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

--- The heartbeat: counts every client needs but nobody needs instantly.
---
--- Sent unconditionally rather than on change, because it is also how a client
--- that missed a delta re-converges without needing a full snapshot.
local function digest()
    TriggerClientEvent(BR.Net.DIGEST, -1, {
        alive       = BR.Server.aliveCount(),
        squadsAlive = BR.Server.squadsAlive(),
        connected   = BR.Server.count(),
        state       = BR.Server.match.state,
        endsAt      = BR.Server.match.endsAt,
        serverNow   = GetGameTimer(),
    })
end

--- Everything a client needs to rebuild its mirror from nothing.
---
--- Sent on join and whenever a client asks (br_ui restarting, for instance).
--- Deltas are an optimisation on top of this; the snapshot is what makes them
--- safe, because any client that falls behind can always be re-seeded.
---
--- @param src integer|nil  a single player, or nil for everyone
function BR.Broadcast.snapshot(src)
    local payload = {
        seq       = seq,
        roster    = BR.Roster.publicAll(),
        match     = {
            state  = BR.Server.match.state,
            mode   = BR.Server.match.mode,
            endsAt = BR.Server.match.endsAt,
        },
        alive       = BR.Server.aliveCount(),
        squadsAlive = BR.Server.squadsAlive(),
        serverNow   = GetGameTimer(),
        storm       = BR.Server.storm,
    }

    if src then
        TriggerClientEvent(BR.Net.SNAPSHOT, src, payload)
    else
        TriggerClientEvent(BR.Net.SNAPSHOT, -1, payload)
    end
end

--- Announce a match state transition.
---
--- Flushes queued deltas first: a client must not learn the match started before
--- it learns who is in it.
--- @param state string
--- @param endsAt number
--- @param meta table|nil
function BR.Broadcast.state(state, endsAt, meta)
    flush()
    TriggerClientEvent(BR.Net.STATE, -1, {
        state     = state,
        endsAt    = endsAt,
        mode      = BR.Server.match.mode,
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
