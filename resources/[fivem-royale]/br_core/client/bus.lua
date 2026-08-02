-- The Battle Bus, client half: a private plane pretending to be a shared one.
--
-- Every client spawns its OWN local, non-networked Titan and drives it along
-- the published route by direct coordinate writes against the synced clock.
-- No ownership, no sync, no physics -- 48 players see 48 identical planes in
-- identical places and cannot tell the difference.
--
-- THE PLAYER PED IS NEVER ATTACHED TO THE PLANE. Attaching remote peds to a
-- moving vehicle is the entire class of ragdoll/desync bugs this design
-- exists to avoid. The ped stays hidden, frozen and invincible on the ground
-- at the airstrip; a scripted camera rides the plane instead. The ped only
-- teleports when the server says where the jump happened.

BR = BR or {}

local route   = nil     -- published record; survives until the next match
local bus     = nil     -- local vehicle handle
local cam     = nil
local riding  = false
local told    = false   -- "doors open" notice sent

local function cleanup()
    if cam then
        RenderScriptCams(false, false, 0, true, true)
        DestroyCam(cam, false)
        cam = nil
    end
    if bus then
        if DoesEntityExist(bus) then DeleteEntity(bus) end
        bus = nil
    end
    if riding then
        -- Whatever ends the ride, the ped must come back. A hidden frozen
        -- ped with no bus is a black screen with a HUD on it.
        local ped = PlayerPedId()
        SetEntityVisible(ped, true, false)
        FreezeEntityPosition(ped, false)
        riding = false
    end
    told = false
end

RegisterNetEvent(BR.Net.BUS_ROUTE)
AddEventHandler(BR.Net.BUS_ROUTE, function(r)
    route = r
end)

--- Spawn the local plane and put the camera on it.
---
--- Runs in its own one-shot thread: model streaming blocks, and blocking
--- inside a registered loop callback would stall every other TICK subsystem
--- behind it. One thread per boarding, not per frame, is within the rules.
local function board()
    riding = true   -- set before the async work so the loop does not re-enter

    Citizen.CreateThread(function()
    local model = GetHashKey(BR.Config.Bus.model)
    RequestModel(model)
    local deadline = GetGameTimer() + 10000
    while not HasModelLoaded(model) and GetGameTimer() < deadline do
        Citizen.Wait(50)
    end
    if not HasModelLoaded(model) then
        print('[br_core] bus: model never loaded; riding blind (camera only)')
    end
    if not riding then return end   -- torn down while the model streamed

    local heading = BR.Bearing(route.sx, route.sy, route.mx, route.my)
    bus = CreateVehicle(model, route.sx, route.sy, route.alt, heading,
                        false, false)   -- LOCAL. Never networked.
    SetModelAsNoLongerNeeded(model)
    SetEntityCollision(bus, false, false)
    SetEntityInvincible(bus, true)
    FreezeEntityPosition(bus, true)
    SetVehicleEngineOn(bus, true, true, false)

    local ped = PlayerPedId()
    SetEntityVisible(ped, false, false)
    FreezeEntityPosition(ped, true)

    local off = BR.Config.Bus.camOffset
    cam = CreateCamWithParams('DEFAULT_SCRIPTED_CAMERA',
        route.sx + off.x, route.sy + off.y, route.alt + off.z,
        0.0, 0.0, 0.0, 60.0, false, 2)
    AttachCamToEntity(cam, bus, off.x, off.y, off.z, true)
    PointCamAtEntity(cam, bus, 0.0, 0.0, 0.0, true)
    SetCamActive(cam, true)
    RenderScriptCams(true, false, 0, true, true)

    print('[br_core] aboard the bus')
    end)
end

-- Board when the server says we are a rider. Driven by MY roster state, not
-- the match state alone -- a lobby bystander during someone else's bus ride
-- must never grow a camera.
BR.Loop.register(BR.Loop.TICK, 'bus.board', function()
    local me = BR.State.me.state

    if not riding and route
       and BR.State.match.state == BR.MatchState.BUS
       and me == BR.PlayerState.BUS then
        board()
    end

    -- The ride ends when the server moves me out of BUS (jump, force-eject,
    -- elimination) or the match leaves the state entirely.
    if riding and (me ~= BR.PlayerState.BUS
                   or BR.State.match.state ~= BR.MatchState.BUS) then
        -- The jump handler does its own teardown FIRST so there is no frame
        -- of airstrip between camera and freefall; this catches everything
        -- else (brforce, elimination, disconnect-reconnect states).
        cleanup()
    end

    if riding and not told and route and BR.Clock.now() >= route.tMid then
        told = true
        TriggerEvent('br:ui:sendLocal', BR.Nui.TOAST, {
            text = 'Over the drop zone — press F to jump.', tone = 'info', ms = 6000,
        })
    end
end)

-- Fly the plane. Frame loop, active only while a bus exists; everyone
-- computes the same position from the same record and the same clock.
BR.Loop.register(BR.Loop.FRAME, 'bus.fly', function()
    if not bus then return end

    local x, y, dx, dy = BR.RoutePosAt(route, BR.Clock.now())
    SetEntityCoordsNoOffset(bus, x, y, route.alt, false, false, false)
    if dx ~= 0.0 or dy ~= 0.0 then
        SetEntityHeading(bus, BR.Bearing(0.0, 0.0, dx, dy))
    end
end)

-- Ask to jump. The server owns the yes and the where.
BR.Keys.on('jump', function(pressed)
    if not pressed or not riding or not route then return end
    if BR.Clock.now() < route.tMid then
        TriggerEvent('br:ui:sendLocal', BR.Nui.TOAST, {
            text = 'Not over land yet.', tone = 'warn' })
        return
    end
    TriggerServerEvent(BR.Net.BUS_JUMP)
end)

RegisterNetEvent(BR.Net.BUS_JUMP_OK)
AddEventHandler(BR.Net.BUS_JUMP_OK, function(d)
    -- Teardown before teleport: the camera must already be back on the ped
    -- when the ped appears in the sky.
    cleanup()

    local ped = PlayerPedId()
    SetEntityCoordsNoOffset(ped, d.x + 0.0, d.y + 0.0, d.z + 0.0, false, false, false)
    SetEntityHeading(ped, d.heading or 0.0)

    TriggerEvent('br:drop:begin', d)
end)

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then cleanup() end
end)
