-- The client mirror.
--
-- Everything here is RECEIVED. Nothing in this file works out who is alive, who
-- is on which squad, or what the match is doing -- it applies what the server
-- said and nothing more.
--
-- That constraint is not stylistic. A client can only see players in its scope,
-- so any locally-derived answer is correct while everyone is bunched at the drop
-- and wrong for the rest of the match. tools/verify.sh fails the build if the
-- scope-limited natives appear in this directory.

BR = BR or {}

local S = BR.State
local lastSeq = -1

-- Set by the delta handler the moment MY state reads 'dead'; consumed by the
-- match-end summary (see the long note above its declaration site... which is
-- the STATE handler below). Declared HERE because the delta handler assigns
-- it -- an assignment above a later `local` would quietly write a global.
local diedThisMatch = false

-- HOW I died, from the kill feed (the one broadcast that carries a cause).
-- The verdict slam reads it: a storm death is not an "elimination".
local myDeathCause = nil
local myDeathByPlayer = false

-- Whether I am IN this round. A lobby bystander shares match.state with the
-- players fighting it out, and at ENDED they were shown the verdict slam of
-- a match they never entered while their lobby menu vanished. Set the
-- moment my own state becomes a match state; cleared at WAITING.
local roundParticipant = false

-- Forward declaration. The SQUAD_UPDATE handler sits above the definition
-- because it belongs with the other net handlers, not with the UI pushes.
local pushSquadOrParty

-- Boot timeline, so "the menu takes ages to appear" becomes a number instead of
-- an impression. Each stage records ms since this resource started; /brboot
-- prints them.
local boot = { t0 = GetGameTimer() }

--- Record the first time a boot stage happened.
--- @param stage string
local function mark(stage)
    if boot[stage] then return end
    boot[stage] = GetGameTimer() - boot.t0
end

-- --------------------------------------------------------------------------
-- Clock
-- --------------------------------------------------------------------------

local pingSentAt = 0

local function pingClock()
    pingSentAt = GetGameTimer()
    TriggerServerEvent(BR.Net.CLOCK_PING, pingSentAt)
end

RegisterNetEvent(BR.Net.CLOCK_PONG)
AddEventHandler(BR.Net.CLOCK_PONG, function(sentAt, serverAt)
    BR.Clock.sample(sentAt, GetGameTimer(), serverAt)
end)

-- --------------------------------------------------------------------------
-- Snapshot and deltas
-- --------------------------------------------------------------------------

--- Grant or release NUI focus for the current match state.
---
--- Called from BOTH the snapshot and the state handler, deliberately.
---
--- Doing it only on transition was a bug with a very confusing symptom: a
--- player joining a server already sitting in WAITING never receives a
--- transition, so they got a fully rendered lobby with no focus behind it --
--- visible, correct, and completely unclickable, with no cursor. It looked like
--- the UI was drawn wrong rather than simply not focused.
---
--- Both paths are safe to repeat: pushFocus is a no-op when the screen is
--- already on top, and RAISES it when it is buried. It used to ignore a screen
--- anywhere on the stack, which is what left the admin console unopenable for
--- a whole session after a match ended over it -- see the note on pushFocus.
--- @param state string

--- Screens that only make sense while standing in the lobby.
---
--- THEY HAVE TO BE POPPED WITH IT, or they outlive it. 'lobby' is not the
--- only thing that can be on the stack -- the locker and the settings screen
--- sit ON TOP of it -- and popping only 'lobby' leaves the stack non-empty,
--- which means NUI focus is never released and the player walks into warmup
--- holding a cursor with no menu under it (user, 2026-08-09).
---
--- Settings is in this list even though it can legitimately be opened
--- mid-match: the case here is specifically LEAVING the lobby, and a
--- full-screen opaque menu is not something to arrive at the warmup pad
--- inside. Reopening it takes one keypress.
local LOBBY_SCREENS = { 'settings', 'locker', 'lobby' }

local function applyFocusForState(state)
    -- NEVER during the teardown -- FOR PARTICIPANTS. At ENDED the server
    -- flips every roster entry to LOBBY (that is what drives the trip
    -- home), and granting focus then drew a MOUSE CURSOR over the verdict
    -- slam. But a BYSTANDER -- someone whose lobby menu is up while other
    -- people's match tears down, including a player whose own brleave is
    -- what ended it -- has no slam and every need of their cursor: popping
    -- theirs was the "lobby with no cursor" repro (squads, last leaver,
    -- 2026-08-04).
    if state == BR.MatchState.ENDED or state == BR.MatchState.CLEANUP then
        if roundParticipant then
            for _, s in ipairs(LOBBY_SCREENS) do
                TriggerEvent('br:ui:popFocus', s)
            end
        elseif S.me.state == BR.PlayerState.LOBBY then
            TriggerEvent('br:ui:pushFocus', 'lobby')
        end
        return
    end

    -- The lobby owns the screen when the MATCH is waiting -- or when this
    -- player personally is in the lobby while a match runs without them
    -- (left it, or never readied up). Match state alone was the wrong test
    -- the moment leaving a match became possible.
    if state == BR.MatchState.WAITING or S.me.state == BR.PlayerState.LOBBY then
        mark('focus')
        TriggerEvent('br:ui:pushFocus', 'lobby')
    else
        for _, s in ipairs(LOBBY_SCREENS) do
            TriggerEvent('br:ui:popFocus', s)
        end
    end
end

