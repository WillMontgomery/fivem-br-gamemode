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
    # test_client.lua is the odd one out and deliberately so: every other suite
    # here is server-side or pure arithmetic, and all three of the regressions
    # that shipped on 2026-08-16 landed on a CLIENT interaction that no gate
    # touched (#140). It stubs the FiveM natives and steps the frame band by
    # hand, the same shape test_roster.lua uses for the server.
    for suite in tools/test_shared.lua tools/test_loop.lua tools/test_sched.lua tools/test_roster.lua tools/test_stats.lua tools/test_ringmaster.lua tools/test_client.lua; do
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

echo "${DIM}== console capability boundary ==${RST}"
boundary=0

# THIS GATE MOVED IN SLICE 2, ON PURPOSE. It used to assert the console could
# not touch the game at all -- exactly two read verbs, no DropPlayer, no
# commands. The kick shipped, so that assertion is gone; what replaces it is the
# NEXT line, and the gate is only worth having if moving it stays deliberate.
#
# What is still forbidden, and what it would mean:
#
#   stop / restart            killing or bouncing the process directly. There is
#                             no reason to reach for these: `deploy` restarts
#                             FXServer through the unit that also syncs the
#                             code, which is the only restart anybody actually
#                             wants, and it is reached through a drained
#                             maintenance window rather than a button.
#   reload / config           live config editing. M6.
#
# `deploy` ARRIVED IN M6 AND IS THE HEAVIEST VERB HERE, because the restart ends
# every match in progress. It is fenced by the maintenance flow: scheduled,
# drained until the server is empty, then fired automatically. The single path
# that runs it with players online is an explicit force with its own
# confirmation and an audit row naming who chose it.

# `branches` AND `switchref` ARRIVED WITH BRANCH SWITCHING, and they are the
# reason gate 4e below exists. `branches` only reads refs. `switchref` writes
# one file naming the ref the next deploy should check out -- it starts nothing
# and restarts nothing, which is why the pair is nowhere near as heavy as
# `deploy` despite being the feature people will call dangerous.
#
# What makes them safe is not that they are small. It is the invariant in
# docs/branch-switch.md: a ref is only deployable if its tools/dispatch.sh is
# byte-identical to main's. Without that, `switchref` is a way to replace THIS
# FILE'S SUBJECT -- the console's only channel to the box -- with unreviewed
# code, because dispatch.sh is a tracked file inside the tree deploy.sh
# hard-resets.

# dispatch.sh: the SSH verb surface.
if [ -f tools/dispatch.sh ]; then
    verbs=$(grep -oE '^\s+(status|telemetry|stop|restart|deploy|reload|config|kick|ban|branches|switchref)\)' tools/dispatch.sh \
            | tr -d ' )' | sort -u | tr '\n' ' ')
    if [ "$verbs" != "branches deploy kick status switchref telemetry " ]; then
        echo "${RED}FAIL${RST} dispatch.sh verb set is '${verbs}', expected 'branches deploy kick status switchref telemetry '"
        echo "     A new verb is a new capability from the console to the host."
        echo "     Process control (stop/restart) is not a verb and never has been."
        echo "     If you are adding one on purpose, update THIS gate."
        boundary=1
    fi
fi

# br_ringmaster: the commands it registers ARE its surface, so the list is
# pinned. brkick is the kick; the other two are read-only dumps.
rmdir_="resources/*/br_ringmaster"
if compgen -G "$rmdir_" >/dev/null 2>&1; then
    cmds=$(grep -rhoE "RegisterCommand\('[a-z]+'" $rmdir_ 2>/dev/null \
           | grep -oE "'[a-z]+'" | tr -d "'" | sort -u | tr '\n' ' ')
    if [ -n "$cmds" ] && [ "$cmds" != "bridents brkick brring " ]; then
        echo "${RED}FAIL${RST} br_ringmaster registers '${cmds}', expected 'bridents brkick brring '"
        boundary=1
    fi

    # DropPlayer is now permitted -- but ONLY in the file that owns the kick.
    # Scoping it this way keeps the blast radius one reviewable file instead of
    # letting "the console can kick" quietly become "any file here can drop
    # anyone for any reason".
    stray=$(grep -rlE 'DropPlayer\(' $rmdir_ 2>/dev/null \
            | grep -v 'server/kick\.lua' || true)
    if [ -n "$stray" ]; then
        echo "${RED}FAIL${RST} DropPlayer outside br_ringmaster/server/kick.lua:"
        echo "$stray" | sed 's/^/     /'
        boundary=1
    fi
