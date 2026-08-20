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
    for suite in tools/test_shared.lua tools/test_loop.lua tools/test_sched.lua tools/test_roster.lua tools/test_stats.lua tools/test_ringmaster.lua tools/test_client.lua tools/test_config.lua; do
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

# --- 3f. the config report still finds everything it names --------------------
#
# tools/config_report.lua is the gamemode half of the console's `configreport`
# verb: it names about forty values by hand and reads them out of
# br_lib/config/*.lua. That hand-written list is a SECOND PLACE where every one
# of those key names is spelled out, and the first place -- the config file
# itself -- gets renamed by people who have never heard of the second.
#
# WHAT GOES WRONG WITHOUT THIS GATE is not a crash. `try()` catches a moved key
# and prints "(unreadable)" in its place, which is the right behaviour on a live
# server at 2am and completely the wrong behaviour on a dev machine, where
# nothing would say a word until somebody opened the Live config page weeks
# later and found a blank where the payout table used to be. So: any unreadable
# row is a build failure here, and a rename is caught by the person doing it.
#
# It also proves the property the whole script depends on -- that
# br_lib/config/*.lua still loads in a BARE Lua state with no FXServer natives.
# The day a config file grows a GetConvar call, this is what says so.
echo "${DIM}== config report ==${RST}"
if [ -n "${LUA:-}" ] && [ -x "$LUA" ]; then
    if report=$("$LUA" tools/config_report.lua 2>&1); then
        broken=$(printf '%s' "$report" | grep -oE '"key":"[^"]*","value":"\(unreadable[^"]*"' || true)
        if printf '%s' "$report" | grep -q '"ok":false'; then
            echo "${RED}FAIL${RST} tools/config_report.lua could not load the config files:"
            printf '%s' "$report" | grep -oE '"loadErrors":\[[^]]*\]' | sed 's/^/     /'
            rc=1
        elif [ -n "$broken" ]; then
            echo "${RED}FAIL${RST} config_report.lua names values that no longer exist:"
            echo "$broken" | sed 's/^/     /'
            echo "     A key was renamed or moved in br_lib/config/. Update the"
            echo "     matching line in tools/config_report.lua."
            rc=1
        else
            n=$(printf '%s' "$report" | grep -oE '"key":' | wc -l | tr -d ' ')
            echo "${GRN}ok${RST}   $n config values readable, all groups present"
        fi
    else
        echo "${RED}FAIL${RST} tools/config_report.lua did not run:"
        printf '%s' "$report" | head -5 | sed 's/^/     /'
        rc=1
    fi
else
    echo "${YEL}skip${RST} (lua interpreter not found)"
fi

# --- 3g. the voice modes have one definition ----------------------------------
#
# THE SIGNATURE FAILURE OF THIS PROJECT, ON THE SUBJECT IT HAS COST THE MOST.
#
# The voice default was written down in FOUR places -- br_lib's enums, br_ui's
# settings schema, br_core's preference, and the TypeScript store -- and three
# of them said 'squad' while one said 'nearby'. The player got 'nearby' only
# because br_ui happens to push its copy over br_core's on br:ui:ready, so the
# answer to "what does a player who never opens the settings screen get"
# depended on a race. Nothing compared them, and nothing could: two of the four
# are not Lua.
#
# tools/test_client.lua asserts the Lua half behaviourally -- an unknown mode
# falls back to BR.VoiceModeDefault, and the modes route what they claim. What
# it cannot reach is ui-src, which is TypeScript, and the BUILT BUNDLE, which is
# what actually ships to the player. Both are checked here, as text, because
# text is what they have in common.
#
# THE BUNDLE CHECK IS THE ONE THAT EARNS ITS PLACE. resources/*/br_ui/ui is
# committed build output and tools/deploy.sh rsyncs it verbatim; editing
# apply.ts without running `npm run build` in ui-src changes nothing that
# reaches a player, and looks correct in every diff.

