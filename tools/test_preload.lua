-- The lobby's head start on the warmup's models, and the crate half of the
-- warmup fade's wait (#403).
--
--   "when we wait for the vehicle models to load, let's also wait for the crate
--    models to load. [...] would it make sense to request the models while
--    still in Lobby? Not actually spawn them, but just to front-load the
--    caching work"                                       -- owner, 2026-10-11
--
-- ═══ WHAT A PLAYTEST CANNOT SEE ═══
--
-- Every mistake here is invisible from a chair. A model asked for and never
-- handed back is memory held for the rest of the session; one handed back at
-- the wrong moment is a stream the player waits on anyway, or -- because a
-- release in br_core hands back every request for that model in br_core -- the
-- showroom's or client/loot.lua's own request taken out from under them. And a
-- set worked out wrong is the wrong season's boxes, or the festive ones in
-- October, streamed for nothing.
--
-- So this loads the real br_core/client/preload.lua over the real season, festive,
-- world and crates modules, models which models this build has and which have
-- loaded, and counts every RequestModel and SetModelAsNoLongerNeeded by name.
-- The showroom (BR.Shop.models) and client/loot.lua (BR.Loot.boxModels) are the
-- two collaborators it asks, and both are stood in for: their own halves are
-- tools/test_shop.lua's and tools/test_crates_client.lua's. The fade's half --
-- that the trip asks, and waits on the answer -- is tools/test_lobbyseq.lua's.
--
-- Run:  lua tools/test_preload.lua        (or via tools/verify.sh)

