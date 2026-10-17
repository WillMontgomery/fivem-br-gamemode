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
-- ═══ WHY THEY WERE STILL NOT SEEN (round 8, owner 2026-10-11: "Airstrikes
--     didn't seem to spawn any props....") ═══
--
-- The server ran each strike (its log said "ok (done)" three times) and this
-- file flew each rocket -- where nobody could see it. Measured on the curve
-- itself (tools/test_terminalstrike.lua), from where the rehearsal stands --
-- 60 m off the spot, looking at it, through GTA's 50-degree camera -- a round
-- 7 rocket was in the picture, near enough to be more than a few pixels, for
-- a median 0.35 s of its 3 s. It launched 320 m off and 160 m up (a 1 m rocket
-- at 300 m is four pixels), crossed the sky above the top of the picture at
-- 130 m/s and came into it only for its last dive. Round 6's straight fall
-- from 150 m was the same: above the picture until its last half second.
-- Since round 8 each comes in LOW AND SLOWER (art.rocket): 240 m off and 70 m
-- up, five seconds in the air at about 50 m/s, diving from 35 m onto its
-- point -- in that picture for a median 1.4 s, and from 150 m off for 1.75 s
-- or more, every rocket (round 7: 0.58 s).
--
-- AND THE NEXT TEST SAYS WHICH IT WAS (dev mode only, F8): one line per
-- strike -- how many rockets were made, as which model, how many had their
-- trail, how many the game reported on screen (IS_ENTITY_ON_SCREEN, sampled
-- while they fly) and how near the nearest came; or why none was drawn here:
-- too far off, already over, each model and why it would not load, the
-- object the game would not make.
--
-- ═══ WHAT IT COSTS ═══
--
-- Nothing per frame but the rockets: a FRAME callback registered a moment
-- before the first one launches within draw distance and unregistered when
-- the last has landed (about ten seconds). Each rocket in the air is moved
-- AND turned every frame since round 7 -- a curve's heading changes as it
-- flies, where round 5's straight slant was turned once -- so a strike's
-- frames cost two natives a rocket, all ten in the air at once for a moment
-- since round 8's five-second flight (and a third, IS_ENTITY_ON_SCREEN, in
-- dev mode only).
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

--- Is this a dev box? Asked once a strike (BR.Dev.on reads two convars).
local function devOn()
    return BR.Dev ~= nil and BR.Dev.on ~= nil and BR.Dev.on() == true
end

