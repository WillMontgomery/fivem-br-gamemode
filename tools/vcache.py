"""tools/vcache.py -- verify.sh's pass cache: which suites may be skipped, and
writing down the ones that passed. docs/testing.md has the whole story.

    python3 tools/vcache.py check  --root DIR --lua PATH
    python3 tools/vcache.py commit --root DIR --lua PATH --run RUNDIR [--full]

A UNIT is one suite or gate verify.sh can skip. When one passes, verify.sh has
a trace of everything it read (tools/vcache_trace.lua, tools/vcache_trace.py)
and, for the shell parts no tracer can see, the inputs it DECLARES. `commit`
hashes all of it and stores, per unit:

    the key    verify.sh, this file and both tracers (sha256 each), and the
               identity of the interpreters the unit ran under
    the inputs every (kind, path, state) it read: a file's sha256 or `absent`,
               a directory listing's hash, a command's output, an environment
               variable's value hash

`check` prints the units whose key and every input are what they were. A unit
is skipped ONLY then; anything it cannot evaluate counts as changed.

`commit` refuses a unit whose inputs moved while it ran: a file whose existence
or size differs from what the tracer saw, a hash that differs from the one the
Python tracer took at the read, or any input modified after the unit started.
It runs once, after every gate, so an interrupted verify writes nothing; and
verify.sh hands it only units that exited 0, so a failure is never stored --
a unit that failed has its old entry deleted instead.

Lives in <root>/.verify-cache/ (gitignored): entries/ and runs/.
"""

import argparse
import hashlib
import json
import os
import re
import stat as S
import subprocess
import sys
import time

SCHEMA = 2
SLACK = 2.0          # seconds: an input modified this close to a unit's start is too close to call
RUN_MAX_AGE = 12 * 3600

TOOL_FILES = ('tools/verify.sh', 'tools/vcache.py', 'tools/vcache_trace.lua', 'tools/vcache_trace.py')


def sha_bytes(b):
    return hashlib.sha256(b).hexdigest()


def sha_file(path):
    h = hashlib.sha256()
    with open(path, 'rb') as fh:
        for block in iter(lambda: fh.read(1 << 20), b''):
            h.update(block)
    return h.hexdigest()


def native(path):
    """An MSYS path (/c/Users/...) as Windows spells it; anything else as is."""
    if os.name == 'nt':
        m = re.match(r'^/([A-Za-z])(/.*)?$', path)
        if m:
            return m.group(1).upper() + ':' + (m.group(2) or '/')
    return path


def file_state(path):
    try:
        if os.path.isdir(path):
            return 'dir'
        return sha_file(path)
    except FileNotFoundError:
        return 'absent'
    except OSError as e:
        return 'error:%s' % type(e).__name__


def listing_state(path):
    try:
        names = []
        with os.scandir(path) as it:
            for e in it:
                try:
                    d = e.is_dir()
                except OSError:
                    d = False
                names.append(e.name + ('/' if d else ''))
    except FileNotFoundError:
        return 'absent'
    except NotADirectoryError:
        return 'notdir'
    except OSError as e:
        return 'error:%s' % type(e).__name__
    names.sort()
    return sha_bytes('\n'.join(names).encode('utf-8', 'surrogatepass'))


def stat_state(path, follow=True):
    try:
        st = os.stat(path) if follow else os.lstat(path)
    except FileNotFoundError:
        return 'absent'
    except OSError as e:
        return 'error:%s' % type(e).__name__
    if S.S_ISDIR(st.st_mode):
        return 'dir'
    if S.S_ISLNK(st.st_mode):
        return 'link'
    return 'file:%d' % st.st_size


# Shell bookkeeping, not configuration: bash gives a child started inside $( )
# a different SHLVL from one started directly, sets _ to the command it runs,
# and PWD/OLDPWD say where verify.sh was started from (it cd's to the root).
# Every other variable is an input of a unit that records the environment.
VOLATILE_ENV = ('_', 'SHLVL', 'PWD', 'OLDPWD')


def env_state(hashes=None):
    """The environment as one hash: every variable but VOLATILE_ENV. From
    os.environ, or from the per-variable hashes a Python trace recorded."""
    if hashes is None:
        hashes = {k: sha_bytes(v.encode('utf-8', 'surrogatepass')) for k, v in os.environ.items()}
    if os.name == 'nt':
        hashes = {k.upper(): v for k, v in hashes.items()}
    rows = sorted('%s=%s' % (k, v) for k, v in hashes.items() if k.upper() not in VOLATILE_ENV)
    return sha_bytes('\0'.join(rows).encode('utf-8', 'surrogatepass'))


