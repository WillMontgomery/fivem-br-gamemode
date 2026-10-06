-- Unit tests for Season 2's Yubikey and the terminals it opens (#396): the
-- Gameplay half. The shell half -- the session door, the computer, the app's
-- relay -- is tools/test_terminal.lua.
--
-- Every rule the owner set on 2026-10-04, on the real files:
--
--   PART A  br_core/server/yubikey.lua and server/terminal.lua, with the REAL
--           server/loot.lua's claim and open, against a stubbed roster,
--           scheduler, timer and br_ddb:
--             the key: the profile read, the cap of one, the first-pickup line
--             once ever, the death drop, the leave drop (and its switch), the
--             carry into the next match, every profile write;
--             the sources: 50% per airdrop and the legendary crate's small
--             chance, at their odds, on a stream of their own -- an EXTRA item,
--             so nothing else in the box moves;
--             the terminals: online only inside the storm's current zone; a use
--             only from a living player at a live terminal in a live match;
--             access, then the run: the key spent, the squad's ONE use spent,
--             the lobby told twice; a squad's second holder refused; a solo
--             player a squad of one; Storm reveal to the squad and nobody else;
--             the session closed when its player dies or walks off or the
--             storm takes the terminal; every dev tool.
--   PART B  br_core/client/yubikey.lua over modelled natives: blips only while
--           holding a key, only for a terminal inside the storm, only in a
--           match; the plate's four readings; the hold that asks the server;
--           Storm reveal on both maps until the lobby; and no native at all on
--           a frame without a plate.
--   PART C  Season 1: none of it, anywhere.
--   PART D  the hooks the other files make, pinned by text: market.lua hands
--           the profile over, combat.lua and roster.lua drop the key on the
--           right edges, party.lua's beacon carries the holder bit to the squad
--           alone, and the HUD envelope carries the glyph.
--
-- Run via tools/verify.sh, or directly:  lua tools/test_yubikey.lua

local realPrint = print
local realExit  = os.exit

local gameMs = 100000
function GetGameTimer() return gameMs end
function GetCurrentResourceName() return 'br_core' end

local ROOT = 'resources/[fivem-royale]/'
local function loadAll(files)
    for _, f in ipairs(files) do
        local chunk, err = loadfile(ROOT .. f)
        if not chunk then
            realPrint('\27[31mload error\27[0m ' .. f .. ': ' .. tostring(err))
            realExit(1)
        end
        chunk()
    end
end

local function readFile(path)
    local fh = io.open(path, 'rb')
    if not fh then return nil end
    local s = fh:read('a')
    fh:close()
    return s
end

-- ---------------------------------------------------------------- harness ---

local pass, fail = 0, 0
local group = ''

local function describe(name) group = name end

local function ok(cond, name, detail)
    if cond then
        pass = pass + 1
    else
        fail = fail + 1
        realPrint(('\27[31mFAIL\27[0m %s > %s%s'):format(group, name,
            detail and ('\n       ' .. tostring(detail)) or ''))
    end
end

local function eq(got, want, name)
    ok(got == want, name, ('got %s, want %s'):format(tostring(got), tostring(want)))
end

