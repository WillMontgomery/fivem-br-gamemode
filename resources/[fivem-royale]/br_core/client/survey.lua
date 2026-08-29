-- /brsurvey -- PICK THE MAP EDGE OFF THE PAUSE MAP AND WRITE THE BOUNDARY DOWN.
--
-- ═══ THE REQUEST ═══
--
-- Owner, 2026-08-28:
--
--   "we need to rope in these POIs - we have too many places where the storm
--    can end outside the map and in the ocean. My proposal (since you can't see
--    the map and its coords) is you make me a client-side command which, when
--    run, draws lines on the map between the player-selected waypoints which
--    already exist in our gamemode. I'll run it, then choose several (maybe a
--    dozen or two) waypoints, and when done I'll run another command which
--    prints all the coords. I'll use the lines on the map to help me draw a
--    full shape without any holes ideally, and even if it's not a circle you'll
--    have a rough idea of our boundaries - then you can remove any POIs which
--    are outside of those bounds. Sound good?"
--
-- ═══ WHY IT EXISTS ═══
--
-- BR.Config.Storm.mapAABB is a RECTANGLE -- (-3600, -3600) to (4500, 8000) --
-- and the island is not one. Every corner of that box is open water, so a final
-- circle sited in one is a final circle in the ocean, and a POI authored out
-- there is a POI the storm can push a match onto. That is the reported bug.
--
-- The playable shape cannot be derived from anything in this repository. It is a
-- fact about the map, and the only person here who can see the map is the owner.
-- So it gets AUTHORED, exactly the way BR.Config.Map.AmbulanceSpawns was
-- authored with /brcoords: he stands the tool up, makes the gesture, and the
-- tool prints something that can be pasted without retyping a number.
--
-- IT DIFFERS FROM /brcoords IN ONE WAY THAT MATTERS. /brcoords reads the ped, so
-- its points are places a player stood and its z values are real. A boundary
-- runs through water, cliff faces and restricted airspace -- places nobody can
-- stand -- so these points are picked off the MAP instead, and they carry NO z.
-- A z read from a map pick is the blip's altitude, which is not the terrain's,
-- and a boundary test has no use for it anyway: every POI test in this project
-- is planar because the POI radius is.
--
-- ═══ WHAT ACTUALLY DRAWS ON THE PAUSE MAP -- READ BEFORE "FIXING" THIS ═══
--
-- He asked for LINES. There is no native that draws one on the pause map.
--
--   DrawLine          world space. It draws into the 3D scene, so it is invisible
--                     on a map screen. This is the obvious first guess and it is
--                     wrong.
--   DrawLine2d        screen space, drawn UNDER the pause menu rather than into
--                     the map. Same answer.
--   SetBlipRoute      GTA's own GPS line, and it FOLLOWS ROADS. A boundary runs
--                     over ocean, cliffs and open country, where the pathfinder
--                     either detours to the nearest highway or gives up -- so
--                     the line it drew would not be the line he authored, which
--                     is worse than drawing nothing. Its pause-map rendering is
--                     separately unreliable and unresolved upstream.
--   DUI -> runtime    the real answer, and how third-party map-overlay resources
--   texture ->        do it: render the polygon into an offscreen browser,
--   MINIMAP_LOADER    convert it to a game texture, hang it on the minimap
--   ADD_SCALED_       scaleform. That is a SUBSYSTEM, and it is one the gamemode
--   OVERLAY           would then own forever in exchange for one afternoon of
--                     map authoring.
--
-- SO THE LINE IS BEADED, AND THIS COMMENT WILL NOT PRETEND OTHERWISE. Each edge
-- is a run of small radius blips -- AddBlipForRadius, a filled circle that does
-- render on the pause map, and already how /brpois shades a POI's disc. Spaced
-- at 140m with a 45m radius they read as a dotted line at map zoom: enough to
-- see the shape, and enough to see a hole in it, which is the whole job.
--
-- ═══ THE GESTURE IS ALREADY TAKEN, AND THAT IS THE HARD PART ═══
--
-- client/markers.lua's `markers.place` consumes ANY fresh waypoint while the
-- player is in a match, reads its coordinate, calls SetWaypointOff and turns it
-- into a squad ping -- "these are markers, not GPS", in its own words. This tool
-- wants the identical gesture, and they cannot both have it.
--
-- client/rescue.lua hit this first and settled it: markers.place stands down
-- while BR.Rescue.riding(). This follows that precedent exactly, which is why
-- BR.Survey.active() is the ONE thing this file exports -- markers.lua reads it,
-- nil-guarded, at call time. Nothing else here is public, because a measuring
-- tool with a namespace is scaffolding that later reads as an interface.
--
-- THE CONSEQUENCE IS A SURPRISING MODE AND IT IS DELIBERATE: while a survey is
-- armed, setting a waypoint does NOT place a squad ping. It appends a boundary
-- vertex. /brsurveyoff hands the gesture back.
--
-- ═══ THE GATE ═══
--
-- Console-only (the `false` on every RegisterCommand), and dev-gated the way
-- every other client dev command here is gated -- /brcoords, /brprobe,
-- /brattach: by being a bare RegisterCommand nobody is told about. A convar gate
-- is NOT available on this side; client/attachtune.lua carries the write-up.
-- sv_devMode and br_devMode are read in server/main.lua and are not replicated,
-- so a client GetConvar sees neither, and BR.Server does not exist in the client
-- Lua state at all. Copying that spelling produces a command that silently never
-- runs.
--
-- Nothing in the gamemode calls this file. It is /brprobe's argument applied to
-- geometry: MEASURE, then write the config -- not the other way round.

