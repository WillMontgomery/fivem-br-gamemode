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
#   3e. BOOLS   -- a FiveM native declared BOOL read as a Lua truth value. 0 is
#                 truthy in Lua, so both spellings of that test are wrong and
#                 they are wrong in opposite directions. Seven shipped instances
#                 and counting; a ratchet against tools/bool_natives.baseline.
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
n=0; bad=0; hashlit=0
while IFS= read -r f; do
    n=$((n+1))
    out=$("$LUAC" -p "$f" 2>&1) && continue

    # CfxLua's HASH-STRING LITERAL. A failure here is not always a syntax error.
    #
    # FiveM's Lua compiles `speech` -- BACKTICKS, not quotes -- to the Jenkins
    # hash of that string at parse time. Stock luac 5.4 has no such literal and
    # stops dead at the first backtick, so a file the game loads perfectly well
    # fails this gate. That is a gap between the gate's parser and the game's,
    # not a fault in the file.
    #
    # ONLY ON THE RETRY PATH, which is the point: a file that parses as stock
    # Lua 5.4 is checked exactly as it was before and never reaches here. Only a
    # file that has ALREADY FAILED is re-parsed with `ident` rewritten to
    # "ident", and a genuine syntax error still fails, because that rewrite
    # cannot repair one. The gate gets more accurate rather than more permissive.
    #
    # It exists for VENDORED third-party code: pma-voice's client/commands.lua
    # calls MumbleSetAudioInputIntent(`speech`). Nothing we write uses the
    # literal -- the backticks all over our own files are prose inside comments,
    # which luac never sees.
    if sed -E 's/`([A-Za-z0-9_]*)`/"\1"/g' "$f" | "$LUAC" -p - >/dev/null 2>&1; then
        hashlit=$((hashlit+1))
        continue
    fi

    echo "${RED}FAIL${RST} $f"
    echo "     $out"
    bad=$((bad+1))
done < <(find resources -name '*.lua' 2>/dev/null | sort)

if [ "$bad" -eq 0 ]; then
    if [ "$hashlit" -gt 0 ]; then
        echo "${GRN}ok${RST}   $n files parsed ($hashlit via the CfxLua hash-string retry)"
    else
        echo "${GRN}ok${RST}   $n files parsed"
    fi
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
    #
    # test_artifacts.lua loads br_core/server/artifacts.lua itself, which makes
    # it the second suite here to exercise a server file rather than a pure
    # module. It is worth the stubs: the capture rules -- three frames, one per
    # corroboration after ten seconds, nine and then stop -- can only be seen in
    # the game by drawing nine corroborations on one case.
    #
    # test_airdrop.lua is the third suite here to load a server file rather than
    # a pure module, and it is worth the stubs for the same reason
    # test_artifacts.lua is: the rules under test -- exactly one drop a match,
    # never inside 250m of the wall, never past storm stage 4 -- take a whole
    # match each to observe in the game and are wrong for weeks otherwise.
    # test_fuel.lua is the fourth suite here to load a real server file, and it
    # is its own rather than a block inside test_roster because the property
    # worth pinning spans three layers: the pure solver, the tank size DERIVED
    # from the map AABB, and the registry that makes a tank survive its driver.
    # Split across two existing suites, the interesting one -- a car staying dry
    # for whoever gets in next -- would be testable in neither.
    #
    # test_spectate.lua is the fifth exception and the only CLIENT one besides
    # test_client itself. It stands up br_core/client/spectate.lua, which no
    # other suite loads -- test_client stubs BR.Spectate and says in a comment
    # why. That was right while the only thing read out of that file was
    # `active()`; it stopped being right when the file grew a rule about the
    # player's OWN ped. The property it exists for is not "which controls are in
    # the list" -- a text gate could do that -- it is that the list is let go on
    # every path out of a session, and "the frame after the session ended
    # disabled nothing" is a step of the loop, not a string in a file. A
    # spectator who cannot move after a match is a worse bug than the accidental
    # gunshot that prompted the work.
    # test_matchexit.lua is the second suite to load a CLIENT file, and it loads
    # the biggest one -- client/state.lua, the whole mirror -- because the
    # property it pins is a sequence rather than a value: every way out of a
    # match has to take the match's surfaces with it (#204). A death word that
    # walks into the lobby is not visible to any static check; it is visible in
    # one batch of roster deltas shaped the way server/match.lua really shapes
    # them, which is what this drives.
    #
    # test_vehdamage.lua is the third suite to load a CLIENT file, and the one
    # whose fixture is the argument. #213's applier writes four handling
    # multipliers derived from the model's own values -- and FiveM's
    # GET_VEHICLE_HANDLING_FLOAT reads the vehicle's own CLONE of that handling,
    # so it answers our write once we have made one. An applier that read the
    # field and multiplied it would therefore multiply by five ten times a
    # second, and a fixture whose getter answered a constant would agree with it
    # happily. So the fixture keeps the template and the clone as two tables and
    # the suite's central assertion is that two hundred passes leave the numbers
    # where one pass did.

    # test_bool_natives.lua tests a GATE rather than a shipped module, for the
    # same reason test_icons.lua does and against the defect this project has
    # shipped most. tools/check_bool_natives.lua reads the real tree against a
    # recorded baseline, so on a clean checkout it proves the tree has not got
    # worse and cannot prove it would notice if it had. The rules are pure
    # functions in tools/bool_native_rules.lua and this suite feeds them
    # deliberately broken sources -- and, just as importantly, every spelling of
    # the FIX, because a gate that flags correct code is a gate that gets an
    # exception and then gets deleted.
    #
    # test_icons.lua is the odd one out in a new way: it tests a GATE rather
    # than a shipped module. tools/check_weapons.lua can only ever read the one
    # real ItemIcon.tsx, so it proves that file is clean and cannot prove it
    # would notice a dirty one. The rules live in tools/icon_rules.lua as pure
    # functions and this suite feeds them deliberately broken sources -- which
    # is the only way a detector gets shown to still detect.
    #
    # test_vehrefuse.lua is the fourth suite to load a CLIENT file, and its
    # fixture is an argument too. #215 rejects a refused vehicle AT THE DOOR --
    # during the entry animation, before the seat is taken -- and falls back to
    # ejecting a player who got there anyway. Those two paths are one line apart
    # in the file and indistinguishable in a screenshot: the slow one still ends
    # with the player standing next to the helicopter. So `entering` and `myVeh`
    # are two variables in that fixture and are NEVER both set, which is what
    # makes a file that only ever checks the seat fail rather than pass a second
    # late.
    # test_ambheal.lua is the sixth suite to load a real SERVER file, and the
    # fixture is the argument again. Four of the owner's rules for healing in an
    # ambulance are effectively unobservable in a match: the doors-shut refusal
    # looks identical to an unimplemented prompt, the "one heal per ambulance"
    # race needs two players pressing within a few frames of each other, the
    # partial-on-interrupt rule is INDISTINGUISHABLE from the wrong
    # implementation on any heal that completes, and staging a death on the
    # stretcher costs a playtest round whose bad outcome is a stuck ped. So the
    # world is three stub vehicles and the clock is this file's.
    #
    # The one rule it does NOT test is the one that matters most -- that a
    # healing player is killable -- and that is deliberate: it is a property of
    # client/natives.lua's invincibility latch, so it is asserted against the
    # real natives.lua in test_client.lua, which already drives it frame by
    # frame. See the header of test_ambheal.lua.
    #
    # test_lobbyseq.lua is the fifth suite to load a CLIENT file and the first
    # to MODEL Citizen rather than stub it away, and both are the same argument.
    # The property it pins is an ORDER -- the ped is teleported to its warmup
    # spawn and only then becomes a networked ped (owner, 2026-08-29) -- and an
    # order is what neither a text gate nor a playtest can see: the window is one
    # frame wide, on somebody else's screen, and the wrong version and the right
    # version are identical in a screenshot. Both halves of it live inside
    # threads with waits in them, so the no-op CreateThread every other client
    # suite uses would make every assertion here vacuously true. Threads are
    # coroutines, the clock is stepped, and the ped actually walks -- which is
    # what lets the second claim be tested too: that the entrance can be
    # abandoned at any point leaving no camera and no half-finished task.
    #
    # test_shop.lua is the seventh suite to load a real SERVER file, and the
    # FIXTURE is the whole argument -- more so here than anywhere else, because
    # the shipped catalogue is EMPTY ON PURPOSE. BR.Config.Shop.items is `{}`
    # until the owner authors his models, coordinates and headings in game, so a
    # suite that ran against the shipped table would assert nothing and would
    # start passing for a different reason the day he pastes his rows in. Every
    # behavioural test there builds its own three-car catalogue; exactly one
    # reads the real table, and it asserts that it is empty.
    #
    # It also pins three things a playtest cannot see. "EXACTLY AS SHOWN WHEN
    # THEY PURCHASED IT" is a structural property -- one dresser, one authored
    # row, no appearance on the wire -- and the wrong version is invisible until
    # somebody happens to notice a colour, by which time the showroom car has
    # been gone for forty minutes. The DELIVERY ORDERING is one line: the item is
    # handed out AFTER BR.Inv.clearFor(m), and one line earlier the wipe silently
    # deletes what the player paid for. And NO REFUND (owner's answer 3) fails
    # only under an engine fault nobody can reproduce on demand
    # (citizenfx/fivem#2623), where the wrong version hands out a second car for
    # one payment.
    #
    # test_landtime.lua is the sixth suite to load a CLIENT file, and the only
    # one whose subject is a MEASURING INSTRUMENT rather than a behaviour. That
    # is why it is not a block inside test_client.lua, whose descent section
    # loads the same file: every assertion there is about what the prompt SAID,
    # and none is about when anything happened.
    #
    # An instrument has a failure mode ordinary code does not -- it can agree
    # with the thing it measures by accident. A landing timer that took its own
    # "the feet are down" from one of the clauses of the landing test would read
    # zero for exactly the landing #245 is about: the clause lies, the contact
    # time lies with it, and the readout exonerates the code it is pointing at.
    # So the suite holds one clause false for five seconds and asserts that five
    # seconds is what comes out, from a ground truth (IsEntityInAir) that no ped
    # task owns. Its stubs answer 1/0 rather than true/false, so a sampler that
    # loses its isTrue() wrapper fails here rather than in a playtest.
    #
    # test_revivekey.lua is the eighth suite to load a real SERVER file, and it
    # is deliberately NOT where the feature's central rule is proved. "The key
    # is minted on the same edge that spills the inventory" (owner, 2026-08-30)
    # is a property of server/combat.lua, so it is asserted in test_roster.lua's
    # `combat.revivekey` against the real eliminate(), the real loot table and
    # the real #144 hold -- a sandbox that called BR.ReviveKey.onEliminated by
    # hand would only be testing that the module does what it is told.
    #
    # What IS here is everything a playtest cannot reach cheaply: a three-minute
    # expiry, the last 2.5 metres of a squadmate's walk, a DynamoDB round trip
    # with another elimination landing inside it, and two squadmates pressing
    # buy in the same second. Its BOOL stubs answer 1/0 rather than true/false,
    # so a refusal that loses its isTrue() wrapper fails here rather than
    # selling a revive key at a burnt-out ambulance.
    #
    # Its `source` block runs BEFORE the module is loaded, on purpose: the
    # BR.Server stub has no `notify`, so unrequested player copy would otherwise
    # throw three hundred lines later and report a nil call instead of the rule
    # it broke (#219 Q20 is unanswered and no wording may be invented).
    #
    # test_community.lua is the ninth suite to load a real SERVER file, and the
    # only one whose subject is a single envelope. It runs the REAL
    # config/overrides.lua rather than assigning BR.Config.Community by hand,
    # which is what makes it a seam test rather than a restatement: it fails the
    # day the convar stops reaching the table the sender reads out of.
    #
    # What it is really guarding is the `{}`. br_core/server/community.lua
    # answers br:ready even when there is no invite, so a page already on screen
    # takes the Discord card down when an operator clears the value and restarts;
    # a sender that returned early instead would look correct, pass any test
    # written as "no invite was sent", and leave a dead card up forever.
    #
    # test_guild.lua is the tenth suite to load a real SERVER file, and it is the
    # first whose subject is an OUTSIDE SERVICE. br_core/server/guild.lua asks
    # Discord whether a player is already in our guild, and the answer decides
    # whether that player is shown the invite card at all -- so every mistake
    # available in it is a mistake that stops inviting people, silently, in the
    # states nobody watches.
    #
    # THE POLARITY IS THE SUBJECT. The lookup has three answers -- yes, no, and we
    # did not find out -- and only the first hides anything. Two of the three must
    # behave identically, which means the wrong version and the right version are
    # indistinguishable on a healthy server with a valid token: they differ only
    # when Discord 404s about the GUILD rather than the member, when the bot has
    # been removed, when we are rate-limited, or when no token is configured at
    # all. Staging any of those in a match costs a second Discord server and a way
    # to make Discord fail on demand; here each is a status code.
    #
    # It also drives the pacing, which nothing else can: sixty players connect at
    # once when a match fills, one lookup goes out at a time, and a 429 stands the
    # queue down for the interval Discord named. Its clock is stepped by hand for
    # the reason test_lobbyseq.lua models Citizen -- a no-op SetTimeout would make
    # every one of those assertions vacuously true.
    for suite in tools/test_shared.lua tools/test_loop.lua tools/test_sched.lua tools/test_roster.lua tools/test_stats.lua tools/test_ringmaster.lua tools/test_artifacts.lua tools/test_airdrop.lua tools/test_client.lua tools/test_spectate.lua tools/test_matchexit.lua tools/test_lobbyseq.lua tools/test_landtime.lua tools/test_config.lua tools/test_admin.lua tools/test_community.lua tools/test_guild.lua tools/test_fuel.lua tools/test_boost.lua tools/test_vehdamage.lua tools/test_icons.lua tools/test_vehrefuse.lua tools/test_rescue.lua tools/test_ambheal.lua tools/test_revivekey.lua tools/test_ambulances.lua tools/test_shop.lua tools/test_bool_natives.lua; do
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

