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

-- THE LAST TIME WE ASKED THE SERVER FOR ANYTHING, and it is deliberately NOT
-- part of `holding`.
--
-- It replaces a `sentStart` boolean that guarded the FIRST ask of a hold. That
-- guard was already dead weight -- the frame loop re-asserts off `holding.beat`
-- and a fresh `holding` has no beat, so the ask went out on the next frame
-- either way -- and it hid the real problem, which was that `holding` itself
-- was only ever created on a key-DOWN edge. Now that a hold can be (re-)armed
-- from the frame band, the throttle has to outlive the table it throttles, or
-- an arm-refuse-arm cycle would ask sixty times a second instead of four.
--
-- Reset to 0 on a genuine press edge, so a deliberate press is never delayed by
-- up to 250ms behind an ask the player did not make.
local lastAsk = 0

--- How often we re-assert a hold, ms. The server expires one it has not heard
--- about in dbnoReviveBeatMs (750), so three of these fit inside its patience.
local ASK_EVERY_MS = 250

-- WHAT THE INTERACTION ACTUALLY DID, WRITTEN DOWN AS IT HAPPENS.
--
-- THIS IS THE FIRST DELIVERABLE OF #163 AND IT OUTRANKS THE FIX. Three rounds
-- have now been spent on "I hold the button, the ring fills, nothing happens",
-- and the reason each one cost a round is that the sentence describes THREE
-- different faults which look identical on screen:
--
--   1. THE HOLD NEVER COMPLETED -- this client dropped its own hold partway,
--      so the server was told to stop and never got its 2.8 seconds.
--   2. THE REQUEST NEVER LEFT -- nothing was ever sent, so there was nothing
--      for the server to refuse.
--   3. THE SERVER REFUSED -- it was asked, and it said no, every time.
--
-- The ring cannot tell them apart and never could: br_ui/dui/prompt.html runs a
-- ONE-SHOT CSS fill from a single "a hold began, it lasts N ms" message, on the
-- browser's own clock. Worse, `shownFor` below suppresses a re-send with the
-- same key, so a hold that is refused and immediately re-armed sends NO new
-- message at all -- the ring finishes the fill it started and then sits there
-- full, forever, while the interaction is failing four times a second. That is
-- pixel-identical to a working hold and it is the whole of the false signal.
--
-- So every ask, every stop, every refusal and every progress tick is counted
-- here, with its reason and its age, and /brdbno reads them back as a verdict.
-- Counters rather than a log: this runs in a frame band, and a paste has to fit
-- in a console.
local ledger = {
    armed     = 0,  armedAt    = 0,  armedFor  = nil,
    asks      = 0,  lastAskAt  = 0,
    stops     = 0,  lastStopAt = 0,  lastStopWhy = nil,
    ticks     = 0,  lastTickAt = 0,  lastPct   = 0.0,
    refusals  = 0,  lastRefuseAt = 0, lastRefuseWhy = nil,
    dones     = 0,  lastDoneAt = 0,
    -- Frames in which a hold was live and nearestDowned() came back empty. See
    -- the reach test in dbno.revive: this used to be a REVIVE_STOP.
    blind     = 0,  lastBlindAt = 0,
    -- Set by the REVIVE_PROGRESS handler, consumed by dbno.revive: a refusal
    -- must be allowed to take the ring back down, or the next arm is silent.
    ringStale = false,
}

--- Reasons, counted. A refusal that happens once is a race; the same refusal
--- four times a second is the answer.
local refusedBy = {}

-- PUBLISHED, so the readings are reachable from outside this file: /brdbno is
-- one reader and the suite that has to prove a fix bit is the other. Read-only
-- by convention -- nothing outside writes these, and a test that had to reach
-- into a local through a debug hook would be testing the hook.
BR.Dbno.ledger   = ledger
BR.Dbno.refusals = refusedBy

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

-- How many crawl tasks this session has actually issued. Only for /brdbno, and
-- only because it is the denominator the clone resync below has to be read
-- against: one step per task is the contract, so a readout with one number in
-- it cannot say whether it is being met.
local crawlTasks = 0

-- THE SHORTEST INTERVAL BETWEEN TWO CRAWL TASKS, ms.
--
-- IT LIVES UP HERE NOW BECAUSE playCrawl NEEDS IT, and playCrawl not having it
-- is the whole of the regression below. It used to be declared beside the turn
-- watchdog, nine hundred lines down, and so it governed the ONE re-task path
-- that had already been thought about and none of the others.
--
-- THE REGRESSION IT CLOSES (owner, 2026-08-19, playtested): "DBNO players move
-- immediately after going DBNO when not being commanded to, and that translates
-- to desync in their ped's location between screens."
--
-- They travelled at the full crawl speed with nothing pressed, and the loop is
-- short enough to write out in four lines:
--
--   1. dbno.controls calls playCrawl(false) on the FRAME band. Before ab4bd7f
--      that call could not do anything -- IsEntityPlayingAnim was read raw, `0`
--      is truthy, so the watchdog returned every time. ab4bd7f fixed the read
--      (correctly), which turned the watchdog on for the first time.
--   2. TaskPlayAnim is not evaluated inside the tick that asks for it -- this
--      file says so at length under holdCover, and budgets POSE_SETTLE_MS = 1000
--      for the rest of the transition (citizenfx/fivem#2236). So the frame after
--      a task, `playingCrawl` is still false.
--   3. ...so the watchdog tasks again. And again. Each task RESTARTS the
--      transition, so the clip can never finish landing, so the watchdog never
--      stops: sixty TaskPlayAnims a second, forever, and sixty fresh movers a
--      second on every clone.
--   4. Every task calls resyncArm(), and every arm spent a one-frame step. The
--      body crawled 21.8 metres over the shortest bleed the config can produce,
--      with nobody touching the keyboard (tools/test_shared.lua,
--      `dbno.quiet.body`).
--
-- 250ms is the file's own number and it is not being re-tuned here: it was
-- already "a spin cannot re-task per frame" for the turn watchdog, and this is
-- the same sentence applied to the watchdog that never had one. It is also
-- comfortably longer than any frame, which is the property that matters --
-- whatever the engine's answer is, it has arrived before the next ask.
local RETASK_EVERY_MS = 250

-- THE ORIENTATION THE CLONES WERE LAST HANDED, and the moment they were handed
-- it. Written by playCrawl -- and ONLY by playCrawl, because the thing they
-- describe is a task on the wire, not a number in this file. `turnedSince` is
-- the arm: nothing re-tasks a crawl unless the PLAYER turned it. See the
-- heading block below dbno.controls.
--
-- `taskAt` IS nil UNTIL THERE HAS BEEN A TASK, rather than 0. Zero is a real
-- reading of GetGameTimer on a machine that has just started, and a throttle
-- that compared against it would refuse the FIRST pose of the session for a
-- quarter of a second -- which is a downed player lying in a standing idle for
-- exactly as long as anybody is likely to look.
local taskHeading = 0.0
local taskAt      = nil
local turnedSince = false

-- Where the player last asked to be, while they are not asking to move. See
-- the movement loop: this is what "stay put" is made of.
local hold = nil      -- { x = number, y = number } or nil

--- Pin the ped to where it is standing RIGHT NOW.
---
--- THE HOLD USED TO ARM ITSELF LATE, AND THAT IS THE WHOLE OF "THE PED DRIFTS
--- ON ENTRY" (owner, 2026-08-17 -- the lock flags and stayPut had already
--- shipped and the body still slid).
---
--- stayPut() is the only thing that ever set `hold`, it is reached only from
--- dbno.controls, and its first call RECORDS rather than corrects -- it has
--- nothing to correct towards yet. So the anchor was whatever position the ped
--- had reached by the time that callback next ran with the player downed, not
--- ragdolling, not airborne and not pressing forward. Every one of those
--- conditions is a delay, and two of them are long:
---
---   * `hold` is cleared to nil at the top of dbno.controls whenever we are not
---     downed, so a knock always starts with no anchor at all;
---   * a LIVE knock ragdolls for 1200-1600ms (BR.Native.knockdown), and the
---     ragdoll branch clears `hold` on every frame of it -- so on that path
---     nothing is anchored until the ragdoll releases, and `move_injured_ground`
---     is a LOCOMOTION dictionary whose clip is already running by then.
---
--- Arming it HERE -- at the knock, at the resurrection, and at the frame the
--- knockdown lets go -- means the very first correction has somewhere to correct
--- to, instead of spending that frame deciding where "here" is.
---
--- AND HERE IS THE MEASUREMENT, BECAUSE IT DOES NOT SAY WHAT IT WAS EXPECTED TO
--- SAY. Driven against the real file with the clip's mover modelled at 0.35 m/s
--- and the lock flags assumed to do NOTHING -- the worst case the hold exists to
--- cover -- three seconds of being downed and never touching the keyboard:
---
---                        before      after     what the mover would have done
---   fall (resurrect)     0.000 m     0.000 m   1.05 m
---   shot (knockdown)     0.006 m     0.006 m   1.05 m
---
--- So the hold was ALREADY biting inside one frame, and this changes neither
--- number. It is kept because arming at the knock is simply the correct place to
--- arm -- it costs two natives and removes a frame of "no opinion" -- but it is
--- NOT an explanation for a drift anybody can see, and nobody should read it as
--- one.
---
--- WHAT IS LEFT, for whoever picks this up next: dbno.controls deliberately
--- drops the hold on every frame where IsPedRagdoll or IsEntityInAir is true,
--- and a LIVE knock spends 1200-1600ms ragdolling by design
--- (BR.Native.knockdown). A body sliding under physics for a second and a half
--- is exactly what "the ped drifts on entry" describes, it is the engine and not
--- the clip, and no anchor here touches it -- the branch that drops the hold is
--- the same branch that lets a thrown body travel, which is wanted. If the
--- owner's drift survives this, that ragdoll is the thing to shorten.
---
--- Cheap enough to call unconditionally: two natives and a table.
local function anchorHere()
    local c = GetEntityCoords(PlayerPedId())
    hold = { x = c.x, y = c.y }
