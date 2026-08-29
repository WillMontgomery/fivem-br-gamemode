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

--- Destroy the retiring camera NOW, whatever the current move is doing.
---
--- CALLED BY EVERY PATH THAT IS ABOUT TO OVERWRITE `retiring`, which is every
--- path that starts a new move. sweepRetired above DEFERS while the current
--- interpolation is still running -- correct for the follow tick asking "is
--- there anything to tidy", and a leak here, because the write that follows is
--- the last reference to it. A three-move flight got away with that; a
--- resampled one is two dozen chances to leak a camera nothing will ever come
--- back for, silently, because a camera that is not rendering looks like
--- nothing at all until the count matters.
---
--- SAFE FOR THE SAME REASON EVERY TIME: the camera being destroyed is not part
--- of the blend that is about to start. That blend runs from `cam`.
local function dropRetiring()
    if not retiring then return end
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

-- ---------------------------------------------------------------------------
-- The flight, as a curve
-- ---------------------------------------------------------------------------
--
-- ═══ WHY THIS IS A SPLINE RESAMPLED INTO MANY SHORT MOVES ═══
--
-- Owner, 2026-08-29, four separate complaints about one flight: "The speed is
-- too slow at the beginning and too fast at the end. Over the course of the
-- final move the camera should slow down exponentially. Also the camera facing
-- direction changes too suddenly - it should be much smoother. When the camera
-- gets to a position and changes direction that's also too sudden. I feel like
-- we need more steps in this process which will smooth out the corners into
-- curves."
--
-- SET_CAM_SPLINE_* IS THE ENGINE'S OWN ANSWER TO THE LAST OF THOSE and it was
-- looked at seriously. It is not used, and the reason is not that it would not
-- work -- it is that it would replace the whole of the mechanism below, which
-- is already debugged, with natives whose behaviour on the paths that actually
-- bite here cannot be checked from this machine: what a spline camera does when
-- a sequence is ABANDONED mid-phase, whether the retiring-camera sweep still
-- applies, and whether SET_CAM_SPLINE_PHASE may be driven per frame on a
-- rendering camera (UNVERIFIED -- documented as a setter, not tried here).
-- There is no SET_CAM_SPLINE call anywhere in this project to copy from, so it
-- would be new platform ground on a playtest round that already has four other
-- changes in it. Resampling gets the same picture out of the natives this file
-- has already proved. Worth revisiting on a round of its own.
--
-- SO: a Catmull-Rom curve through the authored nodes, cut into `camSteps`
-- equal-DURATION moves whose LENGTHS shrink exponentially. Three properties
-- fall out of that and they are the four complaints:
--
--   * the curve has no corners -- the camera passes THROUGH each authored node
--     rather than arriving at it and turning;
--   * every step is an un-eased interpolation, so there is still no stop
--     anywhere in the flight (see easeFlag) -- the deceleration is in the
--     GEOMETRY, not in the engine's curve;
--   * the step lengths follow e^-k, so the camera is fastest at the first
--     frame and is still slowing down, exponentially, through the last move.

--- One Catmull-Rom sample. `p0`..`p3` are four consecutive control points and
--- `t` runs 0..1 across the middle two.
---
--- The endpoints are handled by DUPLICATING the first and last control points
--- rather than by inventing tangents: a phantom point in front of the first
--- node would swing the camera the wrong way out of a shot that is raised
--- under a black screen and has to be exactly where the survey put it.
local function crSample(p0, p1, p2, p3, t, key)
    local a, b, c, d = p0[key], p1[key], p2[key], p3[key]
    local t2 = t * t
    local t3 = t2 * t
    return 0.5 * ((2.0 * b)
        + (-a + c) * t
        + (2.0 * a - 5.0 * b + 4.0 * c - d) * t2
        + (-a + 3.0 * b - 3.0 * c + d) * t3)
end