fi

if [ "$boundary" -eq 0 ]; then
    echo "${GRN}ok${RST}   the console can kick, ban, deploy and switch branch -- no raw stop/restart/config"
else
    rc=1
fi

# --- 4e. the branch-switch invariant ------------------------------------------
#
# THE ONE RULE BRANCH SWITCHING HANGS OFF, made mechanical.
#
#   A ref is only deployable if <sha>:tools/dispatch.sh exists, is mode 100755,
#   and its blob id equals origin/main:tools/dispatch.sh's blob id.
#
# Why it has to exist at all: authorized_keys pins Ringmaster's SSH key to a
# forced command at $SERVER_ROOT/.gamemode-src/tools/dispatch.sh, and deploy.sh
# `reset --hard`s that same directory. The dispatcher is a tracked file inside
# the tree the deploy overwrites -- so "switch to branch X" and "replace the
# console's only channel to this box with whatever X says that channel should
# be" are mechanically the same operation. Without the rule, the first thing a
# branch deploy does is install the code that answers every later console
# request, including the request to switch back.
#
# THIS GATE IS WHAT KEEPS docs/branch-switch.md TRUE AFTER EVERYONE STOPS
# LOOKING AT IT. The check inside deploy.sh is a line of shell somebody can
# delete, move below the reset, or lose in a refactor, and nothing about the
# resulting server would look wrong until the day it mattered. So the rule is
# asserted here, from outside, on the text of the scripts: the reset must not be
# reachable without the check standing in front of it.
#
# It is deliberately structural rather than behavioural. Running the real thing
# needs two clones, a remote and a box; asserting that the call is there and is
# ABOVE the reset needs none of that and catches the failure that actually
# happens, which is the check being removed rather than the check being wrong.

echo "${DIM}== branch-switch invariant ==${RST}"
inv=0

if [ -f tools/deploy.sh ]; then
    if ! grep -qE '^assert_dispatch_invariant\(\)' tools/deploy.sh; then
        echo "${RED}FAIL${RST} tools/deploy.sh does not define assert_dispatch_invariant()"
        inv=1
    fi

    # It has to actually compare tools/dispatch.sh across two refs. A function
    # with the right name and an empty body would otherwise pass forever.
    if ! grep -q 'tools/dispatch.sh' tools/deploy.sh \
       || ! grep -q 'dispatch_entry origin/main' tools/deploy.sh; then
        echo "${RED}FAIL${RST} assert_dispatch_invariant does not compare tools/dispatch.sh against origin/main"
        inv=1
    fi

    # Comment lines are dropped first: this file's own prose says "reset --hard"
    # several times, and a gate that trips over the explanation of itself would
    # be deleted within the week.
    gate_line=$(grep -nE '^[[:space:]]*assert_dispatch_invariant[[:space:]]+"' tools/deploy.sh \
                | grep -vE '^[0-9]+:[[:space:]]*#' | head -1 | cut -d: -f1)

    while IFS= read -r hit; do
        [ -n "$hit" ] || continue
        n="${hit%%:*}"
        if [ -z "${gate_line:-}" ] || [ "$gate_line" -ge "$n" ]; then
            echo "${RED}FAIL${RST} tools/deploy.sh reaches a hard reset with no invariant check above it:"
            echo "     line $n: ${hit#*:}"
            echo
            echo "     That reset overwrites \$SRC_DIR/tools/dispatch.sh, which is the"
            echo "     forced command authorized_keys pins the console's SSH key to."
            echo "     Call assert_dispatch_invariant \"\$REMOTE\" before it, or the"
            echo "     branch being deployed gets to rewrite the console's channel."
            inv=1
        fi
    done < <(grep -nE 'reset[[:space:]].*--hard' tools/deploy.sh \
             | grep -vE '^[0-9]+:[[:space:]]*#')
