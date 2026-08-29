-- The CPR kit's rescue, server side (#191).
--
-- The server owns four things and deliberately owns nothing else: whether a
-- rescue may START, WHERE it goes, whether it is making PROGRESS, and how it
-- ENDS. The ambulance itself, the ped on the stretcher, the camera and the
-- driving all live on the rescued player's own client, because all four are
-- things only that machine can do.
--
-- ═══ `rescue` IS A SERVER FIELD, AND storm.lua SAID SO FIRST ═══
--
-- server/storm.lua has carried the specification for this flag since before
-- there was anything to write it: the storm-damage exemption is one condition on
-- one filter, `and not e.rescue`, with two prohibitions attached. Both are
-- honoured here and both are worth restating, because they are what make the
-- flag safe rather than merely present:
--
--   * IT IS NEVER CLIENT-ASSERTED. No net event sets it. It is written by
--     `begin` when the server grants a rescue and cleared by `finish` when the
--     server ends one, and there is no third writer. Storm damage is the one
--     subsystem built specifically so a client cannot influence it; an exemption
--     a client could assert would be storm immunity a client could assert.
--   * IT IS NEVER A TEST ON THE VEHICLE. The owner's rule is about the rescue,
--     not about the ambulance -- "if they hop in an ambulance and drive off they
--     are not granted any sort of immunity" -- so nothing here reads a model and
--     the flag is on the PLAYER.
--
-- It is in neither BR.Roster allowlist, for the reason server/roster.lua asks
-- every new field to answer: a client has no use for it (its own client is told
-- it is being rescued by RESCUE_BEGIN, with the whole payload) and the console
-- cannot act on it.
--
-- ═══════════════════════════════════════════════════════════════════════════
-- STUCK VERSUS DESTROYED
-- ═══════════════════════════════════════════════════════════════════════════
--
-- #191 built two recovery layers -- re-place a wedged ambulance, and a hard
-- timeout that delivers regardless -- on a premise that no longer holds:
--
--     "A player locked in a stuck vehicle has left the match without dying --
--      the worst failure this feature can produce."
--
-- That was true when the ambulance was invincible. Since the owner made it
-- destructible (2026-08-23) there is a LEGITIMATE way to leave the match from
-- inside one, and the recovery layers now have to tell the two apart. Get it
-- wrong in one direction and a player is stranded forever; get it wrong in the
-- other and somebody who was properly killed gets driven back into the match.
--
-- THE ANSWER IS NOT A HEURISTIC OVER ONE SIGNAL, because there isn't one: a
-- wreck and a wedged ambulance are both A VEHICLE THAT HAS STOPPED MOVING, and
-- no amount of tuning a threshold separates them. What separates them is WHO CAN
-- OBSERVE WHAT, and the design is to match each consequence to evidence its
-- observer cannot profitably lie about:
--
--   1. DESTROYED, REPORTED BY THE CLIENT (`RESCUE_LOST`).
--      Trusted immediately, and the trust costs nothing: the only thing this
--      report can do is ELIMINATE THE PLAYER WHO SENT IT. A client that lies
--      here kills itself, which is not an exploit, it is a resignation. This is
--      the fast path and it exists so the kill lands while the explosion is
--      still on screen.
--
--      "DESTROYED" NOW INCLUDES A BAD ENOUGH WRECK (owner, 2026-08-23: "if the
--      ambulance gets in a wreck, even if it doesn't blow up... the rescue also
--      failed"). client/rescue.lua's watch reports on this same event when the
--      condition reading falls to BR.Config.Rescue.wreckedAtPct, so a crippled
--      ambulance SHORT-CIRCUITS layers 2 and 3 instead of being teleported onto
--      a road and told to drive on. Nothing on this side changed, and nothing
--      needed to: it is the same message with one more way of earning it, and
--      it still only ever eliminates. A client that declines to send it is
--      exactly the silent client layers 2-4 were built for.
--
--   2. NO PROGRESS, OBSERVED BY THE SERVER.
--      Judged on BR.Roster's own position samples of the player's ped -- read
--      server-side with GetEntityCoords, never reported -- so it is the same
--      evidence the storm and the anti-cheat already run on. Consequence: ORDER
--      A RE-PLACE. Deliberately the weakest consequence, because it is the one
--      a dishonest client would want: and all it wins is a teleport the server
--      was about to grant anyway.
--
--   3. STILL NO PROGRESS AFTER `maxRecoveries` RE-PLACES, OBSERVED BY THE
--      SERVER. Consequence: ELIMINATE.
--      THIS IS THE DISCRIMINATOR, and it is the reason this scheme works without
--      trusting anybody. A re-place puts a WORKING ambulance back on a road, and
--      a working ambulance then moves. An ambulance that has been re-placed
--      three times and has still never moved is not stuck -- there is nothing
--      there to re-place. A client cannot manufacture progress it is not making,
--      and a wreck can never be re-placed into motion, so this catches exactly
--      the case layer 1 was supposed to report and did not.
--
--   4. THE DEADLINE EXPIRES. Consequence: DELIVER, BUT ONLY IF THE SERVER EVER
--      SAW IT MOVE.
--      #191's hard timeout, with the one condition the destructibility reversal
--      forces on it. A rescue that made progress and then ran late is a slow
--      drive and gets delivered, which is what the timeout is for. A rescue that
--      never moved at all was never driving, and delivering it would be the
--      resurrection this whole section exists to prevent.
--
-- THE INVARIANT, and it is the thing to preserve if any of this is ever
-- retuned: DELIVERY REQUIRES POSITIVE EVIDENCE THAT THE AMBULANCE WAS DRIVING.
-- Elimination is what every ambiguous case resolves to. That is the safe
-- direction, because the owner's rule is that a destroyed ambulance kills you --
-- so a mistake that eliminates costs one player one match, and a mistake that
-- delivers hands a player a second life that another player had already taken
-- off them.
--
-- AND NOTHING IS EVER LEFT RUNNING. Every one of the four paths above ends the
-- rescue and clears `rescue`, and the deadline is checked unconditionally, so
-- there is no branch on which a player stays flagged, storm-exempt and airborne
-- in a state nothing will resolve. "Stranded forever" is not defended against by
-- a rule; it is unreachable because `finish` is the only exit and the deadline
-- always arrives at it.

BR = BR or {}
BR.Rescue = {}

local R = BR.Config.Rescue

--- Rescues in flight. [src] = record.
---
---   matchId      the match this belongs to, so teardown is per-match
---   dest         { x, y, z, heading } where they are being taken
---   deadlineAt   server ms; the hard timeout, derived per route
---   lastPos      { x, y } at the previous judgement
---   lastMoveAt   server ms the ambulance was last seen to have moved
---   recoveries   how many re-places have been ordered
---   everMoved    has the server EVER seen progress -- the delivery gate
local live = {}

BR.Rescue.live = live

--- Publish where this rescue is, or that it is over.
---
--- ═══ THE AMBULANCE IS THE PLAYER, AND THAT IS WHY THIS COSTS NOTHING ═══
---
--- Owner, 2026-08-23: "if someone takes it, we need to update it's location on
--- the map for other players when their blips are shown."
---
--- There is no second position to track. The rescued player is ATTACHED to the
--- stretcher, so their ped and the ambulance are at the same coordinates by
--- construction -- and BR.Roster already samples every player's position
--- server-side, four times a second, with GetEntityCoords. So the ambulance's
--- position is `entry.pos`: already sampled, already server-authoritative,
--- already impossible for a client to forge, and free.
---
--- The alternative -- asking the owning client where its ambulance is -- would
--- have been a client-reported position feeding a blip other players hunt by,
--- which is a way to be un-findable by lying. This cannot be lied about at all.
---
--- COORDINATES RATHER THAN AN ENTITY, for the reason client/squadmates.lua
--- records: an entity blip dies at the scope ceiling and an ambulance crossing
--- the map is exactly that case.
--- @param m table|nil    the match to publish into
--- @param key string     opaque; `r:<src>` for a rescue, `v:<entity>` for a find
--- @param x number|nil
--- @param y number|nil
local function pushBlip(m, key, x, y)
    local b = R and R.blip
    if not b or not b.enabled or b.audience == 'none' then return end
    if not m then return end

    if not x or not y then
        BR.Broadcast.toMatch(m, BR.Net.RESCUE_BLIP, { key = key, gone = true })
        return
    end
    BR.Broadcast.toMatch(m, BR.Net.RESCUE_BLIP, { key = key, x = x, y = y })
end

--- @param src integer
--- @param entry table|nil
--- @param rec table|nil
--- @param gone boolean
local function publishBlip(src, entry, rec, gone)
    local m = rec and rec.matchId and BR.Server.matches[rec.matchId]
    local pos = (not gone) and entry and entry.pos or nil
    if not gone and not pos then return end
    pushBlip(m, 'r:' .. tostring(src), pos and pos.x, pos and pos.y)
end

--- What to call a point in a log line.
---
--- THE SURVEYED POINTS CARRY AN `id` SINCE 2026-08-28 and this prints it. It
--- said the opposite until then -- "inventing one here would not match whatever
--- he named them later" -- and the cost of being right about that was a console
--- line reading `pickup=nil  dest=nil` beside two pairs of coordinates on the
--- first ride that ever worked.
---
--- THE FALLBACK STAYS. A row without an id is still legal (config/rescue.lua's
--- own `points` table has no ids and is the empty-config path), and coordinates
--- are the honest identifier for one: they are what somebody would search
--- config/map.lua for.
--- @param p table|nil
--- @return string
local function pointName(p)
    if not p then return 'nowhere' end
    if p.id then return tostring(p.id) end
    return ('(%.0f, %.0f)'):format(p.x or 0.0, p.y or 0.0)
end

--- Which slot holds a CPR kit, or nil.
---
--- FIRST MATCH WINS, low slot first, and the order is fixed rather than a pairs()
--- walk: two servers replaying the same match must consume the same slot.
--- @param src integer
--- @return integer|nil
local function kitSlot(src)
    local inv = BR.Inv and BR.Inv.of(src)
    if not inv then return nil end
    for i = 1, (BR.Config.Loot.slots or 5) do
        local s = inv.slots[i]
        if s and s.item == 'cprkit' then return i end
    end
    return nil
end

--- Is this player one the kit could work for RIGHT NOW?
---
--- SOLO IS ASKED HERE AND IN server/combat.lua, and that is not a duplicate
--- ruling -- they are two different questions a beat apart. combat.lua asks "may
--- this player be knocked down instead of killed", at the moment of the killing
--- blow. This asks "may this downed player call an ambulance", at the moment
--- they press the key. A squad player is downed by the first and refused by the
--- second, which is exactly right: squads have revives, and the kit is solos
--- only (owner, 2026-08-23).
--- @param entry table|nil
--- @return boolean
--- @return string|nil why   for /brrescue, never for a player
function BR.Rescue.canCall(entry)
    if not R or not R.enabled then return false, 'disabled' end
    if not entry then return false, 'no entry' end
    if entry.state ~= BR.PlayerState.DBNO then return false, 'not downed' end
    if live[entry.src] then return false, 'already being rescued' end

    local m = entry.matchId and BR.Server.matches[entry.matchId]
    if not m or m.state ~= BR.MatchState.PLAYING then return false, 'no live match' end
    if BR.ResolveMode(m.mode).key ~= BR.Mode.SOLO.key then
        return false, 'squads have revives; the kit is solos only'
    end
    if not kitSlot(entry.src) then return false, 'no kit' end
    if #BR.Config.Rescue.Points() == 0 then
        return false, 'no pickup/drop-off points are configured'
    end
    return true
end

--- Does this player hold a kit that would change what their death means?
---
--- THE ONE QUESTION server/combat.lua ASKS OF THIS FILE, and it is asked BEFORE
--- any health is written -- BR.Damage.applyHit needs the answer to decide how
--- much damage to instruct the victim's own ped to take. So it must be cheap,
--- must not allocate, and must not depend on anything that only exists after the
--- knock has happened.
---
--- IT DOES NOT CHECK THE MODE. Its caller does, immediately before, because the
--- mode's own `dbno` flag is the first gate there and reading it twice in two
--- files is how the two come to disagree.
--- @param entry table|nil
--- @return boolean
function BR.Rescue.holdsKit(entry)
    if not R or not R.enabled then return false end
    if not entry or not entry.src then return false end
    return kitSlot(entry.src) ~= nil
end

--- End a rescue, whichever way it went.
---
--- THE ONLY EXIT, and every path is routed through it so that clearing `rescue`
--- cannot be forgotten on one of them. It clears the flag FIRST, before anything
--- that could fail or yield, because a player left flagged is a player the storm
--- has stopped being able to touch.
--- @param src integer
--- @param delivered boolean
--- @param why string   for the log
local function finish(src, delivered, why)
    local rec = live[src]
    live[src] = nil
    if not rec then return end

    -- THE SERVER OWNS THE VEHICLE NOW, so the server deletes it -- on every
    -- ending, before anything below can fail or return early. The client used
    -- to do this because the client used to create it; leaving it there would
    -- mean a disconnect mid-ride abandons an ambulance nothing owns.
    -- `== true` rather than a truth test, the same reason this file already
    -- records where it sweeps destroyed ambulances: DoesEntityExist is a BOOL
    -- native, may answer 1 or 0, and 0 is truthy in Lua.
    if rec.veh then
        local okEx, exists = pcall(DoesEntityExist, rec.veh)
        if okEx and (exists == true or exists == 1) then
            pcall(DeleteEntity, rec.veh)
        end
    end

    local entry = BR.Roster.get(src)
    if entry then
        BR.Roster.update(src, { rescue = nil })
        entry.rescue = nil
    end

    -- TAKE THE BLIP DOWN FIRST, on every ending. A blip left behind is a red
    -- ambulance icon sitting on the map for the rest of the match, and the
    -- players who rotate to it find nothing -- which is worse than never having
    -- shown it.
    publishBlip(src, entry, rec, true)

    if not delivered then
        print(('[br_core] rescue: %d is out -- %s'):format(src, why))

        -- TELL THE CLIENT FIRST, AND TELL IT ON THE DEATH PATH TOO. The ride is
        -- a scripted camera over a ped attached to a vehicle, and only the
        -- client can take any of that down. Ending the rescue server-side
        -- without saying so would leave the camera pointed at a burning wreck
        -- until the client's own sanity sweep noticed a second later -- which is
        -- a second of the player watching the wrong thing, and then a hard cut
        -- instead of a fade. `delivered = false` means "tear down, do not place".
        TriggerClientEvent(BR.Net.RESCUE_END, src, { delivered = false })

        -- ELIMINATE, NOT DEFEAT. defeat() would ask canBeDowned() again, which
        -- for a solo holding a second kit would answer "knock them down" -- and
        -- a player who has just been blown up in an ambulance would be handed
        -- another ambulance. The rescue is the exit from DBNO, not a way back
        -- into it.
        BR.Combat.eliminate(src, 'rescue', nil)
        return
    end

    if not entry or entry.state ~= BR.PlayerState.DBNO then return end

    print(('[br_core] rescue: %d delivered to %s (%s)')
        :format(src, pointName(rec.dest), why))

    -- BACK ON THEIR FEET WITH THEIR HEALTH, through the one function every
    -- revive in this game goes through. The third argument is this feature's
    -- own health: a squad revive hands back `dbnoReviveHp` because a mate spent
    -- eight seconds standing over you and the fight is still going on around
    -- them, whereas the kit is an ULTRA-RARE item that has been spent in full
    -- and #191 says "health restored". Reusing revive() rather than writing the
    -- state transition again is what keeps the undo complete -- the bleed
    -- deadline, the owed kill and the client's downed mirror are all cleared
    -- there and would each be a separate thing to forget here.
    BR.Combat.revive(src, nil, R.deliverHp or 100)

    -- The client does the placing; the server says where. Same contract as
    -- BUS_JUMP_OK, and for the same reason -- the server cannot write a ped.
    TriggerClientEvent(BR.Net.RESCUE_END, src, {
        delivered = true,
        x = rec.dest.x, y = rec.dest.y, z = rec.dest.z,
        heading = rec.dest.heading or 0.0,
    })
end

BR.Rescue.finish = finish

--- Start one.
--- @param src integer
--- @return boolean
function BR.Rescue.begin(src)
    local entry = BR.Roster.get(src)
    local ok = BR.Rescue.canCall(entry)
    if not ok then return false end

    local slot = kitSlot(src)
    if not slot then return false end

    local pos = entry.pos
    if not pos then return false end

    local points = BR.Config.Rescue.Points()
    local m = BR.Server.matches[entry.matchId]
    local now = GetGameTimer()

    -- WHERE IT COMES FROM: nearest authored point to where they went down.
    local pickup = BR.RescueNearest(points, pos.x, pos.y)
    if not pickup then return false end

    -- WHERE IT GOES: solved against the circle as it will be ON ARRIVAL *and*
    -- against the purple circle the storm is shrinking toward. See
    -- shared/rescue_solve.lua for why neither one implies the other.
    local dest, dist, inside =
        BR.RescueDestination(points, pickup.x, pickup.y, m.storm, now, R, pickup)

    -- ═══ NO QUALIFYING POINT IS A REFUSAL, AND THE KIT SURVIVES IT ═══
    --
    -- Owner, 2026-08-28: "If no destinations are available within the PURPLE
    -- storm circle - then cprkits are not available for use."
    --
    -- THE KIT IS SAFE HERE BY POSITION, NOT BY LUCK, and it is worth stating
    -- because the item is ultra-rare and the failure would be unrecoverable:
    -- BR.Inv.take is thirty lines BELOW this return, after every refusal in this
    -- function. A `begin` that answers false has spent nothing, written nothing
    -- to the roster and told no client anything -- the player is simply still
    -- downed, still holding their kit, and still able to press the key again
    -- when the circle moves. tools/test_rescue.lua asserts exactly that, because
    -- "the refusal happens before the take" is a property of an ORDERING and
    -- orderings are what edits change without noticing.
    --
    -- IT SAYS SO IN THE CONSOLE. Nothing is shown to the PLAYER -- this feature
    -- has one notification and a refusal toast would be a second -- but a rescue
    -- that declines to start is otherwise indistinguishable from a keypress that
    -- did not register, which is the report we would get back.
    if not dest then
        print(('[br_core] rescue: %d refused -- no surveyed point is inside the '
               .. 'next circle (pickup %s, %d points, storm phase %s)')
            :format(src, pointName(pickup), #points,
                    tostring(m.storm and m.storm.phase)))
        return false
    end

    -- ═══ IT SAYS WHERE IT IS TAKING THEM, BECAUSE READING SAID IT CANNOT ═══
    --
    -- Owner, 2026-08-28: "the waypoint is actually the spawn point of the
    -- ambulance, not it's destination, and once I do respawn I am taken to the
    -- ambulance's spawn point. Are you even telling the driver where to go?"
    --
    -- Every reading of the code says this is impossible: taskDrive uses
    -- r.dest, the delivery uses the coordinates this function sends, and
    -- RescueDestination skips any candidate within minTripM -- which a pickup
    -- at zero metres from itself always is. So the reading is wrong somewhere,
    -- and a fifth guess costs another playtest.
    --
    -- Same move as /brcpr, which found a three-round bug in one run: print the
    -- two ids and the distance between them. If they are the same point the
    -- exclusion is not biting; if they differ, the fault is downstream of here
    -- and this line clears the solver in one glance.
    print(('[br_core] rescue: %d  pickup=%s (%.1f, %.1f)  dest=%s (%.1f, %.1f)  %.0fm apart%s')
        :format(src, tostring(pickup.id), pickup.x, pickup.y,
                tostring(dest.id), dest.x, dest.y,
                BR.Dist(pickup.x, pickup.y, dest.x, dest.y),
                (pickup == dest) and '  <-- SAME POINT' or ''))

    -- THE KIT IS SPENT HERE, at the moment the rescue is granted and after every
    -- refusal above has already passed. Spending it earlier would burn an
    -- ultra-rare item on a call that then failed to route; spending it later
    -- leaves a window in which the same kit could start a second rescue.
    BR.Inv.take(src, slot)
    BR.Inv.push(src)

    local deadline = BR.RescueDeadlineMs(dist, R)

    -- ═══ THE SERVER MAKES THE AMBULANCE, NOT THE CLIENT ═══
    --
    -- It was a client-side networked CreateVehicle call until 2026-08-28, and
    -- the owner's run showed what that is worth: no ambulance, a camera at the
    -- right coordinates pointing at nothing, and a 'you have been revived'
    -- toast at the end. CreateVehicle answers 0 when it is refused and 0 is
    -- truthy, so nothing downstream noticed.
    --
    -- CreateVehicleServerSetter is the documented route here (see the long
    -- write-up above brcar in server/vehicles.lua). It builds the sync tree and
    -- registers the entity BEFORE minting the handle, so what comes back is a
    -- real entity: SetEntityRoutingBucket works on it at once, with no polling
    -- and no throw, and it needs no player in scope.
    --
    -- THE ROUTING BUCKET IS THE SECOND WAY TO GET AN INVISIBLE AMBULANCE, and
    -- it is not the one that bit him. Matches run in their own buckets and the
    -- setter defaults to bucket 0, so a vehicle left there is one nobody in the
    -- match can see -- the same failure wearing different clothes.
    --
    -- THE TYPE ARGUMENT THROWS on an unrecognised value rather than answering
    -- 0, which is why the call is pcall'd rather than tested.
    -- ═══ THE SERVER DOES NOT MAKE THE AMBULANCE, AND 424 METRES IS WHY ═══
    --
    -- It did, for one round, with CreateVehicleServerSetter. The owner got:
    -- "net id 65534 never resolved to an ambulance here".
    --
    -- 65534 WAS NOT THE BUG. The server allocates object ids DOWNWARD from
    -- MaxObjectId - 1 under OneSync (ServerGameState.cpp CreateEntityFromTree),
    -- so 65534 is exactly what the first server-created entity gets. Clients
    -- count up from 1. The id was correct and so was the conversion.
    --
    -- THE BUG WAS SCOPE. Relevancy is per-client and, for an EMPTY vehicle, is
    -- pure 2D distance -- default radius 424m, onesync_distanceCulling on. The
    -- 23 surveyed rescue points average 825m from an arbitrary map position and
    -- 81.7% of the map is further than 424m from the nearest one. So for about
    -- four downed players in five the ambulance was created outside their
    -- scope, never cloned to them, and NetworkDoesNetworkIdExist answered false
    -- honestly for the full five seconds -- while the player lay where they
    -- fell, up to 2.4km away, because they are only attached to it later.
    --
    -- No platform bug was needed to explain it, and no amount of waiting would
    -- have fixed it.
    --
    -- SO IT IS LOCAL NOW, LIKE EVERY OTHER VEHICLE THIS GAMEMODE MAKES.
    -- client/bus.lua already performs this exact ride -- local vehicle, local
    -- pilot, the player's own ped attached to it, scripted camera, driven by
    -- the script -- and says why: "nothing here is synced". Scope, buckets,
    -- cloning, ownership and entityLockdown all stop being able to fail.
    --
    -- THE COST, NAMED: only the rescued player can destroy their own ambulance.
    -- The rule survives -- their own wreck and condition watch still fire
    -- RESCUE_LOST -- but a third party cannot shoot it. That is the single
    -- requirement that moved this feature off every path this codebase has
    -- working, and it is now a deliberate trade rather than an inherited one.
    live[src] = {
        matchId    = entry.matchId,
        dest       = dest,
        deadlineAt = now + deadline,
        lastPos    = { x = pos.x, y = pos.y },
        lastMoveAt = now,
        recoveries = 0,
        everMoved  = false,
    }

    -- THE FLAG. Written here and read in exactly one place -- storm.lua's
    -- damage filter.
    BR.Roster.update(src, { rescue = true })

    print(('[br_core] rescue: %d picked up at %s, bound for %s (%.0fm, %s, deadline %.0fs)')
        :format(src, pointName(pickup), pointName(dest), dist,
                inside and 'inside the arrival circle AND the next one'
                    or 'no storm published, so no circle to be inside of',
                deadline / 1000.0))

    TriggerClientEvent(BR.Net.RESCUE_BEGIN, src, {
        pickup = pickup,
        dest   = dest,
        endsAt = now + deadline,
    })
    return true
end

-- ---------------------------------------------------------------------------
-- The client's two reports
-- ---------------------------------------------------------------------------

--- "Press [interact key] to call a medic."
---
--- THE ONLY THING A PLAYER EVER SENDS THIS FEATURE, and it carries no payload on
--- purpose -- there is nothing about a rescue a client could tell the server
--- that the server should believe. Every parameter of the ride is decided above.
RegisterNetEvent(BR.Net.RESCUE_CALL)
AddEventHandler(BR.Net.RESCUE_CALL, function()
    BR.Rescue.begin(source)
end)

--- The ambulance is a wreck.
---
--- Trusted on sight, because of what it can and cannot do: it can only
--- eliminate the player who sent it. See layer 1 of the scheme at the top.
RegisterNetEvent(BR.Net.RESCUE_LOST)
AddEventHandler(BR.Net.RESCUE_LOST, function()
    local src = source
    if not live[src] then return end
    finish(src, false, 'the client reported the ambulance destroyed')
end)

--- It got there.
---
--- The client is the only party that can see the ambulance reach the parking
--- spot, so it says when. THIS ONE IS CHECKED, unlike the wreck report, because
--- it asks for something worth having: `everMoved` must be set, which means the
--- SERVER has independently watched the ambulance travel. A client that sends
--- this the instant the ride begins gets nothing -- the rescue simply carries on
--- and is resolved by the deadline like any other.
RegisterNetEvent(BR.Net.RESCUE_ARRIVED)
AddEventHandler(BR.Net.RESCUE_ARRIVED, function()
    local src = source
    local rec = live[src]
    if not rec then return end
    if not rec.everMoved then return end
    finish(src, true, 'arrived')
end)

-- ---------------------------------------------------------------------------
-- The judgement
-- ---------------------------------------------------------------------------

BR.Sched.every(R and R.tickMs or 1000, 'rescue.tick', function()
    if not R or not R.enabled then return end
    local now = GetGameTimer()

    for src, rec in pairs(live) do
        local entry = BR.Roster.get(src)
        local m = rec.matchId and BR.Server.matches[rec.matchId]

        -- GONE, OR NO LONGER DOWNED, OR THE MATCH ENDED UNDER THEM. All three
        -- are the rescue being over by something else's decision, and none of
        -- them is this file's to overturn: clear the flag and leave the state
        -- alone. `finish` is not used because there is nothing to deliver and
        -- nobody to eliminate -- the player is already dead, already revived, or
        -- already gone.
        if not entry or entry.state ~= BR.PlayerState.DBNO
           or not m or m.state ~= BR.MatchState.PLAYING then
            live[src] = nil
            if entry then
                BR.Roster.update(src, { rescue = nil })
                entry.rescue = nil
            end
            publishBlip(src, entry, rec, true)
            goto continue
        end

        do
            -- The map follows the ambulance. Published at this tick's cadence,
            -- which is also the rate the blip needs -- a vehicle blip that
            -- updates once a second reads as smooth on a minimap, and anything
            -- faster is a broadcast to the whole match for no visible gain.
            publishBlip(src, entry, rec, false)

            local pos = entry.pos
            if pos then
                if BR.RescueMoved(rec.lastPos, pos, R) then
                    rec.lastPos    = { x = pos.x, y = pos.y }
                    rec.lastMoveAt = now
                    rec.everMoved  = true
                end
            end

            local stalled = now - rec.lastMoveAt

            -- LAYER 4 FIRST, because a deadline that has passed is not a stuck
            -- vehicle worth recovering -- ordering a re-place on the tick the
            -- ride was due to be over would restart a journey with no time left
            -- to run it.
            if now >= rec.deadlineAt then
                if rec.everMoved then
                    finish(src, true, 'the deadline expired on a rescue that was driving')
                else
                    -- Never moved, never reported, out of time. Layer 4's one
                    -- condition: there is no evidence an ambulance was ever
                    -- driving, so there is nothing to deliver.
                    finish(src, false,
                        'the deadline expired and the ambulance never moved at all')
                end
                goto continue
            end

            if stalled >= (R.stuckAfterMs or 5000) then
                if rec.recoveries >= (R.maxRecoveries or 3) then
                    -- LAYER 3. Re-placed to the limit and still motionless:
                    -- there is nothing there to re-place.
                    finish(src, false, ('no movement across %d re-places -- the ambulance is gone')
                        :format(rec.recoveries))
                    goto continue
                end

                -- LAYER 2. Order a re-place and restart the stall clock, so a
                -- vehicle that wedges again is recovered again rather than
                -- being re-ordered every tick.
                rec.recoveries = rec.recoveries + 1
                rec.lastMoveAt = now
                print(('[br_core] rescue: %d has not moved in %.1fs -- ordering re-place %d/%d')
                    :format(src, stalled / 1000.0, rec.recoveries, R.maxRecoveries or 3))
                TriggerClientEvent(BR.Net.RESCUE_PLACE, src, {
                    distM = R.replaceDistM or 15.0,
                })
            end
        end

        ::continue::
    end
end)

-- ═══════════════════════════════════════════════════════════════════════════
-- AMBIENT AMBULANCES
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Owner, 2026-08-23: "There will also be ambulances around the map which spawn
-- naturally. If a player gets into one that we weren't aware of, add it to our
-- list of blips."
--
-- ═══ WHY "IF A PLAYER GETS INTO ONE" IS THE ONLY POSSIBLE TRIGGER ═══
--
-- Ambient traffic is created by CLIENTS, as population. This server has no
-- knowledge of it at all: it cannot enumerate it, cannot read its coordinates,
-- and cannot blip it. An ambulance parked outside a hospital that nobody has
-- touched is, from here, indistinguishable from an ambulance that does not
-- exist.
--
-- A PLAYER SITTING IN ONE IS THE MOMENT THAT CHANGES. The vehicle becomes a
-- networked entity with a server-visible occupant, and the occupant is somebody
-- this server already samples four times a second. So the owner's rule is not a
-- convenience -- it is the only hook available, and no amount of work anywhere
-- else would find these vehicles earlier.
--
-- ═══ AND THE SUPPLY IS SMALLER THAN THE MAP SUGGESTS ═══
--
-- The world clock is pinned to high noon permanently. Several of GTA's ambulance
-- population points are time-gated to evening and night, so those spawns never
-- fire at all. Nothing here is sized on ambient ambulances being available: the
-- authored station points are the backbone, this is a bonus, and a match in
-- which none is ever discovered is the expected case rather than a fault.
--
-- ═══ THREE DECISIONS, WRITTEN DOWN ═══
--
--   1. WHAT COUNTS. The model, against the same list the rescue's own ambulance
--      is built from (config/rescue.lua `models`), so "an ambulance" means one
--      thing across the whole feature. One model today.
--
--   2. THE BLIP OUTLIVES THE DRIVER. A player getting out does NOT take it down,
--      and that is the more useful of the two rules rather than the lazier one:
--      the question a blip answers is "is there an ambulance there", and an
--      abandoned one still answers yes. A marker that vanished the moment
--      somebody stepped out would also be a strange thing to explain -- the
--      vehicle is still sitting there in plain sight.
--
--   3. THEY DO NOT JOIN THE AUTHORED POINTS. Discovered ambulances are blips and
--      nothing else; BR.Config.Rescue.Points() never sees them. A rescue needs a
--      place an ambulance can STAND AND DRIVE FROM -- authored, on a road,
--      known-good -- and a vehicle abandoned halfway up a mountain is not one.
--      It would also be an exploit shaped exactly like the game inviting it:
--      park an ambulance somewhere terrible and rescues start routing there.
--      The rescue builds its own vehicle at its own point and never uses one of
--      these.

--- Ambulances a player has been seen driving. [entity] = { x, y, matchId }
---
--- KEYED ON THE SERVER'S ENTITY HANDLE, which is what makes the lifetime
--- question answerable: once a vehicle is networked this server can ask whether
--- it still exists, and a blip pointing at a wreck or a streamed-out vehicle is
--- worse than no blip at all.
local found = {}

--- Model hashes that count, resolved once on first use.
---
--- LAZILY RATHER THAN AT LOAD, because config/rescue.lua is a shared file and
--- GetHashKey is not available in every state that loads it -- config/vehicles.lua
--- writes its hashes out as literals for the same reason. Resolving here keeps
--- the magic numbers out of the config without paying for them per sample.
local modelSet = nil
local function isAmbulanceModel(model)
    if modelSet == nil then
        modelSet = {}
        for _, name in ipairs((R and R.models) or { 'ambulance' }) do
            local h = BR.NormHash(GetHashKey(name))
            if h then modelSet[h] = true end
        end
    end
    return modelSet[BR.NormHash(model)] == true
end

--- A player is driving this vehicle. Is it an ambulance we did not know about?
---
--- CALLED FROM server/vehicles.lua's EXISTING 4 Hz SEAT READ, with the handle it
--- had already resolved -- so this costs one table lookup per driver per sample
--- on the ordinary path, and a model read only for a vehicle that is new to it.
--- Adding a second per-tick vehicle scan to find the same thing would have been
--- the obvious way and is pure duplicated cost.
--- @param src integer
--- @param entry table
--- @param veh integer|nil
function BR.Rescue.noteVehicle(src, entry, veh)
    if not R or not R.enabled then return end
    if not veh or veh == 0 then return end
    if found[veh] then return end
    if not entry or not entry.matchId then return end

    local okModel, model = pcall(GetEntityModel, veh)
    if not okModel or not isAmbulanceModel(model) then return end

    local pos = entry.pos
    found[veh] = {
        x = pos and pos.x or 0.0,
        y = pos and pos.y or 0.0,
        matchId = entry.matchId,
    }
    print(('[br_core] rescue: found an ambient ambulance (entity %d), %d was driving it')
        :format(veh, src))
end

--- Keep the found ones honest.
---
--- TWO JOBS, AND THE SECOND IS THE ONE THAT MATTERS. Moving the blip is
--- cosmetic; REMOVING one whose vehicle has stopped existing is what stops the
--- map filling up with markers for ambulances that were destroyed, streamed out
--- or cleaned up by the engine. A blip nobody can act on is worse than none.
BR.Sched.every(R and R.tickMs or 1000, 'rescue.found', function()
    if not R or not R.enabled then return end

    for veh, rec in pairs(found) do
        local m = rec.matchId and BR.Server.matches[rec.matchId]
        local okExists, alive = pcall(DoesEntityExist, veh)

        -- `== true` RATHER THAN A TRUTH TEST. DoesEntityExist is a BOOL native
        -- and may answer 1 or 0; `0` is truthy in Lua, so a bare test would keep
        -- every destroyed ambulance on the map forever.
        if not m or m.state ~= BR.MatchState.PLAYING
           or not okExists or not (alive == true or alive == 1) then
            found[veh] = nil
            pushBlip(m, 'v:' .. tostring(veh), nil, nil)
        else
            -- STILL TRACKED AFTER THE DRIVER LEAVES, which is the whole point of
            -- reading the VEHICLE rather than the person who was in it. An
            -- abandoned ambulance keeps its blip where it was left, and one
            -- somebody drives away keeps it under them.
            local okPos, c = pcall(GetEntityCoords, veh)
            if okPos and c then rec.x, rec.y = c.x, c.y end
            pushBlip(m, 'v:' .. tostring(veh), rec.x, rec.y)
        end
    end
end)

--- @return integer
function BR.Rescue.foundCount()
    local n = 0
    for _ in pairs(found) do n = n + 1 end
    return n
end

-- ---------------------------------------------------------------------------
-- Admin
-- ---------------------------------------------------------------------------

--- Why can this player not call a medic?
---
--- The refusal reasons exist for THIS COMMAND AND NOWHERE ELSE. Nothing in this
--- feature ever tells a player anything: the single "press [key] to call a
--- medic" prompt is the only thing shown in the whole cycle, and a refusal toast
--- would be a second one.
RegisterCommand('brrescue', function(src, args)
    local target = tonumber(args and args[1]) or (tonumber(src) ~= 0 and tonumber(src) or nil)
    if not target then
        print('usage: brrescue <serverId>')
        return
    end

    local entry = BR.Roster.get(target)
    local ok, why = BR.Rescue.canCall(entry)
    local rec = live[target]

    print(('[br_core] rescue %d: canCall=%s%s, points=%d, inFlight=%s')
        :format(target, tostring(ok), ok and '' or (' (' .. tostring(why) .. ')'),
                #BR.Config.Rescue.Points(), tostring(rec ~= nil)))

    if rec then
        print(('    dest=%s deadline in %.1fs recoveries=%d everMoved=%s')
            :format(pointName(rec.dest),
                    (rec.deadlineAt - GetGameTimer()) / 1000.0,
                    rec.recoveries, tostring(rec.everMoved)))
    end

    if ok and tonumber(src) == 0 then
        print('    starting one')
        BR.Rescue.begin(target)
    end
end, true)
