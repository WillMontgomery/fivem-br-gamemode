-- Unit tests for the weapon-icon rules.
--
--   lua tools/test_icons.lua      (or via tools/verify.sh)
--
-- WHAT THIS SUITE IS GUARDING. Owner, 2026-08-22: "We need to not draw any
-- weapons as SVGs and only use pngs." tools/check_weapons.lua enforces that in
-- two halves -- every slot weapon has a PNG, and ItemIcon.tsx draws nothing
-- weapon-shaped -- but that gate only ever reads the ONE REAL ItemIcon.tsx. On
-- a clean tree it proves the file is clean; it cannot prove it would notice a
-- dirty one, and a detector that has silently stopped detecting reports "ok" in
-- exactly the same green as a real pass.
--
-- So the rules were split into tools/icon_rules.lua as pure functions over a
-- source string, and this suite feeds them sources that are DELIBERATELY WRONG
-- and asserts each one is caught. Roughly half the cases below are that.
--
-- THE COMMENT-STRIPPING CASES ARE THE POINT OF THE OTHER HALF. ItemIcon.tsx's
-- header describes the old bug in the past tense: it names WEAPON_CATEGORY, it
-- quotes `?? 'rifle'`, and it lists the silhouettes that were deleted. A rule
-- that reads the raw file finds that essay and reports the bug as present --
-- red on a correct file, which is how a gate gets deleted by the next person
-- through. check_key_glyphs.lua learned this first and check_weapons.lua
-- inherited the lesson; these cases are what keeps it inherited.

local ROOT = 'resources/[fivem-royale]/br_lib/'
local Icons = dofile('tools/icon_rules.lua')

-- ---------------------------------------------------------------- harness ---

local pass, fail = 0, 0
local group = ''

local function describe(name) group = name end

local function ok(cond, name, detail)
    if cond then
        pass = pass + 1
    else
        fail = fail + 1
        io.write('\27[31mFAIL\27[0m ', group, ' > ', name)
        if detail then io.write('\n       ', tostring(detail)) end
        io.write('\n')
    end
end

--- Does any problem message contain this substring?
local function flags(problems, needle)
    for _, m in ipairs(problems) do
        if m:find(needle, 1, true) then return true end
    end
    return false
end

