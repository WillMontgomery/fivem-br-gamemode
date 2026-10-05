-- Season 2 crates (#395), the config and the server: the look a crate wears,
-- the festive window, and the open that plays a clip and bursts on its last
-- frame.
--
-- TWO HALVES, BOTH ON THE REAL FILES.
--
--   PART A is br_lib/config/crates.lua and br_lib/shared/crates.lua: which
--   model a look wears per tier, festive set and gift color, sealed and open;
--   that the shipped placeholders are inert; the festive window's four edges
--   and the dev switch; the server's rule that a clip plays only when the whole
--   row is real and the props' resource runs; the prompt rows.
--
--   PART B loads br_core/server/loot.lua (and server/warmupcrates.lua) against
--   a stubbed roster, scheduler and timer, and drives the claim: Season 1
--   unchanged, the stamp, the opening and its ordering, every edge the owner's
--   spec names (the opener dying or leaving, the match ending, two holds at
--   once, the airdrop, the warmup pad's cycle), a client streaming the crate in
--   during the clip and after it, the dev crate and `brfestive`.
--
-- The client half -- the model it picks, the fallback, the clip, the swap, the
-- prompt and the frame cost -- is tools/test_crates_client.lua.
--
-- Run via tools/verify.sh, or directly:  lua tools/test_crates.lua

local realPrint = print
local realExit  = os.exit

local gameMs = 1000
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

local function said(fragment)
    for _, l in ipairs(logs) do
        if l:find(fragment, 1, true) then return true end
    end
    return false
end

loadAll({
    'br_lib/shared/enums.lua',
    'br_lib/shared/protocol.lua',
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
    'br_lib/shared/season.lua',
    'br_lib/config/seasons.lua',
    'br_lib/config/crates.lua',
    'br_lib/shared/crates.lua',
    'br_lib/shared/loot_gen.lua',
})

local C = BR.Config.Crates
local R = BR.Rarity
BR.Season.strict = true

--- Put this process on a season, the way br_core's server does at start.
local function season(n)
    BR.Season.boot(function(name)
        return name == 'br_season' and tostring(n) or ''
    end, function() end)
end

--- A deep copy, so a block can rewrite the config and put it back.
local function copy(t)
    if type(t) ~= 'table' then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = copy(v) end
    return o
end

local SHIPPED = copy(C)

--- The config with REAL names in every row, which is what it will look like
--- the day the props land: `<set>_<tier>` and `<set>_<tier>_open`, the clip
--- 1200ms for shipping, 1400 for festive, 1800 for the gift boxes.
local function realNames()
    C.resource = 'br_crates'
    for t = 1, 5 do
        C.shipping[t] = { sealed = 'ship_' .. t, open = 'ship_' .. t .. '_open',
                          dict = 'anim@ship_' .. t, clip = 'open', clipMs = 1200 }
        C.festive[t]  = { sealed = 'xmas_' .. t, open = 'xmas_' .. t .. '_open',
                          dict = 'anim@xmas_' .. t, clip = 'open', clipMs = 1400 }
    end
    for _, g in ipairs(C.giftColors) do
        C.gift[g] = { sealed = 'gift_' .. g, open = 'gift_' .. g .. '_open',
                      dict = 'anim@gift_' .. g, clip = 'open', clipMs = 1800 }
    end
end

local function shipped()
    for k, v in pairs(copy(SHIPPED)) do C[k] = v end
end

--- The props' resource, as GetResourceState answers it on this box.
local resources = {}
function GetResourceState(name) return resources[name] or 'missing' end

-- =========================================================================
-- PART A -- the config and the look module
-- =========================================================================

describe('the season gate: crates2 is Season 2 content')
do
    local row = BR.Config.Seasons.features.crates2
    ok(row ~= nil, 'there is a crates2 row')
    eq(row and row.from, 2, 'and it starts at Season 2')
    season(1)
    eq(BR.Season.has('crates2'), false, 'off on a Season 1 server')
    season(2)
    eq(BR.Season.has('crates2'), true, 'on on a Season 2 server')
end

describe('the shipped config: one marked placeholder block, inert until filled')
do
    -- EVERY ROW THE OWNER HAS NOT FILLED IS A PLACEHOLDER, and a placeholder is
    -- today's crate: no model, no clip, no timed open.
    local real = nil
    for _, it in ipairs(BR.Crates.allLooks()) do
        local row = BR.Crates.row(it.look)
        ok(row ~= nil, ('%s has a row'):format(it.label))
        for _, k in ipairs({ 'sealed', 'open', 'dict', 'clip' }) do
            if row and not BR.Crates.placeholder(row[k]) then
                real = real or ('%s.%s = %s'):format(it.label, k, tostring(row[k]))
            end
        end
        ok(row and tonumber(row.clipMs) and row.clipMs > 0,
            ('%s carries a clip length the server can time'):format(it.label))
    end
    ok(real == nil, 'every shipped name is still a placeholder', real)
    eq(#BR.Crates.allLooks(), 14, 'five tiers, five festive, four gift colors')
    ok(BR.Crates.placeholder(C.resource), 'and the resource name is one too')

    resources[C.resource] = 'started'
    for _, it in ipairs(BR.Crates.allLooks()) do
        eq(BR.Crates.modelName(it.look, false), nil,
            ('%s: no sealed model while it is a placeholder'):format(it.label))
        eq(BR.Crates.openMs(it.look), nil,
            ('%s: and no timed open -- it opens at once, as today'):format(it.label))
    end
    resources[C.resource] = nil

    ok(BR.Crates.placeholder(nil) and BR.Crates.placeholder('')
        and BR.Crates.placeholder('placeholder_x') and not BR.Crates.placeholder('prop_x'),
        'a missing, empty or PLACEHOLDER-prefixed name is a placeholder; a real one is not')

    for _, k in ipairs({ 'shipping', 'gift' }) do
        local p = BR.Crates.prompt(k)
        ok(p and tonumber(p.x) and tonumber(p.y) and tonumber(p.z) and tonumber(p.rx)
            and tonumber(p.ry) and tonumber(p.rz) and tonumber(p.size) and p.size > 0,
            ('the %s prompt row has an offset, a rotation and a size'):format(k))
    end
end

describe('model choice: every tier, festive or not, sealed and open, and the gift boxes')
do
    realNames()
    for t = 1, 5 do
        for _, f in ipairs({ false, true }) do
            local set = f and 'xmas_' or 'ship_'
            local look = { t = t, f = f }
            eq(BR.Crates.modelName(look, false), set .. t,
                ('tier %d %s, sealed'):format(t, f and 'festive' or 'plain'))
            eq(BR.Crates.modelName(look, true), set .. t .. '_open',
                ('tier %d %s, open'):format(t, f and 'festive' or 'plain'))
            eq(BR.Crates.kindOf(look), 'shipping', ('tier %d wears the shipping prompt'):format(t))
        end
    end
    for _, g in ipairs(C.giftColors) do
        local look = { t = 3, f = true, g = g }
        eq(BR.Crates.modelName(look, false), 'gift_' .. g, ('the %s gift box, sealed'):format(g))
        eq(BR.Crates.modelName(look, true), 'gift_' .. g .. '_open', ('and open'):format(g))
        eq(BR.Crates.kindOf(look), 'gift', ('and it wears the gift prompt'))
    end

    -- THE LOOK RIDES THE ENTRY, and the tier is clamped to the five tapes.
    eq(BR.Crates.lookOf({}), nil, 'an entry with no stamp is the wooden crate')
    local l = BR.Crates.lookOf({ bt = 4, bf = true })
    ok(l and l.t == 4 and l.f == true and l.g == nil, 'a stamped entry reads back its look')
    eq(BR.Crates.lookOf({ bt = 9 }).t, 5, 'a tier past legendary is legendary')
    eq(BR.Crates.lookOf({ bt = 0 }).t, 1, 'and one below common is common')
    eq(BR.Crates.lookOf({ bt = 2, bg = 'red' }).g, 'red', 'a gift color reads back')

    -- A HALF-FILLED ROW is still a placeholder for the clip.
    C.shipping[2].clip = 'PLACEHOLDER_open'
    eq(BR.Crates.clipOf({ t = 2, f = false }), nil, 'a row with a placeholder clip has no clip')
    eq(BR.Crates.modelName({ t = 2, f = false }, false), 'ship_2',
        'while its real model names still choose the model')
    shipped()
end

describe('the server times a clip only when the whole row is real AND the props run here')
do
    realNames()
    local look = { t = 3, f = false }
    eq(BR.Crates.openMs(look), nil, 'the props resource is not started: open at once')
    resources.br_crates = 'starting'
    eq(BR.Crates.openMs(look), nil, 'starting is not started')
    resources.br_crates = 'started'
    eq(BR.Crates.openMs(look), 1200, 'started: the clip length, from the config')
    eq(BR.Crates.openMs({ t = 3, f = true }), 1400, 'the festive row times its own clip')
    eq(BR.Crates.openMs({ t = 1, g = 'blue' }), 1800, 'and so does a gift box')
    C.shipping[3].clipMs = 0
    eq(BR.Crates.openMs(look), nil, 'a clip length of zero is no clip')
    C.shipping[3].clipMs = 1200
    C.shipping[3].open = 'PLACEHOLDER_open'
    eq(BR.Crates.openMs(look), nil, 'a row missing its open prop opens at once')
    resources.br_crates = nil
    shipped()
end

describe('festive: December and January by the server date, and the dev switch')
do
    local function on(month, day)
        return BR.Crates.festiveNow(function() return { month = month, day = day, year = 2026 } end)
    end
    BR.Crates.festiveOverride = nil
    eq(on(11, 30), false, 'November 30 is not festive')
    eq(on(12, 1), true, 'December 1 is')
    eq(on(12, 31), true, 'December 31 is')
    eq(on(1, 1), true, 'January 1 is')
    eq(on(1, 31), true, 'January 31 is')
    eq(on(2, 1), false, 'February 1 is not')
    eq(on(10, 4), false, 'and today, October, is not')

    BR.Crates.festiveOverride = true
    eq(on(10, 4), true, 'brfestive on forces it in October')
    BR.Crates.festiveOverride = false
    eq(on(12, 25), false, 'brfestive off forces it off on December 25')
    BR.Crates.festiveOverride = nil
    eq(on(12, 25), true, 'and auto hands it back to the date')

    -- THE MONTHS ARE CONFIG, as the owner asked.
    C.festiveMonths = { [11] = true }
    eq(on(11, 30), true, 'moving the months in config moves the window')
    shipped()
    eq(BR.Crates.festiveNow(function() error('no clock') end), false,
        'a date that cannot be read is not festive, rather than an error')
end

-- =========================================================================
-- PART B -- the server
-- =========================================================================

-- ---------------------------------------------------------------- stubs ---

local jobs, commands, handlers = {}, {}, {}
local sent = {}          -- every TriggerClientEvent: { event, src, payload }
local timers = {}        -- SetTimeout: { at, fn, ms }
local notices = {}

BR.Sched = { every = function(_, name, fn) jobs[name] = fn end }
function RegisterCommand(name, fn) commands[name] = fn end
function RegisterNetEvent() end
function AddEventHandler(name, fn) handlers[name] = fn end
function TriggerClientEvent(event, src, payload)
    sent[#sent + 1] = { event = event, src = src, payload = payload }
end
function SetTimeout(ms, fn)
    timers[#timers + 1] = { at = gameMs + ms, ms = ms, fn = fn }
end
function GetPlayerPed() return 0 end
function GetEntityCoords() return nil end

--- Wind the clock to `ms` from now, firing every timer that falls due in order.
local function advance(ms)
    local target = gameMs + ms
    while true do
        table.sort(timers, function(a, b) return a.at < b.at end)
        local t = timers[1]
        if not t or t.at > target then break end
        table.remove(timers, 1)
        gameMs = t.at
        t.fn()
    end
    gameMs = target
end

local roster = {}
local matches = {}
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
        return e and matches[e.matchId] or nil
    end,
    matchById = function(id) return matches[id] end,
    eachMatch = function(fn) for _, m in pairs(matches) do fn(m) end end,
    notify = function(src, text, kind)
        notices[#notices + 1] = { src = src, text = text, kind = kind }
    end,
}
local given = {}
BR.Inv = {
    give = function(src, item) given[#given + 1] = { src = src, item = item } return true end,
    carryMax = function() return nil end,
}
local airdropOpened = {}
BR.Airdrop = { opened = function(m, n) airdropOpened[#airdropOpened + 1] = { m = m, n = n, at = gameMs } end }
local devTrust = true
BR.Admin = { devTrusted = function() return devTrust, devTrust and nil or 'dev-mode-off' end }

loadAll({ 'br_core/server/loot.lua', 'br_core/server/warmupcrates.lua' })

--- A match with an empty layout at a place of our choosing.
local SPOT = { x = 1200.0, y = -800.0, z = 30.0 }
local function newMatch(id, festive)
    local m = {
        id = id, seq = id, state = BR.MatchState.PLAYING,
        loot = { seed = 77, nextId = 0, items = {}, cells = {}, subs = {}, at = {},
                 respawn = {}, fixed = 0, festive = festive },
    }
    matches[id] = m
    return m
end

--- A player standing at the spot, subscribed to its cell.
local function standAt(src, m, dx)
    roster[src] = {
        name = 'p' .. src, state = BR.PlayerState.ALIVE, matchId = m.id,
        pos = { x = SPOT.x + (dx or 0.5), y = SPOT.y, z = SPOT.z },
    }
    m.loot.subs[src] = { [BR.LootCellKeyAt(SPOT.x, SPOT.y)] = true }
end

--- A sealed crate at the spot, tier `rarity`, through the real spawnStack.
local function crateAt(m, rarity, extra)
    local stack = BR.WarmupCrateStack(BR.Rng(rarity * 31 + 7),
        { x = SPOT.x, y = SPOT.y, z = SPOT.z, heading = 90.0, rarity = rarity })
    for k, v in pairs(extra or {}) do stack[k] = v end
    return BR.Loot.spawnStack(m, stack, SPOT.x, SPOT.y, SPOT.z)
end

local function claim(src, id)
    source = src
    handlers[BR.Net.LOOT_CLAIM]({ id = id })
    source = nil
    gameMs = gameMs + 300   -- past the per-player rate window's worst case
end

local function eventsOf(name)
    local out = {}
    for _, s in ipairs(sent) do if s.event == name then out[#out + 1] = s end end
    return out
end

local function reset()
    sent, timers, notices, given, airdropOpened, logs = {}, {}, {}, {}, {}, {}
    roster, matches = {}, {}
    BR.Crates.festiveOverride = nil
    gameMs = gameMs + 100000
end

--- Every LOOT_ADD entry sent, flattened, in order.
local function adds()
    local out = {}
    for _, s in ipairs(eventsOf(BR.Net.LOOT_ADD)) do
        for _, w in ipairs(s.payload) do out[#out + 1] = { src = s.src, w = w } end
    end
    return out
end

describe('Season 1: a crate is today\'s crate -- no look, opened on the spot')
do
    reset()
    season(1)
    realNames()
    resources.br_crates = 'started'
    local m = newMatch(1)
    standAt(10, m)
    sent = {}
    local e = crateAt(m, R.EPIC)
    eq(e.bt, nil, 'no tier is stamped')
    eq(e.bf, nil, 'no festive flag')
    local w = adds()[1] and adds()[1].w or {}
    ok(w.bt == nil and w.bf == nil and w.bg == nil and w.op == nil,
        'and the wire entry carries none of the new fields -- the payload is the one it always was')

    sent = {}
    local n = #e.contents
    claim(10, e.id)
    eq(#eventsOf(BR.Net.LOOT_OPENING), 0, 'no opening is announced')
    eq(#timers, 0, 'and nothing is timed')
    eq(e.kind, 'husk', 'the crate is a husk at once')
    eq(#adds(), n + 1, 'its contents and its husk went out in the same tick')
    shipped()
    resources.br_crates = nil
end

describe('Season 2: every crate is stamped with its tier and its match\'s festive answer')
do
    reset()
    season(2)
    local m = newMatch(1, true)
    standAt(10, m)
    sent = {}
    for _, r in ipairs({ R.COMMON, R.UNCOMMON, R.RARE, R.EPIC, R.LEGENDARY }) do
        local e = crateAt(m, r)
        eq(e.bt, r, ('a tier %d crate wears tape %d -- its rarity, the best thing inside'):format(r, r))
        eq(e.bf, true, 'festive, because the match was laid out festive')
    end
    local w = adds()[1].w
    eq(w.bt, R.COMMON, 'the tier travels on the wire as bt')
    eq(w.bf, true, 'and festive as bf')

    -- A DEATH BOX IS NOT A CRATE, and loose loot is not either.
    local d = BR.Loot.spawnStack(m, { item = 'deathbox', kind = 'deathbox', rarity = 3,
        contents = {} }, SPOT.x, SPOT.y, SPOT.z)
    eq(d.bt, nil, 'a death box wears no look')
    local loose = BR.Loot.spawnStack(m, { item = 'bandage', kind = BR.ItemKind.CONSUMABLE,
        rarity = 1 }, SPOT.x, SPOT.y, SPOT.z)
    eq(loose.bt, nil, 'nor does a loose item')

    -- ONCE: a repair re-indexes the crate and must not restyle it.
    local e = crateAt(m, R.RARE)
    m.loot.festive = false
    BR.Crates.festiveOverride = false
    e.repaired = nil
    source = 10
    handlers[BR.Net.LOOT_FIX]({ id = e.id, x = SPOT.x + 1.0, y = SPOT.y, z = SPOT.z })
    source = nil
    ok(e.repaired == true, 'the repair landed, so the crate was re-indexed')
    eq(e.bt, R.RARE, 'a repaired crate keeps its tier')
    eq(e.bf, true, 'and its festive set')
end

describe('festive is decided ONCE per match, when its loot is laid out')
do
    reset()
    season(2)
    BR.Crates.festiveOverride = true
    local m = { id = 5, seq = 5, state = BR.MatchState.WARMUP }
    matches[5] = m
    BR.Loot.begin(m, 4242)
    eq(m.loot.festive, true, 'the match records the answer it was laid out with')
    local chests, festive = 0, 0
    for _, e in pairs(m.loot.items) do
        if e.kind == 'chest' then
            chests = chests + 1
            if e.bf == true and e.bt == e.rarity then festive = festive + 1 end
        end
    end
    ok(chests > 100, ('the layout has its crates (%d)'):format(chests))
    eq(festive, chests, 'every one of them carries its tier and the festive set')

    -- THE CLOCK TURNING MID-MATCH CHANGES NOTHING. A crate born later in the
    -- same match -- a landing crate -- takes the match's answer, not today's.
    BR.Crates.festiveOverride = false
    standAt(11, m)
    local later = crateAt(m, R.RARE)
    eq(later.bf, true, 'a crate added later in the match is still festive')

    -- THE NEXT MATCH TAKES THE NEW ONE.
    local m2 = { id = 6, seq = 6, state = BR.MatchState.WARMUP }
    matches[6] = m2
    BR.Loot.begin(m2, 4242)
    eq(m2.loot.festive, false, 'the next match is laid out with the new answer')
    local any = false
    for _, e in pairs(m2.loot.items) do if e.bf then any = true end end
    eq(any, false, 'and none of its crates is festive')
    BR.Crates.festiveOverride = nil
end

describe('a missing clip or props falls back to today\'s instant open')
do
    reset()
    season(2)
    local m = newMatch(1)
    standAt(10, m)
    -- Placeholders, the props running: instant.
    resources[C.resource] = 'started'
    local e = crateAt(m, R.RARE)
    claim(10, e.id)
    eq(e.kind, 'husk', 'placeholder rows: the crate opens on the spot')
    eq(#timers, 0, 'with nothing timed')
    -- Real names, the props NOT running on this box: instant.
    realNames()
    local e2 = crateAt(m, R.RARE)
    claim(10, e2.id)
    eq(e2.kind, 'husk', 'real names but no props resource here: on the spot')
    eq(#eventsOf(BR.Net.LOOT_OPENING), 0, 'and no client is told to play a clip')
    shipped()
end

describe('the open: OPENING, the clip to everyone near, the burst on the last frame')
do
    reset()
    season(2)
    realNames()
    resources.br_crates = 'started'
    local m = newMatch(1, false)
    standAt(10, m)          -- the opener
    standAt(11, m, 1.5)     -- somebody beside them
    standAt(12, m, 2.0)     -- and a third, who will also finish a hold
    local e = crateAt(m, R.EPIC)
    local n = #e.contents
    sent = {}

    local t0 = gameMs
    claim(10, e.id)
    ok(e.opening ~= nil, 'the claim marks the crate opening')
    eq(e.kind, 'chest', 'it is still a crate -- nothing has burst')
    ok(e.contents and #e.contents == n, 'its contents are still inside it')
    eq(#adds(), 0, 'no loot reached the ground, so there is nothing to pick up yet')

    local ops = eventsOf(BR.Net.LOOT_OPENING)
    eq(#ops, 3, 'everyone subscribed to the cell is told to play the clip')
    local mine = {}
    for _, o in ipairs(ops) do
        eq(o.payload.id, e.id, 'about this crate')
        eq(o.payload.at, t0, 'with the server clock the opening started on')
        eq(o.payload.ms, 1200, 'and the clip length from the config row')
        mine[o.src] = o.payload.mine
    end
    eq(mine[10], true, 'the opener\'s copy says it is theirs')
    ok(mine[11] == nil and mine[12] == nil, 'nobody else\'s does, and nobody is told who it was')

    eq(#timers, 1, 'one burst is timed')
    eq(timers[1] and timers[1].ms, 1200, 'at the clip\'s length exactly')

    -- TWO HOLDS FINISH AT ONCE: the second finds it opening, and is answered
    -- the way a husk is -- silently.
    sent, notices = {}, {}
    claim(12, e.id)
    eq(#sent, 0, 'a second claim on an opening crate sends nothing')
    eq(#notices, 0, 'and says nothing')
    eq(#timers, 1, 'and times no second burst')

    -- A CLIENT THAT STREAMS IT IN NOW sees it opening.
    sent = {}
    roster[13] = { name = 'p13', state = BR.PlayerState.ALIVE, matchId = 1,
                   pos = { x = SPOT.x + 3.0, y = SPOT.y, z = SPOT.z } }
    source = 13
    local cx, cy = BR.LootCellOf(SPOT.x, SPOT.y)
    handlers[BR.Net.LOOT_CELL]({ cx = cx, cy = cy })
    source = nil
    local seen = nil
    for _, a in ipairs(adds()) do if a.w.id == e.id then seen = a.w end end
    ok(seen ~= nil, 'a player arriving mid-clip is sent the crate')
    eq(seen and seen.op, true, 'marked opening, so they draw the open prop, never a clip begun part-way')
    eq(seen and seen.bt, R.EPIC, 'with its tier')

    -- THE LAST FRAME. The claims above moved the clock on; what is left of
    -- the clip is measured from the opening's own start.
    sent = {}
    advance((t0 + 1200) - gameMs - 1)
    eq(#adds(), 0, 'one millisecond before the last frame, nothing has burst')
    eq(e.kind, 'chest', 'and the crate is still opening')
    advance(1)
    local after = adds()
    ok(#after > 0, 'on the last frame the loot bursts')
    eq(e.kind, 'husk', 'and the crate becomes its husk')
    eq(e.opening, nil, 'no longer opening')

    -- TODAY'S BURST: the contents born out of the box, then the husk.
    local firstHusk, lastItem = nil, 0
    for i, a in ipairs(after) do
        if a.w.id == e.id then firstHusk = firstHusk or i
        else
            lastItem = i
            ok(a.w.fx == e.x and a.w.fy == e.y and a.w.fl ~= nil,
                'each item is born out of the crate\'s mouth -- today\'s arc')
        end
    end
    local items = 0
    for _, a in ipairs(after) do if a.w.id ~= e.id and a.src == 10 then items = items + 1 end end
    eq(items, n, 'every item that was inside reached the opener')
    ok(firstHusk and firstHusk > lastItem, 'the contents go out before the husk, as today')
    local husk = after[firstHusk] and after[firstHusk].w or {}
    eq(husk.kind, 'husk', 'the re-announce is the husk')
    eq(husk.bt, R.EPIC, 'still wearing its tier, so it opens into the right open prop')
    eq(husk.rarity, R.COMMON, 'with a husk\'s common rarity, as always')
    eq(husk.op, nil, 'and not opening')

    -- AND AFTER: a client streaming the husk in gets the husk.
    sent = {}
    m.loot.at[13] = nil
    m.loot.subs[13] = nil
    source = 13
    handlers[BR.Net.LOOT_CELL]({ cx = cx, cy = cy })
    source = nil
    local late = nil
    for _, a in ipairs(adds()) do if a.w.id == e.id then late = a.w end end
    ok(late and late.kind == 'husk' and late.bt == R.EPIC and late.op == nil,
        'a player arriving after the burst is sent the open husk with its tier')
    eq(BR.Loot.openings.burst >= 1, true, 'the session count saw a burst')
    resources.br_crates = nil
    shipped()
end

describe('the opener dying or leaving mid-clip does not stop the box')
do
    for _, case in ipairs({
        { name = 'goes down', apply = function() roster[10].state = BR.PlayerState.DBNO end },
        { name = 'is eliminated', apply = function() roster[10].state = BR.PlayerState.OUT end },
        { name = 'disconnects', apply = function()
            roster[10] = nil
            for _, m in pairs(matches) do m.loot.subs[10] = nil end
        end },
    }) do
        reset()
        season(2)
        realNames()
        resources.br_crates = 'started'
        local m = newMatch(1)
        standAt(10, m)
        standAt(11, m, 1.0)
        local e = crateAt(m, R.RARE)
        claim(10, e.id)
        case.apply()
        sent = {}
        advance(1200)
        eq(e.kind, 'husk', ('the opener %s mid-clip: the box still opens'):format(case.name))
        local items = 0
        for _, a in ipairs(adds()) do if a.src == 11 and a.w.id ~= e.id then items = items + 1 end end
        ok(items > 0, 'and its loot bursts for whoever is still there')
        resources.br_crates = nil
        shipped()
    end
end

describe('the match ending mid-clip bursts nothing')
do
    for _, case in ipairs({
        { name = 'the match is decided (ENDED)', apply = function(m) m.state = BR.MatchState.ENDED end },
        { name = 'the match is torn down (CLEANUP clears its loot)', apply = function(m)
            m.state = BR.MatchState.CLEANUP
            BR.Loot.clear(m)
        end },
        { name = 'the crate left the registry', apply = function(m, e) BR.Loot.remove(m, e) end },
    }) do
        reset()
        season(2)
        realNames()
        resources.br_crates = 'started'
        local m = newMatch(1)
        standAt(10, m)
        local e = crateAt(m, R.RARE)
        claim(10, e.id)
        case.apply(m, e)
        sent = {}
        local before = BR.Loot.openings.dropped
        advance(5000)
        eq(#adds(), 0, ('%s: no loot bursts'):format(case.name))
        ok(e.kind ~= 'husk', 'and no husk is announced')
        eq(BR.Loot.openings.dropped, before + 1, 'and the opening is counted as dropped, with its reason')
        resources.br_crates = nil
        shipped()
    end
end

describe('the airdrop: its own open path, now at the burst')
do
    reset()
    season(2)
    realNames()
    resources.br_crates = 'started'
    local m = newMatch(1)
    standAt(10, m)
    local stack = {
        item = 'airdrop', kind = 'chest', rarity = R.LEGENDARY, count = 1,
        prop = 'prop_box_wood05a', heading = 0.0,
        contents = BR.WarmupCrateContents(BR.Rng(5), R.LEGENDARY),
        huskItem = 'airdrophusk', huskProp = 'prop_box_wood05b', airdrop = 1,
    }
    local e = BR.Loot.spawnStack(m, stack, SPOT.x, SPOT.y, SPOT.z)
    eq(e.bt, R.LEGENDARY, 'the airdrop crate is a legendary box')
    claim(10, e.id)
    eq(#airdropOpened, 0, 'the blip\'s last minute does not start when the hold completes')
    advance(1200)
    eq(#airdropOpened, 1, 'it starts at the burst, when there is something to see')
    eq(airdropOpened[1] and airdropOpened[1].n, 1, 'for this drop')
    eq(e.item, 'airdrophusk', 'and the husk keeps the airdrop\'s own item id')
    eq(e.bt, R.LEGENDARY, 'and its tier')
    resources.br_crates = nil
    shipped()
end

describe('the warmup pad: a generated crate respawns after the burst; the four keep their cycle')
do
    reset()
    season(2)
    realNames()
    resources.br_crates = 'started'
    local zone = BR.Loot.warmupZone()
    local pad = BR.Config.Match.warmupPos

    -- THE GENERATED PAD CRATES: the replacement is queued when the box bursts.
    roster[20] = { name = 'w', state = BR.PlayerState.WARMUP,
                   pos = { x = pad.x, y = pad.y, z = pad.z } }
    zone.loot.subs[20] = { [BR.LootCellKeyAt(pad.x, pad.y)] = true }
    local stack = BR.WarmupCrateStack(BR.Rng(3), { x = pad.x, y = pad.y, z = pad.z,
        heading = 0.0, rarity = R.RARE })
    stack.warmup = true
    local g = BR.Loot.spawnStack(zone, stack, pad.x, pad.y, pad.z)
    ok(g.bt ~= nil, 'a pad crate is stamped too')
    local queued = #zone.loot.respawn
    source = 20
    handlers[BR.Net.LOOT_CLAIM]({ id = g.id })
    source = nil
    eq(#zone.loot.respawn, queued, 'no replacement is queued while it is only opening')
    advance(1200)
    eq(#zone.loot.respawn, queued + 1, 'one is queued at the burst')

    -- THE FOUR PERMANENT CRATES: opening is sealed, the burst is the husk, and
    -- the reset runs on from there, for two whole cycles.
    jobs['warmupcrates.tick']()      -- places them
    local W = BR.Config.WarmupCrates
    local a = W.anchors[3]
    local rec = nil
    for _, it in pairs(zone.loot.items) do
        if it.x == a.x and it.y == a.y and it.kind == 'chest' then rec = it end
    end
    ok(rec ~= nil and rec.bt == a.rarity, 'anchor 3 is a box of its authored tier')
    for cycle = 1, 2 do
        roster[21] = { name = 'v', state = BR.PlayerState.WARMUP,
                       pos = { x = a.x, y = a.y, z = a.z } }
        zone.loot.subs[21] = { [BR.LootCellKeyAt(a.x, a.y)] = true }
        source = 21
        handlers[BR.Net.LOOT_CLAIM]({ id = rec.id })
        source = nil
        gameMs = gameMs + 300
        ok(rec.opening ~= nil, ('cycle %d: the hold starts it opening'):format(cycle))
        jobs['warmupcrates.tick']()
        eq(rec.kind, 'chest', 'the pad\'s cycle treats an opening crate as sealed')
        advance(1200)
        eq(rec.kind, 'husk', 'the burst makes it a husk')
        roster[21] = nil
        jobs['warmupcrates.tick']()          -- nobody near: the settle starts
        advance((W.settleMs or 5000) + 300)
        jobs['warmupcrates.tick']()          -- settled: the spill goes home
        advance((W.returnMs or 520) + 300)
        jobs['warmupcrates.tick']()
        eq(rec.kind, 'chest', ('cycle %d: it reseals'):format(cycle))
        eq(rec.opening, nil, 'not opening')
        eq(rec.bt, a.rarity, 'wearing the same tier')
    end
    resources.br_crates = nil
    shipped()
end

describe('brbox: a server-owned test crate of any look')
do
    reset()
    season(2)
    local m = newMatch(1, false)
    standAt(10, m)
    local function ask(box)
        source = 10
        handlers[BR.Net.LOOT_DEV]({ box = box, x = SPOT.x, y = SPOT.y, z = SPOT.z })
        source = nil
        local newest = nil
        for _, it in pairs(m.loot.items) do
            if not newest or it.id > newest.id then newest = it end
        end
        return newest
    end
    local e = ask({ tier = 4 })
    ok(e and e.kind == 'chest', 'a crate is spawned')
    eq(e.bt, 4, 'of the tier asked for')
    eq(BR.LootContentsRarity(e.contents), R.EPIC, 'with real contents whose best item is that tier')
    eq(e.bf, nil, 'plain, because the match is')
    local f = ask({ tier = 1, festive = true })
    eq(f.bf, true, 'festive when asked, in October')
    local gft = ask({ gift = 'green' })
    eq(gft.bg, 'green', 'a gift box of the color asked for')
    ok(gft.bt ~= nil, 'stamped, so the client knows it is a Season 2 box')
    eq(#notices, 0, 'and the dev crate toasts nobody -- its report is console-only')
    ok(said('brbox (client, 10)'), 'the server console has the report')

    local before = m.loot.nextId
    ask({ gift = 'purple' })
    eq(m.loot.nextId, before, 'an unknown gift color spawns nothing')
    ask({ tier = 6 })
    eq(m.loot.nextId, before, 'nor does a tier past legendary')

    season(1)
    ask({ tier = 3 })
    eq(m.loot.nextId, before, 'on Season 1 nothing is spawned')
    ok(said('Season 2 crates are off'), 'and the console says why')

    season(2)
    devTrust = false
    ask({ tier = 3 })
    eq(m.loot.nextId, before, 'and without the server\'s dev trust, nothing')
    devTrust = true
end

describe('brfestive: forces the set and says when it applies')
do
    reset()
    season(2)
    commands['brfestive'](0, { 'on' })
    eq(BR.Crates.festiveOverride, true, 'on forces it on')
    ok(said('ON') and said('next match'), 'and says it applies from the next match\'s layout')
    commands['brfestive'](0, { 'off' })
    eq(BR.Crates.festiveOverride, false, 'off forces it off')
    commands['brfestive'](0, { 'auto' })
    eq(BR.Crates.festiveOverride, nil, 'auto hands it back to the date')
    logs = {}
    commands['brfestive'](0, { 'sideways' })
    ok(said('usage'), 'anything else prints the usage')
    eq(BR.Crates.festiveOverride, nil, 'and changes nothing')
end

-- ----------------------------------------------------------------- result ---

print = realPrint
io.write(('%s%d passed%s'):format('\27[32m', pass, '\27[0m'))
if fail > 0 then
    io.write(('  %s%d failed%s\n'):format('\27[31m', fail, '\27[0m'))
    os.exit(1)
end
io.write('\n')
