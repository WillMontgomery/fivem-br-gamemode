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

    THE ONE THING HERE THAT FAILS CLOSED is the dev-mode join allowlist. With
    dev mode on (BR.Dev.on()), a join the ban check did not refuse must also
    hold br_lib/config/allowlist.lua's Discord role, and anything short of
    Discord confirming it is a refusal. It runs AFTER the ban check and inside
    the same deferral, so a banned player is always told about the ban and never
    about the allowlist. With dev mode off none of it runs. See the allowlist
    function further down.
    When this file is not there to do it -- br_ringmaster stopped, restarting,
    or started with this file broken -- br_core/server/guild.lua refuses the
    join instead. See gateArmed, at the bottom.

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

--- Can this value be called?
---
--- NOT `type(v) == 'function'`, AND THIS COST AN ENTIRE DEBUGGING SESSION.
--- FiveM passes functions across the runtime boundary as function REFERENCES:
--- tables carrying a `__call` metamethod. So the deferrals object's members
--- arrive as
---
---     done = table   defer = table   update = table   presentCard = table
---
--- every one of them perfectly callable, and every one of them failing a naive
--- `type(x) == 'function'` test. The gate refused to act on every connect
--- because of that single wrong predicate -- silently, until it was made to
--- say so.
---
--- Lua's own idiom is to ask whether a thing can be called rather than what it
--- is, which is what this does and what the original should have done.
local function callable(v)
    if type(v) == 'function' then return true end
    if type(v) ~= 'table' then return false end
    local mt = getmetatable(v)
    return mt ~= nil and mt.__call ~= nil
end

