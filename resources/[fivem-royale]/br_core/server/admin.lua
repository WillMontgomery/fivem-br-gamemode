-- The Admin tab in the pause menu: who gets one, and how it gets signed in.
--
-- THREE FACTS HAVE TO BE TRUE BEFORE THE TAB EXISTS, and this file is the only
-- place that knows all three:
--
--   1. a console is configured   BR.Config.Admin.consoleUrl, from a convar
--   2. this license holds the console scope   BR.Grants.holds, from DynamoDB
--   3. FiveM reported a discord: identifier for this player
--
-- WHY ALL THREE GATE THE TAB RATHER THAN ONLY THE FIRST TWO -- the third is the
-- one that will surprise somebody, so it is written down at the top.
--
-- Minting needs a Discord id, and FiveM only reports a `discord:` identifier for
-- players who have Discord's activity integration switched on IN THEIR OWN
-- DISCORD CLIENT. It is opt-in and it is not ours to turn on;
-- fivem-ringmaster/docs/aws-setup.md documents the same problem for grants. So
-- an admin can hold the grant, be entirely legitimate, and still have no Discord
-- id visible from here.
--
-- The tempting answer is to show the tab and fail honestly when they press it.
-- THAT IS WRONG HERE, and the reason is that the failure is not occasional, it
-- is total. The first open of the console always needs a mint -- there is no
-- session yet -- and signing in inside the frame is not available either, because
-- Discord's OAuth pages refuse to be framed. So without a Discord id the door
-- opens onto nothing, every time, forever. A door that has never once opened is
-- not a door, so it is not drawn.
--
-- THAT MAKES A SILENT STATE, AND A SILENT STATE NEEDS A LOUD COMMAND. `bradmin`
-- at the bottom of this file answers "why is there no tab" for every connected
-- player, naming which of the three facts is missing. Without it this is a
-- feature that is either present or absent with nothing in between, which is
-- exactly the shape of the reports this project keeps generating.
--
-- ═══ FACT 2 IS SETTLED AT playerConnecting, ONCE ═══
--
-- The grant is the only one of the three that costs a network round trip, and it
-- used to be asked at `br:ready` -- the tail end of a connection, with a few
-- hundred milliseconds of budget and a five-second retry behind it. It is now
-- asked at `playerConnecting` instead, which moves the budget to the whole
-- resource download. `THE WARM` further down has the timing argument and the
-- reason that handler may never, under any circumstances, defer a connection.
--
-- SO THERE ARE TWO VIEWS OF FACT 2 AND THEY ARE NOT THE SAME FUNCTION:
--
--   BR.Admin.tabVerdict  what connect decided. Draws the door. Frozen for the
--                        session, on the owner's instruction -- a grant added
--                        mid-session needs a relaunch, and `bradmin` says so.
--   BR.Admin.evaluate    what DynamoDB says now. Hands out the credential, and
--                        takes the door away again if the row is read as gone.
--
-- ═══ WHAT THIS FILE DOES NOT DO ═══
--
-- It does not decide whether the admin may USE the console. It cannot: the real
-- admission test is a live Discord role check, run by the mint endpoint, which
-- fails closed. The game has no Discord session and no business acquiring one --
-- server/grants.lua says so at length. Everything here is about which door is
-- drawn on a player's screen.

BR = BR or {}
BR.Admin = {}

--- The console origin, or nil when nothing is configured.
---
--- READ ONCE, HERE, AND SENT OVER THE WIRE FROM HERE. The client never reads
--- this convar or this config key -- br_lib/config/overrides.lua applies
--- overrides on the SERVER only, so a client reading it would hold the committed
--- default while the server held the operator's value. tools/verify.sh has a
--- gate that makes that impossible to introduce; this is the shape it wants.
local function consoleOrigin()
    local cfg = BR.Config and BR.Config.Admin
    if type(cfg) ~= 'table' then return nil end
    local url = cfg.consoleUrl
    if type(url) ~= 'string' or url == '' then return nil end
    return url
end

