-- Weapon table gate.
--
-- GTA weapon hashes are not arbitrary: a weapon's hash IS the Jenkins
-- one-at-a-time hash of its lowercased name. That means every `hash` in
-- br_lib/config/weapons.lua is CHECKABLE, offline, against the `name` sitting
-- next to it -- and a wrong one is otherwise close to undetectable.
--
-- This was written after the Advanced Rifle appeared to have unlimited ammo
-- while every other gun behaved (user, 2026-08-06). Nothing errors when a hash
-- is wrong. The weapon is given to the ped under one hash and read back under
-- another, so:
--
--   * GetCurrentPedWeapon never matches, so the ammo reporter -- which now
--     refuses to report unless the engine agrees what is in the hand -- bails
--     out every single tick;
--   * nothing is ever reported, so nothing is ever deducted;
--   * the gun has unlimited ammo, and it is the ONLY symptom.
--
-- One typed hex digit, one weapon that never runs dry, and no error anywhere.
-- Checking the whole table takes a millisecond, so check the whole table.
--
-- Run via tools/verify.sh, or directly:  lua tools/check_weapons.lua

local ROOT = 'resources/[fivem-royale]/br_lib/'
for _, f in ipairs({ 'shared/enums.lua', 'shared/geo.lua', 'config/weapons.lua' }) do
    local chunk, err = loadfile(ROOT .. f)
    if not chunk then
        io.write('\27[31mload error\27[0m ', f, ': ', tostring(err), '\n')
        os.exit(1)
    end
    chunk()
end

local fails = 0
local function fail(fmt, ...)
    fails = fails + 1
    io.write('\27[31mFAIL\27[0m ', string.format(fmt, ...), '\n')
end

--- Jenkins one-at-a-time, as GTA computes it: over the LOWERCASED name, with
--- every step truncated to 32 bits.
--- @param s string
--- @return integer
local function joaat(s)
    local h = 0
    s = s:lower()
    for i = 1, #s do
        h = (h + s:byte(i)) & 0xFFFFFFFF
        h = (h + (h << 10)) & 0xFFFFFFFF
        h = (h ~ (h >> 6))  & 0xFFFFFFFF
    end
    h = (h + (h << 3))  & 0xFFFFFFFF
    h = (h ~ (h >> 11)) & 0xFFFFFFFF
    h = (h + (h << 15)) & 0xFFFFFFFF
    return h
end

-- Self-test: if joaat itself is wrong every line below is wrong together, and
-- a gate that fails everything teaches nothing. WEAPON_PISTOL is the anchor --
-- its hash is 0x1B06D571 in every published table there is.
if joaat('WEAPON_PISTOL') ~= 0x1B06D571 then
    io.write('\27[31mjoaat is broken\27[0m -- WEAPON_PISTOL hashed to 0x',
        ('%08X'):format(joaat('WEAPON_PISTOL')), ', expected 0x1B06D571\n')
    os.exit(1)
end

-- ------------------------------------------------------------------- checks --

local seenId, seenHash = {}, {}
local checked = 0

local function check(list, what)
    for _, w in ipairs(list or {}) do
        checked = checked + 1

        if seenId[w.id] then
            fail('duplicate weapon id %q', w.id)
        end
        seenId[w.id] = true

        if not w.name then
            fail('%s %q has no name to hash', what, tostring(w.id))
        else
            local want = joaat(w.name)
            if w.hash ~= want then
                fail('%s %q (%s): hash is 0x%08X, should be 0x%08X',
                     what, w.id, w.name, w.hash or 0, want)
            end
        end

        -- Two weapons sharing a hash is the same failure wearing a different
        -- hat: WeaponByHash keeps one and the other becomes unreachable.
        if w.hash then
            if seenHash[w.hash] then
                fail('%q and %q share hash 0x%08X',
                     w.id, seenHash[w.hash], w.hash)
            end
            seenHash[w.hash] = w.id
        end
    end
end

