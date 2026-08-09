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

-- ESC IN THE LOBBY RAISES GTA'S PAUSE MENU. With NUI focused the engine
-- never sees the key, so the page captures it, fades itself out, drops
-- focus (nui.lua), and hands over here. The beat before ActivateFrontendMenu
-- lets the fade land; the watcher below gives the lobby its focus back the
-- moment the menu closes -- if the player is still a lobby player.
local pausePhase, pauseAt = nil, 0

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
        if S.party and S.party.id then
            TriggerServerEvent(BR.Net.SQUAD_LEAVE)
        end
        -- The existing, proven leave path -- interstitial, server round trip,
        -- teleport home -- rather than a second implementation of it.
        ExecuteCommand('brleave')

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

AddEventHandler('br:ui:pauseRequest', function()
    Citizen.SetTimeout(250, function()
        ActivateFrontendMenu(GetHashKey('FE_MENU_VERSION_SP_PAUSE'), false, -1)
        pausePhase, pauseAt = 'raising', GetGameTimer()
    end)
end)

BR.Loop.register(BR.Loop.TICK, 'state.pausewatch', function()
    if not pausePhase then return end
    local active = IsPauseMenuActive()
    if pausePhase == 'raising' then
        if active then
            pausePhase = 'open'
        elseif GetGameTimer() - pauseAt > 2000 then
            -- The menu never came up; do not strand the player focusless.
            pausePhase = nil
            if S.me.state == BR.PlayerState.LOBBY then
                TriggerEvent('br:ui:pushFocus', 'lobby')
            end
        end
    elseif pausePhase == 'open' and not active then
        pausePhase = nil
        if S.me.state == BR.PlayerState.LOBBY then
            TriggerEvent('br:ui:pushFocus', 'lobby')
        end
    end
end)

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
local function pushMatchState()
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
        lastNoted = st
        if OUR_SCREEN[st] and IsPauseMenuActive() then
            SetFrontendActive(false)
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
                damage     = 0,
                survivedMs = 0,
                xpEarned   = 0,
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
--- ONE PASS, OR SEVERAL. A ped that is merely WRONG needs one write. A ped
--- that has entered the DEATH STATE needs resurrecting, and needs it more than
--- once: the correction arrives a round trip after the engine applied the
--- damage locally, so the ped can still be mid-death when the first attempt
--- lands and the death completes over the top of it.
---
--- Spawning a thread per correction would be wasteful on the common path --
--- one arrives per bullet -- so the retry loop is only entered when there is
--- actually a corpse to argue with.
--- @param netId integer
--- @param hp integer   ENGINE units
local function correctPed(netId, hp)
    if not netId or hp <= 0 then return end
    if not NetworkDoesNetworkIdExist(netId) then return end

    local ped = NetworkGetEntityFromNetworkId(netId)
    if not ped or ped == 0 or not DoesEntityExist(ped) then return end

    if not IsEntityDead(ped) then
        -- Only ever UPWARD. Writing it down would be us arguing with the
        -- owner's own sync about a ped we do not own, for no gain.
        if GetEntityHealth(ped) < hp then SetEntityHealth(ped, hp) end
        return
    end

    -- A CORPSE THAT SHOULD NOT BE ONE. ResurrectPed alone leaves the death
    -- TASK running, so the ped stands up and immediately plays dying again;
    -- clearing tasks is what actually ends it. Before this, the body lay
    -- there for the better part of ten seconds until OneSync re-created it
    -- (user, 2026-08-08).
    Citizen.CreateThread(function()
        for _ = 1, 6 do
            if not NetworkDoesNetworkIdExist(netId) then return end
            local p = NetworkGetEntityFromNetworkId(netId)
            if not p or p == 0 or not DoesEntityExist(p) then return end

            if IsEntityDead(p) then
                ResurrectPed(p)
                ClearPedTasksImmediately(p)
                SetEntityHealth(p, hp)
            elseif GetEntityHealth(p) < hp then
                SetEntityHealth(p, hp)
                return
            else
                return   -- already correct; the owner's sync got there first
            end
            Citizen.Wait(150)
        end
    end)
end

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
        correctPed(d.netId, math.floor(tonumber(d.hp) or 0))
    end
end)

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
    correctPed(d.netId, math.floor(tonumber(d.hp) or 0))
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
                   state = '', paused = nil }

--- Send the HUD envelope, but only when something actually changed.
---
--- The bridge to br_ui crosses a resource boundary, and the HUD is the most
--- frequent thing on it. Pushing unconditionally at 10Hz would mean 600 pointless
--- messages a minute while a player stands still.
--- @param force boolean|nil
function BR.PushHud(force)
    local me = S.me
    local hp     = math.floor(me.hp or 0)
    local armour = math.floor(me.armour or 0)
    local kills  = (S.roster[me.src] and S.roster[me.src].kills) or 0
    -- The HUD gets out of the way of the pause menu (the map fills the
    -- screen and our chrome floats over it otherwise).
    local paused = IsPauseMenuActive()
    -- Whole numbers: the bar cannot show fractions and fractional churn
    -- would defeat the dedupe below.
    local stamina = math.floor((S.stamina or 100.0) + 0.5)

    if not force
       and hp == lastPush.hp and armour == lastPush.armour
       and S.alive == lastPush.alive and S.squadsAlive == lastPush.squads
       and kills == lastPush.kills and me.state == lastPush.state
       and paused == lastPush.paused and stamina == lastPush.stamina then
        return
    end

    lastPush.hp, lastPush.armour = hp, armour
    lastPush.alive, lastPush.squads = S.alive, S.squadsAlive
    lastPush.kills, lastPush.state = kills, me.state
    lastPush.paused = paused
    lastPush.stamina = stamina

    TriggerEvent('br:ui:sendLocal', BR.Nui.HUD, {
        hp          = hp,
        armour      = armour,
        alive       = S.alive,
        squadsAlive = S.squadsAlive,
        kills       = kills,
        state       = me.state,
        paused      = paused,
        stamina     = stamina,
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
            members[#members + 1] = {
                src = src, name = e.name, state = e.state,
                hp = e.hp or 0, armour = e.armour or 0,
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
