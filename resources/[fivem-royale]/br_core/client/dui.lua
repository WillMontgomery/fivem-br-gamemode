-- DUI: browser pages rendered into game textures.
--
-- WHY THIS EXISTS SEPARATELY FROM NUI. The NUI page is one full-screen browser
-- layered over the game; anything drawn in it is positioned in SCREEN space,
-- and anything that has to follow a thing in the WORLD needs its screen
-- position recomputed and sent across the resource bridge every frame. That is
-- exactly what the loot prompt did, and it is why the text visibly trailed the
-- crate: the bridge is throttled, deliberately, because 60 messages a second
-- per prompt is not a thing to put on it.
--
-- A DUI is the other way round. The page renders off-screen into a runtime
-- TEXTURE, and Lua draws that texture with DrawSprite -- a native, per frame,
-- at whatever world position we like. Position costs nothing and never lags.
-- The page only hears from us when the CONTENT changes.
--
-- The cost is that a DUI is a whole browser instance, so they are created once
-- and reused, never per-object.

BR = BR or {}
BR.Dui = BR.Dui or {}

local pages = {}   -- [name] = { dui, txd, tex, w, h }

--- IN LUA 0 IS TRUTHY, AND A FIVEM NATIVE DECLARED BOOL MAY ANSWER 1 OR 0
--- RATHER THAN true OR false. Ten shipped bugs on this project and a ratchet in
--- tools/verify.sh to stop the eleventh. Same helper, same spelling, as
--- br_core/client/loot.lua's.
---
--- drawOnEntity's own raw read below is deliberately LEFT AS IT IS -- it is in
--- tools/bool_natives.baseline, and tightening a ratchet is a change of its own
--- rather than a rider on a shop fix.
--- @param v any
--- @return boolean
local function isTrue(v) return v == true or v == 1 end

--- Model bounding boxes, cached by model hash. A model's dimensions never
--- change, and drawOnEntity would otherwise ask the engine for them on every
--- frame the player is looking at a crate.
local DIMS = {}

--- The model's box, cached. nil when the model has not answered.
---
--- ONE CACHE FOR THE TWO DRAWS THAT NEED A BOX -- the label on a crate's lid and
--- the sign on a van's nearest face. They ask for different fields off the same
--- six numbers, and a second table keyed by the same model hash would be a
--- second GetModelDimensions per model for nothing.
--- @param model integer
--- @return table|nil  { minx, miny, minz, maxx, maxy, maxz }
local function modelBox(model)
    local d = DIMS[model]
    if d then return d end

    local a, b = GetModelDimensions(model)
    if not a or not b then return nil end
    d = { minx = a.x, miny = a.y, minz = a.z,
          maxx = b.x, maxy = b.y, maxz = b.z }
    DIMS[model] = d
    return d
end

-- ---------------------------------------------------------------------------
-- THE PLAYER'S INTERFACE SCALE
-- ---------------------------------------------------------------------------
--
-- A DUI IS A SECOND BROWSER AND IT HEARS NOTHING THE HUD HEARS. The settings
-- screen writes --ui-scale and --text-scale onto the NUI document's :root
-- (ui-src/src/settings/apply.ts); that document is a different browser from
-- this one, so a player who scaled their interface up got a HUD that grew and
-- world prompts that did not. This block is the missing wire.
--
-- SPLIT THE SAME WAY THE HUD SPLITS IT, and for the same reasons (index.css):
--
--   uiScale is INTERFACE SIZE. In the HUD it multiplies the root font size, so
--   the whole thing grows. Here it multiplies the SPRITE, in Lua, at draw
--   time -- which is the exact equivalent, because a DUI's on-screen size is
--   the sprite's and nothing else. Applied here rather than in the page for
--   two reasons: growing the content inside a fixed 512x256 texture would clip
--   it, and a number read per frame needs no message at all (see LIVE below).
--
--   textScale is PROSE ONLY, and it is the page's -- it has to be, because it
--   is the one part that must NOT grow the plate. It is sent to the page,
--   which applies it to the label and the hint and to nothing else, exactly as
--   `.tscale` does in the HUD. It is deliberately NOT applied to the hold ring
--   or the key cap: those are a fixed-size plate, which index.css names as the
--   one place text scaling must never land.
--
-- ONLY `text` GOES OVER THE WIRE. `ui` is applied here and is not sent, so
-- there is no way for a future edit to the page to apply it a second time and
-- square the player's preference.
--
-- LIVE, ON EXISTING PAGES, WITHOUT A RECONNECT. That is a requirement, not a
-- nicety -- a setting that needs a reconnect reads as broken:
--
--   the sprite half needs no push at all. Every draw multiplies by `prefs.ui`
--   as it runs, so changing this table changes the next frame, for every page
--   that already exists and every page made later. There is nothing to miss.
--
--   the prose half is pushed to EVERY LIVE PAGE on change (the handler at the
--   bottom of this file), and again the first frame each page's browser is
--   genuinely up -- a message sent to a CEF instance that has not finished
--   starting is simply lost, which is why `ready` is where the second push
--   lives rather than `page`.
local prefs = { ui = 1.0, text = 1.0 }

--- Coerce one preference off the wire. Never throws, never returns nil.
---
--- br_ui owns the REAL range (0.80..1.30 and 0.90..1.15; see its settings.lua,
--- which clamps before it stores and is the only thing a slider can reach).
--- The band here is deliberately wider and exists for a different reason: to
--- stop a hand-fired event or a stale build putting a nil, a NaN or a 400x
--- sprite on the frame path. Repeating br_ui's exact numbers here would give
--- the project two clamps to keep in step.
--- @param v any
--- @param fallback number
--- @return number
local function pref(v, fallback)
    v = tonumber(v)
    if not v or v ~= v then return fallback end   -- nil, or NaN, which compares false to itself
    if v < 0.5 then return 0.5 end
    if v > 2.0 then return 2.0 end
    return v
end

--- Tell one page the text-size preference. Cheap and idempotent: the page sets
--- a custom property from it and nothing else, so an extra send costs a
--- repaint and cannot restart the hold ring.
--- @param page table
local function pushScale(page)
    if not page or not page.dui then return end
    SendDuiMessage(page.dui, json.encode({ t = 'scale', text = prefs.text }))
end

