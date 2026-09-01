-- Is this player already in our Discord? Asked of Discord, once per connection.
--
-- WHAT IT IS FOR, AND THE ONLY THING IT IS FOR. server/community.lua sends every
-- player the address of our Discord and br_ui draws a card on the Help page from
-- it. The owner asked for that card to stop being shown to the people who are
-- already there (2026-08-31): "let's make it always show in the help page (unless
-- we know they're in the guild)". The parenthesis is this file.
--
-- ═══ THERE IS NO NATIVE FOR THIS, AND THERE IS NO CHEAPER ROUTE ═══
--
-- FiveM knows WHO a player is on Discord and nothing whatever about what servers
-- they are in. `GetPlayerIdentifiers` yields `discord:<snowflake>` -- and only
-- when their desktop client is running with the activity integration on, which is
-- opt-in and not ours to turn on; server/admin.lua's header has the long version
-- of that same limitation, because the Admin tab is gated on the same identifier.
-- Guild membership is a fact that lives at Discord, so somebody has to ask
-- Discord: one authenticated GET, from here, per connection. Every FiveM Discord
-- whitelist in the wild does exactly this and has since the feature existed.
--
-- ═══ IT DOES NOT GO THROUGH RINGMASTER, ON PURPOSE ═══
--
-- fivem-ringmaster/src/lib/discordRole.ts already calls this exact endpoint with
-- this exact token, and asking it would save us a credential on this box. It is
-- still forbidden: THE GAME MUST NEVER DEPEND ON RINGMASTER -- only the reverse
-- is allowed. server/grants.lua reads DynamoDB directly for the same reason, and
-- server/community.lua's header states it for the file this one serves. A Discord
-- card that came back wrong whenever the admin console was down would be a bug
-- nobody could explain from inside the game.
--
-- So the pattern is copied and the credential is not shared: our own convar, our
-- own call, and the same reading of the answers -- which is the part worth
-- copying, because that file learned it the expensive way. See readAnswer.
--
-- ═══ THE ONLY ANSWER THAT HIDES ANYTHING IS A CONFIRMED YES ═══
--
-- `member(src)` answers true, false or nil, and nil is not a soft false. No token
-- configured, no `discord:` identifier, a timeout, a 429, a 500, a guild we
-- cannot see, a player who dropped mid-lookup -- all nil, and the card shows.
-- Hiding on "don't know" would silently stop inviting exactly the people the card
-- exists for, which is the opposite of its purpose, and it would do it in the
-- states nobody watches: an unconfigured server, and Discord having a bad
-- afternoon.
--
-- ═══ THE TOKEN IS A SECRET AND LIVES WHERE SECRETS LIVE ═══
--
-- On a convar that is NEVER REPORTED, which is br_ringmaster/server/config.lua's
-- rule for the ingest secret, restated here because this is the second one. It is
-- not a br_lib/config/ value and it must never become one: every key in that
-- directory is printed at boot by main.lua's tunables block and read back out by
-- `brconfig` and the console's `configreport`. tools/verify.sh's console
-- capability boundary already fails the build if anything token-shaped is named
-- in configreport's allowlist. Nothing here prints the token, echoes a header, or
-- puts it anywhere a client can reach.

BR = BR or {}
BR.Guild = BR.Guild or {}

-- ---------------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------------

--- Read a convar, treating empty string as absent.
---
--- Verbatim from br_ringmaster/server/config.lua's `str`, for its reason:
--- GetConvar returns the default only when a convar is UNSET, so a
--- `set br_discord_bot_token ""` is SET and would otherwise look configured and
--- produce an authenticated request with no credential in it, forever.
local function convar(name)
    local v = GetConvar(name, '')
    if v == nil or v == '' then return nil end
    return v
end

--- A Discord snowflake, or nil.
---
--- DIGITS ONLY, AND THAT IS A URL CONTROL RATHER THAN TIDINESS. Both ids are
--- interpolated straight into the request path, so this is what makes escaping
--- unnecessary instead of merely unlikely to matter: nothing that is not a run of
--- digits ever reaches the URL. The length bound is Discord's own -- a snowflake
--- is a 64-bit integer, so twenty digits is the ceiling and thirty-two is slack.
local function snowflake(s)
    if type(s) ~= 'string' then return nil end
    if s == '' or #s > 32 then return nil end
    if s:find('%D') then return nil end
    return s
end

