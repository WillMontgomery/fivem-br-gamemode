-- The storm's boundary as a WALKABLE SHAPE rather than as a radius.
--
-- EVERY PHASE IS A RANDOM SHAPE NOW (#344), and that is what this file was
-- built for:
--
--   "ship something that will draw random shaped storm walls for each phase,
--    still matching our approximate positioning and size rules, circles are not
--    allowed."                                      -- the owner, 2026-09-22
--
-- The shape is blob() below: a jittered convex polygon whose corners are each
-- rounded, beveled or sharp, or one zone in ten a plain circle -- runs and arcs,
-- the piece model this file has walked since the day it was written. The
-- renderer does not know it is drawing anything in
-- particular. It asks for a perimeter, walks it in metres, and asks where the
-- boundary is nearest a point -- three questions a circle answers and so does
-- everything below.
--
-- ═══ WHY A LIST OF PIECES AND NOT A ROUNDED RECTANGLE ═══
--
-- The obvious shape language for "a wall of any size with rounded edges" is a
-- rectangle grown by a disc, and it is the wrong one. The proof the owner asked
-- for next is not a rectangle (2026-09-21):
--
--   "take for example 2 storm circles (current and next) which are barely
--    overlapping - like a venn diagram. We should extend the safezone to cover
--    both circles, so if a player gets to the new destination early they are
--    safe."
--
-- That is the UNION OF TWO DISCS, and a rounded rectangle cannot describe it.
-- The union of two overlapping discs is not convex: its outline has two REFLEX
-- corners where the circles cross, and every rounded-rectangle model is convex
-- by construction. Build the rectangle today and it is thrown away the week the
-- Venn zone arrives.
--
-- So a shape here is an ORDERED LIST OF BOUNDARY PIECES plus a containment test,
-- and there are two piece kinds and no more:
--
--   arc: a centre, a radius, a start angle and a SIGNED sweep
--   seg: two endpoints
--
-- which is enough for all of these, without a third spelling of any of them:
--
--   a circle            one arc of 2*pi
--   a union of 2 discs  two arcs (or one, or two whole circles -- see union2)
--   a rounded rect      four segments and four arcs
--   a capsule           two segments and two arcs
--
-- ═══ AND THE ROUNDED RECTANGLE SHIPS NOW, WHICH IS NOT A REVERSAL ═══
--
-- roundedRect() exists below (#335 -- "Can you make the storms squircles instead
-- to prove our new logic?"), and the section above is still the reason this file
-- is a piece list. The rejected design was a rounded rectangle AS THE SHAPE
-- LANGUAGE -- one convex box that every zone had to be expressed in, which the
-- Venn union cannot be. What ships is a rounded rectangle as ONE OF THE SHAPES
-- THE LIST CAN HOLD, beside the union, each with its own signed distance. That is
-- the difference between a language and a vocabulary entry, and it is why nothing
-- above had to be unpicked to add it.
--
-- ═══ EVERY SHAPE CARRIES ITS `kind`, AND THE QUERIES DISPATCH ON THAT ═══
--
-- distance() and inset() used to ask whether the shape had a `discs` list and
-- error when it did not. That test was right while every shape in the file was a
-- union of discs and becomes a trap the moment one is not: a shape that grew a
-- disc list for some unrelated reason -- a bounding disc, a broad-phase cull --
-- would silently start being MEASURED as the union of it. So the shape names
-- itself, the queries switch on the name, and a kind with no implementation
-- still errors. See distance().
--
-- ═══ THE SWEEP IS SIGNED, WHICH IS WHAT MAKES A PIECE SELF-DESCRIBING ═══
--
-- Interior on the LEFT is the convention, as it is for the surveyed boundary in
-- polygon.lua. An arc swept counter-clockwise about its own centre therefore has
-- its interior toward that centre and its outward normal pointing radially OUT;
-- an arc swept clockwise bounds a hole, and its outward normal points radially
-- IN. One sign carries that, so pointAtArc can hand back a normal without being
-- told which kind of piece it is standing on.
--
-- A HOLE IS NOT A REFLEX CORNER, AND THIS FILE ONLY MEETS THE SECOND. A Venn
-- union's two reflex vertices are where two COUNTER-CLOCKWISE arcs meet, and
-- both normals there point outward -- which is why union2 builds both of its
-- arcs counter-clockwise and why the sign never goes negative in it. No
-- constructor here sweeps clockwise, so that half of the sign is carried
-- against the day something does and is not exercised today. Said plainly
-- because the first draft of this paragraph claimed the reflex corners were the
-- clockwise case, which would have sent the next reader looking for a bug in
-- union2 that is not there.
--
-- ═══ AND A BOUNDARY IS A LIST OF COMPONENTS, NOT ONE LOOP ═══
--
-- A disjoint union2 is TWO closed loops. That is not a curiosity: the solver
-- really produces it, and it is the difference between a wall and two walls
-- kilometres apart. Every query below answers for the whole boundary, which is
-- right for a perimeter, a signed distance and a nearest point -- and wrong for
-- anything that walks a WINDOW of it, because arc length 0 and arc length P1 are
-- on different islands and a window that straddles the seam draws half its
-- columns behind the viewer. So the shape carries its component ranges,
-- components() and componentAt() hand them out, and pointAtComponent() wraps
-- inside one instead of around both. seal() and pointAtComponent() carry the
-- measured numbers.
--
-- ═══ THE CUMULATIVE TABLE IS BUILT ONCE, AT CONSTRUCTION ═══
--
-- Every query below is answered off one number per piece -- the arc length at
-- that piece's start -- computed once when the shape is built. For a circle the
-- list is one piece long, so a per-frame query is one comparison and one sin/cos
-- pair: cheaper than the atan2 it replaces, and it stays cheap as pieces are
-- added because a storm boundary is single digits of them, never hundreds.
--
-- ═══ THE TRAP THIS FILE EXISTS TO CLOSE ═══
--
-- The column renderer used to index its slots as `first + i` and let that run
-- negative or past the slot count, because math.cos and math.sin accept any
-- angle and wrap for free. AN ARC WALK GETS NO SUCH GIFT, AND ITS FAILURE IS
-- SILENT RATHER THAN LOUD: with the wrap removed, an s past the end does not
-- error, it falls through the piece scan to the LAST piece's far end, so every
-- off-end slot stacks another marker on the same seam and the wall quietly
-- thins. A nil would at least have said something. So pointAtArc wraps s into
-- [0, P) ITSELF, for every caller, rather than trusting each one to do it.

BR = BR or {}
BR.StormShape = {}

local sin, cos, sqrt, atan, abs = math.sin, math.cos, math.sqrt, math.atan, math.abs
local max, huge, pi = math.max, math.huge, math.pi
local TAU = pi * 2.0

-- Metres of slack on the four-way case split in union2. A nanometre, for the
-- same reason polygon.lua picks one: exact equality is not reachable in doubles
-- at map coordinates, and a nanometre is nine orders of magnitude below anything
-- that could change which case a pair of circles is in.
local EPS = 1e-9

-- THE FLOOR ON ANY RADIUS THIS FILE BUILDS, AND IT IS THE SHIPPING ONE.
--
-- A zero-radius arc is a boundary with no length, and a shape with no length has
-- no point at s, no nearest point and no normal -- so every consumer would need
-- a special case for it, and the one that forgot would divide by zero in a
-- per-frame draw call. client/storm.lua's shipping 'solid' path already floors
-- its drawn radius at one metre for the same reason (`math.max(1.0, ...)`), so
-- flooring here keeps the two paths identical in the case rather than giving the
-- generalised one its own behaviour. Sub-metre is far below the storm's own
-- resolution: the wall is drawn in 30m slots.
local MIN_RADIUS = 1.0

--- Arc length remaining strictly positive, for a radius a caller may have
--- shrunk to nothing.
local function radius(r)
    return max(MIN_RADIUS, r or 0.0)
end

--- A counter-clockwise sweep from angle a to angle b, in (0, 2*pi].
---
--- A zero difference means "all the way round" rather than "no arc at all": the
--- only way to ask for a zero-length arc is to build one directly, which seal()
--- drops.
local function ccwSweep(a, b)
    local s = (b - a) % TAU
    if s <= 0.0 then s = TAU end
    return s
end

-- --------------------------------------------------------------- the pieces ---

--- One boundary arc. `sweep` is signed: positive is counter-clockwise.
---
--- `exact` SKIPS THE MIN_RADIUS FLOOR, and only a corner may ask for it. A corner
--- arc is tangent to the two runs either side of it, and floored up to a metre it
--- would no longer meet them -- the boundary would stop chaining. Every circle this
--- file builds on its own is still floored; see MIN_RADIUS.
local function arc(cx, cy, r, a0, sweep, exact)
    if not exact then r = radius(r) end
    return {
        kind = 'arc',
        cx = cx + 0.0, cy = cy + 0.0, r = r,
        a0 = a0 + 0.0, sweep = sweep + 0.0,
        len = abs(sweep) * r,
        -- Which way "out" is, from this piece's own centre. See the header.
        out = (sweep >= 0.0) and 1.0 or -1.0,
    }
end

--- One straight boundary run, from (x0, y0) to (x1, y1).
local function seg(x0, y0, x1, y1)
    local dx, dy = x1 - x0, y1 - y0
    local len = sqrt(dx * dx + dy * dy)
    if len <= 0.0 then return nil end     -- no direction, so no normal
    local ux, uy = dx / len, dy / len
    return {
        kind = 'seg',
        x0 = x0 + 0.0, y0 = y0 + 0.0, x1 = x1 + 0.0, y1 = y1 + 0.0,
        ux = ux, uy = uy,
        -- Interior on the left, so outward is the RIGHT of travel.
        nx = uy, ny = -ux,
        len = len,
    }
end

--- Where a single piece is at `t` metres along ITSELF, and the outward normal.
local function pieceAt(pc, t)
    if pc.kind == 'arc' then
        local th = pc.a0 + pc.sweep * (t / pc.len)
        local c, s = cos(th), sin(th)
        return pc.cx + c * pc.r, pc.cy + s * pc.r, c * pc.out, s * pc.out
    end
    return pc.x0 + pc.ux * t, pc.y0 + pc.uy * t, pc.nx, pc.ny
end

--- Seal a piece list into a shape: the cumulative-length table and the total.
---
--- ═══ WHAT `meta` CARRIES, AND WHY NONE OF IT IS DERIVED FROM THE PIECES ═══
---
--- `kind` names the shape. Every constructor sets its own, and distance() and
--- inset() switch on it -- so a constructor that forgets is a shape with no
--- signed distance, which errors the first time anything measures it rather than
--- being quietly measured as something else.
---
--- `meta.discs` is the shape's containment test when it HAS one -- the list of
--- discs it is the union of. `meta.box` is the rounded rectangle's equivalent:
--- centre, outer half-extents and corner radius. Either one is the arithmetic
--- distance() and inset() are exact from, which is why it is recorded here rather
--- than reconstructed from the piece list later. Reconstructing it would mean
--- reading four arc centres back out and hoping they still mean what they meant.
---
--- `meta.prims` is the MAP's draw list, and it is deliberately a SEPARATE field
--- from `discs` rather than an extra entry in it. `discs` means "this shape is
--- exactly the union of these discs" and is the contract the two queries are
--- built on; a rounded rectangle is not the union of its corner discs, so a map
--- piece parked in there would turn distance()'s honest error() into a silently
--- shallow answer. See mapPrimitives().
---
--- PRIVATE, AND THE PIECE BUILDERS ABOVE ARE TOO. Every shape that exists is
--- named by a constructor below, so there is no door anywhere -- in the game or
--- in a test -- through which a raw piece list can arrive unvalidated.
---
--- ═══ IT ALSO GROUPS THE PIECES INTO COMPONENTS, AND THAT IS NOT BOOKKEEPING ═══
---
--- A boundary is not always ONE closed loop. A disjoint union2 is two, and the
--- difference is kilometres wide: arc length 0 is on one circle and arc length
--- P1 is on the other. Anything that walks a WINDOW of the boundary -- which is
--- the column renderer, above maxDraw -- has to stay inside one loop, because a
--- window that straddles the seam spends half its budget on the island the
--- viewer is not standing on and leaves a hole in the curtain in front of them.
---
--- Measured before this existed, on phase-4 geometry (current r520 at the
--- origin, next r260 at 1040m, viewer at 560, 0): 48 markers drawn, 24 on the
--- near circle covering bearings 2 to 79 degrees only, and 24 dumped on the far
--- circle behind the player, with no curtain at all immediately clockwise of
--- them. Swept round the near circle in 5 degree steps, 32 of 72 viewer bearings
--- showed a broken colonnade at phase 4 and 17 of 72 at phase 3. The nested and
--- Venn cases are single loops and measured 0 of 72, which is why no test caught
--- it: they are the only shapes the suite drives through the windowed branch.
---
--- A piece begins a new component when it is marked `newComponent`; every other
--- piece extends the one before it. That is general rather than a special case
--- for union2: a shape with a hole in it, or two rounded rectangles, says so the
--- same way.
---
--- @param pieces table       array of arc/seg pieces, in boundary order
--- @param kind string        this shape's name, for the query dispatch
--- @param meta table|nil     { discs, box, hull, parts, prims }, all optional
--- @return table shape
local function seal(pieces, kind, meta)
    meta = meta or {}
    local keep, P = {}, 0.0
    local comps = {}
    for _, pc in ipairs(pieces or {}) do
        -- A zero-length piece is not a boundary, and left in the list it would
        -- be selected by the scan below only for s exactly at its start -- the
        -- one index where its own length would then divide.
        if pc and pc.len > 0.0 then
            pc.s0 = P
            -- THE FIRST SURVIVING PIECE ALWAYS OPENS A COMPONENT, whatever it is
            -- marked. A dropped zero-length piece must not be able to take the
            -- shape's only component range with it.
            if #comps == 0 or pc.newComponent then
                comps[#comps + 1] = { s0 = P, len = 0.0 }
            end
            local c = comps[#comps]
            c.len = c.len + pc.len
            pc.comp = #comps
            P = P + pc.len
            keep[#keep + 1] = pc
        end
    end
    return {
        pieces = keep, P = P, comps = comps,
        kind = kind,
        discs = meta.discs, box = meta.box, prims = meta.prims,
        -- `hull` is the blob's equivalent of `box`: its corner list -- every
        -- corner's centre, radius and range of normals -- which is the arithmetic
        -- its exact signed distance and its exact erosion are both written in.
        -- `parts` is a
        -- two-component union's, and the two are deliberately different fields
        -- for the reason `discs` and `prims` are -- see the note above, and
        -- blobUnion's, which says what a part may and may not be asked.
        hull = meta.hull, parts = meta.parts, blob = meta.blob,
    }
end

--- Which piece holds arc length s, and how far along that piece it is.
---
--- `s` must already be wrapped into [0, P). One comparison for a circle.
local function pieceAtArc(shape, s)
    local pcs = shape.pieces
    local n = #pcs
    for i = 1, n do
        local pc = pcs[i]
        if s < pc.s0 + pc.len then return pc, s - pc.s0 end
    end
    -- Only reachable for s at or fractionally under P, where the floating-point
    -- sum of the piece lengths lands under the total. The last piece's end is
    -- the honest answer.
    local pc = pcs[n]
    return pc, pc and pc.len or 0.0
end

-- ------------------------------------------------------------ constructors ---

--- A circle. THE ONLY CONSTRUCTOR ANYTHING IN THE GAME CALLS.
--- @return table shape
function BR.StormShape.circle(cx, cy, r)
    r = radius(r)
    return seal({ arc(cx, cy, r, 0.0, TAU) }, 'circle', {
        discs = { { x = cx + 0.0, y = cy + 0.0, r = r } },
        -- ONE RADIUS BLIP, WHICH IS WHAT THE MAP HAS ALWAYS DRAWN. This descriptor
        -- is the reason a squareness of zero is a no-op rather than a near-no-op:
        -- the client materialises it into the same BR.Native.radiusBlip call the
        -- three rings were making before mapPrimitives existed.
        prims = { { kind = 'radius', cx = cx + 0.0, cy = cy + 0.0, r = r } },
    })
end

--- A capsule: a segment with a radius. Two straight runs and two end caps.
---
--- NOT CALLED BY ANYTHING, HERE OR IN THE GAME, and it is not the next shape
--- either -- the union of two discs is. It exists because the seg branch of the
--- walk above has to be driven by something real, and a capsule is the smallest
--- shape that has both piece kinds in it. The alternative was shipping that
--- branch untested behind a promise that the rounded rectangle will exercise it
--- one day. Delete this the day a shape with straight runs actually ships and can
--- carry those tests instead.
---
--- THAT DAY IS CLOSE AND IS NOT HERE. roundedRect below has straight runs and the
--- game can build one, so the seg branch now has a caller that is not a stand-in
--- -- but only at a squareness the config ships at zero, so on a live client this
--- is still the only shape in the file with a seg in it. Deleting the capsule is
--- one config value and its own commit away; doing it in the same change that
--- introduces the shape replacing it would leave the seg branch untested in
--- between.
---
--- NO MAP PRIMITIVE AND NO SIGNED DISTANCE, deliberately. Nothing draws a capsule
--- on the minimap or measures a player against one, and inventing either would be
--- inventing a claim rather than recording one. mapPrimitives(), distance() and
--- inset() all error on this kind, which is exactly what should happen the first
--- time somebody tries to ship it.
---
--- Walked counter-clockwise, so the interior stays on the left: out along the
--- RIGHT of the axis, a half turn about the far end, back along the other side,
--- a half turn about the near end.
--- @return table shape
function BR.StormShape.capsule(x0, y0, x1, y1, r)
    r = radius(r)
    local dx, dy = x1 - x0, y1 - y0
    local len = sqrt(dx * dx + dy * dy)
    if len <= 0.0 then return BR.StormShape.circle(x0, y0, r) end
    local ux, uy = dx / len, dy / len
    -- Right of travel, which is where the first run sits and the angle both
    -- caps are measured from.
    local rx, ry = uy, -ux
    local a = atan(ry, rx)
    return seal({
        seg(x0 + rx * r, y0 + ry * r, x1 + rx * r, y1 + ry * r),
        arc(x1, y1, r, a, pi),
        seg(x1 - rx * r, y1 - ry * r, x0 - rx * r, y0 - ry * r),
        arc(x0, y0, r, a + pi, pi),
    }, 'capsule')
end

--- The UNION OF TWO DISCS, which is the whole point of this file.
---
--- ═══ NOTHING CALLS THIS YET, ON PURPOSE ═══
---
--- The commit that introduced it changes nothing a player can see. There is no
--- way in the game to ask the storm for this shape, and the renderer builds a
--- circle from the live record every frame exactly as it always did. What this
--- function is for is the next commit -- the safe zone extended to cover the
--- current circle AND the one it is closing toward, so that a player who gets to
--- the new destination early is safe there.
---
--- ═══ FOUR CASES, AND THE THIRD ONE IS NOT A BUG ═══
---
---   ONE CONTAINS THE OTHER  the shape is the containing disc, one arc. Includes
---                           two identical circles and internal tangency.
---   THEY OVERLAP            two arcs, meeting at the two crossings. The
---                           boundary has two reflex corners, which is exactly
---                           what rules out a convex shape language.
---   THEY ARE DISJOINT       two WHOLE circles: a boundary with TWO COMPONENTS.
---                           Legal and correct -- the safe zone is two islands
---                           and the gap between them is not safe. The solver
---                           already produces this pair: a breakout separates
---                           the circles entirely and caps the gap between their
---                           edges at gapMax times the predecessor's radius
---                           (shared/storm_solve.lua). External tangency lands
---                           here too, which is why nothing divides by the
---                           half-chord.
---   TANGENT OR IDENTICAL    whichever of the above it degenerates to, decided
---                           by the same three comparisons with a nanometre of
---                           slack, so no case has to divide by zero to find out
---                           it was degenerate.
---
--- WHICH ARC OF EACH CIRCLE SURVIVES is decided by geometry rather than by
--- sampling. The outer part of circle 1 is the part facing away from circle 2,
--- so walking counter-clockwise it BEGINS at the crossing on the left of the
--- centre line and ENDS at the one on the right. Circle 2's outer arc is the
--- mirror of that, which is what makes the two chain end-to-start into one
--- closed loop: arc 1 finishes at the right-hand crossing and arc 2 starts
--- there. tools/test_shared.lua checks that claim the other way round, by
--- proving the interior arcs are NOT on the boundary.
---
--- ═══ A DISC WITH NO RADIUS IS NOT A DISC, AND PHASE 8 IS WHY THAT IS WRITTEN
---     DOWN HERE RATHER THAN IN EITHER CONSUMER ═══
---
--- The final phase closes on a ZERO-RADIUS target: config/storm.lua's phases[8]
--- has `radius = 0.0`, and that is the point everyone is fighting over. Floored
--- at MIN_RADIUS it became a one-metre disc, and a one-metre disc more than about
--- 35 metres from the current circle's centre is DISJOINT from it -- a second
--- component, on a shape whose first component is the wall. Phase 8's reachable
--- offset is up to 60 metres (r 40 plus gapMax 0.5 of it), so that is not a
--- corner, it is most of the phase.
---
--- WHAT IT COST. The column renderer draws a component, so it painted a 4.8m
--- wide, 950m tall purple pillar standing on the exact final point -- measured
--- off the real config: the shape's perimeter is 220m, the slot floor is 48, so
--- ds is 4.6m and the height is render.height * 3 + 50. The damage rule paid for
--- the same disc the other way round, sheltering an eleven-metre bubble (one
--- metre of disc plus ten of cushion) on the destination for the whole sweep --
--- a safe island detached from the wall in the endgame, which is precisely the
--- failure `server.collapse` exists to prevent at the other end of the phase.
---
--- SO NEITHER GETS IT, AND THE DECISION LIVES HERE SO THEY CANNOT DISAGREE.
--- server/storm.lua and client/storm.lua both build their zone with this one
--- call; deciding it in the constructor is the only place where "does that disc
--- exist" has a single answer. The point is still sheltered when the wall
--- actually arrives on it: r reaches the floor, the shape is a one-metre circle,
--- and the ten-metre cushion around it is the same shelter `r + margin` with r at
--- zero always gave.
---
--- THE TEST IS ON WHAT THE CALLER ASKED FOR, NOT ON THE STORED RADIUS, because
--- radius() has already clamped the second. `> 0.0` and not `> MIN_RADIUS`: a
--- caller that genuinely wants a one-metre disc gets one (test_shared.lua's lens
--- block builds two of them to pin distance()'s understatement inside an
--- overlap), and only a radius of nothing at all is nothing at all.
---
--- @return table shape
function BR.StormShape.union2(x1, y1, r1, x2, y2, r2)
    local has1, has2 = (r1 or 0.0) > 0.0, (r2 or 0.0) > 0.0
    if has1 and not has2 then return BR.StormShape.circle(x1, y1, r1) end
    if has2 and not has1 then return BR.StormShape.circle(x2, y2, r2) end
    -- NEITHER, which is the collapsed wall standing on its own target: BR.StormAt
    -- answers (cx1, cy1, 0) at FINISHED and the record's target is the same
    -- point, so the two centres agree and picking the first is picking the wall.
    -- radius() floors it, so this is the one-metre circle the contained case used
    -- to return for the same arguments.
    if not has1 then return BR.StormShape.circle(x1, y1, 0.0) end

    r1, r2 = radius(r1), radius(r2)
    local discs = {
        { x = x1 + 0.0, y = y1 + 0.0, r = r1 },
        { x = x2 + 0.0, y = y2 + 0.0, r = r2 },
    }
    -- ═══ TWO RADIUS BLIPS, AND THE MAP HAS NO BETTER ANSWER THAN THAT ═══
    --
    -- A union of two discs is exactly two filled discs on the map, so this
    -- descriptor pair is not an approximation of anything -- it is the shape, and
    -- it is what the two rings already drew before mapPrimitives existed.
    --
    -- THE OVERLAP IS THE ONE THING IT COSTS, and it is the reason nothing here
    -- tries to be cleverer. Where the two fills cross, the later one composites
    -- over the earlier, so a Venn lens reads darker than either disc -- the same
    -- doubling that made the purple ring "read as flashing" when the blue current
    -- disc was recreated over it (client/storm.lua's blip block carries that
    -- record). There is no overlap-free partition of a Venn union into primitives
    -- the minimap has: no native strokes or fills an arbitrary outline, and the
    -- only alternative is drawing ONE of the two discs, which is a confident lie
    -- about where it is safe to stand on exactly the phase this shape exists for.
    -- Two honest fills with a darker lens is the least wrong thing available.
    local prims = {
        { kind = 'radius', cx = discs[1].x, cy = discs[1].y, r = r1 },
        { kind = 'radius', cx = discs[2].x, cy = discs[2].y, r = r2 },
    }

    local dx, dy = x2 - x1, y2 - y1
    local d = sqrt(dx * dx + dy * dy)

    -- Contained, either way round. Tested first so that d == 0 never reaches
    -- the division below.
    if d + r2 <= r1 + EPS then return BR.StormShape.circle(x1, y1, r1) end
    if d + r1 <= r2 + EPS then return BR.StormShape.circle(x2, y2, r2) end

    -- Disjoint, or touching at exactly one point. Two components.
    --
    -- AND THE SECOND ONE SAYS SO, which is the whole of Defect 1's fix at this
    -- end. Both arcs are whole circles and they do not chain: the first ends
    -- where it began, and the second begins kilometres away. seal() reads the
    -- mark and gives the shape two component ranges, so a window walker can ask
    -- which loop it is standing on instead of wrapping modulo a perimeter that
    -- spans both.
    local far = arc(x2, y2, r2, 0.0, TAU)
    far.newComponent = true
    if d >= r1 + r2 - EPS then
        return seal({ arc(x1, y1, r1, 0.0, TAU), far }, 'union2',
            { discs = discs, prims = prims })
    end

    -- A proper overlap. `a` is how far along the centre line from circle 1 the
    -- two crossings sit, and `h` is how far off it -- so the crossings are the
    -- centre-line point plus and minus h along the perpendicular.
    local ux, uy = dx / d, dy / d
    local a = (d * d + r1 * r1 - r2 * r2) / (2.0 * d)
    local h2 = r1 * r1 - a * a
    local h = (h2 > 0.0) and sqrt(h2) or 0.0
    local mx, my = x1 + a * ux, y1 + a * uy

    -- Left of the centre line, then right of it.
    local lx, ly = mx - h * uy, my + h * ux
    local rx, ry = mx + h * uy, my - h * ux

    local l1 = atan(ly - y1, lx - x1)
    local r1a = atan(ry - y1, rx - x1)
    local l2 = atan(ly - y2, lx - x2)
    local r2a = atan(ry - y2, rx - x2)

    return seal({
        arc(x1, y1, r1, l1, ccwSweep(l1, r1a)),
        arc(x2, y2, r2, r2a, ccwSweep(r2a, l2)),
    }, 'union2', { discs = discs, prims = prims })
end

--- A ROUNDED RECTANGLE: a rectangle grown by a disc. Four runs, four quarter arcs.
---
--- ═══ THE SHAPE THE OWNER ASKED FOR, AND WHY IT IS THIS ONE (#335) ═══
---
---   "The storm border does draw still, and everything is circular. Can you make
---    the storms squircles instead to prove our new logic?"   -- owner, 2026-09-22
---
--- A squircle proper is `|x/a|^n + |y/b|^n = 1`, and this file cannot express it: it
--- walks arcs and segments, and a superellipse is neither for any n -- save the one
--- degenerate case, n = 2 with a = b, which is the circle we already had. A
--- ROUNDED RECTANGLE reads as a squircle, and it is EXACT here -- four straight
--- runs and four quarter arcs, which is the shape the header has listed as one of
--- the four this piece model was built for since the day it was written.
---
--- `hx` and `hy` ARE THE OUTER HALF-EXTENTS, not the inner rectangle's. So the
--- shape spans `2 * hx` by `2 * hy` whatever `cr` is, and `cr` only decides how
--- much of the corner is cut off -- which is the parameterisation both the signed
--- distance and inset() want, and the one that makes `cr == hx == hy` a circle of
--- radius hx rather than a shape three times the size.
---
--- ═══ COUNTER-CLOCKWISE, INTERIOR ON THE LEFT, STARTING AT THE RIGHT EDGE ═══
---
--- Right edge going up, top-right corner, top edge going left, top-left corner,
--- left edge going down, bottom-left corner, bottom edge going right, bottom-right
--- corner -- and the last arc ends exactly where the first run begins. Each run's
--- right of travel is the outward normal (+x, +y, -x, -y in that order) and each
--- arc is swept positively about its own corner centre, so every piece's own
--- `out` is already correct and pointAtArc needs to know nothing about which shape
--- it is walking. tools/test_storm.lua checks the chain the honest way: it asks
--- every piece boundary for its point twice, from each side, and compares.
---
--- ═══ THE CORNER RADIUS FLOORS AT MIN_RADIUS, IT DOES NOT COLLAPSE TO ZERO ═══
---
--- A hard-cornered rectangle is `cr = 0`, and it is the one value this cannot
--- take: arc() floors every radius at MIN_RADIUS, so a `cr` of zero would become
--- four one-metre arcs whose endpoints are NOT the corners the runs were built
--- for, and the boundary would stop chaining. Four one-metre corners on a shape
--- drawn in 30-metre slots is invisible -- the wall's own quads are metres wide --
--- and it errs INWARD, which is the direction this file is allowed to err in. The
--- alternative was a branch that emits four pieces instead of eight, tested by
--- nothing, reached only at a config extreme.
---
--- SO `hx` AND `hy` ARE RAISED TO `cr` RATHER THAN `cr` BEING CUT TO THEM. An
--- inset that eats the straight runs leaves a shape that is still walkable -- a
--- circle of radius cr -- for the same reason MIN_RADIUS exists at all. Cutting cr
--- down instead would let an over-large inset produce a rectangle with corners
--- SHARPER than the shape it came from, which is the one thing an erosion can
--- never do.
---
--- @param cx number   centre
--- @param cy number
--- @param hx number   OUTER half-extent in x
--- @param hy number   OUTER half-extent in y
--- @param cr number   corner radius, floored at MIN_RADIUS and capped at min(hx,hy)
--- @return table shape
function BR.StormShape.roundedRect(cx, cy, hx, hy, cr)
    cx, cy = cx + 0.0, cy + 0.0
    cr = radius(cr)
    hx = max(radius(hx), cr)
    hy = max(radius(hy), cr)
    -- The INNER rectangle: the corner-arc centres sit on its four corners.
    local ix, iy = hx - cr, hy - cr

    -- ═══ APPENDED ONE AT A TIME, BECAUSE A DEGENERATE RUN IS `nil` AND A TABLE
    ---    CONSTRUCTOR WITH A HOLE IN IT TRUNCATES ═══
    --
    -- seg() returns nil for a run of no length, which is right -- a run with no
    -- direction has no normal -- and seal() reads its list with ipairs, which STOPS
    -- AT THE FIRST NIL. Written as one eight-element constructor this shape
    -- therefore sealed to a boundary of ZERO pieces the moment either half-extent
    -- reached the corner radius, which is not a corner case: it is `cr == hx`, the
    -- circle this shape becomes at zero squareness, and it is every inset larger
    -- than the shape (the collapsed endgame plus render.edgeInset lands exactly
    -- there). A shape with no perimeter has no point at s, so the wall silently drew
    -- nothing and distance() answered off the box, which is still correct -- the
    -- worst possible combination, a curtain that is simply absent with the damage
    -- rule unchanged.
    --
    -- FOUND BY MEASURING THE PERIMETER RATHER THAN BY READING THE CODE, which is
    -- why tools/test_storm.lua now asserts the piece count and the perimeter of the
    -- degenerate case rather than only of the pretty one.
    local pieces = {}
    local function push(pc)
        if pc then pieces[#pieces + 1] = pc end
    end
    push(seg(cx + hx, cy - iy, cx + hx, cy + iy))
    push(arc(cx + ix, cy + iy, cr, 0.0, pi * 0.5))
    push(seg(cx + ix, cy + hy, cx - ix, cy + hy))
    push(arc(cx - ix, cy + iy, cr, pi * 0.5, pi * 0.5))
    push(seg(cx - hx, cy + iy, cx - hx, cy - iy))
    push(arc(cx - ix, cy - iy, cr, pi, pi * 0.5))
    push(seg(cx - ix, cy - hy, cx + ix, cy - hy))
    push(arc(cx + ix, cy - iy, cr, pi * 1.5, pi * 0.5))

    return seal(pieces, 'roundedRect', {
        box = { cx = cx, cy = cy, hx = hx, hy = hy, cr = cr },
        -- ═══ ONE AREA BLIP FOR THE WHOLE SHAPE, NOT SIX PRIMITIVES ═══
        --
        -- A rounded rectangle is exactly two crossed rectangles plus four corner
        -- discs, and drawing that on the map would be the exact decomposition and
        -- the wrong picture. Overlapping blip fills COMPOUND: the later one
        -- composites over the earlier in creation order, which is what made the
        -- purple next-circle ring "read as flashing" when the blue current disc
        -- was recreated on top of it (client/storm.lua's blip block). Six pieces
        -- have regions of one, two AND three layers -- the discs sit inside the
        -- rectangles by construction, so there is no overlap-free partition to
        -- find -- and the wall itself is the thing that already got dark bands
        -- from doubled alpha and was rewritten to escape them (#336). The shape
        -- would show its own seams.
        --
        -- SO THE MAP GETS HARD CORNERS AND THE WALL KEEPS THE ROUNDING. The box is
        -- a `w x h` rectangle that CONTAINS the rounded rect, so it over-reports
        -- by cr * (sqrt(2) - 1) at the four corners and is exact everywhere else.
        -- That is the one place in this file that errs OUTWARD, and it is the
        -- minimap rather than the damage test: 82 cm on a 2m corner radius, at a
        -- map scale where the whole zone is a few hundred pixels. Drawing the
        -- INNER box instead would be mean by the same amount along every straight
        -- edge, which is four long lies instead of four short ones.
        --
        -- ONE ENTRY, AND THE MATERIALISER DOES NOT KNOW THAT. It walks whatever
        -- list it is handed and names the first piece, so putting the six-piece
        -- decomposition back the day overlapping fills are measured NOT to
        -- compound is a change to these lines and to nothing else.
        prims = { {
            kind = 'area',
            cx = cx, cy = cy, w = hx * 2.0, h = hy * 2.0,
            -- AXIS ALIGNED, AND THE ZERO IS LOAD-BEARING RATHER THAN A DEFAULT.
            -- _ADD_BLIP_FOR_AREA's own documentation says to set the rotation or
            -- the blip turns with the camera, so 0 is a value this shape is
            -- asserting and the client passes on, not a field left empty.
            rot = 0.0,
        } },
    })
end

-- ------------------------------------------------- the blob, which is the wall ---
--
-- ═══ A CONVEX POLYGON WHOSE CORNERS ARE EACH ROUNDED, BEVELED OR SHARP (#344) ═══
--
--   "we're only drawing squircles (quite well though), can we change to random
--    shapes per phase? There should be a 90% chance of not being a circle, and
--    when not a circle, there should be equal chances for each vertex to be
--    rounded, beveled, or cornered."                  -- the owner, 2026-09-23
--
-- Until this every corner was an arc of ONE radius, so every shape was the convex
-- hull of N equal discs and read from above as a soft blob whatever its count.
-- Now each vertex draws its own finish, and the three are the three things a
-- corner of a convex polygon can be:
--
--   rounded    an arc tangent to both edges -- one corner, one arc
--   beveled    the corner cut off by a chamfer -- two SHARP corners and a run
--   cornered   the vertex itself -- one sharp corner
--
-- ═══ SO A SHAPE IS A LIST OF CORNERS, AND A SHARP CORNER IS AN ARC OF RADIUS 0 ═══
--
-- Every corner is a centre, a radius and the RANGE OF OUTWARD NORMALS it carries
-- the boundary through; the straight runs are what joins one corner's last normal
-- to the next corner's first. A sharp corner is the same record with a radius of
-- zero, a circle is one corner whose range is the whole turn, and a chamfer is two
-- sharp corners with a run between them. One record, three questions answered
-- exactly from it, and none of them needs the corners to be alike:
--
--   THE SIGNED DISTANCE. For a convex body it is the supremum over unit directions
--   u of (<p, u> - h(u)), where h is the support function -- and h here is
--   <c, u> + rho on each corner's own range of u. So the supremum is reached on a
--   run's normal or radially from the one corner whose range holds the direction
--   to p: a maximum over the same pieces the boundary is made of, exact inside as
--   well as out. hullDistance carries it.
--
--   THE EROSION. Shrinking a convex body by d subtracts d from its support
--   function. A corner whose radius is at least d keeps its centre and loses d; a
--   corner smaller than that -- every sharp one -- becomes sharp where its two
--   offset runs meet. See erode().
--
--   THE MORPH. The support function of (1 - t) A + t B is (1 - t) h_A + t h_B, so
--   the shape half way from one zone to the next is ANOTHER CORNER LIST: the two
--   lists' normal ranges merged, each corner's centre and radius interpolated.
--   See morphUnit(), which is why the snap at a phase change could be removed
--   without leaving the piece model.
--
-- THE HULL OF EQUAL DISCS THIS REPLACES was chosen because it made all three exact,
-- and it was right for a shape whose corners were all alike. They are not alike
-- any more, and the corner list keeps every one of the three exact without asking
-- them to be.
--
-- ═══ CONVEXITY IS NOT GUARANTEED BY THE DRAW AND IS ENFORCED, NOT HOPED FOR ═══
--
-- Radii jittered about r can put a vertex inside the line between its neighbours,
-- and a concave shape breaks all three claims above -- the support-function
-- argument IS convexity -- and #356's stitch, which walks the crossings of two
-- convex boundaries. So a draw that fails the test is redrawn from the SAME stream
-- with both jitters reduced, and the last attempt has no jitter at all, which is a
-- regular polygon and convex by construction. The loop therefore always ends on a
-- convex shape and always consumes a deterministic number of values.
--
-- THE CUTS CANNOT UNDO IT. A rounded or beveled vertex eats at most `cut` of the
-- shorter half-edge beside it, so two neighbours between them take at most `cut`
-- of the run they share and it keeps a straight stretch in the middle; the turns
-- are the polygon's own turns, split or kept. A convex polygon stays convex.
local BLOB_TRIES    = 6
local BLOB_FALLOFF  = 0.75

-- ═══ THE CORNER COUNT IS DRAWN PER ZONE, AND THREE THINGS HAD TO MOVE WITH IT ═══
--
--   "We're able to reliably draw squircle storms, but what about random other
--    shapes of various vertices?"                   -- the owner, 2026-09-23
--
-- Each has a knob in config/storm.lua's `shape` block:
--
--   AREA FALLS WITH THE COUNT, so every draw is SCALED to `area` of the circle it
--   replaces, exactly -- the shoelace of the corner list, arcs included, below.
--
--   AND HOLDING AREA PUSHES THE CORNERS OUT, which is the trade. A draw that would
--   reach past `reach` once scaled is REJECTED like a concave one and redrawn
--   tamer, which keeps both numbers at once and pays in how irregular it may be.
--
--   AND A SLOT IS WIDER AT A LOW COUNT, so the slide is in degrees, the same at
--   every count, rather than a fraction of the slot.
--
-- WHY THE REACH IS A REJECTION AND NOT A CORRECTION. Shrinking an over-reaching
-- draw would hand back a phase that plays small, which is the defect the area
-- rule exists to remove.
--
-- THE CENTRE IS INSIDE, AND THAT IS A THEOREM RATHER THAN A HOPE. A convex shape
-- that misses its own centre lies in a half-plane, and the most of a disc of
-- radius `reach` a half-plane holds is half of it -- 0.66 of the circle at 1.15,
-- against the 0.90 every shape is scaled to. Worked through the circular segment,
-- the centre is at least 0.33 of r deep in every shape that ships. #350's
-- in-place map fill and #352's headcount both lean on it.
--
-- BLOB_MAX_CORNERS is only how far up a weight table is read, twice the top of
-- the shipping range.
local BLOB_MAX_CORNERS = 24

-- ═══ THE SLIDE IS STILL BOUNDED BY THE SLOT, BUT ONLY AS A BACKSTOP ═══
--
-- At half a slot two neighbours can reach the same angle and the vertex ORDER can
-- swap, which would turn a convex draw into a self-crossing one. The shipping
-- slide never reaches this -- nine degrees is 0.3 of a twelve-corner slot and less
-- of every smaller one -- so it binds only on a config asking for more corners or
-- more slide than ships.
local BLOB_SLIDE_SLOT = 0.3

-- HOW SHARP A VERTEX MAY BE, in radians of exterior turn, at both ends.
--
-- The lower bound is a convexity test: a turn at or below zero is a reflex vertex.
-- It is a small POSITIVE number rather than zero because a vertex that turns by a
-- nanoradian is convex and useless -- its own tangent length runs away as the turn
-- goes to nothing. The upper bound is the same statement at the other end: a
-- vertex that turns by nearly half a turn is a spike, and erode() divides by the
-- cosine of half the turn, which is what a spike sends to zero.
local BLOB_MIN_TURN = 0.05

-- A radian a trillion times smaller than the smallest turn this file builds. Two
-- normal angles nearer than this are ONE breakpoint when two corner lists are
-- merged, so the merge never makes a corner that turns by nothing.
local ANGLE_EPS = 1e-12

--- What a vertex can be, in the order its roll is read. Fixed, never a pairs() walk,
--- for the reason blobUnit reads the corner counts in order.
local VERTEX_KINDS = { 'rounded', 'beveled', 'cornered' }

--- The options a nil `opts` reads as: one shared table, so a caller passing none
--- still hits the cache rather than handing it a fresh table every call.
local NO_OPTS = {}

--- The outward normal and the length of each edge of a closed vertex polygon.
---
--- Stamped ONTO the vertex list rather than returned beside it, because every
--- step below wants the normal of "edge i" keyed the same way the vertices are:
--- edge i runs from vertex i to vertex i+1, and its normal is the RIGHT of that
--- travel, which is outward for a counter-clockwise polygon.
--- @param cs table   { { x, y }, ... } counter-clockwise
--- @return boolean   false if any edge has no length, so no normal
local function stampNormals(cs)
    local n = #cs
    for i = 1, n do
        local a, b = cs[i], cs[(i % n) + 1]
        local dx, dy = b.x - a.x, b.y - a.y
        local len = sqrt(dx * dx + dy * dy)
        if len <= 0.0 then return false end
        a.ex, a.ey, a.elen = dx / len, dy / len, len
        a.nx, a.ny = dy / len, -dx / len
    end
    return true
end

--- One corner: a centre, a radius, and the normals it turns the boundary through.
---
--- The cosines and sines of both ends are taken HERE, once, and carried: every
--- query below reads them, and a placed or morphed corner inherits them rather
--- than asking math.cos again. `h1` is the support value on the run AFTER this
--- corner, which is the one number the signed distance reads per run.
local function corner(x, y, rho, a0, a1, c0, s0, c1, s1)
    c0, s0 = c0 or cos(a0), s0 or sin(a0)
    c1, s1 = c1 or cos(a1), s1 or sin(a1)
    return { x = x, y = y, rho = rho, a0 = a0, a1 = a1,
             c0 = c0, s0 = s0, c1 = c1, s1 = s1,
             h1 = x * c1 + y * s1 + rho }
end

--- Does the direction (dx, dy) fall inside corner k's range of normals?
---
--- Two cross products for every corner a polygon has, because every one of them
--- turns by less than half a turn. The one corner that turns by more is a CIRCLE's,
--- whose range is the whole turn, and it gets the angle instead of a test that
--- would read a reflex wedge as its complement.
local function inRange(k, dx, dy)
    local turn = k.a1 - k.a0
    if turn >= pi then
        return ((atan(dy, dx) - k.a0) % TAU) <= turn
    end
    return (k.c0 * dy - k.s0 * dx) >= 0.0 and (dx * k.s1 - dy * k.c1) >= 0.0
end

--- Signed distance to the convex shape a corner list describes.
---
--- THE MAXIMUM OF THE SUPPORTING CONSTRAINTS, which is the section header's
--- argument spelled out: for every run, the distance to the line it lies on; for
--- every corner, the radial distance to its centre less its radius, but ONLY where
--- the direction from that centre falls inside the corner's own range of normals
--- -- because outside it the corner is not what bounds the shape. A sharp corner
--- is the same arithmetic at a radius of zero, and inside the shape it never
--- answers, because the directions into a convex corner are never its normals.
---
--- A POINT AT A CORNER CENTRE IS ANSWERED BY THE RUNS, not by the arc: both runs
--- beside it are tangent to it and both report exactly `-rho` there.
---
--- Negative inside, positive outside, exact everywhere. Checked against a dense
--- walk of the boundary in tools/test_shared.lua rather than against itself.
local function hullDistance(h, px, py)
    local ks = h.ks
    local best = -huge
    for i = 1, #ks do
        local k = ks[i]
        local d = px * k.c1 + py * k.s1 - k.h1
        if d > best then best = d end
        local dx, dy = px - k.x, py - k.y
        if inRange(k, dx, dy) then
            local len = sqrt(dx * dx + dy * dy)
            if len > 0.0 then
                d = len - k.rho
                if d > best then best = d end
            end
        end
    end
    return best
end

--- The furthest any point of a corner list reaches from (ox, oy). EXACT.
---
--- A corner reaches furthest along the direction to its centre when that direction
--- is one of its normals, and otherwise at whichever end of it is further out --
--- distance along an arc from a fixed point rises and then falls. The runs reach
--- no further than the corners at their ends.
local function reachOf(ks, ox, oy)
    local far = 0.0
    for i = 1, #ks do
        local k = ks[i]
        local dx, dy = k.x - ox, k.y - oy
        local e
        if k.rho > 0.0 and not inRange(k, dx, dy) then
            local x0, y0 = dx + k.rho * k.c0, dy + k.rho * k.s0
            local x1, y1 = dx + k.rho * k.c1, dy + k.rho * k.s1
            e = max(sqrt(x0 * x0 + y0 * y0), sqrt(x1 * x1 + y1 * y1))
        else
            e = sqrt(dx * dx + dy * dy) + k.rho
        end
        if e > far then far = e end
    end
    return far
end

--- The area a corner list encloses, by the shoelace -- arcs included. EXACT.
---
--- Half the loop integral of (x dy - y dx), which for a run is the familiar cross
--- product of its ends and for an arc of radius rho about (cx, cy) from a0 to a1 is
--- rho * (cx * (sin a1 - sin a0) - cy * (cos a1 - cos a0)) + rho^2 * (a1 - a0).
local function areaOf(ks)
    local m, twice = #ks, 0.0
    for i = 1, m do
        local k, q = ks[i], ks[(i % m) + 1]
        if k.rho > 0.0 then
            twice = twice + k.rho * (k.x * (k.s1 - k.s0) - k.y * (k.c1 - k.c0))
                + k.rho * k.rho * (k.a1 - k.a0)
        end
        local ex, ey = k.x + k.rho * k.c1, k.y + k.rho * k.s1
        local sx, sy = q.x + q.rho * q.c0, q.y + q.rho * q.s0
        twice = twice + (ex * sy - sx * ey)
    end
    return 0.5 * twice
end

--- A corner list as a boundary: an arc for every corner with a radius, and a run
--- from each corner's last normal to the next corner's first.
---
--- Walked counter-clockwise, so every run's right of travel is its outward normal
--- and every arc is swept positively about its own centre -- which is what lets
--- pointAtArc stay ignorant of the shape it is walking. The chain closes by
--- construction: a run starts where the corner before it ends and ends where the
--- corner after it begins, both computed from the same stored cosines the arcs are.
---
--- A RUN SHORTER THAN A NANOMETRE IS NOT A RUN. It is where two arcs meet tangent
--- to each other -- a circle's own seam, or a morph whose two shapes both turn at
--- that normal -- and left in it would be a piece with a normal read off a rounding
--- error.
---
--- THE ARCS ARE EXACT AT ANY RADIUS, not floored at MIN_RADIUS. A corner arc
--- floored up to a metre would no longer meet the runs it was built for, and the
--- erosion hands this corners of every radius down to zero. MIN_RADIUS still floors
--- every circle this file builds on its own; see blob() for the small-zone case.
--- @param ks table     placed corners, counter-clockwise
--- @param meta table
local function hullOf(ks, meta)
    local m = #ks
    local pieces = {}
    local function push(pc) if pc then pieces[#pieces + 1] = pc end end
    for i = 1, m do
        local k, q = ks[i], ks[(i % m) + 1]
        if k.rho > 0.0 then
            push(arc(k.x, k.y, k.rho, k.a0, k.a1 - k.a0, true))
        end
        local ex, ey = k.x + k.rho * k.c1, k.y + k.rho * k.s1
        local sx, sy = q.x + q.rho * q.c0, q.y + q.rho * q.s0
        local dx, dy = sx - ex, sy - ey
        if dx * dx + dy * dy > EPS * EPS then push(seg(ex, ey, sx, sy)) end
    end
    meta.hull = { ks = ks }
    return seal(pieces, 'blob', meta)
end

--- A unit's corners placed at (cx, cy) and scaled to r. Fresh tables every call,
--- because the shape being built is live and the unit is shared by every caller.
local function placed(unit, cx, cy, r)
    local ks = {}
    for i = 1, #unit.ks do
        local u = unit.ks[i]
        ks[i] = corner(cx + u.x * r, cy + u.y * r, u.rho * r, u.a0, u.a1,
            u.c0, u.s0, u.c1, u.s1)
    end
    return ks
end

--- A placed corner list eroded by `metres`: the corner list of every point at least
--- that deep inside it. nil when that is not a corner list this can build -- see
--- inset(), which falls back to the inscribed circle.
---
--- ═══ THE SUPPORT FUNCTION LOSES `metres` EVERYWHERE, AND EACH CORNER SAYS WHAT
---     THAT DOES TO IT ═══
---
---   A CORNER AT LEAST THAT ROUND keeps its centre and loses `metres` of radius:
---   every normal it carries moves in by exactly that. The runs either side of it
---   move with it and keep their length.
---
---   A SHARPER CORNER -- EVERY SHARP ONE -- BECOMES SHARP where its two offset runs
---   meet: in along its bisector by (metres - rho) / cos(turn / 2). The normals
---   between its two runs add nothing once the corner is sharp -- a normal between
---   two is a positive blend of them, so its line is implied by theirs.
---
---   A RUN THE EROSION TURNS INSIDE OUT -- its two ends now the wrong way round
---   along it -- is a line the two lines beside it make redundant, when both its
---   ends are sharp: they meet on the inside of it. So the run is dropped and its
---   two corners become one, where the lines either side of the pair meet. That is
---   repeated until no run is inside out, which is what a polygon offset is, and
---   every step drops a line that was genuinely redundant, so the answer is the
---   intersection of every offset line there is. A run inside out beside an ARC is
---   an arc cut by a line, and that is the one case handed back as nil.
---
--- FRESH CORNER TABLES, because the shape being eroded is still live -- the wall
--- insets the zone the HUD is measuring against on the same frame.
--- @param ks table      placed corners
--- @param metres number
--- @return table|nil ks
local function erode(ks, metres)
    local out = {}
    for i = 1, #ks do
        local k = ks[i]
        local rho = k.rho - metres
        if rho >= 0.0 then
            out[i] = corner(k.x, k.y, rho, k.a0, k.a1, k.c0, k.s0, k.c1, k.s1)
        else
            local half = 0.5 * (k.a1 - k.a0)
            -- A CORNER TURNING HALF A TURN OR MORE has no point where its runs meet:
            -- the one such corner is a circle's, and a circle eroded past its own
            -- radius is nothing at all.
            if half >= 0.5 * pi then return nil end
            local d = rho / cos(half)
            local mid = k.a0 + half
            out[i] = corner(k.x + cos(mid) * d, k.y + sin(mid) * d, 0.0,
                k.a0, k.a1, k.c0, k.s0, k.c1, k.s1)
        end
    end

    -- THE RUNS, until none is inside out. Bounded by the corner count: every pass
    -- that changes anything removes a corner.
    --
    -- NO FLOOR ON HOW FEW CORNERS ARE LEFT, because a circle is one and it is a
    -- shape. What a floor was standing in for -- sharp corners merged down to a
    -- pair that cannot close -- is the turn test below: two corners that turn a
    -- whole turn between them need one of at least half a turn, which it refuses.
    for _ = 1, #ks do
        local n = #out
        if n < 1 then return nil end
        local fixed = true
        for i = 1, n do
            local k, q = out[i], out[(i % n) + 1]
            local ex, ey = k.x + k.rho * k.c1, k.y + k.rho * k.s1
            local sx, sy = q.x + q.rho * q.c0, q.y + q.rho * q.s0
            -- Signed length along the run's own direction, which is its normal
            -- turned a quarter left: (-sin, cos).
            if (sx - ex) * -k.s1 + (sy - ey) * k.c1 < -EPS then
                if k.rho > 0.0 or q.rho > 0.0 then return nil end
                -- q's normals continue k's; across the wrap they are one turn on.
                local a1 = q.a1 + ((i == n) and TAU or 0.0)
                if a1 - k.a0 >= pi - BLOB_MIN_TURN then return nil end
                -- The line before k and the line after q, each through its own sharp
                -- corner, and where they meet.
                local h0 = k.x * k.c0 + k.y * k.s0
                local h1 = q.x * q.c1 + q.y * q.s1
                local det = k.c0 * q.s1 - k.s0 * q.c1
                local x = (h0 * q.s1 - h1 * k.s0) / det
                local y = (k.c0 * h1 - q.c1 * h0) / det
                local merged = corner(x, y, 0.0, k.a0, a1, k.c0, k.s0, q.c1, q.s1)
                if i == n then
                    out[n] = merged
                    table.remove(out, 1)
                else
                    out[i] = merged
                    table.remove(out, i + 1)
                end
                fixed = false
                break
            end
        end
        if fixed then return out end
    end
    return nil
end

--- Metres the chords of an arc may sit inside it when erode() is handed a polygon
--- instead of the arc. A centimetre is invisible on a wall drawn in quads two metres
--- of sag apart, and it is the whole of the error the one inexact erosion has.
local CHORD_SAG = 0.01

--- A corner list with every arc replaced by chords of it, at most CHORD_SAG inside
--- it: a pure polygon, every corner sharp, and a SUBSET of the shape it was cut
--- from, because every chord's ends are on the arc.
---
--- WHAT IT IS FOR: the one erosion erode() cannot build exactly is a run turned
--- inside out beside an arc, and a polygon has no arcs -- so its erosion is exact,
--- and it is within a centimetre inside the true one. It used to fall back to the
--- inscribed CIRCLE there, which is inside too but is a different shape: measured, a
--- zone morphing through the last two phases hit that on about one frame in two
--- hundred, and the wall would have jumped to a circle and back for it.
local function chorded(ks, sag)
    local out = {}
    for i = 1, #ks do
        local k = ks[i]
        local turn = k.a1 - k.a0
        if k.rho <= 0.0 then
            out[#out + 1] = k
        else
            local step = 2.0 * math.acos(max(-1.0, 1.0 - sag / k.rho))
            local m = max(1, math.ceil(turn / step))
            -- A VERTEX ON THE ARC AT EACH OF m+1 EVEN STEPS, each turning from the
            -- chord before it to the chord after -- whose normals are half way
            -- between the vertices, and the arc's own ends at the first and last.
            for j = 0, m do
                local th = k.a0 + turn * j / m
                local lo = (j == 0) and k.a0 or (k.a0 + turn * (j - 0.5) / m)
                local hi = (j == m) and k.a1 or (k.a0 + turn * (j + 0.5) / m)
                out[#out + 1] = corner(k.x + k.rho * cos(th), k.y + k.rho * sin(th),
                    0.0, lo, hi)
            end
        end
    end
    return out
end

--- A convex vertex polygon, finished corner by corner, as a corner list.
---
--- nil when the polygon is not convex -- a turn outside [BLOB_MIN_TURN,
--- pi - BLOB_MIN_TURN] at any vertex.
---
--- ═══ ONE CUT PER VERTEX, AND IT IS THE SAME FOR A BEVEL AND AN ARC ═══
---
--- `take` is how far back along each edge the finish starts: `cut` of the shorter
--- half-edge beside the vertex, so no two neighbours can meet in the middle of the
--- run they share. A ROUNDED vertex is the arc tangent to both edges at exactly
--- those two points, and a BEVELED one is the straight chord between them -- the
--- same two points, so a bevel and an arc on the same vertex differ by the bulge
--- of the arc and nothing else. The chord is perpendicular to the vertex's
--- bisector, so its normal is exactly half way round the turn and the two sharp
--- corners at its ends split that turn equally.
--- @param vs table       vertices, counter-clockwise
--- @param finish table   one of VERTEX_KINDS per vertex
--- @param cut number     0..1
--- @return table|nil ks
local function finishOf(vs, finish, cut)
    local n = #vs
    if not stampNormals(vs) then return nil end
    for i = 1, n do
        local p, c = vs[((i - 2) % n) + 1], vs[i]
        local t = atan(p.ex * c.ey - p.ey * c.ex, p.ex * c.ex + p.ey * c.ey)
        if t < BLOB_MIN_TURN or t > pi - BLOB_MIN_TURN then return nil end
        c.turn = t
    end

    -- THE NORMAL ANGLES ARE ACCUMULATED, NOT TAKEN PER EDGE WITH atan, so that each
    -- corner's last angle IS the next one's first -- the same double, not two
    -- readings of one direction that differ in the last bit -- and the list climbs
    -- monotonically through one whole turn, which the morph's merge relies on.
    local ks = {}
    local last = vs[n]
    local acc = atan(last.ny, last.nx)
    for i = 1, n do
        local p, c = vs[((i - 2) % n) + 1], vs[i]
        local take = cut * 0.5 * ((p.elen < c.elen) and p.elen or c.elen)
        local a0, a1 = acc, acc + c.turn
        local how = finish[i]
        if how == 'cornered' then
            ks[#ks + 1] = corner(c.x, c.y, 0.0, a0, a1)
        elseif how == 'beveled' then
            local am = a0 + 0.5 * c.turn
            ks[#ks + 1] = corner(c.x - p.ex * take, c.y - p.ey * take, 0.0, a0, am)
            ks[#ks + 1] = corner(c.x + c.ex * take, c.y + c.ey * take, 0.0, am, a1)
        else
            -- THE ARC TANGENT TO BOTH EDGES `take` BACK FROM THE VERTEX: a radius of
            -- take * tan(theta / 2) for an interior angle theta, centred that radius
            -- over sin(theta / 2) in along the bisector -- which is the sum of the
            -- two unit vectors away from the vertex along its edges.
            local half = 0.5 * (pi - c.turn)
            local rho = take * math.tan(half)
            local bx, by = c.ex - p.ex, c.ey - p.ey
            local bl = sqrt(bx * bx + by * by)
            if bl <= 0.0 or not (rho > 0.0) then return nil end
            local d = rho / sin(half)
            ks[#ks + 1] = corner(c.x + bx / bl * d, c.y + by / bl * d, rho, a0, a1)
        end
        acc = a1
    end
    return ks
end

-- ═══ THE UNITS ARE MEMOISED, AND THE CACHE IS BOUNDED ═══
--
-- Every frame of the wall, every tick of the HUD and every tick of the server's
-- damage pass ask for the SAME two units -- the zone the wall is leaving and the
-- zone it is closing on -- so building them each time would be a generator, a
-- convexity test and up to six retries of garbage per call.
--
-- ═══ AND THE KNOBS ARE READ ONCE PER CONFIG, NOT ONCE PER CALL ═══
--
-- The cache used to be keyed on a string of every knob, formatted afresh on every
-- call -- a dozen string builds for a hit, measured at 9 us of a 48 us zone build,
-- and every zone build asks for two units now. So the knobs are read into a SPEC
-- once per options table and the units hang off it by seed and zone. Each call
-- checks that the knobs the spec was read from are still the knobs there -- a few
-- dozen comparisons and no strings -- so a config edited between two calls, in
-- place or by swapping a table in, is still never served a stale shape. A hit costs
-- about a microsecond.
--
-- FLUSHED WHOLE RATHER THAN EVICTED. A server runs matches for days and each one
-- brings a fresh seed, so an unbounded cache is a slow leak. Dropping every unit at
-- a ceiling costs one rebuild per zone per live match on the call after the flush,
-- and it cannot grow. The specs are held weakly, by the options table they read.
local specs = setmetatable({}, { __mode = 'k' })
local blobGen, blobCacheN = 0, 0
local BLOB_CACHE_MAX = 64

--- HOW MANY UNITS AND MERGES HAVE ACTUALLY BEEN BUILT since this file loaded.
---
--- A COUNT AND NOT A FLAG, and it exists for one claim: that a zone's shape is
--- built ONCE and the morph between two zones is merged ONCE, however many frames
--- and ticks ask for them. A cache that silently stopped hitting would still hand
--- back correct shapes -- identical ones, rebuilt -- so nothing a shape can be
--- asked would show it. tools/test_storm.lua runs a sweep and reads these.
BR.StormShape.builds = { units = 0, merges = 0 }

--- One attempt at a unit polygon, off `rng`. nil when the draw is not convex, or
--- reaches past `reach` once it is scaled to `area`.
---
--- Every attempt takes exactly 2N values off the stream WHETHER OR NOT IT SUCCEEDS,
--- which is what makes a retry deterministic rather than a fork: the client and
--- the server reject the same attempt at the same point and arrive at the same
--- shape. Both tests therefore run AFTER all 2N values are drawn.
--- @param slide number   radians a vertex may slide round the ring
--- @param rot number     radians the whole draw is turned by
--- @param area number    the fraction of the unit circle's area to scale to
--- @param reach number   the furthest the scaled boundary may reach from the centre
local function blobAttempt(rng, n, jitter, slide, finish, cut, rot, area, reach)
    local slot = TAU / n
    if slide > slot * BLOB_SLIDE_SLOT then slide = slot * BLOB_SLIDE_SLOT end
    local vs = {}
    for i = 1, n do
        -- THE ANGLE STAYS IN ITS OWN SLOT, which is what stops two vertices swapping
        -- places, and THE WHOLE RING IS TURNED by one angle drawn with the count, so
        -- that vertex one of every shape does not sit due east.
        local a = rot + (i - 1) * slot + slide * (rng:float() * 2.0 - 1.0)
        -- SYMMETRIC ABOUT 1, NOT INWARD FROM IT (#344, measured): radii drawn in
        -- [1 - 2j, 1] cost 28 to 41 percent of the circle's area before scaling.
        local rad = 1.0 + jitter * (rng:float() * 2.0 - 1.0)
        vs[i] = { x = cos(a) * rad, y = sin(a) * rad }
    end

    local ks = finishOf(vs, finish, cut)
    if not ks then return nil end

    -- ═══ SCALED TO `area` OF THE CIRCLE, EXACTLY ═══
    --
    -- Scaling every centre and every radius by one factor scales the area by its
    -- square and leaves every normal where it was, so the shape stays the corner
    -- list it was -- nothing the section header claims exact stops being so.
    local k = sqrt(area * pi / areaOf(ks))
    for i = 1, #ks do
        local c = ks[i]
        ks[i] = corner(c.x * k, c.y * k, c.rho * k, c.a0, c.a1, c.c0, c.s0, c.c1, c.s1)
    end

    local extent = reachOf(ks, 0.0, 0.0)
    if extent > reach then return nil end
    return {
        kind = 'polygon', n = n, ks = ks, finish = finish, jitter = jitter,
        -- WHAT THE SHAPE MEASURES, normalised, recorded here because every consumer
        -- that wants to compare the shape with the circle it replaced would
        -- otherwise re-derive it: how far the boundary reaches, how near it comes,
        -- and the area it was scaled to -- read back off the corners rather than
        -- copied from the knob, so a scaling that went wrong would show here.
        extent = extent,
        inradius = -hullDistance({ ks = ks }, 0.0, 0.0),
        area = areaOf(ks) / pi,
    }
end

--- The knobs of one options table, read: the counts on offer and their weights,
--- the finishes and theirs, and the scalars -- and the RAW values they were read
--- from, which is what specStill compares. nil `counts` is the off switch.
local function readSpec(opts)
    local sp = { units = {}, gen = blobGen, w = {}, v = {},
                 rawCorners = opts.corners, rawVertex = opts.vertex,
                 rawCircle = opts.circle, rawJitter = opts.jitter,
                 rawSlide = opts.slideDeg, rawCut = opts.cut,
                 rawArea = opts.area, rawReach = opts.reach }

    -- THE COUNTS ON OFFER, ascending, and their weights. Read in a fixed order
    -- rather than with pairs(), whose order is not defined and would hand the
    -- client and the server the same roll against differently ordered buckets.
    local want = opts.corners or 9
    local counts, weights, total = {}, {}, 0.0
    if type(want) == 'table' then
        for c = 3, BLOB_MAX_CORNERS do
            local w = tonumber(want[c]) or 0.0
            sp.w[c] = w
            if w > 0.0 then
                counts[#counts + 1], weights[#weights + 1] = c, w
                total = total + w
            end
        end
    else
        local c = math.floor(tonumber(want) or 0)
        if c >= 3 then counts[1], weights[1], total = c, 1.0, 1.0 end
    end
    if total > 0.0 then sp.counts, sp.weights, sp.total = counts, weights, total end

    -- THE THREE FINISHES AND THEIR WEIGHTS, equal unless the config says otherwise.
    -- A kind left out of the table, or weighted at zero, is never drawn; a table
    -- with no weight at all is read as the owner's even three-way split rather than
    -- as "no finish", because a vertex has to be one of the three.
    local vw = opts.vertex or {}
    local kinds, kw, ktotal = {}, {}, 0.0
    for _, name in ipairs(VERTEX_KINDS) do
        sp.v[name] = vw[name]
        local w = tonumber(vw[name])
        if w == nil then w = (next(vw) == nil) and 1.0 or 0.0 end
        if w > 0.0 then
            kinds[#kinds + 1], kw[#kw + 1] = name, w
            ktotal = ktotal + w
        end
    end
    if ktotal <= 0.0 then kinds, kw, ktotal = { 'rounded' }, { 1.0 }, 1.0 end
    sp.kinds, sp.kw, sp.ktotal = kinds, kw, ktotal

    sp.chance = opts.circle or 0.0
    sp.jitter = opts.jitter or 0.13
    sp.slide  = (opts.slideDeg or 9.0) * pi / 180.0
    local cut = opts.cut or 0.5
    if cut < 0.0 then cut = 0.0 elseif cut > 1.0 then cut = 1.0 end
    sp.cut    = cut
    sp.area   = opts.area or 0.90
    sp.reach  = opts.reach or 1.15
    return sp
end

--- Are these still the knobs `sp` was read from? Every field the reading looked
--- at, compared as it was found -- the weight tables entry by entry, so an edit in
--- place is caught as surely as a table swapped for another.
local function specStill(sp, opts)
    if opts.corners ~= sp.rawCorners or opts.vertex ~= sp.rawVertex
        or opts.circle ~= sp.rawCircle or opts.jitter ~= sp.rawJitter
        or opts.slideDeg ~= sp.rawSlide or opts.cut ~= sp.rawCut
        or opts.area ~= sp.rawArea or opts.reach ~= sp.rawReach then
        return false
    end
    local want = opts.corners
    if type(want) == 'table' then
        for c = 3, BLOB_MAX_CORNERS do
            if (tonumber(want[c]) or 0.0) ~= sp.w[c] then return false end
        end
    end
    local vw = opts.vertex
    if type(vw) == 'table' then
        for _, name in ipairs(VERTEX_KINDS) do
            if vw[name] ~= sp.v[name] then return false end
        end
    end
    return true
end

--- The plain circle a zone is one draw in ten: the corner list of one corner whose
--- range is the whole turn, at the radius that holds `area` like every other shape.
---
--- ═══ A CORNER LIST AND NOT BR.StormShape.circle, AND THE MAP IS WHY ═══
---
--- blob() builds it like any other unit, so it carries `blob` -- its centre and its
--- scale -- and #350's map fill can move and scale it in place exactly as it does a
--- polygon. A 'circle' kind would carry no such record, and a moving circle zone
--- would be rebuilt on the map every time it moved: the work #350 removed.
---
--- AT `area` OF THE CIRCLE, NOT AT r. Every other shape plays at that size, and a
--- circle phase that played a tenth bigger than its neighbours would be the size
--- defect the area rule exists to remove, spelled the other way round.
local function circleUnit(area)
    local rho = sqrt(area)
    local ks = { corner(0.0, 0.0, rho, 0.0, TAU) }
    return { kind = 'circle', n = 0, ks = ks, finish = {}, jitter = 0.0,
             extent = rho, inradius = rho, area = areaOf(ks) / pi, tries = 1 }
end

--- THE UNIT SHAPE of one zone of one match: radius 1 at the origin, to be scaled by
--- whatever radius the solver reports.
---
--- ═══ KEYED ON THE ZONE, NOT ON THE PHASE THAT IS DRAWING IT ═══
---
--- Zone k is the circle phase k closes on -- zone 0 is the opening circle -- and it
--- is on screen for two phases: as phase k's TARGET, and then as phase k+1's
--- CURRENT circle until that phase's sweep carries it away. It keeps this one
--- shape for the whole of that. Asked by the phase that happened to be drawing it,
--- the answer changed under a wall standing still, which is the snap the owner
--- reported: "after the storm is finished moving for that phase, the border snaps
--- to a different location." BR.StormZone is where the two zones of a record are
--- named.
---
--- ═══ DETERMINISM IS A CORRECTNESS REQUIREMENT HERE, NOT A NICETY ═══
---
--- The client draws the wall and the server does the damage. They do not exchange
--- the shape, so they derive it, from the seed the record carries and the zone
--- index. If they disagree by a metre the wall is a lie by a metre.
--- tools/test_storm.lua walks both paths and compares.
---
--- INTEGER, AND THAT IS #346. BR.Rng runs its argument through math.tointeger and
--- falls back to ZERO when that fails, so a fractional seed is silently seed 0 --
--- every match the same shape, with nothing to notice. Floored here, once.
---
--- ═══ nil IS THE OFF SWITCH AND IS SPELLED IN THE CONFIG, NOT HERE ═══
---
--- Fewer than three corners is not a polygon, and it is the one way back to the
--- pre-#344 disc union: BR.StormZone hands a nil unit to union2. A table with no
--- positive weight at three or more is the same switch in the table spelling.
--- `circle` is not the off switch -- a chance of 1 draws every zone as a circle
--- corner list, which the map can still place.
---
--- @param seed number|nil     the match's storm seed (server/storm.lua's seedRng)
--- @param zone number|nil     0 is the opening circle, k the circle phase k closes on
--- @param opts table|nil      { circle, corners, vertex, jitter, slideDeg, cut,
---                              area, reach }
--- @return table|nil unit     { kind, n, ks, finish, extent, inradius, area, tries }
function BR.StormShape.blobUnit(seed, zone, opts)
    opts = opts or NO_OPTS
    local sp = specs[opts]
    if not sp or not specStill(sp, opts) then
        sp = readSpec(opts)
        specs[opts] = sp
    end
    if not sp.counts then return nil end
    if sp.gen ~= blobGen then sp.units, sp.gen = {}, blobGen end

    local s = math.tointeger(math.floor(seed or 0)) or 0
    local z = math.tointeger(math.floor(zone or 0)) or 0
    local bySeed = sp.units[s]
    local hit = bySeed and bySeed[z]
    if hit then return hit end

    local counts, weights, total = sp.counts, sp.weights, sp.total
    local kinds, kw, ktotal = sp.kinds, sp.kw, sp.ktotal
    local chance, jitter, slide = sp.chance, sp.jitter, sp.slide
    local cut, area, reach = sp.cut, sp.area, sp.reach

    local rng = BR.Rng(s * 1000003 + z * 7919 + 17)

    -- ═══ THE FIRST VALUES ARE ALWAYS THE SAME ONES, WHATEVER THEY DECIDE ═══
    --
    -- The circle roll, the count, the turn and one finish per vertex, in that order
    -- and ALL OF THEM ALWAYS TAKEN -- the count even when there is one to choose
    -- from, the finishes even when the zone is a circle. So everything after sits
    -- at the same place in the stream however the config is spelled: `9` and
    -- `{ [9] = 1 }` are the same shape, and a zone that is a polygon at a circle
    -- chance of 0.1 is the SAME polygon at 0.2. Retuning a weight changes which
    -- shape a zone draws, never what a given shape looks like there.
    local isCircle = rng:float() < chance
    local roll = rng:float() * total
    local n = counts[#counts]
    for i = 1, #counts do
        roll = roll - weights[i]
        if roll < 0.0 then n = counts[i] break end
    end
    local rot = rng:float() * TAU
    local finish = {}
    for i = 1, n do
        local v = rng:float() * ktotal
        finish[i] = kinds[#kinds]
        for j = 1, #kinds do
            v = v - kw[j]
            if v < 0.0 then finish[i] = kinds[j] break end
        end
    end

    local unit
    if isCircle then
        unit = circleUnit(area)
    else
        local j, sl = jitter, slide
        for attempt = 1, BLOB_TRIES do
            -- THE LAST ATTEMPT HAS NO JITTER AT ALL, radial or angular, so it is a
            -- regular polygon: convex by construction. That is what makes this loop
            -- terminate on a shape rather than on a nil, and it is why nothing
            -- downstream has a "there is no shape" branch to get wrong. So it is
            -- also accepted however far it reaches -- a config asking for a reach
            -- a regular polygon cannot meet at its area gets the regular polygon,
            -- never a circle. config/storm.lua's corner range is what keeps the
            -- shipping draws off that branch.
            local last = attempt == BLOB_TRIES
            if last then j, sl = 0.0, 0.0 end
            unit = blobAttempt(rng, n, j, sl, finish, cut, rot, area,
                last and huge or reach)
            if unit then unit.tries = attempt break end
            j, sl = j * BLOB_FALLOFF, sl * BLOB_FALLOFF
        end
    end

    if blobCacheN >= BLOB_CACHE_MAX then
        blobGen, blobCacheN = blobGen + 1, 0
        sp.units, sp.gen = {}, blobGen
    end
    bySeed = sp.units[s]
    if not bySeed then
        bySeed = {}
        sp.units[s] = bySeed
    end
    bySeed[z] = unit
    blobCacheN = blobCacheN + 1
    BR.StormShape.builds.units = BR.StormShape.builds.units + 1
    return unit
end

-- ═══ THE MORPH: ONE ZONE'S SHAPE BECOMING THE NEXT ONE'S, ACROSS THE SWEEP ═══
--
-- A zone keeps its shape for its whole life, so the wall at the end of a sweep is
-- the target's shape and the wall at the start of it is the previous zone's -- and
-- in between it has to become one from the other, or keeping shapes per zone
-- would only move the snap from the end of the sweep to the start of it.
--
-- ═══ IT IS THE MINKOWSKI COMBINATION, (1 - t) A + t B ═══
--
-- The set of (1 - t) a + t b for a in A and b in B, of two unit shapes, placed at the
-- solved circle -- so the sweep moves and scales it and the morph reshapes it. And
-- with the fraction BR.StormMorph chooses, those two are ONE interpolation: the wall
-- is (1 - s) Z0 + s Z1 of the zone it left and the zone it arrives at, each as
-- placed, s the sweep's own fraction -- affine in s, which is what airdrop siting's
-- window argument needs (storm_solve.lua has why). Four things follow, all exact:
--
--   IT IS CONVEX. A Minkowski combination of convex sets is convex, at every t.
--
--   IT IS A CORNER LIST. Its support function is (1 - t) h_A + t h_B, and on any
--   range of normals where A is on one corner and B on one corner that is
--   <(1 - t) c_A + t c_B, u> + (1 - t) rho_A + t rho_B: a corner, with the centre
--   and the radius interpolated. So the morph is the two lists' breakpoints merged
--   and every corner lerped -- arcs and runs, the piece model this file walks, with
--   an exact signed distance and an exact erosion like any other shape. Nothing is
--   sampled, and nothing is a level set.
--
--   IT NEVER PLAYS SMALLER AND NEVER REACHES FURTHER. By Brunn-Minkowski its area
--   is at least the area both ends were scaled to, and its support function is a
--   blend of two that stay inside `reach`, so the farthest it reaches is at most
--   the farther of the two.
--
--   IT STARTS AND ENDS ON THE ZONES THEMSELVES. At t = 0 it is A and at t = 1 it
--   is B -- and morphUnit hands back the unit ITSELF at both ends rather than a
--   lerp that equals it, so the wall at the end of one sweep and the wall at the
--   start of the next hold are the same table placed at the same circle, to the
--   bit.
--
-- WHY NOT THE SIGNED-DISTANCE BLEND, whose zero set (1 - t) d_A + t d_B <= 0 is also
-- convex at every t and also equals each shape at its end. Two reasons: its boundary
-- is a level set, so the wall would have to find it by root-finding along rays every
-- frame, and its magnitude is only a lower bound on the distance -- a blend of two
-- unit gradients is shorter than one -- so the damage test would read players as
-- nearer the edge than they are. MEASURED on 120 pairs of shipping zones at r 1000: a
-- point 39.5 m outside the blend's boundary read as 32.7, and up to 18 percent short
-- 10 to 40 m out, which is a player twelve metres outside read as inside a ten-metre
-- cushion. This morph's signed distance is the corner list's, exact: measured to
-- 4e-12 m at 98,508 points 1 to 60 m outside moving walls of every phase.
--
-- AND A BREAKOUT DOES NOT TOUCH IT. The two shapes are overlaid at one circle, not
-- blended between two, so whether the old zone and the new one overlap on the map
-- is the sweep's business and never the morph's.

--- Merges are cached per PAIR of units, weakly, so a flushed unit takes its merges
--- with it and a merge is built once per phase rather than once per frame.
local mergeCache = setmetatable({}, { __mode = 'k' })

--- Which corner of `unit` carries normal angle `a`. Its ranges tile one whole turn.
local function cornerAt(unit, a)
    local ks = unit.ks
    for i = 1, #ks do
        local k = ks[i]
        if ((a - k.a0) % TAU) < (k.a1 - k.a0) then return i end
    end
    return #ks
end

--- The merged ranges of two units: every normal angle at which either turns from
--- one corner to the next, sorted, each range between two of them naming the
--- corner of A and the corner of B it lies on. Built once per pair.
local function mergeOf(a, b)
    local byA = mergeCache[a]
    if not byA then
        byA = setmetatable({}, { __mode = 'k' })
        mergeCache[a] = byA
    end
    local hit = byA[b]
    if hit then return hit end

    local bps = {}
    for i = 1, #a.ks do bps[#bps + 1] = a.ks[i].a1 % TAU end
    for i = 1, #b.ks do bps[#bps + 1] = b.ks[i].a1 % TAU end
    table.sort(bps)
    local cuts = {}
    for i = 1, #bps do
        if #cuts == 0 or bps[i] - cuts[#cuts] > ANGLE_EPS then cuts[#cuts + 1] = bps[i] end
    end
    if #cuts > 1 and (cuts[1] + TAU) - cuts[#cuts] <= ANGLE_EPS then
        cuts[#cuts] = nil
    end

    local out = {}
    for j = 1, #cuts do
        local lo = cuts[j]
        local hi = (j < #cuts) and cuts[j + 1] or (cuts[1] + TAU)
        local mid = 0.5 * (lo + hi)
        out[j] = { ia = cornerAt(a, mid), ib = cornerAt(b, mid), a0 = lo, a1 = hi,
                   c0 = cos(lo), s0 = sin(lo), c1 = cos(hi), s1 = sin(hi) }
    end
    byA[b] = out
    BR.StormShape.builds.merges = BR.StormShape.builds.merges + 1
    return out
end

--- The unit `t` of the way from A's shape to B's: (1 - t) A + t B. See above.
---
--- A OR B ITSELF AT THE ENDS, and when the two are the same unit -- the table, not
--- a copy -- so a hold and a finished sweep never pay for a merge and never differ
--- by a rounding from the zone they are.
---
--- ONE CORNER TABLE PER MERGED RANGE PER CALL, and nothing else: the merge is cached
--- per pair, so a frame of the sweep costs the lerp and the two measurements.
--- @param a table|nil   the unit the sweep leaves
--- @param b table|nil   the unit it arrives at
--- @param t number      0..1
--- @return table|nil unit
function BR.StormShape.morphUnit(a, b, t)
    if not a or not b then return b or a end
    t = t or 0.0
    if a == b or t >= 1.0 then return b end
    if t <= 0.0 then return a end
    local mg = mergeOf(a, b)
    local s = 1.0 - t
    local ak, bk = a.ks, b.ks
    local ks = {}
    for j = 1, #mg do
        local g = mg[j]
        local ka, kb = ak[g.ia], bk[g.ib]
        ks[j] = corner(s * ka.x + t * kb.x, s * ka.y + t * kb.y,
            s * ka.rho + t * kb.rho, g.a0, g.a1, g.c0, g.s0, g.c1, g.s1)
    end
    return {
        kind = 'morph', n = #ks, ks = ks, from = a, to = b, t = t,
        extent = reachOf(ks, 0.0, 0.0),
        inradius = -hullDistance({ ks = ks }, 0.0, 0.0),
    }
end

--- A unit placed at (cx, cy) and scaled to radius `r`.
---
--- ═══ SCALED, WHICH IS WHY THE SOLVER DID NOT HAVE TO CHANGE ═══
---
--- BR.StormAt reports a centre and a radius and knows nothing about this; the
--- shape is that radius times a unit, so a shrinking phase is a shrinking scale
--- factor and the whole hold/sweep timing machinery is untouched. `r` stays the
--- number every placement rule is written in, and the shape's own reach is never
--- past `reach` of it (measured, and bounded by the retry).
---
--- ═══ BELOW A METRE AND A HALF IT IS A CIRCLE ═══
---
--- When the centre is less than MIN_RADIUS deep the whole shape is smaller than a
--- metre across its narrowest, which is the last second of the final sweep, where
--- it is a point at the storm's own resolution -- and a point is not a circle, the
--- same reading union2's header gives phase 8. The circle is floored at MIN_RADIUS
--- like every other, so the collapsed zone is the walkable metre it always was.
--- @param cx number
--- @param cy number
--- @param r number
--- @param unit table   from blobUnit or morphUnit
--- @return table shape
function BR.StormShape.blob(cx, cy, r, unit)
    cx, cy, r = cx + 0.0, cy + 0.0, radius(r)
    if not unit or (r * unit.inradius) < MIN_RADIUS then
        return BR.StormShape.circle(cx, cy, r)
    end
    return hullOf(placed(unit, cx, cy, r), {
        blob = { cx = cx, cy = cy, r = r, unit = unit },
        -- ═══ ONE RADIUS BLIP, AND THE MAP HAS NO BETTER ANSWER THAN THAT ═══
        --
        -- This is the radius-blip FALLBACK's descriptor, for a client whose overlay
        -- never became ready; the fill itself walks the real boundary (polyline).
        -- The ring is the CIRCLE THE SHAPE REPLACED, at the radius the solver
        -- reports -- exact where the shape reaches r, over-reporting where it dents
        -- in and under-reporting where a corner pokes out.
        prims = { { kind = 'radius', cx = cx, cy = cy, r = r } },
    })
end

--- The SAFE ZONE as one shape: the current zone and the one it is closing toward,
--- or the one that contains the other.
---
--- ═══ TWO UNITS NOW, BECAUSE THEY ARE TWO ZONES ═══
---
--- `unit` is the CURRENT circle's shape -- the zone the sweep is leaving, morphed as
--- far toward the target as the sweep has got -- and `target` is the zone it closes
--- on. They were one unit until the snap was traced to exactly that. `target`
--- defaults to `unit` for a caller that has one shape to give both.
---
--- ═══ THE SAME FOUR CASES union2 HAS, DECIDED THE SAME WAY ═══
---
--- The zone is the current shape UNION the target, so that a player who reaches
--- the new destination early is safe there (#328):
---
---   NESTED (every phase that did not break out) -- the zone is the CONTAINING
---   shape, one closed loop, and its signed distance is exact everywhere. What it
---   gives up is that the target's corners can poke out of the current shape's
---   dents, so those slivers are not pre-safe. That is grace declined rather than a
---   loss against a disc strictly inside a disc, which adds nothing either; the
---   wall is drawn on the boundary that damages, so nothing is told it is safe
---   where it is not. And it closes itself: the current shape BECOMES the target's
---   across the sweep and lands on it exactly.
---
---   DISJOINT -- two closed loops, kilometres apart, exact.
---
---   OVERLAPPING -- stitched into one loop at the crossings (#356, blobUnion).
---
--- THE CONTAINMENT TEST IS IN CIRCLE SPACE, deliberately: the solver's own nesting
--- rule (`d + r2 <= r1`), so "did this phase break out" has one answer in this
--- file and in storm_solve.lua, and the number of loops on screen never depends on
--- a jitter draw.
---
--- A DISC WITH NO RADIUS IS STILL NOT A DISC. Phase 8 closes on radius 0 and the
--- test is on what the caller asked for, exactly as union2's is.
---
--- @param unit table|nil     nil is the off switch: union2, and the pre-#344 game
--- @param target table|nil   defaults to `unit`
--- @return table shape
function BR.StormShape.zone(x1, y1, r1, x2, y2, r2, unit, target)
    if not unit then
        return BR.StormShape.union2(x1, y1, r1, x2, y2, r2)
    end
    target = target or unit
    local has1, has2 = (r1 or 0.0) > 0.0, (r2 or 0.0) > 0.0
    if has1 and not has2 then return BR.StormShape.blob(x1, y1, r1, unit) end
    if has2 and not has1 then return BR.StormShape.blob(x2, y2, r2, target) end
    if not has1 then return BR.StormShape.circle(x1, y1, 0.0) end

    local dx, dy = x2 - x1, y2 - y1
    local d = sqrt(dx * dx + dy * dy)
    if d + r2 <= r1 + EPS then return BR.StormShape.blob(x1, y1, r1, unit) end
    if d + r1 <= r2 + EPS then return BR.StormShape.blob(x2, y2, r2, target) end

    return BR.StormShape.blobUnion(BR.StormShape.blob(x1, y1, r1, unit),
                                   BR.StormShape.blob(x2, y2, r2, target))
end

-- ═══ STITCHING TWO OVERLAPPING BOUNDARIES INTO ONE LOOP (#356) ═══
--
--   "current/next storm circles, while overlapping, were actually drawn as 2
--    separate circles instead of one conjoined."       -- owner, 2026-09-22
--
-- blobUnion used to concatenate both boundaries whatever they were doing, which
-- is exactly right for a DISJOINT pair and a visible defect for an overlapping
-- one: the stretch of each boundary that runs inside the other is drawn, so the
-- curtain stands in the middle of the safe zone. Measured on a phase-2 overlap
-- (2600 and 1600, centres 3392 apart): union2 on circles drew 1 component and
-- 0.0% of the boundary inside the other shape, blobUnion on blobs drew 2 and
-- 14.1%. #328 removed that for circles and #344 handed it back for blobs.
--
-- ═══ AND IT IS ONE LOOP, BECAUSE BOTH SHAPES ARE CONVEX ═══
--
-- Two convex shapes that overlap have a union that is STAR-SHAPED about any point
-- of their intersection, so its boundary is one closed curve, met once by every
-- ray from that point -- and walking it counter-clockwise it alternates: a run of
-- A's boundary outside B, then a run of B's outside A, joined at a crossing. So
-- the loop is those runs in order, and no polygon clipping or even-odd
-- classification is needed.
--
-- ═══ HOW MANY CROSSINGS: TWO FOR HOMOTHETS, AND UP TO 2N FOR TWO SHAPES ═══
--
-- This used to say every overlapping pair crosses exactly twice. That is a theorem
-- for two HOMOTHETS of one convex shape -- one shape moved and scaled -- and it is
-- what #356 was built on, while the current zone and its target wore one unit
-- between them. They do not any more: each zone keeps its own shape, and two
-- different convex shapes can cross as often as they have sides -- a square and the
-- same square turned 45 degrees cross eight times. So the runs are 2k, not 2:
-- crossings() finds every one and stitch() joins them all, and at k = 1 it is the
-- loop it always was.
--
-- WHICH WAY ROUND THE JOIN GOES falls out of both boundaries being walked
-- counter-clockwise with the interior on the left: at the crossing where A
-- ENTERS B, B is LEAVING A, and at the other one it is the other way about. Two
-- unit discs 1.0 apart is the whole proof in four numbers -- A enters B at -60
-- degrees and that point is where B leaves A, at 240 -- and it is checked at
-- runtime rather than trusted, see stitch().
--
-- ═══ NOTHING HERE TOUCHES WHAT distance() ANSWERS, AND THAT IS DELIBERATE ═══
--
-- The signed distance to a union is the minimum over its parts, which holds for
-- any two shapes at all, and `parts` is handed to seal() unchanged. So this is a
-- change to the WALK and to nothing else: the damage tick, the HUD readout and
-- the way-home arrow all read the same numbers they read before it.

--- Metres of arc length within which two crossings found are ONE crossing.
---
--- A crossing that lands on the joint between two pieces is found by both of
--- them -- the end of one and the start of the next are the same point -- and
--- counted twice it would break the alternation stitch() rests on. A micrometre is
--- far below anything that reads a crossing and far above the rounding in two
--- reconstructions of one point.
local CROSS_SAME = 1e-6

--- How square to B's boundary A's has to run, as a sine, for a meeting to be a
--- CROSSING rather than a touch. Below it the two are tangent there, and a tangent
--- touch changes nothing about which side of B the boundary is on.
local CROSS_GRAZE = 1e-9

--- One piece cut down to the stretch between `t0` and `t1` metres along itself.
---
--- THE WHOLE PIECE IS HANDED BACK AS ITSELF, not copied, for the reason
--- blobUnion's header gives about re-stamping: a zone is rebuilt every frame and
--- copying 2N tables to keep a bookkeeping nothing reads alive is paying for
--- tidiness with garbage. `newComponent` is cleared on the way through, because a
--- piece that once opened a component must not open one here by inheritance.
--- @return table|nil
local function subPiece(pc, t0, t1)
    local L = t1 - t0
    if L <= 0.0 then return nil end
    if t0 <= 0.0 and L >= pc.len then
        pc.newComponent = nil
        return pc
    end
    if pc.kind == 'arc' then
        -- Radians per metre, SIGNED, so a clockwise arc stays clockwise and its
        -- `out` normal keeps pointing the way it pointed. EXACT, because the piece
        -- already has the radius it has: a corner arc under a metre re-floored here
        -- would no longer meet the run beside it.
        local perM = pc.sweep / pc.len
        return arc(pc.cx, pc.cy, pc.r, pc.a0 + perM * t0, perM * L, true)
    end
    local x0, y0 = pieceAt(pc, t0)
    local x1, y1 = pieceAt(pc, t1)
    return seg(x0, y0, x1, y1)
end

--- The pieces of `shape` from arc length `s0` forward for `len` metres.
---
--- INDEXED BY PIECE RATHER THAN WALKED BY ARC LENGTH, and the bound is what makes
--- that the right choice: stepping s forward by what each piece had left over can
--- stall on a piece whose remainder is a picometre, and a stall in a per-frame
--- build is a hung client rather than a wrong picture. One lap of the piece table
--- is the most any slice can need, so that is the loop.
--- @return table  pieces, in boundary order, ends split
local function sliceOf(shape, s0, len)
    local pcs = shape.pieces
    local n = #pcs
    local out = {}
    if n == 0 or len <= 0.0 then return out end
    local pc0, t0 = pieceAtArc(shape, s0 % shape.P)
    local i0 = 1
    for i = 1, n do if pcs[i] == pc0 then i0 = i break end end
    local left = len
    for k = 0, n do
        if left <= 0.0 then break end
        local pc = pcs[((i0 - 1 + k) % n) + 1]
        local from = (k == 0) and t0 or 0.0
        local avail = pc.len - from
        if avail > 0.0 then
            local use = (avail < left) and avail or left
            local p = subPiece(pc, from, from + use)
            if p then out[#out + 1] = p end
            left = left - use
        end
    end
    return out
end

--- The radius of the smallest circle about `shape`'s OWN centre that contains it.
---
--- The furthest any corner reaches from the shape's centre, which reachOf answers
--- exactly -- this runs before every stitch attempt and the whole reason it exists
--- is to be cheaper than the thing it decides not to do, and it is: one pass over
--- the corners against seventy-odd signed distances.
---
--- WHAT IT IS FOR: two shapes whose bounding circles do not reach each other
--- cannot possibly cross, and a disjoint pair is the common case on a breakout
--- phase. Without this rejection the scan below runs its full seventy-odd signed
--- distances to prove what one subtraction already knew -- MEASURED at 0.33 ms per
--- zone build on a disjoint phase-2 pair against 0.08 before, which is a fifth of
--- a 60 fps frame spent on two islands that were never going to touch.
local function boundRadius(shape)
    local h = shape and shape.hull
    if not h then
        local d = shape and shape.discs and shape.discs[1]
        return d and d.r or 0.0
    end
    local m = shape.blob
    return reachOf(h.ks, m.cx, m.cy)
end

--- Is `shape` inside `other`, GIVEN THAT THEIR BOUNDARIES NEVER MEET? EXACT.
---
--- Two closed boundaries that do not meet are nested one way or the other, or
--- apart, and a connected boundary that never meets `other`'s is on one side of it
--- the whole way round -- so ONE of its points says which, and one signed distance
--- answers the question. crossings() is what establishes that they do not meet;
--- blobUnion asks this only then.
---
--- THE POINT IS HALF WAY ALONG THE FIRST PIECE, read off the piece itself rather
--- than walked to by arc length, because a shape handed in here may have had its
--- pieces re-stamped by a union built from them earlier -- see blobUnion's header
--- -- and a walk would read that union's arc lengths instead of this shape's.
---
--- IT USED TO TEST EVERY CORNER'S WHOLE DISC, which is sufficient and not exact: a
--- rounded corner's disc can stand beyond the shape's own neighbouring run, so a
--- target wholly inside the current shape was read as NOT inside, and the zone was
--- drawn as two boundaries with the whole of the target's inside the safe zone.
--- MEASURED on 27,648 reachable geometries: 38% of one such wall inside the zone.
---
--- ═══ WHY THIS IS ASKED AT ALL, WHEN zone() ALREADY TESTS NESTING ═══
---
--- zone()'s test is in CIRCLE space, deliberately -- storm_solve.lua's own nesting
--- rule, so that "did this phase break out" has one answer everywhere. A shape
--- reaches up to 1.15 of its circle and dents in by a third of it, so a pair that
--- is not nested as circles can be nested as shapes, and the two-component drawing
--- of it puts the swallowed shape's boundary inside the safe zone in its ENTIRETY.
---
--- AND COLLAPSING IT CHANGES NOTHING distance() ANSWERS. For A inside B the
--- signed distance to B is at most the signed distance to A everywhere, so the
--- minimum over the parts IS B's -- inside, outside and on either boundary. The
--- same argument makes inset() agree, because erosion preserves inclusion.
local function insideWhole(shape, other)
    local pc = shape and shape.pieces and shape.pieces[1]
    if not pc then return false end
    local x, y = pieceAt(pc, pc.len * 0.5)
    return BR.StormShape.distance(other, x, y) < 0.0
end

--- A piece's bounding box: exact for a run, the whole circle for an arc. Only ever
--- used to skip pairs that cannot meet, so a box too big costs a test and nothing
--- else.
local function boxOf(pc)
    if pc.kind == 'arc' then
        return pc.cx - pc.r, pc.cx + pc.r, pc.cy - pc.r, pc.cy + pc.r
    end
    local x0, x1, y0, y1 = pc.x0, pc.x1, pc.y0, pc.y1
    if x0 > x1 then x0, x1 = x1, x0 end
    if y0 > y1 then y0, y1 = y1, y0 end
    return x0, x1, y0, y1
end

--- How far along run `pc` a line parameter is, or nil when it is off the run. A
--- parameter a micrometre past either end is that end: the joint is the point.
local function alongRun(pc, t)
    if t < -CROSS_SAME or t > pc.len + CROSS_SAME then return nil end
    if t < 0.0 then return 0.0 end
    if t > pc.len then return pc.len end
    return t
end

--- How far along arc `pc` the point (x, y) of its circle is, or nil when the point
--- is on the circle and not on the arc. A micrometre either side of an end is that
--- end, for the reason alongRun gives -- and a hair before the start is read as the
--- start rather than as nearly a whole turn on.
local function alongArc(pc, x, y)
    local span = abs(pc.sweep)
    local off = ((atan(y - pc.cy, x - pc.cx) - pc.a0) * pc.out) % TAU
    if off > span then
        local slack = CROSS_SAME / pc.r
        if TAU - off <= slack then
            off = 0.0
        elseif off - span <= slack then
            off = span
        else
            return nil
        end
    end
    return off * pc.r
end

--- Where two runs meet: 0 or 1 points, as (t along p, u along q).
local function meetRuns(p, q)
    local den = p.ux * q.uy - p.uy * q.ux
    -- PARALLEL RUNS DO NOT CROSS. Two that lie along each other touch along a
    -- stretch, and a touch is not a crossing.
    if abs(den) < CROSS_GRAZE then return 0 end
    local dx, dy = q.x0 - p.x0, q.y0 - p.y0
    local t = alongRun(p, (dx * q.uy - dy * q.ux) / den)
    local u = alongRun(q, (dx * p.uy - dy * p.ux) / den)
    if t and u then return 1, t, u end
    return 0
end

--- Where a run meets an arc: 0, 1 or 2 points, as (t along the run, u along the
--- arc). The run's line against the arc's circle, |P0 + t d - C| = r, and each root
--- that lands on both pieces.
local function meetRunArc(p, q)
    local fx, fy = p.x0 - q.cx, p.y0 - q.cy
    local b = fx * p.ux + fy * p.uy
    local disc = b * b - (fx * fx + fy * fy - q.r * q.r)
    if disc < 0.0 then return 0 end
    local root = sqrt(disc)
    local n, t1, u1 = 0, nil, nil
    for k = -1, 1, 2 do
        local t = alongRun(p, -b + k * root)
        if t then
            local u = alongArc(q, p.x0 + p.ux * t, p.y0 + p.uy * t)
            if u then
                if n == 0 then n, t1, u1 = 1, t, u else return 2, t1, u1, t, u end
            end
        end
        if root == 0.0 then break end
    end
    return n, t1, u1
end

--- Where two arcs meet: 0, 1 or 2 points. Their circles' two crossings, each kept
--- if it lands on both arcs.
local function meetArcs(p, q)
    local dx, dy = q.cx - p.cx, q.cy - p.cy
    local d = sqrt(dx * dx + dy * dy)
    if d <= 0.0 or d > p.r + q.r or d < abs(p.r - q.r) then return 0 end
    local a = (d * d + p.r * p.r - q.r * q.r) / (2.0 * d)
    local h2 = p.r * p.r - a * a
    local h = (h2 > 0.0) and sqrt(h2) or 0.0
    local ux, uy = dx / d, dy / d
    local mx, my = p.cx + a * ux, p.cy + a * uy
    local n, t1, u1 = 0, nil, nil
    for k = -1, 1, 2 do
        local x, y = mx - k * h * uy, my + k * h * ux
        local t = alongArc(p, x, y)
        local u = t and alongArc(q, x, y)
        if u then
            if n == 0 then n, t1, u1 = 1, t, u else return 2, t1, u1, t, u end
        end
        if h == 0.0 then break end
    end
    return n, t1, u1
end

--- Where pieces p and q meet: a count and up to two (t along p, u along q) pairs.
local function meet(p, q)
    if p.kind == 'seg' then
        if q.kind == 'seg' then return meetRuns(p, q) end
        return meetRunArc(p, q)
    end
    if q.kind == 'seg' then
        local n, u1, t1, u2, t2 = meetRunArc(q, p)
        return n, t1, u1, t2, u2
    end
    return meetArcs(p, q)
end

--- Every place `a`'s boundary crosses `b`'s, in arc order along a.
---
--- A list of `{ s, t, into }` -- the arc length along A, the arc length along B at
--- the same point, and whether A is going INTO B there -- with the entries and
--- exits ALTERNATING, which a closed boundary crossing a closed boundary always
--- does. nil when there is no crossing, an odd count, or a pattern that does not
--- alternate: disjoint, nested, tangent, or a crossing through a corner of both.
---
--- ═══ EXACT, PIECE AGAINST PIECE, AND THIS IS WHY IT STOPPED BEING A SCAN ═══
---
--- It used to sample A's boundary, ask B's signed distance at each sample, split
--- every interval a Lipschitz bound could not clear, and bisect each sign change.
--- That is exact for finding whether a stretch of A dips into B, and it cannot see
--- an interval whose ends are on OPPOSITE sides and which crosses three times rather
--- than once: it bisects one crossing and the dip back out and in again is never
--- asked about. With two homothets that could not happen -- they cross at most
--- twice -- and with two different shapes it does. MEASURED, before this: a
--- 2600/1600 pair one seed in 5,184 geometries drew a one-loop wall with 0.9% of it
--- inside the safe zone, a 142 m stretch of A outside B that the stitch never knew
--- was there.
---
--- A boundary here is runs and arcs, and two runs, a run and an arc, and two arcs
--- all meet in closed form. So every pair of pieces is intersected outright -- a box
--- test first, so a pair far apart costs four comparisons -- and every crossing is
--- found, with B's own arc length read off the same intersection rather than
--- searched for afterwards.
---
--- WHICH WAY A CROSSING GOES is A's direction of travel against B's outward normal
--- there: into B when it runs against it. A meeting where the two run along each
--- other is a touch and not a crossing, and is not counted.
---
--- THE SECOND ANSWER IS WHETHER THE TWO BOUNDARIES MET AT ALL, which is a different
--- question from whether they can be stitched: two that never meet are nested or
--- apart, and one point then says which (insideWhole). Two that met in a pattern
--- this cannot stitch are neither, and get both boundaries drawn.
--- @return table|nil  { { s = number, t = number, into = boolean }, ... }
--- @return boolean met
local function crossings(a, b)
    local Pa, Pb = a.P, b and b.P or 0.0
    if Pa <= 0.0 or Pb <= 0.0 then return nil, false end

    local bp = b.pieces
    local bx0, bx1, by0, by1 = {}, {}, {}, {}
    for j = 1, #bp do bx0[j], bx1[j], by0[j], by1[j] = boxOf(bp[j]) end

    local out, met = {}, false
    local function record(p, q, t, u)
        local tx, ty
        if p.kind == 'arc' then
            local th = p.a0 + p.sweep * (t / p.len)
            tx, ty = -sin(th) * p.out, cos(th) * p.out
        else
            tx, ty = p.ux, p.uy
        end
        local _, _, nx, ny = pieceAt(q, u)
        local dot = tx * nx + ty * ny
        if abs(dot) < CROSS_GRAZE then return end
        out[#out + 1] = { s = (p.s0 + t) % Pa, t = (q.s0 + u) % Pb, into = dot < 0.0 }
    end

    for i = 1, #a.pieces do
        local p = a.pieces[i]
        local px0, px1, py0, py1 = boxOf(p)
        for j = 1, #bp do
            if px0 <= bx1[j] and bx0[j] <= px1 and py0 <= by1[j] and by0[j] <= py1 then
                local q = bp[j]
                local n, t1, u1, t2, u2 = meet(p, q)
                if n >= 1 then record(p, q, t1, u1) end
                if n >= 2 then record(p, q, t2, u2) end
                if n >= 1 then met = true end
            end
        end
    end
    if #out < 2 then return nil, met end

    -- ONE CROSSING FOUND TWICE IS ONE CROSSING: a point on the joint between two
    -- pieces of either boundary is on both of them. Across the seam at arc length
    -- zero as well as everywhere else.
    table.sort(out, function(x, y) return x.s < y.s end)
    local keep = {}
    for k = 1, #out do
        local last = keep[#keep]
        if not last or out[k].s - last.s > CROSS_SAME then keep[#keep + 1] = out[k] end
    end
    if #keep > 1 and (keep[1].s + Pa) - keep[#keep].s <= CROSS_SAME then
        keep[#keep] = nil
    end

    -- AND THEY MUST ALTERNATE. A closed boundary that goes into another comes back
    -- out before it goes in again, so an entry that follows an entry is a shape this
    -- cannot stitch honestly, and the two-component fallback is a picture rather
    -- than a guess.
    if #keep < 2 or (#keep % 2) ~= 0 then return nil, true end
    for k = 2, #keep do
        if keep[k].into == keep[k - 1].into then return nil, true end
    end
    return keep, true
end

--- The two boundaries as ONE closed loop, or nil when they do not properly cross.
---
--- A's boundary outside B, then B's boundary outside A, as many times over as they
--- cross -- once for two homothets, and up to N times for two different shapes.
--- THE PRIMS AND THE PARTS ARE THE SAME ONES THE TWO-COMPONENT SPELLING HANDS
--- SEAL, so nothing downstream can tell the two apart except by walking -- which is
--- the only thing that changed.
---
--- ═══ EVERY KEPT RUN IS CHECKED AT ITS MIDPOINT, AND THAT IS NOT BELT AND
---     BRACES ═══
---
--- Which crossing is the entry and which the exit is an argument about winding
--- (see the header), and an argument is a thing that can be wrong. A run kept on
--- the wrong side of it would be the OPPOSITE of the defect being fixed -- the
--- swallowed stretches drawn and the outer ones dropped -- and it would look
--- plausible on a map. A signed distance per run says which side it is really on,
--- and a disagreement falls back to the two-component boundary instead of drawing
--- a loop nobody can account for.
--- @return table|nil shape
--- @return boolean met   whether the two boundaries met at all; see crossings()
local function stitch(a, b)
    -- THE BOUNDING CIRCLES FIRST. One subtraction answers every disjoint pair,
    -- which on a breakout phase is most of them -- see boundRadius.
    local ac, bc = BR.StormShape.discFor(a), BR.StormShape.discFor(b)
    local dx, dy = bc.x - ac.x, bc.y - ac.y
    if sqrt(dx * dx + dy * dy) > boundRadius(a) + boundRadius(b) then
        return nil, false
    end

    local xs, met = crossings(a, b)
    if not xs then return nil, met end

    -- START ON AN EXIT, so the list reads exit, entry, exit, entry ... and each
    -- exit with the entry after it names one run of A outside B.
    if xs[1].into then
        local first = table.remove(xs, 1)
        xs[#xs + 1] = first
    end

    local Pa, Pb = a.P, b.P
    local pieces = {}
    local nx = #xs
    for k = 1, nx, 2 do
        local sOut, sIn = xs[k].s, xs[k + 1].s
        -- FROM WHERE IT LEAVES B, FORWARD TO WHERE IT NEXT ENTERS B -- one run of
        -- A's boundary outside B, which is why no classification of the pieces is
        -- needed.
        local la = (sIn - sOut) % Pa
        if la <= 0.0 then return nil, true end

        -- AND THEN B, FROM THAT ENTRY -- which is where B leaves A -- FORWARD TO
        -- THE NEXT EXIT OF A, which is where B goes back in. Both are crossings, so
        -- B's own arc length at each was read off the same intersection that found
        -- it: the seam is one point reached two ways, to the rounding.
        local tFrom = xs[k + 1].t
        local tTo   = xs[(k + 1) % nx + 1].t
        local lb = (tTo - tFrom) % Pb
        if lb <= 0.0 then return nil, true end

        local mx, my = BR.StormShape.pointAtArc(a, sOut + la * 0.5)
        if BR.StormShape.distance(b, mx, my) < 0.0 then return nil, true end
        local qx, qy = BR.StormShape.pointAtArc(b, tFrom + lb * 0.5)
        if BR.StormShape.distance(a, qx, qy) < 0.0 then return nil, true end

        local as = sliceOf(a, sOut, la)
        for i = 1, #as do pieces[#pieces + 1] = as[i] end
        local bs = sliceOf(b, tFrom, lb)
        for i = 1, #bs do pieces[#pieces + 1] = bs[i] end
    end
    if #pieces < 2 then return nil, true end

    local prims = {}
    for _, p in ipairs(a.prims or {}) do prims[#prims + 1] = p end
    for _, p in ipairs(b.prims or {}) do prims[#prims + 1] = p end
    return seal(pieces, 'blobUnion', { parts = { a, b }, prims = prims })
end

--- Two shapes as ONE boundary where they overlap, and two where they do not.
---
--- ═══ THE PARTS ARE KEPT FOR distance() AND inset() AND FOR NOTHING ELSE ═══
---
--- seal() stamps each piece with its arc length and its component index, so the
--- pieces handed in here are re-stamped into THIS shape's arc length and the
--- parts' own `P`, `comps` and `s0` values are left describing a boundary that is
--- no longer theirs. That is deliberate rather than overlooked -- copying 2N piece
--- tables per zone build, every frame, to keep two bookkeepings alive when only
--- one is ever read would be paying for tidiness with garbage. distance() and
--- inset() read `hull`, `box` and `discs`, which the stamping does not touch.
--- NOTHING MAY WALK A PART: no perimeter, no pointAtArc, no nearestArc. Walk the
--- union, which is what the renderer does.
---
--- ═══ ONE COMPONENT WHEN THEY CROSS, TWO WHEN THEY DO NOT (#356) ═══
---
--- stitch() above is the overlapping case and returns nil for every other one, so
--- the concatenation below is now what DISJOINT means rather than what a union
--- means. A disjoint pair must keep both components: they are kilometres apart,
--- the gap between them is not safe, and a strip that walked through the seam
--- would bridge them with one quad across the sea.
--- @return table shape
function BR.StormShape.blobUnion(a, b)
    local one, met = stitch(a, b)
    if one then return one end

    -- ONE SHAPE SWALLOWED THE OTHER, WHICH IS zone()'s NESTED CASE ARRIVING LATE.
    -- Asked only when the two boundaries never met -- nested or apart, and nothing
    -- else -- so the ordinary overlap never pays for it and a disjoint pair pays
    -- two signed distances. See insideWhole.
    if not met then
        if insideWhole(a, b) then return b end
        if insideWhole(b, a) then return a end
    end

    local pieces = {}
    for _, pc in ipairs(a.pieces) do pieces[#pieces + 1] = pc end
    local first = true
    for _, pc in ipairs(b.pieces) do
        -- THE SECOND BOUNDARY SAYS SO, which is the whole of what components are
        -- for: a strip that walked straight through the seam would bridge the two
        -- loops with one quad across the gap between them.
        if first then pc.newComponent = true first = false end
        pieces[#pieces + 1] = pc
    end
    local prims = {}
    for _, p in ipairs(a.prims or {}) do prims[#prims + 1] = p end
    for _, p in ipairs(b.prims or {}) do prims[#prims + 1] = p end
    return seal(pieces, 'blobUnion', { parts = { a, b }, prims = prims })
end

--- Is there anything left of `part` after eroding it by `metres`?
---
--- The inscribed radius is the answer: a convex shape eroded by more than the
--- radius of the largest disc that fits inside it is empty. Asked of a UNION's
--- parts, so that a component the storm never had cannot be manufactured by the
--- renderer's own six metres of edgeInset -- union2's header argues the decision
--- for discs and this is the same one for blobs.
local function survivesInset(part, metres)
    local h = part and part.hull
    if h then
        local m = part.blob
        return (-hullDistance(h, m.cx, m.cy) - metres) > 0.0
    end
    local d = part and part.discs and part.discs[1]
    return d ~= nil and (d.r - metres) > 0.0
end

-- ----------------------------------------------------------------- queries ---

--- The ONE DISC a path that can only draw a disc should draw this shape as.
---
--- ═══ IT IS A LIE FOR EVERYTHING BUT A CIRCLE, AND THE CALLER IS THE LIE ═══
---
--- There is exactly one such path: /brwallstyle's 'solid' renderer, a single
--- DrawMarker type 1 whose side surface is the whole curtain. A cylinder is a
--- circle by construction, so forced onto any other shape it paints a disc and
--- says nothing about the rest -- which is known ground rather than a defect,
--- because that path exists to be the A/B baseline the real wall is judged
--- against and nothing reaches it without somebody typing the command.
---
--- IT EXISTS BECAUSE THAT PATH INDEXED `discs[1]` DIRECTLY, which is #339's second
--- landmine: a nil index and a dead frame callback on any shape with no disc list,
--- reachable by one console command on every phase of every match once the storm
--- stopped being round.
---
--- The blob answers with the circle it replaced -- its own centre and the radius
--- the solver reported -- which is the disc a cylinder was drawing before #344 and
--- therefore exactly the baseline the A/B wants.
--- @return table  { x, y, r }
function BR.StormShape.discFor(shape)
    local kind = shape and shape.kind
    if kind == 'circle' or kind == 'union2' then
        local d = shape.discs[1]
        return { x = d.x, y = d.y, r = d.r }
    end
    if kind == 'blob' then
        local m = shape.blob
        return { x = m.cx, y = m.cy, r = m.r }
    end
    if kind == 'blobUnion' then
        return BR.StormShape.discFor(shape.parts[1])
    end
    if kind == 'roundedRect' then
        local b = shape.box
        -- THE INSCRIBED DISC, so the cylinder cannot stand outside the shape it is
        -- standing in for. Every other reading of a rectangle as a disc is either
        -- outside it in the axes or outside it at the corners.
        return { x = b.cx, y = b.cy, r = (b.hx < b.hy) and b.hx or b.hy }
    end
    error('StormShape.discFor: no single disc stands in for a shape of kind '
        .. tostring(kind) .. ' -- the one caller draws a cylinder, and inventing '
        .. 'a radius for a shape nobody has decided that for is a wall in the '
        .. 'wrong place rather than a missing one')
end

--- Total length of the boundary, in metres. Sums every component.
--- @return number
function BR.StormShape.perimeter(shape)
    return shape and shape.P or 0.0
end

--- The separate CLOSED LOOPS the boundary is made of, in boundary order.
---
--- Each is `{ s0, len }`: where the loop starts in the shape's own arc length and
--- how many metres of it there are. A circle, a capsule and an overlapping union2
--- have one; a disjoint union2 has two. See seal()'s header for why the
--- distinction is load-bearing rather than descriptive.
---
--- @return table  { { s0 = number, len = number }, ... }
function BR.StormShape.components(shape)
    return (shape and shape.comps) or {}
end

--- Which component holds arc length `s`, and its index.
---
--- `s` IS WRAPPED HERE, for the same reason pointAtArc wraps it: the one caller
--- gets this from nearestArc and hands it straight on, and a value at or
--- fractionally over P must land on the last component rather than on nothing.
---
--- @param shape table
--- @param s number   metres along the boundary; any real number
--- @return table|nil component, integer index
function BR.StormShape.componentAt(shape, s)
    local comps = shape and shape.comps
    local P = shape and shape.P or 0.0
    if not comps or #comps == 0 or P <= 0.0 then return nil, 0 end
    s = s % P
    for i = 1, #comps do
        local c = comps[i]
        if s < c.s0 + c.len then return c, i end
    end
    -- Only reachable where the floating-point sum of the component lengths lands
    -- under the total, the same seam pieceAtArc documents.
    return comps[#comps], #comps
end

--- The PIECES of component `ci`, as offsets along that component.
---
--- Each is `{ t0, len }`: where the piece begins in the COMPONENT's own arc
--- length -- the units pointAtComponent takes -- and how many metres of it there
--- are. A circle's only component has one run; an overlapping union2's has two,
--- and the join between them is a reflex corner.
---
--- ═══ THIS EXISTS BECAUSE A CORNER IS NOT A CURVE, AND A WALK THAT STEPS AT
---     UNIFORM ARC LENGTH CANNOT KNOW THE DIFFERENCE ═══
---
--- A renderer that replaces the boundary with straight chords prices its step off
--- CURVATURE: chord sag is ds^2 / 8r, so a step of sqrt(8 * r * sag) keeps every
--- chord within sag of the arc it replaces. That rule is sound and it is blind to
--- exactly one thing -- a corner, where the curvature is infinite and the sag
--- bound does not hold at any step at all. A Venn union's component is two arcs
--- meeting at two reflex crossings, `c.len` is not a multiple of the step, so one
--- chord straddles each crossing and bridges it. THE NOTCH CUTS INWARD, SO THAT
--- CHORD LANDS OUTSIDE THE SHAPE.
---
--- Measured through the real renderer, as signed distance from the uninset
--- damaging boundary, worst case over the reachable separation range for each
--- shipping phase pair -- and the clean value is -6.00 m, which is the curtain
--- sitting exactly render.edgeInset inside the logical edge where it belongs:
---
---     2600 + 1600   stepping uniformly +33.11 m    forcing the corner -6.00 m
---     1600 +  950                      +23.71 m                      -6.00 m
---      950 +  520                      +15.84 m                      -6.00 m
---      520 +  260                       +9.35 m                      -6.00 m
---      260 +  110                       +3.66 m                      -6.00 m
---
--- A sweep of 235 reachable Venn geometries put 57 of them outside the server's
--- ten-metre damage cushion, and none of them after, so on the owner's "barely
--- overlapping, like a venn diagram" -- the exact geometry #328 exists for -- a
--- wedge up to 33 metres deep at each waist was being billed dps while drawn well
--- inside the purple curtain.
--- That is the live "20ft inside" report edgeInset exists for, INVERTED and about
--- five times larger. Circles and disjoint pairs never had it: they measure
--- -6.00 m either way, because a circle's component is one piece and a disjoint
--- pair's two components are a whole circle each, so neither has an interior
--- boundary to step over.
---
--- SO THE FIX IS A VERTEX AT EVERY RUN BOUNDARY, and that is a question about the
--- PIECE LIST rather than about the perimeter -- which is why it is answered here
--- and not in the renderer. It costs nothing: the walker splits the SAME point
--- count between the runs by length, and the five cases above close at 127, 102,
--- 82, 60 and 45 quads before and after.
---
--- ═══ AND EACH RUN CARRIES ITS OWN CURVATURE, WHICH IS #339's FIRST LANDMINE ═══
---
--- `r` is the run's radius of curvature: the arc's radius, or nil for a straight
--- run, which needs no subdivision at all because a chord of a straight line cuts
--- nothing off it.
---
--- The renderer used to price ONE step for the whole component -- off `shape.discs`,
--- which is no number at all for a shape with no disc list: the minimum stayed at
--- math.huge, the step was infinite, and every loop fell back to the `minSeg` floor
--- and sagged tens of metres inside the boundary it was drawn on.
---
--- READING THE TIGHTEST CURVATURE OF THE WHOLE SHAPE FIXES THAT AND IS STILL NOT
--- ENOUGH, which is worth writing down because it was tried. A blob is short,
--- sharply curved corner arcs joined by long flat runs -- so a single step and a
--- budget split by LENGTH hands most of the points to the straight runs, which need
--- one each, and starves the arcs that need several. MEASURED THROUGH THE RENDERER
--- at the shipping config: a phase-5 zone (r 260, corner radius 98) came out at
--- 4.99 m of sag against a chordM of 2.0, because each corner got one quad where it
--- needed two. So the step is priced PER RUN, off this number, and the budget is
--- split by what each run asked for rather than by how long it is.
---
--- @param shape table
--- @param ci number    a component index, as components() orders them
--- @return table  { { t0 = number, len = number, r = number|nil }, ... }
function BR.StormShape.runs(shape, ci)
    local out = {}
    local pcs = shape and shape.pieces
    local comps = shape and shape.comps
    if not pcs or not comps or not comps[ci] then return out end
    local base = comps[ci].s0
    for i = 1, #pcs do
        local pc = pcs[i]
        -- KEYED ON THE PIECE'S OWN COMPONENT MARK, not on an arc-length range.
        -- seal() writes `pc.comp` while it is grouping, so this is the same answer
        -- it recorded rather than a second derivation of it off two floating-point
        -- sums that agree to picometres and decide a boundary case between them.
        if pc.comp == ci then
            out[#out + 1] = { t0 = pc.s0 - base, len = pc.len,
                              r = (pc.kind == 'arc') and pc.r or nil }
        end
    end
    return out
end

--- The boundary point at `t` metres along ONE COMPONENT, and the outward normal.
---
--- ═══ THE WRAP IS MODULO THE COMPONENT, NOT MODULO THE PERIMETER ═══
---
--- This exists for exactly one reason, and it is the one pointAtArc exists for
--- spelled at the next level up. pointAtArc's `s % P` is honest for ONE closed
--- loop: a circle, or the Venn case where arc 1 ends where arc 2 begins. On a
--- DISJOINT union it is a lie -- arc length 0 is on the near circle and arc
--- length P1 is on the far one -- so a window that indexed off the end of its
--- component did not wrap round to the other side of the island it was drawing.
--- It jumped to the other island, kilometres away, and left a hole in the
--- curtain where the viewer was standing. So the component wrap lives here, in
--- this file, where no caller can forget it either.
---
--- @param shape table
--- @param c table     a component from components() / componentAt()
--- @param t number    metres along that component; any real number
--- @return number x, number y, number nx, number ny
function BR.StormShape.pointAtComponent(shape, c, t)
    if not c or c.len <= 0.0 then return BR.StormShape.pointAtArc(shape, t) end
    return BR.StormShape.pointAtArc(shape, c.s0 + (t % c.len))
end

--- The boundary point at arc length `s`, and the OUTWARD unit normal there.
---
--- `s` IS WRAPPED HERE, and that is the whole reason this is a function rather
--- than four lines at the call site. The column walk indexes slots either side
--- of the viewer's own and lets the index run negative or past the count,
--- because the angular walk it grew up on wrapped for free in cos/sin. An arc
--- walk indexed off the end of its piece table does not fail, it silently
--- returns the last piece's far end, so the wrap lives here, once, where no
--- caller can forget it.
---
--- @param shape table
--- @param s number    metres along the boundary; any real number
--- @return number x, number y, number nx, number ny
function BR.StormShape.pointAtArc(shape, s)
    local P = shape and shape.P or 0.0
    if P <= 0.0 then return 0.0, 0.0, 1.0, 0.0 end
    local pc, t = pieceAtArc(shape, s % P)
    if not pc then return 0.0, 0.0, 1.0, 0.0 end
    return pieceAt(pc, t)
end

--- The arc length of the boundary point NEAREST (px, py).
---
--- This is what replaces `base = math.atan(p.y - cy, p.x - cx)` in the column
--- renderer, and it answers the same question for a boundary of any shape: where
--- along it is the part the viewer is looking at.
---
--- Exact, from the piece list: for each piece, the radial or perpendicular foot
--- when it lands on that piece, and the nearer endpoint when it does not. A
--- point at the exact centre of a circle has no nearest point -- every boundary
--- point ties -- and gets the start of the arc it is the centre of, which is one
--- of the tied winners rather than an error.
---
--- @return number s
function BR.StormShape.nearestArc(shape, px, py)
    local pcs = shape and shape.pieces
    if not pcs or #pcs == 0 then return 0.0 end

    local bestS, bestD = 0.0, huge

    local function consider(s, x, y)
        local ddx, ddy = px - x, py - y
        local d = ddx * ddx + ddy * ddy
        if d < bestD then bestD, bestS = d, s end
    end

    for i = 1, #pcs do
        local pc = pcs[i]
        if pc.kind == 'arc' then
            -- How far along this arc the radial foot lies, measured in the
            -- sweep's own direction and wrapped into [0, 2*pi). For a whole
            -- circle the span is 2*pi, so this always lands on the piece and
            -- the endpoint branch is never taken.
            local off = ((atan(py - pc.cy, px - pc.cx) - pc.a0) * pc.out) % TAU
            local span = abs(pc.sweep)
            if off <= span then
                local t = off * pc.r
                local x, y = pieceAt(pc, t)
                consider(pc.s0 + t, x, y)
            else
                local x, y = pieceAt(pc, 0.0)
                consider(pc.s0, x, y)
                x, y = pieceAt(pc, pc.len)
                consider(pc.s0 + pc.len, x, y)
            end
        else
            -- The perpendicular foot, clamped to the run's own ends.
            local t = (px - pc.x0) * pc.ux + (py - pc.y0) * pc.uy
            if t < 0.0 then t = 0.0 elseif t > pc.len then t = pc.len end
            local x, y = pieceAt(pc, t)
            consider(pc.s0 + t, x, y)
        end
    end

    -- WRAPPED, BECAUSE THE LAST PIECE'S FAR END IS SPELLED `P` AND `P` IS NOT
    -- IN THE DOMAIN. The endpoint branch above considers `pc.s0 + pc.len`, and
    -- on the final piece that sum IS the perimeter: the same vertex the walk
    -- calls 0. Which spelling wins is decided by the last bits of two different
    -- floating-point reconstructions of one point, so it is not a case anybody
    -- would think to test for. Found in review on a real union --
    -- union2(0, 0, 900, 1300, 0, 700) at (291.9, 97.3) returned exactly its own
    -- perimeter, on 15 of 3721 grid points.
    --
    -- NOT LIVE TODAY AND FIXED ANYWAY. The one caller in client/storm.lua turns
    -- this into an index and hands it back to pointAtArc, which wraps, so the
    -- wall draws the identical markers either way. It is fixed here because
    -- this file's header promises every caller a value in [0, P) and pieceAtArc
    -- documents that its argument must already be wrapped; the next consumer to
    -- use the answer for a piece lookup rather than a point is the one that
    -- pays for the promise being untrue.
    local P = shape.P
    return (P and P > 0.0) and (bestS % P) or bestS
end

--- The MINIMAP PRIMITIVES this shape is drawn as, in draw order.
---
--- Each is one blip the client will create:
---
---   { kind = 'radius', cx, cy, r }            a filled disc
---   { kind = 'area',   cx, cy, w, h, rot }    a filled rectangle, rot in degrees
---
--- ═══ THIS IS THE MAP'S FALLBACK NOW, AND IT IS NOT THE BOUNDARY (#347, #350) ═══
---
--- GTA has two filled minimap primitives and nothing else. ADD_BLIP_FOR_RADIUS
--- fills a disc, _ADD_BLIP_FOR_AREA fills a rectangle, and SET_RADIUS_BLIP_EDGE
--- draws a disc as an outline -- with no equivalent for an area blip. No NATIVE
--- strokes or fills an arbitrary polygon on either map.
---
--- WHAT THIS PARAGRAPH USED TO SAY NEXT WAS THAT THE ONLY ROUTE TO ONE WOULD BE
--- AUTHORING A SCALEFORM ASSET, AND THAT WAS WRONG: the estate already ships one.
--- ScaleformUI_Assets' MINIMAP_LOADER.gfx carries ADD_AREA_OVERLAY, it is already
--- streamed on every client, and #347's spike drew a concave arrowhead through it
--- on the radar AND on the pause map, notch intact. polyline() below is the
--- boundary for that path.
---
--- SO THIS IS THE FALLBACK RATHER THAN THE ANSWER, and it stays exactly as it was
--- because it has to: the overlay lives behind a readiness gate that can refuse
--- (client/mapoverlay.lua, and the crash #348 is about), and a client that never
--- gets a handle must still see a zone on its map. The map is an approximation for
--- any shape that is not a disc, the place that decides HOW is the constructor,
--- beside the shape it is approximating, where the error can be stated in metres,
--- and this function only hands the list on.
---
--- ═══ READ OFF `prims`, WRITTEN AT CONSTRUCTION, NEVER OFF `discs` ═══
---
--- Same recorded-at-seal pattern `discs` uses, and a separate field for the reason
--- seal()'s header gives: `discs` is a promise that the shape IS the union of them,
--- which distance() and inset() are exact from. A rounded rectangle's map box is
--- not that promise and must not be able to be mistaken for it.
---
--- A SHAPE WHOSE KIND RECORDS NO PRIMITIVES HAS NO ANSWER HERE, and it errors for
--- the same reason distance() does. Returning an empty list would be worse than the
--- error in the one way that matters: an empty list draws NOTHING, so the first
--- shape to reach the map without a descriptor would take the safe-zone ring off
--- every player's map and say nothing at all about it.
---
--- Fresh tables, so a caller cannot write back into the shape through the answer.
--- @param shape table
--- @return table  { { kind = string, ... }, ... } in draw order
function BR.StormShape.mapPrimitives(shape)
    local prims = shape and shape.prims
    if not prims then
        error('StormShape.mapPrimitives: no map primitives recorded for a shape '
            .. 'of kind ' .. tostring(shape and shape.kind) .. ', and there is no '
            .. 'native that fills an arbitrary outline to fall back to')
    end
    local out = {}
    for i = 1, #prims do
        local p = prims[i]
        out[i] = { kind = p.kind, cx = p.cx, cy = p.cy, r = p.r,
                   w = p.w, h = p.h, rot = p.rot }
    end
    return out
end

--- THE BOUNDARY AS FLAT POINT LISTS, one per component -- the map's real answer.
---
--- ═══ WHAT THIS IS FOR, AND WHY IT IS NOT mapPrimitives (#350) ═══
---
---   "seems every storm is still a circle."               -- owner, 2026-09-22
---
--- The wall is a blob and has been since #344, but at phase 1 the nine corners are
--- 1815 m apart along the boundary and a player sees a few hundred metres of it, so
--- from the ground it reads as a circle. Corner spacing by radius: 2600 -> 1815 m,
--- 950 -> 663, 260 -> 182, 110 -> 77. THE MAP IS THE ONLY PLACE THE SHAPE IS
--- VISIBLE AT AN EARLY PHASE, and the map was drawing the circle the blob replaced.
---
--- ADD_AREA_OVERLAY fills an arbitrary polygon on the radar and on the pause map
--- (#347, spiked and looked at). It takes a flat list of world points per contour,
--- so this is the shape of the answer: one list per COMPONENT, because the movie
--- closes each contour and an overlapping zone stitched into one loop is one call
--- while two islands are two.
---
--- ═══ PRICED OFF CURVATURE, PER RUN, WHICH IS THE WALL'S OWN RULE ═══
---
--- Chord sag is ds^2 / 8r, so a step of sqrt(8 * r * maxChordError) keeps every
--- chord within maxChordError of the arc it replaces. Priced PER RUN off the run's
--- own radius, not once for the shape, for the reason client/storm.lua's strip
--- carries at length: a blob is short sharply-curved corner arcs joined by long flat
--- runs, a straight run needs no subdivision at all, and one step split by LENGTH
--- starves the corners that need the points.
---
--- AND A VERTEX AT EVERY RUN BOUNDARY, WHICH THE SAG RULE CANNOT GIVE. At a corner
--- the curvature is infinite and the bound does not hold at any step -- so a walk
--- that stepped uniformly would bridge each reflex crossing of a stitched union with
--- one chord, and THE NOTCH CUTS INWARD, so that chord lands outside the shape. That
--- is #339's measured landmine on the wall and it is the same landmine here: the fill
--- would cover ground the storm is billing. Every run starts on a point.
---
--- ═══ maxPoints IS A CEILING ON THE STRING, NOT ON THE PICTURE ═══
---
--- The Scaleform string-parameter cap is UNMEASURED. The spike's coordinates were
--- about 70 characters and a real boundary is over a thousand, so if a shape comes
--- out garbled rather than absent that cap is the first suspect -- and the only
--- lever against it is fewer points. Nil or zero means no ceiling. When the ceiling
--- bites, the budget is shared out by what each run ASKED FOR rather than by length,
--- and every run keeps at least one point, so the corners lose accuracy before the
--- outline loses its shape.
---
--- @param shape table
--- @param maxChordError number|nil  metres of sag allowed; defaults to 1 m
--- @param maxPoints number|nil      ceiling per component; nil or 0 for none
--- @return table  { { { x = number, y = number }, ... }, ... } one list per component
function BR.StormShape.polyline(shape, maxChordError, maxPoints)
    local out = {}
    local comps = BR.StormShape.components(shape)
    local sag = maxChordError or 0.0
    if sag <= 0.0 then sag = 1.0 end
    local cap = maxPoints or 0

    for ci = 1, #comps do
        local c = comps[ci]
        local runs = BR.StormShape.runs(shape, ci)
        local nRuns = #runs
        local pts = {}
        out[ci] = pts

        -- WHAT EACH RUN ASKS FOR, and a straight run asks for one: a chord of a
        -- straight line cuts nothing off it however long the run is.
        local want, total = {}, 0
        for i = 1, nRuns do
            local rn = runs[i]
            local k = 1
            if rn.r and rn.r > 0.0 then
                k = max(1, math.ceil(rn.len / sqrt(8.0 * rn.r * sag)))
            end
            want[i] = k
            total = total + k
        end

        if nRuns > 0 and total > 0 then
            local n = total
            if cap > 0 and n > cap then n = cap end
            if n < nRuns then n = nRuns end

            -- CUMULATIVE EDGES, ROUNDED ON THE RUNNING TOTAL, which is what makes
            -- the count come to exactly `n` by construction rather than by luck:
            -- rounding each run's own share independently does not have to sum. The
            -- clamp keeps it monotone -- one point minimum per run, and enough left
            -- for the runs after it. The same arithmetic the strip uses, for the same
            -- reason, and when n == total every edge is already an integer so each run
            -- is handed back precisely what it asked for.
            local edge = { [0] = 0 }
            local cum = 0
            for i = 1, nRuns do
                cum = cum + want[i]
                local k = math.floor(n * cum / total + 0.5)
                local lo, hi = edge[i - 1] + 1, n - (nRuns - i)
                if k < lo then k = lo end
                if k > hi then k = hi end
                edge[i] = k
            end

            for i = 1, nRuns do
                local rn = runs[i]
                local cnt = edge[i] - edge[i - 1]
                -- FROM THE RUN'S START, AND NOT INCLUDING ITS END. The next run's
                -- first point IS this run's end, and the movie closes the contour --
                -- so a point at the end as well would be a duplicate vertex at every
                -- corner and a zero-length edge in the fill.
                for j = 0, cnt - 1 do
                    local x, y = BR.StormShape.pointAtComponent(shape, c,
                        rn.t0 + rn.len * j / cnt)
                    pts[#pts + 1] = { x = x, y = y }
                end
            end
        end
    end
    return out
end

--- Signed distance to the boundary. Negative inside, positive outside.
---
--- ═══ THE MINIMUM OF THE DISC DISTANCES, NOT A WALK OF THE PIECES ═══
---
--- A point is inside a union exactly when it is inside one of the discs, so the
--- minimum of the per-disc signed distances gets the SIGN right everywhere and
--- the MAGNITUDE right everywhere outside and on the boundary -- which is every
--- place any consumer reads the magnitude. The damage test wants the sign. The
--- HUD's "how far to safety" and the wall's window width are read from outside.
---
--- WHERE IT IS NOT THE TRUE DISTANCE, said plainly so nobody has to rediscover
--- it: strictly inside the LENS where two discs overlap, the nearest point of a
--- disc's own circle can be a point the other disc has swallowed, so it is not
--- on the union's boundary at all. Two unit discs 1.0 apart read -0.5 at the
--- midpoint where the true distance to the outline is -0.866. The error is
--- always in the direction of reading SHALLOWER than the truth, never deeper, so
--- nothing can be told it is safely inside when it is not. For an exact answer
--- at a point inside a union, walk to nearestArc and measure -- that is what
--- makes these two functions different rather than redundant.
---
--- ═══ AND THE ROUNDED RECTANGLE IS EXACT EVERYWHERE, INSIDE INCLUDED ═══
---
--- The standard rounded-box signed distance, in the shape's own parameters:
--- subtract the INNER rectangle's half-extents from the absolute offset, and the
--- answer is the length of that clamped to the positive quadrant, plus the deepest
--- negative coordinate when both are negative, minus the corner radius. One
--- expression covering all nine regions -- four corners, four edges, the interior
--- -- with no case split to get wrong, and no understatement anywhere. It joins the
--- single circle in being exact inside as well as out; the UNION is the one case
--- here that understates depth, and anything wanting the truth inside one still has
--- to walk to nearestArc.
---
--- ═══ THE DISPATCH IS ON `kind`, NOT ON WHETHER `discs` IS THERE ═══
---
--- This used to be `if not shape.discs then error(...)`, which was right while
--- every shape here was a union of discs and is a trap the moment one is not: any
--- shape that grew a disc list for an unrelated reason -- a bounding disc, a
--- broad-phase cull, a decomposition recorded for the renderer -- would silently
--- start being MEASURED as the union of it, and the answer would be wrong in the
--- unsafe direction with nothing to notice. Keying on the shape's own name means a
--- new kind gets a real function or an error, and never an inherited one.
---
--- A KIND WITH NO IMPLEMENTATION STILL ERRORS, and that is the point of the whole
--- arrangement rather than an unfinished branch. The capsule has no signed distance
--- because nothing has ever needed one; the day something does, this error is what
--- makes somebody write it instead of shipping a bounding disc that reads shallow.
---
--- @return number  metres, negative inside
function BR.StormShape.distance(shape, px, py)
    local kind = shape and shape.kind

    if kind == 'circle' or kind == 'union2' then
        local discs = shape.discs
        local best = huge
        for i = 1, #discs do
            local c = discs[i]
            local ddx, ddy = px - c.x, py - c.y
            local d = sqrt(ddx * ddx + ddy * ddy) - c.r
            if d < best then best = d end
        end
        return best
    end

    -- ═══ AND THE BLOB IS EXACT EVERYWHERE, INSIDE INCLUDED ═══
    --
    -- The maximum of the supporting constraints -- see hullDistance, which is
    -- where the argument is written down. It joins the single circle and the
    -- rounded rectangle in being exact inside as well as out.
    if kind == 'blob' then
        return hullDistance(shape.hull, px, py)
    end

    -- ═══ AND A TWO-COMPONENT UNION IS THE MINIMUM OF ITS PARTS, WHICH IS EXACT
    --     FOR ANY TWO SHAPES AT ALL ═══
    --
    -- A point is inside a union exactly when it is inside one of the parts, so the
    -- minimum gets the SIGN right everywhere and the MAGNITUDE right everywhere
    -- outside and on the boundary -- which is every place any consumer reads the
    -- magnitude. THAT IS WHY THE DAMAGE RULE IS STILL EXACT on an overlapping
    -- breakout whose WALL is not (zone()'s header names the artifact): the server
    -- asks only whether a player is further outside than the cushion allows.
    --
    -- Strictly inside an overlap it understates DEPTH for the same reason the disc
    -- union does -- a part's own nearest boundary point can be one the other part
    -- has swallowed -- never the other way, so nothing can be told it is safely
    -- inside when it is not.
    if kind == 'blobUnion' then
        local best = huge
        for i = 1, #shape.parts do
            local d = BR.StormShape.distance(shape.parts[i], px, py)
            if d < best then best = d end
        end
        return best
    end

    if kind == 'roundedRect' then
        local b = shape.box
        -- Offset from the centre, folded into the first quadrant -- the shape is
        -- symmetric in both axes, so one corner's arithmetic answers for all four.
        local qx = abs(px - b.cx) - (b.hx - b.cr)
        local qy = abs(py - b.cy) - (b.hy - b.cr)
        -- OUTSIDE THE INNER RECTANGLE IN A GIVEN AXIS, that axis contributes; inside
        -- it, it does not. Both positive is a corner and the length is the distance
        -- to the arc centre; one positive is an edge and the length collapses to that
        -- one term. Both negative is the interior, where `length` is zero and the
        -- second term carries the answer.
        local ex = (qx > 0.0) and qx or 0.0
        local ey = (qy > 0.0) and qy or 0.0
        local outside = sqrt(ex * ex + ey * ey)
        local inside = (qx > qy) and qx or qy
        if inside > 0.0 then inside = 0.0 end
        return outside + inside - b.cr
    end

    error('StormShape.distance: no signed distance for a shape of kind '
        .. tostring(kind) .. ' -- a guess here would be read as a fact by the '
        .. 'damage test, so the kind gets a real function or nothing')
end

--- The same shape, shrunk by `metres`.
---
--- This is what pays the edgeInset debt in the column renderer: a marker's
--- translucent surface reads fatter than its scale, so the visible curtain is
--- drawn slightly INSIDE the logical edge and standing at the wall is always
--- genuinely safe.
---
--- Rebuilt from the disc list rather than by offsetting pieces, which is exact
--- for a single disc and is the same construction the shape came from.
---
--- FOR A UNION IT SHRINKS EACH DISC, which is not quite the true erosion: near
--- the join the eroded union is a little wider than the union of the eroded
--- discs. It errs the same way distance() does, INWARD, which is the safe
--- direction for the only thing this is used for -- the drawn boundary may pull
--- a little further inside the logical edge near a reflex corner, and can never
--- sit outside it.
---
--- Radii floor at one metre, as everything here does, so an inset larger than
--- the shape leaves a boundary that can still be walked instead of a shape with
--- no length. See MIN_RADIUS.
---
--- AN INSET THAT EATS ONE DISC OF A UNION LEAVES THE OTHER, rather than leaving a
--- one-metre pillar beside it. `c.r - metres` goes to zero or below and union2
--- reads that as a disc that is not there -- see its header, which is where the
--- decision is argued. It errs INWARD, which is the direction this whole function
--- is allowed to err in, and it is what stops the renderer's own six metres of
--- edgeInset from manufacturing a component the storm never had.
---
--- ═══ FOR A ROUNDED RECTANGLE IT IS EXACT, AND IT IS THE SAME ONE SUBTRACTION
---     THREE TIMES ═══
---
--- Eroding a rounded box by m gives a rounded box with both half-extents AND the
--- corner radius smaller by m, exactly -- the straight edges move in by m because
--- they are straight, and the corner arcs keep their centres and lose m of radius.
--- No approximation, unlike the union case above.
---
--- WHAT THE FLOORS DO TO THAT, said here because the arithmetic hides it: an m
--- larger than `cr` would want a SHARP corner, and roundedRect floors the corner
--- radius at MIN_RADIUS instead -- a one-metre round on a corner that should be
--- square, which is the inward error the constructor argues for. An m larger than a
--- half-extent leaves that extent at MIN_RADIUS as well, so a shape eaten by its own
--- inset is a small walkable shape rather than nothing, exactly as the circle case
--- has always been.
---
--- THE DISPATCH IS ON `kind` FOR THE REASON distance() GIVES, and the two must stay
--- keyed the same way: the wall measures its own inset shape, so a kind that one of
--- them answers for and the other does not is a renderer drawing a boundary it
--- cannot then ask questions about.
---
--- @return table shape
function BR.StormShape.inset(shape, metres)
    local kind = shape and shape.kind
    metres = metres or 0.0

    if kind == 'circle' or kind == 'union2' then
        local discs = shape.discs
        if #discs == 1 then
            local c = discs[1]
            return BR.StormShape.circle(c.x, c.y, c.r - metres)
        end
        local a, b = discs[1], discs[2]
        return BR.StormShape.union2(a.x, a.y, a.r - metres,
            b.x, b.y, b.r - metres)
    end

    if kind == 'roundedRect' then
        local b = shape.box
        return BR.StormShape.roundedRect(b.cx, b.cy,
            b.hx - metres, b.hy - metres, b.cr - metres)
    end

    -- ═══ FOR A BLOB IT IS THE TRUE EROSION, CORNER BY CORNER ═══
    --
    -- See erode(): a corner at least `metres` round keeps its centre and loses that
    -- much radius, a sharper one becomes sharp where its offset runs meet, and a run
    -- the erosion turns inside out takes its two sharp ends with it. Not a
    -- scaled-down blob: a blob of radius r - d would pull every corner toward the
    -- middle as well, which is a smaller shape rather than an eroded one.
    --
    -- WHEN THE EROSION EATS A RUN BESIDE AN ARC, THE ARC'S CHORDS ARE ERODED
    -- INSTEAD. That case wants an arc and a line intersected, which is a different
    -- algorithm -- so the shape's chord polygon, a centimetre inside it at most, is
    -- eroded exactly in its place: a SUBSET of the true erosion by that centimetre,
    -- so it errs INWARD, which is the direction this whole function is allowed to err
    -- in. MEASURED at a six-metre inset over 2,000 shipping shapes a radius: never at
    -- 25 m and above, 1 in 2,000 at 15 m, 2% at 10 m -- the last seconds of the final
    -- sweep. See chorded().
    --
    -- AND WHAT IS LEFT OF NOTHING IS THE INSCRIBED CIRCLE, floored like every circle:
    -- an erosion past the shape's own depth is empty, and the one-metre circle at its
    -- centre is the point a collapsed zone has always been.
    if kind == 'blob' then
        local h, m = shape.hull, shape.blob
        local ks = erode(h.ks, metres) or erode(chorded(h.ks, CHORD_SAG), metres)
        if ks then
            return hullOf(ks, {
                blob = { cx = m.cx, cy = m.cy, r = m.r - metres, unit = m.unit },
                prims = { { kind = 'radius', cx = m.cx, cy = m.cy,
                            r = m.r - metres } },
            })
        end
        return BR.StormShape.circle(m.cx, m.cy,
            -hullDistance(h, m.cx, m.cy) - metres)
    end

    -- ═══ AND A UNION ERODES ITS PARTS, WHICH IS union2's OWN COMPROMISE ═══
    --
    -- Near the join the eroded union is a little wider than the union of the
    -- eroded parts, so this errs INWARD exactly as the disc union's inset does --
    -- the drawn boundary may pull a little further inside the logical edge where
    -- two components meet, and can never sit outside it.
    --
    -- A PART EATEN BY THE INSET LEAVES THE OTHER, rather than a one-metre stub
    -- beside it, for the reason union2's header argues: a component the storm never
    -- had is worse than a boundary drawn slightly small.
    if kind == 'blobUnion' then
        local kept = {}
        for i = 1, #shape.parts do
            local part = shape.parts[i]
            if survivesInset(part, metres) then
                kept[#kept + 1] = BR.StormShape.inset(part, metres)
            end
        end
        if #kept == 0 then
            -- Both parts eaten, which is a zone smaller than the renderer's own
            -- edgeInset -- the collapsed endgame. The first part's remnant is a
            -- boundary that can still be walked, which is what MIN_RADIUS exists
            -- to guarantee and what a collapsed zone has always been.
            return BR.StormShape.inset(shape.parts[1], metres)
        end
        if #kept == 1 then return kept[1] end
        return BR.StormShape.blobUnion(kept[1], kept[2])
    end

    error('StormShape.inset: no erosion for a shape of kind ' .. tostring(kind)
        .. ' -- offsetting a straight run is a different algorithm from shrinking '
        .. 'a radius, and the wall draws whatever this hands back')
end
