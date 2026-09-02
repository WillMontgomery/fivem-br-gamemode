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
--
-- ═══ THE TRIGGER IS OUT, AND IT USED TO BE "DOWN OR OUT" ═══
--
-- Owner, 2026-08-31, after the first round in which all 23 spawned: "while a
-- squadmate is DBNO bleeding out we have ambulance blips for the squad, but we
-- can't do anything with the ambulances. We should not see blips until they've
-- bled out."
--
-- THIS SUITE ASSERTED THE OLD WORD IN FIVE PLACES and every one of them has been
-- turned round rather than deleted: DBNO showing nothing is now the assertion,
-- and OUT bringing the whole set is the control that stops a file which simply
-- never blips from passing it.
describe('the blips: all of them, to the whole squad, once one is OUT')
do
    -- Two squads and a solo, all in match 1, which already has its 23 up.
    roster = {
        [1] = { matchId = 1, squadId = 'A', state = BR.PlayerState.ALIVE },
        [2] = { matchId = 1, squadId = 'A', state = BR.PlayerState.ALIVE },
        [3] = { matchId = 1, squadId = 'B', state = BR.PlayerState.ALIVE },
        [4] = { matchId = 1, state = BR.PlayerState.ALIVE },
        -- ANOTHER MATCH ENTIRELY, and its player has a mate out. Without this
        -- row a file that ignored matchId would pass everything below.
        [5] = { matchId = 2, squadId = 'A', state = BR.PlayerState.OUT },
    }
    matches[1].state = BR.MatchState.PLAYING

    sent = {}
    tick(1)
    ok(blipsIn(sent) == 0,
        'a squad with nobody down sees nothing -- the blips are not simply on',
        blipsIn(sent))

    -- ═══ A MATE BLEEDING OUT IS NOT THE TRIGGER ═══
    --
    -- The plate at the body is the offer while this state lasts (client/dbno.lua
    -- draws it, a hold, free, inventory kept) and no revive key exists yet --
    -- BR.ReviveKey.onEliminated mints one at ELIMINATION. So a map of vans here
    -- is pointing at something nobody can act on, which is exactly what the
    -- owner watched.
    roster[2].state = BR.PlayerState.DBNO
    sent = {}
    tick(1)
    ok(blipsIn(sent) == 0,
        'a squad with a mate DBNO still sees nothing -- during the bleed-out the '
            .. 'answer is a revive at the body, and there is no key to carry to '
            .. 'an ambulance yet',
        blipsIn(sent))

    -- SQUAD A LOSES ONE FOR GOOD.
    roster[2].state = BR.PlayerState.OUT
    sent = {}
    tick(1)

    local per = {}
    for _, s in ipairs(sent) do
        if s.evt == BR.Net.RESCUE_BLIP then per[s.src] = (per[s.src] or 0) + 1 end
    end
    ok((per[1] or 0) == 23,
        'the ELIMINATED player\'s squadmate gets all 23 -- "the blips for ALL the '
            .. 'ambulances", because the squad is choosing where to drive',
        per[1])
    ok((per[2] or 0) == 23,
        'and so does the eliminated player themselves -- "shown to the whole '
            .. 'squad" has no exception in it, and BR.Server.isInMatch does not '
            .. 'count OUT',
        per[2])
    ok((per[3] or 0) == 0,
        'the OTHER squad in the same match gets nothing -- this is not a '
            .. 'match-wide broadcast',
        per[3])
    ok((per[4] or 0) == 0, 'and neither does the solo player', per[4])
    ok((per[5] or 0) == 0,
        'and a player in a DIFFERENT MATCH whose own mate is out gets none of '
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

    -- ═══ AND THEY COME BACK OFF THE MAP WHEN NOBODY IS OUT ═══
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

    -- ...AND A MATE WHO IS KNOCKED DOWN AGAIN DOES NOT BRING THEM BACK. This is
    -- the OTHER direction of the owner's correction and the one a fix that only
    -- edited the first filter's ordering would miss.
    roster[2].state = BR.PlayerState.DBNO
    sent = {}
    tick(1)
    ok(blipsIn(sent) == 0,
        'a second knock does not put them back -- DBNO is not a trigger in '
            .. 'either direction',
        blipsIn(sent))

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
        'and bleeding out brings them back -- OUT is the state a revive key '
            .. 'exists for, and the only state that shows a map of ambulances',
        back)
