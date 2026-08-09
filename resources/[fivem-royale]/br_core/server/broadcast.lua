-- Scope-independent fanout.
--
-- Every roster fact reaches clients through this file, and always via
-- TriggerClientEvent to -1 (or an explicit list of server ids). That is what
-- makes the roster survive OneSync: server events are not scope-limited, so a
-- player 3km away receives a kill feed entry exactly like one standing next to
-- the shooter.
--
-- COALESCING
--
-- The naive approach is to send each change as it happens. At 48 players a
-- squad wipe is a dozen state changes in the same tick, each becoming its own
-- packet to every client -- 12 x 48 sends for information that would fit in one.
-- So changes queue and flush on a timer, batched into a single array.
--
-- The exception is anything a player reacts to. A kill feed entry that arrives
-- 250ms late is fine; the storm starting to close is not. Those send immediately.

BR = BR or {}
BR.Broadcast = {}

local pending = {}       -- queued deltas, flushed on a timer
local seq = 0

--- Queue a roster delta.
--- @param delta table  { op = 'add'|'remove'|'update', src, e? }
function BR.Broadcast.delta(delta)
    pending[#pending + 1] = delta
end

--- Send everything queued, as one event.
local function flush()
    if #pending == 0 then return end

    seq = seq + 1
    local batch = pending
    pending = {}

    TriggerClientEvent(BR.Net.ROSTER_DELTA, -1, { seq = seq, deltas = batch })
end

--- Force an immediate flush. Used before anything that must not arrive out of
--- order behind queued deltas -- a match state change, or the summary.
function BR.Broadcast.flushNow()
    flush()
end

--- One notice for a player's on-screen notification stack.
---
--- This is the channel for events that happen TO a player -- an invite
--- declined, a party joined, a match left. Chat's system messages scroll away
--- with the conversation and were the only feedback channel until now, which is
--- how "the invite was declined" became information nobody received.
---
--- A NOTICE CAN BE ADDRESSED, NOT ONLY ADDED.
---
--- `opts.key` gives the notice an identity. Sending the same key again
--- REPLACES the row that is already on screen -- new text, new tone, new
--- deadline -- instead of stacking a second one or counting it as a repeat.
--- Everything else here is only useful because of that:
---
---   opts.endsAt  a deadline in SERVER time. The row grows a live countdown
---                and removes itself when it lands. This is the whole reason
---                the field exists: "your sticky bomb is inert for 30s" is
---                one notice with a moving number, not thirty notices.
---   opts.sticky  outlives its own event; only a clear removes it. For STATE
---                ("you are outside the storm"), never for events.
---   opts.ms      lifetime override, ignored when endsAt or sticky is set.
---
--- BR.Server.notifyClear(target, key) is the withdrawal.
---
--- @param target integer|integer[]  a server id, or a list of them
--- @param text string
--- @param tone string|nil  'info' | 'success' | 'warn' | 'danger'
--- @param opts table|nil   { key, ms, endsAt, sticky }
function BR.Server.notify(target, text, tone, opts)
    opts = opts or {}
    local payload = {
        text   = text,
        tone   = tone or 'info',
        key    = opts.key,
        ms     = opts.ms,
        endsAt = opts.endsAt,
        sticky = opts.sticky or nil,
    }
    if type(target) == 'table' then
        for _, src in ipairs(target) do
            TriggerClientEvent(BR.Net.NOTIFY, src, payload)
        end
    else
        TriggerClientEvent(BR.Net.NOTIFY, target, payload)
    end
end

--- Withdraw a keyed notice. Harmless if it is not on screen -- which matters,
--- because the sender generally cannot know: the player may have paused, the
--- notice may have aged out, br_ui may have restarted.
--- @param target integer|integer[]
--- @param key string
function BR.Server.notifyClear(target, key)
    local payload = { key = key, clear = true, text = '' }
    if type(target) == 'table' then
        for _, src in ipairs(target) do
            TriggerClientEvent(BR.Net.NOTIFY, src, payload)
        end
    else
        TriggerClientEvent(BR.Net.NOTIFY, target, payload)
    end
end

--- A match-wide alert. Same stack, every client.
--- @param text string
--- @param tone string|nil
--- @param opts table|nil
function BR.Server.notifyAll(text, tone, opts)
    opts = opts or {}
    TriggerClientEvent(BR.Net.NOTIFY, -1, {
        text   = text,
        tone   = tone or 'info',
        key    = opts.key,
        ms     = opts.ms,
        endsAt = opts.endsAt,
        sticky = opts.sticky or nil,
    })
end

--- Send one event to every member of a match's audience.
---
--- THE SCOPING PRIMITIVE of the parallel-matches model: match traffic --
--- state changes, storm records, bus routes, the kill feed -- reaches the
--- players attached to that instance and nobody else. A lobby bystander no
--- longer hears about anyone's match at all, which is also what keeps two
--- concurrent matches mutually invisible on the wire.
--- @param m table
--- @param event string
--- @param payload any
function BR.Broadcast.toMatch(m, event, payload)
    for _, src in ipairs(BR.Server.audience(m)) do
        TriggerClientEvent(event, src, payload)
    end
end

--- The heartbeat: counts every client needs but nobody needs instantly.
---
--- Sent unconditionally rather than on change, because it is also how a client
--- that missed a delta re-converges without needing a full snapshot. Each
--- player hears about THEIR match; players in no match get the WAITING view,
--- which is how a client's mirror settles back to the lobby after any exit.
local function digest()
    local now       = GetGameTimer()
    local connected = BR.Server.count()

    -- MODE RIDES THE DIGEST. It used to travel only on the STATE event, which
    -- a LATE JOINER never receives: they are attached to a match that is
    -- already in WARMUP, so no transition is broadcast for them and their
    -- mirror kept the lobby's default 'solo' until the next real transition.
    -- The visible symptom was a squad player's HUD hiding the squads counter
    -- through the whole warmup and correcting itself at the jump (user,
    -- 2026-08-05).
    local lobbyPayload = {
        alive       = 0,
        squadsAlive = 0,
        connected   = connected,
        state       = BR.MatchState.WAITING,
        mode        = BR.Mode.SOLO.key,
        endsAt      = 0,
        serverNow   = now,
    }

    local byMatch = {}   -- [matchId] = payload, built once per match
    BR.Server.eachMatch(function(m)
        byMatch[m.id] = {
            alive       = BR.Server.aliveCount(m),
            squadsAlive = BR.Server.squadsAlive(m),
            connected   = connected,
            state       = m.state,
            mode        = m.mode,
            endsAt      = m.endsAt,
            serverNow   = now,
        }
    end)

    BR.Roster.each(nil, function(src, e)
        TriggerClientEvent(BR.Net.DIGEST, src,
            (e.matchId and byMatch[e.matchId]) or lobbyPayload)
    end)
end

--- The match view one player should hold: their own instance, or the lobby's
--- WAITING idle.
--- @param src integer
--- @return table match, integer alive, integer squadsAlive, table|nil storm
local function viewFor(src)
    local m = BR.Server.matchOf(src)
    if m then
        return { state = m.state, mode = m.mode, endsAt = m.endsAt },
               BR.Server.aliveCount(m), BR.Server.squadsAlive(m), m.storm
    end
    return { state = BR.MatchState.WAITING, mode = BR.Mode.SOLO.key, endsAt = 0 },
           0, 0, nil
end

--- Everything a client needs to rebuild its mirror from nothing.
---
--- Sent on join and whenever a client asks (br_ui restarting, for instance).
--- Deltas are an optimisation on top of this; the snapshot is what makes them
--- safe, because any client that falls behind can always be re-seeded.
---
--- The roster is global (the lobby lists everyone), but the MATCH portion is
--- the receiver's own view -- so a snapshot with no target fans out as one
--- personalised send per player rather than one broadcast.
---
--- @param src integer|nil  a single player, or nil for everyone
function BR.Broadcast.snapshot(src)
    local roster = BR.Roster.publicAll()
    local now    = GetGameTimer()

    local function payloadFor(target)
        local match, alive, squadsAlive, storm = viewFor(target)
        return {
            seq         = seq,
            roster      = roster,
            match       = match,
            alive       = alive,
            squadsAlive = squadsAlive,
            serverNow   = now,
            storm       = storm,
            -- Both are the receiver's OWN view and both are why a mid-match
            -- br_ui restart recovers rather than showing an empty bar over a
            -- player holding a rifle. Loot rides the existing subscription --
            -- re-sending the cells they already had, not the whole map.
            inv         = BR.Inv and BR.Inv.publicFor(target) or nil,
            loot        = BR.Loot and BR.Loot.viewFor(target) or nil,
        }
    end

    if src then
        TriggerClientEvent(BR.Net.SNAPSHOT, src, payloadFor(src))
    else
        BR.Roster.each(nil, function(target)
            TriggerClientEvent(BR.Net.SNAPSHOT, target, payloadFor(target))
        end)
    end
end

--- Announce a match state transition, to that match's audience.
---
--- Flushes queued deltas first: a client must not learn the match started before
--- it learns who is in it.
--- @param m table
--- @param state string
--- @param endsAt number
--- @param meta table|nil
function BR.Broadcast.state(m, state, endsAt, meta)
    flush()
    BR.Broadcast.toMatch(m, BR.Net.STATE, {
        state     = state,
        endsAt    = endsAt,
        mode      = m.mode,
        serverNow = GetGameTimer(),
        meta      = meta,
    })
end

--- Send to one squad only.
---
--- Routed server-side by squad membership, never broadcast-and-filter. A
--- client-side filter is not a privacy boundary -- anyone reading the event
--- stream would see every squad's traffic.
--- @param squadId string|nil
--- @param event string
--- @param payload any
function BR.Broadcast.toSquad(squadId, event, payload)
    if not squadId then return end
    BR.Roster.each(
        function(e) return e.squadId == squadId end,
        function(src) TriggerClientEvent(event, src, payload) end)
end

-- Rates come from config so they can be tuned under load without hunting for
-- magic numbers.
local M = BR.Config.Match
BR.Sched.every(math.floor(1000 / M.deltaFlushHz), 'broadcast.deltas', flush)
BR.Sched.every(math.floor(1000 / M.digestHz),     'broadcast.digest', digest)

-- A joining client asks for a snapshot once its UI is ready. Requested rather
-- than pushed on join, because the client's NUI may not have loaded yet and a
-- snapshot that arrives before the UI exists is discarded.
RegisterNetEvent(BR.Net.READY)
AddEventHandler(BR.Net.READY, function()
    local src = source
    BR.Roster.add(src)          -- idempotent; covers a join we somehow missed
    BR.Broadcast.snapshot(src)
    if BR.Server.devMode then
        print(('[br_core] snapshot -> %d'):format(src))
    end
end)
