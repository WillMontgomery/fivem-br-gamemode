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
-- Per-ped coordinates, settable by storm/position tests. Everyone else stands
-- at the origin, which is what the older blocks were written against.
local pedCoords = {}
function GetEntityCoords(ped)
    return pedCoords[ped] or { x = 0.0, y = 0.0, z = 0.0 }
end
-- weaponDamageEvent plumbing, so the handler itself can be driven rather than
-- only the pure validator underneath it. Network ids ARE the ped handles here,
-- which is enough fidelity: the server only ever uses a netId to get back to a
-- player, and GetPlayerPed already returns 1000 + src.
function NetworkGetEntityFromNetworkId(id) return id end
function NetworkGetNetworkIdFromEntity(ped) return ped end
function CancelEvent() end

--- Place a player's PED (positions flow ped -> sampler -> roster, never the
--- other way, so tests must set them the same way the game would).
local function setPos(src, x, y, z)
    pedCoords[1000 + src] = { x = x, y = y, z = z or 30.0 }
end

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
    'br_lib/shared/loot_gen.lua',
    'br_lib/shared/combat_solve.lua',
    'br_core/server/main.lua',
    'br_core/server/broadcast.lua',
    'br_core/server/roster.lua',
    'br_core/server/lobby.lua',
    'br_core/server/party.lua',
    'br_core/server/match.lua',
    'br_core/server/bus.lua',
    'br_core/server/combat.lua',
    'br_core/server/storm.lua',
    'br_core/server/inventory.lua',
    'br_core/server/loot.lua',
    'br_core/server/markers.lua',
    'br_core/server/voice.lua',
    'br_core/server/damage.lua',
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
    -- The match registry replaces the old global match: dropping every
    -- instance is the whole between-blocks cleanup (storm, anchor, descent
    -- and start-squad bookkeeping all live ON the instances now).
    for k in pairs(BR.Server.matches) do BR.Server.matches[k] = nil end
    BR.Server.partyHoldSince = nil
    for k in pairs(pedCoords) do pedCoords[k] = nil end
end

-- ------------------------------------------------ parallel-match helpers ---
-- The state machine is per-instance (parallel matches, 2026-08-04). These
-- read and drive "the newest match" -- which is simply THE match everywhere
-- a block runs one at a time, and lets the multi-match blocks talk about
-- several by holding the returned instances directly.
local function theMatch() return BR.Server.latestMatch() end
local function mstate()
    local m = theMatch()
    return m and m.state or BR.MatchState.WAITING
end
local function mendsAt() local m = theMatch(); return m and m.endsAt or 0 end
local function mstorm()  local m = theMatch(); return m and m.storm or nil end
local function manchor() local m = theMatch(); return m and m.anchor or nil end

