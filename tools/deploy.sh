#!/usr/bin/env bash
#
# FiveM Royale -- deploy script. RUNS ON THE SERVER.
#
#   ./deploy.sh              fetch latest and sync into place
#   ./deploy.sh --dry-run    show what would change, touch nothing
#   ./deploy.sh --status     show local vs remote without deploying
#
# WHICH BRANCH: $BR_BRANCH if set, else the ref pinned in
# $SERVER_ROOT/.branch-pin, else whatever the served clone already has checked
# out, else main. It does NOT unconditionally default to main -- on a box parked
# on a branch that would make every routine deploy a silent revert.
#
# Chain it with your start command so every boot gets the latest:
#
#   /opt/fivem-server-classic/deploy.sh && cd /opt/fivem-server-classic && ./run.sh +exec server.cfg
#
# LICENSED ASSETS (#391): when the fetched assets.lock lists any, or some are
# installed, tools/assets.py stages them before the sync (a failure stops the
# deploy there) and swaps them in after it. See `--- licensed assets ---`.
#
# THE DEPLOYED REF'S OWN deploy.sh DOES THE SYNC. This copy picks the ref,
# fetches it, checks the dispatch rule and resets the served clone; if that
# tree's tools/deploy.sh is a different version, it hands the rest of the
# deploy (and a --dry-run) to a private copy of it, once. See `--- hand over ---`.
#
# ---------------------------------------------------------------------------
# A NOTE ON THE SQUARE BRACKETS
#
# FiveM uses [category] folders, and bash treats [...] as a GLOB CHARACTER CLASS.
# Unquoted, resources/[gamemodes] matches a single character from the set
# g,a,m,e,o,d,s -- so it silently matches nothing, or the wrong thing, and the
# script appears to work while copying to a path you did not intend.
#
# Every bracket path below is quoted. Keep it that way.
# ---------------------------------------------------------------------------

set -euo pipefail

# --- configuration -----------------------------------------------------------

# HTTPS, not SSH. The repo is public, so a read-only clone needs no credential
# at all -- and defaulting to git@ meant the server needed a deploy key on file
# purely to fetch something anyone can curl. One less secret on the box that is
# most exposed to the internet.
REPO="${BR_REPO:-https://github.com/WillMontgomery/fivem-br-gamemode.git}"

# Deliberately NOT defaulted here. Resolving it needs the clone, the pin file
# and a validator, all of which are below; see "which ref" further down.
BRANCH="${BR_BRANCH:-}"

SERVER_ROOT="${BR_SERVER_ROOT:-/opt/fivem-server-classic}"
TARGET_CATEGORY="${BR_TARGET_CATEGORY:-[gamemodes]}"

# Where the working clone lives. Deliberately NOT inside resources/: FiveM would
# scan the .git directory on every refresh, and the repo contains files (ui-src,
# tools, docs) that have no business being served to clients.
SRC_DIR="${BR_SRC_DIR:-$SERVER_ROOT/.gamemode-src}"

# The branch pin the console writes through tools/dispatch.sh's `switchref`.
# One line, `<ref>` or `<ref> <sha>`. Owned by this user, read here, and trusted
# for nothing: the name is re-validated from scratch below and the sha is
# checked against the remote before anything is checked out.
PIN_FILE="${BR_PIN_FILE:-$SERVER_ROOT/.branch-pin}"

# The one directory we own inside the category. Everything outside it is left
# alone, so other gamemodes in [gamemodes] are never touched.
RESOURCE_GROUP="[fivem-royale]"

# --- vendored third-party resources -------------------------------------------
#
# THE SECOND THING THIS SCRIPT SYNCS, AND THE REASON IT HAS TO.
#
# Until this list existed, deploy.sh rsynced $RESOURCE_GROUP and nothing else,
# because resources/ contained nothing else. So a third-party resource vendored
# into this repository under any other group would have been committed,
# reviewed, gated and then never reached the box -- source-only, which is a
# failure mode this project has already had twice, and which produces no error
# anywhere because the box simply keeps running whatever was already there.
#
# EACH ENTRY IS A RESOURCE DIRECTORY, NOT A GROUP, and that is deliberate. The
# sync below runs one rsync per entry with --delete scoped INSIDE that one
# resource directory. Syncing "[voice]" as a group instead would put --delete at
# the category level, where it would remove any OTHER voice resource the
# operator has installed there -- a sibling this repository has no business
# deleting and no way to know about.
#
# The path is relative to resources/ at BOTH ends: resources/[voice]/pma-voice
# here becomes $SERVER_ROOT/resources/[voice]/pma-voice there. That is the path
# pma-voice already occupies on the game box, which is the point -- the deploy
# REPLACES the operator's copy rather than adding a second one next to it. Two
# directories both called pma-voice is the "two implementations, nothing
# asserting only one is active" bug this project keeps shipping.
#
# ADDING A VENDORED RESOURCE MEANS ADDING IT HERE. tools/verify.sh fails the
# build if resources/ contains a VENDOR.json this list does not name, so the
# source-only failure above cannot recur silently.
#
# THE TWO ScaleformUI ENTRIES ARE A PAIR AND NEITHER IS OPTIONAL. The library is
# pure Lua that drives compiled Flash movies; the movies live in the assets
# resource. Upstream says so outright -- "it will not work without them" -- so
# deploying one without the other produces a resource that starts, reports no
# error, and draws nothing. Listed assets-first to match the start order in
# server.cfg.example, though rsync order does not itself matter.
#
# cuchi_computer (#396) is the Season 2 terminals' desktop: upstream's shell cut
# down to run standalone, plus the terminal app's committed build. It has no
# server half, so a box without it still boots -- br_core just has no computer
# to open, which is a terminal that does nothing rather than an error.
VENDORED_RESOURCES=(
    "[voice]/pma-voice"
    "[scaleformui]/ScaleformUI_Assets"
    "[scaleformui]/ScaleformUI_Lua"
    "[computer]/cuchi_computer"
)

