-- The arithmetic behind healing in the back of an ambulance.
--
-- PURE, AND EVERY THRESHOLD IS A PARAMETER. Same shape as BR.FuelSolve and
-- BR.HealthUnexplainedGain: nothing in here reads a global config, so
-- tools/test_ambheal.lua can drive values no shipped config would ever hold --
-- which is the only way the edge cases get shown to still be handled.
--
-- ═══ WHY THESE FOUR ARE WORTH HOISTING OUT OF THE TWO HALVES ═══
--
-- Both ends ask the same three questions and must not answer them differently:
--
--   THE CLIENT asks them to decide what to DRAW and when to stop.
--   THE SERVER asks them to decide what to GRANT.
--
-- client/fuel.lua's header records what happens when those two drift: "a plate
-- reading 'Currently fueling' while the server refuses every message". The
-- refusal is invisible, the prompt is not, and the player reports a broken
-- feature. So the reach test, the rear-arc test and the target arithmetic are
-- written once and called twice.
--
-- WHAT IS NOT HERE: the doors. The rear-door ratio can only be read on a client
-- (GET_VEHICLE_DOOR_ANGLE_RATIO has no server handler), so the server cannot
-- run that half at all -- see BR.AmbHealSolve.doorsOpen for the honest statement
-- of what that costs.

BR = BR or {}
BR.AmbHealSolve = {}

--- How far through a heal we are, 0..1.
---
--- CLAMPED AT BOTH ENDS. Below zero is a clock that went backwards (a server
--- restart mid-heal is the real case) and above one is a tick that arrived late;
--- neither should be able to produce a target outside the range the caller
--- expects, because the target feeds a health write.
---
--- A ZERO OR NEGATIVE DURATION IS "DONE", not "divide by zero". A config that
--- lost its `durationMs` should heal instantly and visibly rather than error in
--- a scheduler callback -- an uncaught throw in BR.Sched costs the whole job.
--- @param startedAt number   server ms the heal began
--- @param now number         server ms
--- @param durationMs number
--- @return number  0..1
function BR.AmbHealSolve.progress(startedAt, now, durationMs)
    startedAt = tonumber(startedAt) or 0.0
    now       = tonumber(now) or 0.0
    durationMs = tonumber(durationMs) or 0.0
    if durationMs <= 0.0 then return 1.0 end
    return BR.Clamp((now - startedAt) / durationMs, 0.0, 1.0)
end

--- The health this player should be on right now.
---
--- ═══ A TARGET MEASURED FROM `hp0`, WHICH IS THE WHOLE DESIGN ═══
---
--- server/inventory.lua's consumable tick learned this the expensive way and the
--- write-up there is worth reading before changing anything here. The short
--- version: every message in one heal is computed from the health the player
--- STARTED on, never from their current reading. That is what makes a dropped
--- message harmless -- the next one carries the full truth -- and it is what
--- stops the final message double-counting the ramp the earlier ones already
--- applied ("one shield took me to ~95% from 0%", 2026-08-08).
---
--- MONOTONIC AND CAPPED. It never returns less than `hp0` (a heal cannot hurt
--- you, even if the caller passes a negative pct) and never more than `healTo`.
--- The client applies these UPWARD ONLY on top of that, so a player who took a
--- bullet mid-heal is not dragged back UP to where the ramp says they should be
--- -- they keep the damage and the ramp keeps healing from underneath it.
--- @param hp0 number      display hp when the heal began
--- @param healTo number   the ceiling
--- @param pct number      0..1 from progress()
--- @return number
function BR.AmbHealSolve.target(hp0, healTo, pct)
    hp0    = tonumber(hp0) or 0.0
    healTo = tonumber(healTo) or 100.0
    pct    = BR.Clamp(tonumber(pct) or 0.0, 0.0, 1.0)
    if healTo <= hp0 then return hp0 end
    return hp0 + (healTo - hp0) * pct
