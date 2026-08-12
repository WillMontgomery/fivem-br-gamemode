--[[
    The connect-time ban gate.

    THIS IS THE PROJECT'S FIRST DEFERRAL, and deferrals are the one FiveM API
    where a bug does not throw, does not log, and does not recover: it leaves a
    human staring at a connecting screen until they give up and close the game.
    Nothing else in this codebase can waste somebody's evening so quietly. Every
    unusual-looking decision below exists because of that.

    THE THREE RULES, in priority order:

      1. ALWAYS RESOLVE. Every path through this file ends in exactly one
         deferrals.done(). Not "almost every path" -- a single early return that
         forgets is the bug described above.
      2. RESOLVE ON A CLOCK WE OWN. br_ddb answers over the network, and the
         network's worst behaviour is not failing but hanging. A timer started
         before the question is asked guarantees an answer even if nothing ever
         comes back.
      3. FAIL OPEN. Every error -- no br_ddb, no credentials, no route, a
         timeout, a malformed reply -- lets the player in and says so loudly in
         the console. A ban list that cannot be read must not become a server
         nobody can join. "A banned player gets in until the link recovers" is
         strictly better than "nobody gets in at all", which is how a game night
         ends.

    WHY THIS LIVES IN br_ringmaster RATHER THAN br_ddb: br_ddb answers questions
    and knows nothing about players, moderation or connect flow. Keeping the
    policy here and the data access there means the resource with AWS
    credentials has the smallest, most auditable surface possible.
]]

BR = BR or {}
BR.Ring = BR.Ring or {}

--- How long we wait for br_ddb before giving up and letting the player in.
---
--- DELIBERATELY LONGER THAN br_ddb'S OWN 3s TIMEOUT, so in the normal failure
--- case the inner timeout fires first and we get a real error message to log
--- rather than an anonymous "no answer". This outer one is the backstop for
--- br_ddb not running at all, in which case nothing ever answers and only this
--- timer saves the connection.
local ANSWER_TIMEOUT_MS = 5000

--- Correlates a request with its answer.
---
--- Monotonic per resource start. A restart resets it, which is safe: pending
--- entries die with the Lua state, and their deferrals die with the connection
--- FiveM already tore down.
local nextReq = 0

--- req -> function(banned, info). Entries are removed by whichever of the
--- answer or the timeout arrives first; the loser finds nothing and returns.
local pending = {}

