-- Vehicle boost: the push, the flames and the meter.
--
--   "we need a vehicle boost. [...] while holding SHIFT by default
--    (remappable), and in the driver's seat, the vehicle has flames which come
--    out the back of the tailpipes and is accelerated forward to reach a speed
--    30mph faster than what it was doing when they pressed it."
--                                              -- owner, 2026-08-22, #203
--
-- The arithmetic is in br_lib/shared/boost_solve.lua and the numbers are in
-- br_lib/config/boost.lua. This file is the part that touches the engine, and
-- it is deliberately the only part that does.
--
-- ═══ HOW THE SPEED IS APPLIED, AND WHY IT IS NOT A VELOCITY SET ═══
--
-- Every frame of a boost this asks for the GAP between the speed the ramp wants
-- and the speed the car has, and hands that gap to APPLY_FORCE_TO_ENTITY as an
-- IMPULSE with `bScaleByMass` set. An impulse scaled by mass is a velocity
-- change: pass 0.4 and the car gains 0.4 m/s, whether it is a Blista or a
-- Phantom. So the loop is a closed-loop speed controller whose control input
-- happens to be expressed in m/s.
--
-- THE ALTERNATIVE WAS SET_VEHICLE_FORWARD_SPEED AND IT IS WRONG HERE FOR TWO
-- SEPARATE REASONS, either of which would be enough:
--
--   * IT DOES NOT SURVIVE A COLLISION. A velocity SET is written straight into
--     the entity after the physics step rather than offered to it. A car whose
--     nose is against a wall is set to 40 m/s anyway, every frame, and the
--     penetration solver is asked to undo it -- which is how a boost script ends
--     up posting a car through a fence. An impulse goes in BEFORE the contact
--     solve, so a car pressed into a wall stays pressed into the wall, wheels
--     spinning, exactly as it would with the throttle floored.
--   * IT ZEROES EVERYTHING THAT IS NOT FORWARD. SET_VEHICLE_FORWARD_SPEED
--     replaces the whole velocity vector with forward*speed, which deletes the
--     lateral component (no drifting while boosting) and the vertical one (a
--     boosting car cannot leave a ramp and cannot fall). An impulse ADDS to the
--     existing velocity and leaves the rest of it alone.
--
-- ═══ AND WE ARE DELIBERATELY DOING WHAT EVERY PUBLIC NITRO SCRIPT DOES NOT ═══
--
-- This is worth being explicit about, because the prior art is unanimous the
-- other way. Four independent open implementations were read -- sw-nitro,
-- renzu_nitro, ND_Nitro, malice_nitro -- and all four boost with a POWER OR
-- TORQUE MULTIPLIER (`SET_VEHICLE_CHEAT_POWER_INCREASE`, which is the same
-- native as `_SET_VEHICLE_ENGINE_TORQUE_MULTIPLIER`). None of them applies a
-- force or sets a velocity. Two reasons that consensus does not carry here:
--
--   * A MULTIPLIER CANNOT BE ASKED FOR A SPEED. It scales the engine's input, so
--     where it lands depends on the car's gearing, its drag and the gradient.
--     sw-nitro says so about its own code, in a comment: "The effect of nitro is
--     quite extreme for cars with custom handling, while slow cars have almost
--     no effect from this at all." The spec here names a speed (+30 mph) and a
--     duration (2 s to reach it), and neither is a thing a multiplier can be
--     given.
--   * ENGINE POWER DOES NOT REPLICATE, AND VELOCITY DOES. citizenfx/fivem #2140:
--     an engine upgrade syncs the mod value but "the power of the vehicle will
--     not change for other players." That is why those four scripts all have to
--     broadcast their multiplier and have EVERY client apply it to a car it does
--     not own -- and why "nitro looks laggy for other players" recurs across all
--     of them. An impulse applied by the vehicle's OWNER changes its velocity,
--     which is ordinary networked entity state, so remote clients see the car
--     move correctly for free. The only thing this file has to broadcast is the
--     flames.
--
-- WHAT WE GIVE UP, STATED: `ApplyForceToEntity` is a signature mod-menu native,
-- so third-party anticheats sometimes flag or block it. We run our own server and
-- our own detectors, so that costs us nothing here -- but it is the reason the
-- public scripts have to avoid it and this one does not.
--
-- ═══ HOW THE FLAMES REACH OTHER PLAYERS WITHOUT A NETWORKED ENTITY ═══
--
-- They are not an entity at all. A looped particle effect is a handle into the
-- local particle system -- START_PARTICLE_FX_LOOPED_ON_ENTITY_BONE returns an
-- int, not an Entity -- so it is not created, not owned, not replicated, and
-- `sv_entityLockdown relaxed` has nothing to refuse. There is also a
-- START_NETWORKED_PARTICLE_FX_LOOPED_ON_ENTITY_BONE, and it is exactly what this
-- must not use.
--
-- So the flames travel as a FACT rather than as an object, which is the same
-- bargain the storm, the Battle Bus and the airdrop strike: the server publishes
-- a small record -- this vehicle's network id, and when its boost is due to end
-- in SERVER TIME -- and every client that can see that vehicle draws its own
-- copy locally. Nothing is shared but the record and the clock.
--
-- `endsAt` RIDES THE START MESSAGE SO A LOST STOP CANNOT LEAVE A CAR ON FIRE.
-- The stop message is an EARLY stop -- the player let go -- and if it never
-- arrives the flames still go out on their own deadline, because BR.Clock says
-- so. A flame that never goes out is the one failure here that a player cannot
-- explain and cannot clear.

BR = BR or {}
BR.Boost = {}

local C = BR.Config and BR.Config.Boost

--- A FiveM BOOL is not a Lua boolean.
---
--- A native declared BOOL hands Lua a number on some builds and a boolean on
--- others, and IN LUA `0` IS TRUTHY -- `1 == true` is also false. This project
--- has shipped that bug four times. IsPedInAnyVehicle and DoesEntityExist are
--- both declared BOOL and both are load-bearing here: a `0` read as true would
--- have this file boosting a player stood in a field.
--- @param v any
--- @return boolean
local isTrue = BR.NativeBool

--- Is the boost switched on at all?
--- @return boolean
local function enabled()
    return C ~= nil and C.enabled == true and (tonumber(C.capacityMs) or 0) > 0
end

-- ---------------------------------------------------------------------------
-- The meter
--
-- ═══ PER PLAYER, NOT PER VEHICLE, AND THE REASONING IS THE SPEC'S OWN OPENING
--     WORDS ═══
--
--   "The vehicle boost will be akin to SPRINT ON FOOT"
--
-- Sprint stamina belongs to the player (client/stamina.lua) and follows them
-- between fights. The boost is described the same way -- a key the player holds
-- -- so the meter follows the player between cars.
--
-- FUEL'S PRECEDENT POINTS THE OTHER WAY AND DOES NOT APPLY. Fuel is per vehicle
-- by an explicit owner decision, "a vehicle must not be a permanent advantage",
-- and that argument is about a FOUND RESOURCE: the tank you inherit when you
-- take a car is the previous driver's leavings, and a full one would make a
-- particular car worth hunting. A boost meter cannot be a permanent advantage
-- wherever it is stored, because it refills to full in six seconds for
-- everybody, always, at no cost. The reason does not transfer.
--
-- THE TWO PRACTICAL CONSEQUENCES, BOTH OF WHICH FAVOUR PER PLAYER:
--
--   * per vehicle would reward CAR HOPPING -- step out of a spent car into any
--     other one and the meter is full -- which is a strategy nobody asked for
--     and which reads as a bug;
--   * per player means a driver who gets out and back in keeps what they had
--     left, which is what "akin to sprint on foot" predicts, and the meter keeps
--     ticking on wall clock while they are out of the seat, so nothing has to be
--     saved, swept or expired. Per vehicle would need a second netId-keyed table
--     with its own TTL sweep, which is a copy of server/fuel.lua's machinery for
--     a value that costs nothing to lose.
--
-- ONE PLACE TO CHANGE IT: `budget` below and BR.Boost.meter(). Both would become
-- a table keyed on network id, and nothing else in this file would move.
-- ---------------------------------------------------------------------------

--- Milliseconds of boost banked. Starts full, because a player who has never
--- boosted has not spent anything.
local budget = C and (tonumber(C.capacityMs) or 0.0) or 0.0

--- Is a boost running right now, and what it was told at the press.
local run = {
    on      = false,
    baseMps = 0.0,   -- speed at the instant of the press. FROZEN -- see boost_solve.
    startAt = 0,     -- local timer
    netId   = nil,   -- the vehicle we announced, so the stop names the same one
}

