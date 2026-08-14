-- Writing an incident to DynamoDB, and then ringing the doorbell.
--
-- THE WRITE IS THE SOURCE OF TRUTH. THE EVENT IS A DOORBELL. This is the single
-- most important property in the pipeline and it is worth stating plainly,
-- because the tidier-looking design is wrong.
--
-- The obvious version sends the incident to Ringmaster over the event channel
-- and lets the console write it. But that channel drops silently: outbox.lua
-- gives a batch four attempts and then discards it, the drop counters reach only
-- the local `brring` command, and nothing on either envelope says a thing was
-- lost. So the console genuinely cannot tell "thirty-two refusals were dropped
-- because the link was down" from "no refusals happened" -- and an incident that
-- vanished that way is unrecoverable, because the evidence buffer it was built
-- from is discarded at match end.
--
-- So the GAME writes the row, directly, and the event carries only an id. A lost
-- doorbell then costs a delay -- the console's reconciliation sweep finds an
-- untriaged incident next time it looks -- rather than costing the case.
--
-- WHICH IS WHY THIS FILE RETRIES AND THE OUTBOX DOES NOT DO IT FOR US. A failed
-- DynamoDB write has no queue behind it: br_ddb answers with an error and the
-- payload is gone. That posture is right for a stats write (costs XP) and wrong
-- for an incident (costs the whole record), so this retries a bounded number of
-- times with backoff and then gives up LOUDLY.
--
-- NOTHING HERE EVER TOUCHES A PLAYER. br_ringmaster owns the project's only
-- DropPlayer (kick.lua) and it is not called from here. Filing a case and
-- acting on one are separate events, arriving from opposite directions.

BR = BR or {}
BR.Ring = BR.Ring or {}

--- How hard to try before giving up on a write.
---
--- FIVE ATTEMPTS OVER ROUGHLY THIRTY SECONDS. br_ddb's own client is configured
--- `maxAttempts: 2` inside a 3-second Promise.race, so an SDK-level retry often
--- cannot even finish -- which means the retry that matters has to live out here
--- where the timeout is ours. Thirty seconds is chosen against the thing it
--- competes with: the evidence is already in the payload, so nothing decays while
--- we wait, and a DynamoDB blip measured in seconds should not cost a case.
local RETRY_MAX = 5
local RETRY_BASE_MS = 1000
local RETRY_CAP_MS = 12000

--- br_ddb's answer deadline. Longer than its internal 3s TIMEOUT_MS so a
--- br_ddb that answers slowly is not counted as a br_ddb that never answered --
--- the difference matters, because the first is worth retrying and the second
--- means the bundle is stale and no amount of retrying will help.
local ASK_TIMEOUT_MS = 8000

local nextReq = 0
local pending = {}

--- Outstanding writes, for the health dump. A number rather than a list: the
--- payloads are already accounted for by the closures holding them.
local stat = { filed = 0, failed = 0, duplicate = 0, inflight = 0 }

function BR.Ring.incidentStats()
    return {
        filed = stat.filed, failed = stat.failed,
        duplicate = stat.duplicate, inflight = stat.inflight,
    }
end

local function reply(req, ...)
    local cb = pending[req]
    if not cb then return end
    pending[req] = nil
    cb(...)
end

AddEventHandler('br:ddb:incidentResult', function(req, ok, extra)
    reply(req, ok, extra or {})
end)

--- Issue one br_ddb request with a timeout of our own.
---
--- The `ask` convention from br_core/server/market.lua, copied rather than
--- shared because the two resources cannot see each other's Lua. The timeout is
--- the load-bearing part: without it a bridge that never answers leaks one
--- pending closure -- holding a whole incident payload -- per attempt, for the
--- life of the server.
local function ask(event, cb, ...)
    if GetResourceState('br_ddb') ~= 'started' then
        cb(false, { error = 'br_ddb not started' })
        return
    end

    local req = nextReq + 1
    nextReq = req
    pending[req] = cb

    SetTimeout(ASK_TIMEOUT_MS, function()
        if pending[req] then
            pending[req] = nil
            cb(false, { error = 'timed out' })
        end
    end)

    TriggerEvent(event, req, ...)
end

--- Wall-clock milliseconds for a game-clock reading.
---
--- THE CLOCK PAIR IS SAMPLED ONCE PER PAYLOAD, not once per row. Two calls drift,
--- and a case whose chat lines are timestamped from a different sample than its
--- kills is a timeline nobody can trust. Same arithmetic as the console's
--- `realTime()`; the conversion happens here because this is the resource that
--- owns the pair.
local function realiser()
    local wallMs, gameMs = BR.Ring.clockPair()
    return function(at)
        local n = tonumber(at)
        if not n then return nil end
        return wallMs + (n - gameMs)
    end
