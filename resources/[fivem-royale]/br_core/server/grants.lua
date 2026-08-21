--[[
    Admin scopes, in the game, without asking Ringmaster anything.

    WHY THE GAME NEEDS THIS AT ALL (#168 self-dealing). An admin can file a
    player report from the in-game panel AND resolve the resulting incident in
    the console with a verdict -- and a resolved-with-action verdict pays 250
    Volts to whoever filed it (br_stats/server/awards.lua). Two admins can
    therefore report each other, close each other's cases and farm the reward
    indefinitely. The owner's instruction is that an admin's report is a report
    like any other and simply earns nothing: "maybe instead of blocking admins
    from reporting we should just block them from getting paid." This file is
    how the game finds out who holds that capability; server/players.lua is
    where the reward is withheld.

    THE GAME MUST NEVER DEPEND ON RINGMASTER. That is a standing rule and it is
    why this does not ask the console anything. The console's own admin test is
    a LIVE DISCORD ROLE CHECK at login -- the game has no Discord session, no
    OAuth token and no business acquiring one, and a game box that could not
    reach the console would lose its answer entirely.

    WHAT THE GAME DOES HAVE is the same DynamoDB grants table the console
    authorises against, read through br_ddb's `br:ddb:grantsFetch`. That is one
    source of truth rather than two, which is the argument
    br_ringmaster/server/maintenance.lua already makes for reading it instead of
    FiveM's ace system ("One source of truth or none"). This file is the second
    consumer of that read and the first one on a hot path.

    ═══ IT IS A CACHE, AND SAYING SO IS THE POINT ═══

    br_ddb's own comment on the grants read says it "is not a cache with
    invalidation -- callers ask when they need to know". A report is a hot path
    that a modified client can hammer, so asking on every attempt would put a
    DynamoDB GetItem behind an unauthenticated net event. It is cached here, and
    the freshness rules are at FRESH_MS and at `holds`.

    ═══ THIS FILE DECIDES NOTHING ABOUT REPORTS ═══

    It answers "does this license hold this scope" and nothing else. Which scope
    matters, and what happens when the answer is no, live in server/players.lua
    beside the handlers that enforce it. Everything in here would be equally
    correct if reports had never existed.
]]

BR = BR or {}
BR.Grants = {}

--- The scope that means "can close an incident with a verdict".
---
--- IT IS `ban`, AND THAT IS A FACT ABOUT THE CONSOLE RATHER THAN A GUESS. Every
--- route that can write a verdict onto an incident authorises on this one scope
--- and no other, in the console repo:
---
---   api/incidents/resolve  authorize('ban', 'write')     -- verdict { action = 'none' }
---   api/bans               authorize('ban', 'write')     -- verdict { action = 'ban' }
---   api/kick               authorize('kick') to kick, AND an explicit
---                          can(license, 'ban') before it may attach the kick
---                          to an incident. Its comment says why in as many
---                          words: without it "an admin trusted only to nudge
---                          people out of the bus door could close a cheating
---                          report permanently by kicking the subject, and #168
---                          would pay 250 Volts against a verdict they were not
---                          trusted to give."
---
--- SO IT IS THE CAPABILITY, NOT THE STATUS. "Is this person staff" would be the
--- easy test and it is the wrong one: a `view` account can read incidents and
--- resolve nothing, a `spectate` account can watch a match, a `notify` account
--- can send an announcement. None of them can pay themselves, so none of them
--- creates the exploit, and withholding their reward would be taking 250 Volts
--- off somebody who earned it. The half of the exploit that pays is the
--- verdict, and `ban` is exactly who may write one.
---
--- IF THE CONSOLE EVER SPLITS THIS OUT into a scope of its own -- `resolve`,
--- say -- this constant is the one line that has to move, and the three routes
--- above are where to check.
BR.Grants.RESOLVE_INCIDENTS = 'ban'

--- The scope that means "offer this person the console".
---
--- IT IS `view`, AND THE REASON IT IS NOT A MORE POWERFUL SCOPE IS THAT THIS
--- GATE DOES NOT GRANT ANYTHING. I checked what the console itself requires to
--- open, rather than assuming, and the answer is: nothing.
--- `fivem-ringmaster/src/app/page.tsx` -- the live players page the handoff
--- lands on -- calls `currentAdmin()` and redirects to /login if there is no
--- session, and its own comment says "Scope checks are per action ... holding a
--- valid session is the whole requirement". Every scope test in that repo sits
--- on a WRITE route (`authorize('ban', 'write')` and friends).
---
--- SO THE CONSOLE DECIDES WHO GETS IN AND THIS DECIDES WHO IS SHOWN A DOOR, and
--- those are different questions. The real admission test is the one the mint
--- endpoint runs and the game cannot: a live Discord role check, fail-closed,
--- plus an Auth.js account that already exists. Nothing chosen here can widen
--- that, and nothing chosen here can substitute for it.
---
--- WHAT THIS GATE IS ACTUALLY FOR, then, is twofold and both halves argue for
--- the same scope:
---
---   * The tab must not appear for players, because a door that answers "no"
---     is worse than no door -- and because showing it is how the CONSOLE'S
---     ADDRESS reaches a machine. BR.Nui.ADMIN carries the origin, so the gate
---     is what keeps that string off ordinary clients.
---   * It must appear for the people who use the console, which is everyone the
---     grants table names.
---
--- `view` is the console's own word for "may read player data, history and
--- incidents" (SCOPES in fivem-ringmaster/src/lib/grants.ts). That is what the
--- console is FOR; the write scopes are things done once inside it. NOTE THE
--- SCOPES ARE FLAT, NOT HIERARCHICAL -- `can()` is a plain
--- `grant.scopes.includes(scope)`, so `ban` does not imply `view` -- and the
--- consequence is worth stating plainly rather than discovering: an admin whose
--- row is `['ban']` and nothing else holds no `view` and gets no tab. That is
--- the correct outcome and not a gap. Such a row cannot read the incident it
--- would ban over; it is a data-entry mistake, and `bradmin` names it.
---
--- IF THE CONSOLE EVER GROWS A SCOPE FOR "MAY SIGN IN AT ALL", this constant is
--- the one line that moves.
BR.Grants.CONSOLE = 'view'

--- How long an answer is trusted without asking again, in milliseconds.
---
--- FIVE MINUTES IS A COMPROMISE BETWEEN TWO REAL COSTS and neither of them is
--- hypothetical:
---
---   too short  puts a DynamoDB GetItem behind a net event a modified client
---              can send in a loop. The read is cheap; a read per attempt is
---              not, and it is also a way for one client to spend the game
---              box's throughput.
---   too long   is a grant change that has not landed. A revoked admin should
---              start earning rewards again, and a freshly promoted one should
---              stop earning them, and both of those run off the same clock.
---
--- IT IS SHORTER THAN A MATCH, deliberately: a change made between rounds is in
--- force by the next one, which is the granularity a human running the console
--- would expect.
local FRESH_MS = 5 * 60 * 1000

--- How long to wait for br_ddb before giving up on one question.
---
--- The same value br_ringmaster/server/maintenance.lua gives its own grants
--- read. It only ever fires when br_ddb is absent or wedged: a DynamoDB failure
--- is not a timeout here, because br_ddb ANSWERS on every error path -- with an
--- empty scope list and an `error` field, which is a case `record` below has to
--- tell apart from a genuinely empty grant.
local ANSWER_TIMEOUT_MS = 5000

--- license -> { scopes = { [scope] = true }, at = ms }
---
--- ONLY EVER WRITTEN FROM A SUCCESSFUL READ. An error answer leaves whatever
--- was here alone -- see `record`.
---
--- BOUNDED BY THE PLAYERS WHO ARE HERE, not by the server's uptime: an entry is
--- dropped on `playerDropped`. Nothing asks about a license that is not
--- connected -- a reporter has to be in a match -- so there is nothing to keep.
local held = {}

--- Licenses with a question already in flight, so a burst asks once.
local inflight = {}

--- req -> license, for the answers we are waiting on.
local pending = {}

--- The request counter behind the ids in `pending`.
local nextReq = 0

--- Counters, for a test to watch and for a human to read in a log line.
local stat = { asked = 0, answered = 0, failed = 0, timedOut = 0 }

--- The license a connected source holds, or nil.
---
--- ASKED OF BR.Identity RATHER THAN OF THE ROSTER, so this file does not depend
--- on roster.lua having handled the same `playerJoining` first. Handler order
--- within one event is load order, which is a thing a manifest edit can change
--- silently, and "the grants prime stopped happening" would be invisible.
--- @param src number|string
--- @return string|nil
local function licenseOfSource(src)
    if not BR.Identity then return nil end
    local byKind = BR.Identity.ofPlayer(src)
    if not byKind then return nil end
    return BR.Identity.qualified('license', byKind.license)
end

--- Take one answer, or decline to.
--- @param license string
--- @param scopes any    whatever br_ddb sent
--- @param info table    br_ddb's `extra`; carries `error` on every failure path
local function record(license, scopes, info)
    -- AN ERROR IS NOT AN ANSWER, AND THIS IS THE LINE THAT MATTERS MOST IN THE
    -- FILE. br_ddb answers a failed grants read with an EMPTY SCOPE LIST and an
    -- `error` field -- see its `on('br:ddb:grantsFetch')`. Recording that empty
    -- list would cache "this person is not an admin" out of a DynamoDB timeout,
    -- which is the exact hole this whole change exists to close, arrived at by
    -- believing a failure. What we knew before, if anything, is still the best
    -- thing we know.
    if type(info) == 'table' and info.error ~= nil then
        stat.failed = stat.failed + 1
        print(('^3[br_core] grants read failed for %s: %s^7')
            :format(tostring(license), tostring(info.error)))
        return
    end

    local set = {}
    if type(scopes) == 'table' then
        for _, s in ipairs(scopes) do
            if type(s) == 'string' then set[s] = true end
        end
    end

    stat.answered = stat.answered + 1
    held[license] = { scopes = set, at = GetGameTimer() }
end

--- Ask br_ddb, at most once at a time per license.
--- @param license string
local function refresh(license)
    if inflight[license] then return end

    -- br_ddb ABSENT IS NOT AN ERROR TO REPORT, it is a server that has not been
    -- configured for DynamoDB -- a dev box, or a deploy where the resource is
    -- deliberately off. Asking would produce an event nothing answers and a
    -- timeout five seconds later, forever, per player.
    if GetResourceState('br_ddb') ~= 'started' then return end

    nextReq = nextReq + 1

    -- A STRING REQ, PREFIXED, AND IT IS A COLLISION FIX RATHER THAN A STYLE.
    -- `br:ddb:grantsResult` is a server event, so it reaches EVERY resource
    -- that listens -- and br_ringmaster/server/maintenance.lua already listens,
    -- with its own `pending` table keyed by its own counter starting at 1. Two
    -- consumers both numbering from 1 would each match the other's answers
    -- against their own table: maintenance would tell an admin about a server
    -- update because br_core asked about a license, and this file would record
    -- a maintenance sweep's scope list against whichever license happened to
    -- share the number. Namespacing the id makes both lookups miss cleanly,
    -- which is what `if not cb then return end` on the far side already does.
    local req = ('brgrants:%d'):format(nextReq)

    pending[req] = license
    inflight[license] = true
    stat.asked = stat.asked + 1

    -- ARMED BEFORE THE QUESTION IS ASKED, which is the idiom
    -- br_ringmaster/server/gate.lua spells out: arming it afterwards looks
    -- equivalent and is not, because a handler that throws synchronously would
    -- leave the timer unset and the license marked in flight forever -- and an
    -- in-flight license never asks again.
    SetTimeout(ANSWER_TIMEOUT_MS, function()
        if pending[req] == nil then return end
        pending[req] = nil
        inflight[license] = nil
        stat.timedOut = stat.timedOut + 1
        print(('^3[br_core] grants read for %s got no answer within %dms^7')
            :format(tostring(license), ANSWER_TIMEOUT_MS))
    end)

    TriggerEvent('br:ddb:grantsFetch', req, license)
end

AddEventHandler('br:ddb:grantsResult', function(req, scopes, info)
    local license = pending[req]
    -- Not ours: another resource asked, or our own timeout already fired and
    -- gave up on this one. Either way there is nothing here to write.
    if license == nil then return end

    pending[req] = nil
    inflight[license] = nil
    record(license, scopes, info or {})
end)

--- Does this license hold this scope?
---
--- THREE ANSWERS, NOT TWO, AND THE THIRD IS THE WHOLE REASON THIS RETURNS
--- `boolean|nil` INSTEAD OF `boolean`:
---
---   true   we have read this license's row and it carries the scope
---   false  we have read it and it does not
---   nil    we have never successfully read it
---
--- The caller has to decide what nil means for it -- see the fail-open argument
--- in server/players.lua -- and collapsing nil into false here would make that
--- decision silently, in the file that is least entitled to make it.
---
--- IT COMPARES AGAINST `true` RATHER THAN TESTING TRUTHINESS. `e.scopes[scope]`
--- is nil on a miss, and nil is exactly the value this function reserves for
--- "we do not know". Returning it would turn "read the row, they are an
--- ordinary player" into "we never asked", which fails open on the one player
--- we have a definite answer about. This project has shipped the truthiness
--- version of this bug four times (see the `didHit` note in
--- br_core/client/dbno.lua); the fix is the same each time and it is to say
--- what you mean.
---
--- IT REFRESHES AS A SIDE EFFECT, on a miss and once an entry goes stale, and
--- serves the stale answer meanwhile. That is deliberate: an answer that has
--- gone stale is still enormously better than none, and expiring it into nil
--- would fail back to UNKNOWN for the one license we know holds the scope --
--- and unknown pays (server/players.lua), so it would hand an admin a rewarded
--- report every FRESH_MS, on a clock, forever. Staleness costs at most FRESH_MS
--- of a grant change not having landed; expiry would cost the control itself.
---
--- @param license string|nil
--- @param scope string
--- @return boolean|nil
function BR.Grants.holds(license, scope)
    if type(license) ~= 'string' or license == '' then return nil end
    if type(scope) ~= 'string' or scope == '' then return nil end

    local e = held[license]
    if e == nil then
        refresh(license)
        return nil
    end

    if (GetGameTimer() - e.at) >= FRESH_MS then refresh(license) end
    return e.scopes[scope] == true
end

--- Counters and cache size, for tools/test_roster.lua and for a log line.
---
--- IT EXISTS FOR THE TEST, and that is a good enough reason here for the same
--- reason BR.Players.tokenCount gives: the properties worth pinning are a cache
--- that stops asking (`asked` must not climb per attempt) and a table that gets
--- freed (`known` must fall when a player leaves). Both are invisible from
--- outside and both fail silently.
--- @return table
function BR.Grants.stats()
    local known = 0
    for _ in pairs(held) do known = known + 1 end
    return {
        known = known, asked = stat.asked, answered = stat.answered,
        failed = stat.failed, timedOut = stat.timedOut,
    }
end

-- ---------------------------------------------------------------------------
-- Keeping the cache warm
-- ---------------------------------------------------------------------------

--- Ask about somebody now, so nothing has to ask later.
---
--- WHY PRIMING IS NOT AN OPTIMISATION HERE. Both reward decisions in
--- server/players.lua read `holds` SYNCHRONOUSLY -- they have to, because the
--- report rules they sit beside are synchronous and deferring them would race
--- "one report per reporter per target". A synchronous read can only answer
--- from the cache, so a cold cache is the rule not being applied -- and since
--- unknown PAYS, a cold cache is a reward going out. Priming at connect is what
--- makes the cache warm by the time it is asked: reporting requires being in a
--- MATCH, which is minutes after this fires.
--- @param src number|string
local function prime(src)
    local license = licenseOfSource(src)
    if license == nil then return end
    if held[license] ~= nil then return end
    refresh(license)
end

-- A SECOND LISTENER ON playerJoining, beside roster.lua's, rather than a call
-- from inside BR.Roster.add. FiveM runs every registered handler, so the two
-- do not have to know about each other -- the same argument server/players.lua
-- and server/incident.lua make for both listening to `br:incident:filed`.
AddEventHandler('playerJoining', function()
    prime(source)
end)

-- BOUNDED BY WHO IS HERE. Nothing asks about a license that is not connected --
-- a reporter has to be in a match -- so a departed player's row is dead weight
-- for the rest of the server's uptime. They are re-primed on the way back in.
AddEventHandler('playerDropped', function()
    local license = licenseOfSource(source)
    if license == nil then return end
    held[license] = nil
    inflight[license] = nil
end)

-- THE RESTART CASE, which is the one that leaves a match in progress with an
-- empty cache -- exactly the state where a report is about to arrive. The same
-- reconcile roster.lua does for the same reason: playerJoining is reliable and
-- a resource restart does not replay it.
--
-- br_ddb MAY NOT BE UP YET when this runs, in which case `refresh` declines and
-- these stay unknown. `holds` asks again on every miss, so the first report to
-- arrive re-opens the question -- it pays that one, and the next is decided.
AddEventHandler('onResourceStart', function(name)
    if name ~= GetCurrentResourceName() then return end
    held = {}
    inflight = {}
    pending = {}
    for _, idStr in ipairs(GetPlayers()) do
        prime(idStr)
    end
end)
