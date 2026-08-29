-- The lobby ped: whether anybody else may see it, and how it arrives.
--
-- ═══ THE BUG THIS FILE EXISTS FOR ═══
--
-- "when peds switch between local and networked, they do so in the same spot.
-- this means for a split second any player's ped who joins into lobby or
-- readies into warmup is seen by other players in the lobby." -- the owner,
-- 2026-08-29.
--
-- THERE IS NO NATIVE THAT MAKES A PLAYER PED NON-NETWORKED, and this project
-- has already paid to find that out. client/squadmates.lua carries the
-- write-up: SetEntityVisible is a replicated property (it hides you from
-- yourself, and the lobby is a character shot), a 10Hz hide loses to an owner
-- asserting its own visibility every frame, and
-- _NETWORK_SET_ENTITY_INVISIBLE_TO_NETWORK does not work under OneSync. The one
-- thing that cannot lose is SET_ENTITY_LOCALLY_INVISIBLE, asserted per frame by
-- every OBSERVER on every other lobby ped.
--
-- So "local" and "networked" are not two kinds of entity here. They are one
-- BOOLEAN, held below, and it means:
--
--   networked = false -- MY ped is a lobby ped. Every other lobby client is
--                        hiding it this frame, and I am hiding theirs.
--   networked = true  -- my ped is an ordinary networked ped that anybody may
--                        see, which is the state every match runs in.
--
-- ═══ AND THE FIX IS AN ORDERING, NOT A MECHANISM ═══
--
-- "since we're transitioning the ped from local to networked ... we need to
-- first (after they fade to black) teleport the player to their new spawn
-- position in warmup - THEN convert their ped to networked."
--
-- Which is exactly what client/spawn.lua's toWarmupPad now does: the flip to
-- `true` is the LAST thing in its landing callback, after the teleport onto one
-- of BR.Config.Match.warmupSpawns and after collision. Nobody standing in the
-- lobby ever sees a networked ped, because by the time the ped is networked it
-- is forty kilometres away on the airstrip.
--
-- The observer's half is the same rule read backwards, and it is the half that
-- used to be wrong: the hide loop was gated on `my state is LOBBY`, which stops
-- being true the INSTANT the server names me a participant -- a second or more
-- before the trip has moved me anywhere. So a player readying up watched every
-- other lobby ped pop into existence around them while they waited for a fade.
-- Gated on this latch instead, they stay hidden until I have actually gone.
--
-- ═══ THE ENTRANCE ═══
--
-- The other half of "joins into lobby" is that a joining ped materialises ON
-- the lobby mark, in everybody's shot. It no longer does: it is placed thirty
-- metres up the path and walks in, behind a camera that flies down to meet it.
-- Every coordinate and every duration is in BR.Config.Match.lobbyEntrance --
-- the owner offered to tune the timing, so none of it is written down here.
--
-- ═══ ABANDONMENT IS A FIRST-CLASS ENDING ═══
--
-- "If the player readies up quickly and joins to warmup - drop everything
-- (camera motions, ped motions) and move to warmup immediately."
--
-- Every thread this file starts carries the value of `token` it began with and
-- checks it before it touches anything. stop() bumps the token, so a sequence
-- is abandoned by ARITHMETIC rather than by finding and interrupting the parts
-- of it that are in flight -- there is no list of things to remember to cancel,
-- and a thread parked in a Citizen.Wait cannot outlive its own sequence.
--
-- And stop() is the ONLY ending. The happy path calls it, readying up calls it,
-- a failure calls it, the resource stopping calls it -- so the walking style,
-- the streaming focus and the locker lock are released in one place rather than
-- in four, which is the shape of bug this project has shipped most.

BR = BR or {}
BR.LobbyPed = {}