--- Create (or fetch) a DUI page and its runtime texture.
---
--- @param name string   unique; also the texture name
--- @param url string    e.g. 'nui://br_ui/dui/prompt.html'
--- @param w integer     texture width in pixels
--- @param h integer     texture height
--- @return table page
function BR.Dui.page(name, url, w, h)
    if pages[name] then return pages[name] end

    local dui = CreateDui(url, w, h)
    local txd = CreateRuntimeTxd('br_dui_' .. name)
    CreateRuntimeTextureFromDuiHandle(txd, name, GetDuiHandle(dui))

    pages[name] = {
        dui = dui, txd = 'br_dui_' .. name, tex = name,
        w = w, h = h, ready = false,
        -- WHAT THIS BROWSER IS CURRENTLY POINTED AT. Recorded rather than
        -- assumed, because BR.Dui.url below can move it and a caller that has to
        -- report what is on screen (client/board.lua's /brboard) would otherwise
        -- be reading the address it asked for rather than the one in force.
        --
        -- MEMOISED ON `name`, WHICH MEANS THE URL ARGUMENT IS ONLY READ ONCE.
        -- A second call with the same name and a different url returns the
        -- FIRST page, unchanged -- so a caller whose address is not known at
        -- boot (again, the board: its URL contains a license the server has not
        -- sent yet) must not create the page until it has the real one.
        url = url,
    }
    return pages[name]
end

--- Send a message to a page. Cheap, but not free -- send on CHANGE, not per
--- frame; the whole point of a DUI is that the page does not need telling
--- about anything that has not changed.
--- @param page table
--- @param msg table
function BR.Dui.send(page, msg)
    if not page or not page.dui then return end
    SendDuiMessage(page.dui, json.encode(msg))
end

--- Point an existing page's browser somewhere else.
---
--- ═══ THIS IS HOW A PAGE CHANGES, AND RECREATING THE DUI IS NOT ═══
---
--- A DUI is a whole CEF instance: creating one costs a browser start, and
--- destroying one to show a different address means the runtime texture and the
--- txd go with it and every draw in flight is pointed at a texture that no
--- longer exists. #247 names the rule outright ("refresh via SendDuiMessage or
--- SetDuiUrl, never by recreating the DUI") and this is the second of those two.
---
--- SendDuiMessage IS STILL THE CHEAPER ONE and remains the right answer whenever
--- the page can update ITSELF from a message -- that is every page br_ui ships.
--- This is for the other case: a document served from somewhere else, which has
--- to be re-fetched to change, and its opposite, a local fallback page shown
--- when that fetch cannot happen.
---
--- IDEMPOTENT, AND THE GUARD IS NOT COSMETIC. This is reachable from a 10Hz pass
--- that re-decides which of two addresses should be up; without the comparison,
--- every one of those passes would reload the document, which for a page fetched
--- over the public internet is a request ten times a second from every client in
--- the lobby.
--- @param page table
--- @param url string
--- @return boolean moved  true only when the browser was actually sent somewhere
function BR.Dui.url(page, url)
    if not page or not page.dui then return false end
    if type(url) ~= 'string' or url == '' then return false end
    if page.url == url then return false end
    page.url = url
    SetDuiUrl(page.dui, url)
    return true
end

--- Is the page's browser actually up? Drawing before this is true renders a
--- blank (or last-frame) texture.
--- @param page table
--- @return boolean
function BR.Dui.ready(page)
    if not page or not page.dui then return false end
    if page.ready then return true end
    -- A NATIVE'S ANSWER IS NOT A LUA BOOLEAN (3b42f0e, #129/#131's seventh
    -- round). A FiveM native declared BOOL may hand Lua `true`, `1`, `false`,
    -- `nil` -- or `0`, and IN LUA THE NUMBER 0 IS TRUTHY. Stored verbatim, a
    -- `0` from a browser that is NOT up latches this page as ready forever on
    -- the first poll: the scale push below is fired at a CEF instance that
    -- cannot receive it, every draw puts a blank texture on the screen, and the
    -- caller's fallback -- the whole reason bus.lua and skydive.lua ask this
    -- question -- never runs, so nothing anywhere says the browser is missing.
    --
    -- Which is why this is an explicit three-way test and NOT `v and true or
    -- false`: that one-liner maps 0 to true and is the worse bug, verbatim the
    -- one 3b42f0e rejected. All four shapes the runtime is known to produce are
    -- covered without this file having to know which one this build uses.
    local up = IsDuiAvailable(page.dui)
    page.ready = (up ~= nil and up ~= false and up ~= 0)
    -- THE ONE MOMENT A MESSAGE TO THIS PAGE IS GUARANTEED TO LAND, and so the
    -- one place the scale can be handed to a NEW browser. A DUI is a whole CEF
    -- instance and messages sent before it has finished starting are dropped
    -- without a word -- so pushing from BR.Dui.page() would work on a warm
    -- reload and silently not work on a cold one, which is the worst of both.
    -- This runs once per page, on the false->true edge, because the line above
    -- latches `ready` and every caller enters through here.
    if page.ready then pushScale(page) end
    return page.ready
end

--- Draw a page in the world, facing the camera, shrinking with distance.
---
--- SetDrawOrigin projects a world position to the screen, but the sprite's
--- width and height stay SCREEN-space -- so without scaling, a prompt 40m away
--- would be exactly as large as one at arm's length. Scaling by inverse
--- distance restores the perspective the origin does not give us.
---
--- @param page table
--- @param x number
--- @param y number
--- @param z number
--- @param scale number   size at 1m, in screen fractions
--- @param dist number    distance to the camera
function BR.Dui.drawWorld(page, x, y, z, scale, dist)
    if not BR.Dui.ready(page) then return end

    -- A FIXED SIZE BY DEFAULT.
    --
    -- This used to scale as 3/dist, clamped to 0.35..1.6 -- so the prompt grew
    -- as the player walked in, which read as the label inflating in their face
    -- rather than as perspective ("a bit jarring", user 2026-08-06). The
    -- prompt is UI pinned to a world point, not an object in the world, and UI
    -- does not change size. Pass a `dist` only where the old behaviour is
    -- actually wanted.
    local k = (scale or 1.0)
    if dist then
        k = BR.Clamp(3.0 / math.max(dist, 0.5), 0.35, 1.6) * k
    end
    -- 0.12 -> 0.09: a quarter smaller (user, 2026-08-06).
    --
    -- ...AND THEN THE PLAYER'S OWN INTERFACE SIZE. Last, so it multiplies the
    -- finished number rather than one of the terms: a prompt at 1.30 is 30%
    -- larger than the same prompt at 1.00 whatever the caller passed and
    -- whatever the distance term did. `h` follows from `w` below, so the plate
    -- grows in both directions and its aspect is untouched.
    local w = 0.09 * k * prefs.ui

    -- ASPECT MATTERS, and leaving it out is what squashed the prompt.
    --
    -- DrawSprite's width and height are fractions of the SCREEN's width and
    -- height respectively -- different units. A 512x256 texture drawn at
    -- w=0.12, h=0.06 is only square if the screen is, and on 16:9 it came out
    -- half as tall as it should. Multiplying by the aspect converts one unit
    -- into the other.
    --
    -- GetAspectRatio, NOT the resolution. They agree on an ordinary 16:9
    -- monitor and diverge exactly where it matters: ultrawide, letterboxed and
    -- multi-monitor setups, where the RENDERED aspect is not the window's.
    -- GetAspectRatio is what the renderer itself uses, so it is what a sprite
    -- drawn by the renderer has to be corrected by -- and it means 21:9 needs
    -- no special case at all (user, 2026-08-06).
    local aspect = GetAspectRatio(false)
    if not aspect or aspect <= 0.1 then
        local sw, sh = GetActiveScreenResolution()
        aspect = (sh and sh > 0) and (sw / sh) or 1.7778
    end
    local h = w * (page.h / page.w) * aspect

    SetDrawOrigin(x, y, z, 0)
    DrawSprite(page.txd, page.tex, 0.0, 0.0, w, h, 0.0, 255, 255, 255, 255)
    ClearDrawOrigin()
end

