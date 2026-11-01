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
--   Storm pause     brstormfreeze    BR.Storm.setMatchFrozen server/storm.lua
--   Warmup pause    brwarmupfreeze   BR.Match.setMatchWarmupFrozen
--                                                            server/match.lua
--   Spawn airdrops  brairdrop now    BR.Airdrop.dropNow      server/airdrop.lua
--   Vehicle spawner brcar            BR.Vehicles.spawnInFront
--                                                            server/vehicles.lua
--
-- The two pauses are the one exception to "the verb's own body": the console
-- verbs hold EVERY match, and these hold one (below). They share the verbs'
-- record swap and deadline (holdOne, holdWarmup), not their every-match loop.
--
-- A refusal is the verb's own sentence. It goes to the player who pressed, as
-- a toast through BR.Server.notify -- the notice every refusal in this game
-- uses -- and to their F8, and to this console.
--
-- ═══ THE ASKER'S MATCH, NEVER THE NEWEST, NEVER EVERY ONE ═══
--
-- Matches run side by side, each in its own routing bucket. The console verbs
-- aim at BR.Server.latestMatch(), which is THE match with one running and
-- somebody else's with two (#291), or -- the two freezes -- at every match at
-- once. A press here comes from a player standing in a match, so Match state,
-- Spawn airdrops and both pauses act on BR.Server.matchOf(asker) and on
-- nothing else; from the lobby the pauses have no match and say so. Time and
-- weather are one override for the whole session -- the server sends one sky
-- -- so those two have no match to aim at and do what their verbs do.
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
-- Yubikey given here lands in dev-br-players, never in br-players.
--
-- EXCEPT WHERE br_ddb STARTED BEFORE DEV MODE WAS ON: it picks its tables once,
-- as it starts. So both gives ask br_ddb which tables it named
-- (BR.Debug.productionTables, server/debug.lua, answered by
-- br_ddb/server/tables.lua) and refuse unless it is the dev ones.
--
-- ═══ A GIVE NAMES ITS PLAYER BY A TOKEN, NOT ONLY BY SERVER ID ═══
--
-- The Player row is a list the server sent, and it can be out of date by the
-- time a row is pressed. Server ids are RECYCLED within the minute (server/
-- players.lua's note on #172), so a bare id could give Volts or a key to
-- whoever holds that id NOW. Every player the menu lists carries a token of
-- their roster entry -- a number that is never handed out twice -- and a give
-- names both. A token that no longer matches the connected player at that id
-- is refused in words, and the asker is sent the list as it stands.
--
-- ═══ EVERY ARGUMENT IS CHECKED HERE, AGAINST THE SAME LISTS THE ROWS SHOW ═══
--
-- An hour 0-23 or `reset`; a weather of BR.World.WEATHERS or `reset`; a state
-- of BR.Config.DevMenu.states; an amount of BR.Config.DevMenu.volts; a player
-- id and token; `on` or `off`; a model name by BR.Config.DevMenu.modelWord and
-- a sync tree of BR.Config.DevMenu.vehicleTypes. Anything else is a request no
-- row could have sent: it is dropped with the usage line on the asker's F8 and
-- nothing else. Every request spends the asker's slot, taken or not, and one
-- inside minIntervalMs of the last is dropped unread.
--
-- ═══ THE VEHICLE SPAWNER (#426): brcar's SPAWN, WITHOUT brcar's RULE ═══
--
-- Owner, 2026-11-01: "can you also add to our dev menu a vehicle spawner
-- menu? remember this needs to be a server-side entity ... For any that you
-- believe to be armed, allow them to be spawned here". So `vehicle <model>
-- <type>` runs BR.Vehicles.spawnInFront -- `brcar`'s own spawn, factored out
-- of the verb -- for the asker: the server setter, five meters in front of
-- them or as far as a wide one needs, in their routing bucket. And it runs it
-- for ANY model. brcar's allowlist pre-check is brcar's and stays in brcar;
-- here a Hydra is a Hydra.
--
-- THE SERVER CANNOT ASK THE GAME WHAT A MODEL IS. There is no server native
-- that says whether a name is a vehicle, or which sync tree it needs, so both
-- come from the client -- IsModelInCdimage, IsModelAVehicle and the
-- IsThisModelA* natives (client/devmenu.lua) -- and what is checked first is
-- their SHAPE: a plain model word, and one of the seven trees the platform
-- builds.
--
-- AND THEN THE TREE, AGAINST THE GAME'S OWN DATA (#426's review). A wrong
-- tree is not the asker's own car built wrong: every client checks the tree
-- as the vehicle reaches it and builds a stand-in for a model of another type
-- -- `adder plane` is a Cargo Plane -- in a bucket the whole warmup pad or
-- match shares (VEHICLE_TYPES' note in server/vehicles.lua). So a model
-- config/vehicle_models.lua has, which is every vehicle of the base game,
-- must be asked for as the tree the game builds it as. The rows always do,
-- so a line that names another tree was typed, and it is dropped like any
-- other request no row could have sent. Only a model that table does not
-- have, an add-on, is taken at the client's word.
--
-- NOT FROM THE LOBBY, which is the one place this differs from brcar. Every
-- lobby player stands frozen on the one lobby mark, in one shared bucket, so a
-- car spawned there would sit in every lobby player's character shot. The
-- answer is the menu's own lobby sentence, `no match running`. Everywhere
-- else -- the warmup pad, the plane and the drop, the match, downed or out --
-- it is brcar's rule: in front of whoever asked, in whatever bucket they are
-- in. In warmup and in a match the match's vehicle rules still hold:
-- client/vehrefuse.lua puts a player out of a refused vehicle, and
-- server/vehicles.lua's occupancy detector counts a driver in one. Neither is
-- excused for a dev menu car; that is the owner's open question on #426.

BR = BR or {}
BR.DevMenu = BR.DevMenu or {}

local D = BR.DevMenu

--- @return table BR.Config.DevMenu, read at call time
local function cfg() return BR.Config.DevMenu end

--- [src] = GetGameTimer() of the last request read from that player.
local lastAt = {}

--- [roster entry] = its token. WEAK-KEYED, so an entry that has left the
--- roster and everything else is collected; the token is never reused, so a
--- stale one can only ever match the entry it was made for.
local tokOf = setmetatable({}, { __mode = 'k' })
local nextTok = 0

--- @param e table  a roster entry
--- @return integer
local function tokenOf(e)
    local t = tokOf[e]
    if not t then
        nextTok = nextTok + 1
        t = nextTok
        tokOf[e] = t
    end
    return t
end

local USAGE = 'usage: brdevsv open | time <0-23|reset> | weather <name|reset> '
    .. '| match <state|skip> | volts <player id> <token> <amount> '
    .. '| yubikey <player id> <token> | storm <on|off> | warmup <on|off> | airdrop '
    .. '| vehicle <model> <type>  '
    .. '(the dev menu, /brdev or F10, runs this for you)'

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

--- The player a give names: its id and token words.
---
--- Returns the server id when both name the same connected player the list
--- showed; nil and a sentence when they named somebody who has since left (or
--- whose id somebody else now holds); nil alone when the words are not an id
--- and a token at all -- a request no row could have sent.
--- @param idWord string|nil
--- @param tokWord string|nil
--- @return integer|nil id
--- @return string|nil refusal
local function targetOf(idWord, tokWord)
    local n = math.tointeger(tonumber(idWord))
    local t = math.tointeger(tonumber(tokWord))
    if not n or n <= 0 or not t or t <= 0 then return nil, nil end
    local e = BR.Roster.get(n)
    if not e or e.state == BR.PlayerState.LEFT or tokOf[e] ~= t then
        return nil, ('player %d has left'):format(n)
    end
    return n, nil
end

--- The players the menu lists, THE ASKER FIRST and then everybody else by
--- server id -- the owner's "a player picked from a list with yourself first".
--- Nobody who has left. `name` is the roster's display name; the client strips
--- GTA's text codes from it before a row shows it. `tok` is what a give sends
--- back with the id -- see the header.
--- @param src integer
--- @return table { { id, tok, name }... }
function D.players(src)
    local out, others = {}, {}
    BR.Roster.each(function(e) return e.state ~= BR.PlayerState.LEFT end,
        function(id, e)
            local row = { id = id, tok = tokenOf(e), name = tostring(e.name or '') }
            if id == src then out[1] = row else others[#others + 1] = row end
        end)
    table.sort(others, function(a, b) return a.id < b.id end)
    for _, row in ipairs(others) do out[#out + 1] = row end
    return out
end

--- What the asker's menu shows: who it can give to, and the two pauses AS
--- THEY STAND FOR THE ASKER'S MATCH -- or, from the lobby, the session's.
--- @param src integer
--- @return table
function D.state(src)
    local m = BR.Server.matchOf(src)
    return {
        players = D.players(src),
        storm   = BR.Storm.isFrozen(m) == true,
        warmup  = BR.Match.warmupFrozen(m) == true,
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

--- brskip's own sentence for "there is no match", which is what a lobby press
--- that needs one is told.
local NO_MATCH = 'no match running'

ACTIONS.match = function(src, a, answer)
    local s = a[2]
    if not oneOf(cfg().states, s) then return false end
    local m = BR.Server.matchOf(src)
    if s == 'skip' then
        answer(BR.Match.skip(m))
        return true
    end
    -- FROM THE LOBBY, `brforce` FORMS A MATCH OUT OF THE WHOLE QUEUE. That is
    -- what a tester standing in the queue means by it; one who is not queued
    -- would be pulling everybody else into a match they are not in -- or,
    -- with nobody queued, forming an empty one that dissolves on the next
    -- tick. So a lobby press is taken only from somebody queued. `waiting`
    -- with no match is brforce's own refusal, below.
    if not m and s ~= BR.MatchState.WAITING
        and not (BR.Lobby and BR.Lobby.queuedMode and BR.Lobby.queuedMode(src)) then
        answer(false, NO_MATCH)
        return true
    end
    answer(BR.Match.force(s, m))
    return true
end

--- A give's player, or the refusal already answered. False for words no row
--- could have sent.
--- @return integer|nil|false
local function giveTarget(a, answer)
    local target, refusal = targetOf(a[2], a[3])
    if target then return target end
    if not refusal then return false end
    answer(false, refusal)
    return nil
end

ACTIONS.volts = function(_, a, answer)
    local amount = math.tointeger(tonumber(a[4]))
    if not oneOf(cfg().volts, amount) then return false end
    local target = giveTarget(a, answer)
    if target == false then return false end
    if not target then return true end
    local sent, why = BR.Debug.grantVolts(target, amount, answer)
    if not sent then answer(false, why) end
    return true
end

ACTIONS.yubikey = function(_, a, answer)
    local target = giveTarget(a, answer)
    if target == false then return false end
    if not target then return true end
    answer(BR.Terminal.devKey(target, true))
    return true
end

--- A pause: the asker's match and nothing else. From the lobby there is none.
--- @param set fun(m: table, on: boolean): boolean, string
local function pause(set)
    return function(src, a, answer)
        local on = onOff(a[2])
        if on == nil then return false end
        local m = BR.Server.matchOf(src)
        if not m then
            answer(false, NO_MATCH)
            return true
        end
        local _, line = set(m, on)
        answer(true, line)
        return true
    end
end

ACTIONS.storm = pause(function(m, on) return BR.Storm.setMatchFrozen(m, on) end)
ACTIONS.warmup = pause(function(m, on) return BR.Match.setMatchWarmupFrozen(m, on) end)

ACTIONS.airdrop = function(src, _, answer)
    local sited, line, outcome = BR.Airdrop.dropNow(BR.Server.matchOf(src))
    -- A `wait` IS NOT A REFUSAL: the drop stays queued and the tick retries it
    -- (brairdrop now's own note). Only a refusal, or a drop the storm turned
    -- down, is a toast.
    answer(sited or outcome == 'wait', line)
    return true
end

--- Vehicle spawner (#426): `vehicle <model> <type>`, brcar's spawn for the
--- asker. See the header for why it is any model, and why not from the lobby.
ACTIONS.vehicle = function(src, a, answer)
    local model = cfg().modelWord(a[2])
    local vtype = a[3]
    if not model or not oneOf(cfg().vehicleTypes, vtype) then return false end
    -- A MODEL OF THE BASE GAME, ONLY AS ITS OWN TREE (the header).
    local own = BR.Vehicles.modelTree(model)
    if own ~= nil and own ~= vtype then return false end

    -- THE LOBBY BUCKET, ASKED THE WAY server/roster.lua PICKS IT: a LOBBY
    -- player, or one with no match, is in the lobby's. A player on the way home
    -- from a match still carries its id and is already LOBBY.
    local e = BR.Roster.get(src)
    if (e and e.state == BR.PlayerState.LOBBY) or BR.Server.matchOf(src) == nil then
        answer(false, NO_MATCH)
        return true
    end

    local made, why = BR.Vehicles.spawnInFront(src, model, vtype)
    if not made then
        answer(false, why)
        return true
    end
    -- A CAR THE SERVER CANNOT SEE IS NOT A SUCCESS -- brcar's readout says the
    -- same, in capitals.
    if not made.exists then
        answer(false, ('%s was created and is already gone, or its handle never resolved')
            :format(model))
        return true
    end
    answer(true, ('%s (0x%08X) as %s, netId %d, bucket %s')
        :format(model, BR.NormHash(made.hash), vtype, made.netId, made.bucketNote))
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

    local verb = type(args[1]) == 'string' and args[1]:lower() or ''

    -- A PRESS TOO SOON IS DROPPED UNREAD. A PAUSE'S ROWS ARE SENT BACK: the
    -- library flips a pause box on the press itself, so a dropped press would
    -- leave the box saying what the server never did. Nothing else is sent, so
    -- a client that floods this costs one comparison a line.
    local last = lastAt[src]
    if last ~= nil and now - last < (cfg().minIntervalMs or 250) then
        if verb == 'storm' or verb == 'warmup' then push(src) end
        return 'too-soon'
    end
    -- EVERY REQUEST READ SPENDS THE SLOT, good or bad, so a flood of bad ones
    -- is held to the same rate as presses -- and to one usage line each.
    lastAt[src] = now

    if verb == 'open' then
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
