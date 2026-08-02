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
-- moves when the jump actually happens.
--
-- CONTROLS: one key. SPACE jumps once the doors are open (and deploys the
-- glider afterwards -- skydive.lua owns that half of the same binding).

BR = BR or {}

local route   = nil     -- published record; survives until the next match
local bus     = nil     -- local vehicle handle
local pilot   = nil     -- local ped in the seat; see board() for why it matters
local cam     = nil
local riding  = false
local told    = false   -- "doors open" notice sent
local ejectedSeen = nil -- when we noticed the server flipped us to FREEFALL
local lastX, lastY, lastZ, lastT = nil, nil, nil, nil  -- finite-difference state
local camYaw, camPitch = 0.0, -8.0   -- free-look orbit, reset each boarding

local function cleanup()
    if cam then
        RenderScriptCams(false, false, 0, true, true)
        DestroyCam(cam, false)
        cam = nil
    end
    if pilot then
        if DoesEntityExist(pilot) then DeleteEntity(pilot) end
        pilot = nil
    end
    if bus then
        if DoesEntityExist(bus) then DeleteEntity(bus) end
        bus = nil
    end
    lastX, lastY, lastZ, lastT = nil, nil, nil, nil
    -- Streaming focus back to the ped, radar back on screen.
    ClearFocus()
    DisplayRadar(true)
    if riding then
        -- Whatever ends the ride, the ped must come back. A hidden frozen
        -- ped with no bus is a black screen with a HUD on it.
        local ped = PlayerPedId()
        SetEntityVisible(ped, true, false)
        FreezeEntityPosition(ped, false)
        riding = false
    end
    told = false
    ejectedSeen = nil
end

RegisterNetEvent(BR.Net.BUS_ROUTE)
AddEventHandler(BR.Net.BUS_ROUTE, function(r)
    route = r
end)

--- Begin the drop at given coordinates: the one true handoff to skydive.lua.
local function beginDrop(x, y, z, heading)
    cleanup()
    local ped = PlayerPedId()
    SetEntityCoordsNoOffset(ped, x + 0.0, y + 0.0, z + 0.0, false, false, false)
    SetEntityHeading(ped, heading or 0.0)
    TriggerEvent('br:drop:begin', { x = x, y = y, z = z, heading = heading })
end

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

        local p0 = route.points[1]
        local heading = route.heading or 0.0
        bus = CreateVehicle(model, p0.x, p0.y, p0.z, heading,
                            false, false)   -- LOCAL. Never networked.
        SetModelAsNoLongerNeeded(model)
        SetEntityCollision(bus, false, false)
        SetEntityInvincible(bus, true)
        -- NOT frozen: the fly loop writes coordinates every frame anyway, and
        -- a frozen prop plane does not run its engine simulation -- static
        -- propellers were half of what made the first flight unconvincing.

        -- The pilot. Prop aircraft SHUT THEIR ENGINES OFF when unoccupied --
        -- that is engine behaviour, not a missing native call -- so the crew
        -- is load-bearing: a seated ped is what keeps the engine simulation
        -- (props, audio) alive. Local and non-networked like the plane.
        local pilotModel = GetHashKey('s_m_m_pilot_01')
        RequestModel(pilotModel)
        local pDeadline = GetGameTimer() + 5000
        while not HasModelLoaded(pilotModel) and GetGameTimer() < pDeadline do
            Citizen.Wait(50)
        end
        if HasModelLoaded(pilotModel) then
            pilot = CreatePed(4, pilotModel, route.sx, route.sy, route.alt, heading,
                              false, false)
            SetModelAsNoLongerNeeded(pilotModel)
            SetEntityInvincible(pilot, true)
            SetBlockingOfNonTemporaryEvents(pilot, true)
            SetPedIntoVehicle(pilot, bus, -1)
        end

        SetVehicleEngineOn(bus, true, true, false)

        local ped = PlayerPedId()
        SetEntityVisible(ped, false, false)
        FreezeEntityPosition(ped, true)

        -- Unattached camera, positioned every frame by the fly loop: an
        -- attached camera is welded in place, and free look was the first
        -- thing missed. HUD chrome goes with it -- the ride is a cutscene.
        camYaw, camPitch = 0.0, -8.0
        cam = CreateCamWithParams('DEFAULT_SCRIPTED_CAMERA',
            p0.x, p0.y, p0.z + BR.Config.Bus.camHeight,
            0.0, 0.0, 0.0, 65.0, false, 2)
        SetCamActive(cam, true)
        RenderScriptCams(true, false, 0, true, true)
        DisplayRadar(false)

        print(('[br_core] aboard the bus (handle %d)'):format(bus))
    end)
