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
local RETRY_MS = 5000

--- How many times to re-ask before settling for "no tab".
---
--- THREE, AND THEN IT STOPS. An unbounded retry would put a DynamoDB read on a
--- timer, per player, for the length of a session -- for a menu tab. A player
--- who is an admin and misses all three gets no tab until they reconnect, which
--- `bradmin` will say out loud.
local RETRY_MAX = 3

--- Request ids for mints in flight. req -> src.
local pending = {}

--- The counter behind those ids.
local nextReq = 0

--- Per-source mint sequence, so the page can tell a fresh answer from an echo.
local mintSeq = {}

local stat = { offered = 0, minted = 0, refused = 0 }

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
--- @param src number|string
--- @return table { ok, why, origin, discordId, grant }
function BR.Admin.evaluate(src)
    local origin = consoleOrigin()
    if origin == nil then
        return { ok = false, why = 'no-console' }
    end

    local license = nil
    if BR.Identity then
        local byKind = BR.Identity.ofPlayer(src)
        if type(byKind) == 'table' then
            license = BR.Identity.qualified('license', byKind.license)
        end
    end
    if license == nil then
        return { ok = false, why = 'no-license', origin = origin }
    end

    local grant = nil
    if BR.Grants then
        grant = BR.Grants.holds(license, BR.Grants.CONSOLE)
    end
    if grant ~= true then
        -- `grant ~= true`, NEVER `not grant`. nil and false are different
        -- answers here and only the comparison tells them apart -- see the long
        -- note on holds(). This is the same didHit discipline the client uses
        -- for BOOL natives, for the same reason: in Lua, 0 and nil and false do
        -- not behave the way the sentence "if we have permission" implies.
        return {
            ok = false,
            why = (grant == nil) and 'grant-unknown' or 'not-admin',
            origin = origin, grant = grant,
        }
    end

    local discordId = BR.Admin.discordIdOf(src)
    if discordId == nil then
        return { ok = false, why = 'no-discord', origin = origin, grant = grant }
    end

    return { ok = true, origin = origin, discordId = discordId, grant = grant }
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

    local verdict = BR.Admin.evaluate(src)

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
end)

-- THE RESTART CASE. A `restart br_core` -- which tools/deploy.sh instructs after
-- every deploy -- does not replay br:ready, so without this an admin mid-session
-- silently loses the tab until they reconnect. The same reconcile roster.lua and
-- grants.lua both do, for the same reason.
AddEventHandler('onResourceStart', function(name)
    if name ~= GetCurrentResourceName() then return end
    for _, idStr in ipairs(GetPlayers()) do
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
    }

    for _, idStr in ipairs(GetPlayers()) do
        local verdict = BR.Admin.evaluate(idStr)
        if verdict.ok then
            print(('  [%s] %s -- tab shown'):format(idStr, GetPlayerName(idStr) or '?'))
        else
            print(('  [%s] %s -- no tab: %s'):format(
                idStr, GetPlayerName(idStr) or '?',
                WHY[verdict.why] or tostring(verdict.why)))
        end
    end
end, true)