# The same joaat proof as the weapon table, over the refused-vehicle table --
# and it matters more there, because the polarity is inverted. A wrong hash in
# weapons.lua makes a gun behave oddly and somebody notices. A wrong hash in
# vehicles.lua permits a tank, and the only symptom is an incident that is never
# filed, which looks exactly like a clean server.
echo "${DIM}== vehicle table ==${RST}"
if [ -n "${LUA:-}" ] && [ -x "$LUA" ]; then
    "$LUA" tools/check_vehicles.lua || rc=1
else
    echo "${YEL}skip${RST} (lua interpreter not found)"
fi

echo "${DIM}== POI siting ==${RST}"
if [ -n "${LUA:-}" ] && [ -x "$LUA" ]; then
    "$LUA" tools/check_pois.lua || rc=1
else
    echo "${YEL}skip${RST} (lua interpreter not found)"
fi

# --- 3d-bis. nothing authored outside the surveyed map edge --------------------
#
# The owner walked the playable boundary on the pause map on 2026-08-28 -- 67
# clicks, a closed ring, 51.06 km^2 -- and asked for everything outside it to be
# removed. Eight POIs were. THIS is the half that keeps them removed.
#
# The failure it is aimed at has a long fuse. A POI authored six months from now
# at coordinates nobody checks against a map does not error, does not look wrong
# in a diff, and does not misbehave until it is drawn as a storm anchor and a
# match ends over open water. That is the bug the owner reported, and it took a
# hand survey to diagnose because nothing in the tree could say where the map was.
# Now something can, so it is asserted every build.
#
# check_boundary.lua also pins the ring to the survey's own perimeter, area and
# centroid, which is what stops this gate being circular: without it, a boundary
# widened to admit a coordinate would still pass every check it makes.
echo "${DIM}== map boundary ==${RST}"
if [ -n "${LUA:-}" ] && [ -x "$LUA" ]; then
    "$LUA" tools/check_boundary.lua || rc=1
else
    echo "${YEL}skip${RST} (lua interpreter not found)"
fi

# A spectator listens and does not talk -- the owner, unconditionally. The
# CLIENT half of that rule is unit-tested (test_client drives the real key
# through the real loop). This gate is for the SERVER half, which is not a
# function with a value to assert but three call sites: two ways to open a
# session and one to close it, each of which has to reach the mute. The defect
# it is aimed at is an edge that does not call -- a fourth way to start
# spectating, added later, that nobody remembers to mute.
echo "${DIM}== spectator microphone ==${RST}"
if [ -n "${LUA:-}" ] && [ -x "$LUA" ]; then
    "$LUA" tools/check_spectator_mic.lua || rc=1
else
    echo "${YEL}skip${RST} (lua interpreter not found)"
fi

# The HUD a spectator reads. The inventory half has a real behaviour test in
# test_client; this covers the two halves no suite can reach -- the vitals
# substitution in client/state.lua, which no suite that owns the HUD loads, and
# the shape of the server feed, whose important property is that the target's
# inventory goes to ONE watcher rather than to everybody. A broadcast there
# would look perfect in game and leak every loadout in the match.
echo "${DIM}== spectator HUD ==${RST}"
if [ -n "${LUA:-}" ] && [ -x "$LUA" ]; then
    "$LUA" tools/check_spectator_hud.lua || rc=1
else
    echo "${YEL}skip${RST} (lua interpreter not found)"
fi

