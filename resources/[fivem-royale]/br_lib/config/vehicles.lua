-- Which vehicles this gamemode tolerates in a match.
--
-- THE OWNER'S RULE, VERBATIM (2026-08-21, #193):
--
--   "For allowlist, we will allow every vehicle except anything that flies or
--    has built-in weapons."
--
-- That is a rule and not a list, and the server cannot evaluate it. The only
-- thing a server-side `entityCreating` handler holds is a model hash: there is
-- no server native that answers "is this a helicopter" or "does this have a
-- turret". So the rule has to become a list, and this file is where the list is
-- authored. It is the whole of it -- nothing else in the tree names a vehicle
-- model except BR.Config.Bus.model, which is the Battle Bus and is discussed
-- below.
--
-- ═══ THE POLARITY IS THE OPPOSITE OF weapons.lua's, AND THAT IS THE ONE THING
--     TO UNDERSTAND BEFORE EDITING THIS FILE ═══
--
-- config/weapons.lua is an ALLOWLIST: BR.Config.IsAllowedWeapon answers yes only
-- for a hash written down in that file, so a weapon nobody thought to name is
-- refused by construction. (It used to say the RPG, minigun, railgun and both
-- launchers were absent on anti-cheat grounds. #88 reversed that for the first
-- four -- they are airdrop loot now, in BR.Config.AirdropWeapons -- and the
-- reversal did not change the SHAPE of the rule, only which hashes are in it.
-- The homing launcher is still absent, and still refused.)
--
-- There, ABSENCE IS REFUSAL: a weapon has to be written down to be permitted.
-- Here, ABSENCE IS PERMISSION: a vehicle has to be written down to be refused.
-- The owner's rule allows "every vehicle except", and GTA ships several hundred
-- of them, so an exhaustive allow table would be a transcription exercise whose
-- every omission bans a car somebody was driving.
--
-- SO THIS IS A DENY-LIST, AND A DENY-LIST ROTS. #193 raised that objection
-- against exactly this shape -- "a deny-list rots, the same objection
-- tools/verify.sh raises against whole-file scope exemptions" -- and the owner's
-- rule makes it unavoidable rather than answering it. Stating the cost plainly
-- rather than hiding it:
--
--   * A DLC aircraft that ships after this table was written is ALLOWED by
--     construction. Not refused-and-logged: allowed, silently, because the rule
--     "everything except these" has no opinion about a hash it has never seen.
--   * `sv_enforceGameBuild` is pinned in server.cfg.example. Every bump of it is
--     a reason to revisit this file, and nothing mechanical will remind you.
--   * A name typo produces a row that refuses nothing. tools/check_vehicles.lua
--     catches a hash that disagrees with its name, which is the failure that
--     actually bites; it cannot catch a name that is spelled consistently and
--     names no real model.
--
-- ═══ THIS TABLE IS NOT THE BOUNDARY. IT IS THE RECORD ═══
--
-- The boundary is `sv_entityLockdown` in server.cfg.example, which refuses
-- client-created networked entities at the network layer, before any Lua runs
-- and before the model hash below is ever compared to anything.
--
-- This table decides what gets WRITTEN DOWN. The owner, same comment:
--
--   "For offenders, don't stop them, simply file an incident."
--
-- So br_core/server/vehicles.lua never cancels: it counts, and on the second
-- offence in a match it opens a case, exactly as server/strip.lua does for a
-- weapon that appeared in a hand. A refusal that nobody records is a refusal
-- nobody can act on, and #193's argument for doing both is that lockdown alone
-- logs nothing at all.
--
-- ═══ THE BATTLE BUS IS ON THIS LIST, ON PURPOSE, AND IT IS SAFE ═══
--
-- BR.Config.Bus.model is 'titan', and `titan` is in REFUSED below as a plane --
-- because it is one. It costs nothing today because client/bus.lua creates it
-- with `isNetwork = false` (bus.lua:197 and :829, and the pilot at :217 and
-- :843), and a non-networked entity never raises the server-side
-- `entityCreating` this table is read from. Every loot prop is the same:
-- client/loot.lua:928 passes isNetwork = false, and that is stated there as "the
-- entire basis of the design".
--
-- IF ANY OF THOSE EVER BECOMES NETWORKED, EVERY CLIENT IN THE MATCH FILES AN
-- INCIDENT AGAINST ITSELF FOR RIDING THE BUS. That is the trap, it is one
-- boolean wide, and it is written here rather than left to be discovered.
--
-- ═══ WHAT THE RULE ALLOWS THAT #193's BODY DID NOT ═══
--
-- #193's "Not in scope" line reads "Aircraft and boats of any kind", and its
-- own recommendation was to exclude Military, Helicopters, Planes, Boats and
-- Commercial. THE OWNER'S RULE IS NARROWER THAN BOTH: it names flight and
-- built-in weapons and nothing else. An unarmed boat neither flies nor carries a
-- gun, so it is allowed here, and so is a Mule, a Bus and a Phantom.
--
-- Following the rule as written is deliberate; the divergence is reported rather
-- than reconciled by guessing. It costs little in practice either way, because
-- BR.Native.applyWorldSetup already calls SetRandomBoats(false) and
-- SetRandomTrains(false), so ambient water traffic does not exist in a match
-- regardless of what this table says about it.

