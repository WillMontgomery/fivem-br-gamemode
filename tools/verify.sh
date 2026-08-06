#!/usr/bin/env bash
#
# FiveM Royale verification gate.
#
#   ./tools/verify.sh
#
# Runs three checks, in increasing order of strictness:
#
#   1. SYNTAX  -- luac -p on every .lua file. FiveM runs Lua 5.4, and so does
#                 this check, so a pass here means the resource will at least
#                 load. This is the floor, not the ceiling.
#
#   2. TESTS   -- unit tests for the pure shared modules (rng, geo, storm_solve).
#                 These have no FiveM dependencies, so they can and should be
#                 tested outside the game.
#
#   3. SCOPE   -- the ban on scope-poisoned natives in br_core/client. Under
#                 OneSync big mode, GetActivePlayers and GetPlayerFromServerId
#                 only see players in scope. They work perfectly with four
#                 players stood together and disintegrate at 48 spread across the
#                 map, producing symptoms that look like logic bugs and are
#                 actually architecture bugs. Enforcing it mechanically beats
#                 relying on discipline.
#
# Exit code is non-zero if any check fails.

set -uo pipefail
cd "$(dirname "$0")/.."

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; DIM=$'\033[2m'; RST=$'\033[0m'
rc=0

# --- locate luac -------------------------------------------------------------

find_luac() {
    if command -v luac >/dev/null 2>&1; then command -v luac; return; fi
    for c in \
        "$LOCALAPPDATA/Programs/Lua/bin/luac.exe" \
        "$HOME/AppData/Local/Programs/Lua/bin/luac.exe" \
        "/c/Program Files/Lua/bin/luac.exe" \
        "/c/Program Files (x86)/Lua/bin/luac.exe"
    do
        [ -x "$c" ] && { echo "$c"; return; }
    done
}

LUAC="$(find_luac)"
if [ -z "${LUAC:-}" ]; then
    echo "${RED}luac not found.${RST}"
    echo "Install Lua 5.4 (matching FiveM's runtime):  winget install --id DEVCOM.Lua -e"
    exit 127
fi
LUA="${LUAC%luac.exe}lua.exe"
[ -x "$LUA" ] || LUA="$(command -v lua || true)"

# --- 1. syntax ---------------------------------------------------------------

echo "${DIM}== syntax ==${RST}"
n=0; bad=0
while IFS= read -r f; do
    n=$((n+1))
    if ! out=$("$LUAC" -p "$f" 2>&1); then
        echo "${RED}FAIL${RST} $f"
        echo "     $out"
        bad=$((bad+1))
    fi
done < <(find resources -name '*.lua' 2>/dev/null | sort)

if [ "$bad" -eq 0 ]; then
    echo "${GRN}ok${RST}   $n files parsed"
else
    echo "${RED}$bad of $n files failed to parse${RST}"
    rc=1
fi

# --- 2. unit tests -----------------------------------------------------------

echo "${DIM}== tests ==${RST}"
if [ -x "$LUA" ] || command -v "$LUA" >/dev/null 2>&1; then
    for suite in tools/test_shared.lua tools/test_loop.lua tools/test_sched.lua tools/test_roster.lua tools/test_stats.lua; do
        [ -f "$suite" ] || continue
        printf '%s' "${DIM}$(basename "$suite" .lua): ${RST}"
        "$LUA" "$suite" || rc=1
    done
else
    echo "${YEL}skip${RST} (lua interpreter not found)"
fi

# --- 3. scope gate -----------------------------------------------------------

echo "${DIM}== scope gate ==${RST}"
BANNED='GetActivePlayers|GetPlayerFromServerId|GetPlayerPed\('

