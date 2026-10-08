-- Season 2 crates (#395), the client: the box a crate wears, the wooden crate
-- behind it, the clip, the swap to the open prop, the prompt, and the cost.
--
-- LOADS THE REAL FILES -- br_core/client/main.lua (the loop registry),
-- client/dui.lua, client/loot.lua and client/warmupcrates.lua -- against a
-- modeled engine: entities that exist until deleted and remember their model,
-- pose, freeze, collision and animation; models that are or are not in this
-- build and that do or do not stream; clipsets that load, load late or never;
-- threads as coroutines woken by a clock that moves a frame at a time; and the
-- three BR.Loop bands stepped on that clock. Natives are COUNTED, so the frame
-- cost of a box can be put beside the wooden crate's.
--
-- WHAT IT CANNOT TELL YOU: whether the owner's clip looks right, whether the
-- open prop really is posed as its last frame, where the prompt reads best, or
-- what GetAnimDuration says about a real clipset. Those are what `brbox`,
-- `brboxprompt` and `brboxcheck` are for, the day the props land.
--
-- The server half is tools/test_crates.lua.
--
-- Run via tools/verify.sh, or directly:  lua tools/test_crates_client.lua

local realPrint = print
local realExit  = os.exit

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

-- ------------------------------------------------------------- the engine ---

local now = 1000
function GetGameTimer() return now end
function GetCurrentResourceName() return 'br_core' end
function IsDuplicityVersion() return false end

--- Every native call, counted. `calls` is read across one frame to price it.
local calls = 0
local function native(name, fn)
    _G[name] = function(...)
        calls = calls + 1
        return fn(...)
    end
end

-- Names and hashes, both ways: a model is a hash to the code and a name to us.
local hashOf, nameOf, nextHash = {}, {}, 70000
native('GetHashKey', function(s)
    s = tostring(s)
    local h = hashOf[s]
    if not h then
        nextHash = nextHash + 1
        h = nextHash
        hashOf[s], nameOf[h] = h, s
    end
    return h
end)
local function nm(h) return nameOf[h] or tostring(h) end

--- REPLICATED CONVARS, AND THE RUNTIME'S LISTENER ON THEM. A client's
--- replicated value is applied by `setr`, which calls every
--- AddConvarChangeListener whose filter names it (Cfx, apiset shared). The
--- season module holds br_seasonServed and re-reads it only when told, so every
--- write to `convars` below is a `setr`: it lands, and the listeners hear it.
local convarListeners = {}
native('AddConvarChangeListener', function(filter, fn)
    convarListeners[#convarListeners + 1] = { filter = filter, fn = fn }
    return #convarListeners
end)
local convarStore = { br_seasonServed = '2', br_devMode = 'true' }
local convars = setmetatable({}, {
    __index = convarStore,
    __newindex = function(_, k, v)
        convarStore[k] = v
        for _, l in ipairs(convarListeners) do
            if l.filter == nil or l.filter == k then l.fn(k, '') end
        end
    end,
})
native('GetConvar', function(n, d)
    local v = convars[n]
    if v == nil then return d end
    return tostring(v)
end)
native('GetConvarInt', function(n, d) return tonumber(convars[n]) or d end)

--- THIS BUILD'S MODELS. `cd` is the CD image (IsModelInCdimage, IsModelValid);
--- `noStream` is a model the image has that never finishes streaming; `refuse`
--- is one the engine will not build as an object; `streamAt[name]` is the
--- clock time a slow one finishes streaming.
local cd = { prop_box_wood05a = true, prop_box_wood05b = true }
local noStream, refuse, loaded, streamAt = {}, {}, {}, {}
local requested, released = {}, {}
native('IsModelInCdimage', function(h) return cd[nm(h)] and 1 or 0 end)
native('IsModelValid', function(h) return cd[nm(h)] and true or false end)
native('RequestModel', function(h)
    requested[#requested + 1] = nm(h)
    if cd[nm(h)] and not noStream[nm(h)] and not streamAt[nm(h)] then loaded[h] = true end
end)
native('HasModelLoaded', function(h)
    local at = streamAt[nm(h)]
    if at and now >= at and cd[nm(h)] then loaded[h] = true end
    return loaded[h] == true
end)
native('SetModelAsNoLongerNeeded', function(h) released[nm(h)] = (released[nm(h)] or 0) + 1 end)
native('GetWeapontypeModel', function() return GetHashKey('w_pi_pistol') end)

--- CLIPSETS. `dicts` exist; `dictLate[d]` = the time it finishes loading;
--- `dictNever` never loads; `clipLen` is GetAnimDuration in seconds.
local dicts, dictLoaded, dictLate, dictNever, clipLen = {}, {}, {}, {}, {}
native('DoesAnimDictExist', function(d) return dicts[d] == true end)
native('RequestAnimDict', function(d)
    if dicts[d] and not dictNever[d] and not dictLate[d] then dictLoaded[d] = true end
end)
native('HasAnimDictLoaded', function(d)
    if dictLate[d] and now >= dictLate[d] then dictLoaded[d] = true end
    return dictLoaded[d] == true
end)
native('GetAnimDuration', function(d, c) return clipLen[d .. '/' .. c] or 0.0 end)

--- ENTITIES. The ped is 1.
local PED = 1
local ped = { x = 0.0, y = 0.0, z = 31.0 }
local ents, nextEnt = {}, 5000
local log = {}          -- 'create <h> <name>' / 'delete <h>', in order
local anims = {}
native('PlayerPedId', function() return PED end)
native('CreateObjectNoOffset', function(model, x, y, z, net, mission, dynamic)
    if refuse[nm(model)] then return 0 end
    nextEnt = nextEnt + 1
    ents[nextEnt] = { model = model, name = nm(model), x = x, y = y, z = z,
                      rx = 0.0, ry = 0.0, rz = 0.0, frozen = false,
                      collision = true, dynamic = dynamic, net = net }
    log[#log + 1] = ('create %d %s'):format(nextEnt, nm(model))
    return nextEnt
end)
native('DoesEntityExist', function(h) return ents[h] ~= nil end)
native('DeleteEntity', function(h)
    if ents[h] then log[#log + 1] = ('delete %d'):format(h) end
    ents[h] = nil
end)
native('GetEntityCoords', function(h)
    if h == PED then return { x = ped.x, y = ped.y, z = ped.z } end
    local e = ents[h]
    if e then return { x = e.x, y = e.y, z = e.z } end
    return { x = 0.0, y = 0.0, z = 0.0 }
end)
native('GetEntityRotation', function(h)
    local e = ents[h]
    if e then return { x = e.rx, y = e.ry, z = e.rz } end
    return { x = 0.0, y = 0.0, z = 0.0 }
end)
native('SetEntityRotation', function(h, rx, ry, rz)
    local e = ents[h]
    if e then e.rx, e.ry, e.rz = rx, ry, rz end
end)
native('SetEntityHeading', function(h, hd) local e = ents[h]; if e then e.rz = hd end end)
native('SetEntityCoordsNoOffset', function(h, x, y, z)
    local e = ents[h]
    if e then e.x, e.y, e.z = x, y, z end
end)
native('FreezeEntityPosition', function(h, on) local e = ents[h]; if e then e.frozen = on end end)
native('SetEntityCollision', function(h, on) local e = ents[h]; if e then e.collision = on end end)
native('GetEntityModel', function(h) local e = ents[h]; return e and e.model or 0 end)
native('PlayEntityAnim', function(h, clip, dict, blend, loop, stay)
    anims[#anims + 1] = { h = h, clip = clip, dict = dict, loop = loop, stay = stay }
    local e = ents[h]
    if e then e.anim = { clip = clip, dict = dict } end
    return true
end)
native('SetEntityAnimCurrentTime', function(h, dict, clip, t)
    local e = ents[h]
    if e then e.animTime = t end
end)
native('GetEntityVelocity', function() return { x = 0.0, y = 0.0, z = 0.0 } end)
native('GetEntityForwardVector', function() return { x = 1.0, y = 0.0, z = 0.0 } end)
native('GetGroundZFor_3dCoord', function() return true, 30.0 end)
native('GetWaterHeight', function() return false, 0.0 end)
native('HasCollisionLoadedAroundEntity', function() return true end)
native('IsPedInAnyVehicle', function() return false end)
local outlined = {}
native('SetEntityDrawOutline', function(h, on) outlined[h] = on end)
local sounds = {}
native('PlaySoundFrontend', function(_, name) sounds[#sounds + 1] = name end)
local resources = {}
native('GetResourceState', function(n) return resources[n] or 'missing' end)

-- Natives that only have to exist.
for _, n in ipairs({
    'ActivatePhysics', 'SetEntityDynamic', 'SetEntityHasGravity',
    'SetObjectPhysicsParams', 'SetEntityAsMissionEntity',
    'PlaceObjectOnGroundProperly', 'SetEntityVelocity',
    'SetEntityDrawOutlineColor', 'DrawLightWithRange', 'DrawMarker',
    'RequestCollisionAtCoord', 'AddBlipForCoord', 'AddBlipForRadius',
    'RemoveBlip', 'SetBlipSprite', 'SetBlipColour', 'SetBlipScale',
    'SetBlipAlpha', 'SetBlipAsShortRange', 'SetBlipFlashes',
    'BeginTextCommandSetBlipName', 'AddTextComponentSubstringPlayerName',
    'EndTextCommandSetBlipName', 'SetDrawOrigin', 'ClearDrawOrigin',
    'DrawSprite', 'SetDuiUrl', 'DestroyDui', 'CreateRuntimeTextureFromDuiHandle',
}) do native(n, function() end) end
native('DoesBlipExist', function() return false end)

-- THE DUI SURFACE. The prompt page is up; every quad corner is recorded.
local polys, offsets = 0, {}
native('CreateDui', function() return 7 end)
native('CreateRuntimeTxd', function(n) return n end)
native('GetDuiHandle', function() return 'h' end)
native('IsDuiAvailable', function() return true end)
native('SendDuiMessage', function() end)
native('DrawSpritePoly', function() polys = polys + 1 end)
native('GetGameplayCamCoord', function() return { x = 0.0, y = 0.0, z = 40.0 } end)
native('GetAspectRatio', function() return 1.7778 end)
native('GetModelDimensions', function()
    return { x = -0.5, y = -0.5, z = -0.3 }, { x = 0.5, y = 0.5, z = 0.3 }
end)
native('GetOffsetFromEntityInWorldCoords', function(h, x, y, z)
    offsets[#offsets + 1] = { h = h, x = x, y = y, z = z }
    local e = ents[h] or { x = 0.0, y = 0.0, z = 0.0 }
    return { x = e.x + x, y = e.y + y, z = e.z + z }
end)
json = { encode = function() return '{}' end, decode = function() return {} end }

-- THREADS, as coroutines woken by the clock.
local threads = {}
Citizen = {
    CreateThread = function(fn)
        threads[#threads + 1] = { co = coroutine.create(fn), wake = now }
    end,
    Wait = function(ms) coroutine.yield(ms or 0) end,
}
Citizen.SetTimeout = function(ms, fn)
    Citizen.CreateThread(function() Citizen.Wait(ms) fn() end)
end
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

-- EVENTS, COMMANDS, THE SERVER'S END OF THE WIRE.
local handlers, commands, toServer = {}, {}, {}
function RegisterNetEvent() end
function AddEventHandler(n, fn)
    handlers[n] = handlers[n] or {}
    handlers[n][#handlers[n] + 1] = fn
end
local events = {}
function TriggerEvent(n, ...)
    events[#events + 1] = { name = n, args = { ... } }
    for _, fn in ipairs(handlers[n] or {}) do fn(...) end
end
function TriggerServerEvent(n, d) toServer[#toServer + 1] = { name = n, d = d } end
-- `brbox` runs the server's `brboxsv` (#384's way, owner 2026-10-06): the
-- command line it sends, as words.
local executed = {}
function ExecuteCommand(line) executed[#executed + 1] = line end
local function lastWords()
    local out = {}
    for w in tostring(executed[#executed] or ''):gmatch('%S+') do out[#out + 1] = w end
    return out
end
function RegisterCommand(n, fn) commands[n] = fn end
function RegisterKeyMapping() end

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

loadAll({
    'br_lib/shared/enums.lua', 'br_lib/shared/protocol.lua',
    'br_lib/shared/rng.lua', 'br_lib/shared/geo.lua', 'br_lib/shared/clock.lua',
    'br_lib/config/match.lua', 'br_lib/config/storm.lua', 'br_lib/config/map.lua',
    'br_lib/config/weapons.lua', 'br_lib/config/loot.lua',
    'br_lib/config/warmupcrates.lua', 'br_lib/config/airdrop.lua',
    'br_lib/shared/season.lua', 'br_lib/config/seasons.lua',
    'br_lib/config/festive.lua', 'br_lib/shared/festive.lua',
    'br_lib/config/crates.lua', 'br_lib/shared/crates.lua',
    'br_lib/shared/loot_gen.lua',
    -- The Yubikey's art block (#396): what a key on the ground is drawn as.
    'br_lib/config/terminals.lua',
    'br_core/client/main.lua',
})

-- The collaborators that are pure native wrappers or another file's state.
BR.State = { me = { src = 1, state = BR.PlayerState.ALIVE }, landed = false, roster = {} }
local held = false
local keyFns = {}
BR.Keys = {
    on = function(name, fn) keyFns[name] = fn end,
    isHeld = function() return held end,
    labelFor = function() return 'E' end,
    rawActive = true, rawHolds = true,
}
--- The matrix scale each body was drawn at, by entity (BR.Native.propScale).
local scaledTo = {}
BR.Native = {
    propScale = function(obj, k) scaledTo[obj] = k end,
    aim = function() return false, nil, 0 end,
    keyLabelForCommand = function() return 'E', 'brinteract' end,
    pedReachable = function() return true, 'ok' end,
    help = function() end, blipName = function() end,
    inputForCommand = function() return '~INPUT~' end,
}
BR.Sfx = { play = function() end }
BR.Nui = { TOAST = 'toast' }

loadAll({
    'br_core/client/dui.lua',
    'br_core/client/loot.lua',
    'br_core/client/warmupcrates.lua',
})

local C = BR.Config.Crates
local L = BR.Config.Loot
local R = BR.Rarity
-- A client whose clock has synced with the server's, which is every client a
-- few seconds after it connects. The one block that is not says so.
BR.Clock.synced = true
local SHIPPED = (function()
    local function copy(t)
        if type(t) ~= 'table' then return t end
        local o = {}
        for k, v in pairs(t) do o[k] = copy(v) end
        return o
    end
    return copy(C)
end)()
local function deep(t)
    if type(t) ~= 'table' then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = deep(v) end
    return o
end

--- The props, the day they land: every row real, every model in this build,
--- every clipset there.
local function propsLanded()
    C.resource = 'br_crates'
    resources.br_crates = 'started'
    local function row(set, key)
        local r = { sealed = set .. key, open = set .. key .. '_open',
                    dict = 'anim@' .. set .. key, clip = 'open', clipMs = 1200 }
        cd[r.sealed], cd[r.open], dicts[r.dict] = true, true, true
        clipLen[r.dict .. '/open'] = 1.2
        return r
    end
    for t = 1, 5 do
        C.shipping[t] = row('ship_', t)
        C.festive[t]  = row('xmas_', t)
    end
    for _, g in ipairs(C.giftColors) do C.gift[g] = row('gift_', g) end
end
local function shipped()
    for k, v in pairs(deep(SHIPPED)) do C[k] = v end
end

-- THE CLOCK AND THE BANDS.
local lastTick, lastSlow = now, now
local function frame(ms)
    now = now + (ms or 16)
    pump()
    BR.Loop.step(BR.Loop.FRAME)
    if now - lastTick >= 100 then lastTick = now; BR.Loop.step(BR.Loop.TICK) end
    if now - lastSlow >= 1000 then lastSlow = now; BR.Loop.step(BR.Loop.SLOW) end
end
local function frames(n, ms) for _ = 1, n do frame(ms) end end

local nextId = 100
local function crateWire(extra)
    nextId = nextId + 1
    local w = { id = nextId, kind = 'chest', item = 'chest', rarity = R.RARE, count = 1,
                x = 2.0, y = 0.0, z = 30.0, prop = L.chestProp, heading = 0.0 }
    for k, v in pairs(extra or {}) do w[k] = v end
    return w
end
--- A crate arriving from the server. The next frame runs the 1Hz prop pass,
--- which is what queues a body for anything in range.
local function add(w)
    TriggerEvent(BR.Net.LOOT_ADD, { w })
    lastSlow = now - 1000
end
local function husk(w)
    local h = {}
    for k, v in pairs(w) do h[k] = v end
    h.kind, h.item, h.prop, h.rarity, h.op = 'husk', 'husk', L.chestOpenProp, R.COMMON, nil
    TriggerEvent(BR.Net.LOOT_ADD, { h })
    return h
end

--- The live object at the crate's spot, and its model name.
local function bodyAt(x, y)
    local best = nil
    for h, e in pairs(ents) do
        if math.abs(e.x - x) < 0.6 and math.abs(e.y - y) < 0.6 then
            if not best or h > best then best = h end
        end
    end
    return best, best and ents[best].name or nil
end
local function bodies()
    local n = 0
    for _ in pairs(ents) do n = n + 1 end
    return n
end

local function reset()
    TriggerEvent(BR.Net.STATE, { state = BR.MatchState.ENDED })
    frames(3)
    shipped()
    for k in pairs(resources) do resources[k] = nil end
    anims, sounds, events, toServer, log, logs = {}, {}, {}, {}, {}, {}
    held = false
    BR.State.me.state = BR.PlayerState.ALIVE
    convars.br_seasonServed = '2'
    ped.x, ped.y, ped.z = 0.0, 0.0, 31.0
    -- A fresh cell subscription, so the registry is live again.
    frames(12)
end

--- Hold the interact key on the crate in front of the player until the hold
--- completes and the claim leaves.
local function holdOpen()
    frames(2)
    held = true
    keyFns.interact(true)
    frames(80)
    held = false
    keyFns.interact(false)
    frames(10)
end

local function claimsSent()
    local n = 0
    for _, s in ipairs(toServer) do if s.name == BR.Net.LOOT_CLAIM then n = n + 1 end end
    return n
end

local function errored()
    for _, l in ipairs(logs) do if l:find('errored', 1, true) then return l end end
    return nil
end

frames(12)

-- =========================================================================

describe('Season 1: a crate with no look is today\'s wooden crate, opened today\'s way')
do
    reset()
    convars.br_seasonServed = '1'
    propsLanded()
    local w = crateWire()
    add(w)
    frames(10)
    local h, name = bodyAt(w.x, w.y)
    eq(name, L.chestProp, 'the sealed wooden crate is built')
    holdOpen()
    eq(claimsSent(), 1, 'a hold sends one claim')
    log = {}
    husk(w)
    frames(5)
    local h2, name2 = bodyAt(w.x, w.y)
    eq(name2, L.chestOpenProp, 'the server\'s husk becomes the open wooden crate')
    ok(h2 ~= h and ents[h] == nil, 'the sealed body is gone')
    eq(log[1], ('delete %d'):format(h), 'deleted first, then rebuilt -- exactly as before')
    eq(#anims, 0, 'and nothing was animated')
    ok(#sounds > 0, 'the reveal still plays for the player who opened it')
    eq(errored(), nil, 'and no loop errored')
end

describe('model choice: every tier, plain and festive, sealed and open, and the gift boxes')
do
    reset()
    propsLanded()
    for t = 1, 5 do
        for _, f in ipairs({ false, true }) do
            local w = crateWire({ bt = t, bf = f or nil, x = 2.0 + t, y = f and 2.0 or -2.0 })
            add(w)
            frames(6)
            local _, name = bodyAt(w.x, w.y)
            eq(name, (f and 'xmas_' or 'ship_') .. t,
                ('tier %d %s is its own box'):format(t, f and 'festive' or 'plain'))
            husk(w)
            frames(6)
            local _, open = bodyAt(w.x, w.y)
            eq(open, (f and 'xmas_' or 'ship_') .. t .. '_open', 'and opens into its own open prop')
        end
    end
    for i, g in ipairs(C.giftColors) do
        local w = crateWire({ bt = 3, bg = g, x = -2.0 - i, y = 0.0 })
        add(w)
        frames(6)
        local _, name = bodyAt(w.x, w.y)
        eq(name, 'gift_' .. g, ('the %s gift box'):format(g))
    end
    eq(errored(), nil, 'no loop errored')
end

describe('the fallback: anything this build cannot draw is the wooden crate')
do
    -- FRESH NAMES IN EVERY CASE. What the CD image holds cannot change under a
    -- running game, so the client asks once per model per session -- a model
    -- this suite has already shown present stays present.
    reset()
    propsLanded()
    C.shipping[4].sealed = 'ship_4_absent'
    local w = crateWire({ bt = 4 })
    add(w)
    frames(6)
    local _, name = bodyAt(w.x, w.y)
    eq(name, L.chestProp, 'a box model not in this build: the wooden crate')
    ok(said('ship_4_absent is not in this build'), 'and the console says which model')

    shipped()
    local w2 = crateWire({ bt = 2, x = 4.0 })
    add(w2)
    frames(6)
    local _, name2 = bodyAt(w2.x, w2.y)
    eq(name2, L.chestProp, 'a placeholder row: the wooden crate')

    -- IN THE IMAGE BUT NEVER STREAMS: the wait runs out, then wood -- and the
    -- next crate wearing it does not wait at all.
    propsLanded()
    C.shipping[3].sealed = 'ship_3_slow'
    cd.ship_3_slow, noStream.ship_3_slow = true, true
    local w3 = crateWire({ bt = 3, x = 6.0 })
    add(w3)
    frames(10)
    eq(select(2, bodyAt(w3.x, w3.y)), nil, 'while the box is still streaming, nothing is built yet')
    frames(300)
    eq(select(2, bodyAt(w3.x, w3.y)), L.chestProp, 'a box that never streams: the wooden crate')
    local w4 = crateWire({ bt = 3, x = 8.0 })
    add(w4)
    frames(8)
    eq(select(2, bodyAt(w4.x, w4.y)), L.chestProp, 'and the next one is wood at once')
    noStream.ship_3_slow = nil

    -- AND ONE THE ENGINE WILL NOT BUILD AS AN OBJECT: wood, on the next pass.
    propsLanded()
    C.shipping[5].sealed = 'ship_5_refused'
    cd.ship_5_refused, refuse.ship_5_refused = true, true
    local w5 = crateWire({ bt = 5, x = 10.0 })
    add(w5)
    frames(8)
    eq(select(2, bodyAt(w5.x, w5.y)), L.chestProp, 'a box the engine refuses: the wooden crate')
    refuse.ship_5_refused = nil
    eq(BR.Loot.boxes.fallback > 0, true, 'the fallbacks are counted for /brloot')
    eq(errored(), nil, 'no loop errored')
end

describe('the open: the clip on the sealed box, held, then the open prop at the same pose')
do
    reset()
    propsLanded()
    local w = crateWire({ bt = 4 })
    add(w)
    frames(15)
    local sealed, name = bodyAt(w.x, w.y)
    eq(name, 'ship_4', 'the sealed tier 4 box stands there')
    ents[sealed].rz = 37.0                       -- the pose physics settled it into
    frames(8)                                    -- loot.crates records it

    holdOpen()
    eq(claimsSent(), 1, 'the hold sends the claim')
    TriggerEvent(BR.Net.LOOT_OPENING, { id = w.id, at = BR.Clock.now(), ms = 1200, mine = true })
    eq(#anims, 1, 'LOOT_OPENING plays the clip')
    local a = anims[1] or {}
    eq(a.h, sealed, 'on the sealed box this client already has')
    eq(a.dict, 'anim@ship_4', 'from its row\'s clipset')
    eq(a.clip, 'open', 'its clip')
    eq(a.loop, false, 'once')
    eq(a.stay, true, 'holding the last frame')
    eq(ents[sealed].frozen, true, 'and the box is held still while it plays')
    ok(table.concat(requested, ','):find('ship_4_open', 1, true) ~= nil,
        'the open prop is asked for now, so the swap does not stream')

    -- NOTHING IS OFFERED while it opens.
    polys = 0
    frames(5)
    eq(polys, 0, 'no prompt is drawn on a box that is opening')
    eq(outlined[sealed], nil, 'and it does not glow')

    -- THE LAST FRAME: the burst arrives as the husk.
    log, sounds = {}, {}
    frames(70)
    husk(w)
    ok(ents[sealed] ~= nil, 'the sealed body is still on screen when the husk arrives')
    eq(ents[sealed].collision, false, 'with its collision off, so the open body is not shoved')
    frames(3)
    local open, oname = bodyAt(w.x, w.y)
    eq(oname, 'ship_4_open', 'the open prop is built')
    eq(ents[open] and ents[open].rz, 37.0, 'at the pose the box was standing in')
    eq(ents[sealed], nil, 'and the sealed body goes')
    local created, deleted = nil, nil
    for i, line in ipairs(log) do
        if line == ('create %d ship_4_open'):format(open) then created = i end
        if line == ('delete %d'):format(sealed) then deleted = i end
    end
    ok(created and deleted and created < deleted,
        'the open body exists before the sealed one is deleted -- no frame of nothing',
        table.concat(log, ' | '))
    ok(#sounds > 0, 'the opener hears the reveal at the burst')
    local opened = false
    for _, ev in ipairs(events) do if ev.name == 'br:loot:opened' then opened = true end end
    ok(opened, 'and the walkthrough is told this player opened it')
    eq(BR.Loot.boxes.swaps >= 1, true, 'the swap is counted')
    eq(errored(), nil, 'no loop errored')
end

describe('somebody else\'s open: the clip plays, the reveal does not')
do
    reset()
    propsLanded()
    local w = crateWire({ bt = 2 })
    add(w)
    frames(15)
    holdOpen()                                   -- our hold finished a tick late
    TriggerEvent(BR.Net.LOOT_OPENING, { id = w.id, at = BR.Clock.now(), ms = 1200 })
    eq(#anims, 1, 'the clip still plays for a bystander')
    sounds = {}
    husk(w)
    frames(3)
    eq(#sounds, 0, 'and the reveal is not theirs to hear')
end

describe('a hold still running when the box starts to open ends on that frame')
do
    reset()
    propsLanded()
    local w = crateWire({ bt = 2 })
    add(w)
    frames(15)
    held = true
    keyFns.interact(true)
    frames(20)
    TriggerEvent(BR.Net.LOOT_OPENING, { id = w.id, at = BR.Clock.now(), ms = 1200 })
    frames(80)
    held = false
    keyFns.interact(false)
    frames(5)
    eq(claimsSent(), 0, 'the hold on a box somebody else opened never sends a claim')
end

describe('a late message starts the clip part-way; one after the clip has ended plays nothing')
do
    reset()
    propsLanded()
    local w = crateWire({ bt = 1 })
    add(w)
    frames(15)
    local box = bodyAt(w.x, w.y)
    TriggerEvent(BR.Net.LOOT_OPENING, { id = w.id, at = BR.Clock.now() - 600, ms = 1200 })
    eq(#anims, 1, 'a message 600ms late still plays the clip')
    ok(math.abs((ents[box].animTime or 0) - 0.5) < 1e-6,
        'starting it half-way, so it still ends on the burst', tostring(ents[box].animTime))

    local w2 = crateWire({ bt = 1, x = 5.0 })
    add(w2)
    frames(15)
    anims = {}
    TriggerEvent(BR.Net.LOOT_OPENING, { id = w2.id, at = BR.Clock.now() - 1300, ms = 1200 })
    eq(#anims, 0, 'a message that arrives after the clip would have ended plays nothing')

    -- A CLIENT WHOSE CLOCK HAS NOT SYNCED cannot subtract the server's clock
    -- from its own, so it times the clip from the message's arrival.
    local w3 = crateWire({ bt = 1, x = 8.0 })
    add(w3)
    frames(15)
    local box3 = bodyAt(w3.x, w3.y)
    BR.Clock.synced = false
    TriggerEvent(BR.Net.LOOT_OPENING, { id = w3.id, at = BR.Clock.now() - 90000, ms = 1200 })
    BR.Clock.synced = true
    eq(#anims, 1, 'an unsynced client still plays the clip, however far off its clock is')
    eq(ents[box3].animTime, nil, 'from its first frame')
end

describe('a clipset that streams late plays late; one that never streams leaves the box sealed')
do
    reset()
    propsLanded()
    local w = crateWire({ bt = 5 })
    dictLate['anim@ship_5'] = now + 400
    add(w)
    frames(15)
    dictLoaded['anim@ship_5'] = nil
    dictLate['anim@ship_5'] = now + 300
    TriggerEvent(BR.Net.LOOT_OPENING, { id = w.id, at = BR.Clock.now(), ms = 1200 })
    eq(#anims, 0, 'not yet: the clipset is still streaming')
    frames(25)
    eq(#anims, 1, 'it plays once the clipset arrives')
    local box = bodyAt(w.x, w.y)
    ok((ents[box].animTime or 0) > 0.2, 'started where the server clock says it should be',
        tostring(ents[box].animTime))
    dictLate['anim@ship_5'] = nil

    local w2 = crateWire({ bt = 5, x = 6.0 })
    dictNever['anim@ship_5'] = true
    dictLoaded['anim@ship_5'] = nil
    add(w2)
    frames(15)
    anims = {}
    local before = BR.Loot.boxes.noClip
    TriggerEvent(BR.Net.LOOT_OPENING, { id = w2.id, at = BR.Clock.now(), ms = 1200 })
    frames(120)
    eq(#anims, 0, 'a clipset that never streams plays nothing')
    eq(BR.Loot.boxes.noClip, before + 1, 'and is counted')
    husk(w2)
    frames(4)
    eq(select(2, bodyAt(w2.x, w2.y)), 'ship_5_open', 'the burst still swaps to the open prop')
    dictNever['anim@ship_5'] = nil
end

describe('streamed in DURING the clip: the open prop, no clip, and no rebuild at the burst')
do
    reset()
    propsLanded()
    local w = crateWire({ bt = 3, op = true })
    add(w)
    frames(15)
    local box, name = bodyAt(w.x, w.y)
    eq(name, 'ship_3_open', 'a crate arriving mid-clip is drawn open')
    eq(#anims, 0, 'with no clip begun part-way')
    polys = 0
    frames(4)
    eq(polys, 0, 'and nothing is offered on it')
    log = {}
    local kept = BR.Loot.boxes.kept
    husk(w)
    frames(4)
    eq(bodyAt(w.x, w.y), box, 'at the burst the same body stays: it is already the open prop')
    eq(#log, 0, 'nothing is deleted or created')
    eq(BR.Loot.boxes.kept, kept + 1, 'and that is counted')
end

describe('streamed in AFTER the burst: the open prop')
do
    reset()
    propsLanded()
    local w = crateWire({ bt = 5, kind = 'husk', item = 'husk', prop = L.chestOpenProp, rarity = R.COMMON })
    add(w)
    frames(15)
    eq(select(2, bodyAt(w.x, w.y)), 'ship_5_open', 'a husk arriving later is the open box of its tier')
    eq(#anims, 0, 'and nothing plays')
end

describe('the wooden fallback opens the way it always has, clip or no clip')
do
    reset()
    propsLanded()
    C.shipping[2].sealed = 'ship_2_absent'
    local w = crateWire({ bt = 2 })
    add(w)
    frames(15)
    eq(select(2, bodyAt(w.x, w.y)), L.chestProp, 'drawn wooden')
    TriggerEvent(BR.Net.LOOT_OPENING, { id = w.id, at = BR.Clock.now(), ms = 1200 })
    eq(#anims, 0, 'a wooden crate has no clip to play')
    husk(w)
    frames(4)
    -- The open BOX is in this build, so the husk wears it: the look is the
    -- crate's, and every model is chosen on its own.
    eq(select(2, bodyAt(w.x, w.y)), 'ship_2_open', 'the husk wears whatever open model this build has')
end

describe('a sealed box whose open prop is never built is not left standing')
do
    reset()
    propsLanded()
    -- Neither the open box nor the wooden open crate can be built here.
    refuse.ship_1_open, refuse[L.chestOpenProp] = true, true
    local w = crateWire({ bt = 1 })
    add(w)
    frames(15)
    local sealed = bodyAt(w.x, w.y)
    TriggerEvent(BR.Net.LOOT_OPENING, { id = w.id, at = BR.Clock.now(), ms = 1200 })
    husk(w)
    frames(5)
    ok(ents[sealed] ~= nil, 'the sealed body lingers while the open one is tried')
    frames(250)
    eq(ents[sealed], nil, 'and is deleted once lingerMs has passed with no successor')
    refuse.ship_1_open, refuse[L.chestOpenProp] = nil, nil
end

describe('the match ending mid-clip takes every body with it')
do
    reset()
    propsLanded()
    local w = crateWire({ bt = 4 })
    add(w)
    frames(15)
    TriggerEvent(BR.Net.LOOT_OPENING, { id = w.id, at = BR.Clock.now(), ms = 1200 })
    husk(w)                                    -- lingering, open prop on its way
    TriggerEvent(BR.Net.STATE, { state = BR.MatchState.ENDED })
    frames(30)
    eq(bodies(), 0, 'nothing is left in the world: sealed, open or lingering')
    eq(errored(), nil, 'and no loop errored')
end

describe('the prompt: one offset and rotation for every shipping box, its own for the gift box')
do
    reset()
    propsLanded()
    local w = crateWire({ bt = 3, x = 1.5 })
    add(w)
    frames(15)
    local box = bodyAt(w.x, w.y)
    offsets, polys = {}, 0
    frame()
    ok(polys >= 2, 'the prompt is drawn on the box', tostring(polys))
    local P = C.prompt.shipping
    local hw = P.size * 0.5
    local zs, xs = {}, {}
    for _, o in ipairs(offsets) do
        if o.h == box then zs[#zs + 1] = o.z; xs[#xs + 1] = o.x end
    end
    eq(#zs, 4, 'four corners, through the box\'s own matrix')
    ok(#zs == 4 and math.abs(zs[1] - P.z) < 1e-6 and math.abs(zs[4] - P.z) < 1e-6,
        'at the shipping row\'s height', tostring(zs[1]))
    ok(#xs == 4 and math.abs(xs[1] - (P.x - hw)) < 1e-6 and math.abs(xs[2] - (P.x + hw)) < 1e-6,
        'and its width', tostring(xs[1]))

    -- THE TUNER moves it on the next frame and prints the paste line.
    logs = {}
    commands.brboxprompt(0, { 'ship', 'z=0.62', 'rz=90', 'size=0.5' })
    ok(said('shipping = { x = 0.000, y = 0.000, z = 0.620, rx = 0.0, ry = 0.0, rz = 90.0, size = 0.50 },'),
        'brboxprompt prints the config line to paste', logs[#logs])
    offsets = {}
    frame()
    local c = {}
    for _, o in ipairs(offsets) do if o.h == box then c[#c + 1] = o end end
    local hh = 0.25 * (256 / 512)
    ok(#c == 4 and math.abs(c[1].z - 0.62) < 1e-6, 'the label moved up, live')
    ok(#c == 4 and math.abs(c[1].x - (-hh)) < 1e-6 and math.abs(c[1].y - (-0.25)) < 1e-6,
        'and turned a quarter about the box\'s up axis',
        #c == 4 and ('%.3f, %.3f'):format(c[1].x, c[1].y) or 'no corners')

    -- THE GIFT BOX HAS ITS OWN.
    local g = crateWire({ bt = 3, bg = 'red', x = 1.5, y = 0.2 })
    TriggerEvent(BR.Net.LOOT_GONE, { w.id })
    add(g)
    frames(15)
    local gbox = bodyAt(g.x, g.y)
    offsets = {}
    frame()
    -- THE CENTER OF ITS FOUR CORNERS, since the owner's gift row stands the
    -- label up (rx 90): its corners sit above and below the row's height.
    local gn, gz, gy = 0, 0.0, 0.0
    for _, o in ipairs(offsets) do
        if o.h == gbox then gn, gz, gy = gn + 1, gz + o.z, gy + o.y end
    end
    eq(gn, 4, 'the gift box\'s label has four corners')
    ok(gn == 4 and math.abs(gz / 4 - C.prompt.gift.z) < 1e-6 and math.abs(gy / 4 - C.prompt.gift.y) < 1e-6,
        'centered on the gift row', gn == 4 and ('%.3f, %.3f'):format(gy / 4, gz / 4) or 'no corners')

    -- THE WOODEN CRATE KEEPS ITS LID LABEL, measured off its model.
    TriggerEvent(BR.Net.LOOT_GONE, { g.id })
    local wood = crateWire({ x = 1.5 })
    add(wood)
    frames(15)
    local wbox = bodyAt(wood.x, wood.y)
    offsets = {}
    frame()
    local wz = nil
    for _, o in ipairs(offsets) do if o.h == wbox then wz = o.z end end
    eq(wz, 0.3 + (L.crateLabelLift or 0.02), 'the wooden crate\'s label is still on its lid')
end

describe('the box prompt makes no closure and no table a frame -- #393')
do
    -- drawOnEntityAt made its corner as a closure over ten values on every call, so
    -- a Season 2 box's prompt left about half a kilobyte for the collector every
    -- frame it was up (#393's measure, 2026-10-06). The corner is a function of the
    -- file now. Counted with the collector stopped, over two hundred draws, with the
    -- stubs that answer a table answering the same one every time -- so what is
    -- counted is drawOnEntityAt's own.
    reset()
    propsLanded()
    local w = crateWire({ bt = 3, x = 1.5 })
    add(w)
    frames(15)
    local box = bodyAt(w.x, w.y)
    local page = BR.Dui.page('lootprompt', 'nui://br_ui/dui/prompt.html', 512, 256)
    local realOff, realCam = GetOffsetFromEntityInWorldCoords, GetGameplayCamCoord
    local one, cam = { x = 1.5, y = 0.0, z = 30.6 }, { x = 0.0, y = 0.0, z = 40.0 }
    GetOffsetFromEntityInWorldCoords = function() return one end
    GetGameplayCamCoord = function() return cam end
    polys = 0
    collectgarbage('collect')
    collectgarbage('stop')
    local k0 = collectgarbage('count')
    for _ = 1, 200 do BR.Dui.drawOnEntityAt(page, box, 0.5, 0.0, 0.0, 0.6, 0.0, 0.0, 90.0) end
    local kb = collectgarbage('count') - k0
    collectgarbage('restart')
    GetOffsetFromEntityInWorldCoords, GetGameplayCamCoord = realOff, realCam
    ok(polys == 400 and kb < 1.0,
        'two hundred box prompts are drawn, and allocate nothing',
        ('%d polys, %.2f KB'):format(polys, kb))
end

describe('no new per-frame cost: a box with its prompt costs no more than the wooden crate')
do
    local function price(look)
        reset()
        propsLanded()
        local w = crateWire(look)
        w.x = 1.5
        add(w)
        frames(30)
        local total = 0
        for _ = 1, 20 do
            calls = 0
            frame()
            total = total + calls
        end
        return total / 20
    end
    local wood = price({})
    local ship = price({ bt = 3 })
    local gift = price({ bt = 3, bg = 'blue' })
    ok(ship <= wood, ('a shipping box: %.1f natives a frame, the wooden crate %.1f'):format(ship, wood))
    ok(gift <= wood, ('a gift box: %.1f natives a frame, the wooden crate %.1f'):format(gift, wood))

    -- AND WHILE IT OPENS: the clip is one message, not a frame cost.
    reset()
    propsLanded()
    local w = crateWire({ bt = 3, x = 1.5 })
    add(w)
    frames(30)
    TriggerEvent(BR.Net.LOOT_OPENING, { id = w.id, at = BR.Clock.now(), ms = 1200 })
    frames(2)
    local total = 0
    for _ = 1, 20 do
        calls = 0
        frame()
        total = total + calls
    end
    ok(total / 20 <= wood, ('an opening box: %.1f natives a frame'):format(total / 20))
end

describe('the warmup pad\'s markers recognize their four crates as boxes')
do
    reset()
    propsLanded()
    BR.State.me.state = BR.PlayerState.WARMUP
    convars.br_seasonServed = '2'
    local a = BR.Config.WarmupCrates.anchors[2]
    ped.x, ped.y, ped.z = a.x + 2.0, a.y, a.z
    native('GetClosestObjectOfType', function(x, y, z, r, model)
        for h, e in pairs(ents) do
            if e.model == model and math.abs(e.x - x) <= r and math.abs(e.y - y) <= r then return h end
        end
        return 0
    end)
    frames(12)
    local w = crateWire({ bt = a.rarity, x = a.x, y = a.y, z = a.z })
    add(w)
    frames(20)
    eq(select(2, bodyAt(a.x, a.y)), 'ship_' .. a.rarity, 'the anchor\'s crate is its box')
    local s = BR.WarmupCrates.get(2)
    eq(s and s.sealed, true, 'and the pad reads it as sealed')
    husk(w)
    frames(20)
    s = BR.WarmupCrates.get(2)
    eq(s and s.sealed, false, 'and as open once it is the open box')
    eq(BR.Loot.boxModels()[GetHashKey('ship_' .. a.rarity)], 'sealed', 'boxModels names the sealed one')
end

describe('brbox: asks the server for a test crate, and checks what it can before asking')
do
    reset()
    propsLanded()
    toServer, executed = {}, {}
    commands.brbox(0, { 'ship', '4', 'festive' })
    local w = lastWords()
    eq(w[1], 'brboxsv', 'it runs the server dev command, dev mode its only gate')
    ok(w[2] == 'ship' and w[3] == '4' and w[4] == 'festive' and tonumber(w[5]) and tonumber(w[7]),
        'for a festive tier 4 shipping box, two meters ahead', table.concat(w, ' '))
    eq(#toServer, 0, 'and no net event at all')
    ok(said('xmas_4') and said('in this build'), 'and says which models this client will draw')
    commands.brbox(0, { 'gift', 'white' })
    w = lastWords()
    ok(w[2] == 'gift' and w[3] == 'white' and w[4] == 'zone', 'a gift box by color, festive as the zone says')
    commands.brbox(0, { 'ship', '2', 'plain' })
    eq(lastWords()[4], 'plain', 'and plain when asked')

    executed = {}
    commands.brbox(0, { 'ship', '9' })
    commands.brbox(0, { 'gift', 'purple' })
    commands.brbox(0, { 'crate' })
    eq(#executed, 0, 'a bad tier, an unknown color or an unknown kind asks for nothing')
    convars.br_seasonServed = '1'
    commands.brbox(0, { 'ship', '2' })
    eq(#executed, 0, 'and on Season 1 it does not ask')
    ok(said('Season 2 crates are off'), 'saying why, in F8')
end

describe('brboxcheck: every model and clip against this build, and GetAnimDuration beside clipMs')
do
    reset()
    propsLanded()
    C.shipping[2].clipMs = 1500             -- the config is wrong about this one
    cd.xmas_3_open = nil                    -- this build lacks this one
    logs = {}
    commands.brboxcheck(0, {})
    frames(60)
    ok(said('resource br_crates: started'), 'it names the props resource and its state')
    local function line(label)
        for _, l in ipairs(logs) do if l:find('  ' .. label .. ' ', 1, true) then return l end end
        return ''
    end
    ok(line('ship 1'):find('clip 1200ms, config 1200ms  ok', 1, true) ~= nil,
        'a clip whose length matches its config is ok', line('ship 1'))
    ok(line('ship 2'):find('MISMATCH: set clipMs = 1200', 1, true) ~= nil,
        'one that does not says the number to set', line('ship 2'))
    ok(line('festive 3'):find('MISSING', 1, true) ~= nil,
        'a model this build lacks is MISSING', line('festive 3'))
    shipped()
    -- The shipped rows are all real now; a row for a prop not made yet is a
    -- placeholder, and the check says so.
    local keep = C.gift.red
    C.gift.red = { sealed = 'PLACEHOLDER_gift_red', open = 'PLACEHOLDER_gift_red_open',
        dict = 'PLACEHOLDER_anim', clip = 'PLACEHOLDER_open', clipMs = 1200 }
    logs = {}
    commands.brboxcheck(0, {})
    frames(10)
    ok(line('gift red'):find('placeholder', 1, true) ~= nil,
        'and a placeholder row says so', line('gift red'))
    C.gift.red = keep
end

-- =========================================================================
-- A SEASON SWITCH UNDER CRATES ALREADY STANDING
-- =========================================================================
--
-- Owner, 2026-10-04: "while on dev I live-switched to season 1 and when I went
-- to warmup the crates fell through again. That means our new crate code is
-- not properly locked to season 2." The server now re-stamps every crate on a
-- switch (tools/test_crates.lua, PART C). Here is the client's half: a body is
-- chosen by the stamp AND this client's own season, and every body chosen
-- under the other answer is rebuilt when the season moves -- whichever of the
-- server's restyle and the replicated season lands first.

--- Any live body wearing one of the boxes.
local function boxBodies()
    local n = 0
    for _, e in pairs(ents) do
        if e.name:find('^ship_') or e.name:find('^xmas_') or e.name:find('^gift_') then n = n + 1 end
    end
    return n
end

describe('the client gate alone: a stamped crate on a Season 1 client is the wooden crate')
do
    reset()
    propsLanded()
    convars.br_seasonServed = '1'
    frames(3)
    local w = crateWire({ bt = 4 })
    add(w)
    frames(10)
    eq(select(2, bodyAt(w.x, w.y)), L.chestProp, 'stamped by the server, drawn by a Season 1 client as the wooden crate')
    requested, anims = {}, {}
    TriggerEvent(BR.Net.LOOT_OPENING, { id = w.id, at = BR.Clock.now(), ms = 1200 })
    frames(3)
    eq(#anims, 0, 'its opening plays no clip')
    local streamed = false
    for _, n in ipairs(requested) do if n:find('^ship_') then streamed = true end end
    eq(streamed, false, 'and streams no box for its burst')
    husk(w)
    frames(5)
    eq(select(2, bodyAt(w.x, w.y)), L.chestOpenProp, 'its husk is the open wooden crate')
    local hw = crateWire({ bt = 2, x = 5.0, kind = 'husk', item = 'husk', prop = L.chestOpenProp })
    add(hw)
    frames(10)
    eq(select(2, bodyAt(hw.x, hw.y)), L.chestOpenProp, 'a stamped husk streaming in is the open wooden crate too')
    eq(next(BR.Loot.boxModels()), nil, 'and not one box model was built')
    eq(errored(), nil, 'no loop errored')
end

describe('2 -> 1: every box this client built is rebuilt as today\'s wooden crate, and none is left behind')
do
    reset()
    propsLanded()
    local ws = {
        crateWire({ bt = 1, x = 2.0 }),
        crateWire({ bt = 3, bf = true, x = 3.5 }),
        crateWire({ bt = 5, bg = 'blue', x = 5.0 }),
    }
    for _, w in ipairs(ws) do add(w) end
    local hw = crateWire({ bt = 2, x = 6.5 })
    add(hw)
    frames(20)
    husk(hw)
    frames(10)
    local all = { ws[1], ws[2], ws[3], hw }
    local want = { 'ship_1', 'xmas_3', 'gift_blue', 'ship_2_open' }
    local boxes = true
    for i, w in ipairs(all) do
        if select(2, bodyAt(w.x, w.y)) ~= want[i] then boxes = false end
    end
    ok(boxes, 'Season 2: three sealed boxes and an open one')
    -- THE OWNER'S BOX: one gone through the map (a .ydr with no physics, the
    -- separate props fix), turned as it fell. loot.crates records that pose.
    local fell = ents[bodyAt(ws[1].x, ws[1].y)]
    fell.rz, fell.z = 21.0, -40.0
    frames(8)
    ok(next(BR.Loot.boxModels()) ~= nil, 'and boxModels lists the boxes built')
    local n0 = bodies()
    local oldFirst = bodyAt(ws[1].x, ws[1].y)
    released, log = {}, {}

    convars.br_seasonServed = '1'
    frames(15)
    local wood = true
    for i, w in ipairs(all) do
        local exp = (i == 4) and L.chestOpenProp or L.chestProp
        if select(2, bodyAt(w.x, w.y)) ~= exp then wood = false end
    end
    ok(wood, 'Season 1: each is the wooden crate, and the open one the open wooden crate')
    eq(bodies(), n0, 'one body per crate')
    eq(boxBodies(), 0, 'and not one box body is left in the world')
    -- PLACED AS SEASON 1 PLACES ONE, not at the box's pose: a box's origin is
    -- its bottom center, and this one's pose is under the map.
    local woodFirst = ents[bodyAt(ws[1].x, ws[1].y)]
    eq(woodFirst.rz, 0.0, 'the wooden crate stands on its entry\'s heading, not turned as the box fell')
    ok(math.abs(woodFirst.z - (30.0 + (L.restLift or 0.35))) < 0.01,
        'and on the ground, placed from its entry, though the box before it went through the map', woodFirst.z)
    local first, created, deleted = bodyAt(ws[1].x, ws[1].y), nil, nil
    for i, line in ipairs(log) do
        if line == ('create %d %s'):format(first, L.chestProp) then created = i end
        if line == ('delete %d'):format(oldFirst) then deleted = i end
    end
    ok(created and deleted and created < deleted,
        'the wooden body exists before the box goes -- no frame of nothing', table.concat(log, ' | '))
    eq(next(BR.Loot.boxModels()), nil, 'boxModels is empty: the pad\'s markers look for the wooden pair alone')
    ok((released.ship_1 or 0) > 0 and (released.gift_blue or 0) > 0 and (released.ship_2_open or 0) > 0,
        'and every box model is handed back to the streamer')
    eq(BR.Loot.reseasons.rebuilt >= 4, true, 'the rebuilds are counted for /brloot')
    eq(errored(), nil, 'no loop errored')
end

describe('1 -> 2: the wooden crates the server has stamped are rebuilt as their boxes')
do
    reset()
    propsLanded()
    convars.br_seasonServed = '1'
    frames(3)
    local w = crateWire({ bt = 3 })
    local w2 = crateWire({ bt = 4, bf = true, x = 4.0 })
    add(w)
    add(w2)
    frames(15)
    ok(select(2, bodyAt(w.x, w.y)) == L.chestProp and select(2, bodyAt(w2.x, w2.y)) == L.chestProp,
        'Season 1: wood, stamped or not')
    local n0 = bodies()
    convars.br_seasonServed = '2'
    frames(15)
    eq(select(2, bodyAt(w.x, w.y)), 'ship_3', 'Season 2: the tier 3 box')
    eq(select(2, bodyAt(w2.x, w2.y)), 'xmas_4', 'and the festive tier 4 box')
    eq(bodies(), n0, 'one body per crate')
    eq(BR.Loot.boxModels()[GetHashKey('ship_3')], 'sealed', 'boxModels lists them again')
    anims = {}
    TriggerEvent(BR.Net.LOOT_OPENING, { id = w.id, at = BR.Clock.now(), ms = 1200 })
    eq(#anims, 1, 'and it opens on its clip again')
    eq(errored(), nil, 'no loop errored')
end

describe('whichever lands first -- the server\'s restyle or this client\'s season -- one rebuild, the right body')
do
    -- 2 -> 1, THE RESTYLE FIRST: BR.Loot.reseason's re-announce, then the convar.
    reset()
    propsLanded()
    local w = crateWire({ bt = 2 })
    add(w)
    frames(15)
    eq(select(2, bodyAt(w.x, w.y)), 'ship_2', 'Season 2: the box')
    local rebuilt = BR.Loot.reseasons.rebuilt
    log = {}
    local cleared = {}
    for k, v in pairs(w) do cleared[k] = v end
    cleared.bt = nil
    TriggerEvent(BR.Net.LOOT_ADD, { cleared })
    frames(10)
    eq(select(2, bodyAt(w.x, w.y)), L.chestProp, 'the restyle alone rebuilds it as wood')
    convars.br_seasonServed = '1'
    frames(10)
    eq(BR.Loot.reseasons.rebuilt, rebuilt, 'and the season landing after finds nothing left to rebuild')
    local creates = 0
    for _, line in ipairs(log) do if line:find('^create') then creates = creates + 1 end end
    eq(creates, 1, 'one body built in all')

    -- 1 -> 2, THE SEASON FIRST: the convar, then the restyle that stamps it.
    local u = crateWire({ x = 4.0 })
    add(u)
    frames(10)
    log = {}
    convars.br_seasonServed = '2'
    frames(10)
    eq(select(2, bodyAt(u.x, u.y)), L.chestProp, 'Season 2 with no stamp yet: still the wooden crate')
    local stamped = {}
    for k, v in pairs(u) do stamped[k] = v end
    stamped.bt = 5
    TriggerEvent(BR.Net.LOOT_ADD, { stamped })
    frames(10)
    eq(select(2, bodyAt(u.x, u.y)), 'ship_5', 'the restyle after it makes it the box')
    creates = 0
    for _, line in ipairs(log) do if line:find('^create') then creates = creates + 1 end end
    eq(creates, 1, 'one body built in all')

    -- 2 -> 1, THE SEASON FIRST: the convar rebuilds the box as wood, and the
    -- restyle that clears its stamp after it keeps that wooden body.
    log = {}
    convars.br_seasonServed = '1'
    frames(10)
    eq(select(2, bodyAt(u.x, u.y)), L.chestProp, 'Season 1 before the restyle: the wooden crate already')
    local woodBody = bodyAt(u.x, u.y)
    local unstamped = {}
    for k, v in pairs(stamped) do unstamped[k] = v end
    unstamped.bt = nil
    TriggerEvent(BR.Net.LOOT_ADD, { unstamped })
    frames(10)
    eq(bodyAt(u.x, u.y), woodBody, 'the restyle after it keeps that same wooden body')
    creates = 0
    for _, line in ipairs(log) do if line:find('^create') then creates = creates + 1 end end
    eq(creates, 1, 'one body built in all')

    -- 1 -> 2, THE RESTYLE FIRST: the stamp arrives while this client still
    -- runs Season 1 and changes nothing on screen; the season after it does.
    log = {}
    TriggerEvent(BR.Net.LOOT_ADD, { stamped })
    frames(10)
    eq(bodyAt(u.x, u.y), woodBody, 'a stamp on a Season 1 client keeps the wooden body it has')
    convars.br_seasonServed = '2'
    frames(10)
    eq(select(2, bodyAt(u.x, u.y)), 'ship_5', 'and the season landing after makes it the box')
    creates = 0
    for _, line in ipairs(log) do if line:find('^create') then creates = creates + 1 end end
    eq(creates, 1, 'one body built in all')
    eq(errored(), nil, 'no loop errored')
end

describe('a switch that lands while a box is still streaming in: it is never adopted, and wood is built')
do
    reset()
    propsLanded()
    C.shipping[2].sealed = 'ship_2_late'
    cd.ship_2_late = true
    streamAt.ship_2_late = now + 500
    local w = crateWire({ bt = 2 })
    add(w)
    frames(4)
    eq(select(2, bodyAt(w.x, w.y)), nil, 'the box is still streaming: nothing is built yet')
    released, log = {}, {}
    convars.br_seasonServed = '1'
    frames(60)
    eq(select(2, bodyAt(w.x, w.y)), L.chestProp, 'the wooden crate stands there')
    local live = false
    for _, e in pairs(ents) do if e.name == 'ship_2_late' then live = true end end
    eq(live, false, 'and the box that finished streaming after the switch is not in the world')
    ok((released.ship_2_late or 0) > 0, 'its model is handed back')
    streamAt.ship_2_late = nil
    eq(errored(), nil, 'no loop errored')
end

describe('a switch mid-clip: the box is rebuilt as wood, and its burst is the wooden husk')
do
    reset()
    propsLanded()
    local w = crateWire({ bt = 4 })
    add(w)
    frames(15)
    local sealed = bodyAt(w.x, w.y)
    anims = {}
    TriggerEvent(BR.Net.LOOT_OPENING, { id = w.id, at = BR.Clock.now(), ms = 1200 })
    eq(#anims, 1, 'Season 2: the clip is playing')
    local n0 = bodies()
    convars.br_seasonServed = '1'
    frames(10)
    eq(ents[sealed], nil, 'the box mid-clip is gone')
    eq(select(2, bodyAt(w.x, w.y)), L.chestProp, 'the wooden crate stands in its place')
    -- The server's switch bursts it (BR.Loot.reseason): the husk, its look gone.
    w.bt = nil
    husk(w)
    frames(5)
    eq(select(2, bodyAt(w.x, w.y)), L.chestOpenProp, 'and the burst is the open wooden crate')
    eq(bodies(), n0, 'one body, nothing lingering')
    eq(boxBodies(), 0, 'and no box')
    eq(errored(), nil, 'no loop errored')
end

describe('the pad\'s markers follow the switch: its box in Season 2, the wooden crate in Season 1')
do
    reset()
    propsLanded()
    BR.State.me.state = BR.PlayerState.WARMUP
    local a = BR.Config.WarmupCrates.anchors[2]
    ped.x, ped.y, ped.z = a.x + 2.0, a.y, a.z
    native('GetClosestObjectOfType', function(x, y, z, r, model)
        for h, e in pairs(ents) do
            if e.model == model and math.abs(e.x - x) <= r and math.abs(e.y - y) <= r then return h end
        end
        return 0
    end)
    frames(12)
    local w = crateWire({ bt = a.rarity, x = a.x, y = a.y, z = a.z })
    add(w)
    frames(20)
    local s = BR.WarmupCrates.get(2)
    ok(select(2, bodyAt(a.x, a.y)) == 'ship_' .. a.rarity and s and s.sealed == true,
        'Season 2: the anchor\'s box, read as sealed')
    convars.br_seasonServed = '1'
    frames(20)
    s = BR.WarmupCrates.get(2)
    ok(select(2, bodyAt(a.x, a.y)) == L.chestProp and s and s.sealed == true,
        'Season 1: the wooden crate in its place, read as sealed')
    BR.State.me.state = BR.PlayerState.ALIVE
end

describe('the gate is asked when a body is chosen or the season moves -- never per frame')
do
    -- Owner, 2026-10-04: "let's also be efficient in how we're checking. That
    -- could turn out to be a lot of repeated checks."
    reset()
    propsLanded()
    for i = 1, 5 do add(crateWire({ bt = i, x = 1.0 + i })) end
    frames(30)
    local asks, reads = 0, 0
    local realHas, realGet = BR.Season.has, GetConvar
    BR.Season.has = function(id) asks = asks + 1 return realHas(id) end
    GetConvar = function(n, d)
        if n == 'br_seasonServed' then reads = reads + 1 end
        return realGet(n, d)
    end
    frames(120)
    eq(asks, 0, 'two seconds of frames with five boxes on screen ask the season nothing')
    eq(reads, 0, 'and read no convar for it')
    local flips, rebuilt = BR.Loot.reseasons.flips, BR.Loot.reseasons.rebuilt
    convars.br_seasonServed = '1'
    frames(20)
    eq(reads, 1, 'a switch reads the replicated season once')
    eq(asks, 1, 'and asks crates2 once, for all five rebuilds')
    eq(BR.Loot.reseasons.flips, flips + 1, 'one flip of the answer, followed once')
    -- A MOVE THAT FLIPS NOTHING -- Season 1 to not known, both without Season 2
    -- crates -- rebuilds nothing and walks nothing.
    rebuilt = BR.Loot.reseasons.rebuilt
    convars.br_seasonServed = 'x'
    frames(5)
    convars.br_seasonServed = '1'
    frames(5)
    ok(BR.Loot.reseasons.flips == flips + 1 and BR.Loot.reseasons.rebuilt == rebuilt,
        'a season move that leaves crates2 where it was is not followed at all')
    BR.Season.has, GetConvar = realHas, realGet
    eq(boxBodies(), 0, 'and all five are wood')
end

-- =========================================================================
-- THE YUBIKEY ON THE GROUND (#396, round 6)
-- =========================================================================
--
-- Owner, 2026-10-07: "the pickup works but it doesn't show the prop". The key
-- was drawn as `prop_cs_usb_drive`, which is in no object list for any build,
-- so this harness's CD image -- which holds models the game has -- does not
-- have it either: no body was ever built. `hei_prop_hst_usb_drive` is one the
-- game has (checked against the GTA V object dump, 2026-10-07); `blitz_seckey`
-- is the owner's, and only a client with br_stream_s2 has it.

local KEY_STANDIN = 'hei_prop_hst_usb_drive'
cd[KEY_STANDIN] = true

local CT = BR.Config.Terminals
local function keyWire(x)
    nextId = nextId + 1
    -- As server/yubikey.lua's Y.stack goes out through wireEntry.
    return { id = nextId, kind = 'yubikey', item = 'yubikey', rarity = R.RARE,
             count = 1, x = x or 2.0, y = 0.0, z = 30.0, prop = CT.art.keyProp }
end

describe('round 6: a Yubikey on a box without the owner\'s pack is the stock stand-in, not nothing')
do
    reset()
    cd.blitz_seckey = nil
    local w = keyWire()
    add(w)
    frames(10)
    local h, name = bodyAt(w.x, w.y)
    ok(h ~= nil, 'a key on the ground has a body')
    eq(name, KEY_STANDIN, 'and it is the stock USB stick the game has')
    eq(h and scaledTo[h], CT.art.keyFallbackScale, 'drawn at the stand-in\'s scale')
    ok(said('the Yubikey prop blitz_seckey is not in this build'), 'and the console says why')
    local lines = 0
    for _, l in ipairs(logs) do
        if l:find('is not in this build', 1, true) then lines = lines + 1 end
    end
    local w2 = keyWire(3.5)
    add(w2)
    frames(10)
    local _, name2 = bodyAt(w2.x, w2.y)
    eq(name2, KEY_STANDIN, 'a second key is the stand-in too')
    local lines2 = 0
    for _, l in ipairs(logs) do
        if l:find('is not in this build', 1, true) then lines2 = lines2 + 1 end
    end
    eq(lines2, lines, 'and the console said it once')
    eq(errored(), nil, 'and no loop errored')
end

describe('round 6: with the pack, a Yubikey is the owner\'s blitz_seckey, as authored')
do
    reset()
    cd.blitz_seckey = true
    requested = {}
    local w = keyWire()
    add(w)
    frames(10)
    local h, name = bodyAt(w.x, w.y)
    eq(name, 'blitz_seckey', 'the owner\'s prop is built')
    eq(h and scaledTo[h], CT.art.keyScale, 'at the art block\'s keyScale')
    eq(CT.art.keyScale, 1.0, 'which is his own size: 24 cm long, a pistol\'s length')
    local asked = false
    for _, n in ipairs(requested) do if n == KEY_STANDIN then asked = true end end
    eq(asked, false, 'and the stand-in is never streamed')
end

describe('round 6: the owner\'s prop that never streams is written off, and keys are the stand-in')
do
    reset()
    cd.blitz_seckey = true
    noStream.blitz_seckey = true
    -- Not resident from the block before: this client never got it.
    loaded[GetHashKey('blitz_seckey')] = nil
    logs = {}
    local w = keyWire()
    add(w)
    frames(260)
    local h, name = bodyAt(w.x, w.y)
    eq(name, KEY_STANDIN, 'a key whose prop would not stream is the stand-in')
    eq(h and scaledTo[h], CT.art.keyFallbackScale, 'at the stand-in\'s scale')
    ok(said('the Yubikey prop blitz_seckey did not stream'), 'and the console says so')
    requested = {}
    local w2 = keyWire(3.5)
    add(w2)
    frames(10)
    local _, name2 = bodyAt(w2.x, w2.y)
    eq(name2, KEY_STANDIN, 'the next key is the stand-in at once')
    local again = false
    for _, n in ipairs(requested) do if n == 'blitz_seckey' then again = true end end
    eq(again, false, 'without asking for the written-off prop again')
    noStream.blitz_seckey = nil
    eq(errored(), nil, 'and no loop errored')
end

describe('round 6: the stand-in is a model the game has, and not the one that drew nothing')
do
    eq(CT.art.keyFallbackProp, KEY_STANDIN, 'the art block names the stock USB stick')
    ok(CT.art.keyProp ~= 'prop_cs_usb_drive' and CT.art.keyFallbackProp ~= 'prop_cs_usb_drive',
        'and prop_cs_usb_drive -- no model at all -- is gone from it')
end

-- ----------------------------------------------------------------- result ---

print = realPrint
io.write(('%s%d passed%s'):format('\27[32m', pass, '\27[0m'))
if fail > 0 then
    io.write(('  %s%d failed%s\n'):format('\27[31m', fail, '\27[0m'))
    os.exit(1)
end
io.write('\n')
