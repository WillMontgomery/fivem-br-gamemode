-- Downed but not out: the client half.
--
-- EVERYTHING HERE IS PRESENTATION AND INPUT. The bleed timer, the revive
-- distance and the moment a downed player is finally eliminated all live on
-- the server (server/combat.lua) -- a client that strips this file out entirely
-- bleeds out at exactly the same second, holding a rifle and standing upright
-- while everybody else watches a body on the floor. That is why the DBNO_SET
-- handler lives here rather than in the mirror: unlike STORM_DAMAGE and
-- HIT_DAMAGE, nothing on this side is load-bearing for the outcome.
--
-- Two jobs:
--
--   1. BEING DOWN. Take the weapon away, put the player on the floor, keep
--      them there, and let them crawl -- which is the whole reason the state
--      looks different from death at a distance (owner, 2026-08-09): an enemy
--      across the street has to be able to tell "finish them" from "they are
--      already gone", and a body that moves is the only signal that carries
--      that far.
--
--   2. PICKING SOMEBODY UP. A hold on the interact key, reusing the crate
--      machinery rather than a second implementation of it.

BR = BR or {}
BR.Dbno = {}

local M = BR.Config.Match

-- What the server last told us about our OWN downed state. Held whole, because
-- the UI envelope is sent whole -- REVIVE_PROGRESS merges into this and the
-- merged copy goes across the bridge, so there is one shape and one writer.
local mine = { downed = false, bleedEndsAt = 0, reviverName = nil,
               revivePct = 0.0 }

-- The revive we are performing on somebody else, or nil.
local holding = nil   -- { target = src, from = ms }

-- Whether we have told the server we are holding. The key can be released and
-- re-pressed faster than the round trip, so the request is edge-driven.
local sentStart = false

-- --------------------------------------------------------------------------
-- Being down
-- --------------------------------------------------------------------------

--- Push the whole downed payload at the interface.
local function pushMine()
    TriggerEvent('br:ui:sendLocal', BR.Nui.DBNO, {
        downed      = mine.downed and true or false,
        bleedEndsAt = mine.bleedEndsAt or 0,
        reviverName = mine.reviverName,
        revivePct   = mine.revivePct or 0.0,
    })
end

-- THE DOWNED POSE.
--
-- WHAT WENT WRONG THE FIRST TIME, because it is the whole reason this is now
-- written the careful way. The first cut called
-- `SetPedMovementClipset(ped, 'move_crawl')`. `move_crawl` is an ANIMATION
-- DICTIONARY, not a locomotion clipset -- and handing a movement clipset
-- something that is not one does not fail, it puts the ped in BIND POSE. A
-- downed player stood there in a perfect T-pose (owner, in game). The clipset
-- request even reported success, which is how it got past the guard that was
-- supposed to catch exactly this.
--
-- So: no movement clipset unless somebody has watched one work. These are
-- animation dictionaries played as a loop, tried in order, and a build with
-- none of them lies still rather than T-posing. `/brcrawl` is the probe that
-- turns this list from a guess into a fact -- run it in game and the answer
-- decides what ships.
-- CHOSEN IN GAME, 2026-08-09: move_injured_ground / front_loop is the one that
-- looks like a downed player (owner, watching all four through /brcrawl). It is
-- first because first is what ships; the rest stay as the fallback chain and as
-- the record of what was actually compared.
local CRAWL_CANDIDATES = {
    { dict = 'move_injured_ground',       anim = 'front_loop'  },
    { dict = 'move_crawl',                anim = 'onfront_fwd' },
    { dict = 'combat@damage@writhe',      anim = 'writhe_loop' },
    { dict = 'random@dealgonewrong',      anim = 'idle_a'      },
}

-- The one that loaded, or false once every candidate has been tried and failed.
local crawl = nil

-- Whether the clip is running (true) or held on the frame it is on (false).
-- nil means "unknown", which makes the next decision write itself through
-- whatever it turns out to be -- the state after a re-task, where the engine
-- has just reset the playback rate under us.
local crawlMoving = nil

-- Where the player last asked to be, while they are not asking to move. See
-- the movement loop: this is what "stay put" is made of.
local hold = nil      -- { x = number, y = number } or nil

--- Did a shape test hit anything?
---
--- `hit == 1` ALONE IS NOT THE QUESTION. A FiveM native declared BOOL can hand
--- Lua a number or a boolean depending on the build, and this codebase carries
--- two scars from assuming otherwise (client/natives.lua compares both forms on
--- this very native; client/spawn.lua does the same on the screen fade). The
--- ray below is the only thing stopping a downed player crawling into the
--- geometry, and on a build that answers `true` the old comparison declined
--- every hit silently.
--- @param v any
--- @return boolean
local function didHit(v)
    return v == 1 or v == true
end

--- Where a label -- or a camera -- belongs over a body.
---
--- The head bone, via the one resolver the client has for it. Anchoring to the
--- ped's ORIGIN is what put the revive prompt above a standing player's head
--- while the player it pointed at was lying on the floor (owner, 2026-08-17);
--- client/squadmates.lua carries the long note and the fallback.
--- @param ped integer
--- @return number x, number y, number z
local function overhead(ped)
    if BR.Squadmates and BR.Squadmates.headAnchor then
        return BR.Squadmates.headAnchor(ped)
    end
    local c = GetEntityCoords(ped)
    return c.x, c.y, c.z + 0.6
end

--- Request a dictionary and wait a beat for it. Returns whether it landed.
--- @param dict string
--- @return boolean
local function loadDict(dict)
    if HasAnimDictLoaded(dict) then return true end
    -- DoesAnimDictExist first: requesting a name the game has never heard of
    -- is a streaming request that can never complete, so without this the
    -- 400ms wait below would be paid for every bad guess in the list.
    if DoesAnimDictExist and not DoesAnimDictExist(dict) then return false end

    RequestAnimDict(dict)
    local deadline = GetGameTimer() + 400
    while not HasAnimDictLoaded(dict) and GetGameTimer() < deadline do
        Citizen.Wait(0)
    end
    return HasAnimDictLoaded(dict)
end

