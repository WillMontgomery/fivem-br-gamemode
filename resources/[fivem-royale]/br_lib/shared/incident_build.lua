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
---           plausible innocent story: position sampling and a bad tick can
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
--- THE SAME TABLE, NOT A SECOND COPY OF IT.
---
--- This used to be its own literal here, which meant the grading existed twice:
--- once where the incident is built and once nowhere at all, because the threshold
--- did not consult it. Now that the bar itself is graded (`BR.ShotBarFor`), the
--- decision to file and the severity written on the case have to agree by
--- construction rather than by two people editing two tables.
---
--- It also fixes the footgun the header of this file used to warn about: the table
--- is keyed on `BR.ShotRefusal` VALUES, which are prose sentences, so building it
--- here required combat_solve.lua to have loaded first. It now lives beside the
--- enum it keys on.
BR.IncidentBuild.SEVERITY_OF = BR.ShotTier

--- The severity a match's tally deserves.
---
--- WORST WINS. A match is a mix, and grading it by whichever reason arrived last
--- filed seven conjured-weapon refusals as whatever the eighth happened to be.
---
--- DELEGATES TO `BR.ShotTallyVerdict`, which is also what decides whether to file
--- at all. Those two answers have to agree: a case opened because `NOT_HELD`
--- crossed its bar must not then be written down as `normal` because a `TOO_FAR`
--- was also in the tally. One function, one traversal, one answer.
---
--- `low` is still a tier the console renders and nothing here returns it; a player
--- report will be its first producer.
---
--- @param reasons table|nil  { [reason] = count }, as sent by damage.lua
--- @param last string|nil    the final reason, for an older event with no tally
--- @return string|nil        nil when nothing in the tally files anything
function BR.IncidentBuild.severityOf(reasons, last)
    local bar = (BR.Config and BR.Config.Combat or {}).refusalBar

    -- FALLS BACK TO THE LAST REASON ONLY WHEN THERE IS NO TALLY AT ALL, so an
    -- event from a build that predates the tally still classifies. Same instinct
    -- as the console keeping the older `action` values: one side being a deploy
    -- behind must not lose the record. Such an event was emitted at ITS OWN
    -- threshold, so its existence is the evidence that a bar was crossed, and
    -- re-testing one reason against a count of one would discard the case.
    --
    -- IT MUST NOT FIRE WHEN A TALLY IS PRESENT AND SIMPLY DID NOT CROSS. The first
    -- version of this checked the tally and then fell through on nil, which let
    -- `{ SELF = 7, NO_WEAPON = 1 }` file as high on the strength of `last` alone --
    -- reinstating, by accident, exactly the two behaviours this change removed.
    if type(reasons) ~= 'table' then
        return last and BR.ShotTier[last] or nil
    end

    local _, severity = BR.ShotTallyVerdict(reasons, bar)
    return severity
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

--- Build an incident from a player's report.
---
--- THE SECOND SOURCE, and the shape is deliberately the same as the anticheat's
--- so the console has one record type rather than two that drift. What differs
--- is what can be trusted: an anticheat incident carries a measurement, a report
--- carries an accusation. Nothing here decides which is true -- that is the
--- whole point of an incident.
---
--- SEVERITY IS NOT SET. `severityOf` grades refusal reasons, and a human's
--- category is not a measurement of anything: "cheating" from a player who just
--- lost a fight and "cheating" from a spectator watching someone track through a
--- wall are the same string. Grading them here would invent confidence that does
--- not exist. The console sorts reports by age, like the queue does.
---
--- NO LICENSE, NO INCIDENT -- for either party. The subject's license keys the
--- record; the reporter's is what makes "somebody who reports everybody"
--- visible, which is a signal the console explicitly renders. A report missing
--- either is dropped rather than filed against a server id.
---
--- THERE IS NO `note`, AND THERE NEVER REALLY WAS. The panel had a free-text
--- field, the callback forwarded it, the server capped it at BR.Config.Report
--- .maxNote and this function copied it onto the payload -- and br_ddb has
--- written `note: null` unconditionally since 2026-08-14, on an owner call
--- whose comment is still sitting in js-src/br_ddb/src/incident.js: "NO
--- FREE-TEXT NOTE, EVER, FROM THE GAME ... there is no player-supplied prose
--- anywhere in this row. That removes the injection surface rather than
--- guarding it."
---
--- So five layers of plumbing carried a string to a hard-coded null. The field
--- is deleted here rather than left accepting a value it discards, because the
--- next reader of this file has no way to discover that from Lua -- they would
--- have to go and read the bundle to find out that the note they are carefully
--- passing through goes nowhere. Removed with #142, which took the field off
--- the panel for an unrelated reason and made the whole chain visible.
---
--- @param ev table  { license, name, reporterLicense, reporterName, category, matchId, at }
--- @param records table|nil  evidence rows for the SUBJECT
--- @return table|nil payload, string|nil why
function BR.IncidentBuild.fromReport(ev, records)
    if type(ev) ~= 'table' then return nil, 'no event' end

    if type(ev.license) ~= 'string' or ev.license == '' then
        return nil, 'no subject license'
    end
    if type(ev.reporterLicense) ~= 'string' or ev.reporterLicense == '' then
        return nil, 'no reporter license'
    end

    -- SELF-REPORTS ARE REFUSED HERE AS WELL AS AT THE DOOR. The server already
    -- rejects them, and this is the layer that builds the record -- a rule
    -- enforced in exactly one place is a rule one refactor away from being gone.
    if ev.license == ev.reporterLicense then
        return nil, 'cannot report yourself'
    end

    local evidence = {}
    for _, r in ipairs(records or {}) do
        evidence[#evidence + 1] = evidenceRow(r)
    end

    local newest = evidence[#evidence]

    return {
        kind     = 'report',
        category = ev.category,
        state    = 'pending_review',

        subjectLicense = ev.license,
        subjectName    = ev.name,
        subjects = { {
            license = ev.license,
            name    = ev.name,
            squadId = newest and newest.squadId or nil,
            left    = newest and newest.left or false,
        } },

        -- PRESENT, unlike the anticheat's payload where these are deliberately
        -- absent. br_ddb writes absent keys as explicit nulls, and the console
        -- tests `reporterLicense === null` to mean "the system filed this" --
        -- so a report MUST carry them or it reads as system-generated.
        reporterLicense = ev.reporterLicense,
        reporterName    = ev.reporterName,

        matchId = ev.matchId,

        -- The summary is the queue row, and it is built only from a category
        -- out of a fixed list plus a name. It carried that shape when there was
        -- also a free-text note to quote and NOT quoting it was the decision;
        -- with the note gone the shape is the same and the reason is now
        -- structural, which is stronger.
        summary = ('Reported for %s by %s'):format(
            tostring(ev.category), tostring(ev.reporterName or 'a player')),

        evidence = evidence,
        atGameMs = ev.at,
    }
end
