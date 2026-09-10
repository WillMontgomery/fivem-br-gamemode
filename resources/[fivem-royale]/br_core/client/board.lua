-- The warmup-area stat board (#247): one browser, one prop, one quad.
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
-- The board shows a leaderboard and the viewer's own career, and swaps between
-- them. That swap lives entirely in the document Ringmaster serves; there is no
-- mode push, no timer and no message about it anywhere in this file. A DUI
-- repaints when its content changes and costs approximately nothing when it does
-- not, so a page that swaps itself is one repaint per swap on each machine, and
-- a page Lua drove would be the same repaints plus a message per swap per client
-- for nothing.
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

local function cfgModel() return ovModel or C.prop.model end
local function cfgX()     return ovX or tonumber(C.prop.x) end
local function cfgY()     return ovY or tonumber(C.prop.y) end
local function cfgZ()     return ovZ or tonumber(C.prop.z) end
local function cfgH()     return ovH or tonumber(C.prop.heading) or 0.0 end

local function cfgFwd()   return ovFwd  or tonumber(C.forwardM) or 0.0 end
local function cfgSide()  return ovSide or tonumber(C.sideM)    or 0.0 end
local function cfgUp()    return ovUp   or tonumber(C.upM)      or 0.0 end
local function cfgW()     return ovW    or tonumber(C.widthM)   or 1.0 end
local function cfgYaw()   return ovYaw  or tonumber(C.yawDeg)   or 0.0 end

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
    return type(cfgX()) == 'number'
       and type(cfgY()) == 'number'
       and type(cfgZ()) == 'number'
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

--- The object we built, or nil.
local prop = nil

--- The model hash it was built from, so a /brboard prop swap can notice.
local propHash = nil

--- Ask for the model, and answer whether it is here yet.
---
--- ═══ NO THREAD AND NO YIELD: THE REQUEST IS A STATE MACHINE ON THE TICK ═══
---
--- Model loading is asynchronous, and client/loot.lua's spawn worker says in its
--- own words that this "cannot live in a loop callback". That is true of a
--- WAIT-until-loaded loop, which is what it needs and what this does not: there
--- is exactly one model here, wanted once per warmup, and no burst to smooth
--- out. So this asks and returns, the tick comes back in 100ms, and the object
--- is built on whichever pass HasModelLoaded first says yes. No Citizen.Wait
--- inside a band callback, no thread of our own, and nothing for client/main.lua's
--- performance contract to object to.
--- @param hash integer
--- @return boolean
local function modelReady(hash)
    if isTrue(HasModelLoaded(hash)) then return true end
    RequestModel(hash)
    return false
end

--- Build the prop at its configured site.
---
--- SURVEYED COORDINATES, USED LITERALLY. No ground probe: config/board.lua
--- carries the same rule config/warmupcrates.lua and config/match.lua carry, and
--- for the same reason -- GetGroundZFor_3dCoord answers with the highest ground
--- BELOW the point it is given, and this project has been burned by trusting it
--- over a number somebody read off their own screen.
---
--- FROZEN AND NOT NETWORKED. It is a fixture, not a physics object: an unfrozen
--- board can be pushed by a player or a vehicle, and a networked one would be an
--- entity a client created, which sv_entityLockdown does not allow. Built the
--- same way client/loot.lua builds every crate.
local function buildProp()
    local hash = GetHashKey(cfgModel())
    if not modelReady(hash) then return end

    local obj = CreateObjectNoOffset(hash, cfgX(), cfgY(), cfgZ(),
                                     false, false, false)
    -- A HANDLE OF 0 IS "NOTHING WAS MADE", not an object.
    if not obj or obj == 0 then return end

    SetEntityHeading(obj, cfgH())
    FreezeEntityPosition(obj, true)
    SetEntityAsMissionEntity(obj, false, true)

    prop = obj
    propHash = hash

    -- RELEASED THE MOMENT IT IS SPENT. A model held by a RequestModel nobody
    -- ever releases is memory this client keeps for the rest of the session for
    -- an object that already exists.
    SetModelAsNoLongerNeeded(hash)
end

--- Take it down. An un-deleted local object outlives the resource that made it.
local function dropProp()
    if prop and isTrue(DoesEntityExist(prop)) then DeleteEntity(prop) end
    prop = nil
    propHash = nil
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

--- Everything down: the browser, the prop, and the range latch.
---
--- CALLED FROM THREE PLACES AND THEY ARE THE THREE THE ISSUE NAMES -- leaving
--- the warmup area, the match starting (which is the same edge, see onPad), and
--- the resource stopping. One function so the three cannot come to disagree
--- about what teardown means.
local inRange = false

local function teardown()
    killPage()
    dropProp()
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
        -- Gone, or never built. A /brboard prop swap deletes the old one and
        -- lands here on the next pass, so this is the ordinary path rather than
        -- an error path.
        prop = nil
        buildProp()
        if not prop then return end
    end

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
-- CONSOLE ONLY, and dev-gated BY CONSTRUCTION -- br_lib/shared/devgate.lua
-- replaces the global RegisterCommand with a gated wrapper before any br_core
-- file loads, so there is no third argument here. Passing `true` would make it
-- ace-restricted instead, which FiveM's client console refuses outright in
-- production mode.

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

RegisterCommand('brboard', function(_, args)
    local what = tostring(args[1] or ''):lower()

    if what == 'reset' then
        ovFwd, ovSide, ovUp, ovW, ovYaw = nil, nil, nil, nil, nil
        ovModel, ovX, ovY, ovZ, ovH = nil, nil, nil, nil, nil
        -- THE PROP GOES WITH THEM. Its model and its site are among the things
        -- being reset, and an object left standing at an overridden site while
        -- the numbers below read the config's is the readout lying.
        dropProp()

    elseif what == 'prop' then
        -- AUDITION A MODEL WITHOUT A CONFIG EDIT AND A RESTART. He has one in
        -- mind; this is how he sees it standing there before writing it down.
        local name = tostring(args[2] or '')
        if name == '' then
            print('[br_core] board: brboard prop <model>')
        else
            ovModel = name
            dropProp()
        end

    elseif what == 'here' then
        -- SURVEY BY STANDING ON THE SPOT, which is how every other placement in
        -- this project was measured. The prop takes the player's OWN heading, so
        -- it faces the way he is facing; `yaw 180` turns the board round without
        -- moving the prop.
        local p = GetEntityCoords(PlayerPedId())
        ovX, ovY, ovZ = p.x, p.y, p.z
        ovH = GetEntityHeading(PlayerPedId())
        dropProp()

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
              .. 'prop <model> | here | static | live | reset')
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
        print(('  prop   %s   handle %d   at %s, %s, %s   heading %s')
            :format(tostring(cfgModel()), prop, m(c.x), m(c.y), m(c.z),
                    m(GetEntityHeading(prop))))
    else
        print(('  prop   %s   NOT STANDING')
            :format(tostring(cfgModel() or 'unset')))
    end
    print(('  you    %s, %s, %s   %sm from the site   draw range %sm')
        :format(m(p.x), m(p.y), m(p.z),
                (cfgX() and m(BR.Dist(p.x, p.y, cfgX(), cfgY()))) or '-',
                m(tonumber(C.drawM))))

    -- PASTEABLE, WHICH IS THE POINT. These are the shapes they take in
    -- br_lib/config/board.lua, and every one starts from what the game is
    -- actually running -- a nudged value if he nudged it, the shipped value if
    -- he did not -- so pasting the block back can never quietly zero a field he
    -- never touched.
    print('  -- br_lib/config/board.lua')
    if cfgModel() and cfgX() then
        print(("    prop = { model = '%s', x = %.2f, y = %.2f, z = %.2f, "
               .. "heading = %.1f },")
            :format(cfgModel(), cfgX(), cfgY(), cfgZ(), cfgH()))
    else
        print('    prop = { model = nil, x = nil, y = nil, z = nil, '
              .. 'heading = 0.0 },')
    end
    print(('    forwardM = %.2f,'):format(cfgFwd()))
    print(('    sideM    = %.2f,'):format(cfgSide()))
    print(('    upM      = %.2f,'):format(cfgUp()))
    print(('    widthM   = %.2f,'):format(cfgW()))
    print(('    yawDeg   = %.2f,'):format(cfgYaw()))
end, false)
