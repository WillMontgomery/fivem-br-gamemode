-- The CPR kit, and the ambulance ride it buys (#191).
--
-- WHAT THE ITEM DOES. In a SOLO match, a player carrying a CPR kit does not die
-- when they run out of health -- they go down, alone, with nobody able to pick
-- them up. From there the only two exits are the kit (an ambulance comes and
-- drives them back into the match) and the bleed timer (they die anyway).
--
-- ═══ SOLOS ONLY. THE SQUAD VERSION WAS ASKED FOR AND THEN WITHDRAWN ═══
--
-- Owner, 2026-08-23: "CPR kit only in solos".
--
-- Earlier the SAME DAY the owner described a squad behaviour instead -- kits as
-- "strictly self-use inventory items, which, when used in squads, immediately
-- prevents that player from being revived by any other players for that one
-- use". That is a real design and it is NOT the one being built: the later
-- message supersedes it, and the revive lockout it describes DOES NOT EXIST
-- ANYWHERE IN THIS TREE. It is written down here so the next person to read the
-- issue thread finds the resolution beside the code rather than re-deriving it
-- from two contradicting quotes and picking the wrong one.
--
-- Mechanically, "solos only" is not a check in this file. It falls out of
-- server/combat.lua's `BR.Combat.canBeDowned`, which asks the mode first and the
-- kit second -- see the block there. A squad player holding a kit gets exactly
-- what a squad player has always got: knocked down, revivable by a mate.
--
-- ═══ THE AMBULANCE IS NOT INVINCIBLE, AND THAT REVERSES THE ISSUE BODY ═══
--
-- Owner, 2026-08-23: "the ambulance vehicle must deliberately not be invincible
-- (not sure if we said before). If the vehicle blows up (most likely other
-- players shot it) then the dead player inside is out."
--
-- #191's step 4 asked for "godmode and bulletproof tyres". Godmode is now the
-- opposite of what is wanted: the ride is a siren-on, visible, findable target,
-- and destroying it eliminates the passenger. Every protection knob below was
-- re-decided against that sentence rather than inherited from the issue, and
-- each one carries its own reason. THE TYRES ARE THE ONE THAT SURVIVED, and not
-- for the reason the issue gave -- see `tyresBulletproof`.

BR = BR or {}
BR.Config = BR.Config or {}

BR.Config.Rescue = {
    enabled = true,

    -- ------------------------------------------------------------------
    -- THE POINTS, AND WHY THIS TABLE IS EMPTY
    -- ------------------------------------------------------------------
    --
    -- ONE LIST SERVES BOTH ENDS. #191: "The lists are universal pickup/drop-off
    -- points, so the same tooling serves both." A point is somewhere an
    -- ambulance can stand on a road: near the death it is a pickup, near the
    -- circle it is a drop-off, and the same 23 coordinates are eligible for
    -- either job on any given rescue.
    --
    -- THE OWNER AUTHORED 23 OF THESE IN GAME ON 2026-08-23 AND THEY LIVE IN
    -- config/map.lua, as `BR.Config.Map.AmbulanceSpawns`. THIS TABLE IS EMPTY ON
    -- PURPOSE and is NOT a second copy of them: duplicating twenty-three
    -- surveyed coordinates would guarantee the two lists drift, and the first
    -- symptom would be ambulances arriving at points the owner had already
    -- moved.
    --
    -- They are real ped-standing positions taken with /brcoords, not points
    -- picked off a map, which is why their z values can be trusted and their
    -- headings are the way a vehicle put there should face.
    --
    -- `BR.Config.Rescue.Points()` below is the only reader, and it reads
    -- map.lua's table at CALL time rather than copying it at load -- so the
    -- owner can add, move or delete a point in the one place he authored them
    -- and nothing here has to be touched.
    --
    -- THEY CARRY AN `id` SINCE 2026-08-28, derived from the nearest POI rather
    -- than invented -- the owner's console read `pickup=nil  dest=nil` on the
    -- first ride that worked, which is a rescue nobody can discuss without a map
    -- open. `pointName` in server/rescue.lua still falls back to the coordinates
    -- for a row without one, so the field stays optional. See the block above
    -- the table in config/map.lua for where the names come from.
    --
    -- WITH NO POINTS THE FEATURE IS INERT RATHER THAN BROKEN: server/rescue.lua
    -- refuses to start a rescue it cannot route, logs the reason, and the kit
    -- simply cannot be called. That is the correct behaviour if the table is
    -- ever emptied, and it is why there is no hardcoded fallback pair here.
    --
    -- Shape:  { id = 'optional', x =, y =, z =, heading = }
    points = {},

    -- ------------------------------------------------------------------
    -- THE VEHICLE
    -- ------------------------------------------------------------------

    model = 'ambulance',

    -- ------------------------------------------------------------------
    -- ...AND HOW LONG THE CLIENT WAITS FOR IT TO ARRIVE
    -- ------------------------------------------------------------------
    --
    -- Owner, 2026-08-28: "Other players have to be able to see the ambulance.
    -- Local is not acceptable." So the vehicle is created on the SERVER and
    -- cloned to the rescued player, and there are two waits on that path.
    --
    -- THE CLONE. The entity exists and is bucketed before RESCUE_BEGIN is sent,
    -- but OneSync only clones what is RELEVANT to a client -- 424 units of
    -- 2D distance for an empty vehicle -- and the ambulance is built an average
    -- of 825m from where the player fell. client/rescue.lua moves the streaming
    -- focus to the spawn point to make it relevant, and then waits here. Ten
    -- seconds rather than five: the whole of it is behind a fade, and the round
    -- that failed spent five seconds proving only that five was not enough to
    -- distinguish "slow" from "never".
    adoptMs = 10000,

    -- ═══ AND THE NUMBER THAT ACTUALLY MAKES THE CLONE HAPPEN ═══
    --
    -- SET_ENTITY_DISTANCE_CULLING_RADIUS, server-side, on the ambulance. OneSync
    -- decides relevancy with
    --
    --     if (overrideCullingRadius != 0.0f) return overrideCullingRadius;
    --     ... else return (424.0f * 424.0f);
    --
    -- and this native is what writes `overrideCullingRadius` (it squares the
    -- argument itself, so this is plain metres). 424 is what the failed round
    -- was fighting; the surveyed points average 825m from an arbitrary map
    -- position and 81.7% of the map is further than 424m from the nearest one.
    --
    -- TEN KILOMETRES IS "THE WHOLE MAP", DELIBERATELY. The map is roughly
    -- 8 x 11.5 km, so this is every client in the match, always -- which is the
    -- direct reading of the owner's "Other players have to be able to see the
    -- ambulance". A tighter number would be a distance at which the requirement
    -- quietly stops holding, and nobody would find out except in a firefight.
    --
    -- server/rescue.lua puts it back to 0.0 when the ride ends. The native is
    -- deprecated and its known failure (an entity far from its OWNER but near
    -- another player being teleported back to its spawn point) cannot touch a
    -- vehicle whose owner is attached to it -- but it absolutely could touch an
    -- abandoned one, so the widening lasts exactly as long as the ride.
    cullRadiusM = 10000.0,

    -- THE CONTROL. Every write the ride makes -- the mods, the siren, the lock,
    -- the drive task, the doors, the halt -- is a write to an entity this client
    -- did not create. NetworkRequestControlOfEntity returns whether the REQUEST
    -- was accepted rather than whether control arrived, so it is asked in a loop
    -- until NetworkHasControlOfEntity agrees or this expires.
    controlMs = 3000,

    -- HOW LONG TO KEEP ASKING AFTER THE GATE HAS GIVEN UP, which is a different
    -- question from controlMs and is asked for a different reason.
    --
    -- controlMs gates the SETUP: the mods, the siren and the lock have to be
    -- written at some point and cannot wait forever. This one runs alongside the
    -- ride and exists to settle an argument -- a vehicle from
    -- CreateVehicleServerSetter is created ORPHANED and only acquires an owning
    -- client once one is in scope, so control being three seconds late and
    -- control never coming look identical at controlMs and completely different
    -- at fifteen. If it arrives, the drive is re-tasked and the ride works; if
    -- it does not, the log says "refusal, not latency" with a number on it.
    --
    -- WELL INSIDE THE 300s DEADLINE and well outside the server's 5s stall
    -- clock, so a late arrival still leaves a journey worth making and the
    -- re-places are visible in the log either side of it.
    controlWatchMs = 15000,

    -- WHAT COUNTS AS AN AMBULANCE, for the ambient-discovery blip (owner,
    -- 2026-08-23: "There will also be ambulances around the map which spawn
    -- naturally. If a player gets into one that we weren't aware of, add it to
    -- our list of blips").
    --
    -- ONE LIST FOR BOTH JOBS, so the vehicle the rescue BUILDS and the vehicles
    -- it RECOGNISES can never mean different things. `model` above must be one
    -- of these; a second, longer list for recognition is how a rescue ambulance
    -- ends up not counting as an ambulance.
    --
    -- Just the one model today. The obvious candidates for a second are not
    -- ambulances: `lguard` is a lifeguard truck and `firetruk` carries no
    -- stretcher, and blipping either as medical transport would be a lie on the
    -- map.
    models = { 'ambulance' },

    -- The driver. config/peds.lua already names this model as 'Paramedic'; it
    -- is read by hash here rather than through the ped catalogue because that
    -- catalogue is the player-cosmetics list and has nothing to do with NPCs.
    driverModel = 's_m_m_paramedic_01',

    -- SIREN ON THE WHOLE TIME (owner, 2026-08-23, reaffirming #191 step 4).
    --
    -- It was a flourish when the ambulance was invincible. It is a GAME MECHANIC
    -- now: the siren is what makes the ambulance findable, and being findable is
    -- the cost the kit charges. Turning it off at any point -- including on
    -- arrival, which #191 step 7 asked for -- would quietly remove that cost, so
    -- it is not turned off at any point and there is no knob to do it.
    siren = true,

    -- WINDOW TINT OFF: "the player must be visible inside" (#191 step 4). Now
    -- load-bearing rather than cosmetic -- somebody deciding whether to shoot
    -- the ambulance should be able to see there is a person in it. 0 is the
    -- stock 'None' tint.
    windowTint = 0,

    -- MAXIMUM UPGRADES EXCEPT SUSPENSION (#191 step 4). Suspension is excluded
    -- because it changes ride height, and the stretcher offset below is measured
    -- against the stock cabin floor -- a lowered ambulance puts the ped through
    -- it. The engine/brakes/transmission tiers are what stop a heavy van losing
    -- a race against a storm that is already shrinking.
    upgrades = {
        -- GTA mod slot indexes. `max` means "the highest index this vehicle
        -- actually has", resolved per vehicle at spawn -- a hardcoded tier is
        -- how you get a silently-unmodified vehicle when a model has fewer.
        engine       = 'max',
        brakes       = 'max',
        transmission = 'max',
        armour       = 'max',
        turbo        = true,
        -- DELIBERATELY ABSENT: suspension. See above.
    },

    -- ------------------------------------------------------------------
    -- WHAT MAY AND MAY NOT KILL THE PASSENGER
    -- ------------------------------------------------------------------
    --
    -- ═══ THE TYRES, RE-DECIDED RATHER THAN INHERITED ═══
    --
    -- #191 listed bulletproof tyres in the same breath as godmode, as part of
    -- one protection package. That package is gone, so the tyres had to be
    -- argued for again on their own, and the argument that keeps them is NOT
    -- about protection:
    --
    --   Shooting a tyre out does not create the outcome the owner asked for. It
    --   cannot blow the ambulance up and it cannot kill the passenger. All it
    --   does is STOP the ambulance -- which drops it into the stuck-recovery
    --   machinery, the most dangerous code in this feature and the one place a
    --   player can be stranded or wrongly resurrected. Shooting out a tyre would
    --   be a way to force that machinery to run, repeatedly, from outside.
    --
    -- So the tyres stay bulletproof because it REMOVES A PATH INTO THE RECOVERY
    -- LAYER, not because it protects anybody. Every way of actually killing the
    -- passenger is untouched: the ambulance still burns, still explodes, and
    -- still dies to sustained fire.
    tyresBulletproof = true,

    -- ═══ A CRASH BAD ENOUGH IS A WRECK, EVEN IF IT NEVER EXPLODES ═══
    --
    -- Owner, 2026-08-23: "if the ambulance gets in a wreck, even if it doesn't
    -- blow up, the vehicle health should go to 0 if it's bad enough. In this
    -- case the rescue also failed, in addition to the failure mode of being
    -- blown up."
    --
    -- WHAT THIS FIXES. There were two bad endings -- destroyed (the client sees
    -- the wreck and reports it) and never-moved (three re-places and still
    -- nothing). A crash that mangles the ambulance without killing it fell
    -- between them: it reads to the server as A VEHICLE THAT HAS STOPPED
    -- MOVING, which is layer 2's signal, so the recovery ladder TELEPORTS THE
    -- WRECK ONTO A ROAD and tells it to drive on. Either it limps to the
    -- destination and delivers a player whose ambulance was destroyed, or it
    -- burns three re-places and ~20 seconds arriving at the elimination this
    -- now reaches in one tick.
    --
    -- ═══ WHAT "BAD ENOUGH" IS MEASURED AGAINST, WHICH IS NOT A NEW NUMBER ═══
    --
    -- The game already has a definition of "vehicle health" and it is on screen
    -- in every car: client/fuel.lua's `healthPct` takes the WORST of
    -- GetVehicleBodyHealth, GetVehicleEngineHealth and GetVehiclePetrolTankHealth
    -- over BR.Config.Fuel.healthMax, and the HUD draws it as the condition bar.
    -- This threshold is a fraction of THAT number, so "the vehicle health went
    -- to zero" means the same thing here as it does on the bar the owner is
    -- looking at, and a change to one cannot silently disagree with the other.
    --
    -- ═══ WHY 25, AND WHY IT CANNOT FIRE ON A NORMAL DRIVE ═══
    --
    -- #213 made vehicles roughly five times more fragile than stock -- see
    -- config/vehicles.lua's BR.Config.VehicleDamage -- so this had to be argued
    -- against the POST-#213 world rather than GTA's.
    --
    -- A quarter is chosen because of what the three pools do at that depth. The
    -- engine pool is the one that moves fastest under #213 (its stock multiplier
    -- is the highest of the three, 1.5, so it scales to ~7.5), and an engine at
    -- a quarter is already smoking and losing power -- GTA starts the engine
    -- fire well under half. So by the time the WORST of the three is at 25 the
    -- ambulance is visibly finished, which is exactly the state the owner
    -- described and could not previously report.
    --
    -- And it is a long way from a scrape. The NPC drives on roads at
    -- `driveSpeed` with `driverAbility`/`driverAggression` set below; clipping a
    -- lamppost or grazing a wall costs single-digit percent even at 5x, and
    -- the pool it costs it from is the BODY, which starts at the same 1000 as
    -- the others. Three quarters of the toughest pool is not a kerb, a bollard
    -- or a parked car -- it is a head-on at speed, which is the case being asked
    -- for. A rescue that failed because the NPC clipped a lamppost would be a
    -- worse bug than the one this fixes, so the number is deliberately set where
    -- a survivable knock cannot reach it.
    --
    -- IT IS THE NUMBER TO TURN, and the direction is plain: raise it to fail
    -- rescues on lighter crashes, lower it to demand a bigger one. At or below
    -- zero the check is off and only an explosion or a stall can end a ride
    -- badly, which is the pre-2026-08-23 behaviour and a legitimate rollback.
    wreckedAtPct = 25.0,

    -- ═══ THE PED'S PROTECTION, AND WHY THE ISSUE'S REASON IS DEAD ═══
    --
    -- #191 step 5 argued the ped needs no protection BECAUSE the vehicle is
    -- protected. That premise is gone, so the conclusion had to be re-reached
    -- from scratch. It lands in the same place by the OPPOSITE argument, and the
    -- old sentence must not be quoted again as though it still held:
    --
    --   the ped is not protected FROM the vehicle's destruction, because the
    --   vehicle's destruction killing the passenger is the entire point of the
    --   owner's reversal. Anything that shielded the ped from it would be
    --   godmode wearing a different name.
    --
    -- BUT THE PED IS ALREADY INVINCIBLE AND NOT BY ANYTHING HERE. A player in
    -- DBNO is `SetPlayerInvincible(true)` for the whole downed state
    -- (client/natives.lua's latch), and a rescued player IS in DBNO for the
    -- whole ride. That is deliberate, it predates this feature, and this feature
    -- does not weaken it -- a downed player's health is a countdown, not a bar,
    -- and re-mortalising the ped to let an explosion reach it would put every
    -- other downed player back in the blast radius of the bug that latch fixed.
    --
    -- SO THE EXPLOSION DOES NOT KILL THE PED. THE SERVER DOES.
    --
    -- Destruction is a RESCUE OUTCOME, not a ped-damage event: the client
    -- watching the ambulance reports the wreck, and the server eliminates the
    -- player through the ordinary BR.Combat.eliminate path with cause 'rescue'.
    -- That is the same authority split every other death in this game already
    -- has -- the client observes, the server decides -- and it means the owner's
    -- rule is enforced by the one component that cannot be lied to about the
    -- consequence, rather than by the engine's damage model. See
    -- server/rescue.lua for how a silent client is caught.
    --
    -- There is consequently NO ped proofs table here. It would be a knob that
    -- changed nothing, which is worse than no knob at all.

    -- ------------------------------------------------------------------
    -- THE STRETCHER
    -- ------------------------------------------------------------------
    --
    -- ═══ MEASURED IN GAME BY THE OWNER, 2026-08-23 ═══
    --
    -- Authored with /brattach (client/attachtune.lua) at 0.01 m and 1 degree
    -- steps against model `ambulance`, and confirmed by looking at it: "Here's
    -- the coords. Looks perfect just like this."
    --
    -- These replace a placeholder guess that was nearly two metres out in y and
    -- carried a 90-degree roll. THE ROLL IS ZERO, which is worth noticing before
    -- anybody "corrects" it back: the guess assumed a ped had to be rolled onto
    -- its back to lie down, and in the event the ambulance's own cabin geometry
    -- and the pose put the body where it belongs without one. Do not reintroduce
    -- a rotation to make the numbers look more like what a stretcher ought to
    -- need -- these were arrived at by moving a real ped until it looked right.
    --
    -- THEY ARE ONLY VALID FOR AN IDENTICAL ATTACH, and client/rescue.lua's is
    -- identical -- same bone index 0, same argument tail
    -- `false, false, false, false, 2, true`, which is client/bus.lua:244's shape
    -- and the one /brattach itself used. Changing the bone or any of those flags
    -- silently moves the body somewhere the owner never approved.
    --
    -- One difference that does NOT affect them: the bus attaches to a LOCAL,
    -- non-networked vehicle and this attaches to a NETWORKED one, because #191's
    -- ambulance has to exist on other players' machines for them to destroy it.
    -- An offset and a rotation are relative to the vehicle MODEL, and the model
    -- is the same ambulance either way.
    stretcher = {
        x = -0.010, y = -3.100, z = 1.690,
        pitch = 0.0, roll = 0.0, yaw = 1.0,

        -- ═══ THE POSE IS THE SEVENTH NUMBER, AND IT IS NOT DECORATION ═══
        --
        -- Owner, 2026-08-28: "please enforce the ped emote in the ambulance as
        -- we discussed. It should be sunbathe".
        --
        -- The six offsets above were authored against THIS CLIP -- /brattach's
        -- first candidate, the one client/attachtune.lua prints beside the
        -- numbers precisely because "the numbers only mean anything alongside
        -- the pose they were measured with". A ped attached at
        -- (-0.010, -3.100, 1.690) in any other posture is not at the offset the
        -- owner approved; it is at the same coordinates with a different body
        -- around them, which is how the note above about the zero roll came to
        -- be true ("the ambulance's own cabin geometry AND THE POSE put the body
        -- where it belongs").
        --
        -- AN ANIMATION, NOT A SCENARIO, and attachtune.lua carries the full
        -- argument: TaskStartScenarioInPlace('WORLD_HUMAN_SUNBATHE') is a TASK
        -- that sites itself against the ground and moves the ped, which is a
        -- direct fight with AttachEntityToEntity over where the body is.
        -- TaskPlayAnim on the dictionary poses the ped and asks for nothing
        -- else. Changing this to a scenario would drift the body with nothing
        -- to indicate it had.
        --
        -- THE MALE DICTIONARY FOR EVERY PED, deliberately. There is a
        -- `@female@back@base` sibling and it is NOT selected per model: the
        -- offset was measured against this one, and a clip that varies with the
        -- player's cosmetic choice is an offset that is only right for half the
        -- lobby. The difference lying on a stretcher is a wrist.
        pose = {
            dict = 'amb@world_human_sunbathe@male@back@base',
            anim = 'base',
        },
    },

    -- ═══ VEHICLE EXTRAS 1 AND 2 ═══
    --
    -- Owner, 2026-08-23: "make sure vehicle extra 1 and 2 are enabled please".
    --
    -- THE NATIVE'S THIRD ARGUMENT IS `disable`, NOT `enable`, AND THAT IS WHY
    -- THIS LIST IS DATA RATHER THAN THREE CALLS AT THE SPAWN SITE.
    -- SetVehicleExtra(veh, id, toggle) turns the extra ON when toggle is FALSE.
    -- Passing `true` to "enable" is the obvious reading, the wrong one, and
    -- exactly the edit a future reader makes while tidying up -- so the
    -- inversion is stated once, in client/rescue.lua, beside the one call that
    -- performs it, rather than being re-derived at every use.
    extras = { 1, 2 },

    -- ------------------------------------------------------------------
    -- THE DRIVE
    -- ------------------------------------------------------------------

    -- "The driver drives erratically but stays on roads" (#191 step 6).
    -- Deliberately the same shape as the ambient erratic-driver knobs in
    -- client/gamerules.lua, because it is the same engine behaviour being asked
    -- for and two different spellings of it would drift.
    driveSpeed       = 30.0,

    -- ═══════════════════════════════════════════════════════════════════
    -- THE DRIVING STYLE, AS A BITFIELD WITH MOST OF IT SWITCHED OFF
    -- ═══════════════════════════════════════════════════════════════════
    --
    -- Owner, 2026-08-28: "a note on the driving style - the driver doesn't seem
    -- to be aware of other vehicles on the road. Can that be changed?"
    --
    -- HE IS DESCRIBING THE VALUE EXACTLY. It was 262144 -- one bit,
    -- `UseShortCutLinks`, and NOTHING ELSE. FiveM's own DrivingStyle enum has a
    -- name for that value and the name is `PloughThrough`. Every avoidance bit
    -- and every stopping bit was clear, so the driver was not failing to avoid
    -- traffic; it had never been told traffic existed.
    --
    -- (The comment that used to sit here claimed 262144 was "avoid obstacles,
    -- stop for vehicles, use roads". It is none of those three. It is recorded
    -- rather than quietly deleted because the wrong reading is the reason the
    -- value survived four rounds of playtesting unexamined.)
    --
    -- ═══ THE BITS, FROM R*'s OWN eVehicleDrivingFlags ═══
    --
    -- Named from the enum published in the Cfx native reference for
    -- SET_DRIVE_TASK_DRIVING_STYLE, not from the community calculator -- three of
    -- the widely-copied community labels are wrong (256 is
    -- `GoOffRoadWhenAvoiding`, not "use blinkers"; 524288 is
    -- `ChangeLanesAroundObstructions`, not "ignore roads"; 8 is
    -- `SteerAroundStationaryVehicles`, not "avoid EMPTY vehicles").
    --
    --        1  StopForVehicles                 ON   brake, not only swerve
    --        2  StopForPeds                     off
    --        4  SwerveAroundAllVehicles         ON   moving AND stationary
    --        8  SteerAroundStationaryVehicles   off  see below
    --       16  SteerAroundPeds                 ON
    --       32  SteerAroundObjects              ON
    --      128  StopAtTrafficLights             off  see below
    --      256  GoOffRoadWhenAvoiding           off  it must stay on roads
    --      512  AllowGoingWrongWay              off
    --   262144  UseShortCutLinks                ON   alleys and driveways
    --   524288  ChangeLanesAroundObstructions   ON   go round, not just swerve
    --                                          ----
    --                                        786485
    --
    -- 786485 is a value Rockstar itself ships, which is worth more than a value
    -- assembled by hand: it is a combination the game's own drivers are known to
    -- cope with.
    --
    -- ═══ WHY NOT BIT 8, WHICH LOOKS LIKE THE ONE THIS MAP NEEDS ═══
    --
    -- BR.Config.Ambient runs `parked` at 1.0 against moving traffic at 0.45 --
    -- parked cars are this gamemode's vehicle SUPPLY -- so "avoid empty
    -- vehicles" sounds like the bit that matters most here. It is not that bit.
    -- 8 is `SteerAroundStationaryVehicles`, and 4 (`SwerveAroundAllVehicles`)
    -- ALREADY COVERS STATIONARY ONES: all vehicles includes parked ones. Setting
    -- both would be a narrower rule stacked on a rule that contains it, and R*
    -- ships them as ALTERNATIVES -- its "avoid" presets (786468, 786469, 786485)
    -- use 4, its "stop for" presets (786475, 786603) use 8, and no shipped
    -- preset uses both. There is no gap to close, so the safe move is the one
    -- the engine's own presets take.
    --
    -- ═══ AND WHY NOT TRAFFIC LIGHTS ═══
    --
    -- The siren is on for the whole ride by the owner's explicit instruction,
    -- and an ambulance running its siren does not sit at a red -- so realism
    -- argues AGAINST 128 here rather than for it. The deadline argues the same
    -- way and more strongly: a rescue that expires while the ambulance is
    -- driving is the exact bug the arrival work above exists to fix, and every
    -- junction spent idling is time taken off that budget.
    --
    -- IT IS THE NUMBER TO TURN. Add 128 for lights, 2 to brake for pedestrians,
    -- 512 to allow overtakes into oncoming lanes. Do NOT add 256, 4194304 or
    -- 16777216 -- all three let the driver leave the road network, and a
    -- grass-crossing ambulance is both wrong-looking and the most reliable way
    -- to wedge one.
    -- Owner, 2026-08-29: "it's going in circles on dirt roads, so I'd like to
    -- see if we can take dirt roads out. Let's use 524415".
    --
    -- HE FOUND THE RIGHT BIT. 524415 is the previous value MINUS 262144,
    -- UseShortCutLinks -- which is precisely the permission to leave the road
    -- network for a shorter path. Every avoidance bit is kept; only the licence
    -- to take a dirt track is withdrawn.
    driveStyle       = 524415,

    -- The shortest journey worth making. Any surveyed point nearer than this to
    -- the pickup is refused as a destination, along with the pickup itself.
    --
    -- Owner, 2026-08-28: "It drove for maybe 30 seconds successfully, but then
    -- de-spawned and put me back at the point where it spawned." The pickup is
    -- one of the same 23 surveyed points the destination is chosen from, and it
    -- is zero metres from itself, so it won every time. The ride was a circle
    -- and the delivery was a teleport to where it began.
    --
    -- 150m rather than 1m because two car parks in one forecourt would produce
    -- the same non-journey with none of the obviousness.
    minTripM         = 150.0,
    -- ═══ THE STYLE WAS NEVER WHAT WAS HITTING THE CARS ═══
    --
    -- Owner, 2026-08-28, after 262460 and then 4980863: "The driver still
    -- doesn't swerve around obstacles and vehicles... Should we adjust
    -- something or should we try a different driving style?"
    --
    -- Neither. A driving STYLE is a set of permissions -- may swerve, may stop,
    -- may cross lanes. These two decide whether the driver is any good at
    -- exercising them, and no bit in any style overrides them.
    --
    -- 0.8 AGGRESSION IS A DRIVER THAT PUSHES THROUGH TRAFFIC rather than
    -- yielding to it, and 0.6 ability is one that reads the road badly while
    -- doing so. Together they describe exactly what he watched happen twice:
    -- a van that has permission to swerve and neither the skill nor the
    -- temperament to use it.
    --
    -- THIS REVERSES #191, DELIBERATELY AND ON HIS ASK. That issue says "The
    -- driver drives ERRATICALLY but stays on roads", which is where 0.6/0.8
    -- came from -- they were the brief being met, not an oversight. It also
    -- warned that erratic driving makes wedging likelier, and wedging is what
    -- the stuck-recovery ladder exists for. Restoring the old feel is these two
    -- numbers and nothing else.
    driverAbility    = 1.0,
    driverAggression = 0.0,

    -- ------------------------------------------------------------------
    -- THE CAMERA
    -- ------------------------------------------------------------------
    --
    -- ═══ TWO NUMBERS, AND BOTH OF THEM ARE READ NOW ═══
    --
    -- Owner, 2026-08-28: "I don't think the camera is zoomed out enough" -- said
    -- AFTER a commit that took the height from 3.0 to 4.83 ("zoom out our
    -- scripted camera by like 6ft"). The reason he saw no change is that neither
    -- number was ever reaching the camera:
    --
    --   1. `R.camHeight` DID NOT EXIST IN THIS FILE. client/rescue.lua read
    --      `R.camHeight or 4.83`, the key was never added here, so the literal
    --      default was the whole value -- a config knob with nothing behind it.
    --   2. AND IT ONLY EVER TOUCHED THE CREATION FRAME. The camera is
    --      repositioned every frame by `rescue.cam`, off HARDCODED 7.0 and 2.5,
    --      so whatever CreateCamWithParams was handed was overwritten before
    --      anybody saw it. The effective camera had not moved since it was
    --      written.
    --
    -- BOTH ARE THE PER-FRAME NUMBERS NOW, which is the only place a camera value
    -- can mean anything in this file. The distance is the half that was missing
    -- from his complaint: raising a camera without pulling it back looks down at
    -- the ambulance's roof rather than back at the ambulance, so height alone
    -- could never have produced "zoomed out".

    -- ═══ AND THE LINE ON THE MINIMAP ═══
    --
    -- Owner, 2026-08-28: "Curiously the route was not on the minimap."
    --
    -- A real engine gate rather than a bug of ours: GPS route rendering on the
    -- RADAR is conditioned on the player being in a vehicle, and this player is
    -- ATTACHED to the stretcher rather than seated -- the same property that
    -- keeps them out of the fuel registry. START_GPS_MULTI_ROUTE's third
    -- parameter exists precisely to override it ("Draws the GPS path regardless
    -- if the player is in a vehicle or not"), so client/rescue.lua draws that
    -- route alongside the waypoint. This is its HUD colour; 5 is yellow.
    routeColour = 5,

    -- The boom length -- how far behind the ambulance the camera sits, before
    -- pitch. Was a hardcoded 7.0.
    camBackM  = 11.0,

    -- How high above the vehicle's own origin the camera sits at level pitch.
    -- Was a hardcoded 2.5.
    camHeight = 5.5,

    -- ------------------------------------------------------------------
    -- THE CLOCK, AND WHY IT IS NEVER SHOWN
    -- ------------------------------------------------------------------
    --
    -- #191 step 6 asked for "a timer shown to the player". IT IS NOT SHOWN, and
    -- that is a deliberate override of the issue body rather than an omission.
    --
    -- The owner's rule for this feature is that the single "press [key] to call
    -- a medic" prompt is THE ONLY NOTIFICATION IN THE ENTIRE CYCLE and nothing
    -- else may be shown at any point. A countdown is something else. The timer
    -- below still exists and still does its whole job -- it is the hard deadline
    -- that guarantees a rescue always ends -- it simply has no UI, and there is
    -- no code anywhere in this feature that draws one.
    --
    -- DERIVED PER ROUTE, NEVER A CONSTANT (#191 is explicit): a long route
    -- against a short timer fails every time. See BR.RescueEta in
    -- shared/rescue_solve.lua for the arithmetic.

    -- Metres per second the solver assumes the ambulance averages, door to door.
    -- Well under `driveSpeed` on purpose: that is a target speed on open road,
    -- and this is an average over junctions, traffic and a driver told to be
    -- erratic.
    etaSpeed = 16.0,

    -- Road distance is longer than the straight line. 1.35 is the usual planar
    -- fudge for a city grid; it is a multiplier on the solver's straight-line
    -- distance rather than a route query because there is no offline road graph
    -- on the server (config/map.lua's Roads block explains why).
    etaRouteFactor = 1.35,

    -- The deadline is the estimate plus this much slack, floored. Slack is what
    -- absorbs the recoveries below: a rescue that gets stuck once and is
    -- re-placed should still make it inside the deadline.
    etaSlack   = 1.8,
    etaFloorMs = 20000,

    -- A BOUND ON THE SLACK, NOT ON THE JOURNEY. BR.RescueDeadlineMs will exceed
    -- this rather than return a deadline shorter than the drive it was derived
    -- from -- see the guarantee written into that function, and the test that
    -- found the case where a clamp alone got it wrong.
    etaCeilMs  = 300000,

    -- ------------------------------------------------------------------
    -- STUCK, AND TELLING IT FROM DESTROYED
    -- ------------------------------------------------------------------
    --
    -- #191 designed the recovery layers on a premise that the owner's 2026-08-23
    -- message removed: that leaving the match from inside the ambulance is
    -- ALWAYS a bug. It is not any more -- being blown up in there is now a
    -- legitimate way to die -- so the recovery has to tell the two apart, and
    -- getting it wrong strands a player forever in one direction and resurrects
    -- a properly-killed one in the other.
    --
    -- THE ANSWER IS NOT A HEURISTIC. It is a split over WHO OBSERVES WHAT, and
    -- the consequences are matched to the evidence each side can be trusted
    -- with. The whole scheme is written out in server/rescue.lua; these are the
    -- numbers it runs on.

    -- How often the server judges a rescue in flight.
    --
    -- THIS IS A JUDGEMENT CADENCE, NOT A REFRESH RATE, and the two were one
    -- number until 2026-08-28. Lowering it to make the map smoother would also
    -- make the stall detector twice as twitchy, because `moveM` is metres of
    -- progress required BETWEEN judgements -- so a faster tick with the same
    -- threshold declares a slow-moving ambulance stuck. They are separate now.
    tickMs = 1000,

    -- How often the ambulance's position is published to the map.
    --
    -- Owner, 2026-08-28: "The ambulance location blips don't refresh fast
    -- enough."
    --
    -- It rode the judgement tick at 1000ms, and an ambulance at driveSpeed
    -- covers about 30 metres in that time -- so the blip was up to a block
    -- behind the van it was pointing at, which on a map is the difference
    -- between chasing something and guessing where it went.
    --
    -- 250ms MATCHES WHAT SQUADMATE BLIPS ALREADY DO. The roster samples
    -- positions at 4Hz and squad blips are drawn from that, so this is the
    -- cadence the rest of the map already moves at rather than a new one -- and
    -- the position is a value the server already holds, so publishing it more
    -- often costs a message, not a sample.
    blipMs = 250,

    -- Metres of progress the server must SEE between judgements for the rescue
    -- to count as moving. Measured on the server's own position samples of the
    -- player's ped, never reported by the client.
    -- ═══ THE STALL RULE, IN MILES PER HOUR ═══
    --
    -- Owner, 2026-08-29: "please trigger the stuck fix if they are moving less
    -- than 10mph for over 10 seconds".
    --
    -- `progressM` used to carry this, as metres between judgements -- an
    -- implicit ~18mph floor that only existed if you also knew tickMs, and that
    -- changed silently whenever either number moved. These two say it outright.
    minSpeedMph = 10.0,

    -- How long with no progress before the server orders a re-place.
    stuckAfterMs = 10000,

    -- How far the re-place moves the ambulance. #191 says "~50ft"; that is 15m.
    replaceDistM = 15.0,

    -- HOW MANY TIMES A RE-PLACE MAY BE ORDERED BEFORE THE SERVER STOPS
    -- BELIEVING IN THE AMBULANCE. This is the number that separates stuck from
    -- destroyed without asking the client anything, and it is small on purpose:
    -- a re-place puts a working ambulance back on a road and a working ambulance
    -- then MOVES. One that has been re-placed this many times and has still
    -- never moved is not stuck, it is gone, and delivering its passenger would
    -- be resurrecting somebody another player legitimately killed.
    maxRecoveries = 3,

    -- ------------------------------------------------------------------
    -- ARRIVAL, AND THE PARKED AMBULANCE IT LEAVES BEHIND
    -- ------------------------------------------------------------------
    --
    -- ═══ EIGHT METRES WAS NEVER REACHED ONCE ═══
    --
    -- Owner, 2026-08-28: "when we got near the destination the driver just
    -- started driving around aimlessly, until eventually I was spawned at the
    -- destination on my own". The server log said the same thing outright --
    -- "the deadline expired on a rescue that was driving".
    --
    -- The destinations are CAR PARKS and TaskVehicleDriveToCoord routes to the
    -- ROAD NETWORK. When the exact coordinate is not on it the vehicle gets as
    -- close as a road allows and then circles, so the old 8m test could not fire
    -- and layer 4 of the recovery ladder delivered every single ride.
    --
    -- ═══ THE OWNER REPLACED THE TEST WITH A DESIGN ═══
    --
    -- "If it can't arrive, I don't want it to circle. I want it to park as close
    -- as it can get, even if that's on the road. And remember we want the back
    -- left and right doors open when it parks. See if you can turn the dome
    -- light on too so it's obvious someone got out of it - doors open, lights
    -- on, but nobody inside. Then you can make the driver get out and run around
    -- aimlessly so players can take the ambulance"
    --
    -- So there is no "failed to arrive" branch anywhere in this feature. There
    -- is arriving and there is having got as close as it is going to get, and
    -- both end in the same parked ambulance. BR.RescueArrived in
    -- shared/rescue_solve.lua is the whole rule and carries the argument for
    -- why the signal is the CLOSEST APPROACH rather than the speed.

    -- Close enough to the surveyed point to call it arrived outright.
    --
    -- FIFTY METRES, THE OWNER'S NUMBER, 2026-08-28: "Let's also change the
    -- arrival radius to 50m please". It needs no argument from here, but it is
    -- worth writing down what it replaces and what it does NOT replace:
    --
    --   * IT REPLACES EIGHT METRES, which a vehicle routed to the nearest road
    --     node never reached at a car park, so no ride ever ended by arriving.
    --   * IT DOES NOT REPLACE `arriveNearM` BELOW. 50m ends most journeys well
    --     before the drive task does, which is exactly what stops the circling
    --     -- but a destination the router cannot get within 50m of at all is
    --     still a real case, and "park as close as it can get, even if that's on
    --     the road" is his answer to it. The two rules are two answers to one
    --     question and he asked for both.
    --
    -- IT IS ALSO THE AI's OWN STOP RANGE. TaskVehicleDriveToCoord's tenth
    -- argument was 4.0, and the native's documentation names small values as the
    -- failure mode in as many words ("20.0 works fine"). A driver told to stop
    -- within four metres of a point it can only reach within twenty is a driver
    -- that never stops -- which is the circling, from the other side. Passing
    -- this same number means the AI's idea of arriving and ours cannot drift.
    arriveM = 50.0,

    -- ...and how near it has to have got before "it has stopped getting closer"
    -- is allowed to end the ride. THIS IS THE GUARD THAT KEEPS A TRAFFIC JAM OUT
    -- OF THE ARRIVAL PATH: an ambulance wedged 800m out is a STUCK one, it is
    -- the server's to judge, and stuckAfterMs/maxRecoveries above have always
    -- handled it. Only a vehicle that reached the neighbourhood may park short.
    arriveNearM = 150.0,

    -- How long its closest approach may go without improving before the ride is
    -- over. A lap of a car park is ~10s at driveSpeed, so this cannot be reached
    -- by a vehicle still driving IN -- only by one going ROUND.
    arriveGiveUpMs = 6000,

    -- ------------------------------------------------------------------
    -- ...AND WHAT THE PARKED AMBULANCE LOOKS LIKE
    -- ------------------------------------------------------------------

    -- ═══ HOW IT STOPS ═══
    --
    -- BringVehicleToHalt(vehicle, distance, duration, bControlVerticalVelocity)
    -- -- "makes the vehicle stop immediately", `distance` being where it comes
    -- to rest and `duration` HOW LONG IT IS HELD THERE, IN SECONDS. Seconds, not
    -- milliseconds: this is the argument that looks like every other timeout in
    -- this config and is not one.
    --
    -- ═══ AND WHY IT IS THIS NATIVE AND NOT THE TWO OBVIOUS ONES ═══
    --
    --   TaskVehiclePark would trade a circling task for a PARKING task -- an AI
    --   that hunts for a bay and, when it cannot find one, does exactly the
    --   thing being fixed. "Park as close as it can get, even if that's on the
    --   road" is not a parking manoeuvre; it is stopping.
    --
    --   ClearPedTasks ALONE stops the DRIVER, not the vehicle. An ambulance at
    --   driveSpeed carries its momentum and coasts on with nobody steering.
    --
    -- So the task is cleared (nothing may re-accelerate) AND the vehicle is
    -- halted (it actually stops). The hold only has to outlast the fade that
    -- ends the ride, and by the time it lapses the medic is out of the seat.
    haltDistM = 8.0,
    haltHoldS = 6,

    -- ═══ THE TWO LOCK STATES, AND THE RIDE'S WAS WRONG ═══
    --
    -- `lockedState` is what the ambulance runs at while it is driving (#191 step
    -- 4, "so no other player can get in"). IT WAS 4, and 4 is not that:
    -- eVehicleLockState 4 is VEHICLELOCK_LOCKED_PLAYER_INSIDE -- "locked once a
    -- player enters, preventing others from entering" -- and the rescued player
    -- NEVER ENTERS. They are attached to the stretcher, not seated, which is the
    -- property this whole feature is built on. So the condition that arms lock
    -- state 4 never occurred and the doors were never locked at all.
    --
    -- 2 is VEHICLELOCK_LOCKED, "preventing entry by players and NPCs", which is
    -- the sentence #191 asked for. It is also the state client/vehrefuse.lua
    -- settled on for the same job, over 10 (CANNOT_ENTER) for a reason that
    -- applies here too: 10 keeps out somebody already inside, and this ride has
    -- produced enough stuck peds.
    lockedState = 2,

    -- ...and what it goes back to when it parks. 1 is VEHICLELOCK_UNLOCKED.
    --
    -- Owner, 2026-08-28: "That also means the doors need to unlock before the
    -- driver gets out". He is right twice over: an ambulance with its doors
    -- open, its dome light on and nobody in it THAT NOBODY CAN GET INTO is a
    -- scene that contradicts itself, and a ped told to leave a vehicle locked
    -- against entry is the kind of task that fails silently and strands him in
    -- the seat.
    --
    -- Nothing else in this tree re-asserts a lock on this vehicle -- checked;
    -- client/vehrefuse.lua is the only other writer of a door lock and it runs
    -- only for a player ALIVE or in WARMUP who is entering a refused vehicle,
    -- which a downed passenger is not. So unlocking once holds.
    unlockedState = 1,

    -- The dome light, so "somebody got out of it" is legible from outside.
    interiorLight = true,

    -- TaskLeaveVehicle flag 256: "normal exit but does not close the door". The
    -- driver's own door left open is part of the same picture the rear two and
    -- the dome light are painting.
    driverExitFlag = 256,

    -- ------------------------------------------------------------------
    -- DELIVERY
    -- ------------------------------------------------------------------
    --
    -- "Health restored" (#191 step 7), and it is FULL rather than the squad
    -- revive's `dbnoReviveHp`. The two are different prices for different
    -- things: a squad revive costs a mate eight exposed seconds and hands back
    -- 30, while the kit is an ultra-rare item spent in full, on a ride the
    -- player spent unable to shoot back, that other players were invited to end.
    -- Handing back a third of a health bar after all that would make the kit
    -- worse than dying.
    deliverHp = 100,

    -- Metres BEHIND the parked ambulance the ped is put down. #191 step 7:
    -- "directly behind the ambulance", which is where the rear doors are.
    dropBackM = 3.5,

    -- ------------------------------------------------------------------
    -- THE BLIP
    -- ------------------------------------------------------------------
    --
    -- Owner, 2026-08-23: "if someone takes it, we need to update it's location
    -- on the map for other players when their blips are shown."
    --
    -- A rescue ambulance is a MOVING vehicle that the owner has deliberately
    -- made destructible, and the siren exists to make it findable. A blip that
    -- moves with it is the map half of the same decision, and without one the
    -- only way to find a rescue in progress is to hear it.
    --
    -- ═══ THE RESCUED PLAYER DOES NOT SEE THEIR OWN ═══
    --
    -- The rule for this feature is that the "press [key] to call a medic" prompt
    -- is the only thing shown to the player being rescued, for the whole cycle.
    -- A blip on their own ambulance would be a second surface, it would tell
    -- them nothing they do not already know, and it would break a rule the owner
    -- has had to restate more than once. So the blip is drawn by every OTHER
    -- client and skipped on the one it belongs to -- which keeps "one
    -- notification" literally true for the person it is a promise to, while
    -- still doing the whole of what the owner asked for.
    blip = {
        enabled = true,
        sprite  = 153,        -- the game's own ambulance icon
        colour  = 1,          -- red
        scale   = 0.9,
        label   = 'Ambulance',

        -- ═══ WHO SEES IT, AND WHY THIS IS A KNOB RATHER THAN A RULE ═══
        --
        -- Everyone in the match. That is the direct reading of "for other
        -- players", and it is coherent with the rest of the design: siren on the
        -- whole time, tint off so the passenger is visible, destructible on
        -- purpose. All four say the same thing -- the ride is meant to be found.
        --
        -- IT IS A KNOB BECAUSE #219 OWNS THE REAL ANSWER. The owner's sentence
        -- came out of #219 (squad resurrection), where ambulance blips are shown
        -- while a squadmate is down and the audience question is that issue's to
        -- settle. This feature needs one moving blip and has no opinion about
        -- squads, so what is built here is the MECHANISM -- server-published
        -- coordinates, drawn client-side -- and #219 changes this one field
        -- rather than rebuilding any of it.
        --
        -- AND IT IS THE CAMPING KNOB TOO. #191 already flags the drop points as
        -- likely camping spots and defers it to playtesting; a map marker on a
        -- player who cannot shoot back sharpens that considerably. If it turns
        -- out to matter, this is the field to turn down, and doing so costs
        -- nothing else.
        audience = 'match',   -- 'match' | 'none'
    },
}

-- ---------------------------------------------------------------------------
-- "THE AMBULANCE AT THE NEAREST STATION HAS BEEN TAKEN"
-- ---------------------------------------------------------------------------
--
-- Owner, 2026-08-23: "if someone uses the CPR kit while the ambulance at the
-- nearest station has been taken, spawn a new ambulance at the same location for
-- the job."
--
-- ═══ THIS REQUIREMENT IS SATISFIED BY CONSTRUCTION, AND THAT IS WORTH WRITING
--     DOWN RATHER THAN QUIETLY RELYING ON ═══
--
-- The rescue ambulance is ALWAYS a fresh vehicle, created for the job at the
-- chosen point and deleted when the job ends. It is never the ambulance parked
-- at that station, whether or not one is there, whether or not somebody drove it
-- away, and whether or not what is standing there is a burnt-out shell. So
-- "taken" cannot block a rescue -- there is no path on which the rescue waits
-- for, looks for, or depends on a station's own vehicle.
--
-- ═══ WHY IT IS NOT THE STATION'S AMBULANCE, WHICH IS THE DECISION THE OWNER'S
--     SENTENCE LEAVES OPEN ═══
--
-- The ride is a scripted one: doors locked, siren on, tint off, maximum
-- upgrades, an NPC medic at the wheel, a player attached to the stretcher, and a
-- destination on rails. EVERY ONE OF THOSE IS A PROPERTY OF A VEHICLE WE MADE.
-- Commandeering a parked one would make all of them conditional on the state
-- somebody else left it in -- half-wrecked, on fire, facing a wall, full of an
-- enemy squad, or with its engine already dead -- and each of those is a
-- separate way for a rescue to fail after the kit has already been spent.
--
-- It also disposes of a question that has no good answer. Deciding whether a
-- station's ambulance "is still there" means picking a rule -- how far away is
-- too far, does a wrecked one count, does an occupied one count -- and every
-- rule is wrong in some case that will happen in a real match. The best version
-- of that check is one that is never asked, and not asking it is free.
--
-- WHAT IS ACTUALLY NEEDED IS MUCH SMALLER, and client/rescue.lua's `board` does
-- it: do not spawn ON TOP of whatever is standing there. `freeSpaceNear` walks a
-- fixed ring of offsets and parks in the first clear one, which covers a
-- station's own ambulance, a returned stolen one, and a second rescue arriving
-- at the same point -- the case #191 step 7 raises for the drop-off end.
--
-- ═══ NOTHING ACCUMULATES -- BY TWO MECHANISMS SINCE 2026-08-28 ═══
--
-- A station that is emptied and refilled repeatedly must not end a match with a
-- queue of ambulances in it. client/rescue.lua's `cleanup` runs on all five
-- endings -- delivered, destroyed, deadline, the match tearing down underneath
-- the ride, and the resource stopping -- and on four of them it deletes the
-- vehicle outright.
--
-- THE DELIVERED ENDING IS THE EXCEPTION AND IT IS THE OWNER'S: "doors open,
-- lights on, but nobody inside... so players can take the ambulance". An
-- ambulance deleted a second and a half after it parks is a scene nobody sees,
-- so a delivery RELEASES it instead -- SetEntityAsNoLongerNeeded, whose whole
-- documented meaning is "delete this as the engine sees fit". The guarantee
-- survives; what changed is who keeps it. The engine's population culler
-- reclaims an abandoned vehicle once nobody is near it, which is exactly the
-- moment it stops being the thing the owner asked for.
--
-- It is created as a mission entity for the ride itself, so nothing can cull it
-- while a rescue is live.

--- The pickup/drop-off points, from wherever they landed.
---
--- THE OWNER'S SURVEYED TABLE WINS, AND THIS FILE'S IS A FALLBACK. The 23 points
--- live in config/map.lua because that is where he authored them and where he
--- will edit them; reading them there rather than copying them here is the whole
--- reason the two can never disagree.
---
--- READ AT CALL TIME, NOT COPIED AT LOAD, so a point added or moved in map.lua
--- takes effect without this file being touched -- and so the load order between
--- the two configs cannot matter.
---
--- RETURNS THE TABLE ITSELF RATHER THAN A COPY, which is safe because every
--- caller only ever iterates it. Nothing in this feature writes to a point, and
--- nothing may start: it is the owner's survey data, shared with #219.
---
--- @return table[]  possibly empty; callers must handle that rather than assume
function BR.Config.Rescue.Points()
    local M = BR.Config.Map
    local surveyed = M and M.AmbulanceSpawns
    if type(surveyed) == 'table' and #surveyed > 0 then return surveyed end
    return BR.Config.Rescue.points
end
