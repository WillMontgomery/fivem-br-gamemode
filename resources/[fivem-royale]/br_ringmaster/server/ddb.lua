--[[
    The DynamoDB reachability reading, cached here and resent on the snapshot.

    ONE OF THE TWO br_ddb FACTS, AND THE ONE THAT CANNOT BE READ OFF THE BOX.
    `br:ddb:selftest` is a real GetItem issued by the running br_ddb with its
    own region, prefix and credentials -- the same probe `brddb` prints -- and
    only something inside FXServer can ask it. A shell probe from the dispatcher
    would answer whether the machine has a route, which is one of the three ways
    this breaks and reports healthy for the other two (no IAM, wrong region).

    So the transport is the one this resource already owns: the last verdict is
    cached here and rides the snapshot push that goes out anyway. Nothing new is
    opened, and the console's SSH verb set is untouched.

    ═══ THIS PUBLISHES AND GATES NOTHING ═══

    No connect is refused on it, no boot depends on it, nothing here changes if
    the console never reads it -- and if br_ddb is missing entirely this file
    simply never has anything to say. The game must not become reliant on
    Ringmaster; this is a fact leaving the box, in one direction.

    ═══ WHY A CACHE RATHER THAN A PROBE PER PUSH ═══

    Snapshots go out every 2s (br_ringmaster_push_ms). A GetItem per push would
    be a network round trip every two seconds, forever, to answer a question
    whose answer changes on the timescale of an IAM edit. So the probe runs on
    its own slow cadence and the verdict is resent with its own timestamp, which
    is what makes `at` load-bearing rather than decorative: the console dates the
    PROBE, not the push, and expires it on its own ceiling.

    ═══ ABSENT IS A REAL ANSWER, AND IT IS THE DEFAULT ═══

    A selftest that has never run, a br_ddb that is not started, an answer that
    never came -- all of them leave the block off the snapshot entirely. The
    console reads absence as "not told" and renders nothing. Nothing in this file
    ever invents a verdict, in either direction: a fabricated green would hide a
    ban gate that is failing open, and a fabricated red is an alarm on every
    routine `restart br_ddb`, which is what tools/deploy.sh tells you to run
    after every single deploy. An alarm that cries wolf on deploys is how the
    real one gets ignored.
]]

BR = BR or {}
BR.Ring = BR.Ring or {}

local cfg = BR.Ring.Config

--- How old a reading may get before we ask again.
---
--- CHOSEN AGAINST THE CONSOLE'S CEILING, which expires a probe at five minutes
--- and reads anything older as "not told". A minute is four beats inside that,
--- so a single skipped probe -- a restart, a tick lost to a stall -- never
--- flaps the console to unknown, and a verdict from a previous era of this
--- box's life can never be reported as the current one.
local PROBE_MS = 60000

--- How often the job wakes up, which is deliberately FASTER than the cadence.
---
--- Two cases need it. At boot the scheduler may tick before br_ddb has reached
--- `started`, and a 60s job would leave the console blank for a minute after
--- every deploy for no reason. And a probe that is never answered at all -- the
--- JS half wedged or absent -- leaves no reading to age, so there is nothing to
--- back off from. `due()` below turns one tick rate into both behaviours: retry
--- promptly while there is no reading, settle to PROBE_MS once there is one.
local TICK_MS = 15000

--- `0` IS TRUTHY IN LUA AND THE BOOL MAY ARRIVE AS `1`. This repo has shipped
--- that bug six times. The console's schema requires a real boolean for `ok`,
--- so this is also what keeps a `1` from failing validation on the far end and
--- taking the whole snapshot -- the player list included -- down with it.
local function yes(v) return v == true or v == 1 end

--- Bound a string the console has declared a length for, or drop it.
---
--- THE LENGTHS ARE THE CONSOLE'S, NOT OURS. Its ingest schema caps `error` at
--- 512, `region` at 64 and `prefix` at 128, and a field over the cap fails the
--- WHOLE envelope -- which the outbox reads as a nack. An AWS SDK error message
--- is not a bounded string; one long enough would turn "the database is
--- unreachable" into "the player list stopped arriving", which is the exact
--- inversion this feature must not cause. Bounded here, at the edge that knows
--- the number.
local function bounded(v, max)
    if type(v) ~= 'string' or v == '' then return nil end
    if #v > max then return v:sub(1, max) end
    return v
end

--- Milliseconds, or nothing. Never a negative -- the console's schema refuses
--- one and a clock that went backwards is not a measurement.
local function millis(v)
    local n = tonumber(v)
    if not n or n < 0 then return nil end
    return math.floor(n)
end

