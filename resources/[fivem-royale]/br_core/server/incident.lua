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

--- Ids already filed against one player in one match.
--- @param matchId any
--- @param license string
--- @return string[]
function BR.Incident.priorFor(matchId, license)
    local m = filed[matchId]
    if not m or license == nil then return {} end
    return m[license] or {}
end

--- Note that an incident landed, so the next one this match can point at it.
--- @param matchId any
--- @param license string
--- @param incidentId string
function BR.Incident.remember(matchId, license, incidentId)
    if matchId == nil or license == nil or incidentId == nil then return end
    local m = filed[matchId]
    if not m then
        m = {}
        filed[matchId] = m
    end
    local list = m[license]
    if not list then
        list = {}
        m[license] = list
    end
    list[#list + 1] = incidentId
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

-- The other half of the loop: br_ringmaster reports back what id the write got,
-- and this is where it becomes available for corroboration. Fire-and-forget in
-- the other direction too -- an incident that was written but whose confirmation
-- was lost costs the NEXT incident its cross-reference, and nothing else.
AddEventHandler('br:incident:filed', function(ack)
    if type(ack) ~= 'table' then return end
    BR.Incident.remember(ack.matchId, ack.subjectLicense, ack.incidentId)
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
