-- The wire: what br_ringmaster actually sends to the console.
--
-- TWO CHANNELS WITH OPPOSITE POLICIES, per docs/ingest-envelope.md, and mixing
-- them up is the one design error this file must not contain:
--
--   snapshots  STATE.    Latest wins. One slot, overwritten by every
--              br:ringmaster:snapshot, sent on a timer, never queued and never
--              retried -- re-sending a stale player list AHEAD of a fresh one
--              is worse than the gap it fills.
--   events     EVIDENCE. Every one matters. BR.Outbox: ordered, batched,
--              retried with backoff, bounded, drop counters visible in brring.
--
-- This is the first PerformHttpRequest in the codebase. Its constraints:
-- a HARDCODED 5s no-response timeout (the endpoint acknowledges before it
-- processes, so a healthy round trip is milliseconds), and failure here is
-- never fatal and never blocks a tick -- the console being down is not an
-- outage of the game.

BR = BR or {}
BR.Ring = BR.Ring or {}

local cfg = BR.Ring.Config

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

local latest = nil          -- the one snapshot slot; nil until br_core speaks
local latestAt = 0          -- GetGameTimer() when it arrived, for the re-hello
local outbox = BR.Outbox.new({
    capacity = cfg.outboxCapacity,
    batchMax = cfg.outboxBatchMax,
    enabled  = cfg.configured(),
})

local stat = {
    snapshotsSent = 0, snapshotsFailed = 0,
    lastStatus = nil, lastSentAt = 0,
}

BR.Ring.outbox = outbox     -- brring reads these
function BR.Ring.pushStats()
    return {
        summary = ('sent %d, failed %d, last status %s')
            :format(stat.snapshotsSent, stat.snapshotsFailed, tostring(stat.lastStatus)),
    }
end

-- ---------------------------------------------------------------------------
-- Envelope
-- ---------------------------------------------------------------------------

local function serverBlock()
    local wallMs, gameMs = BR.Ring.clockPair()
    return {
        bootEpoch = BR.Ring.bootEpoch,
        resource  = GetCurrentResourceName(),
        wallMs    = wallMs,
        gameMs    = gameMs,
    }
end

local function post(body, cb)
    PerformHttpRequest(cfg.ingestUrl, function(status)
        cb(status and status >= 200 and status < 300, status)
    end, 'POST', json.encode(body), {
        ['Content-Type']        = 'application/json',
        ['X-Ringmaster-Secret'] = cfg.ingestSecret,
    })
end

-- ---------------------------------------------------------------------------
-- Inbound from br_core
-- ---------------------------------------------------------------------------

AddEventHandler('br:ringmaster:snapshot', function(snap)
    latest   = snap
    latestAt = GetGameTimer()
end)

AddEventHandler('br:ringmaster:refusal', function(data)
    -- Evidence, not state: an anticheat firing dropped because a queue filled
    -- would be the one record that mattered, which is why this goes through
    -- the outbox and snapshots do not.
    outbox:emit('refusal', data, GetGameTimer())
end)

-- Identity capture -> player_seen. main.lua calls this hook for every NEW
-- license record (reconnects update the record without re-announcing).
function BR.Ring.emitSeen(license, rec)
    local ids = {}
    for k, v in pairs(rec.byKind) do
        if k ~= 'license' then ids[k] = v end
    end
    outbox:emit('player_seen', {
        license     = license,
        name        = rec.name,
        identifiers = ids,
    }, GetGameTimer())
end

-- ---------------------------------------------------------------------------
-- Outbound jobs
-- ---------------------------------------------------------------------------

if cfg.configured() then
    -- Tell br_core we are listening, and how fast. Repeated whenever the feed
    -- has been quiet for several intervals, which self-heals the one seam in
    -- the event design: a br_core restart forgets its subscriber flag, and
    -- without this the board would silently freeze until somebody restarted
    -- the right resource in the right order.
    local function hello()
        TriggerEvent('br:ringmaster:hello', { intervalMs = cfg.pushMs })
    end
    hello()

    BR.Sched.every(cfg.pushMs, 'ring.snapshot', function()
        local now = GetGameTimer()

        if now - latestAt > cfg.pushMs * 3 then
            hello()
        end
        if not latest then return end

        local body = {
            v        = 1,
            kind     = 'snapshot',
            server   = serverBlock(),
            snapshot = latest,
        }
        latest = nil   -- consumed; a stale slot must not be re-sent

        post(body, function(okay, status)
            stat.lastStatus = status
            if okay then
                stat.snapshotsSent = stat.snapshotsSent + 1
                stat.lastSentAt = GetGameTimer()
            else
                -- Dropped, deliberately. The next snapshot is seconds away and
                -- strictly better than this one.
                stat.snapshotsFailed = stat.snapshotsFailed + 1
            end
        end)
    end)

    BR.Sched.every(1000, 'ring.events', function()
        local now = GetGameTimer()
        local batch = outbox:take(now)
        if not batch then return end

        post({
            v      = 1,
            kind   = 'events',
            server = serverBlock(),
            events = batch,
        }, function(okay)
            -- ack/nack per the driver contract in outbox.lua: exactly one
            -- batch in flight, ordered delivery, bounded retries.
            if okay then outbox:ack(GetGameTimer()) else outbox:nack(GetGameTimer()) end
        end)
    end)
end
