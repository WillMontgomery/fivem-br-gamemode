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
--- @param mode string|nil  only players queued for this mode
--- @return integer[]
function BR.Lobby.ids(mode)
    local ids = {}
    for src, q in pairs(queue) do
        if not mode or q.mode == mode then ids[#ids + 1] = src end
    end
    table.sort(ids)
    return ids
end

--- The mode a player is queued for, or nil if they are not queued.
---
--- BR.Party.mayEnter asks this about somebody ELSE -- "is my partymate coming
--- with me" -- which is a question about the queue and belongs to the queue.
--- @param src integer
--- @return string|nil
function BR.Lobby.queuedMode(src)
    local q = queue[src]
    return q and q.mode or nil
end

--- Split a mode's queue into the players a match may take and the ones being
--- held for a party that is not all here yet.
---
--- ONE SPLIT, TWO CALLERS, and that is the point. BR.Match.startBlocker judges
--- the match on `ready` and the formation tick consumes `ready`; the late-join
--- sweep below admits `ready`. A player who is held is held at every door, and
--- there is no second opinion anywhere for the two to drift apart by. See
--- BR.Party.mayEnter for what "held" means and why it always ends.
--- @param mode string
--- @return integer[] ready
--- @return integer[] held
function BR.Lobby.admissible(mode)
    local ready, held = {}, {}
    for _, src in ipairs(BR.Lobby.ids(mode)) do
        if BR.Party.mayEnter(src, mode) then
            ready[#ready + 1] = src
        else
            held[#held + 1] = src
        end
    end
    return ready, held
end

--- Walk everybody the door will now take into an open warmup of this mode.
---
--- Called from BR.Lobby.join (the press itself) and from the match tick (every
--- 250ms, for a player whose party changed while they waited: the last mate
--- readying up, or leaving, or disconnecting). Both routes matter -- a held
--- player is not pressing anything, so without the tick their release would
--- have to wait for somebody else's press.
---
--- SORTED, LOWEST ID FIRST, because BR.Lobby.ids sorts: a party admitted in
--- one sweep puts its first member in a squad and every later member finds it
--- (BR.Party.lateJoin's party scan), instead of each one being autofilled
--- somewhere separate and repaired afterwards by the rebalance.
---
--- The match is re-read INSIDE the loop: admitting a player can fill it, and a
--- full warmup is no longer a forming match. A party that runs out of room
--- half-way through is the one case this cannot keep together -- the last
--- member stays queued and forms the next match instead -- and that is the
--- pre-existing behaviour of a full warmup rather than something the gate
--- introduces: there is no slot to hold for them.
--- @param mode string
function BR.Lobby.admitWaiting(mode)
    for _, src in ipairs(BR.Lobby.admissible(mode)) do
        local m = BR.Server.formingMatch(mode)
        if not m then return end

        local entry = BR.Roster.get(src)
        queue[src] = nil
        print(('[br_core] %s (%d) readied into forming match %d (%s)')
            :format(entry and entry.name or '?', src, m.id, mode))
        BR.Party.lateJoin(src, m)
    end
end

--- Remove a specific set of players from the queue -- the per-mode match
--- formation consumes only ITS mode's queuers, leaving the other mode's
--- queue waiting for its own match.
--- @param ids integer[]
function BR.Lobby.consume(ids)
    for _, src in ipairs(ids) do queue[src] = nil end
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
--[[
    MAINTENANCE BLOCKS THE QUEUE, AND UNTIL NOW IT BLOCKED NOTHING.

    br_ringmaster has always fired `br:ringmaster:blockMatches` when a drain
    begins. NOTHING LISTENED FOR IT. So a drain announced itself in chat, held
    the connect gate against new players, and then let everybody already on the
    server ready up and start a fresh match -- which is the exact outcome
    draining exists to prevent, since that match is the one the restart
    interrupts.

    The flag lives here rather than in match.lua because both consumers need it
    and lobby.lua loads first: readying up is refused outright, and the start
    tick treats it as a blocker so a queue that formed a moment earlier does not
    slip through.
]]
local maintenanceBlock = false

AddEventHandler('br:ringmaster:blockMatches', function(on)
    maintenanceBlock = on == true
end)

--- Are new matches currently held for maintenance?
--- @return boolean
function BR.Lobby.blocked()
    return maintenanceBlock
end

--[[
    EVERY WAY THIS FUNCTION CAN ANSWER NOW SAYS SO ON THE CONSOLE (2026-09-02).

    "not sure how this happened but I readied up and the lobby UI never went
    away. no errors anywhere" -- the owner, and the second report of that shape.
    Both times the only evidence was a screenshot, because this function had
    FOUR endings and exactly ONE of them printed: three of its four ways to
    finish were indistinguishable from the press never having been made.

    The one that matters is the state gate below. A client whose own roster
    mirror has fallen behind -- it believes it is in the lobby, the server has
    it in a match -- presses a live-looking READY UP button and is refused here,
    without a word, for as long as it keeps pressing. That is a permanent,
    silent, un-loggable stall, and it is the shape the screenshots show: the
    lobby camera still parked at the pad and the READY UP button still offered
    rather than the queue spinner that a successful press produces within 500ms.

    THE LINES DO NOT DECIDE ANYTHING. Every branch below is unchanged; each one
    now names itself first. Unconditional, like the queue line at the bottom
    that has always been here -- this is a handful of lines per player per
    round, and the dev switch gates COMMANDS, not the record of what the server
    did with a request.
]]
function BR.Lobby.join(src, mode)
    local entry = BR.Roster.get(src)
    if not entry then
        print(('[br_core] ready up from %d refused: no roster entry'):format(src))
        return
    end

    -- REFUSED AUDIBLY. A ready button that silently does nothing reads as a
    -- broken button, and the player presses it repeatedly rather than learning
    -- why. They are told, once, what is actually happening.
    if maintenanceBlock then
        print(('[br_core] %s (%d) readied up during a drain -- refused')
            :format(entry.name, src))
        TriggerClientEvent(BR.Net.NOTIFY, src, {
            text = 'A server update is pending -- no new matches can be started.',
            tone = 'warn',
            key  = 'maintenance.queue',
            ms   = 6000,
        })
        return
    end

    -- The gate is the PLAYER's state, not the match's. Someone who left the
    -- match (or never joined it) is in the lobby while a match runs, and they
    -- may queue for the next one -- the WAITING tick is the only thing that
    -- consumes the queue, so queueing early just means waiting in line.
    -- Someone still IN a match may not queue; leaving is the explicit verb.
    --
    -- AND THIS IS THE ONE THAT HAS TO SAY THE STATE OUT LOUD. Which state it
    -- read is the whole diagnosis: a player looking at the lobby menu while
    -- this line prints `warmup` is a client mirror that never learned it was
    -- admitted, and a player who really is mid-match pressing a button they
    -- should not be able to see is a different fault entirely. The two are
    -- identical from a chair and one word apart here.
    if entry.state ~= BR.PlayerState.LOBBY then
        print(('[br_core] %s (%d) readied up, but the server has them in %s -- refused')
            :format(entry.name, src, tostring(entry.state)))
        return
    end

    -- Never trust a client-supplied mode: an unknown value falls back rather
    -- than being stored and later used to index a config table.
    local resolved = BR.ResolveMode(mode)

    -- READYING UP CLOSES YOUR OWN INVITES.
    --
    -- Before this, an invite sent and then abandoned by readying up stayed
    -- live for its full 60s TTL: the recipient could accept into a party
    -- whose leader was already in warmup, or on the far side of a bus ride
    -- (user, 2026-08-08). It has to happen HERE rather than after the
    -- queue/lateJoin branch below, because the late-join path returns early
    -- -- and joining a forming match is exactly the case where the invite is
    -- most stale.
    BR.Party.withdrawInvitesFrom(src, 'they readied up')

    -- Queueing SOLO while in a party is a contradiction, and the resolution is
    -- the one the player asked for most recently: solo wins, the party is left.
    -- There is deliberately no "in a party but playing alone" state -- it made
    -- the lobby read as though the party would ride along, then didn't.
    if resolved.key == BR.Mode.SOLO.key and BR.Party.isGrouped(src) then
        BR.Party.leave(src)
    end

    -- THE QUEUE FIRST, EVEN FOR SOMEBODY WHO IS ABOUT TO WALK STRAIGHT PAST IT.
    --
    -- The late-join door below admits a whole party at once, and it reads the
    -- queue to know who is coming (BR.Party.mayEnter). A player who is not in
    -- it yet is invisible to their own admission: the last of two friends to
    -- press Ready would be let in alone and the first left waiting, which is
    -- the bug this change exists to remove, wearing the other member's name.
    --
    -- It is also what keeps the partymate's screen honest. "Ready up! Your
    -- party is waiting." is drawn from the queued ids on LOBBY_STATUS, so a
    -- player held at the door goes on saying they are ready for as long as they
    -- are waiting -- the same trigger, the same string, now telling the truth
    -- for the whole of the wait instead of the second before admission.
    queue[src] = { mode = resolved.key, at = GetGameTimer() }

    -- While a match OF THE MODE THEY PICKED sits in open warmup (not full),
    -- readying up joins it directly instead of queueing for the one after
    -- it. Matches are homogeneous (user call, 2026-08-04): a solo queuer
    -- must never be absorbed into a squad warmup or vice versa -- they
    -- queue instead, and the per-mode formation tick builds their own
    -- match alongside the open one. Both warmups share the communal warmup
    -- bucket; the flights and everything after are separate.
    --
    -- AND THIS DOOR IS GATED NOW (2026-09-02). It used to admit anybody who
    -- pressed Ready, party or no party, which made the queue's party gate
    -- irrelevant the moment any warmup was open -- see BR.Party.mayEnter for
    -- the report and the mechanism. A player their party is not ready to
    -- follow stays in the queue and is swept in by the match tick the moment
    -- it is.
    --
    -- THIS PATH STILL NEEDS ITS OWN LINE, and BR.Lobby.admitWaiting prints it:
    -- a late joiner leaves the queue in the same breath they entered it, so
    -- nothing about them reaches the queue broadcast and the bottom of this
    -- function is not reached -- the busiest door into a match was the
    -- quietest one in the log.
    if BR.Server.formingMatch(resolved.key) then
        BR.Lobby.admitWaiting(resolved.key)
        if not queue[src] then return end
    end

    -- ONE LINE PER PRESS, AND IT SAYS WHICH KIND OF WAIT THIS IS. A queue that
    -- is one short of starting and a queue nobody in it may be admitted from
    -- read identically as a number, and the second is the one that looks like
    -- the server ignoring a button.
    print(('[br_core] %s (%d) queued for %s -- %d/%d%s')
        :format(entry.name, src, resolved.key, BR.Lobby.count(), BR.Lobby.needed(),
                BR.Party.mayEnter(src, resolved.key) and ''
                    or ' -- held until their party readies up'))
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

--- The player picked a mode tile.
---
--- SOLO AND A PARTY CANNOT COEXIST, and the rule is applied HERE, at the
--- moment of choice, rather than only when they ready up. It was previously
--- the client's job: the lobby screen fired a SQUAD_LEAVE off its own derived
--- "am I in a party" boolean, and when that stopped working the party simply
--- survived into a solo queue with nothing on the server to catch it (user,
--- 2026-08-09).
---
--- Idempotent and cheap: BR.Party.leave returns immediately for a player who
--- has no party, so the UI can send this on every tile press without caring
--- what state it is in -- which is the point, because the UI knowing what
--- state it is in was the thing that failed.
RegisterNetEvent(BR.Net.MODE_SET)
AddEventHandler(BR.Net.MODE_SET, function(data)
    local src = source
    local entry = BR.Roster.get(src)
    if not entry or entry.state ~= BR.PlayerState.LOBBY then return end

    if BR.ResolveMode(data and data.mode).key == BR.Mode.SOLO.key then
        BR.Party.leave(src)
    end
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
        local party = BR.Party.of(src)
        players[#players + 1] = {
            src     = src,
            name    = e.name,
            -- isGrouped, not `partyId ~= nil`: a party of one is not a party,
            -- and treating it as one made the player invisible to invites.
            inParty = BR.Party.isGrouped(src),
            -- The Join tab lists leaders; the Create tab must not offer
            -- players who are mid-match. Both facts are already visible in
            -- a lobby, so nothing new leaks.
            leader  = (party ~= nil and party.leader == src
                       and BR.Party.isGrouped(src)) or false,
            inMatch = BR.Server.isInMatch(e.state),
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