--- THE ENTITY'S OWN AXES, FLATTENED INTO THE WORLD'S XY PLANE.
---
--- ═══ THE LEVELLING IS 08d7608's AND THE ARGUMENT BELONGS TO IT ═══
---
--- Owner, 2026-08-30: "can you make sure they're always drawn perfectly level?
--- For example the sanchez tilts a bit on the kickstand, and now it's DUI tilts
--- lol."
---
--- NO EULER ANGLES ARE READ HERE, SO NO ROTATION ORDER IS CHOSEN. Asking
--- GET_ENTITY_ROTATION would force one (this repo asks for 2, ROT_ZXY --
--- client/natives.lua's probe and client/loot.lua's crate pose) and would then
--- need rebuilding into a basis. None of that is necessary: a roll turns the
--- body about its own forward axis, and a rotation leaves the axis it turns
--- about alone, so GET_ENTITY_FORWARD_VECTOR -- which is the matrix's forward
--- column, not a decomposition -- already has the kickstand lean divided out of
--- it. Flattening it into the world's XY plane divides out the pitch as well,
--- and "level" is exactly those two.
---
--- EXTRACTED RATHER THAN COPIED WHEN THE NEAREST-FACE SIGN ARRIVED (owner,
--- 2026-08-31). Two signs each flattening a forward vector of their own is two
--- places that can come to disagree about what level means, and this one has
--- already been got wrong once -- 08d7608 is the fix, and it is one function
--- now rather than a paragraph to re-read.
---
--- ═══ WHO STILL WANTS LEVEL, AFTER #294 ═══
---
--- Three callers, and the list is short enough to keep here rather than grep
--- for: drawFace (the showroom's yard sign, which is the complaint above),
--- drawBoard (the warmup board, which is drawFace with a lateral and a yaw), and
--- faceOf -- where it no longer orients anything and is only used to ask which
--- panel a player is standing beside, which is a horizontal question.
---
--- THE NEAREST-FACE PLATE IS NO LONGER ONE OF THEM. It is bolted to bodywork
--- rather than planted in front of it, so it takes its orientation from the
--- entity's matrix (drawPanel). Leveling it is what #294 was.
--- @param entity integer
--- @return number|nil fx, number fy, number rx, number ry  forward then right
local function levelBasis(entity)
    local f = GetEntityForwardVector(entity)
    local fx, fy = f.x, f.y
    local flat = math.sqrt(fx * fx + fy * fy)
    -- A vehicle stood exactly on its nose has no heading left to read. It cannot
    -- happen to a frozen showroom car, and a quad of nans is a worse failure than
    -- a missing frame.
    if flat < 0.0001 then return nil end
    fx, fy = fx / flat, fy / flat
    -- The entity's OWN +X, flattened: at heading h forward is (-sin h, cos h) and
    -- right is (cos h, sin h), so (fy, -fx) is the right vector.
    return fx, fy, fy, -fx
end

--- FOUR CORNERS, WOUND TOWARD THE CAMERA, AS TWO TRIANGLES.
---
--- ═══ THE ARRANGEMENT THAT WAS ALWAYS MEANT TO BE ONE, LIFTED OUT SO IT IS ═══
---
--- drawPlane's header has said since #236 that the normal, the camera-side test,
--- the two triangles and their UVs are "one proven arrangement that is
--- deliberately not re-derived per caller". That stayed true only while every
--- caller wanted the same corners. #294 breaks that: drawNearFace's plate is
--- glued to a panel and takes its corners from the entity's matrix, while the
--- yard sign and the warmup board stay level. Two corner derivations, one tail
--- -- so the tail moves here rather than being pasted a second time.
---
--- NOT ONE LINE OF IT CHANGED IN THE MOVE. The vertex order, the UV triples and
--- the sign of the camera test are lifted verbatim; `a` is still the texture's
--- top-left and the reader's left is still whoever built the corners' problem.
---
--- TWELVE NUMBERS RATHER THAN FOUR TABLES, deliberately. This runs per frame per
--- plate inside a FRAME band, and four table constructors a frame is garbage
--- this file has no reason to make.
--- @param page table
--- @param ax number  the texture's top-left corner...
--- @param ay number
--- @param az number
--- @param bx number  ...top-right...
--- @param by number
--- @param bz number
--- @param cx number  ...bottom-left...
--- @param cy number
--- @param cz number
--- @param dx number  ...and bottom-right
--- @param dy number
--- @param dz number
--- @param alpha number|nil
local function drawQuad(page, ax, ay, az, bx, by, bz, cx, cy, cz, dx, dy, dz,
                        alpha)
    -- WHICH SIDE THE CAMERA IS ON. DrawSpritePoly is single-sided, so a quad
    -- wound for one side is invisible from the other -- and at a five-meter
    -- reach on a four-meter car the player is regularly behind the bumper. The
    -- winding swaps; the vertex-to-UV mapping does NOT, so the sign reads
    -- correctly from the front and (as any real sign does) backwards from
    -- behind, rather than vanishing.
    local ux, uy, uz = bx - ax, by - ay, bz - az
    local vx, vy, vz = cx - ax, cy - ay, cz - az
    local nx = uy * vz - uz * vy
    local ny = uz * vx - ux * vz
    local nz = ux * vy - uy * vx

    local cam = GetGameplayCamCoord()
    local mx, my, mz = (ax + dx) * 0.5, (ay + dy) * 0.5, (az + dz) * 0.5
    local flip = (nx * (cam.x - mx) + ny * (cam.y - my) + nz * (cam.z - mz)) < 0.0

    local a = alpha or 255
    local txd, tex = page.txd, page.tex

    if flip then
        DrawSpritePoly(ax, ay, az, cx, cy, cz, bx, by, bz,
            255, 255, 255, a, txd, tex,
            0.0, 0.0, 1.0,  0.0, 1.0, 1.0,  1.0, 0.0, 1.0)
        DrawSpritePoly(cx, cy, cz, dx, dy, dz, bx, by, bz,
            255, 255, 255, a, txd, tex,
            0.0, 1.0, 1.0,  1.0, 1.0, 1.0,  1.0, 0.0, 1.0)
    else
        DrawSpritePoly(ax, ay, az, bx, by, bz, cx, cy, cz,
            255, 255, 255, a, txd, tex,
            0.0, 0.0, 1.0,  1.0, 0.0, 1.0,  0.0, 1.0, 1.0)
        DrawSpritePoly(cx, cy, cz, bx, by, bz, dx, dy, dz,
            255, 255, 255, a, txd, tex,
            0.0, 1.0, 1.0,  1.0, 0.0, 1.0,  1.0, 1.0, 1.0)
    end
end

--- Draw the page as an UPRIGHT QUAD standing out along a level direction.
---
--- The shared body of the YARD SIGN AND THE WARMUP BOARD: they differ only in
--- which direction is "out", and everything after the corners is drawQuad's.
---
--- ═══ NOT THE NEAREST-FACE PLATE ANY MORE (#294) ═══
---
--- drawNearFace used to come through here too, and that was the bug: this
--- function stands a quad up along a LEVEL direction with the WORLD's up for its
--- height, so a plate bolted flush to an ambulance's flank could not follow the
--- flank when the ambulance leaned. It builds its corners in drawPanel below
--- instead. The two signs that genuinely want level are still here and still
--- share every line of it.
---
--- ═══ WHICH WAY ROUND "TOP-LEFT" IS, BECAUSE MIRRORED TEXT IS THE FAILURE ═══
---
--- A player reading the sign stands OUTSIDE it looking back along `-out`.
--- Facing that way with the world's up over their head, their LEFT hand points
--- along (out.y, -out.x) -- so that is where the texture's left edge goes. Get
--- this backwards and the sign renders perfectly, in mirror writing, from the
--- only side anybody stands on. (For the front face `out` is the entity's
--- forward, and this expression is its right vector, which is what the yard sign
--- has always used.)
---
--- NO ASPECT CORRECTION AND NO DISTANCE TERM. Both exist in drawWorld only
--- because a screen-space sprite needs them; a quad measured in metres has one
--- unit, and perspective is the renderer's job.
--- @param page table
--- @param px number      the entity's own position...
--- @param py number
--- @param pz number
--- @param ox number      ...the level unit direction the sign stands out along...
--- @param oy number
--- @param dist number    ...how far out along it the sign's centre sits...
--- @param side number|nil ...how far ALONG THE FACE from there, positive to the
---                       reader's right. Derived from `out` and nothing else --
---                       see below -- so a sign slid sideways is still on the
---                       same panel, still level, still the same distance off
---                       the bodywork, and still the right way round.
--- @param oz number      ...and how far straight UP the world from the entity's
---                       origin. Up the WORLD rather than up the entity: `oz` is
---                       a height read off the model's own box, and pushed
---                       through a rolled bike's matrix that height swings out
---                       sideways and hangs a level sign off to one side.
--- @param hw number      half width, and half height, in metres
--- @param hh number
--- @param alpha number|nil
local function drawPlane(page, px, py, pz, ox, oy, dist, side, oz, hw, hh, alpha)
    -- The reader's LEFT. See above; this is the one line that decides whether
    -- the words come out the right way round.
    --
    -- ═══ AND IT IS THE LINE THE LATERAL IS SPENT ALONG, WHICH IS THE POINT ═══
    --
    -- "left" and "right" are already decided here, once, for the text. Sliding
    -- the sign along the SAME vector is what makes a plate nudged right come out
    -- to the right of where it was FROM THE SIDE ANYBODY READS IT -- on the tail
    -- of a van as much as on its nose, with no second opinion about which way
    -- round the face is. A lateral derived anywhere else would be free to
    -- disagree with the writing on it, and the symptom would be a plate that
    -- moves the wrong way on two of the four faces.
    --
    -- SUBTRACTED, BECAUSE POSITIVE IS THE READER'S RIGHT and this is their left.
    local lx, ly = oy, -ox
    local s = tonumber(side) or 0.0
    local cx0 = px + ox * dist - lx * s
    local cy0 = py + oy * dist - ly * s
    local cz0 = pz + oz

    local function corner(sx, sz)
        return cx0 + lx * sx, cy0 + ly * sx, cz0 + sz
    end

    local ax, ay, az = corner( hw,  hh)   -- top-left
    local bx, by, bz = corner(-hw,  hh)   -- top-right
    local cx, cy, cz = corner( hw, -hh)   -- bottom-left
    local dx, dy, dz = corner(-hw, -hh)   -- bottom-right

    drawQuad(page, ax, ay, az, bx, by, bz, cx, cy, cz, dx, dy, dz, alpha)
end

--- Draw the page as a QUAD BOLTED FLAT TO ONE FACE OF AN ENTITY (#294).
---
--- ═══ THE REPORT, TWICE ═══
---
---   "feedback on the ambulance DUIs - they're not fixed to the rotation of the
---    ambulance entity - an ambulance on a slope has DUIs clipping through when
---    I try to use it"                                     -- owner, 2026-09-07
---
---   "the ambulance DUIs are still not positioned with rotation to match the
---    ambulance entity...."                                -- owner, 2026-09-11
---
--- ═══ WHY THE FIRST ANSWER COULD NOT HAVE WORKED ═══
---
--- The plate came through drawPlane, which is handed a LEVELED direction --
--- `levelBasis` normalizes the forward vector's x and y and throws its z away --
--- and stands the quad up along the WORLD's up. So the plate was level BY
--- CONSTRUCTION, before any correction ran. 2026-09-07's answer added a `lean`
--- term that measured how far the real panel had swung and pushed the plate
--- further out to clear it. That is a plate held off a surface it is not
--- parallel to: it stops the worst of the clipping at one height and leaves the
--- plate visibly out of true with the bodywork everywhere else, which is what
--- "still not positioned with rotation to match" describes. The term is gone
--- rather than layered under this, because it was correcting for this.
---
--- ═══ WHAT THIS DOES INSTEAD: THE QUAD IS BUILT IN THE ENTITY'S OWN SPACE ═══
---
--- Every number the caller tunes is already a measurement on the model -- the
--- face's `reach` comes off GET_MODEL_DIMENSIONS' box, `oz` is a height up that
--- same box (BR.ShopSolve.signHeight), and `out` and `side` are meters off and
--- along the panel. They were being spent half in the model's frame and half in
--- the world's, and the seam between those two frames IS the bug. So the whole
--- quad is laid out in the entity's own axes and every corner goes out through
--- GET_OFFSET_FROM_ENTITY_IN_WORLD_COORDS -- the entity's full matrix, yaw,
--- pitch and roll together. There is no orientation maths here to get wrong, the
--- plate is parallel to its panel at every attitude, and it stands exactly `out`
--- meters off it measured perpendicular to the panel rather than along a level
--- line that no longer touches it.
---
--- drawOnEntity below has bought its anchoring the same way since 2026-08-06 and
--- its header says why. This is that decision, for a quad stood on a side rather
--- than laid on a lid.
---
--- ═══ AND IT IS THE SAME QUAD ON FLAT GROUND, WHICH IS WHY IT IS SAFE ═══
---
--- With no pitch and no roll the entity's matrix is a yaw and a translation, and
--- a yaw maps the entity's own axes onto exactly the vectors `levelBasis`
--- returns and its own up onto the world's. So corner for corner this agrees
--- with drawPlane to floating point on every vehicle standing flat, and every
--- number the owner has tuned by eye is where he left it. Only a leaning vehicle
--- moves -- which is the whole of the report. tools/test_shop.lua section 7c
--- executes both halves of that claim rather than trusting this paragraph.
---
--- FOUR MATRIX READS A FRAME, which is what drawOnEntity has always spent on a
--- crate label. It replaces three reads on the old path (the basis, the entity's
--- coordinates and the `lean` probe), so the plate is one native a frame dearer
--- than the bug was.
--- @param page table
--- @param entity integer  the entity the plate is bolted to
--- @param ux number       the face's outward normal IN THE ENTITY'S OWN AXES --
--- @param uy number       one of (0,1) (0,-1) (1,0) (-1,0)
--- @param dist number     meters out along it, from the entity's origin
--- @param side number|nil meters ALONG the face, positive to the reader's right
--- @param oz number       meters up the ENTITY -- not up the world, which is the
---                        difference: this height is read off the model's own box
---                        and belongs on the panel, wherever the panel has got to
--- @param hw number       half width, and half height, in meters
--- @param hh number
--- @param alpha number|nil
local function drawPanel(page, entity, ux, uy, dist, side, oz, hw, hh, alpha)
    -- The reader's LEFT, in the entity's own axes. drawPlane takes (out.y,
    -- -out.x) of a world direction for the same reason and with the same
    -- consequence if it is reversed -- a sign that renders perfectly, in mirror
    -- writing, from the only side anybody stands on. At the nose (ux, uy) is
    -- (0, 1) and this is the entity's +X, which is drawFace's answer too.
    --
    -- SUBTRACTED, BECAUSE POSITIVE IS THE READER'S RIGHT and this is their left.
    local lx, ly = uy, -ux
    local s = tonumber(side) or 0.0
    local cx0 = ux * dist - lx * s
    local cy0 = uy * dist - ly * s

    local function corner(sx, sz)
        local v = GetOffsetFromEntityInWorldCoords(entity,
                                                   cx0 + lx * sx,
                                                   cy0 + ly * sx,
                                                   oz + sz)
        return v.x, v.y, v.z
    end

    local ax, ay, az = corner( hw,  hh)   -- top-left
    local bx, by, bz = corner(-hw,  hh)   -- top-right
    local cx, cy, cz = corner( hw, -hh)   -- bottom-left
    local dx, dy, dz = corner(-hw, -hh)   -- bottom-right

    drawQuad(page, ax, ay, az, bx, by, bz, cx, cy, cz, dx, dy, dz, alpha)
end

--- Draw a page as a FIXED SIGN STANDING ON AN ENTITY'S FRONT FACE (#236).
---
--- ═══ THIS IS THE OPPOSITE OF drawWorld, DELIBERATELY ═══
---
--- Owner, 2026-08-30: "The store DUIs are dynamically sized and face the player.
--- I want them to be stationary, with the DUI displayed on the front face of the
--- vehicle, akin to a yard sign."
---
--- BOTH HALVES OF THAT COMPLAINT ARE ONE CALL. `drawWorld` is
--- SetDrawOrigin + DrawSprite: the origin projects a world point to the screen
--- and the sprite is then sized in SCREEN fractions, so the plate is a billboard
--- (always square to the camera) AND a constant fraction of the display (so
--- walking away makes it grow relative to the car). Neither is a knob on that
--- function -- they are what the two natives do.
---
--- SO THIS DRAWS THE QUAD IN THE WORLD INSTEAD, in metres, squared to the
--- entity's HEADING and level with the horizon. Walk round the car and the sign
--- turns with the car, because its width lies along the car's own forward
--- vector; lean the car and the sign does not lean, because that vector is
--- flattened first (the block in the body has the whole argument). Nothing here
--- reads the camera except to decide which way to wind the triangles.
---
--- THE SAME PLUMBING AS drawOnEntity, STOOD UP -- BUT DELIBERATELY NOT THE SAME
--- BASIS ANY MORE. That one lays a label FLAT on a crate's roof (local X by
--- local Y at a fixed Z) and takes its corners from the entity's whole matrix,
--- pitch and roll included, which its own header records as the point of it;
--- this one stands a sign UPRIGHT in front of a bumper (the car's flattened
--- forward by the world's up) and drops the lean. Everything downstream of the
--- corners -- the normal, the camera-side test, the two triangles and their
--- UVs -- is the same proven arrangement and is deliberately not re-derived.
---
--- WHICH WAY ROUND "TOP-LEFT" IS, BECAUSE MIRRORED TEXT IS THE FAILURE HERE. A
--- player reading the sign stands IN FRONT of the car looking back along the
--- car's -Y. Facing that way, the car's +X is on their LEFT -- so the texture's
--- left edge is at +hw and not at -hw. Get this backwards and the sign renders
--- perfectly, in mirror writing, from the only side anybody stands on.
---
--- NO ASPECT CORRECTION AND NO DISTANCE TERM. Both exist in drawWorld only
--- because a screen-space sprite needs them; a quad measured in metres has one
--- unit, and perspective is the renderer's job. `prefs.ui` still applies: the
--- interface-size preference is the player's, and a sign is interface.
---
--- @param page table
--- @param entity integer  the vehicle the sign is bolted to
--- @param oy number       metres along the entity's heading from its origin to
---                        the sign's centre
--- @param oz number       metres straight up from the entity's origin to the
---                        sign's centre
--- @param widthM number   how wide the sign is, in metres; height follows the
---                        page's own aspect
--- @param alpha number|nil
function BR.Dui.drawFace(page, entity, oy, oz, widthM, alpha)
    if not BR.Dui.ready(page) then return end
    if not entity or entity == 0 or not isTrue(DoesEntityExist(entity)) then
        return
    end

    local hw = ((tonumber(widthM) or 0.75) * 0.5) * prefs.ui
    if hw <= 0.0 then return end
    local hh = hw * (page.h / page.w)

    -- ═══ LEVEL IN THE WORLD, NOT WELDED TO THE WHOLE MATRIX ═══
    --
    -- The corners used to come from GET_OFFSET_FROM_ENTITY_IN_WORLD_COORDS,
    -- which multiplies an offset through the entity's FULL 3x3 -- heading,
    -- pitch and roll together. So the sign was the vehicle's local X-by-Z
    -- rectangle and wore every degree the vehicle wore, and a bike parked on
    -- its kickstand really is rolled. `levelBasis` above is the cure and carries
    -- the whole argument for it.
    --
    -- ═══ AND IT IS THIS FUNCTION THAT WANTS LEVEL, NOT EVERY SIGN (#294) ═══
    --
    -- Two other draws in this file keep the whole matrix, and the divergence is
    -- the point rather than an inconsistency to tidy up. drawOnEntity's header
    -- (the "STUCK TO AN ENTITY'S TOP FACE" block) records the 2026-08-06 bug
    -- where a label that ignored pitch and roll lay dead flat beside a crate
    -- resting on a slope; drawPanel's records 2026-09-07 and 2026-09-11, where a
    -- plate bolted flush to an ambulance's flank could not follow the flank.
    --
    -- WHAT SEPARATES THEM IS WHETHER THE PAGE IS ON THE ENTITY OR IN FRONT OF
    -- IT. A label stuck to a lid follows the lid, and a plate flush to a panel
    -- follows the panel, because both ARE the surface. A yard sign is planted in
    -- the ground in FRONT of a car the player is shopping for -- it is not on
    -- the bodywork, nothing about it is measured off the bodywork, and the owner
    -- asked in as many words for it to stay level when a Sanchez leans on its
    -- kickstand. Same for the warmup board on its prop. Do not "make them
    -- consistent"; the question is what the page is attached to.
    local fx, fy = levelBasis(entity)
    if not fx then return end

    -- THE NOSE IS JUST ONE DIRECTION TO STAND OUT ALONG, and it is this
    -- function's only one. `oy` is the distance along it; drawNearFace below
    -- picks a different direction from the same basis and spends it the same
    -- way. Left and right are the READER'S, which drawPlane owns.
    local p = GetEntityCoords(entity)
    -- NO LATERAL. The yard sign stands on the centre of the nose and the owner
    -- approved it there; a nil would do the same thing, and 0.0 says the
    -- decision was made rather than skipped.
    drawPlane(page, p.x, p.y, p.z, fx, fy, oy, 0.0, oz, hw, hh, alpha)
end

--- Draw a page as a BOARD BOLTED TO A PROP, with a lateral and a yaw (#247).
---
--- ═══ IT IS drawFace's BASIS AND drawFace's QUAD, WITH TWO MORE TERMS ═══
---
--- Everything that was hard about the yard sign is `levelBasis` and `drawPlane`
--- above -- leveling a prop that is not sitting square, getting the reader's
--- left the right way round so the writing is not mirrored, winding the two
--- triangles toward the camera so the board is not invisible from the side
--- everybody stands on, and measuring the whole thing in meters. All of it is
--- shared verbatim rather than reasoned about a second time, and at yaw 0 with
--- no lateral this function IS drawFace. tools/test_board.lua asserts that
--- equality, because two quads that were meant to be the same geometry and
--- quietly diverged is the failure worth pinning.
---
--- ═══ WHY THE WARMUP BOARD NEEDS THE TWO drawFace DOES NOT HAVE ═══
---
--- Owner, 2026-09-09: "I already have a prop in mind for this. Not sure how to
--- put the DUI on it though... I can help align it if you give me the tools."
---
--- Aligning means moving it, and a showroom yard sign only ever had to stand on
--- the middle of a nose:
---
---   THE LATERAL is the same argument client/revivekey.lua's plate already won
---   ("I need to be able to move it left/right as well"). It is spent along the
---   line that already decides the reader's left, inside drawPlane, so a board
---   nudged right goes right FROM WHERE IT IS READ and the offset can never
---   disagree with the writing on it.
---
---   THE YAW EXISTS BECAUSE A PROP'S FORWARD IS THE MODELLER'S CHOICE. drawFace
---   stands its sign out along the entity's own forward vector, which is right
---   for a car (a car's nose is unambiguous) and is a guess for a prop: plenty
---   of GTA props face along their local -Y, or are authored square to a wall
---   they were meant to hang on. Without this term, aligning the board would
---   mean rotating the PROP away from the direction the owner wants the prop
---   itself to face, which is a fix that breaks the thing it is fixing.
---
--- ROTATED IN THE LEVELED PLANE, AFTER LEVELING AND NOT INSTEAD OF IT. The yaw
--- turns the flattened forward vector about the WORLD's up, so a board turned 90
--- degrees on a prop standing on a slope is still level and still upright. It is
--- degrees, positive counter-clockwise seen from above, and both of those are
--- asserted rather than described: 360 is the identity only if the unit is
--- degrees, and the sense is a 2D cross product rather than an angle comparison,
--- which would read the same for 90 and 270.
---
--- @param page table
--- @param entity integer  the prop the board is bolted to
--- @param fwd number      meters out along the (yawed) facing to the board's centre
--- @param side number     meters along the face, positive to the READER'S right
--- @param up number       meters straight up the WORLD from the prop's origin
--- @param widthM number   how wide, in meters; the height follows the page's aspect
--- @param yawDeg number|nil  degrees off the prop's own facing, CCW from above
--- @param alpha number|nil
function BR.Dui.drawBoard(page, entity, fwd, side, up, widthM, yawDeg, alpha)
    if not BR.Dui.ready(page) then return end
    if not entity or entity == 0 or not isTrue(DoesEntityExist(entity)) then
        return
    end

    local hw = ((tonumber(widthM) or 0.75) * 0.5) * prefs.ui
    if hw <= 0.0 then return end
    local hh = hw * (page.h / page.w)

    local fx, fy = levelBasis(entity)
    if not fx then return end

    -- THE TURN, IN THE PLANE levelBasis JUST FLATTENED. `(x, y)` to
    -- `(x cos - y sin, x sin + y cos)` is the counter-clockwise rotation about
    -- +Z, and +Z is the world's up here rather than the prop's -- which is the
    -- whole reason the leveling above is not undone by this line.
    local yaw = tonumber(yawDeg) or 0.0
    if yaw ~= 0.0 then
        local r = math.rad(yaw)
        local c, s = math.cos(r), math.sin(r)
        fx, fy = fx * c - fy * s, fx * s + fy * c
    end

    local p = GetEntityCoords(entity)
    drawPlane(page, p.x, p.y, p.z, fx, fy,
              tonumber(fwd) or 0.0, tonumber(side) or 0.0, tonumber(up) or 0.0,
              hw, hh, alpha)
end

--- Which face of a vehicle a point is nearest to, and everything the caller
--- needs to spend that answer.
---
--- ═══ EXTRACTED BECAUSE THE FACE IS NOW A QUESTION AS WELL AS A STEP ═══
---
--- The owner tuned the revive plate FOUR TIMES, once per panel, and gave four
--- different sets of numbers (br_lib/config/revivekey.lua). So the caller has to
--- know which face it is on BEFORE it can say how far off the panel to stand --
--- which is the answer this used to compute half way through drawing.
---
--- ONE DERIVATION, TWO ENTRY POINTS. BR.Dui.nearFace below and drawNearFace
--- underneath it both come through here with the same arguments, so a caller
--- that asks which face it is on and then draws on that face cannot be told two
--- different things in one frame. A second copy of these six lines would be free
--- to disagree with this one the day `levelBasis` changes, and the symptom would
--- be a plate drawn on the tail wearing the nose's numbers.
---
--- NIL WHEN THE MODEL HAS NOT ANSWERED, which both callers propagate rather than
--- guess through: BR.NearestBoxFace's own header explains what a box of zeroes
--- does, and a `modelBox` that is still nil has not even got that far.
---
--- ═══ THE PICK IS STILL LEVELED, AND ONLY THE PICK (#294) ═══
---
--- This used to hand its caller the leveled basis as well, and drawNearFace
--- built the plate's orientation out of it. That was the bug, and the plate is
--- built from the entity's own matrix now -- so the only thing left here that is
--- leveled is the QUESTION, "which panel is the player standing beside".
---
--- THAT ONE GENUINELY IS A HORIZONTAL QUESTION. A player is on the ground beside
--- a van; flattening the displacement into the van's own heading answers where
--- they are standing, and it answers it identically for a van on a slope and the
--- same van on the flat. Running the pick through the full matrix instead would
--- move the plate to a different PANEL on a tilted van -- and a different panel
--- means a different one of the owner's four tuned sets of five
--- (br_lib/config/revivekey.lua), which is a second behavior change nobody
--- reported. The report is that the plate does not lie on the panel, not that it
--- is on the wrong panel.
--- @param entity integer
--- @param px number
--- @param py number
--- @return number|nil ux, number uy, number reach  the face IN THE ENTITY'S OWN
---                        AXES, and meters from the entity's ORIGIN out to its
---                        plane. All three are the model's own numbers, and
---                        drawPanel spends them without leaving that frame.
local function faceOf(entity, px, py)
    local fx, fy, rx, ry = levelBasis(entity)
    if not fx then return nil end

    local box = modelBox(GetEntityModel(entity))
    if not box then return nil end

    -- THE PLAYER, IN THE VEHICLE'S OWN LEVEL AXES. A dot product against each
    -- basis vector and nothing else -- no world-to-local native, no matrix, and
    -- no second flattening. `lx` is metres along the van's right, `ly` metres
    -- along its nose, which is the frame the model's box is written in.
    local p = GetEntityCoords(entity)
    local dx, dy = px - p.x, py - p.y
    local lx = dx * rx + dy * ry
    local ly = dx * fx + dy * fy

    local ux, uy, reach = BR.NearestBoxFace(lx, ly, box.minx, box.maxx,
                                            box.miny, box.maxy)
    return ux, uy, reach
end

--- WHICH FACE, WITHOUT DRAWING ANYTHING.
---
--- For a caller whose plate NUMBERS depend on the panel it is about to draw on
--- -- client/revivekey.lua, which holds one set of five per face because the
--- owner measured one set per face. It asks this, looks its numbers up, and
--- hands them to drawNearFace; that call resolves the same face through `faceOf`
--- from the same point in the same frame and therefore agrees by construction.
---
--- IT IS NOT A CACHED FIELD FOR THE SAME REASON. A "last face" left over from
--- the previous frame is a plate that wears the wrong panel's numbers for one
--- frame every time the player walks round a corner of the van -- which is
--- exactly when they are looking at it.
--- @param entity integer
--- @param px number  the point the nearest face is nearest to
--- @param py number
--- @return number|nil ux, number uy  one of (0,1) (0,-1) (1,0) (-1,0), in the
---                        vehicle's own axes. nil when the model has not
---                        answered with a box.
function BR.Dui.nearFace(entity, px, py)
    if not entity or entity == 0 or not isTrue(DoesEntityExist(entity)) then
        return nil
    end
    local ux, uy = faceOf(entity, px, py)
    if not ux then return nil end
    return ux, uy
end

--- Draw a page as a sign on WHICHEVER FACE OF A VEHICLE A POINT IS NEAREST TO.
---
--- ═══ THE REQUEST ═══
---
--- Owner, 2026-08-31, on the revive prompt: "I don't like the positioning of the
--- 'press E to revive' DUI... What I want is a DUI that shows on the nearest
--- face of the vehicle."
---
--- So: approach the ambulance from the driver's side and the plate is on the
--- driver's side; walk round the back and it moves to the back. drawFace above
--- is this with the answer fixed to the nose.
---
--- ═══ IT WAS drawFace's BASIS AND drawFace's QUAD, AND THAT WAS THE BUG ═══
---
--- It used to share `levelBasis` and `drawPlane` with the yard sign above, on
--- the reasoning that everything hard about a sign -- the reader's left, the
--- winding toward the camera, the meters -- had been solved once and should not
--- be reasoned about twice. Only one of those two functions was the right thing
--- to share. `drawPlane` and its tail still are, through drawQuad. `levelBasis`
--- was not: a yard sign is planted in front of a car and must stay level, while
--- THIS plate is bolted to a panel and must lie on it. Sharing the basis made
--- the plate level by construction, and two rounds of the owner reporting a
--- plate that does not follow the ambulance are what that cost (#294).
---
--- SO THE ORIENTATION COMES FROM THE ENTITY'S MATRIX NOW, through drawPanel,
--- whose header carries the whole argument and the proof that a vehicle standing
--- flat is unaffected. What is new here is still only which way is out and how
--- far; what changed is the frame those two are spent in.
---
--- ═══ THE FACE COMES OFF THE MODEL, SO AN UNSEEN VAN IS RIGHT ═══
---
--- BR.NearestBoxFace is handed GET_MODEL_DIMENSIONS' own box, so the sides of a
--- longer ambulance are further out and its tail is further back with nothing
--- here changing. A constant tuned against one model is the thing this avoids;
--- see that function's header, and BR.ShopSolve.signHeight, which the caller's
--- `oz` normally comes through for the same reason.
---
--- THE POINT IS THE CALLER'S, NOT THE CAMERA'S. "Whichever face the player is
--- standing closest to" is about where the player is standing, and a camera
--- swung round the van on the mouse must not move the plate to a face nobody is
--- at. This file has no opinion about whose position it is handed.
---
--- @param page table
--- @param entity integer  the vehicle the sign is bolted to
--- @param px number       the point the nearest face is nearest TO -- the
--- @param py number       player's own position, in the world
--- ═══ AND ALONG IT, WHICH IS THE SECOND DIRECTION THE FACE ALREADY CARRIES ═══
---
--- Owner, 2026-09-01: "I need to be able to move it left/right as well. in/out
--- and up/down are great but can't do left/right right now."
---
--- `out` spends the face's own OUTWARD normal; `side` spends the perpendicular
--- of that same normal. Both come out of BR.NearestBoxFace's answer, so neither
--- is a guess about which way the van is pointing and both follow the plate to
--- whichever panel the player walked round to. The perpendicular is taken in
--- drawPlane, beside the line that already decides the reader's left, so the
--- text and the offset cannot come to disagree -- see the note there.
---
--- @param out number      meters the sign stands off that face's panel, measured
---                        PERPENDICULAR TO THE PANEL. May be negative, and every
---                        face the owner has tuned is.
--- @param oz number       meters up the ENTITY from its origin. A height read off
---                        the model's own box (BR.ShopSolve.signHeight), so it
---                        belongs on the panel and travels with it.
--- @param widthM number   how wide the sign is, in metres; height follows the
---                        page's own aspect
--- @param side number|nil metres along that face, positive to the reader's right
--- @param alpha number|nil
--- @return number|nil ux, number uy  which face it drew on, in the vehicle's own
---                        axes, so a tuning readout can name it. nil when
---                        nothing was drawn.
function BR.Dui.drawNearFace(page, entity, px, py, out, oz, widthM, side, alpha)
    if not BR.Dui.ready(page) then return nil end
    if not entity or entity == 0 or not isTrue(DoesEntityExist(entity)) then
        return nil
    end

    local hw = ((tonumber(widthM) or 0.75) * 0.5) * prefs.ui
    if hw <= 0.0 then return nil end
    local hh = hw * (page.h / page.w)

    -- THE FACE, out of the one derivation BR.Dui.nearFace above shares -- see
    -- its header for why the caller may have asked the same question a moment
    -- ago and must get the same answer.
    --
    -- ALL THREE NUMBERS ARE IN THE MODEL'S OWN FRAME and are handed straight on
    -- in it. Nothing is converted to a world direction here any more: that
    -- conversion, and the level basis it went through, is what #294 removed.
    local ux, uy, reach = faceOf(entity, px, py)
    if not ux then return nil end

    -- THE PLATE IS BOLTED TO THAT PANEL. `reach` is where the model's own box
    -- puts the bodywork and `out` is the owner's meters off it -- negative on
    -- every face he has tuned (br_lib/config/revivekey.lua), because an
    -- ambulance's slab sides are inside their bounding box and a plate standing
    -- proud of them "read as floating beside it". A number tuned that finely is
    -- a number that has to be spent perpendicular to the panel it was measured
    -- against, at every attitude, which is exactly what drawPanel does and what
    -- the leveled path could not do at any lean.
    drawPanel(page, entity, ux, uy, reach + (tonumber(out) or 0.0),
              tonumber(side) or 0.0, oz, hw, hh, alpha)
    return ux, uy
end

--- Draw a page FLAT ON THE SCREEN, at a fixed spot, like a HUD element.
---
--- THE OTHER TWO DRAWS PIN A PAGE TO THE WORLD; THIS ONE DELIBERATELY DOES NOT,
--- and the reason it exists is #131. The owner asked for a real button GLYPH on
--- the smoke-trail prompt, and a glyph is the one thing GTA's help box cannot
--- give us for one of OUR keys: the engine draws `~INPUT_*~` glyphs from its own
--- control table, our rebinds live in the raw-key layer in keybinds.lua that the
--- engine never hears about, and `~INPUT_<hash>~` for a RegisterKeyMapping
--- command "renders a hole" -- measured on this build, not assumed (probe.lua,
--- and bus.lua's own note beside INPUT_PARACHUTE_DEPLOY). So the prompt has to
--- be drawn by something that can draw whatever we like, and we already own one:
--- this page, with its key-cap badge, is what every crate on the ground uses.
---
--- There is nothing in the world to attach a descent prompt to -- the player is
--- the subject -- so the position is screen space and constant, which is also
--- the cheapest thing this file can do: no projection, no distance, no matrix.
---
--- @param page table
--- @param x number      screen fraction, 0..1 (0.5 is centre)
--- @param y number      screen fraction, 0..1
--- @param scale number  width as a fraction of the screen
function BR.Dui.drawScreen(page, x, y, scale)
    if not BR.Dui.ready(page) then return end

    -- The player's interface size, exactly as in drawWorld. This is the
    -- descent prompt, which is screen furniture in the plainest sense -- if
    -- anything in this file has to honour "make my interface bigger", it is
    -- the box pinned to the middle of the screen.
    local w = (scale or 0.16) * prefs.ui
    -- The same aspect correction drawWorld needs, and for the same reason: a
    -- sprite's width is a fraction of the screen's WIDTH and its height a
    -- fraction of the screen's HEIGHT, which are different units. Leaving this
    -- out is what squashed the crate prompt to half its height on 16:9.
    local aspect = GetAspectRatio(false)
    if not aspect or aspect <= 0.1 then
        local sw, sh = GetActiveScreenResolution()
        aspect = (sh and sh > 0) and (sw / sh) or 1.7778
    end
    local h = w * (page.h / page.w) * aspect

    DrawSprite(page.txd, page.tex, x, y, w, h, 0.0, 255, 255, 255, 255)
end

--- Draw a page as a label STUCK TO AN ENTITY'S TOP FACE.
---
--- Not "flat in the world at some coordinates" -- the first version of this
--- was, and it showed: the label sat at the loot entry's REGISTERED position
--- while the crate had been shoved somewhere else, it used the crate's
--- GENERATION heading rather than the pose the physics had actually settled
--- into, and it ignored pitch and roll entirely, so a crate resting on a slope
--- wore a label lying dead flat beside it (user screenshots, 2026-08-06).
---
--- Every corner now comes from GET_OFFSET_FROM_ENTITY_IN_WORLD_COORDS, which
--- is the entity's own matrix. That single change buys the anchoring, the
--- yaw, the pitch and the roll together -- there is no orientation maths here
--- to get wrong, and a crate rolling down a hill wears its label the whole way
--- down.
---
--- @param page table
--- @param entity integer  the prop to label
--- @param size number|nil  label WIDTH in metres (height follows the page)
--- @param lift number|nil  metres above the top face, to beat z-fighting
--- @param alpha number|nil
function BR.Dui.drawOnEntity(page, entity, size, lift, alpha)
    if not BR.Dui.ready(page) then return end
    if not entity or entity == 0 or not DoesEntityExist(entity) then return end

    -- The lid, in the MODEL's own local space. Reading it off the model rather
    -- than hardcoding a height means the same call labels the sealed crate and
    -- the shorter open husk correctly, and would label a future container of
    -- any size.
    -- CACHED PER MODEL. GetModelDimensions is a model-table lookup, and this
    -- runs every frame the player is looking at a crate -- exactly the kind of
    -- per-frame engine call that shows up as hitching rather than as a
    -- steady cost. The answer is a constant for a given model.
    local dims = modelBox(GetEntityModel(entity))
    if not dims then return end
    local mn = { x = dims.minx, y = dims.miny, z = dims.minz }
    local mx = { x = dims.maxx, y = dims.maxy, z = dims.maxz }
    local ox, oy = (mn.x + mx.x) * 0.5, (mn.y + mx.y) * 0.5
    local oz = mx.z + (lift or 0.02)

    -- THE INTERFACE SIZE APPLIES HERE TOO -- AND ON THE SHIPPED NUMBERS THE
    -- CLAMP BELOW WILL EAT MOST OF IT. Said plainly, because a silent no-op is
    -- how this project keeps shipping wiring that goes nowhere.
    --
    -- This label is measured in METRES, not screen fractions: it is a decal on
    -- a box, and the fit clamp a few lines down exists to stop it overhanging
    -- the lid. Config already runs it up against that clamp on purpose --
    -- crateLabelSize was doubled to 1.1 and crateLabelFit opened to 0.48 so
    -- "the label may cover almost the whole lid" (br_lib/config/loot.lua). A
    -- crate label is therefore at or near its ceiling before this multiply
    -- touches it, and scaling up will mostly be clamped straight back.
    --
    -- IT STAYS ANYWAY, for two reasons. Scaling DOWN is unclamped, so a player
    -- who wants a smaller interface gets one here as well as everywhere else;
    -- and a smaller crateLabelSize, or a different prop with a bigger lid,
    -- makes the up direction real without needing this line remembered later.
    --
    -- WHAT ACTUALLY MOVES A CRATE LABEL FOR A PLAYER WHO CANNOT READ IT is the
    -- other half of the preference: textScale grows the words INSIDE the plate,
    -- in the page, where the lid's dimensions do not get a vote. That is the
    -- lever to point at if the owner reports crate labels not responding.
    local hw = (size or 0.55) * 0.5 * prefs.ui
    local hh = hw * (page.h / page.w)

    -- NEVER OVERHANG THE LID. A label wider than the box reads as floating
    -- next to it rather than printed on it -- which is most of what was wrong
    -- with the screenshots.
    local fit = (BR.Config.Loot.crateLabelFit or 0.45)
    local fitW, fitH = (mx.x - mn.x) * fit, (mx.y - mn.y) * fit
    local k = 1.0
    if hw > fitW then k = math.min(k, fitW / hw) end
    if hh > fitH then k = math.min(k, fitH / hh) end
    hw, hh = hw * k, hh * k

    local function corner(dx, dy)
        local v = GetOffsetFromEntityInWorldCoords(entity, ox + dx, oy + dy, oz)
        return v.x, v.y, v.z
    end

    local ax, ay, az = corner(-hw,  hh)   -- top-left
    local bx, by, bz = corner( hw,  hh)   -- top-right
    local cx, cy, cz = corner(-hw, -hh)   -- bottom-left
    local dx, dy, dz = corner( hw, -hh)   -- bottom-right

    -- WINDING PICKED FROM THE CAMERA, not guessed.
    --
    -- GTA's polys are single-sided. The first attempt hedged by drawing the
    -- quad both ways round, which is exactly why the label came out MIRRORED:
    -- both faces render, and the one pointing away wins the draw order. So
    -- work out which way the quad is facing and emit one winding -- the one
    -- whose normal points at the camera.
    local ux, uy, uz = bx - ax, by - ay, bz - az
    local vx, vy, vz = cx - ax, cy - ay, cz - az
    local nx = uy * vz - uz * vy
    local ny = uz * vx - ux * vz
    local nz = ux * vy - uy * vx

    local cam = GetGameplayCamCoord()
    local mx2, my2, mz2 = (ax + dx) * 0.5, (ay + dy) * 0.5, (az + dz) * 0.5
    local flip = (nx * (cam.x - mx2) + ny * (cam.y - my2) + nz * (cam.z - mz2)) < 0.0

    local a = alpha or 255
    local txd, tex = page.txd, page.tex

    if flip then
        -- Vertices AND their UVs swapped together, so this is the same image
        -- seen from the other side rather than a mirror of it.
        DrawSpritePoly(ax, ay, az, cx, cy, cz, bx, by, bz,
            255, 255, 255, a, txd, tex,
            0.0, 0.0, 1.0,  0.0, 1.0, 1.0,  1.0, 0.0, 1.0)
        DrawSpritePoly(cx, cy, cz, dx, dy, dz, bx, by, bz,
            255, 255, 255, a, txd, tex,
            0.0, 1.0, 1.0,  1.0, 1.0, 1.0,  1.0, 0.0, 1.0)
    else
        DrawSpritePoly(ax, ay, az, bx, by, bz, cx, cy, cz,
            255, 255, 255, a, txd, tex,
            0.0, 0.0, 1.0,  1.0, 0.0, 1.0,  0.0, 1.0, 1.0)
        DrawSpritePoly(cx, cy, cz, bx, by, bz, dx, dy, dz,
            255, 255, 255, a, txd, tex,
            0.0, 1.0, 1.0,  1.0, 0.0, 1.0,  1.0, 1.0, 1.0)
    end
end

--- Tear a page down. A DUI outlives the resource that made it otherwise.
--- @param name string
function BR.Dui.destroy(name)
    local p = pages[name]
    if not p then return end
    if p.dui then DestroyDui(p.dui) end
    pages[name] = nil
end

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for name in pairs(pages) do BR.Dui.destroy(name) end
end)

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------

--- THE SAME EVENT br_core ALREADY LISTENS TO FOR VOICE (client/voice.lua),
--- fired by br_ui's client/settings.lua on every push and every save. A
--- client-side TriggerEvent crosses resources, which is why this works at all
--- and why the preference does not have to be duplicated into br_core's own
--- storage: br_ui owns the value, this file owns what the DUIs do with it.
---
--- BOTH HALVES ARE HANDLED HERE, and they are handled differently on purpose.
--- The sprite half is just the table -- the next frame reads it. The prose half
--- is a message, so it has to be sent, and it is sent to EVERY page that is
--- already up rather than to the one that happens to be in front of the player.
--- Pages that are not up yet are not skipped so much as deferred: they read the
--- same table from BR.Dui.ready the first frame their browser answers.
AddEventHandler('br:settings:changed', function(s)
    if type(s) ~= 'table' then return end

    prefs.ui   = pref(s.uiScale, prefs.ui)
    prefs.text = pref(s.textScale, prefs.text)

    for _, p in pairs(pages) do
        if p.ready then pushScale(p) end
    end
end)

--- THE INTERFACE'S GREEN, AS THE HUD'S OWN CASCADE RESOLVED IT.
---
--- A DUI is a separate document with no access to index.css, so a page that
--- wants a palette colour has to be told one. br_ui/client/settings.lua explains
--- at length why the value travels from the page rather than being written down
--- a second time here; the short version is that `--color-hp` is remapped by the
--- colourblind modes, and a hex in this file would be the one green in the game
--- that ignored the setting.
---
--- HELD RATHER THAN PUSHED. Unlike the text scale, no page needs this the moment
--- it changes: it is read by the CALLER at the moment it builds a message
--- (BR.Shop's price line), so a page showing nothing has nothing to correct. One
--- fewer message on a path that runs while the player is walking.
---
--- NIL UNTIL br_ui HAS APPLIED ITS SETTINGS ONCE, which is a real state and not
--- an error -- a br_core restart mid-session lands here with nothing until the
--- next apply. Every reader must treat nil as "no colour", and the prompt page
--- falls back to its own default when the field is absent.
local hpColour = nil

--- ...AND THE CURRENCY'S ORANGE, BY THE SAME ROUTE AND FOR THE SAME REASON.
---
--- Owner, 2026-08-30: "the volts text should be orange - the same color we show
--- in the market page." That colour is `--color-royale-accent2`, which is what
--- ui-src/src/screens/Market.tsx paints both the balance plate and every price
--- button with -- so the shop plate's price and the Store screen's prices are
--- now one token rather than two decisions that happen to agree.
---
--- READ OUT OF THE DOCUMENT, NOT WRITTEN DOWN HERE, exactly as the green above
--- is. `--color-royale-accent2` is not one of the four tokens the colourblind
--- modes remap today, and that is not a reason to hardcode it: the whole point
--- of resolving through getComputedStyle is that index.css stays the only place
--- a colour is authored, so the day accent2 is retuned -- or the day a
--- colourblind mode starts remapping it -- nothing here goes stale in silence.
local voltsColour = nil

AddEventHandler('br:settings:palette', function(p)
    if type(p) ~= 'table' then return end
    if type(p.hp) == 'string' and p.hp ~= '' then hpColour = p.hp end
    if type(p.volts) == 'string' and p.volts ~= '' then voltsColour = p.volts end
end)

--- The interface's green, or nil if br_ui has not reported one yet.
--- @return string|nil
function BR.Dui.hp() return hpColour end

--- The interface's currency orange, or nil if br_ui has not reported one yet.
--- @return string|nil
function BR.Dui.volts() return voltsColour end

--- ASK, RATHER THAN WAIT (#131's lesson, in the small).
---
--- br_ui pushes settings on `br:ui:ready`, which is the NUI page coming up.
--- That covers a fresh join and a br_ui restart -- but NOT a br_core restart on
--- its own, where this file starts with a clean 1.00 and no push is ever coming
--- because nothing on br_ui's side has changed. A `restart br_core` mid-session
--- is a normal thing to do while developing, and "the prompts went back to
--- default size and stayed there" is exactly the kind of silent half-wiring
--- this project keeps shipping.
---
--- THE OTHER END EXISTS: br_ui/client/settings.lua answers this by calling
--- BR.Settings.push(), which is the same call `br:ui:ready` makes. If br_ui is
--- not running yet, nothing answers, and br_ui's own push on ready covers it a
--- moment later -- so both start orders are covered and neither needs a retry.
AddEventHandler('onClientResourceStart', function(res)
    if res ~= GetCurrentResourceName() then return end
    TriggerEvent('br:settings:request')
end)
