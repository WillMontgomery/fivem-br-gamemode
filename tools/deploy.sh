#!/usr/bin/env bash
#
# FiveM Royale -- deploy script. RUNS ON THE SERVER.
#
#   ./deploy.sh              fetch latest and sync into place
#   ./deploy.sh --dry-run    show what would change, touch nothing
#   ./deploy.sh --status     show local vs remote without deploying
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
BRANCH="${BR_BRANCH:-main}"

SERVER_ROOT="${BR_SERVER_ROOT:-/opt/fivem-server-classic}"
TARGET_CATEGORY="${BR_TARGET_CATEGORY:-[gamemodes]}"

# Where the working clone lives. Deliberately NOT inside resources/: FiveM would
# scan the .git directory on every refresh, and the repo contains files (ui-src,
# tools, docs) that have no business being served to clients.
SRC_DIR="${BR_SRC_DIR:-$SERVER_ROOT/.gamemode-src}"

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
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
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

check_payload() {
    local group="$1"

    [ -d "$group" ] || die "expected $group -- wrong branch, or the layout moved"

    local f
    for f in \
        "$group/br_lib/fxmanifest.lua" \
        "$group/br_core/fxmanifest.lua" \
        "$group/br_ui/fxmanifest.lua" \
        "$group/br_ui/ui/index.html" \
        "$group/br_ringmaster/fxmanifest.lua"
    do
        [ -f "$f" ] || die "missing from the payload: $f
  If it is the ui/ bundle, someone committed UI source without rebuilding.
  On a dev machine:  cd ui-src && npm run build && git add ../resources && git commit"
    done

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

# --- preflight ---------------------------------------------------------------

command -v git   >/dev/null || die "git is not installed:  sudo apt install -y git"
command -v rsync >/dev/null || die "rsync is not installed:  sudo apt install -y rsync"

[ -d "$SERVER_ROOT" ] || die "server root not found: $SERVER_ROOT
  Set it explicitly:  BR_SERVER_ROOT=/path/to/server $0"

TARGET_DIR="$SERVER_ROOT/resources/$TARGET_CATEGORY"

# --- fetch -------------------------------------------------------------------

if [ ! -d "$SRC_DIR/.git" ]; then
    say "cloning $REPO"
    # A private repo needs credentials. SSH deploy key is the usual answer on a
    # headless box; if this fails, that is almost always why.
    git clone --branch "$BRANCH" "$REPO" "$SRC_DIR" \
        || die "clone failed.
  For a private repo, add a read-only deploy key:
    ssh-keygen -t ed25519 -C fivem-deploy -f ~/.ssh/fivem_deploy -N ''
    cat ~/.ssh/fivem_deploy.pub
  then add it under the repo's Settings > Deploy keys, and in ~/.ssh/config:
    Host github.com
      IdentityFile ~/.ssh/fivem_deploy"
else
    say "fetching $BRANCH"
    git -C "$SRC_DIR" remote set-url origin "$REPO"
    git -C "$SRC_DIR" fetch --quiet origin "$BRANCH"

    LOCAL=$(git -C "$SRC_DIR" rev-parse HEAD)
    REMOTE=$(git -C "$SRC_DIR" rev-parse "origin/$BRANCH")

    if [ "$LOCAL" = "$REMOTE" ]; then
        say "already up to date at ${LOCAL:0:8}"
    else
        say "updating ${LOCAL:0:8} -> ${REMOTE:0:8}"
        git -C "$SRC_DIR" log --oneline "$LOCAL..$REMOTE" | sed 's/^/     /'
    fi

    # Hard reset rather than pull. The server clone is a deployment artifact,
    # not a workspace -- if someone edited a file in place, their change is not
    # in git and must not block a deploy or produce a merge conflict at boot.
    git -C "$SRC_DIR" reset --quiet --hard "origin/$BRANCH"
    git -C "$SRC_DIR" clean --quiet -fd
fi

COMMIT=$(git -C "$SRC_DIR" rev-parse --short HEAD)
SUBJECT=$(git -C "$SRC_DIR" log -1 --pretty=%s)

if [ "$STATUS_ONLY" -eq 1 ]; then
    echo
    echo "  source:   $SRC_DIR"
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
echo "${GRN}deployed${RST} $COMMIT  $SUBJECT"
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
