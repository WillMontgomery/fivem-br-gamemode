-- Evidence capture: the wiring around BR.EvidenceBuf.
--
-- The bookkeeping lives in br_lib/shared/evidence_buf.lua, which is pure and
-- unit-tested. This file is the part that cannot be tested outside the game:
-- which events fire, which native reports the time, and what the roster knows.
-- Same split as combat_solve/damage and outbox/push.
--
-- NOTHING HERE HAS A TIMER. Every write hangs off an event the server already
-- raises -- a chat message, an elimination, a disconnect, a match ending. An
-- idle server does no work on behalf of this file, and a busy one does an O(1)
-- table append per event it was already handling.
--
-- NOTHING HERE WRITES TO A DATABASE. The buffer is memory, discarded when the
-- match ends. An incident is what turns it into a record (owner call,
-- 2026-08-14) -- so a clean match, which is nearly all of them, costs one table
-- and no DynamoDB traffic at all.

BR = BR or {}
BR.Evidence = {}

--- The buffer. Caps come from config so a busy server can trim them without a
--- code change; the defaults live in evidence_buf.lua.
local buf = BR.EvidenceBuf.new({
    chatMax = BR.Config and BR.Config.Evidence and BR.Config.Evidence.chatMax,
    killMax = BR.Config and BR.Config.Evidence and BR.Config.Evidence.killMax,
    stripMax = BR.Config and BR.Config.Evidence and BR.Config.Evidence.stripMax,
})

BR.Evidence.buf = buf

--- Everything the buffer wants to know about a player right now.
---
--- Read from the roster on every note rather than cached, because `license` is
--- filled lazily and `squadId` changes when squads form. `track` keeps the best
--- answer it has seen, so a cheap read here beats a subscription.
--- @param src integer
--- @return table|nil  nil when they are not in a live match
local function metaFor(src)
    local e = BR.Roster and BR.Roster.get and BR.Roster.get(src)
    if not e then return nil end

    -- ONLY WHILE A MATCH IS LIVE. Lobby chatter is not evidence of anything and
    -- buffering it would mean holding the whole server's small talk between
    -- matches for no reader.
    if e.matchId == nil then return nil end

    return {
        -- Resolved rather than read, because `license` is filled lazily and a
        -- record without one cannot be attached to an incident or found by a
        -- report. BR.Roster.licenseOf caches on the entry, so this is one
        -- identifier scan per player, not one per chat line.
        license = BR.Roster.licenseOf(src),
        name    = e.name,
        matchId = e.matchId,
        squadId = e.squadId,
        now     = GetGameTimer(),
    }
end

--- Record one chat line against its sender.
---
--- Called from chat.lua AFTER the message has been sanitised and accepted, so
--- what lands here is exactly what other players saw -- not what was typed. A
--- record of a slur has to be the delivered text or it proves nothing.
--- @param src integer
--- @param msg table  the delivered message { channel, name, text, at }
function BR.Evidence.noteChat(src, msg)
    local meta = metaFor(src)
    if not meta then return end
    buf:noteChat(src, {
        text    = msg.text,
        channel = msg.channel,
        at      = msg.at,
    }, meta)
end