end

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

--- Is this ped playing the downed clip RIGHT NOW?
---
--- THE SAME SCAR AS didHit, ON THE NATIVE THE COVER AND THE WATCHDOG BOTH TURN
--- ON -- and it was still being read raw. `IsEntityPlayingAnim` is declared BOOL
--- and answers `1`/`0` on a build that hands numbers back, and IN LUA `0` IS
--- TRUTHY. Two things were reading it directly and both did the opposite of
--- what they say they do on such a build:
---
---   * holdCover uncovered on the FIRST frame it looked, because `0` passed the
---     `and` -- so the cover over the resurrection's standing frame lasted
---     exactly one frame and the owner watched their ped stand up anyway
---     ("I do still see the DBNO player stand briefly", 2026-08-18);
---   * playCrawl's watchdog took `not 0` == false and returned, so a clip that
---     something had cancelled was never put back.
---
--- One reader, one comparison, and it is the comparison this file already uses
--- three lines up.
--- @param ped integer
--- @return boolean
local function playingCrawl(ped)
    if not crawl then return false end
    return didHit(IsEntityPlayingAnim(ped, crawl.dict, crawl.anim, 3))
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

-- Forward-declared: playCrawl arms the clone resync, and the resync's own state
-- belongs with the #164 note several hundred lines below rather than up here.
-- `local resyncArm` IS the declaration, so the binding exists by the time
-- anything calls it (tools/check_forward_locals.lua).
local resyncArm

--- Start (or restart) the downed loop on our own ped.
--- @param force boolean|nil  play even if something is already running
--- @param snap boolean|nil   arrive at the pose with no blend at all
local function playCrawl(force, snap)
    local c = resolveCrawl()
    if not c then return end

    local ped = PlayerPedId()
    if not force and playingCrawl(ped) then return end

    -- ...AND A WATCHDOG ASKS AT MOST FOUR TIMES A SECOND. See RETASK_EVERY_MS.
    --
    -- THE ORDER OF THESE TWO LINES IS THE FIX AND NOT A STYLE CHOICE. The test
    -- above is "the clip is running, nothing to do"; this one is "the clip is
    -- NOT running, but the last thing we asked for has not had time to arrive
    -- yet". Only the second is new, and only the unforced path is throttled --
    -- a knock, a resurrection and the beat the knockdown lands on all pass
    -- `force` and must never wait, because each of those is a body that is
    -- visibly in the wrong pose right now.
    if not force and taskAt and GetGameTimer() - taskAt < RETASK_EVERY_MS then
        return
    end

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
    crawlTasks  = crawlTasks + 1

    -- WHICH WAY THE BODY WAS POINTING WHEN THE CLONES LAST HEARD FROM IT, and
    -- when. The turn watchdog below measures against these two and nothing
    -- else; see the #164 heading block for why a turn has to become a task.
    taskHeading = GetEntityHeading(ped)
    taskAt      = GetGameTimer()
    turnedSince = false

    -- ...AND A FRESH TASK IS A FRESH MOVER ON EVERY OTHER MACHINE. This is the
    -- arm for the clone resync below, and it is here rather than on a clock
    -- because THIS CALL is the event: see the #164 block for why one step is
    -- the whole of the correction and a repeat of it is the creep.
    resyncArm()
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

-- ==========================================================================
-- THE STANDING FRAME, AND WHY NO AMOUNT OF RE-ORDERING CLOSES IT.
-- ==========================================================================
--
-- "When going from alive -> DBNO the ped briefly stands between the moment of
-- dying, reviving, and going to the emote we chose. During that period we
-- should have the ped be briefly invisible instead." (owner, 2026-08-18.)
--
-- floorTheBody() already carries a note claiming this cannot happen -- "NOTHING
-- YIELDS INSIDE THIS. Nothing is rendered in the middle of a tick, so the
-- standing idle a resurrection restores is overwritten before it can be drawn
-- once". That was the previous round's fix and it is WRONG, in a way the owner
-- can see and the file cannot:
--
--   TaskPlayAnim DOES NOT POSE A PED. It queues a task. The task tree is
--   evaluated by the ENGINE, after the script tick that asked for it, and the
--   ped renders whatever pose it currently has until then. A resurrection
--   restores a standing idle immediately -- that IS what being alive with no
--   task looks like -- so the frame between the resurrection and the engine's
--   next animation update renders a player standing up, every time, however
--   tightly the two calls are written together. `blend = 1000.0` removes the
--   blend, not the frame.
--
-- So the window is not closable by ordering, and the owner's instruction is the
-- correct one: cover it instead.
--
-- SET_ENTITY_LOCALLY_INVISIBLE, AND NOT SetEntityVisible, AND THE REASON IS
-- ALREADY WRITTEN DOWN TWICE IN THIS CODEBASE.
--
--   * SetEntityVisible is a NETWORKED PROPERTY, and client/natives.lua asserts
--     it on our own ped EVERY FRAME: `SetEntityVisible(ped, st ~= BUS, false)`
--     inside BR.Native.applyGameRules, which client/gamerules.lua runs on the
--     FRAME band. A downed player is not on the bus, so that line writes TRUE
--     sixty times a second. Anything this file wrote would be stomped within a
--     frame -- which is exactly the "everyone flickers or simply stays visible"
--     failure client/squadmates.lua records from the lobby-hiding attempts.
--   * SET_ENTITY_LOCALLY_INVISIBLE is not a property at all. It hides the
--     entity FOR YOURSELF FOR THE CURRENT FRAME. There is nothing for
--     applyGameRules to overwrite and nothing to replicate.
--
-- AND THAT IS ALSO THE WHOLE OF "MAKE SURE IT IS VISIBLE AGAIN ON EVERY EXIT,
-- INCLUDING THE FAILURE PATHS". There is no un-hide to forget. The flag lasts
-- one frame, so a Lua error, a resource stop, a match teardown, a revive, a
-- bleed-out, a build with no crawl clip and a ped that never poses all end the
-- same way: this stops calling, and the ped is visible on the next frame.
-- Nothing can leave a player invisible, because nothing is ever left set.
--
-- IT IS THE OWNER'S OWN SCREEN THAT IS BEING FIXED, and that is not a
-- compromise -- it is the report. Other machines never see this frame anyway:
-- they receive the resurrection and the task over the wire, already ordered.

