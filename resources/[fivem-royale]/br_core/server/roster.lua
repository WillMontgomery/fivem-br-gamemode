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

--- Fields pushed to the Ringmaster admin console. A SECOND allowlist, wider
--- than PUBLIC_FIELDS on purpose and NEVER a replacement for it: this
--- projection travels server-to-server over the VPC peering link, to a box
--- that already holds the ban list -- so it may carry exactly the things
--- PUBLIC_FIELDS exists to withhold from clients (license, position, matchId).
---
--- It lives HERE, directly under PUBLIC_FIELDS and beside newEntry, so that
--- adding a roster field forces a decision about BOTH audiences while the
--- shape is on screen. A projection defined off in br_ringmaster would drift
--- silently, and its failure mode is a privacy leak rather than a crash.
--- test_roster.lua asserts both lists against newEntry's actual keys.
local RINGMASTER_FIELDS = {
    src = true, name = true, license = true,
    matchId = true, squadId = true, state = true,
    hp = true, armour = true,
    kills = true, downs = true, revives = true, damage = true,
    placement = true,
    pos = true, posAt = true, bucket = true,
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

        -- DBNO bookkeeping (M7). All server-side, none of it PUBLIC: the
        -- client is TOLD its own downed state on BR.Net.DBNO_SET, and everyone
        -- else learns about it only from the `state` field, which is.
        --
        -- `dbnoUntil` HAS ONE SQUAD-ONLY EXIT and it is worth naming here,
        -- because the next person to want it will reach for PUBLIC_FIELDS
        -- first: server/party.lua copies it onto the squad beacon as
        -- `bleedEndsAt`, to the downed player's own squad and to nobody else.
        -- It must NOT join PUBLIC_FIELDS -- that list goes to every client in
        -- the match, so putting a bleed-out deadline on it would hand each
        -- downed player's exact remaining seconds to the people who shot them.
        --   dbnoUntil   when the bleed runs out (server ms)
        --   dbnoCount   knocks this match; each one bleeds faster
        --   downedBy    who gets the kill if nobody touches them again --
        --               deliberately outlives assistWindowMs, unlike lastHitBy
        --   reviverSrc  who is holding on them right now
        --   reviveFrom  when that hold started
        dbnoUntil  = nil,
        dbnoCount  = 0,
        downedBy   = nil,
        reviverSrc = nil,
        reviveFrom = nil,

        -- WHEN THIS MATCH ENDED FOR THEM, on the same GetGameTimer() clock as
        -- m.startedAt. Both are nil for a player who is still in it.
        --   diedAt  set by BR.Combat.eliminate; survival time stops here
        --   leftAt  set by BR.Roster.remove; presence stops here
        -- A player who dies and stays to spectate has diedAt and no leftAt,
        -- which is exactly the difference the two numbers exist to carry.
        --
        -- DELIBERATELY IN NEITHER ALLOWLIST. These are published once, in the
        -- match results, and read by nothing live -- so a client has no use for
        -- them and the console would only be showing a number it cannot act on.
        -- Cleared at CLEANUP with the rest of the per-match state.
        diedAt     = nil,
        leftAt     = nil,

        -- THEIR PED IS DEAD AND THEIR MATCH IS NOT OVER (#144). Set when a
        -- player is killed before their match reaches PLAYING, cleared by the
        -- revive on that transition. It is the reason `state == DEAD` and
        -- `diedAt == nil` can be true at the same time, which every other part
        -- of this codebase would otherwise read as a contradiction: DEAD is what
        -- their own client draws, diedAt is what the results row is built from,
        -- and for the length of the hold only the first of those has happened.
        --
        -- ALSO IN NEITHER ALLOWLIST, and for a stronger reason than diedAt: this
        -- is a promise the server has made to one player, not a fact about them
        -- that anyone else can act on.
        revivePending = nil,

        joinedAt   = GetGameTimer(),
        bucket     = 0,
    }
end

--- Players who disconnected mid-match, kept until that match publishes.
---
--- NOT KEYED BY src, AND THAT IS THE WHOLE POINT. Server ids are recycled
--- within the minute, so a sealed entry left in `roster[src]` would be
--- overwritten by -- or worse, silently merged with -- whoever connects into
--- that slot next, which inside one match is a routine occurrence rather than
--- an edge case. An array has no key to collide on.
---
--- This is the evidence buffer's move (#94), for the same reason: a disconnect
--- SEALS a player's record rather than freeing it.
local departed = {}

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

--- A player's chosen display name, or nothing.
---
--- Proposed by the client (stored in ITS kvp) and accepted HERE, because a
--- name is the one preference other people can see -- so it is the one
--- preference the server has to have an opinion about.
---
--- LOBBY ONLY. Renaming yourself mid-match rewrites the kill feed everyone
--- else is reading, and there is no legitimate reason to want that.
--- @param src integer
--- @param proposed string|nil  empty or nil restores the platform name
--- @return boolean
function BR.Roster.setName(src, proposed)
    local entry = roster[src]
    if not entry then return false end
    if entry.state ~= BR.PlayerState.LOBBY then return false end

    -- THE SHARED RULE, and the server is the one that counts. The client runs
    -- the same BR.ValidateName so a player learns instantly, but that copy is
    -- a courtesy -- a modified client that skips it is refused here.
    local ok, reason, clean = BR.ValidateName(proposed)
    if not ok then
        BR.Server.notify(src, reason or 'That name is not available.', 'warn')
        return false
    end

    entry.gamertag = (#clean > 0) and clean or nil
    local name = entry.gamertag or GetPlayerName(src) or entry.name
    if name == entry.name then return true end

    entry.name = name
    BR.Broadcast.delta({ op = 'update', src = src, e = { name = name } })
    return true
end

RegisterNetEvent(BR.Net.SETTINGS_NAME)
AddEventHandler(BR.Net.SETTINGS_NAME, function(data)
    BR.Roster.setName(source, data and data.name)
end)

-- LEAVING THE SERVER IS THE SERVER'S TO DO. The client's own `disconnect`
-- console command is restricted and refuses with "Access denied", so the
-- pause menu asks instead. DropPlayer is the supported route and it means the
-- server sees the departure rather than inferring it from a socket closing.
RegisterNetEvent(BR.Net.LEAVE_SERVER)
AddEventHandler(BR.Net.LEAVE_SERVER, function()
    local src = source
    local entry = BR.Roster.get(src)
    print(('[br_core] %s (%d) left the server from the pause menu')
        :format(entry and entry.name or '?', src))
    DropPlayer(src, 'You left from the pause menu.')
end)

function BR.Roster.add(src)
    local existing = roster[src]
    if existing then
        -- The CHOSEN name wins over the platform one. reconcile() calls this
        -- for every connected player on a cadence, so without the gamertag
        -- here a rename would survive for a few seconds and then silently
        -- revert to the Steam name.
        existing.name = existing.gamertag or GetPlayerName(src) or existing.name
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
---
--- AND IT IS NOT THE SAME AS NEVER HAVING PLAYED. Removing the entry outright
--- is what made a quit forfeit the entire match record -- publishResults walks
--- the roster, so a departed player produced no row, so br_stats wrote nothing:
--- no XP, no Volts, no match, not even the kills they got before they left
--- (#100). In a battle royale the most common thing a player does after being
--- eliminated is close the game, so that was most of them.
--- @param src integer
--- @return table|nil the removed entry
function BR.Roster.remove(src)
    local entry = roster[src]
    if not entry then return nil end

    entry.state = BR.PlayerState.LEFT

    -- SEAL, don't discard, if they were in a match. The entry leaves the roster
    -- either way -- nothing downstream should count a disconnected player as
    -- present, and the alive count, the squad panel and the win condition all
    -- read the roster -- but it survives in `departed` until the match it
    -- belongs to publishes its results.
    if entry.matchId then
        entry.leftAt = GetGameTimer()

        -- THE LICENSE HAS TO BE RESOLVED NOW. br_stats resolves it at match end
        -- through BR.Identity.ofPlayer(src), and that answers for CONNECTED
        -- players -- by the time the results publish, this source is gone and
        -- the lookup returns nothing. A row written under a guessed key is
        -- worse than one not written, so the key is captured while it is still
        -- knowable and travels with the sealed entry.
        if entry.license == nil and BR.Identity then
            entry.license = BR.Identity.qualified('license', BR.Identity.licenseOf(src))
        end

        departed[#departed + 1] = entry
    end

    roster[src] = nil

    -- Per-player combat bookkeeping goes with them. Server ids are recycled,
    -- so a stale rate-of-fire timestamp or refusal count would be inherited by
    -- whoever connects into that slot next -- and the first thing they would
    -- notice is their opening shot refused as "too fast".
    if BR.Damage then
        if BR.Damage.forget then BR.Damage.forget(src) end
        if BR.Damage.forgetRefusals then BR.Damage.forgetRefusals(src) end
    end
    if BR.Loot and BR.Loot.clearNpcDrops then BR.Loot.clearNpcDrops(src) end
    -- Same recycled-id argument again, with a second reason on top: whoever
    -- this player was in the middle of picking up would otherwise keep a
    -- reviver that no longer exists, and their progress ring would sit at
    -- whatever percentage the disconnect froze it at until the bleed ran out.
    if BR.Combat and BR.Combat.forget then BR.Combat.forget(src) end
    -- Same recycled-id argument, and a worse outcome: the cached voice
    -- channels are what suppress a re-push, so whoever connects into this
    -- slot next would be told nothing and stay in the previous holder's room.
    if BR.Voice and BR.Voice.forget then BR.Voice.forget(src) end

    BR.Broadcast.delta({ op = 'remove', src = src })
    print(('[br_core] - %s (%d) left -- %d connected'):format(entry.name, src, BR.Server.count()))
    return entry
end

--- Seal a COPY of a player's match record, for somebody leaving the MATCH but
--- not the SERVER (#161).
---
--- THE SAME MOVE AS remove(), FOR THE OTHER WAY OUT. A disconnect seals because
--- the entry is about to be deleted; a voluntary leave has to seal because the
--- entry is about to be DETACHED -- `BR.Match.leaveMatch` clears matchId so the
--- player stops hearing this match's traffic, and publishResults finds its rows
--- by matchId. Either way the record has to survive the exit, and until this
--- existed only one of the two ways out was covered: a player who pressed Leave
--- Match forfeited their whole record even from a match that ended normally,
--- which is #100's bug arriving through the door nobody checked.
---
--- A COPY, NOT THE ENTRY ITSELF, and that is the difference from remove(). This
--- player is still connected and still playing -- they will queue again, take
--- damage again, and every one of those writes would land on a sealed record if
--- it were the same table. The entry stays live; the match takes a photograph.
---
--- The license is resolved HERE for the reason #100 gives: they may well close
--- the game before the match they just left finishes dissolving, and by then
--- `licenseOf` answers for nobody.
--- @param src integer
--- @return table|nil the sealed copy
function BR.Roster.sealLeaver(src)
    local entry = roster[src]
    if not entry or not entry.matchId then return nil end

    local copy = {}
    for k, v in pairs(entry) do copy[k] = v end
    copy.state  = BR.PlayerState.LEFT
    copy.leftAt = GetGameTimer()
    copy.license = BR.Roster.licenseOf(src)

    departed[#departed + 1] = copy
    return copy
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

--- A player's qualified license, resolving and caching it on first ask.
---
--- `newEntry` declares `license = nil` as "filled by br_stats if it is running",
--- and for a long time nothing wrote it -- so whether a player had a license
--- attached depended on whether the ringmaster projection had run for them yet.
--- That was survivable while the only reader was a snapshot. It stopped being
--- survivable when moderation records started being keyed on it: an incident
--- with no license is a case about nobody, and server ids are recycled within
--- the minute.
---
--- SO IT LIVES HERE, once, rather than being re-derived at each call site. It
--- was already being done in two places by the time this was extracted.
--- Cached on the entry, so a roster full of players costs one identifier scan
--- each rather than one per read.
---
--- A licenseless connection stays nil, and nil is what every caller passes on.
--- Inventing a key here would be a ban against the wrong human later.
--- @param src integer
--- @return string|nil
function BR.Roster.licenseOf(src)
    local entry = roster[src]
    if not entry then return nil end
    if entry.license == nil and BR.Identity then
        entry.license = BR.Identity.qualified('license', BR.Identity.licenseOf(src))
    end
    return entry.license
end

--- One player, projected for the admin console. See RINGMASTER_FIELDS.
---
--- `connectedAt` is the wire name for `joinedAt` -- a GetGameTimer() reading,
--- deliberately not a duration, so the console can count it up continuously
--- against the envelope's clock pair instead of receiving a number that is
--- stale on arrival.
--- @param entry table
--- @return table
function BR.Roster.ringmaster(entry)
    BR.Roster.licenseOf(entry.src)

    local out = {}
    for k in pairs(RINGMASTER_FIELDS) do
        out[k] = entry[k]
    end
    out.connectedAt = entry.joinedAt
    return out
end

--- Every player, projected for the admin console.
--- @return table array
function BR.Roster.ringmasterAll()
    local out = {}
    for _, e in pairs(roster) do
        out[#out + 1] = BR.Roster.ringmaster(e)
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

--- Sealed entries for one match: the players who disconnected before it ended.
---
--- TWO CALLERS, AND THE RULE THEY BOTH OBEY. This said "only the results
--- publisher should call this", and the second one (#172) is the in-game player
--- list: a player who ragequits after cheating is exactly the person still
--- worth reporting, so `BR.Players.listFor` merges these rows in and marks them
--- gone. That is the same permission the publisher has, not a new one -- both
--- are RENDERING a finished record, neither is treating its subject as present.
---
--- WHAT IS STILL FORBIDDEN, and it is the part worth keeping loud: nothing may
--- put a sealed entry back into `roster`, and nothing that counts players may
--- read this. The alive count, the squad panel, the win condition and the
--- console snapshot must all go on seeing a departed player as gone, because
--- they are.
--- @param matchId integer
--- @return table array of entries
function BR.Roster.departedIn(matchId)
    local out = {}
    for _, entry in ipairs(departed) do
        if entry.matchId == matchId then out[#out + 1] = entry end
    end
    return out
end

--- Drop one match's sealed entries. Called at CLEANUP, beside the wipe that
--- resets the same per-match counters on everybody still connected -- so the
--- two halves of "this match is over" stay in one place.
--- @param matchId integer
function BR.Roster.clearDeparted(matchId)
    local kept = {}
    for _, entry in ipairs(departed) do
        if entry.matchId ~= matchId then kept[#kept + 1] = entry end
    end
    departed = kept
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

            -- A DOWNED PLAYER'S HEALTH IS THE LEDGER'S, NOT THE PED'S.
            --
            -- Their ped is parked at the DBNO floor and their real "health" is
            -- a countdown living on this entry, so sampling would achieve one
            -- of two wrong things: agree with the floor and churn nothing, or
            -- -- on a client that was slow to apply the knock, or is simply
            -- ignoring it -- drag the entry back to full and show the squad
            -- panel a downed teammate on 100hp.
            --
            -- Written as a condition rather than an early return ON PURPOSE:
            -- this is the body of a loop over the WHOLE roster, and a `return`
            -- here would stop sampling everybody who sorted after the first
            -- downed player -- positions included.
            if entry.state ~= BR.PlayerState.DBNO
               and (hp ~= entry.hp or armour ~= entry.armour) then
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

--- The rate used when the configured one is unusable.
---
--- A LAST RESORT, NOT A SECOND COPY OF THE SETTING. It is only ever reached
--- when `posSampleHz` is nil, zero or negative -- i.e. when somebody has
--- already made a mistake -- and its job is to keep the server sampling rather
--- than to express a policy. It is kept equal to the shipped config value so a
--- broken config degrades to the behaviour everyone has played, and
--- tools/test_roster.lua asserts that equality rather than leaving two numbers
--- free to drift, which is the bug this whole change is about.
local FALLBACK_POS_SAMPLE_HZ = 4

--- How often positions are sampled, in milliseconds, FROM THE CONFIG.
---
--- THIS USED TO BE THE LITERAL 250 AND THE CONFIG USED TO SAY 2 Hz. Both
--- statements were in the repository at once, describing the same thing,
--- disagreeing by a factor of two, with nothing able to notice -- because
--- `BR.Config.Match.posSampleHz` had no readers at all. The hardcoded number
--- was the correct one and the documented one was the value that had been tried
--- and reverted, which is the worst way round for that pair to be.
---
--- 4 Hz IS THE RATE AND THE REASON IT IS NOT 2 IS KEPT HERE DELIBERATELY: squad
--- beacons are drawn straight from this sampling, and at 2 Hz a teammate's dot
--- visibly HOPPED rather than moved. It also halves the staleness the loot claim
--- check has to allow for. 2 Hz is a repeat of a rejected experiment, not a
--- saving -- and the number now lives in the config where somebody looking to
--- turn it down will meet that sentence before they do.
---
--- GUARDED, BECAUSE THE ALTERNATIVE IS DIVIDING BY IT BLINDLY. `1000 / 0` is
--- `inf` in Lua and `math.floor(inf)` raises -- so a typo'd config would not
--- misbehave, it would take the resource down at load, and the traceback would
--- point here rather than at the line someone edited. nil and negatives are the
--- same class of answer. A bad value falls back to the shipped rate and says so
--- loudly; it does not silently pick something.
---
--- Exposed rather than local so the guard itself is testable with values no
--- shipped config would ever hold.
--- @param hz number|nil  defaults to BR.Config.Match.posSampleHz
--- @return integer milliseconds
function BR.Roster.sampleIntervalMs(hz)
    if hz == nil then hz = BR.Config.Match.posSampleHz end
    hz = tonumber(hz)

    if not hz or hz <= 0 then
        print(('^3[br_core] roster: posSampleHz is %s, which is not a rate -- '
            .. 'sampling at %d Hz instead^7')
            :format(tostring(hz), FALLBACK_POS_SAMPLE_HZ))
        hz = FALLBACK_POS_SAMPLE_HZ
    end

    -- The same shape server/broadcast.lua uses for deltaFlushHz and digestHz,
    -- so all three rates are derived one way. `math.max(1, ...)` because a
    -- config above 1000 Hz would floor to zero and give the scheduler a job
    -- with no interval.
    return math.max(1, math.floor(1000 / hz))
end

BR.Sched.every(BR.Roster.sampleIntervalMs(), 'roster.positions', samplePositions)
BR.Sched.every(5000, 'roster.reconcile', reconcile)

-- Players already connected when the resource starts (a restart mid-session).
AddEventHandler('onResourceStart', function(res)
    if res ~= GetCurrentResourceName() then return end
    Citizen.SetTimeout(1000, reconcile)
end)
