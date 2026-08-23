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

--- Cases filed against a player, by license, and NOT scoped to a match (#177).
---
--- [license] = { incidentId, ... }
---
--- WHY THE MATCH-SCOPED MAP ABOVE COULD NOT ANSWER THIS. `filed` is keyed by
--- match and dropped on `br:match:destroyed`, which is exactly right for the
--- two questions it is asked -- "does a case already exist to append to, in
--- THIS round" and "is this the first filing of the round". It is exactly wrong
--- for the killer prompt, which asks "does this player have a case open at
--- all". Owner, 2026-08-18, playtesting #169: a case sitting in
--- `pending_review` from a previous day produced no prompt, and an older case
--- is the BETTER corroboration target -- it has survived long enough to still
--- be under review.
---
--- SEPARATE RATHER THAN "STOP WIPING `filed`", and the distinction is the whole
--- of why there are two tables instead of one. Filing policy is deliberately
--- per match ("one case per player per match; everything after it
--- corroborates", and the teardown note below on why three rounds of cheating
--- are three things worth telling an admin about). Widening the map `filed`
--- feeds would have changed which cases get OPENED, silently, as a side effect
--- of fixing which prompts get SHOWN. Two questions, two tables, and the
--- report-submit path in server/players.lua still asks the match-scoped one.
---
--- WHAT "OPEN" HONESTLY MEANS HERE: filed, and never seen resolved by THIS
--- server process. Two limits fall out of that and neither is hidden:
---
---   * it does not survive a restart. There is no Query or Scan in br_ddb --
---     deliberately, see its header -- so the game cannot enumerate cases by
---     subject, and nothing else on the box remembers them. A case filed before
---     the last restart is invisible again.
---   * br_core has no resolution feed. An admin closing a case console-side is
---     not announced to the game, so a resolved case keeps answering this until
---     the process restarts. That over-triggers the prompt (an extra
---     corroboration on a closed row) rather than under-triggering it, which is
---     the safe side of the two: the bug being fixed is the prompt NOT
---     appearing.
---
--- IT IS NOT AN ENUMERATION CHANNEL. Nothing reads this except the server-side
--- resolver in server/players.lua, which answers only about the killer it
--- attributed itself. There is no verb that takes a license from a client.
local openBy = {}

--- The most ids kept per player, newest last.
---
--- BOUNDED BECAUSE THIS ONE DOES NOT GET FREED. `filed` is emptied match by
--- match; this is emptied only by a restart, so a player who draws a case in
--- every round would otherwise grow a list for the server's uptime. Only the
--- newest is ever read (the case a corroboration appends to), so the cap costs
--- nothing that is used -- and the table is bounded by the number of PLAYERS
--- WHO HAVE DRAWN A CASE, not by the number who have connected.
local OPEN_MAX = 8

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

--- Ids filed against one player, in ANY match this server has run (#177).
---
--- THE SAME SHAPE AS `priorFor` AND DELIBERATELY NOT THE SAME FUNCTION WITH A
--- nil MATCH. `priorFor(nil, lic)` already means something else -- it reads the
--- `nomatch` sentinel bucket, which is where a `brrefuse` from a console files
--- -- so overloading it would have made "outside a match" and "across all
--- matches" the same call, and the caller could not have said which it meant.
---
--- @param license string
--- @return string[]  oldest first; the LAST entry is the newest case
function BR.Incident.openFor(license)
    if license == nil then return {} end
    return openBy[license] or {}
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

    -- AND THE MATCH-FREE COPY (#177). Written here rather than from a second
    -- listener on `br:incident:filed`, so the two maps cannot learn about
    -- different sets of cases: there is exactly one place a filing becomes
    -- known, and it writes both.
    local open = openBy[license]
    if not open then
        open = {}
        openBy[license] = open
    end
    open[#open + 1] = incidentId
    -- Oldest out. See OPEN_MAX: only the newest is read.
    while #open > OPEN_MAX do table.remove(open, 1) end

    return first
end

--- Counters, for brdebug-style introspection.
function BR.Incident.stats()
    local matches, ids = 0, 0
    for _, m in pairs(filed) do
        matches = matches + 1
        for _, list in pairs(m) do ids = ids + #list end
    end
    -- `subjects` is the number of players carrying an open case since this
    -- process started, which is the one number that says whether the map
    -- `openFor` reads is growing (#177).
    local subjects, open = 0, 0
    for _, list in pairs(openBy) do
        subjects = subjects + 1
        open = open + #list
    end
    return { matches = matches, filed = ids, subjects = subjects, open = open }
end

-- ---------------------------------------------------------------------------
-- How often one case is allowed to repeat itself
-- ---------------------------------------------------------------------------
--
-- THE OWNER, 2026-08-22, WITH A SCREENSHOT OF ONE CASE'S TIMELINE: "it seems to
-- be filing a corroboration every few seconds". Nine notes in nine seconds,
-- every one of them differing from the row above it in a single digit:
--
--   Note -- 3 refusals this match - last: weapon is not one this gamemode issues
--   Note -- 4 refusals this match - last: weapon is not one this gamemode issues
--   ...                                                            ... up to 11.
--
-- WHAT WAS ACTUALLY FIRING ONCE A SECOND, BECAUSE IT IS NOT WHAT IT LOOKS LIKE.
-- The ped is stripped TEN times a second -- client/inventory.lua's TICK band is
-- 10Hz and a re-granting trainer re-arms on every one of them -- and that is
-- already collapsed twice before it reaches this file: the client reports at
-- most one a second (STRIP_REPORT_MS), and server/strip.lua counts at most one
-- per 900ms (MIN_INTERVAL_MS). So by the time an offence gets here it really is
-- arriving about once a second, and each one produced exactly one note.
--
-- WHICH MEANS NOTHING ON THIS PATH RATE-LIMITED ANYTHING. The three throttles
-- this subsystem has all live in the detectors and all bound the same thing:
-- how fast an offence may be COUNTED. Not one of them bounds how often the
-- RECORD REPEATS what it already said, and this file -- the only one that can
-- tell a corroboration from a filing -- had no opinion on it at all.
--
-- SO THE FIX IS HERE AND NOT IN THE DETECTORS OR IN THE CONSOLE. Here it covers
-- all three producers at once, it is expressible ("throttle a corroboration,
-- never a filing") only where the two are told apart, and it bounds the wire as
-- well as the page: today one offender can put a message a second on a 512-deep
-- drop-oldest outbox that the rest of the server shares, and an UpdateItem a
-- second on the console's table. Collapsing the rows console-side would have
-- fixed the reading and left both of those exactly as they are.
--
-- ═══ WHY DROPPING A NOTE LOSES NOTHING, WHICH IS THE WHOLE ARGUMENT ═══
--
--   `count` AND `seq` ARE RUNNING TOTALS, NOT INCREMENTS. Every producer sends
--   the cumulative number, so one note says everything the notes it replaced
--   said: "11 refusals this match" is the same sentence whether it arrives once
--   or nine times. A suppressed note costs nothing. Suppressing the LAST one
--   would cost the count outright, which is what `flushHeld` exists to stop.
--
--   THE PER-OFFENCE TIMING IS ALREADY WRITTEN DOWN ELSEWHERE. Every counted
--   strip is a `weapon_strip` row on the case's own match timeline, appended by
--   the close (MAX_TIMELINE_STRIPS, sixty, oldest dropped). "When did each one
--   happen" survives this in full. What does not survive is a second, lossier
--   copy of it, interleaved with the first.
--
-- A CHANGE OF FINDING IS NEVER HELD, and that is the half that keeps this from
-- being a mute button. A different `reason` or a different `severity` is not a
-- repeat -- it is a refused vehicle after a run of strips, or a worse tier than
-- the case was opened at -- and it is the row an admin is scrolling for. Only a
-- note that would read identically to the last one waits.
--
-- THIS FILE STILL HAS NO TIMER, which its header promises. A held note goes out
-- on the next corroboration that crosses the window, or on the match teardown
-- below; both were already arriving.
local CORROBORATE_MIN_INTERVAL_MS = 30000

--- What each case last said, and any newer version of it waiting behind.
---
--- [matchKey] = { [incidentId] = { at, reason, severity, held } }
---
--- KEYED BY MATCH FOR THE REASON `filed` IS. `priorFor` is match-scoped, so every
--- incidentId that reaches here was filed in the match it is keyed under, and one
--- teardown can drop both maps. The `nomatch` bucket is not dropped, exactly as
--- `filed`'s is not: it holds one small record per case filed outside a match --
--- a `brrefuse` from the console -- and `onResourceStart` is what empties it.
local lastSaid = {}

--- Send a corroboration, unless it would only repeat the one before it.
---
--- THE ONE CALLER SHAPE: every corroboration this file raises goes through here,
--- so the rule cannot be true of two producers and forgotten by the third. The
--- corroborations server/players.lua raises deliberately do NOT come through
--- this -- a person pressing a key is not a loop, it is already capped at
--- BR.Config.Report.maxPerMatch, and folding two humans' reports into one row
--- would be destroying evidence rather than tidying it.
---
--- @param ev table  the `br:ringmaster:corroborate` payload
local function corroborate(ev)
    local k = key(ev.matchId)
    local m = lastSaid[k]
    if not m then
        m = {}
        lastSaid[k] = m
    end

    local rec = m[ev.incidentId]
    local now = GetGameTimer()

    -- SAY IT NOW when there is nothing to repeat, when the finding changed, or
    -- when the window has passed.
    --
    -- `rec == nil` IS THE FIRST CORROBORATION ON THIS CASE AND MUST NEVER WAIT.
    -- It is the one that tells an admin reading the queue that the case is not
    -- historical -- "it is still happening, and nobody has acted" -- and it is
    -- also the one a short burst may produce the only copy of.
    if rec == nil
        or rec.reason ~= ev.reason
        or rec.severity ~= ev.severity
        or now - rec.at >= CORROBORATE_MIN_INTERVAL_MS
    then
        m[ev.incidentId] = { at = now, reason = ev.reason, severity = ev.severity }
        TriggerEvent('br:ringmaster:corroborate', ev)
        return
    end

    -- OTHERWISE THE NEWEST WAITS, AND IT REPLACES WHATEVER WAS WAITING. Keeping
    -- the older one would be keeping the smaller count, which is the one thing
    -- this must not do.
    rec.held = ev
end

--- Send whatever a match's cases were still holding.
---
--- WHY THIS IS NOT OPTIONAL. A throttle that only fires on arrival drops the
--- tail: an offender who strips twenty times in twenty seconds and then stops
--- has nineteen of those folded into a note that is waiting for a twenty-first
--- which never comes, and the record would close saying `3`. This is the line
--- that makes "the count is never lost" true rather than nearly true.
---
--- THE TEARDOWN IS THE RIGHT MOMENT AND NOT MERELY A CONVENIENT ONE. It is the
--- last instant anything will ask, it is already an event so no timer is added,
--- and the note it releases carries the final total for the match -- which is
--- the number an admin opening the case tomorrow is actually looking for.
--- @param matchId any
local function flushHeld(matchId)
    local m = lastSaid[key(matchId)]
    if not m then return end
    for _, rec in pairs(m) do
        local held = rec.held
        if held then
            rec.held = nil
            TriggerEvent('br:ringmaster:corroborate', held)
        end
    end
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
    --
    -- AND WHY IT GOES THROUGH `corroborate` RATHER THAN STRAIGHT ONTO THE EVENT.
    -- This producer self-attenuates -- the doublings are seconds apart and then
    -- minutes -- so it is the one least likely to be held, and it is routed
    -- through the same door anyway so that "a corroboration is throttled" is a
    -- property of this file rather than of two of its three handlers.
    local prior = BR.Incident.priorFor(ev.matchId, ev.license)
    if #prior > 0 then
        corroborate({
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

    -- THE MATCH AROUND THE CASE (#30). Match start and every kill so far, from
    -- the same `records` the evidence was built from -- so this reads the buffer
    -- once and costs no extra write.
    BR.Incident.attachTimeline(payload, records)

    TriggerEvent('br:ringmaster:incident', payload)
end)

-- ---------------------------------------------------------------------------
-- An unissued weapon in the hand
-- ---------------------------------------------------------------------------
--
-- THE SECOND ANTICHEAT SOURCE, AND IT REACHES THIS FILE THE SAME WAY THE FIRST
-- ONE DOES. server/strip.lua counts and decides, exactly as damage.lua counts
-- and decides; this file turns the announcement into a case or into a
-- corroboration. Neither detector knows this file exists, which is what lets
-- either of them be restarted, replaced or absent without the other caring.
--
-- ONE CASE PER PLAYER PER MATCH IS UNCHANGED AND IS THE POINT. The owner:
-- "a cheater is likely to do this several times recursively, so we need to log
-- that in the incident timeline rather than creating a new incident each time."
-- The rule that already produced that behaviour for refusals is `priorFor`, and
-- reusing it means a strip after a refusal case appends to the refusal case, and
-- a refusal after a strip case appends to the strip case. One player, one round,
-- one record -- whichever thing they did first opened it.
--
-- WHERE THE REPEATS ACTUALLY LAND. Every accepted strip is written into the
-- evidence buffer by server/strip.lua BEFORE it gets here, so:
--
--   the first    ride the PutItem this handler triggers -- the strips known at
--   two          filing time are on the timeline the case is created with, and
--                since the case is opened by the SECOND strip that includes the
--                first one, which was recorded and announced to nobody.
--   every one    is on the timeline the match-end close appends. That write was
--   after them   already happening for this case and touches only the attributes
--                the game's IAM grant allows; strips cost it nothing extra and
--                add no attribute to it.
--
-- SO A RECURSIVE CHEATER COSTS THE SAME TWO WRITES AS A SINGLE ONE. That is the
-- cost rule this whole subsystem is built on -- see the note further down --
-- and it matters more here than anywhere else in the file, because the volume is
-- chosen by the offender rather than by the game.
AddEventHandler('br:core:stripped', function(ev)
    if type(ev) ~= 'table' then return end

    local prior = BR.Incident.priorFor(ev.matchId, ev.license)
    if #prior > 0 then
        -- SAME CHANNEL, SAME REASONING as the refusal doubling above: the case
        -- is already durable, so "it is still happening" may ride the lossy
        -- event channel, and `seq` travels so the console can tell a dropped
        -- corroboration from a quiet match.
        --
        -- THIS IS THE PRODUCER THE OWNER'S 2026-08-22 SCREENSHOT WAS OF, and the
        -- one the throttle above was written for: `reason` and `severity` are
        -- both constants here, so a run of strips is a run of notes that differ
        -- in nothing but a counter, arriving at whatever rate MIN_INTERVAL_MS
        -- lets a strip be counted at. Every one of them still reaches the case
        -- -- `count` is cumulative and the timeline gets each strip in full --
        -- but they no longer each get a row of their own.
        corroborate({
            incidentId = prior[#prior],
            matchId    = ev.matchId,
            license    = ev.license,
            name       = ev.name,
            seq        = ev.seq,
            count      = ev.count,
            -- THE TAXONOMY'S OWN SENTENCE, which reads "weapon is not one this
            -- gamemode issues" -- true of a strip word for word. It is not
            -- claiming a shot was refused: `count` is the number of strips and
            -- the case's summary says so.
            reason     = BR.ShotRefusal.NO_WEAPON,
            severity   = BR.ShotTier[BR.ShotRefusal.NO_WEAPON],
            at         = ev.at,
        })
        return
    end

    local records = BR.Evidence and BR.Evidence.forLicense(ev.license) or {}

    local payload, why = BR.IncidentBuild.fromStrip(ev, records)
    if not payload then
        print(('^3[br_core] strip incident NOT filed for %s: %s^7')
            :format(tostring(ev.name), tostring(why)))
        return
    end

    payload.priorIncidentIds = prior
    BR.Incident.attachTimeline(payload, records)

    TriggerEvent('br:ringmaster:incident', payload)
end)

-- ---------------------------------------------------------------------------
-- A vehicle this gamemode refuses (#193)
-- ---------------------------------------------------------------------------
--
-- THE THIRD ANTICHEAT SOURCE, AND IT REACHES THIS FILE THE WAY THE OTHER TWO DO.
-- server/vehicles.lua counts and decides, exactly as damage.lua and strip.lua
-- count and decide; this file turns the announcement into a case or into a
-- corroboration. None of the three detectors knows this file exists, which is
-- what lets any of them be restarted, replaced or absent without the others
-- caring.
--
-- ONE CASE PER PLAYER PER MATCH IS UNCHANGED, AND HERE IT IS THE WHOLE OF THE
-- REPEAT HANDLING. The strip path also grows the incident's timeline, because
-- the owner asked for recursive strips to land "in the incident timeline rather
-- than creating a new incident each time". The owner's instruction for this one
-- is shorter -- "simply file an incident" -- so `priorFor` does all of it: the
-- first announcement opens a case, every one after it appends a corroboration to
-- that same case. See BR.IncidentBuild.fromVehicle for why no new timeline kind
-- was added, and what it would have cost.
--
-- AND IT CROSSES KINDS, WHICH IS THE POINT OF `priorFor` BEING SHARED. A refused
-- vehicle after a strip case appends to the strip case; a refused shot after a
-- vehicle case appends to the vehicle case. One player, one round, one record --
-- whichever thing they did first opened it.
AddEventHandler('br:core:vehicle', function(ev)
    if type(ev) ~= 'table' then return end

    local prior = BR.Incident.priorFor(ev.matchId, ev.license)
    if #prior > 0 then
        -- SAME CHANNEL, SAME REASONING as the two above: the case is already
        -- durable, so "it is still happening" may ride the lossy event channel,
        -- and `seq` travels so the console can tell a dropped corroboration from
        -- a quiet match.
        --
        -- AND THE THROTTLE ABOVE BARELY TOUCHES THIS ONE, which is a property of
        -- `ev.why` rather than a special case written for it: the two halves of
        -- the owner's vehicle rule are different strings, so a jet after a tank
        -- is a change of finding and goes out at once. Only a player repeatedly
        -- climbing into the SAME kind of refused vehicle folds -- which is the
        -- one case where the rows really would have been identical.
        corroborate({
            incidentId = prior[#prior],
            matchId    = ev.matchId,
            license    = ev.license,
            name       = ev.name,
            seq        = ev.seq,
            count      = ev.count,
            -- ═══ THIS DETECTOR'S OWN WORDS, NOT THE SHOT TAXONOMY'S ═══
            --
            -- THIS LINE USED TO READ `BR.ShotRefusal.NO_WEAPON` AND THAT WAS THE
            -- BUG the owner reported on 2026-08-22: "when getting in an
            -- unauthorized vehicle, the incident is described in ringmaster as an
            -- unauthorized weapon". It was borrowed verbatim from the strip
            -- handler above, along with the rest of this block, on the reasoning
            -- that it was "the closest true statement in an enum that is about
            -- shots". It is not a true statement at all here: that enum value IS
            -- the sentence "weapon is not one this gamemode issues", and the
            -- console prints `reason` straight onto the case's timeline -- see
            -- Ringmaster's src/app/api/ingest/route.ts, which composes the note
            -- as `N refusals this match · last: <reason> · worst: <severity>`.
            -- So every corroboration on a vehicle case described it as a weapon
            -- finding, in the one place on the page that says what is STILL
            -- happening.
            --
            -- `ev.why` IS THE FIELD THAT ALREADY EXISTS FOR THIS. config/
            -- vehicles.lua's BR.Config.VehicleRefusal values -- "vehicle flies",
            -- "vehicle has built-in weapons" -- are the two halves of the owner's
            -- rule in the owner's words, and server/vehicles.lua already puts the
            -- one that tripped on the wire. It is the same string
            -- BR.IncidentBuild.vehicleSummaryOf builds the case's own summary
            -- from, so the case and its corroborations now say the same thing
            -- rather than two different ones.
            --
            -- NOT DEFAULTED, DELIBERATELY. A `why` that never arrived leaves this
            -- nil, the field does not travel, and the console's note drops the
            -- `last:` clause entirely -- which is honest. A fallback of
            -- NO_WEAPON here would reintroduce exactly the sentence this line
            -- exists to stop.
            reason     = ev.why,
            -- THE TIER IS STILL READ FROM THE TAXONOMY, and that is not the same
            -- borrowing. `severity` is 'high'/'normal'/'low' -- a triage hint,
            -- with no prose in it and nothing to mis-describe -- and it is read
            -- from the same place BR.IncidentBuild.fromVehicle reads it, so the
            -- corroborations cannot grade the finding differently from the case
            -- they attach to.
            severity   = BR.ShotTier[BR.ShotRefusal.NO_WEAPON],
            at         = ev.at,
        })
        return
    end

    local records = BR.Evidence and BR.Evidence.forLicense(ev.license) or {}

    local payload, why = BR.IncidentBuild.fromVehicle(ev, records)
    if not payload then
        print(('^3[br_core] vehicle incident NOT filed for %s: %s^7')
            :format(tostring(ev.name), tostring(why)))
        return
    end

    payload.priorIncidentIds = prior
    BR.Incident.attachTimeline(payload, records)

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
--- AND NEITHER IS THE REPORTER, WHICH IS THE HALF #180 ADDS. Owner, 2026-08-18:
--- being told how to report a player by the system you have just reported them
--- to reads as though the report did not register -- the opposite of what this
--- notice is for. The subject exclusion above is #93's rule and is untouched;
--- this is a second, independent skip beside it.
---
--- `reporterLicense` IS GENUINELY OPTIONAL RATHER THAN DEFAULTED. Two sources
--- reach this function through the same acknowledgement: a player's report,
--- which has a reporter, and an anticheat filing, which has none. A default of
--- '' or 'none' would be a value that silently matches nobody -- and the day a
--- roster entry resolved to the same empty string, the notice would go quiet
--- for a player nobody could name. nil means "there is no reporter", the
--- comparison below is skipped entirely, and the anticheat path behaves exactly
--- as it did.
---
--- THE TEXT IS NOT SENT. The envelope carries an occasion and the client writes
--- the sentence. That was originally so the sentence could name whichever key
--- the player has the panel bound to (#168); since #180 the sentence is FIXED
--- and names tilde outright, and the reason it still is not composed here is
--- narrower but unchanged -- the wire carries occasions, and a server that
--- shipped prose would be a server that has to be redeployed to fix a typo.
---
--- ═══ WHY THERE IS NO DELAY AND NO JITTER ON THIS (#214) ═══
---
--- The question is fair and was asked directly: this fires the instant a case
--- becomes durable, and the offender is the one player who does not see it. If
--- they can watch anybody else react, is the TIMING itself not a signal that
--- tells them what they just got caught doing?
---
--- IT IS NOT, AND THE REASON IS THE ONE-PER-MATCH CAP RATHER THAN ANY SPACING.
--- A timing oracle is only worth anything if it can be RUN AGAIN. The attack
--- would be: do a suspicious thing, watch a second account or a stream for the
--- toast, adjust, repeat -- and read the detection threshold off the responses.
--- The cap is what kills that. One notice per match, total, means the channel
--- carries exactly one bit per round, and the FIRST case of the round spends it
--- -- possibly a case about somebody else entirely. There is no second trial to
--- compare against and no way to attribute the bit to one's own behaviour.
---
--- AND THE ENVELOPE NAMES NOBODY. `{ kind = 'exists' }` carries no subject, no
--- reporter, no reason, no count. A player who RECEIVES it learns only that
--- somebody in this round drew a case, so even a cooperating observer -- a
--- squadmate on voice, a second client -- cannot tell the offender that it was
--- about them. They do not know either. That is what reduces the oracle to a
--- single anonymous bit, and a delay on a single anonymous bit buys nothing.
---
--- NOR IS THE ABSENCE INFORMATIVE. Seeing no toast is the overwhelmingly common
--- state of every honest match ever played, so "I saw nothing" is not evidence
--- of anything and cannot be made into evidence by waiting longer.
---
--- WHAT WOULD CHANGE THIS: making the notice per-incident, per-pair, or naming
--- the subject. Any of the three restores the repeatable experiment, and the
--- delay-and-jitter conversation would then be worth having. Under the cap it is
--- machinery guarding an experiment nobody can run twice.
---
--- @param matchId any
--- @param subjectLicense string
--- @param reporterLicense string|nil  nil for an anticheat filing
local function announceReporting(matchId, subjectLicense, reporterLicense)
    -- NOT OUTSIDE A MATCH. `brrefuse` from a console, or an anticheat firing in
    -- the lobby, files under the `nomatch` sentinel -- there is no audience to
    -- address and no round for the nudge to be about.
    --
    -- ═══ WARMUP IS INSIDE, NOT OUTSIDE (#214) ═══
    --
    -- "During a match" is decided here, by whether the filing carries a matchId
    -- at all -- and a warmup case carries one. A match exists from the moment it
    -- is formed: it is in the registry with a `createdAt`, players are on the
    -- roster in WARMUP with its id, and server/strip.lua counts WARMUP as a live
    -- state on purpose. So a weapon granted on the pad opens a case and this
    -- notice goes out to the pad, which is the owner's call, in the owner's
    -- words: "Granting yourself a weapon through vMenu is exactly what NOBODY
    -- will do in the lobby. That's what cheaters do."
    --
    -- THE TEST IS DELIBERATELY NOT `m.startedAt ~= nil`. That field is stamped
    -- on entering PLAYING and is nil for the whole warmup, so gating on it would
    -- have silently excluded the earliest and cleanest cheat signal this server
    -- produces -- which is the exact bug #B had to repair one layer down, in
    -- attachTimeline, where a warmup case was never queued for its match-end
    -- write. Do not reintroduce that test here.
    --
    -- A REFUSED SHOT IN WARMUP STILL FILES NOTHING, and that is a different
    -- decision made in a different place: WARMUP is a RULE-class refusal, absent
    -- from BR.ShotSuspicious, so it never becomes an incident and never reaches
    -- this function. Strips and vehicles are MEANS-class and do.
    if matchId == nil then return end
    if not BR.Roster then return end

    local told, skipped, hushed, blind = 0, 0, 0, 0

    BR.Roster.each(
        function(e) return e.matchId == matchId end,
        function(src, e)
            -- A player who has already left is not on the wire; TriggerClientEvent
            -- to a recycled id would address whoever landed in that slot.
            if e.state == BR.PlayerState.LEFT then return end

            local byKind = BR.Identity and BR.Identity.ofPlayer(src)
            local lic = byKind and BR.Identity.qualified('license', byKind.license)

            -- ═══ A PLAYER WE CANNOT NAME IS NOT TOLD (#214) ═══
            --
            -- THIS USED TO FALL THROUGH TO THE TriggerClientEvent BELOW, and it
            -- was the one failure the paragraph at the top of this function says
            -- it must not have. Both skips beneath were written as `lic ~= nil
            -- and lic == ...`, so a player whose licence did not resolve matched
            -- NEITHER test and was therefore told. When that player is the
            -- SUBJECT, the offender has just been handed the notice #93 exists
            -- to withhold from them -- quietly, on the one path with no second
            -- check behind it.
            --
            -- THE TRIGGER IS NARROW AND IT IS NOT HYPOTHETICAL. This resolves
            -- the licence LIVE, off GetPlayerIdentifiers, whose own header in
            -- br_lib/shared/identity.lua says it "returns nil when FiveM did not
            -- report a license, which does happen". And the gap between the
            -- filing and this notice is a DynamoDB round trip that retries for
            -- up to thirty seconds, so the subject can be most of the way out of
            -- the server by the time we ask -- still on the roster, not yet
            -- LEFT, and no longer answering with identifiers.
            --
            -- FAILING CLOSED COSTS A COURTESY AND NOTHING ELSE. A player who
            -- goes untold loses a nudge about a feature that will still be there
            -- next round. A player who is wrongly told is an offender who now
            -- knows. Those are not comparable, so the nil case takes the safe
            -- side rather than the generous one.
            --
            -- AND IT IS DELIBERATELY NOT `BR.Identity` BEING ABSENT THAT THIS
            -- GUARDS. If that module ever went missing the whole match would go
            -- untold, which is the safe direction but a dead feature -- so the
            -- count below is on the log line rather than swallowed, and the
            -- shared-coverage gate is what keeps the module loaded.
            if lic == nil then
                blind = blind + 1
                return
            end

            if lic == subjectLicense then
                skipped = skipped + 1
                return
            end

            -- THE REPORTER (#180). Counted apart from the subject because the
            -- two withholdings are different facts: one is a moderation rule
            -- that must never break, the other is a courtesy, and a log line
            -- that added them together could not tell "the offender was
            -- excluded" from "somebody was".
            if reporterLicense ~= nil and lic == reporterLicense then
                hushed = hushed + 1
                return
            end

            -- AN ADMIN IS TOLD, LIKE EVERYBODY ELSE (#168 self-dealing).
            --
            -- This paragraph exists because the obvious reading of that issue
            -- says otherwise, and somebody will come back here. Admins are no
            -- longer PAID for a report (server/players.lua), but they still
            -- file one, it still opens a real case, and that case still carries
            -- evidence and still counts for everyone else -- so an admin who
            -- spots a cheater mid-match is exactly the audience this nudge is
            -- for. Withholding it would take away a genuine reporter to protect
            -- a reward they are not being offered.
            --
            -- The one sentence that is now slightly wrong for them is the last
            -- clause, "all accurate reports are rewarded with Volts". It is the
            -- owner's text, verbatim, and rewording it for an audience of a
            -- handful is not a call this file gets to make.
            TriggerClientEvent(BR.Net.REPORT_HINT, src, { kind = 'exists' })
            told = told + 1
        end)

    -- `unnamed` IS ON THE LINE RATHER THAN FOLDED INTO `withheld`, for the same
    -- reason the subject and the reporter are counted apart: it is a different
    -- fact. A non-zero count here is not a moderation decision, it is this
    -- server failing to read identifiers for somebody who was standing in the
    -- match -- and a number that only ever appears bundled with two deliberate
    -- withholdings is a number nobody will ever investigate.
    print(('[br_core] report hint: told %d player(s) in match %s, withheld from %d subject(s) and %d reporter(s), %d unnamed')
        :format(told, tostring(matchId), skipped, hushed, blind))
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
--
-- `reporterLicense` RIDES THIS ENVELOPE SINCE #180, and it is br_ringmaster
-- that puts it there -- it is forwarding a field the payload it just wrote
-- already carried, not looking anything up. It is absent on an anticheat
-- filing, because `BR.IncidentBuild.fromRefusal` sets no reporter at all, and
-- that absence is what makes the skip below correct without a sentinel.
--
-- ═══ EVERY CREATION PATH ARRIVES HERE, AND THAT IS THE DESIGN (#214) ═══
--
-- The owner's rule is "any time an incident is created for any reason during a
-- match, even by `system`". There are FOUR creation paths today -- a refused
-- shot, a stripped weapon, a refused vehicle (all three in this file) and a
-- player's report (server/players.lua) -- and not one of them announces
-- anything itself. All four emit `br:ringmaster:incident`; br_ringmaster writes
-- the row and emits `br:incident:filed`; this handler is where they meet.
--
-- SO A FIFTH PATH IS COVERED THE DAY IT IS WRITTEN, WITHOUT CALLING ANYTHING.
-- That is not a happy accident and it is worth stating plainly, because #211 is
-- adding one right now (occupancy-based filing for stolen aircraft). Whoever
-- writes it has to do nothing here: emit the payload like the other four and
-- the notice follows. The only way to build a path this misses is to write the
-- DynamoDB row without going through `br:ringmaster:incident` -- and verify.sh's
-- `incident surface` gate fails the build if a second sender of the hint, or a
-- second emitter of this acknowledgement, ever appears.
--
-- A CORROBORATION IS NOT A CREATION, and the separation is structural rather
-- than a condition anybody has to remember. Corroborations go out on
-- `br:ringmaster:corroborate`, br_ringmaster puts them on the outbox and mints
-- no acknowledgement, so they never reach this handler at all. Nothing here has
-- to test for one.
--
-- THE CAP IS `first`, AND IT IS ONE PER MATCH RATHER THAN ONE PER PLAYER.
-- `remember` returns true only when the match had no filings at all, so the
-- second case of a round -- about anybody, from any path -- announces nothing,
-- and a player who joins after the notice went out is simply not told. See the
-- oracle note on `announceReporting`: the cap is what makes the timing of this
-- notice unusable to the offender, so it is load bearing for #93 and not merely
-- a politeness about toast volume.
AddEventHandler('br:incident:filed', function(ack)
    if type(ack) ~= 'table' then return end
    local first = BR.Incident.remember(ack.matchId, ack.subjectLicense, ack.incidentId)
    if first then
        announceReporting(ack.matchId, ack.subjectLicense, ack.reporterLicense)
    end
end)

-- Same teardown hook the evidence buffer uses, and for the same reason: `destroy`
-- is the only way a match leaves the registry, whereas `br:match:results`
-- returns early when nobody scored. Dropping the map here keeps it the size of
-- the matches currently running rather than of the server's uptime.
--
-- `openBy` IS DELIBERATELY NOT DROPPED HERE, and that is the whole of #177's
-- first correction. Everything above about keeping the map the size of the
-- matches currently running is an argument about the CORROBORATION TARGET
-- WITHIN a round; the killer prompt asks a question that outlives the round,
-- and freeing its answer at teardown is precisely why a day-old case produced
-- no prompt. See OPEN_MAX for what bounds it instead.
AddEventHandler('br:match:destroyed', function(ev)
    if not ev or ev.matchId == nil then return end
    -- BEFORE THE MAP GOES, AND THE ORDER IS THE WHOLE POINT. `flushHeld` reads
    -- the record this next line deletes, and the note it releases is the one
    -- carrying the match's final offence count -- see the throttle's header for
    -- why that note is the only one whose loss would cost anything.
    flushHeld(ev.matchId)
    lastSaid[key(ev.matchId)] = nil
    filed[ev.matchId] = nil
end)

AddEventHandler('onResourceStart', function(name)
    if name == GetCurrentResourceName() then
        filed = {}
        openBy = {}
        -- INCLUDING THE `nomatch` BUCKET, which nothing else empties. See
        -- `lastSaid`: it is the only bucket a teardown never reaches.
        lastSaid = {}
    end
end)

-- ---------------------------------------------------------------------------
-- The match timeline (#30)
-- ---------------------------------------------------------------------------
--
-- An incident should show the match around it, not just the report. Two halves,
-- and the split between them is a cost decision rather than a structural one:
--
--   AT FILING      when the match was formed, when it started if it has, and
--                  every kill and strip by the subject so far. All of it is
--                  already in hand -- the match registry knows both timestamps
--                  and the evidence buffer has been holding the rest in RAM all
--                  along -- so they ride the PutItem that was already happening
--                  and cost NOTHING extra.
--
--   AT MATCH END   the fact that the match ended, plus the kills and strips that
--                  happened after the case was filed -- and, for a case filed
--                  during WARMUP, the start and deadline that did not exist yet
--                  when its row was written. None of that can be known at filing
--                  time, and it is therefore the only extra write: ONE per
--                  incident, and none at all for a match that produced no
--                  incident.
--
-- A CASE FILED DURING WARMUP GETS BOTH HALVES, which it did not before #B. The
-- registration below used to require a match START, so a warmup case was never
-- queued for the close and its row never received an end -- the one shape the
-- console cannot distinguish from "this was not about a match at all".
--
-- NOTHING IS LOGGED SPECULATIVELY. A quiet match still writes nothing, which is
-- the rule the evidence buffer already existed to enforce and the reason the
-- timeline is built on it instead of on a second stream of events.

--- Filing instants, waiting for the id that will name them.
---
--- WHY THIS IS NOT JUST READ AT ACKNOWLEDGEMENT TIME. `br:incident:filed` comes
--- back from br_ringmaster only once the row is durable, and that path retries
--- for up to thirty seconds. Timestamping the filing from the acknowledgement
--- would put the case's zero point up to half a minute after the thing it is
--- about -- and every kill in that window would be classified as "before the
--- report" by one function and "after" by another.
---
--- [matchId] = { [license] = { at, killsWritten } }
local pendingTimeline = {}

--- Incidents to close when this match ends.
---
--- [matchId] = { { incidentId, license, filedAt, killsWritten }, ... }
local closing = {}

--- Fold the match context onto an outgoing incident payload.
---
--- Called by BOTH producers -- the anticheat path above and the player-report
--- path in server/players.lua -- because there is no single choke point on this
--- side: each builds its payload with a different BR.IncidentBuild function and
--- emits it directly. One helper called twice beats two copies of the same
--- merge, which is how the two would drift.
---
--- SAFE WHEN THERE IS NO MATCH. `brrefuse` from a console and an anticheat trip
--- in the lobby both carry a nil matchId; timelineOpen answers with an empty
--- timeline and the console shows no match context, which is the truth rather
--- than an invented one.
---
--- @param payload table  the incident payload, mutated in place
--- @param records table|nil  BR.Evidence.forLicense(subject)
--- @return table payload
function BR.Incident.attachTimeline(payload, records)
    if type(payload) ~= 'table' then return payload end

    local m = nil
    if payload.matchId ~= nil and BR.Server and BR.Server.matches then
        m = BR.Server.matches[payload.matchId]
    end

    -- `startedAt` IS STAMPED ON ENTERING PLAYING AND NOTHING CLEARS IT
    -- (server/match.lua), and BR.Match.wasPlayed is the same test. So it is nil
    -- for every case filed on the warmup pad -- and `createdAt` is what those
    -- cases are anchored on instead.
    --
    -- BOTH ARE SENT AND NEITHER IS SUBSTITUTED FOR THE OTHER. The tempting
    -- one-liner is `matchStartedAt = m.startedAt or m.createdAt`, and it is
    -- wrong: `matchStartedAt` would then mean "the match began" on some rows and
    -- "the lobby opened" on others, with nothing on either row saying which, and
    -- every consumer of it -- the console's header, the `matchEndsBy` deadline,
    -- the `match_start` timeline entry -- would inherit the ambiguity silently.
    local t = BR.IncidentBuild.timelineOpen({
        matchId        = payload.matchId,
        matchStartedAt = m and m.startedAt or nil,
        matchCreatedAt = m and m.createdAt or nil,
        records        = records,
    })

    payload.matchStartedAt        = t.matchStartedAt
    payload.matchCreatedAt        = t.matchCreatedAt
    payload.matchEndsByMs         = t.matchEndsByMs
    payload.matchTimeline         = t.matchTimeline
    payload.matchTimelineComplete = t.matchTimelineComplete
    payload.matchKillsSeen        = t.matchKillsSeen

    -- KEEP MORE ABOUT THIS PLAYER FROM NOW ON. The buffer's default caps are
    -- sized for an evidence snippet; #30 wants every kill. Promoting here rather
    -- than at acknowledgement puts the larger cap in place at the earliest
    -- possible moment -- before the DynamoDB round trip, not after it.
    if BR.Evidence and BR.Evidence.retain then
        BR.Evidence.retain(payload.subjectLicense)
    end

    -- ═══ A WARMUP CASE IS REGISTERED FOR THE CLOSE LIKE ANY OTHER ═══
    --
    -- THIS GUARD USED TO READ `t.matchStartedAt ~= nil` AND THAT WAS THE BUG. A
    -- case filed on the warmup pad never entered this map, so it never moved to
    -- `closing` on the acknowledgement, so it never received a match-end write
    -- -- not later, not ever. Its row sat in the console with no start, no
    -- deadline and no end, which the console reads as "filed outside a match":
    -- false about a row that carries a matchId, and false about the earliest
    -- cheat signal this server can produce.
    --
    -- WHAT REPLACES IT IS "DO WE KNOW OF THIS MATCH AT ALL", not "did it start".
    -- Either timestamp answers that. A payload whose matchId names a match the
    -- registry has never heard of -- a stale id, a restarted resource -- still
    -- registers nothing, because the match-end event that would clear it is
    -- never coming and the entry would sit here for the life of the process.
    if payload.matchId ~= nil and payload.subjectLicense ~= nil
        and (t.matchStartedAt ~= nil or t.matchCreatedAt ~= nil) then
        local byLicense = pendingTimeline[payload.matchId]
        if not byLicense then
            byLicense = {}
            pendingTimeline[payload.matchId] = byLicense
        end
        byLicense[payload.subjectLicense] = {
            at            = payload.atGameMs,
            killsWritten  = t.matchKillsWritten or 0,
            stripsWritten = t.matchStripsWritten or 0,
        }
    end

    return payload
end

-- A SECOND LISTENER ON THE SAME ACKNOWLEDGEMENT, rather than a line added to the
-- handler above. server/players.lua, server/grants.lua and server/artifacts.lua
-- all already listen to `br:incident:filed` alongside this file's own handler --
-- the event is explicitly a broadcast with several independent readers, and one
-- more of them is the established shape here rather than a new coupling.
AddEventHandler('br:incident:filed', function(ack)
    if type(ack) ~= 'table' then return end
    if ack.matchId == nil or ack.subjectLicense == nil then return end
    if ack.incidentId == nil then return end

    local byLicense = pendingTimeline[ack.matchId]
    local pend = byLicense and byLicense[ack.subjectLicense]
    if not pend then return end
    byLicense[ack.subjectLicense] = nil

    local list = closing[ack.matchId]
    if not list then
        list = {}
        closing[ack.matchId] = list
    end
    list[#list + 1] = {
        incidentId    = ack.incidentId,
        license       = ack.subjectLicense,
        filedAt       = pend.at,
        killsWritten  = pend.killsWritten,
        stripsWritten = pend.stripsWritten,
    }
end)

-- THE MATCH IS OVER AND THE EVIDENCE IS STILL HERE, WHICH IS TRUE FOR EXACTLY
-- ONE MOMENT. server/evidence.lua emits this from inside its own
-- `br:match:destroyed` handler, immediately before it discards the buffer.
--
-- IT IS NOT `br:match:destroyed`, AND THAT IS THE WHOLE POINT. Listening to that
-- event here would read an EMPTY buffer: FiveM runs handlers in registration
-- order, registration order is manifest order, and br_core's manifest loads
-- server/evidence.lua at line 114 and this file at line 138 -- so the discard
-- would already have happened. The feature would have shipped looking correct
-- and recording nothing, which this project has done before.
AddEventHandler('br:evidence:closing', function(ev)
    if not ev or ev.matchId == nil then return end

    local list = closing[ev.matchId]
    closing[ev.matchId] = nil
    -- A filing whose id never came back has no row to close against.
    pendingTimeline[ev.matchId] = nil
    if not list then return end

    local endedAt = GetGameTimer()

    for _, c in ipairs(list) do
        local records = BR.Evidence and BR.Evidence.forLicense(c.license) or {}

        local close = BR.IncidentBuild.timelineClose({
            matchEndedAt  = endedAt,
            -- FROM THE EVENT, NOT FROM THE REGISTRY. server/match.lua clears
            -- `BR.Server.matches[id]` before it announces the destruction, so a
            -- lookup here reads nil for EVERY match -- including the ones that
            -- ran for twenty minutes -- and the close would then null out a
            -- start that was correct on the row. It travels on the event
            -- instead; see the note at the TriggerEvent in server/match.lua.
            matchStartedAt = ev.startedAt,
            filedAtGameMs = c.filedAt,
            records       = records,
            priorKills    = c.killsWritten,
            priorStrips   = c.stripsWritten,
        })

        -- EMITTED, NOT CALLED. br_ringmaster listens; if it is not running,
        -- nothing happens and br_core carries on. The game never depends on
        -- Ringmaster -- it writes and moves on -- and that rule applies to the
        -- match-end write exactly as it does to the filing.
        TriggerEvent('br:ringmaster:incidentClose', {
            incidentId            = c.incidentId,
            matchId               = ev.matchId,
            subjectLicense        = c.license,
            matchEndedAt          = close.matchEndedAt,
            -- THE TWO THAT REPAIR A WARMUP-FILED ROW. Both are nil for a match
            -- that dissolved without going live, and a nil key does not travel
            -- -- so the close writes nothing about a start that never happened
            -- rather than writing a null over the row's own answer.
            --
            -- THE IAM POLICY MUST NAME `matchStartedAt` AND `matchEndsBy`
            -- BEFORE THIS SHIPS. DynamoDB refuses the whole UpdateItem when an
            -- attribute is outside the grant's allowlist, so an un-widened
            -- policy costs the end timestamp and the post-filing timeline too,
            -- not just these two. `brring` reports the failures.
            matchStartedAt        = close.matchStartedAt,
            matchEndsByMs         = close.matchEndsByMs,
            matchTimeline         = close.matchTimeline,
            matchTimelineComplete = close.matchTimelineComplete,
            matchKillsSeen        = close.matchKillsSeen,
        })
    end
end)

-- BELT AND BRACES ON THE MAPS ABOVE. `br:evidence:closing` normally clears both,
-- but it is emitted by another file -- so a br_core built without
-- server/evidence.lua, or one whose emit is ever moved, must not accumulate a
-- match's worth of closures per round for the life of the process.
AddEventHandler('br:match:destroyed', function(ev)
    if not ev or ev.matchId == nil then return end
    closing[ev.matchId] = nil
    pendingTimeline[ev.matchId] = nil
end)

AddEventHandler('onResourceStart', function(name)
    if name == GetCurrentResourceName() then
        closing = {}
        pendingTimeline = {}
    end
end)

--- Counters for the close path, for brdebug-style introspection.
function BR.Incident.closeStats()
    local matches, cases, pending = 0, 0, 0
    for _, list in pairs(closing) do
        matches = matches + 1
        cases = cases + #list
    end
    for _, byLicense in pairs(pendingTimeline) do
        for _ in pairs(byLicense) do pending = pending + 1 end
    end
    return { matches = matches, cases = cases, pending = pending }
end
