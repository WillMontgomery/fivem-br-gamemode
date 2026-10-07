-- Season 2 terminals (#396), round 5: AIRSTRIKE, the client half. The server
-- half is server/terminalfx/airstrike.lua, and it decides everything: where the
-- rockets land and when, who is hurt and how much, which vehicle is wrecked.
-- This file DRAWS, and does one write the server asks of it:
--
--   THE PICK     TERMINAL_FUZZ: the rough circles, one per opponent, while
--                this player picks the spot on the big map -- radius blips,
--                moved with each push, gone when the list empties or the pick
--                ends here (BR.Terminal.picking, client/terminal.lua).
--   THE WARNING  TERMINAL_STRIKE: the circle on this player's map until just
--                after the last rocket, and -- within fx.strikeDrawM of it --
--                a red flare at the spot (BR.Flare.fire, the airdrop's own:
--                a flare whose relay the server already refuses) and the
--                streams the rockets need, asked for at once.
--   THE ROCKETS  each a LOCAL object (the RPG's rocket model) with the RPG's
--                trail, falling on a slant onto its point over art.rocket's
--                fallMs, and where it lands a fireball and the game's cheap
--                explosion sound, and a camera shake for a player near it.
--                PARTICLES AND A SOUND, NEVER AddExplosion OR A PROJECTILE: a
--                scripted explosion is networked, hurts whatever it touches on
--                this machine and is judged by the server's explosion checks;
--                these hurt nothing and send nothing.
--   A VEHICLE    TERMINAL_STRIKE_VEH, to the client that owns a vehicle a
--                rocket hit: its engine and body health lowered by the
--                server's figure, or the vehicle wrecked -- the owner writes a
--                vehicle's health, and the wreck goes up as any wreck does.
--
-- ═══ WHAT IT COSTS ═══
--
-- Nothing per frame but the rockets: a FRAME callback registered a moment
-- before the first one starts falling within draw distance and unregistered
-- when the last has landed (about five seconds). The circles move on the
-- server's pushes; the SLOW hook returns at once with nothing up.

BR = BR or {}
BR.TerminalFx = BR.TerminalFx or {}

local F = BR.TerminalFx

--- A FiveM BOOL native may answer 1/0, and 0 is truthy in Lua.
local isTrue = BR.NativeTruthy

local function fx() return BR.Config.Terminals.fx or {} end
local function art() return BR.Config.Terminals.art or {} end
local function copy() return BR.Config.Terminals.copy end

local function removeBlip(b)
    if b and isTrue(DoesBlipExist(b)) then RemoveBlip(b) end
end

--- A radius blip on both maps, in a look.
local function circle(x, y, r, look, name)
    local b = AddBlipForRadius(x, y, 0.0, r)
    SetBlipColour(b, look.colour or 1)
    SetBlipAlpha(b, look.alpha or 100)
    SetBlipHighDetail(b, true)
    if name then BR.Native.blipName(b, name) end
    return b
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

-- ------------------------------------------------------------ the pick ---

--- The rough circles up: [s] = blip.
local fuzz = {}

local function clearFuzz()
    for s, b in pairs(fuzz) do
        removeBlip(b)
        fuzz[s] = nil
    end
end

--- How many rough circles are up. For the suites.
--- @return integer
function F.fuzzCount()
    local n = 0
    for _ in pairs(fuzz) do n = n + 1 end
    return n
end

RegisterNetEvent(BR.Net.TERMINAL_FUZZ)
AddEventHandler(BR.Net.TERMINAL_FUZZ, function(d)
    if type(d) ~= 'table' then return end
    if not F.on() then
        clearFuzz()
        return
    end
    local TS = BR.TerminalSolve
    local look = art().fuzz or {}
    local seen = {}
    for _, p in ipairs(type(d.list) == 'table' and d.list or {}) do
        local s = math.tointeger(p.s)
        if s and TS.finite(p.x) and TS.finite(p.y) and TS.finite(p.r) and p.r > 0 then
            seen[s] = true
            local b = fuzz[s]
            if b and isTrue(DoesBlipExist(b)) then
                SetBlipCoords(b, p.x + 0.0, p.y + 0.0, 0.0)
            else
                fuzz[s] = circle(p.x + 0.0, p.y + 0.0, p.r + 0.0, look, copy().airstrike_fuzz_blip)
            end
        end
    end
    for s, b in pairs(fuzz) do
        if not seen[s] then
            removeBlip(b)
            fuzz[s] = nil
        end
    end
end)

-- ---------------------------------------------------------- the strike ---

--- The strikes this client knows: [id] = { id, x, y, r, startsAt, endsAt,
--- rockets = { { x, y, at, gz?, obj?, trail?, done? } }, ring, near, dir }.
local strikes = {}

--- The FRAME callback while rockets fall, and a counter for its name.
local loopHandle, loopSeq = nil, 0

local function rocketArt() return art().rocket or {} end

local function removeEnt(e)
    if e and e ~= 0 and isTrue(DoesEntityExist(e)) then DeleteEntity(e) end
end

local function dropRocket(rk)
    if rk.trail then
        StopParticleFxLooped(rk.trail, false)
        rk.trail = nil
    end
    removeEnt(rk.obj)
    rk.obj = nil
end

local function dropStrike(s)
    for _, rk in ipairs(s.rockets) do dropRocket(rk) end
    removeBlip(s.ring)
    s.ring = nil
    strikes[s.id] = nil
end

--- How many strikes this client shows, and rockets in the air. For the suites.
--- @return integer strikes, integer falling
function F.strikeCounts()
    local a, b = 0, 0
    for _, s in pairs(strikes) do
        a = a + 1
        for _, rk in ipairs(s.rockets) do
            if rk.obj then b = b + 1 end
        end
    end
    return a, b
end

--- Where a rocket is `t` (0..1) of the way down its slant.
local function along(s, rk, t)
    local R = rocketArt()
    local fall, slant = tonumber(R.fallM) or 150.0, tonumber(R.slantM) or 25.0
    local sx, sy = rk.x + s.dir.x * slant, rk.y + s.dir.y * slant
    local sz = rk.gz + fall
    return sx + (rk.x - sx) * t, sy + (rk.y - sy) * t, sz + (rk.gz - sz) * t
end

--- One rocket lands, as this client sees it: particles, a sound, a shake.
local function land(s, rk, view)
    dropRocket(rk)
    rk.done = true
    local R = rocketArt()
    local z = rk.gz or s.gz or 0.0
    if R.blastAsset and R.blast and isTrue(HasNamedPtfxAssetLoaded(R.blastAsset)) then
        UseParticleFxAsset(R.blastAsset)
        StartParticleFxNonLoopedAtCoord(R.blast, rk.x, rk.y, z, 0.0, 0.0, 0.0,
            tonumber(R.blastScale) or 1.0, false, false, false)
    end
    if R.sound then PlaySoundFromCoord(-1, R.sound, rk.x, rk.y, z, 0, false, 0, false) end
    if R.shake and view then
        local dx, dy = view.x - rk.x, view.y - rk.y
        local d = math.sqrt(dx * dx + dy * dy)
        local within = tonumber(R.shakeM) or 60.0
        if d < within then ShakeGameplayCam(R.shake, 0.6 * (1.0 - d / within)) end
    end
end

--- A rocket in the air: made on its first frame, moved on every one after.
local function fly(s, rk, now)
    local R = rocketArt()
    local fallMs = tonumber(R.fallMs) or 1200
    local t = (now - (rk.at - fallMs)) / fallMs
    if t < 0.0 then t = 0.0 end
    local x, y, z = along(s, rk, t)
    if not rk.obj then
        local model = GetHashKey(R.model or 'w_lr_rpg_rocket')
        if not isTrue(HasModelLoaded(model)) then return end
        local obj = CreateObjectNoOffset(model, x, y, z, false, false, false)
        if not obj or obj == 0 then return end
        SetEntityCollision(obj, false, false)
        FreezeEntityPosition(obj, true)
        -- NOSE DOWN ITS SLANT: GTA's forward is (-sin h, cos h), and the
        -- rocket's pitch is the slant's.
        local dx, dy = -s.dir.x, -s.dir.y
        local pitch = -math.deg(math.atan(tonumber(R.fallM) or 150.0, tonumber(R.slantM) or 25.0))
        SetEntityRotation(obj, pitch, 0.0, math.deg(math.atan(-dx, dy)), 2, true)
        rk.obj = obj
        if R.trailAsset and R.trail and isTrue(HasNamedPtfxAssetLoaded(R.trailAsset)) then
            UseParticleFxAsset(R.trailAsset)
            rk.trail = StartParticleFxLoopedOnEntity(R.trail, obj, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                1.0, false, false, false)
        end
    end
    SetEntityCoords(rk.obj, x, y, z, false, false, false, false)
end

local function stepRockets()
    local now = BR.Clock.now()
    local view = nil
    local pending = false
    local fallMs = tonumber(rocketArt().fallMs) or 1200
    for _, s in pairs(strikes) do
        if s.near then
            for _, rk in ipairs(s.rockets) do
                if not rk.done then
                    if now >= rk.at then
                        view = view or viewpoint()
                        land(s, rk, view)
                    else
                        pending = true
                        if now >= rk.at - fallMs and rk.gz then fly(s, rk, now) end
                    end
                end
            end
        end
    end
    if not pending and loopHandle then
        BR.Loop.unregister(loopHandle)
        loopHandle = nil
    end
end

local function ensureLoop()
    if loopHandle then return end
    loopSeq = loopSeq + 1
    loopHandle = BR.Loop.register(BR.Loop.FRAME, 'terminalfx.strike#' .. loopSeq, stepRockets)
end

--- Is the FRAME callback up? For the suites.
--- @return boolean
function F.strikeLoop()
    return loopHandle ~= nil
end

--- The ground under (x, y), from high up: the roof or the street a rocket
--- falling there meets first.
local function groundAt(x, y, fallback)
    local found, gz = GetGroundZFor_3dCoord(x, y, 1000.0, false)
    if isTrue(found) and type(gz) == 'number' then return gz end
    return fallback
end

--- Within draw distance: the flare, the streams, every rocket's ground, and
--- the FRAME callback a moment before the first one falls.
local function prepare(s)
    Citizen.CreateThread(function()
        local R = rocketArt()
        local gz = groundAt(s.x, s.y, nil)
        if gz == nil then
            local p = viewpoint()
            gz = p and p.z or 0.0
        end
        s.gz = gz
        -- THE FLARE ON A THREAD OF ITS OWN: lighting one streams the flare's
        -- weapon asset first (client/flares.lua, up to five seconds), and the
        -- rockets must not wait on it.
        if BR.Flare and BR.Flare.fire and BR.Clock.now() < s.startsAt then
            Citizen.CreateThread(function() BR.Flare.fire(s.x, s.y, gz + 0.1) end)
        end
        RequestModel(GetHashKey(R.model or 'w_lr_rpg_rocket'))
        if R.trailAsset then RequestNamedPtfxAsset(R.trailAsset) end
        if R.blastAsset and R.blastAsset ~= R.trailAsset then RequestNamedPtfxAsset(R.blastAsset) end
        for _, rk in ipairs(s.rockets) do rk.gz = groundAt(rk.x, rk.y, gz) end
        if strikes[s.id] ~= s then return end
        local first = s.rockets[1] and s.rockets[1].at or s.startsAt
        local wait = first - (tonumber(R.fallMs) or 1200) - 250 - BR.Clock.now()
        if wait > 0 then Citizen.Wait(math.floor(wait)) end
        if strikes[s.id] == s then ensureLoop() end
    end)
end

RegisterNetEvent(BR.Net.TERMINAL_STRIKE)
AddEventHandler(BR.Net.TERMINAL_STRIKE, function(d)
    if type(d) ~= 'table' or not F.on() then return end
    local TS = BR.TerminalSolve
    local id = math.tointeger(d.id)
    if not id or not (TS.finite(d.x) and TS.finite(d.y) and TS.finite(d.r)
                      and TS.finite(d.startsAt) and TS.finite(d.endsAt)) then
        return
    end
    if strikes[id] then dropStrike(strikes[id]) end
    local rockets = {}
    for _, rk in ipairs(type(d.rockets) == 'table' and d.rockets or {}) do
        if TS.finite(rk.x) and TS.finite(rk.y) and TS.finite(rk.at) then
            rockets[#rockets + 1] = { x = rk.x + 0.0, y = rk.y + 0.0, at = rk.at }
        end
    end
    table.sort(rockets, function(a, b) return a.at < b.at end)
    -- THE SLANT: one direction per strike, the same on every client.
    local a = (id * 2.399963) % (2.0 * math.pi)
    local s = { id = id, x = d.x + 0.0, y = d.y + 0.0, r = d.r + 0.0, startsAt = d.startsAt,
                endsAt = d.endsAt, rockets = rockets, dir = { x = math.cos(a), y = math.sin(a) } }
    strikes[id] = s
    s.ring = circle(s.x, s.y, s.r, art().strike or {}, copy().airstrike_blip)
    -- THE ROCKETS, THE FLARE AND THE BLASTS ONLY WITHIN SIGHT.
    local p = viewpoint()
    local reach = tonumber(fx().strikeDrawM) or 800.0
    if p and BR.Clock.now() < s.endsAt then
        local dx, dy = p.x - s.x, p.y - s.y
        if dx * dx + dy * dy <= reach * reach then
            s.near = true
            prepare(s)
        end
    end
end)

-- A VEHICLE A ROCKET HIT, to the client that owns it: the server's figure off
-- its engine and body, or wrecked. Not a vehicle this client no longer owns.
RegisterNetEvent(BR.Net.TERMINAL_STRIKE_VEH)
AddEventHandler(BR.Net.TERMINAL_STRIKE_VEH, function(d)
    if type(d) ~= 'table' or not F.on() then return end
    local netId = math.tointeger(d.netId)
    if not netId or not isTrue(NetworkDoesNetworkIdExist(netId)) then return end
    local veh = NetToVeh(netId)
    if not veh or veh == 0 or not isTrue(DoesEntityExist(veh)) then return end
    if not isTrue(NetworkHasControlOfEntity(veh)) then return end
    if d.wreck == true then
        NetworkExplodeVehicle(veh, true, false, false)
        return
    end
    local frac = tonumber(d.frac) or 0.0
    if frac <= 0.0 then return end
    if frac > 1.0 then frac = 1.0 end
    local dmg = frac * (tonumber(fx().strikeVehicleDamage) or 1000.0)
    SetVehicleEngineHealth(veh, math.max(-4000.0, (tonumber(GetVehicleEngineHealth(veh)) or 1000.0) - dmg))
    SetVehicleBodyHealth(veh, math.max(0.0, (tonumber(GetVehicleBodyHealth(veh)) or 1000.0) - dmg))
end)

-- ONCE A SECOND, on client/terminalfx.lua's one SLOW pass: a strike's circle
-- goes fx.strikeLingerMs after its last rocket; the rough circles go once this
-- player's pick is over here (the server's empty list is on its way too); and
-- in the lobby or off Season 2 everything goes. Nothing with nothing up.
F.onSlow(function()
    if next(strikes) == nil and next(fuzz) == nil then return end
    local S = BR.State
    local lobby = S and S.me and S.me.state == BR.PlayerState.LOBBY
    if lobby or not F.on() then
        clearFuzz()
        for _, s in pairs(strikes) do dropStrike(s) end
        if loopHandle then
            BR.Loop.unregister(loopHandle)
            loopHandle = nil
        end
        return
    end
    if next(fuzz) ~= nil and not (BR.Terminal and BR.Terminal.picking and BR.Terminal.picking()) then
        clearFuzz()
    end
    local now = BR.Clock.now()
    local linger = tonumber(fx().strikeLingerMs) or 2000
    for _, s in pairs(strikes) do
        if now >= s.endsAt + linger then dropStrike(s) end
    end
end)

AddEventHandler('onResourceStop', function(name)
    if name ~= GetCurrentResourceName() then return end
    clearFuzz()
    for _, s in pairs(strikes) do dropStrike(s) end
end)
