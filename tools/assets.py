#!/usr/bin/env python3
"""Licensed assets: purchased resources the boxes run but this repo never holds (#391).

    py tools/assets.py publish <drop folder>                     on the owner's PC (Publish.cmd runs it)
    py tools/assets.py init-drop <drop folder>                   makes the drop folder, its README and Publish.cmd
    py tools/assets.py push <folder>... [--season N]             on the owner's PC
    py tools/assets.py retire <name> [--season N]                a null pin: gone from Season N on
    python3 tools/assets.py pull [--stage | --swap | --dry-run]  on a game box (deploy.sh runs it)
    py tools/assets.py status [--profile blitz-assets]           lock vs installed vs bucket
    py tools/assets.py check                                     verify.sh and CI

WHY THIS EXISTS. The NTeam Legion map pack and the emote packs for #215 were
bought, and their licenses do not allow redistribution. This repository is
PUBLIC, so they can never be committed to it. They live in a private S3 bucket
instead, one archive per version, and assets.lock at the repo root pins which
version each box runs: a commit bumps an asset, `git revert` rolls it back, dev
deploys run dev's lock and prod runs main's, so assets ship with an episode PR
the way code does.

THE LOCK HOLDS NAMES, HASHES, SIZES, FILE LISTS AND SEASON PINS, AND NOTHING
ELSE. `check` refuses any other key. The file lists are there so a test or an
agent can check that our code's references (anim dicts, model names) exist in
a pack without having the pack.

SEASONS (#388). An entry maps seasons to pins; the pin in force is the one at
the newest season at or below the box's season, exactly like BR.Season.pick. A
pin is a version's sha256, or null: REMOVED from that season on, until a later
pin brings a version back. {"1": A, "3": null, "5": B} is A in Seasons 1-2,
nothing in 3-4, B from 5. Before the earliest pin the resource is not
installed either. That is the whole season model, in ONE form: no leading
null, no pin that repeats the one in force (check refuses both). The box's
season is the br_season br_core sees when it starts (cfg_season() says how
FXServer gets there); unset means `latest` in seasons.lua, as in game.

THE DROP FOLDER. The owner drags packs into `Season <n>` folders with File
Explorer and double-clicks Publish.cmd, which runs `publish`: the folders ARE
the lock's contents, so a pack moved, replaced or deleted there is published as
exactly that, and an EMPTY folder with a pack's name in a later season is a
null pin there. Publish works in its own clone of the repo, never in a
checkout anyone else uses (see cmd_publish).

FOUR RULES THE CODE BELOW EXISTS TO KEEP, each pinned by tools/test_assets.py:

  * EVERY ARCHIVE'S SHA256 IS CHECKED BEFORE IT IS UNPACKED. fetch_verified()
    is the only door to an archive path, and a pull unpacks nothing until every
    archive it needs has come through it.
  * NOTHING OUTSIDE resources/[licensed]/ IS EVER REMOVED OR REPLACED, and a
    failed pull leaves what was installed exactly as it was: everything is
    downloaded, verified and unpacked into a staging directory first, and only
    then swapped in, journaled, with every move undone if one fails.
  * A TRASH DIR IS NEVER DELETED WHILE IT HOLDS THE ONLY COPY OF SOMETHING. A
    swap whose undo fails too leaves it, says where everything is, and stops.
  * AN OBJECT IN THE BUCKET IS NEVER OVERWRITTEN. The key is the archive's own
    sha256, so a different archive is a different key, and nothing uploads
    when the key exists.

Stdlib only, and the transfers go through the `aws` CLI so credentials stay
with the CLI: a profile on the owner's PC, the instance role on a box. This
file never reads them.
"""

from __future__ import annotations

import argparse
import base64
import contextlib
import gzip
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import types

BUCKET = 'blitz-royale-assets'
REGION = 'us-east-2'
KEY_PREFIX = 'assets/'
PUSH_PROFILE = 'blitz-assets'

LOCK_NAME = 'assets.lock'
# 2: a season pin may be null (removed from that season on), and `from` and
# `until` are gone -- the earliest pin and a null pin say both, in one form.
LOCK_FORMAT = 2

# Where a box keeps them. resources/[licensed]/ belongs to this tool: deploy.sh
# never syncs into it, and a pull may remove any resource directory inside it
# that the lock does not list for the box's season.
LICENSED_GROUP = '[licensed]'
CFG_FILE = 'licensed.cfg'
# The install record, inside a resource so br_core can read it: FXServer's Lua
# sandbox refuses io outside resource folders, and LoadResourceFile needs the
# resource only to be known to the server, not started. Never ensured.
# br_core/server/season.lua names both strings; tools/test_season.lua pins them.
RECORD_RESOURCE = 'br_licensed'
RECORD_FILE = 'installed.txt'
# What the record says for a resource in [licensed] whose version nobody knows:
# one a failed swap's undo left there with no earlier record of it. brseason
# and status say it in words; the next pull reinstalls it.
UNKNOWN_VERSION = 'unknown'
CACHE_DIR = '.assets-cache'
DEFAULT_SERVER_ROOT = '/opt/fivem-server-classic'

# Inside the cache: the staged set between `pull --stage` and `pull --swap`,
# the stage's description of it, a swap's journal (in its trash dir), and when
# each archive was last in force (for the prune).
STAGED_DIR = '.staged'
STAGE_FILE = 'stage.json'
JOURNAL_FILE = 'journal.json'
LAST_USED_FILE = '.last-used.json'
PRUNE_AFTER = 14 * 24 * 3600

# The drop folder (publish, init-drop). Publish.cmd, the README and the index
# sit at its top level, beside the Season folders, and are never packs.
PUBLISH_CMD = 'Publish.cmd'
DROP_README = 'README.txt'
DROP_INDEX = '.publish-index.json'
DROP_SEASONS = (1, 2)
SEASON_DIR_RE = re.compile(r'season[ \t]+([0-9]+)\Z', re.I)
PUBLISH_BRANCH = 'dev'

# Publish's own clone of the repo (cmd_publish): made on first use, fetched on
# every Publish, and never a work tree an agent or the owner works in. The
# mark is how publish knows a --clone path is one it made.
ORIGIN_URL = 'https://github.com/WillMontgomery/fivem-br-gamemode.git'
CLONE_MARK = 'blitzassets.publishclone'
CLONE_IN_LOCALAPPDATA = r'%LOCALAPPDATA%\BlitzAssets\repo'
PUBLISH_RETRIES = 5

SEASONS_LUA = ('resources', '[fivem-royale]', 'br_lib', 'config', 'seasons.lua')
SEASON_CONVAR = 'br_season'
# br_core reads br_season once, when it starts; a value set after the line
# that starts it is never seen.
SEASON_READER = 'br_core'
MAX_SEASON = 9999

TOOL_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(TOOL_DIR)

NAME_RE = re.compile(r'[A-Za-z0-9_][A-Za-z0-9_-]{0,63}\Z')
SHA_RE = re.compile(r'[0-9a-f]{64}\Z')
SEASON_KEY_RE = re.compile(r'[1-9][0-9]{0,3}\Z')

# Left out of a pack, so the same resource packs to the same sha on a machine
# whose file browser has been in the folder.
JUNK_FILES = frozenset(('thumbs.db', 'desktop.ini', '.ds_store'))
JUNK_DIRS = frozenset(('.git', '.svn', '.hg'))

ENTRY_KEYS = ('name', 'seasons', 'versions')
VERSION_KEYS = ('size', 'files')

RECORD_MANIFEST = """\
-- GENERATED by tools/assets.py pull (#391). Do not edit, and do not ensure it:
-- br_core reads installed.txt out of it with LoadResourceFile, which needs the
-- resource to be known to the server, not started.
fx_version 'cerulean'
game 'gta5'
"""


class AssetsError(Exception):
    """A refusal with a message for the operator. Exit 1."""


class DoubleFault(AssetsError):
    """A swap failed and so did its undo. The trash dir is kept."""


def say(msg: str = '') -> None:
    print(('assets: ' + msg) if msg else '', flush=True)


def human(n: int) -> str:
    size = float(n)
    for unit in ('B', 'KB', 'MB', 'GB'):
        if size < 1024 or unit == 'GB':
            return ('%d %s' % (size, unit)) if unit == 'B' else ('%.1f %s' % (size, unit))
        size /= 1024
    return '%d B' % n


def short(sha: str) -> str:
    return sha[:12]


def object_key(name: str, sha: str) -> str:
    return '%s%s/%s.tar.gz' % (KEY_PREFIX, name, sha)


def sha256_file(path: str) -> tuple[str, int]:
    h = hashlib.sha256()
    n = 0
    with open(path, 'rb') as fh:
        while True:
            block = fh.read(1 << 20)
            if not block:
                break
            h.update(block)
            n += len(block)
    return h.hexdigest(), n


def is_int(v) -> bool:
    return isinstance(v, int) and not isinstance(v, bool)


def bad_rel_path(p) -> str | None:
    """Why a path from a pack, an archive or the lock is unsafe, or None.

    Relative, forward slashes, no empty, `.` or `..` segment, no drive letter,
    no control character. An archive member that passes cannot land outside
    the directory it is unpacked into.
    """
    if not isinstance(p, str) or not p:
        return 'empty path'
    if len(p) > 400:
        return 'path longer than 400 characters'
    if '\\' in p:
        return 'backslash in path'
    if p.startswith('/'):
        return 'absolute path'
    if re.match(r'[A-Za-z]:', p):
        return 'drive letter in path'
    if any(ord(c) < 32 or ord(c) == 127 for c in p):
        return 'control character in path'
    if any(part in ('', '.', '..') for part in p.split('/')):
        return 'empty, "." or ".." segment in path'
    return None


# --------------------------------------------------------------------------
# durable writes
# --------------------------------------------------------------------------
#
# A swap renames directories into resources/[licensed]/. A rename is atomic,
# but on Linux the bytes behind it are not on disk until they are synced: a
# power cut after the rename could leave a resource whose files are empty. So
# everything staged is fsynced, files and directories, before the first rename,
# and the directories a rename touched are fsynced after it.

def fsync_file(path: str) -> None:
    # Windows' FlushFileBuffers needs a handle opened for writing.
    flags = (os.O_RDWR | getattr(os, 'O_BINARY', 0)) if os.name == 'nt' else os.O_RDONLY
    fd = os.open(path, flags)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def fsync_dir(path: str) -> None:
    """A directory's entries, durable. POSIX only: Windows cannot open a
    directory this way, and NTFS journals its own metadata."""
    if os.name == 'nt':
        return
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def fsync_tree(root: str) -> None:
    for dirpath, _dirnames, filenames in os.walk(root):
        for f in filenames:
            fsync_file(os.path.join(dirpath, f))
        fsync_dir(dirpath)


def write_bytes_atomic(path: str, data: bytes) -> None:
    tmp = '%s.tmp-%d' % (path, os.getpid())
    with open(tmp, 'wb') as fh:
        fh.write(data)
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, path)
    fsync_dir(os.path.dirname(path) or '.')


def atomic_write(path: str, text: str) -> None:
    write_bytes_atomic(path, text.encode('utf-8'))


def read_bytes(path: str) -> bytes | None:
    try:
        with open(path, 'rb') as fh:
            return fh.read()
    except FileNotFoundError:
        return None


def read_json(path: str):
    raw = read_bytes(path)
    if raw is None:
        return None
    try:
        return json.loads(raw.decode('utf-8'))
    except (ValueError, UnicodeDecodeError):
        return None


def is_link(path: str) -> bool:
    if os.path.islink(path):
        return True
    isjunction = getattr(os.path, 'isjunction', None)
    return bool(isjunction and isjunction(path))


def inside(path: str, root: str) -> bool:
    p = os.path.normcase(os.path.abspath(path))
    r = os.path.normcase(os.path.abspath(root))
    return p.startswith(r.rstrip(os.sep) + os.sep)


# --------------------------------------------------------------------------
# packing
# --------------------------------------------------------------------------

def collect(folder: str) -> tuple[list[tuple[str, str, int, int]], list[str]]:
    """The files a pack holds, as (relative path, full path, size, mtime_ns),
    sorted, and what was left out.

    Plain files only: a link anywhere in the folder is refused rather than
    followed, because what it points at is not part of the resource.
    """
    root = os.path.abspath(folder)
    files: list[tuple[str, str, int, int]] = []
    skipped: list[str] = []

    def rel(full):
        return os.path.relpath(full, root).replace(os.sep, '/')

    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        keep = []
        for d in dirnames:
            full = os.path.join(dirpath, d)
            if is_link(full):
                raise AssetsError('%s is a link; a resource folder must hold plain files only' % rel(full))
            if d.lower() in JUNK_DIRS:
                skipped.append(rel(full) + '/')
                continue
            keep.append(d)
        dirnames[:] = keep
        for f in filenames:
            full = os.path.join(dirpath, f)
            relp = rel(full)
            if f.lower() in JUNK_FILES:
                skipped.append(relp)
                continue
            st = os.lstat(full)
            if stat.S_ISLNK(st.st_mode) or is_link(full):
                raise AssetsError('%s is a link; a resource folder must hold plain files only' % relp)
            if not stat.S_ISREG(st.st_mode):
                raise AssetsError('%s is not a regular file' % relp)
            why = bad_rel_path(relp)
            if why:
                raise AssetsError('%s: %s' % (relp, why))
            files.append((relp, full, st.st_size, st.st_mtime_ns))
    files.sort(key=lambda t: t[0].encode('utf-8'))
    return files, sorted(skipped)


class _Hashing:
    """A file read through, hashing every byte that is read."""

    def __init__(self, fh):
        self.fh = fh
        self.h = hashlib.sha256()

    def read(self, n=-1):
        block = self.fh.read(n)
        self.h.update(block)
        return block


def write_pack(files: list[tuple[str, str, int, int]], out_path: str,
               digests: dict[str, str] | None = None) -> None:
    """THE SAME FILES ALWAYS GIVE THE SAME BYTES, so an unchanged pack is a
    no-op rather than a new version: entries sorted, no directory entries,
    mtime 0, owner 0:0 with no names, mode 0644, and a gzip header with no file
    name and no timestamp. Paths are relative to the folder, so the resource's
    name comes from the lock and never from inside an archive.

    `digests`, when given, gets each path's sha256 OF THE BYTES THAT WENT INTO
    THE ARCHIVE, read once, so publish's index can never describe a pack by
    bytes it did not hold."""
    with open(out_path, 'wb') as raw:
        with gzip.GzipFile(filename='', mode='wb', fileobj=raw, compresslevel=6, mtime=0) as gz:
            with tarfile.open(fileobj=gz, mode='w', format=tarfile.PAX_FORMAT, encoding='utf-8') as tar:
                for relp, full, size, _mtime in files:
                    info = tarfile.TarInfo(relp)
                    info.size = size
                    info.mtime = 0
                    info.mode = 0o644
                    info.uid = info.gid = 0
                    info.uname = info.gname = ''
                    info.type = tarfile.REGTYPE
                    with open(full, 'rb') as fh:
                        src = _Hashing(fh)
                        tar.addfile(info, src)
                        if digests is not None:
                            digests[relp] = src.h.hexdigest()