# Exceptions are marked per line, not per file. A whole-file allowlist rots --
# the exempted file grows and quietly becomes a permanent hole. Requiring the
# marker on the line keeps each use deliberate and greppable:
#
#     local ply = GetPlayerFromServerId(src)  -- scope-ok: <why>
#
# There is one legitimate category: resolving a ped handle for the spectator
# camera, after the server has supplied coordinates and the client has moved
# into range. Anything else is deriving game state from scope, which works with
# four players huddled together and fails at 48 spread across the map.
hits=$(grep -rnE "$BANNED" resources/*/br_core/client/ 2>/dev/null | grep -v 'scope-ok' || true)
if [ -n "$hits" ]; then
    echo "${RED}FAIL${RST} scope-poisoned natives in br_core/client:"
    echo "$hits" | sed 's/^/     /'
    echo
    echo "     These only see players currently in scope. Route roster facts"
    echo "     through the server broadcast (br_core/server/roster.lua) instead."
    echo "     If this really is the spectator-camera case, mark the line:"
    echo "         -- scope-ok: <reason>"
    rc=1
else
    marked=$(grep -rcE 'scope-ok' resources/*/br_core/client/ 2>/dev/null | grep -v ':0$' | wc -l | tr -d ' ')
    echo "${GRN}ok${RST}   no unmarked scope-poisoned natives (${marked} file(s) with marked exceptions)"
fi

# --- 3b. forward-local gate ----------------------------------------------------
#
# A `local function f` called from ABOVE its own declaration resolves as a
# GLOBAL, which is nil. No syntax error, luac -p is happy, and the unit tests
# never reach it because these are client files. In the game the call throws,
# the loop registry suspends that callback after five errors, and a whole
# subsystem goes silent behind one console line.
#
# This has cost two playtest rounds -- most recently BR.Loot's ground probe,
# which took every crate on the map with it.

echo "${DIM}== forward locals ==${RST}"
if [ -n "${LUA:-}" ] && [ -x "$LUA" ]; then
    # shellcheck disable=SC2046
    "$LUA" tools/check_forward_locals.lua $(find resources -name '*.lua' | sort) || rc=1
else
    echo "${YEL}skip${RST} (lua interpreter not found)"
fi

# --- 4. manifest coverage -----------------------------------------------------
#
# Every .lua under a resource must be declared in its fxmanifest, or it simply
# never loads.
#
# This gate exists because client/screen.lua was written, committed and deployed
# without ever being added to client_scripts. Nothing errored. The HUD just
# quietly used its CSS fallbacks instead of the game's real safe zone, and the
# only visible symptom was "1 callbacks registered" where it should have said 2.
# A file that is never loaded produces no error to grep for.

echo "${DIM}== manifest coverage ==${RST}"
missing_total=0

while IFS= read -r manifest; do
    resdir="$(dirname "$manifest")"

    # Declared entries: any quoted *.lua in the manifest. '@other_resource/...'
    # references point outside this resource, so they are not coverage for it.
    declared=$(grep -oE "'[^']+\.lua'" "$manifest" | tr -d "'" | grep -v '^@' || true)

    while IFS= read -r f; do
        rel="${f#"$resdir"/}"
        [ "$rel" = "fxmanifest.lua" ] && continue

        covered=0
        while IFS= read -r pat; do
            [ -z "$pat" ] && continue
            # Glob match, so `shared/*.lua` covers shared/enums.lua
            # shellcheck disable=SC2053
            if [[ "$rel" == $pat ]]; then covered=1; break; fi
        done <<< "$declared"

        if [ "$covered" -eq 0 ]; then
            echo "${RED}FAIL${RST} ${resdir#resources/}/$rel is not declared in fxmanifest.lua"
            missing_total=$((missing_total+1))
        fi
    done < <(find "$resdir" -name '*.lua' | sort)
done < <(find resources -name 'fxmanifest.lua' | sort)

if [ "$missing_total" -eq 0 ]; then
    echo "${GRN}ok${RST}   every .lua is declared in its manifest"
else
    echo "     A file absent from the manifest never loads, and never errors."
    rc=1
fi

# --- result ------------------------------------------------------------------

echo
if [ "$rc" -eq 0 ]; then
    echo "${GRN}PASS${RST}"
else
    echo "${RED}FAIL${RST}"
fi
exit $rc
