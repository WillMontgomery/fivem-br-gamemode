-- A vehicle this gamemode refuses, appearing in a match: from an engine event
-- to a countable fact.
--
-- THE OWNER'S TWO SENTENCES, 2026-08-21 (#193), and both halves are load-bearing:
--
--   "Let's go Option A, and enable entity lockdown."
--   "For offenders, don't stop them, simply file an incident."
--
-- Option A means THIS GAMEMODE SPAWNS NO VEHICLES AT ALL. The supply is GTA's
-- own ambient traffic and its parked-car network, throttled by BR.Config.Ambient
-- and written every frame by client/natives.lua. Nothing in this resource tree
-- creates a vehicle except client/bus.lua, and that one is local and
-- non-networked. So every networked vehicle in a match is, by construction,
-- something we did not make.
--
-- ═══ WHAT THIS CATCHES, STATED PLAINLY SO NOBODY MISTAKES IT FOR THE DEFENCE ═══
--
-- THE DEFENCE IS `sv_entityLockdown`, IN server.cfg.example, AND IT IS NOT THIS
-- FILE. Lockdown refuses client-created networked entities at the network layer,
-- before any Lua on this server runs. It is the boundary; this is the record.
--
-- #193's own counter-argument to lockdown is the reason this file exists at all:
-- what lockdown blocks, it blocks silently -- the entity never reaches the
-- server, so nothing is logged, and a match full of refused attempts and a clean
-- match produce identical records. A boundary that keeps no book cannot tell you
-- somebody is standing at it.
--
-- SO THE COVERAGE OF THIS FILE IS WHATEVER LOCKDOWN LETS THROUGH, and that is a
-- real limit rather than a rhetorical one. It is the same bargain
-- server/strip.lua strikes and describes: catch the tier you can catch, say so,
-- and do not let the catchable tier be mistaken for the whole.
--
-- ═══ WHAT THIS FILE CATCHES CHANGES WITH `sv_entityLockdown`, AND THAT IS NOT A
--     FLAW IN IT ═══
--
-- The platform validates a client's clone-create BEFORE raising `entityCreating`
-- -- a rejected entity is deleted and the event never fires -- so lockdown and
-- this detector are partly SUBSTITUTES rather than the pure complements #193
-- assumed. Per mode:
--
--   inactive   (the shipped default, and the repo's state today) the platform
--              does not even CALL its validator -- the mode is checked first and
--              short-circuits it -- so every client-created networked vehicle
--              reaches this handler. A trainer spawning a Rhino is
--              `POPTYPE_MISSION`, arrives here, and opens a case. THIS IS THE
--              PATH THAT IS LIVE RIGHT NOW and it is the reason this file is
--              worth having before the mode is settled.
--   relaxed    `MISSION` and `PERMANENT` are refused by the platform, so the
--              honest cheat never reaches this handler -- it was stopped, which
--              is better than being recorded. What still arrives is a refused
--              MODEL claiming a population type, because that 4-bit field is
--              read straight out of the client's own packet and can be a lie.
--              That is the one vehicle-cheat path lockdown leaves open, and it
--              is counted below.
--   strict     no client-created entity reaches the server at all, and neither
--              does the ambient traffic Option A's whole supply is made of.
--
-- Nothing here reads the convar or changes behaviour on it. The handler asks the
-- same questions in every mode and the mode decides which of them ever get
-- asked -- which is what keeps this file correct whichever way #193's open
-- question is answered.
--
-- ═══ `entityCreating` SEES CLIENT-CREATED ENTITIES AND ONLY THOSE ═══
--
-- Worth stating because it is the property that makes this detector cheap and
-- correct, and because it is not what the event's name suggests. The platform
-- raises `entityCreating` from ONE place: the client-to-server clone path. An
-- entity this server creates for itself does not pass through it -- it raises
-- `serverEntityCreated` instead, which nothing here listens to.
--
-- So the handler below cannot accuse anybody of something the gamemode did, and
-- it does not need a guard to avoid it. It also means the count is not a count
-- of vehicles in the match; it is a count of vehicles a CLIENT put there.
--
-- THE ONE EXCEPTION IS A TRAP AND IT IS AIMED AT #191. Server-side
-- `CreateVehicle` is an RPC native: the server asks a client to make the entity,
-- so it comes back up the clone path and DOES raise this event. (Server-side
-- `CreateVehicleServerSetter`, `CreatePed` and `CreateObjectNoOffset` do not --
-- they are server setters.) The CPR ambulance is meant to be local and
-- non-networked, so it should reach none of this; if it is ever spawned with
-- server-side `CreateVehicle` and its model is one config/vehicles.lua refuses,
-- this file will open a case about whichever player the engine handed ownership
-- to. An ambulance is not on that list. A rescue helicopter would be.
--
-- ═══ NOTHING HERE TOUCHES THE PLAYER, AND NOTHING HERE CANCELS ═══
--
-- `CancelEvent()` is available in this handler and is deliberately never called.
-- The owner: "don't stop them, simply file an incident." That is the same shape
-- the whole moderation path has -- server/incident.lua files and forms no
-- opinion, server/strip.lua announces and never kicks -- and it inherits the
-- rule those two state: the offender is shown nothing at any point, because a
-- player who discovers they are under suspicion changes behaviour, which costs
-- the case the evidence it was going to be made of.

BR = BR or {}
BR.Vehicles = {}

local cfg = BR.Config.Combat or {}

--- Which player states may draw a refused-vehicle count at all.
---
--- The same pair server/strip.lua gates its report on, for the same reason: a
--- lobby ped and a corpse are outside any match, so there is no timeline to put
--- the finding on and the evidence buffer would refuse the note anyway.
local LIVE = {
    [BR.PlayerState.ALIVE]  = true,
    [BR.PlayerState.WARMUP] = true,
}

--- GTA's population types, as `GetEntityPopulationType` reports them.
---
--- ONLY THE SCRIPT-CREATED ONES ARE THIS FILE'S BUSINESS, and getting that
--- backwards would be the single most expensive mistake available here. Under
--- Option A the map is FULL of vehicles we did not make and did not ask for --
--- that is the whole supply -- and every one of them is `RANDOM_PARKED` or
--- `RANDOM_AMBIENT`. Counting those would open a case against the nearest player
--- every time GTA parked a car near them.
local POPTYPE = {
    UNKNOWN         = 0,
    RANDOM_PERMANENT = 1,
    RANDOM_PARKED   = 2,
    RANDOM_PATROL   = 3,
    RANDOM_SCENARIO = 4,
    RANDOM_AMBIENT  = 5,
    PERMANENT       = 6,
    MISSION         = 7,
    REPLAY          = 8,
    CACHE           = 9,
    TOOL            = 10,
}

--- The population types that mean "a script put this here".
---
--- `MISSION` IS THE ONE THAT MATTERS and `PERMANENT` is included because a
--- client script can produce either. Everything else in the table above is the
--- engine populating the world.
---
--- IT IS A SIGNAL AND NOT A BOUNDARY, and #193 says why: the type is reported by
--- the same client that created the entity, and a `SetPedAsNoLongerNeeded`
--- immediately after creation is reported to flip 7 to 5. So a cheat that knows
--- about this check evades it with one extra native call. What it buys is not
--- protection from that cheat -- it is protection for the honest player standing
--- next to a car GTA parked, which is a thing that happens in every match.
local SCRIPTED = {
    [POPTYPE.MISSION]   = true,
    [POPTYPE.PERMANENT] = true,
}

--- The shortest gap between two counted refusals from one player.
---
--- SAME NUMBER AND SAME JOB AS server/strip.lua's MIN_INTERVAL_MS. A client
--- looping entity creation is exactly the shape an attacker can choose, and the
--- entity-creation path is cheaper for them to spam than the strip report is:
--- there is no cooperating resource in front of it to be polite. One countable
--- refusal per window per player, and the rest are dropped on the floor,
--- uncounted and unrecorded.
---
--- 900ms rather than a round second, for strip.lua's reason: a bound that sits
--- exactly on a natural cadence spends half its time deciding what gets recorded
--- instead of bounding what an attacker can force.
local MIN_INTERVAL_MS = 900

--- Per-source counters. [src] = { matchId, count, reports, at, why }
---
--- BOUNDED BY WHO IS CONNECTED. Cleared on disconnect and rebuilt when the
--- player's match changes, exactly as server/strip.lua's and server/damage.lua's
--- records are -- and for the same reason: server ids are recycled within the
--- minute, so a record left behind is inherited by whoever lands in that slot
--- next, and inheriting a count is inheriting somebody else's case.
local seenBy = {}

--- Refused models that claimed to be engine population, and how many times.
---
--- THE DIAGNOSTIC THAT SETTLES A QUESTION THIS FILE CANNOT ANSWER BY REASONING.
--- A refused model arriving with a population type is one of exactly two things
--- and they are indistinguishable from here:
---
---   * GTA's own ambient aircraft. The engine does place helicopters and planes
---     in the world, this gamemode has never suppressed them (it suppresses
---     boats, trains and garbage trucks and nothing else), and blaming the
---     nearest player for one would be the worst false positive available here.
---   * a client lying about the population field to walk a Rhino through
---     `relaxed` lockdown. That field is four bits out of the client's own
---     packet and the server does not cross-check it.
---
--- So the count is kept and the FILING IS NOT DONE, and `brvehicles` prints the
--- models. One playtest reads that list: mavericks and cargo planes mean the
--- engine is doing it, a Khanjali means somebody is not. Guessing which, in
--- code, before anybody has looked, is how an anticheat opens cases about people
--- standing near an airport.
---
--- BOUNDED, because the keys arrive from the wire. Distinct models are capped;
--- past the cap the counter still counts and the list simply stops growing.
local seenModels, seenModelCount = {}, 0
local MAX_SEEN_MODELS = 16

local stat = {
    seen = 0, vehicles = 0, ambient = 0, allowed = 0,
    counted = 0, throttled = 0, unowned = 0, byType = 0,
    roadkills = 0, roadkillLooks = 0, driving = 0,
}

--- Counters, for brdebug-style introspection. Printed by `brvehicles`.
---
--- `ambient` IS THE ONE TO WATCH, and it is the opposite of strip.lua's `races`.
--- It counts refused MODELS that were declined because the engine said the
--- engine had placed them -- so a number that climbs means GTA is streaming
--- aircraft into matches on its own, which is a gameplay finding (Option A's
--- supply is not ours) rather than an anticheat one. Every one of those would
--- otherwise have been a case opened against whoever happened to be nearest.
---
--- `byType` IS THE ONE THAT SAYS THE TABLE IS OUT OF DATE. It counts refusals
--- that the model table missed and `GetVehicleType` caught -- i.e. an aircraft
--- whose model nobody wrote down in config/vehicles.lua. A non-zero value is a
--- to-do item against that file, and it is the only warning that exists, because
--- a deny-list has no other way to report its own gaps.
function BR.Vehicles.stats()
    local tracked = 0
    for _ in pairs(seenBy) do tracked = tracked + 1 end
    return {
        tracked   = tracked,
        seen      = stat.seen,      vehicles  = stat.vehicles,
        ambient   = stat.ambient,   allowed   = stat.allowed,
        counted   = stat.counted,   throttled = stat.throttled,
        unowned   = stat.unowned,   byType    = stat.byType,
        models    = seenModels,
        -- The roadkill ledger below, which is a gameplay counter rather than an
        -- anticheat one and is printed under its own heading for that reason.
        roadkills = stat.roadkills, roadkillLooks = stat.roadkillLooks,
        driving   = stat.driving,
    }
end

--- Did a native declared BOOL say yes?
---
--- THROUGH THE `didHit` IDIOM, AND THIS IS THE FIFTH TIME IN THIS CODEBASE. A
--- FiveM native declared BOOL hands Lua a number on some builds and a boolean on
--- others, and IN LUA `0` IS TRUTHY -- so `if DoesEntityExist(e) then` is true
--- for an entity that does not exist on a build that answers numbers. Here that
--- would mean reading a model hash off a dead handle and filing whatever came
--- back.
--- @param v any
--- @return boolean
local function didHit(v)
    return v == 1 or v == true
end

--- Which player, if any, this server holds responsible for an entity.
---
--- `NetworkGetEntityOwner` IS THE ONLY ANSWER AVAILABLE AND IT IS NOT A
--- CONFESSION. Ownership follows proximity and migrates automatically -- #193
--- §2 collects the platform's own documentation of that -- so the owner of a
--- freshly created entity is very likely the client that created it and is not
--- guaranteed to be. At creation time it is the best claim there is; a second
--- later it means nothing.
---
--- THAT IS WHY THE BAR IS TWO. One refused vehicle attributed to one player is a
--- claim resting on an ownership read; two in a match from the same player is a
--- pattern. The same reasoning server/strip.lua uses for the same number.
---
--- @param entity integer
--- @return integer|nil src
--- What the engine says this vehicle's class is, or nil.
---
--- pcall'd BECAUSE THE NATIVE THROWS RATHER THAN ANSWERING. `GetVehicleType` is
--- built with the platform's `makeEntityFunction` wrapper, which raises
--- "Tried to access invalid entity" on a handle that has gone stale -- and a
--- handle going stale between the top of this handler and here is exactly the
--- race a flood of creations produces. An uncaught throw in `entityCreating`
--- would take the whole handler down, and with it the model check above it.
--- @param entity integer
--- @return string|nil
local function vehicleType(entity)
    if not GetVehicleType then return nil end
    local ok, t = pcall(GetVehicleType, entity)
    if not ok then return nil end
    -- The native answers nil for a non-vehicle. It answers one of exactly eight
    -- strings otherwise; BR.Config.IsFlyingVehicleType knows which two matter.
    return type(t) == 'string' and t or nil
end

local function ownerOf(entity)
    if not NetworkGetEntityOwner then return nil end
    local ok, owner = pcall(NetworkGetEntityOwner, entity)
    if not ok then return nil end
    local n = math.tointeger(tonumber(owner))
    -- ZERO IS TESTED FOR EXPLICITLY, AND IN LUA THAT IS NOT PEDANTRY. Source 0
    -- is the SERVER CONSOLE, not a player -- and `0` is truthy, so a bare
    -- `if n then` would accept it and go looking for a roster entry that cannot
    -- exist. `-1` is the platform's "nobody owns this".
    if n == nil or n <= 0 then return nil end
    return n
end

-- ---------------------------------------------------------------------------
-- The detector
-- ---------------------------------------------------------------------------

--- A networked entity is being created somewhere in the world.
---
--- SERVER-SIDE AND BEFORE THE FACT, which is what makes this the vehicle
--- equivalent of `weaponDamageEvent` rather than a client's report. #193 §3:
--- "the vehicle equivalent is entityCreating: server-side, fires before the
--- entity is created, GetEntityModel(entity) is readable there, and
--- CancelEvent() stops it." Everything in that sentence is used here except the
--- last clause, which the owner ruled out.
---
--- IT COSTS NOTHING ON THE ORDINARY PATH. Option A's supply is ambient, and this
--- gamemode creates no networked entities, so on a healthy server the two cheap
--- tests at the top -- is it a vehicle, is its model refused -- reject
--- everything before anything walks a table or touches the roster.
AddEventHandler('entityCreating', function(entity)
    stat.seen = stat.seen + 1

    -- A HANDLE THAT IS NOT THERE ANSWERS 0 FOR EVERY NATIVE BELOW, and 0 is a
    -- model hash that is in no row of the refused table -- so this would fall
    -- through as "allowed" rather than misfiring. Checked anyway, because
    -- falling through by luck is not the same as being correct, and because the
    -- next reader should not have to work that out.
    if not didHit(DoesEntityExist(entity)) then return end

    -- 2 IS A VEHICLE. Peds and objects are created constantly by the engine and
    -- are not this file's business: #193 scopes M8 to vehicles and the owner's
    -- rule is written about vehicles. A ped allowlist is a different feature
    -- with a different false-positive profile and it is not being smuggled in
    -- here.
    if GetEntityType(entity) ~= 2 then return end
    stat.vehicles = stat.vehicles + 1

    -- THE ALLOWLIST, AND IT IS THE CHEAPEST TEST THAT REJECTS THE MOST. Every
    -- ordinary car in every match reaches this line and leaves at it, one hash
    -- lookup later.
    --
    -- GetEntityModel IS READABLE HERE, and that is a property of where in the
    -- platform's clone path this event sits rather than an assumption: the
    -- create packet's sync tree is fully parsed before `entityCreating` is
    -- raised. (It is reported unreliable in this event for PICKUPS and for peds
    -- and objects on RedM, which is why the type gate above narrows to vehicles
    -- before this line rather than after it.)
    local model = GetEntityModel(entity)
    local allowed, why = BR.Config.IsAllowedVehicle(model)

    -- THE SECOND SIGNAL, AND THE ONLY THING STOPPING THE MODEL TABLE ROTTING
    -- INTO UNIFORM PERMISSION. config/vehicles.lua is a deny-list: an aircraft
    -- nobody wrote down is allowed by construction, forever, silently. Asking
    -- the engine what class this is catches every aircraft including the ones
    -- added to the game after that table was written.
    --
    -- ONLY CONSULTED WHEN THE TABLE SAID YES. A model the table already refuses
    -- keeps the table's reason -- which distinguishes "flies" from "armed", a
    -- distinction the class cannot make -- and this native is not called at all.
    if allowed then
        local t = vehicleType(entity)
        if BR.Config.IsFlyingVehicleType(t) then
            allowed, why = false, BR.Config.VehicleRefusal.FLIES
            stat.byType = stat.byType + 1
        end
    end

    if allowed then
        stat.allowed = stat.allowed + 1
        return
    end

    -- DID THE ENGINE PUT IT THERE? See SCRIPTED above for why this is a signal
    -- rather than a boundary, and why getting it backwards would be the most
    -- expensive mistake in this file.
    --
    -- A REFUSED MODEL CLAIMING TO BE POPULATION IS COUNTED AND NOT FILED. See
    -- `seenModels` for the two things it can be and why one playtest, rather
    -- than a guess written here, is what separates them.
    local pop = GetEntityPopulationType and GetEntityPopulationType(entity) or nil
    if pop ~= nil and not SCRIPTED[pop] then
        stat.ambient = stat.ambient + 1
        local key = BR.NormHash(model)
        if seenModels[key] then
            seenModels[key] = seenModels[key] + 1
        elseif seenModelCount < MAX_SEEN_MODELS then
            seenModels[key] = 1
            seenModelCount = seenModelCount + 1
        end
        return
    end

    -- NOBODY TO ATTRIBUTE IT TO IS NOT NOBODY TO BLAME -- it is a fact this
    -- server cannot record. A case needs a subject, and a subject needs a
    -- license.
    local src = ownerOf(entity)
    if src == nil then
        stat.unowned = stat.unowned + 1
        return
    end

    -- MUST BE A LIVE PLAYER IN A MATCH, for server/strip.lua's reason: outside
    -- one there is no timeline to put this on and no round for it to be about.
    local e = BR.Roster and BR.Roster.get and BR.Roster.get(src)
    if not e or not LIVE[e.state] or e.matchId == nil then return end

    local now = GetGameTimer()

    -- ONE PER WINDOW. Checked before anything else costs a roster walk or an
    -- identity read, because a flood is exactly the shape a client can choose.
    local rec = seenBy[src]
    if not rec or rec.matchId ~= e.matchId then
        rec = { matchId = e.matchId, count = 0, reports = 0, at = 0, why = why }
        seenBy[src] = rec
    end
    if rec.at ~= 0 and now - rec.at < MIN_INTERVAL_MS then
        stat.throttled = stat.throttled + 1
        return
    end

    -- NOBODY IS EXEMPT, and the absence of an admin check here is deliberate and
    -- inherited. server/strip.lua shipped one for a single commit and the owner
    -- removed it the same day -- "I don't want admins to be exempt from any
    -- incidents please" -- on the reasoning that an exemption is a hole in an
    -- anticheat shaped exactly like the accounts with the most power. It would
    -- be a worse idea here than there: spawning a vehicle through a trainer is
    -- precisely what an admin testing with vMenu does, so the exemption would
    -- silence this path for the only group that can reach it easily.
    local license = BR.Roster.licenseOf and BR.Roster.licenseOf(src) or nil

    rec.at    = now
    rec.count = rec.count + 1
    -- THE LATEST REASON, NOT THE FIRST. A player who spawns a jet and then a
    -- tank has a case whose one-line summary should say what they are doing
    -- now; the earlier reasons are on the corroborations, each carrying its own.
    rec.why   = why
    stat.counted = stat.counted + 1

    -- SILENT ON THE FIRST, THEN ON EVERY ONE AFTER IT -- the cadence the owner
    -- set for strips on 2026-08-20 ("this should fire an incident on the 2nd
    -- offense, and each subsequent should show as corroboration from system"),
    -- applied here because the shape of the finding is identical.
    --
    -- THE FIRST ONE IS QUIET FOR A REASON SPECIFIC TO THIS DETECTOR, and it is
    -- not strip.lua's reason. There, the first strip is forgiven because two of
    -- our own inventory mirrors can disagree for a tick. Here, the doubt is
    -- `ownerOf`: ownership migrates by proximity, so a single refused vehicle
    -- attributed to one player is a claim resting on one ownership read taken at
    -- one instant. A second one in the same match from the same player is not
    -- that.
    if rec.count < 2 then return end
    rec.reports = rec.reports + 1

    local name = e.name or ('src ' .. src)
    print(('[br_core] ANTICHEAT: %s (%d) -- %d refused vehicle(s) spawned this match (%s)')
        :format(name, src, rec.count, tostring(why)))

    -- HANDED OVER, NOT FILED HERE, exactly as server/strip.lua hands over.
    -- server/incident.lua is the file that knows what has been filed this match
    -- and answers the identical question for refusals and for strips.
    -- Fire-and-forget: if nothing is listening, the count is still kept and the
    -- boundary is still `sv_entityLockdown`, which is the part that protects the
    -- match.
    TriggerEvent('br:core:vehicle', {
        src      = src,
        name     = name,
        -- nil only for a genuinely licenseless connection, in which case
        -- BR.IncidentBuild.fromVehicle declines to file rather than opening a
        -- case about whoever holds this server id next.
        license  = license,
        matchId  = e.matchId,
        -- HOW MANY REFUSED VEHICLES THIS PLAYER HAS DRAWN THIS MATCH. Climbs by
        -- one each time -- 2, 3, 4, 5 -- so a gap here means a LOST
        -- announcement, exactly as a gap in `seq` does. The same contract
        -- server/strip.lua's `count` carries since the doubling rule was
        -- dropped.
        count    = rec.count,
        -- WHICH ANNOUNCEMENT THIS IS for this player, this match: 1 opens the
        -- case, 2+ corroborate it. It rides the wire so the console can tell a
        -- dropped corroboration from a match where nothing more happened -- the
        -- event channel discards a batch after four attempts and never says so.
        seq      = rec.reports,
        -- WHICH HALF OF THE OWNER'S RULE THIS TRIPPED, as config/vehicles.lua's
        -- own prose. It is what the queue row is built from.
        why      = why,
        -- THE MODEL, NORMALISED, FOR A HUMAN READING THE SERVER LOG. It is
        -- deliberately absent from the incident summary -- see
        -- BR.IncidentBuild.vehicleSummaryOf -- because a hash the refused table
        -- does not name renders as nothing useful on a moderation record.
        model    = BR.NormHash(model),
        at       = now,
    })
end)

-- ---------------------------------------------------------------------------
-- Roadkill: the one environmental cause with a person behind it
-- ---------------------------------------------------------------------------
--
-- THE OWNER'S ANSWER, 2026-08-21 (#194 question 3):
--
--   "What if GetPedSourceOfDeath returns vehicle, then see if the vehicle is
--    driven by a player, then find out which player it is. Roadkill should be
--    attributed to the driver."
--
-- The BEHAVIOUR is exactly that and it is what is built below. The ROUTE is
-- not, and the difference is the whole of this section.
--
-- ═══ GET_PED_SOURCE_OF_DEATH IS READ ON THE VICTIM'S MACHINE ═══
--
-- client/gamerules.lua calls it and sends the result to the server, and the
-- server has ignored that field since M6 -- see BR.Combat.attributedKiller,
-- "THE CLIENT IS NEVER ASKED". Believing it here would be a new exception to
-- the one rule docs/security.md is built around, and an unusually cheap one to
-- abuse: the payload is `{ cause, killer }`, both client-authored, so a pair of
-- players could farm eliminations by taking turns dying and naming each other's
-- car. An unattributed roadkill is a hole; a FORGEABLE roadkill credit is a
-- bigger one, because it manufactures kills that never happened rather than
-- losing kills that did.
--
-- ═══ SO THE SAME QUESTION IS ASKED OF STATE THIS SERVER ALREADY HOLDS ═══
--
-- This is server/damage.lua's fire attributor, term for term, and #194 §2 says
-- so out loud: "that machinery is the template". A player was run over when
--
--   * they lost health between two of the roster's own 4 Hz samples, and
--   * they were ON FOOT, and
--   * a vehicle a PLAYER was driving was within roadkillRadiusM of them and
--     moving faster than roadkillMinSpeedMs.
--
-- Every one of those is read on the server. Positions come from
-- roster.positions, which reads GetEntityCoords itself and never asks a client;
-- health is the same sample the storm and the fire ledger already run off; and
-- the driver is confirmed by asking the VEHICLE who is in its driving seat.
-- Nothing in the chain can be asserted by a client, which is the property
-- BR.Damage's fire ledger has and the reason it was copied.
--
-- ═══ WHY THE DRIVER IS CONFIRMED FROM THE SEAT AND NOT FROM THE PED ═══
--
-- `GetVehiclePedIsIn(ped, false)` is answerable server-side under OneSync and is
-- the obvious call. It also has a live platform bug -- citizenfx/fivem#4006,
-- "[Server] GetVehiclePedIsIn(ped, false) returns last vehicle when ped is not
-- in any vehicle", reported fixed only as of build 3326 -- so on the build this
-- project pins it answers a handle for a player who got out of a car ten minutes
-- ago and has been walking ever since. Taken alone it would make half the map
-- into drivers. The documented workaround is to gate it on
-- `IsPedInAnyVehicle`, and that native does not exist on the server at all.
--
-- So the ped's answer is treated as a CANDIDATE and the vehicle settles it:
-- GetPedInVehicleSeat(veh, -1) is a live read of who is in that vehicle's
-- driving seat right now, and a ped that left the car is not in it. That is
-- also exactly the question the owner asked -- "see if the vehicle is driven by
-- a player" -- so the confirmation is not defensive plumbing bolted onto the
-- rule, it IS the rule.
--
-- ═══ WHAT THIS DOES NOT CLAIM ═══
--
-- An ambient maniac driver (client/gamerules.lua's erratic peds, ability 0.0,
-- aggression 1.0) killing a player is still nobody's kill, and #194 says that is
-- correct: there is no player in the seat. So is a car that explodes with people
-- in it -- the owner's answer to question 2 was "that's fine... It could be even
-- the driver driving off a cliff." Neither of those is a gap this file is
-- failing to close; both are the answer.
--
-- A PASSENGER whose car crashes beside another player's moving car can be
-- credited to that other driver. The guard below excludes a victim who is
-- DRIVING, because a driver who hits a wall is the crash rather than the
-- roadkill; excluding passengers too would mean enumerating every seat of every
-- vehicle every sample, which is a real cost for a case that needs two cars
-- abreast at speed and one of them dying to something else. Stated rather than
-- hidden.

--- The vehicle each player is confirmed to be DRIVING, rebuilt every sample.
---
--- [src] = vehicle handle. Absent means "not driving", which covers a passenger,
--- a player on foot, and a player whose ped the server could not resolve.
---
--- REBUILT RATHER THAN MAINTAINED, because the events that would maintain it are
--- client-side (`CEventNetworkPlayerEnteredVehicle` and friends are client
--- natives) and a map kept by anything a client sends is a map a client owns.
local driving = {}

--- Position and speed history, per player.
---
--- [src] = { x, y, z, at, license, speed }
---
--- CARRIES THE LICENCE, AND THAT IS NOT DECORATION. FiveM recycles server ids
--- within the minute, so the row left behind by a disconnecting driver would be
--- read as the previous position of whoever lands in that slot next -- and the
--- displacement between two different humans standing in two different places is
--- an enormous speed, arriving at the exact moment a fresh player is least able
--- to have earned a kill. The `playerDropped` handler below already clears the
--- row; the licence is what covers the case where it did not run, and it fails
--- CLOSED -- an unrecognised licence means no speed this sample, so no credit.
local track = {}

--- Read a native that answers an entity handle, defensively.
---
--- pcall'd FOR server/vehicles.lua's OWN REASON, stated above `vehicleType`: the
--- platform builds these with `makeEntityFunction`, which RAISES on a handle that
--- has gone stale rather than answering zero, and a ped handle sampled up to
--- 250 ms ago is exactly the handle that goes stale. An uncaught throw inside a
--- scheduler job costs five of them before BR.Sched suspends the job entirely.
---
--- ZERO IS THE ANSWER FOR "NOTHING", AND IN LUA THAT IS TRUTHY. Every caller
--- below compares against 0 explicitly for the reason `ownerOf` gives: `if veh
--- then` is true for a vehicle that is not there.
--- @param fn function|nil
--- @param ... any
--- @return integer  0 when the native is absent, threw, or answered nothing
local function entityFrom(fn, ...)
    if not fn then return 0 end
    local ok, v = pcall(fn, ...)
    if not ok then return 0 end
    local n = math.tointeger(tonumber(v))
    if n == nil or n < 0 then return 0 end
    return n
end

--- Is this player driving something, and what?
---
--- TWO NATIVES, AND THE SECOND ONE IS THE ANSWER. See the section header for
--- citizenfx/fivem#4006: the first native's answer is a claim about the past on
--- the build this project pins, and the second is a live read that refutes it.
--- @param entry table  a roster entry, for the ped roster.positions sampled
--- @return integer|nil vehicle handle
local function drivenVehicle(entry)
    local ped = math.tointeger(tonumber(entry and entry.ped)) or 0
    if ped == 0 then return nil end

    local veh = entityFrom(GetVehiclePedIsIn, ped, false)
    if veh == 0 then return nil end

    -- SEAT -1 IS THE DRIVING SEAT. A passenger answers the same vehicle from the
    -- native above and fails here, which is what makes this the driver test
    -- rather than an occupancy test.
    if entityFrom(GetPedInVehicleSeat, veh, -1) ~= ped then return nil end
    return veh
end

--- How fast this player was moving at the last sample, in m/s, or nil.
--- @param src integer
--- @return number|nil
local function speedOf(src)
    local t = track[src]
    return t and t.speed or nil
end

--- Take one position sample for a player and fold it into their speed.
---
--- FROM OUR OWN TWO SAMPLES RATHER THAN FROM GetEntitySpeed, and the reason is
--- the same one roster.positions gives for reading coordinates itself: the
--- number that decides a kill should come from the thing this server already
--- treats as truth. It also means the speed and the position the radius is
--- measured against are the SAME pair of samples, so they cannot disagree.
--- @param src integer
--- @param entry table
--- @param now integer
local function sampleSpeed(src, entry, now)
    local p = entry.pos
    if not p then track[src] = nil return end

    local license = BR.Roster.licenseOf and BR.Roster.licenseOf(src) or nil
    local t = track[src]

    -- A DIFFERENT HUMAN IN THE SAME SLOT HAS NO HISTORY. nil is treated as
    -- "cannot prove it is the same person" rather than as a licence that matches
    -- itself, which is the direction that refuses a kill rather than inventing
    -- one.
    if t and (license == nil or t.license ~= license) then t = nil end

    local speed = nil
    if t and now > t.at then
        speed = BR.Dist3(p.x, p.y, p.z, t.x, t.y, t.z) / ((now - t.at) / 1000.0)
    end

    track[src] = { x = p.x, y = p.y, z = p.z, at = now,
                   license = license, speed = speed }
end

--- How far above or below a driver may be and still have hit this player.
---
--- A CAR ON THE BRIDGE OVERHEAD IS NOT RUNNING YOU OVER. The horizontal radius is
--- generous because the sample lags the collision (see roadkillRadiusM); the
--- vertical one cannot be, because Los Santos stacks roads. Four metres is a
--- storey and change -- enough for a truck cab above a prone ped and a ramp, and
--- short of the freeway above the street. The fire ledger makes the same split
--- for the same reason.
local ROADKILL_Z_M = 4.0

--- Which player's vehicle just ran this player over, if the server can see one.
---
--- PURE, AND IT READS NO NATIVES. Everything it needs was sampled by the job
--- below: who is driving, how fast they were going, and where everybody is. That
--- is what makes it testable, and it is also what keeps the cost of an
--- unattributed death at zero natives.
--- @param src integer
--- @param e table   the victim's roster entry
--- @return integer|nil driver src
function BR.Vehicles.roadkillDriverFor(src, e)
    if not e or not e.pos or e.matchId == nil then return nil end

    -- THE VICTIM IS ON FOOT, OR THIS IS A CRASH RATHER THAN A ROADKILL. Without
    -- it, two players racing side by side hand each other a kill every time one
    -- of them hits a wall.
    if driving[src] then return nil end

    stat.roadkillLooks = stat.roadkillLooks + 1

    local r        = cfg.roadkillRadiusM or 8.0
    local r2       = r * r
    local minSpeed = cfg.roadkillMinSpeedMs or 6.0

    local best, bestD2 = nil, nil
    BR.Roster.each(
        function(o) return o.src ~= src
                        and o.matchId == e.matchId
                        and o.state == BR.PlayerState.ALIVE end,
        function(osrc, o)
            if not o.pos or not driving[osrc] then return end

            local sp = speedOf(osrc)
            if sp == nil or sp < minSpeed then return end

            local dx, dy = o.pos.x - e.pos.x, o.pos.y - e.pos.y
            local d2 = dx * dx + dy * dy
            if d2 > r2 then return end
            if math.abs(o.pos.z - e.pos.z) > ROADKILL_Z_M then return end

            -- NEAREST WINS. Two cars in a pile-up is a real thing and somebody
            -- has to own it; the one on top of the body is the better claim than
            -- the one eight metres away.
            if best == nil or d2 < bestD2 then best, bestD2 = osrc, d2 end
        end)

    return best
end

--- Record a roadkill against this player, if the server can see one.
---
--- WRITES THE SAME THREE FIELDS THE VALIDATED DAMAGE PATH WRITES, so nothing
--- downstream needs to learn about vehicles: BR.Combat.attributedKiller reads
--- `lastHitBy` and the assist window, the kill feed reads `lastHitWeapon`, and a
--- player who is run over and then finished by a rifle credits the rifle exactly
--- as they would if the car had been a molotov.
---
--- `lastRoadkillAt` IS THE FOURTH AND IT IS THE CAUSE RATHER THAN THE CREDIT. It
--- does not expire with the assist window -- server/combat.lua reads it against
--- roadkillCauseMs to decide whether the feed says "roadkill", which is a
--- different question from who gets the elimination.
--- @param src integer
--- @return boolean  true when a driver was credited
function BR.Vehicles.creditRoadkill(src)
    local e = BR.Roster and BR.Roster.get and BR.Roster.get(src)
    if not e then return false end

    local driver = BR.Vehicles.roadkillDriverFor(src, e)
    if not driver then return false end

    local now = GetGameTimer()
    e.lastHitBy      = driver
    e.lastHitAt      = now
    -- AN ITEM-SHAPED STRING, exactly as the fire ledger writes 'molotov'. The
    -- kill feed's own CAUSE_PHRASE table already knows this word, so it renders
    -- the plain arrow rather than hunting for a weapon icon that does not exist.
    e.lastHitWeapon  = 'roadkill'
    e.lastRoadkillAt = now
    stat.roadkills   = stat.roadkills + 1
    return true
end

--- Was this player run over recently enough for the feed to say so?
--- @param e table|nil
--- @return boolean
function BR.Vehicles.roadkillRecent(e)
    if not e or not e.lastRoadkillAt then return false end
    return (GetGameTimer() - e.lastRoadkillAt) < (cfg.roadkillCauseMs or 3000)
end

--- Sample who is driving, how fast, and who just lost health because of it.
---
--- AT THE ROSTER'S OWN RATE, READ FROM THE ROSTER'S OWN SETTING, so the two
--- cannot drift: this job's whole input is the sample roster.positions took, and
--- running at a different cadence would mean either measuring speed over a stale
--- pair or measuring it twice over the same one. It is registered AFTER
--- roster.positions (see the fxmanifest order), and BR.Sched runs jobs in
--- registration order, so within one step the positions are already fresh.
BR.Sched.every(BR.Roster.sampleIntervalMs(), 'vehicles.roadkill', function()
    local now = GetGameTimer()

    driving = {}
    local live = 0

    BR.Roster.each(
        function(e) return e.state == BR.PlayerState.ALIVE and e.matchId ~= nil end,
        function(src, e)
            sampleSpeed(src, e, now)
            local veh = drivenVehicle(e)
            if veh then
                driving[src] = veh
                live = live + 1
            end
        end)

    stat.driving = live

    -- ONLY PLAYERS ACTUALLY LOSING HEALTH ARE ATTRIBUTED, which is the fire
    -- ledger's guard and it is load-bearing for the same reason: without it,
    -- driving past a squadmate would own their storm death twenty seconds later.
    BR.Roster.each(
        function(e) return e.state == BR.PlayerState.ALIVE and e.matchId ~= nil end,
        function(src, e)
            local hp  = (e.hp or 100.0) + (e.armour or 0.0)
            local was = e.roadHp
            e.roadHp  = hp
            if was == nil or hp >= was then return end
            BR.Vehicles.creditRoadkill(src)
        end)
end)

--- Forget a player's refused-vehicle history.
---
--- SERVER IDS ARE RECYCLED WITHIN THE MINUTE, so a record left behind would be
--- inherited by whoever lands in that slot next -- and inheriting a count is
--- inheriting somebody else's case. The same reason server/strip.lua and
--- server/damage.lua clear theirs here.
---
--- The roadkill tables go with it, and the stakes there are the same shape: a
--- position sample left behind is read as the previous position of the NEXT
--- person to hold that id, and the displacement between two humans is a speed no
--- car can reach.
AddEventHandler('playerDropped', function()
    local src = source
    if not src then return end
    seenBy[src] = nil
    track[src]  = nil
    driving[src] = nil
end)

AddEventHandler('onResourceStart', function(name)
    if name == GetCurrentResourceName() then
        seenBy = {}
        seenModels, seenModelCount = {}, 0
        track, driving = {}, {}
    end
end)