def pack(folder: str, out_path: str) -> tuple[dict[str, int], list[str]]:
    """Pack a resource folder into a .tar.gz, deterministically."""
    files, skipped = collect(folder)
    if not any(relp == 'fxmanifest.lua' for relp, _, _, _ in files):
        raise AssetsError('%s has no fxmanifest.lua at its top; it is not a FiveM resource folder' % folder)
    write_pack(files, out_path)
    return {relp: size for relp, _, size, _ in files}, skipped


def unpack(archive: str, dest: str, files: dict[str, int]) -> None:
    """Write a VERIFIED archive's files into `dest`, which must not exist yet.

    Only ever handed a path fetch_verified() returned. Regular files only, each
    path checked by bad_rel_path, nothing ever overwritten, and the result must
    be exactly the lock's file list.
    """
    os.makedirs(dest)
    seen: dict[str, int] = {}
    with tarfile.open(archive, mode='r:gz') as tar:
        for m in tar:
            why = bad_rel_path(m.name)
            if why:
                raise AssetsError('archive member %r: %s' % (m.name, why))
            if m.isdir():
                continue
            if not m.isreg():
                raise AssetsError('archive member %r is not a regular file' % m.name)
            if m.name in seen:
                raise AssetsError('archive member %r appears twice' % m.name)
            target = os.path.join(dest, *m.name.split('/'))
            os.makedirs(os.path.dirname(target), exist_ok=True)
            src = tar.extractfile(m)
            with open(target, 'xb') as out:
                shutil.copyfileobj(src, out, 1 << 20)
            seen[m.name] = m.size
    if seen != files:
        raise AssetsError("the archive's files differ from the file list in assets.lock")


def dir_files(path: str) -> dict[str, int]:
    out: dict[str, int] = {}
    for dirpath, _dirnames, filenames in os.walk(path):
        for f in filenames:
            full = os.path.join(dirpath, f)
            out[os.path.relpath(full, path).replace(os.sep, '/')] = os.path.getsize(full)
    return out


# --------------------------------------------------------------------------
# the lock
# --------------------------------------------------------------------------

def _no_duplicate_keys(pairs):
    out = {}
    for k, v in pairs:
        if k in out:
            raise AssetsError('assets.lock: the key %r appears twice in one object' % k)
        out[k] = v
    return out


def parse_lock_text(text: str):
    if text.startswith('\ufeff'):
        text = text[1:]
    try:
        return json.loads(text, object_pairs_hook=_no_duplicate_keys)
    except json.JSONDecodeError as e:
        raise AssetsError('assets.lock is not valid JSON: %s' % e)


def repo_resource_names(root: str = REPO_ROOT) -> frozenset[str]:
    """Lower-cased names of the resources this repository ships. A licensed
    resource may not share one: FiveM would see two resources with one name."""
    names = set()
    base = os.path.join(root, 'resources')
    for dirpath, dirnames, filenames in os.walk(base):
        dirnames[:] = [d for d in dirnames if d != 'node_modules' and not d.startswith('.')]
        if 'fxmanifest.lua' in filenames or '__resource.lua' in filenames:
            names.add(os.path.basename(dirpath).lower())
            dirnames[:] = []
    return frozenset(names)


def validate(data, repo_names: frozenset[str] = frozenset()) -> list[str]:
    """Every way the lock is wrong, or [] when it is right."""
    p: list[str] = []
    if not isinstance(data, dict):
        return ['the lock must be a JSON object']
    extra = sorted(set(data) - {'format', 'resources'})
    if extra:
        p.append('unknown top-level key(s) %s: a lock holds names, hashes, sizes, '
                 'file lists and season pins, nothing else' % ', '.join(extra))
    if data.get('format') != LOCK_FORMAT or not is_int(data.get('format')):
        p.append('"format" must be %d' % LOCK_FORMAT)
    res = data.get('resources')
    if not isinstance(res, list):
        p.append('"resources" must be a list')
        return p
    seen: set[str] = set()
    for i, e in enumerate(res):
        where = 'resources[%d]' % i
        if not isinstance(e, dict):
            p.append('%s is not an object' % where)
            continue
        name = e.get('name')
        if isinstance(name, str) and name:
            where = name
        extra = sorted(set(e) - set(ENTRY_KEYS))
        if extra:
            p.append('%s: unknown key(s) %s (allowed: %s)' % (where, ', '.join(extra), ', '.join(ENTRY_KEYS)))
        if not isinstance(name, str) or not NAME_RE.match(name):
            p.append('%s: "name" must be a resource name: letters, digits, _ and -, at most 64' % where)
        else:
            low = name.lower()
            if low in seen:
                p.append('%s: listed twice' % name)
            seen.add(low)
            if low == RECORD_RESOURCE:
                p.append('%s: the name is reserved for the install record' % name)
            if low in repo_names:
                p.append('%s: a resource in this repository already has that name' % name)
        seasons = e.get('seasons')
        if not isinstance(seasons, dict) or not seasons:
            p.append('%s: "seasons" must map at least one season to a sha256' % where)
            seasons = {}
        pinned: set[str] = set()
        pins: list[tuple[int, str | None]] = []
        for k, sha in seasons.items():
            good_key = bool(SEASON_KEY_RE.match(k))
            if not good_key:
                p.append('%s: %r is not a season (a whole number from 1, no leading zero)' % (where, k))
            if sha is None:
                if good_key:
                    pins.append((int(k), None))
                continue
            if not isinstance(sha, str) or not SHA_RE.match(sha):
                p.append('%s: Season %s: %r is not a sha256 (64 lowercase hex) or null' % (where, k, sha))
                continue
            pinned.add(sha)
            if good_key:
                pins.append((int(k), sha))
        # ONE FORM: every pin changes what is in force. A null with nothing in
        # force before it removes nothing, and a pin equal to the one in force
        # says nothing; either would make two locks mean the same thing.
        in_force = None
        for n, sha in sorted(pins, key=lambda t: t[0]):
            if sha is None and in_force is None:
                p.append('%s: the null pin at Season %d removes nothing: no version is in force before it; '
                         'drop it' % (where, n))
            elif sha is not None and sha == in_force:
                p.append('%s: Season %d pins %s, the version already in force before it; drop the pin'
                         % (where, n, short(sha)))
            in_force = sha
        if seasons and not pinned:
            p.append('%s: "seasons" pins no version (a sha256) at any season' % where)
        versions = e.get('versions')
        if not isinstance(versions, dict):
            p.append('%s: "versions" must be an object keyed by sha256' % where)
            versions = {}
        for sha, v in versions.items():
            if not SHA_RE.match(sha):
                p.append('%s: version key %r is not a sha256' % (where, sha))
                continue
            if sha not in pinned:
                p.append('%s: version %s is pinned to no season; drop it (git history keeps it)' % (where, short(sha)))
            if not isinstance(v, dict):
                p.append('%s: version %s is not an object' % (where, short(sha)))
                continue
            extra = sorted(set(v) - set(VERSION_KEYS))
            if extra:
                p.append('%s: version %s: unknown key(s) %s (allowed: size, files)' % (where, short(sha), ', '.join(extra)))
            if not is_int(v.get('size')) or v.get('size') <= 0:
                p.append('%s: version %s: "size" must be the archive size in bytes' % (where, short(sha)))
            files = v.get('files')
            if not isinstance(files, dict) or not files:
                p.append('%s: version %s: "files" must map each path in the archive to its size' % (where, short(sha)))
                continue
            for path, n in files.items():
                why = bad_rel_path(path)
                if why:
                    p.append('%s: version %s: %r: %s' % (where, short(sha), path, why))
                if not is_int(n) or n < 0:
                    p.append('%s: version %s: %r: size must be a whole number of bytes' % (where, short(sha), path))
            if 'fxmanifest.lua' not in files:
                p.append('%s: version %s has no fxmanifest.lua at its top' % (where, short(sha)))
        for sha in sorted(pinned - set(versions)):
            p.append('%s: %s is pinned to a season but has no entry under "versions"' % (where, short(sha)))
    return p


def load_lock(path: str, repo_names: frozenset[str] | None = None) -> dict:
    """The lock, validated. An absent lock is an empty one."""
    raw = read_bytes(path)
    if raw is None:
        return {'format': LOCK_FORMAT, 'resources': []}
    data = parse_lock_text(raw.decode('utf-8', 'replace'))
    problems = validate(data, repo_resource_names() if repo_names is None else repo_names)
    if problems:
        raise AssetsError('%s does not pass check:\n%s' % (path, '\n'.join('  ' + x for x in problems)))
    return data


def dump_lock(lock: dict) -> str:
    """The lock as it is written: one field per line, in a fixed order."""
    out = []
    for e in lock['resources']:
        o = {'name': e['name']}
        keys = sorted(e['seasons'], key=int)
        o['seasons'] = {k: e['seasons'][k] for k in keys}
        order: list[str] = []
        for k in keys:
            if e['seasons'][k] is not None and e['seasons'][k] not in order:
                order.append(e['seasons'][k])
        o['versions'] = {
            sha: {
                'size': e['versions'][sha]['size'],
                'files': {f: e['versions'][sha]['files'][f]
                          for f in sorted(e['versions'][sha]['files'], key=lambda s: s.encode('utf-8'))},
            }
            for sha in order
        }
        out.append(o)
    return json.dumps({'format': LOCK_FORMAT, 'resources': out}, indent=2, ensure_ascii=False) + '\n'


def version_for(entry: dict, season: int) -> str | None:
    """The sha in force for `season`: the pin at the newest season at or below
    it -- or None, and the resource is not installed: every pin is later, or
    the one in force is null (removed from that season on)."""
    best = None
    for k, sha in entry['seasons'].items():
        n = int(k)
        if n <= season and (best is None or n > best[0]):
            best = (n, sha)
    return best[1] if best else None


def canonical_pins(seasons: dict) -> dict:
    """The same seasons -> pins, in the one form check accepts: a pin that
    changes nothing in force (a leading null, a null after a null, a sha
    after the same sha) is dropped."""
    out: dict = {}
    in_force = None
    for k in sorted(seasons, key=int):
        if seasons[k] == in_force:
            continue
        out[k] = seasons[k]
        in_force = seasons[k]
    return out


def pin_text(sha: str | None) -> str:
    return 'removed' if sha is None else short(sha)


def plan_for(lock: dict, season: int) -> list[tuple[str, str, dict]]:
    """(name, sha, version) for every resource in force, in lock order."""
    out = []
    for e in lock['resources']:
        sha = version_for(e, season)
        if sha is not None:
            out.append((e['name'], sha, e['versions'][sha]))
    return out


# --------------------------------------------------------------------------
# the box's season
# --------------------------------------------------------------------------

def read_latest(repo_root: str = REPO_ROOT) -> int:
    path = os.path.join(repo_root, *SEASONS_LUA)
    try:
        with open(path, encoding='utf-8', errors='replace') as fh:
            text = fh.read()
    except OSError:
        raise AssetsError('cannot read %s, which says the latest season' % path)
    m = re.search(r'^[ \t]*latest[ \t]*=[ \t]*([0-9]+)', text, re.M)
    if not m or int(m.group(1)) < 1:
        raise AssetsError('no `latest = <n>` in %s' % path)
    return int(m.group(1))


def parse_season(raw) -> int | None:
    """BR.Season.parse: a whole number from 1, digits only, spaces forgiven."""
    if not isinstance(raw, str):
        return None
    s = raw.strip()
    if not re.match(r'[0-9]+\Z', s):
        return None
    n = int(s)
    return n if 1 <= n <= MAX_SEASON else None


def cfg_commands(text: str) -> list[tuple[int, list[str]]]:
    """The commands a cfg's text runs, as FXServer splits them: (line, tokens).

    A UTF-8 BOM at the top is dropped. A line holds several commands split on
    `;` outside double quotes. Tokens split on whitespace, a double-quoted
    token keeps its spaces and semicolons, and a `#` or `//` that starts a
    token ends the line."""
    if text.startswith('\ufeff'):
        text = text[1:]
    out: list[tuple[int, list[str]]] = []
    for lineno, line in enumerate(text.splitlines(), 1):
        toks: list[str] = []
        i, n = 0, len(line)
        while i < n:
            c = line[i]
            if c == ';':
                if toks:
                    out.append((lineno, toks))
                    toks = []
                i += 1
                continue
            if c.isspace():
                i += 1
                continue
            if c == '"':
                j = line.find('"', i + 1)
                if j < 0:
                    j = n
                toks.append(line[i + 1:j])
                i = j + 1
                continue
            if c == '#' or line.startswith('//', i):
                break
            j = i
            while j < n and not line[j].isspace() and line[j] not in '";':
                j += 1
            toks.append(line[i:j])
            i = j
        if toks:
            out.append((lineno, toks))
    return out


SET_COMMANDS = ('set', 'setr', 'sets', 'seta')


def season_assignment(t: list[str], exists: bool) -> str | None:
    """The value one cfg command gives br_season, or None when it gives none.

    `set`/`setr`/`sets`/`seta br_season V` always assign (and create the
    convar). A BARE `br_season V` assigns only once the convar exists: a
    convar registers a command under its own name, taking exactly one
    argument, and before that `br_season` is no command at all. Names are
    case-insensitive in both places."""
    cmd = t[0].lower()
    if cmd in SET_COMMANDS and len(t) == 3 and t[1].lower() == SEASON_CONVAR:
        return t[2]
    if cmd == SEASON_CONVAR and len(t) == 2 and exists:
        return t[1]
    return None