--- The dev line (the header's round 8): F8, dev mode only.
local function sayDev(id, text)
    print(('[br_core] airstrike %s: %s'):format(tostring(id), text))
end

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
    removeEnt(rk.carrier)
    rk.carrier = nil
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

--- How big strike `s`'s rockets and trails are drawn (round 9, owner: "do at
--- least 20x but also give me a way to scale it with `brterminal run
--- airstrike`"): art.rocket's scale and trailScale, or the `look` a dev
--- rehearsal sent with this one strike. Public so the suites can hold them.
--- @param s table|nil  a strike
--- @return number
function F.scaleOf(s)
    return (s and s.scale) or tonumber(rocketArt().scale) or 1.0
end

--- @param s table|nil  a strike
--- @return number
function F.trailScaleOf(s)
    return (s and s.trailScale) or tonumber(rocketArt().trailScale) or 1.0
end

--- A rehearsal's size, as the server sent it: a finite number from 0.1 to
--- 100, or nil to use the art's.
local function lookSize(v)
    v = tonumber(v)
    if not v or v ~= v or v < 0.1 or v > 100.0 then return nil end
    return v + 0.0
end

--- A rehearsal's three numbers (`toff=x,y,z`, `trot=p,r,y`), as the server
--- sent them: three finite numbers each within -lim..lim, or nil.
local function lookVec(v, lim)
    if type(v) ~= 'table' then return nil end
    local out = {}
    for i = 1, 3 do
        local n = tonumber(v[i])
        if not n or n ~= n or n < -lim or n > lim then return nil end
        out[i] = n + 0.0
    end
    return out
end

--- How far the back of a rocket model sits behind its origin at 1x, in
--- meters (its box's least y; GTA's forward is +y). Asked once a model.
local backs = {}
local function backOf(model)
    if not model then return -0.15 end
    if backs[model] == nil then
        -- A vector3 in game; anything else (a stub, a failed call) is the
        -- default, never an error in the frame pass.
        local ok, lo = pcall(GetModelDimensions, model)
        local y = nil
        if ok and lo ~= nil and type(lo) ~= 'number' then
            local okY, v = pcall(function() return lo.y or lo[2] end)
            y = okY and v or nil
        end
        backs[model] = tonumber(y) or -0.15
    end
    return backs[model]
end

--- Where strike `s`'s trail sits on its rocket and which way it points
--- (round 9, owner: "the smoke trails are wayyyyy behind the props
--- physically"): meters from the rocket's origin along its right, its nose
--- and its top -- art.rocket.trailOffset, or the back of the rocket at its
--- scale -- and degrees of pitch, roll and yaw (art.rocket.trailRot). A
--- rehearsal's `look` (toff, trot) wins. Public for the suites and brrocket.
--- @return number x, number y, number z
function F.trailOffsetOf(s)
    local o = (s and s.toff) or rocketArt().trailOffset
    if type(o) == 'table' then return o[1] + 0.0, o[2] + 0.0, o[3] + 0.0 end
    return 0.0, backOf(s and s.model) * F.scaleOf(s), 0.0
end

--- The trail effect strike `s` draws (round 9, owner: "perhaps you should
--- also give me a choice of particles?"): the n-th of art.rocket.trails when
--- a rehearsal or brrocket picked one, else trailAsset/trail.
--- @return string|nil asset, string|nil effect, integer|nil n
function F.trailFxOf(s)
    local R = rocketArt()
    local n = s and s.fx
    local e = n and type(R.trails) == 'table' and R.trails[n]
    if type(e) == 'table' and type(e[1]) == 'string' and type(e[2]) == 'string' then
        return e[1], e[2], n
    end
    return R.trailAsset, R.trail, nil
end

--- A rehearsal's pick of art.rocket.trails, as the server sent it, or nil.
local function lookFx(v)
    local n = math.tointeger(tonumber(v))
    local list = rocketArt().trails
    if not n or type(list) ~= 'table' or n < 1 or n > #list then return nil end
    return n
end

--- @return number pitch, number roll, number yaw
function F.trailRotOf(s)
    local r = (s and s.trot) or rocketArt().trailRot
    if type(r) == 'table' then return r[1] + 0.0, r[2] + 0.0, r[3] + 0.0 end
    return 0.0, 0.0, 0.0
end

--- The first rocket model that streams in, bounded: art.rocket.models in order
--- (the Homing Launcher's rocket first), each checked before it is asked for.
--- Nil when none would come -- said once on the console, since nothing else
--- can show it -- with why each one would not, for the dev line.
--- @return integer|nil hash, string|nil name, string[] why
local function loadRocketModel()
    local R = rocketArt()
    local list = type(R.models) == 'table' and R.models or { R.model or 'w_lr_rpg_rocket' }
    local bound = tonumber(R.loadMs) or 5000
    local why = {}
    for _, name in ipairs(list) do
        local h = GetHashKey(name)
        if not isTrue(IsModelInCdimage(h)) then
            why[#why + 1] = name .. ' is not in the game files'
        elseif not isTrue(IsModelValid(h)) then
            why[#why + 1] = name .. ' is not a valid model'
        else
            RequestModel(h)
            local waited = 0
            while not isTrue(HasModelLoaded(h)) and waited < bound do
                Citizen.Wait(50)
                waited = waited + 50
            end
            if isTrue(HasModelLoaded(h)) then return h, name, why end
            why[#why + 1] = ('%s did not load in %d ms'):format(name, bound)
        end
    end
    print('^3[br_core] airstrike: no rocket model would load (' .. table.concat(list, ', ')
        .. ') -- this strike shows its blasts only^7')
    return nil, nil, why
end

--- The dev line for a strike drawn here, once its last rocket has landed:
--- what was made and seen, or why nothing was.
local function sayDrawn(s)
    local d = s.dev
    local n = #s.rockets
    if not s.modelName then
        sayDev(s.id, ('no rocket drawn -- %s; the blasts only')
            :format(#d.why > 0 and table.concat(d.why, '; ') or 'the model was still loading'))
        return
    end
    local line = ('%d of %d rockets made as %s at %gx, %d with a trail at %gx, %d on screen')
        :format(d.made, n, s.modelName, F.scaleOf(s), d.trails, F.trailScaleOf(s), d.seen)
    if d.seen > 0 then line = line .. (' (the longest %.1f s)'):format(d.seenMs / 1000) end
    if d.nearest then line = line .. (', the nearest %.0f m from this view'):format(d.nearest) end
    if d.refused > 0 then
        line = line .. ('; %d the game would not make (CreateObjectNoOffset answered 0)'):format(d.refused)
    end
    local late = n - d.made - d.refused
    if late > 0 then line = line .. ('; %d landed before the model was in'):format(late) end
    if d.noTrail then line = line .. '; no trail: ' .. d.noTrail end
    if #d.why > 0 then line = line .. ' (' .. table.concat(d.why, '; ') .. ')' end
    sayDev(s.id, line)
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
    -- out and veering; at diveUpM a fifth of the way out (round 8: at a
    -- tenth, a five-second flight slowed to under half its launch speed over
    -- its point); the point.
    local p0x, p0y, p0z = gx + ux * L, gy + uy * L, gz + H
    local p1x, p1y, p1z = gx + ux * L * 0.6 + vx * Wv, gy + uy * L * 0.6 + vy * Wv, gz + H
    local p2x, p2y, p2z = gx + ux * L * 0.2 + vx * Wv * 0.3, gy + uy * L * 0.2 + vy * Wv * 0.3, gz + D
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
    -- THE DEV LINE once the last has landed (the header's round 8).
    s.landed = (s.landed or 0) + 1
    if s.dev and s.landed == #s.rockets then sayDrawn(s) end
end

--- A rocket in the air: made on its first frame, moved and turned along its
--- curve on every one after.
local function fly(s, rk, now, dt, view)
    local R = rocketArt()
    local x, y, z, dx, dy, dz = rocketPath(rk, flightT(rk, now))
    local dev = s.dev
    if not rk.obj then
        -- THE MODEL prepare() STREAMED IN, or none would come (said once).
        if not s.model then return end
        local obj = CreateObjectNoOffset(s.model, x, y, z, false, false, false)
        if not obj or obj == 0 then
            if dev and not rk.refused then
                rk.refused = true
                dev.refused = dev.refused + 1
            end
            return
        end
        -- DRAWN FROM AS FAR AS ANYBODY SEES IT FALL (the header's second
        -- reason): a weapon's drawable is culled past its own few meters.
        if SetEntityLodDist then pcall(SetEntityLodDist, obj, math.floor(tonumber(R.lodDist) or 1000)) end
        SetEntityCollision(obj, false, false)
        FreezeEntityPosition(obj, true)
        rk.obj = obj
        -- THE TRAIL'S CARRIER (round 9): a see-through twin of the rocket at
        -- its own size, on the same path and turned the same way every frame.
        -- A looped effect on the scaled rocket is scaled with its matrix --
        -- the effect's own offsets and spread twenty times over -- which is
        -- what put the smoke "wayyyyy behind the props"; on the twin the trail
        -- sits in meters, wherever trailOffset says. SEE-THROUGH (alpha 0),
        -- NOT INVISIBLE: on an invisible twin the owner saw only the effect's
        -- glow, in the dark, and no smoke -- an effect on an entity that is
        -- not drawn may not be drawn either. At 1x it sits inside its scaled
        -- rocket anyway.
        local carrier = CreateObjectNoOffset(s.model, x, y, z, false, false, false)
        if carrier and carrier ~= 0 then
            SetEntityAlpha(carrier, 0, false)
            SetEntityCollision(carrier, false, false)
            FreezeEntityPosition(carrier, true)
            if SetEntityLodDist then pcall(SetEntityLodDist, carrier, math.floor(tonumber(R.lodDist) or 1000)) end
            rk.carrier = carrier
        end
        local tAsset, tName = F.trailFxOf(s)
        if tAsset and tName and isTrue(HasNamedPtfxAssetLoaded(tAsset)) then
            UseParticleFxAsset(tAsset)
            local ox, oy, oz = F.trailOffsetOf(s)
            local rx, ry, rz = F.trailRotOf(s)
            rk.trail = StartParticleFxLoopedOnEntity(tName, rk.carrier or obj, ox, oy, oz, rx, ry, rz,
                F.trailScaleOf(s), false, false, false)
            -- THE TRAIL IS SEEN AS FAR AS THE ROCKET (round 9): a looped
            -- effect's own far clip is shorter than lodDist.
            if rk.trail and rk.trail ~= 0 and SetParticleFxLoopedFarClipDist then
                pcall(SetParticleFxLoopedFarClipDist, rk.trail, (tonumber(R.lodDist) or 1000) + 0.0)
            end
        end
        if dev then
            if rk.refused then
                rk.refused = nil
                dev.refused = dev.refused - 1
            end
            dev.made = dev.made + 1
            if rk.trail and rk.trail ~= 0 then
                dev.trails = dev.trails + 1
            elseif tAsset and tName then
                dev.noTrail = isTrue(HasNamedPtfxAssetLoaded(tAsset))
                    and ('the game would not start ' .. tName)
                    or ('the particle asset ' .. tAsset .. ' was not loaded')
            end
        end
    end
    SetEntityCoords(rk.obj, x, y, z, false, false, false, false)
    aim(rk.obj, dx, dy, dz)
    -- DRAWN AT art.rocket.scale TIMES ITS SIZE (round 9), after the turn: a
    -- rotation writes a unit matrix, so the scale goes back on every frame.
    BR.Native.propScale(rk.obj, F.scaleOf(s))
    if rk.carrier then
        SetEntityCoords(rk.carrier, x, y, z, false, false, false, false)
        aim(rk.carrier, dx, dy, dz)
    end
    -- WHAT THE GAME SAYS IT SHOWS, AND HOW NEAR (dev mode only).
    if dev then
        if isTrue(IsEntityOnScreen(rk.obj)) then
            if not rk.seenMs then dev.seen = dev.seen + 1 end
            rk.seenMs = (rk.seenMs or 0) + (dt or 0)
            if rk.seenMs > dev.seenMs then dev.seenMs = rk.seenMs end
        end
        if view then
            local ex, ey, ez = x - view.x, y - view.y, z - (view.z or z)
            local d = math.sqrt(ex * ex + ey * ey + ez * ez)
            if not dev.nearest or d < dev.nearest then dev.nearest = d end
        end
    end
end

local function stepRockets(dt)
    local now = BR.Clock.now()
    local view = nil
    local pending = false
    local ms = flightMs()
    for _, s in pairs(strikes) do
        if s.near then
            if s.dev then view = view or viewpoint() end
            for _, rk in ipairs(s.rockets) do
                if not rk.done then
                    if now >= rk.at then
                        view = view or viewpoint()
                        land(s, rk, view)
                    else
                        pending = true
                        if now >= rk.at - ms and rk.gz then fly(s, rk, now, dt, view) end
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
        local tAsset = F.trailFxOf(s)
        if tAsset then RequestNamedPtfxAsset(tAsset) end
        if R.blastAsset and R.blastAsset ~= tAsset then RequestNamedPtfxAsset(R.blastAsset) end
        for _, rk in ipairs(s.rockets) do rk.gz = groundAt(rk.x, rk.y, gz) end
        -- THE MODEL, STREAMED AND WAITED ON (the header's first reason), well
        -- inside the warning: it is asked for the moment the strike is known.
        local model, name, why = loadRocketModel()
        if strikes[s.id] ~= s then
            releaseModel(model)
            return
        end
        s.model, s.modelName = model, name
        if s.dev then s.dev.why = why end
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
    -- A DEV REHEARSAL'S SIZES (round 9), for this one strike only; a real run
    -- never carries `look` (server/terminal.lua's `brterminal run`).
    if type(d.look) == 'table' then
        s.scale = lookSize(d.look.scale)
        s.trailScale = lookSize(d.look.trail)
        s.toff = lookVec(d.look.toff, 50.0)
        s.trot = lookVec(d.look.trot, 360.0)
        s.fx = lookFx(d.look.fx)
    end
    strikes[id] = s
    s.ring = circle(s.x, s.y, s.r, art().strike or {}, copy().airstrike_blip)
    -- What the dev line counts (the header's round 8), on a dev box only.
    local dev = devOn()
    if dev then s.dev = { made = 0, refused = 0, trails = 0, seen = 0, seenMs = 0, why = {} } end
    -- THE ROCKETS, THE FLARE AND THE BLASTS ONLY WITHIN SIGHT.
    local p = viewpoint()
    local reach = tonumber(fx().strikeDrawM) or 800.0
    if not p then
        if dev then sayDev(id, 'not drawn here -- this client has no view to draw it from') end
    elseif BR.Clock.now() >= s.endsAt then
        if dev then sayDev(id, 'not drawn here -- its last rocket had landed before it arrived') end
    else
        local dx, dy = p.x - s.x, p.y - s.y
        if dx * dx + dy * dy <= reach * reach then
            s.near = true
            prepare(s)
        elseif dev then
            sayDev(id, ('not drawn here -- %.0f m from this view; rockets are drawn within %.0f m')
                :format(math.sqrt(dx * dx + dy * dy), reach))
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

-- === brrocket: A ROCKET ON A SLOW PASS, TUNED WITH THE KEYS (round 9) ===
--
-- "perhaps you could give me a stationary example where I can tune the
-- position, direction, and size of the smoke trails relative to the props,
-- then fire an airstrike on my own using the other command to try it out"
-- "how about instead of so many commands and args, we use keyboard keys like
-- we've done for other things. ... Any manual adjustment commands must allow
-- keyboard input."                                    -- owner, 2026-10-11
--
-- `brrocket` flies one rocket across your view, 7 m in front of you, over and
-- over, drawn exactly as a strike draws one (the scaled rocket, its trail on
-- the invisible carrier); `brrocket` again puts it away and prints what it came
-- to. IT FLIES BECAUSE THE TRAIL ONLY LAYS SMOKE WHILE IT MOVES: standing still
-- (the first cut), the owner saw "the smoke isn't always drawing - seems to be
-- one frame whenever I move it's position". Then, flying at 20 m/s: "still no
-- particles, and that brrocket flight is far too fast for me fine-tune
-- anything", and "in the dark it does have a glow - perhaps you should also
-- give me a choice of particles?" So the pass is slow (2 m/s) with its speed
-- on the keys, the effect is a choice, and the twin is see-through rather
-- than invisible (fly()'s note). While it is out the keys tune it, in /brplate's shape: the
-- arrows, PAGE UP/DOWN and DELETE are claimed, walking and the mouse stay
-- yours so you can walk round it, a tap is one step and a hold is twenty a
-- second, and the modifiers are read without being taken.
--   LEFT / RIGHT             the trail across the rocket (x, + its right)
--   UP / DOWN                along it (y, + toward the nose)
--   CTRL + UP / DOWN         up and down (z)
--   ALT + UP / DOWN          the trail's pitch    ALT + LEFT / RIGHT   its yaw
--   ALT + CTRL + UP / DOWN   its roll
--   PAGE UP / DOWN           the trail's size     CTRL + PAGE UP / DOWN   the rocket's
--   CTRL + LEFT / RIGHT      the effect: the previous or next of art.rocket.trails
--   ALT + PAGE UP / DOWN     the pass's speed, 0 (standing still) to 50 m/s
--   hold SHIFT               bigger steps         DELETE   back to the art's numbers
-- While it is out, `brterminal run airstrike` fires a strike drawn the same
-- way: client/terminal.lua adds this look (F.rocketLookWords) for any of
-- scale=, trail=, toff=, trot=, fx= not typed. The look lasts the session, so the
-- next `brrocket` picks up where this one was left. Dev mode only (the dev
-- gate wraps every command).
local sample = nil
local look = {}
local keysLoop = nil
local nudgeAt, deleteWasDown = 0, false
local making = false
local fxWasDown = false

--- The pass: 7 m ahead of you, 8 m long across your view, flown left to right
--- at passSpeed (2 m/s to start: 4 s a pass, slow enough to watch), then again
--- from the start with a fresh trail (moved back with the old one running, it
--- would draw smoke along the jump). The speed is the session's, like the look.
local PASS_AHEAD_M, PASS_LENGTH_M = 7.0, 8.0
local passSpeed = 2.0

--- The keys it reads. The arrows, the page keys and DELETE are claimed while
--- it is out (ROCKET_BLOCKED); CTRL, ALT and SHIFT are read, never claimed.
local ROCKET_KEY = {
    UP = 172, DOWN = 173, LEFT = 174, RIGHT = 175,   -- INPUT_CELLPHONE_UP/DOWN/LEFT/RIGHT
    BIGGER = 10,    -- PAGE UP      INPUT_SCRIPTED_FLY_ZUP
    SMALLER = 11,   -- PAGE DOWN    INPUT_SCRIPTED_FLY_ZDOWN
    RESET = 178,    -- DELETE       INPUT_CELLPHONE_OPTION
    DEPTH = 36,     -- LEFT CTRL    INPUT_DUCK
    TURN = 19,      -- LEFT ALT     INPUT_CHARACTER_WHEEL
    COARSE = 21,    -- LEFT SHIFT   INPUT_SPRINT
}
--- 27 is INPUT_PHONE, the up arrow's other control (/brplate's list).
--- CTRL + LEFT / RIGHT picks the effect and ALT + PAGE UP / DOWN the speed.
local ROCKET_BLOCKED = { 27, 172, 173, 174, 175, 10, 11, 178 }
--- attachtune.lua's meters and degrees; sizes a tenth at a time.
local ROCKET_STEP = {
    fine   = { m = 0.01, deg = 1.0,  x = 0.1, mps = 1.0 },
    coarse = { m = 0.10, deg = 15.0, x = 1.0, mps = 5.0 },
}
local ROCKET_REPEAT_MS = 50

local function held(id) return isTrue(IsDisabledControlPressed(0, id)) end

local function roundTo(v, places)
    local k = 10 ^ places
    return math.floor(v * k + 0.5) / k
end

local function clampTo(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

--- Degrees kept within -180..180, so the line always fits the server's -360..360.
local function wrapDeg(v)
    return (v + 180.0) % 360.0 - 180.0
end

--- The look's four words for `brterminal run airstrike`, or nil when no rocket
--- is out. Public for client/terminal.lua and the suites.
--- @return table|nil  { scale=, trail=, toff=, trot= } as typed text
function F.rocketLookWords()
    if not sample then return nil end
    local ox, oy, oz = F.trailOffsetOf(look)
    local rx, ry, rz = F.trailRotOf(look)
    local _, _, n = F.trailFxOf(look)
    return {
        scale = ('%g'):format(F.scaleOf(look)),
        trail = ('%g'):format(F.trailScaleOf(look)),
        toff = ('%g,%g,%g'):format(ox, oy, oz),
        trot = ('%g,%g,%g'):format(rx, ry, rz),
        fx = n and tostring(n) or nil,
    }
end

--- The `brterminal run airstrike` line that draws a strike as `t` looks.
--- @param t table  a look
--- @return string
function F.rocketLine(t)
    local ox, oy, oz = F.trailOffsetOf(t)
    local rx, ry, rz = F.trailRotOf(t)
    local _, _, n = F.trailFxOf(t)
    return ('brterminal run airstrike scale=%g trail=%g toff=%g,%g,%g trot=%g,%g,%g%s')
        :format(F.scaleOf(t), F.trailScaleOf(t), ox, oy, oz, rx, ry, rz, n and (' fx=' .. n) or '')
end

--- What brrocket draws now, and the look it is tuned to (for the suites).
--- @return table|nil sample, table look
function F.rocketSample() return sample, look end

-- While it is out, ALT is its turn key and the emote wheel stays shut
-- (client/tunekeys.lua, ALT IS THE TOOL'S). Guarded for the suites that load
-- this file without that one; the game loads it first.
if BR.TuneKeys and BR.TuneKeys.alsoCount then
    BR.TuneKeys.alsoCount('brrocket', function() return sample ~= nil end)
end

local function sampleClear()
    if keysLoop then
        BR.Loop.unregister(keysLoop)
        keysLoop = nil
    end
    nudgeAt, deleteWasDown, fxWasDown = 0, false, false
    if not sample then return end
    if sample.trail then StopParticleFxLooped(sample.trail, false) end
    removeEnt(sample.obj)
    removeEnt(sample.carrier)
    sample = nil
end

--- A trail on the carrier as the look says, once its effect's asset is in
--- (asked for here; a pick from another asset streams in over a few frames).
--- Tried once a pass per effect, so an effect the game will not start is said
--- on the readout rather than retried every frame.
local function trailStart()
    if not sample or sample.trail then return end
    local asset, name, n = F.trailFxOf(look)
    if not (asset and name) then return end
    local key = ('%s/%s/%d'):format(asset, name, sample.lap)
    if sample.tried == key then return end
    if not isTrue(HasNamedPtfxAssetLoaded(asset)) then
        RequestNamedPtfxAsset(asset)
        return
    end
    sample.tried = key
    UseParticleFxAsset(asset)
    local ox, oy, oz = F.trailOffsetOf(look)
    local rx, ry, rz = F.trailRotOf(look)
    local h = StartParticleFxLoopedOnEntity(name, sample.carrier, ox, oy, oz, rx, ry, rz,
        F.trailScaleOf(look), false, false, false)
    sample.trail = (h and h ~= 0) and h or nil
    sample.refused = not sample.trail
end

--- Where the pass has the rocket now, every frame: both it and its carrier
--- moved and turned (the turn puts the matrix back to 1x, so the scale goes
--- on after), and a fresh trail at the start of each pass.
local function sampleFly()
    local now = GetGameTimer()
    local run = sample.run + (now - sample.lastMs) / 1000.0 * passSpeed
    sample.lastMs = now
    local lap = sample.lap
    if run >= PASS_LENGTH_M then
        run = run % PASS_LENGTH_M
        lap = lap + 1
    end
    sample.run = run
    local along = run
    if lap ~= sample.lap and sample.trail then
        StopParticleFxLooped(sample.trail, false)
        sample.trail = nil
    end
    local x, y = sample.x0 + sample.ux * along, sample.y0 + sample.uy * along
    for _, e in ipairs({ sample.obj, sample.carrier }) do
        SetEntityCoords(e, x, y, sample.z0, false, false, false, false)
        aim(e, sample.ux, sample.uy, 0.0)
    end
    BR.Native.propScale(sample.obj, F.scaleOf(look))
    sample.lap = lap
    trailStart()
end

--- The rocket and its trail as the look says now: turned (which puts its
--- matrix back to 1x), then scaled, and the running trail moved, turned and
--- sized in place rather than started again.
local function sampleApply()
    if not sample then return end
    look.model = sample.model
    aim(sample.obj, sample.ux, sample.uy, 0.0)
    BR.Native.propScale(sample.obj, F.scaleOf(look))
    if sample.trail then
        local ox, oy, oz = F.trailOffsetOf(look)
        local rx, ry, rz = F.trailRotOf(look)
        SetParticleFxLoopedOffsets(sample.trail, ox, oy, oz, rx, ry, rz)
        SetParticleFxLoopedScale(sample.trail, F.trailScaleOf(look))
    end
end

--- One line of the readout: /brplate's `text`, matched call for call.
local function readoutLine(y, s)
    SetTextFont(4)
    SetTextScale(0.0, 0.34)
    SetTextColour(255, 255, 255, 235)
    SetTextDropshadow(0, 0, 0, 0, 255)
    SetTextEdge(1, 0, 0, 0, 205)
    SetTextDropShadow()
    SetTextOutline()
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName(s)
    EndTextCommandDisplayText(0.015, y)
end

--- The numbers, every frame, with what the keys drive right now in blue
--- (/brplate's rule: numbers, and the color says which).
local function readout(depth, turn, step)
    local B, W = '~b~', '~w~'
    local ox, oy, oz = F.trailOffsetOf(look)
    local rx, ry, rz = F.trailRotOf(look)
    local y = 0.34
    readoutLine(y, ('~b~rocket~w~   size %s%.2fx%s   trail %s%.2fx%s')
        :format(depth and B or '', F.scaleOf(look), W, depth and '' or B, F.trailScaleOf(look), W))
    y = y + 0.026
    readoutLine(y, ('place   x %s%.3f%s   y %s%.3f%s   z %s%.3f%s m')
        :format(turn and '' or B, ox, W, (turn or depth) and '' or B, oy, W,
                (not turn and depth) and B or '', oz, W))
    y = y + 0.026
    readoutLine(y, ('turn   pitch %s%.0f%s   roll %s%.0f%s   yaw %s%.0f%s')
        :format((turn and not depth) and B or '', rx, W, (turn and depth) and B or '', ry, W,
                turn and B or '', rz, W))
    y = y + 0.026
    y = y + 0.026
    local asset, name, n = F.trailFxOf(look)
    local list = rocketArt().trails
    readoutLine(y, ('effect %s%s/%d%s   %s / %s%s')
        :format((depth and not turn) and B or '', tostring(n or 0), type(list) == 'table' and #list or 0, W,
                tostring(asset), tostring(name), (sample and sample.refused) and '   ~r~would not start~w~' or ''))
    y = y + 0.026
    readoutLine(y, ('pass %s%.0f m/s%s'):format(turn and B or '', passSpeed, W))
    y = y + 0.026
    readoutLine(y, ('step %.2f m   %.0f deg   %.1fx   %.0f m/s'):format(step.m, step.deg, step.x, step.mps))
end

--- The keys, per frame while the rocket is out (FRAME, for /brplate's reason:
--- DisableControlAction lasts one frame).
local function rocketKeys()
    if not sample then return end
    for i = 1, #ROCKET_BLOCKED do DisableControlAction(0, ROCKET_BLOCKED[i], true) end
    look.model = sample.model
    sampleFly()
    local depth, turn = held(ROCKET_KEY.DEPTH), held(ROCKET_KEY.TURN)
    local step = held(ROCKET_KEY.COARSE) and ROCKET_STEP.coarse or ROCKET_STEP.fine
    readout(depth, turn, step)

    -- DELETE, once a press: the art's numbers back.
    local del = held(ROCKET_KEY.RESET)
    if del and not deleteWasDown then
        look = {}
        sampleApply()
        -- the art's effect too: a fresh trail on it
        if sample.trail then StopParticleFxLooped(sample.trail, false) end
        sample.trail, sample.tried, sample.refused = nil, nil, false
        trailStart()
    end
    deleteWasDown = del

    -- CTRL + LEFT / RIGHT, once a press: the previous or next effect.
    local pick = (depth and not turn) and ((held(ROCKET_KEY.RIGHT) and 1 or 0) - (held(ROCKET_KEY.LEFT) and 1 or 0)) or 0
    if pick ~= 0 and not fxWasDown then
        local list = rocketArt().trails
        local count = type(list) == 'table' and #list or 0
        if count > 0 then
            local _, _, n = F.trailFxOf(look)
            look.fx = ((n or 1) - 1 + pick) % count + 1
            local asset = F.trailFxOf(look)
            if asset then RequestNamedPtfxAsset(asset) end
            if sample.trail then StopParticleFxLooped(sample.trail, false) end
            sample.trail, sample.tried, sample.refused = nil, nil, false
            trailStart()
        end
    end
    fxWasDown = pick ~= 0

    local dv, dh, ds = 0, 0, 0
    if held(ROCKET_KEY.UP) then dv = dv + 1 end
    if held(ROCKET_KEY.DOWN) then dv = dv - 1 end
    if held(ROCKET_KEY.RIGHT) and not (depth and not turn) then dh = dh + 1 end
    if held(ROCKET_KEY.LEFT) and not (depth and not turn) then dh = dh - 1 end
    if held(ROCKET_KEY.BIGGER) then ds = ds + 1 end
    if held(ROCKET_KEY.SMALLER) then ds = ds - 1 end
    if dv == 0 and dh == 0 and ds == 0 then
        nudgeAt = 0
        return
    end
    local now = GetGameTimer()
    if now < nudgeAt then return end
    -- From when this step was due, not from this frame: client/tunekeys.lua's
    -- ON THE BEAT, which is what makes the hold twenty a second at 60 fps too.
    nudgeAt = nudgeAt + ROCKET_REPEAT_MS
    if nudgeAt <= now then nudgeAt = now + ROCKET_REPEAT_MS end

    if ds ~= 0 and turn then
        passSpeed = clampTo(passSpeed + ds * step.mps, 0.0, 50.0)
    elseif ds ~= 0 then
        if depth then
            look.scale = clampTo(roundTo(F.scaleOf(look) + ds * step.x, 2), 0.1, 100.0)
        else
            look.trailScale = clampTo(roundTo(F.trailScaleOf(look) + ds * step.x, 2), 0.1, 100.0)
        end
    end
    if turn and (dv ~= 0 or dh ~= 0) then
        local rx, ry, rz = F.trailRotOf(look)
        if depth then ry = ry + dv * step.deg else rx = rx + dv * step.deg end
        rz = rz + dh * step.deg
        look.trot = { wrapDeg(roundTo(rx, 2)), wrapDeg(roundTo(ry, 2)), wrapDeg(roundTo(rz, 2)) }
    elseif dv ~= 0 or dh ~= 0 then
        local ox, oy, oz = F.trailOffsetOf(look)
        ox = ox + dh * step.m
        if depth then oz = oz + dv * step.m else oy = oy + dv * step.m end
        look.toff = { clampTo(roundTo(ox, 3), -50.0, 50.0), clampTo(roundTo(oy, 3), -50.0, 50.0),
                      clampTo(roundTo(oz, 3), -50.0, 50.0) }
    end
    sampleApply()
end

--- Start the rocket's pass as the look says. MUST be called from inside a
--- Citizen thread: the model and the trail's asset may stream in.
local function sampleMake()
    local model = loadRocketModel()
    if not model then
        print('[br_core] brrocket: no rocket model would load')
        return
    end
    local tAsset = F.trailFxOf(look)
    if tAsset then RequestNamedPtfxAsset(tAsset) end
    local ped = PlayerPedId()
    local p = GetEntityCoords(ped)
    local h = math.rad(tonumber(GetEntityHeading(ped)) or 0.0)
    -- Ahead is your heading; the pass runs to your right across it.
    local fx, fy = -math.sin(h), math.cos(h)
    local ux, uy = math.cos(h), math.sin(h)
    local x = p.x + fx * PASS_AHEAD_M - ux * PASS_LENGTH_M / 2
    local y = p.y + fy * PASS_AHEAD_M - uy * PASS_LENGTH_M / 2
    local z = p.z + 1.0
    local obj = CreateObjectNoOffset(model, x, y, z, false, false, false)
    local carrier = CreateObjectNoOffset(model, x, y, z, false, false, false)
    if not obj or obj == 0 or not carrier or carrier == 0 then
        removeEnt(obj)
        removeEnt(carrier)
        print('[br_core] brrocket: the game would not make the rocket')
        return
    end
    for _, e in ipairs({ obj, carrier }) do
        SetEntityCollision(e, false, false)
        FreezeEntityPosition(e, true)
        aim(e, ux, uy, 0.0)
    end
    SetEntityAlpha(carrier, 0, false)
    sample = { obj = obj, carrier = carrier, model = model, ux = ux, uy = uy,
               x0 = x, y0 = y, z0 = z, run = 0.0, lastMs = GetGameTimer(), lap = 0 }
    look.model = model
    BR.Native.propScale(obj, F.scaleOf(look))
    local waited = 0
    while tAsset and not isTrue(HasNamedPtfxAssetLoaded(tAsset)) and waited < 3000 do
        Citizen.Wait(50)
        waited = waited + 50
    end
    if not sample or sample.obj ~= obj then return end   -- put away while it waited
    sample.lastMs = GetGameTimer()
    trailStart()
    keysLoop = BR.Loop.register(BR.Loop.FRAME, 'terminalfx.rocketkeys', rocketKeys)
    print('[br_core] brrocket: a rocket flying a slow pass 7 m in front of you, again and again. The keys:')
    print('  LEFT / RIGHT             trail across the rocket (x)')
    print('  UP / DOWN                trail along it (y)')
    print('  CTRL + UP / DOWN         trail up and down (z)')
    print('  ALT + UP / DOWN          trail pitch    ALT + LEFT / RIGHT   trail yaw')
    print('  ALT + CTRL + UP / DOWN   trail roll')
    print('  PAGE UP / DOWN           trail size     CTRL + PAGE UP / DOWN   rocket size')
    print('  CTRL + LEFT / RIGHT      the effect     ALT + PAGE UP / DOWN    the pass speed (0 stands still)')
    print('  hold SHIFT               bigger steps   DELETE   the art\'s numbers')
    print('  `brterminal run airstrike` fires one drawn this way; `brrocket` again puts it away')
end

RegisterCommand('brrocket', function()
    if sample then
        look.model = sample.model
        local ox, oy, oz = F.trailOffsetOf(look)
        local rx, ry, rz = F.trailRotOf(look)
        print('[br_core] brrocket: put away. A strike drawn this way:')
        print('  ' .. F.rocketLine(look))
        print('  or paste into br_lib/config/terminals.lua, art.rocket:')
        local tA, tN = F.trailFxOf(look)
        print(('      scale = %g, trailScale = %g, trailAsset = \'%s\', trail = \'%s\','):format(
            F.scaleOf(look), F.trailScaleOf(look), tostring(tA), tostring(tN)))
        print(('      trailOffset = { %g, %g, %g }, trailRot = { %g, %g, %g },')
            :format(ox, oy, oz, rx, ry, rz))
        sampleClear()
        return
    end
    if making then return end
    making = true
    Citizen.CreateThread(function()
        sampleMake()
        making = false
    end)
end, false)

AddEventHandler('onResourceStop', function(name)
    if name ~= GetCurrentResourceName() then return end
    clearFuzz()
    for _, s in pairs(strikes) do dropStrike(s) end
    sampleClear()
end)
