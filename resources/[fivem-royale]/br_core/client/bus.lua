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
-- CONTROLS: one key, and it is OURS. `deploy` (keybinds.lua, default SPACE)
-- jumps once the doors are open and deploys the glider afterwards -- skydive.lua
-- owns that half of the same binding. Rebinding it in Settings moves both, and
-- nothing here reads an engine control behind the player's back (#174).

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

--- IN LUA 0 IS TRUTHY, AND A FIVEM NATIVE DECLARED BOOL MAY ANSWER 1 RATHER
--- THAN true. This file is the front half of the drop, and every model wait in
--- it was read raw: `while not HasModelLoaded(m) do` is FALSE for the 0 that
--- means "not loaded", so the wait ends immediately and CreateVehicle is handed
--- a model that is not in memory. What comes back is nil, and the flight -- and
--- with it everybody's jump -- is over before it started.
--- @param v any
--- @return boolean
local function isTrue(v)
    return v ~= nil and v ~= false and v ~= 0
end

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
        if isTrue(DoesEntityExist(pilot)) then DeleteEntity(pilot) end
        pilot = nil
    end
    if bus then
        if isTrue(DoesEntityExist(bus)) then DeleteEntity(bus) end
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
--- How many points the last custom route was drawn from. /brbus prints it, and
--- it used to print `#crumbs` -- a local that does not exist anywhere in this
--- file, so the ONE command a playtester is asked to paste when the plane
--- misbehaves raised on its own third line instead of answering.
local crumbCount = 0

local function clearCrumbs()
    if routeDrawn then
        ClearGpsCustomRoute()
        routeDrawn = false
        crumbCount = 0
    end
end

