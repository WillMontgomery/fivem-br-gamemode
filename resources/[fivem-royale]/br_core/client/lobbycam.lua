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

BR = BR or {}
BR.LobbyCam = {}

local cam = nil

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

--- Raise the camera on the authored lobby spot. Idempotent.
function BR.LobbyCam.start()
    if cam and DoesCamExist(cam) then return end

    local p = BR.Config.Match.lobbyPos
    local cx, cy, cz, ax, ay, az = frame(p.x, p.y, p.z, p.heading)

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

--- Hand the view back to the game. Safe to call when nothing is up.
---
--- ALWAYS CALLED UNDER A FADE by the transition into warmup: releasing the
--- camera in the open snaps the view from a portrait to a third-person
--- gameplay shot in one frame, which reads as a glitch rather than as the
--- match starting.
function BR.LobbyCam.stop()
    if not cam then return end
    RenderScriptCams(false, false, 0, true, true)
    if DoesCamExist(cam) then DestroyCam(cam, true) end
    cam = nil
    print('[br_core] lobby camera down')
end

--- @return boolean
function BR.LobbyCam.active()
    return cam ~= nil and DoesCamExist(cam)
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
    local want = BR.State.me.state == BR.PlayerState.LOBBY
        and not BR.Spawn.traveling

    if want and not BR.LobbyCam.active() then
        BR.LobbyCam.start()
    elseif not want and BR.LobbyCam.active() then
        -- Not under a fade: this is the path for a state change nobody
        -- choreographed (an admin force, a resource restart). The warmup
        -- transition takes the camera down itself, under black, before the
        -- state ever gets here.
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
