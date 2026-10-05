"""tools/test_vcache.py -- the pass cache's own suite (tools/vcache.py,
tools/vcache_trace.lua, tools/vcache_trace.py and verify.sh's helpers).

    python3 tools/test_vcache.py --lua /path/to/lua

A cache that skips a suite it should have run turns a red build green, which
is worse than having no cache. So every case here is a way an input can change
and the assertion is that the suite RUNS -- plus the two ways a pass must never
be stored: the suite failed, or the run was cut off before the end.

HOW. Each case builds a scratch checkout holding copies of the four cache
files, a handful of stand-in suites (Lua and Python) with known reads, and a
small tools/verify.sh assembled from the REAL one: the code between its
`>>> pass-cache helpers` / `<<< pass-cache helpers` markers and between its
`pass-cache commit` markers, verbatim, around a driver that runs the stand-ins
exactly the way verify.sh runs a suite. So the bash under test is the bash that
ships, and editing it is tested here too.

The stand-ins, and what each one reads:

  test_a.lua   data/a.txt (a line FAIL in it makes the suite fail)
  test_b.lua   data/flag.txt; data/branch.txt ONLY when the flag says yes;
               data/optional.txt, which usually does not exist; $TV_KNOB
  test_d.lua   loadfile tools/lib.lua; io.popen of a command printing data/p.txt
  test_c.py    os.listdir(data/dir) and each file in it; imports tools/helper.py;
               runs `bash data/script.sh`
  decl         a bash gate reading data/decl.txt, declared as file:data/decl.txt
"""

import argparse
import io
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

TOOLS = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(TOOLS)
LUA = None
BASH = None

CACHE_FILES = ('vcache.py', 'vcache_trace.lua', 'vcache_trace.py')


def find_bash():
    """Git Bash on Windows, never System32's WSL launcher."""
    found = shutil.which('bash')
    if os.name != 'nt':
        return found
    for c in ([found] if found else []) + [r'C:\Program Files\Git\usr\bin\bash.exe',
                                           r'C:\Program Files\Git\bin\bash.exe']:
        if c and os.path.isfile(c) and 'system32' not in c.lower() and 'windowsapps' not in c.lower():
            return c
    return None


def block(text, name):
    m = re.search(r'^# >>> %s\n(.*?)^# <<< %s\n' % (re.escape(name), re.escape(name)), text, re.S | re.M)
    if not m:
        raise AssertionError('tools/verify.sh has no `%s` markers; test_vcache.py runs that block' % name)
    return m.group(1)


DRIVER = r'''#!/usr/bin/env bash
# test_vcache.py's stand-in verify.sh. Between the markers: verify.sh's own.
set -uo pipefail
cd "$(dirname "$0")/.."
RED=''; GRN=''; YEL=''; DIM=''; RST=''
rc=0
NL=$'\n'
VC_FULL=0
for a_ in "$@"; do case "$a_" in --full) VC_FULL=1 ;; esac; done
LUA="$TV_LUA"
PY_=("$TV_PY")
section() { echo "== $1 =="; VC_RAN=$((VC_RAN + 1)); }
suite_label() { echo "$1:"; VC_RAN=$((VC_RAN + 1)); }
@@HELPERS@@
for s in a b d; do
    suite_label "test_$s"
    if vc_begin "test_$s"; then
        vc_lua; st_=0
        out_=$("${VCL[@]}" "tools/test_$s.lua") || st_=1
        printf '%s\n' "$out_"
        vc_end "$st_"; [ "$st_" -eq 0 ] || rc=1
    fi
    if [ "$s" = a ] && [ -n "${TV_TOUCH_TOOL:-}" ]; then
        printf '\n' >> tools/vcache_trace.lua
    fi
    if [ "$s" = b ] && [ -n "${TV_INTERRUPT:-}" ]; then
        kill -KILL $$
    fi
done
suite_label test_c
if vc_begin test_c; then
    vc_py; st_=0
    "${VCP[@]}" tools/test_c.py || st_=1
    vc_end "$st_"; [ "$st_" -eq 0 ] || rc=1
fi
section decl
if vc_begin decl 'file:data/decl.txt' 'list:data/listed:.txt' 'tree:data/tree:.cfg'; then
    st_=0
    [ "$(cat data/decl.txt)" = good ] || st_=1
    echo "decl ran"
    vc_end "$st_"; [ "$st_" -eq 0 ] || rc=1
fi
@@COMMIT@@
exit $rc
'''

