-- The spectator camera.
--
-- ONE CAMERA, TWO CALLERS. A dead player watching their squad and an admin
-- watching a suspect are the same shot; they differ only in WHO the server lets
-- them point it at, and that decision is entirely server-side
-- (br_core/server/spectate.lua, br_lib/shared/spectate_solve.lua). Nothing in
-- this file chooses a target, and nothing in it may: the client is handed one
-- server id at a time and never sees a candidate list, because a client-side
-- filter is not a privacy boundary.
--
-- ═══ IT IS THE BUS CAMERA, DELIBERATELY ═══
--
-- client/bus.lua:252 already records why an attached camera is wrong -- it welds
-- in place and kills free look -- so this is the same idiom rather than a second
-- one: an UNATTACHED DEFAULT_SCRIPTED_CAMERA, repositioned every frame around a
-- point, on the same two control normals. bus.lua orbits a plane it computes the
-- position of; this orbits a player the server reports the position of. Same
-- shape, same teardown, same escape hatch (/brunstuck destroys all cams).
--
-- ONE DIFFERENCE, AND IT IS FORCED: the yaw is ABSOLUTE rather than relative to
-- the subject's heading. The bus knows its own heading from the route it is
-- flying; a spectate target may not be streamed in at all, so their heading is
-- unknowable half the time -- and a camera that re-based itself the moment they
-- streamed in would swing the whole view for no reason the player could see.
--
-- ═══ AND IT IS NOT ON THE FOCUS STACK ═══
--
-- br_ui/client/nui.lua's pushFocus carries a note about a screen that could
-- never be raised again once buried, and warns that the file has shipped that
-- class of mistake twice. The lesson taken here is the one that avoids a third:
-- DO NOT JOIN A STACK YOU DO NOT NEED. Spectating draws no page and wants no
-- cursor -- and every screen on that stack takes the keyboard (BR.FocusKeepsInput
-- lists only the inventory), so a `pushFocus('spectate')` would silently kill the
-- arrow keys that ARE the feature and leave a screen on the stack that nothing
-- pops. The pause menu still opens over the camera, and keybinds.lua's
-- uiOwnsKeyboard gate already stops the arrows firing underneath it, for free.
--
-- The one focus interaction that IS real is handled below: an admin starts
-- spectating from the console, which is a full-page focus screen, and it has to
-- get out of the way.

BR = BR or {}
BR.Spectate = {}

--- The running session, or nil. `{ targetSrc, name, admin }`
local session = nil

--- Where the server last said the target is, and where the camera has eased to.
--- Two points rather than one because the feed is 4 Hz and the camera is not: a
--- shot that teleported four times a second was the first thing to fix.
local want, shown = nil, nil

local cam = nil
local camYaw, camPitch = 0.0, -8.0

--- Did a shape test hit anything?
---
--- `hit == 1` ALONE IS NOT THE QUESTION. A FiveM native declared BOOL can hand
--- Lua a number or a boolean depending on the build, and IN LUA `0` IS TRUTHY --
--- this repo has shipped that bug four times. client/dbno.lua carries the same
--- normaliser over the same native for the same camera-through-a-wall reason.
--- @param v any
--- @return boolean
local function didHit(v)
    return v == 1 or v == true
end

--- Is a session running? Read by client/lobbycam.lua, which must not raise the
--- lobby shot over this one, and by client/voice.lua, where it is the whole of
--- the voice rule: BR.Voice.mode() reads it and answers 'off' while it is true,
--- so a spectator neither transmits nor hears for the length of the session and
--- is back on their saved preference the moment it ends.
---
--- NOTHING IN THIS FILE TELLS VOICE ANYTHING, AND THAT IS THE DESIGN. There is
--- no "start" call to pair with a "stop" call and therefore no exit path that
--- can forget to make one -- not the pause-menu stop, not the match ending, not
--- a disconnect, not a resource restart. voice.lua asks this function; a
--- session that is over answers false, and the preference it never overwrote is
--- simply what it was.
--- @return boolean
function BR.Spectate.active()
    return session ~= nil
end