--- READ ONCE, AT LOAD, matching br_ringmaster/server/config.lua.
---
--- The alternative -- reading the convar per lookup -- would let the boot line
--- below and the running behaviour disagree about whether this feature is on, and
--- two homes for one setting with nothing comparing them is the defect this
--- project has paid for most. A convar set after boot applies on the next
--- `restart br_core`, and the boot line will say so when it does.
local TOKEN = convar('br_discord_bot_token')
local GUILD_RAW = convar('br_discord_guild_id')
local GUILD = snowflake(GUILD_RAW)

--- Both halves, or the feature is off.
---
--- A token with no guild id has nothing to ask about and a guild id with no token
--- cannot ask, so there is no useful half-configured state -- the same argument
--- br_ringmaster/server/config.lua makes about its url/secret pair.
--- @return boolean
function BR.Guild.configured()
    return TOKEN ~= nil and GUILD ~= nil
end

-- ---------------------------------------------------------------------------
-- The call
-- ---------------------------------------------------------------------------

--- Discord's REST API, pinned to a version.
---
--- v10 EXPLICITLY. An unversioned `discord.com/api/...` resolves to v6, which
--- Discord has deprecated for years; pinning is what stops this file changing
--- behaviour on a day nobody deployed anything.
local API = 'https://discord.com/api/v10/guilds/%s/members/%s'

