-- Unit tests for `brguardprobe`, the bodyguard ownership probe (#401) -- a DEV
-- TEST command, not the feature.
--
-- What a two-client session in game is for -- who owns a networked ped, and
-- what survives when that changes -- this cannot tell. What it can: that the
-- probe does exactly what the owner will type it for, and nothing when he has
-- not.
--
--   PART A  br_core/server/guardprobe.lua behind the REAL br_lib/shared/
--           devgate.lua and season module: refused with dev mode off and on
--           Season 1; `spawn` makes one networked s_m_y_marine_03 2 m in front
--           of the caller, in their bucket, orphan mode 2, a carbine, 50 armor,
--           told to the caller's bucket alone; `log` every 100 ms with each
--           owner change, kept in the file; a client's report logged, a stray
--           one not; `drive`; `clear` and a resource stop deleting it; and
--           nothing at all before it is typed.
--   PART B  br_core/client/guardprobe.lua over modeled natives: no native
--           without a guard; the client that gains it reports what survived
--           and applies the group (friendly to the caller's, hostile to the
--           rest), the fight and the follow task; losing it is said; an ended
--           follow task is given again; `drive` seats it in the first free
--           passenger seat, on the owner only. And none of the scope gate's
--           natives.
--
-- Run via tools/verify.sh, or directly:  lua tools/test_guardprobe.lua

local realPrint = print
local ROOT = 'resources/[fivem-royale]/'

local pass, fail = 0, 0
local group = ''
local function describe(name) group = name end
local function ok(cond, name, detail)
    if cond then pass = pass + 1 else
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
    for _, l in ipairs(logs) do if l:find(fragment, 1, true) then return true end end
    return false
end

local function loadAll(files)
    for _, f in ipairs(files) do
        local chunk, err = loadfile(ROOT .. f)
        if not chunk then
            realPrint('\27[31mload error\27[0m ' .. f .. ': ' .. tostring(err))
            os.exit(1)
        end
        chunk()
    end
end

-- ------------------------------------------------------- clock and threads ---

local now = 1000
function GetGameTimer() return now end
function GetCurrentResourceName() return 'br_core' end
local threads = {}
Citizen = {
    CreateThread = function(fn)
        threads[#threads + 1] = { co = coroutine.create(fn), wake = now }
    end,
    Wait = function(ms) coroutine.yield(ms or 0) end,
}
local function pump()
    local i = 1
    while i <= #threads do
        local t = threads[i]
        if t.wake <= now then
            local okr, ms = coroutine.resume(t.co)
            if not okr then
                fail = fail + 1
                realPrint('\27[31mthread error\27[0m ' .. tostring(ms))
            end
            if coroutine.status(t.co) == 'dead' then
                table.remove(threads, i)
            else
                t.wake = now + math.max(1, tonumber(ms) or 0)
                i = i + 1
            end
        else
            i = i + 1
        end
    end
end
local function step(ms)
    local stop = now + ms
    while now < stop do
        now = now + 10
        pump()
    end
end

-- ====================================================================== --
-- PART A -- the server
-- ====================================================================== --

local convars = { sv_devMode = 'true' }
function GetConvar(n, d)
    local v = convars[n]
    if v == nil then return d end
    return v
end
local commands = {}
function RegisterCommand(name, fn) commands[name] = fn end
local handlers = {}
function RegisterNetEvent() end
function AddEventHandler(n, fn)
    handlers[n] = handlers[n] or {}
    table.insert(handlers[n], fn)
end
local function fire(n, src, ...)
    local prev = source
    source = src
    for _, fn in ipairs(handlers[n] or {}) do fn(...) end
    source = prev
end

loadAll({
    'br_lib/shared/devgate.lua',
    'br_lib/shared/enums.lua',
    'br_lib/shared/season.lua',
    'br_lib/config/seasons.lua',
})
local function season(n)
    BR.Season.boot(function(name)
        return name == 'br_season' and tostring(n) or ''
    end, function() end)
end
season(2)

-- THE WORLD THE SERVER SEES. Player 1 calls, from bucket 7; player 2 shares
-- it; player 3 is elsewhere (bucket 0).
local hashes, nextHash = {}, 1000
function GetHashKey(s)
    if not hashes[s] then nextHash = nextHash + 1; hashes[s] = nextHash end
    return hashes[s]
end
local players = { { src = 1, bucket = 7, ped = 101, x = 100.0, y = 200.0, z = 30.0, h = 90.0, veh = 0 },
                  { src = 2, bucket = 7, ped = 102, x = 0.0, y = 0.0, z = 30.0, h = 0.0, veh = 0 },
                  { src = 3, bucket = 0, ped = 103, x = 0.0, y = 0.0, z = 30.0, h = 0.0, veh = 0 } }
local function P(src) return players[src] end
function GetPlayers() return { '1', '2', '3' } end
function GetPlayerName(src) return 'p' .. tostring(src) end
function GetPlayerPed(src) return P(tonumber(src)) and P(tonumber(src)).ped or 0 end
function GetPlayerRoutingBucket(src) return P(tonumber(src)).bucket end
local pedOwner = { [101] = 1, [102] = 2, [103] = 3 }
local ents = {}            -- ent -> { model, x, y, z, h, net, exists, bucket, orphan, weapon, armor, health, owner, veh }
local created, deleted, sentTo = {}, {}, {}
local appearAt = nil       -- the clock time an RPC'd ped exists from
local nextEnt = 5000
function CreatePed(pedType, model, x, y, z, h, net, host)
    nextEnt = nextEnt + 1
    ents[nextEnt] = { model = model, x = x, y = y, z = z, h = h, net = nextEnt + 10000,
                      networked = net, health = 200, armor = 0, owner = 1, veh = 0 }
    created[#created + 1] = nextEnt
    appearAt = now + 300
    return nextEnt
end
function DoesEntityExist(e)
    local x = ents[e]
    -- A NUMBER, the BOOL native's other shape: 0 is truthy in Lua.
    return (x and not x.deleted and appearAt and now >= appearAt) and 1 or 0
end
function SetEntityRoutingBucket(e, b) ents[e].bucket = b end
function SetEntityOrphanMode(e, m) ents[e].orphan = m end
function GiveWeaponToPed(e, w) ents[e].weapon = w end
function SetPedArmour(e, a) ents[e].armor = a end
function GetPedArmour(e) return ents[e] and ents[e].armor or 0 end
function GetEntityHealth(e) return ents[e] and ents[e].health or 0 end
function NetworkGetEntityOwner(e) return ents[e] and ents[e].owner or -1 end
function NetworkGetNetworkIdFromEntity(e)
    if ents[e] then return ents[e].net end
    if e == 9001 then return 777 end
    return e + 50000
end
function GetVehiclePedIsIn(ped)
    if ents[ped] then return ents[ped].veh end
    for _, p in ipairs(players) do if p.ped == ped then return p.veh end end
    return 0
end
function DeleteEntity(e) if ents[e] then ents[e].deleted = true end deleted[#deleted + 1] = e end
function GetEntityCoords(ped)
    for _, p in ipairs(players) do if p.ped == ped then return { x = p.x, y = p.y, z = p.z } end end
    return { x = 0.0, y = 0.0, z = 0.0 }
end
function GetEntityHeading(ped)
    for _, p in ipairs(players) do if p.ped == ped then return p.h end end
    return 0.0
end
function TriggerClientEvent(name, src, payload) sentTo[#sentTo + 1] = { name = name, src = src, d = payload } end
local files = {}
function SaveResourceFile(res, name, body) files[res .. '/' .. name] = body return true end
local notices = {}
BR.Server = { notify = function(src, text) notices[#notices + 1] = { src = src, text = text } end }

local threadsBefore = #threads
loadAll({ 'br_core/server/guardprobe.lua' })

local function cmd(src, line)
    local args = {}
    for w in line:gmatch('%S+') do args[#args + 1] = w end
    commands.brguardprobe(src, args, 'brguardprobe ' .. line)
end
local function sent(name)
    local out = {}
    for _, s in ipairs(sentTo) do if s.name == name then out[#out + 1] = s end end
    return out
end

describe('nothing runs until it is typed')
do
    eq(#threads, threadsBefore, 'no thread at load')
    eq(#sentTo, 0, 'nothing sent to anyone')
    ok(type(commands.brguardprobe) == 'function', 'and the command is registered')
end

describe('dev mode only, and Season 2')
do
    convars.sv_devMode = 'false'
    cmd(1, 'spawn')
    eq(#created, 0, 'with dev mode off, `brguardprobe spawn` makes nothing')
    ok(said('brguardprobe is dev-mode only'), 'and the dev gate says so')
    convars.sv_devMode = 'true'
    season(1)
    cmd(1, 'spawn')
    eq(#created, 0, 'on Season 1 it makes nothing')
    ok(said('Season 2 only'), 'and says why')
    season(2)
    logs = {}
    commands.brguardprobe(0, { 'spawn' }, 'brguardprobe spawn')
    eq(#created, 0, 'from the server console it makes nothing: it needs a caller')
end

local ent, guard
describe('spawn: one networked soldier, 2 m in front, in the caller\'s bucket, kept, armed')
do
    cmd(1, 'spawn')
    eq(#created, 1, 'one CreatePed')
    ent = created[1]
    guard = ents[ent]
    eq(guard.model, GetHashKey('s_m_y_marine_03'), 'the marine')
    eq(guard.networked, true, 'networked')
    -- Heading 90 faces -x: two meters ahead of (100, 200) is (98, 200).
    ok(math.abs(guard.x - 98.0) < 0.01 and math.abs(guard.y - 200.0) < 0.01,
        'two meters in front of the caller', ('%.2f, %.2f'):format(guard.x, guard.y))
    eq(guard.bucket, nil, 'nothing is written to it before the RPC has built it')
    step(200)
    eq(guard.bucket, nil, 'still nothing while it does not exist')
    step(300)
    eq(guard.bucket, 7, 'then into the caller\'s routing bucket')
    eq(guard.orphan, 2, 'orphan mode 2: kept when its owner leaves')
    eq(guard.weapon, GetHashKey('WEAPON_CARBINERIFLE'), 'a carbine')
    eq(guard.armor, 50, '50 armor')
    local st = sent('br:guardprobe:state')
    local to = {}
    for _, s in ipairs(st) do to[s.src] = s.d end
    ok(to[1] and to[2] and to[1].net == guard.net and to[1].caller == 1 and to[1].callerPedNet == 50101,
        'the caller\'s bucket is told: its net id, the caller and the caller\'s ped', #st)
    eq(to[3], nil, 'and a player in another bucket is not')
end

describe('log: every 100 ms, the owner, health and seat -- and every owner change -- kept in the file')
do
    logs = {}
    cmd(1, 'log')
    step(1000)
    local samples = 0
    for _, l in ipairs(logs) do if l:find('owner p1 (1)  health 200', 1, true) then samples = samples + 1 end end
    ok(samples >= 9 and samples <= 11, 'ten samples a second', samples)
    ok(said('OWNER CHANGED none -> p1 (1)'), 'the first owner is a change')
    guard.owner, guard.health = 2, 150
    step(200)
    ok(said('OWNER CHANGED p1 (1) -> p2 (2)'), 'a move to another client is logged as it happens')
    ok(said('owner p2 (2)  health 150'), 'with the health from then on')
    guard.veh = 9001
    step(200)
    ok(said('in vehicle yes (777)'), 'and the seat, by the vehicle\'s net id')
    local body = files['br_core/guardprobe.log'] or ''
    ok(body:find('OWNER CHANGED p1 (1) -> p2 (2)', 1, true) ~= nil, 'kept in br_core/guardprobe.log to paste')
end

describe('a client\'s report of what survived is logged; a stray one is not')
do
    logs = {}
    fire('br:guardprobe:report', 2, { net = guard.net, what = 'gained ownership', task = 7,
        groupOk = false, armed = true, inVeh = true, combat = false, health = 150 })
    ok(said('client p2 (2) gained ownership: follow task 7, group LOST, carbine yes'), 'logged')
    logs = {}
    now = now + 500
    fire('br:guardprobe:report', 3, { net = 424242, what = 'gained ownership' })
    fire('br:guardprobe:report', 3, 'nonsense')
    eq(#logs, 0, 'a report about another entity, or not a table, is dropped')
end

describe('drive: the owner is asked to seat it in the caller\'s vehicle')
do
    players[1].veh = 0
    notices = {}
    cmd(1, 'drive')
    ok(notices[#notices] and notices[#notices].text:find('not in a vehicle', 1, true) ~= nil,
        'the caller on foot is told')
    players[1].veh = 9001
    sentTo = {}
    cmd(1, 'drive')
    local d = sent('br:guardprobe:drive')
    eq(#d, 2, 'both clients in the bucket are asked; the owner acts')
    ok(d[1] and d[1].d.net == guard.net and d[1].d.veh == 777, 'with the guard and the vehicle')
end

describe('clear, and a resource stop, delete it')
do
    sentTo = {}
    cmd(1, 'clear')
    ok(deleted[#deleted] == ent, 'clear deletes the guard')
    local st = sent('br:guardprobe:state')
    ok(#st == 2 and st[1].d == false, 'and tells the bucket it is gone')
    logs = {}
    step(300)
    local after = 0
    for _, l in ipairs(logs) do if l:find('health', 1, true) then after = after + 1 end end
    eq(after, 0, 'and the log stops')
    cmd(1, 'spawn')
    step(500)
    local second = created[#created]
    fire('onResourceStop', 0, 'br_core')
    ok(deleted[#deleted] == second, 'a br_core stop deletes the guard orphan mode 2 would keep')
end

-- ====================================================================== --
-- PART B -- the client
-- ====================================================================== --

local calls = 0
local function native(name, fn)
    _G[name] = function(...) calls = calls + 1 return fn(...) end
end

local ME, MATE = 1, 2
local myPed, mateNet, mePed = 501, 77, 501
local world = {}           -- net -> entity
local control = {}         -- entity -> true when this client owns it
local guardEnt = 6001
local G = { group = 0, task = 7, weapon = 0, veh = 0, combat = false, health = 180, given = {} }
local rel, taskGiven, seated, flags, toServer = {}, {}, nil, {}, {}
local seatsTaken = { [0] = true }

native('GetHashKey', GetHashKey)
native('NetworkDoesNetworkIdExist', function(n) return world[n] and 1 or 0 end)
native('NetworkGetEntityFromNetworkId', function(n) return world[n] or 0 end)
native('DoesEntityExist', function(e) return (e == guardEnt or e == 9100 or e == 701) and 1 or 0 end)
native('NetworkHasControlOfEntity', function(e) return control[e] and 1 or 0 end)
native('GetPlayerServerId', function() return ME end)
native('PlayerId', function() return 0 end)
native('PlayerPedId', function() return mePed end)
native('AddRelationshipGroup', function(n) return true, GetHashKey(n) end)
native('SetRelationshipBetweenGroups', function(r, a, b) rel[a .. '>' .. b] = r end)
native('GetVehiclePedIsIn', function() return G.veh end)
native('GetScriptTaskStatus', function() return G.task end)
native('GetPedRelationshipGroupHash', function() return G.group end)
native('GetSelectedPedWeapon', function() return G.weapon end)
native('IsPedInCombat', function() return G.combat and 1 or 0 end)
native('GetEntityHealth', function() return G.health end)
native('TaskFollowToOffsetOfEntity', function(p, target) taskGiven[#taskGiven + 1] = target G.task = 1 end)
native('SetPedRelationshipGroupHash', function(p, g) G.group = g end)
native('SetPedCombatAttributes', function() end)
native('SetPedFleeAttributes', function() end)
native('SetPedKeepTask', function() end)
native('HasPedGotWeapon', function() return G.weapon ~= 0 and 1 or 0 end)
native('GiveWeaponToPed', function(p, w) G.weapon = w end)
native('GetVehicleMaxNumberOfPassengers', function() return 3 end)
native('IsVehicleSeatFree', function(v, s) return seatsTaken[s] and 0 or 1 end)
native('ClearPedTasksImmediately', function() end)
native('SetPedIntoVehicle', function(p, v, s) seated = { v = v, s = s } G.veh = v end)
native('SetPedConfigFlag', function(p, f, on) flags[f] = on end)
function TriggerServerEvent(n, d) toServer[#toServer + 1] = { name = n, d = d } end

local tick = nil
BR.Loop = { TICK = 'tick', register = function(band, name, fn) if band == 'tick' then tick = fn end end }
local friendGroup = GetHashKey('BR_SQ4')
BR.Native = { groupFor = function(me) return me.src == MATE and friendGroup or GetHashKey('BR_SOLO'), true end }
BR.State = { roster = { [ME] = { squadId = 'm1sq4' }, [MATE] = { squadId = 'm1sq4' } } }

handlers = {}
loadAll({ 'br_core/client/guardprobe.lua' })
local function client(n, d) for _, fn in ipairs(handlers[n] or {}) do fn(d) end end
local function reports(what)
    local out = {}
    for _, s in ipairs(toServer) do if s.d and s.d.what == what then out[#out + 1] = s.d end end
    return out
end

describe('client: no guard, no native')
do
    calls = 0
    for _ = 1, 50 do tick() end
    eq(calls, 0, 'fifty ticks without a guard call nothing')
end

describe('client: gaining the guard -- what survived, then the group, the fight and the task again')
do
    world[4242] = guardEnt
    world[mateNet] = 701
    client('br:guardprobe:state', { net = 4242, caller = MATE, callerPedNet = mateNet })
    tick()
    eq(#reports('gained ownership'), 0, 'a guard another client owns: nothing')
    control[guardEnt] = true
    tick()
    local r = reports('gained ownership')[1]
    ok(r ~= nil, 'gaining it is reported')
    ok(r and r.task == 7 and r.groupOk == false and r.armed == false,
        'with what survived as it was found: no follow task, not in the group, no carbine')
    eq(G.group, GetHashKey('BR_GUARDPROBE'), 'then it is put in the probe\'s own group')
    local g = GetHashKey('BR_GUARDPROBE')
    ok(rel[g .. '>' .. friendGroup] == 0 and rel[friendGroup .. '>' .. g] == 0,
        'friendly with the caller\'s group, both ways')
    ok(rel[g .. '>' .. GetHashKey('BR_SQ5')] == 5 and rel[g .. '>' .. GetHashKey('BR_SOLO')] == 5
        and rel[g .. '>' .. GetHashKey('PLAYER')] == 5, 'and hostile to every other group')
    eq(rel[friendGroup .. '>' .. friendGroup], nil, 'no row between players\' own groups is written')
    eq(G.weapon, GetHashKey('WEAPON_CARBINERIFLE'), 'a carbine again')
    eq(taskGiven[#taskGiven], 701, 'and told to follow the caller, by the ped the server named')
    eq(#reports('gained ownership'), 1, 'reported once')
    tick(); tick()
    eq(#reports('gained ownership'), 1, 'and not again while it stays')
end

describe('client: an ended follow task is given again, once a second; losing the guard is said')
do
    G.task = 7
    local before = #taskGiven
    tick()
    eq(#taskGiven, before, 'not on the next tick')
    now = now + 1000
    tick()
    eq(#taskGiven, before + 1, 'but after a second')
    eq(#reports('follow task re-given'), 1, 'and reported')
    G.task = 7
    G.combat = true
    now = now + 1000
    tick()
    eq(#taskGiven, before + 1, 'not while it is fighting')
    G.combat = false
    control[guardEnt] = nil
    tick()
    eq(#reports('lost ownership'), 1, 'losing it is reported')
end

describe('client: drive -- the first free passenger seat, by the owner only')
do
    world[3131] = 9100
    client('br:guardprobe:drive', { net = 4242, veh = 3131 })
    eq(seated, nil, 'a client that does not own it seats nothing')
    control[guardEnt] = true
    tick()
    client('br:guardprobe:drive', { net = 4242, veh = 3131 })
    ok(seated and seated.v == 9100 and seated.s == 1, 'seat 0 is taken: seat 1', seated and seated.s)
    eq(flags[184], true, 'and kept out of the driver\'s seat')
    local before = #taskGiven
    G.task = 7
    now = now + 1000
    tick()
    eq(#taskGiven, before, 'a seated guard is not told to follow on foot')
    client('br:guardprobe:state', false)
    calls = 0
    tick()
    eq(calls, 0, 'cleared: nothing again')
end

describe('client: none of the scope gate\'s natives')
do
    local fh = io.open(ROOT .. 'br_core/client/guardprobe.lua', 'r')
    local src = fh and fh:read('a') or ''
    if fh then fh:close() end
    src = src:gsub('%-%-[^\n]*', '')
    ok(src ~= '' and not src:find('GetActivePlayers', 1, true) and not src:find('GetPlayerFromServerId', 1, true)
        and not src:find('GetPlayerPed%(') , 'no GetActivePlayers, GetPlayerFromServerId or GetPlayerPed')
end

print = realPrint
io.write(('%s%d passed%s'):format('\27[32m', pass, '\27[0m'))
if fail > 0 then
    io.write(('  %s%d failed%s\n'):format('\27[31m', fail, '\27[0m'))
    os.exit(1)
end
io.write('\n')
