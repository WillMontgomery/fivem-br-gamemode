-- The authoritative roster.
--
-- THIS IS THE SOURCE OF TRUTH FOR WHO IS IN THE MATCH.
--
-- Everything the gamemode needs to know about players -- who is alive, who is on
-- which squad, who killed whom, what placement they finished -- lives here and
-- nowhere else. Clients hold a read-only mirror that is only ever updated by
-- explicit broadcasts from this file.
--
-- WHY IT IS BUILT THIS WAY
--
-- Under OneSync, a client can only see players currently in its scope. Two
-- players 3km apart do not exist to each other. Any client-side attempt to count
-- players, list squadmates, or work out who is still alive therefore produces an
-- answer that is correct when everyone is huddled at the drop and wrong for the
-- rest of the match -- and the symptoms (alive count drifting, kill feed missing
-- entries) look like logic bugs rather than architecture bugs.
--
-- The server has no such limitation: playerJoining, playerDropped and
-- GetPlayers() are global. So the rule is absolute, and mechanically enforced by
-- the scope gate in tools/verify.sh: roster facts flow server -> client, never
-- the reverse, and never sideways between clients.

BR = BR or {}
BR.Roster = {}

local roster = BR.Server.roster   -- [src] = entry

--- Fields replicated to clients. Deliberately a subset: licenses, positions and
--- damage bookkeeping are server business. Broadcasting live positions to every
--- client would hand a wallhack to anyone reading the event stream.
---
--- Declared before first use and kept local -- as a global it would leak into
--- every other server script in this resource's Lua state.
local PUBLIC_FIELDS = {
    name = true, squadId = true, state = true,
    hp = true, armour = true, kills = true, placement = true, colour = true,
}

--- Fields carried per player. Written here so the shape is documented in one
--- place rather than accreting keys across a dozen files.
--- @param src integer
--- @return table
local function newEntry(src)
    return {
        src        = src,
        name       = GetPlayerName(src) or 'Unknown',
        license    = nil,          -- filled by br_stats if it is running
        matchId    = nil,          -- match instance membership; NEVER public
        squadId    = nil,
        state      = BR.PlayerState.LOBBY,

        hp         = 100.0,        -- DISPLAY units (0..100), see config/match.lua
        armour     = 0.0,

        kills      = 0,
        downs      = 0,
        revives    = 0,
        damage     = 0.0,
        placement  = nil,

        pos        = nil,          -- sampled server-side, not reported by the client
        posAt      = 0,

        lastDamageBy = nil,
        lastDamageAt = 0,

        joinedAt   = GetGameTimer(),
        bucket     = 0,
    }
end

--- Add a player, or return the existing entry if they are already known.
--- @param src integer
--- @return table
--- Put a player in the routing bucket their state AND MATCH call for.
---
--- THE INSTANCE MODEL (user-specified, 2026-08-03; parallel matches + the
--- communal warmup, 2026-08-04): the lobby is one shared bucket, the WARMUP
--- PAD is another -- every forming match's players (and every rider until
--- their flight is genuinely airborne) share it, so the airstrip is a place
--- where you watch other lobbies' planes take off. From the moment a rider's
--- flight climbs out (m.airborne, set by the bus a few seconds after
--- wheels-up) -- or the moment they jump -- they live in their match's OWN
--- bucket, matchBucketBase + matchId, so two concurrent matches never see
--- each other and a fresh match never inherits anything.
---
--- A LOBBY-state player rides the lobby bucket even while they still carry
--- a matchId (the ENDED summary trip home) -- the bucket is about where
--- their PED is, the matchId about which match's traffic they hear.
--- Guarded, because the unit tests run this file without the Cfx runtime.
--- @param src integer
--- @param entry table
local function applyBucket(src, entry)
    if not SetPlayerRoutingBucket then return end
    local M = BR.Config.Match
    local m = entry.matchId and BR.Server.matches[entry.matchId]
    local bucket
    if entry.state == BR.PlayerState.LOBBY or not m then
        bucket = M.lobbyBucket
    elseif entry.state == BR.PlayerState.WARMUP
        or (entry.state == BR.PlayerState.BUS and not m.airborne) then
        bucket = M.warmupBucket
    else
        bucket = M.matchBucketBase + entry.matchId
    end
    if SetRoutingBucketPopulationEnabled then
        -- MATCH buckets get ambient life (user call, 2026-08-04: parked
        -- cars, some traffic, pedestrians -- the AMOUNT is throttled
        -- client-side by the density multipliers in gamerules). The lobby
        -- and warmup buckets stay sterile: the island is a stage.
        SetRoutingBucketPopulationEnabled(bucket,
            bucket >= M.matchBucketBase)
    end
    SetPlayerRoutingBucket(tostring(src), bucket)
