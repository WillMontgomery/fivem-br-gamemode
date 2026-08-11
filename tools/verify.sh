#!/usr/bin/env bash
#
# FiveM Royale verification gate.
#
#   ./tools/verify.sh
#
# Runs a series of checks, roughly in increasing order of strictness:
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
#   3b/3c/3d   -- weapon table, POI siting, and forward-declared locals.
#
#   4. MANIFEST -- every .lua is declared somewhere, so nothing loads silently
#                 into nothing.
#
#   5. SECRETS -- nothing credential-shaped reaches a public repo. THE ONLY
#                 GATE THAT SCANS THE WHOLE REPO rather than resources/.
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
    for suite in tools/test_shared.lua tools/test_loop.lua tools/test_sched.lua tools/test_roster.lua tools/test_stats.lua tools/test_ringmaster.lua; do
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

echo "${DIM}== weapon table ==${RST}"
if [ -n "${LUA:-}" ] && [ -x "$LUA" ]; then
    "$LUA" tools/check_weapons.lua || rc=1
else
    echo "${YEL}skip${RST} (lua interpreter not found)"
fi

echo "${DIM}== POI siting ==${RST}"
if [ -n "${LUA:-}" ] && [ -x "$LUA" ]; then
    "$LUA" tools/check_pois.lua || rc=1
else
    echo "${YEL}skip${RST} (lua interpreter not found)"
fi

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

# --- 4b. shared-module coverage ------------------------------------------------
#
# Gate 4 above proves every .lua under a resource is DECLARED in that resource's
# manifest. It cannot prove a br_lib module is CONSUMED by anybody, and for
# br_lib specifically it is structurally incapable of it: br_lib's manifest says
# `files { 'shared/*.lua', 'config/*.lua' }`, and a glob satisfies coverage for
# anything dropped in the directory. So br_lib always passes gate 4, whatever is
# in it.
#
# That is not theoretical. outbox.lua and identity.lua were both written,
# reviewed, unit-tested and committed -- and declared in no consuming manifest,
# so at runtime they loaded into no Lua state at all. Two finished modules sat
# dead behind a green build. Only the unit tests ever saw them, because the
# tests loadfile() them directly and never ask FiveM anything.

echo "${DIM}== shared coverage ==${RST}"
orphans=0
consumers=$(find resources -name 'fxmanifest.lua' -not -path '*/br_lib/*' | sort)

for mod in resources/*/br_lib/shared/*.lua resources/*/br_lib/config/*.lua; do
    [ -e "$mod" ] || continue
    rel="${mod#*/br_lib/}"

    if ! grep -qF -- "@br_lib/$rel" $consumers 2>/dev/null; then
        echo "${RED}FAIL${RST} br_lib/$rel is in no resource's script list"
        orphans=$((orphans+1))
    fi
done

if [ "$orphans" -eq 0 ]; then
    echo "${GRN}ok${RST}   every br_lib module is pulled in by at least one resource"
else
    echo
    echo "     A shared module nobody declares is loaded into no Lua state. It"
    echo "     passes every other gate, including its own unit tests, because"
    echo "     those loadfile() it directly. Add it to a consuming resource's"
    echo "     shared_scripts/server_scripts, or delete it."
    rc=1
fi

# --- 4c. deploy payload --------------------------------------------------------
#
# Runs deploy.sh's own preflight against this checkout. Not a re-implementation
# of it -- literally the same function, called with --check-payload, so the two
# cannot drift.
#
# This gate exists because deploy.sh's payload check shipped broken and nobody
# found out until it ran on the server for the first time and refused to deploy.
# It reported "no JS bundle in br_ui/ui/assets" about a bundle that was sitting
# right there: the check used `compgen -G` on a path containing
# [fivem-royale], which `compgen` reads as a glob character class rather than a
# directory name.
#
# Deploy scripts are the classic place for this. They are only exercised in
# production, so a bug in one is found by production. Running the payload half
# here -- where it needs no server, no clone and no network -- moves that
# discovery to a red build.

echo "${DIM}== deploy payload ==${RST}"
bash tools/deploy.sh --check-payload "resources/[fivem-royale]" || rc=1

# --- 4d. slice-1 read-only boundary -------------------------------------------
#
# M9 Slice 1 is "see the server", and its exit gate is a promise: NO code path
# by which the admin console can change a running match. A promise in a plan
# file is not a gate, so this makes it mechanical. When Slice 2 deliberately
# opens the write path, this gate is what gets consciously updated to allow it,
# which is the point: the boundary moves on purpose, never by accident.

echo "${DIM}== slice-1 boundary ==${RST}"
boundary=0

# dispatch.sh: the SSH verb surface. Exactly `status` and `telemetry` reach a
# handler; a stop/restart/deploy verb would be Slice 4 process control.
if [ -f tools/dispatch.sh ]; then
    verbs=$(grep -oE '^\s+(status|telemetry|stop|restart|deploy|reload|config|kick|ban)\)' tools/dispatch.sh \
            | tr -d ' )' | sort -u | tr '\n' ' ')
    if [ "$verbs" != "status telemetry " ]; then
        echo "${RED}FAIL${RST} dispatch.sh verb set is '${verbs}', expected 'status telemetry '"
        echo "     A new verb is a new capability from the console to the host. If"
        echo "     it is a Slice 2+ write verb, update THIS gate on purpose."
        boundary=1
    fi
fi

# br_ringmaster: must not act on the game. No DropPlayer, and no RegisterCommand
# beyond its own read-only debug dump.
rmdir_="resources/*/br_ringmaster"
if compgen -G "$rmdir_" >/dev/null 2>&1; then
    # `DropPlayer(` is a CALL; skip Lua comment lines so the header's own "no
    # DropPlayer" note does not trip its own gate.
    if grep -rnE 'DropPlayer\(' $rmdir_ 2>/dev/null | grep -qvE '^[^:]+:[0-9]+:[[:space:]]*--'; then
        echo "${RED}FAIL${RST} br_ringmaster calls DropPlayer -- a kick, which is Slice 2"
        boundary=1
    fi
    cmds=$(grep -rhoE "RegisterCommand\('[a-z]+'" $rmdir_ 2>/dev/null \
           | grep -oE "'[a-z]+'" | tr -d "'" | sort -u | tr '\n' ' ')
    if [ -n "$cmds" ] && [ "$cmds" != "bridents brring " ]; then
        echo "${RED}FAIL${RST} br_ringmaster registers commands beyond its debug dump: ${cmds}"
        boundary=1
    fi
fi

if [ "$boundary" -eq 0 ]; then
    echo "${GRN}ok${RST}   the admin console has no write path into a running match"
else
    rc=1
fi

# --- 5. secrets ---------------------------------------------------------------
#
# The only gate here that scans the WHOLE repo rather than resources/. A
# credential leaks just as thoroughly from tools/, a doc, or server.cfg.example.
# See tools/check_secrets.sh for why it asks git what it would publish instead
# of walking the disk.

echo "${DIM}== secrets ==${RST}"
bash tools/check_secrets.sh || rc=1

# --- result ------------------------------------------------------------------

echo
if [ "$rc" -eq 0 ]; then
    echo "${GRN}PASS${RST}"
else
    echo "${RED}FAIL${RST}"
fi
exit $rc
