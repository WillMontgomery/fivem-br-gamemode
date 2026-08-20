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
--
-- A SERVER ID IS NOT A PERSON, AND THE OVERRIDE IS WHAT LETS A TEST SAY SO
-- (#172). Deriving the license from `src` alone made the harness quietly
-- incapable of expressing the failure the report path exists to prevent: FiveM
-- recycles ids within the minute, so the player who takes slot 2 after a
-- disconnect is a DIFFERENT human with a different license -- and under a
-- src-derived stub they share one, which would make a report misattributed to
-- them look correct. Tests that care set `licenseOf[src]`; everything else keeps
-- the stable per-src default it was written against.
local licenseOf = {}
function GetNumPlayerIdentifiers(src) return 1 end
function GetPlayerIdentifier(src, i)
    return 'license:' .. (licenseOf[src] or ('test' .. tostring(src)))
end

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
    -- AFTER the config tables it edits, exactly as br_core's fxmanifest orders
    -- it. Nothing here is overridden -- the load-time hook needs
    -- IsDuplicityVersion and this state has none, so every value stays the
    -- committed default -- but BR.Config.Overrides has to EXIST, because
    -- party.lua's formation report asks it which of the two homes the live
    -- maxSquadSize came from. A nil there would make that answer untestable.
    'br_lib/config/overrides.lua',
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
    -- BR.Grants: admin scopes, read from the DynamoDB grants table through
    -- br_ddb. Loaded BEFORE players.lua for the same reason the manifest
    -- declares it there -- the file that answers "may this license file a
    -- report" sits above the two that ask.
    --
    -- IT REGISTERS A `playerJoining` HANDLER, so every `join()` in this suite
    -- now emits a `br:ddb:grantsFetch` into `fired`. That is deliberate and it
    -- is what the block at the bottom of this file drives. Every OTHER block
    -- leaves those questions unanswered, which is exactly the "we never got an
    -- answer" state -- and every one of them still passes, which is the
    -- fail-open decision being asserted by the whole suite rather than by one
    -- assertion in it.
    'br_core/server/grants.lua',
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
    -- Back to the src-derived default. A block that made a recycled id belong
    -- to a different person (see the identifier stub) must not leave that
    -- opinion lying around: the next block asserts on `license:test<src>` and
    -- would fail somewhere with no visible connection to the cause.
    for k in pairs(licenseOf) do licenseOf[k] = nil end
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

-- A REFUSED PICKUP HAS TO SAY SO (#171).
--
-- Owner, 2026-08-17: "If I'm already holding the max amount of something and
-- try to pickup another, show me a toast that says 'you cannot carry more
-- shields' for example."
--
-- Two separate faults were in the way, and neither is visible from the claim
-- handler reading top to bottom:
--
--   * the `carrymax` message read BR.Config.ConsumableById for both the cap and
--     the name. A THROWABLE is in BR.Config.WeaponById, so three grenades
--     produced "You can only carry 0 of thoses." -- the wrong number, and a
--     plural formed by sticking an "s" on the literal fallback string.
--   * the branch chain had a case for `full`, which BR.Inv.give has never
--     returned, and none for `noinv`, which it can. A reason with no branch is
--     a claim that answers with nothing at all.
--
-- The end-to-end claims below are what a player actually does. The refusalText
-- block under them is the property that keeps this fixed: not "carrymax says
-- the right thing" but "NOTHING can come back empty", which is only provable by
-- handing it a reason nobody has written a branch for.
describe('loot.refusal')
do
    local m = lootMatch()

    --- Drop one stack on the floor under a player and claim it.
    --- @return string[] every NOTIFY text that claim sent to `src`
    --- @return table    the entry, so the caller can check it is still there
    local function claim(src, stack)
        local p = BR.Roster.get(src).pos
        local e = BR.Loot.spawnStack(m, stack, p.x, p.y, p.z)
        local cx, cy = BR.LootCellOf(e.x, e.y)
        fire(BR.Net.LOOT_CELL, src, { cx = cx, cy = cy })
        sent = {}
        fire(BR.Net.LOOT_CLAIM, src, { id = e.id })
        local said = {}
        for _, s in ipairs(eventsOf(BR.Net.NOTIFY)) do
            if s.target == src then said[#said + 1] = s.args[1].text end
        end
        return said, e
    end

    -- Away from the generated layout, so the only thing in reach is what the
    -- test puts there.
    standInCell(1, 400, 400)
    BR.Inv.reset(1)

    -- THE THROWABLE, which is the case that was actively lying. Three grenades
    -- is the carry ceiling (weapons.lua maxStack), so the fourth is refused.
    local nade = BR.Config.WeaponById['grenade']
    BR.Inv.give(1, { item = 'grenade', kind = BR.ItemKind.THROWABLE,
                     rarity = nade.rarity, count = nade.maxStack })
    local said = claim(1, { item = 'grenade', kind = BR.ItemKind.THROWABLE,
                            rarity = nade.rarity, count = 1 })
    local nadeText = said[1] or ''
    ok(nadeText:find('Grenades', 1, true) ~= nil,
        'a refused throwable is named in the plural, not as "of thoses"',
        ('%q'):format(nadeText))
    ok(nadeText:find(tostring(nade.maxStack), 1, true) ~= nil,
        'and the cap quoted is the throwable cap, not a consumable zero',
        ('%q'):format(nadeText))

    -- THE CONSUMABLE, which worked and had to keep working.
    BR.Inv.reset(1)
    local band = BR.Config.ConsumableById['bandage']
    BR.Inv.give(1, { item = 'bandage', kind = BR.ItemKind.CONSUMABLE,
                     rarity = band.rarity, count = band.carryMax })
    local saidB, bandE = claim(1, { item = 'bandage',
        kind = BR.ItemKind.CONSUMABLE, rarity = band.rarity, count = 1 })
    ok((saidB[1] or ''):find('Bandages', 1, true) ~= nil,
        'a refused consumable is named from the config plural',
        ('%q'):format(saidB[1] or ''))
    ok(m.loot.items[bandE.id] ~= nil,
        'and the refused item stays in the world')

    -- ----------------------------------------------------------------------
    -- THE SHIELD, WHICH HAD NO REFUSAL TO HEAR AT ALL (owner, 2026-08-18:
    -- "I don't want the swap, if both the item being picked up and the item in
    -- my active slot are the same type").
    --
    -- This is the other half of #171 and it is not a carryMax case: neither
    -- shield HAS a carryMax, so the toast the owner asked for could never fire
    -- for the item he reported it against. What fired instead was the swap --
    -- the loose shield took the active slot and the stack that was there hit
    -- the floor.
    --
    -- The numbers are what make it a bug rather than a preference. A full
    -- shield stack is three; a loose pickup is one. The swap therefore took
    -- THREE out of the inventory and put ONE back, for a key the player
    -- pressed wanting more shields.
    --
    -- ...AND THEN THE PLAYTEST SENT IT BACK, because the refusal that replaced
    -- the swap announced a MAXIMUM (owner, 2026-08-18: "the 'you cannot pickup
    -- any more X' notification should really only appear if I'm actively
    -- holding an item id that has a maximum, and I've reached my maximum
    -- already"). There is no maximum here -- see the assertion directly below,
    -- which is the same fact this block was already resting on and which the
    -- sentence then contradicted. So the block keeps every behavioural claim it
    -- had and swaps every wording claim: the stack survives, the floor copy
    -- survives, the refusal talks -- and what it says is now about the SLOT,
    -- which is the only thing that was ever full.
    -- ----------------------------------------------------------------------
    local shieldCfg = BR.Config.ConsumableById['shield']
    ok(shieldCfg.carryMax == nil,
        'a shield has no carry ceiling, so carrymax can never be its reason')

    --- A claim a full second after the last one.
    ---
    --- The handler's token bucket allows four claims a SECOND and refuses the
    --- fifth SILENTLY -- deliberately, because at that rate it is a stuck key
    --- or a script. Every assertion below reads what a refusal said, so a
    --- shared clock would start returning the bucket's silence and each one
    --- would pass or fail on its position in the file rather than on the rule
    --- it names.
    local function claimLater(src, stack)
        fakeTime = fakeTime + 1100
        return claim(src, stack)
    end

    --- Full inventory, `count` shields in the ACTIVE slot, guns everywhere else.
    local function holdingShields(count)
        BR.Inv.reset(1)
        BR.Inv.give(1, { item = 'shield', kind = BR.ItemKind.CONSUMABLE,
                         rarity = shieldCfg.rarity, count = count })
        for _ = 2, BR.Config.Loot.slots do
            BR.Inv.give(1, { item = 'pistol', kind = BR.ItemKind.WEAPON,
                             rarity = 1, count = 1, clip = 12 })
        end
        local inv = BR.Inv.of(1)
        inv.active = 1
        return inv
    end

    local inv = holdingShields(shieldCfg.maxStack)
    local saidS, shieldE = claimLater(1, { item = 'shield',
        kind = BR.ItemKind.CONSUMABLE, rarity = shieldCfg.rarity, count = 1 })
    ok(inv.slots[1] and inv.slots[1].item == 'shield'
        and inv.slots[1].count == shieldCfg.maxStack,
        'a shield walked over with a shield in hand keeps the stack you had',
        ('%s x%s'):format(tostring(inv.slots[1] and inv.slots[1].item),
                          tostring(inv.slots[1] and inv.slots[1].count)))
    ok(m.loot.items[shieldE.id] ~= nil,
        'and leaves the loose one on the floor rather than trading for it')
    ok((saidS[1] or '') ~= '', 'and it SAYS so -- a silent refusal is #171',
        ('%q'):format(saidS[1] or ''))
    -- THE ITEM IS NAMED, which is the half of the owner's first request that
    -- survived the playtest (2026-08-18: "should say ... [item name]").
    ok((saidS[1] or ''):find(shieldCfg.label, 1, true) ~= nil,
        'and names the item, so the player knows which pickup was refused',
        ('%q'):format(saidS[1] or ''))

    --- Every way a refusal can claim a ceiling that is not there.
    ---
    --- ONE BATTERY, RUN AGAINST BOTH REPORTED ITEMS, because the owner reported
    --- this twice against two kinds -- a Shield (CONSUMABLE, uncapped) and an
    --- SNS Pistol (WEAPON, uncapped by construction) -- and a wording assertion
    --- written out twice is a wording assertion that gets half-updated. Each
    --- string below is a different way of saying the same false thing, and the
    --- sentence is only honest if it says none of them.
    ---
    --- THE DIGIT CHECK IS THE ONE THAT CANNOT BE ARGUED WITH. A cap is a
    --- number; an item with no cap has no number to print, so a refusal for an
    --- uncapped item containing any digit at all has invented one.
    ---
    --- AND IT MUST STILL POINT SOMEWHERE. What is genuinely full here is one
    --- SLOT, and the remedy is the one the owner found for himself before
    --- anybody told him. Naming a true obstacle the player can act on is the
    --- whole difference between this and the sentence it replaced -- and
    --- without this half the battery above would pass on silence, which is the
    --- original #171.
    local function pinsNoCeiling(text, who)
        for _, lie in ipairs({ 'any more', 'cannot carry', 'max' }) do
            ok(text:lower():find(lie, 1, true) == nil,
                ('a refused %s never says %q -- it has no ceiling to say it about')
                    :format(who, lie),
                ('%q'):format(text))
        end
        ok(text:find('%d') == nil,
            ('and quotes no number at a %s, because there is no cap to quote')
                :format(who),
            ('%q'):format(text))
        ok(text:lower():find('slot', 1, true) ~= nil,
            ('and points a %s at the slot, the thing that IS actually full')
                :format(who),
            ('%q'):format(text))
    end

    pinsNoCeiling(saidS[1] or '', 'shield')

    -- THE NAME COMES FROM THE CONFIG, NOT FROM A LITERAL. Every label in the
    -- game reads plausibly, so nothing else in this file can tell a config
    -- lookup from a hardcoded string -- which is exactly how "of thoses" got
    -- shipped. Bending one label out of shape for a single claim separates
    -- them: the sentence either follows `label` or it does not.
    local realLabel = shieldCfg.label
    shieldCfg.label = 'Bubble Of Protection'
    holdingShields(shieldCfg.maxStack)
    local saidOdd = claimLater(1, { item = 'shield',
        kind = BR.ItemKind.CONSUMABLE, rarity = shieldCfg.rarity, count = 1 })
    shieldCfg.label = realLabel
    ok((saidOdd[1] or ''):find('Bubble Of Protection', 1, true) ~= nil,
        'an item name is read from the config, never written into the sentence',
        ('%q'):format(saidOdd[1] or ''))

    -- AND AN ITEM WITH NO CONFIG AT ALL STILL RENDERS A SENTENCE. A refusal
    -- that interpolates a nil is worse than the one it replaced.
    local orphan = BR.Loot.refusalText('sameitem',
        { item = 'no_such_item', kind = BR.ItemKind.CONSUMABLE })
    ok(type(orphan) == 'string' and #orphan > 0
        and orphan:find('nil', 1, true) == nil,
        'and an unconfigured item falls back rather than printing a nil',
        ('%q'):format(tostring(orphan)))

    -- ======================================================================
    -- THREE CASES, AND ONLY THE THIRD SAYS "MAXIMUM" (#171, reopened).
    --
    -- The commit before this one asked ONE question -- "is the active slot the
    -- same item" -- and answered it with a sentence about a limit. Two
    -- different rules had been folded into one test, and the playtest found
    -- both halves of the fold:
    --
    --   1. NO CEILING EXISTS. An SNS Pistol has no carryMax and never will.
    --      A second one is legitimate and goes to a free slot in silence.
    --   2. A CEILING EXISTS AND IS NOT REACHED. It fills, even when the active
    --      slot holds the very same item -- which is the case the like-for-like
    --      rule must NOT eat.
    --   3. A CEILING EXISTS AND IS REACHED, counted across EVERY slot. Refused,
    --      and this is the only refusal entitled to quote a number.
    --
    -- Each case below is claimed end-to-end through the handler rather than
    -- asserted against BR.Inv.give, because the sentence the player reads is
    -- produced a file away from the reason that chose it and #171 has already
    -- been reopened once by exactly that gap.
    -- ======================================================================

    --- Five slots: `first` in slot 1 and pistols after it, `freeFrom` onward
    --- left empty. Active is slot 1 -- the slot the like-for-like rule reads.
    local function holdingWith(first, freeFrom)
        BR.Inv.reset(1)
        BR.Inv.give(1, first)
        for i = 2, (freeFrom or (BR.Config.Loot.slots + 1)) - 1 do
            local _ = i
            BR.Inv.give(1, { item = 'pistol', kind = BR.ItemKind.WEAPON,
                             rarity = 1, count = 1, clip = 12 })
        end
        local i = BR.Inv.of(1)
        i.active = 1
        return i
    end

    -- ----------------------------------------------------------------------
    -- CASE 1 -- NO CEILING, AND A SLOT TO PUT IT IN (owner, 2026-08-18:
    -- "holding an SNS pistol in slot 3 with slot 3 active, trying to pickup
    -- another SNS pistol tells me I already have the max. But I don't, because
    -- there is no max for that id").
    --
    -- THE ITEM HE REPORTED IT AGAINST, by id, so this cannot be argued about.
    -- ----------------------------------------------------------------------
    local sns = BR.Config.WeaponById['snspistol']
    ok(BR.Inv.carryMax({ item = 'snspistol', kind = BR.ItemKind.WEAPON }) == nil,
        'an SNS Pistol has no carry ceiling -- no weapon does')

    inv = holdingWith({ item = 'snspistol', kind = BR.ItemKind.WEAPON,
                        rarity = sns.rarity, count = 1, clip = sns.clip },
                      BR.Config.Loot.slots)   -- slot 5 left empty
    local saidFree, snsFreeE = claimLater(1, { item = 'snspistol',
        kind = BR.ItemKind.WEAPON, rarity = sns.rarity, count = 1, clip = 1 })
    ok(inv.slots[BR.Config.Loot.slots]
        and inv.slots[BR.Config.Loot.slots].item == 'snspistol',
        'a second SNS Pistol goes to the FREE SLOT, cap or no cap',
        tostring(inv.slots[BR.Config.Loot.slots]
                 and inv.slots[BR.Config.Loot.slots].item))
    ok(inv.slots[1] and inv.slots[1].clip == sns.clip,
        'and the one in the active slot is not touched on the way past',
        ('clip %s'):format(tostring(inv.slots[1] and inv.slots[1].clip)))
    ok(#saidFree == 0, 'and NOTHING IS SAID, because nothing was refused',
        table.concat(saidFree, ' / '))
    ok(m.loot.items[snsFreeE.id] == nil, 'and it leaves the world, taken')

    -- The same pickup with every slot full is still refused -- the swap rule,
    -- not a ceiling -- and the sentence has to know the difference.
    inv = holdingWith({ item = 'snspistol', kind = BR.ItemKind.WEAPON,
                        rarity = sns.rarity, count = 1, clip = sns.clip })
    local saidFull, snsFullE = claimLater(1, { item = 'snspistol',
        kind = BR.ItemKind.WEAPON, rarity = sns.rarity, count = 1, clip = 1 })
    ok(inv.slots[1] and inv.slots[1].clip == sns.clip,
        'with no free slot the loaded one is still not traded for a floor copy',
        ('clip %s'):format(tostring(inv.slots[1] and inv.slots[1].clip)))
    ok(m.loot.items[snsFullE.id] ~= nil, 'and the floor copy stays put')
    ok((saidFull[1] or ''):find(sns.label, 1, true) ~= nil,
        'the refusal names the SNS Pistol', ('%q'):format(saidFull[1] or ''))
    -- THE EXACT SENTENCE THE OWNER WAS SHOWN, put through the same battery the
    -- shield goes through. This is the toast he quoted: "tells me I already
    -- have the max. But I don't, because there is no max for that id."
    pinsNoCeiling(saidFull[1] or '', 'SNS Pistol')

    -- ----------------------------------------------------------------------
    -- CASE 2 -- A CEILING THAT IS NOT REACHED FILLS, even from the active slot.
    --
    -- THE ONE THE LIKE-FOR-LIKE RULE MUST NOT EAT. A bandage in hand and a
    -- bandage on the floor is the same shape as a shield in hand and a shield
    -- on the floor; what makes it different is that there is room. Refusing
    -- here on "same item" alone would strand a player one short of their cap
    -- with the cure at their feet.
    -- ----------------------------------------------------------------------
    inv = holdingWith({ item = 'bandage', kind = BR.ItemKind.CONSUMABLE,
                        rarity = band.rarity, count = 1 })
    local saidFill, fillE = claimLater(1, { item = 'bandage',
        kind = BR.ItemKind.CONSUMABLE, rarity = band.rarity, count = 1 })
    ok(inv.slots[1] and inv.slots[1].count == 2,
        'a same-id pickup BELOW the cap fills the stack it is standing on',
        ('bandage x%s'):format(tostring(inv.slots[1] and inv.slots[1].count)))
    ok(#saidFill == 0, 'and says nothing, because it was not refused',
        table.concat(saidFill, ' / '))
    ok(m.loot.items[fillE.id] == nil, 'and the floor copy is gone, taken')

    -- ----------------------------------------------------------------------
    -- CASE 3 -- A CEILING THAT IS REACHED, COUNTED ACROSS EVERY SLOT (owner,
    -- 2026-08-18: "Anything with a max carry limit should be applied across all
    -- slots, not a per-slot basis").
    --
    -- THE ACTIVE SLOT HOLDS SOMETHING ELSE AND THERE IS A FREE SLOT WAITING,
    -- so a rule that reads one slot -- either the active one or the one it
    -- would land in -- lets this through and opens a second stack. Only a count
    -- over the whole inventory refuses it.
    -- ----------------------------------------------------------------------
    BR.Inv.reset(1)
    BR.Inv.give(1, { item = 'pistol', kind = BR.ItemKind.WEAPON,
                     rarity = 1, count = 1, clip = 12 })
    BR.Inv.give(1, { item = 'bandage', kind = BR.ItemKind.CONSUMABLE,
                     rarity = band.rarity, count = band.carryMax })
    inv = BR.Inv.of(1)
    inv.active = 1                       -- a PISTOL is in hand, not a bandage
    ok(inv.slots[2] and inv.slots[2].count == band.carryMax
        and inv.slots[3] == false,
        'set up: the cap sits in slot 2 with slots 3 to 5 free',
        ('slot2 x%s'):format(tostring(inv.slots[2] and inv.slots[2].count)))
    local saidCap, capE = claimLater(1, { item = 'bandage',
        kind = BR.ItemKind.CONSUMABLE, rarity = band.rarity, count = 1 })
    ok(inv.slots[3] == false,
        'a cap reached in ANOTHER slot still refuses -- no second stack opens',
        tostring(inv.slots[3] and inv.slots[3].item))
    ok(m.loot.items[capE.id] ~= nil, 'and the refused bandage stays in the world')
    ok((saidCap[1] or ''):find(tostring(band.carryMax), 1, true) ~= nil
        and (saidCap[1] or ''):find('Bandages', 1, true) ~= nil,
        'and THIS is the sentence that quotes the cap, because there is one',
        ('%q'):format(saidCap[1] or ''))

    -- AND WHEN BOTH RULES COULD FIRE, THE CEILING WINS. Bandages at the cap in
    -- the ACTIVE slot with the inventory full satisfies the like-for-like test
    -- and the carrymax test at once. The player is genuinely at a maximum, so
    -- they hear about the maximum -- "switch slots" would be advice that leads
    -- nowhere, since no slot in the game has room for a fourth bandage.
    inv = holdingWith({ item = 'bandage', kind = BR.ItemKind.CONSUMABLE,
                        rarity = band.rarity, count = band.carryMax })
    local saidBoth = claimLater(1, { item = 'bandage',
        kind = BR.ItemKind.CONSUMABLE, rarity = band.rarity, count = 1 })
    ok((saidBoth[1] or ''):find(tostring(band.carryMax), 1, true) ~= nil,
        'a same-id pickup AT the cap hears the cap, not the slot advice',
        ('%q'):format(saidBoth[1] or ''))
    ok(inv.slots[1] and inv.slots[1].count == band.carryMax,
        'and the stack it already had is untouched')

    -- A SPLIT STACK ALREADY OVER THE CAP DOES NOT GO NEGATIVE. Nothing in the
    -- game builds this today -- every carryMax equals its maxStack, so a capped
    -- item fills exactly one slot -- but INV_SWAP moves slots around, dropAll
    -- and the death box rebuild inventories from stored stacks, and /brgive
    -- writes whatever it is asked for. `cap - held` is NEGATIVE here, and a
    -- negative that reached `math.min(left, room)` would hand the player a
    -- stack of minus one.
    inv = holdingWith({ item = 'bandage', kind = BR.ItemKind.CONSUMABLE,
                        rarity = band.rarity, count = band.carryMax })
    inv.slots[3] = { item = 'bandage', kind = BR.ItemKind.CONSUMABLE,
                     rarity = band.rarity, count = 1 }   -- four, against a cap of three
    local saidSplit, splitE = claimLater(1, { item = 'bandage',
        kind = BR.ItemKind.CONSUMABLE, rarity = band.rarity, count = 1 })
    ok(inv.slots[1].count == band.carryMax and inv.slots[3].count == 1,
        'an inventory already OVER a cap takes nothing more and loses nothing',
        ('%s + %s'):format(tostring(inv.slots[1].count),
                           tostring(inv.slots[3].count)))
    ok(m.loot.items[splitE.id] ~= nil, 'the pickup stays in the world')
    ok((saidSplit[1] or ''):find(tostring(band.carryMax), 1, true) ~= nil,
        'and the sentence quotes the CONFIGURED cap, not what is held',
        ('%q'):format(saidSplit[1] or ''))

    -- ...AND THE UNLIKE SWAP IS UNTOUCHED. Every assertion above is worthless
    -- if it was bought by deleting the swap, so each refusal has its own
    -- control, run from the identical inventory.
    --
    -- SAME KIND, DIFFERENT ITEM. This is the pair that would have broken under
    -- the wider reading of "the same type": a Small Shield and a Shield are
    -- both CONSUMABLE, and refusing on kind would have refused this too.
    inv = holdingShields(shieldCfg.maxStack)
    local mini = BR.Config.ConsumableById['minishield']
    local saidM = claimLater(1, { item = 'minishield',
        kind = BR.ItemKind.CONSUMABLE, rarity = mini.rarity, count = 1 })
    ok(inv.slots[1] and inv.slots[1].item == 'minishield',
        'a DIFFERENT consumable still swaps into the active slot',
        tostring(inv.slots[1] and inv.slots[1].item))
    ok(#saidM == 0, 'and an accepted swap says nothing, because nothing failed')

    --- Full inventory of guns, `item` in the ACTIVE slot.
    local function holding(item)
        BR.Inv.reset(1)
        BR.Inv.give(1, { item = item, kind = BR.ItemKind.WEAPON,
                         rarity = 1, count = 1, clip = 12 })
        for _ = 2, BR.Config.Loot.slots do
            BR.Inv.give(1, { item = 'sawnoff', kind = BR.ItemKind.WEAPON,
                             rarity = 1, count = 1, clip = 8 })
        end
        local i = BR.Inv.of(1)
        i.active = 1
        return i
    end

    -- THE SAME GUN FOR THE SAME GUN, which costs a loaded magazine.
    inv = holding('pistol')
    inv.slots[1].clip = 12
    local saidP, pistolE = claimLater(1, { item = 'pistol',
        kind = BR.ItemKind.WEAPON, rarity = 1, count = 1, clip = 1 })
    ok(inv.slots[1] and inv.slots[1].item == 'pistol' and inv.slots[1].clip == 12,
        'the same gun off the floor does not swap your loaded one for it',
        ('clip %s'):format(tostring(inv.slots[1] and inv.slots[1].clip)))
    ok(m.loot.items[pistolE.id] ~= nil, 'and the floor copy stays put')
    ok((saidP[1] or '') ~= '', 'and that refusal talks too',
        ('%q'):format(saidP[1] or ''))

    -- THE CONTROL, and the reason the swap exists at all: a rifle over a
    -- pistol with five full slots is a real choice made in one motion.
    inv = holding('pistol')
    local rifleCfg = BR.Config.WeaponById['carbinerifle']
    local saidR = claimLater(1, { item = 'carbinerifle',
        kind = BR.ItemKind.WEAPON, rarity = rifleCfg.rarity, count = 1,
        clip = rifleCfg.clip })
    ok(inv.slots[1] and inv.slots[1].item == 'carbinerifle',
        'a DIFFERENT weapon still swaps into the active slot',
        tostring(inv.slots[1] and inv.slots[1].item))
    ok(#saidR == 0, 'and says nothing, because it was not refused')

    -- HOLDING ONE ELSEWHERE IS NOT HOLDING ONE. The rule is about the ACTIVE
    -- slot, because the active slot is the only thing a swap can throw away --
    -- so a second pistol in slot 4 does not block a pistol taking slot 1 from
    -- something else.
    inv = holding('sawnoff')
    BR.Inv.reset(1)
    BR.Inv.give(1, { item = 'sawnoff', kind = BR.ItemKind.WEAPON,
                     rarity = 1, count = 1, clip = 8 })
    for _ = 2, BR.Config.Loot.slots do
        BR.Inv.give(1, { item = 'pistol', kind = BR.ItemKind.WEAPON,
                         rarity = 1, count = 1, clip = 12 })
    end
    inv = BR.Inv.of(1)
    inv.active = 1
    claimLater(1, { item = 'pistol', kind = BR.ItemKind.WEAPON,
                    rarity = 1, count = 1, clip = 12 })
    ok(inv.slots[1] and inv.slots[1].item == 'pistol',
        'a pistol already in another slot does not block the swap',
        tostring(inv.slots[1] and inv.slots[1].item))

    -- THE CRATE PATH CANNOT REACH THIS RULE, and that is worth pinning rather
    -- than assuming: the container branch scatters and RETURNS, so a crate
    -- claim never calls BR.Inv.give at all. A player with no room opens the
    -- crate anyway and its contents land on the ground, where the loose-item
    -- path -- and every refusal above -- is what they meet.
    local crate = nil
    for _, e in pairs(m.loot.items) do
        if e.kind == 'chest' and e.contents and #e.contents > 0 then
            crate = e break
        end
    end
    if crate then
        holdingShields(shieldCfg.maxStack)   -- not one free slot anywhere
        BR.Roster.get(1).pos = { x = crate.x, y = crate.y, z = crate.z }
        local ccx, ccy = BR.LootCellOf(crate.x, crate.y)
        fire(BR.Net.LOOT_CELL, 1, { cx = ccx, cy = ccy })
        sent = {}
        local n = #crate.contents
        fakeTime = fakeTime + 1100
        fire(BR.Net.LOOT_CLAIM, 1, { id = crate.id })
        local scattered = 0
        for _, s in ipairs(eventsOf(BR.Net.LOOT_ADD)) do
            for _, entry in ipairs(s.args[1]) do
                if entry.fx and math.abs(entry.fx - crate.x) < 0.01 then
                    scattered = scattered + 1
                end
            end
        end
        ok(scattered == n,
            'a full inventory still opens a crate: the contents scatter',
            ('%d of %d'):format(scattered, n))
        ok(m.loot.items[crate.id] and m.loot.items[crate.id].kind == 'husk',
            'and the crate becomes a husk, never having consulted BR.Inv.give')
    else
        ok(false, 'no chest with contents in the layout to test against')
    end

    BR.Inv.reset(1)

    -- THE CRATE PATH IS NOT TOUCHED HERE, AND THAT IS A DECISION.
    -- tools/test_ringmaster.lua (loot.chest.refusals, loot.chest.husk,
    -- loot.chest.race) already pins its four silences deliberately. #171 is
    -- about the LOOSE-ITEM path -- the one the owner walks over -- so this
    -- block asserts the two ends of that path and leaves the audit's pins
    -- alone. The husk silence is reachable in play and is reported on the
    -- issue; see the note in server/loot.lua's husk branch for why the fix
    -- for it lives in the client and not here.

    -- THE PROPERTY, tested where it can be: silence is unreachable.
    --
    -- Driven directly rather than through a claim, because the reasons that
    -- were silent are the ones the handler cannot currently produce -- which is
    -- exactly why nobody noticed they had no message. A branch chain could pass
    -- every test above and still answer nothing to the next reason somebody
    -- adds; a table with a default cannot.
    for _, reason in ipairs({ 'carrymax', 'ammofull', 'noinv', 'sameitem',
                              'full', 'somethingaddedlater' }) do
        -- Called through a guard rather than directly: a missing refusalText
        -- should REPORT as the silence it is, not crash the suite and take
        -- every block after this one down with it.
        local text = BR.Loot.refusalText and BR.Loot.refusalText(reason,
            { item = 'bandage', kind = BR.ItemKind.CONSUMABLE }) or nil
        ok(type(text) == 'string' and #text > 0,
            ('a "%s" refusal still says something'):format(reason),
            ('%q'):format(tostring(text)))
    end

    -- The number in the sentence is the number that produced the refusal --
    -- one function, so the message cannot drift from the rule.
    ok(BR.Inv.carryMax({ item = 'grenade', kind = BR.ItemKind.THROWABLE })
        == nade.maxStack,
        'a throwable carry cap is its own maxStack')
    -- SHIELDS ARE UNCAPPED, so `carrymax` is not the reason a shield is ever
    -- refused. It was once true that this meant no shield refusal existed at
    -- all -- and that was the finding that sent #171 back to the owner, whose
    -- answer became `sameitem` above. The carry cap is still nil; what changed
    -- is that nil no longer implies silence.
    ok(BR.Inv.carryMax({ item = 'minishield',
                         kind = BR.ItemKind.CONSUMABLE }) == nil,
        'and shields are uncapped, so a shield refusal is never about a cap')
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

    -- ASK THE SERVER FOR THE LIST, THE WAY THE PANEL DOES, and pick the target
    -- out of it BY NAME (#172).
    --
    -- THE ALTERNATIVE WOULD HAVE BEEN A TEST THAT CANNOT FAIL. A report now
    -- names an opaque row token, and the tempting shortcut is to reach into the
    -- server's own token map for it -- which asserts that the map agrees with
    -- itself and would pass just as happily if `listFor` never sent the row at
    -- all. Going through PLAYERS_LIST means every one of these submissions
    -- proves the panel could have made it: the row was listed, it carried a
    -- token, and that token resolves. This suite's stated failure mode is a stub
    -- that re-encodes the assumption under test, so the round trip is the point.
    local function listSeenBy(src)
        sent = {}
        fire(BR.Net.PLAYERS_ASK, src)
        for i = #sent, 1, -1 do
            if sent[i].event == BR.Net.PLAYERS_LIST then return sent[i].args[1] end
        end
        return nil
    end

    --- The row `src` can see for the player called `name`, or nil.
    local function rowSeenBy(src, name)
        local l = listSeenBy(src)
        for _, p in ipairs((l or {}).players or {}) do
            if p.name == name then return p end
        end
        return nil
    end

    --- The token `src` would tick to report `name`. nil (rather than a
    --- fabricated string) when there is no such row, so a submission built on a
    --- missing row fails loudly instead of resolving to nothing quietly.
    local function tokenFor(src, name)
        local row = rowSeenBy(src, name)
        return row and row.id or nil
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

    -- THE ROW TOKEN IS WHAT A TARGET IS NAMED BY (#172), and the three
    -- properties the report path depends on are asserted before anything is
    -- built on them -- otherwise every submission below could be passing for
    -- the wrong reason.
    do
        local rowB = rowSeenBy(1, 'Bex')
        ok(rowB ~= nil, 'the list names the other players in the match')
        ok(rowB ~= nil and type(rowB.id) == 'string' and rowB.id ~= '',
            'and each row carries a token to report it by',
            rowB and tostring(rowB.id) or 'nil')
        -- THE SERVER ID IS GONE FROM THE WIRE. It had to be: it does not
        -- survive a disconnect and it is recycled inside one match.
        ok(rowB ~= nil and rowB.src == nil,
            'the row no longer carries a server id')
        -- AND THE TOKEN IS NOT THE LICENSE WITH THE PREFIX TRIMMED, which is
        -- the proposal this design replaced. Asserted rather than argued,
        -- because the failure it guards is silent: a token that CONTAINS the
        -- license would look exactly like this one from the panel's side.
        local rawB = BR.Identity.licenseOf(2)
        ok(rowB ~= nil and rowB.id ~= rawB
           and rowB.id ~= BR.Identity.qualified('license', rawB)
           and tostring(rowB.id):find(tostring(rawB), 1, true) == nil,
            'and it is not the license, trimmed or otherwise',
            rowB and tostring(rowB.id) or 'nil')
        -- STABLE ACROSS REFRESHES, or the panel's ticks would clear themselves
        -- every two seconds while a player was choosing.
        ok(rowB ~= nil and rowSeenBy(1, 'Bex').id == rowB.id,
            'the same row keeps the same token on the next refresh')
    end

    -- A FIRST REPORT OPENS A CASE.
    local idB = tokenFor(1, 'Bex')
    fired, sent = {}, {}
    fire(BR.Net.REPORT_SUBMIT, 1, {
        targets = { { id = idB, category = 'power_gaming' } },
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
        targets = { { id = idB, category = 'cheating' } },
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
    local idC = tokenFor(1, 'Cass')
    fired, sent = {}, {}
    fire(BR.Net.REPORT_SUBMIT, 1, {
        targets = { { id = idC, category = 'cheating' } },
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
    local idBfromC = tokenFor(3, 'Bex')
    fired, sent = {}, {}
    fire(BR.Net.REPORT_SUBMIT, 3, {
        targets = { { id = idBfromC, category = 'exploiting' } },
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
        targets = { { id = idBfromC, category = 'cheating' } },
    })
    ok(#firedOf('br:ringmaster:corroborate') == 0,
        'the second reporter cannot corroborate their own corroboration')
    ok((lastResult() or {}).ok == false, 'and is refused in turn')

    -- ONE SUBMISSION NAMING AN ALREADY-REPORTED PLAYER IS REFUSED WHOLE, rather
    -- than filing the rest quietly. A partial file has no honest answer: "1
    -- report sent" hides the refusal, and the panel has one toast.
    local idAfromC = tokenFor(3, 'Ayla')
    fired, sent = {}, {}
    fire(BR.Net.REPORT_SUBMIT, 3, {
        targets = {
            { id = idAfromC,  category = 'cheating' },  -- never reported by Cass
            { id = idBfromC,  category = 'cheating' },  -- already reported by Cass
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

    -- A TOKEN FROM THE PREVIOUS MATCH RESOLVES TO NOBODY. That comes from the
    -- map being per match and a submission only ever being looked up in the
    -- reporter's own -- not from the teardown free, which is a memory bound and
    -- is asserted separately in report.departed. The same player is listed
    -- again under a fresh token, so nothing a client kept can be replayed
    -- forward to join two rounds up. Sent first, because it must not be the
    -- thing that files the report the next assertion is counting.
    fired, sent = {}, {}
    fire(BR.Net.REPORT_SUBMIT, 1, {
        targets = { { id = idB, category = 'cheating' } },
    })
    ok(#firedOf('br:ringmaster:incident') == 0
       and #firedOf('br:ringmaster:corroborate') == 0,
        'last match\'s token names nobody in this one',
        tostring(#firedOf('br:ringmaster:incident')))
    ok((lastResult() or {}).ok == false, 'and the submission is refused')

    local idB2 = tokenFor(1, 'Bex')
    ok(idB2 ~= nil and idB2 ~= idB,
        'the same player is listed under a fresh token in the new match',
        tostring(idB2))

    fired, sent = {}, {}
    fire(BR.Net.REPORT_SUBMIT, 1, {
        targets = { { id = idB2, category = 'cheating' } },
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

describe('report.departed')
do
    --[[
        THE PLAYER LIST KEEPS THE PEOPLE WHO LEFT, AND THEY STAY REPORTABLE
        (#172).

        Owner: "the in-game player list doesn't show anyone who's left the
        match, but it should. We should still be able to report players after
        they've left the match."

        Leaving is the most common thing a cheater does after being noticed, so
        a list that forgets them closes the report window at exactly the moment
        it matters. Every assertion below is written so it would FAIL against
        the shipped behaviour rather than merely describe the new one -- this
        suite's own stated hazard is a test that re-encodes the assumption it is
        checking, and the report path is where that would be least visible.

        EVERY REPORT HERE GOES THROUGH PLAYERS_LIST FIRST. The token is read off
        the envelope the panel would have received, so a row that stopped being
        sent takes the submission down with it instead of being papered over by
        a token fetched from the server's own map.
    ]]
    local function lastResult()
        for i = #sent, 1, -1 do
            if sent[i].event == BR.Net.REPORT_RESULT then return sent[i].args[1] end
        end
        return nil
    end
    local function listSeenBy(src)
        sent = {}
        fire(BR.Net.PLAYERS_ASK, src)
        for i = #sent, 1, -1 do
            if sent[i].event == BR.Net.PLAYERS_LIST then return sent[i].args[1] end
        end
        return nil
    end
    local function rowSeenBy(src, name)
        for _, p in ipairs((listSeenBy(src) or {}).players or {}) do
            if p.name == name then return p end
        end
        return nil
    end
    local function tokenFor(src, name)
        local row = rowSeenBy(src, name)
        return row and row.id or nil
    end

    -- ---------------------------------------------------------------------
    -- A DEPARTED PLAYER IS STILL ON THE LIST, AND STILL REPORTABLE.
    -- ---------------------------------------------------------------------
    reset()
    queueUp(1, 'Ayla',  BR.Mode.SOLO.key)
    queueUp(2, 'Quinn', BR.Mode.SOLO.key)
    queueUp(3, 'Cass',  BR.Mode.SOLO.key)
    fakeTime = fakeTime + 300
    BR.Sched.step(fakeTime)
    for _, s in ipairs({ 1, 2, 3 }) do BR.Roster.setState(s, BR.PlayerState.ALIVE) end
    local m = theMatch()

    local licQuinn = BR.Identity.qualified('license', BR.Identity.licenseOf(2))
    local aliveBefore = BR.Server.aliveCount(m)

    -- THE TOKEN IS TAKEN WHILE THEY ARE STILL HERE, because that is the real
    -- sequence: the reporter opens the panel, sees the name, and the cheater
    -- quits while they are picking a category.
    local idQuinn = tokenFor(1, 'Quinn')
    ok(idQuinn ~= nil, 'a live player is listed with a token')

    fakeTime = fakeTime + 1000
    leave(2)

    ok(BR.Roster.get(2) == nil,
        'the disconnect takes them out of the live roster')

    local goneRow = rowSeenBy(1, 'Quinn')
    ok(goneRow ~= nil, 'but the player list still shows them (#172)')
    ok(goneRow ~= nil and goneRow.left == true,
        'visibly marked as gone', goneRow and tostring(goneRow.left) or 'nil')
    ok(goneRow ~= nil and goneRow.id == idQuinn,
        'under the SAME token they were ticked with before they left',
        goneRow and tostring(goneRow.id) or 'nil')

    -- AND NOT COUNTED AS PRESENT ANYWHERE ELSE. This is the constraint that
    -- makes the merge safe: it happens inside listFor and nowhere else, so
    -- the alive count, the win condition and the squad panel never see it.
    ok(BR.Server.aliveCount(m) == aliveBefore - 1,
        'and the alive count has dropped by one, not stayed flat',
        ('%d -> %d'):format(aliveBefore, BR.Server.aliveCount(m)))

    fired, sent = {}, {}
    fire(BR.Net.REPORT_SUBMIT, 1, {
        targets = { { id = idQuinn, category = 'cheating' } },
    })
    local inc = firedOf('br:ringmaster:incident')[1]
    ok(inc ~= nil, 'a player who has left can still be reported (#172)')
    ok(inc ~= nil and inc.subjectLicense == licQuinn,
        'against the license sealed when they disconnected',
        inc and tostring(inc.subjectLicense) or 'nil')
    ok((lastResult() or {}).ok == true, 'and the reporter is told it worked')

    -- ---------------------------------------------------------------------
    -- THE RECYCLED SERVER ID, WHICH IS THE FAILURE A NAIVE FIX WOULD SHIP.
    -- ---------------------------------------------------------------------
    -- Somebody else connects into the slot Quinn just freed and joins the same
    -- match. If the row still named a server id, the accusation above would
    -- have been filed against THIS player, under THEIR license, and counted
    -- against their record. Nothing downstream could tell.
    licenseOf[2] = 'stranger'
    join(2, 'Newcomer')
    BR.Roster.setMatch(2, m.id)
    BR.Roster.setState(2, BR.PlayerState.ALIVE)

    local licNewcomer = BR.Identity.qualified('license', BR.Identity.licenseOf(2))
    ok(licNewcomer ~= licQuinn,
        'the recycled id belongs to a different person', tostring(licNewcomer))

    local qRow = rowSeenBy(1, 'Quinn')
    local nRow = rowSeenBy(1, 'Newcomer')
    ok(qRow ~= nil and nRow ~= nil,
        'both the departed player and the id-recycler are listed')
    ok(qRow ~= nil and nRow ~= nil and qRow.id ~= nRow.id,
        'as two rows with two different tokens -- not one collided row',
        qRow and nRow and (qRow.id .. ' / ' .. nRow.id) or 'nil')

    -- Cass has reported nobody, so this submission is clean.
    fired, sent = {}, {}
    fire(BR.Net.REPORT_SUBMIT, 3, {
        targets = { { id = tokenFor(3, 'Quinn'), category = 'cheating' } },
    })
    local corr = firedOf('br:ringmaster:corroborate')[1]
    local inc2 = firedOf('br:ringmaster:incident')[1]
    local named = (corr and corr.license) or (inc2 and inc2.subjectLicense)
    ok(named == licQuinn,
        'reporting the departed row names the player who left, not the '
        .. 'stranger holding their old id',
        tostring(named))

    -- ---------------------------------------------------------------------
    -- THE RATE LIMITS HOLD ACROSS THE DEPARTURE BOUNDARY.
    -- ---------------------------------------------------------------------
    -- ONE REPORT PER (REPORTER, TARGET, MATCH), and quitting must not buy a
    -- fresh accusation slot from everybody who already reported you. Ayla
    -- reported Quinn while she was still connected, above.
    fired, sent = {}, {}
    fire(BR.Net.REPORT_SUBMIT, 1, {
        targets = { { id = idQuinn, category = 'exploiting' } },
    })
    ok(#firedOf('br:ringmaster:incident') == 0
       and #firedOf('br:ringmaster:corroborate') == 0,
        'a player already reported cannot be reported again by leaving',
        tostring(#firedOf('br:ringmaster:incident')))
    local again = lastResult()
    ok(again ~= nil and again.ok == false, 'the second one is refused')
    ok(again ~= nil and tostring(again.refused):find('Quinn', 1, true) ~= nil,
        'and names them, so the reporter can untick the right row',
        again and tostring(again.refused) or 'nil')

    -- MAX TARGETS PER SUBMISSION, counted the same whoever is on the list.
    ok(BR.Config.Report.maxTargets == 5,
        'the target cap is still five', tostring(BR.Config.Report.maxTargets))
    ok(BR.Config.Report.maxPerMatch == 3,
        'and the submission cap still three', tostring(BR.Config.Report.maxPerMatch))

    fired, sent = {}, {}
    local over = {}
    for i = 1, BR.Config.Report.maxTargets + 1 do
        over[i] = { id = idQuinn, category = 'cheating' }
    end
    fire(BR.Net.REPORT_SUBMIT, 3, { targets = over })
    ok((lastResult() or {}).ok == false
       and #firedOf('br:ringmaster:incident') == 0,
        'naming more than the cap is refused, departed rows included')

    -- MAX SUBMISSIONS PER MATCH. Cass has spent one (on Quinn); two more are
    -- allowed and the fourth is not -- and the departed player being among
    -- them changes nothing.
    fired, sent = {}, {}
    fire(BR.Net.REPORT_SUBMIT, 3, {
        targets = { { id = tokenFor(3, 'Ayla'), category = 'cheating' } },
    })
    ok((lastResult() or {}).ok == true, 'a second submission goes through')

    fired, sent = {}, {}
    fire(BR.Net.REPORT_SUBMIT, 3, {
        targets = { { id = tokenFor(3, 'Newcomer'), category = 'cheating' } },
    })
    ok((lastResult() or {}).ok == true, 'and a third')

    fired, sent = {}, {}
    fire(BR.Net.REPORT_SUBMIT, 3, {
        targets = { { id = tokenFor(3, 'Quinn'), category = 'cheating' } },
    })
    local spent = lastResult()
    ok(spent ~= nil and spent.ok == false
       and #firedOf('br:ringmaster:incident') == 0
       and #firedOf('br:ringmaster:corroborate') == 0,
        'the fourth is refused -- the allowance is not reset by a departure')
    ok(spent ~= nil and tostring(spent.refused):find('all 3 reports', 1, true) ~= nil,
        'for the reason that actually applies',
        spent and tostring(spent.refused) or 'nil')

    -- ---------------------------------------------------------------------
    -- A CLIENT THAT MAKES A TOKEN UP GETS NOWHERE.
    -- ---------------------------------------------------------------------
    -- The panel is a suggestion; this is what a modified client would send.
    -- Ayla still has submissions left, so a refusal here is about the token.
    fired, sent = {}, {}
    fire(BR.Net.REPORT_SUBMIT, 1, {
        targets = {
            { id = 'deadbeefdeadbeef', category = 'cheating' },
            { id = 2,                  category = 'cheating' },  -- the old shape
            { id = licQuinn,           category = 'cheating' },  -- the license itself
        },
    })
    ok(#firedOf('br:ringmaster:incident') == 0
       and #firedOf('br:ringmaster:corroborate') == 0,
        'an invented token, a server id and a license all name nobody')
    ok((lastResult() or {}).ok == false, 'and the submission is refused')

    -- ---------------------------------------------------------------------
    -- WHAT EVICTS A DEPARTED ROW: THE MATCH ENDING, AND NOTHING ELSE.
    -- ---------------------------------------------------------------------
    -- Retention is bounded by one match, which is also the window every report
    -- rule is scoped to. `BR.Roster.clearDeparted` runs at CLEANUP and again on
    -- destroy for a match that dissolved without reaching it.
    ok(#BR.Roster.departedIn(m.id) == 1,
        'the sealed entry is held for the length of the match',
        tostring(#BR.Roster.departedIn(m.id)))

    -- THE TOKEN MAP IS THE OTHER THING THAT HAS TO GO, and it is the one whose
    -- leak would be silent: nothing observable changes if it is never freed,
    -- because a later match never looks in an earlier match's bucket. So it is
    -- watched directly. Four entries -- Ayla, Cass, Quinn's sealed entry and
    -- the Newcomer who took her id.
    ok(BR.Players.tokenCount(m.id) == 4,
        'the match is holding one row token per entry ever listed in it',
        tostring(BR.Players.tokenCount(m.id)))

    BR.Match.destroy(m)

    ok(#BR.Roster.departedIn(m.id) == 0,
        'and is dropped when the match is destroyed',
        tostring(#BR.Roster.departedIn(m.id)))

    -- FIRED BY HAND, because the harness's TriggerEvent RECORDS server-side
    -- events rather than dispatching them -- so `destroy` announcing the
    -- teardown is captured in `fired` and no handler runs. Every block that
    -- exercises an on-destroy free does this (report.rules does it for the
    -- per-match report rules); it is driving the same event br_core really
    -- emits, one line later.
    ok(#firedOf('br:match:destroyed') > 0,
        'destroying the match announces it, which is what the free hangs off')
    fire('br:match:destroyed', nil, { matchId = m.id })

    ok(BR.Players.tokenCount(m.id) == 0,
        'and the row tokens go with it, so retention is bounded by one match',
        tostring(BR.Players.tokenCount(m.id)))

    -- AND THE LIST STOPS OFFERING THEM. Ayla is back in the lobby with no
    -- matchId, so the panel is answered `inMatch = false` -- there is no
    -- surface left for a stale row to appear on.
    local after = listSeenBy(1)
    ok(after ~= nil and after.inMatch == false,
        'a player with no match gets no list at all')
end

describe('report.killerPrompt')
do
    --[[
        "SUSPECT CHEATING? PRESS TAB TO REPORT <NAME>." -- #169's prompt, with
        #177's four corrections.

        WHAT THESE ASSERTIONS ARE ABLE TO CATCH, stated because this suite's
        named failure mode is a stub that re-encodes the assumption under test.
        Every one of them drives the real net events against the real handlers;
        the only things constructed by hand are a kill (two fields the damage
        path writes) and the DynamoDB acknowledgement (`br:incident:filed`,
        which is br_ringmaster's and cannot be produced without one).

          the day-old case      fails on the code as shipped. The prompt asked
                                `priorFor(matchId, ...)`, and the case is filed
                                in a match that is then DESTROYED, so the map it
                                read is empty by the time the second match asks.
          the one-time rule     fails on the code as shipped. Today's latch is
                                `nudged`, which only suppresses a second PROMPT
                                -- so a player who has already named the killer
                                is prompted again to name them twice.
          the isolation         the two "no second offer" cases below are reached
                                WITHOUT the player ever being prompted in that
                                match, so `nudged` is empty and cannot be what
                                suppresses them. If the usage check were deleted
                                and `nudged` left in place, they fail.
          the control          `no case, no prompt` runs FIRST, on licenses no
                                other block has used -- see freshMatch. Without
                                it every assertion here could be passing on a
                                leftover, because the map that answers them is
                                deliberately never freed.
    ]]

    --- The last REPORT_HINT addressed to one player, or nil.
    local function hintTo(src)
        for i = #sent, 1, -1 do
            local s = sent[i]
            if s.event == BR.Net.REPORT_HINT and s.target == src then
                return s.args[1]
            end
        end
        return nil
    end

    local function lastResultFor(src)
        for i = #sent, 1, -1 do
            local s = sent[i]
            if s.event == BR.Net.REPORT_RESULT and s.target == src then
                return s.args[1]
            end
        end
        return nil
    end

    --- Three players in a live match, on licenses NOTHING ELSE IN THIS FILE HAS
    --- TOUCHED.
    ---
    --- `openBy` in server/incident.lua is deliberately not freed at teardown --
    --- that IS #177's first correction -- so it carries every case the blocks
    --- above filed, for the life of the process. `license:test2` already has one
    --- against it by the time this block runs, so a prompt test written on the
    --- default licenses would pass on report.rules' leftovers no matter what the
    --- handler did. These names are what make the control assertion mean
    --- something.
    local function freshMatch()
        reset()
        licenseOf[1] = 'promptVictim'
        licenseOf[2] = 'promptKiller'
        licenseOf[3] = 'promptWitness'
        queueUp(1, 'Vic',  BR.Mode.SOLO.key)
        queueUp(2, 'Karl', BR.Mode.SOLO.key)
        queueUp(3, 'Wren', BR.Mode.SOLO.key)
        fakeTime = fakeTime + 300
        BR.Sched.step(fakeTime)
        for _, s in ipairs({ 1, 2, 3 }) do
            BR.Roster.setState(s, BR.PlayerState.ALIVE)
        end
        theMatch().state = BR.MatchState.PLAYING
        return theMatch()
    end

    --- Kill somebody the way the validated damage path records it, so
    --- BR.Combat.attributedKiller answers about a real hit rather than a field
    --- this test invented for it.
    local function killedBy(victimSrc, killerSrc)
        local v = BR.Roster.get(victimSrc)
        v.lastHitBy, v.lastHitAt = killerSrc, fakeTime
        BR.Roster.setState(victimSrc, BR.PlayerState.DEAD)
    end

    local function tokenFor(src, name)
        sent = {}
        fire(BR.Net.PLAYERS_ASK, src)
        for i = #sent, 1, -1 do
            if sent[i].event == BR.Net.PLAYERS_LIST then
                for _, p in ipairs(sent[i].args[1].players or {}) do
                    if p.name == name then return p.id end
                end
            end
        end
        return nil
    end

    local m1 = freshMatch()
    local kLic = BR.Identity.qualified('license', BR.Identity.licenseOf(2))
    local vLic = BR.Identity.qualified('license', BR.Identity.licenseOf(1))

    -- ---------------------------------------------------------- the control ---
    ok(#BR.Incident.openFor(kLic) == 0,
        'the fixture starts with no case open against the killer',
        tostring(#BR.Incident.openFor(kLic)))

    killedBy(1, 2)
    sent = {}
    fire(BR.Net.REPORT_KILLED, 1)
    ok(hintTo(1) == nil,
        'a player killed by somebody with no case open sees nothing at all')

    -- ------------------------------------------ (1) a case from an older match ---
    --
    -- Filed in this match, and then the match is destroyed -- which is the shape
    -- "a day-old case still in pending_review" has from the server's side. The
    -- acknowledgement is br_ringmaster's, so it is fired by hand; everything
    -- downstream of it is real.
    fire('br:incident:filed', nil,
        { incidentId = 'inc-yesterday', matchId = m1.id, subjectLicense = kLic })
    fire('br:match:destroyed', nil, { matchId = m1.id })

    ok(#BR.Incident.priorFor(m1.id, kLic) == 0,
        'the match-scoped map is emptied with the round it belonged to',
        tostring(#BR.Incident.priorFor(m1.id, kLic)))
    ok(#BR.Incident.openFor(kLic) == 1,
        'but the case is still open against the player',
        tostring(#BR.Incident.openFor(kLic)))

    local m2 = freshMatch()
    ok(m2.id ~= m1.id, 'and the next round is a different match',
        ('%s vs %s'):format(tostring(m1.id), tostring(m2.id)))

    killedBy(1, 2)
    sent = {}
    fire(BR.Net.REPORT_KILLED, 1)
    local hint = hintTo(1)
    ok(hint ~= nil and hint.kind == 'killer',
        'a case still open from a PREVIOUS match prompts the player it killed',
        hint and tostring(hint.kind) or 'no hint at all')
    ok(hint ~= nil and hint.name == 'Karl',
        'naming the killer the kill feed has already named',
        hint and tostring(hint.name) or 'nil')
    -- NOTHING ELSE ON THE WIRE. One display name the recipient has already been
    -- shown, and no license, no id and no list.
    ok(hint ~= nil and hint.license == nil and hint.incidentId == nil,
        'and carrying no license and no case id')

    -- ----------------------------------------- (2) the key is the whole action ---
    fired, sent = {}, {}
    fire(BR.Net.REPORT_CORROBORATE, 1)

    ok(#firedOf('br:ringmaster:incident') == 0,
        'pressing it opens no second case about a player who already has one',
        tostring(#firedOf('br:ringmaster:incident')))

    local corr = firedOf('br:ringmaster:corroborate')[1]
    ok(corr ~= nil, 'it corroborates, in one press, with no panel involved')
    if corr then
        ok(corr.incidentId == 'inc-yesterday',
            'onto the case that was already open -- the one from the older match',
            tostring(corr.incidentId))
        ok(corr.license == kLic, 'about the killer', tostring(corr.license))
        ok(corr.matchId == m2.id,
            'stamped with the match it happened in, not the one the case opened in',
            tostring(corr.matchId))
        ok(corr.reason == BR.Config.defaultReportCategory(),
            'under the category the prompt actually asked about',
            tostring(corr.reason))
    end

    -- PAID, like any other corroborator (#168). The id is in hand, so the claim
    -- does not wait for an acknowledgement.
    local claim = firedOf('br:report:claim')[1]
    ok(claim ~= nil and claim.incidentId == 'inc-yesterday' and claim.license == vLic,
        'and the player who pressed it is owed for it',
        claim and ('%s / %s'):format(tostring(claim.incidentId), tostring(claim.license))
            or 'no claim')

    -- TOLD, AND TOLD THE SAME THING A PANEL REPORT IS TOLD. "Added to an
    -- existing case" would leak that the person they just named is already under
    -- review, which is exactly what an offender's friend would go looking for.
    local res = lastResultFor(1)
    ok(res ~= nil and res.ok == true and res.filed == 1,
        'the player is told a report was sent, because one was',
        res and tostring(res.ok) or 'no answer at all')

    -- ------------------------------ (3) one action per offender, per match ---
    --
    -- ISOLATED FROM `nudged` ON PURPOSE. Wren is killed by Karl and corroborates
    -- WITHOUT EVER BEING PROMPTED -- so the "already nudged" latch is empty for
    -- Wren, and the only thing that can suppress the prompt below is the report
    -- usage check #177 part 4 asks for. Delete that check and this fails; delete
    -- `nudged` and it still passes.
    local m3 = freshMatch()
    killedBy(3, 2)
    fired, sent = {}, {}
    fire(BR.Net.REPORT_CORROBORATE, 3)
    ok(#firedOf('br:ringmaster:corroborate') == 1,
        'a player can corroborate without having been prompted first',
        tostring(#firedOf('br:ringmaster:corroborate')))

    sent = {}
    fire(BR.Net.REPORT_KILLED, 3)
    ok(hintTo(3) == nil,
        'and is never offered the prompt again for a player they have corroborated')

    -- AND THE OTHER HALF OF PART 4: reported from the panel first, then killed.
    -- This is the exact sequence the issue describes, and `nudged` is empty for
    -- Vic in this match too.
    local idKarl = tokenFor(1, 'Karl')
    ok(idKarl ~= nil, 'the panel can still name the killer')
    fired, sent = {}, {}
    fire(BR.Net.REPORT_SUBMIT, 1, {
        targets = { { id = idKarl, category = 'cheating' } },
    })
    -- THE FILING POLICY DID NOT MOVE WITH THE PROMPT, and this is where that is
    -- pinned. The prompt asks "any case at all"; a REPORT still asks "a case in
    -- THIS match", so a player with a day-old case who is reported tonight gets
    -- a NEW case for tonight -- three rounds of cheating are three things worth
    -- telling an admin about.
    ok(#firedOf('br:ringmaster:incident') == 1,
        'a panel report about them still opens a case for THIS match',
        tostring(#firedOf('br:ringmaster:incident')))

    killedBy(1, 2)
    sent = {}
    fire(BR.Net.REPORT_KILLED, 1)
    ok(hintTo(1) == nil,
        'and somebody who reported the killer from the panel is not prompted to name them twice')

    -- AND THE KEY IS AS DEAD AS THE PROMPT. An offer that is withdrawn while the
    -- action behind it still works is the same bug wearing a different shape --
    -- a modified client would simply skip the prompt.
    fired = {}
    fire(BR.Net.REPORT_CORROBORATE, 1)
    ok(#firedOf('br:ringmaster:corroborate') == 0,
        'pressing the key anyway does nothing once the action is spent',
        tostring(#firedOf('br:ringmaster:corroborate')))

    -- ------------------------------------------------- (4) still only the dead ---
    local m4 = freshMatch()
    BR.Roster.get(1).lastHitBy, BR.Roster.get(1).lastHitAt = 2, fakeTime
    fired, sent = {}, {}
    fire(BR.Net.REPORT_KILLED, 1)
    ok(hintTo(1) == nil, 'a living player is prompted about nobody')
    fire(BR.Net.REPORT_CORROBORATE, 1)
    ok(#firedOf('br:ringmaster:corroborate') == 0,
        'and cannot corroborate their way to a reward without dying first')
    ok(m4 ~= nil, 'the fixture built a match')
end

describe('report.matchBoundary')
do
    --[[
        "YOU HAVE ALREADY REPORTED X IN THIS MATCH" -- IN A MATCH WHERE THEY HAD
        REPORTED NOBODY.

        Owner, 2026-08-18, verbatim: "Match 1 - player 1 reports player 2,
        incident is resolved by kicking player 2 ... Next match - same 3 players
        - player 1 reports player 2 again, and is told they've already reported
        player 2 this match - but that's not possible."

        WHAT ACTUALLY CARRIES IT ACROSS, because `usage` does not. `usageFor`
        resets the moment the matchId it holds stops matching, and the first
        assertion below pins that: with nothing else happening, a report in match
        N+1 about somebody reported in match N is accepted. The carrier is the
        KILL PROMPT. #177 made it fire for a case open in ANY match, and pressing
        it wrote `usage.named` -- the per-(reporter, target, match) set the PANEL
        refuses on -- so answering the prompt in match N+1 about match N's case
        spent match N+1's panel slot, and the round's own cheating got no case.

        WHAT THESE ASSERTIONS CAN CATCH, stated because the naive fix passes the
        headline and breaks two rules on the way past:

          the boundary        fails on the code as shipped. Corroborate from the
                              prompt in the new match, then file from the panel:
                              refused, and no case opened for the new match.
          the same-match rule fails if the corroboration simply stops writing
                              `named`. A case opened THIS match and then
                              corroborated from the prompt must still refuse a
                              panel report -- otherwise one reporter lands twice
                              on one case, which is the half of #143 that the
                              refusal exists for.
          the one-action rule fails if the corroboration stops recording itself
                              at all. #177 part 4 must survive: no second prompt,
                              and the key dead, whichever match the case is from.

        THE SHARED-LICENSE CASE IS ASSERTED TOO, AND NOT AS A CONCESSION. The
        owner playtests with two clients on one license. `usage` is keyed by
        license and stays that way -- one license is one person, and that is what
        stops somebody buying report slots by reconnecting -- so the second
        client's keypress really does spend the first client's allowance. The
        block below pins which allowance: the prompt's, not the panel's.
    ]]

    local function lastResultFor(src)
        for i = #sent, 1, -1 do
            local s = sent[i]
            if s.event == BR.Net.REPORT_RESULT and s.target == src then
                return s.args[1]
            end
        end
        return nil
    end

    local function hintTo(src)
        for i = #sent, 1, -1 do
            local s = sent[i]
            if s.event == BR.Net.REPORT_HINT and s.target == src then
                return s.args[1]
            end
        end
        return nil
    end

    local function tokenFor(src, name)
        sent = {}
        fire(BR.Net.PLAYERS_ASK, src)
        for i = #sent, 1, -1 do
            if sent[i].event == BR.Net.PLAYERS_LIST then
                for _, p in ipairs(sent[i].args[1].players or {}) do
                    if p.name == name then return p.id end
                end
            end
        end
        return nil
    end

    local function killedBy(victimSrc, killerSrc)
        local v = BR.Roster.get(victimSrc)
        v.lastHitBy, v.lastHitAt = killerSrc, fakeTime
        BR.Roster.setState(victimSrc, BR.PlayerState.DEAD)
    end

    --- Three solo players on the licenses named, in a live match.
    ---
    --- LICENSES PER CALL, because the shared-license half of this block needs
    --- two SOURCES on one license -- and because `openBy` in server/incident.lua
    --- is deliberately never freed, so every case any block in this file has
    --- filed is still open. A fresh name per scenario is what stops these
    --- passing on somebody else's leftovers.
    local function three(a, b, c)
        reset()
        licenseOf[1], licenseOf[2], licenseOf[3] = a, b, c
        queueUp(1, 'One',   BR.Mode.SOLO.key)
        queueUp(2, 'Two',   BR.Mode.SOLO.key)
        queueUp(3, 'Three', BR.Mode.SOLO.key)
        fakeTime = fakeTime + 300
        BR.Sched.step(fakeTime)
        for _, s in ipairs({ 1, 2, 3 }) do
            BR.Roster.setState(s, BR.PlayerState.ALIVE)
        end
        theMatch().state = BR.MatchState.PLAYING
        return theMatch()
    end

    --- File a real report from the panel, then hand back the answer.
    local function reportFromPanel(src, name)
        local id = tokenFor(src, name)
        fired, sent = {}, {}
        fire(BR.Net.REPORT_SUBMIT, src, {
            targets = { { id = id, category = 'cheating' } },
        })
        return lastResultFor(src), id
    end

    --- End a match the way the server does, including the free the report rules
    --- hang off. `destroy` announces it; the harness records events rather than
    --- dispatching them, so the announcement is driven by hand one line later --
    --- the same pattern report.rules and report.departed already use.
    local function endMatch(m)
        BR.Match.destroy(m)
        fire('br:match:destroyed', nil, { matchId = m.id })
    end

    -- ==================================================== the plain boundary ===
    --
    -- NOTHING BUT TWO MATCHES. If this ever fails, `usage` has stopped resetting
    -- and everything below it is measuring the wrong thing.
    local m1 = three('boundaryA', 'boundaryB', 'boundaryC')
    local subject  = BR.Identity.qualified('license', BR.Identity.licenseOf(2))
    local reporter = BR.Identity.qualified('license', BR.Identity.licenseOf(1))

    local first = reportFromPanel(1, 'Two')
    ok(first ~= nil and first.ok == true,
        'a report in the first match is accepted',
        first and tostring(first.refused) or 'no answer')
    ok(#firedOf('br:ringmaster:incident') == 1,
        'and opens a case', tostring(#firedOf('br:ringmaster:incident')))

    -- The acknowledgement br_ringmaster sends once the row is durable. Fired by
    -- hand because it is the console's, not br_core's; everything downstream of
    -- it here is real.
    fire('br:incident:filed', nil, {
        incidentId      = 'inc-boundary',
        matchId         = m1.id,
        subjectLicense  = subject,
        reporterLicense = reporter,
    })
    endMatch(m1)

    local m2 = three('boundaryA', 'boundaryB', 'boundaryC')
    ok(m2.id ~= m1.id, 'the next round is a different match',
        ('%s vs %s'):format(tostring(m1.id), tostring(m2.id)))

    local plain = reportFromPanel(1, 'Two')
    ok(plain ~= nil and plain.ok == true,
        'and the same reporter may report the same player again in it',
        plain and tostring(plain.refused) or 'no answer')

    -- ============================== the prompt, answered across the boundary ===
    --
    -- THE OWNER'S SEQUENCE. One case, one match apart, and the panel report that
    -- comes after the keypress is the one that was refused.
    local m3 = three('crossA', 'crossB', 'crossC')
    local subj3 = BR.Identity.qualified('license', BR.Identity.licenseOf(2))
    local rep3  = BR.Identity.qualified('license', BR.Identity.licenseOf(1))

    ok((reportFromPanel(1, 'Two') or {}).ok == true, 'match N: the report lands')
    fire('br:incident:filed', nil, {
        incidentId      = 'inc-cross',
        matchId         = m3.id,
        subjectLicense  = subj3,
        reporterLicense = rep3,
    })
    endMatch(m3)

    local m4 = three('crossA', 'crossB', 'crossC')

    -- THE PROMPT STILL FIRES ACROSS THE BOUNDARY, asserted on a DIFFERENT player
    -- so that `nudged` stays empty for the one every assertion below is about.
    -- That isolation is the whole reason this is player 3 and not player 1: with
    -- `nudged` set, "the prompt is not offered again" would pass on the latch
    -- rather than on the thing being tested.
    killedBy(3, 2)
    sent = {}
    fire(BR.Net.REPORT_KILLED, 3)
    ok((hintTo(3) or {}).kind == 'killer',
        'match N+1: the case from last round still prompts the player it killed',
        tostring((hintTo(3) or {}).kind))

    killedBy(1, 2)
    fired, sent = {}, {}
    fire(BR.Net.REPORT_CORROBORATE, 1)
    local across = firedOf('br:ringmaster:corroborate')[1]
    ok(across ~= nil and across.incidentId == 'inc-cross',
        'and the key still corroborates it, which is #177 part 1 and stays',
        across and tostring(across.incidentId) or 'nothing sent')

    -- ONE ACTION PER OFFENDER, ASKED BEFORE ANYTHING ELSE SPENDS A SLOT. Both of
    -- these run while `named` is still empty for this reporter, so the only
    -- thing that can suppress them is the corroboration's own record -- and
    -- `nudged` is empty for player 1 in this match, so it cannot be that either.
    fired = {}
    fire(BR.Net.REPORT_CORROBORATE, 1)
    ok(#firedOf('br:ringmaster:corroborate') == 0,
        'the key does nothing the second time, whichever match the case is from',
        tostring(#firedOf('br:ringmaster:corroborate')))
    sent = {}
    fire(BR.Net.REPORT_KILLED, 1)
    ok(hintTo(1) == nil,
        'and the prompt is not offered again for that offender (#177 part 4)')

    -- ...AND HERE IS THE REGRESSION. The player goes to the panel to report what
    -- happened TONIGHT, and until this fix was told they had already done it.
    BR.Roster.setState(1, BR.PlayerState.ALIVE)
    local tonight = reportFromPanel(1, 'Two')
    ok(tonight ~= nil and tonight.ok == true,
        'a panel report in the new match is ACCEPTED after answering the prompt',
        tonight and tostring(tonight.refused) or 'no answer')
    ok(#firedOf('br:ringmaster:incident') == 1,
        'and opens a case for THIS round, which is the rule the refusal was eating',
        tostring(#firedOf('br:ringmaster:incident')))

    -- ============================ a case from THIS match keeps the refusal ===
    --
    -- THE OTHER DIRECTION, and the one that fails if the corroboration simply
    -- stops writing `named`. The case belongs to this round, so a panel report
    -- about the same player would land a SECOND time on a case already carrying
    -- this reporter's name -- "the same opinion arriving twice", which #143
    -- refuses and which this refusal is for.
    local m5 = three('sameA', 'sameB', 'sameC')
    local subj5 = BR.Identity.qualified('license', BR.Identity.licenseOf(2))

    -- Opened by the ANTICHEAT rather than by this player, so the reporter has
    -- not spent anything of their own before the keypress.
    fire('br:incident:filed', nil, {
        incidentId     = 'inc-same',
        matchId        = m5.id,
        subjectLicense = subj5,
    })
    killedBy(1, 2)
    fired, sent = {}, {}
    fire(BR.Net.REPORT_CORROBORATE, 1)
    ok(#firedOf('br:ringmaster:corroborate') == 1,
        'the prompt corroborates this round\'s own case',
        tostring(#firedOf('br:ringmaster:corroborate')))

    BR.Roster.setState(1, BR.PlayerState.ALIVE)
    local twice = reportFromPanel(1, 'Two')
    ok(twice ~= nil and twice.ok == false,
        'and the panel then refuses the same player, because that case has their name on it',
        twice and tostring(twice.ok) or 'no answer')
    ok(twice ~= nil and tostring(twice.refused):find('already reported', 1, true) ~= nil,
        'for the reason that actually applies',
        twice and tostring(twice.refused) or 'nil')

    -- ================================================= two clients, one license ===
    --
    -- THE OWNER'S RIG. Sources 1 and 3 are one account; source 2 is the
    -- offender. Player 1 reports in match N; player 3 -- the same license -- is
    -- killed by the offender in match N+1 and answers the prompt.
    --
    -- THE KEYING IS NOT WEAKENED TO MAKE THIS WORK, and that is the point of the
    -- last two assertions: the account still holds ONE prompt action and ONE
    -- panel slot per offender per match. What changed is only which of the two
    -- the keypress spends.
    local m6 = three('sharedA', 'sharedB', 'sharedA')
    local subj6 = BR.Identity.qualified('license', BR.Identity.licenseOf(2))
    local rep6  = BR.Identity.qualified('license', BR.Identity.licenseOf(1))
    ok(rep6 == BR.Identity.qualified('license', BR.Identity.licenseOf(3)),
        'the fixture really does put two sources on one license',
        tostring(rep6))

    ok((reportFromPanel(1, 'Two') or {}).ok == true,
        'match N: the account files a report')
    fire('br:incident:filed', nil, {
        incidentId      = 'inc-shared',
        matchId         = m6.id,
        subjectLicense  = subj6,
        reporterLicense = rep6,
    })
    endMatch(m6)

    local m7 = three('sharedA', 'sharedB', 'sharedA')
    killedBy(3, 2)
    fired, sent = {}, {}
    fire(BR.Net.REPORT_CORROBORATE, 3)
    ok(#firedOf('br:ringmaster:corroborate') == 1,
        'match N+1: the OTHER client on that license answers the prompt',
        tostring(#firedOf('br:ringmaster:corroborate')))

    local shared = reportFromPanel(1, 'Two')
    ok(shared ~= nil and shared.ok == true,
        'and the first client can still file this round\'s report from the panel',
        shared and tostring(shared.refused) or 'no answer')

    -- ONE ACCOUNT, ONE PROMPT ACTION. The second client gets no prompt of its
    -- own, because the account has already answered for this offender -- which
    -- is the license keying doing exactly what it is there for.
    killedBy(1, 2)
    sent = {}
    fire(BR.Net.REPORT_KILLED, 1)
    ok(hintTo(1) == nil,
        'the account is not offered the prompt twice by using its second client')

    -- ...AND ONE PANEL SLOT. The report above spent it; a second one is refused
    -- from either client, which is the rule a shared license must not buy a way
    -- around.
    local again = reportFromPanel(3, 'Two')
    ok(again ~= nil and again.ok == false,
        'and the panel slot it spent is spent for the account, not for the client',
        again and tostring(again.ok) or 'no answer')
end

describe('report.hintAudience')
do
    --[[
        THE COURTESY NOTICE GOES TO THE ROUND, NOT TO THE TWO PEOPLE IN IT WHO
        ALREADY KNOW (#168 part 1, corrected by #180).

        The subject has been excluded since #93 and stays excluded -- a player
        who discovers they are under suspicion changes behaviour, which costs the
        case the evidence it was going to be made of. The REPORTER is the half
        #180 adds: being told how to report a player by the system you have just
        reported them to reads as though the report did not register.

        WHAT THIS CATCHES: the reporter exclusion is a new comparison against a
        new, OPTIONAL field on the acknowledgement, and the two ways to get it
        wrong are opposite and both silent. Skip nobody and the reporter is
        nagged; default the field to a sentinel and an anticheat filing -- which
        has no reporter at all -- excludes whoever the sentinel happens to match.
        Both cases are asserted, on the same fixture.
    ]]

    local function hintKinds()
        local out = {}
        for _, s in ipairs(sent) do
            if s.event == BR.Net.REPORT_HINT and (s.args[1] or {}).kind == 'exists' then
                out[s.target] = true
            end
        end
        return out
    end

    local function threeInAMatch()
        reset()
        licenseOf[1] = 'hintReporter'
        licenseOf[2] = 'hintSubject'
        licenseOf[3] = 'hintBystander'
        queueUp(1, 'Rae',  BR.Mode.SOLO.key)
        queueUp(2, 'Sid',  BR.Mode.SOLO.key)
        queueUp(3, 'Tam',  BR.Mode.SOLO.key)
        fakeTime = fakeTime + 300
        BR.Sched.step(fakeTime)
        for _, s in ipairs({ 1, 2, 3 }) do
            BR.Roster.setState(s, BR.PlayerState.ALIVE)
        end
        theMatch().state = BR.MatchState.PLAYING
        return theMatch()
    end

    -- ------------------------------------------------- a player's report ---
    local m = threeInAMatch()
    local subject  = BR.Identity.qualified('license', BR.Identity.licenseOf(2))
    local reporter = BR.Identity.qualified('license', BR.Identity.licenseOf(1))

    sent = {}
    fire('br:incident:filed', nil, {
        incidentId      = 'inc-hint-1',
        matchId         = m.id,
        subjectLicense  = subject,
        reporterLicense = reporter,
    })

    local told = hintKinds()
    ok(told[3] == true, 'the rest of the match is told reporting exists')
    ok(told[2] == nil,
        'the offender is not -- #93, and it must stay that way')
    ok(told[1] == nil,
        'and neither is the player who just filed the report (#180)')

    -- --------------------------------------------- and an anticheat filing ---
    --
    -- NO REPORTER AT ALL. The field is absent rather than empty, which is the
    -- whole reason it may not be defaulted: a sentinel would be a value that
    -- either matches nobody or, one day, matches somebody.
    local m2 = threeInAMatch()
    local subject2 = BR.Identity.qualified('license', BR.Identity.licenseOf(2))

    sent = {}
    fire('br:incident:filed', nil, {
        incidentId     = 'inc-hint-2',
        matchId        = m2.id,
        subjectLicense = subject2,
    })

    local told2 = hintKinds()
    ok(told2[1] == true and told2[3] == true,
        'an anticheat filing tells everybody it should -- there is no reporter to skip',
        ('1=%s 3=%s'):format(tostring(told2[1]), tostring(told2[3])))
    ok(told2[2] == nil, 'and still withholds it from the subject')

    -- ONCE PER MATCH. A second filing in the same round announces nothing, which
    -- is `remember` deriving "first" from the map rather than tracking it beside
    -- one.
    sent = {}
    fire('br:incident:filed', nil, {
        incidentId     = 'inc-hint-3',
        matchId        = m2.id,
        subjectLicense = subject2,
    })
    local told3 = hintKinds()
    ok(next(told3) == nil,
        'and a second filing in the same round says nothing to anybody')
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
    -- WHO IT IS FOR (#115, round four). The client's correction is now a watch
    -- that outlives the shot, and the only thing that can call it off early is
    -- the roster saying this player is out. Without an id on the wire there is
    -- nothing to look up, and a five-second watch would resurrect a teammate an
    -- enemy had genuinely just killed.
    ok(live and live.src == 2,
        'and it names the victim, so the watch can be called off',
        live and tostring(live.src) or 'nil')

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

-- ==========================================================================
-- A CLIENT, IN THE SERVER SUITE. (#115)
-- ==========================================================================
--
-- WHY THIS EXISTS. #115 has now been "fixed" twice from the symptom, and the
-- owner has reported it unchanged both times. The reason is stated plainly in
-- ef501ef's own message: `client/state.lua` is loaded by NO suite, so
-- `correctPed` -- the ONE piece of code in the entire project that can put a
-- falsely-killed squadmate back on the shooter's screen -- has never been
-- executed outside the game. A fix that cannot be run cannot be wrong in a way
-- anybody notices until a human boots a client.
--
-- So this block loads the real file into a sandboxed _ENV with a real (small)
-- model of the engine behind it, and drives the owner's exact sequence through
-- the REAL server handler that is already wired up above. Nothing here is a
-- fixture: the HIT_RESYNC frames that reach the client are the ones
-- server/damage.lua actually produced from a weaponDamageEvent.
--
-- WHAT THE ENGINE MODEL CLAIMS, AND WHY. Five rules, each of them the reason a
-- native in correctPed exists at all:
--
--   1. DEATH AND THE HEALTH NUMBER ARE TWO DIFFERENT THINGS. A fatal hit starts
--      CTaskDyingDead; it does not have to take the health value with it. A
--      headshot is the everyday example -- the ped is dying from the first
--      frame and `GetEntityHealth` still reads whatever the bullet left behind.
--   2. `IsEntityDead` settles LATE -- some frames after the task starts. This is
--      ef501ef's own premise; modelling it is what lets that fix be judged
--      rather than believed.
--   3. So during that window BOTH questions correctPed asks answer "alive":
--      the flag has not caught up and the number never fell. That is the whole
--      of #115 and it is why this model exists.
--   4. Writing health does NOT cancel a death task, and once the flag is set
--      `GetEntityHealth` reads 0 whatever was written. Health alone never
--      revives a ped -- client/probe.lua says exactly this, which is why
--      `ResurrectPed` is in the file at all.
--   5. `ResurrectPed` clears the task, clears the flag and restores health;
--      `ClearPedTasksImmediately` ends the dying animation and nothing else.
--
-- ...AND RULE 2 IS A NUMBER NOBODY MEASURED. "Some frames" was written as 64ms,
-- which is under correctPed's own 150ms poll -- so the suite handed the fix the
-- one settle time at which its exit condition cannot be wrong. That number is
-- now a KNOB (`opts.settle`) and the sweep below runs the owner's three shots
-- across three orders of magnitude of it. A fix that only works at one settle
-- time is a bet, and this file exists to stop us placing another one.
--
-- ENTITY OWNERSHIP IS MODELLED TOO (`opts.ownership`), and it is the one thing
-- in here that is NOT a claim about the logic. In GTA network play a ped is
-- owned by one machine, and a player's ped is always owned by that player --
-- writes from anybody else are the engine's to ignore. `opts.ownership = true`
-- makes SetEntityHealth / ResurrectPed / ClearPedTasksImmediately on the mate's
-- ped no-ops, which is the pessimistic end of the range.
--
-- Under that setting NO correction of any shape can work, and that is not a
-- defeat, it is the DISCRIMINATOR. The tests at the bottom pin it, including the
-- reason the obvious escape is not one: `NetworkRequestControlOfEntity` is
-- deprecated by Cfx.re over cheat abuse, and `sv_filterRequestControl` defaults
-- to refusing control requests for entities controlled by players -- which is
-- every player ped there is. So it is modelled as refusing, because that is what
-- a default-configured FiveM server does.
--
-- The default stays FAVOURABLE (writes land) so that the sweep is testing the
-- logic and nothing else. Which of the two the owner is actually looking at is
-- answered in game by `/brcorpse`, not here.

describe('resync.client')
do
    local CROOT = 'resources/[fivem-royale]/'

    -- Everything the sandbox may see of the host process. Explicit, so a native
    -- the client reaches for and this harness never defined is an immediate
    -- "attempt to call a nil value" rather than a silent no-op -- the failure
    -- mode that makes a green suite worthless.
    local STD = {
        assert = assert, error = error, ipairs = ipairs, next = next,
        pairs = pairs, pcall = pcall, rawequal = rawequal, rawget = rawget,
        rawlen = rawlen, rawset = rawset, select = select, xpcall = xpcall,
        setmetatable = setmetatable, getmetatable = getmetatable,
        tonumber = tonumber, tostring = tostring, type = type,
        math = math, string = string, table = table,
        coroutine = coroutine, unpack = table.unpack,
    }

    --- Boot one FiveM client with `client/state.lua` in it.
    --- @param netId integer   the network id its copy of the mate answers to
    --- @param opts table|nil  { settle = ms, ownership = bool }
    --- @return table
    local function newClient(netId, opts)
        opts = opts or {}
        local FLOOR = BR.Config.Match.healthFloor
        local MAXHP = BR.Config.Match.maxHealth
        -- ms before IsEntityDead agrees with the task. 64 is the number
        -- ef501ef/a8b22c7 assumed; the sweep below runs 16 to 3500 because
        -- nobody has measured it and the fix must not care.
        local SETTLE = opts.settle or 64
        -- true => this client does NOT own the mate's ped, and the engine
        -- silently drops every write to it.
        local OWNED = not opts.ownership
        -- ...AND THE OTHER WAY A REPAIR FAILS, WHICH THIS FILE HAD NO MODEL FOR
        -- (#115, round seven). `ownership` is the pessimistic reading where the
        -- native is refused outright. There is a second pessimistic reading the
        -- suite has never expressed: the native TAKES -- the ped is alive on the
        -- line after the write, so every counter in state.lua reports success --
        -- and the owner's next clone update puts the corpse straight back.
        --
        -- The two are indistinguishable from the write site and opposite in the
        -- readout, which is exactly why both have to be runnable here. Under
        -- this one `stuck` stays 0 forever while nothing whatsoever is fixed.
        local OVERWRITTEN = opts.overwritten == true
        local REVERT_MS = opts.revertMs or 100

        local env
        env = setmetatable({}, { __index = function(_, k) return STD[k] end })
        env._G = env

        local function load(list)
            for _, f in ipairs(list) do
                local chunk, err = loadfile(CROOT .. f, 't', env)
                if not chunk then
                    realPrint('\27[31mclient load error\27[0m ' .. f .. ': ' .. tostring(err))
                    os.exit(1)
                end
                chunk()
            end
        end

        -- The client's OWN br_lib. A client is a separate Lua state in the real
        -- game and it is one here too, so nothing this block does can reach
        -- back into the server suite's BR.
        env.BR = nil
        load({
            'br_lib/shared/enums.lua', 'br_lib/shared/protocol.lua',
            'br_lib/shared/names.lua', 'br_lib/shared/rng.lua',
            'br_lib/shared/geo.lua', 'br_lib/shared/clock.lua',
            'br_lib/config/match.lua', 'br_lib/config/storm.lua',
            'br_lib/config/map.lua', 'br_lib/config/weapons.lua',
            'br_lib/config/loot.lua', 'br_lib/config/audio.lua',
            'br_lib/config/peds.lua', 'br_lib/config/market.lua',
            'br_lib/shared/xp.lua', 'br_lib/shared/storm_solve.lua',
            'br_lib/shared/combat_solve.lua', 'br_lib/shared/loot_gen.lua',
        })

        -- ---------------------------------------------------------- engine ---

        local C = {
            now = 0,
            calls = { set = 0, resurrect = 0, cleartasks = 0, request = 0 },
            log = {},
            -- The squadmate's ped, as the SHOOTER's machine sees it.
            -- `scoped` is whether the NETWORK ID resolves at all on this
            -- machine. A ped that streams out takes its handle with it and
            -- comes back with a DIFFERENT one -- see C.restream below.
            mate = { handle = 9000 + netId, netId = netId, hp = MAXHP,
                     dead = false, dying = false, since = 0, exists = true,
                     scoped = true, src = opts.src or 2 },
        }
        local m = C.mate

        local function note(s)
            C.log[#C.log + 1] = ('%6dms  %s'):format(C.now, s)
        end
        C.note = note

        --- One engine frame of the death task: the flag catches up (rule 2).
        local function frame()
            -- THE OWNER'S SYNC ARRIVING, and it disagrees with us. Applied
            -- before the death task, because it is not a death task at all --
            -- it is the authoritative copy of this ped being re-cloned over the
            -- top of whatever this machine believes.
            if m.revertAt and C.now >= m.revertAt then
                m.revertAt = nil
                m.dead, m.dying, m.hp = true, false, 0
                note('the owner\'s sync arrives and puts the corpse back')
            end
            if not m.dying then return end
            if not m.dead and (C.now - m.since) >= SETTLE then m.dead = true end
        end

        --- A write that landed. Under `opts.overwritten` the owner takes it
        --- back a moment later; otherwise it stands.
        local function scheduleRevert()
            if OVERWRITTEN then m.revertAt = C.now + REVERT_MS end
        end

        env.NetworkDoesNetworkIdExist = function(id)
            return id == m.netId and m.scoped
        end
        env.NetworkGetEntityFromNetworkId = function(id)
            return (id == m.netId and m.scoped) and m.handle or 0
        end
        -- Handle 1 is OUR OWN ped (PlayerPedId). It has to exist and be
        -- readable, because the trap round six guards against is reaching for
        -- a squadmate and getting ourselves.
        env.DoesEntityExist = function(h)
            return h == 1 or (h == m.handle and m.exists)
        end
        env.GetEntityHealth = function(h)
            if h == 1 then return C.meDead and 0 or MAXHP end
            if h ~= m.handle then return 0 end
            return m.dead and 0 or m.hp
        end
        env.IsEntityDead = function(h)
            if h == 1 then return C.meDead == true end
            return h == m.handle and m.dead
        end
        -- The project's own gamerules.lua pairs this with IsEntityDead, and
        -- /brcorpse prints it. A settled corpse answers both.
        env.IsPedFatallyInjured = function(h) return h == m.handle and m.dead end
        --- WHO IS ALLOWED TO WRITE TO THIS PED.
        ---
        --- In network play the ped is owned by ONE machine and a player's ped is
        --- always owned by that player. A write from anybody else is the
        --- engine's to ignore -- so with `opts.ownership` set, every mutating
        --- native below counts the CALL and then does nothing, which is exactly
        --- what a dropped write looks like from Lua: no error, no return value,
        --- no effect.
        local function mayWrite()
            if OWNED then return true end
            note('DROPPED (this client does not own that ped)')
            return false
        end

        env.SetEntityHealth = function(h, v)
            if h ~= m.handle then return end
            C.calls.set = C.calls.set + 1
            if not mayWrite() then return end
            m.hp = v
            scheduleRevert()
            note(('SetEntityHealth(%d)  dying=%s dead=%s')
                :format(v, tostring(m.dying), tostring(m.dead)))
            if v <= FLOOR and not m.dying then m.dying, m.since = true, C.now end
        end
        env.ResurrectPed = function(h)
            if h ~= m.handle then return end
            C.calls.resurrect = C.calls.resurrect + 1
            if not mayWrite() then return end
            m.dead, m.dying, m.hp = false, false, MAXHP
            scheduleRevert()
            note('ResurrectPed')
        end
        env.ClearPedTasksImmediately = function(h)
            if h ~= m.handle then return end
            C.calls.cleartasks = C.calls.cleartasks + 1
            if not mayWrite() then return end
            -- Ends the dying ANIMATION. It does not un-flag a settled corpse,
            -- which is why the production code calls ResurrectPed first.
            if not m.dead then m.dying = false end
            note('ClearPedTasksImmediately')
        end

        -- CONTROL, AND WHY ASKING FOR IT IS NOT THE WAY OUT.
        --
        -- `NetworkHasControlOfEntity` answers the question /brcorpse prints in
        -- game. `NetworkRequestControlOfEntity` REFUSES, because that is what a
        -- default-configured FiveM server does: the native is deprecated over
        -- cheat abuse and `sv_filterRequestControl` defaults to blocking control
        -- requests for entities controlled by players. There is no player ped on
        -- any server that is not controlled by a player.
        env.NetworkHasControlOfEntity = function(h)
            return h == m.handle and OWNED
        end
        env.NetworkRequestControlOfEntity = function(h)
            if h ~= m.handle then return false end
            C.calls.request = C.calls.request + 1
            note('NetworkRequestControlOfEntity -> REFUSED (player ped)')
            return OWNED
        end

        -- ---------------------------------------------------- the runtime ---

        env.GetGameTimer = function() return C.now end
        env.GetCurrentResourceName = function() return 'br_core' end
        env.GetPlayerServerId = function() return 1 end
        env.PlayerId = function() return 0 end
        env.PlayerPedId = function() return 1 end

        -- THE OTHER WAY TO REACH A PLAYER'S PED, and the one that needs no
        -- netId on the wire. -1 is "that player is not on this machine", and
        -- GetPlayerPed(-1) is the LOCAL player -- the trap the production code
        -- guards against explicitly, so the model has to reproduce it.
        env.GetPlayerFromServerId = function(src)
            if src == m.src and m.scoped then return 7 end
            if src == 1 then return 0 end
            return -1
        end
        env.GetPlayerPed = function(ply)
            if ply == 7 then return m.handle end
            if ply == 0 or ply == -1 then return 1 end
            return 0
        end
        env.GetPedArmour = function() return 0 end
        env.SetPedArmour = function() end
        env.IsPauseMenuActive = function() return false end
        env.SetFrontendActive = function() end
        env.ExecuteCommand = function() end

        -- THE CONSOLE, CAPTURED. `/brcorpse` is the instrument this issue is
        -- now being read through, so the suite has to be able to run it and
        -- read what it printed -- otherwise the readout is the one part of the
        -- system nothing tests, which is how a readout comes to disagree with
        -- itself in front of the owner.
        C.out = {}
        env.print = function(s) C.out[#C.out + 1] = tostring(s) end

        local handlers = {}
        env.AddEventHandler = function(n, fn)
            handlers[n] = handlers[n] or {}
            handlers[n][#handlers[n] + 1] = fn
        end
        env.RegisterNetEvent = function() end
        local commands = {}
        env.RegisterCommand = function(n, fn) commands[n] = fn end
        -- EVERY LOCAL EVENT IS RECORDED, and it has to be recorded HERE rather
        -- than by subscribing: `br:ui:sendLocal` is answered by br_ui, which is
        -- a different resource and is not in this state at all, so there is no
        -- handler to hang a spy off. What this client says to the interface is
        -- the only observable the verdict screen has.
        C.said = {}
        env.TriggerEvent = function(n, ...)
            C.said[#C.said + 1] = { name = n, args = { ... } }
            for _, fn in ipairs(handlers[n] or {}) do fn(...) end
        end
        env.TriggerServerEvent = function() end

        --- The last `br:ui:sendLocal` of one kind, or nil.
        function C.toUi(kind)
            for i = #C.said, 1, -1 do
                local e = C.said[i]
                if e.name == 'br:ui:sendLocal' and e.args[1] == kind then
                    return e.args[2]
                end
            end
            return nil
        end

        -- THREADS ARE MODELLED, NOT MOCKED, and that is the point of the file.
        -- Every client suite in this repo stubs Citizen.CreateThread to a
        -- no-op, which makes correctPed's retry loop -- the entire fix in
        -- ef501ef -- literally unrunnable. Coroutines are what turn "the loop
        -- exists" into "the loop was entered N times and wrote M values".
        local threads = {}
        -- ...AND TIMERS, UNDER A FLAG. `SetTimeout` was a no-op here because
        -- #115 had no timer in it; the verdict screen is raised inside one
        -- (state.lua's 500ms wait for the placement deltas), so a block that
        -- asks whether the verdict appeared cannot run against a stub that
        -- swallows it. OFF BY DEFAULT so every block written before this one
        -- keeps the runtime it was written against.
        local timers = {}
        env.Citizen = {
            CreateThread = function(fn)
                threads[#threads + 1] =
                    { co = coroutine.create(fn), wake = C.now }
            end,
            Wait = function(ms) coroutine.yield(ms or 0) end,
            SetTimeout = opts.timeouts
                and function(ms, fn)
                    timers[#timers + 1] = { at = C.now + (tonumber(ms) or 0), fn = fn }
                end
                or function() end,
        }

        --- Advance the client by `ms`, one 16ms frame at a time.
        function C.pump(ms)
            local target = C.now + ms
            while C.now < target do
                C.now = math.min(C.now + 16, target)
                frame()
                -- Timers first, and taken off the list BEFORE they run: a
                -- callback that schedules another one must not be re-entered on
                -- the same frame, which is how a self-rescheduling clock turns
                -- into a hang rather than a test.
                local due = nil
                for i = #timers, 1, -1 do
                    if C.now >= timers[i].at then
                        due = due or {}
                        due[#due + 1] = timers[i].fn
                        table.remove(timers, i)
                    end
                end
                for i = #(due or {}), 1, -1 do
                    local okt, err = pcall(due[i])
                    if not okt then
                        realPrint('\27[31mclient timer error\27[0m ' .. tostring(err))
                    end
                end
                for i = #threads, 1, -1 do
                    local t = threads[i]
                    if C.now >= t.wake and coroutine.status(t.co) == 'suspended' then
                        local okr, wait = coroutine.resume(t.co)
                        if not okr then
                            realPrint('\27[31mclient thread error\27[0m ' .. tostring(wait))
                        end
                        if coroutine.status(t.co) == 'dead' then
                            table.remove(threads, i)
                        else
                            t.wake = C.now + (tonumber(wait) or 0)
                        end
                    end
                end
            end
        end

        load({ 'br_core/client/main.lua', 'br_core/client/state.lua' })
        env.BR.Sfx = { play = function() end }
        env.BR.State.me.src = 1
        env.BR.State.me.state = env.BR.PlayerState.ALIVE

        C.env = env
        C.threads = threads
        C.resync = handlers[env.BR.Net.HIT_RESYNC][1]
        C.feed   = handlers[env.BR.Net.DAMAGE_FEED][1]

        --- Deliver a net event to this client, exactly as the wire would.
        --- @param name string
        function C.recv(name, ...)
            for _, fn in ipairs(handlers[name] or {}) do fn(...) end
        end
        -- THE MIRROR'S REAL FRONT DOOR. Every #115 test until now hand-seeded
        -- `BR.State.roster[n] = { state = ALIVE }`, which quietly assumes the
        -- shape the standing check reads is the shape the SERVER publishes. It
        -- is an assumption of exactly the kind this issue is made of, so the
        -- handler is captured and driven with a real payload below.
        C.snapshotHandler = (handlers[env.BR.Net.SNAPSHOT] or {})[1]

        -- THREADS THE FILE OWNS FOR ITS WHOLE LIFE, counted once at load so the
        -- assertions below can go on saying "one watch, not ten" without
        -- accidentally counting round six's standing check as a watch.
        C.baseThreads = #threads
        function C.watches() return #threads - C.baseThreads end

        --- Run `/brcorpse` and hand back exactly what it printed.
        --- @return table lines
        function C.brcorpse()
            C.out = {}
            commands['brcorpse']()
            return C.out
        end

        --- The whole readout as one string, for an `ok()` detail line.
        function C.corpseText()
            return table.concat(C.brcorpse(), '\n       ')
        end

        --- THE PED GOES OUT OF SCOPE AND COMES BACK AS A DIFFERENT HANDLE.
        ---
        --- This is ordinary in a battle royale: a squadmate rounds a building,
        --- the entity is destroyed on this machine, and when they come back
        --- OneSync re-creates it -- same NETWORK id, new local handle. Anything
        --- holding the old handle is now writing to nothing at all, silently.
        --- @param gapMs integer  how long the network id fails to resolve
        function C.restream(gapMs)
            m.scoped = false
            note('ped streamed OUT (network id stops resolving)')
            C.pump(gapMs or 0)
            m.handle = m.handle + 1000
            m.scoped = true
            note(('ped streamed back IN as handle %d'):format(m.handle))
        end

        --- GTA applies the shooter's own bullet to their local copy, before the
        --- server has seen anything at all. This is the fact every comment in
        --- damage.lua and state.lua is written around.
        function C.bullet(dmg)
            if m.dead then
                note('bullet into a settled corpse')
                return false
            end
            m.hp = m.hp - dmg
            if m.hp <= FLOOR and not m.dying then
                m.dying, m.since = true, C.now
                note(('bullet -> local copy at %d, death task starts'):format(m.hp))
            else
                note(('bullet -> local copy at %d'):format(m.hp))
            end
            return true
        end

        --- A FATAL hit that does NOT take the health number with it (rule 1).
        --- The everyday version of this is a headshot: the ped is dying from
        --- the first frame and the number still reads perfectly healthy.
        function C.lethal(dmg)
            if m.dead then
                note('lethal hit into a settled corpse')
                return false
            end
            m.hp = m.hp - (dmg or 26)
            m.dying, m.since = true, C.now
            note(('LETHAL hit -> dying, and the number still reads %d'):format(m.hp))
            return true
        end

        function C.alive()
            return not m.dead and not m.dying
        end

        function C.describe()
            return ('hp=%d dead=%s dying=%s')
                :format(env.GetEntityHealth(m.handle), tostring(m.dead),
                        tostring(m.dying))
        end

        return C
    end

    -- ------------------------------------------------------------------------
    -- THE OWNER'S THREE SHOTS. This is the reproduction.
    -- ------------------------------------------------------------------------
    --
    -- "Friendly fire - I shot a squad mate, they got 0 damage, and on my screen
    --  they perished. After shooting their ped once more they sprung to life,
    --  t-posed, then was synced perfectly. I thought we almost had it - but I
    --  did it again, and now their ped is down for good."
    --
    -- SHOT 2 IS THE ONLY ONE THAT IS NOT A RACE, AND THAT IS THE ASYMMETRY.
    --
    --   shot 1  fired at a LIVING mate. The hit is fatal and the health number
    --           does not fall with it (rule 1), so for the few frames before
    --           `IsEntityDead` settles BOTH of correctPed's questions answer
    --           "alive": the flag has not caught up and the number never
    --           dropped. A correction that lands inside that window takes the
    --           single-write path, writes once, RETURNS, and the death finishes
    --           over the top of the value it just wrote. Corpse.
    --   shot 2  fired INTO that corpse. There is nothing left to race -- the
    --           flag settled seconds ago -- so the correction cannot help but
    --           take the watch path, and it resurrects. "Sprung to life,
    --           t-posed" is ResurrectPed followed by ClearPedTasksImmediately,
    --           in that order, which is what that branch does.
    --   shot 3  fired at the mate shot 2 just stood back up. A living ped
    --           again, so a race again, and lost the same way.
    --
    -- That is why the middle one worked and the outer two did not, and it is not
    -- "a race decided differently each time" -- one of the three has no race in
    -- it. The fix has to make the OUTCOME independent of the timing, so both
    -- round trips are driven below.
    local function threeShots(rtt, opts)
        opts = opts or {}
        squadMatch(2)
        local pistol = BR.Config.WeaponById['pistol']
        BR.Inv.reset(1)
        BR.Inv.give(1, { item = 'pistol', kind = BR.ItemKind.WEAPON, rarity = 1,
                         count = 1, clip = pistol.clip })
        BR.Inv.of(1).ammo[BR.AmmoType.LIGHT] = 200
        BR.Inv.of(1).active = 1

        local C = newClient(1002, opts)

        --- Squeeze the trigger once at the mate and let the answer come back.
        --- The frame that reaches the client is the one server/damage.lua
        --- actually produced -- there is no fixture anywhere in here.
        local function shoot(label)
            C.note('===== ' .. label .. ' =====')
            C.lethal(26)
            fakeTime = fakeTime + 400
            sent = {}
            fire('weaponDamageEvent', 1, 1, {
                damageType = 3, weaponType = pistol.hash, hitComponent = 0,
                weaponDamage = 26, hitGlobalIds = { 1002 },
            })
            local frames = {}
            for _, s in ipairs(sent) do
                if s.event == BR.Net.HIT_RESYNC and s.target == 1 then
                    frames[#frames + 1] = s.args[1]
                end
            end
            C.pump(rtt)
            for _, d in ipairs(frames) do C.resync(d) end
            -- Long enough for the death to SETTLE and for the watch to answer
            -- it. This used to be a flat 1500ms -- fine while the modelled
            -- settle was 64ms, and a test that ends before the corpse appears
            -- once it is not.
            C.pump((opts.settle or 64) + 2500)
            C.note(('after %s: %s'):format(label, C.describe()))
            return #frames
        end

        return C, shoot
    end

    -- 32ms: the owner's own box. This whole gamemode is developed and played
    -- against a server the player is standing next to (tools/deploy.sh), so the
    -- correction beating the death flag home is the NORMAL case there, not the
    -- unlucky one -- which is why the report reads as "every time" rather than
    -- "sometimes".
    for _, rtt in ipairs({ 32, 96 }) do
        local C, shoot = threeShots(rtt)
        local tag = ('(round trip %dms) '):format(rtt)

        local sentOne = shoot('shot 1')
        ok(sentOne == 1,
            tag .. 'the server DOES answer a friendly-fire shot with a correction',
            ('%d HIT_RESYNC frames'):format(sentOne))
        ok(C.alive(),
            tag .. 'SHOT 1: and the squadmate is still standing on the '
            .. 'shooter\'s screen',
            C.describe() .. '\n       ' .. table.concat(C.log, '\n       '))

        shoot('shot 2')
        ok(C.alive(), tag .. 'SHOT 2: still standing', C.describe())

        shoot('shot 3')
        ok(C.alive(),
            tag .. 'SHOT 3: and the third shot is no different from the first '
            .. '-- this is the one the owner called "down for good"',
            C.describe() .. '\n       ' .. table.concat(C.log, '\n       '))
    end

    -- ------------------------------------------------------------------------
    -- THE SWEEP: how long does a death take to show up? (#115, round four)
    -- ------------------------------------------------------------------------
    --
    -- Nobody knows, and that is the point. `IsEntityDead` is the LAST thing
    -- about a death to become true -- the project's own gamerules.lua pairs it
    -- with IsPedFatallyInjured for exactly that reason -- and the shipped fix
    -- stopped watching after two clean samples 150ms apart and gave up entirely
    -- after 900ms. Both of those are bets on this number.
    --
    -- The suite modelled it as 64ms, which is UNDER the poll interval, so the
    -- bet could not lose here. Raise it to 800 and the owner's report comes back
    -- word for word: shot 1 corpse, shot 2 fine, shot 3 down for good. That is
    -- not a race the network decides -- it is the same arithmetic every time,
    -- which is why the report reads as "still happening" rather than
    -- "sometimes".
    --
    -- So the fix is not allowed to know this number. Three orders of magnitude
    -- of it, and the answer has to be the same.
    for _, settle in ipairs({ 16, 250, 800, 2000, 3500 }) do
        local C, shoot = threeShots(32, { settle = settle })
        local tag = ('(death settles after %dms) '):format(settle)

        shoot('shot 1')
        ok(C.alive(), tag .. 'SHOT 1 leaves the squadmate standing',
            C.describe() .. '\n       ' .. table.concat(C.log, '\n       '))
        shoot('shot 2')
        ok(C.alive(), tag .. 'SHOT 2 leaves the squadmate standing', C.describe())
        shoot('shot 3')
        ok(C.alive(), tag .. 'SHOT 3 leaves the squadmate standing',
            C.describe() .. '\n       ' .. table.concat(C.log, '\n       '))
    end

    -- ------------------------------------------------------------------------
    -- ROUND FIVE: THE BET DID NOT GO AWAY, IT MOVED TO THE DOOR (#115).
    -- ------------------------------------------------------------------------
    --
    -- Round four took every guess out of the WATCH: no confirmation count, no
    -- settle time, no early exit -- "the deadline is the exit". It left one
    -- judgement standing, in front of the watch rather than inside it:
    --
    --     if not IsEntityDead(ped) and GetEntityHealth(ped) >= hp then return end
    --
    -- and the comment above it confessed the flaw in the same breath it shipped
    -- it: "A ped that is quietly dying reads exactly like a healthy one here."
    -- It does. That reading is not "nothing to write" -- it is "nothing to write
    -- YET", and the difference between the two is a coroutine that never starts.
    -- A watch is what survives being wrong about a single sample; the door is
    -- the one place left where a single sample still decides.
    --
    -- THE SUITE COULD NOT SEE IT because `C.lethal(dmg)` always took a number
    -- with it. `m.hp = m.hp - 26` on a full-health clone is 174, which is under
    -- any target the server ever sends, so the health half of that guard was
    -- false in every case ever run and the door was never tested. The harness
    -- modelled rule 1 ("a fatal hit need not take the health number with it")
    -- and then never exercised the version of it that matters.
    --
    -- Two ways in, both ordinary, and neither of them a race the network
    -- decides -- they are the same arithmetic every time, which is why the
    -- owner's report reads as "still happening":
    --
    --   A. THE NUMBER DOES NOT MOVE AT ALL. The everyday version is a headshot:
    --      CTaskDyingDead from the first frame, health untouched. The
    --      correction lands, reads 200 against a target of 200, and walks away
    --      from a ped that is already gone.
    --   B. THE SERVER'S NUMBER IS BELOW THE LOCAL COPY'S. It usually is: the
    --      mate has taken storm or enemy damage the shooter's clone never
    --      received, so the ledger reads 60 display (160 engine) while the
    --      clone still reads 174 after our own bullet. `174 >= 160` -- nothing
    --      to write, says the door, to a ped that is mid-death.
    --
    -- Both end the same way: no thread, no watch, and nothing in the client
    -- ever looks at that ped again. That is "down for good", exactly.
    for _, settle in ipairs({ 16, 250, 800, 2000, 3500 }) do
        local tag = ('(death settles after %dms) '):format(settle)

        -- A. the fatal hit that leaves the number alone.
        local C = newClient(1002, { settle = settle })
        C.env.BR.State.roster[2] = { state = C.env.BR.PlayerState.ALIVE }
        C.lethal(0)
        C.resync({ netId = 1002, hp = 200, src = 2 })
        ok(C.watches() == 1,
            tag .. 'a fatal hit that leaves the health number ALONE still '
            .. 'gets a watch',
            ('%d threads -- %s'):format(C.watches(), C.describe()))
        C.pump(settle + 2500)
        ok(C.alive(),
            tag .. '...and the squadmate is still standing afterwards',
            C.describe() .. '\n       ' .. table.concat(C.log, '\n       '))

        -- B. the server's number is BELOW the shooter's local copy.
        local D = newClient(1002, { settle = settle })
        D.env.BR.State.roster[2] = { state = D.env.BR.PlayerState.ALIVE }
        D.lethal(26)                                   -- clone 200 -> 174
        D.resync({ netId = 1002, hp = 160, src = 2 })  -- ledger says 60 display
        ok(D.watches() == 1,
            tag .. 'a clone standing ABOVE the ledger\'s number still gets a '
            .. 'watch when it is dying',
            ('%d threads -- %s'):format(D.watches(), D.describe()))
        D.pump(settle + 2500)
        ok(D.alive(),
            tag .. '...and that squadmate is still standing too',
            D.describe() .. '\n       ' .. table.concat(D.log, '\n       '))
        ok(D.env.GetEntityHealth(D.mate.handle) == 160,
            tag .. '...at the LEDGER\'s number, not the clone\'s',
            D.describe())
    end

    -- ------------------------------------------------------------------------
    -- ONE WATCH PER PED, NOT ONE PER BULLET.
    -- ------------------------------------------------------------------------
    do
        local C = newClient(1002, { settle = 800 })
        C.lethal(26)
        for _ = 1, 10 do C.resync({ netId = 1002, hp = 200, src = 2 }) end
        ok(C.watches() == 1,
            'a ten-round burst into one squadmate starts ONE watch, not ten',
            ('%d threads'):format(C.watches()))
        C.pump(4000)
        ok(C.alive(), '...and that one watch still stands them back up',
            C.describe())
    end

    -- ------------------------------------------------------------------------
    -- A WATCH MUST NOT OUTLIVE THE PLAYER IT IS CORRECTING.
    -- ------------------------------------------------------------------------
    --
    -- The watch now runs for five seconds, which is long enough for an ENEMY to
    -- finish the squadmate while it is still going. Standing that corpse back up
    -- would be #115 inverted and strictly worse: the body would be the truth and
    -- this client would be the thing deleting it. The server's verdict is in the
    -- mirror, so it is re-read every pass -- and `src` on the wire is what makes
    -- that lookup possible.
    do
        local C = newClient(1002, { settle = 200 })
        local cenv = C.env
        cenv.BR.State.roster[2] = { state = cenv.BR.PlayerState.ALIVE }

        C.lethal(26)
        C.resync({ netId = 1002, hp = 200, src = 2 })
        C.pump(600)
        ok(C.alive(), 'the watch stands a falsely-dead mate up', C.describe())

        -- ...and now they are killed for real, by somebody else.
        cenv.BR.State.roster[2].state = cenv.BR.PlayerState.DEAD
        C.lethal(26)
        C.pump(2500)
        ok(not C.alive(),
            'and once the SERVER says they are out, the watch lets the real '
            .. 'corpse lie', C.describe())
    end

    -- ------------------------------------------------------------------------
    -- THE DISCRIMINATOR: what this looks like if OWNERSHIP is the blocker.
    -- ------------------------------------------------------------------------
    --
    -- Everything above assumes the writes land. They land in this model because
    -- they are writes to a LOCAL COPY, and that is the favourable reading. The
    -- pessimistic one is that GTA ignores writes to a ped this machine does not
    -- own -- and a player's ped is always owned by that player.
    --
    -- Under that reading no correction can work, whatever shape it is, and these
    -- tests say so out loud rather than leaving a fourth round to discover it.
    -- The in-game answer to WHICH of the two is happening is `/brcorpse`.
    do
        local C, shoot = threeShots(32, { settle = 800, ownership = true })
        shoot('shot 1')
        ok(not C.alive(),
            'OWNERSHIP ENFORCED: the corpse stands, and this is what the owner '
            .. 'still sees if that is the blocker',
            C.describe() .. '\n       ' .. table.concat(C.log, '\n       '))
        ok(C.calls.set > 0 and C.calls.resurrect > 0,
            '...not because the client stopped trying -- it wrote and it '
            .. 'resurrected, and the engine dropped both',
            ('SetEntityHealth x%d, ResurrectPed x%d')
                :format(C.calls.set, C.calls.resurrect))
        ok(C.env.NetworkHasControlOfEntity(C.mate.handle) == false,
            '...this client does not control that ped')
        ok(C.env.NetworkRequestControlOfEntity(C.mate.handle) == false,
            '...and asking for control is REFUSED, which is what a default '
            .. 'FiveM server does: the native is deprecated over cheat abuse '
            .. 'and sv_filterRequestControl blocks player-controlled entities')
    end

    -- ------------------------------------------------------------------------
    -- The four assertions ef501ef named and did not write.
    -- ------------------------------------------------------------------------

    do
        -- 1. A CORRECTION IS WATCHED, NEVER FIRED AND FORGOTTEN. The ped here
        --    is dying with the flag not yet set -- the state the whole issue
        --    lives in -- and the correction must still be in force once the
        --    flag catches up.
        local C = newClient(1002)
        C.lethal(26)                                  -- dying; number reads 174
        C.resync({ netId = 1002, hp = 200 })
        C.pump(1000)
        ok(C.calls.resurrect > 0,
            'a correction that lands mid-death is still holding when the flag '
            .. 'settles, and resurrects',
            ('ResurrectPed x%d, SetEntityHealth x%d -- %s')
                :format(C.calls.resurrect, C.calls.set, C.describe()))
        ok(C.alive(), 'and the ped ends the exchange alive', C.describe())
    end

    do
        -- 2. THE NAMED ONE: a write followed by the ped flipping back to dead
        --    must be written again. Returning after one write is what let the
        --    death task finish over the top of it.
        local C = newClient(1002)
        C.mate.hp, C.mate.dead, C.mate.dying, C.mate.since = 140, false, true, 0
        C.resync({ netId = 1002, hp = 200 })
        C.pump(1000)
        ok(C.calls.set >= 2,
            'a correction the engine takes back is written again',
            ('SetEntityHealth x%d'):format(C.calls.set))
    end

    do
        -- 3. The death floor IS a dead number. Resurrecting a ped into 100
        --    would be reviving it into the value that keeps it dead.
        local C = newClient(1002)
        C.mate.hp, C.mate.dead, C.mate.dying = 0, true, false
        C.resync({ netId = 1002, hp = BR.Config.Match.healthFloor })
        C.pump(1000)
        ok(C.calls.resurrect == 0 and C.calls.set == 0,
            'correctPed(netId, healthFloor) does nothing at all',
            ('ResurrectPed x%d, SetEntityHealth x%d')
                :format(C.calls.resurrect, C.calls.set))
    end

    do
        -- 4. END TO END, through the real server: a shot into an ELIMINATED
        --    player's body must reach the client as nothing whatsoever.
        squadMatch(2)
        local pistol = BR.Config.WeaponById['pistol']
        BR.Inv.reset(1)
        BR.Inv.give(1, { item = 'pistol', kind = BR.ItemKind.WEAPON, rarity = 1,
                         count = 1, clip = pistol.clip })
        BR.Inv.of(1).ammo[BR.AmmoType.LIGHT] = 40
        BR.Inv.of(1).active = 1
        BR.Combat.eliminate(2, 'admin', nil)

        local C = newClient(1002)
        C.mate.hp, C.mate.dead = 0, true
        sent = {}
        fakeTime = fakeTime + 5000
        fire('weaponDamageEvent', 1, 1, {
            damageType = 3, weaponType = pistol.hash, hitComponent = 0,
            weaponDamage = 26, hitGlobalIds = { 1002 },
        })
        local delivered = 0
        for _, s in ipairs(sent) do
            if s.event == BR.Net.HIT_RESYNC and s.target == 1 then
                delivered = delivered + 1
                C.resync(s.args[1])
            end
        end
        C.pump(1000)
        ok(delivered == 0 and C.calls.resurrect == 0,
            'a shot into a real corpse reaches the shooter as no correction at all',
            ('%d frames, ResurrectPed x%d'):format(delivered, C.calls.resurrect))
    end

    do
        -- THE OTHER HALF OF THE T-POSE: a LIVING ped is not stood up.
        --
        -- The shooter's local copy of a mate carries GTA's own damage numbers,
        -- which owe the project's health mapping nothing at all -- four pistol
        -- rounds put it at engine 96, under BR.Config.Match.healthFloor, on a
        -- ped that is upright and running. Treating that number as proof of
        -- death fires ResurrectPed and ClearPedTasksImmediately at somebody who
        -- is very much alive, and the visible result of clearing a running
        -- animation is the T-POSE the owner reported.
        --
        -- The flag is the fact. The number only decides whether there is still
        -- something to correct.
        local C = newClient(1002)
        C.mate.hp, C.mate.dead, C.mate.dying = 96, false, false
        C.resync({ netId = 1002, hp = 200 })
        C.pump(1000)
        ok(C.calls.resurrect == 0 and C.calls.cleartasks == 0,
            'a living ped carrying GTA\'s damage number is corrected, not '
            .. 'resurrected and stripped of its animation',
            ('ResurrectPed x%d, ClearPedTasksImmediately x%d')
                :format(C.calls.resurrect, C.calls.cleartasks))
        ok(C.env.GetEntityHealth(C.mate.handle) == 200,
            '...and it IS corrected', C.describe())
    end

    -- ------------------------------------------------------------------------
    -- ...AND WHAT THE CHEAP PATH COSTS NOW.
    -- ------------------------------------------------------------------------
    do
        -- THIS TEST USED TO ASSERT `#C.threads == 0`, AND THAT ASSERTION WAS
        -- THE BUG WRITTEN DOWN. "A ped already standing at the server's number
        -- costs no thread" is only true if a single health read can tell a
        -- healthy ped from a dying one, and the entire issue is that it cannot
        -- -- so what it actually pinned was the door that walked away from a
        -- corpse-to-be. It is inverted rather than deleted, because the cost is
        -- still worth knowing: a thread, and no WRITE.
        --
        -- One per bullet is what the dedupe exists for, and the burst test
        -- above pins that at one thread for ten rounds. This pins the other
        -- half: the watch that has nothing to do does nothing.
        local C = newClient(1002)
        C.resync({ netId = 1002, hp = 200 })
        ok(C.watches() == 1,
            'a correction for a ped that looks fine STILL watches -- looking '
            .. 'fine is what a dying ped does',
            ('%d threads'):format(C.watches()))
        C.pump(6000)
        ok(C.calls.set == 0 and C.calls.resurrect == 0,
            '...and having nothing to do, it writes nothing at all',
            ('SetEntityHealth x%d, ResurrectPed x%d')
                :format(C.calls.set, C.calls.resurrect))
        ok(C.watches() == 0,
            '...and lets go of the thread at the deadline',
            ('%d threads'):format(C.watches()))
    end

    -- ------------------------------------------------------------------------
    -- ROUND SIX: THE READOUT WAS PRINTING TWO MOMENTS AS ONE (#115).
    -- ------------------------------------------------------------------------
    --
    -- The owner's paste, and it was read as a contradiction inside our own
    -- instrument -- a corpse, and a watch over it that saw nothing:
    --
    --   ENDED   netId 3  target hp 200  src 3
    --       exists 1  health 0  dead 1  fatally injured 1
    --       started 326858ms ago  passes 50  writes 0  resurrects 0
    --       saw a corpse false  ended: deadline
    --
    -- IT IS NOT A CONTRADICTION AND IT IS ARITHMETIC, NOT A THEORY. Every pass
    -- ends in one `Citizen.Wait(WATCH_POLL_MS)`, so fifty passes is seven and a
    -- half seconds of watching -- and the ped underneath was read 326858ms
    -- after that watch STARTED. The counters are the watch's life; the reading
    -- beneath them is the moment somebody typed the command, five minutes and
    -- eighteen seconds later. Nothing was watching when the ped died.
    --
    -- This drives the real /brcorpse and reads what it printed, because a
    -- readout nothing tests is how a readout comes to disagree with itself in
    -- front of the owner.
    do
        --- Does any printed line contain this?
        local function saidsomething(lines, needle)
            for _, l in ipairs(lines) do
                if l:find(needle, 1, true) then return true end
            end
            return false
        end

        -- Ownership enforced, so the corpse STAYS a corpse and the printout has
        -- something to be wrong about. This is the owner's paste, reproduced.
        local C = newClient(3, { settle = 800, src = 3, ownership = true })
        C.env.BR.State.roster[3] = { state = C.env.BR.PlayerState.ALIVE }
        C.resync({ netId = 3, hp = 200, src = 3 })
        C.pump(6000)                      -- the watch lives its budget and ends
        C.lethal(0)                       -- ...and only NOW does the ped die
        C.pump(320000)                    -- ...and only then does he type it
        local out = C.brcorpse()

        ok(saidsomething(out, 'saw a corpse false')
           and saidsomething(out, 'ended: deadline'),
            'the owner\'s readout is reproduced: a watch that ended on its '
            .. 'deadline having seen no corpse',
            table.concat(out, '\n       '))
        ok(saidsomething(out, 'RIGHT NOW:') and saidsomething(out, 'dead true'),
            '...with a ped that is a corpse right now', table.concat(out, '\n       '))
        ok(saidsomething(out, 'AT THE MOMENT IT ENDED')
           and saidsomething(out, 'health 200  dead false'),
            '...and the readout now says what the watch saw LAST -- a healthy, '
            .. 'living ped -- instead of leaving the two moments to be read as one',
            table.concat(out, '\n       '))
        ok(saidsomething(out, 'AFTER THE WATCH LET GO OF IT'),
            '...and names the gap outright, so the next reader does not have to '
            .. 'multiply passes by the poll interval to find it',
            table.concat(out, '\n       '))
        ok(saidsomething(out, 'ran for '),
            '...and prints how long the watch actually lived, next to how long '
            .. 'ago it started', table.concat(out, '\n       '))

        -- AND THE OWNERSHIP ANSWER, WHICH THIS READOUT WAS SWALLOWING. Every
        -- live fact was printed through `native(p) or '-'`, so FALSE came out
        -- as '-' and read as "could not ask". On the one line that decides
        -- whether any of this is fixable from Lua at all, "no" was printing as
        -- "unknown".
        ok(saidsomething(out, 'I control this ped: false'),
            'a native that answers FALSE now prints false -- it used to print '
            .. '"-", which is what "there was no ped to ask" prints',
            table.concat(out, '\n       '))
        ok(saidsomething(out, 'found a false corpse')
           and not saidsomething(out, 'corrected this session'),
            'and the standing check counts what it FOUND rather than claiming '
            .. 'it corrected anything -- under enforced ownership it finds the '
            .. 'same corpse every sweep and repairs none of them',
            table.concat(out, '\n       '))

        -- The other half: a ped that is alive must say so, not '-'.
        local L = newClient(3, { settle = 800, src = 3 })
        L.resync({ netId = 3, hp = 200, src = 3 })
        L.pump(6000)
        ok(saidsomething(L.brcorpse(), 'dead false'),
            '...and a LIVING ped reads "dead false" rather than "-"',
            table.concat(L.brcorpse(), '\n       '))
    end

    -- ------------------------------------------------------------------------
    -- ...AND THE THING THE READOUT WAS HIDING: THE BUDGET IS A BET (#115).
    -- ------------------------------------------------------------------------
    --
    -- Round four took the guess out of the predicate, round five took it out of
    -- the door, and both left it in the CLOCK. Before round six these two rows
    -- straddled WATCH_MS exactly: a death that showed up at 4900ms was
    -- corrected and one at 5200ms was down for good, permanently, with nothing
    -- in the client ever looking at that ped again.
    --
    -- The standing check makes the number irrelevant, which is the only kind of
    -- fix this issue has left: a false corpse is "the server says ALIVE and the
    -- ped here reads dead", and that is answerable at any moment without a
    -- bullet, a netId, or a deadline.
    for _, settle in ipairs({ 3500, 4900, 5200, 8000 }) do
        local C = newClient(3, { settle = settle, src = 3 })
        C.env.BR.State.roster[3] =
            { state = C.env.BR.PlayerState.ALIVE, hp = 100.0 }
        C.lethal(0)
        C.resync({ netId = 3, hp = 200, src = 3 })
        C.pump(settle + 3000)
        ok(C.alive(),
            ('a death that surfaces %dms after the shot is corrected, whether '
             .. 'that is inside the watch\'s budget or long outside it')
                :format(settle),
            C.describe() .. '\n       ' .. table.concat(C.log, '\n       '))
    end

    do
        -- THE OWNER'S OWN GAP, TO SCALE. His readout has the ped dying with
        -- nothing watching for at least five minutes. One bullet, a watch that
        -- finds nothing to do, and a corpse a full minute later.
        local C = newClient(3, { settle = 800, src = 3 })
        C.env.BR.State.roster[3] =
            { state = C.env.BR.PlayerState.ALIVE, hp = 100.0 }
        C.resync({ netId = 3, hp = 200, src = 3 })
        C.pump(6000)
        ok(C.alive() and C.calls.resurrect == 0,
            'a watch with nothing to do still ends having done nothing',
            C.describe())
        C.lethal(0)
        C.pump(60000)
        ok(C.alive(),
            'and a false corpse that appears a MINUTE after the last bullet is '
            .. 'still stood back up -- there is no longer a window to miss',
            C.describe() .. '\n       ' .. table.concat(C.log, '\n       '))
    end

    -- ------------------------------------------------------------------------
    -- CANDIDATE 1, EXECUTED: DOES THE WATCH HOLD A STALE PED HANDLE?
    -- ------------------------------------------------------------------------
    --
    -- It does not, and this is the test that says so rather than a reading of
    -- the source. A ped that leaves scope and comes back is a NEW local handle
    -- on the same network id, and the watch re-resolves the id every pass -- so
    -- it follows. What it does NOT survive is the gap itself: while the id
    -- fails to resolve the watch stops with `netid gone`, on the comment's word
    -- that "OneSync re-created it; the new copy is correct". The new copy is
    -- not correct, and before round six nothing looked again.
    do
        local C = newClient(3, { settle = 200, src = 3 })
        C.env.BR.State.roster[3] =
            { state = C.env.BR.PlayerState.ALIVE, hp = 100.0 }
        C.resync({ netId = 3, hp = 200, src = 3 })
        C.pump(500)
        local was = C.mate.handle
        C.restream(0)                       -- new handle, id never stops resolving
        ok(C.mate.handle ~= was, 'the ped came back as a different handle',
            ('%d -> %d'):format(was, C.mate.handle))
        C.lethal(0)
        C.pump(2000)
        ok(C.alive(),
            'a watch follows its ped through a handle change -- it resolves the '
            .. 'network id every pass, so candidate 1 is not the fault',
            C.describe() .. '\n       ' .. table.concat(C.log, '\n       '))

        -- ...and the same thing WITH a scope gap, which does kill the watch.
        local D = newClient(3, { settle = 200, src = 3 })
        D.env.BR.State.roster[3] =
            { state = D.env.BR.PlayerState.ALIVE, hp = 100.0 }
        D.resync({ netId = 3, hp = 200, src = 3 })
        D.pump(500)
        D.restream(300)
        D.lethal(0)
        D.pump(3000)
        ok(D.watches() == 0,
            'a scope gap DOES end the watch outright (`netid gone`)',
            ('%d watches'):format(D.watches()))
        ok(D.alive(),
            '...and the ped that comes back dead is corrected anyway, because '
            .. 'the standing check never needed the network id',
            D.describe() .. '\n       ' .. table.concat(D.log, '\n       '))
    end

    -- ------------------------------------------------------------------------
    -- AND THE THREE WAYS THE STANDING CHECK COULD BE #115 INVERTED.
    -- ------------------------------------------------------------------------
    --
    -- Every previous round of this fix has been dangerous in the same direction:
    -- something that stands a body up when the body was the truth. A check that
    -- runs forever, on every player, is the most dangerous shape yet -- so the
    -- three bodies it must never touch are pinned here.
    do
        -- 1. A DOWNED TEAMMATE IS POSED, NOT BROKEN. client/dbno.lua lays them
        --    out with NetworkResurrectLocalPlayer and holds them there.
        --    ClearPedTasksImmediately on that would strip the pose and T-pose a
        --    player who is waiting to be revived -- rounds three and four's bug
        --    with a new hat.
        local C = newClient(3, { settle = 100, src = 3 })
        C.env.BR.State.roster[3] =
            { state = C.env.BR.PlayerState.DBNO, hp = 5.0 }
        C.lethal(0)
        C.pump(3000)
        ok(C.calls.resurrect == 0 and C.calls.cleartasks == 0,
            'a DBNO teammate is never stood up by the standing check -- the '
            .. 'server says DBNO rather than ALIVE exactly so this can tell',
            ('ResurrectPed x%d, ClearPedTasksImmediately x%d')
                :format(C.calls.resurrect, C.calls.cleartasks))

        -- 2. A REAL CORPSE STAYS A CORPSE.
        local D = newClient(3, { settle = 100, src = 3 })
        D.env.BR.State.roster[3] =
            { state = D.env.BR.PlayerState.DEAD, hp = 0.0 }
        D.lethal(0)
        D.pump(3000)
        ok(not D.alive() and D.calls.resurrect == 0,
            'a player the server says is OUT is left where they fell',
            D.describe())

        -- 3. OUR OWN BODY IS NOT OURS TO TOUCH FROM HERE. GetPlayerPed(-1) is
        --    the local player, so a squadmate who is not on this machine
        --    resolves to US -- and our own corpse belongs to client/dbno.lua.
        --    S.me.src is deliberately cleared: with it set, the src comparison
        --    alone would carry this, and the guard that has to hold is the one
        --    that survives an unseeded mirror early in a session.
        local E = newClient(3, { settle = 100, src = 3 })
        E.env.BR.State.me.src = nil
        E.env.BR.State.roster[1] =
            { state = E.env.BR.PlayerState.ALIVE, hp = 100.0 }
        E.meDead = true
        E.pump(3000)
        ok(E.calls.resurrect == 0 and E.calls.set == 0,
            'and our own dead ped is never resurrected from here, even with an '
            .. 'unseeded mirror',
            ('ResurrectPed x%d, SetEntityHealth x%d')
                :format(E.calls.resurrect, E.calls.set))
    end

    -- ------------------------------------------------------------------------
    -- THE SERVER IS NOT SWALLOWING BULLETS, AND THAT IS WORTH PINNING.
    -- ------------------------------------------------------------------------
    --
    -- "The correction never arrived" is one of the readings /brcorpse invites,
    -- and it is worth being able to rule out from the suite rather than from
    -- the console. Every round of friendly fire produces exactly one HIT_RESYNC
    -- to the shooter -- so a watch that saw nothing saw nothing because there
    -- was nothing to see, not because it was never told.
    do
        squadMatch(2)
        local pistol = BR.Config.WeaponById['pistol']
        BR.Inv.reset(1)
        BR.Inv.give(1, { item = 'pistol', kind = BR.ItemKind.WEAPON, rarity = 1,
                         count = 1, clip = pistol.clip })
        BR.Inv.of(1).ammo[BR.AmmoType.LIGHT] = 200
        BR.Inv.of(1).active = 1
        local delivered, shots = 0, 12
        for _ = 1, shots do
            fakeTime = fakeTime + 120
            sent = {}
            fire('weaponDamageEvent', 1, 1, {
                damageType = 3, weaponType = pistol.hash, hitComponent = 0,
                weaponDamage = 26, hitGlobalIds = { 1002 },
            })
            for _, s in ipairs(sent) do
                if s.event == BR.Net.HIT_RESYNC and s.target == 1 then
                    delivered = delivered + 1
                end
            end
        end
        ok(delivered == shots,
            'every round of a friendly-fire burst reaches the shooter as '
            .. 'exactly one correction',
            ('%d corrections for %d bullets'):format(delivered, shots))
    end

    -- ------------------------------------------------------------------------
    -- ROUND SEVEN: WHICH OF THE FOUR THINGS IS BROKEN? (#115)
    -- ------------------------------------------------------------------------
    --
    -- The owner asked why the server cannot simply send the ledger's health to
    -- the shooter on a refused friendly-fire hit. It already does -- that is
    -- BR.Damage.resync -- so the honest answer is not "we do that" but "here is
    -- the link that fails", and there are exactly four candidates:
    --
    --   1. the correction is not SENT on every friendly-fire refusal
    --   2. it is sent and this client never WRITES
    --   3. it is written and the engine DROPS it (we do not own that ped)
    --   4. it is written, lands, and the owner's next sync OVERWRITES it
    --
    -- 1 and 2 are decidable here and are ours to fix. 3 and 4 are facts about a
    -- running session that only the engine can answer -- but /brcorpse can be
    -- made to ask them unambiguously, and that is what these pin. Before this
    -- round the readout could not separate 1 from 2 (both print as "no watch")
    -- and actively MISREAD 4 as success.

    --- Does any printed line contain this?
    local function said(lines, needle)
        for _, l in ipairs(lines) do
            if l:find(needle, 1, true) then return true end
        end
        return false
    end

    --- The first number captured by `pat` across the printed lines.
    local function num(lines, pat)
        for _, l in ipairs(lines) do
            local n = l:match(pat)
            if n then return tonumber(n) end
        end
        return nil
    end

    local FOUND    = '(%d+) time%(s%) this session'
    local STUCK    = 'of those: (%d+) were STILL dead'
    local RELAPSED = 'and (%d+) were found dead AGAIN'
    local REPAIRED = 'and (%d+) were upright again'
    local ARRIVED  = 'corrections off the wire: (%d+) arrived'
    local WATCHED  = '(%d+) started a watch'

    -- CANDIDATE 1: IS IT SENT? Every shape of friendly-fire refusal the server
    -- can produce, driven through the real weaponDamageEvent handler, must
    -- reach the shooter as exactly one correction. This is the answer the owner
    -- is owed about his own proposal, and it is the server's half.
    do
        local pistol = BR.Config.WeaponById['pistol']
        local function ffShot(setup)
            squadMatch(2)
            BR.Inv.reset(1)
            BR.Inv.give(1, { item = 'pistol', kind = BR.ItemKind.WEAPON,
                             rarity = 1, count = 1, clip = pistol.clip })
            BR.Inv.of(1).ammo[BR.AmmoType.LIGHT] = 200
            BR.Inv.of(1).active = 1
            if setup then setup() end
            sent = {}
            fakeTime = fakeTime + 500
            fire('weaponDamageEvent', 1, 1, {
                damageType = 3, weaponType = pistol.hash, hitComponent = 0,
                weaponDamage = 26, hitGlobalIds = { 1002 },
            })
            local n = 0
            for _, s in ipairs(sent) do
                if s.event == BR.Net.HIT_RESYNC and s.target == 1 then
                    n = n + 1
                end
            end
            return n
        end

        ok(ffShot() == 1,
            'SENT? a plain friendly-fire shot at a healthy squadmate answers '
            .. 'with exactly one correction')

        ok(ffShot(function()
               local v = BR.Roster.get(2)
               v.hp = 43.0
           end) == 1,
            'SENT? ...and so does one at a squadmate the ledger has on 43hp, '
            .. 'which is the case where the shooter\'s clone is ABOVE the '
            .. 'server\'s number')

        ok(ffShot(function() BR.Combat.defeat(2, 'gunshot', 3) end) == 1,
            'SENT? ...and a DOWNED squadmate is still corrected, because a '
            .. 'downed player is alive and their ped is not a corpse')

        -- ...AND THE ONE THAT MUST NOT BE SENT.
        ok(ffShot(function() BR.Combat.eliminate(2, 'admin', nil) end) == 0,
            'SENT? ...but a squadmate the ledger has ELIMINATED gets no '
            .. 'correction at all -- that corpse is the truth')
    end

    -- CANDIDATE 2: IS IT WRITTEN? And does the mirror the standing check reads
    -- actually LOOK like the one the server publishes? Every previous test in
    -- this file hand-seeded `roster[n] = { state = ALIVE }` and so proved
    -- nothing about the real payload's keys or fields. This drives
    -- BR.Roster.publicAll() -- the exact projection that goes on the wire --
    -- into the client and then makes the ped a false corpse.
    do
        squadMatch(2)
        local C = newClient(3, { settle = 200, src = 2 })
        local published = BR.Roster.publicAll()
        ok(published[2] ~= nil and published[2].state ~= nil,
            'the roster the server PUBLISHES carries a state field for a '
            .. 'squadmate, keyed by server id',
            ('roster[2] = %s'):format(
                published[2] and tostring(published[2].state) or 'nil'))

        C.env.BR.State.roster = published
        C.lethal(0)                       -- a false corpse, and no bullet sent
        C.pump(3000)
        ok(C.alive(),
            'WRITTEN? the standing check repairs a false corpse off the '
            .. 'SERVER\'S OWN published roster, with no hand-seeded mirror '
            .. 'anywhere -- so candidates 1 and 2 are both excluded and the '
            .. 'remaining question is entirely about the engine',
            C.describe() .. '\n       ' .. table.concat(C.log, '\n       '))
    end

    -- CANDIDATES 3 AND 4: THE READOUT HAS TO TELL THEM APART.
    --
    -- Both leave the owner looking at the same corpse. They are opposite
    -- findings about the engine and they have the same fix -- move the repair
    -- to the victim's machine -- but only one of them can be true, and saying
    -- which is the difference between a diagnosis and a sixth guess.
    do
        -- 3. THE ENGINE REFUSES THE WRITE. Dead on the line after resurrecting.
        local C = newClient(3, { settle = 200, src = 3, ownership = true })
        C.env.BR.State.roster[3] =
            { state = C.env.BR.PlayerState.ALIVE, hp = 100.0 }
        C.lethal(0)
        C.pump(3000)
        local out = C.brcorpse()
        ok((num(out, FOUND) or 0) > 0 and (num(out, STUCK) or 0) > 0,
            'REFUSED: found and stuck climb together when the engine drops '
            .. 'every write',
            ('found %s, stuck %s, relapsed %s, repaired %s')
                :format(tostring(num(out, FOUND)), tostring(num(out, STUCK)),
                        tostring(num(out, RELAPSED)),
                        tostring(num(out, REPAIRED))))
        ok((num(out, REPAIRED) or 0) == 0,
            '...and NOTHING is ever reported as repaired', table.concat(out, '\n       '))

        -- 4. THE WRITE LANDS AND THE OWNER TAKES IT BACK. This is the case the
        --    old readout called "the corpses are real and being fixed".
        local D = newClient(3, { settle = 200, src = 3, overwritten = true })
        D.env.BR.State.roster[3] =
            { state = D.env.BR.PlayerState.ALIVE, hp = 100.0 }
        D.lethal(0)
        D.pump(4000)
        local dout = D.brcorpse()
        ok((num(dout, STUCK) or -1) == 0,
            'OVERWRITTEN: stuck stays ZERO -- the native took every time, and '
            .. 'on the line after the write the ped was alive',
            ('found %s, stuck %s, relapsed %s, repaired %s')
                :format(tostring(num(dout, FOUND)), tostring(num(dout, STUCK)),
                        tostring(num(dout, RELAPSED)),
                        tostring(num(dout, REPAIRED))))
        ok((num(dout, RELAPSED) or 0) > 0,
            '...and RELAPSED is what catches it: the same player is a corpse '
            .. 'again on the very next sweep. Without this counter this case '
            .. 'is indistinguishable from success',
            table.concat(dout, '\n       '))
        ok(not D.alive(),
            '...and the owner is indeed still looking at a corpse',
            D.describe())

        -- ...AND THE HEALTHY CASE, so the counters are not simply always loud.
        local E = newClient(3, { settle = 200, src = 3 })
        E.env.BR.State.roster[3] =
            { state = E.env.BR.PlayerState.ALIVE, hp = 100.0 }
        E.lethal(0)
        E.pump(4000)
        local eout = E.brcorpse()
        ok((num(eout, REPAIRED) or 0) > 0 and (num(eout, RELAPSED) or 0) == 0,
            'WORKING: when the writes hold, repaired climbs and relapsed stays '
            .. 'at zero -- the three readings are a partition, not a mood',
            ('found %s, stuck %s, relapsed %s, repaired %s')
                :format(tostring(num(eout, FOUND)), tostring(num(eout, STUCK)),
                        tostring(num(eout, RELAPSED)),
                        tostring(num(eout, REPAIRED))))
    end

    -- ...AND "IT NEVER ARRIVED" MUST NOT PRINT AS "IT ARRIVED AND WE DECLINED".
    do
        local C = newClient(3, { settle = 200, src = 3 })
        local out = C.brcorpse()
        ok((num(out, ARRIVED) or -1) == 0,
            'a client nobody has shot at reports ZERO corrections off the '
            .. 'wire, which is the server\'s answer and not this file\'s',
            table.concat(out, '\n       '))

        -- One that arrives and is declined for a dead target number: the
        -- counters must show it ARRIVED, which is the distinction round seven
        -- exists to draw.
        local D = newClient(3, { settle = 200, src = 3 })
        D.resync({ netId = 3, hp = BR.Config.Match.healthFloor, src = 3 })
        local dout = D.brcorpse()
        ok((num(dout, ARRIVED) or 0) == 1 and (num(dout, WATCHED) or -1) == 0,
            'a correction that arrives and is declined reads as ARRIVED 1 / '
            .. 'watched 0 -- it used to be indistinguishable from one that was '
            .. 'never sent',
            table.concat(dout, '\n       '))
        ok(said(dout, 'for a dead target number'),
            '...and the reason it was declined is named',
            table.concat(dout, '\n       '))

        -- And a watch that never saw a corpse must not report "nil" on the one
        -- line that decides whether the engine was ever asked.
        local E = newClient(3, { settle = 200, src = 3 })
        E.resync({ netId = 3, hp = 200, src = 3 })
        E.pump(6000)
        local eout = E.brcorpse()
        ok(said(eout, 'never resurrected during this watch'),
            'a watch that never resurrected says so, rather than printing '
            .. '"nil" on the line that reads as the engine\'s verdict',
            table.concat(eout, '\n       '))
    end

    -- ======================================================================
    -- THE VERDICT SCREEN IS NOT ALLOWED TO DEPEND ON ONE MESSAGE.
    -- ======================================================================
    --
    -- Owner, 2026-08-18, playtesting in solos: "player 2 kills player 3, then
    -- player 3 goes to this weird state where the verdict screen was never shown
    -- but they're not DBNO and effectively a real corpse but stuck unable to do
    -- anything. No errors were logged."
    --
    -- WHAT THAT SENTENCE DESCRIBES, MECHANICALLY. Exactly two things in this
    -- client hang off `state == ENDED` and nothing else raises either: the
    -- SUMMARY envelope, which IS the verdict screen, and BR.Spawn.toLobby(true),
    -- which is the trip home. A client that does not process that one event is
    -- left standing in a finished match with neither -- and for a player who
    -- died, "standing" is a corpse on the ground. Nothing errors, so nothing is
    -- logged; a message simply did not arrive.
    --
    -- THE DIGEST WAS ALREADY THE SAFETY NET and covered every transition except
    -- the one that ends the round. It replayed WAITING for precisely this class
    -- of failure and refused ENDED on the grounds that "the real event always
    -- arrives". The four assertions below are what that claim is worth.
    --
    -- WHAT THIS CANNOT CLAIM, said plainly: it does not reproduce the owner's
    -- session. Nothing here shows WHY the event went missing -- the server sends
    -- it to every entry in the match, corpses included, and the block above this
    -- one is not about that. It pins the consequence: whichever channel notices
    -- the round is over, the player who was in it gets their verdict.
    describe('verdict.unconditional')

    --- A client that is ALIVE in a running solo match.
    local function inMatch()
        local C = newClient(9, { timeouts = true, src = 9 })
        local B = C.env.BR
        C.snapshotHandler({
            roster = { [1] = { src = 1, state = B.PlayerState.ALIVE,
                               hp = 100.0, armour = 0.0 } },
            match  = { state = B.MatchState.PLAYING, mode = B.Mode.SOLO.key,
                       endsAt = 0 },
            alive = 3, squadsAlive = 3, seq = 1, serverNow = 0,
        })
        return C, B
    end

    --- The roster delta that says I have been killed.
    local function killMe(C, B, seq)
        C.recv(B.Net.ROSTER_DELTA, {
            seq = seq or 2,
            deltas = { { op = 'update', src = 1,
                         e = { state = B.PlayerState.DEAD, hp = 0.0 } } },
        })
    end

    --- The digest, as broadcast.lua sends it.
    local function digest(C, B, state)
        C.recv(B.Net.DIGEST, {
            alive = 1, squadsAlive = 1, state = state,
            endsAt = 0, mode = B.Mode.SOLO.key, serverNow = C.now,
        })
    end

    -- ------------------------------------------------ the ordinary path ---
    do
        local C, B = inMatch()
        killMe(C, B)
        C.said = {}
        C.recv(B.Net.STATE, { state = B.MatchState.ENDED, endsAt = 0,
                              mode = B.Mode.SOLO.key, serverNow = C.now })
        C.pump(1000)
        ok(C.toUi(B.Nui.SUMMARY) ~= nil,
            'a player killed in solos gets a verdict screen when the round ends')
    end

    -- ------------------------------------- ...and when the event never came ---
    --
    -- FAILS BEFORE THE FIX. The digest corrected the mirror and raised nothing,
    -- so this client sat as a corpse in a finished match for ever.
    do
        local C, B = inMatch()
        killMe(C, B)
        C.said = {}
        digest(C, B, B.MatchState.ENDED)
        C.pump(1000)
        ok(C.toUi(B.Nui.SUMMARY) ~= nil,
            'and still gets one when the ENDED broadcast never reached them',
            'no summary was ever raised')
    end

    -- ------------------------------------- ...and when the sweep arrives first ---
    --
    -- THE ORDERING THE SERVER CALLS A CONTRACT, BROKEN. server/match.lua
    -- broadcasts ENDED before the roster sweep for one stated reason: "processing
    -- the flip first reads as a voluntary leave (roundParticipant drops) and the
    -- verdict screen never shows". That is a contract about what the SERVER
    -- sends; it is not a guarantee about what this client processed. Here the
    -- flip to LOBBY lands with the mirror still reading `playing`, which is
    -- exactly what a lost ENDED looks like from inside noteMyState.
    --
    -- FAILS BEFORE THE FIX, and for a different reason than the block above --
    -- the digest replay alone does not rescue it, because participation has
    -- already been withdrawn by the time the replay fires.
    do
        local C, B = inMatch()
        killMe(C, B)
        C.recv(B.Net.ROSTER_DELTA, {
            seq = 3,
            deltas = { { op = 'update', src = 1,
                         e = { state = B.PlayerState.LOBBY } } },
        })
        C.said = {}
        digest(C, B, B.MatchState.ENDED)
        C.pump(1000)
        ok(C.toUi(B.Nui.SUMMARY) ~= nil,
            'a corpse swept home before the round\'s end was processed still gets one',
            'no summary was ever raised')
    end

    -- ------------------------------------------------ and NOT for a bystander ---
    --
    -- THE ASSERTION THAT KEEPS THE THREE ABOVE HONEST. "Unconditional" must mean
    -- "not conditional on which message noticed", never "shown to everybody": a
    -- player sitting in the lobby while other people's match ends has no verdict
    -- and gets their menu instead (live report, and the reason the participant
    -- gate exists at all).
    do
        local C = newClient(10, { timeouts = true, src = 10 })
        local B = C.env.BR
        C.snapshotHandler({
            roster = { [1] = { src = 1, state = B.PlayerState.LOBBY,
                               hp = 100.0, armour = 0.0 } },
            match  = { state = B.MatchState.PLAYING, mode = B.Mode.SOLO.key,
                       endsAt = 0 },
            alive = 3, squadsAlive = 3, seq = 1, serverNow = 0,
        })
        C.said = {}
        C.recv(B.Net.STATE, { state = B.MatchState.ENDED, endsAt = 0,
                              mode = B.Mode.SOLO.key, serverNow = C.now })
        digest(C, B, B.MatchState.ENDED)
        C.pump(1000)
        ok(C.toUi(B.Nui.SUMMARY) == nil,
            'somebody who was never in the round is shown no verdict at all')
    end

    describe('resync.client')
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

describe('roster.sampleRate')
do
    --[[
        THE SAMPLER'S INTERVAL AND THE CONFIG VALUE MUST BE THE SAME NUMBER.

        They were not, and neither of them was wrong in isolation, which is what
        made it survive: `BR.Config.Match.posSampleHz` said 2 and had NO READERS
        AT ALL, while roster.lua registered `BR.Sched.every(250, ...)` -- 4 Hz --
        directly. So the repository contained two statements about one rate,
        disagreeing by a factor of two, with the documented one being the value
        that had been tried in play and reverted.

        THIS BLOCK IS THE POINT OF THE CHANGE. Deriving the interval from the
        config is only half a fix; without something asserting they agree, the
        next person to hardcode a number here reintroduces exactly this bug and
        nothing notices. Two representations of one thing with nothing checking
        them is this project's signature failure.

        THE INVARIANT IS STATED AS A PRODUCT, NOT AS A COPY OF THE FORMULA.
        `interval * hz == 1000` is what "these agree" MEANS; re-writing
        `math.floor(1000 / hz)` here would be the test re-encoding the
        implementation, which is the other way this suite has produced false
        passes.
    ]]
    local job
    for _, s in ipairs(BR.Sched.stats()) do
        if s.name == 'roster.positions' then job = s break end
    end

    ok(job ~= nil, 'the position sampler is registered with the scheduler')

    local hz = BR.Config.Match.posSampleHz
    ok(type(hz) == 'number' and hz > 0,
        'and the config carries a usable rate', tostring(hz))

    ok(job ~= nil and hz and job.intervalMs * hz == 1000,
        'the interval it runs at IS the configured rate, not a number beside it',
        job and ('%s ms x %s Hz = %s'):format(
            tostring(job.intervalMs), tostring(hz),
            tostring(job.intervalMs * hz)) or 'no job')

    -- 4 Hz IS THE OWNER'S CALL AND IS PINNED HERE ON PURPOSE. At 2 Hz a
    -- teammate's beacon visibly hopped rather than moved, and that was played
    -- and reverted -- so a future edit down to 2 should have to delete this
    -- line and read why it exists.
    ok(hz == 4, 'and that rate is 4 Hz, which is the one that was kept',
        tostring(hz))
    ok(job ~= nil and job.intervalMs == 250,
        'so the sampler still runs every 250ms, exactly as it did hardcoded',
        job and tostring(job.intervalMs) or 'no job')

    -- THE GUARD, with values no shipped config would hold. Dividing by these
    -- blindly is not a wrong answer, it is `inf` and then a raise out of
    -- math.floor -- so the resource would fail to load and the traceback would
    -- point at the sampler rather than at the edited line.
    for _, bad in ipairs({ 0, -1, -0.5 }) do
        local ms = BR.Roster.sampleIntervalMs(bad)
        ok(math.type(ms) == 'integer' and ms > 0,
            ('a config of %s still yields a usable interval'):format(tostring(bad)),
            tostring(ms))
    end
    do
        local ms = BR.Roster.sampleIntervalMs(false)   -- nil-ish, not a number
        ok(math.type(ms) == 'integer' and ms > 0,
            'and so does one that is not a number at all', tostring(ms))
    end

    -- THE FALLBACK IS THE SHIPPED RATE, asserted rather than assumed -- the
    -- constant in roster.lua is the one place a second copy of this number
    -- lives, and this is what stops it drifting away from the config it is
    -- standing in for.
    ok(BR.Roster.sampleIntervalMs(0) == BR.Roster.sampleIntervalMs(),
        'a broken config degrades to the rate everybody has played',
        ('%s vs %s'):format(tostring(BR.Roster.sampleIntervalMs(0)),
            tostring(BR.Roster.sampleIntervalMs())))

    -- AND AN ABSURDLY HIGH RATE DOES NOT FLOOR TO ZERO, which would hand the
    -- scheduler a job with no interval.
    ok(BR.Roster.sampleIntervalMs(100000) >= 1,
        'and an impossible rate still leaves the job an interval',
        tostring(BR.Roster.sampleIntervalMs(100000)))
end

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

-- DOWN HERE BECAUSE IT RUNS MATCHES, per the note above match.reviveBeforePlaying.
-- Written beside the other party blocks first, where its six extra instances
-- moved the bus routes everything below them was written against and failed
-- match.busDescent -- which is exactly the coupling that note describes.
describe('party.threeClientsTwoSquads')
do
    -- THE PLAYTEST THIS WHOLE TUNABLE EXISTS FOR, PINNED AS ARITHMETIC.
    --
    -- Three dev clients are the entire playtest budget, and at the committed
    -- cap of four they are ONE team: no enemy anywhere on the map, so
    -- cross-squad damage and the nearby-versus-squad voice split cannot be
    -- produced in game at all. config/match.lua and tunables.dev.cfg.example
    -- both promise the same escape -- br_maxSquadSize 2, and three clients are
    -- two squads (2 + 1).
    --
    -- On 2026-08-19 that promise was reported broken: "with 3 players they were
    -- still placed into the same squad". IT IS NOT BROKEN, and this block is
    -- the proof, because the alternative to proving it is re-deriving it by
    -- hand every time somebody's cfg does not reach the box. What had not
    -- happened was the convar arriving; the shape below is what a server that
    -- DID receive it produces, on every path three clients can reach a match.
    --
    -- Including the path nothing covered: readying up ONE AT A TIME. Dev mode's
    -- minimum is one player, so the first click opens the match and the other
    -- two arrive through BR.Party.lateJoin, which does its own packing and
    -- never calls formSquads unless the shape has drifted. A cap honoured in
    -- formation and dropped on the late-join path would look exactly like the
    -- report that started this.

    --- Squad count and sorted sizes, off the roster.
    local function shape()
        local counts, ids = {}, {}
        BR.Roster.each(nil, function(_, e)
            if e.squadId then
                if not counts[e.squadId] then
                    counts[e.squadId] = 0
                    ids[#ids + 1] = e.squadId
                end
                counts[e.squadId] = counts[e.squadId] + 1
            end
        end)
        local sizes = {}
        for _, id in ipairs(ids) do sizes[#sizes + 1] = counts[id] end
        table.sort(sizes)
        return #ids, sizes
    end

    local function describeShape(n, sizes)
        local out = {}
        for _, s in ipairs(sizes) do out[#out + 1] = tostring(s) end
        return ('%d squad(s), sizes %s'):format(n, table.concat(out, '/'))
    end

    -- The committed default, restored at the end of the block. Every scenario
    -- below sets the cap explicitly rather than assuming it.
    local shipped = BR.Config.Match.maxSquadSize

    -- (1) Three solos who queue together.
    reset()
    BR.Server.devMode = true
    BR.Config.Match.autofill = true
    BR.Config.Match.maxSquadSize = 2
    for i = 1, 3 do join(i, 'P' .. i) end

    -- THE ARITHMETIC ITSELF, not only the outcome. formSquads has a second
    -- capacity pass that opens extra squads when the target falls short, and it
    -- is generous enough to produce 2 + 1 even from a target of one -- so the
    -- shape assertions below survive a broken target, and the target has to be
    -- pinned directly or nothing here would notice it going wrong. Dev mode is
    -- deliberately on: its one-squad floor is what makes the committed cap of
    -- four collapse three clients into one team, and 2 has to beat that floor.
    ok(BR.Party.squadTarget(3, 3) == 2,
        'cap 2: the formation target for three unpartied players is two squads',
        tostring(BR.Party.squadTarget(3, 3)))

    BR.Roster.each(nil, function(src) BR.Roster.setState(src, BR.PlayerState.WARMUP) end)
    ok(BR.Party.prospectiveSquads({ 1, 2, 3 }, BR.Mode.SQUAD.key) == 2,
        'and the start gate predicts the same two, so the queue cannot deadlock',
        tostring(BR.Party.prospectiveSquads({ 1, 2, 3 }, BR.Mode.SQUAD.key)))
    BR.Party.formSquads(fakeMatch(BR.Mode.SQUAD.key))
    local n, sizes = shape()
    ok(n == 2, 'cap 2: three solo clients form TWO squads', describeShape(n, sizes))
    ok(sizes[1] == 1 and sizes[2] == 2,
        'and the split is 2 + 1 -- a pair to test squad voice, and an enemy',
        describeShape(n, sizes))

    -- (2) The "they had already grouped up" explanation, ruled out BY THE SAME
    -- NUMBER. A party is never split across squads, so a standing party of
    -- three really would defeat any amount of formation arithmetic -- but the
    -- cap that forms the squads is the cap that gates the invite, so at 2 that
    -- party cannot exist to begin with. This is why br_maxSquadSize alone is
    -- sufficient and no "unparty everybody" switch is needed.
    reset()
    BR.Server.devMode = true
    BR.Config.Match.maxSquadSize = 2
    for i = 1, 3 do join(i, 'P' .. i) end
    ok(BR.Party.invite(1, 2) and BR.Party.respond(2, true), 'cap 2: a pair may party')
    ok(not BR.Party.invite(1, 3), 'and the third invite is refused by the cap')
    ok(#BR.Party.of(1).members == 2, 'so no party of three can exist at this cap')
    BR.Roster.each(nil, function(src) BR.Roster.setState(src, BR.PlayerState.WARMUP) end)
    BR.Party.formSquads(fakeMatch(BR.Mode.SQUAD.key))
    n, sizes = shape()
    ok(n == 2 and sizes[1] == 1 and sizes[2] == 2,
        'a partied pair plus a solo is still 2 + 1', describeShape(n, sizes))
    ok(BR.Roster.get(1).squadId == BR.Roster.get(2).squadId,
        'with the party kept whole')
    ok(BR.Roster.get(3).squadId ~= BR.Roster.get(1).squadId,
        'and the third client on the OTHER side of it')

    -- (3) Readying up one at a time: formation sees one player, the other two
    -- come through lateJoin. The cap has to survive that route too.
    reset()
    BR.Server.devMode = true
    BR.Config.Match.autofill = true
    BR.Config.Match.maxSquadSize = 2
    for i = 1, 3 do join(i, 'P' .. i) end
    local m = fakeMatch(BR.Mode.SQUAD.key)
    BR.Roster.setState(1, BR.PlayerState.WARMUP)
    BR.Party.formSquads(m)
    BR.Party.lateJoin(2, m)
    BR.Party.lateJoin(3, m)
    n, sizes = shape()
    ok(n == 2 and sizes[1] == 1 and sizes[2] == 2,
        'cap 2: three clients readying up one at a time are still 2 + 1',
        describeShape(n, sizes))

    -- (4) THE REPORTED SHAPE, AND WHAT THE SERVER NOW SAYS ABOUT IT.
    --
    -- At the committed cap of four, three clients in dev mode ARE one squad --
    -- and that is arithmetic, not a fault: ceil(3/4) is 1, and dev mode's
    -- one-squad floor does not raise it. (In production the floor is two, so
    -- the same three players would split -- which is why this only ever bites
    -- on the box where it matters.) Nothing about that round announced itself,
    -- so the console said "formed 1 squad(s)" and the operator went looking for
    -- a formation bug. The report has to name the live cap, say where it came
    -- from, and give the line that changes it.
    reset()
    BR.Server.devMode = true
    BR.Config.Match.autofill = true
    BR.Config.Match.maxSquadSize = 4
    for i = 1, 3 do join(i, 'P' .. i) end
    BR.Roster.each(nil, function(src) BR.Roster.setState(src, BR.PlayerState.WARMUP) end)
    local m4 = fakeMatch(BR.Mode.SQUAD.key)
    BR.Party.formSquads(m4)
    n, sizes = shape()
    ok(n == 1 and sizes[1] == 3,
        'cap 4 in dev mode: three clients are one squad -- the reported shape',
        describeShape(n, sizes))

    local said = table.concat(BR.Party.formationReport(m4), '\n')
    ok(said:find('maxSquadSize 4', 1, true) ~= nil,
        'the report names the cap that is actually live', said)
    ok(said:find('br_maxSquadSize is not set', 1, true) ~= nil,
        'and says the convar is NOT what set it -- the whole question', said)
    ok(said:find('ONE SQUAD IS EVERY PLAYER ON ONE TEAM', 1, true) ~= nil,
        'and says why one squad is useless rather than leaving it to be inferred',
        said)
    ok(said:find('set br_maxSquadSize 2', 1, true) ~= nil,
        'and names the exact line that produces two squads from three clients',
        said)

    -- (5) And when the cap DID come from the convar, it says so instead -- a
    -- report that blames the cfg either way is a report nobody can act on.
    BR.Config.Overrides.applied = {
        { convar = 'br_maxSquadSize', group = 'Match', key = 'maxSquadSize',
          from = 4, to = 4 },
    }
    said = table.concat(BR.Party.formationReport(m4), '\n')
    ok(said:find('set by br_maxSquadSize', 1, true) ~= nil,
        'an applied override is reported as the source', said)
    ok(said:find('br_maxSquadSize is not set', 1, true) == nil,
        'and the "not set" line is gone', said)
    BR.Config.Overrides.applied = {}

    -- (6) The party case gets a DIFFERENT answer, because lowering the cap on a
    -- running server would not separate a party that already exists -- nothing
    -- splits a party, at any size. Sending somebody to edit a cfg that cannot
    -- help them is worse than saying nothing.
    reset()
    BR.Server.devMode = true
    BR.Config.Match.maxSquadSize = 4
    for i = 1, 3 do join(i, 'P' .. i) end
    for i = 2, 3 do BR.Party.invite(1, i); BR.Party.respond(i, true) end
    ok(#BR.Party.of(1).members == 3, 'cap 4: a party of three can exist')
    BR.Roster.each(nil, function(src) BR.Roster.setState(src, BR.PlayerState.WARMUP) end)
    local mp = fakeMatch(BR.Mode.SQUAD.key)
    BR.Party.formSquads(mp)
    n = shape()
    ok(n == 1, 'and it is one squad, as a party always is')
    said = table.concat(BR.Party.formationReport(mp), '\n')
    ok(said:find('ONE PARTY', 1, true) ~= nil,
        'the report says the party is the reason, not the squad size', said)
    ok(said:find('never split across squads', 1, true) ~= nil,
        'and that no squad size separates them while they are grouped', said)

    -- (7) Solo mode has no squads to report on, and must not claim a shape.
    reset()
    BR.Server.devMode = true
    for i = 1, 3 do join(i, 'P' .. i) end
    BR.Roster.each(nil, function(src) BR.Roster.setState(src, BR.PlayerState.WARMUP) end)
    local ms = fakeMatch(BR.Mode.SOLO.key)
    BR.Party.formSquads(ms)
    said = table.concat(BR.Party.formationReport(ms), '\n')
    ok(said:find('solo match', 1, true) ~= nil,
        'solo mode reports itself as having no squads', said)
    ok(said:find('maxSquadSize', 1, true) == nil,
        'and does not offer a squad-size fix for a mode that has no squads', said)

    BR.Config.Match.maxSquadSize = shipped
end


describe('report.adminReward')
do
    --[[
        ADMINS REPORT NORMALLY AND ARE NEVER PAID FOR IT (#168 self-dealing).

        OWNER: "hmmm maybe instead of blocking admins from reporting we should
        just block them from getting paid. Can we do that instead?" And,
        unprompted, about the second path: "also remember admins can
        corroborate. they should still not be paid though."

        SO EVERY ASSERTION HERE COMES IN A PAIR, and that pairing IS the test.
        One half says the money did not move; the other says everything else
        did. A change that refused the report outright -- which is what this
        started as -- passes the first half of every pair in this block and
        fails the second, which is the point of writing them together.

        WHAT THESE ARE ABLE TO CATCH, stated because this suite's named failure
        mode is a stub that re-encodes the assumption under test:

          the unpaid claim    is asserted as the ABSENCE of `br:report:claim`,
                              and every one of those absences is set beside a
                              control that fires it -- the same case, the same
                              match, the same tick, a different reporter. So an
                              absence is the gate rather than a fixture that
                              never pays.
          the real case       the admin's own submission is checked for the
                              `br:ringmaster:incident` it opens, its subject and
                              its reporterLicense; the admin's corroboration for
                              the `br:ringmaster:corroborate` it emits and the
                              seq and count it moved. Gate the wrong thing --
                              return early anywhere -- and these fail.
          the spent slot      an admin who has reported somebody is refused when
                              they name them again, and is not prompted about a
                              killer they have already corroborated. The limits
                              are anti-spam, not a payment meter.
          the identical
          reply               the admin's REPORT_RESULT is compared FIELD BY
                              FIELD against an ordinary player's, key count
                              included. A different answer would be a probe:
                              any player able to compare two replies would learn
                              which accounts hold moderation grants.
          `ban`, NOT "STAFF"  the ordinary player in these fixtures holds five
                              scopes -- view, kick, spectate, notify, moderate
                              -- and is paid. A gate keyed on "has any grant"
                              passes everything else here and fails that.
          pay when unknown    a grants question that is never answered still
                              pays. Asserted here, and implicitly by every OTHER
                              block in this file: they all join players, all
                              emit a grants question, and none answers one.

        WHAT THIS BLOCK DELIBERATELY DOES NOT ASSERT is what br_stats does with
        a claim. tools/test_stats.lua already pins both directions of that --
        `br:report:claim` becomes a `br:ddb:awardClaim`, and a malformed or
        absent one becomes nothing at all -- so "no claim means no 250 Volts"
        is one chain covered in two files rather than a second copy here.

        THE TIMERS ARE DRIVEN RATHER THAN STUBBED OUT. The suite's SetTimeout is
        a no-op, which would make the give-up path untestable and would make
        `inflight` look like it never needs clearing -- a question that is never
        abandoned is also never asked twice. Replaced for the length of this
        block, restored at the end.
    ]]

    local SCOPE = BR.Grants.RESOLVE_INCIDENTS

    ok(SCOPE == 'ban',
        'the scope keyed on is the one the console resolves incidents with',
        tostring(SCOPE))

    -- ------------------------------------------------------------- timers ---
    local timers = {}
    SetTimeout = function(_ms, fn) timers[#timers + 1] = fn end
    local function runTimers()
        local due = timers
        timers = {}
        for _, fn in ipairs(due) do fn() end
    end

    -- ------------------------------------------------------------ helpers ---
    local function lic(name) return BR.Identity.qualified('license', name) end

    --- Every grants question in `fired`, oldest first.
    local function asks()
        local out = {}
        for _, f in ipairs(fired) do
            if f.event == 'br:ddb:grantsFetch' then
                out[#out + 1] = { req = f.args[1], license = f.args[2] }
            end
        end
        return out
    end

    local function asksAbout(license)
        local n = 0
        for _, a in ipairs(asks()) do
            if a.license == license then n = n + 1 end
        end
        return n
    end

    --- Answer the newest outstanding question about a license, as br_ddb does.
    ---
    --- THROUGH THE REAL EVENT, carrying the req the code chose, so the answer
    --- has to find its way home the way a real one would -- including past
    --- br_ringmaster's listener on this same event name, which is the collision
    --- the namespaced req exists to avoid.
    --- @return boolean  whether there was a question to answer
    local function reply(license, scopes, info)
        local all = asks()
        for i = #all, 1, -1 do
            if all[i].license == license then
                fire('br:ddb:grantsResult', nil, all[i].req, scopes, info or {})
                return true
            end
        end
        return false
    end

    local function claims()
        return firedOf('br:report:claim')
    end

    local function lastResultFor(src)
        for i = #sent, 1, -1 do
            local s = sent[i]
            if s.event == BR.Net.REPORT_RESULT and s.target == src then
                return s.args[1]
            end
        end
        return nil
    end

    local function hintTo(src)
        for i = #sent, 1, -1 do
            local s = sent[i]
            if s.event == BR.Net.REPORT_HINT and s.target == src then
                return s.args[1]
            end
        end
        return nil
    end

    local function listSeenBy(src)
        sent = {}
        fire(BR.Net.PLAYERS_ASK, src)
        for i = #sent, 1, -1 do
            if sent[i].event == BR.Net.PLAYERS_LIST then return sent[i].args[1] end
        end
        return nil
    end

    --- The token `src` would tick to report `name`, taken off the real list.
    local function tokenFor(src, name)
        local l = listSeenBy(src)
        for _, p in ipairs((l or {}).players or {}) do
            if p.name == name then return p.id end
        end
        return nil
    end

    --- Are two tables the same map of scalars, key count included?
    ---
    --- THE KEY COUNT IS THE HALF THAT MATTERS. Comparing only the fields this
    --- test knows about would pass happily the day somebody adds an `unpaid`
    --- or `admin` flag to the answer -- which is exactly the leak the
    --- comparison exists to prevent.
    local function sameShape(a, b)
        if type(a) ~= 'table' or type(b) ~= 'table' then return false end
        local n = 0
        for k, v in pairs(a) do
            n = n + 1
            if b[k] ~= v then return false end
        end
        for _ in pairs(b) do n = n - 1 end
        return n == 0
    end

    local function killedBy(victimSrc, killerSrc)
        local v = BR.Roster.get(victimSrc)
        v.lastHitBy, v.lastHitAt = killerSrc, fakeTime
        BR.Roster.setState(victimSrc, BR.PlayerState.DEAD)
    end

    --- Four players in a live match, on licenses this block names itself.
    ---
    --- NEVER REUSED ACROSS SECTIONS, for the reason report.prompt's `freshMatch`
    --- gives: the maps that answer these questions -- `openBy` in
    --- server/incident.lua, and the grants cache -- are deliberately not freed
    --- between matches, so a section written on a license an earlier one
    --- touched could pass on a leftover.
    ---
    --- 1 Boss   holds the resolving scope
    --- 2 Mark   the subject everybody reports
    --- 3 Plain  an ordinary player -- who in these fixtures is a MODERATOR with
    ---          five scopes and not the one that matters
    --- 4 Extra  a second ordinary player, for the controls that need one
    local function four(a, b, c, d)
        reset()
        licenseOf[1], licenseOf[2] = a, b
        licenseOf[3], licenseOf[4] = c, d
        -- CLEARED BEFORE THE JOINS, not after: joining is what emits the grants
        -- questions this block answers, so wiping `fired` afterwards would
        -- throw away the thing under test.
        fired, sent = {}, {}
        queueUp(1, 'Boss',  BR.Mode.SOLO.key)
        queueUp(2, 'Mark',  BR.Mode.SOLO.key)
        queueUp(3, 'Plain', BR.Mode.SOLO.key)
        queueUp(4, 'Extra', BR.Mode.SOLO.key)
        fakeTime = fakeTime + 300
        BR.Sched.step(fakeTime)
        for _, s in ipairs({ 1, 2, 3, 4 }) do
            BR.Roster.setState(s, BR.PlayerState.ALIVE)
        end
        theMatch().state = BR.MatchState.PLAYING
        return theMatch()
    end

    local MOD_SCOPES = { 'view', 'kick', 'spectate', 'notify', 'moderate' }

    -- ===================================================================== --
    -- (0) THE QUESTION IS ASKED AT CONNECT, NOT WHEN A REPORT ARRIVES
    -- ===================================================================== --
    --
    -- Priming is not an optimisation. Both reward decisions read the cache
    -- SYNCHRONOUSLY -- they have to, because the report rules beside them are
    -- synchronous -- so a cold cache is the rule not being applied. The prime
    -- has to happen, and it has to happen minutes before anybody can report.
    local m0 = four('sdColdBoss', 'sdColdMark', 'sdColdPlain', 'sdColdExtra')
    ok(asksAbout(lic('sdColdBoss')) == 1,
        'connecting asks the grants table about the player once',
        tostring(asksAbout(lic('sdColdBoss'))))
    ok(asksAbout(lic('sdColdMark')) == 1 and asksAbout(lic('sdColdExtra')) == 1,
        'and about every other player exactly once as well')

    -- ===================================================================== --
    -- (1) NO ANSWER MEANS PAY -- THE ASYMMETRY ARGUMENT
    -- ===================================================================== --
    --
    -- Nothing has answered, so this is the DynamoDB-unreachable state. The two
    -- failures are not symmetric: not paying wrongs an ORDINARY player, who is
    -- nearly everybody, silently and with nothing to appeal to; paying wrongly
    -- costs 250 Volts of soft currency to somebody who already holds moderation
    -- powers and who still needs a colleague to write an audited verdict.
    ok(BR.Grants.holds(lic('sdColdBoss'), SCOPE) == nil,
        'an unanswered question reads as unknown, not as "not an admin"',
        tostring(BR.Grants.holds(lic('sdColdBoss'), SCOPE)))

    fired, sent = {}, {}
    fire(BR.Net.REPORT_SUBMIT, 1, {
        targets = { { id = tokenFor(1, 'Mark'), category = 'cheating' } },
    })
    ok(#firedOf('br:ringmaster:incident') == 1,
        'a report filed while grants are unreadable opens its case')
    ok((lastResultFor(1) or {}).ok == true, 'and the reporter is told it worked')

    fired, sent = {}, {}
    fire('br:incident:filed', nil, {
        incidentId = 'inc-sd-cold', matchId = m0.id,
        subjectLicense = lic('sdColdMark'), reporterLicense = lic('sdColdBoss'),
    })
    ok((claims()[1] or {}).license == lic('sdColdBoss'),
        'and IS paid, because refusing to pay would wrong an ordinary player',
        (claims()[1] or {}).license or 'no claim')

    -- AND THE ATTEMPT DID NOT ASK AGAIN. A question is already in flight for
    -- this license, so a client hammering the submit event cannot turn itself
    -- into a DynamoDB read loop.
    ok(asksAbout(lic('sdColdBoss')) == 0,
        'a report attempt with a question already in flight asks nothing more',
        tostring(asksAbout(lic('sdColdBoss'))))

    -- ===================================================================== --
    -- (2) A FAILED READ IS NOT AN ANSWER
    -- ===================================================================== --
    --
    -- br_ddb replies to every failure -- no credentials, no network, a throttle,
    -- a timeout -- with an EMPTY scope list and an `error` field. Recording that
    -- would cache "this person is not an admin" out of an outage: the same hole
    -- as paying, except permanent and invisible, because nothing would ask
    -- again.
    fired = {}
    runTimers()
    ok(BR.Grants.holds(lic('sdColdBoss'), SCOPE) == nil,
        'giving up on a question leaves the answer unknown')
    ok(asksAbout(lic('sdColdBoss')) == 1,
        'and frees the license to be asked about again',
        tostring(asksAbout(lic('sdColdBoss'))))

    ok(reply(lic('sdColdBoss'), {}, { error = 'timed out after 3000ms' }),
        'br_ddb answers the retry')
    ok(BR.Grants.holds(lic('sdColdBoss'), SCOPE) == nil,
        'an error answer is still unknown -- an empty scope list that arrived '
        .. 'with an error is not a grant row',
        tostring(BR.Grants.holds(lic('sdColdBoss'), SCOPE)))

    -- ===================================================================== --
    -- (3) THE PANEL REPORT: A REAL CASE, NO REWARD
    -- ===================================================================== --
    local m1 = four('sdBoss', 'sdMark', 'sdPlain', 'sdExtra')
    ok(reply(lic('sdBoss'), { 'view', 'kick', SCOPE }, {}), 'the admin is answered for')
    reply(lic('sdMark'), {}, {})
    -- FIVE SCOPES AND NOT THE ONE THAT MATTERS -- the assertion that separates
    -- "keyed on the capability" from "keyed on being staff".
    ok(reply(lic('sdPlain'), MOD_SCOPES, {}), 'and so is a five-scope moderator')
    reply(lic('sdExtra'), {}, {})

    ok(BR.Grants.holds(lic('sdBoss'), SCOPE) == true,
        'the admin holds the resolving scope')
    ok(BR.Grants.holds(lic('sdPlain'), SCOPE) == false,
        'the moderator, with five other scopes, does not',
        tostring(BR.Grants.holds(lic('sdPlain'), SCOPE)))

    fired, sent = {}, {}
    fire(BR.Net.REPORT_SUBMIT, 1, {
        targets = { { id = tokenFor(1, 'Mark'), category = 'exploiting' } },
    })

    -- ------------------------------------------- the case is real in full ---
    local bossInc = firedOf('br:ringmaster:incident')[1]
    ok(bossInc ~= nil, "an admin's report opens a case like anybody else's")
    if bossInc then
        ok(bossInc.kind == 'report', 'as a report, not an anticheat case',
            tostring(bossInc.kind))
        ok(bossInc.subjectLicense == lic('sdMark'),
            'about the player they named', tostring(bossInc.subjectLicense))
        ok(bossInc.category == 'exploiting',
            'carrying the category they picked', tostring(bossInc.category))
        -- NAMED ON THE CASE. The console's "who reports everybody" signal is
        -- worth exactly as much about an admin as about anybody else, and an
        -- unattributed accusation is worth less than none.
        ok(bossInc.reporterLicense == lic('sdBoss'),
            'and naming them as the reporter', tostring(bossInc.reporterLicense))
    end

    local bossReply = lastResultFor(1)
    ok(bossReply ~= nil and bossReply.ok == true and bossReply.filed == 1,
        'and they are told a report was sent, because one was',
        bossReply and tostring(bossReply.ok) or 'no answer at all')

    -- ------------------------------------------------ and it earns nothing ---
    fired, sent = {}, {}
    fire('br:incident:filed', nil, {
        incidentId = 'inc-sd-boss', matchId = m1.id,
        subjectLicense = lic('sdMark'), reporterLicense = lic('sdBoss'),
    })
    ok(#claims() == 0,
        'the acknowledgement pays them nothing at all',
        tostring(#claims()))

    -- ------------------------------------------------------- THE CONTROL ---
    -- Extra opens a case about a DIFFERENT subject, so the path is the same
    -- one -- open, acknowledge, claim -- and the only thing that differs is
    -- who filed it. If this fails, the assertion above was passing on a
    -- fixture that never pays anybody.
    fired, sent = {}, {}
    fire(BR.Net.REPORT_SUBMIT, 4, {
        targets = { { id = tokenFor(4, 'Plain'), category = 'cheating' } },
    })
    ok(#firedOf('br:ringmaster:incident') == 1, 'an ordinary player opens a case too')

    fired, sent = {}, {}
    fire('br:incident:filed', nil, {
        incidentId = 'inc-sd-extra', matchId = m1.id,
        subjectLicense = lic('sdPlain'), reporterLicense = lic('sdExtra'),
    })
    local extraClaim = claims()[1]
    ok(extraClaim ~= nil and extraClaim.incidentId == 'inc-sd-extra'
       and extraClaim.license == lic('sdExtra'),
        'and IS owed for it -- so the silence above is the gate, not the fixture',
        extraClaim and tostring(extraClaim.license) or 'no claim')

    -- ------------------------------------ the reply gives nothing away ---
    -- Field by field, key count included. A different answer for an admin
    -- would let any player who could compare two replies work out which
    -- accounts hold moderation grants.
    local extraReply
    sent = {}
    fire(BR.Net.REPORT_SUBMIT, 4, {
        targets = { { id = tokenFor(4, 'Mark'), category = 'exploiting' } },
    })
    extraReply = lastResultFor(4)
    ok(sameShape(bossReply, extraReply),
        'the admin got exactly the answer an ordinary player gets, to the key',
        ('%s vs %s'):format(
            bossReply and tostring(bossReply.filed) or 'nil',
            extraReply and tostring(extraReply.filed) or 'nil'))

    -- ------------------------------------------- the slot really was spent ---
    -- The limits are anti-spam, not a payment meter. An admin who has named
    -- somebody is refused when they name them again, exactly as anybody is.
    fired, sent = {}, {}
    fire(BR.Net.REPORT_SUBMIT, 1, {
        targets = { { id = tokenFor(1, 'Mark'), category = 'cheating' } },
    })
    local again = lastResultFor(1)
    ok(again ~= nil and again.ok == false
       and tostring(again.refused):find('Mark', 1, true) ~= nil,
        'and their per-match slot was spent -- naming Mark twice is refused',
        again and tostring(again.refused) or 'nil')

    -- ===================================================================== --
    -- (4) THE PANEL CORROBORATION: COUNTED IN FULL, NEVER PAID
    -- ===================================================================== --
    --
    -- `inc-sd-boss` is open against Mark in this match, so Plain naming Mark
    -- corroborates rather than opening a second case.
    fired, sent = {}, {}
    fire(BR.Net.REPORT_SUBMIT, 3, {
        targets = { { id = tokenFor(3, 'Mark'), category = 'cheating' } },
    })
    local modCorr = firedOf('br:ringmaster:corroborate')[1]
    ok(modCorr ~= nil and modCorr.incidentId == 'inc-sd-boss',
        'a moderator corroborates the open case',
        modCorr and tostring(modCorr.incidentId) or 'nothing')
    ok((claims()[1] or {}).license == lic('sdPlain'),
        'and is paid for it, holding five scopes but not the resolving one',
        (claims()[1] or {}).license or 'no claim')

    -- Now the admin corroborates the same case, from the panel. Boss already
    -- named Mark above, so a fresh match is needed for the slot -- and a fresh
    -- match is also the honest shape: the case is from an earlier round.
    local m2 = four('sdCorrBoss', 'sdCorrMark', 'sdCorrPlain', 'sdCorrExtra')
    reply(lic('sdCorrBoss'), { SCOPE }, {})
    reply(lic('sdCorrMark'), {}, {})
    reply(lic('sdCorrPlain'), MOD_SCOPES, {})
    reply(lic('sdCorrExtra'), {}, {})

    fire('br:incident:filed', nil, {
        incidentId = 'inc-sd-corr', matchId = m2.id,
        subjectLicense = lic('sdCorrMark'),
    })

    fired, sent = {}, {}
    fire(BR.Net.REPORT_SUBMIT, 1, {
        targets = { { id = tokenFor(1, 'Mark'), category = 'cheating' } },
    })
    local bossCorr = firedOf('br:ringmaster:corroborate')[1]
    ok(bossCorr ~= nil and bossCorr.incidentId == 'inc-sd-corr',
        "an admin's panel report corroborates the open case in full",
        bossCorr and tostring(bossCorr.incidentId) or 'nothing')
    ok(bossCorr ~= nil and bossCorr.seq == 2 and bossCorr.count == 1,
        'moving the case counters the way any corroboration does',
        bossCorr and ('seq %s count %s'):format(tostring(bossCorr.seq),
                                                tostring(bossCorr.count)) or 'nil')
    ok(#claims() == 0, 'and earns nothing', tostring(#claims()))

    -- THE CONTROL, on the same case, one tick later.
    fired, sent = {}, {}
    fire(BR.Net.REPORT_SUBMIT, 4, {
        targets = { { id = tokenFor(4, 'Mark'), category = 'cheating' } },
    })
    local extraCorr = firedOf('br:ringmaster:corroborate')[1]
    ok(extraCorr ~= nil and extraCorr.seq == 3,
        'the next corroboration is numbered 3 -- the admin\'s was counted',
        extraCorr and tostring(extraCorr.seq) or 'nothing')
    ok((claims()[1] or {}).license == lic('sdCorrExtra'),
        'and that one IS paid',
        (claims()[1] or {}).license or 'no claim')

    -- ===================================================================== --
    -- (5) THE KILL PROMPT: OFFERED, PRESSED, COUNTED, UNPAID
    -- ===================================================================== --
    --
    -- OWNER, UNPROMPTED: "also remember admins can corroborate. they should
    -- still not be paid though." One killer, one case, two victims -- one
    -- holding the resolving scope and one not, and identical in every other
    -- respect.
    local m3 = four('sdKillBoss', 'sdKiller', 'sdKillPlain', 'sdKillExtra')
    reply(lic('sdKillBoss'), { SCOPE }, {})
    reply(lic('sdKiller'), {}, {})
    reply(lic('sdKillPlain'), MOD_SCOPES, {})
    reply(lic('sdKillExtra'), {}, {})

    fire('br:incident:filed', nil, {
        incidentId = 'inc-sd-killer', matchId = m3.id,
        subjectLicense = lic('sdKiller'),
    })

    -- ------------------------------------------------------- the admin ---
    killedBy(1, 2)
    fired, sent = {}, {}
    fire(BR.Net.REPORT_KILLED, 1)
    local bossHint = hintTo(1)
    -- OFFERED, WHICH IS THE HALF A REFUSAL WOULD HAVE BROKEN. Withholding the
    -- prompt would also have told the admin, by silence, that the player who
    -- killed them has no case open -- the enumeration leak the whole no-payload
    -- design exists to prevent.
    ok(bossHint ~= nil and bossHint.kind == 'killer' and bossHint.name == 'Mark',
        'an admin killed by somebody with an open case IS prompted',
        bossHint and tostring(bossHint.kind) or 'no hint at all')

    fired, sent = {}, {}
    fire(BR.Net.REPORT_CORROBORATE, 1)
    local bossKeyCorr = firedOf('br:ringmaster:corroborate')[1]
    ok(bossKeyCorr ~= nil and bossKeyCorr.incidentId == 'inc-sd-killer',
        'their keypress corroborates the case for real',
        bossKeyCorr and tostring(bossKeyCorr.incidentId) or 'nothing')
    ok(bossKeyCorr ~= nil and bossKeyCorr.seq == 2,
        'numbered like any other corroboration',
        bossKeyCorr and tostring(bossKeyCorr.seq) or 'nil')
    -- THE ONE DIFFERENCE, AND THE WHOLE OF IT.
    ok(#claims() == 0,
        'and it earns them nothing',
        tostring(#claims()))

    local bossKeyReply = lastResultFor(1)
    ok(bossKeyReply ~= nil and bossKeyReply.ok == true and bossKeyReply.filed == 1,
        'while the acknowledgement is the ordinary one',
        bossKeyReply and tostring(bossKeyReply.ok) or 'no answer')

    -- THE SLOT WAS SPENT. One action per offender per match applies to an admin
    -- exactly as it applies to anybody: the offer is withdrawn and the key is
    -- dead, because the limits are anti-spam rather than a payment meter.
    sent = {}
    fire(BR.Net.REPORT_KILLED, 1)
    ok(hintTo(1) == nil,
        'and they are never offered the prompt about that player again')

    fired = {}
    fire(BR.Net.REPORT_CORROBORATE, 1)
    ok(#firedOf('br:ringmaster:corroborate') == 0,
        'nor does pressing the key a second time do anything',
        tostring(#firedOf('br:ringmaster:corroborate')))

    -- AND `usage.named` WAS WRITTEN TOO, because the case belongs to this
    -- match -- so the panel refuses the same player as well. That cross-write
    -- is #177's match-boundary rule and it applies to an admin unchanged.
    fired, sent = {}, {}
    fire(BR.Net.REPORT_SUBMIT, 1, {
        targets = { { id = tokenFor(1, 'Mark'), category = 'cheating' } },
    })
    ok((lastResultFor(1) or {}).ok == false,
        'and the panel refuses the player they corroborated about',
        tostring((lastResultFor(1) or {}).refused))

    -- ------------------------------------------------------- the control ---
    killedBy(3, 2)
    fired, sent = {}, {}
    fire(BR.Net.REPORT_KILLED, 3)
    ok((hintTo(3) or {}).kind == 'killer',
        'an ordinary player killed by the same person is prompted too')

    fired, sent = {}, {}
    fire(BR.Net.REPORT_CORROBORATE, 3)
    ok(#firedOf('br:ringmaster:corroborate') == 1,
        'their key corroborates the same case')
    local paid = claims()[1]
    ok(paid ~= nil and paid.incidentId == 'inc-sd-killer'
       and paid.license == lic('sdKillPlain'),
        'and they ARE paid -- so the admin earning nothing is the gate',
        paid and ('%s / %s'):format(tostring(paid.incidentId), tostring(paid.license))
            or 'no claim')

    -- ===================================================================== --
    -- (6) AN ADMIN IS STILL A SUBJECT, AND REPORTING THEM STILL PAYS
    -- ===================================================================== --
    --
    -- Nothing on the reported side asks about grants. An admin who cheats is
    -- exactly as reportable as anybody, and the player who reports them is owed
    -- the same 250 Volts.
    local m4 = four('sdSubjBoss', 'sdSubjMark', 'sdSubjPlain', 'sdSubjExtra')
    reply(lic('sdSubjBoss'), { SCOPE }, {})
    reply(lic('sdSubjPlain'), MOD_SCOPES, {})
    reply(lic('sdSubjExtra'), {}, {})

    fired, sent = {}, {}
    fire(BR.Net.REPORT_SUBMIT, 4, {
        targets = { { id = tokenFor(4, 'Boss'), category = 'cheating' } },
    })
    local aboutBoss = firedOf('br:ringmaster:incident')[1]
    ok(aboutBoss ~= nil and aboutBoss.subjectLicense == lic('sdSubjBoss'),
        'an admin can be reported by somebody else',
        aboutBoss and tostring(aboutBoss.subjectLicense) or 'no case')

    fired, sent = {}, {}
    fire('br:incident:filed', nil, {
        incidentId = 'inc-sd-subject', matchId = m4.id,
        subjectLicense = lic('sdSubjBoss'), reporterLicense = lic('sdSubjExtra'),
    })
    ok((claims()[1] or {}).license == lic('sdSubjExtra'),
        'and their reporter is paid normally',
        (claims()[1] or {}).license or 'no claim')

    -- ===================================================================== --
    -- (7) THE LIMITS ARE UNCHANGED FOR EVERYBODY
    -- ===================================================================== --
    ok(BR.Config.Report.maxPerMatch == 3 and BR.Config.Report.maxTargets == 5,
        'the shipped limits are three submissions and five targets',
        ('%s/%s'):format(tostring(BR.Config.Report.maxPerMatch),
                         tostring(BR.Config.Report.maxTargets)))

    fired, sent = {}, {}
    local over = {}
    for i = 1, 6 do over[i] = { id = tokenFor(1, 'Mark'), category = 'cheating' } end
    fire(BR.Net.REPORT_SUBMIT, 1, { targets = over })
    local overRes = lastResultFor(1)
    ok(overRes ~= nil and overRes.ok == false
       and tostring(overRes.refused):find('at most 5', 1, true) ~= nil,
        'six targets in one submission is refused, for an admin as for anybody',
        overRes and tostring(overRes.refused) or 'nil')

    -- THREE SUBMISSIONS, THEN THE ALLOWANCE. The admin spends theirs on three
    -- different players and is refused on the fourth -- by the count, which is
    -- the rule the reward gate must not have touched.
    for _, name in ipairs({ 'Mark', 'Plain', 'Extra' }) do
        fired, sent = {}, {}
        fire(BR.Net.REPORT_SUBMIT, 1, {
            targets = { { id = tokenFor(1, name), category = 'cheating' } },
        })
        ok((lastResultFor(1) or {}).ok == true,
            ('an admin may report %s, spending one of three submissions'):format(name),
            tostring((lastResultFor(1) or {}).refused))
    end

    fired, sent = {}, {}
    fire(BR.Net.REPORT_SUBMIT, 1, {
        targets = { { id = tokenFor(1, 'Mark'), category = 'cheating' } },
    })
    local spent = lastResultFor(1)
    ok(spent ~= nil and spent.ok == false
       and tostring(spent.refused):find('all 3 reports', 1, true) ~= nil,
        'and the fourth is refused by the allowance, exactly as anybody else is',
        spent and tostring(spent.refused) or 'nil')

    -- ===================================================================== --
    -- (8) THE ANSWER IS CACHED, AND STALENESS SERVES RATHER THAN EXPIRES
    -- ===================================================================== --
    --
    -- Two failures pull in opposite directions. A read per attempt puts
    -- DynamoDB behind an unauthenticated net event; an answer that never
    -- expires is a grant change that never lands.
    local m5 = four('sdCacheBoss', 'sdCacheMark', 'sdCachePlain', 'sdCacheExtra')
    reply(lic('sdCacheBoss'), { SCOPE }, {})
    reply(lic('sdCacheMark'), {}, {})

    fired, sent = {}, {}
    for _, name in ipairs({ 'Mark', 'Plain', 'Extra' }) do
        fire(BR.Net.REPORT_SUBMIT, 1, {
            targets = { { id = tokenFor(1, name), category = 'cheating' } },
        })
        listSeenBy(1)
    end
    ok(asksAbout(lic('sdCacheBoss')) == 0,
        'three reports and three panel refreshes ask DynamoDB nothing',
        tostring(asksAbout(lic('sdCacheBoss'))))
    ok(#firedOf('br:ringmaster:incident') == 3 and #claims() == 0,
        'while filing all three cases and earning nothing for any of them',
        ('%d cases, %d claims'):format(#firedOf('br:ringmaster:incident'), #claims()))

    -- THE CLOCK MOVES PAST THE FRESHNESS WINDOW. Stale means "ask again AND go
    -- on using what we have", never "forget" -- expiring would fail back to
    -- unknown, which PAYS, handing an admin a rewarded report every five
    -- minutes on a timer.
    local m6 = four('sdStaleBoss', 'sdStaleMark', 'sdStalePlain', 'sdStaleExtra')
    reply(lic('sdStaleBoss'), { SCOPE }, {})
    fakeTime = fakeTime + (5 * 60 * 1000) + 1

    fired, sent = {}, {}
    fire(BR.Net.REPORT_SUBMIT, 1, {
        targets = { { id = tokenFor(1, 'Mark'), category = 'cheating' } },
    })
    ok(#firedOf('br:ringmaster:incident') == 1 and #claims() == 0,
        'a stale answer still withholds the reward rather than expiring into a payout',
        ('%d cases, %d claims'):format(#firedOf('br:ringmaster:incident'), #claims()))
    ok(asksAbout(lic('sdStaleBoss')) >= 1,
        'and the staleness is what triggers the next read',
        tostring(asksAbout(lic('sdStaleBoss'))))

    -- AND A REVOKED GRANT LANDS. The same license, answered with an empty scope
    -- list and NO error, is an ordinary player again -- which is the direction
    -- the freshness window exists for.
    ok(reply(lic('sdStaleBoss'), {}, {}), 'the refreshed read is answered')
    ok(BR.Grants.holds(lic('sdStaleBoss'), SCOPE) == false,
        'a revoked grant reads as revoked',
        tostring(BR.Grants.holds(lic('sdStaleBoss'), SCOPE)))

    fired, sent = {}, {}
    fire(BR.Net.REPORT_SUBMIT, 1, {
        targets = { { id = tokenFor(1, 'Plain'), category = 'cheating' } },
    })
    fire('br:incident:filed', nil, {
        incidentId = 'inc-sd-stale', matchId = m6.id,
        subjectLicense = lic('sdStalePlain'), reporterLicense = lic('sdStaleBoss'),
    })
    ok((claims()[1] or {}).license == lic('sdStaleBoss'),
        'and they are paid again',
        (claims()[1] or {}).license or 'no claim')

    -- ===================================================================== --
    -- (9) THE CACHE IS BOUNDED BY WHO IS CONNECTED
    -- ===================================================================== --
    --
    -- Nothing asks about a license that is not connected -- a reporter has to be
    -- in a match -- so a departed player's row is dead weight for the rest of
    -- the server's uptime. This free is the only thing stopping the table
    -- growing with everybody who has ever joined, and deleting it changes
    -- nothing any other assertion could see.
    local before = BR.Grants.stats().known
    leave(1)
    local after = BR.Grants.stats().known
    ok(after == before - 1,
        'a player who disconnects takes their cached grant with them',
        ('%d -> %d'):format(before, after))

    fired = {}
    licenseOf[1] = 'sdStaleBoss'
    join(1, 'Boss')
    ok(asksAbout(lic('sdStaleBoss')) == 1,
        'and is asked about afresh on the way back in',
        tostring(asksAbout(lic('sdStaleBoss'))))

    SetTimeout = function() end
    ok(m5 ~= nil, 'the fixtures built their matches')
end

realPrint(('\n\27[32m%d passed\27[0m'):format(pass))
if fail > 0 then
    realPrint(('\27[31m%d failed\27[0m'):format(fail))
    os.exit(1)
end
