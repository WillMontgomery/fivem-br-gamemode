-- One count of who holds a vehicle's engine off ON THIS MACHINE (#217): the
-- EMP (client/terminalfx/emp.lua) and the jerry can's pour (client/jerrycan.lua).
--
--   "yes, freeze the vehicle while pouring. players can enter and leave the
--    vehicle, and the engine is turned off while fueling."
--                                                -- owner, 2026-11-02
--
-- ═══ TWO HOLDERS, ONE PAIR OF LATCHES ═══
--
-- Both features stop an engine the same way, the EMP's (wave C, round 4):
-- engine off at once with no auto-start, and undriveable. And both let go the
-- same way, by writing the opposite. So with nothing between them the FIRST to
-- let go frees a car the other still holds: a pour that ends on a car an EMP
-- is stalling hands its driver a running engine with minutes of the EMP still
-- to run, and an EMP that ends mid-pour lets the engine of a frozen car start
-- under the can. The hold is therefore counted here, by holder, and the car is
-- freed only by the release that leaves nobody holding it.
--
-- THE EMP'S SHAPE, MOVED HERE AND NOT CHANGED. The stall and the free are
-- emp.lua's own, word for word, and so is its rule that whoever wrote a hold
-- undoes it: undriveable and no-auto-start are THIS MACHINE's copy of the car
-- ("The state is local to each client and is not synced via the network" --
-- SET_VEHICLE_UNDRIVEABLE's own reference), so another machine's release
-- cannot undo ours, and ours cannot undo theirs. A release by a holder that
-- holds nothing here writes nothing.
--
-- A PLAIN TABLE, AND NOTHING PER PASS. No loop callback and no handler: each
-- holder decides when to hold and when to let go, on its own passes and
-- events, and this keeps the books and makes the writes. The only natives are
-- the two writers and the two reads a release needs, every one pcall'd and
-- every BOOL through BR.NativeTruthy.

BR = BR or {}
BR.EngineHold = BR.EngineHold or {}

local E = BR.EngineHold

--- A FiveM BOOL native may answer 1/0, and 0 is truthy in Lua.
local isTrue = BR.NativeTruthy

--- [netId] = { [who] = true }: which holders hold which car's engine off, on
--- this machine.
local holds = {}

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

--- @param veh integer
--- @return boolean
local function running(veh)
    local ok, on = pcall(GetIsVehicleEngineRunning, veh)
    return ok and isTrue(on)
end

--- A network id as an integer, or nil for anything that is not one.
--- @param netId any
--- @return integer|nil
local function idOf(netId)
    local n = math.tointeger(tonumber(netId))
    if n == nil or n == 0 then return nil end
    return n
end

--- Engine off at once, no auto-start, undriveable: the EMP's stall.
--- @param veh integer
local function stall(veh)
    pcall(SetVehicleEngineOn, veh, false, true, true)
    pcall(SetVehicleUndriveable, veh, true)
end

--- Driveable and free to start -- and started, for the player in its driver's
--- seat (`restart`): the EMP's free. SET_VEHICLE_UNDRIVEABLE false does not
--- start an engine by itself, so without `restart` the engine is left as it is
--- and only the no-auto-start latch is cleared.
--- @param veh integer
--- @param restart boolean|nil
local function freeVeh(veh, restart)
    pcall(SetVehicleUndriveable, veh, false)
    if restart then
        pcall(SetVehicleEngineOn, veh, true, false, false)
    else
        pcall(SetVehicleEngineOn, veh, running(veh), true, false)
    end
end

--- Hold a vehicle's engine off on this machine for `who` ('emp' | 'jerrycan').
--- The stall is written on every call -- a re-assert is the same call, which
--- is how both holders stop an engine somebody started under the hold.
--- @param who string
--- @param netId integer
--- @param veh integer  this machine's handle for it
function E.hold(who, netId, veh)
    local n = idOf(netId)
    veh = math.tointeger(tonumber(veh)) or 0
    if who == nil or n == nil or veh == 0 then return end
    local set = holds[n]
    if set == nil then
        set = {}
        holds[n] = set
    end
    set[who] = true
    stall(veh)
end

--- Let go of `who`'s hold on a vehicle. ONLY WHEN NO OTHER HOLDER REMAINS ON
--- THIS MACHINE is the vehicle freed, the EMP's free: undriveable cleared, then
--- the engine started for its seated driver (`restart`) or left as it is with
--- the no-auto-start latch cleared.
---
--- OUT OF SCOPE (no handle here) the record is dropped and nothing is written:
--- there is no copy here to undo, and the one the car comes back with is fresh.
--- @param who string
--- @param netId integer
--- @param restart boolean|nil
--- @return boolean freed  true only when this call wrote the free
function E.release(who, netId, restart)
    local n = idOf(netId)
    local set = n and holds[n] or nil
    if set == nil or set[who] ~= true then return false end
    set[who] = nil
    if next(set) ~= nil then return false end
    holds[n] = nil
    local veh = netVeh(n)
    if veh == 0 then return false end
    freeVeh(veh, restart)
    return true
end

--- The EMP's "a spared driver gets in" free, of a car this machine does not
--- hold: written only when no holder holds `netId` here, so a spared driver
--- who climbs into a car mid-pour does not free what the pour holds.
--- @param netId integer|nil
--- @param veh integer
--- @param restart boolean|nil
--- @return boolean wrote
function E.free(netId, veh, restart)
    local n = idOf(netId)
    if n ~= nil and holds[n] ~= nil then return false end
    veh = math.tointeger(tonumber(veh)) or 0
    if veh == 0 then return false end
    freeVeh(veh, restart)
    return true
end

--- Does `who` hold this vehicle here -- or, with `who` nil, does anybody?
--- @param netId integer
--- @param who string|nil
--- @return boolean
function E.held(netId, who)
    local n = idOf(netId)
    local set = n and holds[n] or nil
    if set == nil then return false end
    if who == nil then return next(set) ~= nil end
    return set[who] == true
end

--- How many holders hold this vehicle here.
--- @param netId integer
--- @return integer
function E.count(netId)
    local n = idOf(netId)
    local set = n and holds[n] or nil
    local k = 0
    if set ~= nil then
        for _ in pairs(set) do k = k + 1 end
    end
    return k
end

--- The vehicles `who` holds here (any holder, with `who` nil), as network ids
--- in ascending order. A fresh list: a caller may release while it walks it.
--- @param who string|nil
--- @return integer[]
function E.list(who)
    local out = {}
    for n, set in pairs(holds) do
        if who == nil or set[who] == true then out[#out + 1] = n end
    end
    table.sort(out)
    return out
end
