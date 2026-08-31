-- Unit tests for the 23 station ambulances (#219 step 3).
--
-- ═══ WHY THIS IS ITS OWN SUITE ═══
--
-- Four of the owner's rules are effectively unobservable in a playtest and
-- expensive to get wrong, and they are the four this file exists for.
--
--   THE BUCKET. A vehicle created in bucket 0 instead of the match's is
--   INDISTINGUISHABLE IN GAME from one that was never created: nobody in the
--   match can see it, and server/vehicles.lua says so itself -- "a vehicle left
--   there is one nobody in the match can see, which is the same failure as not
--   creating it at all". The owner has reported "our ambulances aren't spawning
--   still" three times; two different bugs print that same nothing.
--
--   THE TEARDOWN. Twenty-three vehicles that survive a match are visible only to
--   whoever is still in the dead match's routing bucket -- which is nobody --
--   so the leak is silent until the server has been up long enough for it to
--   matter. citizenfx/fivem#2256 says the delete can fail while reporting
--   success, so the interesting case is a DeleteEntity that refuses, and the
--   only way to stage one is here.
--
--   THE BLIP AUDIENCE. "Whenever a squadmate is down or out, the blips for all
--   the ambulances should be shown to the whole squad." Getting that wrong by
--   one squad means running a two-squad playtest and asking somebody on the
--   other team what their map looks like.
--
--   THE COLLISION WITH THE RESCUE. server/rescue.lua spawns its ride at the
--   surveyed point, and a station ambulance is parked on it. The wrong answer
--   produces two ambulances interpenetrating BEHIND A FADE, on a rescue the
--   player cannot influence, and the engine resolves it by throwing one of them
--   somewhere -- which reads as a physics glitch rather than as a spawn bug.

local fakeTime = 0
function GetGameTimer() return fakeTime end

local RES = 'resources/[fivem-royale]/'
local ROOT = RES .. 'br_lib/'
local function loadAt(root, f)
    local chunk, err = loadfile(root .. f)
    if not chunk then
        print('\27[31mload error\27[0m ' .. f .. ': ' .. tostring(err))
        os.exit(1)
    end
    chunk()
end
local function load(f) loadAt(ROOT, f) end
local function loadCore(f) loadAt(RES, f) end

for _, f in ipairs({
    'shared/enums.lua',
    'shared/geo.lua',        -- BR.Dist, which the blip and the displacement use
    'shared/protocol.lua',   -- BR.Net.RESCUE_BLIP
    'config/match.lua',      -- matchBucketBase
    'config/overrides.lua',
    'config/storm.lua',
    'config/map.lua',        -- BR.Config.Map.AmbulanceSpawns: the 23 rows
    'config/loot.lua',
    'config/fuel.lua',
    'config/rescue.lua',     -- the model, the blip fields and Points()
    'config/ambulances.lua',
}) do load(f) end

local pass, fail = 0, 0
local group = ''
local function describe(n) group = n end
local function ok(cond, name, detail)
    if cond then pass = pass + 1 else
        fail = fail + 1
        print('\27[31mFAIL\27[0m ' .. group .. ' > ' .. name ..
            (detail and ('\n       ' .. tostring(detail)) or ''))
    end
end

local A = BR.Config.Ambulances

-- ---------------------------------------------------------------------------
describe('the points are the owner\'s, and there is one copy of them')
do
    -- THE WHOLE POINT OF THE READER. Twenty-three surveyed coordinates copied
    -- into a second table would drift the first time he re-walks one, and the
    -- symptom would be a rescue spawning on top of a station ambulance that the
    -- other file thinks is somewhere else -- which is the exact bug the
    -- displacement below exists to prevent.
    local mine = A.Points()
    ok(mine == BR.Config.Rescue.Points(),
        'BR.Config.Ambulances.Points() IS the rescue\'s table -- the same table, '
            .. 'not a copy of its rows')
    ok(mine == BR.Config.Map.AmbulanceSpawns,
        '...which is BR.Config.Map.AmbulanceSpawns, where the owner authored '
            .. 'them with /brcoords')
    ok(#mine == 23, 'all 23 of them', #mine)

    -- The rows carry real ped-standing z values and a heading, and the
    -- displacement below is computed FROM the heading -- a row without one would
    -- silently displace due north.
    local complete = 0
    for _, p in ipairs(mine) do
        if type(p.x) == 'number' and type(p.y) == 'number'
           and type(p.z) == 'number' and type(p.heading) == 'number' then
            complete = complete + 1
        end
    end
    ok(complete == 23, 'every row carries x, y, z AND a heading', complete)

    ok(A.Model() == BR.Config.Rescue.model,
        'and the model is the rescue\'s model -- one list decides what an '
            .. 'ambulance is, so ambheal and the revive key agree with this file',
        A.Model())
end

-- ---------------------------------------------------------------------------
-- THE HARNESS
-- ---------------------------------------------------------------------------
--
-- Everything below drives the real br_core/server/ambulances.lua through the one
-- scheduler job it registers. The natives are stubs that keep a WORLD -- a table
-- of live entity handles with coordinates -- so "did it actually delete them" is
-- a question this file can answer rather than assume.

local sched, sent, world, nextVeh, matches, roster, spawnCalls
local refuseDelete = 0    -- how many DeleteEntity calls to swallow, per handle
local refuseSpawn = false

world, nextVeh = {}, 100
matches, roster, sent, spawnCalls = {}, {}, {}, {}

_G.DoesEntityExist = function(v) return world[v] ~= nil and 1 or 0 end
_G.GetEntityCoords = function(v)
    local e = world[v]
    if not e then return nil end
    return { x = e.x, y = e.y, z = e.z }
end
_G.DeleteEntity = function(v)
    local e = world[v]
    if not e then return end
    if (e.refusals or 0) > 0 then e.refusals = e.refusals - 1 return end
    world[v] = nil
end
_G.TriggerClientEvent = function(evt, src, d)
    sent[#sent + 1] = { evt = evt, src = src, d = d }
end
_G.RegisterCommand = function() end
_G.AddEventHandler = function(name, fn)
    _G.__handlers = _G.__handlers or {}
    _G.__handlers[name] = fn
end

BR.Sched = { every = function(_, name, fn) sched = fn end }

BR.Vehicles = {
    spawnOwned = function(model, vtype, x, y, z, heading, forSrc, bucket)
        spawnCalls[#spawnCalls + 1] = {
            model = model, vtype = vtype, x = x, y = y, z = z,
            heading = heading, forSrc = forSrc, bucket = bucket,
        }
        if refuseSpawn then return nil, nil, 'refused by the test' end
        nextVeh = nextVeh + 1
        world[nextVeh] = { x = x, y = y, z = z, refusals = refuseDelete }
        return nextVeh, nextVeh + 9000, nil
    end,
}

BR.Server = {
    matches = matches,
    eachMatch = function(fn)
        local ids = {}
        for id in pairs(matches) do ids[#ids + 1] = id end
        table.sort(ids)
        for _, id in ipairs(ids) do if matches[id] then fn(matches[id]) end end
    end,
    isInMatch = function(state)
        return state == BR.PlayerState.ALIVE
            or state == BR.PlayerState.DBNO
            or state == BR.PlayerState.WARMUP
            or state == BR.PlayerState.BUS
            or state == BR.PlayerState.FREEFALL
            or state == BR.PlayerState.GLIDE
    end,
}

BR.Roster = {
    each = function(filter, fn)
        local srcs = {}
        for src in pairs(roster) do srcs[#srcs + 1] = src end
        table.sort(srcs)
        for _, src in ipairs(srcs) do
            local e = roster[src]
            if e and (not filter or filter(e)) then fn(src, e) end
        end
    end,
}

loadCore('br_core/server/ambulances.lua')

--- Run the pass n times.
local function tick(n)
    for _ = 1, (n or 1) do
        fakeTime = fakeTime + (A.tickMs or 1000)
        sched()
    end
end

--- A match whose bus doors opened one second ago.
local function busMatch(id)
    matches[id] = {
        id = id, state = BR.MatchState.BUS,
        route = { timed = true, jumpFrom = fakeTime - 1000 },
    }
    return matches[id]
end

local function blipsIn(list)
    local n = 0
    for _, s in ipairs(list) do
        if s.evt == BR.Net.RESCUE_BLIP then n = n + 1 end
    end
    return n
end

local function liveVehicles()
    local n = 0
    for _ in pairs(world) do n = n + 1 end
    return n
end

-- ---------------------------------------------------------------------------
describe('they are built when the bus doors open, and not before')
do
    world, spawnCalls, sent = {}, {}, {}
    local m = busMatch(1)
    m.route.jumpFrom = fakeTime + 60000    -- doors are still shut

    tick(3)
    ok(#spawnCalls == 0,
        'nothing is created while the doors are shut -- the trigger is '
            .. 'route.jumpFrom, which is the clock the player is watching',
        #spawnCalls)

    -- ...AND THE CONTROL. Without this the assertion above would pass just as
    -- happily against a file that never spawns anything at all.
    m.route.jumpFrom = fakeTime - 1
    tick(1)
    ok(#spawnCalls > 0, 'and they start the moment the doors open', #spawnCalls)

    -- STAGED, not all in one frame: 23 points at perTick 6 is four passes.
    ok(#spawnCalls == A.perTick,
        'the first pass builds exactly perTick of them, not 23 -- twenty-three '
            .. 'CreateVehicleServerSetter calls inside one scheduler job is the '
            .. 'spike this staging exists to avoid',
        #spawnCalls)

    tick(3)
    ok(#spawnCalls == 23, 'and four passes have built all 23', #spawnCalls)
    ok(BR.Ambulances.count(1) == 23, 'all of which are standing',
        BR.Ambulances.count(1))

    tick(5)
    ok(#spawnCalls == 23,
        'and it STOPS -- a pass that has built everything builds nothing more, '
            .. 'so a long match does not accumulate ambulances',
        #spawnCalls)
end

-- ---------------------------------------------------------------------------
describe('they are built where the owner walked, in the match\'s own bucket')
do
    local points = A.Points()
    local byId = {}
    for _, c in ipairs(spawnCalls) do byId[c.x .. '/' .. c.y] = c end

    local placed, wrongBucket, wrongModel = 0, 0, 0
    for _, p in ipairs(points) do
        local c = byId[p.x .. '/' .. p.y]
        if c then
            placed = placed + 1
            if c.z ~= p.z or c.heading ~= p.heading then placed = placed - 1 end
            if c.bucket ~= BR.Config.Match.matchBucketBase + 1 then
                wrongBucket = wrongBucket + 1
            end
            if c.model ~= BR.Config.Rescue.model then
                wrongModel = wrongModel + 1
            end
        end
    end

    ok(placed == 23,
        'every one of the 23 is created at its surveyed x, y, z AND heading -- '
            .. 'nothing is re-sited, nudged or rounded',
        placed)

    -- ═══ THE ASSERTION THE OWNER'S "they aren't spawning" ROUNDS NEEDED ═══
    ok(wrongBucket == 0,
        'and every one of them is in the MATCH\'s routing bucket -- bucket 0 is '
            .. 'invisible to everybody in the match, which looks exactly like '
            .. 'not having been created',
        wrongBucket)
    ok(spawnCalls[1].bucket == BR.Config.Match.matchBucketBase + 1,
        '...named outright rather than read off a player: at doors-open the '
            .. 'riders are still in the COMMUNAL WARMUP bucket',
        tostring(spawnCalls[1].bucket))
    ok(spawnCalls[1].forSrc == nil,
        '...which is why no player id is passed at all',
        tostring(spawnCalls[1].forSrc))

    ok(wrongModel == 0, 'and every one is BR.Config.Rescue.model', wrongModel)
    ok(spawnCalls[1].vtype == 'automobile',
        'as an automobile -- CreateVehicleServerSetter THROWS on a type it does '
            .. 'not know',
        tostring(spawnCalls[1].vtype))
end

-- ---------------------------------------------------------------------------
describe('the blips: all of them, to the whole squad, while one is down or out')
do
    -- Two squads and a solo, all in match 1, which already has its 23 up.
    roster = {
        [1] = { matchId = 1, squadId = 'A', state = BR.PlayerState.ALIVE },
        [2] = { matchId = 1, squadId = 'A', state = BR.PlayerState.ALIVE },
        [3] = { matchId = 1, squadId = 'B', state = BR.PlayerState.ALIVE },
        [4] = { matchId = 1, state = BR.PlayerState.ALIVE },
        -- ANOTHER MATCH ENTIRELY, and its player has a mate down. Without this
        -- row a file that ignored matchId would pass everything below.
        [5] = { matchId = 2, squadId = 'A', state = BR.PlayerState.DBNO },
    }
    matches[1].state = BR.MatchState.PLAYING

    sent = {}
    tick(1)
    ok(blipsIn(sent) == 0,
        'a squad with nobody down sees nothing -- the blips are not simply on',
        blipsIn(sent))

    -- SQUAD A LOSES ONE.
    roster[2].state = BR.PlayerState.DBNO
    sent = {}
    tick(1)

    local per = {}
    for _, s in ipairs(sent) do
        if s.evt == BR.Net.RESCUE_BLIP then per[s.src] = (per[s.src] or 0) + 1 end
    end
    ok((per[1] or 0) == 23,
        'the DOWNED player\'s squadmate gets all 23 -- "the blips for ALL the '
            .. 'ambulances", because the squad is choosing where to drive',
        per[1])
    ok((per[2] or 0) == 23,
        'and so does the downed player themselves -- "shown to the whole squad" '
            .. 'has no exception in it',
        per[2])
    ok((per[3] or 0) == 0,
        'the OTHER squad in the same match gets nothing -- this is not a '
            .. 'match-wide broadcast',
        per[3])
    ok((per[4] or 0) == 0, 'and neither does the solo player', per[4])
    ok((per[5] or 0) == 0,
        'and a player in a DIFFERENT MATCH whose own mate is down gets none of '
            .. 'THIS match\'s ambulances',
        per[5])

    -- Every payload is a real coordinate for a real station.
    local coords = 0
    for _, s in ipairs(sent) do
        if s.evt == BR.Net.RESCUE_BLIP and s.src == 1
           and type(s.d.x) == 'number' and type(s.d.y) == 'number'
           and type(s.d.key) == 'string' and s.d.key:sub(1, 2) == 's:' then
            coords = coords + 1
        end
    end
    ok(coords == 23,
        'each carries coordinates and an `s:` key -- the category '
            .. 'client/rescue.lua\'s RESCUE_BLIP handler was left open for, so '
            .. 'no client file changes to draw these',
        coords)

    -- ═══ AND THEY ARE NOT RE-SENT EVERY SECOND ═══
    sent = {}
    tick(3)
    ok(blipsIn(sent) == 0,
        'a parked ambulance sends nothing on later passes -- 23 coordinates per '
            .. 'squad per second, for vehicles that are not moving, would be the '
            .. 'whole of this feature\'s network cost',
        blipsIn(sent))

    -- ═══ ...BUT ONE SOMEBODY DRIVES AWAY TAKES ITS BLIP WITH IT ═══
    local moved = nil
    for v, e in pairs(world) do moved = moved or v; if v < moved then moved = v end end
    world[moved].x = world[moved].x + 250.0
    sent = {}
    tick(1)
    local movedSent = 0
    for _, s in ipairs(sent) do
        if s.evt == BR.Net.RESCUE_BLIP and s.src == 1 and not s.d.gone then
            movedSent = movedSent + 1
        end
    end
    ok(movedSent == 1,
        'exactly the one that moved is re-sent -- the owner\'s "if someone takes '
            .. 'it, we need to update it\'s location on the map"',
        movedSent)

    -- ═══ AND OUT COUNTS, WHICH BR.Server.isInMatch DOES NOT ═══
    roster[2].state = BR.PlayerState.ALIVE
    sent = {}
    tick(1)
    local gone = 0
    for _, s in ipairs(sent) do
        if s.evt == BR.Net.RESCUE_BLIP and s.src == 1 and s.d.gone then
            gone = gone + 1
        end
    end
    ok(gone == 23,
        'a squad that gets its mate back loses the blips again -- all 23 '
            .. 'withdrawn, not left on the map',
        gone)

    roster[2].state = BR.PlayerState.OUT
    sent = {}
    tick(1)
    local back = 0
    for _, s in ipairs(sent) do
        if s.evt == BR.Net.RESCUE_BLIP and s.src == 1 and not s.d.gone then
            back = back + 1
        end
    end
    ok(back == 23,
        'and an ELIMINATED mate brings them back -- "down or out", and OUT is '
            .. 'the state a revive key exists for',
        back)
end

-- ---------------------------------------------------------------------------
describe('a station ambulance that stops existing is forgotten, not respawned')
do
    local victim = nil
    for v in pairs(world) do if not victim or v < victim then victim = v end end
    world[victim] = nil          -- somebody blew it up (or fivem#2623 took it)

    sent = {}
    local before = BR.Ambulances.count(1)
    tick(1)
    ok(BR.Ambulances.count(1) == before - 1,
        'the record goes -- a blip pointing at a wreck is worse than no blip',
        BR.Ambulances.count(1))

    local withdrawn = 0
    for _, s in ipairs(sent) do
        if s.evt == BR.Net.RESCUE_BLIP and s.d.gone then withdrawn = withdrawn + 1 end
    end
    ok(withdrawn > 0, 'and its blip is withdrawn from everyone watching', withdrawn)

    local n = #spawnCalls
    tick(3)
    ok(#spawnCalls == n,
        'and NOTHING is built to replace it -- a station that refilled itself '
            .. 'would hand a squad an unlimited supply of the one vehicle this '
            .. 'feature is built around',
        #spawnCalls - n)
end

-- ---------------------------------------------------------------------------
describe('teardown: nothing survives its match')
do
    local standing = BR.Ambulances.count(1)
    ok(standing > 0 and liveVehicles() == standing,
        'fixture: the world holds exactly the match\'s station ambulances',
        ('%d standing, %d in world'):format(standing, liveVehicles()))

    sent = {}
    matches[1].state = BR.MatchState.ENDED
    tick(6)

    ok(liveVehicles() == 0,
        'every one of them is deleted once the match stops being played -- the '
            .. 'same rule and cadence as server/rescue.lua\'s abandoned sweep',
        liveVehicles())
    ok(BR.Ambulances.count(1) == 0, 'and the record is empty',
        BR.Ambulances.count(1))
    ok(BR.Ambulances.stats(1) == nil,
        'and then dropped entirely, so nothing walks it again')

    local withdrawn = 0
    for _, s in ipairs(sent) do
        if s.evt == BR.Net.RESCUE_BLIP and s.d.gone then withdrawn = withdrawn + 1 end
    end
    ok(withdrawn > 0,
        'the blips come off BEFORE the deletes -- a red ambulance icon stranded '
            .. 'on a lobby map is exactly the leftover nobody can explain later',
        withdrawn)
end

-- ---------------------------------------------------------------------------
describe('teardown survives citizenfx/fivem#2256, and says so when it does not')
do
    -- ═══ A DELETE THAT REFUSES TWICE, WHICH IS THE REPORTED BUG ═══
    matches, roster, world, spawnCalls, sent = {}, {}, {}, {}, {}
    BR.Server.matches = matches
    refuseDelete = 2
    busMatch(7)
    tick(4)
    ok(BR.Ambulances.count(7) == 23, 'fixture: 23 up in match 7',
        BR.Ambulances.count(7))

    matches[7].state = BR.MatchState.ENDED
    tick(1)
    ok(liveVehicles() == 23,
        'fixture: the first delete pass is swallowed entirely, which is what '
            .. 'the issue reports',
        liveVehicles())

    tick(15)
    ok(liveVehicles() == 0,
        'the pass RE-ISSUES and they go -- a single DeleteEntity call is not a '
            .. 'confirmation, and DoesEntityExist on the next pass is the only '
            .. 'evidence there is',
        liveVehicles())
    ok(BR.Ambulances.stats(7) == nil, 'and the record is released')

    -- ═══ A DELETE THAT NEVER WORKS: IT GIVES UP, LOUDLY, AND STOPS ═══
    --
    -- The unbounded version of the retry is an infinite loop over 23 handles
    -- for the server's uptime, which is a worse bug than the one it is chasing.
    matches, world, spawnCalls = {}, {}, {}
    BR.Server.matches = matches
    refuseDelete = 999
    busMatch(8)
    tick(4)
    ok(BR.Ambulances.count(8) == 23, 'fixture: 23 up in match 8',
        BR.Ambulances.count(8))

    matches[8].state = BR.MatchState.ENDED
    tick(40)
    ok(liveVehicles() == 23,
        'fixture: nothing this engine does will delete them',
        liveVehicles())
    ok(BR.Ambulances.stats(8) == nil,
        'the teardown gives up after deleteAttempts rather than re-deleting 23 '
            .. 'handles for ever')

    -- AND THE CONTAINMENT, WHICH IS WHAT MAKES GIVING UP SAFE.
    ok(BR.Config.Match.matchBucketBase + 8 ~= BR.Config.Match.matchBucketBase + 9,
        'a ghost is confined to its own match\'s bucket, and BR.Match.create '
            .. 'takes matchId + 1 without ever reusing one -- so no later match '
            .. 'is ever placed in a bucket a ghost is standing in')
    refuseDelete = 0
end

-- ---------------------------------------------------------------------------
describe('a match that dissolves in the air still tears down')
do
    matches, world, spawnCalls = {}, {}, {}
    BR.Server.matches = matches
    busMatch(9)
    tick(4)
    ok(liveVehicles() == 23, 'fixture: 23 up during the flight', liveVehicles())

    -- EVERYBODY LEFT AFTER THE DOORS OPENED. BR.Match.destroy clears
    -- BR.Server.matches[id] and THEN raises this -- so a teardown driven off
    -- eachMatch alone would stop at the exact moment there was work to do.
    matches[9] = nil
    local destroyed = _G.__handlers['br:match:destroyed']
    ok(type(destroyed) == 'function',
        'the file listens to br:match:destroyed at all',
        type(destroyed))
    if destroyed then destroyed({ matchId = 9 }) end
    tick(6)
    ok(liveVehicles() == 0,
        'br:match:destroyed tears down a match that never reached CLEANUP -- '
            .. 'the only reliable end-of-match signal, and the one path a '
            .. 'dissolved flight takes',
        liveVehicles())
end

-- ---------------------------------------------------------------------------
describe('nothing leaks from one match into the next')
do
    matches, world, spawnCalls = {}, {}, {}
    BR.Server.matches = matches
    busMatch(10)
    tick(4)
    matches[10].state = BR.MatchState.ENDED
    tick(6)
    ok(liveVehicles() == 0 and BR.Ambulances.stats(10) == nil,
        'fixture: match 10 is fully torn down', liveVehicles())

    spawnCalls = {}
    busMatch(11)
    tick(4)
    ok(BR.Ambulances.count(11) == 23,
        'the next match gets its own full set', BR.Ambulances.count(11))
    ok(BR.Ambulances.count(10) == 0, 'and the old one has none')
    ok(spawnCalls[1].bucket == BR.Config.Match.matchBucketBase + 11,
        'in its own bucket, which the previous match never used',
        tostring(spawnCalls[1].bucket))
end

-- ---------------------------------------------------------------------------
describe('the rescue does not spawn inside a parked station ambulance')
do
    -- Match 11 has all 23 standing, on the surveyed points.
    local p = A.Points()[1]

    local x, y, z, moved = BR.Ambulances.displace(11, p.x, p.y, p.z, p.heading)
    ok(moved == true,
        'a rescue spawning on a surveyed point IS displaced -- without this, '
            .. 'every rescue creates its ride inside the parked one and the '
            .. 'engine resolves it by throwing one of them')

    local d = math.sqrt((x - p.x) ^ 2 + (y - p.y) ^ 2)
    ok(math.abs(d - A.standAsideM) < 0.001,
        'by exactly standAsideM', d)
    ok(d > A.occupiedM,
        '...which is further than occupiedM, so the displaced spot is not '
            .. 'itself judged blocked',
        ('%.1f vs %.1f'):format(d, A.occupiedM))
    ok(z == p.z, 'at the surveyed z -- eight metres along a car park is the '
            .. 'same ground, and the point was walked rather than guessed')

    -- ═══ BEHIND, NOT IN FRONT, AND NOT BESIDE ═══
    --
    -- A GTA heading of 0 faces +Y. Forward is (-sin h, cos h), so a point BEHIND
    -- the parked vehicle has a strictly negative projection onto it.
    local rad = math.rad(p.heading)
    local fx, fy = -math.sin(rad), math.cos(rad)
    local proj = (x - p.x) * fx + (y - p.y) * fy
    ok(proj < -(A.standAsideM - 0.001),
        'directly BEHIND the parked one along its surveyed heading -- the ground '
            .. 'it drove in over, rather than the kerb beside it',
        proj)

    -- ═══ AND IT LEAVES AN UNOCCUPIED POINT ALONE ═══
    local fx2, fy2, fz2, moved2 = BR.Ambulances.displace(11, 0.0, 0.0, 0.0, 0.0)
    ok(moved2 == false and fx2 == 0.0 and fy2 == 0.0 and fz2 == 0.0,
        'somewhere with no station ambulance on it is not moved at all -- the '
            .. 'free-spawn path (owner, 2026-08-29) is untouched')

    local nx, ny, _, moved3 = BR.Ambulances.displace(nil, p.x, p.y, p.z, p.heading)
    ok(moved3 == false and nx == p.x and ny == p.y,
        'and a match with no station ambulances at all displaces nothing, so a '
            .. 'build without this feature spawns exactly where it always did')
end

-- ---------------------------------------------------------------------------
describe('...and server/rescue.lua actually uses the displaced coordinates')
do
    -- A SOURCE ASSERTION, DELIBERATELY. The behaviour proven above is worth
    -- nothing if the one call site goes back to spelling the surveyed point --
    -- and that regression is a two-character diff in a 1400-line file.
    local fh = io.open(RES .. 'br_core/server/rescue.lua', 'r')
    local src = fh:read('a')
    fh:close()

    ok(src:find('BR.Ambulances', 1, true) ~= nil,
        'server/rescue.lua asks BR.Ambulances where to spawn')
    ok(src:find('BR.Ambulances and BR.Ambulances.displace', 1, true) ~= nil,
        '...nil-guarded, so a build without this feature still runs')

    local call = src:match('BR%.Vehicles%.spawnOwned%b()')
    ok(call ~= nil, 'fixture: the spawn call is findable')
    ok(call and call:find('sx, sy, sz', 1, true) ~= nil,
        'and the coordinates it passes are the DISPLACED ones', call)
    ok(call and call:find('pickup%.x') == nil,
        '...not the surveyed point, which is where the station ambulance is '
            .. 'standing',
        call)
end

-- ---------------------------------------------------------------------------
describe('the feature switches off in one line')
do
    matches, world, spawnCalls, sent = {}, {}, {}, {}
    BR.Server.matches = matches
    A.enabled = false
    busMatch(12)
    tick(4)
    ok(#spawnCalls == 0, 'nothing is created', #spawnCalls)
    ok(blipsIn(sent) == 0, 'and nothing is blipped', blipsIn(sent))

    local dx, dy, _, dm = BR.Ambulances.displace(12, 1.0, 2.0, 3.0, 0.0)
    ok(dm == false and dx == 1.0 and dy == 2.0,
        'and the rescue displaces nothing, because there is nothing parked')
    A.enabled = true
end

-- ---------------------------------------------------------------------------
describe('a match that skipped the flight still gets them')
do
    -- server/match.lua goes live "when the LAST player is down -- not when the
    -- route timer says so", and `brforce playing` skips the bus outright. A
    -- trigger that only ever fired on `state == BUS` would produce a round with
    -- no ambulances in it -- which is the symptom the owner has now reported
    -- three times, wearing a different cause each time.
    matches, world, spawnCalls = {}, {}, {}
    BR.Server.matches = matches
    matches[13] = { id = 13, state = BR.MatchState.PLAYING }   -- no route at all
    tick(4)
    ok(BR.Ambulances.count(13) == 23,
        'a PLAYING match with no route record at all still gets all 23 -- '
            .. 'PLAYING is a state a match can only reach through an open door',
        BR.Ambulances.count(13))

    local n = #spawnCalls
    tick(5)
    ok(#spawnCalls == n,
        'and only ONE set, however many passes run over it',
        #spawnCalls - n)

    matches[13].state = BR.MatchState.ENDED
    tick(6)
    ok(liveVehicles() == 0, 'and it tears down like any other', liveVehicles())
end

-- ---------------------------------------------------------------------------
print(('\n%d passed, %d failed'):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