local realPrint = print
local logged = {}
function print(s) logged[#logged + 1] = tostring(s) end

-- ------------------------------------------------------------ the engine ---

local now = 1000
function GetGameTimer() return now end
function GetCurrentResourceName() return 'br_core' end
function IsDuplicityVersion() return false end

--- Every native the file under test calls, counted, so "nothing per pass" is
--- a number rather than a reading of the source.
local calls = 0

-- Names and hashes, both ways: a model is a hash to the code and a name here.
local hashOf, nameOf, nextHash = {}, {}, 50000
function GetHashKey(s)
    calls = calls + 1
    s = tostring(s)
    local h = hashOf[s]
    if not h then
        nextHash = nextHash + 1
        h = nextHash
        hashOf[s], nameOf[h] = h, s
    end
    return h
end
local function nm(h) return nameOf[h] or tostring(h) end
local function hash(s)
    local c = calls
    local h = GetHashKey(s)
    calls = c
    return h
end

--- THIS BUILD'S MODELS. `cd[name]` is in the CD image; `loaded[name]` has
--- streamed. The BOOL natives answer 1 and 0, not true and false, because a
--- FiveM BOOL native may -- and 0 is truthy in Lua.
local cd, loaded = {}, {}
local requested, released = {}, {}
function IsModelInCdimage(h) calls = calls + 1; return cd[nm(h)] and 1 or 0 end
function IsModelValid(h) calls = calls + 1; return cd[nm(h)] and 1 or 0 end
function HasModelLoaded(h) calls = calls + 1; return loaded[nm(h)] and 1 or 0 end
function RequestModel(h)
    calls = calls + 1
    requested[nm(h)] = (requested[nm(h)] or 0) + 1
end
function SetModelAsNoLongerNeeded(h)
    calls = calls + 1
    released[nm(h)] = (released[nm(h)] or 0) + 1
end

--- REPLICATED CONVARS: the season is br_seasonServed, re-read on refresh().
local convars = { br_seasonServed = '2' }
function GetConvar(n, d)
    local v = convars[n]
    if v == nil then return d end
    return tostring(v)
end
function GetConvarInt(n, d) return tonumber(convars[n]) or d end
function AddConvarChangeListener() return 1 end

local handlers = {}
function AddEventHandler(n, fn)
    handlers[n] = handlers[n] or {}
    handlers[n][#handlers[n] + 1] = fn
end
function RegisterNetEvent() end
function TriggerEvent(n, ...)
    for _, fn in ipairs(handlers[n] or {}) do fn(...) end
end

Citizen = { CreateThread = function() end, Wait = function() end,
            SetTimeout = function() end }

-- ---------------------------------------------------------------- modules ---

local ROOT = 'resources/[fivem-royale]/'
local function loadAll(files)
    for _, f in ipairs(files) do
        local chunk, err = loadfile(ROOT .. f)
        if not chunk then
            realPrint('\27[31mload error\27[0m ' .. f .. ': ' .. tostring(err))
            os.exit(1)
        end
        local fine, e = pcall(chunk)
        if not fine then
            realPrint('\27[31mrun error\27[0m ' .. f .. ': ' .. tostring(e))
            os.exit(1)
        end
    end
end

loadAll({
    'br_lib/shared/enums.lua', 'br_lib/shared/protocol.lua',
    'br_lib/shared/rng.lua', 'br_lib/shared/geo.lua', 'br_lib/shared/clock.lua',
    'br_lib/config/match.lua', 'br_lib/config/storm.lua', 'br_lib/config/map.lua',
    'br_lib/config/weapons.lua', 'br_lib/config/loot.lua',
    'br_lib/shared/season.lua', 'br_lib/config/seasons.lua',
    'br_lib/config/festive.lua', 'br_lib/shared/festive.lua',
    'br_lib/config/crates.lua', 'br_lib/shared/crates.lua',
    'br_lib/shared/world.lua',
})

--- THE LOOP REGISTRY, stood in for: which band each callback asked for, and
--- the callback itself, so a pass is one call.
local bands = {}
local loops = {}
BR.Loop = {
    FRAME = 'frame', TICK = 'tick', SLOW = 'slow',
    register = function(band, name, fn)
        bands[#bands + 1] = { band = band, name = name }
        loops[name] = fn
    end,
}

BR.State = { me = { src = 1, state = BR.PlayerState.LOBBY }, queued = false }

--- The showroom's cars (client/shop.lua's BR.Shop.models).
local CARS = { 'sultan', 'bison' }
BR.Shop = {
    models = function()
        local out = {}
        for _, n in ipairs(CARS) do out[#out + 1] = hash(n) end
        return out
    end,
}

--- The boxes client/loot.lua has built (BR.Loot.boxModels): [hash] = state.
local built = {}
--- The boxes it has written off (BR.Loot.boxWrittenOff): [hash] = true.
local dead = {}
BR.Loot = { boxModels = function() return built end,
            boxWrittenOff = function(h) return dead[h] == true end }

local C = BR.Config.Crates
local L = BR.Config.Loot

--- One box this build does not have, so "never asked for, never waited on"
--- has something to be about. Every other model is in the build.
local MISSING = C.shipping[4].open
for t = 1, 5 do
    for _, set in ipairs({ C.shipping, C.festive }) do
        cd[set[t].sealed], cd[set[t].open] = true, true
    end
end
cd[MISSING] = nil
for _, row in pairs(C.gift) do cd[row.sealed], cd[row.open] = true, true end
for _, row in pairs(C.spare) do cd[row.sealed], cd[row.open] = true, true end
cd[L.chestProp], cd[L.chestOpenProp] = true, true
for _, n in ipairs(CARS) do cd[n] = true end

BR.Season.refresh()
BR.World.setFestive(false)

loadAll({ 'br_core/client/preload.lua' })

-- ------------------------------------------------------------------ harness ---

local pass, fail = 0, 0
local function ok(cond, what, detail)
    if cond then pass = pass + 1 else
        fail = fail + 1
        realPrint('\27[31mFAIL\27[0m ' .. what
            .. (detail ~= nil and ('\n       ' .. tostring(detail)) or ''))
    end
end

--- The ten names of a set (sealed and open, tiers 1-5) this build has.
--- @param set table  C.shipping or C.festive
local function boxes(set)
    local out = {}
    for t = 1, 5 do
        for _, n in ipairs({ set[t].sealed, set[t].open }) do
            if n ~= MISSING then out[#out + 1] = n end
        end
    end
    return out
end
local PLAIN, FESTIVE = boxes(C.shipping), boxes(C.festive)

--- Is every name in `names` counted exactly once in `log`?
local function once(log, names)
    for _, n in ipairs(names) do
        if log[n] ~= 1 then return false, n .. ' x' .. tostring(log[n] or 0) end
    end
    return true
end
--- Is no name in `names` in `log` at all?
local function none(log, names)
    for _, n in ipairs(names) do
        if log[n] then return false, n end
    end
    return true
end
--- How many entries a log has, by count.
local function total(log)
    local n = 0
    for _, c in pairs(log) do n = n + c end
    return n
end
--- Does a log name anything starting with this?
local function anyPrefix(log, p)
    for n in pairs(log) do
        if n:sub(1, #p) == p then return n end
    end
    return nil
end

local function slow() loops['preload.lobby']() end
local function clear() requested, released = {}, {} end
local function season(n)
    convars.br_seasonServed = tostring(n)
    BR.Season.refresh()
end
--- Back to a player standing in the lobby, holding nothing.
local function reset()
    BR.State.me.state = BR.PlayerState.LOBBY
    BR.State.queued = false
    season(2)
    BR.World.setFestive(false)
    built, dead = {}, {}
    TriggerEvent('onClientResourceStop', 'br_core')
    for k in pairs(loaded) do loaded[k] = nil end
    clear()
end
local function heldKinds()
    local cars, crates = 0, 0
    for _, kind in pairs(BR.Preload.held()) do
        if kind == 'car' then cars = cars + 1 else crates = crates + 1 end
    end
    return cars, crates
end

-- ═══════════════════════════════════════════════════════════════════════════
-- 1. ONE PASS A SECOND, AND NOTHING ON THE FRAME OR THE TICK
-- ═══════════════════════════════════════════════════════════════════════════
do
    ok(#bands == 1 and bands[1].band == BR.Loop.SLOW and bands[1].name == 'preload.lobby',
        'the file registers one callback, on the SLOW band, and none per frame '
            .. 'or per tick', #bands)
    ok(type(BR.Preload.pendingCrates) == 'function' and type(BR.Preload.trip) == 'function',
        'and gives client/spawn.lua the crate count and the trip\'s ask')
end

-- ═══════════════════════════════════════════════════════════════════════════
-- 2. THE LOBBY: NOTHING UNTIL QUEUED, THEN EVERYTHING, ONCE
-- ═══════════════════════════════════════════════════════════════════════════
do
    reset()
    slow()
    ok(total(requested) == 0, 'standing in the lobby, not queued, asks for nothing',
        total(requested))

    BR.State.queued = true
    slow()
    local fine, why = once(requested, CARS)
    ok(fine, 'queued in the lobby, every showroom car is asked for, once', why)
    fine, why = once(requested, PLAIN)
    ok(fine, 'and every Season 2 box this warmup builds, sealed and open, once', why)
    ok(none(requested, FESTIVE) and none(requested, { L.chestProp, L.chestOpenProp })
           and not anyPrefix(requested, 'blitz_loot_largegift')
           and not anyPrefix(requested, 'blitz_loot_plain'),
        'and nothing else: no festive box out of the festive months, no gift box, '
            .. 'no spare, and not the wooden pair client/loot.lua already holds')
    ok(requested[MISSING] == nil,
        'a box this build does not have is never asked for')
    ok(total(released) == 0, 'and nothing is handed back', total(released))

    local c = calls
    clear()
    slow()
    slow()
    ok(total(requested) == 0 and calls == c,
        'every pass after that asks for nothing and calls no native at all',
        calls - c)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- 3. FESTIVE ONLY WHEN FESTIVE, AND BACK
-- ═══════════════════════════════════════════════════════════════════════════
do
    reset()
    BR.State.queued = true
    slow()
    clear()

    BR.World.setFestive(true)
    slow()
    local fine, why = once(requested, FESTIVE)
    ok(fine, 'the festive answer arriving asks for the festive boxes', why)
    fine, why = once(released, PLAIN)
    ok(fine, 'and hands back the plain ones it no longer builds', why)
    ok(none(requested, CARS) and none(released, CARS),
        'without touching the cars, which the festive months do not change')

    clear()
    BR.World.setFestive(false)
    slow()
    fine, why = once(requested, PLAIN)
    ok(fine and once(released, FESTIVE),
        'and going off swaps them back', why)

    -- AND ONLY ON SEASON 2. The festive sky on a Season 1 client is not a
    -- thing the server sends, but a stale fact must still not bring boxes.
    reset()
    season(1)
    BR.World.setFestive(true)
    BR.State.queued = true
    slow()
    ok(not anyPrefix(requested, 'blitz_'),
        'a festive answer on Season 1 asks for no box of either set',
        anyPrefix(requested, 'blitz_'))
end

-- ═══════════════════════════════════════════════════════════════════════════
-- 4. SEASON 1 ASKS FOR NO SEASON 2 CRATE; A SEASON SWITCH SWAPS THE SET
-- ═══════════════════════════════════════════════════════════════════════════
do
    reset()
    season(1)
    BR.State.queued = true
    slow()
    ok(once(requested, CARS), 'on Season 1 the cars are still asked for')
    ok(not anyPrefix(requested, 'blitz_'),
        'and no Season 2 box at all', anyPrefix(requested, 'blitz_'))
    ok(none(requested, { L.chestProp, L.chestOpenProp }),
        'and not the wooden pair: client/loot.lua holds it from load')

    clear()
    season(2)
    slow()
    ok(once(requested, PLAIN), 'switching to Season 2 asks for its boxes')
    ok(none(requested, CARS) and total(released) == 0,
        'and touches nothing else', total(released))

    clear()
    season(1)
    slow()
    local fine, why = once(released, PLAIN)
    ok(fine, 'switching back to Season 1 hands every box back', why)
    ok(none(released, CARS) and total(requested) == 0,
        'and keeps the cars, which no season changes')
    ok(none(released, { L.chestProp, L.chestOpenProp }),
        'and never hands back the wooden pair, which is not this file\'s')
end

-- ═══════════════════════════════════════════════════════════════════════════
-- 5. NOT READY, OR A QUEUE THAT BROKE UP: HANDED BACK AFTER THE GRACE
-- ═══════════════════════════════════════════════════════════════════════════
do
    reset()
    BR.State.queued = true
    slow()
    clear()

    BR.State.queued = false
    slow()
    now = now + BR.Preload.graceMs - 1000
    slow()
    ok(total(released) == 0,
        'inside the grace nothing is handed back -- a queue consumed a beat '
            .. 'before my state reads warmup looks exactly like this', total(released))

    now = now + 1000
    slow()
    local fine, why = once(released, CARS)
    ok(fine, 'once it has passed, every car is handed back', why)
    fine, why = once(released, PLAIN)
    ok(fine, 'and every box', why)
    local cars, crates = heldKinds()
    ok(cars == 0 and crates == 0, 'and nothing is held', cars + crates)

    clear()
    now = now + 5000
    slow()
    slow()
    ok(total(released) == 0 and total(requested) == 0,
        'and the passes after that do nothing')

    -- QUEUED AGAIN INSIDE THE GRACE: the clock starts over.
    reset()
    BR.State.queued = true
    slow()
    clear()
    BR.State.queued = false
    slow()
    now = now + 3000
    BR.State.queued = true
    slow()
    BR.State.queued = false
    now = now + BR.Preload.graceMs - 1000
    slow()
    ok(total(released) == 0 and total(requested) == 0,
        'queuing again inside the grace keeps everything, and the next grace '
            .. 'starts from the next time I leave')
end

-- ═══════════════════════════════════════════════════════════════════════════
-- 6. WARMUP: THE CARS ARE THE SHOWROOM'S, THE BOXES STAY UNTIL I LEAVE
-- ═══════════════════════════════════════════════════════════════════════════
do
    reset()
    BR.State.queued = true
    slow()
    clear()

    -- The match takes me: the lobby broadcast drops me from the queue first.
    BR.State.queued = false
    slow()
    BR.State.me.state = BR.PlayerState.WARMUP
    BR.Preload.trip()
    ok(total(released) == 0,
        'the trip hands the cars to the showroom WITHOUT a release -- one '
            .. 'here would hand back the request the fade is waiting on',
        total(released))
    ok(total(requested) == 0,
        'and asks for no box the lobby already asked for', total(requested))
    local cars, crates = heldKinds()
    ok(cars == 0 and crates == #PLAIN,
        'the boxes are still held through warmup; the cars are no longer this '
            .. 'file\'s', ('%d cars, %d boxes'):format(cars, crates))

    now = now + 60000
    slow()
    slow()
    ok(total(released) == 0 and total(requested) == 0,
        'a whole warmup of passes changes nothing')

    -- client/loot.lua builds two of them on the pad.
    local RARE, EPIC = C.shipping[3].sealed, C.shipping[4].sealed
    built[hash(RARE)], built[hash(EPIC)] = 'sealed', 'sealed'

    BR.State.me.state = BR.PlayerState.BUS
    slow()
    ok(released[RARE] == nil and released[EPIC] == nil,
        'leaving warmup does NOT hand back the boxes client/loot.lua built: '
            .. 'those are its to keep resident now (#395)')
    local rest = {}
    for _, n in ipairs(PLAIN) do
        if n ~= RARE and n ~= EPIC then rest[#rest + 1] = n end
    end
    local fine, why = once(released, rest)
    ok(fine, 'and hands back every other box at once -- no grace out of the lobby', why)
    ok(none(released, CARS), 'and no car: those were the showroom\'s to hand back')
    cars, crates = heldKinds()
    ok(cars == 0 and crates == 0, 'nothing is held into the match', cars + crates)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- 7. A TRIP NOBODY QUEUED FOR, AND A WARMUP THAT DISSOLVES
-- ═══════════════════════════════════════════════════════════════════════════
do
    reset()
    BR.State.me.state = BR.PlayerState.WARMUP
    BR.Preload.trip()
    local fine, why = once(requested, PLAIN)
    ok(fine, 'a trip with no lobby head start -- a late join, a rejoin -- asks '
        .. 'for the boxes itself', why)
    ok(none(requested, CARS),
        'but not the cars: BR.Shop.preload asks for those beside it')
    clear()
    BR.Preload.trip()
    BR.Preload.trip()
    ok(total(requested) == 0, 'and a refused trip\'s retries ask for nothing again')

    -- The match dissolves under warmup: back in the lobby, not queued.
    BR.State.me.state = BR.PlayerState.LOBBY
    slow()
    ok(total(released) == 0, 'back in the lobby, the boxes wait out the grace')
    now = now + BR.Preload.graceMs
    slow()
    fine, why = once(released, PLAIN)
    ok(fine, 'and then are handed back', why)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- 8. THE SEASON MOVING UNDER WARMUP
-- ═══════════════════════════════════════════════════════════════════════════
do
    reset()
    BR.State.me.state = BR.PlayerState.WARMUP
    BR.Preload.trip()
    clear()
    BR.World.setFestive(true)
    slow()
    ok(once(released, PLAIN) and once(requested, FESTIVE),
        'a `brfestive` under warmup swaps the boxes for the ones the pad is '
            .. 'restamped with')
    clear()
    season(1)
    slow()
    ok(once(released, FESTIVE) and total(requested) == 0,
        'and a switch to Season 1 hands them all back')
end

-- ═══════════════════════════════════════════════════════════════════════════
-- 9. br_core STOPPING HANDS BACK WHATEVER IS HELD
-- ═══════════════════════════════════════════════════════════════════════════
do
    reset()
    BR.State.queued = true
    slow()
    clear()
    TriggerEvent('onClientResourceStop', 'br_ui')
    ok(total(released) == 0, 'another resource stopping is not br_core stopping')
    TriggerEvent('onClientResourceStop', 'br_core')
    ok(once(released, CARS) and once(released, PLAIN),
        'br_core stopping hands back every car and every box it holds')
end

-- ═══════════════════════════════════════════════════════════════════════════
-- 10. WHAT THE FADE WAITS ON: THE CRATE MODELS THIS WARMUP BUILDS, UNLOADED
-- ═══════════════════════════════════════════════════════════════════════════
do
    reset()
    BR.State.me.state = BR.PlayerState.WARMUP
    ok(BR.Preload.pendingCrates() == #PLAIN,
        ('on Season 2, every box this build has and has not loaded is waited on '
            .. '(%d of %d -- not the one it does not have)')
            :format(BR.Preload.pendingCrates(), #PLAIN))
    for i, n in ipairs(PLAIN) do
        if i <= 4 then loaded[n] = true end
    end
    ok(BR.Preload.pendingCrates() == #PLAIN - 4,
        'and the count falls as they load', BR.Preload.pendingCrates())
    for _, n in ipairs(PLAIN) do loaded[n] = true end
    ok(BR.Preload.pendingCrates() == 0, 'to nothing once they all have')

    for _, n in ipairs(FESTIVE) do loaded[n] = nil end
    BR.World.setFestive(true)
    ok(BR.Preload.pendingCrates() == #FESTIVE,
        'festive, the festive set is what is waited on -- not the plain one '
            .. 'that has loaded', BR.Preload.pendingCrates())

    season(1)
    BR.World.setFestive(false)
    loaded[L.chestProp], loaded[L.chestOpenProp] = nil, nil
    ok(BR.Preload.pendingCrates() == 2,
        'on Season 1 it is the wooden pair', BR.Preload.pendingCrates())
    loaded[L.chestProp], loaded[L.chestOpenProp] = true, true
    ok(BR.Preload.pendingCrates() == 0,
        'which client/loot.lua has resident from load, so on a live Season 1 '
            .. 'server it costs the fade nothing')

    local c = calls
    clear()
    BR.Preload.pendingCrates()
    ok(total(requested) == 0 and total(released) == 0,
        'asking the count asks the streamer for nothing', calls - c)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- 11. A BOX client/loot.lua WROTE OFF IS NEITHER WAITED ON NOR ASKED FOR AGAIN
-- ═══════════════════════════════════════════════════════════════════════════
--
-- #403 review: loot.lua gives a box that will not stream three seconds and then
-- draws every crate wearing it as the wooden crate for the session. Still
-- counted here, it held the fade its whole ten seconds, under "Loading
-- assets", on every trip after.
do
    reset()
    local DEAD = C.shipping[2].sealed
    BR.State.me.state = BR.PlayerState.WARMUP
    BR.Preload.trip()
    ok(BR.Preload.pendingCrates() == #PLAIN,
        'precondition: every box this build has is waited on', BR.Preload.pendingCrates())
    dead[hash(DEAD)] = true
    ok(BR.Preload.pendingCrates() == #PLAIN - 1,
        'a box written off during the wait stops holding it at once',
        BR.Preload.pendingCrates())

    -- The next trip, from a queued lobby.
    BR.State.me.state = BR.PlayerState.BUS
    slow()
    clear()
    BR.State.me.state = BR.PlayerState.LOBBY
    BR.State.queued = true
    slow()
    local rest = {}
    for _, n in ipairs(PLAIN) do
        if n ~= DEAD then rest[#rest + 1] = n end
    end
    local fine, why = once(requested, rest)
    ok(fine and requested[DEAD] == nil,
        'and the lobby asks for every other box, but never that one again', why)
    BR.State.me.state = BR.PlayerState.WARMUP
    BR.Preload.trip()
    for _, n in ipairs(rest) do loaded[n] = true end
    ok(BR.Preload.pendingCrates() == 0,
        'so the next trip\'s wait ends when the rest have loaded',
        BR.Preload.pendingCrates())
end

-- ---------------------------------------------------------------- result ---

realPrint(('\n\27[32m%d passed\27[0m'):format(pass))
if fail > 0 then
    realPrint(('\27[31m%d failed\27[0m'):format(fail))
    os.exit(1)
end
