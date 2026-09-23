-- The shared minimap overlay handle, and the filled polygons drawn through it.
--
-- ═══ THE SPIKE SAID YES, SO THIS HAS A CALLER NOW (#347 -> #350) ═══
--
-- The one question was whether ADD_AREA_OVERLAY actually fills a polygon on the
-- radar and on the pause map -- nobody ships that method, and across GitHub the
-- only hits are ScaleformUI itself, its docs and its C# demo. It was answered by
-- drawing one hard-coded concave shape through it and looking at it (/brmaparea,
-- client/debug.lua): the arrowhead drew on the big map AND on the minimap with its
-- notch intact.
--
-- So the storm draws its real boundary here. client/storm.lua's `storm.map`
-- callback owns WHAT is drawn and WHEN -- the shape walk, the rebuild cadence, the
-- suppression rules, the radius-blip fallback -- and this file still owns only the
-- handle, the indices and the marshalling. THE DIVISION IS THE SAME ONE THE SPIKE
-- HAD, because it is the one that survives the fallback: a client whose gate never
-- opens gets radius blips from storm.lua and this file simply never draws.
--
-- ═══ THE HANDLE IS NOT OURS TO CREATE ═══
--
-- AddMinimapOverlay resolves its path against the CALLING resource, so calling
-- it from br_core would look for br_core/files/MINIMAP_LOADER.gfx and find
-- nothing. The movie lives in ScaleformUI_Assets, which owns exactly one handle
-- for the whole client and hands it out on the ScUI:AddMinimapOverlay event.
-- That event is the only route in and this file uses it. A client-side
-- TriggerEvent reaches handlers in every resource, which is how the vendored
-- library itself gets the handle.
--
-- ═══ WHAT THE HANDLE BEING SHARED COSTS US ═══
--
--   * The movie's `overlays` array is shared with ScaleformUI. ADD_AREA_OVERLAY
--     returns nothing; the new clip's index is the array's LENGTH BEFORE the
--     push, so the index has to be counted on this side -- see nextIndex().
--   * REM_OVERLAY splices, so every index above the one removed shifts down by
--     one. removeAll() therefore removes highest-first and renumbers nothing,
--     because there is nothing left to renumber.
--   * CLEAR_ALL is never called and is not wrapped in client/natives.lua. It
--     would delete ScaleformUI's overlays too, and their own `minimaps` table
--     would go on reporting clips that are no longer in the movie.
--
-- ═══ AND WHY THE READINESS GATE IS NOT OPTIONAL ═══
--
-- ADD_MINIMAP_OVERLAY racing RELOAD_MAP_STORE crashes gta-streaming-five.dll
-- (citizenfx/fivem#4167, still open). That matters here more than it would in
-- most projects, because an in-game logout in this gamemode re-mints a token
-- and signs the player back in -- a deliberate feature the owner likes -- so
-- join is re-run in normal play and the race is reachable without a cold boot.
-- A crash on login is the one outcome worse than this feature not working.
--
-- So nothing here asks for the handle until NetworkIsGameInProgress and
-- IsMinimapRendering have BOTH been true for a few seconds, and nothing draws
-- until HasMinimapOverlayLoaded has agreed for a few frames after that.
-- `MinimapOverlays.isLoaded` is NOT the test -- it is permanently false in this
-- vendored copy and the BR-PATCH 2 note in ScaleformUI.lua says why.
--
-- WHAT THAT GATE BOUGHT, AND WHAT #348 THEN FIXED BESIDE IT: this gate keeps OUR
-- call off the race and could never move ScaleformUI's, which called
-- MinimapOverlays:Load() at br_core's start and retried at 2 Hz with no session
-- test at all -- so ADD_MINIMAP_OVERLAY ran once per client, at join, ungated, and
-- in-game logout re-auth re-runs join in ordinary play. That is vendored code and
-- it now carries BR-PATCH 5 gating both of its own calls on the same two
-- conditions this file waits for. The two gates are deliberately separate: theirs
-- is in their file because it is their call, and neither one can be deleted on the
-- strength of the other.

BR = BR or {}
BR.MapOverlay = {}

-- The wider of the two shared BOOL policies, matching the alias every other
-- client file uses. HasMinimapOverlayLoaded is declared BOOL and 0 is truthy in
-- Lua, so a bare `while not HasMinimapOverlayLoaded(h)` would stop waiting
-- immediately on a build that answers 0 -- the exact shape of fault
-- tools/check_bool_natives.lua exists to count.
local isTrue = BR.NativeTruthy

--- How long both session gates must hold before we touch the overlay natives.
---
--- THREE SECONDS IS A GUESS AND IS LABELLED AS ONE. #4167 is a race with no
--- published window; the issue thread's own advice is "wait until the session
--- is up". If a crash ever happens here this number is the first thing to
--- raise, and the second is whether waiting is the right mechanism at all.
local SETTLE_MS = 3000

--- Frames HasMinimapOverlayLoaded must keep agreeing after it first says yes.
---
--- The vendored Load() waits for that native and then immediately calls
--- SetMinimapOverlayDisplay on the same frame. This waits longer on purpose:
--- "loaded" is the movie being resident, not the movie having run its
--- INITIALISE, and a method called before INITIALISE has built CONTENT.minimap
--- pushes parameters at a clip that does not exist yet.
local READY_FRAMES = 10

--- How often to re-fire ScUI:AddMinimapOverlay while nobody has answered.
---
--- IT HAS TO RETRY, BECAUSE THE ANSWER COMES FROM ANOTHER RESOURCE. If
--- ScaleformUI_Assets has not registered its handler yet -- or is not started at
--- all -- the first fire reaches nobody and no error is raised anywhere: a
--- client-side TriggerEvent with no listener is silence. Asking once would leave
--- this permanently stuck with nothing to read but "waiting".
---
--- AND 2 Hz RATHER THAN PER FRAME, which is the vendored library's own BR-PATCH
--- 2 lesson recorded in ScaleformUI.lua: the version of this retry that ran
--- every frame fired a cross-resource event sixty times a second, for the whole
--- session, whether anybody wanted an overlay or not.
local ASK_RETRY_MS = 500

local state = {
    phase   = 'idle',   -- idle | settling | asking | loading | ready
    handle  = nil,      -- the shared overlay handle, once ScaleformUI_Assets answers
    bothAt  = 0,        -- GetGameTimer() when the two session gates first agreed
    frames  = 0,        -- consecutive frames HasMinimapOverlayLoaded has said yes
    asked   = false,    -- the event has been fired at least once
    askedAt = 0,        -- GetGameTimer() of the last fire
    ours    = {},       -- the movie indices we added, in the order we added them
    set     = {},       -- the indices the last setAreas added, in ITS order; see placeArea
    chars   = 0,        -- coordinate characters in the last setAreas push
    moves   = 0,        -- areas placed in place rather than rebuilt, all session
    why     = 'not started',
}

-- ------------------------------------------------------------------ indices ---

--- The index the movie will give the NEXT overlay anybody adds.
---
--- ADD_AREA_OVERLAY hands nothing back, so this is arithmetic rather than a
--- read: the clip's index is `overlays.length` at the moment of the push, and
--- that array holds ScaleformUI's overlays and ours together. Theirs are
--- counted out of their own bookkeeping table; ours are counted here, because
--- they have no idea we exist.
---
--- NOTHING IN THIS PROJECT ADDS A SCALEFORMUI OVERLAY TODAY -- the library's
--- Add*OverlayToMap functions are called only from its example.lua, which
--- BR-PATCH 1 in its manifest keeps unloaded -- so in practice this answers 0
--- for the spike's first area. It is still written as a sum rather than as a
--- count of ours, because the day a menu adds a sized overlay is not a day
--- anybody will remember this file exists.
--- @return integer
local function nextIndex()
    local theirs = 0
    local sf = rawget(_G, 'ScaleformUI')
    local mm = sf and sf.Scaleforms and sf.Scaleforms.MinimapOverlays
    if mm and type(mm.minimaps) == 'table' then theirs = #mm.minimaps end
    return theirs + #state.ours
end

-- ---------------------------------------------------------------- readiness ---

--- Advance the readiness gate by one frame and say where it got to.
---
--- A STEP RATHER THAN A THREAD, and that is what makes the lifecycle testable:
--- tools/test_client.lua drives this directly with the two session gates and
--- HasMinimapOverlayLoaded under its control, which is the only way to assert
--- that the crash gate actually refuses. The waiting itself is the caller's --
--- /brmaparea runs this in a Citizen thread and nothing else calls it, so this
--- file costs nothing per frame when it is not in use.
--- @return boolean ready
--- @return string  why  what it is waiting for, for the console
function BR.MapOverlay.step()
    -- READY IS STICKY, DELIBERATELY. The call this whole gate exists to keep off
    -- the crash is the handle ACQUISITION -- ADD_MINIMAP_OVERLAY racing
    -- RELOAD_MAP_STORE -- and by the time this line can be reached that has
    -- already happened, once, from behind the gate. Re-testing the session every
    -- pass afterwards would make ready() flap whenever the radar goes off screen
    -- for a cutscene, without making anything safer: a handle whose movie is gone
    -- is refused by CallMinimapScaleformFunction, and that answer is read.
    if state.phase == 'ready' then return true, 'ready' end

    -- ═══ GATE ONE: IS THERE A SESSION, AND IS THE MAP ON SCREEN ═══
    --
    -- Both, and both continuously. If either drops -- a session ending, the
    -- radar hidden for a cutscene -- the settle clock restarts, because the
    -- thing being waited out is the streaming that follows arrival and arrival
    -- can happen again.
    local inGame = isTrue(NetworkIsGameInProgress())
    local drawn  = isTrue(IsMinimapRendering())
    if not (inGame and drawn) then
        state.bothAt = 0
        state.frames = 0
        state.phase  = 'settling'
        state.why    = not inGame and 'waiting for the session (NetworkIsGameInProgress)'
            or 'waiting for the radar (IsMinimapRendering)'
        return false, state.why
    end

    if state.bothAt == 0 then state.bothAt = GetGameTimer() end
    local held = GetGameTimer() - state.bothAt
    if held < SETTLE_MS then
        state.phase = 'settling'
        state.why   = ('settling after join -- %dms of %dms'):format(held, SETTLE_MS)
        return false, state.why
    end

    -- ═══ GATE TWO: THE HANDLE, WHICH IS SOMEBODY ELSE'S TO GIVE ═══
    if not state.handle then
        local now = GetGameTimer()
        if (not state.asked) or (now - state.askedAt) >= ASK_RETRY_MS then
            state.asked   = true
            state.askedAt = now
            state.phase   = 'asking'
            -- The callback may run on this frame or a later one. loader.lua
            -- caches its handle and calls back synchronously, so once
            -- ScaleformUI_Assets is up this returns on the same frame -- but the
            -- code is written not to depend on that, because the contract is a
            -- callback and not a return value.
            TriggerEvent('ScUI:AddMinimapOverlay', function(handle)
                -- -1 IS loader.lua's OWN "not yet" SENTINEL and 0 is the
                -- engine's "no such overlay". Neither is a handle, and storing
                -- either would send every method call after this into nothing.
                if handle and handle ~= 0 and handle ~= -1 then
                    state.handle = handle
                end
            end)
        end
        if not state.handle then
            state.phase = 'asking'
            state.why   = 'waiting for ScUI:AddMinimapOverlay to answer with a handle'
            return false, state.why
        end
    end

    -- ═══ GATE THREE: THE MOVIE IS RESIDENT, AND STAYS RESIDENT ═══
    if not isTrue(HasMinimapOverlayLoaded(state.handle)) then
        state.frames = 0
        state.phase  = 'loading'
        state.why    = ('waiting for HasMinimapOverlayLoaded(%s)'):format(tostring(state.handle))
        return false, state.why
    end

    state.frames = state.frames + 1
    if state.frames < READY_FRAMES then
        state.phase = 'loading'
        state.why   = ('movie loaded -- %d of %d settling frames')
            :format(state.frames, READY_FRAMES)
        return false, state.why
    end

    -- ONE WRITE OF THE DISPLAY RECTANGLE, WITH THE SAME NUMBERS THE VENDORED
    -- Load() USES. It has almost certainly already done this; repeating it costs
    -- one call and means the spike does not depend on having won a race with
    -- somebody else's thread to be able to draw anything at all.
    --
    -- ONCE, AND WITH NO FLAG OF ITS OWN. What makes it once is the line below --
    -- the phase turns 'ready' on this same pass and the early return at the top
    -- of this function short-circuits every pass after it. A `displayed` boolean
    -- beside that would be a SECOND mechanism for one fact, and two mechanisms
    -- for one fact are two things that can disagree later.
    SetMinimapOverlayDisplay(state.handle, 0.0, 0.0, 100.0, 100.0, 100.0)

    state.phase = 'ready'
    state.why   = 'ready'
    return true, state.why
end

--- Is there a handle, loaded, settled, and safe to push a method at?
---
--- ONE TEST, NOT TWO. `and state.handle ~= nil` used to be spelled out here and
--- it cannot be false: the phase only reaches 'ready' three gates past the one
--- that refuses to continue without a handle. It came out for the same reason
--- the `displayed` flag did -- a second expression of a fact the phase already
--- carries is a second thing to keep true. The nil-handle belt is still there,
--- at the boundary where it belongs: BR.Native.minimapMethod refuses one.
--- @return boolean
function BR.MapOverlay.ready()
    return state.phase == 'ready'
end

-- ------------------------------------------------------------------- drawing ---

--- Fill one polygon on the radar and the pause map.
---
--- A SHAPE CANNOT BE EDITED, ONLY REPLACED. There is no method that changes an
--- area's points, so a boundary that changes SHAPE is removeAll() followed by an
--- add. A boundary that only MOVES AND SCALES is a different case and is not a
--- rebuild at all -- placeArea below has why, and what it needs from the caller.
---
--- @param points table  at least 3 { x = number, y = number } in WORLD coords --
---                      or about an origin the caller will placeArea into the
---                      world -- in order around the outline; the movie closes it
--- @param colour table  { r, g, b, a } -- a is 0-255
--- @return integer|nil index  the movie's own zero-based index, or nil
--- @return string     why
function BR.MapOverlay.addArea(points, colour)
    if not BR.MapOverlay.ready() then
        return nil, ('not ready: %s'):format(state.why)
    end
    if type(points) ~= 'table' or #points < 3 then
        return nil, 'a polygon needs at least three points'
    end

    local index = nextIndex()
    -- outline = false, ALWAYS. The movie's AreaOverlay constructor calls its own
    -- createPolygon with 6 arguments where createPolygon declares 11, so the
    -- stroke's thickness is undefined and lineStyle draws nothing. See
    -- BR.Native.minimapAreaOverlay.
    local sent = BR.Native.minimapAreaOverlay(
        state.handle, points, false,
        colour.r or 255, colour.g or 255, colour.b or 255, colour.a or 255)
    if not sent then
        return nil, 'CallMinimapScaleformFunction refused to open ADD_AREA_OVERLAY'
    end

    state.ours[#state.ours + 1] = index
    return index, ('added at movie index %d'):format(index)
end

--- The `a` to ASK FOR so the fill renders at `want` of 255.
---
--- ═══ THE MOVIE'S ALPHA IS NOT LINEAR BELOW 100, AND IT COMPOUNDS ═══
---
--- Two things in the movie read the same parameter. `Colourise` sets
--- `mc._alpha = a / 255 * 100`, which is a Flash 0-100 percentage, and
--- `beginFill(0xFFFFFF, a)` takes `a` as a Flash 0-100 alpha as well. Above 100
--- Flash clamps the fill term, so the opacity is just `a / 255`; BELOW 100 THE TWO
--- MULTIPLY -- `(a / 255) * (a / 100)` -- and a = 50 renders near 10% where a
--- reader of the parameter would expect 20%. Read out of the disassembled movie,
--- recorded on #347.
---
--- So this inverts it. At or above 100 the answer is `want` itself. Below, solving
--- `(a / 255) * (a / 100) = want / 255` gives `a = 10 * sqrt(want)`, and the two
--- branches agree at exactly 100 so there is no step in the middle.
---
--- WHY INVERT IT RATHER THAN JUST STAYING ABOVE 100. The zone fills are asked for
--- at the alphas the radius blips already use -- 80 for the safe zone, 110 for the
--- target -- so that the overlay and the blip fallback are the same picture at the
--- same strength. 80 is in the compounding region, and "stay above 100" would mean
--- the fill was a THIRD of the way more opaque than the map it replaces, which is a
--- change nobody asked for dressed up as a workaround.
--- @param want integer  0-255, as a blip alpha is
--- @return integer      0-255, for ADD_AREA_OVERLAY's `a`
function BR.MapOverlay.areaAlpha(want)
    want = want or 255
    if want < 0 then want = 0 elseif want > 255 then want = 255 end
    if want >= 100 then return math.floor(want + 0.5) end
    return math.floor(10.0 * math.sqrt(want) + 0.5)
end

--- Replace EVERYTHING this file has drawn with one filled area per entry.
---
--- ═══ REMOVE AND RE-ADD IS THE ONLY WAY A SHAPE CHANGES ═══
---
--- An area's points cannot be edited -- addArea's header has the argument -- so a
--- zone that changes shape is a rebuild, and a rebuild is every one of our clips
--- removed and every one added again. That is why this takes the WHOLE content
--- rather than one area at a time: with one call per rebuild there is no moment at
--- which the movie holds half of last tick's zone and half of this one, and the
--- index bookkeeping stays the single ascending list removeAll() is written for.
---
--- ═══ AND IT IS THE EXPENSIVE CALL, AND THE SUSPECT IN #350's HITCH ═══
---
---   "there's a major client perf issue once per second which only happens while
---    the storm is actively in motion."                   -- owner, 2026-09-23
---
--- Every area pushed is, inside the movie, three new MovieClips, a split of the
--- whole coordinate string, a lineTo per point and two Debug.Log calls, the first of
--- which concatenates the entire argument list -- all in compiled bytecode we do not
--- rebuild. Until #350's fix this ran twice a second for as long as the storm moved
--- and never while it held, which made it the only work in the client with the
--- hitch's signature. What a push costs in FRAME TIME was never measurable from
--- here; that it was the thing to stop doing was. So the caller calls this as RARELY
--- as the picture allows and moves what it can with placeArea instead. Nothing here
--- is safe to run per frame.
---
--- ═══ AND A ZONE IS DRAWN WHOLE OR NOT AT ALL ═══
---
--- The same rule client/storm.lua's mapBlips makes, for the same reason: half a zone
--- is a boundary in the WRONG place rather than a missing one, and a player reads a
--- filled edge as the edge. So a partial push is torn down and reported as nothing,
--- which is also what puts the caller back on the radius-blip fallback.
---
--- @param areas table  { { points = { { x, y }, ... }, colour = { r, g, b, a } }, ... }
---                     `colour.a` is the LINEAR 0-255 alpha; see areaAlpha
--- @return integer drawn   areas now in the movie, 0 if nothing was drawn
--- @return integer chars   characters of coordinate string pushed, for the cap hunt
function BR.MapOverlay.setAreas(areas)
    BR.MapOverlay.removeAll()
    state.chars = 0
    if type(areas) ~= 'table' or #areas == 0 then return 0, 0 end
    if not BR.MapOverlay.ready() then return 0, 0 end

    local whole = true
    for i = 1, #areas do
        local ar = areas[i]
        local col = ar.colour or {}
        local idx = BR.MapOverlay.addArea(ar.points, {
            r = col.r, g = col.g, b = col.b,
            a = BR.MapOverlay.areaAlpha(col.a),
        })
        if idx then
            state.set[#state.set + 1] = idx
            -- THE LENGTH OF THE STRING THAT WENT OUT, WHICH IS THE ONE UNMEASURED
            -- RISK ON THIS PATH. There is no documented cap on a Scaleform string
            -- parameter, which is not the same as there not being one: the #347
            -- spike's coordinates were about 70 characters and a real boundary is
            -- over a thousand. If a shape ever comes out GARBLED rather than absent,
            -- this number is the first suspect and BR.MapOverlay.report() is where to
            -- read it. Counted from the same marshaller that did the pushing, so it
            -- cannot drift from what was actually sent.
            state.chars = state.chars + #BR.Native.minimapAreaString(ar.points)
        else
            whole = false
        end
    end

    if not whole then
        BR.MapOverlay.removeAll()
        state.chars = 0
        return 0, 0
    end
    return #state.ours, state.chars
end

--- Remove everything this file added, and nothing else.
---
--- HIGHEST INDEX FIRST, because REM_OVERLAY splices: removing index 2 of
--- { 2, 3 } shifts 3 down to 2 and the second removal would then delete a clip
--- that is not ours. Descending order means every index is still correct when
--- its turn comes.
---
--- AND A REFUSED REMOVAL IS REMEMBERED, NOT FORGOTTEN. If the engine declines to
--- open REM_OVERLAY the clip is still in the movie, and dropping it from this
--- list would make the next nextIndex() too low -- which on a shared handle is
--- not a cosmetic error, it is a later REM_OVERLAY deleting one of
--- ScaleformUI's. Descending order is what makes keeping it correct: everything
--- still on the list after a failure has a LOWER index than anything already
--- removed, and splicing above an index does not move it.
--- @return integer removed
--- There is no no-handle early return, and that is the same argument as the two
--- above: with no handle the list is empty, because addArea only appends behind
--- ready(), and an empty loop already answers 0. A guard here would be a third
--- place saying what the phase says.
function BR.MapOverlay.removeAll()
    -- NOTHING OF THE LAST SET IS PLACEABLE ONCE THIS HAS RUN, including a clip whose
    -- removal was refused: it is still in the movie, but it is no longer the area a
    -- caller's slot number meant.
    state.set = {}
    table.sort(state.ours, function(a, b) return a > b end)
    local removed, kept = 0, {}
    for i = 1, #state.ours do
        if BR.Native.minimapRemoveOverlay(state.handle, state.ours[i]) then
            removed = removed + 1
        else
            kept[#kept + 1] = state.ours[i]
        end
    end
    state.ours = kept
    return removed
end

--- Move one area of the last setAreas, and optionally resize it, WITHOUT rebuilding
--- it (#350).
---
--- ═══ THE MOVIE CAN DO THIS. IT IS THE WRAPPER THAT REFUSES ═══
---
--- Read out of the disassembled MINIMAP_LOADER.gfx, and recorded on #350:
---
---   UPDATE_OVERLAY_POSITION(id, x, y)       overlays[id].txdLoader._x = x
---                                           overlays[id].txdLoader._y = 0 - y
---   UPDATE_OVERLAY_SIZE_OR_SCALE(id, w, h)  if (overlays[id].isScaled) _xscale/_yscale
---                                           else _width = w, _height = h
---
--- An AreaOverlay never sets `isScaled`, so an area takes the _width branch, and its
--- txdLoader is the one clip both of its fills live in. ScaleformUI refuses both
--- calls on an area "due to their vector boundaries", and for the polygons IT draws
--- that refusal is correct: they are drawn in WORLD coordinates, so the clip's origin
--- is the world's origin and a resize scales the shape about (0, 0) -- a zone at the
--- airport would shrink toward the middle of the ocean. Drawn about its OWN centre
--- instead, the clip's origin is that centre, and the same two writes move and scale
--- the polygon in place. That is the whole contract, and it is the CALLER's half: this
--- function cannot tell which way the points were drawn.
---
--- ═══ WHAT IT COSTS, WHICH IS THE REASON IT EXISTS ═══
---
--- Two property writes per call and nothing else: no clip is made or destroyed, no
--- string is split and nothing is logged. ADD_AREA_OVERLAY's handler, the AreaOverlay
--- constructor and its createPolygon are 2,070 bytes of bytecode with two loops over
--- the points; these two handlers are 210 bytes with none.
---
--- ═══ A REFUSAL IS ANSWERED, NOT SWALLOWED ═══
---
--- The same BOOL read addArea relies on, for the same reason: a refused open followed
--- by pushes commits somebody else's call. An area that could not be placed is still
--- in the movie, wherever it was drawn -- so `false` means the caller's picture is
--- now wrong, and the caller must rebuild or tear it down.
---
--- @param slot integer   1 = the first area the last setAreas pushed
--- @param x number       world x for the area's local origin
--- @param y number       world y -- NOT negated; the movie does it, as addArea's does
--- @param w number|nil   width in world metres; nil leaves the size alone
--- @param h number|nil   height in world metres
--- @return boolean placed
function BR.MapOverlay.placeArea(slot, x, y, w, h)
    if not BR.MapOverlay.ready() then return false end
    local index = state.set[slot]
    if not index then return false end

    if not BR.Native.minimapMethod(state.handle, 'UPDATE_OVERLAY_POSITION') then
        return false
    end
    ScaleformMovieMethodAddParamInt(index)
    ScaleformMovieMethodAddParamFloat(x + 0.0)
    ScaleformMovieMethodAddParamFloat(y + 0.0)
    EndScaleformMovieMethod()

    if w and h then
        if not BR.Native.minimapMethod(state.handle, 'UPDATE_OVERLAY_SIZE_OR_SCALE') then
            return false
        end
        ScaleformMovieMethodAddParamInt(index)
        ScaleformMovieMethodAddParamFloat(w + 0.0)
        ScaleformMovieMethodAddParamFloat(h + 0.0)
        EndScaleformMovieMethod()
    end

    state.moves = state.moves + 1
    return true
end

--- What this file currently believes, for /brmaparea to print.
--- @return table
function BR.MapOverlay.report()
    return {
        phase   = state.phase,
        why     = state.why,
        handle  = state.handle,
        asked   = state.asked,
        frames  = state.frames,
        areas   = #state.ours,
        chars   = state.chars,
        moves   = state.moves,
        next    = nextIndex(),
    }
end
