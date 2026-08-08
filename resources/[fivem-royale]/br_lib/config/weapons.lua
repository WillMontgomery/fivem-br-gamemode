-- Weapon definitions.
--
-- Hashes are stored as literals rather than resolved with GetHashKey so this
-- table can be loaded and tested outside the game, and so the server's damage
-- validation never pays for a native call per hit.
--
-- Two fields exist purely for the anti-cheat pipeline and are not cosmetic:
--   maxRange     -- a hit reported beyond this is rejected outright
--   minInterval  -- minimum ms between shots; a token bucket uses this to catch
--                   rapid-fire modifications
--
-- RANGE CEILING: FiveM's default entity culling radius is 424 units and the
-- natives that would widen it are deprecated. Nothing here has a maxRange above
-- that, because a target further away is not rendered and cannot be hit legitimately.
--
-- EXCLUSIONS ARE AN ANTI-CHEAT DECISION as much as a balance one. RPG, minigun,
-- railgun, grenade launcher and homing launcher are absent from this table, which
-- means they are absent from the entity allowlist -- removing the highest-value
-- targets for a weapon-spawning cheat.

BR = BR or {}
BR.Config = BR.Config or {}

local R = BR.Rarity

BR.Config.Weapons = {
    -- Pistols ---------------------------------------------------------------
    { id = 'pistol',        name = 'WEAPON_PISTOL',           hash = 0x1B06D571, label = 'Pistol',            rarity = R.COMMON,    ammo = BR.AmmoType.LIGHT,  damage = 26, maxRange = 120.0, minInterval = 140, clip = 12 },
    { id = 'snspistol',     name = 'WEAPON_SNSPISTOL',        hash = 0xBFD21232, label = 'SNS Pistol',        rarity = R.COMMON,    ammo = BR.AmmoType.LIGHT,  damage = 25, maxRange = 100.0, minInterval = 140, clip =  6 },
    { id = 'combatpistol',  name = 'WEAPON_COMBATPISTOL',     hash = 0x5EF9FEC4, label = 'Combat Pistol',     rarity = R.UNCOMMON,  ammo = BR.AmmoType.LIGHT,  damage = 27, maxRange = 130.0, minInterval = 130, clip = 12 },
    { id = 'pistolmk2',     name = 'WEAPON_PISTOL_MK2',       hash = 0xBFE256D4, label = 'Pistol Mk II',      rarity = R.UNCOMMON,  ammo = BR.AmmoType.LIGHT,  damage = 28, maxRange = 140.0, minInterval = 130, clip = 12 },
    { id = 'heavypistol',   name = 'WEAPON_HEAVYPISTOL',      hash = 0xD205520E, label = 'Heavy Pistol',      rarity = R.RARE,      ammo = BR.AmmoType.LIGHT,  damage = 40, maxRange = 150.0, minInterval = 160, clip = 18 },
    { id = 'revolver',      name = 'WEAPON_REVOLVER',         hash = 0xC1B3C3D1, label = 'Heavy Revolver',    rarity = R.RARE,      ammo = BR.AmmoType.LIGHT,  damage = 97, maxRange = 160.0, minInterval = 400, clip =  6 },
    { id = 'revolvermk2',   name = 'WEAPON_REVOLVER_MK2',     hash = 0xCB96392F, label = 'Revolver Mk II',    rarity = R.EPIC,      ammo = BR.AmmoType.LIGHT,  damage = 99, maxRange = 180.0, minInterval = 380, clip =  6 },

    -- SMGs ------------------------------------------------------------------
    { id = 'microsmg',      name = 'WEAPON_MICROSMG',         hash = 0x13532244, label = 'Micro SMG',         rarity = R.COMMON,    ammo = BR.AmmoType.SMG,    damage = 22, maxRange = 110.0, minInterval =  70, clip = 16 },
    { id = 'machinepistol', name = 'WEAPON_MACHINEPISTOL',    hash = 0xDB1AA450, label = 'Machine Pistol',    rarity = R.COMMON,    ammo = BR.AmmoType.SMG,    damage = 21, maxRange = 100.0, minInterval =  65, clip = 12 },
    { id = 'minismg',       name = 'WEAPON_MINISMG',          hash = 0xBD248B55, label = 'Mini SMG',          rarity = R.UNCOMMON,  ammo = BR.AmmoType.SMG,    damage = 23, maxRange = 120.0, minInterval =  70, clip = 20 },
    { id = 'smg',           name = 'WEAPON_SMG',              hash = 0x2BE6766B, label = 'SMG',               rarity = R.UNCOMMON,  ammo = BR.AmmoType.SMG,    damage = 24, maxRange = 150.0, minInterval =  80, clip = 30 },
    { id = 'smgmk2',        name = 'WEAPON_SMG_MK2',          hash = 0x78A97CD0, label = 'SMG Mk II',         rarity = R.RARE,      ammo = BR.AmmoType.SMG,    damage = 26, maxRange = 160.0, minInterval =  80, clip = 30 },
    { id = 'assaultsmg',    name = 'WEAPON_ASSAULTSMG',       hash = 0xEFE7E2DF, label = 'Assault SMG',       rarity = R.RARE,      ammo = BR.AmmoType.SMG,    damage = 27, maxRange = 170.0, minInterval =  75, clip = 30 },
    { id = 'combatpdw',     name = 'WEAPON_COMBATPDW',        hash = 0x0A3D4D34, label = 'Combat PDW',        rarity = R.RARE,      ammo = BR.AmmoType.SMG,    damage = 28, maxRange = 180.0, minInterval =  75, clip = 30 },

    -- Assault rifles --------------------------------------------------------
    { id = 'bullpuprifle',  name = 'WEAPON_BULLPUPRIFLE',     hash = 0x7F229F94, label = 'Bullpup Rifle',     rarity = R.UNCOMMON,  ammo = BR.AmmoType.MEDIUM, damage = 30, maxRange = 220.0, minInterval =  90, clip = 30 },
    { id = 'assaultrifle',  name = 'WEAPON_ASSAULTRIFLE',     hash = 0xBFEFFF6D, label = 'Assault Rifle',     rarity = R.RARE,      ammo = BR.AmmoType.MEDIUM, damage = 33, maxRange = 240.0, minInterval =  95, clip = 30 },
    { id = 'carbinerifle',  name = 'WEAPON_CARBINERIFLE',     hash = 0x83BF0278, label = 'Carbine Rifle',     rarity = R.RARE,      ammo = BR.AmmoType.MEDIUM, damage = 32, maxRange = 260.0, minInterval =  95, clip = 30 },
    { id = 'advancedrifle', name = 'WEAPON_ADVANCEDRIFLE',    hash = 0xAF113F99, label = 'Advanced Rifle',    rarity = R.RARE,      ammo = BR.AmmoType.MEDIUM, damage = 34, maxRange = 250.0, minInterval =  90, clip = 30 },
    { id = 'carbinemk2',    name = 'WEAPON_CARBINERIFLE_MK2', hash = 0xFAD1F1C9, label = 'Carbine Mk II',     rarity = R.EPIC,      ammo = BR.AmmoType.MEDIUM, damage = 36, maxRange = 280.0, minInterval =  95, clip = 30 },
    { id = 'assaultmk2',    name = 'WEAPON_ASSAULTRIFLE_MK2', hash = 0x394F415C, label = 'Assault Rifle Mk II', rarity = R.EPIC,    ammo = BR.AmmoType.MEDIUM, damage = 37, maxRange = 270.0, minInterval =  95, clip = 30 },
    { id = 'specialcarbine',name = 'WEAPON_SPECIALCARBINE',   hash = 0xC0A3098D, label = 'Special Carbine',   rarity = R.EPIC,      ammo = BR.AmmoType.MEDIUM, damage = 38, maxRange = 290.0, minInterval =  95, clip = 30 },
    { id = 'militaryrifle', name = 'WEAPON_MILITARYRIFLE',    hash = 0x9D1F17E6, label = 'Military Rifle',    rarity = R.LEGENDARY, ammo = BR.AmmoType.MEDIUM, damage = 42, maxRange = 320.0, minInterval =  90, clip = 30 },

    -- Shotguns --------------------------------------------------------------
    { id = 'sawnoff',       name = 'WEAPON_SAWNOFFSHOTGUN',   hash = 0x7846A318, label = 'Sawed-Off Shotgun', rarity = R.COMMON,    ammo = BR.AmmoType.SHELLS, damage = 70, maxRange =  25.0, minInterval = 450, clip =  8 },
    { id = 'pumpshotgun',   name = 'WEAPON_PUMPSHOTGUN',      hash = 0x1D073A89, label = 'Pump Shotgun',      rarity = R.UNCOMMON,  ammo = BR.AmmoType.SHELLS, damage = 85, maxRange =  35.0, minInterval = 900, clip =  8 },
    { id = 'assaultshotgun',name = 'WEAPON_ASSAULTSHOTGUN',   hash = 0xE284C527, label = 'Assault Shotgun',   rarity = R.RARE,      ammo = BR.AmmoType.SHELLS, damage = 72, maxRange =  40.0, minInterval = 300, clip =  8 },
    { id = 'pumpshotgunmk2',name = 'WEAPON_PUMPSHOTGUN_MK2',  hash = 0x555AF99A, label = 'Pump Shotgun Mk II',rarity = R.EPIC,      ammo = BR.AmmoType.SHELLS, damage = 92, maxRange =  45.0, minInterval = 850, clip =  8 },
    { id = 'heavyshotgun',  name = 'WEAPON_HEAVYSHOTGUN',     hash = 0x3AABBBAA, label = 'Heavy Shotgun',     rarity = R.EPIC,      ammo = BR.AmmoType.SHELLS, damage = 88, maxRange =  42.0, minInterval = 400, clip =  6 },
    { id = 'combatshotgun', name = 'WEAPON_COMBATSHOTGUN',    hash = 0x05A96BA4, label = 'Combat Shotgun',    rarity = R.EPIC,      ammo = BR.AmmoType.SHELLS, damage = 80, maxRange =  48.0, minInterval = 320, clip =  8 },

    -- Marksman and sniper ---------------------------------------------------
    -- Deliberately few and high-rarity: the render ceiling makes true long-range
    -- sniping impossible, so a map full of snipers would promise a fantasy the
    -- engine cannot deliver.
    { id = 'marksmanrifle', name = 'WEAPON_MARKSMANRIFLE',    hash = 0xC734385A, label = 'Marksman Rifle',    rarity = R.EPIC,      ammo = BR.AmmoType.HEAVY,  damage = 65, maxRange = 340.0, minInterval = 450, clip =  8 },
    { id = 'sniperrifle',   name = 'WEAPON_SNIPERRIFLE',      hash = 0x05FC3C11, label = 'Sniper Rifle',      rarity = R.EPIC,      ammo = BR.AmmoType.HEAVY,  damage = 101,maxRange = 400.0, minInterval = 1400,clip = 10 },
    { id = 'marksmanmk2',   name = 'WEAPON_MARKSMANRIFLE_MK2',hash = 0x6A6C02E0, label = 'Marksman Mk II',    rarity = R.LEGENDARY, ammo = BR.AmmoType.HEAVY,  damage = 70, maxRange = 380.0, minInterval = 430, clip =  8 },
    { id = 'heavysniper',   name = 'WEAPON_HEAVYSNIPER',      hash = 0x0C472FE2, label = 'Heavy Sniper',      rarity = R.LEGENDARY, ammo = BR.AmmoType.HEAVY,  damage = 216,maxRange = 420.0, minInterval = 1800,clip =  6 },

    -- LMG -------------------------------------------------------------------
    { id = 'mg',            name = 'WEAPON_MG',               hash = 0x9D07F764, label = 'MG',                rarity = R.RARE,      ammo = BR.AmmoType.HEAVY,  damage = 34, maxRange = 230.0, minInterval =  85, clip = 54 },
    { id = 'gusenberg',     name = 'WEAPON_GUSENBERG',        hash = 0x61012683, label = 'Gusenberg Sweeper', rarity = R.RARE,      ammo = BR.AmmoType.HEAVY,  damage = 32, maxRange = 200.0, minInterval =  80, clip = 50 },
    { id = 'combatmg',      name = 'WEAPON_COMBATMG',         hash = 0x7FD62962, label = 'Combat MG',         rarity = R.EPIC,      ammo = BR.AmmoType.HEAVY,  damage = 38, maxRange = 250.0, minInterval =  85, clip = 100 },
    { id = 'combatmgmk2',   name = 'WEAPON_COMBATMG_MK2',     hash = 0xDBBD7280, label = 'Combat MG Mk II',   rarity = R.LEGENDARY, ammo = BR.AmmoType.HEAVY,  damage = 40, maxRange = 270.0, minInterval =  85, clip = 100 },
}

