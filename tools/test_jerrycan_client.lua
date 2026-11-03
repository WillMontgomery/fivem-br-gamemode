-- Unit tests for the Season 2 jerry can's client (#217):
-- br_core/client/jerrycan.lua and br_core/client/enginehold.lua over modeled
-- natives.
--
-- The property is a SEQUENCE, not a value -- which natives are called, when,
-- how often, and what the world holds after each step -- so the files run in a
-- Lua environment of their own over a modeled engine: vehicles (each this
-- client's own copy, with its engine, its two latches, its freeze, its driver,
-- its owner and its bones), peds in and out of scope, local objects and what
-- they are attached to, streamed models and dictionaries, the three loop bands
-- with the FRAME callbacks that come and go, timers, the season and the
-- inventory mirror. Each block boots a fresh client. The configs are the real
-- ones (br_lib/config/loot.lua's row and UseEmotes, br_lib/config/fuel.lua's
-- jerryCan table), and so are BR.JerryCanSolve and client/tunekeys.lua.
--
--   A. the hold count   BR.EngineHold as a state machine: the EMP and the can
--                       on one car in both orders, the last release frees, a
--                       release by a non-holder writes nothing, out of scope
--                       drops the record, `restart`, and `free`
--   B. FUEL_CAN         the hold and the end, and nothing else, taken on (no
--                       hold on Season 1); the hold to the driver, or the owner
--                       when nobody drives, and to nobody else; the entering
--                       event and its 250 ms and 1 s; a running engine stalled
--                       again; every end and its release; the window; a newer
--                       pour's hold; the deadline, the lobby, the season and the
--                       resource stop. Every pour here is what the server sends:
--                       its hold first, then its end
--   C. the cans         one local can a pour, on the pourer's hand, from the
--                       use entry; the pourer's own following the channel;
--                       streamed on the pass; gone on every ending
--   D. the finder       BR.JerryCan.target over modeled bones
--   E. the marker       one DrawMarker a frame, and none without a point
--   F. the idle pass    no native and nothing allocated
--   G. /brjerrytune     the toggle, the six numbers, the paste line
--   H. the files        client/fuel.lua's guard; no client freeze; the scope
--                       markers; a can never networked
--
-- Run via tools/verify.sh, or directly:  lua tools/test_jerrycan_client.lua

local realPrint = print
local ROOT = 'resources/[fivem-royale]/'

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
local function near(got, want, name, eps)
    ok(type(got) == 'number' and math.abs(got - want) <= (eps or 1e-9), name,
        ('got %s, want %s'):format(tostring(got), tostring(want)))
end

local function readFile(path)
    local fh = io.open(path, 'rb')
    if not fh then return nil end
    local s = fh:read('a')
    fh:close()
    return s
end

-- ------------------------------------------------------------- the engine ---

--- GET_HASH_KEY, modeled: a stable integer per name.
local function hashOf(s)
    local h = 7
    for i = 1, #s do h = (h * 31 + s:byte(i)) % 2147483647 end
    return h
end

--- GET_PED_BONE_INDEX, modeled: an index that is NOT the bone's ID, so an
--- attach handed the ID instead is caught.
local function boneIndexOf(id) return id * 10 + 1 end

