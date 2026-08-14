-- Turning a refusal cluster into an incident payload, as pure functions.
--
-- WHY THIS FILE EXISTS SEPARATELY. The same split as combat_solve/damage and
-- evidence_buf/evidence: the wiring -- which event fires, which native reports
-- the time, what the roster happens to know -- cannot be exercised outside the
-- game, but the DECISIONS can. And the decisions here are the ones that are
-- expensive to get wrong: how bad is this, what goes in the record, and what
-- does the one line an admin reads in a queue actually say.
--
-- THE PAYLOAD MIRRORS RINGMASTER'S `Incident` INTERFACE (src/lib/incidents.ts)
-- because the game writes the row itself. Nothing on the console side maps or
-- renames these fields on the way in -- br_ddb adds an id and a real clock and
-- puts the item. So a field named wrongly here is a field the console cannot
-- read, and the pin against that is tools/fixtures plus the console's own
-- check script.
--
-- WHAT IT DELIBERATELY DOES NOT DECIDE: whether anybody gets kicked. The game
-- files a case and forms no opinion about the player. Severity is a hint for
-- how a human should triage, not an instruction -- see docs/security.md.

BR = BR or {}

BR.IncidentBuild = {}

--- HOW BAD IS A REFUSAL, and the reasoning for each tier.
---
--- Keyed on the refusal VALUES, which are prose (`BR.ShotRefusal.NO_WEAPON` is
--- the sentence, not the symbol) -- so this table has to be built from the enum
--- rather than from string literals, or it silently matches nothing.
---
---   high    The server never issued the means. There is no honest path to a
---           weapon the gamemode does not have, a magazine it did not fill, or
---           a weapon that is not in the shooter's hands. A cluster of these is
---           somebody running something.
---   normal  A number the weapon does not have -- out of range, or cycling
---           faster than its action. Real signals, but the ones with a
---           plausible innocent story: 2Hz position sampling and a bad tick can
---           manufacture both, which is why the validator already carries slack
---           and why these do not read as loudly.
---
--- SELF IS DELIBERATELY ABSENT, and it is the one entry worth arguing about.
---
--- It counts toward the threshold -- BR.ShotSuspicious includes it, and it must,
--- because somebody mixing self-hits with real means should still trip. But a
--- window of NOTHING BUT self-harm earns no severity, so no incident is filed.
--- The arithmetic is why: `selfLimit = 2` over `selfWindowMs = 5000`, so the third
--- self-damage tick in five seconds is already "repetition" -- and one grenade at
--- your own feet lands several ticks well inside that. So a pure-self cluster of
--- eight is two grenades, not somebody exercising something.
---
--- Mixing still works, because severity is the WORST reason in the window: seven
--- conjured-weapon shots and one self-hit files as `high`, and the self-hits do
--- not drag it down. That is the property the tally exists for.
---
--- NOTHING ELSE IS EXCLUDED HERE. The rules -- friendly fire, warmup scraps, a
--- shot that raced a match boundary -- are excluded upstream in
--- `BR.ShotSuspicious`, which is pinned by an exhaustive test and by a gate in
--- tools/verify.sh. A second filter for those would be a second place for the
--- rule to live and a second place for it to rot.
BR.IncidentBuild.SEVERITY_OF = {
    [BR.ShotRefusal.NO_WEAPON]  = 'high',
    [BR.ShotRefusal.NOT_HELD]   = 'high',
    [BR.ShotRefusal.NO_AMMO]    = 'high',
    [BR.ShotRefusal.NOT_THROWN] = 'high',
    [BR.ShotRefusal.TOO_FAR]    = 'normal',
    [BR.ShotRefusal.TOO_FAST]   = 'normal',
}

--- Worst wins, and the order is explicit rather than alphabetical luck.
---
--- `low` has no producer yet and is kept because the console renders three tiers
--- and a player report will use it. Nothing in this file returns it.
local RANK = { low = 1, normal = 2, high = 3 }

--- The severity a whole window deserves.
---
--- A WINDOW IS A MIX, WHICH THE FIRST VERSION OF THIS GOT WRONG. The refusal
--- counter fires once per window and reports only the LAST reason -- so seven
--- conjured-weapon refusals followed by one self-hit would have been filed as
--- `low` and sorted to the bottom of somebody's queue. Taking the worst reason
--- in the window fixes that, and needs the per-reason tally the event now
--- carries.
---
--- @param reasons table|nil  { [reason] = count }, as sent by damage.lua
--- @param last string|nil    the final reason, for an older event with no tally
--- @return string|nil        nil when nothing in the window is classifiable
function BR.IncidentBuild.severityOf(reasons, last)
    local best, bestRank = nil, 0

    if type(reasons) == 'table' then
        for reason, n in pairs(reasons) do
            local sev = BR.IncidentBuild.SEVERITY_OF[reason]
            -- `n` is checked because a tally entry of zero is a reason that was
            -- counted and then rolled out of the window, not a reason present.
            if sev and (tonumber(n) or 0) > 0 and RANK[sev] > bestRank then
                best, bestRank = sev, RANK[sev]
            end
        end
    end

    -- FALLS BACK TO THE LAST REASON, so an event from a build that predates the
    -- tally still classifies. Same instinct as the console keeping the old
    -- `action` values: one side being a deploy behind must not lose the record.
    if not best and last then best = BR.IncidentBuild.SEVERITY_OF[last] end

    return best
