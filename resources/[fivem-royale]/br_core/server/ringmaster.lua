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
