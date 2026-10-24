-- The dev menu (#422), server half: the one door every row's press comes
-- through.
--
-- Owner, 2026-10-24: "What I need now is a dev-only menu using the same UI as
-- our gun store. It should control things like time, weather, match state,
-- give volts, give Yubikeys, Storm pause, warmup pause, spawn airdrops"
--
-- ═══ A FRONT END, NOT A SECOND IMPLEMENTATION ═══
--
-- Every row is an existing console verb, and every press runs THAT VERB'S OWN
-- BODY, factored out of the command so both doors call one piece of code:
--
--   Time            brtime           BR.WorldSky.setTime     server/world.lua
--   Weather         brweather        BR.WorldSky.setWeather  server/world.lua
--   Match state     brforce, brskip  BR.Match.force / .skip  server/match.lua
--   Give volts      brvolts          BR.Debug.grantVolts     server/debug.lua
--   Give Yubikeys   brterminalsv key BR.Terminal.devKey      server/terminal.lua
--   Storm pause     brstormfreeze    BR.Storm.setFrozen      server/storm.lua
--   Warmup pause    brwarmupfreeze   BR.Match.setWarmupFrozen server/match.lua
--   Spawn airdrops  brairdrop now    BR.Airdrop.dropNow      server/airdrop.lua
--
-- A refusal is the verb's own sentence. It goes to the player who pressed, as
-- a toast through BR.Server.notify -- the notice every refusal in this game
-- uses -- and to their F8, and to this console.
--
-- ═══ THE ASKER'S MATCH, NEVER THE NEWEST ═══
--
-- Matches run side by side, each in its own routing bucket. The console verbs
-- aim at BR.Server.latestMatch(), which is THE match with one running and
-- somebody else's with two (#291). A press here comes from a player standing
-- in a match, so Match state and Spawn airdrops act on BR.Server.matchOf(asker)
-- and on nothing else. Time and weather are one override for the whole
-- session, and the two pauses are session flags every later match inherits,
-- so those four have no match to aim at and do what their verbs do.
--
-- ═══ HOW A PRESS GETS HERE: A STANDARD DEV COMMAND ═══
--
-- Every request is the server command `brdevsv`, which br_core/client/
-- devmenu.lua runs with ExecuteCommand -- server/props.lua's route, which the
-- owner asked for by name on 2026-10-03 ("please fix it in the repo, so it's a
-- standard dev command"). The client has no command by that name, so FiveM
-- sends the line here and runs it as that player. Two gates, both on EVERY
-- request:
--
--   devgate.lua's wrap   dev mode by the convars, read at call time
--   BR.DevMenu.allowed   dev mode as this server STARTED (BR.Server.devMode),
--                        `== true` -- a dev mode switched on live, without
--                        restarting br_core, is not dev mode here
--
-- REGISTERED UNRESTRICTED ON PURPOSE, as `brpropsv` is: restricted would ask
-- the player for an ACE. The owner's rule is "anyone on a dev-mode server",
-- so dev mode is the whole authorization -- and it is a dev box's own session
-- that every row changes. On a box without dev mode nothing here runs: the
-- wrap prints which gate closed, on this console, and that is all.
--
-- ═══ THE TWO GIVES WRITE STORED PROFILES, AND ON A DEV BOX THOSE ARE dev- ROWS
--     ═══
--
-- br_ddb forces every table it names to `dev-` whenever sv_devMode or
-- br_devMode is on (js-src/br_ddb/src/prefix.js; DEPLOY.md, "A dev box uses
-- dev- tables"). Those are the convars both gates above read, so a Volts or a
-- Yubikey given here lands in dev-br-players, never in br-players. See
-- docs/devmenu.md for the one way round that, which is not a menu's to close.
--
-- ═══ EVERY ARGUMENT IS CHECKED HERE, AGAINST THE SAME LISTS THE ROWS SHOW ═══
--
-- An hour 0-23 or `reset`; a weather of BR.World.WEATHERS or `reset`; a state
-- of BR.Config.DevMenu.states; an amount of BR.Config.DevMenu.volts; a target
-- that is a connected player; `on` or `off`. Anything else is a request no row
-- could have sent: it is dropped with the usage line on the asker's F8 and
-- nothing else. So is a request inside minIntervalMs of the last one taken.

BR = BR or {}
BR.DevMenu = BR.DevMenu or {}

local D = BR.DevMenu

--- @return table BR.Config.DevMenu, read at call time
local function cfg() return BR.Config.DevMenu end

--- [src] = GetGameTimer() of the last request taken from that player.
local lastAt = {}

local USAGE = 'usage: brdevsv open | time <0-23|reset> | weather <name|reset> '
    .. '| match <state|skip> | volts <player id> <amount> | yubikey <player id> '
    .. '| storm <on|off> | warmup <on|off> | airdrop  (the dev menu, /brdev or F10, '
    .. 'runs this for you)'

--- IS THIS A DEV BOX, AS br_core STARTED IT? Asked first on every request.
---
--- `== true`, NEVER truthiness: a missing BR.Server or a renamed field must read
--- as "no" rather than as an error thrown halfway through a decision -- the
--- reason BR.Admin.devTrusted gives for the same comparison.
--- @return boolean
function D.allowed()
    return BR.Server ~= nil and BR.Server.devMode == true
end

--- One line on the asker's F8, and this console.
--- @param src integer @param text string
local function tell(src, text)
    print(('[br_core] dev menu (client %d): %s'):format(src, text))
    TriggerClientEvent(BR.Net.DEVMENU_DEV, src, text)
end

--- A refusal: the verb's own sentence, as a toast and on F8. NEVER A PLAYER'S
--- NAME IN IT -- every sentence the verbs hand back names a player by server id,
--- and tools/check_notice_names.lua is the gate on the rest.
--- @param src integer @param text string
local function refuse(src, text)
    tell(src, text)
    BR.Server.notify(src, text, 'warn')
end

--- Is `v` one of `list`?
--- @param list table @param v any
--- @return boolean
local function oneOf(list, v)
    for _, x in ipairs(list or {}) do
        if x == v then return true end
    end
    return false
end

--- A connected player's server id out of a request word, or nil.
--- @param word string|nil
--- @return integer|nil
local function targetOf(word)
    local n = math.tointeger(tonumber(word))
    if not n or n <= 0 then return nil end
    local e = BR.Roster.get(n)
    if not e or e.state == BR.PlayerState.LEFT then return nil end
    return n
end

--- The players the menu lists, THE ASKER FIRST and then everybody else by
--- server id -- the owner's "a player picked from a list with yourself first".
--- Nobody who has left. `name` is the roster's display name; the client strips
--- GTA's text codes from it before a row shows it.
--- @param src integer
--- @return table { { id, name }... }
function D.players(src)
    local out, others = {}, {}
    BR.Roster.each(function(e) return e.state ~= BR.PlayerState.LEFT end,
        function(id, e)
            local row = { id = id, name = tostring(e.name or '') }
            if id == src then out[1] = row else others[#others + 1] = row end
        end)
    table.sort(others, function(a, b) return a.id < b.id end)
    for _, row in ipairs(others) do out[#out + 1] = row end
    return out
end

--- What the asker's menu shows: who it can give to, and the two pauses.
--- @param src integer
--- @return table
function D.state(src)
    return {
        players = D.players(src),
        storm   = BR.Storm.isFrozen() == true,
        warmup  = BR.Match.warmupFrozen() == true,
    }
end

--- @param src integer
local function push(src)
    TriggerClientEvent(BR.Net.DEVMENU_STATE, src, D.state(src))
end

--- `on` / `off`, or nil.
--- @param word string|nil
--- @return boolean|nil
local function onOff(word)
    if word == 'on' then return true end
    if word == 'off' then return false end
    return nil
end

--- THE ROWS. Each takes the request's words and `answer`, and answers once --
--- now, or when a round trip lands -- with (ok, line). Each returns false for a
--- request no row could have sent, and then nothing has happened.
local ACTIONS = {}

ACTIONS.time = function(_, a, answer)
    local h = a[2]
    if h ~= 'reset' then
        local n = math.tointeger(tonumber(h))
        if not (n and BR.World.validHour(n)) then return false end
        h = tostring(n)
    end
    local kind, line = BR.WorldSky.setTime(h, nil)
    answer(kind == 'set' or kind == 'reset', line or h)
    return true
end

ACTIONS.weather = function(_, a, answer)
    local w = a[2]
    if not (w == 'reset' or (type(w) == 'string' and BR.World.WEATHER[w] == true)) then
        return false
    end
    local kind, line = BR.WorldSky.setWeather(w)
    answer(kind == 'set' or kind == 'reset', line or w)
    return true
end

ACTIONS.match = function(src, a, answer)
    local s = a[2]
    if not oneOf(cfg().states, s) then return false end
    local m = BR.Server.matchOf(src)
    if s == 'skip' then
        answer(BR.Match.skip(m))
    else
        answer(BR.Match.force(s, m))
    end
    return true
end

ACTIONS.volts = function(_, a, answer)
    local target = targetOf(a[2])
    local amount = math.tointeger(tonumber(a[3]))
    if not target or not oneOf(cfg().volts, amount) then return false end
    local sent, why = BR.Debug.grantVolts(target, amount, answer)
    if not sent then answer(false, why) end
    return true
end

ACTIONS.yubikey = function(_, a, answer)
    local target = targetOf(a[2])
    if not target then return false end
    answer(BR.Terminal.devKey(target, true))
    return true
end

ACTIONS.storm = function(_, a, answer)
    local on = onOff(a[2])
    if on == nil then return false end
    local _, line = BR.Storm.setFrozen(on)
    answer(true, line)
    return true
end

ACTIONS.warmup = function(_, a, answer)
    local on = onOff(a[2])
    if on == nil then return false end
    local _, line = BR.Match.setWarmupFrozen(on)
    answer(true, line)
    return true
end

ACTIONS.airdrop = function(src, _, answer)
    answer(BR.Airdrop.dropNow(BR.Server.matchOf(src)))
    return true
end

--- One request, from one player. THE WHOLE DOOR, in this order: dev mode, a
--- player, the rate, the verb and its words -- and only then the row.
---
--- Returned for the test and for nothing else: 'off' | 'console' | 'player' |
--- 'too-soon' | 'bad' | 'open' | 'ran'.
--- @param src integer
--- @param args table   the command's words
--- @param now number   GetGameTimer()
--- @return string
function D.request(src, args, now)
    if not D.allowed() then
        print('[br_core] brdevsv refused: this server did not start in dev mode')
        return 'off'
    end
    if src <= 0 then
        print('  brdevsv is the dev menu\'s door; a player opens the menu with /brdev')
        return 'console'
    end
    if not BR.Roster.get(src) then return 'player' end

    -- A PRESS TOO SOON IS DROPPED, AND THE ROWS ARE SENT ANYWAY: the library
    -- flips a pause box on the press itself, so a dropped press would leave the
    -- box saying what the server never did.
    local last = lastAt[src]
    if last ~= nil and now - last < (cfg().minIntervalMs or 250) then
        print(('[br_core] dev menu (client %d): dropped, too soon after the last'):format(src))
        push(src)
        return 'too-soon'
    end

    local verb = type(args[1]) == 'string' and args[1]:lower() or ''
    if verb == 'open' then
        lastAt[src] = now
        push(src)
        return 'open'
    end

    local act = ACTIONS[verb]
    if not act then
        tell(src, USAGE)
        return 'bad'
    end

    -- ONE ANSWER PER PRESS, whichever arm gives it: what the verb said, then the
    -- rows as they now stand -- so a pause whose checkbox the library already
    -- flipped is put back by the server's own answer when it did not take.
    local answered = false
    local function respond(ok, line)
        if answered then return end
        answered = true
        line = tostring(line or '')
        if ok then tell(src, line) else refuse(src, line) end
        push(src)
    end

    print(('[br_core] dev menu: %s (%d) -- %s')
        :format(GetPlayerName(src) or '?', src, table.concat(args, ' ')))
    if not act(src, args, respond) then
        tell(src, USAGE)
        return 'bad'
    end
    lastAt[src] = now
    return 'ran'
end

-- THE DOOR. Registered through devgate.lua's wrap, so with dev mode off it
-- prints which gate closed and runs nothing. `false` is `restricted` -- see
-- the header.
RegisterCommand('brdevsv', function(source, args)
    D.request(tonumber(source) or 0, args or {}, GetGameTimer())
end, false)

AddEventHandler('playerDropped', function()
    local src = tonumber(source)
    if src then lastAt[src] = nil end
end)
