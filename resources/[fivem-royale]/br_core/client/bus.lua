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
local cam     = nil
local riding  = false
local told    = false   -- "doors open" notice sent
local ejectedSeen = nil -- when we noticed the server flipped us to FREEFALL

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
            0.0, 0.0, 0.0, 65.0, false, 2)
        AttachCamToEntity(cam, bus, off.x, off.y, off.z, true)
        PointCamAtEntity(cam, bus, 0.0, 0.0, 0.0, true)
        SetCamActive(cam, true)
        RenderScriptCams(true, false, 0, true, true)

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
                local x, y = BR.RoutePosAt(route, BR.Clock.now())
                beginDrop(x, y, route.alt,
                          BR.Bearing(route.mx, route.my, route.ex, route.ey))
            end
        else
            -- Dead, back to lobby, match torn down -- nothing airborne about
            -- any of it. Plain teardown.
            cleanup()
        end
    end

    if riding and not told and route and BR.Clock.now() >= route.tMid then
        told = true
        TriggerEvent('br:ui:sendLocal', BR.Nui.TOAST, {
            text = 'Doors open — SPACE to jump.', tone = 'info', ms = 6000,
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

-- SPACE, bus half: ask to jump. (skydive.lua owns the freefall half of the
-- same key; `riding` and `dropping` are mutually exclusive, so exactly one
-- of the two listeners acts on any press.)
BR.Keys.on('deploy', function(pressed)
    if not pressed or not riding or not route then return end
    if BR.Clock.now() < route.tMid then
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
    print(('  route  tStart %+.1fs  tMid %+.1fs  tEnd %+.1fs  (relative to now)')
        :format((route.tStart - now) / 1000, (route.tMid - now) / 1000,
                (route.tEnd - now) / 1000))
    local x, y = BR.RoutePosAt(route, now)
    print(('  route pos now   %.0f, %.0f'):format(x, y))
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
