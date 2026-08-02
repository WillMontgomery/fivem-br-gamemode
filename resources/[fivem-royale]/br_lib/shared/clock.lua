-- Shared match clock.
--
-- The storm and the battle bus are both interpolated locally on every client from
-- a record the server published once. That only works if every client agrees on
-- what time it is. Streaming positions instead would cost bandwidth every frame
-- for something we can derive; a ~100 ms clock error is invisible across a 90
-- second shrink, so this is the right trade.
--
-- br_lib supplies the estimator only. br_core owns the net events that feed it --
-- shared files must never register handlers, or every consuming resource would
-- register its own copy.

BR = BR or {}

BR.Clock = {
    offset      = 0.0,  -- ms to add to the local timer to reach server time
    samples     = {},
    maxSamples  = 8,
    synced      = false,
}

--- Server time, in milliseconds.
---
--- On the server this is simply the game timer. On the client it is the local
--- timer plus the estimated offset. Every consumer of match timing should call
--- this rather than GetGameTimer() directly.
--- @return number
function BR.Clock.now()
    return GetGameTimer() + BR.Clock.offset
end

--- Feed one round-trip sample into the estimator.
---
--- Called by br_core when a clock pong returns. `sentAt` and `recvAt` are local
--- timer readings; `serverAt` is the server's timer at the moment it replied.
---
--- @param sentAt number    local time the ping was sent
--- @param recvAt number    local time the pong arrived
--- @param serverAt number  server time carried in the pong
function BR.Clock.sample(sentAt, recvAt, serverAt)
    local rtt = recvAt - sentAt
    if rtt < 0 or rtt > 2000 then
        -- A wildly long round trip means the reply sat behind a stall; the
        -- midpoint assumption no longer holds, so the sample is worthless.
        return
    end

    -- Assume the reply took half the round trip to come back.
    local estimated = serverAt + (rtt * 0.5)
    local offset    = estimated - recvAt

    local s = BR.Clock.samples
    s[#s + 1] = offset
    if #s > BR.Clock.maxSamples then
        table.remove(s, 1)
    end

    -- Median rather than mean: one stalled frame should not drag the estimate.
    local sorted = {}
    for i = 1, #s do sorted[i] = s[i] end
    table.sort(sorted)

    local n = #sorted
    if n % 2 == 1 then
        BR.Clock.offset = sorted[(n + 1) // 2]
    else
        BR.Clock.offset = (sorted[n // 2] + sorted[n // 2 + 1]) * 0.5
    end

    BR.Clock.synced = n >= 3
end

--- Drop all samples. Call on match reset or reconnect.
function BR.Clock.reset()
    BR.Clock.offset  = 0.0
    BR.Clock.samples = {}
    BR.Clock.synced  = false
end

--- Milliseconds remaining until `endsAt`, never negative.
--- @param endsAt number  a server timestamp
--- @return number
function BR.Clock.remaining(endsAt)
    if not endsAt then return 0.0 end
    local left = endsAt - BR.Clock.now()
    return left > 0 and left or 0.0
end
