#!/usr/bin/env python3
"""Tests for tools/assets.py, the licensed-asset tool (#391).

    py tools/test_assets.py         (Windows)
    python3 tools/test_assets.py    (Linux; tools/verify.sh runs it)

NOTHING HERE TOUCHES THE REAL BUCKET. Every transfer goes through a fake `aws`
put first on PATH -- a stub that serves a temp directory as the bucket and logs
each call -- with the real CLI's fallback paths switched off and its credential
and config files pointed at nothing, so a stub that failed to resolve would
fail rather than reach AWS.

WHAT IS WORTH PINNING is what a wrong version would do silently: an archive
unpacked before its sha256 was checked, a delete that reaches outside
resources/[licensed]/, a failed pull that leaves half of a new set installed, a
season answered one off, a second upload of bytes the bucket already holds.
None of those errors on its own.
"""

from __future__ import annotations

import contextlib
import gzip
import hashlib
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import types
import unittest
from unittest import mock

TOOLS = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(TOOLS)
TOOL = os.path.join(TOOLS, 'assets.py')
sys.path.insert(0, TOOLS)
import assets  # noqa: E402

# A COMMIT'S GIT IS NOT THESE TESTS' GIT. The pre-commit hook runs verify.sh
# with GIT_INDEX_FILE (and, from some front ends, GIT_DIR and friends) pointing
# at the repo being committed, and every git these tests start inherits them:
# their scratch repos then read and write the real repo's index. Run that way,
# four tests failed and the repo's index was left holding the scratch repos'
# entries (2026-10-06). Every git here works on its own temp tree, so none of
# the repository-locating variables is ever wanted.
for _var in ('GIT_DIR', 'GIT_INDEX_FILE', 'GIT_WORK_TREE', 'GIT_OBJECT_DIRECTORY',
             'GIT_ALTERNATE_OBJECT_DIRECTORIES', 'GIT_COMMON_DIR', 'GIT_PREFIX'):
    os.environ.pop(_var, None)

FAKE_AWS = r'''
import json, os, shutil, sys
root = os.environ.get('FAKE_AWS_ROOT')
if not root:
    sys.stderr.write('fake aws: FAKE_AWS_ROOT is not set\n')
    sys.exit(2)
argv = sys.argv[1:]
with open(os.environ['FAKE_AWS_LOG'], 'a', encoding='utf-8') as fh:
    fh.write(json.dumps(argv) + '\n')
VALUED = {'--region', '--profile', '--bucket', '--key', '--output'}
opts, pos, i = {}, [], 0
while i < len(argv):
    a = argv[i]
    if a in VALUED:
        opts[a] = argv[i + 1]
        i += 2
    elif a.startswith('--'):
        opts[a] = True
        i += 1
    else:
        pos.append(a)
        i += 1
def local(bucket, key):
    return os.path.join(root, bucket, *key.split('/'))
def from_url(url):
    bucket, _, key = url[len('s3://'):].partition('/')
    return local(bucket, key)
fail = os.environ.get('FAKE_AWS_FAIL', '')
if pos[:2] == ['s3api', 'head-object']:
    p = local(opts['--bucket'], opts['--key'])
    if os.path.isfile(p):
        print(json.dumps({'ContentLength': os.path.getsize(p), 'ETag': '"0"'}))
        sys.exit(0)
    sys.stderr.write('\nAn error occurred (404) when calling the HeadObject operation: Not Found\n')
    sys.exit(254)
if pos[:2] == ['s3', 'cp'] and len(pos) == 4:
    src, dst = pos[2], pos[3]
    if src.startswith('s3://'):
        if 'download' in fail:
            sys.stderr.write('fatal error: injected download failure\n')
            sys.exit(1)
        p = from_url(src)
        if not os.path.isfile(p):
            sys.stderr.write('fatal error: An error occurred (404) when calling the HeadObject operation: Key does not exist\n')
            sys.exit(1)
        shutil.copyfile(p, dst)
    else:
        if 'upload' in fail:
            sys.stderr.write('upload failed: injected\n')
            sys.exit(1)
        p = from_url(dst)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        shutil.copyfile(src, p)
    sys.exit(0)
sys.stderr.write('fake aws: unsupported call %r\n' % (argv,))
sys.exit(2)
'''


def tree(root, skip=()):
    """Every file and directory under root, with size and mtime, for 'did
    anything change' comparisons. Top-level names in `skip` are not entered."""
    out = {}
    for dirpath, dirnames, filenames in os.walk(root):
        if dirpath == root:
            dirnames[:] = [d for d in dirnames if d not in skip]
        for d in dirnames:
            full = os.path.join(dirpath, d)
            out[os.path.relpath(full, root).replace(os.sep, '/') + '/'] = None
        for f in filenames:
            full = os.path.join(dirpath, f)
            st = os.stat(full)
            with open(full, 'rb') as fh:
                digest = hashlib.sha256(fh.read()).hexdigest()
            out[os.path.relpath(full, root).replace(os.sep, '/')] = (st.st_size, st.st_mtime_ns, digest)
    return out


def write(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'wb') as fh:
        fh.write(data if isinstance(data, bytes) else data.encode('utf-8'))


def read(path):
    with open(path, 'rb') as fh:
        return fh.read()


MANIFEST = b"fx_version 'cerulean'\ngame 'gta5'\n"
M = len(MANIFEST)


def make_resource(parent, name, files=None, manifest=MANIFEST):
    folder = os.path.join(parent, name)
    write(os.path.join(folder, 'fxmanifest.lua'), manifest)
    for rel, data in (files or {}).items():
        write(os.path.join(folder, *rel.split('/')), data)
    return folder