def cmd_state(cmd, cwd):
    """What io.popen(cmd) would give the script now: exit code and output,
    with CRLF read as LF the way Lua's text-mode pipe reads it on Windows."""
    try:
        r = subprocess.run(cmd, shell=True, cwd=cwd, stdout=subprocess.PIPE,
                           stdin=subprocess.DEVNULL, timeout=60)
    except (OSError, subprocess.SubprocessError) as e:
        return 'error:%s' % type(e).__name__
    out = r.stdout
    if os.name == 'nt':
        out = out.replace(b'\r\n', b'\n')
    return '%d:%s' % (r.returncode, sha_bytes(out))


def text_cmd_state(code, out_bytes):
    return '%s:%s' % (code, sha_bytes(out_bytes))


def tree_files(root, rel, suffix):
    """Every file under rel (recursive, as `find` walks it) ending in suffix,
    sorted, and every directory walked: a declared `tree:` or `list:` input."""
    files, dirs = [], []
    base = os.path.join(root, rel)
    for d, dnames, fnames in os.walk(base):
        dnames.sort()
        dirs.append(d)
        for n in sorted(fnames):
            if not suffix or n.endswith(suffix):
                files.append(os.path.join(d, n))
    return files, dirs


class Machine:
    """What is true now: hashes of the tool files and interpreters, and a
    memo so a file read by forty suites is hashed once."""

    def __init__(self, root, lua):
        self.root = os.path.abspath(root)
        self.lua = native(lua) if lua else ''
        self.memo = {}

    def abs(self, p):
        return p if os.path.isabs(p) else os.path.join(self.root, p)

    def rel(self, p):
        a = os.path.abspath(self.abs(p))
        try:
            r = os.path.relpath(a, self.root)
        except ValueError:
            return a.replace('\\', '/')
        if r.startswith('..'):
            return a.replace('\\', '/')
        return r.replace('\\', '/')

    def tools(self):
        if 'tools' not in self.memo:
            self.memo['tools'] = {f: file_state(self.abs(f)) for f in TOOL_FILES}
        return self.memo['tools']

    def lua_identity(self):
        if 'lua' not in self.memo:
            parts = []
            p = self.lua
            if p and not os.path.isfile(p) and os.path.isfile(p + '.exe'):
                p = p + '.exe'
            if p and os.path.isfile(p):
                p = os.path.realpath(p)
                parts.append('%s=%s' % (os.path.basename(p), sha_file(p)))
                d = os.path.dirname(p)
                for n in sorted(os.listdir(d)):
                    if re.match(r'^(lua|liblua).*\.(dll|so[.0-9]*|dylib)$', n, re.I):
                        parts.append('%s=%s' % (n, sha_file(os.path.join(d, n))))
                self.memo['lua'] = sha_bytes('\n'.join(parts).encode())
            else:
                self.memo['lua'] = None
        return self.memo['lua']

    def py_identity(self):
        if 'py' not in self.memo:
            parts = [sys.version, sys.executable]
            exe = os.path.realpath(sys.executable)
            parts.append(file_state(exe))
            d = os.path.dirname(exe)
            for n in sorted(os.listdir(d)):
                if re.match(r'^(python|libpython)[0-9.]*\.(dll|so[.0-9]*|dylib)$', n, re.I):
                    parts.append('%s=%s' % (n, sha_file(os.path.join(d, n))))
            self.memo['py'] = sha_bytes('\n'.join(parts).encode('utf-8', 'surrogatepass'))
        return self.memo['py']

    def key(self, uses):
        k = {'schema': SCHEMA, 'tools': self.tools()}
        if 'lua' in uses:
            k['lua'] = self.lua_identity()
        if 'py' in uses:
            k['py'] = self.py_identity()
        return k

    def state(self, kind, path):
        m = (kind, path)
        if m in self.memo:
            return self.memo[m]
        a = self.abs(path) if kind not in ('env', 'envall', 'cmd', 'list') else path
        if kind in ('f', 'exe'):
            v = file_state(a)
        elif kind == 'ls':
            v = listing_state(a)
        elif kind == 'st':
            v = stat_state(a)
        elif kind == 'lst':
            v = stat_state(a, follow=False)
        elif kind == 'env':
            v = os.environ.get(path)
            v = 'unset' if v is None else sha_bytes(v.encode('utf-8', 'surrogatepass'))
        elif kind == 'envall':
            v = env_state()
        elif kind == 'list':
            rel, _, suffix = path.partition(':')
            files, _ = tree_files(self.root, rel, suffix)
            v = sha_bytes('\n'.join(self.rel(f) for f in files).encode('utf-8', 'surrogatepass'))
        elif kind == 'cmd':
            v = cmd_state(path, self.root)
        else:
            v = 'unknown-kind'
        self.memo[m] = v
        return v