--- IN LUA 0 IS TRUTHY, AND A FIVEM NATIVE DECLARED BOOL MAY ANSWER 1 RATHER
--- THAN true. Both spellings of the bare test are wrong and they are wrong in
--- opposite directions -- see client/spawn.lua's copy of this note for the two
--- shipped instances. Every BOOL read in this file goes through here, and two
--- of them are the ones that bite: HasModelLoaded gates the walk (the owner
--- asked for that wait explicitly) and IsScreenFadedIn gates the camera's
--- second move. A raw read of either is a wait that does not wait.
--- @param v any
--- @return boolean
local function isTrue(v)
    return v ~= nil and v ~= false and v ~= 0
end

-- ---------------------------------------------------------------------------
-- Local or networked
-- ---------------------------------------------------------------------------

-- FALSE IS THE SAFE DEFAULT AND THAT IS WHY IT IS THE INITIAL VALUE. A client
-- that has just started br_core is, as far as it knows, standing in the lobby:
-- BR.State.me.state defaults to LOBBY (client/main.lua). Starting at `true`
-- would show every other lobby ped for the tick before the latch caught up.
local networked = false

--- Is my ped one that other people may see?
--- @return boolean
function BR.LobbyPed.isNetworked()
    return networked == true
end

--- Is my ped a LOBBY ped -- hidden from every other lobby client this frame?
---
--- The inverse of the above, spelled out because it is what the hide loop in
--- client/squadmates.lua reads and "not isNetworked()" at a call site is a
--- double negative on a per-frame path.
--- @return boolean
function BR.LobbyPed.isLobbyPed()
    return networked ~= true
end

--- Flip the latch, and say so.
---
--- SAID OUT LOUD BECAUSE THE SYMPTOM IS INVISIBLE. A latch stuck at `false` in
--- a match is a player who cannot see anybody they are fighting; stuck at
--- `true` in the lobby is the original bug. Neither produces an error and both
--- look like a networking fault, so the console records every flip and what
--- caused it.
--- @param on boolean
--- @param why string|nil
function BR.LobbyPed.setNetworked(on, why)
    on = on == true
    if on == networked then return end
    networked = on
    print(('[br_core] lobby ped is now %s (%s)')
        :format(on and 'networked' or 'local', tostring(why or 'unstated')))
end

-- ---------------------------------------------------------------------------
-- The entrance
-- ---------------------------------------------------------------------------

local ARMED, RUNNING, DONE = 'armed', 'running', 'done'

-- ARMED AT LOAD: the entrance is a thing that happens once, on the way into the
-- lobby this session, and the tick below is what decides when the world is
-- ready for it.
local phase = ARMED

-- BUMPED BY EVERY stop(). See the header: this is the whole abandonment
-- mechanism, and it is deliberately a number rather than a set of flags.
local token = 0

-- The ped is on its start mark, wearing its walking style, and moving. Distinct
-- from `phase == RUNNING`, which is true during the setup as well: the loading
-- screen may only come down once this is true, and client/natives.lua may only
-- stop freezing the ped once this is true.
local walking = false

-- Whether WE moved the streaming focus, so we know whether to give it back.
local focusHeld = false

-- Whether the locker is currently refused. Held here rather than in
-- client/locker.lua because this file owns every path that sets it.
local locked = false

-- When the loading screen first asked whether it could come down. The arm wait
-- is measured from that rather than from load, because load happens long before
-- there is a session to stand in.
local askedAt = nil

-- Whether the camera has already been sent home by the flight. stop() settles a
-- camera that is still out over the island; restarting an interpolation that is
-- ALREADY landing would cancel it, which reads as a snap rather than an arrival.
local camLanded = false

-- The walk, snapshotted at the start rather than rebuilt per poll: the camera
-- thread reads it at 20Hz to work out how far the ped still has to go.
local path = {}

-- Which leg the ped is on. 1-based; #path+1 once the walk is over.
local legIndex = 1

--- @return table
local function cfg()
    return BR.Config.Match.lobbyEntrance
end

--- Is the entrance running? Read by client/lobbycam.lua, which stands down
--- while it is, and by /brlobbywalk.
--- @return boolean
function BR.LobbyPed.entering()
    return phase == RUNNING
end