--- How long the cover may last at the very outside, ms.
---
--- ONLY THE CAP IS A TIMER. What actually ends the cover is the pose being
--- CONFIRMED on the ped and then given a beat to become the pose -- see
--- holdCover. This number exists so a build that never poses at all (crawl
--- resolved to nothing, the task refused, the ped re-killed mid-window) cannot
--- hold a player invisible for a bleed: an invisible downed player is a worse
--- bug than a visible standing one, and it is the kind that reads as an exploit.
local HIDE_MAX_MS = 1500

--- How long AFTER the clip is confirmed running the cover stays up, ms.
---
--- "I do still see the DBNO player stand briefly -- let's just make the
--- invisibility time like 1 more second or so, should be enough for their ped
--- to be in the crawl position by then" (owner, 2026-08-18).
---
--- A SECOND IS NOT A GUESS ABOUT WHEN THE TASK LANDS -- the confirmation above
--- already answers that exactly. It is the interval between the task landing and
--- the BODY being on the floor, and it is documented FiveM behaviour rather than
--- something this file can shorten: TaskPlayAnim makes a ped LEAVE its current
--- state before it enters the clip (citizenfx/fivem#2236), so
--- `IsEntityPlayingAnim` goes true while the ped is still standing up out of the
--- old one. That is the frame the owner is describing, and it is on the far side
--- of the only signal the engine offers, which is why the cover cannot simply
--- watch harder.
---
--- IT COSTS NOBODY ELSE ANYTHING. SET_ENTITY_LOCALLY_INVISIBLE is not a
--- property and does not replicate: this is a second of the owner not seeing
--- their own body while the downed camera is still swinging into place, and no
--- other machine is affected at all.
local POSE_SETTLE_MS = 1000

-- When the cover was raised, or nil when nothing is being covered.
local hiddenFrom = nil

-- When the crawl clip was first CONFIRMED on the ped inside this cover, or nil
-- if it has not been yet. The settle above is measured from here and not from
-- hiddenFrom, so a slow streaming wait does not eat the settle.
local posedAt = nil

--- Hide our own ped for THIS frame only. Never a property write.
--- @param ped integer
local function hideBody(ped)
    if SetEntityLocallyInvisible then SetEntityLocallyInvisible(ped) end
end

--- Raise the cover over a re-pose that is about to happen.
local function coverPose()
    hiddenFrom = GetGameTimer()
    posedAt    = nil
    hideBody(PlayerPedId())
end

--- Hold the cover until the pose is actually on the ped, then a beat longer.
---
--- ASKED ON A LATER FRAME THAN THE ONE THAT TASKED IT, which is the whole
--- subtlety. A task issued this tick has not been evaluated yet, so
--- IsEntityPlayingAnim on the same frame is answering about the pose we are
--- trying to hide -- and believing it would uncover exactly the frame the cover
--- exists for. GetGameTimer is stamped per frame, so `now > hiddenFrom` is
--- precisely "a frame boundary has passed".
---
--- TWO THINGS WERE WRONG WITH THE ROUND THAT SHIPPED THIS, and the owner could
--- see both as one symptom:
---
---   1. `IsEntityPlayingAnim` WAS READ RAW. It is declared BOOL and can answer
---      `0`, and `0` is truthy in Lua -- so on such a build the `and` passed on
---      the first frame this ran and the cover came down instantly. It now goes
---      through playingCrawl, which compares rather than believes.
---   2. THE CLIP RUNNING IS NOT THE BODY BEING DOWN. TaskPlayAnim makes a ped
---      leave its current state before entering the clip
---      (citizenfx/fivem#2236), so confirmation is the START of the transition,
---      not the end of it. Confirmation therefore starts POSE_SETTLE_MS rather
---      than ending the cover.
--- @param ped integer
local function holdCover(ped)
    if not hiddenFrom then return end

    -- A build with no downed animation has no pose to wait for, and hiding a
    -- ped nothing is ever going to re-pose is just a disappearing player.
    if crawl == false then hiddenFrom, posedAt = nil, nil return end

    local now = GetGameTimer()
    if not posedAt and now > hiddenFrom and playingCrawl(ped) then
        posedAt = now
    end
    if posedAt and now - posedAt >= POSE_SETTLE_MS then
        hiddenFrom, posedAt = nil, nil
        return
    end
    if now - hiddenFrom >= HIDE_MAX_MS then
        hiddenFrom, posedAt = nil, nil
        return
    end

    hideBody(ped)
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
--- NOTHING YIELDS INSIDE THIS, and that is still worth keeping -- but it is NOT
--- enough on its own and the note that used to end here said it was. A tick
--- with no yield in it still ends, and the engine still evaluates the task tree
--- afterwards: the pose asked for below lands on the NEXT animation update, and
--- the resurrected ped renders a standing idle until it does. See the cover
--- above (owner, 2026-08-18: "the ped briefly stands between the moment of
--- dying, reviving, and going to the emote"). The ordering keeps that to one
--- frame; the cover is what stops it being seen.
local function floorTheBody()
    -- FIRST, BEFORE THE RESURRECTION. The standing idle exists from the moment
    -- NetworkResurrectLocalPlayer returns, so the cover has to be up before it
    -- is called and not after.
    coverPose()

    local p = GetEntityCoords(PlayerPedId())
    NetworkResurrectLocalPlayer(p.x, p.y, p.z,
                                GetEntityHeading(PlayerPedId()),
                                true, false)
    -- The dying animation outlives the resurrection otherwise: the ped stands
    -- up and then finishes collapsing over the top of the crawl.
    ClearPedTasksImmediately(PlayerPedId())
    playCrawl(true, true)

    -- ...AND THE SPOT IS RE-TAKEN FROM WHERE THE RESURRECTION PUT THEM. A
    -- resurrection is a position write, and the crawl that was just tasked
    -- carries a mover; an anchor from before either of those would drag the
    -- body back to where the corpse was.
    anchorHere()

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

    -- AND THE SPOT IS TAKEN ON THE FRAME OF THE KNOCK, not on the first frame
    -- dbno.controls happens to like the look of. See anchorHere: everything
    -- below this line can yield, the clip has a mover in it, and the hold is
    -- the only thing that measures. Synchronous, before the thread, so the
    -- FIRST frame of being downed already has something to correct towards.
    anchorHere()

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
                -- AND THIS RE-POSE IS COVERED TOO, which the round that added
                -- the cover missed: it hung the cover on floorTheBody, so only
                -- the FALL path ever had one. A live knock ends with a ragdoll
                -- releasing, and a ped coming out of a ragdoll runs a GETUP --
                -- which is the engine standing the body up, in front of
                -- everybody, on exactly the boundary this cover exists for
                -- ("the ped briefly stands ... and going to the emote we
                -- chose", owner). The ragdoll itself is deliberately NOT
                -- covered: falling over is the knock, and it is the one frame
                -- of this that is supposed to be watched.
                coverPose()
                playCrawl(true)
                SetPedCanRagdoll(PlayerPedId(), false)
                -- THE ANCHOR IS RE-TAKEN HERE AND NOWHERE ELSE ON THIS PATH.
                -- The knockdown has just thrown the body somewhere, and
                -- playCrawl(true) restarts a LOCOMOTION clip from its first
                -- frame with a full mover in it. The anchor from before the
                -- ragdoll points at where they were standing when they were
                -- shot -- metres away, and pinning them to it would teleport
                -- them back. Where they LANDED is the answer.
                anchorHere()
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
    -- AND NOTHING DOWNED-SHAPED SURVIVES STANDING UP. The resync has no body to
    -- speak for and the cover has no re-pose to hide -- a revived player must be
    -- indistinguishable from one who was never downed, which is the whole of
    -- the fourth report on this file.
    resyncPhase, resyncArmed, hiddenFrom, posedAt = 0, false, nil, nil
    -- ...and the turn watchdog with them: a body that stood up owes the clones
    -- nothing, and a stale taskHeading would re-task the first crawl of the
    -- NEXT knock for a turn that happened in a previous one.
    turnedSince = false
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

-- ==========================================================================
-- #164: THE BODY IS STILL ON ITS OWNER'S SCREEN AND CRAWLING ON EVERYBODY
-- ELSE'S.
-- ==========================================================================
--
-- "When DBNO - the ped is not moving on the DBNO player's screen, but on
-- others' they are." (owner, 2026-08-18.)
--
-- EVERYTHING THAT PINS THE BODY IS LOCAL-ONLY, AND THAT IS THE WHOLE FAULT.
-- There are two of them and neither crosses the wire:
--
--   * the lock flags in playCrawl are arguments to TaskPlayAnim on THIS
--     machine;
--   * crawlPlaying() is SetEntityAnimSpeed, which is a playback-rate override
--     on this machine's copy of the ped.
--
-- A clone on another client replays the task at rate 1.0 with the clip's mover
-- intact, and `move_injured_ground` is a LOCOMOTION dictionary -- so the body
-- crawls away over there at roughly a third of a metre a second. The measurement
-- that misled the last round (0.006m of local drift in three seconds) was
-- perfectly accurate and answered the wrong question: it measured the ped this
-- code owns, and the report is about the copies it does not.
--
-- AND NOTHING CORRECTS THE CLONE, BECAUSE NOTHING EVER MOVES THE ORIGINAL.
-- stayPut() only writes when the local ped has drifted past HOLD_SLACK, and the
-- local ped never drifts -- so from the network's point of view this ped is an
-- entity that has not changed position since the knock, and a clone playing a
-- clip with a mover is left to its own devices.
--
-- THE FIX IS THE OWNER'S OWN WORKAROUND, ON A BEAT. "You should quickly simulate
-- a player pressing the move forward and move backward button or similar, which
-- will cancel the animation and stop the ped from moving on everyone's screen.
-- Me doing this manually works."
--
-- Worth being precise about what that press actually does, because it is not
-- what it sounds like: controls 30-35 are DISABLED for a downed player
-- (DOWNED_BLOCKED), so the ENGINE never sees it. The only thing that reads it is
-- the loop below, through GetDisabledControlNormal. So the entire observable
-- effect of the owner's manual press is this file's own crawl branch --
-- crawlPlaying(true) and a real SetEntityCoordsNoOffset step -- followed by the
-- idle branch putting the rate back to zero. That is a sequence this file can
-- perform on its own, and it is exactly what is replayed here.
--
-- ONCE PER TASK, AND NOT ON A CLOCK. THIS IS THE #164 FOLLOW-ON.
--
-- "DBNO is kinda fixed - they're inching forward extremely slowly in steps, but
-- they are synced. If we can play that step exactly once and only once - we're
-- clear." (owner, 2026-08-18.)
--
-- The first cut ran this every 500ms, and the note that used to sit here argued
-- for the beat on the grounds that a client streaming in later gets a fresh
-- clone. The beat is what the owner is now watching, and it is worth being
-- exact about why it is visible rather than invisible:
--
--   THE PAIR IS TWO FRAMES LONG AND THE NETWORK IS NOT FRAME-LOCKED TO IT.
--   Phase 1 moves the body ~9mm and phase 2 puts it back on the NEXT frame.
--   Entity positions are snapshotted on the network's own cadence, not on
--   ours, so a snapshot that lands between the two carries the stepped-out
--   position and one that lands after it carries the anchor. Every beat is
--   therefore a coin toss that other machines see as a twitch forward -- and
--   the beat fires for the whole bleed, which config/match.lua sets at 40
--   seconds at the floor and 120 at the base: 80 to 240 of them per knock.
--
--   AND ANY PATH THAT LOSES HALF A PAIR LEAKS THE STEP. The `back` below only
--   runs while `hold` is set, and dbno.controls drops `hold` on any frame that
--   reads IsPedRagdoll or IsEntityInAir -- so a body on a slope that loses one
--   frame between phase 1 and phase 2 is re-anchored by stayPut AT THE
--   STEPPED-OUT POSITION. That is 9mm the body never gives back, and on a beat
--   it is 9mm every half second in whichever direction the ped is facing.
--   Nothing here can promise that never happens; a one-shot can promise it
--   cannot happen twice.
--
-- SO WHAT ARMS IT, if not a clock. The thing being cancelled is the emote's
-- default animated state ON THE CLONES, and that state has exactly one source:
-- a TaskPlayAnim on this ped, which is replicated and replayed over there at
-- rate 1.0 with the clip's mover intact. A fresh task is a fresh mover; no
-- fresh task is no fresh mover. So playCrawl arms this, every time it actually
-- issues one -- the knock, the resurrection, the beat the knockdown lands on,
-- and the frame-band watchdog putting a cancelled clip back. The re-arm is
-- driven by the event rather than by a guess about when the event might have
-- happened, which is the whole of the change.
--
-- WHAT THIS GIVES UP, said plainly rather than left for the next round to
-- discover: a client that streams the body in LATER, with no re-task in
-- between, builds its clone from the task as it stands and is not covered by a
-- step that has already been performed. The owner has watched a build with the
-- beat in it and reports the bodies are SYNCED -- so one cancellation holds --
-- and the revive no longer depends on the clone being in the right place
-- anyway (#163 moved the reach test to the server's own samples). If a body
-- that nobody re-tasked is ever seen crawling on a newcomer's screen, THAT is
-- the report that brings a second arm back, and it should arm off the scope
-- change rather than off a clock.
--
-- IT CANNOT CANCEL THE CRAWL. It only runs on frames where the player is not
-- travelling -- one touch of the FORWARD axis and the real input owns the frame
-- -- and the step it takes is one frame of dbnoCrawlSpeed (~9mm), put straight
-- back on the following frame.
--
-- ==========================================================================
-- #164, SECOND HALF: THE BODY TURNS AND THE CLONES DO NOT.
-- ==========================================================================
--
-- "When DBNO and a player crawls, their ped position is not synced with anyone
-- else's screen ... if they go forward, they go forward on everyone's screen.
-- But if they turn, they're still moving forward on other player's screens."
-- (owner, 2026-08-18.)
--
-- TRANSLATION REPLICATES AND ROTATION DOES NOT, and the asymmetry is not a
-- mystery once the two are written next to each other. Everything in
-- dbno.controls that moves the body forward ends in SetEntityCoordsNoOffset --
-- a real position write, on a networked entity, every frame of a crawl. A TURN
-- writes ONE THING:
--
--     SetEntityHeading(ped, (GetEntityHeading(ped) - lr * turnRate * dt) % 360)
--
-- and then falls into the "not asking to move" branch, where stayPut declines to
-- write anything at all because the ped has not drifted a centimetre -- it
-- turned, it did not move. So a pure turn produces no entity update of any kind,
-- and a turn WHILE crawling produces position updates that say nothing about
-- which way the body is now pointing.
--
-- That matters because of the model the block above is built on and the owner
-- confirmed in game: a clone is driven by the REPLICATED TASK, replayed at rate
-- 1.0 with `move_injured_ground`'s mover intact, and the only thing that has
-- ever cancelled that mover is a fresh task followed by the one-shot step. The
-- direction that mover carries the clone in is the direction the clone was
-- facing when it got the task. Turn on this machine and nothing re-tasks: the
-- clones keep the heading they were handed and keep crawling along it. Which is
-- the owner's sentence, exactly.
--
-- SO A TURN IS A RE-POSE, AND IT GOES THROUGH THE MECHANISM THAT ALREADY
-- EXISTS. There is no second resync here and there deliberately is not one:
-- playCrawl(true) issues a fresh task and playCrawl is what calls resyncArm, so
-- a settled turn produces exactly one task and exactly one step -- the same
-- one-per-task contract /brdbno's `clone sync` line is read against, and the
-- same thing the owner's own manual workaround does by hand.
--
-- WHAT STOPS IT BECOMING THE 500ms BEAT AGAIN, because that is the failure this
-- has to avoid rather than re-invent:
--
--   * `turnedSince` -- only the PLAYER'S OWN TURN INPUT arms it. The clip has a
--     rotational mover of its own; without this arm, a body rotating gently
--     under its own animation would re-task forever at four a second, and every
--     one of those is a 9mm step. Nothing on the keyboard, nothing on the wire.
--   * RETASK_EVERY_MS -- a spin cannot re-task per frame, which is the bug that
--     restarted the clip 59 times in 60 frames. It is declared at the top of
--     this file now rather than here, because the WATCHDOG needed it too and
--     not having it there is what shipped the 2026-08-19 regression: this list
--     was the only re-task path anybody had put a limit on.
--   * TURN_RETASK_DEG vs TURN_SETTLE_DEG -- mid-turn the body is allowed to be
--     20 degrees stale before it is worth a task; once the stick is back in the
--     deadzone, anything worth seeing is corrected. So a long sweep costs one
--     task per 20 degrees and a flick costs one, total.
--
-- AND WHAT THIS WATCHDOG IS NOT. It is NOT the thing that made downed bodies
-- travel on 2026-08-19, and that was worth proving before deciding whether to
-- keep it: the regression reproduces in a rig where BOTH control axes read 0.0
-- for the whole run, so nothing here ever arms. Reverting it would have left
-- the body crawling 21.8 metres and cost the heading fix for nothing. What is
-- still TRUE of it is the sentence ab4bd7f wrote down and could not prove --
-- that a fresh task is what lets a clone pick up a changed heading. Only a
-- playtest can answer that; /brdbno's `heading` line against `clone sync` is
-- the readout that answers it.
local TURN_RETASK_DEG = 20.0
local TURN_SETTLE_DEG = 2.0

--- The shortest angle between two headings, in degrees. Never negative, never
--- more than 180 -- 359 and 1 are two degrees apart, not three hundred and
--- fifty-eight, and a crawl steered across the wrap would otherwise re-task on
--- every frame of it.
--- @param a number
--- @param b number
--- @return number
local function headingGap(a, b)
    local d = (a - b) % 360.0
    if d > 180.0 then d = 360.0 - d end
    return d
end

--- Do the clones need to be told which way this body is now facing?
--- @param ped integer
--- @param turning boolean  is the player on the turn axis THIS frame
--- @return boolean
local function turnedAway(ped, turning)
    if not crawl or not turnedSince then return false end
    -- `taskAt` is nil until something has actually issued a task, and there is
    -- nothing to be stale AGAINST until then -- taskHeading is still its
    -- declared 0.0, which is a real heading and would read as a gap.
    if not taskAt then return false end
    if GetGameTimer() - taskAt < RETASK_EVERY_MS then return false end
    local gap = headingGap(GetEntityHeading(ped), taskHeading)
    return gap >= (turning and TURN_RETASK_DEG or TURN_SETTLE_DEG)
end

local resyncArmed = false -- a task has been issued and not yet answered for
local resyncPhase = 0     -- 0 idle, 1 the step out, 2 the step back
local resyncs     = 0     -- for /brdbno

--- A fresh crawl task exists, so a fresh mover exists on every clone of us.
---
--- Assigned rather than declared: playCrawl calls this and is written above,
--- so the binding has to exist up there (tools/check_forward_locals.lua).
resyncArm = function()
    resyncArmed = true
    -- A HALF DONE PAIR IS FINISHED, NOT ABANDONED, and the line that used to do
    -- the opposite -- `resyncPhase = 0` -- was the second half of the 2026-08-19
    -- regression.
    --
    -- The reasoning it carried was "finishing it against an anchor the new task
    -- has already invalidated", and the anchor is `hold`. But phase 2 writes
    -- `hold`, whatever `hold` currently is: finishing the pair puts the body
    -- exactly where this file believes it belongs, by definition, and there is
    -- no version of that which is worse than not doing it. Zeroing the phase
    -- threw the STEP BACK away and kept the step out -- so every arm that
    -- landed on a pending pair was 9mm the body never gave back, and an arm
    -- that landed every frame was a body crawling at full speed.
end

--- One "this body is HERE", performed for the benefit of other clients.
--- @param ped integer
--- @param c table   the ped's coordinates this frame
--- @return boolean  true if this frame belonged to the resync
local function resyncBody(ped, c)
    if not hold then return false end

    if resyncPhase == 0 then
        if not resyncArmed then return false end
        -- SPENT HERE, ON THE FRAME THE PAIR STARTS, so nothing can arrive
        -- between the two halves and buy a second one.
        resyncArmed = false
        resyncPhase = 1
        resyncs = resyncs + 1
    end

    if resyncPhase == 1 then
        -- OUT. The same two calls a real forward press makes: the clip is let
        -- off its rate override for one frame, and the ped is genuinely moved,
        -- so there is a position change for the network to carry.
        crawlPlaying(true)
        local step = (M.dbnoCrawlSpeed or 0.55) * GetFrameTime()
        local h    = math.rad(GetEntityHeading(ped))
        -- FROM THE ANCHOR, NOT FROM WHERE THE PED CURRENTLY IS, and that one
        -- word is the invariant this whole band is now built on:
        --
        --   while the player is pressing nothing, every position this file
        --   writes is either `hold` or `hold` plus ONE step.
        --
        -- Stepping from `c` made the step RELATIVE, so two phase-1s in a row --
        -- which is what an arm firing faster than the pair can finish produces
        -- -- compounded into a walk. Nothing that reads `hold` can compound,
        -- however often it runs, because `hold` is not something a step writes.
        --
        -- IT IS A BOUND AND NOT THE FIX, and the difference is measured rather
        -- than argued (tools/test_shared.lua, `dbno.quiet.body`): with resyncArm
        -- finishing its pair, this line is worth nothing on top of it -- one
        -- step either way, which is the excursion the pair exists to make. What
        -- it is worth is the day something re-introduces an arm that abandons a
        -- pair: two steps instead of thirty-three metres. Cheap insurance
        -- against the exact mistake this file has just made.
        --
        -- `hold` is deliberately NOT moved: the anchor is where they were put
        -- down, and phase 2 is what brings them back to it.
        SetEntityCoordsNoOffset(ped,
            hold.x - math.sin(h) * step, hold.y + math.cos(h) * step, c.z,
            true, true, false)
        resyncPhase = 2
        return true
    end

    -- BACK, and unconditionally -- not through stayPut, whose HOLD_SLACK (1cm)
    -- is wider than one frame of crawl (~9mm). Left to the slack test the body
    -- would keep the step rather than give it back.
    crawlPlaying(false)
    SetEntityCoordsNoOffset(ped, hold.x, hold.y, c.z, true, true, false)
    resyncPhase = 0
    return true
end

BR.Loop.register(BR.Loop.FRAME, 'dbno.controls', function()
    if not mine.downed then
        hold, resyncPhase, resyncArmed = nil, 0, false
        -- Not `hideBody` -- the cover is simply not asserted, and a flag that
        -- lasts one frame is already gone. Clearing the stamp is only so a
        -- later knock starts a fresh window.
        --
        -- `taskAt` goes with them: it is the watchdog's throttle, and a body
        -- that is not down owes the clones no task at all. Left standing, a
        -- player knocked again within RETASK_EVERY_MS of the last pose of the
        -- PREVIOUS knock would have their first pose held back a quarter of a
        -- second -- which is the standing frame the cover exists to hide,
        -- reintroduced by the fix for something else.
        hiddenFrom, posedAt, turnedSince, taskAt = nil, nil, false, nil
        return
    end

    for i = 1, #DOWNED_BLOCKED do
        DisableControlAction(0, DOWNED_BLOCKED[i], true)
    end

    local ped = PlayerPedId()

    -- THE COVER, BEFORE ANY OTHER BRANCH CAN RETURN. A resurrection can be
    -- performed on any frame the floor watch is running, and the ragdoll and
    -- input branches below both leave early -- so the one call that must not be
    -- skipped goes first. It does nothing at all unless a re-pose is in flight.
    holdCover(ped)

    -- The loop is the pose; if anything cancelled it -- a car, a blast, a
    -- scripted task -- put it straight back. Cheap: one IsEntityPlayingAnim
    -- when nothing is wrong.
    playCrawl(false)

    -- Being thrown about is the one time the ped is allowed to travel without
    -- being asked to, so the hold is dropped rather than fought with -- and it
    -- is re-taken from wherever they land.
    --
    -- THROUGH didHit, AND FOR THE FOURTH TIME IN THIS CODEBASE. Both of these
    -- are declared BOOL, both were read RAW, and `0` IS TRUTHY IN LUA -- so on a
    -- build that answers numbers this branch is taken on EVERY FRAME, `hold` is
    -- nil forever, and the anchor that is the file's only real defence against
    -- the clip's mover never exists. That is the reported bug wearing a
    -- different costume: a downed ped moving with nobody driving it.
    --
    -- LATENT RATHER THAN LIVE, said plainly: the owner's build must be
    -- answering booleans, because on their build downed players do crawl and a
    -- ped that took this branch every frame could never reach the crawl at all.
    -- It is fixed here anyway, with the comparison this file already owns,
    -- because "the ped must not move without input" is exactly what it breaks.
    if didHit(IsPedRagdoll(ped)) or didHit(IsEntityInAir(ped)) then
        hold = nil
        return
    end

    -- Turn on the horizontal axis, inch forward on the vertical one. Both are
    -- read from the DISABLED control, which is the whole point of disabling it.
    local lr = GetDisabledControlNormal(0, 30)
    local ud = GetDisabledControlNormal(0, 31)

    local turning = math.abs(lr) > 0.1
    if turning then
        SetEntityHeading(ped,
            (GetEntityHeading(ped) - lr * (M.dbnoTurnRate or 90.0)
             * GetFrameTime()) % 360.0)
        -- THE ARM, AND IT IS THE PLAYER'S HAND RATHER THAN THE BODY'S ANGLE.
        -- See turnedAway: measuring the angle alone would let the clip's own
        -- rotation re-task the crawl forever with nobody touching anything.
        turnedSince = true
    end

    -- ...AND A TURN THE CLONES HAVE NOT HEARD ABOUT BECOMES A TASK. Not a
    -- second resync: playCrawl is what arms the one below, so this produces one
    -- task and one step exactly as the knock does.
    if turnedAway(ped, turning) then playCrawl(true) end

    local c = GetEntityCoords(ped)

    -- Forward only. A crawl has no reverse gear, and -ud would let a downed
    -- player back out of a doorway faster than they went in.
    --
    -- NOT ASKING TO MOVE NOW MEANS NOT MOVING. This used to be a bare `return`
    -- -- the input was read, found to be nothing, and the frame was dropped on
    -- the assumption that nothing else could be moving the ped. Something was.
    if ud >= -0.1 then
        -- ...AND NOT MOVING IS WHEN THE BODY HAS TO SAY SO OUT LOUD (#164).
        --
        -- THIS USED TO EXCLUDE A TURNING PLAYER, on the grounds that they were
        -- "already generating entity updates". They are not, and that sentence
        -- is the second half of #164 in one line: a turn writes a heading and
        -- nothing else -- stayPut declines to write a position because the body
        -- has not drifted a centimetre. So a hold armed by a turn would have sat
        -- armed until the player let go of the stick, which on a slow sweep is
        -- the whole of the turn. The ped is not travelling on this frame either
        -- way, which is the only thing the pair actually needs.
        if resyncBody(ped, c) then return end
        crawlPlaying(false)
        stayPut(ped, c)
        return
    end

    -- A REAL INPUT ENDS ANY BEAT THAT WAS HALF DONE, rather than leaving the
    -- rate override and the anchor disagreeing about which phase we are in.
    resyncPhase = 0

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

-- WHICH CUE A SQUADMATE'S PHASE CHANGE PLAYS.
--
-- Named here rather than at the call site so the two strings that have to match
-- something in ui-src/src/audio/cues.ts sit on two adjacent lines, where a
-- rename can see both. They are NOT the subject's own cues: `hit.crit` (below,
-- native, mixed against gunfire) is what the player who went down hears, and
-- these are what everybody else hears -- which is the whole of the owner's
-- "they have their own sounds for this phase".
--
-- THREE PHASES, THREE SOUNDS, and the third is the only good one (owner,
-- 2026-08-18: "when a player is revived all squad mates should hear a success
-- sound"). It rides the same envelope for the same reason the other two do --
-- the SERVER decides the audience, because it is the only party that knows the
-- squad and knows not to address the subject.
local MATE_CUE = {
    down = 'squad.down',
    out  = 'squad.out',
    up   = 'squad.revived',
}

RegisterNetEvent(BR.Net.DBNO_SET)
AddEventHandler(BR.Net.DBNO_SET, function(d)
    if type(d) ~= 'table' then return end

    -- A SECOND SHAPE ON THE SAME EVENT, AND IT IS ABOUT SOMEBODY ELSE.
    --
    -- `mate` means "one of your squad changed phase" -- see tellSquad in
    -- server/combat.lua, which decides the audience and never addresses the
    -- subject. It carries no opinion about OUR downed state, so it is answered
    -- and returned from before a single field of `mine` is touched: falling
    -- through would read `d.downed` as nil and quietly stand a downed player up.
    --
    -- The interface plays it. This side does not reach for BR.Sfx, because
    -- config/audio.lua is deliberately COMBAT ONLY -- native audio earns its
    -- place by ducking against gunfire, and a squad status cue is interface
    -- audio in the same sense the elimination banner's is.
    if type(d.mate) == 'table' then
        local cue = MATE_CUE[d.mate.phase]
        if cue then
            TriggerEvent('br:ui:sendLocal', 'squadcue', {
                cue  = cue,
                src  = d.mate.src,
                name = d.mate.name,
            })
        end
        return
    end

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
        -- AND THE DEADLINE, BECAUSE THE PAUSE IS A NUMBER AND NOT A MODE.
        --
        -- "While actively reviving, the DBNO timer does not stop for some
        -- reason" (owner, 2026-08-18). It stops on the SERVER -- stepDowned
        -- pushes `dbnoUntil` along with each tick, which is what "the clock
        -- stops during a revive" is made of -- and it stopped nowhere else,
        -- because nothing carried the moved deadline back. DBNO_SET is sent on
        -- EDGES (the knock, the hold registering, a cancel, the revive); the
        -- pause happens four times a second in between. So the browser went on
        -- counting down against the deadline it was handed when the hold
        -- started -- DbnoOverlay runs its countdown on requestAnimationFrame
        -- from `bleedEndsAt` -- and a player watched their own timer run out
        -- under a revive the server had already paused.
        --
        -- Guarded rather than defaulted: a payload without the field must leave
        -- the deadline alone, not zero it. `or 0` here would bleed them out on
        -- the spot.
        if d.bleedEndsAt then mine.bleedEndsAt = d.bleedEndsAt end
        pushMine()
        return
    end

    -- Otherwise we are the one holding, and this is our ring.
    --
    -- THE REPLY IS RECORDED BEFORE IT IS FILTERED. `holding` is nil for the
    -- whole of a refuse-then-rearm cycle's first frame, and a refusal dropped
    -- on the floor here is precisely the evidence #163 has been missing three
    -- times running -- so the ledger is written from the envelope, and only the
    -- ACTION below is conditional on the hold still being ours.
    local now = GetGameTimer()
    if d.cancelled then
        ledger.refusals     = ledger.refusals + 1
        ledger.lastRefuseAt = now
        ledger.lastRefuseWhy = d.reason or 'no reason given'
        refusedBy[ledger.lastRefuseWhy] = (refusedBy[ledger.lastRefuseWhy] or 0) + 1
        -- AND THE RING IS ALLOWED TO FALL. Without this the next arm computes
        -- the same setPrompt key, sends nothing, and the fill that is already
        -- running finishes on schedule -- which is the lie. A refusal the
        -- player is holding through now visibly restarts the ring four times a
        -- second instead of completing once and stopping.
        ledger.ringStale = true
    elseif d.done then
        ledger.dones     = ledger.dones + 1
        ledger.lastDoneAt = now
    else
        ledger.ticks     = ledger.ticks + 1
        ledger.lastTickAt = now
        ledger.lastPct   = d.pct or 0.0
    end

    if not holding or d.target ~= holding.target then return end
    if d.cancelled or d.done then
        holding = nil
        -- NOT `lastAsk = 0`. A cancel is the server saying no; re-arming is the
        -- frame loop's job and it must stay on the 250ms leash, or a refusal
        -- the player is holding through becomes a per-frame conversation.
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

    -- A HOLD IS A LEVEL, NOT AN EDGE, AND THAT WAS THE SECOND-REVIVE BUG.
    --
    -- "Reviving a player twice doesn't seem to work. I can hold the input, the
    -- ring fills up, but then nothing happens" (owner, playtest).
    --
    -- `holding` used to be created in ONE place: the key-DOWN listener. Every
    -- other line in this file only ever cleared it -- the reach test below, the
    -- server's cancel, the server's completion, the match teardown. So the
    -- moment anything ended a hold, the player was left leaning on a key that
    -- no longer meant anything, and nothing could re-arm it until they let go
    -- and pressed again. A completed revive is exactly that: it clears
    -- `holding` while the key is still down, so the NEXT knock on the same mate
    -- found a held key and a dead interaction. Same shape for stepping out of
    -- reach and stepping back in, and for pressing before the mate is down.
    --
    -- Proved with the real client and the real server wired over a latency
    -- (tools/test_shared.lua, `dbno.hold.rearm`): at 20/40/120ms round trips,
    -- every one of those sequences failed on the second cycle before this and
    -- passes after it. It is not timing-dependent and never was -- which is why
    -- watching the ring could never find it.
    --
    -- The ring is the reason it survived a playtest, and this is worth saying
    -- out loud because it has cost four rounds once already (#129):
    -- br_ui/dui/prompt.html runs a ONE-SHOT CSS animation from a single
    -- "a hold began, it lasts N ms" message. It fills on schedule whatever the
    -- server thinks, so a full ring is evidence that setPrompt was called and
    -- evidence of nothing else at all.
    --
    -- KEY DOWN + A TARGET IN REACH IS THE WHOLE CONDITION. The server is the
    -- authority on whether that becomes a revive; this side's job is to keep
    -- telling it the truth about the key.
    -- A TARGET WE CANNOT SEE THIS FRAME IS NOT A RELEASE, AND TREATING IT AS
    -- ONE IS #163.
    --
    -- What used to be here dropped the hold -- and sent REVIVE_STOP -- whenever
    -- `target ~= holding.target`, which includes `target == nil`. Every one of
    -- those is a HARD CANCEL on the server: stopRevive() throws `reviveFrom`
    -- away, so the next ask starts a fresh 2.8 seconds from zero. There is no
    -- pause and no resume.
    --
    -- The reach test that produces `target` is the strictest thing in the whole
    -- interaction and it is measured off the WRONG BODY:
    --
    --   * it uses dbnoReviveDist (1.5m) with NO SLACK, while the server allows
    --     dbnoReviveDist + dbnoReviveSlack (2.5m) precisely because a position
    --     is up to 250ms old;
    --   * it measures to `BR.Squadmates.pedOf(src)`, which is OUR MACHINE'S
    --     COPY of the mate's ped -- and #164 is the report that that copy
    --     CRAWLS AWAY. The downed player is pinned on their own machine and
    --     nothing anchors the clone here, so the body a reviver is standing
    --     over walks out of a 1.5m circle in about two seconds. The hold is
    --     killed at 2.0s, the revive needs 2.8s, and the player -- who sees a
    --     ring that was started once and is finishing on the browser's own
    --     clock -- sees nothing happen, forever.
    --
    -- So the authority goes back where the comment always said it was. The
    -- SERVER re-checks reach every 250ms from its own samples and cancels for
    -- real if the reviver has genuinely walked off; this side now only ends a
    -- hold for the two things it is the sole witness to: the key coming up, and
    -- the player deliberately switching to a DIFFERENT mate.
    if holding and not BR.Keys.isHeld('interact') then
        TriggerServerEvent(BR.Net.REVIVE_STOP)
        holding = nil
        ledger.stops       = ledger.stops + 1
        ledger.lastStopAt  = GetGameTimer()
        ledger.lastStopWhy = 'the key came up'
    elseif holding and target and target ~= holding.target then
        TriggerServerEvent(BR.Net.REVIVE_STOP)
        holding = nil
        ledger.stops       = ledger.stops + 1
        ledger.lastStopAt  = GetGameTimer()
        ledger.lastStopWhy = 'a nearer mate took the prompt'
    elseif holding and not target then
        -- COUNTED, NOT ACTED ON. If this number is large while a revive is
        -- failing, the fault is the drifting clone in #164 and not the server.
        ledger.blind       = ledger.blind + 1
        ledger.lastBlindAt = GetGameTimer()
    end

    if not holding and target and BR.Keys.isHeld('interact') then
        holding = { target = target, from = GetGameTimer() }
        ledger.armed    = ledger.armed + 1
        ledger.armedAt  = holding.from
        ledger.armedFor = target
    end

    -- A REFUSAL HAS TO BE ABLE TO TAKE THE RING DOWN. setPrompt is a
    -- send-on-change, keyed on target and duration, and a refuse-then-re-arm
    -- cycle changes neither -- so nothing was sent and the one-shot fill from
    -- the FIRST arm ran to completion over a hold that was being declined four
    -- times a second. Forgetting the key here forces the next arm to re-send,
    -- which restarts the fill: a refused hold now reads as a ring that keeps
    -- resetting, which is the truth.
    if ledger.ringStale then
        ledger.ringStale = false
        setPrompt(nil)
    end

    if holding then
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
        --
        -- Throttled on `lastAsk` rather than on anything inside `holding`: the
        -- table is rebuilt whenever a hold is re-armed, and a throttle that
        -- died with it would be no throttle at all.
        local now = GetGameTimer()
        if now - lastAsk >= ASK_EVERY_MS then
            lastAsk = now
            TriggerServerEvent(BR.Net.REVIVE_START, { target = holding.target })
            ledger.asks      = ledger.asks + 1
            ledger.lastAskAt = now
        end
    else
        setPrompt(target, nil)
    end

    -- THE LABEL FOLLOWS THE HOLD, NOT THE REACH TEST. A hold that survives a
    -- frame of not seeing the body must still draw over it, or the prompt
    -- blinks every time the clone wanders past 1.5m.
    local drawFor = holding and holding.target or target
    if not drawFor then return end

    -- Drawn natively at the mate's own position, every frame, so the label is
    -- welded to the body however fast the camera moves.
    local ped = BR.Squadmates.pedOf(drawFor)
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

-- THE EDGES, AND ONLY THE EDGES.
--
-- Arming a hold is no longer this listener's job -- dbno.revive does it from
-- the key's LEVEL, every frame, which is what makes a hold that was interrupted
-- resume without a re-press. Two things still genuinely belong on an edge:
--
--   RELEASE has to raise the STOP immediately. The frame loop would notice
--   within a frame anyway, but the round trip is the expensive part and a
--   release is the one message the server most wants early.
--
--   PRESS clears the ask throttle. Without that, a deliberate press landing
--   240ms after some earlier ask would sit for a tenth of a second before
--   anything went out -- invisible in isolation, and exactly the kind of "the
--   key does not always work" that costs a playtest round to characterise.
BR.Keys.on('interact', function(pressed)
    if not pressed then
        if holding then
            TriggerServerEvent(BR.Net.REVIVE_STOP)
            holding = nil
            ledger.stops       = ledger.stops + 1
            ledger.lastStopAt  = GetGameTimer()
            ledger.lastStopWhy = 'the key came up (edge)'
        end
        return
    end
    lastAsk = 0
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
    holding, lastAsk = nil, 0
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
    -- BOTH OF THE ABOVE ARE LOCAL-ONLY. This is the line that says whether
    -- anything is being done about the copies on other machines (#164).
    --
    -- READ `steps` AGAINST `tasks`, not against the clock. One step per crawl
    -- task is the contract; a step count climbing on its own is the beat that
    -- creeps coming back, and steps well under tasks is a re-task the resync
    -- never got a still frame to answer.
    --
    -- AND READ `tasks` AGAINST A HANDFUL. A quiet knock settles on TWO, and
    -- that is the number the 2026-08-19 regression would have given away in one
    -- paste if anybody had asked for it: the watchdog was issuing sixty a
    -- second because nothing throttled it, and every one of them spent a step.
    -- `last task` is the throttle's own reading -- if it is never more than a
    -- frame old while the body lies still, the watchdog is storming again.
    print(('  clone sync : %d steps for %d crawl tasks, %s, phase %d   (the pin '
           .. 'above is local; this is what other clients see)')
        :format(resyncs, crawlTasks, resyncArmed and 'ARMED -- owed a step'
                                                 or 'settled', resyncPhase))
    print(('  last task  : %s   (a quiet knock settles on 2 tasks total; the '
           .. 'watchdog may not ask again for %dms)')
        :format(taskAt and ('%dms ago'):format(GetGameTimer() - taskAt)
                        or 'never -- nothing posed yet',
                RETASK_EVERY_MS))
    -- READ `heading` AGAINST `clone sync` ABOVE. A turn that nothing re-tasked
    -- is the second half of #164: the gap is how far the body has turned since
    -- the last thing the clones were told, so a large gap sitting still while
    -- the player is not touching the stick is this watchdog failing to fire.
    print(('  heading    : %.1f deg, clones last told %.1f (gap %.1f), %s')
        :format(GetEntityHeading(PlayerPedId()), taskHeading,
                headingGap(GetEntityHeading(PlayerPedId()), taskHeading),
                turnedSince and 'turned since that task' or 'no turn since'))
    print(('  cover      : %s   (%s; %dms settle after the clip is confirmed, '
           .. '%dms cap)')
        :format(hiddenFrom
                    and ('UP, %dms'):format(GetGameTimer() - hiddenFrom)
                    or 'down',
                posedAt and ('clip confirmed %dms ago'):format(
                                GetGameTimer() - posedAt)
                        or 'clip not confirmed yet',
                POSE_SETTLE_MS, HIDE_MAX_MS))
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
    print(('  in reach   : %s%s   (client reach %.1fm, no slack)'):format(
        tostring(target), dist and (' at %.2fm'):format(dist) or '',
        M.dbnoReviveDist or 1.5))
    print(('  holding    : %s   key %s'):format(
        holding and tostring(holding.target) or '-',
        BR.Keys.isHeld('interact') and 'DOWN' or 'up'))

    -- ------------------------------------------------------------------ #163
    -- THE THREE FACTS, SEPARATED. Read the verdict line first; the counters
    -- under it are the working.
    do
        local now = GetGameTimer()
        local function since(t)
            if not t or t == 0 then return 'never' end
            return ('%.1fs ago'):format((now - t) / 1000.0)
        end

        print('  --- revive ledger (this session) ---')
        print(('  hold       : armed %d, last %s on %s; dropped %d, last %s (%s)')
            :format(ledger.armed, since(ledger.armedAt),
                    tostring(ledger.armedFor), ledger.stops,
                    since(ledger.lastStopAt), tostring(ledger.lastStopWhy)))
        print(('  requests   : %d REVIVE_START sent, last %s  (every %dms while held)')
            :format(ledger.asks, since(ledger.lastAskAt), ASK_EVERY_MS))
        print(('  progress   : %d ticks, last %s at %.0f%%; %d completed')
            :format(ledger.ticks, since(ledger.lastTickAt), ledger.lastPct,
                    ledger.dones))
        print(('  refusals   : %d, last %s -- "%s"')
            :format(ledger.refusals, since(ledger.lastRefuseAt),
                    tostring(ledger.lastRefuseWhy)))
        for why, n in pairs(refusedBy) do
            print(('               %-14s x%d'):format(why, n))
        end
        print(('  lost sight : %d frames held a target this client could not '
               .. 'see, last %s'):format(ledger.blind, since(ledger.lastBlindAt)))

        -- THE VERDICT. Deliberately blunt, and deliberately about the LAST
        -- attempt rather than the totals -- "which of the three is it" is the
        -- question, and a paste has to answer it without arithmetic.
        local verdict
        if ledger.asks == 0 then
            verdict = 'THE REQUEST NEVER LEFT. Nothing was ever sent, so the '
                   .. 'server has nothing to answer for -- the hold never '
                   .. 'armed. Read "in reach" and "key" above: both have to be '
                   .. 'true on the same frame.'
        elseif ledger.ticks == 0 and ledger.refusals == 0 then
            verdict = 'ASKED, AND NEVER ANSWERED AT ALL. Neither progress nor '
                   .. 'a refusal has ever come back, which is a server that is '
                   .. 'not listening -- check REVIVE_START at BOTH ends.'
        elseif ledger.dones > 0 and ledger.lastDoneAt >= ledger.lastRefuseAt
                                and ledger.lastDoneAt >= ledger.lastStopAt then
            verdict = 'the last thing that happened was a completed revive. '
                   .. 'This path works.'
        elseif ledger.lastRefuseAt >= ledger.lastStopAt then
            verdict = ('THE SERVER REFUSED -- "%s". It was asked %d times and '
                    .. 'said no %d of them; run brdbno on the SERVER console '
                    .. 'for the numbers behind that sentence.')
                    :format(tostring(ledger.lastRefuseWhy), ledger.asks,
                            ledger.refusals)
        else
            verdict = ('THE HOLD NEVER COMPLETED -- this client ended it (%s) '
                    .. 'with the server at %.0f%%. %d frames of it were spent '
                    .. 'holding a body this client could not see.')
                    :format(tostring(ledger.lastStopWhy), ledger.lastPct,
                            ledger.blind)
        end
        print(('  VERDICT    : %s'):format(verdict))
        print('  (the RING IS NOT EVIDENCE: prompt.html fills on the browser\'s')
        print('   own clock from one message. These counters are.)')
    end

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
