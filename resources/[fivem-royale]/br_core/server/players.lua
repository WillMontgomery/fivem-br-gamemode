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

    PLAYERS WHO LEFT STILL APPEAR, marked, AND ARE STILL REPORTABLE (#172).
    Somebody who ragequits after cheating is precisely the person most worth
    reporting, and a list that drops them the moment they disconnect closes the
    report window at exactly the wrong moment.

    THE PARAGRAPH THAT USED TO BE HERE SAID THIS WAS ALREADY TRUE AND IT WAS
    NOT, which is worth recording rather than quietly overwriting. It read "the
    roster keeps the entry until the match is destroyed; this renders it rather
    than filtering it" -- and the roster does keep it, in `departed`, but
    `BR.Roster.each` walks the LIVE roster and `BR.Roster.remove` has already
    taken the entry out of it. So `left` below had no reachable writer: the flag
    was computed, sent, carried through br_ui's allowlist and rendered by
    PlayerList.tsx, and was false on every row that ever existed. A comment
    describing an intention as an implementation is how this project's most
    common bug survives review, so the merge is now an explicit second source
    below and the flag is written from which source a row came from.
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

--- Reporters whose case has been sent to be written but not yet acknowledged.
---
--- [matchId] = { [targetLicense] = { reporterLicense, ... } }
---
--- WHY THIS EXISTS AT ALL: br_ddb mints the incident id, so at the moment a
--- report is accepted there is nothing to pay AGAINST. The id comes back
--- seconds later on `br:incident:filed`, which carries the match and the
--- subject and -- correctly -- says nothing about who reported. This is the
--- one table that can join the two.
---
--- A QUEUE PER SUBJECT, NOT A SINGLE SLOT. Two reporters submitting inside the
--- acknowledgement window both see an empty `prior` and both open a case; that
--- race is documented below and accepted. A single slot would drop one of them,
--- and the person dropped would be the one who reported first.
---
--- FIFO, and the pairing is therefore approximate: if two acknowledgements
--- cross, reporter A may be recorded against reporter B's row. Both rows are
--- about the same player in the same match and both resolve together, so the
--- reward lands either way -- and the alternative, threading a token through
--- br_ringmaster and br_ddb purely to make an already-duplicated case tidy, is
--- more machinery than the outcome is worth.
local awaiting = {}

local function awaitAck(matchId, license, reporter)
    if matchId == nil or license == nil or reporter == nil then return end
    local m = awaiting[matchId]
    if not m then
        m = {}
        awaiting[matchId] = m
    end
    local q = m[license]
    if not q then
        q = {}
        m[license] = q
    end
    q[#q + 1] = reporter
end

--- Whoever is next in line for this subject's case, or nil.
local function takeAck(matchId, license)
    local m = awaiting[matchId]
    local q = m and m[license]
    if not q or #q == 0 then return nil end
    return table.remove(q, 1)
end

--- Say that somebody is owed for a case, once it is real.
---
--- AN EVENT, NOT A CALL INTO br_ddb. br_core states the fact and br_stats owns
--- the ledger, the same split `br:market:credited` already runs on -- so a
--- server with no br_stats simply does not pay, exactly as it does not record
--- match results, rather than failing a report path over a reward.
---
--- THE ANTICHEAT NEVER GETS ONE OF THESE. It has no reporter to pay, and a
--- claim keyed on nobody would sit on the reward queue until its age cap
--- expired it. Only the two call sites below emit this, and both are on the
--- player-report path.
local function claimReward(incidentId, license, matchId)
    if type(incidentId) ~= 'string' or incidentId == '' then return end
    if type(license) ~= 'string' or license == '' then return end
    TriggerEvent('br:report:claim', {
        incidentId = incidentId,
        license    = license,
        matchId    = matchId,
    })
end

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

--[[
    HOW A ROW NAMES THE PLAYER IT IS ABOUT (#172).

    ═══ IT USED TO BE THE SERVER ID, AND THAT CANNOT SURVIVE A DISCONNECT ═══

    Every row carried `src` and the panel echoed it back on submit; the server
    then did `BR.Roster.get(tsrc)` to reach the license. A departed player is
    not in the roster, so that lookup answers nil and the report is dropped --
    which is the second half of this issue and the half a "just append the
    departed rows" fix would have left broken.

    THE WORSE FAILURE IS NOT THE MISSING REPORT, IT IS THE WRONG ONE. Server ids
    are RECYCLED within the minute -- `BR.Roster.remove` frees `roster[src]`
    deliberately, and roster.lua's `departed` is an array rather than a map for
    exactly this reason. So a departed row keyed by its old `src` resolves to
    WHOEVER HOLDS THAT ID NOW, and if that person has joined the same
    still-forming match the `te.matchId == me.matchId` gate passes and the
    accusation is filed against a stranger, under their license, counting
    against their `named` set. A misattributed report is worse than a missing
    one, and nothing downstream could tell it had happened.

    ═══ AND IT IS NOT THE LICENSE EITHER, WHICH WAS THE OBVIOUS ALTERNATIVE ═══

    OWNER, 2026-08-17: "Why can't we give a target key that's the license: but
    without license: so it's obfuscated...?"

    IT IS NOT OBFUSCATION, AND THIS IS THE ONE PLACE THAT ARGUMENT CAN BE
    WRITTEN DOWN WHERE THE NEXT PERSON TO PROPOSE IT WILL SEE IT. Stripping
    `license:` removes a CONSTANT eight characters. `BR.Identity.qualified` puts
    them back in one line, from the other side of this same wire, and the prefix
    is FiveM's fixed vocabulary rather than a secret -- so the transform is a
    rename and the value on the wire is the license. What the client would then
    hold is the exact durable key this project keys moderation, bans, XP and
    every br_stats row on: roster.lua excludes `license` from PUBLIC_FIELDS and
    lists it as one of the things the RINGMASTER projection may carry precisely
    BECAUSE that one does not go to clients.

    Handing it out would let any modified client in a 48-player match harvest
    the permanent identity of everyone it plays with, and correlate the same
    people across servers and across sessions -- a name changes, a server id is
    recycled, a license does not. That is a privacy loss the feature does not
    need to buy anything, because:

    IT WOULD NOT EVEN BE ENOUGH ON ITS OWN. A client naming a license can name
    ANY license -- one from a previous match, one seen on another server -- so
    the server would still have to check that the named license is in this
    match, which means a server-side per-match table anyway. Once that table
    exists, putting the license on the wire buys nothing at all.

    ═══ SO: AN OPAQUE PER-MATCH ROW TOKEN ═══

    The server mints a random token per (match, roster entry), sends it in place
    of `src`, and keeps the mapping. The client holds a string that means
    nothing anywhere else and never sees a license.

    KEYED ON THE ENTRY TABLE, NOT ON A LICENSE OR AN ID, and that is what makes
    it survive the disconnect for free: `BR.Roster.remove` moves the SAME table
    from `roster` into `departed`, so a player who is ticked and then quits
    keeps the token they were listed under, and a reporter's selection stays
    valid across their departure. It also means a licenseless connection still
    gets a row and a token -- they simply resolve to no license and are refused
    at submit, exactly as they are today.

    WHAT THE TOKEN HAS TO BE, STATED HONESTLY, because "random" invites
    somebody to make it stronger later for no reason. It must (a) reveal nothing
    about the license and (b) not repeat across matches, so two rounds cannot be
    joined up. It does NOT need to resist guessing: the map is scoped to the
    guesser's OWN match, and they have already been sent every token in it, so a
    successfully guessed token is a handle they were handed on the last refresh.

    STABLE ACROSS REFRESHES, which is a correctness requirement and not a
    nicety. The panel re-asks every two seconds and keeps its ticks keyed by row
    id; a token that churned would silently clear the player's selection mid-
    report.

    FREED WITH THE MATCH, on `br:match:destroyed` with the rest of the tables at
    the bottom of this file -- the same hook, for the same reason.
]]

--- [matchId] = { byEntry = { [entry] = id }, byId = { [id] = entry } }
local rowIds = {}

--- The token stream.
---
--- BR.Rng IS A SEEDED xoshiro AND THAT IS FINE HERE, but only because the seed
--- is not. It is deterministic given its seed by design (the loot layout has to
--- derive identically on both sides), so seeding it from a constant would make
--- every server boot mint the same token sequence -- which would break property
--- (b) above across restarts. Two sources, the same pair br_ringmaster's boot
--- epoch uses and for the same reason its comment gives: GetGameTimer()
--- separates two boots of the same process, and a fresh table's address differs
--- per allocation and per Lua state.
---
--- BUILT ON FIRST USE, NOT AT LOAD, and that is not a micro-optimisation. A
--- module-scope `BR.Rng(...)` makes merely LOADING this file depend on br_lib
--- having loaded first -- which the manifest does arrange, but which also means
--- any harness that loads the report path without the shared modules dies at
--- load with a nil `BR.Rng`. tools/test_ringmaster.lua is exactly that harness
--- and it did. Deferring it means the dependency is on MINTING a token, which
--- is the operation that actually needs one.
local tokenRng = nil

--- 16 hex characters. Not a hash of anything -- see above.
local function mintToken()
    tokenRng = tokenRng or BR.Rng(
        ((GetGameTimer and GetGameTimer()) or 0)
        + (tonumber((tostring({}):match('0x(%x+)')) or '0', 16) or 0))
    return ('%08x%08x'):format(tokenRng:next(), tokenRng:next())
end

--- This entry's row token in this match, minting one on first sight.
--- @param matchId integer
--- @param entry table
--- @return string
local function idFor(matchId, entry)
    local t = rowIds[matchId]
    if not t then
        t = { byEntry = {}, byId = {} }
        rowIds[matchId] = t
    end

    local id = t.byEntry[entry]
    if id then return id end

    -- Collisions are vanishingly unlikely and the loop is one comparison, so
    -- the alternative is a rare duplicate that would make two rows the same
    -- player. Cheap certainty beats a probability argument nobody rechecks.
    repeat id = mintToken() until t.byId[id] == nil

    t.byEntry[entry] = id
    t.byId[id] = entry
    return id
end

--- How many row tokens this match is holding.
---
--- INTROSPECTION FOR ONE ASSERTION, AND IT IS WORTH THE FUNCTION. The only
--- cost this design carries is a table that grows with every entry ever listed
--- in a match, and the only thing that stops it growing forever is the free on
--- `br:match:destroyed` at the bottom of this file. That free is invisible from
--- outside -- deleting the line changes no behaviour any test could otherwise
--- see, because the map is keyed by matchId and a later match never looks in an
--- earlier match's bucket anyway. So a leak here would be silent, permanent and
--- proportional to uptime, which is precisely the shape of bug this project
--- keeps shipping. Making it observable is cheaper than trusting the line.
--- @param matchId integer
--- @return integer
function BR.Players.tokenCount(matchId)
    local t = rowIds[matchId]
    if not t then return 0 end
    local n = 0
    for _ in pairs(t.byId) do n = n + 1 end
    return n
end

--- The roster entry a client-supplied token names, or nil.
---
--- THE MATCH SCOPE IS STRUCTURAL RATHER THAN A CHECK. The map is per match and
--- the caller passes the REPORTER's own matchId, resolved server-side from
--- `source` -- so a token from another match simply is not in the table it is
--- looked up in. There is no `te.matchId == me.matchId` comparison to get
--- wrong, and no matchId travelling in either direction to make one possible.
--- @param matchId integer
--- @param id any  whatever the client sent
--- @return table|nil
local function entryFor(matchId, id)
    if type(id) ~= 'string' then return nil end
    local t = rowIds[matchId]
    return t and t.byId[id] or nil
end

--- Everyone in the same bucket as this player, INCLUDING THE ONES WHO HAVE GONE.
---
--- TWO SOURCES, AND THE SECOND ONE IS THE FIX (#172). The live roster answers
--- for everybody still connected; `BR.Roster.departedIn` answers for everybody
--- who disconnected from, or walked out of, this match since it formed.
---
--- MERGED HERE AND NOWHERE ELSE. Putting sealed entries back into the roster
--- would have been fewer lines and would have corrupted the alive count, the
--- squad panel, the win condition and the console snapshot in one move -- every
--- one of those reads the live roster, and every one of them is right to see a
--- departed player as gone. This function is the single place where they are
--- meant to be visible, so it is the single place they are added.
---
--- WHAT EVICTS A DEPARTED ROW: the match ending, and nothing else. `departed`
--- is emptied by `BR.Roster.clearDeparted`, called at CLEANUP and again on
--- `BR.Match.destroy` for a match that dissolved without reaching it -- so
--- retention is bounded by one match, which is also exactly the window the
--- report rules are scoped to.
---
--- @param src integer
--- @return table|nil rows, integer|nil matchId
function BR.Players.listFor(src)
    local me = BR.Roster.get(src)
    if not me or not me.matchId then return nil, nil end

    local rows = {}
    local function add(e, left, you)
        rows[#rows + 1] = {
            id      = idFor(me.matchId, e),
            name    = e.name,
            -- Already public: PUBLIC_FIELDS carries state and squadId, so
            -- this widens nothing. It is what lets the panel grey out your
            -- own squad and mark who has gone.
            state   = e.state,
            squadId = e.squadId,
            left    = left,
            you     = you,
        }
    end

    BR.Roster.each(
        function(e) return e.matchId == me.matchId end,
        function(otherSrc, e)
            -- RESOLVED AND CACHED WHILE THEY ARE STILL CONNECTED, which is the
            -- same argument roster.lua's `remove` makes for doing it at
            -- disconnect: `BR.Identity.ofPlayer` answers for a live connection
            -- and nobody else, so the submit path must not be the first thing
            -- to ask. It caches onto the entry, so this is one identifier scan
            -- per player per connection rather than one per two-second refresh.
            BR.Roster.licenseOf(otherSrc)
            add(e, e.state == BR.PlayerState.LEFT, otherSrc == src)
        end)

    -- `left` IS WRITTEN FROM WHICH LIST THE ROW CAME OUT OF, not from the state
    -- field. A sealed entry does carry `state = LEFT` -- `remove` sets it before
    -- sealing -- but reading the flag off the state would make the two ways of
    -- saying the same thing able to disagree, and this file has just spent a
    -- release with a `left` flag nothing could ever set.
    for _, e in ipairs(BR.Roster.departedIn(me.matchId)) do
        add(e, true, false)
    end

    -- DETERMINISTIC ORDER. `each` walks a hash, and a list that reshuffles
    -- between two-second refreshes is one where a player clicks the wrong
    -- checkbox. Sorted by name, with the departed last -- they are the least
    -- likely to be the subject and the most likely to be scrolled past.
    --
    -- THE TOKEN IS THE TIEBREAK, because names are not unique and a comparator
    -- that answers false in both directions leaves those two rows in whatever
    -- order the hash walk produced -- i.e. NOT deterministic, in the one
    -- function whose comment promises it is. Two rows can now share a name for
    -- an ordinary reason as well as a contrived one: somebody who left and
    -- somebody still playing are different rows about different people, and
    -- nothing stops them having picked the same gamertag.
    table.sort(rows, function(a, b)
        if a.left ~= b.left then return not a.left end
        if (a.name or '') ~= (b.name or '') then
            return (a.name or '') < (b.name or '')
        end
        return a.id < b.id
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
    --
    -- TWO DEDUPE SETS, NOT ONE, AND THE SECOND IS NOT REDUNDANT (#172). `seen`
    -- is the token, which is cheap and catches a client sending the same row
    -- twice. `seenLicense` is the PERSON, and it is needed now that a token is
    -- per roster ENTRY rather than per player: somebody who walks out of a
    -- match mid-round is sealed as a COPY (`BR.Roster.sealLeaver`), so the same
    -- human can legitimately hold two tokens in one match -- the live entry
    -- they were listed under before they left, and the sealed copy they are
    -- listed under after. Both resolve to one license, and filing twice would
    -- put two rows about one accusation in front of an admin. The old code got
    -- this for free because `src` was one-to-one with a person; it is not any
    -- more, so the invariant is stated instead of inherited.
    local resolved, seen, seenLicense, repeats = {}, {}, {}, {}

    for _, t in ipairs(targets) do
        local id = type(t) == 'table' and t.id or nil
        local category = tostring(type(t) == 'table' and t.category or '')

        if not BR.Config.isReportCategory(category) then
            category = BR.Config.defaultReportCategory()
        end

        -- One report per target per submission, whatever the client sent.
        if type(id) == 'string' and not seen[id] then
            seen[id] = true

            -- THE TOKEN IS THE WHOLE CHECK. It was minted into this match's map
            -- by `listFor`, so an unknown or foreign token resolves to nil and
            -- the target is skipped -- which is the same answer a server id
            -- from another match used to get, reached without the client ever
            -- holding a matchId, a server id or a license.
            local te = entryFor(me.matchId, id)

            if te then
                -- RESOLVED WHEN THEY WERE LISTED, NOT NOW. `listFor` caches the
                -- license onto the entry while its owner is still connected;
                -- asking `BR.Identity.ofPlayer` here would answer for whoever
                -- currently holds a recycled id, which is the exact
                -- misattribution this design exists to make impossible. A
                -- sealed entry carries the license `BR.Roster.remove` resolved
                -- at the moment of disconnect, for the same reason (#100).
                local tlicense = te.license

                -- NOT YOURSELF, by license rather than by id. There is no
                -- server id left to compare, and this is the stronger test
                -- anyway -- it also refuses somebody reporting the entry they
                -- were listed under before they left the match and rejoined.
                -- BR.IncidentBuild.fromReport refuses it a second time.
                if tlicense and tlicense ~= reporter and not seenLicense[tlicense] then
                    seenLicense[tlicense] = true

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

            -- CORROBORATORS ARE PAID TOO, AND THAT IS THE WHOLE POINT (#168).
            -- The limit is five players or three submissions a match, so a
            -- genuine cheater usually draws several reports -- and paying only
            -- whoever got there first teaches everybody to race the panel
            -- instead of watching the fight. The id is already in hand here,
            -- unlike the opening path below, so the claim is immediate.
            claimReward(prior[#prior], reporter, me.matchId)

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
                -- QUEUED BEFORE THE EMIT, NOT AFTER. `br:ringmaster:incident`
                -- is a same-state TriggerEvent and br_ringmaster's handler runs
                -- synchronously inside it -- only the DynamoDB round trip is
                -- asynchronous -- so anything registered afterwards would be a
                -- race against a write that is already in flight.
                awaitAck(me.matchId, t.license, reporter)
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

-- THE CASE IS NOW REAL, SO THE DEBT IS TOO.
--
-- A SECOND HANDLER ON THE SAME EVENT, alongside the one in server/incident.lua,
-- and that is the point rather than an accident: FiveM runs every registered
-- handler, so the corroboration map and the reward queue each hear the
-- acknowledgement directly instead of one of them being threaded through the
-- other. Neither has to know the other exists.
--
-- NOTHING HAPPENS FOR AN ANTICHEAT FILING. `takeAck` answers nil when no report
-- opened this case, so a machine-opened incident registers no debt -- correct,
-- because there is nobody to pay. A human who later corroborates it is claimed
-- on the corroboration path above, against this same id.
AddEventHandler('br:incident:filed', function(ack)
    if type(ack) ~= 'table' then return end
    local reporter = takeAck(ack.matchId, ack.subjectLicense)
    if reporter then claimReward(ack.incidentId, reporter, ack.matchId) end
end)

--[[
    "SUSPECT CHEATING? PRESS <KEY> TO REPORT <NAME>." -- the answer half (#169).

    ═══ THE CLIENT SENDS NOTHING, AND THAT IS THE DESIGN ═══

    The obvious shape for this is "client asks, is player 14 under suspicion?"
    and it is a probe. A modified client would walk the roster and read back
    exactly the list this feature must never produce -- who has a case open --
    which is the same information #93 spends its whole argument keeping away
    from the one player who most wants it. Rate limiting a probe does not stop
    it; it stops it being fast.

    So the question carries no subject at all. This handler resolves the asker's
    own killer from the roster and the damage records the server already keeps,
    and answers about that player or answers nothing. There is no field a client
    can put a name in, so there is nothing to enumerate WITH -- the guard is the
    absence of a parameter, not a check on one.

    WHAT A PLAYER CAN STILL LEARN: that the person who just killed them has a
    case open. That is the feature, it is one bit about one player they were
    already looking at, and there is no way to obtain it without first being
    killed by that player in a match they are both in.

    AND THE SUBJECT IS STILL SHOWN NOTHING. This goes to the victim. The player
    it is about learns nothing, here or anywhere else.

    ONCE PER DEATH. The latch is the killer's license against this asker for
    this match, held in `nudged` -- so a client that fires this every frame gets
    one answer, and a player killed twice by the same suspect is not nagged
    twice about the same case.
]]

--- [matchId] = { [reporterLicense] = { [killerLicense] = true } }
local nudged = {}

RegisterNetEvent(BR.Net.REPORT_KILLED)
AddEventHandler(BR.Net.REPORT_KILLED, function()
    local src = source

    local me = BR.Roster.get(src)
    if not me or not me.matchId then return end

    -- ONLY THE DEAD ASK. A living player has not been killed by anybody, so
    -- there is no killer to resolve and no occasion for the prompt. DBNO is
    -- excluded too: being knocked is not being killed, and the player who
    -- knocked you may yet be the one who revives nobody.
    if me.state ~= BR.PlayerState.DEAD then return end

    -- THE SERVER'S OWN ATTRIBUTION, not the client's claim -- the same function
    -- combat.lua uses to decide who gets the kill, so the player named here is
    -- exactly the player named in the kill feed. It already applies the assist
    -- window, refuses self-attribution and refuses a killer who has left.
    local killerSrc = BR.Combat and BR.Combat.attributedKiller(me)
    if not killerSrc then return end

    local killer = BR.Roster.get(killerSrc)
    if not killer or killer.matchId ~= me.matchId then return end

    local kBy = BR.Identity and BR.Identity.ofPlayer(killerSrc)
    local kLicense = kBy and BR.Identity.qualified('license', kBy.license)
    if not kLicense then return end

    -- THE ONE QUESTION, ASKED THE WAY EVERY OTHER PART OF THIS FILE ASKS IT.
    -- `priorFor` is fed by `br:incident:filed`, so it answers for cases opened
    -- by the anticheat as well as by a report -- which is the pairing worth
    -- nudging toward: somebody the machine already flagged, named independently
    -- by a human who just fought them.
    local prior = BR.Incident and BR.Incident.priorFor(me.matchId, kLicense) or {}
    if #prior == 0 then return end

    -- A player with no license cannot be rate limited, and cannot be paid
    -- either, so there is nothing to gain by prompting them.
    local myBy = BR.Identity and BR.Identity.ofPlayer(src)
    local myLicense = myBy and BR.Identity.qualified('license', myBy.license)
    if not myLicense then return end

    local m = nudged[me.matchId]
    if not m then
        m = {}
        nudged[me.matchId] = m
    end
    local mine = m[myLicense]
    if not mine then
        mine = {}
        m[myLicense] = mine
    end
    if mine[kLicense] then return end
    mine[kLicense] = true

    -- NO ID AND NO LICENSE ON THE WIRE, only the display name the kill feed has
    -- already put on this player's screen. The panel resolves the target the
    -- same way it always has, from the list the server sends it.
    TriggerClientEvent(BR.Net.REPORT_HINT, src, { kind = 'killer', name = killer.name })
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
    -- The nudge latch is per match for the same reason the report limit is: a
    -- player who cheats in three consecutive rounds is three things worth
    -- telling an admin about, and the prompt should offer each of them.
    nudged[ev.matchId] = nil
    -- AND THE ROW TOKENS, WHICH IS THE ONLY THING BOUNDING THE TABLE THIS FILE
    -- GREW (#172). It holds one string per roster entry ever listed in this
    -- match, live or departed.
    --
    -- IT IS PURELY A FREE, AND SAYING SO MATTERS. It is tempting to also call
    -- this the reason a token cannot be replayed into the next match -- it is
    -- not. The map is keyed by matchId and a submission is only ever looked up
    -- in the REPORTER's own match, so last round's token names nobody in this
    -- one whether or not the bucket was ever emptied. Deleting this line
    -- therefore breaks NOTHING observable and leaks for the server's uptime,
    -- which is why BR.Players.tokenCount exists for the test to watch it.
    --
    -- `destroy` is the only way a match leaves the registry, which is why every
    -- other per-match table above frees on this same hook.
    rowIds[ev.matchId] = nil
    -- ANY REPORT STILL AWAITING AN ACKNOWLEDGEMENT AT TEARDOWN HAS LOST ITS
    -- REWARD, and that is the honest outcome rather than a leak. br_ringmaster
    -- gives a write about thirty seconds and a match is destroyed well after
    -- that, so an entry surviving to here means the case was never written --
    -- there is no incident to be paid against and nothing to keep the row for.
    awaiting[ev.matchId] = nil
end)
