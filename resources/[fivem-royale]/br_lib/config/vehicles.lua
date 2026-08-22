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

-- ═══════════════════════════════════════════════════════════════════════════
-- HOW BREAKABLE A CAR IS
-- ═══════════════════════════════════════════════════════════════════════════
--
-- THE OWNER'S REQUEST, VERBATIM (2026-08-22, #213):
--
--   "the vehicle collision/cosmetic damage should be set way higher than it is
--    right now. As you may be aware, damaging vehicles to a point of total
--    failure is nearly impossible in base GTA V. That should not be the case
--    here."
--
-- ═══ WHY IT BELONGS IN THIS FILE AND NOT A NEW ONE ═══
--
-- Everything above decides WHICH vehicles a match tolerates. This decides how
-- long one of them lasts, and both are answers to the same question -- what a
-- vehicle is allowed to be in this gamemode. #195 settled the shape of that
-- question for fuel: "a vehicle must not be a permanent advantage". A car that
-- cannot be destroyed is the same permanence by a different route, so the
-- numbers that stop it live beside the list that bounds it.
--
-- ═══ FIVE MULTIPLIERS EXIST AND THEY ARE NOT ONE KNOB ═══
--
-- GTA keeps these as separate per-vehicle floats in `handling.meta`, all on a
-- documented 0.0..10.0 scale where HIGHER MEANS MORE DAMAGE (0.0 is immune,
-- 10.0 is ten times stock). What each one governs:
--
--   fCollisionDamageMult    how much damage an impact does to the car at all.
--                           This is the one the owner's word "collision" names.
--   fDeformationDamageMult  how far the panels actually bend. Purely visual,
--                           and it is the owner's word "cosmetic".
--   fEngineDamageMult       how fast the engine takes damage, "causing
--                           explosion or engine failure" in GTA's own words.
--                           THIS IS THE ONE "TOTAL FAILURE" ACTUALLY MEANS: a
--                           car with crumpled panels and a live engine still
--                           drives away, which is exactly the complaint.
--   fWeaponDamageMult       how much bullets hurt it. NOT what was asked for --
--                           see `weaponMultiplier` below.
--   fPetrolTankVolume       how much fuel leaks when the tank is shot. Read
--                           already by br_core/client/fuel.lua to convert the
--                           metre ledger into a gauge reading, and DELIBERATELY
--                           NOT TOUCHED here: changing it would move the fuel
--                           gauge as a side effect of a damage change.
--
-- The three petrol-tank/engine/body HEALTH pools (0..1000) are a different
-- thing again and are not set here either. They are what the condition bar
-- reads and what a pump refill restores; this file changes the RATE they fall
-- at, never their value. Nothing in this feature ever writes a health number.
--
-- ═══ THEY ARE PER VEHICLE, SO SOMETHING HAS TO APPLY THEM PER VEHICLE ═══
--
-- SET_VEHICLE_HANDLING_FLOAT is a Cfx native with `apiset: client`, and its
-- implementation clones the model's CHandlingData onto the one entity it is
-- given (fivem/code/components/handling-loader-five). So there is no global
-- switch to throw and no server-side call to make: every client applies these
-- itself, to the vehicles it can see, and br_core/client/vehdamage.lua is the
-- file that does it. Read its header for who applies them and when.
--
-- ITS PER-MODEL SIBLING WAS EXAMINED AND IS THE WRONG NATIVE. SET_HANDLING_FLOAT
-- takes a handling NAME rather than an entity and edits the shared template --
-- which sounds like exactly what "set it once for everything" wants, and is not,
-- because the clone above is taken AT SPAWN. Every vehicle already in the world
-- holds its own copy and would never see the edit; only cars spawned afterwards
-- would. Under #193's Option A the world is populated before anybody drives
-- anything, so that is close to "no vehicle in the match".
--
-- ═══ THE `SetVehicleDamageModifier` FAMILY WAS LOOKED FOR AND IS NOT USABLE ═══
--
-- #213 names it. It does exist -- 0x4E20D2A627011E8E -- and so do three
-- neighbours (0x45A561A9421AB6AD, 0x84D7FFD223CAAFFD, 0x9640E30A7F395E4B).
-- Every one of them is an UNNAMED native: no Rockstar name, an empty
-- description, unknown parameters, and no open implementation anywhere that
-- calls any of them. Two competing community databases disagree about what the
-- first one is even called. Shipping a balance lever whose semantics nobody can
-- state would make every later "make it more" a guess about a guess, so the
-- documented handling fields are what this uses. If somebody ever measures one
-- of those hashes in game, this is the paragraph to come back to.
--
-- ═══ WHOSE PRIOR ART, AND WHY NONE OF IT IS IN THIS TREE ═══
--
-- RECORDED BECAUSE THE STANDING RULE IS TO RECORD IT. The read-scale-write shape
-- below is the one the ecosystem converged on, and every implementation of it is
-- licensed in a way this repo cannot take a byte from:
--
--   RealisticVehicleFailure (iEns/Jens Sandalgaard)  CC BY-SA 4.0. Share-alike
--                                                    copyleft; the canonical
--                                                    implementation.
--   QuantumMalice/vehiclehandler, aabbdev/VehicleHealth   GPL-3.0
--   PawanKrd/pk_vehiclecrash                              AGPL-3.0
--   Kiminaze/VehicleDeformation                      proprietary (NOASSERTION)
--   VehicleRealismV3                                 PAID and obfuscated
--
-- NO CODE WAS TAKEN FROM ANY OF THEM. What is used is the natives' own
-- documentation, GTAMods' handling.meta reference for what each field means and
-- what its range is, and FiveM's own C++ for how the per-vehicle override is
-- stored -- all of which are documentation of the platform rather than somebody
-- else's work. One published FINDING is used and is worth attributing plainly:
-- RealisticVehicleFailure's README states that visual deformation does not sync
-- to other players, which independently corroborates the ownership analysis in
-- br_core/client/vehdamage.lua's header.
--
-- ═══ ONE NUMBER, BECAUSE IT WILL BE TUNED BY PLAYTEST ═══
--
-- "How hard a car should be to destroy" is not a desk question. It will be
-- turned up or down after somebody drives one into a wall, and the request will
-- arrive as "more" or "less" -- so exactly one value below is the answer to
-- that sentence, and everything else is either a name, a guard rail, or a knob
-- the owner has not asked to move.