def cfg_season(server_root: str, cfg_path: str) -> tuple[tuple[str, str, int] | None, list[str]]:
    """The value br_core sees for br_season, as (value, file, line), plus notes
    on anything that could not be followed.

    WHAT br_core SEES IS NOT THE LAST ASSIGNMENT IN THE FILE, and not the last
    one above `ensure br_core` either. FXServer reads its cfg TWICE, and this
    follows both passes (citizenfx/fivem at e34d12cd):

      1. THE EARLY EXEC, code/components/citizen-server-main/src/
         ServerInstance.cpp, ServerInstance::Run, "run early exec so we can
         set convars": every cfg runs once in a scratch console whose `exec`
         only QUEUES the file (fakeExecCommand), so nested files run after the
         one that names them. `ensure` does nothing there. At the end, every
         convar it created is forwarded into the real console with
         `set <name> <value>` -- except one flagged ServerInfo, which `sets`
         creates or adds (the `!(flags & ConVar_ServerInfo)` test).
      2. THE REAL EXEC, the same file's `exec` command (AddCommand("exec"))
         runs each file inline through Context::ExecuteBuffer
         (code/client/citicore/console/Console.cpp), which splits commands on
         newlines and on `;` outside quotes. br_core reads br_season once,
         when `ensure br_core` (or `start`) starts it, so the walk STOPS there.

    And in both passes a bare `br_season 6` is an assignment once the convar
    exists: ConsoleVariableEntry registers a set command under the convar's
    own name (code/client/citicore/console/Console.Variables.h, m_setCommand,
    one argument), command names compare case-insensitively (IgnoreCaseLess in
    Console.Commands.h), and InvokeDirect tries each overload until one takes
    the argument count. Before the convar exists it is "No such command".

    So the real pass STARTS with br_season already set to the early pass's
    last value, whenever the early pass created it without `sets`: a
    `set br_season 2` BELOW `ensure br_core` still reaches br_core, and a bare
    `br_season 6` above everything assigns. Not modeled: `+set` on the command
    line (deploy.sh's boxes pass only `+exec server.cfg`), and a file exec'd
    twice, which is followed once."""
    notes: list[str] = []

    def target_of(path: str, lineno: int, t: list[str]) -> str | None:
        target = t[1]
        if target.startswith('@'):
            notes.append('%s:%d: exec %s is inside a resource; not followed' % (path, lineno, target))
            return None
        return target if os.path.isabs(target) else os.path.join(server_root, target)

    def commands(path: str):
        try:
            raw = read_bytes(path)
        except OSError as e:
            notes.append('%s: %s' % (path, e.strerror or e))
            return None
        if raw is None:
            notes.append('%s does not exist' % path)
            return None
        return cfg_commands(raw.decode('utf-8', 'replace'))

    # Pass 1, the early exec: breadth first, nothing stops it.
    early = None
    early_exists = early_serverinfo = False
    queue, queued = [cfg_path], {os.path.normcase(os.path.abspath(cfg_path))}
    while queue:
        path = queue.pop(0)
        for lineno, t in commands(path) or []:
            v = season_assignment(t, early_exists)
            if v is not None:
                early = (v, path, lineno)
                early_exists = True
                if t[0].lower() == 'sets':
                    early_serverinfo = True
            elif t[0].lower() == 'exec' and len(t) >= 2:
                target = target_of(path, lineno, t)
                key = target and os.path.normcase(os.path.abspath(target))
                if key and key not in queued:
                    queued.add(key)
                    queue.append(target)
    notes_early = list(notes)
    del notes[:]

    # Pass 2, the real exec: in order, from the forwarded value, to br_core.
    found: list = [early if early_exists and not early_serverinfo else None]
    exists = [found[0] is not None]
    seen: set[str] = set()
    started = [False]

    def walk(path: str, depth: int) -> None:
        key = os.path.normcase(os.path.abspath(path))
        if key in seen:
            return
        if depth > 16:
            notes.append('%s: exec nested too deep, not followed' % path)
            return
        seen.add(key)
        for lineno, t in commands(path) or []:
            if started[0]:
                return
            v = season_assignment(t, exists[0])
            cmd = t[0].lower()
            if v is not None:
                found[0] = (v, path, lineno)
                exists[0] = True
            elif cmd in ('ensure', 'start') and len(t) >= 2 and t[1] == SEASON_READER:
                started[0] = True
                return
            elif cmd == 'exec' and len(t) >= 2:
                target = target_of(path, lineno, t)
                if target:
                    walk(target, depth + 1)

    walk(cfg_path, 0)
    # The real pass reads every file the early one did; say each problem once.
    for n in notes_early:
        if n not in notes:
            notes.append(n)
    return found[0], notes


def resolve_season(args, server_root: str, latest: int) -> tuple[int, str]:
    if getattr(args, 'season', None) is not None:
        return args.season, '--season %d' % args.season
    cfg = args.server_cfg or os.path.join(server_root, 'server.cfg')
    found, notes = cfg_season(server_root, cfg)
    for n in notes:
        say('note: ' + n)
    if found is None:
        return latest, '%s is not set: the latest' % SEASON_CONVAR
    raw, path, lineno = found
    n = parse_season(raw)
    where = '%s:%d' % (os.path.basename(path), lineno)
    if n is None:
        say('warning: %s %r (%s) is not a season; using the latest, Season %d, as the game does'
            % (SEASON_CONVAR, raw, where, latest))
        return latest, '%s %r is not a season: the latest' % (SEASON_CONVAR, raw)
    return n, '%s %d, %s' % (SEASON_CONVAR, n, where)


# --------------------------------------------------------------------------
# the AWS CLI
# --------------------------------------------------------------------------

AWS_FALLBACKS = (
    # A systemd unit's PATH has no /snap/bin, and both boxes install the CLI
    # as a snap.
    '/snap/bin/aws',
    '/usr/local/bin/aws',
    '/usr/bin/aws',
    r'C:\Program Files\Amazon\AWSCLIV2\aws.exe',
)


def find_aws(explicit: str | None = None) -> str:
    if explicit:
        return explicit
    found = shutil.which('aws')
    if found:
        return found
    if os.environ.get('BR_ASSETS_NO_AWS_FALLBACK'):
        raise AssetsError('the AWS CLI is not on PATH')
    for c in AWS_FALLBACKS:
        if os.path.isfile(c) and os.access(c, os.X_OK):
            return c
    raise AssetsError('the AWS CLI was not found on PATH or at /snap/bin/aws; install it or name it with --aws PATH')


def last_line(text: str) -> str:
    lines = [ln.strip() for ln in text.splitlines() if ln.strip()]
    return lines[-1] if lines else '(no message)'


class Aws:
    """The three calls this tool makes, through the CLI."""

    def __init__(self, exe: str, profile: str | None, region: str, bucket: str):
        # A .py stand-in (tools/test_assets.py's fake) is run by this
        # interpreter; the real CLI never is one.
        self.cmd = [sys.executable, exe] if exe.lower().endswith('.py') else [exe]
        self.tail = ['--region', region] + (['--profile', profile] if profile else [])
        self.bucket = bucket
        self.profile = profile

    def _run(self, args: list[str], show_progress: bool = False) -> subprocess.CompletedProcess:
        env = dict(os.environ)
        env['AWS_PAGER'] = ''
        try:
            # With progress, the CLI's own progress line goes straight to the
            # console; only its errors are kept to report.
            return subprocess.run(self.cmd + args + self.tail, stdout=None if show_progress else subprocess.PIPE,
                                  stderr=subprocess.PIPE, env=env)
        except OSError as e:
            raise AssetsError('cannot run the AWS CLI (%s): %s' % (self.cmd[-1], e))

    def url(self, key: str) -> str:
        return 's3://%s/%s' % (self.bucket, key)

    def head(self, key: str) -> int | None:
        """The object's size, or None when there is no such object."""
        r = self._run(['s3api', 'head-object', '--bucket', self.bucket, '--key', key, '--output', 'json'])
        err = r.stderr.decode('utf-8', 'replace')
        if r.returncode == 0:
            try:
                return int(json.loads(r.stdout.decode('utf-8', 'replace'))['ContentLength'])
            except (ValueError, KeyError, TypeError):
                raise AssetsError('unexpected answer from aws s3api head-object for %s' % self.url(key))
        if '(404)' in err or 'Not Found' in err:
            return None
        if '(403)' in err or 'Forbidden' in err:
            raise AssetsError('access denied reading %s -- check the %s'
                              % (self.url(key), 'profile %r' % self.profile if self.profile else "box's instance role"))
        raise AssetsError('aws s3api head-object %s failed: %s' % (self.url(key), last_line(err)))

    def download(self, key: str, dest: str) -> None:
        r = self._run(['s3', 'cp', self.url(key), dest, '--no-progress', '--only-show-errors'])
        if r.returncode != 0:
            raise AssetsError('downloading %s failed: %s' % (self.url(key), last_line(r.stderr.decode('utf-8', 'replace'))))

    def upload(self, src: str, key: str, progress: bool = False) -> None:
        quiet = [] if progress else ['--no-progress', '--only-show-errors']
        r = self._run(['s3', 'cp', src, self.url(key)] + quiet, show_progress=progress)
        if r.returncode != 0:
            raise AssetsError('uploading %s failed: %s' % (self.url(key), last_line(r.stderr.decode('utf-8', 'replace'))))


def make_aws(args, default_profile: str | None = None) -> Aws:
    profile = default_profile if args.profile is None else args.profile
    if profile is not None and profile.lower() == 'none':
        profile = None
    return Aws(find_aws(args.aws), profile, args.region, args.bucket)


def upload_missing(aws: Aws, items: list[dict], progress: bool = False) -> tuple[int, int]:
    """Upload each {name, sha, size, archive(), label} the bucket lacks, never
    overwriting. `archive` is called only for one that has to go up. Returns
    (uploaded, already there)."""
    up = there = 0
    todo = []
    for it in items:
        key = object_key(it['name'], it['sha'])
        have = aws.head(key)
        if have is None:
            todo.append(it)
        elif have == it['size']:
            there += 1
            say('already in the bucket, not uploaded again: %s %s' % (it['label'], short(it['sha'])))
        else:
            raise AssetsError('%s already exists with %d bytes, not %d. Objects are never overwritten; '
                              'nothing was changed.' % (aws.url(key), have, it['size']))
    for i, it in enumerate(todo, 1):
        key = object_key(it['name'], it['sha'])
        say('uploading %d/%d: %s %s, %s' % (i, len(todo), it['label'], short(it['sha']), human(it['size'])))
        aws.upload(it['archive'](), key, progress=progress)
        got = aws.head(key)
        if got != it['size']:
            raise AssetsError('the upload did not land whole: %s holds %s bytes, the archive is %d'
                              % (aws.url(key), got, it['size']))
        up += 1
    return up, there


# --------------------------------------------------------------------------
# finding resources: push's folders and publish's season folders
# --------------------------------------------------------------------------

def is_category(name: str) -> bool:
    return len(name) > 2 and name.startswith('[') and name.endswith(']')


def is_empty_folder(path: str) -> bool:
    """No file at all, however deep, but File Explorer's own (desktop.ini,
    Thumbs.db, .DS_Store). A link, or anything that cannot be read, is not
    empty: an empty folder means something, so it has to be certain."""
    unreadable: list = []
    for dirpath, dirnames, filenames in os.walk(path, followlinks=False, onerror=unreadable.append):
        if any(is_link(os.path.join(dirpath, d)) for d in dirnames):
            return False
        if any(f.lower() not in JUNK_FILES for f in filenames):
            return False
    return not unreadable


def find_resources(folder: str, label: str, notes: list[str],
                   empties: list | None = None) -> list[tuple[str, str, str]]:
    """(name, path, label) for each resource in `folder`: a subfolder holding
    fxmanifest.lua is one, named after the folder; a FiveM [category] folder is
    walked into; anything else is noted in `notes` and skipped -- except, when
    `empties` is given, an EMPTY folder, which goes there as (name, path,
    label). A folder with files but no fxmanifest.lua is always skipped: it is
    most likely a copy still in progress, and never means anything."""
    out: list[tuple[str, str, str]] = []
    try:
        entries = sorted(os.listdir(folder), key=lambda s: (s.lower(), s))
    except OSError as e:
        notes.append('%s: cannot be read (%s)' % (label, e.strerror or e))
        return out
    for entry in entries:
        full = os.path.join(folder, entry)
        lab = '%s/%s' % (label, entry) if label else entry
        if entry.lower() in JUNK_FILES or entry.lower() in JUNK_DIRS:
            continue
        if is_link(full):
            notes.append('skipped %s: a link' % lab)
        elif os.path.isdir(full):
            if os.path.isfile(os.path.join(full, 'fxmanifest.lua')):
                out.append((entry, full, lab))
            elif is_category(entry):
                out.extend(find_resources(full, lab, notes, empties))
            elif empties is not None and is_empty_folder(full):
                empties.append((entry, full, lab))
            else:
                notes.append('skipped %s: no fxmanifest.lua, and not a [category] folder' % lab)
        else:
            notes.append('skipped %s: not a folder' % lab)
    return out


def name_problems(items: list[tuple[str, str, str]], where: str) -> list[str]:
    p = []
    seen: dict[str, str] = {}
    for name, _full, lab in items:
        low = name.lower()
        if not NAME_RE.match(name):
            p.append('%s: %r is not a resource name (letters, digits, _ and -); rename the folder' % (lab, name))
        if low == RECORD_RESOURCE:
            p.append('%s: %s is reserved for the install record; rename the folder' % (lab, name))
        if low in seen:
            p.append('%s and %s are one resource twice%s' % (seen[low], lab, where))
        seen[low] = lab
    return p


# --------------------------------------------------------------------------
# push
# --------------------------------------------------------------------------

def next_pin(entry: dict, season: int) -> tuple[int, str | None] | None:
    later = sorted((int(k), v) for k, v in entry['seasons'].items() if int(k) > season)
    return later[0] if later else None


def settle(lock: dict, entry: dict, changes: list[str]) -> None:
    """An entry's pins in their one form, its versions the pinned ones, and
    the entry gone when it pins no version at all."""
    entry['seasons'] = canonical_pins(entry['seasons'])
    live = {v for v in entry['seasons'].values() if v is not None}
    for s in list(entry['versions']):
        if s not in live:
            del entry['versions'][s]
            changes.append('%s: %s is pinned to no season now; dropped from the lock '
                           '(its archive stays in the bucket)' % (entry['name'], short(s)))
    if not live:
        lock['resources'].remove(entry)
        changes.append('%s: in force in no season now; dropped from the lock' % entry['name'])


def apply_push(lock: dict, name: str, sha: str, size: int, files: dict[str, int], season: int) -> list[str]:
    """Pin `sha` at `season` for `name`, in place. What changed, in words."""
    changes: list[str] = []
    entry = next((e for e in lock['resources'] if e['name'] == name), None)
    if entry is None:
        entry = {'name': name, 'seasons': {}, 'versions': {}}
        lock['resources'].append(entry)
        changes.append('%s: new resource' % name)
    was = version_for(entry, season)
    entry['seasons'][str(season)] = sha
    entry['versions'][sha] = {'size': size, 'files': dict(files)}
    if was != sha:
        nxt = next_pin(entry, season)
        changes.append('%s: from Season %d, %s (was %s)%s'
                       % (name, season, short(sha), 'not installed' if was is None else short(was),
                          (' until Season %d, which pins %s' % (nxt[0], pin_text(nxt[1]))) if nxt else ''))
    settle(lock, entry, changes)
    return changes


