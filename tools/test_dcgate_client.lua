-- Unit tests for the data center gate's client (#420): br_core/client/dcgate.lua
-- over modeled natives (docs/dcgate.md).
--
-- The property is a SEQUENCE -- which natives are called, when, how often, and
-- what the world holds after each step -- so the file runs in a Lua
-- environment of its own over a modeled engine: the gate's 27 map objects (the
-- leaves and arms, each this client's own copy, which streams out and back), a
-- door system that registers them by name and turns a lead to the open ratio
-- it is held at (and a door that stops hearing it until it is registered
-- again), attachments, freezing and a car running into a part (a part turned
-- by hand and not frozen falls; and, as the worst case, a door state change or
-- a registration that clears a freeze), the three loop bands with the FRAME and TICK
-- callbacks that come and go, the notice stack, the interact key, the season
-- and the mirror. Each block boots a fresh client.
--
--   the doors    nothing without the map pack; with it, all 27 registered
--                under the pack's names, locally, and locked shut the pack's
--                way; posed as their physics streams in (the arms found and
--                frozen), and a pass with nothing to do writes nothing; a
--                registration a stopped pack took registered again
--   the cost     nothing in the lobby; away from the gate one position a
--                second and no callback; the TICK only near it, the FRAME only
--                while a gate folds
--   the prompt   the owner's words exactly, the key a hole for the player's
--                own interact key; once, at a reader of a lane whose cycle is
--                not running, in a match under way, standing, on Season 2, not
--                in a trap; down when not
--   the press    one DCGATE_USE for the reader the prompt is up for, and not
--                again within the interval
--   the fold     each gate by itself: the outer gate (and its arm) and then
--                the inner one, as the server's codes say; the leads to +-90 by
--                the open ratio, each follower on its lead's knuckle mirroring
--                it at every frame, unlocked while it rides, let go, put back,
--                frozen and locked once its lead is shut; the other gate and
--                lanes left alone; turned back halfway with no jump
--   streamed in  a gate open before this client came near arrives open, its
--                followers riding; a follower that streams out and back rides
--                again
--   the settle   a lead the door system eases is ridden until it stops, open
--                and shut; one that turns after is found astray and ridden again
--   the word     DCGATE_STATE, the snapshot (and its poses, for a late joiner),
--                the lobby and Season 1
--   the arm      turned by hand and frozen from the moment it is found, in
--                every pose: a car running into it before the press, during the
--                cycle or after it knocks nothing loose, and it rises every time;
--                frozen after every change of its door's state, so an engine
--                that clears a freeze then leaves nothing loose either
--   rotate leads the same, frozen in every pose, the followers riding them
--   read back    a lead or arm off its pose posed again; one still off the next
--                pass registered again; one where it should be left alone
--   br_core stopping and `brgate drive`: everything handed back to the door
--                system, put where it was placed and unfrozen
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
            o.handTurned = true
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
        local o = W.objects[h]
        if o then
            if o.frozen and not f then o.thaws = (o.thaws or 0) + 1 end
            o.frozen = f
            wrote(o.id, 'freeze')
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
    env.IsEntityPositionFrozen = function(h) n('IsEntityPositionFrozen') return (W.objects[h] and W.objects[h].frozen) and 1 or 0 end

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
    --- THE WORST CASE FOR A FREEZE (W.thaws): a change of a door's state, or
    --- its registration, clears the engine's freeze on its object -- not seen
    --- in game, and not ruled out.
    local function thaw(d)
        if not W.thaws then return end
        local o = doorObject(d)
        if o then o.frozen = false end
    end
    env.AddDoorToSystem = function(hash, model, x, y, z, p5, scriptDoor, isLocal)
        n('AddDoorToSystem')
        W.doors[hash] = { model = model, x = x, y = y, z = z, p5 = p5, scriptDoor = scriptDoor,
                          isLocal = isLocal, state = 0, ratio = 0.0, states = {} }
        thaw(W.doors[hash])
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
        wrote(hash, 'ratio')
        -- A DOOR THAT STOPPED HEARING its ratio (deaf) keeps what it had until
        -- it is registered again.
        if d.deaf then return end
        d.ratio = r
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
    --- A CAR RUNS INTO A PART: a door entity turned by hand (SetEntityRotation)
    --- has lost its hinge, so one that is not frozen falls; frozen, it is solid.
    --- True when it fell.
    function W.hit(id)
        local o = W.obj(id)
        if o and not o.frozen and o.handTurned then o.fallen = true end
        return o ~= nil and o.fallen == true
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
        thaw(d)
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

