-- Unit tests for #396's round 5 tools that come DOWN FROM THE SKY: Vehicle
-- drop and Airstrike (owner, 2026-10-06).
--
-- The door they run through -- the session, the key, the squad's one use, the
-- options, the Volts -- is tools/test_terminal.lua's. This file stands up the
-- REAL br_core/server/terminal.lua, server/terminalfx.lua and every
-- server/terminalfx/ file the manifest lists, over a stubbed roster, market,
-- scheduler and vehicle layer, and the REAL client/terminalfx.lua and each
-- tool's client half over modeled natives:
--
--   PART A  Vehicle drop, the server: the car (an armored Kuruma, through the
--           one creation path the vehicle rules guard), next to the runner or
--           a standing teammate, on a spot the client of the player it is for
--           found and the server checked itself; the descent, the blip and its
--           end; every refusal spending nothing; the dev command.
--   PART B  Vehicle drop, the client: the look for a road or open ground, the
--           descent's copy and its canopy, the real car hidden until it lands,
--           the blip, and nothing per frame once it has.
--   PART C  Airstrike, the server: the spot, the plan (unguided, evenly over
--           the circle, one after another), the damage the server works out
--           (the falloff, friendly fire, the kill the runner's, never a
--           teammate's), the vehicles' owners told, the persistent notice,
--           the refusals, the match's end, br:ready, the dev command, and the
--           rough circles of the map pick -- who may see them, never on
--           anybody, fixed for the match, Ghost and Scan.
--   PART D  Airstrike, the client: the rough circles, the circle, the flare,
--           the rockets and their blasts -- particles and a sound, never an
--           explosion -- the owner's write to a vehicle, and nothing per frame
--           once the last rocket has landed.
--
-- Run via tools/verify.sh, or directly:  lua tools/test_terminalstrike.lua

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

--- The function files br_core's manifest lists under `<side>/terminalfx/`.
local function fxFiles(side)
    local out = {}
    local text = readFile(ROOT .. 'br_core/fxmanifest.lua') or ''
    for f in text:gmatch("'(" .. side .. "/terminalfx/[%w_]+%.lua)'") do
        out[#out + 1] = 'br_core/' .. f
    end
    return out
end

--- GTA's one-at-a-time hash (tools/check_vehicles.lua's), so a model name is
--- the number config/vehicles.lua's rows are written in.
local function joaat(s)
    local h = 0
    s = tostring(s):lower()
    for i = 1, #s do
        h = (h + s:byte(i)) & 0xFFFFFFFF
        h = (h + (h << 10)) & 0xFFFFFFFF
        h = (h ~ (h >> 6)) & 0xFFFFFFFF
    end
    h = (h + (h << 3)) & 0xFFFFFFFF
    h = (h ~ (h >> 11)) & 0xFFFFFFFF
    h = (h + (h << 15)) & 0xFFFFFFFF
    return h
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

local function near(got, want, tol, name)
    ok(type(got) == 'number' and math.abs(got - want) <= tol, name,
        ('got %s, want %s (+-%s)'):format(tostring(got), tostring(want), tostring(tol)))
end

local logs = {}
function print(s) logs[#logs + 1] = tostring(s) end

local function errored()
    for _, l in ipairs(logs) do
        if l:find('errored', 1, true) or l:find('stack traceback', 1, true) then return l end
    end
    return nil
end

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
function IsDuplicityVersion() return true end
function GetHashKey(s) return joaat(s) end

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
    -- The vehicles the gamemode refuses: the car a Vehicle drop builds is
    -- asked of the REAL ruling.
    'br_lib/config/vehicles.lua',
    'br_lib/config/loot.lua',
    'br_lib/shared/season.lua',
    'br_lib/config/seasons.lua',
    'br_lib/config/terminals.lua',
    'br_lib/shared/storm_solve.lua',
    'br_lib/shared/storm_shape.lua',
    'br_lib/shared/terminal_solve.lua',
    'br_lib/shared/shop_solve.lua',
})
BR.Config.Market = { currency = 'Volts' }

local CT = BR.Config.Terminals
local COPY = CT.copy
local FX = CT.fx
local TS = BR.TerminalSolve
BR.Season.strict = true

local function season(n)
    BR.Season.boot(function(name)
        return name == 'br_season' and tostring(n) or ''
    end, function() end)
end
season(2)

-- ---------------------------------------------------------------- stubs ---