--- The first candidate this build can actually play, or nil.
--- @return table|nil
local function resolveCrawl()
    if crawl ~= nil then return crawl or nil end

    for _, c in ipairs(CRAWL_CANDIDATES) do
        if loadDict(c.dict) then
            crawl = c
            print(('[br_core] dbno: downed pose is %s / %s'):format(c.dict, c.anim))
            return crawl
        end
    end

    crawl = false
    print('[br_core] dbno: no downed animation on this build -- downed players will lie still. Run /brcrawl.')
    return nil
end

-- THE POSE IS RESOLVED BEFORE ANYBODY IS KNOCKED DOWN, AND THAT IS A FIX
-- RATHER THAN AN OPTIMISATION.
--
-- resolveCrawl() is memoised for the session, so exactly ONE knock per session
-- ever pays the streaming wait: the first. That is why the owner's report is
-- always about the first fall they try -- every later knock reads the cached
-- answer and returns without yielding at all, so it never had the window.
--
-- The window is worth naming, because two separate things fall into it. The
-- knock's own thread resolves the pose BEFORE it touches the ped (so a fallen
-- body pays the wait instead of a standing one), which means up to 400ms in
-- which the ped has not been looked at and the engine is still finishing the
-- death that caused the knock. And dbno.controls -- a FRAME callback -- calls
-- playCrawl on its watchdog pass, which reaches the same wait: a yield inside a
-- frame callback stalls the whole band until the dictionary lands.
--
-- Asking here costs one streaming request at boot and closes both. Best-effort
-- by design: if it fails, or the resource starts before the streamer is ready,
-- resolveCrawl still does the whole job on the first knock exactly as before --
-- this only takes the cost off the one path where it is measured in a player
-- dying wrong.
Citizen.CreateThread(function()
    -- Not on the first frame of the resource. The streamer is still bringing
    -- the world up and a request made into that is the one most likely to be
    -- dropped -- and nothing can be knocked down for a whole lobby yet.
    Citizen.Wait(5000)
    resolveCrawl()
end)

--- Start (or restart) the downed loop on our own ped.
--- @param force boolean|nil  play even if something is already running
--- @param snap boolean|nil   arrive at the pose with no blend at all
local function playCrawl(force, snap)
    local c = resolveCrawl()
    if not c then return end

    local ped = PlayerPedId()
    if not force and IsEntityPlayingAnim(ped, c.dict, c.anim, 3) then return end

    -- THE LAST THREE BOOLEANS ARE THE MOVER, AND ALL THREE USED TO BE FALSE.
    --
    -- "There's no way for a DBNO player to stop crawling" (owner, 2026-08-17).
    -- The comment that used to sit here said the clip "plays IN PLACE", and
    -- nothing ever made that true. `move_injured_ground` is a LOCOMOTION
    -- dictionary: its clips carry the translation the move blender normally
    -- extracts and turns into velocity, and TaskPlayAnim applies that
    -- translation to the ped unless the lock flags tell it not to. A player
    -- who let go of the keyboard went on crawling, because the animation --
    -- not the input -- was driving them.
    --
    -- lockX/lockY stop the clip pushing the ped across the ground. Z is left
    -- free so gravity still owns their height. Whether these flags bite is the
    -- engine's answer and not one that can be read off a file, which is
    -- exactly why the hold in dbno.controls exists as well: that one measures
    -- the ped's position and puts it back, so a downed player stays put
    -- whatever the clip is doing.
    --
    -- `snap` is the resurrection case. The pose being blended FROM there is a
    -- standing idle the player must never see, so it is not blended from.
    local blend = snap and 1000.0 or 8.0
    TaskPlayAnim(ped, c.dict, c.anim, blend, -blend, -1, 1, 0.0,
                 true, true, false)
    -- A fresh task runs at rate 1.0 whatever we last asked for.
    crawlMoving = nil
end

--- Run the crawl clip, or hold it still on the frame it is on.
---
--- THE OTHER HALF OF "STOP CRAWLING". Pinning the ped's coordinates stops them
--- travelling; it does not stop them ANIMATING, and a downed player who has let
--- go of everything and is still visibly hauling themselves forward is the same
--- report in a different form. The clip is a loop, so holding it costs nothing
--- and releasing it resumes from where it was.
---
--- Guarded on the native rather than assumed: an unknown native throws, five
--- throws suspend the frame callback, and the callback being suspended here is
--- the one that also keeps the player on the floor.
--- @param moving boolean
local function crawlPlaying(moving)
    if crawlMoving == moving then return end
    if not SetEntityAnimSpeed or not crawl then
        crawlMoving = moving
        return
    end
    SetEntityAnimSpeed(PlayerPedId(), crawl.dict, crawl.anim,
                       moving and 1.0 or 0.0)
    crawlMoving = moving
end

-- --------------------------------------------------------------------------
-- The view from the floor
-- --------------------------------------------------------------------------
--
-- "The DBNO player's camera is too high when in DBNO. Can we lower it closer
-- to the ground? Otherwise seems like it's hovering over their standing
-- height." (owner, 2026-08-17.)
--
-- It is hovering over their standing height, and the reason is the same one
-- behind the labels: a downed ped is only downed to LOOK at. The crawl is an
-- animation, so as far as the engine is concerned the capsule is still stood
-- up, and the follow camera orbits the head it believes is up there. There is
-- no native that lowers the gameplay camera -- it takes a heading, a pitch and
-- an orbit distance, and no height -- so the downed view is a scripted camera,
-- and it is pointed at the ped's actual head bone, which is where the player
-- can see their own body is.
--
-- Free look is kept, on the same two control normals bus.lua's orbit uses, and
-- the base heading is the PED's: a crawl is steered by turning the body, so a
-- camera that did not follow the turn would leave the player driving blind.

local cam = nil
local camYaw, camPitch = 0.0, -10.0

--- Take the downed camera down. Safe to call when nothing is up.
local function camDown()
    if not cam then return end
    if DoesCamExist and DoesCamExist(cam) then
        RenderScriptCams(false, false, 0, true, true)
        DestroyCam(cam, true)
    end
    cam = nil
end

