--[[
    Paying for accurate reports (#168).

    THE PROMISE: 250 Volts to the reporter and to every corroborator, when an
    incident resolves and an action was taken. If they are in the server they
    are told; if they are not, the Volts land anyway, because the award is on
    the account and not on the session.

    ═══ WHY IT LIVES IN br_stats ═══

    Because this is a currency write, and br_stats is where currency writes
    live. The alternative homes are worse in the same way: br_core would be
    reaching into the profile table it has spent this whole project not owning,
    and br_ringmaster does not know what a Volt is.

    It also inherits the rule this resource has always run on, unchanged: A
    STATS FAILURE MUST NEVER STOP A MATCH. Nothing here is on any hot path,
    nothing blocks, every failure is a log line, and the queue survives all of
    them because it is in DynamoDB rather than in this process.

    ═══ WHY THERE IS A QUEUE AT ALL ═══

    The verdict is written by a human in a web console in another region, and
    that happens minutes, hours or days after the report. The game server will
    be restarted several times in that window. So "remember who to pay" cannot
    be a Lua table: a deploy between the report and the admin's decision would
    lose the debt silently, with nothing anywhere recording that it was owed --
    which is the precise failure the console's own aws-setup notes warn about
    when they weigh pushing verdicts down the SSH channel against reading them.

    The queue is therefore one DynamoDB item on the GAME's own table, written
    when a report is accepted and drained by the sweep below. See the reward
    ledger section of js-src/br_ddb/src/index.js for its shape.

    ═══ WHY IT POLLS ═══

    Because the game cannot be told. There is a console -> game channel (the SSH
    dispatcher that carries a kick) and it is deliberately not used for this: a
    dropped message on that path is an unpaid reward with nothing recording that
    it was owed, whereas a missed poll is a reward paid on the next sweep. The
    owner granted `dynamodb:GetItem` on 2026-08-17 to make this the read it is.

    ═══ WHAT MAKES IT SAFE TO SWEEP FOREVER ═══

    Every payment is one conditional UpdateItem that credits the balance and
    records the incident id in the same write. Re-reading a resolution, sweeping
    twice, restarting mid-sweep, or running this against a queue entry that was
    already settled all converge on the same answer, because DynamoDB refuses
    the second credit rather than this file remembering not to ask for it.
]]

BR = BR or {}
BR.Awards = {}

--- What an accurate report is worth (#168, owner: "250 Volts").
---
--- HERE RATHER THAN IN config/market.lua, and the line is worth the argument.
--- That file holds what a MATCH pays, next to what things cost, so that the two
--- stay calibrated against each other -- and this is neither. It is a fixed
--- bounty on a moderation action, it is not part of the earn-per-hour curve the
--- market is tuned against, and putting it in that table would invite somebody
--- to retune it alongside numbers it has nothing to do with.
local AWARD_VOLTS = 250

--- How often to ask whether anything has been decided.
---
--- TEN MINUTES, AND THE COST IS THE REASON IT IS NOT TEN SECONDS. Each sweep is
--- one GetItem plus one per pending case, on a personally funded project, to
--- learn something nobody is waiting on -- the reward is a pleasant surprise
--- hours later, not a transaction anybody is watching for. An admin resolving a
--- case is not blocked by this either way.
local SWEEP_MS = 600000

--- Long enough after boot that br_ddb has answered its first request.
local FIRST_SWEEP_MS = 60000

--- How many cases one sweep will look at.
---
--- The queue is drained faster than it fills on any realistic server, so this is
--- a ceiling on a pathological case rather than a throttle on a normal one: it
--- stops a queue that somehow grew to hundreds from turning one sweep into
--- hundreds of round trips.
local SWEEP_BATCH = 10

--- When to give up on a case that has never been decided.
---
--- THIRTY DAYS. A case still untriaged after a month is not going to pay
--- anybody, and a claim that stays on the queue forever is a row that is read on
--- every sweep for the rest of the server's life. Dropped rather than paid: no
--- verdict is not a verdict.
local CLAIM_MAX_AGE_MS = 30 * 24 * 60 * 60 * 1000

--- br_ddb's answer deadline. Same shape as persist.lua's, same reason: a bridge
--- that never answers must not leak a pending closure per request.
local ASK_TIMEOUT_MS = 8000

local nextReq = 0
local pending = {}

local function reply(req, ...)
    local cb = pending[req]
    if not cb then return end
    pending[req] = nil
    cb(...)
end

AddEventHandler('br:ddb:awardClaimResult',  function(req, ok, info) reply(req, ok, info or {}) end)
AddEventHandler('br:ddb:awardQueueResult',  function(req, rows, info) reply(req, rows or {}, info or {}) end)
AddEventHandler('br:ddb:verdictResult',     function(req, ok, info) reply(req, ok, info or {}) end)
AddEventHandler('br:ddb:awardPayResult',    function(req, ok, info) reply(req, ok, info or {}) end)
AddEventHandler('br:ddb:awardSettleResult', function(req, ok, info) reply(req, ok, info or {}) end)

--- Issue one br_ddb request with a timeout of our own.
---
--- The `ask` convention from br_ringmaster/server/incident.lua, copied rather
--- than shared because the two resources cannot see each other's Lua.
local function ask(event, cb, ...)
    if GetResourceState('br_ddb') ~= 'started' then
        cb(false, { error = 'br_ddb not started' })
        return
    end

    nextReq = nextReq + 1
    local req = nextReq
    pending[req] = cb

    SetTimeout(ASK_TIMEOUT_MS, function()
        if pending[req] then
            pending[req] = nil
            cb(false, { error = 'timed out' })
        end
    end)

    TriggerEvent(event, req, ...)
end

--- Counters, for `brawards`.
local stat = { claimed = 0, swept = 0, paid = 0, already = 0, settled = 0, expired = 0 }

function BR.Awards.stats()
    return {
        claimed = stat.claimed, swept = stat.swept, paid = stat.paid,
        already = stat.already, settled = stat.settled, expired = stat.expired,
    }
end

-- ---------------------------------------------------------------------------
-- Claiming
-- ---------------------------------------------------------------------------

--- Somebody is owed for a case. Record it durably and forget about it.
---
--- FIRE AND FORGET, AND THE FAILURE IS ONE LINE. The report itself is already a
--- row in `ringmaster-incidents` by the time this fires -- br_core emits this
--- off the acknowledgement, not off the submit -- so a lost claim costs one
--- reward and never the case. Retrying would mean holding a payload across a
--- restart, which is the thing the durable queue exists to avoid needing.
AddEventHandler('br:report:claim', function(ev)
    if type(ev) ~= 'table' then return end
    if type(ev.incidentId) ~= 'string' or ev.incidentId == '' then return end
    if type(ev.license) ~= 'string' or ev.license == '' then return end

    stat.claimed = stat.claimed + 1

    ask('br:ddb:awardClaim', function(ok, info)
        if not ok then
            print(('^3[br_stats] reward claim not recorded for %s on %s: %s^7')
                :format(ev.license, ev.incidentId, tostring((info or {}).error)))
        end
    end, ev.incidentId, ev.license)
end)

-- ---------------------------------------------------------------------------
-- Telling them
-- ---------------------------------------------------------------------------

--- The server id of a connected account, or nil.
---
--- WALKED RATHER THAN CACHED. This runs a handful of times a week, on a list of
--- at most 48, and a cache of license -> src is a thing that goes stale exactly
--- when a server id is recycled -- which would address the reward message to
--- whoever connected into that slot.
--- @param license string
--- @return integer|nil
local function srcFor(license)
    if not BR.Identity then return nil end
    for _, id in ipairs(GetPlayers()) do
        local src = tonumber(id)
        local byKind = src and BR.Identity.ofPlayer(src)
        if byKind and BR.Identity.qualified('license', byKind.license) == license then
            return src
        end
    end
    return nil
end

--- The sentence, exactly as #168 words it.
---
--- THE VERDICT WORD COMES FROM `action` AND NOTHING ELSE, resolved in br_ddb's
--- verdict.js against the console's contract. The admin's written resolution is
--- NOT in here and must not be: it is prose one moderator wrote for another, and
--- forwarding it hands a stranger's internal note to the person who reported
--- them.
local function tell(src, word)
    TriggerClientEvent(BR.Net.NOTIFY, src, {
        text = ("You've been gifted %d Volts for reporting a player, who has now been %s. Thanks for your help!")
            :format(AWARD_VOLTS, word),
        tone = 'success',
        -- Keyed so two rewards landing in the same sweep replace rather than
        -- stack; `ms` because this is news, not a state that persists.
        key  = 'report.reward',
        ms   = 10000,
    })
end

-- ---------------------------------------------------------------------------
-- The sweep
-- ---------------------------------------------------------------------------

--- Pay everybody owed for one case, then take it off the queue.
---
--- SETTLED ONLY WHEN EVERY PAYEE HAS ANSWERED, and "already paid" counts as an
--- answer -- it is the outcome we wanted, reported by DynamoDB refusing the
--- second credit. A payee whose write genuinely FAILED leaves the case on the
--- queue, so the next sweep tries again; the ones who were already paid are
--- refused a second time and cost nothing.
---
--- @param entry table  { incidentId, licenses, claimedAt }
--- @param word string|nil  'banned' | 'kicked', or nil when nobody is being paid
local function settleCase(entry, word)
    local payees = word and entry.licenses or {}
    local left = #payees
    local failed = false

    local function finish()
        if failed then
            print(('^3[br_stats] reward for %s not fully paid -- left on the queue^7')
                :format(entry.incidentId))
            return
        end
        stat.settled = stat.settled + 1
        ask('br:ddb:awardSettle', function() end, entry.incidentId)
    end

    if left == 0 then
        finish()
        return
    end

    for _, license in ipairs(payees) do
        ask('br:ddb:awardPay', function(ok, info)
            info = info or {}
            if not ok then
                failed = true
                print(('^3[br_stats] reward not paid to %s for %s: %s^7')
                    :format(license, entry.incidentId, tostring(info.error)))
            elseif info.alreadyPaid then
                -- The whole idempotence story in one branch: this is what a
                -- second sweep over a settled case looks like from here.
                stat.already = stat.already + 1
            else
                stat.paid = stat.paid + 1

                -- KEEP br_core's CACHE HONEST, the same call persist.lua makes
                -- after a match write and for the same reason: br_core read the
                -- balance once on connect and holds it for the session, so
                -- without this the lobby would go on showing the old total.
                -- Zero XP -- a report earns Volts and nothing else.
                TriggerEvent('br:market:credited', license, 0, AWARD_VOLTS)

                -- IN THE SERVER OR NOT, THE VOLTS LANDED. Being told is the
                -- part that depends on being here; the write above does not.
                local src = srcFor(license)
                if src then tell(src, word) end

                print(('[br_stats] reward: %d Volts to %s for %s (%s)%s')
                    :format(AWARD_VOLTS, license, entry.incidentId, word,
                            src and '' or ' -- offline, credited anyway'))
            end

            left = left - 1
            if left == 0 then finish() end
        end, license, entry.incidentId, AWARD_VOLTS)
    end
end

--- One case: read the verdict, then act on it.
local function considerCase(entry, now)
    ask('br:ddb:incidentVerdict', function(ok, v)
        v = v or {}

        if not ok then
            -- FAILS CLOSED. An unreadable case is not a decision; it stays on
            -- the queue and the next sweep asks again.
            print(('^3[br_stats] verdict unreadable for %s: %s^7')
                :format(entry.incidentId, tostring(v.error)))
            return
        end

        if not v.settled then
            -- Still pending, or the row is not there yet. Age it out rather
            -- than reading it forever.
            local age = now - (tonumber(entry.claimedAt) or 0)
            if entry.claimedAt and entry.claimedAt > 0 and age > CLAIM_MAX_AGE_MS then
                stat.expired = stat.expired + 1
                print(('[br_stats] reward claim for %s expired after %d day(s), unpaid')
                    :format(entry.incidentId, math.floor(age / 86400000)))
                ask('br:ddb:awardSettle', function() end, entry.incidentId)
            end
            return
        end

        -- RESOLVED. `payable` is `action ~= 'none'` with absent treated as
        -- ITS OWN state -- see verdict.js. A case an admin closed with no
        -- action, and a case that carries no verdict at all, both settle here
        -- paying nobody, and the log tells them apart because they are
        -- different facts about the same 250 Volts.
        if not v.payable then
            print(('[br_stats] case %s resolved with %s -- nobody paid')
                :format(entry.incidentId,
                        v.action and ('no action taken (' .. tostring(v.action) .. ')')
                        or 'no verdict recorded'))
            settleCase(entry, nil)
            return
        end

        settleCase(entry, v.word or 'actioned')
    end, entry.incidentId)
end

--- Read the queue and consider what is on it.
function BR.Awards.sweep()
    if GetResourceState('br_ddb') ~= 'started' then return end

    ask('br:ddb:awardQueue', function(rows, info)
        if type(rows) ~= 'table' then return end
        if (info or {}).error then
            print(('^3[br_stats] reward queue unreadable: %s^7'):format(tostring(info.error)))
            return
        end

        local now = os.time() * 1000
        local n = 0
        for _, entry in ipairs(rows) do
            if n >= SWEEP_BATCH then break end
            if type(entry) == 'table' and type(entry.incidentId) == 'string' then
                -- A case with no payees is a queue entry whose licenses were
                -- lost; settling it costs nothing and stops it being read
                -- forever.
                entry.licenses = type(entry.licenses) == 'table' and entry.licenses or {}
                n = n + 1
                stat.swept = stat.swept + 1
                considerCase(entry, now)
            end
        end
    end)
end

Citizen.CreateThread(function()
    Citizen.Wait(FIRST_SWEEP_MS)
    while true do
        BR.Awards.sweep()
        Citizen.Wait(SWEEP_MS)
    end
end)

--- What the reward pipeline has done since this resource started.
---
--- RESTRICTED, like every other operational command: it names licenses.
RegisterCommand('brawards', function()
    local s = BR.Awards.stats()
    print('^5[br_stats]^7 report rewards')
    print(('  claimed  %d   swept %d'):format(s.claimed, s.swept))
    print(('  paid     %d   already paid %d'):format(s.paid, s.already))
    print(('  settled  %d   expired unpaid %d'):format(s.settled, s.expired))
    print(('  %d Volts per accurate report; sweeping every %ds')
        :format(AWARD_VOLTS, SWEEP_MS / 1000))
    print('  A sweep reads the reward queue on br-players, then one verdict per')
    print('  pending case from ringmaster-incidents. Payment is conditional, so')
    print('  running this pipeline twice pays nobody twice.')
    BR.Awards.sweep()
    print('  ...swept now.')
end, true)
