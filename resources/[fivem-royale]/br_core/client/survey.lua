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
-- authored with /brcoords: he makes the gesture, and the tool prints something
-- that can be pasted without retyping a number.
--
-- IT DIFFERS FROM /brcoords IN ONE WAY THAT MATTERS. /brcoords reads the ped, so
-- its points are places a player stood and its z values are real. A boundary
-- runs through water, cliff faces and restricted airspace -- places nobody can
-- stand -- so these points are picked off the MAP instead, and they carry NO z.
-- A z read from a map pick is the blip's altitude, which is not the terrain's,
-- and a boundary test has no use for it anyway: every POI test in this project
-- is planar because the POI radius is.
--
-- ═══ THE LINE IS A GPS CUSTOM ROUTE, WHICH THIS CODEBASE ALREADY PROVED ═══
--
-- He asked for lines, and asked the right follow-up when the first cut of this
-- file beaded them out of radius blips instead: "Then how do we draw the lines
-- for the bus route?"
--
-- WE DRAW THEM WITH StartGpsCustomRoute, IN client/bus.lua, TODAY. The Battle
-- Bus flight path is a real solid line on the map and the radar, and it is the
-- RACE-CREATOR AIR-ROUTE line: straight point-to-point segments, drawn anywhere,
-- over ocean and cliff alike, with no pathfinding whatsoever. Same natives here,
-- same order, same thicknesses.
--
-- THE FOUR THAT DO NOT WORK, so nobody re-walks this:
--
--   DrawLine            world space. It draws into the 3D scene, so it is
--                       invisible on a map screen.
--   DrawLine2d          screen space, drawn UNDER the pause menu rather than
--                       into the map.
--   SetBlipRoute        GTA's GPS line, which FOLLOWS ROADS. Pause-map
--                       rendering is separately unreliable upstream.
--   the MULTI route     StartGpsMultiRoute. Looks like the answer and is not:
--                       it still runs GPS pathfinding, so it snaps every
--                       segment to the road network and draws NOTHING over open
--                       country. bus.lua hit exactly this on 2026-08-04 and the
--                       CUSTOM route is what it moved to.
--
-- ~90 points is proven fine in bus.lua with no documented native point cap, and
-- a boundary is "a dozen or two", so there is no resampling here and no budget
-- to respect. The earlier "point budget" theory is recorded there as a
-- misdiagnosis of the multi-route's road-snapping.
--
-- ═══ THERE IS ONLY ONE CUSTOM ROUTE, AND THE BUS OWNS IT ═══
--
-- The natives take NO HANDLE -- StartGpsCustomRoute / AddPointToGpsCustomRoute /
-- SetGpsCustomRouteRender / ClearGpsCustomRoute are all singular. So there is
-- exactly one, a second Start REPLACES the first, and two consequences follow
-- that this file has to handle rather than discover in a playtest:
--
--   1. THE SURVEY MUST NEVER CLOBBER THE BUS. /brsurvey REFUSES TO ARM while
--      BR.BusLine.drawn(), and says so on the console. If a route arrives
--      mid-survey -- a match starting under him -- the survey stands its own
--      line down within a tick and puts it back when the bus line goes. The
--      points and the numbered blips are untouched throughout: nothing he
--      authored is ever lost to this, only the line is.
--
--   2. THE GAP CANNOT BE A SECOND ROUTE IN A SECOND COLOUR. One route means one
--      colour. So the closing run is beaded instead -- see `gapBeads`.
--
-- ═══ THE GESTURE IS ALREADY TAKEN TOO ═══
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

--- The route's HUD colour, and its radar and map line thicknesses. ALL THREE ARE
--- bus.lua's, UNCHANGED AND DELIBERATELY SO: 0 is pure white and 16/16 is what
--- the flight path is drawn at, which makes them the only values in this project
--- proven to render on this build. The HUD colour enum is not otherwise verified
--- here, and guessing an index to get a prettier line risks landing on purple,
--- which belongs to the storm alone (user call, 2026-08-04). The survey line and
--- the bus line can never be up at the same time -- see the refusal above -- so
--- sharing a colour costs nothing.
local ROUTE_COLOUR    = 0
local ROUTE_RADAR_W   = 16
local ROUTE_MAP_W     = 16

--- The z every route point is given. The native demands one; a top-down map does
--- not use it. bus.lua's own fallback rather than 0.0, for the same reason as
--- the colour: it is the value already proven to draw here.
local ROUTE_Z = 200.0