--- How long to wait before re-asking about a license we have no answer for.
---
--- BR.Grants.holds returns nil for "never successfully read", and it starts a
--- read as a side effect of being asked. server/grants.lua primes at
--- playerJoining and its own read times out at 5s, so an answer that is still
--- nil this long after the client finished loading means the first read failed
--- rather than that it is slow.
---
--- THIS IS THE FIVE SECONDS THE CONNECT-TIME WARM EXISTS TO AVOID. It is a
--- POLLING interval, not a round trip: a DynamoDB read that lands one
--- millisecond after br:ready costs the admin the whole RETRY_MS before anything
--- looks again. See THE WARM below for the budget either side of that.
local RETRY_MS = 5000

--- How many times to re-ask before settling for "no tab".
---
--- THREE, AND THEN IT STOPS. An unbounded retry would put a DynamoDB read on a
--- timer, per player, for the length of a session -- for a menu tab. A player
--- who is an admin and misses all three gets no tab until they reconnect, which
--- `bradmin` will say out loud.
local RETRY_MAX = 3

--- How often the connect-time warm looks for an answer that has not arrived.
---
--- TEN TIMES FINER THAN RETRY_MS, and it can afford to be for one reason: there
--- is nobody waiting on it. The retry ladder above runs while a player is
--- standing in the world with a pause menu they may open at any moment, so its
--- cost is a wrong-looking screen. This one runs while they are still watching a
--- loading spinner, so its cost is a table lookup.
local WARM_MS = 500

--- How many times, so a ladder cannot outlive the connection that started it.
---
--- TWELVE, WHICH IS SIX SECONDS, AND THE NUMBER COMES FROM server/grants.lua
--- rather than from a round one: its own read gives up at ANSWER_TIMEOUT_MS
--- (5s). A ladder shorter than that would abandon a read that was still going to
--- answer; a much longer one would be polling for a connection that has failed.
local WARM_MAX = 12

--- Request ids for mints in flight. req -> src.
local pending = {}

--- The counter behind those ids.
local nextReq = 0

--- Per-source mint sequence, so the page can tell a fresh answer from an echo.
local mintSeq = {}

local stat = { offered = 0, minted = 0, refused = 0, warmed = 0, gaveUp = 0 }

--- The console scope as it was answered while this player was CONNECTING.
---
--- [license] = true | false. THE ABSENCE OF A KEY IS THE THIRD STATE and it is
--- the only one this table is allowed to spell as nothing: `nil` here means "the
--- connect-time read never produced an answer", which is exactly what
--- BR.Grants.holds means by nil and exactly what must never be written down as
--- `false`. An admin whose DynamoDB read was slow, or whose read failed, would
--- otherwise be filed as an ordinary player for the whole session -- silently,
--- and with a `bradmin` line that said they simply were not an admin.
---
--- WRITTEN BY THE WARM AND BY NOTHING ELSE. `tabVerdict` reads it and falls
--- through to a live `holds` when there is nothing here; it never writes back.
--- That keeps this table's meaning exact -- "what we learned at connect" -- so
--- `not-admin-at-connect` is a true statement rather than a plausible one.
local decided = {}

--- Licenses with a warm ladder still climbing. [license] = true
---
--- IT IS ALSO THE STOP SIGNAL. A player who leaves mid-connect has their entry
--- cleared, and the next rung sees that and returns -- which matters more than
--- tidiness: `holds` STARTS A DYNAMODB READ as a side effect of being asked, so
--- a ladder that kept climbing for somebody who had gone would refill
--- server/grants.lua's cache one row after that file had just freed it.
local warming = {}

--- The license behind a source, so a drop can forget what connect decided.
---
--- RECORDED AT CONNECT AND RE-KEYED AT JOIN, rather than read back out of FiveM
--- at playerDropped, and both halves are load-bearing:
---
---   * `playerConnecting` hands out a TEMPORARY source id, not the one the
---     player ends up holding. br_ringmaster/server/main.lua has the long note
---     on the bug that costs -- every session close skipped, silently, because
---     the key VALUE was wrong.
---   * identifiers are not reliably readable off a connection that is already
---     closing, which is why this is remembered rather than re-derived.
---
--- AND FORGETTING ON DROP IS THE OWNER'S REMEDY, not hygiene. The answer to "I
--- was given the role after I joined" is "relaunch the game" -- so a decision
--- that survived the disconnect would make the relaunch do nothing at all.
local licenseBySrc = {}

