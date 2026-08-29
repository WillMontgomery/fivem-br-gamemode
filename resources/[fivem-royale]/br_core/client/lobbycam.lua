-- The lobby camera.
--
-- The lobby is a character shot: your ped, standing on the authored spot,
-- looked at from six feet in front. It is the frame the ped picker and the
-- locker will live in, so it is built as a camera that can be re-aimed rather
-- than as a one-off.
--
-- LOCKED, DELIBERATELY. A lobby camera the player can swing is a lobby camera
-- pointed at the sky within ten seconds, and there is nothing to look at out
-- there -- the menu is the content. Freeing it is a decision for the locker,
-- where dragging to turn the ped is the interaction, and even there the ped
-- turns rather than the camera.
--
-- OWNED BY MY PLAYER STATE, not by the match state. A player who left a match
-- is in the lobby while everyone else is mid-flight; a player in warmup is not
-- in the lobby even though the match has not started. The same distinction
-- every other per-frame rule in this project makes, and for the same reason:
-- match state is about the round, player state is about me.
--
-- THE TEARDOWN IS THE DANGEROUS HALF. A script camera left rendering shows
-- whatever it is pointed at forever, with no error and nothing in any log --
-- which after a teleport is usually the inside of the world. Every exit path
-- goes through stop(), including the resource stopping, and brunstuck
-- destroys all cameras unconditionally as the manual escape.
--
-- ── THIS CAMERA MOVES NOW (owner, 2026-08-29) ─────────────────────────────
--
-- IT USED TO BE THE ONLY CAMERA IN THE PROJECT WITH NO MOVE IN IT -- no
-- SetCamCoord, no interpolation, one CreateCamWithParams on a fixed mark and
-- nothing after it. A memory audit on 2026-08-28 leaned on exactly that, so
-- this note exists rather than a stale comment somewhere else: the lobby
-- ENTRANCE (BR.LobbyCam.glide, driven by client/lobbyped.lua) now flies the
-- shot along an authored path before it settles on the lobby frame.
--
-- WHAT HAS NOT CHANGED IS THE LOCK. Once the entrance is over the camera is
-- as fixed as it ever was, and nothing the player does moves it -- the flight
-- is choreography with a beginning and an end, not a freed camera. And the
-- moves are ENGINE INTERPOLATIONS (SetCamActiveWithInterp between two static
-- cameras) rather than per-frame coordinate writes, so there is still no
-- SetCamCoord on a rendering camera anywhere in this file.

BR = BR or {}
BR.LobbyCam = {}

--- IN LUA 0 IS TRUTHY, AND A FIVEM NATIVE DECLARED BOOL MAY ANSWER 1 RATHER
--- THAN true. DoesCamExist and IsCamInterpolating are both BOOL and both are
--- read below on paths that decide whether a camera is destroyed -- the "0
--- reads as yes" direction here leaks a camera, the other direction destroys
--- one mid-interpolation and drops the view to the gameplay camera.
--- @param v any
--- @return boolean
local function isTrue(v)
    return v ~= nil and v ~= false and v ~= 0
end

-- The camera that is rendering, or becoming the one that renders.
local cam = nil

-- THE ONE BEING INTERPOLATED AWAY FROM, held until the move is over.
--
-- SetCamActiveWithInterp blends between two LIVE cameras, so destroying the
-- source the moment the move starts ends the move -- the view snaps to the
-- destination on the next frame, which is the exact opposite of what an
-- interpolation is for. It is swept by the next call in here rather than by a
-- timer, so a sequence that was abandoned halfway cannot leave one behind.
local retiring = nil

--- Where the camera sits and what it looks at, for a ped at (x, y, z) facing
--- `heading`.
---
--- GTA heading -> unit vectors, and getting these backwards is the classic
--- way to end up filming the back of someone's head:
---   forward = (-sin h,  cos h)
---   right   = ( cos h,  sin h)
---
--- The camera is placed along FORWARD (in front of the ped, looking back at
--- them) and the aim point is slid along RIGHT, which pushes the ped to the
--- LEFT of the camera's own axis -- and therefore to the RIGHT of the screen,
--- because the camera is turned 180 degrees from the ped. That is the whole
--- trick behind the ped standing in the gap the menu leaves.
--- @return number, number, number, number, number, number
local function frame(x, y, z, heading)
    local C = BR.Config.Match.lobbyCam
    local rad = math.rad(heading or 0.0)
    local fx, fy = -math.sin(rad), math.cos(rad)
    local rx, ry =  math.cos(rad), math.sin(rad)

    local cx = x + fx * C.dist + rx * 0.0
    local cy = y + fy * C.dist + ry * 0.0
    local cz = z + C.height

    local ax = x + rx * C.offset
    local ay = y + ry * C.offset
    local az = z + C.aim

    return cx, cy, cz, ax, ay, az