fi

# The second enforcement point. dispatch.sh checks the same rule before it
# writes the pin -- earlier, friendlier, and not load-bearing (it lives in the
# clone a branch switch replaces, so a hostile branch could remove it; deploy.sh
# lives in the ops clone and cannot be touched by a deploy). It still has to be
# there and it still has to run BEFORE the pin is written, or the console would
# happily stage a switch it could never carry out.
if [ -f tools/dispatch.sh ]; then
    if ! grep -qE '^ref_blocked_by\(\)' tools/dispatch.sh; then
        echo "${RED}FAIL${RST} tools/dispatch.sh does not define ref_blocked_by()"
        inv=1
    else
        # SCOPED TO do_switchref, and that is the whole difficulty. `branches`
        # calls ref_blocked_by too, on an earlier line, so a naive "is it called
        # before the pin write" search finds the LISTING's call and passes even
        # when the WRITER's has been deleted -- a gate that goes green on
        # precisely the change it exists to catch. Bound the window at the
        # function header instead.
        fn_line=$(grep -nE '^do_switchref\(\)' tools/dispatch.sh | head -1 | cut -d: -f1)
        pin_line=$(grep -nE 'mv -f "\$tmp" "\$PIN_FILE"' tools/dispatch.sh \
                   | head -1 | cut -d: -f1)
        check_line=$(grep -nE 'ref_blocked_by "\$sha"' tools/dispatch.sh \
                     | grep -vE '^[0-9]+:[[:space:]]*#' | cut -d: -f1 \
                     | awk -v lo="${fn_line:-0}" -v hi="${pin_line:-0}" \
                           '$1 > lo && $1 < hi { print; exit }')
        if [ -z "${fn_line:-}" ] || [ -z "${pin_line:-}" ] || [ -z "${check_line:-}" ]; then
            echo "${RED}FAIL${RST} do_switchref writes the branch pin without checking the invariant first"
            echo "     Expected a ref_blocked_by \"\$sha\" call between do_switchref()"
            echo "     and the line that renames the pin into place."
            inv=1
        fi
    fi
fi

if [ "$inv" -eq 0 ]; then
    echo "${GRN}ok${RST}   no path to a hard reset that skips the dispatch.sh blob check"
else
    echo
    echo "     See docs/branch-switch.md. If the rule itself is changing, change"
    echo "     the document and this gate in the same commit -- that is the whole"
    echo "     point of the gate."
    rc=1
fi

# --- 4b. what can become an incident -----------------------------------------
#
# BR.ShotSuspicious is the whole distance between "the game declined a shot" and
# "a human has to review a case": BR.Damage.noteRefusal returns early for
# anything not in it, so nothing outside this table can reach the Ringmaster
# feed or open an incident.
#
# tools/test_shared.lua asserts the classification properly -- both directions
# plus exhaustiveness, so a new reason cannot arrive unfiled. THIS pin exists
# because the test suite is SKIPPED when no Lua interpreter is present, and a
# widened table would then reach a live server unchallenged. Friendly fire is
# the case that matters: every player carries fists at all times, so counting
# rule refusals would file an incident for the first warmup scrap of a match.