--- Throwables. Smoke is not filler: it is the only tool that makes a contested
--- revive possible, so it is in from the start rather than added later.
BR.Config.Throwables = {
    { id = 'grenade',    name = 'WEAPON_GRENADE',      hash = 0x93E220BD, label = 'Grenade',       rarity = R.RARE,     maxStack = 3 },
    { id = 'molotov',    name = 'WEAPON_MOLOTOV',      hash = 0x24B17070, label = 'Molotov',       rarity = R.UNCOMMON, maxStack = 3 },
    { id = 'sticky',     name = 'WEAPON_STICKYBOMB',   hash = 0x2C3731D9, label = 'Sticky Bomb',   rarity = R.EPIC,     maxStack = 3 },
    { id = 'smoke',      name = 'WEAPON_SMOKEGRENADE', hash = 0xFDBC8A50, label = 'Smoke Grenade', rarity = R.COMMON,   maxStack = 3 },
}

--- MELEE. Crate-only, and deliberately a separate list from the firearms.
---
--- They have no magazine and no ammo pool, so they cannot take part in the
--- ammo model at all -- which is why they are not in BR.Config.Weapons, whose
--- gate (tools/check_weapons.lua) requires both. Everything else treats them
--- as ordinary weapons: same lookups, same allowlist, same body-part damage.
---
--- HASHES COMPUTED, NOT RECALLED. Every one of these was produced by hashing
--- the name with joaat rather than copied from a table, and the gate re-derives
--- them on every commit -- so a typo here fails the build instead of shipping a
--- machete nobody can pick up.
---
--- Damage is banded by rarity rather than by GTA's own numbers: a Stone Hatchet
--- that two-shots is a legendary find, a Broken Bottle is what you swing when
--- the drop went badly.
BR.Config.Melee = {
    { id = 'knuckle',   name = 'WEAPON_KNUCKLE',      hash = 0xD8DF3C3C, label = 'Brass Knuckles',        rarity = R.COMMON,    damage = 32, melee = true },
    { id = 'bottle',    name = 'WEAPON_BOTTLE',       hash = 0xF9E6AA4B, label = 'Broken Bottle',         rarity = R.COMMON,    damage = 32, melee = true },
    { id = 'crowbar',   name = 'WEAPON_CROWBAR',      hash = 0x84BD7BFD, label = 'Crowbar',               rarity = R.UNCOMMON,  damage = 40, melee = true },
    { id = 'bat',       name = 'WEAPON_BAT',          hash = 0x958A4A8F, label = 'Baseball Bat',          rarity = R.UNCOMMON,  damage = 44, melee = true },
    { id = 'wrench',    name = 'WEAPON_WRENCH',       hash = 0x19044EE0, label = 'Pipe Wrench',           rarity = R.UNCOMMON,  damage = 46, melee = true },
    { id = 'dagger',    name = 'WEAPON_DAGGER',       hash = 0x92A27487, label = 'Antique Cavalry Dagger',rarity = R.RARE,      damage = 52, melee = true },
    { id = 'knife',     name = 'WEAPON_KNIFE',        hash = 0x99B507EA, label = 'Knife',                 rarity = R.RARE,      damage = 52, melee = true },
    { id = 'switchblade',name= 'WEAPON_SWITCHBLADE',  hash = 0xDFE37640, label = 'Switchblade',           rarity = R.RARE,      damage = 54, melee = true },
    { id = 'machete',   name = 'WEAPON_MACHETE',      hash = 0xDD5DF8D9, label = 'Machete',               rarity = R.RARE,      damage = 58, melee = true },
    { id = 'hatchet',   name = 'WEAPON_HATCHET',      hash = 0xF9DCBF2D, label = 'Hatchet',               rarity = R.EPIC,      damage = 64, melee = true },
    { id = 'battleaxe', name = 'WEAPON_BATTLEAXE',    hash = 0xCD274149, label = 'Battle Axe',            rarity = R.EPIC,      damage = 70, melee = true },
}