--- The qualified license FiveM reports for a source, or nil.
---
--- QUALIFIED (`license:abc...`), because that is the shape BR.Grants.holds and
--- the DynamoDB grants table both key on. server/grants.lua has its own copy of
--- this three-liner for the same reason it declines to reach into roster.lua:
--- deriving it here does not depend on any other file having handled the same
--- event first, and handler order within one event is load order.
--- @param src number|string
--- @return string|nil
local function licenseOfSource(src)
    if not BR.Identity then return nil end
    local byKind = BR.Identity.ofPlayer(src)
    if type(byKind) ~= 'table' then return nil end
    return BR.Identity.qualified('license', byKind.license)
end

--- The Discord id FiveM reported for a source, or nil.
---
--- UNQUALIFIED, deliberately: BR.Identity.parse strips the `discord:` prefix and
--- the console's mint endpoint wants the bare snowflake (`/^[0-9]{1,32}$/`).
--- Everything else in this project passes licenses around QUALIFIED because that
--- is how they are stored; this one is a foreign system's key and travels in
--- that system's shape.
--- @param src number|string
--- @return string|nil
function BR.Admin.discordIdOf(src)
    if not BR.Identity then return nil end
    local byKind = BR.Identity.ofPlayer(src)
    if type(byKind) ~= 'table' then return nil end
    local id = byKind.discord
    if type(id) ~= 'string' or id == '' then return nil end
    return id
end

--- Everything known about one player's eligibility, in one shape.
---
--- RETURNS THE REASON AS WELL AS THE ANSWER, because `bradmin` and the refusal
--- log both need to name which fact was missing, and a boolean cannot. The three
--- facts are checked in the order they are cheapest to establish.
---
--- `grant` IS THE THREE-VALUED ANSWER FROM server/grants.lua AND IS NOT
--- COLLAPSED HERE. nil means "we have never read this license's row", which is
--- not the same as "they are not an admin" -- it is the case `retry` exists for.
---
--- `session` CHOOSES WHICH ANSWER, and the two callers are not interchangeable:
--- BR.Admin.tabVerdict passes true to draw a DOOR from what connect decided,
--- BR.Admin.evaluate passes false to hand out a CREDENTIAL from what DynamoDB
--- says now. Both spellings live here so the other four gates cannot drift apart
--- between them.
--- @param src number|string
--- @param session boolean  prefer the connect-time decision over a live read
--- @return table { ok, why, origin, discordId, grant, cached }
local function assess(src, session)
    local origin = consoleOrigin()
    if origin == nil then
        return { ok = false, why = 'no-console' }
    end

    local license = licenseOfSource(src)
    if license == nil then
        return { ok = false, why = 'no-license', origin = origin }
    end

    local grant, cached = nil, false
    if session then
        grant = decided[license]
        -- `~= nil`, NEVER truthiness. A cached `false` IS an answer -- it is the
        -- ordinary player, who is nearly everybody -- and `if grant then` here
        -- would send every one of them back down the live path this whole change
        -- exists to get off.
        cached = grant ~= nil
    end
    if grant == nil and BR.Grants then
        grant = BR.Grants.holds(license, BR.Grants.CONSOLE)
    end

    if grant ~= true then
        -- `grant ~= true`, NEVER `not grant`. nil and false are different
        -- answers here and only the comparison tells them apart -- see the long
        -- note on holds(). This is the same didHit discipline the client uses
        -- for BOOL natives, for the same reason: in Lua, 0 and nil and false do
        -- not behave the way the sentence "if we have permission" implies.
        --
        -- THREE REASONS OUT OF TWO FALSY VALUES. `grant-unknown` is still the
        -- only one that retries, and a cached refusal is named apart from a live
        -- one because the fix differs: one is a grants row to edit, the other is
        -- a game to relaunch.
        local why = 'not-admin'
        if grant == nil then
            why = 'grant-unknown'
        elseif cached then
            why = 'not-admin-at-connect'
        end
        return {
            ok = false, why = why,
            origin = origin, grant = grant, cached = cached,
        }
    end

    local discordId = BR.Admin.discordIdOf(src)
    if discordId == nil then
        return {
            ok = false, why = 'no-discord',
            origin = origin, grant = grant, cached = cached,
        }
    end

    return {
        ok = true, origin = origin, discordId = discordId,
        grant = grant, cached = cached,
    }
end

