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
    'br_core/server/match.lua',
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

local function reset()
    for k in pairs(BR.Server.roster) do BR.Server.roster[k] = nil end
    for k in pairs(connected) do connected[k] = nil end
    sent = {}
    BR.Server.match.state = BR.MatchState.WAITING
    BR.Server.match.endsAt = 0
end

local function join(src, name)
    connected[src] = true
    playerNames[src] = name
    fire('playerJoining', src)
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

    pedHealth[1001] = 150            -- engine units: halfway between floor and max
    fakeTime = fakeTime + 1000
    BR.Sched.step(fakeTime)

    ok(BR.Roster.get(1).hp == 50,
        'sampled engine health becomes display health',
        ('got %s'):format(tostring(BR.Roster.get(1).hp)))
    ok(BR.Roster.get(1).engineHp == 150, 'and the raw engine value is kept too')

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

    join(1, 'Alice')
    fakeTime = fakeTime + 1000
    BR.Sched.step(fakeTime)
    ok(BR.Server.match.state == BR.MatchState.WAITING,
        'one player is not enough to start')

    join(2, 'Bob')
    fakeTime = fakeTime + 1000
    BR.Sched.step(fakeTime)
    ok(BR.Server.match.state == BR.MatchState.WARMUP,
        'reaching the minimum starts warmup')
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
    ok(BR.Roster.get(1).state == BR.PlayerState.ALIVE, 'players are alive in play')
end

describe('match.winCondition')
do
    -- Two solo players: eliminating one should end the match, because solos each
    -- count as their own team.
    ok(BR.Server.match.state == BR.MatchState.PLAYING, 'starting from PLAYING')
    ok(BR.Server.squadsAlive() == 2, 'two solos are two teams')

    BR.Roster.setState(2, BR.PlayerState.DEAD)
    fakeTime = fakeTime + 500
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
    fakeTime = fakeTime + 500
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

    fire('playerDropped', 2, 'timeout')
    fakeTime = fakeTime + 500
    BR.Sched.step(fakeTime)

    ok(BR.Server.match.state == BR.MatchState.ENDED,
        'a disconnect can end the match like an elimination')
    ok(BR.Roster.get(2) == nil, 'and the leaver is gone from the roster')
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
    fakeTime = fakeTime + 500
    BR.Sched.step(fakeTime)

    ok(BR.Server.match.state == BR.MatchState.ENDED,
        'eliminating the last opponent ends the match')
    ok(BR.Roster.get(1).placement == 1, 'the survivor takes first')
    ok(BR.Roster.get(2).placement == 2, 'the loser keeps the placement they died at')
end

realPrint(('\n\27[32m%d passed\27[0m'):format(pass))
if fail > 0 then
    realPrint(('\27[31m%d failed\27[0m'):format(fail))
    os.exit(1)
end
