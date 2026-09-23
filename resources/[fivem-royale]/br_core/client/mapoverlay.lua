-- The shared minimap overlay handle, and one filled polygon drawn through it.
--
-- ═══ THIS IS A SPIKE (#347) AND THE SCOPE IS THE POINT ═══
--
-- ONE QUESTION: does ADD_AREA_OVERLAY actually fill a polygon on the radar and
-- on the pause map? Nobody ships that method -- across GitHub the only hits are
-- ScaleformUI itself, its docs and its C# demo -- so it is answered by drawing
-- one hard-coded shape and looking at it (/brmaparea, client/debug.lua), not by
-- building on the assumption that it works.
--
-- SO THERE IS DELIBERATELY NO STORM INTEGRATION HERE. No shape walking, no
-- per-phase wiring, no rebuild cadence, no sibling of storm.lua's mapBlips.
-- Nothing in the gamemode calls this file. If the spike says yes, the caller is
-- written then; if it says no, this file and its command are deleted and the
-- fallback is a DUI raster into ADD_SCALED_OVERLAY -- same handle, same movie,
-- and proven in production by somebody else.
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
-- HONESTY ABOUT WHAT THAT GATE BUYS, THOUGH: ScaleformUI's own thread calls
-- MinimapOverlays:Load() at br_core's start and retries at 2 Hz until the
-- handle arrives, so ADD_MINIMAP_OVERLAY has already been called once per
-- client, at join, today, with no gate at all -- and that is vendored code this
-- project does not patch. The gate keeps OUR call off the race. It cannot move
-- theirs, and the spike is not the place to try.

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
--- THERE IS NO UPDATE FUNCTION AND THERE MUST NOT BE ONE. An area cannot be
--- moved, rotated or resized in place: the vendored wrapper refuses all three
--- on an area "due to their vector boundaries" (ScaleformUI.lua:16855, :16868,
--- :16883) and the movie has no method that would do it either. A geometry
--- change is removeArea() followed by addArea(), and a caller that wants to
--- animate one has to be written knowing that.
---
--- @param points table  at least 3 { x = number, y = number } in WORLD coords,
---                      in order around the outline; the movie closes it
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
        next    = nextIndex(),
    }
end
