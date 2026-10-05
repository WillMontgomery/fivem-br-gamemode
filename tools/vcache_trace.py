"""tools/vcache_trace.py -- runs one Python suite or gate and writes down what
it READ, for verify.sh's pass cache (tools/vcache.py, docs/testing.md).

    python3 tools/vcache_trace.py <trace-file> <script> [args...]

The script runs as `python3 <script> [args...]` would: sys.argv, sys.path[0],
__name__ == '__main__', the same exit status. Before it starts, every way this
process reaches the disk or another process is wrapped:

  open (builtins and io), os.open      a file read, hashed at the moment it is
                                       first read; opened for writing, a path
                                       this run produced
  os.listdir, os.scandir (so os.walk,  a directory listing, hashed when taken:
  glob and pathlib too)                a new file under it is a change
  os.stat, os.lstat, os.path.exists,   a path's kind and size
  isfile, isdir, islink, getsize
  subprocess.Popen (so run, call,      the executable's binary and every
  check_output, os.popen)              argument that names a file or directory
  os.system, exec*, spawn*, startfile  uncacheable: the run is never stored
  the environment                      all of it, once: a child process
                                       inherits every variable
  imported modules                     every module file outside the standard
                                       library, hashed at the end

Paths under a directory this run created, or written by it, are its own
output, not inputs. What a CHILD process reads beyond its own script is not
visible from here; docs/testing.md says which suites spawn children and what
verify.sh declares for them.

The trace is written only when the script exits 0. vcache.py commit compares
every hash taken here with the file as it is at the end of verify, and refuses
the entry if anything moved while the suite ran.

THIS FILE IS PART OF EVERY PYTHON CACHE KEY. Editing it invalidates them.
"""

import builtins
import hashlib
import io
import json
import os
import shutil
import stat as S
import subprocess
import sys
import sysconfig
import traceback
import types

if len(sys.argv) < 3:
    sys.stderr.write('usage: python3 tools/vcache_trace.py <trace-file> <script> [args...]\n')
    sys.exit(2)

TRACE = os.path.abspath(sys.argv[1])
SCRIPT = sys.argv[2]
ARGS = sys.argv[3:]
CWD = os.getcwd()
# Taken before the script can touch os.environ: every child inherits it. One
# hash per variable; vcache.py decides which are shell bookkeeping.
ENV_AT_START = {k: hashlib.sha256(v.encode('utf-8', 'surrogatepass')).hexdigest()
                for k, v in os.environ.items()}

_real = {
    'open': builtins.open, 'os_open': os.open, 'listdir': os.listdir, 'scandir': os.scandir,
    'stat': os.stat, 'lstat': os.lstat, 'exists': os.path.exists, 'lexists': os.path.lexists,
    'isfile': os.path.isfile, 'isdir': os.path.isdir, 'islink': os.path.islink,
    'getsize': os.path.getsize, 'mkdir': os.mkdir, 'makedirs': os.makedirs,
    'remove': os.remove, 'unlink': os.unlink, 'rmdir': os.rmdir, 'rename': os.rename,
    'replace': os.replace, 'Popen': subprocess.Popen,
}

events = []
seen = set()
produced = set()
_busy = [False]

_STDLIB = []
for key in ('stdlib', 'platstdlib'):
    p = sysconfig.get_paths().get(key)
    if p:
        _STDLIB.append(os.path.normcase(os.path.abspath(p)))
_STDLIB.append(os.path.normcase(os.path.join(sys.base_prefix, 'DLLs')))


def _key(p):
    return os.path.normcase(os.path.abspath(p))


def _path(p):
    if isinstance(p, int):
        return None
    try:
        p = os.fspath(p)
    except TypeError:
        return None
    if isinstance(p, bytes):
        p = os.fsdecode(p)
    return p


def _is_produced(k):
    while True:
        if k in produced:
            return True
        parent = os.path.dirname(k)
        if parent == k:
            return False
        k = parent


def _real_key(p):
    """The path as the OS resolves it. On Windows an 8.3 short name and its
    long form are one directory -- tempfile hands out C:/Users/WILLIA~1/...
    while realpath answers with the long name -- so a run's own directory has
    to be recognised in both spellings."""
    was, _busy[0] = _busy[0], True
    try:
        return os.path.normcase(os.path.realpath(p))
    except (OSError, ValueError):
        return _key(p)
    finally:
        _busy[0] = was


def _produce(p):
    p = _path(p)
    if p:
        produced.add(_key(p))
        produced.add(_real_key(p))


def _sha(path):
    h = hashlib.sha256()
    with _real['open'](path, 'rb') as fh:
        for block in iter(lambda: fh.read(1 << 20), b''):
            h.update(block)
    return h.hexdigest()


def _listing(path):
    names = []
    with _real['scandir'](path) as it:
        for e in it:
            try:
                d = e.is_dir()
            except OSError:
                d = False
            names.append(e.name + ('/' if d else ''))
    names.sort()
    return hashlib.sha256('\n'.join(names).encode('utf-8', 'surrogatepass')).hexdigest()


