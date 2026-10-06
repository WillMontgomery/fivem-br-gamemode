-- Season 2 terminals (#396), wave C: EMP, the client half -- holding a stalled
-- vehicle stalled on the machine that can. Nothing is decided here: the
-- server picks the vehicles as the EMP goes off and marks each with the
-- `fx.empBag` entity state bag (server/terminalfx/emp.lua), and clears it when
-- it ends.
--
-- ═══ WHO STALLS IT: THE OWNER ═══
--
-- A vehicle's engine is the network owner's to run: SetVehicleEngineOn and
-- SetVehicleUndriveable on any other machine are written over by the owner's
-- next sync. So every client keeps the marked vehicles it has heard of, and
-- the one that OWNS one (NetworkHasControlOfEntity) holds it: engine off, no
-- auto-start, undriveable. When the bag clears it lets go: undriveable off, and
-- the engine on again if somebody is in the driver's seat ("They start again
-- when it ends"), else left off and free to start for whoever gets in.
--
--   ON CHANGE      the bag's change handler: set as the EMP goes off, cleared
--                  as it ends -- and set again for a client the vehicle
--                  becomes relevant to later, which is how a car parked out of
--                  scope is still stalled when somebody walks up to it.
--   ON ENTERING    CEventNetworkPlayerEnteredVehicle: a driver getting into a
--                  marked vehicle mid-EMP. The engine starts as a ped takes the
--                  seat and ownership moves to the driver a moment after, so
--                  it is held at once and again `REASSERT_MS` later.
--   OWNERSHIP      moves (the driver gets in, the old owner walks away): the
--                  one SLOW pass (client/terminalfx.lua's, F.onSlow) holds
--                  every marked vehicle this client has come to own, and
--                  re-holds one whose engine somebody started -- a refuel's
--                  ignition (client/fuel.lua's empty-to-full edge) or a revive
--                  hold's siren (client/revivekey.lua) included.
--   IT ENDS        when the server clears the bag. Behind that: a vehicle this
--                  client owns whose bag is already gone (a clear it was not
--                  in scope for), the lobby, Season 1, the resource stopping,
--                  and `LATE_MS` past the time the bag said it had left.
--
-- ═══ WHOEVER WROTE THE HOLD UNDOES IT, OWNER OR NOT ═══
--
-- A stall is a write to THIS machine's copy of the vehicle: the undriveable
-- flag and the engine's no-auto-start flag. Nothing promises the owner's sync
-- writes either back over it -- no-auto-start is not in the vehicle's synced
-- game state at all -- so a client that stalled a car, lost it to a driver,
-- and was not its owner when the EMP ended would keep a dead copy: the day the
-- car came back to it, it would not start, with no bag left to say why. So
-- every vehicle this client has written the hold to is kept (`wrote`) until
-- it is undone, and EVERY way an EMP ends here undoes it (`undo`): as the
-- owner, the whole release; not the owner, both flags on this copy cleared and
-- the engine left as it runs (the owner's to run). And getting into a vehicle
-- with no bag that this client marked or stalled undoes it again, now and as
-- ownership reaches the driver: a vehicle entered without a bag comes out
-- driveable. Nothing else in resources/ writes SetVehicleUndriveable, so
-- clearing it fights nobody.
--
-- A BICYCLE HAS NO ENGINE (class 13; client/boost.lua's carve-out): it is
-- marked like any vehicle the server picked and never held.
--
-- ═══ WHAT IT COSTS A FRAME ═══
--
-- Nothing. The handlers run on a change and on getting into a vehicle; the
-- SLOW check returns at once with no vehicle marked, and is a few natives per
-- marked vehicle once a second while an EMP lasts.

BR = BR or {}
BR.TerminalFx = BR.TerminalFx or {}

local F = BR.TerminalFx

--- A FiveM BOOL native may answer 1/0, and 0 is truthy in Lua.
local isTrue = BR.NativeTruthy

local function fx() return BR.Config.Terminals.fx or {} end

--- The bag the server marks a stalled vehicle with (config, read once: a
--- change handler is registered against a key).
local BAG = fx().empBag or 'brEmp'

--- How long past the time the bag gave a mark may outlive a lost clear.
local LATE_MS = 5000

--- Vehicle class 13: cycles, which have no engine to stall.
local CYCLES = 13

--- After getting into a marked vehicle, held again this long after: ownership
--- reaches the new driver a moment after the seat does.
local REASSERT_MS = { 250, 1000 }

--- The marked vehicles this client has heard of, by network id:
--- { lateAt, held } -- `held` while this client owns it and has stalled it.
local marked = {}

--- The vehicles this client has written the hold to and not yet undone as
--- their owner, by network id (see WHOEVER WROTE THE HOLD UNDOES IT).
local wrote = {}

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

--- The server's own word on this vehicle, off the entity: the milliseconds
--- the bag held as it was set, or nil when it carries none.
--- @param veh integer
--- @return number|nil
local function bagOf(veh)
    local ok, v = pcall(function() return Entity(veh).state[BAG] end)
    if ok and type(v) == 'number' and v > 0 then return v end
    return nil
end

--- @param veh integer
--- @return boolean
local function owns(veh)
    local ok, mine = pcall(NetworkHasControlOfEntity, veh)
    return ok and isTrue(mine)
end

--- @param veh integer
--- @return boolean
local function engined(veh)
    local ok, class = pcall(GetVehicleClass, veh)
    return not (ok and class == CYCLES)
end

--- @param veh integer
--- @return boolean
local function running(veh)
    local ok, on = pcall(GetIsVehicleEngineRunning, veh)
    return ok and isTrue(on)
end

--- Engine off at once, no auto-start, undriveable -- and remembered as this
--- client's write, to be undone however ownership moves.
--- @param netId integer
--- @param veh integer
local function stall(netId, veh)
    wrote[netId] = true
    pcall(SetVehicleEngineOn, veh, false, true, true)
    pcall(SetVehicleUndriveable, veh, true)
end

--- Driveable again; started for a driver in the seat, else left off and free
--- to start.
local function release(veh)
    pcall(SetVehicleUndriveable, veh, false)
    local okD, driver = pcall(GetPedInVehicleSeat, veh, -1)
    driver = okD and math.tointeger(tonumber(driver)) or 0
    if driver ~= 0 then
        pcall(SetVehicleEngineOn, veh, true, false, false)
    else
        pcall(SetVehicleEngineOn, veh, false, true, false)
    end
end

--- Hold one marked vehicle as the server said, if this client owns it: once
--- when it comes to own it, and again whenever its engine is running.
--- @param netId integer
--- @param rec table
local function settle(netId, rec)
    local veh = netVeh(netId)
    if veh == 0 then return end
    if not owns(veh) then
        rec.held = false
        return
    end
    if not engined(veh) then return end
    if not rec.held or running(veh) then
        stall(netId, veh)
        rec.held = true
    end
end

--- Undo the hold on one vehicle no longer marked. As its owner: the whole
--- release, and nothing of this client's left to undo. Not its owner, but
--- this client wrote the hold to its copy: both flags cleared on that copy,
--- the engine left as it runs; still remembered, so getting in and coming to
--- own it releases it in full. Out of scope (0): this machine has no copy to
--- undo -- the one it comes back with is fresh.
--- @param netId integer
--- @param veh integer
local function undo(netId, veh)
    if veh == 0 then return end
    if owns(veh) then
        release(veh)
        wrote[netId] = nil
    elseif wrote[netId] then
        pcall(SetVehicleUndriveable, veh, false)
        pcall(SetVehicleEngineOn, veh, running(veh), true, false)
    end
end

--- Done with one: forgotten, and this client's hold undone, owner or not.
--- @param netId integer
local function forget(netId)
    marked[netId] = nil
    undo(netId, netVeh(netId))
end

--- Every vehicle this client still has a write on, undone and forgotten: the
--- lobby, Season 1, the resource stopping.
local function undoAll()
    for netId in pairs(wrote) do undo(netId, netVeh(netId)) end
    wrote = {}
end

--- How many vehicles this client holds as marked, how many it is stalling,
--- and how many it still has a write on to undo. For the suites.
--- @return integer marked, integer held, integer wrote
function F.empMarks()
    local n, held, w = 0, 0, 0
    for _, rec in pairs(marked) do
        n = n + 1
        if rec.held then held = held + 1 end
    end
    for _ in pairs(wrote) do w = w + 1 end
    return n, held, w
end

-- ON CHANGE: set as it goes off (or as the vehicle comes into scope), cleared
-- as it ends.
if AddStateBagChangeHandler then
    AddStateBagChangeHandler(BAG, nil, function(bagName, _, value)
        local netId = math.tointeger(tonumber(tostring(bagName):match('^entity:(%d+)$')))
        if not netId then return end
        if type(value) == 'number' and value > 0 then
            if not F.on() then return end
            local rec = marked[netId] or { held = false }
            rec.lateAt = GetGameTimer() + value + LATE_MS
            marked[netId] = rec
            settle(netId, rec)
        elseif marked[netId] then
            forget(netId)
        end
    end)
end

-- ON ENTERING: a driver getting in mid-EMP. Asked of the entity itself, so a
-- change this client missed still counts. And getting into one with NO bag
-- that this client marked or stalled: undone now, and again as ownership
-- reaches the driver (the release is the owner's).
AddEventHandler('gameEventTriggered', function(name, args)
    if name ~= 'CEventNetworkPlayerEnteredVehicle' or not F.on() then return end
    local veh = math.tointeger(tonumber(type(args) == 'table' and args[2] or nil)) or 0
    if veh == 0 then return end
    local okIn, mine = pcall(GetVehiclePedIsIn, PlayerPedId(), false)
    if not okIn or mine ~= veh then return end
    local okN, netId = pcall(NetworkGetNetworkIdFromEntity, veh)
    netId = okN and math.tointeger(tonumber(netId)) or nil
    if not netId then return end
    local left = bagOf(veh)
    if not left then
        if not (marked[netId] or wrote[netId]) then return end
        forget(netId)
        for _, ms in ipairs(REASSERT_MS) do
            Citizen.SetTimeout(ms, function()
                if wrote[netId] and not marked[netId] then undo(netId, netVeh(netId)) end
            end)
        end
        return
    end
    local rec = marked[netId] or { lateAt = GetGameTimer() + left + LATE_MS }
    rec.held = false
    marked[netId] = rec
    settle(netId, rec)
    for _, ms in ipairs(REASSERT_MS) do
        Citizen.SetTimeout(ms, function()
            local r = marked[netId]
            if r then settle(netId, r) end
        end)
    end
end)

-- ONCE A SECOND (client/terminalfx.lua's SLOW pass), and nothing at all with
-- no vehicle marked and no write left: ownership that moved, an engine
-- somebody started, a clear this client was not told of, and the ends behind
-- the server's. A write left on a vehicle no longer marked costs no native
-- here until the lobby or Season 1 undoes it (getting in undoes it sooner).
F.onSlow(function()
    if next(marked) == nil and next(wrote) == nil then return end
    local S = BR.State
    local lobby = S and S.me and S.me.state == BR.PlayerState.LOBBY
    if lobby or not F.on() then
        for netId in pairs(marked) do forget(netId) end
        undoAll()
        return
    end
    local now = GetGameTimer()
    for netId, rec in pairs(marked) do
        if now > rec.lateAt then
            forget(netId)
        else
            local veh = netVeh(netId)
            if veh ~= 0 and owns(veh) and bagOf(veh) == nil then
                forget(netId)
            else
                settle(netId, rec)
            end
        end
    end
end)

AddEventHandler('onResourceStop', function(name)
    if name ~= GetCurrentResourceName() then return end
    for netId in pairs(marked) do forget(netId) end
    undoAll()
end)