end

--- Destroy the camera a finished interpolation was moving away from.
---
--- Called at the top of every entry point below rather than on a timer: the
--- entrance can be abandoned at any moment (a player readying up mid-flight),
--- and a teardown that only ran when a move completed normally is exactly the
--- shape of leak this file's header is about.
local function sweepRetired()
    if not retiring then return end
    if isTrue(IsCamInterpolating(cam)) then return end
    if isTrue(DoesCamExist(retiring)) then DestroyCam(retiring, true) end
    retiring = nil
end

--- Build one static camera at an explicit position and rotation.
--- @return number|nil
local function makeCam(x, y, z, pitch, heading, fov)
    local c = CreateCamWithParams('DEFAULT_SCRIPTED_CAMERA',
        x + 0.0, y + 0.0, z + 0.0,
        pitch + 0.0, 0.0, heading + 0.0,
        fov or BR.Config.Match.lobbyCam.fov, false, 0)
    if not c or c == -1 then return nil end
    return c
end

--- Where the ordinary lobby shot sits, as a node the flight can land on.
--- @return number, number, number, number, number, number
function BR.LobbyCam.lobbyFrame()
    local p = BR.Config.Match.lobbyPos
    return frame(p.x, p.y, p.z, p.heading)
end

--- The downward tilt that makes a node LOOK AT the lobby mark.
---
--- The owner surveyed the flight's nodes as positions and HEADINGS -- which is
--- what a coordinate tool reports and is genuinely half the answer. A camera 99
--- metres up with a pitch of zero is pointed at the horizon, so the shot he
--- described would have been of the sky. Config may pin `pitch` per node; this
--- is what it falls back to.
--- @return number  degrees, negative when looking down
function BR.LobbyCam.pitchToward(x, y, z, tx, ty, tz)
    local dx, dy, dz = tx - x, ty - y, tz - z
    local flat = math.sqrt(dx * dx + dy * dy)
    if flat < 0.01 then return dz > 0 and 89.0 or -89.0 end
    return math.deg(math.atan(dz, flat))
end

--- Raise the camera on the authored lobby spot. Idempotent.
function BR.LobbyCam.start()
    sweepRetired()
    if cam and isTrue(DoesCamExist(cam)) then return end

    local cx, cy, cz, ax, ay, az = BR.LobbyCam.lobbyFrame()

    cam = CreateCamWithParams('DEFAULT_SCRIPTED_CAMERA',
        cx, cy, cz, 0.0, 0.0, 0.0, BR.Config.Match.lobbyCam.fov, false, 0)
    if not cam or cam == -1 then
        cam = nil
        print('[br_core] lobby camera could not be created')
        return
    end

    PointCamAtCoord(cam, ax, ay, az)
    SetCamActive(cam, true)

    -- No interpolation on the way IN: the lobby is arrived at from behind a
    -- fade or straight off the loading screen, so there is nothing to blend
    -- from and a 'lerp from wherever the gameplay camera was' reads as a
    -- swoop through the island.
    RenderScriptCams(true, false, 0, true, true)

    print('[br_core] lobby camera up')
end

--- Put the camera at one authored node, with no blend. The entrance's FIRST
--- shot: it is raised under a black screen, so there is nothing to blend from.
--- @param node table  { x, y, z, heading, pitch? }
--- @return boolean
function BR.LobbyCam.place(node)
    if not node then return false end
    sweepRetired()

    local p = BR.Config.Match.lobbyPos
    local pitch = node.pitch
        or BR.LobbyCam.pitchToward(node.x, node.y, node.z, p.x, p.y, p.z)

    local c = makeCam(node.x, node.y, node.z, pitch, node.heading or 0.0, node.fov)
    if not c then
        print('[br_core] lobby camera node could not be created')
        return false
    end

    local old = cam
    cam = c
    SetCamActive(cam, true)
    RenderScriptCams(true, false, 0, true, true)
    if old and isTrue(DoesCamExist(old)) then DestroyCam(old, true) end
    return true
end

