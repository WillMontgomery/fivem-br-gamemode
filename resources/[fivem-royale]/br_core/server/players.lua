--[[
    The in-game player list, and the reports filed from it.

    THE SERVER RESOLVES THE BUCKET AND SENDS THE ANSWER. It never sends a
    matchId for the client to filter on -- `matchId` is marked NEVER PUBLIC in
    roster.lua's PUBLIC_FIELDS, and shipping it so the client can do the
    filtering would leak the exact field that projection exists to withhold.
    What goes out is a list of people, already correct.

    THIS IS AN INFORMATION CHANGE, AND THAT WAS A DELIBERATE CALL (owner,
    2026-08-12). Before this, a player knew how many were alive but not who.
    Names of the people you are fighting is a real thing to hand over, and it
    was weighed against the report flow needing somewhere to live. What is NOT
    handed over stays exactly as it was: no positions, no health, no inventory,
    no matchId.

    NO LIST IN THE LOBBY (owner). Tilde does nothing there. A lobby player has
    nobody to report and no bucket to be in.

    PLAYERS WHO LEFT STILL APPEAR, marked. Somebody who ragequits after cheating
    is precisely the person most worth reporting, and a list that drops them the
    moment they disconnect makes that impossible. The roster keeps the entry
    until the match is destroyed; this renders it rather than filtering it.
]]

BR = BR or {}
BR.Players = BR.Players or {}

--- license -> reports submitted this match, and which match that was.
---
--- KEYED ON LICENSE, NOT SOURCE. A server id is recycled within the minute, so
--- a limit keyed on one would be handed to whoever connects into that slot next
--- -- either giving somebody a fresh allowance by reconnecting, or charging a
--- stranger for reports they did not file.
---
--- `named` IS THE SAME DECISION APPLIED TO THE SUBJECT (#143). It is the set of
--- target LICENSES this reporter has already reported this match, and it is
--- what makes "one report per (reporter, target, match)" true rather than
--- merely intended. Keying it on the target's server id instead would break in
--- both directions at once: a cheater who reconnects gets a fresh accusation
--- slot from everybody who already reported them, and the next player to land
--- in that slot inherits an accusation they were never the subject of.
local usage = {}

--- Reports counted for a license in a match, resetting when the match changes.
local function usageFor(license, matchId)
    local u = usage[license]
    if not u or u.matchId ~= matchId then
        u = { matchId = matchId, count = 0, named = {} }
        usage[license] = u
    end
    return u
end

--- What has been reported ABOUT a player this match, from anybody.
---
--- [matchId] = { [targetLicense] = { reports = n, seq = k } }
---
--- SEPARATE FROM `usage` BECAUSE IT ASKS THE OPPOSITE QUESTION. `usage` is
--- about the person filing; this is about the person filed against, and it is
--- what the corroboration path needs: how many people have now said this, and
--- which numbered event this is on the case.
---
--- `seq` STARTS AT 2 AND ONLY MOVES WHEN A CORROBORATION IS ACTUALLY EMITTED.
--- br_ringmaster's contract for the field is written on the event handler
--- itself -- "Monotonic per player per match, starting at 2 -- report 1 is the
--- case" -- and it exists so the console can tell 1, 2, 4 with a gap in it (a
--- corroboration the outbox dropped and told nobody about) from a match where
--- nothing more happened. Counting reports instead of emissions would break
--- that the first time a case was opened by the ANTICHEAT rather than by a
--- report: the first report would then corroborate carrying seq = 1, which is
--- the number the case itself already has.
local subjects = {}

--- The running record for one subject in one match.
local function subjectIn(matchId, license)
    local m = subjects[matchId]
    if not m then
        m = {}
        subjects[matchId] = m
    end
    local s = m[license]
    if not s then
        s = { reports = 0, seq = 1 }
        m[license] = s
    end
    return s
end

--- Everyone in the same bucket as this player.
---
--- @param src integer
--- @return table|nil rows, integer|nil matchId
function BR.Players.listFor(src)
    local me = BR.Roster.get(src)
    if not me or not me.matchId then return nil, nil end

    local rows = {}
    BR.Roster.each(
        function(e) return e.matchId == me.matchId end,
        function(otherSrc, e)
            rows[#rows + 1] = {
                src     = otherSrc,
                name    = e.name,
                -- Already public: PUBLIC_FIELDS carries state and squadId, so
                -- this widens nothing. It is what lets the panel grey out your
                -- own squad and mark who has gone.
                state   = e.state,
                squadId = e.squadId,
                left    = e.state == BR.PlayerState.LEFT,
                you     = otherSrc == src,
            }
        end)

    -- DETERMINISTIC ORDER. `each` walks a hash, and a list that reshuffles
    -- between two-second refreshes is one where a player clicks the wrong
    -- checkbox. Sorted by name, with the departed last -- they are the least
    -- likely to be the subject and the most likely to be scrolled past.
    table.sort(rows, function(a, b)
        if a.left ~= b.left then return not a.left end
        return (a.name or '') < (b.name or '')
    end)

    return rows, me.matchId