--- A minimal ItemIcon.tsx-shaped source, with the pieces the rules read.
---
--- Built rather than kept as a fixture file so each case can state exactly the
--- ONE thing it changes -- a fixture directory of near-identical .tsx files is
--- how the difference between two cases stops being visible.
--- @param o table|nil
local function source(o)
    o = o or {}
    local paths = o.paths or { 'shield', 'health', 'ammo', 'missing' }
    local cons  = o.consumables or { { 'shield', 'shield' }, { 'medkit', 'health' } }

    local out = { "import { useState } from 'react'", '' }

    local cl = {}
    for _, kv in ipairs(cons) do
        cl[#cl + 1] = ("  %s: '%s',"):format(kv[1], kv[2])
    end
    out[#out + 1] = 'const CONSUMABLE_ICON: Record<string, DrawnIcon> = {'
    out[#out + 1] = table.concat(cl, '\n')
    out[#out + 1] = '}'
    out[#out + 1] = ''

    if not o.noPaths then
        local pl = {}
        for _, k in ipairs(paths) do
            pl[#pl + 1] = ("  %s: 'M0 0h1v1H0z',"):format(k)
        end
        out[#out + 1] = 'const PATHS: Record<DrawnIcon, string> = {'
        out[#out + 1] = table.concat(pl, '\n')
        out[#out + 1] = '}'
        out[#out + 1] = ''
    end

    out[#out + 1] = o.extra or ''
    return table.concat(out, '\n')
end

-- ------------------------------------------------------- comment stripping --

describe('tsCode')

do
    ok(not Icons.tsCode('a /* b */ c'):find('b', 1, true),
        'strips a block comment')

    ok(not Icons.tsCode('a // b\nc'):find('b', 1, true),
        'strips a line comment')

    ok(Icons.tsCode('a // b\nc'):find('c', 1, true) ~= nil,
        'and keeps the code on the NEXT line -- a line comment ends at the '
        .. 'newline, and eating it would swallow the file')

    ok(Icons.tsCode('x /* one */ y /* two */ z'):find('y', 1, true) ~= nil,
        'strips two block comments without eating what is between them '
        .. '(a greedy .* here would take the lot)')

    -- The declaration is what matters, not the mention. These two cases are
    -- the whole reason tsCode exists.
    local inBlock = source({
        extra = '/**\n'
             .. ' * This file used to declare `const WEAPON_CATEGORY: Record<string,\n'
             .. ' * Category>` and choose with `WEAPON_CATEGORY[slot.id] ?? \'rifle\'`,\n'
             .. ' * which is why a railgun drew an assault rifle.\n'
             .. ' */',
    })
    ok(#Icons.problems(inBlock) == 0,
        'a `const WEAPON_CATEGORY` named only inside a BLOCK comment is not a '
        .. 'declaration and must not be flagged',
        table.concat(Icons.problems(inBlock), ' | '))

    local inLine = source({ extra = '// const WEAPON_CATEGORY = { rpg: \'launcher\' }' })
    ok(#Icons.problems(inLine) == 0,
        'nor one in a LINE comment',
        table.concat(Icons.problems(inLine), ' | '))
end

-- ------------------------------------------------------------- objectKeys ---

describe('objectKeys')

do
    local src = Icons.tsCode(source())
    local paths = Icons.objectKeys(src, 'PATHS')

    ok(paths ~= nil, 'finds a declared block')
    ok(paths and paths.shield and paths.missing, 'and every key in it')

    ok(Icons.objectKeys(src, 'NOPE') == nil,
        'returns nil -- not an empty table -- for a block that is not there, '
        .. 'so "declared and empty" stays distinguishable from "not declared"')

    -- The block terminator is `\n}`. If the pattern were greedy it would run
    -- to the LAST one in the file and hoover up every following const.
    ok(paths and not paths.minishield,
        'does not bleed past its own closing brace into the next const')
end

-- --------------------------------------------------- what must be rejected --

describe('problems')

do
    ok(#Icons.problems(source()) == 0,
        'a clean source has no problems',
        table.concat(Icons.problems(source()), ' | '))
end

do
    -- The map itself. While it exists an id can fall through it to a default,
    -- and that is a table lookup -- no type error catches it.
    local p = Icons.problems(source({
        extra = 'const WEAPON_CATEGORY: Record<string, Category> = {\n'
             .. "  railgun: 'railgun',\n}",
    }))
    ok(flags(p, 'WEAPON_CATEGORY'),
        'a re-declared WEAPON_CATEGORY is caught -- this is the exact shape of '
        .. 'the bug that drew an assault rifle for a railgun')
end

do
    local p = Icons.problems(source({
        paths = { 'shield', 'health', 'ammo', 'missing', 'rifle' },
    }))
    ok(flags(p, 'rifle'),
        'a weapon shape added to PATHS is caught by name')
    ok(#p == 1, 'and nothing else is', table.concat(p, ' | '))
end

do
    for _, weaponish in ipairs({ 'pistol', 'smg', 'shotgun', 'sniper', 'lmg',
                                 'launcher', 'minigun', 'railgun', 'melee',
                                 'throwable' }) do
        local p = Icons.problems(source({
            paths = { 'shield', 'health', 'ammo', 'missing', weaponish },
        }))
        ok(flags(p, weaponish),
            ('a `%s` shape is rejected'):format(weaponish))
    end
end

do
    -- Every removed shape is a <path d=undefined>, i.e. a blank slot with no
    -- error anywhere -- the failure mode the placeholder exists to avoid.
    for _, missingKey in ipairs({ 'shield', 'health', 'ammo', 'missing' }) do
        local keep = {}
        for _, k in ipairs({ 'shield', 'health', 'ammo', 'missing' }) do
            if k ~= missingKey then keep[#keep + 1] = k end
        end
        local p = Icons.problems(source({ paths = keep }))
        ok(flags(p, missingKey),
            ('dropping the `%s` shape is caught'):format(missingKey))
    end
end

do
    local p = Icons.problems(source({ noPaths = true }))
    ok(flags(p, 'PATHS'), 'deleting PATHS entirely is caught')
    ok(#p == 1,
        'and reported once, as the one root cause rather than as four missing '
        .. 'shapes -- a gate that prints five lines for one deletion teaches '
        .. 'nobody which one to fix',
        table.concat(p, ' | '))
end

do
    local p = Icons.problems(source({
        consumables = { { 'shield', 'shield' }, { 'medkit', 'bandaid' } },
    }))
    ok(flags(p, 'CONSUMABLE_ICON.medkit'),
        'a consumable naming a shape that does not exist is caught')
end

do
    -- Stable output. `pairs` order over a hash part is not defined, and a gate
    -- whose message order moves between runs is one nobody trusts enough to
    -- read -- every diff of two runs looks like a change.
    --
    -- ASSERTED AGAINST THE SORT, NOT AGAINST REPETITION. Running the same input
    -- twice in ONE process gives the same `pairs` order both times, so a
    -- "twenty-five runs agree" test passes happily with the sort deleted -- it
    -- did, and this is what replaced it.
    --
    -- The discriminating case: `CONSUMABLE_ICON.medkit ...` is added LAST and
    -- sorts FIRST, because uppercase C is 0x43 and the other messages start
    -- with lowercase. Insertion order and sorted order genuinely disagree here,
    -- so only a real sort puts it at the front.
    local p = Icons.problems(source({
        paths = { 'shield', 'health', 'ammo', 'missing', 'rifle' },
        consumables = { { 'medkit', 'bandaid' } },
    }))
    ok(#p == 2, 'the discriminating case really does produce two problems',
        table.concat(p, ' | '))
    ok(p[1] and p[1]:sub(1, 15) == 'CONSUMABLE_ICON',
        'the problem list is SORTED -- the message added last sorts first, and '
        .. 'comes back first',
        table.concat(p, ' | '))

    local sorted = true
    for i = 2, #p do
        if p[i - 1] > p[i] then sorted = false end
    end
    ok(sorted, 'and the list is non-decreasing throughout')
end

-- ------------------------------------------------------------ the real tree --

describe('the shipped ItemIcon.tsx')

local UI_ICON = 'ui-src/src/hud/ItemIcon.tsx'

do
    local fh = io.open(UI_ICON, 'r')
    ok(fh ~= nil, 'exists')
    if fh then
        local raw = fh:read('a')
        fh:close()
        local p = Icons.problems(raw)
        ok(#p == 0, 'has no problems', table.concat(p, ' | '))

        -- Belt and braces on the one rule that is the owner's actual words.
        -- If `problems` ever stops looking, this still fails.
        ok(not Icons.tsCode(raw):match('const%s+WEAPON_CATEGORY'),
            'declares no WEAPON_CATEGORY outside a comment')

        -- THE ONE LINE THAT TURNS AN ITEM ID INTO A FILE REQUEST, pinned by its
        -- exact text. Everything else in this suite is about what must NOT be
        -- drawn; if `iconUrl` stopped building this path, nothing would be
        -- drawn either -- every slot in the game would show the "picture
        -- missing" placeholder, with all 56 PNGs present and correct on disk
        -- and every other assertion here still green.
        --
        -- Searching the raw file for `items/` is NOT enough and was the first
        -- version of this: the header comment says "items/<id>.png" twice and
        -- FistIcon hardcodes "items/fists.png", so the substring survives the
        -- deletion of the very expression it is meant to guard.
        ok(Icons.tsCode(raw):find('items/${slot.id}.png', 1, true) ~= nil,
            'iconUrl still builds `items/${slot.id}.png` -- in code, not in a '
            .. 'comment')
    end
end

-- ------------------------------------------------------------------- art ----

describe('artwork on disk')

for _, f in ipairs({ 'shared/enums.lua', 'shared/geo.lua', 'config/weapons.lua' }) do
    local chunk, err = loadfile(ROOT .. f)
    if not chunk then
        io.write('\27[31mload error\27[0m ', f, ': ', tostring(err), '\n')
        os.exit(1)
    end
    chunk()
end

local SRC_ITEMS   = 'ui-src/public/items/'
local BUILT_ITEMS = 'resources/[fivem-royale]/br_ui/ui/items/'

--- The first eight bytes of a PNG, which nothing else has.
---
--- WORTH CHECKING RATHER THAN TRUSTING THE EXTENSION. These files arrive by
--- `curl` from a raw.githubusercontent URL, and the two ways that goes wrong --
--- a 404 body and an HTML redirect page -- both land as a file with a .png name
--- and a plausible size. Existence is not the same claim as decodability.
local PNG_MAGIC = '\137PNG\13\10\26\10'

local function pngHeader(path)
    local fh = io.open(path, 'rb')
    if not fh then return nil end
    local head = fh:read(8)
    local size = fh:seek('end')
    fh:close()
    return head, size
end

do
    local seen = 0
    for _, spec in ipairs({
        { BR.Config.Weapons,        'weapon' },
        { BR.Config.AirdropWeapons, 'airdrop weapon' },
        { BR.Config.Melee,          'melee weapon' },
        { BR.Config.Throwables,     'throwable' },
        { { BR.Config.Fists },      'fists' },
    }) do
        for _, w in ipairs(spec[1] or {}) do
            local id = tostring(w.id)
            seen = seen + 1
            for _, dir in ipairs({ SRC_ITEMS, BUILT_ITEMS }) do
                local head, size = pngHeader(dir .. id .. '.png')
                ok(head ~= nil,
                    ('%s %q has %s%s.png'):format(spec[2], id, dir, id))
                if head then
                    ok(head == PNG_MAGIC,
                        ('%s %q: %s%s.png is really a PNG'):format(spec[2], id, dir, id),
                        'first bytes were ' .. string.format('%q', head))
                    ok(size and size > 0,
                        ('%s %q: %s%s.png is not empty'):format(spec[2], id, dir, id))
                end
            end
        end
    end

    ok(seen == 56,
        'all 56 slot weapons were checked -- 36 firearms, 4 airdrop, 11 melee, '
        .. '4 throwables and fists',
        'saw ' .. tostring(seen))
end

describe('the airdrop shelf specifically')

do
    -- Named one at a time rather than swept, because these four are the whole
    -- reason for the change and "the loop ran" is not the same as "these four
    -- are there". Owner, 2026-08-22: "railgun and grenade launcher do not have
    -- images."
    for _, id in ipairs({ 'rpg', 'grenadelauncher', 'railgun', 'minigun' }) do
        local head = pngHeader(SRC_ITEMS .. id .. '.png')
        ok(head == PNG_MAGIC, ('%s.png is a PNG in the source tree'):format(id))
        local built = pngHeader(BUILT_ITEMS .. id .. '.png')
        ok(built == PNG_MAGIC, ('%s.png is a PNG in the built bundle'):format(id))
    end
end

describe('no weapon id is a drawn icon')

do
    -- The inverse of the PATHS allowlist, checked against the real tables
    -- rather than against a list typed here: if a weapon id ever became a
    -- drawn-icon name, that is the old failure wearing a new hat.
    local clash = {}
    for _, list in ipairs({ BR.Config.Weapons, BR.Config.AirdropWeapons,
                            BR.Config.Melee, BR.Config.Throwables }) do
        for _, w in ipairs(list or {}) do
            if Icons.DRAWN_ALLOWED[tostring(w.id)] then
                clash[#clash + 1] = tostring(w.id)
            end
        end
    end
    ok(#clash == 0,
        'no weapon id collides with a drawn-icon name',
        table.concat(clash, ', '))

    ok(Icons.DRAWN_ALLOWED.rifle == nil and Icons.DRAWN_ALLOWED.pistol == nil,
        'and the allowlist itself names no weapon')
end

-- ----------------------------------------------------------------- result ---

io.write(('\n%s%d passed%s'):format('\27[32m', pass, '\27[0m'))
if fail > 0 then
    io.write(('  %s%d failed%s\n'):format('\27[31m', fail, '\27[0m'))
    os.exit(1)
end
io.write('\n')
