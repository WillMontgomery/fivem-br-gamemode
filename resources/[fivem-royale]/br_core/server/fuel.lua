-- The fuel ledger: a number per vehicle, owned here, spent by driving.
--
-- ═══ THE OWNER'S ANSWER, 2026-08-21 (#195) ═══
--
--   "Option B2 is best here, but it should trigger SetVehicleFuelLevel so the
--    in-vehicle fuel-gauge works."
--   "Meters would be best as well."
--   "Yes, fuel is per vehicle, not per player. It is exactly the case of 'a
--    vehicle must not be a permanent advantage'."
--
-- Option B2 is the server-side budget. #195 argues it against B1 (the engine's
-- own fuel model) on docs/security.md rather than on taste:
--
--   "The gamemode is built so the client is never the authority on anything
--    that decides a match."
--
-- GET/SET_VEHICLE_FUEL_LEVEL are client natives. A fuel model that lives there
-- is one `SetVehicleFuelLevel(veh, 100.0)` on a timer away from being infinite,
-- and it would leave no trace -- the server cannot even read the value to
-- notice. A resource whose entire purpose is to limit how far a player can
-- outrun the storm is exactly something that decides a match, so it lives here.
--
-- ═══ WHAT IS AUTHORITATIVE AND WHAT IS MERELY DISPLAYED ═══
--
--   THIS FILE          owns `left`, in metres, per vehicle. Nothing a client
--                      sends can raise it except a validated pump grant, and
--                      that grant is bounded by the WALL CLOCK rather than by
--                      how many messages arrived (BR.FuelSolve.grantMs).
--   client/fuel.lua    renders it. It calls SetVehicleFuelLevel with whatever
--                      this file last told it, on a timer, so a client that
--                      overwrites the level gets it back within 100ms and gains
--                      a tenth of a second of engine per attempt.
--
-- A client can still lie in ONE direction and it is worth naming: it can drive
-- and simply not apply the level we send, and its own engine will not stall.
-- That buys nothing it did not already have, because a client that ignores our
-- writes could equally call SetVehicleFuelLevel itself -- the level is local
-- either way. What it CANNOT do is make the number in this file go up, which is
-- what makes the budget real for everybody who is not modifying their client.
--
-- ═══ THE KEY IS A NETWORK ID, AND WHAT THAT DOES AND DOES NOT SURVIVE ═══
--
-- #193 settled Option A: THIS GAMEMODE SPAWNS NO VEHICLES. Every car in a match
-- is GTA's own ambient traffic or its parked-car network, created by a client
-- and networked to us. We did not make them, we do not own them, and there is
-- no id of ours to hang state off.
--
-- What there is, is the network id -- stable for the entity's lifetime on this
-- server, readable here with NetworkGetNetworkIdFromEntity, and resolvable back
-- to an entity on both sides. So that is the key, and the honest limits are:
--
--   SURVIVES   a driver getting out and another walking up. This is THE case
--              the owner named -- "that needs to carry over if someone else
--              comes up to the vehicle and tries to drive it" -- and it is the
--              easy one: a player is standing right there, so the entity is
--              nowhere near being cleaned up and its id does not move.
--   SURVIVES   the whole squad getting out and coming back within `idleTtlMs`.
--   DOES NOT   the vehicle being destroyed, or streaming out of the world
--              entirely and GTA repopulating that spot. That is a DIFFERENT
--              car with a different id, and it arrives full -- which is also
--              what GTA would have done with it.
--
-- ═══ WHY THE REGISTRY IS SMALL, AND WHY THAT IS THE WHOLE TRICK ═══
--
-- server/loot.lua sizes its own registry with the sentence this one inherits:
-- 1900 networked entities would end the server before the first circle closed.
-- The same arithmetic applies here from the other direction. GTA's ambient and
-- parked population under BR.Config.Ambient is HUNDREDS of vehicles, and a
-- server-side record for every one of them -- sampled, swept, pushed -- would
-- be a per-tick walk over a set nobody is driving.
--
-- So a vehicle enters this registry ONLY BY BEING OCCUPIED BY A PLAYER, which
-- bounds the live set by how many cars the players in a match have actually
-- used. An empty car is not tracked, does not cost a tick, and reads as full,
-- because it is.
--
-- ═══ AMBIENT TRAFFIC AND #191'S AMBULANCE ARE FREE, BY CONSTRUCTION ═══
--
-- Nothing here looks at a vehicle nobody is sitting in, so NPC traffic never
-- enters the registry. The CPR ambulance is created client-side and
-- non-networked (the same `isNetwork = false` that keeps the Battle Bus out of
-- server/vehicles.lua's detector), so it has no network id on this server at
-- all -- GetVehiclePedIsIn answers 0 for a player inside one, and the loop below
-- moves on. Neither needs a special case and neither has one.

BR = BR or {}
BR.Fuel = {}

local F = BR.Config.Fuel

--- Live tanks. [netId] = { left, x, y, at, seen, matchId }
---
---   left     metres remaining
---   x, y     where this vehicle was at the last sample, for the subtraction
---   at       when that sample was taken (GetGameTimer ms)
---   seen     when a player was last in it, for the idle sweep
---   matchId  which match's world it belongs to, so teardown can be per-match
local tanks = {}
local tankCount = 0

--- Refuel grants in flight. [src] = { at, netId }
---
--- ONE ENTRY PER PLAYER, NOT PER VEHICLE, because the thing being rate-limited
--- is the player's hold. See BR.FuelSolve.grantMs for why the bound is the
--- clock and not the message.
local pumping = {}

--- What each client was last told, so an unchanged number is not re-sent.
--- [src] = { netId, frac, at }
local pushed = {}

local stat = {
    admitted = 0, evicted = 0, swept = 0, drained = 0, jumps = 0,
    pumped = 0, pumpRefused = 0, pushes = 0, asks = 0, askRefused = 0,
    sfx = 0,
}

--- Which player states may spend or buy fuel.
---
--- The same pair server/vehicles.lua and server/strip.lua gate on. A lobby ped
--- and a corpse are outside any match; a spectator is watching somebody else's
--- car and must not be able to drain it.
local LIVE = {
    [BR.PlayerState.ALIVE]  = true,
    [BR.PlayerState.WARMUP] = true,
}

--- Did a native declared BOOL say yes?
---
--- THE `didHit` IDIOM, AND THIS PROJECT HAS SHIPPED THE BUG IT PREVENTS FOUR
--- TIMES. A FiveM native declared BOOL hands Lua a number on some builds and a
--- boolean on others, and IN LUA `0` IS TRUTHY -- so `if DoesEntityExist(e)`
--- is true for an entity that does not exist on a build that answers numbers.
--- Here that would mean draining the tank of a handle that has gone stale.
--- @param v any
--- @return boolean
local function didHit(v)
    return v == 1 or v == true
end

--- Is the fuel model switched on and configured?
--- @return boolean
local function enabled()
    return F ~= nil and F.enabled == true and (tonumber(F.tankMetres) or 0) > 0
end

-- ---------------------------------------------------------------------------
-- Natives this file needs, checked ONCE rather than guessed at
-- ---------------------------------------------------------------------------

--- Which server natives are present on this build.
---
--- ALMOST NOTHING ABOUT A VEHICLE IS ANSWERABLE ON THE SERVER -- config/
--- vehicles.lua makes the same point about GetVehicleClass, which has no server
--- handler at all -- so the two this file leans on are worth checking rather
--- than assuming. Checked at load, reported once, and consulted per call:
---
---   GetVehiclePedIsIn      without it there is no way to know which vehicle a
---                          player is in, and the whole model is inert.
---   GetPedInVehicleSeat    without it the DRIVER'S SEAT rule cannot be
---                          enforced, and the owner's rule was explicit:
---                          "Refueling should only be possible while in the
---                          driver's seat". A rule that cannot be checked is a
---                          rule we do not have, so refuelling REFUSES rather
---                          than quietly widening to any seat.
local have = {
    vehiclePedIsIn = type(GetVehiclePedIsIn) == 'function',
    pedInSeat      = type(GetPedInVehicleSeat) == 'function',
    netIdFrom      = type(NetworkGetNetworkIdFromEntity) == 'function',
    entityFromNet  = type(NetworkGetEntityFromNetworkId) == 'function',
}

--- The vehicle a player is sitting in, as a network id, or nil.
--- @param ped integer
--- @return integer|nil netId
--- @return integer|nil entity
local function vehicleOf(ped)
    if not have.vehiclePedIsIn or not have.netIdFrom then return nil, nil end
    if not ped or ped == 0 then return nil, nil end

    -- pcall FOR THE SAME REASON server/vehicles.lua pcalls GetVehicleType: the
    -- platform's entity natives are built with a wrapper that RAISES on a stale
    -- handle rather than answering. A ped handle can go stale between the
    -- roster's sample and this line, and an uncaught throw inside a scheduler
    -- job costs five of them before the job is suspended -- silently, which is
    -- the failure mode this project pays for most often.
    local ok, veh = pcall(GetVehiclePedIsIn, ped, false)
    if not ok or not veh or veh == 0 then return nil, nil end

    local ok2, nid = pcall(NetworkGetNetworkIdFromEntity, veh)
    if not ok2 then return nil, nil end
    nid = math.tointeger(tonumber(nid))
    -- ZERO IS TESTED EXPLICITLY. `0` is truthy in Lua and it is what the
    -- platform answers for "this entity is not networked" -- which is exactly
    -- what a client-side, non-networked vehicle looks like from here. The
    -- Battle Bus and #191's ambulance both land on this line.
    if nid == nil or nid == 0 then return nil, nil end
    return nid, veh
end

--- Where a vehicle is, or nil.
---
--- NO TYPE TEST ON THE RETURN, and the first draft had one that was WRONG.
--- GetEntityCoords answers a vector3, which in CfxLua is its own primitive:
--- `type(v)` is 'vector3', not 'table' and not 'userdata', so a guard written
--- for those two rejects every real answer and fuel silently never drains. The
--- field reads below work on a vector and on a plain table alike, which is what
--- lets the unit suite hand this a `{ x =, y = }` and exercise the same path.
--- @param entity integer
--- @return number|nil x
--- @return number|nil y
local function coordsOf(entity)
    local ok, c = pcall(GetEntityCoords, entity)
    if not ok or c == nil then return nil, nil end
    local okx, x = pcall(function() return tonumber(c.x) end)
    local oky, y = pcall(function() return tonumber(c.y) end)
    if not okx or not oky or x == nil or y == nil then return nil, nil end
    return x, y
end

-- ---------------------------------------------------------------------------
-- The registry
-- ---------------------------------------------------------------------------

--- Throw out the entry nobody has touched for longest.
---
--- CALLED ONLY WHEN THE CAP IS REACHED, so the O(n) scan runs at most once per
--- admission past the cap rather than on every one. The cap exists because the
--- keys arrive from the world: a long match with players hopping cars in the
--- city is exactly how a registry keyed on entities grows without bound, and
--- the same argument server/vehicles.lua makes for MAX_SEEN_MODELS applies to a
--- table whose rows are bigger.
local function evictOldest()
    local worst, worstAt = nil, math.huge
    for nid, rec in pairs(tanks) do
        if rec.seen < worstAt then worst, worstAt = nid, rec.seen end
    end
    if worst ~= nil then
        tanks[worst] = nil
        tankCount = tankCount - 1
        stat.evicted = stat.evicted + 1
    end
end

--- Start tracking a vehicle, full.
---
--- ADMISSION HAPPENS IN EXACTLY ONE PLACE -- the sampler, which requires a
--- player to actually be sitting in the thing. Deliberately NOT from the client
--- ask handler: a client that could admit rows would be a client that could
--- grow this table from the wire, one message per made-up network id.
--- @param netId integer
--- @param x number
--- @param y number
--- @param now integer
--- @param matchId integer|nil
--- @return table
local function admit(netId, x, y, now, matchId)
    local cap = math.tointeger(tonumber(F.maxTracked)) or 0
    if cap > 0 and tankCount >= cap then evictOldest() end

    local rec = {
        left = tonumber(F.tankMetres) or 0.0,
        x = x, y = y, at = now, seen = now, matchId = matchId,
    }
    tanks[netId] = rec
    tankCount = tankCount + 1
    stat.admitted = stat.admitted + 1
    return rec
end

--- The ledger reading for a vehicle, whether or not it is tracked.
---
--- AN UNTRACKED VEHICLE IS FULL, and that is the honest answer rather than a
--- default: nobody has driven it, so nobody has spent any of it.
--- @param netId integer|nil
--- @return number metres
function BR.Fuel.left(netId)
    if not enabled() then return tonumber(F and F.tankMetres) or 0.0 end
    local rec = netId and tanks[netId] or nil
    if rec then return rec.left end
    return tonumber(F.tankMetres) or 0.0
end

--- Introspection for `brfuel`.
function BR.Fuel.stats()
    return {
        enabled = enabled(), tracked = tankCount,
        tankMetres = F and F.tankMetres or nil,
        natives = have,
        admitted = stat.admitted, evicted = stat.evicted, swept = stat.swept,
        drained  = stat.drained,  jumps   = stat.jumps,
        pumped   = stat.pumped,   pumpRefused = stat.pumpRefused,
        pushes   = stat.pushes,   asks    = stat.asks,
        askRefused = stat.askRefused,
        sfx      = stat.sfx,
    }
end

--- Drop everything. Exposed for the test suite and for `onResourceStart`.
function BR.Fuel.reset()
    tanks, tankCount = {}, 0
    pumping, pushed = {}, {}
    for k in pairs(stat) do stat[k] = 0 end
end

-- ---------------------------------------------------------------------------
-- Telling the client
-- ---------------------------------------------------------------------------

--- Send a player the fuel reading for the vehicle they are in.
---
--- ═══ SENT ON CHANGE, NOT ON A CADENCE, AND THE THRESHOLD IS THE POINT ═══
---
--- The naive version pushes every sample: 4 Hz times every occupied seat, which
--- at full player count is two hundred messages a second carrying a number that
--- moved by a metre. So a push happens when one of four things is true, and
--- each of them is a case where the client would otherwise be wrong about
--- something visible:
---
---   1. the vehicle changed        they got into a different car, and the
---                                 gauge is showing the last one's.
---   2. the reading moved by
---      `pushFraction` of a tank   the needle would visibly disagree.
---   3. it just went dry           THE ONE THAT CANNOT WAIT. The engine stalls
---                                 on zero, and a stall that arrives a second
---                                 late is a car that kept going after it ran
---                                 out.
---   4. `pushHeartbeatMs` passed   a client that missed a message, or joined
---                                 mid-drive, converges without needing to ask.
---
--- @param src integer
--- @param netId integer
--- @param left number
--- @param force boolean|nil
--- @param repair number|nil  health points this push earned, pump grants only
local function pushTo(src, netId, left, force, repair)
    local tank = tonumber(F.tankMetres) or 0.0
    local frac = BR.FuelSolve.fraction(left, tank)
    local now  = GetGameTimer()
    local last = pushed[src]

    if not force and last and last.netId == netId then
        local moved = math.abs(frac - last.frac)
        local dry   = (frac <= 0.0) and (last.frac > 0.0)
        local stale = (now - last.at) >= (tonumber(F.pushHeartbeatMs) or 2000)
        if not dry and not stale and moved < (tonumber(F.pushFraction) or 0.005) then
            return
        end
    end

    pushed[src] = { netId = netId, frac = frac, at = now }
    stat.pushes = stat.pushes + 1
    TriggerClientEvent(BR.Net.FUEL_SET, src, {
        n = netId,
        -- THE FRACTION IS WHAT TRAVELS, not the litres. The client is the only
        -- side that can read fPetrolTankVolume, which differs per model, so the
        -- conversion happens there -- see BR.FuelSolve.tankLevel.
        f = frac,
        -- The metres, for the pump readout. The client never computes this: it
        -- is the ledger's own number and the ledger is here.
        m = math.floor(BR.FuelSolve.clamp(left, tank) + 0.5),
        -- HEALTH POINTS THIS PUSH EARNED, present only on a pump grant.
        --
        --   "When stopping for fuel ... the vehicle health should be restored."
        --
        -- SENT AS A DELTA RATHER THAN A TARGET, because the server does not know
        -- the vehicle's health and cannot: every vehicle-health native is
        -- client-only. What it CAN do -- and what makes this a grant rather than
        -- a request -- is decide WHETHER any repair happened, from the same
        -- validated pump hold that decided the fuel. The client applies it; it
        -- never invents it.
        --
        -- A SEAM FOR #194. Vehicle damage is that issue's subject and this file
        -- deliberately models none of it: there is no server-side vehicle health
        -- here to be authoritative over, and this field is the one line that
        -- would have to change if #194 ever introduces one.
        r = (repair and repair > 0.0) and repair or nil,
    })
end

-- ---------------------------------------------------------------------------
-- Spending it
-- ---------------------------------------------------------------------------

--- One pass: every occupied vehicle pays for the ground it covered.
---
--- ═══ THE VEHICLE'S DISPLACEMENT, NOT THE DRIVER'S ═══
---
--- The obvious shape is "for each player, charge the distance THEY moved", and
--- it is wrong in two ways at once. Four squadmates in one car would each drain
--- the same tank, so a full car would empty four times faster than an empty one
--- -- and a player who swapped from the passenger seat to the wheel mid-journey
--- would be charged for a leg somebody else drove.
---
--- Keying the last position on the VEHICLE instead makes the rule what the
--- owner asked for and nothing more: the car pays for where the car went, once,
--- whoever is aboard and however many of them there are.
--- @param dtMs number
local function samplePass(dtMs)
    if not enabled() then return end

    local now = GetGameTimer()
    -- Which vehicles have already been charged on THIS pass. Without it, a
    -- four-player squad in one car charges it four times -- see above.
    local charged = {}

    BR.Roster.each(function(e)
        return LIVE[e.state] == true and e.matchId ~= nil
    end, function(src, e)
        local ped = e.ped
        if not ped or ped == 0 then return end

        local netId, veh = vehicleOf(ped)
        if netId == nil then
            -- Not in a networked vehicle. Forget what we last told them, so
            -- getting back in re-pushes rather than being suppressed as
            -- "unchanged" by a stale record.
            pushed[src] = nil
            return
        end

        local x, y = coordsOf(veh)
        if x == nil then return end

        local rec = tanks[netId]
        if rec == nil then
            rec = admit(netId, x, y, now, e.matchId)
            -- A car admitted on this pass has already had its baseline set to
            -- where it is standing, so there is nothing for a second occupant
            -- to charge it for.
            charged[netId] = true
        -- ═══ `charged` IS A BELT, AND THE RE-BASELINE BELOW IS THE BRACES ═══
        --
        -- Deliberate redundancy, and it is written down because mutation
        -- testing found it and the finding is worth keeping: removing this
        -- guard alone changes NOTHING, because the last line of the branch
        -- stamps `rec.at = now`, so the second occupant of the same car
        -- measures a zero-millisecond interval and BR.FuelSolve.travelled
        -- charges nothing for it.
        --
        -- KEPT ANYWAY, because the two protect against different edits. The
        -- re-baseline is load-bearing for a reason that has nothing to do with
        -- squads -- it is what makes the NEXT pass measure from here -- so a
        -- refactor that hoisted it out of this branch, or that split the drain
        -- from the stamp, would silently restore the four-players-one-car bug.
        -- This line says out loud that one charge per car per pass is intended,
        -- rather than leaving it as a consequence of statement order.
        elseif not charged[netId] then
            charged[netId] = true
            local dt = now - rec.at
            local metres, jumped = BR.FuelSolve.travelled(
                rec.x, rec.y, x, y, dt,
                tonumber(F.maxSpeedMps) or 0.0)

            -- ═══ BOOSTING BURNS FUEL 50% FASTER ═══
            --
            --   "And yes, boosting should burn fuel faster. Good point. Let's
            --    make it burn 50% faster while boosting"  -- owner, 2026-08-22
            --
            -- ONE MULTIPLY, ON THE METRES, AND IT IS ASKED FOR EVEN WHEN THE
            -- STEP WAS DISBELIEVED. BR.Boost.fuelMultiplier is CONSUMING -- it
            -- takes the interval's boost time out of its own row -- so skipping
            -- the call on a jumped step would leave that time banked and charge
            -- it against the NEXT interval's metres, which is a surcharge landing
            -- on ground that was driven without a boost. Asked here, once per
            -- vehicle per pass, on the same `dt` the travel was measured over.
            --
            -- THE MULTIPLIER IS THE CLIENT'S WORD, DELIBERATELY, AND THE FULL
            -- ARGUMENT IS IN server/boost.lua's header -- including the owner's
            -- decision, what a liar gains (about 1.3% of a tank per boost), and
            -- the three clamps that stop it becoming anything else. It is an
            -- exception to this file's own rule that the ledger is not
            -- client-authored, and it is not precedent for a second one.
            local mult = 1.0
            if BR.Boost and BR.Boost.fuelMultiplier then
                mult = BR.Boost.fuelMultiplier(netId, dt)
            end

            if jumped then
                stat.jumps = stat.jumps + 1
            elseif metres > 0.0 then
                rec.left = BR.FuelSolve.drain(
                    rec.left, metres * mult, F.tankMetres)
                stat.drained = stat.drained + 1
            end
            rec.x, rec.y, rec.at = x, y, now
        end

        rec.seen = now
        -- A CAR CAN OUTLIVE THE MATCH ITS FIRST DRIVER WAS IN. Re-stamping
        -- keeps the teardown below aimed at the match that is actually using
        -- it, rather than deleting a live car because whoever first sat in it
        -- was in a round that has since ended.
        rec.matchId = e.matchId
        pushTo(src, netId, rec.left, false)
    end)
end

--- Forget vehicles nobody has been in for a while, and vehicles that are gone.
---
--- TWO DIFFERENT DEATHS, AND ONLY ONE OF THEM IS CHEAP TO DETECT. A destroyed
--- or streamed-out entity can be asked about directly; a car parked at the edge
--- of the map that nobody will ever return to cannot, so it gets a clock.
---
--- `idleTtlMs` IS DELIBERATELY LONGER THAN A ROTATION. A car left at one POI
--- while its driver fights at the next one must still be dry when they walk
--- back to it -- that is the whole feature. The TTL is there to bound the
--- table over a twenty-minute match, not to expire state anybody is using.
local function sweep()
    if not enabled() then return end

    local now = GetGameTimer()
    local ttl = tonumber(F.idleTtlMs) or 0
    for nid, rec in pairs(tanks) do
        local stale = ttl > 0 and (now - rec.seen) > ttl
        local gone = false
        if not stale and have.entityFromNet then
            local ok, ent = pcall(NetworkGetEntityFromNetworkId, nid)
            -- A FAILED pcall IS NOT A DEATH CERTIFICATE. It means the platform
            -- refused the question, which is not the same as answering "no" --
            -- deleting the row on it would reset a live car's tank to full for
            -- a reason nobody could ever reproduce.
            if ok and (not ent or ent == 0 or not didHit(DoesEntityExist(ent))) then
                gone = true
            end
        end
        if stale or gone then
            tanks[nid] = nil
            tankCount = tankCount - 1
            stat.swept = stat.swept + 1
        end
    end
end

-- ---------------------------------------------------------------------------
-- The pump cues
-- ---------------------------------------------------------------------------

--- Play a cue from a vehicle, for everybody sitting in it.
---
--- ═══ THE OWNER'S RULE, AND WHY IT LANDS ON THE SERVER ═══
---
---   "All occupants of a vehicle should hear these sounds."
---                                          -- owner, 2026-08-22
---
--- PLAY_SOUND_FROM_ENTITY IS A CLIENT NATIVE AND IT DOES NOT NETWORK. That was
--- checked rather than assumed -- its `isNetwork` parameter is undocumented in
--- citizenfx/natives, every parameter description in that file is empty, and the
--- established answer to "how do other players hear this" is that you send them
--- a message. So there is no version of this that a single client can do, and
--- the fan-out has to live where the facts are.
---
--- IT IS ALREADY HERE. Deciding who hears a cue means knowing who is in the car,
--- and this file walks exactly that set four times a second for the ledger. The
--- walk below is the same one, run at most twice per refuelling stop.
---
--- ═══ OCCUPANTS, NOT EARSHOT, AND THAT IS THE OWNER'S WORDING ═══
---
--- The alternative shape is "everyone near the vehicle", which the CLIENT could
--- decide for itself by refusing to play a cue for a car it has not streamed.
--- The owner asked for occupants; occupants is what this sends to. Widening it
--- later is a change to this one predicate and nothing else, which is precisely
--- why the recipient list is computed in one function rather than inline.
---
--- NOTHING HERE CREATES AN ENTITY. `sv_entityLockdown` is `relaxed` on this
--- server, so a client cannot spawn networked props -- and nothing in this cue
--- path asks it to. The sound is played from a car GTA's own traffic network
--- already created, by a native that adds nothing to the world.
---
--- @param netId integer
--- @param matchId integer|nil  only players in this match are considered
--- @param cue string           a key in BR.Config.Audio.cues
local function sfxToOccupants(netId, matchId, cue)
    if netId == nil or matchId == nil then return end

    BR.Roster.each(function(e)
        return LIVE[e.state] == true and e.matchId == matchId
    end, function(src, e)
        local ped = e.ped
        if not ped or ped == 0 then return end
        -- THE SAME RESOLUTION THE LEDGER USES, so "is this player in that car"
        -- is answered by the server reading the world rather than by anything a
        -- client said. A passenger gets the cue because they ARE a passenger.
        local inNet = vehicleOf(ped)
        if inNet ~= netId then return end
        stat.sfx = stat.sfx + 1
        TriggerClientEvent(BR.Net.FUEL_SFX, src, { n = netId, c = cue })
    end)
end

-- ---------------------------------------------------------------------------
-- Buying it back
-- ---------------------------------------------------------------------------

--- The client is holding the interact key in a driver's seat at a station.
---
--- ═══ EVERY CLAIM IN THAT SENTENCE IS RE-DERIVED HERE ═══
---
--- The message carries ONE field -- which vehicle -- and even that is checked
--- against what the server can see for itself. What the client is trusted for
--- is exactly one thing: that a key is down, which is the only fact in the
--- whole interaction that lives on a keyboard.
---
---   in a match, alive        from the roster, which the client never writes.
---   in THIS vehicle          GetVehiclePedIsIn, server-side.
---   in the DRIVER'S seat     GetPedInVehicleSeat(veh, -1). The owner's rule:
---                            "Refueling should only be possible while in the
---                            driver's seat".
---   at a station             the VEHICLE's coordinates, read here, against
---                            BR.Config.Fuel.stations -- within
---                            `refuelRadius`, which is TIGHTER than the
---                            `stationRadius` the forecourt rules use. The
---                            client mirrors this same test to decide whether
---                            to draw the plate, so the two agree; it is
---                            re-run here because agreeing is not the same as
---                            being trusted.
---   for how long             the wall clock since the last grant, capped.
---                            See BR.FuelSolve.grantMs.
RegisterNetEvent(BR.Net.FUEL_PUMP)
AddEventHandler(BR.Net.FUEL_PUMP, function(d)
    local src = source
    if not enabled() or type(d) ~= 'table' then return end

    local netId = math.tointeger(tonumber(d.n))
    if netId == nil or netId == 0 then return end

    -- THE CHEAPEST REFUSAL FIRST, because a flood is a shape the client can
    -- choose. A hold sends at BR.Config.Fuel.pumpSendMs; anything faster earns
    -- nothing from grantMs anyway, and this stops it costing a roster walk and
    -- four natives to earn nothing.
    local now = GetGameTimer()
    local p = pumping[src]
    local floor = tonumber(F.pumpFloorMs) or 0
    if p and floor > 0 and (now - p.at) < floor then return end

    if not have.pedInSeat then
        -- SAID ONCE, AT MOST. See `have` above for why this refuses rather than
        -- widening to any seat.
        stat.pumpRefused = stat.pumpRefused + 1
        return
    end

    local e = BR.Roster.get and BR.Roster.get(src) or nil
    if not e or not LIVE[e.state] or e.matchId == nil then
        stat.pumpRefused = stat.pumpRefused + 1
        return
    end

    local ped = e.ped
    if not ped or ped == 0 then stat.pumpRefused = stat.pumpRefused + 1 return end

    local inNet, veh = vehicleOf(ped)
    if inNet ~= netId or veh == nil then
        stat.pumpRefused = stat.pumpRefused + 1
        return
    end

    local okSeat, driver = pcall(GetPedInVehicleSeat, veh, -1)
    if not okSeat or driver ~= ped then
        stat.pumpRefused = stat.pumpRefused + 1
        return
    end

    local x, y = coordsOf(veh)
    if x == nil then stat.pumpRefused = stat.pumpRefused + 1 return end

    -- ═══ refuelRadius, NOT stationRadius, AND THIS IS THE AUTHORITY HALF OF
    --     THE OWNER'S "I CAN STILL GET GAS FURTHER AWAY" ═══
    --
    -- Still the VEHICLE's coordinates as read HERE, still against the authored
    -- station list, still nothing the client said -- only the number moved, from
    -- 30m to 20m. The server cannot test against a pump and never will:
    -- GET_CLOSEST_OBJECT_OF_TYPE reads the streamed world and a server streams
    -- nothing. What it can do is stop approximating "on the forecourt" so
    -- generously, and BR.Config.Fuel.refuelRadius carries the full argument
    -- including what a modified client still gets away with.
    local station = BR.FuelSolve.stationNear(x, y, F.stations, F.refuelRadius)
    if station == nil then
        stat.pumpRefused = stat.pumpRefused + 1
        return
    end

    -- ═══ IS THIS THE FIRST MESSAGE OF A NEW HOLD? ═══
    --
    --   "When pressing [key] to fuel, a sound should be played."
    --
    -- `p` is the record as it was BEFORE this message -- captured at the top of
    -- the handler, above every `pumping[src] = ...` below -- so this reads the
    -- previous hold, not the one being started. A press is inferred from the
    -- silence in front of it, because the server never sees a keypress; see
    -- BR.Config.Fuel.holdGapMs for why the gap is 750ms.
    --
    -- COMPUTED AFTER EVERY REFUSAL ABOVE, so a cue is only ever heard for a hold
    -- that was actually accepted. A player mashing E in a field hears nothing.
    local gap = tonumber(F.holdGapMs) or 0
    local fresh = (p == nil) or (p.netId ~= netId) or ((now - p.at) >= gap)
    if fresh then sfxToOccupants(netId, e.matchId, 'fuel.start') end

    local rec = tanks[netId]
    if rec == nil then
        -- Full and untracked: there is nothing to pour in. Admitting a row here
        -- would be the client growing this table, which admit()'s note refuses.
        --
        -- THE START CUE HAS ALREADY PLAYED ABOVE AND THAT IS INTENDED: they
        -- pressed the key at a pump and the press was accepted. A car that is
        -- already full is not a refusal, and a silent key would read as one.
        pumping[src] = { at = now, netId = netId }
        pushTo(src, netId, tonumber(F.tankMetres) or 0.0, true)
        return
    end

    local ms = BR.FuelSolve.grantMs(p and p.netId == netId and p.at or nil,
                                    now, tonumber(F.pumpStepMs) or 0)
    pumping[src] = { at = now, netId = netId }
    if ms <= 0 then return end

    local metres = (ms / 1000.0) * (tonumber(F.refuelMetresPerSec) or 0.0)
    local before = rec.left
    rec.left = BR.FuelSolve.refill(rec.left, metres, F.tankMetres)
    rec.seen = now

    -- THE REPAIR RIDES ON THE SAME GRANT, so a hold that earned no fuel earns no
    -- repair, and one that earned a full tank earned a full repair. That is what
    -- ties the two to one decision -- see BR.Config.Fuel.repairFraction.
    --
    -- FROM `ms`, NOT FROM THE FUEL ACTUALLY ADDED, and the difference shows at
    -- the top of the tank: a driver who is nearly full still earns the seconds
    -- they stood there, which is the reading that lets somebody stop for the
    -- bodywork alone.
    local repair = (ms / 1000.0) * (tonumber(F.repairPerSecond) or 0.0)

    if rec.left ~= before or repair > 0.0 then
        stat.pumped = stat.pumped + 1
        pushTo(src, netId, rec.left, true, repair)
    end

    -- ═══ THE TANK JUST REACHED FULL ═══
    --
    --   "When fuel reaches 100%, a 'complete' sound should be played."
    --                                          -- owner, 2026-08-22
    --
    -- AN EDGE, NOT A STATE, which is what makes it fire exactly once. A player
    -- who keeps holding after the tank is full sends four more messages a second
    -- and `before` is already at the cap for every one of them, so the test is
    -- false and nothing plays. Holding on is still worth doing -- the repair
    -- rides the same grant and has its own clock -- it is just not worth a
    -- second chime.
    --
    -- EXACT COMPARISON IS SAFE HERE rather than lucky: BR.FuelSolve.refill
    -- clamps through BR.FuelSolve.clamp, which RETURNS `tank` ITSELF when the
    -- sum passes it, so a full tank is bit-for-bit the configured number and not
    -- an accumulation of floats that lands near it.
    local tank = tonumber(F.tankMetres) or 0.0
    if before < tank and rec.left >= tank then
        sfxToOccupants(netId, e.matchId, 'fuel.done')
    end
end)

--- A client wants the reading for a vehicle it is about to be in.
---
--- ═══ THIS IS WHAT MAKES THE STALL CARRY OVER ═══
---
--- The owner: "that needs to carry over if someone else comes up to the vehicle
--- and tries to drive it." The sampler alone would do it a quarter of a second
--- after they sat down, which is a quarter of a second of engine that should
--- not have turned over. The client asks the moment it sees the ENTRY animation
--- start, which is a second or more before the seat is taken, so the answer is
--- already in hand when the ignition would fire.
---
--- ANSWERED FOR A VEHICLE THE PLAYER IS NEAR, AND ONLY THAT. Without the range
--- check this is a free oracle: a client could ask about every network id in
--- the world and learn which cars are dry, which is a small wallhack for one
--- message. With it, the answer is about a car they are standing next to and
--- could read the gauge of in a second anyway.
---
--- IT NEVER ADMITS A ROW. An unknown vehicle answers full without being
--- recorded -- see admit().
RegisterNetEvent(BR.Net.FUEL_ASK)
AddEventHandler(BR.Net.FUEL_ASK, function(d)
    local src = source
    if not enabled() or type(d) ~= 'table' then return end
    stat.asks = stat.asks + 1

    local netId = math.tointeger(tonumber(d.n))
    if netId == nil or netId == 0 or not have.entityFromNet then
        stat.askRefused = stat.askRefused + 1
        return
    end

    local e = BR.Roster.get and BR.Roster.get(src) or nil
    if not e or not LIVE[e.state] or e.pos == nil then
        stat.askRefused = stat.askRefused + 1
        return
    end

    local ok, ent = pcall(NetworkGetEntityFromNetworkId, netId)
    if not ok or not ent or ent == 0 or not didHit(DoesEntityExist(ent)) then
        stat.askRefused = stat.askRefused + 1
        return
    end

    local x, y = coordsOf(ent)
    if x == nil then stat.askRefused = stat.askRefused + 1 return end

    local reach = tonumber(F.askRadius) or 0.0
    if reach <= 0.0 or BR.Dist(e.pos.x, e.pos.y, x, y) > reach then
        stat.askRefused = stat.askRefused + 1
        return
    end

    pushTo(src, netId, BR.Fuel.left(netId), true)
end)

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

--- A match's world is gone, and so are its cars.
---
--- PER MATCH RATHER THAN WHOLESALE, because several matches run at once in
--- separate routing buckets and network ids are global. Dropping the whole
--- table on one match ending would refill every tank in every other match.
AddEventHandler('br:match:destroyed', function(d)
    local matchId = d and d.matchId or nil
    if matchId == nil then return end
    for nid, rec in pairs(tanks) do
        if rec.matchId == matchId then
            tanks[nid] = nil
            tankCount = tankCount - 1
        end
    end
end)

--- SERVER IDS ARE RECYCLED WITHIN THE MINUTE, so a pump grant or a push record
--- left behind is inherited by whoever lands in that slot next. The same reason
--- server/vehicles.lua and server/damage.lua clear theirs here. The TANKS are
--- deliberately NOT cleared: a car does not refill because its driver
--- disconnected, which is the entire point of per-vehicle state.
AddEventHandler('playerDropped', function()
    local src = source
    if not src then return end
    pumping[src] = nil
    pushed[src]  = nil
end)

AddEventHandler('onResourceStart', function(name)
    if name ~= GetCurrentResourceName() then return end
    BR.Fuel.reset()
    if not enabled() then
        print('[br_core] fuel: disabled by config')
        return
    end
    if not have.vehiclePedIsIn or not have.netIdFrom then
        print('^3[br_core] fuel: this build has no server-side '
            .. 'GetVehiclePedIsIn/NetworkGetNetworkIdFromEntity -- '
            .. 'no vehicle will ever consume fuel^7')
    elseif not have.pedInSeat then
        print('^3[br_core] fuel: this build has no server-side '
            .. 'GetPedInVehicleSeat -- consumption works, refuelling refuses, '
            .. "because the owner's rule is driver's seat only^7")
    end
end)

--- The consumption pass runs at the SAME rate the roster samples positions,
--- and reads `entry.ped` that pass has already resolved. #195's argument for
--- metres rests on exactly this: "distance travelled is a subtraction on data
--- the server takes anyway, so a distance budget costs no new loop and no new
--- client message."
BR.Sched.every(BR.Roster.sampleIntervalMs(), 'fuel.sample', samplePass)
BR.Sched.every(5000, 'fuel.sweep', sweep)

RegisterCommand('brfuel', function()
    local s = BR.Fuel.stats()
    print(('[br_core] fuel: %s, %d tracked, tank %s m')
        :format(s.enabled and 'on' or 'OFF', s.tracked, tostring(s.tankMetres)))
    print(('  natives: vehiclePedIsIn=%s pedInSeat=%s netIdFrom=%s entityFromNet=%s')
        :format(tostring(s.natives.vehiclePedIsIn), tostring(s.natives.pedInSeat),
                tostring(s.natives.netIdFrom), tostring(s.natives.entityFromNet)))
    print(('  admitted %d  evicted %d  swept %d  drained %d  jumps %d')
        :format(s.admitted, s.evicted, s.swept, s.drained, s.jumps))
    print(('  pumped %d  refused %d  asks %d (refused %d)  pushes %d  cues %d')
        :format(s.pumped, s.pumpRefused, s.asks, s.askRefused, s.pushes, s.sfx))
end, true)