BR.Loop.register(BR.Loop.FRAME, 'dbno.camera', function()
    if not mine.downed then
        camDown()
        return
    end
    -- A build without the camera natives keeps the gameplay camera. Too high
    -- is a complaint; a black screen on the floor is a match.
    if not CreateCamWithParams then return end

    local ped = PlayerPedId()
    local hx, hy, hz = overhead(ped)

    -- Re-created rather than remembered when the handle stops existing:
    -- /brunstuck calls DestroyAllCams, and a handle to a camera that is gone
    -- would leave the player looking through nothing for the rest of the bleed.
    if not cam or (DoesCamExist and not DoesCamExist(cam)) then
        camYaw, camPitch = 0.0, -10.0
        cam = CreateCamWithParams('DEFAULT_SCRIPTED_CAMERA',
            hx, hy, hz, 0.0, 0.0, 0.0, 55.0, false, 0)
        if not cam or cam == -1 then
            cam = nil
            print('[br_core] dbno: no downed camera -- staying on the gameplay one')
            return
        end
        SetCamActive(cam, true)
        RenderScriptCams(true, false, 0, true, true)
    end

    camYaw   = (camYaw - GetControlNormal(0, 1) * 8.0) % 360.0
    camPitch = BR.Clamp(camPitch - GetControlNormal(0, 2) * 6.0, -55.0, 20.0)

    local dist  = M.dbnoCamDist or 2.2
    local yaw   = math.rad(GetEntityHeading(ped) + 180.0 + camYaw)
    local pitch = math.rad(camPitch)
    local horiz = dist * math.cos(pitch)

    local cx = hx - math.sin(yaw) * horiz
    local cy = hy + math.cos(yaw) * horiz
    local cz = hz + (M.dbnoCamLift or 0.25) - dist * math.sin(pitch)

    -- The floor is a floor. The whole point of this camera is to sit low, and
    -- low plus a downhill slope is under the ground, where the shot is black.
    local feet = GetEntityCoords(ped)
    if cz < feet.z + 0.3 then cz = feet.z + 0.3 end

    -- AND WALLS ARE WALLS. A camera two metres behind a body that is lying
    -- against a doorframe is inside the doorframe; the crawl already casts one
    -- ray per frame for the same reason, and this is the second.
    local ray = StartShapeTestRay(hx, hy, hz, cx, cy, cz, 1 | 16, ped, 4)
    local _, hit, ep = GetShapeTestResult(ray)
    if didHit(hit) and ep and ep.x then
        -- Short of the surface rather than flush with it, or the near plane
        -- clips through and the shot is the inside of the wall anyway.
        cx = hx + (ep.x - hx) * 0.8
        cy = hy + (ep.y - hy) * 0.8
        cz = hz + (ep.z - hz) * 0.8
    end

    SetCamCoord(cam, cx, cy, cz)
    PointCamAtCoord(cam, hx, hy, hz + 0.05)
end)

-- HOW LONG THE KNOCK KEEPS WATCHING THE PED, and how often.
--
-- 50ms because client/gamerules.lua's death watcher is on the 100ms TICK band:
-- watching at the same cadence would be a coin toss over which of the two saw
-- a settling corpse first, and watching at half of it means the body is back on
-- its feet before the watcher's next look, in every phase alignment.
--
-- 30 beats -- a second and a half -- because that is the outside of the window
-- the engine's death task can still be settling in, and because it comfortably
-- outlasts the ragdoll below. Nothing is watched after that: a ped which is
-- still alive a second and a half after the knock is not going to be killed by
-- the fall that caused it.
local FLOOR_WATCH_MS    = 50
local FLOOR_WATCH_BEATS = 30
-- The beat the knockdown ragdoll has landed on: 24 * 50ms, the 1200ms this
-- used to sleep in one go.
local KNOCKDOWN_LANDED  = 24

--- Has the world killed this ped, or is it in the middle of doing so?
---
--- THE SAME QUESTION client/gamerules.lua ASKS BEFORE REPORTING A DEATH, and
--- asking it in the same words is the entire point. That watcher reports on
--- `IsEntityDead or IsPedFatallyInjured`; if it would call this ped dead, then
--- this file has to have put it back, or the two disagree and the server
--- believes the watcher.
---
--- IsEntityDead ALONE IS NOT THE QUESTION -- the scar client/state.lua already
--- carries (a8b22c7). A fatal hit starts CTaskDyingDead and the flag settles
--- frames later, so there is a window in which the ped is unrecoverably on its
--- way out and `IsEntityDead` still answers "alive". A fall lands squarely in
--- that window: the knock is a round trip away, which is the same order of
--- magnitude as the settle. Reading the flag alone there takes the LIVE branch
--- on a corpse-to-be -- no resurrection, no health, and a ped that finishes
--- dying a moment later with the downed state painted on it.
---
--- IsPedFatallyInjured cannot false-positive a real knock: BR.Damage.applyHit
--- clamps a knocking shot so the victim's ped survives AT the downed floor, and
--- the floor is above the threshold by construction (BR.ToEngineHp(dbnoHp)
--- against BR.Config.Match.healthFloor).
--- @param ped integer
--- @return boolean
local function worldTookUs(ped)
    return IsEntityDead(ped) or IsPedFatallyInjured(ped)
end

--- Put a body the world killed back onto the downed floor, in one tick.
---
--- IN PLACE, AND WITHOUT BR.Spawn.respawn. This body is already lying on the
--- ground it fell to; respawn() is the verb for arriving somewhere NEW and
--- carries luggage that is wrong here (it strips the inventory's weapons and
--- ground-probes from fifty metres up, which indoors finds the roof). Same
--- reasoning, and the same three calls, as spawn.lua's REVIVED handler.
---
--- NOTHING YIELDS INSIDE THIS. Nothing is rendered in the middle of a tick, so
--- the standing idle a resurrection restores is overwritten before it can be
--- drawn once -- which is the whole of the owner's "the ped first stands up
--- fully before snapping to the crawling position".
local function floorTheBody()
    local p = GetEntityCoords(PlayerPedId())
    NetworkResurrectLocalPlayer(p.x, p.y, p.z,
                                GetEntityHeading(PlayerPedId()),
                                true, false)
    -- The dying animation outlives the resurrection otherwise: the ped stands
    -- up and then finishes collapsing over the top of the crawl.
    ClearPedTasksImmediately(PlayerPedId())
    playCrawl(true, true)

    -- THE HEALTH IS RE-APPLIED HERE AND NOT LEFT TO THE SERVER'S HEALTH_SYNC.
    --
    -- knock() sends the downed floor immediately after DBNO_SET and that used
    -- to be enough, because the resurrection happened inside the DBNO_SET
    -- handler itself and so ran FIRST. It does not any more -- the pose is
    -- streamed before the ped is touched, which puts a yield in between -- so
    -- the server's write lands on a ped that is still a corpse and is thrown
    -- away. Same shared number, not a second opinion.
    if M.dbnoHp then BR.Native.setDisplayHealth(M.dbnoHp) end
