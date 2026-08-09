-- Outbound event queue for anything that leaves the match loop.
--
-- Stats writes, moderation events, telemetry -- everything this project sends to
-- a system outside the game server shares one hard rule, stated in three
-- different places in the plan and worth stating once in code: **a match tick
-- never blocks on a network round trip, and a dead endpoint is not an outage of
-- the game.** br_stats already degrades to "no stats" rather than taking a match
-- down; this generalises that property so the next consumer inherits it instead
-- of reimplementing it.
--
-- WHY THIS IS PURE. There is no PerformHttpRequest here, and no GetGameTimer:
-- `now` is always a parameter. That keeps the interesting behaviour -- ordering,
-- overflow, backoff, when to give up -- testable outside the game, which is the
-- same reason storm_solve and loot_gen are pure. The transport is a dozen lines
-- of driver in the consuming resource; the decisions are all here.
--
-- THE DRIVER CONTRACT, for whoever writes one:
--
--     local batch = ob:take(now)
--     if batch then
--         send(batch, function(okay)
--             if okay then ob:ack(now) else ob:nack(now) end
--         end)
--     end
--
-- Exactly one batch is in flight at a time. That is deliberate: an endpoint
-- that is struggling should not receive an accelerating pile of concurrent
-- requests, and ordered delivery makes a moderation audit log readable.
--
-- br_lib supplies the queue only. It registers nothing and schedules nothing --
-- shared files must never do either, or every consuming resource gets its own
-- copy.

BR = BR or {}

BR.Outbox = {}
BR.Outbox.__index = BR.Outbox

local DEFAULTS = {
    -- Bounded on purpose. An unbounded queue behind a dead endpoint is a memory
    -- leak that presents as "the server got slow overnight".
    capacity     = 512,
    batchMax     = 32,
    retryMax     = 3,
    backoffMs    = 1000,
    backoffMaxMs = 30000,
}

--- Create an outbox.
---
--- `enabled = false` makes emit() a no-op that still counts, which is how a
--- server with no endpoint configured behaves: the code that emits does not
--- have to know, and the drop counter still shows what would have been sent.
---
--- @param opts table|nil  capacity, batchMax, retryMax, backoffMs, backoffMaxMs, enabled
--- @return table
function BR.Outbox.new(opts)
    opts = opts or {}

    local o = setmetatable({}, BR.Outbox)

    o.capacity     = opts.capacity     or DEFAULTS.capacity
    o.batchMax     = opts.batchMax     or DEFAULTS.batchMax
    o.retryMax     = opts.retryMax     or DEFAULTS.retryMax
    o.backoffMs    = opts.backoffMs    or DEFAULTS.backoffMs
    o.backoffMaxMs = opts.backoffMaxMs or DEFAULTS.backoffMaxMs
    o.enabled      = opts.enabled ~= false

    o.q            = {}     -- pending events, oldest first
    o.inflight     = nil    -- the batch handed to the driver, awaiting ack/nack
    o.attempts     = 0      -- failures against the CURRENT inflight batch
    o.nextAttempt  = 0      -- take() returns nothing before this timestamp
    o.seq          = 0      -- monotonic id, so a receiver can dedupe a retry

    o.stat = {
        emitted   = 0,
        sent      = 0,
        droppedFull   = 0,  -- queue was full
        droppedRetry  = 0,  -- gave up after retryMax
        droppedOff    = 0,  -- no endpoint configured
    }

    return o
end