--- WHO is being watched, or nil.
---
--- EXISTS SO THE HUD CAN DRAW THE RIGHT PERSON'S VITALS. "the health/shield/
--- inventory don't show properly. They should be fully populated" -- the owner.
--- A spectator's own ped is dead, so a HUD that reads it shows an empty bar and
--- an empty bar is what was reported.
---
--- IT HANDS BACK A SERVER ID AND NOTHING ELSE, which is the whole of what this
--- file is allowed to know. Health and shield are then read from the client's
--- own roster mirror -- they are already in roster.lua's PUBLIC_FIELDS, so this
--- reveals nothing that was not already on this machine -- and the inventory,
--- which is NOT public, arrives on the session's own feed from the server.
--- @return integer|nil
function BR.Spectate.targetSrc()
    return session and session.targetSrc or nil
end

-- ----------------------------------------------------------------- camera ---

--- Take the camera down. Safe to call when nothing is up.
---
--- THE TEARDOWN IS THE DANGEROUS HALF, in the words client/lobbycam.lua already
--- uses: a script camera left rendering shows whatever it points at forever,
--- with no error and nothing in any log. Every exit path in this file goes
--- through here.
local function camDown()
    if cam then
        if DoesCamExist and DoesCamExist(cam) then
            RenderScriptCams(false, false, 0, true, true)
            DestroyCam(cam, true)
        end
        cam = nil
    end
    -- The streaming focus goes with it. A focus left on a remote point keeps the
    -- world streaming around somewhere the player is not, which is a frame cost
    -- with no picture attached.
    BR.Native.stopSpectate()
    -- AND SO DOES THE RADAR. A minimap left pinned to a coordinate is the same
    -- class of bug as a script camera left rendering, which is what this whole
    -- function exists for: it shows the wrong thing forever, with no error and
    -- nothing in any log. Every exit path in this file comes through here.
    BR.Native.unlockMinimap()
    want, shown = nil, nil
end

--- Tell the interface what is happening.
---
--- IT USED TO BE TWO BOOLEANS AND NO PROSE, because the only thing any screen
--- did with this was decide whether to offer the pause-menu exit. It now
--- carries the target's NAME as well, for one string the owner wrote out:
--- "some text that says 'SPECTATING X' would be helpful". X is this.
---
--- THE NAME IS THE ONLY THING ADDED, and the keys are deliberately NOT here.
--- The interface already holds every binding with its current label -- Lua
--- pushes BR.Nui.KEYBINDS at start and again on every rebind -- so putting the
--- arrow keys on this envelope too would be a second copy that goes stale the
--- first time somebody rebinds them mid-session. The hint reads the same rows
--- the keybinds screen reads.
local function pushUi()
    TriggerEvent('br:ui:sendLocal', BR.Nui.SPECTATE, {
        active = session ~= nil,
        admin  = session ~= nil and session.admin == true,
        name   = session and session.name or nil,
    })
end

-- --------------------------------------------------------------- the wire ---

RegisterNetEvent(BR.Net.SPECTATE_SET)
AddEventHandler(BR.Net.SPECTATE_SET, function(d)
    if type(d) ~= 'table' then return end

    if d.stop then
        if session then
            print(('[br_core] spectate: stopped (%s)'):format(tostring(d.reason)))
        end
        session = nil
        camDown()
        pushUi()
        -- THE HUD GOES BACK TO ITS OWNER. Both of these are the same call the
        -- start path makes, and they are here as well because the end of a
        -- session is the other edge of the same substitution: without them a
        -- player who stopped spectating would keep looking at the last person
        -- they watched.
        TriggerEvent('br:spectate:inv', nil)
        if BR.PushHud then BR.PushHud(true) end
        return
    end

    local fresh = (session == nil) or (session.targetSrc ~= d.targetSrc)
    session = { targetSrc = d.targetSrc, name = d.name, admin = d.admin == true }

    -- THE TARGET'S INVENTORY, WHEN THE SERVER SENT ONE.
    --
    -- ABSENT MEANS UNCHANGED, NOT EMPTY -- the feed dedupes, so most pushes
    -- carry no `inv` at all and the last one given still stands. A `nil` here
    -- must therefore NOT clear the bar; the only things that clear it are the
    -- stop path above and a change of target below.
    if d.inv then
        TriggerEvent('br:spectate:inv', d.inv)
    end

    if d.x then
        want = { x = d.x, y = d.y, z = d.z }
        -- A NEW TARGET DOES NOT EASE, IT CUTS. Easing from the last person to
        -- the next would fly the camera across the map through the geometry
        -- between them; a cut is what every spectator in every shipped BR does.
        if fresh or not shown then
            shown = { x = d.x, y = d.y, z = d.z }
        end
    end

    -- STREAMING FOLLOWS THE TARGET. Asked on every push rather than once,
    -- because SET_FOCUS_ENTITY is only available while the ped is streamed and
    -- the position fallback is what covers the rest of the time -- which of the
    -- two applies changes as the target moves.
    BR.Native.spectate(d.targetSrc, want)

    if fresh then
        camYaw, camPitch = 0.0, -8.0
        print(('[br_core] spectate: watching %s (%s)')
            :format(tostring(d.name), tostring(d.targetSrc)))

        -- THE VITALS FOLLOW THE CAMERA. `BR.PushHud` dedupes on the values it
        -- last sent, and stepping from one squadmate to another who happens to
        -- be on the same health would send nothing at all -- so the change of
        -- SUBJECT has to force a push rather than wait for a change of number.
        -- The server's own push for the new target is what refills the bar.
        if BR.PushHud then BR.PushHud(true) end

        -- THE CONSOLE GETS OUT OF THE WAY (admin only). The Spectate button is
        -- pressed inside the admin console, which is a full-page focus screen
        -- with a cursor -- so without this the admin is looking at a board of
        -- incidents with a camera running behind it. Popping the two screens
        -- that could be holding it is precise and reversible; clearFocus would
        -- also drop a lobby the player is standing in.
        if session.admin then
            TriggerEvent('br:ui:popFocus', 'admin')
            TriggerEvent('br:ui:popFocus', 'pause')
        end
        pushUi()
    end
end)