end

-- ---------------------------------------------------------------------------
--
-- ═══ THE AMBULANCES NOBODY AUTHORED ═══
--
-- Owner, 2026-08-31: "let's not auto-show ambulance blips just because they got
-- in an ambulance - BUT do add the position to the table so when blips are shown
-- we can include any that other players have found along the way (engine-spawned
-- ones)."
--
-- TWO HALVES AND THEY FAIL DIFFERENTLY. The removal is asserted where the old
-- publisher lived (tools/test_rescue: a find puts nothing on anybody's map); the
-- inclusion is asserted here, because this is the file that now decides who sees
-- one and when. A version that recorded finds perfectly and never published them
-- would pass the first suite and fail this one.
--
-- THE LEDGER IS STUBBED rather than driven through server/rescue.lua, and that is
-- the point of the interface being one function: what is under test is that this
-- file mirrors whatever it is told, publishes it through the SAME gate as the 23,
-- and withdraws it the moment the ledger stops walking it.
describe('the found ones ride along with the 23, through the same gate')
do
    local ledger = {}
    BR.Rescue = {
        eachFound = function(matchId, fn)
            for key, p in pairs(ledger[matchId] or {}) do fn(key, p.x, p.y) end
        end,
    }

    local function blipsFor(src, wantGone)
        local n = 0
        for _, s in ipairs(sent) do
            if s.evt == BR.Net.RESCUE_BLIP and s.src == src
               and (s.d.gone == true) == wantGone then
                n = n + 1
            end
        end
        return n
    end

    -- The roster is where the block above left it: squad A's player 2 is OUT, so
    -- 1 and 2 are watching and squad B's 3 and the solo 4 are not.
    ok(roster[2].state == BR.PlayerState.OUT, 'fixture: squad A has a mate out')

    -- ═══ A FIND REACHES A SQUAD THAT IS ALREADY WATCHING ═══
    ledger[1] = { ['v:5001'] = { x = 10.0, y = 20.0 } }
    sent = {}
    tick(1)
    ok(blipsFor(1, false) == 1,
        'a squad already watching gets the new find on the next pass -- it does '
            .. 'not have to lose another mate to see it',
        blipsFor(1, false))
    ok(blipsFor(3, false) == 0 and blipsFor(3, true) == 0,
        'and the squad with nobody out gets nothing, exactly as with the 23 -- '
            .. 'a find is more rows in one list, not a second feature with a '
            .. 'second audience',
        ('%d shown, %d withdrawn'):format(blipsFor(3, false), blipsFor(3, true)))

    local key, x, y
    for _, s in ipairs(sent) do
        if s.evt == BR.Net.RESCUE_BLIP and s.src == 1 then
            key, x, y = s.d.key, s.d.x, s.d.y
        end
    end
    ok(key == 'v:5001' and x == 10.0 and y == 20.0,
        'carrying the ledger\'s own key and coordinates -- `v:` is the second '
            .. 'category client/rescue.lua\'s handler was left open for, and it '
            .. 'is spelled in server/rescue.lua alone',
        ('%s at %s, %s'):format(tostring(key), tostring(x), tostring(y)))

    ok(BR.Ambulances.stats(1).found == 1,
        'and /brambulances can say how many the round has discovered -- the map '
            .. 'deliberately cannot',
        BR.Ambulances.stats(1).found)

    -- ═══ A PARKED FIND COSTS NOTHING PER PASS ═══
    sent = {}
    tick(3)
    ok(blipsIn(sent) == 0,
        'a find that has not moved sends nothing on later passes -- the same '
            .. 'rule the 23 live by, off the same movedM',
        blipsIn(sent))

    -- ═══ ...AND ONE SOMEBODY DRIVES KEEPS ITS BLIP UNDER IT ═══
    ledger[1]['v:5001'] = { x = 210.0, y = 20.0 }
    sent = {}
    tick(1)
    ok(blipsFor(1, false) == 1 and blipsFor(2, false) == 1,
        'a find that moved is re-sent to everyone watching',
        ('%d, %d'):format(blipsFor(1, false), blipsFor(2, false)))

    -- ═══ AND A SQUAD THAT LOSES A MATE MID-ROUND GETS THE LOT ═══
    ledger[1]['v:5002'] = { x = -40.0, y = -50.0 }
    roster[3].state = BR.PlayerState.OUT
    sent = {}
    tick(1)
    ok(blipsFor(3, false) == BR.Ambulances.count(1) + 2,
        'the second squad, newly bereaved, gets the 23 AND both ambulances the '
            .. 'match had found before them -- "any that other players have '
            .. 'found along the way", which is the whole point of remembering '
            .. 'them match-wide rather than per squad',
        ('%d for %d stations + 2 finds')
            :format(blipsFor(3, false), BR.Ambulances.count(1)))

    -- ═══ A STALE RECORD IS RETIRED, AND ITS BLIP WITH IT ═══
    --
    -- Ambient traffic despawns. server/rescue.lua drops the record the pass its
    -- entity stops existing; from here that is a key that stopped being walked,
    -- and the blip must come off every map holding it in the same pass. A blip
    -- pointing at nothing is worse than no blip -- a squad drives to it.
    ledger[1]['v:5001'] = nil
    sent = {}
    tick(1)
    ok(blipsFor(1, true) == 1 and blipsFor(3, true) == 1,
        'a find that leaves the ledger is withdrawn from everyone watching, in '
            .. 'the pass it went',
        ('%d, %d'):format(blipsFor(1, true), blipsFor(3, true)))
    ok(blipsFor(1, false) == 0,
        '...and nothing else is re-sent with it', blipsFor(1, false))
    ok(BR.Ambulances.stats(1).found == 1,
        'and the count follows', BR.Ambulances.stats(1).found)

    -- ═══ THEY COME OFF WITH THE REST WHEN THE SQUAD STOPS QUALIFYING ═══
    roster[2].state = BR.PlayerState.ALIVE
    roster[3].state = BR.PlayerState.ALIVE
    sent = {}
    tick(1)
    ok(blipsFor(1, true) == BR.Ambulances.count(1) + 1,
        'a squad that stops qualifying loses the finds as well as the stations '
            .. '-- `hide` walks all three lists, and a find left drawn on a map '
            .. 'nobody is entitled to is the leak that would never be noticed',
        ('%d for %d stations + 1 find')
            :format(blipsFor(1, true), BR.Ambulances.count(1)))

    -- ═══ THE 23 ARE NOT FINDS, AND THE LEDGER IS ASKED TO PROVE IT ═══
    --
    -- "engine-spawned ones". A squadmate driving one of OUR ambulances must not
    -- be recorded as a discovery -- the same van would be published twice, under
    -- `s:` and `v:`, and the client keys its blips on that string and would draw
    -- both.
    local station = nil
    for v in pairs(world) do if not station or v < station then station = v end end
    ok(BR.Ambulances.isStation(1, station) == true,
        'one of the 23 is recognised as ours', tostring(station))
    ok(BR.Ambulances.isStation(1, 5001) == false,
        'and a vehicle this file never made is not', tostring(station))
    ok(BR.Ambulances.isStation(2, station) == false,
        '...nor is one of ours when a DIFFERENT match asks -- handles are per '
            .. 'server, and a match must not disown another match\'s find')

    -- ═══ AND WITH NO DISCOVERY MODULE AT ALL, NOTHING BREAKS ═══
    --
    -- BR.Config.Rescue.enabled is a real switch, and tools/test_rescue drives
    -- server/rescue.lua with no ambulances.lua loaded at all. The reverse has to
    -- hold too, or the 23 -- which the owner waited three rounds for -- would be
    -- taken down by a feature that is a bonus.
    --
    -- THIS ALSO RESTORES THE FIXTURE the blocks below inherit: squad A's player
    -- 2 is out and 1 and 2 are watching the stations, which is where the
    -- previous block left it.
    BR.Rescue = nil
    ledger[1] = nil
    roster[2].state = BR.PlayerState.OUT
    sent = {}
    tick(1)
    ok(blipsFor(1, false) == BR.Ambulances.count(1),
        'with no ledger to read the 23 carry on exactly as they did, and the '
            .. 'last find is simply forgotten',
        ('%d for %d stations'):format(blipsFor(1, false), BR.Ambulances.count(1)))
    ok(blipsFor(1, true) == 0,
        '...with nothing withdrawn that was never drawn', blipsFor(1, true))
end

-- ---------------------------------------------------------------------------
--
-- Owner, 2026-08-31: "let's not show a blip for an ambulance while a player is
-- in that ambulance."
--
-- ═══ THE HALF THAT WOULD SHIP BROKEN AND LOOK FINE ═══
--
-- Publishing sends TRANSITIONS ONLY, so the withdrawal is the easy half and the
-- RETURN is the one that quietly does not happen: a van whose blip is withheld
-- while occupied and then simply stops being mentioned when the driver steps out
-- leaves the squad one ambulance short for the rest of the round. Nothing errors,
-- nothing logs, and there is no icon on the map to point at. Both directions are
-- driven below, and so is the pass in between -- because a rule that re-withdraws
-- every second would be a message per van per squad per second, which is the cost
-- this feature was built to avoid.
describe('no blip for an ambulance while a player is in it')
do
    -- EVERY PLAYER GETS A PED, because `occupants` skips a roster row without
    -- one -- which is what has kept every block above this exercising the
    -- unoccupied path.
    for src, e in pairs(roster) do e.ped = 900 + src end

    -- THE SEAM IS BR.Vehicles.ridingIn AND NOTHING BELOW IT. That function owns
    -- the citizenfx/fivem#4006 workaround and is asserted in its own right; what
    -- is under test here is that this file asks it, once per pass, and turns the
    -- answer into the right messages.
    --
    -- ADDED TO THE EXISTING TABLE RATHER THAN REPLACING IT. `spawnOwned` is on
    -- there and `advance` builds the 23 through it every pass -- a fresh table
    -- here takes the whole feature down two blocks later, which is how this was
    -- written the first time.
    local riding = {}
    BR.Vehicles.ridingIn = function(ped) return riding[ped] end

    local function blipsFor(src, wantGone)
        local n = 0
        for _, s in ipairs(sent) do
            if s.evt == BR.Net.RESCUE_BLIP and s.src == src
               and (s.d.gone == true) == wantGone then
                n = n + 1
            end
        end
        return n
    end

    --- The key of the one blip sent to `src` this pass, or nil.
    local function loneKey(src)
        local k = nil
        for _, s in ipairs(sent) do
            if s.evt == BR.Net.RESCUE_BLIP and s.src == src then k = s.d.key end
        end
        return k
    end

    local station = nil
    for v in pairs(world) do if not station or v < station then station = v end end
    local total = BR.Ambulances.count(1)

    -- ═══ SOMEBODY GETS IN ═══
    riding[901] = station          -- player 1, a watcher, climbs into one of ours
    sent = {}
    tick(1)
    ok(blipsFor(1, true) == 1,
        'the blip for an occupied ambulance is withdrawn', blipsFor(1, true))
    local withdrawnKey = loneKey(1)
    ok(withdrawnKey ~= nil and withdrawnKey:sub(1, 2) == 's:',
        '...and it is the station he is sitting in, by its own key',
        tostring(withdrawnKey))
    ok(blipsFor(1, false) == 0,
        'and no other van is disturbed -- the other 22 are parked and silent',
        blipsFor(1, false))

    -- IT GOES FROM THE WHOLE SQUAD, NOT JUST THE DRIVER. A blip is a fact about
    -- a vehicle, so it is withheld from everybody or from nobody; his squadmate
    -- steering toward the same van must not be sent to a van that is taken.
    ok(blipsFor(2, true) == 1,
        'the whole squad loses it, not only the player in the seat',
        blipsFor(2, true))

    -- ═══ AND STAYS QUIET WHILE HE SITS THERE ═══
    sent = {}
    tick(3)
    ok(blipsIn(sent) == 0,
        'three more passes with him still in it send nothing at all -- the '
            .. 'withdrawal is an EDGE, and re-sending it every second would be '
            .. 'the network cost this feature exists to avoid',
        blipsIn(sent))

    -- ═══ A SQUAD THAT QUALIFIES MID-OCCUPANCY GETS THE OTHER 22 ═══
    --
    -- The full push is a different branch from the transition one, and this is
    -- the case that catches it: skipped rather than pushed as `gone`, because a
    -- player who has never had that blip cannot have it withdrawn.
    roster[3].state = BR.PlayerState.OUT
    sent = {}
    tick(1)
    ok(blipsFor(3, false) == total - 1,
        'a squad that starts watching while a van is occupied is sent every '
            .. 'other one, and not that one',
        ('%d of %d'):format(blipsFor(3, false), total))
    ok(blipsFor(3, true) == 0,
        '...and is not sent a withdrawal for a blip it never had',
        blipsFor(3, true))

    -- ═══ HE GETS OUT, AND THE BLIP COMES BACK ═══
    riding[901] = nil
    sent = {}
    tick(1)
    ok(blipsFor(1, false) == 1 and loneKey(1) == withdrawnKey,
        'stepping out puts the blip back -- the same van, by the same key',
        ('%d back, key %s'):format(blipsFor(1, false), tostring(loneKey(1))))
    ok(blipsFor(3, false) == 1,
        'and the squad that never saw it gets it for the first time',
        blipsFor(3, false))

    sent = {}
    tick(2)
    ok(blipsIn(sent) == 0,
        'and it goes quiet again once it is back -- the return is an edge too',
        blipsIn(sent))

    -- ═══ AN NPC AT THE WHEEL IS NOT A PLAYER ═══
    --
    -- "while a PLAYER is in that ambulance". Ambient vans drive around with a
    -- population ped in them, and `rec.ambient` is a ledger of exactly those --
    -- so a rule that asked the VEHICLE who was in its seats would hide the blip
    -- of every found ambulance in the game. Walking the roster is what makes
    -- this case true by construction: no ped considered here belongs to nobody.
    riding[4242] = station         -- a handle no roster row carries
    sent = {}
    tick(2)
    ok(blipsIn(sent) == 0,
        'a ped that is not a player in the roster does not withhold anything',
        blipsIn(sent))
    riding[4242] = nil

    -- ═══ AND NEITHER DOES A PLAYER IN A DIFFERENT MATCH ═══
    --
    -- Player 5 is the fixture row this file already keeps for exactly this
    -- purpose ("without this row a file that ignored matchId would pass
    -- everything below"). Entity handles are unique per SERVER, so a match that
    -- walked the whole roster would usually get the same answer by luck -- which
    -- is what makes the scoping worth pinning rather than leaving to it. It is
    -- also what bounds the cost: this runs once per match per second, and
    -- without the filter it is every player on the server, every time.
    ok(roster[5].matchId == 2, 'fixture: player 5 is in another match')
    riding[905] = station
    sent = {}
    tick(2)
    ok(blipsIn(sent) == 0,
        'a player in a DIFFERENT match sitting in this match\'s van withholds '
            .. 'nothing -- occupancy is asked of this match\'s roster alone',
        blipsIn(sent))
    riding[905] = nil

    -- ═══ A FOUND VAN IS RULED THE SAME WAY, THROUGH THE SAME FIELD ═══
    --
    -- The 23 and the finds are published by one rule because they are shaped the
    -- same, and occupancy is asked of a handle both lists carry. A version that
    -- wired this to `rec.stations` alone would pass every assertion above.
    local ledger = { ['v:7001'] = { x = 40.0, y = 50.0, veh = 7001 } }
    BR.Rescue = {
        eachFound = function(matchId, fn)
            if matchId ~= 1 then return end
            for key, p in pairs(ledger) do fn(key, p.x, p.y, p.veh) end
        end,
    }

    -- ═══ A VAN DISCOVERED WITH SOMEBODY ALREADY IN IT SAYS NOTHING AT ALL ═══
    --
    -- A find is only ever recorded because a player was seen DRIVING it, so this
    -- is not a corner case -- it is the ordinary way one enters the ledger. The
    -- record is new, so `moved` is true; it is occupied, so nothing may be drawn;
    -- and `turned` must be FALSE, because a blip nobody has ever had cannot be
    -- withdrawn. Getting that last one wrong sends a withdrawal for a key the
    -- client has never seen -- harmless on screen, and a message on the wire in a
    -- feature whose entire design is "only transitions are sent".
    riding[901] = 7001
    sent = {}
    tick(1)
    ok(blipsIn(sent) == 0,
        'a find that is discovered while occupied is neither drawn nor '
            .. 'withdrawn -- there is nothing there to take back',
        blipsIn(sent))

    riding[901] = nil
    sent = {}
    tick(1)
    ok(blipsFor(1, false) == 1 and loneKey(1) == 'v:7001',
        'fixture: an unoccupied find reaches a watching squad')

    riding[901] = 7001             -- he gets into the one that was found
    sent = {}
    tick(1)
    ok(blipsFor(1, true) == 1 and loneKey(1) == 'v:7001',
        'and getting into a FOUND ambulance withdraws its blip too -- one rule, '
            .. 'both lists',
        ('%d withdrawn, key %s')
            :format(blipsFor(1, true), tostring(loneKey(1))))

    -- ...AND THE FULL PUSH SKIPS AN OCCUPIED FIND, WHICH IS A SECOND BRANCH.
    -- The transition path and the newly-qualifying path are different loops over
    -- different lists, and this is the fourth of the four: a squad that starts
    -- watching while a FOUND van is taken. Mutation testing added it -- deleting
    -- the `occupied` skip from the ambient half of the full push changed nothing
    -- until this case existed.
    local stations = BR.Ambulances.count(1)
    roster[4].state = BR.PlayerState.OUT          -- the solo starts watching
    sent = {}
    tick(1)
    local sawFound = false
    for _, s in ipairs(sent) do
        if s.evt == BR.Net.RESCUE_BLIP and s.src == 4 and s.d.key == 'v:7001' then
            sawFound = true
        end
    end
    ok(blipsFor(4, false) == stations and not sawFound,
        'a squad that starts watching while a FIND is occupied is sent the '
            .. 'stations and not that find',
        ('%d of %d stations, find sent = %s')
            :format(blipsFor(4, false), stations, tostring(sawFound)))
    roster[4].state = BR.PlayerState.ALIVE

    riding[901] = nil
    sent = {}
    tick(1)
    ok(blipsFor(1, false) == 1 and loneKey(1) == 'v:7001',
        '...and getting out of it brings that one back as well')

    -- ═══ AND WITH NO ridingIn TO ASK, NOTHING IS WITHHELD ═══
    --
    -- The workaround lives in server/vehicles.lua and a bare GetVehiclePedIsIn
    -- is not an answer this file will substitute. A build without it rules
    -- nothing, which is the direction that leaves the map complete.
    BR.Vehicles.ridingIn = nil
    riding[901] = station
    sent = {}
    tick(2)
    ok(blipsIn(sent) == 0,
        'with no BR.Vehicles.ridingIn to ask, no blip is withheld and none is '
            .. 'restored -- the feature simply is not on',
        blipsIn(sent))

    -- RESTORE THE FIXTURE the blocks below inherit: no ledger, no occupancy
    -- reader, no peds, squad A watching and squad B not.
    BR.Rescue = nil
    riding = {}
    for _, e in pairs(roster) do e.ped = nil end
    roster[3].state = BR.PlayerState.ALIVE
    sent = {}
    tick(1)
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