end

-- Board when the server says we are a rider; end the ride when it says we
-- are not. Driven by MY roster state, not the match state alone -- a lobby
-- bystander during someone else's bus ride must never grow a camera.
BR.Loop.register(BR.Loop.TICK, 'bus.board', function()
    local me = BR.State.me.state

    if not riding and route
       and BR.State.match.state == BR.MatchState.BUS
       and me == BR.PlayerState.BUS then
        board()
    end

    if riding and me ~= BR.PlayerState.BUS then
        if me == BR.PlayerState.FREEFALL then
            -- The server has put me out; BUS_JUMP_OK with the exact exit
            -- coordinates is on the wire. Give it a moment -- and if it
            -- never comes, self-place from the same route the server used.
            -- The alternative was being restored at the airstrip, which by
            -- now is an UNLOADED island: that is the "fell into the ocean
            -- at Cayo with no parachute" bug, and it must have no path back.
            ejectedSeen = ejectedSeen or GetGameTimer()
            if GetGameTimer() - ejectedSeen > 800 then
                print('[br_core] bus: exit coords never arrived; self-placing from the route')
                local x, y, z = BR.PathPosAt(route.points, BR.Clock.now())
                beginDrop(x, y, z,
                          BR.GtaHeading(BR.Bearing(route.mx, route.my, route.ex, route.ey)))
            end
        else
            -- Dead, back to lobby, match torn down -- nothing airborne about
            -- any of it. Plain teardown.
            cleanup()
        end
    end

    if riding and not told and route and BR.Clock.now() >= route.jumpFrom then
        told = true
        TriggerEvent('br:ui:sendLocal', BR.Nui.TOAST, {
            text = 'Doors open — SPACE to jump.', tone = 'info', ms = 6000,
        })
    end
end)

-- Fly the plane. Frame loop, active only while a bus exists; everyone
-- computes the same position from the same record and the same clock.
--
-- Coordinates are written every frame -- that is the authority, and what
-- keeps 48 local planes identical. Velocity is ALSO set, from a finite
-- difference of the route, because the engine simulation reads it: velocity
-- is what makes propellers blur and the airframe sound like it is working.
-- The two never fight; the coordinate write wins every frame.
--
-- The same pass drives the free-look orbit camera and keeps the STREAMING
-- FOCUS on the plane: the world streams around the PED by default, and the
-- ped is parked at the airstrip -- without the focus hint, the entire route
-- ahead is unstreamed ocean, which is precisely how flight 3 looked.
BR.Loop.register(BR.Loop.FRAME, 'bus.fly', function()
    if not bus then return end

    local t = BR.Clock.now()
    local x, y, z, dx, dy = BR.PathPosAt(route.points, t)

    SetEntityCoordsNoOffset(bus, x, y, z, false, false, false)

    local heading = 0.0
    if dx ~= 0.0 or dy ~= 0.0 then
        heading = BR.GtaHeading(BR.Bearing(0.0, 0.0, dx, dy))
    end

    local vx, vy, vz = 0.0, 0.0, 0.0
    if lastT and t > lastT then
        local inv = 1000.0 / (t - lastT)
        vx, vy, vz = (x - lastX) * inv, (y - lastY) * inv, (z - lastZ) * inv

        -- Pitch follows the actual climb, so rotation off the runway looks
        -- like rotation rather than an elevator.
        local hSpeed = math.sqrt(vx * vx + vy * vy)
        local pitch = hSpeed > 1.0 and math.deg(math.atan(vz, hSpeed)) or 0.0
        SetEntityRotation(bus, pitch, 0.0, heading, 2, true)
        SetEntityVelocity(bus, vx, vy, vz)
    else
        SetEntityHeading(bus, heading)
    end
    lastX, lastY, lastZ, lastT = x, y, z, t

    SetFocusPosAndVel(x, y, z, vx, vy, vz)

    -- Free-look orbit: mouse (or right stick) walks the camera around the
    -- plane; it always looks AT the plane, so there is no way to get lost.
    if cam then
        camYaw   = (camYaw - GetControlNormal(0, 1) * 8.0) % 360.0
        camPitch = BR.Clamp(camPitch - GetControlNormal(0, 2) * 6.0, -75.0, 25.0)

        local dist = BR.Config.Bus.camDistance
        local yawRad   = math.rad(heading + 180.0 + camYaw)  -- 0 = behind the plane
        local pitchRad = math.rad(camPitch)
        local horiz = dist * math.cos(pitchRad)
        SetCamCoord(cam,
            x - math.sin(yawRad) * horiz,
            y + math.cos(yawRad) * horiz,
            z + BR.Config.Bus.camHeight - dist * math.sin(pitchRad))
        PointCamAtCoord(cam, x, y, z + 4.0)
    end
end)