TEST_A = r'''local fh = assert(io.open('data/a.txt', 'r'))
local text = fh:read('a'); fh:close()
if text:find('FAIL', 1, true) then print('a: FAIL'); os.exit(1) end
if os.getenv('TV_TOUCH_LUA') then
    -- An edit while it runs, as an editor saving would: same size, new bytes.
    local w = assert(io.open('data/a.txt', 'wb')); w:write(text:upper()); w:close()
end
print('a ran')
'''

TEST_B = r'''local fh = io.open('data/flag.txt', 'r')
local flag = fh:read('a'); fh:close()
if flag:find('yes', 1, true) then
    for line in io.lines('data/branch.txt') do
        if line == 'FAIL' then print('b: FAIL'); os.exit(1) end
    end
end
local opt = io.open('data/optional.txt', 'r')
if opt then opt:close() end
local knob = os.getenv('TV_KNOB')
print('b ran', knob or '')
os.exit(0)
'''

TEST_D = r'''local lib = assert(loadfile('tools/lib.lua'))()
local cmd = package.config:sub(1, 1) == '\\' and 'type data\\p.txt' or 'cat data/p.txt'
local p = assert(io.popen(cmd))
local out = p:read('a')
p:close()
if not out:find('p', 1, true) then print('d: FAIL'); os.exit(1) end
print('d ran', lib.v)
'''

TEST_C = r'''import os, shutil, subprocess, sys, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import helper
# Its own scratch, made under one spelling and read back under the other (on
# Windows an 8.3 short name and its long form; elsewhere the same path): the
# run's output, never an input.
def short(p):
    if os.name != 'nt':
        return p
    import ctypes
    buf = ctypes.create_unicode_buffer(1024)
    n = ctypes.windll.kernel32.GetShortPathNameW(p, buf, 1024)
    return buf.value if 0 < n < 1024 else p
for made, seen in ((tempfile.mkdtemp(), os.path.realpath),
                   (tempfile.mkdtemp(dir=os.path.realpath(tempfile.gettempdir())), short)):
    with open(os.path.join(made, 'mine.txt'), 'w') as fh:
        fh.write('mine')
    with open(os.path.join(seen(made), 'mine.txt')) as fh:
        fh.read()
    shutil.rmtree(made)
for n in sorted(os.listdir(os.path.join('data', 'dir'))):
    with open(os.path.join('data', 'dir', n)) as fh:
        if 'FAIL' in fh.read():
            print('c: FAIL'); sys.exit(1)
r = subprocess.run([os.environ['TV_BASH'], 'data/script.sh'], stdout=subprocess.PIPE)
if r.returncode != 0:
    print('c: FAIL'); sys.exit(1)
if os.environ.get('TV_TOUCH'):
    with open(os.path.join('data', 'dir', 'one.txt'), 'a') as fh:
        fh.write('touched while it ran\n')
print('c ran', helper.V)
'''


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w', encoding='utf-8', newline='\n') as fh:
        fh.write(text)


def edit(path, text):
    """Write, dated five seconds ago. The cache refuses to store a unit whose
    input was modified too close to its start to tell from an edit while it
    ran (vcache.py's moved_since), and a suite that ran because it was not
    stored would make a later assertion that it ran pass for the wrong
    reason. The content is what changed."""
    write(path, text)
    age(path)


def age(path):
    then = time.time() - 5
    os.utime(path, (then, then))
    os.utime(os.path.dirname(path), (then, then))