# The squad panel says who is talking and, on the viewer's own row, that their
# voice is carrying nothing at all. The Lua half -- the sentence this replaced,
# and the flags the mark reads -- is unit-tested in test_client. This gate is
# for the properties no suite can reach: that the panel did not grow an oracle
# (a per-player voice mode would widen what a client is told about players it
# cannot see), that the mark stays on one row, and that the two halves of its
# layout pair have not come apart.
echo "${DIM}== squad voice marks ==${RST}"
if [ -n "${LUA:-}" ] && [ -x "$LUA" ]; then
    "$LUA" tools/check_squad_voice.lua || rc=1
else
    echo "${YEL}skip${RST} (lua interpreter not found)"
fi

# The same panel shows a teammate's LEVEL beside their name. The behaviour --
# derived from lifetime xp, squad-only, absent until the server knows it -- is
# unit-tested in test_shared ('squad.level'). This gate is for what no suite can
# execute: that the number has not drifted onto the public roster (where nothing
# would break and nobody would notice), that it has not grown a caption, and
# that it has not learned to scale with the text-size preference on a plate
# whose height must not move.
echo "${DIM}== squad levels ==${RST}"
if [ -n "${LUA:-}" ] && [ -x "$LUA" ]; then
    "$LUA" tools/check_squad_level.lua || rc=1
else
    echo "${YEL}skip${RST} (lua interpreter not found)"
fi

# The same panel says whether a mate's REVIVE KEY is held by the squad. The
# ledger under it is unit-tested in test_revivekey; this gate is for what no
# suite can execute: that the fact stayed squad-only, that the tri-state
# survived both folds (an `x and y or nil` in Lua and a `&&` in JSX each eat the
# false case, which is the mate whose key is still on the ground), that the mark
# is a picture rather than a seventh string, and that the plate stops fading a
# recoverable mate down to nothing. It is also the only gate that catches a
# stale UI bundle for this file.
echo "${DIM}== squad revive keys ==${RST}"
if [ -n "${LUA:-}" ] && [ -x "$LUA" ]; then
    "$LUA" tools/check_squad_key.lua || rc=1
else
    echo "${YEL}skip${RST} (lua interpreter not found)"
fi

# A key is drawn as a key (#209). The half that is a value -- the owner's
# sentence, and that a resolved key LABEL never reaches it -- is unit-tested in
# test_client. This gate is for what no suite can execute: that the token Lua
# writes and the pattern the page parses are still one wire format, that the
# glyph resolves by command name and draws a dash when unbound, and that the
# surfaces carrying those sentences still render it. A mismatch does not error
# -- it puts a raw `{key:brptt}` in the middle of the owner's sentence.
echo "${DIM}== key glyphs ==${RST}"
if [ -n "${LUA:-}" ] && [ -x "$LUA" ]; then
    "$LUA" tools/check_key_glyphs.lua || rc=1
else
    echo "${YEL}skip${RST} (lua interpreter not found)"
fi

# The health and shield bars name themselves inside the pill (#210). The rule
# this protects is the one that change could have broken silently: the shield
# hides its numeral at 0, and the condition deciding that used to key off
# whether the bar had a caption -- which stopped being a valid proxy the moment
# these two got captions of their own.
echo "${DIM}== vitals bars ==${RST}"
if [ -n "${LUA:-}" ] && [ -x "$LUA" ]; then
    "$LUA" tools/check_vitals_bars.lua || rc=1
else
    echo "${YEL}skip${RST} (lua interpreter not found)"
fi

# Your own death and the end of the match are two surfaces sharing one word
# table, and the word and the spectator camera are one sequence on one deadline.
# The failure this catches is the two coming apart -- a second timer that agrees
# with the first only by coincidence, leaving dead air after the word or a
# camera that cuts away mid-sentence.
echo "${DIM}== death verdict ==${RST}"
if [ -n "${LUA:-}" ] && [ -x "$LUA" ]; then
    "$LUA" tools/check_death_verdict.lua || rc=1
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

# A reference to a BR.PlayerState member that does not exist. It is nil, not an
# error, so a half-finished rename reads as always-false in a comparison and
# TRUNCATES an ipairs list -- a suite that covered four states quietly covers two
# and stays green. #233 renamed DEAD to OUT across ~30 files and the whole suite
# passed with a site still on the old name; this is what noticed.
# AND IT COVERS tools/ AS WELL AS resources/, which is where the next one was
# already hiding: tools/test_lobbyseq.lua set a player's state to
# PlayerState.PLAYING in five places -- PLAYING is a MatchState -- so five cases
# had been exercising a nil state and passing. A test file is the WORST place
# for this to sit, because a suite that quietly stops testing something is the
# one thing that cannot be caught by another suite.
echo "${DIM}== player states ==${RST}"
if [ -n "${LUA:-}" ] && [ -x "$LUA" ]; then
    # shellcheck disable=SC2046
    "$LUA" tools/check_player_states.lua $(find resources tools -name '*.lua' | sort) || rc=1
else
    echo "${YEL}skip${RST} (lua interpreter not found)"
fi

# --- 3e. a BOOL native read as a Lua truth value ------------------------------
#
# THE MOST-SHIPPED DEFECT IN THIS REPOSITORY. Seven instances, and the seventh
# was the entire spawn/drop path -- forty-eight raw reads across spawn.lua,
# loading.lua, bus.lua and skydive.lua, every one of them in a wait.
#
# In Lua the number 0 is TRUTHY, and a FiveM native declared BOOL may answer
# 1/0. So `if HasCollisionLoadedAroundEntity(ped) then` is TRUE for a native
# that said no, and `while not HasCollisionLoadedAroundEntity(ped) do` is FALSE
# for the same no -- one proceeds without waiting, the other stops waiting.
# Either way the code carries on at exactly the moment it should hold, and in
# the placement path that means putting a player on ground that has not
# streamed.
#
# SIX RECURRENCES SAY REVIEW DOES NOT CATCH IT. Every one of them was found by a
# playtest, months later, wearing a symptom that looked like something else --
# a crate inside a building, a watchdog that never fired, sixty TaskPlayAnims a
# second. It is invisible in a diff because the wrong spelling is the natural
# one and the right spelling looks like paranoia.
#
# IT IS A RATCHET, NOT A WALL. There were 104 of these left when the gate landed
# and failing the build on all of them would have got the gate deleted, so the
# debt is recorded per file and per native in tools/bool_natives.baseline and
# the count may only go down. A new one -- or one more in a file that already
# had some -- is a red build; so is fixing one without lowering the number,
# because the room left behind is where instance eight goes. See the top of
# tools/check_bool_natives.lua for what the checker can and cannot see.
#
# VENDORED RESOURCES ARE EXCLUDED, on the same argument gate 4 makes: pma-voice
# is upstream's code, it is not edited here, and its baseline would churn on
# every version bump for faults that are not ours to fix.
echo "${DIM}== bool natives ==${RST}"
if [ -n "${LUA:-}" ] && [ -x "$LUA" ]; then
    boolfiles=$(find resources -name '*.lua' | while IFS= read -r f; do
        d=$(dirname "$f"); keep=1
        while [ "$d" != "." ] && [ "$d" != "/" ]; do
            [ -f "$d/VENDOR.json" ] && { keep=0; break; }
            d=$(dirname "$d")
        done
        [ "$keep" -eq 1 ] && echo "$f"
    done | sort)
    # shellcheck disable=SC2086
    "$LUA" tools/check_bool_natives.lua $boolfiles || rc=1
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
skipped_vendored=0

while IFS= read -r manifest; do
    resdir="$(dirname "$manifest")"

    # VENDORED THIRD-PARTY RESOURCES ARE SKIPPED, and this is the one gate where
    # skipping them makes the build MORE correct rather than less.
    #
    # The rule below is a bash approximation of FiveM's manifest resolver, and
    # the two disagree on `**`. In FiveM `server/**/*.lua` is RECURSIVE and
    # matches server/main.lua; in `[[ str == pat ]]` the pattern needs a literal
    # `/` after the `**`, so it does not. pma-voice's manifest uses exactly that
    # spelling, and this gate would fail a file the game loads every single time
    # it starts -- a red build about somebody else's correct code, which is how
    # a gate gets an --exclude and then gets ignored.
    #
    # The reason to skip rather than to teach `**` is what the gate is FOR. It
    # exists because client/screen.lua was written, committed and deployed by US
    # and never added to client_scripts, and nothing errored. Third-party
    # manifests are upstream's, they are not edited here, and a file undeclared
    # in one is upstream's bug to have. What IS true of vendored code -- licence
    # present, version recorded, patch log matching the patches, and the thing
    # actually reaching the box -- is asserted in `vendored third-party` below.
    if [ -f "$resdir/VENDOR.json" ]; then
        skipped_vendored=$((skipped_vendored+1))
        continue
    fi

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
    if [ "$skipped_vendored" -gt 0 ]; then
        echo "${GRN}ok${RST}   every .lua is declared in its manifest ($skipped_vendored vendored resource(s) skipped -- see 'vendored third-party')"
    else
        echo "${GRN}ok${RST}   every .lua is declared in its manifest"
    fi
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