end

--- Is this player standing at the back of that ambulance?
---
--- ═══ TWO TESTS, AND THE SECOND IS THE ONE THAT MAKES THE FIRST MEAN ANYTHING ═══
---
--- Distance alone is a SPHERE around the vehicle origin, and 3.5m of sphere
--- reaches the bonnet of a van. The owner asked for "the back of an ambulance",
--- so the arc is not a refinement of the rule -- it is the rule, and the
--- distance is the part that bounds it.
---
--- ═══ THE FORWARD VECTOR, AND THE SIGN THAT IS ALWAYS GOT WRONG ═══
---
--- A GTA heading's forward vector is (-sin h, cos h). client/rescue.lua carries
--- the same note beside its delivery ("behind is its negation -- getting this
--- backwards puts the player in front of the bonnet"), and this function is the
--- other half of that pair: it decides where you may STAND, that one decides
--- where you are PUT DOWN, and if their signs disagree the player gets in at the
--- back and is spat out at the front.
---
--- So `dot` is forward . (vehicle -> player). Directly behind is -1.0.
---
--- 2D, DELIBERATELY. A player on a kerb beside a van is at the back of it; a
--- player on a roof three metres above is not, but they cannot be within 3.5m in
--- plan either without being on the van itself. Adding z would mostly reject
--- legitimate ground that happens to slope.
---
--- @param vx number       vehicle x
--- @param vy number       vehicle y
--- @param heading number  vehicle heading, degrees
--- @param px number       player x
--- @param py number       player y
--- @param reachM number
--- @param behindDot number   the arc; -1.0 is dead astern, 0.0 is the midline
--- @return boolean inReach
--- @return number dist      metres, for the caller's own logging
--- @return number dot       so a refusal can say WHICH test failed
function BR.AmbHealSolve.atRearDoors(vx, vy, heading, px, py, reachM, behindDot)
    vx, vy = tonumber(vx) or 0.0, tonumber(vy) or 0.0
    px, py = tonumber(px) or 0.0, tonumber(py) or 0.0
    reachM = tonumber(reachM) or 0.0
    behindDot = tonumber(behindDot) or 0.0

    local dist = BR.Dist(vx, vy, px, py)

    -- STANDING EXACTLY ON THE ORIGIN HAS NO DIRECTION, and normalising a zero
    -- vector is a nan that compares false against everything -- which would read
    -- as "not at the back" for the one position that is unambiguously inside the
    -- van. Answered as `in reach` with a dot of -1: the distance test has
    -- already passed and there is no rear arc to fail.
    if dist <= 0.0001 then
        return reachM > 0.0, 0.0, -1.0
    end

    local rad = math.rad(tonumber(heading) or 0.0)
    local fx, fy = -math.sin(rad), math.cos(rad)
    local dot = (fx * (px - vx) + fy * (py - vy)) / dist

    return (dist <= reachM) and (dot <= behindDot), dist, dot
end

--- Are the rear doors open enough to heal through?
---
--- ═══ THIS IS THE ONE RULE THE SERVER CANNOT CHECK, STATED PLAINLY ═══
---
--- GET_VEHICLE_DOOR_ANGLE_RATIO is a client native with no server handler, so
--- the door state reaches the server only if a client tells it -- and a client
--- that lies about it is the thing every other check in this feature exists to
--- refuse. It is not made a wire field for exactly that reason: an unverifiable
--- claim on the wire is worse than no claim, because it looks like a check.
---
--- WHAT A MODIFIED CLIENT GAINS BY IGNORING THIS: a heal at an ambulance whose
--- doors are shut. Not a faster heal, not a bigger one, not one at a vehicle
--- that is not an ambulance, not one somebody else has claimed, and not one they
--- are not standing behind -- every one of those is re-derived on the server
--- from its own reads. What they gain is a cosmetic rule broken in a way nobody
--- else can see. That is the correct thing to spend the unverifiable half of a
--- feature on, and it is why the doors are the client's rule and the claim is
--- the server's.
---
--- ALL OF THEM, NOT ANY. Two doors are named and both must be open: "the rear
--- doors" is plural in the sentence, and half-open is the state a van is left in
--- by somebody who bumped one.
---
--- ═══ `expected` IS NOT OPTIONAL POLISH. IT IS THE HOLE THIS FUNCTION HAD ═══
---
--- The first draft walked `1..#ratios` and treated a nil entry as shut. In Lua
--- `#{ 1.0, nil }` IS 1 -- a nil is not an element, it is the end of the array --
--- so a door the native could not read did not read as shut, it VANISHED, and
--- the loop cheerfully approved a van on the strength of its one remaining door.
--- The rule the owner asked for is plural ("the rear doors"), and that is
--- exactly the case where it would have quietly become singular.
---
--- So the caller says how many doors it MEANT to read, and a short array is a
--- refusal rather than a shorter rule. client/ambheal.lua also writes `false`
--- into a slot it could not read, which keeps the array dense and closes the
--- same hole from the other end -- belt and braces, because this is a rule that
--- fails silently and in the permissive direction.
---
--- @param ratios any[]        one GET_VEHICLE_DOOR_ANGLE_RATIO per rear door;
---                            `false` (not nil) for one that could not be read
--- @param minRatio number     how far counts as open
--- @param expected integer|nil  how many doors there should be; defaults to
---                            #ratios, which is only safe for a dense array
--- @return boolean
function BR.AmbHealSolve.doorsOpen(ratios, minRatio, expected)
    if type(ratios) ~= 'table' then return false end

    local want = tonumber(expected) or #ratios
    if want <= 0 then return false end
    -- A SHORT ARRAY IS A REFUSAL. See above: this is the nil case, and it is the
    -- one that turned a rule about two doors into a rule about one.
    if #ratios < want then return false end

    minRatio = tonumber(minRatio) or 0.0
    for i = 1, want do
        local r = tonumber(ratios[i])
        -- A DOOR THAT COULD NOT BE READ IS SHUT. Treating an unreadable door as
        -- open would make the rule vanish on the first ambulance variant that
        -- numbers its doors differently -- silently, and permissively.
        --
        -- `r ~= r` IS THE NAN TEST. Every comparison against a nan is false,
        -- including `r < minRatio`, so without this line a nan door would fall
        -- through the check and be treated as open.
        if r == nil or r ~= r or r < minRatio then return false end
    end
    return true
end

--- Where to put the player down when the heal ends.
---
--- BEHIND THE VEHICLE AS IT STANDS NOW, which is a decision rather than a
--- transcription. The owner said "we force them out the back of the ambulance
--- where they were before"; "where they were before" is read as BEHIND THE
--- AMBULANCE rather than as the exact patch of road they walked in from,
--- because the two are the same place unless the van has moved -- and if it HAS
--- moved, the coordinates they walked in from are somewhere down the street with
--- no ambulance at them, which is not "out the back of the ambulance".
---
--- THE SIGN, AGAIN. Forward is (-sin h, cos h), so behind is (sin h, -cos h).
--- This returns the same arithmetic client/rescue.lua's delivery uses, from one
--- place, so the two cannot drift -- and BR.AmbHealSolve.atRearDoors above is
--- derived from the same forward vector, which is what makes "you are put down
--- where you stood" true rather than approximately true.
--- @param vx number
--- @param vy number
--- @param heading number  degrees
--- @param backM number
--- @return number x
--- @return number y
function BR.AmbHealSolve.dropPoint(vx, vy, heading, backM)
    local rad = math.rad(tonumber(heading) or 0.0)
    backM = tonumber(backM) or 0.0
    return (tonumber(vx) or 0.0) + math.sin(rad) * backM,
           (tonumber(vy) or 0.0) - math.cos(rad) * backM
end
