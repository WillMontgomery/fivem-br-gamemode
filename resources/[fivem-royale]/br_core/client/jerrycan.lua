-- The Season 2 jerry can (#217), the client half: a pour as every client in
-- the match sees it, and the finder that names the car a press pours into.
--
--   "Please create an issue scoping a jerry can as a useable loot item, which
--    would only be useable at the gascap of a vehicle and could be used to
--    mobile refuel a vehicle. ... Neither the ped nor the vehicle should be
--    able to move while fueling, and fueling should not be able to start
--    while in motion."                          -- owner, 2026-08-22
--   "yes, freeze the vehicle while pouring. players can enter and leave the
--    vehicle, and the engine is turned off while fueling."
--                                                -- owner, 2026-11-02
--
-- And the cap, his pick from a list the same day: the gas cap where the
-- game's data has one, otherwise either rear wheel.
--
-- NOTHING IS DECIDED HERE. server/jerrycan.lua rules the press, opens the pour,
-- moves the fuel out of the can and into the tank, freezes the car by RPC and
-- ends the pour; FUEL_CAN tells every client in the match, and this file makes
-- its own copy of the world agree:
--
--   THE ENGINE   held off by the machine in the car's driver's seat or, with
--                nobody driving it, the machine that owns it: the EMP's stall
--                (client/terminalfx/emp.lua), through BR.EngineHold, so the
--                two never free a car the other still holds. Applied as the
--                hold message lands, on getting in (and again 250 ms and 1 s
--                later, as ownership reaches the new driver) and looked at
--                again once a second. SET_VEHICLE_ENGINE_ON and
--                SET_VEHICLE_UNDRIVEABLE are client-only, and undriveable is
--                local to each machine, so there is no way to say this from
--                the server.
--   THE FREEZE   the server's own FreezeEntityPosition, an RPC to the car's
--                owner, sent again whenever the owner changes. CLIENTS NEVER
--                WRITE TRUE. They only let go: at a pour's end every client
--                unfreezes its own copy if it reads frozen, and for
--                releaseGraceMs after, a client that owns the car and reads it
--                frozen unfreezes it again -- a frozen flag inherited from an
--                owner who left is the forum's stuck-car report, and this is
--                where it ends.
--   THE CAN      a LOCAL w_am_jerrycan in the pourer's hand on every client:
--                sv_entityLockdown relaxed refuses an object a client creates
--                on the network, so a networked can would be deleted before
--                anybody saw it. The pourer's own follows their channel, as
--                the clip does; everybody else's follows FUEL_CAN.
--   THE CAP      BR.JerryCan.target(): the nearest cap bone within reach,
--                else the nearest rear wheel, of the vehicles around this
--                player -- BR.JerryCanSolve's rules, on this machine's bones.
--   THE MARKER   one white cone over the nearest cap while the can is in hand,
--                so the mechanic can be found without a word of new copy.
--
-- THE POURER IS NOT FROZEN, and nothing here writes a freeze on a ped: a
-- freeze is a latch, and client/dbno.lua's REVIVING_BLOCKED note is the
-- repo's argument against one. client/inventory.lua holds them instead, with
-- POUR_HELD disabled every frame of the channel -- the frame it ends, every
-- key is live.
--
-- ═══ EVERY WAY A POUR ENDS, ON THIS CLIENT ═══
--
--   the END message          that pour, at once: always honored, any season
--   its own DEADLINE         the message's `ms` plus releaseGraceMs past its
--                            arrival, for a client that missed the end
--   a NEWER POUR on the car  the older one, as the newer one starts
--   the LOBBY                every pour, the can in hand and the marker
--   the SEASON going off     the same
--   br_core STOPPING         the same, with nothing left running afterwards
--
-- Each one is finish(): the can off the pourer's hand, this machine's engine
-- hold released (started again for a seated driver whose tank is not dry, the
-- EMP's free), and this copy of the car unfrozen, with its window opened.
--
-- ═══ WHAT IT COSTS A FRAME ═══
--
-- Nothing, unless the marker is up: then one DrawMarker, and nothing else. The
-- TICK pass returns at once, with no native and nothing allocated, while no
-- pour is known, no window is open and the can is not in hand. With the can in
-- hand, the marker's look for a cap -- a walk of the whole vehicle pool -- is
-- taken twice a second, not on every pass (MARK_SCAN_MS).

BR = BR or {}
BR.JerryCan = BR.JerryCan or {}

local JC = BR.JerryCan

--- A FiveM BOOL native may answer 1/0, and 0 is truthy in Lua.
local isTrue = BR.NativeTruthy

--- BR.Config.Fuel.jerryCan, read at call time (br_lib/config/fuel.lua).
--- @return table
local function J()
    local F = BR.Config and BR.Config.Fuel
    return (F and type(F.jerryCan) == 'table') and F.jerryCan or {}
end

--- The holder name this file's engine holds go under in BR.EngineHold.
local WHO = 'jerrycan'

--- Vehicle classes the can never pours into: cycles (13), helicopters (15),
--- planes (16) and trains (21) -- the EMP's NEVER set. A bicycle has no tank,
--- nobody may fly here, and a train is nobody's to drive.
local NEVER = { [13] = true, [15] = true, [16] = true, [21] = true }

--- After getting in, held again this long after: ownership reaches the new
--- driver a moment after the seat does (the EMP's REASSERT_MS).
local REASSERT_MS = { 250, 1000 }

--- How often a hold standing on this machine is looked at again: a driver who
--- took the seat without the entering event (a shuffle across), an engine
--- somebody started under it, ownership that arrived with nobody driving.
local HOLD_CHECK_MS = 1000

--- How long the can's model, or the tuner's clip, may take to stream before
--- the request is let go -- client/inventory.lua's EMOTE_LOAD_MS, for its
--- reason: a name the build does not have is a request that never completes.
local STREAM_MS = 2000

--- The clip's flag for `/brjerrytune`'s preview: client/inventory.lua's
--- EMOTE_FLAG, the one the pour itself plays with -- loop, upper body,
--- secondary -- so the tuned can sits in the pose players will see.
local CLIP_FLAG = 49

--- How often the preview's clip is looked at, and put back if it dropped.
local CLIP_RETASK_MS = 1000

--- HOW OFTEN THE MARKER LOOKS FOR ITS CAP while the can is in hand: twice a
--- second, not on every pass. A look is BR.JerryCan.target -- GetGamePool and
--- a position read for every car it holds, the pool walk client/ambheal.lua
--- will not take for a prompt and tools/perf_client.lua counts as a heavy call
--- -- and ten a second were 1,250 natives a second among 120 streamed cars
--- (#217's review). The cars it points at stand still to be poured into, so
--- the point half a second old is where the cap still is; the press looks
--- afresh (client/inventory.lua's sendUse).
local MARK_SCAN_MS = 500

-- ------------------------------------------------------------------ state ---

--- The pours this client has been told of, by pour id:
---   { id, n (netId), p (pourer's server id), deadline, hold, checkAt,
---     obj (the can on the pourer's hand here, or nil), ped, noProp }
local pours = {}

--- [netId] = when its release window shuts (GetGameTimer). See THE FREEZE.
local windows = {}

--- THIS PLAYER'S OWN CAN, while their channel pours. `spent` names a channel
--- that gave up on its prop (its `endsAt`, never compared with a clock).
local own = { obj = nil, ped = 0, spent = nil }

--- The can's model: its hash, when our request went out (nil: none out), and
--- the last pass that wanted it -- a request nothing wants any more is let go.
local stream = { hash = nil, askedAt = nil, wantedAt = nil }

--- The marker's point and look, set on the TICK pass; nil while it is down.
local markAt = nil
--- The FRAME callback that draws it, registered only while it stands.
local markLoop = nil
--- When the marker last looked for a cap (MARK_SCAN_MS), nil while it may not
--- stand at all: the first look after that is at once.
local markScanAt = nil

--- `/brjerrytune`: the six numbers being tuned, the entry they started from,
--- and the preview can and clip on this player's own hand.
local tune = { on = false, e = nil, v = nil, shipped = nil, obj = nil, ped = 0,
               spent = false, clipPed = 0, taskedAt = 0, dictAt = nil }

-- ---------------------------------------------------------------- natives ---

--- The vehicle behind a network id here, or 0 when it is not in scope.
--- @param netId integer
--- @return integer
local function netVeh(netId)
    local okX, has = pcall(NetworkDoesNetworkIdExist, netId)
    if not okX or not isTrue(has) then return 0 end
    local ok, veh = pcall(NetworkGetEntityFromNetworkId, netId)
    veh = ok and math.tointeger(tonumber(veh)) or 0
    if veh == 0 then return 0 end
    local okE, exists = pcall(DoesEntityExist, veh)
    if not okE or not isTrue(exists) then return 0 end
    return veh
end

--- The network id of a vehicle, or nil -- for one that is not networked too,
--- where the engine answers 0 (client/fuel.lua's netOf says why 0 is explicit).
--- @param veh integer
--- @return integer|nil
local function netOf(veh)
    local ok, n = pcall(NetworkGetNetworkIdFromEntity, veh)
    n = ok and math.tointeger(tonumber(n)) or nil
    if n == nil or n == 0 then return nil end
    return n
end

--- @param ent integer|nil
--- @return boolean
local function exists(ent)
    if ent == nil or ent == 0 then return false end
    local ok, v = pcall(DoesEntityExist, ent)
    return ok and isTrue(v)
end

--- @param veh integer
--- @return boolean
local function running(veh)
    local ok, on = pcall(GetIsVehicleEngineRunning, veh)
    return ok and isTrue(on)
end

--- Does this machine own (control) the vehicle?
--- @param veh integer
--- @return boolean
local function owns(veh)
    local ok, v = pcall(NetworkHasControlOfEntity, veh)
    return ok and isTrue(v)
end

--- Does this machine's copy of the vehicle read frozen?
--- @param veh integer
--- @return boolean
local function frozen(veh)
    local ok, v = pcall(IsEntityPositionFrozen, veh)
    return ok and isTrue(v)
end

--- The ped in the vehicle's driver's seat, or 0 for nobody.
--- @param veh integer
--- @return integer
local function driverOf(veh)
    local ok, d = pcall(GetPedInVehicleSeat, veh, -1)
    return ok and math.tointeger(tonumber(d)) or 0
end

--- This client's copy of a pourer's ped, or 0 when it has none: out of scope
--- the pourer has no ped here to hold a can, and the pass asks again.
--- @param src integer|nil
--- @return integer
local function pourerPed(src)
    if src == nil then return 0 end
    local ply = GetPlayerFromServerId(src) -- scope-ok: posing a clone this client already streams; out of scope there is no copy to pose
    if ply == nil or ply == -1 then return 0 end
    local ped = GetPlayerPed(ply) -- scope-ok: posing a clone this client already streams; out of scope there is no copy to pose
    ped = math.tointeger(tonumber(ped)) or 0
    if ped == 0 or not exists(ped) then return 0 end
    return ped
end

-- ------------------------------------------------------------- the item ---

--- Is this slot a can? The row's `refuel`, the field every reader branches
--- on -- never the id.
--- @param s table|false|nil
--- @return boolean
local function refuels(s)
    if type(s) ~= 'table' then return false end
    local c = BR.Config.ConsumableById[s.id]
    return c ~= nil and c.refuel == true
end

--- Is this player's own channel a pour, and may it show? client/inventory.lua's
--- channelItem(), read from here: `using` on a `refuel` row, ALIVE or WARMUP.
--- @param inv table  BR.Inv.local_()
--- @return boolean
local function pouringHere(inv)
    local u = inv.using
    if type(u) ~= 'table' then return false end
    local me = BR.State and BR.State.me
    local st = me and me.state
    if st ~= BR.PlayerState.ALIVE and st ~= BR.PlayerState.WARMUP then return false end
    return refuels(inv.slots[u.slot])
end

--- The UseEmotes.jerrycan entry `use` points at -- the clip, and where the can
--- sits in the hand -- or nil when the row has none to give.
--- @return table|nil
local function placement()
    local row = BR.Config.UseEmotes and BR.Config.UseEmotes.jerrycan
    local e = type(row) == 'table' and row[row.use] or nil
    if type(e) ~= 'table' or type(e.pos) ~= 'table' or type(e.rot) ~= 'table' then return nil end
    return e
end

--- Where a can goes on the hand: a bone ID and the six numbers.
--- @param e table  a UseEmotes.jerrycan entry
--- @return table  { bone, x, y, z, rx, ry, rz }
local function placed(e)
    return { bone = e.bone, x = e.pos.x, y = e.pos.y, z = e.pos.z,
             rx = e.rot.x, ry = e.rot.y, rz = e.rot.z }
end

-- -------------------------------------------------------------- the prop ---

--- Has the can's model streamed? 'ready' (and its hash), 'wait' while our
--- request is out -- asked for on one pass and looked at on the next, never
--- waited for inside a loop callback -- or 'never', when the build does not
--- have it or it did not arrive within STREAM_MS (the request let go).
--- @param now integer
--- @return string, integer|nil
local function canModel(now)
    stream.wantedAt = now
    local hash = stream.hash
    if hash == nil then
        local row = BR.Config.ConsumableById.jerrycan
        if type(row) ~= 'table' or type(row.prop) ~= 'string' then return 'never' end
        hash = GetHashKey(row.prop)
        stream.hash = hash
    end
    if isTrue(HasModelLoaded(hash)) then
        stream.askedAt = nil
        return 'ready', hash
    end
    if stream.askedAt == nil then
        if not isTrue(IsModelInCdimage(hash)) then
            print('[br_core] jerrycan: the can\'s model is not on this build -- pours show no can')
            return 'never'
        end
        RequestModel(hash)
        stream.askedAt = now
        return 'wait'
    end
    if now - stream.askedAt < STREAM_MS then return 'wait' end
    pcall(SetModelAsNoLongerNeeded, hash)
    stream.askedAt = nil
    print(('[br_core] jerrycan: the can\'s model did not stream in %dms -- this pour shows no can')
        :format(STREAM_MS))
    return 'never'
end

--- Put a can on a ped's hand at `at`.
---
--- THE SIX NUMBERS ARE rpemotes-reborn's, AND SO IS THIS CALL. Its `fuel`
--- emote attaches with `true, true, false, true, 1, true` -- rotation order 1
--- among them -- and the numbers were tuned under it, so the same call is
--- what makes them mean what they meant there. Collision is off: a can in a
--- hand must not shove anything. `bone` is the ped bone's ID, and
--- GetPedBoneIndex makes it the index the attach wants -- passing the ID
--- attaches to the wrong bone in silence (client/gunshop.lua's BONE_L_HAND).
--- Called again on a can already attached, it moves it: the tuner's keys.
--- @param obj integer
--- @param ped integer
--- @param at table  { bone, x, y, z, rx, ry, rz }
local function attach(obj, ped, at)
    local okB, idx = pcall(GetPedBoneIndex, ped, at.bone)
    idx = okB and math.tointeger(tonumber(idx)) or 0
    pcall(AttachEntityToEntity, obj, ped, idx,
          (tonumber(at.x) or 0.0) + 0.0, (tonumber(at.y) or 0.0) + 0.0, (tonumber(at.z) or 0.0) + 0.0,
          (tonumber(at.rx) or 0.0) + 0.0, (tonumber(at.ry) or 0.0) + 0.0, (tonumber(at.rz) or 0.0) + 0.0,
          true, true, false, true, 1, true)
end

--- One local can, on a ped's hand at `at`: the handle, nil while the model
--- streams (the next pass asks again), or false once it will not.
---
--- NOT NETWORKED, the three trailing falses: see THE CAN in the header.
--- @param ped integer
--- @param now integer
--- @param at table
--- @return integer|boolean|nil
local function makeProp(ped, now, at)
    local state, hash = canModel(now)
    if state == 'wait' then return nil end
    if state ~= 'ready' then return false end
    local p = GetEntityCoords(ped)
    local ok, obj = pcall(CreateObject, hash, p.x, p.y, p.z + 0.2, false, false, false)
    obj = ok and math.tointeger(tonumber(obj)) or 0
    -- LET GO AS SOON AS IT IS MADE: the object holds its model for as long as
    -- it stands, so this only stops the request outliving the cans.
    pcall(SetModelAsNoLongerNeeded, hash)
    if obj == 0 then return false end
    attach(obj, ped, at)
    return obj
end

--- @param obj integer|nil
local function deleteProp(obj)
    if not exists(obj) then return end
    pcall(DetachEntity, obj, true, true)
    pcall(DeleteEntity, obj)
end

--- Take the can off this pour's pourer, here.
--- @param rec table
local function dropRec(rec)
    if rec.obj ~= nil then deleteProp(rec.obj) end
    rec.obj, rec.ped = nil, 0
end

--- Take this player's own can off.
local function dropOwn()
    if own.obj ~= nil then deleteProp(own.obj) end
    own.obj, own.ped = nil, 0
end

-- ------------------------------------------------------- the engine hold ---

--- Hold this pour's car off on this machine, if this machine is the one to
--- (THE ENGINE, in the header): the one in its driver's seat, or -- with nobody
--- driving it -- the one that owns it. A non-owner passenger and a bystander
--- write nothing.
---
--- WRITTEN AGAIN ONLY WHEN IT IS NEEDED, the EMP's `not held or running`: a
--- hold already written here stands until the engine is found running under
--- it -- a new driver's auto-start before their own hold landed, a refuel's
--- ignition -- and then it is stalled again.
--- @param rec table
--- @param now integer
local function holdNow(rec, now)
    rec.checkAt = now + HOLD_CHECK_MS
    local veh = netVeh(rec.n)
    if veh == 0 then return end
    local driver = driverOf(veh)
    if driver ~= PlayerPedId() and (driver ~= 0 or not owns(veh)) then return end
    if not BR.EngineHold.held(rec.n, WHO) or running(veh) then
        BR.EngineHold.hold(WHO, rec.n, veh)
    end
end

--- Let go of one pour on this client, on every way it can end -- the header's
--- list.
---
---   1. its can comes off the pourer's hand;
---   2. with no other pour on the car known here, this machine's engine hold
---      is released -- started again for this player if they sit in the
---      driver's seat and the tank is not dry (BR.Fuel.levelPct of 0), the
---      EMP's free; BR.EngineHold writes nothing while the EMP still holds
---      the car, and nothing on a machine that never held it;
---   3. this copy of the car is unfrozen if it reads frozen, and its release
---      window opens (THE FREEZE).
---
--- 2 AND 3 BOTH WAIT FOR NO OTHER POUR ON THE CAR: unfreezing a car another
--- pour still holds would undo the server's freeze under it. The FUEL_CAN
--- handler ends an older pour on a car before it records a newer one, so a
--- second pour on one car is never known here at once; the walk is the
--- guarantee, not a case.
--- @param rec table
--- @param now integer
local function finish(rec, now)
    pours[rec.id] = nil
    dropRec(rec)
    for _, other in pairs(pours) do
        if other.n == rec.n then return end
    end
    local veh = netVeh(rec.n)
    local restart = false
    if veh ~= 0 and driverOf(veh) == PlayerPedId() then
        local pct = (BR.Fuel and BR.Fuel.levelPct) and BR.Fuel.levelPct(veh) or nil
        restart = pct ~= 0
    end
    BR.EngineHold.release(WHO, rec.n, restart)
    if veh ~= 0 and frozen(veh) then pcall(FreezeEntityPosition, veh, false) end
    windows[rec.n] = now + (tonumber(J().releaseGraceMs) or 2000)
end

--- The release windows: while one is open, a copy of its car this machine owns
--- and reads frozen is unfrozen. Shut on time, or by a new pour on the car.
--- @param now integer
local function sweepWindows(now)
    for n, shutAt in pairs(windows) do
        if now >= shutAt then
            windows[n] = nil
        else
            local veh = netVeh(n)
            if veh ~= 0 and owns(veh) and frozen(veh) then
                pcall(FreezeEntityPosition, veh, false)
            end
        end
    end
end

-- ------------------------------------------------------------ the marker ---

--- The one marker, a frame: one DrawMarker and nothing else, at the point the
--- TICK pass found. See the config's `marker` for every number in it.
local function drawMarker()
    local m = markAt
    if m == nil then return end
    DrawMarker(m.kind, m.x, m.y, m.z, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
               m.size, m.size, m.height, m.r, m.g, m.b, m.a,
               false, false, 2, false, nil, nil, false)
end

--- Stand the marker over a cap point, `lift` above it.
--- @param t table  { x, y, z }
local function showMarker(t)
    local M = J().marker or {}
    local c = type(M.color) == 'table' and M.color or {}
    local m = markAt
    if m == nil then
        m = {}
        markAt = m
    end
    m.kind = math.tointeger(tonumber(M.kind)) or 0
    m.x, m.y = t.x, t.y
    m.z = t.z + (tonumber(M.lift) or 0.35)
    m.size, m.height = tonumber(M.size) or 0.15, tonumber(M.height) or 0.15
    m.r = math.tointeger(tonumber(c.r)) or 240
    m.g = math.tointeger(tonumber(c.g)) or 240
    m.b = math.tointeger(tonumber(c.b)) or 240
    m.a = math.tointeger(tonumber(c.a)) or 200
    if markLoop == nil then
        markLoop = BR.Loop.register(BR.Loop.FRAME, 'jerrycan.marker', drawMarker)
    end
end

--- Take the marker down: no point, and no FRAME callback either.
local function hideMarker()
    if markLoop ~= nil then
        BR.Loop.unregister(markLoop)
        markLoop = nil
    end
    markAt = nil
end

-- --------------------------------------------------------------- the cap ---

--- The network id of a vehicle the can may pour into, or nil: which of the
--- cars around this player BR.JerryCan.target measures. Networked, not dead,
--- not a cycle, aircraft or train, and using fuel where the game can say so --
--- DoesVehicleUseFuel, asked the way client/fuel.lua's applyLevel asks it.
--- @param veh integer
--- @return integer|nil
local function candidate(veh)
    local okC, class = pcall(GetVehicleClass, veh)
    if okC and NEVER[class] then return nil end
    local n = netOf(veh)
    if n == nil then return nil end
    local okD, dead = pcall(IsEntityDead, veh)
    if okD and isTrue(dead) then return nil end
    if DoesVehicleUseFuel then
        local okU, uses = pcall(DoesVehicleUseFuel, veh)
        if okU and not isTrue(uses) then return nil end
    end
    return n
end

--- Every cap point of one vehicle, onto `anchors`: the bones
--- BR.JerryCanSolve.anchorBones picks -- the cap bones it has, else its rear
--- wheels, else none -- where the game puts them in the world.
---
--- -1 IS THE ENGINE'S "NO SUCH BONE", and the only rejection: bone 0 is a real
--- bone (client/boost.lua's exhaust note), so a `> 0` test would drop a model
--- whose cap is index 0.
--- @param anchors table
--- @param veh integer
--- @param n integer
--- @param Jc table
local function addAnchors(anchors, veh, n, Jc)
    local idx = {}
    local names = BR.JerryCanSolve.anchorBones(function(name)
        local ok, i = pcall(GetEntityBoneIndexByName, veh, name)
        i = ok and math.tointeger(tonumber(i)) or nil
        if i == nil or i == -1 then return false end
        idx[name] = i
        return true
    end, Jc)
    for _, name in ipairs(names) do
        local ok, w = pcall(GetWorldPositionOfEntityBone, veh, idx[name])
        if ok and w ~= nil then
            anchors[#anchors + 1] = { x = w.x, y = w.y, z = w.z, n = n, veh = veh, bone = name }
        end
    end
end

--- The nearest cap point within `reach` (2D; J.capReach when nil) and
--- J.capRise in height of this player's ped, or nil.
---
--- A FRESH SCAN, every call: the vehicles of GetGamePool whose origin is
--- within J.scanMeters, each a candidate (see `candidate`) with at least one
--- anchor bone, and BR.JerryCanSolve.nearestAnchor over all their points. A
--- cap bone always beats a nearer rear wheel, because a model with a cap bone
--- is never offered its wheels.
--- @param reach number|nil
--- @return table|nil  { n, veh, x, y, z, bone }
function JC.target(reach)
    local Jc = J()
    reach = tonumber(reach) or tonumber(Jc.capReach) or 1.5
    local rise = tonumber(Jc.capRise) or 2.0
    local scan = tonumber(Jc.scanMeters) or 10.0
    local p = GetEntityCoords(PlayerPedId())
    local okP, pool = pcall(GetGamePool, 'CVehicle')
    if not okP or type(pool) ~= 'table' then return nil end
    local anchors = {}
    for i = 1, #pool do
        local veh = pool[i]
        local okV, v = pcall(GetEntityCoords, veh)
        if okV and v ~= nil then
            local dx, dy = v.x - p.x, v.y - p.y
            if dx * dx + dy * dy <= scan * scan then
                local n = candidate(veh)
                if n ~= nil then addAnchors(anchors, veh, n, Jc) end
            end
        end
    end
    return (BR.JerryCanSolve.nearestAnchor(anchors, p.x, p.y, p.z, reach, rise))
end

--- Is a pour into this vehicle in force on this client -- from its FUEL_CAN
--- hold until its end or its deadline? client/fuel.lua's FUEL_SET handler
--- skips the dry tank's ignition while this answers yes: the pour's own release
--- starts the engine instead, when it ends. The hold goes out on the pass of
--- the pour's first slice, ahead of the ledger's push of what that slice put
--- in, so the first rising FUEL_SET always finds it.
--- @param nid integer
--- @return boolean
function JC.holds(nid)
    nid = math.tointeger(tonumber(nid))
    if nid == nil then return false end
    local now = GetGameTimer()
    for _, rec in pairs(pours) do
        if rec.n == nid and now < rec.deadline then return true end
    end
    return false
end

--- What this client is doing about pours, for the suites: the pours it knows,
--- the cans it has made (this player's own among them), the engine holds it
--- has written and the release windows open.
--- @return table
function JC.state()
    local out = { pours = 0, props = 0, holds = #BR.EngineHold.list(WHO), windows = 0,
                  own = own.obj ~= nil, marker = markLoop ~= nil, preview = tune.obj ~= nil }
    for _, rec in pairs(pours) do
        out.pours = out.pours + 1
        if rec.obj ~= nil then out.props = out.props + 1 end
    end
    if own.obj ~= nil then out.props = out.props + 1 end
    for _ in pairs(windows) do out.windows = out.windows + 1 end
    return out
end

-- ------------------------------------------------------------- the wire ---

-- THE HOLD makes or refreshes the record for its pour id, with a deadline of
-- its arrival plus `ms` plus releaseGraceMs, and holds the engine, now. It is
-- the first the server sends of a pour, on the slice that pays for the freeze
-- -- nothing goes at the press (server/jerrycan.lua's settle window) -- and a
-- message with `hold` false is still recorded, with no engine held for it.
-- Season 2 only -- AN END IS ALWAYS HONORED, in any season, so a pour can
-- never be left held here by a season that moved under it.
--
-- A NEWER POUR ON THE SAME CAR ENDS THE OLDER ONE HERE, and shuts the car's
-- release window: the server holds one pour per car, so an older record still
-- standing is one whose end this client missed, and a window left open would
-- unfreeze the new pour's car under it.
RegisterNetEvent(BR.Net.FUEL_CAN)
AddEventHandler(BR.Net.FUEL_CAN, function(d)
    if type(d) ~= 'table' then return end
    local id, n = math.tointeger(tonumber(d.id)), math.tointeger(tonumber(d.n))
    local ms = tonumber(d.ms)
    if id == nil or n == nil or n == 0 or ms == nil or ms ~= ms then return end
    local now = GetGameTimer()
    if ms <= 0 then
        local rec = pours[id]
        if rec ~= nil then finish(rec, now) end
        return
    end
    if not BR.Season.has('jerrycan') then return end
    local rec = pours[id]
    if rec == nil then
        for _, older in pairs(pours) do
            if older.n == n then finish(older, now) end
        end
        windows[n] = nil
        rec = { id = id, n = n, p = math.tointeger(tonumber(d.p)), deadline = 0,
                hold = false, checkAt = 0, obj = nil, ped = 0, noProp = false }
        pours[id] = rec
    end
    rec.deadline = now + ms + (tonumber(J().releaseGraceMs) or 2000)
    if d.hold == true then rec.hold = true end
    if rec.hold then holdNow(rec, now) end
end)

-- ON GETTING IN: the hold applied again at once, and 250 ms and 1 s later as
-- ownership reaches the new driver -- the EMP's entering event. Whether this
-- machine holds is holdNow's question: a passenger who got in writes nothing.
AddEventHandler('gameEventTriggered', function(name, args)
    if name ~= 'CEventNetworkPlayerEnteredVehicle' or next(pours) == nil then return end
    local veh = math.tointeger(tonumber(type(args) == 'table' and args[2] or nil)) or 0
    if veh == 0 then return end
    local n = netOf(veh)
    if n == nil then return end
    for id, rec in pairs(pours) do
        if rec.n == n and rec.hold then
            holdNow(rec, GetGameTimer())
            for _, ms in ipairs(REASSERT_MS) do
                Citizen.SetTimeout(ms, function()
                    local live = pours[id]
                    if live ~= nil and live.hold then holdNow(live, GetGameTimer()) end
                end)
            end
        end
    end
end)

-- ------------------------------------------------------------- the pass ---

--- Every pour, the can in hand and the marker let go: the lobby, and the
--- season going off. The release windows run on, since all they do is
--- unfreeze.
--- @param now integer
local function letGo(now)
    for _, rec in pairs(pours) do finish(rec, now) end
    dropOwn()
    hideMarker()
    markScanAt = nil
end

--- The cans: this player's own, following their channel, and every other
--- pourer's, following FUEL_CAN. Each one made when its ped is here and the
--- model has streamed, made again when its ped changed or the can is gone,
--- and taken off the moment it should not be there.
--- @param now integer
--- @param inv table
--- @param channel boolean
--- @param foot boolean
local function propsPass(now, inv, channel, foot)
    -- THIS PLAYER'S OWN CAN FOLLOWS THE CHANNEL, the clip's clock
    -- (client/inventory.lua's #11 note): attached while a pour's channel runs,
    -- in a state that plays it, on foot -- and off on the pass any of those
    -- stops.
    local ped = PlayerPedId()
    local u = inv and inv.using
    if channel and foot and not (u.endsAt ~= nil and own.spent == u.endsAt) then
        if own.obj ~= nil and (own.ped ~= ped or not exists(own.obj)) then dropOwn() end
        if own.obj == nil then
            -- NOT `e and makeProp(...) or false`: makeProp's nil is "still
            -- streaming", and that idiom would read it as "never".
            local e, obj = placement(), false
            if e ~= nil then obj = makeProp(ped, now, placed(e)) end
            if obj == false then
                own.spent = u.endsAt
            elseif obj ~= nil then
                own.obj, own.ped = obj, ped
            end
        end
    elseif own.obj ~= nil then
        dropOwn()
    end

    -- EVERYBODY ELSE'S FOLLOWS FUEL_CAN. Out of scope there is no ped to hold
    -- it, and the next pass asks again.
    local me = BR.State and BR.State.me and BR.State.me.src
    for _, rec in pairs(pours) do
        if rec.p ~= me and not rec.noProp then
            local pped = pourerPed(rec.p)
            if pped == 0 then
                if rec.obj ~= nil then dropRec(rec) end
            else
                if rec.obj ~= nil and (rec.ped ~= pped or not exists(rec.obj)) then dropRec(rec) end
                if rec.obj == nil then
                    local e, obj = placement(), false
                    if e ~= nil then obj = makeProp(pped, now, placed(e)) end
                    if obj == false then
                        rec.noProp = true
                    elseif obj ~= nil then
                        rec.obj, rec.ped = obj, pped
                    end
                end
            end
        end
    end
end

--- The marker: the can in hand, on foot, alive in a match, and a cap within
--- markerReach. The caller has asked the season.
---
--- ALIVE AND NOTHING ELSE, the one state a pour can start in. The server pours
--- for ALIVE and WARMUP alone, and only into a car in the match's own routing
--- bucket, which a warmup player never stands in: the pad is a bucket of its
--- own (server/roster.lua's applyBucket). So a marker shown downed, out or on
--- the pad would point at a pour that cannot start. client/inventory.lua's
--- sendUse asks the same of a press.
---
--- LOOKED FOR TWICE A SECOND (MARK_SCAN_MS), and left where it stands between
--- looks. The first look with the can in hand is at once, and the moment any
--- condition fails it comes down, without a look.
--- @param now integer
--- @param inHand boolean
--- @param foot boolean
local function markerPass(now, inHand, foot)
    local me = BR.State and BR.State.me
    if not (inHand and foot and me ~= nil and me.state == BR.PlayerState.ALIVE) then
        markScanAt = nil
        hideMarker()
        return
    end
    if markScanAt ~= nil and now - markScanAt < MARK_SCAN_MS then return end
    markScanAt = now
    local t = JC.target(J().markerReach)
    if t ~= nil then showMarker(t) else hideMarker() end
end

--- `/brjerrytune`'s numbers as a placement.
--- @return table
local function tuneAt()
    local v = tune.v
    return { bone = tune.e.bone, x = v.x, y = v.y, z = v.z, rx = v.rx, ry = v.ry, rz = v.rz }
end

--- `/brjerrytune`'s preview: a can on this player's own hand at the tuned
--- numbers, and the use entry's clip playing under it -- streamed on the pass
--- and put back once a second if it dropped, as client/inventory.lua's emote
--- is.
--- @param now integer
--- @param ped integer
local function tunePass(now, ped)
    if tune.obj ~= nil and (tune.ped ~= ped or not exists(tune.obj)) then
        deleteProp(tune.obj)
        tune.obj = nil
    end
    if tune.obj == nil and not tune.spent then
        local obj = makeProp(ped, now, tuneAt())
        if obj == false then
            tune.spent = true
        elseif obj ~= nil then
            tune.obj, tune.ped = obj, ped
        end
    end

    local e = tune.e
    if tune.clipPed == ped then
        if now - tune.taskedAt < CLIP_RETASK_MS then return end
        if isTrue(IsEntityPlayingAnim(ped, e.dict, e.clip, 3)) then
            tune.taskedAt = now
            return
        end
    end
    if not isTrue(HasAnimDictLoaded(e.dict)) then
        if tune.dictAt == nil then
            if not isTrue(DoesAnimDictExist(e.dict)) then return end
            RequestAnimDict(e.dict)
            tune.dictAt = now
        elseif now - tune.dictAt >= STREAM_MS then
            RemoveAnimDict(e.dict)
            tune.dictAt = nil
        end
        return
    end
    TaskPlayAnim(ped, e.dict, e.clip, 3.0, 8.0, -1, CLIP_FLAG, 0.0, false, false, false)
    RemoveAnimDict(e.dict)
    tune.clipPed, tune.taskedAt, tune.dictAt = ped, now, nil
end

-- ONE TICK PASS, TEN TIMES A SECOND, AND IDLE IS ITS FIRST LINE: with no pour
-- known, no window open, nothing of ours standing and the can not in hand, it
-- returns before any native and allocates nothing. (`markScanAt` still set is
-- one more pass, the one that puts the can away and resets the marker's look.)
BR.Loop.register(BR.Loop.TICK, 'jerrycan.tick', function()
    local inv = (BR.Inv and BR.Inv.local_) and BR.Inv.local_() or nil
    local inHand = inv ~= nil and refuels(inv.slots[inv.active])
    local channel = inv ~= nil and pouringHere(inv)
    if not inHand and not channel and next(pours) == nil and next(windows) == nil
       and own.obj == nil and markLoop == nil and markScanAt == nil and not tune.on
       and stream.askedAt == nil then
        return
    end

    local now = GetGameTimer()
    local ped = PlayerPedId()
    local S = BR.State
    local lobby = S and S.me and S.me.state == BR.PlayerState.LOBBY
    if lobby or not BR.Season.has('jerrycan') then
        letGo(now)
    else
        for _, rec in pairs(pours) do
            if now >= rec.deadline then
                finish(rec, now)
            elseif rec.hold and now >= rec.checkAt then
                holdNow(rec, now)
            end
        end
        local foot = (inHand or channel) and not BR.Inv.offFoot(ped)
        propsPass(now, inv, channel, foot)
        markerPass(now, inHand, foot)
    end
    if tune.on then tunePass(now, ped) end
    sweepWindows(now)
    -- A REQUEST NOTHING WANTS ANY MORE IS LET GO: the channel or the pour it
    -- was for ended while the model streamed, and nothing else will take it.
    if stream.askedAt ~= nil and stream.wantedAt ~= now then
        pcall(SetModelAsNoLongerNeeded, stream.hash)
        stream.askedAt = nil
    end
end)

-- THE ONE ENDING THE PASS CANNOT COVER, because the pass is what stops: every
-- pour let go -- the engine freed, every copy unfrozen, every can taken off --
-- and the tuner's preview with them.
AddEventHandler('onClientResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    local now = GetGameTimer()
    for _, rec in pairs(pours) do finish(rec, now) end
    dropOwn()
    hideMarker()
    if tune.obj ~= nil then deleteProp(tune.obj) end
    if tune.clipPed ~= 0 and tune.e then
        pcall(StopAnimTask, tune.clipPed, tune.e.dict, tune.e.clip, 8.0)
    end
end)

-- ------------------------------------------------------------ /brjerrytune ---
--
-- "how about instead of so many commands and args, we use keyboard keys like
-- we've done for other things. ... Any manual adjustment commands must allow
-- keyboard input."                                     -- owner, 2026-10-11
--
-- WHERE THE CAN SITS IN THE HAND, ON THE KEYS: a toggle, and `brgunclerk
-- hand`'s six keys through client/tunekeys.lua. A preview can stands on this
-- player's own hand with the use entry's clip playing, every step moves it,
-- and `off` prints the entry's pos and rot to paste back into
-- br_lib/config/loot.lua. Dev mode only, as every console command is
-- (br_lib/shared/devgate.lua).

--- A step of each: a centimeter (ten with SHIFT) and a degree (fifteen), the
--- turns going round rather than stopping -- `brgunclerk hand`'s, with the
--- turns kept to two places, as the shipped numbers are.
local HAND_M   = { fine = 0.01, coarse = 0.10, places = 2, lo = -1.0, hi = 1.0 }
local TURN_DEG = { fine = 1.0, coarse = 15.0, places = 2, wrap = true }

--- The line to paste: the tuned numbers while the tool is on, the config's
--- otherwise -- so `off` always answers with it.
local function pasteLine()
    local row = BR.Config.UseEmotes and BR.Config.UseEmotes.jerrycan
    local e = placement()
    if e == nil then
        print('[br_core] brjerrytune: BR.Config.UseEmotes.jerrycan has no entry at `use`')
        return
    end
    local v = tune.v or { x = e.pos.x, y = e.pos.y, z = e.pos.z,
                          rx = e.rot.x, ry = e.rot.y, rz = e.rot.z }
    print(('[br_core] brjerrytune: BR.Config.UseEmotes.jerrycan[%s], br_lib/config/loot.lua -- paste over its pos and rot:')
        :format(tostring(row and row.use)))
    print(('      pos = { x = %.2f, y = %.2f, z = %.2f }, rot = { x = %.2f, y = %.2f, z = %.2f } },')
        :format(v.x, v.y, v.z, v.rx, v.ry, v.rz))
end

--- Put the tuner away: the paste line, then the preview can and its clip off.
local function tuneOff()
    pasteLine()
    if tune.obj ~= nil then deleteProp(tune.obj) end
    if tune.clipPed ~= 0 and tune.e then
        pcall(StopAnimTask, tune.clipPed, tune.e.dict, tune.e.clip, 8.0)
    end
    if tune.dictAt ~= nil and tune.e then pcall(RemoveAnimDict, tune.e.dict) end
    tune.on, tune.v, tune.shipped, tune.obj, tune.ped = false, nil, nil, nil, 0
    tune.spent, tune.clipPed, tune.taskedAt, tune.dictAt = false, 0, 0, nil
end

--- `brjerrytune on`: the six numbers of the use entry on the keys.
local function tuneOn()
    local e = placement()
    if e == nil then
        print('[br_core] brjerrytune: BR.Config.UseEmotes.jerrycan has no entry at `use`')
        return
    end
    tune.e = e
    tune.v = { x = e.pos.x, y = e.pos.y, z = e.pos.z, rx = e.rot.x, ry = e.rot.y, rz = e.rot.z }
    tune.shipped = {}
    for k, v in pairs(tune.v) do tune.shipped[k] = v end
    tune.on, tune.spent = true, false
    BR.TuneKeys.start('brjerrytune', {
        lines = function(k)
            local v = tune.v
            local function hi(on) return on and '~b~' or '' end
            local move, turn = not k.turn, k.turn
            return {
                ('~b~jerry can~w~  UseEmotes.jerrycan[%s]'):format(tostring(BR.Config.UseEmotes.jerrycan.use)),
                ('%sx %.2f~w~   %sy %.2f~w~   %sz %.2f~w~')
                    :format(hi(move), v.x, hi(move and not k.depth), v.y, hi(move and k.depth), v.z),
                ('%srx %.2f~w~   %sry %.2f~w~   %srz %.2f~w~')
                    :format(hi(turn and not k.depth), v.rx, hi(turn and k.depth), v.ry, hi(turn), v.rz),
                ('step %.2f m   %.0f deg'):format(k.coarse and HAND_M.coarse or HAND_M.fine,
                    k.coarse and TURN_DEG.coarse or TURN_DEG.fine),
            }
        end,
        nudge = function(k)
            local v, moved = tune.v, false
            if k.v ~= 0 then
                local key = k.turn and (k.depth and 'ry' or 'rx') or (k.depth and 'z' or 'y')
                v[key] = BR.TuneKeys.nudged(v[key], k.v, k.coarse, k.turn and TURN_DEG or HAND_M)
                moved = true
            end
            if k.h ~= 0 then
                local key = k.turn and 'rz' or 'x'
                v[key] = BR.TuneKeys.nudged(v[key], k.h, k.coarse, k.turn and TURN_DEG or HAND_M)
                moved = true
            end
            if moved and tune.obj ~= nil then attach(tune.obj, tune.ped, tuneAt()) end
            return moved
        end,
        reset = function()
            for k, v in pairs(tune.shipped) do tune.v[k] = v end
            if tune.obj ~= nil then attach(tune.obj, tune.ped, tuneAt()) end
        end,
        off = tuneOff,
    })
    print('[br_core] brjerrytune: on. A can is in your hand with the pour\'s clip playing. The keys:')
    print('  LEFT / RIGHT             x')
    print('  UP / DOWN                y')
    print('  CTRL + UP / DOWN         z')
    print('  ALT + UP / DOWN          rx     ALT + LEFT / RIGHT   rz')
    print('  ALT + CTRL + UP / DOWN   ry')
    print('  hold SHIFT               10 cm and 15 degree steps instead of 1 cm and 1')
    print('  DELETE                   back to config')
    print('  `brjerrytune off` puts them away and prints what to paste')
end

RegisterCommand('brjerrytune', function(_, args)
    local what = tostring(type(args) == 'table' and args[1] or ''):lower()
    local on = BR.TuneKeys.on('brjerrytune')
    if what == 'off' or (what == '' and on) then
        -- Put away, its `off` prints the line; already off, it is printed
        -- anyway (`brgunclerk off`'s shape).
        if not BR.TuneKeys.stop('brjerrytune') then pasteLine() end
        return
    end
    if what == 'on' or what == '' then
        if not on then tuneOn() end
        return
    end
    print('[br_core] brjerrytune: on | off, or bare to toggle')
end, false)
