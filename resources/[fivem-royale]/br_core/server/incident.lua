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

    -- Anything already filed against them this match, so the console can merge
    -- rather than opening a second case a human has to correlate by eye.
    payload.priorIncidentIds = BR.Incident.priorFor(ev.matchId, ev.license)

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