class Checkout(unittest.TestCase):

    def setUp(self):
        self.root = tempfile.mkdtemp(prefix='vcache-test-')
        self.addCleanup(shutil.rmtree, self.root, True)
        t = os.path.join(self.root, 'tools')
        os.makedirs(t)
        for f in CACHE_FILES:
            shutil.copyfile(os.path.join(TOOLS, f), os.path.join(t, f))
        with open(os.path.join(TOOLS, 'verify.sh'), encoding='utf-8') as fh:
            real = fh.read()
        driver = DRIVER.replace('@@HELPERS@@', block(real, 'pass-cache helpers')) \
                       .replace('@@COMMIT@@', block(real, 'pass-cache commit'))
        write(os.path.join(t, 'verify.sh'), driver)
        write(os.path.join(t, 'test_a.lua'), TEST_A)
        write(os.path.join(t, 'test_b.lua'), TEST_B)
        write(os.path.join(t, 'test_d.lua'), TEST_D)
        write(os.path.join(t, 'test_c.py'), TEST_C)
        write(os.path.join(t, 'lib.lua'), 'return { v = 1 }\n')
        write(os.path.join(t, 'helper.py'), 'V = 1\n')
        d = os.path.join(self.root, 'data')
        write(os.path.join(d, 'a.txt'), 'alpha\n')
        write(os.path.join(d, 'flag.txt'), 'no\n')
        write(os.path.join(d, 'branch.txt'), 'fine\n')
        write(os.path.join(d, 'p.txt'), 'p one\n')
        write(os.path.join(d, 'decl.txt'), 'good')
        write(os.path.join(d, 'dir', 'one.txt'), 'one\n')
        write(os.path.join(d, 'script.sh'), 'exit 0\n')
        write(os.path.join(d, 'listed', 'l1.txt'), 'l1\n')
        write(os.path.join(d, 'listed', 'note.md'), 'note\n')
        write(os.path.join(d, 'tree', 'x.cfg'), 'x\n')
        write(os.path.join(d, 'tree', 'readme.md'), 'readme\n')
        # Every file the first run reads must be older than the unit's start
        # by more than the cache's slack, or the first run would store nothing.
        self.age_all(5)

    def age_all(self, seconds):
        then = time.time() - seconds
        for d, _, fs in os.walk(self.root):
            for f in fs:
                os.utime(os.path.join(d, f), (then, then))
            os.utime(d, (then, then))

    def p(self, *parts):
        return os.path.join(self.root, *parts)

    def run_verify(self, *args, env=None, expect_rc=None):
        e = {k: v for k, v in os.environ.items() if k not in ('CI', 'GITHUB_ACTIONS', 'TV_KNOB')}
        e.update({'TV_LUA': LUA, 'TV_PY': sys.executable.replace(os.sep, '/'), 'TV_BASH': BASH})
        e.update(env or {})
        r = subprocess.run([BASH, 'tools/verify.sh'] + list(args), cwd=self.root, env=e,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        out = r.stdout.decode('utf-8', 'replace').replace('\r\n', '\n')
        if expect_rc is not None:
            self.assertEqual(r.returncode, expect_rc, out)
        return r.returncode, out

    def ran(self, out):
        """The units that ran, by the line each prints when it does."""
        return {m.group(1) for m in re.finditer(r'^(a|b|c|d|decl) ran', out, re.M)} | \
               {m.group(1) for m in re.finditer(r'^(a|b|c|d): FAIL', out, re.M)}

    def warm(self):
        """A first run that passes and stores all five, and a second that
        skips all five: the baseline every case changes one thing against."""
        rc, out = self.run_verify(expect_rc=0)
        self.assertEqual(self.ran(out), {'a', 'b', 'c', 'd', 'decl'}, out)
        self.assertIn('PASS  5 ran, 0 skipped', out)
        rc, out = self.run_verify(expect_rc=0)
        self.assertEqual(self.ran(out), set(), out)
        self.assertIn('PASS  0 ran, 5 skipped', out)
        self.assertEqual(out.count('skipped -- unchanged since it passed at '), 5, out)
        return out

    def entries(self):
        d = self.p('.verify-cache', 'entries')
        return sorted(os.listdir(d)) if os.path.isdir(d) else []


class Skips(Checkout):

    def test_an_unchanged_tree_skips_everything_and_says_how_many_inputs(self):
        out = self.warm()
        for m in re.finditer(r'skipped -- unchanged since it passed at [^(]*\((\d+) inputs\)', out):
            self.assertGreater(int(m.group(1)), 0)

    def test_editing_a_file_a_suite_read_runs_that_suite_and_only_it(self):
        self.warm()
        edit(self.p('data', 'a.txt'), 'alpha, edited\n')
        rc, out = self.run_verify(expect_rc=0)
        self.assertEqual(self.ran(out), {'a'}, out)
        self.assertIn('PASS  1 ran, 4 skipped', out)

    def test_going_back_to_older_bytes_is_still_a_change(self):
        self.warm()
        edit(self.p('data', 'a.txt'), 'alpha, edited\n')
        self.run_verify(expect_rc=0)
        edit(self.p('data', 'a.txt'), 'alpha\n')
        self.age_all(5)
        rc, out = self.run_verify(expect_rc=0)
        # The entry now describes the edited bytes, so the original is a change.
        self.assertEqual(self.ran(out), {'a'}, out)

    def test_a_new_file_in_a_listed_directory_runs_the_suite_that_listed_it(self):
        self.warm()
        edit(self.p('data', 'dir', 'two.txt'), 'two\n')
        rc, out = self.run_verify(expect_rc=0)
        self.assertEqual(self.ran(out), {'c'}, out)

    def test_a_removed_file_in_a_listed_directory_runs_it_too(self):
        write(self.p('data', 'dir', 'two.txt'), 'two\n')
        self.age_all(5)
        self.warm()
        os.remove(self.p('data', 'dir', 'two.txt'))
        age(self.p('data', 'dir', 'one.txt'))
        rc, out = self.run_verify(expect_rc=0)
        self.assertEqual(self.ran(out), {'c'}, out)

    def test_a_file_read_only_on_one_branch_is_recorded_when_that_branch_runs(self):
        self.warm()
        # flag=no: branch.txt is not read, so editing it changes nothing.
        edit(self.p('data', 'branch.txt'), 'still fine\n')
        rc, out = self.run_verify(expect_rc=0)
        self.assertEqual(self.ran(out), set(), out)
        # flag=yes: b runs (its flag changed) and now reads branch.txt...
        edit(self.p('data', 'flag.txt'), 'yes\n')
        rc, out = self.run_verify(expect_rc=0)
        self.assertEqual(self.ran(out), {'b'}, out)
        # ...so a breaking edit to branch.txt is a change that runs it, and fails.
        edit(self.p('data', 'branch.txt'), 'FAIL\n')
        rc, out = self.run_verify(expect_rc=1)
        self.assertEqual(self.ran(out), {'b'}, out)

    def test_a_file_that_was_absent_appearing_runs_the_suite_that_looked(self):
        self.warm()
        edit(self.p('data', 'optional.txt'), 'here now\n')
        rc, out = self.run_verify(expect_rc=0)
        self.assertEqual(self.ran(out), {'b'}, out)

    def test_an_environment_variable_a_suite_read_is_an_input(self):
        self.warm()
        rc, out = self.run_verify(env={'TV_KNOB': 'turned'}, expect_rc=0)
        # b asked for it; c (Python) and decl (bash) record the whole
        # environment, because their children inherit all of it. a and d
        # never asked, so a variable they cannot see is no change to them.
        self.assertEqual(self.ran(out), {'b', 'c', 'decl'}, out)
        rc, out = self.run_verify(env={'TV_KNOB': 'turned'}, expect_rc=0)
        self.assertEqual(self.ran(out), set(), out)
        # Its VALUE is the input, not only whether it is set.
        rc, out = self.run_verify(env={'TV_KNOB': 'turned again'}, expect_rc=0)
        self.assertEqual(self.ran(out), {'b', 'c', 'decl'}, out)

    def test_a_loadfiled_module_and_a_popen_output_are_inputs(self):
        self.warm()
        edit(self.p('tools', 'lib.lua'), 'return { v = 2 }\n')
        rc, out = self.run_verify(expect_rc=0)
        self.assertEqual(self.ran(out), {'d'}, out)
        edit(self.p('data', 'p.txt'), 'p two\n')
        rc, out = self.run_verify(expect_rc=0)
        self.assertEqual(self.ran(out), {'d'}, out)

    def test_a_python_import_and_a_script_it_runs_are_inputs(self):
        self.warm()
        edit(self.p('tools', 'helper.py'), 'V = 2\n')
        rc, out = self.run_verify(expect_rc=0)
        self.assertEqual(self.ran(out), {'c'}, out)
        edit(self.p('data', 'script.sh'), 'exit 0 # edited\n')
        rc, out = self.run_verify(expect_rc=0)
        self.assertEqual(self.ran(out), {'c'}, out)

    def test_a_declared_input_of_a_bash_gate(self):
        self.warm()
        edit(self.p('data', 'decl.txt'), 'bad')
        rc, out = self.run_verify(expect_rc=1)
        self.assertEqual(self.ran(out), {'decl'}, out)
        # A bash gate has no tracer to withhold a finished trace, so this is
        # the case where vc_end's exit status alone keeps a failure out.
        rc, out = self.run_verify(expect_rc=1)
        self.assertEqual(self.ran(out), {'decl'}, 'a failed gate was stored: ' + out)

    def test_a_declared_list_is_the_names_that_match(self):
        self.warm()
        edit(self.p('data', 'listed', 'other.md'), 'not a .txt\n')
        rc, out = self.run_verify(expect_rc=0)
        self.assertEqual(self.ran(out), set(), 'a name the list does not match: ' + out)
        edit(self.p('data', 'listed', 'l1.txt'), 'content is not a list: input\n')
        rc, out = self.run_verify(expect_rc=0)
        self.assertEqual(self.ran(out), set(), out)
        edit(self.p('data', 'listed', 'l2.txt'), 'l2\n')
        rc, out = self.run_verify(expect_rc=0)
        self.assertEqual(self.ran(out), {'decl'}, out)

    def test_a_declared_tree_is_its_listings_and_matching_contents(self):
        self.warm()
        edit(self.p('data', 'tree', 'readme.md'), 'edited, but not a .cfg\n')
        rc, out = self.run_verify(expect_rc=0)
        self.assertEqual(self.ran(out), set(), out)
        edit(self.p('data', 'tree', 'x.cfg'), 'x2\n')
        rc, out = self.run_verify(expect_rc=0)
        self.assertEqual(self.ran(out), {'decl'}, out)
        edit(self.p('data', 'tree', 'sub', 'y.md'), 'a new directory\n')
        age(self.p('data', 'tree', 'sub'))
        rc, out = self.run_verify(expect_rc=0)
        self.assertEqual(self.ran(out), {'decl'}, 'every directory listing is in the tree: ' + out)

    def test_editing_verify_sh_the_cache_or_either_tracer_runs_everything(self):
        self.warm()
        for f in ('verify.sh',) + CACHE_FILES:
            with self.subTest(f=f):
                with open(self.p('tools', f), 'a', encoding='utf-8', newline='\n') as fh:
                    fh.write('\n# an edit\n' if f == 'verify.sh' else '\n')
                age(self.p('tools', f))
                rc, out = self.run_verify(expect_rc=0)
                self.assertEqual(self.ran(out), {'a', 'b', 'c', 'd', 'decl'}, out)
                rc, out = self.run_verify(expect_rc=0)
                self.assertEqual(self.ran(out), set(), 'stored again under the new key: ' + out)

    def test_full_runs_everything_and_refreshes_the_cache(self):
        self.warm()
        rc, out = self.run_verify('--full', expect_rc=0)
        self.assertEqual(self.ran(out), {'a', 'b', 'c', 'd', 'decl'}, out)
        self.assertIn('PASS  5 ran, 0 skipped', out)
        rc, out = self.run_verify(expect_rc=0)
        self.assertEqual(self.ran(out), set(), out)


class NeverStored(Checkout):

    def test_a_failing_suite_is_never_stored_and_loses_its_old_entry(self):
        self.warm()
        n = len(self.entries())
        edit(self.p('data', 'a.txt'), 'FAIL\n')
        rc, out = self.run_verify(expect_rc=1)
        self.assertEqual(self.ran(out), {'a'}, out)
        self.assertEqual(len(self.entries()), n - 1, 'the failed suite\'s entry is gone')
        rc, out = self.run_verify(expect_rc=1)
        self.assertEqual(self.ran(out), {'a'}, 'still failing, so still run: ' + out)
        # Back to the bytes of the old pass: the entry was deleted, so it runs.
        edit(self.p('data', 'a.txt'), 'alpha\n')
        self.age_all(5)
        rc, out = self.run_verify(expect_rc=0)
        self.assertEqual(self.ran(out), {'a'}, out)

    def test_a_failing_first_run_stores_nothing_for_that_suite(self):
        edit(self.p('data', 'a.txt'), 'FAIL\n')
        self.age_all(5)
        rc, out = self.run_verify(expect_rc=1)
        rc, out = self.run_verify(expect_rc=1)
        self.assertIn('a', self.ran(out), out)
        self.assertNotIn('b', self.ran(out), 'the suites that passed were stored: ' + out)

    def test_an_interrupted_run_stores_nothing(self):
        rc, out = self.run_verify(env={'TV_INTERRUPT': '1'})
        self.assertNotEqual(rc, 0, out)
        self.assertEqual(self.ran(out), {'a', 'b'}, out)
        self.assertEqual(self.entries(), [], 'a and b passed, but the run never reached its end')
        rc, out = self.run_verify(expect_rc=0)
        self.assertEqual(self.ran(out), {'a', 'b', 'c', 'd', 'decl'}, out)

    def test_an_input_edited_while_the_suite_ran_is_not_stored(self):
        # a rewrites its own input after reading it, at the same size: only
        # the modification time can tell. Stored, the entry would hold bytes
        # the suite never read -- and the second run would skip it.
        rc, out = self.run_verify(env={'TV_TOUCH_LUA': '1'}, expect_rc=0)
        self.assertIn('not stored: test_a (data/a.txt was modified while it ran)', out)
        rc, out = self.run_verify(env={'TV_TOUCH_LUA': '1'}, expect_rc=0)
        self.assertIn('a', self.ran(out), out)

    def test_an_edit_just_before_the_run_is_stored(self):
        # Saved, then verify at once -- the usual way. That is before the
        # unit started, so it is what the suite read, and storable.
        write(self.p('data', 'a.txt'), 'alpha, saved just now\n')
        rc, out = self.run_verify(expect_rc=0)
        self.assertNotIn('not stored', out)
        rc, out = self.run_verify(expect_rc=0)
        self.assertEqual(self.ran(out), set(), out)

    def test_a_python_input_changed_while_the_suite_ran_is_not_stored(self):
        # Hashed when it was read, compared at the commit: c reads one.txt and
        # then appends to it, as an editor saving mid-run would.
        rc, out = self.run_verify(env={'TV_TOUCH': '1'}, expect_rc=0)
        self.assertRegex(out, r'not stored: test_c \([^)]*one\.txt changed while it ran\)')
        rc, out = self.run_verify(env={'TV_TOUCH': '1'}, expect_rc=0)
        self.assertIn('c', self.ran(out), out)

    def test_the_cache_itself_changing_mid_run_stores_nothing(self):
        # The driver appends to the Lua tracer after test_a: the units after
        # it ran under a tracer the key would not name, and test_a under one
        # it would no longer.
        rc, out = self.run_verify(env={'TV_TOUCH_TOOL': '1'}, expect_rc=0)
        self.assertEqual(self.ran(out), {'a', 'b', 'c', 'd', 'decl'}, out)
        self.assertIn('not stored: anything from this run (verify.sh or the cache itself changed', out)
        rc, out = self.run_verify(expect_rc=0)
        self.assertEqual(self.ran(out), {'a', 'b', 'c', 'd', 'decl'}, out)

    def test_a_suite_with_an_unrepeatable_command_is_never_stored(self):
        write(self.p('tools', 'test_a.lua'), "os.execute('exit 0')\nprint('a ran')\n")
        self.age_all(5)
        rc, out = self.run_verify(expect_rc=0)
        self.assertIn('not stored: test_a (os.execute: exit 0)', out)
        rc, out = self.run_verify(expect_rc=0)
        self.assertEqual(self.ran(out), {'a'}, out)

    def test_an_unfinished_trace_is_not_stored(self):
        # The tracer writes END only after the script returns or exits 0. A
        # trace without it -- the process was killed -- is no pass.
        run = self.p('.verify-cache', 'runs', 'x')
        os.makedirs(run)
        write(os.path.join(run, 'u.1.ltrace'), 'V1\nF\t1\t6\tdata/a.txt\n')
        write(os.path.join(run, 'passed'), 'u\tunit u\t%f\n' % time.time())
        r = subprocess.run([sys.executable, self.p('tools', 'vcache.py'), 'commit', '--root', self.root,
                            '--lua', LUA, '--run', run], stdout=subprocess.PIPE)
        self.assertIn(b'not stored: unit u (the run did not finish)', r.stdout)
        self.assertEqual(self.entries(), [])


    def test_a_traced_process_that_left_no_trace_is_not_stored(self):
        # Review of #397: a unit with declared inputs whose tracer could not
        # write its trace used to be stored on the declared inputs alone.
        run = self.p('.verify-cache', 'runs', 'y')
        os.makedirs(run)
        write(os.path.join(run, 'passed'), 'u\tunit u\t%f\tlist:data:.txt\ttraces:1\n' % time.time())
        r = subprocess.run([sys.executable, self.p('tools', 'vcache.py'), 'commit', '--root', self.root,
                            '--lua', LUA, '--run', run], stdout=subprocess.PIPE)
        self.assertIn(b'not stored: unit u (0 of 1 traced processes left a trace)', r.stdout)
        self.assertEqual(self.entries(), [])


class Tracers(Checkout):

    def lua(self, script, *args):
        write(self.p('s.lua'), script)
        tr = self.p('t.ltrace')
        if os.path.exists(tr):
            os.remove(tr)
        r = subprocess.run([LUA, 'tools/vcache_trace.lua', tr, 's.lua'] + list(args), cwd=self.root,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        trace = open(tr, encoding='utf-8').read() if os.path.exists(tr) else None
        return r.returncode, r.stdout.decode().replace('\r\n', '\n'), trace

    def test_the_script_sees_its_own_arg_and_varargs(self):
        rc, out, _ = self.lua("print(arg[0], arg[1], arg[2], select('#', ...), ...)\n", 'x', 'y z')
        self.assertEqual(rc, 0)
        self.assertEqual(out, 's.lua\tx\ty z\t2\tx\ty z\n')

    def test_exit_codes_are_the_scripts(self):
        self.assertEqual(self.lua('os.exit(3)\n')[0], 3)
        self.assertEqual(self.lua('os.exit(false)\n')[0], 1)
        self.assertEqual(self.lua("error('boom')\n")[0], 1)
        self.assertEqual(self.lua("print('fine')\n")[0], 0)
        self.assertEqual(self.lua('os.exit(true)\n')[0], 0)

    def test_only_a_success_writes_a_finished_trace(self):
        self.assertIsNone(self.lua("io.open('data/a.txt'):close(); os.exit(1)\n")[2])
        self.assertIsNone(self.lua("io.open('data/a.txt'):close(); error('x')\n")[2])
        trace = self.lua("io.open('data/a.txt'):close()\n")[2]
        self.assertTrue(trace.endswith('END\t0\n'), trace)

    def test_every_way_to_read_is_recorded_and_a_written_file_is_not_an_input(self):
        rc, out, trace = self.lua(
            "io.open('data/a.txt'):close()\n"
            "for _ in io.lines('data/flag.txt') do end\n"
            "dofile('tools/lib.lua')\n"
            "loadfile('./data/../tools/lib.lua')\n"
            "io.open('data/missing.txt')\n"
            "local w = io.open('data/made.txt', 'w'); w:write('x'); w:close()\n"
            "io.open('data/made.txt'):close()\n"
            "os.getenv('TV_UNSET_FOR_SURE')\n")
        self.assertEqual(rc, 0, out)
        self.assertIn('F\t1\t6\tdata/a.txt\n', trace)
        self.assertIn('\tdata/flag.txt\n', trace)
        self.assertEqual(trace.count('\ttools/lib.lua\n'), 1, 'one input however it is spelled')
        self.assertIn('F\t0\t-1\tdata/missing.txt\n', trace)
        self.assertNotIn('made.txt', trace)
        self.assertIn('E\tTV_UNSET_FOR_SURE\t0\t\n', trace)

    def test_require_records_the_candidates_before_the_one_that_loaded(self):
        write(self.p('mods', 'm.lua'), 'return 7\n')
        rc, out, trace = self.lua("package.path = 'early/?.lua;mods/?.lua'\nprint((require('m')))\n")
        self.assertEqual(out, '7\n')
        self.assertIn('F\t0\t-1\tearly/m.lua\n', trace)
        self.assertIn('F\t1\t9\tmods/m.lua\n', trace)

    def test_python_tracer_keeps_argv_exit_code_and_main(self):
        write(self.p('s.py'), 'import sys\nprint(sys.argv, __name__)\nsys.exit(int(sys.argv[1]))\n')
        for code in (0, 4):
            r = subprocess.run([sys.executable, 'tools/vcache_trace.py', self.p('t.ptrace'), 's.py', str(code)],
                               cwd=self.root, stdout=subprocess.PIPE)
            self.assertEqual(r.returncode, code)
            self.assertEqual(r.stdout.decode().strip(), "['s.py', '%d'] __main__" % code)


class Identity(unittest.TestCase):

    def test_a_different_lua_binary_is_a_different_key(self):
        sys.path.insert(0, TOOLS)
        import vcache
        d = tempfile.mkdtemp(prefix='vcache-lua-')
        self.addCleanup(shutil.rmtree, d, True)
        exe = os.path.join(d, 'lua.exe' if os.name == 'nt' else 'lua')
        dll = os.path.join(d, 'lua54.dll' if os.name == 'nt' else 'liblua5.4.so')
        write(exe, 'interpreter')
        write(dll, 'library one')
        one = vcache.Machine(d, exe).lua_identity()
        write(dll, 'library two')
        two = vcache.Machine(d, exe).lua_identity()
        self.assertIsNotNone(one)
        self.assertNotEqual(one, two, 'the shared library is part of the interpreter')


def main():
    global LUA, BASH
    ap = argparse.ArgumentParser()
    ap.add_argument('--lua', required=True)
    a, rest = ap.parse_known_args()
    LUA = a.lua
    if os.name == 'nt':
        m = re.match(r'^/([A-Za-z])(/.*)$', LUA)
        if m:
            LUA = m.group(1).upper() + ':' + m.group(2)
        if not os.path.isfile(LUA) and os.path.isfile(LUA + '.exe'):
            LUA += '.exe'
        LUA = LUA.replace(os.sep, '/')
    BASH = find_bash()
    if not BASH:
        print('test_vcache: skip (no bash)')
        return 0
    report = io.StringIO()
    prog = unittest.main(argv=[sys.argv[0]] + rest, exit=False,
                         testRunner=unittest.TextTestRunner(stream=report, verbosity=0))
    r = prog.result
    if r.wasSuccessful():
        print('\033[32mok\033[0m   %d cases: every change to an input re-runs its suite; nothing that failed '
              'or was cut short is stored' % r.testsRun)
        return 0
    sys.stdout.write(report.getvalue())
    return 1


if __name__ == '__main__':
    sys.exit(main())
