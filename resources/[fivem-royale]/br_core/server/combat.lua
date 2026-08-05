-- Elimination.
--
-- The seed of the M6 combat pipeline. For now it does the one thing M1 cannot
-- work without: turning a dead player into a dead ROSTER ENTRY, so the win
-- condition can actually fire and a match can end.
--
-- AUTHORITY. The client reports its own death, because it is the only party that
-- can observe it immediately. The server decides what that means, and
-- independently confirms it by reading the player's health server-side. A client
-- that never reports still dies; a client that reports falsely is ignored.
-- Full damage validation arrives in M6.

BR = BR or {}
BR.Combat = {}

--- Can this player be eliminated? Dying in the lobby is not a thing.
---
--- Takes an ENTRY, not a state string, so it matches the predicate contract of
--- BR.Roster.each and BR.Server.count -- both of which pass the whole entry.
--- An earlier version took the state string, which made
--- `BR.Roster.each(canDie, ...)` compare a table against a string: always false,
--- so the server-observed death check silently never ran for anybody. No error,
--- no log line, just a check that quietly did nothing.
--- @param entry table
--- @return boolean
local function canDie(entry)
    local s = entry and entry.state
    return s == BR.PlayerState.ALIVE
        or s == BR.PlayerState.DBNO
        or s == BR.PlayerState.BUS
        or s == BR.PlayerState.FREEFALL
        or s == BR.PlayerState.GLIDE
end

--- Eliminate a player.
---
--- Placement is assigned as the number of teams still standing INCLUDING this
--- one, computed before the state change. Last of eight teams finishes 8th.
---
--- @param src integer
--- @param cause string
--- @param killerSrc integer|nil
function BR.Combat.eliminate(src, cause, killerSrc)
    local entry = BR.Roster.get(src)
    if not entry or not canDie(entry) then return end

    -- Placement counts THIS match's teams; the kill feed goes to THIS
    -- match's audience. A death in one match is silence in every other.
    local m = BR.Server.matchOf(src)
    local placement = BR.Server.squadsAlive(m)

    -- THE BOX IS BUILT BEFORE THE STATE CHANGES. What they were carrying and
    -- where they were standing are both still true at exactly this moment;
    -- one line later the roster sweep and the CLEANUP reset have opinions
    -- about both. Whoever killed them gets to walk over and take it.
    if m and BR.Loot and BR.Loot.deathBox then
        BR.Loot.deathBox(m, src)
    end

    BR.Roster.setState(src, BR.PlayerState.DEAD)
    entry.placement = placement
    BR.Broadcast.delta({ op = 'update', src = src, e = { placement = placement } })

    local killer = killerSrc and BR.Roster.get(killerSrc)
    if killer and killerSrc ~= src then
        killer.kills = (killer.kills or 0) + 1
        BR.Broadcast.delta({ op = 'update', src = killerSrc, e = { kills = killer.kills } })
    end

    local feed = {
        killer    = killer and killer.name or nil,
        killerSrc = killer and killerSrc or nil,
        victim    = entry.name,
        -- The src matters to exactly one consumer: the victim's own client,
        -- which needs to know HOW it died to pick the right verdict slam --
        -- a storm death is not an "elimination" and should not read as one.
        victimSrc = src,
        cause     = cause,
        placement = placement,
    }
    if m then
        BR.Broadcast.toMatch(m, BR.Net.KILL_FEED, feed)
    else
        -- No instance resolvable (a brkill on an odd state); the victim at
        -- least must hear about their own death.
        TriggerClientEvent(BR.Net.KILL_FEED, src, feed)
    end

    print(('[br_core] eliminated %s (%d) -- placement %d%s')
        :format(entry.name, src, placement,
                killer and (' by ' .. killer.name) or (' (' .. tostring(cause) .. ')')))

    -- No system chat: the kill feed already carries this to every client,
    -- and the chat is for players talking (user rule, 2026-08-03).
end

