-- The warmup's models, asked for from the lobby, and the crate half of what the
-- warmup's fade waits on (#403).
--
-- Owner, 2026-10-11: "when loading from lobby to warmup, when we wait for the
-- vehicle models to load, let's also wait for the crate models to load. [...]
-- would it make sense to request the models while still in Lobby? Not actually
-- spawn them, but just to front-load the caching work" -- and the answer to the
-- question was yes.
--
-- ═══ TWO JOBS, ONE LIST ═══
--
--   THE CRATES      which crate models the warmup this client is heading into
--                   builds. On Season 2 (crates2): every tier's shipping box,
--                   sealed AND open, because opening one swaps the sealed prop
--                   for the open one -- from the festive set when the server
--                   says it is festive, and from the plain set when it does not.
--                   On Season 1: the wooden pair. client/spawn.lua's fade waits
--                   on them beside the showroom's cars (BR.Preload.pendingCrates).
--   THE HEAD START  while this player is queued in the lobby, those boxes and
--                   the showroom's cars (BR.Shop.models) are asked for --
--                   streamed, never spawned -- so the trip to the pad finds them
--                   already in memory instead of starting from nothing on black.
--
-- ═══ WHO HANDS EACH MODEL BACK ═══
--
-- A model request belongs to the RESOURCE that made it, not to the line: one
-- SetModelAsNoLongerNeeded anywhere in br_core hands back every RequestModel of
-- that model in br_core. client/shop.lua's preload is built on the same fact
-- (its build's release is what hands the trip's request back). So each model
-- has one owner at a time, and this file only ever lets go of what is its own:
--
--   THE CARS        this file's in the lobby, the showroom's from the trip on.
--                   BR.Shop.preload asks for them again as the trip starts and
--                   the pad's build hands each back once its car stands (#368),
--                   so they are forgotten here at that hand-over, never released
--                   -- a release here would hand back the request the fade is
--                   waiting on.
--   THE BOXES       this file's through warmup, so a box opened on the pad
--                   swaps without a stream. Once client/loot.lua has built a box
--                   (BR.Loot.boxModels) it is loot.lua's: it keeps them resident
--                   on purpose (#395) and hands them back itself when crates2
--                   goes off. Every other box is handed back here as this player
--                   leaves warmup.
--   THE WOODEN PAIR client/loot.lua's for the whole session, asked for when it
--                   loads. Waited on; never asked for or handed back here.
--
-- ═══ AND EVERY OTHER ROAD HANDS THEM BACK TOO ═══
--
--   Not ready, or a queue that broke up   in the lobby and not queued for
--                   `graceMs`. The grace is for the queue being consumed a beat
--                   before my state reads warmup: the lobby broadcast can drop
--                   me from the queue before the roster delta names me a
--                   participant.
--   A warmup that dissolved               back in the lobby and not queued: the
--                   same grace, then the boxes go.
--   The season or the festive answer moving   the set is worked out again;
--                   what left it is handed back and what joined it is asked for.
--   br_core stopping.
--
-- ═══ NOTHING PER FRAME ═══
--
-- One SLOW pass a second that reads a handful of fields and asks the streamer
-- for something only when the answer has moved. The fade polls pendingCrates
-- twenty times a second, but only while it is holding the black.

BR = BR or {}
BR.Preload = BR.Preload or {}

--- IN LUA 0 IS TRUTHY, AND A FIVEM NATIVE DECLARED BOOL MAY ANSWER 1 RATHER
--- THAN true. Every BOOL native in this file goes through here.
local isTrue = BR.NativeTruthy

--- How long this player may stand in the lobby, unqueued, before the head start
--- is handed back. See the header for why it is not zero.
BR.Preload.graceMs = 5000

--- [hash] = 'car' | 'crate': every request this file holds right now.
local held = {}

--- Whether the cars in `held` are still this file's (the lobby's), rather than
--- handed to the showroom.
local carsHeld = false

--- What `held` was last worked out for: the season, crates2, the festive answer
--- and whether it took the cars. nil when nothing has been asked for since the
--- last full hand-back, which makes the next pass that wants something ask.
local asked = nil

--- When this player was first seen in the lobby, unqueued, with something still
--- held; nil otherwise.
local idleSince = nil

