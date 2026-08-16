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
        -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
        *) echo "unknown option: $arg (try --help)"; exit 2 ;;
    esac
done
[ "$want_payload_dir" -eq 1 ] && { echo "--check-payload needs a directory"; exit 2; }

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; DIM=$'\033[2m'; RST=$'\033[0m'
die() { echo "${RED}deploy: $*${RST}" >&2; exit 1; }
say() { echo "${DIM}==${RST} $*"; }

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
if [ -n "$BRANCH" ]; then
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

if [ ! -d "$SRC_DIR/.git" ]; then
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

say "fetching $BRANCH"
git -C "$SRC_DIR" remote set-url origin "$REPO"
git -C "$SRC_DIR" fetch --quiet origin "$BRANCH" || die "origin has no branch called '$BRANCH'.
  It was probably deleted after the console pinned it. Nothing has been
  deployed and the server is still running what it was.
  To go back to main by hand:  echo main > $PIN_FILE"
# main as well, always, because the invariant below is measured against it and a
# stale origin/main would measure against a rule that has since changed.
[ "$BRANCH" = "main" ] || git -C "$SRC_DIR" fetch --quiet origin main \
    || die "cannot fetch origin/main, which the branch rule is measured against."

LOCAL=$(git -C "$SRC_DIR" rev-parse HEAD)
REMOTE=$(git -C "$SRC_DIR" rev-parse "origin/$BRANCH")

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
git -C "$SRC_DIR" reset --quiet --hard "origin/$BRANCH"
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

if [ "$STATUS_ONLY" -eq 1 ]; then
    echo
    echo "  source:   $SRC_DIR"
    echo "  branch:   $BRANCH"
    echo "  commit:   $COMMIT  $SUBJECT"
    echo "  target:   $TARGET_DIR/$RESOURCE_GROUP"
    [ -d "$TARGET_DIR/$RESOURCE_GROUP" ] && echo "  deployed: yes" || echo "  deployed: no"
    exit 0
fi

# --- validate before touching the live server --------------------------------

SRC_GROUP="$SRC_DIR/resources/$RESOURCE_GROUP"
check_payload "$SRC_GROUP"

# --- sync --------------------------------------------------------------------

mkdir -p "$TARGET_DIR"

RSYNC_OPTS=(-a --delete --human-readable --itemize-changes)
[ "$DRY_RUN" -eq 1 ] && RSYNC_OPTS+=(--dry-run)

# Trailing slash on the source and none on the destination: sync the CONTENTS of
# the group into a directory of the same name. --delete is scoped to that one
# directory, so anything else in [gamemodes] is untouched.
say "syncing $RESOURCE_GROUP -> $TARGET_DIR/"
rsync "${RSYNC_OPTS[@]}" \
    --exclude '.git' \
    --exclude '*.md' \
    "$SRC_GROUP/" "$TARGET_DIR/$RESOURCE_GROUP/" \
    | sed 's/^/     /' || die "rsync failed"

if [ "$DRY_RUN" -eq 1 ]; then
    echo
    echo "${YEL}dry run -- nothing was changed${RST}"
    exit 0
fi

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
echo
echo "The server does not pick this up on its own while running. Either restart"
echo "it, or from the server console:"
echo "     refresh"
echo "     restart br_lib; restart br_core; restart br_ui; restart br_stats; restart br_ringmaster"
echo
echo "${DIM}Note: resources/$TARGET_CATEGORY is a FiveM category folder. If this is a"
echo "new install, make sure server.cfg still ensures br_lib, br_core, br_ui and"
echo "br_stats -- moving a resource between categories does not change its name,"
echo "so existing ensure lines keep working.${RST}"