end

--- The one line shown in the queue.
---
--- NEVER INTERPOLATED INTO ANYTHING, per the field's own contract on the console
--- side -- it is displayed and nothing else. It is still built only from server
--- facts (two integers and an enum value), because the day somebody does
--- interpolate it, a player-controlled name in here would be the bug.
--- @param count integer
--- @param windowMs integer
--- @param reason string
--- @return string
function BR.IncidentBuild.summaryOf(count, windowMs, reason)
    return ('%d shots refused in %ds -- %s')
        :format(count, math.floor((windowMs or 0) / 1000), tostring(reason))
end

--- Project one evidence record onto the wire.
---
--- A PROJECTION RATHER THAN THE RECORD ITSELF. The buffer holds `key`, which is
--- a server id -- recycled within the minute and meaningless to anybody reading
--- the case later. Sending it would invite exactly the mistake sealing exists to
--- prevent: treating a slot number as a person.
local function evidenceRow(r)
    return {
        license = r.license,
        name    = r.name,
        matchId = r.matchId,
        squadId = r.squadId,
        -- Game-clock readings. br_ringmaster converts them to real time on the
        -- way out, because it is the resource that samples the clock pair.
        openedAt = r.openedAt,
        leftAt   = r.leftAt,
        left     = r.leftAt ~= nil,
        chat     = r.chat,
        kills    = r.kills,
    }
end

--- Build the payload for an anticheat incident, or decide there is not one.
---
--- @param ev table        the `br:ringmaster:refusal` payload
--- @param records table|nil  BR.Evidence.forLicense(ev.license), or nil
--- @return table|nil payload, string|nil why-not
function BR.IncidentBuild.fromRefusal(ev, records)
    if type(ev) ~= 'table' then return nil, 'no event' end

    -- NO LICENSE, NO INCIDENT. A case keyed to a server id is a case about
    -- whoever holds that slot next, and filing it would be worse than filing
    -- nothing: it puts a stranger's name on a record that cannot be withdrawn.
    -- damage.lua resolves the license before emitting precisely so this is rare.
    if type(ev.license) ~= 'string' or ev.license == '' then
        return nil, 'no license'
    end

    local severity = BR.IncidentBuild.severityOf(ev.reasons, ev.reason)
    if not severity then return nil, 'not a countable refusal' end

    local subjects = {}
    local evidence = {}
    for _, r in ipairs(records or {}) do
        evidence[#evidence + 1] = evidenceRow(r)
    end

    -- SQUAD AT INCIDENT TIME travels with the subject, because it is the
    -- question the console has to answer about a report ("were these two on the
    -- same team?") and squads change between the incident and anybody reading
    -- it. Taken from the newest evidence record when there is one, since that is
    -- the session the refusals happened in; the event's own view otherwise.
    local newest = evidence[#evidence]
    subjects[1] = {
        license = ev.license,
        name    = ev.name,
        squadId = newest and newest.squadId or nil,
        left    = newest and newest.left or false,
    }

    return {
        kind     = 'anticheat',
        category = 'system',
        state    = 'pending_review',
        severity = severity,

        subjectLicense = ev.license,
        subjectName    = ev.name,
        subjects       = subjects,

        -- NO `reporterLicense` AND NO `reporterName`, and they are absent rather
        -- than null because a Lua key set to nil is not sent -- it simply does
        -- not exist, the same trap the ingest schema's `optNull` exists for.
        -- br_ddb writes them as explicit nulls, so the console's
        -- `reporterLicense === null` test still means "the system filed this".
        -- A player report (the other caller of this pipeline) fills them.

        matchId = ev.matchId,
        summary = BR.IncidentBuild.summaryOf(ev.count, ev.windowMs, ev.reason),

        refusal = {
            count    = ev.count,
            windowMs = ev.windowMs,
            reason   = ev.reason,
            reasons  = ev.reasons,
            action   = ev.action,
        },

        evidence = evidence,

        -- The game clock at the moment the threshold tripped. Converted to a
        -- real timestamp by br_ringmaster; `openedAt` is never set here, because
        -- br_core has no clock worth putting in a record somebody reads next
        -- week.
        atGameMs = ev.at,
    }
end
