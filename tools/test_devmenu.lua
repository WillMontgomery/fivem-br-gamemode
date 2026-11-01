-- Unit tests for the dev menu (#422).
--
-- Owner, 2026-10-24: "What I need now is a dev-only menu using the same UI as
-- our gun store. It should control things like time, weather, match state,
-- give volts, give Yubikeys, Storm pause, warmup pause, spawn airdrops"
--
-- ═══ WHAT A PLAYTEST CANNOT TELL APART, AND THIS CAN ═══
--
-- From a chair, every failure of this menu looks like "I pressed it and nothing
-- happened" -- or worse, like "I pressed it and it worked", on a box where it
-- must not exist at all. A gate that let one request through on the public
-- box, a row that sent the wrong word, an hour of 24 that reached the clock, a
-- storm pause aimed at another match, a toast that never came: each is a few
-- lines here.
--
--   PART A  br_core/server/devmenu.lua behind the REAL br_lib/shared/devgate.lua
--           and the REAL config: the gate on every request (the convar AND the
--           started dev mode, `== true`), the console and strangers refused,
--           every argument checked against the same lists the rows are built
--           from, every row's dispatch to its console verb's own body -- with
--           the ASKER'S match, never the newest -- the refusal as a toast and
--           on F8, the rows pushed back after every answer, the rate limit.
--   PART B  br_core/client/devmenu.lua over the REAL client/menu.lua and a
--           model of the vendored library: the owner's labels and nothing
--           else, no mouse and no buttons, F10 mapped only once dev mode reads
--           on, /brdev behind the dev gate, every row's exact `brdevsv` line,
--           the server's answer applied in place, names stripped of GTA's text
--           codes, and nothing rebuilt per keypress.
--   PART C  the exact lines PART B's rows ran, typed into PART A's server.
--
-- The console verbs' bodies themselves -- BR.WorldSky.setTime and the rest --
-- are driven through their commands by the suites that own them
-- (test_shared, test_roster, test_storm, test_airdrop, test_stats,
-- test_yubikey); here they are stubs that record what they were asked.
--
-- ═══ THE VEHICLE SPAWNER (#426) IS THE EXCEPTION, AND ITS SPAWN IS REAL ═══
--
-- Owner, 2026-11-01: "remember this needs to be a server-side entity". The
-- body is brcar's spawn, BR.Vehicles.spawnInFront, and it is loaded for real
-- -- br_core/server/vehicles.lua over the natives it calls, modeled the way
-- tools/test_roster.lua models them for brcar -- so the server setter's
-- arguments, the position in front of the asker and the routing bucket are
-- asserted on what the native was handed. On the client: the rows built from
-- a modeled GetAllVehicleModels (classes, names, the model-name fallback, the
-- sort, the Armed marks, the left-out class), the sync tree every kind of
-- model is asked as, GTA's keyboard over the open menu (and the keys that
-- close it), and the library's trail back through the submenus.
--
-- Run via tools/verify.sh, or directly:  lua tools/test_devmenu.lua

local realPrint = print
local ROOT = 'resources/[fivem-royale]/'

local function loadAll(files)
    for _, f in ipairs(files) do
        local chunk, err = loadfile(ROOT .. f)
        if not chunk then
            realPrint('\27[31mload error\27[0m ' .. f .. ': ' .. tostring(err))
            os.exit(1)
        end
        chunk()
    end
end

-- ---------------------------------------------------------------- harness ---

local pass, fail = 0, 0
local group = ''

local function describe(name) group = name end

local function ok(cond, name, detail)
    if cond then
        pass = pass + 1
    else
        fail = fail + 1
        realPrint(('\27[31mFAIL\27[0m %s > %s%s'):format(group, name,
            detail and ('\n       ' .. tostring(detail)) or ''))
    end
end

local function eq(got, want, name)
    ok(got == want, name, ('got %s, want %s'):format(tostring(got), tostring(want)))
end

local consoleLines = {}
print = function(...)
    local parts = {}
    for i = 1, select('#', ...) do parts[i] = tostring((select(i, ...))) end
    consoleLines[#consoleLines + 1] = table.concat(parts, ' ')
end

local function said(pat)
    for _, l in ipairs(consoleLines) do
        if l:find(pat, 1, true) then return true end
    end
    return false
end

local function words(line)
    local out = {}
    for w in tostring(line):gmatch('%S+') do out[#out + 1] = w end
    return out
end

--- GetHashKey, as FiveM hands it to Lua on either side: Jenkins one-at-a-time
--- over the LOWER-CASED name, and SIGNED. The signed form is the one a model
--- hash arrives in, and the one BR.Config.IsArmedVehicle has to normalize
--- (BR.NormHash's reason) -- a stub answering unsigned would prove nothing.
--- @param s string
--- @return integer
local function hashOf(s)
    local h = 0
    s = tostring(s):lower()
    for i = 1, #s do
        h = (h + s:byte(i)) & 0xFFFFFFFF
        h = (h + (h << 10)) & 0xFFFFFFFF
        h = (h ~ (h >> 6)) & 0xFFFFFFFF
    end
    h = (h + (h << 3)) & 0xFFFFFFFF
    h = (h ~ (h >> 11)) & 0xFFFFFFFF
    h = (h + (h << 15)) & 0xFFFFFFFF
    if h >= 0x80000000 then h = h - 0x100000000 end
    return h
end
if hashOf('rhino') ~= 0x2EA68690 or hashOf('adder') ~= -1216765807 then
    realPrint('\27[31mhashOf is broken\27[0m')
    os.exit(1)
end

-- =========================================================================
-- PART A -- the server
-- =========================================================================

local svCommands, toClient, notices, calls, convars, roster, matches, clock
local onDropped

--- The vehicle spawner's natives (#426): what the server setter was handed,
--- where each entity and player stands in routing buckets, and where each
--- ped is and which way it faces.
local created, entityBucket, playerBucket, pedPos, pedHeading, nextVeh

--- The eight trees the platform builds -- CREATE_VEHICLE_SERVER_SETTER
--- throws on anything else, and so does the stub (tools/test_roster.lua's
--- reason: a stub that cannot fail the way the platform fails certifies a
--- broken caller).
local SETTER_TYPES = {
    automobile = true, bike = true, boat = true, heli = true,
    plane = true, submarine = true, trailer = true, train = true,
}

--- A fresh server: the real gate, the real config, the real door; every verb
--- body it calls is a recorder -- but the vehicle spawner's, which is the real
--- br_core/server/vehicles.lua over modeled natives.
local function bootServer(opts)
    opts = opts or {}
    BR = nil
    svCommands, toClient, notices, calls, consoleLines = {}, {}, {}, {}, {}
    convars = { sv_devMode = (opts.convar == false) and 'false' or 'true' }
    clock = 100000
    onDropped = nil

    -- ═══ THE SPAWN'S NATIVES, AS tools/test_roster.lua MODELS THEM FOR brcar ═══
    created, entityBucket, nextVeh = {}, {}, 500
    -- Player 3 stands in match A's bucket, facing north at 100, 200, 30;
    -- player 1 in match B's; player 5 in the lobby's.
    playerBucket = { [1] = 1002, [3] = 1001, [5] = 0 }
    pedPos = { [1001] = { 10.0, 20.0, 5.0 }, [1003] = { 100.0, 200.0, 30.0 },
               [1005] = { -50.0, -60.0, 70.0 } }
    pedHeading = {}
    function GetHashKey(s) return hashOf(s) end
    function CreateVehicleServerSetter(hash, vtype, x, y, z, heading)
        created[#created + 1] = { hash = hash, vtype = vtype, x = x, y = y, z = z,
                                  heading = heading }
        if not SETTER_TYPES[vtype] or opts.createThrows then
            error(('CREATE_VEHICLE_SERVER_SETTER: Invalid entity type %s'):format(tostring(vtype)))
        end
        if opts.createFail then return 0 end
        nextVeh = nextVeh + 1
        return nextVeh
    end
    if opts.noSetter then CreateVehicleServerSetter = nil end
    -- A FIVEM BOOL: 1 and 0, and 0 is truthy (test_roster's reason).
    function DoesEntityExist(h)
        if h == nil or h == 0 or opts.vanish then return 0 end
        return 1
    end
    function GetEntityCoords(ped)
        if opts.coordsThrow then error('Tried to access invalid entity') end
        local p = pedPos[ped]
        return p and { x = p[1], y = p[2], z = p[3] } or nil
    end
    function GetEntityHeading(ped) return pedHeading[ped] or 0.0 end
    function GetPlayerRoutingBucket(src) return playerBucket[tonumber(src)] end
    function SetEntityRoutingBucket(ent, bucket) entityBucket[ent] = bucket end
    function GetEntityRoutingBucket(ent) return entityBucket[ent] end
    function NetworkGetNetworkIdFromEntity(ent) return ent + 1000 end

    function GetGameTimer() return clock end
    function GetCurrentResourceName() return 'br_core' end
    function GetConvar(n, d)
        local v = convars[n]
        if v == nil then return d end
        return v
    end
    function RegisterCommand(name, fn, restricted)
        svCommands[name] = { fn = fn, restricted = restricted }
    end
    function RegisterNetEvent() end
    function AddEventHandler(name, fn)
        if name == 'playerDropped' then onDropped = fn end
    end
    function TriggerClientEvent(name, target, data)
        toClient[#toClient + 1] = { name = name, target = target, data = data }
    end
    function GetPlayerName(src) return 'Player' .. tostring(src) end

    loadAll({
        'br_lib/shared/devgate.lua',
        'br_lib/shared/enums.lua',
        'br_lib/shared/protocol.lua',
        'br_lib/shared/world.lua',
        'br_lib/shared/geo.lua',
        'br_lib/config/vehicles.lua',
        'br_lib/config/devmenu.lua',
    })

    -- THREE MATCHES, AND THE ASKER IS NOT IN THE NEWEST. Player 3 stands in
    -- match A; match B is newer; player 5 is in the lobby.
    matches = {
        A = { id = 0xA1, seq = 1, state = 'playing' },
        B = { id = 0xB2, seq = 2, state = 'warmup' },
    }
    roster = {
        [1] = { name = 'Alpha', state = BR.PlayerState.ALIVE, matchId = 0xB2, ped = 1001 },
        [2] = { name = 'Bravo', state = BR.PlayerState.LEFT,  matchId = 0xA1 },
        [3] = { name = 'Me~r~', state = BR.PlayerState.ALIVE, matchId = 0xA1, ped = 1003 },
        [5] = { name = 'Echo',  state = BR.PlayerState.LOBBY, ped = 1005 },
    }

    local function rec(name, ...)
        calls[#calls + 1] = { name = name, args = table.pack(...) }
    end

    BR.Server = {
        devMode = (opts.devMode == nil) and true or opts.devMode,
        matchOf = function(src)
            local e = roster[src]
            if not e or not e.matchId then return nil end
            for _, m in pairs(matches) do
                if m.id == e.matchId then return m end
            end
            return nil
        end,
        latestMatch = function() return matches.B end,
        notify = function(target, text, tone)
            notices[#notices + 1] = { target = target, text = text, tone = tone }
        end,
    }
    BR.Roster = {
        get = function(src) return roster[src] end,
        each = function(pred, fn)
            for src, e in pairs(roster) do
                if not pred or pred(e) then fn(src, e) end
            end
        end,
        -- server/vehicles.lua schedules its sample pass on this at load.
        sampleIntervalMs = function() return 250 end,
    }
    BR.Sched = { every = function() end }
    -- THE PAUSES ARE PER MATCH: each match carries its own, and the session's
    -- (the console verbs') answers for a player with no match. The every-match
    -- console forms are recorded so a test can say the menu never reached them.
    BR.Storm = {
        isFrozen = function(m)
            if m and m.stormFrozen ~= nil then return m.stormFrozen end
            return opts.sessionStorm == true
        end,
        setMatchFrozen = function(m, on)
            rec('setMatchFrozen', m, on)
            local was = BR.Storm.isFrozen(m)
            m.stormFrozen = on
            if was == on then return false, 'storm already ' .. (on and 'frozen' or 'running') end
            return true, on and 'storm FROZEN' or 'storm THAWED'
        end,
        setFrozen = function(on) rec('setFrozen', on) end,
    }
    BR.Match = {
        warmupFrozen = function(m)
            if m and m.warmupFrozen ~= nil then return m.warmupFrozen end
            return opts.sessionWarmup == true
        end,
        setMatchWarmupFrozen = function(m, on)
            rec('setMatchWarmupFrozen', m, on)
            m.warmupFrozen = on
            return true, on and 'warmup FROZEN' or 'warmup THAWED'
        end,
        setWarmupFrozen = function(on) rec('setWarmupFrozen', on) end,
        force = function(s, m)
            rec('force', s, m)
            if opts.forceRefuses then return false, 'no match to dissolve' end
            return true, 'admin forced'
        end,
        skip = function(m)
            rec('skip', m)
            return false, 'warmup has no timer to skip'
        end,
    }
    BR.WorldSky = {
        setTime = function(a, b)
            rec('setTime', a, b)
            return (a == 'reset') and 'reset' or 'set', 'brtime: ' .. tostring(a)
        end,
        setWeather = function(a)
            rec('setWeather', a)
            return (a == 'reset') and 'reset' or 'set', 'brweather: ' .. tostring(a)
        end,
    }
    BR.Debug = {
        grantVolts = function(target, amount, done)
            rec('grantVolts', target, amount, done)
            if opts.voltsUnsent then return false, 'brvolts: br_ddb is not started, so there is nothing to write to.' end
            return true, nil
        end,
    }
    BR.Terminal = {
        devKey = function(target, give)
            rec('devKey', target, give)
            if opts.keyRefused then return false, ('%d: already holds one'):format(target) end
            return true, ('%d now holds a key'):format(target)
        end,
    }
    BR.Airdrop = {
        dropNow = function(m)
            rec('dropNow', m)
            if opts.dropWaits then
                return false, 'wait (drop 2, manual -- perMatch is 1 and this ignores it)', 'wait'
            end
            return false, ('airdrops only run during PLAYING (match %s is %s)')
                :format(tostring(m and m.id), tostring(m and m.state)), nil
        end,
    }
    -- Player 5 stands in the lobby, queued only when a test says so.
    BR.Lobby = {
        queuedMode = function(src)
            return (opts.queued and opts.queued[src]) and 'solo' or nil
        end,
    }

    -- THE REAL SPAWN (#426), BEFORE THE DOOR: server/vehicles.lua answers for
    -- BR.Vehicles at call time, and its own playerDropped handler is the one
    -- the door's replaces in this harness.
    loadAll({ 'br_core/server/vehicles.lua', 'br_core/server/devmenu.lua' })
end

--- The token the server lists player `id` under, opening the menu for `asker`
--- to get it. The clock moves past the slot that spent.
local function tokenFor(asker, id)
    clock = clock + 1000
    BR.DevMenu.request(asker, { 'open' }, clock)
    clock = clock + 1000
    local st
    for _, x in ipairs(toClient) do
        if x.target == asker and x.name == 'br:devmenu:state' then st = x.data end
    end
    for _, pl in ipairs(st and st.players or {}) do
        if pl.id == id then return tostring(pl.tok) end
    end
    return nil
end

--- Type a `brdevsv` line as player `src`, through the command FiveM would run.
local function typed(src, line)
    local w = words(line)
    if w[1] == 'brdevsv' then table.remove(w, 1) end
    svCommands.brdevsv.fn(src, w, line)
end

local function callsOf(name)
    local out = {}
    for _, c in ipairs(calls) do
        if c.name == name then out[#out + 1] = c end
    end
    return out
end

local function sentTo(src, event)
    local out = {}
    for _, s in ipairs(toClient) do
        if s.target == src and s.name == event then out[#out + 1] = s end
    end
    return out
end

local function lastState(src)
    local all = sentTo(src, 'br:devmenu:state')
    return all[#all] and all[#all].data or nil
end

describe('server: the door is a standard dev command')
do
    bootServer()
    ok(svCommands.brdevsv ~= nil, 'brdevsv is registered')
    eq(svCommands.brdevsv and svCommands.brdevsv.restricted, false,
       'unrestricted, as brpropsv is: restricted would ask the player for an ACE')
    eq(BR.Net.DEVMENU_STATE, 'br:devmenu:state', 'the state event is in the one protocol table')
    eq(BR.Net.DEVMENU_DEV, 'br:devmenu:dev', 'and so is the F8 line')
end

describe('server: no dev mode, no menu -- every request refused, with no other effect')
do
    -- ═══ THE CONVAR OFF: devgate.lua's wrap ═══
    bootServer({ convar = false })
    for _, line in ipairs({ 'open', 'time 21', 'weather RAIN', 'match warmup',
                            'volts 3 1000', 'yubikey 3', 'storm on', 'warmup on',
                            'airdrop', 'vehicle hydra plane' }) do
        typed(3, 'brdevsv ' .. line)
    end
    eq(#calls, 0, 'with dev mode off, not one verb body is reached')
    eq(#created, 0, 'and no vehicle is built (#426)')
    eq(#toClient, 0, 'nothing is sent to anybody')
    eq(#notices, 0, 'and nobody is shown anything')
    ok(said('brdevsv is dev-mode only'), 'the wrap says on this console which gate closed')

    -- ═══ THE CONVAR ON, BUT THIS SERVER DID NOT START IN DEV MODE ═══
    --
    -- `set br_devMode true` typed live without restarting br_core: the wrap
    -- reads the convar and opens, BR.Server.devMode is what the server started
    -- as and does not. Both are asked; this one is the second.
    bootServer({ devMode = false })
    typed(3, 'brdevsv storm on')
    typed(3, 'brdevsv open')
    clock = clock + 1000
    typed(3, 'brdevsv vehicle adder automobile')
    eq(#calls, 0, 'a dev mode switched on live is not dev mode to the menu')
    eq(#created, 0, 'and builds no vehicle')
    eq(#toClient, 0, 'and it answers nobody')

    -- ═══ `== true`, NEVER TRUTHINESS ═══
    bootServer({ devMode = 1 })
    typed(3, 'brdevsv storm on')
    eq(#calls, 0, 'a devMode that is truthy but not true is not dev mode')
    BR.Server = nil
    ok(pcall(BR.DevMenu.request, 3, { 'storm', 'on' }, 0), 'and a missing BR.Server does not throw')
    eq(#calls, 0, 'and opens nothing')
end

describe('server: only a connected player is asked about')
do
    bootServer()
    eq(BR.DevMenu.request(0, { 'storm', 'on' }, clock), 'console',
       'the server console is refused: the menu is a player\'s')
    eq(BR.DevMenu.request(9, { 'storm', 'on' }, clock), 'player',
       'and so is a source nobody knows')
    eq(#calls, 0, 'neither reached a verb')
end

describe('server: open answers with the rows, the asker first')
do
    bootServer()
    typed(3, 'brdevsv open')
    local st = lastState(3)
    ok(st ~= nil, 'the asker is sent the rows')
    eq(#sentTo(1, 'br:devmenu:state') + #sentTo(5, 'br:devmenu:state'), 0,
       'and nobody else is')
    local ids = {}
    for i, p in ipairs(st and st.players or {}) do ids[i] = p.id end
    eq(table.concat(ids, ','), '3,1,5',
       'yourself first, then everybody else by id -- and nobody who has left')
    eq(st and st.players[1].name, 'Me~r~',
       'names travel as the roster holds them; the client strips the codes')
    local toks, distinct = 0, {}
    for _, p in ipairs(st and st.players or {}) do
        if math.type(p.tok) == 'integer' and p.tok > 0 and not distinct[p.tok] then
            toks = toks + 1
            distinct[p.tok] = true
        end
    end
    eq(toks, 3, 'every player listed carries a token of their own')
    eq(st and st.storm, false, 'the storm is not held')
    eq(st and st.warmup, false, 'nor the warmup')
    eq(#calls, 0, 'open changes nothing')

    -- THE SAME PLAYER KEEPS THEIR TOKEN; A NEW ONE AT THE SAME ID DOES NOT GET IT.
    local before = st.players[2].tok
    clock = clock + 1000
    typed(3, 'brdevsv open')
    eq(lastState(3).players[2].tok, before, 'a second list names player 1 by the same token')
    roster[1] = { name = 'Newcomer', state = BR.PlayerState.LOBBY }
    clock = clock + 1000
    typed(3, 'brdevsv open')
    ok(lastState(3).players[2].tok ~= before,
       'somebody new holding id 1 is a new token -- server ids are recycled, tokens are not')

    -- THE PAUSE BOXES ARE THE ASKER'S MATCH'S, OR THE SESSION'S FROM THE LOBBY.
    bootServer({ sessionStorm = true })
    matches.A.stormFrozen = false
    typed(3, 'brdevsv open')
    eq(lastState(3).storm, false, 'a match that thawed its own storm shows its own answer')
    clock = clock + 1000
    typed(5, 'brdevsv open')
    eq(lastState(5).storm, true, 'the lobby shows the session\'s')
end

describe('server: Time -- an hour 0-23 or reset, and nothing else')
do
    bootServer()
    for _, bad in ipairs({ '-1', '24', 'noon', '7.5', '', 'RESET', '21:30' }) do
        clock = clock + 1000
        eq(BR.DevMenu.request(3, { 'time', bad }, clock), 'bad',
           ('time %q is a request no row sends'):format(bad))
    end
    clock = clock + 1000
    eq(BR.DevMenu.request(3, { 'time' }, clock), 'bad', 'and so is no hour at all')
    eq(#callsOf('setTime'), 0, 'not one of them reached the clock')
    ok(#sentTo(3, 'br:devmenu:dev') > 0, 'the asker\'s F8 gets the usage line')
    eq(#notices, 0, 'and no toast: no row could have sent it')

    for _, h in ipairs({ '0', '23', '7', 'reset' }) do
        clock = clock + 1000
        BR.DevMenu.request(3, { 'time', h }, clock)
    end
    local got = callsOf('setTime')
    eq(#got, 4, 'every good hour reaches brtime\'s own body')
    eq(got[1] and got[1].args[1], '0', 'midnight as brtime is typed')
    eq(got[2] and got[2].args[1], '23', 'eleven at night')
    eq(got[4] and got[4].args[1], 'reset', 'and reset')
end

describe('server: Weather -- one of the fifteen, or reset')
do
    bootServer()
    for _, bad in ipairs({ 'rain', 'NOPE', '', 'clear' }) do
        clock = clock + 1000
        eq(BR.DevMenu.request(3, { 'weather', bad }, clock), 'bad',
           ('weather %q is not one the row lists'):format(bad))
    end
    eq(#callsOf('setWeather'), 0, 'none reached the sky')
    for _, w in ipairs(BR.World.WEATHERS) do
        clock = clock + 1000
        BR.DevMenu.request(3, { 'weather', w }, clock)
    end
    clock = clock + 1000
    BR.DevMenu.request(3, { 'weather', 'reset' }, clock)
    eq(#callsOf('setWeather'), #BR.World.WEATHERS + 1,
       'every name the row offers, and reset, reaches brweather\'s own body')
end

describe('server: Match state -- the asker\'s match, never the newest')
do
    bootServer()
    for _, bad in ipairs({ 'WARMUP', 'lobby', '', 'nope' }) do
        clock = clock + 1000
        eq(BR.DevMenu.request(3, { 'match', bad }, clock), 'bad',
           ('match %q is not a state the row lists'):format(bad))
    end
    eq(#callsOf('force') + #callsOf('skip'), 0, 'none reached brforce or brskip')

    for _, s in ipairs(BR.Config.DevMenu.states) do
        clock = clock + 1000
        BR.DevMenu.request(3, { 'match', s }, clock)
    end
    local f = callsOf('force')
    eq(#f, #BR.Config.DevMenu.states - 1, 'every state but skip goes to brforce\'s body')
    local mine = true
    for _, c in ipairs(f) do
        if c.args[2] ~= matches.A then mine = false end
    end
    ok(mine, 'EVERY ONE AIMED AT THE ASKER\'S MATCH (A), not the newest (B) -- '
       .. 'matches run side by side in their own buckets')
    local s = callsOf('skip')
    eq(#s, 1, 'skip goes to brskip\'s body')
    ok(s[1] and s[1].args[1] == matches.A, 'with the asker\'s match too')

    -- A PLAYER IN THE LOBBY HAS NO MATCH. Not queued, a press is refused:
    -- brforce from nothing forms a match out of the whole queue, which would
    -- be everybody else's -- or an empty one.
    local forced = #callsOf('force')
    clock = clock + 1000
    BR.DevMenu.request(5, { 'match', 'warmup' }, clock)
    eq(#callsOf('force'), forced, 'from the lobby, not queued: brforce is not reached')
    eq(notices[#notices] and notices[#notices].text, 'no match running',
       'and the asker is told, in brskip\'s words')

    -- QUEUED, the verb is told so: nil, which brforce reads as "form one from
    -- the queue" and never as the newest.
    bootServer({ queued = { [5] = true } })
    clock = clock + 1000
    BR.DevMenu.request(5, { 'match', 'warmup' }, clock)
    local last = callsOf('force')
    last = last[#last]
    ok(last and last.args.n >= 2 and last.args[2] == nil,
       'queued, the match is nil -- formed from the queue, never somebody else\'s')
end

describe('server: Give volts -- a connected player, an amount out of the list')
do
    bootServer()
    local t1, t3 = tokenFor(3, 1), tokenFor(3, 3)
    ok(t1 and t3, 'fixture: the list gave tokens for players 1 and 3')
    local bad = {
        { '0', t1, '1000', 'the console as a target' },
        { '3', t3, '123', 'an amount the row does not offer' },
        { '3', t3, '-500', 'a negative amount (brvolts takes those; the menu does not)' },
        { '3', t3, '1000000', 'a million' },
        { '3', t3, '', 'no amount' },
        { 'me', t3, '1000', 'a target that is not a number' },
        { '3', '', '1000', 'no token' },
        { '3', 'x', '1000', 'a token that is not a number' },
    }
    for _, b in ipairs(bad) do
        clock = clock + 1000
        eq(BR.DevMenu.request(3, { 'volts', b[1], b[2], b[3] }, clock), 'bad', b[4])
    end
    eq(#callsOf('grantVolts'), 0, 'not one reached the profile write')
    eq(#notices, 0, 'and none is a toast: no row could have sent them')

    for _, n in ipairs(BR.Config.DevMenu.volts) do
        clock = clock + 1000
        BR.DevMenu.request(3, { 'volts', '1', t1, tostring(n) }, clock)
    end
    local g = callsOf('grantVolts')
    eq(#g, #BR.Config.DevMenu.volts, 'every amount the row offers reaches brvolts\'s own body')
    ok(g[1] and g[1].args[1] == 1 and g[1].args[2] == 100,
       'to the player picked, as numbers', g[1] and ('%s %s'):format(tostring(g[1].args[1]), tostring(g[1].args[2])))
    local most = 0
    for _, n in ipairs(BR.Config.DevMenu.volts) do if n > most then most = n end end
    ok(most <= 10000, 'one press mints at most 10,000', most)

    -- ═══ THE ANSWER IS A ROUND TRIP, AND IT LANDS ONCE ═══
    local done = g[1].args[3]
    local before = #sentTo(3, 'br:devmenu:state')
    done(true, 'brvolts: 1 +100 Volts')
    done(true, 'brvolts: 1 +100 Volts')
    eq(#sentTo(3, 'br:devmenu:state') - before, 1, 'the rows are pushed once, when br_ddb answers')
    eq(#notices, 0, 'a grant that landed is no toast')

    local done2 = g[2].args[3]
    done2(false, 'brvolts: 1 was NOT credited 500 -- throttled')
    eq(#notices, 1, 'one that did not land is')
    ok(notices[1] and notices[1].target == 3 and notices[1].tone == 'warn',
       'to the asker, as a warning')
    eq(notices[1] and notices[1].text, 'brvolts: 1 was NOT credited 500 -- throttled',
       'in the verb\'s own words')

    -- ═══ NOT SENT AT ALL: br_ddb down ═══
    bootServer({ voltsUnsent = true })
    local mine = tokenFor(3, 3)
    BR.DevMenu.request(3, { 'volts', '3', mine, '1000' }, clock)
    eq(notices[1] and notices[1].text,
       'brvolts: br_ddb is not started, so there is nothing to write to.',
       'a write that could not be sent says why, the way brvolts does')
end

describe('server: a give names the player the list showed, or nobody')
do
    -- ═══ THE LISTED PLAYER LEFT ═══
    bootServer()
    local t1 = tokenFor(3, 1)
    roster[1] = nil
    local pushed = #sentTo(3, 'br:devmenu:state')
    clock = clock + 1000
    eq(BR.DevMenu.request(3, { 'volts', '1', t1, '1000' }, clock), 'ran',
       'a give to somebody who has left is a press the row could send')
    eq(#callsOf('grantVolts'), 0, 'but nothing is granted')
    eq(notices[1] and notices[1].text, 'player 1 has left', 'the asker is told, as a toast')
    eq(#sentTo(3, 'br:devmenu:state') - pushed, 1, 'and sent the list as it stands')
    local ids = {}
    for i, p in ipairs(lastState(3).players) do ids[i] = p.id end
    eq(table.concat(ids, ','), '3,5', 'which no longer lists them')

    -- ═══ THE ID WAS RECYCLED: somebody else holds it now ═══
    bootServer()
    t1 = tokenFor(3, 1)
    roster[1] = { name = 'Stranger', state = BR.PlayerState.LOBBY }
    clock = clock + 1000
    BR.DevMenu.request(3, { 'yubikey', '1', t1 }, clock)
    eq(#callsOf('devKey'), 0, 'a key is NOT given to whoever holds the id now')
    clock = clock + 1000
    BR.DevMenu.request(3, { 'volts', '1', t1, '1000' }, clock)
    eq(#callsOf('grantVolts'), 0, 'and neither are Volts')
    eq(notices[2] and notices[2].text, 'player 1 has left', 'both refused in words')

    -- ═══ A TOKEN THAT WAS NEVER HANDED OUT ═══
    clock = clock + 1000
    BR.DevMenu.request(3, { 'volts', '1', '999', '1000' }, clock)
    eq(#callsOf('grantVolts'), 0, 'a made-up token gives nothing')
end

describe('server: Give Yubikeys -- the terminal command\'s own grant')
do
    bootServer()
    local t5 = tokenFor(3, 5)
    for _, b in ipairs({ { '-3', t5 }, { 'x', t5 }, { '', t5 }, { '5', '' }, { '5', '-1' } }) do
        clock = clock + 1000
        eq(BR.DevMenu.request(3, { 'yubikey', b[1], b[2] }, clock), 'bad',
           ('yubikey %q %q is refused'):format(b[1], b[2]))
    end
    eq(#callsOf('devKey'), 0, 'none reached the grant')
    clock = clock + 1000
    BR.DevMenu.request(3, { 'yubikey', '5', t5 }, clock)
    local k = callsOf('devKey')
    ok(k[1] and k[1].args[1] == 5 and k[1].args[2] == true,
       'a connected player is GIVEN one (BR.Terminal.devKey, give = true)')
    eq(#notices, 0, 'a key that landed is no toast')

    bootServer({ keyRefused = true })
    local t3 = tokenFor(3, 3)
    BR.DevMenu.request(3, { 'yubikey', '3', t3 }, clock)
    eq(notices[1] and notices[1].text, '3: already holds one',
       'the cap of one is the terminal command\'s refusal, word for word')
end

describe('server: Storm pause and Warmup pause -- on or off, and the box follows')
do
    bootServer()
    for _, b in ipairs({ 'yes', '1', 'ON', '' }) do
        clock = clock + 1000
        eq(BR.DevMenu.request(3, { 'storm', b }, clock), 'bad', ('storm %q is refused'):format(b))
        clock = clock + 1000
        eq(BR.DevMenu.request(3, { 'warmup', b }, clock), 'bad', ('warmup %q is refused'):format(b))
    end
    eq(#callsOf('setMatchFrozen') + #callsOf('setMatchWarmupFrozen'), 0, 'neither pause was touched')

    clock = clock + 1000
    BR.DevMenu.request(3, { 'storm', 'on' }, clock)
    local sf = callsOf('setMatchFrozen')
    ok(sf[1] and sf[1].args[1] == matches.A and sf[1].args[2] == true,
       'storm on freezes THE ASKER\'S MATCH (A), and only it')
    eq(matches.B.stormFrozen, nil, 'the newer match B is not touched')
    eq(lastState(3) and lastState(3).storm, true, 'and the pushed rows say it is held')
    clock = clock + 1000
    BR.DevMenu.request(3, { 'warmup', 'on' }, clock)
    local wf = callsOf('setMatchWarmupFrozen')
    ok(wf[1] and wf[1].args[1] == matches.A and wf[1].args[2] == true,
       'warmup on holds the asker\'s match too')
    eq(lastState(3) and lastState(3).warmup, true, 'and the rows say so')
    clock = clock + 1000
    BR.DevMenu.request(3, { 'storm', 'off' }, clock)
    sf = callsOf('setMatchFrozen')
    ok(sf[2] and sf[2].args[1] == matches.A and sf[2].args[2] == false, 'storm off thaws it')
    eq(lastState(3) and lastState(3).storm, false, 'and the box comes back off')
    eq(#callsOf('setFrozen') + #callsOf('setWarmupFrozen'), 0,
       'the console\'s every-match freezes are never reached')

    -- A STALE BOX: the server's answer is the verb's "already", and no toast.
    clock = clock + 1000
    BR.DevMenu.request(3, { 'storm', 'off' }, clock)
    eq(#notices, 0, 'asking for the state the match is already in is no refusal')
    eq(lastState(3) and lastState(3).storm, false, 'and the box says what the match is')

    -- FROM THE LOBBY THERE IS NO MATCH TO PAUSE.
    clock = clock + 1000
    BR.DevMenu.request(5, { 'storm', 'on' }, clock)
    clock = clock + 1000
    BR.DevMenu.request(5, { 'warmup', 'on' }, clock)
    eq(#callsOf('setMatchFrozen'), 3, 'a lobby press freezes nothing')
    eq(#callsOf('setMatchWarmupFrozen'), 1, 'and holds nothing')
    eq(notices[1] and notices[1].text, 'no match running', 'and says so')
    eq(lastState(5) and lastState(5).storm, false, 'the box the library flipped is put back')
end

describe('server: Spawn airdrops -- the asker\'s match, and a refusal said aloud')
do
    bootServer()
    clock = clock + 1000
    BR.DevMenu.request(1, { 'airdrop' }, clock)
    local d = callsOf('dropNow')
    ok(d[1] and d[1].args[1] == matches.B, 'player 1 drops into THEIR match (B)')
    eq(notices[1] and notices[1].target, 1, 'the refusal goes to the player who pressed')
    eq(notices[1] and notices[1].text, 'airdrops only run during PLAYING (match 178 is warmup)',
       'in /brairdrop\'s own sentence')
    local f8 = sentTo(1, 'br:devmenu:dev')
    eq(f8[#f8] and f8[#f8].data, notices[1] and notices[1].text, 'and on their F8')
    ok(lastState(1) ~= nil, 'and the rows are pushed after it')

    clock = clock + 1000
    BR.DevMenu.request(3, { 'airdrop' }, clock)
    d = callsOf('dropNow')
    ok(d[2] and d[2].args[1] == matches.A, 'player 3 drops into theirs (A), not the newest')

    -- A `wait` IS NOT A REFUSAL: the drop stays queued and is retried.
    bootServer({ dropWaits = true })
    clock = clock + 1000
    BR.DevMenu.request(3, { 'airdrop' }, clock)
    eq(#notices, 0, 'a drop that waits is no toast')
    local f8w = sentTo(3, 'br:devmenu:dev')
    ok(f8w[#f8w] and tostring(f8w[#f8w].data):find('wait (drop 2', 1, true) ~= nil,
       'it says so on F8')
end

describe('server: an answer that is a success is no toast')
do
    bootServer()
    clock = clock + 1000
    BR.DevMenu.request(3, { 'time', '21' }, clock)
    eq(#notices, 0, 'no toast for a clock that moved')
    local f8 = sentTo(3, 'br:devmenu:dev')
    eq(f8[#f8] and f8[#f8].data, 'brtime: 21', 'the verb\'s confirmation is on the asker\'s F8')
    ok(said('dev menu: Player3 (3) -- time 21'), 'and this console says who asked for what')

    bootServer({ forceRefuses = true })
    BR.DevMenu.request(3, { 'match', 'waiting' }, clock)
    eq(notices[1] and notices[1].text, 'no match to dissolve', 'brforce\'s refusal is a toast')
end

describe('server: the rate')
do
    bootServer()
    local gap = BR.Config.DevMenu.minIntervalMs
    ok(type(gap) == 'number' and gap > 0, 'there is a floor', gap)
    eq(BR.DevMenu.request(3, { 'storm', 'on' }, clock), 'ran', 'the first press is taken')
    local pushed = #sentTo(3, 'br:devmenu:state')
    eq(BR.DevMenu.request(3, { 'storm', 'off' }, clock + gap - 1), 'too-soon',
       'one a millisecond inside the floor is dropped')
    eq(#callsOf('setMatchFrozen'), 1, 'and did nothing')
    eq(#sentTo(3, 'br:devmenu:state') - pushed, 1,
       'but a pause\'s rows are sent back, so a box the library flipped is put right')
    eq(lastState(3) and lastState(3).storm, true, 'still held, as the server has it')
    local lines = #sentTo(3, 'br:devmenu:dev') + #sentTo(3, 'br:devmenu:state')
    eq(BR.DevMenu.request(3, { 'time', '9' }, clock + 2), 'too-soon', 'any other row too soon')
    eq(BR.DevMenu.request(3, { 'nonsense' }, clock + 3), 'too-soon', 'or a bad line too soon')
    eq(#sentTo(3, 'br:devmenu:dev') + #sentTo(3, 'br:devmenu:state'), lines,
       'is dropped without a word: a flood costs nothing to send')
    eq(BR.DevMenu.request(5, { 'time', '7' }, clock + 1), 'ran',
       'another player is not held by it')
    eq(BR.DevMenu.request(3, { 'storm', 'off' }, clock + gap), 'ran',
       'at the floor, the next is taken')

    -- A BAD REQUEST SPENDS THE SLOT TOO, so a flood of them is held to the
    -- same rate -- and to one usage line each.
    local t = clock + 10 * gap
    eq(BR.DevMenu.request(3, { 'time', '99' }, t), 'bad', 'a bad hour')
    eq(BR.DevMenu.request(3, { 'time', '9' }, t + 1), 'too-soon', 'is a press the next one waits behind')
    eq(BR.DevMenu.request(3, { 'time', '9' }, t + gap), 'ran', 'for the floor, and no longer')
    t = t + gap

    -- A PLAYER WHO LEAVES IS FORGOTTEN.
    eq(BR.DevMenu.request(3, { 'time', '10' }, t + 2), 'too-soon', 'fixture: inside the floor')
    source = 3
    onDropped()
    source = nil
    eq(BR.DevMenu.request(3, { 'time', '10' }, t + 3), 'ran',
       'and a source that left and came back starts clean')
end

-- ═══════════════════════════════════════════════════════════════════════════
-- THE VEHICLE SPAWNER, SERVER HALF (#426)
-- ═══════════════════════════════════════════════════════════════════════════

describe('server: Vehicle spawner -- a model word and a sync tree, and nothing else')
do
    bootServer()
    local long = ('a'):rep(65)
    local bad = {
        { {}, 'no model at all' },
        { { 'adder' }, 'a model and no tree' },
        { { 'adder', 'hovercraft' }, 'a tree the platform does not build' },
        { { 'freight', 'train' }, 'a train: the platform knows the word and cannot build one' },
        { { 'adder', 'Automobile' }, 'a tree in the wrong case' },
        { { 'add!er', 'automobile' }, 'a model that is not a model word' },
        { { 'adder;brcar', 'automobile' }, 'or one carrying a second command' },
        { { long, 'automobile' }, 'a model longer than the keyboard takes' },
    }
    for _, b in ipairs(bad) do
        clock = clock + 1000
        local args = { 'vehicle' }
        for _, w in ipairs(b[1]) do args[#args + 1] = w end
        eq(BR.DevMenu.request(3, args, clock), 'bad', b[2])
    end
    eq(#created, 0, 'not one of them reached the server setter')
    eq(#notices, 0, 'and none is a toast: no row could have sent them')
    ok(said('| vehicle <model> <type>'), 'the usage line names the verb')

    eq(table.concat(BR.Config.DevMenu.vehicleTypes, ','),
       'automobile,bike,boat,heli,plane,submarine,trailer',
       'the seven trees: the platform\'s eight less `train`')
    for _, t in ipairs(BR.Config.DevMenu.vehicleTypes) do
        clock = clock + 1000
        eq(BR.DevMenu.request(3, { 'vehicle', 'adder', t }, clock), 'ran',
           ('`%s` is taken'):format(t))
        eq(created[#created] and created[#created].vtype, t, '... and built as that tree')
    end

    -- GTA HASHES A NAME LOWER-CASED, so `Lazer` -- registered that way -- is
    -- the model `lazer` is. The server reads it lower-cased as well.
    clock = clock + 1000
    BR.DevMenu.request(3, { 'vehicle', 'LAZER', 'plane' }, clock)
    eq(created[#created] and created[#created].hash, hashOf('lazer'),
       'a name in capitals is the same model')
    local f8 = sentTo(3, 'br:devmenu:dev')
    ok(f8[#f8] and tostring(f8[#f8].data):find('lazer (0x', 1, true) ~= nil,
       'and its line names it as it is hashed', f8[#f8] and f8[#f8].data)

    -- THE RATE HOLDS IT LIKE ANY ROW: a second press inside the floor builds
    -- nothing.
    local n = #created
    clock = clock + 1000
    BR.DevMenu.request(3, { 'vehicle', 'adder', 'automobile' }, clock)
    eq(BR.DevMenu.request(3, { 'vehicle', 'adder', 'automobile' }, clock + 1), 'too-soon',
       'a second press inside the floor is dropped')
    eq(#created, n + 1, 'and one vehicle was built, not two')
end

describe('server: Vehicle spawner -- brcar\'s spawn, in front of the asker, in their bucket')
do
    bootServer()
    clock = clock + 1000
    eq(BR.DevMenu.request(3, { 'vehicle', 'adder', 'automobile' }, clock), 'ran',
       'a vehicle row\'s press is taken')
    local c = created[1]
    ok(c ~= nil and c.hash == hashOf('adder'),
       'THE SERVER SETTER builds it -- "this needs to be a server-side entity"')
    eq(c and c.vtype, 'automobile', 'as the tree the row named, in the second argument')
    ok(c ~= nil and math.abs(c.x - 100.0) < 0.001 and math.abs(c.y - 205.0) < 0.001,
       'five meters in front of the asker, who faces north',
       c and ('%.2f, %.2f'):format(c.x, c.y))
    eq(c and c.z, 30.0, 'at their height')
    ok(c ~= nil and math.abs(c.heading - 90.0) < 0.001,
       'turned a quarter across them, a door toward them')
    eq(entityBucket[501], 1001, 'IN THE ASKER\'S ROUTING BUCKET -- the setter leaves it in 0')
    eq(#notices, 0, 'a vehicle that was built is no toast')
    local f8 = sentTo(3, 'br:devmenu:dev')
    local line = f8[#f8] and tostring(f8[#f8].data) or ''
    ok(line:find('adder (0xB779A091) as automobile', 1, true) ~= nil,
       'the asker\'s F8 says what was built: the model, its hash, its tree', line)
    ok(line:find('netId 1501', 1, true) ~= nil and line:find('bucket 1001', 1, true) ~= nil,
       'and its network id and bucket', line)
    ok(lastState(3) ~= nil, 'and the rows are pushed after it, as after every answer')
    ok(said('dev menu: Player3 (3) -- vehicle adder automobile'),
       'this console says who asked for what')

    -- THE OFFSET TURNS WITH THEM (brcar's own check, through this door).
    pedHeading[1003] = 90.0
    clock = clock + 1000
    BR.DevMenu.request(3, { 'vehicle', 'adder', 'automobile' }, clock)
    local east = created[#created]
    ok(east ~= nil and math.abs(east.x - 95.0) < 0.001 and math.abs(east.y - 200.0) < 0.001,
       'facing east, it lands five meters east', east and ('%.2f, %.2f'):format(east.x, east.y))
    ok(east ~= nil and math.abs(east.heading - 180.0) < 0.001, 'and turned with them')
    pedHeading[1003] = nil

    -- ANOTHER ASKER, THEIR OWN BUCKET: player 1 is in match B's.
    clock = clock + 1000
    BR.DevMenu.request(1, { 'vehicle', 'adder', 'automobile' }, clock)
    eq(entityBucket[nextVeh], 1002, 'player 1\'s goes in player 1\'s bucket')
    ok(math.abs(created[#created].x - 10.0) < 0.001 and math.abs(created[#created].y - 25.0) < 0.001,
       'in front of player 1')

    -- BUCKET 0 IS A REAL BUCKET AND IT IS TRUTHY (brcar's reason).
    playerBucket[3] = 0
    clock = clock + 1000
    BR.DevMenu.request(3, { 'vehicle', 'adder', 'automobile' }, clock)
    eq(entityBucket[nextVeh], 0, 'an asker in bucket 0 still has it set to 0')
    playerBucket[3] = 1001

    -- ═══ ANY MODEL: "For any that you believe to be armed, allow them to be
    --     spawned here" ═══
    --
    -- brcar refuses every one of these. The door does not: its spawn has no
    -- allowlist in it, and the refusal stayed in the verb.
    for _, m in ipairs({ { 'hydra', 'plane' }, { 'buzzard', 'heli' },
                         { 'rhino', 'automobile' }, { 'kosatka', 'submarine' },
                         { 'trailersmall2', 'trailer' }, { 'blimp', 'heli' } }) do
        local n = #created
        clock = clock + 1000
        BR.DevMenu.request(3, { 'vehicle', m[1], m[2] }, clock)
        ok(#created == n + 1 and created[#created].hash == hashOf(m[1]),
           ('%s is built (%s)'):format(m[1], m[2]))
    end
    -- AND brcar KEEPS ITS OWN RULE: "brcar keeps its own rule (tolerated
    -- models only)", through the same spawn.
    local n = #created
    svCommands.brcar.fn(0, { '3', 'hydra' }, 'brcar 3 hydra')
    eq(#created, n, 'brcar itself still refuses a Hydra')
    ok(said('REFUSED hydra'), 'and says so, as it always has')
    svCommands.brcar.fn(0, { '3', 'adder' }, 'brcar 3 adder')
    eq(#created, n + 1, 'and still builds what it tolerates, through spawnInFront')
    ok(said('[br_core] brcar: adder (0xB779A091) as automobile -> Me~r~ (3)'),
       'with its own readout, word for word')
    eq(entityBucket[nextVeh], 1001, 'in the target\'s bucket')
end

describe('server: Vehicle spawner -- refused in brcar\'s words, and from the lobby in the menu\'s')
do
    --- One press as player `src`; the toast it drew, or nil.
    local function press(src, model, tree)
        clock = clock + 1000
        local before = #notices
        BR.DevMenu.request(src, { 'vehicle', model, tree }, clock)
        local n = notices[#notices]
        return (#notices > before) and n or nil
    end

    -- THE LOBBY: every lobby player stands on the one mark, in one bucket.
    bootServer()
    local n = press(5, 'adder', 'automobile')
    eq(#created, 0, 'nothing is built from the lobby')
    eq(n and n.text, 'no match running', 'and the asker is told, in the menu\'s own lobby words')
    ok(n and n.target == 5 and n.tone == 'warn', 'as a warning toast, to them')
    local f8 = sentTo(5, 'br:devmenu:dev')
    eq(f8[#f8] and f8[#f8].data, 'no match running', 'and on their F8')
    ok(lastState(5) ~= nil, 'and the rows are pushed after it')

    -- ON THE WAY HOME FROM A MATCH: LOBBY, still carrying the match's id.
    roster[3].state = BR.PlayerState.LOBBY
    n = press(3, 'adder', 'automobile')
    eq(#created, 0, 'a player going home is in the lobby, whatever id they carry')
    eq(n and n.text, 'no match running', 'and is told the same')
    roster[3].state = BR.PlayerState.ALIVE

    -- EVERYWHERE ELSE IS brcar's: the warmup pad, the plane, a downed player.
    for _, st in ipairs({ BR.PlayerState.WARMUP, BR.PlayerState.BUS,
                          BR.PlayerState.GLIDE, BR.PlayerState.DBNO,
                          BR.PlayerState.OUT }) do
        roster[3].state = st
        local before = #created
        press(3, 'adder', 'automobile')
        eq(#created, before + 1, ('a player in state %s gets one in front of them'):format(st))
    end
    roster[3].state = BR.PlayerState.ALIVE

    -- NO PED YET: connected, spawned nowhere.
    bootServer()
    roster[3].ped = nil
    n = press(3, 'adder', 'automobile')
    eq(#created, 0, 'no ped, no vehicle -- rather than one at 0, 0, 0')
    eq(n and n.text, 'no ped for 3 yet -- connected but not spawned, or OneSync is off',
       'in brcar\'s words')

    -- A PED THE SERVER CANNOT READ: the native throws, and is caught.
    bootServer({ coordsThrow = true })
    local okCall = pcall(function() n = press(3, 'adder', 'automobile') end)
    ok(okCall, 'a throwing position read does not take the door down')
    eq(n and n.text, 'no coordinates for 3', 'it is answered, in brcar\'s words')

    -- NO SERVER SETTER IN THIS RUNTIME.
    bootServer({ noSetter = true })
    n = press(3, 'adder', 'automobile')
    eq(n and n.text, 'CreateVehicleServerSetter is not available in this runtime.',
       'a runtime without the native says so')

    -- THE PLATFORM THROWS.
    bootServer({ createThrows = true })
    okCall = pcall(function() n = press(3, 'adder', 'automobile') end)
    ok(okCall, 'a throwing create is caught, not propagated -- #212')
    eq(n and n.text, 'the platform refused to create adder as a automobile',
       'and answered in brcar\'s words')

    -- THE ENGINE ANSWERS 0.
    bootServer({ createFail = true })
    n = press(3, 'adder', 'automobile')
    eq(n and n.text, 'the engine refused to create adder', 'a handle of 0 is a refusal')
    eq(entityBucket[0], nil, 'and 0 is not mistaken for a handle -- nothing was done to entity 0')

    -- BUILT, AND ALREADY GONE: DoesEntityExist answers 0, and 0 is truthy.
    bootServer({ vanish = true })
    n = press(3, 'adder', 'automobile')
    eq(n and n.text, 'adder was created and is already gone, or its handle never resolved',
       'a vehicle the server cannot see is not reported as built')
end

-- =========================================================================
-- PART B -- the client
-- =========================================================================

local executed, mappings, cmds, passes, events, menus, opened
local clientDev

--- The vendored library, modeled as far as these rows reach it: New, AddItem,
--- Visible with OnMenuClose on the falling edge, the list's Index and
--- ChangeList, the checkbox's Checked -- and SelectItem / GoLeft / GoRight in
--- the library's own order, so a test presses the rows the way a player does.
local function modelLibrary()
    menus = {}

    -- ═══ THE TRAIL BACK, AND THE MENU THAT IS CURRENT (#426) ═══
    --
    -- BreadcrumbsHandler and MenuHandler as far as a switch, a Back and a close
    -- reach them, line for line where it matters: Visible(true) pushes a menu
    -- only onto an EMPTY trail, Visible(false) leaves the trail alone, GoBack
    -- at one deep closes and clears, deeper it shows the one before -- and
    -- MenuHandler:SwitchTo reads the undefined global `newer` whenever the
    -- selection it is handed is above 1, so a caller that hands it one throws
    -- here as it would in the game.
    BreadcrumbsHandler = { breadcrumbs = {}, SwitchInProgress = false }
    function BreadcrumbsHandler:Count() return #self.breadcrumbs end
    function BreadcrumbsHandler:CurrentDepth() return #self.breadcrumbs end
    function BreadcrumbsHandler:PreviousMenu() return self.breadcrumbs[#self.breadcrumbs - 1] end
    function BreadcrumbsHandler:Forward(m) table.insert(self.breadcrumbs, { menu = m }) end
    function BreadcrumbsHandler:Clear() self.breadcrumbs = {} end
    function BreadcrumbsHandler:Backwards() table.remove(self.breadcrumbs, #self.breadcrumbs) end

    MenuHandler = { _currentMenu = nil }
    function MenuHandler:SwitchTo(current, new, sel, inherit)
        assert(current ~= nil, 'The menu you\'re switching from cannot be null')
        assert(current == self._currentMenu, 'The menu you\'re switching from must be opened')
        assert(new ~= nil, 'The menu you\'re switching to cannot be null')
        assert(new ~= current, 'You cannot switch a menu to itself')
        assert(not new:Visible(), 'The menu you\'re switching to is already open!')
        if BreadcrumbsHandler.SwitchInProgress then return end
        BreadcrumbsHandler.SwitchInProgress = true
        if sel == nil then sel = 1 end
        if inherit then new.inherited = (new.inherited or 0) + 1 end
        if sel > 1 then
            local max = #newer.Items -- `newer` is nil: the library's own bug
            new._cur = math.min(sel, max)
        end
        current:Visible(false)
        new:Visible(true)
        BreadcrumbsHandler:Forward(new)
        BreadcrumbsHandler.SwitchInProgress = false
    end
    function MenuHandler:CloseAndClearHistory()
        if self._currentMenu ~= nil and self._currentMenu:Visible() then
            self._currentMenu:Visible(false)
        end
        BreadcrumbsHandler:Clear()
    end

    UIMenu = {}
    UIMenu.__index = UIMenu
    function UIMenu.New(title, subTitle, x, y, glare, txd, txn)
        local m = setmetatable({
            Title = title, SubTitle = subTitle, TxtDictionary = txd, TxtName = txn,
            Items = {}, InstructionalButtons = { 'select', 'back' },
            _mouse = true, _edge = true, _visible = false, _cur = 1,
            Controls = { Back = { Enabled = true }, Select = { Enabled = true },
                         Up = { Enabled = true }, Down = { Enabled = true } },
            OnMenuClose = function() end,
        }, UIMenu)
        menus[#menus + 1] = m
        return m
    end
    function UIMenu:MouseControlsEnabled(v) if v ~= nil then self._mouse = v end return self._mouse end
    function UIMenu:MouseEdgeEnabled(v) if v ~= nil then self._edge = v end return self._edge end
    function UIMenu:CounterColor(c) self._counter = c end
    function UIMenu:SubtitleColor(n) self._subtitle = n end
    function UIMenu:AddItem(i) self.Items[#self.Items + 1] = i; i.ParentMenu = self end
    function UIMenu:Visible(v)
        if v ~= nil then
            local was = self._visible
            if v == true then
                if was then return self._visible end
                assert(#self.Items > 0, 'UIMenu is empty')
                self._visible = true
                MenuHandler._currentMenu = self
                if BreadcrumbsHandler:Count() == 0 then BreadcrumbsHandler:Forward(self) end
            else
                self._visible = false
                MenuHandler._currentMenu = nil
                if was == true then self.OnMenuClose(self) end
            end
        end
        return self._visible
    end
    function UIMenu:CurrentItem() return self.Items[self._cur] end
    function UIMenu:SwitchTo(new, sel, inherit)
        assert(new ~= nil, 'cannot switch to a null menu')
        if sel == nil then sel = 1 end
        if inherit == nil then inherit = true end
        MenuHandler:SwitchTo(self, new, sel, inherit)
    end
    function UIMenu:GoBack()
        if BreadcrumbsHandler:CurrentDepth() == 1 then
            MenuHandler:CloseAndClearHistory()
            BreadcrumbsHandler:Clear()
        else
            BreadcrumbsHandler.SwitchInProgress = true
            local prev = BreadcrumbsHandler:PreviousMenu()
            BreadcrumbsHandler:Backwards()
            self:Visible(false)
            if prev ~= nil then prev.menu:Visible(true) end
            BreadcrumbsHandler.SwitchInProgress = false
        end
    end
    --- A key reaching the menu, as UIMenu:ProcessControl reads it: nothing at
    --- all while GTA's keyboard is up or a switch is under way, and Back and
    --- Select only while their Controls are on.
    function UIMenu:Key(name)
        if not self._visible then return end
        if UpdateOnscreenKeyboard() == 0 or BreadcrumbsHandler.SwitchInProgress then return end
        if name == 'back' and self.Controls.Back.Enabled then self:GoBack() end
        if name == 'select' and self.Controls.Select.Enabled then self:Press(self._cur) end
    end
    --- Enter on row `i`, as UIMenu:SelectItem does it.
    function UIMenu:Press(i)
        self._cur = i
        local item = self.Items[i]
        if item.ItemId == 2 then
            item:Checked(not item:Checked())
            item.OnCheckboxChanged(self, item, item:Checked())
        elseif item.ItemId == 1 then
            item.OnListSelected(self, item, item._Index)
        end
        if item.ItemId ~= 2 then item.Activated(self, item) end
    end
    --- Right on row `i`, as UIMenu:GoRight does it.
    function UIMenu:Right(i)
        self._cur = i
        local item = self.Items[i]
        if item.ItemId == 1 then
            item:Index(item:Index() + 1)
            item.OnListChanged(self, item, item._Index)
        end
    end

    UIMenuItem = {}
    UIMenuItem.__index = UIMenuItem
    function UIMenuItem.New(text, description, main, highlight)
        return setmetatable({
            _text = text, _Description = description, _main = main, ItemId = 0,
            Activated = function() end,
        }, UIMenuItem)
    end
    function UIMenuItem:Description(s) if s ~= nil then self._Description = s end return self._Description end
    function UIMenuItem:RightLabel(t) if t ~= nil then self._right = t end return self._right end
    function UIMenuItem:LeftBadge(b) self._badge = b end

    UIMenuListItem = {}
    UIMenuListItem.__index = UIMenuListItem
    setmetatable(UIMenuListItem, { __index = UIMenuItem })
    function UIMenuListItem.New(text, items, index, description)
        local b = UIMenuItem.New(text, description)
        b.Items = items
        b._Index = (index == 0) and 1 or (tonumber(index) or 1)
        b.ItemId = 1
        b.changes = 0
        b.OnListChanged = function() end
        b.OnListSelected = function() end
        return setmetatable(b, UIMenuListItem)
    end
    function UIMenuListItem:Index(i)
        if tonumber(i) then
            if i > #self.Items then self._Index = 1
            elseif i < 1 then self._Index = #self.Items
            else self._Index = i end
        else
            return self._Index
        end
    end
    --- THE LIBRARY'S OWN RULE, line for line (UIMenuListItem:ChangeList): the
    --- index it is handed is thrown away for 1 whenever the OLD index is past
    --- the end of the NEW list.
    function UIMenuListItem:ChangeList(list, index)
        self.changes = self.changes + 1
        if index == nil or index < 1 or index > #list or self._Index > #list then index = 1 end
        self.Items = list
        self:Index(index)
    end

    UIMenuCheckboxItem = {}
    UIMenuCheckboxItem.__index = UIMenuCheckboxItem
    setmetatable(UIMenuCheckboxItem, { __index = UIMenuItem })
    function UIMenuCheckboxItem.New(text, check, style, description)
        local b = UIMenuItem.New(text, description)
        b._Checked = check == true
        b.ItemId = 2
        b.OnCheckboxChanged = function() end
        return setmetatable(b, UIMenuCheckboxItem)
    end
    function UIMenuCheckboxItem:Checked(v)
        if v ~= nil then self._Checked = v == true else return self._Checked end
    end

    UIMenuSeparatorItem = {}
    BadgeStyle = { NONE = 0 }
    SColor = {}
    function SColor.FromHudColor(n) return { hud = n } end
    function SColor.FromArgb(a, r, g, b) return { a = a, r = r, g = g, b = b } end
end

-- ═══ THE GAME'S VEHICLES, AS THE NATIVES WILL ANSWER FOR THEM (#426) ═══
--
-- { name as the game registered it, class, kind, gameName, its text }.
--
-- THE KIND IS WHICH IsThisModelA* NATIVES SAY YES, and the answers are the
-- documented ones: a car is a car and not an amphibious one, a quad likewise;
-- IS_THIS_MODEL_A_BIKE says yes to a bicycle as well; a jetski is a boat with
-- a flag; and a blimp, a submarine, a submarine car and a trailer have no
-- native that says yes to them. Every answer is 1 or 0 -- a FiveM BOOL -- so
-- a bare truth test would read every model as a train.
--
-- AND THE AWKWARD ONES ON PURPOSE: names registered in capitals (`Lazer`,
-- `BLIMP`, `BMX`, `Dinghy`); vehicles the game names alike in one class
-- (three Avengers, two Speedo Customs, two Trailers in Utility, and `BMX`
-- beside an add-on `Bmx`) and a name shared across two classes (a Trailer in
-- Military); a vehicle with no text (`docktrailer`) and an add-on with no
-- entry at all (`myaddon`, whose name sorts against a capitalized one); a
-- label carrying GTA's text codes; trains, in class 21; and no Compacts at
-- all. Armed or not is config/vehicles.lua's say, never this table's -- its
-- rows and its list of armed models with no ruling yet (#427).
local VEHICLES = {
    { 'adder',         7,  'car',      'ADDER',        'Adder' },
    { 'zentorno',      7,  'car',      'ZENTORNO',     'Zentorno' },
    { 'scramjet',      7,  'car',      'SCRAMJET',     'Scramjet' },
    { 'vigilante',     7,  'car',      'VIGILANTE',    'Vigilante' },
    { 'caracara2',     9,  'car',      'CARACARA2',    'Caracara 4x4' },
    { 'insurgent2',    9,  'car',      'INSURGENT2',   'Insurgent' },
    { 'insurgent',     9,  'car',      'INSURGENT',    'Insurgent Pick-Up' },
    { 'speedo4',       12, 'car',      'SPEEDO4',      'Speedo Custom' },
    { 'speedo5',       12, 'car',      'SPEEDO5',      'Speedo Custom' },
    { 'bmx2',          13, 'bicycle',  'BMX2',         'Bmx' },
    { 'avenger3',      16, 'plane',    'AVENGER',      'Avenger' },
    { 'tanker',        11, 'trailer',  'TANKER',       'Trailer' },
    { 'mytrailer',     19, 'trailer',  'MYTRAILER',    'Trailer' },
    { 'blazer',        9,  'quad',     'BLAZER',       'Blazer' },
    { 'blazer5',       9,  'amphquad', 'BLAZER5',      'Blazer Aqua' },
    { 'technical2',    9,  'amphcar',  'TECHNICAL2',   'Technical Aqua' },
    { 'bati',          8,  'bike',     'BATI',         'Bati 801' },
    { 'oppressor2',    8,  'bike',     'OPPRESSOR2',   'Oppressor Mk II' },
    { 'chimera',       8,  'quad',     'CHIMERA',      'Chimera' },
    { 'BMX',           13, 'bicycle',  'BMX',          'BMX' },
    { 'Dinghy',        14, 'boat',     'DINGHY',       'Dinghy' },
    { 'seashark',      14, 'jetski',   'SEASHARK',     'Seashark' },
    { 'kosatka',       14, 'sub',      'KOSATKA',      'Kosatka' },
    { 'submersible',   14, 'sub',      'SUBMERS',      'Submersible' },
    { 'maverick',      15, 'heli',     'MAVERICK',     'Maverick' },
    { 'buzzard',       15, 'heli',     'BUZZARD',      'Buzzard Attack Chopper' },
    { 'Lazer',         16, 'plane',    'LAZER',        'P-996 LAZER' },
    { 'BLIMP',         16, 'blimp',    'blimp',        'Atomic Blimp' },
    { 'avenger2',      16, 'plane',    'AVENGER',      'Avenger' },
    { 'avenger',       16, 'plane',    'AVENGER',      'Avenger' },
    { 'stromberg',     5,  'subcar',   'STROMBERG',    'Stromberg' },
    { 'toreador',      5,  'subcar',   'TOREADOR',     'Toreador' },
    { 'trailers',      11, 'trailer',  'TRAILERS',     'Trailer' },
    { 'docktrailer',   11, 'trailer',  'DOCKTRAILER',  nil },
    { 'tractor',       11, 'car',      'TRACTOR',      'Tractor' },
    { 'rhino',         19, 'car',      'RHINO',        'Rhino Tank' },
    -- AN AMPHIBIOUS CAR IN THE CLASS TRAILERS LIVE IN: only its own native
    -- keeps it off the trailer tree.
    { 'apc',           19, 'amphcar',  'APC',          'APC' },
    { 'trailersmall2', 19, 'trailer',  'TRAILERSMALL2', 'Anti-Aircraft Trailer' },
    { 'barracks',      19, 'car',      'BARRACKS',     'Barracks' },
    { 'freight',       21, 'train',    'FREIGHT',      'Freight Train' },
    { 'metrotrain',    21, 'train',    'METROTRAIN',   'Metro' },
    { 'myaddon',       6,  'car',      nil,            nil },
    { 'brokenlabel',   6,  'car',      'BROKEN',       '~r~Red~s~ Rocket' },
}

--- What each kind answers yes to.
local KIND_SAYS = {
    car      = { Car = true },
    quad     = { Quadbike = true },
    amphcar  = { AnAmphibiousCar = true },
    amphquad = { AnAmphibiousQuadbike = true },
    bike     = { Bike = true },
    bicycle  = { Bike = true, Bicycle = true },
    boat     = { Boat = true },
    jetski   = { Boat = true, Jetski = true },
    heli     = { Heli = true },
    plane    = { Plane = true },
    train    = { Train = true },
}

--- The game's class names, GetLabelText('VEH_CLASS_' .. n).
local CLASS_TEXT = {
    [0] = 'Compacts', [5] = 'Sports Classics', [6] = 'Sports', [7] = 'Super',
    [8] = 'Motorcycles', [9] = 'Off-road', [11] = 'Utility', [12] = 'Vans',
    [13] = 'Cycles', [14] = 'Boats', [15] = 'Helicopters', [16] = 'Planes',
    [19] = 'Military', [21] = 'Trains',
}

--- The modeled game, per boot: the vehicles by hash, the models taken out of
--- it since, how often it was asked for its list, GTA's keyboard, the text
--- entries, the keys held and coming up, the key layer's screens and the
--- toasts this client raised.
local vehByHash, gone, scans, kbd, textEntries, keyHeld, keyUp, screens, toasts

local function bootClient(opts)
    opts = opts or {}
    BR = nil
    executed, mappings, cmds, passes, events, consoleLines = {}, {}, {}, {}, {}, {}
    clientDev = (opts.dev == nil) and true or opts.dev

    vehByHash, gone, scans = {}, {}, 0
    for _, v in ipairs(VEHICLES) do vehByHash[hashOf(v[1])] = v end
    kbd = { state = -1, result = nil, opened = {} }
    textEntries, keyHeld, keyUp, screens, toasts = {}, {}, {}, {}, {}

    function GetHashKey(s) return hashOf(s) end
    if opts.noModelList then
        GetAllVehicleModels = nil
    else
        function GetAllVehicleModels()
            scans = scans + 1
            local out = {}
            for i, v in ipairs(VEHICLES) do out[i] = v[1] end
            return out
        end
    end
    function GetVehicleClassFromName(h) local v = vehByHash[h]; return v and v[2] or 0 end
    function GetDisplayNameFromVehicleModel(h)
        local v = vehByHash[h]
        return v and v[4] or 'CARNOTFOUND'
    end
    function GetLabelText(key)
        local c = tostring(key):match('^VEH_CLASS_(%d+)$')
        if c then return CLASS_TEXT[tonumber(c)] or 'NULL' end
        for _, v in ipairs(VEHICLES) do
            if v[4] == key and v[5] then return v[5] end
        end
        return 'NULL'
    end
    local function yes(h, word)
        local v = vehByHash[h]
        return (v and not gone[h] and KIND_SAYS[v[3]] and KIND_SAYS[v[3]][word]) and 1 or 0
    end
    for _, word in ipairs({ 'Car', 'Quadbike', 'AnAmphibiousCar', 'AnAmphibiousQuadbike',
                            'Bike', 'Bicycle', 'Boat', 'Jetski', 'Heli', 'Plane', 'Train' }) do
        local name = (word:sub(1, 2) == 'An') and ('IsThisModel' .. word) or ('IsThisModelA' .. word)
        _G[name] = function(h) return yes(h, word) end
    end
    function IsModelInCdimage(h) return (vehByHash[h] and not gone[h]) and 1 or 0 end
    function IsModelAVehicle(h) return (vehByHash[h] and not gone[h]) and 1 or 0 end

    -- GTA'S KEYBOARD: 0 while it is up, then 1, 2 or 3.
    --
    -- AND WHATEVER WAS TYPED, IN EVERY STATE. The documentation says the
    -- result is NULL unless the box reads 1; a caller leaning on that would
    -- ask for a name the player canceled with Escape on a build where it is
    -- not, so the model hands the text back regardless.
    function AddTextEntry(k, v) textEntries[k] = v end
    function DisplayOnscreenKeyboard(kind, title, desc, default, c1, c2, c3, maxLen)
        kbd.opened[#kbd.opened + 1] = { kind = kind, title = title, default = default,
                                        maxLen = maxLen }
        kbd.state = 0
    end
    function UpdateOnscreenKeyboard() return kbd.state end
    function GetOnscreenKeyboardResult() return kbd.result end
    function ForceCloseTextInputBox() kbd.state = -1; kbd.forced = true end
    function IsDisabledControlPressed(_, c) return keyHeld[c] and 1 or 0 end
    function IsDisabledControlJustReleased(_, c) return keyUp[c] and 1 or 0 end

    function GetConvar(n, d)
        if n == 'br_devMode' then return clientDev and 'true' or 'false' end
        return d
    end
    function GetCurrentResourceName() return 'br_core' end
    function RegisterCommand(name, fn, restricted) cmds[name] = { fn = fn, restricted = restricted } end
    function RegisterKeyMapping(command, description, mapper, key)
        mappings[#mappings + 1] = { command = command, description = description,
                                    mapper = mapper, key = key }
    end
    function ExecuteCommand(line) executed[#executed + 1] = line end
    function RegisterNetEvent() end
    function AddEventHandler(name, fn) events[name] = fn end
    function PlayerId() return 0 end
    function GetPlayerServerId() return 3 end
    function GetPlayerName() return 'Me' end

    if opts.noLibrary then
        UIMenu, UIMenuItem, UIMenuListItem, UIMenuCheckboxItem, SColor, MenuHandler = nil, nil, nil, nil, nil, nil
        BreadcrumbsHandler = nil
    else
        modelLibrary()
    end

    loadAll({
        'br_lib/shared/devgate.lua',
        'br_lib/shared/enums.lua',
        'br_lib/shared/protocol.lua',
        'br_lib/shared/world.lua',
        'br_lib/shared/geo.lua',
        'br_lib/shared/shop_solve.lua',
        'br_lib/config/vehicles.lua',
        'br_lib/config/devmenu.lua',
    })
    -- client/state.lua's notice, recorded.
    BR.Notify = function(text, tone) toasts[#toasts + 1] = { text = text, tone = tone } end
    BR.Config.World = { hour = 12, minute = 0 }
    BR.Config.Market = { currency = 'Volts' }
    -- What client/state.lua holds: the match's state as last heard, and
    -- client/keybinds.lua's "is one of our panels up".
    BR.State = { match = { state = opts.matchState or 'waiting' } }
    -- ...and its door for a screen it cannot see, recorded ('none' for nil).
    BR.Keys = {
        uiScreen = nil,
        setExternalScreen = function(name) screens[#screens + 1] = name or 'none' end,
    }

    -- THE LOOP REGISTRY, as client/main.lua hands it out: register returns a
    -- handle, unregister marks it dead.
    BR.Loop = {
        FRAME = 'frame', TICK = 'tick', SLOW = 'slow',
        register = function(band, name, fn)
            local h = { band = band, name = name, fn = fn }
            passes[#passes + 1] = h
            return h
        end,
        unregister = function(h) if h then h.dead = true end end,
    }

    loadAll({ 'br_core/client/menu.lua', 'br_core/client/devmenu.lua' })
end

--- Run every live SLOW pass once.
local function slow()
    for _, h in ipairs(passes) do
        if h.band == 'slow' and not h.dead then h.fn(1000) end
    end
end

--- Run every live TICK pass once.
local function tick()
    for _, h in ipairs(passes) do
        if h.band == 'tick' and not h.dead then h.fn(100) end
    end
end

--- Run every live FRAME pass once.
local function frame()
    for _, h in ipairs(passes) do
        if h.band == 'frame' and not h.dead then h.fn(16) end
    end
end

--- Is a pass by this name live?
local function passLive(name)
    for _, h in ipairs(passes) do
        if h.name == name and not h.dead then return true end
    end
    return false
end

--- The server's answer, as BR.Net.DEVMENU_STATE brings it.
local function answer(d) events['br:devmenu:state'](d) end

local function liveLoops()
    local n = 0
    for _, h in ipairs(passes) do
        if not h.dead and h.name ~= 'menu.escape' then n = n + 1 end
    end
    return n
end

--- The dev menu, once it has been built: the one titled so with no subtitle.
--- Its submenus carry the same title, and their own subtitle (#426).
local function devMenu()
    for _, m in ipairs(menus or {}) do
        if m.Title == BR.Config.DevMenu.labels.title and (m.SubTitle or '') == '' then
            return m
        end
    end
    return nil
end

--- A dev submenu by its subtitle -- the Vehicle spawner, or a class (#426).
local function subMenu(subtitle)
    for _, m in ipairs(menus or {}) do
        if m.Title == BR.Config.DevMenu.labels.title and m.SubTitle == subtitle then
            return m
        end
    end
    return nil
end

--- The row labeled `text`, and its index.
local function row(m, text)
    for i, it in ipairs(m and m.Items or {}) do
        if it._text == text then return it, i end
    end
    return nil, nil
end

--- A menu's row labels, joined.
local function rowTexts(m)
    local out = {}
    for i, it in ipairs(m and m.Items or {}) do out[i] = it._text end
    return table.concat(out, '|')
end

--- The library's trail: 'Dev menu' for the one menu, a submenu by its
--- subtitle, and 'other' for a menu that is not the dev menu's.
local function trail()
    local out = {}
    for i, b in ipairs(BreadcrumbsHandler and BreadcrumbsHandler.breadcrumbs or {}) do
        local mm = b.menu
        if mm == devMenu() then out[i] = 'Dev menu'
        elseif mm.Title == BR.Config.DevMenu.labels.title then out[i] = mm.SubTitle
        else out[i] = 'other' end
    end
    return table.concat(out, ' > ')
end

local function lastExecuted() return executed[#executed] end

--- /brdev, then the Vehicle spawner row, the way a player gets there.
--- @return table|nil spawner, table|nil the one menu
local function intoSpawner()
    if not BR.DevMenu.up() then cmds.brdev.fn(0, {}, 'brdev') end
    local m = devMenu()
    local _, vi = row(m, BR.Config.DevMenu.labels.vehicles)
    if vi then m:Press(vi) end
    return subMenu(BR.Config.DevMenu.labels.vehicles), m
end

--- A class from the spawner -- Back to it first when a class is up.
--- @return table|nil the class's menu
local function intoClass(sp, name)
    local cur = MenuHandler._currentMenu
    if cur ~= nil and cur ~= sp then cur:GoBack() end
    local _, ci = row(sp, name)
    if ci then sp:Press(ci) end
    return subMenu(name)
end

describe('client: /brdev and F10, and neither off a dev box')
do
    bootClient({ dev = false })
    ok(cmds.brdev ~= nil, '/brdev is registered')
    eq(#mappings, 0, 'NO KEY MAPPING AT LOAD -- a mapping cannot be taken back')
    for _ = 1, 5 do slow() end
    eq(#mappings, 0, 'and none while the client reads dev mode off')
    cmds.brdev.fn(0, {}, 'brdev')
    eq(#executed, 0, '/brdev off a dev box asks the server nothing')
    eq(#menus, 0, 'and builds no menu')
    ok(said('brdev is dev-mode only'), 'the wrap says on F8 which gate closed')

    -- ═══ THE REPLICATED br_devMode LANDS ═══
    clientDev = true
    slow()
    eq(#mappings, 1, 'the first pass that reads dev mode on maps the key')
    local mp = mappings[1] or {}
    eq(mp.command, 'brdev', 'to /brdev')
    eq(mp.key, 'F10', 'on F10 by default')
    eq(mp.mapper, 'keyboard', 'from the keyboard, so FiveM\'s bindings list can move it')
    eq(mp.description, 'Royale: Dev menu', 'filed with the game\'s other rows')
    slow(); slow()
    eq(#mappings, 1, 'once, and never again')
    eq(liveLoops(), 0, 'and the pass has taken itself out of the loop')
end

describe('client: the menu is the gun shop\'s UI, with the owner\'s labels and nothing else')
do
    bootClient()
    cmds.brdev.fn(0, {}, 'brdev')
    local m = devMenu()
    ok(m ~= nil, '/brdev builds the menu')
    ok(m and m:Visible() == true, 'and shows it')
    eq(m and m._mouse, false, 'no mouse -- BR.Menu.new, as at the gun counter')
    eq(m and #m.InstructionalButtons, 0, 'no instructional buttons')
    eq(m and m.TxtDictionary, nil, 'the library\'s own bar, no banner art')

    local L = BR.Config.DevMenu.labels
    local want = { L.time, L.weather, L.match, L.player, L.volts, L.yubikey,
                   L.storm, L.warmup, L.airdrop, L.vehicles }
    local got = {}
    for i, it in ipairs(m and m.Items or {}) do got[i] = it._text end
    eq(table.concat(got, '|'), table.concat(want, '|'), 'the rows, in order, in his words')
    eq(table.concat(want, '|'),
       'Time|Weather|Match state|Player|Give volts|Give Yubikeys|Storm pause|Warmup pause|Spawn airdrops|Vehicle spawner',
       'which are exactly these -- the Vehicle spawner last (#426)')
    local described = 0
    for _, it in ipairs(m and m.Items or {}) do
        if (it._Description or '') ~= '' then described = described + 1 end
    end
    eq(described, 0, 'no row carries a description')

    eq(lastExecuted(), 'brdevsv open', 'opening asks the server for the rows')
    local time = row(m, L.time)
    eq(time and time.Items[time._Index], '12:00', 'the clock row starts at the rest hour')
    eq(time and #time.Items, 25, 'twenty-four hours and reset')
    eq(time and time.Items[25], 'Reset', 'reset in the console verbs\' own word')
    local wx = row(m, L.weather)
    eq(wx and #wx.Items, #BR.World.WEATHERS + 1, 'the fifteen weathers and reset')
    local vo = row(m, L.volts)
    eq(vo and vo.Items[3], '1,000 Volts', 'the amounts through the one price formatter')
    local pl = row(m, L.player)
    eq(pl and pl.Items[1], 'Me', 'before the server answers, the Player row is you')
end

describe('client: every row sends the line its value says, and only on Enter')
do
    bootClient()
    cmds.brdev.fn(0, {}, 'brdev')
    local m = devMenu()
    local L = BR.Config.DevMenu.labels
    local _, ti = row(m, L.time)
    local n = #executed
    m:Right(ti); m:Right(ti)
    eq(#executed, n, 'an arrow on the clock row asks nothing: stepping is looking')
    m:Press(ti)
    eq(lastExecuted(), 'brdevsv time 14', 'Enter sends the hour showing (12:00, two steps on)')
    local time = row(m, L.time)
    time:Index(25)
    m:Press(ti)
    eq(lastExecuted(), 'brdevsv time reset', 'and Reset sends reset')

    local wx, wi = row(m, L.weather)
    wx:Index(9)
    m:Press(wi)
    eq(lastExecuted(), 'brdevsv weather ' .. BR.World.WEATHERS[9], 'the weather by its engine name')

    local ms, mi = row(m, L.match)
    for i, s in ipairs(BR.Config.DevMenu.states) do
        ms:Index(i)
        m:Press(mi)
        eq(lastExecuted(), 'brdevsv match ' .. s, ('the state row sends %s'):format(s))
    end

    -- THE GIVES WAIT FOR THE SERVER'S LIST: until it lands there is no token.
    local _, vi = row(m, L.volts)
    local _, yi = row(m, L.yubikey)
    local n0 = #executed
    m:Press(vi)
    m:Press(yi)
    eq(#executed, n0, 'before the server has listed anybody, a give sends nothing')
    answer({ players = { { id = 3, tok = 11, name = 'Me' } }, storm = false, warmup = false })
    m:Press(vi)
    eq(lastExecuted(), 'brdevsv volts 3 11 100',
       'Give volts goes to the player picked -- you, first -- by id and token')
    m:Press(yi)
    eq(lastExecuted(), 'brdevsv yubikey 3 11', 'and so does Give Yubikeys')

    local st, si = row(m, L.storm)
    m:Press(si)
    eq(lastExecuted(), 'brdevsv storm on', 'Storm pause sends the box\'s new state')
    ok(st:Checked() == true, 'fixture: the library flipped the box')
    m:Press(si)
    eq(lastExecuted(), 'brdevsv storm off', 'and back')
    local _, wu = row(m, L.warmup)
    m:Press(wu)
    eq(lastExecuted(), 'brdevsv warmup on', 'Warmup pause the same')
    local _, ai = row(m, L.airdrop)
    m:Press(ai)
    eq(lastExecuted(), 'brdevsv airdrop', 'Spawn airdrops asks for one')
end

describe('client: the server\'s answer lands in place')
do
    bootClient()
    cmds.brdev.fn(0, {}, 'brdev')
    local m = devMenu()
    local L = BR.Config.DevMenu.labels
    local pl, pi = row(m, L.player)
    local items = #m.Items

    events['br:devmenu:state']({
        players = { { id = 3, tok = 1, name = 'Me' }, { id = 1, tok = 2, name = '~r~Red~s~Name' },
                    { id = 7, tok = 3, name = 'Seven~n~' } },
        storm = true, warmup = false,
    })
    eq(#m.Items, items, 'no row is added or rebuilt')
    eq(table.concat(pl.Items, ','), 'Me,RedName,Seven',
       'names listed with GTA\'s text codes taken out -- a player wrote them')
    eq(row(m, L.storm):Checked(), true, 'the storm box shows what the server says')
    eq(row(m, L.warmup):Checked(), false, 'and the warmup box')

    pl:Index(3)
    local _, yi = row(m, L.yubikey)
    m:Press(yi)
    eq(lastExecuted(), 'brdevsv yubikey 7 3', 'the picked player by server id and token, not by name')

    -- THE PICK SURVIVES A SHORTER LIST: player 7 moves to the second place.
    -- The library's ChangeList alone would put the pick on you -- the old
    -- index, 3, is past the end of a list of two.
    events['br:devmenu:state']({ players = { { id = 3, tok = 1, name = 'Me' }, { id = 7, tok = 3, name = 'Seven' } },
                                 storm = false, warmup = true })
    eq(pl:Index(), 2, 'the Player row still points at the same player')
    m:Press(yi)
    eq(lastExecuted(), 'brdevsv yubikey 7 3', 'and a give still goes to them')
    eq(row(m, L.storm):Checked(), false, 'a box the server turned off is off')
    eq(row(m, L.warmup):Checked(), true, 'and one it turned on is on')

    -- A REFUSED PAUSE: the library flipped the box, the server says no.
    local _, si = row(m, L.storm)
    m:Press(si)
    ok(row(m, L.storm):Checked() == true, 'fixture: pressed on')
    events['br:devmenu:state']({ players = { { id = 3, tok = 1, name = 'Me' } }, storm = false, warmup = true })
    eq(row(m, L.storm):Checked(), false, 'the server\'s answer puts the box back')
    eq(pl:Index(), 1, 'and a picked player who left falls back to you')

    -- THE PICK FOLLOWS THE TOKEN, NOT THE ID: somebody new at id 7.
    answer({ players = { { id = 3, tok = 1, name = 'Me' }, { id = 7, tok = 3, name = 'Seven' } } })
    pl:Index(2)
    answer({ players = { { id = 3, tok = 1, name = 'Me' }, { id = 7, tok = 9, name = 'Stranger' } } })
    eq(pl:Index(), 1, 'a new player at the same id is not the one that was picked')

    -- A PLAYER WITH NO TOKEN IS NOT LISTED: a give could not name them.
    answer({ players = { { id = 3, tok = 1, name = 'Me' }, { id = 4, name = 'NoTok' } } })
    eq(#pl.Items, 1, 'an entry without a token is left out')

    events['br:devmenu:state']('not a table')
    eq(#m.Items, items, 'a malformed answer changes nothing')

    events['br:devmenu:dev']('brtime: 21:00 for everyone')
    ok(said('[br_core] brdev: brtime: 21:00 for everyone'), 'the server\'s line is printed on F8')
end

describe('client: one menu, toggled')
do
    bootClient()
    cmds.brdev.fn(0, {}, 'brdev')
    local m = devMenu()
    cmds.brdev.fn(0, {}, 'brdev')
    eq(m:Visible(), false, 'F10 again puts it away')
    local asked = #executed
    cmds.brdev.fn(0, {}, 'brdev')
    eq(#menus, 1, 'and opening it again builds nothing new')
    eq(m:Visible(), true, 'the same menu comes back')
    eq(#executed, asked + 1, 'asking the server for the rows again')
    eq(liveLoops(), 2, 'up, it runs one pass beside the key\'s')
    m:GoBack()
    ok(not BR.DevMenu.up(), 'the library\'s own Back is seen without being told')
    slow()
    tick()
    eq(liveLoops(), 0, 'and once it is down and the key is mapped, the menu costs no loop at all')
    cmds.brdev.fn(0, {}, 'brdev')
    eq(liveLoops(), 1, 'opened again, its pass comes back')
    cmds.brdev.fn(0, {}, 'brdev')
    cmds.brdev.fn(0, {}, 'brdev')
    eq(liveLoops(), 1, 'once, however often it is toggled')
end

describe('client: the Match state row stands on the match\'s state, and follows it')
do
    -- ONE ENTER ON THE ROW MUST NOT DISSOLVE THE MATCH. On `waiting` it would;
    -- on the state the match is in, it changes nothing.
    bootClient({ matchState = 'playing' })
    cmds.brdev.fn(0, {}, 'brdev')
    local m = devMenu()
    local L = BR.Config.DevMenu.labels
    local ms, mi = row(m, L.match)
    eq(ms.Items[ms._Index], 'playing', 'opened in a playing match, the row says playing')
    m:Press(mi)
    eq(lastExecuted(), 'brdevsv match playing', 'so a stray Enter asks for what already is')

    BR.State.match.state = 'ended'
    tick()
    eq(ms.Items[ms._Index], 'ended', 'the match moves on, and the row with it')

    -- A STATE THE ROW DOES NOT LIST (none yet) is `waiting`, which with no
    -- match is brforce's own "no match to dissolve".
    BR.State.match.state = nil
    tick()
    eq(ms._Index, 1, 'no state is the first row')

    -- WHAT THE PLAYER STEPPED TO STAYS, UNTIL THE MATCH MOVES.
    BR.State.match.state = 'warmup'
    tick()
    ms:Index(4)
    tick()
    eq(ms._Index, 4, 'a pass with no change leaves the player\'s own choice alone')

    -- AND IT OPENS ON THE STATE AGAIN.
    cmds.brdev.fn(0, {}, 'brdev')
    BR.State.match.state = 'bus'
    cmds.brdev.fn(0, {}, 'brdev')
    eq(ms.Items[ms._Index], 'bus', 'reopened, the row stands on the state the match is in')
end

describe('client: one of our panels taking the keyboard puts the menu away')
do
    bootClient()
    cmds.brdev.fn(0, {}, 'brdev')
    local m = devMenu()
    BR.Keys.uiScreen = 'inventory'
    tick()
    eq(m:Visible(), false, 'the inventory up puts the dev menu down -- the gun shop\'s rule')
    local asked = #executed
    cmds.brdev.fn(0, {}, 'brdev')
    eq(m:Visible(), false, 'and it does not open under one')
    eq(#executed, asked, 'nor ask the server anything')
    BR.Keys.uiScreen = nil
    cmds.brdev.fn(0, {}, 'brdev')
    eq(m:Visible(), true, 'with the panel gone it opens')
end

describe('client: another menu goes down first')
do
    -- THE GUN COUNTER'S MENU UP WHEN F10 IS PRESSED. Both are BR.Menu menus
    -- and the library draws one; the other closes through its own close, so
    -- its flags come down with it -- the emote wheel's rule.
    bootClient()
    local other = BR.Menu.new('', '', nil)
    other:AddItem(BR.Menu.item('Carbine Rifle'))
    local closed = 0
    other.OnMenuClose = function() closed = closed + 1 end
    other:Visible(true)
    cmds.brdev.fn(0, {}, 'brdev')
    eq(other:Visible(), false, 'the other menu is down')
    eq(closed, 1, 'through its own close')
    eq(devMenu():Visible(), true, 'and the dev menu is up')
end

describe('client: no library, no menu, and no throw')
do
    bootClient({ noLibrary = true })
    ok(pcall(cmds.brdev.fn, 0, {}, 'brdev'), '/brdev without ScaleformUI does not throw')
    eq(#executed, 0, 'and asks nothing')
    ok(said('ScaleformUI is not in this Lua state'), 'it says why on F8')
end

-- ═══════════════════════════════════════════════════════════════════════════
-- THE VEHICLE SPAWNER, CLIENT HALF (#426)
-- ═══════════════════════════════════════════════════════════════════════════

describe('client: Vehicle spawner -- a row, and a menu built the first time it opens')
do
    bootClient()
    cmds.brdev.fn(0, {}, 'brdev')
    local m = devMenu()
    local L = BR.Config.DevMenu.labels
    eq(scans, 0, 'opening the dev menu reads no vehicles')
    eq(#menus, 1, 'and builds none of the spawner\'s menus')

    local sp = intoSpawner()
    ok(sp ~= nil, 'the Vehicle spawner row opens a menu')
    eq(sp and sp:Visible(), true, 'shown')
    eq(m:Visible(), false, 'in place of the one menu')
    ok(BR.DevMenu.up(), 'and the dev menu counts as up')
    eq(sp and sp.Title, 'Dev menu', 'the bar is the dev menu\'s; the strip says where you are')
    eq(sp and sp._mouse, false, 'built through BR.Menu.new: no mouse')
    eq(sp and #sp.InstructionalButtons, 0, 'no buttons')
    eq(sp and sp.inherited, nil,
       'switched to without the library rebuilding it from the one menu')
    eq(rowTexts(sp),
       'Spawn by name|Sports Classics|Sports|Super|Motorcycles|Off-road|Utility|'
       .. 'Vans|Cycles|Boats|Helicopters|Planes|Military',
       'Spawn by name, then a row per class the game has vehicles in -- in its '
       .. 'class order, in its words')
    ok(row(sp, 'Compacts') == nil, 'a class with no vehicles has no row')
    ok(row(sp, 'Trains') == nil, 'and Trains has none: the server setter cannot build a train')
    local described = 0
    for _, it in ipairs(sp and sp.Items or {}) do
        if (it._Description or '') ~= '' then described = described + 1 end
    end
    eq(described, 0, 'no row carries a description')
    eq(scans, 1, 'the game was asked for its vehicles once')
    eq(trail(), 'Dev menu > Vehicle spawner', 'and Back has the way to the one menu')

    -- BACK, AND IN AGAIN: nothing read or built twice.
    sp:Key('back')
    eq(m:Visible(), true, 'Back is the one menu')
    local built = #menus
    intoSpawner()
    eq(subMenu(L.vehicles), sp, 'the same spawner comes back')
    eq(#menus, built, 'nothing new is built')
    eq(scans, 1, 'and the vehicles are not read again')
    eq(liveLoops(), 2, 'and it costs no pass of its own -- the menu\'s and the key\'s')

    -- A CLIENT WITH NO VEHICLE LIST still has Spawn by name.
    bootClient({ noModelList = true })
    sp = intoSpawner()
    eq(rowTexts(sp), 'Spawn by name', 'no list: no class rows, and the menu still opens')
end

describe('client: a class lists every vehicle in it, by its in-game name, the armed ones in red')
do
    bootClient()
    local L = BR.Config.DevMenu.labels
    local sp = intoSpawner()
    local RED = BR.Menu.red(L.armed)
    eq(RED, '~HC_6~Armed~s~',
       'the mark: "Armed", in HUD_COLOUR_RED -- an index into the engine\'s palette')

    local planes = intoClass(sp, 'Planes')
    ok(planes ~= nil and planes:Visible(), 'a class row opens its menu')
    eq(planes and planes.SubTitle, 'Planes', 'the strip names the class')
    eq(trail(), 'Dev menu > Vehicle spawner > Planes', 'and Back has the way out')
    eq(rowTexts(planes),
       'Atomic Blimp|Avenger (avenger)|Avenger (avenger2)|Avenger (avenger3)|'
       .. 'P-996 LAZER',
       'every vehicle in the class, by its in-game name, sorted by it -- and the '
       .. 'three the game names alike told apart by their model')
    eq(planes and planes.Items[1]._right, nil,
       'the Atomic Blimp carries nothing: it flies, and is unarmed')
    eq(planes and planes.Items[2]._right, RED, 'an Avenger carries "Armed", in red')
    eq(planes and planes.Items[4]._right, RED,
       'the third Avenger too: no row names it, the game\'s data arms it (#427) -- '
       .. 'the model in its name leaves the mark where it was')
    eq(planes and planes.Items[5]._right, RED, 'and so does the Lazer')
    -- TWO OF A NAME KEEP ONE ORDER: by model, and say which.
    planes:Press(2)
    eq(lastExecuted(), 'brdevsv vehicle avenger plane', '`Avenger (avenger)` is `avenger`')
    planes:Press(3)
    eq(lastExecuted(), 'brdevsv vehicle avenger2 plane', 'and `Avenger (avenger2)` is `avenger2`')
    planes:Press(4)
    eq(lastExecuted(), 'brdevsv vehicle avenger3 plane', 'and `Avenger (avenger3)` is `avenger3`')

    local sports = intoClass(sp, 'Sports')
    eq(rowTexts(sports), 'myaddon|Red Rocket',
       'no name in the game: the model\'s; GTA\'s codes taken out of a label; '
       .. 'sorted without regard to case')

    local util = intoClass(sp, 'Utility')
    eq(rowTexts(util), 'docktrailer|Tractor|Trailer (tanker)|Trailer (trailers)',
       'a vehicle the game never named, by its model; two Trailers, told apart')

    local vans = intoClass(sp, 'Vans')
    eq(rowTexts(vans), 'Speedo Custom (speedo4)|Speedo Custom (speedo5)',
       'two Speedo Customs, told apart')
    eq(vans and vans.Items[1]._right, RED, 'and both armed, by the game\'s data (#427)')
    eq(vans and vans.Items[2]._right, RED, '...both of them')

    local cycles = intoClass(sp, 'Cycles')
    eq(rowTexts(cycles), 'BMX (bmx)|Bmx (bmx2)',
       'names alike but for case are alike: each keeps its own spelling, and says its model')

    local mil = intoClass(sp, 'Military')
    eq(rowTexts(mil), 'Anti-Aircraft Trailer|APC|Barracks|Rhino Tank|Trailer',
       'Military, by name -- its Trailer alone in its own list, so plain, whatever '
       .. 'Utility has')
    eq(mil and mil.Items[1]._right, RED, 'an ARMED row is armed')
    eq(mil and mil.Items[3]._right, nil,
       'the Barracks is military and carries nothing: the class says nothing about guns')
    eq(mil and mil.Items[4]._right, RED, 'and a tank is armed')
    eq(mil and mil.Items[5]._right, nil, 'and an unarmed trailer is not')

    local off = intoClass(sp, 'Off-road')
    eq(rowTexts(off),
       'Blazer|Blazer Aqua|Caracara 4x4|Insurgent|Insurgent Pick-Up|Technical Aqua',
       'Off-road, by name')
    eq(off and off.Items[2]._right, RED,
       'the Blazer Aqua is in no row, and the game\'s data arms it: marked (#427)')
    eq(off and off.Items[3]._right, nil, 'the Caracara 4x4 is unarmed')
    eq(off and off.Items[4]._right, RED,
       '`insurgent2` -- the Insurgent -- is an ARMED row, and marked as the row says')
    eq(off and off.Items[5]._right, RED,
       '`insurgent` -- the Pick-Up, with the turret -- is marked by the game\'s data')

    -- BUILT ONCE.
    local built = #menus
    local again = intoClass(sp, 'Planes')
    eq(again, planes, 'a class opened again is the same menu')
    eq(#menus, built, 'nothing new is built')
end

describe('client: every row asks for its model, as the sync tree the game says it is')
do
    bootClient()
    local L = BR.Config.DevMenu.labels
    local sp = intoSpawner()
    local RED = BR.Menu.red(L.armed)
    local want = {
        adder = 'automobile', zentorno = 'automobile', scramjet = 'automobile',
        vigilante = 'automobile', caracara2 = 'automobile', insurgent2 = 'automobile',
        tractor = 'automobile', rhino = 'automobile', barracks = 'automobile',
        myaddon = 'automobile', brokenlabel = 'automobile',
        insurgent = 'automobile', speedo4 = 'automobile', speedo5 = 'automobile',
        blazer = 'automobile', chimera = 'automobile',   -- quads
        blazer5 = 'automobile',                           -- amphibious quad
        technical2 = 'automobile', apc = 'automobile',    -- amphibious cars
        stromberg = 'automobile', toreador = 'automobile', -- submarine cars: no native
        bati = 'bike', oppressor2 = 'bike',
        bmx = 'bike', bmx2 = 'bike',                       -- a bicycle is a bike
        dinghy = 'boat', seashark = 'boat',                -- a jetski is a boat
        kosatka = 'submarine', submersible = 'submarine',  -- no native: Boats
        maverick = 'heli', buzzard = 'heli',
        blimp = 'heli',                                    -- no native: Planes
        lazer = 'plane', avenger = 'plane', avenger2 = 'plane', avenger3 = 'plane',
        trailers = 'trailer', docktrailer = 'trailer',     -- no native: Utility
        tanker = 'trailer',
        trailersmall2 = 'trailer', mytrailer = 'trailer',  -- ...and Military
    }
    -- THE TABLE'S ARMED, TANK AND MARKED FLIGHT ROWS, AND THE ARMED MODELS
    -- WITH NO RULING YET (#427): blazer5, insurgent, avenger3, speedo4, speedo5.
    local armedWant = {
        scramjet = true, vigilante = true, insurgent2 = true, technical2 = true,
        oppressor2 = true, kosatka = true, buzzard = true, lazer = true,
        avenger = true, avenger2 = true, stromberg = true, toreador = true,
        rhino = true, trailersmall2 = true, apc = true,
        blazer5 = true, insurgent = true, avenger3 = true, speedo4 = true,
        speedo5 = true,
    }
    local got, armedGot, asked, armedCount = {}, {}, 0, 0
    for ci = 2, #sp.Items do
        local cm = intoClass(sp, sp.Items[ci]._text)
        for i, it in ipairs(cm and cm.Items or {}) do
            local n = #executed
            cm:Press(i)
            local w = words(executed[#executed] or '')
            if #executed == n + 1 and w[2] == 'vehicle' then
                asked = asked + 1
                got[w[3]] = w[4]
                if it._right == RED then
                    armedGot[w[3]] = true
                    armedCount = armedCount + 1
                elseif it._right ~= nil then
                    armedGot[w[3]] = 'another label'
                end
            end
        end
    end
    eq(asked, 41, 'every vehicle but the two trains has a row, and every row asks')
    for model, tree in pairs(want) do
        eq(got[model], tree, ('%s is asked for as %s'):format(model, tree))
    end
    eq(armedCount, 20, 'twenty rows are marked')
    for model in pairs(armedWant) do
        eq(armedGot[model], true, ('%s is marked Armed'):format(model))
    end
    ok(got.lazer ~= nil and got.Lazer == nil and got.bmx ~= nil and got.blimp ~= nil,
       'names the game registered in capitals are asked for lower-cased')
    eq(#toasts, 0, 'and none of it was refused')

    -- A MODEL GONE SINCE THE LIST WAS READ (its resource stopped): not asked.
    gone[hashOf('adder')] = true
    local super = intoClass(sp, 'Super')
    local n = #executed
    super:Press(1)
    eq(#executed, n, 'a model this game no longer has is not asked for')
    eq(toasts[#toasts] and toasts[#toasts].text, 'adder cannot be spawned', 'it is refused, by name')
    eq(toasts[#toasts] and toasts[#toasts].tone, 'warn', 'as a warning toast')
    ok(said('[br_core] brdev: adder cannot be spawned'), 'and on F8')
end

describe('client: Spawn by name -- GTA\'s keyboard over the open menu')
do
    bootClient()
    local L = BR.Config.DevMenu.labels
    local sp = intoSpawner()
    local _, bi = row(sp, L.byName)
    eq(bi, 1, 'Spawn by name is the spawner\'s first row')
    local n = #executed

    sp:Press(bi)
    eq(#kbd.opened, 1, 'it opens GTA\'s on-screen keyboard')
    local o = kbd.opened[1] or {}
    eq(textEntries[o.title], 'Spawn by name',
       'titled with the row\'s own label, through a text entry -- the box takes a label')
    eq(o.maxLen, 64, 'as long as a model name may be')
    eq(o.kind, 0, 'the English keyboard: a model name is ASCII')
    eq(o.default, '', 'and empty')
    eq(screens[#screens], 'devmenu.keyboard',
       'the key layer is told a screen it cannot see has the keyboard -- typing '
       .. '`titan` is not T, I, T, A and N')
    eq(sp.Controls.Select.Enabled, false, 'the menu\'s Select is off')
    eq(sp.Controls.Back.Enabled, false, 'and its Back')
    ok(passLive('devmenu.keyboard'), 'and a frame pass runs while the box is up')

    -- WHILE TYPING, THE MENU READS NO KEY.
    frame(); frame()
    sp:Key('select')
    sp:Key('back')
    eq(#kbd.opened, 1, 'Enter reaching the menu under the box opens no second box')
    eq(sp:Visible(), true, 'and Escape takes nothing back')
    sp:Press(bi)
    eq(#kbd.opened, 1, 'one box at a time')
    eq(#executed, n, 'and nothing is asked while it is up')

    -- CONFIRMED, WITH ENTER STILL DOWN.
    kbd.state, kbd.result = 1, '  Adder '
    keyHeld[201] = true
    frame()
    eq(lastExecuted(), 'brdevsv vehicle adder automobile',
       'the name typed is asked for: trimmed, lower-cased, as the tree the game says')
    eq(#executed, n + 1, 'once')
    eq(screens[#screens], 'none', 'the key layer has the keyboard back as the box goes')
    eq(sp.Controls.Select.Enabled, false, 'but while Enter is still down, Select stays off')
    sp:Key('select')
    eq(#kbd.opened, 1, '-- so the Enter that confirmed does not open the box again')
    keyHeld[201], keyUp[201] = nil, true
    frame()
    eq(sp.Controls.Select.Enabled, false, 'nor on the frame Enter comes up')
    keyUp[201] = nil
    frame()
    eq(sp.Controls.Select.Enabled, false,
       'nor after one quiet frame: the library\'s loop is a thread of its own')
    frame()
    eq(sp.Controls.Select.Enabled, true, 'two, and the menu has Select back')
    eq(sp.Controls.Back.Enabled, true, 'and Back')
    ok(not passLive('devmenu.keyboard'), 'and the pass is gone')
    eq(#executed, n + 1, 'still one request')

    -- ESCAPE ON THE BOX: canceled, nothing asked, and the spawner stays.
    sp:Press(bi)
    eq(#kbd.opened, 2, 'opened again')
    kbd.state, kbd.result = 2, 'rhino'
    keyHeld[177] = true
    frame()
    eq(#executed, n + 1, 'a canceled box asks for nothing -- not even what was typed')
    eq(screens[#screens], 'none', 'and gives the keyboard back')
    keyHeld[177], keyUp[177] = nil, true
    sp:Key('back')
    eq(sp:Visible(), true,
       'the Escape that canceled is not also Back on its way up -- the spawner stays')
    keyUp[177] = nil
    frame(); frame()
    eq(sp.Controls.Back.Enabled, true, 'once it is up, Back is the menu\'s again')
    sp:Key('back')
    eq(devMenu():Visible(), true, 'and the next Escape goes back, as it should')

    -- WHAT IS REFUSED, AND WHAT IS NOTHING.
    bootClient()
    sp = intoSpawner()
    n = #executed
    local function typeIt(text, status)
        sp:Press(1)
        kbd.state, kbd.result = status or 1, text
        frame(); frame(); frame()
    end
    typeIt('adderr')
    eq(toasts[#toasts] and toasts[#toasts].text, 'adderr cannot be spawned',
       'a name the game has no vehicle by is refused, as typed')
    eq(toasts[#toasts] and toasts[#toasts].tone, 'warn', 'as a warning toast')
    ok(said('[br_core] brdev: adderr cannot be spawned'), 'and on F8')
    typeIt('add er')
    eq(toasts[#toasts] and toasts[#toasts].text, 'add er cannot be spawned',
       'and so is one that is not a model name at all')
    typeIt('~r~zz')
    eq(toasts[#toasts] and toasts[#toasts].text, 'zz cannot be spawned',
       'with GTA\'s codes taken out of what is echoed')
    typeIt('freight')
    eq(toasts[#toasts] and toasts[#toasts].text, 'freight cannot be spawned',
       'a train, by name: the server setter cannot build one')
    eq(#executed, n, 'not one of them was asked for')
    local t = #toasts
    typeIt('   ')
    typeIt('adder', 3)
    typeIt('adder', -1)
    eq(#toasts, t, 'an empty name, a failed box and one gone without an answer are nothing')
    eq(#executed, n, 'and ask nothing')
    typeIt('Kosatka')
    eq(lastExecuted(), 'brdevsv vehicle kosatka submarine', 'a submarine, by name, as a submarine')
    typeIt('BLIMP')
    eq(lastExecuted(), 'brdevsv vehicle blimp heli', 'a blimp, as a heli')

    -- BR_CORE STOPPING WITH THE BOX UP: it is closed, not left with nobody
    -- reading it.
    sp:Press(1)
    events['onClientResourceStop']('br_core')
    ok(kbd.forced == true, 'FORCE_CLOSE_TEXT_INPUT_BOX takes the box down')
    ok(not BR.DevMenu.up(), 'and the menu goes')
end

describe('client: Back walks the library\'s trail, and a dev menu put away leaves none')
do
    bootClient()
    local sp, m = intoSpawner()
    local cls = intoClass(sp, 'Super')
    eq(trail(), 'Dev menu > Vehicle spawner > Super', 'three deep')
    cls:Key('back')
    eq(sp:Visible(), true, 'Back from a class is the spawner')
    eq(trail(), 'Dev menu > Vehicle spawner', 'one off the trail')
    sp:Key('back')
    eq(m:Visible(), true, 'Back from the spawner is the one menu')
    eq(trail(), 'Dev menu', 'two')
    m:Key('back')
    ok(not BR.DevMenu.up(), 'and Back from the one menu closes it')
    eq(trail(), '', 'leaving no trail')

    -- F10 INSIDE A CLASS.
    sp = intoSpawner()
    intoClass(sp, 'Boats')
    cmds.brdev.fn(0, {}, 'brdev')
    ok(not BR.DevMenu.up(), 'F10 in a class menu puts the dev menu away')
    eq(trail(), '', 'and its trail with it')
    cmds.brdev.fn(0, {}, 'brdev')
    eq(devMenu():Visible(), true, 'F10 again is the one menu, not the class it was left in')
    eq(trail(), 'Dev menu', 'on a trail of its own')

    -- ANOTHER MENU OPENING OVER A CLASS -- the gun counter's, through closeAll.
    sp = intoSpawner()
    intoClass(sp, 'Boats')
    local other = BR.Menu.new('', '', nil)
    other:AddItem(BR.Menu.item('Carbine Rifle'))
    BR.Menu.closeAll(other)
    other:Visible(true)
    ok(not BR.DevMenu.up(), 'another menu opening puts the dev menu away')
    eq(trail(), 'other', 'and the trail is that menu\'s alone')
    other:Key('back')
    eq(other:Visible(), false, 'its Escape closes it')
    ok(not BR.DevMenu.up(), '-- and does not walk back into the Vehicle spawner')

    -- A TRAIL SOMEBODY ELSE LEFT: the gun counter walked away from.
    bootClient()
    local shop = BR.Menu.new('', '', nil)
    shop:AddItem(BR.Menu.item('Carbine Rifle'))
    shop:Visible(true)
    shop:Visible(false)
    eq(trail(), 'other', 'fixture: a close by Visible(false) leaves its trail')
    sp, m = intoSpawner()
    eq(trail(), 'Dev menu > Vehicle spawner', 'the dev menu starts its own')
    sp:Key('back')
    eq(m:Visible(), true, 'Back from the spawner is the dev menu')
    eq(shop:Visible(), false, 'and never the gun shop somebody walked away from')

    -- ONE OF OUR PANELS TAKING THE KEYBOARD, DEEP IN A CLASS.
    sp = intoSpawner()
    intoClass(sp, 'Cycles')
    BR.Keys.uiScreen = 'inventory'
    tick()
    ok(not BR.DevMenu.up(), 'the inventory puts a class menu away too -- the gun shop\'s rule')
    eq(trail(), '', 'and the trail')
    BR.Keys.uiScreen = nil
    tick()
    eq(liveLoops(), 1, 'and with it down, its pass is gone; the key\'s remains')
end

-- =========================================================================
-- PART C -- the client's own lines, typed into the server
-- =========================================================================

describe('end to end: what the rows type, the server takes')
do
    -- THE SERVER FIRST, for the list and its tokens; then the client, handed
    -- that list; then back to the same server -- the same tokens -- with every
    -- line the rows typed.
    bootServer()
    typed(3, 'brdevsv open')
    local listed = lastState(3)
    local server = BR
    bootClient()
    cmds.brdev.fn(0, {}, 'brdev')
    answer(listed)
    local m = devMenu()
    local L = BR.Config.DevMenu.labels
    local function pressAll()
        for i = 1, #m.Items do m:Press(i) end
        -- every value of every list row
        for _, key in ipairs({ L.time, L.weather, L.match, L.volts }) do
            local it, i = row(m, key)
            for v = 1, #it.Items do
                it:Index(v)
                m:Press(i)
            end
        end
    end
    pressAll()
    -- AND THE VEHICLE SPAWNER'S (#426): pressAll's last root row opened it.
    -- Every vehicle row of every class, and a name typed at Spawn by name.
    local sp = subMenu(L.vehicles)
    local vehicleLines = 0
    for ci = 2, #(sp and sp.Items or {}) do
        local cm = intoClass(sp, sp.Items[ci]._text)
        for i = 1, #(cm and cm.Items or {}) do
            cm:Press(i)
            vehicleLines = vehicleLines + 1
        end
    end
    MenuHandler._currentMenu:GoBack()
    sp:Press(1)
    kbd.state, kbd.result = 1, 'Lazer'
    frame()
    local lines = {}
    for _, l in ipairs(executed) do lines[#lines + 1] = l end
    eq(lines[#lines], 'brdevsv vehicle lazer plane', 'fixture: the typed name was asked for')

    BR = server
    local bad, built, refusedVehicles = {}, #created, 0
    for _, l in ipairs(lines) do
        clock = clock + 1000
        local w = words(l)
        table.remove(w, 1)
        local toasted = #notices
        local got = BR.DevMenu.request(3, w, clock)
        if got ~= 'ran' and got ~= 'open' then bad[#bad + 1] = l .. ' -> ' .. got end
        if w[1] == 'vehicle' and #notices > toasted then refusedVehicles = refusedVehicles + 1 end
    end
    eq(#bad, 0, ('all %d lines the rows can type are taken'):format(#lines), table.concat(bad, '; '))
    ok(#lines > 90, 'and that is every value of every row, every vehicle among them', #lines)
    eq(vehicleLines, 41, 'fixture: forty-one vehicle rows were pressed')
    eq(#created - built, vehicleLines + 1, 'and every vehicle line built one vehicle')
    eq(refusedVehicles, 0, 'with no refusal among them')
end

-- =========================================================================
-- PART D -- br_ddb's answer about its own tables
-- =========================================================================

describe('br_ddb/server/tables.lua answers what the bundle decided')
do
    -- ═══ THE SAME TWO CONVARS, READ THE SAME WAY, AS src/prefix.js ═══
    --
    -- The gives refuse unless br_ddb named the dev- tables as it started. The
    -- bundle decides that in JS (devConvarsOn: a name in DEV_CONVARS reading
    -- exactly 'true'); tables.lua answers for it in Lua. Two copies of one
    -- rule, held together here.
    local f = io.open('js-src/br_ddb/src/prefix.js', 'r')
    local js = f and f:read('a') or ''
    if f then f:close() end
    local list = js:match("export const DEV_CONVARS = %[([^%]]*)%]") or ''
    local jsNames = {}
    for n in list:gmatch("'([^']+)'") do jsNames[#jsNames + 1] = n end
    ok(#jsNames == 2, 'fixture: prefix.js names its dev convars', list)
    ok(js:find("getConvar(name, 'false') === 'true'", 1, true) ~= nil,
       'fixture: and reads each as exactly \'true\', defaulting to \'false\'')

    local g = io.open(ROOT .. 'br_ddb/server/tables.lua', 'r')
    local lua = g and g:read('a') or ''
    if g then g:close() end
    local luaList = lua:match('local DEV_CONVARS = {([^}]*)}') or ''
    local luaNames = {}
    for n in luaList:gmatch("'([^']+)'") do luaNames[#luaNames + 1] = n end
    eq(table.concat(luaNames, ','), table.concat(jsNames, ','),
       'tables.lua reads the same convars, in the same order')
    ok(lua:find("GetConvar(name, 'false') == 'true'", 1, true) ~= nil,
       'the same way')

    -- AND IT ANSWERS: one run per box, the export read back.
    local function boot(vals)
        local exported = {}
        BR = nil
        function GetConvar(n, d)
            local v = vals[n]
            if v == nil then return d end
            return v
        end
        function exports(name, fn) exported[name] = fn end
        loadAll({ 'br_ddb/server/tables.lua' })
        exports = nil
        return exported.devTables and exported.devTables()
    end
    eq(boot({}), false, 'a production box: the production tables')
    eq(boot({ sv_devMode = 'true' }), true, 'sv_devMode on: the dev tables')
    eq(boot({ br_devMode = 'true' }), true, 'br_devMode on: the dev tables')
    eq(boot({ br_devMode = 'TRUE' }), false, 'anything but exactly true is not dev mode, as in JS')

    local m = io.open(ROOT .. 'br_ddb/fxmanifest.lua', 'r')
    local manifest = m and m:read('a') or ''
    if m then m:close() end
    ok(manifest:find("'server/tables.lua'", 1, true) ~= nil, 'and br_ddb loads it')
end

print = realPrint
realPrint(('\n%d passed, %d failed'):format(pass, fail))
if fail > 0 then os.exit(1) end