local logs = {}
function print(s) logs[#logs + 1] = tostring(s) end

-- =========================================================================
-- PART A -- the server
-- =========================================================================

local convars = { sv_devMode = 'true', br_season = '2' }
function GetConvar(n, d)
    local v = convars[n]
    if v == nil then return d end
    return v
end
function SetConvarReplicated(n, v) convars[n] = v end

-- THE RAW COMMAND TABLE, BEFORE devgate.lua, which wraps whatever
-- RegisterCommand is when it loads -- exactly as in the game, where the dev
-- gate is the first shared script.
local commands = {}
function RegisterCommand(name, fn) commands[name] = fn end

loadAll({
    'br_lib/shared/devgate.lua',
    'br_lib/shared/enums.lua',
    'br_lib/shared/protocol.lua',
    'br_lib/shared/notice.lua',
    'br_lib/shared/matchtag.lua',
    'br_lib/shared/rng.lua',
    'br_lib/shared/geo.lua',
    'br_lib/shared/polygon.lua',
    'br_lib/shared/clock.lua',
    'br_lib/config/match.lua',
    'br_lib/config/storm.lua',
    'br_lib/config/map.lua',
    'br_lib/config/weapons.lua',
    'br_lib/config/loot.lua',
    'br_lib/config/warmupcrates.lua',
    'br_lib/config/airdrop.lua',
    'br_lib/shared/season.lua',
    'br_lib/config/seasons.lua',
    'br_lib/config/festive.lua',
    'br_lib/shared/festive.lua',
    'br_lib/config/crates.lua',
    'br_lib/shared/crates.lua',
    'br_lib/config/terminals.lua',
    'br_lib/shared/storm_solve.lua',
    'br_lib/shared/storm_shape.lua',
    'br_lib/shared/loot_gen.lua',
    'br_lib/shared/terminal_solve.lua',
})

local R = BR.Rarity
local CT = BR.Config.Terminals
local COPY = CT.copy
BR.Season.strict = true

-- =========================================================================
-- THE OWNER'S FIFTEEN SITES (2026-10-06), as the config has them -- read
-- here, before this suite puts its own two in their place
-- =========================================================================

--- The config's own rows, kept before this suite puts its two in their place.
local OWNER_SITES = nil

describe('the sites: the owner\'s fifteen laptops, his order, his numbers')
do
    -- "they're located at 15 places shown below", word for word: his order,
    -- his x / y / z. The ids are his labels (la_mesa_pd is "chumash? PD",
    -- whose coordinates are La Mesa's).
    local WANT = {
        { 'mount_gordo', 2825.834, 5969.14648, 351.6426 },
        { 'chiliad_top', 472.667969, 5536.955, 785.8789 },
        { 'fort_zancudo', -2455.12769, 3703.64917, 15.4468756 },
        { 'paleto_pd', -429.23584, 5963.753, 30.50765 },
        { 'calafia_way', 361.000427, 4434.68652, 61.91766 },
        { 'vineyard', -1847.0896, 1929.22607, 150.897141 },
        { 'rebel_radio', 764.2342, 2569.98633, 75.97378 },
        { 'panorama_drive', 1901.3136, 3201.079, 46.3064651 },
        { 'vinewood_towers', 793.333, 1286.544, 360.9136 },
        { 'vinewood_bowl', 998.1884, 408.309143, 93.7109 },
        { 'hillcrest_road', -781.49176, 593.5306, 128.329178 },
        { 'college_lot', -1725.14148, 76.23494, 67.39259 },
        { 'la_mesa_pd', 852.3667, -1368.79871, 26.7313938 },
        { 'heliport_factory', -630.0207, -1664.05212, 26.5907326 },
        { 'vespucci_canals', -1111.44263, -966.7761, 2.909578 },
    }
    local rows = CT.sites
    OWNER_SITES = rows
    eq(#rows, #WANT, 'fifteen rows')
    for i, w in ipairs(WANT) do
        local r = rows[i] or {}
        ok(r.id == w[1] and r.x == w[2] and r.y == w[3] and r.z == w[4] and r.h == 0.0,
            ('row %d is %s at the owner\'s %.6f, %.6f, %.6f, heading 0'):format(i, w[1], w[2], w[3], w[4]),
            ('%s %s %s %s %s'):format(tostring(r.id), tostring(r.x), tostring(r.y), tostring(r.z), tostring(r.h)))
    end
    -- Every row a terminal: the shared check skips none and names none.
    local usable, why = BR.TerminalSolve.sites(rows)
    eq(#usable, #WANT, 'BR.TerminalSolve.sites takes every row')
    eq(#why, 0, 'and skips none')
    -- INSIDE THE PLAY AREA the owner surveyed (tools/check_boundary.lua holds
    -- the POIs and the ambulance spawns to it, and the sites since this round),
    -- and in no authored water rectangle.
    for _, r in ipairs(rows) do
        ok(BR.Config.Map.InBounds(r.x, r.y), ('%s is inside the surveyed boundary'):format(r.id))
        ok(not BR.Config.Map.IsWater(r.x, r.y), ('%s is not in a water rectangle'):format(r.id))
    end
end

--- Put this process on a season, the way br_core's server does at start.
local function season(n)
    BR.Season.boot(function(name)
        return name == 'br_season' and tostring(n) or ''
    end, function() end)
end
season(2)

-- ---------------------------------------------------------------- stubs ---

local jobs, handlers = {}, {}
local sent = {}          -- TriggerClientEvent: { event, src, payload }
local timers = {}
local notices = {}       -- BR.Server.notify: { target, text, tone }
local writes = {}        -- br:ddb:yubikeySet: { req, lic, held }
local resources = { br_ddb = 'started' }

BR.Sched = { every = function(_, name, fn) jobs[name] = fn end }
function RegisterNetEvent() end
function AddEventHandler(name, fn)
    handlers[name] = handlers[name] or {}
    table.insert(handlers[name], fn)
end
function TriggerClientEvent(event, src, payload)
    sent[#sent + 1] = { event = event, src = src, payload = payload }
end
function TriggerEvent(name, req, lic, held)
    if name == 'br:ddb:yubikeySet' then
        writes[#writes + 1] = { req = req, lic = lic, held = held }
    end
end
function SetTimeout(ms, fn) timers[#timers + 1] = { at = gameMs + ms, fn = fn } end
function GetResourceState(name) return resources[name] or 'missing' end
function GetPlayerPed() return 0 end
function GetEntityCoords() return nil end

local roster, matches = {}, {}
function GetPlayerName(src) return roster[src] and roster[src].name or nil end

BR.Roster = {
    get = function(src) return roster[src] end,
    each = function(pred, fn)
        for src, e in pairs(roster) do
            if not pred or pred(e) then fn(src, e) end
        end
    end,
}
BR.Server = {
    matchOf = function(src)
        local e = roster[src]
        return e and e.matchId and matches[e.matchId] or nil
    end,
    matchById = function(id) return matches[id] end,
    eachMatch = function(fn) for _, m in pairs(matches) do fn(m) end end,
    notify = function(target, text, tone)
        notices[#notices + 1] = { target = target, text = text, tone = tone }
    end,
    isInMatch = function(st)
        return st == BR.PlayerState.ALIVE or st == BR.PlayerState.DBNO
            or st == BR.PlayerState.WARMUP or st == BR.PlayerState.BUS
            or st == BR.PlayerState.FREEFALL or st == BR.PlayerState.GLIDE
    end,
}
BR.Inv = {
    give = function() return true end,
    carryMax = function() return nil end,
    -- Max ammo's two (server/terminalfx.lua): tools/test_terminalfx.lua's.
    ammoRoom = function() return 30 end,
    fillAmmo = function() return 30 end,
}
BR.Airdrop = {
    opened = function() end,
    -- Supply drop's three (server/terminalfx.lua): tools/test_terminalfx.lua's
    -- and, under the real siting rules, tools/test_airdrop.lua's.
    busy = function() return false end,
    candidate = function(_, x, y) return { id = 'stub', x = x, y = y } end,
    call = function(_, x, y) return { n = 1, x = x, y = y } end,
}
BR.Admin = { devTrusted = function() return true end }
--- server/storm.lua's finalCentre is tools/test_storm.lua's (`server.final`);
--- here the match carries the answer.
BR.Storm = { finalCentre = function(m) return m and m.finalStub or nil end }

loadAll({
    'br_core/server/loot.lua',
    'br_core/server/yubikey.lua',
    'br_core/server/terminal.lua',
    'br_core/server/terminalfx.lua',
})

local Y, T = BR.Yubikey, BR.Terminal

local function fire(name, src, ...)
    local prev = source
    source = src
    for _, fn in ipairs(handlers[name] or {}) do fn(...) end
    source = prev
end

local function sv(src, line)
    local args = {}
    for w in line:gmatch('%S+') do args[#args + 1] = w end
    commands.brterminalsv(src, args, 'brterminalsv ' .. line)
end

local function eventsOf(name, src)
    local out = {}
    for _, s in ipairs(sent) do
        if s.event == name and (src == nil or s.src == src) then out[#out + 1] = s end
    end
    return out
end

local function lastOf(name, src)
    local e = eventsOf(name, src)
    return e[#e] and e[#e].payload or nil
end

local function noticesTo(src)
    local out = {}
    for _, n in ipairs(notices) do
        local t = n.target
        if t == src then out[#out + 1] = n
        elseif type(t) == 'table' then
            for _, s in ipairs(t) do if s == src then out[#out + 1] = n break end end
        end
    end
    return out
end

--- One function's row in a terminal state, by id: the registry lists every
--- function, so a position is not an identity.
local function fnOf(state, id)
    for _, f in ipairs(state and state.functions or {}) do
        if f.id == id then return f end
    end
    return nil
end

local function noticeText(n)
    if type(n.text) == 'table' then return n.text.text end
    return n.text
end

local function said(fragment)
    for _, l in ipairs(logs) do
        if l:find(fragment, 1, true) then return true end
    end
    return false
end

--- Where the storm's centre sits, and a terminal near it and one far outside.
local C0 = { x = 1200.0, y = -800.0 }
local NEAR_SITE = { id = 'tower', x = C0.x + 1.0, y = C0.y, z = 30.0, h = 90.0 }
local FAR_SITE  = { id = 'shack', x = C0.x + 6000.0, y = C0.y, z = 30.0, h = 0.0 }

local function newMatch(id)
    local m = {
        id = id, seq = id, state = BR.MatchState.PLAYING, mode = 'squad',
        loot = { seed = 77, nextId = 0, items = {}, cells = {}, subs = {}, at = {},
                 respawn = {}, fixed = 0 },
        -- A storm holding on a 1500 m zone round C0 for ten minutes.
        storm = BR.BuildStormRecord(2, C0.x, C0.y, 1500.0, C0.x, C0.y, 800.0,
            gameMs, 600000, 60000, 1.0, 4242),
        finalStub = { x = 1111.0, y = -2222.0, r = 0.0, phase = 8 },
    }
    matches[id] = m
    return m
end

local LIC = {}
--- A player in match `m`, squad `squad` (nil for solo), standing at `at`, with
--- a profile that says `held`/`seen`.
local function player(src, m, squad, at, held, seen)
    roster[src] = {
        src = src, name = 'p' .. src, state = BR.PlayerState.ALIVE,
        matchId = m and m.id or nil, squadId = squad,
        pos = { x = at.x, y = at.y, z = at.z or 30.0 },
    }
    if m then m.loot.subs[src] = { [BR.LootCellKeyAt(at.x, at.y)] = true } end
    LIC[src] = 'license:' .. src
    Y.loaded(src, LIC[src], { yubikey = held == true, yubikeySeen = seen == true })
end

--- Every pending timer, in order, the clock moved to each: a run's loading
--- over (round 2), and whatever else was waiting.
local function flush()
    for _ = 1, 20 do
        if #timers == 0 then return end
        local due = timers
        timers = {}
        table.sort(due, function(a, b) return a.at < b.at end)
        for _, t in ipairs(due) do
            if t.at > gameMs then gameMs = t.at end
            t.fn()
        end
    end
end

local function reset()
    -- The last block's runs, finished first: a run left loading would still be
    -- in flight for its player in the next block.
    flush()
    sent, timers, notices, writes, logs = {}, {}, {}, {}, {}
    roster, matches = {}, {}
    gameMs = gameMs + 100000
    resources = { br_ddb = 'started' }
    CT.leaveDrops = true
end

--- server/terminal.lua caches the config sites on first read; this suite sets
--- them before the first read and never changes them.
CT.sites = { NEAR_SITE, FAR_SITE }

local function claim(src, id)
    fire(BR.Net.LOOT_CLAIM, src, { id = id })
    gameMs = gameMs + 300
end

local function groundKeys(m)
    local out = {}
    for _, e in pairs(m.loot.items) do
        if e.kind == 'yubikey' then out[#out + 1] = e end
    end
    return out
end

-- ---------------------------------------------------------------- the key ---

describe('the key: read from the profile, held across matches')
do
    reset()
    local m = newMatch(1)
    player(1, m, nil, C0, true, true)
    player(2, m, nil, C0, false, false)
    eq(Y.holds(1), true, 'a profile that says yubikey = 1 holds a key from the first second -- carried over')
    eq(Y.holds(2), false, 'and one that says 0 does not')
    local st = lastOf(BR.Net.YUBIKEY_STATE, 1)
    ok(st and st.held == true and st.squadUsed == false, 'the holder is told, the moment the profile arrives')
    eq(Y.holds(99), false, 'a player whose profile never arrived holds nothing')

    -- A NEW MATCH IS NOT A NEW KEY: the same license in another match still holds it.
    local m2 = newMatch(2)
    roster[1].matchId = m2.id
    eq(Y.holds(1), true, 'unused, it walks into the next match with them')

    -- A reconnect the market answers from its cache.
    Y.adopt(7, LIC[1])
    eq(Y.holds(7), true, 'a reconnect on the same license is handed the cached key (BR.Yubikey.adopt)')
end

describe('the key: a pickup, the cap of one, and the first-pickup line once ever')
do
    reset()
    local m = newMatch(1)
    player(1, m, nil, C0, false, false)
    player(2, m, nil, C0, true, true)
    local e = Y.dropAt(m, C0.x + 0.5, C0.y, 30.0)
    ok(e ~= nil and e.kind == 'yubikey' and e.item == 'yubikey', 'a key on the ground is ordinary loot of kind yubikey')
    eq(e.prop, CT.art.keyProp, 'drawn with the art block\'s placeholder prop')
    eq(BR.LootLabel(e), COPY.key_label, 'and named on its plate with the copy block\'s key_label')

    notices = {}
    claim(2, e.id)
    eq(m.loot.items[e.id] ~= nil, true, 'a holder walking over a second key leaves it on the ground')
    local n = noticesTo(2)
    eq(n[1] and noticeText(n[1]), COPY.already_holding, 'and is told already_holding')
    eq(#writes, 0, 'and nothing is written')

    notices, writes = {}, {}
    claim(1, e.id)
    eq(m.loot.items[e.id], nil, 'a player with no key picks it up: the entry is retired')
    eq(Y.holds(1), true, 'and holds it')
    ok(#writes == 1 and writes[1].lic == LIC[1] and writes[1].held == true,
        'one profile write: yubikey = 1 for that license', #writes)
    n = noticesTo(1)
    eq(n[1] and noticeText(n[1]), COPY.first_pickup, 'the first key ever explains itself (first_pickup)')
    ok(#eventsOf(BR.Net.LOOT_PICKUP_CUE, 1) == 1, 'with the pickup sound every item makes')
    ok(lastOf(BR.Net.YUBIKEY_STATE, 1).held == true, 'and the HUD hears it holds one')

    -- Spent, then a second one found: the line is not said again, ever.
    Y.take(1, 'used')
    notices = {}
    local e2 = Y.dropAt(m, C0.x + 0.5, C0.y, 30.0)
    claim(1, e2.id)
    eq(Y.holds(1), true, 'a later key is picked up')
    eq(#noticesTo(1), 0, 'and the first-pickup line is not shown a second time')

    -- And the flag came off the profile: a player whose row says seen is never told.
    reset()
    local m3 = newMatch(3)
    player(5, m3, nil, C0, false, true)
    local e3 = Y.dropAt(m3, C0.x + 0.5, C0.y, 30.0)
    claim(5, e3.id)
    eq(#noticesTo(5), 0, 'a profile whose yubikeySeen is set is not told on its first pickup this session')
end

describe('the key: a pickup before the profile is read waits, silently')
do
    reset()
    local m = newMatch(1)
    roster[9] = { src = 9, name = 'p9', state = BR.PlayerState.ALIVE, matchId = 1,
                  pos = { x = C0.x, y = C0.y, z = 30.0 } }
    m.loot.subs[9] = { [BR.LootCellKeyAt(C0.x, C0.y)] = true }
    local e = Y.dropAt(m, C0.x + 0.5, C0.y, 30.0)
    notices = {}
    claim(9, e.id)
    ok(m.loot.items[e.id] ~= nil, 'the key stays on the ground')
    eq(#noticesTo(9), 0, 'and nothing is said -- the player cannot yet be known not to hold one')
end

describe('the key: it drops where its holder dies, as a standard pickup')
do
    reset()
    local m = newMatch(1)
    player(1, m, nil, { x = C0.x + 20.0, y = C0.y - 5.0, z = 31.0 }, true, true)
    Y.onEliminated(m, 1, 'shot')
    eq(Y.holds(1), false, 'the dead player holds no key')
    ok(#writes == 1 and writes[1].held == false, 'the profile row is written yubikey = 0')
    local g = groundKeys(m)
    ok(#g == 1 and g[1].x == C0.x + 20.0 and g[1].y == C0.y - 5.0, 'and one key lies where they stood', #g)
    eq(g[1] and g[1].pz, 31.0, 'vouched by the ground their ped stood on')
    local add = lastOf(BR.Net.LOOT_ADD, 1)
    ok(add and add[1] and add[1].kind == 'yubikey', 'announced to everyone looking at that cell, like any loot')

    -- A killer picks it up.
    player(2, m, nil, { x = C0.x + 20.0, y = C0.y - 5.0, z = 31.0 }, false, true)
    claim(2, g[1].id)
    eq(Y.holds(2), true, 'whoever walks over it takes it')

    -- A player with no key dies: nothing drops.
    local before = #groundKeys(m)
    player(3, m, nil, C0, false, false)
    Y.onEliminated(m, 3, 'shot')
    eq(#groundKeys(m), before, 'a player with no key drops none')
end

describe('the key: leaving alive drops it too, while leaveDrops says so')
do
    reset()
    local m = newMatch(1)
    player(1, m, nil, C0, true, true)
    Y.onEliminated(m, 1, 'left')
    eq(#groundKeys(m), 1, 'walking out mid-match (eliminate \'left\') drops it, by default')
    eq(Y.holds(1), false, 'and the leaver does not keep it')

    -- The disconnect: BR.Roster.remove hands the entry over before it goes.
    player(2, m, nil, C0, true, true)
    Y.leaving('2', roster[2])
    eq(#groundKeys(m), 2, 'a disconnect mid-fight drops it where they stood (source arrives as a string)')
    eq(Y.holds(2), false, 'and it is not theirs any more')

    -- Not from the warmup pad, not once already out.
    player(3, m, nil, C0, true, true)
    roster[3].state = BR.PlayerState.WARMUP
    Y.leaving(3, roster[3])
    eq(Y.holds(3), true, 'a player leaving from warmup keeps it -- the match had not started')
    roster[3].state = BR.PlayerState.OUT
    Y.leaving(3, roster[3])
    eq(Y.holds(3), true, 'nor does a player already out drop anything on leaving')

    -- THE SWITCH: false lets a leaver keep it.
    CT.leaveDrops = false
    player(4, m, nil, C0, true, true)
    Y.onEliminated(m, 4, 'left')
    Y.leaving(4, roster[4])
    eq(Y.holds(4), true, 'with leaveDrops = false, a leaver keeps the key')
    Y.onEliminated(m, 4, 'shot')
    eq(Y.holds(4), false, 'but a death still drops it')
    CT.leaveDrops = true
end

describe('the key: profile writes are a log line when they fail, never a refusal')
do
    reset()
    local m = newMatch(1)
    player(1, m, nil, C0, false, false)
    resources.br_ddb = 'stopped'
    local ok1 = Y.give(1, 'pickup')
    eq(ok1, true, 'with br_ddb down the pickup still happens')
    eq(#writes, 0, 'nothing is sent to a resource that is not there')
    ok(said('br_ddb is not started'), 'and the console says the row was not written')

    resources.br_ddb = 'started'
    logs = {}
    Y.take(1, 'used')
    local w = writes[#writes]
    fire('br:ddb:yubikeySetResult', 0, w.req, false, { error = 'boom' })
    ok(said('PROFILE WRITE FAILED'), 'a failed write is said loudly')
    eq(Y.holds(1), false, 'and the session keeps the answer it had')
end

-- ----------------------------------------------------------------- sources ---

describe('sources: 50% per airdrop, a small chance per legendary crate, at their odds')
do
    reset()
    local m = newMatch(1)
    local N = 4000
    local function rate(container)
        local hits = 0
        for i = 1, N do
            container.id = i
            if Y.extraFor(m, container) then hits = hits + 1 end
        end
        return hits / N
    end
    local air = rate({ kind = 'chest', rarity = R.LEGENDARY, airdrop = 1 })
    ok(math.abs(air - CT.sources.airdropChance) < 0.03,
        ('an airdrop holds a key about half the time (%.3f over %d)'):format(air, N), air)
    local leg = rate({ kind = 'chest', rarity = R.LEGENDARY })
    ok(math.abs(leg - CT.sources.legendaryCrateChance) < 0.015,
        ('a legendary crate holds one about %.0f%% of the time (%.3f)'):format(
            CT.sources.legendaryCrateChance * 100, leg), leg)
    eq(rate({ kind = 'chest', rarity = R.EPIC }), 0, 'an epic crate never does')
    eq(rate({ kind = 'chest', rarity = R.RARE }), 0, 'nor a rare one')
    eq(rate({ kind = 'deathbox', rarity = R.LEGENDARY }), 0, 'nor a death box')
    eq(rate({ kind = 'chest', rarity = R.LEGENDARY, warmup = true }), 0,
        'nor anything on the warmup pad')

    -- Replayable: the same seed and the same container give the same answer.
    local c = { kind = 'chest', rarity = R.LEGENDARY, airdrop = 1, id = 17 }
    eq(Y.extraFor(m, c) ~= nil, Y.extraFor(m, c) ~= nil, 'the roll replays from the layout seed')

    -- The chances are config.
    CT.sources.airdropChance = 0
    eq(rate({ kind = 'chest', rarity = R.LEGENDARY, airdrop = 1 }), 0, 'airdropChance 0 is never')
    CT.sources.airdropChance = 1
    eq(rate({ kind = 'chest', rarity = R.LEGENDARY, airdrop = 1 }), 1, 'and 1 is always')
    CT.sources.airdropChance = 0.5
end

describe('sources: an EXTRA item -- the box\'s own contents do not move')
do
    -- The same legendary crate opened on Season 1 and on Season 2 with the
    -- crate chance forced to always: Season 2 spills exactly Season 1's items,
    -- in the same order, plus one key.
    local function spill(seasonN)
        reset()
        season(seasonN)
        local m = newMatch(1)
        player(1, m, nil, C0, false, false)
        local stack = BR.WarmupCrateStack(BR.Rng(5 * 31 + 7),
            { x = C0.x, y = C0.y, z = 30.0, heading = 90.0, rarity = R.LEGENDARY })
        local crate = BR.Loot.spawnStack(m, stack, C0.x + 0.5, C0.y, 30.0)
        sent = {}
        claim(1, crate.id)
        local items = {}
        for _, s in ipairs(eventsOf(BR.Net.LOOT_ADD)) do
            for _, w in ipairs(s.payload) do
                if w.kind ~= 'husk' and w.id ~= crate.id then items[#items + 1] = w.item end
            end
        end
        return items
    end
    CT.sources.legendaryCrateChance = 1
    local s1 = spill(1)
    local s2 = spill(2)
    CT.sources.legendaryCrateChance = 0.05
    season(2)
    ok(#s1 > 0, 'the crate holds something', #s1)
    eq(#s2, #s1 + 1, 'Season 2 spills one item more')
    local same = true
    for i = 1, #s1 do if s1[i] ~= s2[i] then same = false end end
    ok(same, 'and every other item is the same item in the same place in the list')
    eq(s2[#s2], 'yubikey', 'the extra one is the key')
end

describe('sources: the airdrop, through the real open')
do
    reset()
    local m = newMatch(1)
    player(1, m, nil, C0, false, false)
    CT.sources.airdropChance = 1
    local crate = BR.Loot.spawnStack(m, {
        item = 'airdrop', kind = 'chest', rarity = R.LEGENDARY, count = 1,
        prop = 'x', contents = { { item = 'volts', kind = 'volts', rarity = R.LEGENDARY, count = 500 } },
        airdrop = 3,
    }, C0.x + 0.5, C0.y, 30.0)
    claim(1, crate.id)
    CT.sources.airdropChance = 0.5
    eq(#groundKeys(m), 1, 'an airdrop that rolls a key bursts it out with the rest')
end

-- --------------------------------------------------------------- terminals ---

describe('terminals: online only inside the storm\'s current zone')
do
    reset()
    local m = newMatch(1)
    eq(T.online(T.site('tower'), m, gameMs), true, 'a terminal inside the zone is online')
    eq(T.online(T.site('shack'), m, gameMs), false, 'one 6 km outside it is offline')
    eq(T.online(T.site('shack'), { storm = nil }, gameMs), true,
        'before there is a storm everything is inside it')
    -- The wall closes past the terminal: a record whose current zone excludes it.
    m.storm = BR.BuildStormRecord(8, C0.x + 3000.0, C0.y, 50.0, C0.x + 3000.0, C0.y, 0.0,
        gameMs, 600000, 60000, 6.7, 4242)
    eq(T.online(T.site('tower'), m, gameMs), false, 'once the zone has moved off it, the same terminal is offline')
    eq(T.online(nil, m, gameMs), false, 'no terminal is never online')
end

describe('terminals: a use, access, a run -- the key and the squad\'s one use spent, the lobby told twice')
do
    reset()
    local m = newMatch(1)
    local other = newMatch(2)
    player(1, m, 'A', NEAR_SITE, true, true)          -- the holder
    player(2, m, 'A', { x = 5000, y = 5000 }, false, false)   -- squadmate, far away
    player(3, m, 'B', { x = 5100, y = 5000 }, false, false)   -- another squad, same match
    player(4, other, nil, { x = 9000, y = 9000 }, false, false) -- another match
    roster[2].state = BR.PlayerState.OUT                          -- dead, spectating

    fire(BR.Net.TERMINAL_USE, 1, { terminalId = 'tower' })
    local open = lastOf(BR.Net.TERMINAL_OPEN, 1)
    ok(open and open.state.terminalId == 'tower' and open.state.keyHeld == true
        and open.state.squadUsed == false, 'the holder at a live terminal gets the computer, key held')
    local f = open and fnOf(open.state, 'storm_reveal')
    ok(f and f.id == 'storm_reveal' and f.available == true, 'Storm reveal is available')

    local n1 = noticesTo(3)
    eq(#n1, 1, 'the lobby is told someone gained access: another squad in the match hears it')
    eq(#noticesTo(2), 1, 'so does the holder\'s dead squadmate')
    eq(#noticesTo(4), 0, 'and nobody in another match does')
    local t1 = n1[1] and n1[1].text
    ok(type(t1) == 'table' and t1.parts ~= nil, 'the name travels as its own bold piece (BR.Notice.who)')
    local named = false
    for _, p in ipairs(type(t1) == 'table' and t1.parts or {}) do if p.b == 'p1' then named = true end end
    ok(named, 'and it is the holder\'s name')

    gameMs = gameMs + 1000
    fire(BR.Net.TERMINAL_USE, 1, { terminalId = 'tower' })
    eq(#noticesTo(3), 1, 'opening the same computer again is not a second access notice')

    gameMs = gameMs + 1000
    writes = {}
    fire(BR.Net.TERMINAL_RUN, 1, { terminalId = 'tower', functionId = 'storm_reveal' })
    local r = lastOf(BR.Net.TERMINAL_RESULT, 1)
    ok(r and r.ok == true and r.code == 'running', 'the run is accepted, and loads', r and r.code)
    eq(#noticesTo(3), 1, 'nobody hears it ran while it loads')
    flush()
    r = lastOf(BR.Net.TERMINAL_RESULT, 1)
    ok(r and r.ok == true and r.code == 'done', 'then it is answered done', r and r.code)
    eq(Y.holds(1), false, 'the key is spent')
    ok(#writes == 1 and writes[1].held == false, 'and the profile row says so')
    eq(T.squadUsed(1), true, 'the squad\'s one use is spent')
    eq(T.squadUsed(2), true, 'for every member of the squad')
    eq(T.squadUsed(3), false, 'and not for anyone else\'s')
    ok(r and r.state.squadUsed == true and fnOf(r.state, 'storm_reveal').reason == 'squad_used',
        'the answer already lists it as used')

    local n2 = noticesTo(3)
    eq(#n2, 2, 'the lobby is told a second time, when the action ran')
    eq(n2[2] and noticeText(n2[2]),
        noticeText({ text = BR.TerminalSolve.line(COPY.notice_action, 'p1', COPY.storm_reveal_description) }),
        'with notice_action, the name and the function\'s description filled in')

    -- STORM REVEAL: to the squad, the dead mate included, and nobody else.
    local rv1, rv2 = lastOf(BR.Net.TERMINAL_REVEAL, 1), lastOf(BR.Net.TERMINAL_REVEAL, 2)
    ok(rv1 and rv1.x == 1111.0 and rv1.y == -2222.0, 'the runner is shown where the storm ends')
    ok(rv2 and rv2.x == 1111.0 and rv2.matchId == 1, 'and so is their squadmate')
    eq(#eventsOf(BR.Net.TERMINAL_REVEAL, 3), 0, 'another squad in the same match is not')
    eq(#eventsOf(BR.Net.TERMINAL_REVEAL, 4), 0, 'nor anyone in another match')

    -- The squad's members are told their use is gone (their plates change).
    ok(lastOf(BR.Net.YUBIKEY_STATE, 2) and lastOf(BR.Net.YUBIKEY_STATE, 2).squadUsed == true,
        'the squadmate hears the squad has used its one')

    -- br:ready sends the reveal again, to the squad alone.
    sent = {}
    fire(BR.Net.READY, 2)
    ok(lastOf(BR.Net.TERMINAL_REVEAL, 2) ~= nil, 'a squadmate whose client restarts is sent the reveal again')
    fire(BR.Net.READY, 3)
    eq(#eventsOf(BR.Net.TERMINAL_REVEAL, 3), 0, 'another squad asking is sent nothing')
end

describe('terminals: ONE use per squad per match -- the squad\'s other holders are refused')
do
    reset()
    local m = newMatch(1)
    player(1, m, 'A', NEAR_SITE, true, true)
    player(2, m, 'A', NEAR_SITE, true, true)
    player(3, m, 'B', NEAR_SITE, true, true)
    player(4, m, nil, NEAR_SITE, true, true)
    player(5, m, nil, NEAR_SITE, true, true)

    fire(BR.Net.TERMINAL_USE, 1, { terminalId = 'tower' })
    gameMs = gameMs + 1000
    fire(BR.Net.TERMINAL_RUN, 1, { terminalId = 'tower', functionId = 'storm_reveal' })
    ok(lastOf(BR.Net.TERMINAL_RESULT, 1).ok == true, 'the first holder in squad A runs it')

    notices = {}
    fire(BR.Net.TERMINAL_USE, 2, { terminalId = 'tower' })
    local st = lastOf(BR.Net.TERMINAL_OPEN, 2).state
    ok(st.keyHeld == true and st.squadUsed == true and fnOf(st, 'storm_reveal').reason == 'squad_used',
        'the second holder in squad A opens it and every function is squad_used')
    eq(#notices, 0, 'and nobody is told they gained access -- they did not')
    gameMs = gameMs + 1000
    fire(BR.Net.TERMINAL_RUN, 2, { terminalId = 'tower', functionId = 'storm_reveal' })
    local r = lastOf(BR.Net.TERMINAL_RESULT, 2)
    ok(r.ok == false and r.code == 'squad_used', 'and a run is refused squad_used', r.code)
    eq(Y.holds(2), true, 'their key is kept: refused is not spent')

    fire(BR.Net.TERMINAL_USE, 3, { terminalId = 'tower' })
    gameMs = gameMs + 1000
    fire(BR.Net.TERMINAL_RUN, 3, { terminalId = 'tower', functionId = 'storm_reveal' })
    ok(lastOf(BR.Net.TERMINAL_RESULT, 3).ok == true, 'squad B has its own use')

    fire(BR.Net.TERMINAL_USE, 4, { terminalId = 'tower' })
    gameMs = gameMs + 1000
    fire(BR.Net.TERMINAL_RUN, 4, { terminalId = 'tower', functionId = 'storm_reveal' })
    ok(lastOf(BR.Net.TERMINAL_RESULT, 4).ok == true, 'a solo player is a squad of one')
    fire(BR.Net.TERMINAL_USE, 5, { terminalId = 'tower' })
    gameMs = gameMs + 1000
    fire(BR.Net.TERMINAL_RUN, 5, { terminalId = 'tower', functionId = 'storm_reveal' })
    ok(lastOf(BR.Net.TERMINAL_RESULT, 5).ok == true, 'and another solo player is another squad of one')

    -- A NEW MATCH IS A NEW USE.
    local m2 = newMatch(2)
    roster[2].matchId = m2.id
    eq(T.squadUsed(2), false, 'in the next match the squad\'s use is unspent again')
end

describe('round 2: a key given back by the account, and the squad match on the push')
do
    reset()
    local m = newMatch(1)
    player(1, m, 'A', NEAR_SITE, true, true)
    eq(Y.licenseOf(1), 'license:1', 'the account a key is held under')
    ok(Y.take(1, 'used'), 'a run takes the key')
    writes = {}
    ok(Y.restore('license:1', 'refund') == true, 'and a refund gives it back, by the account')
    eq(Y.holds(1), true, 'held again')
    ok(#writes == 1 and writes[1].held == true and writes[1].lic == 'license:1', 'the profile row is written')
    local st = lastOf(BR.Net.YUBIKEY_STATE, 1)
    ok(st and st.held == true, 'and the player is told')
    eq(Y.restore('license:1', 'refund'), false, 'never a second key: the cap of one stands')
    eq(Y.restore('license:404', 'refund'), false, 'nor a key for an account this session never read')

    -- Gone from the server: the account's entry outlives the source.
    Y.take(1, 'used')
    fire('playerDropped', 1)
    roster[1] = nil
    ok(Y.restore('license:1', 'refund') == true, 'a player who left is given it back on the row')

    -- The push says whether this is a squad match (the plate's line).
    reset()
    m = newMatch(1)
    player(1, m, 'A', NEAR_SITE, true, true)
    Y.push(1)
    eq(lastOf(BR.Net.YUBIKEY_STATE, 1).squadMatch, true, 'a squad match, playing: squadMatch')
    m.mode = 'solo'
    Y.push(1)
    eq(lastOf(BR.Net.YUBIKEY_STATE, 1).squadMatch, false, 'a solo match: not')
    m.mode = 'squad'
    m.state = BR.MatchState.WARMUP
    Y.push(1)
    eq(lastOf(BR.Net.YUBIKEY_STATE, 1).squadMatch, false, 'in a squad match, at warmup: not yet')
end

describe('terminals: no key -- the computer opens and nothing can run')
do
    reset()
    local m = newMatch(1)
    player(1, m, nil, NEAR_SITE, false, false)
    fire(BR.Net.TERMINAL_USE, 1, { terminalId = 'tower' })
    local st = lastOf(BR.Net.TERMINAL_OPEN, 1).state
    ok(st.keyHeld == false and fnOf(st, 'storm_reveal').reason == 'no_key',
        'without a key it opens, every function no_key')
    eq(#notices, 0, 'and nobody is told anything')
    gameMs = gameMs + 1000
    fire(BR.Net.TERMINAL_RUN, 1, { terminalId = 'tower', functionId = 'storm_reveal' })
    local r = lastOf(BR.Net.TERMINAL_RESULT, 1)
    ok(r.ok == false and r.code == 'no_key', 'a run is refused no_key')
    eq(#eventsOf(BR.Net.TERMINAL_REVEAL), 0, 'and nothing is revealed')
end

describe('terminals: a use is only taken from a living player at a live terminal in a live match')
do
    reset()
    local m = newMatch(1)
    player(1, m, nil, FAR_SITE, true, true)
    notices = {}
    fire(BR.Net.TERMINAL_USE, 1, { terminalId = 'shack' })
    eq(#eventsOf(BR.Net.TERMINAL_OPEN, 1), 0, 'a terminal outside the storm does not open')
    eq(noticesTo(1)[1] and noticeText(noticesTo(1)[1]), COPY.offline, 'and the player is told offline')

    gameMs = gameMs + 1000
    player(2, m, nil, { x = NEAR_SITE.x + 30.0, y = NEAR_SITE.y }, true, true)
    fire(BR.Net.TERMINAL_USE, 2, { terminalId = 'tower' })
    eq(#eventsOf(BR.Net.TERMINAL_OPEN, 2), 0, 'thirty metres away is not at the terminal (the server\'s own sample)')

    player(3, m, nil, NEAR_SITE, true, true)
    roster[3].state = BR.PlayerState.DBNO
    fire(BR.Net.TERMINAL_USE, 3, { terminalId = 'tower' })
    eq(#eventsOf(BR.Net.TERMINAL_OPEN, 3), 0, 'a downed player cannot use one')

    player(4, m, nil, NEAR_SITE, true, true)
    m.state = BR.MatchState.ENDED
    fire(BR.Net.TERMINAL_USE, 4, { terminalId = 'tower' })
    eq(#eventsOf(BR.Net.TERMINAL_OPEN, 4), 0, 'nor anyone once the match has ended')
    m.state = BR.MatchState.PLAYING

    fire(BR.Net.TERMINAL_USE, 4, { terminalId = 'nowhere' })
    eq(#eventsOf(BR.Net.TERMINAL_OPEN, 4), 0, 'a terminal that does not exist opens nothing')
    fire(BR.Net.TERMINAL_USE, 4, { terminalId = 'Tower!' })
    fire(BR.Net.TERMINAL_USE, 4, 'tower')
    eq(#eventsOf(BR.Net.TERMINAL_OPEN, 4), 0, 'nor a malformed request')

    gameMs = gameMs + 1000
    fire(BR.Net.TERMINAL_USE, 4, { terminalId = 'tower' })
    eq(#eventsOf(BR.Net.TERMINAL_OPEN, 4), 1, 'the same player, at the terminal, in the live match: it opens')
    fire(BR.Net.TERMINAL_USE, 4, { terminalId = 'tower' })
    eq(#eventsOf(BR.Net.TERMINAL_OPEN, 4), 1, 'and a second use inside the interval is dropped')
end

describe('terminals: the session closes when its player dies, walks off, or the storm takes it')
do
    reset()
    local m = newMatch(1)
    player(1, m, nil, NEAR_SITE, true, true)
    player(2, m, nil, NEAR_SITE, true, true)
    player(3, m, nil, NEAR_SITE, true, true)
    player(4, m, nil, NEAR_SITE, true, true)
    for s = 1, 4 do fire(BR.Net.TERMINAL_USE, s, { terminalId = 'tower' }) end
    ok(jobs['terminal.sessions'] ~= nil, 'a session check is on the scheduler')

    roster[1].state = BR.PlayerState.DBNO
    roster[2].pos = { x = NEAR_SITE.x + 50.0, y = NEAR_SITE.y, z = 30.0 }
    jobs['terminal.sessions'](500)
    eq(T.session(1), nil, 'going down closes the computer')
    eq(T.session(2), nil, 'walking away closes it')
    ok(T.session(3) ~= nil, 'a player still there keeps theirs')
    ok(lastOf(BR.Net.TERMINAL_CLOSE, 1) ~= nil, 'and the client is told')

    -- The wall closes past the terminal.
    m.storm = BR.BuildStormRecord(8, C0.x + 3000.0, C0.y, 50.0, C0.x + 3000.0, C0.y, 0.0,
        gameMs, 600000, 60000, 6.7, 4242)
    gameMs = gameMs + 1000
    fire(BR.Net.TERMINAL_RUN, 4, { terminalId = 'tower', functionId = 'storm_reveal' })
    eq(#eventsOf(BR.Net.TERMINAL_RESULT, 4), 0, 'a run after the storm took the terminal is not answered')
    eq(T.session(4), nil, 'the computer is closed instead')
    eq(Y.holds(4), true, 'and the key is not spent')
    jobs['terminal.sessions'](500)
    eq(T.session(3), nil, 'the check closes the other one too')
end

describe('terminals: Storm reveal with nothing to reveal is refused no_storm, and spends nothing')
do
    reset()
    local m = newMatch(1)
    m.finalStub = nil
    player(1, m, nil, NEAR_SITE, true, true)
    fire(BR.Net.TERMINAL_USE, 1, { terminalId = 'tower' })
    local st = lastOf(BR.Net.TERMINAL_OPEN, 1).state
    eq(fnOf(st, 'storm_reveal').reason, 'no_storm', 'listed no_storm')
    gameMs = gameMs + 1000
    fire(BR.Net.TERMINAL_RUN, 1, { terminalId = 'tower', functionId = 'storm_reveal' })
    eq(lastOf(BR.Net.TERMINAL_RESULT, 1).code, 'no_storm', 'and refused no_storm')
    eq(Y.holds(1), true, 'the key is kept')
    eq(T.squadUsed(1), false, 'and so is the squad\'s use')
end

-- --------------------------------------------------------------------- dev ---

describe('dev: bryubikey, place, online, remove, list, reset, run')
do
    reset()
    local m = newMatch(1)
    player(1, m, 'A', NEAR_SITE, false, false)
    sv(1, 'key give')
    eq(Y.holds(1), true, '`brterminalsv key give` gives the typer a key')
    ok(#writes == 1 and writes[1].held == true, 'through the real profile write')
    sv(1, 'key give')
    ok((lastOf(BR.Net.TERMINAL_DEV, 1) or ''):find('already holds', 1, true) ~= nil,
        'a second says they already hold one')
    sv(1, 'key take')
    eq(Y.holds(1), false, '`key take` takes it away')
    sv(0, 'key 1 give')
    eq(Y.holds(1), true, 'the server console names a player')

    sent = {}
    sv(1, 'place 100.5 200.25 30 45')
    local sites = lastOf(BR.Net.TERMINAL_SITES)
    ok(sites and sites.placed[1] and sites.placed[1].id == 'terminal_1'
        and sites.placed[1].x == 100.5, 'place adds a terminal and tells everyone (-1)')
    eq(eventsOf(BR.Net.TERMINAL_SITES)[1].src, -1, 'to everyone')
    local line = BR.TerminalSolve.siteLine(sites.placed[1])
    local printed = false
    for _, e in ipairs(eventsOf(BR.Net.TERMINAL_DEV, 1)) do
        if e.payload:find(line, 1, true) then printed = true end
    end
    ok(printed, 'and prints the config line to paste', line)
    ok(T.site('terminal_1') ~= nil, 'the new terminal is usable at once')
    sv(1, 'place 1 2 3 0 Bad-Id')
    ok(T.site('bad-id') == nil, 'a malformed id is refused')
    sv(1, 'place 1 2 3 0 lab')
    ok(T.site('lab') ~= nil, 'a placed terminal may be named')

    sv(1, 'online shack')
    eq(T.online(T.site('shack'), m, gameMs), true, '`online` forces a terminal outside the storm online')
    ok(lastOf(BR.Net.TERMINAL_SITES).forced[1] == 'shack', 'and every client hears it')
    sv(1, 'online shack off')
    eq(T.online(T.site('shack'), m, gameMs), false, '`online <id> off` hands it back to the storm')

    sv(1, 'remove tower')
    eq(T.site('tower'), nil, '`remove` takes a config terminal out of play')
    ok(lastOf(BR.Net.TERMINAL_SITES).removed[1] == 'tower', 'and every client hears it')
    sv(1, 'remove lab')
    eq(T.site('lab'), nil, 'and a placed one')

    logs = {}
    sv(1, 'list')
    ok(said('terminal_1') and said('shack') and not said('tower  ('), '`list` names every terminal in play')

    -- reset and run.
    sv(1, 'place ' .. NEAR_SITE.x .. ' ' .. NEAR_SITE.y .. ' 30 0 tower2')
    fire(BR.Net.TERMINAL_USE, 1, { terminalId = 'tower2' })
    gameMs = gameMs + 1000
    fire(BR.Net.TERMINAL_RUN, 1, { terminalId = 'tower2', functionId = 'storm_reveal' })
    eq(T.squadUsed(1), true, 'the squad has used its one')
    sv(1, 'reset')
    eq(T.squadUsed(1), false, '`reset` hands the squad its use back for this match')

    sent = {}
    player(2, m, 'B', { x = 0, y = 0 }, false, false)
    sv(2, 'run storm_reveal')
    ok(lastOf(BR.Net.TERMINAL_REVEAL, 2) ~= nil, '`run` runs a function with no key and no terminal')
    eq(Y.holds(2), false, 'spending nothing')
    eq(T.squadUsed(2), false, 'not even the squad\'s use')
    sv(2, 'run no_such_function')
    ok((lastOf(BR.Net.TERMINAL_DEV, 2) or ''):find('no function', 1, true) ~= nil, 'an unknown function is refused')
    sv(2, 'run disarm')
    ok((lastOf(BR.Net.TERMINAL_DEV, 2) or ''):find('not built', 1, true) ~= nil,
        'a listed function whose effect is not built says so')
    sv(2, 'run storm_reveal zone=north')
    ok((lastOf(BR.Net.TERMINAL_DEV, 2) or ''):find('does not take', 1, true) ~= nil,
        'options a function does not take are refused')
end

-- =========================================================================
-- PART B -- the client: br_core/client/yubikey.lua over modelled natives
-- =========================================================================

local function bootClient(opts)
    opts = opts or {}
    local W = {
        natives = 0, blips = {}, nextBlip = 1, objects = {}, nextObj = 1,
        server = {}, dui = {}, loops = { frame = {}, tick = {}, slow = {} },
        keys = { listeners = {}, held = {} }, ped = { x = 0, y = 0, z = 30 },
        now = 500000, season = opts.season or 2, handlers = {},
        -- The model hides: every call in order, and the live ones by place.
        hideCalls = {}, hides = {}, watchers = {},
    }
    local env = setmetatable({}, { __index = _G })
    local function n() W.natives = W.natives + 1 end
    env.print = function() end
    env.GetGameTimer = function() return W.now end
    env.GetCurrentResourceName = function() return 'br_core' end
    env.PlayerPedId = function() n() return 1 end
    env.GetEntityCoords = function() n() return { x = W.ped.x, y = W.ped.y, z = W.ped.z } end
    env.IsPedInAnyVehicle = function() n() return false end
    env.GetHashKey = function(s) n() return #tostring(s) end
    env.IsModelInCdimage = function() n() return true end
    env.RequestModel = function() n() end
    env.HasModelLoaded = function() n() return true end
    env.SetModelAsNoLongerNeeded = function() n() end
    env.CreateObjectNoOffset = function(_, x, y, z)
        n()
        local h = W.nextObj
        W.nextObj = h + 1
        W.objects[h] = { x = x, y = y, z = z }
        return h
    end
    env.SetEntityHeading = function() n() end
    env.FreezeEntityPosition = function() n() end
    env.DoesEntityExist = function(h) n() return W.objects[h] ~= nil end
    env.DeleteEntity = function(h) n() W.objects[h] = nil end
    local function hideAt(x, y, z, r, hash) return ('%.4f,%.4f,%.4f/%.2f/%s'):format(x, y, z, r, tostring(hash)) end
    env.CreateModelHideExcludingScriptObjects = function(x, y, z, r, hash, survive)
        n()
        W.hideCalls[#W.hideCalls + 1] = { op = 'hide', x = x, y = y, z = z, r = r, hash = hash, flag = survive }
        local k = hideAt(x, y, z, r, hash)
        W.hides[k] = (W.hides[k] or 0) + 1
    end
    env.CreateModelHide = function(x, y, z, r, hash, survive)
        n()
        W.hideCalls[#W.hideCalls + 1] = { op = 'hide_scripts_too', x = x, y = y, z = z, r = r, hash = hash, flag = survive }
    end
    env.RemoveModelHide = function(x, y, z, r, hash, lazy)
        n()
        W.hideCalls[#W.hideCalls + 1] = { op = 'unhide', x = x, y = y, z = z, r = r, hash = hash, flag = lazy }
        local k = hideAt(x, y, z, r, hash)
        if W.hides[k] then
            W.hides[k] = W.hides[k] > 1 and W.hides[k] - 1 or nil
        end
    end
    env.AddBlipForCoord = function(x, y)
        n()
        local h = W.nextBlip
        W.nextBlip = h + 1
        W.blips[h] = { x = x, y = y }
        return h
    end
    env.SetBlipSprite = function(b, s) n() W.blips[b].sprite = s end
    env.SetBlipColour = function(b, c) n() if W.blips[b] then W.blips[b].colour = c end end
    env.SetBlipScale = function() n() end
    env.SetBlipDisplay = function(b, d) n() W.blips[b].display = d end
    env.SetBlipAsShortRange = function() n() end
    env.DoesBlipExist = function(b) n() return W.blips[b] ~= nil end
    env.RemoveBlip = function(b) n() W.blips[b] = nil end
    env.RegisterNetEvent = function() end
    env.AddEventHandler = function(name, fn) W.handlers[name] = fn end
    env.TriggerServerEvent = function(ev, d) W.server[#W.server + 1] = { ev = ev, d = d } end

    env.BR = {}
    for _, f in ipairs({
        'br_lib/shared/enums.lua', 'br_lib/shared/protocol.lua', 'br_lib/shared/notice.lua',
        'br_lib/shared/rng.lua', 'br_lib/shared/geo.lua', 'br_lib/config/storm.lua',
        'br_lib/config/map.lua', 'br_lib/config/loot.lua', 'br_lib/config/terminals.lua',
        'br_lib/shared/storm_solve.lua', 'br_lib/shared/storm_shape.lua',
        'br_lib/shared/terminal_solve.lua',
    }) do
        local chunk = assert(loadfile(ROOT .. f, 't', env))
        chunk()
    end
    local B = env.BR
    B.Config.Terminals.sites = opts.sites or {}
    B.Season = {
        has = function(id) return id == 'terminals' and W.season >= 2 end,
        onChange = function(fn) W.watchers[#W.watchers + 1] = fn end,
    }
    B.Clock = { now = function() return W.now end }
    B.State = {
        match = { state = B.MatchState.PLAYING },
        me = { state = B.PlayerState.ALIVE },
        storm = opts.storm,
    }
    B.Loop = {
        FRAME = 'frame', TICK = 'tick', SLOW = 'slow',
        register = function(band, name, fn) W.loops[band][name] = fn end,
    }
    B.Keys = {
        uiScreen = nil,
        on = function(a, fn) W.keys.listeners[a] = fn end,
        isHeld = function(a) return W.keys.held[a] == true end,
    }
    B.Dui = {
        page = function() return 'page' end,
        send = function(_, msg) W.dui[#W.dui + 1] = msg end,
        drawWorld = function() n() end,
    }
    B.Native = {
        blipName = function() n() end,
        radiusBlip = function(_, x, y, r, colour)
            n()
            local h = W.nextBlip
            W.nextBlip = h + 1
            W.blips[h] = { x = x, y = y, radius = r, colour = colour }
            return h
        end,
        keyLabelForCommand = function() return 'E' end,
    }
    B.Terminal = { computerOpen = function() return W.computer == true end }
    local chunk = assert(loadfile(ROOT .. 'br_core/client/yubikey.lua', 't', env))
    chunk()
    W.env, W.B = env, B
    function W.slow() W.loops.slow['terminals.world']() end
    function W.tick() W.loops.tick['terminals.near']() end
    function W.frame() W.loops.frame['terminals.plate']() end
    function W.net(ev, d) W.handlers[ev](d) end
    function W.spriteBlips(sprite)
        local c = 0
        for _, b in pairs(W.blips) do if b.sprite == sprite then c = c + 1 end end
        return c
    end
    function W.lastPrompt() return W.dui[#W.dui] end
    --- The season moves, and the latch says so (BR.Season.onChange).
    function W.switch(season)
        local before = W.season
        W.season = season
        for _, fn in ipairs(W.watchers) do fn(season, before) end
    end
    --- How many hides are live, and the hide calls made after the first `from`.
    function W.hidden()
        local c = 0
        for _, v in pairs(W.hides) do c = c + v end
        return c
    end
    function W.callsSince(from)
        local out = {}
        for i = from + 1, #W.hideCalls do out[#out + 1] = W.hideCalls[i] end
        return out
    end
    return W
end

local SITE = { id = 'tower', x = 100.0, y = 200.0, z = 30.0, h = 0.0 }

--- A storm record whose current zone holds SITE (a 1500 m zone round it), and
--- one whose zone is 3 km away and 50 m across.
local function stormAround(B, now)
    return B.BuildStormRecord(2, SITE.x, SITE.y, 1500.0, SITE.x, SITE.y, 800.0, now,
        600000, 60000, 1.0, 4242)
end
local function stormAway(B, now)
    return B.BuildStormRecord(8, SITE.x + 3000.0, SITE.y, 50.0, SITE.x + 3000.0, SITE.y, 0.0,
        now, 600000, 60000, 6.7, 4242)
end

describe('client: with no terminal anywhere, nothing costs a native')
do
    local W = bootClient({ sites = {} })
    W.natives = 0
    for _ = 1, 10 do W.frame() W.tick() end
    W.slow()
    eq(W.natives, 0, 'a frame, a tick and a pass with no terminal call no native')
    W = bootClient({ sites = { SITE } })
    W.ped = { x = 5000, y = 5000, z = 30 }
    W.slow()
    W.tick()
    W.natives = 0
    for _ = 1, 60 do W.frame() end
    eq(W.natives, 0, 'and with terminals but none in reach, the frame band calls none either')
end

describe('client: blips only while holding a key, only inside the storm, only in a match')
do
    local W = bootClient({ sites = { SITE } })
    W.B.State.storm = stormAround(W.B, W.now)
    W.ped = { x = SITE.x + 20.0, y = SITE.y, z = SITE.z }
    W.natives = 0
    W.slow()
    W.slow()
    eq(W.spriteBlips(521), 0, 'no key: no terminal blip')
    eq(W.natives, 0, 'and a pass with no key calls no native, however near the player stands')
    -- THE LAPTOP IS THE OWNER'S YMAP'S (2026-10-06): no script makes one.
    eq(next(W.objects), nil, 'no prop is made beside the player -- the ymap stands the laptop there')

    W.net(W.B.Net.YUBIKEY_STATE, { held = true, squadUsed = false })
    W.slow()
    eq(W.spriteBlips(521), 2, 'holding a key: the terminal is on both maps (one blip each)')
    local b = nil
    for _, x in pairs(W.blips) do if x.sprite == 521 then b = x end end
    eq(b and b.colour, 51, 'in the owner\'s colour 51')

    W.B.State.storm = stormAway(W.B, W.now)
    W.slow()
    eq(W.spriteBlips(521), 0, 'the storm moved past it: its blip goes')
    W.B.State.storm = stormAround(W.B, W.now)
    W.slow()
    eq(W.spriteBlips(521), 2, 'inside again: back')

    W.net(W.B.Net.YUBIKEY_STATE, { held = false, squadUsed = false })
    eq(W.spriteBlips(521), 0, 'the key spent or dropped: gone at once')

    W.net(W.B.Net.YUBIKEY_STATE, { held = true, squadUsed = false })
    W.B.State.match.state = W.B.MatchState.WAITING
    W.B.State.me.state = W.B.PlayerState.LOBBY
    W.slow()
    eq(W.spriteBlips(521), 0, 'in the lobby, a held key draws no terminal blips')
    W.B.State.match.state = W.B.MatchState.BUS
    W.B.State.me.state = W.B.PlayerState.BUS
    W.slow()
    eq(W.spriteBlips(521), 2, 'from the bus on -- "from the start" -- it does')
end

describe('client: the plate says what the player needs, and a press asks the server')
do
    local W = bootClient({ sites = { SITE } })
    W.B.State.storm = stormAround(W.B, W.now)
    W.ped = { x = SITE.x + 1.0, y = SITE.y, z = SITE.z }
    W.slow()
    W.tick()
    local p = W.lastPrompt()
    ok(p and p.show == true and p.label == COPY.terminal_label, 'in reach, the plate is up with the terminal_label title')
    eq(p and p.hint, COPY.no_key, 'without a key it says no_key -- what they need to get access')
    eq(p and p.key, 'E', 'with the interact key on it: a press still opens the computer, to its login screen')
    eq(W.B.Yubikey.prompting(), true, 'and the loot prompt is told to stand down')
    W.keys.listeners.interact(true)
    ok(#W.server == 1 and W.server[1].ev == W.B.Net.TERMINAL_USE and W.server[1].d.terminalId == 'tower',
        'no key: a press asks the server all the same (the app opens on no_key)')
    W.keys.listeners.interact(false)
    W.server = {}
    W.now = W.now + CT.runMinIntervalMs

    W.net(W.B.Net.YUBIKEY_STATE, { held = true, squadUsed = false })
    W.tick()
    p = W.lastPrompt()
    ok(p.hint == COPY.terminal_use and p.key == 'E', 'with a key: terminal_use and the player\'s own key cap')

    W.net(W.B.Net.YUBIKEY_STATE, { held = true, squadUsed = true, squadMatch = true })
    W.tick()
    eq(W.lastPrompt().hint, COPY.squad_used, 'the squad has used its one: squad_used')
    eq(W.lastPrompt().key, 'E', 'with the key cap: the press opens it the same way')
    W.keys.listeners.interact(true)
    eq(#W.server, 1, 'and asks the server')
    W.server = {}
    W.now = W.now + CT.runMinIntervalMs
    -- "SQUAD" ONLY IN A SQUAD MATCH (round 2): the plate picks its solo line.
    W.net(W.B.Net.YUBIKEY_STATE, { held = true, squadUsed = true, squadMatch = false })
    W.tick()
    eq(W.lastPrompt().hint, COPY.squad_used_solo, 'outside a squad match: its solo line, without the word')
    W.net(W.B.Net.YUBIKEY_STATE, { held = true, squadUsed = true })
    W.tick()
    eq(W.lastPrompt().hint, COPY.squad_used_solo, 'and a state that does not say is not a squad match')
    W.net(W.B.Net.YUBIKEY_STATE, { held = true, squadUsed = true, squadMatch = true })
    W.tick()

    W.net(W.B.Net.YUBIKEY_STATE, { held = true, squadUsed = false })
    W.B.State.storm = stormAway(W.B, W.now)
    W.slow()
    W.tick()
    p = W.lastPrompt()
    ok(p.hint == COPY.offline and p.key == nil, 'outside the storm: offline, and no key cap -- nothing to press')
    W.keys.listeners.interact(true)
    eq(#W.server, 0, 'and a press there asks nothing')

    -- THE PRESS (owner, 2026-10-06: '"Computer system" "press to open" with
    -- the interact key on it'; it was an 800 ms hold).
    W.B.State.storm = stormAround(W.B, W.now)
    W.slow()
    W.tick()
    p = W.lastPrompt()
    ok(p.label == 'Computer system' and p.hint == 'press to open',
        'with a key at a live terminal: "Computer system", "press to open" -- the owner\'s words')
    eq(p.key, 'E', 'with the player\'s own interact key on it')
    ok(not p.ring and p.holdMs == nil, 'and no ring, no hold time: nothing is held')
    W.keys.listeners.interact(true)
    ok(#W.server == 1 and W.server[1].ev == W.B.Net.TERMINAL_USE and W.server[1].d.terminalId == 'tower',
        'one press: the server is asked to open this terminal, at once')
    eq(W.lastPrompt().ring, nil, 'and the plate never turns into a ring')
    W.keys.listeners.interact(false)
    W.tick()
    eq(#W.server, 1, 'the release asks nothing')
    W.now = W.now + CT.runMinIntervalMs - 1
    W.keys.listeners.interact(true)
    eq(#W.server, 1, 'a press inside the anti-spam interval asks nothing (the server would drop it)')
    W.now = W.now + 1
    W.keys.listeners.interact(true)
    eq(#W.server, 2, 'one after it asks again -- the server decides whether anything opens')
    W.now = W.now + CT.runMinIntervalMs
    W.B.Keys.uiScreen = 'map'
    W.keys.listeners.interact(true)
    eq(#W.server, 2, 'not while a br_ui screen holds the keyboard')
    W.B.Keys.uiScreen = nil
    W.keys.held.interact = true
    for _ = 1, 30 do
        W.now = W.now + 100
        W.tick()
    end
    eq(#W.server, 2, 'and holding the key down asks nothing more: only a press asks')
    W.keys.held.interact = false

    W.ped = { x = SITE.x + 40.0, y = SITE.y, z = SITE.z }
    W.tick()
    eq(W.lastPrompt().show, false, 'walking away takes the plate down')
    eq(W.B.Yubikey.prompting(), false, 'and hands the loot prompt back')

    -- Not while the computer is up, and not while downed.
    W.ped = { x = SITE.x + 1.0, y = SITE.y, z = SITE.z }
    W.tick()
    ok(W.B.Yubikey.prompting(), 'back in reach: the plate is up')
    -- The computer opening between two ticks: the plate is still drawn, and a
    -- press then must not ask the server to open it a second time.
    W.computer = true
    W.now = W.now + CT.runMinIntervalMs
    local before = #W.server
    W.keys.listeners.interact(true)
    eq(#W.server, before, 'a press as the computer comes up, before the plate goes, asks nothing')
    W.tick()
    eq(W.B.Yubikey.prompting(), false, 'no plate while the computer is open')
    W.now = W.now + CT.runMinIntervalMs
    W.keys.listeners.interact(true)
    eq(#W.server, before, 'and no press asks while it is')
    W.computer = false
    W.B.State.me.state = W.B.PlayerState.DBNO
    W.tick()
    eq(W.B.Yubikey.prompting(), false, 'nor while downed')
end

describe('a press, end to end: the client asks, and the server\'s door decides as it always did')
do
    -- The client's own request, carried to the real server/terminal.lua: the
    -- press replaced the hold, and nothing the server checks moved.
    local W = bootClient({ sites = { NEAR_SITE } })
    W.B.State.storm = stormAround(W.B, W.now)
    W.ped = { x = NEAR_SITE.x + 1.0, y = NEAR_SITE.y, z = NEAR_SITE.z }
    W.net(W.B.Net.YUBIKEY_STATE, { held = true, squadUsed = false })
    W.slow()
    W.tick()
    W.keys.listeners.interact(true)
    local ask = W.server[1] or { d = {} }
    ok(ask.ev == BR.Net.TERMINAL_USE and ask.d.terminalId == 'tower', 'the press sends TERMINAL_USE for this terminal')

    reset()
    -- The dev tests above took 'tower' out of play for this server session;
    -- the dev tool's place puts it back where it stood.
    sv(1, ('place %s %s %s 0 tower'):format(NEAR_SITE.x, NEAR_SITE.y, NEAR_SITE.z))
    local m = newMatch(1)
    player(1, m, nil, NEAR_SITE, true, true)
    fire(BR.Net.TERMINAL_USE, 1, ask.d)
    eq(#eventsOf(BR.Net.TERMINAL_OPEN, 1), 1, 'at the terminal, alive, in a live match, with a key: it opens')
    fire(BR.Net.TERMINAL_USE, 1, ask.d)
    eq(#eventsOf(BR.Net.TERMINAL_OPEN, 1), 1, 'the same request again inside the interval: dropped')

    -- What the server sees, not what the client says.
    gameMs = gameMs + 1000
    player(2, m, nil, { x = NEAR_SITE.x + 30.0, y = NEAR_SITE.y }, true, true)
    fire(BR.Net.TERMINAL_USE, 2, ask.d)
    eq(#eventsOf(BR.Net.TERMINAL_OPEN, 2), 0, 'a press the server places thirty meters away opens nothing')
    player(3, m, nil, NEAR_SITE, true, true)
    roster[3].state = BR.PlayerState.DBNO
    fire(BR.Net.TERMINAL_USE, 3, ask.d)
    eq(#eventsOf(BR.Net.TERMINAL_OPEN, 3), 0, 'nor one from a downed player')
    season(1)
    player(4, m, nil, NEAR_SITE, true, true)
    fire(BR.Net.TERMINAL_USE, 4, ask.d)
    eq(#eventsOf(BR.Net.TERMINAL_OPEN, 4), 0, 'nor one on Season 1')
    season(2)
end

describe('client: Storm reveal on both maps until the lobby')
do
    local W = bootClient({ sites = {} })
    W.net(W.B.Net.TERMINAL_REVEAL, { x = 10.0, y = 20.0, r = 0.0, matchId = 3 })
    local radius, sprites = 0, 0
    for _, b in pairs(W.blips) do
        if b.radius then radius = radius + 1 end
        if b.sprite == CT.art.reveal.sprite then sprites = sprites + 1 end
    end
    eq(radius, 1, 'a radius blip round where the storm ends')
    eq(sprites, 2, 'and its sprite on each map')
    W.B.State.me.state = W.B.PlayerState.LOBBY
    W.slow()
    eq(next(W.blips), nil, 'back in the lobby, the match\'s reveal is gone')
    W.net(W.B.Net.TERMINAL_REVEAL, { x = 0 / 0, y = 20.0 })
    eq(next(W.blips), nil, 'a reveal with a broken coordinate draws nothing')
end

describe('client: the HUD glyph is the art block\'s, while holding')
do
    local W = bootClient({ sites = {} })
    eq(W.B.Yubikey.glyph(), nil, 'no key, no icon')
    W.net(W.B.Net.YUBIKEY_STATE, { held = true })
    eq(W.B.Yubikey.glyph(), CT.art.hudGlyph, 'holding: the placeholder glyph')
    eq(W.B.Yubikey.mateGlyph(true), CT.art.hudGlyph, 'and a squadmate who holds one gets the same mark')
    eq(W.B.Yubikey.mateGlyph(nil), nil, 'one who does not, none')
end

-- =========================================================================
-- PART C -- Season 1 sees none of it
-- =========================================================================

describe('Season 1: no key, no source, no drop, no terminal')
do
    reset()
    season(1)
    local m = newMatch(1)
    sent = {}
    player(1, m, nil, NEAR_SITE, true, true)
    eq(Y.holds(1), false, 'a profile that holds a key holds nothing on a Season 1 server')
    eq(#eventsOf(BR.Net.YUBIKEY_STATE), 0, 'and the client is told nothing')
    eq(Y.extraFor(m, { kind = 'chest', rarity = R.LEGENDARY, airdrop = 1, id = 1 }), nil,
        'no airdrop rolls one')
    local ok2 = Y.give(1, 'pickup')
    eq(ok2, false, 'none can be given')
    Y.onEliminated(m, 1, 'shot')
    eq(#groundKeys(m), 0, 'a death drops nothing')
    eq(#writes, 0, 'and the profile row is never touched -- the key is still there for Season 2')
    fire(BR.Net.TERMINAL_USE, 1, { terminalId = 'tower' })
    eq(#eventsOf(BR.Net.TERMINAL_OPEN), 0, 'a terminal use is dropped')
    fire(BR.Net.READY, 1)
    eq(#eventsOf(BR.Net.TERMINAL_SITES), 0, 'and br:ready sends no terminals')
    season(2)
    eq(Y.holds(1), true, 'the same session switched to Season 2 finds the key where it was')

    local W = bootClient({ sites = { SITE }, season = 1 })
    W.B.State.storm = stormAround(W.B, W.now)
    W.net(W.B.Net.YUBIKEY_STATE, { held = true })
    W.ped = { x = SITE.x + 1.0, y = SITE.y, z = SITE.z }
    eq(W.hidden(), 1, 'its one native act was at start: the laptop at the row is hidden')
    W.natives = 0
    W.slow()
    W.tick()
    for _ = 1, 10 do W.frame() end
    eq(W.natives, 0, 'and past the start a Season 1 client calls no native for any of it')
    eq(next(W.blips), nil, 'draws no blip')
    eq(next(W.objects), nil, 'builds no terminal')
    eq(W.B.Yubikey.glyph(), nil, 'and shows no icon')
    W.net(W.B.Net.TERMINAL_REVEAL, { x = 1.0, y = 2.0 })
    eq(next(W.blips), nil, 'and draws no reveal')
end

describe('Season 1 hides the owner\'s laptops, and Season 2 shows them again')
do
    -- THE OWNER'S YMAP STREAMS WHATEVER THE SEASON (2026-10-06), so a client
    -- where terminals are off hides the laptop at every config row.
    local TWO = { SITE, { id = 'shack', x = -500.25, y = 800.5, z = 12.0, h = 0.0 } }
    local W = bootClient({ sites = TWO, season = 1 })
    local hash = #CT.art.terminalProp   -- the stub's GetHashKey
    eq(#W.hideCalls, 2, 'on start: one hide per row')
    local h1, h2 = W.hideCalls[1] or {}, W.hideCalls[2] or {}
    ok(h1.op == 'hide' and h2.op == 'hide',
        'each with CreateModelHideExcludingScriptObjects -- map objects only, never a script\'s')
    ok(h1.x == SITE.x and h1.y == SITE.y and h1.z == SITE.z and h2.x == TWO[2].x and h2.z == TWO[2].z,
        'at the rows themselves')
    ok(h1.r == CT.art.hideRadiusM and (h1.r or 99) <= 3.0,
        ('a small sphere, art.hideRadiusM (%s m)'):format(tostring(h1.r)))
    eq(h1.hash, hash, 'of the art block\'s terminalProp')
    eq(h1.flag, true, 'surviving a map reload: a laptop not streamed in yet is hidden when it is')

    -- NOT PER FRAME: nothing more while the season stands -- no native, and
    -- not even the hides' own walk of the rows (the terminal list itself is
    -- cached, so only a sync would read the config's rows again).
    W.natives = 0
    local TSx = W.B.TerminalSolve
    local realSites, rowReads = TSx.sites, 0
    TSx.sites = function(...)
        rowReads = rowReads + 1
        return realSites(...)
    end
    for _ = 1, 5 do W.slow() W.tick() W.frame() end
    eq(W.natives, 0, 'passes, ticks and frames on the same season call no native')
    W.slow()
    rowReads = 0
    for _ = 1, 5 do W.slow() W.tick() W.frame() end
    eq(rowReads, 0, 'and do no hide work at all: the rows are not walked again')
    TSx.sites = realSites
    W.switch(1)
    eq(#W.hideCalls, 2, 'and a season "move" to the same season makes no second hide')

    -- A LIVE `brseason 2`: the latch announces it, and the hides come off at once.
    local mark = #W.hideCalls
    W.switch(2)
    local undo = W.callsSince(mark)
    eq(#undo, 2, 'switched to Season 2: both hides come off, before any pass')
    ok(undo[1] and undo[1].op == 'unhide' and undo[2] and undo[2].op == 'unhide', 'with RemoveModelHide')
    ok(undo[1] and undo[1].flag == false and undo[2] and undo[2].flag == false,
        'not lazily: the laptops come back now')
    eq(W.hidden(), 0, 'each removal names exactly the hide that was made')
    W.slow()
    eq(#W.hideCalls, mark + 2, 'and the pass after it has nothing to do')

    -- And back to Season 1.
    W.switch(1)
    eq(W.hidden(), 2, '`brseason 1`: hidden again')
    eq(#W.hideCalls, mark + 4, 'one hide each, made once')

    -- A MOVE THE LATCH DID NOT ANNOUNCE: the SLOW pass's own refresh.
    W.season = 2
    W.slow()
    eq(W.hidden(), 0, 'a season that moved unannounced: the next pass takes the hides down')
    W.season = 1
    W.slow()
    eq(W.hidden(), 2, 'and puts them back')

    -- THE DEV TOOL'S CHANGES ARE NOT THE LAPTOPS': on a Season 1 box a removed
    -- or placed terminal leaves the ymap's laptops hidden where they stand.
    mark = #W.hideCalls
    W.net(W.B.Net.TERMINAL_SITES, { placed = { { id = 'dev1', x = 1.0, y = 2.0, z = 3.0 } },
                                     removed = { 'tower' }, forced = {} })
    W.slow()
    eq(#W.hideCalls, mark, 'a dev change touches no hide')
    eq(W.hidden(), 2, 'both laptops stay hidden')

    -- The resource stopping takes every hide down; a restart makes them again.
    W.handlers.onResourceStop('br_ui')
    eq(W.hidden(), 2, 'another resource stopping changes nothing')
    W.handlers.onResourceStop('br_core')
    eq(W.hidden(), 0, 'br_core stopping removes every hide it made')

    -- A SEASON 2 CLIENT HIDES NOTHING until it is switched.
    local V = bootClient({ sites = TWO, season = 2 })
    eq(#V.hideCalls, 0, 'a Season 2 client makes no hide')
    V.switch(1)
    eq(V.hidden(), 2, 'until `brseason 1`')
    local scriptsToo = 0
    for _, c in ipairs(V.hideCalls) do
        if c.op == 'hide_scripts_too' then scriptsToo = scriptsToo + 1 end
    end
    eq(scriptsToo, 0, 'never CreateModelHide, which would hide a script\'s laptop too')

    -- THE OWNER'S FIFTEEN, at Season 1: one hide each, at his rows.
    local U = bootClient({ sites = OWNER_SITES, season = 1 })
    eq(U.hidden(), 15, 'the owner\'s fifteen rows: fifteen hides')
    -- THE RADIUS REACHES EVERY LAPTOP IN HIS YMAP (br_stream_s2 5ec1f721,
    -- stream/LaptopTerminals.ymap, read 2026-10-06): thirteen stand at their
    -- rows, and these two 1.6 m above theirs.
    local YMAP = {
        paleto_pd   = { -428.793182, 5963.445801, 32.129494 },
        calafia_way = { 361.209290, 4434.358887, 63.535072 },
    }
    local checked = 0
    for _, s in ipairs(OWNER_SITES or {}) do
        local m = YMAP[s.id]
        if m then
            checked = checked + 1
            local d = math.sqrt((m[1] - s.x) ^ 2 + (m[2] - s.y) ^ 2 + (m[3] - s.z) ^ 2)
            ok(d < CT.art.hideRadiusM, ('%s: its ymap laptop is %.2f m from the row, inside the %.1f m hide')
                :format(s.id, d, CT.art.hideRadiusM))
        end
    end
    eq(checked, 2, 'both offset laptops were measured')
end

-- =========================================================================
-- PART D -- the hooks, pinned by text
-- =========================================================================

describe('the hooks the rest of br_core makes')
do
    local market = readFile(ROOT .. 'br_core/server/market.lua') or ''
    ok(market:find('BR.Yubikey.loaded(src, lic, i)', 1, true) ~= nil,
        'market.lua hands the connect read to BR.Yubikey.loaded')
    ok(market:find('BR.Yubikey.adopt(src, lic)', 1, true) ~= nil,
        'and a cached reconnect to BR.Yubikey.adopt')

    local combat = readFile(ROOT .. 'br_core/server/combat.lua') or ''
    local hold = combat:find('holdForStart(src, entry, m)', 1, true)
    local box = combat:find('BR.Loot.deathBox(m, src)', 1, true)
    local drop = combat:find('BR.Yubikey.onEliminated(m, src, cause)', 1, true)
    ok(hold and box and drop and hold < box and box < drop,
        'combat.lua drops the key on the death box\'s edge, below the #144 hold')

    local roster = readFile(ROOT .. 'br_core/server/roster.lua') or ''
    local leave = roster:find('BR.Yubikey.leaving(src, entry)', 1, true)
    local left = roster:find('entry.state = BR.PlayerState.LEFT', 1, true)
    ok(leave and left and leave < left, 'roster.lua hands a disconnect over before the state changes')

    local loot = readFile(ROOT .. 'br_core/server/loot.lua') or ''
    ok(loot:find("item.kind == 'yubikey'", 1, true) ~= nil and loot:find('BR.Yubikey.claim(src)', 1, true) ~= nil,
        'loot.lua routes a yubikey claim to BR.Yubikey.claim')
    ok(loot:find('BR.Yubikey.extraFor(m, item)', 1, true) ~= nil, 'and asks for the extra key as a crate opens')

    local party = readFile(ROOT .. 'br_core/server/party.lua') or ''
    ok(party:find('yubikey = (BR.Yubikey ~= nil and BR.Yubikey.holds(src)) or nil', 1, true) ~= nil,
        'the squad beacon carries the holder bit')
    local roster2 = roster
    local pubStart = roster2:find('PUBLIC_FIELDS', 1, true)
    local pubBlock = pubStart and roster2:sub(pubStart, pubStart + 4000) or ''
    ok(not pubBlock:find('yubikey', 1, true), 'and roster.lua\'s PUBLIC_FIELDS -- the whole lobby -- does not')

    local state = readFile(ROOT .. 'br_core/client/state.lua') or ''
    ok(state:find('yubikey     = yubikey,', 1, true) ~= nil, 'the HUD envelope carries the glyph')
    ok(state:find('BR.Yubikey.mateGlyph(b and b.yubikey)', 1, true) ~= nil,
        'and the squad panel row carries the mate\'s')

    local dbno = readFile(ROOT .. 'br_core/client/dbno.lua') or ''
    ok(dbno:find('BR.Yubikey.prompting()', 1, true) ~= nil, 'dbno.lua stands the loot prompt down under a terminal plate')

    -- NO SCRIPTED LAPTOP (owner, 2026-10-06: "we don't need a script to place
    -- the props"). Code only, comments blanked: client/yubikey.lua makes,
    -- streams and deletes no object, and none of the terminal files makes one
    -- or names the laptop's model (the art block's terminalProp is the one
    -- spelling). A fixed list, not a directory walk: io.popen is cmd.exe on
    -- this box (check_notice_names.lua says why that is a gate that can pass
    -- on nothing).
    local ykey = (readFile(ROOT .. 'br_core/client/yubikey.lua') or ''):gsub('%-%-[^\n]*', '')
    ok(ykey ~= '', 'client/yubikey.lua is read')
    for _, native in ipairs({ 'CreateObject', 'CreateObjectNoOffset', 'RequestModel', 'HasModelLoaded',
                              'DeleteEntity', 'DeleteObject', 'SetEntityHeading', 'FreezeEntityPosition' }) do
        ok(not ykey:find('%f[%w_]' .. native .. '%f[^%w_]'), ('client/yubikey.lua calls no %s'):format(native))
    end
    local makers = {}
    for _, f in ipairs({ 'br_core/client/yubikey.lua', 'br_core/client/terminal.lua',
                         'br_core/client/terminalfx.lua', 'br_core/server/terminal.lua',
                         'br_core/server/terminalfx.lua', 'br_core/server/yubikey.lua' }) do
        local src = readFile(ROOT .. f)
        ok(src ~= nil, ('%s is read'):format(f))
        src = (src or ''):gsub('%-%-[^\n]*', '')
        if src:find('CreateObject', 1, true) or src:find('prop_laptop_01a', 1, true) then
            makers[#makers + 1] = f
        end
    end
    eq(table.concat(makers, ', '), '', 'no terminal file makes a laptop or names its model')
end

realPrint(('%d passed, %d failed'):format(pass, fail))
if fail > 0 then realExit(1) end
