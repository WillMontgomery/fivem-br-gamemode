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
---
--- `corroborated` IS A SECOND SET BESIDE `named`, AND THE SPLIT IS #177's BUG
--- (owner, 2026-08-18: "player 1 reports player 2 ... next match ... is told
--- they've already reported player 2 this match - but that's not possible").
---
--- They answer two questions that were one question until the kill prompt
--- learned to reach across matches:
---
---   named         targets this reporter has NAMED IN A CASE BELONGING TO THIS
---                 MATCH. It is what the panel refuses on -- "you have already
---                 reported X in this match" -- and what stops a second
---                 accusation landing on a case that already carries this
---                 reporter's name.
---   corroborated  targets this reporter has answered the KILL PROMPT about
---                 this match, whichever match the case itself belongs to. It
---                 is what makes the prompt one action per offender (#177 part
---                 4) and is read by nothing else.
---
--- WHY THEY CANNOT BE ONE SET. `corroborationFor` asks `BR.Incident.openFor`,
--- which is deliberately NOT match-scoped, so the prompt fires tonight for a
--- case filed yesterday -- that is #177 part 1 and it is right. Writing that
--- keypress into `named` then spent TONIGHT's panel allowance for that player
--- on YESTERDAY's case: the reporter was refused when they went to file what
--- happened tonight, and tonight's round produced no case at all. That is the
--- exact rule #177 went out of its way to protect on the report-submit path --
--- three rounds of cheating are three things worth telling an admin about --
--- undone through the back door by the prompt.
local function usageFor(license, matchId)
    local u = usage[license]
    if not u or u.matchId ~= matchId then
        u = { matchId = matchId, count = 0, named = {}, corroborated = {} }
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
--- seconds later on `br:incident:filed`, and this is the table that joins the
--- two.
---
--- THAT ACKNOWLEDGEMENT NOW CARRIES `reporterLicense` TOO (#180), which makes
--- this queue a SECOND route to a fact the envelope states directly -- and
--- saying so is the point of this paragraph. The field was added for the
--- courtesy notice's audience, in server/incident.lua, and the reward pairing
--- was deliberately left on this queue rather than moved in the same change:
--- collapsing them is a change to who gets paid, on the path a playtest of the
--- Volts loop is about to walk, and it belongs in its own commit with its own
--- assertions. Whoever does it deletes this table, `awaitAck`, `takeAck` and
--- the FIFO approximation below -- the ack pairs exactly and the approximation
--- stops being needed.
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
---
--- AND NEITHER DOES AN ADMIN WHO COULD RESOLVE THE CASE (#168 self-dealing).
--- THE GATE IS NOT IN HERE, AND THAT IS DELIBERATE: this function takes an
--- incident id and a license, and nothing in that pair says at what moment the
--- reward was earned. The rule is about report time -- see the block above
--- `earnsRewards` -- and the opening path calls this from the DynamoDB
--- acknowledgement seconds later, so a check placed here would silently be a
--- payment-time rule for one of the three paths and a report-time rule for the
--- other two. Every caller decides before calling.
local function claimReward(incidentId, license, matchId)
    if type(incidentId) ~= 'string' or incidentId == '' then return end
    if type(license) ~= 'string' or license == '' then return end
    TriggerEvent('br:report:claim', {
        incidentId = incidentId,
        license    = license,
        matchId    = matchId,
    })
end

--[[
    ADMINS REPORT LIKE ANYBODY ELSE AND ARE NEVER PAID FOR IT (#168 self-dealing).

    OWNER, having first asked for the report itself to be blocked and then
    changed their mind about it: "hmmm maybe instead of blocking admins from
    reporting we should just block them from getting paid. Can we do that
    instead?" And, unprompted, about the second path: "also remember admins can
    corroborate. they should still not be paid though."

    ═══ WHAT THE EXPLOIT IS, BECAUSE IT DECIDES WHO IS AFFECTED ═══

    An accurate report pays Volts -- `AWARD_VOLTS` in br_stats/server/awards.lua,
    quoted nowhere else because it has moved twice -- and what
    makes a report "accurate" is a VERDICT written in the console. So the loop
    needs two halves: file the report, then resolve it with an action. Filing is
    free -- anybody in a match can do it -- and resolving is the half that takes
    a permission. Two admins can therefore report each other, close each other's
    cases, and farm the reward. `claimReward` above is where the first half
    turns into money, and it is the only thing this change touches.

    THE TEST IS THE CAPABILITY, NOT THE STATUS: BR.Grants.RESOLVE_INCIDENTS,
    argued at length where that constant is defined. A `spectate` or `notify`
    account cannot write a verdict, cannot pay itself, and is an ordinary player
    here -- which is right, because an admin who cannot resolve anything is
    simply a witness with a badge.

    ═══ WHAT DOES NOT CHANGE, WHICH IS EVERYTHING EXCEPT THE MONEY ═══

    This is the half that is easy to get wrong by being helpful, so it is listed
    rather than implied. An admin's report or corroboration still:

      * opens a real case, or attaches to the one that exists, carrying the same
        evidence and the same category
      * moves `seq` and the corroborator count on that case, so the "how many
        people have now said this" figure an admin reads in the queue counts
        them like anybody else
      * spends their own per-match slots -- `usage.count`, `usage.named`,
        `usage.corroborated` -- because the limits exist to stop spam, not to
        meter payment
      * gets the same acknowledgement, word for word

    THE LAST ONE IS A LEAK RULE AND NOT A COURTESY. A different answer for an
    admin is a probe: any player who could compare two responses would learn
    which accounts hold moderation grants. This file already refuses to let a
    reporter tell "opened a case" from "corroborated one" for the same class of
    reason, and the corroboration handler refuses to say why it declined. The
    same property has to survive this change, and the way it survives is that
    nothing on the wire moves at all.

    NO HELPER TEXT EITHER (standing owner rule). Nobody is told they were not
    paid. There is no new message anywhere in this change.

    AND AN ADMIN IS STILL A SUBJECT. Nothing on the reported side asks this
    question. An admin can be reported, corroborated against, flagged by the
    anticheat, and the player who reported them is paid normally.

    ═══ WHICH MOMENT COUNTS: REPORT TIME, NOT PAYMENT TIME ═══

    The reward is not paid when the report is filed. Path 1 below queues the
    reporter on `awaiting` and pays seconds later off the DynamoDB
    acknowledgement; and even then br_stats only records a CLAIM, which is paid
    days later when a human resolves the case. So there are two honest places to
    ask "is this person an admin", and they disagree:

      AT PAYMENT TIME  the sweep in br_stats already reads DynamoDB, so this is
                       nearly free. But it re-judges a past act by a present
                       fact. Somebody who reported a cheater as an ordinary
                       player on Monday and was made a moderator on Wednesday
                       loses a reward they fairly earned -- and somebody who
                       filed as an admin and resigned gets paid for the exact
                       act this rule exists to stop.

      AT REPORT TIME   the conflict of interest is a fact about the moment of
                       filing: could this person have arranged the verdict that
                       pays them, when they chose to file? A later grant edit
                       cannot make that answer wrong, in either direction.

    REPORT TIME, and the implementation follows from it: the answer is resolved
    once, up front, and RECORDED BY NOT CREATING A CLAIM AT ALL. There is no
    stored field, which is the part worth noticing -- the absence of a
    `br:report:claim` IS the record, it is durable because nothing downstream
    ever existed to reconsider, and it needs no migration and no new column on
    an incident. br_stats is not modified by this change and does not know the
    rule exists.

    IT ALSO KEEPS THE RULE IN ONE PLACE. Adding a second check in the sweep
    would reintroduce the payment-time problem for anybody it caught, so it is
    deliberately NOT defence in depth -- two checks at two moments would be two
    different rules.

    ═══ WHEN THE GRANTS READ IS UNAVAILABLE: PAY ═══

    `BR.Grants.holds` answers nil when it has never managed to read a license's
    row -- br_ddb absent, DynamoDB unreachable, or a report filed in the first
    seconds after a br_core restart. The two failures are not symmetric and that
    is what decides it:

      DO NOT PAY  an ORDINARY player -- which is nearly everybody -- does the
                  right thing, reports a cheater, and silently earns nothing.
                  They are never told, there is nothing to appeal to, and the
                  feature quietly stops working during exactly the outage nobody
                  is watching for. The harm lands on somebody innocent.

      PAY         an admin earns one bounty they should not have. That is a soft
                  in-game currency, going to somebody who already holds
                  moderation powers, and they still had to get a colleague to
                  write a verdict in Ringmaster -- which is authorised
                  console-side and lands in the audit log.

    PAY. The cost of guessing wrong in one direction is a player wronged; in the
    other it is one bounty and an audit trail. It is also rare by construction:
    BR.Grants primes at connect, minutes before anybody can report.

    NEVER SILENT, THOUGH. An unresolved check is this rule not being applied, so
    it gets a log line naming the license -- otherwise the fail-open window is
    invisible for exactly as long as it is open.
]]

--- Does a report filed by this license, right now, earn its bounty?
---
--- @param license string|nil
--- @param what string    which path is asking, for the log line
--- @return boolean
local function earnsRewards(license, what)
    local holds = BR.Grants
        and BR.Grants.holds(license, BR.Grants.RESOLVE_INCIDENTS)

    -- COMPARED AGAINST `true` AND `nil` EXPLICITLY, never tested for
    -- truthiness. There are three answers here and TWO OF THEM ARE FALSY:
    -- `false` means "we read the row and they are an ordinary player", `nil`
    -- means "we never got an answer at all", and they lead to the same outcome
    -- for opposite reasons -- one is the rule applying, the other is the rule
    -- failing open. Collapsing them would lose the log line that is the only
    -- evidence the second ever happened. This project has shipped the
    -- truthiness version of this mistake four times; see the `didHit` note in
    -- br_core/client/dbno.lua.
    if holds == true then
        print(('[br_core] no reward: %s holds %s at the time of filing (%s)')
            :format(tostring(license), BR.Grants.RESOLVE_INCIDENTS, what))
        return false
    end

    if holds == nil then
        -- LOUD, AND IT NAMES THE LICENSE, so a run of these can be matched
        -- against a grants row by hand afterwards. This line is the fail-open
        -- window standing open.
        print(('^3[br_core] admin check unresolved for %s -- paying %s anyway^7')
            :format(tostring(license), what))
    end

    return true
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

    -- WILL THIS SUBMISSION EARN ANYTHING (#168 self-dealing)?
    --
    -- ASKED ONCE, HERE, RATHER THAN AT EACH REWARD CALL SITE BELOW. This is
    -- "report time" in the argument above `earnsRewards` about which moment
    -- counts: it is settled before a single case is opened, against the
    -- reporter the server itself identified, and it is one answer for the whole
    -- press of Send. Asking per target would let one submission be half paid if
    -- a grant landed between two rows of it.
    --
    -- AND ONLY WHEN SOMETHING IS ACTUALLY GOING TO BE FILED, so a submission
    -- already refused above -- the allowance, a repeated target, nothing
    -- resolvable -- does not put a line in the log about a reward that was
    -- never in question.
    --
    -- IT CHANGES NOTHING ELSE. Not the limit, not the dedupe, not whether a
    -- case opens, not the answer the player gets. The only two things it
    -- reaches are `claimReward` and `awaitAck`.
    local earns = false
    if #resolved > 0 then earns = earnsRewards(reporter, 'panel report') end

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
            --
            -- UNLESS THE REPORTER COULD RESOLVE THE CASE THEY ARE JOINING (#168
            -- self-dealing). The corroboration itself has ALREADY HAPPENED --
            -- it is emitted above, it moved `seq` and `s.reports`, and the
            -- console will show it -- so this is the money and nothing but the
            -- money. See the block above `earnsRewards`.
            if earns then
                claimReward(prior[#prior], reporter, me.matchId)
            end

            print(('[br_core] report: %s corroborates case %s about %s (report %d, seq %d)%s')
                :format(tostring(me.name), tostring(prior[#prior]),
                        tostring(t.name), s.reports, s.seq,
                        earns and '' or ' -- unpaid'))
        else
            -- HOISTED so the timeline can be built from the SAME records the
            -- evidence was (#30). Reading the buffer twice would be two answers
            -- to one question -- a kill landing between the calls would be in
            -- one and not the other.
            local records = BR.Evidence and BR.Evidence.forLicense(t.license) or {}

            local payload, why = BR.IncidentBuild.fromReport({
                license         = t.license,
                name            = t.name,
                reporterLicense = reporter,
                reporterName    = me.name,
                category        = t.category,
                matchId         = me.matchId,
                at              = GetGameTimer(),
            }, records)

            if payload then
                -- THE MATCH AROUND THE CASE (#30): match start and every kill by
                -- the subject so far, folded onto the write that was already
                -- going to happen. Guarded because server/incident.lua loads
                -- AFTER this file -- at call time it is always there, but the
                -- guard is what makes that a fact rather than an assumption.
                if BR.Incident and BR.Incident.attachTimeline then
                    BR.Incident.attachTimeline(payload, records)
                end
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
                --
                -- AND NOT QUEUED AT ALL WHEN THE REPORTER CANNOT EARN (#168
                -- self-dealing). This queue exists for one purpose -- to name
                -- who is owed when the id comes back -- so the way to not pay
                -- somebody is to never put them on it. `takeAck` then answers
                -- nil for this case, which is the SAME state an anticheat
                -- filing produces and which the acknowledgement handler already
                -- handles correctly: "a machine-opened incident registers no
                -- debt -- correct, because there is nobody to pay."
                --
                -- THE CASE IS FILED EITHER WAY, on the very next line. Nothing
                -- about the incident, its evidence, its category or its
                -- reporter field depends on this.
                if earns then
                    awaitAck(me.matchId, t.license, reporter)
                end
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
--
-- AND NOTHING HAPPENS FOR A CASE AN ADMIN OPENED (#168 self-dealing), by the
-- same mechanism and deliberately not by a second test here. The submit path
-- decided at REPORT TIME not to queue them, so `takeAck` finds an empty queue
-- and this handler cannot tell the two silences apart -- which is the point.
-- Asking "is this reporter an admin" HERE would be asking seconds later, on the
-- acknowledgement, and would quietly make one of the three reward paths a
-- payment-time rule while the other two stayed report-time. See the block above
-- `earnsRewards`.
AddEventHandler('br:incident:filed', function(ack)
    if type(ack) ~= 'table' then return end
    local reporter = takeAck(ack.matchId, ack.subjectLicense)
    if reporter then claimReward(ack.incidentId, reporter, ack.matchId) end
end)

--[[
    "SUSPECT CHEATING? PRESS TAB TO REPORT <NAME>." -- the answer half (#169),
    and the one-press action behind it (#177).

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

    ═══ AND IT IS ONE ACTION, NOT AN INVITATION TO THE PANEL (#177) ═══

    The prompt used to point at the player list, which is five steps to say "yes,
    that one too" about a case the server had ALREADY resolved before deciding to
    offer the prompt at all. The key now submits the corroboration outright, over
    REPORT_CORROBORATE, and that event carries no fields for the same reason this
    one does not.

    ONE TIME PER OFFENDER, AND `nudged` WAS THE WRONG LATCH FOR IT. It suppresses
    a second PROMPT within one match and knows nothing about the report `usage`
    table -- so a player who reported somebody from the panel and was then killed
    by them got the prompt anyway, inviting a second bite at a case already
    carrying their name. `corroborationFor` below asks BOTH questions, and it is
    the ONE function that decides whether the prompt is shown AND whether the key
    does anything, so the two cannot drift apart. `nudged` stays for what it is
    actually good at: not nagging somebody who ignored the prompt the first time.

    THE SLOT IT SPENDS IS `usage.corroborated`, per (reporter, target, match) --
    and `usage.named` TOO, but only when the case it answered is one this match
    opened. That distinction is the whole of the match-boundary fix; it is argued
    at `usageFor` and at the write itself, and the short version is that the
    prompt reaches across matches and the panel's refusal does not, so one set
    could not honestly answer for both.

    It does NOT spend a SUBMISSION (`usage.count`) either way: one keypress is
    not one of the three trips to the panel a player gets, and charging it would
    quietly take a third of the allowance away from somebody who pressed a key
    they were told to press.
]]

--- Prompts this match has OFFERED, and the record a press is honoured against.
---
---   [matchId] = { [reporterLicense] = { [killerLicense] = { name, at } } }
---
--- IT WAS A SET OF `true`, AND WIDENING IT IS THE WHOLE OF THE VERDICT-SCREEN
--- FIX. Owner, 2026-08-20: "incident corroboration on the match verdict screen
--- in-game doesn't seem to work." It did not, and the case being system-filed
--- and a match old -- which is what the report was about -- turned out to have
--- nothing to do with it: `openBy` held the case perfectly and `openFor`
--- answered for it. What failed is that `corroborationFor` RE-DERIVED the
--- offender when the key was pressed, from two facts that both stop being true
--- while the prompt is still on the screen:
---
---   THE ROSTER STATE. The prompt fires on the death; the verdict screen is what
---   the player is looking at a second later; and at ENDED the server sweeps
---   every participant to LOBBY the moment their own screen reports black
---   (BR.Net.MATCH_COVERED -> BR.Match.sweepHome), which is a couple of seconds
---   into the verdict slam. `me.state ~= DEAD` from then on. In a small playtest
---   -- where the death that prompts you is also the death that ends the round
---   -- that is EVERY prompt.
---
---   THE ASSIST WINDOW. BR.Combat.attributedKiller refuses an attribution older
---   than assistWindowMs, which is 10 000ms. The client's key claim is
---   NUDGE_MS, also 10 000ms, but measured from the PROMPT -- which is sent
---   after the death, which is at or after the last hit. So the key is armed for
---   strictly longer than the server will answer for it, always, by an amount
---   nobody can see.
---
--- Both refusals are silent by design, so the player presses a key they were
--- told to press and nothing happens at all.
---
--- THE OFFER IS THEREFORE THE RECORD. The server made the offer; it knows who it
--- was about; and it keeps that until the match is destroyed, which is the
--- lifetime this table already had. Nothing new is trusted -- the press still
--- carries no fields, and there is still no verb that takes a license from a
--- client.
---
--- ITS LIFETIME MUST OUTLIVE THE CLIENT'S, NEVER THE REVERSE, and that is the
--- invariant this bug was the violation of. So there is deliberately no clock on
--- it beyond the match: an expiry here would be a second deadline to disagree
--- with the one on the screen, which is exactly what produced the failure.
--- `usage.corroborated` still makes it one action per offender per match.
local nudged = {}

--- The newest prompt this match offered this reporter, or nil.
---
--- NEWEST, BECAUSE THAT IS THE RULE THE CLIENT ALREADY KEEPS. BR.Keys.claim
--- documents it in as many words -- "a second claim replaces the first; the most
--- recent thing to ask is the thing that gets the key" -- and the press carries
--- nothing, so the server has to pick the same one the keyboard did. In practice
--- there is at most one: DEAD is terminal within a match, so a player is
--- prompted once. The comparison costs nothing and means the two sides cannot
--- disagree if that ever stops being true.
---
--- @param matchId any
--- @param myLicense string
--- @return string|nil license, string|nil name
local function standingOffer(matchId, myLicense)
    local mine = (nudged[matchId] or {})[myLicense]
    if not mine then return nil end
    local bestLic, bestName, bestAt = nil, nil, nil
    for lic, offer in pairs(mine) do
        if bestAt == nil or (offer.at or 0) > bestAt then
            bestLic, bestName, bestAt = lic, offer.name, (offer.at or 0)
        end
    end
    return bestLic, bestName
end

--- Everything both halves of the prompt need, or nil if there is no prompt.
---
--- ONE RESOLVER FOR THE OFFER AND THE ACTION. These were going to be two
--- handlers doing the same six lookups, which is the shape where an offer is
--- made on one set of conditions and honoured on another -- and the failure that
--- produces is a key the player was TOLD to press doing nothing at all, in
--- silence. Asking once means the prompt is shown exactly when the keypress
--- would work.
---
--- ONE FUNCTION WAS NOT ENOUGH, AND THE REASON IS TIME. The two callers ask at
--- different MOMENTS -- the offer at the death, the action up to ten seconds
--- later -- and half of what this function read had decayed in between. See the
--- note on `nudged` above for the two facts and how each of them expires. The
--- resolution below is therefore live attribution FIRST, and the offer the
--- server already made as the answer when the live one has run out.
---
--- @param src number
--- @return table|nil  { me, kName, kLicense, myLicense, open, usage }
local function corroborationFor(src)
    local me = BR.Roster.get(src)
    if not me or not me.matchId then return nil end

    -- A player with no license cannot be rate limited, and cannot be paid
    -- either, so there is nothing to gain by prompting them.
    local myBy = BR.Identity and BR.Identity.ofPlayer(src)
    local myLicense = myBy and BR.Identity.qualified('license', myBy.license)
    if not myLicense then return nil end

    local kLicense, kName

    -- ONLY THE DEAD ASK. A living player has not been killed by anybody, so
    -- there is no killer to resolve and no occasion for the prompt. DBNO is
    -- excluded too: being knocked is not being killed, and the player who
    -- knocked you may yet be the one who revives nobody.
    if me.state == BR.PlayerState.OUT then
        -- THE SERVER'S OWN ATTRIBUTION, not the client's claim -- the same
        -- function combat.lua uses to decide who gets the kill, so the player
        -- named here is exactly the player named in the kill feed. It already
        -- applies the assist window, refuses self-attribution and refuses a
        -- killer who has left.
        local killerSrc = BR.Combat and BR.Combat.attributedKiller(me)
        local killer = killerSrc and BR.Roster.get(killerSrc)
        if killer and killer.matchId == me.matchId then
            local kBy = BR.Identity and BR.Identity.ofPlayer(killerSrc)
            kLicense = kBy and BR.Identity.qualified('license', kBy.license)
            kName = killer.name
        end
    end

    -- AND THE OFFER THIS MATCH ALREADY MADE, when the live answer has run out.
    -- This is what makes the prompt survive as long as its own sentence does:
    -- past the assist window, past the sweep home, and onto the verdict screen
    -- the prompt was designed to live on (br_core/client/keybinds.lua says so in
    -- as many words). It resolves nothing the server did not already decide and
    -- announce -- it REMEMBERS it.
    if not kLicense then
        kLicense, kName = standingOffer(me.matchId, myLicense)
    end
    if not kLicense then return nil end

    -- THERE IS DELIBERATELY NO GRANT CHECK HERE, AND THIS PARAGRAPH IS THE
    -- REASON SOMEBODY WILL NOT ADD ONE (#168 self-dealing).
    --
    -- Owner, unprompted: "also remember admins can corroborate. they should
    -- still not be paid though." An admin's corroboration is a real
    -- corroboration in every respect except the money -- it attaches to the
    -- case, it moves `seq` and the corroborator count, it spends their own
    -- per-match slot, and it is evidence like anybody else's. Refusing it here
    -- would throw all of that away to stop a payment, and this function is the
    -- one that decides whether the PROMPT is even offered, so a check here
    -- would also silently tell an admin that the person who killed them has no
    -- case open.
    --
    -- The payment is gated at `claimReward` in the handler below, which is the
    -- only line that has to change.

    -- DOES THIS PLAYER HAVE A CASE OPEN AT ALL -- NOT "IN THIS ROUND" (#177).
    --
    -- This asked `priorFor(me.matchId, ...)` until now, and that map is dropped
    -- at `br:match:destroyed`, so a case still sitting in `pending_review` from
    -- a previous day was invisible and the prompt never fired (owner,
    -- 2026-08-18). It is backwards from what the prompt is for: an OLDER open
    -- case is the better corroboration target, because it has survived long
    -- enough to still be under review.
    --
    -- `openFor` IS FED BY THE SAME `br:incident:filed` ACKNOWLEDGEMENT, so it
    -- still answers for cases opened by the anticheat as well as by a report --
    -- which is the pairing worth nudging toward: somebody the machine already
    -- flagged, named independently by a human who just fought them.
    --
    -- THE REPORT-SUBMIT PATH ABOVE DELIBERATELY DID NOT MOVE WITH IT. It still
    -- asks the match-scoped `priorFor`, because that question is about which
    -- cases get OPENED and the answer there must stay per match -- three rounds
    -- of cheating are three things worth telling an admin about (see the
    -- teardown note below and the one in server/incident.lua). Widening both
    -- with one edit would have changed filing policy as a side effect of fixing
    -- a prompt.
    local open = BR.Incident and BR.Incident.openFor(kLicense) or {}
    if #open == 0 then return nil end

    -- ALREADY NAMED THIS PLAYER THIS MATCH -- reported from the panel, or
    -- corroborated from this very prompt (#177 part 4). One action per offender:
    -- there is nothing left to offer and nothing left to press.
    --
    -- BOTH SETS, AND THE PROMPT IS THE ONLY THING THAT READS BOTH. That is what
    -- keeps #177 part 4 exactly as strong as it was while the panel's own
    -- refusal narrows back to the panel's own question -- see usageFor. Delete
    -- either half and the prompt starts offering a second bite: `named` alone
    -- misses somebody who answered the prompt about a case from an older match,
    -- `corroborated` alone misses somebody who reported them from the panel.
    local u = usageFor(myLicense, me.matchId)
    if u.named[kLicense] or u.corroborated[kLicense] then return nil end

    -- `kName` RATHER THAN THE KILLER'S ROSTER ENTRY, because there may not be
    -- one to hand any more: on the offer path it is the live entry's name, and
    -- on the standing-offer path it is the name the prompt itself was written
    -- with -- which is the honest answer, since it is the name the player read
    -- on their own screen before pressing the key.
    return {
        me = me, kName = kName,
        kLicense = kLicense, myLicense = myLicense,
        open = open, usage = u,
    }
end

RegisterNetEvent(BR.Net.REPORT_KILLED)
AddEventHandler(BR.Net.REPORT_KILLED, function()
    local src = source

    local c = corroborationFor(src)
    if not c then return end

    local m = nudged[c.me.matchId]
    if not m then
        m = {}
        nudged[c.me.matchId] = m
    end
    local mine = m[c.myLicense]
    if not mine then
        mine = {}
        m[c.myLicense] = mine
    end
    if mine[c.kLicense] then return end

    -- THE OFFER IS WRITTEN DOWN, NOT MERELY TICKED OFF. `true` here used to mean
    -- only "do not nag them again"; it now carries what the press will need when
    -- the live attribution has expired -- the name this sentence is about, and
    -- when the offer was made. See the note on `nudged`.
    --
    -- WRITTEN BEFORE THE EVENT GOES OUT, so there is no window in which the
    -- player has the prompt on screen and the server has no record of having
    -- offered it. That ordering is the whole point of the table.
    mine[c.kLicense] = { name = c.kName, at = GetGameTimer() }

    -- NO ID AND NO LICENSE ON THE WIRE, only the display name the kill feed has
    -- already put on this player's screen. The client writes the sentence; since
    -- #177 the key in it is a FIXED "TAB", because the action is this file's
    -- REPORT_CORROBORATE rather than the player-list binding.
    TriggerClientEvent(BR.Net.REPORT_HINT, src, { kind = 'killer', name = c.kName })
end)

--- "Yes, that one too." One press, no panel (#177 part 3).
RegisterNetEvent(BR.Net.REPORT_CORROBORATE)
AddEventHandler(BR.Net.REPORT_CORROBORATE, function()
    local src = source

    -- SILENT WHEN IT DOES NOT APPLY, and that is deliberate rather than lazy.
    -- Every refusal this could speak -- "they have no case", "you already named
    -- them" -- is a fact about somebody else's standing, and an endpoint that
    -- answered them differently would be the enumeration oracle the whole
    -- no-payload design exists to prevent. An honest client only reaches this
    -- having been shown the prompt, and the prompt was decided by this same
    -- function, so the reachable path is the one that succeeds.
    local c = corroborationFor(src)
    if not c then return end

    -- THE NEWEST CASE, which is what `openFor` orders for. An older case is
    -- worth prompting about; a corroboration still belongs on the most recent
    -- one, so an admin reading top-down sees the live thread.
    local incidentId = c.open[#c.open]

    local s = subjectIn(c.me.matchId, c.kLicense)
    s.reports = s.reports + 1
    s.seq = s.seq + 1

    TriggerEvent('br:ringmaster:corroborate', {
        incidentId = incidentId,
        matchId    = c.me.matchId,
        license    = c.kLicense,
        name       = c.kName,
        -- SEQ AND COUNT COME FROM THE SAME `subjects` RECORD THE PANEL'S
        -- CORROBORATIONS USE, so one player's report and another's keypress are
        -- numbered by one counter rather than two that could disagree.
        --
        -- AND THE ONE THING THAT IS NOW APPROXIMATE, said out loud: `subjects`
        -- is per match and the case may not be. A day-old case corroborated in
        -- tonight's round restarts at 2, so the console can see a repeated seq
        -- where it previously could only see a gap. It is a triage hint on a
        -- channel that is allowed to drop messages, the corroboration itself is
        -- correct, and numbering it per incident would mean moving the anticheat
        -- path (which numbers from damage.lua's doubling counter) at the same
        -- time. Left as it is, on purpose, rather than half-moved.
        seq        = s.seq,
        count      = s.reports,
        -- THE PROMPT ASKED "SUSPECT CHEATING?", so the category is the answer to
        -- that question and not a menu the player never saw.
        reason     = BR.Config.defaultReportCategory(),
        -- NO SEVERITY, for the reason BR.IncidentBuild.fromReport gives.
    })

    -- PAID LIKE ANY OTHER CORROBORATOR (#168). The id is already in hand, so
    -- the claim is immediate -- the acknowledgement dance the opening path needs
    -- does not apply to a case that already exists.
    --
    -- UNLESS THEY COULD RESOLVE IT THEMSELVES (#168 self-dealing). Owner: "also
    -- remember admins can corroborate. they should still not be paid though."
    --
    -- AND THE ORDER OF THIS FILE IS THE POINT. Everything above this line has
    -- already run for an admin exactly as it runs for anybody else: the
    -- corroboration is emitted, `seq` and `s.reports` have moved, and the case
    -- carries their answer. Everything below it runs too -- the slots are spent
    -- and the acknowledgement is identical. This one `if` is the entire
    -- difference between an admin and a player, and it is deliberately placed
    -- where an early return could not have gone.
    --
    -- ASKED HERE RATHER THAN IN `corroborationFor`, which is where a check
    -- WOULD have gone if this were about refusing the action. It is not:
    -- `corroborationFor` also decides whether the PROMPT is shown, so a test
    -- there would tell an admin -- by silence -- that the player who killed
    -- them has no case open. That is the enumeration leak this handler's own
    -- header spends a paragraph refusing to open.
    if earnsRewards(c.myLicense, 'kill-prompt corroboration') then
        claimReward(incidentId, c.myLicense, c.me.matchId)
    end

    -- SPENT, AND WHICH SLOT IT SPENDS DEPENDS ON WHOSE MATCH THE CASE IS.
    --
    -- `corroborated` ALWAYS, because that is the prompt's own latch: one action
    -- per offender per match, the offer withdrawn and the key dead, exactly as
    -- #177 part 4 asks. Nothing else reads it.
    --
    -- `named` ONLY WHEN THE CASE BELONGS TO THIS MATCH, because that set is the
    -- PANEL's refusal and the panel asks a per-match question. Both writes
    -- happened here until now, and the cross-match half was wrong in a way the
    -- owner walked into on the first playtest: a case filed in match N, answered
    -- from the kill prompt in match N+1, spent match N+1's allowance -- so the
    -- reporter was told "you have already reported X in this match" about a
    -- match in which they had reported nobody, and the round's own cheating got
    -- no case of its own. Filing policy is per match (see the report-submit path
    -- above and the teardown note below); the prompt reaching across matches
    -- must not quietly repeal it.
    --
    -- WHEN THE CASE IS THIS MATCH'S, BOTH ARE WRITTEN AND NOTHING CHANGES. That
    -- is the case the panel would otherwise corroborate a second time under the
    -- same reporter's name, which is the "same opinion arriving twice" #143
    -- refuses -- so the refusal it produces is the correct one and stays.
    c.usage.corroborated[c.kLicense] = true
    for _, id in ipairs(BR.Incident and BR.Incident.priorFor(c.me.matchId, c.kLicense) or {}) do
        if id == incidentId then
            c.usage.named[c.kLicense] = true
            break
        end
    end

    -- THE SAME ANSWER A PANEL REPORT GETS, WORD FOR WORD. "Your report was added
    -- to an existing case" would leak that the person they just named is already
    -- under review, which is precisely what an offender's friend would go
    -- looking for -- so the player is told a report was sent, because one was.
    answer(src, true, 1, nil)

    print(('[br_core] report: %s corroborates case %s about %s from the kill prompt (report %d, seq %d)')
        :format(tostring(c.me.name), tostring(incidentId),
                tostring(c.kName), s.reports, s.seq))
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