--- The last verdict, or nil. Replaced wholesale, never edited in place.
local last = nil

--- When we last ASKED, on the game clock. Separate from `last.at`, which is
--- when we were last ANSWERED: without both, an unanswered probe would either
--- re-ask every tick forever or never re-ask at all.
local lastAskAt = nil

--- Is br_ddb even there?
---
--- gate.lua's precedent, for gate.lua's reason: asking a resource that is not
--- running produces no answer and no error, only a silence indistinguishable
--- from a broken one. Checking the state is instant and turns that into a no-op.
local function ddbRunning()
    return GetResourceState('br_ddb') == 'started'
end

--- EVERY selftest result is adopted, whoever asked for it -- ours on the timer,
--- and an operator's `brddb` on the FXServer console.
---
--- THAT SECOND CASE IS A FEATURE THE CONSOLE ALREADY PROMISES. Its fix popup
--- for an unreachable database ends with "Run brddb on the FXServer console to
--- re-probe once a cause is ruled out", and someone who fixes an IAM policy and
--- runs it should see the card go green then, not up to a minute later. There is
--- nothing to correlate: any result is a real probe of the same thing by the
--- same resource, and the newest one is the truth.
---
--- WHICH IS WHY `req` IS IGNORED HERE AND NAMESPACED WHERE WE MINT IT. br_ddb's
--- own debug.lua keys its pending table by the integer it minted; ours are
--- strings, so `brddb` can never mistake our answer for the one it is waiting
--- on and print it twice.
AddEventHandler('br:ddb:selftestResult', function(_req, ok, info)
    info = type(info) == 'table' and info or {}

    last = {
        ok     = yes(ok),
        at     = math.floor(GetGameTimer()),
        error  = bounded(info.error, 512),
        region = bounded(info.region, 64),
        prefix = bounded(info.prefix, 128),
        ms     = millis(info.ms),
    }
end)

--- br_ddb going away takes its verdict with it.
---
--- WITHOUT THIS A RESTART RESURRECTS THE OLD READING: br_ddb stops, starts
--- again with a different region convar or a bundle that cannot reach anything,
--- and the pre-restart verdict would keep being resent until the next probe.
--- The reading describes a process; when the process ends, so does it.
AddEventHandler('onResourceStop', function(name)
    if name == 'br_ddb' then
        last, lastAskAt = nil, nil
    end
end)

--- The reading, or nil for "this box cannot say".
---
--- PURE, AND THE RESOURCE CHECK IS PART OF THE ANSWER RATHER THAN A GUARD ON
--- IT. A stopped br_ddb is not an unreachable database -- it is a box that is
--- not asking -- and reporting the last verdict from before it stopped would be
--- the one fabrication this whole file is written against.
--- @return table|nil
function BR.Ring.ddbProbe()
    if not ddbRunning() then return nil end
    return last
end

--- Read by brring, so "no reading" and "a reading that says no" are separable
--- from the FXServer console without waiting for the web page.
--- @return table
function BR.Ring.ddbStats()
    return {
        running = ddbRunning(),
        probe   = BR.Ring.ddbProbe(),
        askedAt = lastAskAt,
    }
end

--- Is it time to ask?
--- @param now integer
local function due(now)
    if lastAskAt == nil then return true end
    if last == nil then return (now - lastAskAt) >= TICK_MS end
    return (now - lastAskAt) >= PROBE_MS
end

-- ONLY WHEN THERE IS SOMEWHERE TO SEND IT. A server with no Ringmaster
-- configured pushes nothing, so a GetItem a minute would be a network call an
-- hour to answer a question nobody asked. Same gate push.lua puts on its own
-- jobs, for the same reason.
if cfg.configured() then
    --- Correlates nothing. It exists so br_ddb's `brddb` command, which keys its
    --- own pending table by the integer IT minted, cannot collide with ours --
    --- a string key is simply absent from that table and is ignored there.
    local nextReq = 0

    BR.Sched.every(TICK_MS, 'ring.ddb', function()
        if not ddbRunning() then return end

        local now = GetGameTimer()
        if not due(now) then return end

        lastAskAt = now
        nextReq = nextReq + 1

        -- No timeout, and no answer is recorded if none comes. br_ddb's JS half
        -- carries its own deadline and answers `ok=false` when AWS does not, so
        -- a silence here means the resource itself is not answering -- which is
        -- also what a `restart br_ddb` looks like for a second. Writing a
        -- failure for it would fire a critical alert on every deploy; leaving
        -- the reading to age out says "we are not being told", which is true.
        TriggerEvent('br:ddb:selftest', ('ringmaster:%d'):format(nextReq))
    end)
end
