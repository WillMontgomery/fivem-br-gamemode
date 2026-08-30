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

--- What each chat refusal reason is called on a moderation record.
---
--- PROSE, KEYED ON THE REASON, mirroring how BR.ShotTier is keyed on
--- BR.ShotRefusal's values. These strings reach the console as a corroboration's
--- `reason` and are read by a person, so they are sentences rather than symbols.
BR.IncidentBuild.CHAT_REASON = {
    link   = 'a link, which this server does not carry',
    script = 'characters from a script this server does not accept',
}

--- The one line shown in the queue for a chat case.
---
--- ═══ NO PLAYER TEXT IN THE SUMMARY, DELIBERATELY ═══
---
--- The refused line itself is on the timeline, where a reviewer opens the case to
--- read it. It is NOT in this sentence, and the reason is the one
--- `stripSummaryOf` already gives: this field's contract on the console side is
--- "displayed and nothing else", it is what the QUEUE shows, and the queue is a
--- list of cases about people. Putting an advert in it would publish the advert
--- to the one page every admin reads, which is a smaller version of exactly what
--- the shadow post exists to prevent.
---
--- BUILT FROM SERVER FACTS ONLY -- one integer and one of two fixed reasons.
--- @param count integer
--- @param reason string
--- @return string
function BR.IncidentBuild.chatSummaryOf(count, reason)
    local n = math.floor(tonumber(count) or 0)
    return ('%d chat message%s held back this match -- %s')
        :format(n, n == 1 and '' or 's',
            BR.IncidentBuild.CHAT_REASON[reason] or tostring(reason))
end