BR = BR or {}
BR.Config = BR.Config or {}

--- Why a model is refused. These strings reach a moderation record -- they are
--- the sentence BR.IncidentBuild.vehicleSummaryOf builds its queue row from --
--- so they are prose the way BR.ShotRefusal's values are, not symbols.
BR.Config.VehicleRefusal = {
    FLIES = 'vehicle flies',
    ARMED = 'vehicle has built-in weapons',
}

--- Every model this gamemode will not tolerate, and which half of the rule it
--- trips.
---
--- HASHES ARE LITERALS, NOT GetHashKey CALLS, for the reason weapons.lua gives
--- for the same choice: "so this table can be loaded and tested outside the
--- game". Every one below was produced by hashing the name with joaat and is
--- re-derived from that name on every commit by tools/check_vehicles.lua, so a
--- mistyped hex digit fails the build rather than shipping a Rhino nobody
--- notices is permitted.
---
--- GROUPED BY REASON RATHER THAN ALPHABETICALLY, because the groups are the two
--- halves of the owner's rule and a reader checking the rule against the list
--- should be able to see each half whole.
local F = BR.Config.VehicleRefusal.FLIES
local A = BR.Config.VehicleRefusal.ARMED

BR.Config.RefusedVehicles = {
    -- Fixed-wing. `titan` is the Battle Bus -- see the header.
    { name = 'alkonost',      why = F, hash = 0xEA313705 },
    { name = 'alphaz1',       why = F, hash = 0xA52F6866 },
    { name = 'avenger',       why = F, hash = 0x81BD2ED0 },
    { name = 'avenger2',      why = F, hash = 0x18606535 },
    { name = 'besra',         why = F, hash = 0x6CBD1D6D },
    { name = 'blimp',         why = F, hash = 0xF7004C86 },
    { name = 'blimp2',        why = F, hash = 0xDB6B4924 },
    { name = 'blimp3',        why = F, hash = 0xEDA4ED97 },
    { name = 'bombushka',     why = F, hash = 0xFE0A508C },
    { name = 'cargoplane',    why = F, hash = 0x15F27762 },
    { name = 'cuban800',      why = F, hash = 0xD9927FE3 },
    { name = 'dodo',          why = F, hash = 0xCA495705 },
    { name = 'duster',        why = F, hash = 0x39D6779E },
    { name = 'howard',        why = F, hash = 0xC3F25753 },
    { name = 'hydra',         why = F, hash = 0x39D6E83F },
    { name = 'jet',           why = F, hash = 0x3F119114 },
    { name = 'lazer',         why = F, hash = 0xB39B0AE6 },
    { name = 'luxor',         why = F, hash = 0x250B0C5E },
    { name = 'luxor2',        why = F, hash = 0xB79F589E },
    { name = 'mammatus',      why = F, hash = 0x97E55D11 },
    { name = 'microlight',    why = F, hash = 0x96E24857 },
    { name = 'miljet',        why = F, hash = 0x09D80F93 },
    { name = 'mogul',         why = F, hash = 0xD35698EF },
    { name = 'molotok',       why = F, hash = 0x5D56F01B },
    { name = 'nimbus',        why = F, hash = 0xB2CF7250 },
    { name = 'nokota',        why = F, hash = 0x3DC92356 },
    { name = 'pyro',          why = F, hash = 0xAD6065C0 },
    { name = 'raiju',         why = F, hash = 0x0E4C8C4D },
    { name = 'rogue',         why = F, hash = 0xC5DD6967 },
    { name = 'seabreeze',     why = F, hash = 0xE8983F9F },
    { name = 'shamal',        why = F, hash = 0xB79C1BF5 },
    { name = 'starling',      why = F, hash = 0x9A9EB7DE },
    { name = 'streamer216',   why = F, hash = 0x0B706A72 },
    { name = 'strikeforce',   why = F, hash = 0x64DE07A1 },
    { name = 'stunt',         why = F, hash = 0x81794C70 },
    { name = 'titan',         why = F, hash = 0x761E2AD3 },
    { name = 'tula',          why = F, hash = 0x3E2E4F8A },
    { name = 'velum',         why = F, hash = 0x9C429B6A },
    { name = 'velum2',        why = F, hash = 0x403820E8 },
    { name = 'vestra',        why = F, hash = 0x4FF77E37 },
    { name = 'volatol',       why = F, hash = 0x1AAD0DED },

    -- Rotary.
    { name = 'akula',         why = F, hash = 0x46699F47 },
    { name = 'annihilator',   why = F, hash = 0x31F0B376 },
    { name = 'annihilator2',  why = F, hash = 0x11962E49 },
    { name = 'buzzard',       why = F, hash = 0x2F03547B },
    { name = 'buzzard2',      why = F, hash = 0x2C75F0DD },
    { name = 'cargobob',      why = F, hash = 0xFCFCB68B },
    { name = 'cargobob2',     why = F, hash = 0x60A7EA10 },
    { name = 'cargobob3',     why = F, hash = 0x53174EEF },
    { name = 'cargobob4',     why = F, hash = 0x78BC1A3C },
    { name = 'conada',        why = F, hash = 0xE384DD25 },
    { name = 'frogger',       why = F, hash = 0x2C634FBD },
    { name = 'frogger2',      why = F, hash = 0x742E9AC0 },
    { name = 'havok',         why = F, hash = 0x89BA59F5 },
    { name = 'hunter',        why = F, hash = 0xFD707EDE },
    { name = 'maverick',      why = F, hash = 0x9D0450CA },
    { name = 'polmav',        why = F, hash = 0x1517D4D9 },
    { name = 'savage',        why = F, hash = 0xFB133A17 },
    { name = 'seasparrow',    why = F, hash = 0xD4AE63D9 },
    { name = 'seasparrow2',   why = F, hash = 0x494752F7 },
    { name = 'seasparrow3',   why = F, hash = 0x5F017E6B },
    { name = 'skylift',       why = F, hash = 0x3E48BF23 },
    { name = 'supervolito',   why = F, hash = 0x2A54C47D },
    { name = 'supervolito2',  why = F, hash = 0x9C5E5644 },
    { name = 'swift',         why = F, hash = 0xEBC24DF2 },
    { name = 'swift2',        why = F, hash = 0x4019CB4C },
    { name = 'valkyrie',      why = F, hash = 0xA09E15FD },
    { name = 'valkyrie2',     why = F, hash = 0x5BFA5C4B },
    { name = 'volatus',       why = F, hash = 0x920016F1 },

    -- Flies AND is armed. Filed under flight because that is the half a player
    -- would notice first: an Oppressor Mk II over the final circle is a problem
    -- long before it fires anything.
    { name = 'deluxo',        why = F, hash = 0x586765FB },
    { name = 'oppressor',     why = F, hash = 0x34B82784 },
    { name = 'oppressor2',    why = F, hash = 0x7B54A9D3 },
    { name = 'thruster',      why = F, hash = 0x58CDAF30 },

    -- Stays on the ground (or under water) and carries a gun.
    --
    -- `insurgent` -- the plain one -- IS DELIBERATELY ABSENT. It is armoured and
    -- has no weapon, and the rule the owner wrote is about built-in weapons, not
    -- about durability. How much punishment a vehicle takes is #194's question
    -- and it is unanswered; refusing a model here on a guess at that answer
    -- would be this file deciding it. The two Pick-Up variants below do have
    -- turrets and are refused for that.
    { name = 'apc',           why = A, hash = 0x2189D250 },
    { name = 'barrage',       why = A, hash = 0xF34DFB25 },
    { name = 'chernobog',     why = A, hash = 0xD6BC7523 },
    { name = 'halftrack',     why = A, hash = 0xFE141DA6 },
    { name = 'ignus2',        why = A, hash = 0x39085F47 },
    { name = 'insurgent2',    why = A, hash = 0x7B7E56F0 },
    { name = 'insurgent3',    why = A, hash = 0x8D4B7A8A },
    { name = 'khanjali',      why = A, hash = 0xAA6F980A },
    { name = 'kosatka',       why = A, hash = 0x4FAF0D70 },
    { name = 'patrolboat',    why = A, hash = 0xEF813606 },
    { name = 'rhino',         why = A, hash = 0x2EA68690 },
    { name = 'ruiner2',       why = A, hash = 0x381E10BD },
    { name = 'scramjet',      why = A, hash = 0xD9F0503D },
    { name = 'stromberg',     why = A, hash = 0x34DBA661 },
    { name = 'tampa3',        why = A, hash = 0xB7D9F7F1 },
    { name = 'technical',     why = A, hash = 0x83051506 },
    { name = 'technical2',    why = A, hash = 0x4662BCBB },
    { name = 'technical3',    why = A, hash = 0x50D4D19F },
    { name = 'toreador',      why = A, hash = 0x56C8A5EF },
    { name = 'trailersmall2', why = A, hash = 0x8FD54EBB },
    { name = 'vigilante',     why = A, hash = 0xB5EF4C33 },
}

