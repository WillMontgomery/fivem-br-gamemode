-- One rarity palette, pinned everywhere it is written down (#392).
--
--   "The table you wrote is the one I want kept."     -- owner, 2026-10-04
--
-- ═══ WHAT DRIFTED ═══
--
-- BR.RarityInfo (br_lib/shared/enums.lua) and ui-src's RARITY agreed on five
-- colors, and the bag, the inventory panel, the gun-shop menu and the world
-- were painted with them. ui-src/src/index.css's --rarity-1..5 held Tailwind's
-- defaults instead, and the Market and the Settings preview read those -- so
-- the page showed two palettes, and the colorblind modes (which override only
-- the CSS variables) never reached the bag at all. A comment above the
-- variables said they were "mirrored in bridge/types.ts RARITY". They were not,
-- and nothing compared them.
--
-- ═══ WHAT THIS PINS ═══
--
-- The fix is ONE value per rarity on each side of the language boundary: Lua's
-- BR.RarityInfo for the world and the menus, index.css's base :root block for
-- the page, and nothing on the page holding a hex of its own. A stylesheet and
-- a Lua table cannot share a constant, so this suite is the bridge:
--
--   1. BR.RarityInfo carries the owner's five, and its rgb says the same thing
--      as its hex.
--   2. index.css's base :root block carries the same five, and every other
--      block that declares a rarity is a colorblind mode -- so a second,
--      unconditional palette cannot appear beside it.
--   3. RARITY in bridge/types.ts carries no color at all (that hex is what kept
--      the bag out of every colorblind mode), and its keys and labels are
--      BR.RarityInfo's.
--   4. tailwind.config.ts points its rarity colors at the variables rather than
--      holding a copy -- it held Tailwind's defaults too.
--   5. The BUILT stylesheet says what the source says. br_ui/ui is committed
--      build output that deploy ships verbatim, so a source edit with no
--      `npm run build` changes nothing a player sees and looks right in every
--      diff -- the argument verify.sh's voice-defaults gate makes for its own
--      bundle check.
--
-- Read as text, because text is the only thing the three languages share.
--
-- Run:  lua tools/test_rarity.lua        (or via tools/verify.sh)

local pass, fail = 0, 0
local group = ''
local function describe(n) group = n end
local function ok(cond, name, detail)
    if cond then
        pass = pass + 1
    else
        fail = fail + 1
        print('\27[31mFAIL\27[0m ' .. group .. ' > ' .. name ..
            (detail and ('\n       ' .. tostring(detail)) or ''))
    end
end

local function slurp(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local t = f:read('a'); f:close(); return t
end

-- THE OWNER'S TABLE, written out once and on purpose. Comparing the files only
-- with each other would pass if all of them moved together; this is the answer
-- he gave on #392, so it is the thing they are all compared against.
local CANON = {
    { key = 'common',    label = 'Common',    hex = '#B0B0B0' },
    { key = 'uncommon',  label = 'Uncommon',  hex = '#4CD964' },
    { key = 'rare',      label = 'Rare',      hex = '#3B9BFF' },
    { key = 'epic',      label = 'Epic',      hex = '#B15BFF' },
    { key = 'legendary', label = 'Legendary', hex = '#FFB020' },
}

local ENUMS    = 'resources/[fivem-royale]/br_lib/shared/enums.lua'
local CSS      = 'ui-src/src/index.css'
local TYPES    = 'ui-src/src/bridge/types.ts'
local TAILWIND = 'ui-src/tailwind.config.ts'
local BUNDLE   = 'resources/[fivem-royale]/br_ui/ui/assets/index.css'

--- Every rule in a stylesheet that declares a --rarity-N, as
--- { selector = normalized, decls = { [n] = value } }. Comments are dropped
--- first, so a hex quoted in prose is never read as a declaration. Nested
--- blocks (@media, @supports) are walked, and their selector carries the
--- at-rule as a prefix, so a palette hidden inside one cannot pass for :root.
local function rarityRules(css)
    css = css:gsub('/%*.-%*/', '')
    local out = {}
    local function walk(text, prefix)
        for head, body in text:gmatch('([^{}]*)(%b{})') do
            -- The text before a block can carry finished statements
            -- (`@tailwind base;`); the selector is what follows the last one.
            local sel = head:match('([^;]*)$')
            -- NORMALIZED so source and minified bundle compare equal:
            -- `:root[data-cb="deuter"], :root[data-cb="protan"]` and
            -- `:root[data-cb=deuter],:root[data-cb=protan]` are one selector.
            sel = (prefix .. sel):gsub('%s+', ''):gsub('["\']', '')
            local inner = body:sub(2, -2)
            if inner:find('{', 1, true) then
                walk(inner, sel .. ' ')
            else
                local decls, any = {}, false
                for n, v in inner:gmatch('%-%-rarity%-(%d+)%s*:%s*([^;]+)') do
                    n = tonumber(n)
                    v = v:gsub('%s+$', '')
                    if decls[n] ~= nil then
                        decls.dup = (decls.dup or '') .. ' --rarity-' .. n
                    end
                    decls[n], any = v, true
                end
                if any then out[#out + 1] = { selector = sel, decls = decls } end
            end
        end
    end
    walk(css, '')
    return out
end

--- The one block a stylesheet's base palette lives in, and every complaint
--- about the rest.
local function basePalette(rules, where)
    local base, problems = nil, {}
    for _, r in ipairs(rules) do
        if r.selector == ':root' then
            if base then
                problems[#problems + 1] = where .. ' declares rarities in a second :root block'
            end
            base = base or r
        else
            -- ONLY A COLORBLIND MODE MAY OVERRIDE. Every comma-separated part
            -- must be :root[data-cb=<mode>]; anything else is a second palette.
            for part in (r.selector .. ','):gmatch('([^,]*),') do
                if not part:match('^:root%[data%-cb=[a-z]+%]$') then
                    problems[#problems + 1] = ('%s declares rarities under `%s`, which is not a '
                        .. 'colorblind mode'):format(where, r.selector)
                    break
                end
            end
        end
        if r.decls.dup then
            problems[#problems + 1] = ('%s declares%s twice in `%s`'):format(where, r.decls.dup, r.selector)
        end
    end
    return base, problems
end

-- --------------------------------------------------------------------- Lua ---

describe('BR.RarityInfo')
BR = nil
dofile(ENUMS)
ok(type(BR) == 'table' and type(BR.RarityInfo) == 'table', 'enums.lua defines BR.RarityInfo')
local info = (BR and BR.RarityInfo) or {}
local count = 0
for _ in pairs(info) do count = count + 1 end
ok(count == #CANON, 'it has exactly five rarities', count)
for i, want in ipairs(CANON) do
    local got = info[i] or {}
    ok(got.hex == want.hex, ('%s is %s'):format(want.label, want.hex), tostring(got.hex))
    ok(got.key == want.key and got.label == want.label,
       ('rarity %d is keyed %s and labeled %s'):format(i, want.key, want.label),
       tostring(got.key) .. ' / ' .. tostring(got.label))
    -- THE WORLD AND THE MENUS PAINT `rgb`, the page paints the hex. Two
    -- spellings of one color in one row is the same drift in miniature.
    local r, g, b = want.hex:match('#(%x%x)(%x%x)(%x%x)')
    local rgb = got.rgb or {}
    ok(rgb[1] == tonumber(r, 16) and rgb[2] == tonumber(g, 16) and rgb[3] == tonumber(b, 16),
       ('%s rgb is %s, the same color as its hex'):format(want.label, want.hex),
       ('{ %s, %s, %s }'):format(tostring(rgb[1]), tostring(rgb[2]), tostring(rgb[3])))
end

-- -------------------------------------------------------------- index.css ---

local function checkSheet(path, label)
    local css = slurp(path)
    ok(css ~= nil, label .. ' is readable', path)
    if not css then return end
    local rules = rarityRules(css)
    local base, problems = basePalette(rules, label)
    ok(base ~= nil, label .. ' declares the rarities in a plain :root block')
    ok(#problems == 0, label .. ' has one base palette, and only colorblind modes override it',
       table.concat(problems, '\n       '))
    if base then
        for i, want in ipairs(CANON) do
            local got = base.decls[i]
            ok(got ~= nil and got:upper() == want.hex,
               ('%s --rarity-%d is %s (%s)'):format(label, i, want.hex, want.label),
               tostring(got))
        end
    end
    -- CHROME 103 PARSES A HEX. A mode written as color-mix() or a var() of a
    -- var() would be dropped by CEF and paint nothing (docs/platform.md), and
    -- check-css only reads the bundle when somebody builds it.
    local bad = {}
    for _, r in ipairs(rules) do
        for n, v in pairs(r.decls) do
            if type(n) == 'number' and not v:match('^#%x%x%x%x%x%x$') then
                bad[#bad + 1] = ('%s --rarity-%d: %s'):format(r.selector, n, v)
            end
        end
    end
    ok(#bad == 0, label .. ' writes every rarity as a six-digit hex', table.concat(bad, '\n       '))
    return rules
end

describe('index.css')
local srcRules = checkSheet(CSS, 'index.css') or {}

-- ---------------------------------------------------------------- types.ts ---

describe('bridge/types.ts')
do
    local ts = slurp(TYPES) or ''
    local block = ts:match('export const RARITY[^\n]*\n(.-)\n}')
    ok(block ~= nil, 'RARITY is still where this suite looks for it', TYPES)
    block = block or ''
    ok(not block:find('#%x%x%x'), 'RARITY holds no hex', block)
    ok(not ts:match('export const RARITY[^=]*hex'), 'and its type has no hex field')
    local rows = '\n' .. block
    for i, want in ipairs(CANON) do
        local key, label = rows:match('\n%s*' .. i .. ':%s*{%s*key:%s*\'([%w_]+)\',%s*label:%s*\'([^\']+)\'')
        ok(key == want.key and label == want.label,
           ('rarity %d is keyed %s and labeled %s, as in BR.RarityInfo'):format(i, want.key, want.label),
           tostring(key) .. ' / ' .. tostring(label))
    end
end

-- -------------------------------------------------------- tailwind.config ---

describe('tailwind.config.ts')
do
    local tw = (slurp(TAILWIND) or ''):gsub('//[^\n]*', '')
    local block = tw:match('rarity:%s*(%b{})')
    ok(block ~= nil, 'the rarity colors are still where this suite looks for them', TAILWIND)
    block = block or ''
    ok(not block:find('#%x%x%x'), 'they hold no hex', block)
    for i = 1, #CANON do
        ok(block:find(i .. ":%s*'var%(%-%-rarity%-" .. i .. "%)'") ~= nil,
           ('%d points at var(--rarity-%d)'):format(i, i))
    end
end

-- ------------------------------------------------------------- the bundle ---

describe('built bundle')
do
    local builtRules = checkSheet(BUNDLE, 'the built index.css') or {}
    -- EVERY RARITY DECLARATION, MODES INCLUDED. The base palette is checked
    -- against the owner's table above; this checks the colorblind overrides
    -- reached the bundle too, by comparing the two sheets rule for rule.
    local function flatten(rules)
        local t = {}
        for _, r in ipairs(rules) do
            for n, v in pairs(r.decls) do
                if type(n) == 'number' then
                    t[#t + 1] = ('%s --rarity-%d: %s'):format(r.selector, n, v:lower())
                end
            end
        end
        table.sort(t)
        return table.concat(t, '\n       ')
    end
    local want, got = flatten(srcRules), flatten(builtRules)
    ok(want == got, 'it ships the same rarity declarations as the source -- if not, run '
        .. '`npm run build` in ui-src', 'source:\n       ' .. want .. '\n       built:\n       ' .. got)
end

-- --------------------------------------------------------------- the gate ---

-- A PARSER THAT FINDS NOTHING PASSES EVERYTHING. These are the shapes it has
-- to catch, fed to it directly.
describe('the parser itself')
do
    local base, problems = basePalette(rarityRules([[
        /* --rarity-1: #000000; a comment is not a declaration */
        :root { --x: 1; --rarity-1: #B0B0B0; --rarity-2: #4CD964; }
        :root[data-cb="tritan"] { --rarity-3: #4A88F5; }
    ]]), 'fixture')
    ok(base and base.decls[1] == '#B0B0B0' and base.decls[2] == '#4CD964',
       'it reads the base block, and skips a value quoted in a comment')
    ok(#problems == 0, 'a colorblind override is allowed', table.concat(problems, '; '))

    local _, p2 = basePalette(rarityRules([[
        :root { --rarity-1: #B0B0B0; }
        .market { --rarity-1: #9ca3af; }
    ]]), 'fixture')
    ok(#p2 == 1, 'a second palette under any other selector is refused', #p2)

    local _, p3 = basePalette(rarityRules([[
        :root { --rarity-1: #B0B0B0; }
        @media (min-width: 1px) { :root { --rarity-1: #9ca3af; } }
    ]]), 'fixture')
    ok(#p3 == 1, 'and so is one hidden inside an at-rule', #p3)

    local _, p4 = basePalette(rarityRules([[
        :root { --rarity-1: #B0B0B0; }
        :root { --rarity-2: #22c55e; }
    ]]), 'fixture')
    ok(#p4 == 1, 'and so is a second :root block', #p4)

    local _, p5 = basePalette(rarityRules([[
        :root { --rarity-1: #B0B0B0; --rarity-1: #9ca3af; }
    ]]), 'fixture')
    ok(#p5 == 1, 'and so is a rarity declared twice in one block', #p5)
end

-- ---------------------------------------------------------------- result ---

print(('\n\27[32m%d passed\27[0m'):format(pass))
if fail > 0 then
    print(('\27[31m%d failed\27[0m'):format(fail))
    os.exit(1)
end
