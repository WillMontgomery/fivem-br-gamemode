-- Unit tests for the Season 2 terminals' built functions (#396): what Scan,
-- the bounty, Supply drop and Max ammo do once the door has said yes.
--
-- The door itself -- the session, the key, the squad's one use, the options
-- -- is tools/test_terminal.lua and tools/test_yubikey.lua. This file stands
-- up the REAL br_core/server/terminal.lua and server/terminalfx.lua over a
-- stubbed roster, scheduler and key, and the REAL client/terminalfx.lua over
-- modeled blip natives:
--
--   PART A  Scan: the whole squad sees every opponent for the rest of the
--           match, nobody else does, and the runner gets the bounty.
--   PART B  the bounty, the owner's spec (#396, 2026-10-04): the toast to
--           everyone, the toast to the squad, ten minutes, everyone outside
--           the squad sent where it is, the squad's beacon bit, the match
--           panel; ended early by elimination and by the match ending.
--   PART C  Supply drop and Max ammo: their options, their refusals, and
--           that nothing is spent when they cannot run.
--   PART D  the client: Scan's and the bounty's marks on both maps, moved,
--           dropped, and cleared in the lobby and when the pushes stop.
--   PART E  the hooks the other files make, pinned by text: the beacon's
--           bit, the squad panel's glyph, the teammates' blip 58 colour 69.
--
-- The airdrop half of Supply drop (BR.Airdrop.call, under the real siting
-- rules) is tools/test_airdrop.lua's; the inventory half of Max ammo
-- (BR.Inv.fillAmmo) is tools/test_roster.lua's.
--
-- Run via tools/verify.sh, or directly:  lua tools/test_terminalfx.lua

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

--- The function files br_core's manifest lists under `<side>/terminalfx/`
--- (wave A on, one per function), in its order, as paths under ROOT -- so a
--- file the manifest forgot is a function this suite finds unbuilt.
--- @param side string  'server' | 'client'
--- @return string[]
local function fxFiles(side)
    local out = {}
    local text = readFile(ROOT .. 'br_core/fxmanifest.lua') or ''
    for f in text:gmatch("'(" .. side .. "/terminalfx/[%w_]+%.lua)'") do
        out[#out + 1] = 'br_core/' .. f
    end
    return out
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
-- THE SERVER
-- =========================================================================

local convars = { sv_devMode = 'true', br_season = '2' }
function GetConvar(n, d)
    local v = convars[n]
    if v == nil then return d end
    return v
end
function SetConvarReplicated(n, v) convars[n] = v end

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
    'br_lib/shared/world.lua',
    'br_lib/config/match.lua',
    'br_lib/config/storm.lua',
    'br_lib/config/map.lua',
    'br_lib/config/weapons.lua',
    -- The vehicles the gamemode refuses: EMP never stalls one (wave C).
    'br_lib/config/vehicles.lua',
    -- The consumables (round 5): Gear Up's list is built from this and
    -- config/weapons.lua as terminals.lua loads.
    'br_lib/config/loot.lua',
    'br_lib/shared/season.lua',
    'br_lib/config/seasons.lua',
    'br_lib/config/terminals.lua',
    'br_lib/shared/storm_solve.lua',
    'br_lib/shared/storm_shape.lua',
    'br_lib/shared/terminal_solve.lua',
    'br_lib/shared/shop_solve.lua',
})
-- The currency's name a Volts figure is written with (config/market.lua's).
BR.Config.Market = { currency = 'Volts' }

local CT = BR.Config.Terminals
local COPY = CT.copy
BR.Season.strict = true

local function season(n)
    BR.Season.boot(function(name)
        return name == 'br_season' and tostring(n) or ''
    end, function() end)
end
season(2)

-- ---------------------------------------------------------------- stubs ---

