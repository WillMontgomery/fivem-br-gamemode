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
-- they are server setters.) If a vehicle is ever spawned with server-side
-- `CreateVehicle` and its model is one config/vehicles.lua refuses, this file
-- will open a case about whichever player the engine handed ownership to.
--
-- ═══ #191's AMBULANCE IS NETWORKED, AND IT REACHES THIS HANDLER ═══
--
-- This paragraph used to say the CPR ambulance was "meant to be local and
-- non-networked, so it should reach none of this". That expectation did not
-- survive the owner making it destructible (2026-08-23): other players can only
-- shoot a vehicle that exists on their machine, so the rescue ambulance is
-- created client-side with `isNetwork = true` and DOES arrive here up the clone
-- path, owned by the player being rescued.
--
-- NOTHING WAS EXEMPTED, AND NOTHING NEEDED TO BE. This handler files only on a
-- REFUSED model, and an ambulance is not on that list -- which is what the old
-- paragraph already said, for a different reason. It is counted like any other
-- client-created vehicle and opens no case. A rescue HELICOPTER would need the
-- exemption, and BR.Config.VehicleRefusalFor is still the one place to put it.
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

--- How long the driving seat of a refused vehicle must be HELD before it counts.
---
--- #211's NUMBER, AND IT LIVES UP HERE BESIDE THE THROTTLE FOR TWO REASONS: the
--- two bound the same detector from opposite ends -- one says how fast a finding
--- may repeat, the other how long one takes to become a finding at all -- and
--- BR.Vehicles.stats() below reports it, so it has to be in scope before that
--- function is compiled. The section that uses it is much further down, under
--- "taking one that was already there".
---
--- THREE SECONDS, AND THE NUMBER IS CHOSEN AGAINST THE FALSE POSITIVES RATHER
--- THAN AGAINST THE OFFENCE. At the roster's 4 Hz that is twelve consecutive
--- samples, all naming the same vehicle handle for the same licence.
---
--- What it is sized to reject: a seat read taken during an ejection or a
--- ragdoll (one or two samples), a player who gets in and straight back out,
--- and any single sample the engine answered oddly. What it is sized to admit:
--- somebody who is actually flying, which is the only way to hold a cockpit for
--- three seconds.
---
--- IT IS DELIBERATELY NOT LONGER. The dwell is a noise floor, not a grace
--- period -- an offender is not being given time to reconsider, because they
--- are never told and nothing stops them. Every second added is a second of a
--- stolen Buzzard that files nothing.
local OCCUPY_DWELL_MS = 3000

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
    -- #211's counters. `occupied` is the finding; `dwelling` is how many
    -- players are sitting out a dwell right now, which is the number that says
    -- the sampler is watching rather than that it has decided.
    occupied = 0, dwelling = 0,
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
        -- #211: the same finding reached by sitting in one rather than by
        -- conjuring one. Counted separately and filed identically.
        --
        -- THE DWELL TRAVELS WITH THEM so `brvehicles` prints the rule rather
        -- than a second copy of the number -- the readout that says "0 occupied"
        -- is only readable next to how long somebody has to sit there.
        occupied  = stat.occupied,  dwelling  = stat.dwelling,
        dwellMs   = OCCUPY_DWELL_MS,
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

--- This entity's model hash, or nil when the handle would not answer.
---
--- pcall'd FOR `vehicleType`'s REASON, and NOT through `entityFrom` below --
--- that helper floors negatives to 0, and A MODEL HASH IS LEGITIMATELY
--- NEGATIVE. GetHashKey answers a SIGNED 32-bit integer, so every hash with the
--- top bit set arrives here below zero; running one through `entityFrom` would
--- turn `buzzard` into 0, and 0 is in no row of the refused table. That is a
--- refusal silently becoming permission, which is the single failure this file
--- is least able to notice.
---
--- nil IS THE SAFE ANSWER and BR.Config.IsAllowedVehicle takes it as "allowed".
--- Same polarity that function documents: a model the engine could not report
--- files nothing, rather than opening a case every time a handle goes bad.
--- @param entity integer
--- @return integer|nil
local function modelOf(entity)
    if not GetEntityModel then return nil end
    local ok, m = pcall(GetEntityModel, entity)
    if not ok then return nil end
    return math.tointeger(tonumber(m))
end

