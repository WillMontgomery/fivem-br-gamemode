-- The 23 station ambulances (#219 step 3), and the map of every ambulance a
-- match knows about.
--
-- Owner: "The 23 surveyed points should be persistent ambulances. Whenever a
-- squadmate is down or out, the blips for all the ambulances should be shown to
-- the whole squad." And: "Those ambulances should be spawned at the beginning of
-- the match when the bus doors open."
--
-- He has now hit the absence of this in three playtests -- "our ambulances
-- aren't spawning still. And neither did the blips for them" -- and the revive
-- key cannot be tested in an ordinary round without it, because the ambulance is
-- where a revive happens.
--
-- ═══════════════════════════════════════════════════════════════════════════
-- THE FIRST ROUND THEY ALL WORKED CORRECTED THE SENTENCE ABOVE, TWICE
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Both corrections are the owner's, 2026-08-31, and both are implemented in
-- `publish`. They are recorded here because the quote above is what this file
-- was built from and it is no longer the whole rule.
--
--   NOT "DOWN OR OUT" -- OUT. "while a squadmate is DBNO bleeding out we have
--   ambulance blips for the squad, but we can't do anything with the ambulances.
--   We should not see blips until they've bled out." A downed mate is picked up
--   AT THE BODY; there is no revive key until they are eliminated, so during the
--   bleed-out the map of vans points at something nobody can use yet.
--
--   AND THE 23 ARE NOT THE WHOLE MAP. "let's not auto-show ambulance blips just
--   because they got in an ambulance - BUT do add the position to the table so
--   when blips are shown we can include any that other players have found along
--   the way (engine-spawned ones)." Discovery is server/rescue.lua's -- it owns
--   the only hook that can see ambient traffic -- and it used to publish a blip
--   to the whole match the moment anyone sat in a van. It now only remembers.
--   This file mirrors that ledger (`refreshFound`) and publishes the finds
--   through the same gate as the 23: same audience, same trigger, same event,
--   one undifferentiated set of icons on the squad's map.
--
-- ═══════════════════════════════════════════════════════════════════════════
-- WHY THE SERVER MAKES THEM, WHICH IS NOT A CHOICE
-- ═══════════════════════════════════════════════════════════════════════════
--
-- `sv_entityLockdown relaxed`. The engine's ValidateEntity admits a client's
-- clone-create only for POPTYPE_RANDOM_* or an entity whose creation token
-- carries a script guid, and a client script's vehicle is POPTYPE_MISSION with
-- no token -- so a client CreateVehicle is refused, silently, and answers 0
-- (which is truthy in Lua). The whole write-up is above `brcar` in
-- server/vehicles.lua. BR.Vehicles.spawnOwned is the only creation path in this
-- tree and tools/verify.sh refuses CreateVehicle anywhere else.
--
-- WHAT 23 OF THEM COST, MEASURED RATHER THAN GUESSED:
--
--   AT CREATION. CreateVehicleServerSetter builds a sync tree and registers the
--   entity before it mints the handle. That is the whole of the per-vehicle
--   cost on this side, and `perTick` spreads twenty-three of them over four
--   passes so no single scheduler job carries all of it (BR.Sched records every
--   job's peak; /brperf prints it).
--
--   IN TRAFFIC AT CREATION: as close to nothing as makes no difference. OneSync
--   relevancy for an empty vehicle is 2D distance with a 424-unit radius, the
--   stations are spread over 51 km^2, and at doors-open every player in the
--   match is in the plane. Almost none of these are cloned to anybody at the
--   moment they are made; each one clones when somebody drives within 424m of
--   it, which is the streaming the world would have done for a parked car
--   anyway.
--
--   FOR THE REST OF THE MATCH: 23 entities held by the server. server/loot.lua's
--   sentence is the ceiling worth remembering -- "1900 networked entities would
--   end the server before the first circle closed" -- and 23 is not near it.
--   NOTHING WIDENS THEIR CULLING RADIUS. server/rescue.lua widens its ride's,
--   for a reason that does not apply here (it has to reach a player 800m away
--   before they can adopt it), and the deprecation that buys -- citizenfx/fivem
--   #1828, an entity far from its owner teleporting back to its spawn point --
--   is a bug this feature simply never opts into. The blips do the long-range
--   work instead, out of server coordinates, which is client/squadmates.lua's
--   pattern and has no scope ceiling at all.
--
--   THEY ARE NOT CULLED WHILE NOBODY IS NEAR. A server-script entity carries a
--   creation token, so IsOwnedByServerScript() and ShouldServerKeepEntity() are
--   both already true for it -- the same fact server/rescue.lua relies on, and
--   the reason no orphan mode is set here either.
--
-- ═══════════════════════════════════════════════════════════════════════════
-- FUEL: THEY BURN NONE WHILE PARKED, AND ORDINARY FUEL WHEN DRIVEN
-- ═══════════════════════════════════════════════════════════════════════════
--
-- server/fuel.lua's registry admits a vehicle ONLY BY IT BEING OCCUPIED BY A
-- PLAYER -- "an empty car is not tracked, does not cost a tick, and reads as
-- full, because it is". So twenty-three parked ambulances add exactly zero rows,
-- zero samples and zero pushes to the ledger, by construction and with no
-- exemption written anywhere.
--
-- AND NO EXEMPTION IS WRITTEN. The moment a player gets in and drives one it
-- enters the ledger like any other vehicle they found in the world, with a full
-- tank, and it burns metres for the same reasons everything else does. The one
-- fuel exemption this feature family has is `e.rescue` -- the NPC-driven CPR
-- ride, where "this person is cargo, not a driver" -- and that reasoning does
-- not reach a player who chose to drive an ambulance. Making the stations free
-- fuel would make an ambulance the best car on the map for a reason nobody
-- asked for.
--
-- ═══════════════════════════════════════════════════════════════════════════
-- WHAT IS DELIBERATELY NOT DONE TO THEM
-- ═══════════════════════════════════════════════════════════════════════════
--
-- NOT LOCKED, NOT INVINCIBLE, NO MODS, NO SIREN. A station ambulance is an
-- ordinary vehicle standing in an ordinary car park: players may take it (which
-- is what config/rescue.lua's parked-scene decision already wants -- "doors
-- open, lights on, but nobody inside... so players can take the ambulance"),
-- players may destroy it, and server/ambheal.lua will heal somebody in the back
-- of it because the owner's rule there is "any ambulance at all".
--
-- Every one of those would be a write to an entity this server does not control
-- -- vehicle mods, doors and sirens are client-side natives on a machine that
-- has to own the entity first -- and none of them was asked for.

BR = BR or {}
BR.Ambulances = {}

local A = BR.Config.Ambulances
local M = BR.Config.Match

--- A BOOL native's answer, believed correctly.
---
--- `0` IS TRUTHY IN LUA and a FiveM BOOL native may answer 1/0 rather than
--- true/false, so `if DoesEntityExist(veh) then` is TRUE for a handle that does
--- not exist. Here that would mean re-deleting a vehicle that has been gone for
--- twenty minutes, on every pass, for ever -- and reporting a teardown that
--- never finished. Same helper, same spelling and the same reason as
--- server/fuel.lua's and server/vehicles.lua's.
--- @param v any
--- @return boolean
local function didHit(v)
    return v == 1 or v == true
end

--- Live station sets, by match id. [matchId] = record
---
--- KEYED ON THE MATCH ID RATHER THAN HELD ON THE MATCH INSTANCE, and that is
--- what makes the teardown reachable at all: `BR.Match.destroy` clears
--- `BR.Server.matches[m.id]` BEFORE it raises `br:match:destroyed`, so a record
--- parked on the instance would become unreachable at the exact moment it needed
--- deleting. Every field here is server-side and none of it is ever sent.
---
--- Shape:
---   bucket    integer            the match's routing bucket
---   pending   table[]            surveyed points not built yet
---   next      integer            index into `pending`
---   stations  table[]            { id, veh, x, y, key, moved }
---   refused   integer            points the engine or the allowlist would not build
---   tearing   boolean|nil        deletion in progress
---   attempts  integer            teardown passes spent
---   gone      string[]           blip keys to withdraw on this pass
local live = {}

--- Who currently has station blips on their map. [src] = matchId
local showing = {}

--- Is the whole feature switched on and configured?
--- @return boolean
local function enabled()
    return A ~= nil and A.enabled == true
end

--- What to call a point in a console line. The surveyed rows carry an `id`
--- derived from the nearest POI; a row without one is named by its coordinates,
--- which is what somebody would search config/map.lua for.
--- @param p table
--- @return string
local function pointName(p)
    if p.id then return tostring(p.id) end
    return ('%.1f, %.1f'):format(p.x or 0.0, p.y or 0.0)
end

-- ---------------------------------------------------------------------------
-- Creation
-- ---------------------------------------------------------------------------

--- Start the set for a match whose bus doors have just opened.
---
--- NOTHING IS CREATED HERE. The points are queued and `advance` builds them a
--- few per pass; see `perTick` in config/ambulances.lua for why that matters and
--- why the stagger is invisible.
--- @param m table
local function begin(m)
    local points = A.Points()
    if #points == 0 then
        print(('[br_core] ambulances: match %d -- no surveyed points, nothing to '
               .. 'spawn (BR.Config.Map.AmbulanceSpawns is empty)'):format(m.id))
        -- A RECORD IS STILL MADE. Without one this runs the empty check on every
        -- pass for the whole match, and -- worse -- `advance` would be re-entered
        -- from scratch the moment somebody authored a point mid-match.
    end

    local pending = {}
    for i = 1, #points do pending[i] = points[i] end

    live[m.id] = {
        bucket   = (M and M.matchBucketBase or 100) + m.id,
        pending  = pending,
        next     = 1,
        stations = {},
        -- THE AMBULANCES NOBODY AUTHORED. [blipKey] = { x, y, moved }, mirrored
        -- every pass from server/rescue.lua's discovery ledger -- see
        -- `refreshFound`. Empty for most of most matches and never touched by
        -- creation or teardown: nothing in here was made by this file.
        ambient  = {},
        refused  = 0,
        attempts = 0,
        gone     = {},
    }
end

--- Build the next few.
--- @param matchId integer
--- @param rec table
local function advance(matchId, rec)
    if rec.next > #rec.pending then return end

    local built = 0
    while rec.next <= #rec.pending and built < (A.perTick or 6) do
        local p = rec.pending[rec.next]
        rec.next = rec.next + 1
        built = built + 1

        -- THE BUCKET IS PASSED RATHER THAN INHERITED FROM A PLAYER.
        -- spawnOwned's `forSrc` reads one player's bucket, and at doors-open
        -- there is no player whose bucket is reliably the match's: riders stay
        -- in the communal warmup bucket until `m.hopAt`, and whether that has
        -- passed depends on the route. The match's own bucket is
        -- matchBucketBase + matchId and is known without asking anybody.
        local veh, netId, why = BR.Vehicles.spawnOwned(
            A.Model(), 'automobile',
            p.x, p.y, p.z, p.heading or 0.0, nil, rec.bucket)

        if not veh then
            rec.refused = rec.refused + 1
            print(('[br_core] ambulances: match %d -- %s refused (%s)')
                :format(matchId, pointName(p), tostring(why)))
        else
            rec.stations[#rec.stations + 1] = {
                id    = p.id,
                veh   = veh,
                netId = netId,
                x     = p.x + 0.0,
                y     = p.y + 0.0,
                -- OPAQUE TO THE CLIENT, and namespaced the way the handler in
                -- client/rescue.lua was written to expect: `r:<src>` is a rescue
                -- in flight, `v:<entity>` an ambient ambulance somebody was seen
                -- driving, and `s:<entity>` a station. That file's own note --
                -- "that is what lets the server add a category without this file
                -- changing" -- is the contract being used here.
                key   = 's:' .. tostring(veh),
                moved = true,
            }
        end
    end

    if rec.next > #rec.pending then
        print(('[br_core] ambulances: match %d -- %d of %d station ambulances up '
               .. 'in bucket %d (%d refused)')
            :format(matchId, #rec.stations, #rec.pending, rec.bucket,
                    rec.refused))
    end
end

-- ---------------------------------------------------------------------------
-- The blips
-- ---------------------------------------------------------------------------

--- Which group a player's blips are decided by.
---
--- A SOLO PLAYER IS A SQUAD OF ONE. The owner's sentence says "squadmate" and
--- "the whole squad", which in a squad match is exactly the squad. In a solo
--- match there is no squad -- but a solo player CAN be DBNO (config/rescue.lua's
--- CPR kit is solos-only and knocking them down is its whole point), and
--- refusing them the map on a technicality would be a rule nobody asked for
--- serving nobody. So a player with no squad is their own group.
--- @param src integer
--- @param e table
--- @return string
local function groupKey(src, e)
    if e.squadId then return 's' .. tostring(e.squadId) end
    return 'p' .. tostring(src)
end

-- ---------------------------------------------------------------------------
-- WHICH VANS HAVE SOMEBODY IN THEM
-- ---------------------------------------------------------------------------
--
-- Owner, 2026-08-31: "let's not show a blip for an ambulance while a player is
-- in that ambulance."
--
-- ═══ IT APPLIES TO ALL OF THEM, AND FALLS OUT OF WHERE IT IS ASKED ═══
--
-- The 23 stations and the ones players have found are published by one rule
-- because they are shaped the same (`refreshFound`'s note). Occupancy is asked
-- of a VEHICLE HANDLE, which both lists carry, so it lands on both without a
-- second mechanism -- which is what the sentence asks for: a van somebody is
-- sitting in is a van somebody is sitting in.
--
-- ═══ WHY THE ROSTER IS WALKED AND NOT THE AMBULANCES ═══
--
-- The obvious loop is over the vans, asking each who is in its seats. It is the
-- wrong way round twice over.
--
--   IT CANNOT TELL A PLAYER FROM A PED, and the difference is the request. An
--   AMBIENT ambulance drives around with an NPC at the wheel; that is what
--   `rec.ambient` is a ledger of. "While a PLAYER is in that ambulance" would be
--   false for every one of them and this loop would hide their blips anyway.
--   Walking the roster, every ped considered is a player by construction.
--
--   AND IT COSTS 23 VANS TIMES 9 SEATS. Walking the roster costs one native per
--   player -- `BR.Vehicles.ridingIn` interrogates at most ONE vehicle, the
--   candidate its first read hands back -- and the seat walk is only reached for
--   somebody actually sitting in something.
--
-- ═══ AND IT IS BR.Vehicles.ridingIn RATHER THAN THE NATIVE ═══
--
-- Because the native lies. citizenfx/fivem#4006, still OPEN: server-side
-- `GetVehiclePedIsIn(ped, false)` answers the LAST vehicle for a ped in none, so
-- a bare read would mark an ambulance occupied by a player who got out of it
-- minutes ago and never give the blip back. server/vehicles.lua owns that
-- workaround and its header owns the argument.
--
-- REBUILT WHOLE EVERY PASS, so a player getting out is a set this van is simply
-- not in next second. There is nothing to clear and no event to miss.
--- Vehicle handles a player of this match is sitting in right now.
--- @param matchId integer
--- @return table  [vehicle handle] = true
local function occupants(matchId)
    local held = {}
    if not (BR.Vehicles and BR.Vehicles.ridingIn) then return held end

    BR.Roster.each(
        -- EVERY STATE, NOT ONLY THE PLAYING ONES. The question is "is there
        -- somebody in this van", and a player riding in the back while a
        -- squadmate drives is in it whatever the roster calls them. The audience
        -- test above is where states belong; this is a fact about a vehicle.
        function(e) return e.matchId == matchId and e.ped ~= nil end,
        function(_, e)
            local veh = BR.Vehicles.ridingIn(e.ped)
            if veh then held[veh] = true end
        end)
    return held
end

--- @param src integer
--- @param key string
--- @param x number|nil
--- @param y number|nil
local function push(src, key, x, y)
    if not x or not y then
        TriggerClientEvent(BR.Net.RESCUE_BLIP, src, { key = key, gone = true })
        return
    end
    TriggerClientEvent(BR.Net.RESCUE_BLIP, src, { key = key, x = x, y = y })
end

--- Take every ambulance blip off one player's map.
---
--- ALL THREE LISTS, and the third is the one that would be missed: `rec.gone`
--- holds keys retired THIS pass, which are no longer in either live list and
--- would otherwise be left drawn on the map of a player who stops qualifying in
--- the same second one of them expired.
--- @param src integer
--- @param rec table
local function hide(src, rec)
    for _, s in ipairs(rec.stations) do push(src, s.key, nil, nil) end
    for key in pairs(rec.ambient) do push(src, key, nil, nil) end
    for _, key in ipairs(rec.gone) do push(src, key, nil, nil) end
    showing[src] = nil
end

--- Publish this match's ambulance blips to the squads that should have them.
---
--- ═══ ALL OF THEM, TO THE WHOLE SQUAD, ONCE A SQUADMATE IS OUT ═══
---
--- OUT, AND NO LONGER DBNO. Owner, 2026-08-31: "while a squadmate is DBNO
--- bleeding out we have ambulance blips for the squad, but we can't do anything
--- with the ambulances. We should not see blips until they've bled out."
---
--- The earlier rule said "down or out" and this file kept it literally. What a
--- round showed is that the two halves are not the same offer. While a mate is
--- DBNO the answer is a revive AT THE BODY -- client/dbno.lua's plate, a hold,
--- free, and it keeps their inventory -- and nothing about an ambulance is
--- reachable: there is no key yet, so the whole map of vans is pointing at
--- something nobody can use. The key is minted at ELIMINATION
--- (BR.ReviveKey.onEliminated, off server/combat.lua), and that is the instant
--- these blips become an actual choice. So the test is exactly OUT, and it lines
--- up with the state the revive key exists for rather than with a word.
---
--- ALL OF THEM STILL, AND TO THE WHOLE SQUAD STILL. Not the nearest van, not the
--- one beside the body: the squad is deciding where to drive, and a map showing
--- one option is not a choice.
---
--- THE AUDIENCE TEST IS SEPARATE FROM THE TRIGGER and both need OUT for
--- different reasons. BR.Server.isInMatch does not count OUT, and an eliminated
--- player must still SEE the map their squad is reading -- they are the one being
--- fetched. So the second filter is `isInMatch OR OUT`, and the first is OUT
--- alone.
---
--- ═══ AND IT IS NOT ONLY THE 23 ═══
---
--- Owner, same message: "do add the position to the table so when blips are
--- shown we can include any that other players have found along the way
--- (engine-spawned ones)." `rec.ambient` is that table, mirrored from
--- server/rescue.lua's discovery ledger by `refreshFound`, and it is published
--- through the identical gate: found ambulances are not a second feature with a
--- second audience, they are more rows in the same list.
---
--- ONLY TRANSITIONS AND MOVEMENT ARE SENT. Turning the blips on sends the whole
--- set once; after that a parked ambulance sends nothing at all, and one somebody
--- drives away sends its own coordinates at this pass's cadence. Re-sending 23
--- coordinates per squad per second for vehicles that are not moving would be
--- the whole of this feature's network cost, for nothing.
--- @param matchId integer
--- @param rec table
--- What a record's blip should do on THIS pass.
---
--- ═══ ONE ANSWER FOR BOTH LISTS, AND FOR ALL FOUR CASES ═══
---
--- A station and a found van are shaped the same and are published by one rule,
--- so the decision is written once. The record's DRAWN STATE is either a pair of
--- coordinates or nothing at all, and this returns whether that state changed
--- since the last pass and what it now is:
---
---   occupied, just became so     withdraw it     (the owner's rule firing)
---   occupied, already withdrawn  say nothing     (the silence that keeps this
---                                                 feature's network cost at
---                                                 zero for parked vans)
---   free, just became so         send its point  (somebody got out)
---   free, and it moved           send its point  (the rule that was here)
---
--- WITHOUT THE `turned` HALF THIS FEATURE WOULD LOOK LIKE IT WORKED AND NOT
--- COME BACK. Publishing sends transitions only, so a van whose blip is withheld
--- while occupied and then simply stops being mentioned when the driver gets out
--- would leave the squad with a permanently missing ambulance -- and a missing
--- blip is exactly the failure nobody reports as a bug, because there is nothing
--- on screen to point at.
--- @param r table  a station or an ambient record
--- @return boolean send
--- @return number|nil x
--- @return number|nil y
local function sending(r)
    if r.occupied then return r.turned == true, nil, nil end
    return (r.turned == true or r.moved == true), r.x, r.y
end

local function publish(matchId, rec)
    if not A.blip or A.blip.enabled == false then return end

    -- WHICH GROUPS HAVE SOMEBODY OUT.
    local needy = {}
    BR.Roster.each(
        function(e) return e.matchId == matchId
            and e.state == BR.PlayerState.OUT end,
        function(src, e) needy[groupKey(src, e)] = true end)

    BR.Roster.each(
        function(e) return e.matchId == matchId
            and (BR.Server.isInMatch(e.state)
                 or e.state == BR.PlayerState.OUT) end,
        function(src, e)
            local want = needy[groupKey(src, e)] == true
            local had  = showing[src] == matchId

            if not want then
                if had then hide(src, rec) end
                return
            end

            if not had then
                -- NEWLY QUALIFYING: the whole set, once -- minus the vans
                -- somebody is sitting in. Skipped rather than pushed as `gone`:
                -- this player has no blip for a key they have never been sent,
                -- and withdrawing one is a message about nothing. They get it
                -- the moment the van empties, through `turned` below.
                for _, s in ipairs(rec.stations) do
                    if not s.occupied then push(src, s.key, s.x, s.y) end
                end
                for key, f in pairs(rec.ambient) do
                    if not f.occupied then push(src, key, f.x, f.y) end
                end
                showing[src] = matchId
                return
            end

            -- ALREADY SHOWING: only what changed. A find that is new to this
            -- pass carries `moved` set, so it reaches a player who already has
            -- the rest by the same road a station that drove off does -- and a
            -- van that has just been climbed into or out of carries `turned`,
            -- which reaches them by that same road again.
            for _, key in ipairs(rec.gone) do push(src, key, nil, nil) end
            for _, s in ipairs(rec.stations) do
                local send, x, y = sending(s)
                if send then push(src, s.key, x, y) end
            end
            for key, f in pairs(rec.ambient) do
                local send, x, y = sending(f)
                if send then push(src, key, x, y) end
            end
        end)
end

--- Re-read every station's position, and drop the ones that have stopped
--- existing.
---
--- A STATION AMBULANCE CAN LEGITIMATELY GO. Somebody blows it up, or drives it
--- off a cliff, or citizenfx/fivem#2623 -- "Server side Vehicle created with
--- CreateVehicleServerSetter are randomly deleted", OPEN, and already cited in
--- config/shop.lua and server/shop.lua for the same native -- takes it. All
--- three look identical from here and all three have the same right answer: the
--- record is forgotten and the blip is withdrawn, because a blip pointing at a
--- vehicle that is not there is worse than no blip at all.
---
--- NOTHING IS RESPAWNED. The owner asked for the 23 points to BE ambulances at
--- the start of the match, not for a station to keep producing them -- and a
--- station that refilled itself would hand a squad an unlimited supply of the
--- one vehicle this feature is built around.
--- @param rec table
--- @param rec table
--- @param held table  [vehicle handle] = true, from `occupants`
local function refresh(rec, held)
    local kept = {}
    for _, s in ipairs(rec.stations) do
        local okEx, exists = pcall(DoesEntityExist, s.veh)
        if not okEx or not didHit(exists) then
            rec.gone[#rec.gone + 1] = s.key
        else
            -- WHO IS IN IT, AND WHETHER THAT IS NEWS. `turned` is the edge and
            -- `occupied` is the level; `sending` needs both, because a blip that
            -- is already withheld must not be withheld again every second.
            local was = s.occupied == true
            s.occupied = held[s.veh] == true
            s.turned = s.occupied ~= was

            s.moved = false
            local okPos, c = pcall(GetEntityCoords, s.veh)
            if okPos and c then
                if BR.Dist(c.x, c.y, s.x, s.y) > (A.blip and A.blip.movedM or 1.0) then
                    s.x, s.y = c.x + 0.0, c.y + 0.0
                    s.moved = true
                end
            end
            kept[#kept + 1] = s
        end
    end
    rec.stations = kept
end

--- Mirror the ambulances this match has DISCOVERED, and retire the ones that
--- have stopped existing.
---
--- ═══ THE 23 ARE OURS; THESE ARE ONLY EVER BORROWED ═══
---
--- Owner, 2026-08-31: "do add the position to the table so when blips are shown
--- we can include any that other players have found along the way (engine-spawned
--- ones)."
---
--- WHY THE LEDGER IS NOT KEPT HERE. Ambient traffic is client-created population
--- and this server cannot see it at all until somebody sits in one --
--- server/rescue.lua's AMBIENT AMBULANCES section argues that out and owns the
--- only hook there is (server/vehicles.lua's 4 Hz seat read). So discovery lives
--- there and the MAP lives here, which is the split the owner's sentence
--- describes: a table that is added to as players find things, read at the moment
--- blips are shown.
---
--- WHY A MIRROR RATHER THAN READING IT AT PUBLISH TIME. `moved` is a difference
--- between two passes, and publish runs once per WATCHING PLAYER's group rather
--- than once per pass -- computing it there would ask the same question several
--- times and get a different answer each time. `rec.stations` carries exactly the
--- same field for exactly the same reason, and the two lists are published by one
--- rule because they are shaped the same.
---
--- ═══ HOW A STALE RECORD IS RETIRED ═══
---
--- IT IS NOT RETIRED HERE, AND THAT IS DELIBERATE. server/rescue.lua's sweep asks
--- DoesEntityExist once a second and drops the record the moment the answer is
--- no -- a van that was blown up, or that the owning client's population manager
--- reclaimed after everybody drove away. This pass sees the disappearance as a
--- key that stopped being walked, puts it on `rec.gone`, and `publish` withdraws
--- the blip from everyone holding it in the same pass. One staleness rule, in the
--- file that can actually observe it, and the same DoesEntityExist test the 23
--- live by one function above.
--- @param matchId integer
--- @param rec table
--- @param matchId integer
--- @param rec table
--- @param held table  [vehicle handle] = true, from `occupants`
local function refreshFound(matchId, rec, held)
    local was = rec.ambient
    local now = {}

    -- NIL-GUARDED, and the guard is load order rather than caution:
    -- server/rescue.lua may be disabled outright (BR.Config.Rescue.enabled), and
    -- tools/test_ambulances drives this file with no rescue module at all. With
    -- no ledger the mirror is empty, every key falls into `rec.gone` once, and
    -- the 23 carry on exactly as they did.
    if BR.Rescue and BR.Rescue.eachFound then
        local movedM = (A.blip and A.blip.movedM) or 1.0
        -- THE HANDLE IS THE FOURTH ARGUMENT, AND IT IS NOT THE KEY PARSED BACK.
        -- Occupancy is a question about a VEHICLE and the key is an opaque
        -- string by construction (see BR.Rescue.eachFound's header); unpicking
        -- `v:1234` here would make that format a contract between two files.
        BR.Rescue.eachFound(matchId, function(key, x, y, veh)
            local occupied = held[veh] == true
            local f = was[key]
            if not f then
                -- NEW, AND `moved` IS TRUE ON PURPOSE. It is what carries a
                -- freshly discovered van onto the map of a squad that is already
                -- watching -- `rec.stations` sets the same flag at creation for
                -- the same reason.
                --
                -- ...AND `turned` IS FALSE EVEN WHEN IT IS OCCUPIED, which is
                -- not the same as a change nobody saw. A van discovered with
                -- somebody in it has never been drawn anywhere, so there is
                -- nothing to withdraw -- `sending` reads `occupied` and stays
                -- silent. The pass that empties it sets `turned` and puts it on
                -- the map for the first time.
                now[key] = { x = (x or 0.0) + 0.0, y = (y or 0.0) + 0.0,
                             moved = true, occupied = occupied, turned = false }
                return
            end
            local wasIn = f.occupied == true
            f.occupied = occupied
            f.turned = occupied ~= wasIn

            f.moved = BR.Dist(x or f.x, y or f.y, f.x, f.y) > movedM
            if f.moved then f.x, f.y = x + 0.0, y + 0.0 end
            now[key] = f
        end)
    end

    for key in pairs(was) do
        if not now[key] then rec.gone[#rec.gone + 1] = key end
    end
    rec.ambient = now
end

-- ---------------------------------------------------------------------------
-- Teardown
-- ---------------------------------------------------------------------------

--- Delete a match's station ambulances, and prove it.
---
--- ═══ THE ENGINE BUG THIS IS SHAPED AROUND: citizenfx/fivem#2256 ═══
---
--- "Vehicles Persisting After Server-Side Deletion", opened 2023-10-29, still
--- OPEN, labelled `onesync`. Its reproduction is a server-side deletion loop
--- over SEVERAL vehicles in a NON-DEFAULT ROUTING BUCKET, and the reported
--- symptom is that the server's DeleteEntity succeeds, DoesEntityExist answers
--- false from then on, and CLIENTS GO ON RENDERING THE VEHICLE. The thread
--- carries no workaround. This feature is that reproduction almost exactly:
--- twenty-three vehicles, deleted together, in bucket matchBucketBase + matchId.
---
--- IT IS TWO FAILURES WEARING ONE NAME, AND THEY NEED DIFFERENT ANSWERS.
---
---   1. THE DELETE DID NOT TAKE, and the server can see it: the handle still
---      exists on the next pass. Answered here -- re-issued, `deleteAttempts`
---      times, a few per pass, and whatever survives is PRINTED with its point
---      id rather than dropped quietly. A teardown that silently gave up is
---      indistinguishable from one that worked, which is how this class of bug
---      stays invisible for a year.
---
---   2. THE SERVER THINKS IT IS GONE AND A CLIENT DISAGREES. No amount of
---      re-asking finds this one -- the server's own answer is the thing that is
---      wrong -- so it is not answered by retrying. IT IS ANSWERED BY THE
---      BUCKET, and that is a property rather than a hope: BR.Match.create takes
---      `BR.Server.matchId + 1` and never reuses a number, so a match's bucket
---      (matchBucketBase + matchId) is used by exactly one match for the
---      server's uptime. A ghost left in bucket 100+N is in a bucket no future
---      match is ever placed in, and every player of match N is moved to the
---      lobby bucket at ENDED -- before this teardown runs -- by
---      BR.Match.sweepHome. So a surviving ghost is unobservable by
---      construction, and "it does not leak into the next match" does not depend
---      on the delete having worked.
---
--- SPREAD OVER PASSES, `perTick` at a time, for the reason the creation is: the
--- same thread that reports the bug is a tight server-side loop over several
--- vehicles at once.
--- @param matchId integer
--- @param rec table
local function teardown(matchId, rec)
    -- THE BLIPS COME OFF FIRST, AND BEFORE ANY DELETE. A red ambulance icon
    -- stranded on a lobby map is exactly the leftover nobody can explain later,
    -- and the client's own SLOW sweep (client/rescue.lua, 'rescue.blips') is the
    -- second net rather than the first.
    if not rec.hidden then
        for src, id in pairs(showing) do
            if id == matchId then hide(src, rec) end
        end
        rec.hidden = true
    end

    rec.attempts = rec.attempts + 1

    -- THE ATTEMPT COUNT IS PER VEHICLE, NOT PER PASS, and it has to be: 23
    -- stations at `perTick` 6 need four passes just to ISSUE the first delete
    -- for every one of them, so a per-pass budget of 5 would declare the last
    -- batch a survivor before it had been asked once.
    local maxTries = A.deleteAttempts or 5
    local remaining = {}
    local issued, owed = 0, 0
    for _, s in ipairs(rec.stations) do
        local okEx, exists = pcall(DoesEntityExist, s.veh)
        -- GONE, AND THE SERVER CAN SEE IT: the row is simply not carried
        -- forward. That is the only evidence a delete ever produces, which is
        -- why the delete below does NOT remove the row itself.
        if okEx and didHit(exists) then
            s.tries = s.tries or 0
            if s.tries < maxTries and issued < (A.perTick or 6) then
                pcall(DeleteEntity, s.veh)
                s.tries = s.tries + 1
                issued = issued + 1
            end
            if s.tries < maxTries then owed = owed + 1 end
            -- NOT COUNTED AS GONE UNTIL THE NEXT PASS ASKS. DeleteEntity's
            -- answer is not a confirmation, which is the whole of #2256 -- so
            -- the row survives until DoesEntityExist says otherwise, and a
            -- vehicle beyond this pass's budget simply waits for the next one.
            remaining[#remaining + 1] = s
        end
    end
    rec.stations = remaining

    if #rec.stations == 0 then
        print(('[br_core] ambulances: match %d -- every station ambulance is gone '
               .. '(%d pass(es))'):format(matchId, rec.attempts))
        live[matchId] = nil
        return
    end

    -- GIVING UP TAKES ONE MORE PASS THAN EXHAUSTING THE RETRIES. `owed == 0`
    -- says every survivor has had its full quota; `issued == 0` says none of
    -- those deletes was ordered on THIS pass, so each has had at least one
    -- round trip in which to disappear. Reporting on the pass that issued the
    -- last delete would report vehicles that were about to go.
    if owed == 0 and issued == 0 then
        local names = {}
        for _, s in ipairs(rec.stations) do
            names[#names + 1] = ('%s(%d)'):format(tostring(s.id or '?'), s.veh)
        end
        print(('[br_core] ambulances: match %d -- %d station ambulance(s) SURVIVED '
               .. '%d delete(s) each across %d pass(es) in bucket %d: %s. '
               .. 'citizenfx/fivem#2256; the bucket is never reused and every '
               .. 'player left it at ENDED, so they are unreachable rather than '
               .. 'leaked.')
            :format(matchId, #rec.stations, maxTries, rec.attempts, rec.bucket,
                    table.concat(names, ' ')))
        live[matchId] = nil
    end
end

-- ---------------------------------------------------------------------------
-- The pass
-- ---------------------------------------------------------------------------

--- Have this match's bus doors opened?
---
--- THE OWNER'S MOMENT, EXACTLY. `route.jumpFrom` is the timestamp the doors open
--- and the first jump becomes legal -- server/bus.lua stamps it in `depart` and
--- widens it for the door zones the flight crosses -- so this is the same clock
--- the player is watching rather than a second approximation of it.
---
--- ═══ A MATCH THAT IS ALREADY PLAYING COUNTS, AND THAT IS NOT A SHORTCUT ═══
---
--- The BUS state can be left in less than a pass. server/match.lua goes live
--- "when the LAST player is down -- not when the route timer says so", and
--- `brforce playing` skips the flight outright -- so a set that only ever opened
--- on `state == BUS` would silently produce a round with no ambulances in it,
--- which is the exact symptom the owner has now reported three times. PLAYING is
--- a state a match can only reach through an open door, so this is the same
--- condition read one step later rather than a second rule.
---
--- IT CANNOT DOUBLE-SPAWN ACROSS A RESOURCE RESTART. `BR.Server.matches` is
--- built empty at load (server/main.lua), so a restart destroys every match
--- rather than rejoining one -- there is no path on which a PLAYING match
--- already holding 23 station ambulances is seen by a fresh copy of this file.
--- The `live[m.id]` check above the caller is what covers every other repeat.
--- @param m table
--- @return boolean
local function doorsOpen(m)
    if m.state == BR.MatchState.PLAYING then return true end
    if m.state ~= BR.MatchState.BUS then return false end
    local r = m.route
    if not r or not r.timed or not r.jumpFrom then return false end
    return GetGameTimer() >= r.jumpFrom
end

BR.Sched.every((A and A.tickMs) or 1000, 'ambulances.tick', function()
    if not enabled() then return end

    BR.Server.eachMatch(function(m)
        local rec = live[m.id]

        if not rec then
            if not doorsOpen(m) then return end
            begin(m)
            rec = live[m.id]
            -- FALLING THROUGH RATHER THAN RETURNING. Opening the set and then
            -- waiting a whole pass before building anything spends a second for
            -- nothing and, worse, makes "23 at perTick 6" take five passes
            -- rather than four -- an off-by-one that only shows up as a stagger
            -- one pass longer than the arithmetic says.
            if not rec then return end
        end

        -- A MATCH THAT IS NO LONGER BEING PLAYED IS BEING TORN DOWN. The same
        -- rule and the same cadence as server/rescue.lua's `rescue.abandoned`
        -- sweep, which deletes its own leftover ambulances on exactly this test.
        if m.state ~= BR.MatchState.BUS and m.state ~= BR.MatchState.PLAYING then
            rec.tearing = true
            return
        end

        advance(m.id, rec)

        -- ONE OCCUPANCY READ FOR BOTH LISTS, TAKEN ONCE PER PASS. The two
        -- refreshes below ask the same question of different vans, and this is
        -- `refreshFound`'s own argument for mirroring rather than reading at
        -- publish time: a fact computed per consumer is a fact several consumers
        -- can get different answers to.
        local held = occupants(m.id)

        refresh(rec, held)
        -- BEFORE publish AND AFTER refresh, because both of them write
        -- `rec.gone` and publish is what drains it. A find that expired this
        -- second must be withdrawn in the same pass it expired in, or its blip
        -- survives until something else happens to move.
        refreshFound(m.id, rec, held)
        publish(m.id, rec)
        rec.gone = {}
    end)

    -- SEPARATE WALK, BECAUSE A TEARDOWN OUTLIVES ITS MATCH. `BR.Match.destroy`
    -- clears BR.Server.matches[id] before it raises `br:match:destroyed`, so
    -- anything driven off `eachMatch` alone would stop running at the exact
    -- moment there was still work to do.
    for matchId, rec in pairs(live) do
        if rec.tearing then teardown(matchId, rec) end
    end
end)

--- The one reliable end-of-match signal.
---
--- server/match.lua raises it from the single path out of the registry, and its
--- own note says why nothing else will do: `br:match:results` returns early on
--- an empty match and would leak everything keyed to it. A match dissolved
--- during the bus flight -- everybody left after the doors opened -- never
--- reaches CLEANUP at all, and it is the case this handler exists for.
AddEventHandler('br:match:destroyed', function(d)
    local id = d and d.matchId
    local rec = id and live[id]
    if rec then rec.tearing = true end
end)

--- A player who is gone is showing nothing.
---
--- SERVER IDS ARE RECYCLED WITHIN THE MINUTE, and a row left here would be
--- inherited by whoever lands in that slot next -- who would then be told their
--- blips were already up and never receive them. The same reason
--- server/vehicles.lua and server/damage.lua clear theirs here.
AddEventHandler('playerDropped', function()
    local src = source
    if src then showing[src] = nil end
end)

-- ---------------------------------------------------------------------------
-- What the rescue asks
-- ---------------------------------------------------------------------------

--- Move a rescue's spawn out of a station ambulance, or leave it where it is.
---
--- ═══ WITHOUT THIS, EVERY RESCUE SPAWNS INSIDE A PARKED AMBULANCE ═══
---
--- server/rescue.lua creates its ride at the surveyed pickup point EXACTLY.
--- client/rescue.lua's `freeSpaceNear` used to step it aside and cannot any more
--- -- "the vehicle is created on the server, which has no IsPositionOccupied to
--- ask" -- so that ring-walk now only sites the medic, and config/rescue.lua's
--- claim that the mitigation is live ("`freeSpaceNear` walks a fixed ring of
--- offsets and parks in the first clear one") describes code that no longer
--- does it. With a station ambulance on all 23 points, the case it covered stops
--- being the rare convergence of two rescues and becomes every single rescue.
---
--- THIS IS NOT IsPositionOccupied AND DOES NOT NEED TO BE. The client could only
--- ever ask "is anything there". The server is asking a smaller and exactly
--- answerable question -- "is one of MINE there" -- about vehicles it created and
--- whose coordinates it re-reads every pass. Anything else standing at the point
--- (an ambient car, another player's truck) is the pre-existing case, is not
--- made worse by this feature, and is still the engine's to resolve behind the
--- fade.
---
--- ADOPTING THE PARKED ONE IS NOT AN OPTION, AND NOT BY THIS FILE'S CHOICE.
--- config/rescue.lua argues it out: the ride is scripted -- doors locked, siren
--- on, tint off, maximum upgrades, an NPC at the wheel -- and "EVERY ONE OF
--- THOSE IS A PROPERTY OF A VEHICLE WE MADE". Commandeering a half-wrecked,
--- on-fire, wall-facing parked one makes all of them conditional. That decision
--- stands; this is the small thing that file says is actually needed.
---
--- @param matchId integer|nil
--- @param x number @param y number @param z number
--- @param heading number  the surveyed heading of the point
--- @return number x, number y, number z, boolean moved
function BR.Ambulances.displace(matchId, x, y, z, heading)
    if not enabled() then return x, y, z, false end
    local rec = matchId and live[matchId]
    if not rec then return x, y, z, false end

    local near = (A.occupiedM or 6.0)
    local blocked = false
    for _, s in ipairs(rec.stations) do
        if BR.Dist(s.x, s.y, x, y) <= near then blocked = true break end
    end
    if not blocked then return x, y, z, false end

    -- BEHIND, ALONG THE SURVEYED HEADING. A GTA heading of 0 faces +Y and turns
    -- anticlockwise, so forward is (-sin h, cos h) and behind is (sin h, -cos h).
    -- The z is the surveyed one: eight metres along a car park is the same
    -- ground, and the point was walked rather than picked off a map.
    local rad = math.rad(heading or 0.0)
    local d = A.standAsideM or 8.0
    return x + math.sin(rad) * d, y - math.cos(rad) * d, z, true
end

--- How many station ambulances a match has standing. Read by /brambulances and
--- by the tests.
--- @param matchId integer|nil
--- @return integer
function BR.Ambulances.count(matchId)
    local rec = matchId and live[matchId]
    if not rec then return 0 end
    return #rec.stations
end

--- Is this vehicle one of the 23 this file made for this match?
---
--- ASKED BY server/rescue.lua's `noteVehicle`, WHICH IS THE WHOLE REASON IT
--- EXISTS. The owner asked for the found list to hold "engine-spawned ones"; a
--- squadmate who drives a STATION ambulance would otherwise be recorded as a
--- find, and the same van would then be published twice -- once as `s:<entity>`
--- and once as `v:<entity>`. The client keys its blips on that string and would
--- draw both, which is a map saying there are two ambulances where there is one.
---
--- A WALK RATHER THAN A SET, and it is 23 comparisons on a table this file
--- already owns. It runs only when a player is driving a vehicle whose model is
--- an ambulance and which the ledger has not seen before -- which is once per
--- ambulance per match, not per sample.
--- @param matchId integer|nil
--- @param veh integer|nil
--- @return boolean
function BR.Ambulances.isStation(matchId, veh)
    if not matchId or not veh then return false end
    local rec = live[matchId]
    if not rec then return false end
    for _, s in ipairs(rec.stations) do
        if s.veh == veh then return true end
    end
    return false
end

--- Everything the console needs, for one match.
--- @param matchId integer|nil
--- @return table|nil
function BR.Ambulances.stats(matchId)
    local rec = matchId and live[matchId]
    if not rec then return nil end
    local watching = 0
    for _, id in pairs(showing) do
        if id == matchId then watching = watching + 1 end
    end
    local found = 0
    for _ in pairs(rec.ambient) do found = found + 1 end
    return {
        bucket    = rec.bucket,
        up        = #rec.stations,
        planned   = #rec.pending,
        built     = rec.next - 1,
        refused   = rec.refused,
        tearing   = rec.tearing == true,
        attempts  = rec.attempts,
        watching  = watching,
        -- HOW MANY AMBULANCES THE ROUND HAS DISCOVERED. Printed because it is
        -- otherwise unobservable: the owner's map shows the 23 and the finds as
        -- one undifferentiated set of icons, on purpose, so the console line is
        -- the only place the split is visible.
        found     = found,
    }
end

-- ---------------------------------------------------------------------------
-- Admin
-- ---------------------------------------------------------------------------

--- Where the station ambulances are, and who can see them.
---
--- THE OWNER HAS REPORTED "our ambulances aren't spawning still" THREE TIMES,
--- and on each of those rounds nothing on either side could say whether the
--- answer was "none were built", "they were built in the wrong bucket" or "they
--- are there and nobody is being sent a blip". Those are three different bugs
--- that print the same nothing. Same move as /brcpr and /brshop, which each
--- found a multi-round bug in one run.
RegisterCommand('brambulances', function(src)
    if tonumber(src) ~= 0 then return end   -- console only

    if not enabled() then
        print('[br_core] ambulances: disabled in config')
        return
    end

    local any = false
    BR.Server.eachMatch(function(m)
        any = true
        local s = BR.Ambulances.stats(m.id)
        if not s then
            print(('[br_core] ambulances: match %d (%s) -- no set yet; doors %s')
                :format(m.id, tostring(m.state),
                        doorsOpen(m) and 'ARE open' or 'are not open'))
            return
        end
        print(('[br_core] ambulances: match %d (%s) -- %d up of %d planned '
               .. '(%d built, %d refused) in bucket %d, %d found; %d player(s) '
               .. 'watching%s')
            :format(m.id, tostring(m.state), s.up, s.planned, s.built,
                    s.refused, s.bucket, s.found, s.watching,
                    s.tearing and (', tearing down, pass ' .. s.attempts) or ''))

        local rec = live[m.id]
        for _, st in ipairs(rec.stations) do
            print(('    %-14s veh %-6d net %-6s %.1f, %.1f')
                :format(tostring(st.id or '?'), st.veh, tostring(st.netId),
                        st.x, st.y))
        end
        -- THE FOUND ONES, NAMED BY THEIR BLIP KEY. There is no surveyed id to
        -- print -- nobody authored these -- and the key is what would be matched
        -- against a report that a blip is pointing at nothing.
        for key, f in pairs(rec.ambient) do
            print(('    %-14s %-13s %.1f, %.1f')
                :format('(found)', key, f.x, f.y))
        end
    end)

    if not any then print('[br_core] ambulances: no matches running') end
end, true)