--- Eligibility as DynamoDB has it NOW. The mint's view.
---
--- THE CONNECT-TIME DECISION IS DELIBERATELY NOT CONSULTED HERE, and that is the
--- half of this file that must not be made faster. This is what stands between a
--- net event and a credential, and `answer` re-derives the origin from it -- so a
--- grant read as genuinely gone takes the tab away at the next mint rather than
--- at the next reconnect. There is no latency to save: by the time anybody can
--- press Admin, server/grants.lua has been warm for minutes.
--- @param src number|string
--- @return table
function BR.Admin.evaluate(src)
    return assess(src, false)
end

--- Eligibility as it was decided while this player was connecting. The tab's view.
---
--- IT IS A DOOR, NOT A PERMISSION, which is what makes a frozen answer safe. The
--- owner's instruction is the whole design: "We really only need to do this
--- check once, since ringmaster will log them out and stop issuing tokens if
--- their role is removed. For the case of not having the role when joining the
--- game and then receiving admin perms, we'll simply make them relaunch the
--- game."
---
--- FALLS THROUGH RATHER THAN REFUSING when connect decided nothing. A read that
--- failed leaves no key, `holds` is asked live, and a nil answer is still
--- `grant-unknown` and still retries. Nobody is denied a tab for having had a
--- slow lookup.
--- @param src number|string
--- @return table
function BR.Admin.tabVerdict(src)
    return assess(src, true)
end

--- The warm's two tables and its counters.
---
--- IT EXISTS FOR THE TEST, and that is a good enough reason here for the same
--- reason BR.Grants.stats gives. The two properties worth pinning are invisible
--- from outside and both fail silently:
---
---   `decided` MUST FALL when a player leaves. If it does not, the one
---   instruction we give an admin who was promoted mid-session -- relaunch the
---   game -- does nothing at all, and they relaunch twice and then complain.
---
---   `warming` MUST FALL too. A ladder still climbing for somebody who has gone
---   asks `holds` about a license nobody is connected under, and `holds` starts
---   a DynamoDB read as a side effect -- so it refills server/grants.lua's cache
---   one row after that file freed it, on a timer, for free.
--- @return table
function BR.Admin.stats()
    local kept, climbing = 0, 0
    for _ in pairs(decided) do kept = kept + 1 end
    for _ in pairs(warming) do climbing = climbing + 1 end
    return {
        decided = kept, warming = climbing,
        warmed = stat.warmed, gaveUp = stat.gaveUp,
        offered = stat.offered, minted = stat.minted, refused = stat.refused,
    }
end

--- Tell one client whether it has an Admin tab, and where the console is.
---
--- THE ORIGIN IS THE PERMISSION. There is no separate boolean, so there is
--- nothing to fall out of step with it -- and a player who is not entitled to
--- the tab is never sent the console's address at all, which is the second
--- reason the gate exists.
--- @param src number|string
--- @param verdict table  from evaluate()
local function push(src, verdict)
    local payload = {}
    if verdict.ok then
        payload.origin = verdict.origin
        stat.offered = stat.offered + 1
    end
    TriggerClientEvent(BR.Net.ADMIN_STATE, src, payload)
end

--- Work out whether this player gets a tab, and say so -- retrying while the
--- only thing standing in the way is not having heard from DynamoDB yet.
--- @param src number|string
--- @param attempt integer|nil
local function offer(src, attempt)
    attempt = attempt or 1

    -- THE TAB'S VIEW, NOT THE MINT'S. In the ordinary case this is the whole
    -- speed-up: the answer was settled while this player was still downloading,
    -- so the branch below is not taken and the envelope goes out on the same
    -- tick as br:ready.
    local verdict = BR.Admin.tabVerdict(src)

    if verdict.why == 'grant-unknown' and attempt < RETRY_MAX then
        -- NOTHING IS SENT ON THIS PATH. A `{}` now would be a definite "you are
        -- not an admin" derived from a read that has not finished, and the page
        -- would have to be told twice to undo it. Silence costs the admin the
        -- few seconds it takes; a wrong answer costs a bug report.
        SetTimeout(RETRY_MS, function()
            -- Still here? A player who left between attempts has no client to
            -- send to. Both spellings of "gone" are tested: FiveM has returned
            -- nil and '' from this native for a departed source depending on
            -- build, and a `not name` would additionally be wrong the day it
            -- returns something falsy that is neither.
            local name = GetPlayerName(src)
            if name == nil or name == '' then return end
            offer(src, attempt + 1)
        end)
        return
    end

    push(src, verdict)
