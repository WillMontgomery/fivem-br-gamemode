-- Refusing a vehicle at the door, on the machine of the player opening it.
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
local function isTrue(v)
    return v == 1 or v == true
end

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
               cancelled = 0, hammered = 0, locked = 0, notified = 0 }

--- Why this gamemode refuses this vehicle, or nil.
---
--- THE RULING IS NOT MADE HERE. BR.Config.VehicleRefusalFor makes it, for this
--- file and for both server-side detectors, and that is deliberate rather than
--- tidy: #191's ambulance needs one exemption in one function, and the moment
--- this file grew its own copy of the ordering that promise would be false. All
--- three signals -- model table, type, class -- are described there.
--- @param veh integer
--- @return string|nil
local function refusalFor(veh)
    local model = modelOf(veh)
    local key = BR.NormHash(model)

    if key ~= nil then
        local hit = rulings[key]
        if hit ~= nil then
            stat.cached = stat.cached + 1
            return hit or nil
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

    return why
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
    if refusalFor(veh) ~= nil then
        reject(ped, veh, true, GetGameTimer())
    end
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
--- This command answers all three from a real lobby. It prints to the console.
RegisterCommand('brvehrefuse', function()
    local s = BR.VehRefuse.stats()
    print(('[vehrefuse] asked=%d cached=%d models=%d rejected=%d'):format(
        s.asked, s.cached, s.models, s.rejected))
    print(('[vehrefuse] cancelled-before-seat=%d ejected-from-seat=%d hammered=%d')
        :format(s.cancelled, s.ejected, s.hammered))
    print(('[vehrefuse] locked=%d shown=%d  gate=%s'):format(
        s.locked, s.notified, tostring(enabled())))

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