--- Utility weapon hashes referenced directly by gameplay code.
BR.Config.Gadgets = {
    PARACHUTE = 0xFBAB5776,  -- GADGET_PARACHUTE, granted at drop, removed on landing
    UNARMED   = 0xA2719263,  -- WEAPON_UNARMED
}

--- Ammo pool caps, per pool.
BR.Config.AmmoCaps = {
    [BR.AmmoType.LIGHT]  = 300,
    [BR.AmmoType.SMG]    = 400,
    [BR.AmmoType.MEDIUM] = 350,
    [BR.AmmoType.SHELLS] = 120,
    [BR.AmmoType.HEAVY]  =  60,
}

-- Lookup tables, built once at load. The combat validator runs these per hit, so
-- a linear scan over 35 weapons would be wasteful.
BR.Config.WeaponByHash = {}
BR.Config.WeaponById   = {}

-- KEYED BY THE NORMALISED HASH, and every lookup must normalise too. The
-- engine returns hashes SIGNED, so the twenty weapons here whose hash has the
-- top bit set arrive negative and would miss a table keyed by the positive
-- literal -- see BR.NormHash for what that cost.
for _, w in ipairs(BR.Config.Weapons) do
    BR.Config.WeaponByHash[BR.NormHash(w.hash)] = w
    BR.Config.WeaponById[w.id]                  = w
