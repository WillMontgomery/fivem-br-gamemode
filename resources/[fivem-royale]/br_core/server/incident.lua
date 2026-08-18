-- The incident writer's br_core half: assemble, then hand over.
--
-- WHY IT IS HERE AND NOT IN br_ringmaster. FiveM gives every resource its own
-- Lua state, and br_ringmaster deliberately declares no dependency on br_core --
-- so it cannot see BR.Evidence, BR.Roster or BR.Config at all. ringmaster.lua:66
-- records the last time somebody tried: "the first version of this read nil
-- forever from over there." The evidence lives here, so the assembly lives here.
--
-- THE HANDOVER IS THE EXISTING CONTRACT, unextended: br_core emits, br_ringmaster
-- listens. `br:ringmaster:snapshot` and `br:ringmaster:refusal` already work
-- exactly this way, and neither resource has to be running for the other to
-- load.
--
-- NOTHING HERE HAS A TIMER and nothing here writes to a database. This file runs
-- when the anticheat fires, which on a healthy server is never.
--
-- NOTHING HERE TOUCHES THE PLAYER. Not a notice, not a hint, not a kick. The
-- offender learns nothing at any point; enforcement, if there is any, arrives
-- from Ringmaster over the channel that already exists for it.

BR = BR or {}
BR.Incident = {}

--- Incidents filed during a match, by subject license.
---
--- WHAT THIS IS FOR: corroboration. When a second thing happens to the same
--- player in the same match, the reviewer wants one case with two events rather
--- than two cases -- and a player report against somebody the anticheat has
--- already flagged is the single most useful pairing this system produces.
---
--- IT IS A MAP OF IDS, NOT OF PAYLOADS. Holding the payloads would mean holding
--- every incident's evidence for the life of the match, which is the memory the
--- buffer's caps exist to bound. The id is enough: the record is in DynamoDB.
---
--- [matchId] = { [license] = { incidentId, ... } }
local filed = {}

--- The key a match's filings are stored under.
---
--- NORMALISED, BECAUSE nil SILENTLY DISABLED THE WHOLE FEATURE. An anticheat
--- firing outside a live match -- from the lobby, from warmup, or from
--- `brrefuse` during a test -- carries no matchId, and `remember` returned
--- early on exactly that. So nothing was ever remembered, `priorFor` always
--- answered empty, and every doubling filed a BRAND NEW case instead of
--- corroborating: three refusal reports, three separate incidents about one
--- player, and nothing anywhere saying why (owner, 2026-08-16 -- `brring`
--- read `filed 3` where it should have read `filed 1, corroborated 2`).
---
--- A sentinel keeps the grouping working outside a match. It is deliberately
--- not shared with match 0 -- matches are numbered from 1 -- so a real match
--- can never collide with it.
local NO_MATCH = 'nomatch'

local function key(matchId)
    if matchId == nil then return NO_MATCH end
    return matchId
end

--- Ids already filed against one player in one match.
--- @param matchId any
--- @param license string
--- @return string[]
function BR.Incident.priorFor(matchId, license)
    local m = filed[key(matchId)]
    if not m or license == nil then return {} end
    return m[license] or {}
end

