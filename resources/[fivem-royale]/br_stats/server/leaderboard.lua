-- Leaderboards.
--
-- Cached and refreshed on an interval rather than queried per request. With 48
-- players who can open the lobby at any time, a per-request query would mean
-- dozens of identical sorts a minute for data that changes only at match end.

BR = BR or {}
BR.Leaderboard = {}

local BOARDS = {
    wins  = { column = 'wins',  label = 'Wins'  },
    kills = { column = 'kills', label = 'Kills' },
    xp    = { column = 'xp',    label = 'Level' },
}

local LIMIT = 25
local REFRESH_MS = 120000

local cache = {}      -- [board] = array of rows
local lastRefresh = 0

--- Refresh every board. Cheap enough at this size to do all three together
--- rather than tracking staleness per board.
local function refresh()
    for key, def in pairs(BOARDS) do
        -- Column names are interpolated, never parameterised -- SQL does not
        -- allow a placeholder for an identifier. They come from the BOARDS
        -- table above and never from user input, which is what makes that safe.
        local rows = BR.Db.query(([[
            SELECT license, name, level, xp, wins, kills, matches
            FROM br_players
            WHERE matches > 0
            ORDER BY %s DESC, matches ASC
            LIMIT %d
        ]]):format(def.column, LIMIT), {}, 'leaderboard ' .. key)

        if rows then
            cache[key] = rows
        end
    end
    lastRefresh = GetGameTimer()
end

--- @param board string  one of 'wins' | 'kills' | 'xp'
--- @return table rows
function BR.Leaderboard.get(board)
    if not BOARDS[board] then board = 'wins' end
    if GetGameTimer() - lastRefresh > REFRESH_MS then
        refresh()
    end
    return cache[board] or {}
end

--- Where a specific player sits on a board. Computed on demand, since it is
--- only ever needed for the handful of players actually looking at it.
--- @param license string
--- @param board string
--- @return integer|nil rank
function BR.Leaderboard.rankOf(license, board)
    local def = BOARDS[board] or BOARDS.wins
    local row = BR.Db.single(([[
        SELECT COUNT(*) + 1 AS rank_
        FROM br_players
        WHERE matches > 0 AND %s > (SELECT %s FROM br_players WHERE license = ?)
    ]]):format(def.column, def.column), { license }, 'leaderboard rank')
    return row and row.rank_ or nil
end

AddEventHandler('onResourceStart', function(res)
    if res ~= GetCurrentResourceName() then return end
    -- Deferred so db.lua has finished its schema check first.
    Citizen.SetTimeout(5000, refresh)
end)

RegisterCommand('brtop', function(_, args)
    local board = args[1] or 'wins'
    local rows = BR.Leaderboard.get(board)
    print(('=== leaderboard: %s ==='):format(board))
    if #rows == 0 then
        print('  (empty -- no completed matches yet, or stats are unavailable)')
        return
    end
    print('  #   name                 lvl   wins  kills  matches')
    print('  --- -------------------- ----- ----- ------ -------')
    for i, r in ipairs(rows) do
        print(('  %-3d %-20s %-5s %-5s %-6s %s')
            :format(i, tostring(r.name):sub(1, 20), r.level, r.wins, r.kills, r.matches))
    end
end, true)