-- SPACE, bus half: ask to jump. (skydive.lua owns the freefall half of the
-- same key; `riding` and `dropping` are mutually exclusive, so exactly one
-- of the two listeners acts on any press.)
BR.Keys.on('deploy', function(pressed)
    if not pressed or not riding or not route then return end
    if BR.Clock.now() < route.jumpFrom then
        TriggerEvent('br:ui:sendLocal', BR.Nui.TOAST, {
            text = 'Doors are still closed.', tone = 'warn' })
        return
    end
    TriggerServerEvent(BR.Net.BUS_JUMP)
end)

RegisterNetEvent(BR.Net.BUS_JUMP_OK)
AddEventHandler(BR.Net.BUS_JUMP_OK, function(d)
    beginDrop(d.x, d.y, d.z, d.heading)
end)

--- Everything about the ride, printed at once. The first flight produced
--- "the plane never moved" with no way to tell a dead loop from a dead
--- clock from a camera buried in the hull; this answers all three in one
--- paste, with two position samples a second apart to settle "is it moving".
RegisterCommand('brbus', function()
    print('=== bus (client) ===')
    print(('  riding %s   bus %s   cam %s   dropStateGate %s'):format(
        tostring(riding), tostring(bus), tostring(cam), tostring(BR.State.me.state)))
    print(('  clock  offset %.0fms  synced %s  now %d'):format(
        BR.Clock.offset, tostring(BR.Clock.synced), BR.Clock.now()))
    if not route then print('  route  none') return end
    local now = BR.Clock.now()
    print(('  route  %d pts  tStart %+.1fs  doors %+.1fs  tEnd %+.1fs  (relative to now)')
        :format(#route.points, (route.tStart - now) / 1000,
                (route.jumpFrom - now) / 1000, (route.tEnd - now) / 1000))
    local x, y, z = BR.PathPosAt(route.points, now)
    print(('  route pos now   %.0f, %.0f, %.0f'):format(x, y, z))
    if bus and DoesEntityExist(bus) then
        local c = GetEntityCoords(bus)
        print(('  bus entity pos  %.0f, %.0f, %.0f'):format(c.x, c.y, c.z))
        Citizen.SetTimeout(1000, function()
            if bus and DoesEntityExist(bus) then
                local c2 = GetEntityCoords(bus)
                print(('  bus 1s later    %.0f, %.0f  (moved %.0fm)')
                    :format(c2.x, c2.y, BR.Dist(c.x, c.y, c2.x, c2.y)))
            end
        end)
    end
end, false)

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then cleanup() end
end)
