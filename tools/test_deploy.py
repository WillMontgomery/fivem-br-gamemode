#!/usr/bin/env python3
"""Tests for tools/deploy.sh's handover to the deployed ref's own deploy.sh.

    py tools/test_deploy.py         (Windows)
    python3 tools/test_deploy.py    (Linux; tools/verify.sh runs it)

royale-deploy.service runs deploy.sh from the ops clone, which only a person
pulls, while the tree it deploys is fetched fresh. The two drifted twice: #391's
asset pull and #396's cuchi_computer each reached the served tree and were never
installed, because the old deploy.sh that ran knew nothing about them. Now the
running script hands the rest of the deploy to the fetched tree's deploy.sh.

THE REAL SCRIPT, BOTH SIDES. The deploy that runs is tools/deploy.sh as it is in
this checkout; the "newer" version it fetches is that same file with an extra
vendored resource and a few lines that record who ran, with what arguments and
environment. So nothing here is a model of the handover -- a mutation of the
real script shows up in both roles, as it would on the box. rsync is
test_assets.py's stub, which logs where it was pointed.

WHAT IS PINNED is what a wrong version would get wrong silently: a handover that
never happens (the bug), one that happens twice or forever, one that deploys a
different branch or a tip that moved after the check, one that drops an argument
(a --dry-run that syncs for real), a temp copy left behind or put inside the
clone the deploy resets, and a --status that runs anything.
"""

from __future__ import annotations

import io
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

TOOLS = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, TOOLS)
from test_assets import BASH, FAKE_RSYNC, GIT, MANIFEST, read, tree, write  # noqa: E402

REAL = read(os.path.join(TOOLS, 'deploy.sh'))
EXTRA = '[extra]/br_newvendor'

# Who ran, with what. Stops a runaway loop at the fourth run so a broken guard
# fails the test instead of hanging it.
TRACE = rb'''
# test_deploy.py: record each run.
if [ -n "${DEPLOY_TEST_TRACE:-}" ]; then
    {
        # As Windows spells it under Git Bash (whose /tmp is not C:\tmp).
        printf 'RUN %s\n' "$(cygpath -w "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
        for a_ in "$@"; do printf 'ARG %s\n' "$a_"; done
        env | grep '^BR_' | sed 's/^/ENV /' || true
    } >> "$DEPLOY_TEST_TRACE"
    if [ "$(grep -c '^RUN ' "$DEPLOY_TEST_TRACE")" -gt 3 ]; then exit 99; fi
fi
'''

# The world moving between the check and the handed-over run: the branch gets a
# new tip, something (dispatch.sh's `branches`) fetches it into the served clone,
# and the pin file now names another branch. A handed-over run that resolved
# its ref or its sha again would deploy one of those.
RACE = rb'''
# test_deploy.py: move everything a re-resolution could read.
if [ -n "${BR_DEPLOY_HANDOVER_SHA:-}" ] && [ -n "${DEPLOY_TEST_RACE_SHA:-}" ]; then
    git --git-dir="$DEPLOY_TEST_BARE" update-ref refs/heads/dev "$DEPLOY_TEST_RACE_SHA"
    git -C "$DEPLOY_TEST_SRC" fetch --quiet origin dev
    printf 'other\n' > "$DEPLOY_TEST_PIN"
fi
'''


def native(path):
    """A path, resolved and cased for comparing (TEMP can be an 8.3 name)."""
    return os.path.normcase(os.path.realpath(path))


def version(trace=True, extra=True, race=False, protocol=True, self_blob=None):
    """The real deploy.sh, changed the ways a test needs."""
    s = REAL

    def swap(old, new):
        nonlocal s
        assert s.count(old) == 1, 'fixture anchor moved in deploy.sh: %r' % old
        s = s.replace(old, new)

    swap(b'set -euo pipefail\n', b'set -euo pipefail\n' + (TRACE if trace else b'') + (RACE if race else b''))
    if extra:
        swap(b'    "[computer]/cuchi_computer"\n)', b'    "[computer]/cuchi_computer"\n    "' + EXTRA.encode() + b'"\n)')
    if not protocol:
        swap(b'HANDOVER_PROTOCOL=1\n', b'')
    if self_blob is not None:
        swap(b'SELF_BLOB="$(git -C "$SRC_DIR" hash-object --stdin < "$SELF_SCRIPT" 2>/dev/null || true)"\n',
             b'SELF_BLOB="' + self_blob.encode() + b'"\n')
    return s


