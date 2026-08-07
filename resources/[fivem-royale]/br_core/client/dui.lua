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
    page.ready = IsDuiAvailable(page.dui)
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
    local w = 0.09 * k

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

--- Draw a page FLAT IN THE WORLD, lying face-up like a label stuck on a lid.
---
--- The screen-facing version (drawWorld) is a sprite that always turns to the
--- camera, so walking around a crate spins its label -- which is right for a
--- floating prompt and wrong for something meant to read as printed ON the
--- crate (user, 2026-08-06). This one is a quad in world space: it has a fixed
--- heading, it does not turn, and the player sees it foreshortened exactly as
--- they would a real label.
---
--- DRAWN WITH BOTH WINDINGS. GTA's polys are single-sided and which winding
--- faces up depends on conventions this code cannot check without being in the
--- game -- so it draws the quad twice, once each way. Four triangles instead
--- of two is nothing next to being invisible from above.
---
--- @param page table
--- @param x number
--- @param y number
--- @param z number      world height of the label plane
--- @param size number   width in METRES (the height follows the page aspect)
--- @param heading number|nil  degrees; the label's fixed facing
--- @param alpha number|nil
function BR.Dui.drawFlat(page, x, y, z, size, heading, alpha)
    if not BR.Dui.ready(page) then return end

    local hw = (size or 0.9) * 0.5
    local hh = hw * (page.h / page.w)

    local rad = math.rad(heading or 0.0)
    local c, s = math.cos(rad), math.sin(rad)
    -- Local (dx, dy) -> world, rotated about the label's centre. dy is the
    -- label's "up" on the lid, which is a compass direction once it is flat.
    local function corner(dx, dy)
        return x + dx * c - dy * s, y + dx * s + dy * c, z
    end

    local ax, ay, az = corner(-hw,  hh)   -- top-left
    local bx, by, bz = corner( hw,  hh)   -- top-right
    local cx, cy, cz = corner(-hw, -hh)   -- bottom-left
    local dx, dy, dz = corner( hw, -hh)   -- bottom-right

    local a = alpha or 255
    local txd, tex = page.txd, page.tex

    -- Triangle 1: TL, TR, BL.  Triangle 2: BL, TR, BR.
    DrawSpritePoly(ax, ay, az, bx, by, bz, cx, cy, cz,
        255, 255, 255, a, txd, tex,
        0.0, 0.0, 1.0,  1.0, 0.0, 1.0,  0.0, 1.0, 1.0)
    DrawSpritePoly(cx, cy, cz, bx, by, bz, dx, dy, dz,
        255, 255, 255, a, txd, tex,
        0.0, 1.0, 1.0,  1.0, 0.0, 1.0,  1.0, 1.0, 1.0)

    -- ...and the same two with the winding reversed, so one pair faces up
    -- whichever convention this build uses.
    DrawSpritePoly(cx, cy, cz, bx, by, bz, ax, ay, az,
        255, 255, 255, a, txd, tex,
        0.0, 1.0, 1.0,  1.0, 0.0, 1.0,  0.0, 0.0, 1.0)
    DrawSpritePoly(dx, dy, dz, bx, by, bz, cx, cy, cz,
        255, 255, 255, a, txd, tex,
        1.0, 1.0, 1.0,  1.0, 0.0, 1.0,  0.0, 1.0, 1.0)
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