def cache_dir(root):
    return os.path.join(root, '.verify-cache')


def entry_path(root, unit):
    return os.path.join(cache_dir(root), 'entries',
                        hashlib.sha1(unit.encode('utf-8')).hexdigest()[:20] + '.json')


def load_entries(root):
    d = os.path.join(cache_dir(root), 'entries')
    out = []
    if not os.path.isdir(d):
        return out
    for n in sorted(os.listdir(d)):
        if not n.endswith('.json'):
            continue
        try:
            with open(os.path.join(d, n), encoding='utf-8') as fh:
                e = json.load(fh)
        except (OSError, ValueError):
            continue
        if isinstance(e, dict) and e.get('schema') == SCHEMA:
            out.append(e)
    return out


def still_valid(m, e):
    """True only when the key and every recorded input are what they were."""
    try:
        if e['key'] != m.key(e['uses']):
            return False
        for kind, path, want in e['inputs']:
            if m.state(kind, path) != want:
                return False
    except (KeyError, TypeError, ValueError):
        return False
    return True


def cmd_check(a):
    root = os.path.abspath(a.root)
    clean_runs(root)
    m = Machine(root, a.lua)
    for e in load_entries(root):
        if still_valid(m, e):
            when = time.strftime('%Y-%m-%d %H:%M', time.localtime(e.get('passed', 0)))
            sys.stdout.write('%s\t%s\t%d\n' % (e['unit'], when, len(e['inputs'])))
    return 0


def clean_runs(root):
    d = os.path.join(cache_dir(root), 'runs')
    if not os.path.isdir(d):
        return
    now = time.time()
    for n in os.listdir(d):
        p = os.path.join(d, n)
        try:
            if now - os.stat(p).st_mtime > RUN_MAX_AGE:
                rmtree(p)
        except OSError:
            pass


def rmtree(p):
    import shutil
    shutil.rmtree(p, ignore_errors=True)


# --- reading traces -------------------------------------------------------------

def unesc(s):
    return re.sub(r'%([0-9A-F]{2})', lambda mm: chr(int(mm.group(1), 16)), s)


class Refused(Exception):
    pass


def read_lua_trace(m, path, start, inputs, pinned_env):
    """A tools/vcache_trace.lua trace: F, C, E and X lines, and END."""
    with open(path, encoding='utf-8', errors='surrogateescape') as fh:
        lines = fh.read().split('\n')
    if not lines or lines[0] != 'V1':
        raise Refused('unreadable trace')
    if 'END\t0' not in lines:
        raise Refused('the run did not finish')
    for line in lines[1:]:
        if not line or line.startswith('END\t'):
            continue
        f = line.split('\t')
        t = f[0]
        if t == 'X':
            raise Refused(unesc(f[1]))
        if t == 'F':
            existed, size, p = f[1] == '1', int(f[2]), unesc(f[3])
            a = m.abs(p)
            try:
                st = os.stat(a)
                now_exists = True
                if S.S_ISDIR(st.st_mode):
                    # fopen of a directory fails on Windows and half-works
                    # elsewhere; either way it read no content. Its kind is
                    # the input.
                    inputs[('f', m.rel(p))] = 'dir'
                    continue
            except FileNotFoundError:
                now_exists = False
            except OSError as e:
                raise Refused('cannot stat %s (%s)' % (p, e))
            if now_exists != existed:
                raise Refused('%s %s while it ran' % (p, 'appeared' if now_exists else 'disappeared'))
            if now_exists:
                if S.S_ISREG(st.st_mode) and st.st_size != size and size >= 0:
                    raise Refused('%s changed size while it ran' % p)
                if st.st_mtime > start - SLACK:
                    raise Refused('%s was modified while it ran' % p)
            inputs[('f', m.rel(p))] = m.state('f', m.rel(p))
        elif t == 'C':
            code, side, cmd = f[1], unesc(f[2]), unesc(f[3])
            with open(m.abs(side), 'rb') as sfh:
                out = sfh.read()
            have = text_cmd_state(code, out)
            # What the command gives now must be what the suite was given, or
            # the tree moved under it while it ran.
            if m.state('cmd', cmd) != have:
                raise Refused('`%s` answers differently now' % cmd)
            inputs[('cmd', cmd)] = have
        elif t == 'E':
            name, isset = unesc(f[1]), f[2] == '1'
            if name in pinned_env:
                continue
            v = sha_bytes(unesc(f[3]).encode('utf-8', 'surrogateescape')) if isset else 'unset'
            inputs[('env', name)] = v
        else:
            raise Refused('unknown trace line %r' % t)