--- Note that an incident landed, so the next one this match can point at it.
---
--- RETURNS WHETHER IT WAS THE FIRST IN THIS MATCH, because that is the exact
--- moment #168's announcement is owed and this is the only function that can
--- tell. Derived from the map rather than tracked beside it: a second boolean
--- saying "we have announced" would be a copy of a fact this table already
--- holds, and the two would eventually disagree after a `br:match:destroyed`
--- clears one and not the other.
---
--- @param matchId any
--- @param license string
--- @param incidentId string
--- @return boolean first  true when nothing had been filed in this match before
function BR.Incident.remember(matchId, license, incidentId)
    -- matchId is allowed to be nil; license and the id are not.
    if license == nil or incidentId == nil then return false end
    local k = key(matchId)
    local m = filed[k]
    local first = false
    if not m then
        m = {}
        filed[k] = m
        first = true
    end
    local list = m[license]
    if not list then
        list = {}
        m[license] = list
    end
    list[#list + 1] = incidentId
    return first
end

--- Counters, for brdebug-style introspection.
function BR.Incident.stats()
    local matches, ids = 0, 0
    for _, m in pairs(filed) do
        matches = matches + 1
        for _, list in pairs(m) do ids = ids + #list end
    end
    return { matches = matches, filed = ids }
end

-- ---------------------------------------------------------------------------
-- The anticheat path
-- ---------------------------------------------------------------------------

-- LISTENS TO THE EVENT damage.lua ALREADY EMITS, rather than being called from
-- it. That keeps damage.lua's promise to itself intact -- it counts refused
-- shots and announces the count, and has grown no second job -- and it means the
-- incident writer can be restarted, replaced or absent without the validator
-- caring. br_ringmaster listens to the same event for its own outbox copy; two
-- listeners, neither aware of the other, which is what the event channel is for.
AddEventHandler('br:ringmaster:refusal', function(ev)
    if type(ev) ~= 'table' then return end

    -- ONE CASE PER PLAYER PER MATCH; EVERYTHING AFTER IT CORROBORATES (owner call,
    -- 2026-08-14: this should carry "the same impact and value as … multiple
    -- players report[ing] the same offender").
    --
    -- damage.lua reports at the bar and then on every doubling, so from the second
    -- report onward there is already a case about this player in this match. Filing
    -- another would hand an admin the same conclusion twice and let one persistent
    -- cheater bury a queue that is meant to be a shrinking worklist. Appending to
    -- the case they already have says something a second row cannot: it is still
    -- happening, and nobody has acted.
    --
    -- WHY THE CONSOLE DOES THE WRITE AND NOT US. Corroboration is an UpdateItem on
    -- a row that already exists, and the game's DynamoDB grant is deliberately
    -- append-only -- PutItem conditional on the id being absent, so a compromised
    -- game box can file noise but cannot overwrite a case or erase a verdict and
    -- the admin who made it. Widening that to reach inside existing rows would cost
    -- more than corroboration is worth. Ringmaster already holds the write on its
    -- own table (`incidents.note()` is the same list_append), so the game sends a
    -- fact and the console records it.
    --
    -- AND WHY IT MAY RIDE THE LOSSY CHANNEL when the case itself may not: a
    -- corroboration is by definition redundant. Losing one costs a number; losing
    -- the case loses the record. `seq` travels with it so the console can tell 1,
    -- 2, 4 with a gap from a genuinely quiet match.
    local prior = BR.Incident.priorFor(ev.matchId, ev.license)
    if #prior > 0 then
        TriggerEvent('br:ringmaster:corroborate', {
            incidentId = prior[#prior],
            matchId    = ev.matchId,
            license    = ev.license,
            name       = ev.name,
            seq        = ev.seq,
            count      = ev.count,
            reason     = ev.reason,
            reasons    = ev.reasons,
            severity   = ev.severity,
            at         = ev.at,
        })
        return
    end

    -- EVIDENCE IS ATTACHED AT FILING TIME, NOT LATER. The buffer is discarded
    -- when the match ends, so "we will fetch it when an admin opens the case" is
    -- a promise this system cannot keep. What goes in the record now is all
    -- there will ever be.
    local records = BR.Evidence and BR.Evidence.forLicense(ev.license) or {}

    local payload, why = BR.IncidentBuild.fromRefusal(ev, records)
    if not payload then
        -- LOUD, because the alternative is an anticheat that fires and files
        -- nothing with no trace of having tried. `no license` is the realistic
        -- case and it is worth a line: it means somebody tripped the threshold
        -- and cannot be recorded.
        print(('^3[br_core] incident NOT filed for %s: %s^7')
            :format(tostring(ev.name), tostring(why)))
        return
    end

    -- Empty by construction now -- a non-empty `prior` corroborated and returned
    -- above. The field stays on the payload because the console reads it and
    -- because the next kind to file here (a player report) will reach this line
    -- with cases from a DIFFERENT kind already present.
    payload.priorIncidentIds = prior

    TriggerEvent('br:ringmaster:incident', payload)
end)

-- ---------------------------------------------------------------------------
-- Telling the rest of the match that reporting exists (#168)
-- ---------------------------------------------------------------------------

--- Announce once per match, to everybody in it except the subject.
---
--- WHY IT HANGS OFF THE FIRST FILING RATHER OFF THE MATCH STARTING. The owner's
--- framing is a nudge at the moment it is worth acting on -- somebody in this
--- round has drawn a case, so "if you saw something, say something" is about
--- tonight rather than about the feature existing. A hint at the start of every
--- match is a tutorial nobody reads; this one arrives when it is true.
---
--- THE SUBJECT IS SHOWN NOTHING AT ALL, and that is #93's rule applied intact.
--- The offender learns nothing at any point -- not a notice, not a hint, not a
--- kick -- because a player who discovers they are under suspicion changes
--- behaviour, which costs the case the evidence it was going to be made of. The
--- exclusion is by LICENSE and is resolved per player here rather than trusted
--- off the roster: `entry.license` is documented as "filled by br_stats if it is
--- running", so a match with br_stats absent would silently exclude nobody --
--- and quietly telling the offender is the one failure this function must not
--- have.
---
--- THE TEXT IS NOT SENT. The envelope carries an occasion and the client writes
--- the sentence, because the sentence names the player-list key and only the
--- client knows which key that is. This project has already shipped a prompt
--- naming a key nothing was listening to (#129); the fix then was to resolve the
--- label where the binding lives, and that is why nothing here composes prose.
---
--- @param matchId any
--- @param subjectLicense string
local function announceReporting(matchId, subjectLicense)
    -- NOT OUTSIDE A MATCH. `brrefuse` from a console, or an anticheat firing in
    -- the lobby, files under the `nomatch` sentinel -- there is no audience to
    -- address and no round for the nudge to be about.
    if matchId == nil then return end
    if not BR.Roster then return end

    local told, skipped = 0, 0

    BR.Roster.each(
        function(e) return e.matchId == matchId end,
        function(src, e)
            -- A player who has already left is not on the wire; TriggerClientEvent
            -- to a recycled id would address whoever landed in that slot.
            if e.state == BR.PlayerState.LEFT then return end

            local byKind = BR.Identity and BR.Identity.ofPlayer(src)
            local lic = byKind and BR.Identity.qualified('license', byKind.license)
            if lic ~= nil and lic == subjectLicense then
                skipped = skipped + 1
                return
            end

            TriggerClientEvent(BR.Net.REPORT_HINT, src, { kind = 'exists' })
            told = told + 1
        end)

    print(('[br_core] report hint: told %d player(s) in match %s, withheld from %d subject(s)')
        :format(told, tostring(matchId), skipped))
end

-- The other half of the loop: br_ringmaster reports back what id the write got,
-- and this is where it becomes available for corroboration. Fire-and-forget in
-- the other direction too -- an incident that was written but whose confirmation
-- was lost costs the NEXT incident its cross-reference, and nothing else.
--
-- IT IS ALSO WHERE #168's ANNOUNCEMENT BELONGS, and deliberately not on the
-- submit path in server/players.lua. This handler runs when a row is DURABLE --
-- it is the acknowledgement br_ringmaster sends after DynamoDB accepted the
-- write -- so the hint cannot go out about a case that failed to file. It is
-- also the one place both sources meet: the anticheat's filing and a player's
-- report arrive here identically, which is what makes "the first incident filed
-- against anyone" one condition rather than two that can disagree.
AddEventHandler('br:incident:filed', function(ack)
    if type(ack) ~= 'table' then return end
    local first = BR.Incident.remember(ack.matchId, ack.subjectLicense, ack.incidentId)
    if first then announceReporting(ack.matchId, ack.subjectLicense) end
end)

-- Same teardown hook the evidence buffer uses, and for the same reason: `destroy`
-- is the only way a match leaves the registry, whereas `br:match:results`
-- returns early when nobody scored. Dropping the map here keeps it the size of
-- the matches currently running rather than of the server's uptime.
AddEventHandler('br:match:destroyed', function(ev)
    if not ev or ev.matchId == nil then return end
    filed[ev.matchId] = nil
end)

AddEventHandler('onResourceStart', function(name)
    if name == GetCurrentResourceName() then filed = {} end
end)
