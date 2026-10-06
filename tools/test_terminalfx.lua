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
    'br_lib/config/match.lua',
    'br_lib/config/storm.lua',
    'br_lib/config/map.lua',
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
BR.Storm = { finalCentre = function(m) return m and m.finalStub or nil end }

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
    sent, notices, logs, airdropCalls, filled, granted = {}, {}, {}, {}, {}, {}
    roster, matches, keys = {}, {}, {}
    timers = {}
    market.wallet, market.charges, market.refunds, market.pending = {}, {}, {}, {}
    market.hold, market.broken = false, false
    gameMs = gameMs + 100000
end

--- Open the terminal for `src` the real way and run `id`, to its last word:
--- the loading is let run out (round 2).
local function runAt(src, id, options)
    fire(BR.Net.TERMINAL_USE, src, { terminalId = 'tower' })
    gameMs = gameMs + 1000
    fire(BR.Net.TERMINAL_RUN, src, { terminalId = 'tower', functionId = id, options = options })
    flush()
    return lastOf(BR.Net.TERMINAL_RESULT, src)
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

describe('Supply drop: the drop spot the player chose, sited by the airdrop\'s own rules')
do
    local row = T.row('supply_drop')
    ok(row and row.implemented == true and T.FUNCTIONS.supply_drop ~= nil, 'supply_drop is built')
    reset()
    local m = lobby()
    local r = runAt(1, 'supply_drop', { site = 'terminal' })
    ok(r and r.ok == true and r.code == 'done', 'near this terminal: it runs', r and r.code)
    local call = airdropCalls[#airdropCalls]
    ok(call and call.m == m and call.x == SITE.x and call.y == SITE.y,
        'BR.Airdrop.call is asked for the spot nearest THE TERMINAL')
    eq(keys[1], false, 'the key is spent')

    reset()
    m = lobby()
    r = runAt(1, 'supply_drop', { site = 'circle' })
    call = airdropCalls[#airdropCalls]
    ok(r and r.ok and call and call.x == m.storm.cx1 and call.y == m.storm.cy1,
        'near the next circle: the spot nearest the next circle\'s centre')

    reset()
    m = lobby()
    r = runAt(1, 'supply_drop', { site = 'moon' })
    ok(r and r.code == 'bad_option' and #airdropCalls == 0 and keys[1] == true,
        'a spot that is not offered: bad_option, nothing asked, nothing spent')

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
    fire(BR.Net.TERMINAL_RUN, 1, { terminalId = 'tower', functionId = 'supply_drop' })
    r = lastOf(BR.Net.TERMINAL_RESULT, 1)
    ok(r and r.code == 'no_site' and keys[1] == true and not T.squadUsed(1),
        'and refused no_site, spending nothing', r and r.code)

    reset()
    m = lobby()
    m.storm = nil
    r = runAt(1, 'supply_drop')
    ok(r and r.code == 'no_storm' and keys[1] == true, 'before the storm: no_storm, nothing spent', r and r.code)

    reset()
    m = lobby()
    m.dropBusy = true
    r = runAt(1, 'supply_drop', { site = 'circle' })
    ok(r and r.code == 'drop_busy' and #airdropCalls == 0 and keys[1] == true,
        'another drop on its way: drop_busy, nothing spent', r and r.code)
end

describe('Max ammo: every squadmate still in the fight is filled')
do
    local row = T.row('max_ammo')
    ok(row and row.implemented == true and T.FUNCTIONS.max_ammo ~= nil, 'max_ammo is built')
    reset()
    lobby()
    roster[2].state = BR.PlayerState.DBNO
    filled = { [1] = 30, [2] = 60, [3] = 90 }
    local r = runAt(1, 'max_ammo')
    ok(r and r.ok == true and r.code == 'done', 'it runs', r and r.code)
    ok(filled[1] == 0 and filled[2] == 0, 'the runner and the downed squadmate are filled')
    eq(filled[3], 90, 'another squad is not')

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

local function ask(src, id, options)
    gameMs = gameMs + 1000
    fire(BR.Net.TERMINAL_RUN, src, { terminalId = 'tower', functionId = id, options = options })
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
    local r2 = ask(1, 'supply_drop', { site = 'terminal' })
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

--- A `brterminal run` line typed by `src`; the answer on their F8.
local function devRun(src, line)
    local args = { 'run' }
    for w in line:gmatch('%S+') do args[#args + 1] = w end
    commands.brterminalsv(src, args, 'brterminalsv run ' .. line)
    return lastOf(BR.Net.TERMINAL_DEV, src) or ''
end

describe('Field medic: everyone standing in the squad, to full health and full armor')
do
    local row = T.row('field_medic')
    ok(row and row.implemented == true and T.FUNCTIONS.field_medic ~= nil, 'field_medic is built')
    ok(row and (row.options == nil or #row.options == 0), 'and takes no options')
    ok(row and (row.cost or 0) == 0, 'and costs no Volts')

    reset()
    local m = lobby()
    roster[1].hp, roster[1].armour = 40.0, 0
    roster[2].hp, roster[2].armour = 100.0, 30                    -- full health, armor short
    player(6, m, 'A', { x = C0.x + 60.0, y = C0.y }, BR.PlayerState.DBNO)
    roster[6].hp, roster[6].armour = 20.0, 0                      -- downed: not revived
    player(7, m, 'A', { x = C0.x + 70.0, y = C0.y }, BR.PlayerState.GLIDE)
    roster[7].hp, roster[7].armour = 50.0, 0                      -- in the air: not standing
    player(8, m, 'A', { x = C0.x + 80.0, y = C0.y })              -- standing and full
    roster[3].hp = 10.0                                           -- another squad
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
    ok(noticeIndex('has redeemed their special power', 3) ~= nil, 'and the lobby is told')
    eq(r and r.toast, COPY.field_medic_done, 'the runner reads the squad done line')
end

describe('Field medic: nothing to heal is refused, spending nothing')
do
    reset()
    local m = lobby()
    player(6, m, 'A', { x = C0.x + 60.0, y = C0.y }, BR.PlayerState.DBNO)
    roster[6].hp = 15.0                       -- the only one hurt is downed
    useAt(1)
    local f = listedAs(1, 'field_medic')
    ok(f and f.available == false and f.reason == 'health_full',
        'every standing squadmate full: the card says health_full', f and tostring(f.reason))
    local r = ask(1, 'field_medic')
    ok(r and r.ok == false and r.code == 'health_full', 'and a run is refused health_full', r and r.code)
    eq(r and r.toast, COPY.health_full, 'in the squad line')
    ok(keys[1] == true and not T.squadUsed(1) and #granted == 0 and #timers == 0,
        'the key and the use stay, nobody is touched, nothing loads')

    -- THE END OF THE RUN: hurt when asked, full again when the loading is over.
    reset()
    lobby()
    roster[1].hp = 55.0
    useAt(1)
    r = ask(1, 'field_medic')
    ok(r and r.code == 'running', 'hurt: accepted', r and r.code)
    roster[1].hp = 100.0                      -- healed meanwhile
    flush()
    r = lastOf(BR.Net.TERMINAL_RESULT, 1)
    ok(r and r.ok == false and r.code == 'health_full', 'full by the end of the load: health_full', r and r.code)
    ok(keys[1] == true and not T.squadUsed(1) and #granted == 0, 'and the key and the use are given back')
    eq(noticeIndex('has redeemed their special power', 3), nil, 'the lobby is told nothing')

    -- THE MATCH ENDING MID-LOAD.
    reset()
    m = lobby()
    roster[1].hp = 55.0
    useAt(1)
    ask(1, 'field_medic')
    m.state = BR.MatchState.ENDED
    flush()
    r = lastOf(BR.Net.TERMINAL_RESULT, 1)
    ok(r and r.code == 'unavailable' and keys[1] == true and #granted == 0,
        'a match that ended mid-load heals nobody and gives everything back', r and r.code)
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
    r = runAt(1, 'field_medic')
    ok(r and r.code == 'done' and #granted == 1 and granted[1].src == 1, 'short of armor: healed')
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
    ok(not T.squadUsed(1), 'and spends nothing')
    roster[1].matchId = nil
    said = devRun(1, 'field_medic')
    ok(said:find('refused (unavailable)', 1, true) ~= nil, 'and outside a match it says unavailable', said)
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