--- Did the last boost end because the meter emptied, with the key still down?
---
--- ═══ A DRY METER NEEDS A FRESH PRESS, AND WITHOUT THIS THE HOLD MACHINE-GUNS
---     ═══
---
--- The meter recharges every frame it is not spending, so a player still holding
--- the key one frame after running dry has about eleven milliseconds banked --
--- enough for `budget > 0` to be true again, which would START A NEW BOOST. The
--- new boost re-samples the base speed and restarts the ramp at zero, so it
--- delivers nothing, and the next frame it is dry again. The result is a held
--- key producing an endless stutter of ramp-restarts and no acceleration at all.
---
--- REQUIRING A RELEASE IS THE FIX THAT ADDS NO NUMBER. client/stamina.lua solves
--- the same shape with `minToSprint`, a threshold an emptied meter must climb
--- back to -- but that is a figure the owner gave for sprint and did not give
--- for this, and "let go and press again" is what a player would predict anyway.
--- It takes nothing away from partial spend: releasing and re-pressing on a
--- part-charged meter spends exactly what is there, which is the spec.
local dry = false

--- Did a gate take a LIVE boost away, with the key still down?
---
--- ═══ A SIBLING OF `dry` AND NOT A SECOND USE OF IT. THE MEASUREMENTS FIRST,
---     BECAUSE THEY ARE WHY IT EXISTS ═══
---
--- The two gates further down are live for the whole boost, so either can stop a
--- boost that is already running: the engine is shot out, or the tank crosses the
--- line mid-burn. Without a latch the key is still down on the very next frame
--- and `want` is true again, so THE PRESS PATH RUNS A SECOND TIME UNDER ONE HOLD
--- -- and the press path re-samples `base` from the speed the car has NOW, which
--- is the speed the interrupted boost had already given it. Driven on the shipped
--- frame callback from 20.0 m/s, against a spec of +30 mph:
---
---     steady burn                     +13.41 m/s   (+30 mph, which is the spec)
---     one 1-frame cut at frame 70     +20.71 m/s   (+46 mph)
---     one 1-frame cut every 40        +25.43 m/s   (+57 mph)
---
--- Nothing bounded it: every interruption raised the ceiling again. The press
--- path's own comment states the rule this breaks, in its own words -- re-reading
--- the base per frame "would make the target chase the car and the boost would
--- have no ceiling at all". A resumed boost is that re-read, once per
--- interruption, and an engine that flickers or a fuel reading riding the 5
--- percent line is enough to ask for it on purpose.
---
--- AND THE SAME FLICKER WAS THE STUTTER `dry`'s OWN NOTE DESCRIBES. Twenty frames
--- of alternation produced 0 impulses -- each restart begins the ramp at zero,
--- asks for nothing on its first frame and is stopped on the next -- while the
--- meter still drained from 100 to 88.4. It sent 10 BOOST_SET on and 10 off in
--- those 20 frames, and the server throttles starts only, so every accepted edge
--- is a broadcast to every other client; locally it started and stopped 170
--- particle effects. "A held key producing an endless stutter of ramp-restarts
--- and no acceleration at all" is the sentence above, and this was it.
---
--- ═══ WHY IT IS NOT SIMPLY `dry` ═══
---
--- Reusing `dry` would fix all of that and would cost the readout the one thing
--- the readout is for. "The meter emptied" and "the car stopped qualifying" are
--- different facts with different answers -- "wait six seconds" against "your
--- engine cut out, or you are sitting on the fuel line" -- and the verdict ladder
--- has a rung for each. One flag for two meanings is a flag that makes
--- /brboostwhy name the wrong cause, which is the wasted playtest round that
--- ladder exists to prevent.
---
--- CLEARED ON THE RELEASE AND ONLY ON THE RELEASE, exactly as `dry` is and for
--- the same reason: "let go and press again" is the fix that adds no number.
local gated = false

-- ---------------------------------------------------------------------------
-- THE TRACE
--
-- ═══ WHY THE READOUT IS BUILT INTO THIS FILE RATHER THAN BESIDE IT ═══
--
--   "Boost does nothing, likely because GTA V's drift mode is taking over which
--    is bound on SHIFT."   "The boost bar does display and is at 100, so that's
--    good at least."                              -- owner, 2026-08-22, #203
--
-- A FULL METER IS THE SYMPTOM, NOT THE RESERVE. The meter only falls on a frame
-- the loop below decides to spend, so "100 and staying there" narrows nothing:
-- it is equally the signature of a key that never arrives, a seat gate that
-- refuses, and a boost that runs perfectly while the impulse does nothing. Three
-- causes, three files, one indistinguishable reading from a chair.
--
-- SO THE DECISIONS ARE COUNTED WHERE THEY ARE MADE. `held`, `driving` and `want`
-- are locals inside the frame callback and nothing outside can re-derive them
-- without writing a second copy of this file's rules -- and a second copy is a
-- second opinion, which is worthless against a bug whose whole nature is that
-- the stages look alike. /brdriveby's own note makes this argument about
-- `seatOf`: the readout borrows the gameplay file's answer, "or it exonerates
-- the bug". Same here.
--
-- NIL ALMOST ALWAYS, WHICH IS WHAT IT COSTS. This is the FRAME band -- every
-- player, every frame, forever -- so the trace is one `if trace then` on each
-- path and nothing else. /brboostwhy hands in a table; everything until then pays a
-- nil check, which is exactly what client/debug.lua's `watch` costs.
-- ---------------------------------------------------------------------------

--- The table /brboostwhy is accumulating into, or nil.
local trace = nil

--- Arm or disarm the trace. Pass a table to collect into, nil to stop.
---
--- THE TABLE IS THE CALLER'S, so client/debug.lua owns the deadline, the
--- keyboard samples it takes alongside these, and the printing. This file only
--- writes down what only this file can see.
--- @param t table|nil
function BR.Boost.trace(t)
    trace = (type(t) == 'table') and t or nil
end

--- Bump one counter on the armed trace. A no-op when nothing is armed.
--- @param k string
--- @param by number|nil  defaults to 1
local function note(k, by)
    if not trace then return end
    trace[k] = (trace[k] or 0) + (by or 1)
end

--- THE LAST THING APPLY_FORCE_TO_ENTITY SAID WHEN IT SAID ANYTHING, KEPT
--- FOREVER AND NOT ONLY WHILE TRACING.
---
--- The call is `pcall(ApplyForceToEntity, ...)` and its result was DISCARDED,
--- which is a hole with exactly the shape of this bug: an unbound native, a
--- signature the build disagrees with, or an argument the engine refuses all
--- fail identically and silently, every frame, for the whole life of the
--- feature. One string, written only on the failing branch, turns "boost does
--- nothing" into a sentence. /brboostinfo prints it.
local forceErr = nil

--- How many times the force call has been made and how many of those returned.
--- Written on every boosting frame and on no other, so an idle client pays
--- nothing; two integers are cheaper than the question they answer.
local forceCalls, forceOk = 0, 0

--- The meter as the HUD wants it, 0..100.
---
--- READ BY client/fuel.lua's pushBars, which owns the vehicle envelope. The bar
--- joins the two that are already in it rather than opening a second channel for
--- one number -- see hud/VehicleBars.tsx.
--- @return number
function BR.Boost.meter()
    if not enabled() then return 100.0 end
    local cap = tonumber(C.capacityMs) or 0.0
    if cap <= 0.0 then return 100.0 end
    return BR.Clamp(budget / cap, 0.0, 1.0) * 100.0
end

--- Is the local player boosting? For the debug overlay and for tests.
--- @return boolean
function BR.Boost.active()
    return run.on == true
end

-- ---------------------------------------------------------------------------
-- The flames
-- ---------------------------------------------------------------------------

--- Vehicles believed to be boosting, by network id.
---
--- [netId] = { endsAt = <server ms>, handles = { ptfx... } or nil }
---
--- `handles` STAYS NIL UNTIL THE VEHICLE RESOLVES, and that is the retry. A
--- network id only resolves to an entity inside this client's scope, which is
--- correct -- a car you cannot see needs no flames -- but a car that drives INTO
--- scope mid-boost would stay dark for the rest of it, because the start message
--- has already been and gone. Re-asking on the TICK band turns a missed edge
--- into a late attach.
local lit = {}

--- Has the particle asset been asked for? Requesting is idempotent but not free.
local asked = false

--- Make sure the particle asset is in memory, and select it.
---
--- ═══ ASKED FOR AT RESOURCE START, NOT ON THE FIRST PRESS ═══
---
--- `veh_xs_vehicle_mods` is NOT resident -- it is Arena War content and has to
--- stream. A boost is four seconds long, so an asset requested on the press and
--- delivered on second three is a boost that had no flames, and the first boost
--- of a player's session is the one they judge the feature by. The request goes
--- out once at start (see the bottom of this file) and this only ever waits.
--- @return boolean ready
local function ptfxReady()
    local asset = C.ptfx and C.ptfx.asset
    if type(asset) ~= 'string' or asset == '' then return false end

    if not asked then
        asked = true
        pcall(RequestNamedPtfxAsset, asset)
    end
    local ok, loaded = pcall(HasNamedPtfxAssetLoaded, asset)
    if not ok or not isTrue(loaded) then return false end

    -- MUST BE RE-SELECTED BEFORE EVERY START. UseParticleFxAsset sets the
    -- dictionary for the NEXT start call only; anything else in the game
    -- starting an effect in between would otherwise have moved it.
    pcall(UseParticleFxAsset, asset)
    return true
