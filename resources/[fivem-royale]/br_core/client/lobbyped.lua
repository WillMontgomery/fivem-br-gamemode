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
-- AND IT IS NOT A BOOT SEQUENCE. "Also let's make that grand entry happen for
-- every trip back to the lobby. That was my expectation." -- the owner,
-- 2026-08-29. So it runs on the boot, on the trip home from a match, on
-- /brleave, and on any other road that ends with a player standing on the mark.
--
-- RE-ARMED BY LEAVING, NOT BY ARRIVING, which is what makes that true of roads
-- nobody enumerated -- an admin force, a stuck round being reset. The tick at
-- the bottom of this file watches the one fact every arrival has in common: I
-- was not here a moment ago. Arriving is what FIRES it, and the trip itself
-- asks (BR.LobbyPed.startNow, called by BR.Spawn.toLobby) so that the opening
-- teleport lands in the frame the trip's fade begins rather than somewhere
-- inside it.
--
-- ═══ THE THREE THINGS THAT WERE WRONG WITH THE MOTION ═══
--
-- All reported on 2026-08-29, and they share a shape: every piece of the
-- sequence was built as a self-contained move that ENDS AT REST, and a chain of
-- those is a stop at every joint.
--
--   * The camera paused at each node -- eased interpolations (see
--     BR.LobbyCam.glide) and, latently, a wait on the ped's measured arrival.
--   * The camera changed pace at each node -- a flat camMoveMs per move over
--     segments of 222m, 102m and 31m. It is one camFlightMs shared out by
--     LENGTH now (see flyCamera).
--   * The ped stopped and turned at each corner -- it was handed the surveyed
--     heading of the corner as its arrival facing, and the next leg only
--     arrived once it was 0.9m away, after it had finished slowing down for a
--     stop it was never going to make (see the leg loop in run).
--
-- And the fourth, which is the same story at the very end: the walk stopped
-- 0.9m short of the lobby mark and standOnMark teleported the rest.
--
-- ═══ AND THE WALK WAITS FOR SOMEBODY TO BE WATCHING IT ═══
--
-- Owner, 2026-08-29, having played the round above: "when coming back from the
-- warmup or another match, the ped doesn't do the full walk again. It should."
--
-- IT DID DO THE FULL WALK. Every road home re-arms and fires correctly -- the
-- arming is not the bug and the green test that says so is telling the truth.
-- What the owner was watching is the TAIL of a walk whose opening ran behind a
-- cover that was still up:
--
--   * THE WARMUP ROAD. /brleave raises the leaving CURTAIN -- an opaque NUI
--     layer -- and client/spawn.lua's TO_LOBBY handler lowers it on a schedule
--     that is about the ISLAND STREAMING IN: a 3.5s floor, then collision, then
--     two more seconds. BR.Spawn.toLobby starts the entrance about 450ms into
--     that, so roughly five seconds of walk happened under the curtain. The
--     opening leg is shorter than five seconds.
--   * THE END-OF-MATCH ROAD. The WAITING handler calls startNow() and then
--     DoScreenFadeIn(2000), so the first two seconds are behind a fade.
--   * THE BOOT ROAD, WHICH IS WHY HE NAMED THE OTHER TWO. client/loading.lua
--     holds the loading screen for this sequence and reveals on it, so the boot
--     is the one road where the walk and the reveal were already in step.
--
-- flyCamera ALREADY WAITED for IsScreenFadedIn and run() did not, which is the
-- asymmetry in one line. Both go through awaitReveal now: the ped is placed on
-- its mark under the cover exactly as before -- that is still the pop this file
-- exists to remove -- and then it stands there, frozen, until the screen is
-- genuinely uncovered. Bounded by revealWaitMs, because a cover that never
-- lifts has to cost a walk that starts anyway.
--
-- WHY THE SUITE COULD NOT SEE IT: tools/test_lobbyseq.lua models
-- DoScreenFadeIn as instantaneous, acknowledges the curtain in the frame it is
-- raised, and drives BR.Spawn.toLobby directly rather than through the TO_LOBBY
-- handler that owns the curtain's lifetime. It has no concept of the walk being
-- COVERED, so "a second arrival gets its own entrance" was both true and beside
-- the point. It models the covers now.
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

-- How long the ped may stop getting closer to the lobby mark before the last
-- leg gives up on it. AN ESCAPE, NOT A KNOB -- nothing about how the entrance
-- looks changes with this number, it only bounds a case the engine may never
-- produce, so it is deliberately not in config with the durations the owner
-- tunes. See the leg loop for what it is escaping.
local STALL_MS = 400

-- How far from the lobby mark still counts as standing in the lobby, for the
-- purpose of deciding an entrance may start. The same 150m the latch below and
-- client/spawn.lua's lobby watchdog both use, read the same way round: inside
-- it means the trip home has landed and the mark is under our feet.
local HERE_M = 150.0

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

-- The walk, snapshotted at the start rather than rebuilt per leg.
local path = {}

-- Which of BR.Config.Match.lobbyEntrance.pedCases this entrance drew, and the
-- blend ratio for each of its legs. Both settled once, in begin(), so every
-- reader -- the walk, the loading gate, /brlobbywalk -- is looking at the same
-- draw. A case re-rolled per leg would be four different walks.
local caseIndex = 0
local blends = {}

-- Whether the camera has reached its second-to-last node. See the wave: it is
-- the CAMERA's clock, not the ped's, and the two do not coincide.
local camNearHome = false

-- When the winner's flip finished, or nil. THE FAILSAFE'S CLOCK DOES NOT START
-- UNTIL THIS IS PAST: the flip is a deliberate pause in the walk and a ped
-- standing still for it has not failed to arrive.
local flipEnded = nil

-- ═══ THE EMOTE STATE, DECLARED HERE RATHER THAN BESIDE THE EMOTES ═══
--
-- Only because stop() is above them and has to clear `emoting`: a local
-- declared later would leave that line writing a GLOBAL of the same name, which
-- is the quietest possible way for an ending to stop ending anything. The
-- section that uses these is much further down and carries the reasoning.

-- The emote playing right now, or nil. One ped, one animation.
--
-- AND WHEN IT WILL BE OVER, because nothing else would ever say so. An emote
-- given a duration ends inside the engine and tells this file nothing, so a
-- latch that only cleared on an explicit stop would read as "something is
-- playing" for the rest of the session -- and every other emote here refuses to
-- start while something is playing. The tick at the bottom expires it.
local emoting = nil
local emoteUntil = nil

-- (b) the parked stretch is once per lobby VIEW; both are reset by begin().
local idlePlayed = false
local parkedAt = nil

-- (d) fires at most once per entrance, and (a) is what can cancel it.
local waved = false

-- (e) whether my squad is currently waiting on me, off LOBBY_STATUS.
local squadHolding = false

-- Whether the locker screen is open. (b) and (e) both stand down for it: the
-- locker is a shot of the character being chosen and an emote in the middle of
-- it is the ped moving out of the frame the player is looking at.
local inLocker = false

-- ═══ WHAT THE LAST RUN ACTUALLY TOOK ═══
--
-- THE ONLY HONEST SOURCE FOR THE LEAD. The camera used to chase the ped's
-- measured arrival so it could land `camLeadMs` early, and that chase was the
-- pause the owner reported -- so the flight is a fixed duration now and the
-- lead is whatever the two durations leave. Which means the owner is tuning one
-- against the other by eye, and these are the numbers /brlobbywalk hands him to
-- do it with: how long the walk took, how long the flight took, and therefore
-- how far ahead of the ped the camera landed. Nothing reads them at runtime.
-- Absolute game times rather than durations, because the number the owner is
-- actually tuning is the GAP between the two endings -- how far ahead of the
-- ped the camera landed -- and two independently measured durations that
-- started at different moments cannot answer that.
local walkBegan, walkEnded = nil, nil
local flightBegan, flightEnded = nil, nil

