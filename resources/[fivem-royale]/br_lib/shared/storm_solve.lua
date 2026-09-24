-- Storm solver.
--
-- The single most important property here: this is a PURE FUNCTION of a record
-- the server published once, plus the current time. Server and client both call
-- it and both get the same answer, so a shrinking storm costs zero per-frame
-- network traffic. The server uses it to apply damage; the client uses it to draw
-- the wall. Neither one streams the radius to the other.
--
-- Load order: requires enums.lua and geo.lua. storm_shape.lua is asked for at call
-- time only, so it may load either side of this file.

BR = BR or {}

--- The record shape published by the server (whole-table assignment only --
--- nested mutation of a state bag does not replicate):
---
---   {
---     phase   = 0,        -- 0 = pre-storm hold, 1..n = phase index
---     cx0, cy0, r0,       -- current circle
---     cx1, cy1, r1,       -- circle being shrunk toward
---     tStart,             -- server time this phase began
---     tWait,              -- ms held static before shrinking
---     tShrink,            -- ms spent interpolating
---     dps,                -- damage per second outside the circle
---     seed,               -- the match's storm seed: what SHAPE this is (#344)
---     mo,                 -- the wall's own outline when this record began, for
---                         --   the records that start part way through a morph;
---                         --   absent on every ordinary record
---   }
---
--- `seed` IS ON THE WIRE BECAUSE THE SHAPE CANNOT BE. Every zone is a random
--- shape now, the client draws the wall and the server does the damage, and
--- neither sends geometry -- so both derive the shape from this one integer plus
--- the zone index. See BR.StormZone below, which is the only spelling of that
--- derivation anywhere, and BR.StormShape.blobUnit, which is where it happens.
---
--- ═══ `mo` IS THE ONE EXCEPTION, AND IT IS A DEV PATH ═══
---
--- Phase p's wall starts as zone p-1 and morphs corner to corner into zone p across
--- the sweep, so an ordinary record starts as a zone -- which is what an absent
--- field reads as, and what every record but three is. `brstormfreeze` replaces a
--- record mid-sweep with one that holds the wall where it stands, its thaw re-enters
--- the phase from there, and a same-phase `brphase` does the same; all three start
--- from a wall that is NOT a zone but a moment of a morph. So they carry it:
---
---   mo = { t = <how far the morph had got>,
---          d = { x1, y1, r1, x2, y2, r2, ... },   -- every moving disc, world
---          b = { i1, i2, ... },                   -- the destination disc each
---                                                 --   one is travelling to
---          g = <how far a conjoined zone had grown> }   -- a freeze's only
---
--- -- the discs exactly, rather than the two circles they were computed from,
--- because a freeze of a thawed record is a morph of a morph, and only the discs
--- themselves compose. Each keeps its destination index, so a thaw and a same-phase
--- `brphase` resume every corner toward the corner it was heading for, without a
--- snap. (BR.StormMorphAt builds it.) `g` rides a freeze, which keeps the target, so
--- a zone frozen part way through growing into its destination neither shrinks back
--- to where it started nor grows the same ground twice.

--- How long a conjoined zone takes to grow into its destination, in ms: the
--- config's `grow.seconds`, and never longer than the hold it happens in, so the
--- growth is always over before the wall moves -- and a dev time scale that
--- shortens the hold shortens the growth with it. 0 is no growth: the old pop.
local function growMs(rec)
    local S = BR.Config and BR.Config.Storm
    local sec = S and S.grow and tonumber(S.grow.seconds) or 0.0
    local ms = sec * 1000.0
    local wait = rec.tWait or 0.0
    if wait < ms then ms = wait end
    return ms
end

--- How far a conjoined zone has grown at `elapsed` ms into its record: 0 at the
--- start of the hold, 1 once the growth window is over, and carried across a
--- freeze by `mo.g`. Pure, like everything else here -- the server's damage tick
--- and the client's wall read it off the same record and the same clock.
local function growthAt(rec, elapsed)
    local ms = growMs(rec)
    if ms <= 0.0 then return 1.0 end
    local g0 = (rec.mo and tonumber(rec.mo.g)) or 0.0
    return BR.Clamp(g0 + elapsed / ms, 0.0, 1.0)
end

--- Solve the storm at a given time.
---
--- @param rec table|nil   the published storm record
--- @param now number      server time in ms (BR.Clock.now())
--- @return number cx      current centre x
--- @return number cy      current centre y
--- @return number r       current radius
--- @return string state   one of BR.StormPhase
--- @return number msLeft  ms remaining in the current sub-phase
--- @return number dps     damage per second currently applied outside
--- @return number t       how far through the sweep: 0 holding, 1 finished --
---                        the same fraction the circle is interpolated by, and
---                        the one BR.StormZone moves every corner of the wall by
--- @return number g       how far a conjoined zone has grown into its destination
---                        (#344): 0 at the start of the hold, 1 once `grow.seconds`
---                        have passed -- always before the wall moves -- and read
---                        by BR.StormZone only on a phase whose destination
---                        overlaps the zone it starts in
function BR.StormAt(rec, now)
    if not rec then
        return 0.0, 0.0, 0.0, BR.StormPhase.PRE, 0.0, 0.0, 0.0, 1.0
    end

    local elapsed = now - rec.tStart
    local g = growthAt(rec, elapsed)

    -- Still holding: the next circle is already known and drawn on the map, so
    -- players can see where to rotate before the wall starts moving.
    --
    -- PHASE 1'S HOLD IS THE FREE-LOOT PERIOD AND DEALS NO DAMAGE ANYWHERE --
    -- the Fortnite rule: the whole map is safe until the first circle locks in
    -- and starts closing. The tour spans the entire map and the anchor rides
    -- one leg of it, so a far-end jumper can legitimately land kilometres
    -- outside circle 1; bleeding them for it before the wall has ever moved
    -- punishes the drop they were invited to make. From the first shrink
    -- onward -- including every LATER phase's hold -- outside always hurts.
    -- Decided HERE, in the solver, so the server's damage tick and the
    -- client's vignette cannot disagree about it.
    if elapsed < rec.tWait then
        local state = (rec.phase == 0) and BR.StormPhase.PRE or BR.StormPhase.HOLDING
        local dps = (rec.phase <= 1) and 0.0 or rec.dps
        return rec.cx0, rec.cy0, rec.r0, state, rec.tWait - elapsed, dps, 0.0, g
    end

    local shrinkElapsed = elapsed - rec.tWait

    -- Collapsed.
    if shrinkElapsed >= rec.tShrink then
        return rec.cx1, rec.cy1, rec.r1, BR.StormPhase.FINISHED, 0.0, rec.dps, 1.0, g
    end

    local t = shrinkElapsed / rec.tShrink

    return BR.Lerp(rec.cx0, rec.cx1, t),
           BR.Lerp(rec.cy0, rec.cy1, t),
           BR.Lerp(rec.r0,  rec.r1,  t),
           BR.StormPhase.SHRINKING,
           rec.tShrink - shrinkElapsed,
           rec.dps,
           t,
           g
end

--- THE SHAPE ONE ZONE WEARS, as a unit to be scaled by the solver's radius.
---
--- One line, and it is the reason the client's wall and the server's damage test
--- cannot disagree: both reach it, so there is no second spelling of "which shape
--- is this" to drift. The knobs live in config/storm.lua's `shape` block and a
--- corner count below three is the documented way back to circles.
---
--- ═══ A ZONE, NOT A PHASE ═══
---
--- Zone k is the zone phase k closes on, and zone 0 is the opening zone -- the map
--- disc. A record for phase p therefore holds TWO zones -- its wall starts as zone
--- p-1 and its target is zone p -- and BR.StormZone asks for both by their own
--- index. This used to be asked once, for the phase, and handed to both: the
--- moment the phase advanced, the circle the wall had just finished closing onto
--- re-rolled in place. That is the snap in #344's 2026-09-23 playtest, and it is
--- why the argument is a zone.
---
--- ═══ AND THE PHASES RIDE ALONG, BECAUSE THE ZONES ARE A CHAIN ═══
---
--- Zone z is drawn to fit inside zone z-1 at the ratio of their radii, so the
--- config's phase table is part of what a zone is. See BR.StormShape.blobUnit.
--- @param seed number|nil    the record's seed (server/storm.lua's seedRng)
--- @param zone number|nil    0 for the opening zone, k for phase k's target
--- @return table|nil unit
function BR.StormUnit(seed, zone)
    local S = BR.Config and BR.Config.Storm
    return BR.StormShape.blobUnit(seed, zone, S and S.shape, S and S.phases)