end

--- Send one player their bucket, plus the report rules.
--- @param src integer
function BR.Players.push(src)
    local rows, matchId = BR.Players.listFor(src)
    if not rows then
        -- Explicitly empty rather than silent: the panel has to be able to tell
        -- "not in a match" from "the request went nowhere".
        TriggerClientEvent(BR.Net.PLAYERS_LIST, src, { inMatch = false, players = {} })
        return
    end

    TriggerClientEvent(BR.Net.PLAYERS_LIST, src, {
        inMatch    = true,
        players    = rows,
        -- THE RULES TRAVEL WITH THE DATA. The panel cannot invent its own limit
        -- and must not hardcode one that drifts from the server's.
        categories = BR.Config.Report.categories,
        defaultCategory = BR.Config.defaultReportCategory(),
        maxTargets = BR.Config.Report.maxTargets,

        -- `remaining` IS GONE, AND THE FIELD WENT WITH THE TEXT (#142). It
        -- existed for one line on the panel -- "2 left" -- and the owner's
        -- instruction was that the panel stops saying it: "We don't need to
        -- tell a player how many people they can report, or how many reports
        -- are left."
        --
        -- Once nothing renders it, a field the server computes on every
        -- two-second refresh and the client never reads is not a spare part, it
        -- is the thirteenth confirmed instance of this project's favourite bug.
        -- The LIMIT is untouched and is still checked below on every submit;
        -- what changed is that a player meets it as a reason for a refusal
        -- instead of as a running total.
    })
end

RegisterNetEvent(BR.Net.PLAYERS_ASK)
AddEventHandler(BR.Net.PLAYERS_ASK, function()
    BR.Players.push(source)
end)

--- Tell the reporter what happened.
local function answer(src, ok, filed, refused)
    TriggerClientEvent(BR.Net.REPORT_RESULT, src, {
        ok = ok, filed = filed or 0, refused = refused,
    })
end

--[[
    A submitted report.

    EVERYTHING THE CLIENT SENT IS TREATED AS A CLAIM. It names server ids and a
    category string; the server resolves both. A modified client can ask to
    report anybody for anything and gets exactly the same treatment as an honest
    one -- refused for the same reasons, counted against the same limit.

    THE ANSWER WAITS FOR THE WRITE. The promise made to the player is that an
    admin will review it, and that is only true once a row exists. Reporting
    success on receipt would be a lie in exactly the case that matters: the one
    where the write failed.

    ONE REPORT PER (REPORTER, TARGET, MATCH), and it is the whole of #143's
    second half (owner, 2026-08-16: "Reporting the same player twice is possible
    in the same match by the same reporter - this should not be possible, and
    any future reports during the same match from other reporters to the same
    target should be corroborated per our existing corroboration code").

    Those are two different rules about the same second report, and which one
    applies depends entirely on WHO is filing it:

      the SAME reporter    refused, naming the player they already reported.
                           A second accusation from the person who made the
                           first is not new information -- it is the same
                           opinion arriving twice, and letting it through is
                           how one annoyed player turns into three rows an
                           admin has to read before finding out they are the
                           same complaint.

      a DIFFERENT reporter corroborated onto the case that already exists.
                           This one IS new information and is the single most
                           valuable thing this feature produces: two strangers
                           independently naming the same player. It says so on
                           the case they already have rather than opening a
                           second, for the reason server/incident.lua gives at
                           length -- a queue is a shrinking worklist and one
                           persistent offender must not be able to bury it.

    THE WHOLE SUBMISSION IS REFUSED WHEN IT NAMES SOMEBODY ALREADY REPORTED,
    rather than quietly dropping that one target and filing the rest. Two
    reasons, and the second is the one that decided it:

      * a partial file has no honest answer. "3 reports sent" is true and hides
        the refusal; "1 was refused" alongside a success toast is two answers to
        one question, and the panel has one toast.
      * the panel keeps the selection on a refusal, on purpose (see
        PlayerList.tsx) -- so an explicit "you have already reported X" leaves
        the player one untick away from sending the rest, and they learn the
        rule. A silent drop teaches nothing and looks like the report failing.

    IT DOES NOT COST THEM A SUBMISSION. `u.count` is deliberately not
    incremented on this path, unlike the rate-limit refusal below: naming
    somebody twice is a mistake about who you have already reported, not an
    attempt to spend an allowance, and charging for it would punish the honest
    reading of the rule.
]]
RegisterNetEvent(BR.Net.REPORT_SUBMIT)
AddEventHandler(BR.Net.REPORT_SUBMIT, function(data)
    local src = source
    if type(data) ~= 'table' then return end

    local me = BR.Roster.get(src)
    if not me or not me.matchId then
        answer(src, false, 0, 'You can only report from inside a match.')
        return
    end

    local byKind = BR.Identity and BR.Identity.ofPlayer(src)
    local reporter = byKind and BR.Identity.qualified('license', byKind.license)
    if not reporter then
        -- Without a license the report cannot be attributed, and an
        -- unattributable accusation is worth less than none: the console's
        -- "who reports everybody" signal depends on knowing who filed it.
        answer(src, false, 0, 'Your account could not be identified.')
        return
    end

    local u = usageFor(reporter, me.matchId)
    if u.count >= BR.Config.Report.maxPerMatch then
        -- COUNTED EVEN THOUGH IT IS REFUSED. Somebody hammering the limit is
        -- itself a signal, and discarding the attempt discards the signal.
        u.count = u.count + 1
        answer(src, false, 0, ('You have used all %d reports for this match.')
            :format(BR.Config.Report.maxPerMatch))
        return
    end

    local targets = type(data.targets) == 'table' and data.targets or {}
    if #targets == 0 then
        answer(src, false, 0, 'No players were selected.')
        return
    end
    if #targets > BR.Config.Report.maxTargets then
        answer(src, false, 0, ('You can report at most %d players at once.')
            :format(BR.Config.Report.maxTargets))
        return
    end

    -- RESOLVED IN FULL BEFORE ANYTHING IS FILED, and the two passes are what
    -- make the all-or-nothing refusal above possible at all. Deciding per
    -- target as we go would mean the first two were already written by the time
    -- the third turned out to be a repeat, and an incident cannot be recalled.
    local resolved, seen, repeats = {}, {}, {}

    for _, t in ipairs(targets) do
        local tsrc = tonumber(type(t) == 'table' and t.src or nil)
        local category = tostring(type(t) == 'table' and t.category or '')

        if not BR.Config.isReportCategory(category) then
            category = BR.Config.defaultReportCategory()
        end

        -- One report per target per submission, whatever the client sent.
        if tsrc and not seen[tsrc] and tsrc ~= src then
            seen[tsrc] = true

            local te = BR.Roster.get(tsrc)
            -- SAME BUCKET ONLY. A client naming a server id from another match
            -- is either broken or probing; either way the answer is the same.
            if te and te.matchId == me.matchId then
                local tby = BR.Identity and BR.Identity.ofPlayer(tsrc)
                local tlicense = tby and BR.Identity.qualified('license', tby.license)
                    or te.license

                if tlicense then
                    if u.named[tlicense] then
                        repeats[#repeats + 1] = te.name or 'that player'
                    else
                        resolved[#resolved + 1] = {
                            license  = tlicense,
                            name     = te.name,
                            category = category,
                        }
                    end
                end
            end
        end
    end

    -- ALREADY REPORTED BY THIS PLAYER, THIS MATCH. Named, because "that report
    -- could not be sent" over a five-name selection is a refusal the player
    -- cannot act on -- they have to untick the right one, and only the server
    -- knows which it is.
    if #repeats > 0 then
        answer(src, false, 0, (#repeats == 1
            and ('You have already reported %s in this match.'):format(repeats[1])
            or ('You have already reported %d of those players in this match: %s.')
                :format(#repeats, table.concat(repeats, ', '))))
        return
    end

    -- Reports that went through, whether they opened a case or appended to one.
    -- DELIBERATELY NOT CALLED `filed`: a corroboration files nothing, and the
    -- distinction is one the reporter must never be able to see.
    local sentCount = 0

    for _, t in ipairs(resolved) do
        -- IS THERE ALREADY A CASE ABOUT THIS PLAYER, THIS MATCH? This is the
        -- exact question server/incident.lua asks on the anticheat path, asked
        -- through the same function against the same table -- deliberately, and
        -- not because it saves five lines. BR.Incident is fed by
        -- `br:incident:filed`, which is the acknowledgement br_ringmaster sends
        -- back once a row is actually durable, so it answers for cases opened
        -- by EITHER source. A report about somebody the anticheat has already
        -- flagged corroborates that case, which is the single most useful
        -- pairing this whole system produces.
        --
        -- It is also why a second mechanism would have been actively wrong
        -- rather than merely redundant: a report-only dedupe would have opened
        -- a second case beside the anticheat's, about the same player, in the
        -- same match, and left an admin to notice they were the same person.
        --
        -- THE RACE IS REAL AND IS ACCEPTED, exactly as it is on the anticheat
        -- path. `remember` runs on the DynamoDB acknowledgement, which is
        -- seconds away, so two reporters submitting inside that window both see
        -- an empty `prior` and both file. The rule that #143 actually demands --
        -- one report per reporter per target -- is decided synchronously above
        -- and cannot race; this half is a de-duplication of CASES and is
        -- allowed to be best-effort, because the console can merge two rows and
        -- cannot un-file one that was never written.
        local prior = BR.Incident and BR.Incident.priorFor(me.matchId, t.license) or {}
        local s = subjectIn(me.matchId, t.license)
        local accepted = true
        s.reports = s.reports + 1

        if #prior > 0 then
            s.seq = s.seq + 1
            TriggerEvent('br:ringmaster:corroborate', {
                incidentId = prior[#prior],
                matchId    = me.matchId,
                license    = t.license,
                name       = t.name,
                seq        = s.seq,
                -- HOW MANY REPORTS THIS PLAYER HAS NOW DRAWN, which is the
                -- number an admin actually wants: the anticheat's `count` is
                -- refused shots, and the analogue for a report is people.
                count      = s.reports,
                -- The category, matching the `category` field on the incident
                -- this is being appended to, so the two read in the same
                -- vocabulary. No reporter name rides along: the corroboration
                -- envelope br_ringmaster forwards has a fixed field set, and
                -- widening the outbox contract for a channel that is allowed to
                -- drop messages is not worth it.
                reason     = t.category,
                -- NO SEVERITY, for the reason BR.IncidentBuild.fromReport
                -- gives: a human's category is not a measurement, and grading
                -- it here would invent confidence that does not exist.
            })

            print(('[br_core] report: %s corroborates case %s about %s (report %d, seq %d)')
                :format(tostring(me.name), tostring(prior[#prior]),
                        tostring(t.name), s.reports, s.seq))
        else
            local payload, why = BR.IncidentBuild.fromReport({
                license         = t.license,
                name            = t.name,
                reporterLicense = reporter,
                reporterName    = me.name,
                category        = t.category,
                matchId         = me.matchId,
                at              = GetGameTimer(),
            }, BR.Evidence and BR.Evidence.forLicense(t.license) or {})

            if payload then
                -- Empty here by construction -- a non-empty `prior` took the
                -- branch above -- and set anyway, because the console reads the
                -- field and the anticheat's own filing path sets it for exactly
                -- the same reason.
                payload.priorIncidentIds = prior
                TriggerEvent('br:ringmaster:incident', payload)
            else
                -- LOUD, and the count is rolled back: `fromReport` refuses a
                -- self-report and a licenseless party, and a subject whose
                -- report was never built has not been reported by anybody.
                print(('^3[br_core] report not filed for %s: %s^7')
                    :format(tostring(t.name), tostring(why)))
                s.reports = s.reports - 1
                accepted = false
            end
        end

        -- COUNTED THE MOMENT IT IS ACCEPTED, whether it opened a case or
        -- appended to one. The player must not be able to tell those apart:
        -- "your report was added to an existing case" would leak that the
        -- person they just named is already under review, which is precisely
        -- the thing an offender's friend would go looking for.
        if accepted then
            u.named[t.license] = true
            sentCount = sentCount + 1
        end
    end

    if sentCount == 0 then
        answer(src, false, 0, 'None of those players could be reported.')
        return
    end

    u.count = u.count + 1
    answer(src, true, sentCount, nil)

    print(('[br_core] report: %s sent %d report(s) in match %s (%d/%d submissions used)')
        :format(me.name, sentCount, tostring(me.matchId),
                u.count, BR.Config.Report.maxPerMatch))

    -- NO PUSH BACK TO THE PANEL. There used to be one, because the panel showed
    -- the remaining allowance and would otherwise have gone on offering a
    -- report that was no longer there. Nothing on the panel reads a count any
    -- more (#142) and the client closes the panel on a success, so a refresh
    -- here would be a list rendered into a component that has already
    -- unmounted. The two-second refresh loop covers a panel left open.
end)

--- Reports do not survive the match they were filed in.
---
--- WHICH IS THE POINT OF THE RULE, not a tidy-up. "One report per target per
--- match" has to mean per MATCH or it becomes a permanent ban on ever reporting
--- somebody twice -- and a player who cheats in three consecutive rounds is
--- three separate things worth telling an admin about. Dropping both tables
--- here is what makes the next round a clean sheet for everybody in it.
---
--- The same hook the evidence buffer and the incident map use, and for the same
--- reason server/incident.lua gives: `destroy` is the only way a match leaves
--- the registry, whereas `br:match:results` returns early when nobody scored.
AddEventHandler('br:match:destroyed', function(ev)
    if type(ev) ~= 'table' then return end
    for license, u in pairs(usage) do
        if u.matchId == ev.matchId then usage[license] = nil end
    end
    subjects[ev.matchId] = nil
end)