class Box(unittest.TestCase):
    """A temp dir with spaces in it, holding a fake bucket, a fake aws on PATH,
    a lock, resource folders to push and a server root to pull into."""

    def setUp(self):
        base = tempfile.mkdtemp(prefix='assets-test-')
        self.addCleanup(shutil.rmtree, base, True)
        # The owner's Windows home is "C:/Users/William Montgomery": every
        # path this suite hands the tool has a space in it.
        self.tmp = os.path.join(base, 'William Montgomery')
        self.bucket = os.path.join(self.tmp, 'fake bucket')
        self.bin = os.path.join(self.tmp, 'fake bin')
        self.src = os.path.join(self.tmp, 'packs to push')
        self.server = os.path.join(self.tmp, 'server root')
        self.lock = os.path.join(self.tmp, 'repo', 'assets.lock')
        self.awslog = os.path.join(self.tmp, 'aws calls.log')
        for d in (self.bucket, self.bin, self.src, os.path.join(self.server, 'resources'),
                  os.path.dirname(self.lock)):
            os.makedirs(d)
        write(self.awslog, b'')
        shebang = ('#!' + sys.executable) if ' ' not in sys.executable else '#!/usr/bin/env python3'
        write(os.path.join(self.bin, 'aws'), shebang + '\n' + FAKE_AWS)
        os.chmod(os.path.join(self.bin, 'aws'), 0o755)
        write(os.path.join(self.bin, 'aws.py'), FAKE_AWS)

        env = {k: v for k, v in os.environ.items() if not k.upper().startswith('AWS_')}
        env.update({
            'PATH': self.bin + os.pathsep + os.path.dirname(sys.executable),
            'PATHEXT': '.COM;.EXE;.BAT;.CMD;.PY',
            'FAKE_AWS_ROOT': self.bucket,
            'FAKE_AWS_LOG': self.awslog,
            'BR_ASSETS_NO_AWS_FALLBACK': '1',
            'AWS_SHARED_CREDENTIALS_FILE': os.path.join(self.tmp, 'no credentials'),
            'AWS_CONFIG_FILE': os.path.join(self.tmp, 'no config'),
            'AWS_EC2_METADATA_DISABLED': 'true',
            'PYTHONUTF8': '1',
        })
        env.pop('BR_SERVER_ROOT', None)
        self.env = env

    # -- running the tool -----------------------------------------------------

    def run_tool(self, *args, expect=0):
        """assets.main in this process, under the fake environment."""
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.dict(os.environ, self.env, clear=True), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = assets.main([str(a) for a in args])
        text = out.getvalue() + err.getvalue()
        if expect is not None:
            self.assertEqual(rc, expect, 'assets.py %s exited %s:\n%s' % (' '.join(map(str, args)), rc, text))
        return rc, text

    def run_cli(self, *args, expect=0):
        """tools/assets.py as its own process, the way deploy.sh runs it."""
        r = subprocess.run([sys.executable, TOOL] + [str(a) for a in args], env=self.env,
                           cwd=self.tmp, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        text = r.stdout.decode('utf-8', 'replace')
        if expect is not None:
            self.assertEqual(r.returncode, expect, text)
        return r.returncode, text

    def push(self, folder, *extra, expect=0):
        return self.run_tool('push', folder, '--lock', self.lock, *extra, expect=expect)

    def pull(self, *extra, expect=0):
        return self.run_tool('pull', '--lock', self.lock, '--server-root', self.server, *extra, expect=expect)

    def calls(self):
        with open(self.awslog, encoding='utf-8') as fh:
            return [json.loads(line) for line in fh if line.strip()]

    def uploads(self):
        return [c for c in self.calls() if c[:2] == ['s3', 'cp'] and not c[2].startswith('s3://')]

    def downloads(self):
        return [c for c in self.calls() if c[:2] == ['s3', 'cp'] and c[2].startswith('s3://')]

    def reset_calls(self):
        write(self.awslog, b'')

    def lock_data(self):
        return json.loads(read(self.lock).decode('utf-8'))

    def entry(self, name):
        return next(e for e in self.lock_data()['resources'] if e['name'] == name)

    def object_path(self, name, sha):
        return os.path.join(self.bucket, assets.BUCKET, 'assets', name, sha + '.tar.gz')

    @property
    def licensed(self):
        return os.path.join(self.server, 'resources', '[licensed]')

    def cfg(self, text):
        write(os.path.join(self.server, 'server.cfg'), text)


# =============================================================================
# packing
# =============================================================================

class Packing(Box):

    def pack_sha(self, folder):
        out = os.path.join(self.tmp, 'out.tar.gz')
        files, skipped = assets.pack(folder, out)
        sha, size = assets.sha256_file(out)
        os.remove(out)
        return sha, files, skipped

    def test_same_folder_same_sha(self):
        a = make_resource(self.src, 'pack a', {'stream/b.ytd': b'B' * 100, 'stream/a.ydr': b'A' * 5000,
                                                'data/x.meta': b'<x/>'})
        sha1, files, _ = self.pack_sha(a)
        os.utime(os.path.join(a, 'stream', 'a.ydr'), (1, 1))
        os.utime(os.path.join(a, 'fxmanifest.lua'), (2000000000, 2000000000))
        sha2, _, _ = self.pack_sha(a)
        self.assertEqual(sha1, sha2, 'mtimes do not reach the archive')
        # The same files created in another order, in another place.
        b = os.path.join(self.src, 'elsewhere', 'pack a')
        for rel in ('data/x.meta', 'stream/b.ytd', 'stream/a.ydr', 'fxmanifest.lua'):
            write(os.path.join(b, *rel.split('/')), read(os.path.join(a, *rel.split('/'))))
        sha3, _, _ = self.pack_sha(b)
        self.assertEqual(sha1, sha3, 'creation order and location do not reach the archive')
        self.assertEqual(files, {'data/x.meta': 4, 'fxmanifest.lua': M, 'stream/a.ydr': 5000, 'stream/b.ytd': 100})

    def test_content_changes_the_sha(self):
        a = make_resource(self.src, 'p', {'stream/a.ytd': b'one'})
        sha1, _, _ = self.pack_sha(a)
        write(os.path.join(a, 'stream', 'a.ytd'), b'two')
        sha2, _, _ = self.pack_sha(a)
        self.assertNotEqual(sha1, sha2)

    def test_junk_is_left_out(self):
        a = make_resource(self.src, 'p', {'stream/a.ytd': b'x'})
        clean, _, _ = self.pack_sha(a)
        write(os.path.join(a, 'Thumbs.db'), b'junk')
        write(os.path.join(a, 'stream', 'desktop.ini'), b'junk')
        write(os.path.join(a, '.git', 'config'), b'junk')
        dirty, files, skipped = self.pack_sha(a)
        self.assertEqual(clean, dirty)
        self.assertEqual(skipped, ['.git/', 'Thumbs.db', 'stream/desktop.ini'])
        self.assertNotIn('Thumbs.db', files)

    def test_archive_layout_is_fixed(self):
        a = make_resource(self.src, 'p', {'z.lua': b'z', 'stream/sub dir/b c.ytd': b'bc'})
        out = os.path.join(self.tmp, 'x.tar.gz')
        assets.pack(a, out)
        raw = read(out)
        self.assertEqual(raw[4:8], b'\0\0\0\0', 'no gzip timestamp')
        self.assertEqual(raw[3] & 0x08, 0, 'no file name in the gzip header')
        with tarfile.open(out, 'r:gz') as tar:
            members = tar.getmembers()
        self.assertEqual([m.name for m in members], ['fxmanifest.lua', 'stream/sub dir/b c.ytd', 'z.lua'])
        for m in members:
            self.assertTrue(m.isreg())
            self.assertEqual((m.mtime, m.uid, m.gid, m.uname, m.gname, m.mode), (0, 0, 0, '', '', 0o644))

    def test_refuses_a_folder_that_is_not_a_resource(self):
        folder = os.path.join(self.src, 'loose')
        write(os.path.join(folder, 'stream', 'a.ytd'), b'x')
        with self.assertRaises(assets.AssetsError):
            assets.pack(folder, os.path.join(self.tmp, 'x.tar.gz'))
        _, text = self.push(folder, expect=1)
        self.assertIn('no fxmanifest.lua', text)
        self.assertEqual(self.calls(), [], 'refused before any aws call')

    def test_refuses_links(self):
        a = make_resource(self.src, 'p', {'stream/a.ytd': b'x'})
        try:
            os.symlink(os.path.join(a, 'stream', 'a.ytd'), os.path.join(a, 'stream', 'link.ytd'))
        except (OSError, NotImplementedError):
            self.skipTest('this account cannot create symlinks')
        with self.assertRaises(assets.AssetsError) as cm:
            assets.pack(a, os.path.join(self.tmp, 'x.tar.gz'))
        self.assertIn('link', str(cm.exception))


# =============================================================================
# the lock
# =============================================================================

SHA_A = 'a' * 64
SHA_B = 'b' * 64
SHA_C = 'c' * 64


def version(files=None, size=100):
    return {'size': size, 'files': files or {'fxmanifest.lua': 10, 'stream/a.ytd': 90}}


def good_lock():
    return {'format': 2, 'resources': [
        {'name': 'legion_pack', 'seasons': {'1': SHA_A, '3': SHA_B},
         'versions': {SHA_A: version(), SHA_B: version()}},
        # Seasons 2-4, then removed: a null pin.
        {'name': 'emote_pack', 'seasons': {'2': SHA_C, '5': None}, 'versions': {SHA_C: version()}},
    ]}


class Lock(Box):

    def problems(self, lock, names=frozenset()):
        return assets.validate(lock, names)

    def mutated(self, fn):
        lock = good_lock()
        fn(lock)
        return self.problems(lock)

    def assertRefused(self, fn, needle):
        p = self.mutated(fn)
        self.assertTrue(any(needle in x for x in p), 'expected %r among %r' % (needle, p))

    def test_good_lock_passes(self):
        self.assertEqual(self.problems(good_lock()), [])
        self.assertEqual(self.problems({'format': 2, 'resources': []}), [])
        # Format 1 (from/until) never shipped in a lock, and is not read.
        self.assertTrue(any('"format" must be 2' in x for x in self.problems({'format': 1, 'resources': []})))

    def test_sha_format(self):
        self.assertRefused(lambda l: l['resources'][0]['seasons'].update({'1': 'A' * 64}), 'not a sha256')
        self.assertRefused(lambda l: l['resources'][0]['seasons'].update({'1': 'a' * 63}), 'not a sha256')

    def test_duplicate_resources(self):
        def dup(lock):
            e = json.loads(json.dumps(lock['resources'][1]))
            e['name'] = 'Emote_Pack'
            lock['resources'].append(e)
        self.assertRefused(dup, 'listed twice')

    def test_duplicate_json_keys(self):
        text = '{"format": 2, "resources": [], "resources": []}'
        with self.assertRaises(assets.AssetsError):
            assets.parse_lock_text(text)

    def test_nothing_but_names_hashes_sizes_files_and_pins(self):
        self.assertRefused(lambda l: l.update({'notes': 'x'}), 'unknown top-level')
        self.assertRefused(lambda l: l['resources'][0].update({'license': 'KEY-123'}), 'unknown key')
        self.assertRefused(lambda l: l['resources'][0]['versions'][SHA_A].update({'content': 'x'}), 'unknown key')

    def test_season_pins(self):
        self.assertRefused(lambda l: l['resources'][0]['seasons'].update({'01': SHA_A}), 'is not a season')
        self.assertRefused(lambda l: l['resources'][0]['seasons'].update({'0': SHA_A}), 'is not a season')
        self.assertRefused(lambda l: l['resources'][0].update({'seasons': {}}), 'at least one season')
        self.assertRefused(lambda l: l['resources'][0]['seasons'].update({'2': 'none'}), 'or null')
        # from/until are gone: null pins and the earliest pin say both.
        self.assertRefused(lambda l: l['resources'][1].update({'until': 5}), 'unknown key(s) until')
        self.assertRefused(lambda l: l['resources'][1].update({'from': 2}), 'unknown key(s) from')

    def test_one_form_only(self):
        # A null with nothing in force before it removes nothing.
        self.assertRefused(lambda l: l['resources'][1]['seasons'].update({'1': None}), 'removes nothing')
        # Nor does a null after a null.
        self.assertRefused(lambda l: l['resources'][1]['seasons'].update({'7': None}), 'removes nothing')
        # A pin repeating the version in force says nothing.
        self.assertRefused(lambda l: l['resources'][0]['seasons'].update({'2': SHA_A}), 'already in force')
        self.assertRefused(lambda l: l['resources'][0]['seasons'].update({'4': SHA_B}), 'already in force')
        # Only nulls: nothing is ever installed.
        self.assertRefused(lambda l: l['resources'][1].update({'seasons': {'2': None}, 'versions': {}}),
                           'pins no version')
        # A null then the same version again is a real change: back from 7.
        lock = good_lock()
        lock['resources'][1]['seasons']['7'] = SHA_C
        self.assertEqual(self.problems(lock), [])
        # canonical_pins makes the one form out of any other.
        self.assertEqual(assets.canonical_pins({'1': None, '2': SHA_A, '3': SHA_A, '4': None, '5': None,
                                                '6': SHA_A, '7': SHA_B}),
                         {'2': SHA_A, '4': None, '6': SHA_A, '7': SHA_B})

    def test_versions_and_pins_agree(self):
        self.assertRefused(lambda l: l['resources'][0]['versions'].update({SHA_C: version()}), 'pinned to no season')
        self.assertRefused(lambda l: l['resources'][0]['versions'].pop(SHA_B), 'no entry under "versions"')

    def test_file_lists(self):
        for bad in ('../escape', '/abs', 'a\\b', 'C:x', 'a//b', './a'):
            self.assertRefused(lambda l, bad=bad: l['resources'][0]['versions'][SHA_A]['files'].update({bad: 1}),
                               bad if bad != 'a\\b' else 'backslash')
        self.assertRefused(lambda l: l['resources'][0]['versions'][SHA_A].update(
            {'files': {'stream/a.ytd': 1}}), 'no fxmanifest.lua')
        self.assertRefused(lambda l: l['resources'][0]['versions'][SHA_A]['files'].update({'x': -1}),
                           'whole number of bytes')

    def test_names(self):
        self.assertRefused(lambda l: l['resources'][0].update({'name': 'has space'}), 'resource name')
        self.assertRefused(lambda l: l['resources'][0].update({'name': '../x'}), 'resource name')
        self.assertRefused(lambda l: l['resources'][0].update({'name': 'br_licensed'}), 'reserved')
        lock = good_lock()
        lock['resources'][0]['name'] = 'br_core'
        self.assertTrue(any('already has that name' in x for x in self.problems(lock, assets.repo_resource_names())))
        self.assertIn('br_core', assets.repo_resource_names())
        self.assertIn('pma-voice', assets.repo_resource_names())

    def test_written_form_is_stable_and_one_field_per_line(self):
        lock = good_lock()
        text = assets.dump_lock(lock)
        self.assertEqual(text, assets.dump_lock(json.loads(text)))
        for line in text.splitlines():
            self.assertLessEqual(line.count('": '), 1, line)
        self.assertNotIn('\r', text)
        # Seasons ascend, versions follow their first season, files are sorted.
        lock['resources'][0]['seasons'] = {'3': SHA_B, '1': SHA_A}
        lock['resources'][0]['versions'] = {SHA_B: version(), SHA_A: version({'z': 1, 'fxmanifest.lua': 2, 'b': 3})}
        text2 = assets.dump_lock(lock)
        self.assertLess(text2.index('"1": "a'), text2.index('"3": "b'))
        self.assertLess(text2.index('"%s": {' % SHA_A), text2.index('"%s": {' % SHA_B))
        self.assertLess(text2.index('"b": 3'), text2.index('"fxmanifest.lua": 2'))
        self.assertLess(text2.index('"fxmanifest.lua": 2'), text2.index('"z": 1'))

    def test_check_command(self):
        write(self.lock, assets.dump_lock(good_lock()).replace('\n', '\r\n'))
        _, text = self.run_cli('check', '--lock', self.lock)
        self.assertIn('valid: 2 resource(s), 3 version(s)', text)
        bad = good_lock()
        bad['resources'][0]['seasons']['1'] = 'nope'
        write(self.lock, json.dumps(bad))
        _, text = self.run_cli('check', '--lock', self.lock, expect=1)
        self.assertIn('FAIL assets.lock: legion_pack: Season 1', text)
        os.remove(self.lock)
        _, text = self.run_cli('check', '--lock', self.lock)
        self.assertIn('nothing to check', text)
        self.assertEqual(self.calls(), [], 'check never touches the bucket')

    def test_the_committed_lock_passes(self):
        self.run_cli('check')


# =============================================================================
# seasons
# =============================================================================

class Seasons(Box):

    def test_newest_at_or_below(self):
        e = {'name': 'x', 'seasons': {'1': SHA_A, '3': SHA_B}, 'versions': {}}
        self.assertEqual([assets.version_for(e, s) for s in (1, 2, 3, 4, 9)], [SHA_A, SHA_A, SHA_B, SHA_B, SHA_B])

    def test_a_null_pin_removes_until_a_later_pin(self):
        e = {'name': 'x', 'seasons': {'2': SHA_A, '4': None, '6': SHA_B, '8': None},
             'versions': {SHA_A: version(), SHA_B: version()}}
        self.assertEqual([assets.version_for(e, s) for s in range(1, 10)],
                         [None, SHA_A, SHA_A, None, None, SHA_B, SHA_B, None, None])
        lock = {'format': 2, 'resources': [e, {'name': 'y', 'seasons': {'1': SHA_C}, 'versions': {SHA_C: version()}}]}
        self.assertEqual(assets.validate(lock), [])
        self.assertEqual([n for n, _, _ in assets.plan_for(lock, 4)], ['y'])
        self.assertEqual([n for n, _, _ in assets.plan_for(lock, 6)], ['x', 'y'])

    def test_absent_when_every_pin_is_later(self):
        e = {'name': 'x', 'seasons': {'3': SHA_B}, 'versions': {}}
        self.assertEqual([assets.version_for(e, s) for s in (1, 2, 3)], [None, None, SHA_B])

    def test_plan_keeps_lock_order(self):
        names = [n for n, _, _ in assets.plan_for(good_lock(), 3)]
        self.assertEqual(names, ['legion_pack', 'emote_pack'])
        self.assertEqual([n for n, _, _ in assets.plan_for(good_lock(), 1)], ['legion_pack'])

    def test_parse_matches_the_game(self):
        # BR.Season.parse in br_lib/shared/season.lua.
        for raw, want in ((' 2 ', 2), ('1', 1), ('9999', 9999), ('0', None), ('-1', None), ('1.5', None),
                          ('2e0', None), ('0x2', None), ('', None), ('10000', None), ('two', None), (None, None)):
            self.assertEqual(assets.parse_season(raw), want, repr(raw))

    def test_server_cfg_forms(self):
        root = self.server
        for text, want in (
            ('set br_season 2\n', '2'),
            ('setr br_season "3"\n', '3'),
            ('sets br_season 4  # comment\n', '4'),
            ('seta BR_SEASON 5\n', '5'),
            ('# set br_season 7\n// set br_season 8\n', None),
            ('set br_season 1\nset br_season 2\n', '2'),
            ('set br_season 1\r\nset sv_x 2\r\n', '1'),
            ('set br_seasonServed 9\n', None),
        ):
            self.cfg(text)
            found, _ = assets.cfg_season(root, os.path.join(root, 'server.cfg'))
            self.assertEqual(found and found[0], want, repr(text))

    def test_what_br_core_sees(self):
        # br_core reads br_season once, when it starts: an assignment after the
        # line that starts it does not reach it -- unless FXServer's early exec
        # carried it there first (test_fxserver_reads_the_cfg_twice).
        root = self.server
        for text, want in (
            ('set br_season 1\nensure br_core\nset br_season 2\n', '1'),
            ('set br_season 1\nstart br_core\nset br_season 2\n', '1'),
            ('set br_season 1\nensure br_core_extra\nset br_season 2\n', '2'),
            ('set br_season 1\nensure br_lib\nset br_season 2\nensure br_core\n', '2'),
            # One line, several commands.
            ('set sv_x 1; set br_season 4\n', '4'),
            ('set br_season 2; ensure br_core; set br_season 3\n', '2'),
            ('set br_season "2;3"\n', '2;3'),
            # `set` takes exactly two arguments; three is no assignment.
            ('set br_season 2\nset br_season 3 4\n', '2'),
            # Notepad's UTF-8 BOM.
            ('﻿set br_season 5\n', '5'),
        ):
            self.cfg(text)
            found, _ = assets.cfg_season(root, os.path.join(root, 'server.cfg'))
            self.assertEqual(found and found[0], want, repr(text))

    def test_a_comment_ends_its_command_not_the_line(self):
        # ExecuteBuffer cuts at `;` and newlines BEFORE Tokenize knows what a
        # comment is (Console.cpp): the review's cases first.
        root = self.server
        for text, want in (
            ('# Season 2 from Oct 10; set br_season 2\nensure br_core\n', '2'),
            ('set br_season 1\n# switch with; br_season 3\nensure br_core\n', '3'),
            ('set br_season 1 # pinned; br_season 3\nensure br_core\n', '3'),
            ('set br_season 2 # ; set br_season 3\n', '3'),
            ('set br_season 1 // pinned; br_season 3\n', '3'),
            ('#set br_season 2\n', None),
            # A quote in a comment still holds the `;` for the cut.
            ('# a "quoted; set br_season 2\n', None),
            ('# a "quoted"; set br_season 2\n', '2'),
            # A `#` inside a token is part of it.
            ('set br_season 2#3\n', '2#3'),
            # `/*` at a command's start ends it; later, it skips itself and
            # one character, so `/* x */` is two more tokens.
            ('/* note */ set br_season 2\n', None),
            ('set br_season 2 /* x */\n', None),
            ('set br_season 3 /*x\n', '3'),
            ('set br_season /*x4\n', '4'),
            # \" inside a quoted token; a lone CR ends a command.
            ('set br_season "a\\"b"\n', 'a"b'),
            ('set br_season 1\rset br_season 2\n', '2'),
        ):
            self.cfg(text)
            found, _ = assets.cfg_season(root, os.path.join(root, 'server.cfg'))
            self.assertEqual(found and found[0], want, repr(text))

    def test_starting_a_category_br_core_is_in_starts_it(self):
        # `ensure [x]` / `start [x]` start every resource with a folder [x]
        # anywhere on its path below resources/ (FindByPathComponent).
        root = self.server
        for path in (('[fivem-royale]', '[core]', 'br_core'), ('[maps]', 'legion'), ('[deep]', 'not a category', 'br_core')):
            write(os.path.join(root, 'resources', *path, 'fxmanifest.lua'), MANIFEST)
        for text, want in (
            ('set br_season 1\nensure [fivem-royale]\nset br_season 2\n', '1'),
            ('set br_season 1\nstart [core]\nset br_season 2\n', '1'),
            ('set br_season 1; ensure [core]; set br_season 2\n', '1'),
            ('set br_season 1\nensure [maps]\nset br_season 2\n', '2'),
            ('set br_season 1\nensure [nowhere]\nset br_season 2\n', '2'),
            # FXServer walks into [category] folders only: a br_core inside a
            # resource folder is no resource.
            ('set br_season 1\nensure [deep]\nset br_season 2\n', '2'),
            # One argument, or an argument-count mismatch that starts nothing.
            ('set br_season 1\nensure br_core extra\nset br_season 2\n', '2'),
            ('set br_season 1\nensure [fivem-royale] x\nset br_season 2\n', '2'),
        ):
            self.cfg(text)
            found, _ = assets.cfg_season(root, os.path.join(root, 'server.cfg'))
            self.assertEqual(found and found[0], want, repr(text))
        self.assertEqual(assets.reader_categories(root), frozenset(('[fivem-royale]', '[core]')))
        # And the pull's season is read the same way.
        self.cfg('set br_season 1\nensure [fivem-royale]\nset br_season 2\n')
        args = mock.Mock(season=None, server_cfg=None)
        self.assertEqual(assets.resolve_season(args, root, 3), (1, 'br_season 1, server.cfg:1'))

    def test_a_bare_assignment_counts_once_the_convar_exists(self):
        # A convar registers a command under its own name (Console.Variables.h,
        # m_setCommand, one argument); before any set* created it, `br_season`
        # is no command at all.
        root = self.server
        for text, want in (
            ('br_season 6\n', None),
            ('set br_season 2\nbr_season 6\n', '6'),
            ('set br_season 2\nBR_SEASON 6\n', '6'),               # command names ignore case
            ('setr br_season 2\nbr_season "7"\n', '7'),
            ('set br_season 2\nbr_season 6 7\n', '2'),              # one argument, or no assignment
            ('set br_season 2\nbr_season\n', '2'),                  # no argument prints it
            ('set br_season 2\nensure br_core\nbr_season 6\n', '2'),
            ('sets br_season 4\nbr_season 6\n', '6'),
        ):
            self.cfg(text)
            found, _ = assets.cfg_season(root, os.path.join(root, 'server.cfg'))
            self.assertEqual(found and found[0], want, repr(text))

    def test_fxserver_reads_the_cfg_twice(self):
        # ServerInstance::Run's early exec runs the whole cfg first -- past
        # `ensure br_core`, nested files queued -- and forwards every convar it
        # made into the real console with `set`, unless `sets` flagged it
        # ServerInfo. So the real exec starts with br_season set.
        root = self.server
        for text, want in (
            # Set below br_core's start: the early exec carries it there.
            ('ensure br_core\nset br_season 2\n', '2'),
            ('﻿ensure br_core\nset br_season 5\n', '5'),
            # ...and so a bare one above everything assigns in the real exec.
            ('br_season 6\nensure br_core\nset br_season 2\n', '6'),
            ('br_season 6\nset br_season 2\nensure br_core\n', '2'),
            # A `sets` anywhere flags it ServerInfo: nothing is forwarded.
            ('ensure br_core\nsets br_season 2\n', None),
            ('br_season 6\nensure br_core\nsets br_season 2\n', None),
            ('ensure br_core\nset br_season 2\nsets br_season 3\n', None),
            ('set br_season 1\nensure br_core\nsets br_season 3\n', '1'),
        ):
            self.cfg(text)
            found, _ = assets.cfg_season(root, os.path.join(root, 'server.cfg'))
            self.assertEqual(found and found[0], want, repr(text))
        # The early exec queues a nested file behind the one naming it, so its
        # last value is the nested file's -- and that is what is forwarded.
        write(os.path.join(root, 'late.cfg'), 'set br_season 3\n')
        self.cfg('exec late.cfg\nensure br_core\nset br_season 2\n')
        found, _ = assets.cfg_season(root, os.path.join(root, 'server.cfg'))
        self.assertEqual((found[0], os.path.basename(found[1])), ('3', 'late.cfg'), 'the real exec runs late.cfg first')
        self.cfg('ensure br_core\nset br_season 2\nexec late.cfg\n')
        found, _ = assets.cfg_season(root, os.path.join(root, 'server.cfg'))
        self.assertEqual(found[0], '3', 'early exec order: server.cfg, then the files it queued')
        # Queued, not inline: the rest of server.cfg runs before late.cfg.
        self.cfg('ensure br_core\nexec late.cfg\nset br_season 2\n')
        found, _ = assets.cfg_season(root, os.path.join(root, 'server.cfg'))
        self.assertEqual(found[0], '3')
        # And first queued, first run.
        write(os.path.join(root, 'early.cfg'), 'set br_season 1\n')
        self.cfg('ensure br_core\nexec late.cfg\nexec early.cfg\n')
        found, _ = assets.cfg_season(root, os.path.join(root, 'server.cfg'))
        self.assertEqual((found[0], os.path.basename(found[1])), ('1', 'early.cfg'))

    def test_an_exec_that_starts_br_core_ends_the_walk(self):
        root = self.server
        write(os.path.join(root, 'gamemode.cfg'), 'set br_season 2\nensure br_core\nset br_season 3\n')
        self.cfg('set br_season 1\nexec gamemode.cfg\nset br_season 4\n')
        found, _ = assets.cfg_season(root, os.path.join(root, 'server.cfg'))
        self.assertEqual((found[0], os.path.basename(found[1]), found[2]), ('2', 'gamemode.cfg', 1))

    def test_exec_is_followed_in_order(self):
        root = self.server
        write(os.path.join(root, 'cfg dir', 'season one.cfg'), 'set br_season 1\n')
        write(os.path.join(root, 'tunables.cfg'), 'exec "cfg dir/season one.cfg"\nset br_season 3\n')
        self.cfg('set br_season 2\nexec "tunables.cfg"\nexec missing.cfg\nexec @br_core/x.cfg\nexec server.cfg\n')
        found, notes = assets.cfg_season(root, os.path.join(root, 'server.cfg'))
        self.assertEqual(found[0], '3')
        self.assertEqual(os.path.basename(found[1]), 'tunables.cfg')
        self.assertTrue(any('missing.cfg does not exist' in n for n in notes), notes)
        self.assertTrue(any('inside a resource' in n for n in notes), notes)
        self.cfg('exec tunables.cfg\nset br_season 2\n')
        found, _ = assets.cfg_season(root, os.path.join(root, 'server.cfg'))
        self.assertEqual(found[0], '2', 'a set after the exec wins')
        # `exec` takes one argument; given more, it runs nothing, in either pass.
        self.cfg('set br_season 2\nexec tunables.cfg extra\n')
        found, _ = assets.cfg_season(root, os.path.join(root, 'server.cfg'))
        self.assertEqual(found[0], '2')
        self.cfg('ensure br_core\nexec tunables.cfg extra\n')
        found, _ = assets.cfg_season(root, os.path.join(root, 'server.cfg'))
        self.assertIsNone(found, 'the early exec queued nothing to carry')

    def test_unset_and_garbled_mean_latest(self):
        latest = assets.read_latest()
        args = mock.Mock(season=None, server_cfg=None)
        self.cfg('set sv_hostname x\n')
        self.assertEqual(assets.resolve_season(args, self.server, latest)[0], latest)
        os.remove(os.path.join(self.server, 'server.cfg'))
        with contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(assets.resolve_season(args, self.server, latest)[0], latest)
        self.assertIn('server.cfg does not exist', out.getvalue())
        self.cfg('set br_season two\n')
        with contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(assets.resolve_season(args, self.server, latest)[0], latest)
        self.assertIn('is not a season', out.getvalue())
        args.season = 1
        self.assertEqual(assets.resolve_season(args, self.server, latest), (1, '--season 1'))

    def test_latest_is_read_from_seasons_lua(self):
        text = read(os.path.join(REPO, *assets.SEASONS_LUA)).decode('utf-8')
        m = re.search(r'\blatest\s*=\s*(\d+)', text)
        self.assertEqual(assets.read_latest(), int(m.group(1)))
        crlf = os.path.join(self.tmp, 'crlf repo')
        write(os.path.join(crlf, *assets.SEASONS_LUA), text.replace('\n', '\r\n'))
        self.assertEqual(assets.read_latest(crlf), int(m.group(1)))


# =============================================================================
# push
# =============================================================================

class Push(Box):

    def test_push_uploads_once_and_pins(self):
        folder = make_resource(self.src, 'legion_pack', {'stream/a.ytd': b'A' * 2000})
        _, text = self.push(folder)
        e = self.entry('legion_pack')
        sha = e['seasons']['1']
        self.assertTrue(os.path.isfile(self.object_path('legion_pack', sha)))
        self.assertEqual(assets.sha256_file(self.object_path('legion_pack', sha)),
                         (sha, e['versions'][sha]['size']))
        self.assertEqual(e['versions'][sha]['files'], {'fxmanifest.lua': M, 'stream/a.ytd': 2000})
        self.assertIn('uploading', text)
        self.assertIn('Nothing was committed', text)
        for c in self.calls():
            self.assertEqual(c[c.index('--profile') + 1], 'blitz-assets', c)
            self.assertEqual(c[c.index('--region') + 1], 'us-east-2', c)
        self.assertEqual(len(self.uploads()), 1)

        # The same folder again: nothing uploaded, nothing changed.
        self.reset_calls()
        before = read(self.lock)
        _, text = self.push(folder)
        self.assertEqual(self.uploads(), [])
        self.assertIn('already in the bucket', text)
        self.assertIn('unchanged', text)
        self.assertEqual(read(self.lock), before)

    def test_push_skips_an_object_that_is_already_there(self):
        folder = make_resource(self.src, 'p', {'a.ytd': b'x'})
        out = os.path.join(self.tmp, 'x.tar.gz')
        assets.pack(folder, out)
        sha, _ = assets.sha256_file(out)
        write(self.object_path('p', sha), read(out))
        self.push(folder)
        self.assertEqual(self.uploads(), [])
        self.assertEqual(self.entry('p')['seasons'], {'1': sha})

    def test_push_never_overwrites(self):
        folder = make_resource(self.src, 'p', {'a.ytd': b'x'})
        out = os.path.join(self.tmp, 'x.tar.gz')
        assets.pack(folder, out)
        sha, _ = assets.sha256_file(out)
        write(self.object_path('p', sha), b'something else entirely')
        _, text = self.push(folder, expect=1)
        self.assertIn('never overwritten', text)
        self.assertEqual(self.uploads(), [])
        self.assertFalse(os.path.exists(self.lock))
        self.assertEqual(read(self.object_path('p', sha)), b'something else entirely')

    def test_a_failed_upload_leaves_the_lock_alone(self):
        folder = make_resource(self.src, 'p', {'a.ytd': b'x'})
        self.env['FAKE_AWS_FAIL'] = 'upload'
        _, text = self.push(folder, expect=1)
        self.assertIn('uploading', text)
        self.assertFalse(os.path.exists(self.lock))

    def test_seasons_and_retire(self):
        folder = make_resource(self.src, 'emotes', {'anim/a.ycd': b'v1'})
        self.push(folder)
        v1 = self.entry('emotes')['seasons']['1']
        write(os.path.join(folder, 'anim', 'a.ycd'), b'v2')
        _, text = self.push(folder, '--season', 2)
        e = self.entry('emotes')
        v2 = e['seasons']['2']
        self.assertEqual(e['seasons'], {'1': v1, '2': v2})
        self.assertEqual(sorted(e['versions']), sorted([v1, v2]))
        self.assertIn('emotes: from Season 2, %s (was %s)' % (v2[:12], v1[:12]), text)

        # Two seasons pinned: a push must say which one it is.
        write(os.path.join(folder, 'anim', 'a.ycd'), b'v3')
        before = read(self.lock)
        _, text = self.push(folder, expect=1)
        self.assertIn('--season N', text)
        self.assertEqual(read(self.lock), before)

        # retire --season writes a null pin: gone from Season 4 on.
        self.reset_calls()
        _, text = self.run_tool('retire', 'emotes', '--season', 4, '--lock', self.lock)
        self.assertEqual(self.entry('emotes')['seasons'], {'1': v1, '2': v2, '4': None})
        self.assertIn('emotes: removed from Season 4 on', text)
        self.assertIn('"4": null', read(self.lock).decode('utf-8'))
        self.assertEqual(self.calls(), [], 'retire never touches the bucket')
        # Where it is gone already, nothing changes.
        before = read(self.lock)
        _, text = self.run_tool('retire', 'emotes', '--season', 5, '--lock', self.lock)
        self.assertIn('nothing to remove', text)
        self.assertEqual(read(self.lock), before)

        # A later version brings it back.
        _, text = self.push(folder, '--season', 6)
        v3 = self.entry('emotes')['seasons']['6']
        self.assertEqual(self.entry('emotes')['seasons'], {'1': v1, '2': v2, '4': None, '6': v3})
        self.assertIn('emotes: from Season 6, %s (was not installed)' % v3[:12], text)

        # Season 2 pinned to Season 1's version again: a pin that says nothing
        # goes, and so does the version no season pins now.
        write(os.path.join(folder, 'anim', 'a.ycd'), b'v1')
        _, text = self.push(folder, '--season', 2)
        e = self.entry('emotes')
        self.assertEqual(e['seasons'], {'1': v1, '4': None, '6': v3})
        self.assertNotIn(v2, e['versions'])
        self.assertIn('pinned to no season now', text)
        self.assertTrue(os.path.isfile(self.object_path('emotes', v2)), 'the old archive stays in the bucket')

        # Without --season: out of every season, and out of the lock.
        _, text = self.run_tool('retire', 'emotes', '--lock', self.lock)
        self.assertEqual(self.lock_data()['resources'], [])
        self.assertIn('retired from every season', text)
        _, text = self.run_tool('retire', 'emotes', '--lock', self.lock, expect=1)
        self.assertIn('not in the lock', text)

    def test_one_season_pinned_is_replaced_without_asking(self):
        folder = make_resource(self.src, 'map', {'m.ymap': b'1'})
        self.push(folder, '--season', 2)
        write(os.path.join(folder, 'm.ymap'), b'2')
        self.push(folder)
        e = self.entry('map')
        self.assertEqual(list(e['seasons']), ['2'])
        self.assertEqual(len(e['versions']), 1)

    def test_push_refuses_what_check_would(self):
        folder = make_resource(self.src, 'br_core', {'x.lua': b'x'})
        _, text = self.push(folder, expect=1)
        self.assertIn('already has the name br_core', text)
        self.assertEqual(self.uploads(), [])
        self.assertFalse(os.path.exists(self.lock))

    def test_lock_is_written_in_its_one_form(self):
        folder = make_resource(self.src, 'p', {'b.ytd': b'b', 'a.ytd': b'a'})
        self.push(folder)
        text = read(self.lock).decode('utf-8')
        self.assertEqual(text, assets.dump_lock(json.loads(text)))
        self.assertNotIn('\r', text)

    def test_push_takes_several_folders_or_a_category(self):
        a = make_resource(self.src, 'alpha', {'a.ytd': b'a'})
        b = make_resource(self.src, 'beta', {'b.ytd': b'b'})
        self.run_tool('push', a, b, '--lock', self.lock)
        self.assertEqual([e['name'] for e in self.lock_data()['resources']], ['alpha', 'beta'])
        self.assertEqual(len(self.uploads()), 2)
        # A parent or [category] folder pushes each resource in it, walking
        # nested categories, and says what it skipped.
        cat = os.path.join(self.src, '[maps]')
        make_resource(cat, 'legion', {'m.ymap': b'm'})
        make_resource(os.path.join(cat, '[extra]'), 'docks', {'d.ymap': b'd'})
        write(os.path.join(cat, 'readme.txt'), b'x')
        write(os.path.join(cat, 'loose', 'x.ymap'), b'x')
        _, text = self.push(cat, '--season', 2)
        e = {x['name']: x for x in self.lock_data()['resources']}
        self.assertEqual(sorted(e), ['alpha', 'beta', 'docks', 'legion'])
        self.assertEqual(list(e['legion']['seasons']), ['2'])
        self.assertIn('skipped [maps]/readme.txt: not a folder', text)
        self.assertIn('skipped [maps]/loose: no fxmanifest.lua', text)
        # --name is for one resource.
        _, text = self.run_tool('push', a, b, '--lock', self.lock, '--name', 'x', expect=1)
        self.assertIn('--name names one resource', text)
        _, text = self.run_tool('push', a, a, '--lock', self.lock, expect=1)
        self.assertIn('one resource twice', text)


# =============================================================================
# the drop folder: init-drop and publish
# =============================================================================

GIT_EXE = shutil.which('git')


def backdate(root, seconds):
    """Everything under `root`, and `root`, created, written and read
    `seconds` ago: settled, for a Publish in its own process, whose clock a
    test cannot move. Windows only: nothing portable sets a creation time."""
    import ctypes
    from ctypes import wintypes
    k32 = ctypes.WinDLL('kernel32', use_last_error=True)
    k32.CreateFileW.restype = wintypes.HANDLE
    k32.CreateFileW.argtypes = (wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, wintypes.LPVOID,
                                wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE)
    k32.SetFileTime.restype = wintypes.BOOL
    k32.SetFileTime.argtypes = (wintypes.HANDLE,) + (ctypes.POINTER(wintypes.FILETIME),) * 3
    k32.CloseHandle.argtypes = (wintypes.HANDLE,)
    ticks = int((time.time() - seconds) * 10 ** 7) + 116444736000000000
    ft = wintypes.FILETIME(ticks & 0xFFFFFFFF, ticks >> 32)
    paths = [root] + [os.path.join(d, n) for d, dirs, files in os.walk(root) for n in dirs + files]
    for p in reversed(paths):
        # FILE_WRITE_ATTRIBUTES, any sharing, OPEN_EXISTING, BACKUP_SEMANTICS for a folder.
        h = k32.CreateFileW(p, 0x100, 7, None, 3, 0x02000000, None)
        if h is None or h == wintypes.HANDLE(-1).value:
            raise ctypes.WinError(ctypes.get_last_error())
        try:
            if not k32.SetFileTime(h, ctypes.byref(ft), ctypes.byref(ft), ctypes.byref(ft)):
                raise ctypes.WinError(ctypes.get_last_error())
        finally:
            k32.CloseHandle(h)


@unittest.skipUnless(GIT_EXE, 'needs git')
class Publish(Box):
    """publish from its own clone of a bare 'GitHub' remote, with the fake aws
    and a drop folder, all under paths with spaces and brackets -- and beside
    them a shared checkout on dev, the kind agents work in, which publish must
    never touch."""

    def setUp(self):
        super().setUp()
        # The whole PATH after the fake aws (still found first): Git for
        # Windows' pull fails, silently, with only its own bin directory.
        self.env['PATH'] += os.pathsep + os.environ.get('PATH', '')
        for k in ('GIT_AUTHOR', 'GIT_COMMITTER'):
            self.env[k + '_NAME'] = 'Owner'
            self.env[k + '_EMAIL'] = 'owner@example.invalid'
        self.bare = os.path.join(self.tmp, 'origin.git')
        self.shared = os.path.join(self.tmp, 'repo [dev] copy')
        self.clone = os.path.join(self.tmp, 'publish clone')
        self.drop = os.path.join(self.tmp, 'Blitz Assets')
        os.makedirs(self.bare)
        self.g('init', '-q', '--bare', '-b', 'dev', cwd=self.bare)
        make_resource(os.path.join(self.shared, 'resources', '[fivem-royale]'), 'br_core', {'server/x.lua': b'x'})
        write(os.path.join(self.shared, 'assets.lock'), assets.dump_lock({'format': 2, 'resources': []}))
        write(os.path.join(self.shared, 'README.md'), 'readme\n')
        # dev's own tool, which Publish.cmd runs out of the clone.
        write(os.path.join(self.shared, 'tools', 'assets.py'), read(TOOL))
        self.g('init', '-q', '-b', 'dev')
        self.g('config', 'core.autocrlf', 'false')
        self.g('add', '-A')
        self.g('commit', '-qm', 'base')
        self.g('remote', 'add', 'origin', self.bare)
        self.g('push', '-q', '-u', 'origin', 'dev')
        self.base = self.g('rev-parse', 'HEAD')
        self.run_tool('init-drop', self.drop, '--clone', self.clone, '--origin', self.bare)
        # Everything here is seconds old, so Publish's clock runs an hour
        # ahead: settled. The settle window's own tests set it themselves.
        clock = mock.patch.object(assets, 'wall_clock', lambda: time.time() + 3600)
        clock.start()
        self.addCleanup(clock.stop)

    def clock_at(self, now):
        """Publish's clock: `now`, or time.time() when None."""
        return mock.patch.object(assets, 'wall_clock', time.time if now is None else (lambda: now))

    def g(self, *args, cwd=None):
        r = subprocess.run([GIT_EXE, '-c', 'user.name=t', '-c', 'user.email=t@t'] + list(args),
                           cwd=cwd or self.shared, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        out = r.stdout.decode('utf-8', 'replace')
        self.assertEqual(r.returncode, 0, 'git %s: %s' % (' '.join(args), out))
        return out.strip()

    def publish(self, answer='', expect=0, *extra):
        with mock.patch.object(sys, 'stdin', io.StringIO(answer)):
            return self.run_tool('publish', self.drop, '--clone', self.clone, '--origin', self.bare, *extra,
                                 expect=expect)

    def pack_in(self, where, name, files):
        return make_resource(os.path.join(self.drop, *where.split('/')), name, files)

    def sha_of(self, folder):
        out = os.path.join(self.tmp, 'sha-of.tar.gz')
        assets.pack(folder, out)
        sha = assets.sha256_file(out)[0]
        os.remove(out)
        return sha

    def remote_lock(self):
        return json.loads(self.g('show', 'dev:assets.lock', cwd=self.bare))

    def pins(self, lock=None):
        lock = lock or self.remote_lock()
        return {e['name']: e['seasons'] for e in lock['resources']}

    def subject(self):
        return self.g('log', '-1', '--format=%s', 'dev', cwd=self.bare)

    def checkout_state(self, path):
        """Everything about a checkout: HEAD, its branch, every ref, the
        index and work tree's status, and every file's bytes."""
        return (self.g('rev-parse', 'HEAD', cwd=path),
                self.g('rev-parse', '--abbrev-ref', 'HEAD', cwd=path),
                self.g('for-each-ref', '--format=%(refname) %(objectname)', cwd=path),
                self.g('status', '--porcelain=v1', '-uall', cwd=path),
                tree(path, skip=('.git',)))

    # -- init-drop ---------------------------------------------------------

    def test_init_drop_makes_the_folders_readme_and_publish_cmd(self):
        self.assertEqual(sorted(os.listdir(self.drop)), ['Publish.cmd', 'README.txt', 'Season 1', 'Season 2'])
        self.assertEqual(os.listdir(os.path.join(self.drop, 'Season 1')), [])
        self.assertEqual(read(os.path.join(self.drop, 'README.txt')), assets.README_TEXT.replace('\n', '\r\n').encode())
        self.assertIn(b'An empty Season 3\\legion means legion is gone from', read(os.path.join(self.drop, 'README.txt')))
        cmd = read(os.path.join(self.drop, 'Publish.cmd')).decode('ascii')
        self.assertTrue(cmd.endswith('\r\n') and '\n' not in cmd.replace('\r\n', ''), 'CRLF throughout')
        self.assertIn('set "CLONE=%s"\r\n' % self.clone, cmd)
        self.assertIn('set "ORIGIN=%s"\r\n' % self.bare, cmd)
        self.assertIn('git clone --quiet --single-branch --branch dev --no-tags "%ORIGIN%" "%CLONE%"', cmd)
        self.assertIn('git -C "%CLONE%" config blitzassets.publishclone true', cmd)
        self.assertIn('fetch --quiet --no-tags origin +refs/heads/dev:refs/remotes/origin/dev', cmd)
        self.assertIn('checkout --quiet --force --detach refs/remotes/origin/dev', cmd)
        self.assertIn('py -3 "%CLONE%\\tools\\assets.py" publish "%~dp0." --clone "%CLONE%"\r\n', cmd)
        self.assertNotIn(self.shared, cmd, 'Publish.cmd names no checkout anyone works in')
        self.assertTrue(cmd.rstrip().endswith('pause'), 'the window waits for a key')
        # The default: the owner's LOCALAPPDATA, and GitHub.
        default = assets.publish_cmd_text(None, assets.ORIGIN_URL)
        self.assertIn('set "CLONE=%LOCALAPPDATA%\\BlitzAssets\\repo"', default)
        self.assertIn('set "ORIGIN=https://github.com/WillMontgomery/fivem-br-gamemode.git"', default)
        # The owner's README is his: run again, and it is kept as it is.
        write(os.path.join(self.drop, 'README.txt'), b'mine')
        self.run_tool('init-drop', self.drop, '--clone', self.clone, '--origin', self.bare)
        self.assertEqual(read(os.path.join(self.drop, 'README.txt')), b'mine')
        # A folder inside a work tree is refused.
        _, text = self.run_tool('init-drop', os.path.join(self.shared, 'drop'), expect=1)
        self.assertIn('inside the git work tree', text)
        self.assertFalse(os.path.exists(os.path.join(self.shared, 'drop')))

    # -- the y/N gate --------------------------------------------------------

    def test_add_change_retire_and_readd(self):
        legion = self.pack_in('Season 1', 'legion', {'stream/a.ymap': b'v1' * 100})
        v1 = self.sha_of(legion)
        # The shared checkout has work of its own, which publish never sees.
        write(os.path.join(self.shared, 'README.md'), 'readme, edited\n')
        shared = self.checkout_state(self.shared)

        # n: the clone is made, the archive uploaded, and nothing else anywhere.
        _, text = self.publish('n\n')
        self.assertIn('first Publish here: cloning dev', text)
        self.assertIn('+ legion: %s' % v1[:12], text)
        self.assertIn('Commit and push to dev? [y/N]', text)
        self.assertIn('not published: nothing was committed or pushed, and no lock was written anywhere', text)
        self.assertEqual(len(self.uploads()), 1)
        self.assertEqual(self.pins(), {})
        self.assertEqual(self.g('rev-parse', 'dev', cwd=self.bare), self.base)
        # A second n leaves the clone exactly as it was: no ref, no object.
        clone = self.checkout_state(self.clone)
        loose = self.g('count-objects', cwd=self.clone)
        self.publish('n\n')
        self.assertEqual(self.checkout_state(self.clone), clone)
        self.assertEqual(self.g('count-objects', cwd=self.clone), loose, 'not even a blob was written')

        # y: one commit on top of dev, assets.lock alone, pushed.
        self.reset_calls()
        _, text = self.publish('y\n')
        self.assertEqual(self.uploads(), [], 'uploaded at the n, and still there')
        self.assertEqual(self.pins(), {'legion': {'1': v1}})
        self.assertEqual(self.subject(), 'Licensed assets: add legion')
        self.assertEqual(self.g('rev-parse', 'dev~1', cwd=self.bare), self.base)
        self.assertEqual(self.g('show', '--name-only', '--format=', 'dev', cwd=self.bare).splitlines(), ['assets.lock'])
        self.assertIn('+ legion: %s' % v1[:12], self.g('log', '-1', '--format=%b', 'dev', cwd=self.bare))
        self.assertIn('pushed to dev: %s Licensed assets: add legion' % self.g('rev-parse', '--short', 'dev', cwd=self.bare), text)
        self.assertEqual(self.checkout_state(self.shared), shared, 'the shared checkout is untouched')

        # Changed.
        self.reset_calls()
        write(os.path.join(legion, 'stream', 'a.ymap'), b'v2' * 100)
        v2 = self.sha_of(legion)
        _, text = self.publish('y\n')
        self.assertIn('~ legion: %s, ' % v2[:12], text)
        self.assertIn('(was %s)' % v1[:12], text)
        self.assertEqual(len(self.uploads()), 1)
        self.assertEqual(self.pins(), {'legion': {'1': v2}})

        # Retired: the folder is deleted. Nothing uploads; the archive stays.
        self.reset_calls()
        shutil.rmtree(legion)
        _, text = self.publish('y\n')
        self.assertIn('- legion: retired', text)
        self.assertEqual(self.uploads(), [])
        self.assertEqual(self.pins(), {})
        self.assertEqual(self.subject(), 'Licensed assets: retire legion')
        self.assertTrue(os.path.isfile(self.object_path('legion', v2)))

        # Dragged back: republished with no upload.
        self.reset_calls()
        self.pack_in('Season 1', 'legion', {'stream/a.ymap': b'v2' * 100})
        _, text = self.publish('y\n')
        self.assertEqual(self.uploads(), [])
        self.assertIn('already in the bucket', text)
        self.assertEqual(self.pins(), {'legion': {'1': v2}})

        # Nothing changed at all: nothing to ask.
        _, text = self.publish('')
        self.assertIn('nothing to publish', text)
        self.assertNotIn('[y/N]', text)
        self.assertEqual(self.checkout_state(self.shared), shared)

    def test_the_empty_folder_rule(self):
        legion = self.pack_in('Season 1', 'legion', {'stream/a.ymap': b'one'})
        v1 = self.sha_of(legion)
        # Empty: nothing but Explorer's own file and an empty subfolder.
        write(os.path.join(self.drop, 'Season 2', 'legion', 'desktop.ini'), b'[.ShellClassInfo]')
        os.makedirs(os.path.join(self.drop, 'Season 2', 'legion', 'stream'))
        _, text = self.publish('y\n')
        self.assertIn('Season 2/legion: empty', text)
        self.assertIn('- legion: removed from Season 2 on', text)
        self.assertIn('Commit and push to dev? [y/N]', text, 'and it still asks')
        self.assertEqual(self.pins(), {'legion': {'1': v1, '2': None}})
        self.assertIn('"2": null', self.g('show', 'dev:assets.lock', cwd=self.bare))
        self.assertEqual(self.subject(), 'Licensed assets: add legion; remove legion from Season 2 on')
        e = self.remote_lock()['resources'][0]
        self.assertEqual([assets.version_for(e, s) for s in (1, 2, 3)], [v1, None, None])
        for top in ('README.txt', 'Publish.cmd', assets.DROP_INDEX):
            self.assertNotIn(top, text, 'the top-level files are not packs or seasons')

        # Empty again in a later season: removed already, so nothing to remove.
        os.makedirs(os.path.join(self.drop, 'Season 3', 'legion'))
        # Empty, with no earlier version anywhere: nothing to remove either.
        os.makedirs(os.path.join(self.drop, 'Season 2', '[maps]', 'docks'))
        os.makedirs(os.path.join(self.drop, 'Season 1', 'emotes'))
        _, text = self.publish('')
        self.assertIn('skipped Season 3/legion: empty, and nothing to remove: legion is removed from Season 2 on '
                      'already', text)
        self.assertIn('skipped Season 2/[maps]/docks: empty, and nothing to remove: no earlier Season folder has '
                      'docks', text)
        self.assertIn('skipped Season 1/emotes: empty, and nothing to remove', text)
        self.assertIn('nothing to publish', text)

        # A folder WITH files but no fxmanifest.lua is a copy in progress:
        # Publish refuses, so it is never a removal, nor a removal undone.
        shutil.rmtree(os.path.join(self.drop, 'Season 2', 'legion'))
        write(os.path.join(self.drop, 'Season 2', 'legion', 'stream', 'half.ymap'), b'half')
        _, text = self.publish('y\n', expect=1)
        self.assertIn('Season 2/legion has files but no fxmanifest.lua, and is not a [category] folder: '
                      'is it still copying? nothing was published', text)
        self.assertNotIn('no longer removed', text)
        self.assertNotIn('[y/N]', text)
        self.assertEqual(self.pins(), {'legion': {'1': v1, '2': None}})

        # A later season's version brings it back.
        shutil.rmtree(os.path.join(self.drop, 'Season 2', 'legion'))
        os.makedirs(os.path.join(self.drop, 'Season 2', 'legion'))
        v4 = self.sha_of(self.pack_in('Season 4', 'legion', {'stream/a.ymap': b'four'}))
        _, text = self.publish('y\n')
        self.assertIn('+ legion: %s' % v4[:12], text)
        self.assertEqual(self.pins(), {'legion': {'1': v1, '2': None, '4': v4}})

    def test_seasons_categories_and_what_is_skipped(self):
        self.pack_in('Season 1/[maps]', 'legion', {'m.ymap': b'one'})
        self.pack_in('Season 2/[maps]', 'legion', {'m.ymap': b'two'})
        self.pack_in('Season 1/[anims]/[dances]', 'emotes', {'e.ycd': b'e'})
        self.pack_in('Season 2', 'emotes', {'e.ycd': b'e'})      # the same pack again
        write(os.path.join(self.drop, 'Season 1', 'readme.txt'), b'x')
        write(os.path.join(self.drop, 'Season 1', 'desktop.ini'), b'x')
        write(os.path.join(self.drop, 'Old stuff', 'x.txt'), b'x')
        write(os.path.join(self.drop, 'pack.zip'), b'x')
        # A folder in a Season folder that is no pack, no [category] and not
        # empty could be a pack still copying: refused, never skipped.
        write(os.path.join(self.drop, 'Season 1', 'not a resource', 'x.lua'), b'x')
        _, text = self.publish('y\n', expect=1)
        self.assertIn('Season 1/not a resource has files but no fxmanifest.lua', text)
        shutil.rmtree(os.path.join(self.drop, 'Season 1', 'not a resource'))
        _, text = self.publish('y\n')
        pins = self.pins()
        self.assertEqual(sorted(pins['legion']), ['1', '2'])
        self.assertNotEqual(pins['legion']['1'], pins['legion']['2'])
        self.assertEqual(pins['emotes'], {'1': pins['emotes']['1']}, 'one version per season: no second pin')
        for note in ('skipped Season 1/readme.txt: not a folder',
                     'skipped Old stuff: not a "Season <n>" folder',
                     'skipped pack.zip: not in a season folder'):
            self.assertIn(note, text)
        self.assertNotIn('desktop.ini', text)
        # Season folder names: any case, `Season <n>`.
        os.rename(os.path.join(self.drop, 'Season 2'), os.path.join(self.drop, 'SEASON 2'))
        _, text = self.publish('')
        self.assertIn('nothing to publish', text)

    # -- the index -----------------------------------------------------------

    def test_the_index_spares_packing_never_reading(self):
        big = self.pack_in('Season 1', 'legion', {'stream/a.ymap': b'x' * 5000})
        sha = self.sha_of(big)
        packs = []
        real = assets.write_pack

        def counting(files, out, digests=None):
            packs.append(out)
            return real(files, out, digests)
        with mock.patch.object(assets, 'write_pack', counting):
            self.publish('n\n')
            self.assertEqual(len(packs), 1)
            _, text = self.publish('n\n')
            self.assertEqual(len(packs), 1, 'the same content: not packed again')
            self.assertIn('Season 1/legion: %s, 2 files, ' % sha[:12], text)
            self.assertIn(', packed before', text)
            # A touched file is read again, and the same bytes are the same pack.
            st = os.stat(os.path.join(big, 'stream', 'a.ymap'))
            os.utime(os.path.join(big, 'stream', 'a.ymap'), ns=(st.st_atime_ns, st.st_mtime_ns + 10 ** 9))
            self.publish('n\n')
            self.assertEqual(len(packs), 1)
            # The same content in another folder hits too.
            shutil.copytree(big, os.path.join(self.drop, 'Season 2', 'legion'))
            self.publish('n\n')
            self.assertEqual(len(packs), 1)
            shutil.rmtree(os.path.join(self.drop, 'Season 2', 'legion'))
            # An index hit the bucket lacks: packed once, at upload, and held
            # to the indexed sha.
            os.remove(self.object_path('legion', sha))
            self.reset_calls()
            self.publish('n\n')
            self.assertEqual(len(packs), 2)
            self.assertEqual(len(self.uploads()), 1)
            self.assertEqual(assets.sha256_file(self.object_path('legion', sha))[0], sha)
        index = json.loads(read(os.path.join(self.drop, assets.DROP_INDEX)).decode('utf-8'))
        self.assertEqual(index['format'], 2)
        self.assertEqual([v['sha'] for v in index['packs'].values()], [sha])

    def test_a_same_size_same_mtime_edit_is_published(self):
        # THE REVIEW'S CASE: a file's bytes change, its size and mtime do not
        # (an Explorer copy keeps the source's mtime; a texture re-exported at
        # one resolution keeps its size), and the old sha is already in dev's
        # lock -- so the upload step never re-packs it to notice.
        legion = self.pack_in('Season 1', 'legion', {'stream/a.ymap': b'x' * 178})
        v1 = self.sha_of(legion)
        self.publish('y\n')
        self.assertEqual(self.pins(), {'legion': {'1': v1}})
        path = os.path.join(legion, 'stream', 'a.ymap')
        st = os.stat(path)
        write(path, b'y' * 178)
        os.utime(path, ns=(st.st_atime_ns, st.st_mtime_ns))
        self.assertEqual((os.stat(path).st_size, os.stat(path).st_mtime_ns), (st.st_size, st.st_mtime_ns))
        v2 = self.sha_of(legion)
        self.assertNotEqual(v1, v2)
        self.reset_calls()
        _, text = self.publish('y\n')
        self.assertNotIn('nothing to publish', text)
        self.assertIn('~ legion: %s, ' % v2[:12], text)
        self.assertEqual(len(self.uploads()), 1)
        self.assertEqual(self.pins(), {'legion': {'1': v2}})

    def test_a_folder_that_changes_while_it_is_packed_is_refused(self):
        # A copy still writing into the pack: the bytes packed are not the
        # bytes hashed, and the index must not record either as the other.
        legion = self.pack_in('Season 1', 'legion', {'stream/a.ymap': b'x' * 500})
        real = assets.write_pack

        def copy_lands_meanwhile(files, out, digests=None):
            write(os.path.join(legion, 'stream', 'a.ymap'), b'z' * 500)
            return real(files, out, digests)
        with mock.patch.object(assets, 'write_pack', copy_lands_meanwhile):
            _, text = self.publish('y\n', expect=1)
        self.assertIn('changed while it was being published', text)
        self.assertEqual(self.uploads(), [])
        self.assertEqual(self.pins(), {})
        self.assertFalse(os.path.exists(os.path.join(self.drop, assets.DROP_INDEX)), 'and nothing was indexed')

    def test_a_pack_that_changes_before_its_upload_is_refused(self):
        # An index hit is packed only when it has to go up; if the folder has
        # changed by then, nothing goes into the bucket under the old sha.
        legion = self.pack_in('Season 1', 'legion', {'stream/a.ymap': b'x' * 500})
        sha = self.sha_of(legion)
        self.publish('n\n')
        os.remove(self.object_path('legion', sha))
        real = assets.upload_missing

        def edited_first(aws, items, progress=False):
            write(os.path.join(legion, 'stream', 'a.ymap'), b'w' * 500)
            return real(aws, items, progress)
        self.reset_calls()
        with mock.patch.object(assets, 'upload_missing', edited_first):
            _, text = self.publish('y\n', expect=1)
        self.assertIn('changed while it was being published', text)
        self.assertEqual(self.uploads(), [])
        self.assertFalse(os.path.exists(self.object_path('legion', sha)))
        self.assertEqual(self.pins(), {})

    # -- a copy still running ------------------------------------------------------

    def assert_refused_untouched(self, text, pins, said='is it still copying? nothing was published'):
        """Refused before any upload and before asking: no aws call at all,
        no prompt, and dev's lock as it was."""
        self.assertIn(said, text)
        self.assertNotIn('[y/N]', text)
        self.assertEqual(self.calls(), [])
        self.assertEqual(self.pins(), pins)

    def test_a_half_copied_folder_refuses_publish(self):
        # THE REVIEW'S CASES. Skipped, a folder with files but no
        # fxmanifest.lua dropped the pack it was replacing out of the lock.
        legion = self.pack_in('Season 1', 'legion', {'stream/a.ymap': b'one' * 50})
        v1 = self.sha_of(legion)
        self.publish('y\n')
        # 1. Its only version, mid-replacement: deleted, and the new one's
        #    audio/ copied in before its fxmanifest.lua. It was "retired".
        shutil.rmtree(legion)
        write(os.path.join(legion, 'audio', 'x.awc'), b'z' * 300)
        self.reset_calls()
        _, text = self.publish('y\n', expect=1)
        self.assertIn('Season 1/legion has files but no fxmanifest.lua, and is not a [category] folder: '
                      'is it still copying? nothing was published', text)
        self.assertNotIn('retired', text)
        self.assert_refused_untouched(text, {'legion': {'1': v1}})

        # 2. A later season's version mid-replacement, after a null: its pin
        #    went, and the null carried on.
        shutil.rmtree(legion)
        self.pack_in('Season 1', 'legion', {'stream/a.ymap': b'one' * 50})
        os.makedirs(os.path.join(self.drop, 'Season 2', 'legion'))
        s3 = self.pack_in('Season 3', 'legion', {'stream/a.ymap': b'three'})
        v3 = self.sha_of(s3)
        self.publish('y\n')
        self.assertEqual(self.pins(), {'legion': {'1': v1, '2': None, '3': v3}})
        shutil.rmtree(s3)
        write(os.path.join(s3, 'stream', 'a.ymap'), b'four')
        self.reset_calls()
        _, text = self.publish('y\n', expect=1)
        self.assertIn('Season 3/legion has files but no fxmanifest.lua', text)
        self.assertNotIn('no longer pinned', text)
        self.assert_refused_untouched(text, {'legion': {'1': v1, '2': None, '3': v3}})
        # The copy finishes: published.
        write(os.path.join(s3, 'fxmanifest.lua'), MANIFEST)
        v4 = self.sha_of(s3)
        self.publish('y\n')
        self.assertEqual(self.pins(), {'legion': {'1': v1, '2': None, '3': v4}})

        # 3. At any depth under a Season folder, [category] folders too; and
        #    an empty folder beside it is still a null pin, once it is alone.
        docks = os.path.join(self.drop, 'Season 1', '[maps]', '[docks]', 'docks')
        write(os.path.join(docks, 'stream', 'docks.ymap'), b'd')
        os.makedirs(os.path.join(self.drop, 'Season 4', 'legion'))
        self.reset_calls()
        _, text = self.publish('y\n', expect=1)
        self.assertIn('Season 1/[maps]/[docks]/docks has files but no fxmanifest.lua', text)
        self.assert_refused_untouched(text, {'legion': {'1': v1, '2': None, '3': v4}})
        shutil.rmtree(docks)
        self.publish('y\n')
        self.assertEqual(self.pins(), {'legion': {'1': v1, '2': None, '3': v4, '4': None}})

    def test_a_copy_started_during_the_prompt_is_never_committed(self):
        # dev moves while the owner reads the plan, and a copy starts. The
        # folders are read again after his answer: refused there, before any
        # commit, and the refusal says the upload already made stays.
        self.pack_in('Season 1', 'legion', {'m.ymap': b'm'})
        other = self.other_clone()

        def ask(_q):
            self.move_dev(other)
            write(os.path.join(self.drop, 'Season 2', 'emotes', 'stream', 'e.ycd'), b'e')
            return True
        with mock.patch.object(assets, 'ask', ask):
            _, text = self.publish(expect=1)
        self.assertIn(assets.FOLDERS_CHANGED + ':\n  Season 2/emotes has files but no fxmanifest.lua', text)
        self.assertEqual(assets.FOLDERS_CHANGED, 'the folders changed after the plan was shown; run Publish again; '
                                                 'nothing was committed or pushed (uploads stay in the bucket)')
        self.assertNotIn('git push', text)
        self.assertEqual(self.subject(), 'meanwhile')
        self.assertEqual(len(self.uploads()), 1)

    def move_dev(self, other, name='meanwhile'):
        """Another push lands on dev, from `other`."""
        write(os.path.join(other, 'resources', name + '.lua'), 'return 2\n')
        self.g('add', '-A', cwd=other)
        self.g('commit', '-qm', name, cwd=other)
        self.g('push', '-q', 'origin', 'dev', cwd=other)

    def test_folders_changed_before_a_retry_are_never_committed(self):
        # dev moves during the prompt, so the push is refused and the plan
        # made again -- and by then the folders have changed.
        legion = self.pack_in('Season 1', 'legion', {'m.ymap': b'm'})
        other = self.other_clone()
        real = assets.push_commit
        meanwhile = []
        moves = []

        def ask(_q):
            moves.append(1)
            self.move_dev(other, 'meanwhile %d' % len(moves))
            return True

        def push(clone, base, commit):
            if meanwhile:
                meanwhile.pop(0)()
            return real(clone, base, commit)
        # 1. The same pack copied into Season 2: the same plan, so it would
        #    be pushed without asking, but not from the folders answered.
        meanwhile.append(lambda: shutil.copytree(legion, os.path.join(self.drop, 'Season 2', 'legion')))
        with mock.patch.object(assets, 'ask', ask), mock.patch.object(assets, 'push_commit', push):
            _, text = self.publish(expect=1)
        self.assertIn(assets.FOLDERS_CHANGED + ':\n  Season 2/legion is new', text)
        self.assertNotIn('pushing again', text)
        self.assertEqual(self.subject(), 'meanwhile 1')
        self.assertEqual(self.pins(), {})
        # 2. A copy still running: the new plan's own scan refuses, and says
        #    the upload already made stays.
        shutil.rmtree(os.path.join(self.drop, 'Season 2', 'legion'))
        meanwhile.append(lambda: write(os.path.join(self.drop, 'Season 2', 'emotes', 'e.ycd'), b'e'))
        with mock.patch.object(assets, 'ask', ask), mock.patch.object(assets, 'push_commit', push):
            _, text = self.publish(expect=1)
        self.assertIn('nothing was committed or pushed (what was uploaded stays in the bucket):\n'
                      '  Season 2/emotes has files but no fxmanifest.lua', text)
        self.assertEqual(self.subject(), 'meanwhile 2')
        self.assertEqual(self.pins(), {})
        self.assertEqual(len(self.uploads()), 1)

    # -- the settle window and the second read -------------------------------------

    def test_a_pack_still_landing_refuses_publish(self):
        # THE REVIEW'S P1. File Explorer copies a pack's data/, then its
        # fxmanifest.lua, then stream/: caught between them, the pack holds a
        # manifest and part of its files, and was planned as a version.
        legion = self.pack_in('Season 1', 'legion', {'stream/a.ymap': b'one' * 50})
        v1 = self.sha_of(legion)
        self.publish('y\n')
        landing = os.path.join(self.drop, 'Season 2', '[maps]', 'legion')
        write(os.path.join(landing, 'data', 'carcols.meta'), b'<c/>')
        write(os.path.join(landing, 'fxmanifest.lua'), MANIFEST)
        # Publish's clock stops the moment the pack landed: a loaded machine
        # taking longer than the settle window to get to Publish must not
        # settle it.
        landed = time.time()
        self.reset_calls()
        with self.clock_at(landed):
            _, text = self.publish('y\n', expect=1)
        # (Everything this test made is seconds old: Season 1 may be named too.)
        self.assertIn('nothing was uploaded or changed:\n', text)
        self.assertIn('\n  Season 2/[maps]/legion changed in the last 10 seconds: is it still copying? wait 10 seconds '
                      'and run Publish again; nothing was published\n', text)
        for above in ('Season 2', 'Season 2/[maps]'):
            self.assertNotIn('  %s changed' % above, text, 'the pack is named, not every folder above it')
        self.assert_refused_untouched(text, {'legion': {'1': v1}}, 'is it still copying? wait 10 seconds')
        # Its stream/ lands; once it has settled, the whole pack is published.
        write(os.path.join(landing, 'stream', 'b.ymap'), b'two' * 50)
        v2 = self.sha_of(landing)
        with self.clock_at(time.time() + 2 * assets.SETTLE_SECONDS):
            _, text = self.publish('y\n')
        self.assertIn('pushed to dev', text)
        self.assertEqual(self.pins(), {'legion': {'1': v1, '2': v2}})

    def stamps(self, root):
        return [os.lstat(os.path.join(d, n)) for d, dirs, files in os.walk(root) for n in dirs + files]

    def test_the_settle_window_reads_when_a_file_came_to_be(self):
        # File Explorer gives a copy its source's mtime, so a pack copied
        # this second can say it was last written three years ago. Its
        # creation time (on Linux, its inode change time) says it just landed.
        legion = self.pack_in('Season 1', 'legion', {'stream/a.ymap': b'one' * 50})
        landed = time.time()
        old = time.time() - 3 * 365 * 86400
        for d, dirs, files in os.walk(self.drop, topdown=False):
            for n in dirs + files:
                os.utime(os.path.join(d, n), (old, old))
        for st in self.stamps(os.path.join(self.drop, 'Season 1')):
            self.assertLess(st.st_mtime, old + 1)
            self.assertGreater(assets.entry_stamps(st)[1], time.time() - 60)
        with self.clock_at(landed):
            _, text = self.publish('y\n', expect=1)
        self.assertIn('Season 1/legion changed in the last 10 seconds: is it still copying?', text)
        self.assert_refused_untouched(text, {}, 'wait 10 seconds and run Publish again; nothing was published')
        now = time.time() + 2 * assets.SETTLE_SECONDS
        with self.clock_at(now):
            self.publish('y\n')
        self.assertEqual(self.pins(), {'legion': {'1': self.sha_of(legion)}})
        # An mtime ahead of the clock is a source's (a zip made five hours
        # east, read here): only this PC's clock dates a copy, so it is no
        # copy landing.
        os.utime(os.path.join(legion, 'stream', 'a.ymap'), (now + 5 * 3600, now + 5 * 3600))
        with self.clock_at(now):
            _, text = self.publish('')
        self.assertIn('nothing to publish', text)

    def test_a_season_folder_written_to_lately_refuses_publish(self):
        # A pack deleted (or moved in, which keeps every stamp it had)
        # leaves nothing new under the Season folder: its own mtime moves.
        self.pack_in('Season 1', 'legion', {'m.ymap': b'm'})
        docks = self.pack_in('Season 1', 'docks', {'d.ymap': b'd'})
        self.publish('y\n')
        pins = self.pins()
        now = time.time() + 3600
        shutil.rmtree(docks)
        os.utime(os.path.join(self.drop, 'Season 1'), (now - 5, now - 5))
        self.reset_calls()
        with self.clock_at(now):
            _, text = self.publish('y\n', expect=1)
        self.assertIn('  Season 1 changed in the last 10 seconds: is it still copying? wait 10 seconds', text)
        self.assertNotIn('retired', text)
        self.assert_refused_untouched(text, pins, 'wait 10 seconds and run Publish again; nothing was published')
        with self.clock_at(now + 2 * assets.SETTLE_SECONDS):
            _, text = self.publish('y\n')
        self.assertIn('- docks: retired', text)
        self.assertEqual(sorted(self.pins()), ['legion'])

    def test_a_copy_finishing_during_the_prompt_is_never_committed(self):
        # THE REVIEW'S P2. The plan is made from a pack half landed -- its
        # fxmanifest.lua and data/ in, stream/ not yet, and still for a
        # minute (a copy stopped at a "Replace or Skip" prompt is) -- and
        # the rest lands while the owner reads it.
        legion = self.pack_in('Season 1', 'legion', {'stream/a.ymap': b'one' * 50})
        v1 = self.sha_of(legion)
        self.publish('y\n')
        landing = self.pack_in('Season 2', 'legion', {'data/carcols.meta': b'<c/>'})
        half = self.sha_of(landing)
        meanwhile = []

        def ask(_q):
            meanwhile.pop(0)()
            return True
        meanwhile.append(lambda: write(os.path.join(landing, 'stream', 'b.ymap'), b'two' * 50))
        self.reset_calls()
        with mock.patch.object(assets, 'ask', ask):
            _, text = self.publish(expect=1)
        self.assertIn('+ legion: %s' % half[:12], text, 'the plan answered was the half')
        self.assertIn('reading the folders again before the commit\n', text)
        self.assertIn(assets.FOLDERS_CHANGED + ':\n  Season 2/legion changed\n', text)
        self.assertNotIn('git push', text)
        self.assertEqual(self.g('rev-parse', 'dev~1', cwd=self.bare), self.base, 'nothing was committed')
        self.assertEqual(self.pins(), {'legion': {'1': v1}})
        self.assertEqual(len(self.uploads()), 1, 'the half went up before the answer, and stays')
        # Run again: the whole pack.
        v2 = self.sha_of(landing)
        self.publish('y\n')
        self.assertEqual(self.pins(), {'legion': {'1': v1, '2': v2}})
        # A pack dragged in, and another deleted, while he reads the plan.
        self.pack_in('Season 1', 'docks', {'d.ymap': b'd'})
        meanwhile.append(lambda: (shutil.rmtree(landing), self.pack_in('Season 2', 'emotes', {'e.ycd': b'e'})))
        with mock.patch.object(assets, 'ask', ask):
            _, text = self.publish(expect=1)
        self.assertIn(assets.FOLDERS_CHANGED + ':\n  Season 2/emotes is new\n  Season 2/legion is gone\n', text)
        self.assertEqual(self.pins(), {'legion': {'1': v1, '2': v2}})
        # The second read has the settle window too: with the clock not moved
        # on past the answer, it names what landed.
        shutil.rmtree(os.path.join(self.drop, 'Season 2', 'emotes'))
        answered = []

        def clock():
            return time.time() + (0 if answered else 3600)
        meanwhile.append(lambda: (write(os.path.join(legion, 'stream', 'c.ymap'), b'three'), answered.append(1)))
        with mock.patch.object(assets, 'ask', ask), mock.patch.object(assets, 'wall_clock', clock):
            _, text = self.publish(expect=1)
        self.assertIn(assets.FOLDERS_CHANGED + ':\n', text)
        self.assertIn('\n  Season 1/legion changed in the last 10 seconds: is it still copying? wait 10 seconds and '
                      'run Publish again; nothing was published\n', text)
        self.assertEqual(self.pins(), {'legion': {'1': v1, '2': v2}})

    @contextlib.contextmanager
    def unreadable(self, path):
        """Every read of `path` refused, as a copy holding it open or a
        permission refuses it: listing it, walking into it, opening it. By
        hand, because chmod cannot do it on Windows."""
        denied = os.path.normcase(os.path.abspath(path))
        real_listdir, real_scandir = os.listdir, os.scandir

        def check(p):
            if not isinstance(p, int):
                p = os.fsdecode(os.fspath(p))
                if os.path.normcase(os.path.abspath(p)) == denied:
                    raise PermissionError(13, 'Permission denied', p)

        def listdir(p='.'):
            check(p)
            return real_listdir(p)

        def scandir(p='.'):
            check(p)
            return real_scandir(p)

        def opener(p, *args, **kwargs):
            check(p)
            return open(p, *args, **kwargs)
        with mock.patch.object(os, 'listdir', listdir), mock.patch.object(os, 'scandir', scandir), \
                mock.patch.object(assets, 'open', opener, create=True):
            yield

    def test_anything_unreadable_refuses_publish(self):
        legion = self.pack_in('Season 1', 'legion', {'stream/a.ymap': b'one' * 50})
        self.pack_in('Season 1/[maps]', 'docks', {'d.ymap': b'd'})
        os.makedirs(os.path.join(self.drop, 'Season 2', 'legion'))
        self.publish('y\n')
        pins = self.pins()
        self.assertEqual(sorted(pins), ['docks', 'legion'])
        for path, said in (
            (os.path.join(self.drop, 'Season 2'), 'Season 2'),
            (os.path.join(self.drop, 'Season 1', '[maps]'), 'Season 1/[maps]'),
            (legion, 'Season 1/legion'),
            (os.path.join(legion, 'stream'), 'Season 1/legion/stream'),
            (os.path.join(legion, 'stream', 'a.ymap'), 'Season 1/legion/stream/a.ymap'),
            # An empty folder means something, so an unreadable one is not empty.
            (os.path.join(self.drop, 'Season 2', 'legion'), 'Season 2/legion'),
        ):
            self.reset_calls()
            with self.unreadable(path):
                _, text = self.publish('y\n', expect=1)
            self.assertIn('%s cannot be read (Permission denied): is it still copying? nothing was published'
                          % said, text)
            self.assert_refused_untouched(text, pins)

    def link_dir(self, target, link):
        """A link to the folder `target`: a symlink, or on Windows without
        the right to make one, a junction."""
        try:
            os.symlink(target, link, target_is_directory=True)
        except OSError:
            if os.name != 'nt':
                raise
            import _winapi
            _winapi.CreateJunction(target, link)
        self.assertTrue(assets.is_link(link))

    def test_links_and_what_cannot_be_stated_refuse_publish(self):
        # Skipped with a note, each dropped the pack it stood for out of the
        # lock: retired, or its later version unpinned.
        legion = self.pack_in('Season 1', 'legion', {'stream/a.ymap': b'one' * 50})
        self.pack_in('Season 1/[maps]', 'docks', {'d.ymap': b'd'})
        self.publish('y\n')
        pins = self.pins()
        elsewhere = make_resource(self.src, 'legion', {'stream/a.ymap': b'one' * 50})
        moved = os.path.join(self.tmp, 'legion moved')
        for link, said in ((legion, 'Season 1/legion'),
                           (os.path.join(self.drop, 'Season 1', '[maps]', 'docks'), 'Season 1/[maps]/docks'),
                           (os.path.join(self.drop, 'Season 1', '[maps]'), 'Season 1/[maps]'),
                           (os.path.join(self.drop, 'Season 1'), 'Season 1')):
            os.rename(link, moved)
            self.link_dir(elsewhere if link == legion else moved, link)
            self.reset_calls()
            try:
                _, text = self.publish('y\n', expect=1)
            finally:
                (os.rmdir if os.name == 'nt' else os.unlink)(link)
                os.rename(moved, link)
            self.assertIn('nothing was uploaded or changed:\n  %s is a link; put the folder itself there, not a '
                          'link to it\n' % said, text)
            self.assert_refused_untouched(text, pins, 'is a link')
        real_lstat = os.lstat
        for path, said in ((legion, 'Season 1/legion'), (os.path.join(self.drop, 'Season 1'), 'Season 1'),
                           (os.path.join(legion, 'stream', 'a.ymap'), 'Season 1/legion/stream/a.ymap')):
            denied = os.path.normcase(path)

            def lstat(p, *args, **kwargs):
                if not isinstance(p, int) and os.path.normcase(os.path.abspath(os.fsdecode(p))) == denied:
                    raise PermissionError(13, 'Permission denied', os.fsdecode(p))
                return real_lstat(p, *args, **kwargs)
            self.reset_calls()
            with mock.patch.object(os, 'lstat', lstat):
                _, text = self.publish('y\n', expect=1)
            self.assertIn('%s cannot be read (Permission denied): is it still copying? nothing was published'
                          % said, text)
            self.assert_refused_untouched(text, pins)
        self.publish('')
        self.assertEqual(self.pins(), pins)

    # -- never the shared checkout -----------------------------------------------

    def test_the_shared_checkout_is_never_touched(self):
        # The checkout agents share: dev with a local commit GitHub does not
        # have, an edited tracked file, an untracked one.
        write(os.path.join(self.shared, 'resources', 'agent.lua'), 'return 1\n')
        self.g('add', '--', 'resources/agent.lua')
        self.g('commit', '-qm', 'agent work, not pushed')
        write(os.path.join(self.shared, 'README.md'), 'half done\n')
        write(os.path.join(self.shared, 'notes.txt'), 'untracked\n')
        before = self.checkout_state(self.shared)
        self.pack_in('Season 1', 'legion', {'m.ymap': b'm'})
        self.publish('y\n')
        self.assertEqual(self.checkout_state(self.shared), before)
        self.assertEqual(self.g('log', '--format=%s', 'dev', cwd=self.bare).splitlines(),
                         ['Licensed assets: add legion', 'base'], "the agent's commit did not go up")
        # And a --clone naming it is refused before anything happens.
        self.reset_calls()
        with mock.patch.object(sys, 'stdin', io.StringIO('y\n')):
            _, text = self.run_tool('publish', self.drop, '--clone', self.shared, expect=1)
        self.assertIn("is not Publish's own clone", text)
        self.assertEqual(self.calls(), [])
        self.assertEqual(self.checkout_state(self.shared), before)

    def test_a_branch_switched_in_the_clone_mid_prompt_changes_nothing(self):
        # Round 2 committed on whatever branch the checkout was on at the y,
        # and said "pushed to dev" when it was not. Publish now uses no branch.
        self.pack_in('Season 1', 'legion', {'m.ymap': b'm'})
        self.publish('n\n')          # makes the clone, its HEAD at dev as it was then
        other = self.other_clone()
        write(os.path.join(other, 'resources', 'later.lua'), 'return 1\n')
        self.g('add', '-A', cwd=other)
        self.g('commit', '-qm', 'later work', cwd=other)
        self.g('push', '-q', 'origin', 'dev', cwd=other)
        later = self.g('rev-parse', 'HEAD', cwd=other)

        def ask(_q):
            self.g('checkout', '-q', '-b', 'elsewhere', cwd=self.clone)
            write(os.path.join(self.clone, 'README.md'), 'edited in the clone\n')
            self.g('checkout', '-q', '-b', 'agent-branch', cwd=self.shared)
            return True
        with mock.patch.object(assets, 'ask', ask):
            _, text = self.publish()
        self.assertIn('pushed to dev', text)
        self.assertEqual(self.subject(), 'Licensed assets: add legion')
        self.assertEqual(self.g('rev-parse', 'dev~1', cwd=self.bare), later,
                         "on top of GitHub's dev, not the clone's stale HEAD")
        self.assertEqual(self.g('show', '--name-only', '--format=', 'dev', cwd=self.bare).splitlines(), ['assets.lock'])
        self.assertEqual(self.g('log', '--format=%s', '-1', 'elsewhere', cwd=self.clone), 'base',
                         'and no branch anywhere got the commit')

    def other_clone(self):
        other = os.path.join(self.tmp, 'another clone')
        self.g('clone', '-q', '--branch', 'dev', self.bare, other, cwd=self.tmp)
        return other

    def test_dev_moving_during_the_prompt_with_the_same_plan_pushes_again(self):
        self.pack_in('Season 1', 'legion', {'m.ymap': b'm'})
        other = self.other_clone()
        asked = []

        def ask(q):
            asked.append(q)
            write(os.path.join(other, 'resources', 'meanwhile.lua'), 'return 2\n')
            self.g('add', '-A', cwd=other)
            self.g('commit', '-qm', 'meanwhile', cwd=other)
            self.g('push', '-q', 'origin', 'dev', cwd=other)
            return True
        with mock.patch.object(assets, 'ask', ask):
            _, text = self.publish()
        self.assertEqual(len(asked), 1, 'the same plan on the new dev: pushed without asking again')
        self.assertIn('dev moved while this was being published; the plan is the same, so pushing again', text)
        self.assertEqual(self.g('log', '--format=%s', 'dev', cwd=self.bare).splitlines(),
                         ['Licensed assets: add legion', 'meanwhile', 'base'])
        self.assertEqual(self.g('show', '--name-only', '--format=', 'dev', cwd=self.bare).splitlines(), ['assets.lock'])
        self.assertEqual(sorted(self.pins()), ['legion'])

    def test_dev_moving_with_another_plan_asks_again(self):
        self.pack_in('Season 1', 'legion', {'m.ymap': b'm'})
        other = self.other_clone()
        asked = []

        def ask(q):
            asked.append(q)
            if len(asked) == 1:
                # Another publish lands first, with a pack these folders lack.
                write(os.path.join(other, 'assets.lock'), assets.dump_lock({'format': 2, 'resources': [
                    {'name': 'emotes', 'seasons': {'1': SHA_C}, 'versions': {SHA_C: version()}}]}))
                self.g('commit', '-qam', 'another publish', cwd=other)
                self.g('push', '-q', 'origin', 'dev', cwd=other)
                return True
            return False
        with mock.patch.object(assets, 'ask', ask):
            _, text = self.publish()
        self.assertEqual(len(asked), 2)
        self.assertIn('the plan above is not the one you answered', text)
        self.assertIn('- emotes: retired', text.split('the plan above is not the one you answered')[0].rsplit('the plan:', 1)[1])
        self.assertEqual(self.subject(), 'another publish', 'answered n the second time: nothing of ours went up')

    def test_a_dev_rewound_during_the_prompt_stays_rewound(self):
        # THE REVIEW'S CASE: dev allows force-pushes, and a purge rewinds it
        # while the owner sits at the prompt. The lock commit, built on the
        # purged commit, still fast-forwards the rewound dev: pushed plainly,
        # GitHub took it and the purged commit came back.
        write(os.path.join(self.shared, 'leak.txt'), 'pretend this is a licensed file\n')
        self.g('add', 'leak.txt')
        self.g('commit', '-qm', 'a leak')
        self.g('push', '-q', 'origin', 'dev')
        leak = self.g('rev-parse', 'HEAD')
        self.pack_in('Season 1', 'legion', {'m.ymap': b'm'})
        asked = []

        def ask(q):
            asked.append(q)
            self.g('update-ref', 'refs/heads/dev', self.base, cwd=self.bare)
            return True
        with mock.patch.object(assets, 'ask', ask):
            _, text = self.publish()
        self.assertEqual(len(asked), 1, 'the same plan on the rewound dev: pushed without asking again')
        self.assertIn('--force-with-lease=refs/heads/dev:%s origin' % leak[:12], text)
        self.assertIn('dev moved while this was being published; the plan is the same, so pushing again', text)
        self.assertIn('pushed to dev', text)
        self.assertEqual(self.g('log', '--format=%s', 'dev', cwd=self.bare).splitlines(),
                         ['Licensed assets: add legion', 'base'])
        r = subprocess.run([GIT_EXE, '-C', self.bare, 'merge-base', '--is-ancestor', leak, 'dev'])
        self.assertEqual(r.returncode, 1, 'the purged commit stays purged')
        self.assertEqual(self.g('show', '--name-only', '--format=', 'dev', cwd=self.bare).splitlines(), ['assets.lock'])

    def test_only_a_fast_forward_of_the_planned_dev_is_pushed(self):
        # The lease lets a push through while dev is still the planned commit;
        # a commit not on top of it would rewrite dev. Refused before git runs.
        self.pack_in('Season 1', 'legion', {'m.ymap': b'm'})
        self.publish('n\n')
        orphan = self.g('commit-tree', self.g('rev-parse', 'dev^{tree}', cwd=self.bare), '-m', 'no parent',
                        cwd=self.clone)
        real = assets.git
        pushes = []

        def git(repo, *args, **kw):
            if args[:1] == ('push',):
                pushes.append(args)
            return real(repo, *args, **kw)
        with mock.patch.object(assets, 'git', git), contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(assets.AssetsError) as cm:
                assets.push_commit(self.clone, self.base, orphan)
        self.assertIn('is not a fast-forward of dev at %s, so it was not pushed' % self.base[:12], str(cm.exception))
        self.assertEqual(pushes, [])
        self.assertEqual(self.g('rev-parse', 'dev', cwd=self.bare), self.base)

    def test_success_is_read_back_from_github(self):
        self.pack_in('Season 1', 'legion', {'m.ymap': b'm'})
        real = assets.git

        def git(repo, *args, **kw):
            if args[:1] == ('push',):
                return types.SimpleNamespace(returncode=0, out='', err='', stdout=b'', stderr=b'')
            return real(repo, *args, **kw)
        with mock.patch.object(assets, 'git', git):
            _, text = self.publish('y\n', expect=1)
        self.assertIn('git push said it worked, but dev on GitHub', text)
        self.assertNotIn('pushed to dev', text)
        self.assertEqual(self.pins(), {})

    def test_the_lock_is_checked_once_more_before_the_push(self):
        self.pack_in('Season 1', 'legion', {'m.ymap': b'm'})
        real = assets.build_commit

        def tampered(clone, base, text, message):
            return real(clone, base, text.replace('"1": "', '"2": "'), message)
        with mock.patch.object(assets, 'build_commit', tampered):
            _, text = self.publish('y\n', expect=1)
        self.assertIn('the commit failed its last check, so nothing was pushed', text)
        self.assertIn('is not the one the plan was made from', text)
        self.assertEqual(self.g('rev-parse', 'dev', cwd=self.bare), self.base)

    def test_refusals(self):
        self.pack_in('Season 1', 'legion', {'m.ymap': b'm'})
        # A drop folder inside a work tree.
        inner = os.path.join(self.shared, 'Blitz Assets')
        shutil.copytree(self.drop, inner)
        with mock.patch.object(sys, 'stdin', io.StringIO('')):
            _, text = self.run_tool('publish', inner, '--clone', self.clone, '--origin', self.bare, expect=1)
        self.assertIn('inside the git work tree', text)
        shutil.rmtree(inner)
        # A --clone that is not empty and not a clone.
        junk = os.path.join(self.tmp, 'junk')
        write(os.path.join(junk, 'x.txt'), b'x')
        with mock.patch.object(sys, 'stdin', io.StringIO('')):
            _, text = self.run_tool('publish', self.drop, '--clone', junk, '--origin', self.bare, expect=1)
        self.assertIn('is not empty and is not a clone', text)
        # A repo resource's name; one resource twice in a season, an empty
        # folder included; an empty folder spelled unlike its pack.
        self.pack_in('Season 1', 'br_core', {'x.lua': b'x'})
        self.pack_in('Season 1/[a]', 'docks', {'d.ymap': b'1'})
        self.pack_in('Season 1/[b]', 'docks', {'d.ymap': b'2'})
        os.makedirs(os.path.join(self.drop, 'Season 1', '[c]', 'legion'))
        os.makedirs(os.path.join(self.drop, 'Season 2', 'LEGION'))
        _, text = self.publish(expect=1)
        self.assertIn('br_core: a resource in this repository already has that name', text)
        self.assertIn('Season 1/[a]/docks and Season 1/[b]/docks are one resource twice in Season 1', text)
        self.assertIn('Season 1/legion and Season 1/[c]/legion are one resource twice in Season 1', text)
        self.assertIn('Season 2/LEGION is spelled legion in a season folder that has the pack', text)
        # No season folder at all would retire everything: refused.
        for d in ('Season 1', 'Season 2'):
            shutil.rmtree(os.path.join(self.drop, d))
        _, text = self.publish(expect=1)
        self.assertIn('no "Season <n>" folder', text)
        # A lock on dev that does not pass check is not built on.
        self.pack_in('Season 1', 'legion', {'m.ymap': b'm'})
        other = self.other_clone()
        write(os.path.join(other, 'assets.lock'), '{"format": 2, "resources": [{"name": "x"}]}\n')
        self.g('commit', '-qam', 'a broken lock', cwd=other)
        self.g('push', '-q', 'origin', 'dev', cwd=other)
        _, text = self.publish(expect=1)
        self.assertIn("dev's assets.lock does not pass check, so nothing can be published on top of it", text)
        self.assertEqual(self.calls(), [], 'no refusal reached the bucket')
        self.assertEqual(self.subject(), 'a broken lock')

    @unittest.skipUnless(os.name == 'nt', 'Publish.cmd is run by cmd.exe')
    def test_publish_cmd_bootstraps_its_clone_and_publishes(self):
        self.pack_in('Season 1', 'legion', {'m.ymap': b'm'})
        # Its own process, on the real clock: made and written an hour ago.
        backdate(self.drop, 3600)
        env = dict(self.env)

        def run(answer):
            r = subprocess.run(['cmd.exe', '/d', '/c', os.path.join(self.drop, 'Publish.cmd')], cwd=self.tmp, env=env,
                               input=answer.encode('ascii'), stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               timeout=600)
            return r.returncode, r.stdout.decode('utf-8', 'replace')
        self.assertFalse(os.path.exists(self.clone))
        rc, out = run('y\r\n\r\n')
        self.assertEqual(rc, 0, out)
        self.assertIn('First Publish here: cloning dev into', out)
        self.assertIn('pushed to dev', out)
        self.assertEqual(sorted(self.pins()), ['legion'])
        self.assertEqual(self.g('config', '--get', 'blitzassets.publishclone', cwd=self.clone), 'true')
        rc, out = run('\r\n\r\n')
        self.assertEqual(rc, 0, out)
        self.assertNotIn('First Publish here', out)
        self.assertIn('nothing to publish', out)


# =============================================================================
# pull
# =============================================================================

class Pull(Box):

    def setUp(self):
        super().setUp()
        self.cfg('set br_season 1\n')

    def push_pack(self, name, files, *extra):
        folder = make_resource(self.src, name, files)
        self.push(folder, *extra)
        return folder

    def installed(self, name):
        return assets.dir_files(os.path.join(self.licensed, name))

    def cfg_lines(self):
        return [l for l in read(os.path.join(self.licensed, 'licensed.cfg')).decode('utf-8').splitlines()
                if not l.startswith('#')]

    def test_pull_installs_in_lock_order(self):
        self.push_pack('zeta_pack', {'stream/z.ytd': b'z' * 300})
        self.push_pack('alpha_pack', {'stream/sub dir/a b.ydr': b'a' * 10})
        self.reset_calls()
        _, text = self.pull()
        self.assertEqual(self.installed('zeta_pack'), {'fxmanifest.lua': M, 'stream/z.ytd': 300})
        self.assertEqual(self.installed('alpha_pack'), {'fxmanifest.lua': M, 'stream/sub dir/a b.ydr': 10})
        self.assertEqual(read(os.path.join(self.licensed, 'zeta_pack', 'stream', 'z.ytd')), b'z' * 300)
        self.assertEqual(self.cfg_lines(), ['ensure zeta_pack', 'ensure alpha_pack'])
        for c in self.calls():
            self.assertNotIn('--profile', c, 'a box pulls with its instance role')
        self.assertEqual(len(self.downloads()), 2)
        self.assertIn('Season 1 (br_season 1, server.cfg:1)', text)
        for path in ('licensed.cfg', 'br_licensed/installed.txt', 'br_licensed/fxmanifest.lua'):
            self.assertNotIn(b'\r', read(os.path.join(self.licensed, *path.split('/'))), path)

    def test_downloads_only_what_is_missing(self):
        self.push_pack('p', {'a.ytd': b'a'})
        self.pull()
        self.reset_calls()
        _, text = self.pull()
        self.assertEqual(self.calls(), [], 'nothing to fetch: not even a head')
        self.assertIn('up to date', text)
        # Gone from resources/ but still cached: reinstalled with no download.
        shutil.rmtree(os.path.join(self.licensed, 'p'))
        _, text = self.pull()
        self.assertEqual(self.calls(), [])
        self.assertIn('(cached)', text)
        self.assertEqual(self.installed('p'), {'fxmanifest.lua': M, 'a.ytd': 1})
        # A file edited in place is noticed and put back.
        write(os.path.join(self.licensed, 'p', 'a.ytd'), b'edited')
        self.pull()
        self.assertEqual(read(os.path.join(self.licensed, 'p', 'a.ytd')), b'a')

    def test_rollback_is_instant(self):
        folder = self.push_pack('p', {'a.ytd': b'v1'})
        v1_lock = read(self.lock)
        self.pull()
        write(os.path.join(folder, 'a.ytd'), b'v2')
        self.push(folder)
        self.pull()
        self.assertEqual(read(os.path.join(self.licensed, 'p', 'a.ytd')), b'v2')
        write(self.lock, v1_lock)   # git revert
        self.reset_calls()
        self.pull()
        self.assertEqual(self.calls(), [], 'the old version came out of the cache')
        self.assertEqual(read(os.path.join(self.licensed, 'p', 'a.ytd')), b'v1')

    def test_season_selection_end_to_end(self):
        legion = self.push_pack('legion', {'m.ymap': b's1'})
        write(os.path.join(legion, 'm.ymap'), b's2')
        self.push(legion, '--season', 2)
        self.push_pack('emotes', {'a.ycd': b'e'}, '--season', 2)
        self.push_pack('old_map', {'o.ymap': b'o'})
        self.run_tool('retire', 'old_map', '--season', 2, '--lock', self.lock)   # a null pin
        self.assertEqual(self.entry('old_map')['seasons'][str(2)], None)

        self.pull()
        self.assertEqual(self.cfg_lines(), ['ensure legion', 'ensure old_map'])
        self.assertEqual(read(os.path.join(self.licensed, 'legion', 'm.ymap')), b's1')

        self.cfg('exec "season.cfg"\n')
        write(os.path.join(self.server, 'season.cfg'), 'setr br_season 2\n')
        _, text = self.pull()
        self.assertEqual(self.cfg_lines(), ['ensure legion', 'ensure emotes'])
        self.assertEqual(read(os.path.join(self.licensed, 'legion', 'm.ymap')), b's2')
        self.assertFalse(os.path.exists(os.path.join(self.licensed, 'old_map')))
        self.assertIn('- old_map (not in force for Season 2)', text)

        record = read(os.path.join(self.licensed, 'br_licensed', 'installed.txt')).decode('utf-8')
        lines = [l for l in record.splitlines() if not l.startswith('#')]
        e = lambda n: self.entry(n)['seasons']
        latest = assets.read_latest()
        self.assertEqual(lines[:3], ['format 1', 'season 2', 'seasons ' + ' '.join(map(str, range(1, latest + 1)))])
        self.assertIn('installed legion %s' % e('legion')['2'], lines)
        self.assertIn('installed emotes %s' % e('emotes')['2'], lines)
        self.assertIn('plan 1 legion %s' % e('legion')['1'], lines)
        self.assertIn('plan 1 old_map %s' % e('old_map')['1'], lines)
        self.assertIn('plan 2 emotes %s' % e('emotes')['2'], lines)
        self.assertNotIn('plan 2 old_map %s' % e('old_map')['1'], lines)

    def test_unset_season_is_the_latest(self):
        self.push_pack('later', {'a.ycd': b'e'}, '--season', assets.read_latest())
        os.remove(os.path.join(self.server, 'server.cfg'))
        _, text = self.pull()
        self.assertIn('br_season is not set: the latest', text)
        self.assertEqual(self.cfg_lines(), ['ensure later'])

    def test_a_bad_archive_aborts_before_unpack_and_changes_nothing(self):
        folder = self.push_pack('p', {'a.ytd': b'good v1'})
        v1 = self.entry('p')['seasons']['1']
        self.pull()
        before = tree(self.licensed)
        # v2 is pinned, but the bucket holds some other archive under its key --
        # one with the SAME file list, paths and sizes, so the sha256 is the
        # only thing that can tell them apart.
        write(os.path.join(folder, 'a.ytd'), b'good v2')
        self.push(folder)
        v2 = self.entry('p')['seasons']['1']
        other = make_resource(self.src, 'other', {'a.ytd': b'evil v2'})
        out = os.path.join(self.tmp, 'other.tar.gz')
        assets.pack(other, out)
        write(self.object_path('p', v2), read(out))

        opened = []
        real_open = tarfile.open

        def spy(*a, **k):
            if k.get('mode', a[1] if len(a) > 1 else 'r').startswith('r'):
                opened.append(a[0] if a else k.get('name'))
            return real_open(*a, **k)

        with mock.patch.object(assets.tarfile, 'open', spy):
            _, text = self.pull(expect=1)
        self.assertIn('does not match assets.lock', text)
        self.assertEqual(opened, [], 'no archive was opened')
        self.assertEqual(tree(self.licensed), before, 'the installed set is untouched')
        cache = os.path.join(self.server, '.assets-cache')
        self.assertEqual(os.listdir(os.path.join(cache, 'p')), [v1 + '.tar.gz'],
                         'the bad archive was neither cached nor left half-written')
        self.assertEqual([n for n in os.listdir(cache) if n.startswith('.staging') or n.startswith('.trash')], [])

    def test_every_archive_opened_has_a_verified_sha(self):
        self.push_pack('a', {'a.ytd': b'a'})
        self.push_pack('b', {'b.ytd': b'b'})
        shas = {e['seasons']['1'] for e in self.lock_data()['resources']}
        events = []
        real_open, real_fetch = tarfile.open, assets.fetch_verified

        def spy_open(*a, **k):
            name = a[0] if a else k.get('name')
            if isinstance(name, str) and k.get('mode', a[1] if len(a) > 1 else 'r').startswith('r'):
                events.append(('unpack', assets.sha256_file(name)[0]))
            return real_open(*a, **k)

        def spy_fetch(get_aws, cache, name, sha, size):
            r = real_fetch(get_aws, cache, name, sha, size)
            events.append(('verified', sha))
            return r

        with mock.patch.object(assets.tarfile, 'open', spy_open), \
                mock.patch.object(assets, 'fetch_verified', spy_fetch):
            self.pull()
        self.assertEqual([k for k, _ in events], ['verified', 'verified', 'unpack', 'unpack'],
                         'every archive is verified before the first is unpacked')
        self.assertEqual({s for k, s in events if k == 'unpack'}, shas, 'and each opened archive hashes to its pin')

    def test_a_corrupt_cache_is_fetched_again(self):
        self.push_pack('p', {'a.ytd': b'a'})
        self.pull()
        sha = self.entry('p')['seasons']['1']
        cached = os.path.join(self.server, '.assets-cache', 'p', sha + '.tar.gz')
        write(cached, b'rot')
        shutil.rmtree(os.path.join(self.licensed, 'p'))
        self.reset_calls()
        _, text = self.pull()
        self.assertIn('does not match its sha256; downloading it again', text)
        self.assertEqual(len(self.downloads()), 1)
        self.assertEqual(assets.sha256_file(cached)[0], sha)

    def test_one_bad_resource_installs_none(self):
        self.push_pack('first', {'a.ytd': b'1'})
        self.pull()
        before = tree(self.licensed)
        self.push_pack('second', {'b.ytd': b'2'})
        self.push_pack('third', {'c.ytd': b'3'})
        # The lock's file list for `third` no longer matches its archive.
        data = self.lock_data()
        third = data['resources'][2]
        third['versions'][third['seasons']['1']]['files']['c.ytd'] = 99
        write(self.lock, assets.dump_lock(data))
        _, text = self.pull(expect=1)
        self.assertIn('differ from the file list', text)
        self.assertEqual(tree(self.licensed), before, '`second` unpacked fine and still was not installed')

    def test_a_failed_download_changes_nothing(self):
        self.push_pack('p', {'a.ytd': b'1'})
        self.pull()
        before = tree(self.licensed)
        self.push_pack('q', {'b.ytd': b'2'})
        self.env['FAKE_AWS_FAIL'] = 'download'
        _, text = self.pull(expect=1)
        self.assertIn('injected download failure', text)
        self.assertEqual(tree(self.licensed), before)

    def test_unsafe_archives_are_refused(self):
        evil = os.path.join(self.tmp, 'evil.tar.gz')
        with gzip.GzipFile(evil, 'wb', mtime=0) as gz, tarfile.open(fileobj=gz, mode='w') as tar:
            for name, data in (('fxmanifest.lua', b'fx'), ('../escaped.txt', b'out')):
                info = tarfile.TarInfo(name)
                info.size = len(data)
                tar.addfile(info, io.BytesIO(data))
        sha, size = assets.sha256_file(evil)
        write(self.object_path('evil', sha), read(evil))
        write(self.lock, assets.dump_lock({'format': 2, 'resources': [
            {'name': 'evil', 'seasons': {'1': sha}, 'versions': {sha: {'size': size, 'files': {'fxmanifest.lua': 2}}}}]}))
        _, text = self.pull(expect=1)
        self.assertIn('"." or ".." segment', text)
        found = [os.path.join(d, f) for d, _, fs in os.walk(self.tmp) for f in fs if f == 'escaped.txt']
        self.assertEqual(found, [])
        self.assertFalse(os.path.exists(os.path.join(self.licensed, 'evil')))

        link = os.path.join(self.tmp, 'link.tar.gz')
        with gzip.GzipFile(link, 'wb', mtime=0) as gz, tarfile.open(fileobj=gz, mode='w') as tar:
            info = tarfile.TarInfo('fxmanifest.lua')
            info.type = tarfile.SYMTYPE
            info.linkname = '/etc/passwd'
            tar.addfile(info)
        sha, size = assets.sha256_file(link)
        write(self.object_path('link', sha), read(link))
        write(self.lock, assets.dump_lock({'format': 2, 'resources': [
            {'name': 'link', 'seasons': {'1': sha}, 'versions': {sha: {'size': size, 'files': {'fxmanifest.lua': 0}}}}]}))
        _, text = self.pull(expect=1)
        self.assertIn('not a regular file', text)

    def test_removal_stays_inside_licensed(self):
        res = os.path.join(self.server, 'resources')
        make_resource(res, os.path.join('[gamemodes]', '[fivem-royale]', 'br_core'), {'server/main.lua': b'x'})
        make_resource(res, os.path.join('[other]', 'stale'), {'a.lua': b'x'})
        make_resource(res, 'stale', {'a.lua': b'x'})
        make_resource(self.licensed, 'stale', {'a.ytd': b'x'})
        write(os.path.join(self.licensed, 'notes.txt'), b'mine')
        write(os.path.join(self.server, 'server.cfg'), 'set br_season 1\n')
        outside = {k: v for k, v in tree(self.server).items() if not k.startswith('resources/[licensed]/')}
        self.push_pack('keep', {'k.ytd': b'k'})
        _, text = self.pull()
        self.assertIn('- stale', text)
        self.assertFalse(os.path.exists(os.path.join(self.licensed, 'stale')))
        self.assertTrue(os.path.isdir(os.path.join(self.licensed, 'keep')))
        self.assertEqual(read(os.path.join(self.licensed, 'notes.txt')), b'mine', 'a file is not a resource')
        after = {k: v for k, v in tree(self.server).items()
                 if not k.startswith('resources/[licensed]/') and not k.startswith('.assets-cache/')}
        self.assertEqual(after, {k: v for k, v in outside.items() if not k.startswith('.assets-cache/')},
                         'nothing outside [licensed] was touched')

    def test_an_emptied_lock_removes_everything_it_installed(self):
        self.push_pack('p', {'a.ytd': b'a'})
        self.pull()
        write(self.lock, assets.dump_lock({'format': 2, 'resources': []}))
        self.pull()
        self.assertFalse(os.path.exists(os.path.join(self.licensed, 'p')))
        self.assertEqual(self.cfg_lines(), [])
        os.remove(self.lock)
        _, text = self.pull()
        self.assertIn('up to date', text, 'an absent lock is an empty one')

    def test_nothing_to_do_creates_nothing(self):
        write(self.lock, assets.dump_lock({'format': 2, 'resources': []}))
        before = tree(self.server)
        _, text = self.pull()
        self.assertIn('nothing to do', text)
        self.assertEqual(tree(self.server), before)

    def test_dry_run_touches_nothing(self):
        self.push_pack('p', {'a.ytd': b'a'})
        self.pull()
        self.push_pack('q', {'b.ytd': b'b'})
        make_resource(self.licensed, 'stale', {'s.ytd': b's'})
        before = tree(self.server)
        self.reset_calls()
        _, text = self.pull('--dry-run')
        self.assertEqual(tree(self.server), before)
        self.assertEqual(self.calls(), [])
        self.assertIn('= p', text)
        self.assertIn('+ q', text)
        self.assertIn('to download', text)
        self.assertIn('- stale', text)
        self.assertIn('dry run', text)

    def test_crlf_lock_and_cfg(self):
        self.push_pack('p', {'a.ytd': b'a'})
        write(self.lock, read(self.lock).replace(b'\n', b'\r\n'))
        self.cfg('# box\r\nset br_season 1\r\n')
        self.run_cli('pull', '--lock', self.lock, '--server-root', self.server)
        self.assertEqual(self.cfg_lines(), ['ensure p'])
        self.assertNotIn(b'\r', read(os.path.join(self.licensed, 'licensed.cfg')))

    # -- stage, then swap (#391 round 2) ------------------------------------

    @property
    def cache(self):
        return os.path.join(self.server, '.assets-cache')

    @property
    def staged(self):
        return os.path.join(self.cache, '.staged')

    def cache_dirs(self, prefix):
        return [n for n in os.listdir(self.cache) if n.startswith(prefix)] if os.path.isdir(self.cache) else []

    def test_stage_changes_nothing_installed_and_swap_puts_it_in(self):
        folder = self.push_pack('p', {'a.ytd': b'v1'})
        self.push_pack('gone', {'g.ytd': b'g'})
        self.pull()
        write(os.path.join(folder, 'a.ytd'), b'v2')
        self.push(folder)
        data = self.lock_data()
        data['resources'] = [e for e in data['resources'] if e['name'] != 'gone']
        write(self.lock, assets.dump_lock(data))
        before = tree(self.licensed)
        _, text = self.pull('--stage')
        self.assertEqual(tree(self.licensed), before, '--stage changed nothing installed')
        self.assertIn('nothing installed has changed yet', text)
        self.assertEqual(read(os.path.join(self.staged, 'p', 'a.ytd')), b'v2')
        self.reset_calls()
        _, text = self.pull('--swap')
        self.assertEqual(self.calls(), [], 'the swap downloads nothing')
        self.assertEqual(read(os.path.join(self.licensed, 'p', 'a.ytd')), b'v2')
        self.assertFalse(os.path.exists(os.path.join(self.licensed, 'gone')))
        self.assertEqual(self.cfg_lines(), ['ensure p'])
        self.assertFalse(os.path.exists(self.staged))
        self.assertEqual(self.cache_dirs('.trash-'), [])

    def test_swap_refuses_without_a_matching_stage(self):
        folder = self.push_pack('p', {'a.ytd': b'v1'})
        self.pull()
        write(os.path.join(folder, 'a.ytd'), b'v2')
        self.push(folder)
        before = tree(self.licensed)
        _, text = self.pull('--swap', expect=1)
        self.assertIn('nothing is staged', text)
        self.assertEqual(tree(self.licensed), before)
        # Staged for one lock, swapped under another.
        self.pull('--stage')
        write(os.path.join(folder, 'a.ytd'), b'v3')
        self.push(folder)
        _, text = self.pull('--swap', expect=1)
        self.assertIn('not what assets.lock asks for now', text)
        self.assertEqual(tree(self.licensed), before)
        # An up-to-date swap is fine with nothing staged.
        self.pull()
        _, text = self.pull('--swap')
        self.assertIn('up to date', text)

    # -- rollback ------------------------------------------------------------

    def content(self, root):
        """tree() without mtimes: a restored file is rewritten, so its bytes
        are what has to match."""
        return {k: (v[0], v[2]) if v else v for k, v in tree(root).items()}

    def two_sets(self):
        """Installed: a and b at v1, and c. The lock then wants a and b at v2,
        a new d, and no c -- every kind of rename a swap makes."""
        fa = self.push_pack('a', {'a.ytd': b'a1'})
        fb = self.push_pack('b', {'b.ytd': b'b1'})
        self.push_pack('c', {'c.ytd': b'c1'})
        self.pull()
        old = self.content(self.licensed)
        write(os.path.join(fa, 'a.ytd'), b'a2')
        write(os.path.join(fb, 'b.ytd'), b'b2')
        self.push(fa)
        self.push(fb)
        self.push_pack('d', {'d.ytd': b'd1'})
        data = self.lock_data()
        data['resources'] = [e for e in data['resources'] if e['name'] != 'c']
        write(self.lock, assets.dump_lock(data))
        self.pull('--stage')
        return old

    def failing(self, fail_at=(), undo_fail=None, exc=OSError):
        """os.rename that raises on the forward calls numbered in `fail_at`,
        and on the undo of the rename whose source ends with `undo_fail`."""
        real = os.rename
        n = [0]

        def rename(a, b):
            n[0] += 1
            if n[0] in fail_at:
                raise exc(13, 'injected rename failure')
            if undo_fail and str(b).replace('\\', '/').endswith(undo_fail):
                raise OSError(13, 'injected undo failure')
            return real(a, b)
        return mock.patch.object(assets.os, 'rename', rename)

    def test_a_failure_at_every_rename_restores_the_old_set_exactly(self):
        old = self.two_sets()
        staged = self.content(self.staged)
        # c out, a out, a in, b out, b in, d in: six renames, then the writes.
        for k in range(1, 7):
            with self.failing(fail_at=(k,)):
                _, text = self.pull('--swap', expect=1)
            self.assertIn('injected rename failure', text)
            self.assertEqual(self.content(self.licensed), old, 'failure at rename %d' % k)
            self.assertEqual(self.content(self.staged), staged, 'and the staged set is whole again')
            self.assertEqual(self.cache_dirs('.trash-'), [], 'an undone trash dir is deleted')
        real_write = assets.atomic_write

        def bad_cfg(path, text):
            if path.endswith('licensed.cfg'):
                raise OSError(28, 'injected: no space left')
            return real_write(path, text)
        with mock.patch.object(assets, 'atomic_write', bad_cfg):
            self.pull('--swap', expect=1)
        self.assertEqual(self.content(self.licensed), old, 'a failed write after the renames is undone too')
        self.pull('--swap')
        self.assertEqual(read(os.path.join(self.licensed, 'a', 'a.ytd')), b'a2')
        self.assertEqual(self.cfg_lines(), ['ensure a', 'ensure b', 'ensure d'])

    def test_a_failed_undo_deletes_nothing_and_says_where_everything_is(self):
        self.two_sets()
        # Rename 4 (b out) fails; undoing rename 3 (a in) fails too.
        with self.failing(fail_at=(4,), undo_fail='/.staged/a'):
            _, text = self.pull('--swap', expect=1)
        self.assertIn('NOTHING WAS DELETED', text)
        trash = self.cache_dirs('.trash-')
        self.assertEqual(len(trash), 1, 'the trash dir is kept')
        trash = os.path.join(self.cache, trash[0])
        self.assertEqual(read(os.path.join(trash, 'a', 'a.ytd')), b'a1', 'holding the old a')
        self.assertIn('%s  belongs at  %s' % (os.path.join(trash, 'a'), os.path.join(self.licensed, 'a')), text)
        # [licensed] is the new a, the old b, and c (both undone), and the
        # record and licensed.cfg say exactly that.
        self.assertEqual(read(os.path.join(self.licensed, 'a', 'a.ytd')), b'a2')
        self.assertEqual(read(os.path.join(self.licensed, 'b', 'b.ytd')), b'b1')
        self.assertEqual(sorted(assets.installed_dirs(self.licensed)), ['a', 'b', 'c'])
        self.assertEqual(sorted(self.cfg_lines()), ['ensure a', 'ensure b', 'ensure c'])
        rec = assets.read_record(self.licensed)
        lock = {e['name']: e['seasons']['1'] for e in self.lock_data()['resources']}
        self.assertEqual(rec['a'], lock['a'], 'the record names the new a')
        self.assertNotEqual(rec['b'], lock['b'], 'and the old b')
        self.assertIn('c', rec)
        # Whatever stopped it is fixed: the next pull retries the undo first,
        # then swaps, and the trash goes.
        self.pull('--swap')
        self.assertEqual(self.cache_dirs('.trash-'), [])
        self.assertEqual(self.cfg_lines(), ['ensure a', 'ensure b', 'ensure d'])
        self.assertEqual(read(os.path.join(self.licensed, 'b', 'b.ytd')), b'b2')

    def test_a_killed_swap_is_undone_by_the_next_pull(self):
        class Killed(BaseException):
            pass

        old = self.two_sets()
        staged = self.content(self.staged)
        real_write = assets.atomic_write

        def killed_at_cfg(path, text):
            if path.endswith('licensed.cfg'):
                raise Killed()
            return real_write(path, text)

        # Killed after 1..5 of the six renames, after all six, and after the
        # record but before licensed.cfg. No in-process undo runs at all.
        for k in list(range(2, 7)) + [None]:
            with contextlib.ExitStack() as stack:
                if k is None:
                    stack.enter_context(mock.patch.object(assets, 'atomic_write', killed_at_cfg))
                else:
                    stack.enter_context(self.failing(fail_at=(k,), exc=lambda *a: Killed()))
                stack.enter_context(mock.patch.object(assets, 'rollback', mock.Mock(side_effect=Killed())))
                with self.assertRaises(Killed):
                    self.pull('--swap')
            self.assertEqual(len(self.cache_dirs('.trash-')), 1, 'killed at %s: the trash is left' % k)
            _, text = self.pull('--stage')
            self.assertIn('undid a swap that did not finish', text)
            self.assertEqual(self.content(self.licensed), old, 'killed at %s' % k)
            self.assertEqual(self.content(self.staged), staged)
            self.assertEqual(self.cache_dirs('.trash-'), [])

    def test_leftovers_are_cleaned_but_a_lone_copy_is_never_deleted(self):
        self.push_pack('p', {'a.ytd': b'1'})
        self.pull()
        sha = self.entry('p')['seasons']['1']
        write(os.path.join(self.cache, '.staging-dead', 'p', 'a.ytd'), b'half')
        write(os.path.join(self.cache, 'p', sha + '.tar.gz.part-99'), b'half')
        # A trash dir with no journal, holding a resource [licensed] lacks.
        make_resource(os.path.join(self.cache, '.trash-old'), 'lost', {'l.ytd': b'only copy'})
        _, text = self.pull()
        self.assertEqual(self.cache_dirs('.staging-'), [])
        self.assertFalse(os.path.exists(os.path.join(self.cache, 'p', sha + '.tar.gz.part-99')))
        self.assertIn('put back lost', text)
        self.assertEqual(self.cache_dirs('.trash-'), [])
        # ...and then removed by the plan like any other stale resource, which
        # is the lock's call to make, not the cleanup's.
        self.assertIn('- lost', text)
        # One [licensed] already has: refused, nothing deleted.
        make_resource(os.path.join(self.cache, '.trash-old'), 'p', {'x.ytd': b'which one?'})
        _, text = self.pull(expect=1)
        self.assertIn('Nothing was deleted', text)
        self.assertEqual(read(os.path.join(self.cache, '.trash-old', 'p', 'x.ytd')), b'which one?')

    def test_a_dry_run_leaves_leftovers_for_the_next_pull(self):
        self.two_sets()
        with self.failing(fail_at=(4,), undo_fail='/.staged/a'):
            self.pull('--swap', expect=1)
        before = tree(self.server)
        _, text = self.pull('--dry-run')
        self.assertIn('the next pull recovers it', text)
        self.assertEqual(tree(self.server), before)

    # -- housekeeping --------------------------------------------------------

    def test_staged_files_and_dirs_are_synced_before_the_first_swap_rename(self):
        self.push_pack('p', {'stream/a.ytd': b'a', 'stream/deep/b.ydr': b'b'})
        events = []
        real_rename = os.rename
        norm = lambda p: os.path.normcase(os.path.normpath(p))

        def rename(a, b):
            events.append(('rename', norm(a), norm(b)))
            return real_rename(a, b)
        with mock.patch.object(assets, 'fsync_file', lambda p: events.append(('file', norm(p)))), \
                mock.patch.object(assets, 'fsync_dir', lambda p: events.append(('dir', norm(p)))), \
                mock.patch.object(assets.os, 'rename', rename):
            self.pull()
        lic = norm(self.licensed) + os.sep
        first = next(i for i, e in enumerate(events) if e[0] == 'rename' and e[2].startswith(lic))
        before = set(events[:first])
        # The staging dir was renamed to .staged once it was whole and synced.
        root = next(e[1] for e in events if e[0] == 'rename' and e[2] == norm(self.staged))
        for rel in ('p/fxmanifest.lua', 'p/stream/a.ytd', 'p/stream/deep/b.ydr', 'stage.json'):
            self.assertIn(('file', norm(os.path.join(root, rel))), before, rel)
        for rel in ('.', 'p', 'p/stream', 'p/stream/deep'):
            self.assertIn(('dir', norm(os.path.join(root, rel))), before, 'directory ' + rel)
        self.assertIn(('dir', norm(self.cache)), before, 'the rename to .staged, synced')
        self.assertTrue(any(e[0] == 'dir' and os.path.basename(e[1]).startswith('.trash-') for e in before),
                        'the journal is on disk before the first rename')

    def test_a_same_named_resource_elsewhere_refuses_the_pull(self):
        other = make_resource(os.path.join(self.server, 'resources', '[maps]'), 'legion', {'x.ymap': b'x'})
        self.push_pack('legion', {'m.ymap': b'm'})
        _, text = self.pull('--dry-run', expect=1)
        self.assertIn(other, text)
        _, text = self.pull(expect=1)
        self.assertIn(other, text)
        self.assertIn('two resources with one name', text)
        self.assertFalse(os.path.exists(self.licensed))
        self.assertEqual(self.downloads(), [])

    def test_the_cache_drops_only_unnamed_archives_unused_for_14_days(self):
        folder = self.push_pack('p', {'a.ytd': b'v1'})
        self.pull()
        v1 = self.entry('p')['seasons']['1']
        write(os.path.join(folder, 'a.ytd'), b'v2')
        self.push(folder)
        self.pull()
        v2 = self.entry('p')['seasons']['1']
        # Named by the lock for a later season, never in force here, old.
        later = self.push_pack('later', {'l.ytd': b'l'}, '--season', 3)
        lsha = self.entry('later')['seasons']['3']
        out = os.path.join(self.tmp, 'later.tar.gz')
        assets.pack(later, out)
        write(os.path.join(self.cache, 'later', lsha + '.tar.gz'), read(out))
        # Named by nothing, never recorded, downloaded long ago.
        ghost = os.path.join(self.cache, 'ghost', 'f' * 64 + '.tar.gz')
        write(ghost, b'x')
        long_ago = 1_000_000_000
        # v1 too: downloaded long ago, but in force until today. Its recorded
        # last use, not its file time, is what counts.
        for path in (ghost, os.path.join(self.cache, 'later', lsha + '.tar.gz'),
                     os.path.join(self.cache, 'p', v1 + '.tar.gz')):
            os.utime(path, (long_ago, long_ago))
        cached = lambda name, sha: os.path.isfile(os.path.join(self.cache, name, sha + '.tar.gz'))
        now = __import__('time').time()
        with mock.patch.object(assets.time, 'time', return_value=now + 13 * 86400):
            self.pull()
        self.assertTrue(cached('p', v1), 'v1 was in force 13 days ago: kept')
        self.assertFalse(os.path.exists(ghost), 'never recorded and old: dropped')
        with mock.patch.object(assets.time, 'time', return_value=now + 15 * 86400):
            _, text = self.pull()
        self.assertFalse(cached('p', v1), 'v1: named by nothing, out of force for 15 days')
        self.assertIn('pruned p/%s' % v1, text)
        self.assertTrue(cached('p', v2), 'the version in force stays')
        self.assertTrue(cached('later', lsha), 'a version the lock names stays, however old')
        used = json.loads(read(os.path.join(self.cache, '.last-used.json')).decode('utf-8'))
        self.assertNotIn('p/' + v1, used)
        self.assertIn('p/' + v2, used)

    def test_status(self):
        self.push_pack('p', {'a.ytd': b'a'})
        self.pull()
        _, text = self.run_tool('status', '--lock', self.lock, '--server-root', self.server)
        self.assertIn('in the bucket, cached, installed', text)
        self.assertIn('this box: Season 1', text)
        before = tree(self.server)
        os.remove(self.object_path('p', self.entry('p')['seasons']['1']))
        _, text = self.run_tool('status', '--lock', self.lock, '--server-root', self.server, expect=1)
        self.assertIn('MISSING from the bucket', text)
        _, text = self.run_tool('status', '--lock', self.lock, '--offline')
        self.assertNotIn('bucket', text.split('\n', 1)[1])
        self.assertEqual(tree(self.server), before, 'status is read-only')
        # A null pin reads as what it is.
        self.run_tool('retire', 'p', '--season', 2, '--lock', self.lock)
        _, text = self.run_tool('status', '--lock', self.lock, '--offline')
        self.assertIn('Season 2: removed, not installed from this season on', text)
        # And a version a failed swap could not record is said in words.
        rec = os.path.join(self.licensed, 'br_licensed', 'installed.txt')
        write(rec, read(rec).replace(('installed p ' + self.entry('p')['seasons']['1']).encode(), b'installed p unknown'))
        _, text = self.run_tool('status', '--lock', self.lock, '--server-root', self.server, '--offline')
        self.assertIn('installed at a version a failed swap could not record', text)
        self.assertNotIn('installed unknown', text)


# =============================================================================
# deploy.sh, with the pull stubbed
# =============================================================================

def find_bash():
    """A POSIX bash with sed, grep and find beside it: Git Bash's on Windows,
    never System32's, which is WSL's launcher."""
    found = shutil.which('bash')
    if os.name != 'nt':
        return found
    candidates = [found] if found else []
    candidates += [r'C:\Program Files\Git\usr\bin\bash.exe', r'C:\Program Files\Git\bin\bash.exe']
    for c in candidates:
        if c and os.path.isfile(c) and 'system32' not in c.lower() and 'windowsapps' not in c.lower():
            return c
    return None


BASH = find_bash()
GIT = shutil.which('git')

FAKE_RSYNC = r'''#!/usr/bin/env bash
# test_assets.py's rsync: logs where it was pointed, copies unless --dry-run.
printf 'ARGS %s\n' "$*" >> "$FAKE_RSYNC_LOG"
dry=0; skip=0; pos=()
for a in "$@"; do
    if [ "$skip" -eq 1 ]; then skip=0; continue; fi
    case "$a" in
        --dry-run) dry=1 ;;
        --exclude) skip=1 ;;
        -*) ;;
        *) pos+=("$a") ;;
    esac
done
printf 'DEST %s\n' "${pos[1]}" >> "$FAKE_RSYNC_LOG"
[ "$dry" -eq 1 ] && exit 0
mkdir -p "${pos[1]}" && cp -R "${pos[0]}." "${pos[1]}"
'''

FAKE_PULL = r'''import json, os, sys
with open(os.environ['FAKE_PULL_LOG'], 'a', encoding='utf-8') as fh:
    fh.write(json.dumps(sys.argv[1:]) + '\n')
mode = 'swap' if '--swap' in sys.argv else ('stage' if '--stage' in sys.argv else 'plan')
print('stub pull ran: ' + mode)
sys.exit(int(os.environ.get('FAKE_SWAP_RC' if mode == 'swap' else 'FAKE_PULL_RC', '0')))
'''

LISTING_LOCK = json.dumps({'format': 2, 'resources': [
    {'name': 'legion', 'seasons': {'1': SHA_A}, 'versions': {SHA_A: version()}}]}, indent=2) + '\n'


@unittest.skipUnless(BASH and GIT, 'needs bash and git')
class Deploy(unittest.TestCase):
    """tools/deploy.sh run for real against a local bare repo, with rsync and
    the clone's tools/assets.py replaced by stubs that log what they were
    asked. What is pinned is deploy.sh's half: when the pull runs, that its
    failure stops the deploy before the code sync, that an empty lock is
    today's deploy, that a dry run changes nothing, and that no rsync is ever
    pointed into resources/[licensed]/."""

    @classmethod
    def git(cls, *args, cwd=None):
        r = subprocess.run([GIT, '-c', 'user.name=t', '-c', 'user.email=t@t', '-c', 'core.autocrlf=false',
                            '-c', 'init.defaultBranch=main'] + list(args),
                           cwd=cwd or cls.work, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if r.returncode != 0:
            raise AssertionError('git %s: %s' % (' '.join(args), r.stdout.decode('utf-8', 'replace')))

    @classmethod
    def setUpClass(cls):
        # ONE ORIGIN FOR THE CLASS: process creation is what costs on Windows,
        # and every test sets the lock it needs before it deploys.
        top = tempfile.mkdtemp(prefix='assets-deploy-')
        cls.addClassCleanup(shutil.rmtree, top, True)
        cls.base = os.path.join(top, 'William Montgomery')
        cls.work = os.path.join(cls.base, 'work')
        cls.bare = os.path.join(cls.base, 'origin.git')
        cls.bin = os.path.join(cls.base, 'fake bin')
        write(os.path.join(cls.bin, 'rsync'), FAKE_RSYNC)
        os.chmod(os.path.join(cls.bin, 'rsync'), 0o755)

        g = os.path.join(cls.work, 'resources', '[fivem-royale]')
        for r in ('br_lib', 'br_core', 'br_ui'):
            write(os.path.join(g, r, 'fxmanifest.lua'), MANIFEST)
        write(os.path.join(g, 'br_ui', 'ui', 'index.html'), '<html></html>\n')
        write(os.path.join(g, 'br_ui', 'ui', 'assets', 'app.js'), '1\n')
        for v in ('[voice]/pma-voice', '[scaleformui]/ScaleformUI_Assets', '[scaleformui]/ScaleformUI_Lua',
                  '[computer]/cuchi_computer'):
            write(os.path.join(cls.work, 'resources', *v.split('/'), 'fxmanifest.lua'), MANIFEST)
        write(os.path.join(cls.work, 'tools', 'dispatch.sh'), '#!/bin/sh\n')
        write(os.path.join(cls.work, 'tools', 'assets.py'), FAKE_PULL)
        cls.git('init', '-q', '-b', 'main')
        cls.git('add', '-A')
        cls.git('update-index', '--chmod=+x', 'tools/dispatch.sh')
        cls.git('commit', '-q', '-m', 'base')
        cls.git('init', '-q', '--bare', '-b', 'main', cls.bare, cwd=cls.base)
        cls.git('push', '-q', cls.bare, 'main')

    def setUp(self):
        run = tempfile.mkdtemp(prefix='run ', dir=self.base)
        self.server = os.path.join(run, 'server root')
        self.rsync_log = os.path.join(run, 'rsync.log')
        self.pull_log = os.path.join(run, 'pull.log')
        os.makedirs(os.path.join(self.server, 'resources'))
        for p in (self.rsync_log, self.pull_log):
            write(p, b'')

    def set_lock(self, text):
        """The lock the next deploy fetches; None deletes it."""
        path = os.path.join(self.work, 'assets.lock')
        if text is None:
            if os.path.exists(path):
                self.git('rm', '-q', 'assets.lock')
        else:
            write(path, text)
            self.git('add', 'assets.lock')
        self.git('commit', '-q', '--allow-empty', '-m', 'lock')
        self.git('push', '-q', self.bare, 'main')

    def deploy(self, *args, pull_rc=0, swap_rc=0, extra_env=None):
        env = dict(os.environ)
        env.update({
            'PATH': self.bin + os.pathsep + os.path.dirname(BASH) + os.pathsep + env.get('PATH', ''),
            'BR_REPO': self.bare.replace('\\', '/'),
            'BR_SERVER_ROOT': self.server.replace('\\', '/'),
            'BR_BRANCH': 'main',
            'BR_PYTHON': sys.executable.replace('\\', '/'),
            'FAKE_RSYNC_LOG': self.rsync_log,
            'FAKE_PULL_LOG': self.pull_log,
            'FAKE_PULL_RC': str(pull_rc),
            'FAKE_SWAP_RC': str(swap_rc),
        })
        env.update(extra_env or {})
        r = subprocess.run([BASH, os.path.join(TOOLS, 'deploy.sh')] + list(args), env=env,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        return r.returncode, r.stdout.decode('utf-8', 'replace')

    def pulls(self):
        with open(self.pull_log, encoding='utf-8') as fh:
            return [json.loads(l) for l in fh if l.strip()]

    def rsync_dests(self):
        with open(self.rsync_log, encoding='utf-8') as fh:
            return [l[5:].rstrip('\n') for l in fh if l.startswith('DEST ')]

    def served(self):
        """Every file under the server root but the clone deploy.sh keeps."""
        return tree(self.server, skip=('.gamemode-src',))

    def sentinel(self):
        path = os.path.join(self.server, 'resources', '[licensed]', 'legion', 'stream', 'keep.ytd')
        write(path, b'licensed bytes')
        return path

    def test_an_empty_or_absent_lock_is_todays_deploy(self):
        for lock in ('{\n  "format": 2,\n  "resources": []\n}\n', None):
            self.set_lock(lock)
            rc, out = self.deploy()
            self.assertEqual(rc, 0, out)
            self.assertIn('deployed', out)
            self.assertEqual(self.pulls(), [], 'no Python ran')
            self.assertNotIn('licensed', out)
            self.assertFalse(os.path.exists(os.path.join(self.server, 'resources', '[licensed]')))

    def stamp(self):
        return os.path.join(self.server, 'resources', '[gamemodes]', '[fivem-royale]', 'br_core', 'served-commit')

    def test_the_pull_runs_and_licensed_is_never_synced_into(self):
        self.set_lock(LISTING_LOCK)
        keep = self.sentinel()
        rc, out = self.deploy()
        self.assertEqual(rc, 0, out)
        root = self.server.replace('\\', '/')
        self.assertEqual(self.pulls(), [['pull', '--stage', '--server-root', root],
                                        ['pull', '--swap', '--server-root', root]])
        self.assertIn('(licensed, from assets.lock', out)
        dests = self.rsync_dests()
        self.assertEqual(len(dests), 5, dests)
        for d in dests:
            self.assertNotIn('[licensed]', d)
        self.assertEqual(read(keep), b'licensed bytes')
        self.assertTrue(os.path.isfile(self.stamp()))
        # New assets must never sit under old code: the stage (which can fail
        # for reasons off this box) runs first, the swap only once the code
        # and every vendored resource are synced, and the stamp after it.
        at = [out.index('stub pull ran: stage'), out.index('syncing [fivem-royale]'),
              out.index('syncing [voice]/pma-voice'), out.index('syncing [scaleformui]/ScaleformUI_Lua'),
              out.index('stub pull ran: swap'), out.index('\x1b[32mdeployed')]
        self.assertEqual(at, sorted(at), out)

    def test_a_failed_swap_dies_with_no_stamp_and_no_success(self):
        self.set_lock(LISTING_LOCK)
        keep = self.sentinel()
        rc, out = self.deploy(swap_rc=1)
        self.assertNotEqual(rc, 0, out)
        self.assertIn('licensed asset swap failed', out)
        self.assertIn('has not been restarted', out)
        self.assertNotIn('\x1b[32mdeployed', out, 'no success line, so no restart')
        self.assertEqual(len(self.rsync_dests()), 5, 'the swap runs after every sync')
        self.assertFalse(os.path.exists(self.stamp()), 'no served-commit stamp for a deploy that died')
        self.assertEqual(read(keep), b'licensed bytes')

    def test_a_failed_pull_stops_the_deploy_before_the_sync(self):
        self.set_lock(LISTING_LOCK)
        keep = self.sentinel()
        before = self.served()
        rc, out = self.deploy(pull_rc=1)
        self.assertNotEqual(rc, 0, out)
        self.assertIn('licensed asset pull failed', out)
        self.assertIn('nothing has been deployed', out)
        self.assertNotIn('\x1b[32mdeployed', out, 'no success line')
        self.assertEqual(self.rsync_dests(), [], 'no code was synced')
        self.assertEqual([p[1] for p in self.pulls()], ['--stage'], 'and nothing was swapped')
        self.assertEqual(self.served(), before)
        self.assertEqual(read(keep), b'licensed bytes')

    def test_a_ref_from_before_391_leaves_licensed_alone(self):
        # Deploying a ref with no tools/assets.py while something is installed:
        # warn, deploy the code, touch nothing in [licensed].
        self.set_lock(LISTING_LOCK)
        keep = self.sentinel()
        write(os.path.join(self.server, 'resources', '[licensed]', 'br_licensed', 'installed.txt'), 'format 1\n')
        self.git('rm', '-q', 'tools/assets.py')
        self.git('commit', '-q', '-m', 'before 391')
        self.git('push', '-q', self.bare, 'main')

        def restore():
            self.git('checkout', 'HEAD~1', '--', 'tools/assets.py')
            self.git('commit', '-q', '-m', 'restore')
            self.git('push', '-q', self.bare, 'main')
        self.addCleanup(restore)
        lic = os.path.join(self.server, 'resources', '[licensed]')
        before = tree(lic)
        rc, out = self.deploy()
        self.assertEqual(rc, 0, out)
        self.assertIn('has no tools/assets.py (it predates #391)', out)
        self.assertIn('\x1b[32mdeployed', out)
        self.assertEqual(self.pulls(), [])
        self.assertEqual(tree(lic), before)
        self.assertEqual(read(keep), b'licensed bytes')
        rc, out = self.deploy('--status')
        self.assertEqual(rc, 0, out)
        self.assertIn('predates #391', out)

    def test_a_dry_run_touches_nothing(self):
        self.set_lock(LISTING_LOCK)
        self.sentinel()
        before = self.served()
        rc, out = self.deploy('--dry-run')
        self.assertEqual(rc, 0, out)
        root = self.server.replace('\\', '/')
        self.assertEqual(self.pulls(), [['pull', '--dry-run', '--server-root', root]])
        self.assertEqual({k: v for k, v in self.served().items() if not k.endswith('/')},
                         {k: v for k, v in before.items() if not k.endswith('/')})
        self.assertIn('dry run -- nothing was changed', out)

    def test_something_installed_is_reconciled_even_with_no_lock(self):
        self.set_lock(None)
        write(os.path.join(self.server, 'resources', '[licensed]', 'br_licensed', 'installed.txt'), 'format 1\n')
        rc, out = self.deploy('--status')
        self.assertEqual(rc, 0, out)
        root = self.server.replace('\\', '/')
        self.assertEqual(self.pulls(), [['pull', '--dry-run', '--server-root', root]])
        self.assertIn('licensed: ' + root + '/resources/[licensed]', out)
        rc, out = self.deploy()
        self.assertEqual(rc, 0, out)
        self.assertEqual(self.pulls()[-2:], [['pull', '--stage', '--server-root', root],
                                             ['pull', '--swap', '--server-root', root]])

    def test_licensed_cannot_be_a_sync_target(self):
        self.set_lock(LISTING_LOCK)
        keep = self.sentinel()
        rc, out = self.deploy(extra_env={'BR_TARGET_CATEGORY': '[licensed]'})
        self.assertNotEqual(rc, 0, out)
        self.assertIn('belongs to tools/assets.py', out)
        self.assertEqual(self.rsync_dests(), [])
        self.assertEqual(self.pulls(), [])
        self.assertEqual(read(keep), b'licensed bytes')


# =============================================================================
# tools/check_asset_files.sh, the gate that keeps packs out of the repo
# =============================================================================

@unittest.skipUnless(BASH and GIT, 'needs bash and git')
class AssetFileGate(unittest.TestCase):
    """The real gate, copied into a scratch repository that holds every
    allowlisted file and then whatever each test adds."""

    def setUp(self):
        top = tempfile.mkdtemp(prefix='assets-gate-')
        self.addCleanup(shutil.rmtree, top, True)
        self.repo = os.path.join(top, 'William Montgomery', 'repo')
        script = read(os.path.join(TOOLS, 'check_asset_files.sh')).decode('utf-8')
        block = script[script.index('ALLOW=('):script.index('\n)\n')]
        self.allow = re.findall(r'^\s*"([^"]+)"', block, re.M)
        self.assertGreaterEqual(len(self.allow), 8)
        write(os.path.join(self.repo, 'tools', 'check_asset_files.sh'), script)
        write(os.path.join(self.repo, '.gitignore'), read(os.path.join(REPO, '.gitignore')))
        for path in self.allow:
            write(os.path.join(self.repo, *path.split('/')), b'ours')
        self.git('init', '-q')
        self.git('add', '-A')

    def git(self, *args):
        r = subprocess.run([GIT, '-c', 'core.autocrlf=false'] + list(args), cwd=self.repo,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.assertEqual(r.returncode, 0, r.stdout.decode('utf-8', 'replace'))

    def gate(self):
        r = subprocess.run([BASH, 'tools/check_asset_files.sh'], cwd=self.repo,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        return r.returncode, r.stdout.decode('utf-8', 'replace')

    def test_the_allowlist_alone_passes(self):
        rc, out = self.gate()
        self.assertEqual(rc, 0, out)
        self.assertIn('8-file allowlist', out)

    def test_a_pack_anywhere_fails(self):
        write(os.path.join(self.repo, 'resources', '[maps]', 'legion', 'stream', 'Legion.YTD'), b'x')
        write(os.path.join(self.repo, 'docs', 'pack.fxap'), b'x')
        write(os.path.join(self.repo, 'NTeam Legion.zip'), b'x')
        self.git('add', 'resources')
        rc, out = self.gate()
        self.assertEqual(rc, 1, out)
        for path in ('resources/[maps]/legion/stream/Legion.YTD', 'docs/pack.fxap', 'NTeam Legion.zip'):
            self.assertIn('ASSET\x1b[0m ' + path, out)
        self.assertIn('3 game-asset file(s)', out)

    def test_pulled_assets_in_a_checkout_pass(self):
        write(os.path.join(self.repo, 'resources', '[licensed]', 'legion', 'stream', 'a.ytd'), b'x')
        write(os.path.join(self.repo, '.assets-cache', 'legion', 'x.tar.gz'), b'x')
        rc, out = self.gate()
        self.assertEqual(rc, 0, out)

    def test_a_stale_allowlist_row_fails(self):
        os.remove(os.path.join(self.repo, *self.allow[0].split('/')))
        self.git('add', '-A')
        rc, out = self.gate()
        self.assertEqual(rc, 1, out)
        self.assertIn('allowlisted but not in the repo: ' + self.allow[0], out)

    def test_the_real_repo_passes(self):
        r = subprocess.run([BASH, os.path.join(TOOLS, 'check_asset_files.sh')], cwd=REPO,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.assertEqual(r.returncode, 0, r.stdout.decode('utf-8', 'replace'))

    def test_archives_data_files_and_copies_fail(self):
        # (x.ydr~ is gitignored here, so only a forced add reaches git: the --revs test has one.)
        bad = ['stream/Legion.ytd.bak', 'x.YMAP.old', 'pack.tar', 'pack.tar.xz', 'p.bz2', 'p.zst',
               'p.zstd', 'p.lz4', 'p.txz', 'p.tbz2', 'data/handling.meta', 'data/water.dat', 'audio/x.dat151.rel',
               'audio/y.dat54', 'old.fxap.orig']
        good = ['src/metadata.json', 'docs/data.md', 'tools/x.datasource.lua', 'my.target.js', 'rel.lua',
                'stream/readme.txt']
        for path in bad + good:
            write(os.path.join(self.repo, *path.split('/')), b'x')
        rc, out = self.gate()
        self.assertEqual(rc, 1, out)
        for path in bad:
            self.assertIn('ASSET\x1b[0m ' + path, out)
        for path in good:
            self.assertNotIn(path, out)
        self.assertIn('%d game-asset file(s)' % len(bad), out)

    def test_revs_checks_the_commits_history_and_all(self):
        self.git('-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qm', 'base')
        write(os.path.join(self.repo, 'resources', 'x.lua'), b'code')
        self.git('add', '-A')
        self.git('-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qm', 'code')
        r = subprocess.run([BASH, 'tools/check_asset_files.sh', '--revs', 'HEAD~1..HEAD'], cwd=self.repo,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.assertEqual(r.returncode, 0, r.stdout.decode('utf-8', 'replace'))
        # Added in one commit, deleted in the next: the tip is clean, the
        # history a push would publish is not.
        write(os.path.join(self.repo, 'maps', 'legion pack', 'Legion.ytd'), b'x')
        write(os.path.join(self.repo, 'maps', 'legion pack', 'Legion.ydr~'), b'x')
        self.git('add', '-A')
        self.git('add', '-f', 'maps/legion pack/Legion.ydr~')
        self.git('-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qm', 'oops')
        self.git('rm', '-q', 'maps/legion pack/Legion.ytd', 'maps/legion pack/Legion.ydr~')
        self.git('-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qm', 'undo')
        # ...and more code on top, so the pack is in an older commit, not the
        # newest one that adds anything.
        write(os.path.join(self.repo, 'resources', 'y.lua'), b'more code')
        self.git('add', '-A')
        self.git('-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qm', 'more')
        r = subprocess.run([BASH, 'tools/check_asset_files.sh', '--revs', 'HEAD~4..HEAD'], cwd=self.repo,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        out = r.stdout.decode('utf-8', 'replace')
        self.assertEqual(r.returncode, 1, out)
        self.assertIn('ASSET\x1b[0m maps/legion pack/Legion.ytd', out)
        self.assertIn('ASSET\x1b[0m maps/legion pack/Legion.ydr~', out)
        self.assertNotIn('STALE', out, 'a push is not the whole tree')
        self.assertEqual(self.gate()[0], 0, 'and the tree itself is clean')


@unittest.skipUnless(BASH and GIT, 'needs bash and git')
class PrePush(unittest.TestCase):
    """tools/pre-push, installed by the real tools/install-hooks.sh into a
    scratch clone, with real pushes into a bare remote -- from the clone and
    from a linked worktree on an old base, the way ~20 agent worktrees share
    the owner's hooks."""

    def setUp(self):
        top = tempfile.mkdtemp(prefix='assets-prepush-')
        self.addCleanup(shutil.rmtree, top, True)
        self.base = os.path.join(top, 'William Montgomery')
        self.repo = os.path.join(self.base, 'repo [dev]')
        self.bare = os.path.join(self.base, 'origin.git')
        for f in ('check_asset_files.sh', 'check_secrets.sh', 'pre-push', 'pre-commit', 'install-hooks.sh'):
            write(os.path.join(self.repo, 'tools', f), read(os.path.join(TOOLS, f)))
        script = read(os.path.join(TOOLS, 'check_asset_files.sh')).decode('utf-8')
        block = script[script.index('ALLOW=('):script.index('\n)\n')]
        for path in re.findall(r'^\s*"([^"]+)"', block, re.M):
            write(os.path.join(self.repo, *path.split('/')), b'ours')
        write(os.path.join(self.repo, '.gitignore'), read(os.path.join(REPO, '.gitignore')))
        os.makedirs(self.bare)
        self.git('init', '-q', '--bare', '-b', 'dev', cwd=self.bare)
        self.git('init', '-q', '-b', 'dev')
        self.git('add', '-A')
        self.git('commit', '-qm', 'base')
        self.git('remote', 'add', 'origin', self.bare)
        r = subprocess.run([BASH, 'tools/install-hooks.sh'], cwd=self.repo,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.assertEqual(r.returncode, 0, r.stdout.decode('utf-8', 'replace'))
        self.hooks = os.path.join(self.repo, '.git', 'hooks')
        self.assertEqual(read(os.path.join(self.hooks, 'pre-push')), read(os.path.join(TOOLS, 'pre-push')))
        for g in ('check_asset_files.sh', 'check_secrets.sh'):
            self.assertEqual(read(os.path.join(self.hooks, 'pre-push-gates', g)), read(os.path.join(TOOLS, g)),
                             'the gates are installed beside the hook')
        self.assertTrue(os.path.isfile(os.path.join(self.hooks, 'pre-commit')))
        # The remote's starting point; not what is under test.
        self.push_ok('--no-verify', 'dev')

    def git(self, *args, cwd=None, check=True, env=None):
        r = subprocess.run([GIT, '-c', 'user.name=t', '-c', 'user.email=t@t', '-c', 'core.autocrlf=false']
                           + list(args), cwd=cwd or self.repo, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           env=env)
        out = r.stdout.decode('utf-8', 'replace')
        if check:
            self.assertEqual(r.returncode, 0, 'git %s: %s' % (' '.join(args), out))
        return r.returncode, out

    def commit(self, files, msg='c', cwd=None):
        cwd = cwd or self.repo
        for path, data in files.items():
            if data is None:
                self.git('rm', '-q', path, cwd=cwd)
            else:
                write(os.path.join(cwd, *path.split('/')), data)
                self.git('add', '--', path, cwd=cwd)
        self.git('commit', '-qm', msg, cwd=cwd)

    def remote_tip(self, branch='dev', bare=None):
        rc, out = self.git('rev-parse', '--verify', '-q', branch, cwd=bare or self.bare, check=False)
        return out.strip() if rc == 0 else None

    def push_ok(self, *args, cwd=None):
        rc, out = self.git('push', '-q', 'origin', *args, cwd=cwd, check=False)
        self.assertEqual(rc, 0, out)
        return out

    def push_refused(self, *args, cwd=None):
        rc, out = self.git('push', 'origin', *args, cwd=cwd, check=False)
        self.assertNotEqual(rc, 0, out)
        self.assertIn('Nothing was pushed.', out)
        return out

    def test_an_ordinary_push_of_code_passes(self):
        self.commit({'resources/[fivem-royale]/br_core/server/x.lua': 'return 1\n', 'docs/notes on it.md': 'hi\n'})
        self.push_ok('dev')
        self.assertEqual(self.remote_tip(), self.git('rev-parse', 'HEAD')[1].strip())

    def test_an_asset_or_a_secret_anywhere_in_the_push_is_refused(self):
        before = self.remote_tip()
        key = 'AKIA' + 'Q' * 16
        self.commit({'resources/[maps]/legion/stream/Legion.ytd': b'\0licensed\0'}, 'pack')
        self.commit({'resources/[maps]/legion/stream/Legion.ytd': None}, 'take it out again')
        self.commit({'tools/deploy notes.sh': 'echo hi\nexport AWS_ACCESS_KEY_ID=%s\n' % key}, 'key')
        self.commit({'tools/deploy notes.sh': 'echo hi\n'}, 'and out again')
        out = self.push_refused('dev')
        self.assertEqual(self.remote_tip(), before, 'nothing reached the remote')
        self.assertIn('ASSET\x1b[0m resources/[maps]/legion/stream/Legion.ytd', out)
        sha = self.git('rev-parse', '--short', 'HEAD~1')[1].strip()
        self.assertIn('SECRET\x1b[0m tools/deploy notes.sh:2 (commit %s)  AWS access key id' % sha, out)
        self.assertNotIn(key, out, 'the secret itself is never echoed')
        self.assertIn('pre-push: refused', out)

    def test_text_marked_binary_or_textconv_is_scanned_as_committed(self):
        # .gitattributes makes `git log -p` print "Binary files differ" for a
        # path marked -diff or binary, and a textconv driver's output for one
        # with a driver; the tree form reads the files, so --revs must too.
        key = 'AKIA' + 'R' * 16
        self.git('config', 'diff.hide.textconv', 'echo')
        self.commit({'.gitattributes': 'nodiff.txt -diff\nbin.txt binary\nconv.txt diff=hide\n'}, 'attributes')
        self.commit({f: 'notes\nkey %s\n' % key for f in ('nodiff.txt', 'bin.txt', 'conv.txt')}, 'keys')
        sha = self.git('rev-parse', '--short', 'HEAD')[1].strip()
        _, log = self.git('log', '-p', '-1', '--format=')
        self.assertNotIn(key, log, 'git log -p alone hides all three')
        out = self.push_refused('dev')
        for f in ('nodiff.txt', 'bin.txt', 'conv.txt'):
            self.assertIn('SECRET\x1b[0m %s:2 (commit %s)  AWS access key id' % (f, sha), out)
        self.assertNotIn(key, out)
        r = subprocess.run([BASH, 'tools/check_secrets.sh'], cwd=self.repo, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT)
        self.assertEqual(r.returncode, 1, 'the tree form finds them too')

    def test_what_the_remote_already_has_is_not_held_against_a_later_push(self):
        self.commit({'stream/old.ytd': b'x'}, 'pushed past the hook')
        self.push_ok('--no-verify', 'dev')
        self.commit({'resources/x.lua': 'return 2\n'})
        self.push_ok('dev')
        # A new branch from here, and deleting it, pass too.
        self.push_ok('dev:feature')
        self.push_ok(':feature')

    def test_an_old_base_worktree_gets_the_installed_gates(self):
        # A base from before #391, as the agent worktrees have: no asset gate,
        # and a secrets gate that would pass anything.
        self.commit({'tools/check_asset_files.sh': None,
                     'tools/check_secrets.sh': '#!/usr/bin/env bash\necho "old gate: ok"\nexit 0\n'}, 'old base')
        self.push_ok('--no-verify', 'dev')
        wt = os.path.join(self.base, 'old worktree')
        self.git('worktree', 'add', '-q', '-b', 'old', wt, 'dev')
        # An untracked file in its tree holding a key is not what is pushed.
        write(os.path.join(wt, 'scratch.txt'), 'AKIA' + 'Z' * 16 + '\n')
        self.commit({'resources/x.lua': 'return 3\n'}, 'ordinary work', cwd=wt)
        out = self.push_ok('old', cwd=wt)
        self.assertNotIn('old gate', out)
        self.assertEqual(self.remote_tip('old'), self.git('rev-parse', 'old')[1].strip())
        # A pack from there is refused, by the installed gate.
        self.commit({'resources/[maps]/legion/stream/legion.ytd': b'\0licensed\0'}, 'a pack', cwd=wt)
        out = self.push_refused('old', cwd=wt)
        self.assertIn('ASSET\x1b[0m resources/[maps]/legion/stream/legion.ytd', out)
        self.assertNotIn('old gate', out)
        # Its old secrets gate differs from the installed one, but that gate
        # passed: only a gate that refused is worth comparing.
        self.assertNotIn('differs from the copy installed', out)

    def test_a_newly_allowlisted_file_points_at_reinstalling(self):
        # A file made ours in the same push (a new ALLOW row) is refused by the
        # installed gate, which has the old list, and the refusal says why.
        script = read(os.path.join(TOOLS, 'check_asset_files.sh')).decode('utf-8')
        script = script.replace('ALLOW=(\n', 'ALLOW=(\n    "resources/[fivem-royale]/br_audio/data/new_bank.awc"\n', 1)
        self.commit({'tools/check_asset_files.sh': script,
                     'resources/[fivem-royale]/br_audio/data/new_bank.awc': b'\0ours\0'}, 'a new sound bank')
        out = self.push_refused('dev')
        self.assertIn('ASSET\x1b[0m resources/[fivem-royale]/br_audio/data/new_bank.awc', out)
        self.assertIn('the pushed tools/check_asset_files.sh differs from the copy installed', out)
        self.assertNotIn('check_secrets.sh differs', out)

    def test_a_missing_gate_refuses_every_push(self):
        os.remove(os.path.join(self.hooks, 'pre-push-gates', 'check_secrets.sh'))
        before = self.remote_tip()
        self.commit({'resources/x.lua': 'return 4\n'})
        out = self.push_refused('dev')
        self.assertIn('cannot run the check_secrets.sh gate', out)
        self.assertIn('install-hooks.sh', out)
        self.assertEqual(self.remote_tip(), before)

    def test_a_gate_that_cannot_run_refuses(self):
        write(os.path.join(self.hooks, 'pre-push-gates', 'check_asset_files.sh'),
              '#!/usr/bin/env bash\necho "FAIL could not list"\nexit 2\n')
        before = self.remote_tip()
        self.commit({'resources/x.lua': 'return 5\n'})
        out = self.push_refused('dev')
        self.assertIn('the check_asset_files.sh gate could not run (exit 2)', out)
        self.assertEqual(self.remote_tip(), before)

    def test_a_gate_that_cannot_read_the_commits_says_so(self):
        # Exit 2, which the hook refuses as "could not run", never 0.
        for g in ('check_asset_files.sh', 'check_secrets.sh'):
            r = subprocess.run([BASH, os.path.join(self.hooks, 'pre-push-gates', g), '--revs', 'no-such-rev'],
                               cwd=self.repo, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            out = r.stdout.decode('utf-8', 'replace')
            self.assertEqual(r.returncode, 2, g + ': ' + out)
            self.assertIn('FAIL', out)

    def test_a_grep_that_cannot_run_is_not_a_pass(self):
        # The secrets gate itself, with a grep that fails the way an argument
        # list too long does (exit 2): never "ok".
        real = subprocess.run([BASH, '-c', 'command -v grep'], stdout=subprocess.PIPE).stdout.decode().strip()
        fake = os.path.join(self.base, 'fake grep bin')
        write(os.path.join(fake, 'grep'), '#!/usr/bin/env bash\ncase "$1" in -r*|-HnI*)\n'
              '  echo "grep: f: Argument list too long" >&2; exit 2 ;;\nesac\nexec "%s" "$@"\n' % real)
        os.chmod(os.path.join(fake, 'grep'), 0o755)
        self.commit({'resources/x.lua': 'return 6\n'})
        env = dict(os.environ, PATH=fake + os.pathsep + os.path.dirname(BASH) + os.pathsep + os.environ['PATH'])
        # The installed copy in --revs form, and the tree form verify.sh runs.
        for gate, args in ((os.path.join(self.hooks, 'pre-push-gates', 'check_secrets.sh'), ['--revs', 'HEAD', '^HEAD~1']),
                           (os.path.join(self.repo, 'tools', 'check_secrets.sh'), [])):
            r = subprocess.run([BASH, gate] + args, cwd=self.repo, env=env,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            out = r.stdout.decode('utf-8', 'replace')
            self.assertEqual(r.returncode, 2, out)
            self.assertIn("rule could not run (grep exit 2): grep: f: Argument list too long", out)
            self.assertNotIn('\x1b[32mok', out)
            self.assertIn('could not run, so this is not a clean pass', out)

    def test_a_remote_that_cannot_be_asked_refuses(self):
        # The hook as git runs it, by hand: a remote it cannot ls-remote is a
        # refusal, never a scan bounded by nothing it could check.
        self.commit({'resources/x.lua': 'return 9\n'})
        tip = self.git('rev-parse', 'HEAD')[1].strip()
        r = subprocess.run([BASH, os.path.join(self.hooks, 'pre-push'), 'origin',
                            os.path.join(self.base, 'no such remote.git')], cwd=self.repo,
                           input=('refs/heads/dev %s refs/heads/dev %s\n' % (tip, '0' * 40)).encode(),
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        out = r.stdout.decode('utf-8', 'replace')
        self.assertEqual(r.returncode, 1, out)
        self.assertIn('could not ask origin what it already has', out)
        self.assertIn('Nothing was pushed.', out)

    def test_the_scan_is_bounded_by_the_remote_pushed_to(self):
        # Another remote has a pack origin never got; its tracking ref here
        # must not excuse it from a push to origin.
        other = os.path.join(self.base, 'other.git')
        os.makedirs(other)
        self.git('init', '-q', '--bare', '-b', 'dev', cwd=other)
        self.git('remote', 'add', 'other', other)
        self.commit({'stream/legion.ytd': b'\0licensed\0'}, 'a pack')
        self.git('push', '-q', '--no-verify', 'other', 'dev')
        self.commit({'resources/x.lua': 'return 7\n'})
        out = self.push_refused('dev')
        self.assertIn('ASSET\x1b[0m stream/legion.ytd', out)

    def test_a_stale_tracking_ref_does_not_hide_a_commit(self):
        # A pack pushed to a branch, the branch deleted on the remote -- a
        # purge -- while this clone's origin/feature still points at it.
        self.commit({'stream/legion.ytd': b'\0licensed\0'}, 'a pack')
        self.push_ok('--no-verify', 'dev:feature')
        self.git('update-ref', '-d', 'refs/heads/feature', cwd=self.bare)
        self.assertIsNone(self.remote_tip('feature'))
        self.assertEqual(self.git('rev-parse', 'origin/feature')[0], 0, 'the tracking ref is stale, and here')
        self.commit({'resources/x.lua': 'return 8\n'})
        out = self.push_refused('dev')
        self.assertIn('ASSET\x1b[0m stream/legion.ytd', out)


if __name__ == '__main__':
    # Quiet unless something fails, like the Lua suites: one count line.
    stream = io.StringIO()
    result = unittest.TextTestRunner(stream=stream, verbosity=0).run(
        unittest.defaultTestLoader.loadTestsFromModule(sys.modules[__name__]))
    for _, trace in result.failures + result.errors:
        print(trace)
    ran = result.testsRun - len(result.skipped)
    bad = len(result.failures) + len(result.errors)
    print('%d passed%s%s' % (ran - bad,
                             (', %d skipped' % len(result.skipped)) if result.skipped else '',
                             (', %d FAILED' % bad) if bad else ''))
    sys.exit(1 if bad else 0)
