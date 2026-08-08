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

-- An explosive with no blast radius would be range-checked as though the
-- victim had to be where the grenade landed.
for _, t in ipairs(BR.Config.Throwables or {}) do
    if t.explosive then
        if not t.blastRadius or t.blastRadius <= 0 then
            fail('throwable %q is explosive but has no blastRadius', t.id)
        end
        if not t.maxRange or t.maxRange <= 0 then
            fail('throwable %q is explosive but has no maxRange (throw distance)', t.id)
        end
    end
end

-- A firearm without a magazine size or an ammo pool cannot take part in the
-- ammo model at all -- it would read as unlimited for a different reason.
for _, w in ipairs(BR.Config.Weapons or {}) do
    if not w.clip or w.clip < 1 then
        fail('weapon %q has no clip size', w.id)
    end
    if not w.ammo then
        fail('weapon %q has no ammo pool', w.id)
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

for _, list in ipairs({ BR.Config.Weapons, BR.Config.Throwables, BR.Config.Melee }) do
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
    io.write(('\27[32mok\27[0m   %d weapon hashes match their names; %d resolve from '
        .. 'both signed and unsigned (%d have the top bit set)\n')
        :format(checked, signedChecked, topBit))
else
    io.write(('\27[31m%d weapon table problem(s)\27[0m\n'):format(fails))
end

os.exit(fails == 0 and 0 or 1)
