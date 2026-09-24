-- The storm's boundary as a WALKABLE SHAPE rather than as a radius.
--
-- EVERY PHASE IS A RANDOM SHAPE NOW (#344), and that is what this file was
-- built for:
--
--   "ship something that will draw random shaped storm walls for each phase,
--    still matching our approximate positioning and size rules, circles are not
--    allowed."                                      -- the owner, 2026-09-22
--
-- The shape is blob() below: the convex hull of a zone's corner discs -- a
-- jittered polygon stretched up to 3:1 and held to its phase's area, its corners
-- each rounded, beveled or sharp, or one zone in ten a plain circle -- and between
-- two zones the hull of those discs moving corner to corner. Runs and arcs, the
-- piece model this file has walked since the day it was written. The renderer
-- does not know it is drawing anything in particular. It asks for a perimeter, walks it in metres, and asks where the
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
local acos = math.acos
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
        -- `meet` is an INTERSECTION's two shapes (BR.StormShape.intersect), kept so
        -- its erosion is the intersection of theirs -- exact, where eroding the
        -- corner list it came out as would have to chord the arcs beside its
        -- crossings. See inset().
        meet = meta.meet,
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
-- ═══ A ZONE IS THE CONVEX HULL OF ITS CORNER DISCS, DRAWN BY AREA (#344) ═══
--
--   "the storm is still too circular. let's draw it by area now instead of any
--    consideration for a radius."                     -- the owner, 2026-09-23
--   "these shapes do be lookin far too circular...... especially the ones that
--    aren't circles. We need more aspect ratio mix."  -- the owner, 2026-09-23
--
-- A zone is a convex polygon whose vertices each draw a finish, and the three
-- finishes are the three things a corner of a convex polygon can be:
--
--   rounded    an arc tangent to both edges -- ONE DISC, of the arc's radius
--   beveled    the corner cut off by a chamfer -- TWO POINTS, the chamfer's ends
--   cornered   the vertex itself -- ONE POINT
--
-- and the zone is the convex hull of those discs and points. A circle zone is one
-- disc. So every zone is described by a short list of DISCS (a point is a disc of
-- radius 0), and three things follow from that one description:
--
--   THE SHAPE IS A CORNER LIST. The boundary of the hull of discs is arcs of some
--   of them joined by runs tangent to two -- discHull below walks it -- which is
--   the corner list every query in this file is exact for:
--
--     THE SIGNED DISTANCE. For a convex body it is the supremum over unit
--     directions u of (<p, u> - h(u)), where h is the support function -- and h
--     here is <c, u> + rho on each corner's own range of u. So the supremum is
--     reached on a run's normal or radially from the one corner whose range holds
--     the direction to p: a maximum over the same pieces the boundary is made of,
--     exact inside as well as out. hullDistance carries it.
--
--     THE EROSION. Shrinking a convex body by d subtracts d from its support
--     function. A corner whose radius is at least d keeps its centre and loses d; a
--     corner smaller than that -- every sharp one -- becomes sharp where its two
--     offset runs meet. See erode().
--
--   CONTAINMENT IS EXACT AND CHEAP. A convex shape D is inside a convex shape Z
--   exactly when every one of D's discs is: the hull of discs inside a convex set
--   is inside it. So "does the next zone fit inside this one" is a maximum over a
--   dozen signed distances (fitOf) rather than a boundary walk.
--
--   THE MORPH IS A HULL OF MOVING DISCS. Pair each disc of the zone the wall leaves
--   with a disc of the zone it closes on, move every pair in a straight line, and
--   the wall at any moment is the hull of where they are. See `the morph` below.
--
-- ═══ BY AREA, WITH A STRETCH DRAWN ACROSS THE WHOLE RANGE ═══
--
-- Every zone holds `area` of its phase circle's area, exactly -- the pacing lives in
-- that number -- and nothing about it is measured against the radius any more. What
-- a zone may be instead is STRETCHED: longest length over narrowest width up to
-- `stretch` (the owner's 3:1, "I'm assuming this is a maximum"), with the target
-- drawn uniformly across [1, stretch] so long zones are ordinary rather than rare.
-- The stretch is an area-preserving affine map of the vertex ring along a drawn
-- axis, solved for by bisection, and measured exactly as the diameter over the
-- minimum width off the width function h(u) + h(u + pi). See blobUnit.
--
-- ═══ CONVEXITY IS NOT GUARANTEED BY THE DRAW AND IS ENFORCED, NOT HOPED FOR ═══
--
--   "if it costs us anything today let's not change it and not allow dents
--    inward."                                         -- the owner, 2026-09-23
--
-- Radii jittered about 1 can put a vertex inside the line between its neighbours,
-- and a concave shape breaks every exactness claim above -- the support-function
-- argument IS convexity -- and #356's stitch, which walks the crossings of two
-- convex boundaries. So a draw that fails the test is redrawn from values the SAME
-- stream already handed out, with both jitters reduced, and the last attempt has
-- no jitter at all, which is a regular polygon and convex by construction. A hull
-- of discs is convex whatever the discs are, so nothing after the ring can dent it.
local BLOB_TRIES    = 6
local BLOB_FALLOFF  = 0.75

-- ═══ THE CORNER COUNT IS DRAWN PER ZONE ═══
--
--   "We're able to reliably draw squircle storms, but what about random other
--    shapes of various vertices?"                   -- the owner, 2026-09-23
--   "triangles and squares are okay with me"        -- the owner, 2026-09-23
--
-- Three to twelve, and the area holds at every count because every draw is SCALED
-- to it. The `reach` rule that kept triangles and squares out -- no corner past
-- 1.15 of r -- is gone with the rest of the radius reasoning: a zone is placed by
-- its real shape now (BR.NextZoneCentre), so how far a corner reaches from a centre
-- no longer bounds anything.
--
-- BLOB_MAX_CORNERS is how far up a weight table is read, and it is also how many
-- finishes and jitter pairs every zone draws whatever its count -- see blobUnit.
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
-- cosine of half the turn, which is what a spike sends to zero. A stretch that
-- would make a corner that sharp is refused by the stretch solve, which is why a
-- long triangle stops short of the 3:1 cap more often than a long hexagon does.
local BLOB_MIN_TURN = 0.05

-- A radian a trillion times smaller than the smallest turn this file builds. Two
-- normal angles nearer than this are ONE breakpoint when two corner lists are
-- merged, so the merge never makes a corner that turns by nothing.
local ANGLE_EPS = 1e-12

-- Metres, or units of a unit shape, within which the disc hull treats two discs as
-- one: a disc inside another (or on it) has no tangent to it and is not a corner.
local HULL_EPS = 1e-9

-- ═══ HOW FAR A ROUNDED CORNER'S DISC MAY GROW, AND WHY IT IS CAPPED AT ALL ═══
--
-- A corner's fillet is sized off the edges beside it -- `cut` of the shorter
-- half-edge -- and at a nearly flat vertex that radius runs away: the tangent
-- length is fixed and the radius is it times tan(half the interior angle), up to
-- forty times the tangent length on a shipping draw. The ARC is still inside the
-- polygon; the whole DISC is not, and a disc standing past the far side of the
-- shape would put that side in the hull. MEASURED: without the cap, eleven percent
-- of zones failed to fit inside their predecessor for exactly this.
--
-- So each rounded disc is held to RHO_FIT of the largest disc on its bisector that
-- stays inside every other edge's line -- closed form, see finishDiscs -- and with
-- that the zone is the hull of its discs exactly.
--
-- WHAT THE CAP DOES NOT PROMISE: that a big disc bounds its shape ONCE. Inside every
-- edge line is not inside every other corner's chamfer, so on a long shape a
-- near-flat vertex's disc can reach round to the far side and carry a stretch of it
-- past another corner's bevel -- a disc that is two corners of the hull. The shape
-- is still exactly the hull of its discs, and the arc it adds there is nearly
-- straight. MEASURED on the shipping draw: 1.5 percent of zones, and no disc of any
-- vertex ever swallowed.
local RHO_FIT = 0.98

-- How many times the stretch is bisected. Thirty halvings of a factor-of-a-few
-- range is well under a millionth of the stretch, and it is a FIXED count so both
-- sides of the wire stop on the same value.
local STRETCH_STEPS = 30

-- ═══ THE LADDER A ZONE CLIMBS TO FIT INSIDE THE ONE BEFORE IT ═══
--
-- Zone z has to fit CONCENTRIC inside zone z-1 at the ratio of their radii, with
-- `fitClear` of r to spare -- see blobUnit for why concentric. A long zone turned
-- across a long parent will not, so it is turned (every 15 degrees, nearer turns
-- first) and then, if no turn fits, tamed: the stretch ladder below. The last rung
-- is the parent's own shape, which always fits.
local FIT_TURN  = pi / 12
local FIT_TURNS = 12

--- What a vertex can be, in the order its roll is read. Fixed, never a pairs() walk,
--- for the reason blobUnit reads the corner counts in order.
local VERTEX_KINDS = { 'rounded', 'beveled', 'cornered' }

--- The options a nil `opts` reads as: one shared table, so a caller passing none
--- still hits the cache rather than handing it a fresh table every call.
local NO_OPTS = {}

--- One corner: a centre, a radius, and the normals it turns the boundary through.
---
--- The cosines and sines of both ends are taken HERE, once, and carried: every
--- query below reads them, and a placed corner inherits them rather than asking
--- math.cos again. `h1` is the support value on the run AFTER this corner, which
--- is the one number the signed distance reads per run.
local function corner(x, y, rho, a0, a1, c0, s0, c1, s1)
    c0, s0 = c0 or cos(a0), s0 or sin(a0)
    c1, s1 = c1 or cos(a1), s1 or sin(a1)
    return { x = x, y = y, rho = rho, a0 = a0, a1 = a1,
             c0 = c0, s0 = s0, c1 = c1, s1 = s1,
             h1 = x * c1 + y * s1 + rho }
end

--- Does the direction (dx, dy) fall inside corner k's range of normals?
---
--- Two cross products for every corner that turns by less than half a turn. A
--- corner that turns by more -- a circle's, or a big disc between two small ones
--- in a hull -- gets the angle instead of a test that would read a reflex wedge as
--- its complement.
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
--- to each other -- a circle's own seam, or two moving discs of a morph that turn
--- at that normal -- and left in it would be a piece with a normal read off a
--- rounding error.
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
            -- a circle's, or a hull's big disc between two small ones, eroded past
            -- its own radius. Handed back as nil, and inset() erodes the chords.
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
--- inscribed CIRCLE there, which is inside too but is a different shape: measured,
--- the Minkowski morph through the last two phases hit that on about one frame in
--- two hundred, and the wall would have jumped to a circle and back for it. A hull of
--- discs does not reach it (see inset()); it stays as the guard.
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

-- ------------------------------------------------------------ the disc hull ---

--- THE CONVEX HULL OF A LIST OF DISCS, as a corner list. A point is a disc of
--- radius 0.
---
--- ═══ GIFT WRAPPING BY OUTWARD NORMAL ═══
---
--- Start on the disc that reaches furthest along +x -- the support at normal angle
--- 0 -- and turn the normal counter-clockwise. The disc bounding the shape at the
--- current normal keeps doing so until some other disc overtakes it, and disc j
--- overtakes disc i where <c_j - c_i, u> = r_i - r_j first becomes true on the way
--- round: at the angle of (c_j - c_i) less acos((r_i - r_j) / |c_j - c_i|). The
--- smallest advance names the next corner, and the walk ends when the normal has
--- gone once round. Every corner is one disc and the RANGE of normals it bounds
--- the shape over, which is exactly the record the rest of this file reads.
---
--- A DISC CAN APPEAR TWICE, which is why this is a walk and not a sort: a big disc
--- between two small far ones bounds the shape on both sides of them. And a disc
--- inside another -- or on it, to HULL_EPS -- has no tangent to it at all, so it is
--- skipped as a candidate rather than divided by nothing. That is what makes a
--- disc list with duplicates in it (a split, the moment it opens) cost nothing.
---
--- EXACT: its support function matched a brute-force maximum over the discs to
--- zero on three thousand random disc sets. The ranges climb through one whole turn
--- and each corner's last angle IS the next one's first -- the same double -- so the
--- chain closes to the bit.
--- @param discs table   { { x, y, r }, ... }
--- @return table|nil ks
local function discHull(discs)
    local m = #discs
    if m == 0 then return nil end
    local s, best = 1, -huge
    for i = 1, m do
        local d = discs[i]
        local v = d.x + d.r
        if v > best + HULL_EPS or (abs(v - best) <= HULL_EPS and d.r > discs[s].r) then
            s, best = i, v
        end
    end

    -- FLAT ARRAYS FOR THE WALK, because it is m candidates at every corner of a hull
    -- built every frame of a sweep, and three field lookups a candidate were most of
    -- its cost. The arithmetic is the same arithmetic on the same numbers.
    local xs, ys, rs = {}, {}, {}
    for k = 1, m do
        local d = discs[k]
        xs[k], ys[k], rs[k] = d.x, d.y, d.r
    end

    local seq = {}
    local i, th, closed = s, 0.0, false
    for _ = 1, 2 * m + 2 do
        local xi, yi, ri = xs[i], ys[i], rs[i]
        local nj, nadv, nL = nil, huge, -1.0
        for j = 1, m do
            if j ~= i then
                local dx, dy = xs[j] - xi, ys[j] - yi
                local L = sqrt(dx * dx + dy * dy)
                local dr = ri - rs[j]
                if L > abs(dr) + HULL_EPS then
                    local phi = atan(dy, dx) - acos(dr / L)
                    local adv = (phi - th) % TAU
                    -- A HAIR BEHIND IS NOW, not nearly a whole turn on: the only
                    -- disc that can be found there is one tied with this one.
                    if adv > TAU - 1e-10 then adv = 0.0 end
                    -- TIES GO TO THE FURTHER DISC, so three collinear points make one
                    -- run and not a corner that turns by nothing.
                    if adv < nadv - 1e-12 or (abs(adv - nadv) <= 1e-12 and L > nL) then
                        nj, nadv, nL = j, adv, L
                    end
                end
            end
        end
        if not nj or th + nadv >= TAU - 1e-10 then
            seq[#seq + 1] = { i, th, TAU }
            closed = true
            break
        end
        seq[#seq + 1] = { i, th, th + nadv }
        th = th + nadv
        i = nj
    end
    -- A WALK THAT RAN OUT OF STEPS STILL CLOSES: the last corner is carried round to
    -- the start. Not reachable on a proper disc set (a hull has at most 2m - 1
    -- corners); here so that no rounding can hand back a boundary with a gap in it.
    if not closed then seq[#seq][3] = TAU end

    -- THE DISC THE WALK STARTED ON IS USUALLY ALSO WHERE IT ENDS, straddling normal
    -- angle 0 -- one corner, begun a turn early.
    if #seq > 1 and seq[#seq][1] == seq[1][1] then
        seq[1][2] = seq[#seq][2] - TAU
        seq[#seq] = nil
    end

    local ks = {}
    for k = 1, #seq do
        local e = seq[k]
        if e[3] - e[2] > ANGLE_EPS or #seq == 1 then
            local d = discs[e[1]]
            ks[#ks + 1] = corner(d.x, d.y, d.r, e[2], e[3])
        end
    end
    if #ks == 1 then
        local c = ks[1]
        ks[1] = corner(c.x, c.y, c.rho, 0.0, TAU)
    end
    return ks
end

--- Which corner of a list carries normal angle `a`. The ranges tile one whole turn.
local function cornerAt(ks, a)
    for i = 1, #ks do
        local k = ks[i]
        if ((a - k.a0) % TAU) <= (k.a1 - k.a0) then return k end
    end
    return ks[#ks]
end

--- The support function of a corner list at normal angle `a`.
local function supportAt(ks, a)
    local k = cornerAt(ks, a)
    return k.x * cos(a) + k.y * sin(a) + k.rho
end

--- The longest length and the narrowest width of a corner list. EXACT.
---
--- The width across normal u is h(u) + h(u + pi). Between two breakpoints of that
--- pair -- every corner end, and every corner end turned half a turn -- one corner
--- bounds each side, so the width there is |c_a - c_b| cos(u - phi) plus the two
--- radii, and both corners bounding opposite sides forces cos to be non-negative
--- there. So the MINIMUM is at a breakpoint and the MAXIMUM is at a breakpoint or
--- where u points along c_a - c_b. The diameter of a convex body is its widest
--- width, which is what "longest length" means.
--- @return number longest, number narrowest
local function widthOf(ks)
    if #ks == 1 then
        local d = 2.0 * ks[1].rho
        return d, d
    end
    local bps = {}
    for i = 1, #ks do
        bps[#bps + 1] = ks[i].a1 % TAU
        bps[#bps + 1] = (ks[i].a1 + pi) % TAU
    end
    table.sort(bps)
    local D, W = 0.0, huge
    local function w(a) return supportAt(ks, a) + supportAt(ks, a + pi) end
    for j = 1, #bps do
        local lo = bps[j]
        local hi = (j < #bps) and bps[j + 1] or (bps[1] + TAU)
        local wl = w(lo)
        if wl < W then W = wl end
        if wl > D then D = wl end
        if hi - lo > ANGLE_EPS then
            local mid = 0.5 * (lo + hi)
            local a, b = cornerAt(ks, mid), cornerAt(ks, mid + pi)
            local off = (atan(a.y - b.y, a.x - b.x) - lo) % TAU
            if off < hi - lo then
                local wm = w(lo + off)
                if wm > D then D = wm end
            end
        end
    end
    return D, W
end

--- How stretched a corner list is: its longest length over its narrowest width.
--- 1 for a disc, and for a point, which has neither.
local function stretchOf(ks)
    local D, W = widthOf(ks)
    if not (W > 0.0) then return 1.0, D, W end
    return D / W, D, W
end

--- How far every disc of a list pokes OUT of a convex corner list, at the worst.
---
--- The discs are scaled by `k` about the origin and moved to (ox, oy) first, which
--- is both of the questions this file asks: does a zone fit inside its predecessor
--- concentric at the ratio of their radii, and does the next zone fit inside this
--- one at a candidate centre. Positive is out; the shape the discs are the hull of
--- is inside exactly when this is not.
--- @return number metres (or units)
local function fitOf(ks, discs, ox, oy, k)
    local h = { ks = ks }
    k = k or 1.0
    local worst = -huge
    for i = 1, #discs do
        local d = discs[i]
        local v = hullDistance(h, (ox or 0.0) + d.x * k, (oy or 0.0) + d.y * k) + d.r * k
        if v > worst then worst = v end
    end
    return worst
end

-- ------------------------------------------------------------ the zone units ---

--- The area-weighted centroid of a vertex ring.
local function centroidOf(vs)
    local A, cx, cy = 0.0, 0.0, 0.0
    local n = #vs
    for i = 1, n do
        local p, q = vs[i], vs[(i % n) + 1]
        local cr = p.x * q.y - q.x * p.y
        A = A + cr
        cx = cx + (p.x + q.x) * cr
        cy = cy + (p.y + q.y) * cr
    end
    A = A * 0.5
    if A == 0.0 then return 0.0, 0.0 end
    return cx / (6.0 * A), cy / (6.0 * A)
end

--- A convex vertex ring, finished vertex by vertex, as DISCS.
---
--- nil when the ring is not convex -- a turn outside [BLOB_MIN_TURN,
--- pi - BLOB_MIN_TURN] at any vertex. Otherwise the flat disc list and, per vertex,
--- the record the morph pairs by: its outward-normal bisector `beta` and the one or
--- two discs it is.
---
--- ═══ ONE CUT PER VERTEX, AND IT IS THE SAME FOR A BEVEL AND AN ARC ═══
---
--- `take` is how far back along each edge the finish starts: `cut` of the shorter
--- half-edge beside the vertex, so no two neighbours can meet in the middle of the
--- run they share. A ROUNDED vertex is the disc tangent to both edges at exactly
--- those two points -- or smaller, see RHO_FIT -- and a BEVELED one is the two
--- points themselves. The chamfer between them is square to the vertex's bisector,
--- so the two sharp corners at its ends split that vertex's turn equally.
---
--- THE CAP IS CLOSED FORM. A disc tangent to both edges has its centre on the
--- inward bisector b at rho / sin(half the interior angle), so its signed distance
--- to another edge's line (inward normal n_k, vertex V at depth dist_k from it) is
--- dist_k + rho <b, n_k> / sin(half) -- and it clears that line while that is at
--- least rho, which is rho <= dist_k / (1 - <b, n_k> / sin(half)).
--- @param vs table       vertices, counter-clockwise
--- @param finish table   one of VERTEX_KINDS per vertex
--- @param cut number     0..1
--- @return table|nil discs, table|nil verts
local function finishDiscs(vs, finish, cut)
    local n = #vs
    local E = {}
    for i = 1, n do
        local a, b = vs[i], vs[(i % n) + 1]
        local dx, dy = b.x - a.x, b.y - a.y
        local len = sqrt(dx * dx + dy * dy)
        if len <= 0.0 then return nil end
        -- Inward is the LEFT of travel on a counter-clockwise ring.
        E[i] = { ux = dx / len, uy = dy / len, len = len,
                 nx = -dy / len, ny = dx / len, x = a.x, y = a.y }
    end
    local turns = {}
    for i = 1, n do
        local p, c = E[((i - 2) % n) + 1], E[i]
        local t = atan(p.ux * c.uy - p.uy * c.ux, p.ux * c.ux + p.uy * c.uy)
        if t < BLOB_MIN_TURN or t > pi - BLOB_MIN_TURN then return nil end
        turns[i] = t
    end

    local discs, verts = {}, {}
    for i = 1, n do
        local ip = ((i - 2) % n) + 1
        local p, c, V = E[ip], E[i], vs[i]
        local take = cut * 0.5 * ((p.len < c.len) and p.len or c.len)
        local how = finish[i]
        -- The OUTWARD normal half way round the vertex's turn: the two edges'
        -- outward normals, summed.
        local beta = atan(-(p.ny + c.ny), -(p.nx + c.nx))
        local set
        if how == 'cornered' then
            set = { { x = V.x, y = V.y, r = 0.0 } }
        elseif how == 'beveled' then
            set = { { x = V.x - p.ux * take, y = V.y - p.uy * take, r = 0.0 },
                    { x = V.x + c.ux * take, y = V.y + c.uy * take, r = 0.0 } }
        else
            local half = 0.5 * (pi - turns[i])
            local sh = sin(half)
            local bx, by = c.ux - p.ux, c.uy - p.uy
            local bl = sqrt(bx * bx + by * by)
            if bl <= 0.0 then return nil end
            bx, by = bx / bl, by / bl
            local rho = take * math.tan(half)
            for k = 1, n do
                if k ~= i and k ~= ip then
                    local e = E[k]
                    local dist = (V.x - e.x) * e.nx + (V.y - e.y) * e.ny
                    local lean = 1.0 - (bx * e.nx + by * e.ny) / sh
                    if lean > 1e-12 then
                        local lim = RHO_FIT * dist / lean
                        if lim < rho then rho = lim end
                    end
                end
            end
            if not (rho > 0.0) then rho = 0.0 end
            local d = rho / sh
            set = { { x = V.x + bx * d, y = V.y + by * d, r = rho } }
        end
        verts[i] = { beta = beta, discs = set, finish = how }
        for q = 1, #set do discs[#discs + 1] = set[q] end
    end
    return discs, verts
end

--- A finished ring as a unit's geometry -- its discs, its vertices and the corner
--- list of their hull -- scaled to hold exactly `area` of the unit circle. nil when
--- the ring is not convex.
---
--- ═══ SCALED TO `area` OF THE CIRCLE, EXACTLY ═══
---
--- Scaling every centre and every radius by one factor scales the area by its
--- square and leaves every normal where it was, so the hull stays the corner list
--- it was -- nothing the section header claims exact stops being so. The discs are
--- scaled in place and the corner list alongside them, rather than hulled a second
--- time.
local function coreOf(vs, finish, cut, area)
    local discs, verts = finishDiscs(vs, finish, cut)
    if not discs then return nil end
    local ks = discHull(discs)
    local a = ks and areaOf(ks) or 0.0
    if not (a > 0.0) then return nil end
    local f = sqrt(area * pi / a)
    for i = 1, #discs do
        local d = discs[i]
        d.x, d.y, d.r = d.x * f, d.y * f, d.r * f
    end
    for i = 1, #ks do
        local c = ks[i]
        ks[i] = corner(c.x * f, c.y * f, c.rho * f, c.a0, c.a1, c.c0, c.s0, c.c1, c.s1)
    end
    return { ks = ks, discs = discs, verts = verts }
end

--- A vertex ring stretched by `a` along the axis at angle `psi` and squeezed by `a`
--- across it -- which keeps its area -- and moved so its own centroid is the origin.
---
--- THE CENTROID IS THE ZONE'S CENTRE from here on: the point the solver's circle is
--- centred on, the point the next zone is placed relative to, and the point #350's
--- map fill scales about. A convex shape's centroid is at least a third of the way
--- in along every chord through it, and MEASURED over the shipping draw it is never
--- less than 0.41 r deep.
local function stretchedRing(base, a, psi)
    local c, s = cos(psi), sin(psi)
    local vs = {}
    for i = 1, #base do
        local bx, by = base[i].x, base[i].y
        local x, y = bx * c + by * s, -bx * s + by * c
        x, y = x * a, y / a
        vs[i] = { x = x * c - y * s, y = x * s + y * c }
    end
    local gx, gy = centroidOf(vs)
    for i = 1, #vs do vs[i].x, vs[i].y = vs[i].x - gx, vs[i].y - gy end
    return vs
end

--- The most stretched version of a ring along `psi` that is no more than `S`.
---
--- A FIXED BISECTION, and every build inside it is the whole finish-hull-scale
--- pipeline, so the stretch measured is the stretch of the shape that ships -- the
--- finishes and the area scaling move it, and a stretch computed off the bare ring
--- would not know. A stretch that makes a corner too sharp to be a vertex is read
--- as too far, which is what stops a long triangle short of the cap.
local function solveStretch(base, psi, finish, cut, area, S)
    local best = coreOf(stretchedRing(base, 1.0, psi), finish, cut, area)
    if not best then return nil end
    local s1 = stretchOf(best.ks)
    if s1 >= S then return best end
    local lo, hi = 1.0, 2.0 * sqrt(S / s1) + 1.0
    for _ = 1, STRETCH_STEPS do
        local mid = 0.5 * (lo + hi)
        local u = coreOf(stretchedRing(base, mid, psi), finish, cut, area)
        if u and stretchOf(u.ks) <= S then lo, best = mid, u else hi = mid end
    end
    return best
end

--- A unit's geometry turned by `ang` about its centre. Fresh discs, vertices that
--- name the fresh discs, and the hull of them.
local function turnedCore(u, ang)
    if ang == 0.0 then return u end
    local c, s = cos(ang), sin(ang)
    local discs, map = {}, {}
    for i = 1, #u.discs do
        local d = u.discs[i]
        local nd = { x = d.x * c - d.y * s, y = d.x * s + d.y * c, r = d.r }
        discs[i] = nd
        map[d] = nd
    end
    local verts = {}
    for i = 1, #u.verts do
        local v = u.verts[i]
        local set = {}
        for j = 1, #v.discs do set[j] = map[v.discs[j]] end
        verts[i] = { beta = v.beta + ang, discs = set, finish = v.finish }
    end
    return { ks = discHull(discs), discs = discs, verts = verts }
end

--- The geometry of a plain circle of radius `rho`: one disc, one vertex.
local function circleCore(rho)
    local d = { x = 0.0, y = 0.0, r = rho }
    return { ks = { corner(0.0, 0.0, rho, 0.0, TAU) }, discs = { d },
             verts = { { beta = 0.0, discs = { d } } } }
end

--- ZONE 0, THE OPENING ZONE, IS THE MAP DISC -- EXACTLY THE CIRCLE, AT ITS WHOLE AREA.
---
--- The opening radius is computed per match to reach past the farthest corner of
--- the playable map (server/storm.lua's openingRadius), so a DISC of that radius is
--- the one opening zone nobody can land outside of, and its hold-time wall is a
--- clean ring just past the map's corner. A drawn shape there would either leave
--- corners of the map outside the storm or have to be grown until it covered them
--- -- up to twice the radius, and a phase-1 sweep that long. Not scaled to `area`:
--- the opening zone is not a phase circle a pace was tuned on, it is the map.
local OPENING = circleCore(1.0)
OPENING.kind, OPENING.opening = 'circle', true
OPENING.n, OPENING.finish, OPENING.jitter, OPENING.tries = 0, {}, 0.0, 1
OPENING.stretch, OPENING.D, OPENING.W = 1.0, 2.0, 2.0
OPENING.extent, OPENING.inradius, OPENING.area = 1.0, 1.0, 1.0
OPENING.rung, OPENING.turned, OPENING.homothet = 0, 0, false

-- ═══ THE UNITS ARE MEMOISED, AND THE CACHE IS BOUNDED ═══
--
-- Every frame of the wall, every tick of the HUD and every tick of the server's
-- damage pass ask for the SAME two units -- the zone the wall is leaving and the
-- zone it is closing on -- and a unit is a stretch solve, a hull per step and a fit
-- ladder: two milliseconds on average and thirteen at worst, measured. Built once.
--
-- ═══ AND THE KNOBS ARE READ ONCE PER CONFIG, NOT ONCE PER CALL ═══
--
-- The knobs are read into a SPEC once per options table and the units hang off it
-- by chain, seed and zone. Each call checks that the knobs the spec was read from
-- are still the knobs there -- a few dozen comparisons and no strings -- so a config
-- edited between two calls, in place or by swapping a table in, is still never
-- served a stale shape. The CHAIN is the phase table the zones were fitted to, and
-- its radii are checked the same way: zone z's shape depends on zone z-1's and on
-- the ratio of their radii, so a retuned radius is a different chain.
--
-- FLUSHED WHOLE RATHER THAN EVICTED, AND THE GENERATION BEFORE IS KEPT. A server
-- runs matches for days and each one brings a fresh seed, so an unbounded cache is a
-- slow leak: at a ceiling the whole cache becomes the OLD generation and a fresh one
-- starts, and a unit asked for from the old one is promoted back rather than
-- rebuilt -- so the live matches' zones survive a flush as the same tables, and only
-- the matches that are over are dropped, one flush later. It cannot grow past twice
-- the ceiling.
--
-- THE CEILING IS 256 UNITS, THIRTY-TWO MATCHES OF EIGHT ZONES. It was 64 while a
-- unit cost fifty microseconds; one costs about two milliseconds now, and zone z
-- cannot be built without zone z-1, so a server running more matches at once than
-- the cache held rebuilt whole chains on every damage tick -- measured, a suite of
-- 72 concurrent matches ran nine times slower until this changed. The specs are
-- held weakly, by the options table they read.
local specs = setmetatable({}, { __mode = 'k' })
local blobGen, blobCacheN = 0, 0
local BLOB_CACHE_MAX = 256
local NO_CHAIN = {}

--- HOW MANY UNITS AND PAIRINGS HAVE ACTUALLY BEEN BUILT since this file loaded.
---
--- A COUNT AND NOT A FLAG, and it exists for one claim: that a zone's shape is
--- built ONCE and the corner pairing between two zones is built ONCE, however many
--- frames and ticks ask for them. A cache that silently stopped hitting would still
--- hand back correct shapes -- identical ones, rebuilt -- so nothing a shape can be
--- asked would show it. tools/test_storm.lua runs a sweep and reads these.
BR.StormShape.builds = { units = 0, pairings = 0 }

--- The knobs of one options table, read: the counts on offer and their weights,
--- the finishes and theirs, and the scalars -- and the RAW values they were read
--- from, which is what specStill compares. nil `counts` is the off switch.
local function readSpec(opts)
    local sp = { chains = setmetatable({}, { __mode = 'k' }), gen = blobGen,
                 w = {}, v = {},
                 rawCorners = opts.corners, rawVertex = opts.vertex,
                 rawCircle = opts.circle, rawJitter = opts.jitter,
                 rawSlide = opts.slideDeg, rawCut = opts.cut,
                 rawArea = opts.area, rawStretch = opts.stretch,
                 rawDraw = opts.stretchDraw, rawClear = opts.fitClear }

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
        if c > BLOB_MAX_CORNERS then c = BLOB_MAX_CORNERS end
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
    local cap = tonumber(opts.stretch) or 3.0
    if cap < 1.0 then cap = 1.0 end
    sp.stretch = cap
    sp.sqrtDraw = opts.stretchDraw == 'sqrt'
    sp.clear  = tonumber(opts.fitClear) or 0.0
    return sp
end

--- Are these still the knobs `sp` was read from? Every field the reading looked
--- at, compared as it was found -- the weight tables entry by entry, so an edit in
--- place is caught as surely as a table swapped for another.
local function specStill(sp, opts)
    if opts.corners ~= sp.rawCorners or opts.vertex ~= sp.rawVertex
        or opts.circle ~= sp.rawCircle or opts.jitter ~= sp.rawJitter
        or opts.slideDeg ~= sp.rawSlide or opts.cut ~= sp.rawCut
        or opts.area ~= sp.rawArea or opts.stretch ~= sp.rawStretch
        or opts.stretchDraw ~= sp.rawDraw or opts.fitClear ~= sp.rawClear then
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

--- The unit table of one chain of one spec: the zones fitted to one phase table's
--- radii, or to none. A chain whose radii have changed since it was built is
--- dropped rather than served.
local function chainOf(chains, phases)
    local ch = chains and chains[phases or NO_CHAIN]
    if ch and phases then
        if #phases ~= #ch.radii then return nil end
        for i = 1, #phases do
            if (phases[i] and tonumber(phases[i].radius)) ~= ch.radii[i] then
                return nil
            end
        end
    end
    return ch
end

--- @return table units   this generation's, by seed then zone
--- @return table|nil older  the generation before's, for promotion
local function unitsFor(sp, phases)
    if sp.gen ~= blobGen then
        sp.oldChains = (sp.gen == blobGen - 1) and sp.chains or nil
        sp.chains, sp.gen = setmetatable({}, { __mode = 'k' }), blobGen
    end
    local ch = chainOf(sp.chains, phases)
    if not ch then
        ch = { radii = {}, units = {} }
        if phases then
            for i = 1, #phases do
                ch.radii[i] = phases[i] and tonumber(phases[i].radius)
            end
        end
        sp.chains[phases or NO_CHAIN] = ch
    end
    local old = chainOf(sp.oldChains, phases)
    return ch.units, old and old.units
end

--- Put a unit in this generation, flushing first if the ceiling has been reached.
local function remember(sp, phases, s, z, unit)
    if blobCacheN >= BLOB_CACHE_MAX then
        blobGen, blobCacheN = blobGen + 1, 0
    end
    local units = unitsFor(sp, phases)
    local bySeed = units[s]
    if not bySeed then
        bySeed = {}
        units[s] = bySeed
    end
    bySeed[z] = unit
    blobCacheN = blobCacheN + 1
end

--- Draw one zone. See blobUnit, which is the only caller and carries the argument.
--- @param parent table|nil   zone z-1's unit, when zone z must fit inside it
--- @param k number|nil       zone z's radius over zone z-1's
local function drawUnit(sp, s, z, parent, k)
    local rng = BR.Rng(s * 1000003 + z * 7919 + 17)

    -- ═══ 317 VALUES, ALWAYS, IN THIS ORDER, BEFORE ANYTHING IS DECIDED ═══
    local isCircle = rng:float() < sp.chance
    local roll = rng:float() * sp.total
    local phi = rng:float() * TAU
    local psi = rng:float() * TAU
    local u = rng:float()
    local fin = {}
    for i = 1, BLOB_MAX_CORNERS do
        local v = rng:float() * sp.ktotal
        fin[i] = sp.kinds[#sp.kinds]
        for j = 1, #sp.kinds do
            v = v - sp.kw[j]
            if v < 0.0 then fin[i] = sp.kinds[j] break end
        end
    end
    local jit = {}
    for a = 1, BLOB_TRIES do
        local row = {}
        for i = 1, 2 * BLOB_MAX_CORNERS do row[i] = rng:float() end
        jit[a] = row
    end

    local counts, weights = sp.counts, sp.weights
    local n = counts[#counts]
    for i = 1, #counts do
        roll = roll - weights[i]
        if roll < 0.0 then n = counts[i] break end
    end
    local finish = {}
    for i = 1, n do finish[i] = fin[i] end
    local S = 1.0 + (sp.stretch - 1.0) * (sp.sqrtDraw and sqrt(u) or u)
    local clear = sp.clear
    local info = { rung = 0, turned = 0, homothet = false, circleLost = false }

    --- The first rotation that fits `core` inside the parent, and which it was.
    local function fitted(core)
        if not parent then return core, 0 end
        for j = 0, 2 * FIT_TURNS - 1 do
            local step = (j == 0) and 0
                or (((j % 2 == 1) and 1 or -1) * math.ceil(j / 2))
            local turned = turnedCore(core, step * FIT_TURN)
            if fitOf(parent.ks, turned.discs, 0.0, 0.0, k) <= -clear then
                return turned, step
            end
        end
        return nil
    end

    local core, kind, jitterUsed, tries = nil, 'polygon', 0.0, 1
    if isCircle then
        core = circleCore(sqrt(sp.area))
        kind = 'circle'
        -- A CIRCLE THAT CANNOT FIT ITS PARENT IS DRAWN AS A POLYGON, off values the
        -- stream has already handed out: a round zone of the right area does not fit
        -- inside a long one, and the chain is what the placement rests on.
        if parent and fitOf(parent.ks, core.discs, 0.0, 0.0, k) > -clear then
            core, kind, info.circleLost = nil, 'polygon', true
        end
    end

    if not core then
        -- THE BASE RING: the first attempt that is convex. The last one has no
        -- jitter at all, which is a regular polygon, so this always finds one.
        local slot = TAU / n
        local base
        for a = 1, BLOB_TRIES do
            local vs = {}
            local j, sl = 0.0, 0.0
            if a < BLOB_TRIES then
                local fall = BLOB_FALLOFF ^ (a - 1)
                j = sp.jitter * fall
                sl = ((sp.slide < slot * BLOB_SLIDE_SLOT) and sp.slide
                      or slot * BLOB_SLIDE_SLOT) * fall
            end
            local row = jit[a]
            for i = 1, n do
                -- THE ANGLE STAYS IN ITS OWN SLOT, which is what stops two vertices
                -- swapping places, and THE WHOLE RING IS TURNED by one drawn angle, so
                -- that vertex one of every shape does not sit due east.
                local ang = phi + (i - 1) * slot + sl * (row[2 * i - 1] * 2.0 - 1.0)
                -- SYMMETRIC ABOUT 1, NOT INWARD FROM IT (#344, measured).
                local rad = 1.0 + j * (row[2 * i] * 2.0 - 1.0)
                vs[i] = { x = cos(ang) * rad, y = sin(ang) * rad }
            end
            if coreOf(stretchedRing(vs, 1.0, psi), finish, sp.cut, sp.area) then
                base, jitterUsed, tries = vs, j, a
                break
            end
        end

        -- THE LADDER. The drawn stretch first, then half way to the parent's own,
        -- the parent's, half the drawn one, and none -- and at each, every turn.
        local rungs = { S }
        if parent then
            local ps = parent.stretch or 1.0
            rungs = { S, 0.5 * (S + ps), ps, 1.0 + 0.5 * (S - 1.0), 1.0 }
        end
        for r = 1, #rungs do
            local want = rungs[r]
            if want > sp.stretch then want = sp.stretch end
            local solved = solveStretch(base, psi, finish, sp.cut, sp.area, want)
            if solved then
                local got, step = fitted(solved)
                if got then
                    core, info.rung, info.turned = got, r - 1, step
                    break
                end
            end
        end
    end

    -- ═══ THE LAST RESORT IS THE PARENT'S OWN SHAPE, AND IT ALWAYS FITS ═══
    --
    -- Scaled by k < 1 about its own centre it sits inside itself with (1 - k) of its
    -- centre's depth to spare -- over a tenth of r at every shipping ratio against a
    -- fitClear of a twenty-fifth -- and its area scales by k squared, which is
    -- exactly the next phase's area. MEASURED: 2.5 percent of zone 2s, 1 of zone 3s,
    -- and nothing past zone 4.
    local n2, finish2 = n, finish
    if not core and not parent then
        -- Not reachable: with no parent the first rung is always taken. Here so that
        -- a config this file has not met draws a circle rather than indexing nil.
        core, kind = circleCore(sqrt(sp.area)), 'circle'
    end
    if not core then
        core = { ks = parent.ks, discs = parent.discs, verts = parent.verts }
        kind, n2, finish2 = parent.kind, parent.n, parent.finish
        info.homothet = true
    end

    local ks = core.ks
    local st, D, W = stretchOf(ks)
    return {
        kind = kind, n = (kind == 'circle') and 0 or n2,
        ks = ks, discs = core.discs, verts = core.verts,
        finish = (kind == 'circle') and {} or finish2,
        jitter = jitterUsed, tries = tries,
        stretch = st, D = D, W = W, target = S,
        rung = info.rung, turned = info.turned,
        homothet = info.homothet, circleLost = info.circleLost,
        -- WHAT THE SHAPE MEASURES, normalised, read back off the corners rather than
        -- copied from the knobs, so a scaling that went wrong would show here.
        extent = reachOf(ks, 0.0, 0.0),
        inradius = -hullDistance({ ks = ks }, 0.0, 0.0),
        area = areaOf(ks) / pi,
        seed = s, zone = z,
    }
end

--- THE UNIT SHAPE of one zone of one match: centred on the origin, holding `area`
--- of the unit circle, to be scaled by whatever radius the solver reports.
---
--- ═══ KEYED ON THE ZONE, NOT ON THE PHASE THAT IS DRAWING IT ═══
---
--- Zone k is the zone phase k closes on -- zone 0 is the opening zone -- and it is
--- on screen for two phases: as phase k's TARGET, and then as phase k+1's CURRENT
--- zone until that phase's sweep carries it away. It keeps this one shape for the
--- whole of that. Asked by the phase that happened to be drawing it, the answer
--- changed under a wall standing still, which is the snap the owner reported: "after
--- the storm is finished moving for that phase, the border snaps to a different
--- location." BR.StormZone is where the two zones of a record are named.
---
--- ═══ EVERY ZONE DRAWS THE SAME 317 VALUES, WHATEVER THEY DECIDE ═══
---
--- Off BR.Rng(seed * 1000003 + zone * 7919 + 17), in this order and ALL OF THEM
--- ALWAYS TAKEN: the circle roll, the count roll, the ring's turn, the stretch axis,
--- the stretch, one finish per possible vertex (BLOB_MAX_CORNERS of them, vertex i
--- reading roll i), and a slide and a radius per possible vertex for every attempt.
--- So everything sits at the same place in the stream however the config is
--- spelled -- `9` and `{ [9] = 1 }` are the same shape, a zone that is a polygon at
--- a circle chance of 0.1 is the SAME polygon at 0.2, and a retuned count never
--- re-finishes a vertex -- and every retry, every rung and every turn below reads a
--- value already drawn, so the client and the server reject the same attempt at the
--- same step.
---
--- ═══ BUILT BY AREA ═══
---
--- A ring of `n` vertices jittered about the unit circle, turned by the drawn angle,
--- STRETCHED along the drawn axis to a drawn target -- uniform across [1, stretch]
--- -- by the area-preserving affine map that gets closest to it without passing it,
--- finished into discs, hulled, and scaled to `area`. See the section header.
---
--- ═══ CHAINED: ZONE z FITS INSIDE ZONE z-1 WHERE THE SOLVER PUTS IT ═══
---
---   "the circles still overlap when they are different shapes."
---                                                    -- the owner, 2026-09-23
---
--- With `phases`, zone z (z >= 2) must fit CONCENTRIC inside zone z-1 at the ratio
--- of their radii, every disc at least `fitClear` of r inside: exactly, by fitOf.
--- That is what guarantees BR.NextZoneCentre a nested place for zone z inside zone
--- z-1 however long and however turned both are -- the concentric one, with room
--- around it. A draw that does not fit is turned, then tamed down the ladder in
--- drawUnit, and the last resort is zone z-1's own shape. Zone 1 is unconstrained,
--- because zone 0 is the map disc and every zone 1 fits inside it.
---
--- SO ZONE z DEPENDS ON ZONE z-1, AND ON THE RATIO OF THEIR RADII. Both sides
--- derive the chain from the same seed, so they still agree; what changes is that
--- retuning one phase radius can reshape every later zone of a match.
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
--- `circle` is not the off switch -- a chance of 1 draws every zone as a circle.
---
--- @param seed number|nil     the match's storm seed (server/storm.lua's seedRng)
--- @param zone number|nil     0 is the opening zone, k the zone phase k closes on
--- @param opts table|nil      config/storm.lua's `shape` block
--- @param phases table|nil    config/storm.lua's `phases`, for the chain; nil for none
--- @return table|nil unit     { kind, n, ks, discs, verts, finish, stretch, extent,
---                              inradius, area, tries, ... }
function BR.StormShape.blobUnit(seed, zone, opts, phases)
    opts = opts or NO_OPTS
    local sp = specs[opts]
    if not sp or not specStill(sp, opts) then
        sp = readSpec(opts)
        specs[opts] = sp
    end
    if not sp.counts then return nil end

    local z = math.tointeger(math.floor(zone or 0)) or 0
    if z <= 0 then return OPENING end
    local s = math.tointeger(math.floor(seed or 0)) or 0

    local units, older = unitsFor(sp, phases)
    local bySeed = units[s]
    local hit = bySeed and bySeed[z]
    if hit then return hit end
    -- STILL IN USE ACROSS A FLUSH: the same table, promoted, not a copy rebuilt.
    local was = older and older[s] and older[s][z]
    if was then
        remember(sp, phases, s, z, was)
        return was
    end

    local parent, k = nil, nil
    if phases and z >= 2 then
        local p0, p1 = phases[z - 1], phases[z]
        local r0 = p0 and tonumber(p0.radius)
        local r1 = p1 and tonumber(p1.radius)
        if r0 and r1 and r0 > 0.0 and r1 >= 0.0 then
            parent = BR.StormShape.blobUnit(s, z - 1, opts, phases)
            k = r1 / r0
        end
    end

    local unit = drawUnit(sp, s, z, parent, k)
    remember(sp, phases, s, z, unit)
    BR.StormShape.builds.units = BR.StormShape.builds.units + 1
    return unit
end

--- Is this zone's unit already built? Asked WITHOUT building it or promoting it, so
--- a caller spreading the builds out -- client/storm.lua derives one zone per tick
--- ahead of need -- can tell a cache hit from the two milliseconds a build costs.
--- The same arguments as blobUnit, and the same answer for zone 0 and the off switch.
--- @return boolean
function BR.StormShape.blobUnitReady(seed, zone, opts, phases)
    opts = opts or NO_OPTS
    local sp = specs[opts]
    if not sp or not specStill(sp, opts) or sp.gen ~= blobGen then return false end
    if not sp.counts then return true end
    local z = math.tointeger(math.floor(zone or 0)) or 0
    if z <= 0 then return true end
    local s = math.tointeger(math.floor(seed or 0)) or 0
    local ch = chainOf(sp.chains, phases)
    local bySeed = ch and ch.units[s]
    return (bySeed and bySeed[z]) ~= nil
end

-- ═══ THE MORPH: ONE ZONE'S SHAPE BECOMING THE NEXT ONE'S, CORNER TO CORNER ═══
--
--   "I don't think blending is right here - it still doesn't do what I want. I
--    think morphing is the correct action for it."
--   "I don't want the destinations shape or corners to change at all. I want the
--    moving wall's corners and lines to move and change to match the
--    destination's. Nothing about the destination shape should ever change while
--    in motion."                                      -- the owner, 2026-09-23
--
-- What shipped before this was the Minkowski combination (1 - t) A + t B, whose
-- corner list is BOTH lists merged: the old sides shrink away while the new ones
-- grow in, so the wall wore two shapes at once, n + m sides mid-sweep. That is the
-- look he rejected.
--
-- ═══ SO EVERY CORNER OF THE WALL IS PAIRED WITH A CORNER OF THE DESTINATION ═══
--
-- Each vertex of the zone the wall leaves is linked to a vertex of the zone it
-- closes on (pairsOf), and each disc of it travels in a straight line to its
-- partner's disc -- centre and radius both -- across the sweep. The wall at sweep
-- fraction t is the convex hull of where the discs are. So its corners go to the
-- destination's corners, its runs turn and lengthen into the destination's runs,
-- and each corner's finish becomes its partner's: a rounded corner heading for a
-- sharp one loses its radius, a chamfer's two ends close onto a point or open out
-- of one. max(n, m) links, never n + m.
--
-- ═══ AND THE DESTINATION IS NEVER TOUCHED ═══
--
-- On a phase whose next zone lies inside this one -- every phase that did not
-- break out, now that zones are placed by their real shape -- the destination's
-- own discs are added to the hull (morph()). Three things follow:
--
--   THE WALL NEVER CUTS INTO THE DESTINATION. It is a hull containing it.
--
--   THE WALL NEVER MOVES OUTWARD. A moving disc at t2 is a blend of where it was
--   at t1 and its partner, which is a disc of the destination, so it lies inside
--   the hull at t1 -- and so does the whole wall at t2. Airdrop and rescue siting
--   lean on this: see storm_solve.lua.
--
--   WHERE THE BARE CORNER PATHS WOULD HAVE CUT IN, THE WALL RESTS ON THE
--   DESTINATION instead -- the owner's own first suggestion, "at any point where it
--   intersects with the inside circle, that part of it stops moving". MEASURED, in
--   36 to 64 percent of nested sweeps, on 14 to 32 percent of frames.
--
-- IT IS CONVEX AT EVERY t, because it is a hull. Its signed distance and its
-- erosion are the corner list's, exact -- measured to 4e-12 m at ninety thousand
-- points outside moving walls of every phase. And it starts and ends on the zones
-- themselves: BR.StormZone hands back the placed zones at t = 0 and t = 1, so the
-- hand-off at a phase change is one shape to the bit.
--
-- A BREAKOUT MORPHS THE SAME WAY, WITHOUT THE DESTINATION IN THE HULL: the zone is
-- the moving wall UNION the destination, stitched by blobUnion as it always was.

--- Pairings are cached per PAIR of units, weakly, so a flushed unit takes its
--- pairings with it and a pairing is built once per phase rather than once per frame.
local pairCache = setmetatable({}, { __mode = 'k' })

--- The angle from b to a, wrapped into [-pi, pi).
local function adiff(a, b)
    return ((a - b + pi) % TAU) - pi
end

--- A CYCLIC MONOTONE MAP of every angle in `big` onto one in `small`: each of
--- `small` is hit at least once, in order round the circle, and the sum of the
--- squared angular differences is the least it can be.
---
--- A dynamic programme over (big index, how far round small it has got) for every
--- place `small` can start, so it is O(n^2 m) -- at most a few thousand cells for
--- two twelve-sided zones, once per phase. The last big may land back on the small
--- the first one did, which is a split across the seam.
---
--- STRICT TIE-BREAKS, IN A FIXED ORDER -- stay before advance, the first start that
--- is strictly better -- so the client and the server pair the same way.
--- @return table map   map[j] = index into small, for j = 1..#big
local function align(small, big)
    local n, m = #small, #big
    local map = {}
    if n == 1 then
        for j = 1, m do map[j] = 1 end
        return map
    end
    local bestCost, bestMap = huge, nil
    for s = 1, n do
        local function src(k) return ((s - 1 + k) % n) + 1 end
        local dp, from = { [1] = { [0] = adiff(small[src(0)], big[1]) ^ 2 } }, { [1] = {} }
        for j = 2, m do
            local pj, dj, fj = dp[j - 1], {}, {}
            for k = 0, n do
                local stay = pj[k]
                local adv = (k > 0) and pj[k - 1] or nil
                local c
                if stay and (not adv or stay <= adv) then
                    c, fj[k] = stay, k
                elseif adv then
                    c, fj[k] = adv, k - 1
                end
                if c then dj[k] = c + adiff(small[src(k)], big[j]) ^ 2 end
            end
            dp[j], from[j] = dj, fj
        end
        for _, kEnd in ipairs({ n - 1, n }) do
            local v = dp[m][kEnd]
            if v and v < bestCost - 1e-12 then
                bestCost = v
                local out, k = {}, kEnd
                for j = m, 1, -1 do
                    out[j] = src(k)
                    k = from[j][k] or 0
                end
                bestMap = out
            end
        end
    end
    return bestMap or map
end

--- THE CORNER PAIRING of two units: which disc of A travels to which disc of B.
---
--- ═══ PAIRED BY OUTWARD NORMAL, NOT BY DISTANCE ═══
---
--- Each vertex carries the direction it faces -- its outward-normal bisector -- and
--- the two vertex lists are aligned by that, round the circle, by align(). A corner
--- facing north goes to the corner facing north, which is what keeps the moving
--- outline convex-looking and every corner visibly heading somewhere. MEASURED
--- against pairing by world distance: cut-ins in 36 to 64 percent of sweeps against
--- 50 to 73.
---
--- ═══ max(n, m) LINKS, AND WHAT A LINK MOVES ═══
---
--- The longer list is mapped onto the shorter, so a surplus DESTINATION vertex is a
--- split -- two moving corners that start as one -- and a surplus SOURCE vertex is a
--- merge. Within a link the discs travel:
---
---   one to one         disc to disc
---   one to a bevel     the one disc to BOTH chamfer ends, as two
---   a bevel to one     both chamfer ends onto the one disc
---   a bevel to a bevel in order
---
--- A circle is one vertex, so a circle source feeds every destination vertex and a
--- circle destination swallows every source vertex. A duplicate coincides with its
--- original at t = 0 and an arrival with its partner at t = 1, and discHull skips a
--- disc on top of another -- so a split opens from nothing and a merge closes to
--- nothing, and nothing pops.
---
--- `bi` is the index of the destination disc in B.discs, which is what a record
--- that starts part way through a morph carries across the wire (storm_solve.lua),
--- and `link` numbers the vertex link a pair belongs to.
--- @param uA table
--- @param uB table
--- @return table  { { a = disc, b = disc, bi = integer, link = integer }, ... }
function BR.StormShape.pairsOf(uA, uB)
    local byA = pairCache[uA]
    if not byA then
        byA = setmetatable({}, { __mode = 'k' })
        pairCache[uA] = byA
    end
    local hit = byA[uB]
    if hit then return hit end

    local VA, VB = uA.verts, uB.verts
    local aA, aB = {}, {}
    for i = 1, #VA do aA[i] = VA[i].beta end
    for j = 1, #VB do aB[j] = VB[j].beta end
    local links = {}
    if #VA <= #VB then
        local map = align(aA, aB)
        for j = 1, #VB do links[j] = { map[j], j } end
    else
        local map = align(aB, aA)
        for i = 1, #VA do links[i] = { i, map[i] } end
    end

    local index = {}
    for i = 1, #uB.discs do index[uB.discs[i]] = i end
    local out = {}
    for l = 1, #links do
        local A, B = VA[links[l][1]].discs, VB[links[l][2]].discs
        if #A == #B then
            for q = 1, #A do
                out[#out + 1] = { a = A[q], b = B[q], bi = index[B[q]], link = l }
            end
        elseif #A == 1 then
            for q = 1, #B do
                out[#out + 1] = { a = A[1], b = B[q], bi = index[B[q]], link = l }
            end
        else
            for q = 1, #A do
                out[#out + 1] = { a = A[q], b = B[1], bi = index[B[1]], link = l }
            end
        end
    end
    byA[uB] = out
    BR.StormShape.builds.pairings = BR.StormShape.builds.pairings + 1
    return out
end

--- A disc hull's corner list as a shape, named by a solver circle. See discShape.
local function hullShape(ks, cx, cy, r)
    if not ks or (#ks == 1 and ks[1].rho < MIN_RADIUS) then
        local k = ks and ks[1]
        return BR.StormShape.circle(k and k.x or cx or 0.0, k and k.y or cy or 0.0,
            k and k.rho or 0.0)
    end
    cx, cy, r = cx or ks[1].x, cy or ks[1].y, r or 0.0
    local shape = hullOf(ks, {
        blob = { cx = cx, cy = cy, r = r },
        prims = { { kind = 'radius', cx = cx, cy = cy, r = radius(r) } },
    })
    if shape.P <= 0.0 then return BR.StormShape.circle(ks[1].x, ks[1].y, 0.0) end
    return shape
end

--- The convex hull of world discs, as a shape, with a solver circle to name it by.
---
--- `(cx, cy, r)` is recorded as the shape's `blob` -- the circle discFor stands a
--- cylinder on and the radius-blip fallback draws -- and is NOT required to be
--- inside the hull: queries that need a point inside ask the hull for one (see
--- deepPoint). A hull that is a single point is not a shape and is the one-metre
--- circle every collapsed zone is.
--- @param discs table   { { x, y, r }, ... }
--- @return table shape
function BR.StormShape.discShape(discs, cx, cy, r)
    return hullShape(discHull(discs), cx, cy, r)
end

--- THE MOVING WALL at sweep fraction `t`: every source disc moved `t` of the way to
--- its destination disc, and the hull of them.
---
--- `keep` is the destination's own discs, on a phase whose destination lies inside
--- the zone the wall left: added to the hull whenever one of them would otherwise
--- poke out of it, which is what makes the wall rest on the destination rather than
--- cut into it. See the section header for why that also keeps it from ever moving
--- outward. On a breakout it is nil and the destination is a separate part.
--- @param src table   world discs at t = 0
--- @param dst table   world discs at t = 1, one per source disc
--- @param t number    0..1
--- @param keep table|nil
--- @param cx number   the solver's circle at t, recorded on the shape
--- @return table shape
function BR.StormShape.morph(src, dst, t, keep, cx, cy, r)
    return hullShape(BR.StormShape.morphHull(src, dst, t, keep), cx, cy, r)
end

--- The moving wall's CORNER LIST at sweep fraction `t`: what morph() builds its shape
--- from, without the pieces -- for a caller that asks the wall's signed distance at
--- many instants and never draws it (storm_solve.lua's sweep price, #344).
--- @return table|nil ks
function BR.StormShape.morphHull(src, dst, t, keep)
    local s = 1.0 - t
    local md = {}
    for i = 1, #src do
        local a, b = src[i], dst[i]
        md[i] = { x = s * a.x + t * b.x, y = s * a.y + t * b.y, r = s * a.r + t * b.r }
    end
    local ks = discHull(md)
    -- ONE HULL ON AN ORDINARY FRAME, TWO ON A FRAME THE DESTINATION POKES OUT OF.
    if keep and ks and fitOf(ks, keep, 0.0, 0.0, 1.0) > 0.0 then
        for i = 1, #keep do md[#md + 1] = keep[i] end
        ks = discHull(md)
    end
    return ks
end

--- How far every disc of a list pokes out of a convex shape, at the worst. See
--- fitOf. `k` scales the discs about the origin and (ox, oy) moves them.
--- @param ks table     a corner list: a shape's `hull.ks`, or a unit's `ks`
--- @return number
function BR.StormShape.fit(ks, discs, ox, oy, k)
    return fitOf(ks, discs, ox, oy, k)
end

--- The Minkowski sum A + B of two convex corner lists, as a corner list. EXACT.
---
--- Its support function is h_A + h_B, and on any range of normals where A is on one
--- corner and B on one corner that is <c_A + c_B, u> + rho_A + rho_B: a corner, with
--- the centres and radii summed. So the sum is the two lists' breakpoints merged and
--- every range's two corners added.
---
--- WHAT IT IS FOR: the gap between two convex shapes. The separation of Z and D + c
--- is the signed distance from c to Z + (-D) -- see BR.NextZoneCentre, which places
--- a breakout by it.
--- @return table ks
function BR.StormShape.sumOf(ka, kb)
    local bps = {}
    for i = 1, #ka do bps[#bps + 1] = ka[i].a1 % TAU end
    for i = 1, #kb do bps[#bps + 1] = kb[i].a1 % TAU end
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
        local p, q = cornerAt(ka, mid), cornerAt(kb, mid)
        out[j] = corner(p.x + q.x, p.y + q.y, p.rho + q.rho, lo, hi)
    end
    return out
end

--- A corner list turned half a turn about the origin: the shape -S.
--- @return table ks
function BR.StormShape.reflect(ks)
    local out = {}
    for i = 1, #ks do
        local k = ks[i]
        out[i] = corner(-k.x, -k.y, k.rho, k.a0 + pi, k.a1 + pi, -k.c0, -k.s0, -k.c1, -k.s1)
    end
    return out
end

--- The corner list of a list of discs. See discHull.
--- @return table|nil ks
function BR.StormShape.discHull(discs)
    return discHull(discs)
end

--- The signed distance to a bare corner list. See hullDistance.
--- @return number
function BR.StormShape.hullDistance(ks, px, py)
    return hullDistance({ ks = ks }, px, py)
end

--- How far along the ray from (px, py) in the unit direction (ux, uy) it first comes
--- within `tol` of a corner list -- 0 when it starts there, nil when it never does.
--- EXACT: the ray against every arc and every run of the list grown by `tol`, which
--- is the same corner list with every radius `tol` larger (#344's sweep price).
---
--- ═══ WHY NOT MARCH IT ═══
---
--- Stepping along the ray by the signed distance never overshoots, and it crawls
--- where the ray grazes the boundary: the distance falls off as the square of what
--- is left, so a runner riding the edge of the wall -- which is exactly where the
--- price is decided -- took hundreds of steps and still read as never arriving. A
--- convex boundary meets a line at most twice, and the first time is one of these.
--- @return number|nil metres
function BR.StormShape.lineEntry(ks, px, py, ux, uy, tol)
    tol = tol or 0.0
    if not ks or #ks == 0 then return nil end
    if hullDistance({ ks = ks }, px, py) <= tol then return 0.0 end
    local best = huge
    local m = #ks
    for i = 1, m do
        local k, q = ks[i], ks[(i % m) + 1]
        local R = k.rho + tol
        -- THE ARC, radius R about the corner's centre, entered where the ray first
        -- meets that circle -- if the point it meets it at faces one of the corner's
        -- own normals.
        if R > 0.0 then
            local wx, wy = px - k.x, py - k.y
            local b = ux * wx + uy * wy
            local disc = b * b - (wx * wx + wy * wy - R * R)
            if disc >= 0.0 then
                local s = -b - sqrt(disc)
                if s >= 0.0 and s < best then
                    local dx, dy = wx + ux * s, wy + uy * s
                    if inRange(k, dx, dy) then best = s end
                end
            end
        end
        -- THE RUN to the next corner, on the line whose outward normal is this
        -- corner's last one, entered only from outside it.
        local nu = ux * k.c1 + uy * k.s1
        if nu < 0.0 then
            local s = (k.h1 + tol - (px * k.c1 + py * k.s1)) / nu
            if s >= 0.0 and s < best then
                local ex, ey = k.x + R * k.c1, k.y + R * k.s1
                local Rq = q.rho + tol
                local sx, sy = q.x + Rq * q.c0, q.y + Rq * q.s0
                -- Along the run, counter-clockwise: the normal turned a quarter left.
                local tx, ty = -k.s1, k.c1
                local along = (px + ux * s - ex) * tx + (py + uy * s - ey) * ty
                local span = (sx - ex) * tx + (sy - ey) * ty
                if along >= -EPS and along <= span + EPS then best = s end
            end
        end
    end
    if best == huge then return nil end
    return best
end

--- The furthest a bare corner list reaches from (ox, oy). See reachOf.
--- @return number
function BR.StormShape.reachOf(ks, ox, oy)
    return reachOf(ks, ox, oy)
end

--- A corner list's longest length and narrowest width. See widthOf.
--- @return number longest, number narrowest
function BR.StormShape.widths(ks)
    return widthOf(ks)
end

--- A corner list's area. See areaOf.
--- @return number
function BR.StormShape.areaOf(ks)
    return areaOf(ks)
end

--- A unit placed at (cx, cy) and scaled to radius `r`.
---
--- ═══ SCALED, WHICH IS WHY THE SOLVER DID NOT HAVE TO CHANGE ═══
---
--- BR.StormAt reports a centre and a radius and knows nothing about this; a zone is
--- that radius times a unit, so the hold/sweep timing machinery is untouched. `r`
--- stays the number the phase's AREA is written in -- a zone holds `area` of pi r^2
--- -- and nothing else: where a zone may go is decided by its real shape.
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
--- @param unit table   from blobUnit
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
        -- reports -- the circle of the phase's area, over-reporting where the shape
        -- is narrow and under-reporting along its length.
        prims = { { kind = 'radius', cx = cx, cy = cy, r = r } },
    })
end

--- Does convex shape `a` contain convex shape `b`? EXACT for two corner lists --
--- b's hull corners are its discs, and a convex set holds a hull exactly when it
--- holds what it is the hull of -- and asked of the circle's own disc otherwise.
local function holds(a, b)
    local ks = b and b.hull and b.hull.ks
    local d = (not ks) and b and b.discs and b.discs[1]
    if a and a.hull then
        if ks then
            for i = 1, #ks do
                local k = ks[i]
                if hullDistance(a.hull, k.x, k.y) + k.rho > EPS then return false end
            end
            return true
        end
        if d then return hullDistance(a.hull, d.x, d.y) + d.r <= EPS end
        return false
    end
    if not (a and a.discs and #a.discs == 1) then return false end
    local c = a.discs[1]
    if ks then
        for i = 1, #ks do
            local k = ks[i]
            if sqrt((k.x - c.x) ^ 2 + (k.y - c.y) ^ 2) + k.rho > c.r + EPS then return false end
        end
        return true
    end
    return d ~= nil and sqrt((d.x - c.x) ^ 2 + (d.y - c.y) ^ 2) + d.r <= c.r + EPS
end

--- TWO PLACED ZONES AS ONE SHAPE: the containing one, or their union.
---
--- ═══ NOT WHAT THE STORM DRAWS ANY MORE, AND WHY IT IS STILL HERE ═══
---
--- The safe zone is built by BR.StormZone now, which morphs one zone into the next
--- and knows which phases nest. This is the STATIC question -- two zones standing
--- still, one here and one there -- and it is what the stitch and the map's point
--- lists are proved against in tools/test_shared.lua.
---
--- ═══ THE CONTAINMENT TEST IS BY REAL SHAPE ═══
---
--- It used to be in circle space -- the solver's old nesting rule, `d + r2 <= r1` --
--- and a target could then poke out of the current zone on a "nested" phase and be
--- ignored. Every zone is placed by its real shape now, so the answer is too: the
--- containing shape when one holds the other (see holds), and the union otherwise.
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

    local a = BR.StormShape.blob(x1, y1, r1, unit)
    local b = BR.StormShape.blob(x2, y2, r2, target)
    if holds(a, b) then return a end
    if holds(b, a) then return b end
    return BR.StormShape.blobUnion(a, b)
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
--- ═══ WHY THIS IS ASKED AT ALL, WHEN zone() AND THE RECORD ALREADY TEST NESTING ═══
---
--- Both test the two zones as they STAND: zone() the pair it is handed, and
--- storm_solve.lua the record once, at the start of its sweep. A breakout's moving
--- wall is a new shape every frame, and it can come to hold its destination -- or
--- be held by it -- part way across; the two-component drawing of that would put
--- the swallowed shape's boundary inside the safe zone in its ENTIRETY.
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

-- ═══ A CONJOINED ZONE GROWS INTO ITS DESTINATION INSTEAD OF POPPING (#344) ═══
--
--   "when the storm finishes moving and the next phase is opened, if they're
--    conjoined, today the border pops suddenly to cover the whole area. instead it
--    should grow over a period of 20s to include that new area instead of popping."
--                                                     -- the owner, 2026-09-23
--
-- The safe zone of a breakout is the zone Z the wall starts as UNION the
-- destination D, and it used to be that from the first frame of the phase. Where
-- the two overlap it now grows from Z to Z union D instead:
--
--   G(s) = Z  union  (D  intersect  Z_s)        Z_s = Z grown by s metres
--
-- with s running from 0 to S across the growth, S being how far the furthest point
-- of D is outside Z. So the part of D the wall has taken in is exactly the part
-- within s of Z: a front that spreads out of Z across D at one speed everywhere, and
-- that ends on Z union D exactly, because D is inside Z_S. The destination itself
-- never changes -- it is only ever intersected.
--
-- ═══ EVERY PIECE OF IT IS EXACT, AND DAMAGE READS THE SAME CORNER LISTS ═══
--
--   Z_s IS A CORNER LIST. Growing a convex body by s adds s to its support function
--   everywhere, which is every corner's radius plus s and every normal where it was
--   (dilate).
--
--   D INTERSECT Z_s IS A CORNER LIST. The intersection of two convex shapes is
--   convex, and its boundary is the runs of each boundary inside the other, joined
--   at the crossings -- found exactly by crossings(), the stitch's own intersector.
--   Each arc of those runs is a corner with its own radius and range of normals,
--   and each joint where the direction turns is a SHARP corner spanning the turn
--   (cornersOf). So its signed distance is hullDistance, exact inside and out.
--
--   AND G IS A UNION OF TWO CONVEX PARTS, which is what blobUnion already is: one
--   stitched loop to draw, the minimum of two exact signed distances to bill. Its
--   magnitude is exact from outside and understates depth only inside, the way every
--   union here does -- never the unsafe way.
--
-- S IS EXACT TOO: D is the hull of its discs and the signed distance to Z is convex,
-- so its maximum over D is at a disc -- the centre's distance plus the radius, which
-- is fitOf.

--- A corner list grown by `s`: every radius plus s, every normal where it was.
--- EXACT, because that is what adding s to a support function is. Fresh tables.
--- @param ks table
--- @param s number   metres, >= 0
--- @return table ks
local function dilate(ks, s)
    local out = {}
    for i = 1, #ks do
        local k = ks[i]
        out[i] = corner(k.x, k.y, k.rho + s, k.a0, k.a1, k.c0, k.s0, k.c1, k.s1)
    end
    return out
end

--- The outward-normal angle a piece of a convex boundary starts and ends on.
local function normalsOf(pc)
    if pc.kind == 'arc' then return pc.a0, pc.a0 + pc.sweep end
    local a = atan(pc.ny, pc.nx)
    return a, a
end

--- A closed CONVEX loop of pieces, walked counter-clockwise, as a corner list.
---
--- AN ARC IS A CORNER: its centre, its radius and the normals it sweeps. A JOINT
--- WHERE THE DIRECTION TURNS IS A SHARP CORNER at the joint, spanning the turn --
--- which is every crossing of two boundaries and every sharp corner of either. A
--- joint that turns by less than ANGLE_EPS is a run continuing into its tangent
--- arc, and adds nothing.
---
--- THE RANGES ARE ONE CHAIN. Each corner starts on the normal the one before it
--- ended on, to the bit, and the chain is checked to close on one whole turn --
--- the property every query of a corner list reads. A turn the wrong way is a dent,
--- and a loop that does not close is not a convex boundary: both hand back nil.
--- @param pieces table
--- @return table|nil ks
local function cornersOf(pieces)
    local n = #pieces
    if n == 0 then return nil end
    local raw = {}
    for i = 1, n do
        local p, q = pieces[i], pieces[(i % n) + 1]
        if p.kind == 'arc' then
            if p.out < 0.0 then return nil end
            raw[#raw + 1] = { x = p.cx, y = p.cy, rho = p.r, turn = p.sweep }
        end
        local _, pe = normalsOf(p)
        local qs = normalsOf(q)
        local turn = ((qs - pe + pi) % TAU) - pi
        if turn > ANGLE_EPS then
            local x, y = pieceAt(p, p.len)
            raw[#raw + 1] = { x = x, y = y, rho = 0.0, turn = turn }
        elseif turn < -1e-9 then
            return nil
        end
    end
    if #raw == 0 then return nil end
    -- Anchored on the first piece's own starting normal, so the angles mean what the
    -- piece said rather than what a sum of turns drifted to.
    local a = normalsOf(pieces[1])
    if pieces[1].kind ~= 'arc' then
        -- The first raw corner is the joint AFTER a run, so the chain starts on
        -- that run's normal.
        a = select(2, normalsOf(pieces[1]))
    end
    local start = a
    local ks = {}
    for i = 1, #raw do
        local r = raw[i]
        ks[i] = corner(r.x, r.y, r.rho, a, a + r.turn)
        a = a + r.turn
    end
    if abs((a - start) - TAU) > 1e-6 then return nil end
    return ks
end

--- A point inside a convex corner list: the mean of the points each corner touches
--- the boundary at, half way round its normals -- a mean of boundary points of a
--- convex set, which is inside it.
local function innerPoint(ks)
    local sx, sy = 0.0, 0.0
    for i = 1, #ks do
        local k = ks[i]
        local mid = 0.5 * (k.a0 + k.a1)
        sx = sx + k.x + k.rho * cos(mid)
        sy = sy + k.y + k.rho * sin(mid)
    end
    return sx / #ks, sy / #ks
end

--- THE INTERSECTION OF TWO CONVEX SHAPES, as a corner list shape. EXACT.
---
--- The runs of A's boundary inside B, and of B's inside A, in the order a walk of
--- the intersection meets them: from each place A goes INTO B, forward along A to
--- where it comes out -- which is where B goes into A -- and forward along B from
--- there to where A next goes in. crossings() hands them over alternating, and each
--- run is checked at its midpoint to be inside the other shape, for the reason
--- stitch() checks its own: a winding argument is a thing that can be wrong.
---
--- WHEN THE BOUNDARIES NEVER MEET the answer is whichever shape is inside the other,
--- itself -- or nothing, for two that are apart. A touch this cannot read, or a run
--- on the wrong side, is `nil` and a reason, and the caller decides what that means.
--- @param a table   a corner-list shape (kind 'blob')
--- @param b table   a corner-list shape
--- @return table|nil shape
--- @return string why   'crossed', 'a', 'b', 'apart', or why it could not
function BR.StormShape.intersect(a, b)
    if not (a and a.hull and b and b.hull) then return nil, 'not two corner lists' end
    local xs, met = crossings(a, b)
    if not xs then
        if met then return nil, 'touch' end
        if insideWhole(a, b) then return a, 'a' end
        if insideWhole(b, a) then return b, 'b' end
        return nil, 'apart'
    end
    -- START ON AN ENTRY, so the list reads entry, exit, entry, exit ... and each
    -- entry with the exit after it names one run of A inside B.
    if not xs[1].into then
        local first = table.remove(xs, 1)
        xs[#xs + 1] = first
    end
    local Pa, Pb = a.P, b.P
    local nx = #xs
    local pieces = {}
    for k = 1, nx, 2 do
        local sIn, sOut = xs[k].s, xs[k + 1].s
        local la = (sOut - sIn) % Pa
        if la <= 0.0 then return nil, 'empty run' end
        local tFrom = xs[k + 1].t
        local tTo = xs[(k + 1) % nx + 1].t
        local lb = (tTo - tFrom) % Pb
        if lb <= 0.0 then return nil, 'empty run' end

        -- A MICROMETRE OF SLACK, which is CROSS_SAME: a run that lies along the other
        -- boundary is on it, not outside it.
        local mx, my = BR.StormShape.pointAtArc(a, sIn + la * 0.5)
        if BR.StormShape.distance(b, mx, my) > CROSS_SAME then return nil, 'wrong side' end
        local qx, qy = BR.StormShape.pointAtArc(b, tFrom + lb * 0.5)
        if BR.StormShape.distance(a, qx, qy) > CROSS_SAME then return nil, 'wrong side' end

        local as = sliceOf(a, sIn, la)
        for i = 1, #as do pieces[#pieces + 1] = as[i] end
        local bs = sliceOf(b, tFrom, lb)
        for i = 1, #bs do pieces[#pieces + 1] = bs[i] end
    end
    local ks = cornersOf(pieces)
    if not ks then return nil, 'not a convex loop' end
    -- NAMED BY A POINT INSIDE IT, because deepPoint and the inset's survival test
    -- read the named centre as a candidate for the deepest point -- and neither
    -- shape's own centre is promised to be inside their intersection. The radius
    -- and the map descriptor are the first shape's: the destination's, which is
    -- the only caller's `a`.
    local x, y = innerPoint(ks)
    local ab = a.blob or {}
    return hullOf(ks, {
        blob = { cx = x, cy = y, r = ab.r or 0.0 },
        prims = a.prims or {},
        meet = { a, b },
    }), 'crossed'
end

--- A convex corner-list shape grown by `s` metres, as a shape. EXACT.
--- @param shape table   a corner-list shape
--- @param s number
--- @return table shape
function BR.StormShape.dilate(shape, s)
    local m = shape.blob or {}
    return hullOf(dilate(shape.hull.ks, s), {
        blob = { cx = m.cx, cy = m.cy, r = (m.r or 0.0) + s, unit = m.unit },
        prims = { { kind = 'radius', cx = m.cx, cy = m.cy, r = radius((m.r or 0.0) + s) } },
    })
end

--- THE ZONE `z` GROWN `s` METRES INTO THE DESTINATION `d`: z union (d intersect z_s).
--- See the section header. Both are convex corner-list shapes, and neither is
--- touched -- the parts of the answer are fresh.
---
--- `s` of nothing is `z` itself, and a destination wholly inside z_s is the whole
--- union: the two ends of the growth, which are the zone before it and the zone
--- after it exactly. nil when the intersection cannot be built -- a touch this file
--- does not read -- and the caller decides what that means (BR.StormZone takes the
--- whole union, which errs toward the player).
--- @param z table   the zone the phase started in
--- @param d table   the destination
--- @param s number  metres grown
--- @return table|nil shape
function BR.StormShape.grown(z, d, s)
    if not (s > 0.0) then return z end
    local zs = BR.StormShape.dilate(z, s)
    local part, why = BR.StormShape.intersect(d, zs)
    if not part then
        -- NOTHING OF THE DESTINATION IS WITHIN s YET: the zone as it stands. Only a
        -- pair that does not overlap at all gets here, and BR.StormZone does not ask.
        if why == 'apart' then return z end
        return nil
    end
    -- THE DESTINATION HOLDS ALL OF z_s -- a target that swallows the zone it breaks
    -- out of -- so the part taken in is z_s itself, and z_s holds z. (A destination
    -- wholly inside z_s is the other nesting: the part is the destination, and the
    -- union below is the whole of the growth's end.)
    if part == zs then return zs end
    return BR.StormShape.blobUnion(z, part)
end

--- A point inside a hull shape, and how deep it is there.
---
--- The deeper of two candidates: the shape's own centre, and the mean of its corner
--- centres. A placed zone's centre is at least 0.41 r deep; a MORPH is named by the
--- solver's circle, whose centre nothing guarantees is inside the moving hull --
--- and the mean of the corner centres always is, because every one of them is.
--- Only ever asked where the answer stands in for an inscribed radius, so the
--- deeper of the two is the better stand-in.
--- @return number x, number y, number depth
local function deepPoint(shape)
    local h, m = shape.hull, shape.blob
    local d0 = -hullDistance(h, m.cx, m.cy)
    local ks = h.ks
    local sx, sy = 0.0, 0.0
    for i = 1, #ks do sx, sy = sx + ks[i].x, sy + ks[i].y end
    sx, sy = sx / #ks, sy / #ks
    local d1 = -hullDistance(h, sx, sy)
    if d1 > d0 then return sx, sy, d1 end
    return m.cx, m.cy, d0
end

--- Is there anything left of `part` after eroding it by `metres`?
---
--- The inscribed radius is the answer: a convex shape eroded by more than the
--- radius of the largest disc that fits inside it is empty. Asked of a UNION's
--- parts, so that a component the storm never had cannot be manufactured by the
--- renderer's own six metres of edgeInset -- union2's header argues the decision
--- for discs and this is the same one for blobs. The depth of deepPoint stands in
--- for the inscribed radius, and is never more than it -- so a part this drops can
--- only be one that was nearly gone, and the error is inward.
local function survivesInset(part, metres)
    local h = part and part.hull
    if h then
        local _, _, depth = deepPoint(part)
        return (depth - metres) > 0.0
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
    -- in. See chorded(). A GUARD NOW RATHER THAN A PATH: it was reached by rounded
    -- corners whose discs stood outside their own shape, and every zone and every
    -- morphing wall is a hull of discs since #344's second round -- where a point
    -- beside a disc erodes to a point beside the smaller disc and no run turns round.
    -- MEASURED zero times at a six-metre inset over the shipping shapes from 60 m
    -- down to 8, 15,200 morphing walls and 18,000 random disc hulls.
    --
    -- AND WHAT IS LEFT OF NOTHING IS THE INSCRIBED CIRCLE, floored like every circle:
    -- an erosion past the shape's own depth is empty, and the one-metre circle at its
    -- deepest point is the point a collapsed zone has always been. deepPoint, not the
    -- shape's centre: a morphing wall is named by the solver's circle, whose centre
    -- nothing puts inside it, and a one-metre circle there would be outside the wall.
    if kind == 'blob' then
        -- ═══ AN INTERSECTION ERODES AS THE INTERSECTION OF ITS TWO ERODED SHAPES ═══
        --
        -- A disc of radius d fits inside A intersect B exactly when it fits inside
        -- both, so (A intersect B) eroded by d IS (A eroded) intersect (B eroded) --
        -- two exact erosions and one exact intersection. The corner list the
        -- intersection came out as would erode too, but its crossings are sharp
        -- corners beside arcs, which is the one case erode() hands to the chords:
        -- MEASURED on growing zones, a millisecond and a half a frame where this is a
        -- tenth of that. A pair that will not intersect after eroding -- one eroded
        -- to its inscribed circle -- falls through to the ordinary path.
        if shape.meet then
            local a = BR.StormShape.inset(shape.meet[1], metres)
            local b = BR.StormShape.inset(shape.meet[2], metres)
            local cut = BR.StormShape.intersect(a, b)
            if cut then return cut end
        end
        local h, m = shape.hull, shape.blob
        local ks = erode(h.ks, metres) or erode(chorded(h.ks, CHORD_SAG), metres)
        if ks then
            return hullOf(ks, {
                blob = { cx = m.cx, cy = m.cy, r = m.r - metres, unit = m.unit },
                prims = { { kind = 'radius', cx = m.cx, cy = m.cy,
                            r = m.r - metres } },
            })
        end
        local x, y, depth = deepPoint(shape)
        return BR.StormShape.circle(x, y, depth - metres)
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
