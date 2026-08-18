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
--- Both paths are idempotent: pushFocus ignores a screen already on the stack.
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
        if st == BR.PlayerState.LOBBY then BR.NotifyClear() end
    end
    if st == BR.PlayerState.WARMUP or st == BR.PlayerState.BUS
       or st == BR.PlayerState.FREEFALL or st == BR.PlayerState.GLIDE
       or st == BR.PlayerState.ALIVE or st == BR.PlayerState.DBNO then
        if not roundParticipant then
            roundParticipant = true
            pushMatchState()
        end
    elseif st == BR.PlayerState.LOBBY
       and S.match.state ~= BR.MatchState.ENDED
       and S.match.state ~= BR.MatchState.CLEANUP then
        -- Becoming LOBBY while the match is still running means I LEFT the
        -- round (brleave). Someone who once touched the warmup and then sat
        -- out kept the flag, and the match's ending slammed ELIMINATED over
        -- their lobby menu (live report, twice). The teardown flip to LOBBY
        -- is different: by then match.state already reads ended, so real
        -- participants keep their verdict.
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

    -- REPLAY THE ONE TRANSITION the broadcast can never deliver: WAITING.
    -- Under parallel matches, STATE events are scoped to a match's audience
    -- -- a player who LEAVES one stops hearing about it, and their digest
    -- flipping to WAITING is the only signal the round is over for them.
    -- Every subsystem keyed on the STATE event (route line, markers, island,
    -- the skydive latch) must still run its teardown, so that transition is
    -- re-fired locally -- TriggerEvent reaches the same handlers.
    --
    -- WAITING ONLY, deliberately: for any in-match state the real event
    -- always arrives (the player is in the audience), and replaying those
    -- races the wire into DOUBLED side effects -- an early digest re-firing
    -- 'bus' was part of the duplicated-parachute report (2026-08-04).
    if S.match.state ~= was and S.match.state == BR.MatchState.WAITING then
        TriggerEvent(BR.Net.STATE, {
            state     = S.match.state,
            endsAt    = S.match.endsAt,
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
end)

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
    if not netId or BR.IsDeadHp(hp) then return end

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
        return
    end
    watching[netId] = nil

    if not NetworkDoesNetworkIdExist(netId) then return end

    local ped = NetworkGetEntityFromNetworkId(netId)
    if not ped or ped == 0 or not DoesEntityExist(ped) then return end

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
                if ped and ped ~= 0 and DoesEntityExist(ped)
                   and IsEntityDead(ped) then
                    -- The mirror carries DISPLAY units; a ped takes engine
                    -- ones. Never inline this arithmetic (config/match.lua).
                    local target =
                        math.floor(BR.ToEngineHp(e.hp or 100.0) + 0.5)
                    -- A player the ledger has on the floor is not somebody to
                    -- resurrect INTO a value that keeps them dead -- the same
                    -- guard correctPed opens with, and for the same reason.
                    if not BR.IsDeadHp(target) then
                        falseCorpses = falseCorpses + 1
                        ResurrectPed(ped)
                        ClearPedTasksImmediately(ped)
                        SetEntityHealth(ped, target)
                        -- Whether that took is the engine's to say, and the
                        -- next line is the only place it can be asked.
                        if IsEntityDead(ped) then
                            falseCorpsesStuck = falseCorpsesStuck + 1
                        end
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
    print(('    STILL DEAD ON THE LINE AFTER RESURRECTING: %s   <-- true here '
           .. 'means the engine refused the write, not that the logic missed it')
        :format(tostring(w.stillDeadAfterWrite)))

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
    print(('  standing check: found a false corpse %d time(s) this session '
           .. '(a ped the server calls ALIVE, reading dead here); %d of those '
           .. 'were STILL dead on the line after the write')
        :format(falseCorpses, falseCorpsesStuck))
    print('    found high and stuck ~0  = the corpses are real and being fixed.')
    print('    found and stuck climbing together = the ENGINE is refusing our')
    print('      writes to a ped we do not own, and no Lua here can fix that --')
    print('      the repair has to come from the ped\'s owner.')
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
                   state = '', paused = nil, landed = nil }

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
       and landed == lastPush.landed then
        return
    end

    lastPush.hp, lastPush.armour = hp, armour
    lastPush.alive, lastPush.squads = S.alive, S.squadsAlive
    lastPush.kills, lastPush.state = kills, me.state
    lastPush.paused = paused
    lastPush.stamina = stamina
    lastPush.landed = landed

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