--- GTA's own documented top of range for a damage multiplier.
---
--- The handling fields above are documented 0.0..10.0, where 10.0 is "ten times
--- damage". Nothing in the engine enforces that, which is why it is enforced
--- here: it is the ceiling `scale` falls back to when the configured one is
--- missing or nonsense, so a bad `ceiling` cannot produce an unbounded write.
BR.Config.VehicleDamageRangeMax = 10.0

BR.Config.VehicleDamage = {
    --- The whole feature, on one switch.
    ---
    --- OFF MEANS STOCK GTA, not "half applied". Every write this feature makes
    --- is derived from the model's own value, so switching it off simply stops
    --- the writes -- there is no half-state to be left in.
    enabled = true,

    --- ═══ THE ONE NUMBER ═══
    ---
    --- How many times more damage a vehicle takes than GTA gives it. It is a
    --- MULTIPLE OF THE MODEL'S OWN VALUE, not an absolute, and that is the
    --- choice worth understanding before changing it:
    ---
    ---   * stock values differ per model -- a Phantom is not a Blista -- and
    ---     writing one absolute over all of them would flatten whatever balance
    ---     Rockstar authored into the vehicle list. A relative scale keeps a
    ---     tough model relatively tough and still makes every model breakable.
    ---   * it composes with a deny-list that has nothing to say about
    ---     durability. config/vehicles.lua's own note on the plain `insurgent`
    ---     -- "it is armoured and has no weapon, and the rule the owner wrote is
    ---     about built-in weapons, not about durability" -- stays true: the
    ---     Insurgent is still the toughest thing on the road, it just is not
    ---     immortal any more.
    ---
    --- WHY 5.0, AND IT IS A STARTING POINT RATHER THAN AN ANSWER.
    ---
    --- Sampled stock values across a spread of models are roughly:
    ---
    ---     fCollisionDamageMult      0.7 .. 1.0
    ---     fDeformationDamageMult    0.7 .. 0.8
    ---     fEngineDamageMult         1.5
    ---
    --- and the handling mods that exist to fix precisely this complaint converge
    --- on an ABSOLUTE 4 to 5 for collision and 5 to 8.75 for deformation. So 5x
    --- puts an ordinary car at 3.5-5.0 collision (in that band), 3.5-4.0
    --- deformation (just under it) and 7.5 engine -- which is the aggressive one
    --- on purpose, because the engine is what "total failure" means and it is
    --- the half of the complaint that a dented immortal car does not answer.
    ---
    --- THAT IS ARITHMETIC ABOUT SOMEBODY ELSE'S TASTE. It is a defensible place
    --- to start and it is not a measurement; the measurement is somebody driving
    --- into a wall and saying whether that felt right.
    ---
    --- IT IS THE NUMBER TO TURN. "More" is a bigger one, "less" is a smaller
    --- one, and nothing else in this feature has to move with it. Below 1.0
    --- makes cars TOUGHER than GTA ships them, which is a legitimate direction;
    --- at or below 0.0 the feature switches itself off rather than making cars
    --- invulnerable, because a config typo must cost the feature and never
    --- reverse it.
    ---
    --- ═══ IT HAS ABOUT 6.6 OF HEADROOM BEFORE `ceiling` STARTS DECIDING ═══
    ---
    --- The engine field starts highest, so it meets the 10.0 cap first: 1.5 x
    --- 6.67 is 10.0. Past that, turning this number up stops moving the engine
    --- multiplier on an ordinary car and only moves the other two, which is a
    --- knob that has quietly half stopped working. `/brvehdamage` counts every
    --- clamped write and prints it, so this is visible rather than deduced -- but
    --- if the answer to a playtest is genuinely "much more than this", the
    --- honest edit is `ceiling` and not another turn of this.
    multiplier = 5.0,

    --- Bullet damage to a vehicle. DELIBERATELY 1.0, WHICH IS NO CHANGE.
    ---
    --- The owner asked for collision and cosmetic damage. Gunfire is a separate
    --- multiplier and a separate balance question -- it decides how long a car
    --- works as COVER, which is a thing a battle royale cares about a great deal
    --- and which nobody has asked to change. It is named here rather than left
    --- out so that the answer to "and what about shooting it?" is one edit and a
    --- readable default, instead of a field somebody has to discover.
    ---
    --- ABSOLUTE, NOT SCALED BY `multiplier`. Turning the one number above must
    --- not silently move a value the owner did not ask about.
    weaponMultiplier = 1.0,

    --- The most any of these may be written as, whatever the arithmetic says.
    ---
    --- GTA documents the range as 0.0..10.0 and does not enforce it. This does,
    --- and it earns its place twice: it keeps a large `multiplier` on a model
    --- that already had a high stock value inside the range the engine was
    --- tuned for, and it is the backstop for the one way this feature can drift
    --- -- see br_core/client/vehdamage.lua on re-reading a baseline off a
    --- vehicle we already wrote to.
    ceiling = 10.0,

    --- The only handling class SET_VEHICLE_HANDLING_FLOAT supports.
    ---
    --- Named rather than written into the client file as a bare string, for the
    --- reason config/weapons.lua gives about hashes: a magic constant in a file
    --- nobody edits is a magic constant nobody can check.
    class = 'CHandlingData',

    --- WHICH FIELDS ARE WRITTEN, WHAT DECIDES EACH, AND WHAT EACH ONE GOVERNS.
    ---
    --- AN ORDERED LIST RATHER THAN A KEYED TABLE, so the client applies them in
    --- a fixed order and `/brvehdamage` prints them in one. `from` names the key
    --- ABOVE that scales it, which is what keeps "the one number" honest: three
    --- rows read `multiplier` and the fourth deliberately does not.
    ---
    --- `governs` IS CONSOLE TEXT, NOT INTERFACE TEXT. It is printed by
    --- /brvehdamage and by nothing a player can see.
    fields = {
        { field = 'fCollisionDamageMult',   from = 'multiplier',
          governs = 'how much an impact hurts the car at all' },
        { field = 'fDeformationDamageMult', from = 'multiplier',
          governs = 'how far the panels bend -- the cosmetic half' },
        { field = 'fEngineDamageMult',      from = 'multiplier',
          governs = 'how fast the engine dies, which is what total failure is' },
        { field = 'fWeaponDamageMult',      from = 'weaponMultiplier',
          governs = 'how much bullets hurt the car -- unchanged at 1.0' },
    },

    --- How many distinct MODELS one client remembers stock handling for.
    ---
    --- The baseline is a property of the model rather than of the car, so this
    --- is bounded by how many different vehicles one player climbs into in a
    --- session -- a handful. The cap exists for the reason server/vehicles.lua's
    --- MAX_SEEN_MODELS does: the keys arrive from the world, and a table keyed
    --- on something the world supplies gets a bound whether or not anyone can
    --- imagine it filling. Past the cap a new model keeps its stock handling,
    --- which is the fail-safe direction -- a tougher car, never a wilder one.
    maxModels = 64,
}

