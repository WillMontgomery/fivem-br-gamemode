-- Parties.
--
-- A PARTY is a persistent group of friends. A SQUAD is the in-match team formed
-- from parties plus autofilled solo queuers. Keeping them separate is what lets
-- a party survive a match ending -- and a match ending is exactly when a
-- squad-based group would otherwise dissolve, forcing everyone to re-invite each
-- other between every round.
--
--   roster[src].partyId   persistent, survives matches, cleared only on leave
--   roster[src].squadId   per-match, assigned at warmup, cleared at cleanup
--
-- Parties are server state. A client can ask to invite, accept, decline, leave
-- or kick; it cannot assert membership.

BR = BR or {}
BR.Party = {}

-- [partyId] = { id, leader = src, members = { src, ... }, createdAt }
local parties = {}
BR.Server.parties = parties

-- [targetSrc] = { partyId, from = src, at = ms }
local invites = {}

-- [requesterSrc] = { leader = src, at = ms } -- join requests, invites in reverse
local joinReqs = {}

local nextId = 0

--- Squad colours, assigned in order. Kept small and high-contrast: these have to
--- be distinguishable at a glance on a HUD, over any terrain. NO PURPLE,
--- ever -- purple is the storm's colour and nothing squad-owned (tags,
--- smoke trails, map markers) may be mistaken for it (user call,
--- 2026-08-04); the old violet slot is teal now.
local COLOURS = {
    '#6EE7F9', '#2DD4BF', '#FBBF24', '#F472B6',
    '#4ADE80', '#FB923C', '#60A5FA', '#F87171',
}

local INVITE_TTL_MS = 60000

-- ---------------------------------------------------------------- helpers ---

local function newPartyId()
    nextId = nextId + 1
    return ('p%d'):format(nextId)
end

--- @param src integer
--- @return table|nil
function BR.Party.of(src)
    local entry = BR.Roster.get(src)
    if not entry or not entry.partyId then return nil end
    return parties[entry.partyId]
end

--- @param partyId string
--- @return integer
function BR.Party.size(partyId)
    local p = parties[partyId]
    return p and #p.members or 0
end

--- Is this player actually grouped with somebody?
---
--- Not the same question as "has a partyId". BR.Party.invite creates the
--- inviter's party before the invite is answered, so an invite that is declined
--- leaves a party of one behind. Membership alone would then mark that player
--- as unavailable and hide them from every invite list -- punishing them for
--- having asked. Only a party with somebody else in it counts.
--- @param src integer
--- @return boolean
function BR.Party.isGrouped(src)
    local p = BR.Party.of(src)
    return p ~= nil and #p.members > 1
end