# THIS GATE IS ABOUT THE ANTICHEAT'S SURFACE ONLY, and the distinction started
# mattering the day player reports shipped. Reports are a SECOND source of
# incidents and are deliberately not constrained here: a player naming somebody
# for teaming is not a refusal reason and never passes through BR.ShotSuspicious.
# What this pins is that the ANTICHEAT cannot file for something an honest
# client does constantly.
echo "${DIM}== incident surface ==${RST}"
cs_="resources/[fivem-royale]/br_lib/shared/combat_solve.lua"
SUSPICIOUS_EXPECTED='NOT_HELD NOT_THROWN NO_AMMO NO_WEAPON SELF TOO_FAR TOO_FAST '
if [ -f "$cs_" ]; then
    counted=$(LC_ALL=C sed -n '/^BR.ShotSuspicious = {/,/^}/p' "$cs_" \
              | grep -oE 'BR\.ShotRefusal\.[A-Z_]+' | sed 's/.*\.//' \
              | LC_ALL=C sort -u | tr '\n' ' ')
    if [ "$counted" != "$SUSPICIOUS_EXPECTED" ]; then
        echo "${RED}FAIL${RST} BR.ShotSuspicious is '${counted}'"
        echo "     expected '${SUSPICIOUS_EXPECTED}'"
        echo "     Every reason here files an incident somebody must review."
        echo "     WARMUP, SAME_SQUAD, NOT_LIVE and OTHER_MATCH are things an"
        echo "     honest client does constantly and must never appear."
        echo "     If you are changing this on purpose, update THIS gate and the"
        echo "     RULES/MEANS lists in tools/test_shared.lua together."
        rc=1
    else
        echo "${GRN}ok${RST}   only means-class refusals open an ANTICHEAT incident"
    fi
fi

# --- 5. secrets ---------------------------------------------------------------
#
# The only gate here that scans the WHOLE repo rather than resources/. A
# credential leaks just as thoroughly from tools/, a doc, or server.cfg.example.
# See tools/check_secrets.sh for why it asks git what it would publish instead
# of walking the disk.

echo "${DIM}== secrets ==${RST}"
bash tools/check_secrets.sh || rc=1

# --- 6. br_ddb bundle ---------------------------------------------------------
#
# The AWS SDK is flattened into one committed file because FXServer installs
# nothing and builds nothing. That buys a resource with no dependencies and
# costs exactly one hazard: source and bundle drifting apart, which presents as
# "my change did nothing" with nothing wrong in any log. Same failure the NUI
# bundle guard exists to prevent, so it gets the same treatment.
#
# SKIPPED RATHER THAN FAILED WITHOUT NODE. verify.sh is required to run on a
# box with no Node install (that is why check_secrets.sh is bash), and the ban
# rule's own tests run in the same breath when Node is present.

echo "${DIM}== br_ddb bundle ==${RST}"
if [ ! -d js-src/br_ddb ]; then
    echo "     no br_ddb source, skipping"
elif ! command -v node >/dev/null 2>&1; then
    echo "${YEL}skip${RST} node not installed -- cannot verify the bundle matches its source"
elif [ ! -d js-src/br_ddb/node_modules ]; then
    echo "${YEL}skip${RST} js-src/br_ddb/node_modules absent (run: cd js-src/br_ddb && npm install)"
else
    if node js-src/br_ddb/scripts/build.mjs --check >/dev/null 2>&1; then
        echo "${GRN}ok${RST}   br_ddb bundle matches its source"
    else
        echo "${RED}FAIL${RST} br_ddb bundle does not match js-src/br_ddb"
        echo "     Fix:  cd js-src/br_ddb && npm run build"
        rc=1
    fi

    if node js-src/br_ddb/scripts/test.mjs >/dev/null 2>&1; then
        echo "${GRN}ok${RST}   br_ddb ban rule passes its cases"
    else
        echo "${RED}FAIL${RST} br_ddb ban rule failed -- run: cd js-src/br_ddb && npm test"
        rc=1
    fi
fi

# --- result ------------------------------------------------------------------

echo
if [ "$rc" -eq 0 ]; then
    echo "${GRN}PASS${RST}"
else
    echo "${RED}FAIL${RST}"
fi
exit $rc
