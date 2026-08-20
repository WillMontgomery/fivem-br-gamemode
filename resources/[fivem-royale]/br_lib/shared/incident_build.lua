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
-- === SERVER-AUTHORITATIVE ===
--
-- Nothing on this timeline comes from a client. The kills are the server's own
-- attribution out of damage.lua, the licences are resolved from identifiers
-- server-side, and the two match timestamps come from the match registry. This
-- is a moderation record on an anti-cheat surface; a client-supplied timestamp
-- on it would be evidence a cheater writes about themselves.
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

--- The match context known at FILING time. Costs no extra write.
---
--- Folded into the incident payload by the caller, so these fields ride the
--- PutItem that was already going to happen.
---
--- @param opts table {
---     matchId, matchStartedAt (game ms), records }
--- @return table  fields to merge onto the incident payload
function BR.IncidentBuild.timelineOpen(opts)
    opts = opts or {}

    -- NO MATCH, NO TIMELINE. An anticheat firing from the lobby or a `brrefuse`
    -- from the console carries no matchId and no start -- and inventing a
    -- timeline for it would put a match on the record that never happened. The
    -- console shows no match context at all in that case, which is the truth.
    if opts.matchId == nil or opts.matchStartedAt == nil then
        return {
            matchStartedAt        = nil,
            matchEndsByMs         = nil,
            matchTimeline         = {},
            matchTimelineComplete = true,
            matchKillsSeen        = 0,
            matchKillsWritten     = 0,
        }
    end

    local entries = { { at = opts.matchStartedAt, kind = 'match_start' } }

    local kills, offered, seen = killEntries(opts.records, nil, MAX_TIMELINE_KILLS)
    for _, e in ipairs(kills) do entries[#entries + 1] = e end

    return {
        matchStartedAt = opts.matchStartedAt,
        -- A DURATION HERE, AN ABSOLUTE TIME ON THE ROW. br_ringmaster owns the
        -- clock pair and turns this into wall-clock `matchEndsBy` on the way
        -- out, the same conversion every other timestamp in the payload gets.
        matchEndsByMs  = MATCH_ENDS_BY_MS,
        matchTimeline  = entries,
        matchTimelineComplete = (#kills == offered) and (offered == seen),
        matchKillsSeen = seen,
        -- What the close write must not double-count.
        matchKillsWritten = #kills,
    }
end

--- The one fact that only becomes true later: the match ended.
---
--- @param opts table {
---     matchEndedAt (game ms), filedAtGameMs, records, priorKills, complete }
--- @return table  the close payload
function BR.IncidentBuild.timelineClose(opts)
    opts = opts or {}

    local priorKills = tonumber(opts.priorKills) or 0
    local budget = MAX_TIMELINE_KILLS - priorKills
    if budget < 0 then budget = 0 end

    -- STRICTLY AFTER THE FILING INSTANT. The kills up to that moment are already
    -- on the row, written by timelineOpen; re-sending them would show an admin
    -- the same elimination twice.
    local kills, offered, seen =
        killEntries(opts.records, opts.filedAtGameMs, budget)

    local entries = {}
    for _, e in ipairs(kills) do entries[#entries + 1] = e end
    entries[#entries + 1] = { at = opts.matchEndedAt, kind = 'match_end' }

    -- COMPLETE MEANS COMPLETE END TO END. The filing may already have truncated,
    -- in which case nothing this write does can make the timeline whole again --
    -- so the flag carries that forward rather than reporting only on its own
    -- half. `seen` counts every kill the buffer was ever offered for this
    -- player, including ones its caps dropped, which is what makes the
    -- comparison honest.
    local wrote = priorKills + #kills
    local complete =
        (opts.complete ~= false)
        and (#kills == offered)
        and (seen <= wrote)

    return {
        matchEndedAt          = opts.matchEndedAt,
        matchTimeline         = entries,
        matchTimelineComplete = complete,
        matchKillsSeen        = seen,
    }
end

BR.IncidentBuild.TIMELINE_LIMITS = {
    MAX_TIMELINE_KILLS = MAX_TIMELINE_KILLS,
    MATCH_ENDS_BY_MS   = MATCH_ENDS_BY_MS,
}
