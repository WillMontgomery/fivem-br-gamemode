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
local toldClosing = false
local ejectedSeen = nil -- when we noticed the server flipped us to FREEFALL
local dropBegun = false -- this flight's drop has started; a LATE BUS_JUMP_OK
                        -- must not re-teleport a fall the self-place fallback
                        -- already began
local lastX, lastY, lastZ, lastT = nil, nil, nil, nil  -- finite-difference state
local camYaw, camPitch = 0.0, -8.0   -- free-look orbit, reset each boarding
local gearAt = nil      -- when to retract the landing gear; true once done
local boardGen = 0      -- boarding generation; a stale boarding thread abandons
local islandCut = false -- this flight has already released the lobby island

-- Smoothed airframe orientation. The path is a polyline, so its raw
-- direction is CONSTANT within a segment and STEPS at every waypoint -- the
-- turn is built from 6-degree jumps. Feeding that straight into the
-- entity's rotation made the plane stutter through the arc, and because the
-- camera orbit was based on the same raw heading, every step swung the
-- whole view with it: the "world snaps and rotates back" report.
local smoothHdg, smoothPitch, smoothRoll = nil, 0.0, 0.0

local function angDiff(a, b)
    return ((a - b + 540.0) % 360.0) - 180.0
end

local function cleanup()
    boardGen = boardGen + 1   -- abandon any boarding thread still streaming
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
    smoothHdg, smoothPitch, smoothRoll = nil, 0.0, 0.0
    gearAt = nil
    if riding then
        -- Whatever ends the ride, the ped must come back to the world: off
        -- the plane (it rode ATTACHED -- that is what keeps the minimap and
        -- streaming following the flight), visible, its own master.
        local ped = PlayerPedId()
        DetachEntity(ped, true, false)
        SetEntityVisible(ped, true, false)
        riding = false
    end
    told = false
    toldClosing = false
    ejectedSeen = nil
end

-- ------------------------------------------------------- the map drawing ---

local routeDrawn = false

local function clearCrumbs()
    if routeDrawn then
        ClearGpsMultiRoute()
        routeDrawn = false
    end
end

