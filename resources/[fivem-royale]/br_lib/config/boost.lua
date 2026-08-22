-- Vehicle boost: the numbers, in one place.
--
-- Every figure below is the owner's, from #203, and the ones that are not are
-- derived from those at the bottom of the file with their working shown. The
-- arithmetic that consumes them is br_lib/shared/boost_solve.lua, which is pure
-- and unit-tested; the two halves that call it are br_core/client/boost.lua (the
-- push, the flames and the meter) and br_core/server/boost.lua (the relay and
-- the fuel surcharge).
--
-- ═══ CLIENT-READ, SO NONE OF THIS MAY BECOME A CONVAR OVERRIDE ═══
--
-- config/overrides.lua's hard rule: a value it edits must be read ONLY on the
-- server, because config/*.lua is pulled into the client's Lua state too and an
-- override applied on one side alone gives the two different numbers for the
-- same setting with nothing comparing them. The client runs the meter, so every
-- key here is client-read and every key here is excluded from that file.
-- tools/test_config.lua enforces the direction.

BR = BR or {}
BR.Config = BR.Config or {}

BR.Config.Boost = {
    --- Off switch. The client registers nothing and the server relays nothing.
    enabled = true,

    --- ═══ FOUR SECONDS OF PUSH, SIX TO GET IT BACK ═══
    ---
    ---   "Boost should last a total of 4 seconds and recharge over 6 seconds."
    ---
    --- `rechargeMs` is EMPTY TO FULL, not a per-second rate, which is what makes
    --- a partial spend cost proportionally: half a meter takes three seconds to
    --- come back, not six. BR.BoostSolve.rechargeRate turns the pair into the
    --- rate, and 4000/6000 is where the 40% sustained duty cycle comes from.
    capacityMs = 4000.0,
    rechargeMs = 6000.0,

    --- ═══ THE RAMP LIVES INSIDE THE BOOST, IT DOES NOT PRECEDE IT ═══
    ---
    ---   "The acceleration should be over the course of the first 2 seconds of
    ---    the boost."
    ---
    --- So a full boost is two seconds climbing and two seconds holding, and a
    --- partial boost is however much of that climb the meter paid for. Nothing
    --- resets or rescales this for a short boost -- see boost_solve.lua's header
    --- on why a compressed ramp would be the wrong reading of "partial boost is
    --- acceptable".
    rampMs = 2000.0,

    --- ═══ THIRTY MILES AN HOUR, ON TOP OF WHATEVER THEY WERE DOING ═══
    ---
    ---   "accelerated forward to reach a speed 30mph faster than what it was
    ---    doing when they pressed it"
    ---
    --- RELATIVE, AND SAMPLED ONCE. The base is read on the press and frozen; see
    --- boost_solve.lua. Written in mph because the owner wrote it in mph, and
    --- converted exactly once, below.
    addMph = 30.0,

    --- ═══ HOW MUCH HARDER THAN THE RAMP THE CONTROLLER MAY PUSH ═══
    ---
    --- The push is a closed loop: each frame it asks for the difference between
    --- the speed the ramp wants and the speed the car actually has. Without a
    --- ceiling on that difference, a car that hits a wall at 40 m/s would be
    --- handed the whole 40 m/s back as one frame's impulse, which is not an
    --- acceleration, it is a catapult.
    ---
    --- The ceiling is expressed as a MULTIPLE OF THE RAMP'S OWN RATE rather than
    --- as an absolute, so it stays correct if the owner changes 30 mph or 2
    --- seconds. 1.0 would be exactly enough to follow the ramp on a frictionless
    --- flat road and therefore not enough to follow it against drag or up a
    --- hill; 2.0 leaves the same amount again as spare authority, which is what
    --- holds the elevated speed through seconds two to four.
    ---
    --- A GUESS, AND THE ONE MOST LIKELY TO NEED A PLAYTEST. Too low and the
    --- boost feels soft on a heavy vehicle; too high and a crash is followed by
    --- an unearned relaunch. See maxAccelMps2 below for what it resolves to.
    accelHeadroom = 2.0,

    --- ═══ BOOSTING BURNS FUEL 50% FASTER ═══
    ---
    ---   "And yes, boosting should burn fuel faster. Good point. Let's make it
    ---    burn 50% faster while boosting"      -- owner, 2026-08-22
    ---
    --- ONE VALUE, READ IN ONE PLACE (br_core/server/fuel.lua's sample pass, via
    --- BR.BoostSolve.fuelMultiplier). It multiplies the METRES charged, not a
    --- litre rate -- the ledger's unit is metres of ground covered -- and it is
    --- applied to the FRACTION of each sample interval that was boosted, so a
    --- boost that straddles two samples is charged correctly on both.
    ---
    --- NOTE WHAT THIS IS ON TOP OF. A boosting car covers more ground per second
    --- and is therefore already charged more per second by the ledger's own
    --- arithmetic. This is a surcharge above that, which is the natural reading
    --- of "burn fuel faster" as a thing distinct from "go faster".
    fuelMultiplier = 1.5,

    --- ═══ AIRCRAFT ARE OUT, AND IT IS A KEY COLLISION RATHER THAN A TASTE CALL
    ---     ═══
    ---
    --- The owner said "the vehicle", not "the car", so the default here is as
    --- close to everything as the keyboard allows. LEFT SHIFT is the right
    --- default key precisely because GTA does nothing with it in a CAR. The full
    --- list is longer than the four that used to be written here -- eight
    --- controls default to LSHIFT -- and the conclusion is unchanged, because
    --- only one of the eight can fire in a ground vehicle at all:
    ---
    ---     21   INPUT_SPRINT                       on foot only
    ---     61   INPUT_VEH_MOVE_UP_ONLY             aircraft / heli axis
    ---     131  INPUT_VEH_SUB_ASCEND               submarines
    ---     155  INPUT_PARACHUTE_PRECISION_LANDING  under canopy
    ---     209  INPUT_FRONTEND_LS                  frontend group
    ---     254  INPUT_CREATOR_MENU_TOGGLE          creator
    ---     352  INPUT_VEH_FLY_BOOST                aircraft only
    ---     340  INPUT_VEH_HYDRAULICS_CONTROL_UP    lowriders with hydraulics
    ---
    --- TWO ENTRIES THAT USED TO BE SUSPECTED ARE NOT ON THE LIST AT ALL:
    --- INPUT_VEH_DUCK is 73 (X) and INPUT_VEH_HANDBRAKE is 76 (SPACE). Neither
    --- is shift and neither was ever a collision here.
    ---
    --- ═══ "DRIFT MODE IS ON SHIFT" WAS INVESTIGATED AND IS NOT A GTA FEATURE ═══
    ---
    --- The #203 playtest attributed the dead boost to it -- "likely because GTA
    --- V's drift mode is taking over which is bound on SHIFT" -- and it is worth
    --- writing down what the research found so nobody re-litigates it.
    ---
    --- Drift Tuning is a Chop Shop (1.68 / b3095) VEHICLE MODIFICATION bought at
    --- Hao's, available on about eight cars. It is a handling change -- AWD
    --- conversion, more power, different grip -- and it has NO key, no toggle and
    --- no mode. There is no INPUT_*DRIFT* control in any control table. The only
    --- drift natives are tyre-level (_SET_DRIFT_TYRES_ENABLED), which is
    --- something a script calls, not something a player presses.
    ---
    --- WHERE THE BELIEF COMES FROM: several third-party FiveM drift RESOURCES
    --- bind left shift themselves. That is a convention of other people's
    --- scripts, not of the game -- and no such resource runs on this server.
    ---
    --- STATED HONESTLY: the public control table's last substantive update was
    --- November 2020 (build ~2189), so an input Rockstar added between then and
    --- 3095 would not appear in it. "No drift control exists" is therefore very
    --- well supported and not absolutely proven. /brboost samples GTA's own
    --- controls on the key while you hold it, which is what settles it on this
    --- build rather than in a document.
    ---
    --- REGISTER_KEY_MAPPING AND AN ENGINE CONTROL DO NOT FIGHT OVER A KEY, and
    --- this is now source-backed rather than assumed. FiveM's GameInput.cpp
    --- evaluates custom bindings from the same rage::ioValue device state the
    --- stock controls use, and deliberately BYPASSES the game's own conflict
    --- resolver for them (custom ids carry 0x80000000; HandleMappingConflicts
    --- returns early). Both fire. Nothing swallows anything.
    ---
    --- WHICH IS EXACTLY WHY AIRCRAFT ARE STILL EXCLUDED. Holding the boost key in
    --- a helicopter would climb it (61 / 352) AND shove it forward, from one
    --- press, with no way for the player to want only one of them. That is not a
    --- balance question, it is two features on one key.
    ---
    --- 15 is HELICOPTER and 16 is PLANE, from GET_VEHICLE_CLASS. Boats are
    --- deliberately IN: shift does nothing in one, and a boat has an exhaust.
    ---
    --- REVERSIBLE IN ONE LINE. Empty this table and every aircraft boosts.
    excludeClasses = {
        [15] = true,   -- helicopters
        [16] = true,   -- planes
    },

    --- ═══ THE FLAMES ═══
    ---
    ---   "the vehicle has flames which come out the back of the tailpipes"
    ---
    --- `veh_nitrous` IS THE PURPOSE-BUILT ONE, and it is what every open
    --- implementation converged on. Arena War shipped it as the nitrous flame;
    --- swcfx/sw-nitro started on `core`/`veh_backfire` and moved off it in PR #5
    --- ("Changed flame to new nitro FX"), and ND_Nitro and malice_nitro were both
    --- written on it. That is four independent scripts and one deliberate
    --- migration pointing the same way.
    ---
    --- THE ALTERNATE, KEPT NAMED BECAUSE IT IS THE ONE THAT NEEDS NO STREAMING:
    ---
    ---     core / veh_backfire     GTA's own exhaust backfire. `core` is the
    ---                             base asset and is resident for the whole
    ---                             session, so it can never be late.
    ---
    --- `veh_xs_vehicle_mods` IS NOT RESIDENT and has to stream, which is why
    --- br_core/client/boost.lua asks for it at resource start rather than on the
    --- first press: a boost is four seconds long, and an asset that arrives on
    --- second three is a boost that had no flames.
    ---
    --- WHICH OF THE TWO LOOKS RIGHT IS NOT A DESK QUESTION. Swapping them is one
    --- edit here and no code change.
    ptfx = {
        asset  = 'veh_xs_vehicle_mods',
        effect = 'veh_nitrous',
        --- Size of one flame. Per-bone, so a car with four tailpipes gets four.
        scale  = 1.0,

        --- ═══ EVERY EXHAUST BONE GTA SHIPS, TRIED IN ORDER ═══
        ---
        --- `exhaust` then `exhaust_2` .. `exhaust_16`. That is the run two
        --- independent implementations enumerate -- sw-nitro hardcodes the
        --- sixteen, malice_nitro generates them -- and sixteen is the ceiling
        --- because no shipped model has more.
        ---
        --- GET_ENTITY_BONE_INDEX_BY_NAME answers -1 for a bone a model does not
        --- have, so naming one that does not exist costs a lookup and nothing
        --- else. `exhaust_1` is in the list for exactly that reason: every script
        --- skips it and goes straight from `exhaust` to `exhaust_2`, but
        --- citizenfx/fivem #2003 names it as valid alongside `exhaust`, and
        --- being wrong about which of the two a given model uses costs a car with
        --- no flames. One extra lookup buys the disagreement away.
        ---
        --- KNOWN LIMITATION, WRITTEN DOWN RATHER THAN GUARDED: a vehicle whose
        --- exhaust has been swapped with SET_VEHICLE_MOD keeps reporting the
        --- stock bone indices, because the bone structure is not rebuilt after a
        --- mod is applied (citizenfx/fivem #2003, #2999 -- both still open).
        --- Nothing in this gamemode calls SET_VEHICLE_MOD, so it cannot bite here
        --- today.
        bones = {
            'exhaust',
            'exhaust_1',  'exhaust_2',  'exhaust_3',  'exhaust_4',
            'exhaust_5',  'exhaust_6',  'exhaust_7',  'exhaust_8',
            'exhaust_9',  'exhaust_10', 'exhaust_11', 'exhaust_12',
            'exhaust_13', 'exhaust_14', 'exhaust_15', 'exhaust_16',
        },

        --- Where the flame sits when a model has NO exhaust bone at all, as a
        --- fraction of the model's own bounding box: two plumes either side of
        --- the centre line, at the very back, near the ground.
        ---
        --- A FALLBACK RATHER THAN A DEFAULT. Bones are right when they exist,
        --- and a great many models do not have them -- a boost with no visible
        --- flame on a third of the car list is a feature that looks broken
        --- rather than one that looks plain.
        fallback = {
            side   = 0.45,   -- of half-width, left and right of centre
            lift   = 0.20,   -- of height, up from the bottom of the box
            behind = 0.02,   -- of length, beyond the back face
        },
    },

    --- How often a client retries attaching flames to a boosting vehicle it
    --- cannot resolve yet.
    ---
    --- A NETWORK ID ONLY RESOLVES INSIDE SCOPE, which is correct rather than a
    --- problem: a car you cannot see needs no flames. But a car that drives INTO
    --- your scope mid-boost would otherwise stay dark for the rest of it,
    --- because the start message has already been and gone. The retry is what
    --- turns a missed edge into a late attach. It runs on the TICK band over a
    --- table that is empty almost always and holds a handful of entries at worst.
    attachRetryMs = 250,
}

-- ---------------------------------------------------------------------------
-- Derived
-- ---------------------------------------------------------------------------

--- The whole boost, in the unit every native actually speaks.
---
--- 30 mph = 13.41 m/s. One conversion, at load, so no hot path ever multiplies
--- by 0.44704 and no second copy of that constant can disagree with the first.
BR.Config.Boost.addMps =
    BR.Config.Boost.addMph * BR.BoostSolve.MPH

--- The most acceleration the controller may ask for in one frame, in m/s².
---
--- THE RAMP'S OWN RATE IS THE UNIT OF MEASUREMENT HERE, and it falls straight
--- out of the two numbers the owner gave: 13.41 m/s delivered over 2.0 s is
--- 6.71 m/s², which is what following the ramp costs on a flat road with no
--- drag. `accelHeadroom` says how much more than that the loop may spend to
--- actually track it -- and, incidentally, bounds what a crash can be paid back.
---
--- At the shipped values: 6.71 * 2.0 = 13.4 m/s², about 1.4 g.
BR.Config.Boost.maxAccelMps2 =
    (BR.Config.Boost.addMps / (BR.Config.Boost.rampMs / 1000.0))
    * BR.Config.Boost.accelHeadroom
