-- Season 2 terminals (#396), round 5: VEHICLE DROP, the client half. The
-- server half is server/terminalfx/vehicle_drop.lua, and it decides
-- everything: whether it runs, where it lands (it checks what this file finds
-- against its own samples), when, and whose map shows it. This file does the
-- three things only a client can:
--
--   LOOK        TERMINAL_DROP_FIND: on the client of the player it is for,
--               find a road node -- or, failing one, flat open ground -- within
--               `r` of this player, at least `minM` from them, out of the
--               water, under open sky (so never inside a building or under a
--               bridge) and with nobody and nothing standing on it, and send it
--               (TERMINAL_DROP_SPOT) every `everyMs` until told to stop. The
--               player moves while the run loads, so the spot is found again
--               each time.
--   THE DESCENT TERMINAL_DROP: every client within fx.dropDrawM of it draws a
--               copy of the car coming down under the airdrop's own cargo
--               chute, on the airdrop's own fall curve (BR.AirdropCrateZ with
--               BR.Config.Airdrop's flare), and hides the real car -- built by
--               the server where it lands, frozen -- until the copy touches
--               down. Local, never networked, no collision, moved only by
--               arithmetic, like every airdrop part (client/airdrop.lua).
--   THE BLIP    on the squad's maps (`blip`), moved when the server moves it,
--               gone when the server says (a squadmate got in, the car is
--               wrecked or gone, the match is over), in the lobby, off Season
--               2 and as br_core stops.
--
-- ═══ WHAT IT COSTS ═══
--
-- Nothing per frame but the descent itself: a FRAME callback registered when a
-- copy starts coming down within draw distance and unregistered when the last
-- one lands (about nine seconds). The search runs on a thread of its own, once
-- a second, only on the one client asked and only while asked. The SLOW hook
-- returns at once with nothing up.

BR = BR or {}
BR.TerminalFx = BR.TerminalFx or {}

local F = BR.TerminalFx

--- A FiveM BOOL native may answer 1/0, and 0 is truthy in Lua.
local isTrue = BR.NativeTruthy

local function fx() return BR.Config.Terminals.fx or {} end
local function art() return BR.Config.Terminals.art or {} end
local function copy() return BR.Config.Terminals.copy end

--- Ground at least this flat takes a car: the up component of the ground's
--- normal, about 20 degrees of slope.
local FLAT = 0.94
--- The clear sky the descent needs above the spot, in meters: a roof, a
--- bridge, a tree or an awning inside it is not open ground.
local SKY_M = 60.0
--- Nothing and nobody within this of the spot, in meters.
local CLEAR_M = 3.5
--- The road nodes asked for, nearest first.
local ROAD_TRIES = 16
--- The rings of open ground tried when no road node will do: radii as
--- fractions of the reach, and points on each.
local RINGS = { 0.3, 0.5, 0.7, 0.9 }
local RING_POINTS = 8
--- How far above or below the player a road node, and open ground, may be,
--- in meters: never an overpass over their head or a roof beside them.
local ROAD_RISE_M = 10.0
local RING_RISE_M = 6.0

-- ------------------------------------------------------------- the look ---

--- Will a car stand on (x, y), around height z? Its ground height, or nil.
--- Out of the water (sea level is zero on this map; GetWaterHeight for the
--- lakes), flat, under open sky, and with nobody and nothing on it.
--- @return number|nil gz
local function standOn(x, y, z)
    local found, gz, normal = GetGroundZAndNormalFor_3dCoord(x, y, z + 2.0)
    if not isTrue(found) or type(gz) ~= 'number' or gz <= 0.0 then return nil end
    if math.abs(gz - z) > 2.5 then return nil end
    -- The normal is a vector3; a build that answers none is not refused for it.
    local nz = (normal ~= nil and type(normal) ~= 'number') and tonumber(normal.z) or nil
    if nz and nz < FLAT then return nil end
    local okW, wz = GetWaterHeight(x, y, gz + 2.0)
    if isTrue(okW) and type(wz) == 'number' and wz > gz - 0.5 then return nil end
    local ray = StartExpensiveSynchronousShapeTestLosProbe(x, y, gz + SKY_M, x, y, gz + 1.0,
        1 + 16, 0, 7)
    local _, hit = GetShapeTestResult(ray)
    if isTrue(hit) then return nil end
    if isTrue(IsPositionOccupied(x, y, gz + 1.0, CLEAR_M, false, true, true, false, false, 0, false)) then
        return nil
    end
    return gz
end

--- WHERE THE CAR CAN COME DOWN, near (px, py, pz): a road node first -- the
--- nearest that is at least `minM` and at most `r` away and passes standOn --
--- then flat open ground on rings around the player, nearest ring first. Nil
--- when nothing within `r` will do.
--- @return table|nil { x, y, z, h }
function F.dropSpot(px, py, pz, r, minM)
    r, minM = tonumber(r) or 40.0, tonumber(minM) or 6.0
    local reach = r - 2.0
    for i = 1, ROAD_TRIES do
        local found, pos, heading = GetNthClosestVehicleNodeWithHeading(px, py, pz, i, 1, 3.0, 0)
        if isTrue(found) and pos then
            local dx, dy = pos.x - px, pos.y - py
            local d2 = dx * dx + dy * dy
            if d2 > reach * reach then break end
            if d2 >= minM * minM and math.abs((tonumber(pos.z) or pz) - pz) <= ROAD_RISE_M then
                local gz = standOn(pos.x, pos.y, pos.z)
                if gz then
                    return { x = pos.x + 0.0, y = pos.y + 0.0, z = gz + 0.0, h = (tonumber(heading) or 0.0) + 0.0 }
                end
            end
        end
    end
    for _, k in ipairs(RINGS) do
        local rad = math.max(minM, reach * k)
        for j = 0, RING_POINTS - 1 do
            local a = (j / RING_POINTS) * 2.0 * math.pi
            local x, y = px + math.sin(a) * rad, py + math.cos(a) * rad
            local ok, gz = GetGroundZFor_3dCoord(x, y, pz + 30.0, false)
            if isTrue(ok) and type(gz) == 'number' and math.abs(gz - pz) <= RING_RISE_M then
                local z = standOn(x, y, gz)
                if z then
                    -- SIDE ON TO THE PLAYER, so a door faces them (brcar's
                    -- turn): GTA's forward is (-sin h, cos h), so facing them
                    -- is atan2(-dx, dy), and a quarter turn off it.
                    local h = (math.deg(math.atan(-(px - x), py - y)) + 90.0) % 360.0
                    return { x = x + 0.0, y = y + 0.0, z = z + 0.0, h = h }
                end
            end
        end
    end
    return nil
end

--- The search this client was asked for, or nil: { nonce, r, minM, everyMs, untilAt }.
local search = nil

--- One answer: the best spot near this player now, or `none`.
local function answer(s)
    local ped = PlayerPedId()
    local p = GetEntityCoords(ped)
    local spot = p and F.dropSpot(p.x, p.y, p.z, s.r, s.minM) or nil
    if spot then
        TriggerServerEvent(BR.Net.TERMINAL_DROP_SPOT,
            { nonce = s.nonce, x = spot.x, y = spot.y, z = spot.z, h = spot.h })
    else
        TriggerServerEvent(BR.Net.TERMINAL_DROP_SPOT, { nonce = s.nonce, none = true })
    end
end

--- Is a search running? For the suites.
--- @return boolean
function F.dropSearching()
    return search ~= nil
end

RegisterNetEvent(BR.Net.TERMINAL_DROP_FIND)
AddEventHandler(BR.Net.TERMINAL_DROP_FIND, function(d)
    if type(d) ~= 'table' then return end
    if d.stop == true then
        if search and search.nonce == d.nonce then search = nil end
        return
    end
    if not F.on() then return end
    local every = math.max(250, math.min(5000, math.floor(tonumber(d.everyMs) or 1000)))
    local forMs = math.max(0, math.min(15000, math.floor(tonumber(d.forMs) or 8000)))
    local mine = { nonce = d.nonce, r = tonumber(d.r) or 40.0, minM = tonumber(d.minM) or 6.0,
                   everyMs = every, untilAt = GetGameTimer() + forMs }
    search = mine
    Citizen.CreateThread(function()
        while search == mine and GetGameTimer() < mine.untilAt do
            answer(mine)
            Citizen.Wait(mine.everyMs)
        end
        if search == mine then search = nil end
    end)
end)

-- ------------------------------------------------------- the descent ---

--- The drops this client knows: [id] = { id, matchId, mark?, rec?, veh?,
--- chute?, netId, x, y, z, h, loading? }.
local drops = {}

--- The FRAME callback while a copy comes down, and a counter for its name.
local loopHandle, loopSeq = nil, 0

local function removeEnt(e)
    if e and e ~= 0 and isTrue(DoesEntityExist(e)) then DeleteEntity(e) end
end

--- The copy and its canopy gone (the real car shows from the next frame).
local function endFall(d)
    removeEnt(d.veh)
    removeEnt(d.chute)
    d.veh, d.chute, d.rec = nil, nil, nil
end

local function dropAll(d)
    endFall(d)
    if d.mark then F.dropMark(d.mark) end
    d.mark = nil
    drops[d.id] = nil
end

--- How many drops this client knows, with a blip and coming down. For the suites.
--- @return integer blips, integer falling
function F.dropCounts()
    local b, f = 0, 0
    for _, d in pairs(drops) do
        if d.mark then b = b + 1 end
        if d.rec then f = f + 1 end
    end
    return b, f
end

--- The copy, where the fall curve has it now, and the real car hidden.
local function place(d, now)
    local s = art().drop or {}
    local z = BR.AirdropCrateZ(d.rec, now, d.rec.gz, BR.Config.Airdrop)
    if d.veh then
        SetEntityCoords(d.veh, d.x, d.y, z, false, false, false, false)
        SetEntityHeading(d.veh, d.h)
    end
    if d.chute then
        SetEntityCoords(d.chute, d.x, d.y, z + (s.chuteRiseM or 1.2), false, false, false, false)
        SetEntityHeading(d.chute, d.h)
        BR.Native.propScale(d.chute, s.chuteScale or 3.0)
    end
    if d.netId and isTrue(NetworkDoesNetworkIdExist(d.netId)) then
        local real = NetToVeh(d.netId)
        if real and real ~= 0 then SetEntityLocallyInvisible(real) end
    end
end

local function stepFall()
    local now = BR.Clock.now()
    local any = false
    for _, d in pairs(drops) do
        if d.rec then
            if now >= d.rec.tLand then
                endFall(d)
                -- A drop whose blip already went is done with altogether.
                if not d.mark then drops[d.id] = nil end
            else
                any = true
                place(d, now)
            end
        end
    end
    if not any and loopHandle then
        BR.Loop.unregister(loopHandle)
        loopHandle = nil
    end
end

local function ensureLoop()
    if loopHandle then return end
    loopSeq = loopSeq + 1
    loopHandle = BR.Loop.register(BR.Loop.FRAME, 'terminalfx.vdrop#' .. loopSeq, stepFall)
end

--- Stream a model, bounded.
local function loadModel(hash)
    if not isTrue(IsModelValid(hash)) then return false end
    RequestModel(hash)
    local waited = 0
    while not isTrue(HasModelLoaded(hash)) and waited < 5000 do
        Citizen.Wait(50)
        waited = waited + 50
    end
    return isTrue(HasModelLoaded(hash))
end

--- Build the copy and its canopy, then let the FRAME callback carry them down.
local function startFall(d)
    d.loading = true
    Citizen.CreateThread(function()
        local A = BR.Config.Airdrop or {}
        local carHash = GetHashKey(fx().dropModel or 'kuruma2')
        local chuteHash = GetHashKey(A.chuteModel or 'p_cargo_chute_s')
        local okCar, okChute = loadModel(carHash), loadModel(chuteHash)
        local dict = A.chuteAnimDict
        if dict and A.chuteAnim then
            RequestAnimDict(dict)
            local waited = 0
            while not isTrue(HasAnimDictLoaded(dict)) and waited < 3000 do
                Citizen.Wait(50)
                waited = waited + 50
            end
        end
        d.loading = false
        -- GONE, OR LANDED, WHILE IT STREAMED: nothing to draw.
        if drops[d.id] ~= d or not d.rec or BR.Clock.now() >= d.rec.tLand or not okCar then return end
        local top = d.z + d.rec.alt
        -- LOCAL. NEVER NETWORKED (client/shop.lua's showroom, client/bus.lua).
        local veh = CreateVehicle(carHash, d.x, d.y, top, d.h, false, false)
        if veh and veh ~= 0 and isTrue(DoesEntityExist(veh)) then
            SetEntityCollision(veh, false, false)
            FreezeEntityPosition(veh, true)
            SetEntityInvincible(veh, true)
            SetVehicleDoorsLocked(veh, 2)
            d.veh = veh
        end
        SetModelAsNoLongerNeeded(carHash)
        if okChute then
            local chute = CreateObjectNoOffset(chuteHash, d.x, d.y, top, false, false, false)
            if chute and chute ~= 0 then
                SetEntityCollision(chute, false, false)
                FreezeEntityPosition(chute, true)
                if dict and A.chuteAnim and isTrue(HasAnimDictLoaded(dict)) then
                    PlayEntityAnim(chute, A.chuteAnim, dict, 1000.0, false, false, false, 0.0, 0)
                end
                d.chute = chute
            end
        end
        ensureLoop()
    end)
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

RegisterNetEvent(BR.Net.TERMINAL_DROP)
AddEventHandler(BR.Net.TERMINAL_DROP, function(d)
    if type(d) ~= 'table' or not F.on() then return end
    local id = math.tointeger(d.id)
    if not id then return end
    local TS = BR.TerminalSolve
    local known = drops[id]
    -- TAKEN OFF: a squadmate got in, it was wrecked or is gone, or the match
    -- is over. The copy, if one is still coming down, lands on its own clock.
    if d.off == true then
        if known and known.mark then
            F.dropMark(known.mark)
            known.mark = nil
        end
        if known and not known.rec then drops[id] = nil end
        return
    end
    if not (TS.finite(d.x) and TS.finite(d.y)) then return end
    -- MOVED: the car is not where it landed any more.
    if known and d.netId == nil then
        if known.mark then
            SetBlipCoords(known.mark.big, d.x + 0.0, d.y + 0.0, 0.0)
            SetBlipCoords(known.mark.mini, d.x + 0.0, d.y + 0.0, 0.0)
        end
        return
    end
    if known then dropAll(known) end
    local rec = {
        id = id, matchId = d.matchId, netId = math.tointeger(d.netId),
        x = d.x + 0.0, y = d.y + 0.0, z = TS.finite(d.z) and d.z + 0.0 or 0.0,
        h = TS.finite(d.h) and d.h + 0.0 or 0.0,
    }
    drops[id] = rec
    if d.blip == true then
        local look = art().drop or {}
        rec.mark = F.newMark(rec.x, rec.y, look, nil, copy().vehicle_drop_blip)
    end
    -- THE DESCENT, if it is still coming down and this client can see it.
    local now = BR.Clock.now()
    if TS.finite(d.tLand) and TS.finite(d.tRelease) and now < d.tLand then
        local p = viewpoint()
        local reach = tonumber(fx().dropDrawM) or 600.0
        local dx, dy = p and (p.x - rec.x) or 0.0, p and (p.y - rec.y) or 0.0
        if p and dx * dx + dy * dy <= reach * reach then
            rec.rec = { gz = rec.z, alt = tonumber(d.alt) or tonumber(fx().dropAltM) or 120.0,
                        tStart = d.tRelease, tRelease = d.tRelease, tLand = d.tLand,
                        x = rec.x, y = rec.y }
            startFall(rec)
        end
    end
    -- ANOTHER SQUAD'S, OUT OF SIGHT OR LANDED: nothing to keep.
    if not rec.mark and not rec.rec then drops[id] = nil end
end)

-- ONCE A SECOND, on client/terminalfx.lua's one SLOW pass: in the lobby or
-- off Season 2, every blip and copy goes (the server's own word is on its way
-- too). Nothing with nothing up.
F.onSlow(function()
    if next(drops) == nil and search == nil then return end
    local S = BR.State
    local lobby = S and S.me and S.me.state == BR.PlayerState.LOBBY
    if lobby or not F.on() then
        search = nil
        for _, d in pairs(drops) do dropAll(d) end
        if loopHandle then
            BR.Loop.unregister(loopHandle)
            loopHandle = nil
        end
    end
end)

AddEventHandler('onResourceStop', function(name)
    if name ~= GetCurrentResourceName() then return end
    for _, d in pairs(drops) do dropAll(d) end
end)