# --- licensed assets (#391) ----------------------------------------------------
#
# THE THIRD THING A DEPLOY PUTS ON THE BOX, AND THE ONE THAT IS IN NO CLONE.
# Purchased packs may not be redistributed, so this public repository holds
# only assets.lock -- names, hashes, sizes, file lists, season pins -- and
# tools/assets.py (run from the FETCHED clone, so the lock and the tool are the
# branch being deployed) pulls the archives from the private bucket into
# resources/[licensed]/ for the season this box's server.cfg sets.
#
# THAT DIRECTORY BELONGS TO assets.py. Nothing in this script rsyncs into it,
# and the preflight refuses a target or a vendored entry that would: a --delete
# pointed there would remove every licensed resource the box has.
LICENSED_GROUP="[licensed]"
PYTHON="${BR_PYTHON:-python3}"

# --- a handed-over run ----------------------------------------------------------
#
# Set only by the handover further down, in the environment of the copy it
# execs (see `--- hand over ---`). The ref and the sha are the ones the deploy
# that handed over resolved, fetched and checked; this run takes them as they
# are, so it can neither re-resolve the branch nor fetch a tip that moved since.
# Set, they are also the guard: a handed-over run never hands over again.
#
# HANDOVER_PROTOCOL is what the handing-over script looks for, as this exact
# line, before it hands over to a deploy.sh: a version without it (or with
# another number) would ignore the variables above and fetch afresh. Bump it
# only for a change an older script's handover would get wrong.
HANDOVER_PROTOCOL=1
HANDOVER_SHA="${BR_DEPLOY_HANDOVER_SHA:-}"
HANDOVER_REF="${BR_DEPLOY_HANDOVER_REF:-}"
HANDOVER_FROM="${BR_DEPLOY_HANDOVER_FROM:-}"

# The private copy this run was handed, removed when the run exits. Only a file
# sitting in a directory the handover's mktemp named: the variables above come
# from the environment, and a cleanup must not be pointable at anything else.
if [ -n "$HANDOVER_SHA$HANDOVER_REF" ]; then
    HANDOVER_SELF="${BASH_SOURCE[0]}"
    case "$(basename "$(dirname "$HANDOVER_SELF")")" in
        br-deploy-handover.*)
            trap 'rm -f "$HANDOVER_SELF"; rmdir "$(dirname "$HANDOVER_SELF")" 2>/dev/null || true' EXIT ;;
    esac
fi

DRY_RUN=0
STATUS_ONLY=0
CHECK_PAYLOAD_DIR=""
want_payload_dir=0
for arg in "$@"; do
    if [ "$want_payload_dir" -eq 1 ]; then
        CHECK_PAYLOAD_DIR="$arg"; want_payload_dir=0; continue
    fi
    case "$arg" in
        --dry-run)       DRY_RUN=1 ;;
        --status)        STATUS_ONLY=1 ;;
        --check-payload) want_payload_dir=1 ;;
        -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
        *) echo "unknown option: $arg (try --help)"; exit 2 ;;
    esac
done
[ "$want_payload_dir" -eq 1 ] && { echo "--check-payload needs a directory"; exit 2; }

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; DIM=$'\033[2m'; RST=$'\033[0m'
die() { echo "${RED}deploy: $*${RST}" >&2; exit 1; }
say() { echo "${DIM}==${RST} $*"; }

LICENSED_DIR="$SERVER_ROOT/resources/$LICENSED_GROUP"
LICENSED_RECORD="$LICENSED_DIR/br_licensed/installed.txt"

# Whether this deploy has licensed assets to reconcile: the fetched lock lists
# something, or an earlier pull installed something -- an emptied or deleted
# lock still has to take that away again. Neither, and the deploy is exactly
# what it was before #391: no Python, no aws, nothing under [licensed].
assets_wanted() {
    [ -f "$LICENSED_RECORD" ] && return 0
    [ -f "$SRC_DIR/assets.lock" ] || return 1
    # The empty lock, as assets.py writes it.
    if grep -qE '"resources"[[:space:]]*:[[:space:]]*\[[[:space:]]*\]' "$SRC_DIR/assets.lock"; then
        return 1
    fi
    return 0
}

assets_python_ok() { "$PYTHON" -c '' >/dev/null 2>&1; }

# A ref from before #391 has no tools/assets.py, and so no way to reconcile
# what an earlier deploy installed. Its code is deployed and [licensed] is left
# exactly as it is: the boxes ran fine without the packs before, and taking
# them away is the next #391-aware deploy's call, not this one's.
assets_tool_present() { [ -f "$SRC_DIR/tools/assets.py" ]; }
ASSETS_PREDATES_NOTE="has no tools/assets.py (it predates #391): resources/$LICENSED_GROUP/ is left as it is"

# --- payload validation -------------------------------------------------------
#
# A half-deployed gamemode is worse than a stale one, so the payload is checked
# BEFORE anything touches the live server.
#
# IT IS A FUNCTION TAKING A DIRECTORY, AND IT LIVES UP HERE ABOVE THE NETWORK
# AND THE /opt PATHS, so `--check-payload <dir>` can run it on a dev machine
# with no server and no clone. verify.sh does exactly that on every commit.
#
# That shape is a direct consequence of a bug that shipped and failed on the
# first real deploy:
#
#     deploy: no JS bundle in br_ui/ui/assets -- the UI would render blank
#
# The bundle was present; the CHECK was wrong. It used `compgen -G` on a path
# containing `[fivem-royale]`, and `compgen -G` takes a GLOB -- so the brackets
# were read as a character class matching one character from f,i,v,e,m-r,y,a,l,
# matching no real directory. Quoting cannot help, because the argument is
# meant to be a glob; only escaping, or not globbing at all, can.
#
# This is the same bracket-glob hazard the header of this file warns about and
# DEPLOY.md documents for the old pull-and-start.sh. Knowing about a footgun is
# evidently not the same as not firing it -- so it is now exercised on every
# commit against the real path, where a failure is a red build rather than a
# server that will not deploy.

# The resources without which the server does not function. Deliberately SHORT,
# and deliberately not "every resource we currently ship".
#
# It used to list every resource, and that broke the first deploy after a new
# one was added: deploy.sh runs from whatever checkout is on the box while
# deploying whatever is on the target branch, so the script's idea of the
# resource list and the payload's actual contents are two different versions
# that drift the moment either changes. A required-file list is a version
# coupling pretending to be a safety check.
#
# So this names only what has been required since M0 and would be a genuine
# emergency to lose. Everything else is validated STRUCTURALLY below, which
# needs no list and cannot drift.
CORE_RESOURCES="br_lib br_core br_ui"