local jobs, handlers = {}, {}
local timers = {}
function SetTimeout(ms, fn) timers[#timers + 1] = { at = gameMs + ms, fn = fn } end
local sent = {}          -- TriggerClientEvent: { event, src, payload }
local notices = {}       -- BR.Server.notify: { target, text, tone }
local keys = {}          -- [src] = true while holding a Yubikey

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
    restore = function(lic)
        local src = tonumber(tostring(lic):match('(%d+)$'))
        if not src or keys[src] == true then return false end
        keys[src] = true
        return true
    end,
}
local market = { wallet = {}, charges = {}, refunds = {} }
BR.Market = {
    balanceOf = function(src) return market.wallet[src] or 0 end,
    licenseOf = function(src) return roster[src] and ('license:' .. src) or nil end,
    charge = function(src, cost, reason, done)
        market.charges[#market.charges + 1] = { src = src, cost = cost, reason = reason }
        if (market.wallet[src] or 0) < cost then done(false, 'cannot afford it') return end
        market.wallet[src] = market.wallet[src] - cost
        done(true, nil, market.wallet[src])
    end,
    refund = function(lic, amount)
        market.refunds[#market.refunds + 1] = { lic = lic, amount = amount }
        local src = tonumber(tostring(lic):match('(%d+)$'))
        market.wallet[src] = (market.wallet[src] or 0) + amount
    end,
}
BR.Storm = {
    finalCentre = function() return nil end,
    aim = function() return nil, 'no_circle' end,
}

loadAll({
    'br_core/server/terminal.lua',
    'br_core/server/terminalfx.lua',
})
loadAll(fxFiles('server'))

local T = BR.Terminal

-- THE VEHICLE LAYER, ON ITS CONTRACT (server/vehicles.lua's; tools/verify.sh
-- keeps the creation in that file): spawnOwned asks the real ruling and builds
-- one, ridingIn answers the vehicle a ped is in. Server-side natives on those
-- vehicles, modeled.
local vehicles, vehSeq, spawns, riding = {}, 500, {}, {}
local spawnBroken = false
BR.Vehicles = {
    spawnOwned = function(model, vtype, x, y, z, h, forSrc, bucket)
        spawns[#spawns + 1] = { model = model, vtype = vtype, x = x, y = y, z = z, h = h,
                                forSrc = forSrc, bucket = bucket }
        if BR.Config.VehicleRefusalFor(joaat(model)) ~= nil then
            return nil, nil, 'the allowlist refuses that model'
        end
        if spawnBroken then return nil, nil, 'the engine refused it (handle 0)' end
        vehSeq = vehSeq + 1
        vehicles[vehSeq] = { model = model, x = x, y = y, z = z, h = h, bucket = bucket,
                             frozen = false, locked = 1, engine = 1000.0 }
        return vehSeq, vehSeq + 9000, nil
    end,
    ridingIn = function(ped) return riding[ped] end,
}
-- The other functions' doors, as far as listing them asks (their own suites
-- hold the real ones): nobody carries anything.
BR.Inv = {
    of = function() return { slots = {} } end,
    ammoRoom = function() return 0 end,
    hasGuns = function() return false end,
    roomFor = function(_, stack) return stack.count or 1, nil end,
    give = function() return true end,
}
BR.Airdrop = { busy = function() return false end, candidate = function() return nil end }
function DoesEntityExist(v) return vehicles[v] ~= nil end
function FreezeEntityPosition(v, on) if vehicles[v] then vehicles[v].frozen = on end end
function SetVehicleDoorsLocked(v, s) if vehicles[v] then vehicles[v].locked = s end end
function GetVehicleEngineHealth(v) return vehicles[v] and vehicles[v].engine or 0.0 end
function GetEntityCoords(v)
    local r = vehicles[v]
    return r and { x = r.x, y = r.y, z = r.z } or nil
end

local function fire(name, src, ...)
    local prev = source
    source = src
    for _, fn in ipairs(handlers[name] or {}) do fn(...) end
    source = prev
end

--- Let every pending timer run, the clock moved to each one's time.
local function flush(untilMs)
    for _ = 1, 50 do
        if #timers == 0 then return end
        table.sort(timers, function(a, b) return a.at < b.at end)
        local t = timers[1]
        if untilMs and t.at > untilMs then return end
        table.remove(timers, 1)
        if t.at > gameMs then gameMs = t.at end
        t.fn()
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

local C0 = { x = 1200.0, y = -800.0 }
local SITE = { id = 'tower', x = C0.x + 1.0, y = C0.y, z = 30.0, h = 90.0 }
CT.sites = { SITE }

local function newMatch(id, mode)
    local m = {
        id = id, seq = id, state = BR.MatchState.PLAYING, mode = mode or 'squad',
        bucket = 100 + id,
        startedAt = gameMs - 125000,
        storm = BR.BuildStormRecord(2, C0.x, C0.y, 1500.0, C0.x + 50.0, C0.y, 800.0,
            gameMs, 600000, 60000, 1.0, 4242),
    }
    matches[id] = m
    return m
end

local function player(src, m, squad, at, state)
    roster[src] = {
        src = src, name = 'p' .. src, state = state or BR.PlayerState.ALIVE,
        matchId = m and m.id or nil, squadId = squad, ped = 7000 + src,
        pos = at and { x = at.x, y = at.y, z = at.z or 30.0 } or nil,
        hp = 100.0, armour = 100, kills = 0,
    }
end

local function reset()
    flush()
    sent, notices, logs = {}, {}, {}
    roster, matches, keys = {}, {}, {}
    timers = {}
    market.wallet, market.charges, market.refunds = {}, {}, {}
    vehicles, spawns, riding = {}, {}, {}
    spawnBroken = false
    -- The last block's drops: their match is gone, so the pass takes them off.
    T.stepDrops(gameMs)
    for s = 1, 32 do T.forgetImpacts(s) end
    gameMs = gameMs + 100000
end

--- Let the loading run out, and nothing scheduled after it (a drop's landing).
local function finishLoad()
    flush(gameMs + (CT.runMaxMs or 5000) + 1)
end

--- Open the terminal for `src` the real way and ask for `id`. With `hold`, the
--- load is left running (the answer is `running`); without, it is let run out.
local function runAt(src, id, options, hold, at)
    fire(BR.Net.TERMINAL_USE, src, { terminalId = 'tower' })
    gameMs = gameMs + 1000
    fire(BR.Net.TERMINAL_RUN, src, { terminalId = 'tower', functionId = id, options = options, at = at })
    if not hold then finishLoad() end
    return lastOf(BR.Net.TERMINAL_RESULT, src)
end

--- A `brterminal run` line typed by `src`; the answer on their F8.
local function devRun(src, line)
    local args = { 'run' }
    for w in line:gmatch('%S+') do args[#args + 1] = w end
    commands.brterminalsv(src, args, 'brterminalsv run ' .. line)
    return lastOf(BR.Net.TERMINAL_DEV, src) or ''
end

local function nothingSpent(src, label)
    eq(keys[src], true, label .. ': the key stays')
    ok(not T.squadUsed(src), label .. ': the squad\'s use stays')
    local paid = 0
    for _, c in ipairs(market.charges) do if c.src == src then paid = paid + c.cost end end
    local back = 0
    for _, r in ipairs(market.refunds) do if r.lic == 'license:' .. src then back = back + r.amount end end
    eq(paid - back, 0, label .. ': no Volts')
end

local function listed(src, id)
    local st = T.state(src, T.session(src))
    for _, f in ipairs(st.functions) do
        if f.id == id then return f end
    end
    return nil
end

--- Two squads and a solo player in one match: A = 1, 2; B = 3, 4; solo 5.
local function lobby(mode)
    local m = newMatch(1, mode)
    player(1, m, 'A', SITE)
    player(2, m, 'A', { x = C0.x + 200.0, y = C0.y })
    player(3, m, 'B', { x = C0.x + 300.0, y = C0.y + 10.0 })
    player(4, m, 'B', { x = C0.x + 310.0, y = C0.y - 10.0 }, BR.PlayerState.DBNO)
    player(5, m, nil, { x = C0.x - 500.0, y = C0.y })
    keys[1] = true
    for src = 1, 5 do market.wallet[src] = 1000 end
    return m
end

-- =========================================================================
-- PART A -- Vehicle drop, the server
-- =========================================================================

--- The spot the client of `src` answers with: `dx`, `dy` from where the
--- server has them.
local function answer(src, dx, dy, extra)
    local find = lastOf(BR.Net.TERMINAL_DROP_FIND, src)
    local p = roster[src].pos
    local d = { nonce = find and find.nonce, x = p.x + dx, y = p.y + dy, z = p.z - 0.4, h = 45.0 }
    for k, v in pairs(extra or {}) do d[k] = v end
    fire(BR.Net.TERMINAL_DROP_SPOT, src, d)
    return d
end

describe('Vehicle drop: registered, built, 100 Volts, its options and its numbers')
do
    local row = T.row('vehicle_drop')
    ok(row ~= nil and row.implemented == true, 'the row is listed and built')
    ok(T.FUNCTIONS.vehicle_drop and T.FUNCTIONS.vehicle_drop.run and T.FUNCTIONS.vehicle_drop.refuse
        and T.FUNCTIONS.vehicle_drop.prepare and T.FUNCTIONS.vehicle_drop.abandon,
        'its server half: refuse, prepare, run and abandon')
    eq(row and row.category, 'supply', 'under Supply')
    eq(T.costOf(row), 100, '100 Volts (proposed)')
    eq(row and row.squadWide, true, "squad-wide: the blip is on the squad's maps")
    ok(row and row.spot == nil, 'no map pick ("let\'s not have them pick a location")')
    local to, mate = row.options[1], row.options[2]
    ok(to and to.id == 'to' and table.concat(to.choices, ',') == 'self,mate' and to.default == 'self',
        'next to: you (the default) or a teammate')
    ok(mate and mate.id == 'mate' and mate.source == 'mates' and mate.dropdown == true
        and mate.when and mate.when.to == 'mate', 'the teammate: a dropdown of the standing ones, for "A teammate"')
    eq(FX.dropModel, 'kuruma2', '"Kuruma is good!": the armored Kuruma')
    eq(BR.Config.VehicleRefusalFor(joaat(FX.dropModel)), nil, 'and the vehicle rules admit it')
    ok(BR.Config.VehicleRefusalFor(joaat('lazer')) ~= nil, '(they refuse a jet: the same ruling)')
    eq(FX.dropRadiusM, 40.0, '"within 40m of them"')
    ok(COPY.vehicle_drop_what:find('within 40 meters', 1, true) ~= nil
        and COPY.vehicle_drop_what_solo:find('within 40 meters', 1, true) ~= nil
        and COPY.drop_ground:find('40 meters', 1, true) ~= nil
        and COPY.drop_ground_mate:find('40 meters', 1, true) ~= nil,
        'and every line that says how far says 40')
    ok(COPY.vehicle_drop_what:find('no weapons', 1, true) ~= nil, 'the page says it has no weapons')
    ok(FX.dropFallMs >= 5000 and FX.dropFallMs <= 15000 and COPY.vehicle_drop_duration:find('about 10 seconds', 1, true),
        'the descent is about the ten seconds its page says', FX.dropFallMs)
end

describe('Vehicle drop: next to you -- found by your client, checked by the server, built where it lands')
do
    reset()
    local m = lobby('squad')
    local r = runAt(1, 'vehicle_drop', { to = 'self' }, true)
    eq(r and r.code, 'running', 'accepted, loading')
    local find = lastOf(BR.Net.TERMINAL_DROP_FIND, 1)
    ok(find and find.nonce and find.r == 40.0 and find.minM == FX.dropMinM and find.everyMs == FX.dropAskMs
        and find.forMs == FX.dropAskForMs, 'the runner\'s client is asked to look, within 40 m', find and find.r)
    eq(#eventsOf(BR.Net.TERMINAL_DROP_FIND, 2), 0, 'nobody else is asked')
    eq(#market.charges, 1, '100 Volts charged as it was accepted')
    eq(market.charges[1].cost, 100, '100')
    local spot = answer(1, 18.0, 6.0)
    ok(T.dropAsk(1) and T.dropAsk(1).spot and T.dropAsk(1).spot.x == spot.x, 'its answer is kept')
    finishLoad()
    local res = lastOf(BR.Net.TERMINAL_RESULT, 1)
    eq(res and res.code, 'done', 'done')
    eq(res and res.toast, COPY.vehicle_drop_done .. ' ' .. COPY.balance_new:gsub('{volts}', '900 Volts'),
        'the done line, and the new balance')
    eq(#spawns, 1, 'one car built')
    local sp = spawns[1]
    ok(sp.model == 'kuruma2' and sp.vtype == 'automobile', 'the armored Kuruma, as an automobile')
    ok(sp.x == spot.x and sp.y == spot.y and math.abs(sp.z - (spot.z + 1.0)) < 1e-9 and sp.h == 45.0,
        'on the spot found, held a meter over the ground', ('%s %s %s'):format(sp.x, sp.y, sp.z))
    eq(sp.bucket, m.bucket, "in the match's own routing bucket")
    local veh = next(vehicles)
    ok(vehicles[veh].frozen == true and vehicles[veh].locked == 2, 'frozen and locked while it comes down')
    -- THE DESCENT TO EVERYBODY, THE BLIP TO THE SQUAD.
    for src = 1, 5 do
        local d = lastOf(BR.Net.TERMINAL_DROP, src)
        ok(d and d.netId == veh + 9000 and d.x == spot.x and d.tLand - d.tRelease == FX.dropFallMs
            and d.alt == FX.dropAltM, ('player %d is sent the descent'):format(src))
        eq(d and d.blip, (src == 1 or src == 2) or nil, ('player %d: the blip only to squad A'):format(src))
    end
    local stop = lastOf(BR.Net.TERMINAL_DROP_FIND, 1)
    ok(stop and stop.stop == true and stop.nonce == find.nonce, 'the look is stopped')
    local told = false
    for _, n in ipairs(notices) do
        if (textOf(n) or ''):find(COPY.vehicle_drop_description, 1, true) then told = true end
    end
    ok(told, 'the lobby is told: "has redeemed their special power: Vehicle drop..."')
    local self = false
    for _, n in ipairs(noticesTo(1)) do
        if ((type(n.text) == 'table' and n.text.text) or n.text or ''):find('used Vehicle drop', 1, true) then self = true end
    end
    ok(not self, 'and the runner, who chose it, is not sent vehicle_drop_received')
    eq(#T.dropsLive(), 1, 'its blip is up')

    -- IT LANDS: let go.
    gameMs = gameMs + FX.dropFallMs
    flush()
    ok(vehicles[veh].frozen == false and vehicles[veh].locked == 1, 'at the end of its fall: unfrozen, unlocked')
    jobs['terminal.drops']()
    eq(#T.dropsLive(), 1, 'nobody in it yet: the blip stays')
    ok(errored() == nil, 'clean', errored())
end

describe('Vehicle drop: the blip -- until one of the squad gets in, it is wrecked or gone, or the match ends')
do
    local function dropped(label)
        reset()
        local m = lobby('squad')
        runAt(1, 'vehicle_drop', nil, true)
        answer(1, 15.0, 0.0)
        finishLoad()
        local veh = next(vehicles)
        ok(veh ~= nil, label .. ': dropped')
        return m, veh
    end

    -- GETTING IN BEFORE IT LANDS DOES NOT COUNT (the doors are locked).
    local m, veh = dropped('in it')
    riding[roster[2].ped] = veh
    T.stepDrops(gameMs)
    eq(#T.dropsLive(), 1, 'a seat before it lands is not getting in')
    gameMs = gameMs + FX.dropFallMs
    flush()
    -- A PLAYER OF ANOTHER SQUAD GETTING IN IS NOT IT EITHER.
    riding = { [roster[3].ped] = veh }
    T.stepDrops(gameMs)
    eq(#T.dropsLive(), 1, 'another squad in it: the blip stays')
    riding = { [roster[2].ped] = veh }
    sent = {}
    T.stepDrops(gameMs)
    eq(#T.dropsLive(), 0, 'a squadmate in it: the blip is off')
    for src = 1, 5 do
        local d = lastOf(BR.Net.TERMINAL_DROP, src)
        eq(d and d.off, (src == 1 or src == 2) or nil, ('player %d: told to take it off only in squad A'):format(src))
    end

    m, veh = dropped('wrecked')
    gameMs = gameMs + FX.dropFallMs
    flush()
    vehicles[veh].engine = -4000.0
    T.stepDrops(gameMs)
    eq(#T.dropsLive(), 0, 'wrecked: off')

    m, veh = dropped('gone')
    vehicles[veh] = nil
    T.stepDrops(gameMs)
    eq(#T.dropsLive(), 0, 'gone (deleted, or the platform took it): off')

    m, veh = dropped('the match')
    m.state = BR.MatchState.ENDED
    T.stepDrops(gameMs)
    eq(#T.dropsLive(), 0, 'the match is over: off')

    m, veh = dropped('season')
    season(1)
    T.stepDrops(gameMs)
    season(2)
    eq(#T.dropsLive(), 0, 'off Season 2: off')

    -- MOVED: an opponent pushed or drove it.
    m, veh = dropped('moved')
    gameMs = gameMs + FX.dropFallMs
    flush()
    sent = {}
    vehicles[veh].x = vehicles[veh].x + 1.0
    T.stepDrops(gameMs)
    eq(#eventsOf(BR.Net.TERMINAL_DROP), 0, 'a meter is not a move')
    vehicles[veh].x = vehicles[veh].x + 30.0
    T.stepDrops(gameMs)
    local mv = lastOf(BR.Net.TERMINAL_DROP, 2)
    ok(mv and mv.x == vehicles[veh].x and mv.netId == nil and mv.off == nil, 'moved 31 m: the squad\'s blip follows')
    eq(#eventsOf(BR.Net.TERMINAL_DROP, 3), 0, 'and nobody else is told')
    eq(#T.dropsLive(), 1, 'still up')

    -- A SQUADMATE'S CLIENT RESTARTS: the blip again; another squad's: nothing.
    sent = {}
    fire(BR.Net.READY, 2)
    fire(BR.Net.READY, 3)
    local again = lastOf(BR.Net.TERMINAL_DROP, 2)
    ok(again and again.blip == true and again.id ~= nil, 'br:ready: the squadmate gets the blip again')
    eq(lastOf(BR.Net.TERMINAL_DROP, 3), nil, 'another squad\'s does not')
    ok(errored() == nil, 'clean', errored())
end

describe('Vehicle drop: next to a standing teammate -- their client looks, and they are told')
do
    reset()
    lobby('squad')
    local r = runAt(1, 'vehicle_drop', { to = 'mate', mate = '2' }, true)
    eq(r and r.code, 'running', 'accepted')
    local find = lastOf(BR.Net.TERMINAL_DROP_FIND, 2)
    ok(find and find.nonce, "the TEAMMATE's client is asked to look")
    eq(lastOf(BR.Net.TERMINAL_DROP_FIND, 1), nil, "the runner's is not")
    -- AN ANSWER FROM ANYBODY ELSE, OR FOR ANOTHER SEARCH, IS NOT TAKEN.
    local p2 = roster[2].pos
    fire(BR.Net.TERMINAL_DROP_SPOT, 1, { nonce = find.nonce, x = p2.x + 5, y = p2.y + 10, z = p2.z, h = 0.0 })
    ok(T.dropAsk(1).spot == nil, 'the runner answering for the teammate: not taken')
    fire(BR.Net.TERMINAL_DROP_SPOT, 2, { nonce = find.nonce + 1, x = p2.x + 5, y = p2.y + 10, z = p2.z, h = 0.0 })
    ok(T.dropAsk(1).spot == nil, 'a wrong nonce: not taken')
    local spot = answer(2, -20.0, 12.0)
    finishLoad()
    eq(lastOf(BR.Net.TERMINAL_RESULT, 1).code, 'done', 'done')
    ok(spawns[1] and spawns[1].x == spot.x and spawns[1].y == spot.y, 'it comes down next to the teammate')
    local toMate = noticesTo(2)
    local got = nil
    for _, n in ipairs(toMate) do
        if type(n.text) == 'table' and (n.text.text or ''):find('used Vehicle drop', 1, true) then got = n end
    end
    ok(got ~= nil, 'the teammate is told who sent it (vehicle_drop_received)')
    ok(got and got.text.parts and got.text.parts[1] and got.text.parts[1].b == 'p1',
        "the runner's name as a name, drawn bold (BR.Notice.who)")
    for _, n in ipairs(noticesTo(1)) do
        ok(not ((type(n.text) == 'table' and n.text.text or n.text or ''):find('used Vehicle drop', 1, true)),
            'the runner is not')
    end
    eq(lastOf(BR.Net.TERMINAL_DROP, 2).blip, true, 'the squad gets the blip')
    ok(errored() == nil, 'clean', errored())
end

describe('Vehicle drop: the spot is the server\'s to take -- near them, at their height, clear, on the map')
do
    reset()
    local m = lobby('squad')
    runAt(1, 'vehicle_drop', nil, true)
    local a = T.dropAsk(1)
    answer(1, 60.0, 0.0)
    ok(a.spot == nil, '60 m away (past 40 + the sample\'s slack): not taken')
    answer(1, 30.0, 0.0, { z = roster[1].pos.z + 40.0 })
    ok(a.spot == nil, '40 m over their head: not taken')
    answer(1, 0.0, 2.0)
    ok(a.spot == nil, 'two meters from the runner: never on a player')
    roster[2].pos = { x = SITE.x + 20.0, y = SITE.y, z = 30.0 }
    answer(1, 21.0, 1.0)
    ok(a.spot == nil, 'on a teammate: not taken')
    answer(1, 10.0, 0.0, { x = 0 / 0 })
    ok(a.spot == nil, 'not a number: not taken')
    local good = answer(1, -25.0, 0.0)
    ok(a.spot and a.spot.x == good.x, 'a good spot is')
    answer(1, 0.0, 0.0, { none = true })
    ok(a.spot and a.spot.x == good.x, '`none` after it changes nothing: the last good spot stands')
    answer(1, 70.0, 0.0)
    ok(a.spot and a.spot.x == good.x, 'nor does a bad one')
    -- AND IT IS ASKED AGAIN WHEN IT DROPS: a player walked onto it meanwhile.
    roster[3].pos = { x = good.x + 1.0, y = good.y, z = 30.0 }
    finishLoad()
    local res = lastOf(BR.Net.TERMINAL_RESULT, 1)
    eq(res and res.code, 'drop_ground', 'somebody stands on it when it drops: refused, drop_ground')
    nothingSpent(1, 'drop_ground')
    eq(#spawns, 0, 'nothing built')
    eq(res and res.toast, COPY.drop_ground, 'in its own line')

    -- OFF THE MAP: dropCheck's own bounds (BR.Config.Map.InBounds).
    eq(TS.dropCheck({ x = 6000.0, y = 6000.0, z = 30.0, h = 0.0 }, { x = 5990.0, y = 6000.0, z = 30.0 },
        {}, FX, BR.Config.Map.InBounds), 'bounds', 'outside the play area: bounds')
    eq(TS.dropCheck({ x = C0.x, y = C0.y, z = 30.0, h = 0.0 }, { x = C0.x + 10.0, y = C0.y, z = 30.0 },
        {}, FX, BR.Config.Map.InBounds), nil, 'inside it, near them, clear: fine')
    eq(TS.dropCheck({ x = C0.x + 45.5, y = C0.y, z = 30.0, h = 0.0 }, { x = C0.x, y = C0.y, z = 30.0 },
        {}, FX), nil, '45.5 m: inside 40 + the 6 m of slack')
    eq(TS.dropCheck({ x = C0.x + 46.5, y = C0.y, z = 30.0, h = 0.0 }, { x = C0.x, y = C0.y, z = 30.0 },
        {}, FX), 'far', '46.5 m: far')
    eq(TS.dropCheck({ x = C0.x, y = C0.y, z = 30.0 }, { x = C0.x, y = C0.y, z = 30.0 }, {}, FX), 'shape',
        'no heading: shape')
    eq(TS.dropCheck({ x = C0.x, y = C0.y, z = 30.0, h = 0.0 }, { x = C0.x + 5, y = C0.y, z = 30.0 },
        { { x = C0.x + 3.9, y = C0.y } }, FX), 'crowd', 'a player 3.9 m off: crowd')
    eq(TS.dropCheck({ x = C0.x, y = C0.y, z = 30.0, h = 0.0 }, { x = C0.x + 5, y = C0.y, z = 30.0 },
        { { x = C0.x + 4.1, y = C0.y } }, FX), nil, 'and 4.1 m off is clear')
    ok(m ~= nil and errored() == nil, 'clean', errored())
end

describe('Vehicle drop: refused, spending nothing -- every reason, as asked and as the load ends')
do
    -- NO ANSWER AT ALL (a client that never looked): drop_ground, all of it back.
    reset()
    lobby('squad')
    local r = runAt(1, 'vehicle_drop')
    eq(r and r.code, 'drop_ground', 'nobody answered: drop_ground')
    nothingSpent(1, 'no answer')
    eq(#spawns, 0, 'nothing built')

    -- THE TEAMMATE'S, IN ITS OWN LINE.
    reset()
    lobby('squad')
    r = runAt(1, 'vehicle_drop', { to = 'mate', mate = '2' })
    eq(r and r.code, 'drop_ground_mate', 'a teammate\'s client with no spot: drop_ground_mate')
    eq(r and r.toast, COPY.drop_ground_mate, 'its line')
    nothingSpent(1, 'drop_ground_mate')
    local stop = lastOf(BR.Net.TERMINAL_DROP_FIND, 2)
    ok(stop and stop.stop == true, "the teammate's look is stopped")

    -- NOT A STANDING TEAMMATE: downed, another squad's, the runner, nobody.
    reset()
    lobby('squad')
    roster[2].state = BR.PlayerState.DBNO
    r = runAt(1, 'vehicle_drop', { to = 'mate', mate = '2' })
    eq(r and r.code, 'drop_no_mate', 'a downed teammate: drop_no_mate')
    eq(r and r.toast, COPY.drop_no_mate, 'its line')
    nothingSpent(1, 'downed teammate')
    eq(#market.charges, 0, 'refused before the market is asked')
    for _, mate in ipairs({ '3', '1', '99' }) do
        gameMs = gameMs + 1000
        r = runAt(1, 'vehicle_drop', { to = 'mate', mate = mate })
        eq(r and r.code, 'drop_no_mate', ('mate %s: drop_no_mate'):format(mate))
    end
    gameMs = gameMs + 1000
    r = runAt(1, 'vehicle_drop', { to = 'mate' })
    eq(r and r.code, 'drop_no_mate', 'a teammate picked and none named: drop_no_mate')
    nothingSpent(1, 'no teammate')

    -- A SOLO MATCH HAS NO TEAMMATE CHOICE.
    reset()
    local m = lobby('solo')
    roster[2].squadId = nil
    r = runAt(1, 'vehicle_drop', { to = 'mate', mate = '2' })
    eq(r and r.code, 'bad_option', 'a teammate in a solo match: bad_option')
    nothingSpent(1, 'solo mate')
    gameMs = gameMs + 1000
    r = runAt(1, 'vehicle_drop', { to = 'self' }, true)
    eq(r and r.code, 'running', 'next to yourself, in a solo match: fine')
    answer(1, 12.0, 0.0)
    finishLoad()
    eq(lastOf(BR.Net.TERMINAL_RESULT, 1).code, 'done', 'done')
    ok(not lastOf(BR.Net.TERMINAL_RESULT, 1).toast:lower():find('squad', 1, true), 'its toast says no squad')
    ok(m ~= nil, 'solo')

    -- THE RUNNER DOWN AS IT LOADS: everything back.
    reset()
    lobby('squad')
    runAt(1, 'vehicle_drop', nil, true)
    answer(1, 14.0, 0.0)
    roster[1].state = BR.PlayerState.DBNO
    finishLoad()
    r = lastOf(BR.Net.TERMINAL_RESULT, 1)
    eq(r and r.code, 'drop_target', 'the runner went down while it loaded: drop_target')
    keys[1] = keys[1]
    nothingSpent(1, 'drop_target')
    eq(#spawns, 0, 'nothing built')
    ok(lastOf(BR.Net.TERMINAL_DROP_FIND, 1).stop == true, 'and the look stopped (abandon)')

    -- THE TEAMMATE DOWN AS IT LOADS.
    reset()
    lobby('squad')
    runAt(1, 'vehicle_drop', { to = 'mate', mate = '2' }, true)
    answer(2, 14.0, 0.0)
    roster[2].state = BR.PlayerState.DBNO
    finishLoad()
    eq(lastOf(BR.Net.TERMINAL_RESULT, 1).code, 'drop_no_mate', 'the teammate went down while it loaded: drop_no_mate')
    nothingSpent(1, 'mate down mid-load')

    -- THE ENGINE WILL NOT BUILD IT.
    reset()
    lobby('squad')
    spawnBroken = true
    runAt(1, 'vehicle_drop', nil, true)
    answer(1, 14.0, 0.0)
    finishLoad()
    eq(lastOf(BR.Net.TERMINAL_RESULT, 1).code, 'unavailable', 'the engine refused the car: unavailable')
    nothingSpent(1, 'engine refused')
    eq(#T.dropsLive(), 0, 'no blip')

    -- THE VEHICLE RULES REFUSING THE MODEL: the card says so.
    reset()
    lobby('squad')
    local was = FX.dropModel
    FX.dropModel = 'lazer'
    fire(BR.Net.TERMINAL_USE, 1, { terminalId = 'tower' })
    local f = listed(1, 'vehicle_drop')
    ok(f and f.available == false and f.reason == 'unavailable', 'a model the rules refuse: not available on the card',
        f and f.reason)
    FX.dropModel = was
    f = listed(1, 'vehicle_drop')
    ok(f and f.available == true, 'the Kuruma: available')

    -- THE MATCH ENDS AS IT LOADS.
    reset()
    local mm = lobby('squad')
    runAt(1, 'vehicle_drop', nil, true)
    answer(1, 14.0, 0.0)
    mm.state = BR.MatchState.ENDED
    finishLoad()
    eq(lastOf(BR.Net.TERMINAL_RESULT, 1).code, 'unavailable', 'the match ended mid-load: unavailable')
    nothingSpent(1, 'match ended')
    eq(#spawns, 0, 'nothing built')

    -- TOO MANY ANSWERS: not a person.
    reset()
    lobby('squad')
    runAt(1, 'vehicle_drop', nil, true)
    for _ = 1, 20 do answer(1, 70.0, 0.0) end
    answer(1, 14.0, 0.0)
    ok(T.dropAsk(1).spot == nil, 'past twenty answers, nothing more is read')
    finishLoad()
    eq(lastOf(BR.Net.TERMINAL_RESULT, 1).code, 'drop_ground', 'drop_ground')
    ok(errored() == nil, 'clean', errored())
end

describe('Vehicle drop: the dev command asks first, then drops it, and charges nothing')
do
    reset()
    lobby('squad')
    local out = devRun(1, 'vehicle_drop')
    ok(out:find('asking first', 1, true) ~= nil, 'it says it is asking first', out)
    ok(lastOf(BR.Net.TERMINAL_DROP_FIND, 1) ~= nil, "the typer's client is asked to look")
    answer(1, 16.0, 4.0)
    flush(gameMs + 1)
    eq(#spawns, 0, 'nothing yet')
    flush(gameMs + (CT.runMinMs or 3000))
    out = lastOf(BR.Net.TERMINAL_DEV, 1) or ''
    ok(out:find('ran vehicle_drop for 1 without a key: ok', 1, true) ~= nil, 'then it drops it', out)
    eq(#spawns, 1, 'one car')
    eq(#market.charges, 0, 'and no Volts')
    eq(lastOf(BR.Net.TERMINAL_DROP, 1).blip, true, 'the blip to the squad')

    reset()
    lobby('squad')
    out = devRun(1, 'vehicle_drop to=mate mate=2')
    ok(lastOf(BR.Net.TERMINAL_DROP_FIND, 2) ~= nil, 'to=mate: the teammate looks')
    answer(2, -16.0, 4.0)
    finishLoad()
    out = lastOf(BR.Net.TERMINAL_DEV, 1) or ''
    ok(out:find(': ok (done)', 1, true) ~= nil, 'and it drops next to them', out)

    reset()
    lobby('squad')
    devRun(1, 'vehicle_drop')
    finishLoad()
    out = lastOf(BR.Net.TERMINAL_DEV, 1) or ''
    ok(out:find('refused (drop_ground)', 1, true) ~= nil, 'no answer: refused, drop_ground', out)
    ok(lastOf(BR.Net.TERMINAL_DROP_FIND, 1).stop == true, 'and the look is stopped')
    ok(errored() == nil, 'clean', errored())
end

describe('Vehicle drop: squad and solo lines')
do
    for _, key in ipairs({ 'vehicle_drop_summary', 'vehicle_drop_what', 'vehicle_drop_duration',
                           'vehicle_drop_affects', 'vehicle_drop_notified', 'vehicle_drop_done',
                           'vehicle_drop_description', 'vehicle_drop_risks', 'drop_target', 'drop_ground',
                           'vehicle_drop_received', 'vehicle_drop_blip' }) do
        ok(TS.pick(COPY, key, false) ~= '', key .. ' has a line')
        ok(not TS.pick(COPY, key, false):lower():find('squad', 1, true),
            ('%s never says squad outside a squad match'):format(key))
    end
    eq(TS.pick(COPY, 'vehicle_drop_opt_to', false), '', 'outside a squad match the choice is not shown')
    eq(TS.pick(COPY, 'vehicle_drop_opt_to_mate', false), '', 'nor its teammate choice')
end

-- =========================================================================
-- PART C -- Airstrike, the server
-- =========================================================================

-- THE DAMAGE DOOR, ON ITS CONTRACT (server/damage.lua's BR.Damage.applyHit:
-- the ledger, the knock and the kill, through the real sampler and combat, is
-- tools/test_roster.lua's): every hit the server deals, recorded.
local hits = {}
BR.Damage = {
    applyHit = function(shooter, victim, amount, meta)
        hits[#hits + 1] = { shooter = shooter, victim = victim, amount = amount, meta = meta }
    end,
}
-- THE ONESYNC VEHICLE POOL, over the same vehicles the drop's model keeps.
function GetAllVehicles()
    local out = {}
    for v in pairs(vehicles) do out[#out + 1] = v end
    table.sort(out)
    return out
end
function GetEntityRoutingBucket(v) return vehicles[v] and vehicles[v].bucket or 0 end
function NetworkGetEntityOwner(v) return vehicles[v] and vehicles[v].owner or -1 end
function NetworkGetNetworkIdFromEntity(v) return v + 9000 end

local EXPLOSION_HASH = BR.Config.EnvironmentalFor(0x2024F4E8) and BR.Config.EnvironmentalFor(0x2024F4E8).hash

--- A seeded stream for the solvers (a fixed sequence, not the clock's).
local function stream(seed)
    local x = seed
    return function()
        x = (1103515245 * x + 12345) % 2147483648
        return x / 2147483648
    end
end

local function hitsOn(victim)
    local out = {}
    for _, h in ipairs(hits) do if h.victim == victim then out[#out + 1] = h end end
    return out
end

--- A vehicle in the pool, as a match's car stands.
local function car(x, y, owner, bucket)
    vehSeq = vehSeq + 1
    vehicles[vehSeq] = { model = 'sultan', x = x, y = y, z = 30.0, h = 0.0, bucket = bucket or 101,
                         owner = owner, engine = 1000.0 }
    return vehSeq
end

describe('Airstrike: registered, built, 200 Volts, run at a spot, and its page holds to its numbers')
do
    local row = T.row('airstrike')
    ok(row ~= nil and row.implemented == true and T.FUNCTIONS.airstrike ~= nil
        and T.FUNCTIONS.airstrike.refuse and T.FUNCTIONS.airstrike.run, 'listed, built, refuse and run')
    eq(row and row.category, 'disruption', 'under Disruption')
    eq(T.costOf(row), 200, '200 Volts (proposed)')
    ok(row and row.spot == true and row.fuzz == true and row.options == nil,
        "round 4's map pick, with the rough circles, and no options")
    ok(row and row.squadWide == nil and row.bounty == nil, 'not squad-wide, no bounty')
    eq(FX.strikeWarnMs, 10000, 'the "~10 s warning"')
    eq(FX.strikeRockets, 10, '"about 10" rockets')
    eq(FX.strikeRadiusM, 40.0, '"within ~40 m"')
    ok(FX.strikeSpreadMs >= 2000 and FX.strikeSpreadMs <= 6000, '"over a few seconds"', FX.strikeSpreadMs)
    for _, k in ipairs({ 'airstrike_what', 'airstrike_what_solo' }) do
        local w = COPY[k]
        ok(w:find(('%d seconds later, %d rockets'):format(FX.strikeWarnMs / 1000, FX.strikeRockets), 1, true)
            and w:find(('within %d meters'):format(FX.strikeRadiusM), 1, true)
            and w:find(('about %d seconds'):format(FX.strikeSpreadMs / 1000), 1, true)
            and w:find("They aren't guided.", 1, true), k .. ' says the numbers, and that they are not guided')
    end
    ok(COPY.airstrike_description:find(('in %d seconds'):format(FX.strikeWarnMs / 1000), 1, true)
        and COPY.airstrike_risks:find(('%d seconds'):format(FX.strikeWarnMs / 1000), 1, true)
        and COPY.airstrike_risks_solo:find(('%d seconds'):format(FX.strikeWarnMs / 1000), 1, true),
        'the lobby\'s line and the risks say 10 seconds too')
    ok(COPY.airstrike_what:find('your squad and you included', 1, true)
        and COPY.airstrike_affects:find('your squad included', 1, true),
        'friendly fire is on the page: the squad is hit too')
    ok(COPY.ghost_what:find('Airstrike', 1, true) and COPY.ghost_summary:find('Airstrike', 1, true)
        and COPY.ghost_what_solo:find('Airstrike', 1, true) and COPY.ghost_summary_solo:find('Airstrike', 1, true),
        "Ghost's page says it hides from an Airstrike's circles too")
end

describe('Airstrike: the plan -- unguided, evenly over the circle, one after another')
do
    local rand = stream(7)
    local plan = TS.strikePlan(rand, 1000.0, 2000.0, FX, 5000)
    eq(#plan, 10, 'ten rockets')
    local inside, ordered, timed = true, true, true
    for i, rk in ipairs(plan) do
        local d = math.sqrt((rk.x - 1000.0) ^ 2 + (rk.y - 2000.0) ^ 2)
        if d > 40.0 then inside = false end
        if i > 1 and rk.at < plan[i - 1].at then ordered = false end
        local share = FX.strikeSpreadMs / 10
        if rk.at < 5000 + (i - 1) * share or rk.at > 5000 + i * share then timed = false end
    end
    ok(inside, 'every one within 40 m')
    ok(ordered and timed, 'each in its own tenth of the 4 s, in order')
    -- EVENLY OVER THE AREA: a quarter inside half the radius, not half.
    local r2 = stream(11)
    local inner, n = 0, 0
    for _ = 1, 2000 do
        for _, rk in ipairs(TS.strikePlan(r2, 0.0, 0.0, FX, 0)) do
            n = n + 1
            if rk.x * rk.x + rk.y * rk.y <= 20.0 * 20.0 then inner = inner + 1 end
        end
    end
    near(inner / n, 0.25, 0.02, 'a quarter land inside half the radius: even over the area')
    -- THE FALLOFF.
    eq(TS.blastDamage(0.0, 150, 4, 14), 150.0, 'on it: full')
    eq(TS.blastDamage(4.0, 150, 4, 14), 150.0, 'at 4 m: full')
    near(TS.blastDamage(9.0, 150, 4, 14), 75.0, 1e-9, 'at 9 m: half')
    eq(TS.blastDamage(14.0, 150, 4, 14), 0.0, 'at 14 m: nothing')
    eq(TS.blastDamage(20.0, 150, 4, 14), 0.0, 'past it: nothing')
    eq(TS.blastDamage(30.0, 150, 4, 14), 0.0, 'far past it: nothing')
    eq(TS.blastDamage(0 / 0, 150, 4, 14), 0.0, 'not a number: nothing')
    -- THE ROUGH CIRCLE: never on them, always around them.
    local r3 = stream(13)
    local within, mid = true, 0
    local split = math.sqrt((25 * 25 + 85 * 85) / 2)
    for _ = 1, 4000 do
        local dx, dy = TS.fuzzOffset(r3, 25, 85)
        local d = math.sqrt(dx * dx + dy * dy)
        if d < 25 - 1e-9 or d > 85 + 1e-9 then within = false end
        if d < split then mid = mid + 1 end
    end
    ok(within, 'the offset is always 25..85 m: the player is inside the 100 m circle and never at its center')
    near(mid / 4000, 0.5, 0.03, 'spread evenly over the ring\'s area')
end

--- The lobby, with player 1 at the terminal and holding the key.
local function strikeLobby()
    local m = lobby('squad')
    return m
end

local function spotNear(m, dx, dy) return { x = C0.x + dx, y = C0.y + dy } end

describe('Airstrike: run at a spot -- the warning to everyone, the plan, the 200 Volts')
do
    reset()
    local m = strikeLobby()
    hits = {}
    local at = spotNear(m, 300.0, 0.0)
    local r = runAt(1, 'airstrike', nil, true, at)
    eq(r and r.code, 'running', 'accepted')
    finishLoad()
    r = lastOf(BR.Net.TERMINAL_RESULT, 1)
    eq(r and r.code, 'done', 'done at the end of the load')
    eq(market.charges[1] and market.charges[1].cost, 200, '200 Volts')
    local s = T.strikesLive(m)[1]
    ok(s ~= nil and s.x == at.x and s.y == at.y and s.by == 1, 'the strike stands at the spot, by the runner')
    eq(s.startsAt - s.warnAt, FX.strikeWarnMs, 'the first rocket 10 s after the run ends')
    for src = 1, 5 do
        local p = lastOf(BR.Net.TERMINAL_STRIKE, src)
        ok(p and p.x == at.x and p.r == 40.0 and #p.rockets == 10 and p.startsAt == s.startsAt
            and p.endsAt == s.rockets[10].at, ('player %d is warned: the circle and the rockets'):format(src))
    end
    local told = false
    for _, n in ipairs(notices) do
        if (textOf(n) or ''):find(COPY.airstrike_description, 1, true) then told = true end
    end
    ok(told, 'the lobby is told: "has redeemed their special power: Airstrike..."')
    eq(#hits, 0, 'nothing is hit during the warning')
    flush(s.startsAt - 1)
    eq(#hits, 0, 'nor a millisecond before the first rocket')
    ok(errored() == nil, 'clean', errored())
end

describe('Airstrike: the server works out the damage -- falloff, friendly fire, the kill the runner\'s')
do
    reset()
    local m = strikeLobby()
    hits = {}
    -- Everybody near the spot: the runner, a teammate, two opponents (one
    -- downed), one in the air, one out, one far off.
    local at = spotNear(m, 300.0, 0.0)
    roster[1].pos = { x = at.x - 30.0, y = at.y, z = 30.0 }
    roster[2].pos = { x = at.x + 10.0, y = at.y + 20.0, z = 30.0 }
    roster[3].pos = { x = at.x, y = at.y - 20.0, z = 30.0 }
    roster[4].pos = { x = at.x + 2.0, y = at.y - 20.0, z = 30.0 }
    player(6, m, 'C', { x = at.x, y = at.y + 30.0 }, BR.PlayerState.FREEFALL)
    player(7, m, 'C', { x = at.x + 1.0, y = at.y + 30.0 }, BR.PlayerState.OUT)
    player(8, m, 'C', { x = at.x + 300.0, y = at.y }, BR.PlayerState.ALIVE)
    roster[1].pos = SITE
    runAt(1, 'airstrike', nil, true, at)
    finishLoad()
    roster[1].pos = { x = at.x - 30.0, y = at.y, z = 30.0 }
    local s = T.strikesLive(m)[1]
    -- PLACE THE ROCKETS (the plan is random; the damage is what is tested):
    -- one on the teammate's 10 m, one on opponent 3, one on the runner, one on
    -- the man in the air, one on the man who is out, the rest well away.
    local spots = {
        { x = at.x, y = at.y + 20.0 },          -- 10 m from player 2
        { x = at.x, y = at.y - 20.0 },          -- on player 3; player 4 at 2 m
        { x = at.x - 30.0, y = at.y },          -- on the runner
        { x = at.x, y = at.y + 30.0 },          -- on player 6 (in the air) and 7 (out, 1 m)
    }
    for i, rk in ipairs(s.rockets) do
        local sp = spots[i] or { x = at.x + 35.0, y = at.y - 39.0 + i }
        rk.x, rk.y = sp.x, sp.y
    end
    flush(s.rockets[1].at)
    local h2 = hitsOn(2)
    ok(#h2 == 1 and math.abs(h2[1].amount - 75.0) < 1e-9, 'the teammate 10 m off, half way out (5 to 15 m): half of 150', h2[1] and h2[1].amount)
    eq(h2[1] and h2[1].shooter, nil, 'FRIENDLY FIRE: the squad is hit too -- and it is nobody\'s hit')
    ok(h2[1] and h2[1].meta.weapon == EXPLOSION_HASH and h2[1].meta.explosive == true,
        "billed as the world's blast: it kills outright, and the feed says explosion")
    flush(s.rockets[2].at)
    local h3, h4 = hitsOn(3), hitsOn(4)
    ok(#h3 == 1 and h3[1].amount == 150.0 and h3[1].shooter == 1, 'an opponent under it: 150, the runner\'s hit (credit, the kill)')
    ok(#h4 == 1 and h4[1].amount == 150.0 and h4[1].shooter == 1, 'a downed opponent 2 m off: hit too (their bleed clock)')
    flush(s.rockets[3].at)
    local h1 = hitsOn(1)
    ok(#h1 == 1 and h1[1].amount == 150.0 and h1[1].shooter == nil, 'the runner under their own rocket: hit, and nobody\'s')
    flush(s.rockets[4].at)
    eq(#hitsOn(6), 0, 'a player in the air: untouched')
    eq(#hitsOn(7), 0, 'a player who is out: untouched')
    flush()
    eq(#hitsOn(8), 0, 'a player 300 m off: untouched')
    eq(#hitsOn(5), 0, 'the solo player 500 m off: untouched')
    eq(#T.strikesLive(m), 0, 'after the last rocket the strike is over')

    -- THE RUNNER LEFT THE SERVER BEFORE IT LANDED: nobody's kill.
    reset()
    m = strikeLobby()
    hits = {}
    at = spotNear(m, 300.0, 0.0)
    runAt(1, 'airstrike', nil, true, at)
    finishLoad()
    s = T.strikesLive(m)[1]
    for _, rk in ipairs(s.rockets) do rk.x, rk.y = roster[3].pos.x, roster[3].pos.y end
    roster[1] = nil
    flush()
    ok(#hitsOn(3) == 10 and hitsOn(3)[1].shooter == nil, 'the runner gone: every hit nobody\'s', #hitsOn(3))
    ok(errored() == nil, 'clean', errored())
end

describe('Airstrike: vehicles -- the owner is told; wrecked under a rocket, damaged by the falloff')
do
    reset()
    local m = strikeLobby()
    hits = {}
    local at = spotNear(m, 300.0, 0.0)
    runAt(1, 'airstrike', nil, true, at)
    finishLoad()
    local s = T.strikesLive(m)[1]
    for _, rk in ipairs(s.rockets) do rk.x, rk.y = at.x, at.y end
    local under = car(at.x + 1.0, at.y, 3, m.bucket)
    local ten = car(at.x + 10.0, at.y, 4, m.bucket)
    local far = car(at.x + 20.0, at.y, 3, m.bucket)
    local other = car(at.x, at.y, 3, m.bucket + 50)
    local nobody = car(at.x + 2.0, at.y, -1, m.bucket)
    sent = {}
    flush(s.rockets[1].at)
    local v = eventsOf(BR.Net.TERMINAL_STRIKE_VEH)
    local byNet = {}
    for _, e in ipairs(v) do byNet[e.payload.netId] = e end
    ok(byNet[under + 9000] and byNet[under + 9000].src == 3 and byNet[under + 9000].payload.wreck == true,
        'a car under it: its owner told to wreck it')
    ok(byNet[ten + 9000] and byNet[ten + 9000].src == 4 and byNet[ten + 9000].payload.wreck == nil
        and math.abs(byNet[ten + 9000].payload.frac - 0.5) < 1e-9, 'a car 10 m off: its owner told, half the damage')
    eq(byNet[far + 9000], nil, 'a car 20 m off: nothing')
    eq(byNet[other + 9000], nil, "a car in another match's bucket: nothing")
    eq(byNet[nobody + 9000], nil, 'a car nobody owns (out of everyone\'s scope): nothing to send')
    eq(#v, 2, 'two cars, one message each')
    ok(errored() == nil, 'clean', errored())
end

describe('Airstrike: the persistent notice -- inside its reach, the squad included, never the runner')
do
    reset()
    local m = strikeLobby()
    local at = spotNear(m, 300.0, 0.0)
    runAt(1, 'airstrike', nil, true, at)
    finishLoad()
    local s = T.strikesLive(m)[1]
    roster[1].pos = { x = at.x, y = at.y, z = 30.0 }
    roster[2].pos = { x = at.x + 50.0, y = at.y, z = 30.0 }
    roster[3].pos = { x = at.x, y = at.y - 20.0, z = 30.0 }
    roster[4].pos = { x = at.x + 60.0, y = at.y, z = 30.0 }
    local now = gameMs
    local rows = T.impactsOf(m, now)
    local function has(src)
        for _, r in ipairs(rows[src] or {}) do
            if r.key == 'impact_airstrike' then return r end
        end
        return nil
    end
    eq(has(1), nil, 'the runner, under it: no row (their own run)')
    ok(has(2) and has(2).untilAt == s.endsAt, 'a teammate 50 m off (inside 40 + 14): the row, until the last rocket')
    ok(has(3) ~= nil, 'an opponent inside it: the row')
    eq(has(4), nil, '60 m off: no row')
    eq(has(5), nil, 'the solo player far off: no row')
    rows = T.impactsOf(m, s.endsAt)
    eq(has(2), nil, 'at the last rocket: gone')
    ok(COPY.impact_airstrike:find('^Airstrike: ') ~= nil, 'its line names the tool first, as the others do')
end

describe('Airstrike: refused, spending nothing -- off the map, no spot; the end of the match stops the rockets')
do
    reset()
    lobby('squad')
    local r = runAt(1, 'airstrike', nil, false, { x = 6000.0, y = 6000.0 })
    eq(r and r.code, 'strike_spot', 'a spot off the play area: strike_spot')
    eq(r and r.toast, COPY.strike_spot, 'in its own line')
    nothingSpent(1, 'strike_spot')
    eq(#market.charges, 0, 'refused before the market is asked')
    gameMs = gameMs + 1000
    r = runAt(1, 'airstrike')
    eq(r and r.code, 'bad_option', 'no spot: bad_option')
    nothingSpent(1, 'no spot')

    -- THE MATCH ENDS DURING THE WARNING: nothing lands.
    reset()
    local m = strikeLobby()
    hits = {}
    local at = spotNear(m, 300.0, 0.0)
    runAt(1, 'airstrike', nil, true, at)
    finishLoad()
    local s = T.strikesLive(m)[1]
    for _, rk in ipairs(s.rockets) do rk.x, rk.y = roster[3].pos.x, roster[3].pos.y end
    m.state = BR.MatchState.ENDED
    flush()
    eq(#hits, 0, 'the match ended: no rocket lands')
    eq(#T.strikesLive(m), 0, 'and the strike is gone')

    -- SEASON 1.
    reset()
    m = strikeLobby()
    hits = {}
    runAt(1, 'airstrike', nil, true, spotNear(m, 300.0, 0.0))
    finishLoad()
    s = T.strikesLive(m)[1]
    for _, rk in ipairs(s.rockets) do rk.x, rk.y = roster[3].pos.x, roster[3].pos.y end
    season(1)
    flush()
    season(2)
    eq(#hits, 0, 'off Season 2: no rocket lands')
    ok(errored() == nil, 'clean', errored())
end

describe('Airstrike: br:ready shows a strike again; the dev command needs the spot and charges nothing')
do
    reset()
    local m = strikeLobby()
    runAt(1, 'airstrike', nil, true, spotNear(m, 300.0, 0.0))
    finishLoad()
    sent = {}
    fire(BR.Net.READY, 4)
    local p = lastOf(BR.Net.TERMINAL_STRIKE, 4)
    ok(p and #p.rockets == 10, 'a client that restarts during it is shown it again')
    flush()
    sent = {}
    fire(BR.Net.READY, 4)
    eq(lastOf(BR.Net.TERMINAL_STRIKE, 4), nil, 'and not once it is over')

    reset()
    m = strikeLobby()
    hits = {}
    local out = devRun(1, ('airstrike x=%.1f y=%.1f'):format(C0.x + 300.0, C0.y))
    ok(out:find('ran airstrike for 1 without a key: ok', 1, true) ~= nil, 'brterminal run airstrike x= y=: it runs', out)
    eq(#market.charges, 0, 'no Volts')
    ok(lastOf(BR.Net.TERMINAL_STRIKE, 3) ~= nil, 'and everyone is warned')
    out = devRun(1, 'airstrike')
    ok(out:find('needs the spot', 1, true) ~= nil, 'without x= y= it says it needs the spot', out)
    out = devRun(1, 'airstrike x=6000 y=6000')
    ok(out:find('refused (strike_spot)', 1, true) ~= nil, 'off the map: strike_spot', out)
    flush()
    ok(errored() == nil, 'clean', errored())
end

describe('Airstrike: the rough circles while the spot is picked')
do
    reset()
    local m = strikeLobby()
    fire(BR.Net.TERMINAL_USE, 1, { terminalId = 'tower' })
    gameMs = gameMs + 1000
    local function pick(src, on, id, terminalId)
        fire(BR.Net.TERMINAL_PICK, src, { terminalId = terminalId or 'tower', functionId = id or 'airstrike', on = on })
    end
    sent = {}
    pick(1, true)
    local f = lastOf(BR.Net.TERMINAL_FUZZ, 1)
    ok(f and #f.list == 3, 'every opponent: the other squad (one of them downed) and the solo player', f and #f.list)
    local by = {}
    for _, c in ipairs(f and f.list or {}) do by[c.s] = c end
    eq(by[2], nil, 'never a teammate')
    for _, s in ipairs({ 3, 4, 5 }) do
        local c, p = by[s], roster[s].pos
        local d = c and math.sqrt((c.x - p.x) ^ 2 + (c.y - p.y) ^ 2)
        ok(c and c.r == FX.fuzzRadiusM and d >= FX.fuzzMinM - 1e-9 and d <= FX.fuzzMaxM + 1e-9,
            ('player %d: a 100 m circle %.0f m off them -- around them, never on them'):format(s, d or -1))
    end
    ok(T.fuzzing(1), 'the pick is showing them')
    -- THEY MOVE: the circle moves with them, by the same offset.
    local off3 = { x = by[3].x - roster[3].pos.x, y = by[3].y - roster[3].pos.y }
    roster[3].pos = { x = roster[3].pos.x + 50.0, y = roster[3].pos.y, z = 30.0 }
    gameMs = gameMs + FX.fuzzPingMs
    jobs['terminal.fuzz']()
    f = lastOf(BR.Net.TERMINAL_FUZZ, 1)
    local c3 = nil
    for _, c in ipairs(f.list) do if c.s == 3 then c3 = c end end
    ok(c3 and math.abs(c3.x - roster[3].pos.x - off3.x) < 1e-9 and math.abs(c3.y - roster[3].pos.y - off3.y) < 1e-9,
        'moved with them, the same offset: pushing again tells nothing new')
    -- THE PICK ENDS.
    pick(1, false)
    f = lastOf(BR.Net.TERMINAL_FUZZ, 1)
    ok(f and #f.list == 0 and not T.fuzzing(1), 'the pick ends: an empty list, and no more')
    -- PICKED AGAIN: the same offsets (fixed for the match).
    gameMs = gameMs + 1000
    pick(1, true)
    f = lastOf(BR.Net.TERMINAL_FUZZ, 1)
    for _, c in ipairs(f.list) do if c.s == 3 then c3 = c end end
    ok(c3 and math.abs(c3.x - roster[3].pos.x - off3.x) < 1e-9, 'picked again: the same circle, not a new guess')
    -- GHOST: a squad under it is on nobody's map.
    m.terminalFx.ghosts = { ['squad:B'] = { untilAt = gameMs + 60000 } }
    jobs['terminal.fuzz']()
    f = lastOf(BR.Net.TERMINAL_FUZZ, 1)
    ok(#f.list == 1 and f.list[1].s == 5, 'squad B under Ghost: left out')
    m.terminalFx.ghosts = nil
    -- SCAN RUNNING FOR THE RUNNER'S SQUAD: the exact dots are already there.
    m.terminalFx.scans['squad:A'] = { by = 1, at = gameMs }
    jobs['terminal.fuzz']()
    f = lastOf(BR.Net.TERMINAL_FUZZ, 1)
    ok(f and #f.list == 0, 'their squad has Scan running: no rough circles')
    m.terminalFx.scans['squad:A'] = nil
    -- THE SESSION ENDS (walked off, closed): the next push ends the pick.
    T.close(1, 'test')
    jobs['terminal.fuzz']()
    f = lastOf(BR.Net.TERMINAL_FUZZ, 1)
    ok(f and #f.list == 0 and not T.fuzzing(1), 'the computer closed: the circles go')
    -- TIME'S UP.
    fire(BR.Net.TERMINAL_USE, 1, { terminalId = 'tower' })
    gameMs = gameMs + 1000
    pick(1, true)
    ok(T.fuzzing(1), 'picking')
    gameMs = gameMs + FX.fuzzMaxMs
    jobs['terminal.fuzz']()
    ok(not T.fuzzing(1), 'after fx.fuzzMaxMs it stops on its own')

    -- WHO MAY SEE THEM: nobody else.
    sent = {}
    gameMs = gameMs + 1000
    pick(1, true, 'emp')
    eq(lastOf(BR.Net.TERMINAL_FUZZ, 1), nil, 'a row without `fuzz` (EMP, which could run): nothing')
    gameMs = gameMs + 1000
    pick(1, true, 'airstrike', 'shack')
    eq(lastOf(BR.Net.TERMINAL_FUZZ, 1), nil, 'another terminal than the session\'s: nothing')
    gameMs = gameMs + 1000
    pick(2, true)
    eq(lastOf(BR.Net.TERMINAL_FUZZ, 2), nil, 'no session at all: nothing')
    keys[1] = false
    gameMs = gameMs + 1000
    pick(1, true)
    eq(lastOf(BR.Net.TERMINAL_FUZZ, 1), nil, 'no key (it could not run): nothing')
    keys[1] = true
    market.wallet[1] = 150
    gameMs = gameMs + 1000
    pick(1, true)
    eq(lastOf(BR.Net.TERMINAL_FUZZ, 1), nil, 'short of the 200 Volts: nothing')
    market.wallet[1] = 1000
    gameMs = gameMs + 1000
    pick(1, true)
    ok(lastOf(BR.Net.TERMINAL_FUZZ, 1) ~= nil, 'and with them: the circles')
    sent = {}
    pick(1, false)
    pick(1, true)
    eq(#eventsOf(BR.Net.TERMINAL_FUZZ, 1), 1, 'a second start inside the interval is dropped (only the end is sent)')
    gameMs = gameMs + 1000
    pick(1, true)
    ok(T.fuzzing(1), 'picking again')
    season(1)
    gameMs = gameMs + 1000
    jobs['terminal.fuzz']()
    season(2)
    ok(not T.fuzzing(1), 'off Season 2: over')
    ok(errored() == nil, 'clean', errored())
end

describe('Airstrike: squad and solo lines; no client draws an explosion or fires a projectile')
do
    for _, key in ipairs({ 'airstrike_summary', 'airstrike_what', 'airstrike_duration', 'airstrike_affects',
                           'airstrike_notified', 'airstrike_done', 'airstrike_description', 'airstrike_risks',
                           'impact_airstrike', 'strike_spot', 'airstrike_blip', 'airstrike_fuzz_blip' }) do
        ok(TS.pick(COPY, key, false) ~= '', key .. ' has a line')
        ok(not TS.pick(COPY, key, false):lower():find('squad', 1, true),
            ('%s never says squad outside a squad match'):format(key))
    end
    local src = (readFile(ROOT .. 'br_core/client/terminalfx/airstrike.lua') or ''):gsub('%-%-[^\n]*', '')
    for _, native in ipairs({ 'AddExplosion', 'AddOwnedExplosion', 'ShootSingleBulletBetweenCoords',
                              'ShootSingleBulletBetweenCoordsIgnoreEntity', 'ApplyDamageToPed',
                              'SetEntityHealth' }) do
        ok(not src:find(native .. '%s*%('), ('the client half never calls %s'):format(native))
    end
    local server = (readFile(ROOT .. 'br_core/server/terminalfx/airstrike.lua') or ''):gsub('%-%-[^\n]*', '')
    ok(server:find('BR.Damage.applyHit(h.shooter, h.src, h.dmg', 1, true) ~= nil,
        'every hit through the health ledger\'s own door (BR.Damage.applyHit)')
end

-- =========================================================================
-- PART B -- Vehicle drop, the client
-- =========================================================================

local serverBR = BR
BR = nil

local clientMs = 500000
local C = { handlers = {}, loops = {}, threads = {}, toServer = {}, blips = {}, ents = {}, calls = {} }
local nextBlip, nextEnt = 0, 0

local function call(name) C.calls[name] = (C.calls[name] or 0) + 1 end
local function callsOf(name) return C.calls[name] or 0 end
local function anyNative()
    local n = 0
    for _, v in pairs(C.calls) do n = n + v end
    return n
end

function GetGameTimer() return clientMs end
function IsDuplicityVersion() return false end
function RegisterNetEvent() end
function AddEventHandler(name, fn)
    C.handlers[name] = C.handlers[name] or {}
    table.insert(C.handlers[name], fn)
end
function TriggerServerEvent(name, d) C.toServer[#C.toServer + 1] = { name = name, d = d } end
function TriggerEvent() end
function GetHashKey(s) return joaat(s) end

-- THREADS AS COROUTINES, woken by the clock.
Citizen = {
    CreateThread = function(fn)
        C.threads[#C.threads + 1] = { co = coroutine.create(fn), at = clientMs }
    end,
    Wait = function(ms) coroutine.yield(ms or 0) end,
}
local function runThreads()
    for _ = 1, 400 do
        local woke = false
        for i = #C.threads, 1, -1 do
            local t = C.threads[i]
            if t.at <= clientMs then
                woke = true
                local okRun, ms = coroutine.resume(t.co)
                if not okRun then realPrint('thread error: ' .. tostring(ms)) end
                if coroutine.status(t.co) == 'dead' then
                    table.remove(C.threads, i)
                else
                    t.at = clientMs + (ms or 0)
                end
            end
        end
        if not woke then return end
    end
end
--- Move the client's clock on, `step` at a time, running the threads and the
--- FRAME callbacks (one frame a step) as it goes.
local function advance(ms, step)
    step = step or 50
    local target = clientMs + ms
    while clientMs < target do
        clientMs = math.min(target, clientMs + step)
        runThreads()
        for _, l in pairs(C.loops) do
            if l.band == 'frame' and not l.dead then l.fn(step) end
        end
    end
end

-- BLIPS.
function AddBlipForCoord(x, y, z)
    call('AddBlipForCoord')
    nextBlip = nextBlip + 1
    C.blips[nextBlip] = { x = x, y = y, kind = 'coord' }
    return nextBlip
end
function AddBlipForRadius(x, y, z, r)
    call('AddBlipForRadius')
    nextBlip = nextBlip + 1
    C.blips[nextBlip] = { x = x, y = y, r = r, kind = 'radius' }
    return nextBlip
end
function DoesBlipExist(b) return C.blips[b] ~= nil end
function RemoveBlip(b) call('RemoveBlip'); C.blips[b] = nil end
function SetBlipSprite(b, v) C.blips[b].sprite = v end
function SetBlipColour(b, v) C.blips[b].colour = v end
function SetBlipScale(b, v) C.blips[b].scale = v end
function SetBlipDisplay(b, v) C.blips[b].display = v end
function SetBlipAsShortRange() end
function SetBlipAlpha(b, v) C.blips[b].alpha = v end
function SetBlipHighDetail() end
function SetBlipCoords(b, x, y) call('SetBlipCoords'); C.blips[b].x, C.blips[b].y = x, y end

-- THE WORLD: the ground, the water, roofs, roads and anybody standing about.
local W = {}
local function resetWorld()
    W.groundZ = 20.0            -- flat ground everywhere at this height...
    W.slopes = {}               -- ...but for these: { x, y, r, nz }
    W.water = {}                -- { x, y, r, z }
    W.roofs = {}                -- { x, y, r } -- sky blocked over it
    W.raised = {}               -- { x, y, r, z } -- a surface at another height
    W.roads = {}                -- { x, y, z, h }, nearest first
    W.busy = {}                 -- { x, y, r } -- somebody or something on it
    W.me = { x = 0.0, y = 0.0, z = 20.0 }
end
resetWorld()
local function inDisc(list, x, y)
    for _, d in ipairs(list) do
        local dx, dy = x - d.x, y - d.y
        if dx * dx + dy * dy <= d.r * d.r then return d end
    end
    return nil
end
local function surfaceZ(x, y)
    local raised = inDisc(W.raised, x, y)
    return raised and raised.z or W.groundZ
end
function GetGroundZAndNormalFor_3dCoord(x, y)
    call('GetGroundZAndNormalFor_3dCoord')
    local s = inDisc(W.slopes, x, y)
    return true, surfaceZ(x, y), { x = 0.0, y = 0.0, z = s and s.nz or 1.0 }
end
function GetGroundZFor_3dCoord(x, y)
    call('GetGroundZFor_3dCoord')
    return true, surfaceZ(x, y)
end
function GetWaterHeight(x, y)
    call('GetWaterHeight')
    local w = inDisc(W.water, x, y)
    if w then return true, w.z end
    return false, 0.0
end
local rays, raySeq = {}, 0
function StartExpensiveSynchronousShapeTestLosProbe(x1, y1, z1, x2, y2)
    call('StartExpensiveSynchronousShapeTestLosProbe')
    raySeq = raySeq + 1
    rays[raySeq] = inDisc(W.roofs, x1, y1) ~= nil
    return raySeq
end
function GetShapeTestResult(h) return 2, rays[h] and 1 or 0, nil, nil, 0 end
function IsPositionOccupied(x, y)
    call('IsPositionOccupied')
    return inDisc(W.busy, x, y) ~= nil
end
function GetNthClosestVehicleNodeWithHeading(x, y, z, n)
    call('GetNthClosestVehicleNodeWithHeading')
    local r = W.roads[n]
    if not r then return false, nil, 0.0 end
    return true, { x = r.x, y = r.y, z = r.z or W.groundZ }, r.h or 0.0
end
function PlayerPedId() return 1 end

-- ENTITIES: the copy, its canopy, and the real car (network id 9000+).
local realCars = {}
local function ent(kind, model, x, y, z)
    nextEnt = nextEnt + 1
    C.ents[nextEnt] = { kind = kind, model = model, x = x, y = y, z = z, alive = true, born = clientMs }
    return nextEnt
end
function CreateVehicle(model, x, y, z, h, net)
    call('CreateVehicle')
    local e = ent('veh', model, x, y, z)
    C.ents[e].h, C.ents[e].net = h, net
    return e
end
function CreateObjectNoOffset(model, x, y, z, net)
    call('CreateObjectNoOffset')
    local e = ent('obj', model, x, y, z)
    C.ents[e].net = net
    return e
end
function GetEntityCoords(e)
    if e == 1 then return { x = W.me.x, y = W.me.y, z = W.me.z } end
    local r = C.ents[e]
    return r and { x = r.x, y = r.y, z = r.z } or nil
end
function DoesEntityExist(e) return C.ents[e] ~= nil and C.ents[e].alive end
function DeleteEntity(e) call('DeleteEntity'); if C.ents[e] then C.ents[e].alive = false end end
function SetEntityCollision(e, a) if C.ents[e] then C.ents[e].collision = a end end
function FreezeEntityPosition(e, a) if C.ents[e] then C.ents[e].frozen = a end end
function SetEntityInvincible() end
function SetVehicleDoorsLocked(e, s) if C.ents[e] then C.ents[e].locked = s end end
function SetEntityCoords(e, x, y, z)
    call('SetEntityCoords')
    if C.ents[e] then C.ents[e].x, C.ents[e].y, C.ents[e].z = x, y, z end
end
function SetEntityHeading(e, h) if C.ents[e] then C.ents[e].h = h end end
function SetModelAsNoLongerNeeded() end
function IsModelValid() return true end
function RequestModel() end
function HasModelLoaded() return true end
function RequestAnimDict() end
function HasAnimDictLoaded() return true end
function PlayEntityAnim(e, anim) if C.ents[e] then C.ents[e].anim = anim end end
function NetworkDoesNetworkIdExist(id) return realCars[id] ~= nil end
function NetToVeh(id) return realCars[id] or 0 end
local hidden = {}
function SetEntityLocallyInvisible(e) call('SetEntityLocallyInvisible'); hidden[e] = (hidden[e] or 0) + 1 end

loadAll({
    'br_lib/shared/enums.lua',
    'br_lib/shared/protocol.lua',
    'br_lib/shared/geo.lua',
    'br_lib/config/weapons.lua',
    'br_lib/config/loot.lua',
    'br_lib/config/airdrop.lua',
    'br_lib/config/terminals.lua',
    'br_lib/shared/terminal_solve.lua',
    'br_lib/shared/airdrop_solve.lua',
})
local clientSeason = 2
BR.Season = { has = function(name) return name == 'terminals' and clientSeason == 2 end }
BR.NativeTruthy = function(v) return v == true or v == 1 end
BR.Native = {
    blipName = function(b, name) if C.blips[b] then C.blips[b].name = name end end,
    propScale = function(e, k) if C.ents[e] then C.ents[e].scale = k end end,
}
BR.Clock = { now = function() return clientMs end }
BR.State = { me = { state = BR.PlayerState.ALIVE } }
local loopSeq = 0
BR.Loop = {
    FRAME = 'frame', TICK = 'tick', SLOW = 'slow',
    register = function(band, name, fn)
        for _, l in pairs(C.loops) do
            if l.name == name and not l.dead then error('duplicate loop ' .. name) end
        end
        loopSeq = loopSeq + 1
        local h = { band = band, name = name, fn = fn }
        C.loops[loopSeq] = h
        return h
    end,
    unregister = function(h) if h then h.dead = true end end,
}
loadAll({ 'br_core/client/terminalfx.lua', 'br_core/client/terminalfx/vehicle_drop.lua' })
local F = BR.TerminalFx
local CC = BR.Config.Terminals

local function cfire(name, d)
    for _, fn in ipairs(C.handlers[name] or {}) do fn(d) end
end
local function slow()
    for _, l in pairs(C.loops) do
        if l.band == 'slow' and not l.dead then l.fn(1000) end
    end
end
local function frameLoops()
    local n = 0
    for _, l in pairs(C.loops) do
        if l.band == 'frame' and not l.dead then n = n + 1 end
    end
    return n
end
local function lastToServer(name)
    for i = #C.toServer, 1, -1 do
        if C.toServer[i].name == name then return C.toServer[i].d end
    end
    return nil
end

describe('client: the look -- the nearest road node that will take a car, or flat open ground')
do
    resetWorld()
    W.roads = { { x = 3.0, y = 0.0, h = 10.0 }, { x = 15.0, y = 2.0, h = 90.0 }, { x = 25.0, y = 0.0, h = 180.0 } }
    local s = F.dropSpot(0.0, 0.0, 20.0, 40.0, 6.0)
    ok(s and s.x == 15.0 and s.y == 2.0 and s.h == 90.0 and s.z == 20.0,
        'the nearest node at least 6 m away, with its heading', s and s.x)
    W.water = { { x = 15.0, y = 2.0, r = 3.0, z = 21.0 } }
    s = F.dropSpot(0.0, 0.0, 20.0, 40.0, 6.0)
    ok(s and s.x == 25.0, 'one in the water is passed over', s and s.x)
    W.water = {}
    W.roofs = { { x = 15.0, y = 2.0, r = 3.0 } }
    s = F.dropSpot(0.0, 0.0, 20.0, 40.0, 6.0)
    ok(s and s.x == 25.0, 'one under a roof (or a bridge, or a tree) is passed over', s and s.x)
    W.roofs = {}
    W.busy = { { x = 15.0, y = 2.0, r = 2.0 } }
    s = F.dropSpot(0.0, 0.0, 20.0, 40.0, 6.0)
    ok(s and s.x == 25.0, 'one with somebody or something on it is passed over', s and s.x)
    W.busy = {}
    W.slopes = { { x = 15.0, y = 2.0, r = 3.0, nz = 0.85 } }
    s = F.dropSpot(0.0, 0.0, 20.0, 40.0, 6.0)
    ok(s and s.x == 25.0, 'one on a steep slope is passed over', s and s.x)
    W.slopes = {}
    W.roads[2].z = 32.0
    W.raised = { { x = 15.0, y = 2.0, r = 3.0, z = 32.0 } }
    s = F.dropSpot(0.0, 0.0, 20.0, 40.0, 6.0)
    ok(s and s.x == 25.0, 'an overpass twelve meters over their head is passed over', s and s.x)
    W.raised = {}
    W.roads[2].z = nil
    W.roads = { { x = 3.0, y = 0.0 }, { x = 45.0, y = 0.0 } }
    s = F.dropSpot(0.0, 0.0, 20.0, 40.0, 6.0)
    ok(s and s.x ~= 45.0, 'no node inside the reach: the road past it is not used', s and s.x)
    -- OPEN GROUND, nearest ring first.
    ok(s and math.abs(math.sqrt(s.x * s.x + s.y * s.y) - 38.0 * 0.3) < 1e-6,
        'flat open ground on the nearest ring instead', s and math.sqrt(s.x * s.x + s.y * s.y))
    W.roads = {}
    W.raised = { { x = 0.0, y = 11.4, r = 2.0, z = 28.0 } }
    s = F.dropSpot(0.0, 0.0, 20.0, 40.0, 6.0)
    ok(s and not (math.abs(s.x) < 1e-6 and math.abs(s.y - 11.4) < 1e-6), 'a roof eight meters up is not open ground')
    W.raised = {}
    W.water = { { x = 0.0, y = 0.0, r = 100.0, z = 21.0 } }
    s = F.dropSpot(0.0, 0.0, 20.0, 40.0, 6.0)
    eq(s, nil, 'all water: nowhere')
    W.water = {}
    W.groundZ = -2.0
    s = F.dropSpot(0.0, 0.0, -2.0, 40.0, 6.0)
    eq(s, nil, 'below sea level (open ocean, a seabed): nowhere')
    resetWorld()
    W.roofs = { { x = 0.0, y = 0.0, r = 100.0 } }
    eq(F.dropSpot(0.0, 0.0, 20.0, 40.0, 6.0), nil, 'all under a roof (inside a building): nowhere')
    resetWorld()
    s = F.dropSpot(0.0, 0.0, 20.0, 40.0, 6.0)
    ok(s and math.sqrt(s.x * s.x + s.y * s.y) <= 38.0 and math.sqrt(s.x * s.x + s.y * s.y) >= 6.0,
        'open ground: inside the reach and never on top of the player')
end

describe('client: the look -- asked, it answers every second until told to stop')
do
    resetWorld()
    W.me = { x = 100.0, y = 100.0, z = 20.0 }
    W.roads = { { x = 115.0, y = 100.0, h = 0.0 } }
    C.toServer = {}
    cfire(BR.Net.TERMINAL_DROP_FIND, { nonce = 7, r = 40.0, minM = 6.0, everyMs = 1000, forMs = 8000 })
    runThreads()
    local a = lastToServer(BR.Net.TERMINAL_DROP_SPOT)
    ok(a and a.nonce == 7 and a.x == 115.0 and a.y == 100.0 and a.z == 20.0, 'an answer at once, with the nonce')
    ok(F.dropSearching(), 'looking')
    W.me = { x = 300.0, y = 100.0, z = 20.0 }
    W.roads = {}
    advance(1000, 100)
    a = lastToServer(BR.Net.TERMINAL_DROP_SPOT)
    ok(a and a.nonce == 7 and a.x ~= 115.0 and math.abs(a.x - 300.0) <= 40.0,
        'a second later, from where they are now', a and a.x)
    local n = #C.toServer
    advance(3000, 100)
    eq(#C.toServer, n + 3, 'one a second')
    cfire(BR.Net.TERMINAL_DROP_FIND, { nonce = 6, stop = true })
    ok(F.dropSearching(), "another search's stop is not this one's")
    cfire(BR.Net.TERMINAL_DROP_FIND, { nonce = 7, stop = true })
    ok(not F.dropSearching(), 'stopped')
    n = #C.toServer
    advance(3000, 100)
    eq(#C.toServer, n, 'and nothing more is sent')
    -- NOWHERE: `none`.
    W.roofs = { { x = 300.0, y = 100.0, r = 200.0 } }
    cfire(BR.Net.TERMINAL_DROP_FIND, { nonce = 8, r = 40.0, minM = 6.0, everyMs = 1000, forMs = 2500 })
    runThreads()
    a = lastToServer(BR.Net.TERMINAL_DROP_SPOT)
    ok(a and a.nonce == 8 and a.none == true and a.x == nil, 'nowhere to land: `none`')
    advance(4000, 100)
    ok(not F.dropSearching(), 'and the look ends on its own at `forMs`')
    W.roofs = {}
    -- OFF SEASON 2 IT DOES NOTHING.
    clientSeason = 1
    slow()
    n = #C.toServer
    cfire(BR.Net.TERMINAL_DROP_FIND, { nonce = 9, r = 40.0, minM = 6.0, everyMs = 1000, forMs = 2500 })
    runThreads()
    eq(#C.toServer, n, 'Season 1: no look')
    clientSeason = 2
    slow()
end

local function dropMsg(over)
    local d = { matchId = 1, id = 1, netId = 9501, x = 10.0, y = 20.0, z = 21.0, h = 45.0,
                tRelease = clientMs, tLand = clientMs + 9000, alt = 120.0, blip = true }
    for k, v in pairs(over or {}) do d[k] = v end
    return d
end

local function live(kind)
    local out = {}
    for id, e in pairs(C.ents) do
        if e.alive and e.kind == kind then out[#out + 1] = id end
    end
    table.sort(out)
    return out
end

describe('client: the descent -- a copy under the cargo chute, the real car hidden until it lands')
do
    resetWorld()
    W.me = { x = 50.0, y = 20.0, z = 20.0 }
    realCars = { [9501] = 801 }
    hidden = {}
    C.calls = {}
    cfire(BR.Net.TERMINAL_DROP, dropMsg())
    runThreads()
    local cars, objs = live('veh'), live('obj')
    eq(#cars, 1, 'a copy of the car')
    eq(#objs, 1, 'and its canopy')
    local car, chute = C.ents[cars[1]], C.ents[objs[1]]
    ok(car.net == false and chute.net == false, 'both local, never networked')
    eq(car.model, joaat('kuruma2'), 'the Kuruma')
    eq(chute.model, joaat(BR.Config.Airdrop.chuteModel), "the airdrop's own cargo chute")
    ok(car.collision == false and car.frozen == true and car.locked == 2, 'no collision, frozen, locked')
    eq(chute.anim, BR.Config.Airdrop.chuteAnim, 'the canopy deployed')
    eq(frameLoops(), 1, 'one FRAME callback while it comes down')
    local b, f = F.dropCounts()
    ok(b == 1 and f == 1, 'a blip, and one coming down')
    -- THE FALL CURVE: down from 120 m to the spot, on the airdrop's own shape.
    advance(50)
    near(car.z, 21.0 + 120.0, 2.0, 'it starts 120 m over the spot')
    ok(car.x == 10.0 and car.y == 20.0 and car.h == 45.0, 'over the spot, at its heading')
    near(chute.z - car.z, CC.art.drop.chuteRiseM, 1e-9, 'the canopy over it')
    eq(chute.scale, CC.art.drop.chuteScale, 'at its scale')
    ok((hidden[801] or 0) >= 1, 'the real car is hidden while it comes down')
    local rec = { gz = 21.0, alt = 120.0, tStart = clientMs - 50, tRelease = clientMs - 50, tLand = clientMs - 50 + 9000 }
    advance(4000)
    near(car.z, BR.AirdropCrateZ(rec, clientMs, 21.0, BR.Config.Airdrop), 1e-6, 'halfway: where the airdrop\'s curve has it')
    ok(car.z > 21.0 and car.z < 141.0, 'between the two')
    local hid = hidden[801]
    advance(5200)
    ok(not C.ents[cars[1]].alive and not C.ents[objs[1]].alive, 'landed: the copy and the canopy are gone')
    eq(frameLoops(), 0, 'the FRAME callback with them')
    ok(hidden[801] > hid, 'hidden right up to the landing')
    local h2 = hidden[801]
    advance(1000)
    eq(hidden[801], h2, 'and shown after it')
    b, f = F.dropCounts()
    ok(b == 1 and f == 0, 'the blip stays')

    -- OUT OF DRAW DISTANCE: the blip, and nothing to draw.
    cfire(BR.Net.TERMINAL_DROP, { matchId = 1, id = 1, off = true })
    W.me = { x = 5000.0, y = 20.0, z = 20.0 }
    cfire(BR.Net.TERMINAL_DROP, dropMsg({ id = 2 }))
    runThreads()
    eq(#live('veh'), 0, 'too far off to see: no copy')
    eq(frameLoops(), 0, 'and no FRAME callback')
    b, f = F.dropCounts()
    eq(b, 1, 'but the blip')
    cfire(BR.Net.TERMINAL_DROP, { matchId = 1, id = 2, off = true })

    -- LANDED ALREADY (a client restart): the blip alone.
    W.me = { x = 50.0, y = 20.0, z = 20.0 }
    cfire(BR.Net.TERMINAL_DROP, dropMsg({ id = 3, tRelease = clientMs - 20000, tLand = clientMs - 11000 }))
    runThreads()
    eq(#live('veh'), 0, 'landed already: no copy')
    b = F.dropCounts()
    eq(b, 1, 'the blip')
    cfire(BR.Net.TERMINAL_DROP, { matchId = 1, id = 3, off = true })
    b = F.dropCounts()
    eq(b, 0, 'and off')
end

describe('client: the blip -- the squad\'s, on both maps, moved, and taken off')
do
    for k in pairs(C.blips) do C.blips[k] = nil end
    W.me = { x = 5000.0, y = 0.0, z = 20.0 }
    cfire(BR.Net.TERMINAL_DROP, dropMsg({ id = 4, blip = false }))
    local count = 0
    for _ in pairs(C.blips) do count = count + 1 end
    eq(count, 0, 'another squad: no blip')
    cfire(BR.Net.TERMINAL_DROP, dropMsg({ id = 5 }))
    local d = {}
    for _, bl in pairs(C.blips) do d[bl.display] = bl end
    ok(d[3] and d[5], 'the pause map and the minimap')
    ok(d[3] and d[3].sprite == CC.art.drop.sprite and d[3].colour == CC.art.drop.colour
        and d[3].name == CC.copy.vehicle_drop_blip, "in the art block's look, named from the copy")
    cfire(BR.Net.TERMINAL_DROP, { matchId = 1, id = 5, x = 80.0, y = 90.0 })
    ok(d[3].x == 80.0 and d[5].y == 90.0, 'moved')
    cfire(BR.Net.TERMINAL_DROP, { matchId = 1, id = 5, off = true })
    count = 0
    for _ in pairs(C.blips) do count = count + 1 end
    eq(count, 0, 'off')
    -- THE LOBBY, AND SEASON 1.
    cfire(BR.Net.TERMINAL_DROP, dropMsg({ id = 6 }))
    BR.State.me.state = BR.PlayerState.LOBBY
    slow()
    eq(F.dropCounts(), 0, 'in the lobby: gone')
    BR.State.me.state = BR.PlayerState.ALIVE
    W.me = { x = 10.0, y = 20.0, z = 20.0 }
    cfire(BR.Net.TERMINAL_DROP, dropMsg({ id = 7 }))
    runThreads()
    clientSeason = 1
    slow()
    clientSeason = 2
    eq(F.dropCounts(), 0, 'off Season 2: gone')
    eq(#live('veh'), 0, 'the copy too')
    eq(frameLoops(), 0, 'and its FRAME callback')
    slow()
end

describe('client: nothing per frame and nothing a second with nothing to do')
do
    C.calls = {}
    for _ = 1, 10 do slow() end
    advance(2000, 16)
    eq(anyNative(), 0, 'no drop and no look: no native at all')
    eq(frameLoops(), 0, 'and no FRAME callback')
end

-- =========================================================================
-- PART D -- Airstrike, the client
-- =========================================================================

local fxCalls = { nonLooped = {}, looped = {}, stopped = 0, sounds = {}, shakes = {}, explode = {},
                  rotations = {}, requested = {}, forbidden = 0 }
function HasNamedPtfxAssetLoaded() return true end
function RequestNamedPtfxAsset(a) fxCalls.requested[#fxCalls.requested + 1] = a end
function UseParticleFxAsset() end
function StartParticleFxNonLoopedAtCoord(name, x, y, z, _, _, _, scale)
    call('StartParticleFxNonLoopedAtCoord')
    fxCalls.nonLooped[#fxCalls.nonLooped + 1] = { name = name, x = x, y = y, z = z, scale = scale }
    return true
end
-- THE ROCKET MODEL'S STREAMING (round 6): which models the game has, and how
-- long after its request each one arrives. Every model is in the game and
-- arrives at once unless a block says otherwise.
local models = { missing = {}, arrivesAfterMs = {}, askedAt = {} }
function IsModelInCdimage(h) return not models.missing[h] end
function RequestModel(h) models.askedAt[h] = models.askedAt[h] or clientMs end
function HasModelLoaded(h)
    if models.missing[h] then return false end
    local after = models.arrivesAfterMs[h]
    if not after then return true end
    local at = models.askedAt[h]
    return at ~= nil and clientMs - at >= after
end
local released = {}
function SetModelAsNoLongerNeeded(h) released[#released + 1] = h end
function SetEntityLodDist(e, d) if C.ents[e] then C.ents[e].lodDist = d end end
local loopedSeq = 0
function StartParticleFxLoopedOnEntity(name, e)
    call('StartParticleFxLoopedOnEntity')
    loopedSeq = loopedSeq + 1
    fxCalls.looped[#fxCalls.looped + 1] = { name = name, ent = e }
    return loopedSeq
end
function StopParticleFxLooped() fxCalls.stopped = fxCalls.stopped + 1 end
function PlaySoundFromCoord(_, name, x, y, z)
    call('PlaySoundFromCoord')
    fxCalls.sounds[#fxCalls.sounds + 1] = { name = name, x = x, y = y, z = z }
end
function ShakeGameplayCam(name, k) fxCalls.shakes[#fxCalls.shakes + 1] = { name = name, k = k } end
function SetEntityRotation(e, p, r, y) fxCalls.rotations[e] = { p = p, y = y } end
local controlled, vehHealth = {}, {}
function NetworkHasControlOfEntity(e) return controlled[e] == true end
function NetworkExplodeVehicle(e) fxCalls.explode[#fxCalls.explode + 1] = e end
function GetVehicleEngineHealth(e) return vehHealth[e] and vehHealth[e].engine or 1000.0 end
function GetVehicleBodyHealth(e) return vehHealth[e] and vehHealth[e].body or 1000.0 end
function SetVehicleEngineHealth(e, v) vehHealth[e] = vehHealth[e] or {}; vehHealth[e].engine = v end
function SetVehicleBodyHealth(e, v) vehHealth[e] = vehHealth[e] or {}; vehHealth[e].body = v end
-- WHAT NO CLIENT HALF MAY EVER DO: a networked, damaging explosion or a
-- projectile.
function AddExplosion() fxCalls.forbidden = fxCalls.forbidden + 1 end
function AddOwnedExplosion() fxCalls.forbidden = fxCalls.forbidden + 1 end
function ShootSingleBulletBetweenCoords() fxCalls.forbidden = fxCalls.forbidden + 1 end
local flares = {}
BR.Flare = { fire = function(x, y, z) flares[#flares + 1] = { x = x, y = y, z = z } return true end }
local pickingNow = false
BR.Terminal = { picking = function() return pickingNow end }
loadAll({ 'br_core/client/terminalfx/airstrike.lua' })
local RA = CC.art.rocket

local function radiusBlips()
    local out = {}
    for id, b in pairs(C.blips) do
        if b.kind == 'radius' then out[#out + 1] = { id = id, b = b } end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

describe('client: Airstrike\'s rough circles while the spot is picked')
do
    for k in pairs(C.blips) do C.blips[k] = nil end
    pickingNow = true
    C.calls = {}
    cfire(BR.Net.TERMINAL_FUZZ, { list = { { s = 3, x = 100.0, y = 200.0, r = 100.0 },
                                           { s = 5, x = -50.0, y = 10.0, r = 100.0 } } })
    local rb = radiusBlips()
    eq(#rb, 2, 'one circle per opponent')
    ok(rb[1].b.r == 100.0 and rb[1].b.colour == CC.art.fuzz.colour and rb[1].b.alpha == CC.art.fuzz.alpha
        and rb[1].b.name == CC.copy.airstrike_fuzz_blip, "100 m, in the art block's look, named from the copy")
    eq(F.fuzzCount(), 2, 'two up')
    local made = callsOf('AddBlipForRadius')
    cfire(BR.Net.TERMINAL_FUZZ, { list = { { s = 3, x = 150.0, y = 200.0, r = 100.0 } } })
    eq(callsOf('AddBlipForRadius'), made, 'moved, not rebuilt')
    rb = radiusBlips()
    ok(#rb == 1 and rb[1].b.x == 150.0, 'the one still sent moved; the other gone')
    slow()
    eq(F.fuzzCount(), 1, 'still picking: kept')
    pickingNow = false
    slow()
    eq(F.fuzzCount(), 0, 'the pick over here: gone, without waiting for the server')
    pickingNow = true
    cfire(BR.Net.TERMINAL_FUZZ, { list = { { s = 3, x = 150.0, y = 200.0, r = 100.0 } } })
    cfire(BR.Net.TERMINAL_FUZZ, { list = {} })
    eq(F.fuzzCount(), 0, 'an empty list: gone')
    cfire(BR.Net.TERMINAL_FUZZ, { list = { { s = 3, x = 0 / 0, y = 200.0, r = 100.0 },
                                           { s = 4, x = 1.0, y = 2.0, r = -5.0 } } })
    eq(F.fuzzCount(), 0, 'a malformed circle is not drawn')
    clientSeason = 1
    slow()
    cfire(BR.Net.TERMINAL_FUZZ, { list = { { s = 3, x = 1.0, y = 2.0, r = 100.0 } } })
    eq(F.fuzzCount(), 0, 'off Season 2: none')
    clientSeason = 2
    slow()
    pickingNow = false
end

local function strikeMsg(id, x, y, over)
    local t0 = clientMs + FX.strikeWarnMs
    local rockets = {}
    for i = 1, 10 do
        rockets[i] = { x = x + (i - 5) * 3.0, y = y, at = t0 + (i - 1) * 400 + 100 }
    end
    local d = { matchId = 1, id = id, x = x, y = y, r = 40.0, startsAt = t0, endsAt = rockets[10].at,
                rockets = rockets }
    for k, v in pairs(over or {}) do d[k] = v end
    return d
end

describe('client: Airstrike -- the circle, the flare, and nothing per frame during the warning')
do
    for k in pairs(C.blips) do C.blips[k] = nil end
    resetWorld()
    W.me = { x = 10.0, y = 0.0, z = 20.0 }
    flares = {}
    fxCalls.requested = {}
    local msg = strikeMsg(1, 0.0, 0.0)
    cfire(BR.Net.TERMINAL_STRIKE, msg)
    local rb = radiusBlips()
    ok(#rb == 1 and rb[1].b.r == 40.0 and rb[1].b.x == 0.0 and rb[1].b.colour == CC.art.strike.colour
        and rb[1].b.name == CC.copy.airstrike_blip, 'the circle on the map: 40 m, named from the copy')
    runThreads()
    ok(#flares == 1 and flares[1].x == 0.0 and flares[1].y == 0.0 and math.abs(flares[1].z - 20.1) < 1e-9,
        "a red flare at the spot, on the ground (the airdrop's BR.Flare.fire)")
    local wantAssets = false
    for _, a in ipairs(fxCalls.requested) do if a == RA.trailAsset then wantAssets = true end end
    ok(wantAssets, 'the particle streams asked for at once')
    eq(frameLoops(), 0, 'no FRAME callback during the warning')
    advance(FX.strikeWarnMs - RA.fallMs - 400, 100)
    eq(frameLoops(), 0, 'still none a moment before the first rocket falls')
    eq(fxCalls.forbidden, 0, 'and nothing forbidden')
end

describe('client: Airstrike -- each rocket falls, and lands as particles and a sound')
do
    -- (Continuing the strike above.)
    advance(300, 50)
    eq(frameLoops(), 1, 'the FRAME callback, just before the first rocket falls')
    advance(400, 50)
    local _, falling = F.strikeCounts()
    eq(falling, 1, 'the first rocket is in the air')
    local rocket = nil
    for id, e in pairs(C.ents) do
        if e.alive and e.kind == 'obj' and e.model == joaat(RA.models[1]) then rocket = id end
    end
    local e = rocket and C.ents[rocket]
    ok(e and e.net == false and e.collision == false, 'a local object, never networked, colliding with nothing')
    ok(e and e.z > 20.0 + 50.0, 'high over the ground', e and e.z)
    local z0 = e and e.z
    advance(300, 50)
    ok(e and e.z < z0, 'coming down', e and e.z)
    ok(fxCalls.looped[1] and fxCalls.looped[1].name == RA.trail and fxCalls.looped[1].ent == rocket,
        "with the RPG's trail")
    ok(fxCalls.rotations[rocket] and fxCalls.rotations[rocket].p < -60.0, 'nose down', fxCalls.rotations[rocket] and fxCalls.rotations[rocket].p)
    -- ROUND 6: "missile props never actually spawn". DRAWN FROM AS FAR AS
    -- ANYBODY SEES IT FALL: a weapon's drawable is culled past its own few
    -- meters, and nobody watching stands that close to a rocket 150 m up.
    local farthest = math.sqrt(FX.strikeDrawM ^ 2 + RA.fallM ^ 2)
    ok(e and e.lodDist and e.lodDist >= farthest,
        ('drawn from %d m, past the farthest client that draws it (%.0f m)'):format(e and e.lodDist or 0, farthest))
    -- IT LANDS: after falling long enough to be seen (2 s at least).
    local n0 = #fxCalls.nonLooped
    advance(RA.fallMs - 450, 50)
    ok(not C.ents[rocket].alive, 'landed: the rocket object is gone')
    ok(#fxCalls.nonLooped > n0, 'a fireball where it lands')
    local blast = fxCalls.nonLooped[n0 + 1]
    ok(blast and blast.name == RA.blast and blast.x == -12.0 and blast.z == 20.0, 'at its point, on the ground', blast and blast.x)
    ok(e and clientMs - e.born >= 2000, 'it was in the air for 2 seconds or more before it landed',
        e and (clientMs - e.born))
    -- "THE EXPLOSIONS FROM THEM SHOULD BE 3X AS BIG, AT LEAST": the fireball
    -- drawn out to exactly the server's damage reach.
    local scale = blast and blast.scale or 0
    ok(scale >= 3.0, ('drawn at %.2f times its size: 3x at least (it was 1x)'):format(scale))
    ok(math.abs(scale * RA.blastBaseM - FX.strikeReachM) < 1e-9,
        ('the fireball reaches %.1f m, the damage %.1f m: the same blast'):format(scale * RA.blastBaseM, FX.strikeReachM))
    ok(fxCalls.sounds[1] and fxCalls.sounds[1].name == RA.sound, "the game's explosion sound")
    ok(#fxCalls.shakes >= 1 and fxCalls.shakes[1].name == RA.shake, 'and a shake: this player is 22 m off')
    advance(5000, 50)
    eq(#fxCalls.nonLooped, n0 + 10, 'ten rockets, ten fireballs')
    eq(frameLoops(), 0, 'the FRAME callback goes with the last')
    local strikes = F.strikeCounts()
    eq(strikes, 1, 'the circle stays a moment')
    advance(FX.strikeLingerMs + 100, 500)
    slow()
    strikes = F.strikeCounts()
    eq(strikes, 0, 'then goes')
    eq(#radiusBlips(), 0, 'off the map')
    eq(fxCalls.forbidden, 0, 'never an explosion that is real, never a projectile')
end

describe('client: Airstrike -- a rocket on a roof bursts on the roof; far off, only the circle')
do
    resetWorld()
    W.me = { x = 10.0, y = 0.0, z = 20.0 }
    W.raised = { { x = 110.0, y = 100.0, r = 2.0, z = 45.0 } }
    fxCalls.nonLooped = {}
    local msg = strikeMsg(2, 100.0, 100.0, {})
    for _, rk in ipairs(msg.rockets) do rk.x, rk.y = 110.0, 100.0 end
    cfire(BR.Net.TERMINAL_STRIKE, msg)
    runThreads()
    advance(FX.strikeWarnMs + 5000, 100)
    ok(#fxCalls.nonLooped == 10 and fxCalls.nonLooped[1].z == 45.0, 'on the roof the rocket meets first', fxCalls.nonLooped[1] and fxCalls.nonLooped[1].z)
    advance(FX.strikeLingerMs + 100, 500)
    slow()

    -- FAR OFF.
    flares = {}
    fxCalls.nonLooped = {}
    W.me = { x = 5000.0, y = 0.0, z = 20.0 }
    cfire(BR.Net.TERMINAL_STRIKE, strikeMsg(3, 0.0, 0.0))
    runThreads()
    eq(#radiusBlips(), 1, 'far off: the circle on the map')
    eq(#flares, 0, 'no flare')
    advance(FX.strikeWarnMs + 5000, 100)
    eq(#fxCalls.nonLooped, 0, 'no rockets, no fireballs')
    eq(frameLoops(), 0, 'and never a FRAME callback')
    -- THE LOBBY.
    W.me = { x = 10.0, y = 0.0, z = 20.0 }
    cfire(BR.Net.TERMINAL_STRIKE, strikeMsg(4, 0.0, 0.0))
    runThreads()
    BR.State.me.state = BR.PlayerState.LOBBY
    slow()
    BR.State.me.state = BR.PlayerState.ALIVE
    eq(F.strikeCounts(), 0, 'in the lobby: every strike goes')
    eq(#radiusBlips(), 0, 'and its circle')
    advance(FX.strikeWarnMs + 5000, 100)
    eq(frameLoops(), 0, 'and nothing falls')
    slow()
end

describe('client: Airstrike -- the rocket model: streamed and waited on, the stand-ins when it will not come')
do
    -- ROUND 6: the RPG's rocket was asked for once and never waited on; a
    -- rocket whose model had not arrived was skipped every frame, silently.
    local function rocketsOf(model)
        local n = 0
        for _, e in pairs(C.ents) do
            if e.kind == 'obj' and e.model == model then n = n + 1 end
        end
        return n
    end
    local function strikeAt(id)
        resetWorld()
        W.me = { x = 10.0, y = 0.0, z = 20.0 }
        fxCalls.nonLooped = {}
        for k in pairs(C.ents) do C.ents[k] = nil end
        cfire(BR.Net.TERMINAL_STRIKE, strikeMsg(id, 0.0, 0.0))
        runThreads()
        advance(FX.strikeWarnMs + 5000, 50)
        advance(FX.strikeLingerMs + 100, 500)
        slow()
    end
    local rpg, second = joaat(RA.models[1]), joaat(RA.models[2])
    ok(RA.models[1] == 'w_lr_rpg_rocket', 'the RPG\'s rocket first')

    -- ARRIVING LATE: three seconds after it is asked for, inside the warning.
    models.arrivesAfterMs[rpg] = 3000
    models.askedAt[rpg] = nil
    strikeAt(21)
    eq(rocketsOf(rpg), 10, 'a model that streams in three seconds later: every rocket is drawn')
    models.arrivesAfterMs[rpg] = nil

    -- NOT IN THE GAME: the next model in the list.
    models.missing[rpg] = true
    logs = {}
    strikeAt(22)
    eq(rocketsOf(rpg), 0, 'the RPG\'s rocket missing: none of it')
    eq(rocketsOf(second), 10, 'every rocket is drawn as the next model in the list')
    eq(#fxCalls.nonLooped, 10, 'and every one lands')

    -- NONE AT ALL: the blasts still land, and the console says why once.
    for _, name in ipairs(RA.models) do models.missing[joaat(name)] = true end
    logs = {}
    strikeAt(23)
    local objs = 0
    for _, e in pairs(C.ents) do if e.kind == 'obj' then objs = objs + 1 end end
    eq(objs, 0, 'no model at all: no rocket object')
    eq(#fxCalls.nonLooped, 10, 'the ten blasts still land')
    local said = 0
    for _, l in ipairs(logs) do if l:find('no rocket model would load', 1, true) then said = said + 1 end end
    eq(said, 1, 'and the console says so, once')
    models.missing = {}
    ok(#released >= 1, 'a strike gone lets its model go')
end

describe('client: Airstrike -- the owner of a vehicle a rocket hit writes the server\'s figure')
do
    realCars = { [9601] = 901, [9602] = 902 }
    controlled = { [901] = true }
    vehHealth = {}
    C.ents[901] = { kind = 'veh', alive = true }
    C.ents[902] = { kind = 'veh', alive = true }
    cfire(BR.Net.TERMINAL_STRIKE_VEH, { netId = 9601, frac = 0.5 })
    ok(vehHealth[901] and vehHealth[901].engine == 500.0 and vehHealth[901].body == 500.0,
        'half the damage off its engine and its body')
    cfire(BR.Net.TERMINAL_STRIKE_VEH, { netId = 9601, frac = 5.0 })
    ok(vehHealth[901].engine == -500.0 and vehHealth[901].body == 0.0, 'a fraction past one is one')
    cfire(BR.Net.TERMINAL_STRIKE_VEH, { netId = 9602, frac = 0.5 })
    eq(vehHealth[902], nil, 'a vehicle this client does not own: untouched')
    cfire(BR.Net.TERMINAL_STRIKE_VEH, { netId = 9601, wreck = true })
    eq(fxCalls.explode[1], 901, 'wrecked: blown up the way any wreck is')
    cfire(BR.Net.TERMINAL_STRIKE_VEH, { netId = 9999, wreck = true })
    eq(#fxCalls.explode, 1, 'an unknown vehicle: nothing')
    clientSeason = 1
    slow()
    cfire(BR.Net.TERMINAL_STRIKE_VEH, { netId = 9601, wreck = true })
    clientSeason = 2
    slow()
    eq(#fxCalls.explode, 1, 'off Season 2: nothing')
    C.ents[901], C.ents[902] = nil, nil
    eq(fxCalls.forbidden, 0, 'and never AddExplosion')
end

describe('client: Airstrike -- nothing per frame and nothing a second with nothing to do')
do
    C.calls = {}
    for _ = 1, 10 do slow() end
    advance(2000, 16)
    eq(anyNative(), 0, 'no strike and no circles: no native at all')
    eq(frameLoops(), 0, 'and no FRAME callback')
end

BR = serverBR

-- =========================================================================

realPrint(('%d passed, %d failed'):format(pass, fail))
if fail > 0 then realExit(1) end