--- Record one elimination against both players involved.
---
--- BOTH, deliberately: a player's own deaths are context a reviewer needs as
--- much as their kills. "Reported for teaming" reads very differently when the
--- record shows the accused died to the person they are supposed to be helping.
--- @param feed table  the kill feed row
function BR.Evidence.noteKill(feed)
    local vm = metaFor(feed.victimSrc)
    local km = nil
    if feed.killerSrc and feed.killerSrc ~= feed.victimSrc then
        km = metaFor(feed.killerSrc)
    end

    local row = {
        killer   = feed.killer,
        victim   = feed.victim,
        cause    = feed.cause,
        weapon   = feed.weapon,
        headshot = feed.headshot,
        at       = GetGameTimer(),

        -- THE LICENCES ARE RESOLVED HERE AND ADDED TO THE BUFFERED ROW ONLY --
        -- DELIBERATELY NOT TO `feed` (#30).
        --
        -- `feed` IS BROADCAST TO CLIENTS. combat.lua hands the same table to
        -- BR.Broadcast.toMatch(m, BR.Net.KILL_FEED, feed) two lines after calling
        -- this, so anything added to it is on every player's machine. A licence
        -- is the console's profile key and the identifier every ban, grant and
        -- audit row is written against; putting one on the wire to clients would
        -- hand the whole lobby a stable cross-match identifier for everybody they
        -- kill. This row never leaves the server: it lives in RAM and, if an
        -- incident is ever filed, travels server -> DynamoDB -> console. That is
        -- a different path with a different audience and it is the reason the
        -- licence is acceptable here and not there.
        --
        -- WHY THEY ARE NEEDED. #30 wants each kill on an incident timeline to
        -- link to the victim's profile, and the console keys profiles by licence.
        -- `victim` is a display NAME, which is not unique, is player-chosen and
        -- is not what the console can look up. `victimSrc` is worse than useless
        -- for the purpose: server ids are RECYCLED WITHIN THE MINUTE (see
        -- evidence_buf's header), so a src stored now names somebody else by the
        -- time an admin reads the case.
        --
        -- RESOLVED NOW, WHILE THE SRC IS STILL VALID, for that same reason.
        killerLicense = km and km.license or nil,
        victimLicense = vm and vm.license or nil,
    }

    if vm then buf:noteKill(feed.victimSrc, row, vm) end

    -- A killer who has already disconnected has no roster entry and therefore no
    -- meta -- their record is sealed and stays as it was. Nothing to do, and
    -- deliberately not an error: a shot lands after the shooter leaves.
    if km then buf:noteKill(feed.killerSrc, row, km) end
end

--- Record that a weapon this gamemode does not issue was in a player's hand.
---
--- THE ONLY ENTRY POINT HERE WHOSE SOURCE IS A CLIENT, and it is worth saying so
--- beside the two above it rather than only in the file that receives the event.
--- Chat is delivered text the server already saw; a kill is the server's own
--- attribution out of damage.lua. A strip is a fact about the offender's own ped,
--- which no server-side native can read -- so the report arrives over the wire and
--- br_core/server/strip.lua is where it is rate-limited, cross-checked against the
--- inventory the SERVER holds, and refused for admins. By the time it reaches this
--- function all of that has already happened.
---
--- `at` IS STAMPED HERE, NOT ACCEPTED. Everything on a match timeline is a
--- server clock reading -- see the header of incident_build.lua -- and a
--- client-supplied timestamp on a moderation record would be evidence a cheater
--- writes about themselves.
--- @param src integer
--- @param weapon integer|nil  the normalised hash that was in the hand
function BR.Evidence.noteStrip(src, weapon)
    local meta = metaFor(src)
    if not meta then return end
    buf:noteStrip(src, { at = meta.now, weapon = weapon }, meta)
end

--- Keep more about this player, because a case has been opened about them.
---
--- Called from server/incident.lua the moment a filing is acknowledged. See
--- BR.EvidenceBuf:promote for why the cost is paid per incident rather than per
--- player: a match that files nothing still costs nothing.
--- @param license string
--- @return integer  how many records were promoted
function BR.Evidence.retain(license)
    return buf:promote(license)
end

--- Every record for one license this match, live or sealed.
--- @param license string
--- @return table[]
function BR.Evidence.forLicense(license)
    return buf:forLicense(license)
end

--- Players with a record who are no longer connected.
---
--- This is what makes "caused hell then left" reportable: the report list is the
--- live roster PLUS this, so somebody who quit ten seconds ago is still on
--- screen with a license attached to them.
--- @param matchId integer|nil
--- @return table[]
function BR.Evidence.departed(matchId)
    return buf:departed(matchId)
end

--- Counters, for brring-style introspection.
function BR.Evidence.stats()
    return buf:stats()
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

-- SEAL, DO NOT DELETE. The record moves aside so the player stays reportable
-- and their evidence stays attachable for the rest of the match. Keeping it
-- under `src` instead would be worse than deleting it: server ids are recycled
-- within the minute, so the record would start collecting the next player's
-- chat and an incident built from it would name the wrong person.
AddEventHandler('playerDropped', function()
    local src = source
    if not src then return end
    buf:seal(src, GetGameTimer())
end)

-- THE DISCARD IS THE COST CONTROL. The match has left the registry: nothing
-- more can be reported about it, and any incident it produced was written when
-- it was filed.
--
-- ON `destroyed` RATHER THAN `results`, which matters. `br:match:results` fires
-- from the summary path and returns early on `#rows == 0`, so a match that ends
-- empty announces nothing -- and its buffers would sit there for the life of the
-- process. `destroy` is the only path out of the registry.
--
-- It also runs a phase LATER than the summary, so evidence outlives the match
-- proper by the ENDED/CLEANUP window. That is deliberate: it is the last moment
-- anybody could still be looking at that match.
AddEventHandler('br:match:destroyed', function(ev)
    if not ev or ev.matchId == nil then return end

    -- LAST CALL, AND IT IS EMITTED FROM INSIDE THIS FUNCTION RATHER THAN LEFT TO
    -- HANDLER ORDER. This is the only moment at which "the match is over" and
    -- "the evidence still exists" are both true, and #30's match-end write needs
    -- exactly that moment: it closes the incident timeline with the kills that
    -- happened after the case was filed.
    --
    -- WHY NOT JUST LISTEN TO `br:match:destroyed` OVER IN incident.lua. Because
    -- it would silently read an empty buffer. FiveM runs handlers in registration
    -- order, registration order is manifest order, and br_core's manifest loads
    -- server/evidence.lua (line 114) well before server/incident.lua (line 138) --
    -- so this handler, and the `clearMatch` below it, would both have run first.
    -- The feature would have looked correct, logged nothing, and shipped dead.
    -- This project has form for exactly that, which is why the ordering is a line
    -- of code here rather than a comment in a manifest: moving `clearMatch` above
    -- this emit breaks a test, whereas reordering the manifest breaks nothing
    -- visible until somebody reads a real case.
    --
    -- `startedAt` IS FORWARDED RATHER THAN LOOKED UP, and it is forwarded rather
    -- than left for the reader to fetch because there is nothing left to fetch
    -- it from: server/match.lua clears the registry entry before it announces
    -- the destruction. It is nil for a match that never went live, and the
    -- incident close treats that as "never started" rather than as "unknown".
    TriggerEvent('br:evidence:closing', {
        matchId   = ev.matchId,
        startedAt = ev.startedAt,
    })

    buf:clearMatch(ev.matchId)
end)

-- A resource restart leaves buffers describing matches that no longer exist.
-- roster.lua reconciles itself for the same reason; this is the cheaper version
-- of the same idea, since there is nothing to rebuild -- only stale memory to
-- drop, and no reader can miss what was never reportable after a restart.
AddEventHandler('onResourceStart', function(name)
    if name == GetCurrentResourceName() then buf:clearMatch(nil) end
end)