--- One gate's parts in a booted client: { leads, follows, arm? }, each
--- { r, o, d } -- its row, its map object, its door.
local function gateParts(W, n, which)
    local out = { leads = {}, follows = {} }
    local tag = '.' .. which .. '.'
    for _, lane in ipairs(W.P.lanes) do
        if lane.lane == n then
            for _, r in ipairs(lane.leads) do
                if r.id:find(tag, 1, true) then
                    out.leads[#out.leads + 1] = { r = r, o = W.obj(r.id), d = W.door(r.id) }
                end
            end
            for _, r in ipairs(lane.follows) do
                if r.id:find(tag, 1, true) then
                    out.follows[#out.follows + 1] = { r = r, o = W.obj(r.id), d = W.door(r.id), lead = lane.leads[r.lead] }
                end
            end
            if which == 'outer' then out.arm = { r = lane.arm, o = W.obj(lane.arm.id), d = W.door(lane.arm.id) } end
        end
    end
    return out
end

--- How far each follower of a gate is from mirroring its lead (degrees), the worst.
local function mirrorError(W, Gp)
    local worst = 0.0
    for _, f in ipairs(Gp.follows) do
        local lead = W.obj(f.lead.id)
        local turned = wrap180(lead.h - f.lead.h)
        local want = f.r.h - turned
        worst = math.max(worst, math.abs(wrap180(W.worldHeading(f.o) - want)))
    end
    return worst
end

--- The server's word: each lane's code (1 outer open + 2 inner open + 4 busy).
local function word(W, codes, match)
    W.net(W.B.Net.DCGATE_STATE, { matchId = match or 1, lanes = codes })
end

local function poseOf(W, n, which) return W.G.counts().lanes[n][which].pose end

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
        local list = {}
        for _, r in ipairs(lane.leads) do list[#list + 1] = r end
        for _, r in ipairs(lane.follows) do list[#list + 1] = r end
        list[#list + 1] = lane.arm
        for _, r in ipairs(list) do
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
    word(W, { 0, 5, 0 })
    W.reset()
    W.slow()
    eq(W.natives, 2, 'a gate opening across the map costs this client nothing')
    ok(not W.has('frame', 'dcgate.fold'), 'and folds nothing')
    eq(poseOf(W, 2, 'outer'), 1.0, 'its pose is simply open, for when this client comes near')
    eq(poseOf(W, 2, 'inner'), 0.0, 'the other gate of its lane shut')
end

describe('the doors: posed as their physics streams in, the arms found and frozen; then only reads')
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
    local arms = 0
    for _, lane in ipairs(P0.lanes) do
        local o = W.obj(lane.arm.id)
        if o.frozen and o.rot.x == 0.0 and o.rot.y == 0.0 and o.rot.z == lane.arm.h then arms = arms + 1 end
    end
    eq(arms, 3, 'each arm found and frozen at its placed rotation, shut, before anybody presses')
    eq(W.G.counts().frozen, 3, 'and nothing else frozen')
    W.reset()
    W.slow()
    eq(#W.writes, 0, 'the next pass: nothing written')
    eq(W.calls.DoorSystemGetIsPhysicsLoaded, 27, 'the physics reads')
    eq(W.calls.DoorSystemGetOpenRatio, 12, 'each lead read back by its open ratio')
    eq(W.calls.GetEntityRotation, 3, 'each arm by its rotation')
    eq(W.calls.GetClosestObjectOfType, nil, 'and no search: every handle it needs is held')
end

-- =========================================================================
-- THE PROMPT AND THE PRESS
-- =========================================================================

--- A spot in lane 2's trap 0.3 m inside its inner gate, beside the inside
--- reader: within readerM of it.
local IN_TRAP = (function()
    local lane = P0.lanes[2]
    local ix = (lane.leads[3].x + lane.leads[4].x) / 2.0
    local ox = (lane.leads[1].x + lane.leads[2].x) / 2.0
    local out = READER['gate.lane2.reader_out']
    return { x = ix + 0.3 * (ox > ix and 1 or -1), y = out.y, z = out.z - 0.2 }
end)()

describe('the prompt: the owner\'s words, once, at a reader of a lane whose cycle is not running')
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
    word(W, { 0, 5, 0 })
    W.tick()
    ok(W.notices[#W.notices].clear, 'the lane\'s cycle running (its outer gate open): down')
    word(W, { 0, 4, 0 })
    W.tick()
    ok(W.notices[#W.notices].clear, 'a gate folding shut mid-cycle: still down -- a press now is not taken')
    word(W, { 0, 6, 0 })
    W.tick()
    ok(W.notices[#W.notices].clear, 'the inner gate open: still down')
    word(W, { 5, 0, 7 })
    W.tick()
    ok(W.notices[#W.notices].text == W.G.PROMPT_TEXT, 'lane 2 idle, whatever the others do: up')
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
    -- NO READER IN THE TRAP.
    local out = READER['gate.lane2.reader_out']
    ok(math.sqrt((IN_TRAP.x - out.x) ^ 2 + (IN_TRAP.y - out.y) ^ 2) < W.C.readerM,
        'a spot in the trap within readerM of the inside reader')
    W.at.x, W.at.y, W.at.z = IN_TRAP.x, IN_TRAP.y, IN_TRAP.z
    W.tick()
    ok(W.notices[#W.notices].clear, 'standing there, in the trap: no prompt -- no reader in the trap')
    W.at.x = out.x - 1.0
    W.tick()
    ok(W.notices[#W.notices].text == W.G.PROMPT_TEXT, 'a step past the inner gate, at the inside reader: up')
    W.at.x, W.at.y, W.at.z = AT_IN2.x, AT_IN2.y, AT_IN2.z
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
    word(W, { 0, 5, 0 })
    W.tick()
    W.now = W.now + 2000
    W.press(true)
    eq(#W.uses(), 2, 'its cycle running: the prompt is down, and nothing is asked')
    word(W, { 0, 0, 0 })
    W.at.x = IN2.x + 10.0
    W.tick()
    W.now = W.now + 2000
    W.press(true)
    eq(#W.uses(), 2, 'away from the reader: nothing')
    eq(W.keyLive and W.keyLive.interact, nil, 'interact stays read as it always is (no `live` narrower than its other listeners)')
end

-- =========================================================================
-- THE FOLD, A GATE AT A TIME
-- =========================================================================

describe('the fold: inbound -- the outer gate and its arm, then the inner gate, each by itself')
do
    local W = boot({ at = AT_IN2 })
    W.slow()
    W.slow()
    W.reset()
    word(W, { 0, 5, 0 })
    ok(W.has('frame', 'dcgate.fold'), 'the outer gate opening: the FRAME callback, now')
    local O, I = gateParts(W, 2, 'outer'), gateParts(W, 2, 'inner')
    eq(W.calls.GetClosestObjectOfType, 4, 'its four leaves found first, once (its arm held since it was first posed)')
    local riding = 0
    for _, f in ipairs(O.follows) do
        local lead = W.obj(f.lead.id)
        if f.o.on and W.objects[f.o.on] == lead and f.o.att.bone == 0 and f.o.att.ox == f.r.ox
           and f.o.att.oy == f.r.oy and f.o.att.oz == f.r.oz and f.o.att.rz == 0.0 and f.o.att.collision == true
           and f.d.state == 0 then
            riding = riding + 1
        end
    end
    eq(riding, 2, 'each of its followers on its lead\'s knuckle, bone 0, at the kit\'s offset, with collision, unlocked')
    local worstMirror, worstStep, lastH = 0.0, 0.0, nil
    local lead1 = O.leads[1].o
    local frames = 0
    while poseOf(W, 2, 'outer') < 1.0 and frames < 1000 do
        W.frame(16)
        frames = frames + 1
        worstMirror = math.max(worstMirror, mirrorError(W, O))
        if lastH then worstStep = math.max(worstStep, math.abs(wrap180(lead1.h - lastH))) end
        lastH = lead1.h
        if frames == 125 then
            near(wrap180(lead1.h - O.leads[1].r.h), 45.0, 0.5, 'halfway in time (2 s): halfway open, 45')
        end
    end
    near(frames * 16, W.C.foldMs, 32, 'open after foldMs')
    near(worstMirror, 0.0, 1e-6, 'each follower mirrors its lead about the gate line at every frame')
    ok(worstStep < 1.0, 'and the lead turns smoothly: under a degree a frame', worstStep)
    for _, l in ipairs(O.leads) do
        near(wrap180(l.o.h - l.r.h), l.r.sense * 90.0, 1e-6, l.r.id .. ' turned ' .. (l.r.sense * 90) .. ', its sense')
        near(l.d.ratio, l.r.sense * 1.0, 1e-9, l.r.id .. ': held at open ratio ' .. l.r.sense)
        eq(l.d.state, 1, l.r.id .. ': held locked there')
    end
    for _, f in ipairs(O.follows) do
        local lead = W.obj(f.lead.id)
        near(math.abs(wrap180(W.worldHeading(f.o) - lead.h)), 180.0, 1e-6, f.r.id .. ' lies flat against its lead at 90')
    end
    local a = O.arm.o
    ok(a.frozen and a.rot.x == 0.0 and math.abs(a.rot.y + W.C.armRaiseDeg) < 1e-9 and a.rot.z == O.arm.r.h
        and a.order == 2 and O.arm.d.state == 0,
        'the arm raised by hand: frozen, about local +y by -raise (order 2), its door let go',
        ('%s %s %s'):format(a.rot.x, a.rot.y, a.rot.z))
    eq(W.wroteTo('lane2.inner') + W.wroteTo('lane1') + W.wroteTo('lane3'), 0,
        'the inner gate and the other lanes: nothing written')
    local k = W.settle(20)
    ok(k <= 6 and not W.has('frame', 'dcgate.fold'), 'the followers ridden a few frames more, then the FRAME goes', k)
    W.slow()
    W.reset()
    W.slow()
    eq(#W.writes, 0, 'open and still: a pass writes nothing')

    -- THE OUTER GATE SHUTS BEHIND THEM (code 4), THEN THE INNER ONE OPENS (6).
    word(W, { 0, 4, 0 })
    W.reset()
    W.settle()
    for _, l in ipairs(O.leads) do
        ok(l.d.ratio == 0.0 and l.d.state == 1 and math.abs(wrap180(l.o.h - l.r.h)) < 1e-9, l.r.id .. ': shut and locked')
    end
    for _, f in ipairs(O.follows) do
        local s = f.d.states
        ok(f.o.on == nil and f.o.detaches == 1 and f.o.frozen == true and f.o.x == f.r.x and f.o.y == f.r.y
            and f.o.h == f.r.h and s[#s - 1] == 4 and s[#s] == 1,
            f.r.id .. ': let go once its lead is shut, put back where it was placed, frozen there, and locked')
    end
    ok(a.frozen and a.rot.y == 0.0 and a.rot.z == O.arm.r.h and O.arm.d.state == 1,
        'the arm back down: still frozen, its door locked')
    eq(W.wroteTo('lane2.inner'), 0, 'the inner gate untouched while the outer one shut')
    word(W, { 0, 6, 0 })
    W.reset()
    local frames2 = W.settle()
    ok(frames2 * 16 >= W.C.foldMs, 'the inner gate folds open', frames2)
    for _, l in ipairs(I.leads) do
        near(wrap180(l.o.h - l.r.h), l.r.sense * 90.0, 1e-6, l.r.id .. ' open')
    end
    near(mirrorError(W, I), 0.0, 1e-6, 'its followers folded flat against their leads')
    eq(W.wroteTo('lane2.outer'), 0, 'the outer gate and its arm untouched while the inner one opened')
    for _, l in ipairs(O.leads) do
        ok(math.abs(wrap180(l.o.h - l.r.h)) < 1e-9, l.r.id .. ' still shut')
    end
    word(W, { 0, 0, 0 })
    W.settle()
    for _, l in ipairs(I.leads) do
        ok(l.d.ratio == 0.0 and math.abs(wrap180(l.o.h - l.r.h)) < 1e-9, l.r.id .. ': the inner gate shut again')
    end
    for _, f in ipairs(I.follows) do
        ok(f.o.on == nil and f.o.frozen == true, f.r.id .. ': let go and frozen')
    end
    -- THE NEXT CYCLE: a follower frozen where it was let go is thawed as it is
    -- attached again.
    word(W, { 0, 5, 0 })
    W.frame(16)
    for _, f in ipairs(O.follows) do
        ok(f.o.on ~= nil and f.o.frozen == false and f.o.thaws == 1, f.r.id .. ': unfrozen as it rides its lead again')
    end
    W.settle()
    near(mirrorError(W, O), 0.0, 1e-6, 'and folds flat')
end

describe('the fold: outbound -- the inner gate first, then the outer and its arm')
do
    local W = boot({ at = AT_IN2 })
    W.slow()
    W.reset()
    word(W, { 0, 6, 0 })
    W.settle()
    local O, I = gateParts(W, 2, 'outer'), gateParts(W, 2, 'inner')
    for _, l in ipairs(I.leads) do near(wrap180(l.o.h - l.r.h), l.r.sense * 90.0, 1e-6, l.r.id .. ' open first') end
    ok(O.arm.o.rot.y == 0.0 and O.leads[1].d.ratio == 0.0, 'the outer gate shut and its arm down')
    eq(W.wroteTo('lane2.outer'), 0, 'and untouched')
    word(W, { 0, 4, 0 })
    W.settle()
    word(W, { 0, 5, 0 })
    W.settle()
    ok(math.abs(O.arm.o.rot.y + W.C.armRaiseDeg) < 1e-9 and math.abs(wrap180(O.leads[1].o.h - O.leads[1].r.h) - 90.0) < 1e-6
        and I.leads[1].d.ratio == 0.0, 'then the outer gate open and its arm up, the inner gate shut')
end

describe('the fold: turned back halfway, with no jump')
do
    local W = boot({ at = AT_IN2 })
    W.slow()
    local O = gateParts(W, 2, 'outer')
    word(W, { 0, 5, 0 })
    W.frames(90)
    local mid = wrap180(O.leads[1].o.h - O.leads[1].r.h)
    ok(mid > 20 and mid < 70, 'part open', mid)
    word(W, { 0, 5, 0 })
    word(W, { 0, 4, 0 })
    local last, worstStep, worstMirror, frames = O.leads[1].o.h, 0.0, 0.0, 0
    while W.has('frame', 'dcgate.fold') and frames < 1000 do
        W.frame(16)
        frames = frames + 1
        worstStep = math.max(worstStep, math.abs(wrap180(O.leads[1].o.h - last)))
        worstMirror = math.max(worstMirror, mirrorError(W, O))
        last = O.leads[1].o.h
    end
    ok(worstStep < 1.0, 'turned back: it runs back from where it was, no jump', worstStep)
    near(worstMirror, 0.0, 1e-6, 'mirrored on the way back too')
    ok(frames * 16 < W.C.foldMs, 'and sooner than a whole fold')
    ok(math.abs(wrap180(O.leads[1].o.h - O.leads[1].r.h)) < 1e-9 and O.follows[1].o.on == nil, 'shut, let go')
end

describe('streamed in: a gate open before this client came near arrives open, its followers riding')
do
    local W = boot({ at = FAR, objects = false })
    W.slow()
    word(W, { 6, 0, 0 })
    ok(not W.has('frame', 'dcgate.fold'), 'far away: nothing folds')
    W.at.x, W.at.y = NEAR.x, NEAR.y
    W.slow()
    W.streamIn()
    W.reset()
    W.slow()
    local I, O = gateParts(W, 1, 'inner'), gateParts(W, 1, 'outer')
    for _, l in ipairs(I.leads) do
        ok(math.abs(wrap180(l.o.h - l.r.h) - l.r.sense * 90.0) < 1e-6, l.r.id .. ' arrives open')
    end
    local riding = 0
    for _, f in ipairs(I.follows) do
        if f.o.on then riding = riding + 1 end
    end
    eq(riding, 2, 'its followers found and riding')
    near(mirrorError(W, I), 0.0, 1e-6, 'folded flat against their leads')
    ok(O.leads[1].d.ratio == 0.0 and O.follows[1].o.on == nil and O.arm.o.rot.y == 0.0 and O.arm.o.frozen,
        'its outer gate, shut, posed shut, its arm down and frozen')
    W.settle(20)
    W.reset()
    W.slow()
    eq(#W.writes, 0, 'the next pass writes nothing')
    -- A FOLLOWER THAT STREAMS OUT AND BACK RIDES AGAIN.
    W.streamOut('gate.lane1.inner.follow_l')
    W.reset()
    W.slow()
    eq(#W.writes, 0, 'a follower streamed out: nothing to write to')
    W.streamIn('gate.lane1.inner.follow_l')
    W.slow()
    W.settle(20)
    local f = W.obj('gate.lane1.inner.follow_l')
    ok(f and f.on ~= nil, 'the follower that streamed back in rides its lead again')
    near(mirrorError(W, gateParts(W, 1, 'inner')), 0.0, 1e-6, 'folded')
end

describe('a lead the door system eases: the followers ride it all the way, open and shut')
do
    local W = boot({ at = FAR, objects = false })
    W.slow()
    word(W, { 5, 0, 0 })
    W.at.x, W.at.y = NEAR.x, NEAR.y
    W.slow()
    W.streamIn()
    W.lag = 1.0
    W.slow()
    local O = gateParts(W, 1, 'outer')
    local k = W.settle(400)
    ok(k > 90 and not W.has('frame', 'dcgate.fold'),
        'streamed in open, the leads easing a degree a frame: ridden until they stopped, then the FRAME goes', k)
    for _, l in ipairs(O.leads) do
        near(wrap180(l.o.h - l.r.h), l.r.sense * 90.0, 1e-6, l.r.id .. ' eased all the way open')
    end
    near(mirrorError(W, O), 0.0, 1e-6, 'every follower folded flat against its lead, not where its lead began')
    W.reset()
    W.slow()
    eq(#W.writes, 0, 'the next pass writes nothing')

    W.lag = 0.25
    word(W, { 4, 0, 0 })
    local early, worst, frames = 0, 0.0, 0
    while W.has('frame', 'dcgate.fold') and frames < 2000 do
        W.frame(16)
        frames = frames + 1
        worst = math.max(worst, mirrorError(W, O))
        for _, f in ipairs(O.follows) do
            local lead = W.obj(f.lead.id)
            if f.o.on == nil and math.abs(wrap180(lead.h - f.lead.h)) > 1e-6 then early = early + 1 end
        end
    end
    ok(frames * 16 > W.C.foldMs + 1000, 'shut behind leads that lag a whole second and more: the settle waits', frames)
    near(worst, 0.0, 1e-6, 'every follower mirrors its lagging lead at every frame')
    eq(early, 0, 'and none is let go before its lead is shut')
    local gone = 0
    for _, f in ipairs(O.follows) do if f.o.on == nil then gone = gone + 1 end end
    eq(gone, 2, 'then both are')
end

describe('a lead that turns after the settle: the next pass finds its followers astray and rides them again')
do
    local W = boot({ at = FAR, objects = false })
    W.slow()
    word(W, { 5, 0, 0 })
    W.at.x, W.at.y = NEAR.x, NEAR.y
    W.slow()
    W.streamIn()
    W.lag, W.stall = 3.0, 30
    W.slow()
    local O = gateParts(W, 1, 'outer')
    W.settle(400)
    ok(not W.has('frame', 'dcgate.fold'), 'the leads stood still through the settle, so it ended')
    for _ = 1, 60 do W.engine() end
    ok(mirrorError(W, O) > 10.0, 'then the engine turned them: the followers are off', mirrorError(W, O))
    W.slow()
    W.settle(400)
    near(mirrorError(W, O), 0.0, 1e-6, 'the next pass rode them again: folded flat')
    W.reset()
    W.slow()
    eq(#W.writes, 0, 'and the pass after writes nothing')
end

describe('near: as far as a leaf is drawn (its lodDist, 300 m)')
do
    local W = boot({ at = { x = P0.center.x, y = P0.center.y + 290.0, z = 45.5 } })
    W.slow()
    eq(W.G.counts().near, true, '290 m from the gate\'s middle: its doors kept posed')
    word(W, { 0, 5, 0 })
    ok(W.has('frame', 'dcgate.fold'), 'and a gate opening folds where it is seen')
    W.at.y = P0.center.y + P0.radius + W.C.client.nearM + 1.0
    W.slow()
    eq(W.G.counts().near, false, 'past the leaves\' reach: not')
end

-- =========================================================================
-- THE WORD
-- =========================================================================

describe('the word: DCGATE_STATE\'s codes, the snapshot, the lobby, Season 1')
do
    local W = boot({ at = FAR })
    W.slow()
    word(W, { 5, 0, 6 }, 4)
    local k = W.G.counts()
    ok(k.lanes[1].outer.target == 1 and k.lanes[1].inner.target == 0 and k.lanes[1].busy
        and k.lanes[3].inner.target == 1 and k.lanes[3].outer.target == 0 and k.lanes[2].busy == false and k.match == 4,
        'the server\'s word: lane 1\'s outer gate and lane 3\'s inner gate open, in match 4')
    W.net(W.B.Net.SNAPSHOT, { dcgate = { matchId = 5, lanes = { 0, 6, 0 } } })
    k = W.G.counts()
    ok(k.lanes[1].outer.target == 0 and k.lanes[2].inner.target == 1 and k.match == 5, 'a snapshot replaces it')
    W.net(W.B.Net.SNAPSHOT, { flick = {} })
    k = W.G.counts()
    ok(k.lanes[2].inner.target == 0 and k.match == nil, 'a snapshot with none: every gate shut')
    word(W, { 0, 5, 0 }, 6)
    W.B.State.me.state = W.B.PlayerState.LOBBY
    W.slow()
    k = W.G.counts()
    ok(k.lanes[2].outer.target == 0 and k.match == nil, 'the lobby: every gate shut, the word forgotten')
    W.B.State.me.state = W.B.PlayerState.ALIVE
    word(W, { 0, 5, 0 }, 7)
    W.switch(1)
    eq(W.G.counts().lanes[2].outer.target, 0, 'Season 1: shut')
    word(W, { 0, 5, 0 }, 7)
    eq(W.G.counts().lanes[2].outer.target, 0, 'and a word heard on Season 1 opens nothing')
    W.switch(2)
    word(W, { 'yes', 5, 9 }, 7)
    k = W.G.counts()
    ok(k.lanes[1].outer.target == 0 and k.lanes[2].outer.target == 1 and k.lanes[3].outer.target == 0
        and k.lanes[3].inner.target == 0, 'only a code 0-7 is a lane\'s word')
    word(W, { 1.5, true, -1 }, 7)
    k = W.G.counts()
    ok(k.lanes[1].outer.target == 0 and k.lanes[2].outer.target == 0, 'a fraction, a boolean, a negative: shut')
    -- Season 1 near an open gate: it folds shut, and the doors stay locked.
    local N = boot({ at = AT_IN2 })
    N.slow()
    word(N, { 0, 5, 0 })
    N.settle()
    N.switch(1)
    ok(N.has('frame', 'dcgate.fold'), 'Season 1 near an open gate: it folds shut')
    N.settle()
    local O = gateParts(N, 2, 'outer')
    ok(O.leads[1].d.ratio == 0.0 and O.leads[1].d.state == 1 and O.follows[1].o.on == nil and O.arm.o.rot.y == 0.0,
        'shut and locked, its arm down')
    N.reset()
    N.slow()
    ok((N.calls.DoorSystemGetIsPhysicsLoaded or 0) == 27, 'on Season 1 the gate is still kept locked as it streams in')
end

describe('the snapshot\'s poses: a late joiner near the gate sees each gate where it is')
do
    local W = boot({ at = AT_IN2 })
    W.slow()
    W.reset()
    W.net(W.B.Net.SNAPSHOT, { dcgate = { matchId = 3, lanes = { 0, 5, 0 }, poses = { { 0, 0 }, { 0.5, 0 }, { 0, 0 } } } })
    eq(poseOf(W, 2, 'outer'), 0.5, 'two seconds into the outer gate\'s fold: half open here too')
    ok(W.has('frame', 'dcgate.fold'), 'and folding on')
    W.frame(16)
    local O = gateParts(W, 2, 'outer')
    near(wrap180(O.leads[1].o.h - O.leads[1].r.h), 45.0, 1.0, 'its leads put half open at once, not from shut')
    local frames = W.settle()
    ok(frames * 16 < W.C.foldMs * 0.5 + 200, 'open in the half fold that was left', frames)
    near(mirrorError(W, O), 0.0, 1e-6, 'its followers folded flat')
    eq(poseOf(W, 2, 'inner'), 0.0, 'the inner gate shut')
    -- A CLIENT FOLDING IN STEP KEEPS ITS OWN POSE.
    local N = boot({ at = AT_IN2 })
    N.slow()
    word(N, { 0, 5, 0 })
    N.frames(60)
    local mine = poseOf(N, 2, 'outer')
    N.net(N.B.Net.SNAPSHOT, { dcgate = { matchId = 1, lanes = { 0, 5, 0 }, poses = { { 0, 0 }, { mine + 0.05, 0 }, { 0, 0 } } } })
    eq(poseOf(N, 2, 'outer'), mine, 'a snapshot a network trip ahead: this client keeps its own pose')
    N.net(N.B.Net.SNAPSHOT, { dcgate = { matchId = 1, lanes = { 0, 5, 0 }, poses = { { 0, 0 }, { 'x', 7 }, 9 } } })
    eq(poseOf(N, 2, 'outer'), mine, 'and poses that are not 0-1 are not taken')
    -- Far away: the pose is simply the target.
    local F = boot({ at = FAR })
    F.slow()
    F.net(F.B.Net.SNAPSHOT, { dcgate = { matchId = 1, lanes = { 0, 4, 0 }, poses = { { 0, 0 }, { 0.6, 0 }, { 0, 0 } } } })
    eq(poseOf(F, 2, 'outer'), 0.0, 'far away, a gate folding shut: simply shut, for when this client comes near')
end

-- =========================================================================
-- THE ARM, AND THE 'rotate' DRIVE: FROZEN IN EVERY POSE
-- =========================================================================

describe('the arm: turned by hand and frozen from the moment it is found -- a car hitting it knocks nothing loose')
do
    local W = boot({ at = AT_IN2 })
    eq(W.C.client.drive.arm, 'rotate', 'the arm is turned by hand by default')
    W.slow()
    local A = gateParts(W, 2, 'outer').arm
    ok(A.o.frozen and A.o.rot.y == 0.0 and A.o.rot.z == A.r.h and A.d.state == 1,
        'shut, before any press: found, frozen at its placed rotation, its door locked')
    ok(not W.hit(A.r.id), 'a car drives into it before the press: it stands')
    for cycle = 1, 10 do
        word(W, { 0, 5, 0 })
        W.settle()
        if not (math.abs(A.o.rot.y + W.C.armRaiseDeg) < 1e-9 and A.o.frozen and A.d.state == 0) then
            ok(false, 'cycle ' .. cycle .. ': the arm rises, frozen', A.o.rot.y)
        end
        if W.hit(A.r.id) then ok(false, 'cycle ' .. cycle .. ': raised, a hit knocks it loose') end
        word(W, { 0, 4, 0 })
        W.settle()
        if not (A.o.rot.y == 0.0 and A.o.rot.z == A.r.h and A.o.frozen and A.d.state == 1) then
            ok(false, 'cycle ' .. cycle .. ': back down, frozen, locked', A.o.rot.y)
        end
        if W.hit(A.r.id) then ok(false, 'cycle ' .. cycle .. ': shut, a hit knocks it loose') end
        word(W, { 0, 0, 0 })
        W.slow()
    end
    ok(not A.o.fallen, 'ten cycles, hit before, during and after each: it rises every time and never falls')
    eq(A.o.thaws, nil, 'never unfrozen while this client drives it')
    -- Streamed out and back: the copy that comes back is the map's, hinged;
    -- it is found and frozen on the next pass.
    W.streamOut('gate.lane2.outer_arm')
    W.slow()
    W.streamIn('gate.lane2.outer_arm.arm')
    local fresh = W.obj('gate.lane2.outer_arm.arm')
    ok(not fresh.frozen, 'streamed back in: the map\'s own copy')
    W.slow()
    ok(fresh.frozen and fresh.rot.y == 0.0, 'the next pass: found and frozen, shut')
end

describe('\'rotate\' leads: frozen in every pose too, the followers riding them just the same')
do
    local W = boot({ at = AT_IN2 })
    W.slow()
    W.commands.brgate(0, { 'drive', 'lead', 'rotate' })
    eq(W.C.client.drive.lead, 'rotate', 'the lead switched on this client')
    W.slow()
    local O = gateParts(W, 2, 'outer')
    for _, l in ipairs(O.leads) do
        ok(l.o.frozen and l.d.state == 1 and l.o.rot.z == l.r.h, l.r.id .. ': shut, found and frozen, its door locked')
    end
    word(W, { 0, 5, 0 })
    W.frames(30)
    for _, l in ipairs(O.leads) do
        ok(l.o.frozen == true and l.d.state == 0 and l.o.order == 2, l.r.id .. ': frozen, let go, turned (order 2)')
    end
    W.settle()
    for _, l in ipairs(O.leads) do
        near(wrap180(l.o.rot.z - l.r.h), l.r.sense * 90.0, 1e-6, l.r.id .. ': turned to its sense by hand')
    end
    near(mirrorError(W, O), 0.0, 1e-6, 'the followers ride a lead turned by hand just the same')
    word(W, { 0, 4, 0 })
    W.settle()
    for _, l in ipairs(O.leads) do
        ok(l.o.frozen and l.d.state == 1 and math.abs(wrap180(l.o.rot.z - l.r.h)) < 1e-9 and l.o.thaws == nil,
            l.r.id .. ': shut, still frozen, its door locked, never unfrozen')
        ok(not W.hit(l.r.id), l.r.id .. ': run into, it stands')
    end
    for _, f in ipairs(O.follows) do
        ok(f.o.frozen and not W.hit(f.r.id), f.r.id .. ': let go frozen where it was placed: run into, it stands')
    end
end

describe('the freeze is the engine\'s, not a flag: a door state change or a registration that clears it leaves nothing loose')
do
    local W = boot({ at = AT_IN2 })
    W.thaws = true
    W.slow()
    W.commands.brgate(0, { 'drive', 'lead', 'rotate' })
    W.slow()
    local O = gateParts(W, 2, 'outer')
    local function parts()
        local out = { O.arm }
        for _, l in ipairs(O.leads) do out[#out + 1] = l end
        return out
    end
    for _, p in ipairs(parts()) do
        ok(p.o.frozen and not W.hit(p.r.id), p.r.id .. ': shut, its door locked after it was frozen: still frozen, it stands')
    end
    for cycle = 1, 3 do
        word(W, { 0, 5, 0 })
        W.frames(10)
        for _, p in ipairs(parts()) do
            if not p.o.frozen or W.hit(p.r.id) then ok(false, ('cycle %d: %s frozen as it opens'):format(cycle, p.r.id)) end
        end
        W.settle()
        for _, p in ipairs(parts()) do
            if not p.o.frozen or W.hit(p.r.id) then ok(false, ('cycle %d: %s frozen open'):format(cycle, p.r.id)) end
        end
        word(W, { 0, 4, 0 })
        W.settle()
        for _, p in ipairs(parts()) do
            if not p.o.frozen or W.hit(p.r.id) then ok(false, ('cycle %d: %s frozen shut'):format(cycle, p.r.id)) end
        end
        for _, f in ipairs(O.follows) do
            if not f.o.frozen or W.hit(f.r.id) then ok(false, ('cycle %d: %s frozen where it was let go'):format(cycle, f.r.id)) end
        end
        word(W, { 0, 0, 0 })
        W.slow()
    end
    local fallen = 0
    for _, o in pairs(W.objects) do if o.fallen then fallen = fallen + 1 end end
    eq(fallen, 0, 'three cycles, every part hit open and shut: nothing knocked loose')
    -- Its door registered again (the read-back's last resort): frozen after it.
    word(W, { 0, 5, 0 })
    W.settle()
    W.slow()
    W.settle()
    O.arm.o.rot = { x = 0.0, y = 0.0, z = O.arm.r.h }
    W.slow()
    W.settle()
    O.arm.o.rot = { x = 0.0, y = 0.0, z = O.arm.r.h }
    W.reset()
    W.slow()
    eq(W.calls.AddDoorToSystem, 1, 'an arm off its pose twice: its door registered again')
    ok(O.arm.o.frozen and not W.hit(O.arm.r.id), 'and it is frozen after the registration, not before it')
    W.settle()
    -- `brgate near` reads the engine's freeze.
    W.commands.brgate(0, { 'near' })
    local line = nil
    for i = #W.printed, 1, -1 do
        if W.printed[i]:find(O.arm.r.id .. ':', 1, true) then line = W.printed[i] break end
    end
    ok(line ~= nil and line:find('frozen true', 1, true) ~= nil, '`brgate near` prints the arm frozen by the engine\'s own read', line)
    O.arm.o.frozen = false
    W.commands.brgate(0, { 'near' })
    for i = #W.printed, 1, -1 do
        if W.printed[i]:find(O.arm.r.id .. ':', 1, true) then line = W.printed[i] break end
    end
    ok(line:find('frozen false', 1, true) ~= nil, 'and an arm the engine let go of as not frozen, whatever this file thinks', line)
end

-- =========================================================================
-- THE READ-BACK
-- =========================================================================

describe('the read-back: a lead or arm off its pose is posed again; one still off is registered again')
do
    local W = boot({ at = AT_IN2 })
    W.slow()
    word(W, { 0, 5, 0 })
    W.settle()
    W.slow()
    W.settle()
    local O = gateParts(W, 2, 'outer')
    -- (a) The door system lost a lead's ratio.
    local L1 = O.leads[1]
    L1.d.ratio = 0.0
    W.reset()
    W.slow()
    near(L1.d.ratio, L1.r.sense * 1.0, 1e-9, 'a lead whose open ratio reads 0 at pose 1: posed again on the next pass')
    eq(W.calls.RemoveDoorFromSystem, nil, 'without registering it again')
    W.settle()
    W.slow()
    W.settle()
    W.reset()
    W.slow()
    eq(#W.writes, 0, 'then it reads right, and is left alone')
    -- (b) A door that does not hear a re-pose: registered again.
    local L2 = O.leads[2]
    L2.d.ratio, L2.d.deaf = 0.0, true
    W.reset()
    W.slow()
    eq(W.door(L2.r.id).ratio, 0.0, 'a door that does not hear it: still off after the re-pose')
    eq(W.calls.RemoveDoorFromSystem, nil, 'not registered again yet')
    W.settle()
    W.reset()
    W.slow()
    ok(W.calls.RemoveDoorFromSystem == 1 and W.calls.AddDoorToSystem == 1, 'still off on the next pass: its door registered again')
    near(W.door(L2.r.id).ratio, L2.r.sense * 1.0, 1e-9, 'and posed: it takes')
    W.settle()
    W.slow()
    W.settle()
    W.reset()
    W.slow()
    eq(#W.writes, 0, 'then left alone')
    -- (c) The arm turned off its pose by something else.
    local A = O.arm
    A.o.rot = { x = 0.0, y = 0.0, z = A.r.h }
    W.reset()
    W.slow()
    ok(math.abs(A.o.rot.y + W.C.armRaiseDeg) < 1e-9 and A.o.frozen, 'an arm read back lying down at pose 1: raised again')
    eq(W.calls.RemoveDoorFromSystem, nil, 'without registering it again')
    W.settle()
    W.slow()
    W.settle()
    -- (d) One read back the other way round of the same turn is not off.
    A.o.rot = { x = 180.0, y = 180.0 - W.C.armRaiseDeg, z = A.r.h + 180.0 }
    W.reset()
    W.slow()
    eq(#W.writes, 0, 'the same turn spelled the other way: not off, nothing written')
end

describe('the read-back: the owner\'s bug -- a \'ratio\' arm hit before the press stays down no longer')
do
    local W = boot({ at = AT_IN2 })
    W.slow()
    W.commands.brgate(0, { 'drive', 'arm', 'ratio' })
    W.slow()
    local A = gateParts(W, 2, 'outer').arm
    ok(not A.o.frozen and A.o.rot.y == 0.0 and A.d.state == 1, 'switched to ratio: handed back to the door system, shut')
    word(W, { 0, 5, 0 })
    W.settle()
    near(A.d.ratio, W.C.armRaiseDeg / 90.0, 1e-9, 'the lane opens: the arm\'s ratio set')
    -- The hit: the door system drops the arm's ratio (brgate near read 0.000 at pose 1.00).
    A.d.ratio = 0.0
    W.slow()
    near(A.d.ratio, W.C.armRaiseDeg / 90.0, 1e-9, 'read back at 0.000: set again on the next pass')
end

-- =========================================================================
-- br_core STOPPING, AND `brgate drive`
-- =========================================================================

describe('br_core stopping: everything handed back -- let go, put where it was placed, unfrozen, locked')
do
    local W = boot({ at = AT_IN2 })
    W.slow()
    W.tick()
    word(W, { 5, 0, 6 })
    W.frames(60)
    word(W, { 5, 0, 4 })
    W.tick()
    for _, fn in ipairs(W.handlers.onResourceStop or {}) do fn('br_dummy') end
    ok(W.obj('gate.lane1.outer.follow_l').on ~= nil, 'another resource stopping: nothing')
    W.notices = {}
    -- Mid-fold, the engine has the follower where its lead's knuckle put it.
    local fr = gateParts(W, 1, 'outer').follows[1].r
    local fo = W.obj(fr.id)
    fo.x, fo.y, fo.h = fo.x + 0.7, fo.y - 0.9, fo.h + 33.0
    for _, fn in ipairs(W.handlers.onResourceStop or {}) do fn('br_core') end
    ok(fo.x == fr.x and fo.y == fr.y and fo.z == fr.z and fo.h == fr.h,
        'a follower let go mid-fold is put back where it was placed, not left where the knuckle had it')
    local attached, frozen, open = 0, 0, 0
    for _, o in pairs(W.objects) do
        if o.on then attached = attached + 1 end
        if o.frozen then frozen = frozen + 1 end
    end
    for _, d in pairs(W.doors) do if d.ratio ~= 0.0 or d.state ~= 1 then open = open + 1 end end
    eq(attached, 0, 'no follower attached')
    eq(frozen, 0, 'nothing left frozen: every part the door system\'s again')
    eq(open, 0, 'every door at ratio 0, locked')
    local arms = 0
    for _, lane in ipairs(P0.lanes) do
        local o = W.obj(lane.arm.id)
        if o.rot.x == 0.0 and o.rot.y == 0.0 and o.rot.z == lane.arm.h then arms = arms + 1 end
    end
    eq(arms, 3, 'every arm at its placed rotation')
    local n = 0
    for _ in pairs(W.doors) do n = n + 1 end
    eq(n, 27, 'and left registered: a gate left locked is the map\'s resting state')
    ok(W.notices[1] and W.notices[1].clear == 'dcgate.reader', 'the prompt taken down')
end

describe('`brgate drive`: a kind switched back to ratio is handed back; and the dev verbs')
do
    local W = boot({ at = AT_IN2 })
    W.slow()
    word(W, { 0, 5, 0 })
    W.settle()
    local A = gateParts(W, 2, 'outer').arm
    ok(A.o.frozen and A.o.rot.y ~= 0.0, 'the arm up and frozen')
    W.commands.brgate(0, { 'drive', 'arm', 'ratio' })
    ok(not A.o.frozen and A.o.rot.y == 0.0 and A.o.rot.z == A.r.h and A.d.ratio == 0.0 and A.d.state == 1,
        'switched to ratio: put at its placed rotation, unfrozen, shut by the door system')
    W.slow()
    W.settle()
    near(A.d.ratio, W.C.armRaiseDeg / 90.0, 1e-9, 'then posed by its ratio on the next pass')
    ok(not A.o.frozen, 'and left unfrozen')
    W.commands.brgate(0, { 'drive', 'arm', 'rotate' })
    W.slow()
    ok(A.o.frozen and math.abs(A.o.rot.y + W.C.armRaiseDeg) < 1e-9, 'back to rotate: frozen and raised by hand again')
    W.commands.brgate(0, { 'drive', 'lead', 'sideways' })
    ok(W.printed[#W.printed]:find('brgate drive <lead|arm> <ratio|rotate>', 1, true) ~= nil, 'a drive that is not one: the usage')
    W.commands.brgate(0, { 'open', '2' })
    eq(W.executed[#W.executed], 'brgatesv open 2', '`brgate open 2` goes to the server')
    W.commands.brgate(0, { 'open', '2', 'out' })
    eq(W.executed[#W.executed], 'brgatesv open 2 out', '`brgate open 2 out`: the inside reader\'s cycle')
    W.commands.brgate(0, { 'near' })
    ok(W.printed[#W.printed - 9] and W.printed[#W.printed - 9]:find('gate.lane2.reader_in', 1, true) ~= nil,
        '`brgate near` names the nearest reader and reads its lane\'s nine parts', W.printed[#W.printed - 9])
    ok(W.printed[#W.printed - 9]:find('cycle running, outer open', 1, true) ~= nil, 'and its gates', W.printed[#W.printed - 9])
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
