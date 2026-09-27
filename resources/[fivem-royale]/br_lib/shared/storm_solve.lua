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
-- across the sweep follows from five lists: the discs the wall starts as (`src`),
-- the discs it has become by the knee (`mid`), where each of them ends (`dst`), the
-- index of that destination disc in the target zone's own list (`bi`), and the
-- target zone's discs as placed (`keep`). And one verdict: whether the target lies
-- ENTIRELY inside the zone the wall starts as -- by real shape, exactly
-- (BR.StormShape.fit), which is what BR.NextZoneCentre places every non-breakout
-- target to satisfy.
--
-- Held weakly per record, and re-derived if any field it was read from has moved
-- or a zone unit has been rebuilt: a record is whole-table-assigned everywhere in
-- the game, so this is a cache hit on every frame of a phase but the first.
local recInfo = setmetatable({}, { __mode = 'k' })

-- ═══ ONE MOVING ZONE, WHOSE SHAPE BECOMES THE DESTINATION'S BEFORE IT ARRIVES ═══
--
--   "the expectation is the shape of the outer (moving) circle will change at
--    runtime per frame to eventually match the shape of the inner
--    (stationary/destination) circle when it reaches, say, 15 seconds before
--    finishing the move."                                -- the owner, 2026-09-27
--
-- So a sweep has two legs, split at the KNEE: `morph.leadSeconds` before the sweep
-- ends (config/storm.lua).
--
--   0 .. knee   every corner disc of the zone the wall leaves travels in a straight
--               line to its partner's disc of `mid` -- the DESTINATION'S OWN SHAPE,
--               placed a little larger than the destination and around it. The
--               outline changes every frame, and is the destination's by the knee.
--   knee .. 1   the wall IS the destination's shape, one fixed outline moved and
--               scaled onto the destination: every disc of `mid` travels straight
--               to its own disc of the destination, so the whole outline is one
--               similarity (BR.StormWallFrame), and it lands on the destination
--               exactly as the sweep ends.
--
-- WHERE `mid` STANDS. On a phase that did not break out the destination lies inside
-- the zone, and `mid` is the destination grown about a point inside it -- the mean
-- of its corner centres, p -- by the solver circle's own ratio at the knee,
-- r(knee) / r1, but never so far that it leaves the zone the wall starts as
-- (bisected against that zone's corner list). Three things follow, and they are the
-- three the one-leg morph before it had:
--
--   THE WALL HOLDS THE DESTINATION AT EVERY t. `mid` holds it (a convex set grown
--   about a point of itself holds itself), and the first leg's hull takes `mid`'s
--   discs in wherever they would poke out -- the wall RESTS on the grown destination
--   rather than cutting into it.
--
--   IT NEVER MOVES OUTWARD. Every moving disc heads in a straight line for a disc
--   that is in the hull for the rest of its leg -- `mid`'s in the first, the
--   destination's in the second -- so the wall at a later t is inside the wall at an
--   earlier one. Airdrop and rescue siting rest on that.
--
--   IT STARTS AND ENDS ON THE ZONES THEMSELVES. `mid` is inside the zone the wall
--   leaves, so adding it to that zone's hull changes nothing at t = 0; and the second
--   leg ends on the destination's discs.
--
-- On a BREAKOUT the destination is its own part of the safe zone and nothing has to
-- hold it: `mid` is the destination's shape on the solver's own circle at the knee,
-- and the zone is the wall union the destination (BR.StormZone), as it always was.
--
-- A DESTINATION OF NO RADIUS -- phase 8's point -- has no shape to take on. The last
-- zone shrinks onto its point in one leg, keeping its own shape, as it always did.
-- So does every sweep while `leadSeconds` is 0: one leg, the shape finishing only
-- as the wall arrives. That is the off switch.
--
-- THE KNEE DEPENDS ON HOW LONG THE SWEEP IS, and the sweep is priced on the wall
-- (BR.StormSweepPrice below): server/storm.lua prices it at the length it is about
-- to publish, and lengthens it until the two agree (its sweepSeconds).
local KNEE_MIN = 0.5        -- a sweep under twice the lead turns its shape half way
local MID_STEPS = 20        -- halvings of the grown destination's scale

--- Where the knee falls in a record's sweep, 0..1: `leadSeconds` before it ends,
--- and never before half way. nil for a sweep with one leg -- a destination of no
--- radius, a lead of 0 (the off switch), or a record with no sweep at all.
--- @param rec table
--- @return number|nil
local function kneeOf(rec)
    if (rec.r1 or 0.0) <= 0.0 then return nil end
    local S = BR.Config and BR.Config.Storm
    local lead = S and S.morph and tonumber(S.morph.leadSeconds) or 0.0
    local T = tonumber(rec.tShrink) or 0.0
    if lead <= 0.0 or T <= 0.0 then return nil end
    local k = 1.0 - lead * 1000.0 / T
    if k < KNEE_MIN then k = KNEE_MIN end
    return k
end

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

--- `mid`, the destination's shape the first leg ends on, as one disc per moving disc
--- (the partner of the destination disc that one ends on), and the frame it stands
--- in: the destination's unit at (mx, my) scaled by `ms`. See the section note.
local function midOf(rec, e, knee)
    local SS = BR.StormShape
    local r1 = rec.r1
    local rk = BR.Lerp(rec.r0, r1, knee)
    local mx, my, ms
    if e.nested then
        local keep = e.keep
        local px, py = 0.0, 0.0
        for k = 1, #keep do px, py = px + keep[k].x, py + keep[k].y end
        px, py = px / #keep, py / #keep
        local rel = {}
        for k = 1, #keep do
            rel[k] = { x = keep[k].x - px, y = keep[k].y - py, r = keep[k].r }
        end
        local zks = SS.discHull(e.src)
        local lam = math.max(1.0, rk / r1)
        -- GROWN NO FURTHER THAN THE ZONE THE WALL LEAVES HOLDS IT. At 1 it is the
        -- destination, which that zone holds -- the nesting verdict -- so the bisection
        -- always has a side that fits, and keeps to it.
        if lam > 1.0 and zks and SS.fit(zks, rel, px, py, lam) > 0.0 then
            local lo, hi = 1.0, lam
            for _ = 1, MID_STEPS do
                local m = 0.5 * (lo + hi)
                if SS.fit(zks, rel, px, py, m) <= 0.0 then lo = m else hi = m end
            end
            lam = lo
        end
        mx, my, ms = px + lam * (rec.cx1 - px), py + lam * (rec.cy1 - py), lam * r1
    else
        mx, my, ms = BR.Lerp(rec.cx0, rec.cx1, knee), BR.Lerp(rec.cy0, rec.cy1, knee), rk
    end
    local discs = e.uB.discs
    local mid = {}
    for i = 1, #e.src do
        local b = discs[e.bi[i]] or discs[1]
        mid[i] = { x = mx + ms * b.x, y = my + ms * b.y, r = ms * b.r }
    end
    return mid, mx, my, ms
end

--- The record's morph, worked out: see the section note. nil for the off switch.
local function infoOf(rec)
    local uB = BR.StormUnit(rec.seed, rec.phase)
    if not uB then return nil end
    local uA = nil
    if not rec.mo then uA = BR.StormUnit(rec.seed, (rec.phase or 1) - 1) end
    local knee = kneeOf(rec)
    local e = recInfo[rec]
    if e and e.uA == uA and e.uB == uB and e.mo == rec.mo
        and e.phase == rec.phase and e.seed == rec.seed
        and e.cx0 == rec.cx0 and e.cy0 == rec.cy0 and e.r0 == rec.r0
        and e.cx1 == rec.cx1 and e.cy1 == rec.cy1 and e.r1 == rec.r1
        and e.knee == knee then
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
    if knee and #src > 0 then
        e.knee = knee
        e.mid, e.mx, e.my, e.ms = midOf(rec, e, knee)
    end
    recInfo[rec] = e
    return e
end

--- The leg of the sweep `t` is on: the discs it runs from and to, how far along it,
--- and the discs a nested wall must hold on it. See the section note.
--- @return table from, table to, number u, table|nil keep
local function legOf(e, t)
    local k = e.knee
    if not k then return e.src, e.dst, t, e.nested and e.keep or nil end
    if t < k then return e.src, e.mid, t / k, e.nested and e.mid or nil end
    return e.mid, e.dst, (t - k) / (1.0 - k), e.nested and e.keep or nil
end

--- The moving wall's corner list at sweep fraction `t`, without the pieces.
local function hullAt(e, t)
    local from, to, u, keep = legOf(e, t)
    return BR.StormShape.morphHull(from, to, u, keep)
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
    local from, to, u, keep = legOf(e, t)
    return BR.StormShape.morph(from, to, u, keep,
        BR.Lerp(rec.cx0, rec.cx1, t), BR.Lerp(rec.cy0, rec.cy1, t),
        BR.Lerp(rec.r0, rec.r1, t))
end

--- THE MOVING WALL at sweep fraction `t`, and nothing else: the zone it started as
--- at 0, the destination at 1, and in between the hull of every corner disc on its
--- straight way to the destination's shape by the knee and then onto the
--- destination itself (BR.StormShape.morph, twice -- see "one moving zone" above).
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
--- Every moving disc heads for a disc that stays in the hull for the rest of its leg
--- -- the grown destination's in the first, the destination's own in the second --
--- so the wall at a later t is inside the wall at an earlier one (storm_shape.lua's
--- morph section has the argument for one leg). A point that is inside
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
--- ═══ ONE MOVING ZONE BECOMES THE DESTINATION'S SHAPE, AND THE DESTINATION STANDS
---     STILL ═══
---
---   "I want the moving wall's corners and lines to move and change to match the
---    destination's. Nothing about the destination shape should ever change while
---    in motion."                                     -- the owner, 2026-09-23
---
--- `t` is how far through the sweep the solved circle is -- BR.StormAt's seventh
--- answer -- and the wall is BR.StormWall at that `t`: the destination's shape by the
--- knee, `morph.leadSeconds` before the end, and the destination itself at the end.
--- So the next record's hold starts from zone p again, at the same circle, in the
--- same shape: no snap, because there is nothing left to change. The wall, the HUD,
--- the map and the damage tick all pass the `t` they solved, and they agree to the
--- bit.
---
--- THE CIRCLE IS IMPLIED BY `t`. Every disc of the wall is on its own path between
--- the two placed zones, so `(cx, cy, r)` adds nothing the record and `t` do not
--- already say, and is read only for a record with no shape at all -- the pre-#344
--- off switch -- where the zone is still the two circles.
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
--- THE MAP DRAWS THIS ZONE TOO, front and all: client/storm.lua's storm.map redraws
--- its fill from this function while the zone changes shape, at `overlay.morphHz`.
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

--- WHEN THE SAFE ZONE IS ONE FIXED OUTLINE MOVED AND SCALED, and how: the frame it
--- stands in at sweep fraction `t`. nil while its shape is still changing.
---
--- The map cannot edit a polygon's points -- MINIMAP_LOADER.gfx has no handler that
--- does, only ones that move, scale, turn and fade a clip (client/mapoverlay.lua) --
--- so a changing outline is a redraw, and a redraw is the costly call #350 measured.
--- What it CAN do cheaply is place a polygon it already has, and this says when that
--- is exact: the zone at `t` is the zone at any other `t'` of the same frame moved by
--- (x - x') and scaled by s / s' about the frame's point.
---
---   the second leg of a nested sweep   the destination's shape, standing in `mid`'s
---                                      frame at the knee and in its own at the end
---   the last zone onto its point       its own shape, shrinking about the point
---   a finished sweep                   the destination, standing still
---
--- A BREAKOUT'S ZONE IS THE WALL UNION THE DESTINATION, which is no one outline under
--- any frame while the wall moves, so it has none until the sweep is over. `id` names
--- the family, so a caller can tell a frame it can keep placing from a new one.
--- @param rec table
--- @param t number
--- @return number|nil x, number y, number s, string id
function BR.StormWallFrame(rec, t)
    local e = rec and infoOf(rec)
    if not e then return nil end
    t = BR.Clamp(t or 0.0, 0.0, 1.0)
    local r1 = rec.r1 or 0.0
    if r1 <= 0.0 then
        if not e.nested then return nil end
        return rec.cx1, rec.cy1, 1.0 - t, 'point'
    end
    if t >= 1.0 and not e.nested then return rec.cx1, rec.cy1, r1, 'end' end
    if not e.nested then return nil end
    if e.knee then
        if t < e.knee then return nil end
        local u = (t - e.knee) / (1.0 - e.knee)
        return BR.Lerp(e.mx, rec.cx1, u), BR.Lerp(e.my, rec.cy1, u),
            BR.Lerp(e.ms, r1, u), 'leg2'
    end
    if t >= 1.0 then return rec.cx1, rec.cy1, r1, 'leg2' end
    return nil
end

--- The fastest any corner of the wall moves during this record's sweep, in metres
--- a second: the most any one disc travels plus the most its radius changes, over
--- the time its leg takes -- the faster of the two legs.
---
--- A corner travelling to a corner of a different shape moves further than a
--- circle's edge, (r0 - r1) / T, and one that turns its shape by the knee does it in
--- less than the whole sweep. The damage cushion does not price on a speed at all
--- (BR.StormCushionZones); this is the bound the tests hold every wall to, and the one
--- number to read when a reader wants one.
--- @param rec table
--- @return number metres per second
function BR.StormWallSpeed(rec)
    if not rec then return 0.0 end
    local T = math.max((rec.tShrink or 0.0) / 1000.0, 1.0)
    local e = infoOf(rec)
    if not e then return math.abs((rec.r0 or 0.0) - (rec.r1 or 0.0)) / T end
    local function fastest(from, to, secs)
        local best = 0.0
        for i = 1, #from do
            local a, b = from[i], to[i]
            local v = math.sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2) + math.abs(b.r - a.r)
            if v > best then best = v end
        end
        return best / secs
    end
    if not e.knee then return fastest(e.src, e.dst, T) end
    return math.max(fastest(e.src, e.mid, e.knee * T),
        fastest(e.mid, e.dst, (1.0 - e.knee) * T))
end

-- ═══ THE DAMAGE CUSHION'S 0.7 s OF TRAVEL IS THE ZONE ITSELF, 0.7 s EITHER SIDE ═══
--
-- server/storm.lua bills a player only once they are ten metres outside the safe
-- zone, and while the wall moved it added 0.7 s of travel on top -- (r0 - r1) / T, a
-- CIRCLE's edge speed -- because the tick, the 4 Hz position sample and the client's
-- own clock disagree by about that much at the knife edge.
--
-- TWO THINGS OUTRUN A CIRCLE'S EDGE NOW (#344). The morph moves every corner to its
-- own partner, so parts of the wall move two to four times that speed; and a
-- conjoined zone GROWS into its destination during the HOLD, where the rule added
-- nothing at all -- a front doing 70 m/s on average at phase 2 and 180 at worst, so a
-- client clock a tenth of a second ahead could show a player inside ground the
-- server had not grown to yet, and bill them for it.
--
-- SO THE CUSHION IS WHERE THE ZONE WAS AND WILL BE, rather than a speed: the zone
-- `ms` either side of the tick, whatever is moving and however fast that part of it
-- goes. For two concentric circles that is exactly the old 0.7 s of (r0 - r1) / T;
-- for a morph it is each stretch of wall's own travel, so a player beside a slow
-- stretch gets no more slack than they did; for a growth it is the front's. Built
-- once a tick, three zones where there was one, and only while something moves: a
-- finished sweep and a grown hold are the zone alone.
--- @param rec table
--- @param now number   server time, ms
--- @param ms number    how far either side
--- @return table zones  the zone `ms` before and after `now` -- empty while it stands still
function BR.StormCushionZones(rec, now, ms)
    local out = {}
    if not rec then return out end
    local _, _, _, st, _, _, _, g = BR.StormAt(rec, now)
    local moving = st == BR.StormPhase.SHRINKING
    if not moving and st == BR.StormPhase.HOLDING and g < 1.0 then
        moving = (BR.StormOverlaps(rec))
    end
    if not moving then return out end
    for _, at in ipairs({ now - ms, now + ms }) do
        local cx, cy, r, _, _, _, t, ga = BR.StormAt(rec, at)
        out[#out + 1] = BR.StormZone(rec, cx, cy, r, t, ga)
    end
    return out
end

-- ═══ THE SWEEP IS PRICED ON THE WALL'S OWN ARRIVAL, NOT ON A DISTANCE (#344) ═══
--
-- server/storm.lua prices every sweep for the furthest player's run -- the authored
-- `shrink` is only a ceiling -- so that "a straggler two kilometres out gets their
-- run". That promise is about the wall that will actually chase them.
--
-- WHILE THE WALL WAS A BLEND, THE DISTANCE WAS THE RUN, EXACTLY. (1 - t) Z0 + t D
-- holds (1 - t) P + t N for every P in Z0 and N in D, so a player running straight at
-- the destination's nearest point at d / T stood inside the blend at every instant.
-- (52a7caa priced the circle's distance -- next center less next radius -- which fell
-- short of the drawn shape's, so its own price setter was caught; the distance to the
-- real shape is #344's.)
--
-- THE MORPH DOES NOT HOLD THAT RUNNER. Every corner travels to ITS partner, which is
-- not the point of the destination nearest anybody, so parts of the wall arrive over
-- a player sooner than their distance says. The review of this round priced a phase-5
-- sweep by distance and knocked the runner it was priced for: 139 HP, running at
-- 9 m/s straight at the destination from the moment the wall set off. And since the
-- shape finishes turning at the knee rather than at the end, its corners cover their
-- paths in less than the sweep. So the price reads the wall, both legs of it:
--
--   run(P, Q) = the largest, over the sweep, of lo(t) / t
--
-- where lo(t) is how far along the straight line from P toward a point Q of the
-- destination the safe zone begins at sweep fraction t. A runner who covers
-- run(P, Q) metres per sweep keeps lo(t) behind them, so they are inside at every
-- instant; and on a nested phase so is a faster one, because they stand between that
-- point and the destination, the zone is convex and it holds the destination. It is
-- never less than the length of the line, which is lo(1).
--
-- TWO LINES, AND THE PRICE IS THE BETTER OF THEM: straight at the destination's
-- nearest point, and straight at its centre as far as its edge -- the two ways a
-- player runs at a destination, and the two the round's review measured. A player
-- standing on the very edge of the wall with the nearest point off to the side has a
-- line that runs along the wall, which the wall leaves at once; the line in toward
-- the centre does not.
--
-- ═══ A PLAYER ALREADY OUTSIDE IS HELD AS THE BLEND HELD THEM ═══
--
-- A player `e` meters outside the zone the phase starts in is in the storm already
-- and cannot be kept inside it. They used to be priced on the bare distance, and that
-- was a seam a millimeter wide: the morph can need 1.3 times the distance, so a
-- player 0.5 m out was priced 146 m short of one 0.5 mm in, and their run left them
-- 65 m out of the wall. That is the phase-5 runner above: the round's final review
-- found them 0.5 m out, still knocked for 136 HP. And the players the seam caught are
-- ordinary ones -- a 4 Hz sample of somebody riding the last sweep's wall lands
-- either side of it, the 10 m cushion bills nobody for their first ten meters, and
-- the last sweep's stragglers are who this price is for. Running at d / T, the blend
-- kept them within (1 - t) e of it, so the cushion covered every one who started
-- inside it. That is the promise now, on the wall itself: lo(t) is where the line
-- first comes within (1 - t) e of the safe zone -- the zone grown by that much, which
-- is every corner radius grown by it. At e = 0 it is the inside player's rule
-- exactly, so there is no seam; at t = 1 it is the destination's edge, so the run is
-- never less than the line; and on a nested phase a faster runner is held too,
-- because the grown zone is still convex and still holds the destination.
--
-- (That phase-5 runner is priced 634 m now, past the phase's 60 s ceiling, where no
-- price protects anybody. docs/match-math.md has how often a sweep reaches it.)
--
-- A BREAKOUT reads the same lines against the wall union the destination. There a
-- runner who outpaces the wall's front can be ahead of it in the gap; the price
-- covers the one who keeps with it, as the blend's did.
--
-- A LINE ACROSS A GAP is its own length. Where the straight run already crosses open
-- storm at the start of the sweep -- every line out of a disjoint breakout's zone,
-- and a line from a player on the zone's edge that heads out of it -- no pace keeps
-- the runner inside: they are in the storm from their first step until they reach
-- the destination, which is safe from the start. lo(t) / t asked of such a line only
-- measures how soon the wall behind them passes their starting point, and on a
-- player standing on an edge that retreats it read 279 m / 1e-4 of a sweep: 3.9
-- million metres (phase 6, seed 2051024, BR.Rng(259) -- the breakout audit's case,
-- pinned in tools/test_shared.lua's storm.gap). So such a line is priced at what it
-- can promise, the destination reached by the end of the sweep: its length.
--
-- READ AT 62 INSTANTS -- 48 even steps and 14 more in toward the start, where the
-- maximum sits whenever a corner sets off faster than the blend would -- with where
-- each line meets the zone found exactly (BR.StormShape.lineEntry), and the two best
-- local maxima of the players who could set the price refined by golden section.
--
-- (The numbers below were measured on the one-leg morph, before the knee. The promise
-- is re-asked of the two-leg wall by tools/test_storm.lua's price.run and
-- price.outside, and what the knee costs the pacing is in docs/match-math.md.)
--
-- MEASURED over 5,472 players across 280 sweeps of 40 matches, against the zone the
-- damage tick bills at 1,000 instants: a runner at the priced pace on the better line
-- is never more than 0.23 m outside on a nested phase, at half as fast again too; on
-- a breakout one who holds exactly to it can get up to 10 m ahead of the wall's front
-- into the gap, which the moving cushion covers. The run is longer than the distance
-- for 11.5% of players, 1.48 times it at the 99th percentile. Refining only the
-- players within PRICE_SLACK of the roughest gave the all-refined price in 320 lobbies
-- of 320. Pricing sixty players costs 18 ms on average and 74 at worst, once a phase,
-- on the server only -- the client never prices anything.
--
-- AND FOR PLAYERS ALREADY OUTSIDE, over 200 matches: 24 points of every sweep's start
-- zone pushed 0.5 m and 5 m out, each priced alone and run at 9 m/s straight at the
-- nearest point or the center. Not one was billed on the better line, where 6, 6, 5
-- and 3 sweeps of phases 2 to 5 billed one on the distance's price; on the nearest
-- point's line alone, the nested sweeps with a billed runner 0.5 m out fell from 69,
-- 66, 46 and 19 to 0, 3, 5 and 1, which is what a player just inside already saw.
local PRICE_STEPS = 48      -- even samples across the sweep
local PRICE_T0 = 1e-4       -- where the geometric run toward the start stops
local PRICE_TAIL = 0.7      -- its ratio
local PRICE_REFINE = 18     -- golden-section steps per refined maximum
local PRICE_TOL = 1e-3      -- metres: a line that comes this close has arrived
local PRICE_SLACK = 1.5     -- a player whose rough price is within this factor of the
                            -- lobby's roughest is refined before the price is set

--- The sweep fractions the price reads the wall at, ascending. Built once.
local priceTs = nil
local function priceTimes()
    if priceTs then return priceTs end
    local tail, t = {}, 1.0 / PRICE_STEPS
    while t * PRICE_TAIL > PRICE_T0 do
        t = t * PRICE_TAIL
        tail[#tail + 1] = t
    end
    local ts = {}
    for i = #tail, 1, -1 do ts[#ts + 1] = tail[i] end
    for k = 1, PRICE_STEPS do ts[#ts + 1] = k / PRICE_STEPS end
    priceTs = ts
    return ts
end

--- What the price keeps on a record: the wall's corner list at each sample, built on
--- first use, and the destination and the start zone it measures against.
local function priceOf(rec, e)
    local pr = e.price
    if pr then return pr end
    local SS = BR.StormShape
    local D = BR.StormTarget(rec)
    pr = { ks = {}, D = D,
           dks = (D.hull and D.hull.ks) or SS.discHull(D.discs or {}),
           zone0 = BR.StormZone(rec, rec.cx0, rec.cy0, rec.r0, 0.0, 1.0),
           zks0 = SS.discHull(e.src),
           -- ON A BREAKOUT THE DESTINATION IS ITS OWN PART, and a line may reach it
           -- before it reaches the wall. A destination of no radius is no part.
           apart = (not e.nested) and (rec.r1 or 0.0) > 0.0 }
    e.price = pr
    return pr
end

--- Where along one line the safe zone begins, given the wall's corner list: no
--- further than `L`, where the line is inside the destination. `grow` is the margin a
--- player who started outside is allowed at this instant -- the zone grown by it,
--- which is every radius of both corner lists grown by it (lineEntry).
local function loAlong(pr, ks, px, py, ux, uy, L, grow)
    local SS = BR.StormShape
    local tol = PRICE_TOL + grow
    local s = SS.lineEntry(ks, px, py, ux, uy, tol)
    if pr.apart then
        local sd = SS.lineEntry(pr.dks, px, py, ux, uy, tol)
        if sd and (not s or sd < s) then s = sd end
    end
    if not s or s > L then s = L end
    return s
end

--- Does the straight run along this line cross open storm at the very start of the
--- sweep -- ground outside both the zone the wall starts as and the destination, by
--- more than the margin `out` a player who started outside is allowed? Only a
--- breakout's line can: a nested zone is convex and holds the player and the
--- destination both. See "a line across a gap" in the section note.
local function gappedAtStart(pr, px, py, ux, uy, L, out)
    if not pr.apart or not pr.zks0 then return false end
    local SS = BR.StormShape
    local tol = PRICE_TOL + out
    local qx, qy = px + ux * L, py + uy * L
    local spans = {}
    for _, ks in ipairs({ pr.zks0, pr.dks }) do
        local a = SS.lineEntry(ks, px, py, ux, uy, tol)
        if a and a <= L then
            local back = SS.lineEntry(ks, qx, qy, -ux, -uy, tol) or L
            spans[#spans + 1] = { a, L - back }
        end
    end
    table.sort(spans, function(p, q) return p[1] < q[1] end)
    local reach = 0.0
    for _, sp in ipairs(spans) do
        if sp[1] > reach + 1e-6 then return true end
        if sp[2] > reach then reach = sp[2] end
    end
    return reach < L - 1e-6
end

--- run(P, Q) for one line: from (px, py) along (ux, uy) to where it is inside the
--- destination, `L` metres on, for a player `out` m outside the zone the phase
--- starts in -- 0 inside it -- who is held to (1 - t) out of it. Refined when `refine`.
local function lineRun(e, pr, px, py, ux, uy, L, out, refine)
    local function wallAt(t) return hullAt(e, t) end
    local ts = priceTimes()
    local vals, best = {}, L
    for k = 1, #ts do
        local ks = pr.ks[k]
        if not ks then
            ks = wallAt(ts[k])
            pr.ks[k] = ks
        end
        vals[k] = loAlong(pr, ks, px, py, ux, uy, L, (1.0 - ts[k]) * out) / ts[k]
        if vals[k] > best then best = vals[k] end
    end
    if not refine then return best end

    -- THE TWO BEST LOCAL MAXIMA, refined. Ties go to the earlier sample, so the order
    -- the refinement runs in -- and so the answer -- is fixed.
    local peaks = {}
    for k = 1, #ts do
        local v = vals[k]
        if v > L and (k == 1 or v >= vals[k - 1]) and (k == #ts or v > vals[k + 1]) then
            peaks[#peaks + 1] = k
        end
    end
    table.sort(peaks, function(a, b)
        if vals[a] ~= vals[b] then return vals[a] > vals[b] end
        return a < b
    end)
    local g = 0.5 * (math.sqrt(5.0) - 1.0)
    local function f(t)
        return loAlong(pr, wallAt(t), px, py, ux, uy, L, (1.0 - t) * out) / t
    end
    for i = 1, math.min(2, #peaks) do
        local k = peaks[i]
        local a = (k > 1) and ts[k - 1] or 0.5 * ts[k]
        local b = ts[k + 1] or 1.0
        local c, h = b - g * (b - a), a + g * (b - a)
        local fc, fh = f(c), f(h)
        for _ = 1, PRICE_REFINE do
            if fc > fh then
                b, h, fh = h, c, fc
                c = b - g * (b - a)
                fc = f(c)
            else
                a, c, fc = c, h, fh
                h = a + g * (b - a)
                fh = f(h)
            end
        end
        if fc > best then best = fc end
        if fh > best then best = fh end
    end
    return best
end

--- run(P): the better of the two lines. See the section note.
local function runOf(rec, e, px, py, refine)
    local SS = BR.StormShape
    local pr = priceOf(rec, e)
    local r1 = rec.r1 or 0.0
    local d
    if r1 > 0.0 then d = SS.distance(pr.D, px, py) else d = BR.Dist(px, py, rec.cx1, rec.cy1) end
    if d <= 0.0 then return 0.0 end
    -- OUTSIDE THE ZONE THE PHASE STARTS IN, by this much: see the section note.
    local out = math.max(0.0, SS.distance(pr.zone0, px, py))

    -- STRAIGHT AT THE NEAREST POINT.
    local nx, ny = rec.cx1, rec.cy1
    if r1 > 0.0 then nx, ny = SS.pointAtArc(pr.D, SS.nearestArc(pr.D, px, py)) end
    local L = BR.Dist(px, py, nx, ny)
    if not (L > 0.0) then return d end
    local ux0, uy0 = (nx - px) / L, (ny - py) / L
    local best = L
    if not gappedAtStart(pr, px, py, ux0, uy0, L, out) then
        best = lineRun(e, pr, px, py, ux0, uy0, L, out, refine)
    end

    -- AND STRAIGHT AT THE CENTRE, as far as the destination's edge.
    local C = BR.Dist(px, py, rec.cx1, rec.cy1)
    if r1 > 0.0 and C > 0.0 then
        local ux, uy = (rec.cx1 - px) / C, (rec.cy1 - py) / C
        local Lc = SS.lineEntry(pr.dks, px, py, ux, uy, 0.0)
        if Lc and Lc > 0.0 and Lc < best then
            local v = Lc
            if not gappedAtStart(pr, px, py, ux, uy, Lc, out) then
                v = lineRun(e, pr, px, py, ux, uy, Lc, out, refine)
            end
            if v < best then best = v end
        end
    end
    return best
end

--- The metres per sweep a straight run from (px, py) to the destination must be
--- PRICED AT so that the wall never catches the runner: see the section note. 0
--- inside the destination. A player outside the zone the phase starts in is priced
--- so that they are never further outside than the blend would have left them.
--- @param rec table     a record for the phase being priced -- its tShrink is not read
--- @param px number
--- @param py number
--- @return number metres per sweep
function BR.StormSweepRun(rec, px, py)
    if not rec then return 0.0 end
    local e = infoOf(rec)
    if not e then
        -- THE PRE-#344 OFF SWITCH: two circles, and the blend's own answer.
        return math.max(0.0, BR.Dist(px, py, rec.cx1, rec.cy1) - (rec.r1 or 0.0))
    end
    return runOf(rec, e, px, py, true)
end

--- The furthest run in a lobby: the largest BR.StormSweepRun over `points`, which is
--- what server/storm.lua prices a sweep at.
---
--- REFINED ONLY WHERE IT CAN MATTER. Every player's price is read off the shared
--- samples first, and only those within PRICE_SLACK of the roughest are refined -- a
--- refinement builds the wall afresh at every instant it reads, and only the largest
--- answer sets the price.
--- @param rec table
--- @param points table   { { x, y }, ... }
--- @return number metres per sweep
function BR.StormSweepPrice(rec, points)
    local best = 0.0
    if not rec then return best end
    local e = infoOf(rec)
    local rough, top = {}, 0.0
    for i = 1, #points do
        local p = points[i]
        if e then rough[i] = runOf(rec, e, p.x, p.y, false)
        else rough[i] = BR.StormSweepRun(rec, p.x, p.y) end
        if rough[i] > top then top = rough[i] end
    end
    for i = 1, #points do
        local v = rough[i]
        if e and v > 0.0 and v * PRICE_SLACK >= top then
            v = runOf(rec, e, points[i].x, points[i].y, true)
        end
        if v > best then best = v end
    end
    return best
end

--- HOW LONG A SWEEP IS, priced on the wall it will be: seconds, and the run it was
--- priced for.
---
--- The price is metres per sweep, and the wall it reads turns into the destination's
--- shape `morph.leadSeconds` before the sweep ends -- so the wall at a fraction of the
--- sweep, and the price with it, depends on the length the price sets. This starts at
--- the shortest sweep, whose knee is earliest and whose corners are fastest, prices a
--- record of that length (`probeFor(seconds)`), and lengthens it to what that price
--- asks for until the price read at a length asks for no more than that length --
--- the length and the wall it was priced on are then the ones published. It only ever
--- lengthens, and stops at the ceiling. MEASURED over 40 chains of placed zones, 240
--- sweeps: 161 were repriced after leaving the floor, and every published length was
--- one its own wall's price fits, or the ceiling (tools/test_shared.lua's storm.gap).
--- Pricing twice costs twice: 18 ms a phase on average becomes about 36, server only.
--- @param probeFor function   seconds -> a record of this phase with that sweep
--- @param points table        { { x, y }, ... }
--- @param pace number         metres per second
--- @param minS number         the shortest sweep, seconds
--- @param maxS number         the longest, seconds
--- @return number seconds, number metres per sweep
local SWEEP_ROUNDS = 4
function BR.StormSweepSeconds(probeFor, points, pace, minS, maxS)
    local sec = minS
    if maxS < sec then sec = maxS end
    local run = 0.0
    for _ = 1, SWEEP_ROUNDS do
        run = BR.StormSweepPrice(probeFor(sec), points)
        local want = BR.Clamp(run / pace, minS, maxS)
        if want <= sec then return sec, run end
        sec = want
    end
    return sec, run
end

--- THE WALL AT SWEEP FRACTION `t`, AS A RECORD CAN CARRY IT: the `mo` a freeze, a
--- thaw or a same-phase `brphase` starts its record from. See the record's header.
---
--- nil for a record still holding in the zone it started as, because a record built
--- from that zone's circle starts as that zone anyway. Otherwise every moving disc at
--- `t` with the destination disc it is heading for -- and, on a nested phase, the
--- discs the wall rests on in that leg too (the grown destination's before the knee,
--- the destination's own after it), because they are part of the wall's hull and
--- part of what the next record's morph must keep. Exact duplicates are dropped, so a
--- chain of freezes does not grow what it carries by the discs it already has.
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
    local d, b, seen = {}, {}, {}
    local function add(x, y, r, i)
        local key = ('%a|%a|%a|%d'):format(x, y, r, i)
        if seen[key] then return end
        seen[key] = true
        d[#d + 1], d[#d + 2], d[#d + 3] = x, y, r
        b[#b + 1] = i
    end
    local from, to, u, keep = legOf(e, t)
    local s = 1.0 - u
    for i = 1, #e.src do
        local a, q = from[i], to[i]
        if t >= 1.0 then
            q = e.dst[i]
            add(q.x, q.y, q.r, e.bi[i])
        elseif t <= 0.0 then
            a = e.src[i]
            add(a.x, a.y, a.r, e.bi[i])
        else
            add(s * a.x + u * q.x, s * a.y + u * q.y, s * a.r + u * q.r, e.bi[i])
        end
    end
    -- ON A NESTED PHASE, WHAT THE WALL RESTS ON THIS LEG: the grown destination before
    -- the knee, each disc heading for the destination disc its partner is; the
    -- destination itself after it.
    if e.nested and t > 0.0 then
        if keep == e.mid and t < 1.0 then
            for i = 1, #e.mid do
                local q = e.mid[i]
                add(q.x, q.y, q.r, e.bi[i])
            end
        else
            for k = 1, #e.keep do
                local q = e.keep[k]
                add(q.x, q.y, q.r, k)
            end
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

--- The CEILING on a phase's sweep, in seconds: the authored `shrink`, lifted on a
--- phase that rolled a breakout -- by `shrinkFactor`, and by the real shapes' reach.
---
--- ═══ THE 2.5 WAS A RATIO OF CIRCLE RUNS ═══
---
--- `shrinkFactor` was sized for circles (2026-08-06): the furthest anyone standing in
--- the zone a phase starts in can be from a separated destination is its far rim to
--- the destination's near one, and with the centres at most r0 + r1 + gapMax * r0
--- apart that is never more than (2 + gapMax) * r0 -- the "three times" a nested run
--- that the config's comment argues from. The placement has measured the gap between
--- the SHAPES since #344, and a zone stretched up to 3:1 reaches further from its
--- centre than its circle did, on both sides of the gap: measured over 300 forced
--- breakouts a phase, the furthest run is 3.4 to 4.0 r0 at worst against the circle's
--- 2.5, and phase 5's ceiling -- which covered every circle breakout's furthest run --
--- fell short on 12 percent of them.
---
--- So the lift keeps the circle's proportion. W, how far the furthest point of the
--- zone the wall starts as lies outside the destination, is read off the real shapes
--- (BR.StormShape.fit, exact at every corner disc that is outside it), and where it
--- is longer than any circle breakout could have been the ceiling grows with it.
--- Never below shrink * shrinkFactor, so a breakout that stayed as close as a circle
--- could have is priced exactly as it always was, and a phase that did not roll one
--- keeps its authored ceiling. The pricing below the ceiling still decides how much of
--- it is used: a lobby near the destination gets a short sweep regardless.
--- @param cfg table        BR.Config.Storm
--- @param rec table        the phase's record (its tShrink is not read)
--- @param brokeOut boolean whether the placement rolled a breakout
--- @return number seconds
function BR.StormSweepCeiling(cfg, rec, brokeOut)
    local p = cfg and cfg.phases and rec and cfg.phases[rec.phase]
    local shrink = (p and p.shrink) or 0.0
    if not brokeOut then return shrink end
    local bo = cfg.breakout or {}
    local ceiling = shrink * (bo.shrinkFactor or 1.0)
    local e = infoOf(rec)
    -- THE PRE-#344 OFF SWITCH is two circles, and a circle never passes its own bound.
    if not e then return ceiling end
    local SS = BR.StormShape
    local dks = SS.discHull(e.keep)
    local circleRun = (2.0 + (bo.gapMax or 0.5)) * (rec.r0 or 0.0)
    if not dks or not (circleRun > 0.0) then return ceiling end
    local W = SS.fit(dks, e.src, 0.0, 0.0, 1.0)
    if W > circleRun then ceiling = ceiling * (W / circleRun) end
    return ceiling
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
