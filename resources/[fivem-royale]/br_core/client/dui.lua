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
    local mn, mx = GetModelDimensions(GetEntityModel(entity))
    if not mn or not mx then return end
    local ox, oy = (mn.x + mx.x) * 0.5, (mn.y + mx.y) * 0.5
    local oz = mx.z + (lift or 0.02)

    local hw = (size or 0.55) * 0.5
    local hh = hw * (page.h / page.w)

    -- NEVER OVERHANG THE LID. A label wider than the box reads as floating
    -- next to it rather than printed on it -- which is most of what was wrong
    -- with the screenshots.
    local fitW, fitH = (mx.x - mn.x) * 0.45, (mx.y - mn.y) * 0.45
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