-- ------------------------------------------------------------------- keys ---

--- Ask for a different target, or for a session at all.
---
--- THE SERVER DECIDES AND MAY SAY NO. This sends the intent and nothing else --
--- there is no local candidate list to walk, and there must not be one.
--- @param dir number  +1 next, -1 previous, 0 "start / re-resolve"
local function ask(dir)
    -- Not while still in the fight. The server refuses this case too (it is the
    -- side that decides), but sending a request per keypress from every living
    -- player who happens to press an arrow is traffic with no possible outcome.
    local st = BR.State.me.state
    if st == BR.PlayerState.ALIVE or st == BR.PlayerState.DBNO
       or st == BR.PlayerState.BUS or st == BR.PlayerState.FREEFALL
       or st == BR.PlayerState.GLIDE or st == BR.PlayerState.WARMUP then
        return
    end
    TriggerServerEvent(BR.Net.SPECTATE_CYCLE, { dir = dir })
end

-- THE ARROWS WERE BOUND AND DEAD, AND THIS IS THE SUBSCRIBER THEY NEVER HAD.
--
-- keybinds.lua has carried `specNext` (RIGHT) and `specPrev` (LEFT) since M3
-- with no BR.Keys.on for either -- its own comment called them "STILL DEAD AND
-- STILL BOUND", and a documentation audit on 2026-08-21 found the public site
-- telling players they worked. Nothing new is registered here: the rows in the
-- pause menu and in our own rebinder are the same rows, so a player who had
-- already moved them keeps their choice.
BR.Keys.on('specNext', function(pressed)
    if pressed then ask(1) end
end)
BR.Keys.on('specPrev', function(pressed)
    if pressed then ask(-1) end
end)

-- ---------------------------------------------------------------- the exit ---

-- "While admin spectating, there should be an in-game option (perhaps pause
-- menu) to stop spectating" -- the owner. br_ui owns the row and forwards the
-- verb; what it MEANS is br_core's, which is the same split the locker, the
-- inventory and every other pause-menu verb already use.
--
-- IT ASKS THE SERVER RATHER THAN TEARING THE CAMERA DOWN HERE. The session is
-- the server's -- it holds the audit row that has to be closed with a duration,
-- and a client that could end a session locally would be a client whose admin
-- session ended in the log at a time it did not end on the screen.
AddEventHandler('br:ui:pauseAction', function(action)
    if action ~= 'spectate' then return end
    TriggerServerEvent(BR.Net.SPECTATE_STOP)
end)

-- --------------------------------------------------------------- the open ---

--- How many times one death may ask for a camera before giving up.
---
--- BOUNDED, BECAUSE THE ANSWER MAY LEGITIMATELY BE "NOBODY". A dead solo player
--- on a server with free spectate off has no targets and never will, and a
--- retry loop with no ceiling would ask once a second for the rest of the match.
--- Three covers a request lost to a busy frame, which is the only failure a
--- retry can fix.
local OPEN_TRIES = 3
local asks, lastState = 0, nil

