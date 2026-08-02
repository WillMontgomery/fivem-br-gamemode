-- Database layer.
--
-- The governing rule: A DATABASE FAILURE MUST NEVER STOP A MATCH.
--
-- Stats are nice to have; the gamemode is the product. So every call here is
-- wrapped, failures degrade to "stats not saved" rather than propagating, and a
-- circuit breaker stops a dead database from costing a timeout on every single
-- query for the rest of the session.

BR = BR or {}
BR.Db = {
    ready   = false,
    healthy = false,
    -- Circuit breaker. After this many consecutive failures we stop trying for
    -- a while: if MariaDB is down, 48 players x several queries each is a lot
    -- of pointless waiting, and every one of those waits is a stalled thread.
    failures      = 0,
    failureLimit  = 5,
    retryAfter    = 0,
    retryDelayMs  = 30000,
}

local RESOURCE_OXMYSQL = 'oxmysql'

--- Is oxmysql actually present and started?
local function oxmysqlAvailable()
    return GetResourceState(RESOURCE_OXMYSQL) == 'started'
end

--- Should we even attempt a query right now?
local function canQuery()
    if not BR.Db.ready then return false end
    if BR.Db.failures < BR.Db.failureLimit then return true end
    if GetGameTimer() >= BR.Db.retryAfter then
        -- Let one query through to test the water.
        return true
    end
    return false
end

local function noteSuccess()
    if BR.Db.failures > 0 then
        print('[br_stats] database recovered')
    end
    BR.Db.failures = 0
    BR.Db.healthy = true
end

local function noteFailure(context, err)
    BR.Db.failures = BR.Db.failures + 1
    BR.Db.healthy = false
    print(('[br_stats] query failed (%s): %s'):format(context, tostring(err)))

    if BR.Db.failures == BR.Db.failureLimit then
        BR.Db.retryAfter = GetGameTimer() + BR.Db.retryDelayMs
        print(('[br_stats] %d consecutive failures -- pausing database writes for %ds. '
            .. 'Gameplay continues; stats will not be saved.')
            :format(BR.Db.failures, BR.Db.retryDelayMs / 1000))
    end
end

--- Run a query and return rows, or nil on any failure.
---
--- Never raises. Callers check for nil rather than wrapping in pcall themselves.
--- @param sql string
--- @param params table|nil
--- @param context string  short label used in error output
--- @return table|nil
function BR.Db.query(sql, params, context)
    if not canQuery() then return nil end

    local ok, res = pcall(function()
        return exports[RESOURCE_OXMYSQL]:query_async(sql, params or {})
    end)

    if ok then
        noteSuccess()
        return res
    end
    noteFailure(context or 'query', res)
    return nil
end

--- Run a statement, returning affected rows or nil.
--- @param sql string
--- @param params table|nil
--- @param context string
--- @return number|nil
function BR.Db.execute(sql, params, context)
    if not canQuery() then return nil end

    local ok, res = pcall(function()
        return exports[RESOURCE_OXMYSQL]:update_async(sql, params or {})
    end)

    if ok then
        noteSuccess()
        return res
    end
    noteFailure(context or 'execute', res)
    return nil
end

--- Fetch a single row, or nil.
--- @param sql string
--- @param params table|nil
--- @param context string
--- @return table|nil
function BR.Db.single(sql, params, context)
    local rows = BR.Db.query(sql, params, context)
    if rows and rows[1] then return rows[1] end
    return nil
end

--- Run several statements as one transaction.
---
--- Match results are written this way so a crash mid-write cannot leave a match
--- half-recorded -- a player credited with a win in one table and absent from
--- the other is worse than no record at all.
---
--- @param queries table  array of { query = sql, values = {...} }
--- @param context string
--- @return boolean ok
function BR.Db.transaction(queries, context)
    if not canQuery() then return false end
    if #queries == 0 then return true end

    local ok, res = pcall(function()
        return exports[RESOURCE_OXMYSQL]:transaction_async(queries)
    end)

    if ok and res then
        noteSuccess()
        return true
    end
    noteFailure(context or 'transaction', ok and 'transaction returned false' or res)
    return false
end

--- Verify connectivity and that the schema has been applied.
---
--- Distinguishing "no database" from "database with no tables" matters: the
--- first is a config problem, the second means schema.sql was never run, and
--- the fix is different. Guessing wastes time.
local function checkSchema()
    local rows = BR.Db.query([[
        SELECT TABLE_NAME FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = DATABASE()
          AND TABLE_NAME IN ('br_players','br_matches','br_match_players')
    ]], {}, 'schema check')

    if not rows then
        print('[br_stats] could not reach the database. Gameplay will run; stats are disabled.')
        print('[br_stats]   check mysql_connection_string in server.cfg, and that MariaDB is running.')
        return
    end

    local found = {}
    for _, r in ipairs(rows) do found[r.TABLE_NAME] = true end

    local missing = {}
    for _, t in ipairs({ 'br_players', 'br_matches', 'br_match_players' }) do
        if not found[t] then missing[#missing + 1] = t end
    end

    if #missing > 0 then
        print(('[br_stats] connected, but missing tables: %s'):format(table.concat(missing, ', ')))
        print('[br_stats]   apply the schema:')
        print('[br_stats]   sudo mariadb -u root -p fivem_royale < resources/[fivem-royale]/br_stats/sql/schema.sql')
        BR.Db.healthy = false
        return
    end

    BR.Db.healthy = true
    local n = BR.Db.single('SELECT COUNT(*) AS c FROM br_players', {}, 'count')
    print(('[br_stats] database ready (%s player profiles)')
        :format(n and n.c or '?'))
end

AddEventHandler('onResourceStart', function(res)
    if res ~= GetCurrentResourceName() then return end

    if not oxmysqlAvailable() then
        print('[br_stats] oxmysql is not started -- stats are disabled, gameplay unaffected.')
        print('[br_stats]   add `ensure oxmysql` to server.cfg BEFORE br_stats.')
        return
    end

    BR.Db.ready = true
    -- Deferred so oxmysql has finished opening its pool; querying immediately on
    -- resource start races it and reports a false failure.
    Citizen.SetTimeout(2000, checkSchema)
end)

RegisterCommand('brdb', function()
    print('=== br_stats database ===')
    print(('  oxmysql       %s'):format(GetResourceState(RESOURCE_OXMYSQL)))
    print(('  ready         %s'):format(tostring(BR.Db.ready)))
    print(('  healthy       %s'):format(tostring(BR.Db.healthy)))
    print(('  failures      %d / %d'):format(BR.Db.failures, BR.Db.failureLimit))
    if BR.Db.failures >= BR.Db.failureLimit then
        local left = math.max(0, BR.Db.retryAfter - GetGameTimer())
        print(('  paused        retrying in %.0fs'):format(left / 1000))
    end
end, true)