--- Draw the flight as a SOLID LINE on the map and minimap.
---
--- A GPS CUSTOM ROUTE -- the race-creator air-route line. The first
--- attempt used the MULTI route, which still runs GPS pathfinding: it
--- snapped every segment to the road network and drew NOTHING over open
--- country (map screenshot, 2026-08-04). The CUSTOM route is the one
--- that draws straight point-to-point segments anywhere.
---
--- Point budget stays respected (the multi-route lesson: the engine
--- renders only a handful): start + authored waypoints + overrun end,
--- resampled down to a dozen. Straight lines between waypoints are
--- exactly what the flight is; the fillets only round the corners.
local function drawCrumbs()
    clearCrumbs()
    if not route then return end

    -- Sampled from the FULL PATH, curves included: the "point budget"
    -- theory was a misdiagnosis (the runway-only line was the multi-route
    -- road-snapping over open water), so the custom route gets enough
    -- points to trace the filleted corners. ~36 still showed its polygon
    -- edges; ~90 across the tour is past what the eye resolves at map
    -- scale (user call, 2026-08-04; no documented native point cap).
    local line = {}
    local pts = route.points
    local step = math.max(1, math.floor(#pts / 90))
    for i = 1, #pts, step do
        line[#line + 1] = pts[i]
    end
    if line[#line] ~= pts[#pts] then
        line[#line + 1] = pts[#pts]
    end

    StartGpsCustomRoute(0, true, true)   -- hud colour 0 (pure white)
    for _, p in ipairs(line) do
        AddPointToGpsCustomRoute(p.x, p.y, p.z or 200.0)
    end
    SetGpsCustomRouteRender(true, 16, 16)   -- radar + map line thickness
    routeDrawn = true
    crumbCount = #line
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
        while not isTrue(HasModelLoaded(model)) and GetGameTimer() < deadline do
            Citizen.Wait(50)
        end
        if not isTrue(HasModelLoaded(model)) then
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
        while not isTrue(HasModelLoaded(pilotModel)) and GetGameTimer() < pDeadline do
            Citizen.Wait(50)
        end
        if isTrue(HasModelLoaded(pilotModel)) then
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

    -- (The doors-open prompt is drawn per-frame in bus.prompt below, so it
    -- PERSISTS for the whole jump window instead of fading on the engine's
    -- own schedule.)

    -- THE ISLAND HANDOFF: a few seconds AFTER WHEELS-UP -- clocked from
    -- rotateAt, not tStart, which is when the ROLL begins: the first cut
    -- fired while the plane was still on the runway it was deleting (live
    -- report). Airborne with the forward view on open ocean and the
    -- overcast haze flattening the horizon, the lobby island is released
    -- so Los Santos can exist (they are mutually exclusive; br_environment
    -- owns the switch and the weather choreography that hides the swap).
    -- 5.5s: the +3.5s cut still read as abrupt, so the swap AND the
    -- weather clear that rides it wait two more seconds (user call).
    if riding and not islandCut and route and route.timed
       and BR.Clock.now() >= (route.rotateAt or route.tStart) + 5500 then
        islandCut = true
        TriggerEvent('br:env:releaseIsland')
    end

    -- Last call: past the final authored waypoint the plane flies its
    -- overrun; whoever is still aboard when it runs out goes out anyway.
    --
    -- THE BEEP, AND ONLY THE BEEP. The persistent prompt is a DUI now (see
    -- bus.prompt below) and it hardens into its own "doors closing" wording on
    -- the same tick -- but a DUI cannot make a noise, and this moment is the
    -- one in the whole flight that has to reach a player who is looking at the
    -- map. BR.Native.help is the one-shot with the sound; it fades on the
    -- engine's own clock while the box stays up. Deliberately names NO key: the
    -- box beside it is the thing that names the key, and two places printing
    -- one binding is how they come to disagree.
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
    -- state display -- its absence says the doors are still shut. (That box is
    -- our own DUI now rather than the engine's help text; see the prompt
    -- section below. The rule it enforces is unchanged.)
    if BR.Clock.now() < route.jumpFrom then return end
    TriggerServerEvent(BR.Net.BUS_JUMP)
end

-- ONE BINDING, BOTH JOBS, AND IT IS THE ONLY READER (#174).
--
-- Owner, 2026-08-18: "the jump and parachute keys should be the same." They
-- already were, by name: `deploy` is registered once in keybinds.lua as
-- "Royale: Jump / deploy glider", default SPACE, and skydive.lua listens on the
-- same action for the canopy. What was not ours is what used to sit below this
-- line -- a SECOND reader, in parallel with the first:
--
--     local INPUT_PARACHUTE_DEPLOY = 144
--     if IsControlJustPressed(0, INPUT_PARACHUTE_DEPLOY) then tryJump() end
--
-- It was written when our own binding could not be drawn as a glyph, and it
-- cost three separate things:
--
--   * A REBIND DID NOT MOVE THE JUMP, it only ADDED a key. Move `deploy` to J
--     and J jumped -- and so did Space, forever, because nothing can move the
--     engine's control 144 and nothing here stopped reading it. The settings
--     screen said J. Both were true, which is worse than either.
--
--   * ONE PRESS SENT TWO BUS_JUMPs. On the default binding both readers see
--     the same physical Space in the same frame -- keybinds.raw fires `deploy`,
--     this loop polls 144 -- and `riding` is still true between them, because
--     it only clears when the server answers. Two BUS_JUMP events per jump,
--     every jump, on every client.
--
--   * AND THE PROMPT NAMED 144's KEY rather than the player's, which is the
--     symptom that got reported. It could not have named ours: the prompt was
--     GTA's help box, and `~INPUT_<hash>~` for one of our commands renders a
--     hole (measured, /brpromptcheck; see dui.lua's drawScreen note).
--
-- So there is one reader, and it is BR.Keys. Everything the removed poll gave a
-- player who never opens the settings screen, the default gives instead: SPACE
-- is `deploy`'s default and 0x20 is in keybinds.lua's DEFAULT_VK, so the raw
-- layer watches Space -- and on a client with no raw layer at all, the engine's
-- own `brdeploy` keymapping delivers the very same press to the very same
-- listener. Nothing changes for that player. For the player who DID rebind, the
-- key they chose is now the only one that works, which is what a rebinder is.
BR.Keys.on('deploy', function(pressed)
    if pressed then tryJump() end
end)

-- ------------------------------------------------------------- the prompt ---
--
-- OUR BOX, DRAWN BY US, NAMING OUR KEY.
--
-- Owner: "'press [glyph] to jump' text when in the bus - we should apply our
-- key layer and use a DUI for that instead." Both halves land here, and the
-- second is only possible because of the first: a prompt cannot name our key
-- unless our key is the one being read.
--
-- The precedent is skydive.lua's descent prompt, deliberately followed rather
-- than reinvented -- same page, same position, same scale, so the box the
-- player is looking at when they press the key is the box that is still there
-- after they fall out of the plane, saying the next thing.

--- THE BROWSER'S OWN CLOCK, AND IT IS WHAT ANSWERS THE NEXT ROUND IN ONE PASTE.
---
--- `sends`/`draws`/`fallbacks` below are LIFETIME counters -- across two matches
--- a non-zero `draws` can belong entirely to the previous flight -- so they can
--- say THAT the fallback ran and never WHY. These two stamps can, and they
--- separate the only two answers there are:
---
---   created, then ready 900ms later  -- the browser works and was asked for too
---                                       late. That is the fault fixed here, and
---                                       warming it earlier is the whole cure.
---
---   created, still not ready at 40s  -- a third concurrent CEF instance is not
---                                       being granted at all. No amount of
---                                       warming helps and the next round is
---                                       about SHARING a page, not timing one.
---
--- Never reset. A flight that never opened its doors has no stamp at all, which
--- is its own third answer and is printed as such.
local promptCreatedAt, promptReadyAt = nil, nil

--- How long the prompt waits for its own browser before using the engine box.
--- Three seconds, the owner's number. Long enough that a slow start is covered
--- and short enough that a browser which is never coming does not eat the whole
--- jump window in silence.
local PROMPT_GRACE_MS = 3000

--- The jump prompt's page. Its own browser, NOT the descent prompt's.
---
--- skydive.lua makes this argument for `descentprompt` and it holds here with
--- one edge added: the two boxes are CONSECUTIVE. On the frame the jump lands,
--- this file's `riding` clears and skydive's `dropping` sets -- so a page owned
--- by both would have two writers on that one frame, one saying "hide" and one
--- saying "open the glider", in an order neither file controls. One extra CEF
--- instance is the price of never having to reason about that ordering.
---
--- WHEN THE BROWSER IS BUILT, WHICH IS THE WHOLE OF THIS ISSUE'S SECOND ROUND.
---
--- The first version reached this lazily, from the draw loop, "so the browser is
--- created the first time a jump window actually opens". That is the one line of
--- skydive.lua's descent prompt this file did not copy, and it is the line that
--- makes the prompt appear:
---
---   a DUI is a whole CEF instance and IsDuiAvailable is FALSE for a beat after
---   CreateDui -- messages sent before it answers are dropped and the sprite
---   draws nothing (dui.lua). Asked for at the doors, the browser spends that
---   beat inside the jump window, and the window is the only time this box has.
---   A player who jumps in the first second of it -- which is most players, and
---   every playtester -- sees the help-box fallback and NOTHING ELSE, which is
---   verbatim the report: "why are we still using natives".
---
---   the descent prompt beside it looked fine from the same seat, and that is
---   the evidence rather than a contradiction: skydive.lua warms `descentprompt`
---   on the WARMUP/BUS edge, so by the time anyone falls out of the plane its
---   browser has had the whole flight to come up. Same page, same size, same
---   file it was copied from -- different creation time, opposite outcome.
---
--- So it is warmed on the same edge, from the handler below. BR.Dui.page
--- memoises, so this costs one CEF instance moved EARLIER in the session rather
--- than an extra one: nothing in dui.lua destroys a page short of the resource
--- stopping, so `busprompt` was going to live from the first jump window to the
--- end of the session either way. What changes is that its first ~90 seconds of
--- life are the lobby and the climb instead of the ten seconds it is needed.
--- Idle, it is a hidden page with no timer, no animation and no traffic
--- (br_ui/dui/prompt.html only acts on a message), and it is not drawn: the
--- draw call lives in the window and nowhere else.
local function promptPage()
    if not promptCreatedAt then promptCreatedAt = GetGameTimer() end
    return BR.Dui.page('busprompt', 'nui://br_ui/dui/prompt.html', 512, 256)
end

--- THE SAME EDGE skydive.lua WARMS ITS OWN PAGE ON, deliberately: the two boxes
--- are one box to the player, they are the same document at the same size, and
--- warming them together means they come up together or fail together rather
--- than one of them silently lagging into the window it serves.
---
--- No edge-detection and no bookkeeping: BR.Dui.page memoises on the name, so
--- every STATE broadcast after the first is a table lookup. Registered here
--- rather than folded into the handler at the top of the file so the prompt's
--- lifetime stays in the prompt's own section -- the top one owns the map line.
AddEventHandler(BR.Net.STATE, function(d)
    if type(d) ~= 'table' then return end
    if d.state == BR.MatchState.WARMUP or d.state == BR.MatchState.BUS then
        promptPage()
    end
end)

--- What the box is currently saying: nil, 'open' or 'closing'.
---
--- SENT ON CHANGE, DRAWN EVERY FRAME -- dui.lua's opening note is about exactly
--- this split. Re-sending the same payload sixty times a second would put a
--- JSON encode and a browser message on the frame path for no visible change.
local promptKind = nil

--- The jump key's label, cached for the length of a binding.
---
--- `checked` is separate from the label because NIL IS A REAL ANSWER: a player
--- whose `brdeploy` binding is on no key -- cleared deliberately, or having
--- lost a key conflict to another action, which BR.Keys.set resolves by
--- clearing the loser -- has no jump key at all, and re-asking every frame for
--- an answer that will not change is what the cache is avoiding.
local keyLabel, keyChecked = nil, false

--- NO VANILLA FALLBACK HERE, AND THAT IS THE POINT OF THE WHOLE CHANGE.
---
--- skydive.lua asks for this same command as `keyName('brdeploy', 144)`, with
--- the vanilla control as a fallback, and it is right to: under a parachute
--- task GTA's own INPUT_PARACHUTE_DEPLOY genuinely still opens the canopy, so
--- naming it names a key that works. ABOARD THE PLANE IT DOES NOT. The poll
--- that made 144 jump is what this change removed, and a ped attached to a
--- Titan is in no parachute task to catch it. Passing a fallback here would
--- print a key nothing is listening for, which is #131 and #129's third round
--- verbatim -- the exact bug this issue was opened about.
local function jumpKey()
    if not keyChecked then
        keyChecked = true
        keyLabel = BR.Native.keyLabelForCommand('brdeploy')
    end
    return keyLabel
end

AddEventHandler('br:keys:changed', function()
    keyLabel, keyChecked = nil, false
    -- AND THE BOX IS TOLD TO FORGET WHAT IT WAS SAYING. The payload is only
    -- re-sent when `promptKind` changes, so a rebind mid-flight would move the
    -- cached label and never push it -- "kept saying the old key until they
    -- walked away and back" (user, 2026-08-09), reintroduced by the cache that
    -- exists to avoid it. Clearing the kind forces one re-send next frame.
    promptKind = nil
end)

--- What the prompt has actually done, for /brbus.
---
--- "The prompt did not appear" and "the prompt appeared and the key did
--- nothing" are the same sentence from a chair, and #131 cost five rounds
--- partly because no readout could separate them.
local promptSeen = { kind = nil, sends = 0, draws = 0, fallbacks = 0, waited = 0 }

--- Put the jump window in the box, or take the box away.
--- @param kind string|nil  'open', 'closing' or nil
local function setPrompt(kind)
    promptSeen.kind = kind
    if kind == promptKind then return end
    promptKind = kind
    promptSeen.sends = promptSeen.sends + 1

    local page = promptPage()
    if not kind then
        BR.Dui.send(page, { t = 'prompt', show = false })
        return
    end

    -- AN UNBOUND JUMP GETS A DIFFERENT SENTENCE, NOT AN EMPTY CAP.
    --
    -- The trail prompt draws nothing at all when its key is gone, and for a
    -- cosmetic that is right. Leaving the plane is not a cosmetic. A player can
    -- reach this state without ever having touched the jump row -- bind
    -- something else to Space and `deploy` is the loser that gets cleared -- and
    -- a box that simply vanished would read as the prompt being broken. So it
    -- says which screen fixes it. (They are not stranded either way: the server
    -- force-ejects everyone still aboard at the end of the overrun.)
    local key = jumpKey()
    BR.Dui.send(page, {
        t     = 'prompt',
        show  = true,
        label = (not key) and 'Jump is unbound'
             or (kind == 'closing') and 'Doors closing!'
             or 'Jump from the plane',
        hint  = (not key) and 'Settings > Key Bindings'
             or (kind == 'closing') and 'Press — last call'
             or 'Press',
        -- THE GLYPH. prompt.html draws whatever lands here inside the key cap,
        -- and what lands here is the player's own binding read from BR.Keys.
        key   = key,
        -- No ring: the ring is for a hold, and this is a tap.
        ring  = false,
    })
end

BR.Loop.register(BR.Loop.FRAME, 'bus.prompt', function()
    -- THE WINDOW: doors open until this player is out of the plane. Redrawn
    -- per frame so it PERSISTS instead of fading on the engine's own schedule,
    -- and taken down the frame `riding` clears -- which for a DUI has to be an
    -- explicit instruction rather than an absence, because a DUI holds the last
    -- thing it was told until it is told otherwise. The help box this replaces
    -- expired on its own; a match torn down mid-flight would otherwise leave
    -- "Jump from the plane" hanging over the lobby.
    if not riding or not route or not route.timed
       or BR.Clock.now() < route.jumpFrom then
        setPrompt(nil)
        return
    end

    -- Past the last authored waypoint it hardens into the last call. The TICK
    -- block above beeps once at that moment; this is what keeps it on screen.
    setPrompt(BR.Clock.now() >= route.doorsClose and 'closing' or 'open')

    local page = promptPage()
    if BR.Dui.ready(page) then
        -- The far end of the stamp pair. Latched on the first true, so it is
        -- the moment the browser ANSWERED rather than the moment it was last
        -- seen up, which is the number /brbus needs.
        if not promptReadyAt then promptReadyAt = GetGameTimer() end
        promptSeen.draws = promptSeen.draws + 1
        -- THE DESCENT PROMPT'S OWN POSITION, on purpose. These two boxes are
        -- one box as far as the player is concerned: press the key here, fall
        -- out, and the same plate in the same place is now offering the glider.
        -- Reading BR.Config.Drop rather than copying its numbers means they
        -- cannot drift apart. Scale is dui.lua's business from there -- it
        -- multiplies by the player's interface preference, which is the half of
        -- this request the help box could never honour.
        local D = BR.Config.Drop
        BR.Dui.drawScreen(page, (D and D.promptX) or 0.5,
                                (D and D.promptY) or 0.78,
                                (D and D.promptScale) or 0.17)
    else
        -- GIVE THE BROWSER THREE SECONDS BEFORE FALLING BACK (owner,
        -- 2026-08-18): "If we can't draw the bus text for one beat that's fine.
        -- We should still use DUI - fallback after 3 seconds if we still have
        -- no browser."
        --
        -- The prewarm above means a healthy client is ready long before the
        -- doors open, so this grace is normally never spent. What it buys is
        -- the case it was written for: a slow client where the browser arrives
        -- a beat late no longer shows the engine box for that beat and then
        -- swaps, which reads as two different prompts fighting.
        --
        -- MEASURED FROM CREATION, NOT FROM THE FIRST DRAW. The doors can open
        -- long after the warm edge, and a grace that started here would give a
        -- browser that has already had thirty seconds another three.
        local waited = GetGameTimer() - (promptCreatedAt or GetGameTimer())
        if waited < PROMPT_GRACE_MS then
            promptSeen.waited = promptSeen.waited + 1
            return
        end

        -- A BROWSER THAT NEVER CAME UP MUST NOT MEAN SILENCE (#131's third
        -- round), and here it would cost the whole match rather than a
        -- cosmetic: a player who cannot see the jump prompt does not jump.
        --
        -- So the words fall back to the engine's help box and only the GLYPH is
        -- lost. The letter is still the player's own binding read from BR.Keys,
        -- and it is emphatically NOT an `~INPUT_~` token: the token for one of
        -- our commands renders as a hole, which is the measurement that sent
        -- this prompt to a DUI in the first place.
        promptSeen.fallbacks = promptSeen.fallbacks + 1
        local key = jumpKey()
        BR.Native.helpThisFrame(key and (('%s — press %s to jump.'):format(
                BR.Clock.now() >= route.doorsClose and 'Doors closing'
                                                    or 'Doors open', key))
            or 'Jump is unbound -- set a key in Settings > Key Bindings.')
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

-- ------------------------------------------------------- ghost flights ---
--
-- OTHER matches' departures, rendered for the audience on the tarmac
-- (user call, 2026-08-04). The warmup pad is communal now, and a departing
-- flight's riders are visible peds -- but their plane is client-local, so
-- without this the bystanders watched a formation of people levitate away.
-- The server sends warmup bystanders a spectator copy of the timed route
-- (BUS_SPECTATE); this renders a local, non-networked plane flying it.
-- Purely scenery: no camera, no attachment, no gameplay.

local ghosts = {}   -- [matchId] = { route, plane, pilot, hdg, spawning }

local function removeGhost(id)
    local g = ghosts[id]
    if not g then return end
    if g.pilot and isTrue(DoesEntityExist(g.pilot)) then DeleteEntity(g.pilot) end
    if g.plane and isTrue(DoesEntityExist(g.plane)) then DeleteEntity(g.plane) end
    ghosts[id] = nil
end

local function clearGhosts()
    for id in pairs(ghosts) do removeGhost(id) end
end

local function spawnGhost(g)
    g.spawning = true
    Citizen.CreateThread(function()
        local model = GetHashKey(BR.Config.Bus.model)
        RequestModel(model)
        local deadline = GetGameTimer() + 10000
        while not isTrue(HasModelLoaded(model)) and GetGameTimer() < deadline do
            Citizen.Wait(50)
        end
        if not isTrue(HasModelLoaded(model)) or not g.route then
            g.spawning = false
            return
        end
        local p0 = g.route.points[1]
        g.plane = CreateVehicle(model, p0.x, p0.y, p0.z,
                                g.route.heading or 0.0, false, false)
        SetModelAsNoLongerNeeded(model)
        SetEntityCollision(g.plane, false, false)
        SetEntityInvincible(g.plane, true)
        -- The crew keeps the engine sim (props, audio) alive, same as the
        -- real ride's plane.
        local pilotModel = GetHashKey('s_m_m_pilot_01')
        RequestModel(pilotModel)
        local pDeadline = GetGameTimer() + 5000
        while not isTrue(HasModelLoaded(pilotModel)) and GetGameTimer() < pDeadline do
            Citizen.Wait(50)
        end
        if isTrue(HasModelLoaded(pilotModel)) and isTrue(DoesEntityExist(g.plane)) then
            g.pilot = CreatePed(4, pilotModel, p0.x, p0.y, p0.z,
                                g.route.heading or 0.0, false, false)
            SetModelAsNoLongerNeeded(pilotModel)
            SetEntityInvincible(g.pilot, true)
            SetBlockingOfNonTemporaryEvents(g.pilot, true)
            SetPedIntoVehicle(g.pilot, g.plane, -1)
        end
        SetVehicleEngineOn(g.plane, true, true, false)
        g.spawning = false
    end)
end

RegisterNetEvent(BR.Net.BUS_SPECTATE)
AddEventHandler(BR.Net.BUS_SPECTATE, function(d)
    if type(d) ~= 'table' or not d.matchId or not d.route
       or not d.route.timed then return end
    removeGhost(d.matchId)   -- a re-send replaces
    ghosts[d.matchId] = {
        route = d.route,
        hdg   = d.route.heading or 0.0,
    }

    -- WATCHING SOMEONE ELSE'S PLANE LEAVE NEEDS AN EXPLANATION. From the pad
    -- it is indistinguishable from your own flight departing without you --
    -- that match was full, or it is the other mode, and either way this
    -- player is fine (user, 2026-08-05). Delayed so it lands with the plane
    -- in the air rather than before it has spawned, and re-checked on fire:
    -- three seconds is long enough to have boarded your own bus, and a
    -- "next flight" toast aboard your own plane would be nonsense.
    Citizen.SetTimeout(3000, function()
        if BR.State.me.state ~= BR.PlayerState.WARMUP then return end
        if not ghosts[d.matchId] then return end
        TriggerEvent('br:ui:sendLocal', BR.Nui.TOAST, {
            text = 'Another match is dropping — you are on the next flight.',
            tone = 'info', ms = 7000,
        })
    end)
end)

BR.Loop.register(BR.Loop.FRAME, 'bus.ghosts', function()
    if not next(ghosts) then return end

    -- Ghosts exist for the pre-flight audience: my own warmup, or my own
    -- boarding/ride (another flight climbing out past the window is
    -- exactly the scenery this is for). Any other state means I have
    -- moved on and the tarmac is no longer my problem.
    local st = BR.State.me.state
    if st ~= BR.PlayerState.WARMUP and st ~= BR.PlayerState.BUS then
        clearGhosts()
        return
    end

    local t = BR.Clock.now()
    for id, g in pairs(ghosts) do
        local r = g.route
        if t > r.tEnd + 5000 then
            removeGhost(id)
        else
            if not g.plane and not g.spawning then spawnGhost(g) end
            if g.plane and isTrue(DoesEntityExist(g.plane)) then
                local x, y, z = BR.PathPosAt(r.points, t)
                SetEntityCoordsNoOffset(g.plane, x, y, z, false, false, false)

                -- Look-ahead heading, exponentially eased -- the same cure
                -- for polyline stepping the real ride uses, minus the roll
                -- theatrics nobody can judge from the ground.
                local ax, ay = BR.PathPosAt(r.points, t + 1200)
                local dx, dy = ax - x, ay - y
                if dx * dx + dy * dy > 1.0 then
                    local target = BR.GtaHeading(BR.Bearing(0.0, 0.0, dx, dy))
                    local turn = ((target - g.hdg + 540.0) % 360.0) - 180.0
                    g.hdg = (g.hdg + turn
                        * (1.0 - math.exp(-GetFrameTime() * 2.2))) % 360.0
                end
                SetEntityRotation(g.plane, 0.0, 0.0, g.hdg, 2, true)
            end
        end
    end
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
    -- THE PROMPT AND THE KEY, BEFORE THE ROUTE, because "there was no prompt"
    -- and "the prompt named a key that did nothing" are the two reports this
    -- subsystem has actually produced, and neither of them was answerable from
    -- a paste. `key` is read through the same BR.Keys.labelFor the box itself
    -- prints, so this line cannot agree with a lie the box is telling.
    -- `fallbacks` rising means the DUI browser never came up and the words are
    -- coming from the engine's help box -- a different fault from a prompt that
    -- was never asked for, and indistinguishable from one on screen.
    print(('  prompt %s   key %s   sends %d  draws %d  help-fallbacks %d'):format(
        promptSeen.kind and ('showing "' .. promptSeen.kind .. '"') or 'not showing',
        tostring(jumpKey() or '(UNBOUND -- Settings > Key Bindings)'),
        promptSeen.sends, promptSeen.draws, promptSeen.fallbacks))
    -- THE LINE THAT SEPARATES "LATE" FROM "NEVER", which the counters above
    -- cannot: they are lifetime totals, so a `draws` earned two matches ago
    -- reads exactly like a browser that came up on this flight. See the stamps'
    -- own note by promptPage for what each of the three answers means.
    if not promptCreatedAt then
        print('  browser not asked for yet (no warmup or bus state seen this session)')
    elseif promptReadyAt then
        print(('  browser ready %dms after it was created')
            :format(promptReadyAt - promptCreatedAt))
    else
        print(('  browser NEVER READY -- %dms since it was created')
            :format(GetGameTimer() - promptCreatedAt))
    end
    if not route then print('  route  none') return end
    print(('  route  %d pts  %d crumbs  legs %s  timed %s')
        :format(#route.points, crumbCount,
                route.legs and table.concat(route.legs, '-') or '?',
                tostring(route.timed)))
    if not route.timed then print('  (preview only -- departs at BUS)') return end
    local now = BR.Clock.now()
    print(('  tStart %+.1fs  doors %+.1fs  tEnd %+.1fs  (relative to now)')
        :format((route.tStart - now) / 1000,
                (route.jumpFrom - now) / 1000, (route.tEnd - now) / 1000))
    local x, y, z = BR.PathPosAt(route.points, now)
    print(('  route pos now   %.0f, %.0f, %.0f'):format(x, y, z))
    if bus and isTrue(DoesEntityExist(bus)) then
        local c = GetEntityCoords(bus)
        print(('  bus entity pos  %.0f, %.0f, %.0f'):format(c.x, c.y, c.z))
        Citizen.SetTimeout(1000, function()
            if bus and isTrue(DoesEntityExist(bus)) then
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