--- Discord's documented shape for a bot's User-Agent.
---
--- NOT DECORATION. Discord's API reference requires `DiscordBot ($url,
--- $versionNumber)` and says requests without a valid one "may be blocked and
--- return a Cloudflare error" -- which would arrive here as a 403 with an HTML
--- body, i.e. as "unknown", i.e. as the card showing to everybody forever with
--- nothing in the console to say why.
local USER_AGENT = 'DiscordBot (https://blitz-royale.com, 1.0)'

--- Discord's "unknown member" JSON error code.
---
--- THE MOST DANGEROUS DETAIL IN THIS FILE, and it is borrowed whole from
--- fivem-ringmaster/src/lib/discordRole.ts, which records having got it wrong.
--- `GET /guilds/{guild}/members/{user}` answers 404 for BOTH "that user is not in
--- this guild" (10007) and "I cannot see that guild at all" (10004) -- which is
--- what a mistyped br_discord_guild_id, or a bot that has been removed from the
--- server, looks like. Reading the second as the first would tell us every player
--- on the server was a member, and take the card away from all of them.
local ERR_UNKNOWN_MEMBER = 10007

--- How long before we stop waiting for an answer that is not coming.
---
--- SIX SECONDS, WHICH IS DELIBERATELY ABOVE PerformHttpRequest's OWN CEILING.
--- That ceiling is a hardcoded five seconds and is not ours to move --
--- br_ringmaster/server/push.lua and server/handoff.lua both record the same fact
--- -- so on every ordinary failure the real callback lands first and this timer
--- never fires. It exists for the one case that would otherwise wedge the queue
--- below forever: a request that throws synchronously, or a callback that never
--- arrives at all. handoff.lua arms its timer BEFORE the request for exactly this
--- reason, and so does lookup().
local TIMEOUT_MS = 6000

--- Minimum gap between two calls to Discord.
---
--- ONE CALL AT A TIME, PACED, BECAUSE SIXTY PLAYERS ARRIVE AT ONCE. A match fills
--- from a lobby, so the realistic load is not one lookup an hour -- it is most of
--- a full server connecting inside a couple of minutes, and at server start it is
--- all of them. Discord's only published hard number is fifty requests a second
--- per bot; the per-route bucket for this endpoint is dynamic and announced in
--- headers rather than documented, so the honest engineering answer is to stay far
--- enough under whatever it turns out to be that we never find out. 250ms is four
--- a second: a 60-player fill costs fifteen seconds of wall clock, spent while
--- those players are still watching a loading screen.
---
--- AND NOTHING IS WAITING ON IT. A lookup that has not landed reads as nil, which
--- shows the card, which is the state the player would have been in anyway.
local GAP_MS = 250

--- How long a 429 stands the queue down for when Discord names no interval.
local BACKOFF_MS = 5000

--- The longest stand-down we will honour from a `retry_after`.
---
--- A CEILING ON SOMEBODY ELSE'S NUMBER. `retry_after` is read out of a response
--- body; a malformed or hostile one must not be able to park this queue for the
--- life of the process. A minute is far longer than any real bucket reset and
--- short enough that the queue always comes back.
local BACKOFF_MAX_MS = 60000

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

--- What Discord said. [src] = true | false. Absent means we do not know.
---
--- THREE STATES IN A TWO-STATE TABLE, and the absence is the third one. Writing
--- an unknown down as `false` is the single change that would break this feature
--- in the direction that cannot be seen: false is "Discord answered, and the
--- answer was no", and it is the answer that keeps the card.
local verdict = {}

--- Sources a lookup has already been started for. [src] = true
---
--- SEPARATE FROM `verdict` BECAUSE IT IS A DIFFERENT QUESTION. This one is "have
--- we spent a call on this connection", and it is what makes "one lookup per
--- connect at most" true rather than approximately true -- a lookup that resolved
--- to unknown leaves nothing in `verdict`, and a table that only remembered
--- answers would ask again on the next br:ready and again on the one after that.
local asked = {}

--- Callbacks for a lookup that has not answered yet. [src] = { fn, ... }
---
--- ALSO THE IN-FLIGHT MARKER. A non-nil entry means this source's lookup is
--- somewhere between the queue and its callback, which is what lets a second
--- br:ready arriving mid-flight attach to the first lookup rather than start a
--- second one.
local waiting = {}

--- Sources queued for a call, oldest first, and the set behind it.
local queue, queued = {}, {}

--- True while one request is out. One at a time, by construction.
local busy = false

--- Game-time in ms before which nothing may be sent. Moved by a 429.
local standDownUntil = 0

local stat = { asked = 0, member = 0, notMember = 0, unknown = 0, rateLimited = 0 }

--- Normalise a source to the key everything else uses.
---
--- `source` in a net event handler is a NUMBER and `source` in playerDropped
--- arrives as a STRING, and in Lua t[5] and t["5"] are different keys. server/
--- admin.lua carries the same note over the same fix, made after the un-normalised
--- version cleared nothing at all and grew its tables for the life of the process.
local function key(src)
    return tonumber(src) or src
end

-- ---------------------------------------------------------------------------
-- Reading one answer
-- ---------------------------------------------------------------------------

--- Turn one HTTP answer into true, false or nil.
---
--- SEPARATED FROM THE REQUEST SO EVERY BRANCH IS REACHABLE WITHOUT A NETWORK,
--- which is the arrangement fivem-ringmaster's `readMemberResponse` has and the
--- reason tools/test_guild.lua can walk all of them. It is a pure function of a
--- status and a body.
---
--- @param status number|nil  HTTP status, or a transport failure code
--- @param body string|nil    the response body, unparsed
--- @return boolean|nil  true = in the guild, false = not, nil = we did not learn
function BR.Guild.readAnswer(status, body)
    -- 200 IS THE WHOLE ANSWER. Unlike the console's role check, which has to read
    -- a `roles` array out of the member object, membership is answered by the
    -- status alone: Discord only returns a member object for a member. Nothing
    -- here parses a success body, so nothing here can be confused by one.
    if status == 200 then return true end

    if status == 404 then
        local code = nil
        if type(body) == 'string' and body ~= '' then
            local good, parsed = pcall(json.decode, body)
            if good and type(parsed) == 'table' then code = parsed.code end
        end
        if code == ERR_UNKNOWN_MEMBER then return false end
        -- 10004 (unknown guild), a bot removed from the guild, a guild id with a
        -- digit missing, or a 404 from something in front of Discord with no code
        -- in it at all. Every one of those is a statement about US, and reading it
        -- as a statement about the player is the mistake this constant exists to
        -- make impossible.
        return nil
    end

    -- 401 (the token is wrong), 403 (the bot cannot see this guild, or Cloudflare
    -- refused a request it did not like the shape of), 429, 5xx, and the negative
    -- or zero statuses PerformHttpRequest reports for a transport failure. None of
    -- them is a statement about whether this person is in the Discord.
    return nil
end

--- How long to stand the queue down after a 429, in ms.
---
--- `retry_after` IS SECONDS AND MAY BE FRACTIONAL, which is the one detail worth
--- getting right: reading it as milliseconds turns a two-second bucket reset into
--- a two-millisecond one and produces a tight loop of 429s, and Discord bans an
--- IP that generates ten thousand invalid requests -- 401s, 403s and 429s -- in
--- ten minutes. Pure, so the arithmetic is testable.
--- @param body string|nil
--- @return number ms
function BR.Guild.backoffMs(body)
    local after = nil
    if type(body) == 'string' and body ~= '' then
        local good, parsed = pcall(json.decode, body)
        if good and type(parsed) == 'table' then after = tonumber(parsed.retry_after) end
    end
    if after == nil or after <= 0 then return BACKOFF_MS end
    local ms = math.floor(after * 1000.0 + 0.5)
    if ms > BACKOFF_MAX_MS then return BACKOFF_MAX_MS end
    return ms
end

-- ---------------------------------------------------------------------------
-- The queue
-- ---------------------------------------------------------------------------

local drain

--- Record an answer and tell whoever was waiting for it.
local function settle(src, member)
    if member ~= nil then verdict[src] = member end

    if member == true then
        stat.member = stat.member + 1
    elseif member == false then
        stat.notMember = stat.notMember + 1
    else
        stat.unknown = stat.unknown + 1
    end

    local cbs = waiting[src]
    waiting[src] = nil
    if cbs == nil then return end
    for i = 1, #cbs do
        -- pcall, because a callback belongs to another file and a throw in one of
        -- them must not take the queue's `busy` flag down with it -- that would
        -- wedge every lookup after this one, permanently, on somebody else's bug.
        pcall(cbs[i], member)
    end
end

--- Ask Discord about one source.
local function lookup(src)
    -- THE PLAYER MAY HAVE GONE while this sat in the queue. `waiting` is cleared
    -- on drop, so an empty one here means there is nobody left to answer -- and
    -- spending a Discord call to fill a cache we are about to forget is the one
    -- kind of waste this file can produce on its own.
    if waiting[src] == nil then
        busy = false
        drain()
        return
    end

    local discordId = BR.Guild.discordIdOf(src)
    if discordId == nil then
        settle(src, nil)
        busy = false
        drain()
        return
    end

    stat.asked = stat.asked + 1

    -- ANSWERED EXACTLY ONCE, whichever of the two paths gets here first.
    local done = false
    local function finish(member, retryMs)
        if done then return end
        done = true
        if retryMs then standDownUntil = GetGameTimer() + retryMs end
        settle(src, member)
        busy = false
        -- The gap is spent AFTER an answer rather than before the next request,
        -- so a slow Discord does not also get a faster question rate.
        SetTimeout(GAP_MS, drain)
    end

    -- ARMED BEFORE THE REQUEST, which is server/handoff.lua's idiom and is not
    -- equivalent to arming it after: a PerformHttpRequest that throws
    -- synchronously would otherwise leave `busy` true and this queue stopped for
    -- the life of the process.
    SetTimeout(TIMEOUT_MS, function() finish(nil, nil) end)

    PerformHttpRequest(API:format(GUILD, discordId), function(status, body)
        if status == 429 then
            stat.rateLimited = stat.rateLimited + 1
            -- NOT RETRIED. A 429 is "we do not know", the card stays up, and this
            -- connection's one lookup is spent. Re-queueing it would turn the
            -- busiest moment on the server -- everybody connecting at once -- into
            -- the moment we send Discord the most traffic, which is how a rate
            -- limit becomes an IP ban.
            finish(nil, BR.Guild.backoffMs(body))
            return
        end
        finish(BR.Guild.readAnswer(status, body), nil)
    end, 'GET', '', {
        -- THE ONLY PLACE THE TOKEN IS USED. It is never printed, never returned,
        -- never put in a payload and never echoed on an error path -- the response
        -- handler above reads a status and a body and nothing else.
        ['Authorization'] = 'Bot ' .. TOKEN,
        ['User-Agent']    = USER_AGENT,
    })
end

--- Send the next queued lookup, if the queue is idle and Discord is not sulking.
drain = function()
    if busy then return end

    local src = table.remove(queue, 1)
    if src == nil then return end
    queued[src] = nil

    busy = true

    local wait = standDownUntil - GetGameTimer()
    if wait > 0 then
        SetTimeout(wait, function() lookup(src) end)
    else
        lookup(src)
    end
end

-- ---------------------------------------------------------------------------
-- The surface
-- ---------------------------------------------------------------------------

--- The bare Discord snowflake FiveM reports for a source, or nil.
---
--- A RESTATEMENT OF server/admin.lua's `discordIdOf`, NOT A CALL INTO IT, and the
--- three lines are copied on purpose. server/grants.lua makes the same argument
--- about licenses: deriving it here does not depend on another file having loaded
--- or having handled the same event first, and handler order within one event is
--- load order. Unqualified, because Discord's own API wants the bare snowflake.
--- @param src number|string
--- @return string|nil
function BR.Guild.discordIdOf(src)
    if not BR.Identity then return nil end
    local byKind = BR.Identity.ofPlayer(src)
    if type(byKind) ~= 'table' then return nil end
    return snowflake(byKind.discord)
end

--- What we know about this player, right now.
--- @param src number|string
--- @return boolean|nil  true = in the guild, false = not, nil = we do not know
function BR.Guild.member(src)
    return verdict[key(src)]
end

--- Start this connection's one lookup, if it has not been started already.
---
--- `cb` IS CALLED ONLY FOR A LOOKUP THIS CALL IS WAITING ON, and never for one
--- that has already settled. A caller that wants the settled answer reads
--- `member()`; this is the notification that a NEW answer has arrived, so the
--- caller's re-send happens once rather than on every ask.
---
--- @param src number|string
--- @param cb function|nil  called with true/false/nil when the answer lands
function BR.Guild.ask(src, cb)
    if not BR.Guild.configured() then return end

    src = key(src)

    -- ALREADY IN FLIGHT: attach, do not start a second one. Two br:ready events a
    -- frame apart -- a reconnect, a `restart br_ui` -- are the ordinary way this
    -- happens.
    if waiting[src] ~= nil then
        if cb then waiting[src][#waiting[src] + 1] = cb end
        return
    end

    -- ALREADY SPENT. Not "already answered": a lookup that came back unknown has
    -- used this connection's call and must not be repeated. See `asked`.
    if asked[src] then return end

    asked[src] = true
    waiting[src] = cb and { cb } or {}

    if not queued[src] then
        queued[src] = true
        queue[#queue + 1] = src
    end
    drain()
end

-- FORGOTTEN ON DROP, AND THE FORGETTING IS LOAD-BEARING TWICE OVER. A server id
-- is recycled within the minute, so a verdict left behind is a verdict handed to
-- the next person to hold that number -- and it is the WRONG DIRECTION of wrong:
-- an inherited `true` takes the card away from somebody who never asked Discord
-- anything. It also means a player who joins the Discord and reconnects is asked
-- again, which is the only remedy this feature has and the one it should have.
AddEventHandler('playerDropped', function()
    local src = key(source)
    verdict[src] = nil
    asked[src] = nil
    -- Cleared LAST of the three, because lookup() reads it as "is anybody still
    -- listening" and an entry left here would spend a call on a connection that
    -- has gone.
    waiting[src] = nil
    queued[src] = nil
end)

--- What to print at boot. Lines rather than prints, so this stays readable
--- without a game -- the same shape br_ringmaster/server/config.lua's report has.
--- @return table lines
--- @return boolean configured
function BR.Guild.report()
    local lines = {}

    if BR.Guild.configured() then
        -- THE GUILD ID IS NOT A SECRET AND THE TOKEN IS. Print one; print only
        -- the LENGTH of the other, so a truncated paste is diagnosable without the
        -- value reaching a console log or an operator's scrollback.
        lines[#lines + 1] = ('guild     %s'):format(GUILD)
        lines[#lines + 1] = ('token     set (%d chars)'):format(#TOKEN)
    elseif GUILD_RAW ~= nil and GUILD == nil then
        -- SET AND UNUSABLE IS ITS OWN STATE, and it is the one worth shouting
        -- about: the operator believes this is on. A snowflake is digits.
        lines[#lines + 1] = 'guild     br_discord_guild_id is not a snowflake -- ignored'
        lines[#lines + 1] = '          it must be the guild id, digits only'
    else
        lines[#lines + 1] = 'guild     not configured -- the Discord card shows to everybody'
    end

    return lines, BR.Guild.configured()
end

--- Counters, for whoever is debugging this from the console.
--- @return table
function BR.Guild.stats()
    return {
        asked = stat.asked, member = stat.member, notMember = stat.notMember,
        unknown = stat.unknown, rateLimited = stat.rateLimited,
    }
end

-- REGISTERED AFTER server/main.lua's, so this lands under its banner rather than
-- above it: handlers for one event run in registration order, which is load
-- order, and main.lua is the first server_script in the manifest.
AddEventHandler('onResourceStart', function(res)
    if res ~= GetCurrentResourceName() then return end

    -- NOTHING IS PRIMED FOR THE PLAYERS ALREADY HERE, deliberately. A
    -- `restart br_core` replays no br:ready, so nothing would read the answers
    -- these lookups produced -- it would be sixty Discord calls whose only effect
    -- is to fill a table. The next br:ready, from a reconnect or a
    -- `restart br_ui`, asks for real.
    local lines = BR.Guild.report()
    for _, l in ipairs(lines) do
        print('[br_core]   ' .. l)
    end
end)
