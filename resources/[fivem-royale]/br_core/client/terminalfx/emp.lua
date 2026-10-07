-- Season 2 terminals (#396), wave C: EMP, the client half -- the vehicle THIS
-- player drives, held stalled while the server says their driving stalls.
-- Nothing is decided here (server/terminalfx/emp.lua).
--
-- ROUND 4 (owner, 2026-10-06): "kill all cars in the entire match, except the
-- ones that the user or their squad get into", for 3 minutes. So it is a fact
-- about drivers: TERMINAL_EMP tells this client how long its own player's
-- driving stalls (`leftMs`, absent when every EMP in force spares their
-- squad) and how long any EMP lasts (`liveMs`). Each client applies it to the
-- one vehicle its own player is in the driver's seat of -- the driver's
-- client, which is also the one the vehicle's network ownership goes to, so
-- the write sticks. Nothing is marked on any vehicle, and nothing touches a
-- car nobody here is driving.
--
--   STALLING     while `leftMs` runs and this player is the driver: engine
--                off at once, no auto-start, undriveable. A car moving when
--                it lands coasts to a stop. A player spared (the runner's
--                squad) drives as ever; a car one of them leaves stalls for
--                the next driver who is not spared, and the other way round.
--   WHEN         on the fact's change; on getting in
--                (CEventNetworkPlayerEnteredVehicle -- held again 250 ms and
--                1 s later, as ownership reaches the new driver); and on
--                client/terminalfx.lua's one SLOW pass, for a seat taken
--                without getting in (a shuffle into the driver's seat), an
--                engine somebody started under it (a refuel's ignition, a
--                revive hold's siren), and the stall's end. Never per frame.
--   SPARED, IN A CAR SOMEBODY ELSE STALLED: getting in while any EMP lasts
--                frees it -- driveable, started -- so a car one of the squad
--                gets into works whoever drove it before.
--   UNDONE       the car this client stalled is freed (driveable, free to
--                start, started again for its driver if it is still this
--                player) when this player stops driving it, when the stall
--                ends, in the lobby, off Season 2 and as br_core stops.
--                Whoever wrote the hold undoes it (wave C's review): the
--                undriveable and no-auto-start flags are this machine's copy.
--
-- NEVER AN AIRCRAFT OR A BICYCLE: nobody may fly here (client/vehrefuse.lua
-- ejects them), and a stalled aircraft in the air would fall on whoever is
-- under it; a bicycle has no engine (class 13, client/boost.lua's carve-out).
-- A train is nobody's to drive.
--
-- ═══ WHAT IT COSTS A FRAME ═══
--
-- Nothing. The handlers run on a change and on getting into a vehicle; the
-- SLOW hook returns at once with no EMP and nothing written, and is a few
-- natives once a second while one lasts.

BR = BR or {}
BR.TerminalFx = BR.TerminalFx or {}

local F = BR.TerminalFx

--- A FiveM BOOL native may answer 1/0, and 0 is truthy in Lua.
local isTrue = BR.NativeTruthy

--- Vehicle classes never held: cycles (13), helicopters (15), planes (16),
--- trains (21).
local NEVER = { [13] = true, [15] = true, [16] = true, [21] = true }

--- After getting in, held (or freed) again this long after: ownership
--- reaches the new driver a moment after the seat does.
local REASSERT_MS = { 250, 1000 }

--- GetGameTimer() deadlines: this player's driving stalls until `stallUntil`;
--- some EMP in this match lasts until `liveUntil`. Nil: none.
local stallUntil, liveUntil = nil, nil

--- The vehicles this client has written the hold to and not yet undone, by
--- network id.
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

--- The vehicle this player is in the DRIVER'S SEAT of, and its network id; 0
--- and nil on foot or in any other seat.
--- @return integer veh, integer|nil netId
local function driven()
    local ped = PlayerPedId()
    local okIn, veh = pcall(GetVehiclePedIsIn, ped, false)
    veh = okIn and math.tointeger(tonumber(veh)) or 0
    if veh == 0 then return 0, nil end
    local okD, driver = pcall(GetPedInVehicleSeat, veh, -1)
    if not okD or driver ~= ped then return 0, nil end
    local okN, netId = pcall(NetworkGetNetworkIdFromEntity, veh)
    netId = okN and math.tointeger(tonumber(netId)) or nil
    if not netId then return 0, nil end
    return veh, netId
end

--- @param veh integer
--- @return boolean
local function holdable(veh)
    local ok, class = pcall(GetVehicleClass, veh)
    return not (ok and NEVER[class])
end

--- @param veh integer
--- @return boolean
local function running(veh)
    local ok, on = pcall(GetIsVehicleEngineRunning, veh)
    return ok and isTrue(on)
end

--- Engine off at once, no auto-start, undriveable -- remembered as this
--- client's write, to be undone however it ends.
local function stall(netId, veh)
    wrote[netId] = true
    pcall(SetVehicleEngineOn, veh, false, true, true)
    pcall(SetVehicleUndriveable, veh, true)
end

--- Driveable, free to start -- and started, for this player in its seat.
--- @param veh integer
--- @param mine boolean  this player is driving it
local function free(veh, mine)
    pcall(SetVehicleUndriveable, veh, false)
    if mine then
        pcall(SetVehicleEngineOn, veh, true, false, false)
    else
        pcall(SetVehicleEngineOn, veh, running(veh), true, false)
    end
end

--- Undo this client's hold on one vehicle. Out of scope (0): no copy here to
--- undo -- the one it comes back with is fresh.
--- @param netId integer
--- @param drivingIt boolean
local function undo(netId, drivingIt)
    wrote[netId] = nil
    local veh = netVeh(netId)
    if veh ~= 0 then free(veh, drivingIt) end
end

local function active(untilAt, now)
    return untilAt ~= nil and now < untilAt
end

--- Every write undone and every fact forgotten: the lobby, Season 1, the
--- resource stopping.
local function letGo()
    stallUntil, liveUntil = nil, nil
    local veh, mine = driven()
    for netId in pairs(wrote) do undo(netId, veh ~= 0 and netId == mine) end
end

--- Make the vehicle this player drives match the fact: held while their
--- driving stalls, and every other write undone. With `entered`, a spared
--- player just took the wheel while an EMP lasts: the car is freed.
--- @param entered boolean|nil
local function settle(entered)
    local now = GetGameTimer()
    local stalling = active(stallUntil, now)
    if not stalling then stallUntil = nil end
    if not active(liveUntil, now) then liveUntil = nil end
    if not stalling and liveUntil == nil and next(wrote) == nil then return end
    local veh, netId = driven()
    for n in pairs(wrote) do
        if not (stalling and n == netId) then undo(n, n == netId) end
    end
    if veh == 0 or not holdable(veh) then return end
    if stalling then
        if not wrote[netId] or running(veh) then stall(netId, veh) end
    elseif entered and liveUntil ~= nil then
        free(veh, true)
    end
end

--- Is this player's driving stalled now, and how many vehicles has this
--- client a hold written to? For the suites.
--- @return boolean stalling, integer wrote
function F.empState()
    local n = 0
    for _ in pairs(wrote) do n = n + 1 end
    return active(stallUntil, GetGameTimer()), n
end

-- THE FACT, ON ITS CHANGE.
RegisterNetEvent(BR.Net.TERMINAL_EMP)
AddEventHandler(BR.Net.TERMINAL_EMP, function(d)
    if type(d) ~= 'table' or not F.on() then return end
    local now = GetGameTimer()
    local left, live = tonumber(d.leftMs), tonumber(d.liveMs)
    stallUntil = (left and left > 0) and (now + left) or nil
    liveUntil = (live and live > 0) and (now + live) or nil
    settle(false)
end)

-- ON GETTING IN: this player taking a seat. Settled now and again as
-- ownership reaches the driver.
AddEventHandler('gameEventTriggered', function(name, args)
    if name ~= 'CEventNetworkPlayerEnteredVehicle' or not F.on() then return end
    if stallUntil == nil and liveUntil == nil and next(wrote) == nil then return end
    local veh = math.tointeger(tonumber(type(args) == 'table' and args[2] or nil)) or 0
    if veh == 0 then return end
    local okIn, mine = pcall(GetVehiclePedIsIn, PlayerPedId(), false)
    if not okIn or mine ~= veh then return end
    settle(true)
    for _, ms in ipairs(REASSERT_MS) do
        Citizen.SetTimeout(ms, function() settle(true) end)
    end
end)

-- ONCE A SECOND (client/terminalfx.lua's SLOW pass), and nothing at all with
-- no EMP and nothing written.
F.onSlow(function()
    if stallUntil == nil and liveUntil == nil and next(wrote) == nil then return end
    local S = BR.State
    local lobby = S and S.me and S.me.state == BR.PlayerState.LOBBY
    if lobby or not F.on() then
        letGo()
        return
    end
    settle(false)
end)

AddEventHandler('onResourceStop', function(name)
    if name ~= GetCurrentResourceName() then return end
    letGo()
end)
