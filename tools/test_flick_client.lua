-- Unit tests for the Flick cameras' client (#419): br_core/client/flick.lua
-- over modeled natives (docs/flick.md).
--
-- The property is a SEQUENCE, not a value -- which natives are called, when,
-- how often, and what the world holds after each step -- so the file is run
-- in a Lua environment of its own over a modeled engine: map objects (each
-- client's own copy of a camera, with its health, uprightness, a broken part
-- and the damage it took), script objects, model hides, blips, the three loop
-- bands with the FRAME and TICK callbacks that come and go, the season and
-- the mirror. Each block boots a fresh client.
--
--   the watch     nothing in the lobby, off Season 2, for a player who is
--                 out; a handle found once as a camera comes into reach and
--                 again only when its copy stops existing; a miss asked again
--                 only after findRetryMs; one report a camera a match, `me`
--                 only for this player's own ped or the vehicle they drive,
--                 `other` otherwise; a camera found up has its damage record
--                 cleared
--   the downs     a hide each, made a batch a frame; a wreck by the cause,
--                 only within wreckM and under wreckMax, none over a copy that
--                 really fell; all of it gone on a new match, in the lobby,
--                 off Season 2 and as br_core stops; the snapshot replaces the
--                 list
--   Season 1      every camera hidden, a batch a frame, once per season move
--   the coverage  only with `flick` pushes, only while the big map is up, one
--                 circle per live camera, built in batches, gone when the map
--                 closes or the pushes stop
--   the file      no scope-gate native
--
-- Run via tools/verify.sh, or directly:  lua tools/test_flick_client.lua

local realPrint = print
local realExit = os.exit
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

local function readFile(path)
    local fh = io.open(path, 'rb')
    if not fh then return nil end
    local s = fh:read('a')
    fh:close()
    return s
end

-- ------------------------------------------------------------- the engine ---

local CAM_MODEL = 'blitz_flick_cam'
local function hashOf(s) return 'h:' .. tostring(s) end

--- A fixture registry: n cameras 40 m apart along y = 0, from x = 0.
local function row(n, step, y)
    local out = {}
    for i = 1, n do
        out[i] = { id = i, x = (i - 1) * (step or 40.0), y = y or 0.0, z = 30.0, h = 90.0, region = 'fix' }
    end
    return out
end

