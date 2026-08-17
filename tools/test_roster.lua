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
-- Identifier natives, for BR.Roster.ringmaster's lazy license resolution. A
-- test player's license is synthesised from its src so it is stable and
-- distinct; the ringmaster projection block is the only thing that reads them.
function GetNumPlayerIdentifiers(src) return 1 end
function GetPlayerIdentifier(src, i)  return 'license:test' .. tostring(src) end

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
-- SERVER-SIDE events are captured too, and the anticheat is why. Its whole
-- output is now one TriggerEvent -- it no longer notifies or drops anybody, so
-- there is nothing in `sent` to assert on and a test watching only client
-- traffic would pass while filing no incident at all.
local fired = {}
function TriggerEvent(event, ...)
    fired[#fired + 1] = { event = event, args = { ... } }
end
function TriggerClientEvent(event, target, ...)
    sent[#sent + 1] = { event = event, target = target, args = { ... } }
end
--- Server-side events of one name, in order.
local function firedOf(name)
    local out = {}
    for _, f in ipairs(fired) do
        if f.event == name then out[#out + 1] = f.args[1] end
    end
    return out
end
function RegisterNetEvent() end
function RegisterCommand() end

-- br_stats asks whether br_ddb is running before it records anything, and
-- answers 'not started' by doing nothing at all. Saying 'started' here is what
-- lets the match-history block below drive the real write path; every other
-- block is untouched, because the harness's TriggerEvent records events rather
-- than dispatching them, so br_stats' handler only ever runs when a test calls
-- fire() on it deliberately.
function GetResourceState() return 'started' end

-- Bare SetTimeout, as opposed to Citizen.SetTimeout above. br_stats uses it to
-- expire the callback it is holding for a pending DynamoDB answer; running the
-- timer would only delete bookkeeping the test wants to read.
function SetTimeout() end

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
    'br_lib/shared/sched.lua',   -- BR.Sched; br_core/server/* registers into it
    'br_lib/shared/identity.lua',-- BR.Identity; BR.Roster.ringmaster resolves licenses
    'br_lib/config/match.lua', 'br_lib/config/storm.lua', 'br_lib/config/map.lua',
    'br_lib/config/weapons.lua', 'br_lib/config/loot.lua',
    'br_lib/shared/storm_solve.lua',
    'br_lib/shared/loot_gen.lua',
    'br_lib/shared/combat_solve.lua',
    'br_lib/shared/evidence_buf.lua', -- BR.EvidenceBuf; server/evidence.lua wraps it
    'br_core/server/main.lua',
    'br_core/server/broadcast.lua',
    'br_core/server/roster.lua',
    'br_core/server/evidence.lua',    -- BR.Evidence; combat.lua notes kills into it
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
    -- AFTER combat_solve, whose enum values it keys its severity table on.
    'br_lib/shared/incident_build.lua',
    'br_core/server/incident.lua',     -- BR.Incident; listens to the refusal event
    -- AFTER incident.lua, because the report path asks BR.Incident whether a
    -- case about this player already exists before deciding to file one. It was
    -- loaded by nothing here until #143 put a rule in it worth pinning -- the
    -- report handler had no coverage at all, which is how "one report per
    -- target" could be wrong in a way only a playtest would find.
    'br_core/server/players.lua',      -- BR.Players; the list and the reports

    -- br_stats, LOADED INTO THE ROSTER SUITE ON PURPOSE (#153).
    --
    -- The match-history rows are derived from the same `br:match:results`
    -- payload the block above already asserts on, and testing them anywhere
    -- else would mean hand-building that payload -- which is precisely the
    -- fixture that stops catching anything the moment br_core changes the real
    -- one. Driving the consumer with the producer's actual output is the only
    -- version of this test worth having.
    --
    -- xp.lua and market.lua first: persist.lua reads BR.Xp for the curve and
    -- BR.Config.marketPayout for the Volts, and both are nil-guarded, so
    -- omitting either would produce a suite that passes while asserting zeroes.
    'br_lib/shared/xp.lua',
    'br_lib/config/market.lua',
    'br_stats/server/persist.lua',
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
    local mleave = theMatch()
    fire(BR.Net.MATCH_LEAVE, 2)
    local e = BR.Roster.get(2)
    ok(e.state == BR.PlayerState.LOBBY, 'the leaver is back in the lobby')

    -- THE PLACEMENT IS ON THE SEALED COPY NOW (#161), and that is where it has
    -- to be. This used to assert on the live entry -- where nothing ever read
    -- it: publishResults finds its rows by matchId, and leaving detaches this
    -- player's, so the placement sat on a roster entry as evidence of an
    -- elimination that could never be published. The same fact, moved somewhere
    -- that actually reaches DynamoDB.
    local sealed = BR.Roster.departedIn(mleave.id)[1]
    ok(sealed ~= nil, 'the leaver is sealed into the match they left (#161)')
    ok(sealed and sealed.placement ~= nil,
        'with a placement recorded, like any elimination',
        ('sealed placement %s'):format(tostring(sealed and sealed.placement)))
    ok(e.placement == nil and e.diedAt == nil,
        'and the live entry is wiped, so last match does not ride into the next one',
        ('placement %s diedAt %s'):format(tostring(e.placement), tostring(e.diedAt)))
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
    -- THE OBSERVATION IS UNCHANGED; WHAT IT MEANS IS NOT (#144). The line below
    -- used to read "a death during BUS is a real death" and it was the point of
    -- this block. It is now the opposite: the server still sees them go down --
    -- which is the original regression, and still covered -- but a death before
    -- the match reaches PLAYING is held rather than banked.
    ok(BR.Roster.get(2).state == BR.PlayerState.DEAD,
        'the server still observes a death during BUS')
    ok(BR.Roster.get(2).revivePending == true,
        'but it is HELD for the start rather than banked (#144)')
    ok(BR.Roster.get(2).diedAt == nil and BR.Roster.get(2).placement == nil,
        'and nothing a results row is built from was written',
        ('diedAt %s placement %s'):format(
            tostring(BR.Roster.get(2).diedAt),
            tostring(BR.Roster.get(2).placement)))

    -- The route runs out; player 1 is force-ejected and lands.
    fakeTime = r.tEnd + 600
    BR.Sched.step(fakeTime)
    fakeTime = mendsAt() + 1
    BR.Sched.step(fakeTime)
    ok(mstate() == BR.MatchState.PLAYING, 'the match goes live')
    ok(BR.Roster.get(2).state == BR.PlayerState.ALIVE,
        'and the hold is paid out: they are revived on the way in')
    ok(BR.Roster.get(2).revivePending == nil, 'with the flag cleared')
    ok(BR.Server.squadsAlive(theMatch()) == 2,
        'so both squads are standing and nothing has been won',
        tostring(BR.Server.squadsAlive(theMatch())))
    fire(BR.Net.DROP_LANDED, 1)

    -- And a death AFTER the start is exactly what it always was: banked in
    -- full, and the win condition sees it.
    fire(BR.Net.PLAYER_DIED, 2, { cause = 'fall' })
    ok(BR.Roster.get(2).diedAt ~= nil and BR.Roster.get(2).placement == 2,
        'a death once PLAYING is banked in full',
        ('diedAt %s placement %s'):format(
            tostring(BR.Roster.get(2).diedAt),
            tostring(BR.Roster.get(2).placement)))

    fakeTime = fakeTime + 4000   -- past WIN_GRACE_MS
    BR.Sched.step(fakeTime)
    ok(mstate() == BR.MatchState.ENDED,
        'and ends: the REAL death counted',
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
    ok(BR.Roster.get(2).state == BR.PlayerState.DEAD, 'a freefall death drops them too')
    ok(BR.Roster.get(2).revivePending == true, 'and is held just the same')

    fakeTime = r2.tEnd + 600
    BR.Sched.step(fakeTime)
    fakeTime = mendsAt() + 1
    BR.Sched.step(fakeTime)
    fire(BR.Net.DROP_LANDED, 1)
    ok(BR.Roster.get(2).state == BR.PlayerState.ALIVE,
        'the freefall death was undone as well')

    fire(BR.Net.PLAYER_DIED, 2, { cause = 'fall' })
    fakeTime = fakeTime + 4000
    BR.Sched.step(fakeTime)
    ok(mstate() == BR.MatchState.ENDED,
        'and the match still ends -- on the death that actually happened',
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

    -- THE MID-FLIGHT DEATH IS UNDONE, NOT COUNTED (#144). This used to end the
    -- match: the survivor landed, the state went live, and the win condition
    -- saw one squad standing off a death that happened before the match had
    -- started. Now the same landing revives the player it was going to finish.
    fire(BR.Net.DROP_LANDED, 1)
    fakeTime = fakeTime + 300
    BR.Sched.step(fakeTime)
    ok(mstate() == BR.MatchState.PLAYING,
        'the survivor landing takes it live')
    ok(BR.Roster.get(2).state == BR.PlayerState.ALIVE,
        'and the pre-match death is undone on the way in')
    fakeTime = fakeTime + 3100
    BR.Sched.step(fakeTime)
    ok(mstate() == BR.MatchState.PLAYING,
        'so nobody has won anything yet')

    -- Kill them again with the match live, and the win condition works exactly
    -- as it did -- which is what proves the revive restored a whole player and
    -- not a state string.
    pedHealth[1002] = 0
    for _ = 1, 6 do
        setPos(1, 150.0, 150.0, 25.0)
        setPos(2, 300.0, 300.0, 25.0)
        fakeTime = fakeTime + 250
        BR.Sched.step(fakeTime)
    end
    ok(BR.Roster.get(2).state == BR.PlayerState.DEAD,
        'a death once PLAYING is observed and kept')
    pedHealth[1002] = nil
    fakeTime = fakeTime + 3100
    BR.Sched.step(fakeTime)
    ok(mstate() == BR.MatchState.ENDED,
        'and last squad standing wins off THAT one')
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

    local endedIdx = nil
    for i, s in ipairs(sent) do
        if s.event == BR.Net.STATE
           and s.args[1].state == BR.MatchState.ENDED and not endedIdx then
            endedIdx = i
        end
    end
    ok(endedIdx ~= nil, 'STATE ended is on the wire')

    --- Where a player's trip-home delta appeared, or nil if it has not.
    local function lobbyDeltaFor(src)
        for i, s in ipairs(sent) do
            if s.event == BR.Net.ROSTER_DELTA then
                for _, d in ipairs(s.args[1].deltas or {}) do
                    if d.src == src and d.e
                       and d.e.state == BR.PlayerState.LOBBY then
                        return i
                    end
                end
            end
        end
        return nil
    end

    -- THE WORLD IS NOT TAKEN AWAY ON THE TRANSITION (#124).
    --
    -- The LOBBY flip is a teardown, not bookkeeping: it freezes the ped, moves
    -- the player out of the match's routing bucket -- so the car they were
    -- driving stops existing for them -- and stops the storm rendering. Doing
    -- it here did all three while the verdict slam was still playing over a
    -- live world, which is exactly what the owner reported: "the player should
    -- still be able to move during that point (but can't), any vehicle they
    -- were driving despawns for some reason... THEN it fades to black."
    ok(lobbyDeltaFor(1) == nil and lobbyDeltaFor(2) == nil,
        'nobody is swept home on the ENDED transition itself')

    -- ...it happens when the player's own screen says it has gone black.
    fire(BR.Net.MATCH_COVERED, 1)
    BR.Broadcast.flushNow()
    local covIdx = lobbyDeltaFor(1)
    ok(covIdx ~= nil and endedIdx < covIdx,
        'a covered client goes home, and still after the ENDED state event',
        ('ended at %s, lobby delta at %s'):format(
            tostring(endedIdx), tostring(covIdx)))
    ok(lobbyDeltaFor(2) == nil,
        'and only that client -- 48 screens go black at 48 different moments')

    -- AND THE ONE THAT NEVER ANSWERS STILL GOES HOME. A crashed client, a dead
    -- CEF, a dropped report: the deadline is the net, and it is why the
    -- handshake cannot strand anybody in a finished match.
    fakeTime = fakeTime + (BR.Config.Match.coverSweepMs or 8000) + 500
    BR.Sched.step(fakeTime)
    BR.Broadcast.flushNow()
    ok(lobbyDeltaFor(2) ~= nil,
        'a client that never reports is swept home on the deadline')
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
    -- AND THE MATCH IS LIVE, BECAUSE ITS PLAYERS ARE (#144).
    --
    -- This left the instance in WARMUP while forcing its players to ALIVE, which
    -- is a shape the real state machine cannot produce -- and it stopped being
    -- harmless when a death before PLAYING became a HELD death rather than a
    -- recorded one: every block that eliminates somebody through this fixture
    -- (attribution, the death box, evidence) was suddenly testing the revive
    -- path instead of the one it names. Written directly rather than through
    -- transition(): onEnter(PLAYING) starts the storm and ejects the bus, and
    -- none of these blocks asked for either.
    theMatch().state = BR.MatchState.PLAYING
    return theMatch()
end

--- Stand a player exactly on top of a ground entry.
local function standOn(src, e)
    BR.Roster.get(src).pos = { x = e.x, y = e.y, z = e.z }
end

--- Stand a player in the middle of a cell.
---
--- WHY THESE TESTS NOW HAVE TO POSITION BEFORE SUBSCRIBING. LOOT_CELL used to
--- accept any cell a client named, so a test could subscribe from anywhere and
--- several did. It now refuses a cell more than BR.LOOT_CELL_DRIFT from the
--- player's own sampled position, because accepting any cell let a client
--- enumerate the whole layout. Putting the player there first is not test
--- bookkeeping -- it is what a real client does, and the old ordering only worked
--- because the hole was there.
local function standInCell(src, cx, cy)
    local size = BR.Config.Loot.cellSize
    BR.Roster.get(src).pos = {
        x = (cx + 0.5) * size, y = (cy + 0.5) * size, z = 30.0,
    }
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

    standOn(1, first)
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

    -- Walking three cells away drops everything that was in scope. The player
    -- has to actually walk: a subscription three cells from where they are
    -- standing is refused outright now.
    standInCell(1, cx + 3, cy + 3)
    sent = {}
    fire(BR.Net.LOOT_CELL, 1, { cx = cx + 3, cy = cy + 3 })
    local goneIds = {}
    for _, s in ipairs(eventsOf(BR.Net.LOOT_GONE)) do
        for _, id in ipairs(s.args[1]) do goneIds[id] = true end
    end
    ok(goneIds[1], 'leaving the neighbourhood retires what was in it')

    -- A WARMUP player is not in the world yet. The pad is shared between
    -- matches, so streaming there would hand one match's items to another's.
    -- Stood in the cell on purpose, so the drift rule is satisfied and the ZONE
    -- rule is the only thing left that can refuse them. Otherwise this would
    -- pass for the wrong reason.
    BR.Roster.setState(2, BR.PlayerState.WARMUP)
    standOn(2, first)
    sent = {}
    fire(BR.Net.LOOT_CELL, 2, { cx = cx, cy = cy })
    ok(#eventsOf(BR.Net.LOOT_ADD) == 0, 'a warmup player is refused a subscription')
end

-- WHAT THIS BLOCK DEFENDS IS THE REASON THE LAYOUT SEED NEVER LEAVES THE BOX.
--
-- Two checks were missing and both were reachable from a modded client with no
-- timing, no luck and no other exploit: LOOT_CELL would subscribe you to any cell
-- you named, and LOOT_CLAIM never asked whether you had been streamed the entry
-- you were claiming. Together they turned "the client is only told about the cell
-- it stands in" into a statement about the honest client only.
describe('loot.enumeration')
do
    local m = lootMatch()
    local first = m.loot.items[1]
    local cx, cy = BR.LootCellOf(first.x, first.y)

    standOn(1, first)
    fire(BR.Net.LOOT_CELL, 1, { cx = cx, cy = cy })
    ok(m.loot.subs[1] ~= nil, 'a legitimate subscription is granted')
    local held = m.loot.at[1]

    -- The attack, in one call: name a cell on the other side of the map.
    sent = {}
    fire(BR.Net.LOOT_CELL, 1, { cx = cx + 40, cy = cy + 40 })
    ok(#eventsOf(BR.Net.LOOT_ADD) == 0,
        'a subscription to a distant cell streams nothing')
    ok(m.loot.at[1] == held,
        'and does not disturb the subscription they legitimately had')

    -- Nil position must fail closed. It is nil for a whole tick after joining,
    -- and "unknown" must not read as "anywhere".
    BR.Roster.get(2).pos = nil
    sent = {}
    fire(BR.Net.LOOT_CELL, 2, { cx = cx, cy = cy })
    ok(#eventsOf(BR.Net.LOOT_ADD) == 0,
        'a player with no position sample is refused, not trusted')

    -- THE ORACLE, which is the subtler half. If an entry outside the subscription
    -- refuses differently from an entry that never existed, the refusal text is an
    -- existence probe over a dense sequential id space -- four a second is enough
    -- to map what loot is left without going near any of it.
    local far
    for id = 1, m.loot.nextId do
        local e = m.loot.items[id]
        if e and not m.loot.subs[1][e.cell] then far = e break end
    end
    ok(far ~= nil, 'the layout has an entry this player was never streamed')

    local function claimText(id)
        sent = {}
        fire(BR.Net.LOOT_CLAIM, 1, { id = id })
        for _, s in ipairs(eventsOf(BR.Net.NOTIFY)) do
            if s.target == 1 then return s.args[1].text end
        end
        return nil
    end

    local unseen = claimText(far.id)
    local absent = claimText(m.loot.nextId + 9999)
    ok(unseen ~= nil and unseen == absent,
        'an unstreamed entry answers exactly like one that does not exist',
        tostring(unseen))
    ok(m.loot.items[far.id] ~= nil,
        'and refusing the claim did not consume the entry')
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
    standOn(1, target)
    standOn(2, target)
    fire(BR.Net.LOOT_CELL, 1, { cx = cx, cy = cy })
    fire(BR.Net.LOOT_CELL, 2, { cx = cx, cy = cy })

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
    --
    -- SUBSCRIBED BUT OUT OF REACH, which is the case this is actually about and
    -- which the old version of it reached by accident. Cells are 256m and the
    -- pickup radius is 7.5m, so "I can see it and cannot touch it" is the
    -- ordinary state of nearly everything in view. It is now a DIFFERENT refusal
    -- from a claim against an entry outside the subscription, which answers
    -- identically to an entry that is gone -- deliberately, so the two cannot be
    -- told apart by a client probing the id space.
    local far
    for id = 1, m.loot.nextId do
        local e = m.loot.items[id]
        if e and e.kind == BR.ItemKind.WEAPON then far = e break end
    end
    local fcx, fcy = BR.LootCellOf(far.x, far.y)
    standOn(1, far)
    fire(BR.Net.LOOT_CELL, 1, { cx = fcx, cy = fcy })
    -- Step 100m off it, staying well inside the 3x3 block just subscribed to.
    BR.Roster.get(1).pos = { x = far.x + 100.0, y = far.y, z = far.z }
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

describe('inv.defaultSlot')
do
    -- THE DEFAULT IS FISTS, AND THE FIRST GUN STILL COMES UP (#155).
    --
    -- Owner, 2026-08-16: "The default inventory slot should be fists, not slot
    -- 1." Landing holding something nobody drew takes the player's first action
    -- for them.
    --
    -- The whole difficulty of this change is in the SECOND half of this block.
    -- BR.Inv.give had one test doing two jobs -- `inv.active ~= MELEE_SLOT` meant
    -- both "your hand is empty" and "you deliberately holstered" -- because the
    -- only way to be on slot 0 was to put yourself there. Making fists the
    -- default breaks that identity, and a naive fix trades this bug for a worse
    -- one: a player standing on a rifle they cannot pick into their hands
    -- because they have never pressed a slot key. Both directions are pinned
    -- here, or the next person to touch that condition only finds out in a
    -- playtest.
    local m = lootMatch()
    local MELEE = BR.Config.Loot.meleeSlot or 0

    BR.Inv.reset(1)
    ok(BR.Inv.of(1).active == MELEE,
        'A FRESH INVENTORY IS ON FISTS, NOT SLOT 1 -- #155',
        ('active %s'):format(tostring(BR.Inv.of(1).active)))
    ok(BR.Inv.publicFor(1).active == MELEE,
        'and that is what goes out on the wire, so the bar draws the fist plate',
        ('active %s'):format(tostring(BR.Inv.publicFor(1).active)))

    -- Every restart path funnels through newInv(), which is the point of there
    -- being one: spawn (BR.Inv.of on first touch), a party leave and a respawn
    -- (BR.Inv.reset), a match reset (BR.Inv.clearFor).
    BR.Inv.give(1, { item = 'pistol', kind = BR.ItemKind.WEAPON, rarity = 1,
                     count = 1, clip = 12 })
    ok(BR.Inv.of(1).active == 1,
        'a first weapon into an empty hand still comes up in it',
        ('active %s'):format(tostring(BR.Inv.of(1).active)))
    BR.Inv.reset(1)
    ok(BR.Inv.of(1).active == MELEE,
        'and a reset puts the hand back to fists rather than to slot 1',
        ('active %s'):format(tostring(BR.Inv.of(1).active)))

    -- Armed first, or this asserts nothing: clearFor on an inventory that is
    -- already on fists passes however it is written.
    BR.Inv.give(1, { item = 'pistol', kind = BR.ItemKind.WEAPON, rarity = 1,
                     count = 1, clip = 12 })
    ok(BR.Inv.of(1).active == 1, 'armed again, so the next check has work to do')
    BR.Inv.clearFor(m)
    ok(BR.Inv.of(1).active == MELEE,
        'a match reset lands every player on fists too',
        ('active %s'):format(tostring(BR.Inv.of(1).active)))

    -- A DELIBERATE HOLSTER IS STILL A DELIBERATE HOLSTER. Somebody who pressed
    -- the fist key put their gun away on purpose, and walking over a rifle must
    -- not yank one back into their hands.
    BR.Inv.reset(1)
    BR.Inv.give(1, { item = 'pistol', kind = BR.ItemKind.WEAPON, rarity = 1,
                     count = 1, clip = 12 })
    fire(BR.Net.INV_SELECT, 1, { slot = MELEE })
    ok(BR.Inv.of(1).active == MELEE, 'the fist slot is selectable')
    BR.Inv.give(1, { item = 'sawnoff', kind = BR.ItemKind.WEAPON, rarity = 1,
                     count = 1, clip = 8 })
    ok(BR.Inv.of(1).active == MELEE,
        'a pickup does NOT override a hand emptied on purpose',
        ('active %s'):format(tostring(BR.Inv.of(1).active)))
    ok(BR.Inv.of(1).slots[2] and BR.Inv.of(1).slots[2].item == 'sawnoff',
        'though the weapon is still picked up into a free slot')

    -- ...and choosing a real slot and then coming back to fists reads the same
    -- as holstering straight away. `choseActive` is set for every selection, not
    -- only for slot 0, so this cannot regress into "only the first choice counts".
    BR.Inv.reset(1)
    BR.Inv.give(1, { item = 'pistol', kind = BR.ItemKind.WEAPON, rarity = 1,
                     count = 1, clip = 12 })
    fire(BR.Net.INV_SELECT, 1, { slot = 1 })
    fire(BR.Net.INV_SELECT, 1, { slot = MELEE })
    BR.Inv.give(1, { item = 'sawnoff', kind = BR.ItemKind.WEAPON, rarity = 1,
                     count = 1, clip = 8 })
    ok(BR.Inv.of(1).active == MELEE,
        'holstering after using a weapon is honoured just the same',
        ('active %s'):format(tostring(BR.Inv.of(1).active)))

    -- And the flag does not outlive the inventory it belongs to: a reset player
    -- is a player who has chosen nothing, so their next weapon comes up again.
    -- Without this, one holster would follow somebody into every later match.
    BR.Inv.reset(1)
    BR.Inv.give(1, { item = 'pistol', kind = BR.ItemKind.WEAPON, rarity = 1,
                     count = 1, clip = 12 })
    ok(BR.Inv.of(1).active == 1,
        'A RESET CLEARS THE CHOICE, so the next match arms normally -- #155',
        ('active %s'):format(tostring(BR.Inv.of(1).active)))
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

describe('combat.resync')
do
    -- THE PERMANENT CORPSE, and it was on the path that WORKED.
    --
    -- A player shot down to 7hp died on the SHOOTER'S screen and stayed a
    -- corpse there forever, while walking around alive on their own (user,
    -- 2026-08-09). CancelEvent stops the damage REPLICATING; it does not undo
    -- the copy GTA already applied locally on the shooter's machine before the
    -- server saw the shot. So the shooter's local ped carries GTA's number and
    -- the ledger carries ours -- recomputed from our tables, so a DIFFERENT
    -- number -- and they drift apart by the difference every single shot.
    --
    -- The refusal path had corrected this since 2026-08-08. The success path
    -- never did, which is the whole bug: refused shots looked right and landed
    -- shots did not.
    reset()
    queueUp(1, 'A', BR.Mode.SOLO.key)
    queueUp(2, 'B', BR.Mode.SOLO.key)
    fakeTime = fakeTime + 300
    BR.Sched.step(fakeTime)
    BR.Roster.setState(1, BR.PlayerState.ALIVE)
    BR.Roster.setState(2, BR.PlayerState.ALIVE)

    local pistol = BR.Config.WeaponById['pistol']
    BR.Inv.reset(1)
    BR.Inv.give(1, { item = 'pistol', kind = BR.ItemKind.WEAPON, rarity = 1,
                     count = 1, clip = pistol.clip })
    BR.Inv.of(1).ammo[BR.AmmoType.LIGHT] = 40
    BR.Inv.of(1).active = 1
    for s = 1, 2 do BR.Roster.get(s).pos = { x = s * 2.0, y = 0.0, z = 30.0 } end

    sent = {}
    fakeTime = fakeTime + 5000
    fire('weaponDamageEvent', 1, 1, {
        damageType = 3, weaponType = pistol.hash, hitComponent = 0,
        weaponDamage = 26, hitGlobalIds = { 1002 },
    })

    local feed = nil
    for _, s in ipairs(eventsOf(BR.Net.DAMAGE_FEED)) do
        if s.target == 1 then feed = s.args[1] end
    end
    ok(feed ~= nil, 'a landed shot feeds the shooter')
    ok(feed and feed.netId ~= nil,
        'and tells them WHICH ped their copy has wrong',
        feed and tostring(feed.netId) or 'nil')
    ok(feed and feed.hp ~= nil and feed.hp > 0,
        'and what its health really is, in engine units',
        feed and tostring(feed.hp) or 'nil')

    -- The number has to be the LEDGER's, not the client's, or correcting
    -- against it just re-applies the drift.
    local want = math.floor(BR.ToEngineHp(BR.Roster.get(2).hp) + 0.5)
    ok(feed and feed.hp == want,
        'and it is the ledger\'s number, not the shooter\'s',
        ('%s vs %s'):format(feed and tostring(feed.hp), tostring(want)))

    -- A KILL SENDS NO CORRECTION. Once the ledger says dead the corpse on the
    -- shooter's screen is right, and resurrecting it would be the bug.
    BR.Roster.get(2).hp = 1.0
    sent = {}
    fakeTime = fakeTime + 5000
    fire('weaponDamageEvent', 1, 1, {
        damageType = 3, weaponType = pistol.hash, hitComponent = 0,
        weaponDamage = 26, hitGlobalIds = { 1002 },
    })
    local killFeed = nil
    for _, s in ipairs(eventsOf(BR.Net.DAMAGE_FEED)) do
        if s.target == 1 then killFeed = s.args[1] end
    end
    ok(killFeed and killFeed.killed == true, 'a killing blow reads as a kill')
    ok(killFeed and killFeed.netId == nil,
        'and carries no correction -- that corpse is real',
        killFeed and tostring(killFeed.netId) or 'nil')
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
        return e and e.voiceProx or nil
    end

    --- Who this player's microphone has a direct line to, as the server last
    --- decided it. THE SQUAD ROOM IS GONE (#157): squadmates are addressed by
    --- server id, so the thing to sweep for collisions is this list rather
    --- than a channel number. It is cached on the entry as a sorted string
    --- because that is what the push dedups on.
    local function matesOf(src)
        local e = BR.Roster.get(src)
        local out = {}
        for n in tostring(e and e.voiceMates or ''):gmatch('%d+') do
            out[#out + 1] = tonumber(n)
        end
        return out
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

    -- SEPARATION BETWEEN SQUADS, NOW THAT A SQUAD IS A LIST AND NOT A ROOM
    -- (#157). The property is the same one the squad-channel sweep used to
    -- check and it has to be checked on the mechanism that actually ships: a
    -- player's radio list must contain their own squad and nobody else's, or
    -- two squads hear each other's plans at unlimited range.
    local strayMate, selfMate = nil, nil
    BR.Roster.each(
        function(e) return e.matchId == mA.id and e.squadId end,
        function(src, e)
            for _, other in ipairs(matesOf(src)) do
                if other == src then selfMate = src end
                local oe = BR.Roster.get(other)
                if not oe or oe.squadId ~= e.squadId then
                    strayMate = ('%d -> %d'):format(src, other)
                end
            end
        end)
    ok(strayMate == nil,
        'and nobody has a radio open to a player outside their own squad',
        strayMate)
    ok(selfMate == nil, 'and nobody has one open to themselves',
        tostring(selfMate))

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
    -- roster happens to produce. This sweeps every match id the scheme claims
    -- to support, which is what actually pins the lobby and warmup rooms clear
    -- of the match range: dropping matchBase onto lobbyChannel is a config
    -- edit nobody would notice until a lobby could hear a match.
    --
    -- IT USED TO SWEEP SQUAD ROOMS TOO, 64 matches by a stride of 16. There
    -- are no squad rooms any more (#157) -- a squad is a list of server ids,
    -- and the collision that list can have is checked live above, where it can
    -- actually happen, rather than in arithmetic.
    local proxSeen = {}
    local dupProx, cross = nil, nil
    local MATCHES = 64
    for mid = 1, MATCHES do
        local p = BR.Voice.proxChannel(mid, nil)
        if proxSeen[p] then dupProx = p end
        if p == V.lobbyChannel or p == V.warmupChannel then cross = p end
        proxSeen[p] = mid
    end

    ok(dupProx == nil, 'no two matches can ever share a proximity room',
        tostring(dupProx))
    ok(cross == nil,
        'and no match room is ever also the lobby or warmup room',
        tostring(cross))
    ok(not proxSeen[0], 'and nothing is ever assigned channel 0')
end

describe('voice.channels -- solos')
do
    -- EVERY ASSERTION ABOVE THIS LINE QUEUES BR.Mode.SQUAD.key. Not one of
    -- them had ever formed a solo match, and solo voice was broken from the
    -- day it shipped until #150 -- reported by the owner from a playtest, not
    -- by this file:
    --
    --   "when in solos, 'nearby' doesn't seem to work. It's just not passing
    --    any audio. I had 2 players in the same match next to each other,
    --    neither could hear."
    --
    -- The fault was on the CLIENT (tools/test_client.lua now covers it), and
    -- that is exactly why this block belongs here too: the first job when a
    -- report like that arrives is ruling the server out, and "the server has
    -- always assigned solos a proximity room" was a claim nobody could check
    -- without booting two game clients and standing them next to each other.
    local V = BR.Config.Match.voice

    reset()
    for s = 1, 4 do queueUp(s, 'S' .. s, BR.Mode.SOLO.key) end
    fakeTime = fakeTime + 300
    BR.Sched.step(fakeTime)

    local m1 = theMatch()
    ok(m1 ~= nil and m1.mode == BR.Mode.SOLO.key, 'a SOLO match formed',
        m1 and tostring(m1.mode) or 'no match')

    -- Out of warmup so the next ready-ups mint a second instance, exactly as
    -- the squad block above does.
    BR.Match.transition(m1, BR.MatchState.BUS)

    for s = 5, 8 do queueUp(s, 'T' .. s, BR.Mode.SOLO.key) end
    fakeTime = fakeTime + 300
    BR.Sched.step(fakeTime)
    local m2 = theMatch()
    ok(m2 ~= nil and m2.id ~= m1.id, 'and a second solo match alongside it')

    -- The 1Hz sweep is what actually pushes an assignment to somebody whose
    -- state changed on a path that forgot to push.
    fakeTime = fakeTime + 1200
    BR.Sched.step(fakeTime)

    -- A SOLO PLAYER HAS NO SQUAD, AND THAT MUST NOT COST THEM A ROOM.
    --
    -- Every channel in this scheme derives from matchId, and a solo player has
    -- one -- so there is no arithmetic reason for a solo to end up unassigned.
    -- Pinning it means a future change that keys assignment off squadId (the
    -- obvious shortcut, and the shape of the client bug) fails here instead of
    -- in a playtest.
    local assigned, inZero, gotSquad = 0, false, false
    local first = nil
    local shared = true
    BR.Roster.each(
        function(e) return e.matchId == m1.id end,
        function(_, e)
            if e.voiceProx then assigned = assigned + 1 end
            if not e.voiceProx or e.voiceProx == 0 then inZero = true end
            if e.voiceMates and e.voiceMates ~= '' then gotSquad = true end
            if e.squadId then gotSquad = true end
            first = first or e.voiceProx
            if e.voiceProx ~= first then shared = false end
        end)

    ok(assigned == 4, 'every solo player has a proximity room',
        ('%d of 4'):format(assigned))
    ok(not inZero, 'and none of them is left in the default channel 0')
    ok(shared, 'and everyone in one solo match shares exactly one room',
        tostring(first))
    ok(not gotSquad,
        'and a solo has no squad radio -- there is no squad to open one to')

    local other = nil
    BR.Roster.each(
        function(e) return e.matchId == m2.id end,
        function(_, e) other = other or e.voiceProx end)
    ok(other ~= nil and first ~= nil and other ~= first,
        'while two solo matches are never in the same room',
        ('%s vs %s'):format(tostring(first), tostring(other)))

    -- AND IT IS ACTUALLY SENT. The roster fields above are the server's own
    -- bookkeeping; a player only ends up in a room because VOICE_SET reached
    -- their client carrying a number. This project has shipped correct,
    -- fully-connected code that emitted to nobody often enough to check.
    local delivered = {}
    for _, s in ipairs(sent) do
        if s.event == BR.Net.VOICE_SET and type(s.args[1]) == 'table' then
            delivered[s.target] = s.args[1]
        end
    end
    local p1 = delivered[1]
    ok(p1 ~= nil, 'and a VOICE_SET actually reached a solo player')
    ok(p1 and p1.prox == first,
        'carrying the proximity room the roster says they are in',
        p1 and tostring(p1.prox) or 'nothing')
    ok(p1 and type(p1.mates) == 'table' and #p1.mates == 0,
        'and an empty squad list -- a solo has nobody to open a radio to',
        p1 and type(p1.mates) == 'table' and ('%d'):format(#p1.mates) or 'nothing')

    -- THE RANGES ARE PART OF THE CONTRACT (#157).
    --
    -- The client falls back to config when these are missing, which means a
    -- server that stopped sending them would look fine and behave fine right
    -- up until the two sides' config drifted. More to the point: for a week
    -- nothing anywhere sent a range at all and voice carried across the whole
    -- map, so "a number arrived" is exactly the assertion that was missing.
    ok(p1 and type(p1.nearbyRange) == 'number' and p1.nearbyRange > 0,
        'and a proximity range to apply',
        p1 and tostring(p1.nearbyRange) or 'nothing')
    ok(p1 and type(p1.squadRange) == 'number'
        and p1.squadRange > p1.nearbyRange,
        'and a squad range, which must be the LONGER of the two -- squad voice '
        .. 'that cuts out at proximity range is not squad voice',
        p1 and ('%s vs %s'):format(tostring(p1.squadRange),
                                   tostring(p1.nearbyRange)) or 'nothing')
    ok(p1 and p1.prox ~= V.lobbyChannel and p1.prox ~= V.warmupChannel,
        'which is neither the lobby room nor the warmup room')
end

describe('voice.squad roster -- #157')
do
    -- THE PAYLOAD THAT REPLACED THE SQUAD ROOM. A squad channel was one
    -- integer and its correctness was arithmetic; a squad roster is a list of
    -- server ids and its correctness is membership, so it is checked here on a
    -- real match rather than swept over an id space.
    reset()
    for s = 1, 4 do queueUp(s, 'S' .. s, BR.Mode.SQUAD.key) end
    fakeTime = fakeTime + 300
    BR.Sched.step(fakeTime)
    local m = theMatch()
    ok(m ~= nil, 'a squad match formed')

    fakeTime = fakeTime + 1200
    BR.Sched.step(fakeTime)

    local delivered = {}
    for _, s in ipairs(sent) do
        if s.event == BR.Net.VOICE_SET and type(s.args[1]) == 'table' then
            delivered[s.target] = s.args[1]
        end
    end

    local anyMates, selfListed, mutual = false, false, true
    for src, payload in pairs(delivered) do
        local e = BR.Roster.get(src)
        for _, other in ipairs(payload.mates or {}) do
            anyMates = true
            if other == src then selfListed = true end
            -- SQUAD VOICE HAS TO BE SYMMETRIC or one player can hear the other
            -- and not the reverse, which reads in game as "my mic is broken"
            -- and is impossible to diagnose from one machine.
            local back = false
            for _, mine in ipairs((delivered[other] or {}).mates or {}) do
                if mine == src then back = true end
            end
            if not back then mutual = false end
            local oe = BR.Roster.get(other)
            if not oe or not e or oe.squadId ~= e.squadId then mutual = false end
        end
    end
    ok(anyMates, 'a squad player is told who their squadmates are')
    ok(not selfListed, 'and is never told about themselves')
    ok(mutual,
        'and every radio link is mutual and inside one squad -- a one-way link '
        .. 'reads in game as a broken microphone')
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
    local R = BR.ShotRefusal
    BR.Damage.forgetRefusals(1)

    -- THE BAR IS PER REASON AND PER MATCH (owner call, 2026-08-14). There is no
    -- `refusalLimit` and no rolling window any more: the old rule wanted eight
    -- countable refusals inside ten seconds, which described somebody spraying
    -- with a trainer and missed anybody patient. One impossible hit every eleven
    -- seconds, all match, every match, filed nothing and left no trace.
    ok(cfg.refusalLimit == nil,
        'there is no single refusalLimit left to tune',
        tostring(cfg.refusalLimit))
    ok(type(cfg.refusalBar) == 'table' and cfg.refusalBar.high == 1
        and cfg.refusalBar.normal == 2,
        'the bar is one for high and two for normal')

    -- ONE HIGH REFUSAL IS ENOUGH. There is no honest path to a weapon the server
    -- did not put in your hands, so there was never a reason to demand eight.
    fired = {}
    sent = {}
    BR.Damage.noteRefusal(1, R.NOT_HELD)
    ok(#firedOf('br:ringmaster:refusal') == 1,
        'a single high-tier refusal files exactly one case',
        tostring(#firedOf('br:ringmaster:refusal')))

    -- NOTHING REACHES THE PLAYER. Not a notice, not a hint. The offender used
    -- to be told their shots were not landing, which is free tuning feedback
    -- for whoever is testing a trainer (owner call, 2026-08-14).
    ok(#sent == 0, 'and the offender is told nothing at all', tostring(#sent))

    -- REPORTS DOUBLE, THEY DO NOT STREAM. Holding the trigger down must not put
    -- one event per refused shot onto a 512-deep drop-oldest queue -- that
    -- destroys the player_seen stream behind it to say the same thing fifty
    -- times. After the crossing at 1, the next reports are at 2, 4, 8, 16 and 32.
    fired = {}
    for _ = 1, 49 do BR.Damage.noteRefusal(1, R.NOT_HELD) end
    local ladder = #firedOf('br:ringmaster:refusal')
    ok(ladder == 5,
        'fifty refusals report five more times, not fifty -- 2,4,8,16,32',
        tostring(ladder))

    -- The sequence number is what lets a receiver notice a lost corroboration:
    -- the event channel drops batches silently and says so nowhere.
    local seqs = {}
    for _, evt in ipairs(firedOf('br:ringmaster:refusal')) do
        seqs[#seqs + 1] = evt.seq
    end
    ok(seqs[1] == 2 and seqs[#seqs] == 6,
        'each report carries its own sequence number for this match',
        table.concat(seqs, ','))

    -- THE COUNT NO LONGER LAPSES. Under the old rule this was where a fresh
    -- window started clean; now only leaving the match or disconnecting resets it.
    BR.Damage.forgetRefusals(1)
    fired = {}
    BR.Damage.noteRefusal(1, R.TOO_FAR)
    ok(#firedOf('br:ringmaster:refusal') == 0,
        'one out-of-range shot is a bad tick and files nothing')
    BR.Damage.noteRefusal(1, R.TOO_FAR)
    ok(#firedOf('br:ringmaster:refusal') == 1,
        'the second one, whenever it comes, is a pattern')

    -- THE SERVER DECIDES NOTHING ABOUT THE PLAYER. `refusalAction` is gone: a
    -- convar naming an enforcement action would describe a decision this side
    -- no longer makes. The firing reports what it actually did -- filed a case.
    ok(cfg.refusalAction == nil,
        'there is no configurable enforcement action left in br_core',
        tostring(cfg.refusalAction))

    BR.Damage.forgetRefusals(1)
    fired = {}
    BR.Damage.noteRefusal(1, R.NO_AMMO)
    local ev = firedOf('br:ringmaster:refusal')[1]
    ok(ev ~= nil, 'the firing reaches the Ringmaster feed')
    if ev then
        ok(ev.action == 'incident', 'and says it filed an incident',
            tostring(ev.action))
        ok(ev.reason == R.NO_AMMO, 'carrying the reason', tostring(ev.reason))
        ok(ev.count == 1, 'and the count that tripped it', tostring(ev.count))
        -- CARRIED, NOT RECOMPUTED. Two traversals of the same tally in two files
        -- is two chances to disagree about which reason graded the case.
        ok(ev.severity == 'high', 'with the severity the bar was tested against',
            tostring(ev.severity))
        ok(ev.seq == 1, 'and the first report of this match', tostring(ev.seq))
        -- Identity must be on the event. Server ids recycle within the minute,
        -- so a case keyed on `src` is a case about whoever holds that slot next.
        ok(ev.license ~= nil, 'and a license rather than only a server id',
            tostring(ev.license))
    end

    -- RULES ARE NOT CHEATING, and fists are what made this matter: every
    -- player has them at all times, so a warmup scrap or a squadmate caught in
    -- a spray produces refusals by the dozen. Counting those means the
    -- threshold fires on ordinary play.
    BR.Damage.forgetRefusals(1)
    fired = {}
    for _ = 1, 30 do
        BR.Damage.noteRefusal(1, R.NOT_LIVE)
        BR.Damage.noteRefusal(1, R.SAME_SQUAD)
    end
    ok(#firedOf('br:ringmaster:refusal') == 0,
        'punching in warmup and hitting a squadmate never file an incident',
        tostring(#firedOf('br:ringmaster:refusal')))

    -- SELF IS RECORDED AND NO LONGER COUNTED (owner call, 2026-08-14).
    --
    -- It used to count toward the eight without earning severity, because mixing
    -- self-harm with real refusals must not keep somebody under the bar. At a bar
    -- of one or two that reasoning inverts: one self-hit beside one marginal
    -- out-of-range shot would open a case, and a player could manufacture one
    -- against themselves by standing in their own grenades. So it now files
    -- nothing at any quantity, and the decline is in BR.ShotTier, which has no
    -- entry for it.
    BR.Damage.forgetRefusals(1)
    fired = {}
    for _ = 1, 40 do BR.Damage.noteRefusal(1, R.SELF) end
    ok(#firedOf('br:ringmaster:refusal') == 0,
        'forty self-inflicted hits file nothing at all',
        tostring(#firedOf('br:ringmaster:refusal')))

    -- ...and self-harm cannot carry a real reason over its own bar either, which
    -- is the case the old count-everything threshold would have filed.
    BR.Damage.forgetRefusals(1)
    fired = {}
    for _ = 1, 20 do BR.Damage.noteRefusal(1, R.SELF) end
    BR.Damage.noteRefusal(1, R.NO_WEAPON)
    ok(#firedOf('br:ringmaster:refusal') == 0,
        'twenty self-hits plus one unknown weapon is still under the bar')
    BR.Damage.noteRefusal(1, R.NO_WEAPON)
    ok(#firedOf('br:ringmaster:refusal') == 1,
        'the second unknown weapon is what files it')

    -- THE TALLY REACHES THE CASE, including the reasons that count for nothing --
    -- an admin reading it wants to see the self-harm, it just must not grade it.
    local mixEv = firedOf('br:ringmaster:refusal')[1]
    ok(mixEv and mixEv.reasons[R.SELF] == 20,
        'the self-hits are still on the record',
        mixEv and tostring(mixEv.reasons[R.SELF]) or 'no event')
    ok(mixEv and mixEv.count == 2,
        'while the counted total is only the two that graded it',
        mixEv and tostring(mixEv.count) or 'no event')
    ok(mixEv and mixEv.severity == 'high', 'and it is filed as high',
        mixEv and tostring(mixEv.severity) or 'no event')

    BR.Damage.forgetRefusals(1)
end

describe('evidence.wiring')
do
    -- THE PURE BOOKKEEPING IS COVERED IN test_shared. What is covered here is
    -- the part that only exists inside the game: whether the events actually
    -- reach the buffer, and whether the lifecycle hooks fire on paths that
    -- really run.
    local m = lootMatch()
    BR.Evidence.buf:clearMatch(nil)

    ok(BR.Evidence ~= nil, 'BR.Evidence loads')
    ok(BR.Evidence.stats().live == 0, 'and starts with nothing held')

    -- A kill reaches BOTH participants' records. Recorded off the same feed
    -- table the clients get, so the record cannot drift from what was shown.
    BR.Damage.lastHit = nil
    -- (src, cause, killerSrc) -- 2 is killed by 1.
    BR.Combat.eliminate(2, 'headshot', 1)

    local licA = BR.Identity.qualified('license', BR.Identity.licenseOf(1))
    local licB = BR.Identity.qualified('license', BR.Identity.licenseOf(2))
    local killer = BR.Evidence.forLicense(licA)
    local victim = BR.Evidence.forLicense(licB)
    ok(#killer == 1 and #killer[1].kills == 1,
        'the killer gets the elimination on their record',
        tostring(#killer))
    ok(#victim == 1 and #victim[1].kills == 1,
        'and so does the victim -- their own deaths are evidence too',
        tostring(#victim))
    ok(killer[1].matchId == m.id, 'tagged with the match it happened in',
        tostring(killer[1].matchId))

    -- LOBBY ACTIVITY IS NOT EVIDENCE. A player with no matchId is not in a
    -- match, and holding the whole server's between-match small talk would be
    -- memory spent on something no reviewer will ever open.
    BR.Evidence.buf:clearMatch(nil)
    BR.Roster.setMatch(1, nil)
    BR.Evidence.noteChat(1, { text = 'in the lobby', channel = 0, at = 1 })
    ok(BR.Evidence.stats().chatRows == 0, 'nothing is held outside a match',
        tostring(BR.Evidence.stats().chatRows))

    -- DISCONNECT SEALS RATHER THAN FREES, which is what makes "caused hell then
    -- left" reportable at all.
    local m2 = lootMatch()
    BR.Evidence.buf:clearMatch(nil)
    BR.Evidence.noteChat(1, { text = 'gg ez', channel = 0, at = 10 })
    ok(BR.Evidence.stats().chatRows == 1, 'a message in a match is held')

    fire('playerDropped', 1)
    ok(BR.Evidence.stats().live == 0, 'their live record is gone')
    ok(BR.Evidence.stats().sealed == 1, 'but it was sealed, not freed')
    local gone = BR.Evidence.forLicense(licA)
    ok(#gone == 1 and gone[1].chat[1].text == 'gg ez',
        'so their chat survives them leaving')
    ok(#BR.Evidence.departed(m2.id) == 1,
        'and they are still listed as a departed player of that match')

    -- MATCH TEARDOWN IS THE DISCARD, and it must be on the path that always
    -- runs. br:match:results returns early when nobody scored, so a match that
    -- ended empty would leak; destroy is the only way out of the registry.
    --
    -- Both halves are asserted separately because this harness's TriggerEvent
    -- records rather than dispatches: that destroy ANNOUNCES the teardown, and
    -- that the handler ACTS on the announcement. Testing only one would leave
    -- either a signal nobody hears or a listener nothing calls.
    fired = {}
    BR.Match.destroy(m2)
    local announced = firedOf('br:match:destroyed')[1]
    ok(announced ~= nil and announced.matchId == m2.id,
        'destroying a match announces it, with the id',
        announced and tostring(announced.matchId) or 'nothing announced')

    fire('br:match:destroyed', nil, { matchId = m2.id })
    local after = BR.Evidence.stats()
    ok(after.live == 0 and after.sealed == 0 and after.chatRows == 0,
        'and the announcement discards everything that match held',
        ('live %d sealed %d chat %d'):format(after.live, after.sealed, after.chatRows))
end

describe('incident.wiring')
do
    -- THE CLASSIFIER AND THE PAYLOAD SHAPE ARE COVERED IN test_shared. What is
    -- covered here is the part that only exists inside the game: that the refusal
    -- event actually reaches the writer, that the writer reads the real evidence
    -- buffer, and that what leaves br_core is a payload br_ringmaster can send.
    local m = lootMatch()
    BR.Evidence.buf:clearMatch(nil)
    BR.Damage.forgetRefusals(1)

    local licA = BR.Identity.qualified('license', BR.Identity.licenseOf(1))

    -- Something for the case to carry, so "the evidence is attached" is a real
    -- assertion rather than an empty list matching an empty list.
    BR.Evidence.noteChat(1, { text = 'nothing to see here', channel = 0, at = 5 })

    fired = {}
    -- Two, because NO_WEAPON is the catch-all bucket and carries a bar of 2 --
    -- see BR.ShotBarOverride. The other high reasons file on the first one.
    BR.Damage.noteRefusal(1, BR.ShotRefusal.NO_WEAPON)
    BR.Damage.noteRefusal(1, BR.ShotRefusal.NO_WEAPON)

    -- The harness records TriggerEvent rather than dispatching it, so the two
    -- halves are driven separately -- the same split the evidence teardown test
    -- uses. First: damage.lua announced the firing.
    local refusal = firedOf('br:ringmaster:refusal')[1]
    ok(refusal ~= nil, 'the threshold announces a refusal')
    ok(refusal and refusal.reasons ~= nil,
        'carrying the per-reason tally the classifier needs')
    ok(refusal and refusal.reasons[BR.ShotRefusal.NO_WEAPON] == 2,
        'with every countable shot in it',
        refusal and tostring(refusal.reasons[BR.ShotRefusal.NO_WEAPON]) or 'nil')

    -- Second: the writer acts on the announcement. `sent` is cleared too, because
    -- it accumulates across the whole suite -- asserting on it without this
    -- measures every earlier block's client traffic instead of this one's.
    fired = {}
    sent = {}
    fire('br:ringmaster:refusal', nil, refusal)
    local inc = firedOf('br:ringmaster:incident')[1]

    ok(inc ~= nil, 'and the writer turns it into an incident payload')
    if inc then
        ok(inc.kind == 'anticheat', 'filed as an anticheat case', tostring(inc.kind))
        ok(inc.severity == 'high',
            'at the severity the reason earns', tostring(inc.severity))
        ok(inc.subjectLicense == licA,
            'about the license, not the server id', tostring(inc.subjectLicense))
        ok(inc.matchId == m.id, 'in the match it happened in', tostring(inc.matchId))
        ok(inc.state == 'pending_review',
            'open for review -- br_core never resolves anything')

        -- THE EVIDENCE IS ATTACHED AT FILING TIME, not fetched later. The buffer
        -- is discarded at match end, so "we will look it up when an admin opens
        -- the case" is a promise this system cannot keep.
        ok(#inc.evidence == 1, 'with the evidence buffer attached',
            tostring(#inc.evidence))
        ok(inc.evidence[1] and inc.evidence[1].chat[1]
            and inc.evidence[1].chat[1].text == 'nothing to see here',
            'including what they actually said')

        -- NOTHING WAS SENT TO THE PLAYER. The whole point of the inversion: an
        -- offender learns nothing, ever, at any stage.
        ok(#sent == 0, 'and the offender is told nothing at all', tostring(#sent))
    end

    -- CORROBORATION, AND IT APPENDS RATHER THAN FILING (owner call, 2026-08-14).
    --
    -- A second thing happening to the same player in the same match must not open
    -- a second case. It hands an admin the same conclusion twice, and it lets one
    -- persistent cheater bury a queue that is meant to be a shrinking worklist.
    -- Appending to the case they already have says the thing a second row cannot:
    -- it is still happening and nobody has acted.
    ok(#BR.Incident.priorFor(m.id, licA) == 0, 'nothing is remembered before a write lands')

    fire('br:incident:filed', nil,
        { incidentId = 'inc-1', matchId = m.id, subjectLicense = licA })
    local prior = BR.Incident.priorFor(m.id, licA)
    ok(#prior == 1 and prior[1] == 'inc-1',
        'a confirmed write is remembered for the rest of the match',
        tostring(#prior))

    fired = {}
    BR.Damage.forgetRefusals(1)
    BR.Damage.noteRefusal(1, BR.ShotRefusal.NO_AMMO)
    local second = firedOf('br:ringmaster:refusal')[1]
    fired = {}
    fire('br:ringmaster:refusal', nil, second)

    ok(#firedOf('br:ringmaster:incident') == 0,
        'a second firing files no second case',
        tostring(#firedOf('br:ringmaster:incident')))

    local corr = firedOf('br:ringmaster:corroborate')[1]
    ok(corr ~= nil, 'it corroborates instead')
    if corr then
        ok(corr.incidentId == 'inc-1', 'naming the case it belongs to',
            tostring(corr.incidentId))
        ok(corr.license == licA, 'and the player it is about', tostring(corr.license))
        -- The tally travels so the appended note can say what has happened SINCE,
        -- not merely that something did.
        ok(corr.reasons ~= nil and corr.count ~= nil,
            'carrying the running count and tally')
        -- A sequence number is the only way a receiver can notice a LOST
        -- corroboration: this channel drops batches after four attempts and
        -- neither envelope says so.
        ok(corr.seq ~= nil, 'and a sequence number, so a gap is detectable',
            tostring(corr.seq))
    end

    -- A REFUSAL WITH NO LICENSE FILES NOTHING. Server ids recycle within the
    -- minute, so a case keyed on one is a case about whoever holds that slot
    -- next -- and it cannot be withdrawn once a human has read it.
    fired = {}
    fire('br:ringmaster:refusal', nil, {
        src = 99, name = 'Ghost', matchId = m.id, count = 8, windowMs = 10000,
        reason = BR.ShotRefusal.NO_WEAPON,
        reasons = { [BR.ShotRefusal.NO_WEAPON] = 8 },
        action = 'incident', at = 1000,
    })
    ok(#firedOf('br:ringmaster:incident') == 0,
        'a refusal with no license files nothing rather than naming a stranger')

    -- TEARDOWN DROPS THE MAP, on the same hook the evidence buffer uses -- so it
    -- stays the size of the running matches rather than of the server's uptime.
    fire('br:match:destroyed', nil, { matchId = m.id })
    ok(#BR.Incident.priorFor(m.id, licA) == 0,
        'and the cross-reference map is dropped when the match is')

    BR.Damage.forgetRefusals(1)
end

describe('report.rules')
do
    -- ONE REPORT PER (REPORTER, TARGET, MATCH), AND WHAT THE SECOND ONE DOES
    -- INSTEAD (#143).
    --
    -- The owner's sentence is the whole specification: "Reporting the same
    -- player twice is possible in the same match by the same reporter - this
    -- should not be possible, and any future reports during the same match from
    -- other reporters to the same target should be corroborated per our
    -- existing corroboration code."
    --
    -- So there are two different answers to "somebody has already been reported
    -- for this", and which one applies depends on WHO is asking. Getting that
    -- backwards is invisible from a chair -- both look like "my report went
    -- through" from the panel, and the difference only shows up as an extra row
    -- in a queue nobody is watching yet -- which is exactly why it is asserted
    -- here rather than left to a playtest.
    --
    -- THE PANEL IS NOT INVOLVED IN ANY OF THIS. Every rule it appears to
    -- enforce is enforced again on this side; these tests drive the net event
    -- directly, which is what a modified client would do.
    local function lastResult()
        for i = #sent, 1, -1 do
            if sent[i].event == BR.Net.REPORT_RESULT then return sent[i].args[1] end
        end
        return nil
    end

    local function threeUp()
        reset()
        queueUp(1, 'Ayla', BR.Mode.SOLO.key)
        queueUp(2, 'Bex',  BR.Mode.SOLO.key)
        queueUp(3, 'Cass', BR.Mode.SOLO.key)
        fakeTime = fakeTime + 300
        BR.Sched.step(fakeTime)
        for _, s in ipairs({ 1, 2, 3 }) do
            BR.Roster.setState(s, BR.PlayerState.ALIVE)
        end
        return theMatch()
    end

    local m = threeUp()
    local licB = BR.Identity.qualified('license', BR.Identity.licenseOf(2))

    -- THE CATEGORY LIST IS THE OWNER'S, EXACTLY. Asserted by name rather than by
    -- count, because the failure worth catching is a category that survived a
    -- rename -- a row filed under `teaming` is a row no console filter for the
    -- new list will ever return.
    do
        local want = { 'cheating', 'abusive_chat', 'exploiting', 'power_gaming', 'other' }
        local got = {}
        for _, c in ipairs(BR.Config.Report.categories) do got[#got + 1] = c.id end
        ok(table.concat(got, ',') == table.concat(want, ','),
            'the categories are exactly the five asked for, in order',
            table.concat(got, ','))
        ok(BR.Config.isReportCategory('power_gaming'),
            'and the validator accepts the new one')
        ok(not BR.Config.isReportCategory('teaming'),
            'and refuses the one that was removed')
        ok(BR.Config.defaultReportCategory() == 'cheating',
            'the pre-selected category is still cheating',
            tostring(BR.Config.defaultReportCategory()))
        -- The note went in #142 and the cap went with it. A cap left behind
        -- would be the only surviving evidence of a field nothing sends.
        ok(BR.Config.Report.maxNote == nil,
            'and no note cap survives the field it capped')
    end

    -- A FIRST REPORT OPENS A CASE.
    fired, sent = {}, {}
    fire(BR.Net.REPORT_SUBMIT, 1, {
        targets = { { src = 2, category = 'power_gaming' } },
    })

    local inc = firedOf('br:ringmaster:incident')[1]
    ok(inc ~= nil, 'a report files an incident')
    if inc then
        ok(inc.kind == 'report', 'as a report, not an anticheat case', tostring(inc.kind))
        ok(inc.category == 'power_gaming',
            'carrying the category that was picked', tostring(inc.category))
        ok(inc.subjectLicense == licB,
            'about the license, never the server id', tostring(inc.subjectLicense))
        ok(inc.reporterLicense ~= nil,
            'and naming the reporter, which is what makes report-spam visible')
        -- br_ddb writes `note: null` unconditionally and has since 2026-08-14,
        -- so a note here was always a string on its way to being discarded.
        ok(inc.note == nil, 'with no free-text note anywhere on it')
    end
    ok((lastResult() or {}).ok == true, 'and the reporter is told it worked')

    -- THE SAME REPORTER, THE SAME TARGET, AGAIN: refused, and it files nothing
    -- by either route. Corroborating this one would be worse than filing it --
    -- it would let one player inflate the "how many people have said this"
    -- number on their own.
    fired, sent = {}, {}
    fire(BR.Net.REPORT_SUBMIT, 1, {
        targets = { { src = 2, category = 'cheating' } },
    })
    ok(#firedOf('br:ringmaster:incident') == 0,
        'reporting the same player twice opens no second case',
        tostring(#firedOf('br:ringmaster:incident')))
    ok(#firedOf('br:ringmaster:corroborate') == 0,
        'and does not corroborate their own report either')

    local refused = lastResult()
    ok(refused ~= nil and refused.ok == false, 'the reporter is refused')
    -- NAMED. "That report could not be sent" over a five-name selection is a
    -- refusal the player cannot act on: only the server knows which row to
    -- untick.
    ok(refused and tostring(refused.refused):find('Bex', 1, true) ~= nil,
        'and told which player they had already reported',
        refused and tostring(refused.refused) or 'nil')

    -- IT IS PER TARGET, NOT PER MATCH. Spending the rule on one player must not
    -- cost the reporter everybody else.
    fired, sent = {}, {}
    fire(BR.Net.REPORT_SUBMIT, 1, {
        targets = { { src = 3, category = 'cheating' } },
    })
    ok(#firedOf('br:ringmaster:incident') == 1,
        'the same reporter can still report a different player',
        tostring(#firedOf('br:ringmaster:incident')))

    -- The case about Bex becomes durable. This is br_ringmaster acknowledging
    -- the DynamoDB write, and it is what makes corroboration possible at all --
    -- until it lands there is no id to append to.
    fire('br:incident:filed', nil,
        { incidentId = 'inc-report-1', matchId = m.id, subjectLicense = licB })

    -- A DIFFERENT REPORTER, THE SAME TARGET: corroborates rather than opening a
    -- second case. This is the pairing the whole feature exists to produce --
    -- two strangers independently naming the same player -- and it says so on
    -- the case that already exists, because a queue is a shrinking worklist and
    -- one offender must not be able to bury it.
    fired, sent = {}, {}
    fire(BR.Net.REPORT_SUBMIT, 3, {
        targets = { { src = 2, category = 'exploiting' } },
    })
    ok(#firedOf('br:ringmaster:incident') == 0,
        'a second reporter opens no second case about the same player',
        tostring(#firedOf('br:ringmaster:incident')))

    local corr = firedOf('br:ringmaster:corroborate')[1]
    ok(corr ~= nil, 'it corroborates the existing one instead')
    if corr then
        ok(corr.incidentId == 'inc-report-1',
            'naming the case it belongs to', tostring(corr.incidentId))
        ok(corr.license == licB, 'and the player it is about', tostring(corr.license))
        -- STARTS AT 2, whatever opened the case. br_ringmaster's contract for
        -- this field is "report 1 is the case", and it is what lets the console
        -- tell 1, 2, 4 with a gap in it -- a corroboration the outbox dropped
        -- and told nobody about -- from a match where nothing more happened.
        ok(corr.seq == 2, 'with the first corroboration numbered 2',
            tostring(corr.seq))
        ok(corr.count == 2, 'and the number of people who have now said it',
            tostring(corr.count))
        ok(corr.reason == 'exploiting',
            'carrying the category the second reporter picked', tostring(corr.reason))
    end

    -- AND THE SECOND REPORTER LEARNS NOTHING FROM IT. "Your report was added to
    -- an existing case" would tell a player that whoever they just named is
    -- already under review, which is precisely what an offender's friend would
    -- go looking for. Both answers are the same answer.
    local ok2 = lastResult()
    ok(ok2 ~= nil and ok2.ok == true and ok2.filed == 1,
        'and is told exactly what the first reporter was told',
        ok2 and tostring(ok2.filed) or 'nil')

    -- The rule applies to them too.
    fired, sent = {}, {}
    fire(BR.Net.REPORT_SUBMIT, 3, {
        targets = { { src = 2, category = 'cheating' } },
    })
    ok(#firedOf('br:ringmaster:corroborate') == 0,
        'the second reporter cannot corroborate their own corroboration')
    ok((lastResult() or {}).ok == false, 'and is refused in turn')

    -- ONE SUBMISSION NAMING AN ALREADY-REPORTED PLAYER IS REFUSED WHOLE, rather
    -- than filing the rest quietly. A partial file has no honest answer: "1
    -- report sent" hides the refusal, and the panel has one toast.
    fired, sent = {}, {}
    fire(BR.Net.REPORT_SUBMIT, 3, {
        targets = {
            { src = 1, category = 'cheating' },      -- never reported by Cass
            { src = 2, category = 'cheating' },      -- already reported by Cass
        },
    })
    ok(#firedOf('br:ringmaster:incident') == 0
       and #firedOf('br:ringmaster:corroborate') == 0,
        'a submission containing a repeat files none of itself')
    ok((lastResult() or {}).ok == false, 'and is refused as a whole')

    -- THE RULE IS PER MATCH, WHICH IS THE POINT OF IT. Somebody who cheats in
    -- three consecutive rounds is three things worth telling an admin about,
    -- and a rule that outlived its match would be a permanent ban on ever
    -- reporting the same person twice.
    fire('br:match:destroyed', nil, { matchId = m.id })

    local m2 = threeUp()
    ok(m2.id ~= m.id, 'the next match is a different match', tostring(m2.id))

    fired, sent = {}, {}
    fire(BR.Net.REPORT_SUBMIT, 1, {
        targets = { { src = 2, category = 'cheating' } },
    })
    ok(#firedOf('br:ringmaster:incident') == 1,
        'and the same pair may be reported again in it',
        tostring(#firedOf('br:ringmaster:incident')))
    ok((lastResult() or {}).ok == true, 'with the reporter told it worked')

    -- THE LIST ITSELF STOPPED CARRYING THE ALLOWANCE (#142). The limit is
    -- untouched and still checked above; what went is the advertisement, and
    -- with it the field -- a payload member that outlives the last thing that
    -- rendered it is this project's most reliable bug.
    sent = {}
    fire(BR.Net.PLAYERS_ASK, 1)
    local list
    for i = #sent, 1, -1 do
        if sent[i].event == BR.Net.PLAYERS_LIST then list = sent[i].args[1] break end
    end
    ok(list ~= nil and list.inMatch == true, 'the panel is still answered in a match')
    ok(list ~= nil and list.remaining == nil,
        'and the answer no longer carries a remaining-reports count')
    ok(list ~= nil and list.categories ~= nil and list.maxTargets ~= nil,
        'while the rules it does need still travel with the data')
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

-- --------------------------------------------------------------- M7: DBNO ---

--- A squad match: `n` players, ONE squad, all ALIVE and standing on the same
--- spot. DBNO is squads-only, so nearly every block below wants exactly this.
---
--- devMode + startSquads = 1 is what stops the match tick declaring the single
--- remaining squad the winner and tearing the instance down underneath the
--- assertions -- the same lone-developer hold `brforce playing` relies on.
local function squadMatch(n)
    reset()
    BR.Server.devMode = true
    BR.Config.Match.autofill = true

    for i = 1, n do join(i, 'P' .. i) end
    for i = 2, n do
        BR.Party.invite(1, i)
        BR.Party.respond(i, true)
    end
    BR.Roster.each(nil, function(src) BR.Roster.setState(src, BR.PlayerState.WARMUP) end)

    local m = fakeMatch(BR.Mode.SQUAD.key)
    BR.Party.formSquads(m)
    m.state = BR.MatchState.PLAYING
    m.startSquads = 1

    for i = 1, n do
        BR.Roster.setState(i, BR.PlayerState.ALIVE)
        setPos(i, 0.0, 0.0, 30.0)
        BR.Roster.get(i).pos = { x = 0.0, y = 0.0, z = 30.0 }
    end

    sent = {}
    return m
end

--- Advance the clock and run the schedulers, which is what drives the bleed.
local function tick(ms)
    fakeTime = fakeTime + ms
    BR.Sched.step(fakeTime)
end

--- Advance time the way a client actually HOLDING a revive does.
---
--- The server expires a revive it has not heard about for dbnoReviveBeatMs, so
--- a plain tick() is now "the holder let go" rather than "time passed" -- which
--- is the whole point of the heartbeat and is why every progress assertion
--- below has to go through here.
local function holdTick(reviverSrc, targetSrc, ms)
    local left = ms
    while left > 0 do
        local step = math.min(250, left)
        fakeTime = fakeTime + step
        fire(BR.Net.REVIVE_START, reviverSrc, { target = targetSrc })
        BR.Sched.step(fakeTime)
        left = left - step
    end
end

--- The last DBNO_SET a player was sent, or nil.
local function lastDbno(src)
    local found = nil
    for _, s in ipairs(sent) do
        if s.event == BR.Net.DBNO_SET and s.target == src then found = s.args[1] end
    end
    return found
end

describe('dbno.knock')
do
    -- SQUADS ONLY, AND ONLY WHILE SOMEBODY IS STANDING. Every one of these is a
    -- separate reason for defeat() to fall through to a real death, and the
    -- expensive way to find that out is a playtest where a solo player lies on
    -- the floor for forty-five seconds waiting for a teammate they do not have.
    local m = squadMatch(2)

    BR.Combat.defeat(1, 'gunshot', 2)
    ok(BR.Roster.get(1).state == BR.PlayerState.DBNO,
        'a squad player with a standing mate goes DOWN, not out',
        BR.Roster.get(1).state)
    ok(BR.Roster.get(1).placement == nil,
        'and a knock assigns no placement -- they have not finished anything')

    local push = lastDbno(1)
    ok(push ~= nil and push.downed == true,
        'the downed player is told, on the wire')
    ok(push and push.bleedEndsAt == BR.Roster.get(1).dbnoUntil,
        'with the bleed deadline the server is actually holding')
    ok(push and push.byName == 'P2', 'and who put them there', push and push.byName)

    ok(BR.Roster.get(2).downs == 1, 'the knocker is credited with a down')
    ok(BR.Roster.get(2).kills == 0, 'but NOT with a kill -- a revive may undo it')

    -- The last standing mate is what makes it possible; without one it is a
    -- death however many bodies the squad still has on the floor.
    BR.Combat.defeat(2, 'gunshot', 1)
    ok(BR.Roster.get(2).state == BR.PlayerState.DEAD,
        'the last player of a squad dies rather than joining the pile',
        BR.Roster.get(2).state)

    -- Already down: running out of health again is the end of it.
    BR.Combat.defeat(1, 'gunshot', 2)
    ok(BR.Roster.get(1).state == BR.PlayerState.DEAD,
        'defeating a player who is already down eliminates them')

    -- Solo has no downed state at all.
    reset()
    BR.Server.devMode = true
    queueUp(1, 'A', BR.Mode.SOLO.key)
    queueUp(2, 'B', BR.Mode.SOLO.key)
    tick(300)
    BR.Roster.setState(1, BR.PlayerState.ALIVE)
    BR.Roster.setState(2, BR.PlayerState.ALIVE)
    BR.Combat.defeat(1, 'gunshot', 2)
    ok(BR.Roster.get(1).state == BR.PlayerState.DEAD,
        'a solo player is never downed -- nobody could pick them up')

    -- A mate who is still on canopy counts: they can land and revive.
    m = squadMatch(2)
    BR.Roster.setState(2, BR.PlayerState.GLIDE)
    BR.Combat.defeat(1, 'gunshot', nil)
    ok(BR.Roster.get(1).state == BR.PlayerState.DBNO,
        'a squadmate still under canopy is a standing mate')

    -- A mate who is themselves DOWN does not.
    m = squadMatch(3)
    BR.Combat.defeat(2, 'gunshot', nil)
    BR.Combat.defeat(3, 'gunshot', nil)
    ok(BR.Roster.get(2).state == BR.PlayerState.DBNO
       and BR.Roster.get(3).state == BR.PlayerState.DBNO, 'two of three are down')
    BR.Combat.defeat(1, 'gunshot', nil)
    ok(BR.Roster.get(1).state == BR.PlayerState.DEAD,
        'the last one standing dies: two downed mates cannot revive anybody',
        BR.Roster.get(1).state)
end

describe('dbno.deadPed')
do
    -- THE FALL THAT WENT STRAIGHT TO OUT (owner, 2026-08-16).
    --
    -- "I just tried reviving (who should be) a DBNO player in the same squad and
    --  never even got a prompt or DUI... Their screen reads 0 health and they're
    --  unable to crawl... The squad panel went straight to 'out' when they
    --  dropped."
    --
    -- A knock from a validated GUNSHOT arrives at a ped that is still alive:
    -- BR.Damage.applyHit clamps the damage it instructs the victim to apply so
    -- the ped survives at the downed floor, deliberately. NOTHING CLAMPS A FALL.
    -- Falls, fire, drowning and cars are damage paths M6 leaves to the engine on
    -- purpose, so the ped is genuinely dead by the time the knock lands -- and
    -- the server-observed death check then read that corpse and finished the
    -- player it had knocked down a fraction of a second earlier.
    --
    -- This block is the whole shape of that: knocked, still knocked a couple of
    -- seconds later, and finished by the clock that is supposed to finish them.
    local m = squadMatch(2)

    -- One pass of the sampler first, so `engineHp` holds a real reading. Without
    -- it the entry has never been sampled and "the corpse sample is dropped"
    -- would pass by never having existed.
    tick(300)
    ok(BR.Roster.get(1).engineHp ~= nil, 'the sampler has an opinion to begin with')

    pedHealth[1001] = 0            -- the drop killed the ped outright
    sent = {}
    fire(BR.Net.PLAYER_DIED, 1, { cause = 'fall' })

    ok(BR.Roster.get(1).state == BR.PlayerState.DBNO,
        'a fall knocks a squad player down like every other damage path',
        BR.Roster.get(1).state)

    -- THE STALE READING IS DROPPED WITH THE KNOCK. It is up to 250ms old and, on
    -- every engine-owned path, it is a reading of a corpse -- an opinion from
    -- before the event, which is exactly what reviveHeld clears for the same
    -- reason.
    ok(BR.Roster.get(1).engineHp == nil,
        'and the health sample from before the knock does not outlive it',
        tostring(BR.Roster.get(1).engineHp))

    -- The server cannot write a ped, so it says what the number IS. Without
    -- this the downed player is left on whatever the world left them on, which
    -- for a fall is zero -- "their screen reads 0 health".
    local hs = nil
    for _, s in ipairs(sent) do
        if s.event == BR.Net.HEALTH_SYNC and s.target == 1 then hs = s.args[1] end
    end
    ok(hs ~= nil and hs.hp == BR.Config.Match.dbnoHp,
        'and the client is told what a downed ped weighs, whatever put them there',
        hs and tostring(hs.hp) or 'no HEALTH_SYNC at all')

    -- THE HEADLINE. Two seconds is two passes of combat.deathcheck and eight of
    -- the sampler, every one of them looking at a ped that reads dead.
    tick(1000)
    tick(1000)
    ok(BR.Roster.get(1).state == BR.PlayerState.DBNO,
        'and they are STILL down two seconds later -- the ped reading is not '
        .. 'evidence about a player whose health is a bleed clock',
        BR.Roster.get(1).state)
    ok(BR.Roster.get(1).placement == nil,
        'with nothing banked: a knock is not a finishing position',
        tostring(BR.Roster.get(1).placement))

    -- ...AND DECLINING THE PED READING IS NOT IMMORTALITY. The bleed clock owns
    -- the ending and still delivers it, which is what makes the check above safe
    -- to give up rather than a hole to hide in.
    tick(BR.Config.Match.dbnoBleedBase * 1000 + 500)
    ok(BR.Roster.get(1).state == BR.PlayerState.DEAD,
        'the bleed clock still finishes them on time',
        BR.Roster.get(1).state)
    ok(BR.Roster.get(1).placement ~= nil,
        'and THAT death is banked in full')

    pedHealth[1001] = nil
end

describe('combat.resync.corpse')
do
    -- THE FALSE CORPSE, FROM THE OTHER END (#115, owner 2026-08-16).
    --
    -- "Friendly fire - I shot a squad mate, they got 0 damage, and on my screen
    --  they perished. After shooting their ped once more they sprung to life,
    --  t-posed, then was synced perfectly."
    --
    -- The correction that stands a mate back up is right, and it is the ONLY
    -- thing on this path that can be: the engine applies damage locally on the
    -- shooter's machine before the server ever sees the event, and CancelEvent
    -- stops it replicating rather than undoing it.
    --
    -- What it must not do is stand up a body that is genuinely a body. The
    -- SUCCESS path has said so since it was written -- applyHit withholds the
    -- netId once the ledger reads zero -- and the REFUSAL path, which is where
    -- every friendly-fire shot goes, said nothing at all.
    local m = squadMatch(2)
    local pistol = BR.Config.WeaponById['pistol']
    BR.Inv.reset(1)
    BR.Inv.give(1, { item = 'pistol', kind = BR.ItemKind.WEAPON, rarity = 1,
                     count = 1, clip = pistol.clip })
    BR.Inv.of(1).ammo[BR.AmmoType.LIGHT] = 40
    BR.Inv.of(1).active = 1
    BR.Roster.get(1).pos = { x = 0.0, y = 0.0, z = 30.0 }
    BR.Roster.get(2).pos = { x = 2.0, y = 0.0, z = 30.0 }

    --- Shoot the squadmate and hand back the correction the shooter was sent.
    local function shootMate()
        sent = {}
        fakeTime = fakeTime + 5000
        fire('weaponDamageEvent', 1, 1, {
            damageType = 3, weaponType = pistol.hash, hitComponent = 0,
            weaponDamage = 26, hitGlobalIds = { 1002 },
        })
        local found = nil
        for _, s in ipairs(sent) do
            if s.event == BR.Net.HIT_RESYNC and s.target == 1 then
                found = s.args[1]
            end
        end
        return found
    end

    local live = shootMate()
    ok(BR.Roster.get(2).hp == 100.0,
        'friendly fire takes nothing off the mate', tostring(BR.Roster.get(2).hp))
    ok(live ~= nil,
        'and the shooter is told to put their own copy of them back')
    ok(live and live.hp == math.floor(BR.ToEngineHp(BR.Roster.get(2).hp) + 0.5),
        'with the ledger\'s number, in engine units',
        live and tostring(live.hp) or 'nil')

    -- A DOWNED MATE IS STILL A LIVING PED. Their health is a bleed clock, but
    -- the thing standing in the world is alive at the downed floor and a
    -- shooter's corpse-copy of it is just as wrong.
    BR.Combat.defeat(2, 'gunshot', nil)
    ok(BR.Roster.get(2).state == BR.PlayerState.DBNO, 'the mate goes down')
    local downed = shootMate()
    ok(downed ~= nil and downed.hp > BR.Config.Match.healthFloor,
        'a downed squadmate is still corrected, and to a LIVING number',
        downed and tostring(downed.hp) or 'nil')

    -- ...and once they are out, the corpse is real.
    BR.Combat.eliminate(2, 'admin', nil)
    ok(BR.Roster.get(2).state == BR.PlayerState.DEAD, 'the mate is eliminated')

    -- WHY THE GUARD IS ON THE STATE AND NOT ON THE NUMBER. An eliminated
    -- player's ledger health is never zeroed -- a knock parks it on the downed
    -- floor and nothing takes it off -- so copying applyHit's `hp > 0` test here
    -- would have let a minute-old corpse through carrying a live-looking 105.
    ok(BR.Roster.get(2).hp > 0.0,
        'an eliminated player\'s ledger health is NOT zero',
        tostring(BR.Roster.get(2).hp))
    ok(BR.IsDeadHp(math.floor(BR.ToEngineHp(BR.Roster.get(2).hp) + 0.5)) == false,
        '...and converts to a number that reads perfectly alive',
        tostring(math.floor(BR.ToEngineHp(BR.Roster.get(2).hp) + 0.5)))

    local corpse = shootMate()
    ok(corpse == nil,
        'so shooting the body sends no correction at all: that corpse is real',
        corpse and ('hp ' .. tostring(corpse.hp)) or 'nil')
end

describe('dbno.bleed')
do
    -- THE BLEED TIMER IS THE HEALTH BAR. Everything here is about that one
    -- decision: knocks get shorter, damage buys seconds off it, and it running
    -- out is the death.
    squadMatch(3)

    BR.Combat.defeat(1, 'gunshot', 2)
    local first = BR.Roster.get(1).dbnoUntil - fakeTime
    ok(first == BR.Config.Match.dbnoBleedBase * 1000,
        'the first knock bleeds for the base time', first)

    BR.Combat.revive(1, 2)
    BR.Combat.defeat(1, 'gunshot', 2)
    local second = BR.Roster.get(1).dbnoUntil - fakeTime
    ok(second == (BR.Config.Match.dbnoBleedBase
                  + BR.Config.Match.dbnoBleedStep) * 1000,
        'the second knock in the same match is shorter', second)

    -- ...all the way down to the floor, which is what stops a squad farming
    -- revives out of one long fight.
    for _ = 1, 10 do
        BR.Combat.revive(1, 2)
        BR.Combat.defeat(1, 'gunshot', 2)
    end
    ok(BR.Roster.get(1).dbnoUntil - fakeTime
       == BR.Config.Match.dbnoBleedMin * 1000,
        'and never drops below the minimum',
        BR.Roster.get(1).dbnoUntil - fakeTime)

    -- DAMAGE BUYS SECONDS, NOT HEALTH.
    squadMatch(3)
    BR.Combat.defeat(1, 'gunshot', 2)
    local before = BR.Roster.get(1).dbnoUntil
    local hpBefore = BR.Roster.get(1).hp

    BR.Damage.applyHit(3, 1, 30.0, { weapon = 0 })
    ok(BR.Roster.get(1).hp == hpBefore,
        'a hit on a downed player takes no health', BR.Roster.get(1).hp)
    ok(BR.Roster.get(1).dbnoUntil
       == before - math.floor(30.0 * BR.Config.Match.dbnoBleedPerDamage * 1000),
        'it takes exactly dbnoBleedPerDamage seconds per point off the clock',
        before - BR.Roster.get(1).dbnoUntil)

    -- The ledger holds them above zero, which is what keeps the shooter's own
    -- copy of them correctable rather than a permanent corpse.
    ok(BR.Roster.get(1).hp > 0.0,
        'a downed player is never at zero on the ledger', BR.Roster.get(1).hp)

    -- AND THE SAMPLER LEAVES THAT NUMBER ALONE. Their ped is parked at the
    -- floor and the countdown is the real health, so a client that was slow to
    -- apply the knock -- or is simply ignoring it -- must not drag the entry
    -- back to full and show the squad panel a downed teammate on 100hp.
    -- (pedHealth for these players reads a healthy 200, so without the guard
    -- one pass of roster.positions is enough to do exactly that.)
    tick(600)
    ok(BR.Roster.get(1).hp == BR.Config.Match.dbnoHp,
        'and the position sampler does not overwrite it',
        BR.Roster.get(1).hp)

    -- Enough damage finishes them, and it is the FINISHER who is credited.
    BR.Damage.applyHit(3, 1, 500.0, { weapon = 0 })
    ok(BR.Roster.get(1).state == BR.PlayerState.DEAD,
        'running the clock out with gunfire finishes them')
    ok(BR.Roster.get(3).kills == 1,
        'and the kill goes to whoever finished them, not whoever knocked them',
        BR.Roster.get(3).kills)

    -- THE KNOCKING BLOW IS CLAMPED ON THE WIRE, and this is the half that
    -- cannot be seen from the ledger at all: the server's own hp lands on the
    -- DBNO floor either way, because the knock writes it there. What the
    -- CLIENT is told to apply to its own ped is what decides whether that ped
    -- is still breathing when DBNO_SET arrives a moment behind it -- and an
    -- unclamped overkill would kill it locally first, which the server would
    -- then see and eliminate them for.
    squadMatch(2)
    sent = {}
    BR.Damage.applyHit(2, 1, 500.0, { weapon = 0 })
    ok(BR.Roster.get(1).state == BR.PlayerState.DBNO, 'an overkill shot knocks')

    local hit = nil
    for _, s in ipairs(sent) do
        if s.event == BR.Net.HIT_DAMAGE and s.target == 1 then hit = s.args[1] end
    end
    local ceiling = math.floor(
        BR.ToEngineHpDelta(100.0 - BR.Config.Match.dbnoHp) + 0.5)
    ok(hit ~= nil and hit.amount <= ceiling,
        'and the victim is told to apply only enough to reach the DBNO floor',
        ('told %s, ceiling %d'):format(tostring(hit and hit.amount), ceiling))
    ok(hit ~= nil and hit.amount > 0,
        'while still being told to apply something')
end

describe('dbno.bleedout')
do
    -- THE REASON downedBy EXISTS AT ALL.
    --
    -- attributedKiller expires at assistWindowMs (10s) and a bleed runs 15-45s,
    -- so a player who is knocked and then simply left alone bleeds out with
    -- nothing in the assist window at all. Crediting from lastHitBy would have
    -- given every one of those kills to nobody -- the same shape as the "0
    -- eliminations" summary M6 had to fix.
    squadMatch(3)
    BR.Combat.defeat(1, 'gunshot', 2)
    local victim = BR.Roster.get(1)
    ok(victim.downedBy == 2, 'the knock records who did it')

    -- Walk past the assist window with nobody touching them.
    tick(BR.Config.Match.assistWindowMs + 2000)
    ok(BR.Combat.attributedKiller(victim) == nil,
        'the assist window really has expired by now')
    ok(victim.state == BR.PlayerState.DBNO, 'and they are still bleeding')

    sent = {}
    tick(BR.Config.Match.dbnoBleedBase * 1000)
    ok(BR.Roster.get(1).state == BR.PlayerState.DEAD,
        'the clock running out is the death', BR.Roster.get(1).state)
    ok(BR.Roster.get(2).kills == 1,
        'and the knocker is still credited, long past the assist window',
        BR.Roster.get(2).kills)

    local feed = eventsOf(BR.Net.KILL_FEED)
    local last = feed[#feed] and feed[#feed].args[1]
    ok(last and last.killerSrc == 2,
        'the kill feed names them rather than showing an anonymous death',
        tostring(last and last.killerSrc))
    ok(last and last.cause == 'bledout', 'and says how it ended',
        tostring(last and last.cause))

    -- AND THE PED IS TOLD, which is the half that reached a playtest.
    --
    -- Every other route into eliminate() arrives because something already
    -- died. A downed player's ped is alive and invincible by design, so the
    -- roster flipping to DEAD reaches nothing on its own: the placard stayed on
    -- screen, the pose kept playing and the player stayed conscious with the
    -- match over for them (owner, in game). Two instructions have to go out --
    -- stop being downed, and die -- and neither is visible from the server
    -- tables, which is exactly why this asserts on the wire.
    local sawClear, sawKill = false, false
    for _, s in ipairs(sent) do
        if s.event == BR.Net.DBNO_SET and s.target == 1
           and s.args[1] and s.args[1].downed == false
           and s.args[1].died == true then
            sawClear = true
        end
        if s.event == BR.Net.HEALTH_SYNC and s.target == 1
           and s.args[1] and s.args[1].hp == 0 then
            sawKill = true
        end
    end
    ok(sawClear, 'the downed player is told the downed state is over, and that they died')
    ok(sawKill, 'and told to put their own ped on the floor for good')

    ok(BR.Roster.get(1).dbnoUntil == nil and BR.Roster.get(1).downedBy == nil,
        'and the bleed bookkeeping is cleared with them')
    ok(BR.Roster.get(1).dbnoCount == 1,
        'but the knock COUNT survives -- it is per match, not per life',
        BR.Roster.get(1).dbnoCount)

    -- THE STORM BLEEDS THEM TOO, through the same conversion rather than a
    -- second rule. A knock inside the wall is a short one.
    squadMatch(3)
    BR.Combat.defeat(1, 'gunshot', 2)
    local left = BR.Roster.get(1).dbnoUntil
    BR.Combat.bleed(1, 20.0, nil, nil)
    ok(BR.Roster.get(1).dbnoUntil < left,
        'storm damage takes time off the bleed')
    ok(BR.Roster.get(1).downedBy == 2,
        'and does NOT steal the knock from whoever put them there')
end

describe('dbno.revive')
do
    squadMatch(2)
    BR.Combat.defeat(1, 'gunshot', nil)
    ok(BR.Roster.get(1).state == BR.PlayerState.DBNO, 'p1 is down')

    -- OUT OF REACH IS OUT OF REACH, and it is judged from the SERVER's own
    -- position samples -- never from anything the client said.
    setPos(2, 50.0, 0.0, 30.0)
    BR.Roster.get(2).pos = { x = 50.0, y = 0.0, z = 30.0 }
    fire(BR.Net.REVIVE_START, 2, { target = 1 })
    ok(BR.Roster.get(1).reviverSrc == nil,
        'a revive from across the street is refused')

    setPos(2, 0.5, 0.0, 30.0)
    BR.Roster.get(2).pos = { x = 0.5, y = 0.0, z = 30.0 }
    sent = {}
    fire(BR.Net.REVIVE_START, 2, { target = 1 })
    ok(BR.Roster.get(1).reviverSrc == 2, 'and accepted from arm\'s length')
    ok((lastDbno(1) or {}).reviverName == 'P2',
        'the downed player is told somebody is coming for them')

    -- Progress reaches BOTH parties: the reviver needs their ring, and the
    -- player on the floor needs to know whether to hang on.
    sent = {}
    holdTick(2, 1, 1000)
    local prog = eventsOf(BR.Net.REVIVE_PROGRESS)
    local toReviver, toDowned = false, false
    for _, s in ipairs(prog) do
        if s.target == 2 then toReviver = true end
        if s.target == 1 then toDowned = true end
    end
    ok(toReviver and toDowned, 'revive progress goes to both of them')
    ok(BR.Roster.get(1).state == BR.PlayerState.DBNO,
        'and one second is not eight')

    -- THE BLEED CLOCK STOPS WHILE THEY ARE BEING PICKED UP. A revive begun
    -- with three seconds left used to end in a death anyway, which reads as
    -- the game ignoring what you did rather than as a race you lost (owner,
    -- in game). The deadline moves forward with the hold.
    local deadlineBefore = BR.Roster.get(1).dbnoUntil
    holdTick(2, 1, 1000)
    ok(BR.Roster.get(1).dbnoUntil > deadlineBefore,
        'the bleed deadline is pushed along while the hold runs',
        ('moved %dms'):format(BR.Roster.get(1).dbnoUntil - deadlineBefore))

    holdTick(2, 1, BR.Config.Match.dbnoReviveTime * 1000)
    ok(BR.Roster.get(1).state == BR.PlayerState.ALIVE,
        'the full hold picks them up', BR.Roster.get(1).state)

    -- ON THE WIRE, not on the entry. Once they are ALIVE again the position
    -- sampler resumes and drags entry.hp to whatever their ped reads -- which
    -- in game is the value this instruction just put there, and in a test is
    -- whatever the stub says. What the server SENT is the fact under test.
    local sync = nil
    for _, s in ipairs(sent) do
        if s.event == BR.Net.HEALTH_SYNC and s.target == 1 then sync = s.args[1] end
    end
    ok(sync and sync.hp == BR.Config.Match.dbnoReviveHp,
        'and they are told to come back at the configured health, not full',
        tostring(sync and sync.hp))
    ok(BR.Roster.get(1).dbnoUntil == nil and BR.Roster.get(1).downedBy == nil,
        'and the knock is undone rather than paused')
    ok(BR.Roster.get(2).revives == 1, 'the reviver is credited')

    -- CANCELLED BY THE REVIVER'S OWN DAMAGE. Picking somebody up is the thing
    -- you cannot do while being shot -- that is what the eight seconds are for.
    squadMatch(3)
    BR.Combat.defeat(1, 'gunshot', nil)
    fire(BR.Net.REVIVE_START, 2, { target = 1 })
    ok(BR.Roster.get(1).reviverSrc == 2, 'the hold starts')
    holdTick(2, 1, 1000)
    local wasFrom = BR.Roster.get(1).reviveFrom

    BR.Roster.get(2).lastHitAt = fakeTime
    holdTick(2, 1, 300)

    -- IT RESETS RATHER THAN LOCKING OUT, and that is the honest assertion.
    -- The hold is dropped -- but a reviver still leaning on the key is still
    -- sending heartbeats, so the very next one starts a fresh hold from zero.
    -- Being shot costs you the eight seconds you had banked, which is the
    -- punishment that matters; being unable to try again while your teammate
    -- bleeds out would be a second, harsher rule nobody asked for.
    ok(BR.Roster.get(1).reviveFrom ~= wasFrom,
        'a hit on the reviver throws away the progress')
    ok(BR.Roster.get(1).state == BR.PlayerState.DBNO, 'leaving them down')

    -- Walking away drops it, through the same per-tick re-check. No heartbeat
    -- here: out of range is refused wherever the hold came from.
    fire(BR.Net.REVIVE_STOP, 2)
    fire(BR.Net.REVIVE_START, 3, { target = 1 })
    ok(BR.Roster.get(1).reviverSrc == 3, 'somebody else picks up the job')
    setPos(3, 40.0, 0.0, 30.0)
    BR.Roster.get(3).pos = { x = 40.0, y = 0.0, z = 30.0 }
    tick(300)
    ok(BR.Roster.get(1).reviverSrc == nil, 'walking away drops the hold')

    -- FIRST HAND ON WINS: a second mate must not restart the clock.
    squadMatch(3)
    BR.Combat.defeat(1, 'gunshot', nil)
    fire(BR.Net.REVIVE_START, 2, { target = 1 })
    local startedAt = BR.Roster.get(1).reviveFrom
    holdTick(2, 1, 1000)
    ok(BR.Roster.get(1).reviveFrom == startedAt,
        'a heartbeat from the SAME holder does not restart the clock')
    fire(BR.Net.REVIVE_START, 3, { target = 1 })
    ok(BR.Roster.get(1).reviverSrc == 2, 'the second mate does not take over')
    ok(BR.Roster.get(1).reviveFrom == startedAt,
        'and does not restart the clock')

    -- Letting go stops it, and progress does not survive the release.
    fire(BR.Net.REVIVE_STOP, 2)
    ok(BR.Roster.get(1).reviverSrc == nil, 'releasing the key stops the revive')
    fire(BR.Net.REVIVE_START, 2, { target = 1 })
    ok(BR.Roster.get(1).reviveFrom == fakeTime,
        'and starting again starts from zero')

    -- A HOLD THAT GOES QUIET IS A HOLD THAT ENDED.
    --
    -- THE BUG THIS EXISTS FOR: a brief tap completed a whole eight-second
    -- revive in playtest (owner, 2026-08-09). The key layer derives both edges
    -- correctly, so the REVIVE_STOP was raised and did not land -- and the
    -- design was one dropped message away from giving the interaction away for
    -- free. Progress now needs continuous evidence, so silence stops it and a
    -- lost STOP costs a fraction of a second instead of the whole hold.
    squadMatch(2)
    BR.Combat.defeat(1, 'gunshot', nil)
    fire(BR.Net.REVIVE_START, 2, { target = 1 })
    ok(BR.Roster.get(1).reviverSrc == 2, 'the hold starts')

    -- No heartbeat, and long enough to pass the whole revive time: under the
    -- old design this is exactly the tap that completed one.
    tick(BR.Config.Match.dbnoReviveTime * 1000)
    ok(BR.Roster.get(1).state == BR.PlayerState.DBNO,
        'a tap does NOT complete a revive on its own',
        BR.Roster.get(1).state)
    ok(BR.Roster.get(1).reviverSrc == nil,
        'the silent hold was dropped rather than left running')

    -- A revive can never come from outside the squad, whatever the client says.
    squadMatch(2)
    join(9, 'Stranger')
    BR.Roster.setState(9, BR.PlayerState.ALIVE)
    BR.Roster.get(9).pos = { x = 0.0, y = 0.0, z = 30.0 }
    BR.Roster.get(9).matchId = BR.Roster.get(1).matchId
    BR.Combat.defeat(1, 'gunshot', nil)
    fire(BR.Net.REVIVE_START, 9, { target = 1 })
    ok(BR.Roster.get(1).reviverSrc == nil,
        'an enemy standing over you is not a medic')
end

describe('dbno.teardown')
do
    -- The knock count is per MATCH. A player picked up three times last round
    -- must start the next one on a full timer, or the shortening rule quietly
    -- becomes a per-session punishment.
    local m = squadMatch(2)
    BR.Combat.defeat(1, 'gunshot', 2)
    BR.Combat.revive(1, 2)
    ok(BR.Roster.get(1).dbnoCount == 1, 'the knock was counted')

    BR.Match.transition(m, BR.MatchState.CLEANUP)
    ok(BR.Roster.get(1).dbnoCount == 0, 'and cleanup forgets it')
    ok(BR.Roster.get(1).dbnoUntil == nil, 'along with any bleed still running')

    -- A reviver who disconnects mid-hold does not leave the body pinned to a
    -- player who is no longer on the server.
    squadMatch(2)
    BR.Combat.defeat(1, 'gunshot', nil)
    fire(BR.Net.REVIVE_START, 2, { target = 1 })
    ok(BR.Roster.get(1).reviverSrc == 2, 'the hold is running')
    leave(2)
    ok(BR.Roster.get(1).reviverSrc == nil,
        'and the disconnect clears it rather than freezing the ring')
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

    -- Anyone can simply walk over it -- no hold, no container. Walking over it
    -- includes being streamed it, which is what the subscribe below is: a claim
    -- against an entry the server never sent you is refused now.
    BR.Roster.setState(2, BR.PlayerState.ALIVE)
    standOn(2, spawned[1])
    local scx, scy = BR.LootCellOf(spawned[1].x, spawned[1].y)
    fire(BR.Net.LOOT_CELL, 2, { cx = scx, cy = scy })
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
    standOn(1, crate)
    fire(BR.Net.LOOT_CELL, 1, { cx = cx, cy = cy })

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

    -- Both players are ON the pad, which is where a warmup player actually is.
    BR.Roster.get(1).pos = { x = pad.x, y = pad.y, z = pad.z or 30.0 }
    BR.Roster.get(2).pos = { x = pad.x, y = pad.y, z = pad.z or 30.0 }

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
    standOn(1, target)
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
    standOn(1, first)
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

-- ------------------------------------------------- the ringmaster projection ---
--
-- The second allowlist. Its whole safety argument is that it lives beside
-- newEntry so nobody widens PUBLIC_FIELDS to reach a field the console needs.
-- These tests hold both lists against the ACTUAL entry shape, so a new roster
-- field that lands in neither -- or, worse, drifts into the wrong one -- fails
-- the build rather than leaking in production.

describe('roster.ringmaster')
do
    reset()
    join(1, 'Xeon')
    local e = BR.Roster.get(1)
    e.matchId = 42
    e.pos = { x = 1.0, y = 2.0, z = 3.0 }

    local proj = BR.Roster.ringmaster(e)

    -- The three the client is deliberately NOT told, present here on purpose:
    -- this projection is server-to-server, so it may carry them.
    ok(proj.matchId == 42, 'matchId reaches the console -- it never reaches a client')
    ok(proj.pos ~= nil, 'position reaches the console -- a wallhack if it reached a client')

    -- connectedAt is joinedAt under its wire name -- a game-clock reading, not
    -- a duration, so the console counts it up against the envelope clock pair.
    ok(proj.connectedAt == e.joinedAt, 'connectedAt is joinedAt')

    -- STRICT SUPERSET of the public projection: anything a client may see, an
    -- admin may too. (colour excepted -- it is client-render only, and the
    -- console derives its own squad colour until the roster sends the real one.)
    for _, k in ipairs({ 'name', 'squadId', 'state', 'hp', 'armour', 'kills', 'placement' }) do
        ok(proj[k] ~= nil or e[k] == nil,
            ('the console sees the public field %q'):format(k))
    end

    -- No projected key may be a typo: every one must name a real entry field,
    -- or it silently sends nil forever. connectedAt is the one renamed field.
    local newEntryKeys = BR.Roster.get(1)
    for k in pairs(proj) do
        ok(k == 'connectedAt' or newEntryKeys[k] ~= nil or k == 'license'
           or k == 'matchId' or k == 'pos' or k == 'placement',
           ('projected key %q names a real entry field'):format(k))
    end
end

-- ------------------------------------------- match results and the economy ---
--
-- Three bugs, one block, because they share a payload. All three were invisible
-- from the code: every read path was present and plausible, and the numbers
-- they produced were wrong rather than missing.
--   #98   damage dealt was never credited to anybody, so the XP term that
--         multiplies it paid zero for every player who ever played
--   #99   survival was the MATCH's duration off the envelope, so the player
--         eliminated first was paid exactly what the winner was
--   #100  a disconnect deleted the roster entry, so a player who left produced
--         no row and forfeited the whole match

describe('damage.credit')
do
    reset()
    BR.Server.devMode = true
    join(1, 'Shooter'); join(2, 'Target')
    forceState(BR.MatchState.PLAYING)
    BR.Roster.each(nil, function(src) BR.Roster.setState(src, BR.PlayerState.ALIVE) end)

    ok(BR.Roster.get(1).damage == 0.0, 'nobody has dealt damage yet')

    BR.Damage.applyHit(1, 2, 40.0, { weapon = 0, headshot = false })
    ok(BR.Roster.get(1).damage == 40.0, 'a landed hit credits the shooter (#98)',
        ('got %s'):format(tostring(BR.Roster.get(1).damage)))
    ok(BR.Roster.get(2).damage == 0.0, 'and not the victim')

    BR.Damage.applyHit(1, 2, 15.0, { weapon = 0, headshot = false })
    ok(BR.Roster.get(1).damage == 55.0, 'damage accumulates across hits')

    -- Armour is damage dealt too -- it came off the victim, and it took the
    -- same bullet to do it.
    BR.Roster.get(2).armour = 20.0
    BR.Damage.applyHit(1, 2, 10.0, { weapon = 0, headshot = false })
    ok(BR.Roster.get(1).damage == 65.0, 'damage soaked by armour still counts')

    -- The same rule the kill credit already has, for the same reason.
    BR.Damage.applyHit(2, 2, 10.0, { weapon = 0, headshot = false })
    ok(BR.Roster.get(2).damage == 0.0, 'a player cannot farm damage off themselves')
end

describe('match.results')
do
    reset()
    BR.Server.devMode = true

    -- The harness swallows TriggerEvent, so the results payload has to be
    -- caught here. Restored at the end of the block: leaving a capture in
    -- place would quietly rewrite every later block's event handling.
    local captured
    local realTrigger = TriggerEvent
    TriggerEvent = function(name, payload, ...)
        if name == 'br:match:results' then captured = payload end
        return realTrigger(name, payload, ...)
    end

    join(1, 'Survivor'); join(2, 'Quitter')
    forceState(BR.MatchState.PLAYING)
    BR.Roster.each(nil, function(src) BR.Roster.setState(src, BR.PlayerState.ALIVE) end)
    local m = theMatch()
    local startedAt = m.startedAt

    -- Two minutes in, the quitter is eliminated...
    fakeTime = fakeTime + 120000
    BR.Combat.eliminate(2, 'weapon', 1)
    ok(BR.Roster.get(2).diedAt == fakeTime, 'elimination stamps diedAt (#99)')

    -- ...spectates for thirty seconds, then closes the game.
    fakeTime = fakeTime + 30000
    local leftAt = fakeTime
    connected[2] = nil
    fire('playerDropped', 2, 'Exiting')

    ok(BR.Roster.get(2) == nil, 'they leave the roster -- nothing counts them as present')
    ok(#BR.Roster.departedIn(m.id) == 1, 'but the entry is sealed, not discarded (#100)')

    -- The match runs another eight minutes without them.
    fakeTime = fakeTime + 480000
    BR.Match.transition(m, BR.MatchState.ENDED)

    ok(captured ~= nil, 'the results event fires')
    local byName = {}
    for _, r in ipairs(captured and captured.players or {}) do byName[r.name] = r end

    ok(byName.Survivor ~= nil, 'the survivor gets a row')
    ok(byName.Quitter ~= nil, 'and so does the player who disconnected (#100)')
    ok(captured.total == 2, 'the departed player counts toward the field size',
        ('got %s'):format(tostring(captured and captured.total)))

    -- THE LICENSE IS THE PART THAT CANNOT BE DEFERRED. By now source 2 is gone
    -- and may belong to somebody else; br_stats resolves through the live
    -- player list and would get nothing, so the row would be dropped as
    -- unkeyable and the fix above would achieve exactly nothing.
    ok(byName.Quitter.license ~= nil, 'the sealed row carries the license it was captured with')
    ok(byName.Quitter.left == true, 'and is marked as departed, so nobody sends it a verdict screen')
    ok(byName.Survivor.left == false, 'the survivor is not')

    -- The two durations, which are the whole point of #99.
    ok(byName.Quitter.survivedMs == 120000, 'survival stops when they died',
        ('got %s'):format(tostring(byName.Quitter.survivedMs)))
    ok(byName.Quitter.presentMs == 150000, 'presence stops when they disconnected',
        ('got %s'):format(tostring(byName.Quitter.presentMs)))
    ok(byName.Survivor.survivedMs == 630000, 'the survivor is credited the whole match',
        ('got %s'):format(tostring(byName.Survivor.survivedMs)))
    ok(byName.Survivor.survivedMs > byName.Quitter.survivedMs,
        'and strictly more than the player who died first -- which is the bug')

    ok(leftAt - startedAt == byName.Quitter.presentMs, 'presence is measured from the match start')

    -- ------------------------------------------------------------------
    -- MATCH HISTORY (#153), from the very same event.
    --
    -- Nothing wrote a per-match row until this shipped: every write went to one
    -- aggregate item per player, so the console's match-history panel had
    -- nothing to read and correctly rendered absence. What is asserted below is
    -- the shape of the row, the key it is filed under, and -- the part no
    -- amount of reading catches -- that the row AGREES with the aggregate
    -- written from the same payload.
    --
    -- DRIVEN THROUGH THE REAL CONSUMER, not a hand-built payload. The harness
    -- records events rather than dispatching them, so br_stats' handler is
    -- invoked by hand here; that is also what keeps it out of every other block
    -- in this file.
    -- ------------------------------------------------------------------
    local mark = #fired
    fire('br:match:results', nil, captured)

    --- Everything br_stats emitted for this match, split by verb.
    local function since(n)
        local rows, deltasBy, batches = nil, {}, 0
        for i = n + 1, #fired do
            local f = fired[i]
            if f.event == 'br:ddb:historyPut' then
                batches = batches + 1
                rows = f.args[2]
            elseif f.event == 'br:ddb:statsApply' then
                deltasBy[f.args[2]] = f.args[3]
            end
        end
        return rows, deltasBy, batches
    end

    local rows, deltasBy, batches = since(mark)

    ok(batches == 1, 'the whole match is ONE history event, not one per player',
        ('got %s'):format(tostring(batches)))
    ok(rows ~= nil and #rows == 2, 'with a row for every participant',
        ('got %s'):format(tostring(rows and #rows)))

    local byLicense = {}
    for _, r in ipairs(rows or {}) do byLicense[r.license] = r end

    local winner = byLicense['license:test1']
    local quitter = byLicense['license:test2']

    ok(winner ~= nil, 'the survivor is recorded')
    -- The same fix as #100, carried into the new write rather than re-earned:
    -- somebody who closed the game after dying still played the match.
    ok(quitter ~= nil, 'and so is the player who disconnected (#100)')

    -- THE KEY IS THE READ MODEL. `match#<endedAt>#<matchId>` under the profile's
    -- own partition key is what makes "recent matches, newest first" a Query
    -- with ScanIndexForward = false rather than a scan or a second index.
    ok(winner and winner.sk == ('match#%013d#%s'):format(winner.endedAt, tostring(m.id)),
        'the sort key is match#<zero-padded endedAt>#<matchId>',
        ('got %s'):format(tostring(winner and winner.sk)))
    ok(winner and quitter and winner.sk == quitter.sk,
        'and every row in one match carries the same key suffix, so the match groups')
    ok(winner and #winner.sk == #('match#%013d#%s'):format(0, tostring(m.id)),
        'zero-padded to a fixed width -- the sort is lexicographic, not numeric')

    -- THE TIMESTAMP IS A WALL CLOCK, AND THE ENVELOPE'S IS NOT.
    -- res.endedAt is GetGameTimer(): milliseconds since THIS server process
    -- started, which returns to zero on every restart. Sorting on it would file
    -- every match played after a deploy underneath every match played before
    -- one, so "newest first" would return the oldest match the player ever had.
    ok(winner and winner.endedAt ~= captured.endedAt,
        'endedAt is NOT the envelope timer, which restarts with the process')
    ok(winner and winner.endedAt > 1600000000000,
        'it is epoch milliseconds', ('got %s'):format(tostring(winner and winner.endedAt)))
    ok(winner and quitter and winner.endedAt == quitter.endedAt,
        'one timestamp for the whole match, not one per player')
    -- The aggregate's `lastMatchAt` and the newest history row must be the same
    -- instant, or the profile page says "last match 3 minutes ago" above a list
    -- whose top entry is stamped a second apart.
    ok(winner and deltasBy['license:test1'].at == winner.endedAt,
        'and it is the same stamp the aggregate records as lastMatchAt')

    -- WHAT THE MATCH ACTUALLY WAS.
    ok(winner and winner.placement == 1, 'the survivor placed first')
    ok(winner and winner.won == true, 'and won it')
    ok(winner and winner.kills == 1, 'their kill is on the row',
        ('got %s'):format(tostring(winner and winner.kills)))
    ok(winner and winner.survivedMs == 630000, 'with their own survival time (#99)',
        ('got %s'):format(tostring(winner and winner.survivedMs)))
    ok(quitter and quitter.survivedMs == 120000, 'and the quitter with theirs')
    ok(winner and winner.total == 2, 'the field size is on every row -- 3rd of 8 is not 3rd of 96')
    ok(winner and winner.mode == m.mode, 'as is the mode',
        ('got %s'):format(tostring(winner and winner.mode)))
    ok(quitter and quitter.won == false, 'the player who died did not win')

    -- THE ROW AND THE AGGREGATE ARE WRITTEN SEPARATELY AND MUST STILL AGREE.
    -- They are two DynamoDB operations built from one payload; if they ever
    -- disagree, the profile page shows a career total that no listed match adds
    -- up to, and there is no way to tell which half is lying.
    ok(winner and winner.xpEarned == deltasBy['license:test1'].xp and winner.xpEarned > 0,
        'the XP on the record is the XP that was banked',
        ('row %s vs delta %s'):format(tostring(winner and winner.xpEarned),
            tostring(deltasBy['license:test1'].xp)))
    ok(winner and winner.voltsEarned == deltasBy['license:test1'].balance,
        'and so are the Volts -- including the level-up bonus the player was shown')
    ok(winner and winner.damage == deltasBy['license:test1'].damageDealt,
        'and the damage, floored the same way')

    -- A WIN IS NOT PLACEMENT 1 (#133). The last squad standing can be taken by
    -- the storm: eliminate() records placement 1 because nobody outlasted them,
    -- and they are still dead. The aggregate learned this rule; the record has
    -- to have learned it too, or a moderator reading the history sees a win
    -- beside a career total that never counted one.
    --
    -- The same envelope with the one flag flipped, which is exactly the shape
    -- br_core sends for a storm finish.
    local stormed = { matchId = captured.matchId, mode = captured.mode,
                      startedAt = captured.startedAt, endedAt = captured.endedAt,
                      total = captured.total, players = {} }
    for _, r in ipairs(captured.players) do
        local copy = {}
        for k, v in pairs(r) do copy[k] = v end
        if copy.placement == 1 then copy.died = true end
        stormed.players[#stormed.players + 1] = copy
    end

    mark = #fired
    fire('br:match:results', nil, stormed)
    local srows, sdeltas = since(mark)

    local sw
    for _, r in ipairs(srows or {}) do
        if r.license == 'license:test1' then sw = r end
    end
    ok(sw and sw.placement == 1, 'a storm finish still places first')
    ok(sw and sw.won == false, 'and is NOT recorded as a win (#133)')
    ok(sw and sdeltas['license:test1'].wins == 0,
        'which is the same answer the aggregate gives -- one rule, one place')

    -- CLEANUP owns the other half of the wipe. Without it the sealed entries
    -- accumulate one per disconnect for the server's uptime.
    mark = #fired
    BR.Match.transition(m, BR.MatchState.CLEANUP)
    ok(#BR.Roster.departedIn(m.id) == 0, 'CLEANUP drops the sealed entries')

    -- WHY THE HISTORY ROW IS WRITTEN AT ENDED AND NOT AT CLEANUP, demonstrated
    -- rather than asserted. By this point the numbers a match record is made of
    -- are gone.
    ok(BR.Roster.get(1).kills == 0, 'CLEANUP has zeroed the per-match counters')
    ok(BR.Roster.get(1).placement == nil, 'and cleared placement')

    -- RESULTS ARE PUBLISHED ONCE PER MATCH, and the second publish was not a
    -- duplicate -- it was a fabrication.
    --
    -- transition() only no-ops on `from == state`, so CLEANUP -> ENDED is a
    -- real transition and `brforce ended` reaches it. By this point
    -- resetPlayers has zeroed kills, downs, revives and damage, cleared
    -- placement and nil'd diedAt, while matchId is left intact on purpose. So
    -- the rows the second pass built carried placement nil, kills 0, damage 0
    -- and survivedMs equal to the whole match for everybody -- and br_stats
    -- ADDs those to DynamoDB on top of the real ones, with no compensating
    -- write. A 2026-08-16 playtest produced exactly that fingerprint.
    captured = nil
    BR.Match.transition(m, BR.MatchState.ENDED)
    ok(captured == nil, 'CLEANUP -> ENDED does not republish results')

    -- Guarded on the function as well as on the branch: publishResults is the
    -- one with side effects outside this resource, and a future caller should
    -- not have to know the rule.
    BR.Match.publishResults(m)
    ok(captured == nil, 'and publishResults refuses a direct second call')

    -- SO THERE IS NO SECOND HISTORY WRITE EITHER, and that is the point of
    -- hanging this off br:match:results rather than off a later hook. A row
    -- built from the state above would record placement nil, kills 0, damage 0
    -- and the whole match as survival time, for every participant -- #132's
    -- fingerprint, filed as a permanent record instead of an ADD. One guard,
    -- m.publishedAt, already covers both writes; a second one here would just
    -- be another thing to get wrong.
    local _, _, afterCleanup = since(mark)
    ok(afterCleanup == 0, 'nothing is published after CLEANUP, so nothing is recorded',
        ('got %s batches'):format(tostring(afterCleanup)))

    TriggerEvent = realTrigger
end

-- LAST IN THE FILE, AND DELIBERATELY.
--
-- Every block that runs a match consumes route generation, and the blocks
-- further down this file assume the routes they get. Inserting three more
-- matches in the middle moved somebody else's jump window past their route
-- ceiling and failed match.busDescent -- a real coupling in this suite, and not
-- one worth discovering again from a change that has nothing to do with buses.
-- New match-running blocks go here.
describe('match.reviveBeforePlaying')
do
    -- #144: "If a player dies before game state changes to playing, we should
    -- notify them they will be revived automatically when the match starts, and
    -- then do so."
    --
    -- WHAT THIS BLOCK IS REALLY GUARDING IS THE BOOKKEEPING. Two earlier stats
    -- bugs -- a placement-1 death banked as a win, and a second results publish
    -- that fabricated a whole set of rows -- both reached DynamoDB as an atomic
    -- ADD, which has no compensating write. A death that is going to be undone
    -- must therefore never be WRITTEN, and every assertion below about a field
    -- being nil is an assertion about exactly that.

    -- (1) A LONE PLAYER, which is the case that has to work before any other:
    --     nobody else is alive, so every headcount the pre-match tick makes is
    --     looking at a match with no living members in it.
    reset()
    BR.Config.Match.minToStart = 1
    BR.Server.devMode = true
    join(1, 'A')
    fire(BR.Net.QUEUE_JOIN, 1, { mode = BR.Mode.SOLO.key })
    fakeTime = fakeTime + 300
    BR.Sched.step(fakeTime)
    fakeTime = mendsAt() + 1
    BR.Sched.step(fakeTime)
    ok(mstate() == BR.MatchState.BUS, 'aboard, alone', tostring(mstate()))

    local r = BR.Bus.active(theMatch())
    fakeTime = r.jumpFrom + 1000
    fire(BR.Net.BUS_JUMP, 1)
    fire(BR.Net.DROP_LANDED, 1)
    ok(BR.Roster.get(1).state == BR.PlayerState.ALIVE,
        'landed early -- and mortal, while the match is still BUS')

    sent = {}
    fire(BR.Net.PLAYER_DIED, 1, { cause = 'fall' })

    local e1 = BR.Roster.get(1)
    ok(e1.state == BR.PlayerState.DEAD, 'the death is observed')
    ok(e1.revivePending == true, 'and held for the start')
    ok(e1.diedAt == nil, 'no diedAt -- `died` and the survival clock both hang '
        .. 'off this one field')
    ok(e1.placement == nil, 'no placement -- they have not finished')
    ok(#eventsOf(BR.Net.KILL_FEED) == 0,
        'nothing reaches the kill feed: they are not out',
        tostring(#eventsOf(BR.Net.KILL_FEED)))

    -- The notice, and it has to outlive its own event: the wait it exists to
    -- explain can be the rest of the flight.
    local held = nil
    for _, n in ipairs(eventsOf(BR.Net.NOTIFY)) do
        if n.args[1] and n.args[1].key == 'revive.pending' then held = n end
    end
    ok(held ~= nil and held.target == 1, 'the player is told, by name')
    ok(held ~= nil and held.args[1].sticky == true,
        'and the notice is sticky, because the wait is the whole problem')

    -- ONE TICK. Nobody is airborne and nobody is alive, so the two branches
    -- that fire are the two this change had to teach: the abandoned-match rule
    -- must NOT end or dissolve a match that is holding somebody, and the
    -- go-live rule must count them as a reason to start.
    fakeTime = fakeTime + 300
    BR.Sched.step(fakeTime)
    ok(mstate() == BR.MatchState.PLAYING,
        'the match goes live for the held player rather than ending under them',
        tostring(mstate()))

    ok(e1.state == BR.PlayerState.ALIVE, 'who is revived')
    ok(e1.revivePending == nil, 'with the hold cleared')
    ok(e1.hp == 100.0, 'and their health put back', tostring(e1.hp))
    ok(e1.diedAt == nil and e1.placement == nil,
        'and still nothing written down')
    ok(#eventsOf(BR.Net.REVIVED) == 1,
        'the client is told to resurrect its own ped -- the half the server '
        .. 'cannot do',
        tostring(#eventsOf(BR.Net.REVIVED)))
    local cleared = false
    for _, n in ipairs(eventsOf(BR.Net.NOTIFY)) do
        if n.args[1] and n.args[1].key == 'revive.pending'
           and n.args[1].clear then cleared = true end
    end
    ok(cleared, 'and the sticky notice is withdrawn rather than left up')

    -- (2) NOBODY IS CREDITED WITH A KILL THAT IS ABOUT TO BE UNDONE.
    reset()
    join(1, 'A'); join(2, 'B')
    fire(BR.Net.QUEUE_JOIN, 1, { mode = BR.Mode.SOLO.key })
    fire(BR.Net.QUEUE_JOIN, 2, { mode = BR.Mode.SOLO.key })
    fakeTime = fakeTime + 300
    BR.Sched.step(fakeTime)
    fakeTime = mendsAt() + 1
    BR.Sched.step(fakeTime)
    local r2 = BR.Bus.active(theMatch())
    fakeTime = r2.jumpFrom + 1000
    fire(BR.Net.BUS_JUMP, 1); fire(BR.Net.BUS_JUMP, 2)
    fire(BR.Net.DROP_LANDED, 1); fire(BR.Net.DROP_LANDED, 2)

    BR.Roster.get(1).kills = 0
    BR.Combat.eliminate(2, 'shot', 1)
    ok(BR.Roster.get(2).revivePending == true, 'a shooting before the start is held too')
    ok(BR.Roster.get(1).kills == 0,
        'and the shooter is credited with nothing -- there is no such kill',
        tostring(BR.Roster.get(1).kills))

    -- (3) LEAVING CANCELS THE HOLD. Otherwise the flag walks back to the lobby
    --     with them and holds their old match open in the pre-match tick.
    BR.Match.leaveMatch(2)
    ok(BR.Roster.get(2).revivePending == nil,
        'walking out cancels the hold rather than carrying it home')

    -- (4) AND 'left' IS NEVER HELD. Leaving while alive is deliberately routed
    --     through eliminate so that quitting cannot be a cheaper exit than
    --     dying; holding it would make a bus-phase quit cost nothing at all.
    reset()
    join(1, 'A'); join(2, 'B')
    fire(BR.Net.QUEUE_JOIN, 1, { mode = BR.Mode.SOLO.key })
    fire(BR.Net.QUEUE_JOIN, 2, { mode = BR.Mode.SOLO.key })
    fakeTime = fakeTime + 300
    BR.Sched.step(fakeTime)
    fakeTime = mendsAt() + 1
    BR.Sched.step(fakeTime)
    local r3 = BR.Bus.active(theMatch())
    fakeTime = r3.jumpFrom + 1000
    fire(BR.Net.BUS_JUMP, 2)
    fire(BR.Net.DROP_LANDED, 2)
    local mbus = theMatch()
    BR.Match.leaveMatch(2)
    local e2 = BR.Roster.get(2)
    -- Read off the SEALED copy (#161): leaving detaches matchId, so a leaver's
    -- record now travels in `departed` rather than on the live entry, which is
    -- wiped so none of it reaches their next match.
    local bailed = BR.Roster.departedIn(mbus.id)[1]
    ok(e2.revivePending == nil and bailed ~= nil
       and bailed.diedAt ~= nil and bailed.placement ~= nil,
        'quitting during the flight is still a real elimination',
        ('pending %s diedAt %s placement %s'):format(
            tostring(e2.revivePending), tostring(bailed and bailed.diedAt),
            tostring(bailed and bailed.placement)))

    -- (5) WHERE THE WINDOW STARTS, which is the whole of the rescope (owner,
    --     2026-08-16): "this was not supposed to cover dying during warmup,
    --     since that's not possible. instead, the issue is dying between
    --     jumping from the bus and game state changing to playing".
    --
    --     The first implementation held WARMUP and BUS by MATCH state alone.
    --     Both halves of that were wrong in opposite directions and neither was
    --     visible from the assertions above, because every one of them jumps
    --     first: warmup was covering something that cannot happen, and holding
    --     by match state alone put the AIRCRAFT inside the window -- a player
    --     still in their seat had not left the bus yet, which is where the owner
    --     says it begins.
    reset()
    join(1, 'A'); join(2, 'B')
    fire(BR.Net.QUEUE_JOIN, 1, { mode = BR.Mode.SOLO.key })
    fire(BR.Net.QUEUE_JOIN, 2, { mode = BR.Mode.SOLO.key })
    fakeTime = fakeTime + 300
    BR.Sched.step(fakeTime)
    ok(mstate() == BR.MatchState.WARMUP, 'on the pad', tostring(mstate()))

    -- WARMUP IS NOT A DEATH AT ALL, and that is the owner's point rather than a
    -- consequence of this change: canDie has never included the warmup state, so
    -- eliminate() returns before it reaches any window test. The old scope was
    -- guarding a door with nothing behind it.
    BR.Combat.eliminate(1, 'fall', nil)
    local w = BR.Roster.get(1)
    ok(w.state == BR.PlayerState.WARMUP,
        'a death on the warmup pad does not happen in the first place',
        tostring(w.state))
    ok(w.revivePending == nil and w.diedAt == nil,
        'so there is nothing to hold and nothing to bank')

    -- ABOARD IS BEFORE THE WINDOW. The state that CAN die here is the bus seat,
    -- and it is deliberately outside: "between jumping from the bus and..." is
    -- where the hold begins, so a death in the seat is banked like any other.
    fakeTime = mendsAt() + 1
    BR.Sched.step(fakeTime)
    ok(mstate() == BR.MatchState.BUS, 'and then aboard', tostring(mstate()))
    ok(BR.Roster.get(2).state == BR.PlayerState.BUS, 'player 2 is in their seat')

    BR.Combat.eliminate(2, 'fall', nil)
    local b = BR.Roster.get(2)
    ok(b.revivePending == nil,
        'a death while still ON the bus is not held -- the window starts at the door',
        tostring(b.revivePending))
    ok(b.diedAt ~= nil and b.placement ~= nil,
        'it is banked in full, like any other elimination',
        ('diedAt %s placement %s'):format(
            tostring(b.diedAt), tostring(b.placement)))

    -- AND ONE STEP LATER, THE SAME MATCH STATE, THE OTHER SIDE OF THE DOOR.
    -- Nothing about the match has changed between these two assertions; the only
    -- difference is that this player jumped.
    reset()
    join(1, 'A'); join(2, 'B')
    fire(BR.Net.QUEUE_JOIN, 1, { mode = BR.Mode.SOLO.key })
    fire(BR.Net.QUEUE_JOIN, 2, { mode = BR.Mode.SOLO.key })
    fakeTime = fakeTime + 300
    BR.Sched.step(fakeTime)
    fakeTime = mendsAt() + 1
    BR.Sched.step(fakeTime)
    local r5 = BR.Bus.active(theMatch())
    fakeTime = r5.jumpFrom + 1000
    fire(BR.Net.BUS_JUMP, 2)
    ok(BR.Roster.get(2).state == BR.PlayerState.FREEFALL, 'out of the door')
    BR.Combat.eliminate(2, 'fall', nil)
    local f = BR.Roster.get(2)
    ok(f.revivePending == true,
        'and the very next death IS held -- same match state, different side of the door')
    ok(f.diedAt == nil and f.placement == nil,
        'with nothing a results row is built from written')
end

describe('match.abandonedResults')
do
    -- #161: "A match everybody leaves records nothing for anybody."
    --
    -- Two players joined a match, both left early, the match emptied and cleaned
    -- up, and `brprofile` showed `matches` unchanged for both. No aggregate, no
    -- XP, no Volts, no history row. THE OWNER'S CALL: "we should record
    -- everything."
    --
    -- WHY IT HAPPENED, AND WHY IT WAS TWO BUGS WEARING ONE COAT:
    --
    --   1. Results are published on entering ENDED. A match nobody is left in is
    --      dissolved through BR.Match.destroy instead and never enters ENDED, so
    --      publishResults was never asked to run.
    --   2. And even when it did run, it could not see a player who used Leave
    --      Match: that path detaches matchId, which is the key publishResults
    --      builds its rows from. #100 fixed exactly this for DISCONNECTS and the
    --      other door was never checked -- so a leaver forfeited their record
    --      even from a match that ran all the way to a winner.
    --
    -- Both are staged below, because "left the match" means either one in
    -- practice and the owner cannot be expected to know which button was pressed.
    --
    -- WHAT THIS BLOCK IS REALLY GUARDING is the same thing #132 and #144 guard:
    -- br_stats writes an atomic ADD to DynamoDB and there is NO COMPENSATING
    -- WRITE. Publishing twice, or publishing after CLEANUP has zeroed everything,
    -- is unrecoverable without a manual repair. So every assertion here is really
    -- about counting to exactly one and about what the rows contain when it does.
    local realTrigger = TriggerEvent

    --- Every br:match:results payload published since a mark.
    local function resultsSince(n)
        local out = {}
        for i = n + 1, #fired do
            if fired[i].event == 'br:match:results' then
                out[#out + 1] = fired[i].args[1]
            end
        end
        return out
    end

    --- Everything br_stats emitted since a mark, split by verb.
    local function statsSince(n)
        local rows, deltasBy, batches = nil, {}, 0
        for i = n + 1, #fired do
            local f = fired[i]
            if f.event == 'br:ddb:historyPut' then
                batches = batches + 1
                rows = f.args[2]
            elseif f.event == 'br:ddb:statsApply' then
                deltasBy[f.args[2]] = f.args[3]
            end
        end
        return rows, deltasBy, batches
    end

    --- Two players, a live match, and real numbers on both of them.
    ---
    --- The numbers are the point. A published row of zeroes is not a lesser
    --- version of this fix, it is #132 -- so every assertion below reads a value
    --- that could only have come from before the teardown.
    local function twoInAMatch()
        reset()
        BR.Server.devMode = true
        join(1, 'Stayer'); join(2, 'Bailer')
        forceState(BR.MatchState.PLAYING)
        BR.Roster.each(nil, function(src)
            BR.Roster.setState(src, BR.PlayerState.ALIVE)
        end)
        BR.Roster.get(1).kills, BR.Roster.get(1).damage = 2, 350.0
        BR.Roster.get(2).kills, BR.Roster.get(2).damage = 1, 120.0
        fakeTime = fakeTime + 60000
        return theMatch()
    end

    --- Advance one match tick.
    local function tick()
        fakeTime = fakeTime + 300
        BR.Sched.step(fakeTime)
    end

    -- ------------------------------------------------------------------
    -- (1) EVERYBODY USES LEAVE MATCH. #161's headline case.
    -- ------------------------------------------------------------------
    local mark = #fired
    local m1 = twoInAMatch()
    fire(BR.Net.MATCH_LEAVE, 2)     -- Bailer goes first...
    fire(BR.Net.MATCH_LEAVE, 1)     -- ...then the last player out
    tick()

    ok(BR.Server.matches[m1.id] == nil,
        'a match nobody is left in is dissolved')

    local pub = resultsSince(mark)
    ok(#pub == 1, 'and its results are published -- EXACTLY ONCE (#161)',
        ('got %d publishes'):format(#pub))

    local res = pub[1]
    local by = {}
    for _, r in ipairs(res and res.players or {}) do by[r.name] = r end

    ok(by.Stayer ~= nil and by.Bailer ~= nil,
        'with a row for both players, not just whoever was last out')
    ok(res and res.total == 2, 'and a field size that counts them both',
        ('got %s'):format(tostring(res and res.total)))

    -- THE REAL NUMBERS, WHICH IS THE WHOLE DELIVERABLE. If the publish happened
    -- one line later -- after destroy's roster sweep, or after CLEANUP's wipe --
    -- these are the assertions that would fail, and they would fail as zeroes
    -- rather than as an error.
    ok(by.Stayer and by.Stayer.kills == 2 and by.Stayer.damage == 350.0,
        "the stayer's real kills and damage are on the row",
        ('kills %s damage %s'):format(tostring(by.Stayer and by.Stayer.kills),
            tostring(by.Stayer and by.Stayer.damage)))
    ok(by.Bailer and by.Bailer.kills == 1 and by.Bailer.damage == 120.0,
        "and the first leaver's too -- their record survived being detached")
    ok(by.Stayer and by.Stayer.license == 'license:test1'
       and by.Bailer and by.Bailer.license == 'license:test2',
        'both rows are keyable, so br_stats can write them (#100)')

    -- THE HAZARD THIS ISSUE IS MOST LIKELY TO CREATE: "record everything" makes
    -- the last player to walk out look exactly like the last player standing.
    --
    -- They DO take placement 1, and that is correct -- at the moment they left,
    -- nobody had outlasted them, which is what placement means. What must never
    -- follow is a WIN. eliminate('left') stamps diedAt, and #133 settled the rule
    -- as `won = placement == 1 and not died`.
    ok(by.Stayer and by.Stayer.placement == 1,
        'the last player out places first -- nobody outlasted them',
        ('got %s'):format(tostring(by.Stayer and by.Stayer.placement)))
    ok(by.Stayer and by.Stayer.died == true,
        'but leaving while alive is an elimination, so `died` is set (#133)')
    ok(by.Bailer and by.Bailer.placement == 2,
        'and the player who left first placed behind them',
        ('got %s'):format(tostring(by.Bailer and by.Bailer.placement)))

    -- ...AND THE CONSUMER AGREES, which is the half that reaches DynamoDB.
    -- Asserted through br_stats rather than by re-deriving the rule here: two
    -- copies of this rule disagreeing is precisely what #133 was.
    local smark = #fired
    -- Guarded so that a run with the fix REVERTED reports honest pass/fail counts
    -- instead of dying here on a nil payload. br_stats indexes res.players
    -- directly, as it should -- br_core never sends it nothing.
    if res then fire('br:match:results', nil, res) end
    local hrows, deltasBy, batches = statsSince(smark)

    ok(deltasBy['license:test1'] and deltasBy['license:test1'].wins == 0,
        'NOBODY WINS AN ABANDONED MATCH -- leaving last is not a victory (#133)',
        ('wins %s'):format(tostring(deltasBy['license:test1']
            and deltasBy['license:test1'].wins)))
    ok(deltasBy['license:test1'] and deltasBy['license:test1'].matches == 1,
        'the match is banked, once, for the last player out')
    ok(deltasBy['license:test2'] and deltasBy['license:test2'].matches == 1,
        'and once for the player who left first -- which is what #161 reported missing')
    ok(deltasBy['license:test1'] and deltasBy['license:test1'].kills == 2,
        'with their kills', ('got %s'):format(tostring(deltasBy['license:test1']
            and deltasBy['license:test1'].kills)))

    -- MATCH HISTORY (#153) FOLLOWS FOR FREE, and this is the assertion that says
    -- so rather than assuming it. The rows are built inside the same
    -- br:match:results handler as the aggregate, so publishing an abandoned match
    -- is the only thing that was needed -- #153 was never broken here, it was
    -- never asked to write anything. That is what made its first test
    -- inconclusive.
    ok(batches == 1, 'the abandoned match writes ONE history batch (#153)',
        ('got %d'):format(batches))
    ok(hrows ~= nil and #hrows == 2, 'with a per-match row for both players',
        ('got %s'):format(tostring(hrows and #hrows)))
    local hby = {}
    for _, r in ipairs(hrows or {}) do hby[r.license] = r end
    ok(hby['license:test1'] and hby['license:test1'].won == false,
        'and the record agrees with the aggregate: no win on the history row either')
    ok(hby['license:test2'] and hby['license:test2'].kills == 1,
        'the first leaver is in the history too')

    -- ------------------------------------------------------------------
    -- (2) AND IT DOES NOT PUBLISH AGAIN IF DESTROY RUNS TWICE.
    --
    -- m.publishedAt is the one guard, and it is inside publishResults. A second
    -- pass would not be a duplicate -- by now the roster is detached and the
    -- sealed entries are gone, so it would ADD a fresh set of near-empty rows to
    -- DynamoDB on top of the real ones, with nothing able to take them back.
    -- ------------------------------------------------------------------
    local dmark = #fired
    BR.Match.destroy(m1)
    BR.Match.destroy(m1)
    ok(#resultsSince(dmark) == 0,
        'destroying an already-dissolved match publishes nothing further (#132)',
        ('got %d publishes'):format(#resultsSince(dmark)))
    local _, _, again = statsSince(dmark)
    ok(again == 0, 'so no second history batch is filed either',
        ('got %d'):format(again))

    -- ------------------------------------------------------------------
    -- (3) THE OTHER WAY OUT: everybody CLOSES THE GAME. Same match, same
    --     outcome -- this is the path #100's sealing was built for, and the one
    --     the issue's own diagnosis is written against.
    -- ------------------------------------------------------------------
    mark = #fired
    local m2 = twoInAMatch()
    leave(2); leave(1)
    tick()

    ok(BR.Server.matches[m2.id] == nil, 'a match everybody disconnects from dissolves')
    local pub2 = resultsSince(mark)
    ok(#pub2 == 1, 'and publishes exactly once as well',
        ('got %d'):format(#pub2))
    local by2 = {}
    for _, r in ipairs(pub2[1] and pub2[1].players or {}) do by2[r.name] = r end
    ok(by2.Stayer and by2.Stayer.kills == 2 and by2.Bailer and by2.Bailer.kills == 1,
        'with both sealed records intact (#100)')
    -- A DISCONNECT IS NOT AN ELIMINATION, so there is no placement and no death
    -- flag -- the same shape #100 already produces on a match that ends normally.
    -- Which means there is no route to a win here either.
    ok(by2.Stayer and by2.Stayer.placement == nil and by2.Stayer.died == false,
        'a disconnect records no placement, so nobody can win by quitting last')

    -- ------------------------------------------------------------------
    -- (4) A MATCH THAT NEVER WENT LIVE RECORDS NOTHING, and that is a decision
    --     rather than an omission. Warmup is invincible and the flight is
    --     untouchable, so every field a row is built from is still zero and
    --     survivedMs would be zero for everybody. Publishing that is not
    --     "recording a short match", it is filing #132's fingerprint on purpose.
    -- ------------------------------------------------------------------
    mark = #fired
    reset()
    BR.Server.devMode = true
    queueUp(1, 'A'); queueUp(2, 'B')
    fakeTime = fakeTime + 1000
    BR.Sched.step(fakeTime)
    ok(mstate() == BR.MatchState.WARMUP, 'a warmup starts')
    local m3 = theMatch()
    ok(m3.startedAt == nil, 'and it has not gone live')
    fire(BR.Net.MATCH_LEAVE, 1)
    fire(BR.Net.MATCH_LEAVE, 2)
    tick()
    ok(BR.Server.matches[m3.id] == nil, 'everybody leaves and it dissolves')
    ok(#resultsSince(mark) == 0,
        'a match dissolved off the warmup pad records nothing for anybody',
        ('got %d publishes'):format(#resultsSince(mark)))

    -- ------------------------------------------------------------------
    -- (5) PUBLISHING NEVER HAPPENS AFTER THE DATA IS DESTROYED.
    --
    --     `brforce cleanup` straight from PLAYING runs resetPlayers -- zeroing
    --     kills, downs, revives and damage, clearing placement, nil'ing diedAt
    --     and dropping the sealed entries -- with nothing yet published. The
    --     dissolve that follows must then record NOTHING rather than a match in
    --     which nobody did anything. Better a missing match than a permanent
    --     fabrication: the ADD has no compensating write.
    -- ------------------------------------------------------------------
    mark = #fired
    local m4 = twoInAMatch()
    BR.Match.transition(m4, BR.MatchState.CLEANUP)
    ok(BR.Roster.get(1).kills == 0, 'CLEANUP has zeroed the numbers')
    ok(m4.wipedAt ~= nil, 'and stamped the match as wiped')
    BR.Match.destroy(m4)
    ok(#resultsSince(mark) == 0,
        'a match dissolved AFTER the wipe files nothing rather than rows of zeroes',
        ('got %d publishes'):format(#resultsSince(mark)))

    -- ------------------------------------------------------------------
    -- (6) AND A MATCH THAT ENDS NORMALLY IS STILL PUBLISHED EXACTLY ONCE.
    --
    --     THE MOST DANGEROUS THING ABOUT THIS CHANGE. destroy now publishes, and
    --     every finished match ends ENDED -> CLEANUP -> destroy -- so if the new
    --     call were not covered by m.publishedAt, EVERY match on the server would
    --     be banked twice. This is the assertion that would catch that, and it is
    --     worth more than all the ones above.
    -- ------------------------------------------------------------------
    mark = #fired
    local m5 = twoInAMatch()
    BR.Combat.eliminate(2, 'weapon', 1)
    BR.Match.transition(m5, BR.MatchState.ENDED)
    ok(#resultsSince(mark) == 1, 'a normal end publishes once',
        ('got %d'):format(#resultsSince(mark)))
    BR.Match.transition(m5, BR.MatchState.CLEANUP)
    BR.Match.destroy(m5)
    ok(#resultsSince(mark) == 1,
        'and the CLEANUP -> destroy that follows every finished match adds no second one',
        ('got %d'):format(#resultsSince(mark)))

    TriggerEvent = realTrigger
end

realPrint(('\n\27[32m%d passed\27[0m'):format(pass))
if fail > 0 then
    realPrint(('\27[31m%d failed\27[0m'):format(fail))
    os.exit(1)
end