def apply_retire(lock: dict, name: str, season: int | None) -> list[str]:
    """`name` removed from `season` on (a null pin), or from every season, in
    place. What changed, in words; [] when nothing would."""
    entry = next((e for e in lock['resources'] if e['name'] == name), None)
    if entry is None:
        raise AssetsError('%s is not in the lock' % name)
    changes: list[str] = []
    if season is None:
        lock['resources'].remove(entry)
        return ['%s: retired from every season; dropped from the lock (its archives stay in the bucket)' % name]
    if version_for(entry, season) is None:
        return []
    entry['seasons'][str(season)] = None
    nxt = next_pin(entry, season)
    changes.append('%s: removed from Season %d on%s'
                   % (name, season, (' until Season %d, which pins %s' % (nxt[0], pin_text(nxt[1]))) if nxt else ''))
    settle(lock, entry, changes)
    return changes


def push_targets(folders: list[str], name: str | None) -> list[tuple[str, str]]:
    """(name, folder) for each resource the push names: a folder holding
    fxmanifest.lua is one resource; any other folder (a parent, or a FiveM
    [category]) pushes each resource inside it."""
    out: list[tuple[str, str]] = []
    notes: list[str] = []
    for f in folders:
        folder = os.path.abspath(f)
        if not os.path.isdir(folder):
            raise AssetsError('not a folder: %s' % folder)
        if os.path.isfile(os.path.join(folder, 'fxmanifest.lua')):
            out.append((os.path.basename(folder.rstrip('/\\')), folder))
            continue
        found = find_resources(folder, os.path.basename(folder.rstrip('/\\')), notes)
        if not found:
            raise AssetsError('%s has no fxmanifest.lua and no resource folders inside it' % folder)
        out.extend((n, full) for n, full, _ in found)
    for n in notes:
        say(n)
    if name is not None:
        if len(out) != 1:
            raise AssetsError('--name names one resource, and this push has %d' % len(out))
        out = [(name, out[0][1])]
    problems = name_problems([(n, full, full) for n, full in out], ' in this push')
    if problems:
        raise AssetsError('nothing was uploaded or written:\n%s' % '\n'.join('  ' + x for x in problems))
    return out


def cmd_push(args) -> int:
    targets = push_targets(args.folders, args.name)
    lock_path = args.lock
    names = repo_resource_names()
    for name, _ in targets:
        if name.lower() in names:
            raise AssetsError('a resource in this repository already has the name %s; rename the folder '
                              'or pass --name' % name)
    lock = load_lock(lock_path, names)
    updated = json.loads(json.dumps(lock))

    with tempfile.TemporaryDirectory(prefix='assets-push-') as tmp:
        items = []
        changes: list[str] = []
        for i, (name, folder) in enumerate(targets):
            entry = next((e for e in updated['resources'] if e['name'] == name), None)
            versions_at = sorted((k for k, v in entry['seasons'].items() if v is not None), key=int) if entry else []
            if args.season is not None:
                season = args.season
            elif entry is None:
                season = 1
            elif len(versions_at) == 1:
                season = int(versions_at[0])
            else:
                raise AssetsError('%s pins versions at Seasons %s; say which one this is with --season N'
                                  % (name, ', '.join(versions_at)))
            archive = os.path.join(tmp, '%d.tar.gz' % i)
            files, skipped = pack(folder, archive)
            sha, size = sha256_file(archive)
            say('packed %s: %d files, %s -> %s archive' % (name, len(files), human(sum(files.values())), human(size)))
            say('  sha256 %s' % sha)
            for s in skipped:
                say('  left out: %s' % s)
            changes += apply_push(updated, name, sha, size, files, season)
            items.append({'name': name, 'sha': sha, 'size': size, 'label': name,
                          'archive': (lambda a=archive: a)})

        # THE LOCK THIS PUSH WOULD WRITE, CHECKED BEFORE ANYTHING IS UPLOADED,
        # so a refusal leaves the bucket as well as the lock as they were.
        problems = validate(updated, names)
        if problems:
            raise AssetsError('the lock would not pass check after this push; nothing was uploaded or written:\n%s'
                              % '\n'.join('  ' + x for x in problems))
        unique: dict[tuple[str, str], dict] = {}
        for it in items:
            unique.setdefault((it['name'], it['sha']), it)
        upload_missing(make_aws(args, PUSH_PROFILE), list(unique.values()))

    text = dump_lock(updated)
    before = read_bytes(lock_path)
    if before is not None and before.replace(b'\r\n', b'\n') == text.encode('utf-8'):
        say('%s unchanged: %s already pinned there' % (os.path.basename(lock_path),
                                                       ', '.join(n for n, _ in targets)))
        return 0
    atomic_write(lock_path, text)
    for c in changes:
        say('  ' + c)
    say('%s updated. Nothing was committed: review it, then commit it.' % os.path.basename(lock_path))
    return 0


def cmd_retire(args) -> int:
    """A null pin from the command line: what an empty folder in a later
    Season folder is to publish. Without --season, out of every season."""
    names = repo_resource_names()
    lock = load_lock(args.lock, names)
    updated = json.loads(json.dumps(lock))
    changes = apply_retire(updated, args.name, args.season)
    if not changes:
        say('%s is in force at no season from Season %d on; nothing to remove' % (args.name, args.season))
        return 0
    problems = validate(updated, names)
    if problems:
        raise AssetsError('the lock would not pass check; nothing was written:\n%s'
                          % '\n'.join('  ' + x for x in problems))
    atomic_write(args.lock, dump_lock(updated))
    for c in changes:
        say('  ' + c)
    say('%s updated. Nothing was committed: review it, then commit it.' % os.path.basename(args.lock))
    return 0


# --------------------------------------------------------------------------
# pull
# --------------------------------------------------------------------------
#
# TWO HALVES, SO deploy.sh CAN PUT THE CODE SYNC BETWEEN THEM:
#
#   pull --stage   download, check every sha256, unpack into <cache>/.staged.
#                  Changes nothing installed. deploy.sh runs it before the
#                  code sync, where a failure stops the deploy with nothing
#                  changed anywhere.
#   pull --swap    swap the staged set into resources/[licensed]/, then write
#                  licensed.cfg and the install record. deploy.sh runs it after
#                  the code and vendored syncs have succeeded, just before the
#                  served-commit stamp, so new assets never sit under old code.
#   pull           both, one after the other.
#
# A SWAP IS JOURNALED. Before its first rename, every rename it will make and
# the old bytes of every file it rewrites go into journal.json in its trash
# dir. A failure is undone in process from the journal; a run that was killed
# is undone by the next pull, from the journal, before anything else. When an
# undo itself fails, nothing is deleted: the trash dir stays, the record and
# licensed.cfg are rewritten to say what is really in [licensed], and the
# error names where every old resource is.

def box_paths(args) -> types.SimpleNamespace:
    p = types.SimpleNamespace()
    p.server_root = os.path.abspath(args.server_root)
    p.resources = os.path.join(p.server_root, 'resources')
    if not os.path.isdir(p.resources):
        raise AssetsError('no resources/ under %s -- wrong --server-root?' % p.server_root)
    p.licensed = os.path.join(p.resources, LICENSED_GROUP)
    p.cache = os.path.abspath(args.cache) if args.cache else os.path.join(p.server_root, CACHE_DIR)
    p.staged = os.path.join(p.cache, STAGED_DIR)
    return p


def read_record(licensed: str) -> dict[str, str] | None:
    raw = read_bytes(os.path.join(licensed, RECORD_RESOURCE, RECORD_FILE))
    if raw is None:
        return None
    rec: dict[str, str] = {}
    for line in raw.decode('utf-8', 'replace').splitlines():
        t = line.split()
        if len(t) == 3 and t[0] == 'installed':
            rec[t[1]] = t[2]
    return rec


def season_plans(lock: dict, season: int, latest: int) -> list[list]:
    """[season, [[name, sha], ...]] for every season brseason could switch to."""
    seasons = list(range(1, latest + 1))
    if season not in seasons:
        seasons.append(season)
    return [[s, [[name, sha] for name, sha, _ in plan_for(lock, s)]] for s in seasons]


def record_text(season: int, plans: list, installed: list) -> str:
    """The install record br_core reads for brseason: what is installed, and
    what every season it could switch to would install instead."""
    lines = [
        '# GENERATED by tools/assets.py pull (#391). Do not edit: the next pull rewrites it.',
        '# br_core reads it so brseason can say when a switch needs other licensed assets.',
        'format 1',
        'season %d' % season,
        'seasons %s' % ' '.join(str(s) for s, _ in plans),
    ]
    for name, sha in installed:
        lines.append('installed %s %s' % (name, sha))
    for s, pins in plans:
        for name, sha in pins:
            lines.append('plan %d %s %s' % (s, name, sha))
    return '\n'.join(lines) + '\n'


def cfg_text(season: int, names: list[str]) -> str:
    lines = [
        '# GENERATED by tools/assets.py pull (#391) for Season %d. Do not edit: the next pull rewrites it.' % season,
        '# server.cfg runs it with:  exec resources/%s/%s' % (LICENSED_GROUP, CFG_FILE),
    ]
    if not names:
        lines.append('# Nothing licensed is installed for Season %d.' % season)
    for name in names:
        lines.append('ensure %s' % name)
    return '\n'.join(lines) + '\n'


def state_writes(licensed: str, season: int, plans: list, installed: list) -> list[tuple[str, str]]:
    """The three files that describe [licensed]: the record's manifest, the
    record, and licensed.cfg -- for `installed`, [[name, sha], ...]."""
    rec_dir = os.path.join(licensed, RECORD_RESOURCE)
    return [
        (os.path.join(rec_dir, 'fxmanifest.lua'), RECORD_MANIFEST),
        (os.path.join(rec_dir, RECORD_FILE), record_text(season, plans, installed)),
        (os.path.join(licensed, CFG_FILE), cfg_text(season, [n for n, _ in installed])),
    ]


def installed_dirs(licensed: str) -> list[str]:
    """The resource directories inside [licensed], and only there. The record
    resource is the tool's own and is never one of them."""
    if not os.path.isdir(licensed):
        return []
    out = []
    for entry in sorted(os.listdir(licensed)):
        full = os.path.join(licensed, entry)
        if entry == RECORD_RESOURCE or is_link(full) or not os.path.isdir(full):
            continue
        out.append(entry)
    return out


def resources_elsewhere(resources: str, names) -> list[tuple[str, str]]:
    """(name, path) for each of `names` that a resource OUTSIDE [licensed]
    already has. FiveM would then see two resources with one name and load
    whichever it found first."""
    want = {n.lower() for n in names}
    hits: list[tuple[str, str]] = []
    if not want:
        return hits
    for dirpath, dirnames, filenames in os.walk(resources):
        if os.path.normcase(dirpath) == os.path.normcase(resources):
            dirnames[:] = [d for d in dirnames if d != LICENSED_GROUP]
        dirnames[:] = sorted(d for d in dirnames if d != 'node_modules' and not d.startswith('.'))
        if 'fxmanifest.lua' in filenames or '__resource.lua' in filenames:
            base = os.path.basename(dirpath)
            if base.lower() in want:
                hits.append((base, dirpath))
            dirnames[:] = []
    return hits


def survey(args, p) -> types.SimpleNamespace:
    """Everything a pull decides, read-only: the plan for this box's season,
    against what is installed."""
    s = types.SimpleNamespace(**vars(p))
    s.lock = load_lock(args.lock)
    s.latest = read_latest()
    s.season, s.how = resolve_season(args, s.server_root, s.latest)
    s.plan = plan_for(s.lock, s.season)
    s.record = read_record(s.licensed) or {}
    s.present = installed_dirs(s.licensed)
    wanted = {name for name, _, _ in s.plan}
    s.lines = ['Season %d (%s): %d licensed resource(s) in force' % (s.season, s.how, len(s.plan))]
    s.installs = []
    for name, sha, ver in s.plan:
        target = os.path.join(s.licensed, name)
        if s.record.get(name) == sha and os.path.isdir(target) and dir_files(target) == ver['files']:
            s.lines.append('  = %s %s' % (name, short(sha)))
            continue
        cached = os.path.isfile(os.path.join(s.cache, name, sha + '.tar.gz'))
        was = s.record.get(name)
        verb = '~' if name in s.present else '+'
        detail = (' (was %s)' % short(was)) if (was and was != sha) else (' (reinstall)' if was == sha else '')
        s.lines.append('  %s %s %s%s, %s' % (verb, name, short(sha), detail,
                                             'cached' if cached else 'to download, %s' % human(ver['size'])))
        s.installs.append((name, sha, ver))
    s.removals = [d for d in s.present if d not in wanted]
    for d in s.removals:
        s.lines.append('  - %s (not in force for Season %d)' % (d, s.season))
    s.plans = season_plans(s.lock, s.season, s.latest)
    s.writes = state_writes(s.licensed, s.season, s.plans, [[n, sha] for n, sha, _ in s.plan])
    s.conflicts = resources_elsewhere(s.resources, [n for n, _, _ in s.plan])
    if not s.plan and not os.path.isdir(s.licensed):
        s.todo = False
    else:
        s.todo = bool(s.installs or s.removals
                      or not all(read_bytes(path) == text.encode('utf-8') for path, text in s.writes))
    return s


def conflict_error(s) -> AssetsError:
    lines = ['a resource with the same name as a licensed one is already on this box, outside %s:' % LICENSED_GROUP]
    for name, path in s.conflicts:
        lines.append('  %s: %s' % (name, path))
    lines.append('FiveM would see two resources with one name. Remove that copy (or rename the pack), '
                 'then run the pull again. Nothing was changed.')
    return AssetsError('\n'.join(lines))


def fetch_verified(get_aws, cache: str, name: str, sha: str, size: int) -> tuple[str, str]:
    """THE ONLY DOOR TO AN ARCHIVE. Its path in the cache once its bytes are
    known to hash to `sha`, downloading it first if it is missing or does not.
    Raises, leaving nothing behind, when the bucket's copy does not match."""
    final = os.path.join(cache, name, sha + '.tar.gz')
    if os.path.isfile(final):
        got, n = sha256_file(final)
        if got == sha and n == size:
            return final, 'cached'
        say('  %s: the cached archive does not match its sha256; downloading it again' % name)
        os.remove(final)
    os.makedirs(os.path.dirname(final), exist_ok=True)
    part = '%s.part-%d' % (final, os.getpid())
    try:
        get_aws().download(object_key(name, sha), part)
        got, n = sha256_file(part)
        if got != sha or n != size:
            raise AssetsError('%s: the archive in the bucket does not match assets.lock\n'
                              '  want sha256 %s (%d bytes)\n'
                              '  got  sha256 %s (%d bytes)\n'
                              '  Nothing was unpacked and nothing installed was changed.'
                              % (name, sha, size, got, n))
        os.replace(part, final)
    finally:
        if os.path.exists(part):
            os.remove(part)
    return final, 'downloaded %s' % human(size)