end

--- Re-derive a player's bucket from their current entry -- the lever the
--- bus pulls when a flight goes airborne and its riders leave the communal
--- warmup bucket without any state change.
--- @param src integer
function BR.Roster.rebucket(src)
    local entry = roster[src]
    if entry then applyBucket(src, entry) end
end

--- Attach a player to a match instance (or detach with nil). The bucket
--- follows immediately. matchId is server business -- it never travels in a
--- delta; scoped events are how a client knows which match it is in.
--- @param src integer
--- @param matchId integer|nil
function BR.Roster.setMatch(src, matchId)
    local entry = roster[src]
    if not entry or entry.matchId == matchId then return end
    entry.matchId = matchId
    applyBucket(src, entry)
end

function BR.Roster.add(src)
    local existing = roster[src]
    if existing then
        existing.name = GetPlayerName(src) or existing.name
        return existing
    end

    local entry = newEntry(src)
    roster[src] = entry

    -- New joiners start in the LOBBY state, so they get its shared bucket
    -- too -- add() writes the state directly rather than through setState.
    applyBucket(src, entry)

    BR.Broadcast.delta({ op = 'add', src = src, e = BR.Roster.public(entry) })
    print(('[br_core] + %s (%d) joined -- %d connected'):format(entry.name, src, BR.Server.count()))
    return entry
end

--- Remove a player.
---
--- A disconnect mid-match is NOT the same as an elimination: the player is gone,
--- but their squad may still be alive and their placement still matters. So the
--- entry is marked LEFT and removed, and the caller (match.lua) decides what that
--- means for the win condition.
--- @param src integer
--- @return table|nil the removed entry
function BR.Roster.remove(src)
    local entry = roster[src]
    if not entry then return nil end

    entry.state = BR.PlayerState.LEFT
    roster[src] = nil

    BR.Broadcast.delta({ op = 'remove', src = src })
    print(('[br_core] - %s (%d) left -- %d connected'):format(entry.name, src, BR.Server.count()))
    return entry
end

--- @param src integer
--- @return table|nil
function BR.Roster.get(src)
    return roster[src]
end

--- Mutate an entry and broadcast only what changed.
---
--- Sending the whole entry on every small change would be simpler and much more
--- expensive: at 48 players a state change would push every field to every
--- client. Deltas keep the fanout proportional to what actually happened.
---
--- @param src integer
--- @param changes table  field -> value
--- @return table|nil
function BR.Roster.update(src, changes)
    local entry = roster[src]
    if not entry then return nil end

    local changed = nil
    for k, v in pairs(changes) do
        if entry[k] ~= v then
            entry[k] = v
            -- Only fields the client mirror actually needs are worth sending.
            if PUBLIC_FIELDS[k] then
                changed = changed or {}
                changed[k] = v
            end
        end
    end

    if changed then
        BR.Broadcast.delta({ op = 'update', src = src, e = changed })
    end
    return entry
end