BR = BR or {}

--- THE ONLY EXPORT. See the gesture section above.
BR.Survey = BR.Survey or {}

-- ───────────────────────────────────────────────────────────────── constants ---

--- How close the last point must come to the first before the ring counts as
--- closed. 250m against a ~10km island is "the same corner of the map" -- tight
--- enough that a genuine hole still reads as open, loose enough that he does not
--- have to land a pixel-perfect click to finish.
local CLOSE_M = 250.0

--- The bead spacing and bead size, in metres. Spacing is the larger, so the dots
--- do not merge into a smear; the gap between them is 50m, which is under a
--- pixel of daylight at full pause-map zoom-out.
local DOT_SPACING = 140.0
local DOT_RADIUS  = 45.0

--- A CEILING ON THE BLIP POOL, not a tuning knob. GTA's blip pool is finite and
--- shared with everything else on the map -- loot, squadmates, the storm ring,
--- petrol stations. If the perimeter is long enough that DOT_SPACING would blow
--- through this, the spacing widens instead and the line gets dashier. 500 dots
--- over a 40km perimeter is 80m apart, so in practice DOT_SPACING governs and
--- this never fires.
local MAX_DOTS = 500

--- GTA blip colours. NEVER PURPLE, in any slot: purple belongs to the storm
--- alone (user call, 2026-08-04), and this overlay will be read on top of it.
local COLOUR_EDGE   = 2   -- green:  an edge he has authored
local COLOUR_GAP    = 1   -- red:    the run that would close the ring, still open
local COLOUR_VERTEX = 5   -- yellow: a captured point
local COLOUR_START  = 3   -- blue:   point 1, the one the ring has to come back to
local DOT_ALPHA     = 160

-- ───────────────────────────────────────────────────────────────────── state ---

local armed = false     -- is the waypoint gesture ours right now
local pts   = {}        -- ordered vertices: { { x = , y = }, ... }
local blips = {}        -- every blip this file owns, vertices and beads alike

--- Sprite-8 blips that are NOT the player's waypoint -- see `capture`.
local known = {}

-- ─────────────────────────────────────────────────────────────────── helpers ---

--- A FiveM BOOL. `0` is truthy in Lua and this project has shipped that bug
--- seven times; IsWaypointActive and DoesBlipExist are both declared BOOL, and
--- IsWaypointActive failed a commit on this repository earlier today.
local function yes(v) return v == true or v == 1 end