--- @return table
local function cfg()
    return BR.Config.Match.lobbyEntrance
end

--- The case this entrance is walking, or nil before one has been drawn.
---
--- HIGH IN THE FILE ONLY BECAUSE THE LOADING GATE ASKS FOR IT. Everything else
--- that reads a case is down in the walk.
--- @return table|nil
local function drawnCase()
    local cases = cfg().pedCases
    if type(cases) ~= 'table' then return nil end
    return cases[caseIndex]
end

--- Where this entrance's ped is placed, or nil before a case is drawn.
--- @return table|nil
local function startMark()
    local c = drawnCase()
    return c and c.spawn or nil
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

    -- Whatever gesture was on the ped goes with the sequence. The ClearPedTasks
    -- below is what actually takes it off; this only stops the emote bookkeeping
    -- believing something is still playing.
    emoting = nil

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
        -- EASED, UNLIKE THE FLIGHT'S OWN MOVES. This is not a segment of a
        -- constant-pace flight, it is a self-contained settle out of one that
        -- was interrupted -- so it should start and end at rest.
        if not camLanded then BR.LobbyCam.glideHome(400, true) end
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
--- ...AND IT IS THE DRAWN CASE'S SPAWN, which is why it can answer nil while
--- the entrance is merely ARMED: the case has not been drawn yet, and pointing
--- the reveal at a coordinate this entrance may not use is worse than not
--- answering. revealBlock below is what holds the screen in that window.
--- @return table|nil
function BR.LobbyPed.revealMark()
    if phase == RUNNING then return startMark() end
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

    -- ═══ IT HOLDS FOR THE PED BEING PLACED, NOT FOR THE PED WALKING ═══
    --
    -- IT USED TO HOLD FOR `walking`, AND THAT IS NOW A DEADLOCK. The walk waits
    -- for the screen (awaitReveal, which reads BR.State.worldReady) and this is
    -- what decides when the screen may come down -- so "wait for the walk" and
    -- "wait for the reveal" would be waiting for each other. Bounded, so it
    -- would have resolved after armWaitMs: a four-second stall on every boot
    -- with the ped standing on its mark behind a gag reel.
    --
    -- AND WHAT THIS GATE ACTUALLY NEEDS IS THE PLACEMENT ANYWAY. The reveal
    -- must not happen while the ped is somewhere the shot does not expect --
    -- that is the pop -- and the ped is on its mark from the frame begin() ran.
    -- The walk starting is then the FIRST thing the player sees rather than
    -- something that happened before they were looking, which is the whole of
    -- the "doesn't do the full walk" fix read from this end.
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

