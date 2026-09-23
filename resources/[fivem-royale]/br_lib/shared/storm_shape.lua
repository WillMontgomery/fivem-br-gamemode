-- The storm's boundary as a WALKABLE SHAPE rather than as a radius.
--
-- EVERY PHASE IS A RANDOM SHAPE NOW (#344), and that is what this file was
-- built for:
--
--   "ship something that will draw random shaped storm walls for each phase,
--    still matching our approximate positioning and size rules, circles are not
--    allowed."                                      -- the owner, 2026-09-22
--
-- The shape is blob() below: a jittered convex polygon with rounded corners,
-- which is N segments and N arcs -- the piece model this file has walked since
-- the day it was written. The renderer does not know it is drawing anything in
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
        -- `hull` is the blob's equivalent of `box`: the corner-disc centres and
        -- the one corner radius, which is the arithmetic its exact signed
        -- distance and its exact erosion are both written in. `parts` is a
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
-- ═══ A JITTERED CONVEX POLYGON WITH ROUNDED CORNERS (#344) ═══
--
--   "ship something that will draw random shaped storm walls for each phase,
--    still matching our approximate positioning and size rules, circles are not
--    allowed."                                        -- the owner, 2026-09-22
--
-- N corners at jittered angles and jittered radii, each corner rounded by an
-- arc: N segs and N arcs, which is the piece model above and not an extension of
-- it. What is new is that the shape is DRAWN FROM A SEED rather than from a
-- centre and a radius, and that both halves of the game have to derive the same
-- one -- see blobUnit.
--
-- ═══ IT IS THE CONVEX HULL OF N EQUAL DISCS, AND THAT IS THE WHOLE TRICK ═══
--
-- A rounded polygon can be written two ways and only one of them is exact to
-- compute with. Written as "a polygon whose corners are cut off and filleted"
-- every query is a case analysis over nine regions per corner. Written as the
-- CONVEX HULL OF THE CORNER DISCS -- equivalently the polygon of their centres
-- grown by the corner radius -- three things fall out at once, all exact:
--
--   THE SIGNED DISTANCE. For a convex body the signed distance is the supremum
--   over unit directions of (<p, u> - h(u)), where h is the support function.
--   For a hull of equal discs h(u) = max_i(<c_i, u>) + cr, so that supremum is
--   reached either on an EDGE normal or radially from the one corner whose
--   angular wedge holds the direction to p -- which is a max over the same 2N
--   pieces the boundary is made of. Exact inside as well as out, unlike the
--   disc union's understatement, and no region test to get wrong.
--
--   THE EROSION. Shrinking a convex body by d subtracts d from its support
--   function, and for this shape that is exactly `cr - d` with every centre left
--   where it was. One subtraction, and it is the true erosion rather than an
--   approximation of it -- which matters because the wall draws the eroded shape
--   and then asks it questions (see inset()).
--
--   THE CURVATURE. Every arc on the boundary has radius `cr`, so the tightest
--   curvature the renderer has to resolve is one number rather than a search.
--
-- ONE RADIUS FOR EVERY CORNER, AND THAT IS WHY. The rule #344 describes is 0.85
-- of the SHORTER ADJACENT HALF-EDGE, which is a per-corner number on a jittered
-- polygon -- and a hull of UNEQUAL discs loses all three properties above: its
-- outer tangents are no longer parallel to the centre polygon's edges, a small
-- disc can be swallowed by the hull of its neighbours (an acos out of domain, on
-- one seed in however many), and an erosion past the smallest radius is not a
-- hull of discs at all. So the fraction is applied to the TIGHTEST corner's
-- allowance and that one radius is used everywhere. Measured over 20000 draws at
-- #344's nine corners, the shape family is the one #344 measured: area 0.898 of
-- the circle, max extent 1.050 of r, min/max radius 0.808, against its 0.88 to
-- 0.89 / 1.03 to 1.06 / 0.79 to 0.85 across the same jitter band. The cost of the
-- exactness is that the roundness varies more between draws, because the tightest
-- corner decides it for all of them -- not that it is a different shape.
--
-- ═══ CONVEXITY IS NOT GUARANTEED AND IS ENFORCED, NOT HOPED FOR ═══
--
-- Radii jittered about r can put a corner inside the line between its
-- neighbours: at N=9, jitter 0.13, 2491 of 20000 draws came out concave on the
-- first attempt, and at twelve corners it is most of them. A concave polygon
-- breaks both exactness claims above -- the support-function argument IS
-- convexity -- and so does #356's stitch, which joins two overlapping blobs at
-- their TWO crossings: two homothets of one convex shape cross at most twice,
-- and two of a concave one can cross as often as they like. So a draw that fails
-- the test is redrawn from the SAME stream with both jitters reduced, and the
-- last attempt uses no jitter at all, which is a regular polygon and convex by
-- construction. The loop therefore always ends on a convex shape and always
-- consumes a deterministic number of values.
local BLOB_TRIES    = 6
local BLOB_FALLOFF  = 0.75

-- ═══ THE CORNER COUNT IS DRAWN TOO, AND THREE THINGS HAD TO MOVE WITH IT ═══
--
--   "We're able to reliably draw squircle storms, but what about random other
--    shapes of various vertices?"                   -- the owner, 2026-09-23
--
-- #344 shipped every phase at nine corners, and nine corners at 0.13 of jitter
-- reads from above as a lumpy rounded square -- every storm a relative of the
-- same shape. The count is now the FIRST value off the phase's own stream, so a
-- match is a run of different polygons and the client and the server still
-- derive the same one. Nine was safe for reasons that stop being true on either
-- side of it, and each has a knob in config/storm.lua's `shape` block:
--
--   AREA FALLS WITH THE COUNT. The generator as #344 left it measured 0.29 of the
--   circle at three corners against 0.90 at nine, so a triangle phase would play
--   a third the size of a nine-corner one. Every draw is now SCALED to `area` of
--   the circle it replaces, exactly -- the Steiner formula below, not a walk.
--
--   AND HOLDING AREA PUSHES THE CORNERS OUT, which is the trade. Held to ninety
--   percent of the circle and nothing else, a triangle reaches 1.13 of r on
--   average and 1.29 at worst (1.44 and 2.03 with #344's slide, below), and r is
--   what every placement rule treats as the bound. So a draw that would reach
--   past `reach` once scaled is REJECTED like a concave one and redrawn tamer.
--   That keeps both numbers at once and pays in sharpness alone, because sharper
--   at a fixed area means further out: held to 1.15, a triangle's min/max radius
--   is 0.71 on average and 0.57 at the sharpest, against 0.82 at nine corners.
--
--   AND A THREE-CORNER SLOT IS 120 DEGREES WIDE. #344's slide was a fraction of
--   the slot, which on a triangle lets two corners drift 72 degrees closer and
--   puts the centre OUTSIDE the shape -- 179 of 4000 draws. The slide is in
--   degrees now, the same on every count, so a triangle wanders as far round the
--   ring as a dodecagon does rather than four times as far.
--
-- WHY THE REACH IS A REJECTION AND NOT A CORRECTION. The last attempt is a regular
-- polygon, which at the shipping rounding reaches 1.004 of r at three corners and
-- less above it -- so the loop still always ends on a shape inside every bound,
-- and a draw is never bent into one it did not come out as. Shrinking an
-- over-reaching draw instead would hand back a triangle phase that plays small,
-- which is the defect the area rule exists to remove.
--
-- THE CENTRE IS INSIDE, AND THAT IS NOW A THEOREM RATHER THAN A HOPE. A convex
-- shape that misses its own centre lies in a half-plane, and the most of a disc
-- of radius `reach` a half-plane holds is half of it -- 0.66 of the circle at
-- 1.15, against the 0.90 every shape is scaled to. Worked through the circular
-- segment, the centre is at least 0.33 of r deep in every shape that ships, and
-- measured it is never less than 0.65. #350's in-place map fill and #352's
-- headcount both lean on it.
--
-- BLOB_MAX_CORNERS is only how far up a weight table is read, twice the top of
-- the shipping range. A count up there is legal and a poor bargain: measured, a
-- twenty-corner draw ends on the last attempt's regular polygon four times in five.
local BLOB_MAX_CORNERS = 24

-- ═══ THE SLIDE IS STILL BOUNDED BY THE SLOT, BUT ONLY AS A BACKSTOP ═══
--
-- At half a slot two neighbours can reach the same angle and the corner ORDER can
-- swap, which would turn a convex draw into a self-crossing one. The shipping
-- slide never reaches this -- nine degrees is 0.3 of a twelve-corner slot and less
-- of every smaller one -- so it binds only on a config asking for more corners or
-- more slide than ships, and there it is the value #344 measured as leaving the
-- order decided by construction.
local BLOB_SLIDE_SLOT = 0.3

-- HOW SHARP A CORNER MAY BE, in radians of exterior turn, at both ends.
--
-- The lower bound is a convexity test: a turn at or below zero is a reflex corner.
-- It is a small POSITIVE number rather than zero because a corner that turns by a
-- nanoradian is convex and useless -- `ccwSweep` reads an exactly zero sweep as
-- "all the way round" (see its header), the corner's own tangent length runs away
-- as the turn goes to nothing, and a boundary piece of no length is dropped by
-- seal() leaving a shape whose pieces no longer chain. Three degrees on a
-- twelve-corner polygon whose mean turn is thirty is a guard rather than a
-- constraint: it rejects the degenerate draw and nothing else.
--
-- The upper bound is the same statement at the other end -- a corner that turns
-- by nearly half a turn is a spike -- and it is not reachable at any N this ships
-- with. Kept because it costs one comparison and because the arithmetic below
-- divides by sin of half the interior angle, which is what a spike sends to zero.
--
-- ═══ AND IT IS ONE OF THREE, WHICH IS WORTH KNOWING BEFORE DELETING ANY OF THEM
--     ═══
--
-- Concavity is caught here, AND by `cr > 0` (a reflex corner's tangent limit comes
-- out negative, so the minimum does), AND by the cross-product test on the corner
-- CENTRES further down. Measured by removing each in turn: every one of the three
-- is individually redundant and the suite stays green, and removing all three at
-- once puts concave shapes through and turns tools/test_shared.lua's `blob.*`
-- blocks red on six assertions. That is defence in depth rather than three
-- mistakes -- each one guards a different failure at its own step -- but a reader
-- who deletes one and sees a green suite has learnt nothing about whether it was
-- load-bearing.
local BLOB_MIN_TURN = 0.05

--- The outward normal and the length of each edge of a closed centre polygon.
---
--- Stamped ONTO the centre list rather than returned beside it, because every
--- query below wants the normal of "edge i" keyed the same way the centres are:
--- edge i runs from centre i to centre i+1, and its normal is the RIGHT of that
--- travel, which is outward for a counter-clockwise polygon. Interior on the
--- left, as everything in this file is.
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

--- Signed distance to the convex hull of equal discs `{ cs, cr }`.
---
--- THE MAXIMUM OF THE SUPPORTING CONSTRAINTS, which is the header's argument
--- spelled out: for each edge, the distance to the line the boundary segment lies
--- on; for each corner, the radial distance to its disc, but ONLY where the
--- direction from that disc's centre falls inside the corner's own angular wedge
--- -- between the two adjacent edge normals -- because outside that wedge the
--- disc is not what bounds the shape and its radial distance is an understatement.
---
--- A POINT AT A CORNER CENTRE IS ANSWERED BY THE EDGES, not by the arc, and that
--- is why the length test does not need a special case after it. The disc is
--- tangent to both adjacent edge lines, so both of them report exactly `-cr`
--- there, which is the true answer.
---
--- Negative inside, positive outside, exact everywhere. Checked against a dense
--- walk of the boundary in tools/test_shared.lua rather than against itself.
local function hullDistance(h, px, py)
    local cs, cr = h.cs, h.cr
    local n = #cs
    local best = -huge
    for i = 1, n do
        local a = cs[i]
        local d = (px - a.x) * a.nx + (py - a.y) * a.ny - cr
        if d > best then best = d end
    end
    for i = 1, n do
        local c = cs[i]
        local p = cs[((i - 2) % n) + 1]
        local ddx, ddy = px - c.x, py - c.y
        local len = sqrt(ddx * ddx + ddy * ddy)
        if len > 0.0
            and (p.nx * ddy - p.ny * ddx) >= 0.0
            and (ddx * c.ny - ddy * c.nx) >= 0.0 then
            local d = len - cr
            if d > best then best = d end
        end
    end
    return best
end

--- The hull of equal discs as a boundary: N straight runs and N corner arcs.
---
--- Walked counter-clockwise from the first edge, so every run's right of travel
--- is its outward normal and every arc is swept positively about its own corner
--- centre -- which is what lets pointAtArc stay ignorant of the shape it is
--- walking. The chain closes by construction: run i ends at `c_{i+1} + cr * n_i`
--- and the arc at corner i+1 begins at exactly that angle.
--- @param cs table    corner-disc centres, counter-clockwise, normals stamped
--- @param cr number    the one corner radius
--- @param meta table
local function hullOf(cs, cr, meta)
    local n = #cs
    local pieces = {}
    local function push(pc) if pc then pieces[#pieces + 1] = pc end end
    for i = 1, n do
        local a, b = cs[i], cs[(i % n) + 1]
        local nx, ny = a.nx, a.ny
        push(seg(a.x + nx * cr, a.y + ny * cr, b.x + nx * cr, b.y + ny * cr))
        local a0 = atan(ny, nx)
        local a1 = atan(b.ny, b.nx)
        push(arc(b.x, b.y, cr, a0, ccwSweep(a0, a1)))
    end
    meta.hull = { cs = cs, cr = cr }
    return seal(pieces, 'blob', meta)
end

-- ═══ THE UNIT BLOB IS MEMOISED, AND THE CACHE IS BOUNDED ═══
--
-- Every frame of the wall, every tick of the HUD and every tick of the server's
-- damage pass ask for the SAME unit -- one seed, one phase -- so building it each
-- time is a generator, a convexity test and up to six retries of garbage per
-- call. Keyed on the seed, the phase and every knob that changes the answer, so a
-- config edit between two calls cannot be served a stale shape.
--
-- FLUSHED WHOLE RATHER THAN EVICTED. A server runs matches for days and each one
-- brings a fresh seed, so an unbounded table here is a slow leak. Dropping the
-- whole table at a ceiling costs one rebuild per phase per live match on the
-- frame after the flush, which is microseconds, and it cannot grow.
local blobCache, blobCacheN = {}, 0
local BLOB_CACHE_MAX = 64

--- One attempt at a unit blob, off `rng`. nil when the draw is not convex, or
--- reaches past `reach` once it is scaled to `area`.
---
--- Every draw takes exactly 2N values off the stream WHETHER OR NOT IT SUCCEEDS,
--- which is what makes a retry deterministic rather than a fork: the client and
--- the server reject the same attempt at the same point and arrive at the same
--- shape. Both tests therefore run AFTER all 2N values are drawn.
--- @param slide number   radians a corner may slide round the ring
--- @param rot number     radians the whole draw is turned by
--- @param area number    the fraction of the unit circle's area to scale to
--- @param reach number   the furthest the scaled boundary may reach from the centre
local function blobAttempt(rng, n, jitter, slide, round, rot, area, reach)
    local slot = TAU / n
    if slide > slot * BLOB_SLIDE_SLOT then slide = slot * BLOB_SLIDE_SLOT end
    local vs = {}
    for i = 1, n do
        -- THE ANGLE STAYS IN ITS OWN SLOT, which is what stops two corners
        -- swapping places: at +-0.3 of a slot no draw can reach its neighbour's,
        -- so the corner order is the slot order and the walk is counter-clockwise
        -- without having to be sorted.
        --
        -- AND THE WHOLE RING IS TURNED, by one angle drawn with the count. Without
        -- it corner one of every shape sits due east give or take the slide, so
        -- every triangle in every match points the same way and every square is
        -- the same diamond -- one shape per count rather than a family of them.
        local a = rot + (i - 1) * slot + slide * (rng:float() * 2.0 - 1.0)
        -- SYMMETRIC ABOUT 1, NOT INWARD FROM IT (#344, measured). Radii drawn in
        -- [1 - 2j, 1] cost 28 to 41 percent of the circle's area, because a polygon
        -- inscribed in a circle has already given some up and the corner rounding
        -- takes more. Jittering about the radius costs about a tenth and buys back
        -- the extent. Measured on this generator by making the change and
        -- re-running: area 0.690 of the circle against 0.898, and max extent down
        -- to 0.93 of r -- a zone a fifth smaller everywhere, which is a gameplay
        -- change rather than a shape one.
        local rad = 1.0 + jitter * (rng:float() * 2.0 - 1.0)
        vs[i] = { x = cos(a) * rad, y = sin(a) * rad }
    end
    if not stampNormals(vs) then return nil end

    -- The exterior turn at each corner, which is both the convexity test and the
    -- sweep of the arc that will round it.
    for i = 1, n do
        local p = vs[((i - 2) % n) + 1]
        local c = vs[i]
        local t = atan(p.ex * c.ey - p.ey * c.ex, p.ex * c.ex + p.ey * c.ey)
        if t < BLOB_MIN_TURN or t > pi - BLOB_MIN_TURN then return nil end
        c.turn = t
    end

    -- THE CORNER RADIUS: the given fraction of the TIGHTEST corner's allowance.
    -- A corner may be filleted with a circle tangent to both its edges at a
    -- distance of `t` from the vertex, where t = cr / tan(theta/2) and theta is
    -- the interior angle; t must fit inside both adjacent half-edges or two
    -- corners would eat each other's straight run. So each corner's own ceiling
    -- is (shorter adjacent half-edge) * tan(theta/2), and one radius for all of
    -- them means the smallest ceiling decides -- see the section header.
    local cr = huge
    for i = 1, n do
        local p = vs[((i - 2) % n) + 1]
        local c = vs[i]
        local halfMin = 0.5 * ((p.elen < c.elen) and p.elen or c.elen)
        local lim = halfMin * math.tan((pi - c.turn) * 0.5)
        if lim < cr then cr = lim end
    end
    cr = cr * round
    if not (cr > 0.0) then return nil end

    -- The corner-disc centres: inward along each bisector, far enough in that the
    -- disc is tangent to both edges. cr / sin(theta/2) is that distance, and the
    -- bisector is the sum of the two unit vectors toward the neighbours.
    local cs = {}
    for i = 1, n do
        local p = vs[((i - 2) % n) + 1]
        local c = vs[i]
        local bx, by = c.ex - p.ex, c.ey - p.ey
        local bl = sqrt(bx * bx + by * by)
        if bl <= 0.0 then return nil end
        local d = cr / sin((pi - c.turn) * 0.5)
        cs[i] = { x = c.x + bx / bl * d, y = c.y + by / bl * d }
    end
    -- The centre polygon is the vertex polygon pulled in by cr, so it is convex
    -- whenever that one is and no disc can be swallowed. Asserted rather than
    -- assumed, because everything downstream is exact only if it holds.
    if not stampNormals(cs) then return nil end
    for i = 1, n do
        local p = cs[((i - 2) % n) + 1]
        local c = cs[i]
        if (p.ex * c.ey - p.ey * c.ex) <= 0.0 then return nil end
    end

    -- ═══ SCALED TO `area` OF THE CIRCLE, EXACTLY ═══
    --
    -- A convex polygon grown by a disc of radius cr has area A + P * cr + pi * cr^2
    -- -- its own area, a strip of width cr along every edge, and the corner arcs,
    -- whose sweeps sum to one whole turn (Steiner's formula). So the area is three
    -- terms of arithmetic on numbers already in hand, and scaling the centres and
    -- the radius by one factor keeps the shape a hull of equal discs: nothing the
    -- header claims exact stops being so.
    local poly, per = 0.0, 0.0
    for i = 1, n do
        local a, b = cs[i], cs[(i % n) + 1]
        poly = poly + (a.x * b.y - b.x * a.y)
        per = per + a.elen
    end
    local k = sqrt(area * pi / (0.5 * poly + per * cr + pi * cr * cr))
    for i = 1, n do
        cs[i].x, cs[i].y = cs[i].x * k, cs[i].y * k
    end
    stampNormals(cs)
    cr = cr * k

    local extent = 0.0
    for i = 1, n do
        local c = cs[i]
        local e = sqrt(c.x * c.x + c.y * c.y) + cr
        if e > extent then extent = e end
    end
    if extent > reach then return nil end
    return {
        n = n, cr = cr, cs = cs, jitter = jitter,
        -- WHAT THE SHAPE MEASURES, normalised, recorded here because every
        -- consumer that wants to compare the blob with the circle it replaced
        -- would otherwise re-derive it: the furthest the boundary reaches, and
        -- the nearest it comes. `inradius` is read off the signed distance at the
        -- centre, which IS the distance to the nearest boundary point.
        extent = extent,
        inradius = -hullDistance({ cs = cs, cr = cr }, 0.0, 0.0),
    }
end

--- THE UNIT BLOB for one match seed and one phase: a shape of radius 1 at the
--- origin, to be scaled by whatever radius the solver reports.
---
--- ═══ DETERMINISM IS A CORRECTNESS REQUIREMENT HERE, NOT A NICETY ═══
---
--- The client draws the wall and the server does the damage. They do not exchange
--- the shape -- there is no per-frame traffic in this design and there is not
--- going to be -- so they derive it, from the seed the record carries and the
--- phase index. If they disagree by a metre the wall is a lie by a metre, and the
--- symptom is damage taken at a place the curtain says is safe: the exact report
--- edgeInset exists for, with no bound on it. tools/test_storm.lua walks both
--- paths and compares, the way `first.stream` already does for the centres.
---
--- SEEDED OFF THE MATCH SEED AND THE PHASE, and mixed rather than added, so that
--- two adjacent phases of one match are unrelated draws instead of neighbouring
--- states of one stream.
---
--- INTEGER, AND THAT IS #346. BR.Rng runs its argument through math.tointeger and
--- falls back to ZERO when that fails, so a fractional seed is silently seed 0 --
--- every match the same shape, with nothing to notice. Floored here, once, where
--- both callers pass through.
---
--- ═══ nil IS THE OFF SWITCH AND IS SPELLED IN THE CONFIG, NOT HERE ═══
---
--- Fewer than three corners is not a polygon, and it is the one way back to
--- circles: BR.StormZone hands a nil unit to union2 and the game draws exactly
--- what it drew before #344. That is a value somebody has to type -- #335 shipped
--- its shape behind a knob at zero and nothing in the game ever drew it, which is
--- the mistake this file is not repeating -- so the shipping config weights three
--- to twelve corners and the off switch is a deliberate edit.
---
--- `corners` IS A COUNT OR A TABLE OF WEIGHTS. A number is that many corners on
--- every phase; a table `{ [3] = 2, [4] = 2, ... }` is drawn from, per phase, in
--- proportion to the weights. A table with no positive weight at three or more
--- is the off switch in that spelling, exactly as a number below three is.
---
--- @param seed number|nil     the match's storm seed (server/storm.lua's seedRng)
--- @param phase number|nil    1-based phase index
--- @param opts table|nil      { corners, jitter, slideDeg, round, area, reach }
--- @return table|nil unit     { n, cr, cs, extent, inradius, tries }
function BR.StormShape.blobUnit(seed, phase, opts)
    opts = opts or {}
    -- THE COUNTS ON OFFER, ascending, and their weights. Read in a fixed order
    -- rather than with pairs(), whose order is not defined and would hand the
    -- client and the server the same roll against differently ordered buckets.
    local want = opts.corners or 9
    local counts, weights, total = {}, {}, 0.0
    if type(want) == 'table' then
        for c = 3, BLOB_MAX_CORNERS do
            local w = tonumber(want[c]) or 0.0
            if w > 0.0 then
                counts[#counts + 1], weights[#weights + 1] = c, w
                total = total + w
            end
        end
    else
        local c = math.floor(tonumber(want) or 0)
        if c >= 3 then counts[1], weights[1], total = c, 1.0, 1.0 end
    end
    if total <= 0.0 then return nil end

    local jitter = opts.jitter or 0.13
    local slide  = (opts.slideDeg or 9.0) * pi / 180.0
    local round  = opts.round or 0.85
    local area   = opts.area or 0.90
    local reach  = opts.reach or 1.15

    local s = math.tointeger(math.floor(seed or 0)) or 0
    local p = math.tointeger(math.floor(phase or 0)) or 0

    local spec = {}
    for i = 1, #counts do spec[i] = ('%d:%.6f'):format(counts[i], weights[i]) end
    local key = ('%d|%d|%s|%.6f|%.6f|%.6f|%.6f|%.6f'):format(s, p,
        table.concat(spec, ','), jitter, slide, round, area, reach)
    local hit = blobCache[key]
    if hit then return hit end

    local rng = BR.Rng(s * 1000003 + p * 7919 + 17)

    -- ═══ THE COUNT AND THE TURN ARE THE FIRST TWO VALUES, ALWAYS ═══
    --
    -- Drawn off the phase's own stream, which is the match's storm seed and the
    -- phase index and nothing else, so the client and the server roll the same
    -- count exactly as they draw the same corners. TAKEN EVEN WHEN THERE IS ONE
    -- COUNT TO CHOOSE FROM, so that everything after them sits at the same place
    -- in the stream however `corners` is spelled: `9` and `{ [9] = 1 }` are the
    -- same shape rather than two neighbouring draws.
    local roll = rng:float() * total
    local n = counts[#counts]
    for i = 1, #counts do
        roll = roll - weights[i]
        if roll < 0.0 then n = counts[i] break end
    end
    local rot = rng:float() * TAU

    local j, sl = jitter, slide
    local unit
    for attempt = 1, BLOB_TRIES do
        -- THE LAST ATTEMPT HAS NO JITTER AT ALL, radial or angular, so it is a
        -- regular polygon: convex by construction, and inside `reach` at any count
        -- the shipping rounding allows (see the section header). That is what makes
        -- this loop terminate on a shape rather than on a nil, and it is why
        -- nothing downstream has a "there is no shape" branch to get wrong. So it
        -- is also accepted however far it reaches -- a config asking for a reach a
        -- regular polygon cannot meet at its area gets the regular polygon, never
        -- a circle.
        local last = attempt == BLOB_TRIES
        if last then j, sl = 0.0, 0.0 end
        unit = blobAttempt(rng, n, j, sl, round, rot, area, last and huge or reach)
        if unit then unit.tries = attempt break end
        j, sl = j * BLOB_FALLOFF, sl * BLOB_FALLOFF
    end

    if blobCacheN >= BLOB_CACHE_MAX then blobCache, blobCacheN = {}, 0 end
    blobCache[key] = unit
    blobCacheN = blobCacheN + 1
    return unit
end

--- A unit blob placed at (cx, cy) and scaled to radius `r`.
---
--- ═══ SCALED, WHICH IS WHY THE SOLVER DID NOT HAVE TO CHANGE ═══
---
--- BR.StormAt reports a centre and a radius and knows nothing about this; the
--- shape is that radius times a unit blob, so a shrinking phase is a shrinking
--- scale factor and the whole hold/sweep timing machinery is untouched. `r` stays
--- the number every placement rule is written in -- d_max, the nesting check, the
--- survey -- and the blob's own reach is 1.02 to 1.10 of it on average and never
--- past `reach`, 1.15, at any corner count (measured, and bounded by the retry),
--- which is what "approximate positioning and size rules" bought.
---
--- ═══ BELOW A FEW METRES IT IS A CIRCLE, AND THAT IS MIN_RADIUS's ARGUMENT ═══
---
--- Every radius this file builds floors at MIN_RADIUS, so a corner radius under a
--- metre would be floored up and the corner arcs would no longer meet the runs
--- they were built for -- a boundary that does not chain. That happens at about
--- six metres of zone radius, which is the last few seconds of the final sweep,
--- where the whole shape is smaller than one quad of the wall that draws it. A
--- two-metre circle is a point at the storm's own resolution, and a point is not
--- a circle -- the same reading union2's header gives phase 8.
--- @param cx number
--- @param cy number
--- @param r number
--- @param unit table   from blobUnit
--- @return table shape
function BR.StormShape.blob(cx, cy, r, unit)
    cx, cy, r = cx + 0.0, cy + 0.0, radius(r)
    if not unit or (r * unit.cr) < MIN_RADIUS then
        return BR.StormShape.circle(cx, cy, r)
    end
    local cs = {}
    for i = 1, unit.n do
        local c = unit.cs[i]
        cs[i] = { x = cx + c.x * r, y = cy + c.y * r }
    end
    -- A CENTRE POLYGON WITH AN EDGE OF NO LENGTH IS NOT WALKABLE, and the circle is
    -- the same answer the radius floor above gives for the same reason. The unit's
    -- own convexity test makes this unreachable -- two adjacent centres would have
    -- to coincide -- so it is the guard for a unit that arrived from somewhere this
    -- file does not control, not a case the generator produces.
    if not stampNormals(cs) then return BR.StormShape.circle(cx, cy, r) end
    return hullOf(cs, r * unit.cr, {
        blob = { cx = cx, cy = cy, r = r, unit = unit },
        -- ═══ ONE RADIUS BLIP, AND THE MAP HAS NO BETTER ANSWER THAN THAT ═══
        --
        -- No native fills an arbitrary outline on the minimap or the pause map --
        -- mapPrimitives' header has the whole search -- so a blob cannot be drawn
        -- as itself there. The ring is the CIRCLE THE BLOB REPLACED, which is the
        -- ring the map has always drawn, at the radius the solver reports: it is
        -- exact in the directions the blob reaches r, over-reports by
        -- (1 - inradius/r) of it where the blob dents in, and under-reports by
        -- (extent/r - 1) where it bulges out. Measured at the shipping config, 0.15r
        -- and 0.05r on average -- so on one phase-1 draw a 2600 m ring over a
        -- boundary running 2206 to 2789 metres out, and on phase 7 a 40 m ring over
        -- one running 34 to 42.
        --
        -- THE WALL IS THE AUTHORITY AND IT IS DRAWN AT THE REAL BOUNDARY, so a
        -- player who can see the curtain is never misled by this; the ring is for
        -- deciding a rotation from the pause map, where a few percent of a
        -- kilometre is a pixel. Drawing the INSCRIBED circle instead would never
        -- over-report and would shrink every ring on every map by a fifth, which
        -- is a change to how the whole game reads for a case the curtain already
        -- answers. Left at r, and named here so the decision can be argued with.
        prims = { { kind = 'radius', cx = cx, cy = cy, r = r } },
    })
end

--- The SAFE ZONE as one shape: two blobs, or the one that contains the other.
---
--- ═══ THE SAME FOUR CASES union2 HAS, DECIDED THE SAME WAY, AND ONE OF THEM IS
---     NO LONGER EXACT ═══
---
--- The zone is the current shape UNION the one the wall is closing toward, so
--- that a player who reaches the new destination early is safe there (#328). For
--- two DISCS that union is exact in the arc-and-segment model -- union2 computes
--- the two crossings and stitches the outer arcs. For two BLOBS it is not: two
--- convex rounded polygons can cross up to 2N times, and stitching that is a real
--- boolean union and a separate piece of work.
---
--- SO THIS ROUND PAYS FOR IT IN ONE PLACE ONLY, AND IT IS NAMED HERE:
---
---   NESTED (the common case, every phase that did not break out) -- the zone is
---   the CONTAINING blob, one closed loop, and its signed distance is exact
---   everywhere. What it gives up is that the target blob's bulges can poke out of
---   the current blob's dents, so those slivers are not pre-safe. Measured over the
---   shipping phase pairs, sweeping the whole offset range on four seeds each: it
---   happens on about a tenth of the offsets and only near the containment limit,
---   and the worst sliver is 61 m at 2600 -> 1600, then 70, 48, 27, 15 and 7 m.
---
---   WITH THE COUNT DRAWN, THE TRIANGLES ARE THE WORST OF IT. Computed exactly off
---   the two support functions at 2600 -> 1600, 600 draws a count, the centre
---   drawn uniformly over the slack as NextStormCentre draws it: at nine corners,
---   as #344 shipped them and as they ship now alike, a sliver passes 50 m on about
---   4 percent of phase changes and 95 to 100 m at the 99th percentile; at three,
---   9 percent and 159 m. The most any shape CAN give up is
---   the slack times one minus its inradius -- 233 m at nine corners, 324 m at
---   three. Unscaled the triangle was 66 percent and 1081 m, which is the area rule
---   earning its keep a second time.
---
---   THAT IS NOT A LOSS AGAINST TODAY, IT IS GRACE DECLINED. Today's nested target
---   is a disc strictly inside a disc and adds nothing at all, so the pre-safe
---   ground #328 buys in this case is already nothing. The wall is drawn on the
---   boundary that damages either way, so nothing is ever told it is safe where it
---   is not -- which is the direction that matters.
---
---   DISJOINT -- two closed loops, kilometres apart, exact. The gap between them
---   is not safe, which is the reading union2's header argues.
---
---   OVERLAPPING (a breakout whose circles cross) -- BOTH BOUNDARIES ARE DRAWN,
---   so the stretches of each that run inside the other are drawn too. That is
---   the artifact #328 removed for circles, back for exactly this case: a wall
---   visible inside the safe zone. The DAMAGE IS STILL EXACT -- the signed
---   distance to a union is the minimum of the two, which holds for any two
---   shapes -- so it is a drawing defect and not a gameplay one. It is announced
---   in config/storm.lua as well as here rather than left to be discovered.
---
--- THE CONTAINMENT TEST IS IN CIRCLE SPACE, deliberately, and not in blob space.
--- It is the solver's own nesting rule (`d + r2 <= r1`), the same three
--- comparisons with the same nanometre of slack union2 makes, so "did this phase
--- break out" has one answer in this file and in storm_solve.lua. Testing the
--- blobs instead would make the number of loops on screen depend on a jitter
--- draw, so a phase could be one wall or two for reasons no config explains.
---
--- A DISC WITH NO RADIUS IS STILL NOT A DISC. Phase 8 closes on radius 0 and the
--- test is on what the caller asked for, exactly as union2's is -- so the final
--- phase is one shape closing onto a point, never a shape plus a pillar standing
--- on the destination.
---
--- @param unit table|nil   nil is the off switch: union2, and the pre-#344 game
--- @return table shape
function BR.StormShape.zone(x1, y1, r1, x2, y2, r2, unit)
    if not unit then
        return BR.StormShape.union2(x1, y1, r1, x2, y2, r2)
    end
    local has1, has2 = (r1 or 0.0) > 0.0, (r2 or 0.0) > 0.0
    if has1 and not has2 then return BR.StormShape.blob(x1, y1, r1, unit) end
    if has2 and not has1 then return BR.StormShape.blob(x2, y2, r2, unit) end
    if not has1 then return BR.StormShape.circle(x1, y1, 0.0) end

    local dx, dy = x2 - x1, y2 - y1
    local d = sqrt(dx * dx + dy * dy)
    if d + r2 <= r1 + EPS then return BR.StormShape.blob(x1, y1, r1, unit) end
    if d + r1 <= r2 + EPS then return BR.StormShape.blob(x2, y2, r2, unit) end

    return BR.StormShape.blobUnion(BR.StormShape.blob(x1, y1, r1, unit),
                                   BR.StormShape.blob(x2, y2, r2, unit))
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
-- ═══ AND IT IS NOT A BOOLEAN UNION, BECAUSE A BLOB IS CONVEX ═══
--
-- A blob is the convex hull of N equal discs, so it is convex, and two convex
-- bodies that properly overlap cross at exactly TWO points: A n B is convex, so
-- dA n B is a single connected run, and therefore so is its complement. The
-- union's boundary is then A's boundary outside B followed by B's boundary
-- outside A, joined at the two crossings -- two contiguous runs, one loop. No
-- polygon clipping, no crossing list, no even-odd classification.
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

--- Metres of tolerance on a crossing located by bisection.
---
--- A MILLIMETRE, WHICH IS NINE ORDERS BELOW ANYTHING THAT READS IT. The wall is
--- drawn in 30 m slots and sits six metres inside the logical edge; the map fill
--- is sampled at metres of chord error. What the tolerance actually bounds is the
--- positional gap at the seam -- A's kept run ends at a point found by bisection
--- and B's kept run starts at that same point found by nearestArc -- so a
--- millimetre there is a millimetre of skew on one quad and nothing else.
local CROSS_TOL = 1e-3

--- Uniform scan samples per boundary piece when hunting for the crossings.
---
--- ═══ FOUR IS NOT A GUESS ABOUT WHETHER IT IS ENOUGH, BECAUSE THE REFINEMENT
---     BELOW ANSWERS THAT EXACTLY ═══
---
--- A uniform scan on its own can only find a lens longer than its own step -- at
--- phase 2 that step is about 200 m of a 10 km boundary -- so the density would be
--- a bet on how shallow an overlap the game can reach. MEASURED, with no
--- refinement: at four samples per piece the worst two-component answer over
--- 14,400 reachable geometries still drew 1.20% of its boundary inside the safe
--- zone, and quadrupling the density to sixteen bought that down to 0.067% at 2.4
--- times the cost per frame. Both numbers are a density hoping to be lucky.
---
--- So this is the cost/benefit floor and refineCrossings is the correctness: the
--- scan is cheap and coarse, and every interval that COULD still hide a lens is
--- subdivided until it provably cannot. The seed -- the point of A's boundary
--- nearest B's centre, always strictly inside B for two properly overlapping
--- circles, since proper overlap is |r1-r2| < d < r1+r2 and that is exactly the
--- condition for |r1 - d| < r2 -- is what usually makes the refinement unnecessary
--- rather than what makes the scan sufficient.
local CROSS_PER_PIECE = 4

--- Ceiling on extra signed distances the refinement may spend per crossing hunt.
---
--- A BOUND ON WORK, NOT A BOUND ON CORRECTNESS: the refinement is written to stop
--- on its own when no interval can hide a lens, and in the ordinary overlap it
--- spends nothing at all -- an interval with a negative endpoint is already
--- bracketing a crossing and one with two large positive endpoints is provably
--- clear. What this exists for is the pathological shape nobody has drawn yet,
--- where the loop is the thing running in a per-frame build. Spending it out lands
--- on the two-component boundary, which is the picture that shipped before #356.
local CROSS_REFINE_MAX = 48

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
        -- `out` normal keeps pointing the way it pointed.
        local perM = pc.sweep / pc.len
        return arc(pc.cx, pc.cy, pc.r, pc.a0 + perM * t0, perM * L)
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
--- The furthest corner disc, plus the corner radius. ONE SQUARE ROOT, because the
--- comparison between the corners is made on squared lengths -- this runs before
--- every stitch attempt and the whole reason it exists is to be cheaper than the
--- thing it decides not to do.
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
    local cx, cy = m.cx, m.cy
    local worst = 0.0
    for i = 1, #h.cs do
        local dx, dy = h.cs[i].x - cx, h.cs[i].y - cy
        local q = dx * dx + dy * dy
        if q > worst then worst = q end
    end
    return sqrt(worst) + h.cr
end

--- Is `shape` entirely inside `other`? EXACT, and it is convexity that makes it so.
---
--- A blob is the convex hull of N equal discs and a circle is one disc, so the
--- shape is inside a CONVEX `other` exactly when every one of those discs is --
--- the hull of points in a convex set is in that set. A disc is inside when its
--- centre is at least its own radius deep, which is one signed distance per
--- corner. Nine reads at the shipping corner count, and a disjoint pair fails on
--- the first.
---
--- ═══ WHY THIS IS ASKED AT ALL, WHEN zone() ALREADY TESTS NESTING ═══
---
--- zone()'s test is in CIRCLE space, deliberately -- storm_solve.lua's own nesting
--- rule, so that "did this phase break out" has one answer everywhere. A blob
--- reaches up to 1.15 of its circle and dents in to about 0.85 of it, so a pair
--- that is not nested as circles can be nested as blobs. MEASURED over the
--- shipping phase pairs on four seeds, sweeping the whole reachable separation
--- range: it happens, and the two-component drawing of it put up to 35.3% of the
--- boundary inside the safe zone -- worse than the overlap this round is fixing,
--- because the swallowed shape's boundary is inside in its ENTIRETY.
---
--- AND COLLAPSING IT CHANGES NOTHING distance() ANSWERS. For A inside B the
--- signed distance to B is at most the signed distance to A everywhere, so the
--- minimum over the parts IS B's -- inside, outside and on either boundary. The
--- same argument makes inset() agree, because erosion preserves inclusion.
local function convexInside(shape, other)
    local h = shape and shape.hull
    if h then
        for i = 1, #h.cs do
            if BR.StormShape.distance(other, h.cs[i].x, h.cs[i].y) > -h.cr then
                return false
            end
        end
        return true
    end
    local d = shape and shape.discs and shape.discs[1]
    if not d then return false end
    return BR.StormShape.distance(other, d.x, d.y) <= -d.r
end

--- The arc length in (lo, hi) where `f` changes sign, to CROSS_TOL metres.
---
--- `negAtLo` says which side of the bracket is inside, so one function serves both
--- crossings rather than two spellings of the same halving. BOUNDED BY COUNT AS
--- WELL AS BY WIDTH: the width test is what normally ends it, in about eighteen
--- passes of a two-hundred-metre bracket, and the count is what stops a bracket
--- whose endpoints disagree with f -- a nan, a degenerate shape -- from spinning
--- inside a per-frame build.
local function bisectCross(fn, lo, hi, negAtLo)
    for _ = 1, 60 do
        if (hi - lo) <= CROSS_TOL then break end
        local mid = (lo + hi) * 0.5
        if (fn(mid) < 0.0) == negAtLo then lo = mid else hi = mid end
    end
    return (lo + hi) * 0.5
end

--- Where `a`'s boundary enters `b` and where it leaves again, in a's arc length.
---
--- Both nil when the two boundaries do not cross transversally in exactly one
--- place each way -- disjoint, nested, tangent, or a lens too small for the scan.
--- @return number|nil sIn   arc length where a's boundary ENTERS b
--- @return number|nil sOut  arc length where it LEAVES b
local function crossings(a, b)
    local P = a.P
    if P <= 0.0 or not b or (b.P or 0.0) <= 0.0 then return nil end
    local function f(s)
        local x, y = BR.StormShape.pointAtArc(a, s)
        return BR.StormShape.distance(b, x, y)
    end

    -- The uniform grid, with the seed inserted at its own place in arc order so
    -- that the sign-change scan below is one pass over a sorted list.
    local n = max(8, #a.pieces * CROSS_PER_PIECE)
    local step = P / n
    local bc = BR.StormShape.discFor(b)
    local seed = BR.StormShape.nearestArc(a, bc.x, bc.y) % P
    local at = math.floor(seed / step) + 1
    local ss = {}
    for i = 1, n do
        ss[#ss + 1] = step * (i - 1)
        if i == at then ss[#ss + 1] = seed end
    end

    local vs = {}
    for i = 1, #ss do vs[i] = f(ss[i]) end

    -- ═══ AND THEN EVERY INTERVAL THAT COULD STILL HIDE A LENS IS SPLIT ═══
    --
    -- `f` IS 1-LIPSCHITZ IN ARC LENGTH, which is what makes this exact rather than
    -- a finer guess: a signed distance is 1-Lipschitz in the point, and a point on
    -- a boundary moves at most one metre per metre of arc length. So across an
    -- interval of width w with endpoint values p and q, every value inside is at
    -- least max(p - t, q - (w - t)), whose own minimum over t is (p + q - w) / 2.
    --
    -- Therefore: p + q >= w PROVES there is no crossing inside, for any shape, at
    -- any scale. An interval that fails that test is subdivided; one that passes is
    -- finished. Both endpoints must be positive to be asked at all -- an interval
    -- with a negative end is already bracketing a crossing, and the scan below will
    -- find it.
    --
    -- WHICH IS WHY THE SAMPLE DENSITY ABOVE IS A COST DECISION AND NOT A
    -- CORRECTNESS ONE. In the ordinary overlap this loop evaluates nothing: the
    -- intervals near the crossings have a negative end and the rest are far enough
    -- out that one subtraction clears them. It earns its keep at near-tangency,
    -- where the lens is shorter than the step and the old answer was to draw two
    -- loops and hope nobody looked at the waist.
    local spent = 0
    local i = 1
    while i <= #ss and spent < CROSS_REFINE_MAX do
        local j = (i % #ss) + 1
        local w = ss[j] + ((j == 1) and P or 0.0) - ss[i]
        if vs[i] >= 0.0 and vs[j] >= 0.0 and (vs[i] + vs[j]) < w then
            local mid = ss[i] + w * 0.5
            spent = spent + 1
            -- INSERTED RATHER THAN RECURSED, so the scan below stays one pass over
            -- one ordered list and `i` is not advanced -- the left half is re-tested
            -- on the next turn of this same loop, and the right half after it.
            --
            -- NOT WRAPPED BACK INTO [0, P). The last interval is the one that
            -- straddles arc length zero, so its midpoint is legitimately past P, and
            -- past P is exactly where it has to sit for the list to stay ascending.
            -- Every consumer wraps: f through pointAtArc, and bisectCross's answer
            -- through crossings' own return.
            table.insert(ss, i + 1, mid)
            table.insert(vs, i + 1, f(mid))
        else
            i = i + 1
        end
    end

    -- EXACTLY ONE OF EACH, OR NOTHING. Convexity says a proper overlap has one
    -- entry and one exit; anything else is a shape this cannot stitch honestly --
    -- a tangency counted twice, or a scan that landed on a boundary value -- and
    -- the two-component fallback is a picture rather than a guess.
    local m = #ss
    local sIn, sOut, nIn, nOut = nil, nil, 0, 0
    for ia = 1, m do
        local ib = (ia % m) + 1
        local lo = ss[ia]
        local hi = ss[ib] + ((ib == 1) and P or 0.0)
        if vs[ia] >= 0.0 and vs[ib] < 0.0 then
            nIn = nIn + 1
            sIn = bisectCross(f, lo, hi, false)
        elseif vs[ia] < 0.0 and vs[ib] >= 0.0 then
            nOut = nOut + 1
            sOut = bisectCross(f, lo, hi, true)
        end
    end
    if nIn ~= 1 or nOut ~= 1 then return nil end
    return sIn % P, sOut % P
end

--- The two boundaries as ONE closed loop, or nil when they do not properly cross.
---
--- A's boundary outside B, then B's boundary outside A. THE PRIMS AND THE PARTS
--- ARE THE SAME ONES THE TWO-COMPONENT SPELLING HANDS SEAL, so nothing downstream
--- can tell the two apart except by walking -- which is the only thing that
--- changed.
---
--- ═══ BOTH KEPT RUNS ARE CHECKED AT THEIR MIDPOINT, AND THAT IS NOT BELT AND
---     BRACES ═══
---
--- Which crossing is the entry and which the exit is an argument about winding
--- (see the header), and an argument is a thing that can be wrong. A run kept on
--- the wrong side of it would be the OPPOSITE of the defect being fixed -- the
--- swallowed stretches drawn and the outer ones dropped -- and it would look
--- plausible on a map. Two signed distances say which side the runs are really on,
--- and a disagreement falls back to the two-component boundary instead of drawing
--- a loop nobody can account for.
--- @return table|nil shape
local function stitch(a, b)
    -- THE BOUNDING CIRCLES FIRST. One subtraction answers every disjoint pair,
    -- which on a breakout phase is most of them -- see boundRadius.
    local ac, bc = BR.StormShape.discFor(a), BR.StormShape.discFor(b)
    local dx, dy = bc.x - ac.x, bc.y - ac.y
    if sqrt(dx * dx + dy * dy) > boundRadius(a) + boundRadius(b) then return nil end

    local sIn, sOut = crossings(a, b)
    if not sIn then return nil end

    local Pa, Pb = a.P, b.P
    -- FROM WHERE IT LEAVES B, FORWARD TO WHERE IT ENTERS B. The set of A's
    -- boundary inside B is one connected run, so its complement is the one run
    -- this names -- which is why no classification of the pieces is needed.
    local la = (sIn - sOut) % Pa
    if la <= 0.0 then return nil end

    local xIn,  yIn  = BR.StormShape.pointAtArc(a, sIn)
    local xOut, yOut = BR.StormShape.pointAtArc(a, sOut)
    -- THE CROSSINGS ARE POINTS ON BOTH BOUNDARIES, so B's parameters are read off
    -- them exactly rather than searched for a second time: nearestArc is exact
    -- from the piece list, and the point it is handed is already on B.
    local tOut = BR.StormShape.nearestArc(b, xIn, yIn)
    local tIn  = BR.StormShape.nearestArc(b, xOut, yOut)
    local lb = (tIn - tOut) % Pb
    if lb <= 0.0 then return nil end

    local mx, my = BR.StormShape.pointAtArc(a, sOut + la * 0.5)
    if BR.StormShape.distance(b, mx, my) < 0.0 then return nil end
    local nx, ny = BR.StormShape.pointAtArc(b, tOut + lb * 0.5)
    if BR.StormShape.distance(a, nx, ny) < 0.0 then return nil end

    local pieces = sliceOf(a, sOut, la)
    local bs = sliceOf(b, tOut, lb)
    for i = 1, #bs do pieces[#pieces + 1] = bs[i] end
    if #pieces < 2 then return nil end

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
    local one = stitch(a, b)
    if one then return one end

    -- ONE BLOB SWALLOWED THE OTHER, WHICH IS zone()'s NESTED CASE ARRIVING LATE.
    -- Asked only once stitch() has declined, so the ordinary overlap never pays
    -- for it and a disjoint pair pays one signed distance. See convexInside.
    if convexInside(a, b) then return b end
    if convexInside(b, a) then return a end

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

    -- ═══ FOR A BLOB IT IS ONE SUBTRACTION AND IT IS THE TRUE EROSION ═══
    --
    -- Eroding a convex body by d subtracts d from its support function, and this
    -- shape's support function is `max_i <c_i, u> + cr` -- so the eroded shape is
    -- the SAME CORNER CENTRES with `cr - d`. Every straight run moves in by d
    -- because it is straight, every corner arc keeps its centre and loses d of
    -- radius, and there is nothing to approximate. Not a scaled-down blob: a blob
    -- of radius r - d would pull its corner centres toward the middle as well,
    -- which is a smaller shape rather than an eroded one.
    --
    -- WHEN THE CORNERS ARE EATEN, THE INSCRIBED CIRCLE IS THE ANSWER. An erosion
    -- deeper than the corner radius wants the centre polygon shrunk too, which is
    -- a polygon offset and a different algorithm -- so instead this hands back the
    -- circle inscribed in the eroded shape, centred where the blob was built. That
    -- is a SUBSET of the true erosion, so it errs INWARD, which is the direction
    -- this whole function is allowed to err in. It is reachable at about 34 m of
    -- zone radius against the renderer's six of edgeInset: the last seconds of the
    -- final sweep, where the shape is smaller than one quad of the wall drawing it.
    if kind == 'blob' then
        local h, m = shape.hull, shape.blob
        local cr = h.cr - metres
        if cr >= MIN_RADIUS then
            -- FRESH CENTRE TABLES, because stampNormals writes onto them and the
            -- shape being eroded is still live -- the wall insets the zone the HUD
            -- is measuring against on the same frame.
            local cs = {}
            for i = 1, #h.cs do
                cs[i] = { x = h.cs[i].x, y = h.cs[i].y }
            end
            stampNormals(cs)
            return hullOf(cs, cr, {
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