--- Refused models keyed by NORMALISED hash.
---
--- NORMALISED ON THE WAY IN, and this is not pedantry -- it is the bug this
--- project has shipped four times, described at length in BR.NormHash. The
--- engine reports model hashes SIGNED; the table above authors them positive.
--- Forty of the models above have the top bit set, and unnormalised every one of
--- them would fail to match the value `GetEntityModel` actually returns -- so a
--- Hydra would read as an ordinary car and file nothing.
BR.Config.RefusedVehicleByHash = {}
for _, v in ipairs(BR.Config.RefusedVehicles) do
    BR.Config.RefusedVehicleByHash[BR.NormHash(v.hash)] = v
end

--- The `GetVehicleType` values that mean "this thing leaves the ground".
---
--- ═══ THE HALF OF THE OWNER'S RULE THAT DOES NOT HAVE TO ROT ═══
---
--- Everything above is a deny-list and the header says at length why that is a
--- shape with a leak in it: an aircraft nobody wrote down is permitted, silently,
--- forever. THIS TABLE CLOSES THAT LEAK FOR THE FLIGHT HALF, and it closes it for
--- models that do not exist yet.
---
--- `GetVehicleType` is a Cfx native with `apiset: shared`, so it is answerable ON
--- THE SERVER -- which almost nothing about a vehicle is. (`GetVehicleClass`, the
--- 0-22 one, is client-only; there is no server handler for it at all, which is
--- why #193's "class allowlist" recommendation is not what this file implements.)
--- It returns exactly eight strings and no others:
---
---     automobile  bike  boat  heli  plane  submarine  trailer  train
---
--- because it switches on the network-object class, and GTA V has only those
--- eight vehicle classes. Everything collapses into one of them: a quadbike and
--- an amphibious car are `automobile`, a bicycle is `bike`, a blimp is `heli` or
--- `plane`. So `heli` and `plane` between them ARE "anything that flies", for
--- every aircraft in the game and every aircraft added to it after this was
--- written. (The finer-grained enum, `GetVehicleTypeRaw`, is client-only.)
---
--- ═══ IT IS CLIENT-ASSERTED, WHICH IS WHY IT IS THE SECOND SIGNAL AND NOT THE
---     FIRST ═══
---
--- The type the server reads here comes out of the clone packet header the
--- CLIENT sent. The server does not cross-check it against the model in the sync
--- tree -- the check that would have is commented out in the platform's own
--- source. So a cheat that sets the header to `automobile` while spawning a Hydra
--- defeats this table and nothing else.
---
--- The two signals are complementary rather than redundant, and neither is
--- sufficient:
---
---   the model table  catches every model it NAMES, whatever the client claims
---                    the type is. Defeated by a model nobody wrote down.
---   this table       catches every aircraft, INCLUDING ones nobody wrote down.
---                    Defeated by a client that lies about the type.
---
--- Defeating both at once means spawning an aircraft this file has never heard
--- of AND lying about its class, which is a strictly higher bar than either
--- alone. Neither is the boundary; `sv_entityLockdown` is.
---
--- WHY `boat` AND `submarine` ARE NOT HERE. They do not fly and they have no
--- built-in weapons, so the owner's rule does not reach them -- see the header on
--- how that parts company with #193's body. The armed ones (`kosatka`,
--- `patrolboat`) are refused by name in the table above, on the weapons half of
--- the rule.
BR.Config.FlyingVehicleTypes = {
    heli  = true,
    plane = true,
}