end

-- THE CLIENT SAYS WHEN IT IS READY, and that is the moment to answer.
--
-- br:ready is the existing handshake -- the client has finished loading and is
-- asking for its state -- so the tab is decided at the same point everything
-- else about this player's screen is. A SECOND LISTENER beside br_core's own,
-- rather than a call from inside it: FiveM runs every registered handler, so
-- neither has to know about the other, which is the argument server/grants.lua
-- and server/players.lua already make for both listening to br:incident:filed.
RegisterNetEvent(BR.Net.READY)
AddEventHandler(BR.Net.READY, function()
    offer(source)
end)

-- ---------------------------------------------------------------------------
-- The warm
--
-- "Opening the pause menu the first time takes way too long" (user, 2026-08-20).
-- The menu itself was never slow; the ADMIN TAB was, and this is why.
--
-- ═══ THE BUDGET, WHICH IS THE WHOLE BUG ═══
--
-- server/grants.lua asks DynamoDB at `playerJoining`, and admin.lua decided the
-- tab at `br:ready`. Everything between those two events is the time the read
-- has to come back in, and it is the tail end of a connection: the client has
-- already downloaded and started every resource, so it is a few hundred
-- milliseconds. Miss it and `holds` answers nil, nothing is sent, and the next
-- look is RETRY_MS -- FIVE SECONDS -- later. The player is in the world by then,
-- opens the pause menu, and finds no Admin tab on it.
--
-- So the cost was never the DynamoDB round trip. It was a polling interval that
-- a round trip of a few hundred milliseconds could fall on the wrong side of.
--
-- `playerConnecting` moves the START of the budget to the beginning of the
-- connection instead of the end of it -- the whole resource download and load,
-- seconds rather than milliseconds -- and the answer is waiting by the time
-- anything asks.
--
-- ═══ IT MUST NEVER DELAY A CONNECTION, AND THAT IS NOT A STYLE POINT ═══
--
-- `playerConnecting` is the event that can DEFER a join. This handler does not
-- touch `deferrals`: it does not defer, does not refuse, does not wait, and does
-- not care whether the read succeeds. br_ringmaster/server/main.lua registers
-- the same event on the same terms and says why in as many words -- "a connect
-- handler that blocks is a connect handler that eventually strands somebody".
--
-- Getting this wrong would trade a menu tab for an outage: a DynamoDB read that
-- hangs would hold every player on "connecting" for as long as it hung. So the
-- warm is FIRE AND FORGET by construction. Every path out of it -- an answer, a
-- failure, a timeout, a player who gave up and closed the game -- ends in the
-- same place, which is a table that either has a key or does not.
-- ---------------------------------------------------------------------------

--- Climb until DynamoDB has answered about this license, or until it is time to
--- stop caring.
---
--- ASKS `holds` RATHER THAN br_ddb DIRECTLY. The read, its 5s deadline, its
--- in-flight de-duplication and its refusal to record an error as an empty scope
--- list all belong to server/grants.lua, and a second asker with its own opinion
--- about any of those is how two caches start disagreeing. All this does is
--- collect an answer that file was going to produce anyway.
--- @param license string
--- @param attempt integer
local function warm(license, attempt)
    -- The player left, or a later connection took the ladder over. Either way
    -- this rung is not ours to climb -- and climbing it would ask `holds` about
    -- a license nobody is connected under, which starts a DynamoDB read and
    -- refills the very cache entry server/grants.lua just freed.
    if not warming[license] then return end

    local grant = nil
    if BR.Grants then
        grant = BR.Grants.holds(license, BR.Grants.CONSOLE)
    end

    if grant ~= nil then
        -- `~= nil` AND NOT TRUTHINESS, for the fourth time in this project and
        -- for the same reason each time. `false` is an ANSWER -- an ordinary
        -- player, read cleanly -- and `if grant then` here would throw it away,
        -- climb the ladder to its last rung and leave everybody who is not an
        -- admin exactly as slow as they were before.
        decided[license] = grant
        warming[license] = nil
        stat.warmed = stat.warmed + 1
        return
    end

    if attempt >= WARM_MAX then
        -- NOTHING IS WRITTEN DOWN. `decided[license]` stays absent, which reads
        -- as "connect decided nothing" everywhere it is consulted, and
        -- `tabVerdict` falls through to a live read and the existing retry
        -- ladder. Writing `false` here would be a DynamoDB outage cached as a
        -- statement about a person, for the length of their session, with a
        -- `bradmin` line that agreed with it.
        warming[license] = nil
        stat.gaveUp = stat.gaveUp + 1
        return
    end

    SetTimeout(WARM_MS, function()
        warm(license, attempt + 1)
    end)