--- The closing run's beads -- radius blips, the same thing /brpois shades a POI
--- disc with. ONE EDGE ONLY, so this stays small; MAX_GAP_BEADS is a ceiling on
--- the blip pool for the pathological case of two points at opposite corners of
--- the map, not a tuning knob.
local BEAD_SPACING   = 140.0
local BEAD_RADIUS    = 45.0
local BEAD_ALPHA     = 160
local MAX_GAP_BEADS  = 120

--- GTA blip colours. NEVER PURPLE, in any slot: purple belongs to the storm
--- alone, and this overlay will be read on top of it.
local COLOUR_GAP    = 1   -- red:    the run that would close the ring, still open
local COLOUR_VERTEX = 5   -- yellow: a captured point
local COLOUR_START  = 3   -- blue:   point 1, the one the ring has to come back to

-- ───────────────────────────────────────────────────────────────────── state ---

local armed     = false   -- is the waypoint gesture ours right now
local pts       = {}      -- ordered vertices: { { x = , y = }, ... }
local blips     = {}      -- vertex blips and gap beads; everything we own
local lineDrawn = false   -- have WE got the custom route right now
local yielded   = false   -- our line is down because the bus took the route

--- Sprite-8 blips that are NOT the player's waypoint -- see `resnapshot`.
local known = {}

-- ─────────────────────────────────────────────────────────────────── helpers ---

--- A FiveM BOOL. `0` is truthy in Lua and this project has shipped that bug
--- seven times; IsWaypointActive and DoesBlipExist are both declared BOOL, and
--- IsWaypointActive is the exact shape that failed a commit here on 2026-08-28.
local function yes(v) return v == true or v == 1 end

--- Call a native that may not be bound on this build, without taking the tool
--- down with it. ShowNumberOnBlip is not probed in client/natives.lua, and a
--- measuring tool that throws before it draws a thing is worse than none --
--- /brprobe has already been exactly that once (owner, 2026-08-16).
local function safeCall(fn, ...)
    if type(fn) ~= 'function' then return end
    pcall(fn, ...)
end

--- Is the Battle Bus drawing its flight path right now? Nil-guarded at the call
--- site, so load order between this file and client/bus.lua cannot matter.
local function busOwnsRoute()
    return (BR.BusLine and BR.BusLine.drawn and BR.BusLine.drawn()) and true or false
end

--- Distance from the last point back to the first, or nil below two points.
local function gap()
    local n = #pts
    if n < 2 then return nil end
    return BR.Dist(pts[n].x, pts[n].y, pts[1].x, pts[1].y)
end