end

--- Put the player on the floor and start whatever crawl this build supports.
local function enterDowned()
    -- BEING DOWNED MEANS BEING ALIVE, AND THE WORLD DOES NOT KNOW THAT.
    --
    -- THE BUG (owner, 2026-08-16): a player who fell from a height went straight
    -- to OUT. Their screen read 0 health, they could not crawl, their body stayed
    -- in the world and a squadmate standing over them got no revive prompt at
    -- all. The squad panel said "out" the moment they landed.
    --
    -- Every knock the server hands out through a validated GUNSHOT arrives at a
    -- ped that is still alive: BR.Damage.applyHit clamps the damage it instructs
    -- us to apply so the ped survives at the downed floor, on purpose. Nothing
    -- clamps a fall. Falls, fire, drowning and cars are damage paths M6
    -- deliberately left to the engine (server/damage.lua reads them off
    -- weaponDamageEvent as environmental and returns), so the ped is genuinely
    -- DEAD by the time DBNO_SET arrives -- and a dead ped takes no animation,
    -- holds no health, and reads as a corpse to the server's own health sampler,
    -- which then eliminates the player it just knocked down.
    --
    -- The server cannot fix this from its side: NetworkResurrectLocalPlayer runs
    -- on the machine that owns the ped or nowhere (see the REVIVED note in
    -- shared/protocol.lua, which says exactly this about the #144 path). So the
    -- knock and the resurrection are two halves of one event, and this is the
    -- half that lives here.
    --
    -- IN PLACE, AND WITHOUT BR.Spawn.respawn. This body is already lying on the
    -- ground it fell to; respawn() is the verb for arriving somewhere NEW and
    -- carries luggage that is wrong here (it strips the inventory's weapons and
    -- ground-probes from fifty metres up, which indoors finds the roof). Same
    -- reasoning, and the same three calls, as spawn.lua's REVIVED handler.
    --
    -- The health that follows is the SERVER's: knock() sends HEALTH_SYNC with
    -- the downed floor immediately after DBNO_SET, because a resurrection
    -- restores GTA's defaults rather than ours.
    --
    -- THE WEAPON GOES FIRST, before anything can be fired from the floor, and
    -- before anything below is allowed to yield. The inventory's own weapon
    -- application is already suspended by canArm(); this is the half that
    -- clears what is currently in their hands.
    RemoveAllPedWeapons(PlayerPedId(), true)
    SetCurrentPedWeapon(PlayerPedId(), GetHashKey('WEAPON_UNARMED'), true)

    -- EVERYTHING ELSE IS AN ORDER, AND THE ORDER WAS THE BUG (owner,
    -- 2026-08-17): "When DBNO starts, the ped first stands up fully before
    -- snapping to the crawling position."
    --
    -- They did, and there were two ways to see it. A resurrection restores a
    -- STANDING IDLE -- that is what being alive looks like with no task on you
    -- -- and the crawl that replaced it used to be tasked from inside a thread
    -- that waited 1200ms first. Between those two moments the player was stood
    -- upright in front of everybody. And the clip was not even loaded yet:
    -- resolveCrawl() streams a dictionary and WAITS for it, up to 400ms per
    -- candidate on the first knock of a session, and that wait was being paid
    -- AFTER the ped had been stood up rather than before.
    --
    -- So the sequence is: load first, then touch the ped, and never yield
    -- between the resurrection and the pose.
    Citizen.CreateThread(function()
        -- 1. THE POSE, BEFORE THE PED IS TOUCHED AT ALL. Paid here, the
        --    streaming wait is paid by a body that is already lying on the
        --    ground, which is exactly where a fallen player is.
        resolveCrawl()
        if not mine.downed then return end

        -- 2. WHICH KIND OF KNOCK THIS IS, asked with the predicate the death
        --    watcher uses rather than with the flag alone. See worldTookUs.
        local fell = worldTookUs(PlayerPedId())

        if fell then
            -- THE RESURRECTION AND THE POSE ARE ONE TICK -- see floorTheBody.
            --
            -- AND NO KNOCKDOWN ON THIS PATH. The ragdoll below is the knock
            -- INSTANT -- the moment of falling over -- and this player has
            -- already fallen; the world killed them doing it. Ragdolling a
            -- freshly resurrected ped stands the skeleton up to drop it again,
            -- which is the very frame this whole ordering exists to remove.
            floorTheBody()
            print('[br_core] dbno: the world had already killed this ped -- resurrected onto the downed floor')

            -- AND NOTHING KNOCKS THEM OUT OF IT AGAIN. The knockdown below is
            -- the only ragdoll a downed player gets; leaving it enabled meant a
            -- passing car stood them back up mid-bleed, because the collision
            -- ragdolls them and the getup task that follows outranks a looping
            -- animation (owner, in game). The watchdog in dbno.controls covers
            -- everything else that can cancel a clip -- but not being ragdolled
            -- in the first place is the cheaper half, and it is the half that
            -- stops them standing. Immediate here: there is nothing to land.
            SetPedCanRagdoll(PlayerPedId(), false)
        else
            -- 3. A LIVE KNOCK KEEPS ITS KNOCKDOWN. Ragdoll type 0
            --    (CTaskNMRelax) and only for the moment of falling -- sustained
            --    ragdoll is too unstable to hold a player in, which is why the
            --    crawl is animation-driven from here on.
            BR.Native.knockdown(1200, 1600)
        end

        -- 4. AND THEN THE PED IS WATCHED, BECAUSE ONE LOOK IS NOT AN ANSWER TO
        --    A RACE (owner, 2026-08-17: a fall "went straight to dead" again).
        --
        --    THE THREE WAYS ONE LOOK LOSES, all of them real and all of them a
        --    round trip wide:
        --
        --      * the look above happens while CTaskDyingDead is still settling,
        --        so `fell` reads false on a body that is already gone. Nothing
        --        is resurrected, nothing is put on the floor, and the ped
        --        finishes dying wearing the downed state.
        --      * the server's HEALTH_SYNC lands on that same half-dead ped
        --        FIRST and writes the downed floor onto it. The number now says
        --        "alive" while the task still says "dying" -- which un-arms
        --        gamerules.death's latch, so when the task does finish, that
        --        watcher reports a SECOND death. On the server a second report
        --        from a downed player used to be an instant elimination.
        --      * something kills the ped after the knock lands -- the fire they
        --        fell into, the car that hit them -- down a path the server
        --        never took over and cannot clamp.
        --
        --    All three have the same repair, so it is written once and applied
        --    on a beat rather than reasoned about per case: while the server
        --    says we are down, a ped that reads dead gets put back. Re-applying
        --    is free when nothing is wrong -- worldTookUs is two natives -- and
        --    idempotent when something is, because floorTheBody writes the same
        --    shared number every time.
        for beat = 1, FLOOR_WATCH_BEATS do
            Citizen.Wait(FLOOR_WATCH_MS)
            if not mine.downed then return end

            -- Let the ragdoll land before asking for an animation on top of it,
            -- or the clip is cancelled by a physics state that has not settled.
            if not fell and beat == KNOCKDOWN_LANDED then
                playCrawl(true)
                SetPedCanRagdoll(PlayerPedId(), false)
            end

            if worldTookUs(PlayerPedId()) then floorTheBody() end
        end
    end)
end

--- Stand back up: undo everything enterDowned did.
local function leaveDowned()
    local ped = PlayerPedId()
    -- The view goes back to the game's own camera before anything moves the
    -- ped, so a revive is not watched from the floor.
    camDown()
    -- Nothing is being held down any more, and the clip that was held still
    -- dies with the tasks below.
    hold, crawlMoving = nil, nil
    -- Reset the movement clipset even though nothing sets one any more. It is
    -- two native calls, and the alternative -- a player who was downed by an
    -- OLDER client build walking into the lobby at crawling pace -- is the
    -- undeleted-object bug in a different costume.
    ResetPedMovementClipset(ped, 0.0)
    SetPedMoveRateOverride(ped, 1.0)
    ClearPedTasks(ped)
    -- Handed back, or a revived player is permanently immune to being knocked
    -- over by anything for the rest of the match.
    SetPedCanRagdoll(ped, true)
    -- The inventory re-arms itself on the next pass, now that canArm() is true
    -- again; asking it here would race the state delta that made it true.
end

--- The server says the bleed ran out. Our ped has not noticed.
---
--- A downed ped is alive and invincible, so nothing about being eliminated
--- reaches it on its own -- the server sends HEALTH_SYNC 0 alongside this and
--- that is what should land the kill. This is the belt to that pair of braces:
--- invincibility is re-decided every frame from the mirror's state, so there is
--- a window of a frame or two where a health write can be ignored, and a player
--- left alive after the match has finished with them is the worst possible
--- outcome to leave to a race.
local function dieNow()
    Citizen.CreateThread(function()
        for _ = 1, 12 do
            local ped = PlayerPedId()
            if IsEntityDead(ped) or IsPedFatallyInjured(ped) then return end
            SetEntityHealth(ped, 0)
            Citizen.Wait(100)
        end
        print('[br_core] dbno: the ped would not die after a bleed-out -- tell somebody')
    end)
end

-- A DOWNED PLAYER STEERS AND NOTHING ELSE (owner, 2026-08-09).
--
-- They keep control of whether they are moving and in which direction; they
-- lose the weapon, the inventory, the vehicle and every other verb. Crawling
-- away from a firefight is the one decision the state is supposed to leave you,
-- and taking it away as well would make being downed a loading screen.
--
-- THE MOVEMENT IS OURS. None of the assets that survived the probe is a
-- locomotion clipset -- they are animation dictionaries that play in place --
-- so the engine's own walk is disabled and the ped is driven by hand at
-- dbnoCrawlSpeed. Disabled-then-read is the standard shape for that: the
-- control still reports its value through GetDisabledControlNormal, so the
-- input is ours without the ped also trying to walk on it.
local DOWNED_BLOCKED = {
    21, 22, 23, 24, 25,          -- sprint, jump, enter vehicle, attack, aim
    30, 31, 32, 33, 34, 35,      -- movement axes and WASD (read back below)
    44, 75,                      -- cover, exit vehicle
    140, 141, 142, 143,          -- melee attacks and block
}

-- HOW FAR THE PED IS ALLOWED TO WANDER FROM THE SPOT IT IS BEING HELD ON,
-- in metres. Not zero: a float round-trip through the engine is not exact, and
-- writing a position every frame to correct a millimetre would be a teleport
-- per frame forever. A centimetre is under a pixel at any distance a downed
-- player is looked at from, and it is far below one frame of the clip's own
-- drift, so nothing accumulates.
local HOLD_SLACK = 0.01

--- Keep the ped on the spot it stopped at.
---
--- THE OTHER READING OF "NO WAY TO STOP CRAWLING", AND THE ONE THAT DOES NOT
--- DEPEND ON A NATIVE'S GOODWILL. The lock flags in playCrawl tell the engine
--- not to let the clip drive the ped; this MEASURES whether something did
--- anyway and puts them back. Between the two, a downed player who is not
--- pressing anything stays where they are whatever the animation is made of --
--- which is the only claim about this that can be made from outside the game.
---
--- X and Y only. Pinning Z as well would hold a downed player in the air over
--- a slope they should be sliding down, and gravity is not the thing moving
--- them sideways.
--- @param ped integer
--- @param c table  the ped's coordinates this frame
local function stayPut(ped, c)
    if not hold then
        hold = { x = c.x, y = c.y }
        return
    end
    local dx, dy = c.x - hold.x, c.y - hold.y
    if (dx * dx + dy * dy) > (HOLD_SLACK * HOLD_SLACK) then
        SetEntityCoordsNoOffset(ped, hold.x, hold.y, c.z, true, true, false)
    end
end

BR.Loop.register(BR.Loop.FRAME, 'dbno.controls', function()
    if not mine.downed then
        hold = nil
        return
    end

    for i = 1, #DOWNED_BLOCKED do
        DisableControlAction(0, DOWNED_BLOCKED[i], true)
    end

    -- The loop is the pose; if anything cancelled it -- a car, a blast, a
    -- scripted task -- put it straight back. Cheap: one IsEntityPlayingAnim
    -- when nothing is wrong.
    playCrawl(false)

    local ped = PlayerPedId()
    -- Being thrown about is the one time the ped is allowed to travel without
    -- being asked to, so the hold is dropped rather than fought with -- and it
    -- is re-taken from wherever they land.
    if IsPedRagdoll(ped) or IsEntityInAir(ped) then
        hold = nil
        return
    end

    -- Turn on the horizontal axis, inch forward on the vertical one. Both are
    -- read from the DISABLED control, which is the whole point of disabling it.
    local lr = GetDisabledControlNormal(0, 30)
    local ud = GetDisabledControlNormal(0, 31)

    if math.abs(lr) > 0.1 then
        SetEntityHeading(ped,
            (GetEntityHeading(ped) - lr * (M.dbnoTurnRate or 90.0)
             * GetFrameTime()) % 360.0)
    end

    local c = GetEntityCoords(ped)

    -- Forward only. A crawl has no reverse gear, and -ud would let a downed
    -- player back out of a doorway faster than they went in.
    --
    -- NOT ASKING TO MOVE NOW MEANS NOT MOVING. This used to be a bare `return`
    -- -- the input was read, found to be nothing, and the frame was dropped on
    -- the assumption that nothing else could be moving the ped. Something was.
    if ud >= -0.1 then
        crawlPlaying(false)
        stayPut(ped, c)
        return
    end

    crawlPlaying(true)

    local step = (M.dbnoCrawlSpeed or 0.55) * GetFrameTime()
    local h    = math.rad(GetEntityHeading(ped))
    local dx, dy = -math.sin(h) * step, math.cos(h) * step

    -- A RAY BEFORE EVERY STEP, because moving a ped by hand does not resolve
    -- collision -- SetEntityCoords would happily post them through a wall, and
    -- "crawl into the geometry" is a better exploit than most. Cast from chest
    -- height a little further than the step is long; anything solid means stay
    -- put. One ray per frame, and only while actually crawling.
    local reach = step + 0.45
    local ray = StartShapeTestRay(c.x, c.y, c.z + 0.25,
                                  c.x + dx * (reach / step),
                                  c.y + dy * (reach / step),
                                  c.z + 0.25, 1 | 16, ped, 4)
    local _, hit = GetShapeTestResult(ray)
    if didHit(hit) then
        -- A wall is a reason to stay put, not a reason to stop enforcing it:
        -- a clip with a mover in it would push them into the geometry the ray
        -- just refused to walk them through.
        stayPut(ped, c)
        return
    end

    -- THE LAST THREE ARGUMENTS ARE NOT AXES. They read like the xAxis/yAxis/
    -- zAxis triple SET_ENTITY_COORDS takes, and they are not: this native's
    -- signature is (entity, x, y, z, keepTasks, keepIK, doWarp). Passing
    -- `false, false, false` here -- which is what shipped -- told the engine to
    -- CLEAR THE PED'S TASKS on every single frame of a crawl, which is the
    -- crawl animation itself, sixty times a second. The watchdog above then put
    -- it straight back, so the clip restarted from its first frame every frame
    -- and never played more than one of them.
    --
    -- keepTasks and keepIK are true so the pose survives the step. doWarp stays
    -- false on purpose, and the native's own documentation is why: false is for
    -- "simulating continuous movement", which is exactly what a crawl driven
    -- one step per frame is -- true would clear contacts and shove the ped
    -- space to arrive in, on every frame.
    SetEntityCoordsNoOffset(ped, c.x + dx, c.y + dy, c.z, true, true, false)
    hold = { x = c.x + dx, y = c.y + dy }
end)

RegisterNetEvent(BR.Net.DBNO_SET)
AddEventHandler(BR.Net.DBNO_SET, function(d)
    if type(d) ~= 'table' then return end

    local was = mine.downed
    mine.downed      = d.downed == true
    mine.bleedEndsAt = d.bleedEndsAt or 0
    mine.reviverName = d.reviverName
    mine.revivePct   = d.revivePct or 0.0

    if mine.downed and not was then
        enterDowned()
        BR.Sfx.play('hit.crit')
    elseif was and not mine.downed then
        leaveDowned()
        -- Picked up, or finished. The two look identical from here except for
        -- this flag, and only one of them ends with a body.
        if d.died then dieNow() end
    end

    pushMine()
end)

-- THE SERVER SAYS WHAT THE NUMBER IS; WE APPLY IT.
--
-- The same contract as STORM_DAMAGE and HIT_DAMAGE, in absolute form rather
-- than as a delta -- which is what a revive needs, since the point is to land
-- on a specific health rather than to move by an amount. Handled here because
-- a revive is the only thing that sends it.
RegisterNetEvent(BR.Net.HEALTH_SYNC)
AddEventHandler(BR.Net.HEALTH_SYNC, function(d)
    if type(d) ~= 'table' then return end
    if d.hp then BR.Native.setDisplayHealth(tonumber(d.hp) or 0) end
    if d.armour then SetPedArmour(PlayerPedId(), math.floor(tonumber(d.armour) or 0)) end
end)

-- Progress on the revive somebody is performing on US. Merged into the state
-- we already hold rather than sent as its own envelope: the interface reads
-- one payload for the whole overlay, so there is one shape and no merge
-- protocol on the far side.
RegisterNetEvent(BR.Net.REVIVE_PROGRESS)
AddEventHandler(BR.Net.REVIVE_PROGRESS, function(d)
    if type(d) ~= 'table' then return end

    -- Addressed at us as the DOWNED player.
    if mine.downed and d.target == BR.State.me.src then
        mine.revivePct   = d.pct or 0.0
        mine.reviverName = d.cancelled and nil or (d.reviverName or mine.reviverName)
        pushMine()
        return
    end

    -- Otherwise we are the one holding, and this is our ring.
    if not holding or d.target ~= holding.target then return end
    if d.cancelled or d.done then
        holding = nil
        sentStart = false
    end
end)

-- --------------------------------------------------------------------------
-- Picking somebody up
-- --------------------------------------------------------------------------

--- The nearest downed squadmate within reach, or nil.
---
--- POSITION COMES FROM THE PED, not from the 1Hz squad broadcast. At a metre
--- and a half the mate is streamed in by definition, and a position that is up
--- to a second old is a metre of error on a check whose whole range is one and
--- a half. The ped handle is resolved through BR.Squadmates.pedOf so this file
--- adds no second scope exception.
--- @return integer|nil src, number|nil dist
local function nearestDowned()
    local me = BR.State.me
    if me.state ~= BR.PlayerState.ALIVE or not me.squadId then return nil end

    local p = GetEntityCoords(PlayerPedId())
    local reach = M.dbnoReviveDist or 1.5
    local bestSrc, bestD = nil, nil

    for src, e in pairs(BR.State.roster) do
        if src ~= me.src and e.squadId == me.squadId
           and e.state == BR.PlayerState.DBNO then
            local ped = BR.Squadmates.pedOf(src)
            if ped ~= 0 then
                local c = GetEntityCoords(ped)
                local d = #(c - p)
                if d <= reach and (not bestD or d < bestD) then
                    bestSrc, bestD = src, d
                end
            end
        end
    end
    return bestSrc, bestD
end

-- The prompt page is the crate's. One browser for every world prompt in the
-- game, created on whichever of the two asks first.
local function promptPage()
    return BR.Dui.page('lootprompt', 'nui://br_ui/dui/prompt.html', 512, 256)
end

-- Sent on change only, exactly like the loot prompt: a re-send restarts the
-- ring animation from zero, so a hold already running is left alone.
local shownFor = nil

--- @param src integer|nil  the downed mate to prompt for, or nil to clear
--- @param holdMs number|nil
local function setPrompt(src, holdMs)
    local page = promptPage()

    if not src then
        if shownFor == nil then return end
        shownFor = nil
        BR.Dui.send(page, { t = 'prompt', show = false })
        return
    end

    local key = tostring(src) .. ':' .. tostring(holdMs)
    if key == shownFor then return end
    shownFor = key

    local e = BR.State.roster[src]
    BR.Dui.send(page, {
        t      = 'prompt',
        show   = true,
        label  = (e and e.name or 'Teammate'),
        hint   = 'Hold to revive',
        key    = BR.Native.keyLabelForCommand('brinteract',
                                              BR.Config.Loot.promptControl or 51),
        -- The danger colour, not a rarity: this is the one world prompt that
        -- is about a person rather than an object.
        colour = '#F87171',
        ring   = true,
        holdMs = holdMs,
    })
end

BR.Loop.register(BR.Loop.FRAME, 'dbno.revive', function()
    local target, dist = nearestDowned()

    -- THE YIELD, and it is raised from the reach test rather than from the
    -- keypress. Deciding it at the moment the key goes down would mean the
    -- crate prompt was still on screen when the player pressed, so the thing
    -- they were looking at and the thing that happened would disagree.
    BR.Loot.suppress(target ~= nil or holding ~= nil)

    if holding then
        -- The hold is only ours to keep while the reach still holds. The
        -- SERVER makes the same judgement every 250ms off its own position
        -- samples and is the one that counts; this is what keeps the ring
        -- honest in between.
        if target ~= holding.target or not BR.Keys.isHeld('interact') then
            TriggerServerEvent(BR.Net.REVIVE_STOP)
            holding, sentStart = nil, false
            setPrompt(target, nil)
        else
            setPrompt(holding.target, math.floor((M.dbnoReviveTime or 8.0) * 1000))

            -- THE HOLD IS RE-ASSERTED, NOT ANNOUNCED ONCE.
            --
            -- A brief tap completed a whole revive in playtest (owner,
            -- 2026-08-09). The key layer is not the problem -- it derives both
            -- edges correctly -- so the STOP was raised and did not land, and
            -- the design was one message away from an eight-second hold
            -- happening for free. Progress now requires CONTINUOUS evidence:
            -- the server expires a revive it has not heard about recently, so
            -- silence stops it and a lost STOP costs a fraction of a second
            -- instead of the whole interaction. Same reasoning as the bus's
            -- landing notices being polled rather than hooked.
            local now = GetGameTimer()
            if now - (holding.beat or 0) >= 250 then
                holding.beat = now
                TriggerServerEvent(BR.Net.REVIVE_START, { target = holding.target })
            end
        end
    else
        setPrompt(target, nil)
    end

    if not target then return end

    -- Drawn natively at the mate's own position, every frame, so the label is
    -- welded to the body however fast the camera moves.
    local ped = BR.Squadmates.pedOf(holding and holding.target or target)
    if ped ~= 0 then
        -- Low over the body. The loot prompt's lift is written for something
        -- standing on the ground; this one is written for something lying on
        -- it, and at the standing height it floated clear of the player it was
        -- pointing at (owner, in game).
        --
        -- AND THE LIFT IS MEASURED FROM THE HEAD, NOT FROM THE ORIGIN. A
        -- constant off the entity's position is a constant off a capsule that
        -- is still standing up whatever the ped is doing, which is why the box
        -- was still drawing at head height over a body on the floor (owner,
        -- 2026-08-17). The anchor now moves with the animation.
        local hx, hy, hz = overhead(ped)
        BR.Dui.drawWorld(promptPage(), hx, hy,
                         hz + (M.dbnoPromptLift or 0.35),
                         BR.Config.Loot.promptScale or 2.0)
    end
end)

BR.Keys.on('interact', function(pressed)
    if not pressed then
        if holding then
            TriggerServerEvent(BR.Net.REVIVE_STOP)
            holding, sentStart = nil, false
        end
        return
    end

    local target = nearestDowned()
    if not target then return end

    holding = { target = target, from = GetGameTimer() }
    if not sentStart then
        sentStart = true
        TriggerServerEvent(BR.Net.REVIVE_START, { target = target })
    end
end)

-- --------------------------------------------------------------------------
-- Teardown
-- --------------------------------------------------------------------------

--- Forget everything. A match ending mid-revive, or mid-bleed, must not leave
--- a prompt, a movement clipset or a stale overlay behind -- the clipset in
--- particular outlives the state that set it and would follow the player into
--- the lobby at crawling pace.
local function forgetAll()
    if mine.downed then
        mine.downed = false
        leaveDowned()
        pushMine()
    end
    -- Unconditional, unlike leaveDowned's copy: a scripted camera is the one
    -- thing here that survives every other kind of forgetting, and a match
    -- that ended while it was up would leave the player looking at the floor
    -- from two metres behind their own body for the whole lobby.
    camDown()
    holding, sentStart = nil, false
    setPrompt(nil)
end

RegisterNetEvent(BR.Net.STATE)
AddEventHandler(BR.Net.STATE, function(d)
    if d and (d.state == BR.MatchState.ENDED
              or d.state == BR.MatchState.CLEANUP
              or d.state == BR.MatchState.WAITING) then
        forgetAll()
    end
end)

AddEventHandler('onClientResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    -- A movement clipset survives a resource restart the same way an undeleted
    -- object does; the player would be left crawling with nothing left running
    -- to stand them up.
    local ped = PlayerPedId()
    ResetPedMovementClipset(ped, 0.0)
    SetPedMoveRateOverride(ped, 1.0)
    -- And a rendering camera survives it even harder: nothing else in the game
    -- knows this handle exists, so `restart br_core` while downed would leave
    -- the view welded to a dead camera with no code left to release it.
    camDown()
end)

-- --------------------------------------------------------------------------
-- Debug
-- --------------------------------------------------------------------------

--- WHICH DOWNED POSE THIS BUILD ACTUALLY HAS.
---
---   brcrawl        what exists, and what loads
---   brcrawl <n>    play candidate n on your own ped for six seconds
---
--- This command exists because the first version of the downed state guessed
--- an asset name, guessed the wrong KIND of asset, and put every downed player
--- in a T-pose. `move_crawl` is an animation dictionary; it was handed to
--- SetPedMovementClipset, which does not fail on a bad clipset -- it renders
--- bind pose. Read the `clipset?` column with that in mind: it reported TRUE
--- for the asset that caused the bug, so it is a hint and not an answer.
--- Watching `brcrawl <n>` is the answer.
RegisterCommand('brcrawl', function(_, args)
    local n = tonumber(args[1])

    if n and CRAWL_CANDIDATES[n] then
        local c = CRAWL_CANDIDATES[n]
        if not loadDict(c.dict) then
            print(('  %s did not load -- nothing to show'):format(c.dict))
            return
        end
        print(('[br_core] playing %s / %s for 6s'):format(c.dict, c.anim))
        Citizen.CreateThread(function()
            local ped = PlayerPedId()
            TaskPlayAnim(ped, c.dict, c.anim, 8.0, -8.0, -1, 1, 0.0,
                         false, false, false)
            Citizen.Wait(6000)
            ClearPedTasks(PlayerPedId())
            print('[br_core] done')
        end)
        return
    end

    print('=== downed pose candidates ===')
    print('  #  dict / anim                              exists  loads  clipset?')
    for i, c in ipairs(CRAWL_CANDIDATES) do
        local exists = (not DoesAnimDictExist) or DoesAnimDictExist(c.dict)
        local loads  = exists and loadDict(c.dict) or false
        -- REPORTED, NEVER APPLIED. Applying an unverified movement clipset is
        -- precisely what T-posed a downed player, and a probe that reproduces
        -- the bug it is investigating is not a probe.
        RequestClipSet(c.dict)
        local asClip = HasClipSetLoaded(c.dict)
        print(('  %d  %-40s %-7s %-6s %s'):format(
            i, c.dict .. ' / ' .. c.anim,
            tostring(exists), tostring(loads), tostring(asClip)))
    end
    print(('  in use: %s'):format(
        crawl and (crawl.dict .. ' / ' .. crawl.anim)
              or (crawl == false and 'none -- lying still' or 'not resolved yet')))
    print('  "brcrawl <n>" plays one on your own ped for six seconds.')
    print('  clipset? TRUE is NOT proof -- it read true for the asset that')
    print('  T-posed everybody. Watch it before believing it.')
end, false)

RegisterCommand('brdbno', function()
    print('=== dbno (client) ===')
    print(('  me         : %s'):format(tostring(BR.State.me.state)))
    print(('  downed     : %s  bleedEndsAt %s  (%.1fs left)')
        :format(tostring(mine.downed), tostring(mine.bleedEndsAt),
                (mine.bleedEndsAt - BR.Clock.now()) / 1000.0))
    print(('  reviver    : %s  %.0f%%')
        :format(tostring(mine.reviverName), mine.revivePct or 0.0))
    print(('  pose       : %s   (brcrawl for the candidate list)'):format(
        crawl and (crawl.dict .. ' / ' .. crawl.anim)
              or (crawl == false and 'none -- lying still' or 'not resolved yet')))
    -- THE FOUR PRESENTATION FAULTS, AS FOUR READINGS (owner, 2026-08-17). Each
    -- of these is a thing that can only be judged by eye in game, so the
    -- readout says what the client BELIEVES and the player says what they saw;
    -- the pair is what makes the next report answerable in one paste.
    print(('  clip       : %s   (%s)'):format(
        crawlMoving == nil and 'rate not set yet'
            or (crawlMoving and 'running' or 'held still'),
        SetEntityAnimSpeed and 'SetEntityAnimSpeed present'
                            or 'NO SetEntityAnimSpeed on this build'))
    print(('  held at    : %s'):format(
        hold and ('%.2f, %.2f'):format(hold.x, hold.y)
              or '- (moving, or not downed)'))
    do
        local ped = PlayerPedId()
        local hx, hy, hz = overhead(ped)
        local c = GetEntityCoords(ped)
        print(('  head       : %.2f above the ped origin  (%s)'):format(
            hz - c.z,
            GetPedBoneCoords and 'from the head bone'
                              or 'NO GetPedBoneCoords -- fallback lift'))
        print(('  camera     : %s'):format(
            cam and ('up, handle %s, %.2f above the head'):format(
                        tostring(cam), (M.dbnoCamLift or 0.25))
                or 'down -- the gameplay camera is rendering'))
    end
    local target, dist = nearestDowned()
    print(('  in reach   : %s%s'):format(tostring(target),
        dist and (' at %.2fm'):format(dist) or ''))
    print(('  holding    : %s'):format(holding and tostring(holding.target) or '-'))
    print('  downed squadmates the mirror knows about:')
    local n = 0
    for src, e in pairs(BR.State.roster) do
        if e.state == BR.PlayerState.DBNO then
            n = n + 1
            print(('    %-4d %-18s squad %s  ped %d')
                :format(src, tostring(e.name), tostring(e.squadId),
                        BR.Squadmates.pedOf(src)))
        end
    end
    if n == 0 then print('    (none)') end
end, false)
