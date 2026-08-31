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

--- Delivered ambulances nobody owns any more. [entity] = matchId.
---
--- ═══ "NOTHING ACCUMULATES" NEEDS A KEEPER NOW THAT SOMETHING IS LEFT ═══
---
--- The owner asked for the parked ambulance to survive the delivery -- "so
--- players can take the ambulance" -- and a server-created entity is not
--- reclaimed by any client's population manager the way a local one is. So the
--- promise config/rescue.lua makes ("a station that is emptied and refilled
--- repeatedly must not end a match with a queue of ambulances in it") stops
--- being kept by `finish` and has to be kept here instead.
---
--- SWEPT ON THE MATCH, NOT ON A TIMER. An abandoned ambulance is a legitimate
--- vehicle for the rest of the match -- deleting it out from under whoever is
--- driving it would be worse than leaving it -- so the only safe moment is when
--- the match it belongs to is over. That is the same rule `found` above uses for
--- ambient ambulance blips, and it runs on the same tick.
local abandoned = {}

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
--- ONE CALLER NOW, AND THE KEY IS STILL A PARAMETER. The ambient finds used to
--- publish through here under `v:<entity>` keys and no longer publish at all
--- from this file (see AMBIENT AMBULANCES, decision 2b); what is left is the
--- rescue in flight. The signature is unchanged because the CLIENT's contract is
--- unchanged -- server/ambulances.lua sends the other two categories on the same
--- event, and the handler that draws all three was written to take an opaque
--- string precisely so that could move.
--- @param m table|nil    the match to publish into
--- @param key string     opaque; `r:<src>` for the rescue in flight
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
---
--- ═══ AND IT NOW SAYS WHAT KIND OF POINT IT IS, BECAUSE THE NAME LIED ═══
---
--- Owner, 2026-08-29: "for some reason you set the destination as a POI?"
---
--- Nothing here has ever read BR.Config.Map.POIs. What he saw was this line
--- printing `dest=senora_n`, and `senora_n` is a row in
--- BR.Config.Map.AmbulanceSpawns whose id was named after the POI beside it --
--- so a surveyed car park wore a POI's name with nothing to say it was not one.
--- The kind is attached to the name now, in one shared place
--- (BR.RescuePointLabel) so every line that names a point says it.
--- @param p table|nil
--- @return string
local function pointName(p)
    return BR.RescuePointLabel(p)
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

    -- ═══ THE PLAYER'S SCOPE COMES BACK FIRST, ON EVERY ENDING ═══
    --
    -- `grant` widens the RESCUED PLAYER's culling radius so the ambulance is
    -- relevant to them and to nobody else, and `rescue.own` narrows it again the
    -- moment ownership settles. A ride that ends before that -- a refusal, a
    -- disconnect, a death, an expired deadline, a match ending under them --
    -- never reaches that narrowing, and a player left at a ten-kilometre radius
    -- is one client being sent every entity in the match for the rest of the
    -- round. It is idempotent, so calling it on the rides that were already
    -- narrowed costs nothing.
    if not rec.widened and SetPlayerCullingRadius then
        pcall(SetPlayerCullingRadius, src, 0.0)
    end

    -- ═══ THE SERVER OWNS THE VEHICLE, SO THE SERVER DECIDES WHETHER IT STAYS
    --     ═══
    --
    -- ON EVERY ENDING EXCEPT A DELIVERY it is deleted, here, before anything
    -- below can fail or return early -- a disconnect mid-ride would otherwise
    -- abandon an ambulance nothing owns.
    --
    -- A DELIVERY LEAVES IT STANDING, which is the owner's whole point: "doors
    -- open, lights on, but nobody inside... so players can take the ambulance".
    -- client/rescue.lua has just parked it, unlocked it and sent the medic
    -- walking, and deleting it a second later would make all of that invisible.
    --
    -- BUT IT IS REMEMBERED. A server-created entity is not culled by anybody's
    -- population manager, so an abandoned one outlives the match unless somebody
    -- writes it down -- see `abandoned` and the sweep below it.
    --
    -- `== true` rather than a truth test, the same reason this file already
    -- records where it sweeps destroyed ambulances: DoesEntityExist is a BOOL
    -- native, may answer 1 or 0, and 0 is truthy in Lua.
    if rec.veh then
        local okEx, exists = pcall(DoesEntityExist, rec.veh)
        if okEx and (exists == true or exists == 1) then
            if delivered then
                -- THE WIDENED CULLING RADIUS COMES OFF WITH THE RIDE. It was
                -- set so a client 825m away would be sent the clone at all, and
                -- the deprecation it buys (citizenfx/fivem #1828: an entity far
                -- from its OWNER but near another player gets teleported back to
                -- its spawn point) was survivable only because the owner was
                -- attached to it. Nobody is attached to it now, so the trade
                -- stops being worth taking and it goes back to the ordinary 424.
                if SetEntityDistanceCullingRadius then
                    pcall(SetEntityDistanceCullingRadius, rec.veh, 0.0)
                end
                abandoned[rec.veh] = rec.matchId
            else
                pcall(DeleteEntity, rec.veh)
            end
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
        -- ═══ AND WHETHER THAT `z` IS WORTH ANYTHING ═══
        --
        -- A surveyed destination's height was measured by standing on it. A
        -- SYNTHESISED one (BR.RescueSynthDestination, for a late circle with no
        -- authored point inside it) is a pair of map coordinates the server
        -- guessed, and the server has no GetGroundZFor_3dCoord to improve it
        -- with. Carried so the client knows to resolve the height itself rather
        -- than trusting this number and burying the player in a hillside.
        free = rec.dest.free == true,
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

    -- ═══ EVERYBODY ELSE WHO IS PHYSICALLY ON THE MAP ═══
    --
    -- Owner, 2026-08-29: "make sure wherever the ambulance spawns there are no
    -- other players within 500m", revised the same day to 250m -- the number is
    -- `clearOfPlayersM` and nothing here hard-codes it. `board()` fades out and
    -- TELEPORTS the downed player into the vehicle, so the spawn is where they
    -- materialise -- see BR.RescueClearOfPlayers.
    --
    -- ALIVE AND DBNO, nothing else. A spectator has no body to be surprised by
    -- an ambulance and a player still on the bus is not in the world yet;
    -- counting either would refuse spawns for nobody being there. A DBNO player
    -- IS counted -- they are on the ground, they can be picked up, and dropping
    -- a rescue on top of a squad fight is exactly the case this rule is for.
    --
    -- These are the SERVER's own samples (roster.lua: "sampled server-side, not
    -- reported by the client"), which is what lets this be a real check rather
    -- than a poll of the people it is meant to hide from.
    local others = {}
    BR.Roster.each(
        function(e) return e.matchId == entry.matchId and e.pos
            and (e.state == BR.PlayerState.ALIVE
                 or e.state == BR.PlayerState.DBNO) end,
        function(osrc, e)
            if osrc ~= src then others[#others + 1] = e.pos end
        end)

    -- WHERE IT COMES FROM: nearest authored point to where they went down.
    local pickup = BR.RescueNearest(points, pos.x, pos.y)
    if not pickup then return false end

    -- WHERE IT GOES: solved against the circle as it will be ON ARRIVAL *and*
    -- against the purple circle the storm is shrinking toward. See
    -- shared/rescue_solve.lua for why neither one implies the other.
    local dest, dist, inside =
        BR.RescueDestination(points, pickup.x, pickup.y, m.storm, now, R, pickup)

    -- The surveyed pickup gets the same clearance test as a free one. "Wherever
    -- the ambulance spawns" has no exception in it, and these points are car
    -- parks beside hospitals -- exactly where two players end up in one phase.
    if dest and not BR.RescueClearOfPlayers(
            pickup.x, pickup.y, others, R.clearOfPlayersM) then
        print(('[br_core] rescue: %d  surveyed pickup %s is inside %.0fm of '
               .. 'another player -- looking for a free spot')
            :format(src, pointName(pickup), R.clearOfPlayersM or 250.0))
        dest = nil
    end

    -- ═══ AND IF THAT DID NOT WORK, THE SPAWN FLOATS ═══
    --
    -- Owner, 2026-08-29: "when not possible, start from a random point (nearest
    -- to the DBNO location), <1000m from the destination, and make sure it
    -- starts on a road node."
    --
    -- ONLY WHEN THE AUTHORED PATH FAILED. The 23 surveyed points are ground
    -- somebody stood on and checked, and every ride that already works keeps
    -- using them. This is what happens instead of a refusal -- see
    -- BR.RescueFreeSpawn for why it is what makes the 1000m cap affordable.
    --
    -- NO `z` OF ITS OWN AND NO HEADING. The server cannot ask where a road is:
    -- the pathfind natives are client-only. It hands over a coordinate at the
    -- downed player's own height and `free = true`, and client/rescue.lua snaps
    -- the vehicle onto the nearest live road node behind the fade it already
    -- draws before anybody is put inside it.
    if not dest then
        -- THE ROAD CORRIDORS GO IN WITH IT, and they are the only road knowledge
        -- this process has: the pathfind natives are client-only, so a synthesised
        -- destination is otherwise a uniformly random spot in whatever the circle
        -- left. BR.Config.Map.Roads is coarse -- authored for loot filler, "being
        -- roughly right is enough" -- so it is a PREFERENCE inside the ring the
        -- walk had already chosen, never a filter. See BR.RescueSynthDestination.
        local spot, freeDest, freeDist =
            BR.RescueFreeSpawn(pos.x, pos.y, others, points, m.storm, now, R,
                               BR.Config.Map and BR.Config.Map.Boundary,
                               BR.Config.Map and BR.Config.Map.Roads)
        if spot then
            pickup = {
                id = 'free', free = true,
                x = spot.x, y = spot.y, z = pos.z, heading = 0.0,
            }
            dest, dist, inside = freeDest, freeDist, true

            -- EVERY WAY THIS ANSWER IS SECOND-BEST IS SAID OUT LOUD, because
            -- the player is told none of them -- this feature has one
            -- notification -- and a rescue that starts oddly is otherwise
            -- indistinguishable from one that started normally. `crowded` means
            -- nothing on the map was `clearOfPlayersM` clear and this is the
            -- roomiest spot there was; an INVENTED destination means no surveyed
            -- point was legal and one had to be built.
            --
            -- AND HOW FAR THAT INVENTED POINT IS FROM AUTHORED TARMAC, because
            -- it is the number that predicts the circling: an invented drop-off
            -- kilometres from any road corridor is one client/rescue.lua's snap
            -- is least likely to rescue.
            print(('[br_core] rescue: %d  free spawn at (%.1f, %.1f), %.0fm from '
                   .. 'the player, %.0fm from %s%s%s')
                :format(src, spot.x, spot.y,
                        BR.Dist(pos.x, pos.y, spot.x, spot.y),
                        freeDist, pointName(freeDest),
                        spot.crowded and ('  <-- CROWDED, nearest player %.0fm')
                            :format(BR.RescueRoom(spot.x, spot.y, others)) or '',
                        freeDest.free and ('  <-- INVENTED drop-off, %s from the '
                            .. 'nearest authored road corridor'):format(
                                (freeDest.roadM or math.huge) < math.huge
                                    and ('%.0fm'):format(freeDest.roadM)
                                    or 'no corridor in range') or ''))
        end
    end

    -- ═══ THE ROUTING REFUSAL IS GONE, AND THAT REVERSES AN EARLIER RULE ═══
    --
    -- Owner, 2026-08-28: "If no destinations are available within the PURPLE
    -- storm circle - then cprkits are not available for use."
    -- Owner, 2026-08-29: "we should never reject a cprkit. Find a place to spawn
    -- which is nearest to the player but <1000m from the destination and on a
    -- road, and no other players nearby, then spawn it and go."
    --
    -- The later message supersedes the earlier one, and it is recorded here
    -- rather than quietly dropped because the earlier rule was a real design
    -- with a real reason: a kit is ultra-rare, and a ride that ends in the storm
    -- is worse than a ride that never starts.
    --
    -- WHAT MAKES "NEVER" ACHIEVABLE RATHER THAN A WISH, in the order the solver
    -- tries them -- see shared/rescue_solve.lua for each:
    --
    --   1. the surveyed pickup, as it always was;
    --   2. a FREE spawn, walked outward from the player to the first spot that
    --      is inside the map, clear of everybody, and inside the trip band of a
    --      surveyed destination -- reaching the whole map, not 1200m;
    --   3. a SYNTHESISED destination on open ground inside the arrival circle,
    --      for the late-game case where no authored car park is legal;
    --   4. and, if the survivors are packed so tightly that nothing on the map
    --      is `clearOfPlayersM` clear, the ROOMIEST spot that still had somewhere to drive
    --      to. The clearance is the rule that bends because it is the only one
    --      of the three whose failure is a worse rescue rather than a broken
    --      one: outside the map starts in the storm, and no destination has
    --      nowhere to go.
    --
    -- So `dest` is nil here only if the map has no boundary and no points at
    -- all, which canCall already refused. The guard stays as an assertion
    -- rather than a policy -- if it ever fires, the solver is broken, and
    -- spawning an ambulance with nowhere to drive would hide that.
    if not dest or not pickup then
        print(('[br_core] rescue: %d COULD NOT BE ROUTED AT ALL -- this should '
               .. 'be impossible since 2026-08-29 (%d points, %d other players, '
               .. 'trip band %.0f-%.0fm, search %.0fm, storm phase %s)')
            :format(src, #points, #others,
                    R.minTripM or 150.0, R.maxTripM or 1000.0,
                    R.spawnSearchM or 6000.0,
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
    --
    -- AND EACH ID NOW CARRIES ITS KIND (owner, 2026-08-29: "for some reason you
    -- set the destination as a POI?"). It never was one; this line was printing
    -- a surveyed car park's id, which is named after the POI beside it.
    print(('[br_core] rescue: %d  pickup=%s (%.1f, %.1f)  dest=%s (%.1f, %.1f)  %.0fm apart%s')
        :format(src, pointName(pickup), pickup.x, pickup.y,
                pointName(dest), dest.x, dest.y,
                BR.Dist(pickup.x, pickup.y, dest.x, dest.y),
                (pickup == dest) and '  <-- SAME POINT' or ''))

    -- ═══ THE SERVER MAKES THE AMBULANCE, AND IT IS MADE BEFORE THE KIT IS
    --     SPENT ═══
    --
    -- Owner, 2026-08-28: "Other players have to be able to see the ambulance.
    -- Local is not acceptable." A non-networked vehicle exists on exactly one
    -- machine, so it cannot be seen, shot or taken by anybody else -- and the
    -- only creation path this platform admits under sv_entityLockdown relaxed is
    -- a server one, because a server script's entity carries a creation token
    -- with a scriptGuid and a client script's does not.
    --
    -- CREATION LIVES IN server/vehicles.lua BESIDE THE ALLOWLIST and
    -- tools/verify.sh refuses it anywhere else -- BR.Vehicles.spawnOwned does the
    -- refused-model pre-check, puts the entity in this player's routing bucket
    -- (matches run in their own, and the setter defaults to 0), and prints what
    -- it built. CreateVehicleServerSetter raises `serverEntityCreated` rather
    -- than `entityCreating`, so that pre-check is the whole of the boundary.
    --
    -- ═══ AND THIS IS ABOVE `BR.Inv.take` ON PURPOSE ═══
    --
    -- It used to be below. Every refusal in this function returns before the kit
    -- is spent -- that is the property the owner's refusal rule rests on and
    -- tools/test_rescue.lua asserts it -- and a failed spawn is a refusal like
    -- any other. Leaving the creation after the take would have carved out one
    -- exception to that rule, in the one place most likely to fail, and it would
    -- have cost a player the rarest item in the game for an ambulance that never
    -- existed.
    --
    -- The comment that used to be here worried that spending the kit later
    -- "leaves a window in which the same kit could start a second rescue".
    -- There is no window: nothing between the two lines yields, and `live[src]`
    -- -- which is what canCall tests -- is not written until below either.
    -- ═══ THE RESCUED PLAYER'S SCOPE IS WIDENED FIRST, AND ONLY THEIRS ═══
    --
    -- THIS LINE IS WHY THE AMBULANCE ENDS UP OWNED BY THE RIGHT MACHINE, and it
    -- has to run BEFORE the entity exists rather than after. ServerGameState's
    -- Tick claims an unowned entity for whichever client reaches it first:
    --
    --   // relevant entity owned by nobody, or wants a reassign? try to yoink it
    --   auto cl = entity->GetClientUnsafe().lock();
    --   if (!cl || (entity->wantsReassign && cl->GetNetId() != client->GetNetId()))
    --   { ReassignEntity(entity->handle, client, std::move(_)); }
    --
    -- and the set it walks is the client's SYNCED ENTITIES -- which is exactly
    -- relevancy. So the candidates for first ownership are "every client this
    -- entity is relevant to", and the winner is decided by the order Tick walks
    -- clients in, not by who the ambulance was built for.
    --
    -- WHICH IS WHY THE 424-METRE FIX BROKE THE DRIVE. Widening the ENTITY's
    -- culling radius to the whole map made the ambulance relevant to every
    -- client in the match on the tick it was created, so every client became a
    -- candidate and the rescued player -- the one machine that has the medic ped
    -- and must issue the drive task -- was simply one of the field. The fix for
    -- visibility was the cause of the ownership loss; they are the same line.
    --
    -- SO RELEVANCY IS OPENED ON THE PLAYER SIDE INSTEAD, where it reaches one
    -- client. GetDistanceCullingRadius consults the entity override FIRST and
    -- the player's radius only when there is no override:
    --
    --   if (overrideCullingRadius != 0.0f) return overrideCullingRadius;
    --   else if (playerCullingRadius != 0.0f) return playerCullingRadius;
    --   else return (424.0f * 424.0f);
    --
    -- so with no override set, this makes the ambulance relevant to the rescued
    -- player and to nobody else -- and an uncontested yoink is not a race. It
    -- squares its own argument, like the entity native, so this is plain metres.
    --
    -- IT COMES STRAIGHT BACK OFF once ownership has settled, below, because it
    -- widens the player's scope for EVERY entity and not just this one.
    if SetPlayerCullingRadius then
        pcall(SetPlayerCullingRadius, src, R.cullRadiusM or 10000.0)
    end

    -- ═══ AND IT DOES NOT LAND ON THE STATION AMBULANCE PARKED THERE ═══
    --
    -- #219 step 3 puts a persistent ambulance on every one of the 23 surveyed
    -- points, which are the points this line spawns on. Without the two lines
    -- below every rescue would create its ride INSIDE a parked vehicle and
    -- leave the engine to resolve the intersection by throwing one of them.
    --
    -- THE MITIGATION THIS USED TO HAVE IS GONE, and config/rescue.lua still
    -- describes it as live: "`freeSpaceNear` walks a fixed ring of offsets and
    -- parks in the first clear one". That was true while the CLIENT made the
    -- vehicle. Since 2026-08-28 the SERVER makes it, client/rescue.lua says so
    -- itself -- "`freeSpaceNear` USED TO SITE THE VEHICLE and cannot any more:
    -- the vehicle is created on the server, which has no IsPositionOccupied to
    -- ask" -- and that ring-walk now only sites the medic. What it named as the
    -- cost ("two rescues converging on one station can now overlap") was rare.
    -- A station ambulance on all 23 points makes it certain, every time.
    --
    -- IT IS STILL NOT IsPositionOccupied, AND IT DOES NOT NEED TO BE. The server
    -- cannot ask "is anything there", but this is a smaller question -- "is one
    -- of MINE there" -- about vehicles it created and re-reads every second. See
    -- BR.Ambulances.displace. nil-guarded, because this file must go on working
    -- in a build without #219's half (and tools/test_rescue.lua runs it that
    -- way): with no station ambulances there is nothing parked to avoid, and the
    -- surveyed point is the right answer exactly as it was before.
    local sx, sy, sz = pickup.x, pickup.y, pickup.z
    if BR.Ambulances and BR.Ambulances.displace then
        local moved
        sx, sy, sz, moved = BR.Ambulances.displace(
            entry.matchId, sx, sy, sz, pickup.heading or 0.0)
        if moved then
            print(('[br_core] rescue: %d  %s has a station ambulance on it -- '
                   .. 'spawning %.1f, %.1f instead')
                :format(src, pointName(pickup), sx, sy))
        end
    end

    local veh, netId, whyVeh = BR.Vehicles.spawnOwned(
        R.model or 'ambulance', 'automobile',
        sx, sy, sz, pickup.heading or 0.0, src)
    if not veh then
        -- AND IT COMES OFF ON THE REFUSAL PATH TOO. This is the one exit
        -- between the widening above and the `live[src]` entry below, so it is
        -- the one exit `finish` cannot reach -- there is no record to finish.
        if SetPlayerCullingRadius then
            pcall(SetPlayerCullingRadius, src, 0.0)
        end
        print(('[br_core] rescue: %d refused -- no ambulance (%s)')
            :format(src, tostring(whyVeh)))
        return false
    end

    -- ═══ AND THIS LINE IS THE 424-METRE FIX. IT IS NOT THE ONE I WAS TOLD ═══
    --
    -- The brief for this change said the answer was SET_FOCUS_POS_AND_VEL on the
    -- client. IT IS NOT, and the platform's own source says so plainly enough
    -- that it was worth reading rather than repeating:
    --
    --   ServerGameState.cpp's `isRelevantViaPos` tests the entity against
    --   `GetPlayerFocusPos(playerEntity)`, and that function reads exactly two
    --   things -- the player's SYNCED PED POSITION, and the camera position out
    --   of the CPlayerCameraDataNode sync node (camMode 1/2, the free-cam bit
    --   and the camera offset, both written by GTA's own netcode).
    --   SET_FOCUS_POS_AND_VEL is a STREAMING override -- "override the area
    --   where the camera will render the terrain" -- and writes neither. It
    --   cannot move relevancy, because relevancy never asks it anything.
    --
    --   The resource that was offered as the reference for the technique spawns
    --   its vehicle by walking road nodes outward and STOPPING AT 200 UNITS. It
    --   is always inside the 424 zone already and never tests the case at all.
    --
    -- WHAT DOES MOVE IT is one line, on this side, and it is the same field the
    -- 424 default lives in:
    --
    --   inline float GetDistanceCullingRadius(float playerCullingRadius)
    --   {
    --       if (overrideCullingRadius != 0.0f) { return overrideCullingRadius; }
    --       else if (playerCullingRadius != 0.0f) { return playerCullingRadius; }
    --       else { return (424.0f * 424.0f); }
    --   }
    --
    -- SET_ENTITY_DISTANCE_CULLING_RADIUS writes `overrideCullingRadius = radius
    -- * radius`, which takes priority over both. Plain units in; the squaring is
    -- the native's.
    --
    -- ═══ IT IS DEPRECATED, AND THE DEPRECATION IS SURVIVABLE HERE ═══
    --
    -- Cfx marks the culling natives "deprecated and have known, unfixable
    -- issues", and the known issue (citizenfx/fivem #1828) is that an entity
    -- with a widened radius can be TELEPORTED BACK TO ITS SPAWN POINT when it is
    -- far from its OWNER while near another player.
    --
    -- That cannot happen during a ride: the owner is the rescued player and they
    -- are ATTACHED TO THE VEHICLE, so the distance from owner to entity is zero
    -- for the whole journey by construction. It could happen AFTERWARDS, to an
    -- abandoned ambulance whose owner has walked away -- so `finish` puts the
    -- radius back to 0.0 and the parked one goes back to being an ordinary
    -- vehicle at the ordinary 424.
    --
    -- ORPHAN MODE IS NOT SET AND DOES NOT NEED TO BE. A server-script entity
    -- carries a creation token, `IsOwnedByServerScript()` is token ~= 0 and
    -- scriptHash ~= 0, and `ShouldServerKeepEntity()` is already true for it --
    -- so nothing relevancy-driven deletes this vehicle while nobody is near it.
    -- ═══ AND IT IS NOT SET HERE ANY MORE. IT IS SET ONCE THE RIDE IS OWNED ═══
    --
    -- Setting it on this line is what cost the drive: see the block above
    -- `spawnOwned`. The widening still happens and still reaches the whole map,
    -- but it happens in `widenOnceOwned` below, after the rescued player has
    -- actually taken the entity -- at which point no other client can take it,
    -- because Tick's yoink fires only on an entity owned by NOBODY.
    --
    -- The deprecation this native carries (citizenfx/fivem #1828: an entity far
    -- from its OWNER but near another player gets teleported back to its spawn
    -- point) is what makes the ordering load-bearing rather than merely tidy.
    -- The comment that used to be here said the trade was survivable "because
    -- the owner is the rescued player and they are ATTACHED TO THE VEHICLE" --
    -- which was an assumption, was never checked, and was false for the whole
    -- of the failing round. Gating the widening on ownership is what finally
    -- makes it true.

    -- THE KIT IS SPENT HERE, at the moment the rescue is granted and after every
    -- refusal above has already passed -- including the one immediately above,
    -- which is the newest and the most likely.
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
    -- ═══ 424 METRES WAS THE BUG, AND THE CLIENT'S FOCUS IS THE FIX ═══
    --
    -- The first server-side attempt created the vehicle correctly and the owner
    -- got "net id 65534 never resolved to an ambulance here". Two things were
    -- cleared then and stay cleared:
    --
    --   65534 WAS NEVER THE BUG. The server allocates object ids DOWNWARD from
    --   MaxObjectId - 1 under OneSync (ServerGameState.cpp CreateEntityFromTree),
    --   so 65534 is exactly what the first server-created entity gets; clients
    --   count up from 1. The id was correct and so was the conversion.
    --
    --   THE BUG WAS SCOPE. Relevancy is per-client and, for an EMPTY vehicle, is
    --   pure 2D distance -- default radius 424m, onesync_distanceCulling on. The
    --   23 surveyed points average 825m from an arbitrary map position and 81.7%
    --   of the map is further than 424m from the nearest one, so for about four
    --   downed players in five the ambulance was created outside their scope and
    --   never cloned to them. NetworkDoesNetworkIdExist answered false honestly
    --   for the full five seconds.
    --
    -- THE FIX IS THE CULLING RADIUS ABOVE, and it is on this side because that
    -- is the side the number lives on. It is deliberately map-wide, so the
    -- ambulance is relevant to EVERY client in the match for the whole ride --
    -- which is the direct reading of "other players have to be able to see the
    -- ambulance" rather than a distance at which it quietly stops being true.
    --
    -- ═══ WHAT IS STILL LOCAL, STATED RATHER THAN LEFT TO BE FOUND ═══
    --
    -- The MEDIC. There is no ped server setter -- citizenfx/fivem ships exactly
    -- one creation native under ext/native-decls/server/ and #2787 asking for
    -- the rest is open -- and server-side CreatePed is an RPC native whose
    -- target client is chosen by ServerRPC.cpp with NO ROUTING BUCKET CHECK AT
    -- ALL, which for a gamemode that runs every match in its own bucket is a
    -- coin flip on where the ped ends up.
    --
    -- SO OTHER PLAYERS SEE THE AMBULANCE DRIVING ITSELF. They can find it, shoot
    -- it, be run over by it and take it when it parks; the paramedic at the
    -- wheel exists only on the rescued player's machine. That is the one part of
    -- the picture that could not be bought at any price this platform offers,
    -- and it is the cosmetic half rather than the mechanical one.
    live[src] = {
        veh        = veh,
        netId      = netId,
        matchId    = entry.matchId,
        dest       = dest,
        deadlineAt = now + deadline,
        lastPos    = { x = pos.x, y = pos.y },
        lastMoveAt = now,
        recoveries = 0,
        everMoved  = false,
        -- WHEN THE SCOPE WAS OPENED, so `rescue.own` can give ownership a bound
        -- rather than widening the moment it looks away.
        startedAt  = now,
        -- WHETHER THE MAP-WIDE WIDENING HAS HAPPENED YET. False means the
        -- rescued player's own culling radius is still carrying relevancy and
        -- has to be put back; see `rescue.own` and `finish`.
        widened    = false,
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
        -- THE SAME NUMBER AS `deadlineAt` ABOVE, AND IT IS NOW DRAWN. It was
        -- carried here from the start and read by nothing; since 2026-08-28
        -- ("let's add an on-screen timer showing their time to revive please")
        -- the client parks it on its `ride` record and publishes it to the
        -- interface, which counts down to it. It must stay identical to the
        -- record's copy: two deadlines for one ride means the clock the player
        -- watches is not the clock that ends the journey.
        endsAt = now + deadline,
        -- The client ADOPTS this vehicle rather than making one. It is the only
        -- new field on this envelope and it is the whole of the change on the
        -- wire; the medic carries no id because there is nothing to carry -- see
        -- the block above.
        netId  = netId,
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

-- ═══ THE MAP MOVES FASTER THAN THE JUDGEMENT DOES ═══
--
-- Owner, 2026-08-28: "The ambulance location blips don't refresh fast enough."
--
-- The blip used to be published by rescue.tick, so it inherited a cadence
-- chosen for deciding whether a rescue has stalled. An ambulance at driveSpeed
-- covers ~30m between judgements, so the icon trailed the vehicle by a block.
--
-- IT COULD NOT BE FIXED BY LOWERING tickMs. `moveM` is metres of progress
-- required BETWEEN judgements; halving the interval without halving the
-- threshold turns the stall detector on ambulances that are merely slow, and
-- that detector has already eliminated this owner mid-rescue more than once.
--
-- So the two are separate schedules over the same `live` table. This one only
-- reads a position the server already samples and sends it; it makes no
-- decisions, ends nothing, and cannot eliminate anybody.
BR.Sched.every(R and R.blipMs or 250, 'rescue.blip', function()
    if not R or not R.enabled then return end
    for src, rec in pairs(live) do
        local entry = BR.Roster.get(src)
        if entry then publishBlip(src, entry, rec, false) end
    end
end)

-- ═══ THE OWNERSHIP GATE, AND IT IS A THIRD SCHEDULE FOR THE SECOND REASON THE
--     BLIP ONE IS A SECOND ═══
--
-- It reads an owner and widens a radius. It makes no decisions, ends nothing and
-- cannot eliminate anybody, so it does not belong in `rescue.tick` beside the
-- stall detector that can.
--
-- WHAT IT IS WAITING FOR is the rescued player to actually take the ambulance.
-- `grant` opened relevancy on the PLAYER side so that they are the only client
-- the entity is relevant to, which makes them the only candidate for Tick's
-- yoink; this is where we confirm it landed and then open the entity to the rest
-- of the match.
--
-- ═══ THE SERVER IS THE ONLY SIDE WHERE THE OWNER CAN BE READ ═══
--
-- NETWORK_GET_ENTITY_OWNER answers a different question on each side, and the
-- client's answer cannot settle anything:
--
--   server (ServerGameState_Scripting.cpp):
--       auto entry = entity->GetClient();
--       if (entry) { retval = entry->GetNetId(); }     -- a SERVER ID, else -1
--
--   client (CloneManager.cpp, receiving any inbound clone):
--       // owner ID (forced to be remote so we can call ChangeOwner later)
--       auto owner = 31;
--
-- So `NetworkGetEntityOwner` on a client reads 31 for EVERY networked entity
-- that client did not create, whoever owns it -- 31 is GTA's reserved "remote"
-- physical player index, not a player. The client-side reading can never
-- distinguish "unowned" from "owned by somebody else", which is exactly the
-- distinction this gate turns on. The server's answer is a server id in the
-- same space as `src`, so it can simply be compared.
BR.Sched.every(R and R.ownMs or 250, 'rescue.own', function()
    if not R or not R.enabled then return end
    if not NetworkGetEntityOwner then return end
    local now = GetGameTimer()

    for src, rec in pairs(live) do
        if not rec.widened and rec.veh then
            local okO, raw = pcall(NetworkGetEntityOwner, rec.veh)
            local owner = okO and (math.tointeger(tonumber(raw) or -1) or -1) or -1

            -- BOUNDED, BECAUSE VISIBILITY IS NOT ALLOWED TO WAIT FOREVER ON
            -- OWNERSHIP. If the player never takes it the drive is lost either
            -- way, and an ambulance nobody can see is strictly worse than an
            -- ambulance nobody can drive -- so the widening still happens and
            -- says why.
            local expired = (now - (rec.startedAt or now)) >= (R.ownerMs or 10000)

            if owner == src or expired then
                if owner ~= src then
                    print(('[br_core] rescue: %d never took ownership of '
                           .. 'ambulance %d within %dms (owner reads %s) -- '
                           .. 'widening anyway; the drive will not take')
                        :format(src, rec.veh, R.ownerMs or 10000,
                                owner == -1 and 'unowned' or tostring(owner)))
                else
                    print(('[br_core] rescue: %d owns ambulance %d after %dms '
                           .. '-- opening it to the match')
                        :format(src, rec.veh, now - (rec.startedAt or now)))
                end

                if SetEntityDistanceCullingRadius then
                    pcall(SetEntityDistanceCullingRadius, rec.veh,
                          R.cullRadiusM or 10000.0)
                end

                -- AND THE PLAYER'S OWN RADIUS GOES STRAIGHT BACK. The entity
                -- override takes priority over it, so the ambulance stays
                -- relevant to them; everything ELSE in the world stops being
                -- streamed to one player at ten kilometres.
                if SetPlayerCullingRadius then
                    pcall(SetPlayerCullingRadius, src, 0.0)
                end

                rec.widened = true
            end
        end
    end
end)

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

            -- ═══ BUT THE AMBULANCE AND THE SCOPE ARE STILL THIS FILE'S ═══
            --
            -- This branch deliberately does not call `finish`, and until now it
            -- also did not undo either of the two things `grant` sets up. That
            -- left, on every rescue that ended by somebody else's decision, a
            -- server-created ambulance nothing owns and nothing culls -- and,
            -- since the scope change, a player still streaming the whole map.
            --
            -- Not delivered, so it is deleted rather than remembered: nobody
            -- parked it, its doors are shut and the medic never walked away, so
            -- there is nothing here for a player to find and take.
            if rec.veh then
                local okEx, exists = pcall(DoesEntityExist, rec.veh)
                if okEx and (exists == true or exists == 1) then
                    pcall(DeleteEntity, rec.veh)
                end
            end
            if not rec.widened and SetPlayerCullingRadius then
                pcall(SetPlayerCullingRadius, src, 0.0)
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
                -- Elapsed is measured from the last RESET, which is the same
                -- moment `lastPos` was taken -- so the distance and the window
                -- always describe one interval. Passing the tick length here
                -- instead would ask about the last second while comparing
                -- against a position from ten.
                if BR.RescueMoved(rec.lastPos, pos, now - rec.lastMoveAt, R) then
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
--   2. THE RECORD OUTLIVES THE DRIVER. A player getting out does NOT take it
--      down, and that is the more useful of the two rules rather than the lazier
--      one: the question this ledger answers is "is there an ambulance there",
--      and an abandoned one still answers yes.
--
--   2b. ...AND FINDING ONE NO LONGER PUTS A BLIP ON ANYBODY'S MAP (owner,
--      2026-08-31): "let's not auto-show ambulance blips just because they got
--      in an ambulance - BUT do add the position to the table so when blips are
--      shown we can include any that other players have found along the way
--      (engine-spawned ones)."
--
--      THAT SPLITS THIS FEATURE IN HALF AND THIS FILE KEEPS ONLY THE FIRST HALF.
--      Discovery is a LEDGER here; the map is server/ambulances.lua's, which
--      already decides who may see an ambulance blip and when (a squadmate who
--      is OUT, and only their squad). This file used to publish straight to the
--      whole match on its own tick, which meant a blip appeared for everybody
--      the moment anyone sat in a van -- with nothing to use it for.
--
--      WHAT IS LEFT HERE IS EXACTLY WHAT ONLY THIS FILE CAN DO: notice the
--      vehicle, keep its position current, and forget it when it stops existing.
--      BR.Rescue.eachFound is the whole of the interface.
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

--- Is this model an ambulance? Published, because there is now a SECOND feature
--- that has to agree with this one about the word.
---
--- server/ambheal.lua heals a player in the back of "any ambulance at all"
--- (owner, 2026-08-28) and asks this rather than resolving
--- BR.Config.Rescue.models itself. config/rescue.lua already argues for one list
--- -- "a second, longer list for recognition is how a rescue ambulance ends up
--- not counting as an ambulance" -- and one list with two resolvers is the same
--- fault one step later: the lazy `modelSet` above would be built twice, from
--- the same table, and would stay identical right up until somebody memoised one
--- of them somewhere else.
--- @param model integer|nil
--- @return boolean
function BR.Rescue.isAmbulance(model)
    if not R or not R.enabled then return false end
    if model == nil then return false end
    return isAmbulanceModel(model)
end

--- Is a rescue in flight using this vehicle right now?
---
--- ═══ THE STRETCHER IS THE SAME POSITION, WHICH IS WHY THIS EXISTS ═══
---
--- A heal attaches an ALIVE player to BR.Config.Rescue.stretcher, and a rescue
--- attaches a DBNO player to the identical offset on the identical bone. Two
--- bodies at one offset is one body wearing another, and the second one to
--- arrive would be riding to a car park it never asked to go to.
---
--- MOSTLY UNREACHABLE, AND WORTH HAVING ANYWAY. A rescue in flight runs
--- `lockedState` with its rear doors SHUT -- client/rescue.lua only opens 2 and
--- 3 in `park()` -- so the client's doors-open rule already refuses a moving
--- one. What this closes is the window AFTER it parks and BEFORE the ride ends:
--- about a second and a half in which the doors are open, the dome light is on,
--- and the player it is delivering is still attached inside. Once `finish` has
--- run, the vehicle is abandoned rather than live, this answers false, and the
--- parked ambulance becomes an ordinary heal station -- which is the owner's
--- "any ambulance at all" holding without an exception carved for it.
---
--- ONE WALK OVER `live`, WHICH IS AT MOST ONE ENTRY PER PLAYER IN A SOLO MATCH
--- and in practice zero. Asked only when somebody presses interact at the back
--- of an ambulance, never on a tick.
--- @param veh integer|nil
--- @return boolean
function BR.Rescue.vehicleBusy(veh)
    if not veh or veh == 0 then return false end
    for _, rec in pairs(live) do
        if rec.veh == veh then return true end
    end
    return false
end

--- A player is driving this vehicle. Is it an ambulance we did not know about?
---
--- CALLED FROM server/vehicles.lua's EXISTING 4 Hz SEAT READ, with the handle it
--- had already resolved -- so this costs one table lookup per driver per sample
--- on the ordinary path, and a model read only for a vehicle that is new to it.
--- Adding a second per-tick vehicle scan to find the same thing would have been
--- the obvious way and is pure duplicated cost.
---
--- ═══ ONE OF THE 23 IS NOT A FIND, AND SAYING SO IS NOT COSMETIC ═══
---
--- The owner asked for "any that OTHER PLAYERS HAVE FOUND along the way
--- (engine-spawned ones)". server/ambulances.lua already publishes the 23 under
--- `s:<entity>` keys; without this gate a squadmate who drives one would put a
--- SECOND blip on the same van under `v:<entity>`, and the client keeps its
--- blips in one table keyed on that string, so it would draw both. Two icons on
--- one vehicle is a map claiming there are two.
---
--- ASKED OF THE FILE THAT MADE THEM rather than answered here. It holds the 23
--- handles and their match; a list kept in this file would be a second copy of
--- something already authoritative one file away. Nil-guarded at call time, the
--- same shape in which four files ask BR.Rescue.riding() from above the file
--- that answers -- and the guard is real rather than defensive, because
--- tools/test_rescue drives this module with no ambulances.lua loaded at all.
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

    if BR.Ambulances and BR.Ambulances.isStation
       and BR.Ambulances.isStation(entry.matchId, veh) then
        return
    end

    local pos = entry.pos
    found[veh] = {
        x = pos and pos.x or 0.0,
        y = pos and pos.y or 0.0,
        matchId = entry.matchId,
    }
    print(('[br_core] rescue: found an ambient ambulance (entity %d), %d was driving it')
        :format(veh, src))
end

--- Every ambulance this match has discovered, as blip keys and coordinates.
---
--- THE WHOLE OF THE INTERFACE, and the reason it is a walk rather than a table
--- is BR.Roster.each's: the caller runs this once a second per match and a
--- returned table would be a fresh allocation every pass for a list that is
--- almost always empty.
---
--- THE KEY IS AUTHORED HERE, ONCE. `v:<entity>` is the category
--- client/rescue.lua's RESCUE_BLIP handler was deliberately left open for
--- ("both are just strings here"), and it is spelled in exactly one place so
--- the file that PUBLISHES it and the file that RETIRES it cannot disagree
--- about a string.
---
--- ═══ MATCH-WIDE, WHICH IS THE READING THAT MAKES IT WORTH HAVING ═══
---
--- "any that OTHER PLAYERS have found along the way." Scoped to the finder's own
--- squad this is nearly nothing -- a squad would have to have personally driven
--- an ambient van earlier in the round for it to help them at the moment one of
--- them dies, which is the case where they already know where it is. Scoped to
--- the match it is what it sounds like: the round accumulates knowledge of where
--- the ambulances are, and any squad that needs one gets the benefit.
---
--- AND IT LEAKS NOTHING THE OLD BEHAVIOUR DID NOT. This ledger has always been
--- match-wide and always published to the whole match; what changes is that a
--- blip now appears only while the viewer's OWN squadmate is out, so the surface
--- is strictly smaller than it was.
--- @param matchId any
--- @param fn fun(key: string, x: number, y: number)
function BR.Rescue.eachFound(matchId, fn)
    if not matchId or not fn then return end
    for veh, rec in pairs(found) do
        if rec.matchId == matchId then
            fn('v:' .. tostring(veh), rec.x, rec.y)
        end
    end
end

--- Keep the found ones honest.
---
--- ═══ HOW A STALE RECORD IS RETIRED, WHICH IS THE JOB THAT MATTERS ═══
---
--- Ambient traffic despawns. A remembered position with no ambulance on it is a
--- blip pointing at nothing, and a squad driving three minutes to it because a
--- mate is out is the worst version of that. So the record's whole lifetime is
--- one question asked once a second: DOES THE ENTITY STILL EXIST. A vehicle that
--- was blown up, or that the owning client's population manager reclaimed once
--- everybody drove away, stops existing on this server -- and the record goes
--- with it, in the same pass, before anything can be published from it.
---
--- THAT IS THE SAME RULE THE 23 LIVE BY. server/ambulances.lua's `refresh` drops
--- a station whose handle has stopped existing and withdraws its blip; this is
--- the identical test on the identical cadence, and the consumer withdraws these
--- the identical way. There is no second staleness mechanism -- no age, no TTL,
--- no distance check -- because none of them would be more true than the engine's
--- own answer, and each would be a way for the two halves to disagree.
---
--- THE MATCH IS THE OTHER END OF IT. A record whose match is no longer PLAYING
--- is dropped outright: the bucket is gone, the round is over, and nothing that
--- was true about the world during it survives.
---
--- NOTHING IS PUBLISHED FROM HERE ANY MORE. See decision 2b in this section's
--- header -- this pass keeps the ledger and server/ambulances.lua decides who
--- sees it.
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
        else
            -- STILL TRACKED AFTER THE DRIVER LEAVES, which is the whole point of
            -- reading the VEHICLE rather than the person who was in it. An
            -- abandoned ambulance keeps its position where it was left, and one
            -- somebody drives away keeps it under them -- which is the owner's
            -- own rule for the station ambulances ("if someone takes it, we need
            -- to update it's location on the map", 2026-08-23) holding for these
            -- without a second mechanism.
            local okPos, c = pcall(GetEntityCoords, veh)
            if okPos and c then rec.x, rec.y = c.x, c.y end
        end
    end
end)

--- Delete the delivered ambulances whose match is over.
---
--- ON THE SAME CADENCE AND THE SAME RULE as the ambient-ambulance sweep above.
--- An entity that has already stopped existing -- somebody blew it up, which is
--- a perfectly ordinary end for an abandoned vehicle -- is simply forgotten.
BR.Sched.every(R and R.tickMs or 1000, 'rescue.abandoned', function()
    if not R or not R.enabled then return end

    for veh, matchId in pairs(abandoned) do
        local m = matchId and BR.Server.matches[matchId]
        local okExists, alive = pcall(DoesEntityExist, veh)

        -- `== true` rather than a truth test. DoesEntityExist is a BOOL native
        -- and may answer 1 or 0, and 0 is truthy in Lua -- a bare test would
        -- keep every destroyed ambulance on this list for ever and then try to
        -- delete a handle that has not existed for twenty minutes.
        if not okExists or not (alive == true or alive == 1) then
            abandoned[veh] = nil
        elseif not m or m.state ~= BR.MatchState.PLAYING then
            abandoned[veh] = nil
            pcall(DeleteEntity, veh)
        end
    end
end)

--- @return integer
function BR.Rescue.abandonedCount()
    local n = 0
    for _ in pairs(abandoned) do n = n + 1 end
    return n
end

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
