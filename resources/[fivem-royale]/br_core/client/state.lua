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
    if state == BR.MatchState.WAITING then
        TriggerEvent('br:ui:pushFocus', 'lobby')
    else
        TriggerEvent('br:ui:popFocus', 'lobby')
    end
end

RegisterNetEvent(BR.Net.SNAPSHOT)
AddEventHandler(BR.Net.SNAPSHOT, function(payload)
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
            else
                -- An update for someone we do not know about means we missed
                -- their add. Take what we were given rather than dropping them.
                S.roster[d.src] = d.e
            end
        end

        if d.src == S.me.src and d.e then
            for k, v in pairs(d.e) do
                if S.me[k] ~= nil or k == 'squadId' then S.me[k] = v end
            end
        end
    end

    BR.PushHud()
end)

RegisterNetEvent(BR.Net.DIGEST)
AddEventHandler(BR.Net.DIGEST, function(d)
    S.alive       = d.alive or 0
    S.squadsAlive = d.squadsAlive or 0
    S.match.state = d.state or S.match.state
    S.match.endsAt = d.endsAt or S.match.endsAt
    BR.PushHud()
end)

RegisterNetEvent(BR.Net.STATE)
AddEventHandler(BR.Net.STATE, function(d)
    S.match.state  = d.state
    S.match.endsAt = d.endsAt
    S.match.mode   = d.mode or S.match.mode

    TriggerEvent('br:ui:sendLocal', BR.Nui.STATE, {
        state     = d.state,
        mode      = S.match.mode,
        endsAt    = d.endsAt,
        serverNow = BR.Clock.now(),
    })

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
    elseif name == BR.NuiCb.SQUAD_LEAVE then
        TriggerServerEvent(BR.Net.SQUAD_LEAVE)
    elseif BR.Server and BR.Server.devMode then
        print(('[br_core] unhandled UI action: %s'):format(tostring(name)))
    end
end)

RegisterNetEvent(BR.Net.LOBBY_STATUS)
AddEventHandler(BR.Net.LOBBY_STATUS, function(d)
    TriggerEvent('br:ui:sendLocal', BR.Nui.LOBBY, d)
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
local function pushSquad()
    local me = S.me
    if not me.squadId then
        TriggerEvent('br:ui:sendLocal', BR.Nui.SQUAD, { id = nil, members = {} })
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

    TriggerEvent('br:ui:sendLocal', BR.Nui.SQUAD, { id = me.squadId, members = members })
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

BR.Loop.register(BR.Loop.SLOW, 'state.squad', pushSquad)

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
    askedForSnapshot = true
    TriggerServerEvent(BR.Net.READY)
end)

AddEventHandler('onClientResourceStart', function(res)
    if res ~= GetCurrentResourceName() then return end

    -- Fallback only: if br_ui started first, its ready event is already gone and
    -- we would otherwise sit with an empty mirror forever.
    Citizen.SetTimeout(2000, function()
        if not askedForSnapshot then
            askedForSnapshot = true
            TriggerServerEvent(BR.Net.READY)
        end
    end)
    Citizen.SetTimeout(500, pingClock)
end)