local jobs, handlers = {}, {}
-- A RUN LOADS FOR runMinMs..runMaxMs (round 2): the server's SetTimeout,
-- held here and stepped by `flush`.
local timers = {}
function SetTimeout(ms, fn) timers[#timers + 1] = { at = gameMs + ms, fn = fn } end
local sent = {}          -- TriggerClientEvent: { event, src, payload }
local notices = {}       -- BR.Server.notify: { target, text, tone }
local keys = {}          -- [src] = true while holding a Yubikey
local airdropCalls = {}  -- BR.Airdrop.call: { m, x, y }
local filled = {}        -- BR.Inv.fillAmmo: [src] = rounds it would add
local granted = {}       -- BR.Inv.grantEffect: { src, effect } (Field medic)
local drained = {}       -- BR.Damage.drain: { src, amount, took } (Field medic, round 4)
local invs = {}          -- BR.Inv.of: [src] = { slots = { [i] = stack|false } } (Disarm)
local revoked = {}       -- BR.Inv.revoke: { src, slot, item, grace }
local rooms = {}         -- BR.Inv.roomFor: [src] = { n, why } (Gear Up, round 5); none is room for all of it
local gives = {}         -- BR.Inv.give: { src, stack } (Gear Up)

BR.Sched = { every = function(_, name, fn) jobs[name] = fn end }
function RegisterNetEvent() end
function AddEventHandler(name, fn)
    handlers[name] = handlers[name] or {}
    table.insert(handlers[name], fn)
end
function TriggerClientEvent(event, src, payload)
    sent[#sent + 1] = { event = event, src = src, payload = payload }
end

local roster, matches = {}, {}
function GetPlayerName(src) return roster[src] and roster[src].name or nil end

BR.Roster = {
    get = function(src) return roster[src] end,
    each = function(pred, fn)
        local order = {}
        for src in pairs(roster) do order[#order + 1] = src end
        table.sort(order)
        for _, src in ipairs(order) do
            local e = roster[src]
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
    eachMatch = function(fn)
        local order = {}
        for _, m in pairs(matches) do order[#order + 1] = m end
        table.sort(order, function(a, b) return a.id < b.id end)
        for _, m in ipairs(order) do fn(m) end
    end,
    notify = function(target, text, tone)
        notices[#notices + 1] = { target = target, text = text, tone = tone }
    end,
    isInMatch = function(st)
        return st == BR.PlayerState.ALIVE or st == BR.PlayerState.DBNO
            or st == BR.PlayerState.WARMUP or st == BR.PlayerState.BUS
            or st == BR.PlayerState.FREEFALL or st == BR.PlayerState.GLIDE
    end,
}
BR.Broadcast = {
    toMatch = function(m, event, payload)
        for src, e in pairs(roster) do
            if e.matchId == m.id then TriggerClientEvent(event, src, payload) end
        end
    end,
}
BR.Yubikey = {
    holds = function(src) return keys[src] == true end,
    take = function(src) local had = keys[src] == true; keys[src] = false; return had end,
    push = function() end,
    licenseOf = function(src) return 'license:' .. src end,
    -- A key given back to the account a run took it from (server/yubikey.lua's
    -- cap of one stands).
    restore = function(lic)
        local src = tonumber(tostring(lic):match('(%d+)$'))
        if not src or keys[src] == true then return false end
        keys[src] = true
        return true
    end,
}

-- THE MARKET, MODELED ON ITS CONTRACT (server/market.lua; tools/test_volts.lua
-- holds the real one): balanceOf is the spendable figure; charge answers
-- through a callback -- at once, or held like a DynamoDB round trip while
-- `market.hold` is set -- and the row's condition decides; refund puts an
-- amount back on the account.
local market = { wallet = {}, charges = {}, refunds = {}, hold = false, pending = {}, broken = false }
BR.Market = {
    balanceOf = function(src) return market.wallet[src] or 0 end,
    licenseOf = function(src) return roster[src] and ('license:' .. src) or nil end,
    charge = function(src, cost, reason, done)
        market.charges[#market.charges + 1] = { src = src, cost = cost, reason = reason }
        local function answer()
            if market.broken then done(false, 'timed out') return end
            if (market.wallet[src] or 0) < cost then done(false, 'cannot afford it') return end
            market.wallet[src] = market.wallet[src] - cost
            done(true, nil, market.wallet[src])
        end
        if market.hold then market.pending[#market.pending + 1] = answer else answer() end
    end,
    refund = function(lic, amount)
        market.refunds[#market.refunds + 1] = { lic = lic, amount = amount }
        local src = tonumber(tostring(lic):match('(%d+)$'))
        market.wallet[src] = (market.wallet[src] or 0) + amount
    end,
}
-- The storm as far as these functions ask it. Wave B's Storm control loads
-- here too, since this suite loads every function file the manifest lists;
-- its own suite, tools/test_terminalworld.lua, runs it over the real
-- server/storm.lua. Here it only needs answers that keep it out of the way:
-- an aim refused, the final circle already on the map. Only what the loaded
-- files call: 'the storm stubs' below holds each of them to a caller.
BR.Storm = {
    finalCentre = function(m) return m and m.finalStub or nil end,
    aim = function() return nil, 'no_circle' end,
}

loadAll({
    'br_core/server/terminal.lua',
    'br_core/server/terminalfx.lua',
})
loadAll(fxFiles('server'))

local T = BR.Terminal

-- After the load, so the files' own nil-guards are what the season and the
-- jobs were registered against; the airdrop and the inventory are the other
-- suites', so here they are models with the same contract.
BR.Airdrop = {
    busy = function(m) return m.dropBusy == true end,
    candidate = function(m, x, y)
        if m.noSite then return nil end
        return { id = 'poi_near', x = x + 10.0, y = y + 10.0 }
    end,
    call = function(m, x, y)
        airdropCalls[#airdropCalls + 1] = { m = m, x = x, y = y }
        if m.noSite then return nil, 'no_site' end
        return { n = 9, poi = 'poi_near', x = x + 10.0, y = y + 10.0 }, nil
    end,
}
BR.Inv = {
    ammoRoom = function(src) return filled[src] or 0 end,
    fillAmmo = function(src)
        local n = filled[src] or 0
        filled[src] = 0
        return n
    end,
    -- Field medic's door (server/inventory.lua's; its ledger half is
    -- tools/test_roster.lua's): recorded, and false for a player with no entry.
    grantEffect = function(src, effect)
        if not roster[src] then return false end
        granted[#granted + 1] = { src = src, effect = effect }
        return true
    end,
    -- Disarm's (server/inventory.lua's; the inventory and the anticheat
    -- halves are tools/test_roster.lua's): the slot emptied and recorded.
    of = function(src)
        if not roster[src] then return nil end
        invs[src] = invs[src] or { slots = { false, false, false, false, false } }
        return invs[src]
    end,
    revoke = function(src, slot, grace)
        local inv = invs[src]
        local s = inv and inv.slots[slot]
        if not s then return nil end
        inv.slots[slot] = false
        revoked[#revoked + 1] = { src = src, slot = slot, item = s.item, grace = grace }
        return s
    end,
    -- Gear Up's door (round 5; server/inventory.lua's -- the real roomFor over
    -- real slots and ceilings, and give taking exactly what it said, is
    -- tools/test_roster.lua's): how much would fit, as a block sets it, and
    -- the grant recorded.
    roomFor = function(src, stack)
        if not roster[src] then return 0, 'noinv' end
        local r = rooms[src]
        if r then return math.min(r.n, stack.count or 1), r.n <= 0 and r.why or nil end
        return stack.count or 1, nil
    end,
    give = function(src, stack)
        if not roster[src] then return false, nil, 'noinv' end
        local copy = {}
        for k, v in pairs(stack) do copy[k] = v end
        gives[#gives + 1] = { src = src, stack = copy }
        return true, nil, nil
    end,
}

-- Field medic's drain (round 4; server/damage.lua's BR.Damage.drain -- its
-- ledger half, through the real sampler and the health audit, is
-- tools/test_roster.lua's): modeled on its contract -- a standing player
-- only, never emptied -- and recorded.
BR.Damage = {
    drain = function(src, amount)
        local e = roster[src]
        if not e or e.state ~= BR.PlayerState.ALIVE then return 0.0 end
        local took = math.min(amount, (e.hp or 100.0) - 1.0)
        if took <= 0 then return 0.0 end
        e.hp = e.hp - took
        drained[#drained + 1] = { src = src, amount = amount, took = took }
        return took
    end,
}

local function fire(name, src, ...)
    local prev = source
    source = src
    for _, fn in ipairs(handlers[name] or {}) do fn(...) end
    source = prev
end

--- Let every pending timer run, the clock moved to each one's time: a run's
--- loading, over.
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

local function textOf(n)
    if type(n.text) == 'table' then return n.text.text end
    return n.text
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

local function noticeIndex(fragment, src)
    for i, n in ipairs(noticesTo(src)) do
        if (textOf(n) or ''):find(fragment, 1, true) then return i end
    end
    return nil
end

local C0 = { x = 1200.0, y = -800.0 }
local SITE = { id = 'tower', x = C0.x + 1.0, y = C0.y, z = 30.0, h = 90.0 }
CT.sites = { SITE, { id = 'shack', x = C0.x + 6000.0, y = C0.y, z = 30.0, h = 0.0 } }

local function newMatch(id)
    local m = {
        id = id, seq = id, state = BR.MatchState.PLAYING, mode = 'squad',
        startedAt = gameMs - 125000,
        storm = BR.BuildStormRecord(2, C0.x, C0.y, 1500.0, C0.x + 50.0, C0.y, 800.0,
            gameMs, 600000, 60000, 1.0, 4242),
        finalStub = { x = 1111.0, y = -2222.0, r = 0.0, phase = 8 },
    }
    matches[id] = m
    return m
end

local function player(src, m, squad, at, state)
    roster[src] = {
        src = src, name = 'p' .. src, state = state or BR.PlayerState.ALIVE,
        matchId = m and m.id or nil, squadId = squad,
        pos = at and { x = at.x, y = at.y, z = at.z or 30.0 } or nil,
        -- Full health and armor (display units), unless a block says otherwise.
        hp = 100.0, armour = 100, kills = 0,
    }
end

local function reset()
    -- The last block's runs, finished first: a run left loading would still be
    -- in flight for its player in the next block.
    market.hold = false
    for _, answer in ipairs(market.pending) do answer() end
    flush()
    sent, notices, logs, airdropCalls, filled, granted, drained = {}, {}, {}, {}, {}, {}, {}
    invs, revoked, rooms, gives = {}, {}, {}, {}
    roster, matches, keys = {}, {}, {}
    timers = {}
    market.wallet, market.charges, market.refunds, market.pending = {}, {}, {}, {}
    market.hold, market.broken = false, false
    -- What the persistent notices last sent each player (round 4), forgotten
    -- with the roster: a new block's players are new players.
    for s = 1, 32 do T.forgetImpacts(s) end
    gameMs = gameMs + 100000
end

--- Open the terminal for `src` the real way and run `id`, to its last word:
--- the loading is let run out (round 2).
local function runAt(src, id, options, at)
    fire(BR.Net.TERMINAL_USE, src, { terminalId = 'tower' })
    gameMs = gameMs + 1000
    fire(BR.Net.TERMINAL_RUN, src, { terminalId = 'tower', functionId = id, options = options, at = at })
    flush()
    return lastOf(BR.Net.TERMINAL_RESULT, src)
end

--- A `brterminal run` line typed by `src`; the answer on their F8.
local function devRun(src, line)
    local args = { 'run' }
    for w in line:gmatch('%S+') do args[#args + 1] = w end
    commands.brterminalsv(src, args, 'brterminalsv run ' .. line)
    return lastOf(BR.Net.TERMINAL_DEV, src) or ''
end

--- Two squads and a solo player in one match: A = 1, 2; B = 3, 4; solo 5.
local function lobby()
    local m = newMatch(1)
    player(1, m, 'A', SITE)
    player(2, m, 'A', { x = C0.x + 40.0, y = C0.y })
    player(3, m, 'B', { x = C0.x + 300.0, y = C0.y + 10.0 })
    player(4, m, 'B', { x = C0.x + 310.0, y = C0.y - 10.0 }, BR.PlayerState.DBNO)
    player(5, m, nil, { x = C0.x - 500.0, y = C0.y })
    keys[1] = true
    for src = 1, 5 do market.wallet[src] = 1000 end
    return m
end

describe('the storm stubs: every one has a caller')
do
    -- Round 5's review: an aimCheck stub outlived the refusal that called it,
    -- with a comment still promising "no spot it can end on" -- and was copied
    -- into the next suite to load every function file. Each answer the storm
    -- gives, in this suite's stub and in every other suite that loads the
    -- function files, must be one a loaded server file still asks for.
    local src = (readFile(ROOT .. 'br_core/server/terminal.lua') or '')
        .. (readFile(ROOT .. 'br_core/server/terminalfx.lua') or '')
    for _, f in ipairs(fxFiles('server')) do src = src .. (readFile(ROOT .. f) or '') end
    for _, suite in ipairs({ 'tools/test_terminalfx.lua', 'tools/test_terminalstrike.lua' }) do
        local body = (readFile(suite) or ''):match('\nBR%.Storm = (%b{})')
        ok(body ~= nil, suite .. ' stubs the storm')
        for name in (body or ''):gmatch('\n%s*([%w_]+)%s*=%s*function') do
            ok(src:find('BR.Storm.' .. name .. '(', 1, true) ~= nil,
                ('%s stubs BR.Storm.%s, and a loaded server file calls it'):format(suite, name))
        end
    end
end

-- =========================================================================
-- PART A -- Scan
-- =========================================================================

describe('Scan: registered, built, no options')
do
    local row = T.row('scan')
    ok(row and row.implemented == true and T.FUNCTIONS.scan ~= nil, 'scan is built and has a server half')
    ok(row and (row.options == nil or #row.options == 0), 'and takes no options')
end

describe('Scan: the whole squad sees every opponent, nobody else does')
do
    reset()
    local m = lobby()
    local r = runAt(1, 'scan')
    ok(r and r.ok == true and r.code == 'done', 'it runs', r and r.code)
    eq(keys[1], false, 'the key is spent')
    ok(T.squadUsed(1) and T.squadUsed(2), "and the squad's one use")

    local a, b = lastOf(BR.Net.TERMINAL_SCAN, 1), lastOf(BR.Net.TERMINAL_SCAN, 2)
    ok(a ~= nil and b ~= nil, 'both members of the scanning squad are sent the opponents at once')
    local ids = {}
    for _, p in ipairs(a and a.list or {}) do ids[#ids + 1] = p.s end
    eq(table.concat(ids, ','), '3,4,5', 'every opponent, the solo player included, and no squadmate')
    local downed = a and a.list[2]
    ok(downed and downed.s == 4 and downed.down == true, 'a downed opponent is marked down')
    ok(a.list[1].x == roster[3].pos.x and a.list[1].y == roster[3].pos.y, 'at the roster\'s own position')
    eq(a.matchId, 1, 'stamped with the match')
    eq(#eventsOf(BR.Net.TERMINAL_SCAN, 3) + #eventsOf(BR.Net.TERMINAL_SCAN, 4)
        + #eventsOf(BR.Net.TERMINAL_SCAN, 5), 0, 'no other squad is sent a thing')

    -- FOR THE REST OF THE MATCH, refreshed on the job.
    roster[3].pos = { x = 1.0, y = 2.0, z = 0.0 }
    roster[5].state = BR.PlayerState.OUT
    local n = #eventsOf(BR.Net.TERMINAL_SCAN, 1)
    gameMs = gameMs + 2000
    jobs['terminal.scan']()
    eq(#eventsOf(BR.Net.TERMINAL_SCAN, 1), n + 1, 'the next push arrives on the job')
    local again = lastOf(BR.Net.TERMINAL_SCAN, 1)
    ok(again.list[1].x == 1.0, 'with where they are now')
    eq(#again.list, 2, 'and an eliminated opponent is no longer marked')

    -- THE WHOLE SQUAD: a dead squadmate is still sent it (they watch the map).
    roster[2].state = BR.PlayerState.OUT
    gameMs = gameMs + 60000 * 15
    jobs['terminal.scan']()
    ok(#eventsOf(BR.Net.TERMINAL_SCAN, 2) >= 3, 'an eliminated squadmate keeps receiving it')
    ok(#eventsOf(BR.Net.TERMINAL_SCAN, 1) >= 3, 'long after the bounty would have ended')

    m.state = BR.MatchState.ENDED
    n = #eventsOf(BR.Net.TERMINAL_SCAN, 1)
    jobs['terminal.scan']()
    eq(#eventsOf(BR.Net.TERMINAL_SCAN, 1), n, 'once the match is over, nothing more')
end

-- =========================================================================
-- PART B -- the bounty
-- =========================================================================

describe('the bounty: the lobby is told, then the squad, in the owner\'s words')
do
    reset()
    lobby()
    runAt(1, 'scan')
    local action = noticeIndex('has redeemed their special power', 3)
    local bounty = noticeIndex('A new bounty is among us', 3)
    ok(action ~= nil and bounty ~= nil and action < bounty,
        'everyone hears the redemption first, then the bounty', ('%s, %s'):format(tostring(action), tostring(bounty)))
    for _, src in ipairs({ 1, 2, 3, 4, 5 }) do
        ok(noticeIndex('A new bounty is among us', src) ~= nil, ('p%d is told about the bounty'):format(src))
    end
    local n
    for _, x in ipairs(noticesTo(3)) do
        if (textOf(x) or ''):find('A new bounty', 1, true) then n = x end
    end
    ok(type(n.text) == 'table' and n.text.text == 'A new bounty is among us: p1.',
        'the name is filled', n and textOf(n))
    ok(type(n.text) == 'table' and n.text.parts ~= nil or type(n.text) == 'table',
        'as a named piece (drawn bold), not formatted in')
    ok(noticeIndex('Protect', 2) ~= nil, 'the squadmate is told to protect them')
    eq(noticeIndex('Protect', 1), nil, 'the bounty is not told to protect themselves')
    for _, src in ipairs({ 3, 4, 5 }) do
        eq(noticeIndex('Protect', src), nil, ('p%d, outside the squad, is not'):format(src))
    end
    local p
    for _, x in ipairs(noticesTo(2)) do
        if (textOf(x) or ''):find('Protect', 1, true) then p = x end
    end
    eq(p and textOf(p), "Protect p1! They've got a bounty for the next 10 minutes.", 'in the owner\'s words')
end

describe('the bounty: everyone outside the squad is sent where it is, for ten minutes')
do
    reset()
    local m = lobby()
    runAt(1, 'scan')
    ok(T.hasBounty(1) == true, 'p1 has the bounty')
    ok(T.hasBounty(2) == false, 'p2 does not')
    for _, src in ipairs({ 3, 4, 5 }) do
        local d = lastOf(BR.Net.TERMINAL_BOUNTY, src)
        ok(d and #d.list == 1 and d.list[1].s == 1 and d.list[1].x == SITE.x,
            ('p%d is sent the bounty\'s position'):format(src))
    end
    for _, src in ipairs({ 1, 2 }) do
        local d = lastOf(BR.Net.TERMINAL_BOUNTY, src)
        ok(d == nil or #d.list == 0, ('p%d, in the squad, is not (the beacon carries it)'):format(src))
    end

    roster[1].pos = { x = 50.0, y = 60.0, z = 0.0 }
    gameMs = gameMs + 1000
    jobs['terminal.bounty']()
    ok(lastOf(BR.Net.TERMINAL_BOUNTY, 3).list[1].x == 50.0, 'it follows them, every second')

    local info = T.matchInfo(3, gameMs)
    ok(info.bounties and #info.bounties == 1 and info.bounties[1].name == 'p1',
        'the match panel lists the bounty by name')
    local left = info.bounties[1].leftMs
    ok(left > 0 and left <= CT.fx.bountyMs, 'with its time left', left)

    gameMs = gameMs + CT.fx.bountyMs
    jobs['terminal.bounty']()
    ok(T.hasBounty(1) == false, 'ten minutes later it is over')
    local d = lastOf(BR.Net.TERMINAL_BOUNTY, 3)
    ok(d and #d.list == 0, 'and one empty list clears every map')
    local n = #eventsOf(BR.Net.TERMINAL_BOUNTY, nil)
    jobs['terminal.bounty']()
    eq(#eventsOf(BR.Net.TERMINAL_BOUNTY, nil), n, 'then nothing more is sent')
    eq(#T.matchInfo(3, gameMs).bounties, 0, 'and the panel lists none')
    local _ = m
end

describe('the bounty: ended early by elimination, and by the match ending')
do
    reset()
    local m = lobby()
    runAt(1, 'scan')
    roster[1].state = BR.PlayerState.DBNO
    gameMs = gameMs + 1000
    jobs['terminal.bounty']()
    ok(T.hasBounty(1) == true, 'downed, the bounty stands')
    roster[1].state = BR.PlayerState.OUT
    gameMs = gameMs + 1000
    jobs['terminal.bounty']()
    ok(T.hasBounty(1) == false, 'eliminated, it ends')
    ok(#lastOf(BR.Net.TERMINAL_BOUNTY, 5).list == 0, 'and the maps are cleared')

    reset()
    m = lobby()
    runAt(1, 'scan')
    m.state = BR.MatchState.ENDED
    jobs['terminal.bounty']()
    ok(T.hasBounty(1) == false and #lastOf(BR.Net.TERMINAL_BOUNTY, 3).list == 0,
        'a match that ended ends its bounties')
end

describe('the bounty: a solo player is a squad of one')
do
    reset()
    local m = newMatch(1)
    player(5, m, nil, SITE)
    player(3, m, 'B', { x = 0.0, y = 0.0 })
    keys[5] = true
    market.wallet[5] = 200
    local r = runAt(5, 'scan')
    ok(r and r.ok, 'a solo player runs Scan')
    eq(noticeIndex('Protect', 5), nil, 'and has no squad to tell')
    ok(#lastOf(BR.Net.TERMINAL_SCAN, 5).list == 1, 'and sees the one opponent')
    ok(#lastOf(BR.Net.TERMINAL_BOUNTY, 3).list == 1, 'who sees the bounty')
end

describe('the match panel: what the open computer shows, and only this player\'s squad')
do
    reset()
    local m = lobby()
    fire(BR.Net.TERMINAL_USE, 1, { terminalId = 'tower' })
    local st = lastOf(BR.Net.TERMINAL_OPEN, 1).state
    eq(st.player, 'p1', 'the gamertag')
    local info = st.match
    ok(info ~= nil, 'a panel, in a match')
    eq(info.tag, BR.MatchTag(1), 'the match tag')
    eq(info.mode, 'squad', 'the mode')
    eq(info.phase, BR.MatchState.PLAYING, 'the phase')
    eq(info.elapsedMs, 125000, 'the match time')
    ok(info.storm and info.storm.stage == 2 and info.storm.stages == #BR.Config.Storm.phases,
        'the storm stage, of how many')
    ok(info.storm.state == BR.StormPhase.HOLDING and info.storm.leftMs == 600000,
        'holding, with the time to the next sweep', info.storm.state .. ' ' .. tostring(info.storm.leftMs))
    eq(info.players, 5, 'players left (the downed count)')
    eq(info.squads, 3, 'squads left (a solo player is one)')
    eq(#info.squad, 2, 'their own squad, and nobody else\'s')
    ok(info.squad[1].name == 'p1' and info.squad[1].me == true and info.squad[2].name == 'p2'
        and info.squad[2].state == 'alive', 'by name and state, themselves marked')
    eq(info.terminals.online, 1, 'one terminal online (the other is outside the storm)')
    eq(info.terminals.total, 2, 'of two')
    roster[2].state = BR.PlayerState.DBNO
    eq(T.matchInfo(1, gameMs).squad[2].state, 'downed', 'a downed mate says so')
    roster[2].state = BR.PlayerState.OUT
    eq(T.matchInfo(1, gameMs).squad[2].state, 'out', 'an eliminated one too')
    eq(T.matchInfo(1, gameMs).players, 4, 'and is no longer counted')
    local _ = m
end

describe('Season 1: the jobs do nothing')
do
    reset()
    lobby()
    runAt(1, 'scan')
    season(1)
    local n = #sent
    gameMs = gameMs + 5000
    jobs['terminal.scan']()
    jobs['terminal.bounty']()
    eq(#sent, n, 'nothing is pushed at Season 1')
    season(2)
end

-- =========================================================================
-- PART C -- Supply drop and Max ammo
-- =========================================================================

describe('Supply drop: at the spot the player picked, sited by the airdrop\'s own rules')
do
    -- ROUND 4 (owner, 2026-10-06): "The supply drop should also allow them to
    -- pick exactly where." The run carries the spot set on the big map, and
    -- the airdrop's own siting finds the spot nearest it.
    local row = T.row('supply_drop')
    ok(row and row.implemented == true and T.FUNCTIONS.supply_drop ~= nil, 'supply_drop is built')
    ok(row.spot == true and (row.options == nil or #row.options == 0), 'run at a picked spot, with no options')
    local PICK = { x = C0.x - 700.0, y = C0.y + 350.0 }
    reset()
    local m = lobby()
    local r = runAt(1, 'supply_drop', nil, PICK)
    ok(r and r.ok == true and r.code == 'done', 'at the spot picked: it runs', r and r.code)
    local call = airdropCalls[#airdropCalls]
    ok(call and call.m == m and call.x == PICK.x and call.y == PICK.y,
        'BR.Airdrop.call is asked for the airdrop spot nearest THE SPOT PICKED')
    eq(keys[1], false, 'the key is spent')

    -- WITHOUT A SPOT, OR WITH ONE THAT IS NOT ONE: bad_option, nothing asked.
    for _, bad in ipairs({
        { label = 'no spot', at = nil },
        { label = 'a spot that is not a table', at = 'here' },
        { label = 'a spot with no y', at = { x = 1.0 } },
        { label = 'a spot that is not a number', at = { x = 'a', y = 1.0 } },
        { label = 'a spot off any map', at = { x = 1e9, y = 0.0 } },
        { label = 'a spot that is not finite', at = { x = 0 / 0, y = 0.0 } },
    }) do
        reset()
        m = lobby()
        r = runAt(1, 'supply_drop', nil, bad.at)
        ok(r and r.code == 'bad_option' and #airdropCalls == 0 and keys[1] == true,
            bad.label .. ': bad_option, nothing asked, nothing spent', r and r.code)
    end
    -- A FUNCTION RUN WITHOUT ONE NEVER TAKES ONE.
    reset()
    m = lobby()
    r = runAt(1, 'max_ammo', nil, PICK)
    ok(r and r.code == 'bad_option' and keys[1] == true, 'a spot sent with Max ammo: bad_option', r and r.code)
    -- THE OLD SITE OPTION IS GONE.
    reset()
    m = lobby()
    r = runAt(1, 'supply_drop', { site = 'terminal' }, PICK)
    ok(r and r.code == 'bad_option' and keys[1] == true, 'the old `site` option: bad_option', r and r.code)

    reset()
    m = lobby()
    m.noSite = true
    fire(BR.Net.TERMINAL_USE, 1, { terminalId = 'tower' })
    local f
    for _, x in ipairs(lastOf(BR.Net.TERMINAL_OPEN, 1).state.functions) do
        if x.id == 'supply_drop' then f = x end
    end
    ok(f and f.available == false and f.reason == 'no_site', 'with no spot inside the next circle it is listed no_site')
    gameMs = gameMs + 1000
    fire(BR.Net.TERMINAL_RUN, 1, { terminalId = 'tower', functionId = 'supply_drop', at = PICK })
    r = lastOf(BR.Net.TERMINAL_RESULT, 1)
    ok(r and r.code == 'no_site' and keys[1] == true and not T.squadUsed(1),
        'and refused no_site, spending nothing', r and r.code)

    reset()
    m = lobby()
    m.storm = nil
    r = runAt(1, 'supply_drop', nil, PICK)
    ok(r and r.code == 'no_storm' and keys[1] == true, 'before the storm: no_storm, nothing spent', r and r.code)

    reset()
    m = lobby()
    m.dropBusy = true
    r = runAt(1, 'supply_drop', nil, PICK)
    ok(r and r.code == 'drop_busy' and #airdropCalls == 0 and keys[1] == true,
        'another drop on its way: drop_busy, nothing spent', r and r.code)

    -- THE DEV COMMAND TAKES THE SPOT AS x= y=.
    reset()
    m = lobby()
    keys[1] = false
    local said = devRun(1, ('supply_drop x=%.1f y=%.1f'):format(PICK.x, PICK.y))
    call = airdropCalls[#airdropCalls]
    ok(said:find('ok (done)', 1, true) ~= nil and call and call.x == PICK.x and call.y == PICK.y,
        '`brterminal run supply_drop x=<n> y=<n>` drops at the spot', said)
    said = devRun(1, 'supply_drop')
    ok(said:find('needs the spot', 1, true) ~= nil, 'and without one says it needs the spot', said)
end

describe('Max ammo: every squadmate still in the fight is filled')
do
    local row = T.row('max_ammo')
    ok(row and row.implemented == true and T.FUNCTIONS.max_ammo ~= nil, 'max_ammo is built')
    reset()
    local m = lobby()
    roster[2].state = BR.PlayerState.DBNO
    -- ROUND 4 (owner, 2026-10-06: "The max ammo tool should apply to the whole
    -- squad, when in squads"): a squadmate standing across the map and one
    -- still in the air are the squad too.
    player(6, m, 'A', { x = C0.x - 3000.0, y = C0.y + 2500.0 })
    player(7, m, 'A', { x = C0.x + 900.0, y = C0.y }, BR.PlayerState.GLIDE)
    filled = { [1] = 30, [2] = 60, [3] = 90, [5] = 40, [6] = 20, [7] = 10 }
    local r = runAt(1, 'max_ammo')
    ok(r and r.ok == true and r.code == 'done', 'it runs', r and r.code)
    ok(filled[1] == 0 and filled[2] == 0, 'the runner and the downed squadmate are filled')
    ok(filled[6] == 0 and filled[7] == 0, 'and the squadmates far away and in the air: the whole squad')
    eq(filled[3], 90, 'another squad is not')
    eq(filled[5], 40, 'nor a solo player')
    eq(r and r.toast, COPY.max_ammo_done, "the runner reads the squad's done line")

    reset()
    lobby()
    player(2, matches[1], 'A', { x = 0.0, y = 0.0 }, BR.PlayerState.OUT)
    filled = { [1] = 0, [2] = 60 }
    r = runAt(1, 'max_ammo')
    ok(r and r.code == 'ammo_full' and keys[1] == true and not T.squadUsed(1),
        'nothing to fill among the living: ammo_full, nothing spent', r and r.code)
    local listed
    for _, x in ipairs(lastOf(BR.Net.TERMINAL_OPEN, 1).state.functions) do
        if x.id == 'max_ammo' then listed = x end
    end
    ok(listed and listed.available == false and listed.reason == 'ammo_full',
        'and the card already said so: listed ammo_full', listed and tostring(listed.reason))
end

-- =========================================================================
-- PART F -- round 2 (owner, 2026-10-05): the Volts, the loading and the
-- squad's words, at a real terminal in a real match
-- =========================================================================

local function useAt(src)
    fire(BR.Net.TERMINAL_USE, src, { terminalId = 'tower' })
    gameMs = gameMs + 1000
end

local function ask(src, id, options, at)
    gameMs = gameMs + 1000
    fire(BR.Net.TERMINAL_RUN, src, { terminalId = 'tower', functionId = id, options = options, at = at })
    return lastOf(BR.Net.TERMINAL_RESULT, src)
end

local function results(src) return #eventsOf(BR.Net.TERMINAL_RESULT, src) end

describe('round 2: a run the balance cannot cover is refused, with nothing spent')
do
    reset()
    lobby()
    market.wallet[1] = 150
    useAt(1)
    local f
    for _, x in ipairs(lastOf(BR.Net.TERMINAL_OPEN, 1).state.functions) do
        if x.id == 'scan' then f = x end
    end
    ok(f and f.available == true, 'Run stays pressable whatever the balance (listed available)')
    eq(lastOf(BR.Net.TERMINAL_OPEN, 1).state.volts, 150, 'the state carries the balance the market shows')
    local r = ask(1, 'scan')
    ok(r and r.ok == false and r.code == 'no_volts', 'Scan at 150 Volts: no_volts', r and r.code)
    ok(r and r.cost == 200 and r.balance == 150, 'with its cost and the balance', r and tostring(r.cost))
    eq(#market.charges, 0, 'the market is never asked')
    ok(keys[1] == true and not T.squadUsed(1) and market.wallet[1] == 150,
        'the key, the squad\'s use and the Volts all stay')
    eq(#timers, 0, 'and nothing loads')
end

describe('round 2: spent exactly, as it is accepted; the effect and the lobby only when it is done')
do
    reset()
    lobby()
    market.wallet[1] = 200
    useAt(1)
    local r = ask(1, 'scan')
    ok(r and r.ok == true and r.code == 'running', 'accepted', r and r.code)
    ok(#market.charges == 1 and market.charges[1].cost == 200 and market.charges[1].src == 1,
        'charged once, 200, through BR.Market.charge')
    eq(market.wallet[1], 0, 'exactly the cost')
    ok(r and r.state.volts == 0, 'the top bar moves at once')
    ok(keys[1] == false and T.squadUsed(1), 'the key and the squad\'s use are spent as it is accepted')
    ok(r and r.runMs >= CT.runMinMs and r.runMs <= CT.runMaxMs, 'and it loads for the server\'s pick')
    eq(noticeIndex('has redeemed their special power', 3), nil, 'nobody hears about it while it loads')
    eq(#eventsOf(BR.Net.TERMINAL_SCAN, 1), 0, 'and the effect has not happened')
    flush()
    r = lastOf(BR.Net.TERMINAL_RESULT, 1)
    ok(r and r.ok == true and r.code == 'done' and r.balance == 0, 'done, with the new balance', r and tostring(r.balance))
    ok(#eventsOf(BR.Net.TERMINAL_SCAN, 1) > 0, 'the effect happened when the loading was over')
    ok(noticeIndex('has redeemed their special power', 3) ~= nil, 'and the lobby heard it then')
    eq(#market.charges, 1, 'one charge, start to finish')
    eq(#market.refunds, 0, 'and nothing given back')
end

describe('round 2: an effect that can no longer happen gives everything back')
do
    reset()
    local m = lobby()
    market.wallet[1] = 500
    useAt(1)
    ask(1, 'scan')
    m.state = BR.MatchState.ENDED
    flush()
    local r = lastOf(BR.Net.TERMINAL_RESULT, 1)
    -- The match ending also closes the session on the next check; the last
    -- word then reaches the player as a toast. Here the check has not run.
    ok(r and r.ok == false and r.code == 'unavailable', 'the match ended while it loaded: unavailable', r and r.code)
    ok(#market.refunds == 1 and market.refunds[1].amount == 200 and market.refunds[1].lic == 'license:1',
        'the 200 Volts are refunded to the account charged')
    eq(market.wallet[1], 500, 'all of them')
    ok(keys[1] == true, 'the key is given back')
    ok(not T.squadUsed(1), 'and the squad\'s use')
    eq(noticeIndex('has redeemed their special power', 3), nil, 'and the lobby is told nothing')
    eq(#eventsOf(BR.Net.TERMINAL_SCAN, 1), 0, 'nothing happened')

    -- A free function: the key and the use come back, no Volts move.
    reset()
    m = lobby()
    useAt(1)
    local r2 = ask(1, 'supply_drop', nil, { x = SITE.x, y = SITE.y })
    ok(r2 and r2.code == 'running', 'Supply drop is accepted')
    m.dropBusy = true
    flush()
    r2 = lastOf(BR.Net.TERMINAL_RESULT, 1)
    ok(r2 and r2.ok == false and r2.code == 'drop_busy', 'another drop appeared while it loaded: drop_busy', r2 and r2.code)
    ok(keys[1] == true and not T.squadUsed(1) and #airdropCalls == 0, 'key and use back, no drop called')
    eq(#market.charges + #market.refunds, 0, 'and a free function never touched the market')
end

describe('round 2: two presses, two players -- never two spends, never a spend without a run')
do
    reset()
    lobby()
    keys[2] = true
    roster[2].pos = { x = SITE.x, y = SITE.y, z = SITE.z }
    market.hold = true
    useAt(1)
    useAt(2)
    local before1 = results(1)
    ask(1, 'scan')
    eq(results(1), before1, 'while the charge is in flight, no answer yet')
    ask(1, 'scan')
    eq(#market.charges, 1, 'a second press by the same player is dropped: one charge')
    local r2 = ask(2, 'scan')
    ok(r2 and r2.ok == false and r2.code == 'unavailable', 'a squadmate\'s run while it is in flight is refused',
        r2 and r2.code)
    eq(#market.charges, 1, 'and is never charged')
    ok(keys[2] == true, 'keeping their key')
    market.pending[1]()
    local r = lastOf(BR.Net.TERMINAL_RESULT, 1)
    ok(r and r.code == 'running', 'the charge landed: accepted')
    r2 = ask(2, 'scan')
    ok(r2 and r2.code == 'squad_used', 'from here the squadmate is refused squad_used', r2 and r2.code)
    flush()
    r = lastOf(BR.Net.TERMINAL_RESULT, 1)
    ok(r and r.code == 'done', 'and the run is done')
    ok(market.wallet[1] == 800 and market.wallet[2] == 1000 and #market.charges == 1,
        'one run, one spend: 200 from the runner, nothing from the squadmate')
end

describe('round 2: a write that fails or cannot be made refuses with nothing spent')
do
    reset()
    lobby()
    market.broken = true
    useAt(1)
    local r = ask(1, 'scan')
    ok(r and r.ok == false and r.code == 'unavailable', 'the write timed out: unavailable', r and r.code)
    ok(keys[1] == true and not T.squadUsed(1) and market.wallet[1] == 1000 and #timers == 0,
        'nothing spent, nothing loads')

    -- THE ROW KNEW BETTER THAN THE CACHE: refused by the condition.
    reset()
    lobby()
    market.hold = true
    useAt(1)
    ask(1, 'scan')
    market.wallet[1] = 100
    market.pending[1]()
    r = lastOf(BR.Net.TERMINAL_RESULT, 1)
    ok(r and r.ok == false and r.code == 'no_volts' and r.balance == 100, 'refused by the row: no_volts, at 100',
        r and r.code)
    ok(keys[1] == true and not T.squadUsed(1), 'and nothing else was spent')

    -- The run can be asked again once it is over.
    market.hold = false
    market.wallet[1] = 1000
    r = ask(1, 'scan')
    ok(r and r.code == 'running', 'a refused run is over: the next one is taken')

    -- NO MARKET ON THIS BUILD: a paid run cannot be paid.
    reset()
    lobby()
    local saved = BR.Market
    BR.Market = nil
    useAt(1)
    r = ask(1, 'scan')
    ok(r and r.code == 'no_volts' and r.balance == 0 and keys[1] == true,
        'no market at all: no Volts to spend, nothing spent', r and r.code)
    BR.Market = saved
end

describe('round 2: the door asked again after the round trip')
do
    reset()
    lobby()
    market.hold = true
    useAt(1)
    ask(1, 'scan')
    keys[1] = false   -- the key went while the charge was in flight
    market.pending[1]()
    local r = lastOf(BR.Net.TERMINAL_RESULT, 1)
    ok(r and r.ok == false and r.code == 'no_key', 'the key went meanwhile: no_key', r and r.code)
    ok(#market.refunds == 1 and market.wallet[1] == 1000, 'and the Volts just charged are refunded')
    ok(not T.squadUsed(1), 'the squad\'s use never spent')
end

describe('round 2: closing, going down or dying while it loads -- the paid run completes')
do
    reset()
    lobby()
    useAt(1)
    ask(1, 'scan')
    fire(BR.Net.TERMINAL_CLOSED, 1, { terminalId = 'tower', why = 'escape' })
    roster[1].state = BR.PlayerState.OUT
    local before = results(1)
    flush()
    eq(results(1), before, 'no answer goes to a computer that has closed')
    ok(#eventsOf(BR.Net.TERMINAL_SCAN, 2) > 0, 'the squad gets its Scan')
    eq(noticeIndex('A new bounty is among us', 3), nil, 'but a runner already out gets no bounty')
    ok(noticeIndex('has redeemed their special power', 3) ~= nil, 'the lobby hears the run')
    local mine = noticesTo(1)
    local last = mine[#mine]
    eq(last and textOf(last), COPY.scan_done .. ' Your new balance is: 800 Volts.',
        'the runner reads the done line and the new balance as a toast')
    eq(#market.refunds, 0, 'nothing is refunded')

    -- Downed is still in the fight: the bounty stands.
    reset()
    lobby()
    useAt(1)
    ask(1, 'scan')
    roster[1].state = BR.PlayerState.DBNO
    flush()
    ok(noticeIndex('A new bounty is among us', 3) ~= nil, 'a downed runner still gets the bounty')
end

describe('round 2: leaving the server while it loads gives everything back')
do
    reset()
    lobby()
    useAt(1)
    ask(1, 'scan')
    roster[1] = nil
    fire('playerDropped', 1)
    flush()
    ok(#market.refunds == 1 and market.refunds[1].lic == 'license:1' and market.refunds[1].amount == 200,
        'the Volts go back to the account')
    ok(keys[1] == true, 'and the key')
    eq(#eventsOf(BR.Net.TERMINAL_SCAN, 2), 0, 'nothing happened')
end

describe('round 2: "squad" only in a squad match -- the notices and the listing')
do
    -- A SQUAD MATCH: the squad lines, and the squad-only functions listed.
    reset()
    local m = lobby()
    ok(T.squadMatch(1) == true, 'a squad-mode match, playing: a squad match')
    m.state = BR.MatchState.WARMUP
    ok(T.squadMatch(1) == false, 'its warmup is not')
    m.state = BR.MatchState.BUS
    ok(T.squadMatch(1) == true, 'its bus is')
    m.state = BR.MatchState.PLAYING
    useAt(1)
    local st = lastOf(BR.Net.TERMINAL_OPEN, 1).state
    eq(st.squadMatch, true, 'the state says so')
    local listed = {}
    for _, x in ipairs(st.functions) do listed[x.id] = x end
    ok(listed.reboot ~= nil and listed.comms_blackout ~= nil, 'the squad-only functions are listed')
    runAt(1, 'storm_reveal')
    local n
    for _, x in ipairs(noticesTo(3)) do
        if (textOf(x) or ''):find('has redeemed', 1, true) then n = x end
    end
    eq(n and textOf(n), 'p1 has redeemed their special power: ' .. COPY.storm_reveal_description,
        'the lobby reads the squad description')

    -- A SOLO MATCH: never the word.
    reset()
    m = newMatch(1)
    m.mode = 'solo'
    player(1, m, nil, SITE)
    player(3, m, nil, { x = 0.0, y = 0.0 })
    keys[1] = true
    market.wallet[1] = 1000
    ok(T.squadMatch(1) == false, 'a solo match is not a squad match')
    useAt(1)
    st = lastOf(BR.Net.TERMINAL_OPEN, 1).state
    eq(st.squadMatch, false, 'and the state says so')
    listed = {}
    for _, x in ipairs(st.functions) do listed[x.id] = x end
    ok(listed.reboot == nil and listed.comms_blackout == nil, 'the squad-only functions are not listed')
    ok(listed.ghost ~= nil, 'Ghost is')
    local r = runAt(1, 'storm_reveal')
    ok(r and r.code == 'done', 'a solo Storm reveal runs')
    for _, x in ipairs(noticesTo(3)) do
        if (textOf(x) or ''):find('has redeemed', 1, true) then n = x end
    end
    eq(n and textOf(n), 'p1 has redeemed their special power: ' .. COPY.storm_reveal_description_solo,
        'the lobby reads the solo description')
    for _, x in ipairs(notices) do
        ok(not (textOf(x) or ''):lower():find('squad', 1, true), ('no toast in a solo match says squad: %s'):format(textOf(x)))
    end
    -- And a refusal said as a toast picks too.
    reset()
    m = newMatch(1)
    m.mode = 'solo'
    player(1, m, nil, SITE)
    keys[1] = true
    filled = { [1] = 0 }
    market.wallet[1] = 1000
    useAt(1)
    ask(1, 'max_ammo')
    local ra = lastOf(BR.Net.TERMINAL_RESULT, 1)
    eq(ra and ra.code, 'ammo_full', 'Max ammo with nothing to fill: ammo_full (the app picks its solo line)')
    fire(BR.Net.TERMINAL_CLOSED, 1, { terminalId = 'tower' })
    -- (a run whose effect fails after the computer closed is said as a toast)
    useAt(1)
    filled = { [1] = 10 }
    ask(1, 'max_ammo')
    fire(BR.Net.TERMINAL_CLOSED, 1, { terminalId = 'tower' })
    filled = { [1] = 0 }
    flush()
    local mine = noticesTo(1)
    eq(mine[#mine] and textOf(mine[#mine]), COPY.ammo_full_solo, 'the toast is the solo line')
end

describe('round 2: bounty_protect is never sent to a player with no squadmates')
do
    reset()
    local m = newMatch(1)
    m.mode = 'solo'
    player(1, m, nil, SITE)
    player(3, m, nil, { x = 0.0, y = 0.0 })
    keys[1] = true
    market.wallet[1] = 1000
    runAt(1, 'scan')
    ok(noticeIndex('A new bounty is among us', 3) ~= nil, 'the lobby hears of the bounty')
    for _, x in ipairs(notices) do
        ok(not (textOf(x) or ''):find('Protect', 1, true), 'nobody is told to protect a solo player')
    end
end

-- =========================================================================
-- PART G -- wave A (owner, 2026-10-06): the functions built one file each,
-- under server/terminalfx/, loaded here from the manifest
-- =========================================================================

--- This player's card for `id` in the state the computer last opened with.
local function listedAs(src, id)
    local d = lastOf(BR.Net.TERMINAL_OPEN, src)
    for _, x in ipairs(d and d.state.functions or {}) do
        if x.id == id then return x end
    end
    return nil
end

--- The last toast this player was sent, as text.
local function lastToast(src)
    local mine = noticesTo(src)
    return mine[#mine] and textOf(mine[#mine]) or nil
end

describe('Field medic: everyone standing in the squad, to full health and full armor')
do
    local row = T.row('field_medic')
    ok(row and row.implemented == true and T.FUNCTIONS.field_medic ~= nil, 'field_medic is built')
    ok(row and (row.options == nil or #row.options == 0), 'and takes no options')
    ok(row and (row.cost or 0) == 0, 'and costs no Volts')
    ok(row and row.quiet == true, 'and is quiet (round 4: "should not notify everyone")')

    reset()
    local m = lobby()
    roster[1].hp, roster[1].armour = 40.0, 0
    roster[2].hp, roster[2].armour = 100.0, 30                    -- full health, armor short
    player(6, m, 'A', { x = C0.x + 60.0, y = C0.y }, BR.PlayerState.DBNO)
    roster[6].hp, roster[6].armour = 20.0, 0                      -- downed: not revived
    player(7, m, 'A', { x = C0.x + 70.0, y = C0.y }, BR.PlayerState.GLIDE)
    roster[7].hp, roster[7].armour = 50.0, 0                      -- in the air: not standing
    player(8, m, 'A', { x = C0.x + 80.0, y = C0.y })              -- standing and full
    roster[3].hp = 10.0                                           -- another squad, under 50
    local r = runAt(1, 'field_medic')
    ok(r and r.ok == true and r.code == 'done', 'it runs', r and r.code)
    local who = {}
    for _, g in ipairs(granted) do who[#who + 1] = g.src end
    eq(table.concat(who, ','), '1,2', 'the runner and the standing squadmate short of armor, and nobody else')
    local fxv = granted[1] and granted[1].effect or {}
    ok(fxv.health == 100.0 and fxv.healthCap == 100.0, 'to full health (the display bar\'s 100)')
    ok(fxv.armour == BR.Config.Match.maxArmour and fxv.armourCap == BR.Config.Match.maxArmour,
        'and full armor (BR.Config.Match.maxArmour)')
    ok(keys[1] == false and T.squadUsed(1), 'the key and the squad\'s use are spent')
    eq(r and r.toast, COPY.field_medic_done, 'the runner reads the squad done line')
end

describe('Field medic: everyone else standing at 50 health or more loses 20 (round 4)')
do
    -- THE OWNER (2026-10-06): "remove 20 health from everyone else in the
    -- match who has at least 50 health".
    eq(CT.fx.medicDrainHp, 20, 'the drain is 20')
    eq(CT.fx.medicDrainFromHp, 50, 'from 50 health up')
    ok(COPY.field_medic_what:find(('at least %d health loses %d health'):format(
        CT.fx.medicDrainFromHp, CT.fx.medicDrainHp), 1, true) ~= nil
        and COPY.field_medic_what_solo:find(('at least %d health loses %d health'):format(
        CT.fx.medicDrainFromHp, CT.fx.medicDrainHp), 1, true) ~= nil,
        'and the page says the same two numbers the server uses')

    reset()
    local m = lobby()
    roster[1].hp = 100.0                                          -- the runner, full
    roster[2].hp = 60.0                                           -- a squadmate at 60: healed, never drained
    roster[3].hp = 50.0                                           -- another squad, exactly 50
    roster[4].hp = 90.0                                           -- downed (lobby): never drained
    roster[5].hp = 49.0                                           -- solo, just under
    player(6, m, 'C', { x = 0.0, y = 0.0 })                       -- a third squad, full
    player(7, m, 'C', { x = 5.0, y = 0.0 }, BR.PlayerState.GLIDE) -- in the air
    roster[7].hp = 100.0
    player(8, m, 'C', { x = 9.0, y = 0.0 }, BR.PlayerState.OUT)   -- out
    roster[8].hp = 100.0
    local r = runAt(1, 'field_medic')
    ok(r and r.ok == true and r.code == 'done', 'it runs', r and r.code)
    local who = {}
    for _, d in ipairs(drained) do who[#who + 1] = ('%d:%d'):format(d.src, d.amount) end
    eq(table.concat(who, ' '), '3:20 6:20',
        'everyone standing outside the squad at 50 or more loses 20: exactly 50 counts, 49 does not; '
        .. 'nobody downed, in the air or out; never the squad')
    eq(roster[3].hp, 30.0, '50 less 20 is 30: never a knock')
    eq(granted[1] and granted[1].src, 2, 'the squadmate at 60 is healed')
    eq(#granted, 1, 'and only them')

    -- A SQUAD WITH NOTHING TO HEAL STILL RUNS, FOR THE DRAIN.
    reset()
    lobby()
    roster[3].hp = 40.0
    roster[5].hp = 80.0
    local r2 = runAt(1, 'field_medic')
    ok(r2 and r2.code == 'done' and #granted == 0 and #drained == 1 and drained[1].src == 5,
        'everyone in the squad full: it still runs, and drains the others', r2 and r2.code)
end

describe('Field medic: the lobby is not told (round 4: "should not notify everyone")')
do
    reset()
    local m = lobby()
    roster[1].hp = 40.0
    roster[3].hp = 100.0
    local r = runAt(1, 'field_medic')
    ok(r and r.code == 'done', 'it runs', r and r.code)
    for src = 1, 5 do
        eq(noticeIndex('has redeemed their special power', src), nil, ('p%d hears no notice_action'):format(src))
    end
    ok(noticeIndex('has gained access to a match terminal', 3) ~= nil,
        'the access notice when the terminal opened still went out (the owner\'s own rule)')
    ok(COPY.field_medic_description == nil and COPY.field_medic_description_solo == nil,
        'and there is no description for a notice to carry')
    eq(COPY.field_medic_notified, 'Nobody', 'its page says who is told: nobody')
    -- ANOTHER FUNCTION STILL TELLS THE LOBBY: quiet is the row's, not the door's.
    reset()
    m = lobby()
    filled = { [1] = 30 }
    runAt(1, 'max_ammo')
    ok(noticeIndex('has redeemed their special power', 3) ~= nil, 'Max ammo still tells the lobby')
    local _ = m
end

describe('Field medic: nothing at all to change is refused, spending nothing')
do
    reset()
    local m = lobby()
    player(6, m, 'A', { x = C0.x + 60.0, y = C0.y }, BR.PlayerState.DBNO)
    roster[6].hp = 15.0                       -- the only one hurt is downed
    for _, s in ipairs({ 3, 5 }) do roster[s].hp = 49.0 end -- nobody else at 50 or more
    roster[4].hp = 100.0                      -- downed (lobby): no drain
    useAt(1)
    local f = listedAs(1, 'field_medic')
    ok(f and f.available == false and f.reason == 'health_full',
        'every standing squadmate full and nobody else at 50: the card says health_full', f and tostring(f.reason))
    local r = ask(1, 'field_medic')
    ok(r and r.ok == false and r.code == 'health_full', 'and a run is refused health_full', r and r.code)
    eq(r and r.toast, COPY.health_full, 'in the squad line')
    ok(keys[1] == true and not T.squadUsed(1) and #granted == 0 and #drained == 0 and #timers == 0,
        'the key and the use stay, nobody is touched, nothing loads')

    -- ONE OTHER PLAYER AT 50: available.
    roster[5].hp = 50.0
    useAt(1)
    f = listedAs(1, 'field_medic')
    ok(f and f.available == true, 'one other player at 50: available', f and tostring(f.reason))

    -- THE END OF THE RUN: something to change when asked, nothing when the
    -- loading is over.
    reset()
    lobby()
    roster[1].hp = 55.0
    for _, s in ipairs({ 3, 5 }) do roster[s].hp = 30.0 end
    useAt(1)
    r = ask(1, 'field_medic')
    ok(r and r.code == 'running', 'hurt: accepted', r and r.code)
    roster[1].hp = 100.0                      -- healed meanwhile
    flush()
    r = lastOf(BR.Net.TERMINAL_RESULT, 1)
    ok(r and r.ok == false and r.code == 'health_full', 'nothing left by the end of the load: health_full', r and r.code)
    ok(keys[1] == true and not T.squadUsed(1) and #granted == 0 and #drained == 0,
        'and the key and the use are given back')

    -- THE MATCH ENDING MID-LOAD.
    reset()
    m = lobby()
    roster[1].hp = 55.0
    useAt(1)
    ask(1, 'field_medic')
    m.state = BR.MatchState.ENDED
    flush()
    r = lastOf(BR.Net.TERMINAL_RESULT, 1)
    ok(r and r.code == 'unavailable' and keys[1] == true and #granted == 0 and #drained == 0,
        'a match that ended mid-load heals and drains nobody and gives everything back', r and r.code)
end

describe('Field medic: a solo player hears no squad, and the dev command runs it')
do
    reset()
    local m = newMatch(1)
    m.mode = 'solo'
    player(1, m, nil, SITE)
    keys[1] = true
    useAt(1)
    local r = ask(1, 'field_medic')
    eq(r and r.toast, COPY.health_full_solo, 'full and alone: the solo refusal')
    roster[1].armour = 0
    player(2, m, nil, { x = 0.0, y = 0.0 })
    r = runAt(1, 'field_medic')
    ok(r and r.code == 'done' and #granted == 1 and granted[1].src == 1, 'short of armor: healed')
    ok(#drained == 1 and drained[1].src == 2, 'and the other solo player drained')
    eq(r and r.toast, COPY.field_medic_done_solo, 'and told in the solo line')
    for _, x in ipairs(notices) do
        ok(not (textOf(x) or ''):lower():find('squad', 1, true), ('no solo toast says squad: %s'):format(textOf(x)))
    end

    -- `brterminal run field_medic`: the effect, no key, nothing spent.
    reset()
    lobby()
    roster[2].hp = 30.0
    keys[1] = false
    local said = devRun(1, 'field_medic')
    ok(said:find('ok (done)', 1, true) ~= nil and #granted == 1 and granted[1].src == 2,
        'the dev command heals the squad without a key', said)
    ok(#drained == 2 and drained[1].src == 3 and drained[2].src == 5, 'and drains the others', #drained)
    ok(not T.squadUsed(1), 'and spends nothing')
    roster[1].matchId = nil
    said = devRun(1, 'field_medic')
    ok(said:find('refused (unavailable)', 1, true) ~= nil, 'and outside a match it says unavailable', said)
end

--- Put a weapon in `src`'s slot (Disarm's inventories).
local function arm(src, slot, item, rarity)
    local inv = BR.Inv.of(src)
    local w = BR.Config.WeaponById[item]
    inv.slots[slot] = { item = item, kind = w.melee and BR.ItemKind.WEAPON
                            or (w.maxStack and BR.ItemKind.THROWABLE) or BR.ItemKind.WEAPON,
                        rarity = rarity or w.rarity, count = 1 }
end

describe('Disarm: the one ranking -- highest rarity, then most damage, then the lower slot')
do
    local row = T.row('disarm')
    ok(row and row.implemented == true and T.FUNCTIONS.disarm ~= nil, 'disarm is built')
    ok(row and row.cost == 200, 'and costs 200 Volts')
    local W = BR.Config.WeaponById
    local function stack(item, rarity, kind)
        return { item = item, kind = kind or BR.ItemKind.WEAPON, rarity = rarity or W[item].rarity, count = 1 }
    end
    local P = T.disarmPick
    eq(P({ stack('pumpshotgun'), stack('pistol', BR.Rarity.LEGENDARY) }), 2,
        'a legendary pistol over an uncommon pump shotgun: rarity first, whatever the damage')
    eq(P({ stack('assaultrifle'), stack('revolver') }), 2,
        'two rares: the one with more damage (revolver 97 over assault rifle 33)')
    eq(P({ stack('revolver'), stack('assaultrifle') }), 1, 'whichever slot it is in')
    eq(P({ false, stack('carbinerifle'), stack('carbinerifle') }), 2, 'a tie on both: the lower slot')
    eq(P({ stack('carbinerifle', BR.Rarity.LEGENDARY), stack('specialcarbine') }), 1,
        'the STACK\'s rarity, not the row\'s: a legendary carbine over an epic special carbine')
    eq(P({ stack('carbinerifle', BR.Rarity.LEGENDARY), stack('militaryrifle') }), 2,
        'two legendaries: the military rifle\'s 42 over the carbine\'s 32')
    eq(P({ stack('militaryrifle', BR.Rarity.LEGENDARY), stack('railgun'), stack('grenadelauncher') }), 2,
        'a launcher is a weapon too, and a legendary one: the railgun\'s 110 over the military rifle\'s 42 '
        .. 'and the grenade launcher\'s 85 -- so its anticheat excuse has to cover NOT_THROWN')
    eq(P({ false, false, stack('bat') }), 3, 'a melee weapon is a weapon')
    eq(P({ stack('grenade', nil, BR.ItemKind.THROWABLE), stack('bat') }), 2,
        'a throwable is not, whatever its rarity')
    eq(P({ stack('grenade', nil, BR.ItemKind.THROWABLE) }), nil, 'so a bag of grenades has nothing to take')
    eq(P({ false, false }), nil, 'and nor does an empty one')
    eq(P({ { item = 'bandage', kind = BR.ItemKind.CONSUMABLE, rarity = 5, count = 1 } }), nil,
        'nor a consumable')
end

describe('Disarm: every player still in the match outside the runner\'s squad loses their most powerful weapon')
do
    reset()
    local m = lobby()
    arm(1, 1, 'pistol')
    arm(1, 2, 'assaultrifle')                       -- the runner's rare rifle: kept
    arm(2, 1, 'pumpshotgun')                        -- their squadmate's: kept
    arm(3, 2, 'carbinerifle')                       -- the other squad, standing
    arm(4, 3, 'smg')                                -- a downed opponent
    arm(4, 1, 'microsmg')
    arm(5, 2, 'bat')                                -- the solo player's only weapon
    player(6, m, 'C', { x = 0.0, y = 0.0 }, BR.PlayerState.OUT)
    arm(6, 1, 'militaryrifle')                      -- out: not in the match any more
    local r = runAt(1, 'disarm')
    ok(r and r.ok == true and r.code == 'done', 'it runs', r and r.code)
    local took = {}
    for _, x in ipairs(revoked) do took[#took + 1] = ('%d:%d:%s'):format(x.src, x.slot, x.item) end
    eq(table.concat(took, ' '), '3:2:carbinerifle 4:3:smg 5:2:bat',
        'one weapon from each armed player outside the squad still in the fight, the best of each')
    ok(invs[1].slots[2] and invs[1].slots[2].item == 'assaultrifle'
        and invs[1].slots[1] and invs[1].slots[1].item == 'pistol', 'the runner keeps every weapon')
    ok(invs[2].slots[1] and invs[2].slots[1].item == 'pumpshotgun', 'and so does their squadmate')
    ok(invs[4].slots[1] and invs[4].slots[1].item == 'microsmg', 'the downed player keeps their micro SMG')
    ok(invs[6].slots[1] and invs[6].slots[1].item == 'militaryrifle', 'an eliminated player is not touched')
    eq(revoked[1] and revoked[1].grace, CT.fx.disarmGraceMs, 'through BR.Inv.revoke, with the configured grace')
    ok(market.charges[1] and market.charges[1].cost == 200 and market.wallet[1] == 800, '200 Volts spent')
    ok(noticeIndex('has redeemed their special power', 3) ~= nil, 'and the lobby is told')
    eq(r and r.toast, COPY.disarm_done .. ' Your new balance is: 800 Volts.', 'the done line and the balance')
    ok(not COPY.disarm_risks and not COPY.disarm_risks_solo,
        'the page no longer says the squad loses its weapons (no disarm_risks)')
    ok(COPY.disarm_what:find('outside your squad', 1, true) ~= nil
        and COPY.disarm_affects:find('outside your squad', 1, true) ~= nil
        and not COPY.disarm_affects:find('included', 1, true), 'its page says who is spared')

    -- A SOLO RUNNER IS A SQUAD OF ONE: only they are spared.
    reset()
    m = newMatch(1)
    m.mode = 'solo'
    player(1, m, nil, SITE)
    player(2, m, nil, { x = C0.x + 40.0, y = C0.y })
    keys[1], market.wallet[1] = true, 1000
    arm(1, 1, 'revolver')
    arm(2, 1, 'revolver')
    r = runAt(1, 'disarm')
    ok(r and r.code == 'done' and #revoked == 1 and revoked[1].src == 2, 'solo: the other player loses theirs',
        r and r.code)
    ok(invs[1].slots[1] and invs[1].slots[1].item == 'revolver', 'and the runner keeps their own')
    eq(r and r.toast, COPY.disarm_done_solo .. ' Your new balance is: 800 Volts.', 'in the solo line')
end

describe('Disarm: nobody armed outside the squad is refused, spending nothing -- the Volts included')
do
    reset()
    lobby()
    useAt(1)
    local f = listedAs(1, 'disarm')
    ok(f and f.available == false and f.reason == 'no_weapons', 'nobody armed: the card says no_weapons',
        f and tostring(f.reason))
    local r = ask(1, 'disarm')
    ok(r and r.ok == false and r.code == 'no_weapons', 'a run is refused no_weapons', r and r.code)
    eq(r and r.toast, COPY.no_weapons, 'in its line')
    ok(#market.charges == 0 and market.wallet[1] == 1000 and keys[1] == true and not T.squadUsed(1),
        'the market is never asked; the key and the use stay')

    -- ONLY THE SQUAD ARMED: nothing to take.
    arm(1, 1, 'carbinerifle')
    arm(2, 2, 'heavyshotgun')
    useAt(1)
    eq(listedAs(1, 'disarm').reason, 'no_weapons', 'only the runner\'s own squad armed: still no_weapons')
    r = ask(1, 'disarm')
    ok(r and r.code == 'no_weapons' and #revoked == 0 and #market.charges == 0,
        'and a run is refused, spending nothing and taking nothing', r and r.code)

    -- A GRENADE IS NOT A WEAPON (it is a throwable): still nothing to take.
    arm(3, 1, 'grenade')
    useAt(1)
    eq(listedAs(1, 'disarm').reason, 'no_weapons', 'a bag of grenades does not make a target')

    -- A SOLO PLAYER ALONE ARMED: the solo line.
    reset()
    local m = newMatch(1)
    m.mode = 'solo'
    player(1, m, nil, SITE)
    player(2, m, nil, { x = C0.x + 40.0, y = C0.y })
    keys[1], market.wallet[1] = true, 1000
    arm(1, 1, 'revolver')
    useAt(1)
    r = ask(1, 'disarm')
    ok(r and r.code == 'no_weapons', 'solo, only the runner armed: no_weapons', r and r.code)
    eq(r and r.toast, COPY.no_weapons_solo, 'in the solo line')

    -- THE END OF THE RUN: armed when asked, nobody armed when the load is over.
    reset()
    lobby()
    arm(3, 1, 'carbinerifle')
    arm(1, 1, 'carbinerifle')                   -- the runner's own: never a target
    useAt(1)
    r = ask(1, 'disarm')
    ok(r and r.code == 'running' and market.wallet[1] == 800, 'armed: accepted, 200 Volts charged', r and r.code)
    invs[3].slots[1] = false                    -- dropped meanwhile
    flush()
    r = lastOf(BR.Net.TERMINAL_RESULT, 1)
    ok(r and r.ok == false and r.code == 'no_weapons', 'disarmed by the end of the load: no_weapons', r and r.code)
    ok(market.wallet[1] == 1000 and #market.refunds == 1 and keys[1] == true and not T.squadUsed(1),
        'the Volts, the key and the use all come back')
    eq(#revoked, 0, 'and nothing was taken')
end

describe('Disarm: the dev command takes the weapons and charges nothing')
do
    reset()
    lobby()
    keys[1] = false
    arm(3, 2, 'heavyshotgun')
    local said = devRun(1, 'disarm')
    ok(said:find('ok (done)', 1, true) ~= nil and #revoked == 1 and revoked[1].src == 3,
        'brterminal run disarm', said)
    ok(#market.charges == 0 and not T.squadUsed(1), 'no Volts, no use')
end

local function scanIds(src)
    local d = lastOf(BR.Net.TERMINAL_SCAN, src)
    local ids = {}
    for _, p in ipairs(d and d.list or {}) do ids[#ids + 1] = p.s end
    return table.concat(ids, ',')
end

describe('Ghost: the squad drops off other squads\' Scan at once, and comes back when it ends')
do
    local row = T.row('ghost')
    ok(row and row.implemented == true and T.FUNCTIONS.ghost ~= nil, 'ghost is built')
    reset()
    local m = lobby()
    runAt(1, 'scan')
    eq(scanIds(1), '3,4,5', 'A\'s Scan shows B and the solo player')
    keys[3] = true
    roster[3].pos = { x = SITE.x, y = SITE.y, z = SITE.z }
    local r = runAt(3, 'ghost', { duration = '120' })
    ok(r and r.code == 'done', 'B runs Ghost, 2 minutes', r and r.code)
    eq(scanIds(1), '5', 'and drops off A\'s Scan at once -- both of B, the downed one too')
    eq(scanIds(2), '5', 'for all of A')
    ok(T.hidden(m, 'squad:B', gameMs) and not T.hidden(m, 'squad:A', gameMs), 'B is hidden, A is not')
    eq(r and r.toast, COPY.ghost_done, 'the squad done line')

    -- 119 s on, still hidden; 120 s, back on the next push.
    local t0 = gameMs
    gameMs = t0 + 119000
    jobs['terminal.ghost']()
    jobs['terminal.scan']()
    eq(scanIds(1), '5', 'still hidden at 1:59')
    gameMs = t0 + 120000
    jobs['terminal.ghost']()
    jobs['terminal.scan']()
    eq(scanIds(1), '3,4,5', 'and back on A\'s Scan when the two minutes are up')
    ok(m.terminalFx.ghosts['squad:B'] == nil, 'the record is gone')
end

describe('Ghost: a bounty marker on the squad is hidden too; the squad\'s own view is not')
do
    reset()
    local m = lobby()
    runAt(1, 'scan')                                   -- p1, squad A, has the bounty
    ok(#lastOf(BR.Net.TERMINAL_BOUNTY, 3).list == 1, 'B sees A\'s bounty')
    local said = devRun(1, 'ghost duration=240')
    ok(said:find('ok (done)', 1, true) ~= nil, 'A goes dark (brterminal run ghost duration=240)', said)
    ok(#lastOf(BR.Net.TERMINAL_BOUNTY, 3).list == 0 and #lastOf(BR.Net.TERMINAL_BOUNTY, 5).list == 0,
        'the bounty marker leaves every other map at once')
    ok(T.hasBounty(1), 'the bounty itself stands (its squad\'s beacon still carries it)')
    local info = T.matchInfo(3, gameMs)
    ok(info.bounties and #info.bounties == 1, 'and the match panel still lists it: the lobby was told')
    gameMs = gameMs + 1000
    local n = #eventsOf(BR.Net.TERMINAL_BOUNTY, 3)
    jobs['terminal.bounty']()
    eq(#eventsOf(BR.Net.TERMINAL_BOUNTY, 3), n, 'and nothing more is pushed while it is hidden')
    eq(scanIds(1), '3,4,5', 'A\'s own Scan is untouched: Ghost hides A from others, not others from A')

    -- FOUR MINUTES, THEN THE BOUNTY'S MARKER IS BACK.
    gameMs = gameMs + 240000
    jobs['terminal.ghost']()
    jobs['terminal.bounty']()
    ok(#lastOf(BR.Net.TERMINAL_BOUNTY, 3).list == 1, 'four minutes on, the marker is back on B\'s map')
    local _ = m
end

describe('Ghost: the match ending, Season 1, a solo player, the predicate itself')
do
    reset()
    local m = lobby()
    devRun(3, 'ghost')
    ok(T.hidden(m, 'squad:B', gameMs), 'hidden in a match being played')
    m.state = BR.MatchState.ENDED
    ok(not T.hidden(m, 'squad:B', gameMs), 'not once the match is over')
    m.state = BR.MatchState.PLAYING
    ok(not T.hidden(m, nil, gameMs) and not T.hidden(nil, 'squad:B', gameMs), 'nothing for no squad or no match')
    season(1)
    ok(not T.hidden(m, 'squad:B', gameMs), 'nobody is hidden off Season 2')
    jobs['terminal.ghost']()
    ok(m.terminalFx.ghosts == nil, 'and the ghosts are forgotten')
    season(2)
    ok(not T.hidden(m, 'squad:B', gameMs), 'so Season 2 coming back does not bring it back')

    reset()
    m = newMatch(1)
    m.mode = 'solo'
    player(1, m, nil, SITE)
    keys[1] = true
    local r = runAt(1, 'ghost', { duration = '240' })
    eq(r and r.toast, COPY.ghost_done_solo, 'a solo player reads the solo done line')
    ok(T.hidden(m, 'solo:1', gameMs + 239000) and not T.hidden(m, 'solo:1', gameMs + 240000),
        'hidden for exactly the 4 minutes chosen')
    -- A SECOND, SHORTER GHOST (only the dev command can) never cuts the first.
    local ends = gameMs + 240000
    devRun(1, 'ghost duration=120')
    ok(T.hidden(m, 'solo:1', ends - 1) and not T.hidden(m, 'solo:1', ends),
        'a 2-minute Ghost over a 4-minute one keeps the four')
end

--- Give `src` this many eliminations, reached at `at`.
local function killsOf(src, n, at)
    roster[src].kills = n
    roster[src].killsAt = at
end

describe('Contract: the one rule -- most eliminations outside the squad, a tie to whoever got there first')
do
    local row = T.row('contract')
    ok(row and row.implemented == true and T.FUNCTIONS.contract ~= nil, 'contract is built')
    ok(row and (row.options == nil or #row.options == 0), 'and takes no options')
    reset()
    local m = lobby()
    local P = function() return T.contractPick(m, 'squad:A') end
    eq(P(), nil, 'nobody with an elimination: nobody')
    killsOf(5, 1, 5000)
    eq(P(), 5, 'one elimination is enough')
    killsOf(3, 2, 9000)
    eq(P(), 3, 'the most eliminations wins')
    killsOf(4, 2, 8000)
    eq(P(), 4, 'a tie goes to whoever reached it first (the downed one counts: still in the fight)')
    killsOf(3, 2, 8000)
    eq(P(), 3, 'reached in the same millisecond: the lower server id')
    killsOf(2, 9, 1000)
    killsOf(1, 9, 1000)
    eq(P(), 3, 'the runner\'s own squad is never the target, however many it has')
    roster[3].state = BR.PlayerState.OUT
    eq(P(), 4, 'an eliminated player is not')
    roster[4].kills = 3
    roster[4].killsAt = 99999
    eq(P(), 4, 'more kills beats an earlier time')
    roster[4].killsAt = nil
    killsOf(5, 3, 5)
    eq(P(), 5, 'a count with no time on it loses the tie')
    eq(T.contractPick(m, 'squad:B'), 1, 'and B\'s contract finds A\'s top player')
end

describe('Contract: the bounty, ten minutes, in the owner\'s own words to the lobby and the target\'s squad')
do
    -- ROUND 4 (owner, 2026-10-06): "The contract bounty should last 10
    -- minutes, and cannot land on a player in the same squad as the user."
    reset()
    local m = lobby()
    killsOf(3, 2, 9000)
    killsOf(4, 2, 8000)
    killsOf(5, 1, 100)
    killsOf(2, 9, 50)                                -- the runner's squadmate tops the match
    local r = runAt(1, 'contract')
    ok(r and r.ok == true and r.code == 'done', 'it runs', r and r.code)
    ok(T.hasBounty(4) and not T.hasBounty(3), 'the bounty is on p4, who reached two first')
    ok(not T.hasBounty(2) and not T.hasBounty(1), "never on the runner's own squad, however many it has")
    local action = noticeIndex('has redeemed their special power', 5)
    local new = noticeIndex('A new bounty is among us', 5)
    ok(action and new and action < new, 'the lobby hears the redemption, then the owner\'s bounty line')
    for _, src in ipairs({ 1, 2, 3, 4, 5 }) do
        ok(noticeIndex('A new bounty is among us', src) ~= nil, ('p%d hears the bounty'):format(src))
    end
    local protect = 'Protect p4! They\'ve got a bounty for the next 10 minutes.'
    ok(noticeIndex(protect, 3) ~= nil, "the target's squadmate reads the owner's bounty_protect, the name filled")
    for _, src in ipairs({ 1, 2, 4, 5 }) do
        eq(noticeIndex('Protect p4!', src), nil, ('p%d does not'):format(src))
    end
    for _, src in ipairs({ 1, 2, 3, 4, 5 }) do
        eq(noticeIndex('contract on', src), nil, ('p%d reads no contract line of its own (they are gone)'):format(src))
    end
    ok(COPY.contract_protect == nil and COPY.contract_target == nil and CT.fx.contractMs == nil,
        'contract_protect, contract_target and fx.contractMs are gone')

    -- ON EVERY MAP OUTSIDE THE TARGET'S SQUAD (their squad reads the beacon).
    for _, src in ipairs({ 1, 2, 5 }) do
        local d = lastOf(BR.Net.TERMINAL_BOUNTY, src)
        ok(d and #d.list == 1 and d.list[1].s == 4, ('p%d is sent where the target is'):format(src))
    end
    local d3 = lastOf(BR.Net.TERMINAL_BOUNTY, 3)
    ok(d3 == nil or #d3.list == 0, 'the target\'s squad is not (the beacon carries it)')
    local info = T.matchInfo(1, gameMs)
    ok(info.bounties[1] and info.bounties[1].name == 'p4' and info.bounties[1].leftMs == CT.fx.bountyMs,
        'the panel lists it with the owner\'s ten minutes')
    eq(CT.fx.bountyMs, 600000, '"a bounty for 10 minutes"')
    ok(COPY.contract_what:find('for 10 minutes', 1, true) ~= nil
        and COPY.contract_what_solo:find('for 10 minutes', 1, true) ~= nil
        and COPY.contract_duration == '10 minutes', 'and its page says ten')
    for k, v in pairs(COPY) do
        if k:sub(1, 9) == 'contract_' then
            ok(not v:find('5 minutes', 1, true), ('%s says nothing of five minutes'):format(k))
        end
    end

    -- TEN MINUTES.
    gameMs = gameMs + CT.fx.bountyMs - 1000
    jobs['terminal.bounty']()
    ok(T.hasBounty(4), 'still on at 9:59')
    gameMs = gameMs + 1000
    jobs['terminal.bounty']()
    ok(not T.hasBounty(4) and #lastOf(BR.Net.TERMINAL_BOUNTY, 1).list == 0, 'over at 10:00, every map cleared')

    -- THE MATCH ENDING, AND SEASON 1, END A CONTRACT LIKE ANY BOUNTY.
    reset()
    m = lobby()
    killsOf(3, 1, 100)
    runAt(1, 'contract')
    ok(T.hasBounty(3), 'a fresh contract')
    m.state = BR.MatchState.ENDED
    jobs['terminal.bounty']()
    ok(not T.hasBounty(3) and #lastOf(BR.Net.TERMINAL_BOUNTY, 1).list == 0, 'ended with the match, maps cleared')
    reset()
    m = lobby()
    killsOf(3, 1, 100)
    runAt(1, 'contract')
    season(1)
    local n = #sent
    gameMs = gameMs + 1000
    jobs['terminal.bounty']()
    eq(#sent, n, 'off Season 2, nothing more is pushed')
    season(2)
end

describe('Contract: a Scan bounty already running restarts its ten; Ghost hides the contract too')
do
    reset()
    local m = lobby()
    killsOf(3, 4, 1000)
    T.startBounty(m, 3, gameMs)                      -- p3 ran Scan: ten minutes
    gameMs = gameMs + 60000
    runAt(1, 'contract')
    local b = m.terminalFx.bounties[3]
    eq(b and b.untilAt, gameMs + CT.fx.bountyMs,
        'a contract on a player with nine minutes of bounty left gives them ten again')
    local untilAt = b.untilAt
    gameMs = gameMs + 1000
    T.startBounty(m, 3, gameMs - 700000)             -- a bounty that would end sooner
    eq(m.terminalFx.bounties[3].untilAt, untilAt, 'and a shorter clock never shortens one still running')

    devRun(3, 'ghost')
    ok(#lastOf(BR.Net.TERMINAL_BOUNTY, 1).list == 0, 'and B under Ghost: the contract\'s marker goes too')
end

describe('Contract: nobody to put it on is refused, spending nothing')
do
    reset()
    lobby()
    killsOf(2, 5, 100)                               -- only the runner's own squad has any
    useAt(1)
    local f = listedAs(1, 'contract')
    ok(f and f.available == false and f.reason == 'no_target', 'the card says no_target', f and tostring(f.reason))
    local r = ask(1, 'contract')
    ok(r and r.code == 'no_target' and r.toast == COPY.no_target, 'a run is refused, in the squad line', r and r.code)
    ok(keys[1] == true and not T.squadUsed(1), 'nothing spent')

    -- THE END OF THE RUN: the only target eliminated during the load.
    reset()
    local m = lobby()
    killsOf(3, 1, 100)
    useAt(1)
    r = ask(1, 'contract')
    ok(r and r.code == 'running', 'accepted', r and r.code)
    roster[3].state = BR.PlayerState.OUT
    flush()
    r = lastOf(BR.Net.TERMINAL_RESULT, 1)
    ok(r and r.code == 'no_target' and keys[1] == true and not T.squadUsed(1),
        'nobody left by the end of the load: given back', r and r.code)
    eq(noticeIndex('A new bounty is among us', 5), nil, 'and nobody is told of a bounty')

    -- ...AND WHEN SOMEBODY ELSE QUALIFIES BY THEN, THE CONTRACT IS THEIRS.
    reset()
    m = lobby()
    killsOf(3, 2, 100)
    killsOf(5, 1, 50)
    useAt(1)
    ask(1, 'contract')
    roster[3].state = BR.PlayerState.OUT
    flush()
    ok(T.hasBounty(5), 'the target eliminated during the load: the next one is chosen when it runs')
    local _ = m

    -- SOLO: never "squad".
    reset()
    m = newMatch(1)
    m.mode = 'solo'
    player(1, m, nil, SITE)
    keys[1] = true
    useAt(1)
    r = ask(1, 'contract')
    eq(r and r.toast, COPY.no_target_solo, 'alone: the solo refusal')
    player(3, m, nil, { x = 0.0, y = 0.0 })
    killsOf(3, 1, 100)
    r = runAt(1, 'contract')
    eq(r and r.toast, COPY.contract_done, 'and with a target, done')
    for _, x in ipairs(notices) do
        ok(not (textOf(x) or ''):find('Protect', 1, true), 'nobody is told to protect a solo player')
    end

    -- THE DEV COMMAND.
    reset()
    lobby()
    keys[1] = false
    killsOf(5, 2, 100)
    local said = devRun(1, 'contract')
    ok(said:find('ok (done)', 1, true) ~= nil and T.hasBounty(5), 'brterminal run contract', said)
end

-- =========================================================================
-- PART H -- wave C (owner, 2026-10-06): EMP, Comms blackout and Reboot, one
-- file each under server/terminalfx/, loaded here from the manifest
-- =========================================================================

-- ── EMP (round 4): a match-wide fact about drivers, pushed to every player ──

--- The last TERMINAL_EMP `src` was sent, or nil.
local function empTo(src) return lastOf(BR.Net.TERMINAL_EMP, src) end

describe('EMP: registered, built, no options, three minutes (round 4)')
do
    local row = T.row('emp')
    ok(row and row.implemented == true and T.FUNCTIONS.emp ~= nil, 'emp is built')
    ok(row and (row.cost or 0) == 0, 'and costs no Volts')
    ok(row and (row.options == nil or #row.options == 0), 'and takes no options (the radius and duration are gone)')
    eq(CT.fx.empMs, 180000, '"This should last for 3 minutes"')
    ok(COPY.emp_duration == '3 minutes' and COPY.emp_what:find('For 3 minutes', 1, true) == 1
        and COPY.emp_what_solo:find('For 3 minutes', 1, true) == 1, 'and its page says three')
    ok(CT.fx.empBag == nil and COPY.emp_opt_radius == nil and COPY.emp_opt_duration == nil
        and COPY.emp_risks == nil and COPY.emp_risks_solo == nil,
        'nothing of wave C\'s radius left: no bag, no option lines, no risks saying the squad stalls too')
    for k, v in pairs(COPY) do
        if k:sub(1, 4) == 'emp_' then
            ok(not v:lower():find('radius', 1, true) and not v:find('terminal', 1, true),
                ('%s says nothing of a radius or a terminal'):format(k))
        end
    end
end

describe('EMP: every player outside the runner\'s squad stalls whatever they drive, for 3 minutes')
do
    reset()
    local m = lobby()
    local r = runAt(1, 'emp')
    ok(r and r.ok == true and r.code == 'done', 'it runs', r and r.code)
    eq(r and r.toast, COPY.emp_done, 'the done line')
    ok(keys[1] == false and T.squadUsed(1), 'the key and the squad\'s use are spent')
    ok(noticeIndex('has redeemed their special power', 3) ~= nil, 'the lobby is told')
    for _, src in ipairs({ 3, 4, 5 }) do
        local d = empTo(src)
        ok(d and d.matchId == m.id and d.leftMs == CT.fx.empMs and d.liveMs == CT.fx.empMs,
            ('p%d (another squad, solo, downed alike) is told their driving stalls for three minutes'):format(src), d)
        eq(T.empFor(m, src, gameMs), CT.fx.empMs, ('and the predicate agrees for p%d'):format(src))
    end
    for _, src in ipairs({ 1, 2 }) do
        local d = empTo(src)
        ok(d and d.leftMs == nil and d.liveMs == CT.fx.empMs,
            ('p%d (the runner\'s squad) is told an EMP lasts, and that their driving does not stall'):format(src), d)
        eq(T.empFor(m, src, gameMs), nil, ('the predicate spares p%d'):format(src))
    end

    -- THE END: three minutes, then everyone is told it is over.
    local t0 = gameMs
    gameMs = t0 + CT.fx.empMs - 1
    local n = #eventsOf(BR.Net.TERMINAL_EMP, 3)
    jobs['terminal.emp']()
    eq(#eventsOf(BR.Net.TERMINAL_EMP, 3), n, 'nothing is pushed while it lasts (on change only)')
    ok(T.empFor(m, 3, gameMs) == 1, 'a millisecond left at 2:59.999')
    gameMs = t0 + CT.fx.empMs
    jobs['terminal.emp']()
    for _, src in ipairs({ 1, 2, 3, 4, 5 }) do
        local d = empTo(src)
        ok(d and d.leftMs == nil and d.liveMs == nil, ('at 3:00 p%d is told it is over'):format(src), d)
    end
    ok(m.terminalFx.emps == nil and T.empFor(m, 3, gameMs) == nil, 'and the record is gone')
    n = #eventsOf(BR.Net.TERMINAL_EMP, 3)
    gameMs = gameMs + 1000
    jobs['terminal.emp']()
    eq(#eventsOf(BR.Net.TERMINAL_EMP, 3), n, 'then nothing more is sent')
end

describe('EMP: two EMPs from two squads spare neither from the other')
do
    reset()
    local m = lobby()
    runAt(1, 'emp')
    local t0 = gameMs
    gameMs = gameMs + 60000
    keys[3] = true
    roster[3].pos = { x = SITE.x, y = SITE.y, z = 30.0 }
    runAt(3, 'emp')
    local t1 = gameMs
    eq(T.empFor(m, 1, gameMs), CT.fx.empMs, 'A is stalled by B\'s, for B\'s three minutes')
    eq(T.empFor(m, 3, gameMs), t0 + CT.fx.empMs - gameMs, 'B by A\'s, for what A\'s has left')
    eq(T.empFor(m, 5, gameMs), CT.fx.empMs, 'and the solo player until the later of the two ends')
    eq(empTo(5).liveMs, CT.fx.empMs, 'an EMP lasts until the later end')
    gameMs = t0 + CT.fx.empMs
    jobs['terminal.emp']()
    eq(T.empFor(m, 3, gameMs), nil, 'A\'s ends: B drives again')
    ok(empTo(3).leftMs == nil and empTo(3).liveMs == t1 + CT.fx.empMs - gameMs, 'and is told so, B\'s still lasting')
    eq(empTo(1).leftMs, t1 + CT.fx.empMs - gameMs, 'A is still stalled by B\'s')
    gameMs = t1 + CT.fx.empMs
    jobs['terminal.emp']()
    ok(m.terminalFx.emps == nil and empTo(1).leftMs == nil, 'then B\'s ends too')
end

describe('EMP: the match ending, Season 1, br:ready, and a solo match')
do
    reset()
    local m = lobby()
    runAt(1, 'emp')
    m.state = BR.MatchState.ENDED
    eq(T.empFor(m, 3, gameMs), nil, 'nothing stalls once the match is over')
    jobs['terminal.emp']()
    ok(m.terminalFx.emps == nil and empTo(3).leftMs == nil and empTo(3).liveMs == nil,
        'the match over: the next pass ends it and tells everyone')

    reset()
    m = lobby()
    runAt(1, 'emp')
    season(1)
    eq(T.empFor(m, 3, gameMs), nil, 'off Season 2, nothing stalls')
    jobs['terminal.emp']()
    season(2)
    ok(m.terminalFx.emps == nil and empTo(3).leftMs == nil, 'and it is ended and said, so Season 2 coming back brings none back')

    -- A CLIENT THAT RESTARTS MID-EMP is told again; one with none is sent nothing.
    reset()
    m = lobby()
    runAt(1, 'emp')
    sent = {}
    gameMs = gameMs + 10000
    fire(BR.Net.READY, 4)
    local d = empTo(4)
    ok(d and d.leftMs == CT.fx.empMs - 10000, 'br:ready: told again, with what is left', d)
    eq(empTo(2), nil, 'and nobody else is sent anything')
    reset()
    lobby()
    fire(BR.Net.READY, 4)
    eq(empTo(4), nil, 'with no EMP, br:ready sends nothing')

    -- SOLO: only the runner is spared.
    reset()
    m = newMatch(1)
    m.mode = 'solo'
    player(1, m, nil, SITE)
    player(2, m, nil, { x = 0.0, y = 0.0 })
    keys[1] = true
    local r = runAt(1, 'emp')
    eq(r and r.toast, COPY.emp_done, 'a solo player reads the done line (it names no squad)')
    ok(empTo(1).leftMs == nil and empTo(2).leftMs == CT.fx.empMs, 'only the runner drives; the other player stalls')
end

describe('EMP: refused only outside a match; the end of the load; the dev command')
do
    reset()
    lobby()
    useAt(1)
    local f = listedAs(1, 'emp')
    ok(f and f.available == true, 'listed as available in a match', f and tostring(f.reason))
    ok(T.FUNCTIONS.emp.refuse(1, { dev = false }) == nil, 'and never refused in one')
    roster[1].matchId = nil
    ok(T.FUNCTIONS.emp.refuse(1, { dev = false }) == 'unavailable', 'outside a match: unavailable')
    ok(T.FUNCTIONS.emp.refuse(1, { dev = true }) == nil, 'a dev session is never refused for it')

    -- THE END OF THE LOAD: the match over before it goes off.
    reset()
    local m = lobby()
    useAt(1)
    local r = ask(1, 'emp')
    ok(r and r.code == 'running', 'accepted', r and r.code)
    m.state = BR.MatchState.ENDED
    flush()
    r = lastOf(BR.Net.TERMINAL_RESULT, 1)
    ok(r and r.ok == false and keys[1] == true and not T.squadUsed(1),
        'the match ended during the load: the key and the use given back', r and r.code)
    eq(empTo(3), nil, 'and nobody was told of an EMP')

    -- AN OPTION IT NO LONGER TAKES: bad_option, before anything is asked.
    reset()
    lobby()
    useAt(1)
    r = ask(1, 'emp', { radius = '300' })
    ok(r and r.code == 'bad_option' and keys[1] == true, 'wave C\'s radius: bad_option, nothing spent', r and r.code)

    -- `brterminal run emp`: the squad of whoever typed it is spared.
    reset()
    m = lobby()
    keys[1] = false
    local said = devRun(1, 'emp')
    ok(said:find('ok (done)', 1, true) ~= nil, 'brterminal run emp', said)
    ok(T.empFor(m, 3, gameMs) == CT.fx.empMs and T.empFor(m, 2, gameMs) == nil, 'it goes off, sparing their squad')
    ok(keys[1] == false and not T.squadUsed(1), 'and spends nothing')
    said = devRun(1, 'emp radius=600')
    ok(said:find('does not take those options', 1, true) ~= nil, 'and takes no options', said)
end

-- ── Comms blackout's world: the REAL squad beacon (server/party.lua), loaded
--    here so its `party.squadpos` job can be stepped like the terminal's ──
loadAll({ 'br_core/server/party.lua' })

--- One beacon push, against this block's matches; each squad member's last
--- SQUAD_POS row for `who`, or nil.
local function beacon()
    BR.Server.matches = matches
    jobs['party.squadpos']()
end
local function rowFor(target, who)
    local d = lastOf(BR.Net.SQUAD_POS, target)
    for _, r in ipairs(d or {}) do
        if r.src == who then return r end
    end
    return nil
end
local function positioned(target, who)
    local r = rowFor(target, who)
    return r ~= nil and r.x ~= nil and r.y ~= nil
end

--- lobby() plus a third member of B, out where they fell.
local function darkLobby()
    local m = lobby()
    player(6, m, 'B', { x = C0.x + 330.0, y = C0.y }, BR.PlayerState.OUT)
    roster[4].dbnoUntil = gameMs + 30000
    return m
end

describe('Comms blackout: registered, built, squad-only, its durations')
do
    local row = T.row('comms_blackout')
    ok(row and row.implemented == true and T.FUNCTIONS.comms_blackout ~= nil, 'comms_blackout is built')
    ok(row and row.squadOnly == true, 'and squad-only')
    ok(row and (row.cost or 0) == 0, 'and costs no Volts')
    eq(row and table.concat(row.options[1].choices, ','), '60,120,180', 'duration: 1, 2 or 3 minutes')
    ok(not COPY.comms_blackout_what:find('panel', 1, true),
        'the page no longer says the squad panel shows where teammates are: it never did')
end

describe('Comms blackout: every other squad\'s beacon leaves the positions off; the runner\'s does not')
do
    reset()
    local m = darkLobby()
    beacon()
    ok(positioned(3, 4) and positioned(3, 6) and positioned(1, 2), 'before: every squad sees its teammates')
    local r = runAt(1, 'comms_blackout', { duration = '60' })
    ok(r and r.ok == true and r.code == 'done', 'A runs it, 1 minute', r and r.code)
    eq(r and r.toast, COPY.comms_blackout_done, 'the done line')
    ok(noticeIndex('has redeemed their special power', 3) ~= nil, 'the lobby is told')
    ok(T.blackedOut(m, 'squad:B', gameMs) and not T.blackedOut(m, 'squad:A', gameMs),
        'B is blacked out, A is not')
    sent = {}
    beacon()
    for _, who in ipairs({ 3, 4, 6 }) do
        ok(rowFor(3, who) ~= nil and not positioned(3, who),
            ('B\'s beacon still lists p%d, with no position'):format(who))
    end
    ok(not positioned(4, 3), 'to every member of B')
    local downed = rowFor(3, 4)
    ok(downed and downed.state == BR.PlayerState.DBNO and downed.bleedEndsAt == roster[4].dbnoUntil,
        'a downed mate\'s dot goes too, but the panel keeps their state and bleed clock')
    ok(rowFor(3, 6) and rowFor(3, 6).state == BR.PlayerState.OUT, 'and the mate out stays a mate, with no dot')
    ok(positioned(1, 2) and positioned(2, 1), 'A, which ran it, still sees its own')
    ok(#eventsOf(BR.Net.SQUAD_POS, 5) == 0, 'the solo player has no beacon, before or after')

    -- ONE MINUTE, THEN THE POSITIONS ARE BACK ON THE NEXT PUSH.
    local t0 = gameMs
    gameMs = t0 + 59999
    jobs['terminal.blackout']()
    beacon()
    ok(not positioned(3, 4), 'still dark at 59.999 s')
    gameMs = t0 + 60000
    jobs['terminal.blackout']()
    beacon()
    ok(positioned(3, 4) and positioned(4, 3) and positioned(3, 6), 'and at the minute every dot is back')
    ok(m.terminalFx.blackouts == nil, 'the record is gone')
end

describe('Comms blackout: Ghost and the bounty -- each answers its own question')
do
    -- B UNDER GHOST IS BLACKED OUT LIKE ANY SQUAD, and stays hidden from A's Scan.
    reset()
    local m = darkLobby()
    runAt(1, 'scan')                                       -- A sees every opponent; p1 has a bounty
    devRun(3, 'ghost duration=240')
    devRun(1, 'comms_blackout duration=180')
    sent = {}
    beacon()
    jobs['terminal.scan']()
    ok(not positioned(3, 4), 'B under Ghost: blacked out all the same')
    eq(scanIds(1), '5', 'and still off A\'s Scan: Ghost holds')
    ok(positioned(1, 2), 'A sees its own')

    -- A UNDER GHOST, RUNNING IT: untouched by its own blackout.
    devRun(1, 'ghost duration=240')
    beacon()
    ok(positioned(1, 2), 'A under Ghost and running the blackout: still sees its own')

    -- THE BOUNTY ON A BLACKED-OUT SQUAD'S MEMBER: off their own maps (the beacon
    -- carries no position), its mark still in their panel, and still on every
    -- other map. A's bounty is the case here: C runs the blackout.
    reset()
    m = darkLobby()
    player(7, m, 'C', { x = C0.x - 900.0, y = C0.y })
    player(8, m, 'C', { x = C0.x - 910.0, y = C0.y })
    runAt(1, 'scan')                                       -- p1, squad A, has the bounty
    devRun(7, 'comms_blackout duration=60')
    sent = {}
    beacon()
    gameMs = gameMs + 1000
    jobs['terminal.bounty']()
    local mate = rowFor(2, 1)
    ok(mate and mate.bounty == true and mate.x == nil,
        'p1\'s own squad: the bounty bit for the panel, and no position for the blip 58 color 69 dot')
    local b3 = lastOf(BR.Net.TERMINAL_BOUNTY, 3)
    local b7 = lastOf(BR.Net.TERMINAL_BOUNTY, 7)
    ok(b3 and #b3.list == 1 and b3.list[1].s == 1, 'B, blacked out too, still sees A\'s bounty: not a teammate of theirs')
    ok(b7 and #b7.list == 1 and b7.list[1].s == 1, 'and C, which ran it, sees it as before')
    ok(positioned(7, 8), 'and C sees its own')
    local b2 = lastOf(BR.Net.TERMINAL_BOUNTY, 2)
    ok(b2 == nil or #b2.list == 0, 'nobody in A is sent the bounty as a mark: their beacon carried it, as always')
end

describe('Comms blackout: the match ending, Season 1, the dev command, the predicate itself')
do
    reset()
    local m = darkLobby()
    devRun(1, 'comms_blackout')
    ok(T.blackedOut(m, 'squad:B', gameMs), 'dark in a match being played (brterminal run comms_blackout)')
    m.state = BR.MatchState.ENDED
    ok(not T.blackedOut(m, 'squad:B', gameMs), 'not once the match is over')
    m.state = BR.MatchState.PLAYING
    ok(not T.blackedOut(m, nil, gameMs) and not T.blackedOut(nil, 'squad:B', gameMs),
        'nothing for no squad or no match')
    ok(not T.beaconDark(m, nil, gameMs), 'and the beacon\'s question for no squad id is no')
    ok(T.beaconDark(m, 'B', gameMs) and not T.beaconDark(m, 'A', gameMs),
        'the beacon asks by squad id: B dark, A not')
    season(1)
    ok(not T.blackedOut(m, 'squad:B', gameMs), 'nobody is blacked out off Season 2')
    sent = {}
    beacon()
    ok(positioned(3, 4), 'so the beacon sends positions at once')
    jobs['terminal.blackout']()
    ok(m.terminalFx.blackouts == nil, 'and the blackouts are forgotten')
    season(2)
    ok(not T.blackedOut(m, 'squad:B', gameMs), 'so Season 2 coming back does not bring it back')

    -- A SECOND, SHORTER ONE (only the dev command can) NEVER CUTS THE FIRST.
    reset()
    m = darkLobby()
    devRun(1, 'comms_blackout duration=180')
    local ends = gameMs + 180000
    devRun(1, 'comms_blackout duration=60')
    ok(T.blackedOut(m, 'squad:B', ends - 1) and not T.blackedOut(m, 'squad:B', ends),
        'a 1-minute blackout over a 3-minute one keeps the three')

    -- TWO SQUADS' BLACKOUTS AT ONCE: each blacks out the other.
    reset()
    m = darkLobby()
    devRun(1, 'comms_blackout')
    devRun(3, 'comms_blackout')
    sent = {}
    beacon()
    ok(not positioned(1, 2) and not positioned(3, 4), 'A\'s and B\'s at once: neither sees its own')
end

describe('Comms blackout: squad-only, refused spending nothing, and the end-of-load refund')
do
    -- OUTSIDE A SQUAD MATCH: not listed, and a run is refused by the door.
    reset()
    local m = newMatch(1)
    m.mode = 'solo'
    player(1, m, nil, SITE)
    keys[1] = true
    useAt(1)
    eq(listedAs(1, 'comms_blackout'), nil, 'a solo match lists no Comms blackout')
    local r = ask(1, 'comms_blackout')
    ok(r and r.code == 'unavailable' and keys[1] == true and not T.squadUsed(1),
        'and a run is refused, spending nothing', r and r.code)

    -- OUTSIDE A MATCH, a real session is refused.
    ok(T.FUNCTIONS.comms_blackout.refuse(99, { dev = false }) == 'unavailable', 'outside a match: unavailable')
    ok(T.FUNCTIONS.comms_blackout.refuse(99, { dev = true }) == nil, 'a dev session is never refused for it')

    -- THE END OF THE LOAD: the match over before it starts. Everything back.
    reset()
    m = darkLobby()
    useAt(1)
    r = ask(1, 'comms_blackout', { duration = '120' })
    ok(r and r.code == 'running', 'accepted', r and r.code)
    m.state = BR.MatchState.ENDED
    flush()
    r = lastOf(BR.Net.TERMINAL_RESULT, 1)
    ok(r and r.ok == false and keys[1] == true and not T.squadUsed(1),
        'the match ended during the load: the key and the use given back', r and r.code)
    ok(m.terminalFx == nil or m.terminalFx.blackouts == nil, 'and no blackout began')

    -- AND bad_option.
    reset()
    darkLobby()
    useAt(1)
    r = ask(1, 'comms_blackout', { duration = '30' })
    ok(r and r.code == 'bad_option' and keys[1] == true, 'a duration the row does not offer: bad_option, nothing spent')
end

-- ── Reboot's world: the REAL revive key return (server/revivekey.lua), over
--    this suite's roster, so what is proved is the one way back into a match
--    the gamemode already has ──
local cleared, spectateStops = {}, {}
function BR.Roster.clearFields(src, fields)
    cleared[#cleared + 1] = { src = src, fields = ',' .. table.concat(fields, ',') .. ',' }
    local e = roster[src]
    if e then
        for _, f in ipairs(fields) do e[f] = nil end
    end
end
function BR.Roster.update(src, f)
    local e = roster[src]
    if e then
        for k, v in pairs(f) do e[k] = v end
    end
end
function BR.Roster.setState(src, st)
    if roster[src] then roster[src].state = st end
end
BR.Spectate = { stop = function(src, why) spectateStops[#spectateStops + 1] = { src = src, why = why } end }
loadAll({ 'br_lib/config/revivekey.lua', 'br_core/server/revivekey.lua' })
local RK = BR.Config.ReviveKey

--- Run the timers pending NOW, and only those: one step of a run (its load,
--- then the arrival's wait).
local function stepTimers()
    local due = timers
    timers = {}
    table.sort(due, function(a, b) return a.at < b.at end)
    for _, t in ipairs(due) do
        if t.at > gameMs then gameMs = t.at end
        t.fn()
    end
end

--- Squads still in the fight -- BR.Server.squadsAlive's rule, the match's end
--- check (server/main.lua, server/match.lua: `<= 1` is a win).
local function squadsAlive(m)
    local seen, n = {}, 0
    for src, e in pairs(roster) do
        if e.matchId == m.id and BR.Server.isInMatch(e.state) then
            local k = e.squadId or ('solo:' .. src)
            if not seen[k] then
                seen[k] = true
                n = n + 1
            end
        end
    end
    return n
end
local function inFight(m)
    local n = 0
    for _, e in pairs(roster) do
        if e.matchId == m.id and BR.Server.isInMatch(e.state) then n = n + 1 end
    end
    return n
end

--- lobby() with squad A's p2 eliminated by B's p3: OUT where they fell,
--- placed, their death stamped. The runner stands beside the tower, not on
--- its point, so "over this terminal" and "over the runner" differ.
local function rebootLobby()
    cleared, spectateStops = {}, {}
    local m = lobby()
    BR.Server.matches = matches
    roster[1].pos = { x = SITE.x + 1.5, y = SITE.y + 0.5, z = SITE.z + 1.0 }
    roster[2].state = BR.PlayerState.OUT
    roster[2].placement, roster[2].diedAt, roster[2].engineHp = 3, gameMs - 5000, 0
    roster[3].kills = 1
    return m
end

local function arrivals(src) return eventsOf(BR.Net.REVIVEKEY_ARRIVE, src) end
local function places(src) return eventsOf(BR.Net.REVIVEKEY_PLACE, src) end
local function clearedOf(src, field)
    for _, c in ipairs(cleared) do
        if c.src == src and c.fields:find(',' .. field .. ',', 1, true) then return true end
    end
    return false
end

describe('Reboot: registered, built, squad-only, 150 Volts')
do
    local row = T.row('reboot')
    ok(row and row.implemented == true and T.FUNCTIONS.reboot ~= nil, 'reboot is built')
    ok(row and row.squadOnly == true, 'and squad-only')
    eq(row and T.costOf(row), 150, 'and costs 150 Volts')
    ok(type(BR.ReviveKey.bringBackAt) == 'function', 'through the revive key\'s own return')
end

describe('Reboot: every eliminated squadmate comes back over the runner, by the revive key\'s return')
do
    reset()
    local m = rebootLobby()
    -- p6: out, with a key the squad bought. p7: left mid-match. p8: out, but
    -- no longer connected.
    player(6, m, 'A', { x = C0.x + 90.0, y = C0.y }, BR.PlayerState.OUT)
    roster[6].reviveKey = { x = C0.x + 90.0, y = C0.y, z = 30.0, held = true, via = 'bought',
                            mintedAt = gameMs - 9000, expiresAt = gameMs - 1000 }
    player(7, m, 'A', { x = C0.x + 95.0, y = C0.y }, BR.PlayerState.LEFT)
    player(8, m, 'A', { x = C0.x + 99.0, y = C0.y }, BR.PlayerState.OUT)
    roster[8].name = nil
    local squadsBefore, fightBefore = squadsAlive(m), inFight(m)

    useAt(1)
    local f = listedAs(1, 'reboot')
    ok(f and f.available == true, 'the card is available: two to bring back', f and tostring(f.reason))
    local r = ask(1, 'reboot')
    ok(r and r.code == 'running', 'accepted', r and r.code)
    eq(market.wallet[1], 850, 'the 150 Volts are spent as it is accepted')
    stepTimers()                                       -- the load is over: it runs
    r = lastOf(BR.Net.TERMINAL_RESULT, 1)
    ok(r and r.ok == true and r.code == 'done', 'it runs', r and r.code)
    eq(r and r.toast, COPY.reboot_done .. ' ' .. 'Your new balance is: 850 Volts.', 'the done line, and the new balance')
    ok(noticeIndex('has redeemed their special power', 5) ~= nil, 'the lobby is told')
    local a2, a6 = arrivals(2)[1], arrivals(6)[1]
    local R1 = roster[1].pos
    ok(a2 and a2.payload.x == R1.x and a2.payload.y == R1.y and a2.payload.z == R1.z,
        'p2 is promised the arrival: black, and the focus on the runner -- never the terminal (round 6)')
    ok(a6 ~= nil, 'and so is p6')
    eq(#arrivals(7) + #arrivals(8), 0, 'not the player who left, nor the one no longer connected')
    ok(#spectateStops == 2 and spectateStops[1].why == 'in-the-fight', 'the spectate camera comes down for both')
    eq(roster[2].state, BR.PlayerState.OUT, 'and nothing is written until the screen is black')

    local promisedAt = gameMs
    stepTimers()                                       -- a fade later
    eq(gameMs - promisedAt, RK.fadeMs + RK.focusMs, 'after the key\'s own wait: fadeMs + focusMs of black')
    local p2 = places(2)[1]
    ok(p2 and p2.payload.x == R1.x and p2.payload.y == R1.y and p2.payload.z == R1.z,
        'REVIVEKEY_PLACE over the runner: resurrected 150 m up, with the parachute (client/revivekey.lua)')
    ok(not (p2 and p2.payload.x == SITE.x and p2.payload.y == SITE.y), 'and not over the terminal')
    ok(roster[2].state == BR.PlayerState.ALIVE and roster[6].state == BR.PlayerState.ALIVE, 'both ALIVE')
    ok(roster[2].hp == 100.0 and roster[2].armour == 0.0, 'at full health, no armor')
    local hs = lastOf(BR.Net.HEALTH_SYNC, 2)
    ok(hs and hs.hp == 100, 'their client told its health')
    ok(clearedOf(2, 'placement') and roster[2].placement == nil, 'the placement retracted on every client')
    ok(clearedOf(2, 'diedAt') and roster[2].diedAt == nil, 'the death stamp cleared: they are not counted as died')
    ok(clearedOf(2, 'engineHp'), 'and the corpse sample, or the death check eliminates them again')
    eq(roster[6].reviveKey, nil, 'the key the squad bought for p6 is spent: they are back')
    eq(roster[3].kills, 1, 'the kill that eliminated p2 stays credited')
    ok(roster[1].revives == nil and roster[3].revives == nil, 'and nobody is credited a revive')
    ok(roster[7].state == BR.PlayerState.LEFT and roster[8].state == BR.PlayerState.OUT,
        'the player who left and the one gone stay where they are')
    eq(squadsAlive(m), squadsBefore, 'the squads still standing are what they were: the match\'s end check is untouched')
    eq(inFight(m), fightBefore + 2, 'and the players left grows by the two')
    ok(#eventsOf(BR.Net.SFX_CUE, 1) >= 1, 'the squad hears the revive cue')
end

describe('Reboot: a revive key in play')
do
    -- A HOLD FILLING AT AN AMBULANCE FOR p2: stopped, its reviver told, p2 rebooted.
    reset()
    local m = rebootLobby()
    roster[2].reviveKey = { x = C0.x, y = C0.y, z = 30.0, held = true, via = 'collected',
                            mintedAt = gameMs, expiresAt = gameMs + 180000,
                            byS = 1, from = gameMs, beat = gameMs, veh = 77, spot = { x = 1.0, y = 2.0, z = 3.0 } }
    runAt(1, 'reboot')
    local pr = lastOf(BR.Net.REVIVEKEY_PROGRESS, 1)
    ok(pr and pr.cancelled == true and pr.target == 2, 'the hold at the ambulance is stopped, and its reviver told')
    ok(roster[2].state == BR.PlayerState.ALIVE and roster[2].reviveKey == nil, 'p2 is back, the key spent')
    eq(#places(2), 1, 'brought back once')

    -- A KEY ARRIVAL ALREADY COMMITTED: p2 is on the way back by key; a Reboot
    -- does not take them twice, and with nobody else it is refused.
    reset()
    m = rebootLobby()
    roster[2].reviveKey = { x = C0.x, y = C0.y, z = 30.0, held = true, byS = 1, arriveAt = gameMs + 900,
                            spot = { x = 1.0, y = 2.0, z = 3.0 } }
    useAt(1)
    local f = listedAs(1, 'reboot')
    ok(f and f.available == false and f.reason == 'reboot_none', 'the card says reboot_none', f and tostring(f.reason))
    local r = ask(1, 'reboot')
    ok(r and r.code == 'reboot_none' and r.toast == COPY.reboot_none, 'a run is refused in its own line', r and r.code)
    ok(#market.charges == 0 and keys[1] == true and not T.squadUsed(1), 'spending nothing, the Volts included')

    -- AND ONE THAT COMMITS DURING THE LOAD: everything given back at the end.
    reset()
    m = rebootLobby()
    useAt(1)
    r = ask(1, 'reboot')
    ok(r and r.code == 'running', 'accepted', r and r.code)
    roster[2].reviveKey = { held = true, byS = 1, arriveAt = gameMs + 900, spot = { x = 1.0, y = 2.0, z = 3.0 } }
    flush()
    r = lastOf(BR.Net.TERMINAL_RESULT, 1)
    ok(r and r.code == 'reboot_none', 'the only one came back by key meanwhile: reboot_none', r and r.code)
    ok(market.wallet[1] == 1000 and keys[1] == true and not T.squadUsed(1),
        'the Volts, the key and the use given back')
    eq(#arrivals(2), 0, 'and no second return was started')

    -- A HOLD ON p2 IN THE BLACK, after Reboot has promised the return: refused
    -- as it starts, and stopped if one is somehow running, its reviver told --
    -- never left filling until the arrival clears the key under it.
    reset()
    m = rebootLobby()
    useAt(1)
    ask(1, 'reboot')
    stepTimers()                                       -- the load is over: the promise
    ok(BR.ReviveKey.returning(2) and roster[2].state == BR.PlayerState.OUT, 'p2 is on the way back, still OUT')
    roster[2].reviveKey = { x = C0.x, y = C0.y, z = 30.0, held = true, via = 'bought',
                            mintedAt = gameMs, expiresAt = gameMs + 180000 }
    fire(BR.Net.REVIVEKEY_START, 1, { target = 2, n = 77 })
    local pr = lastOf(BR.Net.REVIVEKEY_PROGRESS, 1)
    ok(pr and pr.cancelled == true and pr.target == 2 and pr.reason == 'already on the way back',
        'a hold starting in the black is refused, and why', pr and tostring(pr.reason))
    ok(roster[2].reviveKey.byS == nil, 'and no hold is running')
    local rec = roster[2].reviveKey
    rec.byS, rec.from, rec.beat, rec.veh = 1, gameMs, gameMs, 77
    jobs['revivekey.hold']()
    pr = lastOf(BR.Net.REVIVEKEY_PROGRESS, 1)
    ok(pr and pr.cancelled == true and pr.reason == 'already on the way back' and rec.byS == nil,
        'one running in the black is stopped on the next step, its reviver told', pr and tostring(pr.reason))
    flush()
    ok(roster[2].state == BR.PlayerState.ALIVE and roster[2].reviveKey == nil, 'p2 is back, the key spent')
    eq(#places(2), 1, 'once')
    local _ = m
end

describe('Reboot: a rebooted player eliminated again')
do
    reset()
    local m = rebootLobby()
    runAt(1, 'reboot')
    eq(roster[2].state, BR.PlayerState.ALIVE, 'p2 is back')
    -- ELIMINATED AGAIN, somewhere else: the elimination edge mints a fresh key
    -- where they fell this time -- no key outlived the reboot to be reused.
    roster[2].pos = { x = 50.0, y = 60.0, z = 10.0 }
    roster[2].state = BR.PlayerState.OUT
    local k = BR.ReviveKey.onEliminated(m, 2)
    ok(k and k.x == 50.0 and k.y == 60.0 and k.held == false, 'a new key, at the new body, not held')
    -- The squad's one use is spent: a second Reboot is refused at the door.
    keys[1] = true
    useAt(1)
    local r = ask(1, 'reboot')
    eq(r and r.code, 'squad_used', 'and the squad cannot Reboot twice in a match')
    -- The dev command can, and brings them back again by the same return.
    local said = devRun(1, 'reboot')
    ok(said:find('ok (done)', 1, true) ~= nil, 'brterminal run reboot', said)
    flush()
    eq(roster[2].state, BR.PlayerState.ALIVE, 'back again')
end

describe('Reboot: a squad with nobody left in the fight is never brought back')
do
    -- THE RUNNER WAS THE LAST ONE STANDING AND FELL DURING THE LOAD.
    reset()
    local m = rebootLobby()
    useAt(1)
    local r = ask(1, 'reboot')
    ok(r and r.code == 'running', 'accepted', r and r.code)
    roster[1].state = BR.PlayerState.OUT
    local squads = squadsAlive(m)
    flush()
    r = lastOf(BR.Net.TERMINAL_RESULT, 1)
    ok(r and r.ok == false and r.code == 'unavailable', 'nobody left in the fight: it cannot happen', r and r.code)
    ok(market.wallet[1] == 1000 and keys[1] == true and not T.squadUsed(1),
        'the Volts, the key and the use given back')
    ok(#arrivals(1) + #arrivals(2) == 0 and roster[2].state == BR.PlayerState.OUT, 'and nobody comes back')
    eq(squadsAlive(m), squads, 'so the squads standing -- the end check -- are what the eliminations left')

    -- A SQUADMATE STILL IN THE FIGHT, the runner out: over the runner there is
    -- nobody standing to come back over (round 6) -- everything given back.
    reset()
    m = rebootLobby()
    player(6, m, 'A', { x = C0.x + 90.0, y = C0.y }, BR.PlayerState.DBNO)
    useAt(1)
    ask(1, 'reboot')
    roster[1].state = BR.PlayerState.OUT
    flush()
    r = lastOf(BR.Net.TERMINAL_RESULT, 1)
    ok(r and r.ok == false and r.code == 'reboot_target', 'over the runner, out as it ends: reboot_target', r and r.code)
    ok(market.wallet[1] == 1000 and keys[1] == true and not T.squadUsed(1), 'everything given back')
    eq(roster[2].state, BR.PlayerState.OUT, 'and nobody comes back')

    -- OVER A STANDING TEAMMATE, the runner out: the runner comes back with p2,
    -- over p6.
    reset()
    m = rebootLobby()
    player(6, m, 'A', { x = C0.x + 90.0, y = C0.y + 7.0, z = 31.0 })
    useAt(1)
    r = ask(1, 'reboot', { to = 'mate', mate = '6' })
    ok(r and r.code == 'running', 'over p6: accepted', r and r.code)
    roster[1].state = BR.PlayerState.OUT
    flush()
    r = lastOf(BR.Net.TERMINAL_RESULT, 1)
    ok(r and r.code == 'done', 'a teammate still standing: it runs', r and r.code)
    flush()
    ok(roster[1].state == BR.PlayerState.ALIVE and roster[2].state == BR.PlayerState.ALIVE,
        'the runner, eliminated while it loaded, comes back with p2')
    local p1 = places(1)[1]
    ok(p1 and p1.payload.x == C0.x + 90.0 and p1.payload.y == C0.y + 7.0 and p1.payload.z == 31.0,
        'over p6, where p6 stands')
end

describe('Reboot: over you or a standing teammate, Vehicle drop\'s two options (round 6)')
do
    -- "Any use of 'near this terminal' is like, not useful for this
    -- gamemode" (owner, 2026-10-07).
    local row = T.row('reboot')
    local opt = {}
    for _, o in ipairs(row.options or {}) do opt[o.id] = o end
    local vd = {}
    for _, o in ipairs(T.row('vehicle_drop').options or {}) do vd[o.id] = o end
    ok(opt.to and opt.to.default == 'self' and #opt.to.choices == 2 and opt.to.choices[1] == 'self'
        and opt.to.choices[2] == 'mate', 'option `to`: self (the default) or mate')
    ok(opt.mate and opt.mate.source == 'mates' and opt.mate.dropdown == true and opt.mate.when
        and opt.mate.when.to == 'mate', 'option `mate`: the standing teammates, in a dropdown, only for mate')
    ok(vd.to and vd.mate and vd.mate.source == opt.mate.source and vd.to.default == opt.to.default,
        'the same two as Vehicle drop')
    for _, k in ipairs({ 'reboot_summary', 'reboot_what', 'reboot_risks' }) do
        ok(COPY[k]:find('this terminal', 1, true) == nil and COPY[k]:find(' here', 1, true) == nil,
            k .. ' no longer says "this terminal" or "here"')
    end
    ok(COPY.reboot_target ~= nil and COPY.drop_no_mate ~= nil, 'its two reasons have their lines')

    -- OVER A STANDING TEAMMATE.
    reset()
    local m = rebootLobby()
    player(6, m, 'A', { x = C0.x + 60.0, y = C0.y - 4.0, z = 33.0 })
    local r = runAt(1, 'reboot', { to = 'mate', mate = '6' })
    ok(r and r.code == 'done', 'over p6: it runs', r and r.code)
    flush()
    local p2 = places(2)[1]
    ok(p2 and p2.payload.x == C0.x + 60.0 and p2.payload.y == C0.y - 4.0 and p2.payload.z == 33.0,
        'p2 comes back over p6')

    -- THE TEAMMATE DOWN AS IT RUNS: drop_no_mate, everything back.
    reset()
    m = rebootLobby()
    player(6, m, 'A', { x = C0.x + 60.0, y = C0.y }, BR.PlayerState.ALIVE)
    useAt(1)
    r = ask(1, 'reboot', { to = 'mate', mate = '6' })
    ok(r and r.code == 'running', 'accepted', r and r.code)
    roster[6].state = BR.PlayerState.DBNO
    flush()
    r = lastOf(BR.Net.TERMINAL_RESULT, 1)
    ok(r and r.ok == false and r.code == 'drop_no_mate' and r.toast == COPY.drop_no_mate,
        'the teammate went down as it loaded: drop_no_mate, in its line', r and r.code)
    ok(market.wallet[1] == 1000 and keys[1] == true and not T.squadUsed(1), 'the Volts, the key and the use given back')
    eq(#arrivals(2), 0, 'and nobody is promised a return')

    -- NOT A STANDING TEAMMATE AT ALL, AS ASKED: refused before anything is spent.
    reset()
    m = rebootLobby()
    useAt(1)
    for _, who in ipairs({ '2', '3', '99' }) do
        r = ask(1, 'reboot', { to = 'mate', mate = who })
        ok(r and r.code == 'drop_no_mate' and #market.charges == 0 and keys[1] == true,
            ('mate %s (out, another squad, nobody): drop_no_mate, nothing spent'):format(who), r and r.code)
    end
    r = ask(1, 'reboot', { to = 'mate' })
    ok(r and r.code == 'drop_no_mate', 'a teammate not named: drop_no_mate', r and r.code)

    -- THE RUNNER DOWN AS IT RUNS, over themselves: reboot_target.
    reset()
    m = rebootLobby()
    useAt(1)
    ask(1, 'reboot')
    roster[1].state = BR.PlayerState.DBNO
    flush()
    r = lastOf(BR.Net.TERMINAL_RESULT, 1)
    ok(r and r.code == 'reboot_target' and r.toast == COPY.reboot_target and market.wallet[1] == 1000,
        'the runner downed as it loaded: reboot_target, everything back', r and r.code)
    local _ = m
end

describe('Reboot: refused, spending nothing')
do
    -- NOBODY ELIMINATED.
    reset()
    lobby()
    BR.Server.matches = matches
    useAt(1)
    local f = listedAs(1, 'reboot')
    ok(f and f.available == false and f.reason == 'reboot_none', 'nobody out: the card says reboot_none')
    local r = ask(1, 'reboot')
    ok(r and r.code == 'reboot_none' and #market.charges == 0 and keys[1] == true,
        'and a run is refused, the market never asked', r and r.code)

    -- A SQUADMATE DOWNED, OR STILL IN THE AIR, IS NOT ELIMINATED: nobody to
    -- bring back, on the card and at a run.
    for _, st in ipairs({ BR.PlayerState.DBNO, BR.PlayerState.GLIDE, BR.PlayerState.FREEFALL,
                          BR.PlayerState.BUS }) do
        reset()
        lobby()
        BR.Server.matches = matches
        roster[2].state = st
        useAt(1)
        f = listedAs(1, 'reboot')
        ok(f and f.available == false and f.reason == 'reboot_none',
            ('a squadmate %s and nobody out: the card says reboot_none'):format(st), f and tostring(f.reason))
        r = ask(1, 'reboot')
        ok(r and r.code == 'reboot_none' and #market.charges == 0 and keys[1] == true,
            ('and a run is refused, spending nothing (%s)'):format(st), r and r.code)
        eq(roster[2].state, st, 'and the squadmate is left as they were')
    end

    -- NOT ENOUGH VOLTS: the door's own refusal, after every other.
    reset()
    rebootLobby()
    market.wallet[1] = 100
    useAt(1)
    r = ask(1, 'reboot')
    ok(r and r.code == 'no_volts' and keys[1] == true and market.wallet[1] == 100, 'no_volts, nothing spent',
        r and r.code)

    -- OUTSIDE A SQUAD MATCH: not listed, and refused.
    reset()
    local m = newMatch(1)
    m.mode = 'solo'
    BR.Server.matches = matches
    player(1, m, nil, SITE)
    player(2, m, nil, { x = 0.0, y = 0.0 }, BR.PlayerState.OUT)
    keys[1] = true
    market.wallet[1] = 1000
    useAt(1)
    eq(listedAs(1, 'reboot'), nil, 'a solo match lists no Reboot')
    r = ask(1, 'reboot')
    ok(r and r.code == 'unavailable' and keys[1] == true and market.wallet[1] == 1000,
        'and a run is refused, spending nothing', r and r.code)

    -- OUTSIDE A MATCH.
    ok(T.FUNCTIONS.reboot.refuse(99, { dev = false }) == 'unavailable', 'outside a match: unavailable')
    ok(T.FUNCTIONS.reboot.refuse(99, { dev = true }) == nil, 'a dev session is never refused for it')
end

describe('Reboot: the match ending during the load or the arrival, Season 1')
do
    reset()
    local m = rebootLobby()
    useAt(1)
    ask(1, 'reboot')
    m.state = BR.MatchState.ENDED
    flush()
    local r = lastOf(BR.Net.TERMINAL_RESULT, 1)
    ok(r and r.ok == false and market.wallet[1] == 1000 and keys[1] == true,
        'the match over during the load: everything back', r and r.code)
    eq(#arrivals(2), 0, 'and nobody promised a return')

    -- DURING THE ARRIVAL: the promise is withdrawn, nobody stands up in a
    -- finished match.
    reset()
    m = rebootLobby()
    useAt(1)
    ask(1, 'reboot')
    stepTimers()
    ok(#arrivals(2) == 1, 'p2 promised')
    m.state = BR.MatchState.ENDED
    stepTimers()
    local last = arrivals(2)[#arrivals(2)]
    ok(last and last.payload.cancelled == true, 'the match ended in the black: the promise is withdrawn')
    eq(roster[2].state, BR.PlayerState.OUT, 'and p2 is not brought back')
    eq(#places(2), 0, 'nothing placed')

    -- SEASON 1 DURING THE LOAD.
    reset()
    m = rebootLobby()
    useAt(1)
    ask(1, 'reboot')
    season(1)
    flush()
    r = lastOf(BR.Net.TERMINAL_RESULT, 1)
    ok(r and r.ok == false and market.wallet[1] == 1000 and keys[1] == true,
        'Season 1 during the load: everything back', r and r.code)
    season(2)
    local _ = m
end

describe('Reboot: full health whatever the key\'s reviveHp; the return once per player')
do
    -- THE PAGE SAYS FULL HEALTH. The key's reviveHp is the owner's number for a
    -- key revive and may move; a Reboot passes its own.
    reset()
    rebootLobby()
    local was = RK.reviveHp
    RK.reviveHp = 40
    runAt(1, 'reboot')
    eq(roster[2].hp, 100.0, 'a Reboot brings them back at 100 with the key\'s reviveHp at 40')
    RK.reviveHp = was

    -- THE RETURN ITSELF REFUSES A PLAYER ALREADY ON THE WAY BACK, whoever asks.
    reset()
    rebootLobby()
    local at = { x = 1.0, y = 2.0, z = 3.0 }
    local ok1 = BR.ReviveKey.bringBackAt(2, at, 100.0)
    local ok2, why2 = BR.ReviveKey.bringBackAt(2, at, 100.0)
    ok(ok1 == true and ok2 == false and why2 == 'already on the way back', 'a second return for p2 is refused',
        tostring(why2))
    ok(BR.ReviveKey.returning(2), 'p2 is returning meanwhile')
    eq(#arrivals(2), 1, 'one promise')
    flush()
    eq(#places(2), 1, 'one arrival')
    ok(not BR.ReviveKey.returning(2), 'and not returning once back')
    local okNo, whyNo = BR.ReviveKey.bringBackAt(2, at, 100.0)
    ok(okNo == false and whyNo ~= nil, 'and a player who is not out is not brought back', tostring(whyNo))

    -- A RETURN THAT CANNOT START FOR ANYBODY: the run says so and gives it all back.
    reset()
    rebootLobby()
    local real = BR.ReviveKey.bringBackAt
    BR.ReviveKey.bringBackAt = function() return false, 'test' end
    useAt(1)
    ask(1, 'reboot')
    flush()
    local r = lastOf(BR.Net.TERMINAL_RESULT, 1)
    ok(r and r.code == 'reboot_none' and market.wallet[1] == 1000 and keys[1] == true,
        'nobody could be brought back: reboot_none, everything back', r and r.code)
    BR.ReviveKey.bringBackAt = real
end


describe('Reboot: the dev command brings them back over the player')
do
    reset()
    rebootLobby()
    roster[1].pos = { x = 10.0, y = 20.0, z = 5.0 }
    keys[1] = false
    local said = devRun(1, 'reboot')
    ok(said:find('ok (done)', 1, true) ~= nil, 'brterminal run reboot', said)
    flush()
    local p = places(2)[1]
    ok(p and p.payload.x == 10.0 and p.payload.y == 20.0 and p.payload.z == 5.0,
        'the dev terminal is nowhere: over the player')
    ok(roster[2].state == BR.PlayerState.ALIVE and not T.squadUsed(1) and #market.charges == 0,
        'and nothing is spent')
end

-- =========================================================================
-- PART I -- round 4 (owner, 2026-10-06): the persistent notices -- "Anything
-- that a player is being impacted by, which happened as a result of another
-- player's actions at a terminal, should show a persistent notification with
-- a timer explaining what the impact is and when it will be over."
-- =========================================================================

--- The rows `src` was last sent ("key@endsAt|..."), '' for an empty list,
--- nil when they were never sent one.
local function rowsOf(src)
    local d = lastOf(BR.Net.TERMINAL_IMPACTS, src)
    if not d then return nil end
    local out = {}
    for _, r in ipairs(d.list or {}) do
        out[#out + 1] = ('%s@%s'):format(r.key, r.endsAt and tostring(r.endsAt) or 'end')
    end
    return table.concat(out, '|')
end

--- The last row `src` was sent with this key, or nil.
local function rowFor(src, key)
    local d = lastOf(BR.Net.TERMINAL_IMPACTS, src)
    for _, r in ipairs(d and d.list or {}) do
        if r.key == key then return r end
    end
    return nil
end

local function impactsPass()
    jobs['terminal.impacts']()
end

describe('the persistent notices: EMP -- everyone it stalls, with its clock, and nobody it spares')
do
    reset()
    local m = lobby()
    local r = runAt(1, 'emp')
    ok(r and r.code == 'done', 'EMP runs', r and r.code)
    local ends = gameMs + CT.fx.empMs
    for _, src in ipairs({ 3, 4, 5 }) do
        eq(rowsOf(src), 'impact_emp@' .. ends, ('p%d is sent the row at once, ending with the EMP'):format(src))
        eq(rowFor(src, 'impact_emp').text, COPY.impact_emp, 'in its words')
        eq(rowFor(src, 'impact_emp').tail, nil, 'a timed row carries no tail')
    end
    eq(rowsOf(1), nil, 'the runner is sent nothing')
    eq(rowsOf(2), nil, 'nor their squad, which it spares')

    -- ON CHANGE ONLY: passes with nothing new send nothing.
    local n = #eventsOf(BR.Net.TERMINAL_IMPACTS)
    gameMs = gameMs + 1000
    impactsPass()
    gameMs = gameMs + 1000
    impactsPass()
    eq(#eventsOf(BR.Net.TERMINAL_IMPACTS), n, 'two more passes, nothing changed: nothing sent')

    -- IT ENDS: an empty list, once.
    gameMs = ends
    jobs['terminal.emp']()
    impactsPass()
    for _, src in ipairs({ 3, 4, 5 }) do eq(rowsOf(src), '', ('p%d: an empty list at its end'):format(src)) end
    n = #eventsOf(BR.Net.TERMINAL_IMPACTS)
    gameMs = gameMs + 1000
    impactsPass()
    eq(#eventsOf(BR.Net.TERMINAL_IMPACTS), n, 'and then nothing')
    local _ = m
end

describe('the persistent notices: Scan -- every opponent for the rest of the match; its bounty on the runner')
do
    reset()
    local m = lobby()
    local r = runAt(1, 'scan')
    ok(r and r.code == 'done', 'Scan runs', r and r.code)
    local ends = gameMs + CT.fx.bountyMs
    eq(rowsOf(1), 'impact_bounty@' .. ends, 'the runner carries its bounty, with the bounty\'s clock')
    eq(rowFor(1, 'impact_bounty').text, COPY.impact_bounty, 'in its words')
    for _, src in ipairs({ 3, 4, 5 }) do
        eq(rowsOf(src), 'impact_scan@end', ('p%d: another squad sees them, until the match ends'):format(src))
        eq(rowFor(src, 'impact_scan').tail, COPY.impact_until_end, 'its tail stands in for a clock')
        eq(rowFor(src, 'impact_scan').endsAt, nil, 'and it has none')
        eq(rowFor(src, 'impact_scan').text, COPY.impact_scan, 'the squad line, in a squad match')
    end
    eq(rowsOf(2), nil, 'the runner\'s squadmate: nothing (Scan shows them nothing, and the bounty is not theirs)')

    -- GHOST: a hidden squad's rows go while it lasts, and come back.
    devRun(3, 'ghost duration=120')
    impactsPass()
    ok(rowsOf(3) == '' and rowsOf(4) == '', 'B under Ghost: no map shows them, so no row says one does')
    eq(rowsOf(5), 'impact_scan@end', 'the solo player is still seen')
    devRun(1, 'ghost duration=120')
    impactsPass()
    eq(rowsOf(1), '', 'and the bounty on a runner whose squad went under Ghost goes too')
    gameMs = gameMs + 121000
    jobs['terminal.ghost']()
    impactsPass()
    ok(rowsOf(3) == 'impact_scan@end' and rowsOf(1) == 'impact_bounty@' .. ends,
        'Ghost over: both come back, the bounty\'s clock unchanged')

    -- ELIMINATED: the rows go with the fight.
    roster[3].state = BR.PlayerState.OUT
    impactsPass()
    eq(rowsOf(3), '', 'a player out of the fight has no rows')

    -- THE MATCH ENDING: everyone's go.
    m.state = BR.MatchState.ENDED
    impactsPass()
    ok(rowsOf(1) == '' and rowsOf(4) == '' and rowsOf(5) == '', 'the match over: every list empty')
end

describe('the persistent notices: a Contract on its target; Comms blackout')
do
    -- CONTRACT: the target, for its ten minutes.
    reset()
    local m = lobby()
    killsOf(3, 2, 100)
    runAt(1, 'contract')
    eq(rowsOf(3), 'impact_bounty@' .. (gameMs + CT.fx.bountyMs), 'the Contract\'s target carries the bounty row')
    eq(rowsOf(4), nil, 'their squadmate does not (they were told to protect them)')
    eq(rowsOf(1), nil, 'nor the runner')

    -- COMMS BLACKOUT: every other squad's members with a teammate.
    reset()
    m = lobby()
    runAt(1, 'comms_blackout', { duration = '120' })
    local ends = gameMs + 120000
    ok(rowsOf(3) == 'impact_blackout@' .. ends and rowsOf(4) == 'impact_blackout@' .. ends,
        'the other squad, both of them, for its two minutes')
    eq(rowFor(3, 'impact_blackout').text, COPY.impact_blackout, 'in its words')
    eq(rowsOf(5), nil, 'not a player with no teammate: no dot to lose')
    ok(rowsOf(1) == nil and rowsOf(2) == nil, 'not the runner\'s squad')
    local _ = m
end

describe('the persistent notices: instant effects have none; a solo match\'s words; br:ready; Season 1')
do
    -- DISARM, FIELD MEDIC, MAX AMMO: nothing to count down.
    reset()
    lobby()
    arm(3, 1, 'carbinerifle')
    runAt(1, 'disarm')
    roster[1].hp = 40.0
    keys[1] = true
    devRun(1, 'field_medic')
    impactsPass()
    eq(#eventsOf(BR.Net.TERMINAL_IMPACTS), 0, 'Disarm and Field medic\'s drain send no row to anybody')

    -- A SOLO MATCH: the solo line.
    reset()
    local m = newMatch(1)
    m.mode = 'solo'
    player(1, m, nil, SITE)
    player(2, m, nil, { x = SITE.x + 100.0, y = SITE.y })
    keys[1] = true
    market.wallet[1] = 1000
    runAt(1, 'scan')
    eq(rowFor(2, 'impact_scan').text, COPY.impact_scan_solo, 'outside a squad match: the solo line')
    ok(not rowFor(2, 'impact_scan').text:lower():find('squad', 1, true), 'which says no squad')

    -- BR:READY: what a restarted client was sent is forgotten, so the next
    -- pass sends its list whole.
    reset()
    lobby()
    runAt(1, 'emp')
    local n = #eventsOf(BR.Net.TERMINAL_IMPACTS, 3)
    fire(BR.Net.READY, 3)
    impactsPass()
    eq(#eventsOf(BR.Net.TERMINAL_IMPACTS, 3), n + 1, 'br:ready: its list again on the next pass')
    eq(#eventsOf(BR.Net.TERMINAL_IMPACTS, 4), 1, 'and nobody else\'s')

    -- THE LOBBY: a player whose match is gone is sent an empty list once.
    roster[3].matchId = nil
    impactsPass()
    eq(rowsOf(3), '', 'in no match any more: an empty list')

    -- SEASON 1: every list empty -- Scan's too, whose record outlives it.
    reset()
    lobby()
    runAt(1, 'scan')
    eq(rowsOf(3), 'impact_scan@end', 'a Scan row')
    season(1)
    impactsPass()
    season(2)
    ok(rowsOf(3) == '' and rowsOf(1) == '', 'off Season 2: emptied')

    -- A PLAYER WHO LEFT IS FORGOTTEN: nothing is sent to an empty seat.
    reset()
    lobby()
    runAt(1, 'emp')
    fire('playerDropped', 4)
    roster[4] = nil
    n = #eventsOf(BR.Net.TERMINAL_IMPACTS)
    impactsPass()
    eq(#eventsOf(BR.Net.TERMINAL_IMPACTS), n, 'a player who left: nothing sent after them')
end

describe('the persistent notices: one row per key, at the later end; the rest of the match outlasts any clock')
do
    -- A SOURCE OF THIS SUITE'S OWN, switched on here alone: the merge rule is
    -- the pass's, whatever source asks it twice for one key.
    local probe = nil
    T.impactSource(function(m, now, add)
        if not probe then return end
        for _, a in ipairs(probe) do add(a[1], a[2], a[3] and (now + a[3]) or nil) end
    end)
    reset()
    local m = lobby()
    local now = gameMs
    probe = {
        { 3, 'impact_emp', 60000 }, { 3, 'impact_emp', 90000 }, { 3, 'impact_emp', 30000 },
        { 4, 'impact_storm', 60000 }, { 4, 'impact_storm', nil }, { 4, 'impact_storm', 120000 },
        { 5, 'impact_emp', -1000 },
        { 6, 'impact_emp', 60000 },
    }
    player(6, m, 'C', { x = 0.0, y = 0.0 }, BR.PlayerState.OUT)
    impactsPass()
    eq(rowsOf(3), 'impact_emp@' .. (now + 90000), 'three of one key: one row, at the latest end')
    eq(rowsOf(4), 'impact_storm@end', 'the rest of the match outlasts a clock, before it or after it')
    eq(rowsOf(5), nil, 'an end already past is no row')
    eq(rowsOf(6), nil, 'and a player out of the fight has none')
    probe = nil
    impactsPass()
    ok(rowsOf(3) == '' and rowsOf(4) == '', 'the source quiet: the rows go')
end

describe('the persistent notices: two of a kind are one row, at the later end; the order is the soonest first')
do
    reset()
    local m = lobby()
    runAt(1, 'emp')
    local first = gameMs + CT.fx.empMs
    gameMs = gameMs + 30000
    keys[3] = true
    roster[3].pos = { x = SITE.x, y = SITE.y, z = 30.0 }
    runAt(3, 'emp')
    local second = gameMs + CT.fx.empMs
    eq(rowsOf(5), 'impact_emp@' .. second, 'stalled by both: one row, ending with the later')
    eq(rowsOf(1), 'impact_emp@' .. second, 'A, stalled by B\'s alone')
    eq(rowsOf(3), 'impact_emp@' .. first, 'B, by A\'s alone')
    -- THE ORDER: a timed row before one for the rest of the match.
    keys[5] = true
    roster[5].pos = { x = SITE.x, y = SITE.y, z = 30.0 }
    runAt(5, 'scan')
    eq(rowsOf(3), ('impact_emp@%d|impact_scan@end'):format(first), 'the clock first, then the rest of the match')
    local _ = m
end

-- =========================================================================
-- PART J -- round 5 (owner, 2026-10-06): Gear Up -- "any inventory item or
-- weapon which is not a heavy sniper or machine gun", to yourself, a
-- teammate, or for 200 Volts the whole squad; a consumable at its maxCarry
-- =========================================================================

--- What Gear Up handed over, one line per grant: "src:item x count".
local function given()
    local out = {}
    for _, g in ipairs(gives) do
        out[#out + 1] = ('%d:%s x%d'):format(g.src, g.stack.item, g.stack.count or 0)
    end
    return table.concat(out, ',')
end

--- The Gear Up choices a state lists as teammates: "id=name,...".
local function matesOf(state)
    local out = {}
    for _, m in ipairs(state and state.mates or {}) do out[#out + 1] = m.id .. '=' .. m.name end
    return table.concat(out, ',')
end

describe('Gear Up: registered, built, and its list -- every item but the machine guns and the Heavy Sniper')
do
    local row = T.row('gear_up')
    ok(row and row.implemented == true and T.FUNCTIONS.gear_up ~= nil, 'gear_up is built')
    eq(COPY.gear_up_name, 'Gear Up', 'the owner\'s name for it, verbatim')
    local item, who, mate = row.options[1], row.options[2], row.options[3]
    ok(item.id == 'item' and item.dropdown == true, 'the item, a dropdown')
    ok(who.id == 'who' and table.concat(who.choices, ',') == 'self,mate,squad' and who.default == 'self',
        'who gets it: you, one teammate, the whole squad -- you by default')
    ok(mate.id == 'mate' and mate.source == 'mates' and mate.dropdown == true and mate.when.who == 'mate',
        'the teammate, a dropdown of standing teammates, only for one teammate')
    eq(row.costBy.option, 'who', 'its price is by who gets it')
    eq(row.costBy.choices.squad, 200, '"for a charge of 200 volts the whole team can get them"')
    eq(row.costBy.choices.self, nil, 'yourself: free')
    eq(row.costBy.choices.mate, nil, 'a teammate: free')

    -- THE CLASS, ON EVERY GUN (config/weapons.lua), so "machine gun" is a
    -- field and not a list of names: a machine gun added later is left out.
    local CLASSES = { pistol = true, smg = true, rifle = true, shotgun = true, sniper = true, mg = true, launcher = true }
    for _, list in ipairs({ BR.Config.Weapons, BR.Config.AirdropWeapons }) do
        for _, w in ipairs(list) do
            ok(CLASSES[w.class] == true, ('%s has a class (%s)'):format(w.id, tostring(w.class)))
        end
    end
    local mgs = {}
    for _, list in ipairs({ BR.Config.Weapons, BR.Config.AirdropWeapons }) do
        for _, w in ipairs(list) do if w.class == 'mg' then mgs[#mgs + 1] = w.id end end
    end
    table.sort(mgs)
    eq(table.concat(mgs, ','), 'combatmg,combatmgmk2,gusenberg,mg,minigun',
        'the machine guns: the MG, the Gusenberg, both Combat MGs, and the minigun filed with them')

    -- THE LIST, BY ITS RULE: the weapons config's guns, its airdrop shelf,
    -- melee and throwables, then the loot config's consumables and the CPR
    -- kit, in their order -- but every 'mg' and the Heavy Sniper.
    local want = {}
    for _, list in ipairs({ BR.Config.Weapons, BR.Config.AirdropWeapons, BR.Config.Melee,
                            BR.Config.Throwables, BR.Config.Consumables }) do
        for _, d in ipairs(list) do
            if d.class ~= 'mg' and d.id ~= 'heavysniper' then want[#want + 1] = d.id end
        end
    end
    want[#want + 1] = 'cprkit'
    eq(table.concat(item.choices, ','), table.concat(want, ','), 'the list is every item but those, in the configs\' order')
    eq(#item.choices, 55, 'fifty-five items on 2026-10-06')
    eq(item.default, item.choices[1], 'and the first is the default')
    local offered = {}
    for _, id in ipairs(item.choices) do offered[id] = true end
    for _, id in ipairs({ 'heavysniper', 'mg', 'gusenberg', 'combatmg', 'combatmgmk2', 'minigun' }) do
        eq(offered[id], nil, ('%s is not offered'):format(id))
    end
    for _, id in ipairs({ 'marksmanrifle', 'sniperrifle', 'marksmanmk2', 'rpg', 'grenadelauncher', 'railgun',
                          'knife', 'grenade', 'smoke', 'minishield', 'medkit', 'repairkit', 'cprkit' }) do
        eq(offered[id], true, ('%s is offered'):format(id))
    end
    -- NEVER: what is no slot item, or no loot config's.
    -- No ammo: a pool, not a slot. (The SMG's id is also the SMG pool's
    -- name; what it hands over is the gun.)
    for _, id in ipairs(item.choices) do
        local st = T.gearStack(id)
        ok(st ~= nil and st.kind ~= BR.ItemKind.AMMO, ('%s hands over an item, never ammo'):format(id))
    end
    eq(T.gearStack('smg').kind, BR.ItemKind.WEAPON, 'smg is the SMG')
    for _, id in ipairs({ 'yubikey', 'fists', 'revivekey', 'chest', 'volts' }) do
        eq(offered[id], nil, ('never %s'):format(id))
    end
    -- EVERY ITEM'S LINE IS THE GAME'S OWN NAME FOR IT.
    for _, id in ipairs(item.choices) do
        local def = BR.Config.WeaponById[id] or BR.Config.ConsumableById[id]
        eq(COPY['gear_up_opt_item_' .. id], def and def.label, ('%s reads as its own label'):format(id))
    end
end

describe('Gear Up: yourself -- free, through the inventory\'s own door, a full stack')
do
    reset()
    lobby()
    local r = runAt(1, 'gear_up', { item = 'assaultrifle' })
    ok(r and r.ok and r.code == 'done', 'it runs', r and r.code)
    eq(given(), '1:assaultrifle x1', 'the rifle, to the runner, through BR.Inv.give')
    local g = gives[1] and gives[1].stack or {}
    ok(g.kind == BR.ItemKind.WEAPON and g.clip == BR.Config.WeaponById.assaultrifle.clip
        and g.rarity == BR.Config.WeaponById.assaultrifle.rarity,
        'loaded, at its own rarity, as a crate\'s is (its spare is the found-gun rule\'s)')
    ok(#market.charges == 0 and market.wallet[1] == 1000, 'free: no Volts asked')
    ok(keys[1] == false and T.squadUsed(1), 'the key and the squad\'s use, spent')
    ok(noticeIndex('has redeemed their special power', 3) ~= nil, 'the lobby is told')
    ok(noticeIndex(COPY.gear_up_description, 3) ~= nil, 'what it was, naming no item')
    eq(noticeIndex('used Gear Up to give you', 1), nil, 'and the runner is not told what they chose')
    eq(r and r.toast, COPY.gear_up_done, 'the done line')

    -- A CONSUMABLE AT ITS maxCarry (config: carryMax), A THROWABLE AT ITS
    -- STACK, A SHIELD (no carry ceiling) AT A FULL STACK, MELEE WITH NO
    -- MAGAZINE.
    for _, c in ipairs({
        { 'medkit', BR.ItemKind.CONSUMABLE, BR.Config.ConsumableById.medkit.carryMax },
        { 'bandage', BR.ItemKind.CONSUMABLE, BR.Config.ConsumableById.bandage.carryMax },
        { 'repairkit', BR.ItemKind.CONSUMABLE, 1 },
        { 'cprkit', BR.ItemKind.CONSUMABLE, 1 },
        { 'minishield', BR.ItemKind.CONSUMABLE, BR.Config.ConsumableById.minishield.maxStack },
        { 'grenade', BR.ItemKind.THROWABLE, BR.Config.WeaponById.grenade.maxStack },
        { 'bat', BR.ItemKind.WEAPON, 1 },
    }) do
        reset()
        lobby()
        runAt(1, 'gear_up', { item = c[1] })
        local st = gives[1] and gives[1].stack or {}
        ok(st.item == c[1] and st.kind == c[2] and st.count == c[3],
            ('%s: %s x%d'):format(c[1], c[2], c[3]), given())
    end
    eq(BR.Config.ConsumableById.medkit.carryMax, 3, 'a Med Kit comes as 3')
    eq(gives[1].stack.clip, nil, 'a bat carries no magazine')

    -- CLAMPED TO WHAT FITS: holding one Med Kit of three, two come.
    reset()
    lobby()
    rooms[1] = { n = 2 }
    runAt(1, 'gear_up', { item = 'medkit' })
    eq(given(), '1:medkit x2', 'two of three, when one is already carried')
end

describe('Gear Up: yourself -- carrying the most you may, or no room, is refused, spending nothing')
do
    for _, c in ipairs({ { 'carrymax', 'gear_full' }, { 'noroom', 'gear_no_room' } }) do
        reset()
        lobby()
        rooms[1] = { n = 0, why = c[1] }
        local r = runAt(1, 'gear_up', { item = 'medkit' })
        ok(r and r.ok == false and r.code == c[2], ('%s: %s'):format(c[1], c[2]), r and r.code)
        eq(r and r.toast, COPY[c[2]], 'in its own words')
        ok(keys[1] == true and not T.squadUsed(1) and #gives == 0, 'the key, the use and the inventory untouched')
    end
    -- THE CARD NEVER SAYS SO: a choice not made yet is no reason.
    reset()
    lobby()
    rooms[1] = { n = 0, why = 'noroom' }
    fire(BR.Net.TERMINAL_USE, 1, { terminalId = 'tower' })
    local f = listedAs(1, 'gear_up')
    ok(f and f.available == true, 'listed: available, whatever the bag holds')
end

describe('Gear Up: one standing teammate, from a dropdown -- free, and they are told')
do
    reset()
    lobby()
    player(6, matches[1], 'A', { x = C0.x + 60.0, y = C0.y }, BR.PlayerState.DBNO)
    player(7, matches[1], 'A', { x = C0.x + 70.0, y = C0.y })
    -- THE DROPDOWN: the standing teammates, never the runner, the downed or
    -- another squad -- in the state, every push.
    fire(BR.Net.TERMINAL_USE, 1, { terminalId = 'tower' })
    local st = lastOf(BR.Net.TERMINAL_OPEN, 1).state
    eq(matesOf(st), '2=p2,7=p7', 'p2 and p7: standing; p6 is downed, p3 is B')
    gameMs = gameMs + 1000
    fire(BR.Net.TERMINAL_RUN, 1, { terminalId = 'tower', functionId = 'gear_up',
                                   options = { item = 'medkit', who = 'mate', mate = '2' } })
    flush()
    local r = lastOf(BR.Net.TERMINAL_RESULT, 1)
    ok(r and r.ok and r.code == 'done', 'it runs', r and r.code)
    eq(given(), '2:medkit x3', 'three Med Kits, to p2 alone')
    ok(#market.charges == 0, 'free')
    local i = noticeIndex('used Gear Up to give you', 2)
    ok(i ~= nil, 'p2 is told', lastToast(2))
    local n = noticesTo(2)[i]
    ok(n and type(n.text) == 'table', 'with the runner\'s name as a name, not in the sentence (BR.Notice.who)')
    ok((textOf(n) or ''):find('3 Med Kits', 1, true) ~= nil, 'and what: "3 Med Kits"', textOf(n))
    ok(noticeIndex('has redeemed their special power', 2) < i, 'after the lobby\'s notice')
    eq(noticeIndex('used Gear Up to give you', 1), nil, 'the runner is not')
    eq(noticeIndex('used Gear Up to give you', 7), nil, 'nor a teammate who got nothing')

    -- NOT A STANDING TEAMMATE: downed, another squad's, the runner, nobody.
    for _, bad in ipairs({ '6', '3', '1', '99' }) do
        reset()
        lobby()
        player(6, matches[1], 'A', { x = C0.x + 60.0, y = C0.y }, BR.PlayerState.DBNO)
        local rr = runAt(1, 'gear_up', { item = 'medkit', who = 'mate', mate = bad })
        ok(rr and rr.code == 'gear_no_mate', ('mate=%s: gear_no_mate'):format(bad), rr and rr.code)
        ok(keys[1] == true and #gives == 0, 'spending nothing')
    end
    reset()
    lobby()
    local rr = runAt(1, 'gear_up', { item = 'medkit', who = 'mate' })
    eq(rr and rr.code, 'gear_no_mate', 'no teammate picked: gear_no_mate')
    -- THEIRS, IN THEIR OWN WORDS.
    for _, c in ipairs({ { 'carrymax', 'gear_full_mate' }, { 'noroom', 'gear_no_room_mate' } }) do
        reset()
        lobby()
        rooms[2] = { n = 0, why = c[1] }
        rr = runAt(1, 'gear_up', { item = 'medkit', who = 'mate', mate = '2' })
        ok(rr and rr.code == c[2] and rr.toast == COPY[c[2]], ('the teammate\'s %s: %s'):format(c[1], c[2]), rr and rr.code)
        ok(keys[1] == true and #gives == 0, 'spending nothing')
    end
end

describe('Gear Up: the whole squad, for 200 Volts -- everyone standing, or nothing is spent')
do
    reset()
    lobby()
    player(6, matches[1], 'A', { x = C0.x + 60.0, y = C0.y }, BR.PlayerState.DBNO)
    player(7, matches[1], 'A', { x = C0.x + 70.0, y = C0.y })
    local r = runAt(1, 'gear_up', { item = 'grenade', who = 'squad' })
    ok(r and r.ok and r.code == 'done', 'it runs', r and r.code)
    eq(given(), '1:grenade x3,2:grenade x3,7:grenade x3', 'everyone in the squad standing, the runner included; not p6, downed')
    ok(#market.charges == 1 and market.charges[1].cost == 200 and market.wallet[1] == 800, '200 Volts, once')
    ok(r and r.balance == 800, 'and the new balance is said')
    ok(noticeIndex('used Gear Up to give you', 2) and noticeIndex('used Gear Up to give you', 7), 'p2 and p7 are told')
    eq(noticeIndex('used Gear Up to give you', 1), nil, 'the runner is not')
    eq(noticeIndex('used Gear Up to give you', 3), nil, 'nor another squad')

    -- ONE ALREADY CARRYING THE MOST THEY MAY HAS IT: skipped, the rest get it.
    reset()
    lobby()
    rooms[2] = { n = 0, why = 'carrymax' }
    r = runAt(1, 'gear_up', { item = 'medkit', who = 'squad' })
    ok(r and r.ok, 'a mate at the ceiling does not stop it', r and r.code)
    eq(given(), '1:medkit x3', 'the runner gets it; p2 already carries three')
    -- EVERYONE THERE: refused, nothing spent.
    reset()
    lobby()
    rooms[1], rooms[2] = { n = 0, why = 'carrymax' }, { n = 0, why = 'carrymax' }
    r = runAt(1, 'gear_up', { item = 'medkit', who = 'squad' })
    ok(r and r.code == 'gear_full_squad' and r.toast == COPY.gear_full_squad, 'everyone carrying the most: gear_full_squad', r and r.code)
    ok(#market.charges == 0 and keys[1] == true and #gives == 0, 'no Volts asked, nothing spent')
    -- ANYONE WITH NO ROOM: the whole run, so 200 Volts never leave a teammate out.
    reset()
    lobby()
    rooms[2] = { n = 0, why = 'noroom' }
    r = runAt(1, 'gear_up', { item = 'assaultrifle', who = 'squad' })
    ok(r and r.code == 'gear_no_room_squad' and r.toast == COPY.gear_no_room_squad, 'a mate with no room: gear_no_room_squad', r and r.code)
    ok(#market.charges == 0 and keys[1] == true and #gives == 0, 'no Volts asked, nothing spent')
    -- SHORT OF 200: no_volts, with the figures.
    reset()
    lobby()
    market.wallet[1] = 150
    r = runAt(1, 'gear_up', { item = 'medkit', who = 'squad' })
    ok(r and r.code == 'no_volts' and r.cost == 200 and r.balance == 150, 'short: no_volts, 200 against 150', r and r.code)
    ok(#gives == 0 and keys[1] == true, 'nothing spent')
    -- FOR YOURSELF THE SAME BALANCE IS PLENTY: it is free.
    r = runAt(1, 'gear_up', { item = 'medkit', who = 'self' })
    ok(r and r.ok and market.wallet[1] == 150, 'yourself, with 150: free', r and r.code)
end

describe('Gear Up: squad choices only in a squad match; the end of the load; the dev command')
do
    -- A SOLO MATCH: the teammate and the squad are no choices -- the page
    -- does not show them, and the door refuses them.
    reset()
    local m = newMatch(1)
    m.mode = 'solo'
    player(1, m, nil, SITE)
    keys[1] = true
    market.wallet[1] = 1000
    fire(BR.Net.TERMINAL_USE, 1, { terminalId = 'tower' })
    eq(matesOf(lastOf(BR.Net.TERMINAL_OPEN, 1).state), '', 'no teammates listed')
    for _, who in ipairs({ 'mate', 'squad' }) do
        local r = runAt(1, 'gear_up', { item = 'medkit', who = who, mate = who == 'mate' and '2' or nil })
        ok(r and r.code == 'bad_option', ('who=%s outside a squad match: bad_option'):format(who), r and r.code)
    end
    ok(#gives == 0 and #market.charges == 0 and keys[1] == true, 'nothing spent')
    local r = runAt(1, 'gear_up', { item = 'medkit' })
    ok(r and r.ok and given() == '1:medkit x3', 'yourself: it runs', r and r.code)
    eq(COPY.gear_up_opt_who_solo, '', 'and the page hides "Who gets it" there')
    eq(BR.TerminalSolve.pick(COPY, 'gear_up_summary', false), COPY.gear_up_summary_solo, 'with the solo summary')

    -- THE RUNNER WENT DOWN WHILE IT LOADED: nobody standing to get it, and
    -- everything back.
    reset()
    lobby()
    fire(BR.Net.TERMINAL_USE, 1, { terminalId = 'tower' })
    gameMs = gameMs + 1000
    fire(BR.Net.TERMINAL_RUN, 1, { terminalId = 'tower', functionId = 'gear_up', options = { item = 'medkit' } })
    roster[1].state = BR.PlayerState.DBNO
    flush()
    r = lastOf(BR.Net.TERMINAL_RESULT, 1)
    ok(r and r.code == 'gear_standing' and r.toast == COPY.gear_standing, 'yourself, downed: gear_standing at the end', r and r.code)
    ok(keys[1] == true and not T.squadUsed(1) and #gives == 0, 'the key and the use given back, nothing given')

    -- THE TEAMMATE WENT DOWN WHILE IT LOADED: everything back.
    reset()
    lobby()
    fire(BR.Net.TERMINAL_USE, 1, { terminalId = 'tower' })
    gameMs = gameMs + 1000
    fire(BR.Net.TERMINAL_RUN, 1, { terminalId = 'tower', functionId = 'gear_up',
                                   options = { item = 'medkit', who = 'mate', mate = '2' } })
    ok(keys[1] == false, 'accepted: the key is spent while it loads')
    roster[2].state = BR.PlayerState.DBNO
    flush()
    r = lastOf(BR.Net.TERMINAL_RESULT, 1)
    ok(r and r.code == 'gear_no_mate', 'the mate went down: gear_no_mate at the end', r and r.code)
    ok(keys[1] == true and not T.squadUsed(1) and #gives == 0, 'the key and the use given back, nothing given')
    -- AND A SQUAD RUN'S 200 VOLTS COME BACK TOO.
    reset()
    lobby()
    fire(BR.Net.TERMINAL_USE, 1, { terminalId = 'tower' })
    gameMs = gameMs + 1000
    fire(BR.Net.TERMINAL_RUN, 1, { terminalId = 'tower', functionId = 'gear_up',
                                   options = { item = 'medkit', who = 'squad' } })
    ok(market.wallet[1] == 800, 'accepted: 200 Volts spent')
    rooms[2] = { n = 0, why = 'noroom' }
    flush()
    r = lastOf(BR.Net.TERMINAL_RESULT, 1)
    ok(r and r.code == 'gear_no_room_squad', 'a mate\'s bag filled meanwhile: refused at the end', r and r.code)
    ok(market.wallet[1] == 1000 and keys[1] == true and #gives == 0, 'the 200 Volts, the key and the use given back')

    -- `brterminal run gear_up [item=] [who=] [mate=]`: no key, no Volts.
    reset()
    lobby()
    local said = devRun(1, 'gear_up item=medkit')
    ok(said:find('ok (done)', 1, true) ~= nil and given() == '1:medkit x3', 'brterminal run gear_up item=medkit', said)
    said = devRun(1, 'gear_up item=railgun who=mate mate=2')
    ok(said:find('ok (done)', 1, true) ~= nil and given() == '1:medkit x3,2:railgun x1',
        'brterminal run gear_up item=railgun who=mate mate=2', said)
    said = devRun(1, 'gear_up item=grenade who=squad')
    ok(said:find('ok (done)', 1, true) ~= nil and #market.charges == 0, 'who=squad charges nothing from the dev command', said)
    said = devRun(1, 'gear_up item=minigun')
    ok(said:find('does not take those options', 1, true) ~= nil, 'a machine gun is no choice', said)
    said = devRun(1, 'gear_up item=heavysniper')
    ok(said:find('does not take those options', 1, true) ~= nil, 'nor the Heavy Sniper', said)
    said = devRun(1, 'gear_up item=medkit who=mate mate=4')
    ok(said:find('refused (gear_no_mate)', 1, true) ~= nil, 'a downed player of another squad: refused', said)
end

describe('Gear Up: every grant through the inventory, pinned by text')
do
    -- A GRANTED GUN IS THE SERVER'S OWN SLOT FROM THE START, so the shot
    -- validator's held check and the strip's `ourWeapon` -- both read the
    -- slot -- never flag it: the file asks BR.Inv.roomFor and hands over with
    -- BR.Inv.give, and nothing else touches an inventory or a ped.
    local src = (readFile(ROOT .. 'br_core/server/terminalfx/gear_up.lua') or ''):gsub('%-%-[^\n]*', '')
    ok(src:find('BR.Inv.give(', 1, true) ~= nil and src:find('BR.Inv.roomFor(', 1, true) ~= nil,
        'through BR.Inv.roomFor and BR.Inv.give')
    for _, bad in ipairs({ 'GiveWeaponToPed', 'TriggerClientEvent', '.slots', 'INV_SET', 'BR.Inv.push', 'dropForPlayer' }) do
        ok(not src:find(bad, 1, true), ('and never %s'):format(bad))
    end
end

-- =========================================================================
-- PART D -- the client
-- =========================================================================

describe('client: Scan\'s and the bounty\'s marks')
do
    local serverBR = BR
    BR = nil
    local blips, nextBlip = {}, 0
    function AddBlipForCoord(x, y, z)
        nextBlip = nextBlip + 1
        blips[nextBlip] = { x = x, y = y, z = z }
        return nextBlip
    end
    function DoesBlipExist(b) return blips[b] ~= nil end
    function RemoveBlip(b) blips[b] = nil end
    function SetBlipSprite(b, v) blips[b].sprite = v; blips[b].colour = 0 end
    function SetBlipColour(b, v) blips[b].colour = v end
    function SetBlipScale(b, v) blips[b].scale = v end
    function SetBlipDisplay(b, v) blips[b].display = v end
    function SetBlipAsShortRange() end
    function SetBlipCoords(b, x, y) blips[b].x, blips[b].y = x, y end
    local clientHandlers, loops = {}, {}
    function RegisterNetEvent() end
    function AddEventHandler(name, fn) clientHandlers[name] = fn end
    function IsDuplicityVersion() return false end
    loadAll({
        'br_lib/shared/enums.lua',
        'br_lib/shared/protocol.lua',
        'br_lib/config/terminals.lua',
        'br_lib/shared/terminal_solve.lua',
    })
    local seasonNow = 2
    BR.Season = { has = function(name) return name == 'terminals' and seasonNow == 2 end }
    BR.NativeTruthy = function(v) return v == true or v == 1 end
    BR.Native = { blipName = function(b, name) blips[b].name = name end }
    BR.Loop = { SLOW = 'slow', register = function(_, name, fn) loops[name] = fn end }
    BR.State = { me = { state = BR.PlayerState.ALIVE } }
    loadAll({ 'br_core/client/terminalfx.lua' })
    local F = BR.TerminalFx
    local A = BR.Config.Terminals.art

    local function count() local n = 0 for _ in pairs(blips) do n = n + 1 end return n end
    local function first(pred)
        for _, b in pairs(blips) do if pred(b) then return b end end
        return nil
    end

    clientHandlers[BR.Net.TERMINAL_SCAN]({ matchId = 1, list = {
        { s = 3, x = 10.0, y = 20.0 }, { s = 4, x = 30.0, y = 40.0, down = true } } })
    eq(select(1, F.counts()), 2, 'one mark per opponent')
    eq(count(), 4, 'drawn on both maps (two blips each)')
    local d = {}
    for _, b in pairs(blips) do d[b.display] = (d[b.display] or 0) + 1 end
    ok(d[3] == 2 and d[5] == 2, 'the pause map and the minimap')
    local b3 = first(function(b) return b.x == 10.0 end)
    ok(b3 and b3.sprite == A.scan.sprite and b3.colour == A.scan.colour and b3.name == BR.Config.Terminals.copy.scan_blip,
        'in the art block\'s look, named from the copy')

    clientHandlers[BR.Net.TERMINAL_SCAN]({ matchId = 1, list = { { s = 3, x = 11.0, y = 21.0 } } })
    eq(select(1, F.counts()), 1, 'an opponent no longer sent is dropped')
    eq(count(), 2, 'both of its blips')
    ok(first(function(b) return b.x == 11.0 end) ~= nil, 'and a moved one is moved, not rebuilt')
    eq(nextBlip, 4, 'no blip was made to move it')

    clientHandlers[BR.Net.TERMINAL_BOUNTY]({ matchId = 1, list = { { s = 1, x = 5.0, y = 6.0 } } })
    local bb = first(function(b) return b.x == 5.0 end)
    ok(bb and bb.sprite == 58 and bb.colour == 3, 'the bounty: the owner\'s blip 58, colour 3')
    eq(bb and bb.name, BR.Config.Terminals.copy.bounty_blip, 'named from the copy')
    clientHandlers[BR.Net.TERMINAL_BOUNTY]({ matchId = 1, list = {} })
    eq(select(2, F.counts()), 0, 'an empty list clears it')

    -- THE LOBBY, AND SILENCE.
    loops['terminalfx.clear']()
    eq(select(1, F.counts()), 1, 'a fresh scan survives the pass')
    BR.State.me.state = BR.PlayerState.LOBBY
    loops['terminalfx.clear']()
    eq(select(1, F.counts()), 0, 'back in the lobby, the marks go')
    eq(count(), 0, 'every blip with them')
    BR.State.me.state = BR.PlayerState.ALIVE
    clientHandlers[BR.Net.TERMINAL_SCAN]({ matchId = 2, list = { { s = 9, x = 1.0, y = 1.0 } } })
    gameMs = gameMs + 3 * BR.Config.Terminals.fx.scanPingMs + 1
    loops['terminalfx.clear']()
    eq(select(1, F.counts()), 0, 'and when the pushes stop for three periods')

    -- THE SQUAD PANEL'S GLYPH, AND SEASON 1.
    eq(F.mateBountyGlyph(true), A.bountyGlyph, 'the panel mark is the art block\'s glyph')
    eq(F.mateBountyGlyph(nil), nil, 'and nothing without the bit')
    local sprite, colour = F.mateBountyLook()
    ok(sprite == 58 and colour == 69, 'teammates\' look: blip 58, colour 69')
    seasonNow = 1
    loops['terminalfx.clear']()
    clientHandlers[BR.Net.TERMINAL_SCAN]({ matchId = 3, list = { { s = 9, x = 1.0, y = 1.0 } } })
    eq(count(), 0, 'Season 1 draws nothing')
    eq(F.mateBountyGlyph(true), nil, 'and shows no mark')

    BR = serverBR
end

-- =========================================================================
-- PART D2 -- the client halves of wave A (2026-10-06), loaded from the
-- manifest after client/terminalfx.lua, over the same modeled blips
-- =========================================================================

--- A client world: BR swapped for a fresh client one, the blip natives
--- modeled, client/terminalfx.lua and every wave A client file loaded.
--- `W.done()` puts the server's BR back.
local function clientWorld()
    local W = { serverBR = BR, blips = {}, nextBlip = 0, handlers = {}, loops = {}, season = 2 }
    BR = nil
    function AddBlipForCoord(x, y, z)
        W.nextBlip = W.nextBlip + 1
        W.blips[W.nextBlip] = { x = x, y = y, z = z }
        return W.nextBlip
    end
    function DoesBlipExist(b) return W.blips[b] ~= nil end
    function RemoveBlip(b) W.blips[b] = nil end
    function SetBlipSprite(b, v) W.blips[b].sprite = v; W.blips[b].colour = 0 end
    function SetBlipColour(b, v) W.blips[b].colour = v end
    function SetBlipScale(b, v) W.blips[b].scale = v end
    function SetBlipDisplay(b, v) W.blips[b].display = v end
    function SetBlipAsShortRange() end
    function SetBlipCoords(b, x, y) W.blips[b].x, W.blips[b].y = x, y end
    function RegisterNetEvent() end
    -- EVERY HANDLER ON A NAME, IN ORDER, as the platform runs them: several
    -- function files answer `onResourceStop`, and keeping only the last one
    -- registered would test one of them and silently drop the rest.
    function AddEventHandler(name, fn)
        local prev = W.handlers[name]
        W.handlers[name] = prev and function(...) prev(...); return fn(...) end or fn
    end
    function IsDuplicityVersion() return false end
    loadAll({
        'br_lib/shared/enums.lua',
        'br_lib/shared/protocol.lua',
        'br_lib/config/terminals.lua',
        'br_lib/shared/terminal_solve.lua',
    })
    BR.Season = { has = function(name) return name == 'terminals' and W.season == 2 end }
    BR.NativeTruthy = function(v) return v == true or v == 1 end
    BR.Native = { blipName = function(b, name) W.blips[b].name = name end }
    BR.Loop = { SLOW = 'slow', register = function(_, name, fn) W.loops[name] = fn end }
    BR.State = { me = { state = BR.PlayerState.ALIVE } }
    loadAll({ 'br_core/client/terminalfx.lua' })
    loadAll(fxFiles('client'))
    W.F, W.A, W.C = BR.TerminalFx, BR.Config.Terminals.art, BR.Config.Terminals.copy
    function W.net(ev, d) W.handlers[ev](d) end
    --- One SLOW pass: client/terminalfx.lua's, the ONE loop callback the
    --- terminal marks register (the wave A files hook it through F.onSlow).
    function W.slow()
        local n = 0
        for _ in pairs(W.loops) do n = n + 1 end
        ok(n == 1, 'the terminal marks register one SLOW callback between them', n)
        W.loops['terminalfx.clear']()
    end
    function W.count(pred)
        local n = 0
        for _, b in pairs(W.blips) do if not pred or pred(b) then n = n + 1 end end
        return n
    end
    function W.done() BR = W.serverBR end
    return W
end

describe('client: the persistent notices -- the server\'s list to the HUD, and down in the lobby (round 4)')
do
    local W = clientWorld()
    local F = W.F
    local ui = {}
    function TriggerEvent(name, kind, data)
        if name == 'br:ui:sendLocal' and kind == BR.Nui.IMPACTS then ui[#ui + 1] = data end
    end
    local function last() return ui[#ui] end
    eq(BR.Nui.IMPACTS, 'impacts', 'the envelope kind is `impacts`')

    W.net(BR.Net.TERMINAL_IMPACTS, { list = {
        { key = 'impact_emp', text = 'EMP: any vehicle you drive stalls.', endsAt = 123456 },
        { key = 'impact_scan', text = 'Scan: another squad can see where you are.', tail = 'Until the match ends' },
        { key = 'bad', text = '' },
        { key = 'worse', endsAt = 5 },
        'not a row',
        { key = 'nan', text = 'A clock that is not one.', endsAt = 0 / 0, tail = 'Until the match ends' },
    } })
    local d = last()
    ok(d and #d.list == 3, 'handed over, the rows with no text dropped', d and #d.list)
    ok(d.list[1].endsAt == 123456 and d.list[1].tail == nil, 'a timed row: its end, no tail')
    ok(d.list[2].endsAt == nil and d.list[2].tail == 'Until the match ends', 'a row for the rest of the match: its tail')
    ok(d.list[3].endsAt == nil and d.list[3].tail == 'Until the match ends', 'an end that is not a number: the tail instead')
    eq(F.impactCount(), 3, 'three up')

    -- A BR_UI RESTART: the list again.
    local n = #ui
    W.handlers['br:ui:ready']()
    ok(#ui == n + 1 and #last().list == 3, 'br:ui:ready: handed over again')

    -- THE SLOW PASS COSTS NOTHING WHILE IN A MATCH, and takes them down in the
    -- lobby.
    n = #ui
    W.slow()
    eq(#ui, n, 'a SLOW pass in a match sends nothing')
    BR.State.me.state = BR.PlayerState.LOBBY
    W.slow()
    ok(#ui == n + 1 and #last().list == 0 and F.impactCount() == 0, 'the lobby: an empty list')
    W.slow()
    eq(#ui, n + 1, 'and nothing more after')
    BR.State.me.state = BR.PlayerState.ALIVE

    -- AN EMPTY LIST FROM THE SERVER, WITH NOTHING UP: nothing to send.
    n = #ui
    W.net(BR.Net.TERMINAL_IMPACTS, { list = {} })
    eq(#ui, n, 'nothing up and nothing sent: no envelope')
    W.handlers['br:ui:ready']()
    eq(#ui, n, 'and a br_ui restart with nothing up sends none')

    -- SEASON 1: down, and nothing taken on.
    W.net(BR.Net.TERMINAL_IMPACTS, { list = { { key = 'k', text = 'Up.', endsAt = 9 } } })
    eq(F.impactCount(), 1, 'one up')
    W.season = 1
    W.slow()
    ok(F.impactCount() == 0 and #last().list == 0, 'off Season 2: down')
    W.net(BR.Net.TERMINAL_IMPACTS, { list = { { key = 'k', text = 'Up.', endsAt = 9 } } })
    eq(F.impactCount(), 0, 'and a list arriving there is not shown')
    W.season = 2
    W.slow()

    -- BR_CORE STOPPING: down with it.
    W.net(BR.Net.TERMINAL_IMPACTS, { list = { { key = 'k', text = 'Up.', endsAt = 9 } } })
    W.handlers.onResourceStop('another_resource')
    eq(F.impactCount(), 1, 'another resource stopping: still up')
    W.handlers.onResourceStop('br_core')
    ok(F.impactCount() == 0 and #last().list == 0, 'br_core stopping: an empty list')
    TriggerEvent = nil
    W.done()
end

-- =========================================================================
-- PART H2 -- the client halves of wave C (2026-10-06), EMP's as round 4
-- rebuilt it
-- =========================================================================

-- ── EMP's client world: the vehicles this client knows, modeled ──
--
-- [handle] = { net, class, engine, noAutoStart, undriveable, driver }. The
-- player's ped is VW.me; VW.inVeh is the vehicle it is in. BOOL natives answer
-- 1/0, as they may in game. Every vehicle native is counted, so "nothing per
-- frame" is a number.
local VW = { cars = {}, me = 4242, inVeh = 0, timers = {}, calls = 0 }
local function vcar(h) return VW.cars[h] end
local function counted(fn)
    return function(...)
        VW.calls = VW.calls + 1
        return fn(...)
    end
end
NetworkDoesNetworkIdExist = counted(function(net)
    for _, c in pairs(VW.cars) do if c.net == net then return 1 end end
    return 0
end)
NetworkGetEntityFromNetworkId = counted(function(net)
    for h, c in pairs(VW.cars) do if c.net == net then return h end end
    return 0
end)
NetworkGetNetworkIdFromEntity = counted(function(h) return vcar(h) and vcar(h).net or 0 end)
DoesEntityExist = counted(function(h) return vcar(h) and 1 or 0 end)
GetVehicleClass = counted(function(h) return vcar(h) and vcar(h).class or 0 end)
GetIsVehicleEngineRunning = counted(function(h) return (vcar(h) and vcar(h).engine) and 1 or 0 end)
SetVehicleEngineOn = counted(function(h, on, _, noAuto)
    local c = vcar(h)
    if c then c.engine, c.noAutoStart = on, noAuto end
end)
SetVehicleUndriveable = counted(function(h, v)
    local c = vcar(h)
    if c then c.undriveable = v end
end)
GetPedInVehicleSeat = counted(function(h, seat)
    local c = vcar(h)
    if seat ~= -1 or not c then return 0 end
    return c.driver or 0
end)
PlayerPedId = function() return VW.me end
GetVehiclePedIsIn = counted(function() return VW.inVeh end)
GetCurrentResourceName = GetCurrentResourceName or function() return 'br_core' end
Citizen = Citizen or {}
Citizen.SetTimeout = function(ms, fn) VW.timers[#VW.timers + 1] = { ms = ms, fn = fn } end

--- A vehicle this client knows: net id = handle + 1000.
local function vnew(h, o)
    o = o or {}
    VW.cars[h] = { net = h + 1000, class = o.class or 1, engine = o.engine == true, driver = 0 }
end

--- This player takes the wheel of `h` (or a passenger seat, `seat` ~= -1),
--- and, with `event`, the game raises the entering event.
local function vgetIn(W, h, seat, event)
    VW.inVeh = h
    if (seat or -1) == -1 then VW.cars[h].driver = VW.me end
    if event ~= false then W.handlers.gameEventTriggered('CEventNetworkPlayerEnteredVehicle', { 128, h }) end
end
local function vgetOut(h)
    VW.inVeh = 0
    if VW.cars[h] and VW.cars[h].driver == VW.me then VW.cars[h].driver = 0 end
end

local function vstalled(h)
    local c = VW.cars[h]
    return c.engine == false and c.noAutoStart == true and c.undriveable == true
end
local function vfree(h)
    local c = VW.cars[h]
    return c.undriveable == false and c.noAutoStart == false
end

local function vtimers()
    local due = VW.timers
    VW.timers = {}
    table.sort(due, function(a, b) return a.ms < b.ms end)
    for _, t in ipairs(due) do t.fn() end
end

local function vreset()
    VW.cars, VW.timers, VW.inVeh, VW.calls = {}, {}, 0, 0
end

describe('client: EMP -- this player\'s driving stalls on the fact\'s change, whatever they drive')
do
    vreset()
    local W = clientWorld()
    local F = W.F
    vnew(1, { engine = true })
    vgetIn(W, 1)                                -- driving, no EMP
    eq(VW.cars[1].undriveable, nil, 'no EMP: getting in writes nothing')
    W.net(BR.Net.TERMINAL_EMP, { matchId = 1, leftMs = 180000, liveMs = 180000 })
    ok(vstalled(1), 'the fact lands while driving: engine off at once, no auto-start, undriveable')
    local stalling, n = F.empState()
    ok(stalling and n == 1, 'stalling, one hold written', ('%s %d'):format(tostring(stalling), n))

    -- SOMEBODY STARTS AN ENGINE UNDER IT (a refuel's ignition, a revive
    -- hold's siren): the SLOW pass stalls it again.
    VW.cars[1].engine = true
    W.slow()
    ok(vstalled(1), 'an engine started under it is stopped again on the SLOW pass')

    -- OUT OF IT: the hold is undone on this copy, the engine left as it is.
    vgetOut(1)
    W.slow()
    ok(vfree(1) and VW.cars[1].engine == false, 'getting out: driveable, free to start, still off')
    eq(select(2, F.empState()), 0, 'nothing written left')

    -- ANOTHER CAR, ANYWHERE: stalled as they get in, and as ownership arrives.
    vnew(2, { engine = true })
    vgetIn(W, 2)
    ok(vstalled(2), 'getting into another car mid-EMP: stalled at once')
    VW.cars[2].engine = true                    -- the old owner's sync, before ownership moved
    vtimers()
    ok(vstalled(2), 'and held again as ownership reaches the driver')
    vgetOut(2)
    W.slow()

    -- A PASSENGER IS NOT THE DRIVER; A SHUFFLE INTO THE SEAT IS.
    vnew(3, { engine = true })
    vgetIn(W, 3, 0)
    eq(VW.cars[3].undriveable, nil, 'a passenger: nothing written (the driver decides)')
    VW.cars[3].driver = VW.me                   -- shuffled over, no entering event
    W.slow()
    ok(vstalled(3), 'shuffled into the driver\'s seat: the SLOW pass stalls it')

    -- THE END, FROM THE SERVER: freed and started for the driver.
    W.net(BR.Net.TERMINAL_EMP, { matchId = 1 })
    ok(vfree(3) and VW.cars[3].engine == true, 'it ends while driving: driveable, and the engine starts again')
    ok(not F.empState() and select(2, F.empState()) == 0, 'not stalling, nothing written')
    vgetOut(3)
    W.done()
end

describe('client: EMP -- spared, a car somebody else stalled works; never an aircraft or a bicycle')
do
    vreset()
    local W = clientWorld()
    local F = W.F
    -- THE RUNNER'S SQUAD: told an EMP lasts, not that their driving stalls.
    W.net(BR.Net.TERMINAL_EMP, { matchId = 1, liveMs = 180000 })
    eq((F.empState()), false, 'spared: not stalling')
    vnew(4, { engine = false })
    VW.cars[4].undriveable, VW.cars[4].noAutoStart = true, true   -- another driver's stall on this copy
    vgetIn(W, 4)
    ok(vfree(4) and VW.cars[4].engine == true, 'getting into a car another driver stalled: freed and started')
    vtimers()
    VW.cars[4].engine = false                   -- the driver switches it off themselves
    for _ = 1, 3 do W.slow() end
    eq(VW.cars[4].engine, false, 'and afterwards the SLOW pass leaves their engine alone')
    eq(select(2, F.empState()), 0, 'a spared driver writes no hold')
    vgetOut(4)

    -- NO EMP AT ALL: getting in frees nothing (it touches no vehicle).
    W.net(BR.Net.TERMINAL_EMP, { matchId = 1 })
    vnew(5)
    VW.cars[5].undriveable = true
    vgetIn(W, 5)
    eq(VW.cars[5].undriveable, true, 'with no EMP in the match, getting in writes nothing')
    vgetOut(5)

    -- AN AIRCRAFT AND A BICYCLE ARE NEVER HELD.
    W.net(BR.Net.TERMINAL_EMP, { matchId = 1, leftMs = 180000, liveMs = 180000 })
    vnew(6, { class = 15, engine = true })
    vgetIn(W, 6)
    ok(VW.cars[6].engine == true and VW.cars[6].undriveable == nil, 'a helicopter: never stalled (it would fall)')
    vgetOut(6)
    vnew(7, { class = 13 })
    vgetIn(W, 7)
    eq(VW.cars[7].undriveable, nil, 'a bicycle: no engine, never held')
    vgetOut(7)
    W.done()
end

describe('client: EMP -- it ends on its own clock, in the lobby, off Season 2 and as br_core stops')
do
    vreset()
    local W = clientWorld()
    local F = W.F
    local t0 = gameMs
    vnew(8, { engine = true })
    vgetIn(W, 8)
    W.net(BR.Net.TERMINAL_EMP, { matchId = 1, leftMs = 180000, liveMs = 180000 })
    ok(vstalled(8), 'stalled')
    -- NO END HAS COME FROM THE SERVER: its own deadline ends it.
    gameMs = t0 + 179999
    VW.cars[8].engine = true
    W.slow()
    ok(vstalled(8), 'at 2:59.999 still held')
    gameMs = t0 + 180000
    W.slow()
    ok(vfree(8) and VW.cars[8].engine == true, 'at 3:00, on the client\'s own clock: freed and started')

    -- AND FORGOTTEN WITH IT: the SLOW pass goes back to costing nothing.
    VW.calls = 0
    for _ = 1, 5 do W.slow() end
    eq(VW.calls, 0, 'over on its own clock: five SLOW passes call no vehicle native')

    -- OVER ON ITS OWN CLOCK BEFORE ANY SLOW PASS SAW IT, and straight into
    -- another car: the old hold is undone, and the new car is not touched --
    -- no EMP lasts, so there is nothing to free it from.
    t0 = gameMs
    W.net(BR.Net.TERMINAL_EMP, { matchId = 1, leftMs = 1000, liveMs = 1000 })
    ok(vstalled(8), 'a short one: stalled')
    gameMs = t0 + 1000
    vgetOut(8)
    vnew(10, { engine = false })
    VW.cars[10].undriveable = true             -- somebody else's write, on this copy
    vgetIn(W, 10)
    ok(vfree(8), 'the car it held is freed')
    eq(VW.cars[10].undriveable, true, 'and the car got into is left as it was: no EMP lasts')
    vgetOut(10)
    vgetIn(W, 8, -1, false)

    -- THE LOBBY.
    W.net(BR.Net.TERMINAL_EMP, { matchId = 1, leftMs = 180000, liveMs = 180000 })
    ok(vstalled(8), 'stalled again')
    BR.State.me.state = BR.PlayerState.LOBBY
    W.slow()
    ok(vfree(8), 'the lobby: freed')
    ok(not F.empState() and select(2, F.empState()) == 0, 'and the fact forgotten')
    BR.State.me.state = BR.PlayerState.ALIVE

    -- SEASON 1.
    W.net(BR.Net.TERMINAL_EMP, { matchId = 1, leftMs = 180000, liveMs = 180000 })
    W.season = 1
    W.slow()
    ok(vfree(8) and not F.empState(), 'off Season 2: freed, forgotten')
    W.net(BR.Net.TERMINAL_EMP, { matchId = 1, leftMs = 180000, liveMs = 180000 })
    eq((F.empState()), false, 'and a fact arriving there is not taken on')
    W.season = 2
    W.slow()

    -- BR_CORE STOPPING -- every file's handler runs.
    W.net(BR.Net.TERMINAL_EMP, { matchId = 1, leftMs = 180000, liveMs = 180000 })
    ok(vstalled(8), 'stalled')
    W.handlers.onResourceStop('another_resource')
    ok(vstalled(8), 'another resource stopping: nothing')
    W.handlers.onResourceStop('br_core')
    ok(vfree(8), 'br_core stopping: freed')

    -- A CAR OUT OF SCOPE WHEN IT ENDS: no copy here to undo.
    W.net(BR.Net.TERMINAL_EMP, { matchId = 1, leftMs = 180000, liveMs = 180000 })
    vgetOut(8)
    VW.cars[8] = nil
    W.slow()
    eq(select(2, F.empState()), 0, 'a held car gone from scope: forgotten, nothing to write')
    W.net(BR.Net.TERMINAL_EMP, { matchId = 1 })
    W.done()
end

describe('client: EMP -- nothing per frame, and nothing at all with nothing to do')
do
    vreset()
    local W = clientWorld()
    VW.calls = 0
    for _ = 1, 5 do W.slow() end
    eq(VW.calls, 0, 'no EMP and nothing written: five SLOW passes call no vehicle native')
    vnew(9, { engine = true })
    VW.inVeh = 9
    VW.cars[9].driver = VW.me
    VW.calls = 0
    W.handlers.gameEventTriggered('CEventNetworkPlayerEnteredVehicle', { 128, 9 })
    eq(VW.calls, 0, 'and getting into a car with no EMP calls none either')
    W.handlers.gameEventTriggered('CEventNetworkEntityDamage', { 9 })
    eq(VW.calls, 0, 'nor does another game event')
    -- WHILE ONE LASTS: a handful a second.
    W.net(BR.Net.TERMINAL_EMP, { matchId = 1, leftMs = 180000, liveMs = 180000 })
    VW.calls = 0
    W.slow()
    ok(VW.calls > 0 and VW.calls <= 10, 'while it lasts: a few natives on the SLOW pass', VW.calls)
    W.net(BR.Net.TERMINAL_EMP, { matchId = 1 })
    VW.inVeh = 0
    W.done()
end

-- =========================================================================
-- PART E -- the hooks, by text
-- =========================================================================

describe('the hooks the rest of br_core makes')
do
    local party = readFile(ROOT .. 'br_core/server/party.lua') or ''
    ok(party:find('bounty = (BR.Terminal ~= nil and BR.Terminal.hasBounty ~= nil', 1, true) ~= nil,
        'the squad beacon carries the bounty bit (party.lua)')
    local state = readFile(ROOT .. 'br_core/client/state.lua') or ''
    ok(state:find('BR.TerminalFx.mateBountyGlyph(b and b.bounty)', 1, true) ~= nil,
        'the squad panel row reads it as a glyph (state.lua)')
    local mates = readFile(ROOT .. 'br_core/client/squadmates.lua') or ''
    ok(mates:find('BR.TerminalFx.mateBountyLook()', 1, true) ~= nil and mates:find("looks[m.src] ~= look", 1, true) ~= nil,
        'teammates\' blip changes look with the bit, on change only (squadmates.lua)')
    -- WAVE C: Comms blackout's two hooks (the beacon's half is driven above,
    -- on the real party.lua; the client's is tools/test_client.lua's).
    ok(party:find('BR.Terminal.beaconDark(squadMatch[squadId], squadId, now)', 1, true) ~= nil
            and party:find('for _, m in ipairs(members) do m.x, m.y = nil, nil end', 1, true) ~= nil,
        'the squad beacon asks the Comms blackout and leaves the positions off (party.lua)')
    ok(mates:find('if m.x == nil or m.y == nil then', 1, true) ~= nil
            and mates:find('dropBlip(m.src)', 1, true) ~= nil,
        'and a row with no position takes the dot down (squadmates.lua)')
    local panel = readFile('ui-src/src/hud/SquadPanel.tsx') or ''
    ok(panel:find('<BountyMark glyph={m.bounty} />', 1, true) ~= nil, 'the panel draws the mark (SquadPanel.tsx)')
    local manifest = readFile(ROOT .. 'br_core/fxmanifest.lua') or ''
    local t = manifest:find("'server/terminal.lua'", 1, true)
    local fx = manifest:find("'server/terminalfx.lua'", 1, true)
    ok(t and fx and fx > t, 'server/terminalfx.lua loads after server/terminal.lua')
    ok(manifest:find("'client/terminalfx.lua'", 1, true) ~= nil, 'client/terminalfx.lua is loaded')
    -- WAVE A: one file per function, each after the file whose helpers it reads.
    local cfx = manifest:find("'client/terminalfx.lua'", 1, true)
    for _, side in ipairs({ 'server', 'client' }) do
        local base = side == 'server' and fx or cfx
        for _, f in ipairs(fxFiles(side)) do
            local at = manifest:find("'" .. f:sub(#'br_core/' + 1) .. "'", 1, true)
            ok(at and base and at > base, ('%s loads after %s/terminalfx.lua'):format(f, side))
            ok(readFile(ROOT .. f) ~= nil, ('%s exists'):format(f))
        end
    end
    ok(#fxFiles('server') >= 1, 'the manifest lists the wave A function files')
    local built = 0
    for _, row in ipairs(CT.functions) do
        if row.implemented then built = built + 1 end
    end
    eq(built, 4 + #fxFiles('server'), 'every built row past the first four is a function file')
end

realPrint(('%d passed, %d failed'):format(pass, fail))
if fail > 0 then realExit(1) end
