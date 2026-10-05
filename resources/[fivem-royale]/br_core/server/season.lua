-- `brseason`: switch the season a dev box runs without restarting br_core (#388).
--
-- Owner, 2026-10-04: "Please add the devmode command. That was my only real
-- intended use case for faster-than-restart switching." Prod stays
-- restart-only: this is an ordinary dev command, registered through
-- br_lib/shared/devgate.lua's wrap, so a box without dev mode refuses it before
-- this file runs a line, and br_season is read exactly as it always was.
--
--   brseason            the season in force, where it came from, and any
--                       switch waiting
--   brseason <n>        switch to Season n (1 to `latest`)
--   brseason reset      back to the season br_core started on
--
-- ═══ NEVER MID-MATCH ═══
--
-- A switch with no match running applies at once. While ANY match instance
-- exists -- warmup, bus, playing, ended or cleanup -- it is STAGED, and applied
-- when the last one is torn down to the lobby: BR.Match.destroy is the only way
-- a match leaves the registry, and it raises `br:match:destroyed` after the
-- registry entry is gone and every player in it is back in the lobby. A second
-- `brseason` replaces a staged one, and one naming the season already in force
-- drops it. The doors a match is played through therefore never see the season
-- change under them.
--
-- ═══ WHAT AN APPLY MOVES ═══
--
--   * The season in force and br_seasonServed, together, through
--     BR.Season.switch -- br_lib/shared/season.lua holds the latch and is the
--     only file that names the convars. Every server door asks has() at call
--     time, so each answers the new season from the next question on; the
--     lobby label (server/lobby.lua, every 500 ms) included.
--   * Every connected player's market state, pushed again (BR.Market.push):
--     whether the page is sent emote ownership and the wheel is the season's
--     to decide, so nobody is left holding the old season's answer.
--   * Every crate still standing (BR.Loot.reseason): the look Season 2 crates
--     stamp once, as a crate is made, is re-stamped for the new season --
--     cleared, or given -- on the warmup pad's crates, its four, every husk,
--     and re-announced once to whoever is looking. The pad is stocked at
--     server start and outlives every switch; without this a Season 1 pad
--     kept Season 2's boxes (owner, 2026-10-04).
--   * Every client is told (BR.Net.SEASON_SWITCHED): one F8 line naming who
--     switched, and br_core/client/season.lua re-reads its season off the
--     replicated value and raises `br:season:changed` for everything on that
--     machine that has to follow.
--
-- A live dance cannot outlive the switch: dances play only in a match, and
-- server/emotes.lua's sweep stops one the moment the gate shuts.
--
-- ═══ WHAT AN APPLY CANNOT MOVE: LICENSED ASSETS (#391) ═══
--
-- The purchased packs (maps, emote animations) are streamed assets, and a
-- running server cannot swap those. tools/assets.py pull installs the set for
-- the season server.cfg names, at deploy, and records it -- with the set every
-- other season would install instead -- in br_licensed/installed.txt. So a
-- switch to a season whose set differs WARNS, naming the resources, and still
-- switches; the assets follow at the next redeploy and restart. No record (no
-- pull has ever run on this box) is no warning.
--
-- CONSOLE AND F8 ONLY. Every line here is dev-mode output; nothing is shown to
-- a player in game.

BR = BR or {}
BR.SeasonSwitch = BR.SeasonSwitch or {}

--- The switch waiting for the last running match to be torn down, or nil:
--- { season = integer, reset = boolean, by = string }.
local staged = nil

--- How many match instances exist. Every one of them is a match running, in
--- whatever state, because a match leaves the registry only by being torn down.
--- @return integer
local function running()
    local n = 0
    for _ in pairs(BR.Server.matches) do n = n + 1 end
    return n
end

--- Who typed it, for the console and every F8.
--- @param src integer
--- @return string
local function who(src)
    local s = tonumber(src) or 0
    if s <= 0 then return 'the server console' end
    local e = BR.Roster and BR.Roster.get and BR.Roster.get(s)
    local name = e and e.name or (GetPlayerName and GetPlayerName(s)) or '?'
    return ('%s (#%d)'):format(tostring(name), s)
end

--- One answer: this console, and the F8 of the player who typed it.
--- @param src integer
--- @param text string
local function tell(src, text)
    print('[br_core] ' .. text)
    local s = tonumber(src) or 0
    if s > 0 then TriggerClientEvent(BR.Net.SEASON_RESULT, s, text) end
end

--- Where tools/assets.py pull writes its install record: a resource nobody
--- ensures, because FXServer's sandbox lets the Lua read files only inside a
--- resource, and LoadResourceFile reads any resource the server knows of.
--- The two names are RECORD_RESOURCE and RECORD_FILE in tools/assets.py.
local LICENSED_RESOURCE = 'br_licensed'
local LICENSED_FILE = 'installed.txt'

--- Whether a record's version is a real sha256. After a swap whose undo also
--- failed, a resource the pull found in [licensed] with no earlier record of
--- it is written as `installed <name> unknown` (UNKNOWN_VERSION in
--- tools/assets.py): installed, at a version nobody can name.
--- @param v string|nil
--- @return boolean
local function knownVersion(v)
    return type(v) == 'string' and #v == 64 and v:find('^[0-9a-f]+$') ~= nil
end

--- The install record, parsed, or nil when it is absent or not format 1:
---   { season = n, installed = { [name] = sha }, plans = { [season] = { [name] = sha } } }
--- `plans` holds every season the pull planned for, an empty set included.
--- @param text string|nil
--- @return table|nil
function BR.SeasonSwitch.parseLicensed(text)
    if type(text) ~= 'string' then return nil end
    local m = { installed = {}, plans = {} }
    local format = nil
    for line in (text .. '\n'):gmatch('([^\n]*)\n') do
        local w = {}
        for t in line:gmatch('%S+') do w[#w + 1] = t end
        local k = w[1]
        if k == 'format' then
            format = w[2]
        elseif k == 'season' then
            m.season = math.tointeger(tonumber(w[2]))
        elseif k == 'seasons' then
            for i = 2, #w do
                local s = math.tointeger(tonumber(w[i]))
                if s then m.plans[s] = m.plans[s] or {} end
            end
        elseif k == 'installed' and #w == 3 then
            m.installed[w[2]] = w[3]
        elseif k == 'plan' and #w == 4 then
            local s = math.tointeger(tonumber(w[2]))
            if s and m.plans[s] then m.plans[s][w[3]] = w[4] end
        end
    end
    if format ~= '1' then return nil end
    return m
end

--- How `season`'s licensed set differs from the installed one, by name:
--- { name, have = installed sha or nil, want = season's sha or nil }, sorted.
--- nil when the record has no plan for that season.
--- @param m table  parseLicensed's answer
--- @param season integer
--- @return table|nil
function BR.SeasonSwitch.licensedDiff(m, season)
    local want = m.plans[season]
    if want == nil then return nil end
    local out = {}
    for name, sha in pairs(want) do
        if m.installed[name] ~= sha then out[#out + 1] = { name = name, have = m.installed[name], want = sha } end
    end
    for name, sha in pairs(m.installed) do
        if want[name] == nil then out[#out + 1] = { name = name, have = sha } end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

--- Warn, to this console and the F8 of whoever typed it, when `season` runs a
--- different licensed set from the one installed. Silent when they agree and
--- when there is no record.
--- @param src integer
--- @param season integer
local function licensedWarning(src, season)
    if type(LoadResourceFile) ~= 'function' then return end
    local m = BR.SeasonSwitch.parseLicensed(LoadResourceFile(LICENSED_RESOURCE, LICENSED_FILE))
    if m == nil then return end
    local diff = BR.SeasonSwitch.licensedDiff(m, season)
    if diff == nil then
        tell(src, ('brseason: WARNING -- the licensed asset record on this box has no plan for Season %d; redeploy to refresh it')
            :format(season))
        return
    end
    if #diff == 0 then return end
    local parts = {}
    for _, d in ipairs(diff) do
        if d.have == nil then
            parts[#parts + 1] = ('%s (not installed)'):format(d.name)
        elseif d.want == nil then
            parts[#parts + 1] = ('%s (installed, not in Season %d)'):format(d.name, season)
        elseif not knownVersion(d.have) then
            parts[#parts + 1] = ('%s (installed at a version a failed swap could not record, Season %d has %s)')
                :format(d.name, season, d.want:sub(1, 8))
        else
            parts[#parts + 1] = ('%s (installed %s, Season %d has %s)')
                :format(d.name, d.have:sub(1, 8), season, d.want:sub(1, 8))
        end
    end
    tell(src, ('brseason: WARNING -- Season %d runs different licensed assets from the ones installed: %s')
        :format(season, table.concat(parts, ', ')))
    tell(src, ('brseason: streamed assets cannot switch while the server runs; to install Season %d\'s, set that season in server.cfg, redeploy and restart')
        :format(season))
end

--- Put a switch into force now.
--- @param target integer|nil  nil is the season br_core started on
--- @param by string
local function apply(target, by)
    staged = nil
    local from = BR.Season.current()
    local now = BR.Season.switch(target)
    if now == nil then return end
    print(('[br_core] brseason: %s switched this server to Season %d (was Season %d)')
        :format(by, now, from or 0))

    -- THE SERVER STATE THE SEASON DECIDES. A whole market state per player,
    -- built at call time against the new season.
    if BR.Market and BR.Market.push and BR.Roster and BR.Roster.each then
        BR.Roster.each(nil, function(src) BR.Market.push(src) end)
    end

    -- Every crate still standing, restyled for the new season, before the
    -- clients are told -- a client handles either order (client/loot.lua).
    if BR.Loot and BR.Loot.reseason then
        local r = BR.Loot.reseason()
        if r.stamped + r.cleared > 0 then
            print(('[br_core] brseason: crates restyled for Season %d -- %d given a Season 2 look, %d back to wood, %d opening burst now, %d player(s) told')
                :format(now, r.stamped, r.cleared, r.burst, r.told))
        end
    end

    TriggerClientEvent(BR.Net.SEASON_SWITCHED, -1, { season = now, from = from, by = by })
end

--- The status lines, for a bare `brseason`.
--- @param src integer
local function status(src)
    local _, words = BR.Season.origin()
    tell(src, ('brseason: Season %d in force -- %s'):format(BR.Season.current(), tostring(words)))
    if staged then
        local n = running()
        tell(src, ('brseason: Season %d%s staged by %s, for when the last of %d running match%s is torn down to the lobby')
            :format(staged.season, staged.reset and ' (reset)' or '', staged.by, n, n == 1 and '' or 'es'))
    else
        tell(src, 'brseason: no switch staged')
    end
    tell(src, ('brseason: usage: brseason | brseason <1-%d> | brseason reset'):format(BR.Season.latest()))
    licensedWarning(src, BR.Season.current())
end

--- Switch now, or stage it while a match is running.
--- @param src integer
--- @param target integer  the season asked for
--- @param reset boolean   asked as `reset`
local function request(src, target, reset)
    local by = who(src)
    local cur = BR.Season.current()
    local n = running()

    if target == cur then
        if staged then
            staged = nil
            tell(src, ('brseason: Season %d is already in force -- the staged switch is dropped'):format(cur))
        else
            tell(src, ('brseason: Season %d is already in force'):format(cur))
        end
        return
    end

    if n > 0 then
        local replaced = staged ~= nil
        staged = { season = target, reset = reset, by = by }
        tell(src, ('brseason: %d match%s running -- Season %d%s is staged%s, and applies when the last one is torn down to the lobby')
            :format(n, n == 1 and '' or 'es', target, reset and ' (reset)' or '',
                    replaced and ', replacing the one staged before' or ''))
        licensedWarning(src, target)
        return
    end

    -- A reset hands switch() nil: the startup season, taken back whatever it
    -- was, even one past `latest` that br_season named.
    if reset then apply(nil, by) else apply(target, by) end
    licensedWarning(src, target)
end

--- THE TEARDOWN. Raised by BR.Match.destroy after the registry entry is gone,
--- so the count here already leaves the destroyed match out.
AddEventHandler('br:match:destroyed', function()
    if staged == nil or running() > 0 then return end
    local s = staged
    if s.reset then apply(nil, s.by) else apply(s.season, s.by) end
end)

--- The staged switch, copied, or nil. For the suites: nothing in the game
--- reads it.
--- @return table|nil
function BR.SeasonSwitch.staged()
    if staged == nil then return nil end
    return { season = staged.season, reset = staged.reset, by = staged.by }
end

-- Dev mode plus restricted, like brforce: through devgate.lua's wrap, so a box
-- without dev mode refuses it, and restricted, so a client's F8 needs the
-- `command` ACE server.cfg.example gives group.admin.
RegisterCommand('brseason', function(src, args)
    args = type(args) == 'table' and args or {}
    local a1 = args[1]
    if a1 == nil then status(src) return end

    if a1 == 'reset' then
        request(src, BR.Season.startup(), true)
        return
    end

    local n = BR.Season.parse(a1)
    local top = BR.Season.latest()
    if n == nil or n > top then
        tell(src, ('brseason: %q is not a season this code knows -- 1 to %d, or reset'):format(tostring(a1):sub(1, 16), top))
        return
    end
    request(src, n, false)
end, true)