--- The player-facing rejection message.
---
--- WRITTEN FOR THE PERSON BEING REFUSED, not for the admin. It answers the
--- three things they will otherwise ask in Discord: what happened, why, and
--- whether it ends. The reason text comes from the console and was stripped of
--- control characters at that boundary (see the console's lib/actions.ts) --
--- it is displayed, never executed, and never interpolated into a command.
--- @param info table
local function rejection(info)
    local reason = info.reason
    if type(reason) ~= 'string' or reason == '' then
        reason = 'No reason recorded'
    end

    local when = 'This ban does not expire.'
    if type(info.expiresAt) == 'number' and info.expiresAt > 0 then
        local secs = math.max(0, math.floor(info.expiresAt / 1000 - os.time()))
        local days = math.floor(secs / 86400)
        local hours = math.floor((secs % 86400) / 3600)
        if days > 0 then
            when = ('Expires in %d day%s.'):format(days, days == 1 and '' or 's')
        elseif hours > 0 then
            when = ('Expires in %d hour%s.'):format(hours, hours == 1 and '' or 's')
        else
            when = 'Expires within the hour.'
        end
    end

    return ('You are banned from this server.\n\nReason: %s\n%s'):format(reason, when)
end

--- req -> license, for requests that timed out and were admitted anyway.
---
--- CLOSING THE FAIL-OPEN WINDOW. Failing open is right -- an unreachable ban
--- list must not become a server nobody can join -- but it leaves a real hole:
--- a banned player who connects during an outage is in, and stays in until they
--- happen to reconnect. So a late answer is not discarded. If it says "banned"
--- after we already let them through, they are removed immediately with the
--- same message they would have seen at the door.
---
--- Entries are dropped once used or when the answer says clean, so this never
--- grows: at most one entry per connection that outran the timeout.
local lateWatch = {}

AddEventHandler('br:ddb:banResult', function(req, banned, info)
    local resolve = pending[req]
    if resolve then
        pending[req] = nil
        resolve(banned and true or false, info or {})
        return
    end

    -- No pending resolver: this answer lost the race with our timeout, and the
    -- player was admitted. Only a "banned" verdict is actionable now.
    local license = lateWatch[req]
    if not license then return end
    lateWatch[req] = nil

    if not banned or (info or {}).error then return end

    local reason = rejection(info or {})
    local kicked = BR.Ring.dropByLicense and BR.Ring.dropByLicense(license, reason)
    if kicked then
        print(('^1[br_ringmaster] late ban answer for %s -- removed after admitting^7')
            :format(license))
    end
end)

--- Ask br_ddb whether a license is banned, guaranteeing exactly one answer.
---
--- The timeout is armed BEFORE the question is asked. Arming it afterwards
--- looks equivalent and is not: if the event handler throws synchronously, the
--- timer never gets set and the caller waits forever.
--- @param license string
--- @param cb fun(banned: boolean, info: table)
local function askBanned(license, cb)
    nextReq = nextReq + 1
    local req = nextReq

    local answered = false
    local function once(banned, info)
        if answered then return end
        answered = true
        pending[req] = nil
        cb(banned, info)
    end

    pending[req] = once

    SetTimeout(ANSWER_TIMEOUT_MS, function()
        -- Admitting on timeout does not end our interest in the answer. Record
        -- the license so a late "banned" verdict can still remove them --
        -- see lateWatch above.
        if not answered then lateWatch[req] = license end
        once(false, { error = ('no answer within %dms'):format(ANSWER_TIMEOUT_MS) })
    end)

    TriggerEvent('br:ddb:banCheck', req, license)
end


AddEventHandler('playerConnecting', function(_name, _setKickReason, deferrals)
    local src = source

    -- A connect event without deferrals is not something to guess at. Bail
    -- before touching the API rather than erroring inside a handler that owes
    -- somebody a resolution.
    if type(deferrals) ~= 'table' or type(deferrals.defer) ~= 'function' then
        return
    end

    -- NO br_ddb, NO GATE, AND NO WAITING. Without this the gate still behaves
    -- correctly -- it asks nobody, times out, and fails open -- but it charges
    -- EVERY player five seconds on the connect screen to do it. A server that
    -- has not installed br_ddb would be slower for everyone and never say why.
    -- Checking the resource state is instant and turns that into a no-op.
    local ddbState = GetResourceState('br_ddb')
    if ddbState ~= 'started' then
        -- Said out loud rather than skipped quietly. A server whose ban gate is
        -- silently inert looks identical to one whose bans do not work, and
        -- this is the single most likely reason for the latter.
        print(('^3[br_ringmaster] gate: br_ddb is "%s", not "started" -- NO BAN CHECK^7')
            :format(tostring(ddbState)))
        return
    end

    deferrals.defer()

    -- REQUIRED. FiveM needs a tick between defer() and the first update()/done()
    -- or the call is dropped and the player hangs. This single Wait(0) is the
    -- difference between a working gate and the failure mode this whole file is
    -- written around.
    Wait(0)

    local byKind = BR.Identity and BR.Identity.ofPlayer(src)
    local license = byKind and BR.Identity.qualified('license', byKind.license)

    -- No license, no ban check. Bans key on license and nothing else, so
    -- there is no question to ask -- let them in rather than inventing an
    -- identifier to refuse them by.
    if not license then
        deferrals.done()
        return
    end

    deferrals.update('Checking your account...')

    askBanned(license, function(banned, info)
        if info.error then
            print(('^3[br_ringmaster] ban check failed for %s: %s -- allowing (fail open)^7')
                :format(license, tostring(info.error)))
            deferrals.done()
            return
        end

        if not banned then
            -- ONE LINE PER CONNECT, and worth the noise. Without it the gate is
            -- invisible exactly when it matters: "I banned them and they got in
            -- anyway" has four possible causes, and a silent admit cannot tell
            -- you whether the gate ran at all, found no row, or was never asked.
            -- At 48 slots this is a handful of lines a minute, and every server
            -- logs connects anyway.
            print(('^2[br_ringmaster] gate: %s not banned -- admitted^7'):format(license))
            deferrals.done()
            return
        end

        print(('^1[br_ringmaster] refused banned license %s (%s)^7')
            :format(license, tostring(info.reason)))

        -- done(reason) REFUSES the connection with that message shown to the
        -- player. done() with no argument admits them. One character between
        -- the two, so it is spelled out rather than left to be inferred.
        deferrals.done(rejection(info))
    end)
end)
