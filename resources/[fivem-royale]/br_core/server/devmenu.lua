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
-- NOT FROM THE LOBBY. Every lobby player stands frozen on the one lobby mark,
-- in one shared bucket, so a car spawned there would sit in every lobby
-- player's character shot. The answer is the menu's own lobby sentence,
-- `no match running`.
--
-- ═══ EXEMPT, AND YOU IN THE DRIVER'S SEAT (#426) ═══
--
-- The owner, 2026-11-01, answering the open question: "yes exempt dev menu
-- vehicles, and put me in the driver seat". And: "you're doing these spawn
-- checks server-side, yeah?" -- yes; every decision below is this server's.
--
-- EXEMPT: what this row builds is recorded, once the spawn has built it, by
-- BR.Vehicles.exemptDevMenuVehicle -- this file is its one caller, and
-- tools/verify.sh pins it here -- and from then on nobody is filed against
-- for sitting in it or for its gun, and the client's vehrefuse.lua neither
-- ejects anybody from it nor holds its gun off. The record is server memory,
-- written only on a server that started in dev mode; server/vehicles.lua, above
-- its occupancy detector, has the whole of it. brcar's vehicles are not in it.
--
-- SEATED: the asker is put in the driving seat by this server, through the
-- platform's own SetPedIntoVehicle -- an RPC its owning client (theirs) runs --
-- once a client holds the vehicle, and tried until the vehicle's own driving
-- seat says they are in it, for SEAT_WINDOW_MS. An NPC the platform put in the
-- seat is deleted first; another player in it ends the try. The vehicle still
-- lands clear of them by its size first, as spawnInFront places it. See `the
-- seat` below for the sources.
--
-- SO ONLY WHERE A SEAT IS FOR: ALIVE and WARMUP, the two states a player takes
-- a vehicle in -- client/vehrefuse.lua's gate. In the plane and the drop the
-- gamemode is carrying them, and a seat would pull them off the bus mid-flight;
-- downed or out, nobody drives. Those are refused before anything is built, in
-- one sentence of this file's own (NOT_SEATABLE).

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

