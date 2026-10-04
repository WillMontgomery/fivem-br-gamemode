#!/usr/bin/env bash
#
# Licensed-asset gate (#391).
#
#   ./tools/check_asset_files.sh                  every file git has or would add
#   ./tools/check_asset_files.sh --revs <revs>    what those commits add (tools/pre-push)
#
# This repository is PUBLIC, and the packs the boxes run -- the NTeam Legion
# map pack, the emote packs for #215 -- were bought under licenses that do not
# allow redistribution. They live in a private bucket and reach the boxes
# through tools/assets.py; assets.lock is the only trace of them here. One
# `git add -A` in a checkout that has a pack lying in it would publish the pack,
# and nothing else in this repository would notice: it is a folder of files the
# game reads and no gate parses.
#
# SO A GAME-ASSET FILE TYPE ANYWHERE IN THE REPO FAILS, unless it is on the
# allowlist below: the handful that are OURS, or vendored under a license that
# allows it. Adding a file of our own means adding its exact path there, which
# is the moment to ask whether it really is ours.
#
# ASKS GIT, LIKE tools/check_secrets.sh, rather than walking the disk:
# tracked files, plus untracked ones that are not ignored -- what a careless
# `git add -A` would sweep up. resources/[licensed]/ and .assets-cache/ are
# gitignored, so a checkout used as a local server with pulled assets passes.
#
# --revs IS THE PRE-PUSH FORM: the paths the given commits add or change, as
# `git log <revs>` walks them, so a pack added and deleted again inside one push
# is still caught -- it would still be in the history the push publishes. A
# push is not the whole tree, so the stale-row check below is skipped there.
#
# Pure bash after the one git call: on Windows every process costs real time.

set -uo pipefail
cd "$(dirname "$0")/.."

RED=$'\033[31m'; GRN=$'\033[32m'; RST=$'\033[0m'

# Exact paths, never patterns. Each one is ours or redistributable.
ALLOW=(
    # br_audio (#382): the airdrop Cargobob's rotor bank, built by
    # tools/build_audio.mjs from assets/audio/cargobob.ogg.
    "resources/[fivem-royale]/br_audio/br_sfx/br_cargobob.awc"
    "resources/[fivem-royale]/br_audio/data/br_airdrop_sounds.dat54.rel"
    # ScaleformUI_Assets, vendored under MIT (its LICENSE and VENDOR.json sit
    # beside these).
    "resources/[scaleformui]/ScaleformUI_Assets/files/MINIMAP_LOADER.gfx"
    "resources/[scaleformui]/ScaleformUI_Assets/stream/PauseMenuHeader.gfx"
    "resources/[scaleformui]/ScaleformUI_Assets/stream/RadialMenu.gfx"
    "resources/[scaleformui]/ScaleformUI_Assets/stream/RadioMenu.gfx"
    "resources/[scaleformui]/ScaleformUI_Assets/stream/ScaleformUI.gfx"
    "resources/[scaleformui]/ScaleformUI_Assets/stream/ScaleformUIPause.gfx"
)

# GTA V and FiveM asset formats -- streamed models, textures, maps, collisions,
# animations, navmeshes, audio, scaleform, archives -- and escrow (.fxap); the
# data files a pack ships beside them (.meta, .dat and .dat54-style audio data);
# and the archive formats a pack is downloaded in. Matched on the lower-cased
# name.
#
# .meta AND .dat COST NO ALLOWLIST ROWS: on 2026-10-04 the repo tracked no
# .meta at all, and its one .dat file (br_audio's .dat54.rel) is a row already.
#
# A COPY OF ONE IS STILL ONE: legion.ytd.bak, x.ymap.old, a.ydr~. After the
# asset extension the name may go on with a `.` or `~` and anything up to the
# end of the file name.
ASSET_EXT='ytd|ydr|ydd|yft|ymap|ytyp|ybn|ycd|ynv|ynd|ymt|ymf|ypt|yld|ysc|ypdb|yvr|ywr|yed|awc|rel|nametable|gfx|gxt2|mrf|cut|rpf|fxap|meta|dat[0-9]*|zip|rar|7z|tgz|gz|tar|xz|bz2|zst|zstd|lz4|txz|tbz2?'
ASSET_RE="\.($ASSET_EXT)([.~][^/]*)?\$"