@unittest.skipUnless(BASH and GIT, 'needs bash and git')
class Handover(unittest.TestCase):

    @classmethod
    def git(cls, *args, cwd=None):
        r = subprocess.run([GIT, '-c', 'user.name=t', '-c', 'user.email=t@t', '-c', 'core.autocrlf=false',
                            '-c', 'init.defaultBranch=main'] + list(args),
                           cwd=cwd or cls.work, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        out = r.stdout.decode('utf-8', 'replace')
        if r.returncode != 0:
            raise AssertionError('git %s: %s' % (' '.join(args), out))
        return out.strip()

    @classmethod
    def setUpClass(cls):
        top = tempfile.mkdtemp(prefix='deploy-handover-')
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
                  '[computer]/cuchi_computer', EXTRA):
            write(os.path.join(cls.work, 'resources', *v.split('/'), 'fxmanifest.lua'), MANIFEST)
        write(os.path.join(cls.work, 'tools', 'dispatch.sh'), '#!/bin/sh\n')
        cls.git('init', '-q', '-b', 'main')
        cls.git('add', '-A')
        cls.git('update-index', '--chmod=+x', 'tools/dispatch.sh')
        cls.git('commit', '-q', '-m', 'base, with no deploy.sh')
        cls.root_commit = cls.git('rev-parse', 'HEAD')
        cls.git('init', '-q', '--bare', '-b', 'main', cls.bare, cwd=cls.base)
        cls.git('push', '-q', cls.bare, 'main')

    def setUp(self):
        run = tempfile.mkdtemp(prefix='run ', dir=self.base)
        self.server = os.path.join(run, 'server root')
        self.src = os.path.join(self.server, '.gamemode-src')
        self.pin = os.path.join(self.server, '.branch-pin')
        self.tmp = os.path.join(run, 'tmp [handover]')
        self.rsync_log = os.path.join(run, 'rsync.log')
        self.trace = os.path.join(run, 'trace.log')
        os.makedirs(os.path.join(self.server, 'resources'))
        os.makedirs(self.tmp)
        write(self.rsync_log, b'')

    def publish(self, branch, *versions):
        """Commit each of `versions` (None: no deploy.sh) as tools/deploy.sh in
        turn, on top of the base commit, and force `branch` there in origin.
        Returns the tip."""
        self.git('checkout', '-q', '-B', branch, self.root_commit)
        path = os.path.join(self.work, 'tools', 'deploy.sh')
        for v in versions:
            if v is None:
                if os.path.exists(path):
                    self.git('rm', '-q', 'tools/deploy.sh')
            else:
                write(path, v)
                self.git('add', 'tools/deploy.sh')
            self.git('commit', '-q', '--allow-empty', '-m', 'deploy.sh')
        self.git('push', '-q', '-f', self.bare, branch)
        return self.git('rev-parse', 'HEAD')

    def env(self, extra=None):
        env = {k: v for k, v in os.environ.items() if not k.startswith(('BR_', 'DEPLOY_TEST_'))}
        env.update({
            'PATH': self.bin + os.pathsep + os.path.dirname(BASH) + os.pathsep + env.get('PATH', ''),
            'BR_REPO': self.bare.replace('\\', '/'),
            'BR_SERVER_ROOT': self.server.replace('\\', '/'),
            'BR_BRANCH': 'main',
            'BR_PYTHON': sys.executable.replace('\\', '/'),
            'BR_TEST_MARK': 'two words [and brackets]',
            'TMPDIR': self.tmp.replace('\\', '/'),
            'FAKE_RSYNC_LOG': self.rsync_log,
            'DEPLOY_TEST_TRACE': self.trace,
        })
        for k, v in (extra or {}).items():
            if v is None:
                env.pop(k, None)
            else:
                env[k] = v
        return env

    def deploy(self, *args, env=None):
        r = subprocess.run([BASH, os.path.join(TOOLS, 'deploy.sh')] + list(args), env=env or self.env(),
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        return r.returncode, r.stdout.decode('utf-8', 'replace')

    def runs(self):
        """Each run of a traced deploy.sh: (path it ran from, [args], {BR_ env})."""
        if not os.path.exists(self.trace):
            return []
        out = []
        for line in read(self.trace).decode('utf-8').splitlines():
            kind, _, rest = line.partition(' ')
            if kind == 'RUN':
                out.append((rest, [], {}))
            elif kind == 'ARG':
                out[-1][1].append(rest)
            elif kind == 'ENV':
                k, _, v = rest.partition('=')
                out[-1][2][k] = v
        return out

    def rsync_dests(self):
        with open(self.rsync_log, encoding='utf-8') as fh:
            return [l[5:].rstrip('\n') for l in fh if l.startswith('DEST ')]

    def stamp(self):
        return read(os.path.join(self.server, 'resources', '[gamemodes]', '[fivem-royale]', 'br_core',
                                 'served-commit')).decode().strip()

    def served(self):
        """Every file under the server root but the clone deploy.sh keeps."""
        return {k: v for k, v in tree(self.server, skip=('.gamemode-src',)).items() if not k.endswith('/')}

    def src_git(self, *args):
        return self.git(*args, cwd=self.src)

    def assert_no_temp_left(self):
        self.assertEqual(os.listdir(self.tmp), [], 'the handover copy is removed')

    def assert_synced_extra(self, yes):
        hit = any(d.endswith('/resources/' + EXTRA + '/') for d in self.rsync_dests())
        self.assertEqual(hit, yes, self.rsync_dests())

    # -------------------------------------------------------------------------

    def test_a_newer_deploy_sh_takes_over_once_and_its_list_is_synced(self):
        # The bug: the ops clone's deploy.sh is the older of two versions of the
        # served tree's, and only the newer one names a vendored resource.
        tip = self.publish('main', REAL, version())
        rc, out = self.deploy()
        self.assertEqual(rc, 0, out)
        self.assertEqual(out.count('handing over'), 1, out)
        self.assertRegex(out, r"handing over\x1b\[0m from \S.* \([0-9a-f]{8}\) to main %s's tools/deploy\.sh "
                              r"\([0-9a-f]{8}\)" % tip[:8])
        self.assertNotIn('OLDER THAN', out, 'nothing to pull: the newer one ran')
        runs = self.runs()
        self.assertEqual(len(runs), 1, runs)
        self.assert_synced_extra(True)
        self.assertIn('-> %s/resources/%s' % (self.server.replace('\\', '/'), EXTRA), out)
        self.assertIn('\x1b[32mdeployed\x1b[0m main', out)
        self.assertEqual(self.stamp(), tip)

        # A private copy, in a directory of its own under TMPDIR, outside the
        # served clone, gone once the run is over.
        ran_from = native(runs[0][0])
        self.assertTrue(ran_from.startswith(native(self.tmp) + os.sep), (ran_from, self.tmp))
        self.assertFalse(ran_from.startswith(native(self.src) + os.sep), ran_from)
        self.assertRegex(os.path.basename(os.path.dirname(ran_from)), r'^br-deploy-handover\.')
        self.assertFalse(os.path.exists(ran_from))
        self.assert_no_temp_left()

    def test_the_same_deploy_sh_runs_alone(self):
        self.publish('main', REAL)
        rc, out = self.deploy()
        self.assertEqual(rc, 0, out)
        self.assertNotIn('handing over', out)
        self.assertNotIn('deploy: note', out)
        self.assertNotIn('OLDER THAN', out)
        self.assert_synced_extra(False)
        self.assertIn('\x1b[32mdeployed', out)
        rc, out = self.deploy('--status')
        self.assertEqual(rc, 0, out)
        self.assertIn("  deploy.sh: the same as main's", out)
        self.assert_no_temp_left()

    def test_the_handed_over_run_keeps_the_ref_the_sha_and_the_environment(self):
        # The branch comes from the pin, so the first run resolves it; then the
        # world moves (RACE). Everything must still be dev at the checked sha.
        tip = self.publish('dev', REAL, version(race=True))
        race_tip = self.publish('race-tip', REAL, version(race=True), REAL)
        self.publish('other', REAL)
        write(self.pin, 'dev\n')
        env = self.env({'BR_BRANCH': None, 'DEPLOY_TEST_RACE_SHA': race_tip,
                        'DEPLOY_TEST_BARE': self.bare.replace('\\', '/'),
                        'DEPLOY_TEST_SRC': self.src.replace('\\', '/'),
                        'DEPLOY_TEST_PIN': self.pin.replace('\\', '/')})
        rc, out = self.deploy(env=env)
        self.assertEqual(rc, 0, out)
        self.assertIn("branch from %s: dev" % self.pin.replace('\\', '/'), out)
        self.assertIn('branch from the handover: dev @ %s' % tip[:8], out)
        self.assertIn('not fetching: the handover pinned dev at %s' % tip[:8], out)
        self.assertEqual(self.git('rev-parse', 'refs/heads/dev', cwd=self.bare), race_tip, 'the race happened')
        self.assertEqual(read(self.pin), b'other\n', 'the race happened')
        self.assertEqual(self.stamp(), tip, 'the sha that was checked, not the tip that moved')
        self.assertEqual(self.src_git('symbolic-ref', 'HEAD'), 'refs/heads/dev')
        self.assertEqual(self.src_git('rev-parse', 'HEAD'), tip)
        self.assertIn('\x1b[32mdeployed\x1b[0m dev', out)

        runs = self.runs()
        self.assertEqual(len(runs), 1, runs)
        _, args, br_env = runs[0]
        self.assertEqual(args, [])
        want = {k: v for k, v in env.items() if k.startswith('BR_')}
        self.assertNotIn('BR_BRANCH', want)
        handed = {k: br_env.pop(k, None) for k in ('BR_DEPLOY_HANDOVER_SHA', 'BR_DEPLOY_HANDOVER_REF',
                                                    'BR_DEPLOY_HANDOVER_FROM')}
        self.assertEqual(br_env, want, 'the environment arrives as it was, BR_BRANCH still unset')
        self.assertEqual(handed['BR_DEPLOY_HANDOVER_SHA'], tip)
        self.assertEqual(handed['BR_DEPLOY_HANDOVER_REF'], 'dev')
        self.assertTrue(handed['BR_DEPLOY_HANDOVER_FROM'].endswith('/tools/deploy.sh'), handed)
        self.assert_no_temp_left()

    def test_a_dry_run_hands_over_and_changes_nothing(self):
        self.publish('main', REAL, version())
        before = self.served()
        rc, out = self.deploy('--dry-run')
        self.assertEqual(rc, 0, out)
        self.assertEqual(out.count('handing over'), 1, out)
        runs = self.runs()
        self.assertEqual(len(runs), 1, runs)
        self.assertEqual(runs[0][1], ['--dry-run'], 'the argument went with it')
        # The new version's dry run: its list, every rsync a dry one.
        self.assert_synced_extra(True)
        with open(self.rsync_log, encoding='utf-8') as fh:
            calls = [l for l in fh if l.startswith('ARGS ')]
        self.assertTrue(calls)
        for c in calls:
            self.assertIn('--dry-run', c)
        self.assertIn('dry run -- nothing was changed', out)
        self.assertEqual(self.served(), before)
        self.assert_no_temp_left()

    def test_status_says_a_deploy_would_hand_over_and_runs_nothing(self):
        tip = self.publish('main', REAL, version())
        before = self.served()
        rc, out = self.deploy('--status')
        self.assertEqual(rc, 0, out)
        self.assertRegex(out, r"  deploy\.sh: a deploy would hand over from \S.* \([0-9a-f]{8}\) to main %s's "
                              r"tools/deploy\.sh \([0-9a-f]{8}\)" % tip[:8])
        self.assertNotIn('handing over', out)
        self.assertNotIn('OLDER THAN', out, 'a deploy fixes it; nothing to pull')
        self.assertEqual(self.runs(), [])
        self.assertEqual(self.rsync_dests(), [])
        self.assertEqual(self.served(), before)
        self.assert_no_temp_left()

    def test_a_tree_without_deploy_sh_is_deployed_by_this_one(self):
        self.publish('main', None)
        rc, out = self.deploy()
        self.assertEqual(rc, 0, out)
        self.assertIn('deploy: note: main has no tools/deploy.sh, so this one (', out)
        self.assertNotIn('handing over', out)
        self.assertIn('\x1b[32mdeployed', out)
        self.assert_synced_extra(False)
        rc, out = self.deploy('--status')
        self.assertEqual(rc, 0, out)
        self.assertIn('  deploy.sh: this one; main has none', out)

    def test_a_copy_that_cannot_be_made_or_sits_in_the_clone_is_not_run(self):
        self.publish('main', REAL, version())
        nowhere = os.path.join(self.tmp, 'missing')
        rc, out = self.deploy(env=self.env({'TMPDIR': nowhere.replace('\\', '/')}))
        self.assertEqual(rc, 0, out)
        self.assertIn("deploy: could not hand over to main's tools/deploy.sh (no private directory could be "
                      "made in ", out)
        self.assertIn("missing); this one (", out)
        self.assertIn("THIS deploy.sh IS OLDER THAN main's tools/deploy.sh", out, 'the pull is the fix then')
        self.assertIn('Pull the ops clone, then deploy again:  git -C ', out)
        self.assertIn('\x1b[32mdeployed', out, 'a warning, not a stop')
        self.assertEqual(self.runs(), [])
        self.assert_synced_extra(False)

        # A TMPDIR inside the served clone (its .git, which the reset and the
        # clean leave alone) is refused rather than run from.
        inside = os.path.join(self.src, '.git', 'handover tmp')
        os.makedirs(inside)
        rc, out = self.deploy(env=self.env({'TMPDIR': inside.replace('\\', '/')}))
        self.assertEqual(rc, 0, out)
        self.assertIn('is inside the served clone); this one (', out)
        self.assertEqual(self.runs(), [])
        self.assertEqual(os.listdir(inside), [], 'and the directory it made there is gone')
        self.assert_no_temp_left()

    def test_the_guard_stops_a_version_that_never_agrees_with_itself(self):
        # This version computes its own blob wrong, so as the handed-over copy
        # it still "differs" from the tree it was handed. Without the guard it
        # would hand over to itself forever (the trace stops it at four).
        self.publish('main', REAL, version(self_blob='0' * 40))
        rc, out = self.deploy()
        self.assertEqual(rc, 0, out)
        self.assertEqual(len(self.runs()), 1, out)
        self.assertEqual(out.count('handing over'), 1, out)
        self.assertRegex(out, r'deploy: note: already handed over once \(from \S.*/tools/deploy\.sh\); this copy '
                              r"deploys although main's tools/deploy\.sh differs from it")
        self.assertIn('\x1b[32mdeployed', out)
        self.assert_synced_extra(True)
        self.assert_no_temp_left()

    def test_a_deploy_sh_that_does_not_take_the_handover_is_not_handed_to(self):
        # A ref from before the handover: its deploy.sh would ignore the pinned
        # sha and fetch again, so this script deploys it, as before.
        self.publish('main', version(protocol=False))
        rc, out = self.deploy()
        self.assertEqual(rc, 0, out)
        self.assertIn("deploy: note: main's tools/deploy.sh differs from this one (", out)
        self.assertIn(') and does not take a handover, so this one deploys it', out)
        self.assertNotIn('OLDER THAN', out, 'not a version this one is older than')
        self.assertNotIn('handing over', out)
        self.assertEqual(self.runs(), [])
        self.assert_synced_extra(False)
        self.assertIn('\x1b[32mdeployed', out)

        # A newer version that does not take it (another protocol): the ops
        # clone needs its pull, and the red box says so.
        self.publish('main', REAL, version(protocol=False))
        rc, out = self.deploy()
        self.assertEqual(rc, 0, out)
        self.assertIn("THIS deploy.sh IS OLDER THAN main's tools/deploy.sh", out)
        self.assertRegex(out, r"\(it is on [^;]+; the pull helps once that branch has main's deploy\.sh\)")
        self.assertEqual(self.runs(), [])
        rc, out = self.deploy('--status')
        self.assertEqual(rc, 0, out)
        self.assertIn("  deploy.sh: this one; main's differs and does not take a handover", out)


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
