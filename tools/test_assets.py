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
import unittest
from unittest import mock

TOOLS = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(TOOLS)
TOOL = os.path.join(TOOLS, 'assets.py')
sys.path.insert(0, TOOLS)
import assets  # noqa: E402

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


def tree(root):
    """Every file and directory under root, with size and mtime, for 'did
    anything change' comparisons."""
    out = {}
    for dirpath, dirnames, filenames in os.walk(root):
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
    return {'format': 1, 'resources': [
        {'name': 'legion_pack', 'seasons': {'1': SHA_A, '3': SHA_B},
         'versions': {SHA_A: version(), SHA_B: version()}},
        {'name': 'emote_pack', 'from': 2, 'until': 5, 'seasons': {'2': SHA_C}, 'versions': {SHA_C: version()}},
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
        self.assertEqual(self.problems({'format': 1, 'resources': []}), [])

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
        text = '{"format": 1, "resources": [], "resources": []}'
        with self.assertRaises(assets.AssetsError):
            assets.parse_lock_text(text)

    def test_nothing_but_names_hashes_sizes_files_and_pins(self):
        self.assertRefused(lambda l: l.update({'notes': 'x'}), 'unknown top-level')
        self.assertRefused(lambda l: l['resources'][0].update({'license': 'KEY-123'}), 'unknown key')
        self.assertRefused(lambda l: l['resources'][0]['versions'][SHA_A].update({'content': 'x'}), 'unknown key')

    def test_season_ranges(self):
        self.assertRefused(lambda l: l['resources'][1].update({'until': 2}), 'must be after "from"')
        self.assertRefused(lambda l: l['resources'][1].update({'from': 0}), '"from" must be a season')
        self.assertRefused(lambda l: l['resources'][1].update({'until': True}), '"until" must be a season')
        self.assertRefused(lambda l: l['resources'][1].update({'until': 3, 'from': 1,
                                                                'seasons': {'2': SHA_C, '4': SHA_A},
                                                                'versions': {SHA_C: version(), SHA_A: version()}}),
                           'never in force')
        self.assertRefused(lambda l: l['resources'][0]['seasons'].update({'01': SHA_A}), 'is not a season')
        self.assertRefused(lambda l: l['resources'][0]['seasons'].update({'0': SHA_A}), 'is not a season')
        self.assertRefused(lambda l: l['resources'][0].update({'seasons': {}}), 'at least one season')

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

    def test_from_and_until(self):
        e = {'name': 'x', 'from': 2, 'until': 4, 'seasons': {'1': SHA_A}, 'versions': {}}
        self.assertEqual([assets.version_for(e, s) for s in (1, 2, 3, 4, 5)], [None, SHA_A, SHA_A, None, None])

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
            ('br_season 6\n', '6'),
            ('# set br_season 7\n// set br_season 8\n', None),
            ('set br_season 1\nset br_season 2\n', '2'),
            ('set br_season 1\r\nset sv_x 2\r\n', '1'),
            ('set br_seasonServed 9\n', None),
        ):
            self.cfg(text)
            found, _ = assets.cfg_season(root, os.path.join(root, 'server.cfg'))
            self.assertEqual(found and found[0], want, repr(text))

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

    def test_seasons_from_and_until(self):
        folder = make_resource(self.src, 'emotes', {'anim/a.ycd': b'v1'})
        self.push(folder)
        v1 = self.entry('emotes')['seasons']['1']
        write(os.path.join(folder, 'anim', 'a.ycd'), b'v2')
        _, text = self.push(folder, '--season', 2, '--from', 1, '--until', 4)
        e = self.entry('emotes')
        v2 = e['seasons']['2']
        self.assertEqual(e['seasons'], {'1': v1, '2': v2})
        self.assertEqual((e['from'], e['until']), (1, 4))
        self.assertEqual(sorted(e['versions']), sorted([v1, v2]))
        self.assertIn('Season 2 and later -> %s' % v2[:12], text)

        # Two seasons pinned: a push must say which one it is.
        write(os.path.join(folder, 'anim', 'a.ycd'), b'v3')
        before = read(self.lock)
        _, text = self.push(folder, expect=1)
        self.assertIn('--season N', text)
        self.assertEqual(read(self.lock), before)

        # Replacing Season 2's version drops the old one from the lock.
        _, text = self.push(folder, '--season', 2, '--until', 'none')
        e = self.entry('emotes')
        v3 = e['seasons']['2']
        self.assertNotIn(v2, e['versions'])
        self.assertNotIn('until', e)
        self.assertIn('pinned to no season now', text)
        self.assertTrue(os.path.isfile(self.object_path('emotes', v2)), 'the old archive stays in the bucket')
        self.assertEqual(sorted(e['versions']), sorted([v1, v3]))

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
        folder = make_resource(self.src, 'emotes', {'x.ycd': b'x'})
        _, text = self.push(folder, '--from', 3, '--until', 2, expect=1)
        self.assertIn('would not pass check', text)
        self.assertFalse(os.path.exists(self.lock))

    def test_lock_is_written_in_its_one_form(self):
        folder = make_resource(self.src, 'p', {'b.ytd': b'b', 'a.ytd': b'a'})
        self.push(folder)
        text = read(self.lock).decode('utf-8')
        self.assertEqual(text, assets.dump_lock(json.loads(text)))
        self.assertNotIn('\r', text)


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
        self.push_pack('old_map', {'o.ymap': b'o'}, '--until', 2)

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
        # v2 is pinned, but the bucket holds some other archive under its key.
        write(os.path.join(folder, 'a.ytd'), b'good v2')
        self.push(folder)
        v2 = self.entry('p')['seasons']['1']
        other = make_resource(self.src, 'other', {'a.ytd': b'evil', 'payload.ytd': b'x' * 50})
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
        write(self.lock, assets.dump_lock({'format': 1, 'resources': [
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
        write(self.lock, assets.dump_lock({'format': 1, 'resources': [
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
        write(self.lock, assets.dump_lock({'format': 1, 'resources': []}))
        self.pull()
        self.assertFalse(os.path.exists(os.path.join(self.licensed, 'p')))
        self.assertEqual(self.cfg_lines(), [])
        os.remove(self.lock)
        _, text = self.pull()
        self.assertIn('up to date', text, 'an absent lock is an empty one')

    def test_nothing_to_do_creates_nothing(self):
        write(self.lock, assets.dump_lock({'format': 1, 'resources': []}))
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