--- What to write for one field, given the model's own value.
---
--- PURE, AND THAT IS THE POINT. This is the whole arithmetic of the feature, so
--- it can be tested against the shipped numbers in a bare Lua state --
--- tools/test_vehdamage.lua -- rather than only against a running game, which is
--- the same bargain BR.FuelSolve and BR.BoostSolve strike.
---
--- A BAD `stock` ANSWERS nil AND THE CALLER WRITES NOTHING. There is no
--- defensible value to invent for a field the engine would not report: leaving
--- GTA's own number alone is the only answer that cannot be wrong.
---
--- A BAD `mult` IS 1.0, NEVER A REVERSAL. BR.BoostSolve.target learned this the
--- same way and says so: "a config typo must cost the feature, never reverse
--- it." A negative multiplier here would write a negative damage multiplier,
--- and nobody knows what the engine does with one.
---
--- @param stock number|nil    the model's own handling value
--- @param mult number|nil     the multiplier from BR.Config.VehicleDamage
--- @param ceiling number|nil  the cap; falls back to the documented range top
--- @return number|nil value   what to write, or nil to leave the field alone
--- @return boolean clamped    true when the ceiling is what decided the answer
function BR.Config.VehicleDamage.scale(stock, mult, ceiling)
    local s = tonumber(stock)
    -- NaN IS NOT A NUMBER AND `s ~= s` IS THE ONLY WAY TO ASK. A NaN baseline
    -- multiplied by anything is NaN, and a NaN written into handling is a
    -- vehicle whose damage calculation nobody can predict.
    if s == nil or s ~= s or s < 0.0 then return nil, false end

    local m = tonumber(mult)
    if m == nil or m ~= m or m < 0.0 then m = 1.0 end

    local cap = tonumber(ceiling)
    if cap == nil or cap ~= cap or cap <= 0.0 then
        cap = BR.Config.VehicleDamageRangeMax
    end

    local v = s * m
    if v > cap then return cap, true end
    -- The floor cannot be reached from a non-negative stock and a non-negative
    -- multiplier, and it is here anyway: the two guards above are what make
    -- that true, and a clamp that depends on two other clamps staying correct
    -- is one refactor away from not being one.
    if v < 0.0 then return 0.0, false end
    return v, false
end
