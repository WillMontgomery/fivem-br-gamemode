-- The storm, server half: the authority -- ONE PER MATCH INSTANCE.
--
-- The server publishes ONE record per phase (BR.BuildStormRecord) and both
-- sides solve the circle locally from it against the synced clock -- the same
-- pattern as the bus. Nothing per-frame ever crosses the wire. The record,
-- the rng and the damage-carry bookkeeping all live on the match instance
-- (m.storm / m.stormRng / m.stormCarry): two concurrent matches run two
-- independent storms, each published only to its own audience.
--
-- AND ONE FIELD THAT EXISTS BEFORE THE STORM DOES. m.stormFirst is circle 1,
-- drawn at WARMUP so the map can show it through warmup and the bus (#327), and
-- spent by enterPhase the moment phase 1 begins. It is not a record and carries
-- no clock: see BR.Net.STORM_PREVIEW for what that distinction is protecting.
--
-- AUTHORITY, stated plainly. The server cannot write a ped's health, so the
-- visible hurt is applied client-side on instruction (STORM_DAMAGE). But the
-- server keeps its own ledger of what the storm SHOULD have done to each
-- player and eliminates from the LEDGER -- so a client that ignores the
-- instruction keeps its health bar and dies at exactly the same moment as an
-- honest one. That is what makes the M4 authority drill pass: disable every
-- client storm callback and the elimination still lands on time.
--
-- Storm damage is deliberately NOT routed through combat validation: it has no
-- attacker, no weapon and no hit position. It is the server hurting a player,
-- not a player claiming to have hurt one.

BR = BR or {}
BR.Storm = {}

local cfg = BR.Config.Storm

-- Dev tuning: every subsequently built phase gets its wait/shrink multiplied
-- by this. 0.1 turns the 20-minute cycle into 2 for testing. Records already
-- published keep their stamped times -- brphase re-enters if you want it now.
-- Deliberately global across matches: it is a dev knob, not match state.
local timeScale = 1.0

local function publish(m)
    BR.Broadcast.toMatch(m, BR.Net.STORM_SYNC, m.storm)
end

-- ═══ THE SOUND THE WALL MAKES WHEN IT STARTS MOVING ═══
--
--   "We also need a sound for when the storm starts moving"
--                                          -- owner, 2026-08-22
--
-- WHICH MOMENT THAT IS. A phase has two halves. `enterPhase` is when the next
-- circle is DRAWN and the wall STOPS -- the hold. The wall starts moving at the
-- other end of that hold, when BR.StormAt stops answering HOLDING and starts
-- answering SHRINKING. That edge is what this cues, and it is cued eight times
-- a match rather than once.
--
-- ═══ WHY THE SERVER OWNS THE EDGE AND NOT THE CLIENT ═══
--
-- Every client already solves the wall for itself -- that is the whole design,
-- and it means every client COULD notice this boundary on its own. It must not:
-- that is eight latches in eight frame loops, each drifting by a frame, each
-- needing its own "have I already played this" state, and each getting it wrong
-- for a player who joined or respawned mid-phase. The server runs one 1 Hz job
-- that is already looking at exactly this record, so the edge is detected once,
-- in one place, and ADDRESSED to the match. "Everyone hears it once" then
-- follows from the fan-out rather than from eight clients agreeing.
--
-- UP TO ONE SECOND LATE, AND THAT IS FINE. The job ticks at 1 Hz, so the cue
-- can trail the true boundary by up to a second. A shrink runs 40 to 360
-- seconds and the wall is a kilometre wide; nobody can perceive the offset, and
-- paying for exactness would mean putting this in a frame loop.
local MOVE_CUE = 'storm.move'

--- The other end of the same sweep.
---
---   "Circle finished moving (possible)" -- owner, 2026-09-08, naming a sound
---   for it. The SHRINKING->HOLDING edge, the opposite of the one MOVE_CUE
---   rides.
local STOP_CUE = 'storm.stop'

--- Tell a whole match the wall has begun to move -- at most once per phase.
---
--- THE LATCH IS ON THE MATCH, NOT ON THE PHASE NUMBER, and that difference is
--- real: `brphase` and `brstormfreeze off` both RE-ENTER a phase from wherever
--- the wall is standing, which gives it a fresh hold and a fresh sweep. Keyed on
--- the number, a thaw would hold its peace while the wall visibly set off again.
--- `enterPhase` clears it, so every entry -- first, forced or thawed -- arms it.
---
--- FINISHED COUNTS AS MOVED. The state to watch is SHRINKING, but a scheduler
--- stall long enough to skip every tick of a sweep would step straight from
--- HOLDING to FINISHED and the cue would be lost with nothing to say so. A wall
--- that has finished moving has moved, so the latch trips either way.
--- @param m table
local function cueMovementOnce(m, st)
    if m.stormMoveCued then return end
    if st ~= BR.StormPhase.SHRINKING and st ~= BR.StormPhase.FINISHED then return end
    m.stormMoveCued = true
    -- A CUE KEY, NEVER A SOUND NAME. The wire carries `storm.move` and the
    -- client resolves it against its own BR.Config.Audio.cues, which is what
    -- lets the owner re-point it with /brsfx bind without a line of this file
    -- changing. See br_lib/shared/protocol.lua's SFX_CUE.
    BR.Broadcast.toMatch(m, BR.Net.SFX_CUE, { c = MOVE_CUE })
end

--- Tell a whole match the wall has come to rest -- at most once per phase.
---
--- ═══ THE SAME SHAPE AS cueMovementOnce, AND SEPARATE FOR ONE REASON ═══
---
--- FINISHED trips the MOVE latch too, deliberately: a scheduler stall long
--- enough to skip every tick of a sweep steps straight from HOLDING to FINISHED,
--- and a wall that has finished moving has moved. Folding both cues into one
--- function would make that shared reading play them as a pair, back to back,
--- for a sweep nobody saw. Two latches means the stall plays the departure it
--- owes and this one, which is the honest account of what the wall did.
---
--- IT IS NOT THE PHASE ADVANCE, though the two land on the same tick in the
--- ordinary case. The final phase stays FINISHED at radius 0 forever and never
--- advances, and it is the one sweep where "the wall has stopped" matters most.
--- @param m table
local function cueStopOnce(m, st)
    if m.stormStopCued then return end
    if st ~= BR.StormPhase.FINISHED then return end
    m.stormStopCued = true
    BR.Broadcast.toMatch(m, BR.Net.SFX_CUE, { c = STOP_CUE })
end

--- Seed this match's storm stream, IF IT HAS NOT ALREADY BEEN SEEDED.
---
--- ═══ EXACTLY ONCE PER MATCH, AND THE `if` IS THE WHOLE POINT ═══
---
--- The sequence number keeps two matches started in the same server millisecond
--- (tests do this constantly) from replaying each other. `seq` rather than `id`
--- (#291): the id is a random draw now, and a storm path that cannot be
--- reproduced from a boot is one nobody can debug.
---
--- WHAT THE GUARD PREVENTS, now that there are two callers. Circle 1 is drawn at
--- WARMUP (#327) and the rest of the match is drawn from the same stream as it
--- runs, so a second seed anywhere would RESTART the sequence -- phase 2 would
--- then be handed the value phase 1 already used, and every phase after it would
--- shift by one. Nothing a player could see would look broken; the storm would
--- simply stop being the storm the preview promised, and it would take a
--- side-by-side walk of two matches to notice.
---
--- ═══ THE SEED IS KEPT NOW, NOT JUST SPENT (#344) ═══
---
--- Every phase draws a random SHAPE as well as a centre, and the client has to
--- derive the same shape from the same seed -- so the integer goes on the record
--- and out on the wire (BR.BuildStormRecord's `seed`, BR.StormZone's derivation).
--- It is the same number the stream was built from, kept rather than recomputed,
--- because a second `GetGameTimer() + m.seq * 7919` a millisecond later is a
--- different number and the client would draw a different wall from the one the
--- damage rule is billing.
---
--- AND IT IS FLOORED TO AN INTEGER, which is #346: BR.Rng runs its argument through
--- math.tointeger and falls back to ZERO when that fails, so a fractional seed is
--- silently seed 0 -- every match the same storm, with nothing to notice.
--- GetGameTimer returns whole milliseconds in the game and a test harness can hand
--- back whatever it likes.
--- @param m table
local function seedRng(m)
    if m.stormRng then return end
    m.stormSeed = math.tointeger(math.floor(GetGameTimer() + m.seq * 7919)) or 0
    m.stormRng = BR.Rng(m.stormSeed)
end

--- Draw the centre the given phase closes on, off this match's storm stream.
---
--- ═══ ONE DRAW SITE, BECAUSE TWO WOULD HAVE TO AGREE FOREVER ═══
---
--- Circle 1 is drawn at WARMUP and phases 2 and up are drawn at phase entry, and
--- both must hand BR.NextZoneCentre byte-for-byte identical arguments -- the
--- zone being closed from, the edge hug, the breakout budget, the map bounds.
--- Spelled at two call sites, the day somebody tunes `edgeHugPhases` is the day
--- the preview quietly stops matching the circle it is previewing. Spelled once,
--- they cannot disagree.
---
--- ═══ PLACED BY REAL SHAPE, INSIDE THE ZONE IT CLOSES FROM (#344) ═══
---
--- The HOST is the zone this phase's wall starts as -- zone 0, the map disc, for
--- phase 1, the zone before otherwise, or the outline a freeze or a same-phase
--- `brphase` carried (`mo`) -- and on a phase that does not break out the next zone
--- lands ENTIRELY inside it, by its real shape. That is what lets the wall morph
--- onto the target without ever crossing it.
---
--- THE FINAL PHASES HUG THE EDGE: the next zone sits within edgeHugM of as far as
--- it could go on its bearing, so endgames resolve as a run to a place rather than
--- a shuffle in the middle. Earlier phases roam the whole room there is (edgeBiasMax
--- 1.0). Phase 1 is never one of them, which is why the preview can be drawn from
--- the anchor alone.
---
--- The breakout budget rides along: it lets a phase's zone leave the current one,
--- and enterPhase's sweep pricing is what keeps that fair -- the furthest player's
--- run to the TARGET's wall sets the wall's travel time, so a zone that moved
--- further simply takes longer to close.
--- @param m table
--- @param phase integer
--- @param cx0 number     the circle being shrunk from
--- @param cy0 number
--- @param r0 number
--- @param mo table|nil   the wall's outline, when the phase starts part way through
---                       a morph (a thaw, a same-phase brphase)
--- @return number, number, boolean  centre, and whether it broke out
local function drawCentre(m, phase, cx0, cy0, r0, mo)
    local p = cfg.phases[phase]
    local hugM = nil
    if phase > #cfg.phases - (cfg.edgeHugPhases or 0) then
        hugM = cfg.edgeHugM or 0.0
    end
    return BR.NextZoneCentre(m.stormRng,
        BR.StormHost(m.stormSeed, phase, cx0, cy0, r0, mo), cx0, cy0, r0,
        BR.StormUnit(m.stormSeed, phase), p.radius, cfg.edgeBiasMax, cfg.mapAABB,
        hugM, BR.StormBreakoutFor(cfg, phase))
end

--- Circle 1 as a shape, from a phase-1 record: the boundary both phase-1 rules
--- measure players against -- the hold's price (BR.Storm.begin) and the 75% cut
--- (circleOneHeadcount) -- so "inside circle 1" means one thing to both.
---
--- ═══ THE SHAPE, NOT THE RADIUS ═══
---
--- Circle 1 has been a shape since #344, and since round 2 one stretched up to
--- 3:1 and held to the circle's area rather than its radius, so a radius test is
--- wrong both ways -- the defect #349 fixed in airdrop siting. BR.StormZone at the
--- END OF THE SWEEP -- `t` of 1, where the wall has arrived -- is the destination
--- itself: zone 1's shape at (cx1, cy1, r1), the same boundary the bus preview
--- draws and the wall ends its first sweep on. Negative distance is inside it.
--- @param rec table   a phase-1 record
--- @return table shape
local function circleOneZone(rec)
    return BR.StormZone(rec, rec.cx1, rec.cy1, rec.r1, 1.0)
end

--- How many of this match's living players there are, and how many of them are
--- standing inside circle 1's shape (#352).
---
--- LIVING IS BR.Server.isInMatch: standing, downed, or still in the air. A glider
--- over circle 1 is counted where they are, and the dead are counted nowhere --
--- which is how "75% of living players" moves as people die. A player the sampler
--- has no position for is living and not inside, because inside is a thing to
--- be shown rather than assumed.
--- @param m table
--- @param rec table   a phase-1 record
--- @return integer living, integer inside
local function circleOneHeadcount(m, rec)
    local zone = circleOneZone(rec)
    local living, inside = 0, 0
    BR.Roster.each(
        function(e) return e.matchId == m.id and BR.Server.isInMatch(e.state) end,
        function(_, e)
            living = living + 1
            if e.pos and BR.StormShape.distance(zone, e.pos.x, e.pos.y) <= 0 then
                inside = inside + 1
            end
        end)
    return living, inside
end

--- Cut the phase-1 hold to 1:30 the first moment the lobby is in (#352).
---
---   "When >=75% are within the circle, the time is 1:30 till the storm moves"
---                                                      -- owner, 2026-09-22
---
--- ═══ ASKED EVERY TICK OF THE HOLD, AND LATCHED THE FIRST TIME IT IS TRUE ═══
---
--- Players move, and a countdown that jumped back up when somebody stepped out
--- would be worse than one that was long to begin with. So `m.stormHoldCapped` is
--- set once and nothing clears it but the instance going away: after that, every
--- phase-1 hold this match has -- including one `brphase 1` or a thaw re-enters --
--- is held to the cap whoever is standing where.
---
--- IT ONLY EVER SHORTENS. The record is rebuilt only when more than the cap is
--- left, with the same tStart, so a hold already under 1:30 -- the one-minute floor
--- a lobby landing inside prices at -- is left exactly as it was.
---
--- AND NEVER INTO A WARNING THE CLIENT HAS COMMITTED TO. What is left is never cut
--- below the wall's own fade-in window (render.fadeInSec, which the curtain and
--- the #340 preview hand off across) or phases[1].warn, whichever is longer --
--- so a cap tuned under them cannot cut the fade short or skip the warning. (No
--- client code reads `warn` yet; the fade window and the 4 s pip are the live
--- ones.) At the shipping 90 s neither binds, and the cap only fires with more
--- than 90 s left, so no countdown on screen is ever inside one when it moves.
---
--- PUBLISHED ON THE TICK THAT CUTS IT, because the HUD derives its digits from
--- the record: a beat of the old countdown after the cut is the hitch this is
--- written to avoid. `quiet` is for enterPhase alone, which is about to publish
--- the record it has just built -- and asking there is what gives the solo drop
--- that opened #352 a first record that already says 1:30.
---
--- NOT WHILE brstormfreeze HOLDS THE STORM. The freeze is a phase-1 record with a
--- day of hold, and cutting it to 1:30 would thaw it by the back door.
--- @param m table
--- @param now number
--- @param quiet boolean|nil  build the record but leave publishing to the caller
local function capFirstHold(m, now, quiet)
    local rec = m.storm
    if not rec or rec.phase ~= 1 then return end
    if BR.Storm.isFrozen and BR.Storm.isFrozen() then return end
    local _, _, _, st, msLeft = BR.StormAt(rec, now)
    if st ~= BR.StormPhase.HOLDING then return end

    local H = cfg.hold
    if not m.stormHoldCapped then
        local living, inside = circleOneHeadcount(m, rec)
        if not BR.AtLeastPercent(inside, living, H.capInsidePct or 100) then
            return
        end
        m.stormHoldCapped = true
        print(('[br_core] storm: match %s -- %d of %d inside circle 1, the hold is capped at %.0fs')
            :format(BR.MatchTag(m.id), inside, living, H.capSeconds or 0))
    end

    -- The schedule numbers take the dev time scale like every hold does; the fade
    -- window is drawn in real seconds on the client, so it does not.
    local floorMs = math.max((cfg.phases[1].warn or 0) * 1000.0 * timeScale,
                             (cfg.render.fadeInSec or 0) * 1000.0)
    local capMs = math.max((H.capSeconds or 0) * 1000.0 * timeScale, floorMs)
    if msLeft <= capMs then return end

    local elapsed = now - rec.tStart
    m.storm = BR.BuildStormRecord(rec.phase, rec.cx0, rec.cy0, rec.r0,
        rec.cx1, rec.cy1, rec.r1, rec.tStart, elapsed + capMs,
        rec.tShrink, rec.dps, rec.seed, rec.mo)
    print(('[br_core] storm: match %s phase 1 hold cut from %.0fs to %.0fs left')
        :format(BR.MatchTag(m.id), msLeft / 1000, capMs / 1000))
    if not quiet then publish(m) end
end

--- Build and publish the record that shrinks toward phases[phase], starting
--- from the given circle. The next centre is drawn HERE, at phase entry, so
--- players see where to rotate for the whole hold.
---
--- THE WALL'S TRAVEL TIME IS PRICED HERE TOO, every phase (user call,
--- 2026-08-04): the furthest in-match player's run to the TARGET's wall, at
--- shrinkPace speed, floored at minSeconds and ceilinged by the authored value.
--- Everyone already inside the target? The sweep is quick and the game moves on.
--- A straggler two kilometres out? They get their run. This replaced phase 1's
--- hold-payback scheme -- pricing the shrink directly is the same fairness
--- without the bookkeeping.
--- @param m table         the match instance
--- @param phase integer   1-based index into cfg.phases
--- @param cx0 number      circle being held / shrunk from
--- @param cy0 number
--- @param r0 number
--- @param now number
--- @param waitSec number|nil  override the authored wait (the dynamic hold)
--- @param mo table|nil        the wall's own outline when the phase is entered part
---                            way through a morph: the thaw's and a same-phase
---                            `brphase`'s (BR.StormMorphAt), so the wall keeps the
---                            shape it is standing in and every corner carries on to
---                            the corner it was heading for. Every ordinary entry
---                            leaves it nil.
local function enterPhase(m, phase, cx0, cy0, r0, now, waitSec, mo)
    local p = cfg.phases[phase]

    -- ═══ PHASE 1 CONSUMES A DRAW ALREADY MADE; EVERY OTHER PHASE MAKES ONE ═══
    --
    --   "just determine circle 1's location upon the first player in the match
    --    completing matchmaking"                      -- owner, 2026-09-21 (#327)
    --
    -- BR.Storm.drawFirstCircle took the FIRST value off this match's stream back
    -- at WARMUP, so that the map could show players where they were dropping
    -- toward. Nothing about the storm moved for it: this is the same draw, off the
    -- same stream, with the same arguments, made earlier -- so phase 1 must now
    -- SPEND that value rather than roll a second one.
    --
    -- THE FAILURE A SECOND ROLL CAUSES IS SILENT AND IT IS NOT PHASE 1'S. Drawing
    -- again here would advance the stream one extra step, so phase 1 would land
    -- somewhere the preview never promised AND phases 2 through 8 would each
    -- inherit the value belonging to the phase before them. Every circle would
    -- still be legal, on the map, and correctly nested; the match would simply not
    -- be the match. tools/test_storm.lua's `first.stream` block walks a whole
    -- match's centres down both paths and is what makes that impossible to ship.
    --
    -- NIL'D AS IT IS SPENT, so it cannot be spent twice -- `brphase 1` an hour
    -- into a match re-enters phase 1 and draws a fresh centre from wherever the
    -- wall is standing, which is what it has always done.
    local cx1, cy1, brokeOut
    local pre = (phase == 1) and m.stormFirst or nil
    if pre then
        m.stormFirst = nil
        cx1, cy1, brokeOut = pre.cx, pre.cy, pre.brokeOut
    else
        cx1, cy1, brokeOut = drawCentre(m, phase, cx0, cy0, r0, mo)
    end

    -- ═══ PRICE THE SWEEP FOR THE FURTHEST PLAYER'S RUN TO THE TARGET'S WALL ═══
    --
    -- THIS match's players only, and measured to the destination's REAL boundary
    -- (#344) -- the wall the sweep ends on, as #364 did for the hold. It used to be
    -- `distance to the next centre - nextRadius`, which on a 3:1 zone charges a
    -- player standing off its long side a run to a circle nothing draws, and lets one
    -- off its end ride free. Inside the shape costs nothing. Phase 8's destination is
    -- a point, and the run is to the point.
    local target = nil
    if p.radius > 0.0 then
        target = BR.StormTarget({ seed = m.stormSeed, phase = phase,
                                  cx1 = cx1, cy1 = cy1, r1 = p.radius })
    end
    local furthest = 0.0
    BR.Roster.each(
        function(e) return e.matchId == m.id and BR.Server.isInMatch(e.state) end,
        function(_, e)
            if e.pos then
                local d
                if target then
                    d = BR.StormShape.distance(target, e.pos.x, e.pos.y)
                else
                    d = BR.Dist(e.pos.x, e.pos.y, cx1, cy1)
                end
                if d > furthest then furthest = d end
            end
        end)
    -- A BREAKOUT BUYS A LONGER SWEEP.
    --
    -- The authored per-phase `shrink` is the ceiling on travel time, and it was
    -- written for NESTED zones -- where the furthest anyone can be from the next
    -- zone's wall is about one radius. A zone that has separated from its
    -- predecessor can be three times that away, and at 9 m/s the wall would
    -- simply outrun everyone: the rotation the breakout is meant to force becomes
    -- a cull instead. So the ceiling is lifted for exactly the phases that rolled
    -- a breakout, and the pricing below still decides how much of it is actually
    -- used -- if everybody happens to be near the new zone, the sweep is short
    -- regardless.
    local ceiling = p.shrink
    if brokeOut then
        ceiling = p.shrink * ((cfg.breakout and cfg.breakout.shrinkFactor) or 1.0)
    end
    local shrinkSec = BR.Clamp(furthest / cfg.shrinkPace.metersPerSec,
        cfg.shrinkPace.minSeconds, ceiling)

    -- THE SEED RIDES ALONG, WHICH IS WHAT MAKES THE WALL A SHAPE (#344). It is the
    -- match's own storm seed, unchanged every phase -- the phase INDEX is the other
    -- half of the derivation, and the record already carries that. seedRng has
    -- always run before any route into a phase, so this is never nil in the game;
    -- BR.BuildStormRecord's header says what a missing one would mean.
    m.storm = BR.BuildStormRecord(phase, cx0, cy0, r0, cx1, cy1, p.radius,
        now, (waitSec or p.wait) * 1000 * timeScale,
        shrinkSec * 1000 * timeScale, p.dps, m.stormSeed, mo)

    -- ARMED FOR THIS PHASE'S SWEEP. Every route into a phase comes through
    -- here -- the first one, the next one, `brphase`, and the thaw -- so this
    -- one line is what makes "once per hold-to-shrink transition" true for all
    -- four of them rather than for the ordinary one only.
    m.stormMoveCued = false
    m.stormStopCued = false

    -- BEFORE THE FIRST PUBLISH, NOT ON THE TICK AFTER IT (#352). A lobby that goes
    -- live already inside circle 1 -- a solo drop, always -- would otherwise be
    -- sent the priced hold and then, a second later, 1:30.
    if phase == 1 then capFirstHold(m, now, true) end

    print(('[br_core] storm: match %s phase %d -- r %.0f -> %.0f, holds %.0fs, shrinks %.0fs (furthest %.0fm), %.1f dps')
        :format(BR.MatchTag(m.id), phase, r0, p.radius,
                m.storm.tWait / 1000, m.storm.tShrink / 1000, furthest, p.dps))
    publish(m)
end

--- The opening circle covers the WHOLE playable map: distance from the anchor
--- to the farthest bounds corner, floored at radius0. Nobody can land outside
--- circle 1, so "I spawned already dying" is structurally impossible -- the
--- first shrink is what brings the map in toward the anchor.
--- @param ax number
--- @param ay number
--- @return number
local function openingRadius(ax, ay)
    local A = cfg.mapAABB
    local r = cfg.radius0
    r = math.max(r, BR.Dist(ax, ay, A.min.x, A.min.y))
    r = math.max(r, BR.Dist(ax, ay, A.min.x, A.max.y))
    r = math.max(r, BR.Dist(ax, ay, A.max.x, A.min.y))
    r = math.max(r, BR.Dist(ax, ay, A.max.x, A.max.y))
    return r + (cfg.openMargin or 200.0)
end

--- Draw circle 1 off this match's stream and keep it for enterPhase to spend.
---
--- ONE SPELLING FOR THE TWO PLACES IT HAPPENS: at warmup, for the preview, and in
--- BR.Storm.begin for a route that never had a warmup. Both hand drawCentre
--- phase 1 from the anchor across the opening circle -- the arguments enterPhase
--- would use -- so where it happens decides only when the value comes off the
--- stream.
--- @param m table
--- @param a table      the match anchor
--- @param r0 number    the opening radius of it
--- @return table       m.stormFirst
local function drawFirst(m, a, r0)
    local cx1, cy1, brokeOut = drawCentre(m, 1, a.x, a.y, r0)
    -- THREE FIELDS AND NOT FOUR. The opening radius this was drawn against is
    -- deliberately not kept: BR.Storm.begin recomputes it from the same anchor
    -- (which nothing can change between here and there -- BR.Bus.plan sets it once)
    -- so a stored copy would be a second source of truth with no reader.
    -- `brokeOut` IS read: enterPhase lifts the sweep's time ceiling for a phase
    -- whose circle left its predecessor, and that fact is decided by the draw.
    m.stormFirst = { cx = cx1, cy = cy1, r = cfg.phases[1].radius,
                     brokeOut = brokeOut }
    return m.stormFirst
end

--- What a client is told about circle 1 before the storm exists: one circle,
--- standing still, with no clock in it.
--- @param m table
--- @return table|nil
--- THE SEED IS IN IT, because the preview is a WALL as well as a ring (#327, #340)
--- and every wall is a shape now (#344). Without it the bus would be shown a circle
--- that changes into phase 1's blob as the real wall fades in over it -- two
--- different shapes on one circle, across a handoff written to be seamless. It is
--- the same seed the record will carry, so the preview curtain IS phase 1's wall.
---
--- ═══ PUBLIC, BECAUSE THE SNAPSHOT SENDS THE SAME THING AND USED TO SPELL IT
---     ITSELF ═══
---
--- server/broadcast.lua's viewFor puts this circle in the join snapshot, so a
--- br_ui restart or a reconnect mid-warmup gets it back. It built its own copy of
--- the table, which was two spellings of one payload -- and the day the payload
--- grew a field (#344's seed) only one of them grew it: the room saw phase 1's
--- shape and a reconnecting client saw a circle. So there is one function and the
--- snapshot calls it.
--- @param m table
--- @return table|nil
function BR.Storm.previewPayload(m)
    local f = m and m.stormFirst
    if not f then return nil end
    return { cx = f.cx, cy = f.cy, r = f.r, seed = m.stormSeed }
end
local previewPayload = BR.Storm.previewPayload

--- Draw circle 1 the moment the match forms, and tell the room where it is.
---
--- ═══ THE EARLIEST INSTANT THE ANSWER EXISTS (#327, owner 2026-09-21) ═══
---
---   "We don't need to change where the circle goes - just determine circle 1's
---    location upon the first player in the match completing matchmaking, and
---    show the blip starting from then."
---
--- NOTHING ABOUT THE STORM MOVES FOR THIS. The problem #327 opened with was that
--- a preview drawn from the ANCHOR would be a lie -- phase 1's real centre is
--- rolled with the whole map as slack, so it can land nowhere near the anchor. The
--- owner's answer dissolves that rather than solving it: make the draw happen
--- earlier and the preview shows the real circle 1 because it IS circle 1. The
--- schedule, the radii, the solver and the damage rule are all untouched; only the
--- timing of one draw changed.
---
--- CALLED FROM THE WARMUP BRANCH OF BR.Match.onEnter, immediately after
--- BR.Bus.plan(m) -- which is what picks m.anchor, and is therefore the earliest
--- moment everything phase 1 needs is on the table: the anchor, the opening radius
--- of it, and cfg.phases[1].radius.
---
--- ═══ IT TOUCHES THE STREAM, SO IT REFUSES TO RUN TWICE ═══
---
--- The guard is on m.stormRng rather than on m.stormFirst, and that is deliberate:
--- the thing that must happen once is not "store a circle", it is "advance the
--- sequence". enterPhase nils m.stormFirst as it spends it, so a guard on the
--- circle would let a second call through after PLAYING began and quietly reroll
--- the rest of the match from a fresh seed.
---
--- NO ANCHOR MEANS NO PREVIEW AND NO SEED. `brforce warmup` on an empty box can
--- reach this before a route exists; BR.Storm.begin still draws for itself in that
--- case, exactly as it did before this function existed.
--- @param m table
function BR.Storm.drawFirstCircle(m)
    if not m or not m.anchor then return end
    if m.stormRng then return end

    seedRng(m)

    local a = m.anchor
    local f = drawFirst(m, a, openingRadius(a.x, a.y))

    print(('[br_core] storm: match %s circle 1 drawn at warmup -- (%.0f, %.0f) r %.0f, off anchor %s')
        :format(BR.MatchTag(m.id), f.cx, f.cy, f.r, tostring(a.name)))
    BR.Broadcast.toMatch(m, BR.Net.STORM_PREVIEW, previewPayload(m))
end

--- A late joiner needs the circle the room has been looking at.
---
--- The same shape as BR.Bus.sendPreview and called from the same two places in
--- server/party.lua, for the same reason: a player attached to a match that is
--- already in WARMUP receives no transition, so nothing else would ever tell them.
--- Silent once PLAYING starts, because enterPhase has spent the circle by then and
--- late joining is WARMUP-only anyway.
--- @param m table
--- @param src integer
function BR.Storm.sendPreview(m, src)
    local payload = m and previewPayload(m)
    if payload then
        TriggerClientEvent(BR.Net.STORM_PREVIEW, src, payload)
    end
end

--- Start a match's storm. Called when it goes PLAYING: the clock starts when
--- 65% of the match is down (#352) and the first circle is on the map
--- immediately (user call, 2026-08-02) -- the free-loot time is phase 1's
--- wait, not a separate pre-phase.
--- @param m table
function BR.Storm.begin(m)
    local a = m.anchor
    if not a then
        -- brforce playing from nothing skips warmup, so no route -- and no
        -- anchor -- was ever drawn. Any POI beats no storm.
        local poi = BR.Rng(GetGameTimer()):pick(BR.Config.Map.POIs)
        a = { x = poi.x, y = poi.y, name = poi.name, poi = poi.id }
        m.anchor = a
    end

    -- SEEDED HERE ONLY IF WARMUP DID NOT ALREADY DO IT (#327). Circle 1 is drawn
    -- the moment the match forms, and that draw is what seeds the stream; this
    -- call is the fallback for the routes that never had a warmup. Reseeding
    -- would restart the sequence and hand phase 2 the value phase 1 already
    -- spent -- see seedRng's header for why that failure is invisible.
    seedRng(m)
    m.stormCarry = {}

    -- CIRCLE 1 IS ON THE TABLE BEFORE PHASE 1 IS ENTERED, because the hold below
    -- is priced on it. Warmup drew it (#327); a route that never had a warmup draws
    -- it here -- the draw enterPhase would otherwise have made, off the same stream
    -- -- and enterPhase spends it either way.
    local r0 = openingRadius(a.x, a.y)
    local f = m.stormFirst or drawFirst(m, a, r0)

    -- ═══ THE FREE-LOOT HOLD IS PRICED ON WHERE THE PLAYERS ARE AGAINST CIRCLE 1 ═══
    --
    --   "change the phase 1 hold please, based on location of the players as we
    --    said."                                       -- owner, 2026-09-23 (#364)
    --
    -- The FURTHEST living player's distance to circle 1's wall, at
    -- hold.metersPerSec. Anyone inside it pays nothing, so a lobby that landed in
    -- circle 1 waits the one-minute floor; only the run in from outside its edge
    -- buys time. LOBBY bystanders are not participants and never lengthen it.
    --
    -- THE SAME WALL THE 75% CUT COUNTS AGAINST. circleOneZone is asked of the record
    -- enterPhase is about to build -- same seed, same phase, same circle, only the
    -- clock missing -- so both phase-1 rules agree on who is inside, and it is the
    -- boundary phase 1's sweep ends on. A radius test would charge a player standing
    -- in a corner past r and let one in a dent inside r ride free.
    --
    -- (Until #364 this measured from the match anchor, which circle 1 has not sat
    -- on since #327.)
    local zone = circleOneZone(BR.BuildStormRecord(1, a.x, a.y, r0,
        f.cx, f.cy, cfg.phases[1].radius, 0, 0, 0, 0, m.stormSeed))
    local furthest = 0.0
    BR.Roster.each(
        function(e) return e.matchId == m.id and BR.Server.isInMatch(e.state) end,
        function(_, e)
            if e.pos then
                local d = BR.StormShape.distance(zone, e.pos.x, e.pos.y)
                if d > furthest then furthest = d end
            end
        end)
    -- Floor at hold.minSeconds, NOT phases[1].wait: an all-inside drop
    -- waits one minute, not two (user call, 2026-08-04 -- "why does it
    -- take 3 minutes for the storm to form?"). The authored wait remains
    -- the schedule for LATER phases.
    local holdSec = BR.Clamp(furthest / cfg.hold.metersPerSec,
        cfg.hold.minSeconds or cfg.phases[1].wait, cfg.hold.maxSeconds)

    -- THE WALL MOVES WITHIN THREE MINUTES, whatever the drop spread priced:
    -- the stationary wait caps at startCapSeconds. The far straggler's time goes
    -- into phase 1's sweep instead, which enterPhase prices on their run.
    local waitSec = math.min(holdSec, cfg.hold.startCapSeconds or holdSec)

    print(('[br_core] storm: match %s homing on %s (%.0f, %.0f) -- opening r %.0f, hold %.0fs (furthest %.0fm outside circle 1)')
        :format(BR.MatchTag(m.id), tostring(a.name), a.x, a.y, r0, waitSec,
                furthest))
    -- AND THE 75% CUT STILL APPLIES: enterPhase asks capFirstHold before it
    -- publishes, so a lobby already that far in is sent 1:30 at most from the start.
    enterPhase(m, 1, a.x, a.y, r0, GetGameTimer(), waitSec)

    -- A MATCH STARTED UNDER A FREEZE INHERITS IT. Without this, freezing the
    -- storm and then starting a fresh match quietly gives you a live one --
    -- which is the failure you would not notice until the wall was on top of
    -- you, an hour into whatever you were actually testing.
    --
    -- THE FROZEN RECORD KEEPS CIRCLE 1 AS ITS TARGET, as every frozen record keeps
    -- the target it froze under (see brstormfreeze): the wall it holds is the opening
    -- zone, and a target pinned to the opening circle instead would be zone 1's shape
    -- blown up to the whole map's radius, drawn beside it.
    if BR.Storm.isFrozen and BR.Storm.isFrozen() then
        local now = GetGameTimer()
        local live = m.storm
        m.storm = BR.BuildStormRecord(1, a.x, a.y, r0, live.cx1, live.cy1, live.r1,
            now, 24 * 60 * 60 * 1000, 1000, 0.0, m.stormSeed)
        publish(m)
        print(('[br_core] storm: match %s starts FROZEN (brstormfreeze is on)')
            :format(BR.MatchTag(m.id)))
    end
end

--- Which player states the storm can hurt. Airborne players are untouchable
--- -- they cannot steer out of a wall they are falling through, and the drop
--- grace exists for the same reason -- and lobby/warmup are not in the match.
---
--- ═══ A VEHICLE IS NOT ON THIS LIST AND NEVER WILL BE (owner, 2026-08-21, #194
---     question 4) ═══
---
---   "no, vehicles will never grant storm immunity. that's not a thing. the
---    only exception is the ambulance and ONLY while they're in `rescue` state
---    - so if they hop in an ambulance and drive off they are not granted any
---    sort of immunity."
---
--- WHICH IS WHAT THIS FILE ALREADY DOES, and #194 §4 established that before the
--- question was asked: the damage loop below is a position check against the
--- solved circle and a server-side ledger. It holds no ped handle and no vehicle
--- handle, so a player driving through the wall takes exactly what a player
--- walking through it takes. Nothing was added to keep it that way. The test in
--- tools/test_roster.lua's `storm.vehicles` block is what stops it drifting,
--- because "we never wrote the exemption" is not a property anything can check.
---
--- ═══ THE ONE EXCEPTION, NOW THAT #191 HAS LANDED ═══
---
--- This block used to say the exemption could not be written yet, because it was
--- conditioned on a `rescue` state that existed nowhere -- and a flag with no
--- writer is a flag that reads false forever while looking like a working
--- feature. #191 (the CPR kit) built the writer, so the sentence is code now:
--- `and not e.rescue` on the `BR.Roster.each` filter in `storm.damage` below,
--- which is exactly the one-condition change this block specified in advance.
---
--- THE TWO PROHIBITIONS IT WAS WRITTEN WITH ARE BOTH HONOURED, and they are
--- restated rather than deleted because they are what makes the flag safe:
---
---   * NOT A CLIENT-ASSERTED FLAG. Storm damage is the subsystem specifically
---     built so a client cannot influence it (#194 §4); an exemption a client can
---     assert is storm immunity a client can assert. `e.rescue` is written in
---     exactly two places, both in server/rescue.lua -- when the server GRANTS a
---     rescue and when it ENDS one -- and no net event sets it. There is no
---     client->server event in this whole feature that carries a payload at all.
---   * NOT A TEST ON THE VEHICLE. The owner's rule is about the rescue, not about
---     the ambulance -- a player who drives one off has no exemption, so a model
---     check would grant exactly the thing that sentence refuses. Nothing below
---     reads a model, a vehicle handle or a seat; the flag is on the PLAYER, and
---     it is set only for a player the server itself put in an ambulance.
---
--- AND IT IS BOUNDED. server/rescue.lua's deadline is checked unconditionally on
--- every tick and every path out of a rescue clears the flag, so there is no
--- branch on which a player stays exempt -- which matters more here than
--- anywhere else, because the failure would be silent and would look exactly
--- like a player who is simply good at staying inside the circle.
local DAMAGEABLE = {
    [BR.PlayerState.ALIVE] = true,
    [BR.PlayerState.DBNO]  = true,
}

-- Phase advancement. 1 Hz is plenty: a phase is minutes long, and the solver
-- is what answers "where is the wall NOW" -- this job only notices a finished
-- shrink and authors the next record.
BR.Sched.every(1000, 'storm.phase', function()
    BR.Server.eachMatch(function(m)
        if m.state ~= BR.MatchState.PLAYING or not m.storm then return end

        -- FIRST, so a hold cut on this tick is the record the rest of the tick
        -- reads (#352). It only acts during phase 1's hold.
        capFirstHold(m, GetGameTimer())

        local rec = m.storm
        local _, _, _, st = BR.StormAt(rec, GetGameTimer())

        -- BEFORE the advance, not after. The advance replaces `m.storm` with a
        -- record that is HOLDING again, so a cue evaluated afterwards would be
        -- reading the NEXT phase's hold and would never fire at all.
        cueMovementOnce(m, st)
        cueStopOnce(m, st)

        if st == BR.StormPhase.FINISHED and rec.phase < #cfg.phases then
            enterPhase(m, rec.phase + 1, rec.cx1, rec.cy1, rec.r1, GetGameTimer())
        end
        -- The final phase just stays FINISHED at radius 0: everyone still
        -- outside (which is everywhere) keeps taking the last phase's dps
        -- until the win condition ends the match.
    end)
end)

-- Damage. Positions come from the roster's own server-side sampling -- never
-- from anything a client reported -- so a position-lying client gains nothing
-- here.
BR.Sched.every(1000, 'storm.damage', function(dt)
    local now = GetGameTimer()

    BR.Server.eachMatch(function(m)
        if m.state ~= BR.MatchState.PLAYING or not m.storm then return end

        local rec = m.storm
        local cx, cy, r, st, _, dps, t = BR.StormAt(rec, now)
        if dps <= 0 then return end

        -- THE EDGE CUSHION. During a shrink the wall moves METRES PER SECOND
        -- (phase 1 sweeps >150 m/s), and three clocks disagree at the knife
        -- edge: this tick, the most recent 4 Hz position sample, and the
        -- client's own view of the circle. Damage therefore starts a margin
        -- OUTSIDE the solved radius -- a base allowance plus ~0.7s of wall
        -- travel -- so a player standing at the visible curtain is always
        -- genuinely safe (live reports: hurt while 20-50ft inside the wall).
        --
        -- UNCHANGED BY THE UNION BELOW, and it means the same thing it always
        -- did: the cushion is metres of slack OUTSIDE the edge of the safe
        -- zone, whatever shape that edge is. It is the same three clocks and
        -- the same wall speed; nothing about a second circle makes any of them
        -- agree better.
        local margin = 10.0
        if st == BR.StormPhase.SHRINKING then
            margin = margin
                + ((rec.r0 - rec.r1) / math.max(rec.tShrink / 1000.0, 1.0)) * 0.7
        end

        -- ═══ THE SAFE ZONE IS BOTH CIRCLES, NOT ONLY THE ONE THE WALL IS ON ═══
        --
        --   "take for example 2 storm circles (current and next) which are
        --    barely overlapping - like a venn diagram. We should extend the
        --    safezone to cover both circles, so if a player gets to the new
        --    destination early they are safe. That logic also doesn't exist
        --    today."                                     -- owner, 2026-09-21
        --
        -- THE FAILURE IT PREVENTS. A player who read the map, saw the purple
        -- ring and ran to it before the wall set off was billed for the whole
        -- trip and billed again for standing in the destination. That is the
        -- storm punishing the one thing it exists to force, and it was worst on
        -- exactly the phases the breakout was built to create -- the ones where
        -- the next circle barely overlaps the current one or does not overlap
        -- it at all.
        --
        -- ═══ WHY THIS IS SAFE TO SHIP: ON AN ORDINARY PHASE IT IS A NO-OP ═══
        --
        -- The next circle is normally NESTED inside the current one, and the
        -- union of a circle with a circle inside it IS the outer circle --
        -- union2 returns precisely that, by its first case, so the set of
        -- players this tick hurts is the same set it hurt yesterday. The rule
        -- only has an effect when the circles are NOT nested, which is the case
        -- the owner is describing and the only case BR.NextZoneCentre's
        -- breakout can produce.
        --
        -- TWO DISJOINT CIRCLES ARE TWO SAFE ISLANDS WITH AN UNSAFE GAP BETWEEN
        -- THEM, and that is the intended reading rather than a case wanting its
        -- own rule: "the far circle should be safe, that's fine" (owner, same
        -- day). A player who has crossed to the far circle has earned it.
        --
        -- IT HOLDS FOR THE WHOLE PHASE, holding and shrinking both, and it is
        -- self-closing: the two circles converge as the sweep runs and the
        -- union collapses onto the one circle exactly when the sweep ends.
        --
        -- BUILT ONCE PER TICK, NOT ONCE PER PLAYER. The zone is a function of
        -- the record and the clock and of nothing a player carries, so it
        -- belongs out here rather than inside the roster walk, where sixty
        -- players would each rebuild the same two discs.
        --
        -- ═══ THE FINAL PHASE'S DESTINATION IS A POINT, AND A POINT IS NOT A
        --     SECOND CIRCLE TO REACH ═══
        --
        -- config/storm.lua's phases[8] closes on `radius = 0.0`. This block used
        -- to say that union2 floored it at one metre and that one metre inside a
        -- cushion of ten changed nothing a player could stand in. It changed two
        -- things. A one-metre disc more than about 35 metres from the current
        -- circle's centre is a SEPARATE COMPONENT, and phase 8's reachable offset
        -- is up to 60 metres (r 40 plus gapMax half of it) -- so the wall drew a
        -- 4.8m wide, 950m tall pillar on the exact point everyone was fighting
        -- over, and this rule sheltered an eleven-metre bubble on it for the whole
        -- sweep: a safe island detached from the wall in the endgame, which is the
        -- failure `server.collapse` exists to prevent at the other end of the
        -- phase.
        --
        -- The constructor NOW REFUSES A DISC WITH NO RADIUS, so neither happens and
        -- the two files cannot disagree about whether that disc exists -- they are
        -- looking at the same constructor. Its header argues the decision. On phase
        -- 8 this reads exactly `r + margin` against the travelling wall, which is
        -- what it read before #328, and the destination is sheltered when the wall
        -- actually arrives on it rather than for the minute beforehand.
        --
        -- ═══ AND THE ZONE IS A SHAPE, NOT A PAIR OF CIRCLES (#344) ═══
        --
        -- BR.StormZone is the same call client/storm.lua's wall and HUD make, off
        -- the same record and the same solved circle, so what this bills for is
        -- exactly the boundary the player is looking at. That is not a tidiness
        -- claim: the shape is derived from the record's seed rather than sent, so
        -- one side spelling the derivation differently is a wall in the wrong place
        -- with nothing on the wire to contradict it.
        --
        -- EXACT ON AN OVERLAPPING BREAKOUT TOO: a signed distance to a union is the
        -- minimum of the two, which holds for any two shapes.
        --
        -- AND EXACT MID-MORPH. `t` is the sweep fraction this tick solved, which is
        -- what the wall's own frame passes, so the shape billed is the shape drawn
        -- -- and a morph is a corner list like any other, with an exact signed
        -- distance rather than a bound on one (storm_shape.lua's morph section).
        local zone = BR.StormZone(rec, cx, cy, r, t)

        -- Capped so a long scheduler stall (or a test jumping the clock)
        -- cannot land one apocalyptic tick.
        local dtSec = math.min((dt and dt > 0) and (dt / 1000.0) or 1.0, 3.0)
        local carry = m.stormCarry or {}
        m.stormCarry = carry

        BR.Roster.each(
            -- `not e.rescue` IS #191'S AMBULANCE EXEMPTION and is the only
            -- exception to "a vehicle never grants storm immunity" that will
            -- ever exist here. See the block above DAMAGEABLE for the two things
            -- it is forbidden from becoming.
            function(e)
                return e.matchId == m.id and DAMAGEABLE[e.state] and not e.rescue
            end,
            function(src, e)
                if not e.pos then return end   -- not sampled yet (OneSync warning covers why)

                -- A SIGNED DISTANCE AGAINST THE ZONE, WHICH IS WHAT `<= r +
                -- margin` ALWAYS WAS. distance() is negative inside and
                -- positive outside, so the radius is simply folded into the
                -- shape and the comparison is the same comparison.
                --
                -- IT READS THE SIGN AND A MAGNITUDE FROM OUTSIDE, WHICH IS
                -- WHERE IT IS EXACT. distance() is the minimum of the two disc
                -- distances, so it understates DEPTH strictly inside the lens
                -- where the two discs overlap -- never the other way, and never
                -- anywhere out here. Its header carries the numbers. This line
                -- asks only whether a player is further outside than the
                -- cushion allows, and that answer is exact.
                if BR.StormShape.distance(zone, e.pos.x, e.pos.y) <= margin then
                    -- Inside: the ledger re-seeds from sampled reality next
                    -- time they are caught out.
                    e.stormHp  = nil
                    carry[src] = nil
                    return
                end

                -- A DOWNED PLAYER OUT HERE BLEEDS, and that is the whole of
                -- it. The bleed timer is their health (see the DBNO section
                -- of server/combat.lua), so the storm subtracts seconds from
                -- it exactly as a bullet does -- one rule rather than a
                -- second, parallel notion of storm health for downed
                -- players. No STORM_DAMAGE is sent: their ped is held at the
                -- ledger floor and the accelerating countdown on their own
                -- screen is the feedback.
                if e.state == BR.PlayerState.DBNO then
                    e.lastStormAt = now
                    BR.Combat.bleed(src, dps * dtSec, nil, nil)
                    return
                end

                -- THE LEDGER. Seeded from the sampled display hp, then
                -- decremented server-side every tick they spend outside.
                -- min() with the sample keeps it honest when the player is
                -- ALSO being shot: the ledger may never lag above reality,
                -- only refuse to be lied upward. (M6's reconciliation sweep
                -- replaces this with the full model.)
                local display = e.stormHp or e.hp or 100.0
                if e.hp and e.hp < display then display = e.hp end
                display = display - dps * dtSec
                e.stormHp     = display
                e.lastStormAt = now

                -- The visible half: tell the client to hurt its ped. Engine
                -- units, whole numbers, fraction carried forward so 1 dps
                -- rounds to two engine points per second instead of nothing.
                local engine = BR.ToEngineHpDelta(dps * dtSec) + (carry[src] or 0.0)
                local whole  = math.floor(engine)
                carry[src]   = engine - whole
                if whole > 0 then
                    TriggerClientEvent(BR.Net.STORM_DAMAGE, src, {
                        amount      = whole,
                        armourFirst = cfg.damageArmourFirst and true or false,
                    })
                end

                -- Elimination comes from the LEDGER, not the ped. An honest
                -- client's ped dies at the same moment anyway; a deaf one
                -- dies here regardless.
                if display <= 0 then
                    print(('[br_core] storm: ledger kill on %s (%d)')
                        :format(e.name, src))
                    -- defeat(), not eliminate(): the wall knocks a squad
                    -- player down like anything else does. It is a bad place
                    -- to be picked up, which is the point.
                    BR.Combat.defeat(src, 'storm', nil)
                end
            end)
    end)
end)

-- ---------------------------------------------------------------- admin ---

RegisterCommand('brphase', function(_, args)
    local m = BR.Server.latestMatch()
    local n = tonumber(args[1])
    if not n or not cfg.phases[n] then
        print(('  usage: brphase <1-%d>   current: %s'):format(#cfg.phases,
            (m and m.storm) and tostring(m.storm.phase) or 'no storm'))
        return
    end
    if not m or m.state ~= BR.MatchState.PLAYING then
        print('  the storm only runs during PLAYING (brforce playing first)')
        return
    end
    if not m.storm then BR.Storm.begin(m) end

    -- Enter phase n from wherever the wall is RIGHT NOW, so the jump is
    -- seamless on every client.
    --
    -- AND IN THE SHAPE IT IS STANDING IN, WHEN THAT IS A SHAPE PHASE n CAN START
    -- FROM. Re-entering the same phase carries the wall's own outline, every corner
    -- still heading for the corner it was heading for; a finished sweep is already
    -- zone n-1 for phase n+1. A jump to any other phase takes zone n-1's shape,
    -- which is a jump the admin asked for.
    local rec = m.storm
    local cx, cy, r, _, _, _, t = BR.StormAt(rec, GetGameTimer())
    local mo = (n == rec.phase) and BR.StormMorphAt(rec, t) or nil
    print(('[br_core] admin: match %s storm jumped to phase %d')
        :format(BR.MatchTag(m.id), n))
    enterPhase(m, n, cx, cy, r, GetGameTimer(), nil, mo)
end, true)

--- FREEZE THE STORM WHERE IT STANDS. Dev mode only.
---
---   brstormfreeze          freeze every live match's wall at its current
---                          radius: no more phases, no more damage
---   brstormfreeze off      thaw -- re-enter the current phase from where the
---                          wall is now, so the resume is seamless
---
--- Exists so a match can be left running indefinitely while something else is
--- being tested, without the storm eventually deciding the session (user,
--- 2026-08-08). The alternative -- `brstormscale 1.0` and racing it -- makes
--- every long test a stopwatch.
---
--- IMPLEMENTED AS A RECORD, NOT A FLAG, and that is the whole trick. Skipping
--- the phase job would not have worked: BR.StormAt solves the wall from the
--- record's own timeline, so the circle would go on shrinking to r1 and sit
--- there at FINISHED with the last phase's dps still burning. Instead the
--- current record is REPLACED with one that starts wherever the wall is this
--- instant -- its circle, and its outline in `mo` -- keeps the target it had,
--- deals dps 0, and holds long enough to outlast any session. Every client
--- solves that to a stationary, harmless wall with no special case at either
--- end, and nothing else in the file needs to know.
local frozen = false

RegisterCommand('brstormfreeze', function(_, args)
    if not BR.Server.devMode then
        print('  brstormfreeze is dev-mode only (br_devMode true)')
        return
    end

    local thaw = (args[1] == 'off' or args[1] == 'thaw')
    local now = GetGameTimer()
    local touched = 0

    BR.Server.eachMatch(function(m)
        if not m.storm then return end
        local live = m.storm
        local cx, cy, r, _, _, _, t = BR.StormAt(live, now)
        local phase = live.phase
        -- THE OUTLINE THE WALL IS STANDING IN, as far as it had morphed -- every
        -- moving disc and the destination disc it is heading for. Carried into the
        -- frozen record and out of it again, so neither end of a freeze snaps the
        -- wall back to the zone it set out from.
        local mo = BR.StormMorphAt(live, t)

        if thaw then
            -- Re-enter the phase we were in, from where the wall is now.
            enterPhase(m, phase, cx, cy, r, now, nil, mo)
        else
            -- A day of holding. Long enough that no session outlives it, and
            -- still a real number rather than an infinity that would poison
            -- every subtraction the clients do with it.
            -- THE SEED SURVIVES A FREEZE, so the wall keeps the shape it was
            -- standing in rather than reverting to a circle for the whole freeze.
            -- AND SO DOES THE TARGET, so a breakout frozen part way across still
            -- shows -- and shelters -- the destination it was running to, rather
            -- than dropping it for the length of the freeze.
            m.storm = BR.BuildStormRecord(phase, cx, cy, r, live.cx1, live.cy1, live.r1,
                now, 24 * 60 * 60 * 1000, 1000, 0.0, live.seed, mo)
            publish(m)
        end
        touched = touched + 1
    end)

    frozen = not thaw
    print(('[br_core] storm %s (%d match%s)'):format(
        thaw and 'THAWED -- phases and damage resume'
             or 'FROZEN -- no phases, no damage, wall stays put',
        touched, touched == 1 and '' or 'es'))
    if not thaw and touched == 0 then
        print('  (no live storm yet -- it will freeze as soon as one starts)')
    end
end, true)

--- Is the storm currently held by brstormfreeze?
--- Read by BR.Storm.begin so a match starting AFTER the freeze inherits it
--- rather than quietly running a live storm under a frozen session.
--- @return boolean
function BR.Storm.isFrozen() return frozen end

--- Drop the freeze at the end of a match.
---
--- A DEBUG SWITCH SHOULD NOT OUTLIVE THE THING IT WAS SET FOR (user call,
--- 2026-08-08). Freezing is something you do to hold ONE match still while
--- testing something else in it; carrying it into the next match means the
--- next round silently has no storm, and a battle royale with no storm never
--- ends -- which is a far more confusing failure than having to type the
--- command again.
---
--- Called from BR.Storm.clear, so it rides the teardown every match already
--- performs rather than needing its own hook.
function BR.Storm.thawOnMatchEnd()
    if not frozen then return end
    frozen = false
    print('[br_core] storm freeze lifted -- the match it was holding has ended')
end

RegisterCommand('brstormscale', function(_, args)
    local s = tonumber(args[1])
    if not s then
        print(('  usage: brstormscale <0.05-1.0>   current: %.2f'):format(timeScale))
        print('  scales wait/shrink of every phase built AFTER this; brphase to apply now')
        return
    end
    timeScale = BR.Clamp(s, 0.05, 1.0)
    print(('[br_core] storm time scale = %.2f (~%.0f min cycle)')
        :format(timeScale, cfg.TotalSeconds() * timeScale / 60.0))
end, true)

-- `brstorm` LIVES IN server/debug.lua, NOT HERE (#137). Both files registered it
-- in the same Lua state and debug.lua loads later, so this version never ran
-- once. Deleted rather than renamed: the surviving one answers the same question
-- and two commands for one question is how the collision happened. Anything this
-- printed that the other does not should move there, not come back here.