--- The client-visible view of a party.
--- @param partyId string|nil
--- @return table
function BR.Party.public(partyId)
    local p = partyId and parties[partyId]
    if not p then return { id = nil, leader = nil, members = {} } end

    local members = {}
    for i, src in ipairs(p.members) do
        local e = BR.Roster.get(src)
        members[#members + 1] = {
            src    = src,
            name   = e and e.name or '?',
            state  = e and e.state or BR.PlayerState.LEFT,
            hp     = e and e.hp or 0,
            armour = e and e.armour or 0,
            leader = (src == p.leader),
            colour = COLOURS[((i - 1) % #COLOURS) + 1],
        }
    end

    -- Invites still waiting for an answer. Without this the sender's only
    -- feedback was a transient "Invite sent." -- once that faded, an invite
    -- that was ignored, declined, or expired all looked identical: like
    -- nothing had ever been sent.
    local pending = {}
    for target, inv in pairs(invites) do
        if inv.partyId == p.id then
            local e = BR.Roster.get(target)
            pending[#pending + 1] = { src = target, name = e and e.name or '?' }
        end
    end
    table.sort(pending, function(a, b) return a.src < b.src end)

    return { id = p.id, leader = p.leader, members = members, pending = pending }
end

--- Push the current party state to every member.
--- @param partyId string|nil
local function sync(partyId)
    local p = partyId and parties[partyId]
    if not p then return end
    local payload = BR.Party.public(partyId)
    for _, src in ipairs(p.members) do
        TriggerClientEvent(BR.Net.SQUAD_UPDATE, src, payload)
    end
end

--- Tell one player they have no party.
local function syncEmpty(src)
    TriggerClientEvent(BR.Net.SQUAD_UPDATE, src, { id = nil, leader = nil, members = {} })
end

-- ------------------------------------------------------------------ verbs ---

--- Create a party around a player, or return their existing one.
--- @param src integer
--- @return table|nil
function BR.Party.ensure(src)
    local entry = BR.Roster.get(src)
    if not entry then return nil end
    if entry.partyId and parties[entry.partyId] then
        return parties[entry.partyId]
    end

    local id = newPartyId()
    parties[id] = {
        id        = id,
        leader    = src,
        members   = { src },
        createdAt = GetGameTimer(),
    }
    entry.partyId = id
    return parties[id]
end

--- Invite a player. Creates the inviter's party if they do not have one, so
--- there is no separate "create party" step to forget.
--- @param src integer
--- @param targetSrc integer
--- @return boolean ok
--- @return string|nil reason
function BR.Party.invite(src, targetSrc)
    if src == targetSrc then return false, 'You cannot invite yourself.' end

    local target = BR.Roster.get(targetSrc)
    if not target then return false, 'That player is not connected.' end

    local party = BR.Party.ensure(src)
    if not party then return false, 'You are not on the roster yet.' end

    if party.leader ~= src then
        return false, 'Only the party leader can invite.'
    end
    if #party.members >= BR.Config.Match.maxSquadSize then
        return false, ('Party is full (%d).'):format(BR.Config.Match.maxSquadSize)
    end
    if target.partyId == party.id then
        return false, 'They are already in your party.' end

    invites[targetSrc] = { partyId = party.id, from = src, at = GetGameTimer() }

    local inviter = BR.Roster.get(src)
    TriggerClientEvent(BR.Net.SQUAD_INVITED, targetSrc, {
        partyId = party.id,
        from    = src,
        name    = inviter and inviter.name or '?',
        size    = #party.members,
        max     = BR.Config.Match.maxSquadSize,
    })

    -- The pending list changed, so the party sees the invite it is waiting on.
    sync(party.id)

    return true
end

--- Accept or decline a pending invite.
--- @param src integer
--- @param accept boolean
--- @return boolean ok
--- @return string|nil reason
function BR.Party.respond(src, accept)
    local inv = invites[src]
    invites[src] = nil

    if not inv then return false, 'No pending invite.' end

    local responder = BR.Roster.get(src)
    local rName = responder and responder.name or '?'

    if not accept then
        -- The inviter must HEAR the no. Silence after an invite is
        -- indistinguishable from the invite never arriving, so senders
        -- re-invited people who had already said no.
        local party = parties[inv.partyId]
        if party then
            BR.Server.notify(inv.from, ('%s declined your invite.'):format(rName), 'warn')
            sync(party.id)   -- the pending chip goes away for everyone
        end
        return true
    end

    local party = parties[inv.partyId]
    if not party then return false, 'That party no longer exists.' end
    if #party.members >= BR.Config.Match.maxSquadSize then
        return false, 'That party is now full.'
    end

    -- Leaving the old party first keeps membership single-valued; a player in
    -- two parties would be assigned to two squads.
    BR.Party.leave(src, true)

    local entry = BR.Roster.get(src)
    if not entry then return false, 'You are not on the roster.' end

    party.members[#party.members + 1] = src
    entry.partyId = party.id

    sync(party.id)
    BR.Server.notify(src, 'You joined the party.', 'success')
    for _, m in ipairs(party.members) do
        if m ~= src then
            BR.Server.notify(m, ('%s joined the party.'):format(entry.name), 'success')
        end
    end
    return true
end

--- Leave the current party.
---
--- @param src integer
--- @param quiet boolean|nil  suppress the message (used when switching parties)
function BR.Party.leave(src, quiet)
    local entry = BR.Roster.get(src)
    if not entry or not entry.partyId then return end

    local party = parties[entry.partyId]
    entry.partyId = nil

    if not party then
        syncEmpty(src)
        return
    end

    for i = #party.members, 1, -1 do
        if party.members[i] == src then table.remove(party.members, i) end
    end

    -- A PARTY OF ONE IS NOT A PARTY, and leaving one behind is a trap.
    --
    -- The remaining player's own interface correctly says "not in a party" --
    -- there is nobody else in it -- while the server still reports them as
    -- partied, which filters them out of every other player's invite list. They
    -- end up unable to be invited and unable to see why, with no control
    -- anywhere that fixes it. Disbanding on the way down to one keeps the
    -- server's answer and the player's answer the same.
    if #party.members <= 1 then
        for _, last in ipairs(party.members) do
            local e = BR.Roster.get(last)
            if e then e.partyId = nil end
            syncEmpty(last)
        end
        parties[party.id] = nil
    else
        -- The leader leaving must not orphan the party; the longest-standing
        -- remaining member takes over.
        if party.leader == src then
            party.leader = party.members[1]
        end
        if not quiet then
            BR.Server.notify(party.members,
                ('%s left the party.'):format(entry.name), 'warn')
        end
        sync(party.id)
    end

    if not quiet then
        BR.Server.notify(src, 'You left the party.', 'info')
    end
    syncEmpty(src)
end

--- Remove someone else from the party. Leader only.
--- @param src integer
--- @param targetSrc integer
--- @return boolean ok
--- @return string|nil reason
function BR.Party.kick(src, targetSrc)
    local party = BR.Party.of(src)
    if not party then return false, 'You are not in a party.' end
    if party.leader ~= src then return false, 'Only the leader can remove members.' end
    if targetSrc == src then return false, 'Use leave instead.' end

    local target = BR.Roster.get(targetSrc)
    if not target or target.partyId ~= party.id then
        return false, 'They are not in your party.'
    end

    BR.Party.leave(targetSrc, true)
    TriggerClientEvent(BR.Net.SQUAD_UPDATE, targetSrc,
        { id = nil, leader = nil, members = {} })
    BR.Server.notify(targetSrc, 'You were removed from the party.', 'danger')
    BR.Server.notify(party.members,
        ('%s was removed from the party.'):format(target.name), 'warn')
    return true
end

-- ------------------------------------------------------- squad formation ---

--- Form in-match squads from parties and the queue.
---
--- Called when a match starts. Parties are kept intact; solo queuers are filled
--- into the gaps. Solo mode leaves everyone unsquadded -- in solo, each player
--- is their own team and a squadId would only confuse the win condition.
---
--- @param mode string
--- How many squads a given set of players WOULD form, without forming them.
---
--- Deliberately mirrors the arithmetic in formSquads below. The two must agree:
--- if this says two squads and formSquads then produces one, the match starts
--- into an instant win, which is precisely the failure this exists to prevent.
--- Any change to the packing rules belongs in both.
---
--- @param srcs integer[]  the players who would be in the match
--- @param mode string
--- @return integer
function BR.Party.prospectiveSquads(srcs, mode)
    if mode == BR.Mode.SOLO.key then return #srcs end

    local maxSize = BR.Config.Match.maxSquadSize

    -- Party members only count if they are in this set; a partied player who
    -- did not queue is not in the match.
    local sizes, solos = {}, 0
    for _, src in ipairs(srcs) do
        local p = BR.Party.of(src)
        if p then
            sizes[p.id] = (sizes[p.id] or 0) + 1
        else
            solos = solos + 1
        end
    end

    local squads, capacity = 0, 0
    for _, n in pairs(sizes) do
        squads = squads + 1
        capacity = capacity + math.max(0, maxSize - n)
    end

    if BR.Config.Match.autofill then
        squads = squads + math.ceil(math.max(0, solos - capacity) / maxSize)
    else
        squads = squads + solos
    end
    return squads
end

function BR.Party.formSquads(mode)
    -- Clear last match's squads first; squadId is per-match, partyId is not.
    -- clearFields rather than direct assignment, because a nil cannot travel in
    -- a delta -- assigning it left every client displaying the previous match's
    -- squad indefinitely, most visibly when switching from squads to solo.
    BR.Roster.each(nil, function(src)
        BR.Roster.clearFields(src, { 'squadId', 'colour' })
    end)

    if mode == BR.Mode.SOLO.key then
        print('[br_core] solo match -- no squads formed')
        return
    end

    local maxSize = BR.Config.Match.maxSquadSize
    local squads = {}      -- array of { members = {src...} }
    local placed = {}

    -- Parties first, in one piece. Splitting a party across squads would be the
    -- single most annoying thing this system could do.
    for _, party in pairs(parties) do
        local members = {}
        for _, src in ipairs(party.members) do
            local e = BR.Roster.get(src)
            if e and BR.Server.isInMatch(e.state) then
                members[#members + 1] = src
                placed[src] = true
            end
        end
        if #members > 0 then
            squads[#squads + 1] = { members = members }
        end
    end

    -- Then everyone else, filling existing squads before opening new ones.
    local solos = {}
    BR.Roster.each(
        function(e) return BR.Server.isInMatch(e.state) end,
        function(src) if not placed[src] then solos[#solos + 1] = src end end)
    table.sort(solos)

    if BR.Config.Match.autofill then
        -- Spread solos across squads rather than packing each one full before
        -- opening the next.
        --
        -- Greedy fill orphans people. Five solos at a cap of four gives 4 + 1,
        -- and that last player spends a squad round alone against full teams --
        -- which is the whole complaint about "solos in a squad match". Opening
        -- enough squads up front and dealing round-robin gives 3 + 2 instead.
        --
        -- Enough squads are opened up front to hold everyone, then each solo
        -- goes to the emptiest one with room. A part-full party gets topped up
        -- only once the new squads have caught up to its size, which is what
        -- keeps the teams even.
        local capacity = 0
        for _, sq in ipairs(squads) do capacity = capacity + (maxSize - #sq.members) end

        local extra = math.ceil(math.max(0, #solos - capacity) / maxSize)
        for _ = 1, extra do squads[#squads + 1] = { members = {} } end

        for _, src in ipairs(solos) do
            -- Always the emptiest squad with room, so the sizes stay level.
            local target
            for _, sq in ipairs(squads) do
                if #sq.members < maxSize
                   and (not target or #sq.members < #target.members) then
                    target = sq
                end
            end
            -- Only reachable if capacity was miscounted; opening a squad beats
            -- dropping a player out of the match entirely.
            if not target then
                target = { members = {} }
                squads[#squads + 1] = target
            end
            target.members[#target.members + 1] = src
        end
    else
        for _, src in ipairs(solos) do
            squads[#squads + 1] = { members = { src } }
        end
    end

    -- Assign ids and colours.
    for i, sq in ipairs(squads) do
        local id = ('sq%d'):format(i)
        local colour = COLOURS[((i - 1) % #COLOURS) + 1]
        for _, src in ipairs(sq.members) do
            local e = BR.Roster.get(src)
            if e then
                e.squadId = id
                e.colour  = colour
                BR.Broadcast.delta({ op = 'update', src = src,
                                     e = { squadId = id, colour = colour } })
            end
        end
    end

    -- Tell every player who they are playing with, and why.
    --
    -- Without this, being autofilled onto a squad is indistinguishable from an
    -- invite having worked: two unpartied players queue, land on the same
    -- squad, and neither has any idea how that happened. A NOTICE, not system
    -- chat -- the chat is for players talking (user rule, 2026-08-03), and
    -- the squad panel shows the roster anyway; this only flags the surprise.
    for _, sq in ipairs(squads) do
        if #sq.members > 1 then
            for _, src in ipairs(sq.members) do
                local mine = BR.Roster.get(src)
                local partied = false
                for _, other in ipairs(sq.members) do
                    if other ~= src then
                        local e = BR.Roster.get(other)
                        if mine and e and mine.partyId and mine.partyId == e.partyId then
                            partied = true
                        end
                    end
                end
                if not partied then
                    BR.Server.notify(src,
                        'Squad filled automatically — check the squad panel.',
                        'info')
                end
            end
        end
    end

    print(('[br_core] formed %d squad(s) for %s'):format(#squads, mode))
end

--- Pull a late arrival into the match during WARMUP.
---
--- The bus has not left; there is no reason to make someone who readied up
--- thirty seconds late sit out the whole round. They join the forming match
--- exactly as if they had queued in time: their party's squad first, then the
--- emptiest squad with room, then a squad of their own -- the same preference
--- order formSquads uses, applied to one person.
---
--- WARMUP only. From BUS onward the drop is in motion and a new player would
--- materialise into a match with no way aboard; those queue for the next one.
--- @param src integer
function BR.Party.lateJoin(src)
    local entry = BR.Roster.get(src)
    if not entry then return end

    BR.Roster.setState(src, BR.PlayerState.WARMUP)

    if BR.Server.match.mode ~= BR.Mode.SQUAD.key then
        BR.Server.notify(src, 'Joined the match -- dropping soon.', 'success')
        if BR.Bus and BR.Bus.sendPreview then BR.Bus.sendPreview(src) end
        return
    end

    local maxSize = BR.Config.Match.maxSquadSize

    -- Whatever squads exist right now, counted from the roster: sorted ids so
    -- the tie-break between equally empty squads is reproducible.
    local counts, colours, ids, maxIdx = {}, {}, {}, 0
    BR.Roster.each(nil, function(_, e)
        if e.squadId then
            if not counts[e.squadId] then
                ids[#ids + 1] = e.squadId
                counts[e.squadId] = 0
                colours[e.squadId] = e.colour
            end
            counts[e.squadId] = counts[e.squadId] + 1
            local n = tonumber(e.squadId:match('^sq(%d+)$'))
            if n and n > maxIdx then maxIdx = n end
        end
    end)
    table.sort(ids)

    -- Their party's squad first: friends who queued in time must not end up
    -- on a different team because one of them was slow to click.
    local target
    local party = entry.partyId and parties[entry.partyId]
    if party then
        for _, m in ipairs(party.members) do
            local mate = BR.Roster.get(m)
            if m ~= src and mate and mate.squadId
               and BR.Server.isInMatch(mate.state)
               and counts[mate.squadId] < maxSize then
                target = mate.squadId
                break
            end
        end
    end

    if not target and BR.Config.Match.autofill then
        for _, id in ipairs(ids) do
            if counts[id] < maxSize
               and (not target or counts[id] < counts[target]) then
                target = id
            end
        end
    end

    local colour
    if target then
        colour = colours[target]
    else
        target = ('sq%d'):format(maxIdx + 1)
        colour = COLOURS[(maxIdx % #COLOURS) + 1]
    end

    entry.squadId, entry.colour = target, colour
    BR.Broadcast.delta({ op = 'update', src = src,
                         e = { squadId = target, colour = colour } })

    BR.Server.notify(src, 'Joined the match -- dropping soon.', 'success')
    for other, e in pairs(BR.Server.roster) do
        if other ~= src and e.squadId == target then
            BR.Server.notify(other, ('%s joined your squad.'):format(entry.name), 'success')
        end
    end

    -- The room saw the flight preview when warmup began; the late arrival
    -- needs their own copy to plan a drop with.
    if BR.Bus and BR.Bus.sendPreview then BR.Bus.sendPreview(src) end

    print(('[br_core] %s (%d) late-joined warmup on %s'):format(entry.name, src, target))
end

-- ---------------------------------------------------------- squad beacons ---

-- Squadmate positions, to squad members ONLY.
--
-- This is the single deliberate exception to "positions never leave the
-- server": your own squad is the one set of players you are supposed to know
-- about, and squad blips are unbuildable without it. The privacy line holds
-- everywhere else -- nothing here can ever reach a player outside the squad,
-- and the roster's public view still carries no positions at all. There is a
-- wire test pinning both properties.
BR.Sched.every(1000, 'party.squadpos', function()
    local ms = BR.Server.match.state
    if ms ~= BR.MatchState.WARMUP
       and ms ~= BR.MatchState.BUS
       and ms ~= BR.MatchState.PLAYING then
        return
    end

    -- Group living squad members. Solos have no squadId and are never sent.
    local squads = {}
    BR.Roster.each(nil, function(src, e)
        if e.squadId and e.pos
           and (BR.Server.isInMatch(e.state) or e.state == BR.PlayerState.DBNO) then
            local sq = squads[e.squadId]
            if not sq then
                sq = {}
                squads[e.squadId] = sq
            end
            sq[#sq + 1] = {
                src   = src,
                name  = e.name,
                x     = e.pos.x,
                y     = e.pos.y,
                state = e.state,
            }
        end
    end)

    for _, members in pairs(squads) do
        if #members > 1 then
            -- Stable member index -> stable blip colour on every client.
            table.sort(members, function(a, b) return a.src < b.src end)
            for i, m in ipairs(members) do m.i = i end
            for _, m in ipairs(members) do
                TriggerClientEvent(BR.Net.SQUAD_POS, m.src, members)
            end
        end
    end
end)

-- --------------------------------------------------------------- plumbing ---

--- Send an invite/kick outcome back to whoever asked, so a failure is visible
--- where the player is looking. Chat alone was not enough: an invite that
--- silently did nothing looked identical to one that worked.
--- @param src integer
--- @param ok boolean
--- @param reason string|nil
local function result(src, ok, reason)
    -- FAILURES ONLY. Every success in this file already announces itself
    -- through the notify channel or a visible state change (the pending chip,
    -- the member list) -- sending a result too produced pairs like
    -- "You joined the party." / "Joined the party." stacked on screen.
    -- A failure has no other voice, so it still speaks here.
    if ok then return end
    TriggerClientEvent(BR.Net.SQUAD_RESULT, src, { ok = ok, reason = reason })
end

RegisterNetEvent(BR.Net.SQUAD_INVITE)
AddEventHandler(BR.Net.SQUAD_INVITE, function(data)
    local src = source
    local ok, reason = BR.Party.invite(src, tonumber(data and data.target))
    result(src, ok, reason)
end)

RegisterNetEvent(BR.Net.SQUAD_RESPOND)
AddEventHandler(BR.Net.SQUAD_RESPOND, function(data)
    local src = source
    local ok, reason = BR.Party.respond(src, data and data.accept)
    result(src, ok, reason)
end)

-- --------------------------------------------------------------------------
-- Join requests: the invite, reversed. A player asks a party LEADER to take
-- them; the leader answers. Same shape as invites -- one outstanding request
-- per requester, expiring on the same sweep -- so every property invites
-- earned (audible declines, expiry notices) is inherited rather than rebuilt.
-- --------------------------------------------------------------------------

--- @param src integer        the requester
--- @param leaderSrc integer  the party leader being asked
--- @return boolean ok
--- @return string|nil reason
function BR.Party.requestJoin(src, leaderSrc)
    if src == leaderSrc then return false, 'That is you.' end
    local entry = BR.Roster.get(src)
    if not entry then return false, 'You are not on the roster yet.' end
    if BR.Party.isGrouped(src) then
        return false, 'Leave your current party first.'
    end

    local lp = BR.Party.of(leaderSrc)
    if not lp or lp.leader ~= leaderSrc then
        return false, 'That player is not leading a party.'
    end
    if #lp.members >= BR.Config.Match.maxSquadSize then
        return false, 'That party is full.'
    end
    local le = BR.Roster.get(leaderSrc)
    if le and BR.Server.isInMatch(le.state) then
        return false, 'That party is in a match right now.'
    end

    joinReqs[src] = { leader = leaderSrc, at = GetGameTimer() }
    TriggerClientEvent(BR.Net.SQUAD_JOINASK, leaderSrc, {
        from = src,
        name = entry.name,
        size = #lp.members,
        max  = BR.Config.Match.maxSquadSize,
    })
    BR.Server.notify(src, 'Join request sent.', 'info')
    return true
end

--- The leader's answer.
--- @param leaderSrc integer
--- @param requesterSrc integer
--- @param accept boolean
--- @return boolean ok
--- @return string|nil reason
function BR.Party.answerJoin(leaderSrc, requesterSrc, accept)
    local req = joinReqs[requesterSrc]
    if not req or req.leader ~= leaderSrc then
        return false, 'No such join request.'
    end
    joinReqs[requesterSrc] = nil

    local rq = BR.Roster.get(requesterSrc)
    if not rq then return false, 'They are no longer connected.' end

    if not accept then
        BR.Server.notify(requesterSrc, 'Your join request was declined.', 'warn')
        return true
    end

    local party = BR.Party.of(leaderSrc)
    if not party or party.leader ~= leaderSrc then
        return false, 'Your party no longer exists.'
    end
    if #party.members >= BR.Config.Match.maxSquadSize then
        BR.Server.notify(requesterSrc, 'That party is now full.', 'warn')
        return false, 'Party is full.'
    end

    if rq.partyId then BR.Party.leave(requesterSrc, true) end
    party.members[#party.members + 1] = requesterSrc
    rq.partyId = party.id

    sync(party.id)
    BR.Server.notify(requesterSrc, 'You joined the party.', 'success')
    for _, m in ipairs(party.members) do
        if m ~= requesterSrc then
            BR.Server.notify(m, ('%s joined the party.'):format(rq.name), 'success')
        end
    end
    return true
end

RegisterNetEvent(BR.Net.SQUAD_JOINREQ)
AddEventHandler(BR.Net.SQUAD_JOINREQ, function(data)
    local src = source
    local ok, reason = BR.Party.requestJoin(src, tonumber(data and data.leader))
    result(src, ok, reason)
end)

RegisterNetEvent(BR.Net.SQUAD_JOINRESP)
AddEventHandler(BR.Net.SQUAD_JOINRESP, function(data)
    local src = source
    local ok, reason = BR.Party.answerJoin(src,
        tonumber(data and data.requester), data and data.accept)
    result(src, ok, reason)
end)

RegisterNetEvent(BR.Net.SQUAD_LEAVE)
AddEventHandler(BR.Net.SQUAD_LEAVE, function()
    -- Success speaks via the "You left the party." notice inside leave().
    BR.Party.leave(source)
end)

RegisterNetEvent(BR.Net.SQUAD_KICK)
AddEventHandler(BR.Net.SQUAD_KICK, function(data)
    local src = source
    local ok, reason = BR.Party.kick(src, tonumber(data and data.target))
    result(src, ok, reason)
end)

--- Remove a player from whatever party they are in, WITHOUT consulting the
--- roster.
---
--- Needed because roster.lua registers its playerDropped handler first and
--- deletes the roster entry, so by the time this file's handler runs
--- BR.Party.leave finds no entry and returns early -- leaving a disconnected
--- player holding a party slot forever, blocking invites against a party that
--- looks full and is not.
---
--- @param src integer
function BR.Party.removePlayer(src)
    for id, party in pairs(parties) do
        for i = #party.members, 1, -1 do
            if party.members[i] == src then
                table.remove(party.members, i)

                if #party.members == 0 then
                    parties[id] = nil
                else
                    if party.leader == src then
                        party.leader = party.members[1]
                    end
                    sync(id)
                end
            end
        end
    end
end

AddEventHandler('playerDropped', function()
    invites[source] = nil
    BR.Party.removePlayer(source)
end)

-- Expire stale invites, so a declined-by-ignoring invite does not sit forever
-- and block the inviter from seeing an accurate party size.
BR.Sched.every(5000, 'party.expire', function()
    local now = GetGameTimer()
    for src, inv in pairs(invites) do
        if now - inv.at > INVITE_TTL_MS then
            invites[src] = nil

            -- Being ignored is an answer the sender needs to hear too --
            -- otherwise "expired" and "still thinking" look identical for as
            -- long as the sender cares to keep watching the pending chip.
            local target = BR.Roster.get(src)
            BR.Server.notify(inv.from,
                ('Invite to %s expired.'):format(target and target.name or 'a player'),
                'warn')
            sync(inv.partyId)
        end
    end

    -- Join requests age out the same way, and the requester hears it --
    -- "ignored" must never look like "still deciding".
    for src, req in pairs(joinReqs) do
        if now - req.at > INVITE_TTL_MS then
            joinReqs[src] = nil
            BR.Server.notify(src, 'Your join request expired.', 'warn')
        end
    end
end)

RegisterCommand('brparty', function(_, args)
    if args[1] == 'invite' and args[2] and args[3] then
        local ok, reason = BR.Party.invite(tonumber(args[2]), tonumber(args[3]))
        print(ok and '  invited' or ('  failed: ' .. tostring(reason)))
        return
    end

    print('=== parties ===')
    local any = false
    for id, p in pairs(parties) do
        any = true
        local names = {}
        for _, src in ipairs(p.members) do
            local e = BR.Roster.get(src)
            names[#names + 1] = ('%s(%d)%s'):format(
                e and e.name or '?', src, src == p.leader and '*' or '')
        end
        print(('  [%s] %s'):format(id, table.concat(names, ', ')))
    end
    if not any then print('  (no parties)') end

    local pending = 0
    for _ in pairs(invites) do pending = pending + 1 end
    print(('  %d pending invite(s)'):format(pending))
    print('  usage: brparty [invite <fromId> <toId>]   (* = leader)')
end, true)
