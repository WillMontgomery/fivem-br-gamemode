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
               disarmed = 0, unnamedGun = 0 }

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
-- ═══ AND THE SEAT THIS CANNOT SEE IS ANSWERED ON THE SERVER, NOT HERE ═══
--
-- `GetCurrentPedVehicleWeapon` has no opinion about some gun positions -- the
-- firetruck's hose is the one this project has measured -- and in one of those
-- there is no hash to disable, so the gun stays live and the engine puts it in
-- the player's hand. Before #322 that could not happen in an armed vehicle
-- because nobody was in the seat for longer than a tenth of a second; now they
-- sit there all match, in about sixty models, one of which is for sale.
--
-- NOTHING HERE PAPERS OVER IT. What that seat used to cost was a high severity
-- anticheat case against somebody who got into a car -- server/damage.lua
-- refusing the shots as NO_WEAPON, server/strip.lua filing the stripped hash --
-- and both of those now ask BR.Vehicles.inDisarmedVehicle and decline to accuse
-- anybody sitting in a model this ruling disarms. The GUN in such a seat is
-- still live, which is a gameplay gap and is counted as `unnamed-gun` by
-- `/brvehrefuse`; it is not an accusation any more.

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
--- coincidence. The seats where it does NOT answer are the other half, and they
--- are answered on the server: see the section header above.
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

--- Is the engine holding a gun in this ped's hand that this gamemode issues
--- NOBODY?
---
--- ═══ THE FIRETRUCK SIGNATURE, AND THE COUNTER BELOW MEANS NOTHING WITHOUT IT
---     ═══
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
--- lua's `isMountedWeapon` cannot see and the strip fires on, and it is the only
--- reading that says a model needs an answer of its own.
---
--- FOUR CONDITIONS IN THE SAFE DIRECTION, the same four `mountedWeaponOf` above
--- takes, and "safe" here means NOT COUNTING: a native that is absent, throws,
--- declines to answer or names nothing leaves the counter where it was. This is
--- a diagnostic, so a silence that inflates it is worse than a silence that
--- loses it.
---
--- THE PARACHUTE IS NOT A GUN. It is in no weapon row -- client/inventory.lua's
--- strip excuses it by hash for that reason -- and it is granted on purpose by
--- client/skydive.lua, so counting it would be counting our own grant.
--- @param ped integer
--- @return boolean
local function unnamedGunInHand(ped)
    local pok, answered, held = pcall(GetCurrentPedWeapon, ped, true)
    if not pok or not isTrue(answered) then return false end

    -- `BR.NormHash(0)` IS 0 AND 0 IS TRUTHY, so "no weapon" is tested for rather
    -- than trusted to be falsy -- the reading this file normalises everything
    -- else for.
    local h = BR.NormHash(held)
    if h == nil or h == 0 then return false end

    local known = BR.Config and BR.Config.WeaponByHash
    if known == nil then return false end
    if known[h] ~= nil then return false end

    local gadgets = BR.Config.Gadgets
    if gadgets and h == BR.NormHash(gadgets.PARACHUTE) then return false end

    return true
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
--- ═══ NOTHING EVER CALLS IT WITH `false` ═══
---
--- There is no re-enable path and there should not be one. The lock is per ped
--- and per vehicle, so a player who gets out takes nothing with them and leaves
--- nothing behind for the next occupant that a pass of this loop would not
--- re-establish. A Cfx report of the `false` call leaving a vehicle unable to
--- find its weapons again until it is respawned is the other reason: an undo
--- nobody needs is an undo that can only break something.
--- @param ped integer
--- @param veh integer
--- @param model integer|nil
local function disarm(ped, veh, model)
    if not BR.Config.IsDisarmedVehicle(model) then return end

    local hash = mountedWeaponOf(ped)
    if hash == nil then
        -- THE SEAT THE NATIVE HAS NO OPINION ABOUT, COUNTED ONLY WHEN THE ENGINE
        -- HAS ACTUALLY PUT SOMETHING IN THE HAND. There is no hash, so there is
        -- nothing to disable and this pass is a no-op either way -- but most of
        -- these passes are an ordinary driver, and counting those made the
        -- number unreadable. `unnamedGunInHand` is the other half, and the pair
        -- is the firetruck: a gun the seat will not name, in a hand, in no row
        -- of ours. See that function for why one half alone says nothing.
        --
        -- IT IS A COUNTER AND NOT A FALLBACK. The fallback would be
        -- BR.Config.StripExemptVehicles, which switches the anticheat off for
        -- the whole model; see that table's header for what does the work
        -- instead. This number is what says a model needs one anyway, because it
        -- is the seat where the gun is live and nothing here can hold it off.
        if unnamedGunInHand(ped) then
            stat.unnamedGun = stat.unnamedGun + 1
        end
        return
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
    if not enabled() then
        clearPending()
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
        return
    end

    local veh = GetVehiclePedIsIn(ped, false) or 0
    -- ZERO IS EXPLICIT for the reason it is explicit twenty lines up.
    if veh == 0 then
        clearPending()
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
    disarm(ped, veh, model)
end)

-- ---------------------------------------------------------------------------
-- Lifecycle and the readout
-- ---------------------------------------------------------------------------

--- Forget every ruling and every pending ejection.
function BR.VehRefuse.reset()
    rulings, ruled = {}, 0
    clearPending()
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
---   `disarmed`     passes on which the engine NAMED a gun and the disable was
---                  CALLED on it and the call reached the native. Not weapons
---                  proved silent: the native returns nothing, so that is the
---                  most this side can honestly claim, and it is the same
---                  honesty `locked` is counted with above. A build without
---                  DisableVehicleWeapon leaves this at zero rather than
---                  counting passes that went nowhere.
---   `unnamed-gun`  passes on which the seat named NOTHING and the engine had
---                  nevertheless put a weapon in the hand that this gamemode
---                  issues nobody. BOTH HALVES, because either alone is noise:
---                  the driver of a Technical has no vehicle weapon and would
---                  otherwise climb this ten times a second all match. The pair
---                  is the firetruck, and it is the reading that says a model
---                  needs an answer of its own -- the gun is live in that seat
---                  and nothing on this side can hold it off.
---
--- NEITHER OF THEM IS THE ANTICHEAT'S ANSWER ANY MORE, and that is worth knowing
--- before reading them. server/damage.lua and server/strip.lua excuse a hash we
--- issue nobody from anybody sitting in one of these models, so a seat this
--- cannot disable files no case either way. These two numbers say whether the
--- WEAPON works, not whether somebody is accused.
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

    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn and GetVehiclePedIsIn(ped, false) or 0
    if veh ~= 0 then
        print(('[vehrefuse] this vehicle: model=%s type=%s class=%s lock=%s ruling=%s')
            :format(tostring(modelOf(veh)), tostring(typeOf(veh)),
                    tostring(classOf(veh)),
                    tostring(safe(GetVehicleDoorLockStatus, veh)),
                    tostring(refusalFor(veh))))
    end
end, false)
