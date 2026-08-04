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
local function applyFocusForState(state)
    -- The lobby owns the screen when the MATCH is waiting -- or when this
    -- player personally is in the lobby while a match runs without them
    -- (left it, or never readied up). Match state alone was the wrong test
    -- the moment leaving a match became possible.
    if state == BR.MatchState.WAITING or S.me.state == BR.PlayerState.LOBBY then
        mark('focus')
        TriggerEvent('br:ui:pushFocus', 'lobby')
    else
        TriggerEvent('br:ui:popFocus', 'lobby')
    end
end

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
    })
end

RegisterNetEvent(BR.Net.SNAPSHOT)
AddEventHandler(BR.Net.SNAPSHOT, function(payload)
    mark('snapshot')
    S.roster = payload.roster or {}
    S.match.state  = payload.match.state
    S.match.mode   = payload.match.mode
    S.match.endsAt = payload.match.endsAt
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
    local was, wasEnd = S.match.state, S.match.endsAt
    S.match.state  = d.state or S.match.state
    S.match.endsAt = d.endsAt or S.match.endsAt
    if S.match.state ~= was or S.match.endsAt ~= wasEnd then
        pushMatchState()
        applyFocusForState(S.match.state)
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

    pushMatchState()

    -- The result screen. Placement rides roster deltas that flush AFTER the
    -- state broadcast (the transition flushes what came before it, then
    -- onEnter awards placements), so the mirror is read after a beat -- the
    -- screen is faded to black at this moment anyway. M7 fills in damage,
    -- survival time and XP; placement and kills already tell won-or-lost.
    if d.state == BR.MatchState.ENDED then
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
    elseif name == BR.NuiCb.SQUAD_LEAVE then
        TriggerServerEvent(BR.Net.SQUAD_LEAVE)
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

RegisterNetEvent(BR.Net.SQUAD_INVITED)
AddEventHandler(BR.Net.SQUAD_INVITED, function(inv)
    TriggerEvent('br:ui:sendLocal', BR.Nui.INVITE, inv)
end)

-- Server-pushed notices: party events, match alerts. Same UI stack as the
-- local action results, so a player has ONE place to glance at.
RegisterNetEvent(BR.Net.NOTIFY)
AddEventHandler(BR.Net.NOTIFY, function(n)
    TriggerEvent('br:ui:sendLocal', BR.Nui.TOAST, {
        text = n and n.text or '',
        tone = n and n.tone or 'info',
    })
end)

-- Eliminations, broadcast to everyone. Forwarded to the UI's kill feed --
-- and if the victim is ME, the cause is remembered for the verdict slam.
RegisterNetEvent(BR.Net.KILL_FEED)
AddEventHandler(BR.Net.KILL_FEED, function(d)
    if not d then return end

    if d.victimSrc == S.me.src then
        myDeathCause    = d.cause
        myDeathByPlayer = d.killerSrc ~= nil
    end

    -- Shaped to the UI's FeedEntry contract. weapon carries the cause until
    -- M6 brings real weapon attribution.
    TriggerEvent('br:ui:sendLocal', BR.Nui.FEED, {
        id       = BR.Clock.now(),
        killer   = d.killer or '',
        victim   = d.victim or '',
        weapon   = d.cause or '',
        headshot = false,
        mine     = d.victimSrc == S.me.src or d.killerSrc == S.me.src,
    })
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
    })
end)

-- --------------------------------------------------------------------------
-- HUD
-- --------------------------------------------------------------------------

local lastPush = { hp = -1, armour = -1, alive = -1, squads = -1, kills = -1, state = '' }

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

    if not force
       and hp == lastPush.hp and armour == lastPush.armour
       and S.alive == lastPush.alive and S.squadsAlive == lastPush.squads
       and kills == lastPush.kills and me.state == lastPush.state then
        return
    end

    lastPush.hp, lastPush.armour = hp, armour
    lastPush.alive, lastPush.squads = S.alive, S.squadsAlive
    lastPush.kills, lastPush.state = kills, me.state

    TriggerEvent('br:ui:sendLocal', BR.Nui.HUD, {
        hp          = hp,
        armour      = armour,
        alive       = S.alive,
        squadsAlive = S.squadsAlive,
        kills       = kills,
        state       = me.state,
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
                colour = e.colour or '#6EE7F9',
            }
        end
    end
    table.sort(members, function(a, b) return a.src < b.src end)

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
