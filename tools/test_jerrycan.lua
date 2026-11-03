-- Unit tests for the Season 2 jerry can (#217): the server half and the shared
-- rules.
--
-- ═══ WHAT THE OWNER ASKED FOR, AND WHAT THIS HOLDS IT TO ═══
--
--   "a useable loot item, which would only be useable at the gascap of a
--    vehicle ... For anything other than small 4wheelers/buggies/dirtbikes,
--    this should add 25% fuel to the tank, and for 4wheelers/buggies/dirtbikes
--    it should fill the tank completely. Neither the ped nor the vehicle should
--    be able to move while fueling, and fueling should not be able to start
--    while in motion. maxCarry 1 on the jerry can."  -- owner, 2026-08-22
--   "please remember that jerry can will be a season 2+ feature"
--   "yes, freeze the vehicle while pouring."
--   "the jerry can does not repair the vehicle"
--   "partial use of a can should be possible."      -- owner, 2026-11-02
--
-- ON THE REAL FILES: br_lib's configs (vehicle_models.lua included), the season
-- module, rng, fuel_solve, terminal_solve and jerrycan_solve; and br_core's
-- server/inventory.lua, loot.lua, fuel.lua, jerrycan.lua, yubikey.lua and
-- vehicles.lua, loaded in the manifest's order. The roster, the match and the
-- scheduler are stubs in tools/test_yubikey.lua's shape, over a MODELED VEHICLE
-- WORLD: entities with buckets, coordinates, headings, speeds and models; an
-- owner, a frozen bit and an engine per vehicle; seats, and a GetVehiclePedIsIn
-- that can go stale the way citizenfx/fivem#4006 makes it; and every
-- FreezeEntityPosition RPC the server sends, recorded with the owner it went to.
--
--   A  config and season            I  conservation, seeded random sequences
--   B  the shared solver            J  the griefer bound
--   C  the vehicle data             K  transfers and the wire
--   D  the press's refusals         L  loot
--   E  an accepted press            M  no repair
--   F  the ticks                    N  regressions
--   G  completions                  O  the icon
--   H  the cancel matrix            P  the playtest, by brfueltank
--
-- Run via tools/verify.sh, or directly:  lua tools/test_jerrycan.lua

local realPrint = print
local realExit  = os.exit

local fakeTime = 100000
function GetGameTimer() return fakeTime end
function GetCurrentResourceName() return 'br_core' end
function GetConvar(_, d) return d end
function SetConvarReplicated() end
function RegisterNetEvent() end

local commands = {}
function RegisterCommand(name, fn) commands[name] = fn end

local handlers = {}
function AddEventHandler(name, fn)
    handlers[name] = handlers[name] or {}
    table.insert(handlers[name], fn)
end

local sent = {}
function TriggerClientEvent(event, target, payload)
    sent[#sent + 1] = { event = event, target = target, payload = payload }
end
function TriggerEvent() end

local timers = {}
function SetTimeout(ms, fn) timers[#timers + 1] = { at = fakeTime + ms, fn = fn } end
function GetResourceState(name) return name == 'br_ddb' and 'started' or 'missing' end
function GetPlayerName(src) return 'p' .. tostring(src) end

local logs = {}
function print(...)
    local t = {}
    for i = 1, select('#', ...) do t[#t + 1] = tostring((select(i, ...))) end
    logs[#logs + 1] = table.concat(t, ' ')
end

Citizen = { CreateThread = function() end, Wait = function() end, SetTimeout = SetTimeout }

--- Jenkins one-at-a-time, as GTA hashes a name (tools/check_vehicles.lua's).
local function joaat(s)
    local h = 0
    for i = 1, #s do
        h = (h + s:lower():byte(i)) & 0xFFFFFFFF
        h = (h + (h << 10)) & 0xFFFFFFFF
        h = h ~ (h >> 6)
    end
    h = (h + (h << 3)) & 0xFFFFFFFF
    h = h ~ (h >> 11)
    h = (h + (h << 15)) & 0xFFFFFFFF
    return h
end
function GetHashKey(s) return joaat(tostring(s)) end

-- ---------------------------------------------------------------------------
-- The world
-- ---------------------------------------------------------------------------
--
-- HANDLES AND NETWORK IDS ARE DIFFERENT NUMBERS, for tools/test_fuel.lua's
-- reason: a registry keyed on the wrong one must be able to fail here.

local W

local function world()
    W = {
        exists = {}, coords = {}, heading = {}, speed = {}, model = {},
        etype = {}, bucket = {}, owner = {}, frozen = {}, engine = {},
        netOf = {}, entOf = {}, seats = {}, pedVeh = {},
    }
end
world()

--- Every FreezeEntityPosition the server sent: { ent, on, owner, at }.
local rpcs = {}

function DoesEntityExist(e) return W.exists[e] and 1 or 0 end
function GetEntityCoords(e)
    local c = W.coords[e]
    if not c then return nil end
    return { x = c.x, y = c.y, z = c.z }
end
function GetEntityHeading(e) return W.heading[e] or 0.0 end
function GetEntitySpeed(e) return W.speed[e] or 0.0 end
--- SIGNED, as the engine answers a hash with its top bit set.
function GetEntityModel(e)
    local h = W.model[e] or 0
    if h >= 0x80000000 then return h - 0x100000000 end
    return h
end
function GetEntityType(e) return W.etype[e] or 0 end
function GetEntityRoutingBucket(e) return W.bucket[e] or 0 end
function NetworkGetEntityOwner(e) return W.owner[e] or -1 end
function IsEntityPositionFrozen(e) return W.frozen[e] and 1 or 0 end
function GetIsVehicleEngineRunning(e) return W.engine[e] and 1 or 0 end
function FreezeEntityPosition(e, on)
    rpcs[#rpcs + 1] = { ent = e, on = on, owner = W.owner[e] or -1, at = fakeTime }
end
function NetworkGetEntityFromNetworkId(n) return W.entOf[n] or 0 end
function NetworkGetNetworkIdFromEntity(e) return W.netOf[e] or 0 end
--- citizenfx/fivem#4006: the LAST vehicle a ped sat in, until the engine
--- forgets -- so a player who got out can still read as in it.
function GetVehiclePedIsIn(ped) return W.pedVeh[ped] or 0 end
function GetPedInVehicleSeat(veh, seat) return (W.seats[veh] or {})[seat] or 0 end
function GetPlayerPed() return 0 end

-- ---------------------------------------------------------------------------
-- The real files
-- ---------------------------------------------------------------------------

BR = BR or {}

local ROOT = 'resources/[fivem-royale]/'
local function load(f)
    local chunk, err = loadfile(ROOT .. f)
    if not chunk then
        realPrint('\27[31mload error\27[0m ' .. f .. ': ' .. tostring(err))
        realExit(1)
    end
    chunk()
end

for _, f in ipairs({
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
    'br_lib/config/vehicles.lua',
    'br_lib/config/loot.lua',
    'br_lib/config/fuel.lua',
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
    'br_lib/shared/fuel_solve.lua',
    'br_lib/shared/health_solve.lua',
    'br_lib/shared/terminal_solve.lua',
    'br_lib/shared/jerrycan_solve.lua',
}) do load(f) end

BR.Season.strict = true

local function season(n)
    BR.Season.boot(function(name)
        return name == 'br_season' and tostring(n) or ''
    end, function() end)
end
season(2)

-- The roster, the match and the scheduler, in tools/test_yubikey.lua's shape.
local roster = {}
local matches = {}
local notices = {}

BR.Roster = {
    get = function(src) return roster[src] end,
    each = function(pred, fn)
        local ids = {}
        for s in pairs(roster) do ids[#ids + 1] = s end
        table.sort(ids)
        for _, s in ipairs(ids) do
            local e = roster[s]
            if e and (not pred or pred(e)) then fn(s, e) end
        end
    end,
    sampleIntervalMs = function() return 250 end,
}
BR.Server = {
    matches = matches,
    devMode = false,
    matchOf = function(src)
        local e = roster[src]
        return e and e.matchId and matches[e.matchId] or nil
    end,
    matchById = function(id) return matches[id] end,
    eachMatch = function(fn) for _, m in pairs(matches) do fn(m) end end,
    notify = function(target, text, tone)
        notices[#notices + 1] = { target = target, text = text, tone = tone }
    end,
}
BR.Airdrop = { opened = function() end }

--- The jobs, IN THE ORDER THEY REGISTERED, which is the order BR.Sched runs
--- them in. A pass runs the three a pour lives through.
local jobs = {}
BR.Sched = { every = function(_, name, fn) jobs[#jobs + 1] = { name = name, fn = fn } end }
local PASS = { ['inv.use'] = true, ['fuel.sample'] = true, ['jerrycan.reconcile'] = true }

for _, f in ipairs({
    'br_core/server/inventory.lua',
    'br_core/server/loot.lua',
    'br_core/server/fuel.lua',
    'br_core/server/jerrycan.lua',
    'br_core/server/yubikey.lua',
    'br_lib/config/vehicle_models.lua',
    'br_core/server/vehicles.lua',
}) do load(f) end

local JC, JS = BR.JerryCan, BR.JerryCanSolve
local F = BR.Config.Fuel
local J = F.jerryCan
local TANK = F.tankMetres
local CAN = BR.Config.JerryCan
local CT = BR.Config.Terminals

local function job(name)
    for _, j in ipairs(jobs) do if j.name == name then return j.fn end end
    return nil
end

--- One scheduler pass, `ms` after the last (250 by default).
local function tick(ms)
    fakeTime = fakeTime + (ms or 250)
    for _, j in ipairs(jobs) do
        if PASS[j.name] then j.fn(ms or 250) end
    end
end

local function fire(name, src, ...)
    local prev = source
    source = src
    for _, fn in ipairs(handlers[name] or {}) do fn(...) end
    source = prev
end

-- ---------------------------------------------------------------- harness ---

local pass, fail = 0, 0
local group = ''
local function describe(n) group = n end
local function ok(cond, name, detail)
    if cond then pass = pass + 1 else
        fail = fail + 1
        realPrint('\27[31mFAIL\27[0m ' .. group .. ' > ' .. name ..
            (detail ~= nil and ('\n       ' .. tostring(detail)) or ''))
    end
end
local function near(a, b, eps)
    return math.abs((tonumber(a) or 0) - (tonumber(b) or 0)) <= (eps or 1e-9)
end
local function readFile(p)
    local fh = io.open(p, 'rb')
    if not fh then return nil end
    local s = fh:read('a')
    fh:close()
    return s
end

--- Every payload of one event, to one target or to anybody.
local function events(name, target)
    local out = {}
    for _, s in ipairs(sent) do
        if s.event == name and (target == nil or s.target == target) then
            out[#out + 1] = s.payload
        end
    end
    return out
end
--- The targets one event went to, as a set.
local function targets(name, pred)
    local out = {}
    for _, s in ipairs(sent) do
        if s.event == name and (pred == nil or pred(s.payload)) then out[s.target] = (out[s.target] or 0) + 1 end
    end
    return out
end
local function rpcsFor(ent, on)
    local out = {}
    for _, r in ipairs(rpcs) do
        if r.ent == ent and (on == nil or r.on == on) then out[#out + 1] = r end
    end
    return out
end

-- ---------------------------------------------------------------- scenes ---

local MATCH, OTHER = 1, 2
local BUCKET, OTHER_BUCKET = 1001, 1002
local CAR, NET = 500, 900
--- Where the car stands, and where a pourer stands at its rear left: 1.5 m to
--- the left of its middle and 2 m behind its origin, at heading 0.
local V = { x = 1000.0, y = 1000.0, z = 30.0 }
local AT = { lx = -1.5, ly = -2.0 }

local function newMatch(id, bucket)
    local m = {
        id = id, seq = id, bucket = bucket, state = BR.MatchState.PLAYING, mode = 'solo',
        loot = { seed = 77, nextId = 0, items = {}, cells = {}, subs = {}, at = {},
                 respawn = {}, fixed = 0 },
    }
    matches[id] = m
    return m
end

--- Every cell a player could ask for, so a claim is judged on reach alone.
local ANY_CELL = setmetatable({}, { __index = function() return true end })

--- A player and their ped, standing at (x, y, z).
local function player(src, matchId, state, x, y, z)
    local ped = 100 + src
    W.exists[ped], W.etype[ped] = true, 1
    W.coords[ped] = { x = x or 0.0, y = y or 0.0, z = z or 30.0 }
    W.bucket[ped] = matchId == OTHER and OTHER_BUCKET or BUCKET
    W.pedVeh[ped] = 0
    roster[src] = {
        src = src, name = 'p' .. src, state = state or BR.PlayerState.ALIVE,
        matchId = matchId, ped = ped, hp = 100, armour = 0,
        pos = { x = x or 0.0, y = y or 0.0, z = z or 30.0 },
    }
    local m = matchId and matches[matchId]
    if m then m.loot.subs[src] = ANY_CELL end
    return roster[src]
end

--- Move a player: the ped and the roster's own sample, which agree.
local function place(src, x, y, z)
    local e = roster[src]
    W.coords[e.ped] = { x = x, y = y, z = z or e.pos.z }
    e.pos = { x = x, y = y, z = z or e.pos.z }
end

--- The world point at (lx, ly) in a vehicle's own frame.
local function worldOf(vx, vy, heading, lx, ly)
    local r = math.rad(heading or 0.0)
    return vx + lx * math.cos(r) - ly * math.sin(r), vy + lx * math.sin(r) + ly * math.cos(r)
end

--- A vehicle of `name`'s model (or a raw hash), in match 1's bucket.
local function vehicle(ent, net, name, x, y, heading)
    W.exists[ent], W.etype[ent] = true, 2
    W.coords[ent] = { x = x, y = y, z = V.z }
    W.heading[ent] = heading or 0.0
    W.speed[ent] = 0.0
    W.model[ent] = type(name) == 'number' and name or joaat(name)
    W.bucket[ent] = BUCKET
    W.owner[ent] = 2
    W.netOf[ent], W.entOf[net] = net, ent
    W.seats[ent] = {}
end

local function seat(src, ent, s)
    local ped = roster[src].ped
    W.pedVeh[ped] = ent
    W.seats[ent][s] = ped
end

--- Out of a vehicle. `stale` leaves GetVehiclePedIsIn answering it (#4006).
local function unseat(src, ent, stale)
    local ped = roster[src].ped
    for k, v in pairs(W.seats[ent] or {}) do
        if v == ped then W.seats[ent][k] = nil end
    end
    if not stale then W.pedVeh[ped] = 0 end
end

local function moveCar(ent, x, y)
    W.coords[ent] = { x = x, y = y, z = W.coords[ent].z }
end

--- Burn `meters` of a vehicle's tank the way a match does: a driver in it
--- (player `driver`), driving it in steps the sampler believes, then out of it
--- and the car put back where it stood. Admits the row on the way.
local function drain(ent, meters, driver)
    driver = driver or 2
    local home = { x = W.coords[ent].x, y = W.coords[ent].y }
    local e = roster[driver]
    local wasAt = { x = e.pos.x, y = e.pos.y, z = e.pos.z }
    seat(driver, ent, -1)
    tick()
    local done = 0.0
    while done < meters - 1e-9 do
        local d = math.min(25.0, meters - done)
        moveCar(ent, W.coords[ent].x + d, W.coords[ent].y)
        tick()
        done = done + d
    end
    unseat(driver, ent)
    tick()
    moveCar(ent, home.x, home.y)
    place(driver, wasAt.x, wasAt.y, wasAt.z)
end

--- A fresh world, a fresh season-2 match with a car, and the match's people:
---
---   1  the pourer, ALIVE, standing at the car's cap (AT)
---   2  the driver who burned its fuel, ALIVE, out of it now
---   3  a spectator (OUT) and 4 a downed player (DBNO), same match
---   9  somebody ALIVE in another match
---
--- opts: model (the car's, 'adder'), burn (meters burned, 3750), fill (the
--- can's, nil for a fill-less can), at ({ lx, ly } of the pourer), heading,
--- noCan (give the pourer nothing), noHand (do not select the can).
local function scene(opts)
    opts = opts or {}
    fakeTime = fakeTime + 60000
    world()
    for k in pairs(matches) do matches[k] = nil end
    for k in pairs(roster) do roster[k] = nil end
    sent, rpcs, notices, logs, timers = {}, {}, {}, {}, {}
    JC.reset()
    BR.Fuel.reset()
    season(opts.season or 2)

    newMatch(MATCH, BUCKET)
    newMatch(OTHER, OTHER_BUCKET)
    local h = opts.heading or 0.0
    vehicle(CAR, NET, opts.model or 'adder', V.x, V.y, h)

    local at = opts.at or AT
    local px, py = worldOf(V.x, V.y, h, at.lx, at.ly)
    player(1, MATCH, nil, px, py, V.z)
    player(2, MATCH, nil, V.x + 6.0, V.y, V.z)
    player(3, MATCH, BR.PlayerState.OUT, V.x + 50.0, V.y, V.z)
    player(4, MATCH, BR.PlayerState.DBNO, V.x + 60.0, V.y, V.z)
    player(9, OTHER, nil, V.x + 70.0, V.y, V.z)

    if (opts.burn or 3750.0) > 0 then drain(CAR, opts.burn or 3750.0) end

    local slot = nil
    if not opts.noCan then
        BR.Inv.give(1, { item = CAN.id, kind = BR.ItemKind.CONSUMABLE,
                         rarity = CAN.rarity, count = 1, fill = opts.fill })
        local inv = BR.Inv.of(1)
        for i = 1, 5 do
            if inv.slots[i] and inv.slots[i].item == CAN.id then slot = i end
        end
        if not opts.noHand then fire(BR.Net.INV_SELECT, 1, { slot = slot }) end
    end
    sent, rpcs, notices = {}, {}, {}
    return slot
end

local function inv(src) return BR.Inv.of(src) end
local function press(src, slot, n) fire(BR.Net.INV_USE, src, { slot = slot, n = n }) end
--- A slot's fill, or 'empty' when the slot holds nothing -- so a can that
--- left the bag fails an assertion rather than the suite.
local function fillAt(src, slot)
    local s = inv(src).slots[slot]
    if not s then return 'empty' end
    return s.fill
end

--- The can wherever it is: { where, stack } -- a slot, the ground or nowhere.
local function findCan()
    for src, e in pairs(roster) do
        for i = 1, 5 do
            local s = e.inv and e.inv.slots[i]
            if s and s.item == CAN.id then return 'slot', s, src, i end
        end
    end
    for _, m in pairs(matches) do
        for _, it in pairs(m.loot.items) do
            if it.item == CAN.id then return 'ground', it, m end
        end
    end
    return nil
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('A. config and season')
-- ═══════════════════════════════════════════════════════════════════════════
do
    local row = BR.Config.Seasons.features.jerrycan
    local keys = 0
    for _ in pairs(row or {}) do keys = keys + 1 end
    ok(row ~= nil and row.from == 2 and keys == 1,
       'the seasons row is exactly { from = 2 }: Season 2 and on, no untilSeason')
    season(1)
    ok(BR.Season.has('jerrycan') == false, 'off on Season 1')
    season(2)
    ok(BR.Season.has('jerrycan') == true, 'on on Season 2')

    local WANT = {
        id = 'jerrycan', label = 'Jerry Can', plural = 'Jerry Cans',
        rarity = BR.Rarity.RARE, kind = BR.ItemKind.CONSUMABLE, prop = 'w_am_jerrycan',
        useMs = 5000, maxStack = 1, carryMax = 1, refuel = true, emote = 'jerrycan',
    }
    local bad = {}
    for k, v in pairs(WANT) do
        if CAN[k] ~= v then bad[#bad + 1] = ('%s = %s'):format(k, tostring(CAN[k])) end
    end
    for k in pairs(CAN) do
        if WANT[k] == nil then bad[#bad + 1] = 'extra field ' .. k end
    end
    ok(#bad == 0, 'the item row holds exactly its eleven fields', table.concat(bad, ', '))
    ok(BR.Rarity.RARE == 3, 'rare is 3, the blue tint')
    for _, k in ipairs({ 'ignoresDamage', 'repairVeh', 'health', 'armour', 'chestOnly',
                         'propScale', 'propDrop', 'shopCar' }) do
        ok(CAN[k] == nil, ('and it has no `%s`'):format(k))
    end

    ok(BR.Config.ConsumableById.jerrycan == CAN, 'registered by hand into ConsumableById')
    local inList = false
    for _, c in ipairs(BR.Config.Consumables) do if c.id == 'jerrycan' then inList = true end end
    ok(not inList, 'and in no Consumables entry')
    local inBucket = false
    for r = BR.Rarity.COMMON, BR.Rarity.LEGENDARY do
        for _, t in ipairs({ BR.Config.ConsumablesByRarity[r] or {},
                             BR.Config.ConsumablesByRarityFloor[r] or {} }) do
            for _, c in ipairs(t) do if c.id == 'jerrycan' then inBucket = true end end
        end
    end
    ok(not inBucket, 'and in no rarity bucket, crate or floor')

    local WANT_J = {
        crateChance = 0.02, canFraction = 0.25, settleMs = 250, minPourMs = 250,
        minSpace = 0.005, emptyBelow = 1e-6, stillSpeed = 0.5, driftMeters = 1.0,
        pourerDrift = 0.75, boxMargin = 2.0, riseMeters = 3.0,
        releaseGraceMs = 2000, capReach = 1.5, capRise = 2.0, scanMeters = 10.0,
        markerReach = 3.0,
        capBones = { 'petrolcap', 'petroltank', 'petroltank_l', 'petroltank_r', 'fueltank' },
        wheelBones = { 'wheel_lr', 'wheel_rr' },
        marker = { kind = 0, size = 0.15, height = 0.15, lift = 0.35,
                   color = { r = 240, g = 240, b = 240, a = 200 } },
    }
    local function same(a, b)
        if type(a) ~= type(b) then return false end
        if type(a) ~= 'table' then return a == b end
        for k, v in pairs(a) do if not same(v, b[k]) then return false end end
        for k in pairs(b) do if a[k] == nil then return false end end
        return true
    end
    local diff = {}
    for k, v in pairs(WANT_J) do
        if not same(v, J[k]) then diff[#diff + 1] = k end
    end
    for k in pairs(J) do if WANT_J[k] == nil then diff[#diff + 1] = 'extra ' .. k end end
    ok(#diff == 0, 'BR.Config.Fuel.jerryCan holds every value, and nothing else',
       table.concat(diff, ', '))
    ok(J.useMs == nil, 'and the pour time lives on the item row alone')

    local E = BR.Config.UseEmotes.jerrycan
    ok(E and E.use == 1 and #E == 2, 'UseEmotes.jerrycan: two entries, use = 1')
    local e1, e2 = E[1], E[2]
    ok(e1.dict == 'weapons@misc@jerrycan@' and e1.clip == 'fire' and e1.bone == 57005
       and e1.pos.x == 0.18 and e1.pos.y == 0.13 and e1.pos.z == -0.24
       and e1.rot.x == -165.87 and e1.rot.y == -11.21 and e1.rot.z == -32.95,
       'the default is rpemotes-reborn\'s `fuel`: the clip and the right hand together')
    ok(e2.dict == 'weapon@w_sp_jerrycan' and e2.clip == 'fire' and e2.bone == 18905
       and e2.pos.x == 0.11 and e2.pos.y == 0.0 and e2.pos.z == 0.25
       and e2.rot.x == 15.0 and e2.rot.y == 170.0 and e2.rot.z == 90.42,
       'the alternate is cdn-fuel\'s, left hand')
    ok(E.flag == nil and e1.flag == nil and e2.flag == nil,
       'and no flag: the emote pass plays every row with its own 49')
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('B. the solver')
-- ═══════════════════════════════════════════════════════════════════════════
do
    local rows = {}
    for _, r in ipairs(BR.Config.VehicleModels) do rows[r.name] = r end
    local adder, sanchez, blazer = rows.adder, rows.sanchez, rows.blazer

    -- fillOf and empty.
    ok(JS.fillOf(nil) == 1 and JS.fillOf({}) == 1, 'a can with no fill is a whole can')
    ok(JS.fillOf({ fill = 0.6 }) == 0.6, 'a fill reads as itself')
    ok(JS.fillOf({ fill = 'lots' }) == 1 and JS.fillOf({ fill = 0 / 0 }) == 1,
       'a fill that is not a number reads as whole')
    ok(JS.fillOf({ fill = 1.5 }) == 1 and JS.fillOf({ fill = -0.2 }) == 0,
       'and one out of range is brought into 0..1')
    ok(JS.empty(0) and JS.empty(1e-6) and not JS.empty(2e-6) and not JS.empty(0.5),
       'empty at or below a millionth of a can')
    ok(not JS.empty(nil) and not JS.empty(0 / 0), 'a fill that is not a number is not empty')
    ok(JS.empty(0.01, { emptyBelow = 0.05 }), 'and the threshold can be an argument')

    -- perCan.
    ok(JS.perCan(sanchez, TANK, 0.25) == 7500, 'a jerryFills row: a whole tank, 7,500 m')
    ok(JS.perCan(blazer, TANK, 0.25) == 7500, 'and a quad is one too')
    ok(JS.perCan(adder, TANK, 0.25) == 1875, 'a plain row: a quarter, 1,875 m')
    ok(JS.perCan(nil, TANK, 0.25) == 1875, 'an add-on with no row: a quarter')
    ok(JS.perCan(adder, nil, nil) == 1875, 'nil reads the config: the tank and canFraction')

    -- plan.
    local m, ms = JS.plan(1, TANK, 1875, 5000, 250)
    ok(m == 1875 and ms == 5000, 'a dry car: 1,875 m in 5,000 ms', ('%s %s'):format(m, ms))
    m, ms = JS.plan(1, 750, 1875, 5000, 250)
    ok(m == 750 and ms == 2000, 'a car at 90%: 750 m in 2,000 ms', ('%s %s'):format(m, ms))
    ok(near(JS.fillAfter(1, 750, 1875), 0.6), 'and the can keeps 0.6')
    m, ms = JS.plan(1, 5250, 7500, 5000, 250)
    ok(m == 5250 and ms == 3500, 'a dirt bike at 30%: 5,250 m in 3,500 ms', ('%s %s'):format(m, ms))
    ok(near(JS.fillAfter(1, 5250, 7500), 0.3), 'and the can keeps 0.3')
    m, ms = JS.plan(1, 10, 1875, 5000, 250)
    ok(m == 10 and ms == 250, 'a sliver of room: floored at 250 ms', ('%s %s'):format(m, ms))
    m, ms = JS.plan(0.5, TANK, 1875, 5000, 250)
    ok(m == 937.5 and ms == 2500, 'half a can: half the meters in half the time')
    for _, args in ipairs({ { 1, 0 }, { 1, -5 }, { 0, TANK }, { -0.1, TANK }, { 0 / 0, TANK },
                            { 1, 0 / 0 } }) do
        ok(JS.plan(args[1], args[2], 1875, 5000, 250) == nil,
           ('no plan for fill %s and space %s'):format(tostring(args[1]), tostring(args[2])))
    end
    ok(JS.plan(1, TANK, 0, 5000, 250) == nil, 'no plan for a can worth nothing')
    m = JS.plan(1.5, TANK, 1875, 5000, 250)
    ok(m == 1875, 'a fill above one is one: a can never holds more than a can')
    m, ms = JS.plan(1, TANK, 1875)
    ok(m == 1875 and ms == 5000, 'nil reads the item row\'s useMs and the config\'s floor')

    -- target.
    ok(JS.target(0, 5000, 1875, 250) == 0 and JS.target(249, 5000, 1875, 250) == 0,
       'nothing inside the settle window')
    ok(JS.target(250, 5000, 1875, 250) == 93.75, 'then the elapsed share: 93.75 m at 250 ms')
    ok(JS.target(5000, 5000, 1875, 250) == 1875 and JS.target(9000, 5000, 1875, 250) == 1875,
       'the whole plan at the end, and never past it')
    ok(JS.target(300, 0, 1875, 250) == 1875, 'a pour of no length is done')
    local mono, last = true, -1
    for t = 0, 6000, 7 do
        local v = JS.target(t, 5000, 1875, 250)
        if v < last then mono = false end
        last = v
    end
    ok(mono, 'and it never goes down as time passes')

    -- fillAfter.
    ok(JS.fillAfter(1, 0, 1875) == 1 and near(JS.fillAfter(0.6, 375, 1875), 0.4),
       'what is left is the start less what poured, in cans')
    ok(JS.perCan(adder, 0, 0.25) == 0, 'no tank, no can')
    ok(JS.perCan(adder, TANK, 0 / 0) == 0 and JS.plan(1, TANK, 1875, 5000, 0 / 0) == 1875,
       'and a broken number is broken, not the config\'s: only nil reads the config')
    ok(JS.fillAfter(0.5, -100, 1875) == 0.5 and JS.fillAfter(0.5, 0 / 0, 1875) == 0.5,
       'a negative or broken pour takes nothing out and puts nothing back')
    ok(JS.fillAfter(0.1, 999999, 1875) == 0, 'and it never goes below empty')

    -- crateRoll.
    ok(JS.CRATE_SALT == 217, 'the can\'s stream is salt 217')
    local same = true
    for id = 1, 200 do
        if JS.crateRoll(77, id, 0.5) ~= JS.crateRoll(77, id, 0.5) then same = false end
    end
    ok(same, 'the roll replays from the layout seed')
    local never, always = true, true
    for id = 1, 500 do
        if JS.crateRoll(77, id, 0) then never = false end
        if not JS.crateRoll(77, id, 1) then always = false end
    end
    ok(never and always, 'chance 0 is never and 1 is always')
    local hits, both = 0, 0
    local N = 100000
    for id = 1, N do
        if JS.crateRoll(4242, id, 0.02) then hits = hits + 1 end
        if JS.crateRoll(4242, id, 0.5) and BR.TerminalSolve.extraRoll(4242, id, 0.5) then
            both = both + 1
        end
    end
    ok(math.abs(hits / N - 0.02) <= 0.002,
       ('about 1 crate in 50 over 100,000 (%.4f)'):format(hits / N), hits / N)
    ok(math.abs(both / N - 0.25) <= 0.0125,
       ('at 0.5 each, a can and a key turn up together a quarter of the time (%.4f): independent streams')
           :format(both / N), both / N)
    ok(both / N < 0.4, 'and nowhere near a half, which one shared float would give')
    local keyOk = true
    for id = 1, 10000 do
        if BR.TerminalSolve.extraRoll(99, id, 0.37) ~= BR.TerminalSolve.extraRoll(99, id, 0.37, 396) then
            keyOk = false
        end
    end
    ok(keyOk, 'no salt is the key\'s 396: every key a pinned seed replayed, replays')
    local differ = 0
    for id = 1, 1000 do
        if BR.TerminalSolve.extraRoll(99, id, 0.5) ~= JS.crateRoll(99, id, 0.5) then differ = differ + 1 end
    end
    ok(differ > 300, 'and the can\'s salt rolls apart from it', differ)

    -- toLocal.
    local lx, ly = JS.toLocal(1000, 1005, 1000, 1000, 0)
    ok(near(lx, 0) and near(ly, 5), 'heading 0: +y is ahead')
    lx, ly = JS.toLocal(1005, 1000, 1000, 1000, 0)
    ok(near(lx, 5) and near(ly, 0), 'and +x is to the right')
    lx, ly = JS.toLocal(995, 1000, 1000, 1000, 90)
    ok(near(lx, 0, 1e-9) and near(ly, 5, 1e-9), 'heading 90 faces west: -x is ahead')
    lx, ly = JS.toLocal(1000, 1005, 1000, 1000, 90)
    ok(near(lx, 5, 1e-9) and near(ly, 0, 1e-9), 'and +y is to its right')
    ok(JS.toLocal(0 / 0, 0, 0, 0, 0) == nil and JS.toLocal(0, 0, 0, 0, nil) == nil,
       'a position or a heading that is not a number has no frame')

    -- atCap, under two headings, at every edge. THE PARTY BUS'S ROW, which is
    -- long behind and short ahead (4.4 m ahead of its origin, 7.5 behind), so a
    -- box that mixed up its front and its rear fails here; an Adder's is the
    -- same both ways and could not tell.
    local bus = rows.pbus2
    ok(bus.front ~= bus.rear, 'the Party Bus\'s box is not the same front and back')
    for _, h in ipairs({ 0.0, 37.0 }) do
        local function at(lx2, ly2, dz, row)
            local x, y = worldOf(V.x, V.y, h, lx2, ly2)
            return JS.atCap(x, y, V.z + (dz or 0), V.x, V.y, V.z, h, row or bus, J, F.askRadius)
        end
        local reach, front, rear = bus.reach + J.boxMargin, bus.front + J.boxMargin,
                                   bus.rear + J.boxMargin
        ok(at(reach - 0.01, 0) and at(-(reach - 0.01), 0),
           ('heading %g: just inside the box across, both sides'):format(h))
        local okL, whyL = at(reach + 0.01, 0)
        local okR = at(-(reach + 0.01), 0)
        ok(not okL and not okR and whyL == 'box', ('heading %g: just outside it across, both sides'):format(h))
        ok(at(0, front - 0.01) and not at(0, front + 0.01), ('heading %g: the front edge'):format(h))
        ok(at(0, -(rear - 0.01)) and not at(0, -(rear + 0.01)), ('heading %g: the rear edge'):format(h))
        ok(at(reach - 0.01, -(rear - 0.01)), ('heading %g: the rear corner is inside'):format(h))
        ok(at(AT.lx, AT.ly, 2.99), ('heading %g: 2.99 m above is close enough'):format(h))
        local okZ, whyZ = at(AT.lx, AT.ly, 3.01)
        ok(not okZ and whyZ == 'rise', ('heading %g: 3.01 m above is not'):format(h))
        local okD = at(AT.lx, AT.ly, -3.01)
        ok(not okD, ('heading %g: nor 3.01 m below'):format(h))
    end
    -- The fallback: no row, and a row with no sizes, at askRadius.
    local function radial(d, row)
        return JS.atCap(V.x + d, V.y, V.z, V.x, V.y, V.z, 0, row, J, nil)
    end
    ok(radial(11.99, nil) and not radial(12.01, nil), 'an add-on falls back to askRadius (12 m)')
    local okR2, whyR2 = radial(12.01, nil)
    ok(whyR2 == 'radius', 'and says so', whyR2)
    ok(radial(11.99, rows.arbitergt) and not radial(12.01, rows.arbitergt),
       'and so does a row the data has no size for')
    ok(radial(11.99, { reach = 1, front = 2 }) and not radial(12.01, { reach = 1, front = 2 }),
       'and a row missing one of the three')
    ok(not JS.atCap(0 / 0, 0, 0, 0, 0, 0, 0, adder, J), 'and a position that is not a number is not at it')

    -- drifted.
    ok(not JS.drifted(0, 0, 0.74, 0, 0.75) and JS.drifted(0, 0, 0.76, 0, 0.75),
       'drifted: further than the limit, in 2D')
    ok(JS.drifted(0, 0, 0 / 0, 0, 0.75) and JS.drifted(0, 0, 0, 0, nil),
       'and a position or a limit that is not a number has drifted')

    -- anchorBones.
    local function has(set) return function(n) return set[n] == true end end
    local function list(t) return table.concat(t, ',') end
    ok(list(JS.anchorBones(has({ fueltank = true, petroltank_r = true, petrolcap = true,
                                 petroltank = true, petroltank_l = true }))) ==
       'petrolcap,petroltank,petroltank_l,petroltank_r,fueltank',
       'every cap bone a model has, in config order')
    ok(list(JS.anchorBones(has({ petroltank_r = true, petrolcap = true, wheel_lr = true }))) ==
       'petrolcap,petroltank_r', 'a cap bone and a wheel: the cap bones alone')
    ok(list(JS.anchorBones(has({ wheel_rr = true, wheel_lr = true }))) == 'wheel_lr,wheel_rr',
       'no cap bone: both rear wheels')
    ok(list(JS.anchorBones(has({ wheel_lr = true, wheel_lf = true }))) == 'wheel_lr',
       'a bike: its one rear wheel')
    ok(list(JS.anchorBones(has({ fueltank = true }))) == 'fueltank', 'the Bus: fueltank alone')
    ok(#JS.anchorBones(has({ wheel_lf = true, chassis = true })) == 0, 'nothing at all: not a target')
    ok(#JS.anchorBones(function() return 1 end) == 0, 'and only a true answer counts')

    -- nearestAnchor.
    local A1 = { x = 1.0, y = 0.0, z = 0.0, bone = 'a' }
    local A2 = { x = 0.0, y = 1.4, z = 0.0, bone = 'b' }
    local A3 = { x = 0.0, y = -1.0, z = 0.0, bone = 'c' }
    local A4 = { x = 0.5, y = 0.0, z = 2.5, bone = 'd' }
    local best, d = JS.nearestAnchor({ A2, A1, A4 }, 0, 0, 0, 1.5, 2.0)
    ok(best == A1 and near(d, 1.0), 'the nearest in 2D, carried back whole with its own fields')
    ok(JS.nearestAnchor({ A2 }, 0, 0, 0, 1.39, 2.0) == nil, 'nothing past the reach')
    ok(JS.nearestAnchor({ A4 }, 0, 0, 0, 1.5, 2.0) == nil, 'nothing past the rise')
    best = JS.nearestAnchor({ A3, A1 }, 0, 0, 0, 1.5, 2.0)
    ok(best == A3, 'a tie goes to the earlier in the list')
    best = JS.nearestAnchor({ A1, A3 }, 0, 0, 0, 1.5, 2.0)
    ok(best == A1, 'whichever that is')
    ok(JS.nearestAnchor({ A2 }, 0, 0, 0) == A2, 'nil reads capReach and capRise')
    ok(JS.nearestAnchor({}, 0, 0, 0) == nil and JS.nearestAnchor(nil, 0, 0, 0) == nil,
       'and no anchors, no point')
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('C. the vehicle data')
-- ═══════════════════════════════════════════════════════════════════════════
do
    local OWNERS = {
        'bf400', 'bfinjection', 'bifta', 'blazer', 'blazer2', 'blazer3', 'blazer4', 'blazer5',
        'chimera', 'dune', 'dune2', 'dune3', 'dune4', 'dune5', 'enduro', 'esskey', 'manchez',
        'manchez2', 'manchez3', 'outlaw', 'rrocket', 'sanchez', 'sanchez2', 'stryder',
        'vagrant', 'verus',
    }
    local marked, byName = {}, {}
    local sized, partial = 0, {}
    for _, r in ipairs(BR.Config.VehicleModels) do
        byName[r.name] = r
        if r.jerryFills == true then marked[#marked + 1] = r.name end
        local n = (r.reach and 1 or 0) + (r.below and 1 or 0) + (r.front and 1 or 0) + (r.rear and 1 or 0)
        if n == 4 then sized = sized + 1 elseif n ~= 0 then partial[#partial + 1] = r.name end
    end
    table.sort(marked)
    ok(table.concat(marked, ',') == table.concat(OWNERS, ','),
       'the jerryFills rows are exactly the owner\'s 26', table.concat(marked, ','))
    ok(byName.rcbandito and byName.rcbandito.jerryFills == nil,
       'and the RC Bandito, a toy in a buggy layout, is not marked')
    ok(#partial == 0, 'every row with a size has all four', table.concat(partial, ', '))
    ok(sized == 916, 'and 916 rows have them', sized)

    -- modelRowOf, through the real server/vehicles.lua.
    local adder = byName.adder
    ok(adder.hash >= 0x80000000, 'the Adder\'s hash has its top bit set (a signed answer is negative)')
    ok(BR.Vehicles.modelRowOf(adder.hash) == adder, 'modelRowOf answers by the unsigned hash')
    ok(BR.Vehicles.modelRowOf(adder.hash - 0x100000000) == adder,
       'and by the signed one GetEntityModel answers')
    ok(BR.Vehicles.modelRowOf(joaat('my_addon_car')) == nil, 'nil for an add-on')
    ok(BR.Vehicles.modelRowOf(nil) == nil and BR.Vehicles.modelRowOf('adder') == nil,
       'and nil for no hash, or a name instead of one')
    ok(BR.Vehicles.modelRowOf(byName.sanchez.hash).jerryFills == true,
       'a dirt bike\'s row says a can fills it')
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('D. the press\'s refusals, in order')
-- ═══════════════════════════════════════════════════════════════════════════
do
    --- Press, and hold the press to having done nothing at all: no channel, no
    --- claim, the slot and its fill as they were, no FUEL_CAN, no ledger write,
    --- no toast -- and the reason counted, when there is one.
    local function refused(key, label, slot, n, src)
        src = src or 1
        local inv1 = inv(src)
        local s = slot and inv1.slots[slot] or nil
        local snap = {
            item = s and s.item, count = s and s.count, fill = s and s.fill,
            left = BR.Fuel.left(NET), pours = BR.Fuel.stats().pours,
            presses = JC.stats().presses, why = JC.stats().refused[key or ''] or 0,
            using = inv1.using,
        }
        sent, notices = {}, {}
        press(src, slot, n)
        local s2 = slot and inv1.slots[slot] or nil
        ok(inv1.using == snap.using and JC.claimOf(NET) == nil and JC.claimOf(n) == nil,
           label .. ': no channel and no claim')
        ok((s2 and s2.item) == snap.item and (s2 and s2.count) == snap.count
           and (s2 and s2.fill) == snap.fill, label .. ': the slot and its fill unchanged')
        ok(#events(BR.Net.FUEL_CAN) == 0 and #rpcs == 0, label .. ': no FUEL_CAN and no freeze')
        ok(BR.Fuel.left(NET) == snap.left and BR.Fuel.stats().pours == snap.pours,
           label .. ': no ledger write')
        ok(#notices == 0, label .. ': and not a word to the player', notices[1] and notices[1].text)
        if key then
            ok((JC.stats().refused[key] or 0) == snap.why + 1, label .. ': counted as `' .. key .. '`',
               JC.stats().refused[key])
        else
            ok(JC.stats().presses == snap.presses, label .. ': refused before the can is asked')
        end
    end

    -- THE GENERIC GATES: the inventory's own, before the can is asked.
    local slot = scene()
    roster[1].state = BR.PlayerState.DBNO
    refused(nil, 'downed (not live)', slot, NET)
    slot = scene()
    refused(nil, 'an empty slot', 4, NET)
    slot = scene()
    BR.Inv.give(1, { item = 'bandage', kind = BR.ItemKind.CONSUMABLE, rarity = BR.Rarity.COMMON, count = 1 })
    roster[1].hp = 40
    local bslot
    for i = 1, 5 do if inv(1).slots[i] and inv(1).slots[i].item == 'bandage' then bslot = i end end
    press(1, bslot)
    ok(inv(1).using ~= nil, 'a bandage is being used')
    refused(nil, 'another channel running', slot, NET)
    ok(inv(1).using.item == 'bandage', 'and the bandage\'s channel is untouched')

    -- season
    slot = scene()
    season(1)
    refused('season', 'Season 1', slot, NET)
    season(2)
    -- hand
    slot = scene({ noHand = true })
    refused('hand', 'the can not in hand', slot, NET)
    -- nomodule
    slot = scene()
    local realSpace = BR.Fuel.space
    BR.Fuel.space = nil
    refused('nomodule', 'no fuel ledger to ask', slot, NET)
    BR.Fuel.space = realSpace
    -- nonet
    for _, n in ipairs({ false, 0, 1.5, 'abc' }) do
        slot = scene()
        refused('nonet', ('n = %s'):format(tostring(n)), slot, n ~= false and n or nil)
    end
    -- noentity
    slot = scene()
    refused('noentity', 'a network id naming nothing', slot, 4242)
    slot = scene()
    W.exists[CAR] = nil
    refused('noentity', 'an entity that does not exist', slot, NET)
    -- notvehicle
    slot = scene()
    W.netOf[102], W.entOf[950] = 950, 102
    refused('notvehicle', 'a ped, not a vehicle', slot, 950)
    -- bucket
    slot = scene()
    W.bucket[CAR] = OTHER_BUCKET
    refused('bucket', 'a car in another match\'s bucket', slot, NET)
    -- untracked
    slot = scene({ burn = 0 })
    refused('untracked', 'a car nobody has sat in (it reads full)', slot, NET)
    slot = scene({ burn = 0 })
    drain(CAR, 3000.0, 9)
    refused('untracked', 'a car whose ledger row is another match\'s', slot, NET)
    -- full
    slot = scene({ burn = 30.0 })
    refused('full', 'within half a percent of full (30 m of room)', slot, NET)
    slot = scene({ burn = 0 })
    seat(2, CAR, -1)
    tick()
    unseat(2, CAR)
    tick()
    refused('full', 'a full tank', slot, NET)
    -- seated
    for _, s in ipairs({ -1, 0, 1, 2 }) do
        slot = scene()
        seat(1, CAR, s)
        refused('seated', ('the pourer in seat %d'):format(s), slot, NET)
    end
    -- ...AND AT THE BACK OF A BUS: every seat it has, not the cabin's eight
    -- (BR.Vehicles.EVERY_SEAT). Seat 7 is the last the roadkill sampler walks;
    -- 8, 9 and 14 are past it, and the first build poured from all three.
    for _, s in ipairs({ 7, 8, 9, 14 }) do
        slot = scene({ model = 'bus', at = { lx = 0.6, ly = -4.0 } })
        seat(1, CAR, s)
        refused('seated', ('the pourer in seat %d of a bus'):format(s), slot, NET)
    end
    -- away: each edge of the box, and the rise
    local adder = BR.Vehicles.modelRowOf(joaat('adder'))
    local m = J.boxMargin
    for _, at in ipairs({
        { lx = adder.reach + m + 0.05, ly = 0, what = 'right' },
        { lx = -(adder.reach + m + 0.05), ly = 0, what = 'left' },
        { lx = 0, ly = adder.front + m + 0.05, what = 'front' },
        { lx = 0, ly = -(adder.rear + m + 0.05), what = 'rear' },
    }) do
        slot = scene({ at = at })
        refused('away', 'just past the box\'s ' .. at.what .. ' edge', slot, NET)
    end
    slot = scene()
    place(1, roster[1].pos.x, roster[1].pos.y, V.z + 3.5)
    refused('away', '3.5 m above the car', slot, NET)
    -- moving
    slot = scene()
    W.speed[CAR] = 0.6
    refused('moving', 'the car rolling at 0.6 m/s', slot, NET)
    slot = scene()
    W.speed[roster[1].ped] = 0.6
    refused('moving', 'the pourer walking at 0.6 m/s', slot, NET)
    -- claimed
    slot = scene()
    player(5, MATCH, nil, worldOf(V.x, V.y, 0, 1.5, -2.0))
    BR.Inv.give(5, { item = CAN.id, kind = BR.ItemKind.CONSUMABLE, rarity = CAN.rarity, count = 1 })
    fire(BR.Net.INV_SELECT, 5, { slot = 1 })
    press(5, 1, NET)
    ok(JC.claimOf(NET) ~= nil and JC.claimOf(NET).src == 5, 'somebody else is pouring into it')
    local theirs = JC.claimOf(NET)
    sent = {}
    local before = JC.stats().refused.claimed or 0
    press(1, slot, NET)
    ok(inv(1).using == nil and JC.claimOf(NET) == theirs, 'claimed: no channel, and their claim stands')
    ok((JC.stats().refused.claimed or 0) == before + 1, 'claimed: counted')
    ok(#events(BR.Net.FUEL_CAN) == 0, 'claimed: no FUEL_CAN')
    -- empty
    slot = scene({ fill = 0 })
    refused('empty', 'a can with nothing in it', slot, NET)

    -- #4006: OUT OF THE CAR, WHILE GetVehiclePedIsIn STILL ANSWERS IT.
    slot = scene({ burn = 0 })
    drain(CAR, 3750.0, 1)
    place(1, worldOf(V.x, V.y, 0, AT.lx, AT.ly))
    seat(1, CAR, -1)
    unseat(1, CAR, true)
    ok(GetVehiclePedIsIn(roster[1].ped) == CAR, 'the stale read still names the car (#4006)')
    sent = {}
    press(1, slot, NET)
    ok(inv(1).using ~= nil and JC.claimOf(NET) ~= nil,
       'and the press is accepted: the car\'s own seats say they are on foot')
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('E. an accepted press')
-- ═══════════════════════════════════════════════════════════════════════════
do
    local slot = scene()
    local left0 = BR.Fuel.left(NET)
    ok(near(left0, TANK - 3750, 1e-6), 'the car is at half a tank', left0)
    local t0 = fakeTime
    press(1, slot, NET)
    local u = inv(1).using
    ok(u ~= nil and u.ms == 5000 and u.endsAt == t0 + 5000, 'the channel is the plan: 5,000 ms',
       u and u.ms)
    ok(u and u.pour == JC.claimOf(NET) and u.pour ~= nil, 'and its pour IS the claim')
    ok(inv(1).slots[slot] and inv(1).slots[slot].fill == nil, 'the can\'s fill is untouched by the press')
    -- NOTHING GOES TO THE MATCH AT THE PRESS: it first hears of a pour on the
    -- slice that pays for it (F, and J for why).
    ok(#events(BR.Net.FUEL_CAN) == 0, 'no FUEL_CAN at the press, to anybody', #events(BR.Net.FUEL_CAN))
    ok(#rpcs == 0, 'no freeze yet: nothing pours or freezes in the settle window')
    ok(BR.Fuel.left(NET) == left0 and BR.Fuel.stats().pours == 0, 'and no fuel moves yet')
    ok(JC.stats().starts == 1 and JC.stats().presses == 1, 'one press, one start')
    local firstId = u and u.pour and u.pour.id
    ok(math.type(firstId) == 'integer' and firstId >= 1, 'the pour has its id, for the wire', firstId)

    -- AND THE NEXT PRESS GETS THE NEXT ID.
    slot = scene()
    press(1, slot, NET)
    ok(JC.claimOf(NET) and JC.claimOf(NET).id == firstId + 1, 'ids increase, across resets too')
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('F. the ticks')
-- ═══════════════════════════════════════════════════════════════════════════
do
    local slot = scene()
    -- Two people in the car while it is poured into -- they may -- and a third
    -- who got out, whose GetVehiclePedIsIn still names it (#4006).
    player(5, MATCH, nil, V.x, V.y, V.z)
    player(6, MATCH, nil, V.x + 3, V.y, V.z)
    seat(2, CAR, -1)
    seat(5, CAR, 0)
    seat(6, CAR, 1)
    unseat(6, CAR, true)
    tick(0)
    local left0 = BR.Fuel.left(NET)
    sent = {}
    press(1, slot, NET)
    local pour = JC.claimOf(NET)

    tick(100)
    ok(BR.Fuel.left(NET) == left0 and #rpcs == 0, 'before 250 ms nothing happens')
    ok(#events(BR.Net.FUEL_CAN) == 0, 'and nothing is sent to anybody')

    tick(150)
    ok(near(BR.Fuel.left(NET), left0 + 93.75, 1e-9), 'the first slice is the elapsed share: 93.75 m',
       BR.Fuel.left(NET) - left0)
    ok(near(fillAt(1, slot), 1 - 93.75 / 1875), 'and the can lost exactly that',
       fillAt(1, slot))
    local on = rpcsFor(CAR, true)
    ok(#on == 1 and on[1].owner == 2, 'the freeze RPC goes once, to the owner', #on)
    -- THE HOLD IS THE FIRST THE MATCH HEARS OF THE POUR: to every roster entry
    -- in it, in every state -- the downed and the out see the can in a hand
    -- too -- and to nobody outside it.
    local to = targets(BR.Net.FUEL_CAN)
    ok(to[1] == 1 and to[2] == 1 and to[3] == 1 and to[4] == 1 and to[5] == 1 and to[6] == 1,
       'FUEL_CAN hold reaches every match member, in every state: alive, out, downed')
    ok(to[9] == nil, 'and nobody in another match')
    local holds = 0
    for _, p in ipairs(events(BR.Net.FUEL_CAN, 3)) do
        if p.hold == true then
            holds = holds + 1
            ok(p.ms == 4750 and p.id == pour.id and p.n == NET and p.p == 1,
               'it is { id, n, p, ms, hold = true }, with 4,750 ms left', p.ms)
        end
    end
    ok(holds == 1 and #events(BR.Net.FUEL_CAN, 3) == 1, 'FUEL_CAN hold once, and nothing before it', holds)
    local cues = targets(BR.Net.FUEL_SFX, function(p) return p.c == 'fuel.start' and p.n == NET end)
    ok(cues[1] == 1 and cues[2] == 1 and cues[5] == 1,
       'fuel.start reaches the pourer and each seated occupant, once each')
    ok(cues[6] == nil, 'and not the one who got out (#4006)')
    ok(cues[3] == nil and cues[9] == nil, 'nor anyone else')

    tick()
    ok(near(BR.Fuel.left(NET), left0 + 187.5, 1e-9), 'and a slice every pass after',
       BR.Fuel.left(NET) - left0)
    ok(#rpcsFor(CAR, true) == 1, 'with no second freeze for the same owner')
    cues = targets(BR.Net.FUEL_SFX, function(p) return p.c == 'fuel.start' end)
    ok(cues[1] == 1, 'and no second cue')

    -- THE OWNER MOVES: the RPC is sent again, to whoever owns it now.
    W.owner[CAR] = 5
    tick()
    on = rpcsFor(CAR, true)
    ok(#on == 2 and on[2].owner == 5, 'a new owner is sent the freeze again', #on)
    ok(JC.stats().ownerChanges == 1, 'and it is counted')
    ok(pour.owners[2] and pour.owners[5], 'both owners recorded')
    -- AND ONCE (#217's third review): a pour that kept no note of whom it last
    -- sent to would send the new owner the freeze on every pass.
    tick()
    ok(#rpcsFor(CAR, true) == 2 and JC.stats().ownerChanges == 1,
       'and only once: the next pass, the car still theirs, sends them nothing',
       #rpcsFor(CAR, true))
    W.owner[CAR] = -1
    tick()
    ok(#rpcsFor(CAR, true) == 3, 'nobody owning it: sent anyway, to wait for the next')
    W.owner[CAR] = 65535
    tick()
    W.owner[CAR] = 0
    tick()
    ok(#rpcsFor(CAR, true) == 3, 'and 65535 or 0 is still nobody, not a change')

    -- WHAT THE SERVER READS OF THE CAR IS COUNTED, AND DECIDES NOTHING.
    W.engine[CAR], W.frozen[CAR] = true, true
    local e0, f0 = JC.stats().engineOnPasses, JC.stats().frozenPasses
    tick()
    tick()
    ok(JC.stats().engineOnPasses == e0 + 2 and JC.stats().frozenPasses == f0 + 2,
       'engine-running and frozen reads are counted')
    ok(JC.claimOf(NET) == pour and inv(1).using ~= nil, 'and never cancel a pour')
    ok(pour.engineSeen >= 2 and pour.frozenSeen >= 2, 'and kept on the pour for the readout')

    -- `brjerrycan` reads it all back.
    logs = {}
    commands.brjerrycan(0, {})
    local live = false
    for _, l in ipairs(logs) do
        if l:find(('car %d <- 1'):format(NET), 1, true) then live = true end
    end
    ok(live, 'brjerrycan lists the live pour', logs[4])

    -- THE BACK OF A BUS IS IN IT: the cue reaches a rider in seat 12, past the
    -- cabin's eight -- the same every-seat reading the pourer's own test uses.
    slot = scene({ model = 'bus', at = { lx = 0.6, ly = -4.0 } })
    player(5, MATCH, nil, V.x, V.y, V.z)
    seat(5, CAR, 12)
    sent = {}
    press(1, slot, NET)
    tick()
    local cued = targets(BR.Net.FUEL_SFX, function(p) return p.c == 'fuel.start' and p.n == NET end)
    ok(cued[1] == 1 and cued[5] == 1, 'fuel.start reaches a rider at the back of a bus, seat 12',
       tostring(cued[5]))
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('G. completions')
-- ═══════════════════════════════════════════════════════════════════════════
do
    --- Run a pour to its end, recording every BR.Fuel.pour answer.
    local poured = {}
    local realPour = BR.Fuel.pour
    BR.Fuel.pour = function(n, m, x)
        local a = realPour(n, m, x)
        poured[#poured + 1] = a
        return a
    end
    local function run(maxTicks)
        for _ = 1, maxTicks or 40 do
            if inv(1).using == nil then return end
            tick()
        end
    end

    -- A FULL CAN INTO A CAR AT HALF: +1,875 m, AND THE CAN IS GONE.
    local slot = scene()
    local left0 = BR.Fuel.left(NET)
    poured = {}
    press(1, slot, NET)
    run()
    ok(near(BR.Fuel.left(NET), left0 + 1875, 1e-6), 'a car gets +1,875 m from a full can',
       BR.Fuel.left(NET) - left0)
    ok(inv(1).slots[slot] == false, 'and the empty can leaves the bag')
    local sum = 0
    for _, a in ipairs(poured) do sum = sum + a end
    ok(near(sum, 1875, 1e-6), 'the slices add up to the plan: nothing paid twice', sum)
    ok(JC.claimOf(NET) == nil, 'the claim is gone')
    local ends = 0
    for _, p in ipairs(events(BR.Net.FUEL_CAN, 3)) do if p.ms == 0 then ends = ends + 1 end end
    ok(ends == 1, 'FUEL_CAN end goes out once')
    ok(#rpcsFor(CAR, false) == 1, 'and the unfreeze RPC with it')
    ok(JC.stats().completions == 1 and JC.stats().emptied == 1, 'counted: one completion, one emptied')
    local pushed = events(BR.Net.INV_SET, 1)
    local lastSlot = pushed[#pushed].slots[slot]
    ok(lastSlot == false, 'and the pourer is told the slot is empty')
    ok(#notices == 0, 'and not a word: a pour that completes is as silent as one refused or cut short',
       notices[1] and notices[1].text)

    -- A CAR AT 90%: ENDS EXACTLY FULL, AND THE CAN KEEPS 0.6.
    slot = scene({ burn = 750 })
    press(1, slot, NET)
    ok(inv(1).using.ms == 2000, 'a 750 m pour is two seconds')
    run()
    ok(BR.Fuel.left(NET) == TANK, 'a car at 90% ends exactly full', BR.Fuel.left(NET))
    ok(near(fillAt(1, slot), 0.6, 1e-9), 'and the can keeps 0.6', fillAt(1, slot))
    pushed = events(BR.Net.INV_SET, 1)
    local sentSlot = pushed[#pushed].slots[slot]
    ok(sentSlot and sentSlot.fill == 0.6, 'which is what its plate is sent', sentSlot and sentSlot.fill)
    ok(#notices == 0, 'and a pour that keeps the rest in the can says nothing either',
       notices[1] and notices[1].text)

    -- A DRY DIRT BIKE: FULL, AND THE CAN IS GONE.
    slot = scene({ model = 'sanchez', burn = TANK })
    ok(BR.Fuel.left(NET) == 0, 'the bike is dry')
    press(1, slot, NET)
    ok(inv(1).using.ms == 5000, 'a whole tank is the whole five seconds')
    run()
    ok(BR.Fuel.left(NET) == TANK, 'a dry dirt bike ends full', BR.Fuel.left(NET))
    ok(inv(1).slots[slot] == false, 'and the can is gone')

    -- A QUAD AT 80%: FULL, AND THE CAN KEEPS 0.8.
    slot = scene({ model = 'blazer', burn = 1500 })
    press(1, slot, NET)
    run()
    ok(BR.Fuel.left(NET) == TANK, 'a quad at 80% ends full')
    ok(near(fillAt(1, slot), 0.8, 1e-9), 'and the can keeps 0.8', fillAt(1, slot))

    -- A PUMP IN THE SAME CAR FILLS IT FIRST: THE POUR ENDS EARLY, AND THE CAN
    -- PAID ONLY FOR WHAT IT POURED.
    local S = F.stations[1]
    slot = scene()
    moveCar(CAR, S.x, S.y)
    place(1, worldOf(S.x, S.y, 0, AT.lx, AT.ly))
    seat(2, CAR, -1)
    tick(0)
    poured = {}
    press(1, slot, NET)
    local due = inv(1).using.endsAt
    local endedAt = nil
    for _ = 1, 40 do
        if inv(1).using == nil then break end
        fakeTime = fakeTime + 1
        fire(BR.Net.FUEL_PUMP, 2, { n = NET })
        tick(249)
        if inv(1).using == nil and endedAt == nil then endedAt = fakeTime end
    end
    sum = 0
    for _, a in ipairs(poured) do sum = sum + a end
    ok(inv(1).using == nil and JC.claimOf(NET) == nil, 'the pump filled it first and the pour ended')
    ok(endedAt ~= nil and endedAt < due - 1000,
       'on the pass the tank filled, well before its bar was due', endedAt and (due - endedAt))
    ok(BR.Fuel.left(NET) == TANK, 'with the tank full')
    ok(sum < 1875 - 1, 'having poured less than its plan', sum)
    ok(near(fillAt(1, slot), 1 - sum / 1875, 1e-9),
       'and the can lost only what IT poured', fillAt(1, slot))
    BR.Fuel.pour = realPour

    -- ═══ THE RELEASE IS THE SAFE HALF ON EVERY PATH ═══
    --
    -- A car a pour froze is watched from its release UNTIL THE SERVER READS IT
    -- FREE: past the second the server's read of a freeze can lag, it is sent
    -- the unfreeze again while it reads frozen, by whoever owns it, whatever
    -- presses, claims and cancels come after -- and only a pour that holds it
    -- again ends the watch, since that pour's release starts its own.

    --- A pour that holds the car, then its pourer downed: released on that
    --- pass, with the unfreeze, and watched from a second and a half on. The
    --- log of RPCs starts after it, and the car still reads frozen -- the
    --- release's unfreeze did not land -- unless `landed`.
    local function heldThenDropped(landed)
        local s = scene({ burn = 7500 })
        press(1, s, NET)
        tick()
        tick()
        ok(JC.claimOf(NET) and JC.claimOf(NET).hold == true, 'the pour holds the car')
        roster[1].state = BR.PlayerState.DBNO
        tick()
        ok(JC.claimOf(NET) == nil and #rpcsFor(CAR, false) == 1,
           'downed: released, and the unfreeze sent with it')
        rpcs = {}
        W.frozen[CAR] = not landed
        return s
    end

    -- WATCHED UNTIL IT READS FREE: nothing read into it inside the lag, then
    -- the unfreeze again every second and a half for as long as it reads
    -- frozen -- not three looks and done, which left a car still frozen -- and
    -- the car counted once. The first read that finds it free ends the watch.
    heldThenDropped()
    for _ = 1, 5 do tick() end           -- 1,250 ms on
    ok(#rpcsFor(CAR, false) == 0 and JC.stats().frozenAfterRelease == 0,
       'inside the lag nothing is read into it: no unfreeze again, nothing counted',
       #rpcsFor(CAR, false))
    tick()                               -- 1.5 s: the first look
    ok(#rpcsFor(CAR, false) == 1 and JC.stats().frozenAfterRelease == 1,
       'past it, a car still reading frozen is sent the unfreeze again, and counted',
       #rpcsFor(CAR, false))
    for _ = 1, 34 do tick() end          -- ten seconds after the release
    ok(#rpcsFor(CAR, false) == 6,
       'and again every second and a half while it reads frozen: six by ten seconds',
       #rpcsFor(CAR, false))
    ok(JC.stats().frozenAfterRelease == 1 and JC.stats().queued == 1,
       'counted once: one car the unfreeze did not reach, and still watched',
       JC.stats().frozenAfterRelease)
    W.frozen[CAR] = false                -- it lands, and the owner's sync says so
    tick()
    ok(JC.stats().queued == 0, 'the first read that finds it free ends the watch')
    W.frozen[CAR] = true
    for _ = 1, 12 do tick() end
    ok(#rpcsFor(CAR, false) == 6, 'and nothing is sent after it: a car read free is nobody\'s to watch',
       #rpcsFor(CAR, false))

    -- A RELEASE THAT WORKED IS NOT COUNTED: the owner's sync catches up with
    -- the unfreeze inside the lag, and the watch finds the car free.
    heldThenDropped()
    for _ = 1, 4 do tick() end           -- a second of the stale bit
    W.frozen[CAR] = false                -- then the sync of the unfreeze
    for _ = 1, 8 do tick() end
    ok(#rpcsFor(CAR, false) == 0 and JC.stats().frozenAfterRelease == 0,
       'a release whose read was a second stale is neither sent again nor counted',
       JC.stats().frozenAfterRelease)
    ok(JC.stats().queued == 0, 'and its watch is over')

    -- A PRESS THAT NEVER HOLDS DOES NOT END THE WATCH (#217's second review).
    -- The release's unfreeze did not land; the pourer, up again, presses at
    -- once and steps off inside the settle window, so the new pour freezes
    -- nothing and sends nothing. The first build dropped the watch for any
    -- claim on the car, and the car stood frozen for the rest of the match.
    local slot2 = heldThenDropped()
    roster[1].state = BR.PlayerState.ALIVE
    tick(100)
    press(1, slot2, NET)
    ok(JC.claimOf(NET) ~= nil and JC.claimOf(NET).hold == false,
       'pressed again at once: a new claim, in its settle window')
    tick(100)                            -- a pass with that claim standing
    place(1, roster[1].pos.x, roster[1].pos.y - 0.8)
    tick()
    ok(JC.claimOf(NET) == nil and (JC.stats().cancels.moved or 0) == 1,
       'and cut short before its first slice')
    ok(#rpcs == 0 and JC.stats().queued == 1,
       'having sent nothing itself, and left the first pour\'s watch standing', #rpcs)
    for _ = 1, 8 do tick() end           -- past the first release's lag
    ok(#rpcsFor(CAR, false) == 1 and JC.stats().frozenAfterRelease == 1,
       'which still sends the car the unfreeze, and counts it', #rpcsFor(CAR, false))
    W.frozen[CAR] = false
    tick()
    ok(JC.stats().queued == 0, 'until it reads free')

    -- ...NOR ONE STILL IN ITS SETTLE WINDOW AS THE WATCH LOOKS: that claim has
    -- frozen nothing, so the car under it is sent the unfreeze -- and the pass
    -- it holds, the watch is over and its freeze stands.
    slot2 = heldThenDropped()
    roster[1].state = BR.PlayerState.ALIVE
    for _ = 1, 5 do tick() end           -- 1,250 ms on
    fakeTime = fakeTime + 150            -- and between two passes, pressed
    press(1, slot2, NET)                 -- again, 100 ms before the first look
    tick(100)
    ok(JC.claimOf(NET) ~= nil and JC.claimOf(NET).hold == false, 'the look comes with the claim unheld')
    ok(#rpcsFor(CAR, false) == 1 and #rpcsFor(CAR, true) == 0,
       'and the car is sent the unfreeze: a claim that has not held froze nothing')
    tick()                               -- the claim's first slice
    ok(JC.claimOf(NET) ~= nil and JC.claimOf(NET).hold == true, 'then it holds')
    ok(rpcs[#rpcs] and rpcs[#rpcs].ent == CAR and rpcs[#rpcs].on == true,
       'its freeze the last thing the car was sent')
    for _ = 1, 12 do tick() end          -- the new pour freezing it, three seconds on
    ok(JC.claimOf(NET) ~= nil and #rpcsFor(CAR, false) == 1 and JC.stats().queued == 0,
       'and the watch is over: no unfreeze under a pour that holds the car',
       #rpcsFor(CAR, false))
    ok(JC.stats().frozenAfterRelease == 1, 'nor its freeze counted as one that stuck')
    -- ITS OWN RELEASE STARTS THE WATCH OVER.
    roster[1].state = BR.PlayerState.DBNO
    tick()
    ok(JC.claimOf(NET) == nil and #rpcsFor(CAR, false) == 2 and JC.stats().queued == 1,
       'the new pour released: its own unfreeze, and its own watch')
    for _ = 1, 6 do tick() end
    ok(#rpcsFor(CAR, false) == 3 and JC.stats().frozenAfterRelease == 2,
       'which, the car still frozen past the lag, sends it again and counts that release too',
       #rpcsFor(CAR, false))

    -- WHOEVER OWNS IT: a new owner is sent the unfreeze on the pass it is seen,
    -- not a second and a half later, and then once every second and a half,
    -- as any owner is -- never on every pass, which a watch that noted when it
    -- last sent but not to whom would do: a mutant this block let pass until
    -- #217's third review. While nobody owns the car nothing is sent to pile
    -- up for the next; and the next is sent it the pass they come.
    heldThenDropped()
    for _ = 1, 6 do tick() end           -- the first look
    local off = rpcsFor(CAR, false)
    ok(#off == 1 and off[1].owner == 2, 'the first look sends it to the owner', #off)
    W.owner[CAR] = 5
    tick()
    off = rpcsFor(CAR, false)
    ok(#off == 2 and off[2].owner == 5, 'a new owner: sent it on the next pass', #off)
    for _ = 1, 5 do tick() end           -- 1,250 ms after that send
    ok(#rpcsFor(CAR, false) == 2, 'and not again inside a second and a half of it',
       #rpcsFor(CAR, false))
    tick()
    off = rpcsFor(CAR, false)
    ok(#off == 3 and off[3].owner == 5, 'but again at a second and a half, to the same owner', #off)
    W.owner[CAR] = -1
    for _ = 1, 12 do tick() end
    ok(#rpcsFor(CAR, false) == 3, 'nobody owning it: three seconds with nothing sent',
       #rpcsFor(CAR, false))
    W.owner[CAR] = 7
    tick()
    off = rpcsFor(CAR, false)
    ok(#off == 4 and off[4].owner == 7, 'and the next owner is sent it the pass they come', #off)
    -- THE CAR GONE: nothing left to unfreeze, and nothing left to watch.
    W.exists[CAR] = nil
    for _ = 1, 8 do tick() end
    ok(#rpcsFor(CAR, false) == 4 and JC.stats().queued == 0, 'a car that is gone ends its watch')
end

-- ═══════════════════════════════════════════════════════════════════════════
-- H. THE CANCEL MATRIX
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Every way a pour ends early, each from a pour one second in (375 m poured,
-- the car held): the ledger keeps what poured, the can holds exactly what did
-- not, the claim is gone within a pass, FUEL_CAN's end and the unfreeze go
-- out -- and the player is told nothing, but for an enemy's hit, which says
-- the 'Interrupted.' every interrupted channel says.
do
    --- @param name string
    --- @param key string  the reason the release is counted under
    --- @param trigger fun(): table|nil  does it; may answer { stack = <where the can is now> }
    --- @param opts table|nil  { at, model, says, noLedger, noUnfreeze, now }
    local function route(name, key, trigger, opts)
        opts = opts or {}
        describe('H. the cancel matrix: ' .. name)
        local slot = scene({ at = opts.at, model = opts.model })
        local left0 = BR.Fuel.left(NET)
        press(1, slot, NET)
        for _ = 1, 4 do tick() end
        local pour = JC.claimOf(NET)
        ok(pour ~= nil and pour.hold and near(pour.poured, 375, 1e-9),
           'one second in: 375 m poured and the car held', pour and pour.poured)
        local s = inv(1).slots[slot]
        sent, rpcs, notices = {}, {}, {}
        local got = trigger(s) or {}
        if not opts.now then tick() end
        ok(JC.claimOf(NET) == nil, 'the claim is released within one pass')
        -- SILENT: a cancel says nothing to the player, as a refusal does (D),
        -- and the hit's one line goes to them alone.
        if opts.says then
            ok(#notices == 1 and notices[1].text == opts.says and notices[1].target == 1,
               ('with the ordinary \'%s\', to the pourer'):format(opts.says), notices[1] and notices[1].text)
        else
            ok(#notices == 0, 'and not a word to the player', notices[1] and notices[1].text)
        end
        local st = JC.stats()
        ok((st.cancels[key] or 0) == 1 and st.canceled == 1 and st.completions == 0,
           ('as a cancel, `%s`'):format(key), next(st.cancels))
        local stack = got.stack or s
        ok(near(JS.fillOf(stack), 1 - 375 / 1875, 1e-9),
           'the can holds exactly what it did not pour: 0.8', JS.fillOf(stack))
        if not opts.noLedger then
            ok(near(BR.Fuel.left(NET), left0 + 375, 1e-9), 'and the ledger keeps the 375 m',
               BR.Fuel.left(NET) - left0)
        end
        local ends = 0
        for _, p in ipairs(events(BR.Net.FUEL_CAN)) do
            if p.ms == 0 and p.n == NET then ends = ends + 1 end
        end
        ok(ends >= 1, 'FUEL_CAN end goes to the match')
        if opts.noUnfreeze then
            ok(#rpcsFor(CAR, false) == 0, 'and no unfreeze for a car that no longer exists')
        else
            ok(#rpcsFor(CAR, false) >= 1, 'and the unfreeze RPC goes out')
        end
        ok(#rpcsFor(CAR, true) == 0, 'and nothing freezes it again')
        return stack
    end

    route('an enemy\'s hit', 'reconcile', function()
        roster[1].hp = 80
        BR.Inv.struck(1, 9, 20)
    end, { says = 'Interrupted.' })

    route('downed', 'reconcile', function() roster[1].state = BR.PlayerState.DBNO end)
    ok(inv(1).slots[1] and inv(1).slots[1].item == CAN.id, 'the can stays in the downed player\'s bag')

    route('killed: the death box', 'reconcile', function()
        BR.Loot.deathBox(matches[MATCH], 1)
        roster[1].state = BR.PlayerState.OUT
        local where, st = findCan()
        ok(where == 'ground', 'the can is on the ground, in the death box\'s ring')
        return { stack = st }
    end)

    route('Leave Match', 'reconcile', function()
        BR.Loot.deathBox(matches[MATCH], 1)
        roster[1].state, roster[1].matchId = BR.PlayerState.LOBBY, nil
        local _, st = findCan()
        return { stack = st }
    end)

    route('a squadmate\'s Field medic', 'reconcile', function()
        BR.Inv.grantEffect(1, { health = 100, healthCap = 100 })
    end)

    -- ...AND A NEW CHANNEL OPENED BEFORE THE NEXT PASS: Field medic ends the
    -- pour between two passes, and the player starts a bandage straight away.
    -- The reconcile job must see that the channel standing now is not the
    -- pour's, not merely that some channel stands.
    route('Field medic, then a bandage before the next pass', 'reconcile', function()
        BR.Inv.grantEffect(1, { health = 100, healthCap = 100 })
        BR.Inv.give(1, { item = 'bandage', kind = BR.ItemKind.CONSUMABLE,
                         rarity = BR.Rarity.COMMON, count = 1 })
        roster[1].hp = 40
        roster[1].healUntil, roster[1].grantHpTo = nil, nil
        local b
        for i = 1, 5 do
            local s2 = inv(1).slots[i]
            if s2 and s2.item == 'bandage' then b = i end
        end
        press(1, b)
        ok(inv(1).using and inv(1).using.item == 'bandage' and inv(1).using.pour == nil,
           'a bandage\'s channel stands where the pour\'s did')
    end)

    route('the pourer moves 0.8 m', 'moved', function()
        place(1, roster[1].pos.x, roster[1].pos.y - 0.8)
    end)

    route('the pourer gets in', 'seated', function() seat(1, CAR, 0) end)

    -- ...AT THE BACK OF A BUS: seat 12, past the cabin's eight. The first build
    -- poured on, and held the bus, with its pourer sitting in it.
    route('the pourer sits at the back of a bus', 'seated', function() seat(1, CAR, 12) end,
          { model = 'bus' })

    route('the pourer steps outside the box', 'away', function()
        place(1, roster[1].pos.x - 0.2, roster[1].pos.y)
    end, { at = { lx = -(1.1 + J.boxMargin) + 0.1, ly = -2.0 } })

    route('the car is pushed 1.1 m', 'moving', function() moveCar(CAR, V.x + 1.1, V.y) end)

    route('the car rolls at 0.6 m/s', 'moving', function() W.speed[CAR] = 0.6 end)

    route('the network id names another car', 'gone', function()
        W.exists[777], W.etype[777], W.bucket[777] = true, 2, BUCKET
        W.coords[777] = { x = V.x, y = V.y, z = V.z }
        W.entOf[NET] = 777
    end)

    route('the car is gone', 'gone', function() W.exists[CAR] = nil end, { noUnfreeze = true })

    route('another bucket', 'bucket', function() W.bucket[CAR] = OTHER_BUCKET end)

    route('its ledger row is swept', 'untracked', function()
        local ttl = F.idleTtlMs
        F.idleTtlMs = 1
        fakeTime = fakeTime + 10
        job('fuel.sweep')()
        F.idleTtlMs = ttl
        ok(BR.Fuel.space(NET, MATCH) == nil, 'the row is gone')
    end, { noLedger = true })

    route('the season is switched off', 'season', function() season(1) end)
    season(2)

    route('a disconnect', 'dropped', function()
        fire('playerDropped', '1')
    end, { now = true })

    route('the match is torn down', 'destroyed', function()
        fire('br:match:destroyed', nil, { matchId = MATCH })
    end, { now = true, noLedger = true })
    tick()
    ok(inv(1).using == nil, 'and the channel closes on the next pass')
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('I. conservation: no sequence gets more than one can out of a can')
-- ═══════════════════════════════════════════════════════════════════════════
do
    local CAR2, NET2 = 510, 910
    local V2 = { x = 1100.0, y = 1000.0 }
    local PER = { [NET] = 1875, [NET2] = 7500 }
    local delivered = 0
    local realPour = BR.Fuel.pour
    BR.Fuel.pour = function(n, m, x)
        local a = realPour(n, m, x)
        delivered = delivered + a / PER[n]
        return a
    end

    local rng = BR.Rng(21717)
    local worst, steps, broken = 0, 0, nil
    local seen = { pours = 0, cut = 0, emptied = 0, drives = 0, pumps = 0, handoffs = 0, boxes = 0 }

    local function check(where)
        local w, st, who = findCan()
        local fill = w and JS.fillOf(st) or 0
        local err = math.abs(delivered + fill - 1)
        if err > worst then worst = err end
        if err > 1e-9 or fill < 0 or fill > 1 then
            broken = broken or ('%s: delivered %.12f + fill %.12f'):format(where, delivered, fill)
        end
        steps = steps + 1
        return w, st, who
    end

    local function holderOf()
        for _, src in ipairs({ 1, 2 }) do
            local e = roster[src]
            for i = 1, 5 do
                local s = e.inv and e.inv.slots[i]
                if s and s.item == CAN.id then return src, i end
            end
        end
        return nil
    end

    for _ = 1, 60 do
        scene({ burn = 0 })
        vehicle(CAR2, NET2, 'sanchez', V2.x, V2.y, 0.0)
        player(7, MATCH, nil, V.x - 20, V.y, V.z)
        drain(CAR, rng:int(0, 300) * 25.0, 7)
        drain(CAR2, rng:int(0, 300) * 25.0, 7)
        delivered = 0
        check('start')

        for _ = 1, rng:int(4, 12) do
            local op = rng:int(1, 6)
            local src, slot = holderOf()
            local cars = { { CAR, NET, V }, { CAR2, NET2, V2 } }
            local car = cars[rng:int(1, 2)]
            if op <= 3 and src then
                -- A POUR, CUT SHORT OR NOT.
                fire(BR.Net.INV_SELECT, src, { slot = slot })
                place(src, worldOf(car[3].x, car[3].y, 0, -0.5, -1.0))
                press(src, slot, car[2])
                if roster[src].inv and roster[src].inv.using then seen.pours = seen.pours + 1 end
                for _ = 1, rng:int(0, 25) do
                    if not (roster[src].inv and roster[src].inv.using) then break end
                    tick()
                end
                local how = rng:int(1, 6)
                if roster[src].inv and roster[src].inv.using then
                    if how <= 4 then seen.cut = seen.cut + 1 end
                    if how == 1 then
                        place(src, roster[src].pos.x + 1.0, roster[src].pos.y)
                    elseif how == 2 then
                        roster[src].hp = 70
                        BR.Inv.struck(src, 9, 30)
                    elseif how == 3 then
                        roster[src].state = BR.PlayerState.DBNO
                    elseif how == 4 then
                        moveCar(car[1], car[3].x + 1.5, car[3].y)
                    end
                    for _ = 1, 30 do
                        if not (roster[src].inv and roster[src].inv.using) then break end
                        tick()
                    end
                end
                roster[src].state, roster[src].hp = BR.PlayerState.ALIVE, 100
                moveCar(car[1], car[3].x, car[3].y)
                tick()
                check('pour')
            elseif op == 4 then
                -- DRIVE IT DOWN, OR PUMP IT UP, BETWEEN POURS.
                if rng:int(1, 2) == 1 then
                    seen.drives = seen.drives + 1
                    drain(car[1], rng:int(1, 40) * 25.0, 7)
                else
                    seen.pumps = seen.pumps + 1
                    local S = F.stations[1]
                    moveCar(car[1], S.x, S.y)
                    seat(7, car[1], -1)
                    tick(0)
                    for _ = 1, rng:int(1, 8) do
                        fakeTime = fakeTime + 1
                        fire(BR.Net.FUEL_PUMP, 7, { n = car[2] })
                        tick(249)
                    end
                    unseat(7, car[1])
                    tick()
                    moveCar(car[1], car[3].x, car[3].y)
                end
                check('drive or pump')
            elseif op == 5 and src then
                -- PUT DOWN, AND PICKED UP BY THE OTHER.
                local other = src == 1 and 2 or 1
                fire(BR.Net.INV_DROP, src, { slot = slot })
                local w, st = check('dropped')
                if w == 'ground' then
                    place(other, st.x, st.y, st.z)
                    fakeTime = fakeTime + 1100
                    fire(BR.Net.LOOT_CLAIM, other, { id = st.id })
                end
                local _, _, by = check('picked up')
                if by == other then seen.handoffs = seen.handoffs + 1 end
            elseif op == 6 and src then
                -- KILLED: THE DEATH BOX, AND THE OTHER TAKES IT.
                local other = src == 1 and 2 or 1
                BR.Loot.deathBox(matches[MATCH], src)
                tick()
                local w, st = check('death box')
                if w == 'ground' then
                    place(other, st.x, st.y, st.z)
                    fakeTime = fakeTime + 1100
                    fire(BR.Net.LOOT_CLAIM, other, { id = st.id })
                end
                local _, _, by = check('taken from the box')
                if by == other then seen.boxes = seen.boxes + 1 end
            end
            if findCan() == nil then
                seen.emptied = seen.emptied + 1
                break
            end
        end
    end
    BR.Fuel.pour = realPour
    ok(broken == nil, ('delivered cans plus the fill left is one can, over %d checks (worst %.1e)')
        :format(steps, worst), broken)
    ok(steps > 300, 'and the sequences really ran', steps)
    local missing = {}
    for k, v in pairs(seen) do if v == 0 then missing[#missing + 1] = k end end
    table.sort(missing)
    ok(#missing == 0, ('every road was walked: %d pours (%d cut short), %d cans emptied, %d drives, '
        .. '%d pumps, %d hand-offs, %d death boxes'):format(seen.pours, seen.cut, seen.emptied,
        seen.drives, seen.pumps, seen.handoffs, seen.boxes), table.concat(missing, ', '))
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('J. the griefer bound')
-- ═══════════════════════════════════════════════════════════════════════════
do
    --- Frozen milliseconds, read off the RPC log for the car: from each freeze
    --- to the unfreeze after it.
    local function frozenMs()
        local total, since = 0, nil
        for _, r in ipairs(rpcs) do
            if r.ent == CAR then
                if r.on and since == nil then since = r.at
                elseif not r.on and since ~= nil then
                    total = total + (r.at - since)
                    since = nil
                end
            end
        end
        if since then total = total + (fakeTime - since) end
        return total
    end

    local rng = BR.Rng(3)
    local slot = scene({ burn = 7500 })
    seat(2, CAR, -1)   -- somebody is sitting in the car being griefed
    tick(0)
    local presses, paidMs = 0, 0
    local home = { x = roster[1].pos.x, y = roster[1].pos.y }
    rpcs = {}
    for _ = 1, 25 do
        if not inv(1).slots[slot] then break end
        place(1, home.x, home.y)
        press(1, slot, NET)
        if inv(1).using then
            presses = presses + 1
            local pour = inv(1).using.pour
            for _ = 1, rng:int(1, 3) do tick() end
            place(1, home.x, home.y + 1.0)
            tick()
            paidMs = paidMs + pour.poured / pour.perCan * CAN.useMs
        end
    end
    ok(presses >= 8, 'eight and more presses, each cut short', presses)
    local fz = frozenMs()
    ok(fz <= paidMs + 250 * presses,
       ('the car was frozen %d ms against %.0f ms of fuel paid for, plus a pass a press')
           :format(fz, paidMs), fz)
    ok(fz > 0, 'and it was frozen at all')

    -- A CANCEL INSIDE THE SETTLE WINDOW FREEZES NOTHING AND SENDS NOTHING: not
    -- at the press, and not at its end.
    slot = scene()
    press(1, slot, NET)
    place(1, roster[1].pos.x, roster[1].pos.y + 1.0)
    tick(100)
    ok(JC.claimOf(NET) == nil, 'a pour cut short in its first 250 ms is released')
    ok(#rpcs == 0, 'having frozen nothing, and sent no unfreeze either', #rpcs)
    ok(#events(BR.Net.FUEL_CAN) == 0, 'and told the match nothing: no hold, no start, no end',
       #events(BR.Net.FUEL_CAN))
    ok(BR.Fuel.stats().pours == 0, 'and poured nothing')

    -- ...AND AGAIN AND AGAIN: a modified client stepping off after every press,
    -- the cycle that cost nothing. The first build sent every match member a
    -- start and an end for each, and the car an unfreeze: free messages to the
    -- whole match, and a can made and taken down on every hand there, four
    -- times a second.
    slot = scene()
    local at = { x = roster[1].pos.x, y = roster[1].pos.y }
    for _ = 1, 40 do
        place(1, at.x, at.y)
        press(1, slot, NET)
        place(1, at.x, at.y + 0.8)
        tick()
    end
    ok(JC.stats().starts == 40 and JC.stats().canceled == 40,
       'forty presses taken, each cut short on its first pass', JC.stats().starts)
    ok(#events(BR.Net.FUEL_CAN) == 0 and #rpcs == 0,
       'and not one message to the match, nor one RPC', ('%d, %d'):format(#events(BR.Net.FUEL_CAN), #rpcs))
    ok(fillAt(1, slot) == nil and BR.Fuel.stats().pours == 0, 'the can and the tank untouched')

    -- A POUR DONE ON ITS FIRST SLICE never held, so it sends no FUEL_CAN either
    -- -- only the start cue that slice paid for, to the pourer and whoever rides
    -- in the car: a sliver of room, 60 m, poured whole in its one 250 ms pass.
    slot = scene({ burn = 60 })
    seat(2, CAR, -1)
    tick(0)
    sent = {}
    press(1, slot, NET)
    ok(inv(1).using and inv(1).using.ms == 250, 'a 60 m pour is one pass long')
    tick()
    ok(inv(1).using == nil and JC.stats().completions == 1, 'and done on its first slice')
    ok(BR.Fuel.stats().pours == 1 and near(BR.Fuel.left(NET), TANK, 1e-6), 'the tank full')
    ok(#events(BR.Net.FUEL_CAN) == 0 and #rpcs == 0, 'no hold was sent, so no end and no unfreeze')
    local cued = targets(BR.Net.FUEL_SFX, function(p) return p.c == 'fuel.start' and p.n == NET end)
    ok(cued[1] == 1 and cued[2] == 1 and cued[3] == nil and cued[4] == nil and cued[9] == nil,
       'only the start cue it paid for: to the pourer and the driver, once each, and nobody else')
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('K. transfers and the wire')
-- ═══════════════════════════════════════════════════════════════════════════
do
    -- PUT DOWN: THE WORLD ENTRY CARRIES THE FILL, AND THE WIRE DOES NOT.
    local slot = scene({ fill = 0.6, noHand = true })
    sent = {}
    fire(BR.Net.INV_DROP, 1, { slot = slot })
    local w, st = findCan()
    ok(w == 'ground' and st.fill == 0.6, 'INV_DROP\'s world entry carries the fill', st and st.fill)
    local wire = nil
    for _, p in ipairs(events(BR.Net.LOOT_ADD)) do
        for _, en in ipairs(p) do if en.id == st.id then wire = en end end
    end
    ok(wire ~= nil and wire.fill == nil, 'and LOOT_ADD\'s entry does not')

    -- PICKED UP INTO A NEW SLOT.
    place(2, st.x, st.y, st.z)
    fire(BR.Net.LOOT_CLAIM, 2, { id = st.id })
    local w2, st2, src2 = findCan()
    ok(w2 == 'slot' and src2 == 2 and st2.fill == 0.6, 'a pickup puts it in a new slot, fill and all')

    -- ...AND INTO A SWAP, WITH A FULL BAG.
    slot = scene({ fill = 0.6, noHand = true })
    fire(BR.Net.INV_DROP, 1, { slot = slot })
    w, st = findCan()
    for _, g in ipairs({ 'pistol', 'smg', 'pumpshotgun', 'carbinerifle', 'microsmg' }) do
        BR.Inv.give(2, { item = g, kind = BR.ItemKind.WEAPON, rarity = BR.Rarity.COMMON, count = 1 })
    end
    fire(BR.Net.INV_SELECT, 2, { slot = 2 })
    place(2, st.x, st.y, st.z)
    fakeTime = fakeTime + 1100
    fire(BR.Net.LOOT_CLAIM, 2, { id = st.id })
    ok(inv(2).slots[2] and inv(2).slots[2].item == CAN.id and inv(2).slots[2].fill == 0.6,
       'a pickup into a full bag swaps the hand for it, fill and all')

    -- THE DEATH BOX.
    slot = scene({ fill = 0.45 })
    BR.Loot.deathBox(matches[MATCH], 1)
    w, st = findCan()
    ok(w == 'ground' and st.fill == 0.45, 'the death box carries it', st and st.fill)

    -- A SECOND CAN IS REFUSED BY THE CARRY LIMIT'S OWN SENTENCE.
    slot = scene()
    local e = BR.Loot.spawnStack(matches[MATCH], { item = CAN.id, kind = BR.ItemKind.CONSUMABLE,
        rarity = CAN.rarity, count = 1, fill = 1 }, roster[1].pos.x, roster[1].pos.y, V.z)
    notices = {}
    fakeTime = fakeTime + 1100
    fire(BR.Net.LOOT_CLAIM, 1, { id = e.id })
    ok(notices[1] and notices[1].text == 'You cannot carry more than 1 Jerry Cans.',
       'a second can: "You cannot carry more than 1 Jerry Cans."', notices[1] and notices[1].text)
    ok(matches[MATCH].loot.items[e.id] ~= nil, 'and it stays on the ground')

    -- CANS NEVER STACK, WHATEVER maxStack SAYS.
    scene({ noCan = true })
    CAN.maxStack, CAN.carryMax = 3, 3
    BR.Inv.give(1, { item = CAN.id, kind = BR.ItemKind.CONSUMABLE, rarity = CAN.rarity, count = 1, fill = 0.5 })
    BR.Inv.give(1, { item = CAN.id, kind = BR.ItemKind.CONSUMABLE, rarity = CAN.rarity, count = 1, fill = 0.9 })
    CAN.maxStack, CAN.carryMax = 1, 1
    local a, b = inv(1).slots[1], inv(1).slots[2]
    ok(a and b and a.item == CAN.id and b.item == CAN.id and a.count == 1 and b.count == 1
       and a.fill == 0.5 and b.fill == 0.9, 'two cans are two slots, each with its own fill')

    -- THE WIRE: A FILL ON A CAN AND ON NOTHING ELSE.
    scene({ noCan = true })
    BR.Inv.give(1, { item = CAN.id, kind = BR.ItemKind.CONSUMABLE, rarity = CAN.rarity, count = 1, fill = 0.12345 })
    local p = BR.Inv.publicFor(1)
    ok(p.slots[1].fill == 0.123, 'publicFor rounds the fill to a thousandth', p.slots[1].fill)
    scene({ noCan = true })
    BR.Inv.give(1, { item = CAN.id, kind = BR.ItemKind.CONSUMABLE, rarity = CAN.rarity, count = 1 })
    BR.Inv.give(1, { item = 'medkit', kind = BR.ItemKind.CONSUMABLE, rarity = BR.Rarity.UNCOMMON, count = 1 })
    BR.Inv.give(1, { item = 'pistol', kind = BR.ItemKind.WEAPON, rarity = BR.Rarity.COMMON, count = 1 })
    p = BR.Inv.publicFor(1)
    ok(p.slots[1].fill == 1, 'a can a dev verb gave, with no fill, is sent as 1')
    ok(p.slots[2].fill == nil and p.slots[3].fill == nil, 'and no other slot has the field')

    -- A CAN STILL IN THE BAG IS NEVER SENT AS EMPTY. The server keeps a can
    -- down to a millionth, so a sliver under half a thousandth would round to
    -- 0 on the wire -- a plate saying empty over a can that still takes the one
    -- place a player may carry one. At least a thousandth, then; 0 only for a
    -- can the server itself calls empty.
    scene({ noCan = true })
    BR.Inv.give(1, { item = CAN.id, kind = BR.ItemKind.CONSUMABLE, rarity = CAN.rarity, count = 1, fill = 0.0003 })
    p = BR.Inv.publicFor(1)
    ok(p.slots[1].fill == 0.001, 'a can with 0.0003 left is sent as 0.001, not 0', p.slots[1].fill)
    inv(1).slots[1].fill = 1e-7
    p = BR.Inv.publicFor(1)
    ok(p.slots[1].fill == 0, 'and only one at or under a millionth as 0', p.slots[1].fill)
    -- ...AS A POUR LEAVES IT: 0.6 of a can into a car with 1,124.5 m of room --
    -- the can's 1,125 m less half a meter -- keeps 0.00027 of it.
    slot = scene({ fill = 0.6, burn = 1124.5 })
    press(1, slot, NET)
    for _ = 1, 20 do
        if inv(1).using == nil then break end
        tick()
    end
    ok(inv(1).using == nil and near(BR.Fuel.left(NET), TANK, 1e-6), 'the car is filled')
    local kept = inv(1).slots[slot]
    ok(kept and kept.item == CAN.id and near(kept.fill, 0.6 - 1124.5 / 1875, 1e-9),
       'and the can stays, with the sliver the tank had no room for', kept and kept.fill)
    local pushed = events(BR.Net.INV_SET, 1)
    local last = pushed[#pushed] and pushed[#pushed].slots[slot]
    ok(last and last.fill == 0.001, 'which its plate is sent as a thousandth', last and last.fill)

    -- THE SPECTATOR'S FEED NOTICES A POUR'S END: server/spectate.lua's own
    -- invSig, lifted out of the file and RUN, over two of publicFor's payloads
    -- that differ in nothing but a can's fill. (A pin on its text was passed by
    -- a format string that dropped the fill and kept the argument.)
    local spec = readFile(ROOT .. 'br_core/server/spectate.lua') or ''
    local fnSrc = spec:match('(local function invSig%(p%).-\nend)\n')
    -- _G.load: this file's own `load` reads a file off the disk.
    local lifted = fnSrc and _G.load(fnSrc .. '\nreturn invSig', '=invSig', 't', _G)
    local invSig = lifted and lifted()
    ok(type(invSig) == 'function', 'server/spectate.lua\'s invSig is found, and loads on its own')
    scene({ noCan = true })
    BR.Inv.give(1, { item = CAN.id, kind = BR.ItemKind.CONSUMABLE, rarity = CAN.rarity, count = 1, fill = 0.6 })
    local before = BR.Inv.publicFor(1)
    inv(1).slots[1].fill = 0.4
    local after = BR.Inv.publicFor(1)
    ok(invSig and invSig(before) ~= invSig(after),
       'a pour\'s end, which moves nothing but the fill, changes the signature')
    ok(invSig and invSig(after) == invSig(BR.Inv.publicFor(1)),
       'and the same bag signs the same, so the dedupe still holds')

    -- ...AND A POUR SIGNS ONE CHANGE, NOT ONE A SLICE. The feed runs that
    -- signature over publicFor four times a second, and a fill that moved with
    -- the slices sent a spectator watching a pourer the whole bag on every
    -- pass of the pour, while the pourer's own plate moved once (#217's second
    -- review). While a pour runs, every push carries the fill it started from;
    -- its end carries what is left.
    slot = scene({ burn = 750 })
    local sig, changes, during, pushed = invSig(BR.Inv.publicFor(1)), 0, {}, nil
    press(1, slot, NET)
    for i = 1, 12 do
        tick()
        local p = BR.Inv.publicFor(1)
        if inv(1).using ~= nil then during[#during + 1] = p.slots[slot].fill end
        if i == 3 then
            sent = {}
            BR.Inv.push(1)
            local set = events(BR.Net.INV_SET, 1)
            pushed = set[#set] and set[#set].slots[slot] and set[#set].slots[slot].fill
        end
        local now = invSig and invSig(p) or ''
        if now ~= sig then changes, sig = changes + 1, now end
    end
    ok(inv(1).using == nil and near(fillAt(1, slot), 0.6, 1e-9),
       'a pour into a car at 90%: done, with 0.6 left in the can', fillAt(1, slot))
    ok(changes == 1, 'and the spectator\'s signature changed once over the whole pour, at its end', changes)
    local still = #during >= 6
    for _, f in ipairs(during) do still = still and f == 1 end
    ok(still, 'every pass of it carried the fill it started from', table.concat(during, ','))
    ok(pushed == 1, 'and so did a push to the pourer in the middle of it', tostring(pushed))
    ok(BR.Inv.publicFor(1).slots[slot].fill == 0.6, 'the end carries what is left')
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('L. loot')
-- ═══════════════════════════════════════════════════════════════════════════
do
    local rolls = 0
    local realRoll = JS.crateRoll
    JS.crateRoll = function(...)
        rolls = rolls + 1
        return realRoll(...)
    end

    --- One crate, opened by player 1: the items that burst out, in order.
    local function spill(seasonN, keyChance, canChance, container)
        scene({ noCan = true, burn = 0, season = seasonN })
        local wasKey, wasCan = CT.sources.crateChance, J.crateChance
        CT.sources.crateChance, J.crateChance = keyChance, canChance
        local m = matches[MATCH]
        local stack = container or {
            item = 'chest', kind = 'chest', rarity = BR.Rarity.COMMON, count = 1, prop = 'x',
            contents = {
                { item = 'pistol', kind = BR.ItemKind.WEAPON, rarity = BR.Rarity.COMMON, count = 1, clip = 12 },
                { item = 'bandage', kind = BR.ItemKind.CONSUMABLE, rarity = BR.Rarity.COMMON, count = 2 },
                { item = BR.AmmoType.LIGHT, kind = BR.ItemKind.AMMO, rarity = BR.Rarity.COMMON, count = 36 },
            },
        }
        local crate = BR.Loot.spawnStack(m, stack, roster[1].pos.x + 0.5, roster[1].pos.y, V.z)
        sent = {}
        fakeTime = fakeTime + 1100
        fire(BR.Net.LOOT_CLAIM, 1, { id = crate.id })
        CT.sources.crateChance, J.crateChance = wasKey, wasCan
        local items, cans = {}, {}
        for _, s in ipairs(events(BR.Net.LOOT_ADD, 1)) do
            for _, w in ipairs(s) do
                if w.kind ~= 'husk' and w.id ~= crate.id then
                    items[#items + 1] = w.item
                    if w.item == CAN.id then cans[#cans + 1] = m.loot.items[w.id] end
                end
            end
        end
        return items, cans, crate
    end

    rolls = 0
    local s1 = spill(1, 1, 1)
    ok(table.concat(s1, ',') == 'pistol,bandage,' .. BR.AmmoType.LIGHT,
       'Season 1: the crate spills exactly what it held, in order', table.concat(s1, ','))
    ok(rolls == 0 and JC.stats().crateRolls == 0, 'and the can\'s roll is never asked')
    local s2, cans = spill(2, 1, 1)
    ok(table.concat(s2, ',') == table.concat(s1, ',') .. ',yubikey,jerrycan',
       'Season 2, both chances at 1: Season 1\'s items, then the key, then the can',
       table.concat(s2, ','))
    ok(cans[1] and cans[1].fill == 1 and cans[1].rarity == BR.Rarity.RARE and cans[1].count == 1,
       'a full can, rare')
    local s3 = spill(2, 1, 0)
    ok(table.concat(s3, ',') == table.concat(s1, ',') .. ',yubikey',
       'with the can\'s chance at 0, Season 2 is Season 1 plus the key')
    local s4 = spill(2, 0, 1)
    ok(s4[#s4] == 'jerrycan' and #s4 == #s1 + 1, 'and with the key\'s at 0, plus the can alone')

    -- WHAT NEVER ROLLS: THE WARMUP PAD, THE AIRDROP AND A DEATH BOX.
    scene({ noCan = true, burn = 0 })
    local m = matches[MATCH]
    J.crateChance = 1
    rolls = 0
    ok(JC.extraFor(m, { kind = 'chest', id = 1, warmup = true }) == nil, 'not a warmup crate')
    m.warmup = true
    ok(JC.extraFor(m, { kind = 'chest', id = 2 }) == nil, 'nor anything in the pad\'s zone')
    m.warmup = nil
    ok(JC.extraFor(m, { kind = 'chest', id = 3, airdrop = 1 }) == nil, 'nor the airdrop')
    ok(JC.extraFor(m, { kind = 'deathbox', id = 4 }) == nil, 'nor a death box')
    ok(rolls == 0, 'and none of them so much as rolled')
    ok(JC.extraFor(m, { kind = 'chest', id = 5 }) ~= nil, 'a match crate does')
    J.crateChance = 0.02
    local _, cans2 = spill(2, 0, 1, {
        item = 'airdrop', kind = 'chest', rarity = BR.Rarity.LEGENDARY, count = 1, prop = 'x',
        contents = { { item = 'volts', kind = 'volts', rarity = BR.Rarity.LEGENDARY, count = 500 } },
        airdrop = 3,
    })
    ok(#cans2 == 0, 'the airdrop, opened for real, holds no can')

    -- A GENERATED LAYOUT HOLDS NONE.
    local layout = BR.BuildLootLayout(4242)
    local inLayout = 0
    for _, en in ipairs(layout) do
        if en.item == CAN.id then inLayout = inLayout + 1 end
        for _, c in ipairs(en.contents or {}) do
            if c.item == CAN.id then inLayout = inLayout + 1 end
        end
    end
    ok(inLayout == 0 and #layout > 1000, 'BR.BuildLootLayout never holds a can', inLayout)

    -- THE CRATE STILL SHOWS WHAT IT SHOWED.
    local _, cans3, crate = spill(2, 0, 1)
    ok(cans3[1] ~= nil, 'a common crate certain to hold a can')
    ok(crate.sealedRarity == BR.Rarity.COMMON, 'remembers common: the can does not tint it',
       crate.sealedRarity)

    JS.crateRoll = realRoll
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('M. no repair')
-- ═══════════════════════════════════════════════════════════════════════════
do
    local slot = scene()
    seat(2, CAR, -1)   -- an occupant, so the ledger pushes to somebody
    tick(0)
    sent = {}
    press(1, slot, NET)
    for _ = 1, 30 do tick() end
    tick(2500)
    local sets, withR = 0, 0
    for _, p in ipairs(events(BR.Net.FUEL_SET)) do
        sets = sets + 1
        if p.r ~= nil then withR = withR + 1 end
    end
    ok(sets > 0, 'the occupant was sent the rising tank', sets)
    ok(withR == 0, 'and no FUEL_SET during or after the pour carries `r`')
    ok(#events(BR.Net.VEH_FIX) == 0, 'and no VEH_FIX is ever sent')

    -- AND THE SOURCE SAYS SO: one pushTo with a fifth argument, the pump's,
    -- and none at all inside BR.Fuel.pour.
    local src = readFile(ROOT .. 'br_core/server/fuel.lua') or ''
    local code = src:gsub('%-%-[^\n]*', '')
    local fifth = 0
    for args in code:gmatch('pushTo(%b())') do
        local depth, commas = 0, 0
        for ch in args:sub(2, -2):gmatch('.') do
            if ch == '(' or ch == '{' then depth = depth + 1
            elseif ch == ')' or ch == '}' then depth = depth - 1
            elseif ch == ',' and depth == 0 then commas = commas + 1 end
        end
        if commas >= 4 then fifth = fifth + 1 end
    end
    ok(fifth == 2, 'pushTo carries a fifth argument in two places: its own definition and the pump', fifth)
    ok(code:find('pushTo(src, netId, rec.left, true, repair)', 1, true) ~= nil,
       'and the one call is the pump\'s grant')
    local body = code:match('function BR%.Fuel%.pour%(.-\nend\n') or ''
    ok(#body > 100, 'BR.Fuel.pour\'s body is found')
    ok(body:find('pushTo', 1, true) == nil and body:find('TriggerClientEvent', 1, true) == nil,
       'and it calls no pushTo and sends nothing')
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('N. regressions')
-- ═══════════════════════════════════════════════════════════════════════════
do
    -- THE REPAIR KIT IGNORES AN `n`: the server still names the car.
    scene({ noCan = true })
    vehicle(501, 901, 'zentorno', V.x + 30, V.y, 0)
    seat(1, CAR, -1)
    BR.Inv.give(1, { item = 'repairkit', kind = BR.ItemKind.CONSUMABLE, rarity = BR.Rarity.LEGENDARY, count = 1 })
    press(1, 1, 901)
    ok(inv(1).using and inv(1).using.veh == NET, 'the kit is aimed at the car they drive, not `n`',
       inv(1).using and inv(1).using.veh)
    ok(inv(1).using and inv(1).using.pour == nil and JC.claimOf(901) == nil, 'and no pour is opened')
    ok(#events(BR.Net.FUEL_CAN) == 0, 'and no FUEL_CAN')

    -- ...AND ITS SEAT RULE STILL SPENDS IT.
    tick()
    unseat(1, CAR)
    tick()
    ok(inv(1).using == nil and inv(1).slots[1] == false, 'out of the seat mid-repair: the kit is spent (#361)')

    -- A MED KIT'S COMPLETION STILL SPENDS ONE.
    scene({ noCan = true })
    BR.Inv.give(1, { item = 'medkit', kind = BR.ItemKind.CONSUMABLE, rarity = BR.Rarity.UNCOMMON, count = 2 })
    roster[1].hp = 40
    press(1, 1)
    for _ = 1, 40 do tick() end
    ok(inv(1).using == nil and inv(1).slots[1] and inv(1).slots[1].count == 1,
       'a med kit\'s completion spends one', inv(1).slots[1] and inv(1).slots[1].count)
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('O. the icon')
-- ═══════════════════════════════════════════════════════════════════════════
do
    --- SHA-1, for git's blob id: sha1("blob <size>\0" .. bytes).
    local function sha1(msg)
        local h0, h1, h2, h3, h4 = 0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0
        local ml = #msg * 8
        msg = msg .. '\128' .. string.rep('\0', (55 - #msg) % 64) .. string.pack('>I8', ml)
        local function rol(x, n) return ((x << n) | (x >> (32 - n))) & 0xFFFFFFFF end
        for chunk = 1, #msg, 64 do
            local w = {}
            for i = 0, 15 do w[i] = string.unpack('>I4', msg, chunk + i * 4) end
            for i = 16, 79 do w[i] = rol(w[i - 3] ~ w[i - 8] ~ w[i - 14] ~ w[i - 16], 1) end
            local a, b, c, d, e = h0, h1, h2, h3, h4
            for i = 0, 79 do
                local f, k
                if i < 20 then f, k = (b & c) | ((~b) & d), 0x5A827999
                elseif i < 40 then f, k = b ~ c ~ d, 0x6ED9EBA1
                elseif i < 60 then f, k = (b & c) | (b & d) | (c & d), 0x8F1BBCDC
                else f, k = b ~ c ~ d, 0xCA62C1D6 end
                local t = (rol(a, 5) + (f & 0xFFFFFFFF) + e + k + w[i]) & 0xFFFFFFFF
                e, d, c, b, a = d, c, rol(b, 30), a, t
            end
            h0 = (h0 + a) & 0xFFFFFFFF
            h1 = (h1 + b) & 0xFFFFFFFF
            h2 = (h2 + c) & 0xFFFFFFFF
            h3 = (h3 + d) & 0xFFFFFFFF
            h4 = (h4 + e) & 0xFFFFFFFF
        end
        return ('%08x%08x%08x%08x%08x'):format(h0, h1, h2, h3, h4)
    end
    ok(sha1('abc') == 'a9993e364706816aba3e25717850c26c9cd0d89d', 'the SHA-1 here is SHA-1')

    local src = readFile('ui-src/public/items/jerrycan.png')
    local built = readFile(ROOT .. 'br_ui/ui/items/jerrycan.png')
    ok(src ~= nil, 'the source icon is in ui-src/public/items/jerrycan.png')
    ok(built ~= nil, 'and the built one in br_ui/ui/items/jerrycan.png')
    ok(src ~= nil and sha1('blob ' .. #src .. '\0' .. src) == '66317a53ead28471d6f4ee1dc3941b57bc1ee9f5',
       'and it is upstream\'s Jerry Can.png byte for byte (git blob 66317a53...)')
    ok(src ~= nil and built == src, 'and the build copied it unchanged')
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('P. the playtest, by brfueltank')
-- ═══════════════════════════════════════════════════════════════════════════
--
-- docs/running.md's playtest, step for step, on the real files, and with its
-- own numbers -- none of which needs any driving, which is what the command is
-- for. Sit in a car, `brfueltank <id> <percent>`, get out, pour:
--
--   steps 2-6  a car at 10% takes a full can and reads 35%; the can is gone
--   step 7     a car at 90% takes 10%, and the can keeps 0.6
--   step 8     that can into a car at 85.1%: it keeps a sliver, sent as such
--   step 9     a dirt bike at 70% ends full and the can keeps 0.7; one at 0
--              takes a whole full can
--   its words  every press the client never sends named, in the opening and
--              `brjerrycan`'s row, and the reach and the cone's meters the
--              config's -- in steps 3 and 10 and docs/terminology.md's gas cap
do
    local function console(...)
        logs = {}
        commands.brfueltank(0, { ... })
        return table.concat(logs, '\n')
    end
    --- From a seat, `brfueltank 1 <pct>`; out again (the #4006 stale read left
    --- naming the car when `stale`); then the can poured to its end.
    local function setAndPour(slot, pct, stale)
        seat(1, CAR, -1)
        local out = console('1', pct)
        unseat(1, CAR, stale)
        tick()
        press(1, slot, NET)
        for _ = 1, 30 do
            if inv(1).using == nil then break end
            tick()
        end
        return out
    end
    BR.Server.devMode = true

    local slot = scene({ burn = 0 })
    ok(BR.Fuel.space(NET, MATCH) == nil, 'a car nobody has sat in is not in the ledger: a can would be refused')
    local out = setAndPour(slot, '10')
    ok(out:find('750 of 7500 m', 1, true) ~= nil, '`brfueltank 1 10` from its seat: the car at 10%', out)
    ok(near(BR.Fuel.left(NET) / TANK, 0.35, 1e-9), 'a full can poured in from outside it: 10% becomes 35%',
       BR.Fuel.left(NET) / TANK)
    ok(inv(1).slots[slot] == false, 'and the can, empty, leaves the bag')

    slot = scene({ burn = 0 })
    setAndPour(slot, '90')
    ok(BR.Fuel.left(NET) == TANK and near(fillAt(1, slot), 0.6, 1e-9),
       'a car at 90%: 10% goes in, and the can keeps 0.6', fillAt(1, slot))
    setAndPour(slot, '85.1', true)
    ok(BR.Fuel.left(NET) == TANK, 'that can into a car at 85.1%: full', BR.Fuel.left(NET))
    ok(near(fillAt(1, slot), 0.6 - 0.149 * TANK / 1875, 1e-9),
       'and the can keeps the few meters it had no room for', fillAt(1, slot))
    local pushed = events(BR.Net.INV_SET, 1)
    local last = pushed[#pushed] and pushed[#pushed].slots[slot]
    ok(last and last.fill == 0.004, 'its plate is sent 0.004: a sliver, never an empty can',
       last and last.fill)

    slot = scene({ model = 'sanchez', burn = 0 })
    setAndPour(slot, '70', true)
    ok(BR.Fuel.left(NET) == TANK, 'a dirt bike at 70%: the can fills it to 100', BR.Fuel.left(NET))
    ok(near(fillAt(1, slot), 0.7, 1e-9), 'and keeps the 70% the tank had no room for', fillAt(1, slot))
    slot = scene({ model = 'sanchez', burn = 0 })
    setAndPour(slot, '0')
    ok(BR.Fuel.left(NET) == TANK and inv(1).slots[slot] == false,
       'one set to 0: a full can fills it, and is gone')
    BR.Server.devMode = false

    -- AND ITS WORDS ARE THE FILES' (#217's third review). A press the player's
    -- own client drops never reaches the server, so the console the playtest
    -- sends a tester to has nothing for it: the opening and `brjerrycan`'s row
    -- name every one, the cap's reach at the config's meters. The reach was
    -- the one left out, and the one a tester meets first: the cone stands
    -- from 3 m, and a press from 2 m did nothing the console could show. Each
    -- is proved unsent elsewhere: tools/test_client.lua's #217 block and
    -- tools/test_jerrycan_client.lua's finder. Nor does either doc that gives
    -- the cone's meters give them without the reach.
    local reach, cone = ('%g m'):format(J.capReach), ('%g m'):format(J.markerReach)
    --- What of `words` a text does not say, its line breaks read as spaces.
    local function unsaid(text, words)
        text = text:gsub('%s+', ' ')
        local out = {}
        for _, w in ipairs(words) do
            if not text:find(w, 1, true) then out[#out + 1] = w end
        end
        return table.concat(out, ', ')
    end
    local doc = (readFile('docs/running.md') or ''):gsub('\r\n', '\n')
    local play = doc:match('\n### Playtesting the jerry can %(#217%)\n(.-)\n### ') or ''
    local opening = play:match('\n(A refused press .-)\n\n') or ''
    local row = doc:match('\n(| `brjerrycan`[^\n]*)') or ''
    local step3 = play:match('\n(3%. [^\n]*)') or ''
    local never = { 'from a seat', 'downed', 'moving', 'already using an item', reach }
    local miss = unsaid(opening, never)
    ok(miss == '', 'the playtest names every press the client never sends: a seat, downed, '
       .. 'moving, mid-use, and past the ' .. reach .. ' a press reaches', miss)
    miss = unsaid(opening, { 'from ' .. cone, 'bicycle', 'aircraft', 'train', 'wreck' })
    ok(miss == '', 'and where the cone is not: past ' .. cone .. ', or over a bicycle, an '
       .. 'aircraft, a train or a wreck', miss)
    miss = unsaid(row, never)
    ok(miss == '', 'and `brjerrycan`\'s row says the same of what it does not count', miss)
    miss = unsaid(step3, { 'from ' .. cone, 'within ' .. reach })
    ok(miss == '', 'step 3: the cone from ' .. cone .. ', a press only within ' .. reach
       .. ' -- so the tester stands at the cone', miss)
    -- Step 10's press off the cap is one the client drops only while it
    -- stands past the reach and inside the cone's, both the config's to tune.
    local step10 = play:match('\n(10%. [^\n]*)') or ''
    local off = tonumber(step10:match('one from ([%d%.]+) m off the cap with the cone up'))
    ok(off ~= nil and off > J.capReach and off <= J.markerReach,
       ('step 10: its press %s m off the cap is past the %s reach, the cone up from %s')
           :format(tostring(off), reach, cone), step10)
    local terms = (readFile('docs/terminology.md') or ''):gsub('\r\n', '\n')
    local cap = terms:match('\n(| %*%*Gas cap%*%* |[^\n]*)') or ''
    miss = unsaid(cap, { 'within ' .. cone, 'within ' .. reach })
    ok(miss == '', 'docs/terminology.md\'s gas cap: the cone within ' .. cone .. ', the reach '
       .. 'beside it', miss)
end

realPrint(('\n\27[32m%d passed\27[0m'):format(pass))
if fail > 0 then
    realPrint(('\27[31m%d failed\27[0m'):format(fail))
    realExit(1)
end