check_payload() {
    local group="$1"

    [ -d "$group" ] || die "expected $group -- wrong branch, or the layout moved"

    local r
    for r in $CORE_RESOURCES; do
        [ -f "$group/$r/fxmanifest.lua" ] \
            || die "core resource missing from the payload: $r/fxmanifest.lua
  The server cannot run without it. Wrong branch, or a half-finished sync."
    done

    [ -f "$group/br_ui/ui/index.html" ] || die "missing from the payload: br_ui/ui/index.html
  Someone committed UI source without rebuilding.
  On a dev machine:  cd ui-src && npm run build && git add ../resources && git commit"

    # Structural, and this is the check that actually scales: anything sitting
    # in the resource group has to BE a resource. Catches a half-synced tree, a
    # directory left behind by a rename, and a new resource whose manifest was
    # never committed -- without anybody maintaining a list.
    local d
    while IFS= read -r d; do
        [ -f "$d/fxmanifest.lua" ] \
            || die "$(basename "$d") is in the resource group but has no fxmanifest.lua
  FiveM will not load it, and its presence suggests a half-finished sync."
    done < <(find "$group" -mindepth 1 -maxdepth 1 -type d)

    # The UI bundle is the file most likely to be stale or absent, and its
    # absence produces a server that starts cleanly and shows a blank screen.
    #
    # `find` takes the directory as a literal path operand and never interprets
    # it, so a directory named [fivem-royale] is just a directory. This is the
    # line that was wrong.
    if [ -z "$(find "$group/br_ui/ui/assets" -maxdepth 1 -name '*.js' -print -quit 2>/dev/null)" ]; then
        die "no JS bundle in br_ui/ui/assets -- the UI would render blank"
    fi
}

if [ -n "$CHECK_PAYLOAD_DIR" ]; then
    check_payload "$CHECK_PAYLOAD_DIR"
    echo "${GRN}ok${RST}   payload complete (manifests + UI bundle present)"
    exit 0
fi

# --- the branch-switch invariant ----------------------------------------------
#
# THIS IS THE LOAD-BEARING COPY OF THE RULE. tools/dispatch.sh checks it too,
# before it writes the pin, and that check is worth having -- but it is not the
# one that has to be right.
#
# The reason is which clone each script lives in. dispatch.sh is pinned by
# authorized_keys to $SERVER_ROOT/.gamemode-src/tools/dispatch.sh, INSIDE the
# tree this script hard-resets: deploy a branch that ships a different
# dispatch.sh and the console's own channel to this box has been replaced with
# unreviewed code, and every check in it after that point is a check written by
# whoever pushed the branch.
#
# This script runs from the OPS clone, /opt/misc/fivem-br-gamemode -- see
# royale-deploy.service's ExecStart. A branch switch never touches that
# directory. Nothing a deployed branch contains can edit, weaken or skip the
# check below, which is exactly why the check below is the one that counts.
#
# THE HANDOVER DOES NOT CHANGE THAT. It comes after this check and the reset,
# the copy it hands to is pinned to the very sha this check passed, and every
# deploy starts here again, in the ops clone's copy. What the branch's own
# deploy.sh then runs, it runs as the deploy user, the same as the branch's
# tools/assets.py already does (#391).
#
#   A REF IS ONLY DEPLOYABLE IF <sha>:tools/dispatch.sh EXISTS, IS MODE 100755,
#   AND ITS BLOB ID EQUALS origin/main:tools/dispatch.sh's BLOB ID.
#
# Accepted cost, and it is a feature: this cannot be used to test a change to
# tools/. Those go through main and PR review.

# Same shape check dispatch.sh applies, for the same reasons, on a string that
# by the time it gets here has been through a file on disk. A leading '-' is an
# option to git; '..' and '//' climb out of refs/remotes/origin/<ref>.
valid_ref() {
    local r="${1:-}"
    [ -n "$r" ] || return 1
    [ "${#r}" -le 120 ] || return 1
    printf '%s' "$r" | grep -qE '^[A-Za-z0-9][A-Za-z0-9._/-]*$' || return 1
    case "$r" in
        *..*|*//*|*/) return 1 ;;
    esac
    git check-ref-format "refs/heads/$r" >/dev/null 2>&1
}

# "<mode> <blobid>" for tools/dispatch.sh at a commit, or empty if absent.
dispatch_entry() {
    git -C "$SRC_DIR" ls-tree "$1" -- tools/dispatch.sh 2>/dev/null \
        | awk '{print $1" "$3}'
}

# Dies unless <sha> satisfies the rule. Called on the resolved tip of whatever
# is about to be checked out, on EVERY deploy including main's -- main trivially
# equals itself, and a gate with an exemption is a gate with a way around it.
assert_dispatch_invariant() {
    local sha="$1" want have
    want="$(dispatch_entry origin/main)"
    [ -n "$want" ] || die "cannot read tools/dispatch.sh on origin/main.
  The rule that keeps a branch from replacing the console's channel to this box
  is measured against main, so a deploy cannot proceed without it."

    have="$(dispatch_entry "$sha")"
    [ -n "$have" ] || die "refusing $BRANCH: it deletes tools/dispatch.sh.
  That file IS the console's channel to this box, and it lives inside the tree
  this deploy is about to overwrite. Land the change on main instead."

    case "$have" in
        "100755 "*) : ;;
        *) die "refusing $BRANCH: tools/dispatch.sh is not mode 100755 there.
  It would stop being executable after the reset, and the forced command in
  authorized_keys would fail for every console action." ;;
    esac

    [ "$have" = "$want" ] || die "refusing $BRANCH: it changes tools/dispatch.sh.
  Deploying it would replace the console's only channel to this box with code
  that has not been through PR review -- and the replacement would be the thing
  answering the next kick. Land changes to tools/ on main.
    on main:   $want
    on branch: $have"
}

# --- preflight ---------------------------------------------------------------

