-- The stat board (#247): one browser, one prop, one quad.
--
-- ═══ ONE BOARD, AND THE SCOREBOARD IS IT ═══
--
-- Owner, 2026-09-11: the warmup stat board and the scoreboard are the SAME
-- BOARD. There is one physical display showing a page that alternates between a
-- viewer's own stats and the shared leaderboard, and this file is all of the
-- Lua there is for it. There is no second prop, no second browser, no mode and
-- no switch -- see the alternation note below, which was already true and is now
-- also the answer to "which board is this one".
--
-- ═══════════════════════════════════════════════════════════════════════════
-- WHAT A DUI IS, AND WHY THIS FILE IS SHORT
-- ═══════════════════════════════════════════════════════════════════════════
--
-- A DUI is a whole Chromium instance rendering a page into a runtime texture.
-- This one runs on the LOCAL player's machine, fetches a page Ringmaster serves
-- at an address whose only parameter is that player's own license, and this file
-- paints the resulting texture onto a quad standing on a prop.
--
-- Everything hard about that quad is already solved and is deliberately not
-- solved again here. client/dui.lua's drawPlane levels a prop that is not
-- sitting square, gets the reader's left the right way round so the writing is
-- not mirrored, winds the two triangles toward the camera so the board is not
-- invisible from the side everybody stands on, and measures the whole thing in
-- meters. BR.Dui.drawBoard is that quad with a lateral and a yaw. This file
-- hands it an entity and five numbers.
--
-- ═══ THE ALTERNATION IS THE PAGE'S AND NOT OURS ═══
--
-- The board shows a leaderboard, the viewer's own career and, in squads, their
-- squadmates', and moves between them. That handover lives entirely in the
-- document Ringmaster serves; there is no mode push, no timer and no message
-- about it anywhere in this file.
--
-- ⚠ THE REASON USED TO BE "A STILL DUI COSTS APPROXIMATELY NOTHING, SO A PAGE
-- THAT SWAPS ITSELF IS ONE REPAINT PER SWAP". That premise is false and so is
-- the sentence it was standing on. FiveM's NUIRenderCallbacks.cpp calls
-- UpdateFrame() on every registered NUI window unconditionally, and the
-- dirty-flag gate exists only in the software fallback branch -- so the game's
-- renderer does the same full-surface blit every game frame whether the page
-- painted or not, and there is no such thing as a repaint this side is billed
-- for. Ringmaster's src/lib/scoreboardPage.ts carries the correction in full,
-- out of the FiveM and CEF sources; config/board.lua's texture note records it
-- beside the two numbers it bears on.
--
-- THE CONCLUSION IS UNCHANGED AND THE HONEST REASON IS SIMPLER. Lua driving the
-- handover would put a message on the wire per swap per client and could not
-- lower the cost of anything, because the cost is frame production inside CEF on
-- the player's own machine and the page is what decides how much work a frame
-- is. What CAN lower it is Ringmaster's own SCOREBOARD_MOTION setting, which is
-- a server-side knob over there and nothing this file can reach.
--
-- ⚠ IT ALSO MOVES ON ITS OWN CLOCK, DELIBERATELY. Every animated layer starts at
-- a random offset and there is no seed and no start time, so two players at this
-- prop see different backgrounds. Owner: "Each one having a different background
-- is fine - nobody will know." Nothing here should ever try to synchronise it.
--
-- ═══ WHY A QUAD AND NOT AddReplaceTexture ═══
--
-- ADD_REPLACE_TEXTURE would give real engine lighting and a real UV fit -- the
-- board would BE the prop's screen rather than a plane in front of it -- and it
-- is the upgrade path if this ever reads as floating. It is not the starting
-- point, for three reasons that compound:
--
--   IT NEEDS THREE FACTS ABOUT THE PROP WE DO NOT HAVE: the txd name, the
--   texture name inside it, and the certainty that the model has streamed. Two
--   of those are only readable by opening the model.
--
--   IT IS GLOBAL PER CLIENT. The replacement is by texture name, not by entity,
--   so every instance of that model anywhere on the map wears the board.
--
--   AND THE NATIVE HAS NO RETURN VALUE. A wrong dictionary name, a wrong texture
--   name and a prop that has not streamed yet all produce an ordinary-looking
--   prop and no error anywhere. That is this project's worst failure shape.
--
-- A quad is wrong in exactly one visible way (it can look like it is floating),
-- and that way is measurable and tunable with /brboard.
--
-- ═══ THE GAME SERVER LEARNS NOTHING ABOUT ANY OF THIS ═══
--
-- The house rule is that the game server must never depend on Ringmaster, and
-- the design is safe only because this all happens on the player's own machine.
-- Read the file for it: there is no TriggerServerEvent anywhere below, no state
-- reported anywhere, and the single thing that arrives from the server is the
-- player's own license -- a value the box already had, that would be sent
-- identically on an install that had never heard of the console. Whether the
-- fetch worked is known to one browser and to /brboard, and to nothing else.

BR = BR or {}
BR.Board = BR.Board or {}

local C = BR.Config.Board

--- IN LUA 0 IS TRUTHY, AND A FIVEM NATIVE DECLARED BOOL MAY ANSWER 1 OR 0
--- RATHER THAN true OR false. The same helper and the same spelling as
--- client/warmupcrates.lua's, and there is a ratchet in tools/verify.sh whose
--- count may only go down. Every BOOL native in this file goes through here.
--- @param v any
--- @return boolean
local function isTrue(v)
    return v ~= nil and v ~= false and v ~= 0
end

-- ---------------------------------------------------------------------------
-- What we have been told
-- ---------------------------------------------------------------------------

--- This player's own license, bare hex, or nil until the server says.
---
--- br_core/server/board.lua pushes it on READY, which is well before a player
--- can be standing in warmup, and pushes it again on every br_ui or br_core
--- restart because client/state.lua re-sends READY on both. So the ordering
--- requirement -- the license is in hand before the browser is built -- is met
--- by construction rather than by a delay, and a mid-session `restart br_core`
--- does not leave a client that can never build a URL again.
local license = nil

RegisterNetEvent(BR.Net.BOARD_ID)
AddEventHandler(BR.Net.BOARD_ID, function(id)
    if type(id) ~= 'string' or id == '' then return end
    license = id
end)

--- Whether the page has said it is alive: 'unknown', 'up' or 'down'.
---
--- ═══ THIS IS THE HALF A DUI CANNOT ANSWER, AND SAYING SO IS THE HONEST
---     IMPLEMENTATION ═══
---
--- Owner, 2026-09-09: "If ringmaster is down, that's fine. We just show static on
--- the screen instead."
---
--- SHOWING static is easy and is done below. DETECTING is the hard half, and
--- Lua cannot do it alone. There is no load callback, no status code, no error
--- event and no way to read a runtime texture back: CreateDui hands over an
--- address and IS_DUI_AVAILABLE answers whether the CEF INSTANCE started, which
--- is true whether the page loaded or the browser is sitting on
--- ERR_NAME_NOT_RESOLVED. The only party that knows is the page.
---
--- SO THE DEFAULT IS 'unknown' AND 'unknown' DRAWS THE BOARD. A timer that
--- assumed failure after N seconds would be a guess wearing a detector's
--- clothes, and it would put static on the wall of a perfectly healthy lobby the
--- first time a fetch was slow. Only a positive report moves this.
---
--- WHAT WOULD MOVE IT is written down at BR.Board.health below, along with what
--- the Ringmaster page has to do to send one and why that is not a line of
--- JavaScript. Until that lands, /brboard static drives this by hand, which is
--- also how the owner looks at the static while aligning the board.
local health = 'unknown'

-- ---------------------------------------------------------------------------
-- The numbers, and the live overrides on top of them
-- ---------------------------------------------------------------------------
--
-- ═══ nil MEANS "NOT OVERRIDDEN", AND 0.0 DOES NOT ═══
--
-- Every resolver below is `override or config`, and that reads as the classic
-- Lua trap right up until you remember which way round it is: 0 IS TRUTHY in
-- Lua, so an override of exactly 0.0 wins over the config value, which is
-- precisely what somebody typing `/brboard side 0` means. The trap would be an
-- override stored as `false`, and nothing here ever stores one.

local ovFwd, ovSide, ovUp, ovW, ovYaw = nil, nil, nil, nil, nil
local ovModel = nil
local ovX, ovY, ovZ, ovH = nil, nil, nil, nil

--- The object we adopted, or nil. Declared HERE, above `fitted()`, because a
--- Lua local is invisible above its own declaration and `fitted` reads it.
local prop = nil

--- The model hash it was found under, so a /brboard prop swap can notice.
local propHash = nil

local function cfgModel() return ovModel or C.prop.model end
local function cfgX()     return ovX or tonumber(C.prop.x) end
local function cfgY()     return ovY or tonumber(C.prop.y) end
local function cfgZ()     return ovZ or tonumber(C.prop.z) end
local function cfgH()     return ovH or tonumber(C.prop.heading) or 0.0 end
local function cfgRadius() return tonumber(C.prop.radiusM) or 8.0 end

-- ---------------------------------------------------------------------------
-- The three numbers the prop itself answers
-- ---------------------------------------------------------------------------
--
-- ═══ WE DO NOT KNOW HOW BIG prop_huge_display_02 IS, AND THE ENGINE DOES ═══
--
-- config/board.lua ships forwardM, upM and widthM as nil, and the reason is
-- written out there: no dimensions for this model are published anywhere, and
-- this project does not put a plausible number where a measured one belongs. The
-- previous draft's 0.06 / 1.20 / 2.40 were invented against no prop at all and
-- are known wrong against a stage display.
--
-- THIS IS THE SAME MOVE config/fuel.lua's pump lookup ALREADY MADE. There was no
-- table of pump coordinates either, and asking the streamed world turned out to
-- be better than a table would have been. GET_MODEL_DIMENSIONS is the model's
-- own bounding box, straight out of the model table.
--
-- CACHED PER MODEL HASH, AND THE CACHE IS THE POINT. These resolvers are read by
-- the FRAME band -- BR.Dui.drawBoard is handed all five every frame the board is
-- in range -- and a GET_MODEL_DIMENSIONS per number per frame is three lookups
-- sixty times a second for six numbers that cannot change. client/dui.lua caches
-- the same native for the same reason and says so in the same words.
local BOXES = {}

--- The found prop's bounding box, or nil.
---
--- NIL UNTIL THERE IS A PROP, WHICH IS NOT THE SAME AS ZERO. GET_MODEL_DIMENSIONS
--- answers a box of zeroes for a model that is not loaded, and a widthM of 0.0
--- would reach BR.Dui.drawBoard's `if hw <= 0.0 then return end` and draw
--- nothing, forever, with no error anywhere -- this project's worst failure
--- shape. So a degenerate box is refused here and the caller falls through to
--- its own last resort rather than inheriting a zero.
---
--- MEASURED OFF THE MODEL WE SEARCHED BY, not off GetEntityModel. They are the
--- same hash by construction (the search matched on it), and asking the entity
--- would be a second native for the same answer.
--- @return table|nil { minx, miny, minz, maxx, maxy, maxz }
local function box()
    if not prop or not propHash then return nil end

    local d = BOXES[propHash]
    if d ~= nil then
        if d == false then return nil end
        return d
    end

    local a, b = GetModelDimensions(propHash)
    if not a or not b then
        BOXES[propHash] = false
        return nil
    end
    d = { minx = a.x, miny = a.y, minz = a.z,
          maxx = b.x, maxy = b.y, maxz = b.z }

    -- A BOX WITH NO WIDTH IS NOT A MEASUREMENT. `false` rather than nil, so a
    -- model that answered uselessly is asked once and not once per frame.
    if (d.maxx - d.minx) <= 0.0 then
        BOXES[propHash] = false
        return nil
    end

    BOXES[propHash] = d
    return d
end

--- How far off the prop's front face the quad should stand, measured.
---
--- THE FRONT FACE IS `maxy`, PLUS CLEARANCE. drawBoard walks out along the
--- prop's forward vector, which is its local +Y, so the box's own +Y extent is
--- exactly how far it is to the surface. The clearance is what keeps the quad
--- out of the mesh rather than z-fighting inside it.
---
--- ⚠ WHICH SIDE OF THE MODEL THE SCREEN IS ON IS NOT IN THE BOX. If this comes
--- up behind the prop, that is `/brboard yaw 180`, and the config says so.
local FACE_CLEARANCE_M = 0.02

--- The measured forwardM, upM and widthM, or nil each when there is no box.
--- @return number|nil fwd
--- @return number|nil up
--- @return number|nil width
local function fitted()
    local d = box()
    if not d then return nil, nil, nil end
    return d.maxy + FACE_CLEARANCE_M,
           (d.minz + d.maxz) * 0.5,
           d.maxx - d.minx
end

--- ═══ THE ORDER IS OVERRIDE, THEN CONFIG, THEN MEASUREMENT, THEN LAST RESORT
---     ═══
---
--- An explicit number always beats the tape measure -- that is what pasting
--- /brboard's block back into config/board.lua does, and a config that could be
--- silently overruled by a model change would not be a config.
---
--- THE LAST RESORTS BELOW ARE NOT ALIGNMENT VALUES AND ARE NOT MEANT TO LOOK
--- LIKE ANY. They are reached only when a prop is standing AND its model
--- answered a degenerate box, which should never happen; they exist so that a
--- board in that state is visibly somewhere rather than invisible, because a
--- quad that is not drawn is indistinguishable from six other faults.
local function cfgFwd()
    if ovFwd then return ovFwd end
    local v = tonumber(C.forwardM)
    if v then return v end
    local f = fitted()
    return f or 0.06
end

local function cfgSide()  return ovSide or tonumber(C.sideM) or 0.0 end

local function cfgUp()
    if ovUp then return ovUp end
    local v = tonumber(C.upM)
    if v then return v end
    local _, u = fitted()
    return u or 1.20
end

local function cfgW()
    if ovW then return ovW end
    local v = tonumber(C.widthM)
    if v then return v end
    local _, _, w = fitted()
    return w or 2.40
end

local function cfgYaw()   return ovYaw  or tonumber(C.yawDeg)   or 0.0 end

--- Are all three coordinates there?
---
--- ALL THREE, TOGETHER, AND SEPARATELY FROM THE MODEL. A half-finished config
--- edit that sets x and y and forgets z is the shape this catches, and
--- CREATE_OBJECT_NO_OFFSET with a nil z is an engine error rather than a board
--- that is slightly wrong. `sited()` below spends this, and so does the readout
--- in /brboard, which formats all three with %.2f and would throw on a nil.
--- @return boolean
local function haveSite()
    return type(cfgX()) == 'number'
       and type(cfgY()) == 'number'
       and type(cfgZ()) == 'number'
end

--- Has anybody said where the board goes?
---
--- ⚠ FALSE ON A SHIPPED CHECKOUT, DELIBERATELY. The owner has a prop in mind and
--- has not named it (see config/board.lua), so `model` is nil, and a nil model
--- means this file spawns nothing, builds no browser and draws nothing at all.
--- The feature is inert rather than guessing at a prop -- and /brboard prop
--- <model> is how it is auditioned without a config edit and a restart.
--- @return boolean
local function sited()
    if C.enabled == false then return false end
    local m = cfgModel()
    if type(m) ~= 'string' or m == '' then return false end
    return haveSite()
end

--- Is the local player somewhere this board could be seen from?
---
--- WARMUP AND NOTHING ELSE, which is the issue's own rule: the DUI exists only
--- while the player is in the warmup area. In every other state the prop's site
--- is kilometres away in a world where there is nothing standing there.
---
--- MATCH START IS THIS EDGE. A match starting moves this player's state out of
--- WARMUP, so the teardown below is the "destroy it on match start" the issue
--- asks for rather than a second mechanism that could disagree with it. It is
--- polled at 10 Hz like client/warmupcrates.lua polls the same question, so the
--- browser outlives the match's start by up to one tick.
--- @return boolean
local function onPad()
    return BR.State and BR.State.me
       and BR.State.me.state == BR.PlayerState.WARMUP
end

--- The address this browser should be pointed at right now.
---
--- TWO REASONS TO SHOW STATIC AND THEY ARE THE SAME REASON. The page reported
--- itself down, or there is no license to ask about -- and in both cases there
--- is nothing true to paint. A screen full of noise reads as a screen that is on
--- and has nothing to show; a blank quad reads as a bug, which is why the owner
--- asked for static rather than for nothing.
--- @return string
local function wantUrl()
    if health ~= 'down' then
        local url = BR.BoardUrl(license, C)
        if url then return url end
    end
    return C.staticUrl
end

-- ---------------------------------------------------------------------------
-- The prop
-- ---------------------------------------------------------------------------
--
-- ═══════════════════════════════════════════════════════════════════════════
-- ⚠ THIS PROP IS NOT OURS. WE FIND IT, AND WE NEVER MAKE OR UNMAKE ONE.
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Owner, 2026-09-11: "The prop is prop_huge_display_02, already in a ymap and
-- streamed and verified working in-game."
--
-- The previous draft called CREATE_OBJECT_NO_OFFSET at the configured
-- coordinates. Against a prop that is already standing there that is not a
-- near-miss, it is TWO DISPLAYS IN THE SAME CUBIC METRE: two coincident meshes
-- z-fighting through each other, and an alignment session against a board that
-- turns out to be two boards. Both halves of that mistake are gone --
-- CreateObjectNoOffset, RequestModel and SetModelAsNoLongerNeeded have no
-- callers left in this file, and neither does DeleteEntity.
--
-- ═══ AND DELETING IS THE WORSE HALF, WHICH IS WHY IT IS CALLED OUT SEPARATELY
--     ═══
--
-- A spawned prop must be deleted or it outlives the resource. A FOUND one must
-- NOT be: DeleteEntity on a ymap entity takes a piece of the owner's map away
-- for the rest of that client's session, and it would fire on every match start,
-- on every /brboard reset, and on `restart br_core`. The board would work, once,
-- and the display would then be missing until the player reconnected. So the
-- teardown below FORGETS a handle and does nothing to the entity, and there is
-- no code path anywhere in this file that can delete it.

--- How long to wait before looking again after a search came up empty.
---
--- ═══ GET_CLOSEST_OBJECT_OF_TYPE IS THE MOST EXPENSIVE NATIVE THIS PROJECT
---     CALLS, AND client/fuel.lua ALREADY PAID FOR THAT LESSON ═══
---
--- It has no spatial index -- it walks the object pool -- and Cfx.re's own
--- thread on it (forum.cfx.re/t/146715) measures 2 to 4 ms per call. fuel.lua's
--- resolvePump carries the post-mortem: the fault that turned a stutter into a
--- collapse was not the cost of a hit, it was that A MISS WAS NEVER CACHED, so
--- the sweep ran again on the very next pass and kept running for as long as the
--- player stood there.
---
--- THAT IS EXACTLY THIS SHAPE. The board's site is in the warmup area, the
--- player is standing in the warmup area, and a prop that has not streamed in
--- yet is a miss that lasts seconds. At 10 Hz, unthrottled, that is up to 80 ms
--- of search per second, on every client in the lobby at once, for a prop that
--- is about to arrive on its own. Two seconds between attempts turns that into
--- one call per two seconds, and the cost of being late is that the board
--- appears up to two seconds after the prop does.
local FIND_RETRY_MS = 2000

--- When we last looked and did not find it.
local lastMiss = 0

--- Both spellings of GET_CLOSEST_OBJECT_OF_TYPE's `isMission` flag.
---
--- A file-local constant rather than a literal at the call, because the search
--- runs inside a 10 Hz callback and a fresh two-element table per pass is
--- garbage this project has no reason to make. Same constant, same spelling and
--- the same reasoning as client/warmupcrates.lua's.
local MISSION_FLAGS = { false, true }

--- The existing display, or nil.
---
--- ═══ THE SIGNATURE, READ RATHER THAN REMEMBERED ═══
---
---   Object GET_CLOSEST_OBJECT_OF_TYPE(float x, float y, float z, float radius,
---                                     Hash modelHash, BOOL isMission,
---                                     BOOL p6, BOOL p7)
---
--- Eight arguments, hash 0xE143FA2249364369. citizenfx/natives documents
--- `isMission` as "if true doesn't return mission objects" -- which is the
--- OPPOSITE of what the parameter's name reads as, and p6 and p7 are undocumented
--- there and everywhere else. So both spellings of the flag are asked and p6/p7
--- are false, which is what every working call in this repository already passes.
---
--- ═══ ASKING TWICE IS NOT SUPERSTITION ═══
---
--- client/warmupcrates.lua's findProp says it at length and it is true here for a
--- sharper reason: a ymap entity is not a mission entity and is not a script
--- object, and which side of an undocumented flag with a documented-backwards
--- meaning it falls on is a question about this runtime rather than about the
--- API. Asking once and guessing costs a feature that silently never engages,
--- which is the failure this project keeps paying for. Asking twice costs one
--- extra native call, and only on a pass that already missed.
---
--- ═══ AND THE HIT IS RANGE-CHECKED AGAIN AFTER THE NATIVE HAS RANGE-CHECKED IT
---     ═══
---
--- Belt and braces, the same way warmupcrates.lua re-checks its own tolerance:
--- the radius argument is the native's promise, and this project has been wrong
--- about a native's promise before. It costs one distance test against a number
--- we already have.
--- @return integer|nil
local function findProp()
    local hash = GetHashKey(cfgModel())
    local x, y, z = cfgX(), cfgY(), cfgZ()
    local r = cfgRadius()

    for _, mission in ipairs(MISSION_FLAGS) do
        local ok, obj = pcall(GetClosestObjectOfType, x, y, z, r, hash,
                              mission, false, false)
        -- A HANDLE OF 0 IS "NOTHING FOUND", not an object. Checked before
        -- DoesEntityExist rather than instead of it: the native answers 0 for a
        -- miss, and a stale non-zero handle is a separate question.
        if ok and obj and obj ~= 0 and isTrue(DoesEntityExist(obj)) then
            local c = GetEntityCoords(obj)
            if BR.Dist2(c.x, c.y, x, y) <= r * r then
                propHash = hash
                return obj
            end
        end
    end
    return nil
end

--- Look for it, at most once every FIND_RETRY_MS.
---
--- ═══ A PROP THAT HAS NOT STREAMED IN IS THE ORDINARY CASE, NOT AN ERROR ═══
---
--- The issue's own edge: a player arriving in warmup is a player whose client is
--- still streaming the corner of the map the board stands in. There is nothing
--- to do about that except come back, so this is a state machine on the tick
--- rather than a wait -- no thread, no Citizen.Wait inside a band callback, and
--- nothing for client/main.lua's performance contract to object to. The same
--- shape the old model request had, for the same reason, against a different
--- kind of waiting.
local function seekProp()
    local now = GetGameTimer()
    if (now - lastMiss) < FIND_RETRY_MS then return end

    local obj = findProp()
    if obj then
        prop = obj
        lastMiss = 0
        return
    end

    -- THE MISS IS RECORDED, WHICH IS THE WHOLE OF fuel.lua's FAULT 2. Without
    -- this line the guard above is false again on the very next pass.
    lastMiss = now
    propHash = nil
end

--- Let go of it. THE ENTITY IS UNTOUCHED -- see this section's header.
local function forgetProp()
    prop = nil
    propHash = nil
    -- THE RETRY CLOCK GOES WITH IT. Letting go on the way out of warmup and then
    -- coming straight back must look again immediately rather than serve out a
    -- timer from a search that is no longer the one being run -- which is also
    -- what makes `/brboard prop <model>` feel instant.
    lastMiss = 0
end

-- ---------------------------------------------------------------------------
-- The browser
-- ---------------------------------------------------------------------------

--- The BR.Dui page, or nil while there is no browser.
---
--- ONE, EVER, AND IT IS NEVER RECREATED TO CHANGE WHAT IS ON IT. The issue names
--- that rule outright: a DUI is a real browser instance and leaking one per match
--- is not acceptable. Swapping between the board and the static page goes through
--- BR.Dui.url, which is SetDuiUrl; destroy is reserved for leaving the pad.
local page = nil

--- The name BR.Dui memoises this page under. A constant, in one place, because
--- BR.Dui.destroy takes the NAME and BR.Dui.page returns the page -- two calls
--- that must agree about a string or the teardown silently tears down nothing.
local PAGE = 'board'

local function makePage()
    if page then return end
    page = BR.Dui.page(PAGE, wantUrl(),
                       math.tointeger(tonumber(C.width)) or 1280,
                       math.tointeger(tonumber(C.height)) or 720)
end

local function killPage()
    if not page then return end
    BR.Dui.destroy(PAGE)
    page = nil
end

--- Everything down: the browser, our hold on the prop, and the range latch.
---
--- CALLED FROM THREE PLACES AND THEY ARE THE THREE THE ISSUE NAMES -- leaving
--- the warmup area, the match starting (which is the same edge, see onPad), and
--- the resource stopping. One function so the three cannot come to disagree
--- about what teardown means.
---
--- ⚠ ONE BROWSER IS DESTROYED AND NO PROP IS. The DUI is ours and leaking one
--- per match is what the issue forbids; the display is the map's and deleting it
--- is what the prop section's header forbids. The asymmetry is deliberate and it
--- is the whole reason `forgetProp` is not called `dropProp` any more.
local inRange = false

local function teardown()
    killPage()
    forgetProp()
    inRange = false
end

-- ---------------------------------------------------------------------------
-- The two passes
-- ---------------------------------------------------------------------------

-- ═══ 10 Hz: WHETHER THERE IS A BOARD AT ALL, AND WHAT IS ON IT ═══
--
-- Everything that is not the draw call itself. The steady state off the pad is
-- one table lookup and a return, which is what this costs for the whole of a
-- match.
BR.Loop.register(BR.Loop.TICK, 'board.track', function()
    if not onPad() or not sited() then
        -- NOT "if page then teardown()" -- teardown is idempotent and cheap, and
        -- a guard here would be a second place that has to agree about what
        -- "there is something up" means.
        if page or prop then teardown() end
        return
    end

    if not prop or not isTrue(DoesEntityExist(prop)) then
        -- STREAMED OUT, NEVER FOUND, OR SWAPPED. All three are ordinary: a
        -- player who walks far enough from the board has its entity unstreamed
        -- under them and the handle stops existing, which is a search again and
        -- not an error. `/brboard prop <model>` lands here the same way.
        prop = nil
        seekProp()
        if not prop then return end
    end

    -- ⚠ NOT BEFORE THE PROP IS IN HAND. The browser is built only once there is
    -- something to paint it on, which is what keeps a client that is still
    -- streaming the warmup area from opening a Chromium instance it cannot use
    -- yet -- and, with the search throttled to FIND_RETRY_MS, from opening one
    -- seconds before the surface arrives.
    makePage()

    -- THE ADDRESS IS RE-DECIDED EVERY PASS AND ALMOST NEVER CHANGES. BR.Dui.url
    -- compares before it navigates, so this is a string comparison ten times a
    -- second rather than a page load ten times a second -- which is the whole
    -- reason that guard is inside BR.Dui rather than duplicated here.
    BR.Dui.url(page, wantUrl())

    -- WHETHER IT IS WORTH DRAWING, decided here rather than on the frame band.
    -- The answer is good for a tenth of a second and costs a native; the draw
    -- itself has to be per frame because DrawSpritePoly lasts exactly one frame.
    -- Same split, and the same reasoning, as client/warmupcrates.lua's markers.
    local p = GetEntityCoords(PlayerPedId())
    local reach = tonumber(C.drawM) or 80.0
    inRange = BR.Dist2(p.x, p.y, cfgX(), cfgY()) <= reach * reach
end)

-- ═══ EVERY FRAME: THE QUAD ═══
--
-- REGISTERED ALWAYS, RUNS ALMOST NEVER. Off the pad `inRange` is false and this
-- callback is one boolean test per frame.
BR.Loop.register(BR.Loop.FRAME, 'board.draw', function()
    if not inRange or not page or not prop then return end
    BR.Dui.drawBoard(page, prop,
                     cfgFwd(), cfgSide(), cfgUp(), cfgW(), cfgYaw())
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    teardown()
end)

-- ---------------------------------------------------------------------------
-- The one thing the page has to tell us
-- ---------------------------------------------------------------------------

--- The board's page reporting whether it is alive.
---
--- ═══ WHAT HAS TO HAPPEN ON THE OTHER SIDE, WRITTEN DOWN RATHER THAN ASSUMED
---     ═══
---
--- Nothing calls this yet from the page, and that is a fact rather than an
--- oversight. A DUI has no channel back to Lua of its own; the only one CEF
--- offers is an NUI callback, and FiveM's own source settles what that can
--- reach: nui-resources/src/ResourceUI.cpp adds cross-origin whitelist entries
--- for exactly two source origins per resource, `nui://<res>` and
--- `https://cfx-nui-<res>`, and the callback handler sets no
--- Access-Control-Allow-Origin of its own. A document served from
--- ringmaster.blitz-royale.com is neither of those origins.
---
--- SO THE PAGE CANNOT REPORT FROM WHERE IT IS. What can is a small LOCAL shell
--- page -- served from `https://cfx-nui-br_ui/...`, which is whitelisted -- that
--- fetches the board's URL, learns whether it answered, reports here through
--- br_ui's NUI doorway (the only resource whose callbacks are reachable, for the
--- reason br_ui/client/nui.lua's own note records), and then shows the board.
--- That shell is a page, and pages are the console repository's half of this
--- feature; it is written up in the handover rather than guessed at here.
---
--- THIS SIDE IS READY FOR IT EITHER WAY. A plain client event is the seam --
--- separate Lua states cannot share a function, they share events, exactly as
--- `br:tutorial:set` already crosses from br_ui to br_core.
---
--- @param up boolean|nil  true = the page loaded, false = it did not, nil = we
---                        no longer know (a fresh browser, nothing reported yet)
function BR.Board.health(up)
    if up == nil then
        health = 'unknown'
    else
        health = (up == true) and 'up' or 'down'
    end
end

AddEventHandler('br:board:health', function(up)
    BR.Board.health(up)
end)

-- ---------------------------------------------------------------------------
-- The tuning command
-- ---------------------------------------------------------------------------
--
-- ═══ HE ASKED FOR A TOOL, IN THOSE WORDS ═══
--
-- Owner, 2026-09-09: "I already have a prop in mind for this. Not sure how to
-- put the DUI on it though. Need your help on that. I can help align it if you
-- give me the tools."
--
-- So the prop, its site and the board's five numbers are all live, and the
-- output is a block he can paste into br_lib/config/board.lua. This is
-- /brgunplate's shape and /brgunplate's argument applied to a surface nobody has
-- seen yet: one round of nudging settles what three rounds of guessing would
-- not.
--
-- EVERY VALUE TAKES AN ABSOLUTE OR A DELTA. `0.65` sets, `+0.05` and `-0.10`
-- nudge, which is why the parser reads the RAW string before it reads the number.
--
-- The registration, and why there are two names for it, is at the bottom.

--- "0.65" is a value, "+0.05" and "-0.10" are nudges. Same helper, same spelling,
--- as client/gunshop.lua's.
--- @param cur number
--- @param arg string|nil
--- @return number|nil
local function nudge(cur, arg)
    local s = tostring(arg or '')
    local n = tonumber(s)
    if n == nil then return nil end
    if s:sub(1, 1) == '+' or s:sub(1, 1) == '-' then return cur + n end
    return n
end

--- A number, or a dash where there is nothing to read.
---
--- "-0.00" IS NOT A READING, and every offset here is a difference of floats that
--- may be equal. client/gunshop.lua's /brgunshop carries the same helper for the
--- same reason.
--- @param v number|nil
--- @return string
local function m(v)
    if type(v) ~= 'number' then return '-' end
    local s = ('%.2f'):format(v)
    if s == '-0.00' then return '0.00' end
    return s
end

--- Which of the three sources a number came from.
---
--- ⚠ THE TEST IS `~= nil` AND IT HAS TO BE. Every one of these values can
--- legitimately be 0.0 -- `/brboard up 0` is a real instruction meaning "level
--- with the prop's origin" -- and 0 IS TRUTHY IN LUA, so `override and ...`
--- would read correctly here by accident while the equivalent line elsewhere
--- would not. Spelled out rather than relied on.
--- @param override number|nil
--- @param configured any
--- @return string
local function srcOf(override, configured)
    if override ~= nil then return 'nudged' end
    if tonumber(configured) ~= nil then return 'config' end
    if fitted() ~= nil then return 'measured' end
    return 'fallback'
end

local function runBoardCmd(_, args)
    local what = tostring(args[1] or ''):lower()

    if what == 'reset' then
        ovFwd, ovSide, ovUp, ovW, ovYaw = nil, nil, nil, nil, nil
        ovModel, ovX, ovY, ovZ, ovH = nil, nil, nil, nil, nil
        -- THE HOLD ON THE PROP GOES WITH THEM. Its model and the site it was
        -- found from are among the things being reset, and a handle kept from a
        -- search at an overridden site while the numbers below read the config's
        -- is the readout lying. The display itself is not touched.
        forgetProp()

    elseif what == 'prop' then
        -- AUDITION A MODEL WITHOUT A CONFIG EDIT AND A RESTART. `prop_huge_display_01`
        -- is the sibling of the one that ships, and this is how it is tried.
        local name = tostring(args[2] or '')
        if name == '' then
            print('[br_core] board: brboard prop <model>')
        else
            ovModel = name
            forgetProp()
        end

    elseif what == 'here' then
        -- ═══ THIS NOW MOVES WHERE WE LOOK, NOT WHERE THE PROP STANDS ═══
        --
        -- It used to survey a spot to build a prop on. Nothing is built any
        -- more, so standing next to the display and typing this is how a
        -- configured coordinate that turns out to be too far off gets corrected:
        -- the search starts from the player instead.
        --
        -- AND IT NO LONGER TAKES HIS HEADING. It cannot -- the prop's facing
        -- belongs to the ymap and this command has no business rotating a piece
        -- of the map. `adopt` below reads the real one instead.
        local p = GetEntityCoords(PlayerPedId())
        ovX, ovY, ovZ = p.x, p.y, p.z
        forgetProp()

    elseif what == 'adopt' then
        -- ═══ WRITE DOWN WHAT THE PROP ACTUALLY IS ═══
        --
        -- The one command that turns the open question in config/board.lua into
        -- a measurement. The heading there was converted from the owner's
        -- quaternion and ymaps sometimes store the inverse of a rotation, so 135
        -- and 225 were both defensible from the four numbers alone. This reads
        -- the answer off the entity the ymap actually produced -- along with its
        -- true origin, which is also very likely a few centimetres from the
        -- coordinate anybody transcribes by hand.
        --
        -- NOTHING IS WRITTEN TO THE MAP OR TO DISK. It copies INTO the overrides,
        -- so the block printed below becomes the truth and pasting it into
        -- config/board.lua is what makes it permanent.
        if prop and isTrue(DoesEntityExist(prop)) then
            local c = GetEntityCoords(prop)
            ovX, ovY, ovZ = c.x, c.y, c.z
            ovH = GetEntityHeading(prop)
        else
            print('[br_core] board: brboard adopt needs the prop to be found '
                  .. 'first')
        end

    elseif what == 'fit' then
        -- ═══ PIN THE MEASUREMENT SO IT CAN BE PASTED ═══
        --
        -- forwardM, upM and widthM already come off GET_MODEL_DIMENSIONS while
        -- the config leaves them nil, so this changes nothing on screen. What it
        -- changes is the block below: a measured value is only a starting point
        -- until it is written down, and this is what puts three real numbers
        -- there to nudge from rather than three nils to wonder about.
        local f, u, w = fitted()
        if f then
            ovFwd, ovUp, ovW = f, u, w
        else
            print('[br_core] board: brboard fit needs the prop to be found first')
        end

    elseif what == 'static' then
        -- WHAT THE WALL LOOKS LIKE WHEN RINGMASTER IS DOWN, on demand. It is
        -- also the only way to see the static today, since nothing reports
        -- health yet (see BR.Board.health above).
        BR.Board.health(false)

    elseif what == 'live' then
        BR.Board.health(nil)

    elseif what == 'fwd'  then ovFwd  = nudge(cfgFwd(),  args[2]) or ovFwd
    elseif what == 'side' then ovSide = nudge(cfgSide(), args[2]) or ovSide
    elseif what == 'up'   then ovUp   = nudge(cfgUp(),   args[2]) or ovUp
    elseif what == 'w'    then ovW    = nudge(cfgW(),    args[2]) or ovW
    elseif what == 'yaw'  then ovYaw  = nudge(cfgYaw(),  args[2]) or ovYaw

    elseif what ~= '' then
        print('[br_core] board: brboard [fwd|side|up|w|yaw] <value|+delta> | '
              .. 'prop <model> | here | adopt | fit | static | live | reset')
    end

    -- ═══ THE READOUT, AND EVERY LINE OF IT SEPARATES TWO FAILURES THAT LOOK
    --     THE SAME FROM A CHAIR ═══
    --
    -- A board showing nothing can be: not in warmup, no prop configured, a model
    -- that never streamed, a browser that was never built, a license that never
    -- arrived, an address pointing at the static page, or a quad drawn out of
    -- range. All seven read as "the board is not there", and every one of them
    -- is a different line below.
    local p = GetEntityCoords(PlayerPedId())

    print('=== board ===')
    print(('  warmup %s   sited %s   dui %s   drawing %s')
        :format(tostring(onPad()), tostring(sited()),
                page and (BR.Dui.ready(page) and 'up' or 'starting') or 'none',
                tostring(inRange)))
    print(('  health %s   texture %dx%d   license %s')
        :format(health,
                math.tointeger(tonumber(C.width)) or 0,
                math.tointeger(tonumber(C.height)) or 0,
                license or 'none'))
    -- THE ADDRESS IN FORCE, NOT THE ONE WE ASKED FOR. page.url is written by
    -- BR.Dui.url as it navigates, so a board that is on the static page says so
    -- here rather than printing the board URL it is not showing.
    print(('  url    %s'):format((page and page.url) or wantUrl() or '-'))

    if prop and isTrue(DoesEntityExist(prop)) then
        local c = GetEntityCoords(prop)

        -- ═══ THE CONFIGURED HEADING BESIDE THE REAL ONE, AND THE DIFFERENCE ═══
        --
        -- config/board.lua's heading was converted from the owner's quaternion,
        -- and ymaps sometimes store the inverse of a rotation -- so 135 and 225
        -- were both readings the four numbers supported. THIS LINE SETTLES IT
        -- FROM A CHAIR. It steers no geometry either way (drawBoard builds its
        -- quad from the entity's own matrix), which is exactly why it is safe to
        -- print rather than dangerous to gate on.
        local real = GetEntityHeading(prop)
        local off = ((real - cfgH() + 180.0) % 360.0) - 180.0
        print(('  prop   %s   handle %d   FOUND at %s, %s, %s')
            :format(tostring(cfgModel()), prop, m(c.x), m(c.y), m(c.z)))
        print(('  facing %s   config says %s   off by %s')
            :format(m(real), m(cfgH()), m(off)))

        -- WHAT THE MODEL MEASURES, SO THE THREE FITTED NUMBERS ARE NOT MAGIC.
        -- Nobody has published this model's size and nobody needs to; this is
        -- where the board's default width came from and it is printed so it can
        -- be disbelieved.
        local d = box()
        if d then
            print(('  model  %s wide  %s tall  %s deep   front face at %s')
                :format(m(d.maxx - d.minx), m(d.maxz - d.minz),
                        m(d.maxy - d.miny), m(d.maxy)))
        else
            print('  model  NO BOX -- GetModelDimensions answered nothing usable')
        end
    else
        -- ⚠ "NOT FOUND" AND "NOT STANDING" ARE DIFFERENT CLAIMS AND THIS IS THE
        -- FIRST ONE. Nothing is spawned any more, so a board with no prop means
        -- the search missed: the model name is wrong, the coordinates are
        -- further than radiusM from it, or it has not streamed in yet. All three
        -- read as "no board" and the line below separates the third from the
        -- other two.
        print(('  prop   %s   NOT FOUND within %sm of the site')
            :format(tostring(cfgModel() or 'unset'), m(cfgRadius())))
    end
    print(('  you    %s, %s, %s   %sm from the site   draw range %sm')
        :format(m(p.x), m(p.y), m(p.z),
                haveSite() and m(BR.Dist(p.x, p.y, cfgX(), cfgY())) or '-',
                m(tonumber(C.drawM))))

    -- ═══ WHERE EACH OF THE FIVE IS COMING FROM, WHICH THE BLOCK BELOW CANNOT
    --     SHOW ═══
    --
    -- Three of them are nil in the shipped config and are measured off the prop,
    -- so the block prints a number for a field that does not carry one. Without
    -- this line, `widthM = 12.40` in the paste block and `widthM = nil` in the
    -- file look like a contradiction rather than the feature they are.
    print(('  source fwd %s  up %s  w %s   (side and yaw are always config)')
        :format(srcOf(ovFwd, C.forwardM), srcOf(ovUp, C.upM),
                srcOf(ovW, C.widthM)))

    -- PASTEABLE, WHICH IS THE POINT. These are the shapes they take in
    -- br_lib/config/board.lua, and every one starts from what the game is
    -- actually running -- a nudged value if he nudged it, a measured one if the
    -- config left it open, the shipped value if he did not -- so pasting the
    -- block back can never quietly zero a field he never touched.
    --
    -- FIVE DECIMALS ON THE COORDINATES, NOT TWO. They are the owner's own
    -- surveyed numbers and `adopt` replaces them with the entity's true origin;
    -- rounding either to a centimetre in the one place they get written down is
    -- this project throwing away precision it was handed. The block is spread
    -- over several lines for the same reason: it is the shape the config file
    -- actually has now, so it pastes rather than needing reformatting.
    print('  -- br_lib/config/board.lua')
    if cfgModel() and haveSite() then
        print('    prop = {')
        print(("        model   = '%s',"):format(cfgModel()))
        print(('        x       = %.5f,'):format(cfgX()))
        print(('        y       = %.5f,'):format(cfgY()))
        print(('        z       = %.5f,'):format(cfgZ()))
        print(('        radiusM = %.2f,'):format(cfgRadius()))
        print(('        heading = %.2f,'):format(cfgH()))
        print('    },')
    else
        print('    prop = { model = nil, x = nil, y = nil, z = nil, '
              .. 'radiusM = 8.0, heading = 0.0 },')
    end
    print(('    forwardM = %.2f,'):format(cfgFwd()))
    print(('    sideM    = %.2f,'):format(cfgSide()))
    print(('    upM      = %.2f,'):format(cfgUp()))
    print(('    widthM   = %.2f,'):format(cfgW()))
    print(('    yawDeg   = %.2f,'):format(cfgYaw()))
end

-- ═══ TWO NAMES, ONE IMPLEMENTATION ═══
--
-- Owner, 2026-09-11: "Just give me tools like `brscoreboard` or something to
-- adjust them."
--
-- /brboard already did everything he described and had done since it was built,
-- so the answer to that sentence is a NAME rather than a command: he reached for
-- `brscoreboard` because "the scoreboard" is what he calls this thing, and a
-- tool nobody can guess the name of is a tool nobody has. Both spellings run the
-- same function -- an alias and not a second implementation, because two
-- commands that tune the same five numbers are two commands that will one day
-- disagree about what they tune.
--
-- CONSOLE ONLY, and dev-gated BY CONSTRUCTION -- br_lib/shared/devgate.lua
-- replaces the global RegisterCommand with a gated wrapper before any br_core
-- file loads, so there is no third argument here. Passing `true` would make it
-- ace-restricted instead, which FiveM's client console refuses outright in
-- production mode.
RegisterCommand('brboard', runBoardCmd, false)
RegisterCommand('brscoreboard', runBoardCmd, false)