--- Build an incident from a chat line the server refused to deliver.
---
--- THE FOURTH SOURCE, and the shape is the anticheat's rather than the report's:
--- the server MEASURED something (this line contains a link; this line is not in
--- an alphabet we take) rather than repeating a human's accusation. So it carries
--- no reporter, and br_ddb writes the reporter fields as explicit nulls, which is
--- what makes the console read it as system-filed.
---
--- SEVERITY IS `low`, AND THAT IS A DELIBERATE FLOOR RATHER THAN A SHRUG.
--- `severityOf` grades what a refused SHOT means, where `high` says the server
--- never issued the means and there is no honest path to it. A chat line has no
--- equivalent: the overwhelming majority of these are a player pasting a Discord
--- invite, which is against the rules and is not cheating. Grading it beside a
--- conjured weapon would put advertising and aimbotting in the same tier and
--- teach whoever reads the queue to trust the tier less.
---
--- NO MATCH, NO INCIDENT -- and the line is still shadowed. The evidence buffer
--- refuses to hold lobby chat at all (server/evidence.lua's metaFor: "Lobby
--- chatter is not evidence of anything"), so a case filed from the lobby would
--- carry a summary and an empty timeline -- a moderation record with the one
--- thing the owner asked for missing from it. server/strip.lua declines on the
--- same rule for the same reason. THE MESSAGE IS STILL NOT DELIVERED; what is
--- skipped is the paperwork, not the refusal.
---
--- @param ev table  { license, name, matchId, reason, count, at }
--- @param records table|nil  evidence rows for the sender
--- @return table|nil payload, string|nil why
function BR.IncidentBuild.fromChat(ev, records)
    if type(ev) ~= 'table' then return nil, 'no event' end

    -- NO LICENSE, NO INCIDENT. A case keyed to a server id is a case about
    -- whoever holds that slot next; the same rule the other three builders open
    -- with.
    if type(ev.license) ~= 'string' or ev.license == '' then
        return nil, 'no license'
    end
    if ev.matchId == nil then return nil, 'not in a match' end
    if BR.IncidentBuild.CHAT_REASON[ev.reason] == nil then
        return nil, 'not a chat refusal reason'
    end

    local evidence = {}
    for _, r in ipairs(records or {}) do
        evidence[#evidence + 1] = evidenceRow(r)
    end

    local newest = evidence[#evidence]

    return {
        kind     = 'anticheat',
        category = 'system',
        state    = 'pending_review',
        severity = 'low',

        subjectLicense = ev.license,
        subjectName    = ev.name,
        subjects = { {
            license = ev.license,
            name    = ev.name,
            squadId = newest and newest.squadId or nil,
            left    = newest and newest.left or false,
        } },

        matchId = ev.matchId,
        summary = BR.IncidentBuild.chatSummaryOf(ev.count, ev.reason),

        evidence = evidence,
        atGameMs = ev.at,
    }
end

--- The one line shown in the queue for a strip case.
---
--- ITS OWN SENTENCE RATHER THAN `summaryOf`'s, because that one says "%d shots
--- refused" and no shot was refused. Nothing was fired: a weapon appeared in a
--- hand the gamemode never put it in, and it was taken back out. Reusing the
--- refusal wording would put a number of shots on a case that has none, which
--- is the sort of small lie a reviewer builds a wrong conclusion on.
---
--- BUILT FROM SERVER FACTS ONLY -- one integer -- like the other two. The
--- field's contract on the console side is "displayed and nothing else", and
--- the day somebody interpolates it a player-controlled name in here would be
--- the bug.
--- @param count integer
--- @return string
function BR.IncidentBuild.stripSummaryOf(count)
    local n = math.floor(tonumber(count) or 0)
    return ('%d unissued weapon%s taken out of the hand this match')
        :format(n, n == 1 and '' or 's')
end

--- Build the payload for a case opened by an unissued weapon in the hand.
---
--- THE THIRD PRODUCER, and the shape is deliberately the anticheat's rather than
--- a new one: `kind = 'anticheat'`, filed by the system, no reporter. The console
--- has two record types and must not grow a third for a finding that triages
--- exactly like the first.
---
--- SEVERITY IS READ, NOT RESTATED. `BR.ShotTier[NO_WEAPON]` is where this
--- project has already written down how bad "a weapon this gamemode does not
--- issue" is, and it says `high`. Spelling `'high'` here would be a second copy
--- of that judgement in a second file, which is how the two end up disagreeing
--- the day somebody re-grades the taxonomy.
---
--- ...AND THE BAR IS NOT READ, WHICH IS THE ONE PLACE THIS DELIBERATELY PARTS
--- COMPANY WITH THE REFUSAL PATH. `BR.ShotBarOverride[NO_WEAPON] = 2` exists
--- because a REFUSAL of that reason is a catch-all: it means the hash was in
--- neither our table nor the world's, so a weapon added by a future game build
--- or carried by an ambient NPC lands there, and asking for two costs nothing.
--- A STRIP IS NOT THAT. It is not a lookup failing, it is the ped observably
--- holding something the inventory did not put there, cross-checked against the
--- inventory the server itself holds. The bar for it is nevertheless two, and it
--- is server/strip.lua that holds it rather than this function: the owner set it
--- there on 2026-08-20 ("this should fire an incident on the 2nd offense"), and
--- the lowest count that can reach this function is therefore 2. This function
--- still files on whatever it is given -- deciding when to announce is the
--- detector's job in both anticheat paths, and duplicating the bar here would be
--- a second copy of it to disagree with.
---
--- NO `refusal` BLOCK. That field carries `count` and `windowMs` from the shot
--- validator and the console renders it as refused shots; a strip has neither
--- number and inventing them would dress up the finding. The timeline is where
--- the evidence for this one lives.
---
--- @param ev table  { license, name, matchId, count, at }
--- @param records table|nil  BR.Evidence.forLicense(ev.license)
--- @return table|nil payload, string|nil why-not
function BR.IncidentBuild.fromStrip(ev, records)
    if type(ev) ~= 'table' then return nil, 'no event' end

    -- NO LICENSE, NO INCIDENT -- the same rule as every other producer here. A
    -- case keyed to a server id is a case about whoever holds that slot next.
    if type(ev.license) ~= 'string' or ev.license == '' then
        return nil, 'no license'
    end

    local evidence = {}
    for _, r in ipairs(records or {}) do
        evidence[#evidence + 1] = evidenceRow(r)
    end
    local newest = evidence[#evidence]

    return {
        kind     = 'anticheat',
        category = 'system',
        state    = 'pending_review',
        severity = BR.ShotTier[BR.ShotRefusal.NO_WEAPON],

        subjectLicense = ev.license,
        subjectName    = ev.name,
        subjects = { {
            license = ev.license,
            name    = ev.name,
            squadId = newest and newest.squadId or nil,
            left    = newest and newest.left or false,
        } },

        -- NO reporter, absent rather than null -- the same absence
        -- `fromRefusal` relies on. br_ddb writes the missing keys as explicit
        -- nulls and the console reads `reporterLicense === null` as "the system
        -- filed this", which is exactly what happened.

        matchId = ev.matchId,
        summary = BR.IncidentBuild.stripSummaryOf(ev.count),

        evidence = evidence,
        atGameMs = ev.at,
    }
end

--- The one line shown in the queue for a refused-vehicle case.
---
--- ITS OWN SENTENCE, for the same reason `stripSummaryOf` is not `summaryOf`:
--- no shot was refused and no weapon left anybody's hand. A networked entity the
--- gamemode does not create appeared in a match, and the queue row should say
--- that and nothing more.
---
--- THE REASON IS THE TABLE'S OWN PROSE, not a word chosen here.
--- BR.Config.VehicleRefusal's values read "vehicle flies" and "vehicle has
--- built-in weapons", which are the two halves of the rule the owner wrote --
--- so an admin reading the queue reads the rule rather than a paraphrase of it,
--- and re-grading the rule re-grades this line by construction.
---
--- BUILT FROM SERVER FACTS ONLY -- one integer and one enum value -- like the
--- other three. The field's contract on the console side is "displayed and
--- nothing else", and the day somebody interpolates it, a player-controlled
--- name in here would be the bug. THE MODEL NAME IS DELIBERATELY NOT IN IT: the
--- server has a hash, and turning a hash back into a name means a lookup that
--- misses for exactly the models this list does not know about -- which would
--- put "unknown" on half the cases this ever files.
---
--- @param count integer
--- @param why string|nil  a BR.Config.VehicleRefusal value
--- @return string
--- THE WORD `spawned` USED TO BE IN THIS SENTENCE AND #211 TOOK IT OUT. While
--- the only detector was `entityCreating`, every case this built really was
--- about a vehicle somebody conjured, so the verb was true. It stopped being
--- true the moment a player could draw the same case by climbing into a
--- helicopter that was already parked at Fort Zancudo: nobody spawned that, and
--- a moderation record that says they did is a false statement in the one field
--- an admin reads before deciding.
---
--- THAT IS NOT A HYPOTHETICAL FAILURE MODE HERE. The corroboration note on this
--- exact case type described a refused VEHICLE as a refused WEAPON until
--- 2026-08-22, because a line was borrowed from the strip handler on the
--- reasoning that it was the closest true statement available. The owner found
--- it by reading the queue. A wrong verb is the same bug one field over.
---
--- SO THE SENTENCE NAMES THE FINDING AND NOT THE ROUTE. "N refused vehicles
--- this match" is true whether they were created or taken, and `why` -- "vehicle
--- flies", "vehicle has built-in weapons" -- is the half an admin triages on
--- anyway. The route is not omitted to save words; it is omitted because ONE
--- case can now hold both, and no single verb would be true of it.
function BR.IncidentBuild.vehicleSummaryOf(count, why)
    local n = math.floor(tonumber(count) or 0)
    return ('%d refused vehicle%s this match -- %s')
        :format(n, n == 1 and '' or 's', tostring(why))
end

--- Build the payload for a case opened by a vehicle the gamemode refuses.
---
--- THE FOURTH PRODUCER, and like the third it deliberately reuses the
--- anticheat's shape rather than inventing one: `kind = 'anticheat'`,
--- `category = 'system'`, no reporter. The console has two record types and must
--- not grow a third for a finding that triages exactly like the first two.
---
--- NO NEW TIMELINE KIND, AND THAT IS A DECISION RATHER THAN AN OMISSION. A strip
--- earns `weapon_strip` entries because the owner asked for the repeats to land
--- "in the incident timeline rather than creating a new incident each time", and
--- paying for that meant a new kind the console had to learn, a per-case cap, and
--- a share of the truncation budget the kills already compete for. The owner's
--- instruction here is shorter -- "simply file an incident" -- and the repeat
--- behaviour it asks for is what `priorFor` already does for every producer:
--- one case per player per match, everything after it a corroboration. So this
--- adds a row the console can already render, and adds nothing to the two writes
--- a case costs.
---
--- SEVERITY IS READ, NOT RESTATED, and it is read from the same place
--- `fromStrip` reads it: `BR.ShotTier[NO_WEAPON]`, whose sentence is "weapon is
--- not one this gamemode issues" and whose tier is `high` because -- in
--- server/strip.lua's words -- "the server never issued the means". A networked
--- vehicle is the same fact about a different kind of means: this gamemode
--- creates no networked entities at all, so there is no honest path to one.
--- Spelling `'high'` here would be a second copy of that judgement in a second
--- file, which is how the two end up disagreeing the day somebody re-grades the
--- taxonomy.
---
--- NO `refusal` BLOCK, for `fromStrip`'s reason: that field carries `count` and
--- `windowMs` from the shot validator and the console renders it as refused
--- shots. This has neither number.
---
--- @param ev table  { license, name, matchId, count, why, at }
--- @param records table|nil  BR.Evidence.forLicense(ev.license)
--- @return table|nil payload, string|nil why-not
function BR.IncidentBuild.fromVehicle(ev, records)
    if type(ev) ~= 'table' then return nil, 'no event' end

    -- NO LICENSE, NO INCIDENT -- the same rule as every other producer here. A
    -- case keyed to a server id is a case about whoever holds that slot next,
    -- and server ids are recycled within the minute.
    if type(ev.license) ~= 'string' or ev.license == '' then
        return nil, 'no license'
    end

    local evidence = {}
    for _, r in ipairs(records or {}) do
        evidence[#evidence + 1] = evidenceRow(r)
    end
    local newest = evidence[#evidence]

    return {
        kind     = 'anticheat',
        category = 'system',
        state    = 'pending_review',
        severity = BR.ShotTier[BR.ShotRefusal.NO_WEAPON],

        subjectLicense = ev.license,
        subjectName    = ev.name,
        subjects = { {
            license = ev.license,
            name    = ev.name,
            squadId = newest and newest.squadId or nil,
            left    = newest and newest.left or false,
        } },

        -- NO reporter, absent rather than null -- the same absence `fromRefusal`
        -- and `fromStrip` rely on. br_ddb writes the missing keys as explicit
        -- nulls and the console reads `reporterLicense === null` as "the system
        -- filed this", which is exactly what happened.

        matchId = ev.matchId,
        summary = BR.IncidentBuild.vehicleSummaryOf(ev.count, ev.why),

        evidence = evidence,
        atGameMs = ev.at,
    }
end

-- ---------------------------------------------------------------------------
-- The match timeline (#30)
-- ---------------------------------------------------------------------------
--
-- WHAT THIS IS. An incident today records the moment it was filed and almost
-- nothing around it, so an admin deciding a verdict sees the accusation without
-- the match it came out of. These functions build the two halves of the match
-- context that goes on the row: what was already true when the case was filed,
-- and the one fact that only becomes true later -- that the match ended.
--
-- === THE COST RULE, WHICH SHAPES EVERYTHING BELOW ===
--
-- A MATCH THAT PRODUCES NO INCIDENT MUST WRITE NOTHING. That is the owner's
-- constraint and it is also the rule the evidence buffer was already built on:
-- kills and chat are held in RAM, bounded, and thrown away at match end unless
-- an incident turned them into a record. The timeline rides that same buffer
-- rather than adding a second stream of writes.
--
-- So the write budget is:
--
--   * a match with no incident   ZERO writes. Nothing here runs.
--   * filing an incident         the PutItem that already happens, carrying
--                                more fields. NO extra write.
--   * that match ending          ONE UpdateItem per incident filed in it -- in
--                                practice one, since the filing rule is one
--                                case per player per match.
--
-- Cost is therefore proportional to INCIDENTS, not to matches, kills or players.
--
-- === ABSOLUTE TIMES, NOT OFFSETS ===
--
-- Every `at` here is a game-clock reading that br_ringmaster converts to
-- wall-clock ms on the way out, exactly as it already does for chat and kill
-- rows. The console renders "3m before the report" by subtracting `openedAt`
-- itself. Storing offsets instead would bake the zero point into the data and
-- make every entry unreadable the moment anything about the incident's own
-- timestamp were corrected.
--
-- === SERVER-AUTHORITATIVE, WITH ONE STATED EXCEPTION ===
--
-- Almost nothing on this timeline comes from a client. The kills are the
-- server's own attribution out of damage.lua, the licences are resolved from
-- identifiers server-side, and the two match timestamps come from the match
-- registry. This is a moderation record on an anti-cheat surface; a
-- client-supplied timestamp on it would be evidence a cheater writes about
-- themselves.
--
-- `weapon_strip` IS THE EXCEPTION AND IT IS ADMITTED HERE RATHER THAN LEFT FOR
-- SOMEBODY TO DISCOVER. What is in a ped's hand is a client-side fact and no
-- server native can read it, so the entry exists because a client said so. Two
-- things keep that from being a hole:
--
--   * the `at` IS STILL THE SERVER'S. br_core/server/evidence.lua stamps it
--     from GetGameTimer() when the report arrives and never accepts one over
--     the wire, so the offender cannot place their own events in time.
--   * the direction of the lie is harmless. `source` decides who the entry is
--     about, so the only record a client can write to is its OWN -- a false
--     report is a confession, and there is no way to spend it on somebody else.
--
-- The weapon hash on the entry IS the client's word. It is kept because it is
-- the one useful fact about the event and because a strip entry without it says
-- nothing an admin can act on; it is not corroborated by anything.
--
-- === ROOM FOR #34 WITHOUT A MIGRATION ===
--
-- `matchTimeline` is a heterogeneous list discriminated by `kind`, and the
-- console switches on that field. An artifact frame becomes an entry by adding
-- `{ at, kind = 'artifact', ... }` -- no new attribute, no reshaping of what is
-- already stored, and rows written before that day simply do not contain one.
-- That is the whole reason this is a list of tagged entries rather than a set of
-- parallel typed arrays.

--- How long after a match starts its end is still plausibly pending.
---
--- THIS IS WHAT STOPS AN ABSENT END READING AS "STILL RUNNING" FOREVER. The
--- match-end write is the one part of this that happens later, which means it is
--- the one part that can never happen: a crash, a restart, a lost DynamoDB
--- write. The console cannot distinguish those from a match still in progress by
--- looking at a missing field -- both are simply an absent `matchEndedAt`.
---
--- So the game states its own expectation at FILING time, when it is already
--- writing anyway and therefore at no extra cost, and the console compares it to
--- the clock:
---
---   matchEndedAt present          -> ended, at that time
---   absent, now <  matchEndsBy    -> STILL IN PROGRESS
---   absent, now >= matchEndsBy    -> end never reported
---
--- The third case is the one that matters and it is deliberately NOT the same
--- answer as the second. "This match is still going, more evidence may arrive"
--- and "this server never told us how this match finished" are different facts,
--- and an admin banning on partial evidence needs to tell them apart.
---
--- SIXTY MINUTES AGAINST A MATCH THAT RUNS ROUGHLY TWENTY (config/storm.lua's
--- phase table totals about that). Three times the expected length: long enough
--- that a slow round, a long warmup or a paused server is never mislabelled as a
--- crash, short enough that a real crash stops claiming to be live within the
--- hour rather than at the heat death of the queue.
local MATCH_ENDS_BY_MS = 60 * 60 * 1000

--- The most kill entries one incident's timeline may carry.
---
--- BOUNDED BECAUSE A DYNAMODB ITEM IS 400KB AND A PLAYER INFLUENCES THIS ONE.
--- The buffer's own promoted cap (250 rows) is the real limiter and this is the
--- backstop for a caller that promoted differently -- two caps that disagree
--- should fail towards the smaller, not towards a rejected write. A kill entry
--- marshals to roughly 200 bytes, so 250 of them is about 50KB against a ceiling
--- the evidence log is also spending from.
local MAX_TIMELINE_KILLS = 250

--- The `kind` a strip entry carries.
---
--- ONE SPELLING, NAMED ONCE, BECAUSE THE OTHER HALF OF IT IS IN JAVASCRIPT.
--- js-src/br_ddb/src/close.js discriminates on this exact string and DROPS a
--- kind it does not know -- deliberately, so a bug on this side cannot put an
--- unrenderable row on a moderation record. The failure that produces is the
--- worst kind this project has: the feature works end to end in every test on
--- each side, and the entries silently never arrive. tools/verify.sh compares
--- this literal against close.js's, which is the only place the two languages
--- can be made to agree mechanically.
local STRIP_KIND = 'weapon_strip'

--- The `kind` an entry carries when the match had been FORMED but not STARTED.
---
--- A DIFFERENT WORD BECAUSE IT IS A DIFFERENT FACT, and that is the whole reason
--- this constant exists rather than a `match_start` entry carrying the creation
--- time. `startedAt` is stamped on entering PLAYING and nothing else sets it
--- (br_core/server/match.lua), so a case filed during warmup has no start -- and
--- the tempting fix, writing the creation time into `matchStartedAt`, would make
--- `match_start` mean "the lobby opened" on some rows and "the match began" on
--- others with nothing on either row saying which. Two facts sharing one field is
--- how a moderation record starts lying quietly.
---
--- SO THE CONSOLE GETS ITS OWN WORD FOR IT. An entry of this kind says "this is
--- when the match this case belongs to was formed", which is the truth, and the
--- console can render "formed" rather than "started".
---
--- ONE SPELLING, NAMED ONCE, FOR THE SAME REASON STRIP_KIND IS: close.js
--- discriminates on this exact string and drops what it does not recognise.
--- tools/verify.sh reads every `*_KIND` constant in this file and checks close.js
--- names it, which is the only mechanical agreement two languages can have.
local MATCH_CREATED_KIND = 'match_created'

--- The most strip entries one incident's timeline may carry.
---
--- SIXTY, AND IT IS THE BUFFER'S PROMOTED CAP RESTATED AS A BACKSTOP -- exactly
--- what MAX_TIMELINE_KILLS is to `killMax`. The buffer is the real limiter; this
--- catches a caller that promoted differently, and two caps that disagree should
--- fail towards the smaller rather than towards a rejected write.
--- tools/test_shared.lua pins the two to the same number.
local MAX_TIMELINE_STRIPS = 60

--- The `kind` a refused chat line carries.
---
--- ONE SPELLING, NAMED ONCE, FOR THE REASON STRIP_KIND AND MATCH_CREATED_KIND
--- ARE: js-src/br_ddb/src/close.js discriminates on this exact string and drops
--- what it does not recognise, so a typo here fails no test on either side and
--- simply means the entries never arrive. tools/verify.sh reads every `*_KIND`
--- constant in this file and checks close.js names it.
local CHAT_KIND = 'chat_block'

--- The most refused-chat entries one incident's timeline may carry.
---
--- SIXTY, AND IT IS THE BUFFER'S PROMOTED CAP RESTATED AS A BACKSTOP -- exactly
--- what MAX_TIMELINE_STRIPS is to `refusedMax`. tools/test_shared.lua pins the
--- two to the same number.
local MAX_TIMELINE_CHAT = 60

--- The longest refused chat line that reaches a moderation record.
---
--- ═══ THIS IS THE FIRST PLAYER-AUTHORED PROSE ON AN INCIDENT'S TIMELINE ═══
---
--- js-src/br_ddb/src/incident.js says, of a player report's free-text note,
--- "NO FREE-TEXT NOTE, EVER, FROM THE GAME ... there is no player-supplied prose
--- anywhere in this row. That removes the injection surface rather than guarding
--- it." The second sentence was already not quite true -- `evidence[].chat[]
--- .text` has carried what players typed since the buffer shipped, capped at 512
--- there -- and the owner has now asked for the refused line specifically, on the
--- timeline. So the surface is real and is bounded here rather than argued away.
---
--- TWO HUNDRED, WHICH IS BR.ChatLimits.maxLength AND NOT A NEW NUMBER. The
--- server already refuses to deliver more than that, so a cap above it could
--- never be reached and a cap below it would store something the recipients did
--- not see -- the same "record what was delivered" rule the chat evidence log is
--- built on. Sixty entries of two hundred bytes is 12KB against DynamoDB's 400KB
--- item, alongside the kills and the evidence log already spending from it.
---
--- IT IS TEXT ON THE CONSOLE, NEVER MARKUP. Ringmaster renders timeline entries
--- as React text children -- there is no dangerouslySetInnerHTML anywhere on that
--- path -- so the escaping is structural rather than a sanitiser somebody has to
--- remember. Nothing on the game side should ever pre-escape it: that would
--- double-encode on the page and put `&amp;` in a moderation record.
local MAX_CHAT_TEXT = 200

--- Turn one buffered kill row into a timeline entry.
---
--- BOTH SIDES OF THE KILL, NOT JUST THE SUBJECT'S HALF. The buffer records a kill
--- against the killer AND the victim on purpose -- "reported for teaming" reads
--- very differently when the record shows the accused dying to the person they
--- are accused of helping -- and the timeline keeps that. The console decides
--- which way round to render it by comparing against the incident's own
--- `subjectLicense`, which it already has; the game does not pre-judge it.
---
--- THE LICENCES ARE THE PROFILE LINKS #30 ASKS FOR. `victimName` travels beside
--- `victimLicense` so the console can render a row whose profile has not loaded,
--- and so a case stays readable if the licence is later merged or renamed.
--- Everything this gamemode issues, indexed by every name it answers to.
---
--- THREE IDENTIFIER FORMS REACH THIS FILE, AND THAT IS THE WHOLE REASON THIS
--- TABLE EXISTS. `lastHitWeapon` is not one type:
---
---   * the gunshot path stores `data.weaponType`, which is a HASH -- see
---     damage.lua, where it is looked up as `WeaponByHash[NormHash(...)]`;
---   * the explosive path stores `f.item`, which is an ID string;
---   * and a row built by hand may carry the `WEAPON_*` NAME.
---
--- A lookup that assumed any one of those would answer "not a weapon we issue"
--- for the other two. That answer is not cosmetic here -- the console paints it
--- red and calls it high confidence of cheating -- so the cost of guessing the
--- form wrong is a false accusation against an innocent player. Accepting all
--- three is deliberate: a weapon we recognise by ANY of its identifiers is one
--- we issue, and there is no case where recognising it too easily does harm.
---
--- BUILT LAZILY AND CACHED ONLY ONCE POPULATED. br_lib's config and shared
--- files load in an order this file must not assume, and an empty result means
--- "the config is not up yet", never "there are no weapons". Caching the empty
--- one would make every kill for the rest of the process look conjured.
local known = nil
local function knownWeapons()
    if known then return known end

    local cfg = BR.Config
    if cfg == nil or cfg.WeaponById == nil or next(cfg.WeaponById) == nil then
        return nil
    end

    local byId, byHash, byName, env = {}, {}, {}, {}
    for id, w in pairs(cfg.WeaponById) do
        byId[id] = w
        if w.name then byName[w.name] = w end
        if w.hash and BR.NormHash then byHash[BR.NormHash(w.hash)] = w end
    end
    for _, e in ipairs(cfg.Environmental or {}) do
        env[e.id] = true
        if e.name then env[e.name] = true end
    end

    known = { byId = byId, byHash = byHash, byName = byName, env = env }
    return known
end

--- What killed them, and whether it is something this gamemode hands out.
---
--- THREE ANSWERS, NOT TWO, AND THE THIRD IS WHY THIS IS NOT A BOOLEAN.
---
---   * a weapon we issue           -> label, true
---   * a weapon we do not issue    -> no label, FALSE. This is the finding the
---                                    field exists to carry.
---   * a fall, a drowning, a storm -> no label, NIL
---
--- The third case is the one that matters. An environmental death is not a
--- weapon claim at all, and answering `false` would have the console accuse
--- somebody of cheating because they walked off a cliff. `nil` does not
--- travel: a Lua key set to nil simply does not appear in the row.
---
--- ABSENT MEANS "NO CLAIM", AND THE CONSOLE MUST READ IT THAT WAY. Every case
--- filed before this field existed carries no `weaponIssued`, and none of them
--- may light up red the day the console learns to look. Red requires an
--- explicit `false`, never the absence of a `true`.
---
--- SILENCE ON DOUBT, IN EVERY DIRECTION. No config, an unexpected type, no
--- weapon at all: all `nil`. The dangerous answer here is never silence, it is
--- a confident wrong one.
local function weaponFacts(w)
    if w == nil then return nil, nil end

    local K = knownWeapons()
    if K == nil then return nil, nil end

    if type(w) == 'number' then
        local hit = BR.NormHash and K.byHash[BR.NormHash(w)] or nil
        if hit then return hit.label, true end
        if BR.Config.EnvironmentalFor and BR.Config.EnvironmentalFor(w) then
            return nil, nil
        end
        return nil, false
    end

    if type(w) == 'string' then
        local hit = K.byId[w] or K.byName[w]
        if hit then return hit.label, true end
        if K.env[w] then return nil, nil end
        return nil, false
    end

    return nil, nil
end

local function killEntry(k)
    -- Resolved HERE, on the server, at the moment the case is built, rather
    -- than shipped to the console as an id for it to look up. The console has
    -- no weapon list and must not grow one: a second copy of this table in
    -- another repository is a copy that drifts, and the failure it produces is
    -- an innocent player shown in red. The gamemode is the authority on what
    -- the gamemode issues, so the gamemode answers.
    local weaponLabel, weaponIssued = weaponFacts(k.weapon)

    return {
        at   = k.at,
        kind = 'kill',

        killerLicense = k.killerLicense,
        killerName    = k.killer,
        victimLicense = k.victimLicense,
        victimName    = k.victim,

        weapon   = k.weapon,
        -- The display name, because `weapon` is an id: 'marksmanrifle' is not
        -- what an admin reads on a case, 'Marksman Rifle' is. Absent when the
        -- weapon is not one we issue -- we have no label for something we do
        -- not have, and inventing one would dress up the thing being flagged.
        weaponLabel  = weaponLabel,
        weaponIssued = weaponIssued,
        cause    = k.cause,
        -- STRICTLY BOOLEAN. `headshot` is set as `(cause == 'headshot') or nil`
        -- upstream, so it arrives as true or as absent, and this pins it to a
        -- real boolean before it crosses into JS. IN LUA `0` IS TRUTHY: a bare
        -- `if k.headshot` would call a `0` from any future producer a headshot.
        headshot = k.headshot == true,
    }
end

--- Every kill in `records`, oldest first, deduplicated, optionally windowed.
---
--- @param records table|nil  BR.Evidence.forLicense(license)
--- @param afterGameMs number|nil  keep only kills strictly later than this
--- @param cap integer|nil
--- @return table[] entries, integer offered, integer seen
local function killEntries(records, afterGameMs, cap)
    cap = cap or MAX_TIMELINE_KILLS

    local rows, seen = {}, 0
    -- Identity of a kill, for the reconnect case: `forLicense` returns one
    -- record per SESSION, and a row could in principle be noted against two of
    -- them. A timeline that lists the same elimination twice reads as two
    -- kills, which is a claim about a person that is simply false.
    local sawRow = {}

    for _, r in ipairs(records or {}) do
        seen = seen + (r.killsSeen or #(r.kills or {}))
        for _, k in ipairs(r.kills or {}) do
            local at = tonumber(k.at)
            -- `afterGameMs` NIL MEANS EVERYTHING, and that is not the same as 0.
            -- A game-clock reading of 0 is a legitimate instant, so this compares
            -- against nil explicitly rather than letting a falsy test decide.
            if at ~= nil and (afterGameMs == nil or at > afterGameMs) then
                local id = ('%d|%s|%s'):format(
                    at, tostring(k.killerLicense or k.killer),
                    tostring(k.victimLicense or k.victim))
                if not sawRow[id] then
                    sawRow[id] = true
                    rows[#rows + 1] = k
                end
            end
        end
    end

    table.sort(rows, function(a, b)
        if a.at == b.at then
            return tostring(a.victim or '') < tostring(b.victim or '')
        end
        return a.at < b.at
    end)

    local offered = #rows
    -- OVERFLOW DROPS THE OLDEST, matching the buffer and the outbox: when a
    -- record is full the rows describing what is happening now are worth more.
    -- The caller reports the drop rather than hiding it.
    while #rows > cap do table.remove(rows, 1) end

    local out = {}
    for _, k in ipairs(rows) do out[#out + 1] = killEntry(k) end
    return out, offered, seen
end

--- Every strip in `records`, oldest first, optionally windowed.
---
--- NO DEDUPLICATION, UNLIKE THE KILLS ABOVE, and the asymmetry is real rather
--- than an oversight. A kill is noted against BOTH participants, so `forLicense`
--- returning one record per session can offer the same elimination twice. A
--- strip is noted against one player's own record and nobody else's, so two
--- rows are two events -- and collapsing them would be the actual falsehood
--- here, because the thing this is evidence OF is repetition.
---
--- @param records table|nil  BR.Evidence.forLicense(license)
--- @param afterGameMs number|nil  keep only strips strictly later than this
--- @param cap integer|nil
--- @return table[] entries, integer offered, integer seen
local function stripEntries(records, afterGameMs, cap)
    cap = cap or MAX_TIMELINE_STRIPS

    local rows, seen = {}, 0
    for _, r in ipairs(records or {}) do
        seen = seen + (r.stripsSeen or #(r.strips or {}))
        for _, s in ipairs(r.strips or {}) do
            local at = tonumber(s.at)
            -- nil MEANS EVERYTHING, and that is not the same as 0 -- the same
            -- explicit comparison the kills make, for the same reason.
            if at ~= nil and (afterGameMs == nil or at > afterGameMs) then
                rows[#rows + 1] = s
            end
        end
    end

    table.sort(rows, function(a, b) return a.at < b.at end)

    local offered = #rows
    -- OVERFLOW DROPS THE OLDEST, matching the kills and the buffer -- and for
    -- strips the oldest are the least costly rows to lose, because the earliest
    -- ones already rode the incident's own PutItem and are durable.
    while #rows > cap do table.remove(rows, 1) end

    local out = {}
    for _, s in ipairs(rows) do
        out[#out + 1] = {
            at   = s.at,
            kind = STRIP_KIND,
            -- THE CLIENT'S WORD, AND THE ONLY FIELD ON THIS TIMELINE THAT IS.
            -- See the header. Kept because it is the whole content of the
            -- finding -- there is no label for a weapon the gamemode has never
            -- heard of, so the number the cheat actually used is what an admin
            -- gets, exactly as it is for a kill with an unissued weapon.
            weapon = tonumber(s.weapon),
        }
    end
    return out, offered, seen
end

--- Every refused chat line in `records`, oldest first, optionally windowed.
---
--- NO DEDUPLICATION, LIKE THE STRIPS AND UNLIKE THE KILLS. A refused line is
--- noted against one player's own record and nobody else's, so two rows are two
--- events -- and the same advert sent twice is the thing this is evidence OF.
---
--- @param records table|nil  BR.Evidence.forLicense(license)
--- @param afterGameMs number|nil  keep only lines strictly later than this
--- @param cap integer|nil
--- @return table[] entries, integer offered, integer seen
local function chatEntries(records, afterGameMs, cap)
    cap = cap or MAX_TIMELINE_CHAT

    local rows, seen = {}, 0
    for _, r in ipairs(records or {}) do
        seen = seen + (r.refusedSeen or #(r.refused or {}))
        for _, c in ipairs(r.refused or {}) do
            local at = tonumber(c.at)
            -- nil MEANS EVERYTHING, and that is not the same as 0 -- the same
            -- explicit comparison the kills and strips make.
            if at ~= nil and (afterGameMs == nil or at > afterGameMs) then
                rows[#rows + 1] = c
            end
        end
    end

    table.sort(rows, function(a, b) return a.at < b.at end)

    local offered = #rows
    -- OVERFLOW DROPS THE OLDEST, matching everything else here.
    while #rows > cap do table.remove(rows, 1) end

    local out = {}
    for _, c in ipairs(rows) do
        out[#out + 1] = {
            at   = c.at,
            kind = CHAT_KIND,
            -- WHAT THEY TRIED TO SAY, WHICH IS THE WHOLE POINT OF THE ENTRY
            -- (owner, 2026-08-29: "specifically save the chat content to the DDB
            -- entry and display on the timeline in the incident"). Clamped on a
            -- character boundary rather than with `sub`, so a line ending in an
            -- accent does not reach the console as a broken sequence -- see
            -- BR.ChatScreen.clamp and the note at MAX_CHAT_TEXT.
            text = BR.ChatScreen
                and BR.ChatScreen.clamp(c.text, MAX_CHAT_TEXT)
                or tostring(c.text or ''):sub(1, MAX_CHAT_TEXT),
            -- WHICH RULE REFUSED IT: `link` or `script`. A reviewer reading
            -- "Chat blocked -- <text>" needs to know whether the finding was the
            -- domain in it or the alphabet it is written in, and for a non-Latin
            -- line the text alone will not tell them.
            reason = c.reason,
            -- Global or squad. A rival server advertised to the whole lobby and
            -- one whispered to three squadmates are different facts.
            channel = c.channel,
        }
    end
    return out, offered, seen
end

--- Two already-sorted entry lists into one, oldest first.
---
--- A MERGE RATHER THAN A CONCATENATION-AND-SORT, because the order of this list
--- is not cosmetic. js-src/br_ddb/src/close.js takes the LAST n entries when a
--- close overflows -- so a list with every strip appended after every kill would
--- truncate by KIND rather than by age, and an offender who kept stripping would
--- push their own kills off the record. Chronological order makes the overflow
--- rule mean what it says.
---
--- STABLE, AND TIES GO TO THE FIRST LIST. Two entries at the same game
--- millisecond is ordinary -- the clock has 1ms resolution and a tick does
--- several things -- and an unstable answer would make the tests flap.
local function mergeByTime(a, b)
    local out, i, j = {}, 1, 1
    while i <= #a or j <= #b do
        local x, y = a[i], b[j]
        if y == nil or (x ~= nil and x.at <= y.at) then
            out[#out + 1] = x
            i = i + 1
        else
            out[#out + 1] = y
            j = j + 1
        end
    end
    return out
end

--- The match context known at FILING time. Costs no extra write.
---
--- Folded into the incident payload by the caller, so these fields ride the
--- PutItem that was already going to happen.
---
--- @param opts table {
---     matchId, matchStartedAt (game ms), matchCreatedAt (game ms), records }
--- @return table  fields to merge onto the incident payload
function BR.IncidentBuild.timelineOpen(opts)
    opts = opts or {}

    -- ═══ THE FIRST ENTRY IS THE ZERO POINT, AND WARMUP HAS ONE TOO ═══
    --
    -- A match that has STARTED anchors its timeline on the start, which is what
    -- this has always done. A match that has only been FORMED anchors on its
    -- creation, which is new and is the whole of #A: `startedAt` is stamped on
    -- entering PLAYING, so a weapon-strip case filed on the warmup pad used to
    -- fall through to the empty shape below and lose everything -- no zero
    -- point, no strips, and (because the caller keyed its close registration on
    -- the start) no match-end write for the rest of time. A strip during warmup
    -- is the EARLIEST cheat signal there is; it must not be the least recorded.
    --
    -- THE START WINS WHEN BOTH ARE KNOWN, and the creation time still rides the
    -- row as `matchCreatedAt`. One list, one beginning, and the console never
    -- has to decide which of two entries meant "the match began".
    local anchorAt, anchorKind = nil, nil
    if opts.matchStartedAt ~= nil then
        anchorAt, anchorKind = opts.matchStartedAt, 'match_start'
    elseif opts.matchCreatedAt ~= nil then
        anchorAt, anchorKind = opts.matchCreatedAt, MATCH_CREATED_KIND
    end

    -- NO MATCH, NO TIMELINE. An anticheat firing from the lobby or a `brrefuse`
    -- from the console carries no matchId and no times at all -- and inventing a
    -- timeline for it would put a match on the record that never happened. The
    -- console shows no match context at all in that case, which is the truth.
    if opts.matchId == nil or anchorAt == nil then
        return {
            matchStartedAt        = nil,
            matchCreatedAt        = nil,
            matchEndsByMs         = nil,
            matchTimeline         = {},
            matchTimelineComplete = true,
            matchKillsSeen        = 0,
            matchKillsWritten     = 0,
            matchStripsWritten    = 0,
            matchChatWritten      = 0,
        }
    end

    local entries = { { at = anchorAt, kind = anchorKind } }

    local kills, offered, seen = killEntries(opts.records, nil, MAX_TIMELINE_KILLS)
    local strips, stripsOffered, stripsSeen =
        stripEntries(opts.records, nil, MAX_TIMELINE_STRIPS)
    local chat, chatOffered, chatSeen =
        chatEntries(opts.records, nil, MAX_TIMELINE_CHAT)
    -- THREE LISTS THROUGH A TWO-WAY MERGE, FOLDED RATHER THAN CONCATENATED. The
    -- order of this list is not cosmetic: close.js takes the LAST n entries when
    -- a close overflows, so a list that appended one kind after another would
    -- truncate by KIND rather than by age. `mergeByTime` is stable, so nesting
    -- it keeps that property.
    for _, e in ipairs(mergeByTime(mergeByTime(kills, strips), chat)) do
        entries[#entries + 1] = e
    end

    return {
        -- STILL ABSENT UNTIL THE MATCH ACTUALLY STARTS. Nothing here invents one
        -- from the creation time; the close writes the real value when it comes.
        matchStartedAt = opts.matchStartedAt,
        matchCreatedAt = opts.matchCreatedAt,
        -- A DURATION HERE, AN ABSOLUTE TIME ON THE ROW. br_ringmaster owns the
        -- clock pair and turns this into wall-clock `matchEndsBy` on the way
        -- out, the same conversion every other timestamp in the payload gets.
        --
        -- ONLY WHEN THERE IS A START TO MEASURE IT FROM. The deadline means "this
        -- long after the match STARTED", and deriving it from the creation time
        -- instead would be a different promise wearing the same name -- badly, on
        -- a warmup that can be held open for a day (`brwarmup hold`), where
        -- created + 60 minutes would tell an admin the end was never reported
        -- about a match still sitting on the pad. The close carries the real one.
        matchEndsByMs  = opts.matchStartedAt ~= nil and MATCH_ENDS_BY_MS or nil,
        matchTimeline  = entries,
        -- COMPLETENESS IS ABOUT THE WHOLE LIST, NOT ABOUT THE KILLS. A timeline
        -- whose kills are all present and whose strips were truncated is not
        -- complete, and saying otherwise would tell an admin "this is everything
        -- they did" when it is not -- the one failure a moderation record must
        -- not produce.
        --
        -- THERE IS NO `matchStripsSeen` BESIDE `matchKillsSeen`, DELIBERATELY.
        -- The close write may only touch the attributes named in the game's IAM
        -- grant on `ringmaster-incidents` -- seven of them since #B, and every
        -- one had to be added to a policy before the code that writes it could
        -- run. A counter would be an eighth round of that, for a number the flag
        -- below already carries: something was dropped, which is what a reader
        -- needs to know.
        matchTimelineComplete = (#kills == offered) and (offered == seen)
            and (#strips == stripsOffered) and (stripsOffered == stripsSeen)
            and (#chat == chatOffered) and (chatOffered == chatSeen),
        matchKillsSeen = seen,
        -- What the close write must not double-count.
        matchKillsWritten = #kills,
        matchStripsWritten = #strips,
        matchChatWritten = #chat,
    }
end

--- The facts that only become true later: the match ended, and (for a case filed
--- before it started) when it started.
---
--- WHY A START TRAVELS ON A CLOSE AT ALL. A case filed during WARMUP is filed
--- before `startedAt` exists, so its row is written with no start and no
--- deadline. Both become known while the case is already durable, and this is the
--- write that was going to happen anyway -- so they ride it rather than costing
--- one of their own. For a case filed during PLAYING the row already carries both
--- and this restates them, which is a no-op rather than a correction.
---
--- ABSENT WHEN THE MATCH NEVER STARTED, and that absence has to survive. A match
--- that dissolves on the pad ends without ever having begun; `matchStartedAt`
--- stays nil here, the close omits it entirely, and the row keeps saying the
--- honest thing rather than being overwritten with a null or with the end time.
---
--- @param opts table {
---     matchEndedAt (game ms), matchStartedAt (game ms|nil), filedAtGameMs,
---     records, priorKills, priorStrips, complete }
--- @return table  the close payload
function BR.IncidentBuild.timelineClose(opts)
    opts = opts or {}

    local priorKills = tonumber(opts.priorKills) or 0
    local budget = MAX_TIMELINE_KILLS - priorKills
    if budget < 0 then budget = 0 end

    local priorStrips = tonumber(opts.priorStrips) or 0
    local stripBudget = MAX_TIMELINE_STRIPS - priorStrips
    if stripBudget < 0 then stripBudget = 0 end

    local priorChat = tonumber(opts.priorChat) or 0
    local chatBudget = MAX_TIMELINE_CHAT - priorChat
    if chatBudget < 0 then chatBudget = 0 end

    -- STRICTLY AFTER THE FILING INSTANT. The kills up to that moment are already
    -- on the row, written by timelineOpen; re-sending them would show an admin
    -- the same elimination twice.
    --
    -- THE STRIP THAT OPENED THE CASE IS EXCLUDED BY THIS SAME COMPARISON and
    -- that is not a coincidence to rely on quietly: the first strip is recorded
    -- in the buffer and THEN the payload is built, so its `at` equals the filing
    -- instant exactly, and `> filedAtGameMs` drops it. It is already on the row.
    local kills, offered, seen =
        killEntries(opts.records, opts.filedAtGameMs, budget)
    local strips, stripsOffered, stripsSeen =
        stripEntries(opts.records, opts.filedAtGameMs, stripBudget)
    -- THE LINE THAT OPENED THE CASE IS EXCLUDED BY THE SAME COMPARISON that
    -- excludes the strip that opened one: server/chat.lua notes the refusal and
    -- THEN announces it, so its `at` equals the filing instant exactly and
    -- `> filedAtGameMs` drops it. It is already on the row.
    local chat, chatOffered, chatSeen =
        chatEntries(opts.records, opts.filedAtGameMs, chatBudget)

    local entries = {}
    for _, e in ipairs(mergeByTime(mergeByTime(kills, strips), chat)) do
        entries[#entries + 1] = e
    end
    entries[#entries + 1] = { at = opts.matchEndedAt, kind = 'match_end' }

    -- COMPLETE MEANS COMPLETE END TO END. The filing may already have truncated,
    -- in which case nothing this write does can make the timeline whole again --
    -- so the flag carries that forward rather than reporting only on its own
    -- half. `seen` counts every kill the buffer was ever offered for this
    -- player, including ones its caps dropped, which is what makes the
    -- comparison honest.
    local wrote = priorKills + #kills
    local stripsWrote = priorStrips + #strips
    local chatWrote = priorChat + #chat
    local complete =
        (opts.complete ~= false)
        and (#kills == offered)
        and (seen <= wrote)
        and (#strips == stripsOffered)
        and (stripsSeen <= stripsWrote)
        and (#chat == chatOffered)
        and (chatSeen <= chatWrote)

    return {
        matchEndedAt          = opts.matchEndedAt,
        matchStartedAt        = opts.matchStartedAt,
        -- THE SAME DURATION-TO-DEADLINE HANDOFF THE FILING USES, and it is here
        -- for exactly one reason: a case filed during warmup has no deadline on
        -- its row, so an end that later fails to arrive would leave it with
        -- neither an end nor an expectation of one. Paired with the start above,
        -- so the two are never written from different clocks.
        matchEndsByMs         = opts.matchStartedAt ~= nil and MATCH_ENDS_BY_MS or nil,
        matchTimeline         = entries,
        matchTimelineComplete = complete,
        matchKillsSeen        = seen,
    }
end

BR.IncidentBuild.TIMELINE_LIMITS = {
    MAX_TIMELINE_KILLS  = MAX_TIMELINE_KILLS,
    MAX_TIMELINE_STRIPS = MAX_TIMELINE_STRIPS,
    MAX_TIMELINE_CHAT   = MAX_TIMELINE_CHAT,
    MAX_CHAT_TEXT       = MAX_CHAT_TEXT,
    MATCH_ENDS_BY_MS    = MATCH_ENDS_BY_MS,
}

--- The `kind` a strip entry carries, for the tests and for verify.sh.
BR.IncidentBuild.STRIP_KIND = STRIP_KIND

--- The `kind` a formed-but-not-started match carries, for the same two readers.
BR.IncidentBuild.MATCH_CREATED_KIND = MATCH_CREATED_KIND

--- The `kind` a refused chat line carries, for the same two readers.
BR.IncidentBuild.CHAT_KIND = CHAT_KIND