# --- 4c-bis. vendored third-party resources -----------------------------------
#
# WHAT A VENDORED DIRECTORY OWES, ASSERTED RATHER THAN REMEMBERED.
#
# resources/[voice]/pma-voice is not ours. It is an upstream MIT release copied
# in whole so that three player-facing faults -- an unconditional debug print, a
# mic-click chirp with no off switch, and two key registrations outside our own
# key layer -- could be fixed at source instead of worked around from outside.
# Earlier rounds reported all three as "no convar exists, cannot be fixed",
# which was accepting the wrong constraint.
#
# Vendoring is cheap to do and expensive to keep, and it decays in four
# specific ways. Each one is a check below.
#
#   1. THE LICENCE GOES MISSING. MIT requires the notice to travel with the
#      code. This is the only item here that is a legal problem rather than an
#      engineering one.
#
#   2. NOBODY RECORDS WHAT VERSION THIS IS. Then the next upgrade opens with
#      archaeology -- diffing a directory against every tag until one nearly
#      matches -- and the local patches are what gets lost in it.
#
#   3. THE PATCH LOG AND THE PATCHES DRIFT. A local change with no entry is
#      invisible at the next bump and gets silently reverted; an entry with no
#      change is a fix somebody believes is in place and is not. So the marker
#      set in the tree and the id set in VENDOR.json must be EQUAL, both ways.
#      This is why the patches carry a greppable BR-PATCH marker at all.
#
#   4. IT NEVER REACHES THE BOX. tools/deploy.sh used to rsync exactly one
#      resource group because resources/ contained exactly one. A resource
#      vendored anywhere else would have been committed, reviewed, gated and
#      then never deployed -- source-only, which this project has shipped twice,
#      and which raises no error anywhere because the server just keeps running
#      whatever was already on disk. The check runs BOTH WAYS: every vendored
#      resource must be in deploy.sh's list, and every entry in that list must
#      be a real vendored resource.

echo "${DIM}== vendored third-party ==${RST}"
ven=0
ven_n=0

while IFS= read -r vjson; do
    [ -n "$vjson" ] || continue
    vdir="$(dirname "$vjson")"
    vrel="${vdir#resources/}"
    ven_n=$((ven_n+1))

    # 1. the licence
    if [ ! -f "$vdir/LICENSE" ]; then
        echo "${RED}FAIL${RST} $vrel is vendored but ships no LICENSE"
        echo "     MIT and everything like it requires the notice to travel with"
        echo "     the code. Restore it from upstream."
        ven=1
    fi

    # 2. the provenance
    for k in upstream version commit; do
        if ! grep -qE "\"$k\"[[:space:]]*:[[:space:]]*\"[^\"]+\"" "$vjson"; then
            echo "${RED}FAIL${RST} $vrel/VENDOR.json does not record \"$k\""
            ven=1
        fi
    done

    # 3. the patch log, both directions.
    #
    # VENDOR.json is excluded from the TREE side -- it names every id itself, so
    # including it would let the log satisfy itself and the check would pass
    # over a tree with no patches left in it at all.
    tree_ids=$(grep -rhoE 'BR-PATCH [0-9]+[a-z]?' "$vdir" \
                    --exclude='VENDOR.json' 2>/dev/null | sort -u)
    log_ids=$(grep -oE '"id"[[:space:]]*:[[:space:]]*"BR-PATCH [0-9]+[a-z]?"' "$vjson" \
              | grep -oE 'BR-PATCH [0-9]+[a-z]?' | sort -u)

    while IFS= read -r id; do
        [ -n "$id" ] || continue
        echo "${RED}FAIL${RST} $vrel: '$id' is in the source but not in VENDOR.json"
        echo "     An undeclared local change is invisible at the next upstream"
        echo "     bump, which is how a fix gets silently reverted."
        ven=1
    done < <(comm -23 <(printf '%s\n' "$tree_ids") <(printf '%s\n' "$log_ids"))

    while IFS= read -r id; do
        [ -n "$id" ] || continue
        echo "${RED}FAIL${RST} $vrel: VENDOR.json declares '$id' but no source file carries the marker"
        echo "     Either the patch was lost in an upstream bump, or the log is"
        echo "     describing a fix that is not actually in place."
        ven=1
    done < <(comm -13 <(printf '%s\n' "$tree_ids") <(printf '%s\n' "$log_ids"))

    # Every file the log names has to exist. A patch entry pointing at a path
    # upstream renamed is the same lie in a different shape.
    while IFS= read -r pf; do
        [ -n "$pf" ] || continue
        if [ ! -f "$vdir/$pf" ]; then
            echo "${RED}FAIL${RST} $vrel/VENDOR.json names a patched file that does not exist: $pf"
            ven=1
        fi
    done < <(grep -oE '"file"[[:space:]]*:[[:space:]]*"[^"]+"' "$vjson" \
             | sed -E 's/.*"file"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')

    # 4a. it has to deploy
    if ! grep -qF "\"$vrel\"" tools/deploy.sh; then
        echo "${RED}FAIL${RST} $vrel is vendored but tools/deploy.sh never syncs it"
        echo "     deploy.sh rsyncs VENDORED_RESOURCES and \$RESOURCE_GROUP and"
        echo "     nothing else, so this resource would be committed and gated"
        echo "     and then never reach the server. Add \"$vrel\" to"
        echo "     VENDORED_RESOURCES in tools/deploy.sh."
        ven=1
    fi
done < <(find resources -name 'VENDOR.json' 2>/dev/null | sort)

# 4b. and the list has to be real
while IFS= read -r listed; do
    [ -n "$listed" ] || continue
    if [ ! -f "resources/$listed/VENDOR.json" ]; then
        echo "${RED}FAIL${RST} tools/deploy.sh lists vendored resource '$listed', which has no resources/$listed/VENDOR.json"
        echo "     Either it was removed and the list was not, or it is vendored"
        echo "     without the provenance record this gate needs."
        ven=1
    fi
done < <(sed -n '/^VENDORED_RESOURCES=(/,/^)/p' tools/deploy.sh \
         | grep -oE '"[^"]+"' | tr -d '"')

if [ "$ven" -eq 0 ]; then
    if [ "$ven_n" -eq 0 ]; then
        echo "${GRN}ok${RST}   no vendored third-party resources"
    else
        echo "${GRN}ok${RST}   $ven_n vendored resource(s): licence kept, version recorded, patch log matches the source, deploy.sh syncs it"
    fi
else
    echo
    echo "     A vendored dependency is only cheap while its provenance and its"
    echo "     local patches are both written down. See resources/[voice]/pma-voice/VENDOR.json."
    rc=1
fi

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
    if [ "$verbs" != "branches configreport deploy kick spectate status switchref telemetry " ]; then
        echo "${RED}FAIL${RST} dispatch.sh verb set is '${verbs}', expected 'branches configreport deploy kick spectate status switchref telemetry '"
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
# pinned. brkick is the kick, brspectate points a moderator's camera at somebody;
# the other two are read-only dumps.
#
# brspectate JOINED THE LIST WITH SPECTATING (#192), AND THAT IS THIS GATE
# WORKING RATHER THAN BEING WORKED AROUND. It is the lightest write verb here --
# it removes nobody, changes no state a player can feel, and takes no free text
# -- but it does something to a player who has not been told, which is precisely
# the boundary this list guards. It resolves two licenses and hands them to
# br_core; the session, the camera and the audit rows are all over there.
rmdir_="resources/*/br_ringmaster"
if compgen -G "$rmdir_" >/dev/null 2>&1; then
    cmds=$(grep -rhoE "RegisterCommand\('[a-z]+'" $rmdir_ 2>/dev/null \
           | grep -oE "'[a-z]+'" | tr -d "'" | sort -u | tr '\n' ' ')
    if [ -n "$cmds" ] && [ "$cmds" != "bridents brkick brring brspectate " ]; then
        echo "${RED}FAIL${RST} br_ringmaster registers '${cmds}', expected 'bridents brkick brring brspectate '"
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