--- [hash] = boolean: does this build have this model? Asked once per model per
--- session, like client/loot.lua's boxInCd -- the answer cannot change under a
--- running game. A box this build does not have can never load, so it is never
--- asked for and never waited on.
local inBuild = {}

--- The crate set, kept for the answers it was worked out from.
local cache = { season = false, on = false, festive = false, list = {} }

--- Sealed and open, in that order.
local OPEN_STATES = { false, true }

--- Are Season 2 crates on, in this client's season? client/loot.lua's cached
--- answer when it is loaded, so the boxes waited on are the boxes it builds.
--- @return boolean
local function crates2On()
    if BR.Loot and BR.Loot.crates2On then return BR.Loot.crates2On() == true end
    return BR.Season ~= nil and BR.Season.has('crates2') == true
end

--- The festive answer this client holds: the server's one fact on the world
--- payload (BR.World.festive, #399). It comes from the same festive calendar
--- and the same `brfestive` switch the server stamps the crates' `bf` from, and
--- only ever while Season 2 is on -- which is why the set below asks it only
--- when crates2 is.
--- @return boolean
local function festiveNow()
    return BR.World ~= nil and BR.World.isFestive ~= nil and BR.World.isFestive() == true
end

--- @return integer|nil
local function seasonNow()
    if BR.Season and BR.Season.current then return BR.Season.current() end
    return nil
end

--- The crate models this client's warmup builds: { hash, ours } each, where
--- `ours` is false for the wooden pair (client/loot.lua's, see the header).
--- Worked out again only when the season, crates2 or the festive answer moved.
--- @return table[]
local function crateSet()
    local season, on = seasonNow(), crates2On()
    local festive = on and festiveNow()
    if cache.season == season and cache.on == on and cache.festive == festive then
        return cache.list
    end
    local list = {}
    if on and BR.Crates and BR.Crates.modelName then
        for tier = 1, 5 do
            for _, open in ipairs(OPEN_STATES) do
                local name = BR.Crates.modelName({ t = tier, f = festive }, open)
                if name then list[#list + 1] = { hash = GetHashKey(name), ours = true } end
            end
        end
    else
        local L = BR.Config.Loot or {}
        for _, name in ipairs({ L.chestProp or '', L.chestOpenProp or '' }) do
            if name ~= '' then list[#list + 1] = { hash = GetHashKey(name), ours = false } end
        end
    end
    cache.season, cache.on, cache.festive, cache.list = season, on, festive, list
    return list
end

--- Does this build have this model?
--- @param hash integer
--- @return boolean
local function inThisBuild(hash)
    local known = inBuild[hash]
    if known == nil then
        known = isTrue(IsModelInCdimage(hash)) and isTrue(IsModelValid(hash))
        inBuild[hash] = known
    end
    return known
end

--- Has client/loot.lua written this box off -- a stream that timed out there,
--- or an object the engine refused -- so every crate wearing it is the wooden
--- crate? Then it is neither asked for nor waited on (#403 review): a box in
--- the build that never streams would otherwise hold the fade its whole ten
--- seconds, under "Loading assets", on every trip for the rest of the session.
--- Asked live, not cached: the answer can arrive during a wait.
--- @param hash integer
--- @return boolean
local function writtenOff(hash)
    return BR.Loot ~= nil and BR.Loot.boxWrittenOff ~= nil
        and BR.Loot.boxWrittenOff(hash) == true
end

--- Has client/loot.lua built this box, and so taken it over?
--- @param hash integer
--- @return boolean
local function lootHas(hash)
    local built = BR.Loot and BR.Loot.boxModels and BR.Loot.boxModels() or nil
    return type(built) == 'table' and built[hash] ~= nil
end

--- Hand one request back -- unless client/loot.lua has built the model since,
--- in which case it is loot.lua's now and is only forgotten here.
--- @param hash integer
local function letGo(hash)
    if held[hash] == nil then return end
    held[hash] = nil
    if lootHas(hash) then return end
    SetModelAsNoLongerNeeded(hash)
end

--- The cars become the showroom's: forgotten, NOT released. See the header.
local function handOverCars()
    if not carsHeld then return end
    for hash, kind in pairs(held) do
        if kind == 'car' then held[hash] = nil end
    end
    carsHeld = false
end

--- Hand back everything this file still holds.
local function releaseAll()
    for hash in pairs(held) do letGo(hash) end
    carsHeld = false
    asked = nil
    idleSince = nil
end

--- Has anything `held` was worked out for moved?
--- @param withCars boolean
--- @return boolean
local function moved(withCars)
    if asked == nil then return true end
    local on = crates2On()
    return asked.cars ~= withCars or asked.season ~= seasonNow() or asked.on ~= on
        or asked.festive ~= (on and festiveNow())
end

--- Make `held` exactly the set wanted now: hand back what left it, ask for what
--- joined it. With `withCars`, the showroom's cars are part of it.
--- @param withCars boolean
local function sync(withCars)
    local want = {}
    if withCars and BR.Shop and BR.Shop.models then
        local fine, list = pcall(BR.Shop.models)
        if fine and type(list) == 'table' then
            for _, hash in ipairs(list) do want[hash] = 'car' end
        end
    end
    for _, m in ipairs(crateSet()) do
        if m.ours and inThisBuild(m.hash) and not writtenOff(m.hash) then
            want[m.hash] = 'crate'
        end
    end

    for hash in pairs(held) do
        if want[hash] == nil then letGo(hash) end
    end
    for hash, kind in pairs(want) do
        if held[hash] == nil then RequestModel(hash) end
        held[hash] = kind
    end
    carsHeld = withCars and next(want) ~= nil

    local on = crates2On()
    asked = { cars = withCars, season = seasonNow(), on = on,
              festive = on and festiveNow() }
end

--- How many of this warmup's crate models are not loaded yet -- the crate half
--- of what client/spawn.lua's fade waits on (#403), beside BR.Shop.pendingCars.
---
--- A model this build does not have is never counted: it could never load,
--- and a client without the Season 2 props draws the wooden crate instead
--- (client/loot.lua). Nor is one client/loot.lua has written off (writtenOff),
--- for the same reason. One that is in the build and never loads is what the
--- fade's ten seconds are for -- at most once a session, since loot.lua writes it
--- off three seconds into building it. Asks for nothing -- BR.Preload.trip did.
--- @return integer
function BR.Preload.pendingCrates()
    local n = 0
    for _, m in ipairs(crateSet()) do
        if inThisBuild(m.hash) and not writtenOff(m.hash)
                and not isTrue(HasModelLoaded(m.hash)) then
            n = n + 1
        end
    end
    return n
end

--- The trip to the pad has started (client/spawn.lua, beside BR.Shop.preload).
---
--- The cars are handed to the showroom, and the crate set is asked for if the
--- lobby did not already -- a late join, a rejoin, a queue too short for a SLOW
--- pass. IDEMPOTENT, so a refused trip's retry costs nothing.
function BR.Preload.trip()
    idleSince = nil
    handOverCars()
    if moved(false) then sync(false) end
end

--- What this file holds, for the suites: a fresh { [hash] = 'car' | 'crate' }.
--- @return table
function BR.Preload.held()
    local out = {}
    for hash, kind in pairs(held) do out[hash] = kind end
    return out
end

-- The head start, reconciled once a second. A reconciler rather than handlers on
-- the queue, the season and the festive fact, for the reason client/shop.lua's
-- scene is one: every case that is not an edge -- a late join, a br_core
-- restart, an answer that moved while nobody was listening -- is a comparison
-- here, not a handler that did not run.
BR.Loop.register(BR.Loop.SLOW, 'preload.lobby', function()
    local st = BR.State.me.state

    if st == BR.PlayerState.WARMUP then
        idleSince = nil
        handOverCars()
        if moved(false) then sync(false) end
        return
    end

    if st == BR.PlayerState.LOBBY and BR.State.queued == true then
        idleSince = nil
        if moved(true) then sync(true) end
        return
    end

    if asked == nil and next(held) == nil then return end
    if st == BR.PlayerState.LOBBY then
        local now = GetGameTimer()
        idleSince = idleSince or now
        if now - idleSince < BR.Preload.graceMs then return end
    end
    releaseAll()
end)

AddEventHandler('onClientResourceStop', function(res)
    if res == GetCurrentResourceName() then releaseAll() end
end)