--- The player-facing rejection message.
---
--- WRITTEN FOR THE PERSON BEING REFUSED, not for the admin. It answers the
--- three things they will otherwise ask in Discord: what happened, why, and
--- whether it ends. The reason text comes from the console and was stripped of
--- control characters at that boundary (see the console's lib/actions.ts) --
--- it is displayed, never executed, and never interpolated into a command.
---
--- AND SINCE 2026-08-20 IT ALSO SAYS WHERE TO ASK. The fourth thing they will
--- otherwise do is find the Discord on their own, or not; the owner asked for
--- the invitation to be on the message. It is appended HERE rather than at the
--- two places this string is used, because both of them -- the deferral and the
--- late-answer removal -- would otherwise need to remember to, and one of them
--- forgetting is a ban notice that differs from every other ban notice for no
--- reason anybody could see. With `br_discordUrl` unset the text is returned
--- exactly as composed above.
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

    local text = ('You are banned from this server.\n\nReason: %s\n%s')
        :format(reason, when)

    -- GUARDED FOR THE SAME REASON kick.lua GUARDS IT: a missing appeal.lua must
    -- cost the sentence, never the refusal. A nil call inside a deferral is the
    -- one failure this file is written around -- it would leave the player on
    -- the connecting screen forever, banned and never told so.
    return BR.Ring.withAppeal and BR.Ring.withAppeal(text) or text
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

--- req -> { req, ban }, for a dev-mode join whose ban check timed out and whose
--- deferral is still open on the allowlist.
---
--- THE HOLE lateWatch CANNOT CLOSE. In dev mode a timed-out ban check admits
--- nobody yet: it goes on to allowlist() and holds the deferral while Discord is
--- asked. A late "banned" landing in that window would reach dropByLicense,
--- which walks GetPlayers() -- and a connection still deferring is not in it, so
--- nobody would be removed and the role answer would admit them for good. So the
--- ban is handed to the deferral instead, and allowlist() refuses with it
--- whatever Discord says. Cleared when that deferral ends.
local lateDoor = {}

AddEventHandler('br:ddb:banResult', function(req, banned, info)
    local resolve = pending[req]
    if resolve then
        pending[req] = nil
        resolve(banned and true or false, info or {})
        return
    end

    -- No pending resolver: this answer lost the race with our timeout. Only a
    -- "banned" verdict is actionable now.
    local license = lateWatch[req]
    local door = lateDoor[req]
    if not license and not door then return end
    lateWatch[req] = nil
    lateDoor[req] = nil

    if not banned or (info or {}).error then return end

    -- STILL AT THE DOOR, so refused there, with this notice, when allowlist()
    -- ends. No license is needed for this one: nobody has to be found again.
    if door then
        door.ban = info or {}
        return
    end

    local reason = rejection(info or {})
    local kicked = BR.Ring.dropByLicense and BR.Ring.dropByLicense(license, reason)
    if kicked then
        print(('^1[br_ringmaster] late ban answer for %s -- removed after admitting^7')
            :format(license))
    end
end)

--- Ask br_ddb whether this CONNECTION is banned, guaranteeing exactly one answer.
---
--- TWO IDENTIFIERS SINCE fivem-ringmaster#38, AND ONE ANSWER. `ringmaster-bans`
--- is keyed on a qualified identifier, and blitz-bot files a ban under
--- `discord:<snowflake>` for somebody an admin banned in Discord whom the game
--- has never met -- so there is no license to file it under and, until now,
--- nothing that would ever read it. That row was a record of a decision and not
--- a closed door.
---
--- BOTH KEYS GO IN ONE REQUEST rather than two `askBanned` calls, and that is
--- not tidiness. Two calls would mean two deferral answers to reconcile, two
--- timers, and a rule about which answer wins written HERE -- in the file whose
--- one job is "always resolve, exactly once". br_ddb does both lookups and
--- applies the rule (`effective`, the one shared with the console), so this
--- file's three rules are untouched: one question, one answer, one done().
---
--- The timeout is armed BEFORE the question is asked. Arming it afterwards
--- looks equivalent and is not: if the event handler throws synchronously, the
--- timer never gets set and the caller waits forever.
--- @param license string|nil qualified, or nil when FiveM reported none
--- @param discord string|nil qualified `discord:...`, or nil
--- @param cb fun(banned: boolean, info: table, req: integer)
local function askBanned(license, discord, cb)
    nextReq = nextReq + 1
    local req = nextReq

    local answered = false
    local function once(banned, info)
        if answered then return end
        answered = true
        pending[req] = nil
        cb(banned, info, req)
    end

    pending[req] = once

    SetTimeout(ANSWER_TIMEOUT_MS, function()
        -- Admitting on timeout does not end our interest in the answer. Record
        -- the license so a late "banned" verdict can still remove them --
        -- see lateWatch above.
        --
        -- THE LICENSE AND NOT THE DISCORD ID, even when the discord row is what
        -- the late answer will be about. `dropByLicense` is the only removal
        -- this file has and it matches on license; a connection without one
        -- cannot be found again once it is in, so it is simply not watched.
        -- That gap is bounded by the same 5s and is the price of failing open.
        if not answered and license then lateWatch[req] = license end
        once(false, { error = ('no answer within %dms'):format(ANSWER_TIMEOUT_MS) })
    end)

    -- EMPTY STRINGS AND NEVER nil, WHICH IS THE ONE THING IN THIS CHANGE THAT IS
    -- NOT ABOUT BANS. A player with no license and a Discord ban is the case the
    -- second lookup exists for, and it is exactly the case that would put a nil
    -- in the MIDDLE of this argument list. Whether FiveM's msgpack packs an
    -- embedded nil or truncates the array there is not something this repo can
    -- answer offline, and the game box is production -- so the question is
    -- removed rather than researched: both arguments are always strings, and
    -- br_ddb reads '' as "no such identifier" on both.
    TriggerEvent('br:ddb:banCheck', req, license or '', discord or '')
end

-- ---------------------------------------------------------------------------
-- The dev allowlist
-- ---------------------------------------------------------------------------

--- How long we wait for br_core to say whether a dev-mode join holds the role.
---
--- ABOVE br_core/server/guild.lua'S OWN 6s REQUEST TIMEOUT, so a lookup that is
--- sent at once and fails lands its real verdict first. NOT ABOVE EVERY LOOKUP'S
--- WORST CASE, and no number would be: a lookup queued behind another request
--- (up to 6s plus a 250ms gap) or behind a 429 stand-down (up to a minute) can
--- reach this timer with Discord perfectly healthy. When it fires the join is
--- REFUSED, not admitted, and the number travels with the question so br_core
--- stops spending a call on a lookup this gate has already given up on.
local ROLE_TIMEOUT_MS = 10000

--- What a dev-mode join is told when the allowlist does not let it in.
---
--- ONE SENTENCE FOR EVERY REASON. The reason goes to the console, which logs
--- it; the player is told the fact.
local ALLOWLIST_REFUSAL = 'This server is restricted to allowlisted players.'

--- req -> function(verdict), exactly as `pending` is for the ban check.
local rolePending = {}

AddEventHandler('br:guild:roleResult', function(req, verdict)
    local resolve = rolePending[req]
    if not resolve then return end
    rolePending[req] = nil
    resolve(verdict)
end)

--- Ask br_core whether this Discord id holds the allowlist role, guaranteeing
--- exactly one answer. askBanned's shape, timer first, for askBanned's reason.
--- @param discordId string  the bare snowflake
--- @param cb fun(verdict: string)  'held' is the only verdict that admits
local function askRole(discordId, cb)
    nextReq = nextReq + 1
    local req = nextReq

    local answered = false
    local function once(verdict)
        if answered then return end
        answered = true
        rolePending[req] = nil
        cb(verdict)
    end

    rolePending[req] = once

    SetTimeout(ROLE_TIMEOUT_MS, function()
        -- NO lateWatch HERE. A late answer has nothing to undo: nobody was
        -- admitted on this timeout, so there is nobody to remove.
        once(('no answer within %dms'):format(ROLE_TIMEOUT_MS))
    end)

    TriggerEvent('br:guild:roleCheck', req, discordId, ROLE_TIMEOUT_MS)
end

--- The dev-mode join allowlist. Called only once no ban stands in the way.
---
--- FAILS CLOSED, the opposite of the ban check and on purpose. A ban list that
--- cannot be read must not lock everybody out of the public server; an
--- allowlist that cannot be read must not let everybody into a dev one. So
--- every state short of Discord confirming the role -- no identifier, br_core
--- not running, no token, a timeout, a 429, not a member -- refuses.
--- @param who string  what the log lines name
--- @param discordId string|nil  the bare snowflake, or nil when FiveM reported none
--- @param deferrals table
--- @param door table|nil  this join's lateDoor slot, when its ban check timed out
local function allowlist(who, discordId, deferrals, door)
    --- EVERY WAY OUT GOES THROUGH HERE, so a late ban is looked at on all of
    --- them: an admit it must turn into a refusal, and a refusal that must be the
    --- ban notice rather than the allowlist sentence.
    --- @param admit boolean
    --- @param why string|nil  what the log names on a refusal
    local function finish(admit, why)
        if door then
            lateDoor[door.req] = nil
            if door.ban then
                print(('^1[br_ringmaster] refused banned connection %s (%s) -- late ban answer^7')
                    :format(who, tostring(door.ban.reason)))
                deferrals.done(rejection(door.ban))
                return
            end
        end

        if admit then
            print(('^2[br_ringmaster] gate: %s holds the allowlist role -- admitted^7')
                :format(who))
            deferrals.done()
            return
        end

        print(('^3[br_ringmaster] gate: refused %s -- dev allowlist: %s^7')
            :format(who, tostring(why)))
        deferrals.done(ALLOWLIST_REFUSAL)
    end

    if not discordId then
        finish(false, 'no discord identifier')
        return
    end

    -- NOBODY TO ASK, SO NO TEN SECONDS SPENT FINDING THAT OUT. The same instant
    -- check the ban path makes for br_ddb, refusing where that one admits.
    local coreState = GetResourceState('br_core')
    if coreState ~= 'started' then
        finish(false, ('br_core is "%s", not "started"'):format(tostring(coreState)))
        return
    end

    deferrals.update('Checking your account...')

    askRole(discordId, function(verdict)
        finish(verdict == 'held', verdict)
    end)
end


-- Printed once when the file loads. If this line is absent from the console at
-- boot, the gate is not installed at all -- which is invisible from the game
-- side and looks exactly like a ban that does not work.
print('^5[br_ringmaster]^7 ban gate armed')

AddEventHandler('playerConnecting', function(_name, _setKickReason, deferrals)
    local src = source

    -- ENTRY LOG BEFORE ANY BRANCH, because both early returns below used to be
    -- silent -- so a connect that skipped the gate produced no output at all
    -- and was indistinguishable from the handler never running. That cost a
    -- real debugging session: `brban` proved the license was banned and
    -- readable while the player still walked in, with nothing in the console
    -- either way.
    print(('^5[br_ringmaster] gate: connect from %s (deferrals=%s)^7')
        :format(tostring(src), type(deferrals)))

    -- A connect event without a usable deferrals object is not something to
    -- guess at. Bail before touching the API rather than erroring inside a
    -- handler that owes somebody a resolution.
    --
    -- THE SHAPE IS CHECKED, THEN DUMPED WHEN IT DISAGREES. The first version
    -- asserted `type(deferrals.defer) == 'function'` and returned silently when
    -- that failed -- which is exactly what happened on the live server: the
    -- table arrived, `defer` was not a plain function, and the gate declined to
    -- act while saying nothing. An assumption about a third-party API's shape
    -- deserves to print what it actually found rather than just disagreeing.
    if type(deferrals) ~= 'table' then
        print(('^3[br_ringmaster] gate: deferrals is %s, not a table -- CANNOT REFUSE^7')
            :format(type(deferrals)))
        return
    end

    if not (callable(deferrals.defer) and callable(deferrals.done)) then
        -- Kept loud, and kept dumping the shape. If FiveM ever changes this
        -- object again, the next person gets the answer in one connect instead
        -- of an evening -- which is exactly what this cost the first time.
        print('^3[br_ringmaster] gate: deferrals members are not callable. Keys present:^7')
        for k, v in pairs(deferrals) do
            print(('^3    %s = %s (callable: %s)^7')
                :format(tostring(k), type(v), tostring(callable(v))))
        end
        return
    end

    -- NO br_ddb, NO GATE, AND NO WAITING. Without this the gate still behaves
    -- correctly -- it asks nobody, times out, and fails open -- but it charges
    -- EVERY player five seconds on the connect screen to do it. A server that
    -- has not installed br_ddb would be slower for everyone and never say why.
    -- Checking the resource state is instant and turns that into a no-op.
    -- READ ONCE PER CONNECT, so one connection is never judged by two answers if
    -- the convar changes while it waits. BR.Dev is @br_lib/shared/devgate.lua's,
    -- the first script this resource loads.
    local dev = BR.Dev ~= nil and BR.Dev.on() == true

    local ddbState = GetResourceState('br_ddb')
    local ddbUp = ddbState == 'started'
    if not ddbUp then
        -- Said out loud rather than skipped quietly. A server whose ban gate is
        -- silently inert looks identical to one whose bans do not work, and
        -- this is the single most likely reason for the latter.
        print(('^3[br_ringmaster] gate: br_ddb is "%s", not "started" -- NO BAN CHECK^7')
            :format(tostring(ddbState)))
        -- NO BAN LIST IS NOT NO ALLOWLIST. In dev mode the join still defers
        -- and goes to allowlist() below, just without a ban to wait for.
        if not dev then return end
    end

    deferrals.defer()

    -- REQUIRED. FiveM needs a tick between defer() and the first update()/done()
    -- or the call is dropped and the player hangs. This single Wait(0) is the
    -- difference between a working gate and the failure mode this whole file is
    -- written around.
    Wait(0)

    -- MAINTENANCE FIRST, BEFORE THE BAN LOOKUP. Draining refuses everybody, so
    -- there is nothing to learn from a DynamoDB round trip -- and the drain
    -- answer is already in memory from the poller, so this refusal is instant
    -- where the ban path costs a network call. Turning somebody away quickly
    -- with a real explanation beats making them wait to be turned away.
    if BR.Ring.draining and BR.Ring.draining() then
        print(('^3[br_ringmaster] gate: refused %s -- maintenance draining^7')
            :format(tostring(src)))
        deferrals.done(BR.Ring.drainMessage())
        return
    end

    local byKind = BR.Identity and BR.Identity.ofPlayer(src)
    local license = byKind and BR.Identity.qualified('license', byKind.license)

    -- THE SECOND IDENTIFIER, AND IT IS ONLY SOMETIMES THERE. FiveM reports
    -- `discord:` only when the player has Discord's activity integration
    -- switched on, which is opt-in -- so most connections carry no such
    -- identifier and ask exactly the one question they always did. Qualified
    -- through BR.Identity, never interpolated by hand: `parse` strips the
    -- prefix and the table is keyed on the string WITH it, so a lookup for
    -- `280...` instead of `discord:280...` is a perfectly valid GetItem that
    -- finds no row and reads as "never banned".
    local discord = byKind and BR.Identity.qualified('discord', byKind.discord)

    -- NEITHER IDENTIFIER, NO BAN CHECK. There is no question to ask -- let them
    -- in rather than inventing an identifier to refuse them by.
    --
    -- THIS USED TO SAY "NO LICENSE, NO BAN CHECK" and admit anybody FiveM gave
    -- no license for. That was correct while bans keyed on license and nothing
    -- else; it is not correct now, because a `discord:`-keyed ban is precisely
    -- a ban on somebody the game does not know, and skipping the lookup for
    -- exactly the people it was written for would be the bug this change is
    -- about, in a new place.
    -- Once no ban stands in the way: in, or in dev mode, on to the allowlist.
    -- `door` is this join's lateDoor slot when its ban check timed out.
    local function letIn(who, door)
        if dev then
            allowlist(who, byKind and byKind.discord, deferrals, door)
            return
        end
        deferrals.done()
    end

    -- No br_ddb, so no ban to wait for. Only dev mode gets this far without it.
    if not ddbUp then
        letIn(tostring(src))
        return
    end

    if not license and not discord then
        if dev then
            letIn(tostring(src))
            return
        end
        print('^3[br_ringmaster] gate: connecting player has no license or discord id -- admitted^7')
        deferrals.done()
        return
    end

    deferrals.update('Checking your account...')

    -- What the log lines below name. Both when we have both, so a refusal says
    -- which identifiers were actually asked about -- "I banned them and they
    -- got in anyway" is answered by knowing what was looked up.
    local asked = license or discord
    if license and discord then asked = license .. ' + ' .. discord end

    askBanned(license, discord, function(banned, info, req)
        if info.error then
            print(('^3[br_ringmaster] ban check failed for %s: %s -- %s^7')
                :format(asked, tostring(info.error),
                    dev and 'no ban check (fail open)' or 'allowing (fail open)'))
            -- A LATE ANSWER CAN STILL COME, and in dev mode this deferral stays
            -- open on the allowlist while it might. See lateDoor.
            local door = nil
            if dev then
                door = { req = req }
                lateDoor[req] = door
            end
            letIn(asked, door)
            return
        end

        if not banned then
            -- ONE LINE PER CONNECT, and worth the noise. Without it the gate is
            -- invisible exactly when it matters: "I banned them and they got in
            -- anyway" has four possible causes, and a silent admit cannot tell
            -- you whether the gate ran at all, found no row, or was never asked.
            -- At 48 slots this is a handful of lines a minute, and every server
            -- logs connects anyway.
            print(('^2[br_ringmaster] gate: %s not banned%s^7')
                :format(asked, dev and '' or ' -- admitted'))
            letIn(asked)
            return
        end

        print(('^1[br_ringmaster] refused banned connection %s (%s)^7')
            :format(asked, tostring(info.reason)))

        -- done(reason) REFUSES the connection with that message shown to the
        -- player. done() with no argument admits them. One character between
        -- the two, so it is spelled out rather than left to be inferred.
        deferrals.done(rejection(info))
    end)
end)

-- THE PROOF THAT THE HANDLER ABOVE EXISTS, for br_core/server/guild.lua. In dev
-- mode br_core refuses every join itself unless this answers, because a
-- br_ringmaster that is stopped, mid-restart, or started with this file broken
-- has no gate in it, and a dev allowlist with no gate is an open door.
--
-- DIRECTLY AFTER THE HANDLER, WITH NOTHING BETWEEN THEM THAT CAN THROW. A load
-- error anywhere above leaves neither registered, so br_core refuses; with both
-- registered br_core stands aside. There is no state in which both defer the
-- same join, which is what keeps a ban notice from racing an allowlist refusal.
exports('gateArmed', function() return true end)
