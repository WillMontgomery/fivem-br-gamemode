-- Unit tests for the data center gate's client (#420): br_core/client/dcgate.lua
-- over modeled natives (docs/dcgate.md).
--
-- The property is a SEQUENCE -- which natives are called, when, how often, and
-- what the world holds after each step -- so the file runs in a Lua
-- environment of its own over a modeled engine: the gate's 27 map objects (the
-- leaves and arms, each this client's own copy, which streams out and back), a
-- door system that registers them by name and turns a lead to the open ratio
-- it is held at, attachments, the three loop bands with the FRAME and TICK
-- callbacks that come and go, the notice stack, the interact key, the season
-- and the mirror. Each block boots a fresh client.
--
--   the doors    nothing without the map pack; with it, all 27 registered
--                under the pack's names, locally, and locked shut the pack's
--                way; posed as their physics streams in, and a pass with
--                nothing to do writes nothing; a registration a stopped pack
--                took registered again
--   the cost     nothing in the lobby; away from the gate one position a
--                second and no callback; the TICK only near it, the FRAME only
--                while a lane folds
--   the prompt   the owner's words exactly, the key a hole for the player's
--                own interact key; once, at a reader of a shut lane, in a
--                match under way (the bus or playing), standing, on Season 2;
--                down when not
--   the press    one DCGATE_USE for the reader the prompt is up for, and not
--                again within the interval
--   the fold     a lane the server opens folds open over foldMs and back: the
--                leads to +-90 by the open ratio, the arm to its raise, each
--                follower on its lead's knuckle and turned -2 times its lead's
--                turn as it stands, so it mirrors its lead at every frame and
--                lies flat against it at 90; unlocked while it rides and let
--                go and locked once its lead is shut; the other lanes left
--                alone; turned back halfway with no jump
--   streamed in  a lane open before this client came near arrives open, its
--                followers found and riding; a follower that streams out and
--                back rides again
--   the settle   a lead the door system eases is ridden until it stops, open
--                and shut; one that turns after is found astray and ridden again
--   the word     DCGATE_STATE, the snapshot, the lobby and Season 1
--   br_core stopping, and the 'rotate' drive
--   the file     no scope-gate native, every BOOL read wrapped
--
-- Run via tools/verify.sh, or directly:  lua tools/test_dcgate_client.lua

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
local function near(got, want, tol, name)
    ok(type(got) == 'number' and math.abs(got - want) <= tol, name,
        ('got %s, want %s +- %s'):format(tostring(got), tostring(want), tostring(tol)))
end

local function readFile(path)
    local fh = io.open(path, 'rb')
    if not fh then return nil end
    local s = fh:read('a')
    fh:close()
    return s
end

local function wrap180(d)
    d = (d + 180.0) % 360.0
    return d - 180.0
end

-- ------------------------------------------------------------- the engine ---

local function hashOf(s) return 'h:' .. tostring(s) end