end

AddEventHandler('playerConnecting', function()
    -- NO deferrals.defer(), NO refusal, NO wait. See the block above.
    local src = tonumber(source) or source

    local license = licenseOfSource(src)
    if license == nil then
        -- FiveM reported no license. `evaluate` answers `no-license` for this
        -- player anyway, so there is nothing a warm could usefully hold.
        return
    end

    licenseBySrc[src] = license

    -- ALREADY ANSWERED, OR ALREADY BEING ASKED. A second ladder for one license
    -- would be two timers racing to write the same value -- harmless, and still
    -- worth not doing, because the reconnect case makes it common: the drop and
    -- the new connect can land in either order.
    if decided[license] ~= nil then return end
    if warming[license] then return end

    warming[license] = true
    warm(license, 1)
end)

-- RE-KEY ONTO THE REAL SERVER ID.
--
-- `playerConnecting` handed out a TEMPORARY id, and `playerDropped` will arrive
-- with the real one. `playerJoining` is the only moment both numbers are in the
-- same place -- br_ringmaster/server/main.lua has the long note on the bug that
-- costs, which is every eviction silently skipped because the key VALUE was
-- wrong.
AddEventHandler('playerJoining', function(oldId)
    local newSrc = tonumber(source) or source
    local temp = tonumber(oldId) or oldId

    local license = licenseBySrc[temp] or licenseOfSource(newSrc)
    if temp ~= nil then licenseBySrc[temp] = nil end
    if license == nil then return end

    licenseBySrc[newSrc] = license
end)

-- ---------------------------------------------------------------------------
-- The mint
-- ---------------------------------------------------------------------------

--- Send one mint outcome to the page.
--- @param src number|string
--- @param url string|nil
--- @param err string|nil
local function answer(src, url, err)
    local seq = (mintSeq[src] or 0) + 1
    mintSeq[src] = seq

    -- THE ORIGIN RIDES ALONG ON EVERY ANSWER, AND LEAVING IT OFF IS A BUG WITH
    -- A NAME. The page holds ONE object for this feature, so an envelope
    -- carrying only a mint result would blank `origin` -- and the tab would
    -- disappear as a side effect of a mint that merely failed. The admin would
    -- press Admin, see an error, and find the tab gone.
    --
    -- RE-DERIVED RATHER THAN REMEMBERED, which is safe here for a reason that
    -- belongs to server/grants.lua rather than to this file: `holds` serves a
    -- STALE answer while it refreshes and never expires one into nil, so a
    -- DynamoDB outage cannot momentarily turn a known admin into an unknown
    -- one. Re-deriving therefore costs nothing on a blip and buys the honest
    -- behaviour on a real revocation -- a grant read as genuinely absent takes
    -- the tab away at the next mint rather than at the next reconnect.
    local verdict = BR.Admin.evaluate(src)
    local payload = { mint = { seq = seq, url = url, error = err } }
    if verdict.ok then payload.origin = verdict.origin end

    TriggerClientEvent(BR.Net.ADMIN_STATE, src, payload)
end

AddEventHandler('br:ringmaster:handoffResult', function(req, ok, url, err)
    local src = pending[req]
    -- Not ours: another resource asked, or our own timeout already gave up on
    -- this one. Either way there is nobody here waiting for it.
    if src == nil then return end
    pending[req] = nil

    if ok then
        stat.minted = stat.minted + 1
        -- NOT LOGGED. The URL carries the token, and a server log is the one
        -- place a 90-second credential becomes a permanent one.
        answer(src, url, nil)
        return
    end

    stat.refused = stat.refused + 1
    print(('^3[br_core] admin console mint refused for %s: %s^7')
        :format(tostring(src), tostring(err)))
    answer(src, nil, err or 'unknown')
end)