end

-- ═══ WHAT ONE RECORD'S MORPH IS MADE OF, WORKED OUT ONCE PER RECORD ═══
--
-- A record names two zones and where they stand, and everything the wall does
-- across the sweep follows from four lists: the discs the wall starts as (`src`),
-- where each of them is going (`dst`), the index of that destination disc in the
-- target zone's own list (`bi`), and the target zone's discs as placed (`keep`).
-- And one verdict: whether the target lies ENTIRELY inside the zone the wall
-- starts as -- by real shape, exactly (BR.StormShape.fit), which is what
-- BR.NextZoneCentre places every non-breakout target to satisfy.
--
-- Held weakly per record, and re-derived if any field it was read from has moved
-- or a zone unit has been rebuilt: a record is whole-table-assigned everywhere in
-- the game, so this is a cache hit on every frame of a phase but the first.
local recInfo = setmetatable({}, { __mode = 'k' })

--- The source discs of a record: a morph's own discs when it carries one, and the
--- zone it starts as, paired with its target, otherwise.
local function sourceOf(rec, uA, uB)
    local src, bi = {}, {}
    local mo = rec.mo
    if mo then
        local d, b = mo.d or {}, mo.b or {}
        local nB = #uB.discs
        for i = 1, #b do
            local x, y, r = d[3 * i - 2], d[3 * i - 1], d[3 * i]
            if x and y and r then
                src[#src + 1] = { x = x, y = y, r = r }
                -- AN INDEX THE CURRENT UNIT DOES NOT HAVE -- a config edited under a
                -- frozen record -- travels to the target's first disc rather than
                -- to nothing.
                local k = math.tointeger(b[i]) or 1
                bi[#bi + 1] = (k >= 1 and k <= nB) and k or 1
            end
        end
        return src, bi
    end
    local ps = BR.StormShape.pairsOf(uA, uB)
    local cx, cy, r = rec.cx0, rec.cy0, rec.r0
    for i = 1, #ps do
        local p = ps[i]
        src[i] = { x = cx + r * p.a.x, y = cy + r * p.a.y, r = r * p.a.r }
        bi[i] = p.bi
    end
    return src, bi
end

--- The record's morph, worked out: see the section note. nil for the off switch.
local function infoOf(rec)
    local uB = BR.StormUnit(rec.seed, rec.phase)
    if not uB then return nil end
    local uA = nil
    if not rec.mo then uA = BR.StormUnit(rec.seed, (rec.phase or 1) - 1) end
    local e = recInfo[rec]
    if e and e.uA == uA and e.uB == uB and e.mo == rec.mo
        and e.phase == rec.phase and e.seed == rec.seed
        and e.cx0 == rec.cx0 and e.cy0 == rec.cy0 and e.r0 == rec.r0
        and e.cx1 == rec.cx1 and e.cy1 == rec.cy1 and e.r1 == rec.r1 then
        return e
    end

    local SS = BR.StormShape
    local src, bi = sourceOf(rec, uA, uB)
    local r1 = ((rec.r1 or 0.0) > 0.0) and rec.r1 or 0.0
    local keep = {}
    if r1 > 0.0 then
        for k, d in ipairs(uB.discs) do
            keep[k] = { x = rec.cx1 + r1 * d.x, y = rec.cy1 + r1 * d.y, r = r1 * d.r }
        end
    else
        -- A TARGET OF NO RADIUS IS ONE POINT, whatever unit it was drawn with.
        keep[1] = { x = rec.cx1 + 0.0, y = rec.cy1 + 0.0, r = 0.0 }
    end
    local dst = {}
    for i = 1, #src do dst[i] = keep[bi[i]] or keep[1] end

    -- NESTED, BY REAL SHAPE. Every disc of the target inside the zone the wall starts
    -- as -- the hull of those discs is then inside it too, because it is convex.
    local zks = SS.discHull(src)
    local nested = zks ~= nil and SS.fit(zks, keep, 0.0, 0.0, 1.0) <= 0.0

    e = { uA = uA, uB = uB, mo = rec.mo, phase = rec.phase, seed = rec.seed,
          cx0 = rec.cx0, cy0 = rec.cy0, r0 = rec.r0,
          cx1 = rec.cx1, cy1 = rec.cy1, r1 = rec.r1,
          src = src, dst = dst, bi = bi, keep = keep, nested = nested }
    recInfo[rec] = e
    return e
end

--- Is this record's target inside the zone its wall starts as, by real shape?
---
--- True on every phase the server placed without a breakout (BR.NextZoneCentre),
--- and that is what the wall, the map and airdrop siting each read to know whether
--- the destination is a separate part of the safe zone or already inside it.
--- @param rec table
--- @return boolean
function BR.StormNested(rec)
    local e = rec and infoOf(rec)
    return e ~= nil and e.nested
end

--- Whether a record's destination OVERLAPS the zone its wall starts as without
--- being inside it -- the conjoined case, and the only one that grows -- and how far
--- it has to grow: S, the furthest any point of the destination is outside the zone.
---
--- ASKED ONCE PER RECORD, EXACTLY. The two shapes meet when the origin is inside
--- Z + (-D), which is a corner list (BR.StormShape.sumOf), so one signed distance
--- decides it. And D is the hull of its discs while the signed distance to Z is
--- convex, so the furthest point of D is at a disc: fitOf, the same maximum the
--- nesting test reads. A destination of no radius is a point and never grows; a
--- disjoint one is the far island the owner is content to see appear at once.
local function growthInfo(rec, e)
    if e.overlap ~= nil then return e.overlap, e.growS end
    local SS = BR.StormShape
    local over, S = false, 0.0
    if not e.nested and (rec.r1 or 0.0) > 0.0 then
        local zks, dks = SS.discHull(e.src), SS.discHull(e.keep)
        if zks and dks then
            over = SS.hullDistance(SS.sumOf(zks, SS.reflect(dks)), 0.0, 0.0) < 0.0
            if over then S = SS.fit(zks, e.keep, 0.0, 0.0, 1.0) end
        end
    end
    e.overlap, e.growS = over, S
    return over, S
end

--- Does this record's destination overlap, without nesting in, the zone its wall
--- starts as? Those are the phases whose safe zone GROWS into the destination
--- across the start of the hold instead of taking it all at once. See BR.StormZone.
--- @param rec table
--- @return boolean overlaps
--- @return number reach   metres the zone grows by across the whole growth
function BR.StormOverlaps(rec)
    local e = rec and infoOf(rec)
    if not e then return false, 0.0 end
    return growthInfo(rec, e)
end

--- The zone a record's wall starts as, placed at (cx, cy, r) -- the record's own
--- circle unless the caller names another. A morph's own outline when it carries
--- one (`mo`), and the zone before this phase's otherwise.
local function sourceShape(rec, e, cx, cy, r)
    if rec.mo then return BR.StormShape.discShape(e.src, cx, cy, r) end
    return BR.StormShape.blob(cx, cy, r, e.uA)
end

--- The zone a phase is entered FROM, before its record exists: the host the next
--- zone is placed inside (server/storm.lua's drawCentre).
---
--- The zone before this phase at (cx, cy, r) -- zone 0, the map disc, for phase 1
--- -- or the outline a freeze, a thaw or a same-phase `brphase` carried in `mo`.
--- @return table shape
function BR.StormHost(seed, phase, cx, cy, r, mo)
    if mo then
        local rec = { seed = seed, phase = phase, cx0 = cx, cy0 = cy, r0 = r,
                      cx1 = cx, cy1 = cy, r1 = 0.0, mo = mo }
        local e = infoOf(rec)
        if e then return BR.StormShape.discShape(e.src, cx, cy, r) end
    end
    local u = BR.StormUnit(seed, (phase or 1) - 1)
    if not u then return BR.StormShape.circle(cx, cy, r) end
    return BR.StormShape.blob(cx, cy, r, u)
end

--- THE DESTINATION, placed: zone `phase` at (cx1, cy1, r1). It never changes
--- during the phase -- not its shape, not its corners, not where it is.
---
--- A TARGET OF NO RADIUS is phase 8's final point, and it is the one-metre circle
--- every collapsed zone is (union2's header argues why a point is not a disc).
---
--- A FRESH SHAPE EVERY CALL, deliberately: blobUnion re-stamps the pieces of the
--- parts it is handed, so a cached target walked after a union would read the
--- union's arc lengths. Building one is a placement and a piece list.
--- @param rec table
--- @return table shape
function BR.StormTarget(rec)
    if not rec then return BR.StormShape.circle(0.0, 0.0, 0.0) end
    local r1 = rec.r1 or 0.0
    if r1 <= 0.0 then return BR.StormShape.circle(rec.cx1 or 0.0, rec.cy1 or 0.0, 0.0) end
    local u = BR.StormUnit(rec.seed, rec.phase)
    if not u then return BR.StormShape.circle(rec.cx1, rec.cy1, r1) end
    return BR.StormShape.blob(rec.cx1, rec.cy1, r1, u)
end

--- The wall of a record already worked out: see BR.StormWall.
local function wallOf(rec, e, t)
    if t <= 0.0 then return sourceShape(rec, e, rec.cx0, rec.cy0, rec.r0) end
    if t >= 1.0 then return BR.StormTarget(rec) end
    return BR.StormShape.morph(e.src, e.dst, t, e.nested and e.keep or nil,
        BR.Lerp(rec.cx0, rec.cx1, t), BR.Lerp(rec.cy0, rec.cy1, t),
        BR.Lerp(rec.r0, rec.r1, t))
end

--- THE MOVING WALL at sweep fraction `t`, and nothing else: the zone it started as
--- at 0, the destination at 1, and the hull of every corner disc on its straight
--- way between (BR.StormShape.morph) in between.
---
--- ON A NESTED PHASE IT CONTAINS THE DESTINATION AT EVERY t and so it IS the safe
--- zone. On a breakout the safe zone is this UNION the destination -- BR.StormZone.
---
--- AT THE ENDS IT IS THE PLACED ZONES THEMSELVES, not hulls that equal them, so the
--- wall at the end of one sweep and at the start of the next hold are one shape to
--- the bit.
---
--- ═══ IT NEVER MOVES OUTWARD ON A NESTED PHASE, AND THAT IS WHAT SITING RESTS ON ═══
---
--- Every moving disc heads for a disc of the destination, and the destination's own
--- discs are in the hull, so the wall at a later t is inside the wall at an earlier
--- one (storm_shape.lua's morph section has the argument). A point that is inside
--- the wall at an instant is inside it at every earlier instant, and a point inside
--- the destination is inside it at every instant. BR.AirdropLandingCircles and
--- BR.RescueCircles are built on exactly that.
--- @param rec table
--- @param t number|nil   BR.StormAt's seventh answer; nil reads as 0
--- @return table shape
function BR.StormWall(rec, t)
    if not rec then return BR.StormShape.circle(0.0, 0.0, 0.0) end
    t = BR.Clamp(t or 0.0, 0.0, 1.0)
    local e = infoOf(rec)
    if not e then
        return BR.StormShape.circle(BR.Lerp(rec.cx0, rec.cx1, t),
            BR.Lerp(rec.cy0, rec.cy1, t), BR.Lerp(rec.r0, rec.r1, t))
    end
    return wallOf(rec, e, t)
end

--- THE SAFE ZONE at a solved moment: the moving wall, and the destination -- grown
--- into, on a conjoined phase, rather than taken at once.
---
--- ═══ THE ONE PLACE THE ZONE IS BUILT, WHICH IS WHAT MAKES THE WALL HONEST ═══
---
--- Three callers used to spell `BR.StormShape.union2(cx, cy, r, rec.cx1, rec.cy1,
--- rec.r1)` out by hand -- the client's wall, the client's HUD readout and the
--- server's damage tick. That was already three chances to disagree while the
--- shape was a circle, and it becomes a correctness hole the moment the shape is
--- DRAWN FROM A SEED (#344): a caller that forgot the unit would measure a circle
--- against a wall drawn as a blob, and the symptom is damage taken where the
--- curtain says it is safe. So the derivation lives here and the callers ask for
--- the zone rather than assembling one.
---
--- ═══ THE WALL MORPHS CORNER TO CORNER, AND THE DESTINATION STANDS STILL ═══
---
---   "I want the moving wall's corners and lines to move and change to match the
---    destination's. Nothing about the destination shape should ever change while
---    in motion."                                     -- the owner, 2026-09-23
---
--- `t` is how far through the sweep the solved circle is -- BR.StormAt's seventh
--- answer -- and the wall is BR.StormWall at that `t`. So at the end of a sweep the
--- wall IS zone p, and the next record's hold starts from zone p again, at the same
--- circle, in the same shape: no snap, because there is nothing left to change. The
--- wall, the HUD and the damage tick all pass the `t` they solved, and they agree to
--- the bit.
---
--- THE CIRCLE IS IMPLIED BY `t`. Every disc of the wall is on its own straight line
--- between the two placed zones, so `(cx, cy, r)` adds nothing the record and `t`
--- do not already say, and is read only for a record with no shape at all -- the
--- pre-#344 off switch -- where the zone is still the two circles.
---
--- ═══ NESTED: THE WALL. A BREAKOUT: THE WALL UNION THE DESTINATION ═══
---
--- On every phase that did not break out the destination lies inside the zone the
--- wall starts as, by its real shape, and the wall holds it the whole way across --
--- so the wall is the safe zone, one closed loop. A breakout's destination is its
--- own part: stitched to the wall where they overlap (#356), two islands where they
--- do not, exactly as the union always was, so a player who reaches the destination
--- early is safe there (#328). A destination of no radius is phase 8's final point,
--- which is not a disc to reach and is not a part (union2's header argues why).
---
--- ═══ A CONJOINED DESTINATION IS GROWN INTO, NOT POPPED ON (#344) ═══
---
---   "if they're conjoined, today the border pops suddenly to cover the whole area.
---    instead it should grow over a period of 20s to include that new area instead
---    of popping."                                    -- the owner, 2026-09-23
---
--- On a phase whose destination overlaps the zone the wall starts in without being
--- inside it (BR.StormOverlaps), the safe zone across the hold's first
--- `grow.seconds` is that zone grown `g` of the way into the destination --
--- Z union (D intersect Z grown by g S) -- where S is how far the destination's
--- furthest point is outside Z (BR.StormShape.grown has the geometry, and why every
--- piece of it is exact). It starts as Z, where the last sweep left the wall, and
--- ends on Z union D exactly, so nothing pops at either end. The destination itself
--- never changes; it is only intersected. `g` is BR.StormAt's eighth answer, pure in
--- the record and the clock, so the wall, the HUD and the damage tick grow it
--- together. A DISJOINT destination is the far island, and appears at once: the
--- owner is content with that.
---
--- A NIL `g` READS AS 1, the whole union at once. A caller that was never taught to
--- pass it therefore bills and draws the old pop -- MORE safe ground, never less.
---
--- A GROWTH THAT CANNOT BE BUILT -- two boundaries touching in a way the crossing
--- finder refuses -- is the whole union too, for the same reason. The wall and the
--- damage tick both come through here, so even then they agree.
---
--- THE MAP DOES NOT DRAW THE GROWTH: it shows the zone the phase started in under
--- the destination's fill -- whose union is what the growth ends on -- because
--- drawing the front would mean rebuilding the overlay while it moves, the hitch
--- 52a7caa removed. client/storm.lua's overlayPlan says so where it is decided.
---
--- @param rec table|nil    the published storm record
--- @param cx number        the CURRENT centre, as BR.StormAt reports it
--- @param cy number
--- @param r number         the CURRENT radius
--- @param t number|nil     how far through the sweep; nil reads as 0
--- @param g number|nil     how far a conjoined zone has grown; nil reads as 1
--- @return table shape
function BR.StormZone(rec, cx, cy, r, t, g)
    if not rec then
        return BR.StormShape.circle(cx or 0.0, cy or 0.0, r or 0.0)
    end
    local e = infoOf(rec)
    if not e then
        return BR.StormShape.union2(cx, cy, r, rec.cx1, rec.cy1, rec.r1)
    end
    t = BR.Clamp(t or 0.0, 0.0, 1.0)
    local wall = wallOf(rec, e, t)
    if e.nested or t >= 1.0 or (rec.r1 or 0.0) <= 0.0 then return wall end
    local target = BR.StormTarget(rec)
    g = (g == nil) and 1.0 or BR.Clamp(g, 0.0, 1.0)
    if g < 1.0 and t <= 0.0 and wall.hull and target.hull then
        local over, S = growthInfo(rec, e)
        if over then
            local zone = BR.StormShape.grown(wall, target, S * g)
            if zone then return zone end
        end
    end
    return BR.StormShape.blobUnion(wall, target)
end

-- ═══ THE WALL IN ITS OWN MOVING FRAME, WHICH IS WHAT THE MAP CAN DRAW (#344) ═══
--
-- Every disc of the wall travels in a straight line, centre and radius both, from
-- (c0 + r0 a) to (c1 + r1 b), a and b its two partners' unit discs. At sweep fraction
-- t that is
--
--   (1-t)(c0 + r0 a) + t(c1 + r1 b)  =  c(t) + r(t) [ (1-m) a + m b ],  m = t r1 / r(t)
--
-- where c(t), r(t) are the solver's own circle. So the moving wall is the solver's
-- circle times ONE unit shape, V(m) -- the hull of every (1-m) a + m b -- and V(0) is
-- the zone the wall leaves, V(1) the one it closes on. The map cannot re-draw a
-- polygon while the storm moves (#350, 52a7caa) and it CAN move, scale and fade a
-- polygon it already has: so it draws V at chosen values of m ahead of time and
-- crossfades between them while placing them on the solver's circle. At m = 0 and
-- m = 1 that is the wall exactly. (Where a nested wall rests on its destination it is
-- the hull of this and the destination, and the destination's own fill is drawn
-- over it.)

--- The unit discs of a record's morph, both ends, in link order: `ua` the wall
--- leaves from and `ub` the partners it travels to. A record carrying its outline
--- (`mo`) has world discs, read back into its own circle; an end of no radius
--- borrows the other end's, because the frame there is a point anyway.
local function unitDiscs(rec, e)
    if e.ua then return e.ua, e.ub end
    local ua, ub = {}, {}
    local uB = e.uB
    local r0 = rec.r0 or 0.0
    for i = 1, #e.src do
        ub[i] = uB.discs[e.bi[i]] or uB.discs[1]
    end
    if rec.mo then
        for i = 1, #e.src do
            local s = e.src[i]
            if r0 > 0.0 then
                ua[i] = { x = (s.x - rec.cx0) / r0, y = (s.y - rec.cy0) / r0, r = s.r / r0 }
            else
                ua[i] = ub[i]
            end
        end
    else
        local ps = BR.StormShape.pairsOf(e.uA, uB)
        for i = 1, #ps do ua[i] = (r0 > 0.0) and ps[i].a or ub[i] end
    end
    if (rec.r1 or 0.0) <= 0.0 then
        for i = 1, #ua do ub[i] = ua[i] end
    end
    e.ua, e.ub = ua, ub
    return ua, ub
end

--- How far through the morph the wall is IN ITS OWN FRAME at sweep fraction `t`:
--- the `m` for which the wall is the solver's circle times V(m). See the section.
--- 0 the whole way for a destination of no radius -- the last zone shrinks onto its
--- point without changing shape -- and 1 from the first instant for a wall that
--- starts as a point.
--- @param rec table
--- @param t number
--- @return number m   0..1
function BR.StormMorphFrame(rec, t)
    t = BR.Clamp(t or 0.0, 0.0, 1.0)
    local r0, r1 = rec.r0 or 0.0, rec.r1 or 0.0
    if r0 <= 0.0 then return (t > 0.0) and 1.0 or 0.0 end
    if r1 <= 0.0 then return 0.0 end
    local r = r0 + (r1 - r0) * t
    return BR.Clamp(t * r1 / r, 0.0, 1.0)
end

--- The solver's radius at the moment the frame's morph fraction is `m`: the
--- inverse of BR.StormMorphFrame, which is the size V(m) is seen at and so the size
--- the map draws it at.
--- @param rec table
--- @param m number
--- @return number metres
function BR.StormMorphRadius(rec, m)
    m = BR.Clamp(m or 0.0, 0.0, 1.0)
    local r0, r1 = rec.r0 or 0.0, rec.r1 or 0.0
    if r0 <= 0.0 then return r1 end
    if r1 <= 0.0 then return r0 end
    return r0 * r1 / (r1 * (1.0 - m) + m * r0)
end

--- V(m), the moving wall's shape in its own frame, drawn about the ORIGIN at
--- radius `rDraw`: the hull of every (1-m) a + m b, scaled. Fresh every call.
---
--- WITHOUT the destination's discs, so a nested wall resting on its destination is
--- this hull with the destination's fill drawn over it rather than the hull of both.
--- nil for the pre-#344 off switch.
--- @param rec table
--- @param m number      0..1
--- @param rDraw number  metres
--- @return table|nil shape
function BR.StormKeyframe(rec, m, rDraw)
    local e = rec and infoOf(rec)
    if not e then return nil end
    m = BR.Clamp(m or 0.0, 0.0, 1.0)
    local ua, ub = unitDiscs(rec, e)
    local s, k = 1.0 - m, rDraw or 1.0
    local md = {}
    for i = 1, #ua do
        local a, b = ua[i], ub[i]
        md[i] = { x = (s * a.x + m * b.x) * k, y = (s * a.y + m * b.y) * k,
                  r = (s * a.r + m * b.r) * k }
    end
    return BR.StormShape.discShape(md, 0.0, 0.0, k)
end

--- The fastest any corner of the wall moves during this record's sweep, in metres
--- a second: the most any one disc travels plus the most its radius changes, over
--- the sweep's length.
---
--- THE DAMAGE CUSHION'S WALL-SPEED TERM IS (r0 - r1) / T, AND THE MORPH OUTRUNS IT.
--- That is how fast a CIRCLE's edge moves, and a corner travelling to a corner of a
--- different shape moves further: measured at 2.2 to 3.8 times that on average
--- across phases 7 down to 2, and 6.2 at worst. server/storm.lua's damage tick
--- belongs to #366, which is where this is for.
--- @param rec table
--- @return number metres per second
function BR.StormWallSpeed(rec)
    if not rec then return 0.0 end
    local T = math.max((rec.tShrink or 0.0) / 1000.0, 1.0)
    local e = infoOf(rec)
    if not e then return math.abs((rec.r0 or 0.0) - (rec.r1 or 0.0)) / T end
    local best = 0.0
    for i = 1, #e.src do
        local a, b = e.src[i], e.dst[i]
        local v = math.sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2) + math.abs(b.r - a.r)
        if v > best then best = v end
    end
    return best / T
end

--- THE WALL AT SWEEP FRACTION `t`, AS A RECORD CAN CARRY IT: the `mo` a freeze, a
--- thaw or a same-phase `brphase` starts its record from. See the record's header.
---
--- nil for a record still holding in the zone it started as, because a record built
--- from that zone's circle starts as that zone anyway. Otherwise every moving disc at
--- `t` with the destination disc it is heading for -- and, on a nested phase, the
--- destination's own discs too, because they are part of the wall's hull and part of
--- what the next record's morph must keep. Exact duplicates are dropped, so a chain
--- of freezes does not grow what it carries by the discs it already has.
---
--- `g`, THE GROWTH, RIDES ALONG WHEN IT IS PASSED, on a conjoined record -- and then
--- even in the hold, so a freeze part way through growing into the destination, and
--- the thaw after it, carry on from where the zone had got to rather than shrinking
--- back to where it started (BR.StormZone). Only a caller that keeps the target
--- passes it: brstormfreeze's freeze does; its thaw and a same-phase `brphase`, which
--- draw a new target with its own growth ahead of it, do not.
--- @param rec table
--- @param t number|nil
--- @param g number|nil   BR.StormAt's eighth answer, for a caller keeping the target
--- @return table|nil mo
function BR.StormMorphAt(rec, t, g)
    if not rec then return nil end
    t = BR.Clamp(t or 0.0, 0.0, 1.0)
    local e = infoOf(rec)
    local carry = (g ~= nil and e ~= nil) and (growthInfo(rec, e)) or false
    if t <= 0.0 and not rec.mo and not carry then return nil end
    if not e then return nil end
    local s = 1.0 - t
    local d, b, seen = {}, {}, {}
    local function add(x, y, r, i)
        local key = ('%a|%a|%a|%d'):format(x, y, r, i)
        if seen[key] then return end
        seen[key] = true
        d[#d + 1], d[#d + 2], d[#d + 3] = x, y, r
        b[#b + 1] = i
    end
    for i = 1, #e.src do
        local a, q = e.src[i], e.dst[i]
        if t >= 1.0 then
            add(q.x, q.y, q.r, e.bi[i])
        elseif t <= 0.0 then
            add(a.x, a.y, a.r, e.bi[i])
        else
            add(s * a.x + t * q.x, s * a.y + t * q.y, s * a.r + t * q.r, e.bi[i])
        end
    end
    if e.nested and t > 0.0 then
        for k = 1, #e.keep do
            local q = e.keep[k]
            add(q.x, q.y, q.r, k)
        end
    end
    local mo = { t = t, d = d, b = b }
    if carry then mo.g = BR.Clamp(g, 0.0, 1.0) end
    return mo
end

--- Pick the match anchor: the POI the whole storm sequence homes on.
---
--- The scheme (user-designed, 2026-08-02): one random waypoint of THIS match's
--- flight tour, then one random POI between band.min and band.max units of it.
--- Route-coupled -- the opening circle almost always contains a stretch of the
--- path players actually dropped along -- and POI-anchored, so the centre is
--- always a nameable place on land, never a point in the sea.
---
--- FAILURE IS NOT AN OPTION HERE: this runs inside the WARMUP transition, and
--- an error would kill the match before it starts. So the band widens in steps
--- when a waypoint is POI-sparse (coastal leg-1 points, the Chiliad exits),
--- and the nearest POI of all is the final fallback. Some POI is always
--- returned as long as one exists.
---
--- @param rng table         a BR.Rng instance (server only)
--- @param waypoints table   the tour's authored waypoints, { {x, y}, ... }
--- @param pois table        candidate POIs, { {x, y, ...}, ... }
--- @param band table        { min, max, widenStep, widenMax }
--- @return table|nil poi    the chosen POI (a reference into `pois`)
--- @return table|nil wp     the waypoint it was picked around
function BR.PickStormAnchor(rng, waypoints, pois, band)
    if #pois == 0 or #waypoints == 0 then return nil, nil end

    local wp = rng:pick(waypoints)
    local minD = band and band.min or 500.0
    local maxD = band and band.max or 1500.0
    local step = band and band.widenStep or 500.0
    local cap  = band and band.widenMax or 4000.0

    while true do
        local candidates = {}
        for _, p in ipairs(pois) do
            local d = BR.Dist(wp.x, wp.y, p.x, p.y)
            if d >= minD and d <= maxD then
                candidates[#candidates + 1] = p
            end
        end
        if #candidates > 0 then
            return rng:pick(candidates), wp
        end
        if maxD >= cap then break end
        maxD = math.min(cap, maxD + step)
    end

    -- Nothing within widenMax of this waypoint. Take the nearest POI outright:
    -- a slightly off-band anchor is a shrug, no anchor is a dead match.
    local best, bestD = nil, math.huge
    for _, p in ipairs(pois) do
        local d = BR.Dist(wp.x, wp.y, p.x, p.y)
        if d < bestD then best, bestD = p, d end
    end
    return best, wp
end

--- The breakout budget for one phase, with the chance RAMPED by progress.
---
--- The first circle must never break out and the last should nearly always
--- (user call, 2026-08-06). The reason is that the opening circle is enormous
--- and already contains most of the map -- moving it outside itself asks
--- players to cross the whole island before they have a gun -- while the late
--- circles are small, everyone is armed, and a static circle is where a
--- passive player wins by having picked the right building.
---
--- Linear from chanceStart at phase 1 to chanceEnd at the last phase.
---
--- @param cfg table      BR.Config.Storm
--- @param phase integer  1-based phase being entered
--- @return table|nil     { chance, gapMax, minRadius } for NextZoneCentre
function BR.StormBreakoutFor(cfg, phase)
    local bo = cfg and cfg.breakout
    if not bo then return nil end

    local n = #(cfg.phases or {})
    local t = 1.0
    if n > 1 then
        t = BR.Clamp((phase - 1) / (n - 1), 0.0, 1.0)
    end

    local a = bo.chanceStart or 0.0
    local b = bo.chanceEnd or 0.0
    return {
        chance    = a + (b - a) * t,
        gapMax    = bo.gapMax,
        minRadius = bo.minRadius,
    }
end

-- Metres of clearance a nested placement keeps from touching the zone it is inside.
-- A millimetre: far below anything a player can see, and nine orders of magnitude
-- above the rounding in a signed distance -- so "is this record nested" is decided
-- the same way on both sides of the wire however the last bits of a sine fall, and
-- a destination is never classified at the one knife edge where it would be drawn
-- as a second boundary inside the wall.
local NEST_CLEAR = 1e-3

-- How many times each ray is bisected. A FIXED count, so both of a phase's placements
-- -- at warmup and at the phase itself -- stop on the same double.
local RAY_STEPS = 48

--- Choose where the next zone goes: its centre, by its REAL SHAPE.
---
---   "the circles still overlap when they are different shapes."
---                                                    -- the owner, 2026-09-23
---
--- ═══ NESTED: THE NEXT ZONE LIES ENTIRELY INSIDE THIS ONE ═══
---
--- The centres the next zone can take and still fit are F = {c : D + c inside Z},
--- which is Z eroded by D: CONVEX, and it holds this zone's own centre with room to
--- spare, because blobUnit drew the next zone to fit there concentric (`fitClear`).
--- So along a drawn bearing the feasible offsets are one interval from zero, and
--- its far end L is found by bisection on the exact test -- every disc of D inside
--- Z, BR.StormShape.fit. The offset is sqrt(u) * edgeBias * L: uniform over F when
--- F is a disc, which is exactly what rng:pointInDisc drew in the circle era.
---
--- ═══ A BREAKOUT: THE GAP TO THIS ZONE, CAPPED ═══
---
--- A breakout may leave this zone entirely, and the gap between the two shapes is
--- capped at `gapMax` of the current radius, as it always was (user call,
--- 2026-08-06). The gap between Z and D + c is the signed distance from c to the
--- Minkowski sum Z + (-D), which is a corner list (BR.StormShape.sumOf) -- so the
--- breakout's region F_b is that sum dilated by the gap, convex, containing F, and
--- the same bisection finds its far end on the bearing. A breakout roll can still
--- land nested, as it always could.
---
--- ═══ THE DRAWS ARE FIXED, AND THEY ARE THE ONES pointInDisc TOOK ═══
---
--- The breakout roll -- only when there is a chance and this zone is at least the
--- floor, the rule this always had -- then the bearing, then u. Everything after is
--- arithmetic with fixed iteration counts. So a phase takes the same values off
--- m.stormRng that it took when zones were circles, and `first.stream`'s alignment
--- of warmup and phase 1 holds. (The one conditional draw the circle era had -- a
--- random bearing for an offset of exactly zero -- is gone: the bearing is always
--- drawn.)
---
--- ═══ THE EDGE HUG, THE MAP BOUNDS AND THE WATER, BY REAL SHAPE ═══
---
--- THE LAST PHASES HUG THE EDGE: with `hugM`, the offset is at least the nested
--- ray's far end less hugM -- the ray standing in for the old slack.
---
--- THE MAP BOUNDS clamp the centre so the next zone's exact bounding box stays
--- inside mapAABB, an axis it is wider than being centred -- ClampCircleToAABB's
--- rule, for a shape. If that moved it out of the phase's region, it is bisected
--- back toward this zone's centre to the last point inside: THE PHASE'S BUDGET
--- BEATS BOUNDS, because the sweep was priced off where the solver put the zone.
---
--- AND NOT OFF THE MAP: the centre walks back toward this zone's in eight steps, as
--- it always did, and the region is convex, so every step of the walk is inside it.
---
--- A HOST THAT CANNOT HOLD THE NEXT ZONE AT ALL -- a frozen outline thawed, or a
--- same-phase `brphase`, part way through a morph -- leaves the centre where it is,
--- and the phase is simply not nested. Those are dev paths.
---
--- @param rng table        m.stormRng (server only: clients must not predict this)
--- @param host table       the zone being closed from, as a shape (BR.StormHost)
--- @param cx number        its centre
--- @param cy number
--- @param r0 number        its radius: the breakout's gap and floor are measured in it
--- @param unit table|nil   the next zone's unit; nil for a point
--- @param r1 number        the next zone's radius
--- @param edgeBias number  0..1, how much of the room the offset may use
--- @param aabb table|nil   playable bounds
--- @param hugM number|nil  the edge hug, on the phases that have one
--- @param breakout table|nil  { chance, gapMax, minRadius }
--- @return number, number, boolean  the next centre, and whether it rolled a breakout
function BR.NextZoneCentre(rng, host, cx, cy, r0, unit, r1, edgeBias, aabb, hugM, breakout)
    local SS = BR.StormShape
    local hks = host and host.hull and host.hull.ks
    if not hks then
        -- A CIRCLE HOST -- a zone so small blob() made it one: its one disc.
        local d = host and host.discs and host.discs[1]
        hks = SS.discHull({ { x = d and d.x or cx, y = d and d.y or cy, r = d and d.r or r0 } })
    end

    -- THE NEXT ZONE ABOUT ITS OWN CENTRE, at its real size.
    local D0 = {}
    if unit and (r1 or 0.0) > 0.0 then
        for k, d in ipairs(unit.discs) do
            D0[k] = { x = d.x * r1, y = d.y * r1, r = d.r * r1 }
        end
    else
        D0[1] = { x = 0.0, y = 0.0, r = 0.0 }
    end

    local broke = false
    if breakout and breakout.chance and breakout.chance > 0
       and r0 >= (breakout.minRadius or 0.0) then
        if rng:float() < breakout.chance then broke = true end
    end
    local theta = rng:float() * 2.0 * math.pi
    local u = rng:float()

    -- A config value above 1.0 would push the new centre past the region and
    -- silently overshoot it, so clamp rather than trusting it.
    edgeBias = BR.Clamp(edgeBias or 0.55, 0.0, 1.0)
    local dx, dy = math.cos(theta), math.sin(theta)

    local function nested(x, y)
        return SS.fit(hks, D0, x, y, 1.0) <= -NEST_CLEAR
    end
    local inside = nested
    local sum, gap = nil, 0.0
    if broke then
        sum = SS.sumOf(hks, SS.reflect(SS.discHull(D0)))
        gap = (breakout.gapMax or 0.5) * r0
        inside = function(x, y) return SS.hullDistance(sum, x, y) <= gap end
    end

    --- The far end of the region along the drawn bearing: zero when this zone's own
    --- centre is not in it.
    local function ray(ok, hi)
        if not ok(cx, cy) then return 0.0 end
        local lo = 0.0
        for _ = 1, RAY_STEPS do
            local mid = 0.5 * (lo + hi)
            if ok(cx + dx * mid, cy + dy * mid) then lo = mid else hi = mid end
        end
        return lo
    end

    -- A NESTED CENTRE IS INSIDE THIS ZONE -- every zone holds its own centre -- so no
    -- ray reaches past this zone's reach from its centre. A breakout's reaches no
    -- further than the sum's, plus the gap.
    local Ln = ray(nested, SS.reachOf(hks, cx, cy) + 1.0)
    local L = Ln
    if broke then L = ray(inside, SS.reachOf(sum, cx, cy) + gap + 1.0) end

    local s = math.sqrt(u) * edgeBias * L
    if hugM then
        local floor = Ln - hugM
        if floor > s then s = floor end
        if s > L then s = L end
    end
    local nx, ny = cx + dx * s, cy + dy * s

    if aabb then
        -- THE NEXT ZONE'S EXACT BOUNDING BOX about its centre: its support function in
        -- the four axis directions.
        local west, east, south, north = 0.0, 0.0, 0.0, 0.0
        for k = 1, #D0 do
            local d = D0[k]
            west = math.max(west, -d.x + d.r)
            east = math.max(east, d.x + d.r)
            south = math.max(south, -d.y + d.r)
            north = math.max(north, d.y + d.r)
        end
        local minX, maxX = aabb.min.x + west, aabb.max.x - east
        local minY, maxY = aabb.min.y + south, aabb.max.y - north
        local mx, my
        -- If the zone is wider than the box, centring it is the best we can do.
        if minX > maxX then
            mx = 0.5 * (aabb.min.x + aabb.max.x) + 0.5 * (west - east)
        else
            mx = BR.Clamp(nx, minX, maxX)
        end
        if minY > maxY then
            my = 0.5 * (aabb.min.y + aabb.max.y) + 0.5 * (south - north)
        else
            my = BR.Clamp(ny, minY, maxY)
        end

        -- Clamping to the map bounds can push the centre out of the region the phase
        -- settled on -- most easily when this zone already overhangs the bounds,
        -- which the opening zone routinely does.
        --
        -- THE PHASE'S BUDGET WINS OVER BOUNDS. A zone poking into the ocean is a
        -- cosmetic problem; a zone further out than the phase intended is a run
        -- nobody was given time for, because the shrink duration was priced off the
        -- place the solver chose. So it is walked back along the line to this zone's
        -- centre, to the last point inside the region.
        if mx ~= nx or my ~= ny then
            if not inside(mx, my) then
                local lo = 0.0
                if inside(cx, cy) then
                    local hi = 1.0
                    for _ = 1, RAY_STEPS do
                        local mid = 0.5 * (lo + hi)
                        if inside(cx + (mx - cx) * mid, cy + (my - cy) * mid) then
                            lo = mid
                        else
                            hi = mid
                        end
                    end
                end
                mx, my = cx + (mx - cx) * lo, cy + (my - cy) * lo
            end
            nx, ny = mx, my
        end
    end

    -- AND NOT OFF THE MAP.
    --
    -- The anchor is a POI and therefore always on land, but nothing stopped
    -- the per-phase drift from walking seaward one zone at a time -- eight
    -- phases of offset off a coastal anchor is enough to finish over open water,
    -- and the final zone is where it matters most (user, 2026-08-06: "rare (but
    -- possible) cases where the storm can close in to an anchor point in the
    -- ocean").
    --
    -- Walked back along its own line toward the PREVIOUS centre, which is on
    -- the map by induction: phase 0 is the anchor POI, and every POI is inside
    -- the boundary (tools/check_boundary.lua is what makes that true rather
    -- than hoped). That makes this terminate, and it keeps the draw's bearing
    -- -- the zone still moves the way the roll said, just not as far. The region
    -- the centre was drawn in is convex and holds the previous centre, so every
    -- step in is still inside it: a nested zone stays nested.
    --
    -- THE CENTRE IS WHAT IS TESTED, and it is a good stand-in for the zone: it is
    -- the zone's centroid, at least 0.41 of r deep in every shape that ships, and it
    -- is phase 8's final point itself.
    --
    -- ═══ THE MASK IS THE SURVEYED BOUNDARY NOW, NOT JUST THE RECTANGLES ═══
    --
    -- It used to be BR.Config.Map.Water alone: five coarse rectangles authored
    -- to stop LOOT generating in the Pacific. They were never a map outline,
    -- and the gaps between them are where the storm went. Measured over 4000
    -- simulated matches on the old rule, 20.2% of them ENDED with the final
    -- circle's centre outside the playable shape -- which is the owner's report
    -- ("we have too many places where the storm can end outside the map and in
    -- the ocean", 2026-08-28) as a number rather than as an anecdote.
    --
    -- BOTH TESTS RUN, because neither contains the other. The boundary is the
    -- island's outline and knows nothing about the water inside it; the Alamo
    -- Sea rectangle sits wholly within the ring and is the case the boundary
    -- cannot catch. The four ocean rectangles are wholly outside it and are now
    -- redundant here -- kept because they cost one comparison and because
    -- deleting a backstop to save a comparison is how backstops go missing.
    local M = BR.Config and BR.Config.Map
    local function offMap(x, y)
        if not M then return false end
        if M.IsWater and M.IsWater(x, y) then return true end
        if M.InBounds and not M.InBounds(x, y) then return true end
        return false
    end

    if offMap(nx, ny) then
        for attempt = 1, 8 do
            local t = 1.0 - attempt / 8.0
            local tx, ty = cx + (nx - cx) * t, cy + (ny - cy) * t
            if not offMap(tx, ty) then
                return tx, ty, broke
            end
        end
        -- Every step of the way in was off the map, which means the CURRENT
        -- centre is too. Nothing better to offer than staying put.
        return cx, cy, broke
    end

    return nx, ny, broke
end

--- Build the record for a phase transition.
---
--- @param phase integer      phase index being entered (1-based)
--- @param cx0 number         circle we are starting from
--- @param cy0 number
--- @param r0 number
--- @param cx1 number         circle we are shrinking toward
--- @param cy1 number
--- @param r1 number
--- @param now number         server time
--- @param waitMs number
--- @param shrinkMs number
--- @param dps number
--- @param seed number|nil    the match's storm seed -- WHAT SHAPE THIS PHASE IS
--- @param mo table|nil       the wall's outline, for a record that starts part way
---                           through a morph; see the record's header
--- @return table
---
--- ═══ THE SEED DEFAULTS TO ZERO, AND ZERO IS A REAL SEED ═══
---
--- Every production path passes the match's own (server/storm.lua's enterPhase is
--- the only one), so this default is for a record built by hand: a test, or a
--- console. It is 0 rather than nil because nil would mean "no shape", and "no
--- shape" means circles -- so a caller that forgot the seed would quietly ship the
--- exact thing #344 exists to remove, with a green suite behind it. Seed 0 is an
--- ordinary stream and draws an ordinary blob, so a hand-built record is measured
--- against the same kind of shape the game draws.
function BR.BuildStormRecord(phase, cx0, cy0, r0, cx1, cy1, r1, now, waitMs, shrinkMs, dps, seed, mo)
    return {
        phase   = phase,
        seed    = math.tointeger(math.floor(seed or 0)) or 0,
        -- ABSENT RATHER THAN EMPTY on every ordinary record, so the wire and the
        -- snapshot carry nothing new for the phases that start where they should.
        mo      = mo,
        cx0     = cx0 + 0.0,
        cy0     = cy0 + 0.0,
        r0      = r0 + 0.0,
        cx1     = cx1 + 0.0,
        cy1     = cy1 + 0.0,
        r1      = r1 + 0.0,
        tStart  = now + 0.0,
        tWait   = waitMs + 0.0,
        tShrink = shrinkMs + 0.0,
        dps     = dps + 0.0,
    }
end

--- Total ms from the start of a phase until its circle has fully collapsed.
function BR.StormPhaseDuration(rec)
    if not rec then return 0.0 end
    return rec.tWait + rec.tShrink
end
