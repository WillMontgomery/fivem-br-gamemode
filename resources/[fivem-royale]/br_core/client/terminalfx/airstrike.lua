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
--   THE ROCKETS  each a LOCAL object -- since round 7 a HOMING MISSILE to
--                look at (below): the Homing Launcher's rocket with its trail,
--                launched high and off to the side and curving onto its point
--                over art.rocket's flightMs, landing at exactly the moment the
--                server scheduled -- and where it lands a fireball and the
--                game's cheap explosion sound, and a camera shake for a player
--                near it. The fireball is drawn as big as the server's blast
--                reaches (fx.strikeReachM over art.rocket.blastBaseM): what a
--                player sees is what hurts them.
--
-- ═══ HOMING MISSILES, TO LOOK AT (round 7) ═══
--
-- "For the airstrike - that's more like it. Any chance we could use homing
-- missiles targeted at the random coords we already have?"
--                                                     -- owner, 2026-10-07
--
-- THE SERVER'S STRIKE IS UNTOUCHED: the same random points, the same
-- schedule, the same damage through the health ledger. Only the flight a
-- client draws changed. Two ways to draw one were weighed:
--
--   A REAL PROJECTILE  SHOOT_SINGLE_BULLET_BETWEEN_COORDS with the Homing
--                Launcher (or a vehicle's missile) flies a real homing rocket
--                -- and a real rocket explodes as itself. The Cfx.re native
--                reference: its `ownerPed` is who the kill feed credits ("if
--                the bullet kills someone the kill feed shows 'X was shot by
--                ownerPed'"); the launcher's ammo (weaponhominglauncher.meta,
--                AMMO_HOMINGLAUNCHER) is DestroyOnImpact ProcessImpacts, so
--                its explosion -- GTA's damage, networked, an explosion event
--                server/damage.lua judges -- comes whatever the bullet's own
--                `damage` says. Nothing proves it hurts nobody, so it is not
--                used: our damage is the server's, and only the server's.
--   OUR OWN PROP  what this file does: a local object nothing can be hurt
--                by, flown along a curve. The Homing Launcher's own rocket
--                (w_lr_homing_rocket, the model its ammo wears) first in
--                art.rocket.models, and the trail that ammo draws
--                (TrailFx proj_rpg_trail in the same meta), looped on it from
--                its launch to its landing.
--
-- THE FLIGHT (rocketPath): a cubic curve from art.rocket.launchM off to the
-- side and launchUpM over its point, cruising in at that height, then turning
-- down into a dive from diveUpM -- each rocket veering weaveM to one side or
-- the other on the way, its nose along its path every frame -- onto its point
-- at exactly its `at`. EVERY CLIENT DRAWS THE SAME FLIGHT: the launch bearing
-- comes from the strike's id (as round 5's slant did), fanned over fanDeg by
-- each rocket's place in the server's schedule, the veer alternating by that
-- place too. Nothing random is drawn here.
--
-- ═══ WHY THE ROCKETS WERE NEVER SEEN (round 6, owner 2026-10-07: "missile
--     props never actually spawn") ═══
--
-- Two things stood between the object and the screen, and the suite's stubs
-- hid both (every model loaded, every object drawn):
--
--   NEVER LOADED, SILENTLY. The model was asked for once with RequestModel and
--   never waited on or checked; a rocket whose model had not arrived was simply
--   skipped, every frame of its fall, with nothing said. Now the model is
--   streamed with a bound before the first rocket falls (IsModelInCdimage and
--   IsModelValid first, art.rocket.models in order -- the RPG's rocket, then
--   two stand-ins), and a strike with none loaded says so once on the console.
--   NEVER DRAWN FROM WHERE ANYONE STANDS. A weapon's drawable is authored to be
--   seen in a hand, and the engine stops drawing an object past its model's own
--   LOD distance -- the airdrop crate's lesson (client/airdrop.lua drawFar: "the
--   box was there and was not being DRAWN"). A rocket spends its whole fall
--   50 to 150 m from anybody watching, so it was culled until its last meters,
--   which it covered in a frame or two. Each rocket now gets SET_ENTITY_LOD_DIST
--   (art.rocket.lodDist, past the farthest client that draws one), and flies
--   for 2.5 s or more rather than 1.2, so it is on screen long enough to be
--   seen (3 s since round 7's homing flight).
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
-- before the first one launches within draw distance and unregistered when
-- the last has landed (about seven seconds). Each rocket in the air is moved
-- AND turned every frame since round 7 -- a curve's heading changes as it
-- flies, where round 5's straight slant was turned once -- so a strike's
-- frames cost two natives a rocket, up to eight rockets in the air at once.
-- The circles move on the server's pushes; the SLOW hook returns at once with
-- nothing up.

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
--- rockets = { { x, y, at, ux, uy, side, gz?, obj?, trail?, done? } }, ring,
--- near }. (ux, uy) is the bearing from the rocket's point to its launch, and
--- side the way it veers.
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

--- Let the engine stream a rocket model out again, once no strike shown here
--- still needs it.
local function releaseModel(h)
    if not h or not SetModelAsNoLongerNeeded then return end
    for _, o in pairs(strikes) do
        if o.model == h then return end
    end
    SetModelAsNoLongerNeeded(h)
end

local function dropStrike(s)
    for _, rk in ipairs(s.rockets) do dropRocket(rk) end
    removeBlip(s.ring)
    s.ring = nil
    strikes[s.id] = nil
    releaseModel(s.model)
    s.model = nil
end

--- How big the fireball is drawn: the server's blast reach over the effect's
--- own radius at scale 1 -- so the fireball a player sees is the blast that
--- hurts them (round 6: "the explosions from them should be 3x as big, at
--- least"). Public so the suites can hold the two together.
--- @return number
function F.blastScale()
    local R = rocketArt()
    local base = tonumber(R.blastBaseM) or 5.0
    local reach = tonumber(fx().strikeReachM) or 15.0
    if base <= 0.0 then return 1.0 end
    return reach / base
end

--- The first rocket model that streams in, bounded: art.rocket.models in order
--- (the RPG's rocket first), each checked before it is asked for. Nil when
--- none would come -- said once on the console, since nothing else can show it.
--- @return integer|nil hash
local function loadRocketModel()
    local R = rocketArt()
    local list = type(R.models) == 'table' and R.models or { R.model or 'w_lr_rpg_rocket' }
    for _, name in ipairs(list) do
        local h = GetHashKey(name)
        if isTrue(IsModelInCdimage(h)) and isTrue(IsModelValid(h)) then
            RequestModel(h)
            local waited = 0
            while not isTrue(HasModelLoaded(h)) and waited < (tonumber(R.loadMs) or 5000) do
                Citizen.Wait(50)
                waited = waited + 50
            end
            if isTrue(HasModelLoaded(h)) then return h end
        end
    end
    print('^3[br_core] airstrike: no rocket model would load (' .. table.concat(list, ', ')
        .. ') -- this strike shows its blasts only^7')
    return nil
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

local function flightMs() return tonumber(rocketArt().flightMs) or 3000 end

--- Where a rocket is `t` (0..1) of the way along its flight, and which way it
--- is heading: a cubic curve (the header's THE FLIGHT) from its launch, high
--- and off to the side, to its point on the ground (rk.gz).
--- @return number x, number y, number z, number dx, number dy, number dz
local function rocketPath(rk, t)
    local R = rocketArt()
    local L = tonumber(R.launchM) or 320.0
    local H = tonumber(R.launchUpM) or 160.0
    local D = tonumber(R.diveUpM) or 90.0
    local Wv = (tonumber(R.weaveM) or 40.0) * rk.side
    local ux, uy = rk.ux, rk.uy
    local vx, vy = -uy, ux
    local gx, gy, gz = rk.x, rk.y, rk.gz
    -- The four points: the launch; level at launch height, 60% of the way
    -- out and veering; over the point at diveUpM, a little short of it; the
    -- point.
    local p0x, p0y, p0z = gx + ux * L, gy + uy * L, gz + H
    local p1x, p1y, p1z = gx + ux * L * 0.6 + vx * Wv, gy + uy * L * 0.6 + vy * Wv, gz + H
    local p2x, p2y, p2z = gx + ux * L * 0.1 + vx * Wv * 0.3, gy + uy * L * 0.1 + vy * Wv * 0.3, gz + D
    local a = 1.0 - t
    local b0, b1, b2, b3 = a * a * a, 3.0 * a * a * t, 3.0 * a * t * t, t * t * t
    local x = b0 * p0x + b1 * p1x + b2 * p2x + b3 * gx
    local y = b0 * p0y + b1 * p1y + b2 * p2y + b3 * gy
    local z = b0 * p0z + b1 * p1z + b2 * p2z + b3 * gz
    local d0, d1, d2 = 3.0 * a * a, 6.0 * a * t, 3.0 * t * t
    local dx = d0 * (p1x - p0x) + d1 * (p2x - p1x) + d2 * (gx - p2x)
    local dy = d0 * (p1y - p0y) + d1 * (p2y - p1y) + d2 * (gy - p2y)
    local dz = d0 * (p1z - p0z) + d1 * (p2z - p1z) + d2 * (gz - p2z)
    return x, y, z, dx, dy, dz
end

--- How far along its flight a rocket is at `now`: 0 at launch, 1 at its `at`.
local function flightT(rk, now)
    local ms = flightMs()
    local t = (now - (rk.at - ms)) / ms
    if t < 0.0 then return 0.0 end
    if t > 1.0 then return 1.0 end
    return t
end

--- Where strike `id`'s rocket `i` (in the server's order) is at `now` on the
--- server's clock, or nil before this client knows its ground. For the suites:
--- every client works the same flight out of the same strike.
--- @return number|nil x, number y, number z
function F.rocketAt(id, i, now)
    local s = strikes[id]
    local rk = s and s.rockets[i]
    if not rk or not rk.gz then return nil end
    local x, y, z = rocketPath(rk, flightT(rk, now))
    return x, y, z
end

--- A rocket's nose along (dx, dy, dz): GTA's forward is (-sin h, cos h), and
--- its pitch the climb's.
local function aim(obj, dx, dy, dz)
    local flat = math.sqrt(dx * dx + dy * dy)
    if flat < 1e-6 and math.abs(dz) < 1e-6 then return end
    SetEntityRotation(obj, math.deg(math.atan(dz, flat)), 0.0, math.deg(math.atan(-dx, dy)), 2, true)
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
            F.blastScale(), false, false, false)
    end
    if R.sound then PlaySoundFromCoord(-1, R.sound, rk.x, rk.y, z, 0, false, 0, false) end
    if R.shake and view then
        local dx, dy = view.x - rk.x, view.y - rk.y
        local d = math.sqrt(dx * dx + dy * dy)
        local within = tonumber(R.shakeM) or 60.0
        if d < within then ShakeGameplayCam(R.shake, 0.6 * (1.0 - d / within)) end
    end
end

--- A rocket in the air: made on its first frame, moved and turned along its
--- curve on every one after.
local function fly(s, rk, now)
    local R = rocketArt()
    local x, y, z, dx, dy, dz = rocketPath(rk, flightT(rk, now))
    if not rk.obj then
        -- THE MODEL prepare() STREAMED IN, or none would come (said once).
        if not s.model then return end
        local obj = CreateObjectNoOffset(s.model, x, y, z, false, false, false)
        if not obj or obj == 0 then return end
        -- DRAWN FROM AS FAR AS ANYBODY SEES IT FALL (the header's second
        -- reason): a weapon's drawable is culled past its own few meters.
        if SetEntityLodDist then pcall(SetEntityLodDist, obj, math.floor(tonumber(R.lodDist) or 1000)) end
        SetEntityCollision(obj, false, false)
        FreezeEntityPosition(obj, true)
        rk.obj = obj
        if R.trailAsset and R.trail and isTrue(HasNamedPtfxAssetLoaded(R.trailAsset)) then
            UseParticleFxAsset(R.trailAsset)
            rk.trail = StartParticleFxLoopedOnEntity(R.trail, obj, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                1.0, false, false, false)
        end
    end
    SetEntityCoords(rk.obj, x, y, z, false, false, false, false)
    aim(rk.obj, dx, dy, dz)
end

local function stepRockets()
    local now = BR.Clock.now()
    local view = nil
    local pending = false
    local ms = flightMs()
    for _, s in pairs(strikes) do
        if s.near then
            for _, rk in ipairs(s.rockets) do
                if not rk.done then
                    if now >= rk.at then
                        view = view or viewpoint()
                        land(s, rk, view)
                    else
                        pending = true
                        if now >= rk.at - ms and rk.gz then fly(s, rk, now) end
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
        if R.trailAsset then RequestNamedPtfxAsset(R.trailAsset) end
        if R.blastAsset and R.blastAsset ~= R.trailAsset then RequestNamedPtfxAsset(R.blastAsset) end
        for _, rk in ipairs(s.rockets) do rk.gz = groundAt(rk.x, rk.y, gz) end
        -- THE MODEL, STREAMED AND WAITED ON (the header's first reason), well
        -- inside the warning: it is asked for the moment the strike is known.
        local model = loadRocketModel()
        if strikes[s.id] ~= s then
            releaseModel(model)
            return
        end
        s.model = model
        local first = s.rockets[1] and s.rockets[1].at or s.startsAt
        local wait = first - flightMs() - 250 - BR.Clock.now()
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
    -- THE LAUNCH BEARINGS (the header's THE FLIGHT): one per strike from its
    -- id, fanned over fanDeg by each rocket's place in the schedule, and the
    -- veer alternating by it -- the same on every client.
    local base = (id * 2.399963) % (2.0 * math.pi)
    local fan = math.rad(tonumber(rocketArt().fanDeg) or 50.0)
    for i, rk in ipairs(rockets) do
        local off = #rockets > 1 and ((i - 1) / (#rockets - 1) - 0.5) * fan or 0.0
        rk.ux, rk.uy = math.cos(base + off), math.sin(base + off)
        rk.side = (i % 2 == 0) and 1.0 or -1.0
    end
    local s = { id = id, x = d.x + 0.0, y = d.y + 0.0, r = d.r + 0.0, startsAt = d.startsAt,
                endsAt = d.endsAt, rockets = rockets }
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