--- Call a native that may not be bound on this build, without taking the tool
--- down with it. ShowNumberOnBlip is not probed in client/natives.lua, and a
--- measuring tool that throws before it draws a thing is worse than none --
--- /brprobe has already been exactly that once (owner, 2026-08-16).
local function safeCall(fn, ...)
    if type(fn) ~= 'function' then return end
    pcall(fn, ...)
end

--- Distance from the last point back to the first, or nil below two points.
local function gap()
    local n = #pts
    if n < 2 then return nil end
    return BR.Dist(pts[n].x, pts[n].y, pts[1].x, pts[1].y)
end

--- Is the ring closed? Nil-safe, and false below three points -- two points are
--- a line segment, and a line segment that doubles back on itself is not a shape
--- however close its ends are.
local function closed()
    local g = gap()
    return (#pts >= 3) and g ~= nil and g <= CLOSE_M
end

--- Total length of the ring INCLUDING the closing run, which is the number the
--- bead spacing has to be budgeted against.
local function perimeter()
    local n = #pts
    if n < 2 then return 0.0 end
    local total = 0.0
    for i = 1, n do
        local j = (i % n) + 1
        total = total + BR.Dist(pts[i].x, pts[i].y, pts[j].x, pts[j].y)
    end
    return total
end

--- Axis-aligned bounding box over the captured points.
--- @return number, number, number, number  minx, miny, maxx, maxy
local function bbox()
    local minx, miny = pts[1].x, pts[1].y
    local maxx, maxy = pts[1].x, pts[1].y
    for i = 2, #pts do
        local p = pts[i]
        if p.x < minx then minx = p.x end
        if p.y < miny then miny = p.y end
        if p.x > maxx then maxx = p.x end
        if p.y > maxy then maxy = p.y end
    end
    return minx, miny, maxx, maxy
end

--- The polygon centroid and area, by the shoelace formula.
---
--- AREA-WEIGHTED, NOT THE MEAN OF THE VERTICES, and the difference is the whole
--- reason this is eight lines rather than three: the mean is dragged toward
--- wherever he happened to click densely, so a coastline picked at ten points
--- and a straight inland edge picked at two would report a centre well off to
--- the detailed side. The area-weighted centroid does not care how the outline
--- was sampled, only where it runs -- which is what "the middle of the playable
--- area" has to mean if a storm-centre sanity check is ever built against it.
---
--- Falls back to the vertex mean when the ring has no area (under three points,
--- or all of them collinear), and the caller says so in the printout rather than
--- reporting a weighted centroid it did not compute.
--- @return number, number, number, boolean  cx, cy, area m^2, wasWeighted
local function centroid()
    local n = #pts
    local a2, cx, cy = 0.0, 0.0, 0.0

    for i = 1, n do
        local j = (i % n) + 1
        local cross = (pts[i].x * pts[j].y) - (pts[j].x * pts[i].y)
        a2 = a2 + cross
        cx = cx + (pts[i].x + pts[j].x) * cross
        cy = cy + (pts[i].y + pts[j].y) * cross
    end

    if n >= 3 and math.abs(a2) > 1e-6 then
        return cx / (3.0 * a2), cy / (3.0 * a2), math.abs(a2) * 0.5, true
    end

    local sx, sy = 0.0, 0.0
    for i = 1, n do sx = sx + pts[i].x; sy = sy + pts[i].y end
    return sx / n, sy / n, 0.0, false
end

-- ───────────────────────────────────────────────────────────────── rendering ---

local function clearBlips()
    for _, b in ipairs(blips) do
        if yes(DoesBlipExist(b)) then RemoveBlip(b) end
    end
    blips = {}
end

--- Bead one edge. The ENDPOINTS ARE SKIPPED -- the vertex blips already sit
--- there, and a bead under a vertex only muddies which of the two he is looking
--- at.
local function beadEdge(ax, ay, bx, by, spacing, colour)
    local len = BR.Dist(ax, ay, bx, by)
    if len < 1.0 then return end

    local steps = math.max(1, math.floor(len / spacing))
    for k = 1, steps - 1 do
        local t = k / steps
        -- UNNAMED, deliberately. BR.Native.blipName's standing rule is that
        -- every blip we make gets a name because the legend is where a blip
        -- explains itself -- but that rule is written for the handful of blips a
        -- MATCH makes, and several hundred identical legend rows would bury the
        -- legend rather than populate it. /brpois leaves its radius discs
        -- unnamed for the same reason and has done since it landed.
        blips[#blips + 1] = BR.Native.radiusBlip(
            nil, ax + (bx - ax) * t, ay + (by - ay) * t,
            DOT_RADIUS, colour, DOT_ALPHA, nil)
    end
end

--- Rebuild every blip from `pts`.
---
--- A FULL REBUILD ON EVERY EDIT, rather than appending the one new edge. Two
--- reasons, and neither is laziness: radius blips cannot be moved or resized in
--- place (client/natives.lua says so at the top of its blip section), and the
--- bead spacing is derived from the WHOLE perimeter, so a point added at the far
--- end can change the spacing of every edge before it. A few hundred
--- AddBlipForRadius calls in one frame is a hitch he will not see on a pause
--- screen, and this is a dev command.
local function redraw()
    clearBlips()
    local n = #pts
    if n == 0 then return end

    -- Widen the spacing if -- and only if -- the honest spacing would overrun
    -- the blip budget. See MAX_DOTS.
    local spacing = DOT_SPACING
    local p = perimeter()
    if p > 0.0 and (p / spacing) > MAX_DOTS then
        spacing = p / MAX_DOTS
    end

    -- The edges first, so the vertex blips sit on top of their own beads.
    if n >= 2 then
        for i = 1, n - 1 do
            beadEdge(pts[i].x, pts[i].y, pts[i + 1].x, pts[i + 1].y,
                     spacing, COLOUR_EDGE)
        end

        -- THE CLOSING RUN IS THE HOLE INDICATOR. It is always drawn, so the ring
        -- on the map is always a complete loop -- and it is RED until the ends
        -- meet, so the red arc is precisely the span he has not authored yet.
        -- Once the gap is inside CLOSE_M it goes green and all but disappears,
        -- which is the shape being finished.
        beadEdge(pts[n].x, pts[n].y, pts[1].x, pts[1].y, spacing,
                 closed() and COLOUR_EDGE or COLOUR_GAP)
    end

    for i = 1, n do
        local b = AddBlipForCoord(pts[i].x, pts[i].y, 0.0)
        -- SPRITE 1, NOT SPRITE 8, AND THAT IS LOAD-BEARING. markers.lua finds
        -- the player's waypoint by walking the sprite-8 blips, and its own squad
        -- pings wear sprite 8 -- which is exactly the collision that had one
        -- marker deleting another (user, 2026-08-05). A survey vertex on sprite
        -- 8 would rejoin that pileup the moment /brsurveyoff handed the gesture
        -- back with the blips still up.
        SetBlipSprite(b, 1)
        SetBlipColour(b, i == 1 and COLOUR_START or COLOUR_VERTEX)
        SetBlipScale(b, 0.85)
        SetBlipAsShortRange(b, false)   -- a boundary is read zoomed out or not at all
        -- The number ON the blip, which is what makes the outline readable as an
        -- ORDER rather than a scatter -- he needs to see that 7 follows 6 to
        -- spot a point entered out of sequence. Belt and braces: the legend name
        -- carries the same number, so an unbound native costs the numbering on
        -- the icons and nothing else.
        safeCall(ShowNumberOnBlip, b, i)
        BR.Native.blipName(b, i == 1
            and 'Survey 1 (start)'
            or ('Survey %d'):format(i))
        blips[#blips + 1] = b
    end
end

-- ─────────────────────────────────────────────────────────────────── capture ---

--- Is a survey armed? READ BY client/markers.lua, which is otherwise about to
--- eat the gesture this tool runs on. Nil-safe at the call site, so load order
--- between the two files cannot matter.
--- @return boolean
function BR.Survey.active()
    return armed
end

--- WHOSE SPRITE-8 BLIP IS THAT?
---
--- The standard trick for finding the player's waypoint is GetFirstBlipInfoId(8)
--- -- 8 is the waypoint sprite. It is also the sprite markers.lua gives every
--- squad ping, deliberately, because a destination should look like a
--- destination. So on a live server the first sprite-8 hit is very often a
--- teammate's ping rather than the thing the owner just clicked, and capturing
--- it would silently write a teammate's marker into the boundary.
---
--- markers.lua solves this by remembering its own blip handles. This file cannot
--- see that table -- it is a file-local, and reaching for it would make two
--- subsystems share a private -- so it establishes the same fact from the other
--- end: WHENEVER NO WAYPOINT IS ACTIVE, every sprite-8 blip in the world belongs
--- to somebody else, by definition. Re-snapshotting on those frames keeps the
--- set current as teammates come and go, and the tick after a waypoint appears,
--- the one handle NOT in the set is it.
---
--- The single remaining hole is a teammate's ping arriving in the same 100ms
--- tick as the owner's click. /brsurveyundo exists partly for that.
local function resnapshot()
    known = {}
    local b = GetFirstBlipInfoId(8)
    while yes(DoesBlipExist(b)) do
        known[b] = true
        b = GetNextBlipInfoId(8)
    end
end

BR.Loop.register(BR.Loop.TICK, 'survey.capture', function()
    if not armed then return end

    if not yes(IsWaypointActive()) then
        resnapshot()
        return
    end

    local b = GetFirstBlipInfoId(8)
    while yes(DoesBlipExist(b)) and known[b] do
        b = GetNextBlipInfoId(8)
    end
    if not yes(DoesBlipExist(b)) then return end

    local c = GetBlipInfoIdCoord(b)
    -- Consume it immediately, exactly as markers.lua does: the flag has to be
    -- gone before he can place the next one, and leaving it up would have this
    -- pass capture the same point again on the next tick.
    SetWaypointOff()

    pts[#pts + 1] = { x = c.x + 0.0, y = c.y + 0.0 }
    redraw()

    local g = gap()
    print(('[br_core] survey: point %d at %.1f, %.1f%s'):format(
        #pts, c.x, c.y,
        g and (', %.0fm from point 1%s'):format(g, closed() and ' -- CLOSED' or '')
          or ''))
end)

-- ────────────────────────────────────────────────────────────────── printout ---

local function rule()
    print('--------------------------------------------------------------')
end

--- Everything the boundary work needs, in one block he can copy in one go.
local function dump()
    local n = #pts
    rule()
    if n == 0 then
        print('[br_core] survey: no points captured')
        print('  /brsurvey, then set a waypoint on the pause map for each vertex')
        rule()
        return
    end

    print(('[br_core] survey: %d point(s)%s'):format(n, armed and '' or ' (stopped)'))
    print('')
    print('  -- paste into br_lib/config/map.lua')
    print('  {')
    for i = 1, n do
        print(('      { x = %9.1f, y = %9.1f },   -- %d'):format(pts[i].x, pts[i].y, i))
    end
    print('  }')
    print('')

    -- CLOSED OR NOT, IN METRES AND NOT AS A VERDICT ALONE. "no" on its own does
    -- not say whether he is 90m short or 4km short, and those are a keystroke
    -- and an afternoon respectively.
    local g = gap()
    if n < 3 then
        print(('  closed     no -- %d point(s); a ring needs at least 3'):format(n))
    elseif closed() then
        print(('  closed     YES -- point %d is %.0fm from point 1 (threshold %.0fm)')
            :format(n, g, CLOSE_M))
    else
        print(('  closed     no -- point %d is %.0fm from point 1 (threshold %.0fm)')
            :format(n, g, CLOSE_M))
        print('             the RED run on the map is that gap')
    end

    local cx, cy, area, weighted = centroid()
    local minx, miny, maxx, maxy = bbox()

    print(('  perimeter  %.2f km (closing run included)'):format(perimeter() / 1000.0))
    if weighted then
        print(('  area       %.2f km^2'):format(area / 1000000.0))
        print(('  centroid   %.1f, %.1f   (polygon, area-weighted)'):format(cx, cy))
    else
        print( '  area       n/a -- the points have no enclosed area yet')
        print(('  centroid   %.1f, %.1f   (mean of vertices; no area to weight by)')
            :format(cx, cy))
    end
    print(('  bbox       x %.1f .. %.1f    y %.1f .. %.1f'):format(minx, maxx, miny, maxy))
    print(('             %.0fm wide, %.0fm tall, centre %.1f, %.1f')
        :format(maxx - minx, maxy - miny, (minx + maxx) * 0.5, (miny + maxy) * 0.5))
    -- The box this is meant to replace, printed beside it so the two are
    -- comparable without going and looking it up. If the survey's bbox is not
    -- comfortably inside the AABB, one of them is wrong.
    local aabb = BR.Config and BR.Config.Storm and BR.Config.Storm.mapAABB
    if aabb and aabb.min and aabb.max then
        print(('  vs mapAABB x %.1f .. %.1f    y %.1f .. %.1f')
            :format(aabb.min.x, aabb.max.x, aabb.min.y, aabb.max.y))
    end
    rule()
end

-- ────────────────────────────────────────────────────────────────── commands ---

--- Arm the survey. Idempotent, and it does NOT discard points -- running it
--- again after /brsurveyoff resumes where he left off.
RegisterCommand('brsurvey', function()
    local was = armed
    armed = true

    -- CONSUME ANY WAYPOINT STANDING FROM BEFORE THE SURVEY, and this is not
    -- tidiness. resnapshot records every sprite-8 blip that exists right now as
    -- "somebody else's" -- so a waypoint left up at arming time goes into
    -- `known`. GTA pools blip handles, so the next waypoint he sets can come
    -- back on that same number, be recognised as known, and be skipped. For
    -- ever, silently, with the tool capturing nothing and saying nothing, which
    -- is the worst failure available here. Clearing it first means a waypoint
    -- handle can never enter the set at all: after this line the set is only
    -- ever rebuilt on ticks where no waypoint is active.
    if yes(IsWaypointActive()) then SetWaypointOff() end

    resnapshot()
    redraw()

    rule()
    if was then
        print(('[br_core] survey already running -- %d point(s)'):format(#pts))
    elseif #pts > 0 then
        print(('[br_core] survey RESUMED at %d point(s)'):format(#pts))
    else
        print('[br_core] survey ON')
    end
    print('  Set a waypoint on the pause map for each boundary corner, in order.')
    print('  WHILE THIS IS ON, A WAYPOINT DOES NOT PLACE A SQUAD MARKER.')
    print('  Green beads = an edge. RED beads = the gap that would close the ring.')
    print('')
    print('  /brsurveyundo    drop the last point')
    print('  /brsurveydump    print the coords (keeps going)')
    print('  /brsurveyclear   throw the points away and start over')
    print('  /brsurveyoff     stop; the waypoint places squad markers again')
    rule()
end, false)

RegisterCommand('brsurveyundo', function()
    if #pts == 0 then
        print('[br_core] survey: nothing to undo')
        return
    end
    local p = table.remove(pts)
    redraw()
    print(('[br_core] survey: dropped point %d (%.1f, %.1f) -- %d left')
        :format(#pts + 1, p.x, p.y, #pts))
end, false)

--- Throw the points away.
---
--- IT PRINTS THEM FIRST. A dozen or two hand-picked points is an afternoon on
--- the pause map, and the difference between /brsurveyclear and /brsurveyoff is
--- one word at a console. If the wrong one gets typed the coordinates are still
--- in the scrollback.
RegisterCommand('brsurveyclear', function()
    if #pts > 0 then
        print('[br_core] survey: clearing -- the points as they stood:')
        dump()
    end
    pts = {}
    clearBlips()
    print(('[br_core] survey cleared%s'):format(armed and ' (still ON)' or ''))
end, false)

RegisterCommand('brsurveydump', dump, false)

--- Stop capturing and take the overlay down. THE POINTS SURVIVE -- see
--- /brsurveyclear for why the two are separate commands.
RegisterCommand('brsurveyoff', function()
    if not armed and #pts == 0 then
        print('[br_core] survey is not running')
        return
    end
    armed = false
    clearBlips()
    known = {}
    print(('[br_core] survey OFF -- %d point(s) kept; /brsurveydump to print, /brsurvey to resume')
        :format(#pts))
    print('  the waypoint places squad markers again')
end, false)