end

--- Rewrite every game-clock reading in a payload to real time, in place.
---
--- IN PLACE AND EXHAUSTIVE, because a single missed field is a row that renders
--- as 1970 next to rows that render correctly -- which reads as corrupt data
--- rather than as a bug in one line of Lua.
local function realise(payload)
    local real = realiser()

    payload.openedAt = real(payload.atGameMs)
    payload.atGameMs = nil

    for _, r in ipairs(payload.evidence or {}) do
        r.openedAt = real(r.openedAt)
        if r.leftAt ~= nil then r.leftAt = real(r.leftAt) end
        for _, c in ipairs(r.chat or {}) do c.at = real(c.at) end
        for _, k in ipairs(r.kills or {}) do k.at = real(k.at) end
    end

    return payload
end

--- Try the write, and keep trying for a while if the database is unhappy.
---
--- @param payload table   the realised incident payload
--- @param token string    stable across retries, so a lost ANSWER cannot double-file
--- @param attempt integer  1-based
local function attemptWrite(payload, token, attempt)
    stat.inflight = stat.inflight + 1

    ask('br:ddb:putIncident', function(ok, extra)
        stat.inflight = stat.inflight - 1
        extra = extra or {}

        if ok then
            if extra.duplicate then stat.duplicate = stat.duplicate + 1 end
            stat.filed = stat.filed + 1

            local id = extra.incidentId

            -- THE DOORBELL. Carries an id and nothing else -- the row is already
            -- durable, and re-sending the payload over a channel that drops
            -- silently would only invite somebody to depend on it.
            if BR.Ring.outbox then
                BR.Ring.outbox:emit('incident_filed', {
                    incidentId     = id,
                    kind           = payload.kind,
                    severity       = payload.severity,
                    subjectLicense = payload.subjectLicense,
                    state          = payload.state,
                }, GetGameTimer())
            end

            -- Back to br_core, so the next incident this match can point at this
            -- one. Its handler is guarded; br_core being absent is fine.
            TriggerEvent('br:incident:filed', {
                incidentId     = id,
                matchId        = payload.matchId,
                subjectLicense = payload.subjectLicense,
            })

            print(('[br_ringmaster] incident %s filed (%s, %s)%s')
                :format(tostring(id), tostring(payload.kind),
                        tostring(payload.severity),
                        extra.duplicate and ' -- already present' or ''))
            return
        end

        if attempt >= RETRY_MAX then
            stat.failed = stat.failed + 1
            -- LOUD, AND THE LOUDEST LINE IN THIS RESOURCE. There is no queue
            -- behind this and no second chance: the case is lost, and the only
            -- record that it ever existed is this line plus the counter that
            -- rides the health dump. Deliberately not falling back to sending
            -- the whole payload over the event channel -- that channel drops
            -- silently, so the fallback would convert a visible failure into an
            -- invisible one.
            print(('^1[br_ringmaster] INCIDENT LOST after %d attempts -- %s (%s about %s)^7')
                :format(attempt, tostring(extra.error),
                        tostring(payload.kind), tostring(payload.subjectLicense)))
            return
        end

        -- Exponential, capped. The failure this is riding out is a throttle or a
        -- brief unreachability, and hammering a throttled table is how a brief
        -- one becomes a long one.
        local waitMs = math.min(RETRY_BASE_MS * (2 ^ (attempt - 1)), RETRY_CAP_MS)
        print(('^3[br_ringmaster] incident write failed (%s), retry %d/%d in %dms^7')
            :format(tostring(extra.error), attempt + 1, RETRY_MAX, waitMs))

        SetTimeout(waitMs, function()
            attemptWrite(payload, token, attempt + 1)
        end)
    end, token, payload)
end

-- ---------------------------------------------------------------------------
-- Inbound from br_core
-- ---------------------------------------------------------------------------

local nextToken = 0

AddEventHandler('br:ringmaster:incident', function(payload)
    if type(payload) ~= 'table' then return end

    -- THE TOKEN IS WHAT MAKES A RETRY SAFE. br_ddb mints the incident's UUID, so
    -- a naive retry after a lost ANSWER (the write landed, the reply did not)
    -- would file the same case twice under two ids -- and a reviewer would have
    -- no way to tell that from the same player doing it twice. Keyed on the boot
    -- epoch so it stays unique across a restart, exactly as `seq` is.
    nextToken = nextToken + 1
    local token = ('%s:%d'):format(tostring(BR.Ring.bootEpoch), nextToken)

    attemptWrite(realise(payload), token, 1)
end)