-- ═══ EASE IS OFF BY DEFAULT, AND THAT IS THE FIX FOR THE STUTTER ═══
--
-- SET_CAM_ACTIVE_WITH_INTERP's last two arguments are easeLocation and
-- easeRotation, and passing 1 for them is an ease-IN-and-OUT: the camera
-- accelerates away from the source and DECELERATES TO A STANDSTILL at the
-- destination. One interpolation of those is a nice single move. A CHAIN of
-- them is a camera that stops dead at every node -- which is exactly what the
-- owner reported on 2026-08-29 ("once the camera reaches each point, there's a
-- pause ... it should be smooth movement all the way start to finish with no
-- pace change either").
--
-- So every move that is a SEGMENT OF A LONGER FLIGHT passes 0: constant
-- velocity, and the next segment picks the camera up at the speed the last one
-- left it. Easing is kept for moves that really are one self-contained move --
-- the settle in BR.LobbyPed.stop's abandoned flight -- where starting and
-- ending at rest is what it should look like.
--- @param ease boolean|nil  true to ease in and out; nil/false for constant pace
--- @return number
local function easeFlag(ease)
    return ease == true and 1 or 0
end

--- Move smoothly from wherever the camera is to a node, over `ms`.
---
--- ENGINE INTERPOLATION, NOT A PER-FRAME WRITE. Two static cameras and
--- SetCamActiveWithInterp between them: the engine blends both the position and
--- the rotation, it survives a frame the script misses, and it leaves nothing
--- to unwind if the sequence is abandoned mid-move -- the destination camera is
--- already `cam`, so stop() destroys it like any other.
--- @param node table    { x, y, z, heading, pitch? }
--- @param ms number
--- @param ease boolean|nil  see easeFlag; default is constant pace
--- @return boolean
function BR.LobbyCam.glide(node, ms, ease)
    if not node then return false end
    sweepRetired()

    -- Nothing to blend FROM is not an error, it is the first shot.
    if not (cam and isTrue(DoesCamExist(cam))) then
        return BR.LobbyCam.place(node)
    end

    local p = BR.Config.Match.lobbyPos
    local pitch = node.pitch
        or BR.LobbyCam.pitchToward(node.x, node.y, node.z, p.x, p.y, p.z)

    local dest = makeCam(node.x, node.y, node.z, pitch, node.heading or 0.0, node.fov)
    if not dest then
        print('[br_core] lobby camera move could not be created')
        return false
    end

    retiring = cam
    cam = dest
    SetCamActiveWithInterp(cam, retiring, math.max(1, math.floor(ms or 1000)),
        easeFlag(ease), easeFlag(ease))
    RenderScriptCams(true, false, 0, true, true)
    return true
end

--- The last move of the flight: land on the ordinary lobby frame.
---
--- Aimed with PointCamAtCoord like BR.LobbyCam.start, so the shot the entrance
--- ends on is the SAME shot the locker and the ped picker were composed
--- against -- not an approximation of it built out of a heading.
--- @param ms number
--- @param ease boolean|nil  see easeFlag; default is constant pace
--- @return boolean
function BR.LobbyCam.glideHome(ms, ease)
    sweepRetired()

    local cx, cy, cz, ax, ay, az = BR.LobbyCam.lobbyFrame()
    local dest = CreateCamWithParams('DEFAULT_SCRIPTED_CAMERA',
        cx, cy, cz, 0.0, 0.0, 0.0, BR.Config.Match.lobbyCam.fov, false, 0)
    if not dest or dest == -1 then
        print('[br_core] lobby camera could not land')
        return false
    end
    PointCamAtCoord(dest, ax, ay, az)

    if cam and isTrue(DoesCamExist(cam)) then
        retiring = cam
        cam = dest
        SetCamActiveWithInterp(cam, retiring, math.max(1, math.floor(ms or 1000)),
            easeFlag(ease), easeFlag(ease))
    else
        cam = dest
        SetCamActive(cam, true)
    end
    RenderScriptCams(true, false, 0, true, true)
    return true
end

--- Hand the view back to the game. Safe to call when nothing is up.
---
--- ALWAYS CALLED UNDER A FADE by the transition into warmup: releasing the
--- camera in the open snaps the view from a portrait to a third-person
--- gameplay shot in one frame, which reads as a glitch rather than as the
--- match starting.
function BR.LobbyCam.stop()
    -- THE RETIRING CAMERA GOES EVEN IF THE MAIN ONE IS ALREADY GONE, which is
    -- why this is above the early return rather than beside the destroy below.
    -- A flight abandoned mid-move has two live cameras, and the one that is
    -- NOT rendering is the one nothing else would ever come back for.
    if retiring then
        if isTrue(DoesCamExist(retiring)) then DestroyCam(retiring, true) end
        retiring = nil
    end
    if not cam then return end
    RenderScriptCams(false, false, 0, true, true)
    if isTrue(DoesCamExist(cam)) then DestroyCam(cam, true) end
    cam = nil
    print('[br_core] lobby camera down')
end

--- @return boolean
---
--- AND IT ANSWERS A BOOLEAN, which it did not before. DoesCamExist is a BOOL
--- native and may hand back 1/0 -- so this used to RETURN a number, and every
--- `if BR.LobbyCam.active() then` in the project was reading a raw native at one
--- remove: `0` is truthy in Lua, so a camera that does not exist read as one
--- that does. The follow tick's whole job is that comparison.
function BR.LobbyCam.active()
    return cam ~= nil and isTrue(DoesCamExist(cam))
end

--- Destroy a finished move's source camera. Public so the follow tick can
--- assert it; see sweepRetired above for why it is not on a timer.
function BR.LobbyCam.sweep()
    sweepRetired()
end

-- The camera follows MY state, and it is asserted on a tick rather than on a
-- transition. Every road into the lobby has to raise it -- the first spawn,
-- the trip home after a match, a brforce cleanup, br_core restarting under a
-- player who is already standing there -- and enumerating those was how the
-- old radar rule kept missing one. Asking "should it be up? is it up?" ten
-- times a second is two native calls and cannot miss a path.
--
-- It does NOT raise the camera while a trip is in progress: BR.Spawn.toLobby
-- is mid-teleport with the screen black, and pointing a camera at coordinates
-- the ped has not reached yet films empty island.
BR.Loop.register(BR.Loop.TICK, 'lobbycam.follow', function()
    -- FIRST, AND BEFORE EVERY EARLY RETURN BELOW. A finished interpolation
    -- leaves its source camera alive, and the paths that would normally sweep
    -- it are exactly the paths an abandoned flight does not take. Two native
    -- calls, ten times a second, and no move can leak a camera on any road.
    BR.LobbyCam.sweep()

    -- A TRIP OWNS THE TEARDOWN, AND THIS TICK MUST KEEP ITS HANDS OFF.
    --
    -- This used to stop the camera as soon as the state stopped being LOBBY,
    -- which is the same tick readying up sets it -- so the view snapped back
    -- to the gameplay camera INSTANTLY, and the player then watched the
    -- teleport happen before the fade they were supposed to be behind (user,
    -- 2026-08-09: "the player teleports before a fade to black"). The trip
    -- fades first and drops the camera under the black; all this has to do is
    -- not race it.
    if BR.Spawn.traveling then return end

    -- AND A SPECTATE CAMERA OWNS THE VIEW WHILE IT IS UP (#192).
    --
    -- This tick asserts the lobby shot ten times a second precisely so no path
    -- can miss it -- which makes it the thing that would quietly take the screen
    -- back from an admin spectating from the lobby. There is only ever one
    -- rendered camera: whichever called RenderScriptCams last wins, and at 10 Hz
    -- against a per-frame loop that is this one. So the answer is not to race
    -- it, it is to stand down: an admin standing on the lobby pad watching
    -- somebody else's match is in the lobby AND is not looking at it.
    --
    -- Guarded rather than assumed, because client/spectate.lua loads after this
    -- file -- the field is read at call time, so the guard only matters for the
    -- ticks between the two resources' load.
    if BR.Spectate and BR.Spectate.active() then
        if BR.LobbyCam.active() then BR.LobbyCam.stop() end
        return
    end

    -- AND THE ENTRANCE OWNS THE CAMERA WHILE IT IS FLYING IT.
    --
    -- Same argument as the trip and the spectate session above, and the same
    -- shape: this tick asserts a FIXED shot ten times a second, so left
    -- unguarded it would drag the camera back to the lobby mark in the middle
    -- of every move client/lobbyped.lua made. It stands down rather than
    -- races -- and because the guard is "is the entrance running", a sequence
    -- that is abandoned, errors or simply finishes hands the camera straight
    -- back on the next tick with no handover to get wrong.
    if BR.LobbyPed and BR.LobbyPed.entering() then return end

    local want = BR.State.me.state == BR.PlayerState.LOBBY

    if want and not BR.LobbyCam.active() then
        BR.LobbyCam.start()
    elseif not want and BR.LobbyCam.active() then
        -- The uncoreographed path: an admin force, a resource restart, a
        -- state change nobody fades for. Better an abrupt cut than a camera
        -- left pointing at an empty hillside for the rest of the match.
        BR.LobbyCam.stop()
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    BR.LobbyCam.stop()
end)

-- Re-frame from the console after editing the numbers, without a restart.
RegisterCommand('brlobbycam', function(_, args)
    local C = BR.Config.Match.lobbyCam
    local key, value = args[1], tonumber(args[2])
    if key and value and C[key] ~= nil then
        C[key] = value
        print(('[br_core] lobbyCam.%s = %.2f'):format(key, value))
        BR.LobbyCam.stop()
        BR.LobbyCam.start()
        return
    end
    print('=== lobby camera ===')
    for _, k in ipairs({ 'dist', 'height', 'aim', 'offset', 'fov' }) do
        print(('  %-7s %.2f'):format(k, C[k]))
    end
    print(('  active  %s'):format(tostring(BR.LobbyCam.active())))
    print('  usage: brlobbycam <dist|height|aim|offset|fov> <number>')
end, false)
