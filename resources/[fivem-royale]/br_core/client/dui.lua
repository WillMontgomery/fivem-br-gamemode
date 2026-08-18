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

--- Model bounding boxes, cached by model hash. A model's dimensions never
--- change, and drawOnEntity would otherwise ask the engine for them on every
--- frame the player is looking at a crate.
local DIMS = {}

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
    local model = GetEntityModel(entity)
    local dims = DIMS[model]
    if not dims then
        local a, b = GetModelDimensions(model)
        if not a or not b then return end
        dims = { minx = a.x, miny = a.y, minz = a.z,
                 maxx = b.x, maxy = b.y, maxz = b.z }
        DIMS[model] = dims
    end
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