--- Every leg of the drawn case, its authored corners plus the lobby mark.
---
--- THE LAST ONE IS NOT IN THE CONFIG and is deliberately not: the lobby mark
--- has exactly one definition, which the camera, the locker and the loading
--- gate all read, and a second copy of it in four separate case tables is the
--- drift this project is most scarred by.
--- @return table
local function legs()
    local out = {}
    local c = drawnCase()
    for _, n in ipairs(c and c.path or {}) do
        out[#out + 1] = n
    end
    out[#out + 1] = BR.Config.Match.lobbyPos
    return out
end

--- ═══ THE SPEEDS ARE DERIVED FROM THE GEOMETRY, NOT AUTHORED ═══
---
--- Owner, 2026-08-29: "Each walk should take the exact same amount of time, and
--- be faster at the first steps when necessary, before slowing down to a normal
--- pace for the last walk." Eighteen seconds, every case.
---
--- FOUR CASES OF 41m, 59m, 29m AND 34m CANNOT SHARE ONE AUTHORED LIST, which is
--- what the flat `walkSpeeds = { 2.0, 1.5, 1.0 }` was and why it had to go: the
--- shortest case would amble in and the longest would still be walking. So the
--- pace is solved per draw.
---
--- THE SHAPE IS A RAMP, NOT A STEP. The last leg is 1.0 -- his "normal pace for
--- the last walk", and it is the leg the player is actually looking at -- and
--- the legs before it come down to it in equal increments from whatever the
--- first one needs. A single fast speed for the early legs and then 1.0 would
--- be a visible gear change at the last corner.
---
---   blend(i) = 1 + (r - 1) * (n - i) / (n - 1)
---
--- so blend(n) = 1.0 and blend(1) = r, and `r` is found by bisection: it is the
--- opening ratio that makes sum(len(i) / (blend(i) * mps)) come out at the
--- target. Bisection rather than algebra because the sum has one term per leg
--- and the cases do not agree on how many.
---
--- CLAMPED AT BOTH ENDS. 1.0 is a walk and 3.0 is a sprint, so 3.0 is as fast
--- as a person moves; a case that cannot make the target inside it (case 2,
--- because of its detour north) simply runs long, and /brlobbywalk says by how
--- much. The floor matters too: a case SHORTER than the target would otherwise
--- be solved with a blend below a walk, which is a ped wading.
--- @param from table   where the walk starts { x, y }
--- @param pts table    the legs, in order
--- @return table blends, number seconds  what those blends actually take
local function blendPlan(from, pts)
    local C = cfg()
    local mps    = C.walkMps or 1.4
    local target = (C.walkTargetMs or 18000) / 1000.0
    local lo, hi = C.walkBlendMin or 1.0, C.walkBlendMax or 3.0

    -- ═══ THE LENGTHS ARE THE ONES ACTUALLY WALKED, NOT THE SURVEYED ONES ═══
    --
    -- Every leg but the last ENDS EARLY, `cornerRadius` short of its corner --
    -- that is what rounds the corner, and it is the leg loop's `want`. So the
    -- ped never walks the full straight-line distance between two corners: it
    -- walks to a point short of one and sets off from there toward the next.
    --
    -- SUMMING THE SURVEYED LENGTHS OVERSTATES THE WALK BY ABOUT A CORNER RADIUS
    -- PER CORNER, and on case 1 -- five corners over forty-one metres -- that is
    -- most of ten metres, a quarter of the path. Solved against that, the derived
    -- speeds come out too fast and every case lands early. Same arithmetic as the
    -- leg loop, so the plan and the walk agree.
    local corner  = C.cornerRadius or 2.0
    local radius  = C.arriveRadius or 0.9
    local markRad = C.markRadius or 0.15

    local lens = {}
    local px, py = from.x, from.y
    for i = 1, #pts do
        local raw = BR.Dist(px, py, pts[i].x, pts[i].y)
        local want
        if i == #pts then
            want = markRad
        else
            want = math.min(corner, raw * 0.4)
            if want < radius then want = radius end
        end
        lens[i] = math.max(0.0, raw - want)

        -- ...and the next leg starts from where this one stopped, which is
        -- `want` back along the line just walked rather than on the corner.
        if raw > 0.0001 and i < #pts then
            local t = lens[i] / raw
            px = px + (pts[i].x - px) * t
            py = py + (pts[i].y - py) * t
        else
            px, py = pts[i].x, pts[i].y
        end
    end

    local n = #lens
    if n == 0 or mps <= 0.0 then return {}, 0.0 end

    local function blendFor(r, i)
        if n < 2 then return r end
        return 1.0 + (r - 1.0) * (n - i) / (n - 1)
    end

    local function secondsFor(r)
        local t = 0.0
        for i = 1, n do
            local b = blendFor(r, i)
            if b < 0.1 then b = 0.1 end
            t = t + lens[i] / (b * mps)
        end
        return t
    end

    -- Bisect on r. The time is strictly decreasing in r, so this converges from
    -- the clamp range itself -- no solution outside it is wanted anyway.
    local a, b = lo, hi
    if secondsFor(a) > target and secondsFor(b) > target then
        a = hi                        -- even the ceiling is too slow: take it
    elseif secondsFor(b) < target and secondsFor(a) < target then
        a = lo                        -- even the floor is too fast: take it
    else
        for _ = 1, 40 do
            local mid = (a + b) * 0.5
            if secondsFor(mid) > target then a = mid else b = mid end
        end
        a = (a + b) * 0.5
    end
    if a < lo then a = lo end
    if a > hi then a = hi end

    local out = {}
    for i = 1, n do out[i] = blendFor(a, i) end
    return out, secondsFor(a)
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

-- ---------------------------------------------------------------------------
-- The emotes
-- ---------------------------------------------------------------------------
--
-- ═══ FIVE GESTURES ON FIVE DIFFERENT CLOCKS ═══
--
-- All five are the owner's, 2026-08-29, and the only thing they have in common
-- is the ped they run on. They are collected here rather than sprinkled through
-- the sequence because the one rule that spans them is a rule about CONFLICT:
-- two animations on one ped is the last one winning, silently.
--
--   (a) THE FLIP, on a winning return, at the second-to-last walk point,
--       facing the camera. THE WALK PAUSES FOR IT, so a win is longer than a
--       loss by the length of the animation -- the eighteen seconds is the
--       WALK; this is on top.
--   (b) THE STRETCH, thirty seconds after the ped is parked, once per lobby
--       view, and not while the locker is open.
--   (c) THE THUMBS UP, on readying up, for 600ms, and then ClearPedTasks --
--       which MUST run before the fade if the ready is accepted. A ped that
--       fades out mid-emote and arrives in warmup still playing it is the
--       failure, so this is the one whose ordering is load-bearing.
--   (d) THE WAVE, when the CAMERA reaches its second-to-last node. Different
--       clock from (a) and they will usually not coincide: the ped is still
--       walking when the camera gets there, so this is the one emote that has
--       to play OVER a walk -- upper body plus the secondary flag (48).
--   (e) THE WAIT, while my squad has readied up and is waiting on me.
--
-- AND (a) BEATS (d) WHERE THEY MEET. Owner, 2026-08-29: "If that overlap
-- happens - prefer the flip." Because the flip PAUSES the walk, the camera can
-- easily reach its second-to-last node while the flip is still playing -- so
-- the wave is not queued and not played afterwards, it is SKIPPED. See waveNow.

--- @return table
local function emoteCfg()
    return cfg().emotes or {}
end

--- Stream one animation dictionary, bounded.
---
--- SAME SHAPE AS client/attachtune.lua's ensureDict AND FOR THE SAME REASONS:
--- HasAnimDictLoaded is a BOOL native that answers 1/0 on some builds (see
--- isTrue at the top of this file -- a raw read here is a wait that does not
--- wait, and then TaskPlayAnim on a dictionary that is not in memory, which
--- does nothing at all and says nothing), and the wait has a ceiling because a
--- dictionary that will not stream must cost one gesture rather than a walk
--- that stops halfway up the path.
--- @param dict string
--- @param mine number|nil  the token, when called from a sequence thread
--- @return boolean
local function ensureDict(dict, mine)
    if not dict or not RequestAnimDict or not HasAnimDictLoaded then return false end
    if isTrue(HasAnimDictLoaded(dict)) then return true end

    RequestAnimDict(dict)
    local deadline = GetGameTimer() + (emoteCfg().dictWaitMs or 2000)
    while GetGameTimer() < deadline do
        if mine and token ~= mine then return false end
        if isTrue(HasAnimDictLoaded(dict)) then return true end
        Citizen.Wait(50)
    end
    if not isTrue(HasAnimDictLoaded(dict)) then
        print(('[br_core] lobby emote: "%s" never streamed'):format(tostring(dict)))
        return false
    end
    return true
end

--- Start one emote on the player ped. Must be called from a thread.
--- @param e table       { dict, clip, flags, ms }
--- @param mine number|nil
--- @param ms number|nil  override the configured duration; -1 plays it out
--- @return boolean
local function playEmote(e, mine, ms)
    if not e or not e.dict or not e.clip or not TaskPlayAnim then return false end
    if not ensureDict(e.dict, mine) then return false end
    if mine and token ~= mine then return false end

    local dur = math.floor(ms or e.ms or 2000)
    TaskPlayAnim(PlayerPedId(), e.dict, e.clip, 8.0, -8.0, dur,
        e.flags or 0, 0.0, false, false, false)
    emoting = e
    emoteUntil = (dur > 0) and (GetGameTimer() + dur) or nil
    return true
end

--- Take whatever emote is playing off the ped.
---
--- ClearPedTasks, WHICH IS ALSO WHAT ENDS A WALK -- so this is only ever called
--- on a ped that is standing still, or by (c), where taking the walk with it is
--- the point. The one emote that plays over a walk (the wave) is given an
--- explicit duration instead and ends by itself, because clearing it here would
--- clear the leg underneath it.
local function clearEmote()
    if not emoting then return end
    emoting, emoteUntil = nil, nil
    if ClearPedTasks then ClearPedTasks(PlayerPedId()) end
end

--- Is the ped standing on its mark with nothing to do?
--- @return boolean
local function parked()
    return parkedAt ~= nil
        and BR.State.me.state == BR.PlayerState.LOBBY
        and phase ~= RUNNING
end

-- ═══ DID I WIN THE MATCH I HAVE JUST COME HOME FROM? ═══
--
-- TAKEN FROM THE VERDICT SCREEN'S OWN PAYLOAD rather than recomputed here, and
-- that is the point: client/state.lua works "won" out as placement == 1 AND not
-- having died, using a `diedThisMatch` flag that is private to that file and
-- exists because a corpse can be first on the list when everyone else
-- disconnects. Two definitions of winning would eventually disagree, and the
-- one the player already read on their screen is the one they will expect the
-- ped to celebrate.
--
-- A LATCH, CONSUMED BY THE ENTRANCE. The summary lands seconds after the match
-- ends and the entrance starts twenty seconds after THAT, so it has to survive
-- the gap; begin() takes it and clears it, so one win buys one flip.
local wonLast = false
local winThisRun = false

AddEventHandler('br:ui:sendLocal', function(kind, d)
    if kind ~= BR.Nui.SUMMARY then return end
    wonLast = type(d) == 'table' and d.won == true
end)

--- Turn to face the camera and play the winner's flip. Pauses the walk.
---
--- "If the player is coming back to lobby from a match which they won - have
--- the ped play the 'flip' emote at the 2nd to last walk point, then once the
--- animation is done, they walk to the final point" -- and, separately, "please
--- make sure the flip happens facing the camera :)" (owner, 2026-08-29).
---
--- FACING IS ASKED OF THE ENGINE, NOT COMPUTED FROM THE PLAN. The flight plan
--- says where the camera is HEADED; the interpolation says where it actually
--- is, and by the second-to-last walk point those differ by however far the
--- walk and the flight have drifted. BR.LobbyCam.pos reads the live camera.
---
--- AND IT TURNS RATHER THAN SNAPPING. SetEntityHeading here would be a ped
--- spinning on the spot one frame before a backflip, which is the same
--- complaint as every other snap in this file.
--- @param mine number
local function doFlip(mine)
    local e = emoteCfg().win
    if not e or not e.dict then return end

    -- ═══ AND THE WAVE IS SPENT THE MOMENT THIS STARTS ═══
    --
    -- Owner, 2026-08-29: "If that overlap happens - prefer the flip."
    --
    -- SET HERE RATHER THAN CHECKED LATER, and that is the whole of it. The walk
    -- is paused for the length of this animation, so the camera's own cue
    -- routinely lands DURING it -- and the leg loop, which is what polls that
    -- cue, is not running to see it. Left unspent, the wave would fire on the
    -- first poll after the flip finished, which is "immediately after it" and is
    -- precisely what he ruled out. A wave that already played earlier in the
    -- walk is unaffected; this only closes the door in front.
    waved = true

    local ped = PlayerPedId()
    if ClearPedTasks then ClearPedTasks(ped) end

    local cx, cy, cz = BR.LobbyCam.pos()
    if cx then
        if TaskTurnPedToFaceCoord then
            local turn = math.floor(e.turnMs or 500)
            TaskTurnPedToFaceCoord(ped, cx, cy, cz, turn)
            local until_ = GetGameTimer() + turn
            while token == mine and GetGameTimer() < until_ do Citizen.Wait(50) end
        else
            local c = GetEntityCoords(ped)
            SetEntityHeading(ped, BR.GtaHeading(BR.Bearing(c.x, c.y, cx, cy)))
        end
    end
    if token ~= mine then return end

    -- -1 PLAYS THE CLIP OUT rather than cutting it at a number somebody guessed.
    -- `ms` is the ceiling under that, because a clip that never reports itself
    -- finished would park the ped one leg short of the lobby forever.
    if playEmote(e, mine, -1) then
        local cap = GetGameTimer() + math.floor(e.ms or 3200)
        Citizen.Wait(200)   -- one beat for the task to actually be running
        while token == mine and GetGameTimer() < cap do
            -- IsEntityPlayingAnim IS A BOOL NATIVE. A bare read here is a wait
            -- that never waits (0 is truthy) or one that never ends.
            if not IsEntityPlayingAnim
               or not isTrue(IsEntityPlayingAnim(PlayerPedId(), e.dict, e.clip, 3)) then
                break
            end
            Citizen.Wait(50)
        end
    end

    emoting, emoteUntil = nil, nil
    if token == mine and ClearPedTasks then ClearPedTasks(PlayerPedId()) end
end

--- Wave, over the top of the walk, when the camera gets near home.
---
--- ═══ AND THE FLIP BEATS IT ═══
---
--- Owner, 2026-08-29: "If that overlap happens - prefer the flip." The flip
--- pauses the walk and the flight does not, so on a winning return the camera
--- will often reach its second-to-last node while the ped is mid-backflip.
--- `waved` is set either way, so a wave that lost this race is SKIPPED rather
--- than queued -- there is no later moment at which it would be the right
--- gesture.
--- @param mine number
local function waveNow(mine)
    waved = true
    local e = emoteCfg().wave
    if not e then return end
    -- Anything already on the ped wins, which on a winning return is the flip.
    if emoting then return end
    playEmote(e, mine)
end

--- Is the screen genuinely showing the lobby yet?
---
--- ═══ THE ONE CUE BOTH HALVES OF THE ENTRANCE WAIT ON ═══
---
--- See the header: the walk used to start the instant begin() was called while
--- the flight waited for the fade, and on every road home except the boot there
--- is a cover still up at that moment -- a fade the trip started, or the leaving
--- curtain, which is a NUI layer the game's own fade natives know nothing
--- about. So the ped walked its opening leg where nobody could see it.
---
--- THREE THINGS, AND THE THIRD IS THE ONE THAT WAS MISSING. worldReady is the
--- boot's loading screen; IsScreenFadedIn is the game fade; curtainWanted is
--- br_ui's opaque layer, and it is the longest of the three by several seconds.
--- @return boolean
local function revealed()
    if BR.State.worldReady == false then return false end
    if not isTrue(IsScreenFadedIn()) then return false end
    -- Asked-for rather than acknowledged: the curtain is lowered by a message
    -- to the page, and waiting for the page to confirm it has FADED OUT would
    -- hold the walk for a transition nothing reports the end of.
    if BR.Spawn and BR.Spawn.curtainWanted then return false end
    return true
end

--- Hold this thread until the screen is uncovered. Bounded.
---
--- A COVER THAT NEVER LIFTS MUST COST A WALK THAT STARTS ANYWAY, which is the
--- same trade every other wait in this file makes. The ceiling sits inside
--- br_ui's own 15s curtain watchdog, so a stuck curtain still gets its walk.
--- @param mine number
--- @return boolean  false when the sequence was abandoned while waiting
local function awaitReveal(mine)
    local deadline = GetGameTimer() + (cfg().revealWaitMs or 10000)
    while token == mine and GetGameTimer() < deadline do
        if revealed() then return true end
        Citizen.Wait(50)
    end
    return token == mine
end

--- Fly the camera down to meet the ped. Runs alongside the walk.
---
--- ═══ ONE CURVE, DECELERATING, AND IT DOES NOT WATCH THE PED ═══
---
--- The shape of the flight -- a Catmull-Rom spline through the authored nodes,
--- resampled into equal-duration steps whose lengths decay exponentially -- is
--- BR.LobbyCam.flightPlan, and the long note above it is why. All this does is
--- issue the plan against a clock.
---
--- THE BOUNDARIES ARE ABSOLUTE, measured from t0 rather than from "now", so the
--- frame each move is issued late is spent out of THAT move instead of being
--- added to the flight. Two dozen steps of accumulated drift would be a visible
--- hitch at the landing.
---
--- AND IT STILL DOES NOT READ THE PED. It used to hold at the last node until
--- the ped's measured arrival came within camLeadMs, which was the pause the
--- owner reported. The two are kept together by starting on the same cue and
--- being given the same duration, not by watching each other.
--- @param mine number  the token this thread belongs to
local function flyCamera(mine)
    local C = cfg()
    local plan, marks = BR.LobbyCam.flightPlan(C.camPath, C.camSteps or 24, C.camDecay or 0.0)
    if #plan < 2 then return end

    -- WHERE THE WAVE IS CUED. The camera's "second-to-last position" is the
    -- last authored node -- the lobby frame is the last one -- and after the
    -- resampling no single move ends there, so it is a fraction of the flight
    -- rather than a move index.
    local waveAt = marks[#marks - 1] or 1.0

    if not awaitReveal(mine) then return end
    if token ~= mine then return end

    local flight = C.camFlightMs or 18000
    local steps = #plan - 1
    local t0 = GetGameTimer()
    flightBegan = t0

    for i = 2, #plan do
        local boundary = t0 + math.floor(flight * (i - 1) / steps)
        local ms = boundary - GetGameTimer()
        if ms < 1 then ms = 1 end

        BR.LobbyCam.glideTo(plan[i], ms)

        while token == mine do
            local left = boundary - GetGameTimer()
            if left <= 0 then break end
            Citizen.Wait(left > 50 and 50 or left)
        end
        if token ~= mine then return end

        if plan[i].at >= waveAt then camNearHome = true end
    end

    flightEnded = GetGameTimer()
    camLanded = true
end

--- Put the ped on the start mark and raise the first shot over it.
---
--- ═══ SYNCHRONOUS, AND THAT IS THE POINT ═══
---
--- This is a teleport up the path, and it has to happen under cover -- it is
--- the "arriving ped pops into the shot" this whole file exists to remove. On
--- the boot road the cover is the loading screen and there is all the time in
--- the world. On the TRIP HOME it is BR.Spawn.toLobby's fade, which lifts a
--- line after the trip lets go -- so the placement is done in the caller's own
--- frame rather than on the entrance thread's first resume, and toLobby calls
--- BR.LobbyPed.startNow() while it is still black.
---
--- THE WALK THAT FOLLOWS IT DOES NOT START HERE. See awaitReveal: the ped is
--- placed under the cover and then waits, frozen, for the cover to lift.
local function placeOnStart()
    local C = cfg()
    local ped = PlayerPedId()
    local s = startMark()
    if not s then return end

    RequestCollisionAtCoord(s.x, s.y, s.z)
    SetEntityCoordsNoOffset(ped, s.x, s.y, s.z, false, false, false)
    SetEntityHeading(ped, s.heading + 0.0)
    FreezeEntityPosition(ped, true)

    -- THE CAMERA'S FIRST SHOT, RAISED UNDER THE BLACK. No interpolation: there
    -- is nothing to blend from. Taken from the flight plan rather than from the
    -- authored node so the raise and the first move agree about where the
    -- camera is pointed -- built separately they disagreed by the difference
    -- between the surveyed heading and the aim point, which is a snap on the
    -- first frame of the flight.
    local plan = BR.LobbyCam.flightPlan(C.camPath, C.camSteps or 24, C.camDecay or 0.0)
    if plan[1] then BR.LobbyCam.placeAt(plan[1]) end
end

--- The whole entrance, from the black screen to the ped standing on its mark.
--- The ped is already on its start mark when this begins -- see placeOnStart.
--- @param mine number
local function run(mine)
    local C = cfg()
    local ped = PlayerPedId()

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

    -- 4b. THE EMOTE DICTIONARIES THIS ENTRANCE MIGHT NEED, STREAMED NOW.
    --
    --     UNDER THE COVER, WITH THE MODEL AND THE CLIPSET, and that is the
    --     whole reason they are here rather than at the moment they are played.
    --     The wave fires mid-walk off the camera's clock and the flip fires
    --     between two legs; a two-second stream wait at either of those moments
    --     is a ped standing still in plain sight. Bounded, and a dictionary
    --     that does not arrive costs its gesture and nothing else.
    do
        local E = emoteCfg()
        if E.wave then ensureDict(E.wave.dict, mine) end
        if winThisRun and E.win then ensureDict(E.win.dict, mine) end
    end
    if token ~= mine then return end

    -- 5. AND NOW IT WAITS FOR SOMEBODY TO BE LOOKING.
    --
    --    See awaitReveal and the header. The ped is standing on its mark under
    --    whatever cover the road home was holding -- a fade, or the leaving
    --    curtain -- and starting the walk here is how four or five seconds of
    --    it were spent behind that cover. Bounded: a cover that never lifts
    --    costs a walk that starts anyway.
    if not awaitReveal(mine) then return end
    if token ~= mine then return end
    ped = PlayerPedId()

    -- 6. AND NOW IT MAY MOVE. client/natives.lua re-freezes a LOBBY ped every
    --    frame, so `walking` is what stands that rule down -- setting it before
    --    the unfreeze rather than after is the difference between a walk and a
    --    single frame of one.
    walking = true
    walkBegan = GetGameTimer()
    FreezeEntityPosition(ped, false)

    local radius = C.arriveRadius or 0.9
    local legMs = C.legTimeoutMs or 15000

    -- ═══ AND THE LAST LEG IS WALKED ONTO THE MARK, NOT NEAR IT ═══
    --
    -- Owner, 2026-08-29: "the ped is getting close to the final coords, but then
    -- being teleported there."
    --
    -- IT WAS `arriveRadius`, AND IT WAS DOING EXACTLY WHAT IT SAYS. Every leg
    -- stopped being walked the moment the ped was within 0.9m of its corner --
    -- fine at a corner, where the ped simply turns and carries on and the 0.9m
    -- is walked off on the next leg. But the LAST corner is the lobby mark, and
    -- what comes after it is standOnMark(): SetEntityCoordsNoOffset onto the
    -- exact spot. So the entrance ended by snapping the ped the last 0.9m,
    -- face-on, six feet from a camera that had already landed. There was no
    -- second teleport to find -- the arrival WAS the teleport.
    --
    -- So the final leg gets its own radius, small enough that what is left for
    -- standOnMark to correct is under the width of a boot.
    local markRadius = C.markRadius or 0.15

    -- ═══ A SPEED PER LEG, DERIVED, RAMPING DOWN TO A WALK ═══
    --
    -- Owner, 2026-08-29: "Each walk should take the exact same amount of time,
    -- and be faster at the first steps when necessary, before slowing down to a
    -- normal pace for the last walk."
    --
    -- SOLVED IN begin(), NOT HERE, because the loading gate and /brlobbywalk
    -- both want the answer and a second solve could differ from the one being
    -- walked. See blendPlan for the shape of it and why it is not a list in
    -- config any more.
    local function speedFor(i)
        return blends[i] or blends[#blends] or 1.0
    end

    -- ═══ WHICH WAY THE PED IS ASKED TO FACE AT EACH CORNER ═══
    --
    -- Owner, 2026-08-29: "it seems the ped walks to the point, stops, turns,
    -- then walks to the next point. Can we maybe smooth the corners to keep
    -- them walking?"
    --
    -- HALF OF THAT TURN WAS ASKED FOR, IN WRITING, BY THIS CALL. The seventh
    -- argument to TaskGoStraightToCoord is `targetHeading` -- the way the ped
    -- faces once it gets there -- and every leg was handing it `n.heading`, the
    -- heading authored on the corner in config. Those headings are where the
    -- OWNER HAPPENED TO BE LOOKING when he surveyed each point, and two of the
    -- three are the direction he had just walked IN from:
    --
    --   pedPath[2] heading 218.7  -- the next corner is 82 degrees off it
    --   pedPath[3] heading 304.5  -- the next corner is 88 degrees off it
    --
    -- So the ped was being told to arrive, turn most of a right angle to face
    -- backwards, and only then given its next leg -- which turned it back. The
    -- facing at a corner is not a surveyed fact, it is a consequence of where
    -- the path goes next, so it is COMPUTED from the path.
    --
    -- THE LAST ONE IS DIFFERENT AND KEEPS ITS AUTHORED HEADING. The lobby mark
    -- is not a corner, it is the camera's subject: BR.Config.Match.lobbyPos's
    -- heading is what the whole lobby shot is composed against.
    local function headingFor(i)
        if i >= #path then return path[i].heading + 0.0 end
        local a, b = path[i], path[i + 1]
        return BR.GtaHeading(BR.Bearing(a.x, a.y, b.x, b.y))
    end

    -- ═══ AND THE OTHER HALF OF THE TURN WAS THE HANDOVER BEING LATE ═══
    --
    -- Each leg is its own go-to-coord task, and a go-to-coord task ENDS AT
    -- REST -- the ped slows down over the last couple of metres so that it
    -- stops on the coordinate rather than overshooting it. The next leg was
    -- only tasked once the ped was within `arriveRadius` (0.9m) of the corner,
    -- by which point that deceleration has already happened: the ped had
    -- finished stopping before it was told to keep going.
    --
    -- So an intermediate corner hands over EARLY, while the ped is still at
    -- speed, and the corner gets rounded rather than touched. Clamped to a
    -- fraction of the leg actually being walked, so a short leg can never be
    -- swallowed whole by its own corner, and never later than arriveRadius so
    -- this can only ever hand over sooner than it used to.
    local corner = C.cornerRadius or 2.0

    -- ═══ AND THE FAILSAFE IS THE CAMERA'S CLOCK, NOT THE LEG'S ═══
    --
    -- Owner, 2026-08-29: "if the ped doesn't get to the destination within 5
    -- seconds of the camera parking we fire that function and bring them to the
    -- position ourselves."
    --
    -- SO IT IS ONE DEADLINE FOR THE WHOLE REMAINING WALK rather than a per-leg
    -- one. A ped that is behind is behind for the rest of the path, and the
    -- thing the player is looking at is the landed shot with nobody in it --
    -- which is a fact about the camera, so the camera is what it hangs off.
    --
    -- THE FLIP IS EXCLUDED BY NOT STARTING THE CLOCK. `flipEnded` is written
    -- when the animation is genuinely over; until then this answers nil and
    -- nothing can fire. A winning return pauses for several seconds at the
    -- second-to-last point ON PURPOSE, and teleporting the winner out of their
    -- own victory animation is the one outcome this must never produce.
    --
    -- legTimeoutMs AND THE STALL ESCAPE BOTH STAY, as the floor underneath:
    -- they cover the window BEFORE the camera has landed, where this has
    -- nothing to hang off and a ped wedged on geometry would otherwise wait out
    -- the whole flight.
    local grace = C.arriveGraceMs or 5000
    local function graceExpired()
        if not camLanded or not flightEnded then return false end
        -- THE CLOCK RUNS FROM WHICHEVER CAME LATER. One line, and it is the
        -- whole of the flip exclusion: a pause that ended after the camera
        -- parked pushes the deadline out by exactly its own length.
        local from = flightEnded
        if flipEnded and flipEnded > from then from = flipEnded end
        return (GetGameTimer() - from) > grace
    end

    -- Set when the failsafe fires, so the loop below abandons the REST of the
    -- path rather than the leg it happened to be on -- the destination is the
    -- mark, not the next corner.
    local forced = false

    for i = 1, #path do
        if token ~= mine then return end
        local n = path[i]
        local last = (i == #path)

        -- ═══ THE WINNER FLIPS AT THE SECOND-TO-LAST POINT ═══
        --
        -- Which is HERE: the ped has arrived at path[#path - 1] and has not yet
        -- been given the last leg. "then once the animation is done, they walk
        -- to the final point" -- so the walk genuinely stops for it, and a
        -- winning return is longer than a losing one by the length of the clip.
        -- The eighteen seconds is the WALK.
        if last and winThisRun then
            doFlip(mine)
            if token ~= mine then return end
            -- AND THE PAUSE IS RECORDED HERE RATHER THAN INSIDE doFlip, so it
            -- is recorded even on the roads doFlip returns early on -- a missing
            -- clip, a config with no `win` entry. A failsafe whose clock depends
            -- on an animation having played is a failsafe that never fires for
            -- a winner whose animation did not.
            flipEnded = GetGameTimer()
        end

        ped = PlayerPedId()

        local from = GetEntityCoords(ped)
        local legLen = BR.Dist(from.x, from.y, n.x, n.y)

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
            legMs, headingFor(i), 0.0)

        local want
        if last then
            want = markRadius
        else
            want = math.min(corner, legLen * 0.4)
            if want < radius then want = radius end
        end

        -- AND A PED THAT HAS STOPPED SHORT IS NOT GOING TO GET CLOSER.
        --
        -- The tight final radius asks the engine for more precision than
        -- TaskGoStraightToCoord is documented to promise -- unverified either
        -- way, and the failure if it will not give it is the ugly one: the ped
        -- standing on the mark for the whole legTimeoutMs before the sequence
        -- notices. So the leg also ends when the ped has stopped IMPROVING
        -- while already inside the ordinary radius. Measured off the distance
        -- rather than off GetEntitySpeed, because a ped shuffling on the spot
        -- has a speed and is still not arriving.
        local best, stuck = math.huge, 0
        local until_ = GetGameTimer() + legMs
        while token == mine and GetGameTimer() < until_ do
            -- THE WAVE RIDES THE WALK, and this is the only place that can see
            -- both clocks at once. Its cue is the CAMERA reaching its
            -- second-to-last position (flyCamera sets the flag) while the ped
            -- is still somewhere on its path -- the two will usually not line
            -- up with any particular leg, which is why this is a poll and not
            -- an event on a corner.
            --
            -- NO YIELD HERE: the dictionary was streamed under the cover, so
            -- playEmote is one native and the leg's distance poll keeps its
            -- 50ms cadence.
            if camNearHome and not waved then waveNow(mine) end

            if graceExpired() then
                forced = true
                print(('[br_core] lobby entrance: the ped was still %d leg(s) '
                    .. 'out %dms after the camera parked -- placing it')
                    :format(#path - i + 1, grace))
                break
            end

            local c = GetEntityCoords(PlayerPedId())
            local d = BR.Dist(c.x, c.y, n.x, n.y)
            if d <= want then break end
            if d < best - 0.01 then best, stuck = d, 0 else stuck = stuck + 50 end
            if last and d <= radius and stuck >= STALL_MS then break end
            Citizen.Wait(50)
        end
        if forced then break end
    end
    if token ~= mine then return end

    walkEnded = GetGameTimer()

    -- 6. ARRIVED. The walking style is cleared here because the owner asked for
    --    it here ("On arrival, clear the walking style"), and stop() clears it
    --    again on every other ending -- the two are not redundant, they are the
    --    happy path and every other path.
    walking = false
    standOnMark()
    -- THE CLOCK THE PARKED EMOTE RUNS ON starts here and only here: on the
    -- ARRIVAL, not on any other ending. "once the ped is parked" means the walk
    -- finished, not that it was abandoned halfway into a warmup.
    parkedAt = GetGameTimer()
    BR.LobbyPed.stop('arrived')
end

--- Begin. Called by the tick below, and by BR.LobbyPed.startNow.
local function begin()
    phase = RUNNING
    token = token + 1
    local mine = token

    -- ═══ ONE OF FOUR, DRAWN HERE AND NOWHERE ELSE ═══
    --
    -- Owner, 2026-08-29: four surveyed spawns and paths, "one of the four is
    -- chosen at random per lobby entrance". Drawn ONCE, into a file-local, so
    -- the walk, the loading gate and /brlobbywalk are all looking at the same
    -- draw -- a case re-rolled per reader is four different walks at once.
    local cases = cfg().pedCases or {}
    caseIndex = (#cases > 0) and math.random(#cases) or 0

    path = legs()
    local first = startMark()
    blends = first and (blendPlan(first, path)) or {}

    camLanded = false
    camNearHome = false
    walkBegan, walkEnded = nil, nil
    flightBegan, flightEnded = nil, nil

    -- THE EMOTE STATE IS PER LOBBY VIEW, AND THIS IS WHERE A LOBBY VIEW BEGINS.
    -- "make sure it only plays once per lobby view" -- so the stretch's latch is
    -- cleared by an ENTRANCE rather than by a timer or by the state changing:
    -- an entrance is exactly the thing that makes this a new view of the lobby.
    idlePlayed = false
    parkedAt = nil
    waved = false
    flipEnded = nil
    emoting, emoteUntil = nil, nil

    -- The win is consumed rather than read: one win, one flip.
    winThisRun = wonLast
    wonLast = false

    setLocked(true)

    -- BEFORE THE THREADS, NOT ON THEM. See placeOnStart: the teleport onto the
    -- start mark has to be inside the caller's frame, because on the trip home
    -- the caller is holding the black it needs.
    placeOnStart()

    Citizen.CreateThread(function() flyCamera(mine) end)
    Citizen.CreateThread(function() run(mine) end)

    print(('[br_core] lobby entrance begins (case %d, %d legs%s)')
        :format(caseIndex, #path, winThisRun and ', winner' or ''))
end

--- Am I standing in the lobby, by the only test that cannot be argued with?
---
--- STATE IS NOT ENOUGH AND THIS IS THE GUARD THAT PROVES IT. The server sets a
--- player to LOBBY the moment a match is decided -- seconds before
--- BR.Spawn.toLobby has taken them anywhere -- so an entrance armed on state
--- alone would fire while the ped was still standing in Los Santos over a
--- verdict slam, and its first act would be a forty-kilometre teleport in plain
--- sight. Asking where the ped IS costs one native and cannot be raced.
--- @return boolean
local function atTheLobby()
    local p = BR.Config.Match.lobbyPos
    local c = GetEntityCoords(PlayerPedId())
    return BR.Dist(c.x, c.y, p.x, p.y) <= HERE_M
end

--- May the entrance start right now?
--- @param allowTraveling boolean|nil  the caller IS the trip (see startNow)
--- @return boolean
local function mayBegin(allowTraveling)
    if phase ~= ARMED then return false end
    if BR.State.me.state ~= BR.PlayerState.LOBBY then return false end
    if not atTheLobby() then return false end
    if not allowTraveling then
        -- A TRIP OWNS THE PED WHILE IT IS IN FLIGHT. BR.Spawn.toLobby is
        -- routinely running underneath the loading screen on a fresh join
        -- (client/loading.lua explains why), and starting a walk out of a
        -- teleport that has not landed would race it for the ped's position.
        if BR.Spawn and BR.Spawn.traveling then return false end
        if BR.Spawn and BR.Spawn.holdBlack then return false end
    end
    return true
end

--- Take the entrance NOW, under the black the caller is holding.
---
--- CALLED BY BR.Spawn.toLobby, which is the one road home from anywhere: the
--- end of a match, /brleave, the server's TO_LOBBY, and the lobby watchdog all
--- go through it. The trip has already put the ped on the lobby mark and is
--- about to fade in; the placement has to be finished before it does.
---
--- It refuses on every road where it is not wanted (already run, not in the
--- lobby, ped nowhere near the mark) and the tick below is still the net under
--- every other way of ending up standing here.
--- @param fromTrip boolean|nil  true ONLY when the caller is the trip itself,
---        which is the one caller allowed to be `traveling` -- anybody else
---        asking while a trip is in flight is racing it for the ped.
--- @return boolean  whether an entrance was started
function BR.LobbyPed.startNow(fromTrip)
    if not mayBegin(fromTrip == true) then return false end
    begin()
    return true
end

-- WHEN. The same shape as the lobby camera's own follow tick, and for the same
-- reason: enumerating the roads into the lobby is how the old rules kept
-- missing one. This asks "should it start? has it?" ten times a second.
--
-- IT WAITS FOR THE CHARACTER TO BE ON THE PLAYER, not merely for the state to
-- say lobby -- see step 3 of run(), and client/loading.lua's own note on the
-- four different moments "fully spawned in" could mean.
--
-- ═══ AND IT RE-ARMS, BECAUSE THE ENTRANCE IS NOT A BOOT SEQUENCE ═══
--
-- Owner, 2026-08-29: "Also let's make that grand entry happen for every trip
-- back to the lobby. That was my expectation."
--
-- RE-ARMED ON LEAVING RATHER THAN ON ARRIVING, which is the same argument the
-- latch below makes and it is the reason this is not a list of events. There
-- are several ways to end up back on the lobby mark -- the end of a match,
-- /brleave, an admin resetting a stuck round, br_core restarting under a player
-- who is already standing there -- and every one of them is preceded by the one
-- fact this can watch: I am not in the lobby. So leaving is what re-arms, and
-- arriving is what fires, and no road has to be remembered.
--
-- askedAt GOES WITH IT. It is the loading screen's arm wait, which exists only
-- on the boot road; left set from that boot it would expire during the first
-- match and skip every entrance afterwards with "the reveal went ahead without
-- it", on a road that has no reveal at all.
BR.Loop.register(BR.Loop.TICK, 'lobbyped.entrance', function()
    if BR.State.me.state ~= BR.PlayerState.LOBBY then
        if phase == DONE then
            phase = ARMED
            askedAt = nil
        end
        -- AND THE PARKED CLOCK STOPS WITH THE LOBBY. `parkedAt` is "how long
        -- the ped has been standing on the mark with nothing to do", and a
        -- player in a match is not standing on the mark -- left running it
        -- would come home expired and fire the stretch into the middle of the
        -- next entrance.
        parkedAt = nil
        return
    end

    if phase ~= ARMED then return end

    -- AND IT GIVES UP IF THE SCREEN HAS ALREADY COME DOWN WITHOUT IT.
    --
    -- revealBlock() holds the loading screen for this sequence and then stops
    -- holding it, bounded, so a boot can never be parked on a walk that will
    -- not start. The other half of that bound is here: once the reveal has gone
    -- ahead, starting is WORSE than not starting -- the first thing begin() does
    -- is teleport the ped thirty metres up the path, and doing that in front of
    -- somebody is the pop this whole file exists to remove.
    if askedAt and GetGameTimer() - askedAt > (cfg().armWaitMs or 4000) then
        phase = DONE
        print('[br_core] lobby entrance: the reveal went ahead without it -- skipped')
        return
    end

    if not mayBegin(false) then return end

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

-- ---------------------------------------------------------------------------
-- The emotes that are not part of the walk
-- ---------------------------------------------------------------------------

-- WHETHER THE LOCKER SCREEN IS OPEN, off br_ui's focus stack.
--
-- br_ui owns the NUI focus and announces the top of the stack as an EDGE
-- (`br:ui:focusChanged`); the locker pushes 'locker' when it opens and pops it
-- when it closes. That is a better answer than anything br_core could work out
-- for itself: the question the owner asked -- "if they are not in the locker
-- screen" -- is about what is ON SCREEN, and the focus stack is the only thing
-- that knows.
AddEventHandler('br:ui:focusChanged', function(top)
    local was = inLocker
    inLocker = (top == 'locker')
    -- Leaving the locker does not start anything; walking INTO it stops what is
    -- running, because the emote and the locker are two things asking the ped
    -- to be in different places.
    if inLocker and not was and emoting and parked() then clearEmote() end
end)

-- WHETHER MY SQUAD HAS READIED UP AND IS WAITING ON ME.
--
-- Owner, 2026-08-29: "If they are in squads and their squad readies up and is
-- waiting on them, (so long as they are not in locker) play any variation of
-- 'wait*' emotes except 'wait 9'".
--
-- EVERYTHING THIS NEEDS IS ALREADY ON THE WIRE. LOBBY_STATUS carries the list
-- of server ids that have queued and the client already holds its own party --
-- client/state.lua resolves the same two facts into the "2/3 ready" the party
-- panel shows. A SECOND handler on the same event rather than a change to that
-- one: this is a different consumer of the same broadcast, and the departure
-- path in client/state.lua is not this round's to edit.
--
-- "IS WAITING ON ME" IS THREE THINGS, and all three have to hold: I am in a
-- party of more than one, every OTHER member has queued, and I have not.
RegisterNetEvent(BR.Net.LOBBY_STATUS)
AddEventHandler(BR.Net.LOBBY_STATUS, function(d)
    local members = BR.State.party and BR.State.party.members
    if type(members) ~= 'table' or #members < 2 then
        squadHolding = false
        return
    end

    local ids = {}
    for _, src in ipairs((d and d.ids) or {}) do ids[src] = true end

    local others, ready = 0, 0
    for _, m in ipairs(members) do
        if m.src ~= BR.State.me.src then
            others = others + 1
            if ids[m.src] then ready = ready + 1 end
        end
    end

    squadHolding = others > 0 and ready == others and not ids[BR.State.me.src]
end)

-- READYING UP: A THUMBS UP, 600ms, AND THEN THE TASK IS CLEARED.
--
-- Owner, 2026-08-29: "When they click ready up, play 'thumbs up 3' for 600ms
-- then clearpedtasks. Make sure clearpedtasks runs before fade to black if they
-- are accepted to warmup."
--
-- THE ORDERING IS THE LOAD-BEARING PART and it is guarded from BOTH ends.
--
--   * The clock. 600ms from the press, on a timer that does not care what the
--     server says. Acceptance is a round trip plus client/state.lua's cover
--     handshake plus BR.Spawn.toWarmupPad's own fade, so the emote is normally
--     long gone before anything goes dark.
--   * THE STATE EDGE, WHICH IS THE ONE THAT ACTUALLY PROMISES IT. A local
--     server can answer in single-digit milliseconds, so the timer alone would
--     be a race. The tick below clears on the frame my state stops reading
--     LOBBY -- which is the moment the server names me a participant, and that
--     is upstream of every cover: client/state.lua raises the curtain on that
--     same edge and the fade is behind the curtain's acknowledgement.
--
-- A SECOND HANDLER ON `br:ui:action`, alongside client/state.lua's. Both run;
-- this one only ever touches the ped.
AddEventHandler('br:ui:action', function(name)
    if name ~= BR.NuiCb.QUEUE then return end
    if BR.State.me.state ~= BR.PlayerState.LOBBY then return end

    local e = emoteCfg().ready
    if not e then return end

    Citizen.CreateThread(function()
        if not playEmote(e, nil) then return end
        Citizen.Wait(math.floor(e.ms or 600))
        -- Guarded: the walk may have started under us (a ready that was
        -- refused, an entrance the tick began), and clearing tasks then would
        -- take the walk with the gesture.
        if emoting == e and not walking then clearEmote() end
    end)
end)

-- THE PARKED PED. Two emotes live here and they are on different clocks: the
-- stretch is a timer and the wait is a live status.
BR.Loop.register(BR.Loop.TICK, 'lobbyped.emotes', function()
    -- LEAVING THE LOBBY TAKES THE GESTURE OFF THE PED IMMEDIATELY, and this is
    -- the ordering guarantee for the ready-up emote above: my state stops
    -- reading LOBBY the moment the server names me a participant, which is
    -- before any cover this client raises.
    if BR.State.me.state ~= BR.PlayerState.LOBBY then
        if emoting then clearEmote() end
        squadHolding = false
        return
    end

    -- AN EMOTE WITH A DURATION ENDS IN THE ENGINE AND SAYS NOTHING, so this is
    -- the only thing that can notice. Without it the latch sticks after the
    -- first gesture of the session and every emote after it refuses to start --
    -- silently, because "something is already playing" is not an error.
    if emoting and emoteUntil and GetGameTimer() >= emoteUntil then
        emoting, emoteUntil = nil, nil
    end

    if not parked() then return end

    -- THE SQUAD IS WAITING: FIRST CLAIM ON THE PED, because it describes
    -- something that is true RIGHT NOW and the stretch does not. It also stops
    -- the moment it stops being true.
    local E = emoteCfg()
    local waits = E.waiting
    if squadHolding and not inLocker then
        if not emoting and waits and type(waits.clips) == 'table' and #waits.clips > 0 then
            local pick = waits.clips[math.random(#waits.clips)]
            Citizen.CreateThread(function()
                playEmote({ dict = pick.dict, clip = pick.clip, waiting = true,
                            flags = waits.flags or 0, ms = waits.ms or 4000 }, nil)
            end)
        end
        return
    end

    -- ...and once the squad is no longer waiting, whatever was playing for that
    -- reason comes off rather than running its duration out over a lobby that
    -- has moved on.
    if emoting and emoting.waiting then clearEmote() end

    -- THE STRETCH: ONCE, THIRTY SECONDS IN, AND THAT IS ALL.
    --
    -- Owner, 2026-08-29: "once the ped is parked, if they are not in the locker
    -- screen, play the 'stretch 3' emote after 30 seconds, and make sure it only
    -- plays once per lobby view." Confirmed since: once and no rotation.
    --
    -- `idlePlayed` IS SET WHEN IT FIRES, NOT WHEN IT FINISHES, so a player who
    -- opens the locker halfway through it does not get a second one on the way
    -- out. The latch is reset by begin(), which is what a new lobby view is.
    if idlePlayed or inLocker or emoting then return end
    local e = E.idle
    if not e then return end
    if GetGameTimer() - parkedAt < (e.afterMs or 30000) then return end

    idlePlayed = true
    Citizen.CreateThread(function() playEmote(e, nil) end)
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
    print(('  camFlightMs  %d   (walkTargetMs %d)')
        :format(C.camFlightMs or 0, C.walkTargetMs or 0))
    print(('  camSteps     %d   camDecay %.2f'):format(C.camSteps or 0, C.camDecay or 0))
    print(('  walkMps      %.2f  blend %.2f..%.2f')
        :format(C.walkMps or 0, C.walkBlendMin or 0, C.walkBlendMax or 0))
    print(('  focusLeadMs  %d'):format(C.focusLeadMs or 0))
    print(('  cornerRadius %.2f'):format(C.cornerRadius or 0))
    print(('  markRadius   %.2f'):format(C.markRadius or 0))
    print(('  arriveGrace  %dms after the camera parks'):format(C.arriveGraceMs or 0))
    print(('  revealWaitMs %d   screen %s')
        :format(C.revealWaitMs or 0, revealed() and 'uncovered' or 'COVERED'))

    -- THE FLIGHT, STEP BY STEP, IN METRES PER SECOND. The whole point of the
    -- decay is that these numbers COME DOWN -- fast at the top of the column,
    -- slow at the bottom, and never back up. Printed sparsely because two dozen
    -- steps is a screen of console: the first, the last, and every fourth.
    local plan = BR.LobbyCam.flightPlan(C.camPath, C.camSteps or 24, C.camDecay or 0.0)
    local flight = C.camFlightMs or 18000
    if #plan > 1 then
        local per = flight / (#plan - 1)
        for i = 2, #plan do
            local a, b = plan[i - 1], plan[i]
            local len = BR.Dist3(a.x, a.y, a.z, b.x, b.y, b.z)
            if i == 2 or i == #plan or (i % 4) == 0 then
                local turn = math.abs((b.heading - a.heading + 540.0) % 360.0 - 180.0)
                print(('    step %2d    %6.1fm  %5dms  %5.1f m/s  turn %4.1f deg')
                    :format(i - 1, len, math.floor(per), len / (per / 1000.0), turn))
            end
        end
    end

    -- AND WHAT THE LAST RUN ACTUALLY TOOK. The two durations are meant to be
    -- equal now ("The camera flight and the walk should finish together"), so
    -- the gap is the number to read: near zero on an ordinary return, and the
    -- length of the flip early on a winning one, because the walk pauses for
    -- the flip and the flight does not.
    if walkBegan and walkEnded and flightBegan and flightEnded then
        print(('  last run     walk %.1fs, flight %.1fs, camera landed %.1fs early')
            :format((walkEnded - walkBegan) / 1000.0,
                    (flightEnded - flightBegan) / 1000.0,
                    (walkEnded - flightEnded) / 1000.0))
    else
        print('  last run     not measured yet')
    end

    -- ═══ THE CASE THAT WAS DRAWN, AND THE SPEEDS IT DERIVED ═══
    --
    -- ONE LINE PER LEG, IN ORDER, because the whole point is that they differ:
    -- a single averaged number would hide the thing being tuned. The last
    -- column is the leg's own predicted duration, and the total under it is
    -- what walkTargetMs is being solved against -- so if the MEASURED walk
    -- above and this total disagree, walkMps is wrong and nothing else is.
    local cases = C.pedCases or {}
    print(('  case         %d of %d'):format(caseIndex, #cases))
    local first = startMark()
    if first and #path > 0 and #blends > 0 then
        local px, py = first.x, first.y
        local secs = 0.0
        for i = 1, #path do
            local len = BR.Dist(px, py, path[i].x, path[i].y)
            local b = blends[i] or 1.0
            local t = len / (b * (C.walkMps or 1.4))
            secs = secs + t
            print(('    leg %d      %6.2fm  blend %.2f  %5.2fs'):format(i, len, b, t))
            px, py = path[i].x, path[i].y
        end
        print(('    total                              %5.2fs  (target %.2fs)')
            :format(secs, (C.walkTargetMs or 18000) / 1000.0))
    else
        print('    legs         not planned yet -- nothing has been drawn')
    end
    print(('  winner       %s'):format(winThisRun and 'yes -- the flip is on' or 'no'))

    if BR.State.me.state ~= BR.PlayerState.LOBBY then
        print('  not in the lobby -- nothing to replay')
        return
    end
    BR.LobbyPed.rearm()
    print('  re-armed; the entrance tick will start it')
end, false)