check(BR.Config.Weapons, 'weapon')
check(BR.Config.Throwables, 'throwable')
check(BR.Config.Melee, 'melee')
-- The airdrop shelf (#88). In no rarity bucket, so nothing that walks the loot
-- tables would ever notice a typo here -- and a wrong hash on an RPG is the
-- Advanced Rifle bug at the top of this file with a rocket launcher: the weapon
-- is given under one hash, read back under another, and has unlimited ammo with
-- no other symptom.
check(BR.Config.AirdropWeapons, 'airdrop weapon')
-- Fists are not a list, but they ARE resolved from an engine hash on every
-- punch, so the same joaat proof has to cover them. This is the check that
-- would have caught the hash being wrong; the thing that made fists fail in
-- game was that they were not registered at all.
check({ BR.Config.Fists }, 'fists')

-- THE WORLD'S OWN DAMAGE. These are matched against live engine hashes on
-- every fall, fire and car crash, and a typo here does not fail quietly -- it
-- turns falling off a roof into "a weapon this gamemode does not issue", i.e.
-- a cancelled hit and an anticheat strike against the player who fell.
check(BR.Config.Environmental, 'environmental')

for _, w in ipairs(BR.Config.Environmental or {}) do
    if BR.Config.EnvironmentalFor(w.hash) ~= w then
        fail('%q does not resolve through EnvironmentalFor', w.id)
    end
    -- An environmental source that is ALSO a weapon would be owned by the
    -- validator and never pass through, which is the failure that would put
    -- our damage table on a drowning.
    if BR.Config.WeaponByHash[BR.NormHash(w.hash)] then
        fail('%q is in both the weapon table and the environmental table', w.id)
    end
end

-- ...and registered, which is a separate claim from being spelled correctly.
-- Fists are deliberately outside every loot list, so nothing else in this gate
-- would notice if the by-hand registration below the tables were dropped.
if BR.Config.WeaponByHash[BR.NormHash(BR.Config.Fists.hash)] ~= BR.Config.Fists then
    fail('fists do not resolve through WeaponByHash -- every punch in the game '
         .. 'would be refused as an unknown weapon')
end

-- ...and the same for the airdrop shelf, which is registered the same way and
-- would fail the same way: silently, since nothing else in this file reads it.
--
-- AND IN NO BUCKET, WHICH IS THE OTHER HALF OF WHAT THEY ARE. An RPG that
-- reached BR.Config.WeaponsByRarity is an RPG in every legendary crate on the
-- map, ~1900 rolls a match, and the only symptom is that the game got a lot
-- louder. Checked here rather than trusted to the registration loop staying
-- where it is.
for _, w in ipairs(BR.Config.AirdropWeapons or {}) do
    if BR.Config.WeaponByHash[BR.NormHash(w.hash)] ~= w then
        fail('airdrop weapon %q does not resolve through WeaponByHash -- it '
             .. 'would be refused as a weapon this gamemode does not issue', w.id)
    end
    if BR.Config.WeaponById[w.id] ~= w then
        fail('airdrop weapon %q does not resolve through WeaponById -- the '
             .. 'airdrop pool that names it would resolve to nothing', w.id)
    end
    for r = BR.Rarity.COMMON, BR.Rarity.LEGENDARY do
        for _, x in ipairs(BR.Config.WeaponsByRarity[r] or {}) do
            if x.id == w.id then
                fail('airdrop weapon %q is in rarity bucket %d -- it is world '
                     .. 'loot now, on the floor of the whole map', w.id, r)
            end
        end
    end
end

-- An explosive with no blast radius would be range-checked as though the
-- victim had to be where the grenade landed.
for _, list in ipairs({ BR.Config.Throwables, BR.Config.AirdropWeapons }) do
    for _, t in ipairs(list or {}) do
        if t.explosive then
            if not t.blastRadius or t.blastRadius <= 0 then
                fail('%q is explosive but has no blastRadius', t.id)
            end
            if not t.maxRange or t.maxRange <= 0 then
                fail('%q is explosive but has no maxRange (travel distance)', t.id)
            end
        end
    end
end

-- A firearm without a magazine size or an ammo pool cannot take part in the
-- ammo model at all -- it would read as unlimited for a different reason.
for _, list in ipairs({ BR.Config.Weapons, BR.Config.AirdropWeapons }) do
    for _, w in ipairs(list or {}) do
        if not w.clip or w.clip < 1 then
            fail('weapon %q has no clip size', w.id)
        end
        if not w.ammo then
            fail('weapon %q has no ammo pool', w.id)
        end
        if w.ammo and not (BR.Config.AmmoCaps or {})[w.ammo] then
            fail('weapon %q draws from ammo pool %q, which has no cap -- it can '
                 .. 'never be reloaded', w.id, tostring(w.ammo))
        end
    end
end

-- ------------------------------------------------------------ drive-by ----
--
-- EVERY WEAPON MUST SAY WHETHER A CAR SEAT ACCEPTS IT, AND SAYING NOTHING IS
-- NOT AN ANSWER (#206).
--
-- br_core/client/driveby.lua reads this field and, on the strength of it, tells
-- a passenger "switch to slot N to fire your X". If the field is missing, Lua
-- hands back nil, nil is not true, and the weapon is silently treated as
-- unusable from a seat -- so a gun added to the table above would quietly never
-- be offered, with no error anywhere. That is the same failure mode as the wrong
-- hash this gate was written for: no symptom except a feature that stops
-- working for one weapon.
--
-- THE OTHER DIRECTION IS WORSE AND IS NOT CHECKABLE HERE. A `true` on a weapon
-- the engine actually refuses sends a player to a slot that does not fire, and
-- no offline gate can know: which weapons a seat accepts is game data inside the
-- .rpf, and the game refused our attempt to redefine it (2026-08-22, see
-- docs/vehicle-data.md). The check on THAT direction is /brdriveby, from the
-- seat: it prints our claim next to what the engine did with the weapon, and
-- names the verdict `stowed-unexpected` when they disagree.
--
-- MELEE AND FISTS MUST NOT CARRY THE FIELD AT ALL. Swinging from a seat is
-- DRIVEBY_BIKE_MELEE, which no car seat reaches, so the answer is "no" for the
-- whole list and always will be -- and a `driveby = false` on eleven melee
-- entries reads as though the question were open per weapon. The absence is
-- asserted rather than left to habit, so nobody half-annotates the table.
local function checkDriveBy(list, what)
    for _, w in ipairs(list or {}) do
        if type(w.driveby) ~= 'boolean' then
            fail('%s %q has no `driveby` field (must be an explicit true/false '
                 .. '-- a missing one reads as false and is never offered)',
                 what, tostring(w.id))
        end
    end
end

checkDriveBy(BR.Config.Weapons, 'weapon')
checkDriveBy(BR.Config.Throwables, 'throwable')

for _, w in ipairs(BR.Config.Melee or {}) do
    if w.driveby ~= nil then
        fail('melee %q carries a `driveby` field; no car seat reaches '
             .. 'DRIVEBY_BIKE_MELEE, so the answer is no for the whole list',
             tostring(w.id))
    end
end
if BR.Config.Fists and BR.Config.Fists.driveby ~= nil then
    fail('fists carry a `driveby` field; unarmed is DRIVEBY_DEFAULT_UNARMED and '
         .. 'there is nothing to switch to')
end

-- ---------------------------------------------------------------- icons ----
--
-- EVERY WEAPON MUST HAVE A PICTURE THAT SOMEBODY CHOSE, AND DEFAULTING IS NOT
-- CHOOSING.
--
-- Owner, 2026-08-22: "Please double check that we have images for all of our
-- weapons in the inventory slots - railgun and grenade launcher do not have
-- images."
--
-- THE SAME ARGUMENT AS `driveby` ABOVE, and it failed the same silent way. The
-- airdrop shelf -- rpg, grenadelauncher, railgun, minigun -- shipped with no
-- artwork and no category, and NOTHING ERRORED, because ui-src/src/hud/
-- ItemIcon.tsx degrades twice on the way down:
--
--   1. `items/<id>.png` 404s, and the <img> onError swaps in a drawn icon --
--      by design, so the set can be filled a few at a time;
--   2. the drawn icon is picked by `WEAPON_CATEGORY[slot.id] ?? 'rifle'`, and
--      an id that is not in that map takes the DEFAULT.
--
-- So a railgun drew an assault rifle. Not a broken image, not an empty square,
-- not a console warning -- a confident picture of the wrong gun. Fallback (1)
-- is a feature and stays; fallback (2) is the one that must never be what
-- covers a real weapon, because it cannot be told apart from a correct answer
-- by looking at the screen. It took a playtest to find, which is exactly what
-- this gate is for.
--
-- ONLY `kind = 'weapon'` ITEMS ARE CHECKED, and that is ItemIcon's own routing
-- rather than a simplification: a throwable resolves to the 'throwable' icon
-- from its KIND and never consults the map, consumables have their own map,
-- ammo is deliberately artless, and fists are drawn by FistIcon. The three
-- lists below are the ones that reach `WEAPON_CATEGORY[...] ?? 'rifle'`.
--
-- A PNG IS NOT REQUIRED, A DECISION IS. Melee and the airdrop shelf are drawn
-- rather than photographed, so requiring a file would fail honest work. What
-- is required is that the id appears in the map, so that whoever adds the next
-- weapon has to answer "what does this look like" instead of inheriting a
-- rifle by silence.
local UI_ICON = 'ui-src/src/hud/ItemIcon.tsx'

--- The file with its comments stripped.
---
--- NOT OPTIONAL: the note above `rpg:` in that file names every id this gate
--- searches for, so a raw read would find the essay describing the bug and
--- report the bug as fixed. check_key_glyphs.lua learned this first.
local function tsCode(s)
    s = s:gsub('/%*.-%*/', ' ')
    s = s:gsub('//[^\n]*', '')
    return s
end

--- The `key: 'value'` pairs of a top-level `const NAME ... = { ... }` block.
local function objectKeys(src, name)
    local body = src:match('const%s+' .. name .. '[^=]*=%s*{(.-)\n}')
    if not body then return nil end
    local keys = {}
    for k in body:gmatch("([%a][%w_]*)%s*:%s*'") do keys[k] = true end
    return keys
end

do
    local fh = io.open(UI_ICON, 'r')
    if not fh then
        fail('%s is missing, so no weapon has a resolvable icon', UI_ICON)
    else
        local src = tsCode(fh:read('a'))
        fh:close()

        local cats  = objectKeys(src, 'WEAPON_CATEGORY')
        local paths = objectKeys(src, 'PATHS')

        if not cats then
            fail('%s no longer declares WEAPON_CATEGORY', UI_ICON)
        elseif not paths then
            fail('%s no longer declares PATHS', UI_ICON)
        else
            -- Every weapon that can sit in a slot names its own picture.
            for _, spec in ipairs({
                { BR.Config.Weapons,        'weapon' },
                { BR.Config.AirdropWeapons, 'airdrop weapon' },
                { BR.Config.Melee,          'melee weapon' },
            }) do
                for _, w in ipairs(spec[1] or {}) do
                    local id = tostring(w.id)
                    if not cats[id] then
                        fail('%s %q has no entry in WEAPON_CATEGORY (%s), so it '
                             .. 'falls through to the `?? \'rifle\'` default and '
                             .. 'draws a picture of a different gun',
                             spec[2], id, UI_ICON)
                    end
                end
            end

            -- And every category names a shape that exists. A map pointing at a
            -- missing path renders an empty <path d=undefined> -- a blank slot,
            -- with no error.
            local body = src:match('const%s+WEAPON_CATEGORY[^=]*=%s*{(.-)\n}') or ''
            for k, v in body:gmatch("([%a][%w_]*)%s*:%s*'([%a][%w_]*)'") do
                if not paths[v] then
                    fail('WEAPON_CATEGORY.%s names category %q, which has no '
                         .. 'entry in PATHS -- the slot would draw nothing', k, v)
                end
            end
        end
    end
end

-- ART SHIPS OR IT DOES NOT EXIST.
--
-- ui-src/public/ is the SOURCE and br_ui/ui/ is what FXServer actually serves;
-- vite copies one to the other on `npm run build`. A PNG committed to only one
-- of them is either art the game cannot see, or art whose source is gone at the
-- next build -- and tools/pre-commit's rebuild guard keys on `^ui-src/src/`, so
-- it does not cover public/ at all. Checked per id rather than by listing the
-- directories, because Lua cannot list one without io.popen and this repo is
-- developed on Windows (see tools/test_config.lua on why the directory walks
-- live in bash).
local SRC_ITEMS   = 'ui-src/public/items/'
local BUILT_ITEMS = 'resources/[fivem-royale]/br_ui/ui/items/'

local function exists(path)
    local fh = io.open(path, 'rb')
    if fh then fh:close() return true end
    return false
end

local paired = 0
for _, list in ipairs({ BR.Config.Weapons, BR.Config.AirdropWeapons,
                        BR.Config.Melee, BR.Config.Throwables }) do
    for _, w in ipairs(list or {}) do
        local id = tostring(w.id)
        local inSrc, inBuilt = exists(SRC_ITEMS .. id .. '.png'),
                               exists(BUILT_ITEMS .. id .. '.png')
        if inSrc and inBuilt then
            paired = paired + 1
        elseif inSrc then
            fail('%q has artwork in %s but not in %s -- the game serves the '
                 .. 'built copy, so this art does not exist in game. Run: '
                 .. 'cd ui-src && npm run build', id, SRC_ITEMS, BUILT_ITEMS)
        elseif inBuilt then
            fail('%q has artwork in %s but not in %s -- the source is gone and '
                 .. 'the next build will delete it', id, BUILT_ITEMS, SRC_ITEMS)
        end
    end
end

-- THE SIGNED-HASH TRAP, pinned.
--
-- The engine returns hashes as SIGNED 32-bit ints, so a hash with the top bit
-- set arrives negative. Twenty of the forty weapons here are in that half, and
-- every one of them had unlimited ammo until 2026-08-06: the lookup missed,
-- the "is the engine holding what we think" guard could never be true, and the
-- ammo reporter bailed on every tick. Nothing errored, and printing both sides
-- as %08X masked them back to identical digits.
--
-- So: every weapon must resolve through WeaponByHash from BOTH the positive
-- literal AND the signed form the engine would hand back.
local signedChecked, topBit = 0, 0
local function signed32(h)
    return (h >= 0x80000000) and (h - 0x100000000) or h
end

for _, list in ipairs({ BR.Config.Weapons, BR.Config.Throwables,
                        BR.Config.Melee, BR.Config.AirdropWeapons }) do
    for _, w in ipairs(list or {}) do
        if w.hash then
            signedChecked = signedChecked + 1
            if w.hash >= 0x80000000 then topBit = topBit + 1 end

            if BR.Config.WeaponByHash[BR.NormHash(w.hash)] == nil then
                fail('%q does not resolve from its positive hash', w.id)
            end
            if BR.Config.WeaponByHash[BR.NormHash(signed32(w.hash))] == nil then
                fail('%q does not resolve from the SIGNED hash the engine returns '
                     .. '(0x%08X -> %d)', w.id, w.hash, signed32(w.hash))
            end
            -- And the allowlist, which is fed straight from engine values.
            if not BR.Config.IsAllowedWeapon(signed32(w.hash)) then
                fail('%q reads as DISALLOWED when passed the signed hash', w.id)
            end
        end
    end
end

-- The gadgets go through the same doors.
for name, h in pairs(BR.Config.Gadgets or {}) do
    if not BR.Config.IsAllowedWeapon(signed32(h)) then
        fail('gadget %s reads as disallowed from its signed hash', name)
    end
end

-- ------------------------------------------------------------------- report --

if fails == 0 then
    local db = 0
    for _, list in ipairs({ BR.Config.Weapons, BR.Config.Throwables }) do
        for _, w in ipairs(list or {}) do
            if w.driveby == true then db = db + 1 end
        end
    end
    io.write(('\27[32mok\27[0m   %d weapon hashes match their names; %d resolve from '
        .. 'both signed and unsigned (%d have the top bit set); %d are claimed '
        .. 'usable from a car seat; every slot weapon names its own icon and '
        .. '%d have artwork in both the source and the built bundle\n')
        :format(checked, signedChecked, topBit, db, paired))
else
    io.write(('\27[31m%d weapon table problem(s)\27[0m\n'):format(fails))
end

os.exit(fails == 0 and 0 or 1)