--- What GET_PED_CAUSE_OF_DEATH's weapon hash means in words.
---
--- The client reports the raw hash; translating it HERE keeps the wire format
--- dumb and the mapping in one place. Built lazily because GetHashKey is what
--- computes the keys (a raw hash literal in source broke luac once already),
--- and normalised to unsigned because hash sign conventions differ between
--- the native's return and Lua's arithmetic.
local causeByHash = nil

local function describeCause(raw)
    if type(raw) ~= 'number' then
        return (type(raw) == 'string') and raw or 'unknown'
    end
    if not causeByHash then
        causeByHash = {}
        local function put(weapon, key)
            causeByHash[GetHashKey(weapon) & 0xFFFFFFFF] = key
        end
        put('WEAPON_FALL',                 'fall')
        put('WEAPON_DROWNING',             'drowned')
        put('WEAPON_DROWNING_IN_VEHICLE',  'drowned')
        put('WEAPON_FIRE',                 'burned')
        put('WEAPON_EXPLOSION',            'explosion')
        put('WEAPON_RAMMED_BY_CAR',        'roadkill')
        put('WEAPON_RUN_OVER_BY_CAR',      'roadkill')
    end
    return causeByHash[raw & 0xFFFFFFFF] or 'unknown'
end

--- Client-reported death. A hint, not an instruction.
RegisterNetEvent(BR.Net.PLAYER_DIED)
AddEventHandler(BR.Net.PLAYER_DIED, function(data)
    local src = source
    local entry = BR.Roster.get(src)
    if not entry then return end

    if not canDie(entry) then
        -- Not necessarily malicious: a report can arrive just after the server
        -- already eliminated them from its own health check.
        if BR.Server.devMode then
            print(('[br_core] ignored death report from %d in state %s')
                :format(src, entry.state))
        end
        return
    end

    -- A recent storm tick outranks whatever the engine blames: the finishing
    -- blow of a storm death often reads as generic damage.
    local cause = describeCause(data and data.cause)
    if entry.lastStormAt and (GetGameTimer() - entry.lastStormAt) < 3000 then
        cause = 'storm'
    end

    -- Resolving the killer from a network id is left to M6, where it can be
    -- validated properly against weapon, distance and fire rate. Crediting a
    -- kill on an unvalidated client claim would be trivially forgeable.
    BR.Combat.eliminate(src, cause, nil)
end)

--- Independent confirmation from server-side health.
---
--- This is the half a cheating client cannot avoid. It requires OneSync, which
--- is also what makes position sampling work -- if the roster shows no peds,
--- this silently does nothing and the boot warning explains why.
BR.Sched.every(1000, 'combat.deathcheck', function()
    -- BUS counts as live: early droppers are on the ground and mortal while
    -- stragglers are still flying, and a death in that window must be
    -- observed like any other. PLAYING-only meant a landed player could not
    -- be server-confirmed dead until the LAST player was down. Checked per
    -- player against THEIR match's state -- matches advance independently.
    BR.Roster.each(function(e)
        if not canDie(e) then return false end
        local m = e.matchId and BR.Server.matches[e.matchId]
        return m ~= nil and (m.state == BR.MatchState.PLAYING
                          or m.state == BR.MatchState.BUS)
    end, function(src, entry)
        if not entry.ped or entry.ped == 0 then return end

        -- engineHp is sampled by roster.positions alongside coordinates.
        if entry.engineHp and BR.IsDeadHp(entry.engineHp) then
            -- A death within moments of a storm tick is a storm death: the
            -- kill feed should say so rather than the generic fallback.
            local cause = 'server-observed'
            if entry.lastStormAt
               and (GetGameTimer() - entry.lastStormAt) < 3000 then
                cause = 'storm'
            end
            print(('[br_core] server observed %s (%d) dead (hp %d) -- eliminating')
                :format(entry.name, src, entry.engineHp))
            BR.Combat.eliminate(src, cause, nil)
        end
    end)
end)

RegisterCommand('brkill', function(_, args)
    local src = tonumber(args[1])
    if not src then
        print('  usage: brkill <serverId>   -- eliminate a player, for testing')
        return
    end
    if not BR.Roster.get(src) then
        print(('  no such player: %d'):format(src))
        return
    end
    BR.Combat.eliminate(src, 'admin', tonumber(args[2]))
end, true)