--- Is the ped actually walking right now? Read by client/natives.lua, whose
--- per-frame LOBBY freeze would otherwise hold it on the spot.
--- @return boolean
function BR.LobbyPed.walking()
    return walking == true
end

--- Is the locker refused? Read by client/locker.lua and pushed to the page.
--- @return boolean
function BR.LobbyPed.lockerLocked()
    return locked == true
end

--- Lock or unlock the locker, and tell the interface.
---
--- THE LOCK IS THE WHOLE ANSWER TO A MODEL SWAP MID-WALK (owner, 2026-08-29:
--- "How about to prevent them from changing peds while walking, we lock out the
--- 'locker' button until the ped has reached it's final coords"). SetPlayerModel
--- hands back a NEW ped handle and throws the old one away -- with its tasks, so
--- the walk would simply stop, on a handle nothing is holding, halfway up a
--- path. Locking removes the case instead of trying to survive it.
---
--- NO NEW WORDS ANYWHERE. The button uses the disabled state every other
--- unavailable control in this interface already has; nothing explains itself.
--- @param on boolean
local function setLocked(on)
    on = on == true
    if on == locked then return end
    locked = on
    -- Guarded because this file loads before nothing in particular and the
    -- locker's own push reads the roster; a lock set before locker.lua exists
    -- is still recorded here and travels on its next push.
    if BR.Locker and BR.Locker.push then BR.Locker.push() end
end

--- Give the streaming focus back to the player.
---
--- ON EVERY ENDING, WHICH IS WHY IT IS IN stop() AND NOWHERE ELSE. A client
--- left with its focus three hundred metres up over the ocean does not error
--- and does not log: it presents, later and somewhere else, as world geometry
--- failing to stream in around the player, with nothing pointing back here.
local function releaseFocus()
    if not focusHeld then return end
    focusHeld = false
    if SetFocusEntity then
        SetFocusEntity(PlayerPedId())
    elseif ClearFocus then
        ClearFocus()
    end
end

--- Put the ped exactly on the lobby mark, frozen, facing the authored heading.
---
--- The same treatment BR.Spawn.respawn's exact path gives it, and for the same
--- reason: the lobby is a CAMERA MARK, so a ground snap that moved the ped half
--- a metre downhill would move the subject out of its own frame.
local function standOnMark()
    local p = BR.Config.Match.lobbyPos
    local ped = PlayerPedId()
    SetEntityCoordsNoOffset(ped, p.x, p.y, p.z, false, false, false)
    SetEntityHeading(ped, p.heading + 0.0)
    FreezeEntityPosition(ped, true)
end

--- Drop everything. The only ending this sequence has.
---
--- Safe to call at any time, from any state, as often as you like -- readying
--- up calls it, the walk calls it when it finishes, a failure calls it, and the
--- resource stopping calls it.
--- @param why string|nil  for the console
function BR.LobbyPed.stop(why)
    local wasRunning = (phase == RUNNING)

    -- FIRST, AND BEFORE ANY NATIVE. Every thread in flight reads this before it
    -- touches the ped or the camera, so bumping it here means nothing else can
    -- write over the teardown below while the teardown is happening.
    token = token + 1
    phase = DONE
    walking = false

    releaseFocus()
    setLocked(false)

    if not wasRunning then return end

    local ped = PlayerPedId()
    ClearPedTasks(ped)
    -- The walking style is a property of the ped, not of the task, so clearing
    -- the task does NOT clear it -- a ped left with this on would groove
    -- through the whole match.
    if ResetPedMovementClipset then ResetPedMovementClipset(ped, 0.25) end

    -- WHERE THE PED IS LEFT DEPENDS ON WHETHER IT IS STILL A LOBBY PED, and
    -- getting this backwards would undo the entire fix. The warmup transition
    -- abandons this sequence precisely so that IT can do the teleport; snapping
    -- home here would drag the player back onto the lobby mark a moment after
    -- they left it. So: only stand on the mark if the mark is still where I
    -- belong, and never while a trip is carrying me somewhere else.
    if BR.State.me.state == BR.PlayerState.LOBBY
       and not (BR.Spawn and BR.Spawn.traveling) then
        standOnMark()
        -- A camera parked mid-flight over the ocean is worse than an abrupt
        -- settle, so it lands rather than being destroyed -- the follow tick in
        -- client/lobbycam.lua takes it back from here. Skipped when the flight
        -- already sent it home: restarting an interpolation that is landing
        -- CANCELS it, and the view snaps to the destination instead of easing
        -- into it, which is precisely the two-seconds-early arrival the whole
        -- schedule exists to produce.
        if not camLanded then BR.LobbyCam.glideHome(400) end
    else
        BR.LobbyCam.stop()
    end

    print(('[br_core] lobby entrance stopped (%s)'):format(tostring(why or 'unstated')))
end

--- Ask for the entrance again. /brlobbywalk, and nothing in the gamemode.
function BR.LobbyPed.rearm()
    BR.LobbyPed.stop('re-armed')
    phase = ARMED
    askedAt = nil
end

-- ---------------------------------------------------------------------------
-- What the loading screen needs to know
-- ---------------------------------------------------------------------------

--- Where the ped is expected to be standing when the screen comes down.
---
--- client/loading.lua holds the loading screen until the ped is on its mark,
--- and during the entrance the mark is the START of the walk rather than the
--- lobby spot -- the owner's choreography has the screen fading in with the ped
--- already moving. Nil means "the ordinary lobby mark", which is every other
--- case.
--- @return table|nil
function BR.LobbyPed.revealMark()
    if phase == ARMED or phase == RUNNING then
        return cfg().pedStart
    end
    return nil
end

--- Why the loading screen may not come down yet, or nil.
---
--- BOUNDED, LIKE EVERY OTHER WAIT ON THAT PATH. If the entrance never starts --
--- a model that will not stream, a config somebody emptied -- this gives up and
--- lets the boot finish. A player parked on a gag reel because a walk did not
--- begin is a far worse failure than a player who simply appears on the mark.
--- @return string|nil
function BR.LobbyPed.revealBlock()
    if phase ~= ARMED and phase ~= RUNNING then return nil end

    askedAt = askedAt or GetGameTimer()
    if GetGameTimer() - askedAt > (cfg().armWaitMs or 4000) then return nil end

    if phase == ARMED then return 'the lobby entrance has not started yet' end
    if not walking then return 'the lobby entrance ped is not walking yet' end
    return nil
end

--- Point the streaming focus at the first camera node.
---
--- "please set the focus area to the first camera coords 1 second before fading
--- in" -- the owner, 2026-08-29. Called BY client/loading.lua, which owns the
--- reveal and is therefore the only thing that can lead it; it returns the lead
--- so that file can hold the reveal open for exactly that long rather than
--- hoping the calls happen to land in the right order.
---
--- SET_FOCUS_POS_AND_VEL MOVES WHERE THE ENGINE STREAMS TERRAIN AND ASSETS, and
--- that is the whole of what it does. It has no bearing on which entities are
--- relevant to this client -- that is decided from the player's own ped and
--- camera sync nodes and never reads the focus.
--- @return number  milliseconds the reveal should wait, 0 when not running
function BR.LobbyPed.focusAhead()
    if phase ~= RUNNING then return 0 end

    local node = cfg().camPath and cfg().camPath[1]
    if not node or not SetFocusPosAndVel then return 0 end

    SetFocusPosAndVel(node.x + 0.0, node.y + 0.0, node.z + 0.0, 0.0, 0.0, 0.0)
    focusHeld = true
    return cfg().focusLeadMs or 1000
end

-- ---------------------------------------------------------------------------
-- The walk
-- ---------------------------------------------------------------------------

--- Every leg of the path, the authored corners plus the lobby mark.
---
--- THE LAST ONE IS NOT IN THE CONFIG and is deliberately not: the lobby mark
--- has exactly one definition, which the camera, the locker and the loading
--- gate all read, and a second copy of it in a path table is the drift this
--- project is most scarred by.
--- @return table
local function legs()
    local out = {}
    for _, n in ipairs(cfg().pedPath or {}) do
        out[#out + 1] = n
    end
    out[#out + 1] = BR.Config.Match.lobbyPos
    return out
end

--- The clipset for this ped's walk.
---
--- "grooving male" / "grooving female" are the rpemotes MENU's labels for two
--- stock GTA movement clipsets, and these are the clipsets. Nothing here
--- requires, references or checks for rpemotes -- the owner intends to remove
--- it, and SetPedMovementClipset takes the clipset name directly.
--- @param ped number
--- @return string
local function clipsetFor(ped)
    local male = true
    if IsPedMale then male = isTrue(IsPedMale(ped)) end
    return male and cfg().walkClipsetMale or cfg().walkClipsetFemale
end

--- How far the ped still has to walk, along the remaining path.
--- @param from number  index of the leg being walked
--- @return number  metres
local function remaining(from)
    local c = GetEntityCoords(PlayerPedId())
    local total = 0.0
    local px, py = c.x, c.y
    for i = from, #path do
        total = total + BR.Dist(px, py, path[i].x, path[i].y)
        px, py = path[i].x, path[i].y
    end

    -- AND THE WALK STOPS SHORT AT EVERY CORNER. `arriveRadius` is how close
    -- counts as arrived, so the ped covers that much less than the
    -- straight-line sum -- once per leg still to come. Left in, the estimate
    -- runs long by a couple of seconds, the last camera move starts late, and
    -- the camera lands with the ped instead of ahead of it, which is the one
    -- thing this schedule exists to prevent.
    total = total - (cfg().arriveRadius or 0.9) * math.max(0, #path - from + 1)
    return total > 0.0 and total or 0.0
end

--- Roughly how long until the ped reaches the lobby mark, in milliseconds.
---
--- MEASURED RATHER THAN ASSUMED, and it is what schedules the camera's last
--- move: distance still to cover over the speed the ped is ACTUALLY managing.
--- A guessed metres-per-second would be one more number to tune and would be
--- wrong the first time somebody changed walkSpeed or the clipset.
---
--- The floor on the speed is what stops a ped that has snagged on geometry
--- reading as "never arriving" and holding the camera up in the sky; the leg
--- timeout is the real escape from that, and this only has to not make it
--- worse.
--- @return number
local function etaMs()
    local speed = GetEntitySpeed and GetEntitySpeed(PlayerPedId()) or 0.0
    if not speed or speed ~= speed or speed < 0.6 then speed = 0.6 end
    return (remaining(legIndex) / speed) * 1000.0
end

--- Fly the camera down to meet the ped. Runs alongside the walk.
--- @param mine number  the token this thread belongs to
local function flyCamera(mine)
    local C = cfg()
    local path = C.camPath or {}
    local move = C.camMoveMs or 5000

    -- MOVE 2 IS CUED ON THE SCREEN, NOT ON A CLOCK. "As the screen fades in
    -- (ped still walking): smoothly to ..." -- so this waits for the reveal
    -- rather than starting a timer at the same moment and hoping. Bounded,
    -- because a boot where the fade never lands must still end with a camera
    -- pointing at the lobby.
    local deadline = GetGameTimer() + 20000
    while token == mine and GetGameTimer() < deadline do
        if BR.State.worldReady ~= false and isTrue(IsScreenFadedIn()) then break end
        Citizen.Wait(50)
    end
    if token ~= mine then return end

    for i = 2, #path do
        BR.LobbyCam.glide(path[i], move)
        local until_ = GetGameTimer() + move
        while token == mine and GetGameTimer() < until_ do Citizen.Wait(50) end
        if token ~= mine then return end
    end

    -- AND IT LANDS BEFORE THE PED DOES, BY camLeadMs. The last move is started
    -- when the ped is (move + lead) away from the mark, so it FINISHES a lead's
    -- worth of time early -- which is the owner's "the camera should reach its
    -- final position about 2 seconds before the ped does", expressed against
    -- the ped rather than against a stopwatch that would drift the moment the
    -- walk was slower than the estimate.
    local lead = C.camLeadMs or 2000
    local hard = GetGameTimer() + (C.legTimeoutMs or 15000) * 2
    while token == mine and GetGameTimer() < hard do
        if legIndex > #path then break end            -- the ped got there first
        if etaMs() <= move + lead then break end
        Citizen.Wait(50)
    end
    if token ~= mine then return end

    BR.LobbyCam.glideHome(move)
    camLanded = true
end

--- The whole entrance, from the black screen to the ped standing on its mark.
--- @param mine number
local function run(mine)
    local C = cfg()

    -- 1. THE PED GOES TO THE START MARK WHILE THE SCREEN IS STILL BLACK.
    --    Frozen, and with collision requested: this is a teleport like any
    --    other and the ground under it has to exist before the ped is released.
    local ped = PlayerPedId()
    local s = C.pedStart
    RequestCollisionAtCoord(s.x, s.y, s.z)
    SetEntityCoordsNoOffset(ped, s.x, s.y, s.z, false, false, false)
    SetEntityHeading(ped, s.heading + 0.0)
    FreezeEntityPosition(ped, true)

    -- 2. THE CAMERA'S FIRST SHOT, RAISED UNDER THE BLACK. No interpolation:
    --    there is nothing to blend from.
    if C.camPath and C.camPath[1] then BR.LobbyCam.place(C.camPath[1]) end

    -- 3. WAIT FOR THE MODEL. The owner called this out explicitly, and the
    --    failure it prevents is the one client/loading.lua already documents:
    --    the character is assembled by client/locker.lua on the first lobby
    --    tick, and a walk started before that is a walk the default freemode
    --    ped begins and the real character finishes -- on a different handle,
    --    with the task lost in between.
    local want = nil
    if BR.PedById and BR.Locker and BR.Locker.chosen then
        want = GetHashKey(BR.PedById(BR.Locker.chosen()).model)
    end
    if want then
        local deadline = GetGameTimer() + (C.modelWaitMs or 8000)
        while token == mine and GetGameTimer() < deadline do
            if GetEntityModel(PlayerPedId()) == want then break end
            Citizen.Wait(50)
        end
    end
    if token ~= mine then return end

    -- The handle can have changed under us while we waited -- that IS what we
    -- were waiting for -- so everything below reads it again.
    ped = PlayerPedId()

    -- 4. THE WALKING STYLE. Bounded: a clipset that will not stream costs an
    --    ordinary walk, not an entrance that never starts.
    local clip = clipsetFor(ped)
    if clip and RequestAnimSet then
        RequestAnimSet(clip)
        local deadline = GetGameTimer() + (C.clipsetWaitMs or 3000)
        while token == mine and GetGameTimer() < deadline
              and not isTrue(HasAnimSetLoaded(clip)) do
            Citizen.Wait(50)
        end
        if token ~= mine then return end
        if isTrue(HasAnimSetLoaded(clip)) then
            SetPedMovementClipset(ped, clip, 0.2)
        else
            print(('[br_core] lobby entrance: "%s" never streamed -- plain walk')
                :format(tostring(clip)))
        end
    end

    -- 5. AND NOW IT MAY MOVE. client/natives.lua re-freezes a LOBBY ped every
    --    frame, so `walking` is what stands that rule down -- setting it before
    --    the unfreeze rather than after is the difference between a walk and a
    --    single frame of one.
    walking = true
    FreezeEntityPosition(ped, false)

    local radius = C.arriveRadius or 0.9
    local legMs = C.legTimeoutMs or 15000

    -- ═══ A SPEED PER LEG, AND THE LAST ONE CARRIES ═══
    --
    -- Owner, 2026-08-29: "Set walk speed to 2.0 until the first point, 1.5
    -- until the second point, then 1.0 for 3rd -> 4th point." So the ped
    -- arrives at a walk having covered the long opening leg at a run.
    --
    -- THE LIST MAY BE SHORTER THAN THE PATH. A table indexed straight by `i`
    -- would hand `nil` to TaskGoStraightToCoord the moment somebody added a
    -- corner, which is a ped that stops dead with no error to read. Clamping to
    -- the last entry means a longer path simply finishes at the arrival speed,
    -- which is the one that was chosen for arriving.
    --
    -- `walkSpeed` STAYS AS THE SCALAR FALLBACK so a config that predates the
    -- list still walks rather than defaulting to a number nobody wrote.
    local speeds = C.walkSpeeds
    local haveList = type(speeds) == 'table' and #speeds > 0
    local function speedFor(i)
        if haveList then return speeds[math.min(i, #speeds)] or 1.0 end
        return C.walkSpeed or 1.0
    end

    for i = 1, #path do
        if token ~= mine then return end
        legIndex = i
        local n = path[i]
        ped = PlayerPedId()

        -- TaskGoStraightToCoord rather than a pathfinding walk: these are
        -- authored corners on open ground and the point is that the ped takes
        -- the line the owner surveyed, not one the navmesh preferred.
        --
        -- THE SPEED IS THE TASK'S, WHICH IS WHY ABANDONMENT NEEDS NOTHING NEW.
        -- Owner, 2026-08-29: "if the player readies up fast we need to cancel
        -- that walk speed now too." It is a blend ratio passed into this call
        -- rather than a property written onto the ped, so `ClearPedTasks` in
        -- stop() takes it with the task -- unlike the movement clipset, which
        -- IS a ped property and needs its own reset there. A player who readies
        -- up during the 2.0 leg does not carry a run into warmup.
        TaskGoStraightToCoord(ped, n.x, n.y, n.z, speedFor(i),
            legMs, n.heading + 0.0, 0.0)

        local until_ = GetGameTimer() + legMs
        while token == mine and GetGameTimer() < until_ do
            local c = GetEntityCoords(PlayerPedId())
            if BR.Dist(c.x, c.y, n.x, n.y) <= radius then break end
            Citizen.Wait(50)
        end
    end
    if token ~= mine then return end

    legIndex = #path + 1

    -- 6. ARRIVED. The walking style is cleared here because the owner asked for
    --    it here ("On arrival, clear the walking style"), and stop() clears it
    --    again on every other ending -- the two are not redundant, they are the
    --    happy path and every other path.
    walking = false
    standOnMark()
    BR.LobbyPed.stop('arrived')
end

--- Begin. Called by the tick below when the world is ready for it.
local function begin()
    phase = RUNNING
    token = token + 1
    local mine = token

    path = legs()
    legIndex = 1
    camLanded = false
    setLocked(true)

    Citizen.CreateThread(function() flyCamera(mine) end)
    Citizen.CreateThread(function() run(mine) end)

    print('[br_core] lobby entrance begins')
end

-- WHEN. The same shape as the lobby camera's own follow tick, and for the same
-- reason: enumerating the roads into the lobby is how the old rules kept
-- missing one. This asks "should it start? has it?" ten times a second.
--
-- IT WAITS FOR THE CHARACTER TO BE ON THE PLAYER, not merely for the state to
-- say lobby -- see step 3 of run(), and client/loading.lua's own note on the
-- four different moments "fully spawned in" could mean.
BR.Loop.register(BR.Loop.TICK, 'lobbyped.entrance', function()
    if phase ~= ARMED then return end

    -- AND IT GIVES UP IF THE SCREEN HAS ALREADY COME DOWN WITHOUT IT.
    --
    -- revealBlock() holds the loading screen for this sequence and then stops
    -- holding it, bounded, so a boot can never be parked on a walk that will
    -- not start. The other half of that bound is here: once the reveal has gone
    -- ahead, starting is WORSE than not starting -- the first thing run() does
    -- is teleport the ped thirty metres up the path, and doing that in front of
    -- somebody is the pop this whole file exists to remove.
    if askedAt and GetGameTimer() - askedAt > (cfg().armWaitMs or 4000) then
        phase = DONE
        print('[br_core] lobby entrance: the reveal went ahead without it -- skipped')
        return
    end

    if BR.State.me.state ~= BR.PlayerState.LOBBY then return end

    -- A TRIP OWNS THE PED WHILE IT IS IN FLIGHT. BR.Spawn.toLobby is routinely
    -- running underneath the loading screen on a fresh join (client/loading.lua
    -- explains why), and starting a walk out of a teleport that has not landed
    -- would race it for the ped's position.
    if BR.Spawn and BR.Spawn.traveling then return end
    if BR.Spawn and BR.Spawn.holdBlack then return end

    begin()
end)

-- THE LATCH, ASSERTED ON A TICK RATHER THAN ON A TRANSITION.
--
-- The flip to networked is made deliberately, by the warmup trip, after the
-- teleport -- that is the fix and it is in client/spawn.lua. This is the net
-- underneath it, and it exists because the flip has exactly one call site while
-- there are several ways to leave the lobby that do not go through it: a
-- /brforce, an admin resetting a stuck round, br_core restarting under a player
-- who is mid-match.
--
-- A LATCH STUCK AT `false` OUTSIDE THE LOBBY IS THE WORST BUG IN THIS FILE --
-- it is a player who cannot see anybody they are fighting, with nothing on
-- screen to say why -- so the recovery is keyed on the one fact that cannot be
-- argued with: where the ped IS. Out of the lobby by state AND out of it by a
-- hundred and fifty metres means the teleport happened, whoever did it.
BR.Loop.register(BR.Loop.TICK, 'lobbyped.latch', function()
    if BR.State.me.state == BR.PlayerState.LOBBY then
        BR.LobbyPed.setNetworked(false, 'in the lobby')
        return
    end
    if networked then return end

    local p = BR.Config.Match.lobbyPos
    local c = GetEntityCoords(PlayerPedId())
    -- The same 150m client/spawn.lua's lobby watchdog uses to decide a LOBBY
    -- player is not at the vista, read from the other direction.
    if BR.Dist(c.x, c.y, p.x, p.y) > 150.0 then
        BR.LobbyPed.setNetworked(true, 'away from the lobby mark')
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    BR.LobbyPed.stop('resource stopping')
end)

-- Replay the whole thing after editing the numbers, without a restart. This is
-- the tuning loop the owner asked for: change a duration in config, /brlobbywalk.
RegisterCommand('brlobbywalk', function()
    local C = cfg()
    print('=== lobby entrance ===')
    print(('  phase        %s'):format(phase))
    print(('  walking      %s'):format(tostring(walking)))
    print(('  locker       %s'):format(locked and 'LOCKED' or 'free'))
    print(('  ped          %s'):format(BR.LobbyPed.isNetworked() and 'networked' or 'local'))
    print(('  camMoveMs    %d'):format(C.camMoveMs or 0))
    print(('  camLeadMs    %d'):format(C.camLeadMs or 0))
    print(('  focusLeadMs  %d'):format(C.focusLeadMs or 0))
    -- ONE LINE PER LEG, IN ORDER, because the whole point of the list is that
    -- the legs differ -- a single averaged number would hide the thing being
    -- tuned. Falls back to the scalar so a config without the list still says
    -- something true.
    local sp = C.walkSpeeds
    if type(sp) == 'table' and #sp > 0 then
        local parts = {}
        for i, v in ipairs(sp) do parts[i] = ('%.2f'):format(v) end
        print(('  walkSpeeds   %s'):format(table.concat(parts, ' -> ')))
    else
        print(('  walkSpeed    %.2f'):format(C.walkSpeed or 0))
    end
    if BR.State.me.state ~= BR.PlayerState.LOBBY then
        print('  not in the lobby -- nothing to replay')
        return
    end
    BR.LobbyPed.rearm()
    print('  re-armed; the entrance tick will start it')
end, false)
