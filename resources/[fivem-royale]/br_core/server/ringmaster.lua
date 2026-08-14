-- br_core's half of the Ringmaster feed: the snapshot broadcast.
--
-- br_core knows the roster; br_ringmaster knows the wire. This file is the
-- boundary between them, and it is a server-side TriggerEvent rather than an
-- export on purpose -- events are this project's cross-resource idiom (br_ui
-- publishes both and br_core consumes only the event form), and neither
-- resource has to be running for the other to load. `restart br_ringmaster`
-- misses at most one interval; `restart br_core` re-registers the job and the
-- feed resumes on the next hello.
--
-- NOTHING HERE LISTENS. This file emits state and nothing else -- the
-- ringmaster -> core direction (the drain flag, config edits) is Slice 4's
-- `br:core:control`, deliberately absent until there is an audit log to
-- record it.

BR = BR or {}
BR.RingFeed = {}

-- Push only while somebody is listening. br_ringmaster says hello on its
-- start (and re-hellos if the feed goes quiet), so an unconfigured or absent
-- console costs br_core nothing but this boolean staying false.
local subscribed = false
local intervalMs = 2000
local job = nil

--- The player-list cap, and the honesty flag that travels with it.
---
--- The snapshot is a full list with no delta encoding. Fine at 48; at the
--- 2048 this project is heading for it would be megabytes per second, so the
--- cap exists from day one and `truncated` says when it bit -- a short list
--- that LOOKS complete is the one failure a moderation view must never
--- produce.
local MAX_PLAYERS = 512

local function matchRows()
    local out = {}
    BR.Server.eachMatch(function(m)
        out[#out + 1] = {
            id          = m.id,
            state       = m.state,
            mode        = m.mode,
            bucket      = m.bucket or 0,
            endsAt      = m.endsAt,
            alive       = BR.Server.aliveCount(m),
            squadsAlive = BR.Server.squadsAlive(m),
        }
    end)
    return out
end

--- The anticheat's live settings, for the console's Anticheat page.
---
--- SENT RATHER THAN DOCUMENTED. A console page that hardcodes "eight refusals
--- in ten seconds" lies the day somebody edits config/match.lua, and a page
--- that describes the threshold wrongly is worse than one that says it does not
--- know.
---
--- WHAT IT DOES ABOUT A FIRING IS NO LONGER A SETTING. `refusalAction` is gone:
--- crossing the threshold files an incident, always, and Ringmaster decides what
--- follows. `action` is reported as the constant `incident` so the console reads
--- what happened from the wire rather than inferring it from a build number --
--- and so an older console, whose schema only knows log/notify/kick, is the one
--- thing that must be updated first.
---
--- IT LIVES HERE RATHER THAN IN br_ringmaster because BR.Config is br_core's.
--- FiveM gives each resource its own Lua state, so br_ringmaster -- which
--- deliberately does not depend on br_core -- cannot see it at all, and the
--- first version of this read nil forever from over there.
---
--- Rides the snapshot rather than taking a channel of its own: five numbers
--- next to a player array, on a broadcast that already runs.
local function anticheatBlock()
    local cfg = BR.Config and BR.Config.Combat
    if not cfg then return nil end

    local bar = cfg.refusalBar or {}

    return {
        -- Constant, and kept on the wire anyway: the console records what the
        -- server did rather than deducing it. The day this becomes configurable
        -- again, nothing on the receiving side has to change to notice.
        action     = 'incident',

        -- THE BAR, PER TIER. Replaces a single `limit` in a rolling window, and the
        -- console's Anticheat page reads it from here rather than describing it
        -- from memory -- which is the whole reason this block exists.
        barHigh    = bar.high or 0,
        barNormal  = bar.normal or 0,

        -- `limit` AND `windowMs` STAY ON THE WIRE, ZEROED. Removing a field is the
        -- one change that needs an envelope version bump (docs/ingest-envelope.md),
        -- and a console one deploy behind would render "0 in 0s" -- wrong, but
        -- visibly wrong, rather than crashing its schema on a missing key. They go
        -- for real once no console can still be reading them.
        limit      = 0,
        windowMs   = cfg.refusalWindowMs or 0,

        selfLimit  = cfg.selfLimit or 0,
        selfWindow = cfg.selfWindowMs or 0,
    }
end

local function snapshot()
    local players = BR.Roster.ringmasterAll()

    local truncated = false
    if #players > MAX_PLAYERS then
        for i = #players, MAX_PLAYERS + 1, -1 do
            players[i] = nil
        end
        truncated = true
    end

    local inMatch = 0
    for _, p in ipairs(players) do
        if BR.Server.isInMatch(p.state) then inMatch = inMatch + 1 end
    end

    return {
        takenGameMs = GetGameTimer(),
        counts      = { connected = BR.Server.count(), inMatch = inMatch },
        truncated   = truncated,
        matches     = matchRows(),
        players     = players,
        anticheat   = anticheatBlock(),
    }
end

local function ensureJob()
    if job then BR.Sched.cancel(job) end
    job = BR.Sched.every(intervalMs, 'ringfeed.snapshot', function()
        if not subscribed then return end
        TriggerEvent('br:ringmaster:snapshot', snapshot())
    end)
end

--- br_ringmaster announcing itself. Carries the interval so the cadence is
--- the consumer's decision -- the side with the outbox knows how fast it can
--- drain.
AddEventHandler('br:ringmaster:hello', function(opts)
    subscribed = true
    local ms = tonumber(opts and opts.intervalMs)
    if ms and ms >= 250 and ms <= 60000 and ms ~= intervalMs then
        intervalMs = ms
        ensureJob()
    end
end)

ensureJob()
