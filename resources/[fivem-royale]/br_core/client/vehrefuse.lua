-- Refusing a vehicle at the door, on the machine of the player opening it -- and,
-- since #322, holding the gun off in the ones the owner decided are fine to
-- drive.
--
-- ═══ TWO OUTCOMES, ONE RULING, AND THE RULING IS NOT IN THIS FILE ═══
--
-- BR.Config.VehicleRefusalFor says which vehicles are refused and
-- BR.Config.IsDisarmedVehicle says which are driven with the weapon disabled.
-- Both live in br_lib/config/vehicles.lua and both are shared with the server.
-- This file is the client half of what happens NEXT: an ejection for the first
-- answer, a per-tick DisableVehicleWeapon for the second. They are mutually
-- exclusive -- a model the second names is allowed by the first -- and the pass
-- at the bottom is written so that they cannot both fire.
--
-- #329 ADDED A THIRD SOURCE FOR THE SECOND ANSWER AND NONE AT ALL FOR THE FIRST.
-- The engine is now asked whether the vehicle a player is actually sitting in has
-- weapons, because a hand-written list of models was incomplete twice in three
-- days and each gap was both an armed vehicle AND a case filed against its
-- driver. WHICH VEHICLES ARE REFUSED IS STILL ENTIRELY AUTHORED -- nothing the
-- engine says can eject anybody, or stop this file ejecting them. See the section
-- above `seatOf`.
--
-- ═══ THE OWNER'S ASK, VERBATIM (2026-08-22, #215) ═══
--
--   "Yeah incidents do happen when stealing a heli from zancudo. I do have to
--    wonder though - this doesn't really follow our proactive posture. It's more
--    of a reactive measure. What if we detect the vehicle they're trying to get
--    in as they try, then reject the action client-side? If they do manage
--    through some hoops we should still get incidents but the client-side magic
--    should stop non-cheaters."
--
--   "When rejecting the action client-side, they'll be forced out of the vehicle
--    and given a notification - 'To keep things fair, this vehicle is not
--    allowed to be used during the match.' Then the vehicle's doors should be
--    locked, which will prevent us from running that check again on that
--    vehicle."
--
-- ═══ THIS FILE IS ADVISORY. IT IS NOT ENFORCEMENT, AND NOTHING SHOULD EVER BE
--     BUILT AS THOUGH IT WERE ═══
--
-- It runs on the player's own machine. A modified client does not run it at all:
-- the loop is never registered, the ejection never happens, the doors are never
-- locked, and there is no server-side consequence for any of that, because
-- nothing here talks to the server.
--
-- SO IT STOPS THE HONEST PLAYER AND ONLY THE HONEST PLAYER, which is exactly
-- what the owner asked it to do -- "the client-side magic should stop
-- non-cheaters". A cheat walks through it untouched and lands, unchanged, in
-- br_core/server/vehicles.lua, whose occupancy detector was NOT weakened by this
-- file and must not be: "if they do manage through some hoops we should still
-- get incidents". That detector is the boundary. This is a door sign.
--
-- Anybody who later reads a locked door or an ejected ped as proof of anything
-- has misread this paragraph. The lock is a state a client set on itself.
--
-- ═══ BEFORE THE SEAT, OR AFTER IT? BOTH, AND THE ORDER IS THE POINT ═══
--
-- `GetVehiclePedIsEntering` answers while the ped is playing the entry
-- animation -- door open, climbing in -- and BEFORE the seat is taken:
-- `IsPedInAnyVehicle` is still false for the whole of that window.
-- client/fuel.lua and client/vehdamage.lua both already ride it, and
-- vehdamage.lua's own comment measures it at "about a second".
--
-- A second is ten passes of the TICK band, so the ordinary path -- a player
-- walking up to a Buzzard and pressing F -- IS INTERCEPTED BEFORE THE SEAT IS
-- TAKEN. They never sit down. The task is cancelled where it stands.
--
-- IT IS NOT GUARANTEED, and pretending otherwise would be the bug. Three ways in
-- skip the window or shorten it below one pass:
--
--   * a script warp. `SetPedIntoVehicle` is instantaneous and has no entry task.
--   * entering a vehicle already moving, or a bike, where the animation is a
--     fraction of a car's.
--   * this loop simply not having run yet -- the window opens between passes.
--
-- So the seat is checked as well, on the same pass, and a player who got there
-- is put back out. Both routes end in the same `reject`. THE HONEST ANSWER IS
-- "usually before, always by the pass after", and the suite asserts both halves
-- separately so a change that quietly loses the early one is visible.
--
-- ═══ WHAT IS SHOWN, AND WHY IT DISCLOSES NOTHING (#93) ═══
--
-- One sentence, the owner's, verbatim, with nothing appended. It is IDENTICAL
-- for every player and every vehicle: the same words for a first-timer who
-- wandered into a parked Buzzard and for somebody on their fifth Rhino. It does
-- not say a case was filed, does not say anyone is being watched, does not name
-- the reason (flies / armed / tank) and does not change when the server has been
-- counting. It is a statement of a game rule, which every player is entitled to
-- know, and it is the reason this layer does not violate #93: an offender learns
-- exactly what an honest player learns, which is nothing about the detector.
--
-- Nothing here reads roster state, offence counts, or anything the server sent
-- about this player. There is nothing in this file for a message to leak.
--
-- ═══ THE LOCK: A DETERRENT, A MEMO, AND SELF-HEALING ═══
--
-- `SetVehicleDoorsLocked(veh, 2)` -- VEHICLELOCK_LOCKED, "prevents entry by
-- players and NPCs". Chosen over 10 (VEHICLELOCK_CANNOT_ENTER) for one reason:
-- 10 is documented as preventing entry "even if previously inside", and this
-- code runs on a vehicle a player may still be sitting in for the frame or two
-- the exit takes. State 2 cannot strand anybody; the eject runs first regardless.
--
-- THE OWNER'S STATED PURPOSE IS THE MEMO -- "which will prevent us from running
-- that check again on that vehicle" -- and that is how it works, but NOT by this
-- file reading the lock back and skipping. It must not, and the reason is worth
-- being blunt about: ambient parked cars in GTA V are frequently lock state 2
-- already. "Skip the check on a locked vehicle" would let a LOCKED BUZZARD -- an
-- ambient one, locked by the map and not by us -- straight through the only
-- check in this file. So the lock prevents the re-check the way the owner meant
-- it: the engine stops the entry, the entry task never starts, and the check has
-- nothing to fire on. Emergent, not coded.
--
-- IT DOES NOT SURVIVE A STREAM-OUT. Door lock state lives on the entity, and an
-- entity that streams out and back is a new entity at default lock. Nothing is
-- persisted, and nothing needs to be: the next attempt hits the same check, gets
-- the same ejection, and re-locks. That is the whole recovery story -- the loop
-- is the durable part and the lock is the convenience.
--
-- Re-asserted on EVERY rejection for the same reason: another client, the
-- server, or a stream cycle can put it back to unlocked, and re-writing it costs
-- one native on a path that has already decided to eject somebody.
--
-- ═══ WHY IT DOES NOT RUN DURING THE BUS ═══
--
-- BR.Config.Bus.model is `titan`, which is refused -- it is an aircraft, and
-- config/vehicles.lua's header says so at length. Today client/bus.lua carries
-- the player with `AttachEntityToEntity` rather than a seat, so `GetVehiclePedIsIn`
-- answers 0 and this file would never see it. THAT IS AN IMPLEMENTATION DETAIL
-- OF ANOTHER FILE and a poor thing to depend on: the day the bus seats players,
-- an unguarded version of this loop would throw every player out of the Battle
-- Bus at three thousand feet, one per hundred milliseconds.
--
-- So the gate is on player state and is deliberately narrow: ALIVE or WARMUP.
-- BUS, FREEFALL and GLIDE are the states in which this gamemode is carrying the
-- player somewhere, and it is never right to fight it. LOBBY, OUT and DBNO have
-- no player who can take a vehicle -- and a spectator is OUT.

BR = BR or {}
BR.VehRefuse = BR.VehRefuse or {}

--- The one sentence, the owner's words, and NOTHING appended to them.
---
--- A constant so tools/test_vehrefuse.lua can compare what reached the toast
--- against a literal written out in the suite -- which is a real check, where
--- comparing this constant to itself would be a tautology.
BR.VehRefuse.MESSAGE =
    'To keep things fair, this vehicle is not allowed to be used during the match.'

--- VEHICLELOCK_LOCKED. See the header for why not 10.
local LOCK_STATE = 2

--- How long a `TaskLeaveVehicle` is given before the hammer comes out.
---
--- ONE PASS IS TOO FEW AND TEN IS TOO MANY. `TaskLeaveVehicle` is a TASK -- it is
--- queued and takes effect over frames, so a ped is legitimately still seated on
--- the pass after it is issued. But the task can also be REFUSED outright (a
--- vehicle upside down, a door destroyed, an animation already blending), and a
--- refusal looks exactly like a task that has not finished yet. So it is given
--- 400 ms -- four passes -- and then `ClearPedTasksImmediately`, which is not a
--- task and cannot be declined.
local ESCALATE_MS = 400

--- Silence between two showings of the sentence.
---
--- NOT ANTI-SPAM FOR ITS OWN SAKE. Without it a player standing against a locked
--- Buzzard, holding the entry key, is shown the same words ten times a second.
--- Long enough to read; short enough that a second, deliberate attempt a few
--- seconds later is answered rather than ignored.
local NOTIFY_COOLDOWN_MS = 4000

--- How many distinct models to remember a ruling for before starting over.
---
--- KEYED ON THE MODEL AND NOT ON THE VEHICLE HANDLE, which is what makes the
--- cache both correct and small. A ruling is a property of the MODEL -- the model
--- table is keyed on it and `GetVehicleClass` reads the model's class -- so two
--- Buzzards cannot rule differently, and a recycled entity handle cannot inherit
--- a stale answer, because handles are not the key.
---
--- 128 is generous: it is distinct MODELS this player has tried to get into.
local MAX_RULINGS = 128

--- The highest seat index this file will look for a player in.
---
--- -1 THROUGH 8, WHICH IS THE RANGE client/driveby.lua's `seatOf` WALKS, and its
--- note says why: there is no native that answers "which seat am I in", the
--- engine only answers "who is in seat N", and eight is past the largest seat
--- count in the base game. A ped in seat 9 or beyond -- the back of a coach --
--- reads as "no seat we can name", which switches the whole of #329's probe off
--- for them and leaves the authored table answering, exactly as it does today.
--- br_core/server/vehicles.lua's CABIN_SEATS states the same limit for the same
--- reason and refuses a report naming a seat past it.
---
--- NOT SHARED WITH driveby.lua's COPY, and the reason is the manifest rather
--- than taste: client/vehrefuse.lua is declared BEFORE client/driveby.lua, so
--- BR.DriveBy does not exist when this file loads, and a loop that reached for a
--- function from a file declared later would be one manifest edit away from
--- silently never probing anything. `isTrue` above is per-file for the same
--- class of reason.
local MAX_SEAT = 8

--- How long between two armament reports about the same seat.
---
--- IT IS A REPEAT RATHER THAN AN EDGE, AND THAT IS NOT BELT-AND-BRACES. The
--- server checks the report against ITS OWN seat read, and the server's copy of
--- a player's seat arrives up to a roster sample behind the client's -- so the
--- one report sent on the pass the seat is taken can land before the far end
--- agrees anybody is sitting there, and a single edge that arrives early is a
--- suppression lost for the whole of that occupancy. The cost of repeating is
--- one message every two seconds from a player sitting in an armed car; the cost
--- of not repeating is an anticheat case about them.
---
--- THERE IS NO ACKNOWLEDGEMENT AND THIS IS WHY. The far end answers nothing (the
--- report is evidence, not a request), so the client cannot know whether one
--- landed. A fixed cadence is what that leaves.
local REPORT_EVERY_MS = 2000

--- How many passes of one occupancy will read DOES_VEHICLE_HAVE_WEAPONS before
--- this file gives up and lets the authored table answer alone.
---
--- ═══ A READ THAT DID NOT ANSWER IS NOT AN ANSWER ═══
---
--- The probe below LATCHES what the engine said, so that an ordinary car costs
--- nothing for the rest of the match. `safe` exists in this file precisely because
--- these two natives may not be on this build and may throw on a stale handle --
--- so the read can come back having reached nothing at all, and latching THAT as
--- "this vehicle has no gun" is the worst outcome available here: the player who
--- sat down on the pass where the handle was mid-migration gets no disarm and no
--- report for as long as they stay in that vehicle. That is the exact symptom
--- #329 exists to remove, made silent. So a read that did not answer is retried
--- on the next pass, and only a read that answered latches.
---
--- WHICH IS ONLY SAFE WITH A CEILING ON IT. A native that is not on this build
--- never starts answering, and an unbounded retry would be a pcall'd native every
--- 100 ms for every player in every vehicle in the match, for the whole match.
--- FIVE PASSES IS HALF A SECOND at TICK -- long enough for an ownership migration
--- or a stale handle to settle, and five reads is the entire cost of a build that
--- does not have the native. After the fifth, this occupancy is settled and costs
--- nothing more, exactly as one the engine answered "no" for does.
local PROBE_TRIES = 5

-- ---------------------------------------------------------------------------
-- Reading a world that lies in three different ways
-- ---------------------------------------------------------------------------

--- A FiveM BOOL native answers `true`, or `1`, and this repo has shipped the bug
--- of believing otherwise FIVE times. A diagnostic on 2026-08-22 caught one
--- native on this build returning `number 1` on some frames and `boolean false`
--- on others, in the same session.
---
--- Same body as client/vehdamage.lua's and client/boost.lua's, per-file for the
--- reason those two are per-file.
--- @param v any
--- @return boolean
local isTrue = BR.NativeBool

--- Call a native that may not exist on this build and may throw on a stale
--- handle. nil is the answer for both, and every caller here treats nil as
--- "no opinion" rather than as "refused".
--- @return any|nil
local function safe(fn, ...)
    if type(fn) ~= 'function' then return nil end
    local ok, v = pcall(fn, ...)
    if not ok then return nil end
    return v
end

--- The same call `safe` makes, with the one thing `safe` throws away: WHETHER THE
--- CALL REACHED THE ENGINE AT ALL.
---
--- `safe` folds "no such native on this build", "the handle was stale and it
--- threw" and "the engine said no" into one nil, and for every other caller in
--- this file that is the right shape -- all of them want no opinion to read as
--- "not refused". #329's probe is the one caller the fold is a bug for, because it
--- LATCHES the answer for the whole occupancy: a throw latched as a no is a gun
--- left live and nothing said about it. See PROBE_TRIES.
---
--- A CALL THAT RETURNED IS AN ANSWER, EVEN WHEN WHAT IT RETURNED WAS nil. The only
--- two outcomes counted as silence are the two where the engine was never asked:
--- there is no such function, and the call threw. What an answer MEANS is
--- `isTrue`'s question and not this one.
---
--- NOT `safe` REWRITTEN IN TERMS OF THIS ONE, which was written and then undone:
--- `safe` is read on every pass by every player in a vehicle, and a call frame per
--- native read to save four lines is the wrong trade in this file.
--- @return boolean answered  the native exists and did not throw
--- @return any|nil
local function tried(fn, ...)
    if type(fn) ~= 'function' then return false, nil end
    local ok, v = pcall(fn, ...)
    if not ok then return false, nil end
    return true, v
end

--- This vehicle's model hash, or nil.
---
--- NOT FLOORED, NOT COERCED TOWARD ZERO. A model hash is legitimately NEGATIVE:
--- the engine reports it signed, and server/vehicles.lua's `modelOf` carries the
--- same warning for the same reason. BR.NormHash on the far side handles the
--- sign; mangling it here would turn a Buzzard into 0, and 0 is in no row.
--- @param veh integer
--- @return integer|nil
local function modelOf(veh)
    local m = safe(GetEntityModel, veh)
    if m == nil then return nil end
    return math.tointeger(tonumber(m))
end

--- This vehicle's class, 0-22, or nil.
---
--- ═══ THE SIGNAL THE SERVER CANNOT HAVE ═══
---
--- `GetVehicleClass` is CLIENT-ONLY -- config/vehicles.lua says so where it
--- explains why the server settles for `GetVehicleType` -- so this function is
--- the entire reason the armed half of the owner's rule has a net under it
--- anywhere in the tree. On the server there are two signals and both of them
--- only ever say "flies".
--- @param veh integer
--- @return integer|nil
local function classOf(veh)
    local c = safe(GetVehicleClass, veh)
    if c == nil then return nil end
    return math.tointeger(tonumber(c))
end

--- This vehicle's `GetVehicleType` string, or nil.
---
--- READ ON THE CLIENT TOO, EVEN THOUGH THE CLASS IS AVAILABLE HERE, because the
--- two disagree on real models: a Blimp is class 15 (heli) and type `plane`, and
--- tabarra's published divergence table lists thirty-odd more. Either one alone
--- refuses a Blimp; asking both makes the client's flight coverage a strict
--- superset of the server's rather than a differently-shaped set.
--- @param veh integer
--- @return string|nil
local function typeOf(veh)
    local t = safe(GetVehicleType, veh)
    return type(t) == 'string' and t or nil
end

-- ---------------------------------------------------------------------------
-- The ruling, cached by model
-- ---------------------------------------------------------------------------

--- [normalised model hash] = refusal reason, or `false` for allowed.
---
--- `false` AND NOT nil FOR AN ALLOWED MODEL, because nil is "not asked yet" and
--- the difference is the entire saving: every ordinary car in every match lands
--- in this table once and is a lookup forever after.
local rulings = {}
local ruled = 0

--- Counters, for /brvehrefuse. Nothing here is sent anywhere.
local stat = { asked = 0, cached = 0, rejected = 0, ejected = 0,
               cancelled = 0, hammered = 0, locked = 0, notified = 0,
               disarmed = 0, unnamedGun = 0,
               -- #329's five. See the section on asking the vehicle.
               probed = 0, engineArmed = 0, turretSeat = 0, reported = 0,
               -- Reads of DOES_VEHICLE_HAVE_WEAPONS that reached no engine at
               -- all: no such native, or a handle that threw. It is the number
               -- that tells a silent build from a match of ordinary cars, which
               -- is the one thing this process cannot infer. See PROBE_TRIES.
               armedSilent = 0 }

--- Why this gamemode refuses this vehicle, or nil.
---
--- THE RULING IS NOT MADE HERE. BR.Config.VehicleRefusalFor makes it, for this
--- file and for both server-side detectors, and that is deliberate rather than
--- tidy: #191's ambulance needs one exemption in one function, and the moment
--- this file grew its own copy of the ordering that promise would be false. All
--- three signals -- model table, type, class -- are described there.
---
--- THE MODEL IS RETURNED AS WELL, AND ONLY SO THAT NOTHING READS IT TWICE.
--- `disarm` below needs the same hash this function has just paid a native for,
--- and server/vehicles.lua's namesake has returned it for its own callers since
--- it was written. Handing it back is one value; reading `GetEntityModel` again
--- on the next line would be a second native on every pass a player spends
--- seated, which is most of them.
--- @param veh integer
--- @return string|nil why
--- @return integer|nil model
local function refusalFor(veh)
    local model = modelOf(veh)
    local key = BR.NormHash(model)

    if key ~= nil then
        local hit = rulings[key]
        if hit ~= nil then
            stat.cached = stat.cached + 1
            return hit or nil, model
        end
    end

    stat.asked = stat.asked + 1
    local why = BR.Config.VehicleRefusalFor(model, {
        typeOf  = function() return typeOf(veh) end,
        classOf = function() return classOf(veh) end,
    })

    if key ~= nil then
        -- WIPED WHOLE RATHER THAN EVICTED. There is no useful recency order
        -- here and a cache miss costs three natives, so the simple thing is the
        -- right thing -- the same call client/vehdamage.lua makes at its own cap.
        if ruled >= MAX_RULINGS then rulings, ruled = {}, 0 end
        rulings[key] = why or false
        ruled = ruled + 1
    end

    return why, model
end

-- ---------------------------------------------------------------------------
-- Driving one instead: holding the gun off (#322)
-- ---------------------------------------------------------------------------
--
-- ═══ THE OWNER'S RULING AND WHERE IT IS MADE ═══
--
-- "only vehicles refused for being ARMED become drivable." The ruling is
-- BR.Config's, exactly as the refusal is: BR.Config.IsDisarmedVehicle names the
-- set and BR.Config.VehicleRefusalFor stops refusing it, so this file learns
-- both facts by asking rather than by knowing. Nothing below decides anything.
--
-- ═══ WHY THIS BELONGS IN THIS FILE ═══
--
-- The pass below already has the ped, the seat and the model in hand, and it
-- already holds the per-model ruling cache. A second file would have had to read
-- `GetVehiclePedIsIn` and `GetEntityModel` again, every pass, to learn what this
-- one has already learned -- and would have been a second opinion about which
-- vehicles the rule covers, which is the thing config/vehicles.lua's header
-- spends its length preventing.
--
-- ═══ IT IS ADVISORY, LIKE EVERYTHING ELSE HERE ═══
--
-- The file header's paragraph applies word for word: this runs on the player's
-- own machine, a modified client never registers the loop, and nothing here
-- talks to the server. br_core/server/damage.lua validates every shot against
-- the inventory the SERVER issued and refuses one from a weapon it never handed
-- out -- that is what actually stops a mounted gun hurting anybody, and it is
-- unchanged. What this removes is the noise and the desync of a gun that fires,
-- looks like it hit, and is then refused a round trip later.
--
-- ═══ AND THE SEAT THE NATIVE CANNOT SEE ═══
--
-- `GetCurrentPedVehicleWeapon` has no opinion about some gun positions -- the
-- firetruck's hose was the first this project measured -- and in one of those
-- the seat names no hash to disable. Before #322 that could not happen in an
-- armed vehicle because nobody was in the seat for longer than a tenth of a
-- second; now they sit there all match, in about sixty models.
--
-- THE CARACARA'S GUN SEAT READS AS THE SECOND (owner, 2026-09-19). The strip
-- fired on what he was holding there, and `isMountedWeapon` excuses the hand
-- whenever the seat names the same gun -- so the seat did not name the gun in
-- his hand. `/brvehrefuse` is what confirms which way; see its note.
--
-- THE ENGINE PUTS THAT GUN IN THE PLAYER'S HAND, AND THE HAND IS WHERE THE HASH
-- COMES FROM. Where the seat names nothing, `disarm` switches off the hash in
-- the hand when it is in no row of ours -- see `unnamedGunInHand` for why that,
-- and only that, is safe to hand back to the engine.
--
-- THE ACCUSATION IS ANSWERED ON THE SERVER, AND THE CLIENT STRIP IS NOT
-- LOOSENED. What that seat used to cost was a high severity anticheat case
-- against somebody who got into a car -- server/damage.lua refusing the shots
-- as NO_WEAPON, server/strip.lua filing the stripped hash -- and both of those
-- ask BR.Vehicles.inDisarmedVehicle and decline to accuse anybody sitting in a
-- model this ruling disarms. client/inventory.lua still takes the gun out of
-- the hand and still reports it; #322's review rejected excusing a hash in no
-- row of ours on this side, and nothing here changes that.

--- The vehicle weapon this ped's seat currently holds, or nil.
---
--- ═══ ASKED THE WAY client/inventory.lua's `isMountedWeapon` ASKS IT, AND THAT
---     IS DELIBERATE RATHER THAN CONVENIENT ═══
---
--- `GetCurrentPedVehicleWeapon` -- BOOL GET_CURRENT_PED_VEHICLE_WEAPON(Ped,
--- Hash*) -- is the same native, asked of the same ped, for the same hash. So
--- the seats where this function answers are EXACTLY the seats where the strip's
--- mounted-weapon guard answers, and the two cannot come apart: a gun this
--- disables is a gun the anticheat already excuses, by construction and not by
--- coincidence. The seats where it does NOT answer are the other half: the gun
--- is found in the hand by `unnamedGunInHand` below, and the report the strip
--- sends about it is dropped on the server. See the section header above.
---
--- FOUR CONDITIONS, ALL IN THE SAFE DIRECTION, THE SAME FOUR THAT FILE LISTS:
---
---   1. the native EXISTS and did not throw. pcall'd with no `type(...)` guard
---      in front of it, because `pcall(nil, ...)` returns false rather than
---      raising -- the guard and the pcall are the same test, and this file
---      already deleted one such pair from `lock` for that reason.
---   2. it ANSWERED. A FiveM BOOL may be `true` or `1`, six shipped instances
---      say so, and `isTrue` is this file's own normalisation.
---   3. the hash is a NUMBER. A native that answered prose is no opinion.
---   4. it is NON-ZERO. A vehicle with no mounted gun answers `0`, and `0` is
---      TRUTHY in Lua -- without this, "this seat has no gun" would be handed to
---      DisableVehicleWeapon as a weapon hash.
---
--- NOT PUT THROUGH BR.NormHash, and this is the one place in this file where
--- that is right. Everything else here normalises because it is about to index a
--- table the config authored positive. This value is going straight back into a
--- native, in the form that native just produced it in, and rewriting a hash on
--- its way from the engine to the engine could only make it wrong.
--- @param ped integer
--- @return integer|nil
local function mountedWeaponOf(ped)
    local pok, answered, hash = pcall(GetCurrentPedVehicleWeapon, ped)
    if not pok or not isTrue(answered) then return nil end
    local h = math.tointeger(tonumber(hash))
    if h == nil or h == 0 then return nil end
    return h
end

--- The gun the engine has put in this ped's hand that this gamemode issues
--- NOBODY, or nil.
---
--- ═══ THE FIRETRUCK SIGNATURE, AND IT HAS TO MEAN THAT AND NOT A DRIVER ═══
---
--- `disarm` is called for ANY seat, by design, so the pass where
--- `GetCurrentPedVehicleWeapon` names nothing is mostly the ORDINARY DRIVER of a
--- Technical, an Insurgent or a Caracara: the gun is in the bed and the driver
--- has no vehicle weapon at all. A counter of "the native named nothing" climbs
--- ten times a second for the whole time anybody drives one normally, which
--- makes it unreadable -- and the first version of this file printed it beside a
--- sentence telling the operator that a climbing number meant a missing table
--- row.
---
--- What the firetruck actually looked like is BOTH HALVES AT ONCE: the vehicle
--- names no mounted weapon AND the engine has put something in the hand that is
--- in no row of BR.Config.WeaponByHash. That pair is the seat client/inventory.
--- lua's `isMountedWeapon` cannot see and the strip fires on.
---
--- ═══ AND SINCE THE CARACARA IT IS ALSO THE HASH `disarm` SWITCHES OFF ═══
---
--- The owner sat in a Caracara's gun seat on 2026-09-19 and the gun fired. The
--- model was in no row then, so nothing here ran at all -- but the row alone
--- would not have been enough. The strip fired on what he was holding, which
--- `isMountedWeapon` excuses whenever the seat names it, so the seat did not
--- name the gun in his hand and `mountedWeaponOf` would never have handed it to
--- `disarm`. The hand is where it is read from now.
---
--- ═══ AND IT IS READ BEFORE client/inventory.lua's STRIP EMPTIES IT ═══
---
--- That strip reads the same hand on the same TICK, takes a hash in no row out
--- of it and puts the active slot back. Read after it, this finds our own
--- weapon or the fists and hands `disarm` nothing, every pass. This file is
--- declared ABOVE inventory.lua in fxmanifest.lua for that reason, which is
--- what puts `vehrefuse.gate` first in the pass; see the note there.
---
--- IN NO ROW OF OURS IS WHAT MAKES IT SAFE TO HAND BACK. A hash this gamemode
--- issues nobody takes nothing from anybody when it is disabled, and it is the
--- same trade server/strip.lua's vehicle-gun guard makes about the same hash in
--- the same seat. A hash that IS one of ours -- an issued rifle, the fists --
--- is never handed to DisableVehicleWeapon: it is the player's own weapon, not
--- the car's.
---
--- FISTS ARE A ROW. WEAPON_UNARMED is BR.Config.Fists, registered into
--- WeaponByHash by hand in config/weapons.lua, so the row test declines it and
--- a second test of the same hash would be one mutation testing calls
--- unkillable. tools/test_vehrefuse.lua asserts the outcome against the real
--- arsenal, so the day that row goes this is what fails.
---
--- THE PARACHUTE IS NOT A GUN. It is in no weapon row -- client/inventory.lua's
--- strip excuses it by hash for that reason -- and it is granted on purpose by
--- client/skydive.lua, so switching it off would be switching off our own
--- grant.
---
--- FOUR CONDITIONS IN THE SAFE DIRECTION, the same four `mountedWeaponOf` above
--- takes, and "safe" here means NOTHING: a native that is absent, throws,
--- declines to answer or names nothing hands `disarm` no hash, so nothing is
--- disabled and nothing is counted.
---
--- RETURNED AS THE ENGINE REPORTED IT, for the reason `mountedWeaponOf` gives:
--- it is normalized to index the table and handed back raw, because it is going
--- straight into a native.
--- @param ped integer
--- @return integer|nil
local function unnamedGunInHand(ped)
    local pok, answered, held = pcall(GetCurrentPedWeapon, ped, true)
    if not pok or not isTrue(answered) then return nil end

    -- `0` IS TRUTHY, so "no weapon" is tested for rather than trusted to be
    -- falsy -- the reading this file normalizes everything else for.
    local raw = math.tointeger(tonumber(held))
    if raw == nil or raw == 0 then return nil end
    local h = BR.NormHash(raw)

    local known = BR.Config and BR.Config.WeaponByHash
    if known == nil then return nil end
    if known[h] ~= nil then return nil end

    local gadgets = BR.Config.Gadgets
    if gadgets and h == BR.NormHash(gadgets.PARACHUTE) then return nil end

    return raw
end

--- Hold this vehicle's gun off for the player sitting in it.
---
--- ═══ THE ARGUMENT ORDER, FROM THE NATIVE'S OWN DECLARATION ═══
---
---     void DISABLE_VEHICLE_WEAPON(BOOL disabled, Hash weaponHash,
---                                 Vehicle vehicle, Ped owner);
---
--- citizenfx/natives, VEHICLE/DisableVehicleWeapon.md, 0xF4FC6A6F67D8D856. THE
--- FLAG COMES FIRST, which is the opposite of every other native in this file --
--- `SetVehicleDoorsLocked(veh, state)`, `TaskLeaveVehicle(ped, veh, flags)` --
--- and is the single most likely thing to be written from memory and be wrong.
--- Wrong, it is silent: the engine gets a vehicle handle where it wanted a
--- boolean and a boolean where it wanted a hash, does nothing anybody can see,
--- and the gun keeps firing. tools/test_vehrefuse.lua asserts the four arguments
--- positionally for exactly that reason.
---
--- `owner` IS THE PED, NOT THE PLAYER INDEX. The native's own note calls this a
--- ped-specific lock and says the ped need not be in the vehicle or in any
--- particular seat when it is called.
---
--- ═══ ONE CALL, TWO PLACES THE HASH CAN COME FROM ═══
---
--- The seat, when `GetCurrentPedVehicleWeapon` names one; the hand, when it
--- does not and the hand holds a hash in no row of ours. Same call, same
--- argument order, same band, so the Caracara's gun seat gets exactly the call
--- a Technical's does. `disarmed` counts both; `unnamed-gun` counts the
--- second. See `/brvehrefuse`.
---
--- ═══ NOTHING EVER CALLS IT WITH `false` ═══
---
--- There is no re-enable path and there should not be one. The lock is per ped
--- and per vehicle, so a player who gets out takes nothing with them and leaves
--- nothing behind for the next occupant that a pass of this loop would not
--- re-establish. A Cfx report of the `false` call leaving a vehicle unable to
--- find its weapons again until it is respawned is the other reason: an undo
--- nobody needs is an undo that can only break something.
--- ═══ AND SINCE #329 THERE ARE TWO WAYS IN, ONE AUTHORED AND ONE MEASURED ═══
---
--- `BR.Config.IsDisarmedVehicle(model)` is the owner's ruling and is unchanged:
--- the ARMED rows of the model table, keepRefused excepted. `armed` and `turret`
--- are what the ENGINE said about the vehicle this player is actually sitting in,
--- and they exist because the table was incomplete twice in three days -- the
--- Caracara on 2026-09-19 and another stock model on 2026-09-21, which the owner
--- deliberately did not name so that nothing could be fixed by writing one more
--- row. See `engineProbe` below for which native answers which question, what it
--- costs, and what has not been confirmed in game.
---
--- EITHER OF THE TWO ENGINE ANSWERS IS ENOUGH, WHICH IS AN `or` ON PURPOSE.
--- Neither native's return value is documented on its own page, so the safe shape
--- is one where a single surprising answer does not switch the feature off: a
--- vehicle the engine calls armed is disarmed even if the seat denies being a
--- turret (the Ruiner 2000 family fires from the driving seat), and a seat the
--- engine calls a turret is disarmed even if the vehicle-level question answered
--- nothing (which is also what a build missing the native looks like).
---
--- WHAT BOUNDS IT IS STILL AUTHORED. `engineProbe` never answers yes for a model
--- BR.Config.StripExemptVehicles names -- the firetruck, whose hose the owner
--- ruled is the point ("I want them to be able to use the firehose") -- and it is
--- not reached at all for a vehicle BR.Config.VehicleRefusalFor refuses, because
--- the pass returns above it. So this widens the set of vehicles whose gun is
--- held off; it cannot touch the set that is refused, and it cannot touch the one
--- model the owner exempted by hand.
--- @param ped integer
--- @param veh integer
--- @param model integer|nil
--- @param armed boolean   the engine says this VEHICLE carries weapons (#329)
--- @param turret boolean  the engine says this SEAT is a turret (#329)
local function disarm(ped, veh, model, armed, turret)
    if not (BR.Config.IsDisarmedVehicle(model) or armed or turret) then return end

    local hash = mountedWeaponOf(ped)
    if hash == nil then
        -- THE SEAT THE NATIVE HAS NO OPINION ABOUT, WHICH IS WHAT THE
        -- CARACARA'S GUN SEAT LOOKED LIKE. The gun is in the hand instead, so
        -- the hand's hash is the one switched off -- but only a hash in no row
        -- of ours, which is what `unnamedGunInHand` answers. See that function
        -- for why nothing wider is safe to hand back.
        --
        -- MOST OF THESE PASSES ARE AN ORDINARY DRIVER, holding their own rifle,
        -- nothing, or the parachute. That is nil here, so nothing of theirs is
        -- disabled and nothing is counted.
        --
        -- NOT BR.Config.StripExemptVehicles. That table switches the anticheat
        -- off for the whole model; this switches off one hash we issue nobody,
        -- in one seat, and the strip in client/inventory.lua still runs.
        hash = unnamedGunInHand(ped)
        if hash == nil then return end
        stat.unnamedGun = stat.unnamedGun + 1
    end

    -- COUNTED THE WAY `lock` COUNTS, AND THAT IS THE WHOLE POINT OF THE pcall
    -- BEING HERE RATHER THAN IN `safe`. `safe` answers nil for a native that
    -- threw AND for one that is not on this build -- in the second case it never
    -- calls anything at all -- so incrementing after it counted passes that
    -- never reached the engine, under a readout that says the opposite in as
    -- many words. `pcall(nil, ...)` returns false rather than raising, which is
    -- why there is no `type(...)` guard in front of it; the same argument `lock`
    -- makes about the guard it deleted.
    local ok = pcall(DisableVehicleWeapon, true, hash, veh, ped)
    if ok then stat.disarmed = stat.disarmed + 1 end
end

-- ---------------------------------------------------------------------------
-- Asking the vehicle instead of the list (#329)
-- ---------------------------------------------------------------------------
--
-- ═══ ONE MISSING ROW WAS THREE BUGS, WHICH IS WHY THIS IS NOT ONE MORE ROW ═══
--
-- BR.Config.IsDisarmedVehicle answers three different questions in three files:
-- what this file disarms, what server/vehicles.lua reports as `ctx.vehicleGun`,
-- and -- through that flag -- whether br_lib/shared/combat_solve.lua reads an
-- unknown weapon hash as the car's gun or as an accusation. So a stock model
-- nobody wrote down is armed AND files a case against whoever drives it. The
-- owner reported the second such model on 2026-09-21 and withheld its name for
-- exactly this reason: "I'm not going to give you that vehicle's name because I
-- don't want you to hardcode anything with this."
--
-- ═══ SO POLICY STAYS AUTHORED AND FACT COMES FROM THE ENGINE ═══
--
-- WHICH VEHICLES THIS GAMEMODE REFUSES, which it lets you drive with the gun
-- switched off, and which it leaves alone are the OWNER'S RULINGS and are not
-- derived here. config/vehicles.lua keeps every row, every `why`, every
-- keepRefused exception and its gate in tools/check_vehicles.lua.
--
-- WHETHER A GIVEN VEHICLE HAS A GUN IS A FACT, and the engine knows it better
-- than a hand-written list does. Two natives, neither of which appeared anywhere
-- in this repository before this change -- they were never considered rather than
-- tried and rejected:
--
--   DOES_VEHICLE_HAVE_WEAPONS(vehicle)      0x25ECB9F8017D98E0
--   IS_TURRET_SEAT(vehicle, seatIndex)      0xE33FFA906CE74880
--
-- BOTH ARE ASKED, FOR DIFFERENT QUESTIONS, AND MIXING THEM UP IS THE MISTAKE
-- AVAILABLE HERE:
--
--   DOES_VEHICLE_HAVE_WEAPONS  "is this vehicle armed at all", and it is
--                              agnostic about HOW the weapon is worked. It is
--                              what the report to the server carries, because a
--                              Ruiner 2000, a Toreador, a Stromberg and a
--                              Scramjet all fire from the DRIVING seat -- a
--                              turret test alone would go on accusing that whole
--                              family of drivers.
--   IS_TURRET_SEAT             "does THIS seat have a gun", which is precisely
--                              the question GetCurrentPedVehicleWeapon has no
--                              opinion about in the Caracara's gun seat and the
--                              firetruck's hose seat -- the seam that makes both
--                              `isMountedWeapon` and `disarm` fail there. It is
--                              an extra signal for the DISARM, and it is NOT
--                              sent to the server.
--
-- ═══ WHAT HAS NOT BEEN CONFIRMED IN GAME, AND HOW THIS SURVIVES IT ═══
--
-- NEITHER DOC PAGE DESCRIBES ITS RETURN VALUE. Both are declared BOOL, so both
-- go through `isTrue` -- a FiveM BOOL answers `true` or `1` and `0` is truthy in
-- Lua, which this project has shipped six times -- and both are read through
-- `safe`, so an absent native, a throw or prose all read as "no opinion" rather
-- than as yes.
--
-- THREE THINGS A PLAYTEST HAS TO SETTLE and nothing here pretends to know:
--
--   * whether DOES_VEHICLE_HAVE_WEAPONS is true for vehicles carrying equipment
--     nobody would call a weapon -- the firetruck's hose is the known one and it
--     is excluded by hand below, but a police car's spike strip would be the
--     same shape. If it over-answers, the cost is a gun hash being handed to
--     DisableVehicleWeapon in a vehicle that has none, which the engine ignores.
--   * whether IS_TURRET_SEAT is true for the DRIVING seat of a car whose gun the
--     driver fires. Everything here is written on the assumption that it is not.
--   * whether either answers at all on this build. `/brvehrefuse` prints
--     `armed-silent`, which counts the reads that reached no engine at all --
--     absent native, or a handle that threw -- and THAT is the answer to this one.
--     It used to be read off `probed` climbing with the other two at zero, which
--     was wrong in both directions: that is also what a match full of ordinary
--     cars looks like.
--
-- ═══ WHAT IT COSTS PER PASS, WHICH IS THE CONTRACT THIS BAND KEEPS ═══
--
-- ASKED ONCE PER OCCUPANCY, NOT ONCE PER PASS. The answers are properties of the
-- vehicle and the seat, so they are latched and the latch is checked against the
-- handle AND THE MODEL for free -- both were read on this pass already. An
-- ordinary car costs THREE natives on the first pass somebody at its wheel sits in
-- it -- the vehicle-level question, one seat read, and the
-- seat question -- rising to twelve for a passenger, because the seats are walked
-- until one answers and there is no native that asks the other way round. Then
-- NOTHING for the rest of the match, because "this vehicle has no gun in any seat"
-- is a complete answer and the latch says so.
--
-- A READ THAT DID NOT ANSWER IS NOT AN OCCUPANCY'S ANSWER, and that is the one
-- thing that can cost more than the paragraph above. PROBE_TRIES bounds it at five
-- passes -- half a second at TICK -- so a build without the native pays five reads
-- for an occupancy instead of one, and a handle that was stale for a pass or two
-- gets the disarm and the report it is owed instead of silence for as long as the
-- player stays seated.
--
-- A vehicle that DID answer costs one native a pass after that: seat state is the
-- one thing that can change without the handle changing, and a player who
-- shuffles into the gun seat of a car they drove in must be re-asked. That one
-- native is `GetPedInVehicleSeat` on the latched seat, which is a confirmation
-- rather than a search.
--
-- A model the authored table already names is not probed at all. It is already
-- disarmed, the server already excuses it, and there is nothing a report could
-- add -- which is also what makes this change unable to alter how a listed
-- vehicle behaves.

--- Which seat this ped is in, by asking the vehicle rather than the ped.
---
--- There is no native that answers "which seat am I in"; the engine only answers
--- "who is in seat N". nil means no seat this file can name -- see MAX_SEAT --
--- and every caller reads that as "do not probe", never as seat 0.
--- @param veh integer
--- @param ped integer
--- @return integer|nil
local function seatOf(veh, ped)
    for i = -1, MAX_SEAT do
        if safe(GetPedInVehicleSeat, veh, i) == ped then return i end
    end
    return nil
end

--- What the engine last said about the vehicle this player is sitting in.
---
--- ONE SLOT, for the reason `pending` above is one slot: there is one local ped
--- and it is in one vehicle.
---
--- ═══ KEYED ON THE HANDLE AND THE MODEL TOGETHER, BECAUSE A HANDLE IS NOT A
---     VEHICLE ═══
---
--- ENTITY HANDLES ARE RECYCLED. Sit in an armed vehicle holding handle 10, get
--- out, let that vehicle be deleted, and the engine will hand 10 to the next thing
--- it creates -- which can be a plain Adder, in the same seat, a second later.
--- Keyed on the handle alone this latch answers "armed" for that Adder WITHOUT THE
--- ENGINE EVER HAVING BEEN ASKED ABOUT IT, and the far end cannot catch the
--- mistake: server/vehicles.lua reads the model off the vehicle IT resolved, so
--- its handle, model and match checks all pass and the report is believed.
---
--- THE MODEL COSTS NOTHING TO KEY ON. `refusalFor` has already read it on this
--- pass and hands it to the probe; it is the same hash `disarm` is given.
---
--- IT IS NOT ENOUGH ON ITS OWN AND IS NOT MEANT TO BE. Two vehicles of the same
--- model can share a recycled handle, and that pair is indistinguishable from here
--- -- which costs nothing, because the answer for the second one is the answer for
--- the first. What ends an occupancy properly is the gate: it calls `clearProbe`
--- wherever it calls `clearPending`, so getting out is the end of the measurement
--- and sitting down again is a new one.
---
--- `answered` IS SEPARATE FROM `armed` AND `turret` BECAUSE A READ THAT DID NOT
--- HAPPEN IS NOT A READ THAT SAID NO. Only a read that reached the engine latches;
--- `tries` bounds how many passes of one occupancy may try, which is PROBE_TRIES
--- and the whole argument is there. Together they also keep "nothing has been
--- asked yet" distinguishable from "asked and told no" -- the same reason `rulings`
--- stores `false` rather than nil.
local probe = { veh = 0, model = nil, tries = 0, answered = false, seat = nil,
                armed = false, turret = false, sentAt = nil }

--- Nothing has been asked about any vehicle.
local function clearProbe()
    probe.veh, probe.model, probe.tries, probe.answered = 0, nil, 0, false
    probe.seat, probe.armed, probe.turret, probe.sentAt = nil, false, false, nil
end

--- Tell the server the engine calls this vehicle armed.
---
--- ONLY THE ARMED HALF TRAVELS, and only as a positive. The far end may add
--- armament to the authored table's answer and may never remove it, so there is
--- nothing for a "no" to mean there: silence IS the table's answer. The seat rides
--- along because it is what the server validates the claim with -- see
--- BR.Net.VEH_ARMED in br_lib/shared/protocol.lua.
---
--- THE NETWORK ID, NOT THE HANDLE. A handle is a name only this machine uses. `0`
--- is what the engine answers for a vehicle it does not network -- the Battle Bus,
--- #191's rescue ambulance -- and a report naming one would be a report about a
--- vehicle the server has never heard of, so it is not sent. Nobody drives either
--- of those two, and the player in them is not in a state this loop runs in.
--- THE CLOCK IS READ HERE AND NOT PASSED IN, which is one native rather than a
--- style choice: called with `GetGameTimer()` at the site, every player sitting in
--- an ordinary car would pay for it on every pass to reach a function that returns
--- on its first line. Both guards above it are table reads.
--- @param veh integer
local function report(veh)
    if not probe.armed then return end
    -- NO SEAT, NO REPORT. The server's whole check is "is this ped really in that
    -- seat of that vehicle", so a claim that cannot name a seat cannot be checked
    -- and would be dropped on arrival. See MAX_SEAT for whose seat this is.
    if probe.seat == nil then return end

    local now = GetGameTimer()
    if probe.sentAt ~= nil and now - probe.sentAt < REPORT_EVERY_MS then return end

    local nid = math.tointeger(tonumber(safe(NetworkGetNetworkIdFromEntity, veh)))
    -- ZERO IS EXPLICIT, for the reason every other zero in this file is: `0` is
    -- truthy in Lua.
    if nid == nil or nid == 0 then return end

    probe.sentAt = now
    stat.reported = stat.reported + 1
    TriggerServerEvent(BR.Net.VEH_ARMED, { netId = nid, seat = probe.seat })
end

--- Find which seat this player is in and ask the engine about it.
---
--- THE WALK IS WHAT COSTS THE TEN NATIVES, so this is called on a fresh occupancy
--- and on a real seat change and at no other time. `sentAt` is cleared with it: a
--- player who has just moved into the gun seat is a NEW claim, not a repeat of the
--- old one, and must not wait out a cadence window opened by the seat they left.
---
--- A FILE-LOCAL FUNCTION AND NOT A CLOSURE INSIDE `engineProbe`, which is where it
--- was first written: that would allocate one per pass for every player sitting in
--- a vehicle in the match, on the band this project keeps its performance contract
--- in, for a function whose two arguments it already has.
--- @param ped integer
--- @param veh integer
local function askSeat(ped, veh)
    probe.seat, probe.turret, probe.sentAt = seatOf(veh, ped), false, nil
    if probe.seat == nil then return end
    probe.turret = isTrue(safe(IsTurretSeat, veh, probe.seat))
    if probe.turret then stat.turretSeat = stat.turretSeat + 1 end
end

--- Ask the engine about the vehicle this player is in, at most once per
--- occupancy, and report an armed one to the server.
---
--- @param ped integer
--- @param veh integer
--- @param model integer|nil
--- @return boolean armed   the engine says this vehicle carries weapons
--- @return boolean turret  the engine says this seat is a turret
local function engineProbe(ped, veh, model)
    -- ═══ THE TWO AUTHORED ANSWERS THAT STOP THIS BEFORE ANY NATIVE ═══
    --
    -- A MODEL THE RULING ALREADY NAMES needs nothing from the engine: `disarm`
    -- runs for it either way and server/vehicles.lua already excuses it, so a
    -- probe could only cost natives and a report nobody reads. It is also what
    -- guarantees this change cannot alter how a listed vehicle behaves.
    if BR.Config.IsDisarmedVehicle(model) then return false, false end

    -- AND THE FIRETRUCK, WHICH IS THE CASE THAT PROVES POLICY IS STILL THE
    -- OWNER'S. Its hose IS a vehicle weapon, so the engine will say so -- and
    -- c58745f settled that using a firehose is not an incident and not something
    -- to switch off ("I want them to be able to use the firehose. That's the
    -- point."). A version of this that disarmed it because the engine said it was
    -- armed would be a regression wearing a fix's clothes. BR.Config's own table
    -- is what excludes it, so the day the owner rules on a second such vehicle
    -- the change is one row there and nothing here.
    local exempt = BR.Config and BR.Config.StripExemptByHash
    if model == nil or (exempt and exempt[BR.NormHash(model)] ~= nil) then
        return false, false
    end

    -- ═══ A FRESH OCCUPANCY IS A NEW HANDLE OR A NEW MODEL UNDER THE OLD ONE ═══
    --
    -- THE MODEL IS HALF THE KEY AND THAT IS THE CORRECTNESS HALF: see `probe` for
    -- the Adder that inherited an armed claim from whatever held handle 10 before
    -- it. Both values were read on this pass already, so the key is two table
    -- comparisons and no natives.
    if probe.veh ~= veh or probe.model ~= model then
        clearProbe()
        probe.veh, probe.model = veh, model
        stat.probed = stat.probed + 1
    end

    if not probe.answered and probe.tries < PROBE_TRIES then
        -- ═══ ASKED UNTIL IT ANSWERS, AND PROBE_TRIES TIMES AT MOST ═══
        --
        -- THE VEHICLE FIRST, because it is one native and it is the answer the
        -- server is told about. `tried` says whether the call reached the engine at
        -- all -- an absent native and a throwing handle did not -- and `isTrue`
        -- says what a call that did reach it MEANT: `1` is yes, `0` is no, and `0`
        -- is truthy in Lua.
        --
        -- ONLY AN ANSWER LATCHES. Anything else leaves `answered` false and the
        -- next pass asks again, up to PROBE_TRIES, which is where the argument for
        -- both halves of that is written.
        probe.tries = probe.tries + 1
        local answered, v = tried(DoesVehicleHaveWeapons, veh)
        if answered then
            probe.answered = true
            probe.armed = isTrue(v)
            if probe.armed then stat.engineArmed = stat.engineArmed + 1 end
        else
            -- COUNTED, BECAUSE IT IS THE ONE THING THIS PROCESS CANNOT INFER. A
            -- `probed` that climbs with `engine-armed` at zero is ALSO what a match
            -- full of ordinary cars looks like, so without this number
            -- /brvehrefuse cannot tell a build where the native is silent from one
            -- where every car really was unarmed.
            stat.armedSilent = stat.armedSilent + 1
        end

        -- THE SEAT IS ASKED ABOUT EVEN WHEN THE VEHICLE SAID NO. It is the half
        -- that sees the Caracara's gun seat, and reading it only after a yes would
        -- make the whole probe rest on one undocumented return value.
        --
        -- ONCE THE SEAT HAS A NAME THE WALK IS NOT PAID FOR AGAIN HERE. A retry
        -- exists for the read that did not answer; re-walking a seat an earlier
        -- pass already named would cost ten natives and count the same turret
        -- twice. The seat-change branch below is what watches it after that.
        if probe.seat == nil then askSeat(ped, veh) end
    elseif not probe.armed and not probe.turret then
        -- NO GUN IN THIS VEHICLE, so no seat of it can matter and there is nothing
        -- to confirm. Zero natives, for the whole time a player spends in an
        -- ordinary car.
        --
        -- THIS IS ALSO WHERE A SILENT BUILD SETTLES, once PROBE_TRIES is spent: the
        -- authored table is the whole answer then, which is the pre-#329 behavior
        -- and the honest floor. `armed-silent` in the readout is what says that is
        -- what happened, rather than leaving an operator to guess from a zero.
        --
        -- IT IS AN INFERENCE ABOUT AN UNCONFIRMED NATIVE and worth naming as one:
        -- it assumes a vehicle the engine calls unarmed has no turret seat. If
        -- that is ever false, the cost is a gun in a seat this never asks about,
        -- in a vehicle the engine denied -- which is exactly today's behavior.
        return false, false
    elseif probe.seat ~= nil
        and safe(GetPedInVehicleSeat, veh, probe.seat) ~= ped then
        -- THE SEAT CHANGED WITHOUT THE VEHICLE CHANGING. A player who drives a
        -- Technical to a fight and then shuffles into the bed is in a different
        -- seat of the same handle, and the turret answer is about the seat. One
        -- native a pass confirms the latched one still holds this ped; only a
        -- failure pays for the walk again.
        --
        -- THE VEHICLE-LEVEL ANSWER IS NOT RE-ASKED, because it is a property of
        -- the vehicle and nobody changed vehicles.
        askSeat(ped, veh)
    end
    -- AND A LATCHED OCCUPANCY WHOSE SEAT COULD NOT BE NAMED FALLS THROUGH ALL
    -- THREE, deliberately: there is no seat state to confirm, so re-walking ten
    -- natives a pass would buy nothing. A player who later shuffles from the back
    -- of a coach into a seat this file can name is not re-asked until they change
    -- vehicle -- the same limit server/vehicles.lua's `ridingIn` states for seats
    -- past the eighth, and for the same reason.
    --
    -- WHICH IS ALSO THE LIMIT OF THE RETRY ABOVE, AND IT IS A SMALLER THING THAN
    -- IT LOOKS. A seat walk that THREW on a pass where the vehicle question
    -- answered leaves this occupancy with no seat, so no report -- but the GUN is
    -- still held off, because `armed` carries the disarm on its own, and the
    -- confirmation branch re-walks the moment a later read disagrees. What is lost
    -- is the server's excuse for a shot, not a live weapon.

    report(veh)
    return probe.armed, probe.turret
end

-- ---------------------------------------------------------------------------
-- Refusing it
-- ---------------------------------------------------------------------------

--- The vehicle we last told this player to get out of, and the two clocks.
---
--- ONE SLOT AND NOT A TABLE PER VEHICLE. There is exactly one local ped and it
--- can be in one vehicle, so a second row could only ever be stale.
---
--- `seatedSince` IS SEPARATE FROM THE REJECTION and starts only when the seat is
--- observed taken. A player intercepted at the door and then somehow seated a
--- second later must get the polite `TaskLeaveVehicle` first, not the hammer --
--- one clock for both would have escalated straight past it.
local pending = { veh = 0, seatedSince = nil, notifiedAt = nil }

--- Nobody is being ejected from anything.
local function clearPending()
    pending.veh, pending.seatedSince, pending.notifiedAt = 0, nil, nil
end

--- Put the doors back to locked.
---
--- BEST EFFORT, AND SILENT WHEN IT FAILS. Door lock state is entity state, so it
--- only sticks if this client owns the entity -- which it does whenever its own
--- ped was just in or entering it, which is every path that reaches here. The
--- control request is a nicety for the entering case, where ownership may not
--- have migrated yet; it is asynchronous and nothing waits on it, so the lock
--- either lands now or lands on the next attempt, and the next attempt is what
--- the loop is for.
---
--- `locked` COUNTS ATTEMPTS THAT REACHED THE NATIVE, not doors that ended up
--- locked -- the native returns nothing and there is no honest way to count the
--- latter from here. /brvehrefuse prints the real lock status of the vehicle the
--- player is in, which is the reading that answers the question.
--- @param veh integer
local function lock(veh)
    -- ═══ WRITTEN ONLY WHEN IT IS NOT ALREADY WHAT WE WANT ═══
    --
    -- Door lock state is NETWORKED state, and `reject` runs on every pass of a
    -- 100 ms loop for as long as a player leans on the entry key. Writing it ten
    -- times a second for the whole of that is ten times a second of sync traffic
    -- to set a value to the value it already holds.
    --
    -- THIS IS NOT THE "SKIP THE CHECK IF IT IS LOCKED" BUG THE HEADER WARNS
    -- ABOUT, and the difference is worth being exact about: the RULING has
    -- already been made by the time this function is called, and the player is
    -- already being ejected. What is skipped is a redundant WRITE, never a read
    -- of whether the vehicle is refused. An ambient Buzzard the map locked is
    -- still checked, still refused, and still emptied -- it just does not need
    -- its doors locked twice.
    --
    -- A status that cannot be read comes back nil, which is not LOCK_STATE, so
    -- the write happens. That is the safe direction.
    if safe(GetVehicleDoorLockStatus, veh) == LOCK_STATE then return end

    safe(NetworkRequestControlOfEntity, veh)
    -- NO `type(...) == 'function'` GUARD, DELIBERATELY. It was written and then
    -- removed: `pcall(nil, ...)` returns false rather than raising, so the guard
    -- and the pcall had identical behaviour and mutation testing correctly
    -- reported the guard as unkillable. Two lines that cannot differ are one
    -- line and a comment.
    local ok = pcall(SetVehicleDoorsLocked, veh, LOCK_STATE)
    if ok then stat.locked = stat.locked + 1 end
end

--- Show the sentence, at most once per NOTIFY_COOLDOWN_MS.
--- @param now integer
local function tell(now)
    if pending.notifiedAt ~= nil
        and now - pending.notifiedAt < NOTIFY_COOLDOWN_MS then
        return
    end
    pending.notifiedAt = now
    stat.notified = stat.notified + 1
    -- 'info' AND NOT 'warn'. The player being shown this is usually somebody who
    -- walked into a parked Buzzard; the sentence is a rule, not an accusation,
    -- and it says the same thing to everybody (see the header on #93).
    BR.Notify(BR.VehRefuse.MESSAGE, 'info',
        { key = 'vehrefuse', ms = 6000 })
end

--- Take this player out of this vehicle, tell them why, and lock it behind them.
---
--- @param ped integer
--- @param veh integer
--- @param seated boolean  true when the seat was already taken
--- @param now integer
local function reject(ped, veh, seated, now)
    stat.rejected = stat.rejected + 1

    -- A DIFFERENT VEHICLE IS A FRESH EPISODE: fresh escalation clock, and the
    -- sentence is owed again even if one was shown a moment ago for another car.
    if pending.veh ~= veh then
        pending.veh, pending.seatedSince, pending.notifiedAt = veh, nil, nil
    end

    if seated and pending.seatedSince == nil then pending.seatedSince = now end

    if not seated then
        -- BEFORE THE SEAT. Cancelling the entry task leaves the player standing
        -- where they were, which is the outcome the owner described: the action
        -- is rejected rather than undone.
        safe(ClearPedTasksImmediately, ped)
        stat.cancelled = stat.cancelled + 1
    elseif now - pending.seatedSince >= ESCALATE_MS then
        -- THE TASK WAS ISSUED AND THE PLAYER IS STILL SITTING THERE. See
        -- ESCALATE_MS: a refused task and an unfinished task look identical, so
        -- after four passes this stops asking. `ClearPedTasksImmediately` is not
        -- a task and is not declined.
        safe(ClearPedTasksImmediately, ped)
        stat.hammered = stat.hammered + 1
    else
        -- Flag 16: teleport out, door kept closed. Not the door-open animation,
        -- which takes a second the player would spend flying.
        safe(TaskLeaveVehicle, ped, veh, 16)
        stat.ejected = stat.ejected + 1
    end

    tell(now)

    -- LOCKED LAST, AFTER THE PED IS ON ITS WAY OUT. Locking a vehicle somebody is
    -- still in is the one ordering that could trap them, and it costs nothing to
    -- rule it out. See the header for why state 2 could not anyway.
    lock(veh)
end

-- ---------------------------------------------------------------------------
-- The pass
-- ---------------------------------------------------------------------------

--- Is this player in a state where taking a vehicle is theirs to do?
---
--- See the header: BUS, FREEFALL and GLIDE are states in which the gamemode is
--- carrying the player, and the Battle Bus is itself a refused model.
--- @return boolean
local function enabled()
    local st = BR.State and BR.State.me and BR.State.me.state
    return st == BR.PlayerState.ALIVE or st == BR.PlayerState.WARMUP
end

BR.Loop.register(BR.Loop.TICK, 'vehrefuse.gate', function()
    -- ═══ THE PROBE IS CLEARED WHEREVER THE PENDING EJECTION IS ═══
    --
    -- ALL THREE OF THESE ARE "THIS PLAYER IS NOT SITTING IN ANYTHING", and an
    -- occupancy that has ended is not a fact about the next one. Without this the
    -- latch outlived dismounts, deaths and match boundaries -- `BR.VehRefuse.reset`
    -- calls `clearProbe` too, but nothing in `resources/` calls that function, so
    -- the only real clear is this one. See `probe` for what a latch that outlives
    -- its vehicle costs when the engine reissues the handle.
    if not enabled() then
        clearPending()
        clearProbe()
        return
    end

    local ped = PlayerPedId()

    -- ═══ FIRST: THE CAR BEING CLIMBED INTO, BEFORE THE SEAT IS TAKEN ═══
    --
    -- Guarded with `and ... or 0` exactly as client/fuel.lua and
    -- client/vehdamage.lua guard the same native: it is not stubbed in every
    -- harness and a missing native must read as "not entering anything".
    local entering = GetVehiclePedIsEntering and GetVehiclePedIsEntering(ped) or 0
    -- ZERO IS EXPLICIT BECAUSE `0` IS TRUTHY IN LUA. `if entering then` is true
    -- for a player standing in a field.
    if entering ~= 0 then
        if refusalFor(entering) ~= nil then
            reject(ped, entering, false, GetGameTimer())
            return
        end
    end

    -- ═══ THEN: THE SEAT, FOR THE ENTRIES THE WINDOW ABOVE DID NOT CATCH ═══
    if not isTrue(IsPedInAnyVehicle(ped, false)) then
        clearPending()
        clearProbe()
        return
    end

    local veh = GetVehiclePedIsIn(ped, false) or 0
    -- ZERO IS EXPLICIT for the reason it is explicit twenty lines up.
    if veh == 0 then
        clearPending()
        clearProbe()
        return
    end

    -- ANY SEAT, NOT ONLY THE DRIVER'S, and this is the one place this file is
    -- deliberately WIDER than server/vehicles.lua's occupancy detector.
    --
    -- That detector is driver-only because it opens a CASE against a person, and
    -- a passenger can be put in a seat by somebody else -- its header argues that
    -- at length and it is right. This file opens nothing against anybody. It
    -- enforces "this vehicle is not allowed to be used during the match", and a
    -- Buzzard with a gunner in the back is being used.
    local why, model = refusalFor(veh)
    if why ~= nil then
        reject(ped, veh, true, GetGameTimer())
        return
    end

    -- ═══ AND THE VEHICLES #322 LETS THEM KEEP, WITH THE GUN HELD OFF ═══
    --
    -- BELOW THE REFUSAL AND AFTER A `return`, so the two can never both run on
    -- one pass. They are mutually exclusive by the ruling -- an ARMED row of the
    -- model table leaves BR.Config.VehicleRefusalFor as allowed, so `why` is nil
    -- for every vehicle `disarm` acts on -- and the `return` says so in code
    -- rather than leaving it as something a reader has to re-derive.
    --
    -- ANY SEAT, for the reason the refusal above is any seat: the gunner's seat
    -- is the one with the gun in it, and a driver-only disable would switch off
    -- the only thing nobody was using.
    --
    -- ON TICK, WITH THE REST OF THIS FILE, AND THE BAND IS A CONDITIONAL
    -- DECISION RATHER THAN A SETTLED ONE.
    --
    -- THE TWO READINGS, BECAUSE THE SOURCES DISAGREE AND NOBODY HAS MEASURED IT:
    --
    --   A LOCK.  citizenfx's page for DisableVehicleWeapon describes a
    --            ped-specific lock rather than a per-frame suppression. On that
    --            reading the loop exists only for the OTHER half -- the seat's
    --            weapon can CHANGE under us, so the hash has to be re-read and
    --            the new one disabled -- and the exposure is at most one tenth
    --            of a second of a gun immediately after a switch.
    --   NOT A    #322 says the opposite in as many words: "the call does not
    --   LOCK.    persist, so it is a loop, not a one-shot". On that reading the
    --            gun is live for most of every 100 ms window and TICK is the
    --            wrong band.
    --
    -- SO WHAT THE CHOICE ACTUALLY RESTS ON IS THAT NEITHER READING COSTS A CASE.
    -- A hit landed in the window is refused by server/damage.lua as
    -- BR.ShotRefusal.VEHICLE_GUN -- a rule, not a means -- so it is cancelled
    -- and accuses nobody, and the same is true of the strip report. That is what
    -- makes the cheap band defensible while the question is open; it was not
    -- true when this was first written, and the comment that stood here argued
    -- from the lock reading as though it were established.
    --
    -- THE OTHER SIDE IS SMALL TOO, AND SMALLER THAN THIS USED TO CLAIM. FRAME
    -- costs two natives a frame for a player SEATED IN ONE OF ROUGHLY SIXTY
    -- MODELS -- not "every player sitting in one" of anything, since the model
    -- test above turns an ordinary car away for one table lookup.
    --
    -- THE PLAYTEST THAT SETTLES IT, and it is one round: sit in a Technical,
    -- hold the trigger on the mounted gun at another player, and run
    -- `/brshots VEHICLE_GUN` on the server console. A shot only reaches the
    -- validator when it HITS somebody, so an empty list means the lock held and
    -- TICK is right. A column of them means it does not, and this comment is the
    -- one to come back to: move the `disarm` call to a FRAME registration.
    --
    -- ═══ AND SINCE #329 THE ENGINE IS ASKED ABOUT THE ONES NOBODY WROTE DOWN ═══
    --
    -- BELOW THE REFUSAL FOR THE REASON `disarm` IS: a vehicle this gamemode
    -- refuses has already returned, so the probe can only ever widen the set whose
    -- GUN is held off and can never touch the set that is EMPTIED. See the section
    -- above `seatOf` for which native answers which question and what it costs.
    local armed, turret = engineProbe(ped, veh, model)
    disarm(ped, veh, model, armed, turret)
end)

-- ---------------------------------------------------------------------------
-- Lifecycle and the readout
-- ---------------------------------------------------------------------------

--- Forget every ruling and every pending ejection.
function BR.VehRefuse.reset()
    rulings, ruled = {}, 0
    clearPending()
    clearProbe()
    for k in pairs(stat) do stat[k] = 0 end
end

--- @return table  a copy of the counters
function BR.VehRefuse.stats()
    local out = {}
    for k, v in pairs(stat) do out[k] = v end
    out.models = ruled
    return out
end

--- What this machine ACTUALLY did, for the questions a Lua process cannot answer.
---
--- ═══ THE THINGS THAT CANNOT BE SETTLED WITHOUT A LIVE SERVER ═══
---
--- Three, and none of them is a test this suite could have written:
---
---   * whether the entry window really is wide enough on this build -- whether
---     `cancelled` outnumbers `ejected` in practice, which is the difference
---     between "rejected as they try" and "yanked back out".
---   * whether `SetVehicleDoorsLocked` sticks on an entity this client did not
---     create, and whether it survives the other players in the lobby.
---   * whether `TaskLeaveVehicle` with flag 16 is ever declined here at all, and
---     so whether ESCALATE_MS's hammer ever fires.
---
--- AND #322 ADDED A FOURTH, WHICH IS THE ONE TO READ FIRST AFTER A ROUND IN A
--- CARACARA.
---
---   `disarmed`     passes on which the disable was CALLED on a gun and the
---                  call reached the native, whichever place the hash came
---                  from: named by the seat, or read from the hand where the
---                  seat names nothing. Not weapons proved silent: the native
---                  returns nothing, so that is the most this side can
---                  honestly claim, and it is the same honesty `locked` is
---                  counted with above. A build without DisableVehicleWeapon
---                  leaves this at zero rather than counting passes that went
---                  nowhere.
---   `unnamed-gun`  passes on which the seat named NOTHING and the engine had
---                  nevertheless put a weapon in the hand that this gamemode
---                  issues nobody -- so the HAND's hash is the one handed to
---                  the disable. BOTH HALVES, because either alone is noise:
---                  the driver of a Technical has no vehicle weapon and would
---                  otherwise climb this ten times a second all match. The pair
---                  is the firetruck's seam, and on the evidence the Caracara's
---                  gun seat. A climbing number says the seat will not name its
---                  gun, NOT that the gun is live: it is the gun being switched
---                  off from the hand, and it climbs with `disarmed` beside it.
---
--- SO, IN THE CARACARA'S GUN SEAT: both climbing together means the hand path
--- is doing the work. `disarmed` climbing alone means the seat names a gun
--- after all -- and if the gun still fires, it is naming a different one from
--- the gun in the hand, which this file does not cover. `unnamed-gun` climbing
--- while `disarmed` does not means the disable never reached the engine. And a
--- gun that fires with both climbing means the hand's hash is not the one the
--- engine wanted, or the lock does not survive a TICK -- see the note at the
--- `disarm` call site.
---
--- NEITHER OF THEM IS THE ANTICHEAT'S ANSWER ANY MORE, and that is worth knowing
--- before reading them. server/damage.lua and server/strip.lua excuse a hash we
--- issue nobody from anybody sitting in one of these models, so a seat this
--- cannot disable files no case either way. These two numbers say whether the
--- WEAPON was switched off, not whether somebody is accused.
---
--- This command answers all four from a real lobby. It prints to the console.
RegisterCommand('brvehrefuse', function()
    local s = BR.VehRefuse.stats()
    print(('[vehrefuse] asked=%d cached=%d models=%d rejected=%d'):format(
        s.asked, s.cached, s.models, s.rejected))
    print(('[vehrefuse] cancelled-before-seat=%d ejected-from-seat=%d hammered=%d')
        :format(s.cancelled, s.ejected, s.hammered))
    print(('[vehrefuse] locked=%d shown=%d  gate=%s'):format(
        s.locked, s.notified, tostring(enabled())))
    print(('[vehrefuse] disarmed=%d unnamed-gun=%d'):format(
        s.disarmed, s.unnamedGun))
    -- #329's FIVE, AND `armed-silent` IS THE ONE THAT ANSWERS THE BUILD QUESTION.
    -- `probed` counts OCCUPANCIES the engine was asked about at all, and it was
    -- once claimed here that a `probed` climbing with `engine-armed` at zero meant
    -- the natives were not answering. IT DOES NOT: that is also what a match full
    -- of ordinary cars looks like. `armed-silent` counts the reads of
    -- DOES_VEHICLE_HAVE_WEAPONS that reached no engine at all -- absent native, or
    -- a handle that threw -- so it climbing is the answer, and it climbing at up to
    -- PROBE_TRIES per occupancy is what a build without the native looks like.
    -- `reported` is how many times the server was told; it climbs on the
    -- REPORT_EVERY_MS cadence while somebody sits in an armed car, so it is
    -- expected to outrun `engine-armed`.
    print(('[vehrefuse] probed=%d engine-armed=%d turret-seat=%d reported=%d '
           .. 'armed-silent=%d')
        :format(s.probed, s.engineArmed, s.turretSeat, s.reported,
                s.armedSilent))

    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn and GetVehiclePedIsIn(ped, false) or 0
    if veh ~= 0 then
        print(('[vehrefuse] this vehicle: model=%s type=%s class=%s lock=%s ruling=%s')
            :format(tostring(modelOf(veh)), tostring(typeOf(veh)),
                    tostring(classOf(veh)),
                    tostring(safe(GetVehicleDoorLockStatus, veh)),
                    tostring(refusalFor(veh))))
        -- THE ENGINE'S OWN TWO ANSWERS FOR THE SEAT THIS PLAYER IS IN, read
        -- fresh rather than out of the latch: the question an operator is asking
        -- here is what the natives say right now, and printing the latch would
        -- answer a different one. Both are BOOL, so both go through `isTrue`.
        local seat = seatOf(veh, ped)
        print(('[vehrefuse] this vehicle: seat=%s engine-armed=%s turret=%s')
            :format(tostring(seat),
                    tostring(isTrue(safe(DoesVehicleHaveWeapons, veh))),
                    tostring(seat ~= nil
                        and isTrue(safe(IsTurretSeat, veh, seat)) or nil)))
    end
end, false)