def read_py_trace(m, path, start, inputs):
    """A tools/vcache_trace.py trace: one JSON object a line."""
    with open(path, encoding='utf-8') as fh:
        rows = [json.loads(l) for l in fh if l.strip()]
    if not rows or rows[0].get('v') != 1:
        raise Refused('unreadable trace')
    if rows[-1] != {'k': 'END', 'status': 0}:
        raise Refused('the run did not finish')
    head = rows[0]
    if head.get('executable') != sys.executable or head.get('python') != sys.version:
        raise Refused('ran under a different Python than this one')
    if not isinstance(head.get('env'), dict):
        raise Refused('unreadable trace')
    started = env_state(head['env'])
    if started != env_state():
        raise Refused('the environment changed while it ran')
    inputs[('envall', '')] = started
    for r in rows[1:-1]:
        k = r.get('k')
        if k == 'X':
            raise Refused(r.get('why', 'uncacheable'))
        p = m.rel(r['p'])
        now = m.state(k, p)
        if now != r['h']:
            raise Refused('%s changed while it ran' % p)
        if r.get('late') and now not in ('absent', 'dir'):
            try:
                if os.stat(m.abs(p)).st_mtime > start - SLACK:
                    raise Refused('%s was modified while it ran' % p)
            except OSError:
                raise Refused('cannot stat %s' % p)
        inputs[(k, p)] = now


def declared(m, decl, start, inputs):
    """The inputs verify.sh declares for the shell half of a unit:

      file:PATH            one file's content (absent counts)
      tree:DIR[:SUFFIX]    every file under DIR ending in SUFFIX: the listing
                           of every directory walked, and each file's content
      list:DIR[:SUFFIX]    the same file list, names only -- what a `find`
                           that builds a suite's arguments sees
      exe:PATH             a program's binary
      env                  the whole environment
    """
    for d in decl:
        kind, _, rest = d.partition(':')
        if kind == 'env':
            inputs[('envall', '')] = m.state('envall', '')
        elif kind in ('file', 'exe'):
            p = native(rest) if kind == 'exe' else rest
            a = m.abs(p)
            if kind == 'exe' and not os.path.isfile(a) and os.path.isfile(a + '.exe'):
                p, a = p + '.exe', a + '.exe'
            try:
                if os.stat(a).st_mtime > start - SLACK:
                    raise Refused('%s was modified while it ran' % p)
            except FileNotFoundError:
                pass
            inputs[('f', m.rel(p))] = m.state('f', m.rel(p))
        elif kind == 'list':
            rel, _, suffix = rest.partition(':')
            files, dirs = tree_files(m.root, rel, suffix)
            for dd in dirs:
                if os.stat(dd).st_mtime > start - SLACK:
                    raise Refused('%s gained or lost a file while it ran' % m.rel(dd))
            inputs[('list', rest)] = m.state('list', rest)
        elif kind == 'tree':
            rel, _, suffix = rest.partition(':')
            files, dirs = tree_files(m.root, rel, suffix)
            for dd in dirs:
                if os.stat(dd).st_mtime > start - SLACK:
                    raise Refused('%s gained or lost a file while it ran' % m.rel(dd))
                inputs[('ls', m.rel(dd))] = m.state('ls', m.rel(dd))
            for f in files:
                if os.stat(f).st_mtime > start - SLACK:
                    raise Refused('%s was modified while it ran' % m.rel(f))
                inputs[('f', m.rel(f))] = m.state('f', m.rel(f))
        else:
            raise Refused('unknown declared input %r' % d)