--- Clear fields, and tell clients they were cleared.
---
--- A separate verb from update() because nil cannot travel in a delta: setting
--- `e.squadId = nil` removes the key from the table, so it serialises as though
--- nothing changed and the client keeps the old value forever.
---
--- That is exactly what happened switching a squad match to solo -- the server
--- correctly emptied squadId and every client carried on displaying the squad
--- from the previous match.
---
--- @param src integer
--- @param fields table  array of field names
function BR.Roster.clearFields(src, fields)
    local entry = roster[src]
    if not entry then return end

    local cleared = {}
    for _, k in ipairs(fields) do
        if entry[k] ~= nil then
            entry[k] = nil
            if PUBLIC_FIELDS[k] then cleared[#cleared + 1] = k end
        end
    end

    if #cleared > 0 then
        BR.Broadcast.delta({ op = 'update', src = src, clear = cleared })
    end
end

--- Set a player's state, with the transition logged.
--- State changes are the single most useful thing in a match log when working
--- out why someone did or did not win.
--- @param src integer
--- @param state string
function BR.Roster.setState(src, state)
    local entry = roster[src]
    if not entry or entry.state == state then return end

    local from = entry.state
    entry.state = state

    -- The bucket rides the state, from the single choke point every state
    -- change already passes through.
    applyBucket(src, entry)

    BR.Broadcast.delta({ op = 'update', src = src, e = { state = state } })

    if BR.Server.devMode then
        print(('[br_core]   %s (%d): %s -> %s'):format(entry.name, src, from, state))
    end
end

--- The client-visible view of an entry.
--- @param entry table
--- @return table
function BR.Roster.public(entry)
    local out = {}
    for k in pairs(PUBLIC_FIELDS) do
        out[k] = entry[k]
    end
    return out
end

--- The whole roster, client-visible, for a snapshot.
--- @return table  [src] = public entry
function BR.Roster.publicAll()
    local out = {}
    for src, entry in pairs(roster) do
        out[src] = BR.Roster.public(entry)
    end
    return out
end

--- Iterate players matching a predicate. Convenience so callers do not each
--- write the same pairs() loop with a state check.
--- @param pred function|nil
--- @param fn function  receives (src, entry)
function BR.Roster.each(pred, fn)
    for src, entry in pairs(roster) do
        if not pred or pred(entry) then fn(src, entry) end
    end
end

--- Server-side position sampling.
---
--- Read from the server rather than reported by the client, deliberately. The
--- storm, the spectator camera and the anti-cheat all depend on positions, and a
--- client-reported position is exactly the thing a cheater would lie about. The
--- server can read every player's coordinates regardless of scope, so there is no
--- reason to ask.
local function samplePositions()
    local now = GetGameTimer()
    for src, entry in pairs(roster) do
        -- GET_PLAYER_PED is declared as `Entity GET_PLAYER_PED(char* playerSrc)`
        -- -- playerSrc is documented as a STRING. Passing the numeric roster key
        -- returned 0 for every player, so positions silently never sampled and
        -- brwhy reported "not sampled yet" indefinitely.
        local ped = GetPlayerPed(tostring(src))
        entry.ped = ped

        if ped and ped ~= 0 then
            local c = GetEntityCoords(ped)
            entry.pos   = { x = c.x, y = c.y, z = c.z }
            entry.posAt = now

            -- Health is read the same way, for the same reason. This is what
            -- makes the reconciliation in the combat pipeline possible later.
            entry.engineHp = GetEntityHealth(ped)
            entry.engineArmour = GetPedArmour(ped)

            -- ...and converted into the DISPLAY value the rest of the system
            -- uses. Sampling the engine value without doing this left entry.hp
            -- pinned at its initial 100 forever: brwhy reported full health for
            -- a player lying dead at the bottom of a cliff, and every squad
            -- panel would have shown the same.
            --
            -- Rounded to an integer so a stationary player does not generate a
            -- delta every half second from float noise -- Roster.update only
            -- broadcasts fields that actually changed.
            local hp = math.floor(BR.ToDisplayHp(entry.engineHp) + 0.5)
            local armour = math.floor((entry.engineArmour or 0) + 0.5)

            if hp ~= entry.hp or armour ~= entry.armour then
                BR.Roster.update(src, { hp = hp, armour = armour })
            end
        end
    end
end

--- Reconcile the roster against reality.
---
--- playerJoining and playerDropped are reliable, but a resource restart mid-session
--- leaves us with an empty roster and a server full of players, and a missed
--- event would otherwise persist for the whole match. Cheap enough to just check.
local function reconcile()
    local seen = {}

    for _, idStr in ipairs(GetPlayers()) do
        local src = tonumber(idStr)
        if src then
            seen[src] = true
            if not roster[src] then
                print(('[br_core] reconcile: adding missing player %d'):format(src))
                BR.Roster.add(src)
            end
        end
    end

    for src in pairs(roster) do
        if not seen[src] then
            print(('[br_core] reconcile: removing stale player %d'):format(src))
            BR.Roster.remove(src)
        end
    end
end

-- Connection events. These are SERVER-side and global -- unaffected by entity
-- scoping, which is the entire reason the roster is built from them.
AddEventHandler('playerJoining', function()
    BR.Roster.add(source)
end)

AddEventHandler('playerDropped', function(reason)
    local entry = roster[source]
    if entry and BR.Server.devMode then
        print(('[br_core]   drop reason: %s'):format(tostring(reason)))
    end
    BR.Roster.remove(source)
end)

BR.Sched.every(500, 'roster.positions', samplePositions)
BR.Sched.every(5000, 'roster.reconcile', reconcile)

-- Players already connected when the resource starts (a restart mid-session).
AddEventHandler('onResourceStart', function(res)
    if res ~= GetCurrentResourceName() then return end
    Citizen.SetTimeout(1000, reconcile)
end)