--- Draw the flight as a SOLID LINE on the map and minimap.
---
--- A GPS MULTI-ROUTE, not blips: multi-routes draw straight segments
--- between arbitrary points (unlike ordinary GPS, which snaps to roads),
--- which is the one native way to put a real line on the map -- the old
--- breadcrumb dots read as scattered debris (user call, 2026-08-04).
--- Sampled down: the multi-route point budget is small, and a flight is
--- straight runs and gentle arcs -- every ~4th path point traces it
--- faithfully.
local function drawCrumbs()
    clearCrumbs()
    if not route then return end

    StartGpsMultiRoute(25, true, true)   -- hud colour 25; on foot + in vehicle
    local pts = route.points
    local step = math.max(1, math.floor(#pts / 40))
    for i = 1, #pts, step do
        AddPointToGpsMultiRoute(pts[i].x, pts[i].y, pts[i].z)
    end
    if (#pts - 1) % step ~= 0 then
        AddPointToGpsMultiRoute(pts[#pts].x, pts[#pts].y, pts[#pts].z)
    end
    SetGpsMultiRouteRender(true)
    routeDrawn = true
end

RegisterNetEvent(BR.Net.BUS_ROUTE)
AddEventHandler(BR.Net.BUS_ROUTE, function(r)
    route = r
    dropBegun = false   -- a fresh route is a fresh flight
    drawCrumbs()
end)

-- The route drawing lives and dies with the pre-drop states.
RegisterNetEvent(BR.Net.STATE)
AddEventHandler(BR.Net.STATE, function(d)
    if d.state ~= BR.MatchState.WARMUP and d.state ~= BR.MatchState.BUS then
        clearCrumbs()
    end
end)

--- Begin the drop at given coordinates: the one true handoff to skydive.lua.
local function beginDrop(x, y, z, heading)
    dropBegun = true
    cleanup()   -- detaches the ped from the plane, among everything else
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
    islandCut = false   -- fresh flight, fresh island handoff
    boardGen = boardGen + 1
    local gen = boardGen

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
        -- STALE-BOARDING GUARD. Model streaming takes real time (longest
        -- right after the island unloads), and a state flap can run
        -- cleanup() and a SECOND board() while this thread is still waiting
        -- -- which is how one flight produced two planes (handles 258 and
        -- 770), the first orphaned with the ped attached to nothing the fly
        -- loop moves. The generation token means a superseded boarding
        -- quietly abandons instead of finishing.
        if not riding or gen ~= boardGen then return end

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
        -- (No engine-smoke particles. Two rounds of tuning could not make
        -- looped ptfx read as exhaust: particles detach into world space
        -- with no slipstream, and the effect's emitter geometry trailed
        -- forward regardless of anchor. Removed by user call, 2026-08-04
        -- -- the props, audio and heat-haze the engine sim provides are
        -- the effect.)

        -- THE PED RIDES IN THE PLANE, attached at a cabin offset varied by
        -- server id so co-riders spread through the fuselage instead of
        -- stacking in one seat. This is what makes the minimap and the
        -- world's streaming follow the flight -- both track the PED, and a
        -- ped parked at the airstrip kept the minimap there too. Attaching
        -- own-local-ped to own-local-plane has none of the network attach
        -- problems this design originally avoided; nothing here is synced.
        -- It also retires the in-flight freeze, whose per-frame re-freeze
        -- was racing the drop setup at the moment of the jump.
        local ped = PlayerPedId()
        local srcN = BR.State.me.src or 0
        AttachEntityToEntity(ped, bus,
            0,
            (srcN % 3 - 1) * 0.9,            -- across the cabin
            -1.5 - (srcN % 4) * 1.3,         -- down the fuselage
            0.4,
            0.0, 0.0, 0.0, false, false, false, false, 2, true)
        SetEntityVisible(ped, false, false)

        -- Unattached camera, positioned every frame by the fly loop: an
        -- attached camera is welded in place, and free look was the first
        -- thing missed. HUD chrome goes with it -- the ride is a cutscene.
        camYaw, camPitch = 0.0, -8.0
        smoothHdg = route.heading or heading   -- parked look-ahead is zero-length;
                                               -- without this the first rotation
                                               -- write snapped the plane to north
        cam = CreateCamWithParams('DEFAULT_SCRIPTED_CAMERA',
            p0.x, p0.y, p0.z + BR.Config.Bus.camHeight,
            0.0, 0.0, 0.0, 65.0, false, 2)
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

    -- `not dropBegun` closes THE JUMP RACE (repro: jump the moment the
    -- doors open). The server ejects and sends BUS_JUMP_OK immediately,
    -- but the FREEFALL state rides the 4Hz delta flush -- so the OK
    -- often lands FIRST. beginDrop() tears the plane down, this loop
    -- then saw "not riding, mirror still says BUS" and put the player
    -- BACK ABOARD A SECOND PLANE mid-drop (handles 258/770, live log):
    -- re-attached, re-hidden, camera up -- while falling. That wrecked
    -- the drop state machine and read as invincibility. Once this
    -- flight's drop has begun, there is nothing left to board.
    if not riding and not dropBegun and route and route.timed
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
                local x, y, z, ddx, ddy = BR.PathPosAt(route.points, BR.Clock.now())
                beginDrop(x, y, z, BR.GtaHeading(BR.Bearing(0.0, 0.0, ddx, ddy)))
            end
        else
            -- Dead, back to lobby, match torn down -- nothing airborne about
            -- any of it. Plain teardown. LOGGED with the state that caused
            -- it: a mid-flight teardown+reboard has happened once (the
            -- two-plane flight) and the trigger state is the evidence.
            print(('[br_core] bus: ending ride -- my state is %s'):format(tostring(me)))
            cleanup()
        end
    end

    -- (The doors-open prompt is drawn per-frame in bus.jumpkey below, so it
    -- PERSISTS for the whole jump window instead of fading on the engine's
    -- own schedule.)

    -- THE ISLAND HANDOFF: a few seconds AFTER WHEELS-UP -- clocked from
    -- rotateAt, not tStart, which is when the ROLL begins: the first cut
    -- fired while the plane was still on the runway it was deleting (live
    -- report). Airborne with the forward view on open ocean and the
    -- overcast haze flattening the horizon, the lobby island is released
    -- so Los Santos can exist (they are mutually exclusive; br_environment
    -- owns the switch and the weather choreography that hides the swap).
    if riding and not islandCut and route and route.timed
       and BR.Clock.now() >= (route.rotateAt or route.tStart) + 3500 then
        islandCut = true
        TriggerEvent('br:env:releaseIsland')
    end

    -- Last call: past the final authored waypoint the plane flies its
    -- overrun; whoever is still aboard when it runs out goes out anyway.
    -- Native help with the beep, like every other door/chute message --
    -- flight prompts live in the game's own scaleforms, not the NUI stack.
    if riding and not toldClosing and route and route.timed
       and BR.Clock.now() >= route.doorsClose then
        toldClosing = true
        BR.Native.help('Doors closing — jump now!')
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
    local x, y, z = BR.PathPosAt(route.points, t)

    -- A hand on the yoke: slow layered sine drift in altitude, +/- ~8 units,
    -- driven by the SYNCED clock so all 48 planes drift identically. Only
    -- once airborne -- and RAMPED IN over the first ~120m of climb: switching
    -- it on at full amplitude the moment the wheels cleared 15m added up to
    -- eight metres in one frame, which was the "small but noticeable vertical
    -- jump" right off the pavement.
    local above = z - (route.points[1].z + 15.0)
    if above > 0.0 then
        -- Wheels up: tuck the gear five seconds after leaving the pavement,
        -- like an aircraft that means it. gearAt doubles as the done-flag.
        if not gearAt then
            gearAt = GetGameTimer() + 5000
        elseif gearAt ~= true and GetGameTimer() >= gearAt then
            ControlLandingGear(bus, 3)   -- 3 = retract
            gearAt = true
        end

        local amp = math.min(1.0, above / 120.0)
        z = z + (math.sin(t * 0.00037) * 5.0 + math.sin(t * 0.00011 + 1.7) * 3.0) * amp
    end

    SetEntityCoordsNoOffset(bus, x, y, z, false, false, false)

    -- ORIENTATION FROM A LOOK-AHEAD, EASED. Where will the bus be in 1.2
    -- seconds? The direction to there spans waypoint boundaries, so it
    -- changes continuously through the turn instead of stepping with the
    -- polyline -- and the exponential ease below takes out what little
    -- stepping remains. Roll banks into the heading change and pitch
    -- follows the climb, both gently.
    local ax, ay, az = BR.PathPosAt(route.points, t + 1200)
    local ddx, ddy, ddz = ax - x, ay - y, az - z
    local hLen = math.sqrt(ddx * ddx + ddy * ddy)

    local dt = GetFrameTime()
    local ease = 1.0 - math.exp(-dt * 2.2)

    if hLen > 1.0 then
        local targetHdg = BR.GtaHeading(BR.Bearing(0.0, 0.0, ddx, ddy))
        smoothHdg = smoothHdg or targetHdg
        local turn = angDiff(targetHdg, smoothHdg)
        smoothHdg = (smoothHdg + turn * ease) % 360.0

        -- Bank proportional to how hard the nose is being asked to come
        -- around. 2.5x the first pass, per feedback -- the shallow bank read
        -- as a plane sliding sideways through its own turn.
        local targetRoll  = BR.Clamp(-turn * 2.2, -42.0, 42.0)
        local targetPitch = BR.Clamp(math.deg(math.atan(ddz, hLen)) * 0.8, -14.0, 14.0)
        smoothRoll  = smoothRoll + (targetRoll - smoothRoll) * ease
        smoothPitch = smoothPitch + (targetPitch - smoothPitch) * ease
    end

    SetEntityRotation(bus, smoothPitch, smoothRoll, smoothHdg or 0.0, 2, true)

    local vx, vy, vz = 0.0, 0.0, 0.0
    if lastT and t > lastT then
        local inv = 1000.0 / (t - lastT)
        vx, vy, vz = (x - lastX) * inv, (y - lastY) * inv, (z - lastZ) * inv
        SetEntityVelocity(bus, vx, vy, vz)
    end
    lastX, lastY, lastZ, lastT = x, y, z, t
    -- No streaming focus hint needed anymore: the ped rides the plane, and
    -- the world streams around the ped all by itself.

    -- Free-look orbit: mouse (or right stick) walks the camera around the
    -- plane; it always looks AT the plane, so there is no way to get lost.
    -- Based on the SMOOTHED heading -- on the raw one, every waypoint step
    -- swung the entire view and snapped it back.
    if cam then
        camYaw   = (camYaw - GetControlNormal(0, 1) * 8.0) % 360.0
        camPitch = BR.Clamp(camPitch - GetControlNormal(0, 2) * 6.0, -75.0, 25.0)

        local dist = BR.Config.Bus.camDistance
        local yawRad   = math.rad((smoothHdg or 0.0) + 180.0 + camYaw)  -- 0 = behind
        local pitchRad = math.rad(camPitch)
        local horiz = dist * math.cos(pitchRad)
        SetCamCoord(cam,
            x - math.sin(yawRad) * horiz,
            y + math.cos(yawRad) * horiz,
            z + BR.Config.Bus.camHeight - dist * math.sin(pitchRad))
        PointCamAtCoord(cam, x, y, z + 4.0)
    end
end)

-- Ask to jump. (skydive.lua owns the freefall half of the same intent;
-- `riding` and `dropping` are mutually exclusive, so exactly one of the two
-- acts on any press.)
local function tryJump()
    if not riding or not route or not route.timed then return end
    -- No toast on an early press: the persistent doors-open prompt IS the
    -- state display now -- its absence says the doors are still shut, and
    -- door/chute messaging lives entirely in the native scaleforms.
    if BR.Clock.now() < route.jumpFrom then return end
    TriggerServerEvent(BR.Net.BUS_JUMP)
end

BR.Keys.on('deploy', function(pressed)
    if pressed then tryJump() end
end)

-- The BASE GAME's parachute-deploy control works aboard too -- it is the key
-- the doors-open prompt displays (custom keymapping hashes refused to render
-- a glyph in help text; INPUT_PARACHUTE_DEPLOY always does, and one key for
-- the whole descent was the design anyway). Frame-polled because
-- IsControlJustPressed only lives for the frame it happened in.
local INPUT_PARACHUTE_DEPLOY = 144
BR.Loop.register(BR.Loop.FRAME, 'bus.jumpkey', function()
    if not riding then return end

    -- The prompt PERSISTS from doors-open until this player jumps --
    -- redrawn per frame, gone the frame `riding` flips. Past the last
    -- authored waypoint it hardens into the last call (the TICK block
    -- above beeps once at that moment; this keeps the text on screen).
    if route and route.timed and BR.Clock.now() >= route.jumpFrom then
        BR.Native.helpThisFrame(BR.Clock.now() >= route.doorsClose
            and 'Doors closing — press ~INPUT_PARACHUTE_DEPLOY~ NOW!'
            or  'Doors open — press ~INPUT_PARACHUTE_DEPLOY~ to jump.')
    end

    if IsControlJustPressed(0, INPUT_PARACHUTE_DEPLOY) then
        tryJump()
    end
end)

RegisterNetEvent(BR.Net.BUS_JUMP_OK)
AddEventHandler(BR.Net.BUS_JUMP_OK, function(d)
    if dropBegun then
        -- The self-place fallback beat these coordinates here. Snapping the
        -- ped back up to the route mid-fall would restart the whole drop.
        print('[br_core] bus: exit coords arrived late -- already dropping, ignored')
        return
    end
    if ejectedSeen then
        -- The eject state flip was seen before the coordinates: measure the
        -- gap. "Exit coords never arrived" repros need this number.
        print(('[br_core] bus: exit coords arrived %dms after the eject flip')
            :format(GetGameTimer() - ejectedSeen))
    end
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
    print(('  route  %d pts  %d crumbs  legs %s  timed %s')
        :format(#route.points, #crumbs,
                route.legs and table.concat(route.legs, '-') or '?',
                tostring(route.timed)))
    if not route.timed then print('  (preview only -- departs at BUS)') return end
    local now = BR.Clock.now()
    print(('  tStart %+.1fs  doors %+.1fs  tEnd %+.1fs  (relative to now)')
        :format((route.tStart - now) / 1000,
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
    if res == GetCurrentResourceName() then
        cleanup()
        clearCrumbs()
    end
end)