def write_entry(root, entry):
    path = entry_path(root, entry['unit'])
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = '%s.%d.tmp' % (path, os.getpid())
    with open(tmp, 'w', encoding='utf-8', newline='\n') as fh:
        json.dump(entry, fh, indent=0, sort_keys=True)
    os.replace(tmp, path)


def tools_moved(m, since):
    """True when verify.sh, this file or a tracer was modified after `since`,
    less the slack -- or cannot be read at all."""
    for f in TOOL_FILES:
        try:
            if os.stat(m.abs(f)).st_mtime > since - SLACK:
                return True
        except OSError:
            return True
    return False


def drop_entry(root, unit):
    try:
        os.remove(entry_path(root, unit))
    except FileNotFoundError:
        pass


def cmd_commit(a):
    root = os.path.abspath(a.root)
    run = os.path.abspath(a.run)
    m = Machine(root, a.lua)
    passed, failed = [], []
    for name, bucket in (('passed', passed), ('failed', failed)):
        p = os.path.join(run, name)
        if os.path.isfile(p):
            with open(p, encoding='utf-8') as fh:
                for line in fh:
                    line = line.rstrip('\n')
                    if line:
                        bucket.append(line.split('\t'))
    for row in failed:
        drop_entry(root, row[1])
    starts = [float(row[2]) for row in passed]
    if starts and tools_moved(m, min(starts)):
        # The key names these files as they are NOW, and the run used them as
        # they were: nothing from it can be stored under either.
        rmtree(run)
        sys.stdout.write('not stored: anything from this run (verify.sh or the cache '
                         'itself changed while it ran)\n')
        return 0
    kept, refused = set(), []
    for row in passed:
        uid, unit, start = row[0], row[1], float(row[2])
        decl = [d for d in row[3:] if d]
        pinned = set(d[4:] for d in decl if d.startswith('pin:'))
        decl = [d for d in decl if not d.startswith('pin:')]
        inputs, uses = {}, set()
        try:
            traces = sorted(n for n in os.listdir(run)
                            if n.startswith(uid + '.') and n.endswith(('.ltrace', '.ptrace')))
            for n in traces:
                if n.endswith('.ltrace'):
                    uses.add('lua')
                    read_lua_trace(m, os.path.join(run, n), start, inputs, pinned)
                else:
                    uses.add('py')
                    read_py_trace(m, os.path.join(run, n), start, inputs)
            if not traces and not decl:
                raise Refused('nothing was recorded')
            declared(m, decl, start, inputs)
        except Refused as e:
            drop_entry(root, unit)
            refused.append('%s (%s)' % (unit, e))
            continue
        except (OSError, ValueError, IndexError) as e:
            drop_entry(root, unit)
            refused.append('%s (%s: %s)' % (unit, type(e).__name__, e))
            continue
        entry = {
            'schema': SCHEMA, 'unit': unit, 'passed': start, 'uses': sorted(uses),
            'key': m.key(uses),
            'inputs': sorted([k, p, v] for (k, p), v in inputs.items()),
        }
        write_entry(root, entry)
        kept.add(unit)
    if a.full:
        # A full run is the whole cache: what did not pass in it is not kept.
        for e in load_entries(root):
            if e['unit'] not in kept:
                drop_entry(root, e['unit'])
    rmtree(run)
    if refused:
        more = len(refused) - 6
        shown = refused[:6] + (['and %d more' % more] if more > 0 else [])
        sys.stdout.write('not stored: %s\n' % '; '.join(shown))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(prog='vcache.py')
    sub = ap.add_subparsers(dest='cmd', required=True)
    c = sub.add_parser('check')
    c.add_argument('--root', required=True)
    c.add_argument('--lua', default='')
    w = sub.add_parser('commit')
    w.add_argument('--root', required=True)
    w.add_argument('--lua', default='')
    w.add_argument('--run', required=True)
    w.add_argument('--full', action='store_true')
    a = ap.parse_args(argv)
    return cmd_check(a) if a.cmd == 'check' else cmd_commit(a)


if __name__ == '__main__':
    sys.exit(main())