@contextlib.contextmanager
def held(cache: str):
    """One pull at a time per cache."""
    os.makedirs(cache, exist_ok=True)
    fh = open(os.path.join(cache, '.lock'), 'a+')
    try:
        try:
            import fcntl
        except ImportError:
            fcntl = None
        if fcntl is not None:
            try:
                fcntl.flock(fh, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError:
                raise AssetsError('another pull is running (it holds %s)' % os.path.join(cache, '.lock'))
        yield
    finally:
        fh.close()


# -- the journaled swap -------------------------------------------------------

def commit(s, trash: str) -> None:
    """Swap the staged resources in and the stale ones out, then write the
    record and licensed.cfg. Journaled first; any failure is undone from the
    journal, so the installed set is either all old or all new -- or, when
    the undo fails too, a DoubleFault that keeps the trash and says why."""
    moves = []
    for name in s.removals:
        moves.append({'kind': 'out', 'name': name, 'src': os.path.join(s.licensed, name),
                      'dst': os.path.join(trash, name)})
    for name, _sha, _ver in s.installs:
        target = os.path.join(s.licensed, name)
        if os.path.lexists(target):
            moves.append({'kind': 'out', 'name': name, 'src': target, 'dst': os.path.join(trash, name)})
        moves.append({'kind': 'in', 'name': name, 'src': os.path.join(s.staged, name), 'dst': target})
    rec_dir = os.path.join(s.licensed, RECORD_RESOURCE)
    files = {}
    for path, _text in s.writes:
        old = read_bytes(path)
        files[path] = None if old is None else base64.b64encode(old).decode('ascii')
    journal = {
        'format': 1,
        'licensed': s.licensed,
        'staged': s.staged,
        'trash': trash,
        'moves': moves,
        'created': [] if os.path.isdir(rec_dir) else [rec_dir],
        'files': files,
        'before': {name: s.record.get(name, UNKNOWN_VERSION) for name in s.present},
        'installs': {name: sha for name, sha, _ in s.installs},
        'order': [name for name, _, _ in s.plan],
        'season': s.season,
        'plans': s.plans,
    }
    atomic_write(os.path.join(trash, JOURNAL_FILE), json.dumps(journal, indent=1))
    try:
        for m in moves:
            os.rename(m['src'], m['dst'])
        for d in (s.licensed, trash, s.staged):
            fsync_dir(d)
        if journal['created']:
            os.makedirs(rec_dir)
        for path, text in s.writes:
            atomic_write(path, text)
    except BaseException as exc:
        failures, actual = rollback(journal)
        if failures:
            raise DoubleFault(double_fault_text(journal, failures, actual, exc)) from exc
        raise


def rollback(j: dict) -> tuple[list[str], list]:
    """Undo a swap from its journal: the files it rewrote, the record dir it
    made, then its renames, last first. Each rename's state is read off the
    disk, so this undoes a swap that failed in this process and one that was
    killed alike. Returns (what could not be undone, [[name, sha], ...] in
    [licensed] when something could not be -- and then the record and
    licensed.cfg have been rewritten to say exactly that)."""
    failures: list[str] = []
    for path, old in j['files'].items():
        try:
            if old is None:
                if os.path.lexists(path):
                    os.remove(path)
            else:
                write_bytes_atomic(path, base64.b64decode(old))
        except OSError as e:
            failures.append('%s could not be put back: %s' % (path, e.strerror or e))
    for d in j['created']:
        with contextlib.suppress(OSError):
            if os.path.isdir(d) and not os.listdir(d):
                os.rmdir(d)
    for m in reversed(j['moves']):
        src, dst = m['src'], m['dst']
        if m['kind'] == 'in':
            # Staged -> [licensed]. Happened when the staged copy is gone and
            # [licensed] has one.
            if not (os.path.lexists(dst) and not os.path.lexists(src)):
                continue
        else:
            # [licensed] -> trash. Happened when the trash has it.
            if not os.path.lexists(dst):
                continue
            if os.path.lexists(src):
                failures.append('%s cannot go back to %s: something else is there' % (dst, src))
                continue
        try:
            os.rename(dst, src)
        except OSError as e:
            failures.append('%s -> %s: %s' % (dst, src, e.strerror or e))
    for d in (j['licensed'], j['trash'], j['staged']):
        with contextlib.suppress(OSError):
            fsync_dir(d)
    if not failures:
        return failures, []
    actual = actual_state(j)
    try:
        rec_dir = os.path.join(j['licensed'], RECORD_RESOURCE)
        os.makedirs(rec_dir, exist_ok=True)
        for path, text in state_writes(j['licensed'], j['season'], j['plans'], actual):
            atomic_write(path, text)
    except OSError as e:
        failures.append('the record and licensed.cfg could not be rewritten to match: %s' % (e.strerror or e))
    return failures, actual


def actual_state(j: dict) -> list:
    """[[name, sha], ...] for what is really in [licensed] now, in lock order."""
    names = list(j['order'])
    for n in sorted(set(j['before']) | set(j['installs'])):
        if n not in names:
            names.append(n)
    out = []
    for name in names:
        if not os.path.isdir(os.path.join(j['licensed'], name)):
            continue
        new_in = any(m['kind'] == 'in' and m['name'] == name and not os.path.lexists(m['src']) for m in j['moves'])
        out.append([name, j['installs'][name] if new_in else j['before'].get(name, UNKNOWN_VERSION)])
    return out


def double_fault_text(j: dict, failures: list[str], actual: list, exc) -> str:
    lines = ['the swap into %s failed (%s), and undoing it failed too. NOTHING WAS DELETED.'
             % (j['licensed'], exc if isinstance(exc, str) else (str(exc) or type(exc).__name__))]
    stranded = [m for m in j['moves'] if m['kind'] == 'out' and os.path.lexists(m['dst'])]
    if stranded:
        lines.append('The resources that were installed before are still in the trash dir %s:' % j['trash'])
        for m in stranded:
            lines.append('  %s  belongs at  %s' % (m['dst'], m['src']))
    lines.append('%s now holds: %s' % (j['licensed'], ', '.join(
        '%s %s' % (n, 'at an unknown version' if sha == UNKNOWN_VERSION else short(sha)) for n, sha in actual)
        or 'no licensed resource'))
    lines.append('installed.txt and licensed.cfg say exactly that.')
    lines.append('What could not be undone:')
    lines += ['  ' + f for f in failures]
    lines.append('Fix what stopped it and run the pull again (it retries the undo first), '
                 'or move each one above back by hand.')
    return '\n'.join(lines)


def journal_is_ours(j, p) -> bool:
    try:
        roots = (p.licensed, p.cache)
        if os.path.normcase(os.path.abspath(j['licensed'])) != os.path.normcase(os.path.abspath(p.licensed)):
            return False
        for m in j['moves']:
            if m['kind'] not in ('in', 'out') or not all(any(inside(m[k], r) for r in roots) for k in ('src', 'dst')):
                return False
        return all(inside(path, p.licensed) for path in list(j['files']) + list(j['created']))
    except (KeyError, TypeError, AttributeError):
        return False


def recover_trash(trash: str, p) -> None:
    """A trash dir a pull left behind: undo the swap it journaled, or put back
    what it holds, and only then delete it. Stops, deleting nothing, when that
    cannot be done."""
    j = read_json(os.path.join(trash, JOURNAL_FILE))
    held_items = [e for e in os.listdir(trash) if not e.startswith(JOURNAL_FILE)]
    if j is None:
        clash = [e for e in held_items if os.path.lexists(os.path.join(p.licensed, e))]
        if clash:
            raise AssetsError('%s, left by a pull that did not finish, holds %s, and %s has its own copy. '
                              'Nothing was deleted: keep one of each, delete the other, and run the pull again.'
                              % (trash, ', '.join(clash), p.licensed))
        if held_items:
            os.makedirs(p.licensed, exist_ok=True)
        for e in held_items:
            try:
                os.rename(os.path.join(trash, e), os.path.join(p.licensed, e))
            except OSError as err:
                raise AssetsError('%s holds %s, left by a pull that did not finish, and it could not be put back '
                                  'in %s (%s). Nothing was deleted.' % (trash, e, p.licensed, err.strerror or err))
        if held_items:
            say('put back %s from %s, left by a pull that did not finish' % (', '.join(held_items), trash))
    else:
        if not journal_is_ours(j, p):
            raise AssetsError('%s holds a journal naming paths outside %s and %s; nothing was touched or deleted.'
                              % (trash, p.licensed, p.cache))
        failures, actual = rollback(j)
        if failures:
            raise DoubleFault(double_fault_text(j, failures, actual, 'a pull that did not finish'))
        say('undid a swap that did not finish: %s is as it was before it' % p.licensed)
    rest = [e for e in os.listdir(trash) if not e.startswith(JOURNAL_FILE)]
    if rest:
        raise AssetsError('%s still holds %s; nothing was deleted.' % (trash, ', '.join(rest)))
    shutil.rmtree(trash)


def leftovers(cache: str) -> list[str]:
    if not os.path.isdir(cache):
        return []
    return sorted(e for e in os.listdir(cache)
                  if (e.startswith('.staging-') or e.startswith('.trash-')) and os.path.isdir(os.path.join(cache, e)))


def recover(p) -> None:
    """What a killed pull left in the cache: half-unpacked staging dirs and
    half-downloaded archives go, a trash dir is undone first (recover_trash)."""
    for e in leftovers(p.cache):
        full = os.path.join(p.cache, e)
        if e.startswith('.staging-'):
            shutil.rmtree(full)
            say('removed %s, left by a pull that did not finish' % full)
        else:
            recover_trash(full, p)
    for e in os.listdir(p.cache):
        d = os.path.join(p.cache, e)
        if e.startswith('.') or not os.path.isdir(d):
            continue
        for f in os.listdir(d):
            if '.tar.gz.part-' in f:
                with contextlib.suppress(OSError):
                    os.remove(os.path.join(d, f))


def discard_trash(trash: str) -> None:
    """After an undo that finished: the trash holds only the journal."""
    rest = [e for e in os.listdir(trash) if not e.startswith(JOURNAL_FILE)]
    if rest:
        say('warning: kept %s, which still holds %s' % (trash, ', '.join(rest)))
        return
    shutil.rmtree(trash, ignore_errors=True)


# -- the cache's housekeeping -------------------------------------------------

def mark_used(s) -> None:
    """Record that every archive in force here was in use now."""
    path = os.path.join(s.cache, LAST_USED_FILE)
    used = read_json(path)
    if not isinstance(used, dict):
        used = {}
    now = int(time.time())
    for name, sha, _ in s.plan:
        used['%s/%s' % (name, sha)] = now
    atomic_write(path, json.dumps(used, indent=1, sort_keys=True) + '\n')


def prune_cache(s) -> list[str]:
    """Drop cached archives the lock no longer names at all and that have not
    been in force here for PRUNE_AFTER. An archive the lock names, for any
    season, is never dropped: it is what a revert or a season change needs."""
    if not os.path.isdir(s.cache):
        return []
    referenced = {'%s/%s' % (e['name'], sha) for e in s.lock['resources'] for sha in e['versions']}
    path = os.path.join(s.cache, LAST_USED_FILE)
    used = read_json(path)
    if not isinstance(used, dict):
        used = {}
    now = time.time()
    dropped: list[str] = []
    on_disk: set[str] = set()
    for name in sorted(os.listdir(s.cache)):
        d = os.path.join(s.cache, name)
        if name.startswith('.') or not os.path.isdir(d) or is_link(d):
            continue
        for f in sorted(os.listdir(d)):
            if not f.endswith('.tar.gz'):
                continue
            key = '%s/%s' % (name, f[:-len('.tar.gz')])
            on_disk.add(key)
            if key in referenced:
                continue
            full = os.path.join(d, f)
            last = used.get(key)
            if not isinstance(last, (int, float)):
                last = os.path.getmtime(full)
            if now - last > PRUNE_AFTER:
                try:
                    os.remove(full)
                    dropped.append(key)
                    on_disk.discard(key)
                except OSError as e:
                    say('warning: could not prune %s: %s' % (full, e.strerror or e))
        with contextlib.suppress(OSError):
            if not os.listdir(d):
                os.rmdir(d)
    kept = {k: v for k, v in used.items() if k in on_disk}
    if kept != used:
        atomic_write(path, json.dumps(kept, indent=1, sort_keys=True) + '\n')
    for k in dropped:
        say('pruned %s from the cache: the lock no longer names it, and it was last in force over %d days ago'
            % (k, PRUNE_AFTER // 86400))
    return dropped


# -- the two halves -----------------------------------------------------------

def stage(s, args) -> None:
    aws_box: list[Aws] = []

    def get_aws() -> Aws:
        if not aws_box:
            aws_box.append(make_aws(args))
        return aws_box[0]

    # 1. EVERY ARCHIVE, VERIFIED, BEFORE ANYTHING IS UNPACKED.
    archives: dict[str, str] = {}
    for name, sha, ver in s.installs:
        path, how_got = fetch_verified(get_aws, s.cache, name, sha, ver['size'])
        archives[name] = path
        say('  %s %s: sha256 verified (%s)' % (name, short(sha), how_got))
    home = s.licensed if os.path.isdir(s.licensed) else s.resources
    if os.stat(s.cache).st_dev != os.stat(home).st_dev:
        raise AssetsError('%s and %s are on different filesystems, so the swap cannot be atomic; '
                          'pass --cache with a directory beside resources/' % (s.cache, home))
    # 2. UNPACKED BESIDE THE CACHE, never inside resources/, and on disk for
    # real before it is called staged.
    tmp = tempfile.mkdtemp(prefix='.staging-', dir=s.cache)
    try:
        for name, sha, ver in s.installs:
            unpack(archives[name], os.path.join(tmp, name), ver['files'])
        atomic_write(os.path.join(tmp, STAGE_FILE), json.dumps(stage_description(s), indent=1))
        fsync_tree(tmp)
        if os.path.lexists(s.staged):
            shutil.rmtree(s.staged)
        os.rename(tmp, s.staged)
        fsync_dir(s.cache)
    except BaseException:
        shutil.rmtree(tmp, ignore_errors=True)
        raise
    mark_used(s)
    say('staged for Season %d: %s; nothing installed has changed yet'
        % (s.season, ', '.join(n for n, _, _ in s.installs) or 'removals only'))


def stage_description(s) -> dict:
    return {'format': 1, 'season': s.season,
            'installs': [[n, sha] for n, sha, _ in s.installs], 'removals': list(s.removals)}


def swap(s) -> None:
    staged = read_json(os.path.join(s.staged, STAGE_FILE))
    if staged is None:
        raise AssetsError('nothing is staged in %s. Run `pull --stage` first (deploy.sh does, before the '
                          'code sync); nothing was changed.' % s.staged)
    if staged != stage_description(s):
        raise AssetsError('what is staged in %s is not what assets.lock asks for now; run the pull again. '
                          'Nothing was changed.' % s.staged)
    for name, _sha, ver in s.installs:
        if dir_files(os.path.join(s.staged, name)) != ver['files']:
            raise AssetsError('the staged copy of %s is not whole; run the pull again. Nothing was changed.' % name)
    os.makedirs(s.licensed, exist_ok=True)
    trash = tempfile.mkdtemp(prefix='.trash-', dir=s.cache)
    try:
        commit(s, trash)
    except DoubleFault:
        raise
    except OSError as e:
        discard_trash(trash)
        raise AssetsError('the swap failed and was undone, so %s holds exactly what it held before: %s'
                          % (s.licensed, e))
    except BaseException:
        discard_trash(trash)
        raise
    # Done: what the trash holds is the versions just replaced, each still
    # cached as an archive while the lock names it.
    shutil.rmtree(trash, ignore_errors=True)
    shutil.rmtree(s.staged, ignore_errors=True)
    prune_cache(s)
    say('installed for Season %d: %s' % (s.season, ', '.join(n for n, _, _ in s.plan) or 'nothing'))
    say('licensed assets changed: they load on the next server restart')


def cmd_pull(args) -> int:
    p = box_paths(args)
    if args.dry_run:
        s = survey(args, p)
        for line in s.lines:
            say(line)
        for e in leftovers(p.cache):
            say('note: %s was left by a pull that did not finish; the next pull recovers it'
                % os.path.join(p.cache, e))
        if s.conflicts:
            raise conflict_error(s)
        say('dry run: nothing was downloaded or changed')
        return 0
    if not os.path.isdir(p.cache):
        # Nothing has ever been pulled here: nothing to recover, nothing staged.
        s = survey(args, p)
        if s.conflicts:
            for line in s.lines:
                say(line)
            raise conflict_error(s)
        if not s.todo:
            for line in s.lines:
                say(line)
            if not s.plan and not os.path.isdir(s.licensed):
                say('nothing licensed for Season %d and nothing installed; nothing to do' % s.season)
            else:
                say('up to date')
            return 0
    with held(p.cache):
        recover(p)
        s = survey(args, p)
        for line in s.lines:
            say(line)
        if s.conflicts:
            raise conflict_error(s)
        if not s.todo:
            if os.path.lexists(s.staged):
                shutil.rmtree(s.staged)
            if not args.swap:
                mark_used(s)
            if not args.stage:
                prune_cache(s)
            say('up to date')
            return 0
        if not args.swap:
            stage(s, args)
        if not args.stage:
            swap(s)
    return 0


# --------------------------------------------------------------------------
# the drop folder: publish and init-drop
# --------------------------------------------------------------------------
#
# The owner's way in, because File Explorer is: a folder on the Desktop with a
# `Season <n>` folder per season, packs dragged into the one they start in, an
# EMPTY folder with a pack's name in a later season to remove it from there on,
# a README saying so, and Publish.cmd. publish makes dev's assets.lock say
# exactly what the folders hold, uploads what the bucket lacks, and -- asked,
# never assumed -- commits that lock alone on top of dev and pushes it, from
# its own clone.

# The owner's README, as written for him (#391); init-drop puts it in the drop
# folder when it is missing, and never overwrites his copy.
README_TEXT = """\
BLITZ ASSETS

Licensed packs (map mods, emote packs) go here, never in the GitHub repo.
Drag them into a season folder, then double-click Publish.


ADDING A PACK

- Drag the pack's folder (the one with fxmanifest.lua in it) into the
  season it starts in. Category folders like [nteam] are fine.
- A pack carries into every later season on its own. Most packs go in
  Season 1 and stay there.
- Wait for a copy to finish before you click Publish.


CHANGING A PACK

- For every season: replace the files in the folder it's already in.
- From a later season on: put the new version in that season's folder,
  with the same name. Earlier seasons keep the old one.


REMOVING A PACK

- From a later season on: make an EMPTY folder with the pack's name in
  that season. An empty Season 3\\legion means legion is gone from
  Season 3 on.
- Everywhere: delete the pack's folder from every season folder.
- Removed packs stay in storage, so dragging one back publishes it again
  without another upload.


PUBLISHING

- Double-click Publish. It lists every change and asks before it
  commits anything.
- The dev server installs the change on its next deploy. Prod gets it
  with the next merge to main.
- A new season is a new folder: Season 3, Season 4, and so on.
"""


def enclosing_work_tree(path: str) -> str | None:
    """The git work tree `path` is inside (or is), or None."""
    cur = os.path.abspath(path)
    while True:
        if os.path.lexists(os.path.join(cur, '.git')):
            return cur
        parent = os.path.dirname(cur)
        if parent == cur:
            return None
        cur = parent


def drop_top_level_file(entry: str) -> bool:
    """Publish.cmd, the README, the index (and its temp files) and Explorer's
    own files: at the drop folder's top level, never a pack or a season."""
    low = entry.lower()
    return (low in (PUBLISH_CMD.lower(), DROP_README.lower()) or entry.startswith(DROP_INDEX)
            or low in JUNK_FILES)


def scan_drop(drop: str):
    """({season: [(name, path, label)]} of packs, the same of EMPTY folders,
    notes on what was skipped, problems)."""
    seasons: dict[int, list[tuple[str, str, str]]] = {}
    empties: dict[int, list[tuple[str, str, str]]] = {}
    notes: list[str] = []
    problems: list[str] = []
    folder_of: dict[int, str] = {}
    for entry in sorted(os.listdir(drop), key=lambda s: (s.lower(), s)):
        full = os.path.join(drop, entry)
        if drop_top_level_file(entry):
            continue
        if not os.path.isdir(full) or is_link(full):
            notes.append('skipped %s: not in a season folder' % entry)
            continue
        m = SEASON_DIR_RE.match(entry.strip())
        n = parse_season(m.group(1)) if m else None
        if n is None:
            notes.append('skipped %s: not a "Season <n>" folder' % entry)
            continue
        if n in folder_of:
            problems.append('%s and %s are both Season %d; merge them' % (folder_of[n], entry, n))
            continue
        folder_of[n] = entry
        empties[n] = []
        seasons[n] = find_resources(full, entry, notes, empties[n])
    spelled: dict[str, str] = {}
    for n in sorted(seasons):
        problems += name_problems(seasons[n], ' in Season %d' % n)
        for name, _full, lab in seasons[n]:
            low = name.lower()
            if low in spelled and spelled[low] != name:
                problems.append('%s is spelled %s in another season folder; FiveM tells them apart, so '
                                'rename one to match' % (lab, spelled[low]))
            spelled.setdefault(low, name)
    for n in sorted(seasons):
        here = {name.lower(): lab for name, _full, lab in seasons[n]}
        for name, _full, lab in empties[n]:
            low = name.lower()
            if low in here:
                problems.append('%s and %s are one resource twice in Season %d' % (here[low], lab, n))
            here.setdefault(low, lab)
            if low in spelled and spelled[low] != name:
                problems.append('%s is spelled %s in a season folder that has the pack; rename it to match'
                                % (lab, spelled[low]))
    return seasons, empties, notes, problems


# -- the index ---------------------------------------------------------------
#
# EVERY FILE'S BYTES ARE HASHED ON EVERY PUBLISH; the index only spares
# packing and compressing them again. It maps a pack's CONTENT -- each file's
# path, size and sha256 -- to the archive that content packs to, which
# write_pack makes a pure function of it. So an index hit is proved by the
# bytes on disk now, never assumed from them.
#
# Stat data cannot promise that, and every case the review raised beats it: a
# file rewritten to the same size with its mtime put back; an Explorer copy,
# which keeps the source's mtime; a texture re-exported at the same resolution,
# so the same .ytd size. A file id and a creation time do not save it either:
# NTFS keeps both across an overwrite in place, and it hands a file deleted and
# made again under the same name within seconds its old creation time back
# ("tunneling"). Reading the bytes costs a disk read; packing is the slow part.

INDEX_FORMAT = 2


def content_digest(entries) -> str:
    """One sha256 over (path, size, sha256 of the bytes) for every file."""
    h = hashlib.sha256()
    for relp, size, digest in entries:
        h.update(('%s\0%d\0%s\n' % (relp, size, digest)).encode('utf-8'))
    return h.hexdigest()


def load_index(path: str) -> dict:
    data = read_json(path)
    if not isinstance(data, dict) or data.get('format') != INDEX_FORMAT or not isinstance(data.get('packs'), dict):
        return {}
    return data['packs']


def save_index(path: str, packs: dict, used: set) -> None:
    keep = {k: v for k, v in packs.items() if k in used}
    atomic_write(path, json.dumps({'format': INDEX_FORMAT, 'packs': keep}, indent=1, sort_keys=True) + '\n')


def hash_folder(folder: str, index: dict, tmp: str) -> dict:
    """The sha256 and size the folder packs to, and its file list. Every
    file's bytes are read and hashed; the archive comes from the index when
    exactly that content was packed before, and is packed here otherwise."""
    files, _skipped = collect(folder)
    if not any(relp == 'fxmanifest.lua' for relp, _, _, _ in files):
        raise AssetsError('%s has no fxmanifest.lua at its top' % folder)
    content = content_digest((relp, size, sha256_file(full)[0]) for relp, full, size, _ in files)
    filemap = {relp: size for relp, _, size, _ in files}
    info = {'files': filemap, 'folder': folder, 'content': content, 'archive': None}
    hit = index.get(content)
    if isinstance(hit, dict) and isinstance(hit.get('sha'), str) and SHA_RE.match(hit['sha']) \
            and is_int(hit.get('size')):
        info.update(sha=hit['sha'], size=hit['size'], reused=True)
        return info
    out = os.path.join(tmp, '%d.tar.gz' % len(os.listdir(tmp)))
    packed: dict[str, str] = {}
    write_pack(files, out, packed)
    if content_digest((relp, size, packed[relp]) for relp, _, size, _ in files) != content:
        raise AssetsError('%s changed while it was being published; wait for any copy into it to finish, '
                          'then run Publish again' % folder)
    sha, size = sha256_file(out)
    index[content] = {'sha': sha, 'size': size}
    info.update(sha=sha, size=size, archive=out, reused=False)
    return info


def archive_for(info: dict, name: str, tmp: str) -> str:
    """The archive to upload: the one packed this run, or -- for an index hit,
    which was never packed this run -- packed now and held to the sha the
    plan was made with."""
    if info['archive'] is None:
        files, _ = collect(info['folder'])
        out = os.path.join(tmp, '%s-%s.tar.gz' % (name, short(info['sha'])))
        write_pack(files, out)
        if sha256_file(out)[0] != info['sha']:
            raise AssetsError('%s changed while it was being published; run Publish again' % info['folder'])
        info['archive'] = out
    return info['archive']


# -- the lock the folders describe ---------------------------------------------

def lock_from_drop(old: dict, found: dict[str, dict[int, dict]],
                   removed: dict[str, dict[int, str]]) -> tuple[dict, list[str]]:
    """The lock the folders describe, and a note for each empty folder that
    removes nothing. `found` is {name: {season: hash_folder's answer}},
    `removed` is {name: {season: label}} for the empty folders.

    A resource keeps its place in the lock (licensed.cfg's ensure order); new
    ones follow, by first season, then name. Its pins are the seasons where
    what is in force changes: a version, or null where an empty folder is. A
    season that holds the version already in force adds no pin; an empty folder
    with nothing in force before it removes nothing and is only noted."""
    by_name = {e['name'] for e in old['resources']}
    names = [e['name'] for e in old['resources'] if e['name'] in found]
    names += sorted((n for n in found if n not in by_name), key=lambda n: (min(found[n]), n.lower(), n))
    notes: list[str] = []
    out = []
    for name in names:
        events: dict[int, dict | None] = dict(found[name])
        for n in removed.get(name, {}):
            events.setdefault(n, None)
        seasons: dict[str, str | None] = {}
        versions: dict[str, dict] = {}
        in_force = None
        removed_at = None
        for n in sorted(events):
            info = events[n]
            sha = None if info is None else info['sha']
            if sha == in_force:
                if info is None:
                    notes.append('skipped %s: empty, and nothing to remove: %s' % (
                        removed[name][n], ('%s is removed from Season %d on already' % (name, removed_at))
                        if removed_at else 'no earlier Season folder has %s' % name))
                continue
            seasons[str(n)] = sha
            if info is not None:
                versions[sha] = {'size': info['size'], 'files': dict(info['files'])}
            removed_at = n if info is None else None
            in_force = sha
        out.append({'name': name, 'seasons': seasons, 'versions': versions})
    for name in sorted(n for n in removed if n not in found):
        for n in sorted(removed[name]):
            notes.append('skipped %s: empty, and nothing to remove: no earlier Season folder has %s'
                         % (removed[name][n], name))
    return {'format': LOCK_FORMAT, 'resources': out}, notes


# -- the plan ------------------------------------------------------------------

def lock_changes(old: dict, new: dict) -> list[tuple[int, str, str, str | None, int, str | None]]:
    """(season, kind, name, sha, size, was) for each pin that differs, sorted
    by season then name. Kinds:

      added      a version pinned where nothing was
      readded    a version pinned where a null was (back from that season)
      changed    one version for another
      removed    a null pinned: "<name>: removed from Season N on"
      unremoved  a null taken away: the earlier pin carries on again
      unpinned   a version's pin taken away: the earlier pin carries on
      retired    the resource is in no season folder at all (one line)"""
    o = {e['name']: e for e in old['resources']}
    n = {e['name']: e for e in new['resources']}
    out = []
    for name in sorted(set(o) | set(n), key=lambda s: (s.lower(), s)):
        if name not in n:
            first = min(int(k) for k, v in o[name]['seasons'].items() if v is not None)
            sha = o[name]['seasons'][str(first)]
            out.append((first, 'retired', name, sha, o[name]['versions'][sha]['size'], None))
            continue
        os_ = o[name]['seasons'] if name in o else {}
        ns_ = n[name]['seasons']
        for k in sorted(set(os_) | set(ns_), key=int):
            was = os_.get(k)
            if k in ns_ and (k not in os_ or ns_[k] != was):
                sha = ns_[k]
                if sha is None:
                    out.append((int(k), 'removed', name, None, 0, was))
                else:
                    kind = 'added' if k not in os_ else ('readded' if was is None else 'changed')
                    out.append((int(k), kind, name, sha, n[name]['versions'][sha]['size'], was))
            elif k in os_ and k not in ns_:
                out.append((int(k), 'unremoved' if was is None else 'unpinned', name, None, 0, was))
    out.sort(key=lambda c: (c[0], c[2].lower(), c[2]))
    return out


SIGNS = {'added': '+', 'readded': '+', 'changed': '~', 'removed': '-', 'unremoved': '+', 'unpinned': '~',
         'retired': '-'}


def change_lines(changes) -> list[str]:
    lines = []
    season = None
    for s, kind, name, sha, size, was in changes:
        if s != season:
            lines.append('Season %d' % s)
            season = s
        if kind == 'added':
            tail = '%s, %s' % (short(sha), human(size))
        elif kind == 'readded':
            tail = '%s, %s (it was removed from Season %d on)' % (short(sha), human(size), s)
        elif kind == 'changed':
            tail = '%s, %s (was %s)' % (short(sha), human(size), short(was))
        elif kind == 'removed':
            tail = 'removed from Season %d on' % s
        elif kind == 'unremoved':
            tail = 'no longer removed from Season %d on' % s
        elif kind == 'unpinned':
            tail = 'no longer pinned at Season %d (was %s); the earlier pin carries on' % (s, short(was))
        else:
            tail = 'retired: in no Season folder (its archives stay in the bucket)'
        lines.append('  %s %s: %s' % (SIGNS[kind], name, tail))
    return lines


def commit_message(changes) -> str:
    added, updated, removed, retired = [], [], [], []
    for s, kind, name, _sha, _size, _was in changes:
        if kind == 'added':
            group, item = added, name
        elif kind == 'removed':
            group, item = removed, '%s from Season %d on' % (name, s)
        elif kind == 'retired':
            group, item = retired, name
        else:
            group, item = updated, name
        if item not in group:
            group.append(item)
    parts = ['%s %s' % (verb, ', '.join(g)) for verb, g in
             (('add', added), ('update', updated), ('remove', removed), ('retire', retired)) if g]
    subject = 'Licensed assets: ' + ('; '.join(parts) or 'assets.lock')
    if len(subject) > 72:
        subject = 'Licensed assets: %s' % ', '.join(
            '%d %s' % (len(g), w) for g, w in ((added, 'added'), (updated, 'updated'),
                                              (removed, 'removed from a season'), (retired, 'retired')) if g)
    return '%s\n\n%s\n\nPublished from the drop folder with tools/assets.py publish (#391).\n' % (
        subject, '\n'.join(change_lines(changes)))


# -- git, in Publish's own clone -------------------------------------------------

def git_cmd() -> str:
    g = shutil.which('git')
    if not g:
        raise AssetsError('git is not on PATH')
    return g


def git(repo: str | None, *args: str, check: bool = True, env: dict | None = None,
        data: bytes | None = None) -> subprocess.CompletedProcess:
    """git in `repo` (or nowhere in particular when None). Its stdin is the
    data given, or nothing: never the console, whose next line is the
    owner's y/N answer."""
    cmd = [git_cmd()] + (['-C', repo] if repo else []) + list(args)
    try:
        r = subprocess.run(cmd, input=data if data is not None else b'', stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, env=env)
    except OSError as e:
        raise AssetsError('cannot run git: %s' % e)
    r.out = r.stdout.decode('utf-8', 'replace').strip()
    r.err = r.stderr.decode('utf-8', 'replace').strip()
    if check and r.returncode != 0:
        raise AssetsError('git %s failed: %s' % (' '.join(args[:2]), last_line(r.err or r.out)))
    return r


def ask(question: str) -> bool:
    try:
        answer = input(question + ' ')
    except EOFError:
        print()
        return False
    return answer.strip().lower() in ('y', 'yes')


def default_clone_dir() -> str:
    """%LOCALAPPDATA%\\BlitzAssets\\repo -- outside every work tree, and the
    path Publish.cmd names."""
    base = os.environ.get('LOCALAPPDATA') or os.path.join(os.path.expanduser('~'), '.local', 'share')
    return os.path.join(base, 'BlitzAssets', 'repo')


def ensure_clone(clone: str, origin: str) -> None:
    """Publish's own clone: made on first use from `origin`, and marked, so a
    path that is anything else -- a checkout an agent or the owner works in --
    is refused rather than used."""
    dotgit = os.path.join(clone, '.git')
    if not os.path.lexists(dotgit):
        if os.path.isdir(clone) and os.listdir(clone):
            raise AssetsError('%s is not empty and is not a clone. Publish keeps its own clone there: move '
                              'that folder away. Nothing was uploaded or changed.' % clone)
        tree = enclosing_work_tree(os.path.dirname(clone))
        if tree:
            raise AssetsError("%s is inside the git work tree %s; Publish's clone must be outside every work "
                              'tree. Nothing was uploaded or changed.' % (clone, tree))
        say('first Publish here: cloning %s from %s into %s' % (PUBLISH_BRANCH, origin, clone))
        os.makedirs(os.path.dirname(clone), exist_ok=True)
        git(None, 'clone', '--quiet', '--single-branch', '--branch', PUBLISH_BRANCH, '--no-tags', origin, clone)
        git(clone, 'config', CLONE_MARK, 'true')
        return
    if not os.path.isdir(dotgit) or git(clone, 'config', '--get', CLONE_MARK, check=False).out != 'true':
        raise AssetsError("%s is not Publish's own clone (it has no %s mark), so publish will not touch it: "
                          'Publish never works in a checkout anyone else uses. Leave out --clone to use %s. '
                          'Nothing was uploaded or changed.' % (clone, CLONE_MARK, default_clone_dir()))


def fetch_dev(clone: str) -> str:
    """Fetch dev; the commit it is at on GitHub now."""
    ref = 'refs/remotes/origin/%s' % PUBLISH_BRANCH
    r = git(clone, 'fetch', '--quiet', '--no-tags', 'origin', '+refs/heads/%s:%s' % (PUBLISH_BRANCH, ref),
            check=False)
    if r.returncode != 0:
        raise AssetsError('could not fetch %s: %s' % (PUBLISH_BRANCH, last_line(r.err or r.out)))
    return git(clone, 'rev-parse', '--verify', '--quiet', ref + '^{commit}').out


def tree_resource_names(clone: str, commit: str) -> frozenset[str]:
    """repo_resource_names(), read from a commit instead of a work tree."""
    raw = git(clone, 'ls-tree', '-r', '-z', '--name-only', commit, '--', 'resources').stdout
    dirs = set()
    for path in raw.decode('utf-8', 'replace').split('\0'):
        parts = path.split('/')
        if len(parts) < 3 or parts[-1] not in ('fxmanifest.lua', '__resource.lua'):
            continue
        if any(p == 'node_modules' or p.startswith('.') for p in parts[1:-1]):
            continue
        dirs.add(tuple(parts[:-1]))
    # A resource inside another one is not walked into, as on disk.
    return frozenset(d[-1].lower() for d in dirs if not any(d[:i] in dirs for i in range(2, len(d))))


def lock_at(clone: str, commit: str, names: frozenset[str]) -> dict:
    """The lock in `commit`, validated; absent is empty."""
    if not git(clone, 'ls-tree', '--name-only', commit, '--', LOCK_NAME).out:
        return {'format': LOCK_FORMAT, 'resources': []}
    data = parse_lock_text(git(clone, 'cat-file', 'blob', '%s:%s' % (commit, LOCK_NAME)).stdout.decode('utf-8', 'replace'))
    problems = validate(data, names)
    if problems:
        raise AssetsError("%s's %s does not pass check, so nothing can be published on top of it; fix it on %s "
                          'first:\n%s' % (PUBLISH_BRANCH, LOCK_NAME, PUBLISH_BRANCH,
                                          '\n'.join('  ' + x for x in problems)))
    return data


def build_commit(clone: str, base: str, text: str, message: str) -> str:
    """A commit on top of `base` whose only change is assets.lock = `text`.
    Plumbing, with a throwaway index: no work tree, branch or HEAD is touched."""
    blob = git(clone, 'hash-object', '-w', '--stdin', data=text.encode('utf-8')).out
    with tempfile.TemporaryDirectory(prefix='assets-index-') as td:
        env = dict(os.environ, GIT_INDEX_FILE=os.path.join(td, 'index'))
        git(clone, 'read-tree', base, env=env)
        git(clone, 'update-index', '--add', '--cacheinfo', '100644,%s,%s' % (blob, LOCK_NAME), env=env)
        tree = git(clone, 'write-tree', env=env).out
    return git(clone, 'commit-tree', tree, '-p', base, '-F', '-', data=message.encode('utf-8')).out


def check_commit(clone: str, base: str, commit: str, text: str, names: frozenset[str]) -> None:
    """THE LAST LOOK BEFORE THE PUSH: the commit's one parent is `base`, it
    changes assets.lock and nothing else, its lock is the text the plan was
    made from, and that lock passes check against `base`'s resources."""
    parents = git(clone, 'rev-list', '--parents', '-n', '1', commit).out.split()[1:]
    changed = [p for p in git(clone, 'diff-tree', '--no-commit-id', '--name-only', '-r', '-z', base,
                              commit).stdout.decode('utf-8', 'replace').split('\0') if p]
    held = git(clone, 'cat-file', 'blob', '%s:%s' % (commit, LOCK_NAME)).stdout
    problems = []
    if parents != [base]:
        problems.append('its parent is not %s at %s' % (PUBLISH_BRANCH, short(base)))
    if changed != [LOCK_NAME]:
        problems.append('it changes %s, not %s alone' % (', '.join(changed) or 'nothing', LOCK_NAME))
    if held != text.encode('utf-8'):
        problems.append('its %s is not the one the plan was made from' % LOCK_NAME)
    else:
        problems += validate(parse_lock_text(held.decode('utf-8')), names)
    if problems:
        raise AssetsError('the commit failed its last check, so nothing was pushed:\n%s'
                          % '\n'.join('  ' + x for x in problems))


def push_commit(clone: str, base: str, commit: str) -> bool:
    """Push `commit` to dev. True when GitHub's dev now holds it -- read back
    from GitHub, never taken from the push's word -- and False when dev had
    moved on from `base`, so the plan has to be made again. Raises otherwise."""
    say('git push origin %s:refs/heads/%s' % (short(commit), PUBLISH_BRANCH))
    r = git(clone, 'push', 'origin', '%s:refs/heads/%s' % (commit, PUBLISH_BRANCH), check=False)
    now = fetch_dev(clone)
    if git(clone, 'merge-base', '--is-ancestor', commit, now, check=False).returncode == 0:
        say('pushed to %s: %s%s' % (PUBLISH_BRANCH, git(clone, 'log', '-1', '--format=%h %s', commit).out,
                                    '' if now == commit else ' (dev has moved on since, to %s)' % short(now)))
        return True
    if r.returncode == 0:
        raise AssetsError('git push said it worked, but %s on GitHub (%s) does not hold %s. Nothing else was '
                          'changed; run Publish again.' % (PUBLISH_BRANCH, short(now), short(commit)))
    if now == base:
        raise AssetsError('the push failed: %s\nNothing reached GitHub. The archives already uploaded stay in '
                          'the bucket, and the next Publish uses them.' % last_line(r.err or r.out))
    return False


def cmd_publish(args) -> int:
    """THE DROP FOLDER, PUBLISHED, FROM PUBLISH'S OWN CLONE.

    Publish never runs git in a checkout anyone else uses (an agent's
    branch switch mid-prompt once sent its lock commit elsewhere and still
    reported "pushed"). Its clone lives outside every work tree
    (default_clone_dir(), made on first use) and nothing in it is a branch:

      1. fetch dev; the plan is made against GitHub's dev, its lock and its
         resource names, never a local file;
      2. hash every pack, and compute the lock the folders make on top of
         dev's lock; show the plan;
      3. upload what the bucket lacks;
      4. ask y/N. n: nothing is written anywhere -- no lock, no commit --
         and only the uploaded archives remain;
      5. y: build a commit on top of the fetched dev whose only change is
         assets.lock, check it once more, and push it to refs/heads/dev;
      6. dev moved meanwhile (the push is refused as not a fast-forward):
         fetch, make the plan again from the folders on the new dev, push
         without asking if it is unchanged, and ask again if it is not;
      7. "pushed" only once GitHub's dev is fetched back and holds the commit.
    """
    drop = os.path.abspath(args.drop)
    if not os.path.isdir(drop):
        raise AssetsError('not a folder: %s' % drop)
    tree = enclosing_work_tree(drop)
    if tree:
        raise AssetsError('%s is inside the git work tree %s, and nothing licensed may sit in a repository. '
                          'Move the folder out (the Desktop is fine). Nothing was uploaded or changed.'
                          % (drop, tree))
    clone = os.path.abspath(args.clone or default_clone_dir())
    if clone == drop or inside(clone, drop) or inside(drop, clone):
        raise AssetsError("Publish's clone (%s) and the drop folder (%s) must not be inside one another"
                          % (clone, drop))
    ensure_clone(clone, args.origin)
    index_path = os.path.join(drop, DROP_INDEX)
    approved = None
    aws_box: list[Aws] = []

    with tempfile.TemporaryDirectory(prefix='assets-publish-') as tmp:
        for _attempt in range(PUBLISH_RETRIES):
            base = fetch_dev(clone)
            names = tree_resource_names(clone, base)
            old = lock_at(clone, base, names)
            say('%s is at %s; scanning %s' % (PUBLISH_BRANCH, short(base), drop))
            seasons, empties, notes, problems = scan_drop(drop)
            for n in notes:
                say('  ' + n)
            if not seasons and not problems:
                # That would retire every pack; deleting each pack is how to ask.
                problems.append('%s has no "Season <n>" folder; init-drop makes them' % drop)
            for name in sorted({name for items in seasons.values() for name, _, _ in items if name.lower() in names}):
                problems.append('%s: a resource in this repository already has that name; rename the folder' % name)
            if problems:
                raise AssetsError('nothing was uploaded or changed:\n%s' % '\n'.join('  ' + x for x in problems))

            index = load_index(index_path)
            used: set[str] = set()
            found: dict[str, dict[int, dict]] = {}
            removed: dict[str, dict[int, str]] = {}
            for n in sorted(seasons):
                for name, full, lab in seasons[n]:
                    info = hash_folder(full, index, tmp)
                    used.add(info['content'])
                    say('  %s: %s, %d files, %s%s' % (lab, short(info['sha']), len(info['files']),
                                                      human(info['size']), ', packed before' if info['reused'] else ''))
                    found.setdefault(name, {})[n] = info
                for name, _full, lab in empties[n]:
                    say('  %s: empty' % lab)
                    removed.setdefault(name, {})[n] = lab
            save_index(index_path, index, used)

            updated, rnotes = lock_from_drop(old, found, removed)
            for x in rnotes:
                say('  ' + x)
            problems = validate(updated, names)
            if problems:
                raise AssetsError('the lock these folders make would not pass check; nothing was uploaded or '
                                  'changed:\n%s' % '\n'.join('  ' + x for x in problems))
            changes = lock_changes(old, updated)
            say()
            if not changes:
                say("nothing to publish: %s's %s already says what the folders hold" % (PUBLISH_BRANCH, LOCK_NAME))
                return 0
            plan = change_lines(changes)
            say('the plan:')
            for line in plan:
                say('  ' + line)
            unchanged = sum(1 for e in updated['resources'] if not any(c[2] == e['name'] for c in changes))
            if unchanged:
                say('  %d resource(s) unchanged' % unchanged)

            # Only versions dev's lock does not already name can be missing
            # from the bucket: a named one went up, and was checked, when it
            # was published.
            known = {(e['name'], sha) for e in old['resources'] for sha in e['versions']}
            items = []
            for e in updated['resources']:
                for k in sorted(e['seasons'], key=int):
                    sha = e['seasons'][k]
                    if sha is None or (e['name'], sha) in known or any(
                            i['name'] == e['name'] and i['sha'] == sha for i in items):
                        continue
                    info = found[e['name']][int(k)]
                    items.append({'name': e['name'], 'sha': sha, 'size': info['size'],
                                  'label': '%s (Season %s)' % (e['name'], k),
                                  'archive': (lambda info=info, name=e['name']: archive_for(info, name, tmp))})
            if items:
                say()
                if not aws_box:
                    aws_box.append(make_aws(args, PUSH_PROFILE))
                up, there = upload_missing(aws_box[0], items, progress=True)
                say('%d uploaded, %d already in the bucket' % (up, there))

            message = commit_message(changes)
            if plan != approved:
                say()
                if approved is not None:
                    say('%s moved while this was being published, and the plan above is not the one you '
                        'answered' % PUBLISH_BRANCH)
                say('the commit, on top of %s at %s:' % (PUBLISH_BRANCH, short(base)))
                for line in message.rstrip('\n').splitlines():
                    say('  ' + line)
                if not ask('Commit and push to %s? [y/N]' % PUBLISH_BRANCH):
                    say('not published: nothing was committed or pushed, and no lock was written anywhere%s'
                        % ('; what was uploaded stays in the bucket for next time' if items else ''))
                    return 0
                approved = plan
            else:
                say('%s moved while this was being published; the plan is the same, so pushing again' % PUBLISH_BRANCH)
            text = dump_lock(updated)
            commit = build_commit(clone, base, text, message)
            check_commit(clone, base, commit, text, names)
            if push_commit(clone, base, commit):
                return 0
            say('%s moved while this was being published; making the plan again from the folders' % PUBLISH_BRANCH)
    raise AssetsError('%s moved %d times while this was being published, so nothing was pushed. Run Publish again.'
                      % (PUBLISH_BRANCH, PUBLISH_RETRIES))


def cmd_safe(text: str, what: str) -> str:
    if not text.isascii() or any(c in text for c in '"%^&|<>!') or any(ord(c) < 32 for c in text):
        raise AssetsError('%s %r cannot be written into a .cmd file safely' % (what, text))
    return text


def publish_cmd_text(clone: str | None, origin: str) -> str:
    """Publish.cmd. It names no checkout: it runs dev's own tools/assets.py
    out of Publish's clone, fetched and checked out first, so Publish is
    always dev's latest. THE FIRST RUN BOOTSTRAPS ITSELF: with no clone yet it
    clones dev from GitHub (git and py are all it needs) and marks the clone
    as Publish's."""
    clone_expr = CLONE_IN_LOCALAPPDATA if clone is None else cmd_safe(clone, 'the clone path')
    lines = [
        '@echo off',
        'rem Written by tools/assets.py init-drop (#391).',
        'rem Publish works in its own clone of the repo, never in a checkout anyone',
        'rem else uses. The first run clones dev into it; every run fetches dev,',
        'rem checks it out and runs that tools/assets.py, so Publish is always',
        "rem dev's latest.",
        'setlocal',
        'set "CLONE=%s"' % clone_expr,
        'set "ORIGIN=%s"' % cmd_safe(origin, 'the origin URL'),
        'if exist "%CLONE%\\.git" goto fetch',
        'echo First Publish here: cloning dev into "%CLONE%"',
        'git clone --quiet --single-branch --branch %s --no-tags "%%ORIGIN%%" "%%CLONE%%" || goto failed'
        % PUBLISH_BRANCH,
        'git -C "%%CLONE%%" config %s true || goto failed' % CLONE_MARK,
        ':fetch',
        'git -C "%%CLONE%%" fetch --quiet --no-tags origin +refs/heads/%s:refs/remotes/origin/%s || goto failed'
        % (PUBLISH_BRANCH, PUBLISH_BRANCH),
        'git -C "%%CLONE%%" checkout --quiet --force --detach refs/remotes/origin/%s || goto failed'
        % PUBLISH_BRANCH,
        'if not exist "%CLONE%\\tools\\assets.py" goto notool',
        'py -3 "%CLONE%\\tools\\assets.py" publish "%~dp0." --clone "%CLONE%"',
        'goto done',
        ':notool',
        'echo %s has no tools/assets.py yet.' % PUBLISH_BRANCH,
        ':failed',
        'echo Nothing was published.',
        ':done',
        'echo.',
        'pause',
    ]
    return '\r\n'.join(lines) + '\r\n'


def cmd_init_drop(args) -> int:
    drop = os.path.abspath(args.drop)
    tree = enclosing_work_tree(drop)
    if tree:
        raise AssetsError('%s is inside the git work tree %s, and nothing licensed may sit in a repository. '
                          'Pick a folder outside it (the Desktop is fine).' % (drop, tree))
    text = publish_cmd_text(os.path.abspath(args.clone) if args.clone else None, args.origin)
    os.makedirs(drop, exist_ok=True)
    for n in DROP_SEASONS:
        os.makedirs(os.path.join(drop, 'Season %d' % n), exist_ok=True)
    path = os.path.join(drop, PUBLISH_CMD)
    if read_bytes(path) != text.encode('ascii'):
        write_bytes_atomic(path, text.encode('ascii'))
    readme = os.path.join(drop, DROP_README)
    wrote_readme = not os.path.lexists(readme)
    if wrote_readme:
        write_bytes_atomic(readme, README_TEXT.replace('\n', '\r\n').encode('ascii'))
    say('%s: %s, %s%s; Publish clones into %s' % (
        drop, ', '.join('Season %d' % n for n in DROP_SEASONS), PUBLISH_CMD,
        ' and %s' % DROP_README if wrote_readme else ' (%s kept as it is)' % DROP_README,
        os.path.abspath(args.clone) if args.clone else CLONE_IN_LOCALAPPDATA))
    return 0


# --------------------------------------------------------------------------
# status and check
# --------------------------------------------------------------------------

def cmd_status(args) -> int:
    lock = load_lock(args.lock)
    say('%s: %d resource(s)' % (args.lock, len(lock['resources'])))
    aws = None if args.offline else make_aws(args)
    server_root = os.path.abspath(args.server_root) if args.server_root else None
    box = bool(server_root and os.path.isdir(os.path.join(server_root, 'resources')))
    licensed = os.path.join(server_root, 'resources', LICENSED_GROUP) if box else None
    cache = (os.path.abspath(args.cache) if args.cache else os.path.join(server_root, CACHE_DIR)) if box else None
    record = (read_record(licensed) or {}) if box else {}
    missing = 0
    for e in lock['resources']:
        say(e['name'])
        for k in sorted(e['seasons'], key=int):
            sha = e['seasons'][k]
            if sha is None:
                say('  Season %s: removed, not installed from this season on' % k)
                continue
            ver = e['versions'][sha]
            facts = ['%s' % human(ver['size']), '%d files' % len(ver['files'])]
            if aws is not None:
                have = aws.head(object_key(e['name'], sha))
                if have is None:
                    facts.append('MISSING from the bucket')
                    missing += 1
                elif have != ver['size']:
                    facts.append('bucket holds %d bytes, not %d' % (have, ver['size']))
                    missing += 1
                else:
                    facts.append('in the bucket')
            if box:
                facts.append('cached' if os.path.isfile(os.path.join(cache, e['name'], sha + '.tar.gz')) else 'not cached')
                if record.get(e['name']) == sha:
                    facts.append('installed')
            say('  Season %s: %s  %s' % (k, short(sha), ', '.join(facts)))
    if box:
        latest = read_latest()
        season, how = resolve_season(args, server_root, latest)
        plan = plan_for(lock, season)
        say('this box: Season %d (%s)' % (season, how))
        for name, sha, _ in plan:
            have = record.get(name)
            if have == sha:
                state = 'installed'
            elif have == UNKNOWN_VERSION:
                state = 'installed at a version a failed swap could not record; the next pull reinstalls it'
            elif have:
                state = 'installed %s, lock says %s' % (short(have), short(sha))
            else:
                state = 'not installed'
            say('  %s %s: %s' % (name, short(sha), state))
        for d in installed_dirs(licensed):
            if d not in {n for n, _, _ in plan}:
                say('  %s: installed, not in force for Season %d (the next pull removes it)' % (d, season))
        for e in leftovers(cache):
            say('  %s: left by a pull that did not finish (the next pull recovers it)' % os.path.join(cache, e))
    if missing:
        say('%d archive(s) the lock names are not in the bucket' % missing)
        return 1
    return 0


def cmd_check(args) -> int:
    raw = read_bytes(args.lock)
    if raw is None:
        say('no %s: nothing to check' % os.path.basename(args.lock))
        return 0
    try:
        data = parse_lock_text(raw.decode('utf-8', 'replace'))
        problems = validate(data, repo_resource_names())
    except AssetsError as e:
        problems = [str(e)]
    if problems:
        for x in problems:
            print('FAIL %s: %s' % (os.path.basename(args.lock), x))
        return 1
    res = data['resources']
    nver = sum(len(e['versions']) for e in res)
    nfiles = sum(len(v['files']) for e in res for v in e['versions'].values())
    say('%s is valid: %d resource(s), %d version(s), %d file(s) listed'
        % (os.path.basename(args.lock), len(res), nver, nfiles))
    return 0


# --------------------------------------------------------------------------
# command line
# --------------------------------------------------------------------------

def season_arg(text: str) -> int:
    n = parse_season(text)
    if n is None:
        raise argparse.ArgumentTypeError('%r is not a season (a whole number from 1)' % text)
    return n


def build_parser() -> argparse.ArgumentParser:
    bucket = argparse.ArgumentParser(add_help=False)
    bucket.add_argument('--aws', help='the AWS CLI to run (default: aws on PATH, then /snap/bin/aws)')
    bucket.add_argument('--profile', help="AWS profile; 'none' for the instance role "
                                          "(default: %s for push and publish, none otherwise)" % PUSH_PROFILE)
    bucket.add_argument('--region', default=REGION)
    bucket.add_argument('--bucket', default=BUCKET)
    # publish has no --lock: it reads dev's, in its own clone.
    common = argparse.ArgumentParser(add_help=False, parents=[bucket])
    common.add_argument('--lock', default=os.path.join(REPO_ROOT, LOCK_NAME),
                        help='the lock file (default: assets.lock at the repo root)')

    box = argparse.ArgumentParser(add_help=False)
    box.add_argument('--server-root', default=os.environ.get('BR_SERVER_ROOT', DEFAULT_SERVER_ROOT),
                     help='the FXServer data directory (default: $BR_SERVER_ROOT or %s)' % DEFAULT_SERVER_ROOT)
    box.add_argument('--server-cfg', help='the cfg the season is read from (default: <server-root>/server.cfg)')
    box.add_argument('--season', type=season_arg, help="install for this season instead of server.cfg's")
    box.add_argument('--cache', help='archive cache (default: <server-root>/%s)' % CACHE_DIR)

    p = argparse.ArgumentParser(prog='assets.py', description='Licensed assets in the private bucket (#391).')
    sub = p.add_subparsers(dest='command', required=True)

    sp = sub.add_parser('publish', parents=[bucket], help="make dev's assets.lock what the drop folder holds, "
                                                          "upload, and (asked) commit and push it, from "
                                                          "Publish's own clone")
    sp.add_argument('drop', help='the drop folder, holding Season <n> folders')
    sp.add_argument('--clone', help="Publish's own clone, made on first use (default: %s)"
                                    % CLONE_IN_LOCALAPPDATA.replace('%', '%%'))
    sp.add_argument('--origin', default=ORIGIN_URL, help='where the first use clones from (default: %(default)s)')
    sp.set_defaults(func=cmd_publish)

    sp = sub.add_parser('init-drop', help='make a drop folder: Season 1 and Season 2, README.txt and Publish.cmd')
    sp.add_argument('drop')
    sp.add_argument('--clone', help="the clone Publish.cmd keeps (default: %s)" % CLONE_IN_LOCALAPPDATA.replace('%', '%%'))
    sp.add_argument('--origin', default=ORIGIN_URL, help='where Publish.cmd clones from (default: %(default)s)')
    sp.set_defaults(func=cmd_init_drop)

    sp = sub.add_parser('push', parents=[common], help='pack resource folders, upload them, pin them in the lock')
    sp.add_argument('folders', nargs='+', metavar='folder',
                    help='a resource folder, or a folder (or [category]) of them')
    sp.add_argument('--name', help='resource name (default: the folder name; one resource only)')
    sp.add_argument('--season', type=season_arg, help='pin these versions from Season N on (default: 1, '
                                                      'or the only season a resource pins a version at)')
    sp.set_defaults(func=cmd_push)

    sp = sub.add_parser('retire', parents=[common], help='remove a resource from Season N on (a null pin), '
                                                         'or from every season')
    sp.add_argument('name')
    sp.add_argument('--season', type=season_arg, help='gone from this season on (default: every season)')
    sp.set_defaults(func=cmd_retire)

    sp = sub.add_parser('pull', parents=[common, box], help="install the lock's resources for this box's season")
    mode = sp.add_mutually_exclusive_group()
    mode.add_argument('--dry-run', action='store_true', help='print the plan; download and change nothing')
    mode.add_argument('--stage', action='store_true', help='download, verify and unpack into the staging dir; '
                                                           'change nothing installed')
    mode.add_argument('--swap', action='store_true', help='swap what --stage staged into resources/[licensed]/')
    sp.set_defaults(func=cmd_pull)

    sp = sub.add_parser('status', parents=[common, box], help='lock vs bucket (and vs this box), read-only')
    sp.add_argument('--offline', action='store_true', help='do not ask the bucket')
    sp.set_defaults(func=cmd_status)
    # status looks at a box only when it is asked to or is on one.
    sp.set_defaults(server_root=os.environ.get('BR_SERVER_ROOT')
                    or (DEFAULT_SERVER_ROOT if os.path.isdir(DEFAULT_SERVER_ROOT) else None))

    sp = sub.add_parser('check', parents=[common], help='validate the lock; never touches the bucket')
    sp.set_defaults(func=cmd_check)
    return p


def main(argv=None) -> int:
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(errors='replace')
        except (AttributeError, ValueError):
            pass
    args = build_parser().parse_args(argv)
    try:
        return args.func(args) or 0
    except (AssetsError, OSError) as e:
        lines = str(e).splitlines() or ['failed']
        print('assets: error: ' + lines[0], file=sys.stderr, flush=True)
        for line in lines[1:]:
            print(line, file=sys.stderr, flush=True)
        return 1
    except KeyboardInterrupt:
        return 130


if __name__ == '__main__':
    sys.exit(main())