--- Boot a client. opts: cameras (the registry), season (1 or 2; nil is not
--- known yet), match ('playing' ...), me (a player state), at (the ped).
local function boot(opts)
    opts = opts or {}
    local W = {
        now = 500000, natives = 0, calls = {}, season = opts.season ~= false and (opts.season or 2) or nil,
        objects = {}, nextObj = 1, blips = {}, nextBlip = 1, hides = {}, hideCalls = 0,
        handlers = {}, loops = { frame = {}, tick = {}, slow = {} }, server = {}, commands = {},
        watchers = {}, ped = 77, veh = 0, seat = nil, at = opts.at or { x = 0.0, y = 0.0, z = 30.0 },
        printed = {}, executed = {}, loaded = {}, requested = {},
    }
    local env = setmetatable({}, { __index = _G })
    local function n(name)
        W.natives = W.natives + 1
        W.calls[name] = (W.calls[name] or 0) + 1
    end
    env.print = function(s) W.printed[#W.printed + 1] = tostring(s) end
    env.GetGameTimer = function() return W.now end
    env.GetCurrentResourceName = function() return 'br_core' end
    env.PlayerPedId = function() n('PlayerPedId') return W.ped end
    env.GetEntityCoords = function(h)
        n('GetEntityCoords')
        if h == W.ped then return { x = W.at.x, y = W.at.y, z = W.at.z } end
        local o = W.objects[h]
        return o and { x = o.x, y = o.y, z = o.z } or { x = 0.0, y = 0.0, z = 0.0 }
    end
    env.GetHashKey = function(s) n('GetHashKey') return hashOf(s) end
    env.IsModelInCdimage = function(h) n('IsModelInCdimage') return (opts.noWreckModels and 0) or 1 end
    env.HasModelLoaded = function(h) n('HasModelLoaded') return W.loaded[h] and 1 or 0 end
    env.RequestModel = function(h) n('RequestModel') W.requested[h] = (W.requested[h] or 0) + 1 end
    env.SetModelAsNoLongerNeeded = function(h) n('SetModelAsNoLongerNeeded') W.loaded[h] = nil end
    --- THE MAP OBJECTS: a camera the ymap stands, this client's copy, found by
    --- model near a row unless it is hidden or streamed out.
    function W.mapCamera(r, extra)
        local h = W.nextObj
        W.nextObj = h + 1
        local o = { x = r.x, y = r.y, z = r.z, model = hashOf(CAM_MODEL), map = true, health = 1000,
                    upright = 1.0, broken = false, damagedBy = {}, anyVehicle = false }
        for k, v in pairs(extra or {}) do o[k] = v end
        W.objects[h] = o
        return h
    end
    local function hiddenAt(o)
        for _, hd in pairs(W.hides) do
            if hd.hash == o.model and (o.x - hd.x) ^ 2 + (o.y - hd.y) ^ 2 + (o.z - hd.z) ^ 2 <= hd.r * hd.r then
                return true
            end
        end
        return false
    end
    env.GetClosestObjectOfType = function(x, y, z, r, hash)
        n('GetClosestObjectOfType')
        local best, bestD = 0, r * r
        for h, o in pairs(W.objects) do
            if o.map and o.model == hash and not hiddenAt(o) then
                local d = (o.x - x) ^ 2 + (o.y - y) ^ 2 + (o.z - z) ^ 2
                if d <= bestD then best, bestD = h, d end
            end
        end
        return best
    end
    env.DoesEntityExist = function(h) n('DoesEntityExist') return W.objects[h] ~= nil and 1 or 0 end
    env.GetEntityHealth = function(h) n('GetEntityHealth') return W.objects[h] and W.objects[h].health or 0 end
    env.GetEntityUprightValue = function(h) n('GetEntityUprightValue') return W.objects[h] and W.objects[h].upright or 0.0 end
    env.HasObjectBeenBroken = function(h) n('HasObjectBeenBroken') return (W.objects[h] and W.objects[h].broken) and 1 or 0 end
    env.HasEntityBeenDamagedByEntity = function(h, by)
        n('HasEntityBeenDamagedByEntity')
        return (W.objects[h] and W.objects[h].damagedBy[by]) and 1 or 0
    end
    env.HasEntityBeenDamagedByAnyVehicle = function(h)
        n('HasEntityBeenDamagedByAnyVehicle')
        return (W.objects[h] and W.objects[h].anyVehicle) and 1 or 0
    end
    env.ClearEntityLastDamageEntity = function(h)
        n('ClearEntityLastDamageEntity')
        local o = W.objects[h]
        if o then o.damagedBy, o.anyVehicle, o.cleared = {}, false, (o.cleared or 0) + 1 end
    end
    env.GetVehiclePedIsIn = function() n('GetVehiclePedIsIn') return W.veh end
    env.GetPedInVehicleSeat = function(_, seat) n('GetPedInVehicleSeat') return seat == -1 and W.seat or 0 end
    env.CreateObjectNoOffset = function(hash, x, y, z, net, mission, door)
        n('CreateObjectNoOffset')
        local h = W.nextObj
        W.nextObj = h + 1
        W.objects[h] = { x = x, y = y, z = z, model = hash, script = true, net = net, damagedBy = {} }
        return h
    end
    env.SetEntityHeading = function(h, hd) n('SetEntityHeading') if W.objects[h] then W.objects[h].h = hd end end
    env.FreezeEntityPosition = function(h, f) n('FreezeEntityPosition') if W.objects[h] then W.objects[h].frozen = f end end
    env.DeleteObject = function(h) n('DeleteObject') W.objects[h] = nil end
    env.CreateModelHideExcludingScriptObjects = function(x, y, z, r, hash, survive)
        n('CreateModelHideExcludingScriptObjects')
        W.hideCalls = W.hideCalls + 1
        local k = ('%.3f,%.3f,%.3f'):format(x, y, z)
        ok(W.hides[k] == nil, 'never a second hide over a live one', k)
        W.hides[k] = { x = x, y = y, z = z, r = r, hash = hash, survive = survive }
    end
    env.RemoveModelHide = function(x, y, z, r, hash, lazy)
        n('RemoveModelHide')
        W.hideCalls = W.hideCalls + 1
        local k = ('%.3f,%.3f,%.3f'):format(x, y, z)
        ok(W.hides[k] ~= nil and lazy == false, 'only a hide this client made is lifted, at once', k)
        W.hides[k] = nil
    end
    env.CreateModelHide = function() n('CreateModelHide') W.scriptsToo = true end
    env.DoesBlipExist = function(b) n('DoesBlipExist') return W.blips[b] ~= nil and 1 or 0 end
    env.RemoveBlip = function(b) n('RemoveBlip') W.blips[b] = nil end
    env.RegisterNetEvent = function() end
    env.AddEventHandler = function(name, fn)
        W.handlers[name] = W.handlers[name] or {}
        table.insert(W.handlers[name], fn)
    end
    env.TriggerServerEvent = function(ev, d) W.server[#W.server + 1] = { ev = ev, d = d } end
    env.RegisterCommand = function(name, fn) W.commands[name] = fn end
    env.ExecuteCommand = function(line) W.executed[#W.executed + 1] = line end

    env.BR = {}
    for _, f in ipairs({ 'br_lib/shared/enums.lua', 'br_lib/shared/protocol.lua',
                         'br_lib/config/terminals.lua', 'br_lib/config/flick.lua',
                         'br_lib/config/flick_cameras.lua', 'br_lib/shared/flick_solve.lua' }) do
        assert(loadfile(ROOT .. f, 't', env))()
    end
    local B = env.BR
    if opts.cameras then B.Config.Flick.cameras = opts.cameras end
    B.Season = {
        has = function(id)
            if id ~= 'flick' then error('asked ' .. tostring(id)) end
            return W.season ~= nil and W.season >= 2
        end,
        current = function() return W.season end,
        onChange = function(fn) W.watchers[#W.watchers + 1] = fn end,
    }
    B.State = {
        match = { state = opts.match or B.MatchState.PLAYING },
        me = { state = opts.me or B.PlayerState.ALIVE },
    }
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
            for band, list in pairs(W.loops) do
                for id, x in pairs(list) do
                    if x == e then list[id] = nil end
                end
            end
        end,
    }
    B.Native = {
        frontendMap = false,
        radiusBlip = function(existing, x, y, r, color, alpha, name)
            n('AddBlipForRadius')
            local b = W.nextBlip
            W.nextBlip = b + 1
            W.blips[b] = { x = x, y = y, r = r, color = color, alpha = alpha, name = name }
            return b
        end,
        blipHiddenOnLegend = function(b, hidden)
            n('SetBlipHiddenOnLegend')
            if W.blips[b] then W.blips[b].offLegend = hidden end
        end,
    }
    assert(loadfile(ROOT .. 'br_core/client/flick.lua', 't', env))()
    W.env, W.B = env, B

    --- One pass of a band, every callback in it.
    local function step(band)
        local ids = {}
        for id in pairs(W.loops[band]) do ids[#ids + 1] = id end
        table.sort(ids)
        for _, id in ipairs(ids) do
            local e = W.loops[band][id]
            if e then e.fn() end
        end
    end
    function W.slow() step('slow') end
    function W.tick() step('tick') end
    function W.frame() step('frame') end
    function W.frames(k) for _ = 1, k do W.frame() end end
    function W.has(band, name)
        for _, e in pairs(W.loops[band]) do if e.name == name then return true end end
        return false
    end
    function W.net(name, d)
        for _, fn in ipairs(W.handlers[name] or {}) do fn(d) end
    end
    function W.switch(s)
        local before = W.season
        W.season = s
        for _, fn in ipairs(W.watchers) do fn(s, before) end
    end
    function W.hidden()
        local k = 0
        for _ in pairs(W.hides) do k = k + 1 end
        return k
    end
    function W.reports()
        local out = {}
        for _, s in ipairs(W.server) do
            if s.ev == B.Net.FLICK_REPORT then out[#out + 1] = s.d end
        end
        return out
    end
    function W.scripts()
        local out = {}
        for h, o in pairs(W.objects) do if o.script then out[#out + 1] = h end end
        return out
    end
    function W.circles()
        local k = 0
        for _ in pairs(W.blips) do k = k + 1 end
        return k
    end
    --- Let every queued hide and circle be made.
    function W.drain()
        for _ = 1, 400 do
            if not W.has('frame', 'flick.work') then return end
            W.frame()
        end
    end
    return W
end

-- ------------------------------------------------------------- the watch ---

describe('the watch: nothing is called in the lobby, off Season 2, or for a player who is out')
do
    local cams = row(5)
    for _, case in ipairs({
        { label = 'in the lobby', o = { me = 'lobby', match = 'waiting' } },
        { label = 'at warmup', o = { match = 'warmup', me = 'warmup' } },
        { label = 'for a player who is out', o = { me = 'dead' } },
    }) do
        local o = case.o
        o.cameras = cams
        local W = boot(o)
        for _, r in ipairs(cams) do W.mapCamera(r) end
        W.drain()
        W.natives = 0
        for _ = 1, 5 do W.slow() end
        eq(W.natives, 0, case.label .. ': five passes, no native')
    end
    local W = boot({ cameras = cams, season = 1 })
    W.drain()
    W.natives = 0
    for _ = 1, 5 do W.slow() end
    eq(W.natives, 0, 'Season 1: five passes, no native (its hides were made once, at start)')
end

describe('the watch: a handle found once as a camera comes into reach, again only when it is gone')
do
    local cams = row(8, 300.0)
    local W = boot({ cameras = cams })
    local h1 = W.mapCamera(cams[1])
    W.mapCamera(cams[2])
    W.slow()
    eq(W.calls.GetClosestObjectOfType or 0, 1, 'the one camera within 120 m: one find')
    W.calls = {}
    for _ = 1, 10 do W.slow() end
    eq(W.calls.GetClosestObjectOfType or 0, 0, 'ten passes on, no find: the handle is held')
    eq(W.calls.DoesEntityExist, 10, 'one existence read a pass')
    eq(W.calls.ClearEntityLastDamageEntity, 10, 'and the damage record cleared each pass it reads up')
    -- STREAMED OUT: the copy stops existing, and is found again.
    W.objects[h1] = nil
    local h1b = W.mapCamera(cams[1])
    W.calls = {}
    W.slow()
    eq(W.calls.GetClosestObjectOfType, 1, 'a copy that stopped existing is found again, once')
    W.calls = {}
    W.slow()
    eq(W.calls.GetClosestObjectOfType or 0, 0, 'and held again')
    local _ = h1b
    -- WALKING ON: the next camera comes into reach, the last leaves it.
    W.at = { x = cams[2].x, y = 0.0, z = 30.0 }
    W.calls = {}
    W.slow()
    eq(W.calls.GetClosestObjectOfType, 1, 'the next camera, as it comes into reach: one find')
    W.at = { x = cams[1].x, y = 0.0, z = 30.0 }
    W.calls = {}
    W.slow()
    eq(W.calls.GetClosestObjectOfType, 1, 'back again: the one that left reach is found anew')
end

describe('the watch: a miss is asked again only after findRetryMs, and finds are capped a pass')
do
    -- Ten cameras in reach and no copy of any: the pack is not installed here.
    local cams = row(10, 10.0)
    local W = boot({ cameras = cams })
    local per = W.B.Config.Flick.client.findsPerPass
    local asks = {}
    for i = 1, 6 do
        W.calls = {}
        W.slow()
        asks[i] = W.calls.GetClosestObjectOfType or 0
        W.now = W.now + 1000
    end
    eq(table.concat(asks, ','), ('%d,%d,%d,0,0,%d'):format(per, per, 10 - 2 * per, per),
        'findsPerPass a pass at most, and a row it missed asked again only findRetryMs on')
end

describe('the watch: one report a camera a match -- me for this player\'s own ped or the car they drive')
do
    local cams = row(4, 30.0)
    local W = boot({ cameras = cams })
    local h = {}
    for i, r in ipairs(cams) do h[i] = W.mapCamera(r) end
    W.slow()
    eq(#W.reports(), 0, 'every camera up: nothing reported')
    -- SHOT BY THIS PLAYER.
    W.objects[h[1]].broken = true
    W.objects[h[1]].damagedBy[W.ped] = true
    -- RAMMED BY THE CAR THIS PLAYER DRIVES.
    W.veh, W.seat = 900, W.ped
    W.objects[h[2]].broken = true
    W.objects[h[2]].damagedBy[900] = true
    W.objects[h[2]].anyVehicle = true
    -- KNOCKED OVER BY A CAR NOBODY HERE DRIVES (traffic).
    W.objects[h[3]].broken = true
    W.objects[h[3]].anyVehicle = true
    W.slow()
    local got = {}
    for _, d in ipairs(W.reports()) do got[d.id] = d end
    ok(got[1] and got[1].by == 'me' and got[1].cause == 'weapon', 'shot by this player: me, weapon')
    ok(got[2] and got[2].by == 'me' and got[2].cause == 'vehicle', 'rammed with the car they drive: me, vehicle')
    ok(got[3] and got[3].by == 'other' and got[3].cause == 'vehicle', 'traffic: other, vehicle')
    eq(got[4], nil, 'the untouched one is not reported')
    W.slow()
    W.slow()
    eq(#W.reports(), 3, 'each reported once, whatever the server says')
    -- A PASSENGER'S CAR IS NOT THEIRS.
    W = boot({ cameras = cams })
    for i, r in ipairs(cams) do h[i] = W.mapCamera(r) end
    W.slow()
    W.veh, W.seat = 900, 12345
    W.objects[h[1]].broken = true
    W.objects[h[1]].damagedBy[900] = true
    W.objects[h[1]].anyVehicle = true
    W.slow()
    local d = W.reports()[1]
    ok(d and d.by == 'other', 'riding in a car somebody else drives: other')
    -- TILTED, OR MOVED, IS DOWN TOO. Where it stands is read only when its
    -- health or its upright moved: a camera that moved without either is one
    -- the engine never moves (the ymap's handle stays at the base).
    W.objects[h[2]].upright = 0.5
    W.objects[h[3]].x = W.objects[h[3]].x + 2.0
    W.calls = {}
    W.slow()
    eq(#W.reports(), 2, 'tilted is down')
    eq(W.calls.GetEntityCoords, 1 + 1, 'the ped, and where the tilted camera is: no other coordinates read')
    W.objects[h[3]].health = 900
    W.slow()
    eq(#W.reports(), 3, 'moved, with its health moved, is down too')
end

describe('the watch: a damaged camera still up has its record cleared, so a stale me lasts a pass')
do
    local cams = row(1)
    local W = boot({ cameras = cams })
    local h = W.mapCamera(cams[1])
    W.slow()
    -- A shot at the pole: sparks, nothing broken.
    W.objects[h].damagedBy[W.ped] = true
    W.objects[h].health = 990
    W.slow()
    eq(next(W.objects[h].damagedBy), nil, 'up: the record is cleared on the pass that reads it')
    -- Long after, traffic knocks it over: not this player's.
    W.objects[h].broken = true
    W.objects[h].anyVehicle = true
    W.slow()
    local d = W.reports()[1]
    ok(d and d.by == 'other', 'a camera traffic took is not this player\'s for an old shot')
end

-- -------------------------------------------------------------- the downs ---

describe('the downs: a hide each, a batch a frame; a wreck by the cause, near only')
do
    local cams = row(40, 5.0)
    local W = boot({ cameras = cams })
    W.drain()
    eq(W.hidden(), 0, 'Season 2: no camera hidden')
    local ids, causes = {}, {}
    for i = 1, 30 do
        ids[i] = i
        causes[i] = (i % 2 == 0) and 'vehicle' or 'weapon'
    end
    W.net(W.B.Net.FLICK_DOWN, { matchId = 9, ids = ids, causes = causes })
    eq(W.hidden(), 0, 'nothing in the handler itself')
    ok(W.has('frame', 'flick.work'), 'the work callback is registered for them')
    W.frame()
    eq(W.hidden(), W.B.Config.Flick.client.hidesPerFrame, 'one frame: hidesPerFrame hides')
    W.drain()
    eq(W.hidden(), 30, 'then one hide a down camera, no more')
    ok(not W.has('frame', 'flick.work'), 'and the work callback is gone with the work')
    for _, hd in pairs(W.hides) do
        ok(hd.survive == true and hd.hash == hashOf(CAM_MODEL) and hd.r == W.B.Config.Flick.art.hideRadiusM,
            'map objects of the camera model only, surviving a map reload, at hideRadiusM')
        break
    end
    ok(not W.scriptsToo, 'never CreateModelHide, which would hide a script\'s wreck too')
    -- The models stream first.
    W.slow()
    eq(#W.scripts(), 0, 'the wreck models are asked for before any wreck is made')
    W.loaded[hashOf('blitz_flick_cam_shot')] = true
    W.loaded[hashOf('blitz_flick_cam_down')] = true
    W.slow()
    eq(#W.scripts(), W.B.Config.Flick.client.wreckMax, 'thirty down near the view: wreckMax wrecks')
    local shot, down = 0, 0
    for _, hh in ipairs(W.scripts()) do
        local o = W.objects[hh]
        ok(o.net == false and o.h == 90.0, 'a local object, never networked, at the row\'s heading')
        if o.model == hashOf('blitz_flick_cam_shot') then
            shot = shot + 1
            ok(o.frozen == false, 'the shot wreck stands unfrozen, so a car can still knock it over')
        elseif o.model == hashOf('blitz_flick_cam_down') then
            down = down + 1
            ok(o.frozen == true, 'the stump is frozen')
        end
    end
    ok(shot > 0 and down > 0, 'each by its cause: a weapon\'s shot wreck, a vehicle\'s stump')
    -- WALKING AWAY: past wreckM every wreck goes.
    W.at = { x = 5000.0, y = 0.0, z = 30.0 }
    W.slow()
    eq(#W.scripts(), 0, 'past wreckM of every down camera, no wreck')
    eq(W.hidden(), 30, 'the hides stay: a camera that streams in later arrives hidden')
end

describe('the downs: no stand-in over a copy that really fell, and none without the models')
do
    local cams = row(3, 20.0)
    local W = boot({ cameras = cams })
    local h = W.mapCamera(cams[1])
    W.slow()
    W.objects[h].broken = true
    W.objects[h].damagedBy[W.ped] = true
    W.slow()
    eq(#W.reports(), 1, 'this client saw its copy go down and said so')
    W.loaded[hashOf('blitz_flick_cam_shot')] = true
    W.net(W.B.Net.FLICK_DOWN, { matchId = 9, ids = { 1, 2 }, causes = { 'weapon', 'weapon' } })
    W.drain()
    W.slow()
    eq(#W.scripts(), 1, 'a stand-in for the camera it did not see fall, none over the one it did')
    W.objects[h] = nil
    W.slow()
    eq(#W.scripts(), 2, 'once its own copy is gone, the stand-in comes')

    W = boot({ cameras = cams, noWreckModels = true })
    W.net(W.B.Net.FLICK_DOWN, { matchId = 9, ids = { 1 }, causes = { 'vehicle' } })
    W.drain()
    for _ = 1, 3 do W.slow() end
    ok(#W.scripts() == 0 and W.hidden() == 1, 'no wreck model on this build: hidden only')
    eq(W.calls.RequestModel or 0, 0, 'and never asked to stream')
end

describe('the downs: all of it gone on a new match, in the lobby, off Season 2, and as br_core stops')
do
    local cams = row(6, 20.0)
    local function downed()
        local W = boot({ cameras = cams })
        W.loaded[hashOf('blitz_flick_cam_shot')] = true
        W.net(W.B.Net.FLICK_DOWN, { matchId = 9, ids = { 1, 2, 3 }, causes = { 'weapon', 'weapon', 'weapon' } })
        W.drain()
        W.slow()
        ok(W.hidden() == 3 and #W.scripts() == 3, 'three down: three hides, three wrecks')
        return W
    end
    local W = downed()
    W.net(W.B.Net.FLICK_DOWN, { matchId = 10, ids = { 5 }, causes = { 'weapon' } })
    W.drain()
    ok(W.hidden() == 1 and #W.scripts() == 0, 'a new match: the last one\'s hides and wrecks gone, its own made')

    W = downed()
    W.B.State.me.state = 'lobby'
    W.B.State.match.state = 'waiting'
    W.slow()
    W.drain()
    ok(W.hidden() == 0 and #W.scripts() == 0, 'in the lobby: every hide and wreck gone')

    W = downed()
    W.switch(1)
    W.drain()
    ok(#W.scripts() == 0 and W.hidden() == #cams, 'off Season 2: the wrecks gone, and every camera hidden instead')

    W = downed()
    for _, fn in ipairs(W.handlers.onResourceStop or {}) do fn('br_core') end
    ok(W.hidden() == 0 and #W.scripts() == 0, 'br_core stopping: everything lifted at once, nothing left queued')

    W = downed()
    W.net(W.B.Net.FLICK_DOWN, { matchId = 9, reset = true })
    W.drain()
    ok(W.hidden() == 0 and #W.scripts() == 0, '`brflick reset`: every hide lifted')
end

describe('the downs: the snapshot replaces the list for its match')
do
    local cams = row(6, 20.0)
    local W = boot({ cameras = cams })
    W.net(W.B.Net.FLICK_DOWN, { matchId = 9, ids = { 1, 2 }, causes = { 'weapon', 'vehicle' } })
    W.drain()
    W.net(W.B.Net.SNAPSHOT, { flick = { matchId = 9, ids = { 2, 4 }, causes = { 'vehicle', 'weapon' } } })
    W.drain()
    eq(W.hidden(), 2, 'the snapshot\'s two, no more')
    eq(W.env.BR.Flick.counts().downs, 2, 'and the list is its list')
    W.net(W.B.Net.SNAPSHOT, { match = {} })
    W.drain()
    eq(W.hidden(), 0, 'a snapshot with none: none')
    W.net(W.B.Net.FLICK_DOWN, { matchId = 9, ids = { 'x', 0, 9999, 3.5 } })
    W.drain()
    eq(W.hidden(), 0, 'ids that are not cameras are dropped')
end

-- -------------------------------------------------------------- Season 1 ---

describe('Season 1: every camera hidden, a batch a frame, once per season move')
do
    local cams = row(60, 20.0)
    local W = boot({ cameras = cams, season = 1 })
    eq(W.hidden(), 0, 'nothing in the load itself')
    W.frame()
    eq(W.hidden(), 25, 'the first frame: 25')
    W.frame()
    W.frame()
    eq(W.hidden(), 60, 'three frames: all 60')
    ok(not W.has('frame', 'flick.work'), 'then no frame callback at all')
    local calls = W.hideCalls
    for _ = 1, 5 do W.slow() end
    W.drain()
    eq(W.hideCalls, calls, 'five passes on: no hide made again')
    W.switch(2)
    W.drain()
    eq(W.hidden(), 0, 'Season 2: every hide lifted')
    eq(W.hideCalls, calls + 60, 'one lift each')
    W.switch(1)
    W.drain()
    eq(W.hidden(), 60, 'and back')

    -- A CLIENT THAT DOES NOT KNOW ITS SEASON YET HIDES NOTHING: it would only
    -- show them all again when the season lands.
    W = boot({ cameras = cams, season = false })
    W.season = nil
    W.slow()
    W.drain()
    eq(W.hidden(), 0, 'no season yet: nothing hidden')
    W.switch(2)
    W.drain()
    eq(W.hidden(), 0, 'Season 2 lands: still nothing')
end

-- ----------------------------------------------------------- the coverage ---

describe('the coverage: only with flick pushes, only while the big map is up, in batches')
do
    local cams = row(250, 20.0)
    local W = boot({ cameras = cams })
    W.B.Native.frontendMap = true
    for _ = 1, 3 do W.tick() W.frame() end
    eq(W.circles(), 0, 'no push: no circle, map up or not')
    ok(not W.has('tick', 'flick.coverage'), 'and no coverage callback')
    W.net(W.B.Net.TERMINAL_SCAN, { matchId = 9, list = {} })
    eq(W.circles(), 0, 'a Scan push without flick: none')
    ok(not W.has('tick', 'flick.coverage'), 'still no callback')

    W.B.Native.frontendMap = false
    W.net(W.B.Net.TERMINAL_SCAN, { matchId = 9, list = {}, flick = true })
    ok(W.has('tick', 'flick.coverage'), 'a flick push arms the coverage')
    W.tick()
    W.frames(3)
    eq(W.circles(), 0, 'the map closed: none')
    W.net(W.B.Net.FLICK_DOWN, { matchId = 9, ids = { 1, 2 }, causes = { 'weapon', 'weapon' } })
    W.B.Native.frontendMap = true
    W.tick()
    eq(W.circles(), 0, 'the map rises: queued, nothing made in the TICK pass itself')
    W.frame()
    eq(W.circles(), W.B.Config.Flick.client.coverageBatch, 'one frame: a batch')
    W.drain()
    eq(W.circles(), 248, 'then one circle per live camera, none for the two down')
    local b = W.blips[next(W.blips)]
    ok(b.r == W.B.Config.Flick.rangeM and b.name == nil and b.offLegend == true,
        'rangeM, no name, off the legend')
    -- A CAMERA GOES DOWN WHILE THE MAP IS UP.
    W.net(W.B.Net.FLICK_DOWN, { matchId = 9, ids = { 3 }, causes = { 'weapon' } })
    W.drain()
    eq(W.circles(), 247, 'a camera down while the map is up loses its circle')
    -- THE MAP CLOSES.
    W.B.Native.frontendMap = false
    W.tick()
    W.drain()
    eq(W.circles(), 0, 'the map closes: every circle gone')
    -- THE PUSHES STOP.
    W.B.Native.frontendMap = true
    W.tick()
    W.drain()
    eq(W.circles(), 247, 'up again')
    W.now = W.now + 3 * W.B.Config.Terminals.fx.scanPingMs + 1
    W.tick()
    W.drain()
    eq(W.circles(), 0, 'three pings without a push: gone, map up or not')
    W.tick()
    ok(not W.has('tick', 'flick.coverage'), 'and the coverage callback with them')
end

describe('the coverage: never in the lobby, never off Season 2, gone as br_core stops')
do
    local cams = row(10, 20.0)
    local W = boot({ cameras = cams })
    W.B.Native.frontendMap = true
    W.net(W.B.Net.TERMINAL_SCAN, { matchId = 9, list = {}, flick = true })
    W.tick()
    W.drain()
    eq(W.circles(), 10, 'scanning, map up: ten')
    W.B.State.me.state = 'lobby'
    W.tick()
    W.drain()
    eq(W.circles(), 0, 'the lobby: none')
    W = boot({ cameras = cams, season = 1 })
    W.B.Native.frontendMap = true
    W.net(W.B.Net.TERMINAL_SCAN, { matchId = 9, list = {}, flick = true })
    W.tick()
    W.drain()
    eq(W.circles(), 0, 'Season 1: none')
    W = boot({ cameras = cams })
    W.B.Native.frontendMap = true
    W.net(W.B.Net.TERMINAL_SCAN, { matchId = 9, list = {}, flick = true })
    W.tick()
    W.drain()
    for _, fn in ipairs(W.handlers.onResourceStop or {}) do fn('br_core') end
    eq(W.circles(), 0, 'br_core stopping: none')
end

-- ---------------------------------------------------------------- the dev ---

describe('the dev command: brflick types the server\'s, and its own verbs read this client')
do
    local cams = row(3, 20.0)
    local W = boot({ cameras = cams })
    W.mapCamera(cams[1])
    W.commands.brflick(0, {})
    eq(W.executed[#W.executed], 'brflicksv list', '`brflick`: the server\'s list')
    W.commands.brflick(0, { 'down', '2' })
    eq(W.executed[#W.executed], 'brflicksv down 2', '`brflick down 2`')
    W.commands.brflick(0, { 'down', 'near' })
    eq(W.executed[#W.executed], 'brflicksv down 1', '`brflick down near`: the nearest camera')
    W.commands.brflick(0, { 'reset' })
    eq(W.executed[#W.executed], 'brflicksv reset', '`brflick reset`')
    W.commands.brflick(0, { 'near' })
    local line = W.printed[#W.printed] or ''
    ok(line:find('camera 1', 1, true) and line:find('broken false', 1, true) and line:find('upright', 1, true),
        '`brflick near` prints what this client reads off the nearest camera', line)
    W.commands.brflick(0, { 'coverage' })
    W.B.Native.frontendMap = true
    W.tick()
    W.drain()
    eq(W.circles(), 3, '`brflick coverage`: the big map\'s coverage without Scan')
end

-- --------------------------------------------------------------- the file ---

describe('the file: no scope-gate native, every BOOL read wrapped')
do
    local src = readFile(ROOT .. 'br_core/client/flick.lua') or ''
    local code = src:gsub('%-%-[^\n]*', '')
    for _, native in ipairs({ 'GetActivePlayers', 'GetPlayerFromServerId', 'GetPlayerPed%(' }) do
        ok(not code:find(native), 'client/flick.lua calls no ' .. native:gsub('%%', ''))
    end
    for _, native in ipairs({ 'HasObjectBeenBroken', 'HasEntityBeenDamagedByEntity',
                              'HasEntityBeenDamagedByAnyVehicle', 'DoesEntityExist', 'DoesBlipExist',
                              'HasModelLoaded', 'IsModelInCdimage' }) do
        local bare = 0
        for at in code:gmatch('()' .. native .. '%(') do
            if code:sub(math.max(1, at - 7), at - 1) ~= 'isTrue(' then bare = bare + 1 end
        end
        eq(bare, 0, native .. ' is only ever read through isTrue')
    end
    ok(not code:find('CreateModelHide%('), 'never CreateModelHide (it would hide a script\'s wreck)')
end

realPrint(('%d passed, %d failed'):format(pass, fail))
if fail > 0 then realExit(1) end