--- Boot a client. opts: pack (false: no map pack), season (1 or 2), match
--- (its state), me (a player state), at (the ped), objects (false: the gate
--- not streamed).
local function boot(opts)
    opts = opts or {}
    local W = {
        now = 500000, natives = 0, calls = {}, writes = {},
        season = opts.season or 2, pack = opts.pack ~= false,
        objects = {}, nextObj = 1, doors = {}, notices = {}, server = {},
        handlers = {}, loops = { frame = {}, tick = {}, slow = {} }, commands = {}, executed = {},
        watchers = {}, keys = {}, ped = 77, printed = {},
        at = opts.at and { x = opts.at.x, y = opts.at.y, z = opts.at.z } or { x = 0.0, y = 0.0, z = 45.5 },
    }
    local env = setmetatable({}, { __index = _G })
    local function n(name)
        W.natives = W.natives + 1
        W.calls[name] = (W.calls[name] or 0) + 1
    end
    --- A write to a door or an object, by its name or handle: what changed it.
    local function wrote(key, what)
        W.writes[#W.writes + 1] = { key = key, what = what }
    end
    env.print = function(s) W.printed[#W.printed + 1] = tostring(s) end
    env.GetGameTimer = function() return W.now end
    env.GetCurrentResourceName = function() return 'br_core' end
    env.PlayerPedId = function() n('PlayerPedId') return W.ped end
    env.GetHashKey = function(s) n('GetHashKey') return hashOf(s) end
    env.IsModelInCdimage = function(h) n('IsModelInCdimage') return W.pack and 1 or 0 end
    env.GetEntityCoords = function(h)
        n('GetEntityCoords')
        if h == W.ped then return { x = W.at.x, y = W.at.y, z = W.at.z } end
        local o = W.objects[h]
        return o and { x = o.x, y = o.y, z = o.z } or { x = 0.0, y = 0.0, z = 0.0 }
    end

    --- THE GATE'S MAP OBJECTS: each part's copy on this client, at its placed
    --- origin and heading, until it streams out. `only`: that one part.
    function W.streamIn(only)
        for _, lane in ipairs(W.P.lanes) do
            local list = {}
            for _, r in ipairs(lane.leads) do list[#list + 1] = { r = r, kind = 'lead' } end
            for _, r in ipairs(lane.follows) do list[#list + 1] = { r = r, kind = 'follow' } end
            list[#list + 1] = { r = lane.arm, kind = 'arm' }
            for _, it in ipairs(list) do
              if not only or it.r.id == only then
                local h = W.nextObj
                W.nextObj = h + 1
                W.objects[h] = { id = it.r.id, kind = it.kind, model = hashOf(it.r.model), x = it.r.x,
                                 y = it.r.y, z = it.r.z, h = it.r.h, placed = it.r.h, rot = { x = 0.0, y = 0.0, z = it.r.h } }
              end
            end
        end
    end
    function W.streamOut(match)
        for h, o in pairs(W.objects) do
            if not match or o.id:find(match, 1, true) then W.objects[h] = nil end
        end
    end
    function W.obj(id)
        for h, o in pairs(W.objects) do if o.id == id then return o, h end end
        return nil
    end
    env.GetClosestObjectOfType = function(x, y, z, r, model)
        n('GetClosestObjectOfType')
        local best, bestD = 0, r * r
        for h, o in pairs(W.objects) do
            if o.model == model then
                local d = (o.x - x) ^ 2 + (o.y - y) ^ 2 + (o.z - z) ^ 2
                if d <= bestD then best, bestD = h, d end
            end
        end
        return best
    end
    env.DoesEntityExist = function(h) n('DoesEntityExist') return W.objects[h] ~= nil and 1 or 0 end
    env.GetEntityHeading = function(h) n('GetEntityHeading') return W.objects[h] and W.objects[h].h % 360.0 or 0.0 end
    env.GetEntityRotation = function(h)
        n('GetEntityRotation')
        local o = W.objects[h]
        return o and { x = o.rot.x, y = o.rot.y, z = o.rot.z } or { x = 0.0, y = 0.0, z = 0.0 }
    end
    env.SetEntityRotation = function(h, x, y, z, order, p)
        n('SetEntityRotation')
        local o = W.objects[h]
        if o then
            o.rot = { x = x, y = y, z = z }
            o.h = z
            o.order = order
            wrote(o.id, 'rotation')
        end
    end
    env.SetEntityCoordsNoOffset = function(h, x, y, z)
        n('SetEntityCoordsNoOffset')
        local o = W.objects[h]
        if o then
            o.x, o.y, o.z = x, y, z
            wrote(o.id, 'coords')
        end
    end
    env.FreezeEntityPosition = function(h, f)
        n('FreezeEntityPosition')
        if W.objects[h] then
            W.objects[h].frozen = f
            wrote(W.objects[h].id, 'freeze')
        end
    end
    env.AttachEntityToEntity = function(h, to, bone, ox, oy, oz, rx, ry, rz, p9, soft, collision, isPed, order, fixed)
        n('AttachEntityToEntity')
        local o = W.objects[h]
        if o then
            o.on = to
            o.att = { bone = bone, ox = ox, oy = oy, oz = oz, rx = rx, ry = ry, rz = rz, collision = collision,
                      isPed = isPed, order = order, fixed = fixed }
            o.attaches = (o.attaches or 0) + 1
            wrote(o.id, 'attach')
        end
    end
    env.DetachEntity = function(h, dyn, coll)
        n('DetachEntity')
        local o = W.objects[h]
        if o then
            o.on, o.att = nil, nil
            o.detaches = (o.detaches or 0) + 1
            wrote(o.id, 'detach')
        end
    end
    env.IsEntityAttached = function(h) n('IsEntityAttached') return (W.objects[h] and W.objects[h].on) and 1 or 0 end

    --- THE DOOR SYSTEM: a door by its name's hash, with its model and place, its
    --- state and its open ratio. A lead held at a ratio turns by ratio * 90
    --- about +z -- the engine honoring the ratio the 'ratio' drive asks of it:
    --- at once, or with W.lag set, eased there at most W.lag degrees a frame
    --- after W.stall frames of not moving at all (W.engine below; a SLOW step
    --- is sixty frames of it).
    local function doorObject(d)
        for h, o in pairs(W.objects) do
            if o.model == d.model and math.abs(o.x - d.x) < 0.01 and math.abs(o.y - d.y) < 0.01 then
                return o, h
            end
        end
        return nil
    end
    W.doorObject = doorObject
    env.AddDoorToSystem = function(hash, model, x, y, z, p5, scriptDoor, isLocal)
        n('AddDoorToSystem')
        W.doors[hash] = { model = model, x = x, y = y, z = z, p5 = p5, scriptDoor = scriptDoor,
                          isLocal = isLocal, state = 0, ratio = 0.0, states = {} }
        wrote(hash, 'add')
    end
    env.RemoveDoorFromSystem = function(hash)
        n('RemoveDoorFromSystem')
        W.doors[hash] = nil
        wrote(hash, 'remove')
    end
    env.IsDoorRegisteredWithSystem = function(hash)
        n('IsDoorRegisteredWithSystem')
        return W.doors[hash] ~= nil and 1 or 0
    end
    env.DoorSystemGetIsPhysicsLoaded = function(hash)
        n('DoorSystemGetIsPhysicsLoaded')
        local d = W.doors[hash]
        return (d and doorObject(d)) and 1 or 0
    end
    env.DoorSystemSetOpenRatio = function(hash, r, req, force)
        n('DoorSystemSetOpenRatio')
        local d = W.doors[hash]
        if not d then return end
        d.ratio = r
        wrote(hash, 'ratio')
        local o = doorObject(d)
        if o and o.kind == 'lead' and not o.frozen then
            local goal = o.placed + r * 90.0
            if not W.lag then
                o.h = goal
            elseif o.goal ~= goal then
                o.goal, o.wait = goal, W.stall or 0
            end
        end
    end
    --- One frame of the engine: each lead with a goal turned toward it.
    function W.engine()
        if not W.lag then return end
        for _, o in pairs(W.objects) do
            if o.goal ~= nil and not o.frozen then
                if (o.wait or 0) > 0 then
                    o.wait = o.wait - 1
                else
                    local d = o.goal - o.h
                    if math.abs(d) <= W.lag then o.h = o.goal else o.h = o.h + (d > 0 and W.lag or -W.lag) end
                end
            end
        end
    end
    env.DoorSystemSetDoorState = function(hash, state, req, force)
        n('DoorSystemSetDoorState')
        local d = W.doors[hash]
        if not d then return end
        d.state = state
        d.states[#d.states + 1] = state
        wrote(hash, 'state')
    end
    env.DoorSystemGetDoorState = function(hash) n('DoorSystemGetDoorState') return W.doors[hash] and W.doors[hash].state or -1 end
    env.DoorSystemGetOpenRatio = function(hash) n('DoorSystemGetOpenRatio') return W.doors[hash] and W.doors[hash].ratio or 0.0 end

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
                         'br_lib/config/dcgate.lua', 'br_lib/config/dcgate_parts.lua',
                         'br_lib/shared/dcgate_solve.lua' }) do
        assert(loadfile(ROOT .. f, 't', env))()
    end
    local B = env.BR
    W.P = B.Config.DcGate.parts
    W.C = B.Config.DcGate
    B.NativeTruthy = function(v) return v == true or v == 1 end
    B.Season = {
        has = function(id)
            if id ~= 'dcgate' then error('asked ' .. tostring(id)) end
            return W.season ~= nil and W.season >= 2
        end,
        current = function() return W.season end,
        onChange = function(fn) W.watchers[#W.watchers + 1] = fn end,
    }
    B.State = {
        match = { state = opts.match or B.MatchState.PLAYING },
        me = { state = opts.me or B.PlayerState.ALIVE },
    }
    B.Notify = function(text, tone, o)
        W.notices[#W.notices + 1] = { text = text, tone = tone, opts = o }
    end
    B.NotifyClear = function(key)
        W.notices[#W.notices + 1] = { clear = key }
    end
    B.Keys = {
        uiScreen = nil,
        on = function(action, fn, live)
            W.keys[action] = W.keys[action] or {}
            table.insert(W.keys[action], fn)
            W.keyLive = W.keyLive or {}
            W.keyLive[action] = live
        end,
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
            for _, list in pairs(W.loops) do
                for id, x in pairs(list) do
                    if x == e then list[id] = nil end
                end
            end
        end,
    }
    if opts.objects ~= false then W.streamIn() end
    assert(loadfile(ROOT .. 'br_core/client/dcgate.lua', 't', env))()
    W.env, W.B, W.G = env, B, B.DcGate

    local function step(band)
        local ids = {}
        for id in pairs(W.loops[band]) do ids[#ids + 1] = id end
        table.sort(ids)
        for _, id in ipairs(ids) do
            local e = W.loops[band][id]
            if e then e.fn() end
        end
    end
    function W.slow()
        W.now = W.now + 1000
        for _ = 1, 60 do W.engine() end
        step('slow')
    end
    function W.tick() W.now = W.now + 100 step('tick') end
    function W.frame(ms)
        W.now = W.now + (ms or 16)
        W.engine()
        step('frame')
    end
    function W.frames(k, ms) for _ = 1, k do W.frame(ms) end end
    function W.has(band, name)
        for _, e in pairs(W.loops[band]) do if e.name == name then return true end end
        return false
    end
    --- Frames until the fold is done (the FRAME callback gone), at most `cap`.
    function W.settle(cap)
        local k = 0
        while W.has('frame', 'dcgate.fold') and k < (cap or 1000) do
            W.frame()
            k = k + 1
        end
        return k
    end
    function W.net(name, d)
        for _, fn in ipairs(W.handlers[name] or {}) do fn(d) end
    end
    function W.press(down)
        for _, fn in ipairs(W.keys.interact or {}) do fn(down ~= false) end
    end
    function W.switch(s)
        local before = W.season
        W.season = s
        for _, fn in ipairs(W.watchers) do fn(s, before) end
    end
    function W.reset()
        W.natives, W.calls, W.writes = 0, {}, {}
    end
    function W.door(id) return W.doors[hashOf('brdc_door_' .. id)] end
    function W.uses()
        local out = {}
        for _, s in ipairs(W.server) do
            if s.ev == B.Net.DCGATE_USE then out[#out + 1] = s.d end
        end
        return out
    end
    --- The writes this step made to anything of these lanes' (by id substring).
    function W.wroteTo(sub)
        local k = 0
        for _, w in ipairs(W.writes) do
            local key = tostring(w.key)
            if key:find(sub, 1, true) then k = k + 1 end
        end
        return k
    end
    --- A follower's heading in the world: its lead's, turned by its attachment.
    function W.worldHeading(o)
        if o.on and W.objects[o.on] then return W.objects[o.on].h + o.att.rz end
        return o.h
    end
    return W
end

-- The places, off the real registry.
local P0 = (function()
    local env = { BR = {} }
    assert(loadfile(ROOT .. 'br_lib/config/dcgate_parts.lua', 't', env))()
    return env.BR.Config.DcGate.parts
end)()
local READER = {}
for i, r in ipairs(P0.readers) do READER[r.id] = { i = i, x = r.x, y = r.y, z = r.z } end
local IN2 = READER['gate.lane2.reader_in']
--- Standing at lane 2's in-reader: a ped about a meter over the grade.
local AT_IN2 = { x = IN2.x, y = IN2.y + 1.0, z = IN2.z - 0.2 }
--- Inside the gate's near radius but far from every reader.
local NEAR = { x = P0.center.x, y = P0.center.y + P0.radius + 60.0, z = 45.5 }
local FAR = { x = P0.center.x + 1000.0, y = P0.center.y, z = 45.5 }

-- =========================================================================
-- THE DOORS
-- =========================================================================

describe('the doors: nothing at all without the map pack')
do
    local W = boot({ pack = false, at = AT_IN2 })
    local n = 0
    for _ in pairs(W.doors) do n = n + 1 end
    eq(n, 0, 'no door registered')
    W.reset()
    for _ = 1, 9 do W.slow() end
    eq(W.calls.IsModelInCdimage, nil, 'the pack asked again only every tenth pass')
    eq(W.calls.GetEntityCoords, nil, 'and nothing else asked')
    W.slow()
    eq(W.calls.IsModelInCdimage, 1, 'the tenth: asked again')
    W.pack = true
    for _ = 1, 10 do W.slow() end
    n = 0
    for _ in pairs(W.doors) do n = n + 1 end
    eq(n, 27, 'a pack that mounts later is picked up, and its doors registered')
end

describe('the doors: all 27 registered under the pack\'s names, locally, and locked shut its way')
do
    local W = boot({ at = FAR })
    local n = 0
    for _ in pairs(W.doors) do n = n + 1 end
    eq(n, 27, 'the 24 leaves and 3 arms')
    local bad = 0
    for _, lane in ipairs(P0.lanes) do
        local parts = {}
        for _, r in ipairs(lane.leads) do parts[#parts + 1] = r end
        for _, r in ipairs(lane.follows) do parts[#parts + 1] = r end
        parts[#parts + 1] = lane.arm
        for _, r in ipairs(parts) do
            local d = W.door(r.id)
            if not (d and d.model == hashOf(r.model) and d.x == r.x and d.y == r.y and d.z == r.z
                    and d.isLocal == true and d.scriptDoor == false and d.ratio == 0.0
                    and d.states[1] == 4 and d.states[2] == 1 and d.state == 1) then
                bad = bad + 1
            end
        end
    end
    eq(bad, 0, 'each by its model at its origin, isLocal, ratio 0, forced shut (4) then held locked (1)')
    -- A NAME THE PACK HAS ALREADY REGISTERED IS TAKEN BACK AND REGISTERED AGAIN.
    W.doors = {}
    local h = hashOf('brdc_door_gate.lane1.outer.lead_l')
    W.doors[h] = { model = 'stale', states = {} }
    W.reset()
    W.env.BR.Config.DcGate.client.nearM = 200.0
    W.at.x, W.at.y = NEAR.x, NEAR.y
    W.slow()
    ok(W.door('gate.lane1.outer.lead_l') and W.door('gate.lane1.outer.lead_l').model == hashOf('brdc_bifold_lead_l'),
        'a stopped pack took the registrations: registered again, the stale one replaced')
end

describe('the cost: nothing in the lobby; away from the gate one position a second and no callback')
do
    local W = boot({ at = FAR, me = 'lobby' })
    W.reset()
    for _ = 1, 5 do W.slow() end
    eq(W.natives, 0, 'in the lobby: no native at all')
    W.B.State.me.state = W.B.PlayerState.ALIVE
    W.reset()
    for _ = 1, 5 do W.slow() end
    eq(W.natives, 10, 'in a match, far away: PlayerPedId and GetEntityCoords, once a second')
    ok(not W.has('tick', 'dcgate.prompt') and not W.has('frame', 'dcgate.fold'), 'no TICK, no FRAME')
    W.net(W.B.Net.DCGATE_STATE, { matchId = 1, open = { false, true, false } })
    W.reset()
    W.slow()
    eq(W.natives, 2, 'a lane opening across the map costs this client nothing')
    ok(not W.has('frame', 'dcgate.fold'), 'and folds nothing')
    eq(W.G.counts().lanes[2].pose, 1.0, 'its pose is simply open, for when this client comes near')
end

describe('the doors: posed as their physics streams in; a pass with nothing to do writes nothing')
do
    local W = boot({ at = FAR, objects = false })
    W.at.x, W.at.y = NEAR.x, NEAR.y
    W.slow()
    eq(W.G.counts().near, true, 'near the gate')
    W.reset()
    W.slow()
    eq(#W.writes, 0, 'nothing streamed in: nothing written')
    eq(W.calls.DoorSystemGetIsPhysicsLoaded, 27, 'each door\'s physics read once')
    W.streamIn()
    W.reset()
    W.slow()
    local shutNow = 0
    for _, d in pairs(W.doors) do if d.state == 1 and d.ratio == 0.0 then shutNow = shutNow + 1 end end
    eq(shutNow, 27, 'streamed in: every door posed shut and locked')
    ok(#W.writes > 0, 'by writes')
    W.reset()
    W.slow()
    eq(#W.writes, 0, 'the next pass: nothing written')
    eq(W.calls.DoorSystemGetIsPhysicsLoaded, 27, 'only the reads')
    eq(W.calls.GetClosestObjectOfType, nil, 'and no search: a shut lane needs no handle')
end

-- =========================================================================
-- THE PROMPT AND THE PRESS
-- =========================================================================

describe('the prompt: the owner\'s words, once, at a reader of a shut lane')
do
    local W = boot({ at = AT_IN2 })
    eq(W.G.PROMPT_TEXT, 'Press {key:brinteract} to open the gate',
        'the text: "Press E to open the gate", the E the player\'s own interact key as a hole')
    eq(W.B.KeyToken('brinteract'), '{key:brinteract}', 'built by BR.KeyToken')
    local kb = readFile(ROOT .. 'br_core/client/keybinds.lua') or ''
    ok(kb:find("hold%('interact',%s*'brinteract'") ~= nil, 'and brinteract is the interact binding the page resolves')
    W.slow()
    ok(W.has('tick', 'dcgate.prompt'), 'near the gate: the TICK callback')
    W.tick()
    eq(#W.notices, 1, 'one notice')
    local nt = W.notices[1]
    ok(nt and nt.text == W.G.PROMPT_TEXT and nt.tone == 'info' and nt.opts.key == 'dcgate.reader'
        and nt.opts.sticky == true and nt.opts.cue == false, 'keyed, sticky and silent')
    for _ = 1, 20 do W.tick() end
    eq(#W.notices, 1, 'and not sent again while the player stands there')
    W.at.y = IN2.y + W.C.readerM + 0.2
    W.tick()
    ok(W.notices[2] and W.notices[2].clear == 'dcgate.reader', 'a step past readerM: taken down')
    W.at.y = AT_IN2.y
    W.tick()
    eq(#W.notices, 3, 'back: up again')
    W.B.State.me.state = W.B.PlayerState.DBNO
    W.tick()
    ok(W.notices[4] and W.notices[4].clear, 'downed: down')
    W.B.State.me.state = W.B.PlayerState.ALIVE
    W.tick()
    W.net(W.B.Net.DCGATE_STATE, { matchId = 1, open = { false, true, false } })
    W.tick()
    ok(W.notices[#W.notices].clear, 'the lane open: down')
    W.net(W.B.Net.DCGATE_STATE, { matchId = 1, open = { false, false, false } })
    W.tick()
    ok(W.notices[#W.notices].text == W.G.PROMPT_TEXT, 'shut again (or folding shut): up -- a press opens it again')
    W.B.State.match.state = W.B.MatchState.ENDED
    W.tick()
    ok(W.notices[#W.notices].clear, 'the match over: down')
    W.B.State.match.state = W.B.MatchState.BUS
    W.tick()
    ok(W.notices[#W.notices].text == W.G.PROMPT_TEXT, 'the bus still flying (this player jumped early and landed): up')
    W.B.State.match.state = W.B.MatchState.PLAYING
    W.tick()
    W.B.Keys.uiScreen = 'inventory'
    W.tick()
    ok(W.notices[#W.notices].clear, 'one of our screens up: down')
    W.B.Keys.uiScreen = nil
    W.tick()
    W.switch(1)
    ok(W.notices[#W.notices].clear and not W.has('tick', 'dcgate.prompt'), 'Season 1: down, and no TICK')
    W.slow()
    W.tick()
    ok(W.notices[#W.notices].clear, 'and it stays down')
    W.switch(2)
    W.slow()
    W.tick()
    ok(W.notices[#W.notices].text == W.G.PROMPT_TEXT, 'Season 2 again: up')
    local before = #W.notices
    W.at.x, W.at.y = FAR.x, FAR.y
    W.slow()
    ok(not W.has('tick', 'dcgate.prompt') and W.notices[before + 1] and W.notices[before + 1].clear,
        'away from the gate: the TICK goes, and the prompt with it')
end

describe('the press: one DCGATE_USE for the reader the prompt is up for, not again within the interval')
do
    local W = boot({ at = AT_IN2 })
    W.slow()
    W.press(true)
    eq(#W.uses(), 0, 'before the prompt is up: nothing')
    W.tick()
    W.press(true)
    local u = W.uses()
    ok(#u == 1 and u[1].reader == IN2.i, 'pressed at it: the reader\'s index, and nothing else',
        u[1] and u[1].reader)
    W.press(false)
    eq(#W.uses(), 1, 'the release asks nothing')
    W.now = W.now + 500
    W.press(true)
    eq(#W.uses(), 1, 'again half a second later: not asked')
    W.now = W.now + 600
    W.press(true)
    eq(#W.uses(), 2, 'past the interval: asked')
    W.at.x = IN2.x + 10.0
    W.tick()
    W.now = W.now + 2000
    W.press(true)
    eq(#W.uses(), 2, 'away from the reader: nothing')
    eq(W.keyLive and W.keyLive.interact, nil, 'interact stays read as it always is (no `live` narrower than its other listeners)')
end

-- =========================================================================
-- THE FOLD
-- =========================================================================

--- The lane 2 parts of a booted client, by role.
local function laneParts(W, n)
    local out = { leads = {}, follows = {} }
    for _, lane in ipairs(W.P.lanes) do
        if lane.lane == n then
            for _, r in ipairs(lane.leads) do out.leads[#out.leads + 1] = { r = r, o = W.obj(r.id), d = W.door(r.id) } end
            for _, r in ipairs(lane.follows) do
                out.follows[#out.follows + 1] = { r = r, o = W.obj(r.id), d = W.door(r.id), lead = lane.leads[r.lead] }
            end
            out.arm = { r = lane.arm, o = W.obj(lane.arm.id), d = W.door(lane.arm.id) }
        end
    end
    return out
end

--- How far each follower is from mirroring its lead (degrees), the worst.
local function mirrorError(W, L)
    local worst = 0.0
    for _, f in ipairs(L.follows) do
        local lead = W.obj(f.lead.id)
        local turned = wrap180(lead.h - f.lead.h)
        local want = f.r.h - turned
        worst = math.max(worst, math.abs(wrap180(W.worldHeading(f.o) - want)))
    end
    return worst
end

describe('the fold: a lane the server opens folds open over foldMs -- the bi-fold at every frame')
do
    local W = boot({ at = AT_IN2 })
    W.slow()
    W.slow()
    W.reset()
    W.net(W.B.Net.DCGATE_STATE, { matchId = 1, open = { false, true, false } })
    ok(W.has('frame', 'dcgate.fold'), 'the FRAME callback, now')
    local L = laneParts(W, 2)
    eq(W.calls.GetClosestObjectOfType, 9, 'the lane\'s nine parts found first, once')
    local riding = 0
    for _, f in ipairs(L.follows) do
        local lead = W.obj(f.lead.id)
        if f.o.on and W.objects[f.o.on] == lead and f.o.att.bone == 0 and f.o.att.ox == f.r.ox
           and f.o.att.oy == f.r.oy and f.o.att.oz == f.r.oz and f.o.att.rz == 0.0 and f.o.att.collision == true
           and f.d.state == 0 then
            riding = riding + 1
        end
    end
    eq(riding, 4, 'every follower on its lead\'s knuckle, bone 0, at the kit\'s offset, with collision, unlocked')
    local worstMirror, worstStep, lastH = 0.0, 0.0, nil
    local lead1 = L.leads[1].o
    local frames = 0
    while W.G.counts().lanes[2].pose < 1.0 and frames < 1000 do
        W.frame(16)
        frames = frames + 1
        worstMirror = math.max(worstMirror, mirrorError(W, L))
        if lastH then worstStep = math.max(worstStep, math.abs(wrap180(lead1.h - lastH))) end
        lastH = lead1.h
        if frames == 125 then
            near(wrap180(lead1.h - L.leads[1].r.h), 45.0, 0.5, 'halfway in time (2 s): halfway open, 45')
        end
    end
    near(frames * 16, W.C.foldMs, 32, 'open after foldMs')
    near(worstMirror, 0.0, 1e-6, 'each follower mirrors its lead about the gate line at every frame')
    ok(worstStep < 1.0, 'and the lead turns smoothly: under a degree a frame', worstStep)
    for _, l in ipairs(L.leads) do
        near(wrap180(l.o.h - l.r.h), l.r.sense * 90.0, 1e-6, l.r.id .. ' turned ' .. (l.r.sense * 90) .. ', its sense')
        near(l.d.ratio, l.r.sense * 1.0, 1e-9, l.r.id .. ': held at open ratio ' .. l.r.sense)
        eq(l.d.state, 1, l.r.id .. ': held locked there')
    end
    for _, f in ipairs(L.follows) do
        local lead = W.obj(f.lead.id)
        near(math.abs(wrap180(W.worldHeading(f.o) - lead.h)), 180.0, 1e-6, f.r.id .. ' lies flat against its lead at 90')
    end
    near(L.arm.d.ratio, W.C.armRaiseDeg / 90.0, 1e-9, 'the arm raised to armRaiseDeg by its ratio')
    eq(W.wroteTo('lane1') + W.wroteTo('lane3'), 0, 'lanes 1 and 3: nothing written')
    local k = W.settle(20)
    ok(k <= 6 and not W.has('frame', 'dcgate.fold'), 'the followers ridden a few frames more, then the FRAME goes', k)
    W.slow()
    W.reset()
    W.slow()
    eq(#W.writes, 0, 'open and still: a pass writes nothing')
end

describe('the fold: back shut, the followers let go and locked; turned back halfway with no jump')
do
    local W = boot({ at = AT_IN2 })
    W.slow()
    W.net(W.B.Net.DCGATE_STATE, { matchId = 1, open = { false, true, false } })
    W.settle()
    W.slow()
    local L = laneParts(W, 2)
    W.net(W.B.Net.DCGATE_STATE, { matchId = 1, open = { false, false, false } })
    ok(W.has('frame', 'dcgate.fold'), 'shut: it folds back')
    local worst = 0.0
    local frames = 0
    while W.has('frame', 'dcgate.fold') and frames < 1000 do
        W.frame(16)
        frames = frames + 1
        worst = math.max(worst, mirrorError(W, L))
    end
    near(worst, 0.0, 1e-6, 'mirrored on the way back too')
    for _, l in ipairs(L.leads) do
        ok(l.d.ratio == 0.0 and l.d.state == 1 and math.abs(wrap180(l.o.h - l.r.h)) < 1e-9, l.r.id .. ': shut and locked')
    end
    for _, f in ipairs(L.follows) do
        local s = f.d.states
        ok(f.o.on == nil and f.o.detaches == 1 and f.d.ratio == 0.0 and s[#s - 1] == 4 and s[#s] == 1,
            f.r.id .. ': let go once its lead is shut, and locked the pack\'s way')
    end
    ok(L.arm.d.ratio == 0.0 and L.arm.d.state == 1, 'the arm down and locked')

    -- TURNED BACK HALFWAY.
    W.net(W.B.Net.DCGATE_STATE, { matchId = 1, open = { false, true, false } })
    W.frames(90)
    local mid = wrap180(L.leads[1].o.h - L.leads[1].r.h)
    ok(mid > 20 and mid < 70, 'part open', mid)
    W.net(W.B.Net.DCGATE_STATE, { matchId = 1, open = { false, false, false } })
    local last, worstStep = L.leads[1].o.h, 0.0
    frames = 0
    while W.has('frame', 'dcgate.fold') and frames < 1000 do
        W.frame(16)
        frames = frames + 1
        worstStep = math.max(worstStep, math.abs(wrap180(L.leads[1].o.h - last)))
        last = L.leads[1].o.h
    end
    ok(worstStep < 1.0, 'turned back: it runs back from where it was, no jump', worstStep)
    ok(frames * 16 < W.C.foldMs, 'and sooner than a whole fold')
    ok(math.abs(wrap180(L.leads[1].o.h - L.leads[1].r.h)) < 1e-9 and L.follows[1].o.on == nil, 'shut, let go')
end

describe('streamed in: a lane open before this client came near arrives open, its followers riding')
do
    local W = boot({ at = FAR, objects = false })
    W.slow()
    W.net(W.B.Net.DCGATE_STATE, { matchId = 1, open = { true, false, false } })
    ok(not W.has('frame', 'dcgate.fold'), 'far away: nothing folds')
    W.at.x, W.at.y = NEAR.x, NEAR.y
    W.slow()
    W.streamIn()
    W.reset()
    W.slow()
    local L = laneParts(W, 1)
    for _, l in ipairs(L.leads) do
        ok(math.abs(wrap180(l.o.h - l.r.h) - l.r.sense * 90.0) < 1e-6, l.r.id .. ' arrives open')
    end
    local riding = 0
    for _, f in ipairs(L.follows) do
        if f.o.on then riding = riding + 1 end
    end
    eq(riding, 4, 'its followers found and riding')
    near(mirrorError(W, L), 0.0, 1e-6, 'folded flat against their leads')
    local other = laneParts(W, 2)
    ok(other.leads[1].d.ratio == 0.0 and other.follows[1].o.on == nil, 'lane 2, shut, posed shut')
    W.settle(20)
    W.reset()
    W.slow()
    eq(#W.writes, 0, 'the next pass writes nothing')
    -- A FOLLOWER THAT STREAMS OUT AND BACK RIDES AGAIN.
    W.streamOut('gate.lane1.outer.follow_l')
    W.reset()
    W.slow()
    eq(#W.writes, 0, 'a follower streamed out: nothing to write to')
    W.streamIn('gate.lane1.outer.follow_l')
    W.slow()
    W.settle(20)
    local f = W.obj('gate.lane1.outer.follow_l')
    ok(f and f.on ~= nil, 'the follower that streamed back in rides its lead again')
    near(mirrorError(W, laneParts(W, 1)), 0.0, 1e-6, 'folded')
end

describe('a lead the door system eases: the followers ride it all the way, open and shut')
do
    local W = boot({ at = FAR, objects = false })
    W.slow()
    W.net(W.B.Net.DCGATE_STATE, { matchId = 1, open = { true, false, false } })
    W.at.x, W.at.y = NEAR.x, NEAR.y
    W.slow()
    W.streamIn()
    W.lag = 1.0
    W.slow()
    local L = laneParts(W, 1)
    local k = W.settle(400)
    ok(k > 90 and not W.has('frame', 'dcgate.fold'),
        'streamed in open, the leads easing a degree a frame: ridden until they stopped, then the FRAME goes', k)
    for _, l in ipairs(L.leads) do
        near(wrap180(l.o.h - l.r.h), l.r.sense * 90.0, 1e-6, l.r.id .. ' eased all the way open')
    end
    near(mirrorError(W, L), 0.0, 1e-6, 'every follower folded flat against its lead, not where its lead began')
    W.reset()
    W.slow()
    eq(#W.writes, 0, 'the next pass writes nothing')

    W.lag = 0.25
    W.net(W.B.Net.DCGATE_STATE, { matchId = 1, open = { false, false, false } })
    local early, worst, frames = 0, 0.0, 0
    while W.has('frame', 'dcgate.fold') and frames < 2000 do
        W.frame(16)
        frames = frames + 1
        worst = math.max(worst, mirrorError(W, L))
        for _, f in ipairs(L.follows) do
            local lead = W.obj(f.lead.id)
            if f.o.on == nil and math.abs(wrap180(lead.h - f.lead.h)) > 1e-6 then early = early + 1 end
        end
    end
    ok(frames * 16 > W.C.foldMs + 1000, 'shut behind leads that lag a whole second and more: the settle waits', frames)
    near(worst, 0.0, 1e-6, 'every follower mirrors its lagging lead at every frame')
    eq(early, 0, 'and none is let go before its lead is shut')
    local gone = 0
    for _, f in ipairs(L.follows) do if f.o.on == nil then gone = gone + 1 end end
    eq(gone, 4, 'then all four are')
end

describe('a lead that turns after the settle: the next pass finds its followers astray and rides them again')
do
    local W = boot({ at = FAR, objects = false })
    W.slow()
    W.net(W.B.Net.DCGATE_STATE, { matchId = 1, open = { true, false, false } })
    W.at.x, W.at.y = NEAR.x, NEAR.y
    W.slow()
    W.streamIn()
    W.lag, W.stall = 3.0, 30
    W.slow()
    local L = laneParts(W, 1)
    W.settle(400)
    ok(not W.has('frame', 'dcgate.fold'), 'the leads stood still through the settle, so it ended')
    for _ = 1, 60 do W.engine() end
    ok(mirrorError(W, L) > 10.0, 'then the engine turned them: the followers are off', mirrorError(W, L))
    W.slow()
    W.settle(400)
    near(mirrorError(W, L), 0.0, 1e-6, 'the next pass rode them again: folded flat')
    W.reset()
    W.slow()
    eq(#W.writes, 0, 'and the pass after writes nothing')
end

describe('near: as far as a leaf is drawn (its lodDist, 300 m)')
do
    local W = boot({ at = { x = P0.center.x, y = P0.center.y + 290.0, z = 45.5 } })
    W.slow()
    eq(W.G.counts().near, true, '290 m from the gate\'s middle: its doors kept posed')
    W.net(W.B.Net.DCGATE_STATE, { matchId = 1, open = { false, true, false } })
    ok(W.has('frame', 'dcgate.fold'), 'and a lane opening folds where it is seen')
    W.at.y = P0.center.y + P0.radius + W.C.client.nearM + 1.0
    W.slow()
    eq(W.G.counts().near, false, 'past the leaves\' reach: not')
end

-- =========================================================================
-- THE WORD
-- =========================================================================

describe('the word: DCGATE_STATE, the snapshot, the lobby, Season 1')
do
    local W = boot({ at = FAR })
    W.slow()
    W.net(W.B.Net.DCGATE_STATE, { matchId = 4, open = { true, false, true } })
    local k = W.G.counts()
    ok(k.lanes[1].target == 1 and k.lanes[2].target == 0 and k.lanes[3].target == 1 and k.match == 4,
        'the server\'s word: lanes 1 and 3 open in match 4')
    W.net(W.B.Net.SNAPSHOT, { dcgate = { matchId = 5, open = { false, true, false } } })
    k = W.G.counts()
    ok(k.lanes[1].target == 0 and k.lanes[2].target == 1 and k.match == 5, 'a snapshot replaces it')
    W.net(W.B.Net.SNAPSHOT, { flick = {} })
    k = W.G.counts()
    ok(k.lanes[2].target == 0 and k.match == nil, 'a snapshot with none: every lane shut')
    W.net(W.B.Net.DCGATE_STATE, { matchId = 6, open = { false, true, false } })
    W.B.State.me.state = W.B.PlayerState.LOBBY
    W.slow()
    k = W.G.counts()
    ok(k.lanes[2].target == 0 and k.match == nil, 'the lobby: every lane shut, the word forgotten')
    W.B.State.me.state = W.B.PlayerState.ALIVE
    W.net(W.B.Net.DCGATE_STATE, { matchId = 7, open = { false, true, false } })
    W.switch(1)
    eq(W.G.counts().lanes[2].target, 0, 'Season 1: shut')
    W.net(W.B.Net.DCGATE_STATE, { matchId = 7, open = { false, true, false } })
    eq(W.G.counts().lanes[2].target, 0, 'and a word heard on Season 1 opens nothing')
    W.switch(2)
    W.net(W.B.Net.DCGATE_STATE, { matchId = 7, open = { 'yes', true, 1 } })
    k = W.G.counts()
    ok(k.lanes[1].target == 0 and k.lanes[2].target == 1 and k.lanes[3].target == 0, 'only `true` opens a lane')
    -- Season 1 near the gate: the open lane folds shut, and the doors stay locked.
    local N = boot({ at = AT_IN2 })
    N.slow()
    N.net(N.B.Net.DCGATE_STATE, { matchId = 1, open = { false, true, false } })
    N.settle()
    N.switch(1)
    ok(N.has('frame', 'dcgate.fold'), 'Season 1 near an open lane: it folds shut')
    N.settle()
    local L = laneParts(N, 2)
    ok(L.leads[1].d.ratio == 0.0 and L.leads[1].d.state == 1 and L.follows[1].o.on == nil, 'shut and locked')
    N.reset()
    N.slow()
    ok((N.calls.DoorSystemGetIsPhysicsLoaded or 0) == 27, 'on Season 1 the gate is still kept locked as it streams in')
end

-- =========================================================================
-- br_core STOPPING, AND THE 'rotate' DRIVE
-- =========================================================================

describe('br_core stopping: the prompt down, every follower let go, every part shut and locked')
do
    local W = boot({ at = AT_IN2 })
    W.slow()
    W.tick()
    W.net(W.B.Net.DCGATE_STATE, { matchId = 1, open = { true, true, false } })
    W.frames(60)
    W.net(W.B.Net.DCGATE_STATE, { matchId = 1, open = { true, false, false } })
    W.tick()
    for _, fn in ipairs(W.handlers.onResourceStop or {}) do fn('br_dummy') end
    ok(W.obj('gate.lane1.outer.follow_l').on ~= nil, 'another resource stopping: nothing')
    W.notices = {}
    -- Mid-fold, the engine has the follower where its lead's knuckle put it.
    local fr = laneParts(W, 1).follows[1].r
    local fo = W.obj(fr.id)
    fo.x, fo.y, fo.h = fo.x + 0.7, fo.y - 0.9, fo.h + 33.0
    for _, fn in ipairs(W.handlers.onResourceStop or {}) do fn('br_core') end
    ok(fo.x == fr.x and fo.y == fr.y and fo.z == fr.z and fo.h == fr.h,
        'a follower let go mid-fold is put back where it was placed, not left where the knuckle had it')
    local attached, open = 0, 0
    for _, o in pairs(W.objects) do if o.on then attached = attached + 1 end end
    for _, d in pairs(W.doors) do if d.ratio ~= 0.0 or d.state ~= 1 then open = open + 1 end end
    eq(attached, 0, 'no follower attached')
    eq(open, 0, 'every door at ratio 0, locked')
    local n = 0
    for _ in pairs(W.doors) do n = n + 1 end
    eq(n, 27, 'and left registered: a gate left locked is the map\'s resting state')
    ok(W.notices[1] and W.notices[1].clear == 'dcgate.reader', 'the prompt taken down')
end

describe('the \'rotate\' drive: `brgate drive` switches it; frozen and turned by hand, unlocked while it moves')
do
    local W = boot({ at = AT_IN2 })
    W.slow()
    W.commands.brgate(0, { 'drive', 'lead', 'rotate' })
    W.commands.brgate(0, { 'drive', 'arm', 'rotate' })
    eq(W.C.client.drive.lead, 'rotate', 'the lead switched on this client')
    W.slow()
    W.net(W.B.Net.DCGATE_STATE, { matchId = 1, open = { false, true, false } })
    W.frames(30)
    local L = laneParts(W, 2)
    for _, l in ipairs(L.leads) do
        ok(l.o.frozen == true and l.d.state == 0 and l.o.order == 2, l.r.id .. ': frozen, unlocked, turned (order 2)')
    end
    W.settle()
    for _, l in ipairs(L.leads) do
        near(wrap180(l.o.rot.z - l.r.h), l.r.sense * 90.0, 1e-6, l.r.id .. ': turned to its sense by hand')
    end
    near(mirrorError(W, L), 0.0, 1e-6, 'the followers ride a lead turned by hand just the same')
    local a = L.arm.o
    ok(a.frozen and a.rot.x == 0.0 and math.abs(a.rot.y + W.C.armRaiseDeg) < 1e-9 and a.rot.z == L.arm.r.h,
        'the arm: about local +y by -raise, under its heading', ('%s %s %s'):format(a.rot.x, a.rot.y, a.rot.z))
    W.net(W.B.Net.DCGATE_STATE, { matchId = 1, open = { false, false, false } })
    W.settle()
    for _, l in ipairs(L.leads) do
        ok(not l.o.frozen and l.d.state == 1 and math.abs(wrap180(l.o.rot.z - l.r.h)) < 1e-9,
            l.r.id .. ': shut, let go, locked')
    end
    W.commands.brgate(0, { 'drive', 'lead', 'sideways' })
    ok(W.printed[#W.printed]:find('brgate drive <lead|arm> <ratio|rotate>', 1, true) ~= nil, 'a drive that is not one: the usage')
    W.commands.brgate(0, { 'open', '2' })
    eq(W.executed[#W.executed], 'brgatesv open 2', '`brgate open 2` goes to the server')
    W.commands.brgate(0, { 'near' })
    ok(W.printed[#W.printed - 9] and W.printed[#W.printed - 9]:find('gate.lane2.reader_in', 1, true) ~= nil,
        '`brgate near` names the nearest reader and reads its lane\'s nine parts', W.printed[#W.printed - 9])
end

-- --------------------------------------------------------------- the file ---

describe('the file: no scope-gate native, every BOOL read wrapped')
do
    local src = readFile(ROOT .. 'br_core/client/dcgate.lua') or ''
    local code = src:gsub('%-%-[^\n]*', '')
    for _, native in ipairs({ 'GetActivePlayers', 'GetPlayerFromServerId', 'GetPlayerPed%(' }) do
        ok(not code:find(native), 'client/dcgate.lua calls no ' .. native:gsub('%%', ''))
    end
    for _, native in ipairs({ 'DoesEntityExist', 'IsModelInCdimage', 'IsDoorRegisteredWithSystem',
                              'DoorSystemGetIsPhysicsLoaded', 'IsEntityAttached' }) do
        local bare = 0
        for at in code:gmatch('()' .. native .. '%(') do
            if code:sub(math.max(1, at - 7), at - 1) ~= 'isTrue(' then bare = bare + 1 end
        end
        eq(bare, 0, native .. ' is only ever read through isTrue')
    end
    ok(not code:find('DoorSystemSetAutomatic'), 'no automatic door: the server says when')
    ok(code:find("BR%.Season%.has%('dcgate'%)") ~= nil, 'the season asked as BR.Season.has(\'dcgate\')')
end

realPrint(('%d passed, %d failed'):format(pass, fail))
if fail > 0 then realExit(1) end