allowed() {
    local a
    for a in "${ALLOW[@]}"; do
        [ "$a" = "$1" ] && return 0
    done
    return 1
}

MODE=tree
if [ "${1:-}" = "--revs" ]; then
    shift
    MODE=revs
    [ "$#" -gt 0 ] || { echo "${RED}FAIL${RST} --revs needs the commits to scan"; exit 1; }
    LIST=$(mktemp) || exit 1
    trap 'rm -f "$LIST"' EXIT
    # -m: a merge's own changes too. ACMRT: what a commit adds or changes.
    if ! git -c core.quotePath=false log -z -m --format= --name-only --no-renames \
            --diff-filter=ACMRT "$@" > "$LIST"; then
        echo "${RED}FAIL${RST} could not list the files in the commits being pushed"
        exit 1
    fi
fi

found=0
n=0
present='|'
reported='|'
while IFS= read -r -d '' f; do
    [ -n "$f" ] || continue
    n=$((n + 1))
    lower="${f,,}"
    [[ "$lower" =~ $ASSET_RE ]] || continue
    if allowed "$f"; then
        present="${present}${f}|"
        continue
    fi
    case "$reported" in *"|$f|"*) continue ;; esac
    reported="${reported}${f}|"
    echo "${RED}ASSET${RST} $f"
    found=$((found + 1))
done < <(if [ "$MODE" = revs ]; then cat "$LIST"; else git ls-files -z --cached --others --exclude-standard 2>/dev/null; fi)

if [ "$MODE" = revs ]; then
    if [ "$found" -gt 0 ]; then
        echo
        echo "${RED}$found game-asset file(s) in the commits being pushed, outside the allowlist.${RST}"
        echo "     This repo is public: pushing them publishes them, and a later commit"
        echo "     deleting them does not take them out of the history. Take them out"
        echo "     of these commits before pushing. A purchased pack goes to the"
        echo "     private bucket (py tools/assets.py push <folder>, or the drop folder)."
        exit 1
    fi
    echo "${GRN}ok${RST}   no game-asset files outside the allowlist in the $n path(s) the pushed commits add or change"
    exit 0
fi

if [ "$n" -eq 0 ]; then
    echo "${RED}FAIL${RST} no files to scan -- is this a git checkout?"
    exit 1
fi

# AND THE ALLOWLIST STAYS TRUE: a row whose file is gone describes nothing,
# and is a free pass for whatever lands at that path next.
stale=0
for a in "${ALLOW[@]}"; do
    case "$present" in
        *"|$a|"*) ;;
        *) echo "${RED}STALE${RST} allowlisted but not in the repo: $a"; stale=$((stale + 1)) ;;
    esac
done

if [ "$found" -gt 0 ] || [ "$stale" -gt 0 ]; then
    echo
    if [ "$found" -gt 0 ]; then
        echo "${RED}$found game-asset file(s) outside the allowlist.${RST}"
        echo "     This repo is public. A purchased pack goes to the private bucket:"
        echo "       py tools/assets.py push <folder>"
        echo "     If the file is genuinely ours, add its exact path to ALLOW in"
        echo "     tools/check_asset_files.sh."
    fi
    if [ "$stale" -gt 0 ]; then
        echo "     Remove the stale row(s) from ALLOW in tools/check_asset_files.sh."
    fi
    exit 1
fi

echo "${GRN}ok${RST}   no game-asset files outside the ${#ALLOW[@]}-file allowlist in $n scanned files"