--- Does the gamemode refuse this vehicle, and on which half of the rule?
---
--- THE OWNER'S RULE IN ONE PLACE, ASKED BY BOTH DETECTORS. #193's sentence --
--- "allow every vehicle except anything that flies or has built-in weapons" --
--- is now reached down two routes: a client CREATING one (`entityCreating`,
--- below) and a player SITTING IN one that was already in the world (#211, the
--- sample pass further down). They must answer identically or the same Buzzard
--- is two different rulings depending on how somebody got into it.
---
--- BOTH SIGNALS, IN THE ORDER THE CREATION PATH ESTABLISHED. The model table
--- first, because it is one hash lookup and it distinguishes "flies" from
--- "armed" -- a distinction the engine's class cannot make. `GetVehicleType`
--- only when the table said yes, as the backstop against config/vehicles.lua
--- rotting into uniform permission: it is a DENY-list, so an aircraft nobody
--- wrote down is allowed by construction, forever, silently.
---
--- ═══ THE RULING MOVED TO br_lib AND THIS IS NOW A NATIVE-READING SHELL ═══
---
--- #215 put a THIRD asker in the tree -- br_core/client/vehrefuse.lua, which
--- ejects a player rather than filing a case. The sentence in the occupancy
--- header below ("the question is asked in exactly one place for both
--- detectors") only survives a third caller if the three of them share the
--- ruling, so the ordering and the reasons live in
--- BR.Config.VehicleRefusalFor and this function supplies the signals it can
--- read. The behaviour is unchanged, term for term.
---
--- NO `classOf` IS PASSED, AND THAT IS NOT AN OVERSIGHT. `GetVehicleClass` --
--- the 0-22 enum -- is CLIENT-ONLY; there is no server handler for it. The
--- server's two signals are exactly what they were. The client's third is why
--- the armed half of the owner's rule finally has a net under it, and it can
--- only ever hold on the client, which is advisory. See that file's header.
---
--- @param entity integer
--- @return string|nil why    a BR.Config.VehicleRefusal value; nil when allowed
--- @return integer|nil model  the hash, for the caller's payload and log line
local function refusalFor(entity)
    local model = modelOf(entity)

    -- A FUNCTION, NOT `vehicleType(entity)` EVALUATED HERE. The native is only
    -- read when the model table has already said "allowed", which is the case
    -- for every ordinary car -- and `entityCreating` sees one of those per
    -- spawn under a flood. Passing the value would pay for the pcall'd native
    -- unconditionally and lose the ordering this comment is about.
    local why, signal = BR.Config.VehicleRefusalFor(model, {
        typeOf = function() return vehicleType(entity) end,
    })

    -- COUNTED FROM WHICHEVER ROUTE FOUND IT. The number means "the model table
    -- missed an aircraft that is in this game build", which is a fact about
    -- config/vehicles.lua rather than about how the vehicle was reached.
    if signal == 'type' then stat.byType = stat.byType + 1 end

    return why, model
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
-- Counting one, and handing it over
-- ---------------------------------------------------------------------------

--- Record one refused vehicle against a player, and announce it if it is the
--- second or later this match.
---
--- THE ONE ROUTE OUT OF THIS FILE, AND #211 IS WHY IT IS A FUNCTION. There are
--- now two ways to reach the owner's rule -- a client creating a refused
--- vehicle, and a player taking one that was already in the world -- and they
--- must produce the SAME case rather than two cases with two shapes. Everything
--- that decides what a finding is worth lives here and is therefore shared: the
--- per-match record, the flood throttle, the bar of two, the corroboration
--- sequence, and the single `br:core:vehicle` handover.
---
--- IT IS ALSO THE SEAM ANY LATER DETECTOR SHOULD USE. server/incident.lua turns
--- `br:core:vehicle` into a case or a corroboration and knows nothing about who
--- raised it; anything downstream that hangs off a case being filed -- the
--- match-wide notice among them -- therefore picks up a new route here for
--- free, with nothing to call and nothing to register.
---
--- ONE COUNTER FOR BOTH ROUTES, DELIBERATELY. A player who spawns a jet and
--- then steals a Buzzard has done the same thing twice, so it is one case with
--- a count of two rather than two cases of one -- which is the "one player, one
--- round, one record" rule server/incident.lua already states.
---
--- NOBODY IS EXEMPT, and the absence of an admin check here is deliberate and
--- inherited. server/strip.lua shipped one for a single commit and the owner
--- removed it the same day -- "I don't want admins to be exempt from any
--- incidents please" -- on the reasoning that an exemption is a hole in an
--- anticheat shaped exactly like the accounts with the most power. It would be
--- a worse idea here than there: spawning a vehicle through a trainer is
--- precisely what an admin testing with vMenu does, so the exemption would
--- silence this path for the only group that can reach it easily.
---
--- @param src integer
--- @param e table      the player's roster entry; caller has checked LIVE
--- @param why string   a BR.Config.VehicleRefusal value
--- @param model integer|nil  the model hash, for the log line and the payload
--- @return boolean  true when this one was counted (as opposed to throttled)
local function fileRefusal(src, e, why, model)
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
        return false
    end

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
    -- that. The occupancy route's doubt is a different one -- a seat read taken
    -- while somebody was being thrown out of a cockpit -- and the dwell rule
    -- there answers it, but the bar is kept at two for both so that one case
    -- cannot be opened on a lower standard than the other.
    if rec.count < 2 then return true end
    rec.reports = rec.reports + 1

    local name = e.name or ('src ' .. src)
    print(('[br_core] ANTICHEAT: %s (%d) -- %d refused vehicle(s) this match (%s)')
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
    return true
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
    -- lookup later. Both signals live in `refusalFor` because #211's occupancy
    -- pass asks the identical question of a vehicle nobody created.
    --
    -- GetEntityModel IS READABLE HERE, and that is a property of where in the
    -- platform's clone path this event sits rather than an assumption: the
    -- create packet's sync tree is fully parsed before `entityCreating` is
    -- raised. (It is reported unreliable in this event for PICKUPS and for peds
    -- and objects on RedM, which is why the type gate above narrows to vehicles
    -- before this line rather than after it.)
    local why, model = refusalFor(entity)

    if why == nil then
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

    fileRefusal(src, e, why, model)
end)

-- ---------------------------------------------------------------------------
-- The second detector: taking one that was already there (#211)
-- ---------------------------------------------------------------------------
--
-- THE OWNER, 2026-08-22:
--
--   "I did go to fort zancudo and steal a helicopter, but for whatever reason
--    that didn't create an incident."
--
-- THEY WERE RIGHT, AND IT WAS A HOLE RATHER THAN A BUG. `entityCreating` sees a
-- vehicle a CLIENT CREATES and nothing else -- the header above says so as a
-- property worth having, and it is, right up until the refused vehicle is one
-- the engine put in the world before anybody logged in. A Zancudo Buzzard was
-- created by nobody. Under `sv_entityLockdown relaxed` that population is large
-- and permanent: the airbase's aircraft, the hospital helipads, every parked
-- car. Flying a stock Buzzard is EXACTLY the behaviour #193's rule exists to
-- catch, and until this section it was invisible.
--
-- ═══ THE RULE IS UNCHANGED; ONLY THE QUESTION IS NEW ═══
--
-- `refusalFor` is the same function `entityCreating` asks, so the same Buzzard
-- is the same ruling whether it was conjured or found. And the finding leaves
-- by the same door: `fileRefusal` above, which owns the throttle, the bar of
-- two, the corroboration sequence and the single `br:core:vehicle` handover. No
-- second counter, no second event, no second shape of case.
--
-- ═══ DRIVER ONLY, AND NOT ANY SEAT ═══
--
-- The owner's rule is about TAKING a refused vehicle, and a passenger did not
-- take it. Four reasons, in the order they carry weight:
--
--   * A PASSENGER CAN BE PUT THERE BY SOMEBODY ELSE. A squadmate lands a
--     Buzzard and you climb in; you are now a participant in somebody else's
--     offence. A driver cannot be made a driver by another player, so the
--     driving seat is the only one whose occupant chose it.
--   * THE SEAT IS ALREADY READ, AND THE OTHERS ARE NOT. `drivenVehicle` runs
--     once per ALIVE player per sample for the roadkill ledger. Enumerating
--     every passenger seat means GetPedInVehicleSeat for every index of every
--     vehicle every sample -- the exact cost the roadkill section above weighed
--     and declined for the same reason.
--   * IT IS THE HALF THE OWNER DESCRIBED. "I did go to fort zancudo and steal a
--     helicopter" is a driver.
--   * IT DOES NOT PAINT INTO A CORNER. Widening to passengers later is a loop
--     around one native inside `occupantRefusal`; nothing else would move.
--
-- ═══ HOW OCCUPANCY IS OBSERVED, AND WHY NOT THE OBVIOUS WAY ═══
--
-- Through `drivenVehicle`, unchanged, for the reason the roadkill section
-- already establishes at length: server-side `GetVehiclePedIsIn(ped, false)`
-- answers the vehicle a ped was LAST in -- citizenfx/fivem#4006, which is still
-- OPEN with no fix (checked 2026-08-22; the claim that build 3326 fixed it was
-- wrong, and the one PR touching it is unmerged and RedM-specific) -- so it
-- names a helicopter for a player who climbed out of one ten minutes ago and
-- has been walking ever since. Taken alone it would file a case against half
-- the map. So the ped's answer is a CANDIDATE and the vehicle settles it:
-- `GetPedInVehicleSeat(veh, -1)` is a live read of who is in that vehicle's
-- driving seat right now, and a ped that left is not in it.
--
-- THAT IS ALSO WHY THIS DETECTOR CANNOT BE WRITTEN OFF THE FUEL LEDGER OR THE
-- ROSTER'S ped FIELD. Both would inherit #4006; this reads the seat.
--
-- ═══ THE DWELL, WHICH IS WHAT STOPS IT FIRING ON NOTHING ═══
--
-- A single sample showing somebody in a cockpit is not somebody taking an
-- aircraft. It is also what a player being thrown out of one looks like, what a
-- ragdoll through a seat looks like, and what a mis-click looks like. So the
-- seat must be HELD: the same player, the same vehicle handle, continuously,
-- across samples spanning at least OCCUPY_DWELL_MS.
--
-- NOTHING IS COUNTED TWICE FOR ONE SITTING. A count is taken once per
-- occupancy, not once per sample -- otherwise a five-minute flight would file
-- twelve hundred corroborations. Getting out and getting back in is a fresh
-- occupancy and counts again, which is correct: it is a fresh act, and
-- MIN_INTERVAL_MS still bounds how fast anybody can repeat it.
--
-- ═══ NOTHING ON THIS SIDE TELLS ANYBODY ANYTHING, AND #215 DID NOT CHANGE THAT
--     ═══
--
-- The owner reversed the blocking decision on 2026-08-22 -- "detect the vehicle
-- they're trying to get in as they try, then reject the action client-side" --
-- and br_core/client/vehrefuse.lua is that rejection. IT IS A SEPARATE FILE ON
-- A SEPARATE MACHINE AND IT DOES NOT TALK TO THIS ONE.
--
-- SO THIS DETECTOR IS UNCHANGED AND MUST STAY UNCHANGED. Nothing here removes
-- anybody from a seat, warns them, or changes what they can do; nothing here
-- learns whether the client ejected them. That is #93's rule -- an offender who
-- learns they are under suspicion changes behaviour, and the case loses the
-- evidence it was going to be made of -- and it is also the reason the client
-- layer is safe to have: the notification it shows is shown to EVERYONE who
-- touches a Buzzard, says the same words every time, and does not vary for a
-- player with two prior refusals. It discloses a game rule, not a case.
--
-- ═══ AND THE CLIENT LAYER IS WHY THIS ONE MATTERS MORE, NOT LESS ═══
--
-- A client file is advisory. A modified client does not run it. Everything that
-- gets through the ejection arrives here exactly as it did before, which is the
-- owner's own framing: "if they do manage through some hoops we should still get
-- incidents". The ONLY enforcement in this feature is on this side of the wire.
--
-- ═══ WHAT THIS DELIBERATELY DOES NOT DO ═══
--
-- IT BUILDS NONE OF #191's AMBULANCE MACHINERY, and it does not need to: the
-- question "is this model refused" is asked in exactly one place for all three
-- askers -- this detector, the creation detector, and #215's client-side
-- ejection -- so the day a rescue vehicle needs an exemption there is one
-- function to put it in and no second copy to find. That function is
-- BR.Config.VehicleRefusalFor. It stayed one place when the third caller
-- arrived, which is the only test that claim has ever had.
--
-- IT SAMPLES ALIVE PLAYERS IN A MATCH ONLY, which is narrower than the creation
-- detector's LIVE (alive OR warmup), and that is a stated limit rather than an
-- oversight. The pass below reuses the roadkill job's roster walk, whose filter
-- is ALIVE; widening that filter would change which players can be credited a
-- roadkill, which is a different feature's behaviour. A warmup player in a
-- refused aircraft is caught only if a client created it.

--- Who is sitting out a dwell, and in what.
---
--- [src] = { veh, since, license, why, filed }
---
--- CARRIES THE LICENCE FOR `track`'s REASON, and the stakes are the same: FiveM
--- recycles server ids within the minute, so a row left behind by a departing
--- pilot would be read as the dwell of whoever lands in that slot next -- and
--- they would inherit a case for a seat they never sat in. A licence that does
--- not match restarts the dwell, which is the direction that files nothing
--- rather than the direction that invents a finding.
---
--- `why` IS DECIDED ONCE, WHEN THE OCCUPANCY STARTS, and then reused. That is
--- cheaper -- one model read per sitting rather than one per sample -- and it
--- is also the more correct of the two: the ruling belongs to the vehicle they
--- got into, and re-asking every 250 ms only creates a way for the answer to
--- change underneath a dwell that is already running.
local seat = {}

--- Fold one sample of one driver into the occupancy ledger, and file if it is
--- time.
---
--- CALLED FROM INSIDE THE SAMPLE JOB'S EXISTING WALK, with the vehicle handle
--- `drivenVehicle` already resolved -- so an ordinary match, where every driver
--- is in an ordinary car, costs one model read per driver per SITTING and a
--- table lookup per sample.
--- @param src integer
--- @param e table            roster entry; the caller has filtered ALIVE + match
--- @param veh integer|nil    the vehicle this player is confirmed DRIVING
--- @param now integer
local function occupancySample(src, e, veh, now)
    -- NOT DRIVING ANYTHING ENDS THE OCCUPANCY. Walking, riding as a passenger,
    -- and a ped the server could not resolve all land here, and all three mean
    -- the same thing: whatever dwell was running is over and does not resume.
    if veh == nil then seat[src] = nil return end

    local license = BR.Roster.licenseOf and BR.Roster.licenseOf(src) or nil
    local rec = seat[src]

    -- A DIFFERENT VEHICLE, A DIFFERENT PERSON, OR NOTHING YET: start the clock.
    -- The licence is compared as well as the handle because a recycled server
    -- id would otherwise walk into a dwell somebody else started -- and nil is
    -- treated as "cannot prove it is the same person", which restarts.
    if rec == nil or rec.veh ~= veh
        or license == nil or rec.license ~= license then
        local why = refusalFor(veh)
        rec = { veh = veh, since = now, license = license, why = why,
                filed = false }
        seat[src] = rec
    end

    -- AN ORDINARY CAR, WHICH IS ALL OF THEM. Left here on the second line of
    -- the function for every driver in every match.
    if rec.why == nil then return end

    stat.dwelling = stat.dwelling + 1

    -- ONE COUNT PER SITTING. See the section header: without it a flight files
    -- a corroboration every 250 ms.
    if rec.filed then return end
    if now - rec.since < OCCUPY_DWELL_MS then return end

    rec.filed = true
    stat.occupied = stat.occupied + 1
    fileRefusal(src, e, rec.why, modelOf(veh))
end

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
-- in any vehicle", still OPEN with no fix (checked 2026-08-22) -- so on every
-- build it answers a handle for a player who got out of a car ten minutes
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
-- NOR IS A CRASH THAT HURTS A PASSENGER, AND THAT IS NEWER THAN THE REST OF
-- THIS SECTION. Two guards now stand between a crash and a kill feed entry: the
-- victim must not be DRIVING -- a driver who hits a wall is the crash rather
-- than the roadkill -- and the victim must not be riding in the CANDIDATE'S OWN
-- CAR, because a passenger sits a metre from their own driver at exactly their
-- own driver's speed and satisfies every other term by construction. #213 made
-- vehicles genuinely breakable, which turned that from a curiosity into the
-- ordinary outcome of a squad car meeting a wall; the second guard is at
-- `ridesAsPassenger` below and carries the argument.
--
-- WHAT IS STILL CREDITED, STATED RATHER THAN HIDDEN: a passenger in car A who
-- dies while a DIFFERENT player's car B is alongside at speed is credited to
-- B's driver. That is the fire ledger's exposure exactly -- health went down and
-- a thing was on top of them -- and narrowing it further would need the server
-- to know what hurt them, which is the question it cannot ask.
--
-- AND A CAR AT SPEED PASSING A PLAYER WHO IS BURNING OR IN THE STORM CAN TAKE
-- THE CREDIT FOR THAT SAMPLE. It is the fire ledger's exposure exactly -- the
-- test is "health went down and the thing was on top of them", and the server
-- cannot ask the engine which of two causes moved the number. A storm veto was
-- weighed and declined for two reasons: it would reopen the hole #194 is about
-- (a griefer with a car and the storm as an alibi), and the storm's own ledger
-- kill already passes `nil` for the killer outright -- server/storm.lua's
-- `defeat(src, 'storm', nil)` -- so the ordinary storm death cannot be stolen at
-- all. What is left is a death the storm ledger did not get to first, which is
-- the case where a car really might have been the thing that finished them.

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

--- How many passenger seats are walked when asking whether somebody is riding
--- in a car somebody else is driving.
---
--- Seats 0..7, so this covers an eight-passenger vehicle. Every car, van and
--- pickup in the game is inside it; a bus is not, and somebody riding in the
--- back of one is described at `ridesAsPassenger` below.
local CABIN_SEATS = 8

--- Is this ped riding as a PASSENGER of this vehicle?
---
--- ═══ THE VEHICLE IS ASKED, NOT THE PED, AND THAT IS citizenfx/fivem#4006
---     AGAIN ═══
---
--- `drivenVehicle` above already explains it for the driver: server-side
--- `GetVehiclePedIsIn(ped, false)` answers the vehicle a ped was LAST in when it
--- is in none, and `IsPedInAnyVehicle` -- the documented workaround -- does not
--- exist on the server at all. So the ped's answer is a claim about the past and
--- `GetPedInVehicleSeat` is the live read that settles it.
---
--- THE SAME TRICK, MOVED FROM THE DRIVING SEAT TO THE PASSENGER SEATS, because
--- the question here is not "who is driving" but "is this person riding with the
--- driver", and a passenger answers no to the first and yes to the second.
---
--- ═══ SEAT -1 IS DELIBERATELY NOT WALKED, AND MUTATION TESTING IS WHY IT SAYS
---     SO ═══
---
--- A first draft checked the driving seat too, on the reasoning that "is this
--- ped in this vehicle" should mean any seat. It is UNREACHABLE from the only
--- caller and a mutant that deleted it changed nothing: the caller has already
--- established that seat -1 of this vehicle holds the CANDIDATE'S ped
--- (`drivenVehicle` is what put the vehicle in `driving`), and the candidate is
--- never the victim -- BR.Roster.each is filtered on `o.src ~= src`. So the
--- branch could not answer true, and a check that cannot fire is a check the
--- next reader has to work out the emptiness of. The name says passenger now,
--- which is what it actually asks.
---
--- WHAT IT MISSES: a ped in seat 8 or beyond -- the back of a bus or a coach.
--- They would still be creditable as a roadkill to their own driver, which is
--- the bug this exists to stop, for the handful of vehicles in the game big
--- enough to have that seat. Stated rather than papered over with a seat count
--- nobody can justify; enumerating every seat of every candidate every sample is
--- a real cost for a case that needs a coach.
--- @param veh integer
--- @param ped integer
--- @return boolean
local function ridesAsPassenger(veh, ped)
    if veh == 0 or ped == 0 then return false end
    for s = 0, CABIN_SEATS - 1 do
        if entityFrom(GetPedInVehicleSeat, veh, s) == ped then return true end
    end
    return false
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

    -- ═══ ...AND NEITHER IS A PASSENGER IN THE CAR THAT CRASHED (#194, #213) ═══
    --
    -- The guard above only excludes the victim who was DRIVING, and the rule
    -- this file implements is wider than that: config/match.lua states it as "a
    -- player lost health, THEY WERE ON FOOT, and a vehicle a PLAYER was driving
    -- was on top of them and moving". A passenger is not on foot.
    --
    -- IT WAS A GAP BETWEEN THE PROSE AND THE CODE, AND #213 IS WHAT MAKES IT
    -- BITE. A passenger sits about a metre from their own driver, in a vehicle
    -- moving at exactly the vehicle's speed -- so every term below is satisfied
    -- by the person at the wheel of the car they are sitting in. Any crash that
    -- hurts a passenger has therefore always been creditable to their own
    -- driver, as a "roadkill", in the feed. It was rare only because a car
    -- crashing hard enough to hurt anybody was rare.
    --
    -- #213 makes vehicles genuinely destructible, which makes it ORDINARY: a
    -- squad car that hits a wall would hand the driver an elimination for each
    -- of their passengers. The owner settled the shape of this on #194 -- "It's
    -- by design that vehicles in the game can explode under normal
    -- circumstances, without a killer necessarily" -- so a crash stays
    -- uncredited, and raising the damage rates must not quietly turn crashes
    -- into kills.
    --
    -- ═══ AND IT ASKS THE VEHICLE, NEVER THE PED ═══
    --
    -- The obvious spelling is "does GetVehiclePedIsIn(victim) name the same car
    -- the candidate is driving", and it is wrong twice over. It is #4006 again
    -- -- the ped's answer is a claim about the PAST, so it names a car the
    -- victim left ten minutes ago and would refuse a genuine roadkill by
    -- somebody now driving it -- and MUTATION TESTING FOUND THE OTHER HALF: in
    -- the window where a player has moved between two cars, the ped's answer and
    -- the seat disagree in the other direction and the guard misses the very
    -- case it is for.
    --
    -- So the ped is not asked at all. `ridesAsPassenger` is a live read of the
    -- CANDIDATE'S OWN CAR, which is the same doctrine `drivenVehicle` states
    -- above for the driver, applied to the passenger seats.
    local victimPed = math.tointeger(tonumber(e.ped)) or 0

    local r        = cfg.roadkillRadiusM or 8.0
    local r2       = r * r
    local minSpeed = cfg.roadkillMinSpeedMs or 6.0

    local best, bestD2 = nil, nil
    BR.Roster.each(
        function(o) return o.src ~= src
                        and o.matchId == e.matchId
                        and o.state == BR.PlayerState.ALIVE end,
        function(osrc, o)
            if not o.pos then return end
            local veh = driving[osrc]
            if not veh then return end

            local sp = speedOf(osrc)
            if sp == nil or sp < minSpeed then return end

            local dx, dy = o.pos.x - e.pos.x, o.pos.y - e.pos.y
            local d2 = dx * dx + dy * dy
            if d2 > r2 then return end
            if math.abs(o.pos.z - e.pos.z) > ROADKILL_Z_M then return end

            -- SAME CABIN, NO CREDIT -- see the block above `victimPed`.
            --
            -- ASKED LAST, AND THAT IS THE WHOLE OF ITS COST CONTROL. It is the
            -- only test in this callback that spends natives -- eight seat reads
            -- -- and every test above it is arithmetic on samples this server
            -- already took. Ordering it here means the seats are walked only for
            -- a driver who is ALREADY within eight metres of a dying player and
            -- moving, which is a handful of times a match rather than once per
            -- driver per sample.
            if ridesAsPassenger(veh, victimPed) then return end

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

    -- A GAUGE RATHER THAN A TALLY, like `driving` beside it: it is rebuilt from
    -- this sample, so it answers "how many people are sitting in something
    -- refused right now" rather than "how many ever were".
    stat.dwelling = 0

    BR.Roster.each(
        function(e) return e.state == BR.PlayerState.ALIVE and e.matchId ~= nil end,
        function(src, e)
            sampleSpeed(src, e, now)
            local veh = drivenVehicle(e)
            if veh then
                driving[src] = veh
                live = live + 1
            end
            -- #211, OFF THE SEAT READ THAT WAS ALREADY TAKEN. Passed the same
            -- handle the roadkill ledger just confirmed, so the refused-vehicle
            -- question costs no extra native on the ordinary path -- and nil
            -- (not driving) is a meaningful value here rather than a skip,
            -- because it is what ENDS an occupancy.
            occupancySample(src, e, veh, now)

            -- #191, OFF THE SAME SEAT READ AGAIN, and for a reason that has
            -- nothing to do with anti-cheat: a player getting into an ambulance
            -- is the ONLY moment this server can learn an ambient one exists.
            -- Ambient traffic is client-created population, invisible from here
            -- until somebody sits in it -- so this read is not the cheapest hook
            -- for the owner's "add it to our list of blips", it is the only one.
            --
            -- IT FORMS NO OPINION AND FILES NOTHING. Driving an ambulance is not
            -- an offence and this line is not part of the detector; it hands a
            -- handle to the gamemode and returns. Guarded on the function
            -- existing because this file must keep loading without br_core's
            -- rescue half, which tools/test_vehicles fixtures rely on.
            if veh and BR.Rescue and BR.Rescue.noteVehicle then
                BR.Rescue.noteVehicle(src, e, veh)
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
    -- AND THE DWELL, for the same reason and with a sharper edge: a row left
    -- here is a part-served dwell in a stolen helicopter, and the next player to
    -- hold this id would finish it and take the case. The licence check inside
    -- occupancySample already refuses that; this is the cheaper half of the
    -- same guard, and neither is enough on its own.
    seat[src]   = nil
end)

AddEventHandler('onResourceStart', function(name)
    if name == GetCurrentResourceName() then
        seenBy = {}
        seenModels, seenModelCount = {}, 0
        track, driving = {}, {}
        seat = {}
    end
end)

-- ---------------------------------------------------------------------------
-- Putting one there on purpose
-- ---------------------------------------------------------------------------

--- The model `brcar` spawns when nobody names one. An ordinary four-seat SUV,
--- which is what a squad test wants and what the allowlist above is happy with.
local DEFAULT_MODEL = 'granger'

--- Build a gamemode-owned vehicle, in a player's routing bucket.
---
--- IT LIVES HERE BECAUSE tools/verify.sh SAYS IT MUST. The gate refuses any
--- server-side CreateVehicle/CreateVehicleServerSetter outside this file, and
--- the reason is written above brcar: the allowlist pre-check is the ONLY thing
--- standing between a refused model and a vehicle nothing would notice, because
--- the server setter raises `serverEntityCreated` and this resource listens to
--- no such event. Creation and the allowlist are reviewed on one screen or the
--- backstop is gone.
---
--- #191's ambulance was the second caller to need this, and it tried to make
--- its own on the CLIENT instead -- CreateVehicle(..., networked), which the
--- owner's 2026-08-28 run showed answering 0 while every call after it no-opped
--- against entity 0. This is the route that works, so it stops being a private
--- trick of one debug verb.
---
--- THE BUCKET IS NOT OPTIONAL. Matches run in their own (server/roster.lua) and
--- the setter defaults to bucket 0 -- a vehicle left there is one nobody in the
--- match can see, which is the same failure as not creating it at all.
---
--- @param model string|number
--- @param vtype string   automobile/bike/boat/heli/plane/submarine/trailer/train
--- @param x number @param y number @param z number @param heading number
--- @param forSrc number|nil  take this player's routing bucket
--- @return number|nil veh, number|nil netId, string|nil why
function BR.Vehicles.spawnOwned(model, vtype, x, y, z, heading, forSrc)
    local hash = type(model) == 'number' and model or GetHashKey(model)
    if BR.Config.IsAllowedVehicle and not BR.Config.IsAllowedVehicle(hash) then
        return nil, nil, 'the allowlist refuses that model'
    end

    -- The type argument THROWS on an unrecognised value rather than answering
    -- 0, which is why this is pcall'd rather than tested.
    local okCreate, raw = pcall(CreateVehicleServerSetter,
        hash, vtype or 'automobile', x, y, z, heading or 0.0)
    if not okCreate then return nil, nil, tostring(raw) end

    local veh = math.tointeger(tonumber(raw)) or 0
    -- `== true` rather than a truth test: DoesEntityExist is a BOOL native and
    -- may answer 1 or 0, and 0 is truthy in Lua.
    local okEx, exists = pcall(DoesEntityExist, veh)
    if veh == 0 or not okEx or not (exists == true or exists == 1) then
        return nil, nil, 'the engine refused it (handle 0)'
    end

    if forSrc then
        local okB, b = pcall(GetPlayerRoutingBucket, tostring(forSrc))
        local n = okB and math.tointeger(tonumber(b) or -1) or nil
        if n and n >= 0 then pcall(SetEntityRoutingBucket, veh, n) end
    end

    -- ═══ IT SAYS WHAT IT BUILT, BECAUSE THE CALLER CANNOT SEE ANY OF IT ═══
    --
    -- Owner, 2026-08-28: "net id 65534 never resolved to an ambulance here."
    -- The vehicle was created and the id was sent; nothing on either side could
    -- say WHICH of the four things between those two facts had gone wrong --
    -- the handle, the id, the bucket, or the clone never reaching the client.
    --
    -- Same lesson as /brcpr an hour earlier: six indistinguishable failures
    -- cost three rounds of reading source, and one line of output ended it.
    local netId = math.tointeger(tonumber(
        (select(2, pcall(NetworkGetNetworkIdFromEntity, veh))))) or -1
    local okB2, gotB = pcall(GetEntityRoutingBucket, veh)
    print(('[br_core] spawnOwned: handle %d  netId %d  bucket asked %s got %s')
        :format(veh, netId,
                tostring(forSrc and select(2, pcall(GetPlayerRoutingBucket,
                                                    tostring(forSrc)))),
                okB2 and tostring(gotB) or 'unreadable'))

    return veh, netId, nil
end
--- The eight sync trees `CreateVehicleServerSetter` knows how to build.
---
--- SPELLED OUT HERE SO A BAD ONE NEVER REACHES THE NATIVE, because the native
--- THROWS on an unrecognised type rather than answering 0 -- and a throw inside
--- this handler is precisely the failure #212 was. Case-sensitive on the
--- platform's side; the verb lowercases before it looks, so `Automobile` works
--- at the console and `automobile` is what is passed.
---
--- IT IS NOT CHECKED AGAINST THE MODEL by the platform: the type selects which
--- sync tree is built and nothing cross-references it against vehicles.meta. So
--- this list bounds what can be ASKED FOR, not what is correct.
local VEHICLE_TYPES = {
    'automobile', 'bike', 'boat', 'heli', 'plane',
    'submarine', 'trailer', 'train',
}
local VEHICLE_TYPE = {}
for _, t in ipairs(VEHICLE_TYPES) do VEHICLE_TYPE[t] = true end

--- What `brcar` builds when nobody names a type.
---
--- THE ONE THAT MATCHES DEFAULT_MODEL, and the one that matches almost every
--- model the allowlist tolerates. config/vehicles.lua refuses everything that
--- flies, so `heli` and `plane` are unreachable through this verb by
--- construction; `boat`, `bike` and the rest are reachable and have to be asked
--- for by name.
local DEFAULT_TYPE = 'automobile'

--- How far in front of the target player the vehicle lands, in metres.
---
--- FAR ENOUGH NOT TO LAND ON THEM. A vehicle created at a ped's own coordinates
--- leaves the engine to resolve the intersection, and it resolves it by throwing
--- one of the two.
local SPAWN_AHEAD_M = 5.0

--- PUT A VEHICLE IN THE WORLD WITHOUT A TRAINER. Console only, dev mode only.
---
---   brcar <serverId> [model]    spawn a vehicle in front of that player
---
--- ═══ WHY IT EXISTS: vMENU IS NOT BROKEN AND NEITHER ARE WE ═══
---
--- Owner, 2026-08-22 (#202): "Probably related to our hardening but I can no
--- longer spawn a vehicle through vMenu. We should have dev tooling to do this
--- otherwise if vMenu won't be an option."
---
--- IT IS `sv_entityLockdown relaxed`, AND IT IS THE PLATFORM RATHER THAN THIS
--- FILE. The engine's own ValidateEntity admits a client's clone-create only if
--- the sync tree reports one of the five RANDOM_* population types, or if the
--- entity's creation token carries a script guid. A trainer's vehicle is
--- POPTYPE_MISSION with no token, so it is refused and the clone deleted -- and
--- `entityCreating` is raised only AFTER that validation, so the handler at the
--- top of this file never sees it and `brvehicles` stays at zero. A refusal we
--- reported and a refusal the platform swallowed look completely different in
--- that readout, and vMenu's is the second one.
---
--- ═══ AND THE SAME VALIDATOR IS WHY THIS WORKS ═══
---
--- The creation-token branch is not gated on the lockdown mode. A server script
--- that asks for an entity gets a token with a script guid on it, and that is
--- what admits the clone when it comes back -- so this path works under
--- `relaxed`, and would go on working under `strict`. Nothing here reads the
--- convar and nothing here needs to.
---
--- ═══ WHY IT SHIPPED BROKEN, WHICH IS #212 AND IS THE WHOLE OF THE REWRITE ═══
---
--- Owner, 2026-08-22: "It seems brcar doesn't do anything."
---
--- THEY WERE RIGHT AND IT WAS THE SPAWN, NOT THE GATES. The verb used server-side
--- `CreateVehicle`, which is an RPC native -- `ext/natives/rpc_spec_natives.lua`
--- registers it with `entity_rpc 'CREATE_VEHICLE'` -- so the server asks a CLIENT
--- to make the entity and returns IMMEDIATELY, before any entity exists. What it
--- returns is not an entity handle. It is a `ScriptGuid::Type::TempEntity`, and
--- `ServerGameState::GetEntity` answers null for anything that is not
--- `Type::Entity`.
---
--- EVERY NATIVE THIS VERB CALLED NEXT IS BUILT WITH `makeEntityFunction`, WHICH
--- THROWS ON THAT NULL rather than answering: `SET_ENTITY_ROUTING_BUCKET`,
--- `NETWORK_GET_NETWORK_ID_FROM_ENTITY`, `GET_ENTITY_COORDS` and
--- `GET_ENTITY_MODEL` all raise "Tried to access invalid entity". So the very
--- next line after a successful create threw, the handler died there, and the
--- readout at the bottom -- the part that would have said what happened --
--- never ran. A verb that throws before it prints is a verb that does nothing.
---
--- AND IT WOULD NOT HAVE WORKED EVEN WITHOUT THE THROW. citizenfx/fivem#1407 is
--- titled "Serverside created vehicles spawn in the routing bucket of the last
--- serverside spawned vehicle, sometimes do not even spawn", and blattersturm
--- closed it with the rule this file now obeys: RPC creation is inherently
--- incompatible with routing buckets, so do not use it if you use any. THIS
--- GAMEMODE RUNS EVERY MATCH IN ONE. An RPC-created vehicle inherits the bucket
--- of whichever client the engine picked to build it, which is not the target's.
---
--- ═══ SO IT USES THE SERVER SETTER, AND THAT FIXES ALL OF IT AT ONCE ═══
---
--- `CreateVehicleServerSetter(model, type, x, y, z, heading)` builds the sync
--- tree on the server and registers the entity before it mints the handle, so
--- what comes back is a REAL entity: `SetEntityRoutingBucket` works on it
--- immediately, with no polling and no throw. It also needs no player in scope,
--- where the RPC returned 0 when the candidate list was empty.
---
--- THE TYPE IS THE SECOND ARGUMENT AND THAT IS EASY TO GET WRONG. It is one of
--- automobile/bike/boat/heli/plane/submarine/trailer/train, case-sensitive, and
--- an unrecognised value THROWS rather than answering 0 -- so it is taken as an
--- optional argument, defaulted, and the call is guarded like everything else
--- here. It selects which sync tree is built and is NOT validated against the
--- model, so a mismatch is the caller's to get right; the readout says which
--- one was used.
---
--- ═══ IT SPAWNS BESIDE A PLAYER, WHICH IS NOW A CHOICE RATHER THAN A LIMIT ═══
---
--- The server setter would happily spawn at bare coordinates on an empty map.
--- Naming a player is kept because it is what a squad test wants, and because
--- the player is where BOTH remaining inputs come from: a position to put the
--- car beside, and the ROUTING BUCKET to put it in. Matches run in their own
--- buckets (server/roster.lua) and the setter defaults to bucket 0, so a car
--- that is not moved into the target's bucket is a car nobody in a match can
--- see -- which is the other half of what "does nothing" looked like.
---
--- ═══ IT SPAWNS ONLY WHAT THE GAMEMODE ALREADY TOLERATES ═══
---
--- The model goes through BR.Config.IsAllowedVehicle FIRST, and a refused one is
--- refused HERE, before anything is created.
---
--- THAT PRE-CHECK IS NOW THE ONLY THING THERE IS, AND THE REWRITE IS WHY. The
--- old note here said a refused model would reach the detector at the top of
--- this file anyway, because an RPC create comes back up the client clone path
--- and raises `entityCreating`. That was true of the RPC and is NOT true of the
--- server setter: it raises `serverEntityCreated` and nothing else --
--- citizenfx/fivem#1737, closed not_planned, "it's not actually created from the
--- server" -- and nothing in this resource listens to that event.
---
--- SO THE BACKSTOP IS GONE AND THE PRE-CHECK IS LOAD-BEARING. Deleting it would
--- not merely permit a refused model, it would permit one that NOTHING would
--- notice: no case, no count, not a line in `brvehicles`. It stays first, it
--- stays before anything is created, and tools/verify.sh asserts the verb and
--- the allowlist stay in the same file so the two are reviewed on one screen.
---
--- NOBODY IS EXEMPT AND NOTHING IS EXCUSED. The verb cannot create the thing
--- that would file, so there is no exemption to grant. An allowed model is an
--- ordinary car. And a refused vehicle somebody DRIVES is caught by the
--- occupancy detector above regardless of how it got into the world -- including
--- one this verb had put there, if the pre-check were ever wrong.
---
--- If a refused model is genuinely wanted in a match, the change is a reviewed
--- row in config/vehicles.lua, not a back door in a debug verb.
---
--- ═══ WHAT HAPPENS TO IT AFTERWARDS ═══
---
---   * NOTHING DELETES IT AT MATCH END. Option A means this gamemode owns no
---     vehicles, so there is no vehicle teardown to add it to, and none is added
---     here. It is left on the platform's default orphan mode
---     (DeleteWhenNotRelevant), which collects it once no player has it in
---     scope -- the same death every ambient car dies.
---   * IT MAY VANISH ON ITS OWN, AND THAT IS A PLATFORM BUG WE HAVE NOT
---     REPRODUCED. citizenfx/fivem#2623, "Server side Vehicle created with
---     CreateVehicleServerSetter are randomly deleted", is OPEN: server-setter
---     entities sometimes receive `entityRemoved` for no reason the reporter
---     could pin down, apparently only with more than one player connected, and
---     with no repro after two years. It is filed as a slight inconvenience and
---     it is accepted here on those terms -- a dev car that occasionally
---     disappears is a far better trade than a verb that throws every single
---     time, which is what the RPC path did. NOT VERIFIED AGAINST OUR PINNED
---     BUILD: the report is against server b8823 and we pin game build 3095,
---     which are different numbers for different things. If a spawned car
---     evaporates, this is the first thing to read.
---   * THE FUEL LEDGER PICKS IT UP, BUT NOT AT SPAWN. #195 admits a vehicle from
---     its sample pass over players who are LIVE and in a match, keyed on the
---     vehicle the PED is in -- so an empty car is in no ledger at all, and the
---     moment somebody in a match sits in it, it is admitted with a full tank
---     exactly like a car found at the roadside.
RegisterCommand('brcar', function(src, args)
    -- CONSOLE ONLY, AND `RESTRICTED` IS NOT WHAT DOES THAT. Every verb in this
    -- family is registered restricted, which means the server console OR a live
    -- client holding the `br.admin` ACE. That is the right boundary for a
    -- readout and the wrong one for a vehicle: #202's rule is that this "must
    -- not become a route for anyone without console access to obtain a vehicle",
    -- and an admin holding br.admin does not have console access.
    --
    -- AN EQUALITY RATHER THAN A TRUTHINESS TEST, because 0 IS TRUTHY IN LUA and
    -- source 0 is the console -- `if src then` admits everybody and `if not src
    -- then` admits nobody. The same distinction ownerOf spells out above.
    if tonumber(src) ~= 0 then
        print('  brcar is server-console only (the br.admin ACE is not enough)')
        return
    end

    -- ...AND DEV MODE ON TOP OF IT, the same gate brgive and brarm carry, for
    -- the reason their note gives: one switch meaning "this box is not a real
    -- match", rather than a second thing to remember. Option A says the gamemode
    -- spawns no vehicles, and a car appearing out of nothing in a live round is
    -- the event that rule exists to prevent.
    if not BR.Server.devMode then
        print('  brcar is dev-mode only (br_devMode true)')
        return
    end

    local target = tonumber(args and args[1])
    local model  = tostring((args and args[2]) or DEFAULT_MODEL):lower()
    local vtype  = tostring((args and args[3]) or DEFAULT_TYPE):lower()
    if not target then
        print(('  usage: brcar <serverId> [model] [type]   defaults: %s, %s')
            :format(DEFAULT_MODEL, DEFAULT_TYPE))
        print('    Spawns in front of that player, in their routing bucket.')
        print('    Only models config/vehicles.lua tolerates -- brvehicles reads')
        print('    the other side of the same allowlist.')
        print(('    type is one of: %s'):format(table.concat(VEHICLE_TYPES, ', ')))
        return
    end

    -- THE TYPE IS CHECKED HERE BECAUSE THE NATIVE THROWS ON A BAD ONE rather
    -- than answering 0, and a throw is what #212 was. Checked against our own
    -- list rather than by catching the platform's error, so the message names
    -- the eight that work instead of quoting an exception.
    if not VEHICLE_TYPE[vtype] then
        print(('  %s is not a vehicle type the platform knows'):format(vtype))
        print(('  It must be one of: %s'):format(table.concat(VEHICLE_TYPES, ', ')))
        print('  It picks which sync tree the server builds, and it is NOT')
        print('  checked against the model -- so it has to match what the model')
        print('  actually is (vehicles.meta), not what you would like it to be.')
        return
    end

    local e = BR.Roster and BR.Roster.get and BR.Roster.get(target)
    if not e then
        print(('  no roster entry for %d'):format(target))
        return
    end

    -- THE PED, NOT THE PLAYER. The RPC needs a real position, and the roster's
    -- sampled ped is where the rest of this server reads one from.
    local ped = e.ped
    if not ped or ped == 0 then
        print(('  no ped for %d yet -- connected but not spawned, or OneSync is off')
            :format(target))
        return
    end

    local hash = GetHashKey(model)
    local allowed, why = BR.Config.IsAllowedVehicle(hash)
    if not allowed then
        print(('  REFUSED %s -- %s'):format(model, tostring(why)))
        print('  This gamemode opens a case about that model when a CLIENT puts')
        print('  one in a match, so the console does not get to put one there')
        print('  either. If the rule is wrong, change config/vehicles.lua.')
        return
    end

    if not CreateVehicleServerSetter then
        print('  CreateVehicleServerSetter is not available in this runtime.')
        print('  That native is what makes this verb work at all: server-side')
        print('  CreateVehicle is an RPC whose handle cannot be bucketed, and')
        print('  every match here runs in a routing bucket. See #212.')
        return
    end

    local p = GetEntityCoords(ped)
    if not p then
        print(('  no coordinates for %d'):format(target))
        return
    end

    -- IN FRONT OF THEM, TURNED ACROSS. GTA's heading is degrees clockwise from
    -- north, so the forward vector is (-sin, cos) -- and the vehicle is set a
    -- quarter turn off that, so what faces the player is a door.
    local heading = 0.0
    if GetEntityHeading then heading = tonumber(GetEntityHeading(ped)) or 0.0 end
    local rad = math.rad(heading)
    local x = p.x - math.sin(rad) * SPAWN_AHEAD_M
    local y = p.y + math.cos(rad) * SPAWN_AHEAD_M
    local z = p.z

    -- NORMALISED BEFORE IT IS TESTED, because this is a handle and the platform
    -- answers 0 for failure -- and 0 is truthy. `if veh then` reports a success
    -- that did not happen and then prints a netId for nothing.
    --
    -- GUARDED, BECAUSE A BAD TYPE THROWS. The check above should have caught
    -- every one of those, so reaching the failure branch here means the
    -- platform refused for a reason this verb does not know about -- which is
    -- exactly the case that has to print rather than disappear.
    local okCreate, raw = pcall(CreateVehicleServerSetter,
        hash, vtype, x, y, z, heading + 90.0)
    if not okCreate then
        print(('  the platform refused to create %s as a %s'):format(model, vtype))
        print(('    %s'):format(tostring(raw)))
        return
    end

    local veh = math.tointeger(tonumber(raw)) or 0
    if veh == 0 then
        print(('  the engine refused to create %s'):format(model))
        print('  The likeliest cause is that the name is not a vehicle in this')
        print('  game build -- the server does not validate the model, so a')
        print('  typo gets this far and no further.')
        return
    end

    -- ═══ EVERY NATIVE FROM HERE DOWN IS GUARDED, AND #212 IS WHY ═══
    --
    -- This is the stretch that killed the verb. `makeEntityFunction` natives
    -- THROW on a handle the server cannot resolve rather than answering a
    -- default, and the old code called four of them bare -- so one bad handle
    -- took the whole handler down between creating the car and saying anything
    -- about it. The car existed and the console was told nothing.
    --
    -- The server setter returns a real entity, so none of these SHOULD throw
    -- now. `should` is the word that put this verb in the issue tracker once
    -- already: what the guard buys is that the next platform surprise costs a
    -- printed line instead of a silent verb.
    local function ask(fn, ...)
        if not fn then return nil, 'native not available in this runtime' end
        local okCall, v = pcall(fn, ...)
        if not okCall then return nil, tostring(v) end
        return v, nil
    end

    -- THE BUCKET, COPIED FROM THE PLAYER RATHER THAN RE-DERIVED. roster.lua owns
    -- the rule that picks it -- lobby, warmup pad, or the match's own -- and a
    -- second copy of that rule here would be a second copy to keep right.
    --
    -- THE SETTER PUTS IT IN BUCKET 0 AND MATCHES DO NOT RUN THERE, so this is
    -- not a refinement: a car that stays in 0 is invisible to the person who
    -- asked for it, which is half of what "brcar does nothing" meant.
    local bucket = math.tointeger(tonumber(
        (ask(GetPlayerRoutingBucket, tostring(target)))))
    local bucketNote
    if bucket == nil then
        bucketNote = 'UNKNOWN -- could not read the player\'s bucket'
    else
        -- ZERO IS A REAL BUCKET AND IT IS TRUTHY, so this is an explicit nil
        -- test rather than `if bucket then`. Setting 0 on an entity already in
        -- 0 is a no-op; NOT setting it because 0 looked falsy would be the bug.
        local _, err = ask(SetEntityRoutingBucket, veh, bucket)
        bucketNote = err and ('FAILED (' .. err .. ')') or tostring(bucket)
    end

    local netId = math.tointeger(tonumber((ask(NetworkGetNetworkIdFromEntity, veh)))) or 0

    -- DID IT ACTUALLY APPEAR? `DoesEntityExist` is the one entity native the
    -- platform does NOT build with makeEntityFunction -- it is hand-written and
    -- answers false rather than throwing -- so it is the only honest answer
    -- available here, and it is normalised through didHit for this file's
    -- fifth-time reason: a FiveM BOOL hands Lua 1 on some builds, and 0 is
    -- truthy, so `if DoesEntityExist(v) then` is true for a car that is not
    -- there.
    local exists = didHit((ask(DoesEntityExist, veh)))

    print(('[br_core] brcar: %s (0x%08X) as %s -> %s (%d)')
        :format(model, BR.NormHash(hash), vtype, e.name or '?', target))
    print(('  at       %.1f, %.1f, %.1f   bucket %s')
        :format(x, y, z, bucketNote))
    print(('  handle   %d   netId %d   exists %s')
        :format(veh, netId, tostring(exists)))
    if not exists then
        print('  ^ THE SERVER DOES NOT SEE IT. It was created and is already')
        print('    gone, or the handle never resolved. Nothing below is true.')
        return
    end
    print('  Nothing owns it: no match teardown deletes it, and the platform')
    print('  collects it once no player has it in scope. It joins the fuel')
    print('  ledger the moment somebody in a match sits in it, with a full tank.')
end, true)