--- Boot a client. opts: season (1 or 2), streamPasses (passes a model takes to
--- stream after its request; math.huge never), inCd (the model is on the
--- build; default true), noDicts (no dictionary on the build).
local function boot(opts)
    opts = opts or {}
    local W = {
        now = 100000, natives = 0, calls = {}, season = opts.season or 2,
        ped = 77, at = { x = 0.0, y = 0.0, z = 30.0 }, offFoot = false,
        players = {}, ents = {}, nextEnt = 5000,
        loaded = {}, pending = {}, requested = {}, released = {},
        streamPasses = opts.streamPasses or 0, inCd = opts.inCd ~= false,
        dicts = {}, anims = {}, attaches = {}, freezes = {}, draws = {},
        handlers = {}, nets = {}, loops = { frame = {}, tick = {}, slow = {} },
        commands = {}, timers = {}, printed = {}, levels = {},
        inv = { slots = { false, false, false, false, false }, active = 0, using = nil },
        down = {}, claims = {}, readout = {},
    }
    W.ents[W.ped] = { kind = 'ped' }
    -- This player's own server id (BR.State.me.src, below) resolves to their
    -- own ped, as it does in game -- so a can hung on them from FUEL_CAN as
    -- well as from their channel would show here as a second can.
    W.players[7] = W.ped
    local env = setmetatable({}, { __index = _G })
    local function n(name)
        W.natives = W.natives + 1
        W.calls[name] = (W.calls[name] or 0) + 1
    end
    local function car(h) local e = W.ents[h] return (e and e.kind == 'veh') and e or nil end

    env.print = function(s) W.printed[#W.printed + 1] = tostring(s) end
    env.GetGameTimer = function() return W.now end
    env.GetCurrentResourceName = function() return 'br_core' end
    env.PlayerPedId = function() n('PlayerPedId') return W.ped end
    env.GetEntityCoords = function(h)
        n('GetEntityCoords')
        if h == W.ped then return { x = W.at.x, y = W.at.y, z = W.at.z } end
        local e = W.ents[h]
        return e and { x = e.x or 0.0, y = e.y or 0.0, z = e.z or 0.0 } or { x = 0.0, y = 0.0, z = 0.0 }
    end
    env.DoesEntityExist = function(h) n('DoesEntityExist') return W.ents[h] ~= nil and 1 or 0 end

    -- THE VEHICLES. BOOLs answer 1/0, as they may in game.
    env.GetGamePool = function(kind)
        n('GetGamePool')
        local out = {}
        if kind == 'CVehicle' then
            for h, e in pairs(W.ents) do if e.kind == 'veh' then out[#out + 1] = h end end
            table.sort(out)
        end
        return out
    end
    env.NetworkGetNetworkIdFromEntity = function(h) n('NetworkGetNetworkIdFromEntity') local e = W.ents[h] return e and e.net or 0 end
    env.NetworkDoesNetworkIdExist = function(net)
        n('NetworkDoesNetworkIdExist')
        for _, e in pairs(W.ents) do if e.net == net and net ~= 0 then return 1 end end
        return 0
    end
    env.NetworkGetEntityFromNetworkId = function(net)
        n('NetworkGetEntityFromNetworkId')
        for h, e in pairs(W.ents) do if e.net == net and net ~= 0 then return h end end
        return 0
    end
    env.GetVehicleClass = function(h) n('GetVehicleClass') local c = car(h) return c and c.class or 0 end
    env.IsEntityDead = function(h) n('IsEntityDead') local c = car(h) return (c and c.dead) and 1 or 0 end
    env.DoesVehicleUseFuel = function(h) n('DoesVehicleUseFuel') local c = car(h) return (c and c.usesFuel ~= false) and 1 or 0 end
    env.GetEntityBoneIndexByName = function(h, name)
        n('GetEntityBoneIndexByName')
        local c = car(h)
        local i = c and c.boneIdx[name]
        return i == nil and -1 or i
    end
    env.GetWorldPositionOfEntityBone = function(h, idx)
        n('GetWorldPositionOfEntityBone')
        local c = car(h)
        local b = c and c.boneAt[idx]
        return b and { x = b.x, y = b.y, z = b.z } or { x = 0.0, y = 0.0, z = 0.0 }
    end
    env.GetPedInVehicleSeat = function(h, seat)
        n('GetPedInVehicleSeat')
        local c = car(h)
        if not c then return 0 end
        if seat == -1 then return c.driver or 0 end
        return (c.seats and c.seats[seat]) or 0
    end
    env.NetworkHasControlOfEntity = function(h) n('NetworkHasControlOfEntity') local c = car(h) return (c and c.owner) and 1 or 0 end
    env.GetIsVehicleEngineRunning = function(h) n('GetIsVehicleEngineRunning') local c = car(h) return (c and c.engine) and 1 or 0 end
    env.SetVehicleEngineOn = function(h, on, instantly, noAuto)
        n('SetVehicleEngineOn')
        local c = car(h)
        if c then c.engine, c.noAutoStart, c.writes = on, noAuto, (c.writes or 0) + 1 end
    end
    env.SetVehicleUndriveable = function(h, v)
        n('SetVehicleUndriveable')
        local c = car(h)
        if c then c.undriveable, c.writes = v, (c.writes or 0) + 1 end
    end
    env.IsEntityPositionFrozen = function(h) n('IsEntityPositionFrozen') local e = W.ents[h] return (e and e.frozen) and 1 or 0 end
    env.FreezeEntityPosition = function(h, f)
        n('FreezeEntityPosition')
        W.freezes[#W.freezes + 1] = { ent = h, frozen = f }
        local e = W.ents[h]
        if e then e.frozen = f end
    end

    -- THE PLAYERS: a server id is in scope when it has a ped here.
    env.GetPlayerFromServerId = function(src) n('GetPlayerFromServerId') return W.players[src] and src or -1 end
    env.GetPlayerPed = function(ply) n('GetPlayerPed') return W.players[ply] or 0 end

    -- THE CAN: a model to stream, a local object, an attachment.
    env.GetHashKey = function(s) n('GetHashKey') return hashOf(s) end
    env.IsModelInCdimage = function() n('IsModelInCdimage') return W.inCd and 1 or 0 end
    env.HasModelLoaded = function(h)
        n('HasModelLoaded')
        if W.loaded[h] then return 1 end
        local p = W.pending[h]
        if p ~= nil then
            if p <= 0 then W.loaded[h], W.pending[h] = true, nil return 1 end
            W.pending[h] = p - 1
        end
        return 0
    end
    env.RequestModel = function(h)
        n('RequestModel')
        W.requested[h] = (W.requested[h] or 0) + 1
        if W.pending[h] == nil and not W.loaded[h] then W.pending[h] = W.streamPasses end
    end
    env.SetModelAsNoLongerNeeded = function(h)
        n('SetModelAsNoLongerNeeded')
        W.released[h] = (W.released[h] or 0) + 1
        W.pending[h] = nil
    end
    env.CreateObject = function(hash, x, y, z, net, mission, door)
        n('CreateObject')
        W.nextEnt = W.nextEnt + 1
        W.ents[W.nextEnt] = { kind = 'obj', model = hash, x = x, y = y, z = z,
                              net = 0, networked = net, mission = mission, door = door }
        return W.nextEnt
    end
    env.GetPedBoneIndex = function(_, id) n('GetPedBoneIndex') return boneIndexOf(id) end
    env.AttachEntityToEntity = function(obj, to, bone, x, y, z, rx, ry, rz, p9, soft, coll, isPed, order, fixed)
        n('AttachEntityToEntity')
        local a = { obj = obj, to = to, bone = bone, x = x, y = y, z = z, rx = rx, ry = ry, rz = rz,
                    p9 = p9, soft = soft, coll = coll, isPed = isPed, order = order, fixed = fixed }
        W.attaches[#W.attaches + 1] = a
        local e = W.ents[obj]
        if e then e.attached = a end
    end
    env.DetachEntity = function(obj) n('DetachEntity') local e = W.ents[obj] if e then e.attached = nil end end
    env.DeleteEntity = function(h) n('DeleteEntity') W.ents[h] = nil end

    -- THE TUNER'S CLIP.
    env.DoesAnimDictExist = function() n('DoesAnimDictExist') return opts.noDicts and 0 or 1 end
    env.HasAnimDictLoaded = function(d) n('HasAnimDictLoaded') return W.dicts[d] and 1 or 0 end
    env.RequestAnimDict = function(d) n('RequestAnimDict') W.dicts[d] = true end
    env.RemoveAnimDict = function(d) n('RemoveAnimDict') W.dicts[d] = nil end
    env.TaskPlayAnim = function(ped, d, c, _, _, dur, flag)
        n('TaskPlayAnim')
        W.anims[ped] = { dict = d, clip = c, dur = dur, flag = flag }
    end
    env.StopAnimTask = function(ped, d, c)
        n('StopAnimTask')
        local a = W.anims[ped]
        if a and a.dict == d and a.clip == c then W.anims[ped] = nil end
    end
    env.IsEntityPlayingAnim = function(ped, d, c)
        n('IsEntityPlayingAnim')
        local a = W.anims[ped]
        return (a and a.dict == d and a.clip == c) and 1 or 0
    end

    -- THE MARKER.
    env.DrawMarker = function(...)
        n('DrawMarker')
        W.draws[#W.draws + 1] = { ... }
    end

    -- THE KEYS (client/tunekeys.lua's): what is held, claimed and drawn.
    env.IsDisabledControlPressed = function(_, id) return W.down[id] and 1 or 0 end
    env.DisableControlAction = function(_, id) W.claims[id] = (W.claims[id] or 0) + 1 end
    for _, name in ipairs({ 'SetTextFont', 'SetTextScale', 'SetTextColour', 'SetTextDropshadow',
                            'SetTextEdge', 'SetTextDropShadow', 'SetTextOutline',
                            'BeginTextCommandDisplayText' }) do
        env[name] = function() end
    end
    local pendingText = nil
    env.AddTextComponentSubstringPlayerName = function(s) pendingText = s end
    env.EndTextCommandDisplayText = function() W.readout[#W.readout + 1] = pendingText end

    -- THE RUNTIME.
    env.RegisterNetEvent = function(name) W.nets[name] = true end
    env.AddEventHandler = function(name, fn)
        W.handlers[name] = W.handlers[name] or {}
        table.insert(W.handlers[name], fn)
    end
    env.RegisterCommand = function(name, fn) W.commands[name] = fn end
    env.TriggerServerEvent = function() W.server = (W.server or 0) + 1 end
    env.Citizen = { SetTimeout = function(ms, fn) W.timers[#W.timers + 1] = { at = W.now + ms, fn = fn } end }

    env.BR = {}
    for _, f in ipairs({ 'br_lib/shared/enums.lua', 'br_lib/shared/protocol.lua',
                         'br_lib/config/loot.lua', 'br_lib/config/fuel.lua',
                         'br_lib/shared/jerrycan_solve.lua' }) do
        assert(loadfile(ROOT .. f, 't', env))()
    end
    local B = env.BR
    -- THE SPIES on the shared finder's two rules, so D can say they were used.
    W.solved = { anchorBones = 0, nearestAnchor = 0 }
    local JS = B.JerryCanSolve
    local realBones, realNearest = JS.anchorBones, JS.nearestAnchor
    JS.anchorBones = function(...) W.solved.anchorBones = W.solved.anchorBones + 1 return realBones(...) end
    JS.nearestAnchor = function(...) W.solved.nearestAnchor = W.solved.nearestAnchor + 1 return realNearest(...) end

    B.Season = {
        has = function(id)
            if id ~= 'jerrycan' then error('asked ' .. tostring(id)) end
            return W.season ~= nil and W.season >= 2
        end,
    }
    B.State = { me = { src = 7, state = B.PlayerState.ALIVE } }
    local loopId = 0
    B.Loop = {
        FRAME = 'frame', TICK = 'tick', SLOW = 'slow',
        register = function(band, name, fn)
            for _, e in pairs(W.loops[band]) do
                ok(e.name ~= name, 'no callback registered twice by name', name)
            end
            loopId = loopId + 1
            local e = { name = name, fn = fn, id = loopId }
            W.loops[band][loopId] = e
            return e
        end,
        unregister = function(e)
            for _, list in pairs(W.loops) do
                for id, x in pairs(list) do if x == e then list[id] = nil end end
            end
        end,
    }
    -- The inventory mirror and its on-foot answer (client/inventory.lua's), and
    -- the gauge's reading (client/fuel.lua's): stand-ins, read at call time.
    B.Inv = {
        local_ = function() return W.inv end,
        offFoot = function() return W.offFoot end,
    }
    B.Fuel = { levelPct = function(veh) local v = W.levels[veh] if v == nil then return 50.0 end return v end }

    assert(loadfile(ROOT .. 'br_core/client/tunekeys.lua', 't', env))()
    assert(loadfile(ROOT .. 'br_core/client/enginehold.lua', 't', env))()
    assert(loadfile(ROOT .. 'br_core/client/jerrycan.lua', 't', env))()
    W.env, W.B, W.E, W.JC = env, B, B.EngineHold, B.JerryCan
    W.J = B.Config.Fuel.jerryCan

    --- A vehicle this client knows. o: net, x, y, z, class, driver, owner,
    --- engine, frozen, dead, usesFuel, bones = { { name, x, y, z }, ... } --
    --- the first bone is index 0, a real bone.
    function W.car(o)
        W.nextEnt = W.nextEnt + 1
        local c = { kind = 'veh', net = o.net or 0, x = o.x or 0.0, y = o.y or 0.0, z = o.z or 30.0,
                    class = o.class or 1, driver = o.driver or 0, owner = o.owner == true,
                    engine = o.engine == true, frozen = o.frozen == true, dead = o.dead == true,
                    usesFuel = o.usesFuel, boneIdx = {}, boneAt = {}, seats = {} }
        for i, b in ipairs(o.bones or {}) do
            c.boneIdx[b[1]] = i - 1
            c.boneAt[i - 1] = { x = b[2], y = b[3], z = b[4] }
        end
        W.ents[W.nextEnt] = c
        return W.nextEnt, c
    end
    --- Another player, in scope: their ped here.
    function W.player(src)
        W.nextEnt = W.nextEnt + 1
        W.ents[W.nextEnt] = { kind = 'ped' }
        W.players[src] = W.nextEnt
        return W.nextEnt
    end

    local function step(band)
        local ids = {}
        for id in pairs(W.loops[band]) do ids[#ids + 1] = id end
        table.sort(ids)
        for _, id in ipairs(ids) do
            local e = W.loops[band][id]
            if e then e.fn() end
        end
    end
    --- Move the clock, running every timer that falls due.
    function W.advance(ms)
        local target = W.now + (ms or 0)
        while true do
            local best, bi = nil, nil
            for i, t in ipairs(W.timers) do
                if t.at <= target and (best == nil or t.at < best.at) then best, bi = t, i end
            end
            if not best then break end
            table.remove(W.timers, bi)
            W.now = math.max(W.now, best.at)
            best.fn()
        end
        W.now = target
    end
    function W.tick(ms) W.advance(ms or 100) step('tick') end
    function W.ticks(k, ms) for _ = 1, k do W.tick(ms) end end
    function W.frame() step('frame') end
    function W.has(band, name)
        for _, e in pairs(W.loops[band]) do if e.name == name then return true end end
        return false
    end
    function W.loop(band, name)
        for _, e in pairs(W.loops[band]) do if e.name == name then return e.fn end end
    end
    function W.fire(name, ...)
        for _, fn in ipairs(W.handlers[name] or {}) do fn(...) end
    end
    --- One FUEL_CAN message: a hold (`hold` true), or the end (ms 0) -- the two
    --- the server sends. Anything else is a message it does not send, which
    --- only B's first block hands the handler.
    function W.can(id, net, p, ms, hold)
        W.fire(B.Net.FUEL_CAN, { id = id, n = net, p = p, ms = ms, hold = hold })
    end
    --- This player gets in: the seat taken, and the game's entering event.
    function W.getIn(h, seat)
        local c = W.ents[h]
        if (seat or -1) == -1 then c.driver = W.ped else c.seats[seat] = W.ped end
        W.fire('gameEventTriggered', 'CEventNetworkPlayerEnteredVehicle', { 128, h })
    end
    --- The cans that stand, as { obj, record }.
    function W.objects()
        local out = {}
        for h, e in pairs(W.ents) do if e.kind == 'obj' then out[#out + 1] = { h = h, e = e } end end
        table.sort(out, function(a, b) return a.h < b.h end)
        return out
    end
    function W.stalled(c) return c.engine == false and c.noAutoStart == true and c.undriveable == true end
    function W.freed(c) return c.undriveable == false and c.noAutoStart == false end
    --- The can in a slot, as the server sends it.
    function W.give(slot, active)
        W.inv.slots[slot] = { id = 'jerrycan', kind = B.ItemKind.CONSUMABLE, rarity = 3, count = 1, fill = 1 }
        if active ~= nil then W.inv.active = active end
    end
    return W
end

-- The car most blocks pour into: networked 501, a cap bone 1.2 m from where
-- the player stands, and a rear wheel nearer still.
local function sedan(W, o)
    o = o or {}
    return W.car({ net = o.net or 501, x = o.x or 2.0, y = 0.0, z = 30.0, class = 1,
                   driver = o.driver, owner = o.owner, engine = o.engine, frozen = o.frozen,
                   bones = o.bones or { { 'petroltank', 1.2, 0.0, 30.5 }, { 'wheel_lr', 0.6, 0.3, 30.0 } } })
end

-- ===================================================== A. the hold count ---

describe('A. BR.EngineHold: hold, held, count and list')
do
    local W = boot()
    local E = W.E
    local h1, c1 = W.car({ net = 1001 })
    local h2 = W.car({ net = 1002 })
    local h5 = W.car({ net = 1005 })
    E.hold('emp', 1001, h1)
    ok(W.stalled(c1), 'a hold is the EMP\'s stall: engine off at once, no auto-start, undriveable')
    ok(E.held(1001, 'emp') and E.held(1001) and not E.held(1001, 'jerrycan'),
       'held by that holder, and by somebody, and not by the other')
    eq(E.count(1001), 1, 'one holder')
    E.hold('jerrycan', 1001, h1)
    eq(E.count(1001), 2, 'two holders on one car')
    E.hold('emp', 1005, h5)
    E.hold('emp', 1002, h2)
    eq(table.concat(E.list('emp'), ','), '1001,1002,1005', 'the EMP\'s holds, ascending')
    eq(table.concat(E.list('jerrycan'), ','), '1001', 'the can\'s')
    eq(table.concat(E.list(), ','), '1001,1002,1005', 'and every held car, with no holder named')
    c1.engine, c1.writes = true, 0
    E.hold('jerrycan', 1001, h1)
    ok(c1.engine == false and c1.writes == 2, 'a hold written again is the same two writes: a running engine stops')
    E.hold('emp', 1009, 0)
    eq(E.held(1009), false, 'a hold with no handle here records nothing')
end

describe('A. BR.EngineHold: the EMP and the can on one car, in both orders -- the last release frees')
do
    for _, order in ipairs({ { 'emp', 'jerrycan' }, { 'jerrycan', 'emp' } }) do
        local W = boot()
        local E = W.E
        local h, c = W.car({ net = 2001 })
        E.hold('emp', 2001, h)
        E.hold('jerrycan', 2001, h)
        c.writes = 0
        local first = E.release(order[1], 2001, true)
        ok(first == false and c.writes == 0 and W.stalled(c),
           ('%s lets go first: nothing written, the car still held for %s'):format(order[1], order[2]))
        local last = E.release(order[2], 2001, true)
        ok(last == true and W.freed(c) and c.engine == true,
           ('%s lets go last: the car freed, and started for its driver'):format(order[2]))
        eq(E.count(2001), 0, 'nobody holds it')
    end
end

describe('A. BR.EngineHold: a release by a non-holder writes nothing; out of scope drops the record')
do
    local W = boot()
    local E = W.E
    local h, c = W.car({ net = 3001 })
    E.hold('emp', 3001, h)
    c.writes = 0
    ok(E.release('jerrycan', 3001, true) == false and c.writes == 0 and W.stalled(c),
       'the can never held it: its release writes nothing, and the EMP\'s hold stands')
    ok(E.release('jerrycan', 3999, true) == false, 'a car nobody holds: nothing to release')
    -- OUT OF SCOPE: the car streams out while held.
    W.ents[h] = nil
    W.calls = {}
    ok(E.release('emp', 3001, true) == false, 'out of scope: no free written')
    ok((W.calls.SetVehicleEngineOn or 0) == 0 and (W.calls.SetVehicleUndriveable or 0) == 0,
       'and no write at all')
    eq(E.held(3001), false, 'and the record dropped: the copy it comes back with is fresh')
end

describe('A. BR.EngineHold: `restart`, and the spared driver\'s free')
do
    local W = boot()
    local E = W.E
    local h, c = W.car({ net = 4001 })
    E.hold('jerrycan', 4001, h)
    E.release('jerrycan', 4001, false)
    ok(W.freed(c) and c.engine == false,
       'without restart: driveable, no-auto-start cleared, the engine left as it was (off)')
    c.engine = true
    E.hold('jerrycan', 4001, h)
    c.engine = true                       -- somebody started it under the hold
    E.release('jerrycan', 4001, false)
    ok(W.freed(c) and c.engine == true, 'without restart, a running engine is left running')
    E.hold('emp', 4001, h)
    E.release('emp', 4001, true)
    ok(W.freed(c) and c.engine == true, 'with restart: started for the driver')
    -- THE SPARED DRIVER'S FREE: nothing while anybody holds the car here.
    E.hold('jerrycan', 4001, h)
    c.writes = 0
    ok(E.free(4001, h, true) == false and c.writes == 0 and W.stalled(c),
       'free writes nothing while the can holds the car')
    E.release('jerrycan', 4001, false)
    c.undriveable, c.noAutoStart = true, true            -- somebody else's write
    ok(E.free(4001, h, true) == true and W.freed(c) and c.engine == true,
       'and frees a car nobody holds here, started')
end

-- ======================================================== B. FUEL_CAN ---

describe('B. FUEL_CAN: a hold or an end, and nothing else; and no hold on Season 1')
do
    -- THE SERVER SENDS TWO MESSAGES OF A POUR, its hold and its end, and a
    -- client takes on nothing else. The start the press sent before #217's
    -- review is no message any server sends now, and neither is a hold with
    -- its flag missing or mangled: each is dropped, recording nothing.
    local W = boot()
    local h = sedan(W, { driver = 77, engine = true })
    ok(W.nets[W.B.Net.FUEL_CAN] == true, 'FUEL_CAN is registered as a net event')
    for _, bad in ipairs({ { v = false }, { v = nil }, { v = 'true' }, { v = 1 } }) do
        W.can(1, 501, 9, 5000, bad.v)
        eq(W.JC.state().pours, 0,
           ('a message with `hold` %s and time left is not taken on'):format(tostring(bad.v)))
    end
    eq(W.JC.holds(501), false, 'so nothing holds the car')
    ok(W.ents[h].undriveable == nil and W.ents[h].engine == true, 'and nothing is written to it')
    W.can(1, 501, 9, 5000, true)
    eq(W.JC.state().pours, 1, 'the hold records the pour')
    eq(W.JC.holds(501), true, 'and BR.JerryCan.holds answers for its car')
    eq(W.JC.holds(502), false, 'and for no other')
    W.can(9, 501, 9, 0)
    eq(W.JC.state().pours, 1, 'an end for a pour never held here touches nothing')

    local W1 = boot({ season = 1 })
    sedan(W1)
    W1.can(1, 501, 9, 4000, true)
    eq(W1.JC.state().pours, 0, 'Season 1: a hold is not taken on')
    eq(W1.JC.holds(501), false, 'and nothing holds')
end

describe('B. FUEL_CAN: the hold is the first message a pour sends, and it alone records and holds')
do
    -- THE SERVER SENDS NOTHING AT THE PRESS (server/jerrycan.lua's settle
    -- window): the hold, on the slice that pays, is the first this client hears.
    local W = boot()
    local h, c = sedan(W, { driver = 77, engine = true })
    W.player(9)
    W.can(1, 501, 9, 4750, true)
    eq(W.JC.state().pours, 1, 'a hold with no start before it records the pour')
    eq(W.JC.holds(501), true, 'and BR.JerryCan.holds answers for its car')
    ok(W.stalled(c) and W.E.held(501, 'jerrycan'), 'the driver\'s machine stalls it as the hold lands')
    W.ticks(2)                                   -- the model asked for, then the can
    eq(#W.objects(), 1, 'and the can goes on the pourer\'s hand')
    W.levels[h] = 40.0
    W.can(1, 501, 9, 0)
    ok(W.freed(c) and c.engine == true and #W.objects() == 0 and W.JC.state().pours == 0,
       'its end lets all of it go: the driver started again, the can off')
end

describe('B. FUEL_CAN: the hold goes to the driver, or the owner when nobody drives, and to nobody else')
do
    -- THIS PLAYER DRIVES.
    local W = boot()
    local h, c = sedan(W, { driver = 77, engine = true })
    W.can(1, 501, 9, 4700, true)
    ok(W.stalled(c), 'the driver\'s machine: stalled as the hold lands')
    eq(W.E.held(501, 'jerrycan'), true, 'held under the can\'s name')

    -- NOBODY DRIVES, AND THIS MACHINE OWNS IT.
    W = boot()
    h, c = sedan(W, { owner = true, engine = true })
    W.can(1, 501, 9, 4700, true)
    ok(W.stalled(c), 'nobody driving: the owner\'s machine stalls it')

    -- A PASSENGER, NOT THE OWNER, WITH NOBODY DRIVING.
    W = boot()
    h, c = sedan(W, { engine = true })
    c.seats[0] = 77
    W.can(1, 501, 9, 4700, true)
    ok(c.undriveable == nil and c.engine == true and not W.E.held(501),
       'a passenger whose machine does not own the car writes nothing')

    -- SOMEBODY ELSE DRIVES, AND THIS MACHINE OWNS IT ANYWAY.
    W = boot()
    h, c = sedan(W, { driver = 901, owner = true, engine = true })
    W.can(1, 501, 9, 4700, true)
    ok(c.undriveable == nil and not W.E.held(501),
       'another player drives: their machine holds it, this one writes nothing')

    -- A BYSTANDER.
    W = boot()
    h, c = sedan(W, { engine = true })
    W.can(1, 501, 9, 4700, true)
    ok(c.undriveable == nil and c.engine == true, 'a bystander writes nothing')
    local _ = h
end

describe('B. FUEL_CAN: getting in holds it again, at once and 250 ms and 1 s later')
do
    local W = boot()
    local h, c = sedan(W, { engine = false })
    W.can(1, 501, 9, 4700, true)
    eq(c.undriveable, nil, 'a bystander at the hold: nothing written')
    c.engine = true                              -- the auto-start as the seat is taken
    W.getIn(h)
    ok(W.stalled(c), 'getting into the driver\'s seat: stalled at once')
    c.engine = true                              -- the old owner's sync, before ownership moved
    W.advance(250)
    ok(W.stalled(c), 'and again 250 ms later')
    c.engine = true
    W.advance(750)
    ok(W.stalled(c), 'and again 1 s later')
    eq(#W.timers, 0, 'two timers, both spent')
    -- A PASSENGER GETTING IN, with somebody else at the wheel: nothing.
    local W2 = boot()
    local h2, c2 = sedan(W2, { driver = 901, engine = true })
    W2.can(1, 501, 9, 4700, true)
    W2.getIn(h2, 0)
    W2.advance(1000)
    ok(c2.undriveable == nil and c2.engine == true, 'a passenger getting in writes nothing')
end

describe('B. FUEL_CAN: a running engine is stalled again within a second')
do
    local W = boot()
    local _, c = sedan(W, { driver = 77 })
    W.can(1, 501, 9, 8700, true)
    ok(W.stalled(c), 'held')
    c.engine = true                              -- started under the hold
    W.ticks(10)
    ok(W.stalled(c), 'a second of passes: stalled again')
    W.calls = {}
    W.ticks(10)
    ok((W.calls.SetVehicleEngineOn or 0) == 0, 'and a hold that stands is not written again')

    -- OWNERSHIP ARRIVES WITH NOBODY DRIVING: the once-a-second look takes it.
    W = boot()
    local _, c2 = sedan(W, { engine = true })
    W.can(1, 501, 9, 8700, true)
    eq(c2.undriveable, nil, 'a bystander at the hold: nothing written')
    c2.owner = true                              -- the old owner left; this machine has it
    W.ticks(10)
    ok(W.stalled(c2), 'ownership of an empty car reaches this machine: held within a second')

    -- THE MACHINE THAT WROTE A HOLD KEEPS IT UNTIL THE POUR ENDS THERE.
    W = boot()
    local _, c3 = sedan(W, { driver = 77 })
    W.can(1, 501, 9, 8700, true)
    c3.driver = 0                                -- this player gets out, mid-pour
    W.ticks(20)
    ok(W.stalled(c3) and W.E.held(501, 'jerrycan'), 'out of the seat, its hold stands here')
    W.can(1, 501, 9, 0)
    ok(W.freed(c3) and c3.engine == false and not W.E.held(501),
       'and the end lets it go -- not started, for a player no longer at the wheel')

    -- GETTING INTO A CAR WITH NO POUR KNOWN costs nothing.
    W = boot()
    local hh = sedan(W)
    W.natives = 0
    W.getIn(hh)
    eq(W.natives, 0, 'with no pour known, the entering event calls no native')
end

describe('B. FUEL_CAN: the end releases -- the driver started again, unless the tank is dry or the EMP holds them')
do
    -- THE DRIVER, FUEL IN THE TANK.
    local W = boot()
    local h, c = sedan(W, { driver = 77 })
    W.levels[h] = 40.0
    W.can(1, 501, 9, 4700, true)
    W.can(1, 501, 9, 0)
    ok(W.freed(c) and c.engine == true, 'a seated driver with fuel: freed, and the engine started')
    eq(W.JC.state().pours, 0, 'the pour forgotten')
    eq(W.JC.holds(501), false, 'and nothing holds the car')

    -- A DRY TANK.
    W = boot()
    h, c = sedan(W, { driver = 77 })
    W.levels[h] = 0
    W.can(1, 501, 9, 4700, true)
    W.can(1, 501, 9, 0)
    ok(W.freed(c) and c.engine == false, 'a dry tank: freed, the engine left off')

    -- THE EMP STALLS THEIR DRIVING TOO.
    W = boot()
    h, c = sedan(W, { driver = 77 })
    W.can(1, 501, 9, 4700, true)
    W.E.hold('emp', 501, h)
    W.can(1, 501, 9, 0)
    ok(W.stalled(c) and W.E.held(501, 'emp'), 'the EMP still holds them: nothing freed')

    -- THE OWNER, NOBODY DRIVING: no-auto-start cleared, the engine as it was.
    W = boot()
    h, c = sedan(W, { owner = true })
    W.can(1, 501, 9, 4700, true)
    W.can(1, 501, 9, 0)
    ok(W.freed(c) and c.engine == false, 'a non-driver\'s hold: no-auto-start cleared, not started')
end

describe('B. FUEL_CAN: every client unfreezes its frozen copy at the end, and the window catches a late one')
do
    -- A BYSTANDER'S COPY, FROZEN BY THE SERVER'S RPC.
    local W = boot()
    local _, c = sedan(W, { frozen = true })
    W.can(1, 501, 9, 4700, true)
    W.can(1, 501, 9, 0)
    eq(c.frozen, false, 'a frozen copy is unfrozen at the end, by every client')
    for _, f in ipairs(W.freezes) do
        ok(f.frozen == false, 'and no client ever writes a freeze', tostring(f.frozen))
    end
    eq(W.JC.state().windows, 1, 'and the car\'s release window opens')

    -- THE WINDOW: an inherited freeze on a copy this machine owns is undone.
    c.owner, c.frozen = true, true
    W.tick()
    eq(c.frozen, false, 'inside the window, an owned copy found frozen is unfrozen')
    c.owner, c.frozen = false, true
    W.tick()
    eq(c.frozen, true, 'a copy this machine does not own is left: its owner unfreezes it')
    c.owner = true
    W.ticks(20)
    eq(W.JC.state().windows, 0, 'two seconds on, the window has shut')
    c.frozen = true
    W.tick()
    eq(c.frozen, true, 'and a freeze after it is not this client\'s business')

    -- A NEW POUR'S HOLD SHUTS IT: a re-press inside the window. The server
    -- sends nothing at the press, so the new pour's first message is its hold,
    -- on the pass its freeze goes out -- and the hold alone has to shut the
    -- window, or this machine, which owns the car, would undo that freeze on
    -- its next pass.
    W = boot()
    _, c = sedan(W, { owner = true })
    W.can(1, 501, 9, 4700, true)
    W.can(1, 501, 9, 0)
    eq(W.JC.state().windows, 1, 'the end opens the window')
    c.frozen = true                                  -- the new pour's freeze, landed first
    W.can(2, 501, 9, 4750, true)
    eq(W.JC.state().windows, 0, 'the new pour\'s hold, its first message, shuts it')
    W.tick()
    eq(c.frozen, true, 'so the new pour\'s freeze stands on the next pass')
    W.ticks(5)
    eq(c.frozen, true, 'and on every pass after it')
end

describe('B. FUEL_CAN: a newer pour\'s hold ends the older one here, and leaves the car held for it')
do
    -- AN OLDER RECORD STILL STANDING IS ONE WHOSE END THIS CLIENT MISSED: the
    -- server holds one pour per car. The newer pour's hold -- its first message
    -- -- takes the older one's can off and hands the car over, still stalled
    -- and still frozen: the newer pour's freeze RPC goes out on the same pass as
    -- its hold and may land first. Finishing the older pour there instead
    -- unfroze that freeze, and started a seated driver's engine for the newer
    -- hold to stall again.
    local W = boot()
    local h, c = sedan(W, { driver = 77, owner = true })
    W.player(9)
    W.levels[h] = 40.0
    W.can(1, 501, 9, 4700, true)
    W.ticks(2)                                   -- the model asked for, then the can
    ok(W.stalled(c) and #W.objects() == 1, 'the first pour: held, and its can on the pourer')
    c.frozen = true                              -- its end missed; the newer pour's freeze lands
    W.calls = {}
    W.can(2, 501, 9, 4750, true)
    local s = W.JC.state()
    ok(s.pours == 1 and s.windows == 0, 'the newer pour\'s hold ends the older one: one pour known, no window',
       ('%d pour(s), %d window(s)'):format(s.pours, s.windows))
    eq(#W.objects(), 0, 'and the older pour\'s can is gone')
    ok(W.stalled(c) and (W.calls.SetVehicleEngineOn or 0) == 0,
       'the driver held throughout: never started, so never stalled again')
    eq(c.frozen, true, 'and the car still frozen for the newer pour')
    W.ticks(3)
    ok(c.frozen == true and W.stalled(c), 'on the passes after it too')
    W.can(1, 501, 9, 0)
    ok(W.stalled(c) and c.frozen == true and W.JC.state().pours == 1,
       'and the older pour\'s late end touches nothing')
    W.can(2, 501, 9, 0)
    ok(W.freed(c) and c.engine == true and c.frozen == false and W.JC.state().pours == 0,
       'the newer pour\'s own end lets all of it go: the driver started again, the car unfrozen')
end

describe('B. FUEL_CAN: the deadline, the lobby, the season and the resource stop each leave nothing held')
do
    --- A pour in full: this machine drives, the copy frozen, the can on the
    --- pourer's hand.
    local function full()
        local W = boot()
        local h, c = sedan(W, { driver = 77, frozen = true })
        W.player(9)
        W.can(1, 501, 9, 4700, true)
        local heldAt = W.now
        W.ticks(2)                               -- the model asked for, then the can
        ok(W.stalled(c) and c.frozen == true and #W.objects() == 1,
           'set up: held, frozen and a can in hand')
        return W, h, c, heldAt
    end
    local function clean(W, c, label)
        ok(c.frozen == false and c.undriveable == false and #W.objects() == 0
           and W.JC.state().pours == 0 and not W.E.held(501),
           label .. ': nothing frozen, undriveable or attached',
           ('frozen %s, undriveable %s, %d can(s), %d pour(s)'):format(tostring(c.frozen),
               tostring(c.undriveable), #W.objects(), W.JC.state().pours))
    end

    -- THE DEADLINE: the hold's ms (4700) plus releaseGraceMs past its arrival.
    local W, _, c, heldAt = full()
    local due = heldAt + 4700 + W.J.releaseGraceMs
    W.advance(due - 1 - W.now)
    W.tick(0)
    eq(W.JC.state().pours, 1, 'a millisecond before the deadline: still in force')
    eq(W.JC.holds(501), true, 'and BR.JerryCan.holds still answers yes')
    W.tick(1)
    clean(W, c, 'the deadline, with no end received')

    W, _, c = full()
    W.B.State.me.state = W.B.PlayerState.LOBBY
    W.tick()
    clean(W, c, 'the lobby')

    W, _, c = full()
    W.season = 1
    W.tick()
    clean(W, c, 'the season going off')

    W, _, c = full()
    W.fire('onClientResourceStop', 'another_resource')
    eq(W.JC.state().pours, 1, 'another resource stopping: nothing')
    W.fire('onClientResourceStop', 'br_core')
    clean(W, c, 'br_core stopping')

    -- AN END IS ALWAYS HONORED, the season gone off before any pass saw it.
    W, _, c = full()
    W.season = 1
    W.can(1, 501, 9, 0)
    clean(W, c, 'the end, on a season that just went off')
end

-- ========================================================== C. the cans ---

describe('C. the cans: one local can a pour, on the pourer\'s hand, from the use entry')
do
    local W = boot()
    sedan(W)
    local p9 = W.player(9)
    W.can(1, 501, 9, 5000, true)
    eq(#W.objects(), 0, 'nothing made inside the message: the pass makes it')
    W.tick()
    eq(#W.objects(), 0, 'the first pass asks for the model and waits for nothing')
    W.tick()
    local objs = W.objects()
    eq(#objs, 1, 'the next pass: one can')
    local o = objs[1] and objs[1].e or {}
    local row = W.B.Config.UseEmotes.jerrycan
    local e = row[row.use]
    eq(o.model, hashOf(W.B.Config.ConsumableById.jerrycan.prop), 'the item row\'s prop, w_am_jerrycan')
    ok(o.networked == false and o.mission == false and o.door == false,
       'LOCAL: created with every network flag false (sv_entityLockdown relaxed)')
    local a = o.attached or {}
    eq(a.to, p9, 'on the pourer\'s ped')
    eq(a.bone, boneIndexOf(e.bone), 'at GetPedBoneIndex of the entry\'s bone, never the bone ID')
    ok(a.x == e.pos.x and a.y == e.pos.y and a.z == e.pos.z
       and a.rx == e.rot.x and a.ry == e.rot.y and a.rz == e.rot.z,
       'at the entry\'s pos and rot', ('%s %s %s / %s %s %s'):format(a.x, a.y, a.z, a.rx, a.ry, a.rz))
    ok(a.p9 == true and a.soft == true and a.coll == false and a.isPed == true
       and a.order == 1 and a.fixed == true,
       'attached as rpemotes-reborn attaches it, rotation order 1, no collision')
    W.ticks(10)
    eq(#W.objects(), 1, 'and ten passes later it is still the one can')
    eq(W.calls.CreateObject, 1, 'made once')

    -- TWO POURERS, TWO CANS.
    W.player(10)
    sedan(W, { net = 502, x = -2.0 })
    W.can(2, 502, 10, 5000, true)
    W.tick()
    eq(#W.objects(), 2, 'a second pourer\'s can beside the first')
end

describe('C. the cans: streamed on the pass, never waited for -- and a model that never comes is let go')
do
    local W = boot({ streamPasses = 2 })
    sedan(W)
    W.player(9)
    W.can(1, 501, 9, 5000, true)
    W.tick()
    local hash = hashOf('w_am_jerrycan')
    ok(W.requested[hash] == 1 and #W.objects() == 0, 'the first pass asks for the model, and makes nothing')
    W.ticks(3)
    ok(#W.objects() == 1 and W.requested[hash] == 1, 'a later pass makes the can, the model asked for once')
    ok((W.released[hash] or 0) >= 1, 'and the request is let go once the can is made')

    W = boot({ streamPasses = math.huge })
    sedan(W)
    W.player(9)
    W.can(1, 501, 9, 9000, true)
    W.ticks(25)
    ok(#W.objects() == 0 and W.requested[hash] == 1 and (W.released[hash] or 0) == 1,
       'a model that never streams is asked for once and let go after two seconds',
       ('%d requested, %d let go'):format(W.requested[hash] or 0, W.released[hash] or 0))
    W.ticks(20)
    eq(W.requested[hash], 1, 'and that pour does not ask again: it goes without a can')

    W = boot({ inCd = false })
    sedan(W)
    W.player(9)
    W.can(1, 501, 9, 9000, true)
    W.ticks(5)
    ok(#W.objects() == 0 and (W.requested[hash] or 0) == 0,
       'a model the build does not have is never requested')
end

describe('C. the cans: attached when the pourer streams in, gone when they stream out')
do
    local W = boot()
    sedan(W)
    W.can(1, 501, 9, 9000, true)
    W.ticks(3)
    eq(#W.objects(), 0, 'out of scope: no ped here to hold it')
    eq(W.calls.RequestModel, nil, 'and nothing is asked for while there is no ped to hold it')
    local p9 = W.player(9)
    W.ticks(2)
    ok(#W.objects() == 1 and W.objects()[1].e.attached.to == p9, 'streamed in: the can goes on')
    W.ents[p9], W.players[9] = nil, nil
    W.tick()
    eq(#W.objects(), 0, 'streamed out: the can comes off')
    local again = W.player(9)
    W.tick()
    ok(#W.objects() == 1 and W.objects()[1].e.attached.to == again, 'and back: on the new ped')
end

describe('C. the cans: this player\'s own follows the channel, on foot, and FUEL_CAN adds no second')
do
    local W = boot()
    sedan(W)
    W.give(1, 1)
    W.inv.using = { slot = 1, endsAt = W.now + 5000, ms = 5000 }
    W.ticks(2)
    local objs = W.objects()
    ok(#objs == 1 and objs[1].e.attached.to == W.ped and W.JC.state().own,
       'the channel opens: the can on this player\'s own hand')
    W.can(1, 501, 7, 5000, true)                -- p is this player
    W.ticks(3)
    eq(#W.objects(), 1, 'the pour\'s FUEL_CAN names this player: no second can')
    W.offFoot = true
    W.tick()
    eq(#W.objects(), 0, 'off its feet: the can comes off')
    W.offFoot = false
    W.tick()
    eq(#W.objects(), 1, 'back on foot, the channel still running: on again')
    W.B.State.me.state = W.B.PlayerState.DBNO
    W.tick()
    eq(#W.objects(), 0, 'knocked down: off on the pass the state says so')
    W.B.State.me.state = W.B.PlayerState.ALIVE
    W.tick()
    eq(#W.objects(), 1, 'up again')
    W.inv.using = nil
    W.tick()
    eq(#W.objects(), 0, 'the channel ends: off')

    -- THE ENDINGS THE CHANNEL DOES NOT SEE take this player's own can off too,
    -- with the channel still running here: the lobby and the season going off,
    -- where the pass lets go of everything and makes no can (letGo), and
    -- br_core stopping, where the pass that would have is the thing that stops.
    local endings = {
        { 'the lobby', function(X) X.B.State.me.state = X.B.PlayerState.LOBBY X.tick() end },
        { 'the season going off', function(X) X.season = 1 X.tick() end },
        { 'br_core stopping', function(X) X.fire('onClientResourceStop', 'br_core') end },
    }
    for _, case in ipairs(endings) do
        W = boot()
        sedan(W)
        W.give(1, 1)
        W.inv.using = { slot = 1, endsAt = W.now + 5000, ms = 5000 }
        W.ticks(2)
        ok(#W.objects() == 1 and W.JC.state().own, case[1] .. ': the own can stands, its channel running')
        case[2](W)
        ok(#W.objects() == 0 and not W.JC.state().own, case[1] .. ': the own can is gone',
           ('%d can(s)'):format(#W.objects()))
        if case[1] ~= 'br_core stopping' then
            W.ticks(3)
            ok(#W.objects() == 0 and not W.JC.state().own, case[1] .. ': and stays gone',
               ('%d can(s)'):format(#W.objects()))
        end
    end
end

describe('C. the cans: gone on every ending')
do
    local endings = {
        { 'the end', function(W) W.can(1, 501, 9, 0) end },
        { 'the deadline', function(W) W.ticks(80) end },
        { 'a newer pour', function(W) W.can(2, 501, 10, 5000, true) end },
        { 'the lobby', function(W) W.B.State.me.state = W.B.PlayerState.LOBBY W.tick() end },
        { 'the season going off', function(W) W.season = 1 W.tick() end },
        { 'br_core stopping', function(W) W.fire('onClientResourceStop', 'br_core') end },
    }
    for _, case in ipairs(endings) do
        local W = boot()
        sedan(W)
        W.player(9)
        W.can(1, 501, 9, 5000, true)
        W.ticks(2)
        ok(#W.objects() == 1, case[1] .. ': a can on the pourer')
        case[2](W)
        eq(#W.objects(), 0, case[1] .. ': the can is gone')
    end
end

-- ======================================================== D. the finder ---

describe('D. the finder: a cap bone beats a nearer rear wheel, through the shared rules')
do
    local W = boot()
    local h = sedan(W)
    local t = W.JC.target()
    ok(t ~= nil and t.bone == 'petroltank' and t.n == 501 and t.veh == h,
       'the cap bone at 1.2 m, not the wheel at 0.67 m',
       t and ('%s %s'):format(tostring(t.bone), tostring(t.n)) or 'nil')
    ok(t and t.x == 1.2 and t.y == 0.0 and t.z == 30.5, 'at the bone\'s world position')
    ok(W.solved.anchorBones >= 1 and W.solved.nearestAnchor == 1,
       'through BR.JerryCanSolve.anchorBones and nearestAnchor',
       ('%d, %d'):format(W.solved.anchorBones, W.solved.nearestAnchor))
    -- BONE 0 IS A REAL BONE: the petroltank above is index 0 on this car.
    eq(W.ents[h].boneIdx.petroltank, 0, 'and the cap found was bone index 0')
end

describe('D. the finder: wheels only without a cap bone; a lone wheel_lr bike works')
do
    local W = boot()
    W.car({ net = 601, x = 2.0, bones = { { 'wheel_lr', 1.0, 0.0, 30.2 }, { 'wheel_rr', 1.2, 0.5, 30.2 } } })
    local t = W.JC.target()
    ok(t ~= nil and t.bone == 'wheel_lr', 'no cap bone: the nearer rear wheel',
       t and t.bone or 'nil')
    W = boot()
    W.car({ net = 602, x = 1.5, class = 8, bones = { { 'wheel_lr', 1.1, 0.0, 30.3 } } })
    t = W.JC.target()
    ok(t ~= nil and t.bone == 'wheel_lr' and t.n == 602, 'a bike with only wheel_lr')
    W = boot()
    W.car({ net = 603, x = 1.5, bones = { { 'chassis', 0.5, 0.0, 30.0 } } })
    eq(W.JC.target(), nil, 'a model with neither is not a target')
    W = boot()
    W.car({ net = 604, x = 3.0, bones = { { 'fueltank', 1.0, 0.2, 30.4 }, { 'wheel_lr', 0.4, 0.0, 30.0 } } })
    t = W.JC.target()
    ok(t ~= nil and t.bone == 'fueltank', 'the bus\'s fueltank is a cap bone')
end

describe('D. the finder: the reach and the rise')
do
    local reach, rise = 1.5, 2.0
    local function at(x, z)
        local W = boot()
        W.car({ net = 701, x = x, bones = { { 'petrolcap', x, 0.0, z } } })
        return W.JC.target()
    end
    eq(reach, (boot()).J.capReach, 'the config\'s capReach is 1.5')
    ok(at(1.49, 30.0) ~= nil, 'a cap 1.49 m away is in reach')
    eq(at(1.51, 30.0), nil, 'a cap 1.51 m away is not')
    ok(at(1.0, 30.0 + rise) ~= nil, 'a cap 2.0 m up is within the rise')
    eq(at(1.0, 30.0 + rise + 0.01), nil, 'and one 2.01 m up is not')
    local W = boot()
    W.car({ net = 702, x = 3.0, bones = { { 'petroltank', 2.6, 0.0, 30.4 } } })
    ok(W.JC.target(3.0) ~= nil and W.JC.target() == nil, 'an explicit reach widens it: the marker\'s 3 m')
end

describe('D. the finder: cycles, aircraft, trains, wrecks, local cars and cars with no tank are skipped')
do
    for _, case in ipairs({
        { 'a bicycle (13)', { class = 13 } }, { 'a helicopter (15)', { class = 15 } },
        { 'a plane (16)', { class = 16 } }, { 'a train (21)', { class = 21 } },
        { 'a wreck', { dead = true } }, { 'a car that is not networked', { net = 0 } },
        { 'a car that uses no fuel', { usesFuel = false } },
    }) do
        local W = boot()
        local o = { net = 801, x = 2.0, bones = { { 'petroltank', 1.0, 0.0, 30.4 } } }
        for k, v in pairs(case[2]) do o[k] = v end
        W.car(o)
        eq(W.JC.target(), nil, case[1] .. ' is not a target')
    end
    -- BEYOND scanMeters: never measured, whatever its bones say.
    local W = boot()
    W.car({ net = 802, x = 10.5, bones = { { 'petroltank', 1.0, 0.0, 30.4 } } })
    W.calls = {}
    eq(W.JC.target(), nil, 'a car whose origin is past scanMeters is not a target')
    eq(W.calls.GetEntityBoneIndexByName or 0, 0, 'and its bones are never asked')
    eq(boot().JC.target(), nil, 'nothing in reach: nil')
end

-- ======================================================== E. the marker ---

describe('E. the marker: only with the can in hand, on foot, alive, on Season 2, with a cap within 3 m')
do
    local function setup(o)
        o = o or {}
        local W = boot({ season = o.season })
        W.car({ net = 901, x = 3.0, bones = { { 'petroltank', o.capX or 2.5, 0.0, 30.4 } } })
        W.give(2, o.active or 2)
        W.offFoot = o.offFoot == true
        W.tick()
        return W
    end
    local W = setup()
    ok(W.has('frame', 'jerrycan.marker'), 'the can in hand by a cap: the FRAME callback is registered')
    W.draws, W.natives = {}, 0
    W.frame()
    eq(#W.draws, 1, 'one DrawMarker a frame')
    eq(W.natives, 1, 'and nothing else')
    local d = W.draws[1] or {}
    local M = W.J.marker
    ok(d[1] == M.kind and d[2] == 2.5 and d[3] == 0.0 and math.abs(d[4] - (30.4 + M.lift)) < 1e-9,
       'type 0 at the cap, lift above it', ('%s %s %s %s'):format(tostring(d[1]), tostring(d[2]), tostring(d[3]), tostring(d[4])))
    ok(d[11] == M.size and d[12] == M.size and d[13] == M.height
       and d[14] == M.color.r and d[15] == M.color.g and d[16] == M.color.b and d[17] == M.color.a,
       'at the config\'s size, height and the game\'s white')
    ok(d[18] == false and d[19] == false and d[20] == 2 and d[21] == false
       and d[22] == nil and d[23] == nil and d[24] == false,
       'no bob, no face-camera, no spin, no texture, not drawn on entities')

    -- TWO CARS IN REACH: still one.
    W = boot()
    W.car({ net = 911, x = 3.0, bones = { { 'petroltank', 2.0, 0.0, 30.4 } } })
    W.car({ net = 912, x = -3.0, bones = { { 'petroltank', -2.2, 0.0, 30.4 } } })
    W.give(1, 1)
    W.tick()
    W.draws = {}
    for _ = 1, 5 do W.frame() end
    eq(#W.draws, 5, 'two caps in reach: still one marker a frame')

    eq(setup({ active = 0 }).has('frame', 'jerrycan.marker'), false, 'the can not in hand: no marker')
    eq(setup({ offFoot = true }).has('frame', 'jerrycan.marker'), false, 'off foot: no marker')
    eq(setup({ season = 1 }).has('frame', 'jerrycan.marker'), false, 'Season 1: no marker')
    -- ALIVE, THE ONE STATE A POUR CAN START IN: the server pours only for ALIVE
    -- and WARMUP, and only into a car in the match's own bucket, which the
    -- warmup pad never is. So a player holding the can by a cap downed, out or
    -- on the pad is shown nothing to aim at.
    W = setup()
    W.B.State.me.state = W.B.PlayerState.DBNO
    W.tick()
    eq(W.has('frame', 'jerrycan.marker'), false, 'downed with the can in hand by a cap: no marker')
    W.B.State.me.state = W.B.PlayerState.OUT
    W.tick()
    eq(W.has('frame', 'jerrycan.marker'), false, 'out: no marker')
    W.B.State.me.state = W.B.PlayerState.WARMUP
    W.tick()
    eq(W.has('frame', 'jerrycan.marker'), false, 'on the warmup pad: no marker')
    W.B.State.me.state = W.B.PlayerState.ALIVE
    W.tick()
    ok(W.has('frame', 'jerrycan.marker'), 'alive again: the marker')
    eq(setup({ capX = -0.5 }).has('frame', 'jerrycan.marker'), true, 'a cap 0.5 m off: marker')
    W = boot()
    W.car({ net = 921, x = 4.0, bones = { { 'petroltank', 3.1, 0.0, 30.4 } } })
    W.give(1, 1)
    W.tick()
    eq(W.has('frame', 'jerrycan.marker'), false, 'a cap 3.1 m off: no marker')
end

describe('E. the marker: the FRAME callback exists only while a point stands, and costs nothing otherwise')
do
    local W = boot()
    local h = W.car({ net = 931, x = 3.0, bones = { { 'petroltank', 2.5, 0.0, 30.4 } } })
    W.give(1, 1)
    W.tick()
    ok(W.has('frame', 'jerrycan.marker'), 'up')
    W.inv.active = 0                               -- the can put away
    W.tick()
    eq(W.has('frame', 'jerrycan.marker'), false, 'the can put away: the callback is gone')
    W.natives = 0
    for _ = 1, 60 do W.frame() end
    eq(W.natives, 0, 'and sixty frames call no native')
    W.inv.active = 1
    W.tick()
    ok(W.has('frame', 'jerrycan.marker'), 'brought up again: back, at once')
    W.ents[h].x = 9.0
    W.ents[h].boneAt[0].x = 8.5                   -- the car drives off
    W.ticks(5)
    eq(W.has('frame', 'jerrycan.marker'), false, 'the cap out of reach: gone again within half a second')
end

describe('E. the marker: the pool is walked twice a second, not on every pass')
do
    -- THE LOOK IS A WALK OF EVERY CAR STREAMED: GetGamePool and a position read
    -- each. Ten a second of it, a car or not in reach, was the first build's.
    local W = boot()
    W.car({ net = 941, x = 3.0, bones = { { 'petroltank', 2.5, 0.0, 30.4 } } })
    for i = 1, 40 do W.car({ net = 1000 + i, x = 50.0 + i, y = 50.0 }) end
    W.give(1, 1)
    W.calls = {}
    W.tick()
    eq(W.calls.GetGamePool, 1, 'the can brought up: one look at once')
    ok(W.has('frame', 'jerrycan.marker'), 'and the marker up from it')
    W.calls = {}
    W.ticks(10)                                   -- a second
    eq(W.calls.GetGamePool, 2, 'a second with it in hand: two looks, not ten', W.calls.GetGamePool)
    ok((W.calls.GetEntityCoords or 0) <= 2 * 42, 'and a position read per car per look, no more',
       W.calls.GetEntityCoords)
    ok(W.has('frame', 'jerrycan.marker'), 'the marker standing between looks')

    -- WITH NOTHING IN REACH, the same two.
    W = boot()
    for i = 1, 40 do W.car({ net = 1000 + i, x = 50.0 + i, y = 50.0 }) end
    W.give(1, 1)
    W.tick()
    W.calls = {}
    W.ticks(10)
    eq(W.calls.GetGamePool, 2, 'no cap anywhere near: still two a second', W.calls.GetGamePool)

    -- PUT AWAY, NO LOOK AT ALL; BROUGHT UP AGAIN, THE FIRST AT ONCE.
    W.inv.active = 0
    W.tick()
    W.calls = {}
    W.ticks(10)
    eq(W.calls.GetGamePool, nil, 'the can put away: no look at all')
    W.car({ net = 942, x = 3.0, bones = { { 'petroltank', 2.5, 0.0, 30.4 } } })
    W.inv.active = 1
    W.tick()
    ok(W.has('frame', 'jerrycan.marker'), 'brought up beside a car: the marker on the first pass')
end

-- ===================================================== F. the idle pass ---

describe('F. the idle pass: no native and nothing allocated with no pour, no window and the can not in hand')
do
    local W = boot()
    sedan(W)
    W.give(3, 0)                                   -- a can in the bag, not in hand
    local fn = W.loop('tick', 'jerrycan.tick')
    ok(fn ~= nil, 'the TICK pass is registered')
    W.natives = 0
    collectgarbage('collect')
    collectgarbage('stop')
    local before = collectgarbage('count')
    for _ = 1, 200 do fn() end
    local grew = collectgarbage('count') - before
    collectgarbage('restart')
    eq(W.natives, 0, 'two hundred idle passes call no native')
    eq(grew, 0, 'and allocate nothing')
    eq(W.has('tick', 'jerrycan.tick') and 1 or 0, 1, 'one TICK callback')
    local frames = 0
    for _ in pairs(W.loops.frame) do frames = frames + 1 end
    eq(frames, 0, 'and no FRAME callback at all')
end

-- ===================================================== G. /brjerrytune ---

describe('G. /brjerrytune: a toggle, the six numbers on the keys, the paste line')
do
    local W = boot()
    local K = W.B.TuneKeys.KEY
    local cmd = W.commands.brjerrytune
    ok(type(cmd) == 'function', '/brjerrytune is registered')
    local row = W.B.Config.UseEmotes.jerrycan
    local e = row[row.use]
    cmd(nil, {})
    ok(W.B.TuneKeys.on('brjerrytune') and W.has('frame', 'tunekeys.brjerrytune'),
       'bare: on, on client/tunekeys.lua\'s keys')
    W.tick()
    W.tick()
    local objs = W.objects()
    ok(#objs == 1 and objs[1].e.attached.to == W.ped and W.JC.state().preview,
       'a preview can on this player\'s own hand')
    local anim = W.anims[W.ped]
    ok(anim and anim.dict == e.dict and anim.clip == e.clip and anim.flag == 49 and anim.dur == -1,
       'with the use entry\'s clip playing, looped, as the pour plays it')

    local function tap(...)
        local ids = { ... }
        for _, id in ipairs(ids) do W.down[id] = true end
        W.frame()
        for _, id in ipairs(ids) do W.down[id] = nil end
        W.frame()
    end
    tap(K.RIGHT)                                   -- x
    tap(K.UP)                                      -- y
    tap(K.DEPTH, K.UP)                             -- z
    tap(K.TURN, K.UP)                              -- rx
    tap(K.TURN, K.RIGHT)                           -- rz
    tap(K.TURN, K.DEPTH, K.UP)                     -- ry
    tap(K.COARSE, K.RIGHT)                         -- x, ten times the step
    local a = W.objects()[1].e.attached
    near(a.x, e.pos.x + 0.11, 'RIGHT then SHIFT + RIGHT: x up a centimeter and ten', 1e-9)
    near(a.y, e.pos.y + 0.01, 'UP: y', 1e-9)
    near(a.z, e.pos.z + 0.01, 'CTRL + UP: z', 1e-9)
    near(a.rx, e.rot.x + 1.0, 'ALT + UP: rx', 1e-9)
    near(a.ry, e.rot.y + 1.0, 'ALT + CTRL + UP: ry', 1e-9)
    near(a.rz, e.rot.z + 1.0, 'ALT + RIGHT: rz', 1e-9)
    eq(a.to, W.ped, 'each step moves the preview on the hand')
    local drawn = table.concat(W.readout, '\n')
    ok(drawn:find(('x %.2f'):format(e.pos.x + 0.11), 1, true) ~= nil, 'the numbers on screen', drawn:sub(1, 200))

    -- DELETE: back to the config's.
    tap(K.RESET)
    a = W.objects()[1].e.attached
    ok(a.x == e.pos.x and a.rz == e.rot.z, 'DELETE: back to config')
    tap(K.LEFT)
    tap(K.TURN, K.DOWN)

    W.printed = {}
    cmd(nil, { 'off' })
    local printed = table.concat(W.printed, '\n')
    local want = ('pos = { x = %.2f, y = %.2f, z = %.2f }, rot = { x = %.2f, y = %.2f, z = %.2f }')
        :format(e.pos.x - 0.01, e.pos.y, e.pos.z, e.rot.x - 1.0, e.rot.y, e.rot.z)
    ok(printed:find(want, 1, true) ~= nil, 'off prints the entry\'s pos and rot to paste', printed)
    ok(not W.B.TuneKeys.on('brjerrytune') and not W.has('frame', 'tunekeys.brjerrytune'),
       'and the keys are put away')
    ok(#W.objects() == 0 and W.anims[W.ped] == nil, 'the preview can and its clip with them')

    -- BARE AGAIN TURNS IT ON; BARE ONCE MORE, OFF.
    cmd(nil, {})
    ok(W.B.TuneKeys.on('brjerrytune'), 'bare: on again')
    cmd(nil, {})
    ok(not W.B.TuneKeys.on('brjerrytune'), 'bare: off again')
    W.printed = {}
    cmd(nil, { 'off' })
    ok(table.concat(W.printed, '\n'):find('pos = { x = ', 1, true) ~= nil,
       'off while off still answers with the line, from the config')
end

-- ========================================================== H. the files ---

describe('H. the files: the dry tank\'s ignition waits for a pour; no client freezes; the scope markers')
do
    -- THE WHOLE CONDITION, AS TEXT, AND WHAT IT GUARDS. client/fuel.lua cannot
    -- be loaded by a suite (tools/test_fuel.lua's prompt.copy says why), so the
    -- guard is read -- and read whole, its spacing aside: a pin on the call
    -- alone was passed by `BR.JerryCan.hold and BR.JerryCan.holds(nid)` (a
    -- field that is never there, so the guard never fires) and by an
    -- `and false` after it (#217's review).
    local fuel = readFile(ROOT .. 'br_core/client/fuel.lua') or ''
    local handler = fuel:match('AddEventHandler%(BR%.Net%.FUEL_SET, function%(d%)(.-)\nend%)') or ''
    local cond, body = (handler .. '\n'):match('\n(%s*if prev and prev%.f <= 0%.0.-then)\n(.-)\n    end\n')
    local flat = (cond or ''):gsub('%s+', ' '):gsub('^ ', '')
    eq(flat, 'if prev and prev.f <= 0.0 and (tonumber(d.f) or 0.0) > 0.0 and not '
        .. '(BR.JerryCan and BR.JerryCan.holds and BR.JerryCan.holds(nid)) then',
       'client/fuel.lua\'s dry-tank ignition is skipped while BR.JerryCan.holds(nid), the whole condition')
    ok((body or ''):find('pcall(SetVehicleEngineOn, veh, true, false, false)', 1, true) ~= nil,
       'and what it guards is the ignition itself, still there for every other refuel', body)

    local src = readFile(ROOT .. 'br_core/client/jerrycan.lua') or ''
    local code = src:gsub('%-%-[^\n]*', '')
    ok(code:find('FreezeEntityPosition, veh, true', 1, true) == nil
       and code:find('FreezeEntityPosition%([^,]+,%s*true') == nil,
       'client/jerrycan.lua never writes a freeze: clients only let go')
    ok(code:find('CreateObject, hash, p.x, p.y, p.z + 0.2, false, false, false', 1, true) ~= nil,
       'and its can is created with every network flag false')
    local unmarked = {}
    for line in (src .. '\n'):gmatch('([^\n]*)\n') do
        if (line:find('GetPlayerFromServerId', 1, true) or line:find('GetPlayerPed(', 1, true))
           and not line:find('scope-ok', 1, true) then
            unmarked[#unmarked + 1] = line
        end
    end
    eq(#unmarked, 0, 'every line resolving a pourer\'s ped carries its scope-ok marker')
    local hold = readFile(ROOT .. 'br_core/client/enginehold.lua') or ''
    ok(not hold:find('BR%.Loop%.register') and not hold:find('AddEventHandler'),
       'client/enginehold.lua registers no loop and no handler: holders call it')
end

realPrint((fail == 0 and '\27[32m%d passed, %d failed\27[0m' or '\27[31m%d passed, %d failed\27[0m')
    :format(pass, fail))
if fail > 0 then os.exit(1) end