def _file_state(path):
    try:
        if _real['isdir'](path):
            return 'dir'
        return _sha(path)
    except FileNotFoundError:
        return 'absent'
    except OSError as e:
        return 'error:%s' % type(e).__name__


def _stat_state(path, follow=True):
    try:
        st = _real['stat'](path) if follow else _real['lstat'](path)
    except FileNotFoundError:
        return 'absent'
    except OSError as e:
        return 'error:%s' % type(e).__name__
    if S.S_ISDIR(st.st_mode):
        return 'dir'
    if S.S_ISLNK(st.st_mode):
        return 'link'
    return 'file:%d' % st.st_size


def _record(kind, p, state_fn, force=False):
    # _busy: this module's own probing (hashing, resolving a program on PATH)
    # goes through the same wrapped functions and is not the script's reading.
    if _busy[0] and not force:
        return
    p = _path(p)
    if not p:
        return
    k = _key(p)
    tag = (kind, k)
    if tag in seen:
        return
    seen.add(tag)
    if _is_produced(k) or _is_produced(_real_key(p)):
        return
    was, _busy[0] = _busy[0], True
    try:
        events.append({'k': kind, 'p': os.path.abspath(p), 'h': state_fn(p)})
    finally:
        _busy[0] = was


def _read(p, force=False):
    _record('f', p, _file_state, force)


def _ls(p, force=False):
    def state(x):
        try:
            return _listing(x)
        except FileNotFoundError:
            return 'absent'
        except NotADirectoryError:
            return 'notdir'
        except OSError as e:
            return 'error:%s' % type(e).__name__
    _record('ls', p, state, force)


def _st(p):
    _record('st', p, _stat_state)


def _uncacheable(why):
    events.append({'k': 'X', 'why': why})


_WRITE = set('wax+')


def traced_open(file, mode='r', *a, **kw):
    p = _path(file)
    if p is not None:
        if _WRITE & set(mode):
            if 'r' in mode or '+' in mode and 'w' not in mode and 'a' not in mode:
                _read(p)
            _produce(p)
        else:
            _read(p)
    return _real['open'](file, mode, *a, **kw)


_WFLAGS = os.O_WRONLY | os.O_RDWR | os.O_CREAT | os.O_APPEND | os.O_TRUNC


def traced_os_open(path, flags, *a, **kw):
    if flags & _WFLAGS:
        if not flags & (os.O_CREAT | os.O_TRUNC):
            _read(path)
        _produce(path)
    else:
        _read(path)
    return _real['os_open'](path, flags, *a, **kw)


def traced_listdir(path='.'):
    _ls(path)
    return _real['listdir'](path)


def traced_scandir(path='.'):
    _ls(path)
    return _real['scandir'](path)


def traced_stat(path, *a, **kw):
    _st(path)
    return _real['stat'](path, *a, **kw)


def traced_lstat(path, *a, **kw):
    _record('lst', path, lambda x: _stat_state(x, follow=False))
    return _real['lstat'](path, *a, **kw)


def _wrap_query(name):
    real = _real[name]

    def query(path, *a, **kw):
        _st(path)
        return real(path, *a, **kw)
    query.__name__ = name
    return query


def traced_mkdir(path, *a, **kw):
    _produce(path)
    return _real['mkdir'](path, *a, **kw)


def traced_makedirs(name, *a, **kw):
    # Only the directories this call creates are this run's; an existing
    # parent (the repo, the temp dir) is not.
    p = _path(name)
    if p:
        p = os.path.abspath(p)
        missing = []
        while p and not _real['exists'](p):
            missing.append(p)
            parent = os.path.dirname(p)
            if parent == p:
                break
            p = parent
        for m in missing:
            _produce(m)
    return _real['makedirs'](name, *a, **kw)


def _consume(name):
    real = _real[name]

    def f(*paths, **kw):
        for p in paths[:2]:
            _produce(p)
        return real(*paths, **kw)
    f.__name__ = name
    return f


def _record_child(args, kw):
    exe = kw.get('executable')
    cwd = kw.get('cwd') or CWD
    env = kw.get('env')
    shell = kw.get('shell', False)
    if isinstance(args, (str, bytes, os.PathLike)):
        argv = [os.fsdecode(os.fspath(args))]
    else:
        argv = [os.fsdecode(os.fspath(a)) if isinstance(a, (str, bytes, os.PathLike)) else str(a)
                for a in args]
    if shell:
        prog = os.environ.get('COMSPEC', 'cmd.exe') if os.name == 'nt' else '/bin/sh'
    else:
        prog = exe or (argv[0] if argv else None)
    if prog:
        prog = os.fsdecode(os.fspath(prog))
        path = (env or os.environ).get('PATH')
        resolved = prog if os.path.isabs(prog) else shutil.which(prog, path=path)
        if resolved is None and not os.path.isabs(prog):
            cand = os.path.join(cwd, prog)
            resolved = cand if _real['exists'](cand) else None
        if resolved and _key(resolved) != _key(sys.executable):
            _record('exe', resolved, _file_state, force=True)
    for a in argv[1:] if not shell else argv:
        if not a or a.startswith('-') or len(a) > 1024:
            continue
        cand = a if os.path.isabs(a) else os.path.join(cwd, a)
        try:
            if _real['isdir'](cand):
                _ls(cand, force=True)
            elif _real['isfile'](cand):
                _read(cand, force=True)
        except (OSError, ValueError):
            pass


