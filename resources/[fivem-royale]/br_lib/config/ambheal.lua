-- The back of an ambulance as a heal station.
--
-- ═══ THE OWNER'S SENTENCE, IN FULL, BECAUSE EVERY CLAUSE IS A RULE ═══
--
--   "if I'm hurt, and I walk up to the back of an ambulance, I should get a
--    prompt to jump in the ambulance to heal up (a process which should put me
--    on the stretcher (position I gave you), run the siren, and take 15 seconds
--    to heal). Healing should be done with the rear doors open only, only one
--    heal per ambulance at a time, and if someone shoots me to death while in
--    the ambulance healing, I should still take damage and die completely."
--                                                    -- owner, 2026-08-28
--
-- ...and four more the same day:
--
--   "Use the scripted cam while healing in the ambulance, add that ambulance to
--    our list of ambulance blips if it wasn't already (such as ambient ones --
--    should already be covered but just checking), and also the only way to
--    leave the ambulance while healing should be pressing the interact button.
--    Once healing is done, we force them out the back of the ambulance where
--    they were before"
--
-- ═══ THIS IS NOT THE CPR KIT AND MUST NOT BECOME IT ═══
--
-- config/rescue.lua is the OTHER ambulance feature and the two are opposites in
-- almost every respect. Writing the difference down here is cheaper than having
-- somebody merge them later:
--
--                       THE CPR KIT (#191)          THIS
--   who                 a DBNO player               an ALIVE player, hurt
--   what it costs       an ultra-rare item          nothing
--   the vehicle         one WE build, per rescue    any ambulance in the world
--   who drives          an NPC medic, to a point    nobody; it does not move
--   the player is       invincible (the DBNO latch) MORTAL -- the owner's rule
--   it ends in          a delivery or a death       full health, or an interrupt
--
-- THE ONE THING THEY SHARE IS THE STRETCHER, and they share it EXACTLY: the
-- offset, the bone, the flag tail and the pose all come from
-- BR.Config.Rescue.stretcher, which the owner authored in game with /brattach.
-- There is no copy of those numbers in this file and there must never be one --
-- see the note at `stretcher()` below.
--
-- ═══ AND THE PLAYER IS MORTAL, WHICH IS WHERE THE BODIES ARE BURIED ═══
--
-- "if someone shoots me to death while in the ambulance healing, I should still
-- take damage and die completely." That is satisfied by CONSTRUCTION rather
-- than by anything in this file, and the construction is worth stating so
-- nobody adds a knob that breaks it:
--
--   client/natives.lua's `wantInvincible` latch is derived from the PLAYER
--   STATE and the MATCH STATE and nothing else. WARMUP, BUS, LOBBY, FREEFALL,
--   GLIDE, DBNO, a decided match, or the drop grace. A player healing in the
--   back of an ambulance is ALIVE in a PLAYING match, so the latch answers
--   false and SetPlayerInvincible(pid, false) is what is actually written.
--
-- So there is NO `proofs` table here, no invincibility knob, and nothing in the
-- client half that calls SetEntityInvincible, SetEntityProofs or SetPlayerInvincible
-- on the player's ped. tools/test_ambheal.lua asserts BOTH halves of that -- the
-- latch answering false for a healing player, and the file containing none of
-- those three natives -- because this is the requirement most likely to be
-- broken by a well-meaning edit that "stops the heal being interrupted".

BR = BR or {}
BR.Config = BR.Config or {}

BR.Config.AmbHeal = {
    enabled = true,

    -- ------------------------------------------------------------------
    -- WHAT COUNTS AS AN AMBULANCE
    -- ------------------------------------------------------------------
    --
    -- NOT A LIST. `BR.Config.Rescue.models` is the list, and reading it rather
    -- than copying it is the whole point: config/rescue.lua already argues that
    -- one list must serve every job "so the vehicle the rescue BUILDS and the
    -- vehicles it RECOGNISES can never mean different things". A heal station
    -- that recognised a different set would be a third meaning of the word.
    --
    -- ANY AMBULANCE AT ALL is the owner's explicit decision (2026-08-28) and it
    -- falls out of that: ambient traffic, the one parked at a station, the one a
    -- rescue abandoned. Nothing here asks where a vehicle came from.

    -- ------------------------------------------------------------------
    -- THE HEAL
    -- ------------------------------------------------------------------

    -- "take 15 seconds to heal". Wall clock, NOT scaled by how hurt you are --
    -- see the open question in the report: a player on 5hp and a player on 95hp
    -- both spend fifteen seconds, so the price of a top-up is deliberately bad
    -- and the price of a full heal is deliberately good. That is a guess at what
    -- he meant by "15 seconds" and it is the reading that needs no second number.
    durationMs = 15000,

    -- "heal up" -- to full. The same 100 the CPR kit's delivery hands back
    -- (BR.Config.Rescue.deliverHp), and for a weaker reason: there is no
    -- interesting number between "some" and "all" that a player could plan
    -- around, and a partial cap would make the last few seconds of the hold
    -- worthless without saying so anywhere.
    healTo = 100,

    -- ═══ HOW OFTEN THE SERVER ISSUES, AND WHY IT ISSUES AT ALL ═══
    --
    -- "Interrupting keeps what you healed so far", so the heal cannot land in
    -- one lump at the end. This is the cadence at which the server recomputes a
    -- TARGET and sends it -- the same 250ms and the same shape as
    -- server/inventory.lua's consumable tick, deliberately:
    --
    --   TARGETS, NOT DELTAS, ANCHORED ON `hp0`. Every message in one heal is
    --   measured from the health the player started on, so a dropped message
    --   self-corrects on the next one instead of losing that increment for
    --   good -- and the final one cannot double-count its own ramp. That last
    --   sentence is the shield bug (2026-08-08) and it is written out at length
    --   in server/inventory.lua; this file inherits the fix rather than
    --   rediscovering the fault.
    tickMs = 250,

    -- ------------------------------------------------------------------
    -- WHERE YOU HAVE TO BE STANDING
    -- ------------------------------------------------------------------

    -- How far the closest-vehicle scan reaches. Larger than `reachM` on purpose:
    -- the scan is what FINDS the ambulance and the reach is what OFFERS the
    -- prompt, and a scan that only reached as far as the offer would make the
    -- prompt flicker at its own boundary as the ped's coordinates jitter.
    scanM = 8.0,

    -- ...and how close to the back of it you must actually be.
    --
    -- 3.5m, WHICH IS BR.Config.Rescue.dropBackM, AND THAT IS NOT A COINCIDENCE.
    -- #191 step 7 puts a delivered player "directly behind the ambulance" at
    -- that distance, and the owner's "we force them out the back of the
    -- ambulance where they were before" asks for the same spot. One number means
    -- the place you stand to get in IS the place you are put down, so the heal
    -- reads as reversible rather than as a teleport.
    reachM = 3.5,

    -- ═══ "THE BACK OF AN AMBULANCE", AS A NUMBER ═══
    --
    -- The dot product of the vehicle's own forward vector with the direction
    -- from the vehicle to the player. -1.0 is directly behind, 0.0 is level with
    -- the middle, +1.0 is at the bonnet.
    --
    -- -0.35 IS A COMFORTABLE REAR ARC RATHER THAN A LINE. It admits roughly the
    -- rear 110 degrees, which covers standing at either rear door and walking in
    -- from the side of the van, and refuses standing at the driver's window --
    -- which is 3.5m from the vehicle ORIGIN and would otherwise pass the
    -- distance test with the doors nowhere in sight.
    --
    -- IT IS ALSO WHAT MAKES `reachM` HONEST. Without an arc, "within 3.5m of the
    -- origin" is a sphere that includes the bonnet, and the owner asked for the
    -- back.
    behindDot = -0.35,

    -- ------------------------------------------------------------------
    -- THE REAR DOORS
    -- ------------------------------------------------------------------
    --
    -- "Healing should be done with the rear doors open only."
    --
    -- DOORS 2 AND 3, WHICH ARE THE ONES `park()` OPENS. client/rescue.lua's park
    -- calls SetVehicleDoorOpen(veh, 2, ...) and (veh, 3, ...) for the owner's
    -- "back left and right doors open when it parks", so an ambulance a rescue
    -- has parked satisfies this rule the moment it stops -- which is the case
    -- that makes the two features fit together instead of merely coexisting.
    --
    -- ═══ HOW "OPEN" IS MEASURED, AND WHY IT IS NOT `IsVehicleDoorOpen` ═══
    --
    -- There is no such native. GET_VEHICLE_DOOR_ANGLE_RATIO is the reader, it
    -- answers a FLOAT (0.0 shut, 1.0 wide), and being a float is a small mercy:
    -- it is the one test in this feature that cannot be got wrong by the
    -- 0-is-truthy fault, because there is no BOOL to misread.
    --
    -- A THRESHOLD RATHER THAN `> 0.0`, because a door being pushed by physics or
    -- mid-animation reads as a hair off zero, and a heal that could be started
    -- through a door that is technically ajar is not what he asked for.
    rearDoors = { 2, 3 },
    doorOpenRatio = 0.35,

    -- ═══ CHECKED WHILE HEALING, NOT ONLY AT THE START ═══
    --
    -- "Healing cannot start, and presumably cannot continue, unless the rear
    -- doors are open." Both, and the second is the one somebody would leave out:
    -- an ambulance whose doors are shut around a healing player is exactly the
    -- picture the rule exists to prevent, and it is reachable -- another player
    -- can walk up and close them.
    --
    -- IT ENDS THE HEAL RATHER THAN PAUSING IT. A pause is a third state to
    -- reason about, it has no surface, and the player keeps what they healed
    -- either way. Ending is the same outcome as walking out.
    stopOnDoorsShut = true,

    -- ------------------------------------------------------------------
    -- THE SCENE
    -- ------------------------------------------------------------------

    -- "run the siren". Its own key rather than BR.Config.Rescue.siren, because
    -- that one carries a GAME-MECHANIC argument this feature does not share --
    -- there, the siren is the cost of the kit, the thing that makes a rescue
    -- findable, and it may not be turned off. Here it is what the owner asked
    -- for and nothing else depends on it, so it is a knob that can be turned
    -- down after a playtest without touching a balance decision.
    siren = true,

    -- The dome light, so a lit ambulance with its doors open reads the same way
    -- a parked rescue does. Same native, same guard: undocumented beyond its
    -- signature, so a build without it must still heal.
    interiorLight = true,

    -- ------------------------------------------------------------------
    -- THE CAMERA
    -- ------------------------------------------------------------------
    --
    -- "Use the scripted cam while healing in the ambulance."
    --
    -- THERE ARE NO NUMBERS HERE AND THAT IS THE POINT. client/ambheal.lua drives
    -- the camera off BR.Config.Rescue.camBackM and camHeight -- the two the
    -- owner tuned by eye on 2026-08-28 ("I don't think the camera is zoomed out
    -- enough", and the commit that finally moved them). The shot he approved for
    -- lying on that stretcher is the shot for lying on that stretcher; a second
    -- pair of numbers here would drift from it the first time he retunes one.

    -- ------------------------------------------------------------------
    -- THE PROMPT
    -- ------------------------------------------------------------------
    --
    -- ═══ THE VOCABULARY IS THE EXISTING ONE, TO THE WORD ═══
    --
    -- client/loot.lua draws `label` = the SUBJECT and `hint` = the VERB PHRASE,
    -- and it already has both spellings of the verb: 'Hold to open' for a
    -- container and 'Press to pick up' for an item. client/dbno.lua's revive is
    -- 'Hold to revive'; client/fuel.lua's pump is 'Hold to refuel'.
    --
    -- THIS IS A PRESS, so it takes the press spelling. You are not holding a key
    -- for fifteen seconds -- you press once to get in, the heal runs, and you
    -- press again to get out. A 'Hold to...' string would be a lie about the
    -- input, which is worse than a plain one.
    --
    -- THE SUBJECT IS `BR.Config.Rescue.blip.label` -- 'Ambulance' -- READ, NOT
    -- RETYPED. That string is already on the map for the same vehicle, so
    -- spelling it again here is how the map and the prompt come to disagree.
    promptHint = 'Press to heal',

    -- AND THERE IS NO SECOND STRING. The fuel pump has one ('Currently fueling')
    -- because the owner asked for it in as many words; nobody asked for one
    -- here, and the rule this project keeps is that UI copy nobody asked for
    -- does not get written. In particular THERE IS NO "press to get out" HINT --
    -- see the open questions in the report. The prompt comes down when the heal
    -- starts and there is nothing on screen until it ends.

    promptLift  = 1.1,    -- metres above the vehicle origin the plate floats
    promptScale = 1.6,    -- same as the fuel pump's; one plate size in the world
}

--- The stretcher, from the one place it was measured.
---
--- ═══ NOT A COPY. THE OWNER'S SURVEY, READ AT CALL TIME ═══
---
--- BR.Config.Rescue.stretcher holds six offsets and a pose that the owner
--- authored in game with /brattach at 0.01m and 1 degree steps, against model
--- `ambulance`, and confirmed by looking at it. config/rescue.lua's own note is
--- the whole argument and it applies here word for word:
---
---   "THEY ARE ONLY VALID FOR AN IDENTICAL ATTACH ... same bone index 0, same
---    argument tail `false, false, false, false, 2, true`. Changing the bone or
---    any of those flags silently moves the body somewhere the owner never
---    approved."
---
--- ...and the seventh number is the POSE, which the six were measured against.
--- client/ambheal.lua plays the same clip with the same TaskPlayAnim arguments
--- for the same reason: "a ped attached at (-0.010, -3.100, 1.690) in any other
--- posture is not at the offset the owner approved".
---
--- READ AT CALL TIME rather than copied at load, so the day he re-surveys it
--- with /brattach both features move together and neither file is touched.
---
--- @return table  { x, y, z, pitch, roll, yaw, pose = { dict, anim } }
function BR.Config.AmbHeal.stretcher()
    local R = BR.Config.Rescue
    return (R and R.stretcher) or {}
end

--- Which models count as an ambulance.
---
--- ONE LIST, config/rescue.lua's. See the block above; this exists so the reader
--- is a function rather than a reach across two config tables at four call
--- sites, and so a future second list has one place to fail to be added.
--- @return string[]
function BR.Config.AmbHeal.models()
    local R = BR.Config.Rescue
    return (R and R.models) or { 'ambulance' }
end

--- What the plate calls the thing you are standing behind.
---
--- BR.Config.Rescue.blip.label, which is already the word this vehicle is given
--- on the map. Retyping 'Ambulance' here would be a second copy of a string that
--- has exactly one meaning.
--- @return string
function BR.Config.AmbHeal.label()
    local R = BR.Config.Rescue
    return ((R and R.blip) or {}).label or 'Ambulance'
end