command -v git   >/dev/null || die "git is not installed:  sudo apt install -y git"
command -v rsync >/dev/null || die "rsync is not installed:  sudo apt install -y rsync"

[ -d "$SERVER_ROOT" ] || die "server root not found: $SERVER_ROOT
  Set it explicitly:  BR_SERVER_ROOT=/path/to/server $0"

TARGET_DIR="$SERVER_ROOT/resources/$TARGET_CATEGORY"

# Quoted patterns, so the brackets are compared as text rather than read as a
# character class (see the note at the top of this file).
case "$TARGET_CATEGORY" in
    "$LICENSED_GROUP"|"$LICENSED_GROUP"/*)
        die "BR_TARGET_CATEGORY may not be $LICENSED_GROUP: that directory belongs to tools/assets.py" ;;
esac
for v in "${VENDORED_RESOURCES[@]}"; do
    case "$v" in
        "$LICENSED_GROUP"|"$LICENSED_GROUP"/*)
            die "vendored resource $v would sync into $LICENSED_GROUP, which belongs to tools/assets.py" ;;
    esac
done

# --- which ref ----------------------------------------------------------------
#
# In order: $BR_BRANCH, the pin file, whatever the clone already has checked
# out, main.
#
# THE THIRD STEP IS THE ONE THAT MATTERS AND IT USED TO BE ABSENT. `main` was
# the unconditional default, which was correct while main was the only thing
# this box ever ran. Once it can be parked on a branch, an unconditional default
# turns EVERY routine deploy -- the console's 72-hour automation, a force, a
# human typing `systemctl start royale-deploy` -- into a silent, unannounced
# revert to main, with players online and nothing in any log saying a branch had
# been swapped out from under them. Falling back to what is already checked out
# means a plain deploy refreshes the ref this box is on, which is the only
# behaviour that is never a surprise.

PINNED_SHA=""
if [ -n "$HANDOVER_SHA$HANDOVER_REF" ]; then
    # Handed over: the ref and the sha the first run resolved and checked,
    # never re-resolved (BR_BRANCH, the pin and the clone could all say
    # something else by now). Both or neither, and both well formed.
    valid_ref "$HANDOVER_REF" \
        || die "handed over with a bad ref ('$HANDOVER_REF'). Nothing has been deployed."
    printf '%s' "$HANDOVER_SHA" | grep -qE '^[0-9a-f]{40}$' \
        || die "handed over with a bad sha ('$HANDOVER_SHA'). Nothing has been deployed."
    BRANCH="$HANDOVER_REF"
    say "branch from the handover: $BRANCH @ ${HANDOVER_SHA:0:8}"
elif [ -n "$BRANCH" ]; then
    say "branch from BR_BRANCH: $BRANCH"
elif [ -r "$PIN_FILE" ]; then
    PIN_REF=""; PIN_SHA=""
    read -r PIN_REF PIN_SHA _ < "$PIN_FILE" || true
    if valid_ref "${PIN_REF:-}"; then
        BRANCH="$PIN_REF"
        # Optional, and consumed on success. It exists to make ONE staged switch
        # exact: hours pass between an admin choosing a branch in the console and
        # the last match ending, and a force-push in the gap must be a refusal
        # rather than a silent deploy of a tip nobody looked at. Once that switch
        # has landed, later routine deploys legitimately track the branch's tip,
        # so keeping the sha forever would instead make every one of them fail.
        if printf '%s' "${PIN_SHA:-}" | grep -qE '^[0-9a-f]{40}$'; then
            PINNED_SHA="$PIN_SHA"
        fi
        say "branch from $PIN_FILE: $BRANCH${PINNED_SHA:+ @ ${PINNED_SHA:0:8}}"
    else
        # Ignored rather than fatal: a corrupt pin must not be able to stop the
        # server being deployed at all. Loud, because it means somebody wrote
        # something by hand that this script will not act on.
        echo "${YEL}deploy: ignoring $PIN_FILE -- '${PIN_REF:-}' is not a usable branch name${RST}" >&2
    fi
fi
if [ -z "$BRANCH" ] && [ -d "$SRC_DIR/.git" ]; then
    BRANCH="$(git -C "$SRC_DIR" symbolic-ref --short -q HEAD || true)"
    valid_ref "${BRANCH:-}" || BRANCH=""
fi
[ -n "$BRANCH" ] || BRANCH=main

# --- fetch -------------------------------------------------------------------
#
# NOT ON A HANDED-OVER RUN. The run that handed over fetched this ref, checked it
# and reset the clone to it moments ago. A second fetch could only find a tip
# that has moved since, which the ops clone's dispatch check never saw, so this
# run deploys the sha it was handed or nothing.

if [ -n "$HANDOVER_SHA" ]; then
    [ -d "$SRC_DIR/.git" ] \
        || die "handed over, but there is no clone at $SRC_DIR. Nothing has been deployed."
    git -C "$SRC_DIR" cat-file -e "$HANDOVER_SHA^{commit}" 2>/dev/null \
        || die "handed over at ${HANDOVER_SHA:0:8}, which $SRC_DIR does not have. Nothing has been deployed."
    say "not fetching: the handover pinned $BRANCH at ${HANDOVER_SHA:0:8}"
fi

if [ -z "$HANDOVER_SHA" ] && [ ! -d "$SRC_DIR/.git" ]; then
    # ALWAYS CLONES main, WHATEVER $BRANCH SAYS. A first clone has nothing to
    # measure the invariant against -- there is no origin/main on disk yet -- so
    # cloning the requested branch directly would install an unreviewed
    # tools/dispatch.sh before any check could run. Clone the reviewed ref, then
    # fall through into the ordinary fetch-check-reset path below, which is the
    # only code that ever puts a branch on this box.
    say "cloning $REPO"
    # A private repo needs credentials. SSH deploy key is the usual answer on a
    # headless box; if this fails, that is almost always why.
    git clone --branch main "$REPO" "$SRC_DIR" \
        || die "clone failed.
  For a private repo, add a read-only deploy key:
    ssh-keygen -t ed25519 -C fivem-deploy -f ~/.ssh/fivem_deploy -N ''
    cat ~/.ssh/fivem_deploy.pub
  then add it under the repo's Settings > Deploy keys, and in ~/.ssh/config:
    Host github.com
      IdentityFile ~/.ssh/fivem_deploy"
fi

if [ -z "$HANDOVER_SHA" ]; then
    say "fetching $BRANCH"
    git -C "$SRC_DIR" remote set-url origin "$REPO"
    git -C "$SRC_DIR" fetch --quiet origin "$BRANCH" || die "origin has no branch called '$BRANCH'.
  It was probably deleted after the console pinned it. Nothing has been
  deployed and the server is still running what it was.
  To go back to main by hand:  echo main > $PIN_FILE"
    # main as well, always, because the invariant below is measured against it
    # and a stale origin/main would measure against a rule that has since changed.
    [ "$BRANCH" = "main" ] || git -C "$SRC_DIR" fetch --quiet origin main \
        || die "cannot fetch origin/main, which the branch rule is measured against."
fi

LOCAL=$(git -C "$SRC_DIR" rev-parse HEAD)
if [ -n "$HANDOVER_SHA" ]; then
    REMOTE="$HANDOVER_SHA"
else
    REMOTE=$(git -C "$SRC_DIR" rev-parse "origin/$BRANCH")
fi

# THE STAGED SHA, IF THERE IS ONE. A moved branch is a refusal and says so; it
# is never a silent deploy of whatever the tip happens to be now.
if [ -n "$PINNED_SHA" ] && [ "$PINNED_SHA" != "$REMOTE" ]; then
    die "$BRANCH has moved since it was chosen in the console.
  chosen:  ${PINNED_SHA:0:8}
  now:     ${REMOTE:0:8}
  Nothing has been deployed. Pick the branch again in Ringmaster, which
  re-checks it and re-pins the commit you are actually looking at."
fi

# THE GATE. Above the reset, and above it on purpose -- see the long comment on
# assert_dispatch_invariant. tools/verify.sh fails the build if a `reset --hard`
# ever appears in this file without one of these calls before it.
assert_dispatch_invariant "$REMOTE"

if [ "$LOCAL" = "$REMOTE" ]; then
    say "already up to date at ${LOCAL:0:8}"
else
    say "updating ${LOCAL:0:8} -> ${REMOTE:0:8}"
    git -C "$SRC_DIR" log --oneline "$LOCAL..$REMOTE" | sed 's/^/     /'
fi

# MOVE HEAD FIRST, WITH PLUMBING, AND THEN RESET.
#
# `git reset --hard origin/feature/x` while HEAD still points at refs/heads/main
# does exactly what it says: it moves the LOCAL main branch to the feature
# branch's commit. The tree would be right and every question about it would be
# answered wrong -- `symbolic-ref HEAD` would say main, so the fallback above
# would resolve to main, the console's off-main banner would never appear, and
# `status` would report the box as running main while it ran something else.
#
# `symbolic-ref` is pure ref plumbing: it writes .git/HEAD and touches no file
# in the working tree, so unlike `checkout` it cannot fail because somebody
# edited a resource in place -- which is the exact failure `reset --hard` is
# here to be immune to. The branch need not exist yet; the reset creates it.
git -C "$SRC_DIR" symbolic-ref HEAD "refs/heads/$BRANCH"

# Hard reset rather than pull. The server clone is a deployment artifact,
# not a workspace -- if someone edited a file in place, their change is not
# in git and must not block a deploy or produce a merge conflict at boot.
#
# To the sha the gate passed, not to origin/$BRANCH by name: anything that
# fetches this clone in between (dispatch.sh's `branches` does) moves the name,
# and a handed-over run is pinned to the sha whatever the name says now.
git -C "$SRC_DIR" reset --quiet --hard "$REMOTE"
git -C "$SRC_DIR" clean --quiet -fd

# The staged switch has happened, so the sha has done its job. Rewriting the pin
# with the ref alone means the next ordinary deploy refreshes this branch
# normally instead of refusing forever the moment somebody pushes to it. The
# invariant above still runs on every deploy, on whatever the tip is then.
if [ -n "$PINNED_SHA" ]; then
    printf '%s\n' "$BRANCH" > "$PIN_FILE.tmp.$$" && mv -f "$PIN_FILE.tmp.$$" "$PIN_FILE"
fi

COMMIT=$(git -C "$SRC_DIR" rev-parse --short HEAD)
SUBJECT=$(git -C "$SRC_DIR" log -1 --pretty=%s)

# --- hand over --------------------------------------------------------------------
#
# THE DEPLOYED REF'S OWN deploy.sh DOES THE REST OF THE DEPLOY.
#
# This script runs from the OPS clone (/opt/misc/fivem-br-gamemode), which
# nothing pulls but a person, while the tree it deploys is fetched fresh above.
# The two drift, and a drifted deploy says nothing: dev's 30cbfcd added
# cuchi_computer (#396) to VENDORED_RESOURCES, the dev box served that commit,
# and the ops clone's older list never synced it. #391's asset pull needed the
# same hand pull of the ops clone before it.
#
# So when the served tree's tools/deploy.sh is a different version from this
# one (compared as git blobs, so no checkout's line endings count), this run
# hands over to it HERE: the clone is at the target sha and nothing has been
# synced, so everything from the payload check on is that version's to do.
#
#   * TO A PRIVATE COPY, never to the file in the served clone. bash reads a
#     script while it runs it, and every deploy resets and cleans that clone,
#     the handed-over one included. The copy is the blob from git, hashed again
#     once written, in a mktemp directory outside the clone, and it removes
#     itself on exit (an EXIT trap: a die and a SIGTERM run it, a SIGKILL not).
#   * WITH THE SAME ARGUMENTS AND ENVIRONMENT, plus the ref and the sha this run
#     resolved and checked (BR_DEPLOY_HANDOVER_*). The copy takes those as
#     given: it resolves no ref and fetches nothing, so it deploys this sha.
#   * ONCE. A handed-over run never hands over again, whatever it finds, so two
#     versions that disagree about each other cannot loop.
#   * ONLY TO A deploy.sh THAT TAKES IT (the HANDOVER_PROTOCOL line). An older
#     one would ignore the pinned sha and fetch again, so a ref from before the
#     handover is deployed by this script, as every ref was before it.
#
# --dry-run HANDS OVER TOO, because a dry run should show what the deploy would
# do, and that is the new version's sync: a dry run by this script would show
# none of what the new version adds. It is as inert as a dry run already is:
# the copy fetches nothing, resets to the sha this run already reset to, runs
# its own --dry-run, and removes itself. --status does not run the other
# version at all; it says a deploy would hand over, and to what.
#
# When there is no handing over (no tools/deploy.sh in the tree, the copy
# failed, a deploy.sh that does not take it, a run already handed over once),
# this script carries on and says why -- and if it is an OLDER version of the
# served one (its blob is in that file's history), the red box asks for the pull
# of the ops clone that is still the fix then.

SELF_SCRIPT="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
SERVED_BLOB="$(git -C "$SRC_DIR" rev-parse -q --verify "$REMOTE:tools/deploy.sh" 2>/dev/null || true)"
SELF_BLOB="$(git -C "$SRC_DIR" hash-object --stdin < "$SELF_SCRIPT" 2>/dev/null || true)"

# #391's warning, for a run that carries on although the served tree's
# deploy.sh differs. Loud only when this script is an older version of it.
older_than_served() {
    local ops_clone ops_on="" ops_pull blobs
    # Every version tools/deploy.sh has had on the served ref, one blob a line.
    # Into a variable, not `| grep -q`: under pipefail an early grep exit can
    # fail the pipeline with SIGPIPE and read as "not found".
    blobs="$(git -C "$SRC_DIR" log --format= --raw --no-abbrev "$REMOTE" -- tools/deploy.sh \
        | awk '{ print $4 }' || true)"
    [ -n "$SELF_BLOB" ] || return 0
    case $'\n'"$blobs"$'\n' in
        *$'\n'"$SELF_BLOB"$'\n'*) ;;
        *) return 0 ;;
    esac
    ops_clone="$(git -C "$(dirname "$SELF_SCRIPT")" rev-parse --show-toplevel 2>/dev/null || true)"
    if [ -n "$ops_clone" ]; then
        ops_pull="git -C $ops_clone pull"
        # A pull brings only its own branch's deploy.sh: one tracking main
        # catches up with dev's only after the dev->main merge.
        ops_on="$(git -C "$ops_clone" symbolic-ref -q --short HEAD 2>/dev/null || echo 'a detached HEAD')"
    else
        ops_pull="replace $SELF_SCRIPT with $BRANCH's tools/deploy.sh"
    fi
    {
        echo "${RED}================================================================${RST}"
        echo "${RED}deploy: THIS deploy.sh IS OLDER THAN $BRANCH's tools/deploy.sh${RST}"
        echo "${RED}  running: $SELF_SCRIPT${RST}"
        echo "${RED}  Pull the ops clone, then deploy again:  $ops_pull${RST}"
        if [ -n "$ops_on" ]; then
            echo "${RED}  (it is on $ops_on; the pull helps once that branch has $BRANCH's deploy.sh)${RST}"
        fi
        echo "${RED}  Until then each deploy runs the old script's steps, and leaves${RST}"
        echo "${RED}  out whatever the new one added.${RST}"
        echo "${RED}================================================================${RST}"
    } >&2
}

# The private copy: sets HANDOVER_COPY, or sets HANDOVER_FAIL and returns
# non-zero with nothing left behind.
HANDOVER_COPY=""
HANDOVER_FAIL=""
handover_copy() {
    local tmp="${TMPDIR:-/tmp}" dir
    dir="$(mktemp -d "$tmp/br-deploy-handover.XXXXXXXX" 2>/dev/null)" \
        || { HANDOVER_FAIL="no private directory could be made in $tmp"; return 1; }
    case "$(cd "$dir" && pwd -P)/" in
        "$(cd "$SRC_DIR" && pwd -P)/"*)
            rmdir "$dir" 2>/dev/null
            HANDOVER_FAIL="the temp directory $dir is inside the served clone"
            return 1 ;;
    esac
    if git -C "$SRC_DIR" cat-file blob "$SERVED_BLOB" > "$dir/deploy.sh" 2>/dev/null \
        && [ "$(git -C "$SRC_DIR" hash-object --stdin < "$dir/deploy.sh" 2>/dev/null)" = "$SERVED_BLOB" ]; then
        HANDOVER_COPY="$dir/deploy.sh"
        return 0
    fi
    rm -f "$dir/deploy.sh"
    rmdir "$dir" 2>/dev/null
    HANDOVER_FAIL="the copy in $dir did not come out as $BRANCH's tools/deploy.sh"
    return 1
}

STATUS_DEPLOY_SH="the same as $BRANCH's"
if [ -z "$SERVED_BLOB" ]; then
    STATUS_DEPLOY_SH="this one; $BRANCH has none"
    echo "${YEL}deploy: note: $BRANCH has no tools/deploy.sh, so this one ($SELF_SCRIPT) deploys it${RST}" >&2
elif [ "$SELF_BLOB" != "$SERVED_BLOB" ]; then
    HANDOVER_DESC="from $SELF_SCRIPT (${SELF_BLOB:0:8}) to $BRANCH ${REMOTE:0:8}'s tools/deploy.sh (${SERVED_BLOB:0:8})"
    if [ -n "$HANDOVER_SHA" ]; then
        # THE GUARD. This run is the handed-over copy and still disagrees with
        # the tree it was handed: it deploys, and nothing hands over twice.
        echo "${YEL}deploy: note: already handed over once (from ${HANDOVER_FROM:-another deploy.sh}); this copy deploys although $BRANCH's tools/deploy.sh differs from it${RST}" >&2
    elif ! git -C "$SRC_DIR" grep -q -E -e "^HANDOVER_PROTOCOL=$HANDOVER_PROTOCOL\$" "$REMOTE" -- tools/deploy.sh; then
        STATUS_DEPLOY_SH="this one; $BRANCH's differs and does not take a handover"
        echo "${YEL}deploy: note: $BRANCH's tools/deploy.sh differs from this one ($SELF_SCRIPT) and does not take a handover, so this one deploys it${RST}" >&2
        older_than_served
    elif [ "$STATUS_ONLY" -eq 1 ]; then
        STATUS_DEPLOY_SH="a deploy would hand over $HANDOVER_DESC"
    elif handover_copy; then
        say "${YEL}handing over${RST} $HANDOVER_DESC"
        export BR_DEPLOY_HANDOVER_SHA="$REMOTE" BR_DEPLOY_HANDOVER_REF="$BRANCH" \
               BR_DEPLOY_HANDOVER_FROM="$SELF_SCRIPT"
        exec "${BASH:-bash}" "$HANDOVER_COPY" "$@"
    else
        echo "${YEL}deploy: could not hand over to $BRANCH's tools/deploy.sh ($HANDOVER_FAIL); this one ($SELF_SCRIPT) deploys it${RST}" >&2
        older_than_served
    fi
fi

if [ "$STATUS_ONLY" -eq 1 ]; then
    echo
    echo "  source:   $SRC_DIR"
    echo "  branch:   $BRANCH"
    echo "  commit:   $COMMIT  $SUBJECT"
    echo "  deploy.sh: $STATUS_DEPLOY_SH"
    echo "  target:   $TARGET_DIR/$RESOURCE_GROUP"
    [ -d "$TARGET_DIR/$RESOURCE_GROUP" ] && echo "  deployed: yes" || echo "  deployed: no"
    for v in "${VENDORED_RESOURCES[@]}"; do
        echo "  vendored: $SERVER_ROOT/resources/$v"
        [ -d "$SERVER_ROOT/resources/$v" ] \
            && echo "            deployed: yes" || echo "            deployed: no"
    done
    if assets_wanted; then
        echo "  licensed: $LICENSED_DIR"
        if ! assets_tool_present; then
            echo "            $BRANCH $ASSETS_PREDATES_NOTE"
        elif assets_python_ok; then
            "$PYTHON" "$SRC_DIR/tools/assets.py" pull --dry-run --server-root "$SERVER_ROOT" 2>&1 \
                | sed 's/^/            /' \
                || echo "            (the plan could not be computed; a deploy would stop here)"
        else
            echo "            ($PYTHON is not installed; a deploy would stop here)"
        fi
    else
        echo "  licensed: none (assets.lock lists nothing)"
    fi
    exit 0
fi

# --- validate before touching the live server --------------------------------

SRC_GROUP="$SRC_DIR/resources/$RESOURCE_GROUP"
check_payload "$SRC_GROUP"

# Vendored resources get the one structural check that matters for them: a
# resource without a manifest is a directory FiveM will not load, and its
# presence means a half-finished sync or a branch that predates the vendoring.
# Deliberately NOT check_payload -- that function is about OUR payload (br_lib,
# br_core, br_ui, the built bundle) and none of it is true of third-party code.
for v in "${VENDORED_RESOURCES[@]}"; do
    [ -d "$SRC_DIR/resources/$v" ] \
        || die "vendored resource missing from the payload: resources/$v
  Either this branch predates the vendoring, or the sync is half finished.
  Nothing has been copied to the live server."
    [ -f "$SRC_DIR/resources/$v/fxmanifest.lua" ] \
        || die "vendored resource has no fxmanifest.lua: resources/$v
  FiveM will not load it."
done

# --- licensed assets, part 1 of 2: stage (#391) --------------------------------
#
# TWO HALVES WITH THE CODE SYNC BETWEEN THEM, so new assets never sit under old
# code. `pull --stage` here does everything that can fail for a reason outside
# this box -- download, sha256 check, unpack into the cache's staging dir --
# and changes NOTHING installed. A failure dies here: the code and the
# licensed assets are both as they were, in step, and the server is never
# restarted (`die` exits non-zero, so neither the chained start nor
# royale-deploy.service's restart runs).
#
# `pull --swap`, after the code and vendored syncs have succeeded and just
# before the served-commit stamp, renames the staged set into
# resources/[licensed]/. It is journaled and undoes itself on failure.
#
# On --dry-run (and --status) it prints the plan and downloads and changes
# nothing.
ASSETS_STAGED=0
if assets_wanted; then
    if ! assets_tool_present; then
        echo "${YEL}deploy: $BRANCH $ASSETS_PREDATES_NOTE${RST}" >&2
    else
        assets_python_ok || die "$PYTHON is not installed, and assets.lock lists licensed assets.
  Nothing has been deployed.  sudo apt install -y python3"
        say "licensed assets: assets.lock -> $LICENSED_DIR/"
        if [ "$DRY_RUN" -eq 1 ]; then
            "$PYTHON" "$SRC_DIR/tools/assets.py" pull --dry-run --server-root "$SERVER_ROOT" 2>&1 \
                | sed 's/^/     /' || die "the licensed asset plan failed (above)."
        else
            "$PYTHON" "$SRC_DIR/tools/assets.py" pull --stage --server-root "$SERVER_ROOT" 2>&1 \
                | sed 's/^/     /' || die "the licensed asset pull failed (above) -- nothing has been deployed.
  The code and the licensed assets on this box are both as they were, and the
  server has not been restarted. assets.lock in the branch decides what a pull
  installs: fix the lock or the bucket, then deploy again."
            ASSETS_STAGED=1
        fi
    fi
fi

# --- sync --------------------------------------------------------------------

mkdir -p "$TARGET_DIR"

RSYNC_OPTS=(-a --delete --human-readable --itemize-changes)
[ "$DRY_RUN" -eq 1 ] && RSYNC_OPTS+=(--dry-run)

# Trailing slash on the source and none on the destination: sync the CONTENTS of
# the group into a directory of the same name. --delete is scoped to that one
# directory, so anything else in [gamemodes] is untouched.
#
# THE DEV PROPS SAVE IS EXCLUDED, and an exclude is what keeps it: rsync's
# --delete never removes an excluded file on the receiver. `/brprop save` (#384)
# writes it into br_core on the box itself and it is in no checkout, so without
# this every push to dev would wipe the owner's saved placements. The name is
# BR.Config.Props.saveFile; tools/test_props.lua fails if the two disagree.
say "syncing $RESOURCE_GROUP -> $TARGET_DIR/"
rsync "${RSYNC_OPTS[@]}" \
    --exclude '.git' \
    --exclude '*.md' \
    --exclude 'br_core/devprops.json' \
    "$SRC_GROUP/" "$TARGET_DIR/$RESOURCE_GROUP/" \
    | sed 's/^/     /' || die "rsync failed"

# Vendored third-party resources, one rsync each.
#
# NOT UNDER $TARGET_DIR. These live directly under $SERVER_ROOT/resources/, in
# the group the operator already installed them into, because the whole point is
# to REPLACE the existing copy rather than create a second resource with the
# same name somewhere else.
#
# --delete IS SCOPED TO THE RESOURCE DIRECTORY ITSELF -- source and destination
# both end in the resource name with a trailing slash -- so it can remove a file
# upstream dropped between versions and cannot touch a sibling resource in the
# same group. See VENDORED_RESOURCES near the top for why the list is per
# resource rather than per group.
for v in "${VENDORED_RESOURCES[@]}"; do
    vdst="$SERVER_ROOT/resources/$v"

    # A leftover .git means this path used to be a clone, from back when the
    # operator installed the resource by hand. rsync --delete does NOT remove
    # excluded files, so the clone's .git survives every deploy while the files
    # around it become ours: a directory that reports one version to `git
    # describe` and runs another. Said out loud rather than deleted from under
    # somebody, and rather than refusing to deploy over it.
    if [ -d "$vdst/.git" ]; then
        echo "${YEL}  NOTE: $vdst/.git exists.${RST}"
        echo "${YEL}  This path was a hand-installed clone. Its files are being replaced by the${RST}"
        echo "${YEL}  vendored copy, but the stale .git is left behind and will misreport the${RST}"
        echo "${YEL}  version. Remove it:  rm -rf '$vdst/.git'${RST}"
    fi

    # NOT ON A DRY RUN. --dry-run is in RSYNC_OPTS already, so the sync itself
    # is inert -- but this mkdir is not rsync, and on a box that has never had
    # the vendored resource it would create the directory tree for real while
    # the operator was being told nothing was changed.
    [ "$DRY_RUN" -eq 1 ] || mkdir -p "$vdst"
    say "syncing $v -> $SERVER_ROOT/resources/"
    rsync "${RSYNC_OPTS[@]}" \
        --exclude '.git' \
        --exclude '*.md' \
        "$SRC_DIR/resources/$v/" "$vdst/" \
        | sed 's/^/     /' || die "rsync failed for vendored resource $v"
done

if [ "$DRY_RUN" -eq 1 ]; then
    echo
    echo "${YEL}dry run -- nothing was changed${RST}"
    exit 0
fi

# --- licensed assets, part 2 of 2: swap (#391) ---------------------------------
#
# The code and every vendored resource are synced, so the staged set goes in
# now and the two land together. A swap that fails is undone by assets.py --
# [licensed] goes back to exactly what it held -- and the deploy dies here, so
# nothing restarts. If the undo fails too, assets.py says where every old
# resource is and deletes nothing.
if [ "$ASSETS_STAGED" -eq 1 ]; then
    "$PYTHON" "$SRC_DIR/tools/assets.py" pull --swap --server-root "$SERVER_ROOT" 2>&1 \
        | sed 's/^/     /' || die "the licensed asset swap failed (above), and the server has not been restarted.
  The code is synced, and resources/$LICENSED_GROUP/ holds what it held before
  this deploy unless the lines above say otherwise. A restart now would run the
  new code with the old licensed assets: fix what stopped the swap and deploy
  again instead."
fi

# THE SERVED COMMIT, for the dev-mode hex under the lobby's Settings button.
#
# The game server cannot read $SRC_DIR/.git: FXServer's Lua sandbox refuses io on
# any path in the server root outside a resource folder. So the sha goes INSIDE a
# resource, where br_core reads it with LoadResourceFile (br_lib/shared/gitref.lua).
#
# AFTER EVERY SYNC AND THE SWAP, AND THAT IS THE ORDER THAT KEEPS IT HONEST. The
# stamp is not in the source, so the --delete above removes it on every deploy (a
# dry run lists that as `*deleting`); a deploy that dies before this line leaves
# no stamp rather than the previous commit's. Never on a dry run, which exited
# above.
STAMP="$TARGET_DIR/$RESOURCE_GROUP/br_core/served-commit"
git -C "$SRC_DIR" rev-parse HEAD > "$STAMP.tmp.$$" && mv -f "$STAMP.tmp.$$" "$STAMP" \
    || die "could not write $STAMP"

# --- done --------------------------------------------------------------------

echo
echo "${GRN}deployed${RST} $BRANCH  $COMMIT  $SUBJECT"
if [ "$BRANCH" != "main" ]; then
    # Said here as well as in the console, because the person reading a deploy
    # log at 3am is not necessarily the person who pressed the button.
    echo "${YEL}  NOT ON main.${RST} This box is parked on '$BRANCH'."
    echo "${YEL}  Every later deploy refreshes that branch until somebody switches back.${RST}"
fi
echo "  -> $TARGET_DIR/$RESOURCE_GROUP"
for v in "${VENDORED_RESOURCES[@]}"; do
    echo "  -> $SERVER_ROOT/resources/$v  ${DIM}(vendored)${RST}"
done
if [ "$ASSETS_STAGED" -eq 1 ]; then
    echo "  -> $LICENSED_DIR  ${DIM}(licensed, from assets.lock; they load on a full restart)${RST}"
fi
echo
echo "The server does not pick this up on its own while running. Either restart"
echo "it, or from the server console:"
echo "     refresh"
echo "     restart br_lib; restart br_core; restart br_ui; restart br_stats; restart br_ringmaster"
for v in "${VENDORED_RESOURCES[@]}"; do
    # basename, because a FiveM resource is named by its directory and the
    # group it sits in is not part of that name.
    echo "     restart $(basename "$v")"
done
echo
echo "${DIM}Note: resources/$TARGET_CATEGORY is a FiveM category folder. If this is a"
echo "new install, make sure server.cfg still ensures br_lib, br_core, br_ui and"
echo "br_stats -- moving a resource between categories does not change its name,"
echo "so existing ensure lines keep working.${RST}"