end
for _, t in ipairs(BR.Config.Throwables) do
    BR.Config.WeaponByHash[BR.NormHash(t.hash)] = t
    BR.Config.WeaponById[t.id]                  = t
end
for _, m in ipairs(BR.Config.Melee) do
    BR.Config.WeaponByHash[BR.NormHash(m.hash)] = m
    BR.Config.WeaponById[m.id]                  = m
end

--- Melee bucketed by rarity, in authored order -- same construction and same
--- reason as every other bucket table here: the loot layout must replay
--- identically from a seed, so nothing rolls against a hash-keyed table.
BR.Config.MeleeByRarity = {}
for r = BR.Rarity.COMMON, BR.Rarity.LEGENDARY do
    BR.Config.MeleeByRarity[r] = {}
end
for _, m in ipairs(BR.Config.Melee) do
    local b = BR.Config.MeleeByRarity[m.rarity]
    if b then b[#b + 1] = m end
end

--- Is this weapon hash one the gamemode permits at all?
--- Used by the entity/weapon allowlist -- anything not here is a cheat signal.
--- @param hash integer
--- @return boolean
function BR.Config.IsAllowedWeapon(hash)
    -- Normalised on the way in: this is fed straight from engine values, which
    -- are signed. Unnormalised, every top-bit-set weapon in the game would
    -- read as "not allowed" -- i.e. as a cheat signal, for using a rifle we
    -- shipped.
    local h = BR.NormHash(hash)
    return BR.Config.WeaponByHash[h] ~= nil
        or h == BR.NormHash(BR.Config.Gadgets.PARACHUTE)
        or h == BR.NormHash(BR.Config.Gadgets.UNARMED)
end

--- Expected damage for a hit, before body-part multipliers.
--- The server recomputes this rather than trusting the client's reported value.
--- @param hash integer
--- @param rarity integer|nil
--- @param distance number|nil
--- @return number
function BR.Config.ExpectedDamage(hash, rarity, distance)
    -- Normalised: M6's damage validator feeds this straight from
    -- weaponDamageEvent, which reports signed hashes. Unnormalised, half the
    -- arsenal would validate as 0 expected damage -- i.e. every hit with a
    -- carbine would look like a cheat.
    local w = BR.Config.WeaponByHash[BR.NormHash(hash)]
    if not w or not w.damage then return 0.0 end

    local dmg = w.damage * (BR.RarityInfo[rarity or BR.Rarity.COMMON].damageMult)

    -- Linear falloff over the back half of the weapon's range, floored at 55%.
    if distance and w.maxRange then
        local half = w.maxRange * 0.5
        if distance > half then
            local t = (distance - half) / half
            dmg = dmg * BR.Lerp(1.0, 0.55, BR.Clamp(t, 0.0, 1.0))
        end
    end

    return dmg
end

-- Rarity buckets, built once at load. A match rolls ~1900 loot stacks, and the
-- old per-call linear scan allocated a fresh table for every one of them.
--
-- Order inside a bucket is the authored order of BR.Config.Weapons, which is
-- fixed source order rather than pairs() order -- the loot layout must be
-- reproducible from a seed, and an index built by iterating a hash would not be.
BR.Config.WeaponsByRarity   = {}
BR.Config.ThrowablesByRarity = {}

for r = BR.Rarity.COMMON, BR.Rarity.LEGENDARY do
    BR.Config.WeaponsByRarity[r]    = {}
    BR.Config.ThrowablesByRarity[r] = {}
end
for _, w in ipairs(BR.Config.Weapons) do
    local b = BR.Config.WeaponsByRarity[w.rarity]
    if b then b[#b + 1] = w end
end
for _, t in ipairs(BR.Config.Throwables) do
    local b = BR.Config.ThrowablesByRarity[t.rarity]
    if b then b[#b + 1] = t end
end

--- All weapons of a given rarity, for loot rolls.
--- @param rarity integer
--- @return table  the shared bucket -- treat as read-only
function BR.Config.WeaponsOfRarity(rarity)
    return BR.Config.WeaponsByRarity[rarity] or {}
end

--- All throwables of a given rarity.
--- @param rarity integer
--- @return table  the shared bucket -- treat as read-only
function BR.Config.ThrowablesOfRarity(rarity)
    return BR.Config.ThrowablesByRarity[rarity] or {}
end