-- THE PAUSE MENU'S GAMEPLAY VERBS. br_ui owns the page and forwards the verb;
-- what it MEANS is br_core's, the same split the locker and inventory use.
AddEventHandler('br:ui:pauseAction', function(action)
    if action == 'lobby' then
        -- LEAVING THE MATCH LEAVES THE PARTY (owner's call, 2026-08-09), and
        -- the confirm says so before the button is pressed. Walking out on
        -- three people and staying in their party means they queue for the
        -- next match with somebody who has already gone -- the party would be
        -- holding a slot for a player who left, which is the same broken
        -- state a disconnect used to leave behind.
        --
        -- PASSED IN RATHER THAN SENT FROM HERE, and that is #124's last path.
        -- The party leave used to go out on this line, immediately, ahead of
        -- everything -- so the pause menu's own party card rewrote itself in
        -- front of the player before the screen had begun to darken. It now
        -- rides inside the leave, which does not send ANYTHING until the page
        -- reports the curtain solid black.
        --
        -- A direct call rather than ExecuteCommand('brleave'): the leave yields
        -- now, and a fire-and-forget console command cannot carry an argument or
        -- be sequenced against. See BR.Spawn.leaveMatch for the whole ordering.
        BR.Spawn.leaveMatch(S.party ~= nil and S.party.id ~= nil)

    elseif action == 'squad' then
        -- DEFERRED, ON PURPOSE, and this is the user's design (2026-08-09):
        -- the player stays with their squad for the rest of THIS match and is
        -- split from them at cleanup. Pulling someone out mid-match would
        -- strip three other people's health bars, blips and overhead names in
        -- the middle of a fight -- punishing them for a decision that was not
        -- theirs -- and would hand the leaver a free wallhack-free respawn
        -- into a solo they never queued for.
        --
        -- The party is what survives a match; the SQUAD dies with it. So the
        -- honest way to say "I am done with these people" is to leave the
        -- PARTY, which changes nothing about the round in progress and
        -- everything about the next one.
        TriggerServerEvent(BR.Net.SQUAD_LEAVE)
        TriggerEvent('br:ui:sendLocal', BR.Nui.TOAST, {
            text = 'You will leave the squad when this match ends.',
            tone = 'info', key = 'squad.leaving', ms = 6000,
        })
    end
end)

-- WHAT THE INTERFACE ACTUALLY BELIEVES ABOUT THE PARTY.
--
-- The pause menu's party controls are gated on "am I the leader", which is
-- `party.leader == party.you` -- three values that all come from here, and if
-- any one of them is nil every control silently disappears rather than
-- failing loudly (user, 2026-08-09: "doesn't seem like anything is working
-- other than leave party"). This prints the three.
RegisterCommand('brparty', function()
    local p = S.party
    print('=== party ===')
    print(('  me (you)   : %s'):format(tostring(S.me.src)))
    print(('  party id   : %s'):format(tostring(p and p.id)))
    print(('  leader     : %s'):format(tostring(p and p.leader)))
    print(('  am leader  : %s'):format(tostring(p ~= nil and p.leader == S.me.src)))
    print(('  members    : %d'):format(p and p.members and #p.members or 0))
    for _, m in ipairs((p and p.members) or {}) do
        print(('    %-4s %-18s %s'):format(m.src, m.name,
            m.leader and '(leader)' or ''))
    end
    print(('  squad id   : %s   size %d'):format(
        tostring(S.me.squadId), S.me.squadId and 1 or 0))
end, false)

-- GTA'S FRONTEND CLOSED AND IT WAS US WHO OPENED IT.
--
-- br_ui empties the focus stack before handing the screen to the engine's
-- menu -- it has to, because anything of ours left up draws OVER a scaleform.
-- Handing focus back is br_core's call for the same reason the pause watcher
-- above is: this file is the one that knows where the player actually is.
AddEventHandler('br:ui:frontendClosed', function()
    if S.me.state == BR.PlayerState.LOBBY then
        TriggerEvent('br:ui:pushFocus', 'lobby')
    end
end)

-- `br:ui:pauseRequest` AND ITS WATCHER ARE GONE (#138).
--
-- They were a SECOND way to raise the engine's frontend, living here in
-- br_core, alongside br_ui's. This one raised the menu after a 250ms timeout
-- and restored focus from a `pausePhase` tick watcher; br_ui's announces the
-- frontend to the page first (which is what actually stops the lobby drawing
-- over the scaleform -- see #122) and restores via `br:ui:frontendClosed`
-- above.
--
-- Two mechanisms meant two answers to "is the frontend up", and only one of
-- them told the page. Its two callers -- settings.lua's key-bindings button
-- and an orphaned `BR.NuiCb.PAUSE` in nui.lua that the page never invoked --
-- now go through BR.Pause.handOverToFrontend, leaving this with no emitter at
-- all. Deleted rather than kept "in case": a handler nothing fires is the
-- thirteenth instance of that pattern in this project, and had it been left,
-- restoring one caller would have run BOTH restore paths at once.

-- THE CURTAIN GOES UP BEFORE THE SCREEN CHANGES, NOT AFTER IT.
--
-- This flag is the whole of #124's first half. The owner's report, verbatim:
-- "I press ready up, get accepted into a match, then the lobby UI goes away and
-- cuts immediately to the in-game HUD/minimap/teleports my player, and THEN the
-- fade to black happens."
--
-- The mechanics were exactly that, and the order was not a timing accident --
-- it was structural. Being accepted into a match arrives as a roster delta;
-- this file forwarded it to the page the instant it landed, so the lobby went
-- and the HUD came in on that very frame. The curtain was raised afterwards, by
-- client/spawn.lua's gather loop, up to a tick later, and then slept on for a
-- fixed 450ms in the hope it had finished fading. Nothing anywhere WAITED for
-- it. Adjusting the sleep cannot fix that and has been tried three times.
--
-- So the state is held HERE, at the only door it can reach the page through,
-- until br_ui reports the curtain genuinely opaque. The player never sees the
-- change because it happens behind solid black -- which is what the curtain was
-- added for. Bounded, of course: BR.Spawn.awaitCover gives up and lets the
-- state through, because a stale lobby menu that never updates is worse than a
-- visible cut.
--
-- ONLY the two paint channels are held. Focus is not: it decides who owns the
-- CURSOR, not what is drawn, and re-asserting it after the hold is idempotent.
local uiHold = false

-- What "I am being taken into a match" looks like from MY OWN state. WARMUP is
-- the ordinary door; the rest are here because brforce can reach them directly
-- and a forced state change is a cut like any other.
local MATCH_ENTRY = {
    [BR.PlayerState.WARMUP]   = true,
    [BR.PlayerState.BUS]      = true,
    [BR.PlayerState.FREEFALL] = true,
    [BR.PlayerState.GLIDE]    = true,
    [BR.PlayerState.ALIVE]    = true,
}

--- Tell the UI what state the match is in.
---
--- Called from EVERY path that learns the state, not only transitions.
---
--- It used to be sent only from the transition handler, which was wrong in a
--- way that took a br_ui restart to expose: restarting the interface mid-warmup
--- re-seeded the Lua mirror from a snapshot, but nothing pushed the state
--- across the bridge, so the freshly loaded page sat on its default -- a full
--- lobby screen drawn over a match already in progress -- until the next
--- transition happened to correct it.
---
--- The digest path makes it self-healing: if the UI's idea of the state is ever
--- wrong, it is wrong for at most half a second.
---
--- ...UNLESS THE CURTAIN IS STILL GOING UP. See uiHold directly below: the one
--- moment self-healing is wrong is the moment we are deliberately holding the
--- old picture on screen because the new one is a cut.
local function pushMatchState()
    if uiHold then return end
    TriggerEvent('br:ui:sendLocal', BR.Nui.STATE, {
        state     = S.match.state,
        mode      = S.match.mode,
        endsAt    = S.match.endsAt,
        serverNow = BR.Clock.now(),
        -- The UI needs to know whether the teardown is OURS: participants
        -- get the verdict-slam choreography; a lobby bystander keeps their
        -- menu.
        participant = roundParticipant,
    })
end

--- Raise the curtain, and hold the interface still until it is opaque.
---
--- The sequence this exists to make real: cover the screen, THEN change what is
--- on it, THEN uncover. See the long note on `uiHold` above for what it was
--- doing instead and why no amount of sleeping fixed it.
---
--- The trip to the warmup pad (client/spawn.lua) raises the same curtain a tick
--- later and lowers it once the pad is genuinely under the player's feet -- so
--- the cover this puts up is HANDED OVER rather than duplicated, and the
--- curtain watchdog there is the net under a trip that never starts.
local function enterMatchBehindCurtain()
    if uiHold then return end
    uiHold = true

    local wait = BR.Config.Match.coverWaitMs or 2500

    --- Let the held state through, and never twice.
    local function release()
        if not uiHold then return end
        -- The screen is black (or the page never answered and we are past the
        -- deadline). Everything the hold suppressed now goes out at once, and
        -- FORCED: BR.PushHud dedupes against what it last sent, and what it
        -- last sent is the lobby it was refusing to update.
        uiHold = false
        pushMatchState()
        BR.PushHud(true)
        applyFocusForState(S.match.state)
    end

    -- THE HOLD MUST NOT BE ABLE TO OUTLIVE THE THREAD THAT OWNS IT.
    --
    -- Everything below runs in a bare Citizen thread, and a bare thread that
    -- throws simply stops -- no error handler, no loop registry to suspend the
    -- callback and say so. If that happened here the interface would be frozen
    -- on the lobby menu for the rest of the session with a live match running
    -- underneath it: strictly worse than the cut this exists to hide, and the
    -- kind of failure this file has been bitten by before. So the release is
    -- ALSO scheduled independently, on a clock nothing in the thread can break.
    Citizen.SetTimeout(wait * 2, release)

    Citizen.CreateThread(function()
        BR.Spawn.curtain(true, 'dropping')
        BR.Spawn.awaitCover('curtain', wait)
        release()
    end)
end

--- Keep the participant flag current from MY state. Called wherever my
--- state can change (snapshot, deltas).
-- The last state this ran for, so a TRANSITION can be told from a repeat.
local lastNoted = nil

-- States where the gamemode's own full-screen UI takes the screen: the death
-- verdict, the spectator handoff, the lobby menu.
local OUR_SCREEN = {
    [BR.PlayerState.DEAD]       = true,
    [BR.PlayerState.SPECTATING] = true,
    [BR.PlayerState.LOBBY]      = true,
}

-- ═══════════════════════════════════════════════════════════════════════════
-- MATCH-SCOPED SURFACES
--
-- A SURFACE RAISED INSIDE A MATCH COMES DOWN WHEN THE MATCH IS OVER FOR THIS
-- PLAYER, AND THAT IS A RULE RATHER THAN A LINE IN ONE HANDLER (#204).
--
-- ═══ WHAT WENT WRONG ═══
--
-- The death word (below) is the first surface in this client with a lifetime of
-- its OWN -- raised at the moment of death, taken down on a clock -- rather
-- than one borrowed from the match state. It was cleared on the transitions a
-- round normally passes through and on nothing else, so every exit that is not
-- "the match ended underneath you" carried it out of the match and into the
-- lobby, where it means nothing.
--
-- Leaving mid-match is the one the owner found (2026-08-22). Going down first
-- is only what makes it instant: server/match.lua's leaveMatch eliminates a
-- DBNO player on the way out ("leaving while alive IS an elimination"), so the
-- DEAD delta and the LOBBY delta arrive in the SAME batch -- the word goes up
-- on the first and the lobby appears underneath it on the second. The identical
-- bug needs no knockdown at all: die, then use Leave Match inside the window.
--
-- ═══ WHY A REGISTRY AND NOT A THIRD CALL TO clearDeathVerdict ═══
--
-- Everything else this client draws mid-match -- the DBNO overlay, the spectate
-- hint, the vehicle bars -- is safe from this only because App.tsx mounts it
-- inside <Hud>, whose visibility follows the match state. That is protection by
-- POSITION, not by rule, and DeathVerdict is mounted outside that wrapper on
-- purpose: `hudUp` goes false the instant a match is decided and the word has
-- its own end. The next surface with the same reason to sit outside it repeats
-- this exactly, which is how a fix per screen becomes a bug per screen.
--
-- So the edge is named once, here, and a surface joins it by registering.
--
-- ═══ THE EDGES, ALL OF THEM ═══
--
--   * MY OWN STATE BECOMES LOBBY -- the one transition every exit passes
--     through, whichever door was used: Leave Match, the ENDED sweep home, a
--     match destroyed under a dead player (server/match.lua's destroy, which
--     never reaches ENDED at all), an admin resetting a stuck round. It sits
--     with BR.NotifyClear() in noteMyState below, which is the same broom on
--     the same edge for the same reason.
--   * THE MATCH STATE IS ANYTHING BUT PLAYING -- including WAITING, which is
--     where a LEAVER's mirror settles: server/broadcast.lua sends the lobby
--     digest to players in no match, and the digest replays that transition
--     locally for exactly this kind of teardown.
--   * A REVIVE -- a death that was undone must take its word with it. #144's
--     held death really does put the roster through DEAD (server/combat.lua
--     says so in as many words), so the word genuinely goes up for a player who
--     is about to be stood back up.
--   * THE CAMERA MOVES ON TO SOMEBODY ELSE -- a spectate session opening. This
--     is the one the owner found on 2026-08-22 ("The verdict text still shows
--     while spectating for some reason") and it is NOT a match exit, which is
--     why the first four did not cover it: starting to spectate is the opposite
--     of leaving. See the handler below for why the word is nonetheless done.
--   * br_core STARTING -- THE PAGE OUTLIVES THIS RESOURCE, and see the note on
--     `force` below for why that one is not like the others.
--
-- ═══ WHAT IS DELIBERATELY NOT IN HERE ═══
--
-- The match-end verdict SCREEN (BR.Nui.SUMMARY, further down). It is not a
-- surface raised inside a match; it IS the teardown. It is gated on the
-- teardown in App.tsx and the page drops it itself at WAITING -- and the LOBBY
-- flip that this rule fires on is the very transition that raises it, so
-- registering it would delete the screen it exists to show.
--
-- ═══ AND NOTHING HERE TOUCHES FOCUS ═══
--
-- The death word takes no input and is not on the focus stack; br_ui/client/
-- nui.lua owns that stack and its own comments record what getting near it
-- costs. A dismissal that also popped focus could strand a player who dies,
-- leaves and rejoins with no cursor and no way to open the pause menu -- worse
-- than the bug being fixed, so this touches none of it.
-- ═══════════════════════════════════════════════════════════════════════════

--- Registered surfaces, in registration order. Each is { name, dismiss }.
local matchSurfaces = {}

--- Declare a surface that belongs to a match in progress.
---
--- GLOBAL so a surface can register from the file that owns it instead of being
--- listed here. That is the point of the registry: the EDGE lives in one place
--- and what each screen knows about itself stays with that screen.
---
--- @param name string  printed on the forced path below, which is the one
---        dismissal with no other evidence that it happened
--- @param dismiss fun(force: boolean)  take it down. `force` means "send even
---        if you believe it is already down" -- see dismissMatchSurfaces.
function BR.MatchSurface(name, dismiss)
    matchSurfaces[#matchSurfaces + 1] = { name = name, dismiss = dismiss }
end

--- The match is over for this player: take down everything it raised.
---
--- @param force boolean|nil  pass true only when this client's own idea of what
---        is on screen cannot be trusted -- which is precisely one case, br_core
---        restarting in front of a page that did not. Compared against `true`
---        rather than tested for truth, because in Lua 0 is true and a FiveM
---        BOOL native answers 1.
local function dismissMatchSurfaces(force)
    local hard = force == true
    local said = {}
    for _, s in ipairs(matchSurfaces) do
        s.dismiss(hard)
        said[#said + 1] = s.name
    end

    -- SAID OUT LOUD ONLY ON THE FORCED PATH, and only because that one is
    -- otherwise undiagnosable: "I restarted br_core and the word is still
    -- there" and "the correction went out and the page ignored it" look
    -- identical from a chair. Every other dismissal has a state change next to
    -- it in the log. Once per br_core start, which is not a hot path.
    if hard and #said > 0 then
        print(('[br_core] match surfaces dropped on start: %s')
            :format(table.concat(said, ', ')))
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- ...AND THE CAMERA MOVING ON IS AN EDGE TOO, THOUGH IT IS NOT AN EXIT
--
-- "The verdict text still shows while spectating for some reason." -- the owner,
-- 2026-08-22.
--
-- ═══ WHAT THE WORD'S LIFETIME ACTUALLY IS ═══
--
-- Not "ten seconds". The config that carries the number says so in the owner's
-- own sentence -- "the verdict text ONLY should be shown for ~10 seconds THEN
-- the text can immediately disappear AS WE SNAP INTO SPECTATING" -- and
-- BR.DeathVerdictUp below already names the pair: the word and the camera are
-- ONE SEQUENCE, not two timers that happen to be the same length. The real
-- lifetime is "from my death until the camera moves on, and no longer than
-- deathVerdictMs". deathVerdictMs is the CEILING on that, not the definition.
--
-- ═══ WHY IT LEAKED, GIVEN client/spectate.lua ALREADY HOLDS THE CAMERA ═══
--
-- The hold is real and it is not enough. spectate.lua's SLOW `spectate.open`
-- loop waits on BR.DeathVerdictUp() before it asks for a target -- so the
-- AUTOMATIC snap cannot outrun the word. But that loop is not the only way a
-- session starts: `ask(dir)` refuses ALIVE, DBNO, BUS, FREEFALL, GLIDE and
-- WARMUP and admits DEAD, so the arrow keys work the instant a player dies --
-- and the hint that tells them the arrows exist is on screen by then. A dead
-- player who presses Left or Right inside the window gets a camera on somebody
-- else with their own verdict still written across it. That is the report.
--
-- ═══ WHY THE EDGE IS HERE AND NOT KEYED ON PlayerState.SPECTATING ═══
--
-- Because nothing ever writes that state. `BR.PlayerState.SPECTATING` is read in
-- six places across this client and the server and ASSIGNED IN NONE -- grep it.
-- A rule hung on it would be a rule that never fires, tested green by a suite
-- that sets the state by hand and dead in the game. The fact that actually
-- changes is the session, and the session arrives on this wire.
--
-- ═══ ONLY THE OPENING EDGE, AND NOT FOR AN ADMIN ═══
--
-- SPECTATE_SET is the 4 Hz position feed as well as the start message, so `on`
-- latches and only the transition into a session calls the registry. Dismissal
-- is idempotent by contract, so this is tidiness rather than correctness today
-- -- but the next surface to register need not be, and a rule that fired four
-- times a second for the rest of a match would be the thing that found out.
--
-- AND AN ADMIN SPECTATOR IS NOT OUT OF A MATCH. The console's Spectate button
-- requires only that the admin be in game; they may be alive, mid-fight, with
-- every surface a live match raises legitimately on screen. `admin` is the
-- server's own flag on this envelope and it is the discriminator client/
-- spectate.lua already trusts for the same distinction one file over.
--
-- ═══ AND IT DOES NOT TOUCH THE VERDICT'S NORMAL APPEARANCE ═══
--
-- On the ordinary path the word is already down when this fires: the SLOW loop
-- holds until BR.DeathVerdictUp() goes false, THEN asks, and the reply comes
-- back after that. clearDeathVerdict returns on its first line when the word is
-- down, so a player who dies and never presses anything sees exactly what they
-- see today, for exactly as long. A player who never spectates at all never
-- reaches this handler.
-- ═══════════════════════════════════════════════════════════════════════════

--- Is a spectate session running, as far as this file is concerned?
local spectatingNow = false

RegisterNetEvent(BR.Net.SPECTATE_SET)
AddEventHandler(BR.Net.SPECTATE_SET, function(d)
    if type(d) ~= 'table' then return end

    -- READ EXACTLY AS client/spectate.lua READS IT, deliberately. Two handlers
    -- on one message that disagreed about what a stop is would be a latch that
    -- says "spectating" while the camera is down, and the disagreement would be
    -- invisible until the next death.
    if d.stop then
        spectatingNow = false
        return
    end

    if d.admin == true then return end
    if spectatingNow then return end
    spectatingNow = true

    dismissMatchSurfaces()
end)

local function noteMyState()
    local st = S.me.state

    -- DYING WITH THE PAUSE MENU UP LEFT IT UP.
    --
    -- GTA's pause menu is a separate frontend, not a NUI layer, so nothing in
    -- br_ui can cover it and nothing in br_ui closes it. A player killed while
    -- looking at the map arrived in the lobby with the pause screen still
    -- underneath our menu, with no way to reach either cleanly (user,
    -- 2026-08-06). Closing it on the transition is the whole fix -- and only
    -- on the TRANSITION, so a player who opens the pause menu in the lobby on
    -- purpose keeps it.
    if st ~= lastNoted then
        local was = lastNoted
        lastNoted = st
        if OUR_SCREEN[st] and IsPauseMenuActive() then
            SetFrontendActive(false)
        end

        -- READY UP -> ACCEPTED INTO A MATCH is the cut the owner reported, and
        -- this is the edge it happens on: the server names me a participant and
        -- the whole screen changes underneath the player in one frame. Cover it
        -- first (#124).
        --
        -- Only from the LOBBY, and only on a real transition. A snapshot that
        -- re-seeds a client already standing in a match -- a reconnect, a
        -- br_ui restart -- has nothing to hide and must not drop a black
        -- rectangle over a live fight; `was` is nil in exactly that case.
        if was == BR.PlayerState.LOBBY and MATCH_ENTRY[st] then
            enterMatchBehindCurtain()
        end

        -- STICKY NOTICES ARE ABOUT THE MATCH, AND THE MATCH IS OVER FOR ME.
        --
        -- A sticky notice describes a state that is still true; landing in
        -- the lobby means none of them are. Every sender is supposed to
        -- withdraw its own, and each of them will -- but a player who
        -- brleaves mid-flight, or dies, walks out from under whatever code
        -- was going to do it. This is the broom, on the one edge that covers
        -- all of those at once, and it is why the sticky flag is safe to
        -- hand out.
        --
        -- ...AND SO IS EVERY SURFACE THE MATCH RAISED (#204). The same edge and
        -- the same argument one paragraph up: this is the transition every way
        -- out of a match passes through, so it is the one place that does not
        -- have to know which door was used.
        if st == BR.PlayerState.LOBBY then
            BR.NotifyClear()
            dismissMatchSurfaces()
        end
    end
    if st == BR.PlayerState.WARMUP or st == BR.PlayerState.BUS
       or st == BR.PlayerState.FREEFALL or st == BR.PlayerState.GLIDE
       or st == BR.PlayerState.ALIVE or st == BR.PlayerState.DBNO then
        if not roundParticipant then
            roundParticipant = true
            pushMatchState()
        end
    elseif st == BR.PlayerState.LOBBY
       and not diedThisMatch
       and S.match.state ~= BR.MatchState.ENDED
       and S.match.state ~= BR.MatchState.CLEANUP then
        -- Becoming LOBBY while the match is still running means I LEFT the
        -- round (brleave). Someone who once touched the warmup and then sat
        -- out kept the flag, and the match's ending slammed ELIMINATED over
        -- their lobby menu (live report, twice). The teardown flip to LOBBY
        -- is different: by then match.state already reads ended, so real
        -- participants keep their verdict.
        --
        -- ...AND A DEATH IS NOT A LEAVE, WHICH IS THE OTHER HALF OF THAT TEST
        -- AND WAS MISSING. "By then match.state already reads ended" is true of
        -- the SERVER and is an assumption about this client's mirror: the
        -- teardown sweep is what flips a dead player to LOBBY, and if the ENDED
        -- broadcast has not been processed here yet -- lost, or simply beaten by
        -- the delta -- the mirror still reads `playing` and this branch reads a
        -- corpse being swept home as a voluntary leave. It then withdraws the
        -- one flag the verdict screen is gated on, permanently, and the player
        -- who died gets no verdict at all (owner, 2026-08-18). `diedThisMatch`
        -- tells the two apart with the fact that actually distinguishes them:
        -- nobody who died in this round walked out of it. It is set by the
        -- roster delta that made me DEAD and cleared by the next match, so a
        -- player who dies and THEN uses Leave Match keeps the participation
        -- they earned by dying in the round, which is the answer that matches
        -- their placement.
        if roundParticipant then
            roundParticipant = false
            pushMatchState()
        end
    end
end

RegisterNetEvent(BR.Net.SNAPSHOT)
AddEventHandler(BR.Net.SNAPSHOT, function(payload)
    mark('snapshot')
    local was = S.match.state
    S.roster = payload.roster or {}
    S.match.state  = payload.match.state
    S.match.mode   = payload.match.mode
    S.match.endsAt = payload.match.endsAt

    -- The same WAITING replay the digest performs (see its handler for the
    -- full note). It must live HERE too: a match being destroyed re-seeds
    -- its players with a snapshot, which used to update the mirror
    -- SILENTLY -- so when the digest arrived the state had already
    -- "changed" and the edge never fired. The players it stranded were the
    -- ones under the end-of-match black hold, whose release rides this
    -- exact transition (live repro, 2026-08-04: both storm deaths stuck
    -- black over the lobby menu).
    if S.match.state ~= was and S.match.state == BR.MatchState.WAITING then
        TriggerEvent(BR.Net.STATE, {
            state     = S.match.state,
            endsAt    = S.match.endsAt,
            serverNow = payload.serverNow,
            meta      = { from = was, reason = 'snapshot' },
        })
    end
    S.alive        = payload.alive or 0
    S.squadsAlive  = payload.squadsAlive or 0
    S.storm        = payload.storm

    -- A snapshot supersedes anything queued, so it resets the sequence rather
    -- than being discarded as stale. Otherwise a client that reconnects, or
    -- restarts br_ui, would sit frozen behind an old sequence number forever.
    lastSeq = payload.seq or 0

    local me = S.roster[S.me.src]
    if me then
        S.me.squadId = me.squadId
        S.me.state   = me.state
        S.me.hp      = me.hp
        S.me.armour  = me.armour
    end
    noteMyState()

    BR.PushHud(true)
    pushMatchState()
    applyFocusForState(S.match.state)
end)

RegisterNetEvent(BR.Net.ROSTER_DELTA)
AddEventHandler(BR.Net.ROSTER_DELTA, function(batch)
    -- Deltas are only safe because a snapshot can always re-seed us. If one
    -- arrives out of order, dropping it is correct: the next digest corrects the
    -- counts, and the next snapshot corrects everything.
    if batch.seq and batch.seq <= lastSeq then return end
    lastSeq = batch.seq or lastSeq

    for _, d in ipairs(batch.deltas or {}) do
        if d.op == 'add' then
            S.roster[d.src] = d.e

        elseif d.op == 'remove' then
            S.roster[d.src] = nil

        elseif d.op == 'update' then
            local entry = S.roster[d.src]
            if entry then
                for k, v in pairs(d.e or {}) do entry[k] = v end
                -- Cleared fields arrive as a name list, because a nil value
                -- cannot survive serialisation -- it simply vanishes from the
                -- table and the client keeps the stale value.
                for _, k in ipairs(d.clear or {}) do entry[k] = nil end
            else
                -- An update for someone we do not know about means we missed
                -- their add. Take what we were given rather than dropping them.
                S.roster[d.src] = d.e
            end
        end

        if d.src == S.me.src and d.e then
            local wasState = S.me.state
            for k, v in pairs(d.e) do
                if S.me[k] ~= nil or k == 'squadId' then S.me[k] = v end
            end
            -- The clear list applies to ME too. Without this, S.me.squadId
            -- outlived the match until the next full snapshot happened to
            -- re-seed it -- a window where the squad/party fallback picked
            -- the wrong branch.
            for _, k in ipairs(d.clear or {}) do
                if k == 'squadId' or S.me[k] ~= nil then S.me[k] = nil end
            end
            -- MY state changing can move screen ownership: becoming LOBBY
            -- while a match runs (left it) must summon the lobby and its
            -- focus, and leaving LOBBY must release them.
            if S.me.state ~= wasState then
                if S.me.state == BR.PlayerState.DEAD then
                    diedThisMatch = true
                    BR.NoteDeath()
                end
                noteMyState()
                applyFocusForState(S.match.state)
            end
        end
    end

    BR.PushHud()
end)

RegisterNetEvent(BR.Net.DIGEST)
AddEventHandler(BR.Net.DIGEST, function(d)
    S.alive       = d.alive or 0
    S.squadsAlive = d.squadsAlive or 0

    -- The digest is the safety net under the transition broadcast: if the UI's
    -- state is ever wrong -- a missed transition, a br_ui restart, a snapshot
    -- that raced the page load -- this corrects it within half a second.
    -- Pushed only on a CHANGE, so the net is free when nothing is wrong.
    local was, wasEnd, wasMode = S.match.state, S.match.endsAt, S.match.mode
    S.match.state  = d.state or S.match.state
    S.match.endsAt = d.endsAt or S.match.endsAt
    -- Mode is carried here as well as on STATE because a late joiner is
    -- attached to a match that is ALREADY in warmup and so never hears a
    -- transition -- this is the only channel that reaches them.
    S.match.mode   = d.mode or S.match.mode
    if S.match.state ~= was or S.match.endsAt ~= wasEnd
       or S.match.mode ~= wasMode then
        pushMatchState()
        applyFocusForState(S.match.state)
    end

    -- REPLAY THE TWO TRANSITIONS whose absence strands the player: WAITING and
    -- ENDED. Under parallel matches, STATE events are scoped to a match's
    -- audience -- a player who LEAVES one stops hearing about it, and their
    -- digest flipping to WAITING is the only signal the round is over for them.
    -- Every subsystem keyed on the STATE event (route line, markers, island,
    -- the skydive latch) must still run its teardown, so that transition is
    -- re-fired locally -- TriggerEvent reaches the same handlers.
    --
    -- ENDED IS THE SECOND ONE, AND IT IS HERE BECAUSE IT IS THE TERMINAL ONE.
    -- Two things in this whole client hang off `state == ENDED` and NOTHING
    -- else raises either of them: the verdict screen (the SUMMARY below) and
    -- BR.Spawn.toLobby(true), which is the trip home. A client that does not
    -- process that one event is left standing in a finished match -- for a
    -- player who died, a corpse on the ground with no verdict, no lobby and
    -- nothing in any log, because nothing failed; a message simply did not
    -- arrive. That is the owner's report of 2026-08-18 word for word ("the
    -- verdict screen was never shown ... effectively a real corpse but stuck
    -- unable to do anything. No errors were logged"), and it had no safety net
    -- while every lesser transition did.
    --
    -- THE CHANGE GATE IS WHAT MAKES THIS SAFE, and it is why the two names
    -- below are the only ones here. This fires only when the digest MOVED the
    -- mirror, so the real event arriving first makes it a no-op -- and for
    -- ENDED the real event always goes out first by construction:
    -- BR.Match.transition broadcasts BEFORE onEnter (server/match.lua says the
    -- ordering is a contract), so a digest carrying 'ended' cannot beat the
    -- transition that produced it. BUS is the state where that is NOT true --
    -- onEnter sends it, so a digest can arrive first -- and an early digest
    -- re-firing 'bus' was part of the duplicated-parachute report (2026-08-04).
    -- That is the reason for the allowlist, and BUS is why it is an allowlist
    -- rather than "replay anything that changed".
    if S.match.state ~= was
       and (S.match.state == BR.MatchState.WAITING
            or S.match.state == BR.MatchState.ENDED) then
        TriggerEvent(BR.Net.STATE, {
            state     = S.match.state,
            endsAt    = S.match.endsAt,
            mode      = S.match.mode,
            serverNow = d.serverNow,
            meta      = { from = was, reason = 'digest' },
        })
    end

    BR.PushHud()
end)

-- diedThisMatch (declared at the top; the delta handler writes it): placement
-- alone cannot answer "did I win". The last player standing who then dies to
-- the storm still finishes #1 -- there was nobody left to finish ahead of
-- them -- and a dev-solo run did exactly that: the storm killed the only
-- player and the screen slammed VICTORY ROYALE over their corpse. Placement
-- says where you finished; the flag says how it ended.

-- ...AND A DEATH THAT WAS UNDONE DID NOT HAPPEN (#144).
--
-- This latch is written by the roster delta and cleared only by a new match, so
-- a player who dies before their match reaches PLAYING -- landed early, fell off
-- something while the rest of the room was still gliding -- carried it for the
-- whole round they were then revived into. Win that round and the client would
-- have refused their own victory screen while the server banked the win: the
-- placement-1 disagreement from the other end, and the same shape as the bug
-- where the stats path and the client disagreed about what a death meant.
--
-- The revive is the authority on this. It is sent once, by the server, at the
-- moment the death is unwritten -- so this clears the local record of it in the
-- same beat, alongside the death cause, which would otherwise pick the verdict
-- slam for a death nobody had.
RegisterNetEvent(BR.Net.REVIVED)
AddEventHandler(BR.Net.REVIVED, function()
    diedThisMatch = false
    myDeathCause, myDeathByPlayer = nil, false
    -- ...AND THE WORD THAT WENT UP WITH THE DEATH (#204). A held death puts the
    -- roster through DEAD -- server/combat.lua's holdForStart is explicit that
    -- it must, or the health check eliminates them for real -- so the death word
    -- is genuinely on screen for a death that is about to be unwritten. Nothing
    -- else would take it down: the revive lands on the transition into PLAYING,
    -- and PLAYING is the one match state a match-scoped surface survives.
    dismissMatchSurfaces()
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- YOUR OWN DEATH, FOR THE TEN SECONDS BEFORE THE CAMERA MOVES ON
--
-- "Upon dying, the verdict text ONLY should be shown for ~10 seconds then the
-- text can immediately disappear as we snap into spectating. Our typical
-- verdict screen should remain once the match is over." -- the owner.
--
-- ═══ THE TWO MOMENTS WERE NOT SHARING A SURFACE. THERE WAS ONLY ONE ═══
--
-- Worth stating plainly, because it is not what the change was expected to be:
-- nothing was drawn on death at all. BR.Nui.SUMMARY is sent only on
-- MatchState.ENDED (see below), and App.tsx gates the verdict screen on the
-- match tearing down -- so a player who died mid-match got no word, no pause
-- and no acknowledgement, and client/spectate.lua's SLOW loop put them behind a
-- squadmate within a second. The moment a player most wants to read was the one
-- moment the game skipped.
--
-- So this is a NEW surface rather than a split of an old one, and the match-end
-- screen below is untouched.
--
-- ═══ WHY IT IS PUSHED TWICE ═══
--
-- The cause arrives on KILL_FEED and the death arrives on a roster delta, and
-- they are separate messages with no ordering between them. Waiting for both
-- would mean a word that appears late or not at all; so the word goes up on the
-- DEATH, with whatever cause is known -- 'WASTED' is the honest fallback and is
-- the same default the verdict screen uses -- and is re-sent if the cause lands
-- inside the window. The player sees WASTED become ELIMINATED at worst, which
-- is a correction rather than a delay.
-- ═══════════════════════════════════════════════════════════════════════════

--- Game-timer ms at which the death word comes down. 0 when nothing is up.
local deathVerdictUntil = 0

--- @param show boolean
local function pushDeath(show)
    TriggerEvent('br:ui:sendLocal', BR.Nui.DEATH, {
        show     = show,
        cause    = show and myDeathCause or nil,
        byPlayer = show and myDeathByPlayer or false,
    })
end

--- Take the death word down, whatever is left of its window.
---
--- NOT CALLED FROM THE TRANSITIONS ANY MORE -- it is registered as a
--- match-scoped surface (immediately below) and the edges that mean "the match
--- is over for this player" reach it through that. See the long note on
--- BR.MatchSurface for why the list of transitions was the wrong shape: it has
--- to be complete, it was not, and the one it was missing was the door the
--- owner used.
---
--- @param force boolean|nil  push `show = false` even when this client believes
---        the word is already down. Only br_core restarting passes it, and it
---        is the whole reason the argument exists: a fresh Lua state has
---        deathVerdictUntil = 0, so without it the one call that could correct
---        a page left holding show=true is the one call that does nothing.
local function clearDeathVerdict(force)
    if deathVerdictUntil == 0 and force ~= true then return end
    deathVerdictUntil = 0
    pushDeath(false)
end

-- THE WORD IS A MATCH-SCOPED SURFACE, and this one line is what puts it under
-- the rule instead of under a list of transitions somebody has to keep complete.
BR.MatchSurface('death verdict', clearDeathVerdict)

--- I just died. Put the word up and start the clock.
---
--- GLOBAL because the roster-delta handler above is the only caller and it is
--- the one place that sees the edge; a local declared after that handler would
--- resolve as a nil global at runtime, which is the forward-local trap
--- tools/check_forward_locals.lua exists for.
function BR.NoteDeath()
    local ms = (BR.Config.Spectate and BR.Config.Spectate.deathVerdictMs) or 10000
    if ms <= 0 then return end

    -- A NEW DEATH IS A NEW SEQUENCE, so the spectate latch is armed here rather
    -- than only by a stop message.
    --
    -- The latch upstairs exists to keep the 4 Hz feed from calling the registry
    -- four times a second, and the message that lowers it is the server's
    -- `stop`. That message is reliable -- the feed re-resolves every tick and a
    -- player with no match gets stopped -- but it is still a message, and the
    -- failure if one is ever missed is silent and lasts the rest of the session:
    -- the latch stays up, and the NEXT death's word has no edge to take it down.
    -- Clearing it on the death costs one assignment and makes the latch describe
    -- one death rather than one Lua state.
    --
    -- Nobody spectating is alive to reach this line, so there is no session
    -- being forgotten here -- except an ADMIN's, and an admin's push never sets
    -- the latch in the first place.
    spectatingNow = false

    deathVerdictUntil = GetGameTimer() + ms
    pushDeath(true)

    Citizen.SetTimeout(ms, function()
        -- STILL THE SAME DEATH? A new round, or a match that ended inside the
        -- window, has already taken the word down and moved the clock; firing
        -- blind here would push a stale `show = false` over whatever replaced
        -- it. Comparing the deadline is what makes this timeout idempotent.
        if deathVerdictUntil ~= 0 and GetGameTimer() >= deathVerdictUntil then
            clearDeathVerdict()
        end
    end)
end

--- Is the death word still on screen?
---
--- READ BY client/spectate.lua, which holds its first request for a target
--- until this goes false. That is the "then the text can immediately disappear
--- as we snap into spectating" half: the two are one sequence, not two timers
--- that happen to be the same length, so shortening deathVerdictMs moves both.
--- @return boolean
function BR.DeathVerdictUp()
    return deathVerdictUntil ~= 0 and GetGameTimer() < deathVerdictUntil
end

RegisterNetEvent(BR.Net.STATE)
AddEventHandler(BR.Net.STATE, function(d)
    S.match.state  = d.state
    S.match.endsAt = d.endsAt
    S.match.mode   = d.mode or S.match.mode

    -- A new match forgives old deaths.
    if d.state == BR.MatchState.WARMUP or d.state == BR.MatchState.BUS then
        diedThisMatch = false
        myDeathCause, myDeathByPlayer = nil, false
    end

    -- AND EVERY SURFACE THIS MATCH RAISED COMES DOWN WITH ANY STATE THAT IS NOT
    -- A LIVE MATCH (#204).
    --
    -- ONE NEGATIVE RATHER THAN A LIST OF THE FIVE STATES THAT CLEAR, because the
    -- list is what shipped and the list is what was wrong. It named WARMUP, BUS,
    -- ENDED and CLEANUP -- and not WAITING, which is the state a LEAVER's mirror
    -- settles into (server/broadcast.lua sends the lobby digest to players in no
    -- match, and the digest replays that transition locally). The one exit that
    -- was not on the list was the one the owner walked out of.
    --
    -- The reasons the old names were there have not changed and are still the
    -- reasons this holds:
    --
    --   ENDED / CLEANUP -- the verdict SCREEN is the surface for a finished
    --     match. Dying in the closing seconds is ordinary, and without this the
    --     word sits over the world at the same moment the backdrop and the
    --     placement come up behind it: two verdicts at once, which is exactly
    --     the pair the owner asked to keep distinct.
    --   WARMUP / BUS -- a fresh match with ELIMINATED across it is the one state
    --     this must never reach.
    if d.state ~= BR.MatchState.PLAYING then
        dismissMatchSurfaces()
    end
    -- The round is over for everyone; participation resets with it.
    if d.state == BR.MatchState.WAITING then
        roundParticipant = false
    end

    pushMatchState()

    -- The result screen. Placement rides roster deltas that flush AFTER the
    -- state broadcast (the transition flushes what came before it, then
    -- onEnter awards placements), so the mirror is read after a beat -- the
    -- screen is faded to black at this moment anyway. M7 fills in damage,
    -- survival time and XP; placement and kills already tell won-or-lost.
    -- PARTICIPANTS ONLY: the verdict belongs to the players who were in the
    -- round. A lobby bystander got the wasted screen of somebody else's
    -- match (live report); with no summary sent, their lobby menu stays.
    if d.state == BR.MatchState.ENDED and roundParticipant then
        Citizen.SetTimeout(500, function()
            local me = S.roster[S.me.src]
            TriggerEvent('br:ui:sendLocal', BR.Nui.SUMMARY, {
                placement  = (me and me.placement) or 0,
                kills      = (me and me.kills) or 0,
                won        = (me and me.placement == 1 and not diedThisMatch)
                                or false,
                cause      = myDeathCause,
                byPlayer   = myDeathByPlayer,
                total      = 0,
                -- `damage`, `survivedMs` and `xpEarned` used to be sent here as
                -- a hardcoded 0 each. Nothing has ever rendered them, and they
                -- were three zeroes on the wire sitting immediately next to the
                -- XP bug -- which is how an hour went into checking whether the
                -- verdict screen's "0 XP" was reading one of them (#91). What a
                -- match paid comes from br_stats on MATCH_EARNED, from the same
                -- numbers written to the database. This payload says what
                -- HAPPENED to you; that one says what it was worth.
            })
        end)
    end

    -- Visibility and FOCUS are separate things. CEF only receives mouse input
    -- while NUI focus is held, so a visible-but-unfocused lobby is inert.
    --
    -- Focus is granted by br_ui, which owns the ui_page -- br_core must never
    -- call SetNuiFocus itself or there would be two owners disagreeing.
    applyFocusForState(d.state)

    print(('[br_core] match state: %s'):format(tostring(d.state)))
end)

-- --------------------------------------------------------------------------
-- Lobby
-- --------------------------------------------------------------------------

--- UI actions forwarded from br_ui.
---
--- br_ui deliberately does not know what any of these mean -- it owns the NUI
--- page and focus, nothing else. This is the handler that was missing: the
--- queue button resolved its callback and emitted an event nobody listened for,
--- so pressing Play did nothing while the UI happily showed "Searching...".
AddEventHandler('br:ui:action', function(name, data)
    if name == BR.NuiCb.QUEUE then
        TriggerServerEvent(BR.Net.QUEUE_JOIN, { mode = data and data.mode })
    elseif name == BR.NuiCb.QUEUE_LEAVE then
        TriggerServerEvent(BR.Net.QUEUE_LEAVE)
    elseif name == BR.NuiCb.SQUAD_INVITE then
        TriggerServerEvent(BR.Net.SQUAD_INVITE, data)
    elseif name == BR.NuiCb.SQUAD_RESPOND then
        TriggerServerEvent(BR.Net.SQUAD_RESPOND, data)
    elseif name == BR.NuiCb.SQUAD_KICK then
        TriggerServerEvent(BR.Net.SQUAD_KICK, data)
    elseif name == BR.NuiCb.SQUAD_JOINREQ then
        TriggerServerEvent(BR.Net.SQUAD_JOINREQ, data)
    elseif name == BR.NuiCb.SQUAD_JOINRESP then
        TriggerServerEvent(BR.Net.SQUAD_JOINRESP, data)
    elseif name == BR.NuiCb.SQUAD_LEAVE then
        TriggerServerEvent(BR.Net.SQUAD_LEAVE)
    elseif name == BR.NuiCb.MODE_SET then
        TriggerServerEvent(BR.Net.MODE_SET, data)
    elseif BR.Server and BR.Server.devMode then
        print(('[br_core] unhandled UI action: %s'):format(tostring(name)))
    end
end)

-- Party membership is pushed by the server to members only, so a client never
-- learns about parties it is not in.
--
-- Held here rather than only forwarded, because the SQUAD channel has two
-- writers: this, and pushSquadOrParty() below for the in-match squad.
-- Forwarding without keeping a copy meant the party could not be re-sent once
-- the match squad went away -- see that function.
RegisterNetEvent(BR.Net.SQUAD_UPDATE)
AddEventHandler(BR.Net.SQUAD_UPDATE, function(party)
    S.me.partyId = party and party.id or nil
    S.party = (party and party.id) and party or nil
    pushSquadOrParty()
end)

RegisterNetEvent(BR.Net.SQUAD_RESULT)
AddEventHandler(BR.Net.SQUAD_RESULT, function(res)
    TriggerEvent('br:ui:sendLocal', BR.Nui.TOAST, {
        text = res and res.reason or (res and res.ok and 'Done.' or 'Failed.'),
        tone = (res and res.ok) and 'success' or 'danger',
    })
end)

-- An invite ARRIVES on this channel, and it is WITHDRAWN on it too. The
-- server sends { cancel = true } when the sender readied up (or otherwise
-- stopped being somewhere an acceptance could land) -- see
-- BR.Party.withdrawInvitesFrom. A card offering to join a party that no
-- longer takes joiners is a button that lies, so it comes off the screen.
RegisterNetEvent(BR.Net.SQUAD_INVITED)
AddEventHandler(BR.Net.SQUAD_INVITED, function(inv)
    TriggerEvent('br:ui:sendLocal', BR.Nui.INVITE, inv or { cancel = true })

    -- IN A MATCH, THE CARD IS BEHIND THE PAUSE MENU. The lobby draws the
    -- invite card on screen; mid-match the only place that answers an invite
    -- is the pause menu's party card -- so an invite that expires in a minute
    -- would arrive, sit somewhere nobody is looking, and lapse (user,
    -- 2026-08-09). The notice is the part that reaches them.
    --
    -- Only in a match: in the lobby the card IS on screen, and a notice
    -- pointing at a card the player is already looking at is noise.
    if inv and not inv.cancel
       and S.me.state ~= BR.PlayerState.LOBBY then
        -- NO KEY NAME IN THE TEXT. It read the binding and printed "#27" --
        -- Escape had no entry in the name table -- and a notice that names a
        -- key it cannot name is worse than one that names a place (user,
        -- 2026-08-09). The key is fixed now; the wording is simpler anyway.
        BR.Notify(
            ('%s invited you to their party — answer it in the pause menu')
                :format(inv.name or 'Someone'),
            'info', { key = 'party.invite', ms = 12000 })
    end
end)

-- A join REQUEST rides the same interface slot as an invite -- one card,
-- two directions -- tagged so the UI words it and answers it correctly.
RegisterNetEvent(BR.Net.SQUAD_JOINASK)
AddEventHandler(BR.Net.SQUAD_JOINASK, function(ask)
    TriggerEvent('br:ui:sendLocal', BR.Nui.INVITE, {
        kind = 'joinreq',
        from = ask and ask.from,
        name = ask and ask.name or '?',
        size = ask and ask.size or 0,
        max  = ask and ask.max or 0,
    })
end)

-- Server-pushed notices: party events, match alerts. Same UI stack as the
-- local action results, so a player has ONE place to glance at.
RegisterNetEvent(BR.Net.NOTIFY)
AddEventHandler(BR.Net.NOTIFY, function(n)
    if not n then return end
    -- Forwarded field by field rather than passed through whole: this is a
    -- net event, so its payload is whatever reached the client, and the UI
    -- should not be the thing that discovers a sender invented a field.
    TriggerEvent('br:ui:sendLocal', BR.Nui.TOAST, {
        text   = n.text or '',
        tone   = n.tone or 'info',
        key    = n.key,
        ms     = n.ms,
        endsAt = n.endsAt,
        sticky = n.sticky,
        clear  = n.clear,
    })
end)

--- Raise a notice from CLIENT code, with the same identity rules the server
--- has. Client-side notices are the ones that describe something only this
--- machine can see -- a prompt refused, a countdown on a local effect -- and
--- until now they had to build the envelope by hand, which is how three of
--- them ended up with slightly different shapes.
--- @param text string
--- @param tone string|nil
--- @param opts table|nil  { key, ms, endsAt, sticky }
function BR.Notify(text, tone, opts)
    opts = opts or {}
    TriggerEvent('br:ui:sendLocal', BR.Nui.TOAST, {
        text   = text,
        tone   = tone or 'info',
        key    = opts.key,
        ms     = opts.ms,
        endsAt = opts.endsAt,
        sticky = opts.sticky,
    })
end

--- Withdraw a keyed notice -- or, with no key, EVERY persistent notice.
---
--- The keyless form is the broom, not a convenience: it only touches sticky
--- notices (the ones with no expiry of their own), so it can never swallow an
--- event the player has not read yet.
--- @param key string|nil
function BR.NotifyClear(key)
    TriggerEvent('br:ui:sendLocal', BR.Nui.TOAST,
        { key = key, clear = true, text = '' })
end

-- Eliminations, broadcast to everyone. Forwarded to the UI's kill feed --
-- and if the victim is ME, the cause is remembered for the verdict slam.
RegisterNetEvent(BR.Net.KILL_FEED)
AddEventHandler(BR.Net.KILL_FEED, function(d)
    if not d then return end

    if d.victimSrc == S.me.src then
        myDeathCause    = d.cause
        myDeathByPlayer = d.killerSrc ~= nil
        -- AND IF THE WORD IS ALREADY UP, CORRECT IT. This event and the roster
        -- delta that made me DEAD have no ordering between them, so the word
        -- goes up on whichever arrives first -- with 'WASTED' standing in until
        -- the cause is known. Re-sending here turns that into ELIMINATED (or
        -- COOKED BY THE STORM, or whichever it was) inside the same window.
        -- Waiting for both messages instead would risk a death with no word at
        -- all, which is the bug being fixed.
        if BR.DeathVerdictUp and BR.DeathVerdictUp() then
            TriggerEvent('br:ui:sendLocal', BR.Nui.DEATH, {
                show     = true,
                cause    = myDeathCause,
                byPlayer = myDeathByPlayer,
            })
        end
    end

    -- Shaped to the UI's FeedEntry contract.
    --
    -- KILLING SOMEONE AND BEING KILLED ARE NOT THE SAME EVENT, and `mine`
    -- used to be true for both -- so the line where you died wore the same
    -- accent as the line where you got a kill. They are opposite pieces of
    -- news and the feed said them in the same voice.
    --
    -- `weapon` is the ITEM ID when a player did it (the server knows, from
    -- the validated damage path) and the CAUSE when the world did. The two
    -- never collide because the cause branch only renders without a killer.
    TriggerEvent('br:ui:sendLocal', BR.Nui.FEED, {
        id       = BR.Clock.now(),
        killer   = d.killer or '',
        victim   = d.victim or '',
        weapon   = d.weapon or d.cause or '',
        headshot = d.headshot or false,
        mine     = d.killerSrc == S.me.src,
        died     = d.victimSrc == S.me.src,
    })

    -- YOUR kill gets a moment; everyone else's is a line in the feed.
    --
    -- The banner is sent from HERE rather than from DAMAGE_FEED because this is
    -- the event that knows the victim's NAME. DAMAGE_FEED knows a hit killed
    -- someone but not who -- it is the shooter's private damage channel, and
    -- widening it would put a name on the wire for every bullet rather than
    -- for every death.
    if d.killerSrc == S.me.src and d.victimSrc ~= S.me.src then
        BR.Sfx.play('elim')
        TriggerEvent('br:ui:sendLocal', BR.Nui.HIT, {
            killed = true,
            name   = d.victim or '',
        })
    end
end)

-- HIT CONFIRMATION.
--
-- The server has been sending this to the shooter since M6 -- amount, headshot
-- and whether it killed -- and nothing has ever consumed it. It is the one
-- piece of feedback that taking damage away from the engine would otherwise
-- have cost us, which is exactly why damage.lua sends it.
--
-- The cue is throttled in BR.Sfx (60ms), not here: an unthrottled full-auto
-- burst is thirty overlapping sounds, and that has no visual symptom.
--- Drag our local copy of somebody else's ped back to the server's number.
---
--- A CORRECTION IS WATCHED, NEVER FIRED AND FORGOTTEN (#115, owner 2026-08-16
--- and again 2026-08-17).
---
--- THE REPORT. "I shot a squad mate, they got 0 damage, and on my screen they
--- perished. After shooting their ped once more they sprung to life, t-posed,
--- then was synced perfectly... but I did it again, and now their ped is down
--- for good."
---
--- WHY SHOT TWO WORKED AND SHOTS ONE AND THREE DID NOT. Not "a race decided
--- differently each time" -- one of the three has no race in it at all:
---
---   shots 1 and 3 were fired at a LIVING mate. A fatal hit starts
---     CTaskDyingDead; it does not have to take the health NUMBER with it (a
---     headshot is the everyday example) and `IsEntityDead` settles some frames
---     behind the task either way. For that window BOTH questions this function
---     used to ask answered "alive": the flag had not caught up and the number
---     had never fallen. So the correction took the one-write branch, wrote the
---     health, RETURNED -- and the death finished over the top of the value it
---     had just written, with nothing left watching.
---
---   shot 2 was fired INTO that corpse. Nothing left to race: the flag had
---     settled seconds earlier, so the very same correction took the other
---     branch and stood the body up. "Sprung to life, t-posed" is ResurrectPed
---     followed by ClearPedTasksImmediately, in that order.
---
--- ef501ef diagnosed the window correctly and then repaired the wrong half: it
--- removed the unconfirmed `return` from INSIDE the loop, which was never
--- entered, and left the identical unconfirmed `return` on the branch that
--- actually gets taken. tools/test_roster.lua's `resync.client` block executes
--- all three shots and pins them.
---
--- SO THERE IS ONE LOOP AND NO SHORTCUT INTO IT. The only question asked up
--- front is "is there anything to do at all", which is answerable from a single
--- sample without being wrong later: a ped standing at or above the server's
--- number, with the flag clear, needs nothing. Everything else -- wrong number,
--- flagged dead, or dying quietly with a healthy number -- goes to the watcher,
--- which writes and then comes back to see whether the write survived.
---
--- AND THE FLAG IS THE FACT ABOUT DEATH; THE NUMBER IS NOT. `BR.IsDeadHp` reads
--- the project's own mapping (display 0..100 onto engine 100..200), and our copy
--- of somebody else's ped carries GTA's raw damage instead -- four pistol rounds
--- put it at engine 96 on a ped that is upright and running. Resurrecting that
--- ped and clearing its tasks is the OTHER half of the t-pose the owner saw, so
--- only `IsEntityDead` may reach for ResurrectPed. A low number is a reason to
--- keep correcting, never a reason to declare a corpse.
---
--- ROUND FOUR: THE WATCHER STOPPED WATCHING TOO SOON, AND IT STOPPED ON A
--- QUESTION A DYING PED ANSWERS CORRECTLY (#115, owner 2026-08-17).
---
--- a8b22c7 built the loop and then handed it an exit: "alive at the number twice
--- running, 150ms apart, outlives the task". That is a GUESS about how long
--- `IsEntityDead` takes to catch up with a fatal hit, wearing the clothes of a
--- fact -- and the whole reason this bug exists is that during that window a
--- dying ped reads EXACTLY like a healthy one. Two clean samples are not
--- evidence the death task has gone; they are evidence it has not finished yet.
--- The same guess is in the loop's length: six passes is 900ms, and then the
--- thread stops whatever the ped is doing.
---
--- tools/test_roster.lua modelled that settle at 64ms, which is under the 150ms
--- poll -- so the shipped fix passed a suite that had assumed the answer. Move
--- the model's settle to 800ms, change nothing else, and the suite reproduces
--- the owner's report verbatim: shot 1 corpse, shot 2 fine, shot 3 down for
--- good. It never was a race that "went differently each time"; it is one number
--- nobody knows, and every version of this fix has been a bet on it.
---
--- SO THIS ONE DOES NOT BET. There is no early exit and no confirmation count.
--- The watch runs for a fixed budget that is longer than any dying animation,
--- re-asserting the server's number whenever the ped disagrees with it, and the
--- things that stop it early are FACTS rather than guesses:
---
---   * the entity is gone (OneSync re-created it; the new copy is correct);
---   * the SERVER says the victim is no longer someone to correct -- they were
---     downed and then finished while we were arguing with their corpse. That is
---     what `src` is for, and it is the guard that makes a five-second watch safe
---     to run at all: without it a genuine death landing mid-watch would be
---     resurrected, which is this bug pointed the other way.
---
--- ONE WATCH PER PED, NOT ONE PER BULLET. A burst of automatic fire used to
--- start a coroutine per round, all of them writing the same value to the same
--- ped. A later correction now refreshes the running watch -- newest number,
--- deadline pushed out -- and starts nothing.
---
--- ROUND FIVE: THE BET DID NOT GO AWAY. IT MOVED TO THE DOOR (#115, owner
--- 2026-08-17, fifth report).
---
--- Round four took every guess out of the watch and said so: no confirmation
--- count, no settle time, no early exit, "the deadline is the exit". It left
--- exactly one judgement standing -- in FRONT of the watch rather than inside
--- it -- and the comment that used to sit on it confessed the flaw in the same
--- breath it shipped it:
---
---     if not IsEntityDead(ped) and GetEntityHealth(ped) >= hp then return end
---     -- "A ped that is quietly dying reads exactly like a healthy one here"
---
--- It does. And that reading was not deciding what to WRITE -- it was deciding
--- whether a watch would exist at all. "Nothing to write" and "nothing to write
--- YET" are the same sample and opposite answers, and the gap between them is a
--- coroutine that never starts. Everything after this point in the function was
--- built to survive being wrong about a single sample; this was the one place
--- where a single sample still ended the conversation.
---
--- TWO ORDINARY WAYS IN, neither of them a race the network decides -- they are
--- the same arithmetic every time, which is why the report reads "still
--- happening" rather than "sometimes":
---
---   * THE NUMBER DOES NOT MOVE. A headshot is CTaskDyingDead from the first
---     frame with the health untouched -- rule 1, the thing this whole file is
---     written around. The correction reads 200 against a target of 200 and
---     walks away from a ped that is already gone.
---   * THE SERVER'S NUMBER IS BELOW THE CLONE'S, which it usually is: the mate
---     has taken storm or enemy damage this machine's copy never received, so
---     the ledger holds 60 display (160 engine) while the clone still reads 174
---     after our own bullet. `174 >= 160` -- nothing to do, said the door, to a
---     ped in the middle of dying.
---
--- Both leave no thread and nothing anywhere that ever looks at that ped again.
--- That is "down for good", precisely. tools/test_roster.lua now drives both,
--- at five settle times from 16ms to 3500ms; before this change all five failed
--- identically, which is the shape of an arithmetic bug rather than a race.
---
--- SO THE DOOR ASKS NOTHING. A correction watches.
---
--- THE COST, honestly. One coroutine per PED under fire -- not per bullet, the
--- refresh above sees to that -- waking 33 times over five seconds to read a
--- health value. The correction with nothing to do now costs that instead of
--- costing nothing, and that is the trade this round makes on purpose: the
--- saving was paid for by a single sample deciding whether the ped was fine,
--- and that sample cannot tell.
local WATCH_MS = 5000
local WATCH_POLL_MS = 150

-- netId -> { hp, src, deadline, ... }. Presence IS "a watch is running".
local watching = {}

-- WHY A CORRECTION DID NOT BECOME A WATCH (#115, round seven).
--
-- "The message never arrived" and "the message arrived and this file declined
-- it" are the first two of the four things that can be wrong with this issue,
-- and until now /brcorpse could not tell them apart: both print as "no watch
-- has finished this session". That is the same class of mistake round six
-- fixed in the readout -- a blank standing in for an answer -- and it is on
-- the line that decides whether the next round is the server's work or ours.
--
-- Every entry is a REASON a correction stopped short, counted where it stops.
-- `arrived` counts frames off the wire before any judgement at all, so a zero
-- there is the server's answer and a non-zero is this file's.
local corrections = {
    arrived      = 0,   -- HIT_RESYNC / DAMAGE_FEED frames that reached correctPed
    noNetId      = 0,   -- ...with no network id on them
    deadTarget   = 0,   -- ...whose target health is itself a dead number
    refreshed    = 0,   -- ...answered by a watch that was already running
    unknownNetId = 0,   -- ...for a network id that does not resolve here
    noEntity     = 0,   -- ...for a network id with no entity behind it
    watched      = 0,   -- ...that started a watch. This is the one that counts.
}

-- The last watch to finish, kept for /brcorpse. A finished watch is exactly
-- the one worth reading and exactly the one `watching` no longer has.
local lastWatch = nil

--- @param netId integer
--- @param hp integer   ENGINE units
--- @param src integer|nil  the victim's server id, so the roster can call it off
local function correctPed(netId, hp, src)
    -- A CORRECTION TO A DEAD NUMBER IS NOT A CORRECTION. This used to read
    -- `hp <= 0`, which is not the threshold: engine health floors at 100 for a
    -- player ped, so a target of 100 is a corpse that would have been
    -- resurrected once per retry into a value that keeps it dead. The server no
    -- longer sends one (BR.Damage.resync declines a victim who is out), and this
    -- is the half that cannot be reached by getting that wrong again.
    corrections.arrived = corrections.arrived + 1
    if not netId then
        corrections.noNetId = corrections.noNetId + 1
        return
    end
    if BR.IsDeadHp(hp) then
        corrections.deadTarget = corrections.deadTarget + 1
        return
    end

    -- A WATCH ALREADY RUNNING IS THE ANSWER TO THIS BULLET TOO. Refresh it and
    -- go: newest number, deadline pushed out. This is now the ONLY question
    -- asked before a watch starts, and it is a question about this table rather
    -- than about the ped -- which is the whole of round five. Nothing here reads
    -- the engine to decide whether the correction is needed, because a ped
    -- mid-death reads perfectly fine and deciding on that reading is what left
    -- four rounds of corpses standing.
    --
    -- ...UNLESS THE ENTRY HAS OUTLIVED ITS THREAD. A bare Citizen thread that
    -- throws simply stops -- no handler, nothing to notice -- and it would leave
    -- this table holding a watch with nothing behind it. Every later correction
    -- for that ped would then be answered by refreshing a corpse of a watch, for
    -- the rest of the session. An entry past its own deadline is that, by
    -- definition, so it is thrown away and a fresh one started. (The same shape
    -- of failure as the uiHold thread at the top of this file, which is why it
    -- gets the same kind of net.)
    local w = watching[netId]
    if w and GetGameTimer() < w.deadline then
        w.hp = hp
        w.src = src or w.src
        w.deadline = GetGameTimer() + WATCH_MS
        corrections.refreshed = corrections.refreshed + 1
        return
    end
    watching[netId] = nil

    if not NetworkDoesNetworkIdExist(netId) then
        corrections.unknownNetId = corrections.unknownNetId + 1
        return
    end

    local ped = NetworkGetEntityFromNetworkId(netId)
    if not ped or ped == 0 or not DoesEntityExist(ped) then
        corrections.noEntity = corrections.noEntity + 1
        return
    end

    -- ...AND THERE IS NO LONGER A TEST HERE AT ALL. See the round-five note
    -- above: the reading this used to take -- "not dead and already at the
    -- number, so nothing to do" -- is the one reading a dying ped answers
    -- exactly like a healthy one, and answering it decided whether a watch ever
    -- existed. A correction watches. That is the whole door.
    --
    -- A CORPSE THAT SHOULD NOT BE ONE. ResurrectPed alone leaves the death
    -- TASK running, so the ped stands up and immediately plays dying again;
    -- clearing tasks is what actually ends it. Before this, the body lay
    -- there for the better part of ten seconds until OneSync re-created it
    -- (user, 2026-08-08).
    --
    -- The counters are evidence for /brcorpse, and they are the point of round
    -- five's other half: if this is STILL a corpse in game, the next question
    -- is not "was the logic right" but "did the writes land", and that is a
    -- question about the engine that only the engine can answer. See the
    -- command at the bottom of this section.
    corrections.watched = corrections.watched + 1
    watching[netId] = { hp = hp, src = src,
                        deadline = GetGameTimer() + WATCH_MS,
                        startedAt = GetGameTimer(),
                        passes = 0, writes = 0, resurrects = 0,
                        sawDead = false }

    Citizen.CreateThread(function()
        while true do
            local watch = watching[netId]
            -- Cleared by a stop condition below, or never created. Either way
            -- this thread has nothing left to own.
            if not watch then return end

            --- Give up the watch and the thread together, so the table can
            --- never hold an entry with nothing behind it.
            ---
            --- The finished watch is KEPT, once, for /brcorpse. `watching` is
            --- empty by the time the player alt-tabs out to type a command, so
            --- without this the one moment worth inspecting is the one moment
            --- there is nothing to inspect.
            ---
            --- AND IT TAKES A LAST READING ON ITS WAY OUT (#115, round six).
            --- /brcorpse samples the ped LIVE and prints that sample directly
            --- beneath these counters. The counters describe the watch's
            --- lifetime; the sample describes the moment somebody typed the
            --- command, and those are not the same moment -- they were five
            --- minutes apart in the owner's own paste. A reading taken HERE,
            --- with the clock stamped, is what turns that block from a
            --- contradiction into a diagnosis.
            local function stop(why)
                watch.why, watch.netId = why, netId
                watch.endedAt = GetGameTimer()
                local q = NetworkDoesNetworkIdExist(netId)
                          and NetworkGetEntityFromNetworkId(netId) or 0
                if q ~= 0 and DoesEntityExist(q) then
                    watch.endHealth = GetEntityHealth(q)
                    watch.endDead   = IsEntityDead(q)
                end
                lastWatch = watch
                watching[netId] = nil
            end

            if GetGameTimer() >= watch.deadline then return stop('deadline') end

            if not NetworkDoesNetworkIdExist(netId) then return stop('netid gone') end
            local p = NetworkGetEntityFromNetworkId(netId)
            if not p or p == 0 or not DoesEntityExist(p) then
                return stop('entity gone')
            end

            -- THE SERVER GETS THE LAST WORD, AND IT CAN CHANGE ITS MIND.
            --
            -- A watch outlives the correction that started it, which is the
            -- whole point -- and a five-second one comfortably outlives the
            -- squadmate too, if an enemy finishes them mid-watch. Reviving a
            -- teammate who has genuinely just died would be #115 inverted and
            -- far worse: the corpse would be the truth and we would be the
            -- ones deleting it. The mirror already holds the server's verdict,
            -- so it is read every pass rather than trusted once.
            --
            -- Absent entry means keep going: a squadmate is always in the
            -- roster, and failing open here costs a correction that the next
            -- OneSync re-creation would have made anyway.
            local e = watch.src and S.roster[watch.src]
            if e and e.state ~= BR.PlayerState.ALIVE
               and e.state ~= BR.PlayerState.DBNO then
                return stop('server says they are out')
            end

            watch.passes = watch.passes + 1
            local target = watch.hp
            if IsEntityDead(p) then
                watch.sawDead = true
                watch.resurrects = watch.resurrects + 1
                watch.writes = watch.writes + 1
                ResurrectPed(p)
                ClearPedTasksImmediately(p)
                SetEntityHealth(p, target)
                -- WHETHER THAT TOOK IS NOT SOMETHING THIS FILE MAY ASSUME. The
                -- one thing it can do is record the reading the engine gives
                -- back on the very next line, so /brcorpse can say "resurrected
                -- 33 times and it read dead every time" -- which is a fact
                -- about the ENGINE, and the only kind of evidence that settles
                -- whether a clone of somebody else's player ped can be stood up
                -- from here at all.
                watch.stillDeadAfterWrite = IsEntityDead(p)
            elseif GetEntityHealth(p) < target then
                watch.writes = watch.writes + 1
                -- Only ever UPWARD. Writing it down would be us arguing with
                -- the owner's own sync about a ped we do not own, for no gain.
                SetEntityHealth(p, target)
            end
            -- ...AND NO `else return`. There is no reading of a ped that proves
            -- its death task has finished, so there is nothing here to confirm
            -- against. The deadline is the exit.

            Citizen.Wait(WATCH_POLL_MS)
        end
    end)
end

--- ROUND SIX: THE BUDGET IS THE LAST BET, AND #115's OWN INSTRUMENT IS WHAT
--- CAUGHT IT (owner, 2026-08-17, sixth report).
---
--- The owner shot a squadmate to a false death and ran /brcorpse. The watch
--- over that ped had run FIFTY passes, seen no corpse, and written nothing --
--- next to a live reading of `health 0  dead 1  fatally injured 1`. Read as one
--- moment that is a contradiction, and four of the five previous rounds would
--- have gone looking for a broken predicate. It is not one moment. Fifty passes
--- at one poll every WATCH_POLL_MS is seven and a half seconds of watching, and
--- the ped was read three hundred and twenty-six SECONDS after that watch
--- started. The detection was fine. The ped simply died with nothing looking at
--- it, and everything above only looks while a bullet is recent.
---
--- SO THE BUDGET WAS THE BET ALL ALONG. Round four took the guess out of the
--- predicate; round five took it out of the door; both left it in the clock.
--- `WATCH_MS` is a number nobody has measured, exactly like the settle time
--- that made rounds three and four wrong, and tools/test_roster.lua now sweeps
--- it: a death that shows up at 4900ms is corrected and one at 5200ms is "down
--- for good" forever. That is the same shape of failure with a bigger constant
--- in it.
---
--- AND THERE IS A FACT HERE THAT NEEDS NO CLOCK AT ALL. A false corpse is not
--- "a ped that was shot recently and then died". It is, exactly:
---
---     the server says this player is ALIVE, and their ped on this machine
---     reads dead.
---
--- That is decidable from the mirror this very file maintains, at any moment,
--- for every player -- with no netId on the wire, no bullet, and no budget. It
--- is also the only form of the question that cannot be got wrong by being
--- asked at the wrong time, because there is no window: ask it again in half a
--- second and it is still true, and still true, until it is fixed.
---
--- ALIVE ONLY, AND DBNO IS DELIBERATELY EXCLUDED. A downed player's body is
--- POSED by their own client -- client/dbno.lua resurrects them and lays them
--- out with NetworkResurrectLocalPlayer -- and ClearPedTasksImmediately on a
--- teammate mid-knock would strip that pose and T-pose them, which is the
--- previous rounds' bug wearing a new hat. The server calls them DBNO rather
--- than ALIVE precisely so this can tell the difference.
---
--- THE WATCH STAYS. It answers within a poll of the shot rather than within
--- half a second, and forty-odd assertions pin it. This is the floor under it.
local RECONCILE_MS = 500

-- EVIDENCE, FOR /brcorpse -- AND COUNTED AS WHAT IT IS.
--
-- The first version of this counter said "corrected", which it could not know.
-- With the writes being dropped it read 623 after five minutes on ONE corpse,
-- because it was counting attempts and calling them repairs -- the same kind of
-- over-claiming readout that made this issue take six rounds. So: how many
-- sweeps found a false corpse, and how many of those were still dead on the
-- very next line. `found` climbing while `stuck` climbs with it is the ownership
-- answer the round-five note was reaching for, and it now arrives from a
-- channel that runs all match instead of for five seconds after a bullet.
local falseCorpses, falseCorpsesStuck = 0, 0

-- ...AND `stuck ~= 0` IS ONLY HALF THE OWNERSHIP QUESTION (#115, round seven).
--
-- `stuck` is read on the line AFTER the write, with no yield in between, so no
-- packet from anybody can have arrived: it answers "did the native itself take
-- effect on this machine, this frame". That is a real answer and it is the only
-- one this file could give -- but it is blind to the other way a repair fails.
-- A write that lands and is then reverted by the owner's next sync reads
-- `stuck = 0` every single time, and the old readout called that case "the
-- corpses are real and being fixed". It is the exact case where they are not.
--
-- So the sweep also remembers who it wrote to LAST time. A player written to on
-- one sweep and found dead again on the next, half a second later, was not
-- repaired -- whatever the line after the write said. That is a fact about
-- whether the correction HOLDS, which is a different question from whether it
-- lands, and between them the two counters separate the last two candidates:
--
--   stuck climbing      the native is refused outright -- we do not own the ped
--   relapsed climbing   the native takes and the owner's sync puts it back
--   neither             the repair works, and `repaired` is what it did
local falseCorpsesRelapsed, falseCorpsesRepaired = 0, 0

-- src -> true when the last sweep wrote to that player's ped. Cleared the
-- moment they read alive again, so a player who is fixed and later dies for
-- real does not count as a relapse.
local wroteLastSweep = {}

--- Is a watch already arguing about this player's ped?
---
--- IT HAS THE BETTER NUMBER AND IT MUST NOT BE FOUGHT. A watch carries the
--- health the SERVER put on the wire for this exact hit; the mirror carries the
--- roster's copy, which is a tick or two behind and rounded through display
--- units. Two writers on one ped means whichever polls first wins, and the
--- answer to "what health is this player on" would depend on that. So the
--- standing check is a FLOOR under the watch, not a second opinion beside it.
--- @param src integer
--- @return boolean
local function watchOwns(src)
    for _, w in pairs(watching) do
        if w.src == src then return true end
    end
    return false
end

--- One sweep of the mirror. Split out so the suite can call it directly.
local function reconcileFalseCorpses()
    for src, e in pairs(S.roster) do
        -- A PLAYER THIS SWEEP WILL NOT LOOK AT HAS NO HISTORY WORTH KEEPING.
        -- Without this, somebody written to and then genuinely killed comes
        -- back from the dead in the arithmetic: the next false corpse they
        -- present, minutes later, would be counted as a relapse of a write
        -- that has nothing to do with it.
        if e.state ~= BR.PlayerState.ALIVE then wroteLastSweep[src] = nil end

        if src ~= S.me.src and e.state == BR.PlayerState.ALIVE
           and not watchOwns(src) then
            -- -1 IS "NOT ON THIS MACHINE", AND IT IS A TRAP RATHER THAN A
            -- MISS: the ped native answers -1 with the LOCAL player's ped, so
            -- a squadmate on the far side of the map resolves to us, and we
            -- would resurrect ourselves in a fight with client/dbno.lua over a
            -- body it owns. Both the index and the player id are checked.
            --
            -- ...AND SCOPE IS NOT BEING USED AS A ROSTER HERE, which is what
            -- the gate in tools/verify.sh exists to stop. The set of players
            -- and their states comes off the server broadcast above; scope only
            -- answers "is there a copy of that ped on this machine to be
            -- wrong", which is the one question it is actually authoritative
            -- about. Out of scope there is no local corpse, so there is
            -- nothing here to fix.
            local ply = GetPlayerFromServerId(src)  -- scope-ok: a false corpse is a fact about the LOCAL copy of that ped; the roster comes from the server
            if ply and ply ~= -1 and ply ~= PlayerId() then
                local ped = GetPlayerPed(ply)  -- scope-ok: same call, same reason -- the ped handle for a player already known to be in scope
                if ped and ped ~= 0 and DoesEntityExist(ped) then
                  if IsEntityDead(ped) then
                    -- The mirror carries DISPLAY units; a ped takes engine
                    -- ones. Never inline this arithmetic (config/match.lua).
                    local target =
                        math.floor(BR.ToEngineHp(e.hp or 100.0) + 0.5)
                    -- A player the ledger has on the floor is not somebody to
                    -- resurrect INTO a value that keeps them dead -- the same
                    -- guard correctPed opens with, and for the same reason.
                    if not BR.IsDeadHp(target) then
                        -- DEAD AGAIN, HALF A SECOND AFTER WE WROTE TO THEM.
                        -- Counted BEFORE this sweep's write, so it describes
                        -- the fate of the PREVIOUS one.
                        if wroteLastSweep[src] then
                            falseCorpsesRelapsed = falseCorpsesRelapsed + 1
                        end
                        falseCorpses = falseCorpses + 1
                        ResurrectPed(ped)
                        ClearPedTasksImmediately(ped)
                        SetEntityHealth(ped, target)
                        wroteLastSweep[src] = true
                        -- Whether that took is the engine's to say, and the
                        -- next line is the only place it can be asked.
                        if IsEntityDead(ped) then
                            falseCorpsesStuck = falseCorpsesStuck + 1
                        end
                    end
                  elseif wroteLastSweep[src] then
                    -- WRITTEN TO LAST SWEEP AND UPRIGHT NOW. This is the only
                    -- evidence in the file that a repair ever actually held,
                    -- and it is the number whose absence means the corpse is
                    -- winning however healthy the other counters look.
                    falseCorpsesRepaired = falseCorpsesRepaired + 1
                    wroteLastSweep[src] = nil
                  end
                end
            end
        end
    end
end

Citizen.CreateThread(function()
    while true do
        Citizen.Wait(RECONCILE_MS)
        reconcileFalseCorpses()
    end
end)

RegisterNetEvent(BR.Net.DAMAGE_FEED)
AddEventHandler(BR.Net.DAMAGE_FEED, function(d)
    if not d then return end

    BR.Sfx.play(d.headshot and 'hit.crit' or 'hit')

    -- The banner for a kill rides KILL_FEED (it has the name); this is the
    -- marker only. `killed` still travels so the marker can punctuate.
    TriggerEvent('br:ui:sendLocal', BR.Nui.HIT, {
        amount   = d.amount or 0,
        headshot = d.headshot or false,
        killed   = d.killed or false,
    })

    -- AND PUT THE VICTIM BACK WHERE THE SERVER SAYS THEY ARE.
    --
    -- We are the shooter, and our own copy of the person we just shot is
    -- wrong -- guaranteed, every time. GTA applied its own damage number to
    -- them locally before the server saw the shot; the server cancelled the
    -- replication and applied OURS, which is a different number. The gap
    -- compounds shot after shot until our copy hits zero and dies while they
    -- walk around alive on 7hp -- a permanent corpse that nothing ever
    -- cleared (user, 2026-08-09).
    --
    -- Cheap: one health read, and a write only when it disagrees. The netId
    -- is absent when the ledger says they are dead, because then the corpse
    -- is right and reviving it would be the bug.
    if d.netId then
        correctPed(d.netId, math.floor(tonumber(d.hp) or 0), tonumber(d.src))
    end
end)

-- IS ENTITY OWNERSHIP THE BLOCKER? ASK THE ENGINE, IN GAME (#115).
--
-- Everything above is a write to a ped this machine does not own, and GTA is
-- entitled to ignore those. The suite cannot answer that question -- it is a
-- property of the running session, not of the logic -- so this prints what the
-- engine says about the last ped we tried to correct, live, next to the number
-- we were trying to write.
--
-- The natives here are READ-ONLY on purpose. `NetworkRequestControlOfEntity` is
-- deprecated by Cfx.re over cheat abuse, and `sv_filterRequestControl` defaults
-- to blocking control requests for entities controlled by players -- which is
-- every player ped on the server. Calling it would be asking for something the
-- server is configured to refuse.
--
-- ROUND FIVE ADDS THE FINISHED WATCH, and that is the reading that matters.
-- The live table is empty five seconds after the shot, which is roughly when a
-- player finishes saying "it's still a corpse" and reaches for the console. The
-- last watch to end says how many passes it got, how many times it wrote, how
-- many times it resurrected, and -- the one that settles the argument -- what
-- the engine answered on the line immediately AFTER a resurrection.
--
--   resurrects > 0 and stillDead=true   the logic ran and the ENGINE refused.
--                                       Nothing in Lua fixes that; the repair
--                                       has to come from the ped's owner, the
--                                       way client/dbno.lua's floorTheBody does
--                                       it with NetworkResurrectLocalPlayer.
--   passes 0, or no watch at all        the correction never arrived, or the
--                                       roster called it off. That is a logic
--                                       fault, and this file's to fix.
--- ...AND THE ONE THING THIS PRINTOUT MUST NEVER DO AGAIN IS PRINT TWO
--- DIFFERENT MOMENTS AS THOUGH THEY WERE ONE (#115, round six).
---
--- The owner's paste was read as a contradiction inside our own instrument:
---
---     ENDED netId 3  target hp 200  src 3
---       exists 1  health 0  dead 1  fatally injured 1
---       started 326858ms ago  passes 50  writes 0  resurrects 0
---       saw a corpse false  ended: deadline
---
--- A corpse, and a watch over it that saw nothing. It is not a contradiction
--- and there is nothing wrong with the detection: `passes 50` at one poll every
--- WATCH_POLL_MS is SEVEN AND A HALF SECONDS of watching, and the ped was read
--- 326858ms after that watch began -- so the two lines are five minutes and
--- eighteen seconds apart. The counters are the watch's life; the reading
--- underneath them is right now. The ped died with nothing looking at it.
---
--- So the age of every number is printed next to it, the reading the watch took
--- on its way out is printed beside the reading taken now, and a gap between
--- the two is called what it is.
local function printWatch(label, netId, w)
    local exists = NetworkDoesNetworkIdExist(netId)
    local p = exists and NetworkGetEntityFromNetworkId(netId) or 0
    local now = GetGameTimer()
    print(('  %s netId %s  target hp %s  src %s')
        :format(label, tostring(netId), tostring(w.hp), tostring(w.src)))

    -- THE WATCH'S OWN LIFETIME. Every one of these is history.
    print(('    started %dms ago  ran for %dms  passes %d  writes %d  '
           .. 'resurrects %d  saw a corpse %s  ended: %s')
        :format(now - (w.startedAt or now),
                (w.endedAt or now) - (w.startedAt or now),
                w.passes or 0, w.writes or 0, w.resurrects or 0,
                tostring(w.sawDead), tostring(w.why or 'still running')))
    -- ...AND `nil` HERE IS NOT AN ANSWER EITHER (#115, round seven). This field
    -- only exists once something has been resurrected, so on a watch that never
    -- saw a corpse it printed "nil" -- which is round six's dash wearing a
    -- different word. "Never resurrected" and "resurrected, and it did not
    -- take" are opposite findings and they must not share a rendering.
    if w.stillDeadAfterWrite == nil then
        print('    STILL DEAD ON THE LINE AFTER RESURRECTING: never resurrected '
              .. 'during this watch, so the engine was never asked')
    else
        print(('    STILL DEAD ON THE LINE AFTER RESURRECTING: %s   <-- true here '
               .. 'means the engine refused the write, not that the logic missed it')
            :format(tostring(w.stillDeadAfterWrite)))
    end

    -- WHAT THE WATCH SAW LAST, and how long ago that was.
    if w.endedAt then
        print(('    AT THE MOMENT IT ENDED (%dms ago): health %s  dead %s')
            :format(now - w.endedAt,
                    tostring(w.endHealth or '-'), tostring(w.endDead)))
    end

    -- ...AND WHAT THE PED IS DOING NOW, which is a different sentence.
    --
    -- `a and b or '-'` IS NOT A SAFE WAY TO PRINT A BOOLEAN, and this readout
    -- was doing it on all four of the facts it exists to report. When the
    -- native answers FALSE the idiom falls through to '-' -- so "I looked, and
    -- the answer is no" printed identically to "there was no ped to ask". The
    -- worst case is the last line: `I control this ped: -` is the single most
    -- important fact in this issue, and it read as "unknown" when it meant
    -- "no". Nothing above is worth trusting if the reader cannot tell a false
    -- from a blank.
    local function said(v)
        if v == nil then return '-' end
        return tostring(v)
    end
    if p ~= 0 then
        print(('    RIGHT NOW: exists %s  health %s  dead %s  fatally injured %s')
            :format(said(exists), said(GetEntityHealth(p)), said(IsEntityDead(p)),
                    IsPedFatallyInjured and said(IsPedFatallyInjured(p))
                        or 'native unavailable'))
        print(('    I control this ped: %s')
            :format(said(NetworkHasControlOfEntity(p))))
    else
        print(('    RIGHT NOW: exists %s -- there is no ped on this machine for '
               .. 'that network id, so nothing below could be asked')
            :format(said(exists)))
    end

    -- THE SENTENCE THE OWNER SHOULD NOT HAVE HAD TO WORK OUT BY HAND.
    if w.endedAt and p ~= 0 and IsEntityDead(p) and not w.endDead then
        print(('    >>> THIS PED DIED %dms AFTER THE WATCH LET GO OF IT. The '
               .. 'watch is not wrong; nothing was watching.')
            :format(now - w.endedAt))
    end
end

RegisterCommand('brcorpse', function()
    print('=== corpse watch ===')

    -- 1. DID THE SERVER'S CORRECTION ARRIVE AT ALL? Printed FIRST and on its
    --    own line, because it is the only question here whose answer is not
    --    this file's responsibility -- and until round seven it was invisible.
    print(('  corrections off the wire: %d arrived  ->  %d started a watch, '
           .. '%d refreshed a running one')
        :format(corrections.arrived, corrections.watched, corrections.refreshed))
    print(('    declined here: %d for a dead target number, %d with no netId, '
           .. '%d for a netId that does not resolve, %d with no entity behind it')
        :format(corrections.deadTarget, corrections.noNetId,
                corrections.unknownNetId, corrections.noEntity))
    print('    arrived 0 while squadmates are being shot = the SERVER is not')
    print('      sending them, and nothing below can help.')

    -- 2. THE STANDING CHECK, WHICH NEEDS NO BULLET AND HAS NO WINDOW.
    print(('  standing check: found a false corpse %d time(s) this session '
           .. '(a ped the server calls ALIVE, reading dead here)')
        :format(falseCorpses))
    print(('    of those: %d were STILL dead on the line after the write, and '
           .. '%d were found dead AGAIN on the very next sweep')
        :format(falseCorpsesStuck, falseCorpsesRelapsed))
    print(('    and %d were upright again when the next sweep looked')
        :format(falseCorpsesRepaired))

    -- ...AND WHAT THOSE THREE NUMBERS MEAN, WHICH IS THE WHOLE POINT.
    --
    -- The line this replaces read "found high and stuck ~0 = the corpses are
    -- real and being fixed", and that was wrong in the one case it most
    -- mattered: a write that lands and is reverted by the owner's next sync
    -- reads stuck 0 forever while nothing is fixed at all. `repaired` is what
    -- "being fixed" actually looks like, and `relapsed` is what it looks like
    -- when the engine takes the write and then takes it back.
    print('    stuck climbing with found  = the engine REFUSES the write. We do')
    print('      not own that ped and no Lua on this machine can stand it up.')
    print('    stuck ~0 but relapsed climbing = the write LANDS and does not')
    print('      HOLD -- the owner\'s next sync puts the corpse back. Same')
    print('      conclusion: the repair has to run on the victim\'s machine.')
    print('    repaired climbing and relapsed ~0 = the corrections are working.')
    print('    found 0 while a corpse is on screen = the mirror never said')
    print('      ALIVE for them, and the detection is what is broken.')

    local any = false
    for netId, w in pairs(watching) do
        any = true
        printWatch('RUNNING', netId, w)
    end
    if not any then print('  nothing being corrected right now') end
    if lastWatch then
        print('  --- the last watch to finish ---')
        printWatch('ENDED  ', lastWatch.netId, lastWatch)
    else
        print('  no watch has finished this session')
    end
end, false)

-- --------------------------------------------------------------------------
-- Storm
-- --------------------------------------------------------------------------

-- The published record. Solved locally (BR.StormAt against the synced clock)
-- by the renderer and the HUD; nothing about the circle is ever streamed.
RegisterNetEvent(BR.Net.STORM_SYNC)
AddEventHandler(BR.Net.STORM_SYNC, function(rec)
    S.storm = rec
end)

-- The server said the storm hurt us; hurt the ped it can see. This handler
-- lives HERE, in the mirror, and not in client/storm.lua ON PURPOSE: the
-- authority drill disables every storm VISUAL and the player must still take
-- identical damage -- and even a client that strips this handler out only
-- silences the animation, because the server eliminates from its own ledger
-- either way. Applying what the server said is exactly this file's job.
RegisterNetEvent(BR.Net.STORM_DAMAGE)
AddEventHandler(BR.Net.STORM_DAMAGE, function(d)
    local amount = (d and d.amount) or 0
    if amount <= 0 then return end
    BR.Native.applyDamage(amount, d.armourFirst)
end)

-- A VALIDATED GUNSHOT, applied to our own ped on instruction.
--
-- M6 cancels the engine's own damage and applies the SERVER's number instead,
-- which is what makes our weapon table real rather than decorative. The split
-- arrives already worked out -- the server took armour first and told us how
-- much of each -- because it is the server's ledger that decides the
-- elimination, and a client that quietly disagreed here would only be lying to
-- its own health bar.
-- A SHOT OF OURS WAS REFUSED, so the ped we think we hit is wrong.
--
-- The engine applies damage locally on the shooter's machine before the server
-- ever sees the event, and the server's CancelEvent stops it REPLICATING
-- rather than undoing it. So a refused burst leaves this client looking at a
-- corpse that is alive everywhere else. The server sends the health it holds
-- for that player and this puts it back.
--
-- Local only, and deliberately: we do not own that ped, so this is correcting
-- our own copy rather than asserting anything about theirs. If the write does
-- not take, the owner's next sync corrects it anyway -- this only shortens the
-- window.
RegisterNetEvent(BR.Net.HIT_RESYNC)
AddEventHandler(BR.Net.HIT_RESYNC, function(d)
    if type(d) ~= 'table' then return end
    correctPed(d.netId, math.floor(tonumber(d.hp) or 0), tonumber(d.src))
end)

RegisterNetEvent(BR.Net.HIT_DAMAGE)
AddEventHandler(BR.Net.HIT_DAMAGE, function(d)
    if type(d) ~= 'table' then return end

    -- Armour is a display-unit number and the ped's own; health arrives in
    -- ENGINE units, same as STORM_DAMAGE.
    local armour = math.floor(tonumber(d.armour) or 0)
    if armour > 0 then
        local ped = PlayerPedId()
        SetPedArmour(ped, math.max(0, GetPedArmour(ped) - armour))
    end

    local amount = math.floor(tonumber(d.amount) or 0)
    if amount > 0 then
        -- armourFirst is FALSE here on purpose: the server already took the
        -- armour above, so letting the native take it again would charge the
        -- shield twice for one bullet.
        BR.Native.applyDamage(amount, false)
    end
end)

RegisterNetEvent(BR.Net.LOBBY_STATUS)
AddEventHandler(BR.Net.LOBBY_STATUS, function(d)
    -- Resolve "am I queued?" here rather than shipping the id list to the UI.
    -- The client already knows its own server id; the interface should be told
    -- a boolean, not asked to work it out.
    local you = false
    for _, src in ipairs(d.ids or {}) do
        if src == S.me.src then you = true break end
    end

    -- Drop ourselves from the invitable list here rather than making the UI
    -- filter: the client knows its own server id, the interface should not
    -- have to care.
    local others = {}
    for _, p in ipairs(d.players or {}) do
        if p.src ~= S.me.src then others[#others + 1] = p end
    end

    -- How much of MY party has readied up.
    --
    -- Resolved here rather than server-side because it is the one number in
    -- this payload that differs per player, and the queued id list is already
    -- on the wire -- so one broadcast still serves everyone. Sending it from
    -- the server would mean 48 targeted messages to say 48 different things.
    local party
    if S.party and S.party.members then
        local queued = 0
        for _, m in ipairs(S.party.members) do
            for _, src in ipairs(d.ids or {}) do
                if src == m.src then queued = queued + 1 break end
            end
        end
        party = { ready = queued, size = #S.party.members }
    end

    TriggerEvent('br:ui:sendLocal', BR.Nui.LOBBY, {
        queued    = d.queued,
        needed    = d.needed,
        connected = d.connected,
        mode      = d.mode,
        you       = you,
        players   = others,
        wait      = d.wait,
        party     = party,
        -- Who has readied up, so the party panel can mark which members are
        -- still holding the group. The id list is already on the wire in
        -- this same broadcast -- forwarding it reveals nothing new.
        readyIds  = d.ids or {},
    })
end)

-- --------------------------------------------------------------------------
-- HUD
-- --------------------------------------------------------------------------

local lastPush = { hp = -1, armour = -1, alive = -1, squads = -1, kills = -1,
                   state = '', paused = nil, landed = nil, watching = nil }

--- Send the HUD envelope, but only when something actually changed.
---
--- The bridge to br_ui crosses a resource boundary, and the HUD is the most
--- frequent thing on it. Pushing unconditionally at 10Hz would mean 600 pointless
--- messages a minute while a player stands still.
--- @param force boolean|nil
function BR.PushHud(force)
    -- HELD WHILE THE CURTAIN IS GOING UP. This is the channel the lobby-to-HUD
    -- cut actually travelled down: `state` here is what App.tsx reads to decide
    -- the lobby is over. See uiHold at the top of this file.
    if uiHold then return end

    local me = S.me
    local hp     = math.floor(me.hp or 0)
    local armour = math.floor(me.armour or 0)

    -- A DOWNED PLAYER READS ZERO, whatever their ped says.
    --
    -- The ledger parks them a few points above zero so the shooter's copy of
    -- them stays correctable (see dbnoHp in config/match.lua), and the local
    -- vitals loop reads that off the ped -- so the bar sat at a sliver of green
    -- while the bleed countdown was the real number (owner, in game). Their
    -- health IS the countdown now; the bar is empty because that is true, and
    -- showing 5% would be claiming they can take a hit.
    if me.state == BR.PlayerState.DBNO then
        hp, armour = 0, 0
    end

    -- ═══ WHILE SPECTATING, THE BARS ARE THE PERSON ON SCREEN ═══
    --
    -- "the health/shield/inventory don't show properly. They should be fully
    -- populated" -- the owner. They were populated; they were populated with
    -- the DEAD VIEWER's numbers, which are zero and zero, so the HUD read as
    -- broken. The camera changed subject and the vitals did not.
    --
    -- IT IS THE ROSTER MIRROR AND NOT A NEW WIRE. `hp` and `armour` are in
    -- roster.lua's PUBLIC_FIELDS, so this client is already told them for every
    -- player in the match, 2 Hz, whether it is spectating or not. Asking the
    -- server to send them a second time down the spectate feed would be two
    -- representations of one fact -- the bug this project is named for in half
    -- its comments -- and would leak nothing extra either way, because there is
    -- nothing extra to leak. THE INVENTORY IS THE OPPOSITE CASE and is handled
    -- where it belongs, in client/inventory.lua: it is not public, so it does
    -- come down the session's own feed.
    --
    -- A TARGET WITH NO ROSTER ROW LEAVES THE VIEWER'S OWN NUMBERS ALONE rather
    -- than zeroing. A missing row means a delta in flight or a player already
    -- gone, and the session is about to end on the server's own licence check.
    -- Painting 0/0 for that frame would flash an empty bar on the way out,
    -- which is the reported symptom.
    local watching = BR.Spectate and BR.Spectate.targetSrc
        and BR.Spectate.targetSrc() or nil
    if watching then
        local t = S.roster[watching]
        if t then
            hp     = math.floor(t.hp or 0)
            armour = math.floor(t.armour or 0)
            -- THE SAME DBNO RULE, APPLIED TO THEM. A downed player's ledger
            -- parks them a few points above zero so the shooter's copy stays
            -- correctable; their health IS the bleed countdown. A spectator
            -- watching a squadmate bleed out must see the same empty bar the
            -- squadmate sees, not the sliver the ledger holds.
            if t.state == BR.PlayerState.DBNO then
                hp, armour = 0, 0
            end
        end
    end
    local kills  = (S.roster[me.src] and S.roster[me.src].kills) or 0
    -- The HUD gets out of the way of the pause menu (the map fills the
    -- screen and our chrome floats over it otherwise).
    local paused = IsPauseMenuActive()
    -- Whole numbers: the bar cannot show fractions and fractional churn
    -- would defeat the dedupe below.
    local stamina = math.floor((S.stamina or 100.0) + 0.5)

    -- MY FEET ARE ON THE GROUND, WHATEVER THE SERVER STILL THINKS.
    --
    -- The interface hides the squad panel and the inventory bar for a player
    -- who is FREEFALL or GLIDE, which is right in the air and wrong the moment
    -- they touch down -- because the state that says so is the SERVER's, and it
    -- arrives when the landing report gets there. That report is the single
    -- most historically unreliable message in this project (see the long note
    -- above reportLanded in client/skydive.lua), and everything a landed player
    -- has hangs off it. When it is late the player stands in a POI with no
    -- inventory and half a HUD until something else -- in the worst case the
    -- match reaching PLAYING -- eventually promotes them (#126).
    --
    -- It was diagnosed as slowness and answered with speed: retries, a loot
    -- burst budget, a faster cell loop. They are not slow, they are OFF.
    --
    -- So this reports the second fact alongside the first: the server's state,
    -- AND my own ped's report that it has landed. The mirror is not corrupted
    -- to say it -- `state` still carries exactly what the server said, and
    -- nothing that MATTERS (damage, claims, placement) reads this. It is
    -- observation of our own ped, which is the one thing a client may always
    -- do, used for the one thing it is allowed to decide: what to draw.
    local landed = BR.State.landed == true

    if not force
       and hp == lastPush.hp and armour == lastPush.armour
       and S.alive == lastPush.alive and S.squadsAlive == lastPush.squads
       and kills == lastPush.kills and me.state == lastPush.state
       and paused == lastPush.paused and stamina == lastPush.stamina
       and landed == lastPush.landed
       -- WHO THE BARS ARE ABOUT IS PART OF WHAT CHANGED. Two squadmates on the
       -- same health are the same three numbers, so without this a cycle to the
       -- next target would dedupe away and the HUD would keep describing the
       -- previous one.
       and watching == lastPush.watching then
        return
    end

    lastPush.hp, lastPush.armour = hp, armour
    lastPush.alive, lastPush.squads = S.alive, S.squadsAlive
    lastPush.kills, lastPush.state = kills, me.state
    lastPush.paused = paused
    lastPush.stamina = stamina
    lastPush.landed = landed
    lastPush.watching = watching

    TriggerEvent('br:ui:sendLocal', BR.Nui.HUD, {
        hp          = hp,
        armour      = armour,
        alive       = S.alive,
        squadsAlive = S.squadsAlive,
        kills       = kills,
        state       = me.state,
        paused      = paused,
        stamina     = stamina,
        landed      = landed,
    })
end

--- Squad panel data, assembled from the mirror.
---
--- ONE channel, TWO sources, and the fallback between them matters.
---
--- A SQUAD is per-match and dies with the match; a PARTY persists. Both feed
--- BR.Nui.SQUAD. This function used to send an empty payload whenever squadId
--- was nil, which meant that the moment a match ended and Match.reset cleared
--- squadId, this loop overwrote the party the server was still holding -- so
--- players who had queued together were told, on the lobby screen, that they
--- were in no party at all. The party was fine; only the display was destroyed,
--- roughly four times a second.
---
--- Falling back to the party keeps the panel showing the group that actually
--- still exists.
function pushSquadOrParty()
    local me = S.me

    -- THE PARTY GOES OUT EVERY TIME, on its own channel, whatever the squad
    -- channel ends up carrying. Mid-match the two are different groups and
    -- the squad wins the SQUAD channel -- so without this the interface can
    -- see who it is fighting with and has no idea who it is PARTIED with,
    -- which is exactly what in-match party management needs to know.
    local party = S.party
    TriggerEvent('br:ui:sendLocal', BR.Nui.PARTY,
        party and { id = party.id, leader = party.leader,
                    members = party.members, pending = party.pending,
                    you = me.src }
              or  { id = nil, members = {}, you = me.src })

    -- `you` rides along on every payload. The interface has no other way to
    -- know its own server id, and without it "am I the leader?" degenerates to
    -- "does this party have a leader?" -- which is true for everyone, so every
    -- member was shown leader-only controls the server would then refuse.
    if not me.squadId then
        local p = S.party
        TriggerEvent('br:ui:sendLocal', BR.Nui.SQUAD,
            p and { id = p.id, leader = p.leader, members = p.members,
                    pending = p.pending, you = me.src }
              or  { id = nil, members = {}, you = me.src })
        return
    end

    local members = {}
    for src, e in pairs(S.roster) do
        if e.squadId == me.squadId then
            -- THE BLEED CLOCK COMES OFF THE SQUAD BEACON, NOT THE ROSTER, and
            -- that is the whole point of it. `dbnoUntil` is deliberately absent
            -- from PUBLIC_FIELDS -- on the public set it would hand every
            -- enemy the exact second a downed player expires. The beacon is
            -- already squad-only, so this is the channel that may carry it.
            local b = BR.Squadmates and BR.Squadmates.beaconOf
                and BR.Squadmates.beaconOf(src)
            members[#members + 1] = {
                src = src, name = e.name, state = e.state,
                hp = e.hp or 0, armour = e.armour or 0,
                -- Absent unless they are down. The panel renders nothing at all
                -- for a missing value rather than seeding a local countdown
                -- that would drift from the server and keep ticking through a
                -- revive.
                bleedEndsAt = b and b.bleedEndsAt or nil,
                -- THE LEVEL COMES OFF THE SAME BEACON, AND FOR THE SAME
                -- REASON. It is not in PUBLIC_FIELDS -- the owner asked to see
                -- his TEAMMATES' levels, and the public roster goes to the
                -- whole match. The server derives it from lifetime XP on every
                -- push (see levelOf in server/party.lua); nothing is derived
                -- here, because a client that computed its own would eventually
                -- disagree with the lobby about what level somebody is.
                --
                -- ABSENT UNTIL THE SERVER KNOWS IT. nil travels as "no level on
                -- the wire" and the panel draws nothing rather than a 1 it
                -- would have to take back.
                level = b and b.level or nil,

                -- THIS MATE'S VOICE CARRIES NOTHING -- ONE BIT, OFF THE SAME
                -- SQUAD-ONLY BEACON, AND IT IS THE ONLY VOICE FACT ON HERE.
                --
                -- Owner, 2026-08-29: "the squad panel works, but doesn't
                -- accurately show when others in the squad have 'off'
                -- selected", and then "Why can't we build another client ->
                -- server -> squad hop?"
                --
                -- WHAT MUST NOT FOLLOW IT IS THE MODE. 'nearby' and 'squad'
                -- are one value away and they are the value this payload is
                -- forbidden to carry: which of the two a mate is on is only
                -- meaningful next to how far away they are, so a panel that
                -- drew it would be a proximity sensor for players this client
                -- cannot see. tools/check_squad_voice.lua permits `voiceOff`
                -- here BY NAME and fails the build on any other voice field --
                -- so widening this is a decision somebody has to make on
                -- purpose, in that file, rather than one line of drift here.
                --
                -- ABSENT MEANS NOTHING TO DRAW, exactly as the two fields above
                -- do. A mate whose voice is fine, a mate the beacon has not
                -- covered yet and an older server all produce an empty slot,
                -- which is the honest rendering of all three.
                voiceOff = b and b.voiceOff or nil,
            }
        end
    end
    table.sort(members, function(a, b) return a.src < b.src end)

    -- THE PANEL'S COLOUR IS THE PLAYER'S BLIP COLOUR, NOT THE SQUAD'S.
    --
    -- This used to send `e.colour`, which is the colour of the SQUAD -- shared
    -- by all four of them. So the panel drew four identical stripes while the
    -- same four people had four different dots on the minimap and four
    -- different destination beams, and the one place you look to work out
    -- WHICH teammate is in trouble was the one place that would not tell you
    -- (user, 2026-08-08). markers.lua and squadmates.lua both learned this
    -- lesson already; this is the third consumer.
    --
    -- The index is derived exactly as the server derives it in
    -- BR.Party.memberIndex -- squad members sorted by server id -- so it
    -- agrees with the beacons without needing a round trip. The sort above IS
    -- that ordering; do not reorder this list without moving this loop.
    for i, m in ipairs(members) do
        m.colour = BR.SquadColour(i).hex
    end

    TriggerEvent('br:ui:sendLocal', BR.Nui.SQUAD,
        { id = me.squadId, members = members, you = me.src })
end

-- Local vitals. Read from our own ped, which is always in our own scope --
-- the one player a client can legitimately observe directly. The server still
-- holds the authoritative value and will correct us.
BR.Loop.register(BR.Loop.TICK, 'state.vitals', function()
    local ped = PlayerPedId()
    S.me.hp     = BR.ToDisplayHp(GetEntityHealth(ped))
    S.me.armour = GetPedArmour(ped)
    BR.PushHud()
end)

BR.Loop.register(BR.Loop.SLOW, 'state.squad', pushSquadOrParty)

-- Clock sync: fast at first so countdowns are usable immediately, then slow.
local pings = 0
BR.Loop.register(BR.Loop.SLOW, 'state.clock', function()
    pings = pings + 1
    if pings <= 8 or pings % 30 == 0 then
        pingClock()
    end
end)

-- Snapshot requests.
--
-- br_ui announces itself with br:ui:ready, which may arrive before or after this
-- file loads, and again every time br_ui restarts.
--
-- br:ui:ready ALWAYS re-requests. That matters for more than tidiness: the
-- snapshot is what re-applies NUI focus, and if a snapshot arrived while br_ui
-- was still loading, nothing was listening for the focus event. Guarding the
-- ready path would leave the player with a visible, unfocused, unclickable
-- lobby and no way to recover short of reconnecting.
local askedForSnapshot = false

AddEventHandler('br:ui:ready', function()
    mark('uiReady')
    askedForSnapshot = true
    TriggerServerEvent(BR.Net.READY)
end)

RegisterCommand('brboot', function()
    print('[br_core] boot timeline (ms since br_core start)')
    for _, k in ipairs({ 'uiReady', 'snapshot', 'focus' }) do
        print(('  %-9s %s'):format(k, boot[k] and (boot[k] .. 'ms') or 'never'))
    end
    print(('  total    %dms since start'):format(GetGameTimer() - boot.t0))
end, false)

AddEventHandler('onClientResourceStart', function(res)
    if res ~= GetCurrentResourceName() then return end

    -- THE PAGE OUTLIVES THIS RESOURCE, AND NOTHING ELSE IN THE CLIENT KNOWS IT
    -- (#204).
    --
    -- br_ui is a separate resource with a separate lifetime. `restart br_core`
    -- mid-match gives us a fresh Lua state in front of a CEF document still
    -- holding every envelope sent before the restart -- and for the death word
    -- that means show=true with the deadline that would have retired it gone
    -- from the only process that had it. Not a screen that lingers for ten
    -- seconds: one that never comes down at all, which is the failure that is
    -- worse than the bug.
    --
    -- FORCED. A fresh deathVerdictUntil is 0, so an ordinary dismissal is a
    -- no-op in precisely the case that needs it.
    --
    -- SAFE IN THE DIRECTION IT CAN BE WRONG. If nothing was up, the page is told
    -- a surface it is not drawing is down. If br_ui is not running yet the event
    -- reaches nobody -- and a page that does not exist is not holding a stale
    -- one, because its own start will re-request everything from here.
    dismissMatchSurfaces(true)

    -- Fallback only: if br_ui started first, its ready event is already gone and
    -- we would otherwise sit with an empty mirror forever.
    --
    -- 250ms rather than 2s. This is a floor on how long a player can stare at
    -- nothing whenever the start order goes that way, and the cost of being
    -- wrong is one extra snapshot -- the handler is idempotent and the server
    -- answers it happily. Two seconds bought nothing for that.
    Citizen.SetTimeout(250, function()
        if not askedForSnapshot then
            askedForSnapshot = true
            TriggerServerEvent(BR.Net.READY)
        end
    end)
    Citizen.SetTimeout(500, pingClock)
end)