# THE OTHER DIRECTION OF THE SAME BOUNDARY: what the GAME lets the console do
# that it lets nobody else do. #202 added the first one -- `brcar`, which puts a
# vehicle in the world under `sv_entityLockdown relaxed`, where a trainer cannot.
#
# WHY IT NEEDS A GATE AND THE OTHER FORTY VERBS DO NOT. Every other command in
# br_core is registered RESTRICTED, which means the server console OR a live
# client holding the `br.admin` ACE, and that is the right boundary for all of
# them. This one is narrower on purpose -- the owner is the only person with
# console access, not even admins have it, and #202's rule is that this "must not
# become a route for anyone without console access to obtain a vehicle". The
# narrowing is one `tonumber(src) ~= 0` inside the handler, which is precisely
# the kind of line a refactor deletes without anything looking wrong afterwards:
# the verb keeps working, for everybody.
#
# AND `0` IS TRUTHY IN LUA, which is why the pattern is matched as an EQUALITY
# rather than by looking for the word `src`. `if src then` and `if not src then`
# are both real, both compile, and both are wrong in opposite directions -- the
# first admits every player, the second admits nobody.
#
# CreateVehicle IS SCOPED TO ONE FILE for server/kick.lua's reason above: it is
# the only server-side call in this tree that puts a networked entity in a match,
# and keeping it in the file that also holds the refused-vehicle detector means
# the spawn and the rule it must obey are reviewed on one screen.
vehfile_="resources/[fivem-royale]/br_core/server/vehicles.lua"
if [ -f "$vehfile_" ]; then
    if ! grep -q "RegisterCommand('brcar'" "$vehfile_"; then
        echo "${RED}FAIL${RST} brcar is not registered in $vehfile_"
        echo "     If it moved, move this gate with it -- and keep the console"
        echo "     check and the CreateVehicle call in the same file."
        boundary=1
    elif ! grep -qE 'tonumber\(src\) ~= 0' "$vehfile_"; then
        echo "${RED}FAIL${RST} brcar has lost its server-console gate"
        echo "     Expected 'tonumber(src) ~= 0' in $vehfile_."
        echo "     RESTRICTED is not that gate: it also admits any live client"
        echo "     holding br.admin, and #202's rule is console access only."
        echo "     It must stay an equality -- 0 is truthy in Lua, so both"
        echo "     'if src then' and 'if not src then' are wrong."
        boundary=1
    fi

    # ...and nowhere else in any server file may create one.
    #
    # BOTH SPELLINGS, AND #212 IS WHY THE SECOND ONE IS HERE. The verb used to
    # call server-side `CreateVehicle`, which is an RPC whose handle cannot be
    # routed into a bucket -- so it now calls `CreateVehicleServerSetter`. The
    # old pattern would not have matched the new name (it anchors on the paren
    # straight after `CreateVehicle`), so this gate would have gone on passing
    # while the capability it guards moved out from under it.
    strayveh=$(grep -rlE '(^|[^_[:alnum:]])CreateVehicle(ServerSetter)?[[:space:]]*\(' \
               "resources/[fivem-royale]"/*/server/*.lua 2>/dev/null \
               | grep -v 'br_core/server/vehicles\.lua' || true)
    if [ -n "$strayveh" ]; then
        echo "${RED}FAIL${RST} server-side vehicle creation outside br_core/server/vehicles.lua:"
        echo "$strayveh" | sed 's/^/     /'
        echo "     Putting a networked vehicle in a match is the one capability"
        echo "     that has to be reviewed beside the allowlist that limits it."
        echo "     CreateVehicleServerSetter raises serverEntityCreated and NOT"
        echo "     entityCreating, so the refused-vehicle detector never sees"
        echo "     what it makes -- the pre-check in that file is the only"
        echo "     thing there is, and it cannot guard a call somewhere else."
        boundary=1
    fi

    # AND THE PRE-CHECK ITSELF, which is load-bearing in a way it was not when
    # the verb shipped. While `brcar` used the RPC, a refused model would have
    # reached the `entityCreating` detector anyway and opened a case; the server
    # setter raises no such event, so BR.Config.IsAllowedVehicle in this file is
    # now the whole of the boundary. Deleting it would permit a refused model
    # that NOTHING would notice -- no case, no count, not a line in brvehicles.
    if ! grep -q 'IsAllowedVehicle' "$vehfile_"; then
        echo "${RED}FAIL${RST} brcar has lost its allowlist pre-check"
        echo "     BR.Config.IsAllowedVehicle must be consulted in $vehfile_"
        echo "     BEFORE anything is created. CreateVehicleServerSetter does"
        echo "     not raise entityCreating, so nothing downstream would catch"
        echo "     a refused model this verb let through."
        boundary=1
    fi
fi

# THE ANTICHEAT'S OWN READOUT AND ITS TEST LEVER, narrowed the same way and for
# a sharper reason than brcar's (#93).
#
# #93's property is that an OFFENDER IS SHOWN NOTHING AT ALL -- no message, no
# refusal feedback, no hint. `brshots` prints, per refused shot, the exact bound
# that refused it. RESTRICTED is not the right boundary for that: it admits the
# server console OR any live client holding `br.admin`, and the owner's standing
# rule is that nobody is exempt from incidents, admins included. So an admin can
# be the SUBJECT of the rows brshots prints, and a restricted readout would hand
# that person a live oracle for exactly which limit to stay under -- which is
# worse than telling them they were refused, because it tells them by how much.
#
# `brtestfire` bends the bounds the anticheat judges by, for every player at
# once. It carries the console gate AND the dev gate, and the dev gate is the
# one that keeps it off the public box entirely.
#
# AND `0` IS TRUTHY IN LUA, which is why both are matched as an EQUALITY rather
# than by looking for the word `src`: `if src then` admits every player and
# `if not src then` admits nobody. Both compile, both look right, both are wrong
# in opposite directions. Same trap the brcar gate above spells out.
dmgfile_="resources/[fivem-royale]/br_core/server/damage.lua"
if [ -f "$dmgfile_" ]; then
    for verb_ in brshots brtestfire; do
        if ! grep -q "RegisterCommand('$verb_'" "$dmgfile_"; then
            echo "${RED}FAIL${RST} $verb_ is not registered in $dmgfile_"
            echo "     If it moved, move this gate with it -- the verb and the"
            echo "     adjudication ring it reads belong on one screen."
            boundary=1
        fi
    done

    # One equality per verb. Counted rather than merely found, so deleting the
    # narrowing from ONE of the two cannot pass on the other one's line.
    gates_=$(grep -cE 'tonumber\(src\) ~= 0' "$dmgfile_" || true)
    if [ "$gates_" -lt 2 ]; then
        echo "${RED}FAIL${RST} brshots/brtestfire have lost a server-console gate"
        echo "     Expected 'tonumber(src) ~= 0' twice in $dmgfile_, found ${gates_}."
        echo "     RESTRICTED is not that gate: it also admits any live client"
        echo "     holding br.admin, and #93's rule is that an offender learns"
        echo "     NOTHING -- an admin can be the subject of these rows."
        echo "     It must stay an equality -- 0 is truthy in Lua."
        boundary=1
    fi

    # The dev gate on the lever, and the refusal-to-file guard that stops a
    # manufactured refusal becoming a real case against a playtester.
    if ! grep -q 'BR.Server.devMode' "$dmgfile_"; then
        echo "${RED}FAIL${RST} brtestfire has lost its dev-mode gate"
        echo "     Bending the validator's bounds must not be armable on the"
        echo "     public box, where a bent bound would stop real refusals"
        echo "     filing and no one would be told."
        boundary=1
    fi
    if ! grep -qE 'if forced then' "$dmgfile_"; then
        echo "${RED}FAIL${RST} damage.lua no longer guards noteRefusal on the test lever"
        echo "     A refusal manufactured by brtestfire must never open an"
        echo "     incident: it would file a case about a playtest, against the"
        echo "     person running it, with screenshots attached."
        boundary=1
    fi

    # ...and it must clear itself. Both lifecycle hooks, because the guarantee
    # the owner was given is "reset on match end or resource restart".
    for hook_ in 'br:match:destroyed' 'onResourceStop'; do
        if ! grep -q "AddEventHandler('$hook_'" "$dmgfile_"; then
            echo "${RED}FAIL${RST} damage.lua does not clear the test lever on $hook_"
            echo "     brtestfire is guaranteed to be impossible to leave armed."
            boundary=1
        fi
    done
fi

# THE THIRD DIRECTION: WHAT CAN MAKE THIS CLIENT PLAY A SOUND.
#
# Lighter than the two above and gated for the same reason they are -- the
# capability is small, and the thing that goes wrong is that it QUIETLY GROWS a
# second copy of itself.
#
# ═══ WHY A SOUND NEEDS A GATE AT ALL ═══
#
# Because a wrong sound fails SILENTLY, and this project has now paid for that
# three separate times: WIN and LOSER were silent in the wrong set; the fuel
# completion cue has been rejected twice by ear, with "I dislike this" and "this
# never played" indistinguishable from the driver's seat. The defence is that
# every sound comes out of ONE table -- br_lib/config/audio.lua -- reached BY
# KEY, so that /brsfx can audition it and one edit changes it everywhere.
#
# A PAIR INLINED AT A CALL SITE DEFEATS ALL OF THAT AT ONCE. It cannot be
# auditioned (nothing knows the key), it cannot be re-pointed with `brsfx bind`,
# and when it turns out to be silent the search for it starts with a grep. That
# is not hypothetical: `brsound` in client/debug.lua was a whole second audition
# command, invisible to the duplicate-command gate below because that one
# buckets by NAME and these were two names for one question.
#
# SO THE CALLERS ARE AN ALLOWLIST, exactly like DropPlayer above.
#
#   client/sfx.lua        owns the cue table, the throttle and /brsfx. The only
#                         file that is SUPPOSED to name a native audio call.
#   client/loot.lua       )  config/loot.lua's own openSound/pickupSound, which
#   client/inventory.lua  )  predate the cue table. NOT MOVED -- the pickup sound
#                            is one the owner heard and kept -- but pinned here
#                            so the list is two files rather than "wherever".
#
# Adding a fourth is a decision, not an accident; if it is the right one, this
# list is what gets updated.
# COMMENT LINES ARE STRIPPED FIRST, and that is not tidiness. This subject is
# the most heavily commented in the tree -- client/sfx.lua, client/fuel.lua,
# server/fuel.lua and config/audio.lua all discuss `PlaySoundFrontend(...)` by
# name in prose, because the whole point of those comments is that the native
# fails silently. A gate that counted prose would fail on a paragraph explaining
# why the rule exists, which is the fastest possible route to it being deleted.
sfxfiles_=$(
    for f in "resources/[fivem-royale]"/*/client/*.lua; do
        [ -f "$f" ] || continue
        if grep -v '^[[:space:]]*--' "$f" \
           | grep -qE '(^|[^_[:alnum:]])PlaySound(Frontend|FromEntity)[[:space:]]*\('; then
            echo "$f" | sed 's|.*/client/|client/|'
        fi
    done | sort -u | tr '\n' ' '
)
if [ -n "$sfxfiles_" ] \
   && [ "$sfxfiles_" != "client/inventory.lua client/loot.lua client/sfx.lua " ]; then
    echo "${RED}FAIL${RST} native sound calls live in '${sfxfiles_}'"
    echo "     expected 'client/inventory.lua client/loot.lua client/sfx.lua '"
    echo "     A set/name pair written at a call site cannot be auditioned with"
    echo "     /brsfx, cannot be re-pointed with 'brsfx bind', and fails SILENTLY"
    echo "     when the set is wrong. Add a cue to br_lib/config/audio.lua and"
    echo "     play it by key. If a fourth file really must, update THIS gate."
    boundary=1
