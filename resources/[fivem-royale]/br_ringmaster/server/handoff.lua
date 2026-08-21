-- The pause-menu handoff: ask Ringmaster for a signed-in URL (#23).
--
-- WHAT THIS FILE IS ALLOWED TO KNOW. It takes a Discord id and gives back a URL
-- or a reason. It does not know what a grant is, does not know which player
-- asked, and never speaks to a client -- br_ringmaster has no client half and
-- must not grow one. br_core/server/admin.lua decides WHO may ask; this decides
-- nothing and only carries the question across the wire.
--
-- WHY THE SPLIT IS THIS WAY ROUND. The secret and the endpoint live here, in
-- the resource that already holds them, read once by server/config.lua. Putting
-- the HTTP call in br_core would mean a second reader of
-- br_ringmaster_ingest_secret, which is the "one source of truth or none" rule
-- server/maintenance.lua already argues for. Putting the GRANT check here would
-- mean br_ringmaster reading DynamoDB, which is br_ddb's job and br_core's
-- question. So the seam is a request/response event pair, which is exactly the
-- idiom br_ddb's `br:ddb:grantsFetch` / `br:ddb:grantsResult` already
-- establishes for a cross-resource question with an answer that takes time.
--
-- ═══ THE GAME MUST NOT DEPEND ON RINGMASTER, AND HERE IT DOES ═══
--
-- This is the one place in the project where the game asks the console for
-- something and waits. It is allowed for exactly one reason, and the reason is
-- the boundary of the licence: the ask only ever happens because an admin
-- clicked a button, and if the console does not answer, the iframe does not open
-- and NOTHING ELSE CHANGES. No connect gate, no match, no player, no tick. Every
-- failure path below ends in an answer being sent -- never in a caller left
-- waiting -- because a caller left waiting is how "the console is slow" becomes
-- "the game is broken".

BR = BR or {}
BR.Ring = BR.Ring or {}

local cfg = BR.Ring.Config

--- How long to wait for the mint before giving up, in milliseconds.
---
--- THREE SECONDS, AGAINST A BUDGET OF 2.5 AND A CEILING OF 5, and all three of
--- those numbers are somebody else's.
---
---   2.5s  is what the endpoint says it costs: one Auth.js account lookup
---         (us-west-2 -> us-east-2), one Discord member fetch capped at 2s, and
---         one put. fivem-ringmaster's `MINT_BUDGET_MS`, asserted by its own
---         `npm run verify`.
---   5s    is PerformHttpRequest's own no-response timeout. It is HARDCODED and
---         not ours to move -- server/push.lua's header records the same fact --
---         so anything at or near five is a mint we could never observe
---         succeeding.
---
--- Three sits above the budget and below the ceiling, which is the only window
--- there is.
---
--- WHAT A TIMEOUT COSTS IS ALMOST NOTHING, and that is a property of the
--- console's table rather than of this timer. The handoff record is keyed on the
--- ADMIN, so a retry's put overwrites its predecessor: at most one live token
--- exists per admin at any instant and it is always the newest. A mint that
--- lands at 3.1s after we gave up is not a credential loose in the world; it is
--- a row the next mint replaces.
local TIMEOUT_MS = 3000

--- The path the console serves the mint on. Written down once, here, because
--- the console's own reply carries the redeem URL whole -- this is the only
--- Ringmaster path the game ever constructs.
local MINT_PATH = '/api/handoff/mint'

--- Requests waiting on an answer. req -> true, cleared by whichever of the
--- response or the timeout gets there first.
local pending = {}

local stat = { asked = 0, ok = 0, failed = 0, timedOut = 0 }

--- Counters for `brring`.
--- @return table
function BR.Ring.handoffStats()
    return {
        asked = stat.asked, ok = stat.ok,
        failed = stat.failed, timedOut = stat.timedOut,
    }
end

--- The scheme-and-authority of a URL, with the path thrown away.
---
--- WHY THE MINT GOES TO THE INGEST HOST AND NOT TO THE CONSOLE'S PUBLIC ADDRESS.
--- They are the same Next application and different addresses: the public origin
--- is what a BROWSER uses, over Cloudflare; `ingestUrl` is a private address on
--- the VPC peering link, which server/config.lua says in as many words is
--- "never a public one, and never through Cloudflare". This call is
--- server-to-server with the ingest secret on it, so it belongs on the path that
--- is already proven to work from this box and already restricted to it.
---
--- DERIVED RATHER THAN CONFIGURED, so there is no third convar for an operator
--- to get subtly out of step with the first two. It takes everything up to the
--- third slash, which is a pure string operation with no assumption about what
--- the ingest PATH is -- `/api/ingest` today, anything tomorrow.
---
--- @param url string|nil
--- @return string|nil
function BR.Ring.originOf(url)
    if type(url) ~= 'string' then return nil end

    local scheme, authority = url:match('^(%a[%w+.-]*)://([^/?#]+)')
    if scheme == nil or authority == nil or authority == '' then return nil end

    return ('%s://%s'):format(scheme, authority)
end

--- Turn one HTTP outcome into a code the game can act on.
---
--- MACHINE CODES, NEVER SENTENCES, and the console deliberately answers the same
--- way: "what the admin is shown in-game is the game side's to decide and is not
--- written here" (its mint route). What comes out of this function reaches a
--- log, a `bradmin` line and -- until somebody writes the words -- the screen.
---
--- THE BODY IS TRUSTED FOR THE REASON AND THE STATUS FOR THE CATEGORY. 403 and
--- 503 each cover two genuinely different situations that an admin would act on
--- differently -- a revoked role versus an account that never existed, Discord
--- being unreachable versus DynamoDB being unreachable -- and only the body
--- separates them. A status with no body we understand falls back to naming the
--- status, which is strictly better than inventing a cause.
---
--- @param status number|nil
--- @param body string|nil
--- @return string code
local function codeFor(status, body)
    local reason = nil
    if type(body) == 'string' and body ~= '' then
        -- pcall, because a proxy or a load balancer between here and the
        -- console can answer with HTML, and json.decode raises on it.
        local decoded, parsed = pcall(json.decode, body)
        if decoded and type(parsed) == 'table' and type(parsed.error) == 'string' then
            reason = parsed.error
        end
    end

    -- A CONNECTION THAT NEVER HAPPENED. FiveM reports 0 (and some builds a
    -- negative) when there was no HTTP response at all -- DNS, refused, or the
    -- engine's own 5s ceiling firing under ours. It is not a 500.
    if type(status) ~= 'number' or status <= 0 then return 'unreachable' end

    if status >= 200 and status < 300 then return 'ok' end
    if reason ~= nil then return reason end

    if status == 401 then return 'auth' end
    if status == 429 then return 'rate-limited' end
    return ('http-%d'):format(status)
end

--- Answer exactly one request, exactly once.
--- @param req string
--- @param ok boolean
--- @param url string|nil
--- @param err string|nil
local function answer(req, ok, url, err)
    -- The timeout and the response race, and both call this. Whoever is second
    -- finds the request gone and says nothing -- which is what stops a late
    -- HTTP callback overwriting a timeout that has already been reported.
    if pending[req] == nil then return end
    pending[req] = nil

    if ok then stat.ok = stat.ok + 1 else stat.failed = stat.failed + 1 end

    TriggerEvent('br:ringmaster:handoffResult', req, ok, url, err)
end

--- Ask the console for a signed-in URL for one Discord id.
---
--- @param req string       the caller's own id; echoed back on the answer
--- @param discordId string
AddEventHandler('br:ringmaster:handoffMint', function(req, discordId)
    if type(req) ~= 'string' or req == '' then return end

    -- ALREADY IN FLIGHT. Not an error and not worth a log line: it means two
    -- callers picked the same id, which br_core's counter makes impossible, or
    -- that this handler ran twice for one event.
    if pending[req] ~= nil then return end

    pending[req] = true
    stat.asked = stat.asked + 1

    if not cfg.configured() then
        -- NOT AN ERROR, A SERVER WITH NO CONSOLE. br_core will not have offered
        -- the tab in this state, so reaching here means the two disagree --
        -- answer honestly rather than firing a request at nil.
        answer(req, false, nil, 'not-configured')
        return
    end

    if type(discordId) ~= 'string' or discordId:match('^%d+$') == nil then
        -- Refused here rather than spent on a round trip that would come back
        -- `schema`. The console's own check is the authority; this is the cheap
        -- half of it, and it keeps a malformed id out of the request body.
        answer(req, false, nil, 'schema')
        return
    end

    local endpoint = BR.Ring.originOf(cfg.ingestUrl)
    if endpoint == nil then
        answer(req, false, nil, 'not-configured')
        return
    end

    -- ARMED BEFORE THE REQUEST IS MADE, which is the idiom server/gate.lua
    -- spells out and it is not equivalent to arming it after. A
    -- PerformHttpRequest that throws synchronously -- a malformed URL is the
    -- realistic way -- would leave the timer unset and the request pending
    -- forever, and a caller waiting forever is the one outcome this file is
    -- not allowed to produce.
    SetTimeout(TIMEOUT_MS, function()
        if pending[req] == nil then return end
        stat.timedOut = stat.timedOut + 1
        print(('^3[br_ringmaster] handoff mint got no answer within %dms^7')
            :format(TIMEOUT_MS))
        answer(req, false, nil, 'timeout')
    end)

    PerformHttpRequest(endpoint .. MINT_PATH, function(status, body)
        local code = codeFor(status, body)

        if code ~= 'ok' then
            -- THE CODE, NEVER THE BODY. A successful body carries a token, and
            -- a log line is the one place a short-lived credential becomes a
            -- long-lived one. Failure bodies carry no token today, and printing
            -- them anyway would make that a property of the console's code
            -- rather than of ours.
            print(('^3[br_ringmaster] handoff mint refused: %s^7'):format(code))
            answer(req, false, nil, code)
            return
        end

        local decoded, parsed = pcall(json.decode, body)
        local url = nil
        if decoded and type(parsed) == 'table' then url = parsed.url end

        if type(url) ~= 'string' or url == '' then
            -- A 200 WE CANNOT USE. Treated as a failure rather than passed on:
            -- an iframe pointed at nil shows a blank rectangle, which is
            -- indistinguishable from every other way this can go wrong.
            answer(req, false, nil, 'malformed-reply')
            return
        end

        answer(req, true, url, nil)
    end, 'POST', json.encode({ discordId = discordId }), {
        ['Content-Type']        = 'application/json',
        ['X-Ringmaster-Secret'] = cfg.ingestSecret,
    })
end)