--- Queue one event.
---
--- Never blocks, never allocates a request, never fails in a way the caller has
--- to handle -- the return value is for tests and debug commands, not for
--- control flow at the call site.
---
--- @param kind string     event type, e.g. 'match_end', 'refusal', 'ban'
--- @param payload table   arbitrary, must be serialisable
--- @param now number      caller's clock, ms
--- @return boolean queued
function BR.Outbox:emit(kind, payload, now)
    self.stat.emitted = self.stat.emitted + 1

    if not self.enabled then
        self.stat.droppedOff = self.stat.droppedOff + 1
        return false
    end

    -- Drop the OLDEST, not the newest. A full queue means the endpoint is
    -- already behind, and in that state the freshest events are the ones worth
    -- keeping -- a moderation panel showing the last minute is useful, one
    -- showing the minute before the outage is not. The counter exists so this
    -- is visible rather than silent, which is the part that actually matters.
    if #self.q >= self.capacity then
        table.remove(self.q, 1)
        self.stat.droppedFull = self.stat.droppedFull + 1
    end

    self.seq = self.seq + 1
    self.q[#self.q + 1] = {
        seq  = self.seq,
        kind = kind,
        at   = now,
        data = payload,
    }

    return true
end

--- Pull the next batch to send, or nil if there is nothing to do yet.
---
--- Returns nil while a batch is already in flight, while backing off, and when
--- the queue is empty -- so a driver can call this on a plain timer without
--- guarding any of those cases itself.
---
--- @param now number
--- @return table|nil  array of events
function BR.Outbox:take(now)
    if self.inflight then return nil end
    if now < self.nextAttempt then return nil end
    if #self.q == 0 then return nil end

    local n = #self.q
    if n > self.batchMax then n = self.batchMax end

    local batch = {}
    for i = 1, n do
        batch[i] = self.q[i]
    end
    for _ = 1, n do
        table.remove(self.q, 1)
    end

    self.inflight = batch

    -- NOT resetting `attempts` here is the whole point of it. A retried batch is
    -- re-taken through this same path, merged with anything queued behind it, so
    -- resetting on take would hand out a fresh set of retries every round and the
    -- give-up below could never fire. `attempts` counts CONSECUTIVE failures
    -- against the endpoint, and only an ack (or a give-up) clears it.
    return batch
end

--- The in-flight batch was delivered.
--- @param now number
function BR.Outbox:ack(now)
    if not self.inflight then return end

    self.stat.sent = self.stat.sent + #self.inflight
    self.inflight  = nil
    self.attempts  = 0
    self.nextAttempt = now

    return true
end

--- The in-flight batch failed.
---
--- Retries with exponential backoff up to `retryMax`, then **drops the batch and
--- moves on**. That last part is the project's "queue and drop, do not retry
--- into a stall" rule made concrete: a permanently broken endpoint must not wedge
--- delivery of everything behind it, and it must not grow without bound.
---
--- @param now number
--- @return boolean willRetry
function BR.Outbox:nack(now)
    if not self.inflight then return false end

    self.attempts = self.attempts + 1

    if self.attempts > self.retryMax then
        self.stat.droppedRetry = self.stat.droppedRetry + #self.inflight
        self.inflight = nil
        self.attempts = 0
        -- Still back off. The endpoint just failed retryMax times in a row;
        -- sending the NEXT batch immediately would be the same mistake with
        -- different data.
        self.nextAttempt = now + self.backoffMs
        return false
    end

    -- Put it back at the front, oldest-first order preserved, so a retry does
    -- not reorder events relative to anything queued while it was in flight.
    local batch = self.inflight
    for i = #batch, 1, -1 do
        table.insert(self.q, 1, batch[i])
    end
    self.inflight = nil

    local wait = self.backoffMs * (2 ^ (self.attempts - 1))
    if wait > self.backoffMaxMs then wait = self.backoffMaxMs end
    self.nextAttempt = now + wait

    return true
end

--- Queue depth, including anything currently in flight.
--- @return number
function BR.Outbox:depth()
    return #self.q + (self.inflight and #self.inflight or 0)
end

--- Counters, for a debug command or a health push. Returns a copy.
--- @return table
function BR.Outbox:stats()
    local s = {}
    for k, v in pairs(self.stat) do s[k] = v end
    s.depth    = self:depth()
    s.inflight = self.inflight and #self.inflight or 0
    return s
end
