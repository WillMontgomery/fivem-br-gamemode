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

    -- The gate is the PLAYER's state, not the match's. Someone who left the
    -- match (or never joined it) is in the lobby while a match runs, and they
    -- may queue for the next one -- the WAITING tick is the only thing that
    -- consumes the queue, so queueing early just means waiting in line.
    -- Someone still IN a match may not queue; leaving is the explicit verb.
    if entry.state ~= BR.PlayerState.LOBBY then
        return
    end

    -- Never trust a client-supplied mode: an unknown value falls back rather
    -- than being stored and later used to index a config table.
    local resolved = BR.ResolveMode(mode)

    -- Queueing SOLO while in a party is a contradiction, and the resolution is
    -- the one the player asked for most recently: solo wins, the party is left.
    -- There is deliberately no "in a party but playing alone" state -- it made
    -- the lobby read as though the party would ride along, then didn't.
    if resolved.key == BR.Mode.SOLO.key and BR.Party.isGrouped(src) then
        BR.Party.leave(src)
    end

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
    -- Broadcast in EVERY match state, not only WAITING: a player who left the
    -- match is standing in the lobby while others play, and without this they
    -- would queue into silence -- no counts, no reason, exactly the "is it
    -- broken?" screen this payload exists to prevent.
    --
    -- In-match clients receive it too and ignore it; at 2Hz with a name list
    -- this is far below the deltas the match itself generates.

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
            -- isGrouped, not `partyId ~= nil`: a party of one is not a party,
            -- and treating it as one made the player invisible to invites.
            inParty = BR.Party.isGrouped(src),
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

        -- WHY the match has not started, straight from the function the tick
        -- uses to decide -- so the explanation cannot describe a condition that
        -- is not the one actually holding the match.
        --
        -- nil when nothing is blocking, which drops the key entirely. Safe only
        -- because this payload is rebuilt whole every time rather than merged:
        -- the client sees the reason vanish instead of keeping the last one.
        wait      = BR.Match.startBlocker(),
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
