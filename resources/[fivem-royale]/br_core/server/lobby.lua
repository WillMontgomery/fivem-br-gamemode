-- The queue.
--
-- Being connected and wanting to play are different things, and until now the
-- match started on the CONNECTED count -- so pressing Play did nothing at all
-- (the UI's queue callback was forwarded to an event nobody handled), while
-- anyone idling in the lobby was dragged into a match they never asked for.
--
-- The queue is the server's list of players who have actually opted in.

BR = BR or {}
BR.Lobby = {}

-- [src] = { mode = 'solo'|'squad', at = ms }
local queue = {}
BR.Server.queue = queue

--- @return integer
function BR.Lobby.count()
    local n = 0
    for _ in pairs(queue) do n = n + 1 end
    return n
end

--- How many players are needed before a match can start.
--- @return integer
function BR.Lobby.needed()
    return BR.Config.Match.MinPlayers(BR.Server.devMode)
end

--- The queued player ids.
---
--- Sorted, so anything derived from the queue is reproducible -- `pairs` order
--- is undefined and would make squad packing differ between identical lobbies.
--- @return integer[]
function BR.Lobby.ids()
    local ids = {}
    for src in pairs(queue) do ids[#ids + 1] = src end
    table.sort(ids)
    return ids
end

--- The mode the next match should run, decided by majority of the queue.
---
--- Ties fall to squad: a solo player dropped into a squad match still plays,
--- whereas a squad dropped into solos loses the mode they queued for entirely.
--- @return string
function BR.Lobby.dominantMode()
    local tally = {}
    for _, q in pairs(queue) do
        tally[q.mode] = (tally[q.mode] or 0) + 1
    end

    -- The tie-break is explicit rather than incidental. `pairs` has no defined
    -- order, so a plain `n > bestN` would resolve a tie differently from one
    -- call to the next -- two players queueing 1 solo / 1 squad would get an
    -- arbitrary mode, and the same input would not reproduce.
    local SQUAD = BR.Mode.SQUAD.key
    local best, bestN = SQUAD, -1
    for mode, n in pairs(tally) do
        if n > bestN or (n == bestN and mode == SQUAD) then
            best, bestN = mode, n
        end
    end
    return best
end

--- @param src integer
--- @param mode string
function BR.Lobby.join(src, mode)
    local entry = BR.Roster.get(src)
    if not entry then return end

    -- Queueing mid-match is meaningless; they will be picked up at cleanup.
    if BR.Server.match.state ~= BR.MatchState.WAITING
       and BR.Server.match.state ~= BR.MatchState.CLEANUP then
        return
    end

    -- Never trust a client-supplied mode: an unknown value falls back rather
    -- than being stored and later used to index a config table.
    local resolved = BR.ResolveMode(mode)
    queue[src] = { mode = resolved.key, at = GetGameTimer() }

    print(('[br_core] %s (%d) queued for %s -- %d/%d')
        :format(entry.name, src, resolved.key, BR.Lobby.count(), BR.Lobby.needed()))
end

--- @param src integer
function BR.Lobby.leave(src)
    if not queue[src] then return end
    queue[src] = nil

    local entry = BR.Roster.get(src)
    print(('[br_core] %s (%d) left the queue -- %d/%d')
        :format(entry and entry.name or '?', src, BR.Lobby.count(), BR.Lobby.needed()))
end

--- Clear the queue. Called when a match starts, so players are not left queued
--- for the match they are already playing.
function BR.Lobby.clear()
    queue = {}
    BR.Server.queue = queue
end

RegisterNetEvent(BR.Net.QUEUE_JOIN)
AddEventHandler(BR.Net.QUEUE_JOIN, function(data)
    BR.Lobby.join(source, data and data.mode)
end)

RegisterNetEvent(BR.Net.QUEUE_LEAVE)
AddEventHandler(BR.Net.QUEUE_LEAVE, function()
    BR.Lobby.leave(source)
end)

AddEventHandler('playerDropped', function()
    queue[source] = nil
end)

--- Queue progress, so a waiting player can see WHY they are waiting.
---
--- "Searching for players" with no numbers behind it is indistinguishable from
--- a broken queue, which is exactly how it looked when the button did nothing.
BR.Sched.every(500, 'lobby.status', function()
    if BR.Server.match.state ~= BR.MatchState.WAITING then return end

    -- The ids ride along so each client can tell whether IT is queued.
    --
    -- Sending only a count meant a client had no way to know: after a match
    -- consumed the queue and fell back to WAITING, players were left showing
    -- "Searching..." forever against a server that had never heard of them.
    -- One broadcast with ids is cheaper than 48 targeted messages and is
    -- self-correcting -- a client that misses one is fixed by the next.
    local ids = {}
    for src in pairs(queue) do ids[#ids + 1] = src end

    -- The connected player list, so inviting does not require knowing someone's
    -- server id. Asking players to type an id they have no way to discover is
    -- not a feature, and was the only way to invite until now.
    --
    -- Names and ids only -- no positions, nothing that is not already visible
    -- in a lobby.
    local players = {}
    BR.Roster.each(nil, function(src, e)
        players[#players + 1] = {
            src     = src,
            name    = e.name,
            inParty = e.partyId ~= nil,
            queued  = queue[src] ~= nil,
        }
    end)
    table.sort(players, function(a, b) return a.src < b.src end)

    TriggerClientEvent(BR.Net.LOBBY_STATUS, -1, {
        queued    = BR.Lobby.count(),
        needed    = BR.Lobby.needed(),
        connected = BR.Server.count(),
        mode      = BR.Lobby.dominantMode(),
        ids       = ids,
        players   = players,
    })
end)

RegisterCommand('brqueue', function()
    print('=== queue ===')
    print(('  %d queued, %d needed, %d connected')
        :format(BR.Lobby.count(), BR.Lobby.needed(), BR.Server.count()))
    for src, q in pairs(queue) do
        local e = BR.Roster.get(src)
        print(('  %-3d %-18s %s'):format(src, e and e.name or '?', q.mode))
    end
    if BR.Lobby.count() == 0 then print('  (nobody queued)') end
end, true)
