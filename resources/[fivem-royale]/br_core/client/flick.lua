-- Flick cameras (#419), Season 2, client half: WHAT THIS PLAYER SEES OF THE
-- CAMERAS, and the one thing it tells the server. It decides nothing; every
-- down is server/flick.lua's.
--
--   the watch     once a second, the cameras near this player: one that went
--                 down on this client's own copy is reported, once a match
--                 (FLICK_REPORT) -- "I did it", or "it fell"
--   the downs     every camera the server says is down in this match
--                 (FLICK_DOWN, the snapshot): its model hidden here, and a
--                 stand-in wreck drawn near the view
--   Season 1      every camera the ymap stands hidden while Flick is off here
--   the coverage  the Scan squad's: a circle per live camera on the big map,
--                 only while it is up, only while Scan's pushes say `flick`
--   the dev tools `brflick`, and `brflicktune`: the coverage's look on the keys
--
-- ═══ A MAP OBJECT IS THIS CLIENT'S ALONE ═══
--
-- The ymap's cameras are map objects, and each client has its own copy of
-- each. So only a client can see one break, and "broken for everyone" is drawn
-- by each client from the server's list: a model hide at the row
-- (CreateModelHideExcludingScriptObjects, surviving a map reload, so a camera
-- that streams in later arrives hidden) and, near the view, a local script
-- object of the wreck the server's cause names -- a script object is never
-- caught by that hide. Lifted again on a new match, in the lobby, off Season 2
-- and when br_core stops.
--
-- ═══ NO OTHER PLAYER'S PED IS EVER RESOLVED ═══
--
-- A report says `me` when this player's own ped -- or the vehicle they drive,
-- from its seat -- damaged the camera, and `other` otherwise. Nothing here
-- needs to know who anybody else is, so none of the scope gate's natives is
-- called, and the server credits only the player whose own report says `me`.
--
-- ═══ WHAT IT COSTS ═══
--
-- Nothing per frame. The watch returns before any native unless Flick is on,
-- this player's match is PLAYING and they are standing or downed; then the
-- cameras within client.nearM cost five reads a camera a second (exists,
-- health, broken, upright, and the damage record cleared) and a find only as
-- one comes into reach -- ten cameras in the city is fifty natives a second.
-- The model hides and the coverage circles are made on a FRAME callback that
-- exists only while some are waiting, a batch a frame (client.hidesPerFrame,
-- client.coverageBatch), and the coverage's TICK callback exists only while
-- Scan's pushes say `flick`. tools/perf_client.lua's budget holds all of it.

BR = BR or {}
BR.Flick = BR.Flick or {}

local F = BR.Flick
local FS = BR.FlickSolve

--- A FiveM BOOL native may answer 1/0, and 0 is truthy in Lua. Every BOOL read
--- in this file goes through here (tools/bool_native_rules.lua).
local isTrue = BR.NativeTruthy

local function cfg() return BR.Config.Flick end
local function C() return BR.Config.Flick.client or {} end
local function art() return BR.Config.Flick.art or {} end

--- THE SEASON, ASKED ONCE A SECOND (client/terminalfx.lua's reason): the
--- watch, the handlers and the coverage read this boolean, and the SLOW pass
--- and BR.Season.onChange refresh it.
local seasonOn = false
local function refreshSeason()
    seasonOn = BR.Season ~= nil and BR.Season.has ~= nil and BR.Season.has('flick') == true
end
refreshSeason()

local function on()
    return seasonOn
end

--- Does this client know which season it runs yet? Until br_seasonServed
--- lands every gate is shut, and hiding every camera for those seconds only
--- to show them all again would be the season switch's cost twice over.
local function seasonKnown()
    return BR.Season ~= nil and BR.Season.current ~= nil and BR.Season.current() ~= nil
end

--- The registry in cells, built once (BR.FlickSolve.grid).
local grid = FS.grid(cfg().cameras or {}, cfg().gridM)

-- ------------------------------------------------------------- the state ---

--- The cameras down in this match, as the server said: [id] = cause.
local downs = {}
--- The match that list is for (nil: none).
local downMatch = nil
--- The cameras this client reported this match, whatever the server said.
local reported = {}
--- The watch's handles: [id] = { h, max, hp, up }.
local handles = {}
--- A row the watch found nothing at: [id] = when it may be asked again.
local misses = {}
--- This client's own copy that it saw go down: [id] = handle. A real wreck,
--- so no stand-in is drawn over it while it exists.
local fell = {}
--- The stand-in wrecks: [id] = handle.
local wrecks = {}
--- The model hides this client holds: [id] = { x, y, z, r, hash }.
local hidden = {}
--- The coverage circles up: [id] = blip.
local circles = {}
--- The season answer every camera's hide was last brought to (nil: never).
local hidesFor = nil

local cameraHash = nil
local function modelHash()
    if cameraHash == nil then
        local name = art().model
        cameraHash = (type(name) == 'string' and name ~= '') and GetHashKey(name) or false
    end
    return cameraHash
end

local function count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

local function removeBlip(b)
    if b and isTrue(DoesBlipExist(b)) then RemoveBlip(b) end
end

local function dropObject(h)
    if h and isTrue(DoesEntityExist(h)) then DeleteObject(h) end
end

--- Where this client's view is: the storm's viewpoint (a spectator's shot),
--- or the player.
local function viewpoint()
    if BR.Storm and BR.Storm.viewpoint then
        local p = BR.Storm.viewpoint()
        if p then return p end
    end
    return GetEntityCoords(PlayerPedId())
end

-- -------------------------------------------- the work, a batch a frame ---
--
-- ═══ ONE FRAME CALLBACK, AND ONLY WHILE THERE IS WORK ═══
--
-- A model hide and a radius blip are each engine work far past a read, and a
-- season switch is one of each per camera. So every hide and every circle is
-- QUEUED by id and made by 'flick.work', client.hidesPerFrame hides and
-- client.coverageBatch circles a frame, registered when the first job arrives
-- and unregistered when the last is done. A job carries no verdict: it asks,
-- as it runs, what that camera should be NOW (hidden while Flick is off here
-- or the camera is down; a circle while the coverage shows and it is up), so
-- a hide and an unhide queued one after the other settle on the last word,
-- and a job that finds nothing to change calls nothing.

local function queue()
    return { items = {}, head = 1, tail = 0, queued = {} }
end
local hideQ, circleQ = queue(), queue()

local worker = nil
local work

local function wake()
    if worker == nil then worker = BR.Loop.register(BR.Loop.FRAME, 'flick.work', work) end
end

local function push(q, id)
    if q.queued[id] then return end
    q.queued[id] = true
    q.tail = q.tail + 1
    q.items[q.tail] = id
    wake()
end

local function pop(q)
    if q.head > q.tail then return nil end
    local id = q.items[q.head]
    q.items[q.head] = nil
    q.head = q.head + 1
    if q.head > q.tail then q.head, q.tail = 1, 0 end
    q.queued[id] = nil
    return id
end

local function wantHidden(id)
    return hidesFor == false or downs[id] ~= nil
end

--- Bring one camera's model hide to what it should be. True when a native
--- was called.
local function applyHide(id)
    local want, h = wantHidden(id), hidden[id]
    if want and not h then
        local row, hash = FS.row(grid, id), modelHash()
        if not row or not hash then return false end
        local r = tonumber(art().hideRadiusM) or 1.5
        CreateModelHideExcludingScriptObjects(row.x, row.y, row.z, r, hash, true)
        hidden[id] = { x = row.x, y = row.y, z = row.z, r = r, hash = hash }
        return true
    elseif h and not want then
        RemoveModelHide(h.x, h.y, h.z, h.r, h.hash, false)
        hidden[id] = nil
        return true
    end
    return false
end

--- Is the coverage on the big map up? Set by the coverage pass below.
local showing = false

--- The coverage's look: art.coverage, which `brflicktune` writes live.
--- @return number color, number alpha
local function coverageLook()
    local look = art().coverage or {}
    return tonumber(look.colour) or 5, tonumber(look.alpha) or 25
end

--- Bring one camera's coverage circle to what it should be.
local function applyCircle(id)
    local want, b = showing and on() and downs[id] == nil, circles[id]
    if want and not b then
        local row = FS.row(grid, id)
        if not row then return false end
        local color, alpha = coverageLook()
        -- NO NAME, AND OFF THE LEGEND: hundreds of circles are one thing to the
        -- player, and a legend with hundreds of entries flickers and rebuilds.
        b = BR.Native.radiusBlip(nil, row.x, row.y, cfg().rangeM or 75.0, color, alpha, nil)
        BR.Native.blipHiddenOnLegend(b, true)
        circles[id] = b
        return true
    elseif b and not want then
        removeBlip(b)
        circles[id] = nil
        return true
    end
    return false
end

work = function()
    local n = C().hidesPerFrame or 25
    while n > 0 do
        local id = pop(hideQ)
        if id == nil then break end
        if applyHide(id) then n = n - 1 end
    end
    n = C().coverageBatch or 100
    while n > 0 do
        local id = pop(circleQ)
        if id == nil then break end
        if applyCircle(id) then n = n - 1 end
    end
    if hideQ.head > hideQ.tail and circleQ.head > circleQ.tail then
        BR.Loop.unregister(worker)
        worker = nil
    end
end

--- Every camera's hide brought to the season's answer: on start, on every move
--- of the season, and from the SLOW pass when a move went unannounced -- never
--- per pass. Only a camera whose hide must change is queued.
local function syncHides()
    if not seasonKnown() then return end
    hidesFor = on()
    for _, row in ipairs(grid.rows) do
        local id = row.id
        if grid.byId[id] and wantHidden(id) ~= (hidden[id] ~= nil) then push(hideQ, id) end
    end
end

--- Every camera's circle brought to `showing`.
local function syncCircles()
    for _, row in ipairs(grid.rows) do
        local id = row.id
        local want = showing and on() and downs[id] == nil
        if grid.byId[id] and want ~= (circles[id] ~= nil) then push(circleQ, id) end
    end
end

-- -------------------------------------------------------------- the downs ---

local wreckHashes = {}
--- [hash] = true: a wreck model this client asked to stream.
local requested = {}

--- Is a wreck model ready to make? Asked to stream the first time, and false
--- for a model this build does not have (no pack: the camera is simply gone).
local function wreckReady(name)
    local hash = wreckHashes[name]
    if hash == nil then
        hash = GetHashKey(name)
        if not isTrue(IsModelInCdimage(hash)) then hash = false end
        wreckHashes[name] = hash
    end
    if not hash then return nil end
    if isTrue(HasModelLoaded(hash)) then return hash end
    if not requested[hash] then
        requested[hash] = true
        RequestModel(hash)
    end
    return nil
end

local function releaseModels()
    for hash in pairs(requested) do SetModelAsNoLongerNeeded(hash) end
    requested = {}
end

local function dropWreck(id)
    dropObject(wrecks[id])
    wrecks[id] = nil
end

--- A camera that is no longer down here (a new match, the lobby, a reset):
--- its hide, its wreck and its circle back to what an up camera has.
local function forget(id)
    downs[id] = nil
    dropWreck(id)
    push(hideQ, id)
    if showing then push(circleQ, id) end
end

--- EVERYTHING ABOUT THE MATCH GONE: on a new match id, in the lobby, off
--- Season 2, on a reset, and as br_core stops. A camera this client broke
--- itself is not repairable by script; it comes back when its map section
--- streams out, which the trip to the lobby does.
local function clearMatch()
    for id in pairs(downs) do forget(id) end
    for id in pairs(wrecks) do dropWreck(id) end
    downMatch = nil
    reported, handles, misses, fell = {}, {}, {}, {}
    releaseModels()
end

--- Take cameras as down: a hide each, its circle gone.
local function addDowns(ids, causes)
    if type(ids) ~= 'table' then return end
    causes = type(causes) == 'table' and causes or {}
    for i, raw in ipairs(ids) do
        local id = type(raw) == 'number' and math.tointeger(raw) or nil
        if id and grid.byId[id] and downs[id] == nil then
            downs[id] = causes[i] == 'vehicle' and 'vehicle' or 'weapon'
            push(hideQ, id)
            if circles[id] then push(circleQ, id) end
        end
    end
end

RegisterNetEvent(BR.Net.FLICK_DOWN)
AddEventHandler(BR.Net.FLICK_DOWN, function(d)
    if type(d) ~= 'table' or not on() then return end
    if d.reset == true then
        if downMatch ~= nil and d.matchId == downMatch then
            clearMatch()
            downMatch = d.matchId
        end
        return
    end
    if d.matchId == nil then return end
    -- A NEW MATCH'S FIRST LIST: the last match's downs go. The first list of
    -- a match this client has none for yet only names it -- what the watch
    -- reported meanwhile is this match's.
    if d.matchId ~= downMatch then
        if downMatch ~= nil then clearMatch() end
        downMatch = d.matchId
    end
    addDowns(d.ids, d.causes)
end)

-- A LATE JOINER, A RESTART: the snapshot's list replaces this one for that
-- match -- the server's own view of what this player should hold
-- (BR.Flick.viewFor). None in it, and none here.
RegisterNetEvent(BR.Net.SNAPSHOT)
AddEventHandler(BR.Net.SNAPSHOT, function(payload)
    local v = type(payload) == 'table' and payload.flick or nil
    if type(v) ~= 'table' or v.matchId == nil or not on() then
        if downMatch ~= nil or next(downs) ~= nil then clearMatch() end
        return
    end
    if v.matchId ~= downMatch then
        if downMatch ~= nil then clearMatch() end
        downMatch = v.matchId
    end
    local keep = {}
    for _, raw in ipairs(type(v.ids) == 'table' and v.ids or {}) do
        local id = type(raw) == 'number' and math.tointeger(raw) or nil
        if id then keep[id] = true end
    end
    for id in pairs(downs) do
        if not keep[id] then forget(id) end
    end
    addDowns(v.ids, v.causes)
end)

--- THE STAND-INS, ONCE A SECOND: a wreck at every down camera within
--- client.wreckM of the view, nearest first, at most client.wreckMax at once,
--- none over a copy of this client's that really fell; the rest dropped.
local function wreckPass()
    if next(downs) == nil then
        if next(wrecks) ~= nil then
            for id in pairs(wrecks) do dropWreck(id) end
        end
        return
    end
    local wreckArt = art().wreck or {}
    local p = viewpoint()
    local c = C()
    local r = c.wreckM or 300.0
    local r2 = r * r
    local near = {}
    for id, cause in pairs(downs) do
        local row = FS.row(grid, id)
        if row then
            local dx, dy = row.x - p.x, row.y - p.y
            local d2 = dx * dx + dy * dy
            if d2 <= r2 then near[#near + 1] = { id = id, d2 = d2, row = row, cause = cause } end
        end
    end
    table.sort(near, function(a, b) return a.d2 < b.d2 or (a.d2 == b.d2 and a.id < b.id) end)
    local want = {}
    for i = 1, math.min(#near, c.wreckMax or 24) do want[near[i].id] = near[i] end
    for id in pairs(wrecks) do
        if not want[id] then dropWreck(id) end
    end
    for _, w in pairs(want) do
        local id = w.id
        local own = fell[id]
        if own and not isTrue(DoesEntityExist(own)) then
            fell[id] = nil
            own = nil
        end
        local name = wreckArt[w.cause]
        if not wrecks[id] and not own and type(name) == 'string' and name ~= '' then
            local hash = wreckReady(name)
            if hash then
                local h = CreateObjectNoOffset(hash, w.row.x, w.row.y, w.row.z, false, false, false)
                if h and h ~= 0 then
                    SetEntityHeading(h, w.row.h or 0.0)
                    FreezeEntityPosition(h, (art().wreckFrozen or {})[w.cause] ~= false)
                    wrecks[id] = h
                end
            end
        end
    end
end

-- -------------------------------------------------------------- the watch ---

--- A camera near this player went down on this client's copy: who did it, as
--- this client saw it, and the one report a match.
local function reportDown(id, h, ped, veh)
    local by = 'other'
    if isTrue(HasEntityBeenDamagedByEntity(h, ped, true)) then
        by = 'me'
    elseif veh ~= 0 and GetPedInVehicleSeat(veh, -1) == ped
           and isTrue(HasEntityBeenDamagedByEntity(h, veh, true)) then
        by = 'me'
    end
    local cause = isTrue(HasEntityBeenDamagedByAnyVehicle(h)) and 'vehicle' or 'weapon'
    reported[id] = true
    handles[id] = nil
    fell[id] = h
    TriggerServerEvent(BR.Net.FLICK_REPORT, { id = id, by = by, cause = cause })
end

--- THE WATCH, ONCE A SECOND: the live, unreported cameras within client.nearM
--- of this player, each read off its own copy (BR.FlickSolve.downed). A handle
--- is found only as a camera comes into reach or its copy stops existing (it
--- streamed out), client.findsPerPass a pass at most; a row with nothing there
--- is asked again only client.findRetryMs on. A camera found up has its damage
--- record cleared, so a "me" is the damage of the last second, never a shot at
--- the pole long ago.
local function watchPass()
    if not on() or grid.n == 0 then return end
    local S = BR.State
    if not (S and S.match and S.match.state == BR.MatchState.PLAYING and S.me) then return end
    local st = S.me.state
    if st ~= BR.PlayerState.ALIVE and st ~= BR.PlayerState.DBNO then return end
    local hash = modelHash()
    if not hash then return end
    local c = C()
    local ped = PlayerPedId()
    local p = GetEntityCoords(ped)
    local now = GetGameTimer()
    local finds = c.findsPerPass or 4
    local seen, veh = {}, nil
    FS.near(grid, p.x, p.y, c.nearM or 120.0, function(row)
        local id = row.id
        if downs[id] or reported[id] then return end
        seen[id] = true
        local hc = handles[id]
        if hc and not isTrue(DoesEntityExist(hc.h)) then
            handles[id] = nil
            hc = nil
        end
        if not hc then
            if finds <= 0 or (misses[id] and now < misses[id]) then return end
            finds = finds - 1
            local h = GetClosestObjectOfType(row.x, row.y, row.z, c.findRadiusM or 2.0, hash,
                false, false, false)
            if not h or h == 0 then
                misses[id] = now + (c.findRetryMs or 5000)
                return
            end
            misses[id] = nil
            hc = { h = h }
            handles[id] = hc
        end
        local h = hc.h
        local hp = GetEntityHealth(h)
        local up = GetEntityUprightValue(h)
        if hc.max == nil then hc.max = hp end
        local probe = { broken = isTrue(HasObjectBeenBroken(h)), upright = up,
                        health = hp, maxHealth = hc.max }
        if hp ~= hc.hp or up ~= hc.up then
            local q = GetEntityCoords(h)
            probe.x, probe.y = q.x, q.y
        end
        hc.hp, hc.up = hp, up
        if FS.downed(probe, row, c) then
            if veh == nil then veh = GetVehiclePedIsIn(ped, false) end
            reportDown(id, h, ped, veh)
        else
            ClearEntityLastDamageEntity(h)
        end
    end)
    for id in pairs(handles) do
        if not seen[id] then handles[id] = nil end
    end
end

-- ----------------------------------------------------------- the coverage ---
--
-- ═══ THE SCAN SQUAD'S COVERAGE, ON THE BIG MAP ONLY ═══
--
-- Who: a client receiving TERMINAL_SCAN with `flick = true` -- the scanning
-- squad, dead and spectating members included -- in a match, on Season 2.
-- Nobody else draws anything: no camera blip and no legend entry, for anyone.
-- What: one radius blip per live camera, rangeM, in art.coverage's look; the
-- overlaps at a junction read darker, "seen from two poles". When: ONLY WHILE
-- THE BIG MAP IS UP (BR.Native.frontendMap, raised by br_ui around the frontend
-- map): built in batches as it rises, taken down as it falls, and gone when
-- the pushes stop (three of their periods, the marks' rule), in the lobby, off
-- Season 2 and on resource stop. So the radar never holds them, and playing
-- costs nothing; the map costs one burst as it opens. Not the minimap overlay
-- (client/mapoverlay.lua): it is the storm's, and an area push is the
-- expensive call #350's hitch was traced to.

local coverage = { at = 0, dev = false }
local coverageLoop = nil

--- The coverage tuner (`brflicktune`, the dev section): its name on the keys.
local TUNE = 'brflicktune'

--- A DEV PREVIEW -- `brflick coverage`, or the tuner on -- draws the coverage
--- with no Scan run. ASKED, NOT REMEMBERED: the tuner is on while its keys are,
--- so however it is put away (the command, or another tuner turned on) the
--- preview goes with it.
local function devPreview()
    return coverage.dev or (BR.TuneKeys ~= nil and BR.TuneKeys.on(TUNE))
end

local function coverageArmed()
    if not on() then return false end
    local S = BR.State
    if S and S.me and S.me.state == BR.PlayerState.LOBBY then return false end
    if devPreview() then return true end
    local fx = BR.Config.Terminals and BR.Config.Terminals.fx or {}
    return coverage.at > 0 and GetGameTimer() - coverage.at <= 3 * (fx.scanPingMs or 2000)
end

local function coveragePass()
    local armed = coverageArmed()
    local up = armed and BR.Native ~= nil and BR.Native.frontendMap == true
    if up ~= showing then
        showing = up
        syncCircles()
    end
    -- A DEV PREVIEW KEEPS ITS CALLBACK through the lobby and a season move:
    -- nothing would arm it again on the way out (a Scan push arms its own).
    if not armed and not devPreview() and next(circles) == nil and circleQ.head > circleQ.tail then
        BR.Loop.unregister(coverageLoop)
        coverageLoop = nil
    end
end

local function armCoverage()
    if coverageLoop == nil then
        coverageLoop = BR.Loop.register(BR.Loop.TICK, 'flick.coverage', coveragePass)
    end
end

RegisterNetEvent(BR.Net.TERMINAL_SCAN)
AddEventHandler(BR.Net.TERMINAL_SCAN, function(d)
    if type(d) ~= 'table' or d.flick ~= true or not on() then return end
    coverage.at = GetGameTimer()
    armCoverage()
end)

-- ----------------------------------------------------------- the season ---

--- The season moved (or this client first learned it): Season 1 hides every
--- camera and forgets the match; Season 2 lifts the hides of every camera
--- that is up.
local function onSeason()
    if not on() then
        clearMatch()
        coverage.at, coverage.dev = 0, false
    end
    syncHides()
end

-- ON START, and on every move of this client's season.
onSeason()
if BR.Season and BR.Season.onChange then
    BR.Season.onChange(function()
        refreshSeason()
        onSeason()
    end)
end

-- ONCE A SECOND: the season (a move the latch did not announce brings the
-- hides with it), the lobby and Season 1 forgetting the match, the wrecks
-- near the view, and the watch.
BR.Loop.register(BR.Loop.SLOW, 'flick.watch', function()
    refreshSeason()
    if hidesFor ~= on() and seasonKnown() then onSeason() end
    local S = BR.State
    local lobby = S and S.me and S.me.state == BR.PlayerState.LOBBY
    if lobby and (downMatch ~= nil or next(reported) ~= nil) then clearMatch() end
    wreckPass()
    watchPass()
end)

-- br_core stopping: every hide lifted, every wreck and circle gone, NOW --
-- nothing queued survives the resource.
AddEventHandler('onResourceStop', function(name)
    if name ~= GetCurrentResourceName() then return end
    for id, h in pairs(hidden) do
        RemoveModelHide(h.x, h.y, h.z, h.r, h.hash, false)
        hidden[id] = nil
    end
    for id in pairs(wrecks) do dropWreck(id) end
    for id, b in pairs(circles) do
        removeBlip(b)
        circles[id] = nil
    end
    releaseModels()
end)

-- ------------------------------------------------------------ the suites ---

--- What this client holds, for the suites and `brflick hides`.
--- @return table { downs, reported, hidden, wrecks, circles, queued }
function F.counts()
    return {
        downs = count(downs), reported = count(reported), hidden = count(hidden),
        wrecks = count(wrecks), circles = count(circles),
        queued = (hideQ.tail - hideQ.head + 1) + (circleQ.tail - circleQ.head + 1),
        match = downMatch,
    }
end

-- -------------------------------------------------------------- the dev ---
--
--   brflick [list]          the server's list (`brflicksv list`)
--   brflick near            the nearest camera: its id, how far, up or down,
--                           and what this client reads off its copy -- the
--                           tool for docs/flick.md's engine questions
--   brflick down <id|near>  down it through the server's decision: nobody
--                           credited, nothing paid
--   brflick reset           every camera in your match up again
--   brflick coverage [off]  your big map's coverage without running Scan
--   brflick hides           the model hides this client holds

RegisterNetEvent(BR.Net.FLICK_DEV)
AddEventHandler(BR.Net.FLICK_DEV, function(text)
    print('[br_core] brflick: ' .. tostring(text))
end)

--- The camera nearest a point, and how far, flat; nil with none within 3 km.
local function nearest(x, y)
    local best, bestD = nil, nil
    FS.near(grid, x, y, 3000.0, function(row, d2)
        if bestD == nil or d2 < bestD then best, bestD = row, d2 end
    end)
    return best, bestD and math.sqrt(bestD) or nil
end

local function devNear()
    local ped = PlayerPedId()
    local p = GetEntityCoords(ped)
    local row, d = nearest(p.x, p.y)
    if not row then
        print('[br_core] brflick: no camera within 3 km')
        return
    end
    local hash = modelHash()
    local h = hash and GetClosestObjectOfType(row.x, row.y, row.z, C().findRadiusM or 2.0, hash,
        false, false, false) or 0
    local probe = 'no handle found'
    if h and h ~= 0 then
        local q = GetEntityCoords(h)
        probe = ('handle %d, health %d, broken %s, upright %.3f, moved %.2f m, damaged by you %s, '
            .. 'by a vehicle %s'):format(h, GetEntityHealth(h), tostring(isTrue(HasObjectBeenBroken(h))),
            GetEntityUprightValue(h), math.sqrt((q.x - row.x) ^ 2 + (q.y - row.y) ^ 2),
            tostring(isTrue(HasEntityBeenDamagedByEntity(h, ped, true))),
            tostring(isTrue(HasEntityBeenDamagedByAnyVehicle(h))))
    end
    print(('[br_core] brflick: camera %d (%s) %.1f m away, %s here%s; %s'):format(row.id,
        tostring(row.region), d, downs[row.id] and ('down, ' .. downs[row.id]) or 'up',
        reported[row.id] and ', reported' or '', probe))
end

RegisterCommand('brflick', function(_, args)
    args = args or {}
    local verb = args[1] and args[1]:lower() or 'list'
    if verb == 'near' then
        devNear()
    elseif verb == 'hides' then
        local k = F.counts()
        print(('[br_core] brflick: %d model hides held (%s), %d down, %d wrecks, %d circles, %d queued')
            :format(k.hidden, hidesFor == false and 'Season 1: every camera' or 'the downs',
                k.downs, k.wrecks, k.circles, k.queued))
    elseif verb == 'coverage' then
        coverage.dev = not (args[2] and args[2]:lower() == 'off')
        if coverage.dev then armCoverage() end
        print(('[br_core] brflick: coverage %s'):format(coverage.dev
            and 'on (open the big map)' or 'off unless Scan says so'))
    elseif verb == 'down' and args[2] and args[2]:lower() == 'near' then
        local p = GetEntityCoords(PlayerPedId())
        local row = nearest(p.x, p.y)
        if row then
            ExecuteCommand(('brflicksv down %d'):format(row.id))
        else
            print('[br_core] brflick: no camera within 3 km')
        end
    elseif verb == 'down' then
        ExecuteCommand(('brflicksv down %s'):format(tostring(args[2] or '')))
    elseif verb == 'list' or verb == 'reset' then
        ExecuteCommand('brflicksv ' .. verb)
    else
        print('[br_core] brflick: brflick [list] | near | down <id|near> | reset | coverage [off] | hides')
    end
end)

-- ------------------------------------------------------------ the tuner ---
--
-- ═══ brflicktune: THE COVERAGE'S LOOK ON THE KEYS ═══
--
-- "the circles should be barely visible. give me an in-game adjuster and i'll
-- tell you what looks good" (owner, 2026-10-18). The shape every tuner shares
-- (#404, client/tunekeys.lua): the command turns it on, the keys move the look,
-- and the command again puts it away and prints the config line to paste.
--
--   brflicktune [on|off]   bare, it turns the tuner on or off
--
-- While it is on, the big map shows a circle for every live camera with no
-- Scan run (devPreview, as `brflick coverage`), and the keys move the look of
-- every circle at once:
--
--   LEFT / RIGHT   the blip color, once a press, round GTA's palette (0-85)
--   UP / DOWN      the alpha, 1 a step, 0-255
--   hold SHIFT     10 a step, for either
--   DELETE         the shipped look
--
-- THE LOOK IS WRITTEN INTO art.coverage ITSELF, as /brshine writes its numbers
-- into the loot config, so a circle made later -- the map opened again -- is
-- made in it, and the circles already up are restyled in place: two setters a
-- circle, no blip made again (a radius blip is the expensive call; its color
-- and alpha are not). Client-local: a restart puts the config's look back.

--- GTA's blip palette: SET_BLIP_COLOUR takes 0..85, and the keys go round it.
local PALETTE = 86
--- The alpha's step: 1, and 10 with SHIFT.
local ALPHA_STEP = { fine = 1, coarse = 10, places = 0, lo = 0, hi = 255 }
--- What the config shipped, for DELETE: the tuner writes the config table.
local SHIPPED = {}
SHIPPED.color, SHIPPED.alpha = coverageLook()

--- Every circle up brought to the look, in place.
local function restyle()
    local color, alpha = coverageLook()
    for _, b in pairs(circles) do
        SetBlipColour(b, color)
        SetBlipAlpha(b, alpha)
    end
end

--- Set the look, live: the config's table, then every circle up.
local function setLook(color, alpha)
    local a = cfg()
    a.art = a.art or {}
    a.art.coverage = a.art.coverage or {}
    a.art.coverage.colour, a.art.coverage.alpha = color, alpha
    restyle()
end

--- The look, and the line for br_lib/config/flick.lua.
local function tuneReport()
    local color, alpha = coverageLook()
    print(('[br_core] brflicktune: color %d, alpha %d'):format(color, alpha))
    print('  paste into br_lib/config/flick.lua:')
    print(('    coverage = { colour = %d, alpha = %d },'):format(color, alpha))
end

local function tuneOn()
    if not on() then
        print('[br_core] brflicktune: Flick is Season 2 (brseason 2 first)')
        return
    end
    BR.TuneKeys.start(TUNE, {
        lines = function(k)
            local color, alpha = coverageLook()
            return {
                '~b~flick coverage~w~',
                ('color %d'):format(color),
                ('alpha %d'):format(alpha),
                ('step %d'):format(k.coarse and ALPHA_STEP.coarse or ALPHA_STEP.fine),
            }
        end,
        pick = function(d)
            local color, alpha = coverageLook()
            local n = BR.TuneKeys.held(BR.TuneKeys.KEY.COARSE) and ALPHA_STEP.coarse or ALPHA_STEP.fine
            setLook(math.floor(color + d * n) % PALETTE, alpha)
        end,
        nudge = function(k)
            if k.v == 0 then return false end
            local color, alpha = coverageLook()
            setLook(color, BR.TuneKeys.nudged(alpha, k.v, k.coarse, ALPHA_STEP))
            return true
        end,
        reset = function() setLook(SHIPPED.color, SHIPPED.alpha) end,
        off = tuneReport,
    })
    armCoverage()
    print('[br_core] brflicktune: on. Open the big map. The keys:')
    print('  LEFT / RIGHT   the color')
    print('  UP / DOWN      the alpha')
    print('  hold SHIFT     10 a step')
    print('  DELETE         the shipped look')
    print('  `brflicktune` again puts them away and prints what to paste')
end

RegisterCommand(TUNE, function(_, args)
    local word = args and args[1] and tostring(args[1]):lower() or ''
    if word == 'off' or (word ~= 'on' and BR.TuneKeys.on(TUNE)) then
        if not BR.TuneKeys.stop(TUNE) then tuneReport() end
        return
    end
    tuneOn()
end)
