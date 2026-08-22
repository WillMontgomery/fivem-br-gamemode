-- Drive-by data gate (#197).
--
-- br_environment/data/vehiclelayouts.meta is the first GAME data file this
-- project ships, and it is the one file here that no Lua test can execute: the
-- game parses it, not us. What a test CAN do is prove the two claims the file
-- makes about itself, and both of them are claims that go quietly wrong.
--
--   1. IT LISTS EVERY FIREARM THIS GAMEMODE ISSUES. The list REPLACES the base
--      game's, it does not extend it, so a weapon left off does not keep its
--      old behaviour -- it LOSES drive-by. Add a gun to br_lib/config/weapons.lua
--      and forget this file and that gun is the one that mysteriously cannot be
--      fired from a seat, with no error anywhere. That is the same shape of
--      silent failure check_weapons.lua was written for.
--
--   2. IT REDEFINES TWO ENTRIES AND NOTHING ELSE. The whole argument for
--      shipping this at all is that it restates no Rockstar data and therefore
--      cannot go stale. The moment somebody adds a <VehicleLayoutInfos> or a
--      <VehicleDriveByInfos> section, that argument is dead and the file has
--      become a copy of Rockstar's with a maintenance cost attached. This gate
--      makes that a deliberate act with a red build in front of it rather than
--      a diff nobody looks at.
--
-- It also checks the fxmanifest, because a data file declared in `files` but
-- not in `data_file` (or the reverse) is a resource that looks correct, boots
-- clean, and does nothing at all.
--
-- Run via tools/verify.sh, or directly:  lua tools/check_driveby.lua

local ROOT = 'resources/[fivem-royale]/'
for _, f in ipairs({ 'br_lib/shared/enums.lua', 'br_lib/shared/geo.lua',
                     'br_lib/config/weapons.lua' }) do
    local chunk, err = loadfile(ROOT .. f)
    if not chunk then
        io.write('\27[31mload error\27[0m ', f, ': ', tostring(err), '\n')
        os.exit(1)
    end
    chunk()
end

local META     = ROOT .. 'br_environment/data/vehiclelayouts.meta'
local MANIFEST = ROOT .. 'br_environment/fxmanifest.lua'
local DECLARED = 'data/vehiclelayouts.meta'

--- The two base-game entries this file is allowed to redefine, and the reason
--- each one is here. Front and rear are separate entries in the base game, so
--- the change has to be made twice or half the seats in a squad car keep the
--- old rule.
local GROUPS = {
    DRIVEBY_DEFAULT_ONE_HANDED      = 'front seats (driver and front passenger)',
    DRIVEBY_DEFAULT_REAR_ONE_HANDED = 'rear seats',
}

local fails = 0
local function fail(fmt, ...)
    fails = fails + 1
    io.write('\27[31mFAIL\27[0m ', string.format(fmt, ...), '\n')
end

local function slurp(path)
    local f = io.open(path, 'r')
    if not f then return nil end
    local s = f:read('*a')
    f:close()
    return s
end

-- ------------------------------------------------------------------- parser --

--- A tag walker, not an XML library.
---
--- It tracks the open-element stack so an unbalanced file is an ERROR rather
--- than a silently truncated read -- which matters more here than anywhere
--- else in this repo, because the consumer of this file is a C++ parser inside
--- the game whose complaints nobody sees.
---
--- @param src string  the file, comments already stripped
--- @return table|nil  { sections = {name...}, groups = { {name=, types={}, groups={}} } }
--- @return string|nil error
local function parse(src)
    local stack, pos = {}, 1
    local sections, groups = {}, {}
    local cur, list = nil, nil
    local text = ''

    while true do
        local lt = src:find('<', pos, true)
        if not lt then break end
        text = src:sub(pos, lt - 1):gsub('^%s+', ''):gsub('%s+$', '')
        local gt = src:find('>', lt + 1, true)
        if not gt then return nil, 'unterminated tag at byte ' .. lt end
        local tag = src:sub(lt + 1, gt - 1)
        pos = gt + 1

        if tag:sub(1, 1) == '?' or tag:sub(1, 1) == '!' then
            -- declaration; carries no structure
        elseif tag:sub(1, 1) == '/' then
            local name = tag:sub(2)
            local top = stack[#stack]
            if top ~= name then
                return nil, ('</%s> closes <%s>'):format(name, tostring(top))
            end
            -- The text just before a closing tag is that element's content.
            if name == 'Name' and cur then cur.name = text end
            if name == 'Item' and list and text ~= '' then list[#list + 1] = text end
            if name == 'WeaponTypeNames' or name == 'WeaponGroupNames' then list = nil end
            if name == 'Item' and #stack == 3 and cur then
                groups[#groups + 1] = cur
                cur = nil
            end
            stack[#stack] = nil
        else
            local selfClosing = tag:sub(-1) == '/'
            if selfClosing then tag = tag:sub(1, -2) end
            local name = tag:match('^([%w_]+)')
            if not name then return nil, 'unnamed tag: <' .. tag .. '>' end

            if #stack == 1 then sections[#sections + 1] = name end
            if name == 'Item' and tag:find('CDrivebyWeaponGroup', 1, true) then
                cur = { name = nil, types = {}, groups = {} }
            end
            if not selfClosing then
                if name == 'WeaponTypeNames'  and cur then list = cur.types  end
                if name == 'WeaponGroupNames' and cur then list = cur.groups end
                stack[#stack + 1] = name
            end
        end
    end

    if #stack > 0 then
        return nil, 'unclosed <' .. stack[#stack] .. '>'
    end
    return { sections = sections, groups = groups }
end

-- SELF-TEST, before a single real check. A parser that returns nothing passes
-- every "is X absent" test in this file and fails every "is X present" one, and
-- check_weapons.lua already learned that a gate which fails everything -- or
-- passes everything -- teaches nothing.
do
    local probe = [[<?xml version="1.0"?>
<CVehicleMetadataMgr>
  <DrivebyWeaponGroups>
    <Item type="CDrivebyWeaponGroup">
      <Name>PROBE</Name>
      <WeaponGroupNames />
      <WeaponTypeNames>
        <Item>WEAPON_A</Item>
        <Item>WEAPON_B</Item>
      </WeaponTypeNames>
    </Item>
  </DrivebyWeaponGroups>
</CVehicleMetadataMgr>]]
    local got, err = parse(probe)
    local okShape = got
        and #got.sections == 1 and got.sections[1] == 'DrivebyWeaponGroups'
        and #got.groups == 1 and got.groups[1].name == 'PROBE'
        and #got.groups[1].types == 2
        and got.groups[1].types[1] == 'WEAPON_A'
        and got.groups[1].types[2] == 'WEAPON_B'
        and #got.groups[1].groups == 0
    if not okShape then
        io.write('\27[31mthe parser in this gate is broken\27[0m -- its own probe ',
            'did not read back (', tostring(err), ')\n')
        os.exit(1)
    end
    -- ...and it must NOTICE damage, or "no problems found" means nothing.
    if parse('<a><b></a>') ~= nil then
        io.write('\27[31mthe parser in this gate is broken\27[0m -- it accepted ',
            'mismatched tags\n')
        os.exit(1)
    end
end

-- -------------------------------------------------------------------- checks --

local raw = slurp(META)
local parsed
if not raw then
    fail('%s is missing -- the drive-by override is declared but not shipped', META)
else
    local err
    parsed, err = parse((raw:gsub('<!%-%-.-%-%->', '')))
    if not parsed then
        fail('%s does not parse: %s', META, err)
    end
end

if parsed then
    -- 1. NOTHING BUT WEAPON GROUPS. See the header: this is the claim that
    --    keeps the file small enough to be maintenance-free.
    for _, s in ipairs(parsed.sections) do
        if s ~= 'DrivebyWeaponGroups' then
            fail('%s declares a <%s> section. Only <DrivebyWeaponGroups> may be '
                .. 'redefined here -- anything else restates Rockstar data that '
                .. 'goes stale on the next game build. If that is genuinely '
                .. 'wanted, change this gate first and say why in docs/vehicle-data.md',
                META, s)
        end
    end

    -- 2. THE TWO ENTRIES, BOTH DIRECTIONS. A group that is here and not
    --    expected is scope creep; one that is expected and not here is half a
    --    squad car left on the old rule.
    local seen = {}
    for _, g in ipairs(parsed.groups) do
        local name = g.name or '(unnamed)'
        if seen[name] then
            fail('%s defines %s twice', META, name)
        end
        seen[name] = g
        if not GROUPS[name] then
            fail('%s redefines %s, which is not one of the two entries this '
                .. 'project claims to touch', META, name)
        end
    end
    for name, why in pairs(GROUPS) do
        if not seen[name] then
            fail('%s does not redefine %s (%s), so those seats keep GTA\'s own '
                .. 'one-handed-only rule', META, name, why)
        end
    end

    -- 3. THE WEAPON LIST, BOTH DIRECTIONS, PER GROUP.
    local want, wantN = {}, 0
    for _, w in ipairs(BR.Config.Weapons or {}) do
        want[w.name] = w.id
        wantN = wantN + 1
    end
    -- Throwables and melee are deliberately absent: thrown weapons are
    -- DRIVEBY_THROW (a group this file does not touch, and they already work
    -- from a seat), and a melee drive-by is a different group again. Listing
    -- one here would be a change nobody asked for.
    local never = {}
    for _, list in ipairs({ BR.Config.Throwables, BR.Config.Melee }) do
        for _, w in ipairs(list or {}) do never[w.name] = w.id end
    end

    for name, g in pairs(seen) do
        local have = {}
        for _, t in ipairs(g.types) do
            if have[t] then
                fail('%s lists %s twice in %s', META, t, name)
            end
            have[t] = true
            if never[t] then
                fail('%s lists %s in %s -- that is a throwable or a melee weapon '
                    .. 'and belongs to a group this file does not touch', META, t, name)
            elseif not want[t] then
                fail('%s lists %s in %s, which br_lib/config/weapons.lua does not '
                    .. 'issue', META, t, name)
            end
        end
        for w, id in pairs(want) do
            if not have[w] then
                fail('%s is missing from %s in %s -- weapon %q would LOSE drive-by, '
                    .. 'because this list replaces the base game\'s rather than '
                    .. 'extending it', w, name, META, id)
            end
        end
        -- An empty WeaponGroupNames is the decision that makes the check above
        -- exact. One entry there quietly re-admits a whole class of weapons and
        -- the both-directions comparison stops meaning anything.
        if #g.groups > 0 then
            fail('%s gives %s a non-empty <WeaponGroupNames> (%s). The weapon list '
                .. 'is authored one weapon at a time on purpose', META, name,
                table.concat(g.groups, ' '))
        end
    end
end

-- 4. THE MANIFEST. Declared in `files` so it reaches the client and
--    LoadResourceFile can read it back; declared as a data_file so the game
--    mounts it. Either alone is a resource that does nothing.
local man = slurp(MANIFEST)
if not man then
    fail('%s is missing', MANIFEST)
else
    local code = man:gsub('%-%-[^\n]*', '')
    -- INSIDE THE files{} BLOCK, not anywhere in the file. The data_file line
    -- below names the same path, so a search over the whole manifest passes
    -- with files{} empty -- which is a client that never receives the file at
    -- all. Caught by mutation: deleting the files{} entry survived a whole run.
    local block = code:match('files%s*{(.-)}')
    if not (block and block:find("'" .. DECLARED .. "'", 1, true)) then
        fail('%s does not list %q in files{} -- the client never receives it and '
            .. '/brdriveby cannot read it back', MANIFEST, DECLARED)
    end
    if not code:find("data_file 'VEHICLE_LAYOUTS_FILE' '" .. DECLARED .. "'", 1, true) then
        fail('%s does not mount %q as VEHICLE_LAYOUTS_FILE -- the game never '
            .. 'parses it and every seat keeps its own rule', MANIFEST, DECLARED)
    end
end

-- -------------------------------------------------------------------- report --

if fails == 0 then
    local n = 0
    for _, w in ipairs(BR.Config.Weapons or {}) do n = n + 1 end
    io.write(('\27[32mok\27[0m   %d weapon group(s) redefined, %d firearm(s) in each, '
        .. '0 Rockstar seats restated\n'):format(#(parsed and parsed.groups or {}), n))
else
    io.write(('\27[31m%d drive-by data problem(s)\27[0m\n'):format(fails))
end

os.exit(fails == 0 and 0 or 1)
