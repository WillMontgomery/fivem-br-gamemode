-- The storm's boundary as a WALKABLE SHAPE rather than as a radius.
--
-- Nothing in the game asks this file for anything but a circle, and that is
-- deliberate: the storm draws exactly what it drew before this file existed.
-- What changes is that the renderer no longer KNOWS it is drawing a circle. It
-- asks for a perimeter, walks it in metres, and asks where the boundary is
-- nearest a point -- three questions a circle answers and so does everything
-- below.
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
local function arc(cx, cy, r, a0, sweep)
    r = radius(r)
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
--- @param meta table|nil     { discs = ..., box = ..., prims = ... }, all optional
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

-- ----------------------------------------------------------------- queries ---

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
--- @param shape table
--- @param ci number    a component index, as components() orders them
--- @return table  { { t0 = number, len = number }, ... } in boundary order
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
            out[#out + 1] = { t0 = pc.s0 - base, len = pc.len }
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
--- ═══ THIS IS THE MAP'S ANSWER, AND IT IS NOT THE BOUNDARY ═══
---
--- GTA has two filled minimap primitives and nothing else. ADD_BLIP_FOR_RADIUS
--- fills a disc, _ADD_BLIP_FOR_AREA fills a rectangle, and SET_RADIUS_BLIP_EDGE
--- draws a disc as an outline -- with no equivalent for an area blip. NO NATIVE
--- STROKES OR FILLS AN ARBITRARY POLYGON on the minimap or the pause map. The only
--- route to one is a custom Scaleform .gfx through ADD_MINIMAP_OVERLAY and
--- CALL_MINIMAP_SCALEFORM_FUNCTION, which means authoring and shipping a Flash
--- asset in an estate that streams none -- and it attaches to the MINIMAP movie,
--- so its pause-map coverage is unverified on top of that.
---
--- So the map is an approximation for any shape that is not a disc, and the place
--- that decides HOW is the constructor, beside the shape it is approximating,
--- where the error can be stated in metres. This function only hands the list on.
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

    error('StormShape.inset: no erosion for a shape of kind ' .. tostring(kind)
        .. ' -- offsetting a straight run is a different algorithm from shrinking '
        .. 'a radius, and the wall draws whatever this hands back')
end