end

--- Every exhaust bone index this model actually has.
--- @param veh integer
--- @return table  array of bone indices, possibly empty
local function exhaustBones(veh)
    local out = {}
    local names = C.ptfx and C.ptfx.bones
    if type(names) ~= 'table' then return out end
    for i = 1, #names do
        local ok, idx = pcall(GetEntityBoneIndexByName, veh, names[i])
        idx = ok and math.tointeger(tonumber(idx)) or nil
        -- -1 IS THE ENGINE'S "NO SUCH BONE", and it is the only rejection
        -- needed: bone 0 is a real bone (the chassis root), so a `> 0` test
        -- would silently drop a model whose exhaust is index 0.
        if idx ~= nil and idx >= 0 then out[#out + 1] = idx end
    end
    return out
end

--- Two plumes at the back of the model, for a vehicle with no exhaust bone.
---
--- A GREAT MANY MODELS HAVE NONE, and a boost whose flames appear on some cars
--- and not others reads as broken rather than as plain. The offsets come from
--- the model's own bounding box, so they land at the back of a Bison and the
--- back of a Blista without a per-model table.
--- @param veh integer
--- @return table  array of { x, y, z } local offsets
local function fallbackOffsets(veh)
    local fb = C.ptfx and C.ptfx.fallback
    if type(fb) ~= 'table' then return {} end

    local okm, model = pcall(GetEntityModel, veh)
    if not okm or not model then return {} end
    local okd, lo, hi = pcall(GetModelDimensions, model)
    if not okd or lo == nil or hi == nil then return {} end

    local halfW = (tonumber(hi.x) or 0.0) * (tonumber(fb.side) or 0.0)
    -- The BACK face. GTA's model space puts +y forward, so the rear is min.y.
    local backY = (tonumber(lo.y) or 0.0)
                  - math.abs((tonumber(hi.y) or 0.0) - (tonumber(lo.y) or 0.0))
                    * (tonumber(fb.behind) or 0.0)
    local z = (tonumber(lo.z) or 0.0)
              + ((tonumber(hi.z) or 0.0) - (tonumber(lo.z) or 0.0))
                * (tonumber(fb.lift) or 0.0)

    return {
        { x = -halfW, y = backY, z = z },
        { x =  halfW, y = backY, z = z },
    }
end

--- Light every tailpipe on one vehicle. Local only, and never networked.
--- @param veh integer
--- @return table|nil  array of ptfx handles, nil when nothing could be started
local function light(veh)
    if not ptfxReady() then return nil end

    local effect = C.ptfx and C.ptfx.effect
    if type(effect) ~= 'string' or effect == '' then return nil end
    local scale = tonumber(C.ptfx.scale) or 1.0

    local handles = {}
    local bones = exhaustBones(veh)
    if #bones > 0 then
        for i = 1, #bones do
            -- Re-selected per start; see ptfxReady.
            if not ptfxReady() then break end
            local ok, h = pcall(StartParticleFxLoopedOnEntityBone,
                effect, veh, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, bones[i], scale,
                false, false, false)
            h = ok and math.tointeger(tonumber(h)) or nil
            if h and h ~= 0 then handles[#handles + 1] = h end
        end
    else
        for _, o in ipairs(fallbackOffsets(veh)) do
            if not ptfxReady() then break end
            local ok, h = pcall(StartParticleFxLoopedOnEntity,
                effect, veh, o.x, o.y, o.z, 0.0, 0.0, 0.0, scale,
                false, false, false)
            h = ok and math.tointeger(tonumber(h)) or nil
            if h and h ~= 0 then handles[#handles + 1] = h end
        end
    end

    if #handles == 0 then return nil end
    return handles
end

--- Put one vehicle's flames out.
--- @param handles table|nil
local function douse(handles)
    if type(handles) ~= 'table' then return end
    for i = 1, #handles do
        -- `true` DESTROYS RATHER THAN LETTING IT FINISH. A boost ends the frame
        -- the key comes up, and a plume that lingers for a second afterwards is
        -- a car that looks like it is still boosting when it is not.
        pcall(StopParticleFxLooped, handles[i], true)
    end
end

--- Begin drawing flames for a vehicle, on this machine only.
--- @param netId integer
--- @param endsAt number  server time the boost is due to end
local function flamesOn(netId, endsAt)
    netId = math.tointeger(tonumber(netId))
    if netId == nil or netId == 0 then return end
    local rec = lit[netId]
    if rec then
        -- ALREADY LIT: extend rather than restart. The local player lights their
        -- own car on the press and then hears their own relay come back a round
        -- trip later; restarting there would produce a visible flicker on the
        -- boosting player's screen and nowhere else.
        rec.endsAt = tonumber(endsAt) or rec.endsAt
        return
    end
    lit[netId] = { endsAt = tonumber(endsAt) or 0, handles = nil }
end

--- Stop drawing flames for a vehicle.
--- @param netId integer
local function flamesOff(netId)
    netId = math.tointeger(tonumber(netId))
    if netId == nil then return end
    local rec = lit[netId]
    if not rec then return end
    douse(rec.handles)
    lit[netId] = nil
end

--- Everything alight goes out. Used when the feature is switched off under us
--- and when this resource stops.
local function flamesAllOff()
    for netId in pairs(lit) do flamesOff(netId) end
end

-- ---------------------------------------------------------------------------
-- What the car itself has to be doing
--
-- ═══ TWO GATES, ONE SENTENCE ═══
--
--   "make the vehicle boost only work if the engine is on and fuel is >=5%"
--                                              -- owner, 2026-09-21
--
-- Both are read here and consumed by one clause of `want` in the frame callback
-- below, which is what makes them live for the whole boost rather than only at
-- the press. Neither of them does anything to the car: the refusal is the
-- absence of a push, exactly as a released key is.
-- ---------------------------------------------------------------------------

--- Is this vehicle's engine actually running?
---
--- ═══ A COASTING CAR MUST NOT BOOST ═══
---
--- IS_VEHICLE_ENGINE_ON IS DECLARED BOOL, and in this project that is a sentence
--- with a history rather than a footnote: a native declared BOOL answers `1` on
--- some builds and `true` on others, `0` is truthy in Lua, and this repository
--- has shipped that confusion seven times. The answer goes through BR.NativeBool
--- like every other BOOL read in this file, so a build that says `0` for a dead
--- engine REFUSES the boost instead of allowing it. The pair is already here:
--- four files call SetVehicleEngineOn, and client/fuel.lua's own ignition block
--- is the one that turns an engine back on after a refuel.
---
--- A BUILD THAT CANNOT ANSWER GETS THE BOOST, NOT A DEAD FEATURE. An unbound
--- native, a raise, or a nil would otherwise refuse every boost on that client
--- for ever, with precisely the "boost does nothing, meter stays at 100" symptom
--- the ladder at the bottom of this file exists to take apart. `engineUnreadable`
--- is what stops that being silent: a gate nobody is enforcing is a fact about
--- the build, and the readout says it rather than leaving it to be deduced.
--- @param veh integer
--- @return boolean
local function engineRunning(veh)
    if IsVehicleEngineOn == nil then
        note('engineUnreadable')
        return true
    end
    local ok, on = pcall(IsVehicleEngineOn, veh)
    if not ok or on == nil then
        note('engineUnreadable')
        return true
    end
    return isTrue(on)
end

--- Is this a class of vehicle that HAS an engine for the gate above to be about?
---
--- ═══ A BICYCLE HAS NO ENGINE, AND THE GATE MUST NOT ASK ABOUT ONE ═══
---
--- BR.Config.Boost.excludeClasses holds 15 and 16 only, so class 13 -- CYCLES,
--- every bicycle in the game -- reaches the gates today, and is meant to: the
--- owner said "the vehicle", boats are deliberately in, and shift does nothing on
--- a BMX. But there is no ignition on a BMX either.
---
--- WRITTEN AGAINST AN UNCONFIRMED NATIVE ANSWER, AND THE CARVE-OUT IS PRECISELY
--- WHAT MAKES THAT HARMLESS. If IS_VEHICLE_ENGINE_ON answers nil or raises for a
--- cycle then engineRunning()'s fail-open path already covers it and this changes
--- nothing. If it answers a plain `false` then the fail-open path does NOT apply,
--- and every bicycle on the server would silently lose the boost while
--- /brboostwhy told the player to start the engine on a bicycle. Nothing in this
--- tree can settle which it is -- a real answer needs the game, and the suite
--- stubs GetVehicleClass -- so the gate is simply not applied to a class that has
--- no engine, and the question stops mattering either way. That is the difference
--- between an uncertainty and a class of vehicle quietly losing a feature.
---
--- THE FUEL GATE IS DELIBERATELY UNTOUCHED. It reads the same percentage the
--- vitals bar draws, whatever client/fuel.lua models for a cycle, so the gate and
--- the gauge agree about a bicycle exactly as they agree about a Bison.
--- @param veh integer
--- @return boolean
local function hasEngine(veh)
    local none = C.enginelessClasses
    if type(none) ~= 'table' then return true end
    local ok, class = pcall(GetVehicleClass, veh)
    if not ok then return true end
    class = math.tointeger(tonumber(class))
    if class == nil then return true end
    return none[class] ~= true
end

--- Is there at least `minPct` of a tank left, on the gauge the driver reads?
---
--- ═══ THE NUMBER ON THE BAR, AND DELIBERATELY NOT A SECOND OPINION ═══
---
--- BR.Fuel.levelPct IS THE VITALS BAR'S OWN VALUE. client/fuel.lua holds the
--- server's fraction for this vehicle's network id, exports it through that one
--- function, and draws the fuel bar by rounding the very same expression -- so
--- there is one fuel number on this client and both the gauge and this gate are
--- reading it. GetVehicleFuelLevel was the obvious reach and it is the wrong
--- number twice over: it is LITRES of a per-model tank rather than a fraction of
--- one, and it holds whatever fuel.lua's gauge pass last wrote plus whatever the
--- engine has burned since. A boost that refused while the bar read 40% would be
--- a worse bug than the one this gate closes.
---
--- AN UNANSWERED TANK READS FULL rather than empty, and that rule is fuel.lua's
--- rather than ours: between sitting down and the server's answer arriving there
--- is no number at all, and a boost that refused for a tenth of a second every
--- time somebody got into a car would be reported as the boost being broken. The
--- boost inherits it for free by asking that file instead of the engine.
---
--- NIL IS NOT EMPTY, SO NIL PASSES. It means no tank is being modelled for this
--- vehicle -- the fuel feature is switched off, or the vehicle is not networked,
--- which is the Battle Bus and the one case this file already documents as
--- "gets the push and no flames". Refusing there would turn a feature switch
--- into a boost that mysteriously does nothing, which is the whole class of bug
--- #203 was. Counted, for the same reason `engineUnreadable` is.
--- @param veh integer
--- @param minPct number
--- @return boolean
local function fuelAbove(veh, minPct)
    local read = BR.Fuel and BR.Fuel.levelPct
    if type(read) ~= 'function' then
        note('fuelUnknown')
        return true
    end
    local ok, pct = pcall(read, veh)
    -- A READING OF ZERO HAS TO SURVIVE THIS LINE, and it does only because `0` is
    -- truthy in Lua -- `0.0 or nil` is 0.0. That is the one place in this project
    -- where the trap works in our favour, and it is written down because the
    -- obvious tidy-up of an `and`/`or` chain is what would turn an empty tank
    -- into "no reading, so full" and let a dry car boost.
    pct = ok and tonumber(pct) or nil
    -- `pct ~= pct` IS THE NaN TEST, and it is the only one Lua has.
    if pct == nil or pct ~= pct then
        note('fuelUnknown')
        return true
    end
    -- THE LOWEST READING OF THE WINDOW, WHICH IS THE ONE THE VERDICT WANTS. A
    -- boost refused at 3% and then taken at 60% after a fill is two facts, and
    -- the refusal is the one somebody ran /brboostwhy to understand.
    if trace and (trace.fuelPctMin == nil or pct < trace.fuelPctMin) then
        trace.fuelPctMin = pct
    end
    return pct >= minPct
end

-- ---------------------------------------------------------------------------
-- The push
-- ---------------------------------------------------------------------------

--- Forward speed in m/s, signed, or nil when it cannot be read.
---
--- GET_ENTITY_SPEED_VECTOR in RELATIVE mode gives velocity in the entity's own
--- frame, where `y` is forward -- which is the component the boost is about. A
--- car sliding sideways at 20 m/s is not doing 20 m/s forward, and charging the
--- controller for speed it does not have in the direction it is pushing would
--- make the boost refuse to fire on exactly the frames it is most wanted.
---
--- GET_ENTITY_SPEED IS THE FALLBACK and is an unsigned magnitude, so it
--- overstates forward speed in a slide and reads a reversing car as going fast
--- forwards. It is here because a build without the vector native must still
--- boost, and being approximately right beats not working.
---
--- THE SECOND RETURN IS THE SIDEWAYS COMPONENT, AND ONLY THE TRACE READS IT. A
--- car's lateral speed in its own frame is how sideways it is travelling, which
--- is the number a drift IS -- see push(). It is nil on the scalar fallback,
--- because an unsigned magnitude has no direction to decompose.
--- @param veh integer
--- @return number|nil  forward m/s, signed
--- @return number|nil  lateral m/s, signed, when the vector native answered
local function forwardMps(veh)
    if GetEntitySpeedVector then
        local ok, v = pcall(GetEntitySpeedVector, veh, true)
        if ok and v ~= nil then
            local y = tonumber(v.y)
            if y ~= nil and y == y then return y, tonumber(v.x) end
        end
    end
    local ok, s = pcall(GetEntitySpeed, veh)
    if ok then
        local n = tonumber(s)
        if n ~= nil and n == n then return n end
    end
    return nil
end

--- One frame of push.
---
--- ═══ THE ONLY THING THAT HAPPENS TO THE CAR, AND IT ONLY EVER ADDS ═══
---
--- `dv` is clamped at zero from below, so this function can never take speed
--- away. That is not a tidy-up, it is the spec: "Upon releasing or running out
--- of boost, no action against the vehicle should be taken to slow it down or
--- anything." A car already going faster than the ramp asks for -- downhill, or
--- rammed by a squadmate -- is simply not pushed on that frame. It is never
--- pulled back to the target.
---
--- @param veh integer
--- @param dtMs number
local function push(veh, dtMs)
    note('pushFrames')
    local have, lateral = forwardMps(veh)
    if have == nil then
        -- NEITHER SPEED NATIVE ANSWERED. The caller latches `dry` on the press
        -- for this, but a build that answers on the press and stops answering
        -- mid-boost would spend the meter and never push, which is
        -- indistinguishable from an inert impulse without this row.
        note('noSpeed')
        return
    end
    if trace then
        if trace.speedMin == nil or have < trace.speedMin then trace.speedMin = have end
        if trace.speedMax == nil or have > trace.speedMax then trace.speedMax = have end
        -- ═══ THE ONE NUMBER THE SPEC IS WRITTEN IN ═══
        --
        -- "30mph faster than what it was doing when they pressed it". `baseMps`
        -- IS what it was doing when they pressed it, frozen, so this is the
        -- feature's own contract measured in the feature's own terms -- and it
        -- is what settles whether the impulse does anything at all. A boost
        -- whose best gain is a fraction of a m/s over four seconds of pushing is
        -- APPLY_FORCE_TO_ENTITY declining, which no count of frames can show.
        local gain = have - run.baseMps
        if trace.gain == nil or gain > trace.gain then trace.gain = gain end

        -- ═══ HOW SIDEWAYS THE CAR WENT WHILE WE WERE PUSHING IT ═══
        --
        -- The owner's second report is "still getting drift mode at the same
        -- time", and nothing in this project could measure that claim. The
        -- controls research says no drift INPUT exists on this build -- the Cfx
        -- table runs 0..359 and no name in it contains DRIFT -- so the suspect
        -- with no alibi is this file: `maxAccelMps2` is about 1.4 g applied to
        -- the rigid body as an impulse, which never passes through the tyres and
        -- so never spends any of their grip. A car handed speed its tyre model
        -- did not authorise slides, and a slide is lateral velocity.
        --
        -- SO THE NUMBER IS RECORDED RATHER THAN THE THEORY BEING ARGUED. A boost
        -- whose slipMax stays near zero exonerates the impulse and sends the next
        -- round back to the controls; one that climbs with the ramp convicts it.
        -- Peak rather than mean, because a drift is an excursion.
        if lateral ~= nil and lateral == lateral then
            local a = lateral < 0.0 and -lateral or lateral
            if trace.slipMax == nil or a > trace.slipMax then trace.slipMax = a end
        end
    end

    local want = BR.BoostSolve.target(
        run.baseMps, C.addMps, GetGameTimer() - run.startAt, C.rampMs)

    local dv = want - have
    if dv <= 0.0 then
        -- ALREADY FASTER THAN THE RAMP ASKS FOR, which is not a failure -- see
        -- the note above this function. Counted so a readout can tell "the loop
        -- declined to push" from "the loop pushed and nothing happened".
        note('alreadyAhead')
        return
    end

    -- THE CEILING IS WHAT STOPS A CRASH BECOMING A CATAPULT. Without it, a car
    -- that hit a wall at 40 m/s would be handed the whole 40 back as one frame's
    -- impulse. See BR.Config.Boost.maxAccelMps2 for where the number comes from.
    local cap = (tonumber(C.maxAccelMps2) or 0.0) * (math.max(dtMs, 0.0) / 1000.0)
    if cap <= 0.0 then return end
    if dv > cap then dv = cap end

    -- APPLY_FORCE_TO_ENTITY(entity, forceType, x, y, z, offX, offY, offZ,
    --                       nComponent, bLocalForce, bLocalOffset,
    --                       bScaleByMass, bPlayAudio, bScaleByTimeWarp)
    --
    --   forceType 1        APPLY_TYPE_IMPULSE
    --   y = dv             +y is FORWARD in an entity's own frame
    --   bLocalForce true   so that is what +y means here
    --   bScaleByMass true  the impulse is multiplied by the vehicle's mass, so
    --                      `dv` is a velocity change in m/s and a Phantom
    --                      accelerates exactly like a Blista. This is the flag
    --                      that makes the controller's units m/s at all.
    --   bPlayAudio false   it plays a suspension squeal sized by the force, once
    --                      per call, and this is called every frame.
    --
    -- THE RESULT IS READ NOW. It was discarded, and a discarded pcall over a
    -- native is the one construction that can fail on every frame of every boost
    -- for the whole life of a feature and say nothing at all -- an unbound
    -- native, a signature this build disagrees with, or an argument it refuses
    -- are all the same silence. See `forceErr`.
    forceCalls = forceCalls + 1
    local ok, err = pcall(ApplyForceToEntity, veh, 1,
        0.0, dv, 0.0,
        0.0, 0.0, 0.0,
        0, true, true, true, false, true)
    if ok then
        forceOk = forceOk + 1
        note('forced')
        note('dvAsked', dv)
    else
        -- FIRST ONE KEPT, NOT THE LATEST. They are all the same message at 60 Hz
        -- and the first is the one from before anything else went wrong.
        if forceErr == nil then forceErr = tostring(err) end
        note('forceThrew')
    end
end

-- ---------------------------------------------------------------------------
-- The loop
-- ---------------------------------------------------------------------------

--- End the running boost. NOTHING IS DONE TO THE CAR.
---
--- There is no braking here, no damping, no restoring of the speed the car had
--- before, and there must never be one. The car simply stops being pushed and
--- coasts as physics dictates -- the owner said so in as many words, and it is
--- the clause most likely to be "fixed" by somebody tidying up.
---
--- @param announce boolean  tell the server, so other screens stop drawing flames
local function stop(announce)
    if not run.on then return end
    run.on = false
    local netId = run.netId
    run.netId = nil

    if netId then flamesOff(netId) end
    if announce and netId then
        TriggerServerEvent(BR.Net.BOOST_SET, { on = false, netId = netId })
    end
end

BR.Loop.register(BR.Loop.FRAME, 'boost.drive', function(dtMs)
    note('frames')
    if not enabled() then
        note('offFrames')
        if run.on then stop(true) end
        return
    end

    local held = BR.Keys.isHeld('boost')
    -- THE KEY LAYER'S OWN CONCLUSION, COUNTED BEFORE ANYTHING ACTS ON IT. This
    -- is the row that separates "the keyboard never reached us" from every other
    -- cause: /brboostwhy samples the raw natives itself alongside this, so the two
    -- disagreeing names the fault as keybinds.lua's rather than this file's.
    if held then note('heldFrames') end
    -- BOTH LATCHES CLEAR ON THE RELEASE AND ONLY ON THE RELEASE. See `dry` and
    -- `gated`. They are cleared together and on the same frame because they are
    -- the same bargain -- a fresh boost needs a fresh press -- and kept apart
    -- because the readout has to say which of the two happened.
    if not held then dry, gated = false, false end

    -- ═══ THE IDLE PATH IS TWO LOCALS AND A SUBTRACTION, AND THIS BAND IS WHY ═══
    --
    -- This is the FRAME band, which is client/main.lua's "performance contract of
    -- the project": it runs for every player on every frame, whether or not they
    -- have ever seen a car. Almost all of that time the key is up and no boost is
    -- running, so the vehicle questions below -- four natives, two of them
    -- pcalled -- are asked only when one of those two things is true.
    --
    -- THE METER STILL ADVANCES ON THIS PATH, and it has to: it is the PLAYER's
    -- meter (see the note above `budget`), so it recharges on wall clock while
    -- they are on foot, in the lobby, dead or spectating. Nothing has to be reset
    -- when a match ends -- six seconds after the last boost it is full again,
    -- wherever they are and whatever the match is doing.
    if not held and not run.on then
        budget = BR.BoostSolve.step(
            budget, dtMs, false, C.capacityMs, C.rechargeMs)
        return
    end

    local now = GetGameTimer()
    local ped = PlayerPedId()

    -- ═══ DRIVER'S SEAT ONLY, AND EVERY WAY OF LEAVING IT PASSES THROUGH HERE
    --     ═══
    --
    -- Getting out, being pulled out, the car exploding under them, dying in it,
    -- being teleported out, and the match ending and sweeping them to the lobby
    -- are the same fact from this line's point of view: they are not the driver
    -- of a vehicle. So the boost ends in one place rather than each transition
    -- needing to be enumerated and one of them being forgotten -- which is the
    -- shape client/fuel.lua's own exit note argues for.
    local veh = 0
    if isTrue(IsPedInAnyVehicle(ped, false)) then
        veh = GetVehiclePedIsIn(ped, false) or 0
    end
    local driving = false
    if veh ~= 0 then
        note('inVehFrames')
        local ok, driver = pcall(GetPedInVehicleSeat, veh, -1)
        driving = ok and driver == ped
        if driving then note('driverFrames') end
        -- AIRCRAFT ARE OUT BECAUSE THE KEY IS ALREADY THEIRS. Left shift is
        -- INPUT_VEH_FLY_BOOST (352) and INPUT_VEH_MOVE_UP_ONLY (61), and
        -- RegisterKeyMapping cannot take a control away from the engine -- so a
        -- boost in a helicopter would climb it and shove it at once. The list
        -- and the full argument are in BR.Config.Boost.excludeClasses.
        if driving and type(C.excludeClasses) == 'table' then
            local okc, class = pcall(GetVehicleClass, veh)
            if trace and okc then trace.class = math.tointeger(tonumber(class)) end
            if okc and C.excludeClasses[math.tointeger(tonumber(class)) or -1] then
                driving = false
                note('excludedFrames')
            end
        end
    end

    -- ═══ THE REST OF WHAT THE KEY DOES, HELD DOWN ═══
    --
    --   "Vehicle boost does work now, but still getting drift mode at the same
    --    time. Sick affect, but not intended or acceptable really."
    --                                              -- owner, 2026-08-22
    --
    -- RegisterKeyMapping does not take a key away from the engine -- FiveM
    -- bypasses the game's conflict resolver for custom bindings on purpose, so
    -- both fire -- and eight stock controls default to LSHIFT. Two of them can
    -- act on a ground vehicle. Those two are held down here, and the list, the
    -- reason each is on it and the reason the other six are not are in
    -- BR.Config.Boost.suppressControls.
    --
    -- ═══ THE SCOPE IS THE POINT, AND #200 IS WHY ═══
    --
    -- An unconditional per-frame suppression in client/inventory.lua ate the
    -- radio wheel for months, because the melee controls it disabled share Q
    -- with INPUT_VEH_RADIO_WHEEL. Every clause below narrows this one to the
    -- exact circumstance the owner is describing:
    --
    --   `driving`  is already IN A VEHICLE, in the DRIVER's seat, and NOT an
    --              excluded class -- computed above, so this cannot drift out of
    --              agreement with the gate the boost itself uses. A passenger
    --              keeps their controls, and a helicopter pilot keeps 61 and 352,
    --              which is the whole reason aircraft are excluded rather than
    --              suppressed.
    --   `held`     only while the boost key is actually down. Let go and the
    --              engine has all of it back on the very next frame, because a
    --              disable lasts exactly one frame.
    --
    -- NOT GATED ON `want`, AND THAT IS DELIBERATE RATHER THAN AN OVERSIGHT. A
    -- player holding the key on a dry meter is still holding the key, and GTA
    -- does not consult our meter before pitching their car. Gating on the boost
    -- actually running would hand the collision back for exactly the six seconds
    -- a player is most likely to still be leaning on the key.
    if driving and held and type(C.suppressControls) == 'table' then
        local sc = C.suppressControls
        for i = 1, #sc do DisableControlAction(0, sc[i], true) end
    end

    -- ═══ THE TANK AND THE ENGINE, ASKED EVERY FRAME AND NOT ONCE AT THE PRESS
    --     ═══
    --
    --   "make the vehicle boost only work if the engine is on and fuel is >=5%"
    --                                              -- owner, 2026-09-21
    --
    -- A RUNNING BOOST STOPS THE MOMENT EITHER GOES FALSE, and that is the
    -- decision this block is mostly about, because both of them can: the engine
    -- is shot out under #213's destructible cars, or the tank crosses the line
    -- mid-burn. They feed `want`, which is re-derived every frame, so such a
    -- boost ends through the same stop() a released key goes through -- flames
    -- out, the stop announced so other screens agree, the meter no longer
    -- charged, and nothing whatsoever done to the car.
    --
    -- "FINISH THE BURN YOU STARTED" WAS THE ALTERNATIVE AND IT IS WRONG HERE FOR
    -- TWO SEPARATE REASONS. Every other clause in this chain is already live --
    -- the seat, the class, the key, the meter -- so a pair of gates that only
    -- applied at the press would be the only ones a driver could get behind and
    -- stay behind, which is the kind of asymmetry that gets rediscovered as a
    -- bug. And the visible half is worse than the arithmetic half: flames out of
    -- the tailpipes of an engine that is off does not read as "a boost finishing
    -- its burn", it reads as a separate bug about flames.
    --
    -- THE TANK IS ASKED BEFORE THE ENGINE, AND THE ORDER IS LOAD-BEARING. A dry
    -- tank STALLS the car -- fuel.lua writes a zero level and GTA's own fuel
    -- system cuts the engine, which is that file's whole reason for existing --
    -- so an empty car fails both gates at once. Asking the tank first is what
    -- lets the ladder below tell a player to find a station instead of telling
    -- them to start an engine that cannot start.
    --
    -- ONLY WHEN WE ARE ALREADY DRIVING SOMETHING THAT MAY BOOST, so the idle path
    -- above pays nothing and a car we have already refused is not asked two more
    -- questions about.
    --
    -- AND THE SUPPRESSION ABOVE IS DELIBERATELY NOT NARROWED BY EITHER OF THEM.
    -- A player holding the key in a car with a dead engine is still holding the
    -- key, and GTA does not consult our gates before pitching their car -- which
    -- is the argument BR.Config.Boost.suppressControls already makes about
    -- `want` itself.
    --
    -- AND THE ENGINE HALF IS NOT ASKED OF A VEHICLE THAT HAS NO ENGINE. Class 13
    -- is CYCLES and a bicycle has no ignition; see hasEngine(). The fuel half is
    -- asked of everything, because it reads the bar rather than the engine.
    local fuelOk, engineOn = true, true
    if driving then
        fuelOk = fuelAbove(veh, tonumber(C.minFuelPct) or 0.0)
        if not fuelOk then note('lowFuelFrames') end
        if hasEngine(veh) then
            engineOn = engineRunning(veh)
            if not engineOn then note('engineOffFrames') end
        else
            note('enginelessFrames')
        end
    end

    local want = driving and held and fuelOk and engineOn
                 and not dry and not gated and budget > 0.0
    if trace then
        if want then note('wantFrames') end
        -- THE THREE REFUSALS THAT ARE NOT THE SEAT, SEPARATED. A held key in the
        -- driver's seat that still does not boost is a latched dry meter, an
        -- empty one, or a gate that took a live boost away -- and all three want
        -- different answers: "let go and press again", "wait six seconds", and
        -- "your engine cut out or you are on the fuel line, so let go and press
        -- again". Two of them share the answer and none of them share the cause,
        -- which is why `gated` is its own flag rather than a second use of `dry`.
        if driving and held and dry then note('dryFrames') end
        if driving and held and not dry and budget <= 0.0 then note('emptyFrames') end
        if driving and held and gated then note('gatedFrames') end
    end
    budget = BR.BoostSolve.step(
        budget, dtMs, want == true, C.capacityMs, C.rechargeMs)

    if not want then
        if run.on then
            -- ═══ A GATE THAT STOPS A LIVE BOOST LATCHES. See `gated` ═══
            --
            -- ONLY UNDER A HELD KEY, and the asymmetry is the whole point: a
            -- release is the player's own stop and clears both latches on the
            -- next frame anyway, so latching there would be a boost that needed
            -- two presses. A key that is still down is the case where the press
            -- path would otherwise run a second time and re-sample the base
            -- speed off the boost it is replacing.
            --
            -- EVERY REASON `want` CAN GO FALSE UNDER A HELD KEY IS THE SAME FACT
            -- HERE, which is why this is not a list of the two gates: the tank,
            -- the engine, stepping out of the seat and a class that stopped
            -- qualifying all mean the car stopped being one this may push, and
            -- all of them recover under the same hold. The meter running out is
            -- NOT one of them -- that path is below, and it sets `dry`.
            if held then
                gated = true
                note('gateStops')
            end
            stop(true)
        end
        return
    end

    if not run.on then
        -- ═══ THE PRESS: SAMPLE THE BASE SPEED ONCE ═══
        --
        -- "30mph faster than what it was doing WHEN THEY PRESSED IT". Read here
        -- and frozen for the whole boost. Re-reading it per frame would make the
        -- target chase the car and the boost would have no ceiling at all.
        local base = forwardMps(veh)
        if base == nil then
            -- A BUILD WHERE NEITHER SPEED NATIVE ANSWERS CANNOT BOOST AT ALL, and
            -- the meter must not quietly drain while it tries. `step` above has
            -- already charged this frame; latching `dry` means the next frame
            -- recharges instead of spending another, so a player holding the key
            -- on such a client loses one frame of meter rather than all of it.
            -- The release clears the latch, exactly as running dry does.
            dry = true
            return
        end
        if base < 0.0 then base = 0.0 end

        run.on, run.baseMps, run.startAt = true, base, now
        run.netId = nil

        local okn, nid = pcall(NetworkGetNetworkIdFromEntity, veh)
        nid = okn and math.tointeger(tonumber(nid)) or nil
        -- ZERO IS EXPLICIT, and `0` is truthy in Lua. It is what the engine
        -- answers for a vehicle that is not networked -- the Battle Bus, #191's
        -- rescue ambulance -- and asking the server to relay flames for one would
        -- name a vehicle no other client has ever heard of.
        --
        -- SUCH A VEHICLE GETS THE PUSH AND NO FLAMES, which is a case nobody can
        -- currently reach: `lit` is keyed on network id because that is the only
        -- name every machine agrees on, and the two non-networked vehicles in
        -- this game are ones no player is ever the driver of. Written down rather
        -- than guarded, because the day a driveable client-side vehicle exists
        -- this is the line that explains why it has no flames.
        if nid ~= nil and nid ~= 0 then
            run.netId = nid
            -- `budget` HAS ALREADY BEEN CHARGED FOR THIS FRAME, so what is left
            -- in it is exactly how much longer this boost can run. Published as
            -- a SERVER timestamp so every client can put the flames out on its
            -- own without a second message -- the same clock bargain the storm
            -- and the bus route are built on.
            local endsAt = BR.Clock.now() + budget
            TriggerServerEvent(BR.Net.BOOST_SET,
                { on = true, netId = nid, endsAt = endsAt })
            flamesOn(nid, endsAt)
        end
    end

    push(veh, dtMs)

    -- RAN DRY. This is "running out of boost", and what it does to the car is
    -- nothing at all -- see stop(). The latch is what stops the next frame's
    -- eleven milliseconds of recharge starting a fresh boost under a key that
    -- was never released; see `dry`.
    if budget <= 0.0 then
        dry = true
        stop(true)
    end
end)

--- Attach flames that could not be attached when the message arrived, and put
--- out flames whose deadline has passed.
BR.Loop.register(BR.Loop.TICK, 'boost.flames', function()
    if not enabled() then
        if next(lit) then flamesAllOff() end
        return
    end
    if not next(lit) then return end

    local now = BR.Clock.now()
    for netId, rec in pairs(lit) do
        -- ═══ THE DEADLINE IS THE BACKSTOP, NOT THE MECHANISM ═══
        --
        -- An ordinary boost ends with a stop message. This is what happens when
        -- that message is lost, or when the booster disconnects mid-boost: the
        -- flames go out on the clock the start message already carried, because
        -- a car on fire forever is the one failure a player cannot explain.
        if rec.endsAt > 0 and now >= rec.endsAt then
            flamesOff(netId)
        elseif rec.handles == nil then
            local ok, ent = pcall(NetworkGetEntityFromNetworkId, netId)
            ent = ok and ent or 0
            -- OUT OF SCOPE IS NOT A FAILURE. A vehicle this client cannot see
            -- needs no flames; the retry is here for the one that drives into
            -- scope while it is still boosting.
            if ent and ent ~= 0 and isTrue(DoesEntityExist(ent)) then
                rec.handles = light(ent)
            end
        end
    end
end)

-- ---------------------------------------------------------------------------
-- The wire
-- ---------------------------------------------------------------------------

RegisterNetEvent(BR.Net.BOOST_SYNC)
AddEventHandler(BR.Net.BOOST_SYNC, function(d)
    if not enabled() then return end
    if type(d) ~= 'table' then return end
    local netId = math.tointeger(tonumber(d.netId))
    if netId == nil or netId == 0 then return end

    if d.on == true then
        flamesOn(netId, tonumber(d.endsAt) or 0)
    else
        flamesOff(netId)
    end
end)

AddEventHandler('onClientResourceStart', function(res)
    if res ~= GetCurrentResourceName() then return end
    if not enabled() then return end
    -- ASK FOR THE PARTICLE ASSET NOW, so the first boost of the session is not
    -- the one that streams it. See ptfxReady.
    ptfxReady()
end)

AddEventHandler('onClientResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    -- A LOOPED PTFX OUTLIVES THE RESOURCE THAT STARTED IT. Restarting br_core
    -- with a car alight would leave a flame nothing has a handle to any more.
    flamesAllOff()
end)

-- ---------------------------------------------------------------------------
-- THE VERDICT
-- ---------------------------------------------------------------------------

--- The state only this file can see, for /brboostwhy's report.
---
--- Separate from the trace table because these are not counted over a window --
--- they are true right now, and two of them (`forceErr`, `forceOk`) are true
--- from before the window opened, which is the point of keeping them at all.
--- @return table
function BR.Boost.facts()
    return {
        enabled    = enabled(),
        budgetMs   = budget,
        capacityMs = C and tonumber(C.capacityMs) or 0.0,
        addMps     = C and tonumber(C.addMps) or 0.0,
        rampMs     = C and tonumber(C.rampMs) or 0.0,
        -- THE THRESHOLD, SO THE FUEL RUNG CAN QUOTE IT RATHER THAN RESTATE IT.
        -- A verdict that said "below 5%" while the config had been moved to 10
        -- would send the next round looking in the wrong place.
        minFuelPct = C and tonumber(C.minFuelPct) or 0.0,
        running    = run.on == true,
        dryLatch   = dry == true,
        -- TRUE RIGHT NOW RATHER THAN OVER THE WINDOW, which is what makes it the
        -- guard on the gate rung: a driver who stalled, let go and then boosted
        -- properly has a `gateStops` count and no latch, and must not be told the
        -- stall was the answer. A driver who is still stuck has both.
        gateLatch  = gated == true,
        forceCalls = forceCalls,
        forceOk    = forceOk,
        forceErr   = forceErr,
    }
end

--- ═══ WHICH STAGE FAILED, AS ONE WORD AND ONE SENTENCE ═══
---
--- PURE, AND IT IS THE WHOLE REASON /brboostwhy IS NOT SIX PRINT STATEMENTS. #203
--- has three candidate causes -- a key that never arrives, a seat gate that
--- refuses, and an impulse that does nothing -- and from the driver's seat all
--- three are "boost does nothing, meter stays at 100". Each wants a fix in a
--- different file. A readout that prints numbers and leaves the reading to the
--- person holding the controller is a readout that costs another playtest round
--- when the numbers are misread, which is exactly what BR.Inv.driveByVerdict
--- exists to prevent for #197.
---
--- THE LADDER IS ORDERED BY THE CHAIN, NOT BY LIKELIHOOD. Each rung assumes
--- every rung above it passed, so the first one that fails is the one to fix and
--- everything below it is unmeasured rather than fine. Reordering it would let a
--- late symptom name itself as the cause -- "the impulse did nothing" is
--- trivially true on a boost that never started.
---
--- @param f table  the trace table, with BR.Boost.facts() merged in
--- @return string code
--- @return string sentence
function BR.Boost.verdict(f)
    f = type(f) == 'table' and f or {}
    --- Counters are absent rather than zero when nothing incremented them.
    local function n(k) return tonumber(f[k]) or 0 end

    if f.enabled ~= true then
        return 'disabled',
            'BR.Config.Boost.enabled is off, or capacityMs is zero. Nothing was '
            .. 'ever going to happen; there is no bug here to find.'
    end
    if n('frames') == 0 then
        return 'no-frames',
            'The boost.drive frame callback did not run once. That is the loop, '
            .. 'not the boost -- see /brperf and /brloop.'
    end

    -- ── RUNG 1: DID THE KEY REACH US? ──────────────────────────────────────
    if n('heldFrames') == 0 then
        if n('rawSelf') > 0 then
            return 'key-not-routed',
                ('The virtual-key code the boost watches (0x%02X) read DOWN on %d '
                .. 'frames, and BR.Keys.isHeld("boost") was never true. The key '
                .. 'arrived and the key layer did not deliver it -- the fault is '
                .. 'in br_core/client/keybinds.lua. Check `holds` and `ui input` '
                .. 'in /brkeys.'):format(tonumber(f.rawSelfCode) or 0, n('rawSelf'))
        end
        if n('rawBestFrames') > 0 then
            return 'key-wrong-code',
                ('The boost watches 0x%02X and that code never read down, but '
                .. '0x%02X read down on %d frames. We are asking the raw layer '
                .. 'about the wrong virtual-key code -- the fix is DEFAULT_VK in '
                .. 'br_core/client/keybinds.lua, not the boost.')
                :format(tonumber(f.rawSelfCode) or 0,
                        tonumber(f.rawBestCode) or 0, n('rawBestFrames'))
        end
        if n('engineFrames') > 0 then
            return 'key-engine-only',
                ('No raw-key code reported the key at all, and GTA\'s own controls '
                .. 'on it fired on %d frames. The game can see the key and '
                .. 'IsRawKeyDown cannot, so the raw layer is the wrong reader for '
                .. 'this key. Drive the hold from the RegisterKeyMapping +/- pair '
                .. 'instead, or read the key by control.'):format(n('engineFrames'))
        end
        return 'key-unseen',
            'Nothing saw the key: not the raw layer, not GTA\'s own controls on '
            .. 'it, not the key layer. Either it was not held for the window, or '
            .. 'the game did not have keyboard focus. Run it again and hold the '
            .. 'key for the whole countdown before blaming the code.'
    end

    -- ── RUNG 2: WERE WE DRIVING SOMETHING THAT MAY BOOST? ─────────────────
    --
    -- THE CLASS GATE IS ASKED BEFORE THE SEAT, AND IT HAS TO BE. `driverFrames`
    -- counts the seat and nothing else -- the exclusion is applied afterwards, so
    -- a player at the controls of a helicopter has a non-zero seat count and
    -- would sail past a rung that only asked about the seat. It did: a plane
    -- reached the meter rung and came out as `no-want`, which is the ladder's own word
    -- for "this should not be possible" and would have sent the next round
    -- looking for a bug that was not there.
    --
    -- GUARDED ON `wantFrames`, so a player who sat in a helicopter for a moment
    -- and then boosted a car properly is not told the helicopter was the answer.
    if n('excludedFrames') > 0 and n('wantFrames') == 0 then
        return 'excluded-class',
            ('The key was seen, and the vehicle is class %s, which is in '
            .. 'BR.Config.Boost.excludeClasses -- aircraft are excluded because '
            .. 'left shift already climbs them. Boost a car.')
            :format(tostring(f.class))
    end
    if n('driverFrames') == 0 then
        if n('inVehFrames') == 0 then
            return 'not-in-vehicle',
                'The key was seen on ' .. n('heldFrames') .. ' frames and you were '
                .. 'not in a vehicle on any of them. Boost only runs in a seat.'
        end
        return 'not-driver',
            'The key was seen and you were in a vehicle, never in the DRIVER\'s '
            .. 'seat of it. Boost is the driver\'s, by the spec.'
    end

    -- ── RUNG 3: WAS THE CAR ITSELF IN A STATE THAT MAY BOOST? ─────────────
    --
    --   "make the vehicle boost only work if the engine is on and fuel is >=5%"
    --                                              -- owner, 2026-09-21
    --
    -- BOTH ARE GUARDED ON `wantFrames` FOR THE CLASS RUNG'S REASON: a driver who
    -- stalled for a moment, or coasted the last of a tank onto a forecourt and
    -- filled up, and then boosted properly must not be told the tank was the
    -- answer.
    --
    -- THE TANK IS ASKED BEFORE THE ENGINE BECAUSE THE CHAIN ASKS IT FIRST, and
    -- the chain asks it first because a dry tank STALLS the car. An empty car
    -- fails both gates, and 'engine-off' would send that player to start an
    -- engine that cannot start -- which is exactly the wasted round this ladder
    -- exists to prevent. So the engine rung below genuinely means "the tank is
    -- fine and the engine is still not running".
    -- ═══ AND THE ONE FAILURE THE GATES THEMSELVES INTRODUCED, WHICH IS THE ONLY
    --     RUNG HERE NOT GUARDED ON `wantFrames == 0` ═══
    --
    -- The two rungs below are about a boost that NEVER STARTED, so a window in
    -- which the loop wanted to boost at all is not theirs. This one is the
    -- opposite case and could not be reached by that guard: a gate stopped a
    -- boost that WAS running, which means at least one frame wanted it. Before
    -- this rung existed a flickering engine came out as `already-ahead` -- the
    -- car was going faster than a ramp that had just restarted at zero, which is
    -- true and is not the cause -- and sent the next round to the impulse.
    --
    -- GUARDED ON THE LATCH STILL BEING SET rather than on a count, because a
    -- count cannot tell "it stopped and I am stuck" from "it stopped, I let go,
    -- and then it boosted fine". `gateLatch` is true only while the boost is
    -- still refusing under this hold, which is the case somebody ran /brboostwhy
    -- to understand.
    if n('gateStops') > 0 and f.gateLatch == true then
        return 'gate-tripped',
            ('Key seen, driving, and a gate took a LIVE boost away %d time(s) '
            .. 'while the key stayed down. The engine read OFF on %d frames and '
            .. 'the fuel gauge read below the line on %d. A gate that stops a '
            .. 'running boost latches, exactly as an emptied meter does, so it '
            .. 'will not come back under this hold: let go, then press again. '
            .. 'The latch is what stops a resumed boost re-sampling its base '
            .. 'speed off the boost it replaced, which measured +57 mph against '
            .. 'a +30 mph spec. If the engine and the tank were both fine on '
            .. 'your screen then the fault is one of those two reads rather than '
            .. 'the boost -- engineRunning() and fuelAbove() in '
            .. 'br_core/client/boost.lua.')
            :format(n('gateStops'), n('engineOffFrames'), n('lowFuelFrames'))
    end
    if n('lowFuelFrames') > 0 and n('wantFrames') == 0 then
        return 'fuel-low',
            ('Key seen, driving, and the fuel gauge read %.1f%% at its lowest '
            .. 'against the %.1f%% BR.Config.Boost.minFuelPct asks for, on %d '
            .. 'frames. The boost is refusing on purpose. That percentage is the '
            .. 'same one the fuel bar draws -- BR.Fuel.levelPct in '
            .. 'br_core/client/fuel.lua -- so if the bar disagrees with it, the '
            .. 'bug is that reading and not the boost. Otherwise: fill up.')
            :format(tonumber(f.fuelPctMin) or 0.0,
                    tonumber(f.minFuelPct) or 0.0, n('lowFuelFrames'))
    end
    if n('engineOffFrames') > 0 and n('wantFrames') == 0 then
        return 'engine-off',
            ('Key seen, driving, the tank is above the line, and '
            .. 'IS_VEHICLE_ENGINE_ON read OFF on %d frames. A coasting car does '
            .. 'not boost, by the spec. Start the engine. If it is running on '
            .. 'your screen then the fault is that read rather than the boost -- '
            .. 'engineRunning() in br_core/client/boost.lua, and %d frames could '
            .. 'not ask the native at all.')
            :format(n('engineOffFrames'), n('engineUnreadable'))
    end

    -- ── RUNG 4: DID THE LOOP DECIDE TO SPEND? ─────────────────────────────
    if n('wantFrames') == 0 then
        if n('emptyFrames') > 0 then
            return 'meter-empty',
                'Key seen, driving, and the meter was empty for the whole window. '
                .. 'It refills in six seconds from empty; wait, then try again.'
        end
        if n('dryFrames') > 0 then
            return 'dry-latch',
                'Key seen, driving, and the dry latch was set for the whole '
                .. 'window -- the meter emptied while the key was still down, and '
                .. 'a fresh boost needs a fresh press. Let go, then press again.'
        end
        return 'no-want',
            'Key seen and driving, and the loop still declined to boost on every '
            .. 'frame. That combination is not reachable by the rules as written; '
            .. 'paste this whole readout.'
    end

    -- ── RUNG 5: DID THE PUSH RUN, AND DID THE ENGINE ACCEPT IT? ───────────
    if n('pushFrames') == 0 then
        return 'no-push',
            'The loop wanted to boost on ' .. n('wantFrames') .. ' frames and '
            .. 'push() ran on none of them. That is not reachable by the rules as '
            .. 'written; paste this whole readout.'
    end
    if n('forced') == 0 then
        if n('forceThrew') > 0 then
            return 'force-throws',
                'APPLY_FORCE_TO_ENTITY threw on every call: ' ..
                tostring(f.forceErr or 'no message') .. '. The native is unbound '
                .. 'on this build or refuses these arguments. This is the impulse, '
                .. 'not the key -- the fallback is a torque multiplier, which '
                .. 'cannot be asked for an exact speed and is the owner\'s call.'
        end
        if n('noSpeed') > 0 then
            return 'no-speed-native',
                'Neither GET_ENTITY_SPEED_VECTOR nor GET_ENTITY_SPEED answered, so '
                .. 'the controller has no idea how fast the car is going and never '
                .. 'asked for anything. Nothing downstream of this was measured.'
        end
        return 'already-ahead',
            'The car was already going faster than the ramp asked for on every '
            .. 'frame, so nothing was applied -- which is correct, and is the '
            .. 'spec\'s "never slow the car down". Boost from a lower speed.'
    end

    -- ── RUNG 6: DID THE CAR ACTUALLY GO FASTER? ───────────────────────────
    --
    -- THE THRESHOLD IS DELIBERATELY LOW AND THE MIDDLE IS DELIBERATELY NAMED.
    -- Drag, gradient, gearing and a driver who lifted off all take a bite out of
    -- the gain, so anything near the full 30 mph would be a threshold that calls
    -- a working boost broken. A gain under a tenth of what was asked, over a
    -- boost that pushed for real frames, is not drag -- it is nothing happening.
    -- Between the two this says INCONCLUSIVE rather than picking, because a
    -- wrong verdict here costs the same playtest round as a wrong fix.
    local asked = tonumber(f.addMps) or 0.0
    local gain  = tonumber(f.gain) or 0.0
    if asked > 0.0 and gain < asked * 0.1 then
        return 'force-inert',
            ('The impulse was applied on %d frames and the car never got more than '
            .. '%.1f m/s above its speed at the press, against the %.1f m/s asked '
            .. 'for. The key, the seat, the meter and the loop are all fine and '
            .. 'APPLY_FORCE_TO_ENTITY is doing nothing. The fallback is a torque '
            .. 'multiplier, and it makes the exact +30 mph approximate -- that is '
            .. 'the owner\'s decision, not a silent swap.')
            :format(n('forced'), gain, asked)
    end
    if asked > 0.0 and gain < asked * 0.6 then
        return 'inconclusive',
            ('The impulse was applied on %d frames and the car gained %.1f m/s of '
            .. 'the %.1f m/s asked for. Something is happening and it is short. '
            .. 'Boost on a flat straight at a steady speed and read it again '
            .. 'before changing anything.'):format(n('forced'), gain, asked)
    end
    return 'ok',
        ('The whole chain ran: key seen on %d frames, pushed on %d, and the car '
        .. 'gained %.1f m/s of the %.1f m/s asked for. Boost works on this build.')
        :format(n('heldFrames'), n('forced'), gain, asked)
end

--- Everything about the meter, in one paste. The same shape as /brstam.
RegisterCommand('brboostinfo', function()
    print('=== boost ===')
    print(('  enabled %s   meter %.0f%%  (%.0f / %.0f ms)'):format(
        tostring(enabled()), BR.Boost.meter(), budget,
        C and C.capacityMs or 0))
    print(('  running %s   base %.1f m/s   netId %s'):format(
        tostring(run.on), run.baseMps, tostring(run.netId)))
    if run.on then
        local el = GetGameTimer() - run.startAt
        print(('  elapsed %d ms   ramp %.2f   target %.1f m/s'):format(
            el, BR.BoostSolve.ramp(el, C.rampMs),
            BR.BoostSolve.target(run.baseMps, C.addMps, el, C.rampMs)))
    end
    -- ═══ THE ROW THAT SAYS WHETHER THE ENGINE EVER TOOK THE IMPULSE ═══
    --
    -- `pcall(ApplyForceToEntity, ...)` discarded its result, so a native that is
    -- unbound on this build, or that refuses this signature, failed silently on
    -- every frame of every boost and left exactly the reported symptom: a meter
    -- that spends and a car that does not move. Two integers and a string.
    --
    -- 0 of 0 IS NOT A FAULT -- it means nobody has boosted yet this session.
    print(('  force calls %d, accepted %d%s'):format(
        forceCalls, forceOk,
        forceErr and ('   FIRST ERROR: ' .. forceErr) or ''))
    local n = 0
    for _ in pairs(lit) do n = n + 1 end
    print(('  vehicles alight %d   key %s'):format(
        n, tostring(BR.Keys.labelFor('brboost'))))
    print('  /brboostwhy [secs] measures the whole chain and names the stage that fails')
end, false)