BR.Loop.register(BR.Loop.SLOW, 'spectate.open', function()
    local st = BR.State.me.state

    -- A NEW DEATH IS A NEW BUDGET. Reset on the EDGE rather than on the state,
    -- so being dead for twenty minutes does not re-arm the counter, and dying in
    -- the next match does.
    if st ~= lastState then
        lastState = st
        asks = 0
    end

    if session or asks >= OPEN_TRIES then return end
    if st ~= BR.PlayerState.DEAD and st ~= BR.PlayerState.SPECTATING then return end

    -- YOUR OWN DEATH GETS THE SCREEN FIRST.
    --
    -- "Upon dying, the verdict text ONLY should be shown for ~10 seconds then
    -- the text can immediately disappear as we snap into spectating" -- the
    -- owner. This loop is the "snap": it used to fire on the first SLOW tick
    -- after the state read DEAD, which put the player behind a squadmate's
    -- shoulder inside a second and skipped the moment entirely.
    --
    -- THE HOLD IS THE SAME CLOCK AS THE WORD, not a second timer of the same
    -- length. client/state.lua owns the deadline and this asks it, so
    -- BR.Config.Spectate.deathVerdictMs moves both halves together and they
    -- cannot drift into a gap of dead air or an overlap where the camera cuts
    -- away mid-sentence.
    --
    -- IT DOES NOT SPEND A TRY. `asks` is the budget for requests the server
    -- might have dropped; returning before incrementing means a player is not
    -- charged two of their three attempts for waiting out their own death.
    --
    -- NIL-GUARDED because this file loads with or without state.lua's half, and
    -- the safe answer for "is the word up" on a client that cannot say is no --
    -- which is exactly the behaviour that shipped before this existed.
    if BR.DeathVerdictUp and BR.DeathVerdictUp() then return end

    asks = asks + 1
    ask(0)
end)

-- --------------------------------------------------------------- the shot ---