fi

# AND THE AUDITION COMMAND IS WHERE THE TABLE IS. /brsfx has to be registered in
# the file that owns the cue table: a version of it anywhere else would be
# reading that table across files and would be the first half of growing a
# second one.
sfxfile_="resources/[fivem-royale]/br_core/client/sfx.lua"
if [ -f "$sfxfile_" ]; then
    if ! grep -q "RegisterCommand('brsfx'" "$sfxfile_"; then
        echo "${RED}FAIL${RST} brsfx is not registered in $sfxfile_"
        echo "     The audition command belongs in the file that owns the cue"
        echo "     table. If it moved, move this gate with it."
        boundary=1
    fi
    # THE PROBE IS THE POINT OF THE COMMAND, so it is pinned rather than
    # trusted. Without a real GET_SOUND_ID there is nothing to ask
    # HAS_SOUND_FINISHED about, and /brsfx silently goes back to being what it
    # was before the owner asked for this: a command that plays something and
    # cannot tell you whether anything came out.
    #
    # MATCHED AS A CALL, NOT AS A SUBSTRING, AND MUTATION TESTING IS WHY. The
    # first draft of this line was `grep -q 'HasSoundFinished'`, and a mutant
    # that renamed every occurrence to `HasSoundFinishedX` -- which is a probe
    # that calls a native that does not exist, i.e. no probe at all -- SURVIVED
    # it, because the old name is a prefix of the new one. The gate reported
    # green over a /brsfx that could no longer answer the only question it was
    # built to answer.
    if ! grep -qE 'HasSoundFinished[[:space:]]*[,)]' "$sfxfile_"; then
        echo "${RED}FAIL${RST} /brsfx has lost its silence probe"
        echo "     Expected HasSoundFinished in $sfxfile_. A wrong sound SET"
        echo "     plays nothing and reports nothing, which is indistinguishable"
        echo "     from a sound somebody disliked -- and that ambiguity has cost"
        echo "     this project two rounds of picking a fuel cue."
        boundary=1
    fi
    # AND IT READS THE ANSWER THROUGH THE 1-OR-true IDIOM. HAS_SOUND_FINISHED is
    # declared BOOL and a FiveM BOOL native may hand Lua a number; `0` IS TRUTHY
    # IN LUA, so a bare `if fin then` reports every pair as playing and the probe
    # becomes a decoration that always says yes. Six times in this codebase.
    if ! grep -qE 'v == 1 or v == true' "$sfxfile_"; then
        echo "${RED}FAIL${RST} /brsfx reads a BOOL native without the 1-or-true idiom"
        echo "     Expected 'v == 1 or v == true' in $sfxfile_."
        echo "     0 is truthy in Lua and a BOOL native may return 1, so a bare"
        echo "     truth test would make the silence probe answer 'played' for"
        echo "     every pair, including the silent ones it exists to catch."
        boundary=1
    fi
fi

# `brsound` IS GONE AND STAYS GONE. It was the second raw-pair audition command
# and it played through the fire-and-forget sound id -1, which cannot be asked
# whether it ever started -- so reaching for it instead of /brsfx lost exactly
# the answer the owner is trying to get. Two commands for one question is #137's
# lesson, and the duplicate-command gate cannot see this shape because the two
# had different names.
if grep -rq "RegisterCommand('brsound'" "resources/[fivem-royale]" 2>/dev/null; then
    echo "${RED}FAIL${RST} brsound is back"
    echo "     It is a second answer to the question /brsfx answers, without the"
    echo "     silence probe. Whoever reached for the wrong one would lose the"
    echo "     one piece of information they were after. Use 'brsfx play'."
    boundary=1
fi

if [ "$boundary" -eq 0 ]; then
    echo "${GRN}ok${RST}   the console can kick, ban, deploy, switch branch and READ config -- no raw stop/restart, no config writes"
    echo "${GRN}ok${RST}   brcar is console-only and CreateVehicle is scoped to the file that holds the allowlist"
    echo "${GRN}ok${RST}   brshots/brtestfire are console-only, dev-gated and cannot file a manufactured incident"
    echo "${GRN}ok${RST}   native sound comes from 3 known files, and /brsfx keeps its silence probe"
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