echo "${DIM}== voice defaults ==${RST}"
voice=0
enums=$(echo resources/*/br_lib/shared/enums.lua)

if [ ! -f "$enums" ]; then
    echo "${RED}FAIL${RST} cannot find br_lib/shared/enums.lua"
    voice=1
else
    # BR.VoiceModeDefault = BR.VoiceMode.NEARBY  ->  NEARBY  ->  'nearby'
    key=$(grep -oE '^BR\.VoiceModeDefault[[:space:]]*=[[:space:]]*BR\.VoiceMode\.[A-Z]+' "$enums" \
          | grep -oE '[A-Z]+$' || true)
    want=$(grep -oE "^[[:space:]]+${key:-__none__}[[:space:]]*=[[:space:]]*'[a-z]+'" "$enums" \
           | grep -oE "'[a-z]+'" | tr -d "'" || true)

    if [ -z "$want" ]; then
        echo "${RED}FAIL${RST} cannot read BR.VoiceModeDefault out of br_lib/shared/enums.lua"
        echo "     This gate resolves 'BR.VoiceModeDefault = BR.VoiceMode.<KEY>'"
        echo "     against the BR.VoiceMode table. If that shape changed, reshape"
        echo "     this gate with it -- do not delete it."
        voice=1
    fi
fi

if [ "$voice" -eq 0 ]; then
    # 1. NO ROUTING ROW MAY OPEN BOTH CHANNELS. The modes are exclusive: nearby
    #    is proximity, squad is the radio, and a row with both is the layering
    #    the owner has now rejected three times.
    if grep -qE 'proximity[[:space:]]*=[[:space:]]*true[[:space:]]*,[[:space:]]*radio[[:space:]]*=[[:space:]]*true' "$enums"; then
        echo "${RED}FAIL${RST} a BR.VoiceRouting row opens proximity AND the radio:"
        grep -nE 'proximity[[:space:]]*=[[:space:]]*true[[:space:]]*,[[:space:]]*radio[[:space:]]*=[[:space:]]*true' "$enums" | sed 's/^/     /'
        echo "     The modes are mutually exclusive. 'nearby' is proximity only;"
        echo "     'squad' is the squad radio only. See the block above the table."
        voice=1
    fi

    # 2. THE TWO LUA CONSUMERS MUST READ THE VALUE, NOT RESTATE IT. A literal
    #    here is the exact shape of the bug: it compiles, it runs, and it
    #    disagrees with the other file silently.
    #
    #    THE FIELD NAMES MOVED WHEN THE SETTING BECAME TWO -- voiceModeSolo and
    #    voiceModeSquad, one per kind of match (see BR.VoiceModeFor in br_lib).
    #    The pattern below matches the stem, so it covers the pair and would
    #    still catch a plain `voiceMode` if one came back.
    for pair in \
        "resources/*/br_ui/client/settings.lua:voiceMode[A-Za-z]*" \
        "resources/*/br_core/client/voice.lua:mode"
    do
        # Unquoted on purpose: the left half is a glob that has to expand
        # through the bracketed resource-group directory.
        f=$(echo ${pair%%:*}); field="${pair##*:}"
        [ -f "$f" ] || continue
        if grep -qE "${field}[[:space:]]*=[[:space:]]*'(nearby|squad|off)'" "$f"; then
            echo "${RED}FAIL${RST} ${f#resources/} spells a voice mode out as a literal:"
            grep -nE "${field}[[:space:]]*=[[:space:]]*'(nearby|squad|off)'" "$f" | sed 's/^/     /'
            echo "     Read BR.VoiceModeDefault / BR.ToVoiceMode from br_lib instead."
            voice=1
        fi
    done

    # 3. THE TYPESCRIPT DEFAULTS, which no Lua test can see.
    #
    #    BOTH SLOTS ARE CHECKED, AND THE COUNT IS CHECKED TOO. A gate that
    #    compares whatever it happens to find goes blind the moment a field is
    #    renamed out from under it -- which is exactly what would have happened
    #    here, silently, when voiceMode became a pair. So the names are named.
    ts='ui-src/src/settings/apply.ts'
    if [ -f "$ts" ]; then
        for field in voiceModeSolo voiceModeSquad; do
            got=$(grep -oE "${field}:[[:space:]]*'[a-z]+'" "$ts" \
                  | grep -oE "'[a-z]+'" | tr -d "'" || true)
            if [ "$got" != "$want" ]; then
                echo "${RED}FAIL${RST} $ts has $field '${got:-<none>}', br_lib says '$want'"
                echo "     This is the value the settings screen renders before Lua's"
                echo "     push lands, so a disagreement shows the player a mode they"
                echo "     are not on. If the field was renamed, rename it HERE too --"
                echo "     a gate that cannot find its field passes nothing."
                voice=1
            fi
        done
    fi

    # 4. AND THE BUILT BUNDLE, which is what a player actually runs.
    bundle_seen=0
    for js in resources/*/br_ui/ui/assets/*.js; do
        [ -e "$js" ] || continue
        while IFS= read -r got; do
            bundle_seen=1
            if [ "$got" != "$want" ]; then
                echo "${RED}FAIL${RST} ${js#resources/} ships a voice default '$got', br_lib says '$want'"
                echo "     The bundle is stale. Run: cd ui-src && npm run build"
                voice=1
            fi
        done < <(grep -oE 'voiceMode(Solo|Squad):"[a-z]+"' "$js" \
                 | grep -oE '"[a-z]+"' | tr -d '"' || true)
    done
    if [ "$bundle_seen" -eq 0 ]; then
        echo "${YEL}warn${RST} no voice-mode default found in the built bundle --"
        echo "     the minifier's output shape may have changed. This gate is the"
        echo "     only thing that catches a source edit that was never built;"
        echo "     re-point it rather than leaving it blind."
    fi
fi

if [ "$voice" -eq 0 ]; then
    echo "${GRN}ok${RST}   voice modes are exclusive and the default ('$want') agrees in Lua, TS and the bundle"
else
    rc=1
fi

# --- 3h. the tunable overrides stay server-side and stay in order --------------
#
# br_lib/config/overrides.lua lets a .cfg on one box change values that are
# otherwise committed constants, which creates -- for the handful of settings it
# names -- a SECOND place each value can come from. Two homes for one setting
# with nothing comparing them is the failure this project keeps paying for, so
# the two properties that keep it honest are mechanical.
#
# BOTH OF THESE NEED A DIRECTORY WALK, which is why they are here and not in
# tools/test_config.lua: Lua cannot list a directory without io.popen, and
# io.popen on the Windows checkout this repo is developed on spawns cmd.exe,
# where `ls` does not exist. That gate would scan zero files and pass forever.
# The behavioural half of this feature -- parsing, ranges, refusals, the boot
# banner -- is unit-tested and needs none of this.

echo "${DIM}== tunable overrides ==${RST}"
tun=0
OVR="resources/*/br_lib/config/overrides.lua"

if ! compgen -G "$OVR" >/dev/null 2>&1; then
    echo "${YEL}skip${RST} no br_lib/config/overrides.lua in this checkout"
else
    # The spec is the list of keys a convar may write. Pulled out of the file
    # rather than restated here, so adding a tunable extends this gate for free
    # and a gate that names its own subjects cannot go stale against them.
    keys=$(grep -oE "^\s+key\s+=\s+'[A-Za-z_]+'" $OVR | grep -oE "'[A-Za-z_]+'" | tr -d "'" | sort -u)

    if [ -z "$keys" ]; then
        echo "${RED}FAIL${RST} could not read the override spec out of br_lib/config/overrides.lua"
        echo "     The two checks below would silently examine nothing. If the"
        echo "     spec was reshaped, reshape this gate with it."
        tun=1
    fi

    # (1) NO OVERRIDABLE KEY MAY BE READ ON THE CLIENT.
    #
    # config/*.lua is loaded into the client's Lua state as well, and
    # overrides.lua deliberately applies nothing there -- it reads convars only
    # when IsDuplicityVersion says this is the server. So a client that READS
    # one of these keys is holding the committed default while the server holds
    # the operator's value, for the same named setting, with nothing comparing
    # them. That is not a bug this gate makes convenient to find; it is one it
    # makes impossible to introduce.
    #
    # Comment lines are dropped first. config/match.lua's prose and
    # br_core/client/natives.lua both DISCUSS maxSquadSize in comments, and a
    # gate that trips over the explanation of the thing it guards gets deleted
    # within the week.
    for k in $keys; do
        while IFS= read -r hit; do
            [ -n "$hit" ] || continue
            echo "${RED}FAIL${RST} a client file reads the overridable key '$k':"
            echo "     ${hit}"
            echo "     Overrides are applied on the SERVER only. A client read means"
            echo "     the two sides disagree the moment an operator sets the convar."
            echo "     Either send the value over the wire, or drop it from the spec"
            echo "     in br_lib/config/overrides.lua."
            tun=1
        # \b at BOTH ends, not a bracket expression. `[^A-Za-z_]${k}[^A-Za-z_]`
        # was the first spelling and it needs a character after the key, so a
        # read at the end of a line -- `local n = BR.Config.Match.maxSquadSize`,
        # the single likeliest way this is written -- matched nothing at all.
        done < <(grep -rnE "\\b${k}\\b" resources/*/br_*/client/*.lua 2>/dev/null \
                 | grep -vE '^[^:]+:[0-9]+:[[:space:]]*--' || true)
    done

    # (2) EVERY CONSUMER OF config/match.lua MUST LOAD overrides.lua AFTER IT.
    #
    # The override has to land before anything copies the value: br_core's
    # server/match.lua builds its DURATION table from warmupSeconds and
    # endedSeconds at file load. A resource that pulls in match.lua and not
    # overrides.lua runs the committed defaults while the rest of the server
    # runs the convars, and nothing at runtime says a word.
    # COMMENTED LINES DO NOT COUNT, and the first draft of this let them.
    # `-- '@br_lib/config/overrides.lua',` satisfied a plain grep perfectly
    # while loading nothing -- the gate went green on the exact edit it exists
    # to catch. These manifests are half prose, so this is not a hypothetical
    # spelling.
    uncommented() {
        grep -n "$1" "$2" | grep -vE '^[0-9]+:[[:space:]]*--' | head -1 | cut -d: -f1
    }

    while IFS= read -r manifest; do
        m=$(uncommented '@br_lib/config/match.lua' "$manifest")
        [ -n "$m" ] || continue
        o=$(uncommented '@br_lib/config/overrides.lua' "$manifest")
        if [ -z "$o" ]; then
            echo "${RED}FAIL${RST} ${manifest#resources/} loads config/match.lua but never config/overrides.lua"
            echo "     It would run the committed defaults while the rest of the"
            echo "     server runs whatever the .cfg set."
            tun=1
        elif [ "$o" -lt "$m" ]; then
            echo "${RED}FAIL${RST} ${manifest#resources/} loads config/overrides.lua BEFORE config/match.lua"
            echo "     The overrides edit that table; loading them first edits nothing."
            tun=1
        fi
    done < <(find resources -name 'fxmanifest.lua' | sort)

    if [ "$tun" -eq 0 ]; then
        echo "${GRN}ok${RST}   overridable keys are server-only and every consumer loads them in order"
    else
        rc=1
    fi
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
#   reload / config           live config EDITING. Still M6, still forbidden,
#                             and the bare word `config` stays reserved for it
#                             -- which is why the read verb below is called
#                             `configreport` and not `config`. Reading the
#                             values and writing them are different
#                             capabilities and must not share a name.
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

# `configreport` ARRIVED WITH THE LIVE CONFIG PAGE (ringmaster#21) AND IS THE
# LIGHTEST VERB HERE. It opens server.cfg and the deployed config files, runs
# one Lua script over them, and prints JSON. No tmux, no systemctl, no writes of
# any kind -- it is `status` and `telemetry` with a different set of files. The
# thing that makes it safe is not that it only reads, it is WHAT it reads: an
# explicit allowlist of convar names, checked by the gate below, because
# server.cfg is where sv_licenseKey lives.

# dispatch.sh: the SSH verb surface.
#
# THE PATTERN IS DELIBERATELY GENERIC, AND IT USED NOT TO BE. This grep matched
# an alternation of verb names somebody had thought of in advance --
# `(status|telemetry|stop|restart|deploy|reload|config|kick|ban|...)` -- which
# means a verb named anything else WAS INVISIBLE TO IT. Adding `configreport)`
# to dispatch.sh left this gate reporting the old six and passing green; the
# gate protecting the verb set could not see the verb set growing.
#
# That is the same failure mode as a denylist, in the one place built to prevent
# it: it fails OPEN, and it fails open exactly for the case it exists to catch,
# because a new capability arrives under a new name by definition. Matching the
# shape of a case arm instead -- indented, lowercase, then `)` -- means the gate
# reads what dispatch.sh actually dispatches. Verified to match the seven arms
# and nothing else in the file; the `*)` fallthrough and the quoted patterns
# inside `case` blocks do not start with a lowercase letter.
if [ -f tools/dispatch.sh ]; then
    # ANY case arm, not a list of names somebody anticipated.
    #
    # This used to grep a fixed alternation -- (status|telemetry|deploy|...) --
    # which made it a DENYLIST inside the gate built to prevent denylists, and
    # it failed open for exactly the case it exists to catch: a new capability
    # arrives under a new name by definition. `configreport)` did not match
    # `config)`, so the verb was invisible here and the check passed green with
    # a new channel from the console to the host already added.
    verbs=$(grep -oE '^[[:space:]]+[a-z_]+\)' tools/dispatch.sh \
            | tr -d ' )' | sort -u | tr '\n' ' ')
    if [ "$verbs" != "branches configreport deploy kick status switchref telemetry " ]; then
        echo "${RED}FAIL${RST} dispatch.sh verb set is '${verbs}', expected 'branches configreport deploy kick status switchref telemetry '"
        echo "     A new verb is a new capability from the console to the host."
        echo "     Process control (stop/restart) is not a verb and never has been."
        echo "     If you are adding one on purpose, update THIS gate."
        boundary=1
    fi

    # THE CONVAR ALLOWLIST MAY NOT NAME A CREDENTIAL.
    #
    # `configreport` renders in a browser and lands in an audit log, and the
    # allowlist in do_configreport is the only thing standing between that and
    # server.cfg, which holds the real licence key. The allowlist itself is the
    # control and this does not replace it -- this is the second pair of eyes on
    # the one line of that file where a mistake is expensive.
    #
    # A DENYLIST IS THE WRONG TOOL FOR CHOOSING WHAT TO PUBLISH and the right
    # one for reviewing a specific short list somebody just edited. It cannot
    # catch a secret under an unguessable name, which is precisely why it is not
    # what decides the output -- but `sv_licenseKey` pasted into that list at
    # 1am is the realistic mistake, and this catches that.
    allow_block=$(sed -n '/^    local CONVAR_ALLOW="$/,/^    "$/p' tools/dispatch.sh)
    if [ -z "$allow_block" ]; then
        echo "${RED}FAIL${RST} cannot find do_configreport's CONVAR_ALLOW list in tools/dispatch.sh"
        echo "     The gate below cannot check a list it cannot find. If the list"
        echo "     was reshaped, reshape this gate with it."
        boundary=1
    else
        bad=$(printf '%s' "$allow_block" \
              | grep -iE '(licen[cs]e|secret|password|passwd|_pass|token|api_?key|_key|webhook|principal|ingest_url)' \
              || true)
        if [ -n "$bad" ]; then
            echo "${RED}FAIL${RST} configreport's convar allowlist names something credential-shaped:"
            echo "$bad" | sed 's/^/     /'
            echo "     This output is rendered in a browser and written to an audit log."
            boundary=1
        fi
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
    echo "${GRN}ok${RST}   the console can kick, ban, deploy, switch branch and READ config -- no raw stop/restart, no config writes"
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

# --- 7. duplicate console commands --------------------------------------------
#
# TWO HANDLERS FOR ONE NAME MEANS LOAD ORDER DECIDES, AND LOAD ORDER IS NOT A
# DECISION ANYBODY MADE. FiveM keeps the LAST registration, silently, so the
# loser looks present in the source, reads correctly, and never runs.
#
# Three of these existed at once when this gate was written (#137):
#
#   brdrop   keybinds.lua's G binding vs skydive.lua's debug dump. On a client
#            with no raw-key layer, G ran the debug print and dropped nothing.
#   brkeys   keybinds.lua's real dump vs a thinner one in debug.lua that loaded
#            later and won -- so the raw-layer, holds and focus-resync readings
#            added for #90 and #129 printed for nobody, while we were telling
#            the owner to run that exact command to diagnose those exact bugs.
#   brstorm  storm.lua's vs debug.lua's; storm.lua's never ran.
#
# CLIENT AND SERVER ARE SEPARATE LUA STATES, so the same name in a client file
# and a server file is fine and common here (brloot, brparty, brvoice...). Only
# a collision WITHIN one state is a fault, which is why this buckets by folder.
#
# tap()/hold() register indirectly -- tap('drop','brdrop',...) becomes
# RegisterCommand('brdrop'), and hold() becomes '+name' and '-name' -- so a grep
# for RegisterCommand alone misses exactly the case that caused #137.
echo "${DIM}== duplicate console commands ==${RST}"
dupes=$(
    for side in client server; do
        for f in $(find "resources/[fivem-royale]" -path "*/$side/*.lua" 2>/dev/null); do
            grep -v '^\s*--' "$f" \
                | grep -oE "RegisterCommand\(\s*'[^']+'|^\s*(tap|hold)\s*\(\s*'[^']*'\s*,\s*'[^']+'" \
                | grep -oE "'[^']+'\s*\)?$" | tr -d "' )" \
                | sed "s/^/$side /"
        done
    done | sort | uniq -c | awk '$1 > 1 { print "     " $3 " (" $2 ", " $1 " registrations)" }'
)
if [ -z "$dupes" ]; then
    echo "${GRN}ok${RST}   no console command name is registered twice in one Lua state"
else
    echo "${RED}FAIL${RST} a console command is registered more than once in one Lua state:"
    echo "$dupes"
    echo "     The later registration wins and the earlier one never runs."
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
