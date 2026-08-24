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
    -- THEY CARRY NO `id`, and nothing requires one: the id is only ever used in
    -- a log line, and `pointName` in server/rescue.lua falls back to the
    -- coordinates. An id invented here would not match the one the owner would
    -- choose later.
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
    --
    -- The driving STYLE is the part that keeps it on roads: 262144 is
    -- "avoid obstacles, stop for vehicles, use roads" WITHOUT the shortcut bit
    -- that lets an AI driver cut across open ground. A grass-crossing ambulance
    -- is both wrong-looking and the single most reliable way to wedge one.
    driveSpeed       = 30.0,
    driveStyle       = 262144,
    driverAbility    = 0.6,   -- not 1.0: "erratically" is the brief
    driverAggression = 0.8,

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
    tickMs = 1000,

    -- Metres of progress the server must SEE between judgements for the rescue
    -- to count as moving. Measured on the server's own position samples of the
    -- player's ped, never reported by the client.
    progressM = 8.0,

    -- How long with no progress before the server orders a re-place.
    stuckAfterMs = 5000,

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
    -- ARRIVAL
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
-- ═══ NOTHING ACCUMULATES ═══
--
-- A station that is emptied and refilled repeatedly must not end a match with a
-- queue of ambulances in it. Every rescue ambulance is deleted by
-- client/rescue.lua's `cleanup`, which runs on all five endings -- delivered,
-- destroyed, deadline, the match tearing down underneath the ride, and the
-- resource stopping. The vehicle is also created as a mission entity, so the
-- engine's own population culling never removes it while a rescue is live and
-- never has to be relied on to remove it afterwards.

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