# --- 4b-ii. who gets TOLD that a case was opened (#214) -----------------------
#
# The rule: an incident CREATED during a match, from any source including
# `system`, shows the rest of the match the "See something suspicious?" notice,
# once per match, minus the offender and minus the reporter.
#
# WHAT MAKES THAT TRUE IS A SHAPE, NOT A CALL. The four creation paths -- refused
# shot, stripped weapon, refused vehicle, player report -- all emit
# `br:ringmaster:incident`; br_ringmaster writes the row and emits ONE
# acknowledgement, `br:incident:filed`; br_core/server/incident.lua announces
# from there and nowhere else. A fifth creation path is therefore covered on the
# day it is written, having called nothing -- which is the property #211's
# aircraft-occupancy filing depends on without knowing it does.
#
# SO THIS GATE PINS THE TWO CHOKE POINTS AND DELIBERATELY DOES NOT COUNT THE
# PATHS. Pinning "there are four creation paths" would fail the build for #211
# doing exactly the right thing, and whoever hit that would fix it by editing a
# number rather than by reading any of this. What must not change is that there
# is ONE announcer and ONE acknowledgement; add a second of either and the cap,
# the offender exclusion and the reporter exclusion all become things two places
# have to agree about.
#
# THE OFFENDER EXCLUSION IS #93 AND IS THE REASON THIS IS A GATE AT ALL. A
# second sender of the notice would not fail a test that nobody thought to
# write; it would just quietly tell somebody.
echo "${DIM}== incident notice surface ==${RST}"
inc_="resources/[fivem-royale]/br_core/server/incident.lua"
ring_="resources/[fivem-royale]/br_ringmaster/server/incident.lua"
if [ -f "$inc_" ] && [ -f "$ring_" ]; then
    notice_rc=0

    # One sender of the 'exists' notice. The 'killer' nudge on the same event
    # (server/players.lua) is a DIFFERENT occasion -- it answers a dead player
    # who asked about their killer -- and is not constrained here.
    hint_senders=$(grep -rn "TriggerClientEvent(BR\.Net\.REPORT_HINT" \
                   "resources/[fivem-royale]" 2>/dev/null \
                   | grep -c "'exists'" || true)
    hint_where=$(grep -rln "TriggerClientEvent(BR\.Net\.REPORT_HINT.*'exists'" \
                 "resources/[fivem-royale]" 2>/dev/null || true)
    if [ "$hint_senders" != "1" ] || [ "$hint_where" != "$inc_" ]; then
        echo "${RED}FAIL${RST} the 'See something suspicious?' notice has ${hint_senders} sender(s)"
        echo "     in: ${hint_where:-<none>}"
        echo "     Expected exactly one, in ${inc_}."
        echo "     That function is where the once-per-match cap, the #93"
        echo "     offender exclusion and the #180 reporter exclusion live. A"
        echo "     second sender does not break them loudly -- it just tells"
        echo "     somebody who was supposed to be told nothing."
        notice_rc=1
    fi

    # One minter of the acknowledgement every creation path converges on.
    ack_senders=$(grep -rn "TriggerEvent('br:incident:filed'" \
                  "resources/[fivem-royale]" 2>/dev/null | wc -l | tr -d ' ')
    ack_where=$(grep -rln "TriggerEvent('br:incident:filed'" \
                "resources/[fivem-royale]" 2>/dev/null || true)
    if [ "$ack_senders" != "1" ] || [ "$ack_where" != "$ring_" ]; then
        echo "${RED}FAIL${RST} br:incident:filed has ${ack_senders} emitter(s)"
        echo "     in: ${ack_where:-<none>}"
        echo "     Expected exactly one, in ${ring_}, sent only after DynamoDB"
        echo "     accepted the write. A second emitter would announce a case"
        echo "     that may not exist, and would spend the one notice this"
        echo "     match gets on it."
        notice_rc=1
    fi

    # A corroboration is not a creation. It must never mint the acknowledgement.
    if sed -n "/AddEventHandler('br:ringmaster:corroborate'/,/^end)/p" "$ring_" \
       | grep -q "br:incident:filed"; then
        echo "${RED}FAIL${RST} the corroboration handler emits br:incident:filed"
        echo "     A corroboration appends to a case that already exists. If it"
        echo "     mints an acknowledgement it becomes a creation, and the"
        echo "     second thing a cheater does in a round announces itself."
        notice_rc=1
    fi

    # And one place that asks br_ddb to write a case at all. This is the only
    # bypass the two pins above cannot see: a new detector that called
    # `br:ddb:putIncident` itself would file a perfectly good incident, mint no
    # acknowledgement, and tell nobody -- the feature would ship dead for that
    # path with every gate green, which is the exact failure the shared-coverage
    # gate's note about outbox.lua describes.
    put_askers=$(grep -rn "br:ddb:putIncident" "resources/[fivem-royale]" 2>/dev/null \
                 | grep -v "/br_ddb/" | wc -l | tr -d ' ')
    put_where=$(grep -rln "br:ddb:putIncident" "resources/[fivem-royale]" 2>/dev/null \
                | grep -v "/br_ddb/" || true)
    if [ "$put_askers" != "1" ] || [ "$put_where" != "$ring_" ]; then
        echo "${RED}FAIL${RST} br:ddb:putIncident is asked from ${put_askers} place(s)"
        echo "     in: ${put_where:-<none>}"
        echo "     Expected exactly one, in ${ring_}. Every creation path must"
        echo "     reach the database through it, because that is the function"
        echo "     that emits the acknowledgement the report notice hangs off."
        echo "     A path that writes its own row files a case nobody is told"
        echo "     about, and no other gate can see the difference."
        notice_rc=1
    fi

    if [ "$notice_rc" = "0" ]; then
        echo "${GRN}ok${RST}   one announcer, one acknowledgement, one writer; corroboration is none of them"
    else
        rc=1
    fi
fi

# --- 4c. the timeline entry kinds agree across the language boundary ----------
#
# THE SAME SHAPE AS THE VOICE DEFAULT ABOVE, WHICH IS THIS PROJECT'S SIGNATURE
# FAILURE: one value written down in two languages, with nothing comparing them.
#
# `matchTimeline` is a heterogeneous list discriminated on `kind`. The Lua side
# builds the entries; js-src/br_ddb/src/close.js projects them onto the DynamoDB
# update and DELIBERATELY DROPS a kind it does not recognise, so that a bug on
# the Lua side cannot put an unrenderable row on a moderation record.
#
# THAT DESIGN MAKES A DISAGREEMENT SILENT, WHICH IS EXACTLY WHY THIS GATE
# EXISTS. Both suites pin the kinds they already know about, so the case they
# cover is a kind being RENAMED. The case they cannot cover is the one that
# actually happens: a kind ADDED on the Lua side and never taught to close.js.
# Nothing fails then -- there is no test for a kind nobody has written a test
# for -- the build is green, and every entry of it is discarded on the way to
# the row. The feature ships dead, which this project has done before; see the
# shared-coverage gate's note about outbox.lua.
#
# It reads the Lua constants rather than restating them, so adding a kind
# extends this gate for free -- provided it is declared as a `*_KIND` local,
# which is what the resolver below matches on.

echo "${DIM}== timeline entry kinds ==${RST}"
kinds=0
ib_="resources/[fivem-royale]/br_lib/shared/incident_build.lua"
cj_="js-src/br_ddb/src/close.js"

if [ ! -f "$ib_" ] || [ ! -f "$cj_" ]; then
    echo "${YEL}skip${RST} incident_build.lua or close.js absent from this checkout"
else
    # EVERY `*_KIND` CONSTANT, NOT ONE NAMED ONE. This gate used to resolve
    # STRIP_KIND alone, which made its own promise -- "adding a kind extends this
    # gate for free" -- false: MATCH_CREATED_KIND was added beside it and would
    # have been checked by nothing. The pattern is the contract now, so the next
    # kind is covered the moment it is declared.
    declared=$(grep -oE "^local [A-Z_]+_KIND[[:space:]]*=[[:space:]]*'[a-z_]+'" "$ib_" \
               | grep -oE "'[a-z_]+'" | tr -d "'" || true)
    if [ -z "$declared" ]; then
        echo "${RED}FAIL${RST} cannot read any *_KIND out of br_lib/shared/incident_build.lua"
        echo "     This gate resolves \"local <SOMETHING>_KIND = '<kind>'\". If that"
        echo "     shape changed, reshape this gate with it -- do not delete it:"
        echo "     a kind close.js does not know is dropped in silence."
        kinds=1
    else
        for k in $declared; do
            if ! grep -qF "kind === '$k'" "$cj_"; then
                echo "${RED}FAIL${RST} close.js does not handle the timeline kind '$k'"
                echo "     br_lib/shared/incident_build.lua builds entries of that kind and"
                echo "     timelineEntry() drops every kind it does not name, so those"
                echo "     entries would never reach a single incident row -- and nothing"
                echo "     would error while they were being dropped."
                kinds=1
            fi
        done
    fi

    # AND THE THREE THAT WERE ALREADY THERE, so this gate covers the whole
    # vocabulary rather than only the newest member of it.
    for k in match_start match_end kill; do
        if ! grep -qF "'$k'" "$cj_"; then
            echo "${RED}FAIL${RST} close.js no longer handles the timeline kind '$k'"
            kinds=1
        fi
    done
fi

if [ "$kinds" -eq 0 ]; then
    echo "${GRN}ok${RST}   every timeline kind Lua writes is one close.js stores"
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

# --- 6. br_ddb bundle ---------------------------------------------------------
#
# The AWS SDK is flattened into one committed file because FXServer installs
# nothing and builds nothing. That buys a resource with no dependencies and
# costs exactly one hazard: source and bundle drifting apart, which presents as
# "my change did nothing" with nothing wrong in any log. Same failure the NUI
# bundle guard exists to prevent, so it gets the same treatment.
#
# A FINGERPRINT, NOT A REBUILD, SINCE #218. This section used to run esbuild
# and diff the result against the committed bundle. That is the stronger check
# and it never once executed: it needed js-src/br_ddb/node_modules, so it
# printed `skip` on every machine for months, and installing the deps turned it
# RED rather than green -- on a package-exports failure inside the AWS SDK's own
# dependency tree under Node 24, which no rebuild of ours fixes. A gate that
# fails for somebody else's reason is worse than one that never ran, because the
# two are indistinguishable from here.
#
# What runs instead is a sha256 over the source tree, recorded beside the bundle
# in dist/fingerprint.json. No node, no npm, no install -- so it runs on every
# machine, starting today. tools/br_ddb_fingerprint.sh carries the scheme and,
# more usefully, the list of what it does NOT prove: it catches "somebody edited
# the source and forgot to rebuild", it does not prove the bundle is correct,
# and it is not a tamper check -- the manifest is as editable as the bundle
# beside it.
#
# THE BAN RULE CASES NEEDED NO node_modules EITHER. They import only src/, which
# is pure arithmetic on data, and they were sitting behind the same dead guard:
# 193 cases that ran on no machine that had not done an install. They run now
# whenever Node is present, which is the only thing they ever needed.