--- Is the ring closed? False below three points -- two points are a line
--- segment, and a segment that doubles back on itself is not a shape however
--- close its ends are.
local function closed()
    local g = gap()
    return (#pts >= 3) and g ~= nil and g <= CLOSE_M
end

--- Total length of the ring INCLUDING the closing run.
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

--- Take our line off the map.
---
--- GUARDED ON `lineDrawn`, exactly as bus.lua's clearCrumbs is guarded on
--- `routeDrawn`: ClearGpsCustomRoute is global, so calling it when the route is
--- somebody else's would erase the bus's flight path from a dev tool's teardown.
local function clearLine()
    if not lineDrawn then return end
    ClearGpsCustomRoute()
    lineDrawn = false
end

--- Draw the outline as a REAL LINE. Same four calls in the same order as
--- bus.lua's drawCrumbs, which is the working reference on this build.
---
--- THE RING CLOSES ITSELF WHEN THE SHAPE DOES: point 1 is appended a second time
--- once the ends are within CLOSE_M, so a finished boundary draws as a closed
--- loop and an unfinished one draws as an open polyline with the missing span
--- beaded red. That is the hole indicator, and it costs one `if`.
local function drawLine()
    clearLine()
    if #pts < 2 then return end

    -- The bus is the game and this is a dev tool. If its line is up, ours does
    -- not go on the map at all -- see the one-route section at the top.
    if busOwnsRoute() then
        yielded = true
        return
    end
    yielded = false

    StartGpsCustomRoute(ROUTE_COLOUR, true, true)
    for i = 1, #pts do
        AddPointToGpsCustomRoute(pts[i].x, pts[i].y, ROUTE_Z)
    end
    if closed() then
        AddPointToGpsCustomRoute(pts[1].x, pts[1].y, ROUTE_Z)
    end
    SetGpsCustomRouteRender(true, ROUTE_RADAR_W, ROUTE_MAP_W)
    lineDrawn = true
end

--- Bead the closing run in red, because one custom route means one colour and
--- the gap has to be distinguishable from the outline some other way.
---
--- Nothing is drawn once the ring is closed -- at that point the route itself
--- closes and there is no gap left to mark. The ENDPOINTS ARE SKIPPED: the
--- vertex blips already sit there.
local function gapBeads()
    local n = #pts
    if n < 3 or closed() then return end

    local ax, ay, bx, by = pts[n].x, pts[n].y, pts[1].x, pts[1].y
    local len = BR.Dist(ax, ay, bx, by)
    if len < 1.0 then return end

    local spacing = BEAD_SPACING
    if (len / spacing) > MAX_GAP_BEADS then spacing = len / MAX_GAP_BEADS end

    local steps = math.max(1, math.floor(len / spacing))
    for k = 1, steps - 1 do
        local t = k / steps
        -- UNNAMED, deliberately. BR.Native.blipName's standing rule is that
        -- every blip we make gets a name because the legend is where a blip
        -- explains itself -- but that rule is written for the handful of blips a
        -- MATCH makes, and a legend row per bead would bury the legend rather
        -- than populate it. /brpois leaves its radius discs unnamed for the same
        -- reason and has done since it landed.
        blips[#blips + 1] = BR.Native.radiusBlip(
            nil, ax + (bx - ax) * t, ay + (by - ay) * t,
            BEAD_RADIUS, COLOUR_GAP, BEAD_ALPHA, nil)
    end
end

--- Rebuild everything this file puts on the map, from `pts`.
local function redraw()
    clearBlips()
    drawLine()
    if #pts == 0 then return end
    gapBeads()

    for i = 1, #pts do
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
        -- spot a point entered out of sequence. The line does not give this for
        -- free. Belt and braces: the legend name carries the same number, so an
        -- unbound native costs the numbering on the icons and nothing else.
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

    -- ── THE BUS CAN TAKE THE ROUTE OUT FROM UNDER US MID-SURVEY ──
    --
    -- A match starting while he is surveying fires BUS_ROUTE, and bus.lua's
    -- drawCrumbs would overwrite our line and then clear it as its own. So the
    -- survey yields within a tick and takes itself back when the bus is done.
    -- The points and the numbered blips never move; only the line does.
    if lineDrawn and busOwnsRoute() then
        clearLine()
        yielded = true
        print('[br_core] survey: the bus route took the map line -- points kept, line back when it clears')
    elseif yielded and not busOwnsRoute() then
        redraw()
        if lineDrawn then print('[br_core] survey: map line restored') end
    end

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
        print('             the RED beaded run on the map is that gap')
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
    if yielded then
        print('  NOTE: the map line is down -- the bus route has it')
    end
    rule()
end

-- ────────────────────────────────────────────────────────────────── commands ---

--- Arm the survey. Idempotent, and it does NOT discard points -- running it
--- again after /brsurveyoff resumes where he left off.
RegisterCommand('brsurvey', function()
    -- REFUSED WHILE THE BUS LINE IS UP, because arming would replace it. There
    -- is one custom route; see the top of this file. Refusing loudly is the
    -- honest version of a collision that would otherwise present as "the flight
    -- path disappeared" in somebody else's playtest.
    if busOwnsRoute() then
        print('[br_core] survey REFUSED -- the Battle Bus route is on the map')
        print('  There is only one GPS custom route and the bus has it. Arming now')
        print('  would erase the flight path. Try again once the drop is over.')
        return
    end

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
    print('  The white line is the outline. RED beads = the gap that would close it.')
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
    clearLine()
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
    clearLine()
    yielded = false
    known = {}
    print(('[br_core] survey OFF -- %d point(s) kept; /brsurveydump to print, /brsurvey to resume')
        :format(#pts))
    print('  the waypoint places squad markers again')
end, false)

-- A ROUTE LEFT RENDERING OUTLIVES THE RESOURCE. bus.lua carries the same
-- handler for the same reason: ClearGpsCustomRoute is the only way the line
-- comes off, and a /restart br_core with a survey up would leave a white
-- boundary drawn across everybody's map with nothing left alive to clear it.
AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then
        clearBlips()
        clearLine()
    end
end)