-- THE CLIENT ASKS; THE SERVER DECIDES EVERYTHING.
--
-- The event carries no arguments at all -- see BR.Net.ADMIN_MINT in
-- br_lib/shared/protocol.lua. A client that could name the Discord id it wanted
-- a session for could name somebody else's, and nothing downstream would catch
-- it: the console's role check would run against the id it was given and
-- cheerfully confirm that THAT person is an admin.
--
-- AND THE FULL CHECK RUNS AGAIN HERE. The tab is only shown to people who
-- passed it, which is a statement about the interface and not about the wire --
-- a modified client sends whatever it likes, whenever it likes, and this handler
-- is where that stops.
RegisterNetEvent(BR.Net.ADMIN_MINT)
AddEventHandler(BR.Net.ADMIN_MINT, function()
    local src = source

    local verdict = BR.Admin.evaluate(src)
    if not verdict.ok then
        stat.refused = stat.refused + 1
        print(('^3[br_core] admin console mint refused for %s: %s^7')
            :format(tostring(src), verdict.why))
        answer(src, nil, verdict.why)
        return
    end

    if GetResourceState('br_ringmaster') ~= 'started' then
        -- Asking would produce an event nothing answers and a caller waiting
        -- for a reply that cannot come. server/grants.lua declines the same way
        -- when br_ddb is absent, for the same reason.
        answer(src, nil, 'not-configured')
        return
    end

    nextReq = nextReq + 1
    -- A STRING REQ, PREFIXED. `br:ringmaster:handoffResult` is a plain event, so
    -- it reaches every resource that listens -- and if a second consumer ever
    -- appears with its own counter starting at 1, two tables would each match
    -- the other's answers. Namespacing makes both lookups miss cleanly, which is
    -- what the `if src == nil then return end` above already does. The same fix
    -- server/grants.lua made after br_ringmaster's maintenance sweep collided
    -- with it.
    local req = ('bradmin:%d'):format(nextReq)
    pending[req] = src

    -- NO TIMER HERE, AND THAT IS DELIBERATE RATHER THAN AN OMISSION. The timeout
    -- belongs to the resource making the HTTP call, because that is the side
    -- that knows what it is waiting on and what its ceiling is -- and
    -- br_ringmaster/server/handoff.lua answers on every path including its own
    -- 3s expiry. A second timer here would be a second opinion about the same
    -- deadline, and the two would disagree the day one of them moves.
    TriggerEvent('br:ringmaster:handoffMint', req, verdict.discordId)
end)

-- NORMALISED, BECAUSE THE WRITE IS AND THE READ WOULD NOT BE. `source` in a net
-- event handler is a NUMBER and `source` in playerDropped arrives as a STRING,
-- and in Lua t[5] and t["5"] are different keys -- so an un-normalised read here
-- would clear nothing, every time, and the tables would grow for the life of the
-- process. br_ringmaster/server/main.lua has the same note over the same fix,
-- made after it silently held every session open forever.
AddEventHandler('playerDropped', function()
    local src = tonumber(source) or source
    mintSeq[src] = nil
    for req, who in pairs(pending) do
        if who == src then pending[req] = nil end
    end

    -- AND THE CONNECT-TIME DECISION GOES WITH THEM, WHICH IS THE FEATURE AND NOT
    -- THE CLEANUP. The owner's answer to "I was made an admin after I joined" is
    -- "relaunch the game" -- so a decision that outlived the disconnect would
    -- make the relaunch change nothing, and the one instruction we gave the
    -- admin would be wrong.
    --
    -- READ FROM THE MAP, NOT FROM FiveM. Identifiers are not reliably readable
    -- off a connection that is already closing, and a failed read here would
    -- leave the decision behind -- which is the exact failure above, arrived at
    -- silently.
    local license = licenseBySrc[src]
    licenseBySrc[src] = nil
    if license == nil then return end

    decided[license] = nil
    -- Stops a ladder mid-climb. See the guard at the top of `warm`.
    warming[license] = nil
end)