echo "${DIM}== br_ddb bundle ==${RST}"
if [ ! -d js-src/br_ddb ]; then
    echo "     no br_ddb source, skipping"
else
    if fp=$(bash tools/br_ddb_fingerprint.sh --check 2>&1); then
        echo "${GRN}ok${RST}   br_ddb bundle matches the source fingerprint ($fp)"
    else
        echo "${RED}FAIL${RST} br_ddb bundle does not match js-src/br_ddb"
        echo "$fp" | sed 's/^/     /'
        rc=1
    fi

    if ! command -v node >/dev/null 2>&1; then
        echo "${YEL}skip${RST} node not installed -- ban rule cases not run"
    elif node js-src/br_ddb/scripts/test.mjs >/dev/null 2>&1; then
        echo "${GRN}ok${RST}   br_ddb ban rule passes its cases"
    else
        echo "${RED}FAIL${RST} br_ddb ban rule failed -- run: node js-src/br_ddb/scripts/test.mjs"
        rc=1
    fi
fi

# --- 6b. the same bundle, read off a BOX -------------------------------------
#
# The gate above is the one that matters and it runs before a commit lands: it
# proves the committed bundle was recorded against the committed source. It says
# nothing at all about the file a running server actually loaded, because a
# deploy happens afterwards and rsync can stop halfway.
#
# So `status` carries a second reading -- the deployed manifest, and the deployed
# bundle's real digest -- and the console compares the two. THIS SECTION DRIVES
# tools/dispatch.sh AGAINST FIXTURES, because every interesting case here is a
# case where a file is missing or wrong, and none of them can be produced by
# reading this repo.
#
# WHAT IS ACTUALLY BEING PINNED:
#
#   1. the shape, so the console's parser and this printf cannot drift apart;
#   2. that ABSENCE IS REPRESENTABLE -- no manifest, no bundle, and no hasher
#      each produce null rather than a value. A false green is the worst
#      outcome this feature can produce and null is what prevents it;
#   3. that a MISMATCH IS REPRESENTABLE. A check that cannot go red is a
#      decoration, and this one is one hash comparison away from always
#      agreeing with itself;
#   4. that the DEPLOYED copy is what gets read. Reading the clone would be a
#      check that passes by construction -- the clone's manifest and bundle
#      arrived in the same commit and always agree.
#
# NOTHING HERE IS A SECURITY PROPERTY. The manifest sits beside the bundle and
# is writable by whoever can write the bundle; this catches a deploy that did
# not finish, which is the realistic cause and very nearly the only one.

echo "${DIM}== br_ddb bundle over the wire ==${RST}"
mf_="resources/[fivem-royale]/br_ddb/dist/fingerprint.json"
js_="resources/[fivem-royale]/br_ddb/dist/server.js"
if [ ! -f tools/dispatch.sh ] || [ ! -f "$mf_" ] || [ ! -f "$js_" ]; then
    echo "     no dispatcher or no committed bundle, skipping"
elif ! command -v sha256sum >/dev/null 2>&1 \
     && ! command -v shasum >/dev/null 2>&1 \
     && ! command -v openssl >/dev/null 2>&1; then
    echo "${YEL}skip${RST} no sha256 tool -- bundle reading not driven"
else
    bx_=$(mktemp -d)
    bfail_=0

    # A box: a served clone, and a DEPLOYED resource tree that is not it.
    mkdir -p "$bx_/.git" "$bx_/resources/[gamemodes]/[fivem-royale]/br_ddb/dist"
    mkdir -p "$bx_/resources/[fivem-royale]/br_ddb/dist"
    dep_="$bx_/resources/[gamemodes]/[fivem-royale]/br_ddb/dist"
    clone_="$bx_/resources/[fivem-royale]/br_ddb/dist"

    ask_() {
        env BR_SERVER_ROOT="$bx_" BR_SRC_DIR="$bx_" BR_REPO_DIR="$bx_" \
            BR_TARGET_CATEGORY='[gamemodes]' SSH_ORIGINAL_COMMAND=status \
            bash tools/dispatch.sh 2>/dev/null
    }
    says_() {
        if ! printf '%s' "$2" | grep -qF "$3"; then
            echo "${RED}FAIL${RST} status bundle: $1"
            echo "     expected to contain: $3"
            echo "     got: $2"
            bfail_=1
        fi
    }

    want_="$(sed -n 's/.*"bundle"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$mf_" | head -1)"

    # 1. The healthy case. The digest on the line is the manifest's own, which
    #    is what makes the console say "Matches" rather than anything stronger.
    cp "$mf_" "$js_" "$dep_/"
    out_="$(ask_)"
    says_ 'a deployed pair reports its manifest' "$out_" "\"scheme\":\"br_ddb-source-fingerprint-1\""
    says_ 'and the bundle digest beside it'      "$out_" "\"onDisk\":\"$want_\""
    # THE COUNT IS READ OUT OF THE MANIFEST, NOT TYPED HERE. It used to be the
    # literal 713416, which made every legitimate rebuild of the bundle fail
    # this gate in a section that is about a DEPLOY going wrong -- a red that
    # says nothing about the thing it is checking and is fixed by editing the
    # test, which is how a gate stops being read. The property under test is
    # that the count reaches the console as a JSON NUMBER rather than a quoted
    # string; the surrounding `":` and the absence of a quote after it are what
    # assert that, and the value only has to agree with the manifest beside it.
    bytes_="$(sed -n 's/.*"bundleBytes"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$mf_" | head -1)"
    if [ -z "$bytes_" ]; then
        echo "${RED}FAIL${RST} status bundle: the manifest has no numeric bundleBytes"
        bfail_=1
    fi
    says_ 'with the byte count as a NUMBER'      "$out_" "\"bundleBytes\":$bytes_"

    # The whole line has to parse. This object is interpolated into the one
    # response the console polls; malformed here is not a wrong bundle reading,
    # it is the process state and the branch pin going dark to report a hash.
    if command -v node >/dev/null 2>&1; then
        if ! printf '%s' "$out_" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{JSON.parse(s)})' 2>/dev/null; then
            echo "${RED}FAIL${RST} status did not print valid JSON with the bundle block"
            echo "     $out_"
            bfail_=1
        fi
    fi

    # 2. A MISMATCH IS REACHABLE. One appended byte, which is what half an
    #    rsync leaves behind.
    printf '\n// truncated deploy\n' >> "$dep_/server.js"
    out_="$(ask_)"
    if printf '%s' "$out_" | grep -qF "\"onDisk\":\"$want_\""; then
        echo "${RED}FAIL${RST} a modified bundle still reported the manifest's digest"
        echo "     This check cannot go red, which makes it a decoration."
        bfail_=1
    fi
    says_ 'and still names what the manifest claims' "$out_" "\"bundle\":\"$want_\""

    # 3. THE DEPLOYED COPY WINS. The clone always agrees with itself, so a
    #    reader pointed at it could never see the case above.
    cp "$js_" "$clone_/"
    cp "$mf_" "$clone_/"
    out_="$(ask_)"
    if printf '%s' "$out_" | grep -qF "\"onDisk\":\"$want_\""; then
        echo "${RED}FAIL${RST} status read the clone's bundle, not the deployed one"
        echo "     A deploy that stops halfway is the whole failure this detects,"
        echo "     and it is invisible from the tree the deploy came from."
        bfail_=1
    fi

    # 4. ABSENCE, THREE WAYS, AND NONE OF THEM IS A MISMATCH.
    rm -f "$dep_/fingerprint.json"
    out_="$(ask_)"
    says_ 'no manifest reads as null, not as a fault' "$out_" '"manifest":null'

    cp "$mf_" "$dep_/"
    rm -f "$dep_/server.js"
    out_="$(ask_)"
    says_ 'no bundle reads as null'      "$out_" '"onDisk":null'
    says_ 'while the manifest still reports' "$out_" "\"bundle\":\"$want_\""

    rm -f "$dep_/fingerprint.json"
    out_="$(ask_)"
    says_ 'neither file reads as two nulls' "$out_" '{"manifest":null,"onDisk":null}'

    # 5. A manifest with no source hash is not a half manifest, it is a file we
    #    could not read -- the rule server-side fingerprint reading used to
    #    apply, kept now that the reading moved to the shell.
    printf '{\n  "scheme": "br_ddb-source-fingerprint-1"\n}\n' > "$dep_/fingerprint.json"
    out_="$(ask_)"
    says_ 'a manifest with no source hash reads as null' "$out_" '"manifest":null'

    rm -rf "$bx_"
    if [ "$bfail_" -eq 0 ]; then
        echo "${GRN}ok${RST}   status reports the deployed bundle, and every absence as null"
    else
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