--- brforce semantics: drive the newest instance (creating one from every
--- connected player if none exists) into a state. WAITING dissolves it.
local function forceState(state)
    if state == BR.MatchState.WAITING then
        local m = theMatch()
        if m then BR.Match.destroy(m) end
        return
    end
    local m = theMatch()
    if not m then
        local mode = BR.Lobby.count() > 0 and BR.Lobby.dominantMode()
            or BR.Mode.SOLO.key
        local parts = {}
        for src in pairs(BR.Server.roster) do parts[#parts + 1] = src end
        table.sort(parts)
        BR.Lobby.clear()
        m = BR.Match.create(mode, parts)
    end
    BR.Match.transition(m, state)
end

--- A bare instance for blocks that exercise one subsystem (squad formation,
--- a scoped broadcast) without running the machine; attaches every
--- rostered player, which mirrors the old whole-roster semantics.
local function fakeMatch(mode)
    BR.Server.matchId = BR.Server.matchId + 1
    local m = { id = BR.Server.matchId, mode = mode or BR.Mode.SOLO.key,
                state = BR.MatchState.WARMUP, endsAt = 0,
                bucket = BR.Config.Match.matchBucketBase + BR.Server.matchId }
    BR.Server.matches[m.id] = m
    for src in pairs(BR.Server.roster) do BR.Roster.setMatch(src, m.id) end
    return m
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
    BR.Broadcast.state(fakeMatch(BR.Mode.SOLO.key), BR.MatchState.PLAYING, 12345)

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
    ok(mstate() == BR.MatchState.WAITING,
        'connected players alone do not start a match')

    fire(BR.Net.QUEUE_JOIN, 1, { mode = 'solo' })
    fakeTime = fakeTime + 1000
    BR.Sched.step(fakeTime)
    ok(mstate() == BR.MatchState.WAITING,
        'one queued player is not enough to start')

    fire(BR.Net.QUEUE_JOIN, 2, { mode = 'solo' })
    fakeTime = fakeTime + 1000
    BR.Sched.step(fakeTime)
    ok(mstate() == BR.MatchState.WARMUP,
        'reaching the minimum QUEUED count starts warmup')
    ok(BR.Lobby.count() == 0, 'and the queue is cleared once the match begins')
    ok(BR.Roster.get(1).state == BR.PlayerState.WARMUP,
        'players move to warmup with the match')
    ok(mendsAt() > fakeTime, 'warmup has a deadline')

    -- Countdowns are derived from endsAt, never ticked over the network.
    fakeTime = mendsAt() + 1
    BR.Sched.step(fakeTime)
    ok(mstate() == BR.MatchState.BUS, 'warmup expires into the bus')
    ok(BR.Roster.get(1).state == BR.PlayerState.BUS, 'players board the bus')

    fakeTime = mendsAt() + 1
    BR.Sched.step(fakeTime)
    ok(mstate() == BR.MatchState.PLAYING, 'the bus route ends in play')
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
    ok(mstate() == BR.MatchState.PLAYING, 'starting from PLAYING')
    ok(BR.Server.squadsAlive() == 2, 'two solos are two teams')

    BR.Roster.setState(2, BR.PlayerState.DEAD)
    fakeTime = fakeTime + 4000   -- past WIN_GRACE_MS
    BR.Sched.step(fakeTime)

    ok(mstate() == BR.MatchState.ENDED, 'one team left ends the match')
    ok(BR.Roster.get(1).placement == 1, 'the survivor is placed first')

    fakeTime = mendsAt() + 1
    BR.Sched.step(fakeTime)
    ok(mstate() == BR.MatchState.CLEANUP, 'ended expires into cleanup')
    ok(BR.Roster.get(1).placement == nil, 'cleanup clears per-match state')
    ok(BR.Roster.get(1).state == BR.PlayerState.LOBBY, 'and returns players to the lobby')
end

describe('match.squads')
do
    reset()
    BR.Server.devMode = true
    join(1, 'A'); join(2, 'B'); join(3, 'C'); join(4, 'D')

    forceState(BR.MatchState.PLAYING)
    BR.Roster.each(nil, function(src) BR.Roster.setState(src, BR.PlayerState.ALIVE) end)
    -- Squads are hand-assigned AFTER the machine runs: formation (solo mode
    -- here) clears squad identity on the way in.
    BR.Roster.update(1, { squadId = 'sq1' })
    BR.Roster.update(2, { squadId = 'sq1' })
    BR.Roster.update(3, { squadId = 'sq2' })
    BR.Roster.update(4, { squadId = 'sq2' })

    ok(BR.Server.squadsAlive() == 2, 'four players in two squads are two teams')

    BR.Roster.setState(1, BR.PlayerState.DEAD)
    ok(BR.Server.squadsAlive() == 2, 'a squad with a survivor is still up')

    -- A downed player is not out: their squad is still contesting the match.
    BR.Roster.setState(2, BR.PlayerState.DBNO)
    ok(BR.Server.squadsAlive() == 2, 'a downed player still counts for their squad')

    BR.Roster.setState(2, BR.PlayerState.DEAD)
    fakeTime = fakeTime + 4000   -- past WIN_GRACE_MS
    BR.Sched.step(fakeTime)
    ok(mstate() == BR.MatchState.ENDED, 'wiping a squad ends the match')

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
    forceState(BR.MatchState.PLAYING)
    BR.Roster.each(nil, function(src) BR.Roster.setState(src, BR.PlayerState.ALIVE) end)
    ok(BR.Server.squadsAlive() == 2, 'two players in play')

    leave(2)
    fakeTime = fakeTime + 4000   -- past WIN_GRACE_MS
    BR.Sched.step(fakeTime)

    ok(mstate() == BR.MatchState.ENDED,
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

    -- Only player 1 is IN the match; 2 stays a lobby bystander.
    BR.Match.create(BR.Mode.SOLO.key, { 1 })
    forceState(BR.MatchState.PLAYING)
    BR.Roster.setState(1, BR.PlayerState.ALIVE)

    fire(BR.Net.QUEUE_JOIN, 1, { mode = 'solo' })
    ok(BR.Lobby.count() == 0, 'an in-match player cannot queue')

    fire(BR.Net.QUEUE_JOIN, 2, { mode = 'solo' })
    ok(BR.Lobby.count() == 1,
        'a lobby player queues for the NEXT match while this one runs')
    ok(mstate() == BR.MatchState.PLAYING,
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

describe('party.invite.withdrawnOnReady')
do
    -- READYING UP ANSWERS YOUR OWN INVITES. Before this, an invite sent and
    -- then abandoned by readying up stayed live for its full 60s TTL, so the
    -- recipient could accept into a party whose leader was already in warmup
    -- (user, 2026-08-08).
    --
    -- Asserted on the WIRE as well as on the outcome: the recipient's CARD has
    -- to be taken off their screen, and a server-side-only check would pass
    -- happily while the prompt sat there waiting to be clicked.
    reset()
    BR.Server.devMode = true
    join(1, 'Alice'); join(2, 'Bob'); join(3, 'Cara')

    BR.Party.invite(1, 2)
    BR.Party.invite(1, 3)
    ok(#eventsOf(BR.Net.SQUAD_INVITED) == 2, 'two invites went out')

    BR.Lobby.join(1, BR.Mode.SQUAD.key)

    -- The withdrawal rides the same channel the invite arrived on, carrying
    -- `cancel`, so the client has one handler rather than two.
    local cancels = 0
    for _, e in ipairs(eventsOf(BR.Net.SQUAD_INVITED)) do
        if e.args[1] and e.args[1].cancel then cancels = cancels + 1 end
    end
    ok(cancels == 2, 'readying up withdraws both cards')

    ok(not BR.Party.respond(2, true), 'and the invite can no longer be accepted')
    ok(BR.Party.of(2) == nil, 'so the accepter does not end up in an absent party')

    -- The recipient is TOLD. A card vanishing on its own is otherwise
    -- indistinguishable from a bug.
    local told = false
    for _, e in ipairs(eventsOf(BR.Net.NOTIFY)) do
        if e.target == 3 and e.args[1] and e.args[1].text:find('readied up') then
            told = true
        end
    end
    ok(told, 'and hears why it went away')
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

    forceState(BR.MatchState.PLAYING)
    BR.Roster.each(nil, function(src) BR.Roster.setState(src, BR.PlayerState.ALIVE) end)
    forceState(BR.MatchState.ENDED)
    forceState(BR.MatchState.CLEANUP)

    ok(BR.Party.of(1) ~= nil, 'the party survives a completed match')
    ok(BR.Party.of(1).id == pid, 'and it is the same party')
    ok(BR.Roster.get(1).squadId == nil, 'while the in-match squad is cleared')

    -- Disconnecting does leave the party -- a ghost member would hold a
    -- slot. And a pair losing one member DISBANDS (the party-of-one rule,
    -- now applied on the disconnect path too): the survivor must not be
    -- left half-partied, invisible in every invite list.
    leave(2)
    ok(BR.Party.size(pid) == 0, 'a pair losing a member to disconnect disbands')
    ok(BR.Roster.get(1).partyId == nil, 'and the survivor is fully released')
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

    BR.Party.formSquads(fakeMatch(BR.Mode.SQUAD.key))

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
    BR.Party.formSquads(fakeMatch(BR.Mode.SOLO.key))
    local anySquad = false
    BR.Roster.each(nil, function(_, e) if e.squadId then anySquad = true end end)
    ok(not anySquad, 'solo mode assigns no squads')

    -- Without autofill, solos stand alone rather than being merged.
    BR.Config.Match.autofill = false
    BR.Roster.each(nil, function(src) BR.Roster.setState(src, BR.PlayerState.WARMUP) end)
    BR.Party.formSquads(fakeMatch(BR.Mode.SQUAD.key))
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
        BR.Party.formSquads(fakeMatch(BR.Mode.SQUAD.key))

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
        BR.Party.formSquads(fakeMatch(mode))

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
    ok(mstate() == BR.MatchState.WAITING,
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
    ok(mstate() == BR.MatchState.WARMUP, 'and now it starts')

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
    BR.Party.formSquads(fakeMatch(BR.Mode.SQUAD.key))

    local sq = BR.Roster.get(1).squadId
    ok(sq ~= nil and BR.Roster.get(2).squadId == sq, 'both start on one squad')

    BR.Broadcast.flushNow()
    sent = {}

    -- The next match is solo.
    BR.Roster.each(nil, function(src) BR.Roster.setState(src, BR.PlayerState.WARMUP) end)
    BR.Party.formSquads(fakeMatch(BR.Mode.SOLO.key))
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
    forceState(BR.MatchState.PLAYING)
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
    forceState(BR.MatchState.WAITING)
    BR.Roster.setState(1, BR.PlayerState.LOBBY)
    BR.Combat.eliminate(1, 'fall', nil)
    ok(BR.Roster.get(1).state == BR.PlayerState.LOBBY, 'a player in the lobby cannot be eliminated')
end

describe('combat.credit')
do
    reset()
    BR.Server.devMode = true
    join(1, 'Killer'); join(2, 'Victim'); join(3, 'Bystander')
    forceState(BR.MatchState.PLAYING)
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
    forceState(BR.MatchState.PLAYING)
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
    forceState(BR.MatchState.PLAYING)
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
    forceState(BR.MatchState.PLAYING)
    BR.Roster.each(nil, function(src) BR.Roster.setState(src, BR.PlayerState.ALIVE) end)

    BR.Combat.eliminate(2, 'fall', 1)
    fakeTime = fakeTime + 4000   -- past WIN_GRACE_MS
    BR.Sched.step(fakeTime)

    ok(mstate() == BR.MatchState.ENDED,
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
    ok(mstate() == BR.MatchState.WARMUP, 'the match starts')
    ok(BR.Roster.get(1).state == BR.PlayerState.WARMUP, 'queued players enter warmup')
    ok(BR.Roster.get(3).state == BR.PlayerState.LOBBY,
        'the idler who never readied up stays in the lobby')

    -- And the idler is not promoted when the match goes live either.
    forceState(BR.MatchState.PLAYING)
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
    forceState(BR.MatchState.PLAYING)

    sent = {}
    fire(BR.Net.MATCH_LEAVE, 2)
    local e = BR.Roster.get(2)
    ok(e.state == BR.PlayerState.LOBBY, 'the leaver is back in the lobby')
    ok(e.placement ~= nil, 'with a placement recorded, like any elimination')
    ok(#eventsOf(BR.Net.TO_LOBBY) == 1, 'and is sent home')
    ok(mstate() == BR.MatchState.PLAYING,
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
    ok(mstate() == BR.MatchState.WARMUP, 'warmup running')
    fire(BR.Net.MATCH_LEAVE, 5)
    ok(BR.Roster.get(5).state == BR.PlayerState.LOBBY, 'warmup leaver is out')
    ok(BR.Roster.get(5).placement == nil, 'with no placement recorded')
end

describe('bus.landingNotice')
do
    -- A player who lands first stands in an empty field with no storm, no
    -- timer and no enemies, and nothing on screen says why (user, 2026-08-05:
    -- "give them a notification that the match will start once all players
    -- have landed"). Said once, to the lander, and only while it is true.
    reset()
    queueUp(1, 'A', BR.Mode.SOLO.key)
    queueUp(2, 'B', BR.Mode.SOLO.key)
    fakeTime = fakeTime + 300
    BR.Sched.step(fakeTime)
    forceState(BR.MatchState.BUS)
    BR.Roster.setState(1, BR.PlayerState.FREEFALL)
    BR.Roster.setState(2, BR.PlayerState.FREEFALL)

    local function noticesTo(target)
        local out = {}
        for _, s in ipairs(eventsOf(BR.Net.NOTIFY)) do
            if s.target == target then out[#out + 1] = s.args[1] end
        end
        return out
    end

    -- POLLED, NOT HOOKED TO THE LANDING REPORT. The notice comes off the match
    -- tick now: hanging it on DROP_LANDED meant it only fired if that event
    -- arrived, and that event has a documented history of going missing (the
    -- stuck-lander promotion exists because of it).
    sent = {}
    fire(BR.Net.DROP_LANDED, 1)
    fakeTime = fakeTime + 300
    BR.Sched.step(fakeTime)

    -- Matched on the KEY, not on the wording. The notice is addressable now
    -- (it has to be, or it could never be withdrawn), and a test that pins
    -- the English is a test that fails every time the copy is edited while
    -- proving nothing about the behaviour.
    local told, sticky = false, false
    for _, n in ipairs(noticesTo(1)) do
        if n.key == 'bus.landing' and not n.clear then
            told = true
            sticky = n.sticky == true
        end
    end
    ok(told, 'the first player down is told the match is waiting on the others')
    ok(sticky, 'and it is STICKY -- a four-second toast is gone before it matters')

    -- ONCE. The tick runs four times a second; a notice per tick would be a
    -- wall of toasts for the whole descent.
    sent = {}
    fakeTime = fakeTime + 1000
    BR.Sched.step(fakeTime)
    local repeated = 0
    for _, n in ipairs(noticesTo(1)) do
        if n.key == 'bus.landing' and not n.clear then repeated = repeated + 1 end
    end
    ok(repeated == 0, 'and only once, however many ticks pass',
        ('%d repeats'):format(repeated))

    -- The LAST player down must not be told to wait for himself.
    sent = {}
    fire(BR.Net.DROP_LANDED, 2)
    fakeTime = fakeTime + 300
    BR.Sched.step(fakeTime)
    local toldAgain = false
    for _, n in ipairs(noticesTo(2)) do
        if n.key == 'bus.landing' and not n.clear then toldAgain = true end
    end
    ok(not toldAgain, 'the last player down is told nothing -- nobody is left')

    -- THE ALL-CLEAR, which is the half this never had. A sticky notice with
    -- nobody to withdraw it is a line parked on the player's screen for the
    -- rest of the match, so the withdrawal is the load-bearing part of making
    -- it sticky at all.
    local cleared = false
    for _, n in ipairs(noticesTo(1)) do
        if n.key == 'bus.landing' and n.clear then cleared = true end
    end
    ok(cleared, 'and the first player down is told the wait is over')

    -- And a match already live says nothing either: a late lander (the
    -- stuck-lander promotion, a glider still coming down after PLAYING)
    -- would otherwise be told to wait for a match that already started.
    reset()
    queueUp(1, 'A', BR.Mode.SOLO.key)
    queueUp(2, 'B', BR.Mode.SOLO.key)
    fakeTime = fakeTime + 300
    BR.Sched.step(fakeTime)
    forceState(BR.MatchState.PLAYING)
    BR.Roster.setState(1, BR.PlayerState.FREEFALL)
    BR.Roster.setState(2, BR.PlayerState.FREEFALL)
    sent = {}
    fire(BR.Net.DROP_LANDED, 1)
    fakeTime = fakeTime + 300
    BR.Sched.step(fakeTime)
    local liveTold = false
    for _, n in ipairs(noticesTo(1)) do
        if n.text and n.text:find('landed') then liveTold = true end
    end
    ok(not liveTold, 'a live match never announces a wait')

    -- A SECOND FLIGHT RE-ARMS IT. The latch lives on the roster entry and is
    -- cleared at BUS entry; without that, a player told once would never be
    -- told again for the rest of the session.
    reset()
    queueUp(1, 'A', BR.Mode.SOLO.key)
    queueUp(2, 'B', BR.Mode.SOLO.key)
    fakeTime = fakeTime + 300
    BR.Sched.step(fakeTime)
    BR.Roster.get(1).landNotice = true      -- as if a previous flight told them
    forceState(BR.MatchState.BUS)
    ok(BR.Roster.get(1).landNotice == nil, 'the latch is cleared at wheels-up')
end

describe('party.balance')
do
    -- THE BUG THIS EXISTS FOR: two players queueing for squads landed in ONE
    -- squad, and a match with a single team standing can never satisfy the win
    -- condition -- in production the round would simply never start (user,
    -- 2026-08-05). The floor is minSquads, not "whatever capacity demands".
    local function sizesOf(m)
        local sizes = {}
        BR.Roster.each(
            function(e) return e.matchId == m.id and e.squadId end,
            function(_, e) sizes[e.squadId] = (sizes[e.squadId] or 0) + 1 end)
        local out = {}
        for _, n in pairs(sizes) do out[#out + 1] = n end
        table.sort(out)
        return out
    end

    reset()
    -- devMode stays ON (the harness needs its low start gate); the SQUAD
    -- floor is what this block is about, so pin the dev floor to the
    -- production value of two rather than fighting minToStart.
    local devFloor = BR.Config.Match.minSquadsDev
    BR.Config.Match.minSquadsDev = 2
    queueUp(1, 'A', BR.Mode.SQUAD.key)
    queueUp(2, 'B', BR.Mode.SQUAD.key)
    fakeTime = fakeTime + 300
    BR.Sched.step(fakeTime)

    local m = theMatch()
    ok(m ~= nil, 'a squad match forms')
    local s = sizesOf(m)
    ok(#s == 2 and s[1] == 1 and s[2] == 1,
        'two unpartied players become TWO squads of one, not one squad of two',
        table.concat(s, '/'))
    ok(BR.Server.squadsAlive(m) == 2,
        'so the win condition has something to resolve')

    -- The maths, directly.
    ok(BR.Party.squadTarget(2) == 2, 'target: 2 players -> 2 squads')
    ok(BR.Party.squadTarget(8) == 2, 'target: 8 players -> 2 squads of four')
    ok(BR.Party.squadTarget(9) == 3, 'target: 9 players -> 3 squads')
    ok(BR.Party.squadTarget(1) == 1, 'target: a lone player is one squad')

    -- A NINTH PLAYER REBALANCES 4/4 INTO 3/3/3, and everyone who moved is
    -- told. Silently swapping someone's team between glances at the squad
    -- panel is indistinguishable from a bug.
    reset()
    BR.Config.Match.minSquadsDev = 2
    for i = 1, 8 do queueUp(i, 'P' .. i, BR.Mode.SQUAD.key) end
    fakeTime = fakeTime + 300
    BR.Sched.step(fakeTime)

    m = theMatch()
    s = sizesOf(m)
    ok(#s == 2 and s[1] == 4 and s[2] == 4, 'eight players make two full squads',
        table.concat(s, '/'))

    sent = {}
    join(9, 'Ninth')
    BR.Party.lateJoin(9, m)

    s = sizesOf(m)
    ok(#s == 3 and s[1] == 3 and s[2] == 3 and s[3] == 3,
        'and a ninth rebalances them to three squads of three',
        table.concat(s, '/'))

    local told = 0
    for _, ev in ipairs(eventsOf(BR.Net.NOTIFY)) do
        if ev.args[1].text:find('rebalanced') then told = told + 1 end
    end
    ok(told > 0, 'the players who moved are told why', ('%d told'):format(told))

    -- Parties are NEVER split by a rebalance. That is the one thing this
    -- system must not do, whatever the arithmetic wants.
    reset()
    BR.Config.Match.minSquadsDev = 2
    join(1, 'A'); join(2, 'B')
    BR.Party.invite(1, 2); BR.Party.respond(2, true)
    for i = 1, 6 do
        if i > 2 then join(i, 'P' .. i) end
        fire(BR.Net.QUEUE_JOIN, i, { mode = BR.Mode.SQUAD.key })
    end
    fakeTime = fakeTime + 300
    BR.Sched.step(fakeTime)

    m = theMatch()
    local a, b = BR.Roster.get(1), BR.Roster.get(2)
    ok(a and b and a.squadId and a.squadId == b.squadId,
        'a party stays together through formation')

    join(9, 'Late')
    BR.Party.lateJoin(9, m)
    a, b = BR.Roster.get(1), BR.Roster.get(2)
    ok(a and b and a.squadId == b.squadId,
        'and through a rebalance')

    BR.Config.Match.minSquadsDev = devFloor
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
    ok(mstate() == BR.MatchState.WARMUP, 'match reaches warmup')

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

    -- A DEAD SQUADMATE STAYS ON THE PUSH (user, 2026-08-05). The client's
    -- membership model IS this list, so dropping the dead took their blip and
    -- their overhead name with them -- and where a teammate fell is exactly
    -- the thing their squad needs to see. The survivor keeps receiving.
    forceState(BR.MatchState.PLAYING)
    BR.Combat.eliminate(2, 'test', nil)
    sent = {}
    fakeTime = fakeTime + 1100
    BR.Sched.step(fakeTime)
    local after = eventsOf(BR.Net.SQUAD_POS)
    local deadSeen, survivorGot, deadState = false, false, nil
    for _, p in ipairs(after) do
        if p.target == 1 then survivorGot = true end
        for _, m in ipairs(p.args[1]) do
            if m.src == 2 then
                deadSeen = true
                deadState = m.state
            end
        end
    end
    ok(deadSeen, 'a dead squadmate is still broadcast to their squad')
    ok(survivorGot, 'the survivor keeps receiving the push')
    ok(deadState == BR.PlayerState.DEAD,
        'the payload carries the dead state, so the client can mark the tag',
        tostring(deadState))

    -- The privacy boundary is unchanged by that: a dead player is still only
    -- ever shown to their OWN squad, never to the other one.
    local crossSquad = false
    for _, p in ipairs(after) do
        local targetSquad = BR.Roster.get(p.target)
        targetSquad = targetSquad and targetSquad.squadId
        for _, m in ipairs(p.args[1]) do
            local e = BR.Roster.get(m.src)
            if not e or e.squadId ~= targetSquad then crossSquad = true end
        end
    end
    ok(not crossSquad, 'a dead mate never leaks to another squad')

    -- And a SOLO round shares nothing with anybody: no squads, no beacons.
    reset()
    join(1, 'A'); join(2, 'B')
    fire(BR.Net.QUEUE_JOIN, 1, { mode = BR.Mode.SOLO.key })
    fire(BR.Net.QUEUE_JOIN, 2, { mode = BR.Mode.SOLO.key })
    fakeTime = fakeTime + 300
    BR.Sched.step(fakeTime)
    ok(mstate() == BR.MatchState.WARMUP, 'solo match reaches warmup')
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
    ok(mstate() == BR.MatchState.WARMUP, 'one dev player starts a match')

    forceState(BR.MatchState.PLAYING)
    fakeTime = fakeTime + 5000        -- well past WIN_GRACE_MS
    BR.Sched.step(fakeTime)
    ok(mstate() == BR.MatchState.PLAYING,
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
    forceState(BR.MatchState.PLAYING)
    BR.Combat.eliminate(2, 'test', 1)
    fakeTime = fakeTime + 5000
    BR.Sched.step(fakeTime)
    ok(mstate() == BR.MatchState.ENDED,
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
    ok(mstate() == BR.MatchState.WARMUP, 'the early bird starts warmup')
    ok(BR.Roster.get(2).state == BR.PlayerState.LOBBY, 'the other is still an idler')

    fire(BR.Net.QUEUE_JOIN, 2, { mode = BR.Mode.SOLO.key })
    ok(BR.Roster.get(2).state == BR.PlayerState.WARMUP,
        'readying up during warmup joins the forming match directly')
    ok(BR.Server.queue[2] == nil, 'and does not sit in the queue')

    -- Both now count as starting teams: the solo-dev hold does not engage and
    -- the match ends like any other.
    forceState(BR.MatchState.PLAYING)
    BR.Combat.eliminate(2, 'test', 1)
    fakeTime = fakeTime + 5000
    BR.Sched.step(fakeTime)
    ok(mstate() == BR.MatchState.ENDED,
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
    ok(mstate() == BR.MatchState.WARMUP, 'squad match forms')

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
    -- Player 3's party is incomplete, so the party gate holds first (one
    -- tick to engage its patience clock); the match forms once the patience
    -- runs out. That is the door 3 will late-join through -- this scenario.
    fakeTime = fakeTime + 300
    BR.Sched.step(fakeTime)
    fakeTime = fakeTime + BR.Config.Match.partyGraceSeconds * 1000 + 1500
    BR.Sched.step(fakeTime)
    ok(mstate() == BR.MatchState.WARMUP, 'match forms without player 3')
    ok(BR.Roster.get(4).squadId ~= BR.Roster.get(1).squadId,
        'the solo has a squad of one -- the emptier target')

    fire(BR.Net.QUEUE_JOIN, 3, { mode = BR.Mode.SQUAD.key })
    ok(BR.Roster.get(3).squadId == BR.Roster.get(1).squadId,
        "a late partymate lands on their party's squad, not the emptier one",
        ('got %s, wanted %s'):format(tostring(BR.Roster.get(3).squadId),
                                     tostring(BR.Roster.get(1).squadId)))
    BR.Config.Match.autofill = true

    -- From BUS onward the door is shut: late arrivals queue for the NEXT match.
    forceState(BR.MatchState.BUS)
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
    ok(mstate() == BR.MatchState.WARMUP, 'warmup starts')

    -- The route is drawn AT WARMUP -- players plan their drop with it -- but
    -- carries no clock yet: the wheels move at BUS.
    local r = BR.Bus.active(theMatch())
    ok(r ~= nil, 'the flight is drawn when warmup begins')
    ok(#eventsOf(BR.Net.BUS_ROUTE) >= 1, 'and the preview reaches every client')
    ok(r.timed == false, 'but it is not timed until departure')

    ok(#r.legs == #BR.Config.Bus.legs, 'one option chosen per leg')
    local legsValid, wpIdx = true, 1
    for li, pick in ipairs(r.legs) do
        local option = BR.Config.Bus.legs[li][pick]
        if not option then legsValid = false break end
        for _, wp in ipairs(option) do
            local got = r.waypoints[wpIdx]
            if not got or got.x ~= wp.x or got.y ~= wp.y then legsValid = false end
            wpIdx = wpIdx + 1
        end
    end
    ok(legsValid and wpIdx - 1 == #r.waypoints,
        'the tour is exactly the chosen options, in leg order')

    sent = {}
    fakeTime = mendsAt() + 1
    BR.Sched.step(fakeTime)
    ok(mstate() == BR.MatchState.BUS, 'warmup expires into the bus')
    ok(BR.Roster.get(1).state == BR.PlayerState.BUS, 'players are aboard')

    r = BR.Bus.active(theMatch())
    ok(r.timed == true, 'departure stamps the clock onto the geometry')
    ok(#eventsOf(BR.Net.BUS_ROUTE) == 2,
        'and rebroadcasts the timed flight to each of the two riders')

    local sp = BR.Config.Bus.spawn
    local p1 = r.points[1]
    ok(p1.x == sp.x and p1.y == sp.y and p1.z == sp.z,
        'the path begins parked at the surveyed runway spawn')
    ok(r.tStart < r.jumpFrom and r.jumpFrom < r.tEnd, 'doors open inside the flight')

    local ordered, groundedRoll = true, true
    for i = 2, #r.points do
        if r.points[i].t <= r.points[i - 1].t then ordered = false end
    end
    for _, p in ipairs(r.points) do
        if p.t <= r.tStart then groundedRoll = groundedRoll and p.z == sp.z end
    end
    ok(ordered, 'waypoint timestamps strictly increase')
    ok(groundedRoll, 'the ground roll stays on the ground')

    -- Speed continuity: implied segment speeds must ramp, not step. Before
    -- the kinematic smoothing, cruise into a corner was a 400 -> 150 cliff
    -- across one sample.
    local maxJump, prevSpd = 0.0, nil
    for i = 2, #r.points do
        local a, b = r.points[i - 1], r.points[i]
        local d = BR.Dist(a.x, a.y, b.x, b.y)
        local dt = (b.t - a.t) / 1000.0
        if dt > 0.01 and d > 5.0 then
            local spd = d / dt
            if prevSpd then
                maxJump = math.max(maxJump, math.abs(spd - prevSpd))
            end
            prevSpd = spd
        end
    end
    ok(maxJump < 80.0, 'speed changes ramp instead of stepping',
        ('largest adjacent speed jump: %.0f m/s'):format(maxJump))

    -- THE DOORS OPEN AT THE LEG-1 WAYPOINT, *OR* EARLIER OVER A DOOR ZONE.
    --
    -- This used to assert the leg-1 waypoint alone. That is no longer the
    -- contract: a tour that crosses the ports or LSIA opens the doors there
    -- too, wherever that falls in the route (user, 2026-08-06). What still has
    -- to hold is that the bus is FLYING when they open -- at cruise altitude,
    -- after rotation -- and that the opening point is somewhere the players
    -- were actually shown, i.e. the first waypoint or a door zone.
    local doorX, doorY, doorZ = BR.PathPosAt(r.points, r.jumpFrom)
    ok(math.abs(doorZ - BR.Config.Bus.altitude) < 1.0,
        'the bus is at cruise altitude when the doors open')
    ok(r.jumpFrom >= r.rotateAt,
        'and the doors never open before the wheels leave the runway',
        ('jumpFrom %d, rotateAt %d'):format(r.jumpFrom, r.rotateAt))

    local w1 = r.waypoints[1]
    local atWp1 = BR.Dist(doorX, doorY, w1.x, w1.y) <= BR.Config.Bus.turnRadius + 50.0
    local inZone = false
    for _, z in ipairs(BR.Config.Map.DoorZones or {}) do
        if BR.Dist(doorX, doorY, z.x, z.y) <= z.radius then inZone = true end
    end
    ok(atWp1 or inZone,
        'the doors open at the first authored waypoint or over a door zone',
        ('door at %.0f,%.0f -- wp1 at %.0f,%.0f, inZone=%s')
            :format(doorX, doorY, w1.x, w1.y, tostring(inZone)))

    -- AND THE WINDOW ONLY EVER WIDENS. A zone must never shorten the jumpable
    -- stretch -- that would make some tours worse than before the feature.
    ok(r.doorsClose >= r.jumpFrom,
        'the door window is never inverted by a zone')

    -- The last AUTHORED point is where the doors-closing warning fires; the
    -- path then overruns ~5s so stragglers get a last call instead of the
    -- plane evaporating under them.
    local wn = r.waypoints[#r.waypoints]
    local pc = r.points[r.closeIdx]
    ok(math.abs(pc.x - wn.x) < 0.1 and math.abs(pc.y - wn.y) < 0.1,
        'the doors-closing point is the final authored waypoint')
    ok(r.doorsClose < r.tEnd, 'and the plane keeps flying past it')
    local overrun = (r.tEnd - r.doorsClose) / 1000
    ok(overrun > 3 and overrun < 10,
        'for about the configured overrun', ('overrun %.1fs'):format(overrun))
    -- The storm anchor rides the route draw: it must be an authored POI within
    -- anchor-band reach of SOME waypoint of this tour -- that is the whole
    -- design ("select a flight leg coord, then a POI 500-1500 off it").
    local anch = manchor()
    ok(anch ~= nil, 'a match anchor is picked for the storm')
    local anchIsPoi = false
    for _, p in ipairs(BR.Config.Map.POIs) do
        if p.id == anch.poi and p.x == anch.x and p.y == anch.y then
            anchIsPoi = true
        end
    end
    ok(anchIsPoi, 'the anchor is an authored POI')
    local bandMax = BR.Config.Storm.anchorBand.widenMax
    local anchNear = false
    for _, w in ipairs(r.waypoints) do
        if BR.Dist(w.x, w.y, anch.x, anch.y) <= bandMax then anchNear = true end
    end
    ok(anchNear, 'the anchor is within band reach of this tour')

    -- The spawn heading IS the roll direction. The surveyed heading was ~3
    -- degrees off the actual spawn->rotate line, and the airframe visibly
    -- snapped straight as the roll began.
    local sp2, rp2 = BR.Config.Bus.spawn, BR.Config.Bus.rotatePoint
    local wantHdg = BR.GtaHeading(BR.Bearing(sp2.x, sp2.y, rp2.x, rp2.y))
    local hdgDiff = math.abs(((r.heading - wantHdg + 540.0) % 360.0) - 180.0)
    ok(hdgDiff < 0.01, 'the plane spawns facing exactly down the runway',
        ('heading %.2f vs direction %.2f'):format(r.heading, wantHdg))
    ok(mendsAt() >= r.tEnd, 'BUS lasts at least the whole flight')

    -- Jumping before the doors is refused; after them it is an elimination
    -- of altitude, not of the player.
    sent = {}
    fire(BR.Net.BUS_JUMP, 1)
    ok(BR.Roster.get(1).state == BR.PlayerState.BUS, 'jumping before the doors is refused')
    ok(#eventsOf(BR.Net.BUS_JUMP_OK) == 0, 'no exit coordinates are sent')

    fakeTime = r.jumpFrom + 1000
    fire(BR.Net.BUS_JUMP, 1)
    ok(BR.Roster.get(1).state == BR.PlayerState.FREEFALL, 'jumping past the doors works')
    local oks = eventsOf(BR.Net.BUS_JUMP_OK)
    ok(#oks == 1 and oks[1].target == 1, 'exit coordinates go to the jumper alone')
    local jx, jy = oks[1].args[1].x, oks[1].args[1].y
    local px, py = BR.PathPosAt(r.points, fakeTime)
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
    fakeTime = mendsAt() + 1
    BR.Sched.step(fakeTime)
    ok(mstate() == BR.MatchState.PLAYING, 'the route expires into PLAYING')
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

    -- Variety and the Chiliad clearance, across many seeds. Runs last: each
    -- plan() replaces the live route.
    local combos, sawChiliad, chiliadOk = {}, false, true
    local comboCount = 0
    for seed = 1, 40 do
        fakeTime = fakeTime + 7919 * seed
        BR.Bus.plan(theMatch())
        local rr = BR.Bus.active(theMatch())

        local key = table.concat(rr.legs, '-')
        if not combos[key] then
            combos[key] = true
            comboCount = comboCount + 1
        end

        -- Exit option 1 doglegs over the Chiliad massif with explicit
        -- altitudes; if those are dropped anywhere in the pipeline, the
        -- plane flies through the mountain at 500.
        if rr.legs[4] == 1 then
            sawChiliad = true
            local peak = 0.0
            for _, p in ipairs(rr.points) do
                if p.z > peak then peak = p.z end
            end
            if peak < 850.0 then chiliadOk = false end
        end
    end
    ok(comboCount >= 8, 'the draw actually varies across matches',
        ('%d distinct tours in 40 draws'):format(comboCount))
    ok(sawChiliad, 'the Chiliad exit came up at least once in 40 draws')
    ok(chiliadOk, "the Chiliad exit's authored altitudes survive into the path")
    BR.Bus.clear(theMatch())
end

describe('roster.buckets')
do
    -- THE INSTANCE MODEL (2026-08-03; communal warmup 2026-08-04): ONE
    -- shared lobby bucket; ONE shared WARMUP bucket -- the pad is communal,
    -- so players waiting on any flight watch the others depart -- and a
    -- fresh private bucket per match that riders enter only once their
    -- flight is genuinely airborne (or the moment they jump).
    reset()
    BR.Server.devMode = true
    local LB = BR.Config.Match.lobbyBucket
    local WB = BR.Config.Match.warmupBucket
    join(1, 'A'); join(2, 'B')
    ok(buckets[1] == LB and buckets[2] == LB,
        'joining lands everyone in the one shared lobby bucket')

    fire(BR.Net.QUEUE_JOIN, 1, { mode = BR.Mode.SOLO.key })
    fire(BR.Net.QUEUE_JOIN, 2, { mode = BR.Mode.SOLO.key })
    fakeTime = fakeTime + 300
    BR.Sched.step(fakeTime)
    ok(mstate() == BR.MatchState.WARMUP, 'match starts')
    ok(buckets[1] == WB and buckets[2] == WB,
        'warmup is the COMMUNAL warmup bucket, not the match bucket',
        ('got %s/%s want %d'):format(tostring(buckets[1]), tostring(buckets[2]), WB))
    ok(WB ~= LB, 'which is never the lobby bucket')

    fire(BR.Net.MATCH_LEAVE, 2)
    ok(buckets[2] == LB, 'leaving the match returns them to the lobby bucket')
    ok(buckets[1] == WB, 'without disturbing anyone still on the pad')

    -- Departure: riders HOLD the communal bucket through boarding and the
    -- roll -- the airstrip watches the takeoff -- and hop to the match's
    -- own bucket once the flight has climbed out.
    forceState(BR.MatchState.BUS)
    local m = theMatch()
    ok(buckets[1] == WB, 'riders keep the communal bucket through boarding')
    fakeTime = m.route.rotateAt + 3600
    BR.Sched.step(fakeTime)
    local mb = BR.Config.Match.matchBucketBase + m.id
    ok(m.airborne == true, 'the flight goes airborne shortly after wheels-up')
    ok(buckets[1] == mb, "and its riders hop to the match's own bucket",
        ('got %s want %d'):format(tostring(buckets[1]), mb))
    ok(mb ~= LB and mb ~= WB, 'which is neither shared bucket')

    -- The NEXT match gets a different bucket: leftover entities from this
    -- round can never haunt the next one.
    forceState(BR.MatchState.ENDED)
    forceState(BR.MatchState.CLEANUP)
    forceState(BR.MatchState.WAITING)
    ok(buckets[1] == LB, 'the trip home is the lobby bucket again')
    queueUp(1, 'A'); queueUp(2, 'B')
    fakeTime = fakeTime + 1000
    BR.Sched.step(fakeTime)
    ok(mstate() == BR.MatchState.WARMUP, 'second match starts')
    local mb2 = BR.Config.Match.matchBucketBase + theMatch().id
    ok(mb2 ~= mb, 'and it owns a fresh private bucket for its flight')
end

describe('match.earlyDeath')
do
    -- REGRESSION, reported in play: a player who died while the machine was
    -- still in BUS (dove into the ground) left the server thinking they were
    -- alive, and the match never ended.
    reset()
    BR.Server.devMode = true
    join(1, 'A'); join(2, 'B')
    fire(BR.Net.QUEUE_JOIN, 1, { mode = BR.Mode.SOLO.key })
    fire(BR.Net.QUEUE_JOIN, 2, { mode = BR.Mode.SOLO.key })
    fakeTime = fakeTime + 300
    BR.Sched.step(fakeTime)
    fakeTime = mendsAt() + 1
    BR.Sched.step(fakeTime)
    ok(mstate() == BR.MatchState.BUS, 'both aboard')

    local r = BR.Bus.active(theMatch())

    -- Player 2 jumps at the doors, dives, lands, and dies -- all during BUS.
    fakeTime = r.jumpFrom + 1000
    fire(BR.Net.BUS_JUMP, 2)
    ok(BR.Roster.get(2).state == BR.PlayerState.FREEFALL, 'p2 is out early')
    fire(BR.Net.DROP_LANDED, 2)
    ok(BR.Roster.get(2).state == BR.PlayerState.ALIVE, 'p2 hit the ground')
    fire(BR.Net.PLAYER_DIED, 2, { cause = 'fall' })
    ok(BR.Roster.get(2).state == BR.PlayerState.DEAD,
        'a death during BUS is a real death')

    -- The route runs out; player 1 is force-ejected, lands, stands alone.
    fakeTime = r.tEnd + 600
    BR.Sched.step(fakeTime)
    fakeTime = mendsAt() + 1
    BR.Sched.step(fakeTime)
    ok(mstate() == BR.MatchState.PLAYING, 'the match goes live')
    fire(BR.Net.DROP_LANDED, 1)

    fakeTime = fakeTime + 4000   -- past WIN_GRACE_MS
    BR.Sched.step(fakeTime)
    ok(mstate() == BR.MatchState.ENDED,
        'and ends: the early death counted',
        ('state %s, squadsAlive %d'):format(mstate(), BR.Server.squadsAlive()))

    -- Variant: dies MID-AIR during BUS (never landed).
    reset()
    BR.Server.devMode = true
    join(1, 'A'); join(2, 'B')
    fire(BR.Net.QUEUE_JOIN, 1, { mode = BR.Mode.SOLO.key })
    fire(BR.Net.QUEUE_JOIN, 2, { mode = BR.Mode.SOLO.key })
    fakeTime = fakeTime + 300
    BR.Sched.step(fakeTime)
    fakeTime = mendsAt() + 1
    BR.Sched.step(fakeTime)
    local r2 = BR.Bus.active(theMatch())
    fakeTime = r2.jumpFrom + 1000
    fire(BR.Net.BUS_JUMP, 2)
    fire(BR.Net.PLAYER_DIED, 2, { cause = 'fall' })
    ok(BR.Roster.get(2).state == BR.PlayerState.DEAD, 'a freefall death counts too')

    fakeTime = r2.tEnd + 600
    BR.Sched.step(fakeTime)
    fakeTime = mendsAt() + 1
    BR.Sched.step(fakeTime)
    fire(BR.Net.DROP_LANDED, 1)
    fakeTime = fakeTime + 4000
    BR.Sched.step(fakeTime)
    ok(mstate() == BR.MatchState.ENDED,
        'the match still ends',
        ('state %s, squadsAlive %d'):format(mstate(), BR.Server.squadsAlive()))
end

describe('match.lastLanding')
do
    -- BUS -> PLAYING is driven by the LAST landing, not the route timer --
    -- the timer is only the ceiling for clients that crash mid-fall.
    reset()
    BR.Server.devMode = true
    join(1, 'A'); join(2, 'B')
    fire(BR.Net.QUEUE_JOIN, 1, { mode = BR.Mode.SOLO.key })
    fire(BR.Net.QUEUE_JOIN, 2, { mode = BR.Mode.SOLO.key })
    fakeTime = fakeTime + 300
    BR.Sched.step(fakeTime)
    fakeTime = mendsAt() + 1
    BR.Sched.step(fakeTime)
    ok(mstate() == BR.MatchState.BUS, 'both aboard')

    local r = BR.Bus.active(theMatch())
    fakeTime = r.jumpFrom + 1000
    fire(BR.Net.BUS_JUMP, 1)
    fire(BR.Net.BUS_JUMP, 2)
    fire(BR.Net.DROP_LANDED, 1)

    -- One down, one still falling: the match must NOT go live.
    fakeTime = fakeTime + 300
    BR.Sched.step(fakeTime)
    ok(mstate() == BR.MatchState.BUS,
        'one player still airborne holds the bus state')

    -- The second lands, long before the route runs out.
    fire(BR.Net.DROP_LANDED, 2)
    fakeTime = fakeTime + 300
    BR.Sched.step(fakeTime)
    ok(mstate() == BR.MatchState.PLAYING,
        'the last landing takes the match live early')
    ok(fakeTime < r.tEnd, 'well before the route timer',
        ('%.0fs early'):format((r.tEnd - fakeTime) / 1000))

    -- Ceiling intact: a ghost stuck in FREEFALL cannot hold the match.
    reset()
    BR.Server.devMode = true
    join(1, 'A'); join(2, 'B')
    fire(BR.Net.QUEUE_JOIN, 1, { mode = BR.Mode.SOLO.key })
    fire(BR.Net.QUEUE_JOIN, 2, { mode = BR.Mode.SOLO.key })
    fakeTime = fakeTime + 300
    BR.Sched.step(fakeTime)
    fakeTime = mendsAt() + 1
    BR.Sched.step(fakeTime)
    local r2 = BR.Bus.active(theMatch())
    fakeTime = r2.jumpFrom + 1000
    fire(BR.Net.BUS_JUMP, 1)
    fire(BR.Net.DROP_LANDED, 1)   -- p1 lands; p2 rides to force-eject and never reports
    fakeTime = r2.tEnd + 600
    BR.Sched.step(fakeTime)
    fakeTime = mendsAt() + 1
    BR.Sched.step(fakeTime)
    ok(mstate() == BR.MatchState.PLAYING,
        'the route timer still forces PLAYING past a silent faller')
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

describe('match.storm')
do
    -- The M4 engine, end to end on the server alone: PLAYING starts the
    -- clock, the record is published once per phase, damage is decided from
    -- server-sampled positions, and the LEDGER -- not the client's ped --
    -- is what eliminates. This last property is the authority drill in unit
    -- test form: player 2's "client" never applies a single point of the
    -- damage it is told about, and dies on schedule anyway.
    reset()
    queueUp(1, 'A'); queueUp(2, 'B')
    fakeTime = fakeTime + 1000
    BR.Sched.step(fakeTime)
    ok(mstate() == BR.MatchState.WARMUP, 'warmup starts')

    -- Stand both players ON the anchor before the match goes live, so the
    -- distance-scaled hold bottoms out at its 120s minimum and the timing
    -- assertions below stay exact. The far-player case has its own block.
    local a0 = manchor()
    setPos(1, a0.x, a0.y); setPos(2, a0.x, a0.y)
    fakeTime = fakeTime + 1000
    BR.Sched.step(fakeTime)   -- the position sampler picks them up

    sent = {}
    fakeTime = fakeTime + 1000
    forceState(BR.MatchState.PLAYING)

    local rec = mstorm()
    local a   = manchor()
    ok(rec ~= nil, 'PLAYING starts the storm')
    ok(rec.phase == 1, 'phase 1 is entered directly -- the hold IS its wait')
    ok(rec.cx0 == a.x and rec.cy0 == a.y, 'the opening circle sits on the match anchor')

    -- THE OPENING CIRCLE COVERS THE WHOLE MAP: every playable-bounds corner
    -- inside, so "landed outside circle 1, bleeding on arrival" is
    -- structurally impossible (live report, 2026-08-02).
    local A = BR.Config.Storm.mapAABB
    local cornersIn = true
    for _, c in ipairs({ { A.min.x, A.min.y }, { A.min.x, A.max.y },
                         { A.max.x, A.min.y }, { A.max.x, A.max.y } }) do
        if BR.Dist(a.x, a.y, c[1], c[2]) > rec.r0 then cornersIn = false end
    end
    ok(cornersIn, 'the opening circle contains the whole playable map')
    ok(rec.r0 >= BR.Config.Storm.radius0, 'and never shrinks below the radius0 floor')

    ok(rec.tWait == BR.Config.Storm.hold.minSeconds * 1000.0,
        'players at the anchor get the minimum free-loot hold (one minute)')
    ok(rec.r1 == BR.Config.Storm.phases[1].radius,
        'the first target circle is known the moment the match goes live')
    ok(BR.Dist(rec.cx0, rec.cy0, rec.cx1, rec.cy1) + rec.r1 <= rec.r0 + 1e-6,
        'and nests inside the opening circle')

    local syncs = eventsOf(BR.Net.STORM_SYNC)
    local gotSync = {}
    for _, sy in ipairs(syncs) do gotSync[sy.target] = true end
    ok(#syncs >= 1 and gotSync[1] and gotSync[2],
        'the record reaches every participant')
    ok(not gotSync[-1], 'and is never blasted to the whole server')

    -- A participant rebuilding its mirror (br_ui restart) gets the record in
    -- its snapshot; a lobby bystander gets none -- storm is match traffic.
    sent = {}
    fire(BR.Net.READY, 1)
    local snaps = eventsOf(BR.Net.SNAPSHOT)
    ok(#snaps == 1 and snaps[1].args[1].storm ~= nil,
        'snapshots carry the storm record for a participant rebuilding')
    join(5, 'Late')
    sent = {}
    fire(BR.Net.READY, 5)
    snaps = eventsOf(BR.Net.SNAPSHOT)
    ok(#snaps == 1 and snaps[1].args[1].storm == nil,
        "a lobby bystander's snapshot carries no other match's storm")
    leave(5)

    -- Damage targeting: 1 stands at the anchor (inside), 2 beyond even the
    -- full-map opening circle (a spot no real player can reach, which is the
    -- point -- it stays outside through every assertion below).
    setPos(1, a.x, a.y)
    setPos(2, a.x + rec.r0 + 4000.0, a.y)

    -- THE FREE-LOOT HOLD IS FREE: during phase 1's wait, being outside
    -- circle 1 costs nothing -- no wire damage, no ledger. Live report
    -- pinned here: a far-end jumper bled from the moment they landed.
    sent = {}
    fakeTime = fakeTime + 1000; BR.Sched.step(fakeTime)
    fakeTime = fakeTime + 1000; BR.Sched.step(fakeTime)
    ok(#eventsOf(BR.Net.STORM_DAMAGE) == 0,
        'nobody takes damage during the phase-1 free-loot hold')
    ok(BR.Roster.get(2).stormHp == nil,
        'and the ledger stays empty for the whole map')

    -- The first shrink is where the storm goes live. RECORD-DRIVEN, not a
    -- hardcoded step: the hold and shrink are both priced dynamically now,
    -- so the record is the only honest schedule.
    sent = {}
    fakeTime = rec.tStart + rec.tWait + 1000
    BR.Sched.step(fakeTime)
    fakeTime = fakeTime + 1000; BR.Sched.step(fakeTime)

    local toOne, lastToTwo, countTwo = 0, nil, 0
    for _, h in ipairs(eventsOf(BR.Net.STORM_DAMAGE)) do
        if h.target == 1 then toOne = toOne + 1 end
        if h.target == 2 then countTwo = countTwo + 1 lastToTwo = h.args[1] end
    end
    ok(toOne == 0, 'a player inside the circle is never told to take damage')
    ok(countTwo >= 1, 'the player outside is, once the shrink begins')
    -- Phase 1 is 1.0 DISPLAY hp/s; the wire speaks ENGINE units. With the
    -- corrected floor (100..200 live range, span 100) the two scales move
    -- 1:1 -- derived from the converter, not hardcoded, so a future span
    -- change lands here as arithmetic and not as a stale literal.
    local expectEngine = math.floor(BR.ToEngineHpDelta(1.0) + 0.5)
    ok(lastToTwo and lastToTwo.amount == expectEngine,
        'damage crosses the wire in engine units',
        lastToTwo and ('amount %s, expected %d'):format(
            tostring(lastToTwo.amount), expectEngine) or 'none')
    ok(BR.Roster.get(2).stormHp ~= nil, 'the server ledger tracks the exposure')
    ok(BR.Roster.get(1).stormHp == nil, 'and carries nothing for the safe player')

    -- Phase advancement: jump past the rest of the shrink; the next record
    -- starts exactly where the last one finished.
    local c1x, c1y, r1 = rec.cx1, rec.cy1, rec.r1
    sent = {}
    fakeTime = rec.tStart + rec.tWait + rec.tShrink + 1500
    BR.Sched.step(fakeTime)
    local rec2 = mstorm()
    ok(rec2.phase == 2, 'a finished shrink advances the phase')
    ok(rec2.cx0 == c1x and rec2.cy0 == c1y and rec2.r0 == r1,
        'the new record starts at the old target circle')
    -- ITS OWN TARGET STAYS WITHIN THE PHASE'S REACH BUDGET.
    --
    -- This used to assert strict nesting. It no longer holds by design: a
    -- phase may roll a BREAKOUT and put the next circle partly outside the
    -- current one, so that sitting still is never a winning move (user call,
    -- 2026-08-06). What must still hold is the budget the phase priced its
    -- sweep against -- slack, plus the breakout overhang when one is allowed.
    local bo = BR.Config.Storm.breakout
    local slack2 = rec2.r0 - rec2.r1
    local reach2 = slack2
    if bo and rec2.r0 >= (bo.minRadius or 0.0) then
        -- The breakout budget, stated as the geometry: edges touching plus a
        -- gap of at most gapMax * the predecessor's radius. Computed from the
        -- LIVE config rather than a literal, so retuning the storm cannot
        -- leave this test asserting a number nothing uses any more.
        reach2 = rec2.r0 + rec2.r1 + (bo.gapMax or 0.0) * rec2.r0
    end
    ok(BR.Dist(rec2.cx0, rec2.cy0, rec2.cx1, rec2.cy1) <= reach2 + 1e-6,
        'and its own target stays inside the phase reach budget',
        ('offset %.1f, budget %.1f'):format(
            BR.Dist(rec2.cx0, rec2.cy0, rec2.cx1, rec2.cy1), reach2))
    ok(#eventsOf(BR.Net.STORM_SYNC) >= 1, 'the new phase is rebroadcast')

    -- THE AUTHORITY PROOF. Player 2's ped health never moves -- this client
    -- ignores every STORM_DAMAGE it is sent -- but the ledger runs out at the
    -- dps-predicted moment and the server eliminates them anyway.
    -- The block is in phase 2 by now (1.25 dps on the kill-time curve):
    -- display 5 is exactly four one-second ticks of life.
    pedHealth[1002] = BR.ToEngineHp(5)   -- display 5, converter-derived
    local deadAt = nil
    for i = 1, 14 do
        fakeTime = fakeTime + 1000
        BR.Sched.step(fakeTime)
        local e = BR.Roster.get(2)
        if e and e.state == BR.PlayerState.DEAD and not deadAt then deadAt = i end
    end
    ok(deadAt ~= nil,
        'the LEDGER eliminates a client that never applies its storm damage')
    ok(deadAt and deadAt >= 3 and deadAt <= 6,
        'at the dps-predicted moment (5 hp / 1.25 dps), not instantly and not late',
        ('died on tick %s'):format(tostring(deadAt)))

    local feed = eventsOf(BR.Net.KILL_FEED)
    ok(#feed >= 1 and feed[#feed].args[1].cause == 'storm',
        'the kill feed names the storm')

    -- And the win condition sees it like any other death: last squad standing.
    ok(mstate() == BR.MatchState.ENDED,
        'a storm kill can decide the match')
    ok(mstorm() == nil or mstate() ~= BR.MatchState.PLAYING,
        'no storm keeps running past the match')

    pedHealth[1002] = nil
end

describe('match.abandoned')
do
    -- Everyone brleaving during warmup used to leave the state machine
    -- idling out the warmup clock for nobody. An empty match aborts.
    reset()
    queueUp(1, 'A'); queueUp(2, 'B')
    fakeTime = fakeTime + 1000
    BR.Sched.step(fakeTime)
    ok(mstate() == BR.MatchState.WARMUP, 'warmup starts')

    fire(BR.Net.MATCH_LEAVE, 1)
    fire(BR.Net.MATCH_LEAVE, 2)
    fakeTime = fakeTime + 300
    BR.Sched.step(fakeTime)
    ok(mstate() == BR.MatchState.WAITING,
        'an all-left warmup aborts straight back to WAITING')
end

describe('match.partyGate')
do
    -- Parties enter together: one member readying up must not launch the
    -- match while the rest of the party is still in the menu -- the first
    -- two-client squad test started on the first Ready.
    reset()
    BR.Server.devMode = true
    BR.Config.Match.minToStart = 1   -- so the party gate is what holds, not headcount
    join(1, 'A'); join(2, 'B')
    BR.Party.invite(1, 2)
    fire(BR.Net.SQUAD_RESPOND, 2, { accept = true })

    fire(BR.Net.QUEUE_JOIN, 1, { mode = 'squad' })
    fakeTime = fakeTime + 1000
    BR.Sched.step(fakeTime)
    ok(mstate() == BR.MatchState.WAITING,
        'one ready in a party of two holds the match')
    local blocker = BR.Match.startBlocker()
    ok(blocker and blocker.reason == 'party' and blocker.have == 1 and blocker.need == 2,
        'and the blocker names the party as the reason',
        blocker and ('%s %s/%s'):format(tostring(blocker.reason),
            tostring(blocker.have), tostring(blocker.need)) or 'nil')

    fire(BR.Net.QUEUE_JOIN, 2, { mode = 'squad' })
    fakeTime = fakeTime + 1000
    BR.Sched.step(fakeTime)
    ok(mstate() == BR.MatchState.WARMUP,
        'the second Ready releases it')

    -- Patience: an AFK partymate cannot brick the queue. The hold expires
    -- after partyGraceSeconds and the match forms without them (they can
    -- still late-join during warmup).
    forceState(BR.MatchState.ENDED)
    forceState(BR.MatchState.CLEANUP)
    forceState(BR.MatchState.WAITING)
    fire(BR.Net.QUEUE_JOIN, 1, { mode = 'squad' })
    fakeTime = fakeTime + 1000
    BR.Sched.step(fakeTime)
    ok(mstate() == BR.MatchState.WAITING, 'held again next match')
    fakeTime = fakeTime + BR.Config.Match.partyGraceSeconds * 1000 + 1500
    BR.Sched.step(fakeTime)
    ok(mstate() == BR.MatchState.WARMUP,
        'but patience runs out and the match forms without the idler')
end

describe('match.busDescent')
do
    -- The BUS ceiling yields to a LIVE descender: fresh, still-falling
    -- position samples extend the timer in 10s steps, so a real glider off
    -- a high exit is not forced into PLAYING mid-air (the "storm started
    -- before I landed" report). A frozen altitude stops paying within one
    -- round, so a crashed client cannot hold the room hostage.
    reset()
    queueUp(1, 'A'); queueUp(2, 'B')
    fakeTime = fakeTime + 1000
    BR.Sched.step(fakeTime)
    forceState(BR.MatchState.BUS)
    local r = BR.Bus.active(theMatch())

    fakeTime = r.jumpFrom + 1000
    fire(BR.Net.BUS_JUMP, 1)
    fire(BR.Net.BUS_JUMP, 2)
    fire(BR.Net.DROP_LANDED, 1)   -- 1 lands instantly; 2 keeps gliding
    ok(BR.Roster.get(2).state == BR.PlayerState.FREEFALL, 'player 2 is airborne')

    -- Mid-flight ticks record 2's falling altitude, so the verdict already
    -- exists when the ceiling arrives (that is the design: track always,
    -- decide at expiry).
    setPos(2, 0.0, 0.0, 500.0)
    fakeTime = fakeTime + 1000; BR.Sched.step(fakeTime)
    setPos(2, 0.0, 0.0, 450.0)
    fakeTime = fakeTime + 1000; BR.Sched.step(fakeTime)

    -- Past the ceiling with 2 visibly descending: BUS holds.
    setPos(2, 0.0, 0.0, 400.0)
    fakeTime = mendsAt() + 600
    BR.Sched.step(fakeTime)
    ok(mstate() == BR.MatchState.BUS,
        'a live descender holds the BUS past the route timer')

    setPos(2, 0.0, 0.0, 300.0)
    fakeTime = mendsAt() + 600
    BR.Sched.step(fakeTime)
    ok(mstate() == BR.MatchState.BUS, 'and keeps holding while falling')

    -- Altitude freezes (a hung client): the grace stops paying and the
    -- ceiling fires within two more checks.
    for _ = 1, 3 do
        fakeTime = math.max(fakeTime + 11000, mendsAt() + 600)
        BR.Sched.step(fakeTime)
    end
    ok(mstate() == BR.MatchState.PLAYING,
        'a frozen altitude stops extending and the match goes live')
end

describe('match.storm.hold')
do
    -- The free-loot hold is priced for the furthest player's run to the
    -- FIRST TARGET CIRCLE'S EDGE -- distance beyond phases[1].radius, not to
    -- the anchor point (pricing to the anchor charged players already inside
    -- the circle: the "everyone is in the circle, why four minutes?" report).
    -- The SHRINK is priced the same way per phase (2026-08-04): the furthest
    -- player's run to the target edge, floored at shrinkPace.minSeconds and
    -- ceilinged by the authored value.
    --
    -- edgeBiasMax is zeroed for this block to remove the random draw --
    -- but the AABB clamp can STILL shift the target off an edge-adjacent
    -- anchor, so shrink expectations are computed from the record's ACTUAL
    -- target circle rather than assumed distances.
    local savedBias = BR.Config.Storm.edgeBiasMax
    BR.Config.Storm.edgeBiasMax = 0.0

    --- What enterPhase should have priced, from the same geometry it saw.
    local function expectShrink(rec2)
        local f = 0.0
        for _, src in ipairs({ 1, 2 }) do
            local pc = pedCoords[1000 + src]
            local d = BR.Dist(pc.x, pc.y, rec2.cx1, rec2.cy1) - rec2.r1
            if d > f then f = d end
        end
        return BR.Clamp(f / BR.Config.Storm.shrinkPace.metersPerSec,
            BR.Config.Storm.shrinkPace.minSeconds,
            BR.Config.Storm.phases[1].shrink) * 1000.0
    end

    reset()
    queueUp(1, 'A'); queueUp(2, 'B')
    fakeTime = fakeTime + 1000
    BR.Sched.step(fakeTime)

    local r1 = BR.Config.Storm.phases[1].radius
    local a = manchor()
    setPos(1, a.x + r1 + 1800.0, a.y)
    setPos(2, a.x, a.y)
    fakeTime = fakeTime + 1000
    BR.Sched.step(fakeTime)

    forceState(BR.MatchState.PLAYING)
    local rec = mstorm()
    -- 200s priced, capped at the 180s start cap; the 1800m run also prices
    -- the shrink at 200s, which the authored phase-1 value ceilings.
    local cap    = BR.Config.Storm.hold.startCapSeconds * 1000.0
    local shrink = BR.Config.Storm.phases[1].shrink * 1000.0
    ok(math.abs(rec.tWait - cap) < 1500.0,
        'a 200s-priced hold waits only to the start cap (180s)',
        ('tWait %.0fms'):format(rec.tWait))
    ok(math.abs(rec.tShrink - expectShrink(rec)) < 1500.0,
        'the shrink matches the pricing formula against the actual target',
        ('tShrink %.0fms, expected %.0fms'):format(rec.tShrink, expectShrink(rec)))

    -- The formula itself, un-clamped: a 700m run beyond the target edge is
    -- ~78s of wall travel -- between the 40s floor and the 120s ceiling.
    forceState(BR.MatchState.ENDED)
    forceState(BR.MatchState.CLEANUP)
    forceState(BR.MatchState.WAITING)
    queueUp(1, 'A'); queueUp(2, 'B')
    fakeTime = fakeTime + 1000
    BR.Sched.step(fakeTime)
    a = manchor()
    setPos(1, a.x + r1 + 700.0, a.y)
    setPos(2, a.x, a.y)
    fakeTime = fakeTime + 1000
    BR.Sched.step(fakeTime)
    forceState(BR.MatchState.PLAYING)
    ok(math.abs(mstorm().tShrink - expectShrink(mstorm())) < 1500.0,
        'a mid-range run prices between the floor and the ceiling',
        ('tShrink %.0fms, expected %.0fms'):format(
            mstorm().tShrink, expectShrink(mstorm())))

    -- Landing INSIDE the first target circle prices at zero: the minimum
    -- hold applies no matter where inside it you are.
    forceState(BR.MatchState.ENDED)
    forceState(BR.MatchState.CLEANUP)
    forceState(BR.MatchState.WAITING)
    queueUp(1, 'A'); queueUp(2, 'B')
    fakeTime = fakeTime + 1000
    BR.Sched.step(fakeTime)
    a = manchor()
    setPos(1, a.x + BR.Config.Storm.phases[1].radius - 100.0, a.y)
    setPos(2, a.x, a.y)
    fakeTime = fakeTime + 1000
    BR.Sched.step(fakeTime)
    forceState(BR.MatchState.PLAYING)
    ok(mstorm().tWait == BR.Config.Storm.hold.minSeconds * 1000.0,
        'anyone already inside the target circle pays only the one-minute floor',
        ('tWait %.0fms'):format(mstorm().tWait))
    ok(math.abs(mstorm().tShrink - expectShrink(mstorm())) < 1.0,
        'an uncontested map prices at the formula (the floor when all inside)',
        ('tShrink %.0fms'):format(mstorm().tShrink))

    -- The caps: however far out the drop was, the wait stops at the start
    -- cap and the shrink at its authored ceiling. The wall is ALWAYS moving
    -- within three minutes of PLAYING.
    forceState(BR.MatchState.ENDED)
    forceState(BR.MatchState.CLEANUP)
    forceState(BR.MatchState.WAITING)
    queueUp(1, 'A'); queueUp(2, 'B')
    fakeTime = fakeTime + 1000
    BR.Sched.step(fakeTime)
    a = manchor()
    setPos(1, a.x + r1 + 9000.0, a.y)
    setPos(2, a.x, a.y)
    fakeTime = fakeTime + 1000
    BR.Sched.step(fakeTime)
    forceState(BR.MatchState.PLAYING)
    ok(mstorm().tWait == BR.Config.Storm.hold.startCapSeconds * 1000.0,
        'even the farthest drop waits only to the start cap',
        ('tWait %.0fms'):format(mstorm().tWait))
    ok(mstorm().tShrink == BR.Config.Storm.phases[1].shrink * 1000.0,
        'and its shrink stops at the authored ceiling',
        ('tShrink %.0fms'):format(mstorm().tShrink))

    BR.Config.Storm.edgeBiasMax = savedBias
end

describe('match.storm.cleanup')
do
    -- Between matches the record must be gone: the next match's clients would
    -- otherwise render last round's wall until the new PLAYING replaced it.
    reset()
    queueUp(1, 'A'); queueUp(2, 'B')
    fakeTime = fakeTime + 1000
    BR.Sched.step(fakeTime)
    forceState(BR.MatchState.PLAYING)
    ok(mstorm() ~= nil, 'storm up')

    local e1 = BR.Roster.get(1)
    e1.stormHp, e1.lastStormAt = 42.0, fakeTime

    forceState(BR.MatchState.ENDED)
    forceState(BR.MatchState.CLEANUP)
    ok(mstorm() == nil, 'CLEANUP clears the storm record')
    ok(e1.stormHp == nil and e1.lastStormAt == nil,
        'and the per-player storm ledger with it')
end

describe('match.busSafetyNets')
do
    -- The invincibility repro (2026-08-04): a lander whose DROP_LANDED went
    -- missing stayed FREEFALL -- a client-invincible state -- and BOTH
    -- safety nets (stuck-lander promotion, server deathcheck) were gated on
    -- PLAYING. That gate was circular: a stuck lander still counts as
    -- airborne, and airborne > 0 is exactly what holds the match in BUS --
    -- so the net waited on the state the stuck lander was blocking, for as
    -- long as the route had left to fly. Both nets must work DURING BUS.

    -- (1) The stuck lander is promoted mid-flight, and the promotion itself
    --     is what takes the match live -- not the route timer.
    reset()
    queueUp(1, 'A'); queueUp(2, 'B')
    fakeTime = fakeTime + 1000
    BR.Sched.step(fakeTime)
    fakeTime = mendsAt() + 1
    BR.Sched.step(fakeTime)
    ok(mstate() == BR.MatchState.BUS, 'flying')

    local r = BR.Bus.active(theMatch())
    fakeTime = r.jumpFrom + 1000
    fire(BR.Net.BUS_JUMP, 1)
    fire(BR.Net.BUS_JUMP, 2)
    fire(BR.Net.DROP_LANDED, 2)   -- 2 lands cleanly; 1's report is LOST
    ok(BR.Roster.get(1).state == BR.PlayerState.FREEFALL,
        'the lost report leaves 1 marked as falling')

    for _ = 1, 30 do              -- ~7.5s standing on the ground, silent
        setPos(1, 150.0, 150.0, 25.0)
        setPos(2, 300.0, 300.0, 25.0)
        fakeTime = fakeTime + 250
        BR.Sched.step(fakeTime)
    end
    ok(BR.Roster.get(1).state == BR.PlayerState.ALIVE,
        'constant altitude promotes the stuck lander DURING the flight')
    ok(mstate() == BR.MatchState.PLAYING,
        'and the promotion is what takes the match live')
    ok(fakeTime < r.tEnd, 'long before the route timer',
        ('%.0fs early'):format((r.tEnd - fakeTime) / 1000))

    -- (2) A death on the ground while others still fly is server-observed
    --     immediately, not shelved until PLAYING.
    reset()
    queueUp(1, 'A'); queueUp(2, 'B')
    fakeTime = fakeTime + 1000
    BR.Sched.step(fakeTime)
    fakeTime = mendsAt() + 1
    BR.Sched.step(fakeTime)
    local r2 = BR.Bus.active(theMatch())
    fakeTime = r2.jumpFrom + 1000
    fire(BR.Net.BUS_JUMP, 1)
    fire(BR.Net.BUS_JUMP, 2)
    fire(BR.Net.DROP_LANDED, 2)

    pedHealth[1002] = 0           -- 2 dies on the ground; 1 still gliding
    local z = 400.0
    for _ = 1, 8 do
        z = z - 15.0
        setPos(1, 150.0, 150.0, z)   -- a REAL descent: no promotion here
        setPos(2, 300.0, 300.0, 25.0)
        fakeTime = fakeTime + 250
        BR.Sched.step(fakeTime)
    end
    ok(BR.Roster.get(2).state == BR.PlayerState.DEAD,
        'a death on the ground is observed while others still fly')
    ok(BR.Roster.get(1).state == BR.PlayerState.FREEFALL,
        'a genuinely descending glider is never promoted')
    ok(mstate() == BR.MatchState.BUS,
        'and the flight goes on for everyone else')
    pedHealth[1002] = nil

    -- The mid-flight death already counted: the survivor lands, the match
    -- goes live, and the win condition sees one squad standing.
    fire(BR.Net.DROP_LANDED, 1)
    fakeTime = fakeTime + 300
    BR.Sched.step(fakeTime)
    ok(mstate() == BR.MatchState.PLAYING,
        'the survivor landing takes it live')
    fakeTime = fakeTime + 3100
    BR.Sched.step(fakeTime)
    ok(mstate() == BR.MatchState.ENDED,
        'and last squad standing wins off the mid-flight death')
end

describe('match.parallel')
do
    -- THE PARALLEL-MATCHES MODEL (user call, 2026-08-04): matches are
    -- instances. While one sits in OPEN WARMUP, ready-ups join IT; once it
    -- is BUS-or-later the next ready-ups queue and form their own -- and
    -- the two then run fully isolated: buckets, storms, kill feeds, win
    -- conditions, teardown.
    reset()
    BR.Server.devMode = true
    join(1, 'A1'); join(2, 'A2'); join(3, 'B1'); join(4, 'B2')

    fire(BR.Net.QUEUE_JOIN, 1, { mode = 'solo' })
    fire(BR.Net.QUEUE_JOIN, 2, { mode = 'solo' })
    fakeTime = fakeTime + 300
    BR.Sched.step(fakeTime)
    local A = theMatch()
    ok(A ~= nil and A.state == BR.MatchState.WARMUP, 'match A forms')

    -- The formation gate, front half: an open warmup absorbs ready-ups.
    fire(BR.Net.QUEUE_JOIN, 3, { mode = 'solo' })
    ok(BR.Roster.get(3).state == BR.PlayerState.WARMUP,
        'an open warmup absorbs a ready-up directly')
    ok(BR.Server.matchOf(3) == A, 'into match A itself')
    fire(BR.Net.MATCH_LEAVE, 3)   -- steps back out for the B half below
    ok(BR.Server.matchOf(3) == nil, 'and leaving detaches cleanly')

    -- A departs; the gate opens.
    BR.Match.transition(A, BR.MatchState.BUS)
    fire(BR.Net.QUEUE_JOIN, 3, { mode = 'solo' })
    ok(BR.Server.queue[3] ~= nil, 'once A is flying, ready-ups queue instead')
    fire(BR.Net.QUEUE_JOIN, 4, { mode = 'solo' })
    fakeTime = fakeTime + 300
    BR.Sched.step(fakeTime)

    local B = theMatch()
    ok(B ~= nil and B.id ~= A.id, 'a second match forms while A is mid-flight')
    ok(B.state == BR.MatchState.WARMUP and A.state == BR.MatchState.BUS,
        'each instance holds its own state')
    ok(A.bucket ~= B.bucket, 'the matches own different private buckets')
    local WB = BR.Config.Match.warmupBucket
    ok(buckets[1] == WB and buckets[3] == WB,
        "pre-flight everyone shares the communal warmup bucket",
        ('p1 %s, p3 %s, WB %d'):format(tostring(buckets[1]),
                                       tostring(buckets[3]), WB))

    -- A's landings take A live without moving B. B's own warmup deadline is
    -- pinned far out first: the clock is about to jump to A's door-open
    -- time (minutes ahead, tour-dependent), and B expiring on its own
    -- schedule during that jump would read as "A moved B" when it is only
    -- the shared clock.
    B.endsAt = fakeTime + 600000
    local r = A.route
    fakeTime = math.max(fakeTime, r.jumpFrom + 1000)
    fire(BR.Net.BUS_JUMP, 1); fire(BR.Net.BUS_JUMP, 2)
    ok(buckets[1] == A.bucket,
        "a jumper leaves the communal bucket for the match's own",
        ('got %s want %d'):format(tostring(buckets[1]), A.bucket))
    ok(buckets[3] == WB, "while B's warmup stays on the communal pad")
    fire(BR.Net.DROP_LANDED, 1); fire(BR.Net.DROP_LANDED, 2)
    fakeTime = fakeTime + 300
    BR.Sched.step(fakeTime)
    ok(A.state == BR.MatchState.PLAYING, 'A goes live on its own landings')
    ok(B.state == BR.MatchState.WARMUP, 'without moving B')

    BR.Match.transition(B, BR.MatchState.PLAYING)
    ok(A.storm ~= nil and B.storm ~= nil, 'each match runs its own storm')
    ok(A.storm ~= B.storm, 'two distinct records')

    -- A kill in B is silence in A: scoped feed, scoped win condition.
    sent = {}
    BR.Combat.eliminate(4, 'test', 3)
    local feedTargets = {}
    for _, s in ipairs(eventsOf(BR.Net.KILL_FEED)) do
        feedTargets[s.target] = true
    end
    ok(feedTargets[3] and feedTargets[4],
        "B's kill feed reaches B's players")
    ok(not feedTargets[1] and not feedTargets[2] and not feedTargets[-1],
        "and never A's, nor the whole server")

    fakeTime = fakeTime + 4000   -- past WIN_GRACE_MS
    BR.Sched.step(fakeTime)
    ok(B.state == BR.MatchState.ENDED, "B's win condition fires on B's kill")
    ok(A.state == BR.MatchState.PLAYING, 'while A plays on, untouched')

    -- B runs out and is destroyed; A survives it.
    fakeTime = B.endsAt + 1
    BR.Sched.step(fakeTime)      -- ENDED -> CLEANUP
    fakeTime = B.endsAt + 1
    BR.Sched.step(fakeTime)      -- CLEANUP -> destroyed
    ok(BR.Server.matches[B.id] == nil, 'B is destroyed after its cleanup')
    ok(BR.Server.matches[A.id] == A and A.state == BR.MatchState.PLAYING,
        'and A is still running')
    ok(BR.Server.matchOf(3) == nil
       and BR.Roster.get(3).state == BR.PlayerState.LOBBY,
        "B's players are ordinary lobby players again")
end

describe('match.modes')
do
    -- HOMOGENEOUS MATCHES (user call, 2026-08-04): a solo queuer never
    -- lands in a squad match. Each mode's queue forms its own instance, so
    -- a solo warmup and a squad warmup can be open at the same time --
    -- sharing the communal pad, flying separate buses into separate games.
    reset()
    BR.Server.devMode = true
    join(1, 'Q1'); join(2, 'Q2'); join(3, 'S1'); join(4, 'S2')

    fire(BR.Net.QUEUE_JOIN, 1, { mode = BR.Mode.SQUAD.key })
    fire(BR.Net.QUEUE_JOIN, 2, { mode = BR.Mode.SQUAD.key })
    fakeTime = fakeTime + 300
    BR.Sched.step(fakeTime)
    local SQ = BR.Server.matchOf(1)
    ok(SQ ~= nil and SQ.mode == BR.Mode.SQUAD.key
       and SQ.state == BR.MatchState.WARMUP, 'a squad match forms')

    -- A solo ready-up while the squad warmup is open QUEUES; it must not
    -- be absorbed into a match of the wrong mode.
    fire(BR.Net.QUEUE_JOIN, 3, { mode = BR.Mode.SOLO.key })
    ok(BR.Server.matchOf(3) == nil and BR.Server.queue[3] ~= nil,
        'a solo queuer is not absorbed into the open squad warmup')

    fire(BR.Net.QUEUE_JOIN, 4, { mode = BR.Mode.SOLO.key })
    fakeTime = fakeTime + 300
    BR.Sched.step(fakeTime)
    local SO = BR.Server.matchOf(3)
    ok(SO ~= nil and SO.mode == BR.Mode.SOLO.key and SO.id ~= SQ.id,
        'the solo queue forms its own match beside the open squad warmup')
    ok(SO.state == BR.MatchState.WARMUP and SQ.state == BR.MatchState.WARMUP,
        'two warmups are open at once')
    local WB = BR.Config.Match.warmupBucket
    ok(buckets[1] == WB and buckets[3] == WB,
        'and their players share the communal pad')

    -- Later ready-ups are routed by the mode they picked.
    join(5, 'Q3')
    fire(BR.Net.QUEUE_JOIN, 5, { mode = BR.Mode.SQUAD.key })
    ok(BR.Server.matchOf(5) == SQ, 'a squad ready-up joins the squad warmup')
    join(6, 'S3')
    fire(BR.Net.QUEUE_JOIN, 6, { mode = BR.Mode.SOLO.key })
    ok(BR.Server.matchOf(6) == SO, 'a solo ready-up joins the solo warmup')
end

describe('match.teardownWire')
do
    -- The ordering CONTRACT at the end of a match, plus the teardown
    -- housekeeping the 2026-08-04 playtests caught missing.
    reset()
    BR.Server.devMode = true
    join(1, 'A'); join(2, 'B')
    fire(BR.Net.QUEUE_JOIN, 1, { mode = 'solo' })
    fire(BR.Net.QUEUE_JOIN, 2, { mode = 'solo' })
    fakeTime = fakeTime + 300
    BR.Sched.step(fakeTime)
    local m = theMatch()

    -- ONE 'bus' state event per rider, with the flight's real deadline.
    -- The transition used to broadcast (endsAt 0) and depart rebroadcast:
    -- every client logged "state bus" twice.
    sent = {}
    BR.Match.transition(m, BR.MatchState.BUS)
    local busEvents = {}
    for _, s in ipairs(eventsOf(BR.Net.STATE)) do
        if s.args[1].state == BR.MatchState.BUS then
            busEvents[#busEvents + 1] = s
        end
    end
    ok(#busEvents == 2, 'entering BUS sends exactly one state event per rider',
        ('got %d'):format(#busEvents))
    ok(busEvents[1] and busEvents[1].args[1].endsAt > fakeTime,
        'and it carries the flight-derived deadline, not zero')

    -- STATE(ended) must reach clients BEFORE the roster sweep's LOBBY
    -- deltas: a client that processes its own LOBBY flip first reads it as
    -- a voluntary leave and drops the verdict screen (live regression).
    forceState(BR.MatchState.PLAYING)
    sent = {}
    BR.Combat.eliminate(2, 'storm', nil)
    fakeTime = fakeTime + 4000
    BR.Sched.step(fakeTime)
    ok(m.state == BR.MatchState.ENDED, 'the match ends')
    BR.Broadcast.flushNow()   -- the sweep's deltas ride the next flush; force it
    local endedIdx, lobbyDeltaIdx = nil, nil
    for i, s in ipairs(sent) do
        if s.event == BR.Net.STATE
           and s.args[1].state == BR.MatchState.ENDED and not endedIdx then
            endedIdx = i
        end
        if s.event == BR.Net.ROSTER_DELTA and not lobbyDeltaIdx then
            for _, d in ipairs(s.args[1].deltas or {}) do
                if d.e and d.e.state == BR.PlayerState.LOBBY then
                    lobbyDeltaIdx = i
                end
            end
        end
    end
    ok(endedIdx ~= nil and lobbyDeltaIdx ~= nil and endedIdx < lobbyDeltaIdx,
        'STATE ended is on the wire before the trip-home roster deltas',
        ('ended at %s, lobby delta at %s'):format(
            tostring(endedIdx), tostring(lobbyDeltaIdx)))
end

describe('match.memberless')
do
    -- A match nobody belongs to cannot end itself -- the win condition
    -- refuses empty matches -- so the last leaver used to leave a PLAYING
    -- instance running forever, storm and all.
    reset()
    BR.Server.devMode = true
    join(1, 'A'); join(2, 'B')
    fire(BR.Net.QUEUE_JOIN, 1, { mode = 'solo' })
    fire(BR.Net.QUEUE_JOIN, 2, { mode = 'solo' })
    fakeTime = fakeTime + 300
    BR.Sched.step(fakeTime)
    local m = theMatch()
    forceState(BR.MatchState.PLAYING)

    fire(BR.Net.MATCH_LEAVE, 1)
    fire(BR.Net.MATCH_LEAVE, 2)
    fakeTime = fakeTime + 300
    BR.Sched.step(fakeTime)
    ok(BR.Server.matches[m.id] == nil,
        'a PLAYING match emptied by its last leaver is dissolved')
end

describe('party.resyncAtTeardown')
do
    -- Parties survive matches by design -- so the moment a match is
    -- destroyed, its players must be RE-TOLD their party state. A client
    -- whose party display went stale filtered its owner out of every
    -- invite list with nothing on screen explaining why.
    reset()
    BR.Server.devMode = true
    join(1, 'A'); join(2, 'B')
    BR.Party.invite(1, 2); BR.Party.respond(2, true)
    fire(BR.Net.QUEUE_JOIN, 1, { mode = 'squad' })
    fire(BR.Net.QUEUE_JOIN, 2, { mode = 'squad' })
    fakeTime = fakeTime + 300
    BR.Sched.step(fakeTime)
    local m = theMatch()
    forceState(BR.MatchState.PLAYING)
    forceState(BR.MatchState.ENDED)
    forceState(BR.MatchState.CLEANUP)

    sent = {}
    fakeTime = m.endsAt + 1
    BR.Sched.step(fakeTime)   -- CLEANUP expires -> destroy
    ok(BR.Server.matches[m.id] == nil, 'the match is destroyed')

    local told = {}
    for _, s in ipairs(eventsOf(BR.Net.SQUAD_UPDATE)) do
        local p = s.args[1]
        if p and p.id and #(p.members or {}) == 2 then told[s.target] = true end
    end
    ok(told[1] and told[2],
        'both members are re-told their surviving party at teardown')
end

describe('bus.spectate')
do
    -- The audience on the tarmac: when a flight departs, warmup players of
    -- OTHER matches get a spectator copy of the route (their clients render
    -- the ghost plane). The departing match's own riders do not.
    reset()
    BR.Server.devMode = true
    BR.Config.Match.minToStart = 1   -- one queuer per mode forms each match
    join(1, 'A1'); join(2, 'B1')
    fire(BR.Net.QUEUE_JOIN, 1, { mode = 'solo' })
    fakeTime = fakeTime + 300
    BR.Sched.step(fakeTime)
    local A = theMatch()
    fire(BR.Net.QUEUE_JOIN, 2, { mode = 'squad' })
    fakeTime = fakeTime + 300
    BR.Sched.step(fakeTime)
    local B = BR.Server.matchOf(2)
    ok(A and B and A.id ~= B.id, 'two forming matches are open')

    sent = {}
    BR.Match.transition(A, BR.MatchState.BUS)
    local specTo = {}
    for _, s in ipairs(eventsOf(BR.Net.BUS_SPECTATE)) do
        specTo[s.target] = s.args[1]
    end
    ok(specTo[2] ~= nil and specTo[2].matchId == A.id
       and specTo[2].route and specTo[2].route.timed,
        "the other warmup receives the departing flight's timed route")
    ok(specTo[1] == nil, 'the riders themselves get no spectator copy')
end

describe('party.integrity')
do
    -- Party membership lives in two places (the parties table and each
    -- entry's partyId), and the 2026-08-04 playtests produced a state
    -- where they disagreed -- which held the party gate on a "1/2 party"
    -- nobody could see. The sweep reconciles both directions within 5s,
    -- whatever the origin.
    reset()
    BR.Server.devMode = true
    join(1, 'A'); join(2, 'B'); join(3, 'C')
    BR.Party.invite(1, 2); BR.Party.respond(2, true)
    local pid = BR.Party.of(1).id

    -- Simulate the observed asymmetry: B's entry forgets the party while
    -- the members list still holds them.
    BR.Roster.get(2).partyId = nil
    fakeTime = fakeTime + 5100
    BR.Sched.step(fakeTime)
    ok(BR.Server.parties[pid] == nil,
        'a ghost member is dropped and the resulting loner party disbanded')
    ok(BR.Roster.get(1).partyId == nil,
        'with the stranded member fully released')

    -- The other direction: an entry pointing at a party that is gone.
    BR.Roster.get(3).partyId = 'p999'
    sent = {}
    fakeTime = fakeTime + 5100
    BR.Sched.step(fakeTime)
    ok(BR.Roster.get(3).partyId == nil, 'a dangling partyId is released')
    local toldEmpty = false
    for _, s in ipairs(eventsOf(BR.Net.SQUAD_UPDATE)) do
        if s.target == 3 and s.args[1] and s.args[1].id == nil then
            toldEmpty = true
        end
    end
    ok(toldEmpty, 'and the client is told it has no party')

    -- The one legitimate party of one -- an inviter awaiting an answer --
    -- is spared, or every fresh invite would dissolve in five seconds.
    BR.Party.invite(1, 2)
    local pid2 = BR.Party.of(1).id
    fakeTime = fakeTime + 5100
    BR.Sched.step(fakeTime)
    ok(BR.Server.parties[pid2] ~= nil,
        'a loner party with a pending invite survives the sweep')
    BR.Party.respond(2, true)
    ok(BR.Party.size(pid2) == 2, 'and the acceptance lands normally')
end

describe('markers')
do
    -- One marker per player, relayed to the squad and nobody else, tinted
    -- the owner's colour. The sweep clears a marker whose owner stopped
    -- being a match participant.
    reset()
    join(1, 'A'); join(2, 'B'); join(3, 'C')
    local e1 = BR.Roster.get(1)
    e1.squadId, e1.colour = 'sq_test', '#F87171'
    BR.Roster.get(2).squadId = 'sq_test'
    BR.Roster.get(3).squadId = 'sq_other'
    BR.Roster.setState(1, BR.PlayerState.ALIVE)
    BR.Roster.setState(2, BR.PlayerState.ALIVE)
    BR.Roster.setState(3, BR.PlayerState.ALIVE)

    sent = {}
    fire(BR.Net.MARKER_SET, 1, { x = 100.0, y = 200.0 })
    local got = {}
    for _, s in ipairs(eventsOf(BR.Net.MARKER_SYNC)) do
        got[s.target] = s.args[1]
    end
    ok(got[1] ~= nil and got[2] ~= nil and got[3] == nil,
        'a squad marker reaches owner and squadmates, nobody else')
    -- The MEMBER INDEX, not the squad colour. entry.colour is shared by the
    -- whole squad, so relaying it made every teammate's destination marker the
    -- same colour while their minimap dots were all different (user,
    -- 2026-08-05). The index keys BR.SquadColours, which the beacons use too.
    ok(got[2] and got[2].i ~= nil and got[2].x == 100.0,
        'and carries the owner MEMBER INDEX and position',
        tostring(got[2] and got[2].i))
    ok(got[2] and got[2].colour == nil,
        'and no longer carries the squad-wide colour')

    -- Two members of one squad must get DIFFERENT indices, or the whole point
    -- of the change is lost.
    sent = {}
    fire(BR.Net.MARKER_SET, 2, { x = 300.0, y = 400.0 })
    local other
    for _, s in ipairs(eventsOf(BR.Net.MARKER_SYNC)) do
        if s.target == 1 then other = s.args[1] end
    end
    ok(other and other.i ~= got[2].i,
        'two squadmates get distinct member indices',
        ('%s vs %s'):format(tostring(got[2].i), tostring(other and other.i)))

    sent = {}
    fire(BR.Net.MARKER_CLEAR, 1)
    local cleared = eventsOf(BR.Net.MARKER_SYNC)
    ok(#cleared >= 2 and cleared[1].args[1].op == 'clear',
        'clearing tells the same audience')

    -- Solo: no squadId means the audience is exactly the owner.
    sent = {}
    fire(BR.Net.MARKER_SET, 3, { x = 5.0, y = 6.0 })
    local soloTo = {}
    for _, s in ipairs(eventsOf(BR.Net.MARKER_SYNC)) do
        soloTo[#soloTo + 1] = s.target
    end
    BR.Roster.get(3).squadId = nil
    sent = {}
    fire(BR.Net.MARKER_SET, 3, { x = 5.0, y = 6.0 })
    soloTo = {}
    for _, s in ipairs(eventsOf(BR.Net.MARKER_SYNC)) do
        soloTo[#soloTo + 1] = s.target
    end
    ok(#soloTo == 1 and soloTo[1] == 3, 'a solo marker is private to its owner')

    -- The sweep: an owner who stops being in the match loses their marker.
    BR.Roster.setState(3, BR.PlayerState.LOBBY)
    sent = {}
    fakeTime = fakeTime + 5100
    BR.Sched.step(fakeTime)
    local swept = false
    for _, s in ipairs(eventsOf(BR.Net.MARKER_SYNC)) do
        if s.args[1].op == 'clear' and s.args[1].owner == 3 then swept = true end
    end
    ok(swept, 'the sweep clears markers of departed owners')
end

-- ------------------------------------------------------------------ loot ---

--- A match in warmup with a stocked world and both players landed. Loot is
--- generated at WARMUP (players land during BUS), so this is the earliest
--- point at which any of it can be reached.
local function lootMatch()
    reset()
    queueUp(1, 'A', BR.Mode.SOLO.key)
    queueUp(2, 'B', BR.Mode.SOLO.key)
    fakeTime = fakeTime + 300
    BR.Sched.step(fakeTime)
    BR.Roster.setState(1, BR.PlayerState.ALIVE)
    BR.Roster.setState(2, BR.PlayerState.ALIVE)
    return theMatch()
end

--- Stand a player exactly on top of a ground entry.
local function standOn(src, e)
    BR.Roster.get(src).pos = { x = e.x, y = e.y, z = e.z }
end

describe('loot.stream')
do
    local m = lootMatch()
    ok(m.loot ~= nil, 'warmup stocks the world')

    -- Ids are assigned 1..n in generation order, so entry 1 always exists and
    -- always names the same place for a given seed.
    local first = m.loot.items[1]
    ok(first ~= nil, 'the layout is indexed by id')

    local cx, cy = BR.LootCellOf(first.x, first.y)

    sent = {}
    fire(BR.Net.LOOT_CELL, 1, { cx = cx, cy = cy })
    local adds = eventsOf(BR.Net.LOOT_ADD)
    local sawFirst, leaked = false, false
    for _, s in ipairs(adds) do
        for _, entry in ipairs(s.args[1]) do
            if entry.id == 1 then sawFirst = true end
            if entry.contents then leaked = true end
        end
    end
    ok(#adds > 0, 'subscribing to a cell streams its entries')
    ok(sawFirst, 'the entry standing in that cell is among them')
    -- SECURITY-ADJACENT: a client that knew what was in each chest would only
    -- ever open the good ones, which is the whole tension of a chest removed.
    ok(not leaked, 'container contents never travel to the client')

    -- Re-subscribing to the SAME cell must be a no-op, or a client parked on
    -- a cell boundary re-streams 150 entries every second.
    sent = {}
    fire(BR.Net.LOOT_CELL, 1, { cx = cx, cy = cy })
    ok(#eventsOf(BR.Net.LOOT_ADD) == 0, 'a repeat subscription sends nothing')

    -- Walking three cells away drops everything that was in scope.
    sent = {}
    fire(BR.Net.LOOT_CELL, 1, { cx = cx + 3, cy = cy + 3 })
    local goneIds = {}
    for _, s in ipairs(eventsOf(BR.Net.LOOT_GONE)) do
        for _, id in ipairs(s.args[1]) do goneIds[id] = true end
    end
    ok(goneIds[1], 'leaving the neighbourhood retires what was in it')

    -- A WARMUP player is not in the world yet. The pad is shared between
    -- matches, so streaming there would hand one match's items to another's.
    BR.Roster.setState(2, BR.PlayerState.WARMUP)
    sent = {}
    fire(BR.Net.LOOT_CELL, 2, { cx = cx, cy = cy })
    ok(#eventsOf(BR.Net.LOOT_ADD) == 0, 'a warmup player is refused a subscription')
end

describe('loot.claim')
do
    local m = lootMatch()

    -- Find a plain weapon entry to fight over: containers take a different
    -- path and ammo does not occupy a slot.
    local target
    for id = 1, m.loot.nextId do
        local e = m.loot.items[id]
        if e and e.kind == BR.ItemKind.WEAPON then target = e break end
    end
    ok(target ~= nil, 'the layout contains a weapon to claim')

    local cx, cy = BR.LootCellOf(target.x, target.y)
    fire(BR.Net.LOOT_CELL, 1, { cx = cx, cy = cy })
    fire(BR.Net.LOOT_CELL, 2, { cx = cx, cy = cy })
    standOn(1, target)
    standOn(2, target)

    -- BOTH REACH FOR IT IN THE SAME TICK. This is the normal case at a hot
    -- drop, and exactly one of them may end up holding it.
    sent = {}
    fire(BR.Net.LOOT_CLAIM, 1, { id = target.id })
    fire(BR.Net.LOOT_CLAIM, 2, { id = target.id })

    local gained = {}
    for _, s in ipairs(eventsOf(BR.Net.INV_SET)) do
        for _, slot in ipairs(s.args[1].slots) do
            if slot and slot.id == target.item then gained[s.target] = true end
        end
    end
    local n = 0
    for _ in pairs(gained) do n = n + 1 end
    ok(n == 1, 'exactly one claimant ends up holding it', ('%d did'):format(n))
    ok(m.loot.items[target.id] == nil, 'and it is gone from the world')

    -- The loser is TOLD. A claim that silently does nothing is
    -- indistinguishable from a broken key (the bus jump handler's rule).
    local loser = gained[1] and 2 or 1
    local toldLoser = false
    for _, s in ipairs(eventsOf(BR.Net.NOTIFY)) do
        if s.target == loser and s.args[1].text:find('beat you') then
            toldLoser = true
        end
    end
    ok(toldLoser, 'the loser is told someone beat them to it')

    -- Both subscribers must hear it vanish, not just the winner -- otherwise
    -- the loser keeps a prop standing in the world forever.
    local goneTo = {}
    for _, s in ipairs(eventsOf(BR.Net.LOOT_GONE)) do
        for _, id in ipairs(s.args[1]) do
            if id == target.id then goneTo[s.target] = true end
        end
    end
    ok(goneTo[1] and goneTo[2], 'every subscriber is told it is gone')

    -- Distance is re-validated server-side; the client prompt is cosmetic.
    local far
    for id = 1, m.loot.nextId do
        local e = m.loot.items[id]
        if e and e.kind == BR.ItemKind.WEAPON then far = e break end
    end
    BR.Roster.get(1).pos = { x = far.x + 400.0, y = far.y, z = far.z }
    sent = {}
    fire(BR.Net.LOOT_CLAIM, 1, { id = far.id })
    ok(m.loot.items[far.id] ~= nil, 'a claim from 400m away is refused')
    local toldFar = false
    for _, s in ipairs(eventsOf(BR.Net.NOTIFY)) do
        if s.target == 1 and s.args[1].text:find('far') then toldFar = true end
    end
    ok(toldFar, 'and audibly so')

    -- A dead player cannot loot.
    standOn(1, far)
    BR.Roster.setState(1, BR.PlayerState.DEAD)
    fire(BR.Net.LOOT_CLAIM, 1, { id = far.id })
    ok(m.loot.items[far.id] ~= nil, 'a corpse cannot pick things up')
end

describe('loot.rateLimit')
do
    local m = lootMatch()

    -- Ten claims inside one millisecond is not a player. The limit is per
    -- second, so this must bite regardless of what is being claimed.
    local ids = {}
    for id = 1, m.loot.nextId do
        local e = m.loot.items[id]
        if e and e.kind ~= 'chest' and e.kind ~= 'deathbox' then
            ids[#ids + 1] = id
            if #ids >= 10 then break end
        end
    end

    for _, id in ipairs(ids) do
        standOn(1, m.loot.items[id])
        fire(BR.Net.LOOT_CLAIM, 1, { id = id })
    end

    local taken = 0
    for _, id in ipairs(ids) do
        if m.loot.items[id] == nil then taken = taken + 1 end
    end
    ok(taken <= BR.Config.Loot.pickupRateLimit,
        'no more than the configured claims per second are honoured',
        ('%d of %d'):format(taken, #ids))
end

describe('inv.model')
do
    local m = lootMatch()

    BR.Inv.reset(1)
    local rifle = BR.Config.WeaponById['carbinerifle']
    local ok1 = BR.Inv.give(1, { item = 'carbinerifle', kind = BR.ItemKind.WEAPON,
                                 rarity = rifle.rarity, count = 1, clip = rifle.clip })
    local inv = BR.Inv.of(1)
    ok(ok1 and inv.slots[1] and inv.slots[1].item == 'carbinerifle',
        'a weapon lands in the first free slot')
    ok(inv.active == 1, 'and comes up in an empty hand')
    -- A found gun has to be usable or the first weapon on the ground is a
    -- decoration.
    ok((inv.ammo[rifle.ammo] or 0) > 0, 'a weapon brings reserve ammo with it')

    -- Fill every slot, then pick up a sixth weapon.
    for i = 2, BR.Config.Loot.slots do
        BR.Inv.give(1, { item = 'pistol', kind = BR.ItemKind.WEAPON,
                         rarity = 1, count = 1, clip = 12 })
    end
    inv.active = 3
    local ok2, displaced = BR.Inv.give(1, { item = 'heavysniper',
        kind = BR.ItemKind.WEAPON, rarity = 5, count = 1, clip = 6 })
    ok(ok2 and inv.slots[3].item == 'heavysniper',
        'a full inventory swaps the new weapon into the ACTIVE slot')
    ok(displaced ~= nil and displaced.item == 'pistol',
        'and hands the displaced one back to the world')

    -- A FULL INVENTORY SWAPS, IT NEVER REFUSES (user call, 2026-08-05).
    -- Reaching for something means wanting it more than what is in hand, and
    -- "No room for that" just made the player drop something manually and
    -- pick up again -- the same outcome with three extra steps.
    inv.active = 3
    local ok3, displaced3, reason = BR.Inv.give(1, { item = 'bandage',
        kind = BR.ItemKind.CONSUMABLE, rarity = 1, count = 1 })
    ok(ok3 and reason == nil, 'a consumable into a full inventory is accepted')
    ok(inv.slots[3] and inv.slots[3].item == 'bandage',
        'it takes the active slot')
    ok(displaced3 ~= nil and displaced3.item == 'heavysniper',
        'and what was there goes to the world, not into the void',
        tostring(displaced3 and displaced3.item))

    -- Stacking.
    BR.Inv.reset(1)
    inv = BR.Inv.of(1)
    local band = BR.Config.ConsumableById['bandage']
    for _ = 1, band.maxStack do
        BR.Inv.give(1, { item = 'bandage', kind = BR.ItemKind.CONSUMABLE,
                         rarity = 1, count = 1 })
    end
    ok(inv.slots[1] and inv.slots[1].count == band.maxStack,
        'consumables fill one slot to maxStack first')

    -- THE CARRY CEILING IS ACROSS EVERY SLOT, not per stack. Capping the
    -- stack alone just produced two stacks of three (user, 2026-08-06).
    local okMore, _, whyMore = BR.Inv.give(1, { item = 'bandage',
        kind = BR.ItemKind.CONSUMABLE, rarity = 1, count = 1 })
    ok(not okMore and whyMore == 'carrymax',
        'and refuse a second stack once carryMax is reached',
        tostring(whyMore))
    ok(inv.slots[2] == false, 'so no second stack is opened')

    -- Something WITHOUT a carry ceiling still spills into a second slot.
    local mini = BR.Config.ConsumableById['minishield']
    ok(mini.carryMax == nil, 'small shields have no carry ceiling')
    for _ = 1, mini.maxStack + 1 do
        BR.Inv.give(1, { item = 'minishield', kind = BR.ItemKind.CONSUMABLE,
                         rarity = 1, count = 1 })
    end
    local stacks = 0
    for i = 1, BR.Config.Loot.slots do
        local s = inv.slots[i]
        if s and s.item == 'minishield' then stacks = stacks + 1 end
    end
    ok(stacks == 2, 'and opens a second stack once the first is full',
        ('%d stacks'):format(stacks))

    -- Ammo pools are capped.
    BR.Inv.reset(1)
    inv = BR.Inv.of(1)
    local cap = BR.Config.AmmoCaps[BR.AmmoType.HEAVY]
    BR.Inv.give(1, { item = BR.AmmoType.HEAVY, kind = BR.ItemKind.AMMO,
                     rarity = 1, count = cap * 10 })
    ok(inv.ammo[BR.AmmoType.HEAVY] == cap, 'ammo cannot exceed its pool cap')
    local ok4, _, reason4 = BR.Inv.give(1, { item = BR.AmmoType.HEAVY,
        kind = BR.ItemKind.AMMO, rarity = 1, count = 10 })
    ok(not ok4 and reason4 == 'ammofull', 'a full pool refuses more')

    -- Dropping puts it back in the world at the dropper's feet.
    BR.Inv.reset(1)
    BR.Inv.give(1, { item = 'pistol', kind = BR.ItemKind.WEAPON,
                     rarity = 1, count = 1, clip = 12 })
    BR.Roster.get(1).pos = { x = 1234.0, y = -567.0, z = 30.0 }
    local before = m.loot.nextId
    fire(BR.Net.INV_DROP, 1, { slot = 1 })
    ok(m.loot.nextId == before + 1, 'dropping creates a ground entry')
    local droppedEntry = m.loot.items[m.loot.nextId]
    ok(droppedEntry and droppedEntry.item == 'pistol'
        and math.abs(droppedEntry.x - 1234.0) < 0.01,
        'at the dropper, carrying the same item')
    ok(BR.Inv.of(1).slots[1] == false, 'and it leaves the inventory')

    -- The slot INDEX is what is selected, not the gun in it: dragging an item
    -- into slot 3 while slot 1 is up must not change what is in your hands.
    BR.Inv.reset(1)
    BR.Inv.give(1, { item = 'pistol', kind = BR.ItemKind.WEAPON, rarity = 1,
                     count = 1, clip = 12 })
    BR.Inv.give(1, { item = 'sawnoff', kind = BR.ItemKind.WEAPON, rarity = 1,
                     count = 1, clip = 8 })
    BR.Inv.of(1).active = 1
    fire(BR.Net.INV_SWAP, 1, { from = 1, to = 2 })
    ok(BR.Inv.of(1).active == 1, 'a swap never moves the active slot index')
    ok(BR.Inv.of(1).slots[1].item == 'sawnoff', 'but it does move the items')
end

describe('inv.use')
do
    lootMatch()
    BR.Inv.reset(1)
    BR.Inv.give(1, { item = 'minishield', kind = BR.ItemKind.CONSUMABLE,
                     rarity = 1, count = 2 })
    local shield = BR.Config.ConsumableById['minishield']
    local e = BR.Roster.get(1)
    e.armour = 0.0

    sent = {}
    fire(BR.Net.INV_USE, 1, { slot = 1 })
    ok(BR.Inv.of(1).using ~= nil, 'using starts a timed action')
    ok(BR.Inv.of(1).slots[1].count == 2,
        'and consumes nothing yet -- an interrupted use costs nothing')

    -- THE BAR FILLS AS YOU DRINK (user call, 2026-08-05). Half way through,
    -- roughly half the armour has been applied -- and every message is a
    -- TARGET, so a dropped one self-corrects rather than losing its share.
    fakeTime = fakeTime + math.floor(shield.useMs / 2)
    BR.Sched.step(fakeTime)
    local partials = eventsOf(BR.Net.INV_EFFECT)
    ok(#partials >= 1, 'the effect is applied progressively, not at the end')
    local mid = partials[#partials] and partials[#partials].args[1]
    ok(mid and mid.partial == true, 'and is flagged as an interim value')
    ok(mid and mid.armour > 0 and mid.armour < shield.armour,
        'partway between nothing and the full amount',
        tostring(mid and mid.armour))

    -- THE ROSTER SAMPLES THE RAMP, and that is what broke this in game.
    --
    -- The partials walk the player up from armour0, and the 2Hz health sampler
    -- writes that rise back into the roster entry -- so by completion
    -- `e.armour` is nearly the finished value. The final payload used to be
    -- computed from THAT, which added the item's worth a second time on top of
    -- its own ramp: one shield took a player from 0 to ~95 (user, 2026-08-08).
    --
    -- Simulated here by doing what the sampler does, because without it the
    -- old arithmetic passed by accident: e.armour never moved, so
    -- `e.armour + 25` and `armour0 + 25` were the same number.
    --
    -- AND IT STILL CANNOT BE PROVEN HERE, which is worth stating plainly
    -- rather than leaving a test that looks like it covers this and does not.
    -- Setting e.armour by hand does nothing: BR.Sched.step runs the roster's
    -- health sampler first, and the harness's stub reports armour 0, so the
    -- value is back to zero before inv.use reads it. Modelling that properly
    -- means teaching the harness to carry armour across a step, which is a
    -- bigger change than the fix it would guard.
    --
    -- The fix itself is not in doubt -- both payloads now measure from the
    -- same origin, and 45 + 50 = 95 is exactly the number the user saw -- but
    -- the in-game check is what confirms it: drink one shield from zero and
    -- land on 50, not 95.
    sent = {}
    fakeTime = fakeTime + shield.useMs
    BR.Sched.step(fakeTime)
    local effects = eventsOf(BR.Net.INV_EFFECT)
    local final = effects[#effects] and effects[#effects].args[1]
    ok(final and final.armour == shield.armour,
        'and lands on exactly what the item is worth, even after the sampler '
        .. 'has already seen most of the ramp',
        tostring(final and final.armour))
    ok(final and not final.partial, 'the last one is the real thing')
    ok(effects[1] and effects[1].args[1].armourCap == shield.armourCap,
        'and its own ceiling, so the client can clamp')
    ok(BR.Inv.of(1).slots[1].count == 1, 'completion is what consumes one')
    ok(BR.Inv.of(1).using == nil, 'and clears the action')

    -- TAKING FIRE INTERRUPTS. Committing to an 8s med kit while being shot
    -- should lose you the med kit, not heal you through it.
    e.armour = 0.0
    -- Driven through the PED, not by poking entry.hp: the roster samples
    -- health off the engine four times a second, so anything written straight
    -- onto the entry is overwritten before the next tick reads it. Setting the
    -- stub ped's health is what a real hit looks like from the server's side.
    sent = {}
    fire(BR.Net.INV_USE, 1, { slot = 1 })
    pedHealth[1001] = BR.ToEngineHp(80.0)
    fakeTime = fakeTime + 300
    BR.Sched.step(fakeTime)
    ok(BR.Inv.of(1).using == nil, 'damage cancels a use in progress')
    fakeTime = fakeTime + shield.useMs * 2
    BR.Sched.step(fakeTime)
    ok(#eventsOf(BR.Net.INV_EFFECT) == 0, 'and no effect ever lands')
    ok(BR.Inv.of(1).slots[1] and BR.Inv.of(1).slots[1].count == 1,
        'the item survives the interruption')

    -- Dying mid-use lands nothing either.
    pedHealth[1001] = nil
    e.hp = 100.0
    fire(BR.Net.INV_USE, 1, { slot = 1 })
    sent = {}
    BR.Combat.eliminate(1, 'test', nil)
    fakeTime = fakeTime + shield.useMs * 2
    BR.Sched.step(fakeTime)
    ok(#eventsOf(BR.Net.INV_EFFECT) == 0, 'a use dies with the player')

    -- A use that would do nothing is refused OUT LOUD rather than eating five
    -- seconds for no effect.
    reset()
    queueUp(1, 'A', BR.Mode.SOLO.key)
    queueUp(2, 'B', BR.Mode.SOLO.key)
    fakeTime = fakeTime + 300
    BR.Sched.step(fakeTime)
    BR.Roster.setState(1, BR.PlayerState.ALIVE)
    BR.Inv.reset(1)
    BR.Inv.give(1, { item = 'minishield', kind = BR.ItemKind.CONSUMABLE,
                     rarity = 1, count = 1 })
    BR.Roster.get(1).armour = shield.armourCap
    sent = {}
    fire(BR.Net.INV_USE, 1, { slot = 1 })
    ok(BR.Inv.of(1).using == nil, 'a pointless use never starts')
    -- The wording distinguishes "you are full" from "this item cannot take
    -- you further" -- a small shield potion at 50 shield is refused because
    -- of ITS cap, not because the player is topped up.
    local refused = false
    for _, s in ipairs(eventsOf(BR.Net.NOTIFY)) do
        local t = s.args[1].text
        if t:find('already full') or t:find('only takes') then refused = true end
    end
    ok(refused, 'and says why')
end

describe('inv.serverammo')
do
    -- M6: THE SERVER COUNTS THE ROUNDS. Every shot is a validated server
    -- event, so the magazine is spent from events the server authorised rather
    -- than from a number the client reported about itself. This retires the M5
    -- placeholder entirely -- see the block after this one, which now only
    -- covers the fallback path when server ammo is switched off.
    lootMatch()
    BR.Inv.reset(1)
    local rifle = BR.Config.WeaponById['carbinerifle']
    BR.Inv.give(1, { item = 'carbinerifle', kind = BR.ItemKind.WEAPON,
                     rarity = 3, count = 1, clip = rifle.clip })
    local inv = BR.Inv.of(1)
    inv.ammo[BR.AmmoType.MEDIUM] = 60
    inv.active = 1

    BR.Damage.spendRound(1, rifle.hash)
    ok(inv.slots[1].clip == rifle.clip - 1, 'a shot costs one round',
        tostring(inv.slots[1].clip))
    ok(inv.ammo[BR.AmmoType.MEDIUM] == 60, 'and does not touch the reserve')

    -- THE SIGNED HASH AGAIN. weaponDamageEvent reports it either way, and
    -- carbinerifle is one of the thirty with the top bit set -- unnormalised,
    -- this would silently never match and the gun would never run dry.
    BR.Damage.spendRound(1, rifle.hash - 0x100000000)
    ok(inv.slots[1].clip == rifle.clip - 2,
        'and it counts the same when the hash arrives signed',
        tostring(inv.slots[1].clip))

    -- A shot from a weapon that is not the one in the active slot means the
    -- slot and the ped disagree; guessing which is right is how the ammo model
    -- went wrong the first time, so it spends nothing.
    local before = inv.slots[1].clip
    BR.Damage.spendRound(1, BR.Config.WeaponById['pistol'].hash)
    ok(inv.slots[1].clip == before,
        'a shot from another weapon spends nothing')

    -- EMPTYING THE MAGAZINE RELOADS IT, because the client report that used to
    -- carry reloads is gone. Without this the gun stops at zero forever.
    inv.slots[1].clip = 1
    inv.ammo[BR.AmmoType.MEDIUM] = 60
    BR.Damage.spendRound(1, rifle.hash)
    ok(inv.slots[1].clip == rifle.clip,
        'emptying the magazine refills it from the reserve',
        tostring(inv.slots[1].clip))
    ok(inv.ammo[BR.AmmoType.MEDIUM] == 60 - rifle.clip,
        'and the reserve pays for exactly that',
        tostring(inv.ammo[BR.AmmoType.MEDIUM]))

    -- An empty reserve leaves the magazine empty rather than conjuring one.
    inv.slots[1].clip = 1
    inv.ammo[BR.AmmoType.MEDIUM] = 0
    BR.Damage.spendRound(1, rifle.hash)
    ok(inv.slots[1].clip == 0, 'a dry reserve leaves the magazine empty',
        tostring(inv.slots[1].clip))

    -- Melee has no magazine to spend.
    BR.Inv.reset(1)
    BR.Inv.give(1, { item = 'machete', kind = BR.ItemKind.WEAPON,
                     rarity = 3, count = 1 })
    BR.Inv.of(1).active = 1
    local meleeClipBefore = BR.Inv.of(1).slots[1].clip
    BR.Damage.spendRound(1, BR.Config.WeaponById['machete'].hash)
    ok(BR.Inv.of(1).slots[1].clip == meleeClipBefore,
        'and melee has no magazine to spend',
        ('%s -> %s'):format(tostring(meleeClipBefore),
                            tostring(BR.Inv.of(1).slots[1].clip)))

    -- THE CLIENT REPORT IS REFUSED while this is on. Two authorities for one
    -- number means the reload the server just paid for is overwritten by a
    -- report that has not seen it yet.
    BR.Inv.reset(1)
    BR.Inv.give(1, { item = 'carbinerifle', kind = BR.ItemKind.WEAPON,
                     rarity = 3, count = 1, clip = rifle.clip })
    BR.Inv.of(1).ammo[BR.AmmoType.MEDIUM] = 60
    fire(BR.Net.INV_AMMO, 1, { slot = 1, total = 5, clip = 5 })
    ok(BR.Inv.of(1).slots[1].clip == rifle.clip,
        'and a client ammo report is ignored outright',
        tostring(BR.Inv.of(1).slots[1].clip))
end

describe('combat.multivictim')
do
    -- THE SHOOTER WAS COMPETING WITH THEMSELVES.
    --
    -- One weaponDamageEvent can list SEVERAL hits: a shotgun spread catching
    -- two players, a round that clips one and lands in another, a blast
    -- catching four. The rate-of-fire check was computed and STAMPED inside
    -- the per-victim loop, so the second victim in the list was measured
    -- against a "last shot" the first victim had just written microseconds
    -- earlier -- and refused as faster than the weapon can cycle.
    --
    -- Nobody would have read that as a bug in the validator. It presents as
    -- shotguns doing single-target damage in a crowd, plus a slow drip of
    -- refusals blamed on lag.
    --
    -- Same reasoning that already put spendRound outside the loop: an event is
    -- one trigger pull no matter how many people it catches.
    reset()
    queueUp(1, 'A', BR.Mode.SOLO.key)
    queueUp(2, 'B', BR.Mode.SOLO.key)
    queueUp(3, 'C', BR.Mode.SOLO.key)
    fakeTime = fakeTime + 300
    BR.Sched.step(fakeTime)
    for s = 1, 3 do BR.Roster.setState(s, BR.PlayerState.ALIVE) end

    local pistol = BR.Config.WeaponById['pistol']
    BR.Inv.reset(1)
    BR.Inv.give(1, { item = 'pistol', kind = BR.ItemKind.WEAPON, rarity = 1,
                     count = 1, clip = pistol.clip })
    BR.Inv.of(1).ammo[BR.AmmoType.LIGHT] = 40
    BR.Inv.of(1).active = 1

    for s = 1, 3 do BR.Roster.get(s).pos = { x = s * 2.0, y = 0.0, z = 30.0 } end
    local hpBefore2 = BR.Roster.get(2).hp
    local hpBefore3 = BR.Roster.get(3).hp

    fakeTime = fakeTime + 5000
    fire('weaponDamageEvent', 1, 1, {
        damageType = 3, weaponType = pistol.hash, hitComponent = 0,
        weaponDamage = 26, hitGlobalIds = { 1002, 1003 },
    })

    ok(BR.Roster.get(2).hp < hpBefore2, 'the first victim in the list is hit',
        ('%s -> %s'):format(tostring(hpBefore2), tostring(BR.Roster.get(2).hp)))
    ok(BR.Roster.get(3).hp < hpBefore3,
        'and so is the second, rather than being refused as too fast',
        ('%s -> %s'):format(tostring(hpBefore3), tostring(BR.Roster.get(3).hp)))

    -- ONE ROUND FOR THE WHOLE EVENT. Charging a magazine per victim would
    -- empty a shotgun in three shots.
    ok(BR.Inv.of(1).slots[1].clip == pistol.clip - 1,
        'and the event costs exactly one round, not one per victim',
        tostring(BR.Inv.of(1).slots[1].clip))
end

describe('voice.channels')
do
    -- THE PROPERTY THAT MATTERS IS SEPARATION, and it is the one thing the
    -- engine will not do for us: FiveM's Mumble mixes by POSITION, and two
    -- parallel matches stand on the same coordinates. Routing buckets stop
    -- players seeing each other; they are not documented to stop them hearing
    -- each other, so the channels are explicit.
    local V = BR.Config.Match.voice

    local function channelsFor(src)
        local e = BR.Roster.get(src)
        return e and e.voiceProx or nil, e and e.voiceSquad or nil
    end

    -- Two SEPARATE matches, which is the case the whole file exists for.
    reset()
    for s = 1, 4 do queueUp(s, 'P' .. s, BR.Mode.SQUAD.key) end
    fakeTime = fakeTime + 300
    BR.Sched.step(fakeTime)

    local mA = theMatch()
    ok(mA ~= nil, 'a match formed')

    -- Force it out of warmup so the next ready-ups mint a second instance
    -- rather than late-joining this one.
    BR.Match.transition(mA, BR.MatchState.BUS)

    for s = 5, 8 do queueUp(s, 'Q' .. s, BR.Mode.SQUAD.key) end
    fakeTime = fakeTime + 300
    BR.Sched.step(fakeTime)

    local matches = {}
    BR.Server.eachMatch(function(m) matches[#matches + 1] = m end)
    ok(#matches == 2, 'and a second one formed alongside it', tostring(#matches))

    fakeTime = fakeTime + 1200
    BR.Sched.step(fakeTime)

    local proxA = channelsFor(1)
    local proxB = channelsFor(5)
    ok(proxA ~= nil and proxB ~= nil, 'everybody has a proximity channel',
        ('%s / %s'):format(tostring(proxA), tostring(proxB)))
    ok(proxA ~= proxB,
        'and two different matches are NEVER in the same one',
        ('%s vs %s'):format(tostring(proxA), tostring(proxB)))

    -- Inside one match, everyone shares the proximity room -- that is what
    -- makes "global" mean the match rather than the server.
    local p1 = channelsFor(1)
    local sameMatchShared = true
    BR.Roster.each(
        function(e) return e.matchId == mA.id end,
        function(src)
            if channelsFor(src) ~= p1 then sameMatchShared = false end
        end)
    ok(sameMatchShared, 'while one match shares exactly one proximity room')

    -- Squads inside a match must NOT share a squad room, or two squads hear
    -- each other's plans at unlimited range -- worse than no squad voice.
    local seen, collided = {}, false
    BR.Roster.each(
        function(e) return e.matchId == mA.id and e.squadId end,
        function(src, e)
            local _, sq = channelsFor(src)
            if sq then
                if seen[sq] and seen[sq] ~= e.squadId then collided = true end
                seen[sq] = e.squadId
            end
        end)
    ok(not collided, 'and no two squads share a squad room')

    -- A squad channel must never collide with ANY proximity channel either.
    local overlap = false
    BR.Roster.each(
        function(e) return e.state ~= BR.PlayerState.LEFT end,
        function(src)
            local prox, sq = channelsFor(src)
            if sq and prox and sq == prox then overlap = true end
            if sq and (sq == V.lobbyChannel or sq == V.warmupChannel) then
                overlap = true
            end
        end)
    ok(not overlap, 'and a squad room is never also a proximity room')

    -- Nobody is left in channel 0, which is where every Mumble client starts
    -- and therefore the one room that is shared by default.
    local inZero = false
    BR.Roster.each(
        function(e) return e.state ~= BR.PlayerState.LEFT end,
        function(src)
            local prox = channelsFor(src)
            if not prox or prox == 0 then inZero = true end
        end)
    ok(not inZero, 'and nobody is left in the default channel 0')

    -- THE WHOLE SPACE, not just the four players who happen to be online.
    --
    -- The live checks above can only fail on a collision that this particular
    -- roster happens to produce -- and with one squad per match they cannot
    -- see a squad collision at all. These sweep every match id and squad
    -- index the scheme claims to support, which is what actually pins the
    -- BASES apart: raising squadBase onto matchBase is a config edit nobody
    -- would notice until two rooms merged in front of players.
    local proxSeen, squadSeen = {}, {}
    local dupProx, dupSquad, cross = nil, nil, nil
    local MATCHES = 64
    for mid = 1, MATCHES do
        local p = BR.Voice.proxChannel(mid, nil)
        if proxSeen[p] then dupProx = p end
        proxSeen[p] = mid

        for idx = 1, V.squadStride do
            local sc = BR.Voice.squadChannel(mid, idx)
            if squadSeen[sc] then dupSquad = sc end
            squadSeen[sc] = ('m%d/%d'):format(mid, idx)
        end
    end
    for _, lone in ipairs({ V.lobbyChannel, V.warmupChannel }) do
        proxSeen[lone] = 'lone'
    end
    for ch in pairs(squadSeen) do
        if proxSeen[ch] then cross = ch end
    end

    ok(dupProx == nil, 'no two matches can ever share a proximity room',
        tostring(dupProx))
    ok(dupSquad == nil, 'no two squads can ever share a squad room',
        tostring(dupSquad))
    ok(cross == nil,
        'and the squad range never overlaps the proximity range',
        tostring(cross))
    ok(not squadSeen[0] and not proxSeen[0],
        'and nothing is ever assigned channel 0')
end

describe('combat.fire')
do
    -- A MOLOTOV KILL BELONGED TO NOBODY.
    --
    -- Measured 2026-08-08: /brdamagelog armed for 15 payloads, a molotov
    -- thrown at a player, the player DIED, and not one payload printed.
    -- Burning damage never raises weaponDamageEvent -- it is applied on the
    -- victim's own machine through a path the server does not see, so no
    -- amount of validator work reaches it.
    --
    -- The damage was never the point. The KILL was: attribution reads
    -- e.lastHitBy, nothing had written to it, and the feed credited nobody.
    -- explosionEvent DOES reach the server, so the damage stays the engine's
    -- and the LEDGER becomes ours.
    reset()
    queueUp(1, 'A', BR.Mode.SOLO.key)
    queueUp(2, 'B', BR.Mode.SOLO.key)
    fakeTime = fakeTime + 300
    BR.Sched.step(fakeTime)
    BR.Roster.setState(1, BR.PlayerState.ALIVE)
    BR.Roster.setState(2, BR.PlayerState.ALIVE)

    -- BOTH HEALTH AND POSITION FLOW PED -> SAMPLER -> ROSTER, never the other
    -- way. Writing entry.hp or entry.pos directly here would be overwritten by
    -- roster.positions before damage.fires ever saw it -- which is the mistake
    -- this project already documents. So the test moves and burns the PED.
    setPos(1, 0.0, 0.0, 30.0)
    setPos(2, 3.0, 0.0, 30.0)
    pedHealth[1002] = 200
    fakeTime = fakeTime + 600
    BR.Sched.step(fakeTime)

    local b = BR.Roster.get(2)
    b.lastHitBy, b.lastHitWeapon = nil, nil

    -- Player 1 lands a molotov next to player 2.
    fire('explosionEvent', 1, 1,
        { explosionType = 3, posX = 3.0, posY = 0.0, posZ = 30.0 })

    fakeTime = fakeTime + 600
    BR.Sched.step(fakeTime)
    ok(b.lastHitBy == nil, 'standing in a fresh fire unharmed credits nobody')

    -- Now the engine burns them. The server sees the health FALL; it never
    -- sees the hit.
    pedHealth[1002] = 164
    fakeTime = fakeTime + 600
    BR.Sched.step(fakeTime)
    ok(b.lastHitBy == 1,
        'health lost inside a fire is credited to whoever lit it',
        tostring(b.lastHitBy))
    ok(b.lastHitWeapon == 'molotov', 'and names the weapon',
        tostring(b.lastHitWeapon))

    -- ...which is the whole reason this exists.
    ok(BR.Combat.attributedKiller(b) == 1,
        'so a molotov kill finally has a killer',
        tostring(BR.Combat.attributedKiller(b)))

    -- UNHARMED IS NOT ATTRIBUTED. Without this guard a generous radius and a
    -- twenty-second window would hand out kills the storm did.
    b.lastHitBy, b.lastHitWeapon = nil, nil
    fakeTime = fakeTime + 600
    BR.Sched.step(fakeTime)
    ok(b.lastHitBy == nil, 'and standing in it unhurt still credits nobody')

    -- A PETROL PUMP IS NOT SOMEBODY'S KILL. Only the three explosive types
    -- this gamemode actually issues are claimed -- and this has to be tested
    -- INSIDE the window it would have credited, or it passes because the
    -- record expired rather than because the type was refused.
    fakeTime = fakeTime + (BR.Config.Combat.fireLifeMs or 20000) + 2000
    BR.Sched.step(fakeTime)
    b.lastHitBy, b.lastHitWeapon = nil, nil

    fire('explosionEvent', 1, 1,
        { explosionType = 7, posX = 3.0, posY = 0.0, posZ = 30.0 })
    pedHealth[1002] = 120
    fakeTime = fakeTime + 600
    BR.Sched.step(fakeTime)
    ok(b.lastHitBy == nil,
        'an exploding car credits nobody, even standing in it while burning',
        tostring(b.lastHitBy))

    -- THE FIRE GOES OUT. Credit must not outlive the flames, or a storm death
    -- half a minute later belongs to whoever last threw something.
    fire('explosionEvent', 1, 1,
        { explosionType = 3, posX = 3.0, posY = 0.0, posZ = 30.0 })
    fakeTime = fakeTime + (BR.Config.Combat.fireLifeMs or 20000) + 2000
    BR.Sched.step(fakeTime)
    pedHealth[1002] = 80
    fakeTime = fakeTime + 600
    BR.Sched.step(fakeTime)
    ok(b.lastHitBy == nil, 'and a burnt-out fire credits nobody',
        tostring(b.lastHitBy))

    -- Leave the stub as it was found: later blocks read this ped's health.
    pedHealth[1002] = nil
end

describe('loot.origin')
do
    -- WHERE A THING CAME FROM TRAVELS WITH IT.
    --
    -- Items born mid-match -- a crate bursting open, a player dropping
    -- something -- carry fx/fy/fz so the client can arc the prop from its
    -- origin instead of popping it into existence at the destination.
    --
    -- SENT WITH THE ITEM, not prefetched during the open-hold. Prefetching a
    -- container's contents before the claim is confirmed would hand the client
    -- a list of what is inside crates it has not opened -- a wallhack, for
    -- three floats of latency nobody needs.
    local m = lootMatch()
    BR.Inv.reset(1)
    BR.Roster.get(1).pos = { x = 500.0, y = 500.0, z = 40.0 }

    -- Subscribe so this player actually receives the announcements.
    local cx, cy = BR.LootCellOf(500.0, 500.0)
    fire(BR.Net.LOOT_CELL, 1, { cx = cx, cy = cy })

    -- A DROP comes out of the dropper's hands, not off the floor.
    BR.Inv.give(1, { item = 'pistol', kind = BR.ItemKind.WEAPON, rarity = 1,
                     count = 1, clip = 12 })
    sent = {}
    fire(BR.Net.INV_DROP, 1, { slot = 1 })
    local dropped = nil
    for _, s in ipairs(eventsOf(BR.Net.LOOT_ADD)) do
        for _, entry in ipairs(s.args[1]) do
            if entry.item == 'pistol' then dropped = entry end
        end
    end
    ok(dropped ~= nil, 'dropping an item announces it')
    -- A LIFT ABOVE THE GROUND, never an absolute z. Only the client has a
    -- ground probe, so an absolute height from the server is a guess -- and
    -- when that guess sat below the terrain, crate contents burst upward out
    -- of the floor (user, 2026-08-08).
    ok(dropped and dropped.fl ~= nil and dropped.fl > 0.0,
        'and it comes from ABOVE where it lands -- the dropper\'s hands',
        dropped and tostring(dropped.fl) or 'nil')
    ok(dropped and dropped.fz == nil,
        'and never as an absolute z the client would have to trust')

    -- THE GENERATED LAYOUT HAS NO ORIGIN. It was always just there, and an
    -- arc from nowhere would be an item flying out of the ground on the first
    -- frame a player sees it.
    local layoutHasOrigin = false
    for _, e in pairs(m.loot.items) do
        if not e.dropped and e.fx then layoutHasOrigin = true end
    end
    ok(not layoutHasOrigin, 'while the generated layout carries no origin')

    -- A CRATE'S CONTENTS COME OUT OF THE CRATE.
    local crate = nil
    for _, e in pairs(m.loot.items) do
        if e.kind == 'chest' and e.contents and #e.contents > 0 then
            crate = e break
        end
    end
    if crate then
        BR.Roster.get(1).pos = { x = crate.x, y = crate.y, z = crate.z }
        local ccx, ccy = BR.LootCellOf(crate.x, crate.y)
        fire(BR.Net.LOOT_CELL, 1, { cx = ccx, cy = ccy })
        sent = {}
        fire(BR.Net.LOOT_CLAIM, 1, { id = crate.id })
        local scattered = 0
        for _, s in ipairs(eventsOf(BR.Net.LOOT_ADD)) do
            for _, entry in ipairs(s.args[1]) do
                if entry.fx and math.abs(entry.fx - crate.x) < 0.01
                   and math.abs(entry.fy - crate.y) < 0.01 then
                    scattered = scattered + 1
                end
            end
        end
        ok(scattered > 0,
            'and a crate\'s contents come out of the crate, not out of nowhere',
            tostring(scattered))
    else
        ok(false, 'no chest with contents in the layout to test against')
    end
end

describe('combat.paths')
do
    -- THREE ANSWERS TO "WHOSE HIT IS THIS", decided by weaponType.
    --
    -- The validator used to gate on damageType. A punch that arrived as
    -- damageType 1 fell through to the engine, which applied GTA's own melee
    -- damage ON TOP of ours -- two punches killed a full-health player (user,
    -- 2026-08-08). Chasing that with a longer list of numbers leaves every gap
    -- in the list as a damage path handed back to the client.
    reset()
    queueUp(1, 'A', BR.Mode.SOLO.key)
    queueUp(2, 'B', BR.Mode.SOLO.key)
    fakeTime = fakeTime + 300
    BR.Sched.step(fakeTime)
    BR.Roster.setState(1, BR.PlayerState.ALIVE)
    BR.Roster.setState(2, BR.PlayerState.ALIVE)
    BR.Inv.reset(1)
    for s = 1, 2 do BR.Roster.get(s).pos = { x = s * 1.0, y = 0.0, z = 30.0 } end

    local UNARMED = 2725352035
    local FALL    = BR.Config.Environmental[1].hash

    -- 1. THE WORLD'S. A fall is not a weapon and must never be refused --
    -- under the old rule it was "a weapon this gamemode does not issue",
    -- i.e. a cancelled hit and an anticheat strike against a player who fell
    -- off a roof.
    BR.Damage.forgetRefusals(1)
    local refusalsBefore = BR.Damage.refusals or 0
    local envBefore = BR.Damage.envHits or 0
    fakeTime = fakeTime + 5000
    fire('weaponDamageEvent', 2, 2, {
        damageType = 3, weaponType = FALL, hitComponent = 0,
        weaponDamage = 40, hitGlobalIds = { 1002 },
    })
    ok((BR.Damage.envHits or 0) > envBefore,
        'a fall is recognised as the world hurting somebody')
    ok((BR.Damage.refusals or 0) == refusalsBefore,
        'and is never refused')

    -- 2. NEITHER. A weapon nobody was issued is the one thing left worth
    -- refusing, and widening the pass-through must not have opened it.
    fakeTime = fakeTime + 5000
    fire('weaponDamageEvent', 1, 1, {
        damageType = 3, weaponType = 0x12345678, hitComponent = 0,
        weaponDamage = 90, hitGlobalIds = { 1002 },
    })
    ok((BR.Damage.refusals or 0) > refusalsBefore,
        'while a weapon nobody was issued is still refused')

    -- 3. OURS -- including a punch, whatever damageType it claims to be. This
    -- is the exact payload shape that used to fall through.
    local hp0 = BR.Roster.get(2).hp
    fakeTime = fakeTime + 5000
    fire('weaponDamageEvent', 1, 1, {
        damageType = 1, weaponType = UNARMED, hitComponent = 8,
        weaponDamage = 25, hitGlobalIds = { 1002 },
    })
    local hp1 = BR.Roster.get(2).hp
    ok(hp1 < hp0, 'a punch reported as damageType 1 is still ours to apply',
        ('%s -> %s'):format(tostring(hp0), tostring(hp1)))
    ok(math.abs((hp0 - hp1) - BR.Config.Fists.damage) < 0.01,
        'and costs exactly the fists number, not ours plus the engine\'s',
        tostring(hp0 - hp1))

    -- ONE SWING, ONE HIT. Melee is an animation with several contact points
    -- and the engine may report it more than once; applying twice is how a
    -- punch came to hit for double. The duplicate is dropped rather than
    -- REFUSED -- it arrives microseconds later, so validating it would refuse
    -- it as TOO_FAST, which is a countable refusal, which would file
    -- anticheat strikes against people for punching.
    local dupBefore = BR.Damage.meleeDupes or 0
    local refBefore = BR.Damage.refusals or 0
    fire('weaponDamageEvent', 1, 1, {
        damageType = 3, weaponType = UNARMED, hitComponent = 8,
        weaponDamage = 25, hitGlobalIds = { 1002 },
    })
    ok(BR.Roster.get(2).hp == hp1,
        'the same swing arriving twice costs one hit',
        tostring(BR.Roster.get(2).hp))
    ok((BR.Damage.meleeDupes or 0) > dupBefore, 'and is counted as a duplicate')
    ok((BR.Damage.refusals or 0) == refBefore,
        'and is never counted as a refusal')

    -- SELF-DAMAGE IS ALLOWED, REPEATED SELF-DAMAGE IS NOT. You can stand in
    -- your own grenade; refusing that outright made explosives free to spam at
    -- your own feet (user pushback, 2026-08-08).
    BR.Damage.forget(1)
    BR.Damage.forgetRefusals(1)
    BR.Inv.reset(1)
    BR.Inv.give(1, { item = 'grenade', kind = BR.ItemKind.THROWABLE,
                     rarity = 3, count = 3 })
    BR.Inv.of(1).active = 1
    BR.Roster.get(1).hp = 100.0

    local selfHp0 = BR.Roster.get(1).hp
    fakeTime = fakeTime + 5000
    fire('weaponDamageEvent', 1, 1, {
        damageType = 3, weaponType = 2481070269, hitComponent = 0,
        weaponDamage = 500, hitGlobalIds = { 1001 },
    })
    ok(BR.Roster.get(1).hp < selfHp0,
        'your own grenade hurts you', tostring(BR.Roster.get(1).hp))

    local refSelf = BR.Damage.refusals or 0
    BR.Roster.get(1).hp = 100.0
    for _ = 1, 4 do
        fakeTime = fakeTime + 50
        fire('weaponDamageEvent', 1, 1, {
            damageType = 3, weaponType = 2481070269, hitComponent = 0,
            weaponDamage = 500, hitGlobalIds = { 1001 },
        })
    end
    ok((BR.Damage.refusals or 0) > refSelf,
        'but doing it over and over is refused and counted')
end

describe('inv.throwables')
do
    -- UNLIMITED GRENADES, for one commit.
    --
    -- serverAmmo counts rifle rounds off validated weaponDamageEvents, and its
    -- early-return sat at the TOP of the INV_AMMO handler -- above the
    -- throwable branch. But a THROW raises no event at all: the only thing a
    -- grenade produces is its detonation, which arrives seconds later, may
    -- never arrive (into water, at nobody), and is cancelled by the validator
    -- when it does. So nothing decremented throwables, from either side.
    --
    -- The client report stays the authority for these, and stays safe for the
    -- reason it always was: decrease-only, so the worst a liar achieves is
    -- throwing their own grenades away.
    ok(BR.Config.Combat.serverAmmo, 'server ammo is on for this block')

    lootMatch()
    BR.Inv.reset(1)
    BR.Inv.give(1, { item = 'grenade', kind = BR.ItemKind.THROWABLE,
                     rarity = 3, count = 3 })
    local inv = BR.Inv.of(1)
    inv.active = 1

    fire(BR.Net.INV_AMMO, 1, { slot = 1, total = 2, clip = 2 })
    ok(inv.slots[1] and inv.slots[1].count == 2,
        'throwing one grenade leaves two, even with server ammo on',
        tostring(inv.slots[1] and inv.slots[1].count))

    -- THREE PER ITEM, ACROSS THE WHOLE INVENTORY (user call, 2026-08-08).
    -- The per-slot cap says nothing about how many slots you may open, so
    -- without a carry cap a player could fill three slots and walk around
    -- with nine grenades.
    BR.Inv.reset(1)
    for _ = 1, 4 do
        BR.Inv.give(1, { item = 'grenade', kind = BR.ItemKind.THROWABLE,
                         rarity = 3, count = 3 })
    end
    local held = 0
    for i = 0, 5 do
        local s = BR.Inv.of(1).slots[i]
        if s and s.item == 'grenade' then held = held + (s.count or 0) end
    end
    ok(held == 3, 'a player can carry three of a throwable and no more',
        tostring(held))

    -- ...and the fourth is REFUSED rather than silently eaten, so the entry
    -- stays on the floor for somebody who has room.
    local okGive, _, reason = BR.Inv.give(1, {
        item = 'grenade', kind = BR.ItemKind.THROWABLE, rarity = 3, count = 1 })
    ok(not okGive and reason == 'carrymax',
        'and the one that does not fit stays in the world', tostring(reason))

    -- Different throwables are capped independently: three grenades AND
    -- three smokes is fine, it is nine of one that is not.
    BR.Inv.give(1, { item = 'smoke', kind = BR.ItemKind.THROWABLE,
                     rarity = 1, count = 3 })
    local smokes = 0
    for i = 0, 5 do
        local s = BR.Inv.of(1).slots[i]
        if s and s.item == 'smoke' then smokes = smokes + (s.count or 0) end
    end
    ok(smokes == 3, 'and each kind is capped on its own', tostring(smokes))

    -- Back to the stack the rest of this block works against.
    BR.Inv.reset(1)
    BR.Inv.give(1, { item = 'grenade', kind = BR.ItemKind.THROWABLE,
                     rarity = 3, count = 3 })
    inv = BR.Inv.of(1)
    inv.active = 1
    fire(BR.Net.INV_AMMO, 1, { slot = 1, total = 2, clip = 2 })

    -- A RISE IS STILL REFUSED. Decrease-only is the whole safety argument.
    fire(BR.Net.INV_AMMO, 1, { slot = 1, total = 9, clip = 9 })
    ok(inv.slots[1].count == 2, 'and a report that conjures more is ignored',
        tostring(inv.slots[1].count))

    -- THE THROW IS REMEMBERED, because the blast arrives after the slot is
    -- empty and the validator has to know the grenade was ours.
    ok(BR.Damage.threwRecently(1, 'grenade'),
        'and the server remembers who threw it')
    ok(not BR.Damage.threwRecently(1, 'sticky'),
        'but not for something they never threw')

    -- Throwing the last one empties the slot, and the memory is what carries
    -- the detonation that follows.
    fire(BR.Net.INV_AMMO, 1, { slot = 1, total = 0, clip = 0 })
    ok(not inv.slots[1] or inv.slots[1] == false,
        'the last grenade empties the slot')
    ok(BR.Damage.threwRecently(1, 'grenade'),
        'and the blast still resolves to the thrower with empty hands')

    -- ...until the window closes.
    local was = fakeTime
    fakeTime = fakeTime + (BR.Config.Combat.explosiveGraceMs or 30000) + 1000
    ok(not BR.Damage.threwRecently(1, 'grenade'),
        'the credit expires rather than lasting the match')
    fakeTime = was

    BR.Damage.forget(1)
    ok(not BR.Damage.threwRecently(1, 'grenade'),
        'and a disconnect forgets it outright')
end

-- THE FALLBACK PATH, still live when `/brdamage off` turns the takeover back
-- into an audit. If the server is not applying damage it is not seeing shots
-- either, and a magazine nothing decrements is better than one nothing
-- refills -- so the M5 model stays behind a flag rather than being deleted.
local savedServerAmmo = BR.Config.Combat.serverAmmo
BR.Config.Combat.serverAmmo = false

describe('inv.ammo')
do
    -- THE TOTAL IS AUTHORITATIVE AND DECREASE-ONLY. The clip is only the split.
    --
    -- Two models came before this one and both tried to work out what the
    -- player DID from a single number. The first computed the reserve as
    -- `GetAmmoInPedWeapon - clip`; the second reported the magazine alone and
    -- read a rise as a reload. Both collapse the moment one of those natives
    -- misbehaves -- and one did: the magazine sat frozen while the total
    -- climbed by one per shot (user, 2026-08-06).
    --
    -- So nothing is inferred any more. Firing lowers the total, a reload only
    -- moves rounds between the halves of it, and a RISE is refused rather than
    -- explained -- the same guard ox_inventory uses.
    lootMatch()
    BR.Inv.reset(1)
    local pistol = BR.Config.WeaponById['pistol']
    BR.Inv.give(1, { item = 'pistol', kind = BR.ItemKind.WEAPON, rarity = 1,
                     count = 1, clip = pistol.clip })
    local inv = BR.Inv.of(1)
    inv.ammo[BR.AmmoType.LIGHT] = 40
    local total = pistol.clip + 40

    -- FIRING: five rounds leave the world. The magazine falls with the total.
    fire(BR.Net.INV_AMMO, 1, { slot = 1, total = total - 5, clip = pistol.clip - 5 })
    ok(inv.slots[1].clip == pistol.clip - 5, 'firing empties the magazine',
        tostring(inv.slots[1].clip))
    ok(inv.ammo[BR.AmmoType.LIGHT] == 40,
        'and does not touch the reserve',
        tostring(inv.ammo[BR.AmmoType.LIGHT]))

    -- RELOADING: the total does not move at all. The split does, and the
    -- reserve pays exactly the rounds that went into the magazine.
    fire(BR.Net.INV_AMMO, 1, { slot = 1, total = total - 5, clip = pistol.clip })
    ok(inv.slots[1].clip == pistol.clip, 'a reload fills the magazine')
    ok(inv.ammo[BR.AmmoType.LIGHT] == 35,
        'and the reserve pays exactly the difference',
        tostring(inv.ammo[BR.AmmoType.LIGHT]))

    -- A RISING TOTAL IS REFUSED. This is the entire fix: whatever was
    -- inflating the engine's number, the server simply does not believe it.
    local beforeClip = inv.slots[1].clip
    fire(BR.Net.INV_AMMO, 1, { slot = 1, total = total + 500, clip = pistol.clip })
    ok(inv.ammo[BR.AmmoType.LIGHT] == 35,
        'a client cannot report itself more ammo',
        tostring(inv.ammo[BR.AmmoType.LIGHT]))
    ok(inv.slots[1].clip == beforeClip, 'nor change anything by trying')

    -- AN EMPTY RESERVE CANNOT CONJURE A MAGAZINE. The reserve is what is LEFT
    -- once the magazine comes out of the total, so there is nothing for the
    -- arithmetic to take it from.
    inv.ammo[BR.AmmoType.LIGHT] = 2
    inv.slots[1].clip = 0
    fire(BR.Net.INV_AMMO, 1, { slot = 1, total = 2, clip = pistol.clip })
    ok(inv.slots[1].clip == 2, 'a reload is capped by what the reserve held',
        tostring(inv.slots[1].clip))
    ok(inv.ammo[BR.AmmoType.LIGHT] == 0, 'which is now empty')

    -- And a magazine cannot exceed the weapon's own capacity.
    inv.ammo[BR.AmmoType.LIGHT] = 500
    inv.slots[1].clip = 0
    fire(BR.Net.INV_AMMO, 1, { slot = 1, total = 500, clip = 9999 })
    ok(inv.slots[1].clip == pistol.clip, 'a magazine cannot hold more than a magazine',
        tostring(inv.slots[1].clip))
    ok(inv.ammo[BR.AmmoType.LIGHT] == 500 - pistol.clip,
        'and everything above it stays in the reserve',
        tostring(inv.ammo[BR.AmmoType.LIGHT]))

    -- RUNNING DRY takes the magazine with it: a total below a full magazine
    -- cannot leave a full magazine behind.
    fire(BR.Net.INV_AMMO, 1, { slot = 1, total = 3, clip = 3 })
    ok(inv.slots[1].clip == 3 and inv.ammo[BR.AmmoType.LIGHT] == 0,
        'the last three rounds are all in the magazine and none in reserve',
        ('clip %s reserve %s'):format(inv.slots[1].clip,
                                      inv.ammo[BR.AmmoType.LIGHT]))

    -- Nonsense is refused outright.
    local before = inv.slots[1].clip
    fire(BR.Net.INV_AMMO, 1, { slot = 1, total = -50, clip = -50 })
    ok(inv.slots[1].clip == before, 'a negative report is ignored')
    fire(BR.Net.INV_AMMO, 1, { slot = 1, clip = 1 })
    ok(inv.slots[1].clip == before, 'and so is one carrying no total at all')

    -- The client is told, because the reserve is the SERVER's arithmetic -- it
    -- has no other way to learn it.
    inv.ammo[BR.AmmoType.LIGHT] = 400
    inv.slots[1].clip = pistol.clip
    sent = {}
    fire(BR.Net.INV_AMMO, 1, { slot = 1, total = 400, clip = 4 })
    ok(#eventsOf(BR.Net.INV_SET) > 0, 'and the result is pushed back')
end

-- Fallback coverage ends here; the takeover is the default again.BR.Config.Combat.serverAmmo = savedServerAmmo
describe('inv.warmup')
do
    -- A WARMUP INVENTORY IS A LIVE INVENTORY.
    --
    -- There is loot on the warmup island and the whole point of the island is
    -- early PVP, so a player who picks a gun up there has to be able to hold
    -- it. The server's LIVE table listed only ALIVE and DBNO, so every
    -- INV_SELECT/SWAP/DROP/USE from warmup was dropped in silence while the
    -- client happily sent them -- "it's impossible to select a weapon while in
    -- warmup" (user, 2026-08-06).
    lootMatch()
    BR.Inv.reset(1)
    BR.Inv.give(1, { item = 'pistol', kind = BR.ItemKind.WEAPON, rarity = 1,
                     count = 1, clip = 12 })
    BR.Inv.give(1, { item = 'sawnoff', kind = BR.ItemKind.WEAPON, rarity = 1,
                     count = 1, clip = 8 })
    BR.Inv.of(1).active = 1

    BR.Roster.setState(1, BR.PlayerState.WARMUP)
    fire(BR.Net.INV_SELECT, 1, { slot = 2 })
    ok(BR.Inv.of(1).active == 2, 'a warmup player can select a slot',
        tostring(BR.Inv.of(1).active))

    fire(BR.Net.INV_SWAP, 1, { from = 1, to = 2 })
    ok(BR.Inv.of(1).slots[1] and BR.Inv.of(1).slots[1].item == 'sawnoff',
        'and reorder what they are carrying')

    -- A RIDER ON THE BUS STILL CANNOT. The distinction is feet on the ground,
    -- not "is in a match" -- rummaging through a bag mid-drop is not a thing,
    -- and the client suspends weapon application in the air anyway.
    local was = BR.Inv.of(1).active
    BR.Roster.setState(1, BR.PlayerState.BUS)
    fire(BR.Net.INV_SELECT, 1, { slot = 1 })
    ok(BR.Inv.of(1).active == was, 'but a rider on the bus still cannot',
        tostring(BR.Inv.of(1).active))
    BR.Roster.setState(1, BR.PlayerState.ALIVE)
end

describe('combat.refusals')
do
    -- A STREAM OF REFUSALS IS A SIGNAL, not noise. The validator ran in
    -- log-only mode for a full playtest on the rule that every refusal during
    -- honest play is a false positive, and that log came back empty -- so a
    -- dozen in half a minute means somebody is doing something the server did
    -- not issue them the means to do.
    lootMatch()
    local cfg = BR.Config.Combat
    BR.Damage.forgetRefusals(1)

    -- Under the limit: counted, nothing said.
    for _ = 1, cfg.refusalLimit - 1 do
        BR.Damage.noteRefusal(1, BR.ShotRefusal.NOT_HELD)
    end
    ok(true, 'refusals under the limit are counted quietly')

    -- The action fires ONCE at the limit, not once per shot after it -- a
    -- cheater holding the trigger must not produce a hundred log lines or a
    -- hundred notices.
    sent = {}
    BR.Damage.noteRefusal(1, BR.ShotRefusal.NOT_HELD)
    local firstBurst = #sent
    for _ = 1, 20 do
        BR.Damage.noteRefusal(1, BR.ShotRefusal.NOT_HELD)
    end
    ok(#sent == firstBurst,
        'the response fires once per window, not once per refused shot',
        ('%d then %d'):format(firstBurst, #sent))

    -- A fresh window starts clean, so an honest player who tripped it once
    -- during a bad race is not carrying it for the rest of the match.
    BR.Damage.forgetRefusals(1)
    for _ = 1, cfg.refusalLimit - 1 do
        BR.Damage.noteRefusal(1, BR.ShotRefusal.NOT_HELD)
    end
    ok(true, 'and the count resets with the window')

    -- DEFAULT IS LOG, DELIBERATELY. Kicking on a validator that has never
    -- wrongly refused an honest player TODAY is still a bet on tomorrow.
    ok(cfg.refusalAction == 'log',
        'and the default response is to log rather than to kick',
        tostring(cfg.refusalAction))

    -- RULES ARE NOT CHEATING, and fists are what made this matter: every
    -- player has them at all times, so a warmup scrap or a squadmate caught in
    -- a spray produces refusals by the dozen. Counting those means the
    -- threshold fires on ordinary play.
    BR.Damage.forgetRefusals(1)
    sent = {}
    for _ = 1, cfg.refusalLimit * 3 do
        BR.Damage.noteRefusal(1, BR.ShotRefusal.NOT_LIVE)
        BR.Damage.noteRefusal(1, BR.ShotRefusal.SAME_SQUAD)
        BR.Damage.noteRefusal(1, BR.ShotRefusal.SELF)
    end
    ok(#sent == 0,
        'punching in warmup and hitting a squadmate never trip the threshold',
        tostring(#sent))

    -- ...and the ones that mean something still do, from the same clean slate.
    BR.Damage.forgetRefusals(1)
    cfg.refusalAction = 'notify'
    sent = {}
    for _ = 1, cfg.refusalLimit do
        BR.Damage.noteRefusal(1, BR.ShotRefusal.NO_WEAPON)
    end
    ok(#sent > 0, 'while a weapon the server never issued still does',
        tostring(#sent))
    cfg.refusalAction = 'log'
    BR.Damage.forgetRefusals(1)
end

describe('combat.attribution')
do
    -- WHO GETS THE KILL, and why it cannot come from the client any more.
    --
    -- M6 cancels the engine's damage and applies its own, so GTA's idea of who
    -- shot whom is gone by the time the ped dies -- the killing blow is our
    -- own health write, and an honest client reports no killer. Every
    -- elimination therefore read "0 eliminations" on the summary until the
    -- server started answering this itself (user, 2026-08-08).
    lootMatch()
    local victim = BR.Roster.get(2)
    BR.Roster.setState(2, BR.PlayerState.ALIVE)

    -- Nothing recorded: nobody is credited. A fall in an empty field is
    -- nobody's kill.
    victim.lastHitBy, victim.lastHitAt = nil, nil
    ok(BR.Combat.attributedKiller(victim) == nil,
        'a death with no recorded damage credits nobody')

    -- The validated damage path recorded a hit: that is the killer.
    victim.lastHitBy, victim.lastHitAt = 1, fakeTime
    ok(BR.Combat.attributedKiller(victim) == 1,
        'a recent validated hit credits the shooter')

    -- THE ASSIST WINDOW IS THE POINT. Finish someone who was already bleeding
    -- from your rifle -- storm, fall, anything -- and it is still your kill.
    victim.lastHitAt = fakeTime - (BR.Config.Match.assistWindowMs - 1000)
    ok(BR.Combat.attributedKiller(victim) == 1,
        'and still credits them inside the assist window')

    victim.lastHitAt = fakeTime - (BR.Config.Match.assistWindowMs + 1000)
    ok(BR.Combat.attributedKiller(victim) == nil,
        'but not once the window has passed')

    -- Never yourself, and never somebody who has left.
    victim.lastHitBy, victim.lastHitAt = 2, fakeTime
    ok(BR.Combat.attributedKiller(victim) == nil,
        'nobody is credited for their own death')

    victim.lastHitBy, victim.lastHitAt = 999, fakeTime
    ok(BR.Combat.attributedKiller(victim) == nil,
        'nor is a player who has since disconnected')

    -- END TO END: the kill lands on the roster and on the wire.
    victim.lastHitBy, victim.lastHitAt = 1, fakeTime
    BR.Roster.get(1).kills = 0
    sent = {}
    fire(BR.Net.PLAYER_DIED, 2, { cause = 'unknown' })
    ok(BR.Roster.get(1).kills == 1, 'an attributed death increments the killer',
        tostring(BR.Roster.get(1).kills))

    local feed = eventsOf(BR.Net.KILL_FEED)
    local last = feed[#feed] and feed[#feed].args[1]
    ok(last and last.killerSrc == 1,
        'and the kill feed names them rather than showing an anonymous death',
        tostring(last and last.killerSrc))
end

describe('loot.deathbox')
do
    local m = lootMatch()
    BR.Inv.reset(1)
    BR.Inv.give(1, { item = 'carbinerifle', kind = BR.ItemKind.WEAPON,
                     rarity = 3, count = 1, clip = 30 })
    BR.Inv.give(1, { item = 'bandage', kind = BR.ItemKind.CONSUMABLE,
                     rarity = 1, count = 3 })
    BR.Roster.get(1).pos = { x = 900.0, y = 900.0, z = 40.0 }

    local before = m.loot.nextId
    BR.Combat.eliminate(1, 'test', 2)

    -- SCATTERED, NOT BOXED (user call, 2026-08-05). Right after a fight,
    -- standing still to hold a key on a container is the last thing anyone
    -- wants to do -- their kit lands around them and you run through it.
    local spawned = {}
    for id = before + 1, m.loot.nextId do
        local e = m.loot.items[id]
        if e then spawned[#spawned + 1] = e end
    end
    ok(#spawned >= 2, 'an elimination scatters what they carried',
        ('%d items'):format(#spawned))

    local boxes, rifle, ammo = 0, false, false
    local furthest = 0.0
    for _, e in ipairs(spawned) do
        if e.kind == 'deathbox' or e.kind == 'chest' then boxes = boxes + 1 end
        if e.item == 'carbinerifle' then rifle = true end
        if e.kind == BR.ItemKind.AMMO then ammo = true end
        local d = BR.Dist(e.x, e.y, 900.0, 900.0)
        if d > furthest then furthest = d end
    end

    ok(boxes == 0, 'with no container to open')
    ok(rifle, 'their weapon is on the ground')
    ok(ammo, 'and their ammo with it')
    ok(furthest <= BR.Config.Loot.deathScatterRadius + 0.01,
        'all of it within the scatter radius of where they fell',
        ('%.1fm'):format(furthest))
    ok(BR.Inv.of(1).slots[1] == false, 'and the corpse carries nothing')

    -- Anyone can simply walk over it -- no hold, no container.
    BR.Roster.setState(2, BR.PlayerState.ALIVE)
    standOn(2, spawned[1])
    sent = {}
    fire(BR.Net.LOOT_CLAIM, 2, { id = spawned[1].id })
    ok(m.loot.items[spawned[1].id] == nil, 'and picked up in one press')
end

describe('loot.crates')
do
    local m = lootMatch()

    local crate
    for id = 1, m.loot.nextId do
        local e = m.loot.items[id]
        if e and e.kind == 'chest' then crate = e break end
    end
    ok(crate ~= nil, 'the layout contains a crate')
    ok(crate.prop == BR.Config.Loot.chestProp, 'sealed, as the wooden crate')

    local cx, cy = BR.LootCellOf(crate.x, crate.y)
    fire(BR.Net.LOOT_CELL, 1, { cx = cx, cy = cy })
    standOn(1, crate)

    local n = #crate.contents
    local crateX = crate.x
    local before = m.loot.nextId
    sent = {}
    fire(BR.Net.LOOT_CLAIM, 1, { id = crate.id })

    -- THE CRATE STAYS, OPENED -- same id, same place, new model. Retiring it
    -- and announcing a separate husk entry meant a delete, a round-trip and a
    -- fresh model stream before the open crate appeared, which was visibly
    -- slow (user, 2026-08-05).
    local husk = m.loot.items[crate.id]
    ok(husk ~= nil, 'the crate entry survives, as a husk')
    ok(husk and husk.kind == 'husk', 'its kind flips to husk')
    ok(husk and husk.prop == BR.Config.Loot.chestOpenProp,
        'and it wears the open-and-empty crate model')
    ok(husk and math.abs(husk.x - crateX) < 0.01,
        'standing exactly where the sealed one was')
    ok(husk and husk.contents == nil, 'holding nothing')
    ok(m.loot.nextId == before + n,
        'and exactly the contents were laid on the ground -- no extra entry',
        ('%d new'):format(m.loot.nextId - before))

    -- The change reaches everyone looking at that cell, under the SAME id, so
    -- clients swap one model rather than deleting and rebuilding.
    local reskinned = false
    for _, s in ipairs(eventsOf(BR.Net.LOOT_ADD)) do
        for _, entry in ipairs(s.args[1]) do
            if entry.id == crate.id and entry.kind == 'husk' then
                reskinned = true
            end
        end
    end
    ok(reskinned, 'and is re-announced under its original id')

    -- A HUSK IS NOT LOOT. Claiming it must do nothing at all -- an opened
    -- crate that could be opened again would duplicate its contents.
    standOn(1, husk)
    local beforeHusk = m.loot.nextId
    fire(BR.Net.LOOT_CLAIM, 1, { id = husk.id })
    ok(m.loot.items[husk.id] ~= nil, 'a husk cannot be claimed')
    ok(m.loot.nextId == beforeHusk, 'and produces nothing')
end

describe('loot.warmup')
do
    -- The pad is a COMMUNAL bucket, so its loot is ONE shared layout -- two
    -- players warming up for different matches must see the same crates.
    -- Deliberately NOT in a match apiece: the pad zone is chosen by PLAYER
    -- STATE, not by membership, which is what lets two players warming up for
    -- different flights share one layout.
    reset()
    join(1, 'A')
    join(2, 'B')
    BR.Roster.setState(1, BR.PlayerState.WARMUP)
    BR.Roster.setState(2, BR.PlayerState.WARMUP)

    local pad = BR.Config.Match.warmupPos
    local cx, cy = BR.LootCellOf(pad.x, pad.y)

    sent = {}
    fire(BR.Net.LOOT_CELL, 1, { cx = cx, cy = cy })
    fire(BR.Net.LOOT_CELL, 2, { cx = cx, cy = cy })

    local seenBy = { [1] = {}, [2] = {} }
    for _, s in ipairs(eventsOf(BR.Net.LOOT_ADD)) do
        for _, e in ipairs(s.args[1]) do
            if seenBy[s.target] then seenBy[s.target][e.id] = e end
        end
    end

    local n1, n2, agree = 0, 0, true
    for id, e in pairs(seenBy[1]) do
        n1 = n1 + 1
        local other = seenBy[2][id]
        if not other or math.abs(other.x - e.x) > 0.01 then agree = false end
    end
    for _ in pairs(seenBy[2]) do n2 = n2 + 1 end

    ok(n1 > 0, 'a warmup player is streamed the pad crates',
        ('%d crates'):format(n1))
    ok(n1 == n2 and agree,
        'and two players in DIFFERENT matches see the identical layout')

    -- Warmup loot is takeable: the pad is for practice PVP.
    local anyId, anyEntry = next(seenBy[1])
    BR.Roster.get(1).pos = { x = anyEntry.x, y = anyEntry.y, z = anyEntry.z }
    sent = {}
    fire(BR.Net.LOOT_CLAIM, 1, { id = anyId })
    -- Opening turns the crate into its husk in place -- so the proof it was
    -- opened is the re-announcement, not a removal.
    local opened = false
    for _, s in ipairs(eventsOf(BR.Net.LOOT_ADD)) do
        for _, entry in ipairs(s.args[1]) do
            if entry.id == anyId and entry.kind == 'husk' then opened = true end
        end
    end
    ok(opened, 'and can be opened during warmup')

    -- NOTHING FLIES. Everything found on the pad is wiped at wheels-up: the
    -- island is practice, and arriving early must not be a head start.
    reset()
    queueUp(1, 'A', BR.Mode.SOLO.key)
    queueUp(2, 'B', BR.Mode.SOLO.key)
    fakeTime = fakeTime + 300
    BR.Sched.step(fakeTime)
    ok(mstate() == BR.MatchState.WARMUP, 'a match reaches warmup')

    BR.Inv.reset(1)
    BR.Inv.give(1, { item = 'carbinerifle', kind = BR.ItemKind.WEAPON,
                     rarity = 3, count = 1, clip = 30 })
    BR.Inv.give(1, { item = BR.AmmoType.MEDIUM, kind = BR.ItemKind.AMMO,
                     rarity = 1, count = 90 })
    ok(BR.Inv.of(1).slots[1] ~= false, 'a warmup pickup is in hand')

    BR.Match.transition(theMatch(), BR.MatchState.BUS)
    ok(BR.Inv.of(1).slots[1] == false, 'and is gone the moment the bus departs')
    ok((BR.Inv.of(1).ammo[BR.AmmoType.MEDIUM] or 0) == 0,
        'ammo found on the pad does not fly either')
end

describe('loot.repair')
do
    -- Only a CLIENT can ground-probe, so a correction can only come from out
    -- there -- and the bound on it is what makes accepting one safe.
    local m = lootMatch()
    local target
    for id = 1, m.loot.nextId do
        local e = m.loot.items[id]
        if e and e.kind == BR.ItemKind.WEAPON then target = e break end
    end

    local cx, cy = BR.LootCellOf(target.x, target.y)
    fire(BR.Net.LOOT_CELL, 1, { cx = cx, cy = cy })

    local ox, oy = target.x, target.y

    -- Out of bounds: a 400m "correction" is a relocation, not a repair.
    fire(BR.Net.LOOT_FIX, 1, { id = target.id, x = ox + 400.0, y = oy, z = 5.0 })
    ok(math.abs(m.loot.items[target.id].x - ox) < 0.01,
        'a correction beyond the bound is refused')

    -- In bounds: accepted, and the entry moves.
    fire(BR.Net.LOOT_FIX, 1, { id = target.id, x = ox + 12.0, y = oy + 3.0, z = 44.0 })
    ok(math.abs(m.loot.items[target.id].x - (ox + 12.0)) < 0.01,
        'a correction within the bound is applied')
    ok(math.abs(m.loot.items[target.id].z - 44.0) < 0.01,
        'including the height the client probed')

    -- ONCE PER ENTRY. Without this a client could walk an item across the map
    -- 30m at a time.
    fire(BR.Net.LOOT_FIX, 1, { id = target.id, x = ox + 24.0, y = oy, z = 44.0 })
    ok(math.abs(m.loot.items[target.id].x - (ox + 12.0)) < 0.01,
        'an entry can only be corrected once')

    -- A player who is not subscribed to that cell cannot correct it at all.
    local far
    for id = 1, m.loot.nextId do
        local e = m.loot.items[id]
        if e and e.kind == BR.ItemKind.WEAPON and e.cell ~= target.cell
           and not e.repaired then
            far = e
            break
        end
    end
    if far then
        local fx = far.x
        BR.Roster.setState(2, BR.PlayerState.ALIVE)
        fire(BR.Net.LOOT_FIX, 2, { id = far.id, x = fx + 5.0, y = far.y, z = 1.0 })
        ok(math.abs(m.loot.items[far.id].x - fx) < 0.01,
            'and only for cells they are actually subscribed to')
    end
end

describe('loot.teardown')
do
    local m = lootMatch()
    local first = m.loot.items[1]
    local cx, cy = BR.LootCellOf(first.x, first.y)
    fire(BR.Net.LOOT_CELL, 1, { cx = cx, cy = cy })
    BR.Inv.give(1, { item = 'pistol', kind = BR.ItemKind.WEAPON, rarity = 1,
                     count = 1, clip = 12 })
    ok(BR.Inv.of(1).slots[1] ~= false, 'the player is carrying something')

    BR.Match.transition(m, BR.MatchState.CLEANUP)
    ok(m.loot == nil, 'cleanup forgets the layout')
    ok(BR.Inv.of(1).slots[1] == false, 'and empties every inventory')

    BR.Match.destroy(m)
    ok(BR.Server.matches[m.id] == nil, 'and the instance goes with it')
end

realPrint(('\n\27[32m%d passed\27[0m'):format(pass))
if fail > 0 then
    realPrint(('\27[31m%d failed\27[0m'):format(fail))
    os.exit(1)
end