BR.Loop.register(BR.Loop.FRAME, 'spectate.camera', function()
    if not session or not shown or not want then
        if cam then camDown() end
        return
    end

    -- A build without the camera natives keeps the gameplay camera rather than
    -- taking the screen away -- the same call client/dbno.lua makes.
    if not CreateCamWithParams then return end

    -- EASE TOWARD THE LAST SAMPLE. The feed is 4 Hz (config: Spectate.feedMs);
    -- this runs every frame, so without it the subject moves in visible steps.
    -- Same exponential ease bus.lua uses on its heading, and for the same
    -- reason: it is frame-rate independent, unlike a fixed fraction per frame.
    local dt = GetFrameTime()
    local e = 1.0 - math.exp(-dt * 8.0)
    shown.x = shown.x + (want.x - shown.x) * e
    shown.y = shown.y + (want.y - shown.y) * e
    shown.z = shown.z + (want.z - shown.z) * e

    -- THE MINIMAP GOES WHERE THE CAMERA GOES.
    --
    -- "the minimap doesn't show the right location - it shows the dead ped's
    -- location" -- the owner. Nothing had ever moved it: the radar follows the
    -- local player, and the local player is a corpse where they fell.
    --
    -- PINNED TO `shown` AND NOT TO `want`, so the map and the shot are the same
    -- place. `want` is the raw 4 Hz server sample; `shown` is the eased point
    -- the camera is actually looking at, and a radar snapping four times a
    -- second under a camera that glides would read as two different subjects.
    --
    -- RE-ASSERTED EVERY FRAME rather than set once per target. The lock is a
    -- position, not a follow -- the engine holds the coordinate it was given and
    -- has no idea the subject is running -- so this is the mechanism, not a
    -- refresh of it.
    --
    -- NO PED IS MOVED, and see BR.Native.lockMinimap for why that matters: the
    -- alternative on the table was teleporting the dead ped onto the target and
    -- hiding it, which is safe for a dead player and catastrophic for an ADMIN
    -- who may be alive and mid-match. This is one mechanism that is correct for
    -- both.
    BR.Native.lockMinimap(shown.x, shown.y)

    -- AND PREFER THE PED WHEN THERE IS ONE. Once the target is streamed in, the
    -- engine has their position every frame and the server's 4 Hz sample is the
    -- worse of the two answers -- so the sample becomes the fallback rather than
    -- the source. Out of scope it is the only answer there is.
    local ped = BR.Native.spectatePed(session.targetSrc)
    local tx, ty, tz = shown.x, shown.y, shown.z
    if ped ~= 0 then
        local c = GetEntityCoords(ped)
        tx, ty, tz = c.x, c.y, c.z
        shown.x, shown.y, shown.z = c.x, c.y, c.z
    end

    if not cam or (DoesCamExist and not DoesCamExist(cam)) then
        camYaw, camPitch = camYaw or 0.0, camPitch or -8.0
        cam = CreateCamWithParams('DEFAULT_SCRIPTED_CAMERA',
            tx, ty, tz + BR.Config.Spectate.camHeight,
            0.0, 0.0, 0.0, BR.Config.Spectate.fov, false, 2)
        if not cam or cam == -1 then
            cam = nil
            print('[br_core] spectate: no camera -- staying on the gameplay one')
            return
        end
        SetCamActive(cam, true)
        RenderScriptCams(true, false, 0, true, true)
    end

    camYaw   = (camYaw - GetControlNormal(0, 1) * 8.0) % 360.0
    camPitch = BR.Clamp(camPitch - GetControlNormal(0, 2) * 6.0, -70.0, 25.0)

    local dist  = BR.Config.Spectate.camDistance
    local yaw   = math.rad(180.0 + camYaw)
    local pitch = math.rad(camPitch)
    local horiz = dist * math.cos(pitch)

    local aimZ = tz + BR.Config.Spectate.camHeight
    local cx = tx - math.sin(yaw) * horiz
    local cy = ty + math.cos(yaw) * horiz
    local cz = aimZ - dist * math.sin(pitch)

    -- WALLS ARE WALLS. A camera four metres behind somebody stood against a
    -- doorframe is inside the doorframe, and the shot is the inside of a wall.
    -- dbno.lua casts the same ray against the same problem; this one is only
    -- worth casting when the geometry around the target is actually loaded,
    -- which is what having a ped handle means.
    if ped ~= 0 then
        local ray = StartShapeTestRay(tx, ty, aimZ, cx, cy, cz, 1 | 16, ped, 4)
        local _, hit, ep = GetShapeTestResult(ray)
        if didHit(hit) and ep and ep.x then
            cx = tx + (ep.x - tx) * 0.8
            cy = ty + (ep.y - ty) * 0.8
            cz = aimZ + (ep.z - aimZ) * 0.8
        end
    end

    SetCamCoord(cam, cx, cy, cz)
    PointCamAtCoord(cam, tx, ty, aimZ)

    -- THE BODY STAYS PUT WHILE THE EYES ARE ELSEWHERE, and this is per-frame
    -- suppression rather than a freeze on purpose. A latch that sets a flag on
    -- start and clears it on stop is a flag that can stick, and a stuck freeze
    -- is a player who cannot move with nothing on screen saying why -- the
    -- failure keybinds.lua's own gate note calls worse than the leak it closes.
    -- Suppression that has to be re-asserted every frame cannot outlive the
    -- session by more than one.
    --
    -- IT MATTERS FOR THE ADMIN, NOT THE CORPSE. A dead player's ped is not going
    -- anywhere; an admin spectating from the lobby would otherwise be running
    -- around blind, and shooting.
    for _, control in ipairs({ 21, 22, 23, 24, 25, 30, 31, 32, 33, 34, 35 }) do
        DisableControlAction(0, control, true)
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    session = nil
    camDown()
end)

-- ------------------------------------------------------------------ debug ---

RegisterCommand('brspec', function()
    print('=== spectate (client) ===')
    if not session then
        print('  (not spectating)')
    else
        print(('  target   %s (%s)%s'):format(
            tostring(session.name), tostring(session.targetSrc),
            session.admin and '   [admin]' or ''))
        print(('  ped      %d  (0 = out of scope; camera is on the server feed)')
            :format(BR.Native.spectatePed(session.targetSrc)))
        print(('  want     %s'):format(want
            and ('%.1f %.1f %.1f'):format(want.x, want.y, want.z) or 'nil'))
    end
    print(('  camera   %s'):format(cam and 'up' or 'down'))
    print(('  keys     %s / %s'):format(
        BR.Keys.labelFor('brspecprev'), BR.Keys.labelFor('brspecnext')))
end, false)
