-- The source-reading half of the weapon-icon gate, as pure functions.
--
-- WHY THIS IS NOT JUST INSIDE tools/check_weapons.lua. That gate can only ever
-- see the one real ui-src/src/hud/ItemIcon.tsx. Run against a clean tree it
-- proves the file is currently clean -- and it CANNOT prove it would notice a
-- dirty one. A gate that has quietly stopped detecting is strictly worse than
-- no gate at all, because it reports "ok" in the same green as a real pass.
--
-- So the rules live here, take a source string, and return problems. The gate
-- feeds them the real file; tools/test_icons.lua feeds them synthetic sources
-- that are deliberately broken, and asserts each one is caught. That second
-- half is the one that keeps the first half honest.
--
-- Loaded with dofile from the repo root by both callers.

local M = {}

-- THE ONLY DRAWN ICONS THERE MAY BE, and why none of them is a weapon:
--
--   shield  -- minishield/shield. A symbol, not an object; there is no
--              photograph of "shield" to take.
--   health  -- bandage/medkit. The same.
--   ammo    -- a pooled count. Nothing to photograph, and ItemIcon never even
--              requests a file for it.
--   missing -- the placeholder for a file that failed to decode. Deliberately
--              not weapon-shaped, so it reads as a fault rather than as an
--              unusual gun.
--
-- Anything else appearing in PATHS is a weapon being drawn again, which is the
-- thing the owner ruled out on 2026-08-22.
M.DRAWN_ALLOWED = {
    shield = true, health = true, ammo = true, missing = true,
}

--- The file with its comments stripped.
---
--- NOT OPTIONAL, and this is the single most load-bearing line in the file.
--- ItemIcon.tsx's own header describes the old bug IN THE PAST TENSE -- it
--- names WEAPON_CATEGORY, it quotes `?? 'rifle'`, and it lists the silhouettes
--- that were removed. A raw read finds the description of the problem and
--- reports the problem as present, so the gate goes red on a correct file and
--- the next person deletes the gate. check_key_glyphs.lua learned this first.
--- @param s string
--- @return string
function M.tsCode(s)
    s = s:gsub('/%*.-%*/', ' ')
    s = s:gsub('//[^\n]*', '')
    return s
end

--- The `key: 'value'` pairs of a top-level `const NAME ... = { ... }` block.
---
--- Returns nil -- distinct from an empty table -- when the block is not there
--- at all, because "declared and empty" and "not declared" are different
--- failures and the caller says so differently.
--- @param src string  already comment-stripped
--- @param name string
--- @return table|nil
function M.objectKeys(src, name)
    local body = src:match('const%s+' .. name .. '[^=]*=%s*{(.-)\n}')
    if not body then return nil end
    local keys = {}
    for k in body:gmatch("([%a][%w_]*)%s*:%s*'") do keys[k] = true end
    return keys
end

--- The `key: 'value'` pairs of a block, as pairs rather than as a key set.
--- @param src string  already comment-stripped
--- @param name string
--- @return table  list of { key, value }
function M.objectPairs(src, name)
    local body = src:match('const%s+' .. name .. '[^=]*=%s*{(.-)\n}') or ''
    local out = {}
    for k, v in body:gmatch("([%a][%w_]*)%s*:%s*'([%a][%w_]*)'") do
        out[#out + 1] = { k, v }
    end
    return out
end

--- Everything wrong with an ItemIcon.tsx, as a sorted list of messages.
---
--- Takes the RAW source and strips comments itself, so no caller can forget.
--- Sorted so the output is stable: `pairs` order is not, and a gate whose
--- message order changes between runs is one nobody trusts.
--- @param raw string
--- @return table  list of strings, empty when the file is clean
function M.problems(raw)
    local src = M.tsCode(raw)
    local out = {}
    local function add(fmt, ...) out[#out + 1] = fmt:format(...) end

    -- The map that used to choose a silhouette. Its ABSENCE is the check:
    -- while it exists, an id can fall through it to a default and draw a
    -- different gun -- and that is a table lookup, so no type error catches it.
    if src:match('const%s+WEAPON_CATEGORY') then
        add('declares WEAPON_CATEGORY again. That map existed only to pick a '
            .. 'drawn weapon silhouette, and its `?? \'rifle\'` default is what '
            .. 'drew an assault rifle for a railgun. Weapons are PNGs now: add '
            .. 'the file, not a shape.')
    end

    local paths = M.objectKeys(src, 'PATHS')
    if not paths then
        add('no longer declares PATHS, so the consumables, ammo and the '
            .. 'missing-artwork placeholder have no shapes at all')
        table.sort(out)
        return out
    end

    for k in pairs(paths) do
        if not M.DRAWN_ALLOWED[k] then
            add('draws a %q icon. The drawn set is the consumables, ammo and '
                .. 'the missing-artwork placeholder -- a new shape here is how '
                .. 'a weapon gets drawn again, which is the thing the owner '
                .. 'ruled out.', k)
        end
    end

    for k in pairs(M.DRAWN_ALLOWED) do
        if not paths[k] then
            add('has no %q entry in PATHS -- it would render <path d=undefined>, '
                .. 'which is a blank slot with no error anywhere', k)
        end
    end

    -- And every consumable names a shape that exists. The same blank slot,
    -- reached by a different road.
    for _, kv in ipairs(M.objectPairs(src, 'CONSUMABLE_ICON')) do
        if not paths[kv[2]] then
            add('CONSUMABLE_ICON.%s names %q, which has no entry in PATHS -- '
                .. 'the slot would draw nothing', kv[1], kv[2])
        end
    end

    table.sort(out)
    return out
end

return M