--- Walk a control-point list as one curve, parametrised 0..1 over the whole
--- thing, and answer the point at `u`.
--- @param pts table  list of { x, y, z }, at least two
--- @return number, number, number
local function curveAt(pts, u)
    local segs = #pts - 1
    if segs < 1 then return pts[1].x, pts[1].y, pts[1].z end
    if u <= 0.0 then return pts[1].x, pts[1].y, pts[1].z end
    if u >= 1.0 then return pts[#pts].x, pts[#pts].y, pts[#pts].z end

    local scaled = u * segs
    local i = math.floor(scaled) + 1
    if i > segs then i = segs end
    local t = scaled - (i - 1)

    local p0 = pts[math.max(1, i - 1)]
    local p1 = pts[i]
    local p2 = pts[math.min(#pts, i + 1)]
    local p3 = pts[math.min(#pts, i + 2)]
    return crSample(p0, p1, p2, p3, t, 'x'),
           crSample(p0, p1, p2, p3, t, 'y'),
           crSample(p0, p1, p2, p3, t, 'z')
end

-- How finely the curve is measured before it is cut into steps. Not a knob:
-- it only has to be much larger than camSteps for the arc-length mapping to be
-- accurate, and 240 samples over a 350m path is a metre and a half.
local ARC_SAMPLES = 240

--- The pitch and GTA heading that make a camera at (x,y,z) look at (tx,ty,tz).
---
--- BOTH, TOGETHER, AND FROM THE AIM POINT -- which is the whole of the "facing
--- changes too suddenly" fix. A camera whose rotation comes from an authored
--- per-node heading turns whenever the author's headings differ; one whose
--- rotation is derived from where it is LOOKING turns only as fast as the thing
--- it is looking at moves, and the aim point here barely moves at all.
--- @return number pitch, number heading
function BR.LobbyCam.aimAt(x, y, z, tx, ty, tz)
    return BR.LobbyCam.pitchToward(x, y, z, tx, ty, tz),
           BR.GtaHeading(BR.Bearing(x, y, tx, ty))
end

--- How far along the flight the camera should be after fraction `s` of its
--- time, 0..1.
---
--- (1 - e^-ks) / (1 - e^-k). Its derivative is proportional to e^-ks, so the
--- SPEED decays exponentially from the first frame to the last -- "too slow at
--- the beginning and too fast at the end" and "over the course of the final
--- move the camera should slow down exponentially" are the same curve read at
--- its two ends. k = 0 degenerates to the flat pace this replaced.
--- @param s number  0..1, fraction of the flight's DURATION
--- @param k number  decay; 0 is a flat pace
--- @return number   0..1, fraction of the flight's LENGTH
function BR.LobbyCam.pace(s, k)
    if s <= 0.0 then return 0.0 end
    if s >= 1.0 then return 1.0 end
    k = k or 0.0
    if k <= 0.0001 then return s end
    return (1.0 - math.exp(-k * s)) / (1.0 - math.exp(-k))
end

--- The whole flight, as a list of camera placements.
---
--- Entry 1 is where the shot is RAISED (no move into it -- it goes up under a
--- black screen). Entries 2..n are the moves, in order, each one an equal slice
--- of the flight's duration. The LAST entry is exactly BR.LobbyCam.lobbyFrame,
--- position and aim both, because the shot the entrance ends on has to be the
--- same shot the locker was composed against.
---
--- Pure: no natives, no state. That is deliberate -- it is the half of this
--- feature that can be asserted in a test rather than looked at.
--- SECOND RETURN: where each authored control point sits along the flight, as
--- a fraction of its LENGTH. The wave is cued on the camera reaching its
--- second-to-last position (owner, 2026-08-29) and after the resampling there
--- is no longer a move that ends there -- so the cue is "the flight has got
--- this far", and this is what that number is measured against.
--- @param nodes table   the authored camPath
--- @param steps number  how many moves to cut the flight into
--- @param decay number   see BR.LobbyCam.pace
--- @return table plan  { { x, y, z, pitch, heading, ax, ay, az, at }, ... }
--- @return table marks  one 0..1 per control point, the lobby frame included
function BR.LobbyCam.flightPlan(nodes, steps, decay)
    nodes = nodes or {}
    if #nodes == 0 then return {} end
    steps = math.max(1, math.floor(steps or 24))

    local p = BR.Config.Match.lobbyPos
    local hx, hy, hz, aimX, aimY, aimZ = BR.LobbyCam.lobbyFrame()

    -- The control points: the authored nodes, then the lobby frame itself.
    local pts = {}
    for _, n in ipairs(nodes) do
        pts[#pts + 1] = { x = n.x + 0.0, y = n.y + 0.0, z = n.z + 0.0 }
    end
    pts[#pts + 1] = { x = hx, y = hy, z = hz }

    -- Measure the curve so the steps can be cut by LENGTH rather than by
    -- parameter: an evenly-parametrised Catmull-Rom runs fast through straight
    -- stretches and slow through bends, which is a pace change nobody asked for
    -- sitting underneath the one that was.
    local us, cum = { 0.0 }, { 0.0 }
    local px, py, pz = curveAt(pts, 0.0)
    for i = 1, ARC_SAMPLES do
        local u = i / ARC_SAMPLES
        local x, y, z = curveAt(pts, u)
        us[#us + 1]  = u
        cum[#cum + 1] = cum[#cum] + BR.Dist3(px, py, pz, x, y, z)
        px, py, pz = x, y, z
    end
    local total = cum[#cum]

    --- The curve parameter at arc-length fraction `f`.
    local function paramAt(f)
        if total <= 0.0 then return f end
        local want = f * total
        for i = 2, #cum do
            if cum[i] >= want then
                local span = cum[i] - cum[i - 1]
                local t = span > 0.0 and (want - cum[i - 1]) / span or 0.0
                return us[i - 1] + (us[i] - us[i - 1]) * t
            end
        end
        return 1.0
    end

    -- THE AIM POINT MOVES, AND IT MOVES ALMOST NOWHERE. It starts on the lobby
    -- mark -- the only thing worth framing from ninety-nine metres up -- and
    -- slides onto the locker's exact aim as the camera lands. Under a metre of
    -- travel over the whole flight, which is why the rotation reads as one slow
    -- continuous turn instead of three.
    local out = {}
    for j = 0, steps do
        local s = j / steps
        local f = BR.LobbyCam.pace(s, decay)
        local u = paramAt(f)
        local x, y, z = curveAt(pts, u)

        local ax = p.x + (aimX - p.x) * f
        local ay = p.y + (aimY - p.y) * f
        local az = p.z + (aimZ - p.z) * f

        -- The last one is the lobby frame EXACTLY, not the curve's opinion of
        -- where the lobby frame is: floating point along 350 metres of spline
        -- is not something the locker's composition should depend on.
        if j == steps then
            x, y, z = hx, hy, hz
            ax, ay, az = aimX, aimY, aimZ
        end

        local pitch, heading = BR.LobbyCam.aimAt(x, y, z, ax, ay, az)
        out[#out + 1] = { x = x, y = y, z = z, pitch = pitch, heading = heading,
                          ax = ax, ay = ay, az = az, at = f }
    end

    -- Where each control point fell along the measured curve. The first is
    -- always 0 and the last always 1; the ones between are read straight off
    -- the cumulative table at the parameter that control point sits at.
    local marks, segs = {}, #pts - 1
    for i = 1, #pts do
        if i == 1 then
            marks[i] = 0.0
        elseif i == #pts then
            marks[i] = 1.0
        else
            local u = (i - 1) / segs
            local k = math.floor(u * ARC_SAMPLES) + 1
            if k > #cum then k = #cum end
            marks[i] = total > 0.0 and (cum[k] / total) or (u)
        end
    end
    return out, marks
end

--- Put the camera at one plan entry with no blend. The flight's first shot.
--- @param e table  an entry from BR.LobbyCam.flightPlan
--- @return boolean
function BR.LobbyCam.placeAt(e)
    if not e then return false end
    sweepRetired()

    local c = makeCam(e.x, e.y, e.z, e.pitch, e.heading)
    if not c then
        print('[br_core] lobby camera node could not be created')
        return false
    end

    dropRetiring()
    local old = cam
    cam = c
    SetCamActive(cam, true)
    RenderScriptCams(true, false, 0, true, true)
    if old and isTrue(DoesCamExist(old)) then DestroyCam(old, true) end
    return true
end

--- Move to one plan entry over `ms`, at a constant pace and with no ease.
--- @param e table
--- @param ms number
--- @return boolean
function BR.LobbyCam.glideTo(e, ms)
    if not e then return false end
    sweepRetired()

    if not (cam and isTrue(DoesCamExist(cam))) then
        return BR.LobbyCam.placeAt(e)
    end

    local dest = makeCam(e.x, e.y, e.z, e.pitch, e.heading)
    if not dest then
        print('[br_core] lobby camera move could not be created')
        return false
    end

    dropRetiring()
    retiring = cam
    cam = dest
    -- ZERO, ALWAYS. See easeFlag: an eased step arrives at rest, and this is a
    -- step of a longer flight. The slowing down the owner asked for is in how
    -- SHORT the last steps are, not in how they are interpolated.
    SetCamActiveWithInterp(cam, retiring, math.max(1, math.floor(ms or 1000)), 0, 0)
    RenderScriptCams(true, false, 0, true, true)
    return true
end

--- Where the rendering camera is, or nil.
---
--- Read by client/lobbyped.lua so a winning ped can turn to face the camera
--- before it flips -- "please make sure the flip happens facing the camera"
--- (owner, 2026-08-29). Asked of the engine rather than recomputed from the
--- plan, because the plan says where the camera is HEADED and the interpolation
--- says where it actually is.
--- @return number|nil, number|nil, number|nil
function BR.LobbyCam.pos()
    if not (cam and isTrue(DoesCamExist(cam))) then return nil end
    if not GetCamCoord then return nil end
    local c = GetCamCoord(cam)
    if not c then return nil end
    return c.x, c.y, c.z
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
-- So every move that is a STEP OF A LONGER FLIGHT passes 0: constant velocity,
-- and the next step picks the camera up at the speed the last one left it (see
-- BR.LobbyCam.glideTo, which hardcodes 0 for exactly that reason). Easing is
-- kept for moves that really are one self-contained move -- the settle in
-- BR.LobbyPed.stop's abandoned flight -- where starting and ending at rest is
-- what it should look like, and glideHome below is the only caller left.
--- @param ease boolean|nil  true to ease in and out; nil/false for constant pace
--- @return number
local function easeFlag(ease)
    return ease == true and 1 or 0
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
        dropRetiring()
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