class TracedPopen(_real['Popen']):
    def __init__(self, args, *a, **kw):
        if a:
            names = ('bufsize', 'executable', 'stdin', 'stdout', 'stderr', 'preexec_fn',
                     'close_fds', 'shell', 'cwd', 'env')
            for n, v in zip(names, a):
                kw.setdefault(n, v)
            a = ()
        if not _busy[0]:
            _busy[0] = True
            try:
                _record_child(args, kw)
            finally:
                _busy[0] = False
        super().__init__(args, *a, **kw)


def _forbidden(name):
    real = getattr(os, name)

    def f(*a, **kw):
        _uncacheable('os.%s' % name)
        return real(*a, **kw)
    f.__name__ = name
    return f


def install():
    builtins.open = traced_open
    io.open = traced_open
    os.open = traced_os_open
    os.listdir = traced_listdir
    os.scandir = traced_scandir
    os.stat = traced_stat
    os.lstat = traced_lstat
    for name in ('exists', 'lexists', 'isfile', 'isdir', 'islink', 'getsize'):
        setattr(os.path, name, _wrap_query(name))
    os.mkdir = traced_mkdir
    os.makedirs = traced_makedirs
    for name in ('remove', 'unlink', 'rmdir', 'rename', 'replace'):
        setattr(os, name, _consume(name))
    subprocess.Popen = TracedPopen
    for name in ('system', 'startfile', 'execv', 'execve', 'execl', 'execle', 'execlp',
                 'execlpe', 'execvp', 'execvpe', 'spawnv', 'spawnve', 'spawnl', 'spawnle',
                 'posix_spawn', 'posix_spawnp', 'fork', 'forkpty'):
        if hasattr(os, name):
            setattr(os, name, _forbidden(name))


def _module_files():
    out = []
    for m in list(sys.modules.values()):
        f = getattr(m, '__file__', None)
        if not f:
            continue
        k = _key(f)
        if any(k == s or k.startswith(s + os.sep) for s in _STDLIB) and 'site-packages' not in k:
            continue
        if k == _key(__file__):
            continue
        out.append(os.path.abspath(f))
    return sorted(set(out))


def write_trace():
    _busy[0] = True
    for f in _module_files():
        k = _key(f)
        if ('f', k) not in seen and not _is_produced(k):
            seen.add(('f', k))
            events.append({'k': 'f', 'p': f, 'h': _file_state(f), 'late': True})
    head = {
        'v': 1, 'cwd': CWD, 'script': SCRIPT, 'args': ARGS,
        'python': sys.version, 'executable': sys.executable,
        'env': ENV_AT_START,
    }
    tmp = TRACE + '.tmp'
    with _real['open'](tmp, 'w', encoding='utf-8', newline='\n') as fh:
        fh.write(json.dumps(head) + '\n')
        for e in events:
            fh.write(json.dumps(e) + '\n')
        fh.write(json.dumps({'k': 'END', 'status': 0}) + '\n')
    _real['replace'](tmp, TRACE)


def main():
    # As `python3 SCRIPT` does it: argv[0] as typed, __file__ absolute, the
    # script's directory first on sys.path, and the script AS __main__ (so
    # unittest.main finds its tests). runpy.run_path would make argv[0]
    # absolute, which a script printing its own usage would show.
    script = os.path.abspath(SCRIPT)
    sys.argv = [SCRIPT] + ARGS
    sys.path[0] = os.path.dirname(script)
    with _real['open'](script, 'rb') as fh:
        source = fh.read()
    code_obj = compile(source, script, 'exec', dont_inherit=True)
    main_mod = types.ModuleType('__main__')
    main_mod.__file__ = script
    main_mod.__builtins__ = builtins
    main_mod.__spec__ = None
    main_mod.__loader__ = None
    main_mod.__cached__ = None
    sys.modules['__main__'] = main_mod
    install()
    _read(script)
    code = 0
    try:
        exec(code_obj, main_mod.__dict__)
    except SystemExit as e:
        c = e.code
        if c is None:
            code = 0
        elif isinstance(c, int):
            code = c
        else:
            code = 1
        if code == 0:
            write_trace()
        raise
    except KeyboardInterrupt:
        raise
    except BaseException:
        traceback.print_exc()
        sys.exit(1)
    write_trace()
    sys.exit(code)


if __name__ == '__main__':
    main()