-- ═══════════════════════════════════════════════════════════════════════════
-- THE SEAT (#426): "put me in the driver seat"
-- ═══════════════════════════════════════════════════════════════════════════
--
-- HOW, AND THE SOURCES. SetPedIntoVehicle is one of the platform's server RPC
-- natives -- `context_rpc 'SET_PED_INTO_VEHICLE'` in citizenfx/fivem's
-- ext/natives/rpc_spec_natives.lua -- so the server calls it and the client that
-- OWNS THE PED runs it: the asker's own. That client turns the vehicle's object
-- id into a handle as the call arrives and does not wait for it
-- (code/components/gta-net-five/src/ClientRPC.cpp: only an entity still being
-- created through an RPC waits; one the server setter made does not), so a call
-- that lands before the vehicle has reached the asker's machine does nothing.
-- Qbox's qbx.spawnVehicle (Qbox-project/qbx_core, modules/lib.lua) is the same
-- server setter and the same native, and it waits for a client to have the car
-- before it seats anybody. So this waits until a client OWNS the vehicle
-- (NetworkGetEntityOwner), calls the RPC, and calls it again every
-- SEAT_POLL_MS until the vehicle's own driving seat -- the live read the
-- occupancy detector trusts, not the ped's #4006 answer -- names the asker, for
-- SEAT_WINDOW_MS at most.
--
-- AN NPC IN THE DRIVING SEAT. The Cfx.re forum has a server setter vehicle
-- turning up with an ambient driver who drives it off (forum.cfx.re/t/4936285,
-- 2022; forum.cfx.re/t/4947251, where Cfx.re's Linden said in 2024 that it was
-- fixed in commit 631484ec). Whatever build this runs on, a driving seat
-- holding a ped that is not a player's (IsPedAPlayer, a server native) is
-- emptied by deleting that ped, and the asker is seated on a later pass. A
-- PLAYER in it ends the try: nobody is pulled out of a seat for this.
--
-- WHEN IT CANNOT: the vehicle never reaches a client, it is gone, or somebody
-- else is driving it. The vehicle stays where it landed, and the asker is told
-- once (SEAT_FAILED). A seat that stops making sense on the way -- the asker
-- died, boarded, left, or asked for another vehicle -- is dropped without a
-- word; nothing was promised for that.

--- The player states the vehicle row is taken in. See the header.
local SEATABLE = {
    [BR.PlayerState.ALIVE]  = true,
    [BR.PlayerState.WARMUP] = true,
}

--- This file's sentence for a press in any other state but the lobby's.
local NOT_SEATABLE = 'only in warmup, or alive in a match'

--- This file's sentence for a seat that could not be taken. `%s` is the model.
local SEAT_FAILED = '%s was built, but you could not be put in it'

--- How often a pending seat is tried. The roster's own sample rate.
local SEAT_POLL_MS = 250

--- How long a seat is tried for: Qbox waits five seconds for a client to own a
--- car it seats somebody in, and so does this.
local SEAT_WINDOW_MS = 5000

--- [asker] = { veh, model, untilMs }. One each: a second vehicle replaces the
--- first, which stays where it landed.
local seating = {}

--- The scheduler job, while anything is waiting to be seated.
local seatJob = nil

--- A FiveM BOOL, by the shared policy: 1 and true are yes, and 0 -- truthy in
--- Lua -- is no.
local isTrue = BR.NativeBool

--- @param veh integer @return boolean
local function stillThere(veh)
    if not DoesEntityExist then return false end
    local ok, v = pcall(DoesEntityExist, veh)
    return ok and isTrue(v)
end

--- Who is in the driving seat, by the vehicle's own seats. 0 for nobody.
--- @param veh integer @return integer
local function driverOf(veh)
    if not GetPedInVehicleSeat then return 0 end
    local ok, p = pcall(GetPedInVehicleSeat, veh, -1)
    return ok and math.tointeger(tonumber(p)) or 0
end

--- Is this ped a player's? A read that fails says yes: a player is never
--- deleted on a guess.
--- @param ped integer @return boolean
local function playersPed(ped)
    if not IsPedAPlayer then return true end
    local ok, v = pcall(IsPedAPlayer, ped)
    return not ok or isTrue(v)
end

--- Has the vehicle reached a client yet? An owner is a player's server id; -1
--- is nobody.
--- @param veh integer @return boolean
local function onAClient(veh)
    if not NetworkGetEntityOwner then return false end
    local ok, o = pcall(NetworkGetEntityOwner, veh)
    o = ok and math.tointeger(tonumber(o)) or nil
    return o ~= nil and o > 0
end

--- One try at one asker's seat.
--- @return string  'wait' | 'done' | 'failed' | 'dropped'
local function seatOne(src, s, now)
    local e = BR.Roster.get(src)
    if not e or not SEATABLE[e.state] or not e.ped or e.ped == 0 then
        return 'dropped'
    end
    if not stillThere(s.veh) then return 'failed' end
    local driver = driverOf(s.veh)
    if driver == e.ped then return 'done' end
    if now >= s.untilMs then return 'failed' end
    if driver ~= 0 then
        if playersPed(driver) then return 'failed' end
        pcall(DeleteEntity, driver)
        return 'wait'
    end
    if not onAClient(s.veh) then return 'wait' end
    pcall(SetPedIntoVehicle, e.ped, s.veh, -1)
    return 'wait'
end

--- The pass, every SEAT_POLL_MS while anybody is waiting, and gone after.
local function seatPass()
    local now = GetGameTimer()
    for src, s in pairs(seating) do
        local r = seatOne(src, s, now)
        if r ~= 'wait' then
            seating[src] = nil
            if r == 'failed' then refuse(src, SEAT_FAILED:format(s.model)) end
        end
    end
    if next(seating) == nil and seatJob ~= nil then
        BR.Sched.cancel(seatJob)
        seatJob = nil
    end
end

--- Seat the asker in what the row just built.
--- @param src integer @param veh integer @param model string
local function seatAsker(src, veh, model)
    seating[src] = { veh = veh, model = model, untilMs = GetGameTimer() + SEAT_WINDOW_MS }
    if seatJob == nil then
        seatJob = BR.Sched.every(SEAT_POLL_MS, 'devmenu.seat', seatPass)
    end
end

--- Vehicle spawner (#426): `vehicle <model> <type>`, brcar's spawn for the
--- asker, exempt, with them in it. See the header for why it is any model, and
--- in which states.
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
    -- AND ONLY WHERE A SEAT IS FOR (the header), before anything is built.
    if not (e and SEATABLE[e.state]) then
        answer(false, NOT_SEATABLE)
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
    -- EXEMPT, THEN SEATED: the record first, so the asker is never at its
    -- wheel for a sample before it is exempt.
    BR.Vehicles.exemptDevMenuVehicle(made.veh, made.hash, src)
    seatAsker(src, made.veh, model)
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
    if src then
        lastAt[src] = nil
        -- A SEAT FOR SOMEBODY WHO LEFT is nobody's: the id is handed out again.
        seating[src] = nil
    end
end)
