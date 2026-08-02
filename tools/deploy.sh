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
#   /opt/fivem-server-basic/deploy.sh && cd /opt/fivem-server-basic && ./run.sh +exec server.cfg
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

REPO="${BR_REPO:-git@github.com:WillMontgomery/fivem-br-gamemode.git}"
BRANCH="${BR_BRANCH:-main}"

SERVER_ROOT="${BR_SERVER_ROOT:-/opt/fivem-server-basic}"
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
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --status)  STATUS_ONLY=1 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "unknown option: $arg (try --help)"; exit 2 ;;
    esac
done

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; DIM=$'\033[2m'; RST=$'\033[0m'
die() { echo "${RED}deploy: $*${RST}" >&2; exit 1; }
say() { echo "${DIM}==${RST} $*"; }

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
#
# A half-deployed gamemode is worse than a stale one. Check the payload is
# complete BEFORE syncing, not after.

SRC_GROUP="$SRC_DIR/resources/$RESOURCE_GROUP"
[ -d "$SRC_GROUP" ] || die "expected $SRC_GROUP in the repo -- wrong branch, or the layout moved"

for f in \
    "$SRC_GROUP/br_lib/fxmanifest.lua" \
    "$SRC_GROUP/br_core/fxmanifest.lua" \
    "$SRC_GROUP/br_ui/fxmanifest.lua" \
    "$SRC_GROUP/br_ui/ui/index.html"
do
    [ -f "$f" ] || die "missing from the clone: ${f#$SRC_DIR/}
  If it is the ui/ bundle, someone committed UI source without rebuilding.
  On a dev machine:  cd ui-src && npm run build && git add ../resources && git commit"
done

# The UI bundle is the file most likely to be stale or absent, and its absence
# produces a server that starts cleanly and shows a blank screen.
if ! compgen -G "$SRC_GROUP/br_ui/ui/assets/*.js" >/dev/null; then
    die "no JS bundle in br_ui/ui/assets -- the UI would render blank"
fi

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
echo "     restart br_lib; restart br_core; restart br_ui; restart br_stats"
echo
echo "${DIM}Note: resources/$TARGET_CATEGORY is a FiveM category folder. If this is a"
echo "new install, make sure server.cfg still ensures br_lib, br_core, br_ui and"
echo "br_stats -- moving a resource between categories does not change its name,"
echo "so existing ensure lines keep working.${RST}"