-- THE RESTART CASE. A `restart br_core` -- which tools/deploy.sh instructs after
-- every deploy -- does not replay br:ready, so without this an admin mid-session
-- silently loses the tab until they reconnect. The same reconcile roster.lua and
-- grants.lua both do, for the same reason.
AddEventHandler('onResourceStart', function(name)
    if name ~= GetCurrentResourceName() then return end

    -- THE CONNECT-TIME DECISIONS ARE DROPPED RATHER THAN KEPT, and the reason is
    -- that they cannot be told apart from decisions this process never made. A
    -- restart replays nothing: these tables are empty on the way in, so anything
    -- claiming to be in them would be a lie. Everyone here is re-decided from a
    -- live read by `offer` below, exactly as they were before the warm existed.
    decided, warming, licenseBySrc = {}, {}, {}

    for _, idStr in ipairs(GetPlayers()) do
        local src = tonumber(idStr) or idStr
        -- Re-learnt so a LATER drop can still evict. This is the one place the
        -- license may be read straight from FiveM: the connection is open and
        -- settled, which is the case playerDropped is not.
        local license = licenseOfSource(src)
        if license ~= nil then licenseBySrc[src] = license end
        offer(idStr)
    end
end)

-- ---------------------------------------------------------------------------
-- "Why is there no Admin tab?"
-- ---------------------------------------------------------------------------

--- The one command that makes an invisible feature diagnosable.
---
--- IT EXISTS BECAUSE THE TAB IS BINARY AND ITS THREE PRECONDITIONS ARE NOT. An
--- admin who cannot see it has no way to tell whether the convar is unset, their
--- grant row is missing a scope, DynamoDB never answered, or Discord's activity
--- integration is off on their machine -- and those have four different fixes,
--- three of which are not in this repo.
---
--- RESTRICTED, like brconfig and brloot: it names who holds admin scope, which
--- is not a list a player should be able to print.
RegisterCommand('bradmin', function()
    print('=== admin console (#23) ===')

    local origin = consoleOrigin()
    print(('  console    %s'):format(origin or 'NOT CONFIGURED -- set br_adminConsoleUrl'))
    print(('  scope      %s (BR.Grants.CONSOLE)')
        :format(tostring(BR.Grants and BR.Grants.CONSOLE or 'br_core not loaded')))
    print(('  ringmaster %s'):format(GetResourceState('br_ringmaster')))
    print(('  offered %d, minted %d, refused %d')
        :format(stat.offered, stat.minted, stat.refused))
    -- THE WARM'S OWN TWO NUMBERS. `gave up` climbing is the one that explains a
    -- whole server's worth of admins having to wait five seconds again: it means
    -- DynamoDB was not answering during the connect window, and every tab on the
    -- box fell back to the retry ladder.
    print(('  connect-time answers %d, gave up %d')
        :format(stat.warmed, stat.gaveUp))
    print('')

    -- WHY EACH PLAYER RATHER THAN A COUNT. The question this answers is always
    -- about one specific person -- "I am an admin and I have no tab" -- and a
    -- summary line cannot answer it.
    local WHY = {
        ['no-console']    = 'br_adminConsoleUrl is not set',
        ['no-license']    = 'FiveM reported no license for this player',
        ['not-admin']     = 'grants row does not carry the console scope',
        ['grant-unknown'] = 'no answer from DynamoDB yet (br_ddb down, or still reading)',
        ['no-discord']    = 'no discord: identifier -- their Discord activity integration is off',
        -- THE SIXTH REASON, AND IT IS THE ONE WITH A DIFFERENT FIX. The other
        -- five are things to change on the server; this one is a decision this
        -- process already made and will not revisit, so editing the grants row
        -- fixes nothing until they reconnect. A `bradmin` that reported it as
        -- plain `not-admin` would send somebody to check a row that is already
        -- correct.
        ['not-admin-at-connect'] =
            'grants row carried no console scope when they connected -- if it does now, they must relaunch',
    }

    -- THE TAB'S VIEW, NOT THE MINT'S, because the question this command answers
    -- is "why is there no tab" -- and after the connect-time warm those two can
    -- legitimately disagree. Asking `evaluate` here would print the reason a
    -- mint would fail, which is a different question and, for the player who
    -- gained a grant mid-session, a different answer.
    for _, idStr in ipairs(GetPlayers()) do
        local verdict = BR.Admin.tabVerdict(idStr)
        if verdict.ok then
            print(('  [%s] %s -- tab shown'):format(idStr, GetPlayerName(idStr) or '?'))
        else
            print(('  [%s] %s -- no tab: %s'):format(
                idStr, GetPlayerName(idStr) or '?',
                WHY[verdict.why] or tostring(verdict.why)))
        end
    end
end, true)
