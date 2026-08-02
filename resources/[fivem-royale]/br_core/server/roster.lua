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
    hp = true, armour = true, kills = true, placement = true,
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
function BR.Roster.add(src)
    local existing = roster[src]
    if existing then
        existing.name = GetPlayerName(src) or existing.name
        return existing
    end

    local entry = newEntry(src)
    roster[src] = entry

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
        local ped = GetPlayerPed(src)
        if ped and ped ~= 0 then
            local c = GetEntityCoords(ped)
            entry.pos   = { x = c.x, y = c.y, z = c.z }
            entry.posAt = now

            -- Health is read the same way, for the same reason. This is what
            -- makes the reconciliation in the combat pipeline possible later.
            entry.engineHp = GetEntityHealth(ped)
            entry.engineArmour = GetPedArmour(ped)
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
