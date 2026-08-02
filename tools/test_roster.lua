-- Unit tests for the roster, broadcast fanout and match state machine.
--
-- These are the pieces every later milestone builds on, and the ones where a
-- mistake is least visible: a roster that drifts produces a wrong alive count
-- twenty minutes into a match, not an error at load.

local fakeTime = 0
function GetGameTimer() return fakeTime end
function GetConvar(_, d) return d end
function GetCurrentResourceName() return 'br_core' end

local playerNames = {}
function GetPlayerName(src) return playerNames[src] or ('Player' .. tostring(src)) end

-- Server-side player enumeration and entity reads. Not scope-limited on the
-- server, which is the whole reason the roster is built here.
local connected = {}
function GetPlayers()
    local out = {}
    for src in pairs(connected) do out[#out + 1] = tostring(src) end
    table.sort(out)
    return out
end
-- GET_PLAYER_PED takes playerSrc as a STRING; the stub matches so the test
-- exercises the same call shape the server does.
-- noPed simulates OneSync being off, or a player who has not spawned: they are
-- connected and on the roster, but the server cannot resolve a ped for them.
local noPed = {}
function GetPlayerPed(src)
    local n = tonumber(src)
    if noPed[n] then return 0 end
    return connected[n] and (1000 + n) or 0
end
function GetEntityCoords() return { x = 0.0, y = 0.0, z = 0.0 } end

-- Health is driven through this table rather than set on roster entries
-- directly. roster.positions samples health every pass and would overwrite a
-- hand-set value before combat.deathcheck ever read it -- so poking the entry
-- tests nothing, while this exercises the real path: server samples, server
-- observes death, server eliminates.
local pedHealth = {}
function GetEntityHealth(ped) return pedHealth[ped] or 200 end
function GetPedArmour() return 0 end

-- Routing buckets, captured for assertion: the lobby is per-player private,
-- matches are shared.
local buckets = {}
function SetPlayerRoutingBucket(src, bucket) buckets[tonumber(src)] = bucket end
function SetRoutingBucketPopulationEnabled() end

-- Capture outbound traffic so tests can assert on what clients would receive.
local sent = {}
function TriggerClientEvent(event, target, ...)
    sent[#sent + 1] = { event = event, target = target, args = { ... } }
end
function RegisterNetEvent() end
function RegisterCommand() end

local realPrint = print
function print() end

Citizen = { CreateThread = function() end, Wait = function() end,
            SetTimeout = function() end }
local handlers = {}
function AddEventHandler(n, fn)
    handlers[n] = handlers[n] or {}
    table.insert(handlers[n], fn)
end
local function fire(name, src, ...)
    source = src
    for _, fn in ipairs(handlers[name] or {}) do fn(...) end
end

local ROOT = 'resources/[fivem-royale]/'
for _, f in ipairs({
    'br_lib/shared/enums.lua', 'br_lib/shared/protocol.lua',
    'br_lib/shared/rng.lua', 'br_lib/shared/geo.lua', 'br_lib/shared/clock.lua',
    'br_lib/config/match.lua', 'br_lib/config/storm.lua', 'br_lib/config/map.lua',
    'br_lib/config/weapons.lua', 'br_lib/config/loot.lua',
    'br_lib/shared/storm_solve.lua',
    'br_core/server/main.lua',
    'br_core/server/broadcast.lua',
    'br_core/server/roster.lua',
    'br_core/server/lobby.lua',
    'br_core/server/party.lua',
    'br_core/server/match.lua',
    'br_core/server/bus.lua',
    'br_core/server/combat.lua',
}) do
    local chunk, err = loadfile(ROOT .. f)
    if not chunk then
        realPrint('\27[31mload error\27[0m ' .. f .. ': ' .. tostring(err))
        os.exit(1)
    end
    chunk()
end

-- br_core/server/chat.lua is not loaded here, so stub what match.lua calls.
BR.Server.systemMessage = function() end

local pass, fail = 0, 0
local group = ''
local function describe(n) group = n end
local function ok(cond, name, detail)
    if cond then pass = pass + 1 else
        fail = fail + 1
        realPrint('\27[31mFAIL\27[0m ' .. group .. ' > ' .. name ..
            (detail and ('\n       ' .. tostring(detail)) or ''))
    end
end

-- The value the CONFIG ships (dev minimum 1, so a lone client can walk the
-- flow). Captured before reset() pins the suite default below.
local SHIPPED_MIN_TO_START = BR.Config.Match.minToStart

local function reset()
    -- Suite default: matches need TWO queued players. Most blocks queue
    -- players one at a time and assert nothing starts early -- under the
    -- shipped dev minimum of 1 the match would start at the first queueUp
    -- and every later assertion would be testing the wrong match. Blocks
    -- that care about the shipped value (match.soloDev) set it themselves.
    BR.Config.Match.minToStart = 2

    for k in pairs(BR.Server.roster) do BR.Server.roster[k] = nil end
    for k in pairs(BR.Server.parties or {}) do BR.Server.parties[k] = nil end
    for k in pairs(connected) do connected[k] = nil end
    -- The queue survives a roster wipe otherwise, and a leftover queue from the
    -- previous block silently changes what the state machine decides -- which
    -- is exactly the kind of cross-test leak that makes a real failure look
    -- like a flake.
    BR.Lobby.clear()
    sent = {}
    BR.Server.match.state = BR.MatchState.WAITING
    BR.Server.match.endsAt = 0
end

local function join(src, name)
    connected[src] = true
    playerNames[src] = name
    fire('playerJoining', src)
end

--- Join AND opt in to a match.
---
--- A match starts on the QUEUED count, not the connected count: being present
--- and wanting to play are different things, and starting on connections would
--- drag anyone idling in the lobby into a match they never asked for.
local function queueUp(src, name, mode)
    join(src, name)
    fire(BR.Net.QUEUE_JOIN, src, { mode = mode or 'solo' })
end

--- Simulate a real disconnect.
---
--- Firing playerDropped alone is not faithful: the player would still be in
--- GetPlayers(), so roster.reconcile correctly re-adopts them a few seconds
--- later. A genuine disconnect removes them from both.
local function leave(src)
    connected[src] = nil
    fire('playerDropped', src, 'quit')
end

local function eventsOf(name)
    local out = {}
    for _, s in ipairs(sent) do
        if s.event == name then out[#out + 1] = s end
    end
    return out
end

-- ----------------------------------------------------------------- roster ---

describe('roster')
do
    reset()
    join(1, 'Alice'); join(2, 'Bob')

    ok(BR.Server.count() == 2, 'players are added on playerJoining')
    ok(BR.Roster.get(1).name == 'Alice', 'names are captured')
    ok(BR.Roster.get(1).state == BR.PlayerState.LOBBY, 'new players start in the lobby')

    join(1, 'Alice')
    ok(BR.Server.count() == 2, 'adding an existing player is idempotent')

    fire('playerDropped', 2, 'quit')
    ok(BR.Server.count() == 1, 'players are removed on playerDropped')
    ok(BR.Roster.get(2) == nil, 'and the entry is gone')

    fire('playerDropped', 99, 'quit')
    ok(BR.Server.count() == 1, 'dropping an unknown player is harmless')
end

describe('roster.privacy')
do
    -- SECURITY-RELEVANT. The public view is what gets broadcast to every client.
    -- Anything leaking here is available to anyone reading the event stream, so
    -- positions in particular would be a wallhack handed out for free.
    reset()
    join(1, 'Alice')
    local e = BR.Roster.get(1)
    e.pos = { x = 100.0, y = 200.0, z = 30.0 }
    e.license = 'license:deadbeef'
    e.engineHp = 175
    e.lastDamageBy = 2

    local pub = BR.Roster.public(e)

    ok(pub.pos == nil,          'position is NOT replicated to clients')
    ok(pub.license == nil,      'license is NOT replicated to clients')
    ok(pub.engineHp == nil,     'raw engine health is NOT replicated')
    ok(pub.lastDamageBy == nil, 'damage bookkeeping is NOT replicated')

    ok(pub.name ~= nil,   'name IS replicated')
    ok(pub.state ~= nil,  'state IS replicated')
    ok(pub.hp ~= nil,     'display health IS replicated')
    ok(pub.kills ~= nil,  'kills ARE replicated')

    local all = BR.Roster.publicAll()
    ok(all[1] ~= nil and all[1].pos == nil, 'publicAll applies the same filter')
end

describe('roster.updates')
do
    reset()
    join(1, 'Alice')
    sent = {}

    BR.Roster.update(1, { kills = 3 })
    ok(BR.Roster.get(1).kills == 3, 'update writes the field')

    BR.Roster.update(1, { pos = { x = 1, y = 2, z = 3 } })
    ok(BR.Roster.get(1).pos ~= nil, 'private fields are still stored server-side')

    BR.Broadcast.flushNow()
    local deltas = eventsOf(BR.Net.ROSTER_DELTA)
    local sawPos = false
    for _, s in ipairs(deltas) do
        for _, d in ipairs(s.args[1].deltas or {}) do
            if d.e and d.e.pos then sawPos = true end
        end
    end
    ok(not sawPos, 'but private fields are never put on the wire')

    local before = #eventsOf(BR.Net.ROSTER_DELTA)
    BR.Roster.update(1, { kills = 3 })   -- same value
    BR.Broadcast.flushNow()
    ok(#eventsOf(BR.Net.ROSTER_DELTA) == before,
        'setting a field to its current value sends nothing')

    ok(BR.Roster.update(999, { kills = 1 }) == nil, 'updating an unknown player is safe')
end

describe('roster.clearFields')
do
    -- REGRESSION: a nil cannot travel in a serialised delta. Assigning
    -- entry.squadId = nil made the key VANISH from the payload rather than
    -- arriving as an instruction to forget it, so every client kept displaying
    -- the value it was last told. Clearing therefore needs its own wire
    -- instruction: a list of field names to drop.
    reset()
    join(1, 'Alice')
    BR.Roster.update(1, { squadId = 'sq1', colour = '#ff0000' })
    BR.Broadcast.flushNow()
    sent = {}

    BR.Roster.clearFields(1, { 'squadId', 'colour' })
    ok(BR.Roster.get(1).squadId == nil, 'the field is cleared server-side')

    BR.Broadcast.flushNow()
    local cleared = {}
    for _, s in ipairs(eventsOf(BR.Net.ROSTER_DELTA)) do
        for _, d in ipairs(s.args[1].deltas or {}) do
            for _, k in ipairs(d.clear or {}) do cleared[k] = true end
        end
    end
    ok(cleared.squadId, 'and the wire carries a named clear instruction')
    ok(cleared.colour, 'for every cleared public field')

    -- The same privacy rule as updates: clearing a private field must not
    -- announce that the field existed.
    BR.Roster.update(1, { pos = { x = 1, y = 2, z = 3 } })
    BR.Broadcast.flushNow()
    sent = {}
    BR.Roster.clearFields(1, { 'pos' })
    BR.Broadcast.flushNow()
    ok(#eventsOf(BR.Net.ROSTER_DELTA) == 0,
        'clearing a private field sends nothing')

    sent = {}
    BR.Roster.clearFields(1, { 'squadId' })   -- already nil
    BR.Broadcast.flushNow()
    ok(#eventsOf(BR.Net.ROSTER_DELTA) == 0,
        'clearing an already-absent field sends nothing')

    ok(pcall(BR.Roster.clearFields, 999, { 'squadId' }),
        'clearing on an unknown player is safe')
end

describe('roster.healthSync')
do
    -- REGRESSION: the sampler read engine health but never converted it into
    -- the display value the roster, brwhy and every squad panel actually use.
    -- entry.hp stayed pinned at its initial 100, so a player lying dead at the
    -- bottom of a cliff reported full health.
    reset()
    join(1, 'A')
    local e = BR.Roster.get(1)
    ok(e.hp == 100.0, 'players start at full display health')

    -- Halfway between the floor and max, computed from config rather than
    -- hardcoded -- this test is about the CONVERSION HAPPENING, not about
    -- where the floor sits (that is pinned in test_shared's health block).
    local mid = (BR.Config.Match.healthFloor + BR.Config.Match.maxHealth) // 2
    pedHealth[1001] = mid
    fakeTime = fakeTime + 1000
    BR.Sched.step(fakeTime)

    ok(BR.Roster.get(1).hp == 50,
        'sampled engine health becomes display health',
        ('got %s'):format(tostring(BR.Roster.get(1).hp)))
    ok(BR.Roster.get(1).engineHp == mid, 'and the raw engine value is kept too')

    pedHealth[1001] = BR.Config.Match.healthFloor
    fakeTime = fakeTime + 1000
    BR.Sched.step(fakeTime)
    ok(BR.Roster.get(1).hp == 0, 'a dead player reports zero display health',
        ('got %s'):format(tostring(BR.Roster.get(1).hp)))

    -- Health changes must reach clients, or squad panels show stale bars.
    sent = {}
    pedHealth[1001] = 200
    fakeTime = fakeTime + 1000
    BR.Sched.step(fakeTime)
    BR.Broadcast.flushNow()
    local sawHp = false
    for _, s in ipairs(eventsOf(BR.Net.ROSTER_DELTA)) do
        for _, d in ipairs(s.args[1].deltas or {}) do
            if d.e and d.e.hp ~= nil then sawHp = true end
        end
    end
    ok(sawHp, 'a health change is broadcast to clients')

    -- ...but an unchanged value must not be, or 48 players at 2Hz would flood
    -- the wire with deltas that say nothing.
    sent = {}
    fakeTime = fakeTime + 1000
    BR.Sched.step(fakeTime)
    BR.Broadcast.flushNow()
    local sawIdle = false
    for _, s in ipairs(eventsOf(BR.Net.ROSTER_DELTA)) do
        for _, d in ipairs(s.args[1].deltas or {}) do
            if d.e and d.e.hp ~= nil then sawIdle = true end
        end
    end
    ok(not sawIdle, 'unchanged health generates no traffic')

    pedHealth[1001] = nil
end

describe('roster.reconcile')
do
    -- A resource restart mid-session leaves an empty roster and a full server.
    reset()
    connected[1], connected[2], connected[3] = true, true, true
    ok(BR.Server.count() == 0, 'roster starts empty after a restart')

    BR.Sched.setEnabled('roster.reconcile', true)
    fakeTime = fakeTime + 10000
    BR.Sched.step(fakeTime)

    ok(BR.Server.count() == 3, 'reconcile adopts already-connected players',
        ('got %d'):format(BR.Server.count()))

    connected[2] = nil
    fakeTime = fakeTime + 10000
    BR.Sched.step(fakeTime)
    ok(BR.Server.count() == 2, 'reconcile drops players who are gone',
        ('got %d'):format(BR.Server.count()))
end

-- -------------------------------------------------------------- broadcast ---

describe('broadcast')
do
    reset()
    join(1, 'Alice'); join(2, 'Bob'); join(3, 'Cara')
    BR.Broadcast.flushNow()
    sent = {}

    -- Coalescing: several changes in one window become one event, not one each.
    BR.Roster.update(1, { kills = 1 })
    BR.Roster.update(2, { kills = 2 })
    BR.Roster.update(3, { kills = 3 })
    ok(#eventsOf(BR.Net.ROSTER_DELTA) == 0, 'deltas queue rather than sending immediately')

    BR.Broadcast.flushNow()
    local ev = eventsOf(BR.Net.ROSTER_DELTA)
    ok(#ev == 1, 'a whole window flushes as one event', ('got %d'):format(#ev))
    ok(#ev[1].args[1].deltas == 3, 'carrying every queued change',
        ('got %d'):format(#ev[1].args[1].deltas))

    -- Scope independence: everything goes to -1, never to a scoped subset.
    ok(ev[1].target == -1, 'roster deltas broadcast to everyone, not to a scope')

    sent = {}
    BR.Broadcast.flushNow()
    ok(#eventsOf(BR.Net.ROSTER_DELTA) == 0, 'an empty queue sends nothing')

    sent = {}
    BR.Broadcast.snapshot(2)
    local snaps = eventsOf(BR.Net.SNAPSHOT)
    ok(#snaps == 1 and snaps[1].target == 2, 'a snapshot can target one player')
    local payload = snaps[1].args[1]
    ok(payload.roster and payload.roster[1] and payload.roster[3],
        'the snapshot carries the whole roster regardless of scope')
    ok(payload.roster[1].pos == nil, 'and applies the privacy filter too')
end

describe('broadcast.ordering')
do
    reset()
    join(1, 'Alice')
    BR.Broadcast.flushNow()
    sent = {}

    -- A client must not learn the match started before it learns who is in it.
    BR.Roster.update(1, { kills = 5 })
    BR.Broadcast.state(BR.MatchState.PLAYING, 12345)

    local order = {}
    for _, s in ipairs(sent) do
        if s.event == BR.Net.ROSTER_DELTA then order[#order + 1] = 'delta'
        elseif s.event == BR.Net.STATE then order[#order + 1] = 'state' end
    end
    ok(order[1] == 'delta' and order[2] == 'state',
        'queued deltas flush before a state change',
        table.concat(order, ','))
end

-- ------------------------------------------------------------------ match ---

describe('match.transitions')
do
    reset()
    BR.Server.devMode = true

    -- Connected but NOT queued: the match must not start.
    join(1, 'Alice')
    join(2, 'Bob')
    fakeTime = fakeTime + 1000
    BR.Sched.step(fakeTime)
    ok(BR.Server.match.state == BR.MatchState.WAITING,
        'connected players alone do not start a match')

    fire(BR.Net.QUEUE_JOIN, 1, { mode = 'solo' })
    fakeTime = fakeTime + 1000
    BR.Sched.step(fakeTime)
    ok(BR.Server.match.state == BR.MatchState.WAITING,
        'one queued player is not enough to start')

    fire(BR.Net.QUEUE_JOIN, 2, { mode = 'solo' })
    fakeTime = fakeTime + 1000
    BR.Sched.step(fakeTime)
    ok(BR.Server.match.state == BR.MatchState.WARMUP,
        'reaching the minimum QUEUED count starts warmup')
    ok(BR.Lobby.count() == 0, 'and the queue is cleared once the match begins')
    ok(BR.Roster.get(1).state == BR.PlayerState.WARMUP,
        'players move to warmup with the match')
    ok(BR.Server.match.endsAt > fakeTime, 'warmup has a deadline')

    -- Countdowns are derived from endsAt, never ticked over the network.
    fakeTime = BR.Server.match.endsAt + 1
    BR.Sched.step(fakeTime)
    ok(BR.Server.match.state == BR.MatchState.BUS, 'warmup expires into the bus')
    ok(BR.Roster.get(1).state == BR.PlayerState.BUS, 'players board the bus')

    fakeTime = BR.Server.match.endsAt + 1
    BR.Sched.step(fakeTime)
    ok(BR.Server.match.state == BR.MatchState.PLAYING, 'the bus route ends in play')
    -- Since M3, the transition does not make anyone alive -- riders were
    -- force-ejected at the end of the chord and are falling; LANDING is what
    -- makes a player alive (pinned in match.bus).
    ok(BR.Roster.get(1).state == BR.PlayerState.FREEFALL,
        'riders who never jumped are falling, not alive')
    fire(BR.Net.DROP_LANDED, 1)
    fire(BR.Net.DROP_LANDED, 2)
    ok(BR.Roster.get(1).state == BR.PlayerState.ALIVE, 'players are alive once they land')
end

describe('match.winCondition')
do
    -- Two solo players: eliminating one should end the match, because solos each
    -- count as their own team.
    ok(BR.Server.match.state == BR.MatchState.PLAYING, 'starting from PLAYING')
    ok(BR.Server.squadsAlive() == 2, 'two solos are two teams')

    BR.Roster.setState(2, BR.PlayerState.DEAD)
    fakeTime = fakeTime + 4000   -- past WIN_GRACE_MS
    BR.Sched.step(fakeTime)

    ok(BR.Server.match.state == BR.MatchState.ENDED, 'one team left ends the match')
    ok(BR.Roster.get(1).placement == 1, 'the survivor is placed first')

    fakeTime = BR.Server.match.endsAt + 1
    BR.Sched.step(fakeTime)
    ok(BR.Server.match.state == BR.MatchState.CLEANUP, 'ended expires into cleanup')
    ok(BR.Roster.get(1).placement == nil, 'cleanup clears per-match state')
    ok(BR.Roster.get(1).state == BR.PlayerState.LOBBY, 'and returns players to the lobby')
end

describe('match.squads')
do
    reset()
    BR.Server.devMode = true
    join(1, 'A'); join(2, 'B'); join(3, 'C'); join(4, 'D')
    BR.Roster.update(1, { squadId = 'sq1' })
    BR.Roster.update(2, { squadId = 'sq1' })
    BR.Roster.update(3, { squadId = 'sq2' })
    BR.Roster.update(4, { squadId = 'sq2' })

    BR.Match.transition(BR.MatchState.PLAYING)
    BR.Roster.each(nil, function(src) BR.Roster.setState(src, BR.PlayerState.ALIVE) end)

    ok(BR.Server.squadsAlive() == 2, 'four players in two squads are two teams')

    BR.Roster.setState(1, BR.PlayerState.DEAD)
    ok(BR.Server.squadsAlive() == 2, 'a squad with a survivor is still up')

    -- A downed player is not out: their squad is still contesting the match.
    BR.Roster.setState(2, BR.PlayerState.DBNO)
    ok(BR.Server.squadsAlive() == 2, 'a downed player still counts for their squad')

    BR.Roster.setState(2, BR.PlayerState.DEAD)
    fakeTime = fakeTime + 4000   -- past WIN_GRACE_MS
    BR.Sched.step(fakeTime)
    ok(BR.Server.match.state == BR.MatchState.ENDED, 'wiping a squad ends the match')

    local placed = 0
    BR.Roster.each(function(e) return e.placement == 1 end, function() placed = placed + 1 end)
    ok(placed == 2, 'the whole winning squad shares first place', ('got %d'):format(placed))
end

describe('match.disconnects')
do
    -- A disconnect mid-match must not leave a phantom keeping the match alive.
    reset()
    BR.Server.devMode = true
    join(1, 'A'); join(2, 'B')
    BR.Match.transition(BR.MatchState.PLAYING)
    BR.Roster.each(nil, function(src) BR.Roster.setState(src, BR.PlayerState.ALIVE) end)
    ok(BR.Server.squadsAlive() == 2, 'two players in play')

    leave(2)
    fakeTime = fakeTime + 4000   -- past WIN_GRACE_MS
    BR.Sched.step(fakeTime)

    ok(BR.Server.match.state == BR.MatchState.ENDED,
        'a disconnect can end the match like an elimination')
    ok(BR.Roster.get(2) == nil, 'and the leaver is gone from the roster')
end

-- ------------------------------------------------------------------ queue ---

describe('lobby.queue')
do
    reset()
    BR.Server.devMode = true
    BR.Lobby.clear()

    join(1, 'A'); join(2, 'B'); join(3, 'C')
    ok(BR.Lobby.count() == 0, 'joining does not queue you')

    fire(BR.Net.QUEUE_JOIN, 1, { mode = 'solo' })
    ok(BR.Lobby.count() == 1, 'queueing adds you')

    fire(BR.Net.QUEUE_JOIN, 1, { mode = 'solo' })
    ok(BR.Lobby.count() == 1, 'queueing twice is idempotent')

    fire(BR.Net.QUEUE_LEAVE, 1)
    ok(BR.Lobby.count() == 0, 'leaving removes you')

    fire(BR.Net.QUEUE_LEAVE, 1)
    ok(BR.Lobby.count() == 0, 'leaving when not queued is harmless')

    -- A client can send anything. An unrecognised mode must not be stored and
    -- later used to index a config table.
    fire(BR.Net.QUEUE_JOIN, 2, { mode = 'nonsense' })
    ok(BR.Server.queue[2] ~= nil, 'an unknown mode still queues the player')
    ok(BR.Server.queue[2].mode == BR.Mode.SOLO.key,
        'and falls back to a real mode',
        tostring(BR.Server.queue[2].mode))

    fire(BR.Net.QUEUE_JOIN, 3, {})
    ok(BR.Server.queue[3].mode == BR.Mode.SOLO.key, 'a missing mode falls back too')

    -- Disconnecting must not leave a phantom holding a queue slot, or a match
    -- could start for players who are no longer there.
    fire('playerDropped', 2, 'quit')
    ok(BR.Server.queue[2] == nil, 'dropping removes you from the queue')

    BR.Lobby.clear()
    ok(BR.Lobby.count() == 0, 'clear empties the queue')
end

describe('lobby.mode')
do
    reset()
    BR.Server.devMode = true
    BR.Lobby.clear()
    join(1, 'A'); join(2, 'B'); join(3, 'C')

    fire(BR.Net.QUEUE_JOIN, 1, { mode = 'solo' })
    fire(BR.Net.QUEUE_JOIN, 2, { mode = 'solo' })
    fire(BR.Net.QUEUE_JOIN, 3, { mode = 'squad' })
    ok(BR.Lobby.dominantMode() == 'solo', 'the majority mode wins',
        BR.Lobby.dominantMode())

    BR.Lobby.clear()
    fire(BR.Net.QUEUE_JOIN, 1, { mode = 'solo' })
    fire(BR.Net.QUEUE_JOIN, 2, { mode = 'squad' })
    -- Ties favour squad: a solo player dropped into a squad match still plays,
    -- whereas a squad dropped into solos loses the mode entirely.
    ok(BR.Lobby.dominantMode() == 'squad', 'a tie falls to squad',
        BR.Lobby.dominantMode())

    BR.Lobby.clear()
end

describe('lobby.midMatch')
do
    -- The queue gate is the PLAYER's state, not the match's. A lobby player
    -- may queue at any time -- the WAITING tick is the only consumer, so
    -- queueing during a live match just means waiting in line for the next
    -- one. A player still IN the match may not queue; leaving is explicit.
    reset()
    BR.Server.devMode = true
    BR.Lobby.clear()
    join(1, 'A'); join(2, 'B')

    BR.Match.transition(BR.MatchState.PLAYING)
    BR.Roster.setState(1, BR.PlayerState.ALIVE)

    fire(BR.Net.QUEUE_JOIN, 1, { mode = 'solo' })
    ok(BR.Lobby.count() == 0, 'an in-match player cannot queue')

    fire(BR.Net.QUEUE_JOIN, 2, { mode = 'solo' })
    ok(BR.Lobby.count() == 1,
        'a lobby player queues for the NEXT match while this one runs')
    ok(BR.Server.match.state == BR.MatchState.PLAYING,
        'and the running match does not notice')

    BR.Lobby.clear()
end

-- ------------------------------------------------------------------ party ---

describe('party.invite')
do
    reset()
    BR.Server.devMode = true
    join(1, 'Alice'); join(2, 'Bob'); join(3, 'Cara')

    ok(BR.Party.of(1) == nil, 'players start with no party')

    -- Inviting creates the inviter's party implicitly. A separate "create
    -- party" step is one more thing to forget.
    local ok1 = BR.Party.invite(1, 2)
    ok(ok1, 'inviting succeeds')
    ok(BR.Party.of(1) ~= nil, 'and creates a party for the inviter')
    ok(BR.Party.size(BR.Party.of(1).id) == 1, 'which contains only them until accepted')

    BR.Party.respond(2, true)
    ok(BR.Party.of(2) ~= nil, 'accepting joins the party')
    ok(BR.Party.of(2).id == BR.Party.of(1).id, 'the same party')
    ok(BR.Party.size(BR.Party.of(1).id) == 2, 'now with two members')

    -- Declining must not join, and must consume the invite.
    BR.Party.invite(1, 3)
    BR.Party.respond(3, false)
    ok(BR.Party.of(3) == nil, 'declining does not join')
    local again = BR.Party.respond(3, true)
    ok(not again, 'and the invite is consumed -- no accepting it later')

    ok(not BR.Party.invite(1, 1), 'you cannot invite yourself')
    ok(not BR.Party.invite(1, 999), 'you cannot invite someone not connected')

    -- Only the leader invites, or any member could grow the party unilaterally.
    ok(not BR.Party.invite(2, 3), 'non-leaders cannot invite')
end

describe('party.leave')
do
    reset()
    BR.Server.devMode = true
    join(1, 'A'); join(2, 'B'); join(3, 'C'); join(4, 'D')
    for i = 2, 4 do BR.Party.invite(1, i); BR.Party.respond(i, true) end

    local pid = BR.Party.of(1).id
    ok(BR.Party.size(pid) == 4, 'four in the party')

    BR.Party.leave(4)
    ok(BR.Party.of(4) == nil, 'leaving clears your party')
    ok(BR.Party.size(pid) == 3, 'and removes you from it')

    -- The leader leaving must not orphan everyone else.
    ok(BR.Party.of(1).leader == 1, 'player 1 leads')
    BR.Party.leave(1)
    ok(BR.Party.of(2) ~= nil, 'the party survives the leader leaving')
    ok(BR.Party.of(2).leader == 2, 'and someone else is promoted')

    -- Down to one is down to none: see party.ofOne for why a lone member left
    -- holding a party id is a trap rather than a tidiness question.
    BR.Party.leave(2)
    ok(BR.Server.parties[pid] == nil, 'the party is deleted once it cannot field two')
    ok(BR.Party.of(3) == nil, 'and the last member is released with it')
end

describe('party.kick')
do
    reset()
    BR.Server.devMode = true
    join(1, 'A'); join(2, 'B')
    BR.Party.invite(1, 2); BR.Party.respond(2, true)

    ok(not BR.Party.kick(2, 1), 'a non-leader cannot kick')
    ok(BR.Party.kick(1, 2), 'the leader can')
    ok(BR.Party.of(2) == nil, 'and the target is removed')
end

describe('party.capacity')
do
    reset()
    BR.Server.devMode = true
    local maxSize = BR.Config.Match.maxSquadSize
    for i = 1, maxSize + 1 do join(i, 'P' .. i) end

    for i = 2, maxSize do
        BR.Party.invite(1, i)
        BR.Party.respond(i, true)
    end
    ok(BR.Party.size(BR.Party.of(1).id) == maxSize, 'party fills to the maximum')

    local over = BR.Party.invite(1, maxSize + 1)
    ok(not over, 'and refuses to go beyond it')
end

describe('party.persistence')
do
    -- The entire reason parties exist separately from squads: they must survive
    -- a match, or players re-invite each other every single round.
    reset()
    BR.Server.devMode = true
    join(1, 'A'); join(2, 'B')
    BR.Party.invite(1, 2); BR.Party.respond(2, true)
    local pid = BR.Party.of(1).id

    BR.Match.transition(BR.MatchState.PLAYING)
    BR.Roster.each(nil, function(src) BR.Roster.setState(src, BR.PlayerState.ALIVE) end)
    BR.Match.transition(BR.MatchState.ENDED)
    BR.Match.transition(BR.MatchState.CLEANUP)

    ok(BR.Party.of(1) ~= nil, 'the party survives a completed match')
    ok(BR.Party.of(1).id == pid, 'and it is the same party')
    ok(BR.Roster.get(1).squadId == nil, 'while the in-match squad is cleared')

    -- Disconnecting does leave the party -- a ghost member would hold a slot.
    leave(2)
    ok(BR.Party.size(pid) == 1, 'disconnecting removes you from the party')
end

describe('party.squadFormation')
do
    reset()
    BR.Server.devMode = true
    BR.Config.Match.autofill = true
    for i = 1, 6 do join(i, 'P' .. i) end

    -- 1+2 are a party; 3..6 are solos to be filled around them.
    BR.Party.invite(1, 2); BR.Party.respond(2, true)
    BR.Roster.each(nil, function(src) BR.Roster.setState(src, BR.PlayerState.WARMUP) end)

    BR.Party.formSquads(BR.Mode.SQUAD.key)

    local sq1 = BR.Roster.get(1).squadId
    ok(sq1 ~= nil, 'squads are assigned')
    ok(BR.Roster.get(2).squadId == sq1, 'a party is never split across squads')

    -- Every player placed, and no squad over the cap.
    local counts, unplaced = {}, 0
    BR.Roster.each(nil, function(_, e)
        if e.squadId then counts[e.squadId] = (counts[e.squadId] or 0) + 1
        else unplaced = unplaced + 1 end
    end)
    ok(unplaced == 0, 'everyone is placed in a squad')

    local over = 0
    for _, n in pairs(counts) do
        if n > BR.Config.Match.maxSquadSize then over = over + 1 end
    end
    ok(over == 0, 'no squad exceeds the maximum size')

    -- Solo mode has no squads at all: each player is their own team, and a
    -- squadId would only confuse the win condition.
    BR.Party.formSquads(BR.Mode.SOLO.key)
    local anySquad = false
    BR.Roster.each(nil, function(_, e) if e.squadId then anySquad = true end end)
    ok(not anySquad, 'solo mode assigns no squads')

    -- Without autofill, solos stand alone rather than being merged.
    BR.Config.Match.autofill = false
    BR.Roster.each(nil, function(src) BR.Roster.setState(src, BR.PlayerState.WARMUP) end)
    BR.Party.formSquads(BR.Mode.SQUAD.key)
    ok(BR.Roster.get(3).squadId ~= BR.Roster.get(4).squadId,
        'without autofill, solo players are not merged')
    BR.Config.Match.autofill = true
end

describe('party.noOrphans')
do
    -- Greedy fill packed each squad full before opening the next, so five
    -- players at a cap of four became 4 + 1 and somebody played a squad round
    -- alone against a full team.
    reset()
    BR.Server.devMode = true
    BR.Config.Match.autofill = true

    local function sizesFor(n)
        reset()
        BR.Server.devMode = true
        for i = 1, n do join(i, 'P' .. i) end
        BR.Roster.each(nil, function(src) BR.Roster.setState(src, BR.PlayerState.WARMUP) end)
        BR.Party.formSquads(BR.Mode.SQUAD.key)

        local counts = {}
        BR.Roster.each(nil, function(_, e)
            if e.squadId then counts[e.squadId] = (counts[e.squadId] or 0) + 1 end
        end)
        local sizes = {}
        for _, c in pairs(counts) do sizes[#sizes + 1] = c end
        table.sort(sizes)
        return sizes
    end

    for _, n in ipairs({ 5, 6, 7, 9, 13 }) do
        local sizes = sizesFor(n)
        local lone, total = 0, 0
        for _, c in ipairs(sizes) do
            if c == 1 then lone = lone + 1 end
            total = total + c
        end
        ok(total == n, ('%d players are all placed'):format(n))
        ok(lone == 0, ('%d players leave nobody in a squad of one'):format(n))
    end

    -- With one player there is no way to avoid a squad of one; it must not
    -- crash or drop them, and the minSquads gate is what stops such a match.
    ok(#sizesFor(1) == 1, 'a single player still forms one squad')
end

describe('party.prospectiveSquads')
do
    -- The gate and the outcome must agree. If the prediction says two squads
    -- and formation produces one, the match starts into an instant win -- which
    -- is the exact thing the prediction exists to prevent.
    local function actual(n, partyPairs, mode)
        reset()
        BR.Server.devMode = true
        for i = 1, n do join(i, 'P' .. i) end
        for _, pr in ipairs(partyPairs or {}) do
            BR.Party.invite(pr[1], pr[2]); BR.Party.respond(pr[2], true)
        end

        local ids = {}
        for i = 1, n do ids[#ids + 1] = i end
        local predicted = BR.Party.prospectiveSquads(ids, mode)

        BR.Roster.each(nil, function(src) BR.Roster.setState(src, BR.PlayerState.WARMUP) end)
        BR.Party.formSquads(mode)

        local counts = {}
        BR.Roster.each(nil, function(_, e)
            if e.squadId then counts[e.squadId] = true end
        end)
        local formed = 0
        for _ in pairs(counts) do formed = formed + 1 end
        return predicted, formed
    end

    BR.Config.Match.autofill = true
    for _, case in ipairs({
        { 2, {} }, { 5, {} }, { 8, {} },
        { 4, { { 1, 2 } } },
        { 6, { { 1, 2 }, { 3, 4 } } },
        { 9, { { 1, 2 } } },
    }) do
        local predicted, formed = actual(case[1], case[2], BR.Mode.SQUAD.key)
        ok(predicted == formed,
            ('prediction matches formation for %d players (%d)'):format(case[1], formed))
    end

    -- Solo mode is one "squad" per player, and forms none at all.
    local predicted = actual(5, {}, BR.Mode.SOLO.key)
    ok(predicted == 5, 'solo mode counts every player as their own team')

    BR.Config.Match.autofill = false
    local p2, f2 = actual(3, {}, BR.Mode.SQUAD.key)
    ok(p2 == f2 and p2 == 3, 'without autofill each solo is its own squad')
    BR.Config.Match.autofill = true
end

describe('match.minSquads')
do
    -- A squad match with one squad has already met its win condition at the
    -- starting gun: it would end on the first tick past the grace period.
    reset()
    BR.Server.devMode = false          -- production thresholds: minSquads = 2
    BR.Config.Match.autofill = true

    for i = 1, 20 do join(i, 'P' .. i) end
    -- Everyone in one party would be one squad -- but a party caps at 4, so
    -- instead make the whole queue a single squad by capping size at 20.
    local realMax = BR.Config.Match.maxSquadSize
    BR.Config.Match.maxSquadSize = 20
    for i = 2, 20 do BR.Party.invite(1, i); BR.Party.respond(i, true) end

    for i = 1, 20 do BR.Lobby.join(i, BR.Mode.SQUAD.key) end
    ok(BR.Lobby.count() >= BR.Lobby.needed(), 'the queue is full enough on headcount')
    ok(BR.Party.prospectiveSquads(BR.Lobby.ids(), BR.Mode.SQUAD.key) == 1,
        'but they are all one squad')

    -- The clock MUST advance past the tick interval, or the scheduler simply
    -- does not run the tick and "still WAITING" would be true for the wrong
    -- reason -- a test that passes with the gate deleted.
    fakeTime = fakeTime + 300
    BR.Sched.step(fakeTime)
    ok(BR.Server.match.state == BR.MatchState.WAITING,
        'so the match does not start')
    ok(BR.Lobby.count() == 20, 'and the queue is not consumed')

    -- A second team arrives and it starts.
    BR.Config.Match.maxSquadSize = realMax
    join(21, 'Outsider')
    BR.Lobby.join(21, BR.Mode.SQUAD.key)
    ok(BR.Party.prospectiveSquads(BR.Lobby.ids(), BR.Mode.SQUAD.key) >= 2,
        'a second team makes two')

    fakeTime = fakeTime + 300
    BR.Sched.step(fakeTime)
    ok(BR.Server.match.state == BR.MatchState.WARMUP, 'and now it starts')

    BR.Server.devMode = true
end

describe('party.squadToSolo')
do
    -- REGRESSION, reported in play: two players finished a squad match together,
    -- then queued SOLO -- and both clients still showed them squadded. The
    -- server had it right; the clearing never reached the clients, because a
    -- nil squadId simply dropped out of the delta.
    --
    -- Asserting on the server roster alone would have passed while the bug was
    -- live, so this checks what actually goes over the wire.
    reset()
    BR.Server.devMode = true
    join(1, 'A'); join(2, 'B')
    BR.Roster.each(nil, function(src) BR.Roster.setState(src, BR.PlayerState.WARMUP) end)
    BR.Party.formSquads(BR.Mode.SQUAD.key)

    local sq = BR.Roster.get(1).squadId
    ok(sq ~= nil and BR.Roster.get(2).squadId == sq, 'both start on one squad')

    BR.Broadcast.flushNow()
    sent = {}

    -- The next match is solo.
    BR.Roster.each(nil, function(src) BR.Roster.setState(src, BR.PlayerState.WARMUP) end)
    BR.Party.formSquads(BR.Mode.SOLO.key)
    BR.Broadcast.flushNow()

    ok(BR.Roster.get(1).squadId == nil, 'the squad is dropped server-side')

    local told = {}
    for _, s in ipairs(eventsOf(BR.Net.ROSTER_DELTA)) do
        for _, d in ipairs(s.args[1].deltas or {}) do
            for _, k in ipairs(d.clear or {}) do
                if k == 'squadId' then told[d.src] = true end
            end
        end
    end
    ok(told[1] and told[2], 'and both clients are told to drop it')

    -- Autofill is what pairs unpartied players, so it must not happen in solo.
    ok(BR.Roster.get(1).colour == nil, 'the squad colour goes with it')
end

-- ----------------------------------------------------------------- combat ---

describe('combat.elimination')
do
    reset()
    BR.Server.devMode = true
    join(1, 'A'); join(2, 'B'); join(3, 'C'); join(4, 'D')
    BR.Match.transition(BR.MatchState.PLAYING)
    BR.Roster.each(nil, function(src) BR.Roster.setState(src, BR.PlayerState.ALIVE) end)

    ok(BR.Server.squadsAlive() == 4, 'four solo players are four teams')

    -- Placement counts teams still standing INCLUDING the one dying, so the
    -- first of four to die finishes 4th, not 1st.
    BR.Combat.eliminate(1, 'fall', nil)
    ok(BR.Roster.get(1).state == BR.PlayerState.DEAD, 'eliminating marks the player dead')
    ok(BR.Roster.get(1).placement == 4, 'first death of four takes last place',
        ('got %s'):format(tostring(BR.Roster.get(1).placement)))

    BR.Combat.eliminate(2, 'fall', nil)
    ok(BR.Roster.get(2).placement == 3, 'placements count down as teams fall',
        ('got %s'):format(tostring(BR.Roster.get(2).placement)))

    -- Ordering must be strictly monotonic; two players sharing a placement in a
    -- solo match would be a scoring bug nobody notices until someone complains.
    ok(BR.Roster.get(1).placement > BR.Roster.get(2).placement,
        'an earlier death places worse than a later one')

    BR.Combat.eliminate(1, 'fall', nil)
    ok(BR.Roster.get(1).placement == 4, 'eliminating an already-dead player does nothing')

    reset()
    join(1, 'A')
    BR.Match.transition(BR.MatchState.WAITING)
    BR.Roster.setState(1, BR.PlayerState.LOBBY)
    BR.Combat.eliminate(1, 'fall', nil)
    ok(BR.Roster.get(1).state == BR.PlayerState.LOBBY, 'a player in the lobby cannot be eliminated')
end

describe('combat.credit')
do
    reset()
    BR.Server.devMode = true
    join(1, 'Killer'); join(2, 'Victim'); join(3, 'Bystander')
    BR.Match.transition(BR.MatchState.PLAYING)
    BR.Roster.each(nil, function(src) BR.Roster.setState(src, BR.PlayerState.ALIVE) end)

    BR.Combat.eliminate(2, 'weapon', 1)
    ok(BR.Roster.get(1).kills == 1, 'the killer is credited')
    ok(BR.Roster.get(3).kills == 0, 'bystanders are not')

    -- A player cannot farm kills off themselves.
    BR.Combat.eliminate(3, 'weapon', 3)
    ok(BR.Roster.get(3).kills == 0, 'a self-kill credits nobody')
end

describe('combat.serverObserved')
do
    -- The half a cheating client cannot avoid: the server reads health itself
    -- and eliminates regardless of whether the client ever reported.
    reset()
    BR.Server.devMode = true
    join(1, 'A'); join(2, 'B')
    BR.Match.transition(BR.MatchState.PLAYING)
    BR.Roster.each(nil, function(src) BR.Roster.setState(src, BR.PlayerState.ALIVE) end)

    -- Player 1's ped now reads as dead. Nothing reports it; the server has to
    -- notice on its own.
    pedHealth[1001] = BR.Config.Match.healthFloor

    fakeTime = fakeTime + 2000
    BR.Sched.step(fakeTime)

    ok(BR.Roster.get(1).state == BR.PlayerState.DEAD,
        'the server eliminates on its own health reading, with no client report')
    ok(BR.Roster.get(2).state == BR.PlayerState.ALIVE,
        'and leaves the healthy player alone')
    pedHealth[1001] = nil

    -- Without a ped the check must not fire. No ped means OneSync is off or the
    -- player has not spawned -- neither of which means they are dead, and
    -- treating it as death would eliminate everyone on a misconfigured server.
    reset()
    join(1, 'A'); join(2, 'B')
    BR.Match.transition(BR.MatchState.PLAYING)
    BR.Roster.each(nil, function(src) BR.Roster.setState(src, BR.PlayerState.ALIVE) end)

    -- Simulate "connected but no ped" with a dedicated lever. Removing them from
    -- `connected` would also make roster.reconcile drop them entirely -- correct
    -- behaviour, but not the case under test.
    noPed[1] = true
    pedHealth[1001] = 0

    fakeTime = fakeTime + 2000
    BR.Sched.step(fakeTime)
    ok(BR.Roster.get(1) ~= nil, 'the player is still on the roster')
    ok(BR.Roster.get(1).state == BR.PlayerState.ALIVE,
        'a player with no ped is not assumed dead')

    noPed[1] = nil
    pedHealth[1001] = nil
end

describe('combat.endsMatch')
do
    reset()
    BR.Server.devMode = true
    join(1, 'A'); join(2, 'B')
    BR.Match.transition(BR.MatchState.PLAYING)
    BR.Roster.each(nil, function(src) BR.Roster.setState(src, BR.PlayerState.ALIVE) end)

    BR.Combat.eliminate(2, 'fall', 1)
    fakeTime = fakeTime + 4000   -- past WIN_GRACE_MS
    BR.Sched.step(fakeTime)

    ok(BR.Server.match.state == BR.MatchState.ENDED,
        'eliminating the last opponent ends the match')
    ok(BR.Roster.get(1).placement == 1, 'the survivor takes first')
    ok(BR.Roster.get(2).placement == 2, 'the loser keeps the placement they died at')
end

describe('match.startBlocker')
do
    -- The gate and the explanation shown to players are the same function.
    -- Written separately they drift, and the drift is nasty: the lobby
    -- confidently explains a condition that is not the one holding the match,
    -- so the player does what it asks and nothing happens.
    reset()
    BR.Server.devMode = true       -- minToStart 2, minSquads 1

    ok(BR.Match.startBlocker().reason == 'players',
        'an empty queue is blocked on players')

    queueUp(1, 'A', BR.Mode.SQUAD.key)
    local b = BR.Match.startBlocker()
    ok(b.reason == 'players' and b.have == 1 and b.need == 2,
        'and it reports how many are short')

    queueUp(2, 'B', BR.Mode.SQUAD.key)
    ok(BR.Match.startBlocker() == nil,
        'two solo queuers in dev mode are two squads, so nothing blocks')

    -- Put them in one party and the headcount is still met, but the TEAM count
    -- is not -- with production thresholds this is the case that matters.
    BR.Party.invite(1, 2); BR.Party.respond(2, true)
    BR.Server.devMode = false      -- minSquads 2, minToStart 16
    BR.Config.Match.minToStartProd = 2
    local sq = BR.Match.startBlocker()
    ok(sq and sq.reason == 'squads', 'one party of two is blocked on squads')
    ok(sq.have == 1 and sq.need == 2, 'and says how many teams it has')

    -- Solo rounds have no team requirement: everyone IS their own team, so the
    -- squad gate must never apply to them.
    --
    -- Reaching that branch takes a lobby smaller than the squad minimum, which
    -- only happens if the two are configured across each other. That is the
    -- point: without the exemption such a lobby waits for a second "squad" that
    -- can never arrive, because in solo the squad count and the player count
    -- are the same number it has already rejected.
    BR.Lobby.clear()
    BR.Config.Match.minToStartProd = 1
    fire(BR.Net.QUEUE_JOIN, 1, { mode = BR.Mode.SOLO.key })
    ok(BR.Match.startBlocker() == nil,
        'a solo round is never held for want of squads')

    BR.Config.Match.minToStartProd = 16
    BR.Server.devMode = true
end

describe('lobby.wait')
do
    -- The reason has to reach the client, not merely exist on the server.
    reset()
    BR.Server.devMode = true
    queueUp(1, 'A', BR.Mode.SQUAD.key)

    sent = {}
    fakeTime = fakeTime + 600
    BR.Sched.step(fakeTime)

    local status = eventsOf(BR.Net.LOBBY_STATUS)
    ok(#status > 0, 'the lobby broadcasts while WAITING')
    local d = status[#status].args[1]
    ok(d.wait ~= nil and d.wait.reason == 'players',
        'and it carries the reason the match has not started')
    ok(d.wait.need == 2, 'including the minimum needed to start')
end

describe('party.ofOne')
do
    -- REGRESSION, reported in play: after a match one player left the party and
    -- the other was left in a party of one. Their own interface said "not in a
    -- party" -- correctly, there was nobody else in it -- while the server
    -- still reported them as partied, which filtered them out of every invite
    -- list. No control anywhere fixed it.
    reset()
    join(1, 'A'); join(2, 'B'); join(3, 'C')
    BR.Party.invite(1, 2)
    BR.Party.respond(2, true)
    ok(BR.Party.isGrouped(1) and BR.Party.isGrouped(2), 'two players make a party')

    BR.Party.leave(2)
    ok(BR.Roster.get(2).partyId == nil, 'the leaver is out')
    ok(BR.Roster.get(1).partyId == nil,
        'and the last member left behind is out too -- a party of one is not a party')
    ok(not BR.Party.isGrouped(1), 'so they can be invited again')

    -- The same trap by a different route: inviting creates the inviter's party
    -- before the invite is answered, so a decline used to leave a party of one.
    BR.Party.invite(1, 3)
    BR.Party.respond(3, false)
    ok(not BR.Party.isGrouped(1),
        'a declined invite does not leave the inviter stranded in a party of one')

    -- And the wire agrees, which is what the invite list actually reads.
    sent = {}
    fakeTime = fakeTime + 600
    BR.Sched.step(fakeTime)
    local status = eventsOf(BR.Net.LOBBY_STATUS)
    local players = status[#status] and status[#status].args[1].players or {}
    local flagged = 0
    for _, p in ipairs(players) do
        if p.inParty then flagged = flagged + 1 end
    end
    ok(flagged == 0, 'nobody is advertised as partied when no party has two members')
end

local function noticesTo(target)
    local out = {}
    for _, s in ipairs(sent) do
        if s.event == BR.Net.NOTIFY and s.target == target then
            out[#out + 1] = s.args[1]
        end
    end
    return out
end

describe('party.pending')
do
    -- The sender's only feedback used to be a transient "Invite sent." --
    -- after it faded, ignored, declined and expired invites all looked like
    -- nothing had ever been sent. The pending list and the answer notices are
    -- asserted ON THE WIRE, because that is what the interface actually reads.
    reset()
    join(1, 'A'); join(2, 'B'); join(3, 'C')

    sent = {}
    BR.Party.invite(1, 2)
    local updates = eventsOf(BR.Net.SQUAD_UPDATE)
    ok(#updates > 0, 'the invite itself pushes a party update')
    local last = updates[#updates].args[1]
    ok(last.pending and #last.pending == 1 and last.pending[1].src == 2,
        'and it carries the invite as pending')
    ok(last.pending[1].name == 'B', 'with the invitee name, not just an id')

    -- Declined: the inviter HEARS the no, and the chip goes away.
    sent = {}
    BR.Party.respond(2, false)
    local notes = noticesTo(1)
    ok(#notes > 0 and tostring(notes[1].text):find('declined'),
        'declining notifies the inviter')
    updates = eventsOf(BR.Net.SQUAD_UPDATE)
    ok(#updates > 0 and #(updates[#updates].args[1].pending or {}) == 0,
        'and the pending list empties on the wire')

    -- Accepted: pending clears and both sides are told.
    BR.Party.invite(1, 2)
    sent = {}
    BR.Party.respond(2, true)
    updates = eventsOf(BR.Net.SQUAD_UPDATE)
    ok(#(updates[#updates].args[1].pending or {}) == 0,
        'accepting clears the pending list')
    ok(#noticesTo(2) > 0, 'the joiner is told they joined')
    ok(#noticesTo(1) > 0, 'and the inviter is told who arrived')

    -- Expired: ignoring an invite is an answer the sender needs too.
    BR.Party.invite(1, 3)
    sent = {}
    fakeTime = fakeTime + 61000
    BR.Sched.step(fakeTime)
    notes = noticesTo(1)
    local expired = false
    for _, n in ipairs(notes) do
        if tostring(n.text):find('expired') then expired = true end
    end
    ok(expired, 'an ignored invite expires with a notice to the sender')
    updates = eventsOf(BR.Net.SQUAD_UPDATE)
    ok(#updates > 0 and #(updates[#updates].args[1].pending or {}) == 0,
        'and the pending chip is withdrawn')
end

describe('lobby.soloDropsParty')
do
    -- Queueing solo while in a party is a contradiction; the resolution is
    -- what the player asked for most recently. No "in a party but playing
    -- alone" state exists, on purpose.
    reset()
    join(1, 'A'); join(2, 'B')
    BR.Party.invite(1, 2); BR.Party.respond(2, true)
    ok(BR.Party.isGrouped(1), 'party formed')

    fire(BR.Net.QUEUE_JOIN, 1, { mode = BR.Mode.SOLO.key })
    ok(not BR.Party.isGrouped(1), 'queueing solo leaves the party')
    ok(not BR.Party.isGrouped(2),
        'and the abandoned partner is released too (party of one rule)')
    ok(BR.Server.queue[1] ~= nil, 'the queue entry still lands')
end

describe('match.participants')
do
    -- The queue gates the start AND defines who is in. This used to sweep the
    -- whole roster, conscripting connected players who never readied up.
    reset()
    BR.Server.devMode = true
    join(1, 'A'); join(2, 'B'); join(3, 'Idler')
    fire(BR.Net.QUEUE_JOIN, 1, { mode = BR.Mode.SOLO.key })
    fire(BR.Net.QUEUE_JOIN, 2, { mode = BR.Mode.SOLO.key })

    fakeTime = fakeTime + 300
    BR.Sched.step(fakeTime)
    ok(BR.Server.match.state == BR.MatchState.WARMUP, 'the match starts')
    ok(BR.Roster.get(1).state == BR.PlayerState.WARMUP, 'queued players enter warmup')
    ok(BR.Roster.get(3).state == BR.PlayerState.LOBBY,
        'the idler who never readied up stays in the lobby')

    -- And the idler is not promoted when the match goes live either.
    BR.Match.transition(BR.MatchState.PLAYING)
    ok(BR.Roster.get(1).state == BR.PlayerState.ALIVE, 'participants go alive')
    ok(BR.Roster.get(3).state == BR.PlayerState.LOBBY, 'the idler still does not')
end

describe('match.leave')
do
    -- Leaving mid-match IS an elimination: placement recorded, the match plays
    -- on, and the leaver is back in the lobby able to queue for the next one.
    reset()
    BR.Server.devMode = true
    join(1, 'A'); join(2, 'B'); join(3, 'C')
    fire(BR.Net.QUEUE_JOIN, 1, { mode = BR.Mode.SOLO.key })
    fire(BR.Net.QUEUE_JOIN, 2, { mode = BR.Mode.SOLO.key })
    fire(BR.Net.QUEUE_JOIN, 3, { mode = BR.Mode.SOLO.key })
    fakeTime = fakeTime + 300
    BR.Sched.step(fakeTime)
    BR.Match.transition(BR.MatchState.PLAYING)

    sent = {}
    fire(BR.Net.MATCH_LEAVE, 2)
    local e = BR.Roster.get(2)
    ok(e.state == BR.PlayerState.LOBBY, 'the leaver is back in the lobby')
    ok(e.placement ~= nil, 'with a placement recorded, like any elimination')
    ok(#eventsOf(BR.Net.TO_LOBBY) == 1, 'and is sent home')
    ok(BR.Server.match.state == BR.MatchState.PLAYING,
        'while the match plays on for everyone else')
    ok(BR.Server.squadsAlive() == 2, 'the alive count dropped by exactly one')

    -- Back in the lobby DURING the match, they may queue for the next one.
    fire(BR.Net.QUEUE_JOIN, 2, { mode = BR.Mode.SOLO.key })
    ok(BR.Server.queue[2] ~= nil, 'a lobby player can queue while a match runs')

    -- A player still IN the match cannot double-queue their way out.
    fire(BR.Net.QUEUE_JOIN, 1, { mode = BR.Mode.SOLO.key })
    ok(BR.Server.queue[1] == nil, 'an in-match player cannot queue')

    -- Leaving during WARMUP records no placement -- the match never started
    -- for them, so there is nothing to place.
    reset()
    join(4, 'D'); join(5, 'E')
    fire(BR.Net.QUEUE_JOIN, 4, { mode = BR.Mode.SOLO.key })
    fire(BR.Net.QUEUE_JOIN, 5, { mode = BR.Mode.SOLO.key })
    fakeTime = fakeTime + 300
    BR.Sched.step(fakeTime)
    ok(BR.Server.match.state == BR.MatchState.WARMUP, 'warmup running')
    fire(BR.Net.MATCH_LEAVE, 5)
    ok(BR.Roster.get(5).state == BR.PlayerState.LOBBY, 'warmup leaver is out')
    ok(BR.Roster.get(5).placement == nil, 'with no placement recorded')
end

describe('party.squadpos')
do
    -- SECURITY-RELEVANT. br:squad:pos is the single deliberate exception to
    -- "positions never leave the server", and this pins its boundary: members
    -- of a squad receive their OWN squad's positions and never anyone
    -- else's. A leak here is a wallhack, the same class of bug the
    -- roster.privacy block guards against.
    reset()
    BR.Server.devMode = true
    -- Player 5 never queues: a lobby bystander, the one kind of player who
    -- must receive nothing. (A SOLO QUEUER in a squad round is autofilled
    -- onto a squad by design, so they are not the negative case here.)
    join(1, 'A'); join(2, 'B'); join(3, 'C'); join(4, 'D'); join(5, 'Idler')
    BR.Party.invite(1, 2); BR.Party.respond(2, true)
    BR.Party.invite(3, 4); BR.Party.respond(4, true)

    for i = 1, 4 do
        fire(BR.Net.QUEUE_JOIN, i, { mode = BR.Mode.SQUAD.key })
    end
    fakeTime = fakeTime + 300
    BR.Sched.step(fakeTime)
    ok(BR.Server.match.state == BR.MatchState.WARMUP, 'match reaches warmup')

    local sq1 = BR.Roster.get(1).squadId
    local sq3 = BR.Roster.get(3).squadId
    ok(sq1 and sq3 and sq1 ~= sq3, 'two distinct squads formed')

    -- Positions are sampled by roster.positions; then the beacon job runs.
    sent = {}
    fakeTime = fakeTime + 1100
    BR.Sched.step(fakeTime)

    local pushes = eventsOf(BR.Net.SQUAD_POS)
    ok(#pushes > 0, 'squad positions are pushed during warmup')

    local leak, wrongTarget, idlerGot = false, false, false
    for _, p in ipairs(pushes) do
        if p.target == 5 then idlerGot = true end
        local targetSquad = BR.Roster.get(p.target)
        targetSquad = targetSquad and targetSquad.squadId
        for _, m in ipairs(p.args[1]) do
            local e = BR.Roster.get(m.src)
            if not e or e.squadId ~= targetSquad then leak = true end
        end
        if not targetSquad then wrongTarget = true end
    end
    ok(not idlerGot, 'a lobby bystander receives no positions at all')
    ok(not leak, 'no payload ever contains a player from another squad')
    ok(not wrongTarget, 'every recipient is in a squad')

    -- A dead squadmate drops out of the push; a one-survivor squad gets none.
    BR.Match.transition(BR.MatchState.PLAYING)
    BR.Combat.eliminate(2, 'test', nil)
    sent = {}
    fakeTime = fakeTime + 1100
    BR.Sched.step(fakeTime)
    local after = eventsOf(BR.Net.SQUAD_POS)
    local deadSeen, lonely = false, false
    for _, p in ipairs(after) do
        if p.target == 1 then lonely = true end
        for _, m in ipairs(p.args[1]) do
            if m.src == 2 then deadSeen = true end
        end
    end
    ok(not deadSeen, 'the dead stop being broadcast')
    ok(not lonely, 'a squad of one survivor gets no pushes (nothing to show)')

    -- And a SOLO round shares nothing with anybody: no squads, no beacons.
    reset()
    join(1, 'A'); join(2, 'B')
    fire(BR.Net.QUEUE_JOIN, 1, { mode = BR.Mode.SOLO.key })
    fire(BR.Net.QUEUE_JOIN, 2, { mode = BR.Mode.SOLO.key })
    fakeTime = fakeTime + 300
    BR.Sched.step(fakeTime)
    ok(BR.Server.match.state == BR.MatchState.WARMUP, 'solo match reaches warmup')
    sent = {}
    fakeTime = fakeTime + 1100
    BR.Sched.step(fakeTime)
    ok(#eventsOf(BR.Net.SQUAD_POS) == 0,
        'solo rounds broadcast no positions to anyone')
end

describe('match.soloDev')
do
    -- minToStart = 1 exists so a lone dev client can walk the whole flow.
    -- The trap it sets: one squad satisfies "squadsAlive <= 1" the moment
    -- PLAYING begins, so without the started-with check the match ends three
    -- seconds in, every time, and PLAYING is untestable alone.
    ok(SHIPPED_MIN_TO_START == 1, 'the config ships a dev minimum of 1')

    reset()
    BR.Server.devMode = true
    BR.Config.Match.minToStart = 1   -- the shipped value, under test here
    join(1, 'OnlyDev')
    fire(BR.Net.QUEUE_JOIN, 1, { mode = BR.Mode.SOLO.key })

    fakeTime = fakeTime + 300
    BR.Sched.step(fakeTime)
    ok(BR.Server.match.state == BR.MatchState.WARMUP, 'one dev player starts a match')

    BR.Match.transition(BR.MatchState.PLAYING)
    fakeTime = fakeTime + 5000        -- well past WIN_GRACE_MS
    BR.Sched.step(fakeTime)
    ok(BR.Server.match.state == BR.MatchState.PLAYING,
        'a match that STARTED with one squad never auto-ends in dev')

    -- The guard must not weaken a real dev match: two squads, one dies,
    -- the match ends exactly as before.
    reset()
    BR.Server.devMode = true
    join(1, 'A'); join(2, 'B')
    fire(BR.Net.QUEUE_JOIN, 1, { mode = BR.Mode.SOLO.key })
    fire(BR.Net.QUEUE_JOIN, 2, { mode = BR.Mode.SOLO.key })
    fakeTime = fakeTime + 300
    BR.Sched.step(fakeTime)
    BR.Match.transition(BR.MatchState.PLAYING)
    BR.Combat.eliminate(2, 'test', 1)
    fakeTime = fakeTime + 5000
    BR.Sched.step(fakeTime)
    ok(BR.Server.match.state == BR.MatchState.ENDED,
        'a two-squad dev match still ends when one falls')
end

describe('match.lateJoin')
do
    -- The warmup door stays open: readying up during WARMUP joins the FORMING
    -- match; from BUS onward it queues for the next one. Without this, idler
    -- protection worked "too well" -- one early bird started the round and
    -- everyone else was locked out for its whole duration.
    reset()
    BR.Server.devMode = true
    BR.Config.Match.minToStart = 1

    join(1, 'Early'); join(2, 'Late')
    fire(BR.Net.QUEUE_JOIN, 1, { mode = BR.Mode.SOLO.key })
    fakeTime = fakeTime + 300
    BR.Sched.step(fakeTime)
    ok(BR.Server.match.state == BR.MatchState.WARMUP, 'the early bird starts warmup')
    ok(BR.Roster.get(2).state == BR.PlayerState.LOBBY, 'the other is still an idler')

    fire(BR.Net.QUEUE_JOIN, 2, { mode = BR.Mode.SOLO.key })
    ok(BR.Roster.get(2).state == BR.PlayerState.WARMUP,
        'readying up during warmup joins the forming match directly')
    ok(BR.Server.queue[2] == nil, 'and does not sit in the queue')

    -- Both now count as starting teams: the solo-dev hold does not engage and
    -- the match ends like any other.
    BR.Match.transition(BR.MatchState.PLAYING)
    BR.Combat.eliminate(2, 'test', 1)
    fakeTime = fakeTime + 5000
    BR.Sched.step(fakeTime)
    ok(BR.Server.match.state == BR.MatchState.ENDED,
        'a late joiner makes it a real match with a real winner')

    -- Squad placement: party squad first, then the emptiest squad with room.
    reset()
    BR.Server.devMode = true
    join(1, 'A'); join(2, 'B'); join(3, 'C'); join(4, 'D'); join(5, 'E'); join(6, 'F')
    BR.Party.invite(1, 2); BR.Party.respond(2, true)
    BR.Party.invite(1, 3); BR.Party.respond(3, true)   -- party of 3: 1,2,3
    BR.Party.invite(4, 5); BR.Party.respond(5, true)   -- party of 2: 4,5
    for i = 1, 5 do fire(BR.Net.QUEUE_JOIN, i, { mode = BR.Mode.SQUAD.key }) end
    fakeTime = fakeTime + 300
    BR.Sched.step(fakeTime)
    ok(BR.Server.match.state == BR.MatchState.WARMUP, 'squad match forms')

    -- Player 6, partied with nobody, readies late: the emptiest squad with
    -- room is the pair, not the trio.
    local pairSquad = BR.Roster.get(4).squadId
    fire(BR.Net.QUEUE_JOIN, 6, { mode = BR.Mode.SQUAD.key })
    ok(BR.Roster.get(6).state == BR.PlayerState.WARMUP, 'late joiner is in the match')
    ok(BR.Roster.get(6).squadId == pairSquad,
        'and fills the emptiest squad, not the fullest')
    ok(BR.Roster.get(6).colour == BR.Roster.get(4).colour,
        "wearing that squad's colour")

    -- A late PARTYMATE goes to their friends EVEN WHEN another squad is
    -- emptier -- autofill is off here precisely so the two rules disagree:
    -- the party squad has two members, the solo's squad has one, and only
    -- the party preference sends player 3 to the fuller one.
    reset()
    BR.Server.devMode = true
    BR.Config.Match.autofill = false
    join(1, 'A'); join(2, 'B'); join(3, 'C'); join(4, 'D')
    BR.Party.invite(1, 2); BR.Party.respond(2, true)
    BR.Party.invite(1, 3); BR.Party.respond(3, true)   -- trio 1,2,3
    for i = 1, 2 do fire(BR.Net.QUEUE_JOIN, i, { mode = BR.Mode.SQUAD.key }) end
    fire(BR.Net.QUEUE_JOIN, 4, { mode = BR.Mode.SQUAD.key })
    fakeTime = fakeTime + 300
    BR.Sched.step(fakeTime)
    ok(BR.Server.match.state == BR.MatchState.WARMUP, 'match forms without player 3')
    ok(BR.Roster.get(4).squadId ~= BR.Roster.get(1).squadId,
        'the solo has a squad of one -- the emptier target')

    fire(BR.Net.QUEUE_JOIN, 3, { mode = BR.Mode.SQUAD.key })
    ok(BR.Roster.get(3).squadId == BR.Roster.get(1).squadId,
        "a late partymate lands on their party's squad, not the emptier one",
        ('got %s, wanted %s'):format(tostring(BR.Roster.get(3).squadId),
                                     tostring(BR.Roster.get(1).squadId)))
    BR.Config.Match.autofill = true

    -- From BUS onward the door is shut: late arrivals queue for the NEXT match.
    BR.Match.transition(BR.MatchState.BUS)
    join(9, 'TooLate')
    fire(BR.Net.QUEUE_JOIN, 9, { mode = BR.Mode.SOLO.key })
    ok(BR.Roster.get(9).state == BR.PlayerState.LOBBY, 'a bus-stage arrival stays in the lobby')
    ok(BR.Server.queue[9] ~= nil, 'queued for the next match instead')
end

describe('match.bus')
do
    -- The bus is a shared illusion: the server publishes ONE route record and
    -- owns who may jump, when, and where they exit. These pin the authority
    -- half; the rendering half is native-driven and tested in-game.
    reset()
    BR.Server.devMode = true
    join(1, 'A'); join(2, 'B')
    fire(BR.Net.QUEUE_JOIN, 1, { mode = BR.Mode.SOLO.key })
    fire(BR.Net.QUEUE_JOIN, 2, { mode = BR.Mode.SOLO.key })
    fakeTime = fakeTime + 300
    BR.Sched.step(fakeTime)
    ok(BR.Server.match.state == BR.MatchState.WARMUP, 'warmup starts')

    sent = {}
    fakeTime = BR.Server.match.endsAt + 1
    BR.Sched.step(fakeTime)
    ok(BR.Server.match.state == BR.MatchState.BUS, 'warmup expires into the bus')

    local r = BR.Bus.active()
    ok(r ~= nil, 'a route exists')
    ok(#eventsOf(BR.Net.BUS_ROUTE) == 1, 'and was broadcast exactly once')
    ok(BR.Roster.get(1).state == BR.PlayerState.BUS, 'players are aboard')

    -- Geometry: departs the airstrip, legs in order, chord ends on the
    -- anchor circle, enters at the end nearer the airstrip.
    local rw = BR.Config.Bus.runwayStart
    ok(r.sx == rw.x and r.sy == rw.y, 'the route departs the runway threshold')
    ok(r.sz == rw.z, 'on the ground -- the climb profile owes its start to this')
    ok(r.tStart < r.tMid and r.tMid < r.tEnd, 'legs are ordered in time')
    ok((r.landScore or 0) > 0, 'the chosen chord overflies at least some land')

    -- The scorer itself, pinned at its extremes: open sea south of the map
    -- scores zero, a chord through the city scores near-full. (The best-of-N
    -- selection is exercised statistically below -- a single "> 0" proved
    -- vacuous in audit, since almost any chord near a land anchor grazes
    -- some POI.)
    ok(BR.Bus.landScore(0.0, -8000.0, 4000.0, -9000.0) == 0,
        'open ocean scores zero')
    ok(BR.Bus.landScore(-1000.0, -1500.0, 1000.0, -500.0) > 0.8,
        'a chord across the city scores near-full')

    local a = BR.Server.matchAnchor
    ok(a ~= nil, 'the match anchor is remembered for the storm')
    ok(math.abs(BR.Dist(a.x, a.y, r.mx, r.my) - BR.Config.Bus.chordRadius) < 1.0,
        'the chord entry sits on the anchor circle')
    ok(BR.Dist2(rw.x, rw.y, r.mx, r.my) <= BR.Dist2(rw.x, rw.y, r.ex, r.ey),
        'the bus enters at the end nearer the airstrip')
    ok(BR.Server.match.endsAt >= r.tEnd, 'BUS lasts at least the whole route')

    -- Jumping over the ocean is refused; over the chord it is an elimination
    -- of altitude, not of the player.
    sent = {}
    fire(BR.Net.BUS_JUMP, 1)
    ok(BR.Roster.get(1).state == BR.PlayerState.BUS, 'jumping before the chord is refused')
    ok(#eventsOf(BR.Net.BUS_JUMP_OK) == 0, 'no exit coordinates are sent')

    fakeTime = r.tMid + 1000
    fire(BR.Net.BUS_JUMP, 1)
    ok(BR.Roster.get(1).state == BR.PlayerState.FREEFALL, 'jumping over the chord works')
    local oks = eventsOf(BR.Net.BUS_JUMP_OK)
    ok(#oks == 1 and oks[1].target == 1, 'exit coordinates go to the jumper alone')
    local jx, jy = oks[1].args[1].x, oks[1].args[1].y
    local px, py = BR.RoutePosAt(r, fakeTime)
    ok(math.abs(jx - px) < 0.1 and math.abs(jy - py) < 0.1,
        'and they are the bus position by the SERVER clock')

    -- Nobody rides the bus home.
    sent = {}
    fakeTime = r.tEnd + 600
    BR.Sched.step(fakeTime)
    ok(BR.Roster.get(2).state == BR.PlayerState.FREEFALL,
        'stragglers are force-ejected at the end of the line')
    oks = eventsOf(BR.Net.BUS_JUMP_OK)
    ok(#oks == 1 and oks[1].args[1].forced == true, 'and told it was not their idea')

    -- Landing is what makes a player ALIVE -- not the PLAYING transition.
    fakeTime = BR.Server.match.endsAt + 1
    BR.Sched.step(fakeTime)
    ok(BR.Server.match.state == BR.MatchState.PLAYING, 'the route expires into PLAYING')
    ok(BR.Roster.get(1).state == BR.PlayerState.FREEFALL,
        'a mid-air player is NOT snapped to alive by the transition')

    fire(BR.Net.DROP_LANDED, 1)
    ok(BR.Roster.get(1).state == BR.PlayerState.ALIVE, 'touchdown makes them alive')

    fire(BR.Net.DROP_LANDED, 1)
    ok(BR.Roster.get(1).state == BR.PlayerState.ALIVE, 'a duplicate report is a no-op')

    join(9, 'Idler')
    fire(BR.Net.DROP_LANDED, 9)
    ok(BR.Roster.get(9).state == BR.PlayerState.LOBBY,
        'a bystander claiming to land changes nothing')

    -- Freefallers count as living teams: the match must not end while one
    -- fighter is on the ground and the other is still falling.
    ok(BR.Server.squadsAlive() == 2, 'a freefaller is a living team')

    -- Across many seeds, the CHOSEN chord never dips below a floor a purely
    -- random pick regularly violates around the coastal anchors. Runs last:
    -- each plan() replaces the live route.
    local worst = 1.0
    for seed = 1, 25 do
        fakeTime = fakeTime + 7919 * seed
        BR.Bus.plan()
        local rr = BR.Bus.active()
        if rr.landScore < worst then worst = rr.landScore end
    end
    ok(worst >= 0.3, 'best-of-N keeps every match over meaningful land',
        ('worst chosen score across seeds: %.2f'):format(worst))
    BR.Bus.clear()
end

describe('roster.buckets')
do
    -- The lobby is a MENU with a view: each lobby player sits alone in a
    -- personal routing bucket so no ped ever stands in another player's
    -- vista shot. Match states share bucket 0. The bucket rides the state
    -- through the setState choke point, and join must apply it too --
    -- add() writes the initial state directly.
    reset()
    BR.Server.devMode = true
    join(1, 'A'); join(2, 'B')
    ok(buckets[1] == 1001 and buckets[2] == 1002,
        'joining lands each player in their own private lobby bucket')

    fire(BR.Net.QUEUE_JOIN, 1, { mode = BR.Mode.SOLO.key })
    fire(BR.Net.QUEUE_JOIN, 2, { mode = BR.Mode.SOLO.key })
    fakeTime = fakeTime + 300
    BR.Sched.step(fakeTime)
    ok(BR.Server.match.state == BR.MatchState.WARMUP, 'match starts')
    ok(buckets[1] == 0 and buckets[2] == 0,
        'entering the match moves everyone into the shared bucket')

    fire(BR.Net.MATCH_LEAVE, 2)
    ok(buckets[2] == 1002, 'leaving the match returns them to their private bucket')
    ok(buckets[1] == 0, 'without disturbing anyone still playing')
end

describe('party.resultFailuresOnly')
do
    -- The "You joined the party." / "Joined the party." double: every success
    -- already speaks through the notify channel or a visible state change, so
    -- SQUAD_RESULT firing on success too put two voices on one event.
    reset()
    join(1, 'A'); join(2, 'B')

    sent = {}
    BR.Party.invite(1, 2)
    fire(BR.Net.SQUAD_RESPOND, 2, { accept = true })
    ok(#eventsOf(BR.Net.SQUAD_RESULT) == 0,
        'a successful accept sends no SQUAD_RESULT (notify already spoke)')
    ok(#noticesTo(2) > 0, 'and the joiner still hears about it')

    sent = {}
    fire(BR.Net.SQUAD_INVITE, 1, { target = 1 })   -- inviting yourself fails
    local results = eventsOf(BR.Net.SQUAD_RESULT)
    ok(#results == 1 and results[1].args[1].ok == false,
        'a failure still sends its reason')
end

realPrint(('\n\27[32m%d passed\27[0m'):format(pass))
if fail > 0 then
    realPrint(('\27[31m%d failed\27[0m'):format(fail))
    os.exit(1)
end