--- Does this `GetVehicleType` value describe something that flies?
---
--- A FUNCTION RATHER THAN A BARE TABLE INDEX, because the value arrives from a
--- native that answers `nil` for a non-vehicle and THROWS for a stale handle.
--- Callers pcall the native; this makes the nil case a plain `false` instead of
--- an index into a table with a nil key, which is an error in Lua.
--- @param t string|nil  a GetVehicleType value
--- @return boolean
function BR.Config.IsFlyingVehicleType(t)
    if type(t) ~= 'string' then return false end
    return BR.Config.FlyingVehicleTypes[t] == true
end

--- Is this model one the gamemode tolerates?
---
--- MIRRORS BR.Config.IsAllowedWeapon's NAME AND SIGNATURE ON PURPOSE, and
--- inverts its implementation for the reason the header gives: there, a weapon
--- is allowed by being present; here, a vehicle is allowed by being absent.
--- Anyone who reads one and assumes the other has read this file backwards,
--- which is why both facts are said out loud in both places.
---
--- ZERO IS ALLOWED, AND THAT IS THE SAFE DIRECTION. `0` is TRUTHY in Lua, so
--- BR.NormHash(0) answers 0 rather than nil, and 0 is in no row above -- a
--- model the engine could not report reads as an ordinary vehicle and files
--- nothing. The other polarity would open a case every time a handle went bad.
---
--- @param hash integer|nil  a model hash, signed or not
--- @return boolean allowed
--- @return string|nil why   the refusal reason when it is not; nil when it is
function BR.Config.IsAllowedVehicle(hash)
    if hash == nil then return true, nil end
    local v = BR.Config.RefusedVehicleByHash[BR.NormHash(hash)]
    if v == nil then return true, nil end
    return false, v.why
end
