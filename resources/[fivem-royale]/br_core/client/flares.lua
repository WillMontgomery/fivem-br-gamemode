-- The airdrop's flares: one place that knows how to light one, and where they
-- go while the crate falls and after it has landed.
--
-- ═══ WHY THIS IS ITS OWN FILE, ON THE THIRD ATTEMPT ═══
--
-- The flares now have to exist in TWO places that have nothing to do with each
-- other. While the crate falls they hang off client/airdrop.lua's solver, a
-- pure function of the published record and the synced clock. Once it has
-- landed the box is an ordinary loot registry entry owned by client/loot.lua,
-- streamed in and out with every other crate on the map and re-skinned in place
-- when somebody opens it (owner, 2026-08-22: "there should be flares on the
-- husk too").
--
-- Two copies of "light a flare" is how the two ends come to disagree about
-- which route, which weapon and which particle -- on a feature whose entire
-- history is that nobody could tell which of those was wrong.
--
-- ═══ THE FLARE IS A PROJECTILE. THAT IS THE WHOLE OF THE THIRD ATTEMPT. ═══
--
-- The first two attempts looked for a model that glows and there is no such
-- model. Every visual a flare has -- fuse, trail, light, corona, flicker --
-- lives in `AMMO_FLARE`'s CAmmoThrownInfo and is applied by the projectile
-- controller; `w_am_flare` is only the drawable the projectile wears. So we
-- fire a real one, in place, exactly as the owner's reference does. See
-- br_lib/config/airdrop.lua for the evidence and for the two objections this
-- had to answer first.
--
-- ═══ AND NOTHING HERE IS NETWORKED, SIMULATED, OR OURS TO DELETE ═══
--
-- The object route is CreateObjectNoOffset with isNetwork = false, collision
-- off, frozen, moved only by arithmetic -- the same rule as every other object
-- this gamemode creates. The projectile route creates no entity of ours at all:
-- the engine makes it, the engine expires it on AMMO_FLARE's own 62.5s clock,
-- and its replication is refused server-side rather than tolerated. There is
-- nothing here for two machines to disagree about.

BR = BR or {}
BR.Flare = BR.Flare or {}

--- IN LUA 0 IS TRUTHY, AND A FIVEM NATIVE DECLARED BOOL MAY ANSWER 1 RATHER
--- THAN true. This project has shipped that six times. Every native BOOL read
--- in this file goes through here.
--- @param v any
--- @return boolean
local function isTrue(v)
    return v ~= nil and v ~= false and v ~= 0
end

--- Is this a looped-particle handle that is actually running?
---
--- ═══ THE ONLY OBSERVABLE THE WHOLE FEATURE HAS, AND ONLY ON ONE ROUTE ═══
---
--- A looped ptfx can be asked whether it is alive. A fired projectile cannot be
--- asked anything at all -- there is no handle, no native that reports one, and
--- no flare-named native anywhere in the native DB. That asymmetry is the only
--- reason the object route survives: it is the route that can answer a
--- question.
---
--- THE FAILURE VALUE IS -1, NOT 0, AND CHECKING FOR 0 SHIPPED A LIE. Cfx's own
--- ParticleEffect wrapper documents the handle as "-1 when this ParticleEffect
--- is not active" and stores it only if `Handle ~= -1 and
--- DoesParticleFxLoopedExist(Handle)`. So there are TWO ways to fail: the
--- sentinel, and a handle that is neither sentinel and still dead.
---
--- BOTH SENTINELS ARE REFUSED. Cfx's looped wrapper compares against -1 while
--- its non-looped one compares `> 0`, so the engine's own bindings disagree
--- about which number means failure. Treating either as a handle is a guess
--- with a known cost; refusing both costs at most one improbable legitimate
--- zero. DoesParticleFxLoopedExist is guarded so a build without it degrades to
--- the sentinel test rather than erroring.
--- @param fx any
--- @return boolean
function BR.Flare.live(fx)
    if fx == nil or fx == false then return false end
    if fx == -1 or fx == 0 then return false end
    if DoesParticleFxLoopedExist then
        return isTrue(DoesParticleFxLoopedExist(fx))
    end
    return true
end

--- @return table  BR.Config.Airdrop, never nil
local function cfg()
    return BR.Config.Airdrop or {}
end

--- Which route is in force. Anything unrecognised is 'projectile', because a
--- typo in a config value must not silently disable the feature the owner is
--- trying to look at.
--- @return string
local function route()
    return cfg().flareRoute == 'object' and 'object' or 'projectile'
end

-- ---------------------------------------------------------------------------
-- Streaming
-- ---------------------------------------------------------------------------

--- Load a model, bounded. Returns false rather than blocking forever on a name
--- that is not a model at all.
--- @param model integer
--- @return boolean
local function loadModel(model)
    if not isTrue(IsModelValid(model)) then return false end
    RequestModel(model)
    local waited = 0
    while not isTrue(HasModelLoaded(model)) and waited < 5000 do
        Citizen.Wait(50)
        waited = waited + 50
    end
    return isTrue(HasModelLoaded(model))
end

--- Stream a weapon asset, bounded.
---
--- ═══ RequestWeaponAsset, NOT RequestModel, AND THAT IS A REAL BUG FIX ═══
---
--- A cfx.re thread on this exact symptom (the weapon native answering nothing)
--- was resolved by requesting the WEAPON ASSET rather than the model; the
--- reference resources all do it and the crate-drop one carries the comment
--- "flare won't spawn later in the script if we don't request it right now".
---
--- THE WAIT LOOP CONTAINS A Citizen.Wait AND A BOUND. Two of the three
--- reference resources spin on `while not HasWeaponAssetLoaded(...) do end`
--- with a Wait inside; without the Wait the client hangs, and without the bound
--- a name that is not a weapon hangs it just as hard. Same shape as every other
--- streaming wait in this project.
--- @param hash integer
--- @return boolean
local function loadWeapon(hash)
    if not RequestWeaponAsset or not HasWeaponAssetLoaded then return false end
    if isTrue(HasWeaponAssetLoaded(hash)) then return true end
    local A = cfg()
    RequestWeaponAsset(hash, A.flareAssetP1 or 31, A.flareAssetP2 or 26)
    local waited = 0
    while not isTrue(HasWeaponAssetLoaded(hash)) and waited < 5000 do
        Citizen.Wait(50)
        waited = waited + 50
    end
    return isTrue(HasWeaponAssetLoaded(hash))
end

--- Stream a named particle asset, bounded. A missing trail costs the flares
--- their smoke and must not cost the match its airdrop.
--- @param asset string|nil
--- @return boolean
local function loadPtfx(asset)
    if type(asset) ~= 'string' or asset == '' then return false end
    if isTrue(HasNamedPtfxAssetLoaded(asset)) then return true end
    RequestNamedPtfxAsset(asset)
    local waited = 0
    while not isTrue(HasNamedPtfxAssetLoaded(asset)) and waited < 5000 do
        Citizen.Wait(50)
        waited = waited + 50
    end
    return isTrue(HasNamedPtfxAssetLoaded(asset))
end

-- ---------------------------------------------------------------------------
-- The projectile route
-- ---------------------------------------------------------------------------

--- How many flares this client has lit, and how many attempts failed. Read by
--- /brflare and /brairdrop, because a projectile has no handle and this counter
--- is the ONLY evidence anywhere that the call was made.
BR.Flare.fired  = 0
BR.Flare.failed = 0

--- The weapon hash, resolved and cached. Cached because the answer cannot
--- change within a session and the asset stream is not free.
local weaponHash, weaponReady, weaponTried = nil, false, false

--- @return integer|nil
local function flareWeapon()
    if weaponTried then return weaponReady and weaponHash or nil end
    weaponTried = true

    local name = cfg().flareWeapon
    if type(name) ~= 'string' or name == '' then
        print('[br_core] flares: no flareWeapon configured')
        return nil
    end
    weaponHash = GetHashKey(name)
    weaponReady = loadWeapon(weaponHash)
    if not weaponReady then
        print(('[br_core] flares: weapon asset %s WOULD NOT LOAD -- no flares '
               .. 'will be lit. Try /brflare route object.'):format(name))
        return nil
    end
    return weaponHash
end

--- Light one flare at (x, y, z), standing still.
---
--- ═══ THE 1e-4 SEPARATION IS THE TECHNIQUE, NOT A ROUNDING ARTEFACT ═══
---
--- SHOOT_SINGLE_BULLET_BETWEEN_COORDS fires from one point toward another, and
--- a projectile is ballistic -- which is the objection this file refused the
--- projectile route over twice. With the two points effectively coincident
--- there is no direction to travel in, so the flare stays where it was put.
---
--- AND IT MUST NOT BE ZERO. The crate-drop reference records in its own comment
--- that a flare fired with IDENTICAL coordinates "remains static and won't
--- remove itself later" -- so the engine's own expiry, which is the only reason
--- we are allowed to create something we hold no handle to, depends on this
--- being non-zero.
---
--- ownerPed IS 0, which is what the crate-drop resource passes: this flare
--- belongs to nobody, so nothing it does can be attributed to a player by the
--- damage pipeline. Damage is 0 and DamageType on AMMO_FLARE is NONE anyway.
--- @param x number
--- @param y number
--- @param z number
--- @return boolean
function BR.Flare.fire(x, y, z)
    if not ShootSingleBulletBetweenCoords then
        BR.Flare.failed = BR.Flare.failed + 1
        return false
    end
    local hash = flareWeapon()
    if not hash then
        BR.Flare.failed = BR.Flare.failed + 1
        return false
    end

    local A = cfg()
    local e = A.flareEpsilon or 0.0001

    -- pcall, because this is the one native here whose argument list this
    -- project has never executed. A wrong arity must degrade to a counted
    -- failure rather than throw on the render loop, where the loop registry
    -- suspends the whole airdrop after five errors.
    local ok, err = pcall(ShootSingleBulletBetweenCoords,
        x, y, z,
        x - e, y - e, z - e,
        0,                      -- damage
        false,                  -- p7 / pureAccuracy
        hash,
        0,                      -- ownerPed: nobody
        true,                   -- isAudible
        false,                  -- isInvisible
        A.flareSpeed or -1.0)

    if not ok then
        BR.Flare.failed = BR.Flare.failed + 1
        if not BR.Flare._warnedFire then
            BR.Flare._warnedFire = true
            print(('[br_core] flares: ShootSingleBulletBetweenCoords threw '
                   .. '(%s) -- try /brflare route object'):format(tostring(err)))
        end
        return false
    end

    BR.Flare.fired = BR.Flare.fired + 1
    return true
end

-- ---------------------------------------------------------------------------
-- The object route
-- ---------------------------------------------------------------------------

--- The configured model, resolved and cached for the session.
---
--- ONE NAME. The second attempt's fallback chain is gone: it took the first of
--- three candidates that would load and printed which, which meant "the client
--- is using the model you configured" stopped being true. `flareAlternatives`
--- is a list /brflare prints and nothing else reads.
--- @return integer|nil model
--- @return string|nil name
local resolvedModel, resolvedName, resolveTried = nil, nil, false
local function flareModel()
    if resolveTried then return resolvedModel, resolvedName end
    resolveTried = true

    local name = cfg().flareModel
    if type(name) ~= 'string' or name == '' then
        print('[br_core] flares: no flareModel configured')
        return nil, nil
    end

    local m = GetHashKey(name)
    if not loadModel(m) then
        print(('[br_core] flares: model %s WOULD NOT LOAD. That is how the '
               .. '2026-08-21 flares shipped invisible -- run /brflare.')
            :format(name))
        return nil, nil
    end

    resolvedModel, resolvedName = m, name
    return m, name
end

--- Drop every cached answer, so the next flare resolves them again. Called on
--- resource stop and by /brflare after it edits the live config -- a restart is
--- a new session and the config may have been edited across it, which is the
--- reason anybody restarts a resource while tuning this.
function BR.Flare.forget()
    resolvedModel, resolvedName, resolveTried = nil, nil, false
    weaponHash, weaponReady, weaponTried = nil, false, false
    BR.Flare._warnedFire = nil
    BR.Flare._warnedFx   = nil
end

--- Build one object-route flare at (x, y, z): the prop, and the emitter on it.
---
--- BOTH HALVES ARE BEST-EFFORT and neither missing may cost us the drop. The
--- particle is anchored to the PROP rather than started at a coordinate, so the
--- emitter rides the fall while the smoke it has already made stays where it
--- was made -- which is what a trail is.
--- @param x number
--- @param y number
--- @param z number
--- @return table|nil  { obj, fx }
function BR.Flare.make(x, y, z)
    local A = cfg()
    local model = flareModel()
    if not model then return nil end

    -- `isNetwork = false` is not consistency for its own sake -- `sv_entity-
    -- lockdown relaxed` refuses a client-created networked entity outright, so
    -- any other value is an object that silently never appears for anybody.
    local obj = CreateObjectNoOffset(model, x, y, z, false, false, false)
    if not obj or obj == 0 then return nil end

    -- A flare must not shove anyone and nothing may shove it: its position is
    -- decided by arithmetic, and a collision that moved it would put this
    -- client's flare somewhere no other client's is.
    SetEntityCollision(obj, false, false)
    FreezeEntityPosition(obj, true)
    -- SIZE LAST, because every call above can write the transform matrix and a
    -- scale applied before one of them is silently thrown away (#166).
    BR.Native.propScale(obj, A.flareScale)

    local rec = { obj = obj }

    if A.flarePtfx == true and A.flarePtfxName and loadPtfx(A.flarePtfxAsset) then
        -- USE_PARTICLE_FX_ASSET IS PER CALL, NOT PER SESSION -- its own alias
        -- is _SET_PTFX_ASSET_NEXT_CALL. Immediately before each start, or the
        -- effect resolves against whatever asset was last named.
        UseParticleFxAsset(A.flarePtfxAsset)
        local fx = StartParticleFxLoopedOnEntity(
            A.flarePtfxName, obj,
            0.0, 0.0, 0.0,
            0.0, 0.0, 0.0,
            A.flarePtfxScale or 1.0,
            false, false, false)
        -- STORED ONLY IF IT IS ACTUALLY RUNNING. The failure value is -1, not
        -- 0, and a handle that is neither can still be dead.
        if BR.Flare.live(fx) then
            rec.fx = fx
        elseif not BR.Flare._warnedFx then
            BR.Flare._warnedFx = true
            print(('[br_core] flares: ptfx %s/%s would not start (handle %s) '
                   .. '-- try /brflare')
                :format(tostring(A.flarePtfxAsset), tostring(A.flarePtfxName),
                        tostring(fx)))
        end
    end

    return rec
end

--- Tear one object-route flare down.
---
--- THE PARTICLE HANDLE GOES FIRST, and before the entity it is anchored to. A
--- looped ptfx OUTLIVES the object it was started on -- that is what looped
--- means -- so deleting the prop first leaves an emitter running at the last
--- place it was, for the rest of the session, with nothing holding its handle.
--- @param f table|nil
function BR.Flare.destroy(f)
    if not f then return end
    if f.fx ~= nil then StopParticleFxLooped(f.fx, false) end
    f.fx = nil
    if f.obj and isTrue(DoesEntityExist(f.obj)) then DeleteEntity(f.obj) end
    f.obj = nil
end

--- Put one object-route flare at (x, y, z) facing `heading`.
---
--- AND THE SIZE BACK, EVERY TIME, because SetEntityHeading is a matrix write
--- and a matrix write resets the axis vectors to unit length -- which is where
--- the scale lives (#166). Without this a flare is 4x for exactly one frame and
--- authored size for the rest of the descent.
--- @param f table|nil
--- @param x number
--- @param y number
--- @param z number
--- @param heading number|nil
function BR.Flare.place(f, x, y, z, heading)
    if not f or not f.obj then return end
    if not isTrue(DoesEntityExist(f.obj)) then return end
    SetEntityCoords(f.obj, x, y, z, false, false, false, false)
    if heading then SetEntityHeading(f.obj, heading) end
    BR.Native.propScale(f.obj, cfg().flareScale)
end

-- ---------------------------------------------------------------------------
-- Sites
-- ---------------------------------------------------------------------------
--
-- A SITE IS "SOMETHING THAT WANTS FLARES AT MOVING POSITIONS", and there are
-- exactly two: the falling crate and the landed box. They differ in what they
-- ask for and in nothing else, so the route logic lives here once rather than
-- in client/airdrop.lua and in the landed pass separately.
--
--   projectile  fire at each position when the refire clock is due, and hold
--               nothing. The engine owns what it made.
--   object      build a pair once and write their coordinates every update.

--- @return table
function BR.Flare.newSite()
    return { flares = nil, nextAt = 0, lit = 0 }
end

--- Every object this site holds goes away. A no-op on the projectile route,
--- which holds nothing -- and that asymmetry is the point: there is no path
--- here that deletes something the engine owns.
--- @param site table|nil
function BR.Flare.clearSite(site)
    if not site then return end
    for _, f in ipairs(site.flares or {}) do BR.Flare.destroy(f) end
    site.flares = nil
    site.nextAt = 0
end

--- Put this site's flares where `positions` says, this pass.
---
--- @param site table
--- @param now number      GetGameTimer, not the synced clock -- a refire cadence
---                        is a local presentation rhythm and must not lurch when
---                        the clock estimate is corrected.
--- @param refireMs number  how often the projectile route lights a new one
--- @param positions table  array of { x, y, z, h }
function BR.Flare.updateSite(site, now, refireMs, positions)
    if not site or type(positions) ~= 'table' then return end

    if route() == 'projectile' then
        -- NOTHING IS HELD, SO NOTHING IS PLACED. A fired flare stands where it
        -- was lit; the crate falls away from it and a new one is lit further
        -- down, which is what leaves a burning column behind the descent.
        if now < (site.nextAt or 0) then return end
        site.nextAt = now + (refireMs or 3000)
        for _, p in ipairs(positions) do
            if BR.Flare.fire(p.x, p.y, p.z) then
                site.lit = (site.lit or 0) + 1
            end
        end
        return
    end

    if not site.flares then
        local made = {}
        for i, p in ipairs(positions) do
            made[i] = BR.Flare.make(p.x, p.y, p.z)
        end
        -- Only adopted if at least one was actually built, so a site whose
        -- model failed retries on the next pass instead of holding an empty
        -- array forever.
        local any = false
        for _, f in ipairs(made) do if f then any = true end end
        if not any then return end
        site.flares = made
        site.lit = (site.lit or 0) + 1
    end

    for i, p in ipairs(positions) do
        BR.Flare.place(site.flares[i], p.x, p.y, p.z, p.h)
    end
end

--- The two world positions a pair of flares sits at, for a box at (x, y, z)
--- facing `heading`.
---
--- ONE OFFSET, TWO SIGNS, and the sign is the only difference -- both flares on
--- the same side satisfies every distance check and is not what the owner asked
--- for. Rotated by the box's heading so they stay on its left and right faces
--- while it yaws.
--- @param x number
--- @param y number
--- @param z number
--- @param heading number|nil
--- @return table  array of { x, y, z, h }
function BR.Flare.positionsAround(x, y, z, heading)
    local off = cfg().flareOffset or { x = 1.1, y = 0.0, z = 0.0 }
    local a = math.rad(heading or 0.0)
    -- GTA's right vector for a heading. Same convention as BR.AirdropOffsetAt,
    -- which is the half of this that gets written backwards.
    local rx, ry = math.cos(a), math.sin(a)
    local out = {}
    for i, side in ipairs({ 1.0, -1.0 }) do
        local d = (off.x or 1.1) * side
        out[i] = { x = x + rx * d, y = y + ry * d,
                   z = z + (off.z or 0.0), h = heading }
    end
    return out
end

-- ---------------------------------------------------------------------------
-- The pair on the landed box
-- ---------------------------------------------------------------------------

--- The site standing on whatever the airdrop's box currently is.
---
--- `box` is the ENTITY HANDLE it was last placed against, and it is the whole
--- of the carry-over: when a sealed crate becomes its husk the handle changes
--- and nothing in this site is rebuilt, because nothing in it is attached.
local landed = { site = nil, box = nil }

local function dropLanded()
    BR.Flare.clearSite(landed.site)
    landed.site, landed.box = nil, nil
end

--- Keep flares on the airdrop's landed crate, and then on its husk.
---
--- 10Hz RATHER THAN PER FRAME. A landed box only moves when a car hits it, and
--- client/loot.lua's drag pass -- the thing that answers that -- is already on
--- this band.
---
--- COSTS ONE TABLE LOOKUP WHEN THERE IS NO AIRDROP ON THE GROUND, which is most
--- of every match: BR.Loot.airdropBox() reads a cached id rather than walking
--- the registry.
BR.Loop.register(BR.Loop.TICK, 'flares.landed', function()
    local A = cfg()
    if A.flareOnLanded ~= true then
        if landed.site then dropLanded() end
        return
    end

    -- REACHED AT CALL TIME AND NIL-GUARDED. client/loot.lua owns the registry
    -- and is loaded above this file, but a rig that stands this file up alone
    -- must not need it.
    local box = BR.Loot and BR.Loot.airdropBox and BR.Loot.airdropBox() or nil
    if not box or not isTrue(DoesEntityExist(box)) then
        -- THE BOX'S PROP IS STREAMED, AND THIS IS THE WHOLE LIFETIME RULE.
        -- client/loot.lua despawns it past propDistance + propHysteresis and
        -- rebuilds it on the way back; forgetAll() drops it at the end of the
        -- match. Either way the accessor answers nil and the flares go with it,
        -- so there is no second lifetime here that can outlive its box.
        if landed.site then dropLanded() end
        return
    end

    local c = GetEntityCoords(box)
    if not c then return end
    local h = GetEntityHeading(box)

    landed.site = landed.site or BR.Flare.newSite()
    -- ═══ THE BOX CAN CHANGE UNDERNEATH IT, AND THAT IS THE POINT ═══
    --
    -- A sealed crate becoming its husk is a NEW entity handle for the SAME
    -- registry entry. Nothing above rebuilds on that, because nothing here is
    -- attached to the handle -- the flares are written to the new box's
    -- coordinates on the next pass and never notice. `landed.box` is recorded
    -- for the diagnostic and read by nothing else.
    landed.box = box

    BR.Flare.updateSite(landed.site, GetGameTimer(),
        A.flareRefireMs or 45000,
        BR.Flare.positionsAround(c.x, c.y, c.z, h))
end)

--- What the landed pair is doing, for /brflare and /brairdrop.
--- @return table
function BR.Flare.landedStatus()
    local out = { box = landed.box, route = route(),
                  lit = landed.site and landed.site.lit or 0, flares = {} }
    for i, f in ipairs((landed.site or {}).flares or {}) do
        out.flares[i] = { obj = f.obj, fx = f.fx, live = BR.Flare.live(f.fx) }
    end
    return out
end

-- ---------------------------------------------------------------------------
-- The bench
-- ---------------------------------------------------------------------------

--- The last object-route test flare, so a second /brflare replaces rather than
--- litters. A projectile-route test leaves nothing to clear -- the engine
--- expires it -- which is itself worth knowing when reading this command.
local bench = nil

local function clearBench()
    if not bench then return end
    BR.Flare.destroy(bench)
    bench = nil
end

--- Put the flare question on the ground three metres away, and answer every
--- part of it that CAN be answered from inside a running client.
---
--- ═══ WRITTEN AGAIN BECAUSE THIS IS THE THIRD ATTEMPT ═══
---
--- The owner ran the previous version and came back with "you used the wrong
--- flare", which the old output could not quite support: it printed which of
--- three candidates the client had picked, the model was a fallback chain
--- rather than a choice, and there was no way to try anything else without
--- editing a config and restarting.
---
---   /brflare                        light one from the committed config
---   /brflare off                    clear the object-route bench
---   /brflare route projectile|object
---   /brflare weapon <name>          e.g. weapon_flare, weapon_flaregun
---   /brflare model <name>           object route only
---   /brflare ptfx <asset> <name> [scale]     object route only
---
--- EVERY VERB EDITS THE LIVE CONFIG ON THIS CLIENT ONLY -- the server's copy
--- and the committed file are untouched -- and the command prints the lines to
--- paste once something works. That is what "try each without a code change"
--- means here.
RegisterCommand('brflare', function(_, args)
    local A = cfg()
    local verb = args[1] and tostring(args[1]):lower() or nil

    if verb == 'off' then
        clearBench()
        print('[br_core] flare bench cleared (a fired flare is the engine\'s '
              .. 'and expires on its own)')
        return
    end

    if verb == 'route' and args[2] then
        local r = tostring(args[2]):lower()
        if r ~= 'object' and r ~= 'projectile' then
            print('[br_core] flare route must be projectile or object')
            return
        end
        A.flareRoute = r
    elseif verb == 'weapon' and args[2] then
        A.flareWeapon = tostring(args[2])
    elseif verb == 'model' and args[2] then
        A.flareModel = tostring(args[2])
    elseif verb == 'ptfx' and args[2] and args[3] then
        A.flarePtfxAsset = tostring(args[2])
        A.flarePtfxName  = tostring(args[3])
        A.flarePtfxScale = tonumber(args[4]) or A.flarePtfxScale or 1.0
        A.flarePtfx      = true
    elseif verb ~= nil then
        print('[br_core] /brflare [off | route projectile|object | '
              .. 'weapon <name> | model <name> | ptfx <asset> <name> [scale]]')
        return
    end
    BR.Flare.forget()
    clearBench()

    local ped = PlayerPedId()
    local p   = GetEntityCoords(ped)
    local h   = math.rad(GetEntityHeading(ped) or 0.0)
    -- Three metres in front, at chest height: close enough to see a wisp, far
    -- enough that a plume does not fill the screen.
    local x, y, z = p.x - math.sin(h) * 3.0, p.y + math.cos(h) * 3.0, p.z + 1.0

    print('=== flare bench ===')
    print(('  route: %s'):format(route()))

    if route() == 'projectile' then
        local before = BR.Flare.fired
        local hash = flareWeapon()
        print(('  weapon %s -- asset loaded %s')
            :format(tostring(A.flareWeapon), tostring(hash ~= nil)))
        if not hash then
            print('  THE WEAPON ASSET DID NOT LOAD. Nothing was fired. Try '
                  .. '/brflare weapon weapon_flaregun, or /brflare route object.')
            return
        end
        BR.Flare.fire(x, y, z)
        print(('  fired %d (session total %d, failed %d) at %.1f, %.1f, %.1f')
            :format(BR.Flare.fired - before, BR.Flare.fired, BR.Flare.failed,
                    x, y, z))
        -- ═══ THE LINE THAT MATTERS MOST, AND IT IS AN ADMISSION ═══
        --
        -- A projectile has no handle. There is no native that reports whether
        -- one exists, whether its light is on, or whether it rendered -- the
        -- flare is weapons.meta data and projectile behaviour rather than an
        -- API, and there is no flare-named native anywhere in the native DB.
        -- Two attempts have now been reported as "no flares" and both were
        -- reasoned about confidently from outside the game. This is the line
        -- that stops that happening a third time.
        print('  THE CALL WAS MADE. NOTHING HERE CAN CONFIRM IT RENDERED -- a '
              .. 'projectile has no handle and no native reports one. Look at '
              .. 'the ground three metres in front of you and say what you see.')
        print('  it burns for about 60s and expires on its own; nothing is '
              .. 'left for /brflare off to clear.')
    else
        -- WHICH MODELS THIS BUILD EVEN HAS. This is the check that was never
        -- run before 2026-08-21: the shipped name was `prop_flare_01a`, which
        -- is not a model, and nothing anywhere said so.
        print(('  configured model: %s'):format(tostring(A.flareModel)))
        local seen = {}
        for _, n in ipairs(A.flareAlternatives or {}) do
            seen[n] = true
            print(('  %-16s valid %s%s'):format(n,
                tostring(isTrue(IsModelValid(GetHashKey(n)))),
                n == A.flareModel and '   <-- IN USE' or ''))
        end
        if A.flareModel and not seen[A.flareModel] then
            print(('  %-16s valid %s   <-- IN USE'):format(A.flareModel,
                tostring(isTrue(IsModelValid(GetHashKey(A.flareModel))))))
        end

        local f = BR.Flare.make(x, y, z)
        if not f then
            print('  THE MODEL DID NOT LOAD. That is the answer, and it is the '
                  .. 'whole 2026-08-21 bug. Nothing below matters until '
                  .. '/brflare model <name> names a real object.')
            return
        end
        bench = f
        print(('  prop %s at x%.2f'):format(tostring(f.obj), A.flareScale or 1.0))

        if A.flarePtfx ~= true then
            print('  emitter: OFF (flarePtfx = false)')
        elseif f.fx then
            print(('  emitter %s / %s at x%.2f -- handle %s, LIVE')
                :format(tostring(A.flarePtfxAsset), tostring(A.flarePtfxName),
                        A.flarePtfxScale or 1.0, tostring(f.fx)))
            print('  a LIVE handle means our smoke is running. It does NOT '
                  .. 'mean the prop glows -- no model does, which is why the '
                  .. 'projectile route is the default.')
        else
            print(('  emitter %s / %s -- DEAD. The effect did not start: the '
                   .. 'name is not an effect in that asset, or it is not '
                   .. 'loopable.'):format(tostring(A.flarePtfxAsset),
                                          tostring(A.flarePtfxName)))
        end
        print('  /brflare off to clear it')
    end

    print('  paste into br_lib/config/airdrop.lua:')
    print(('    flareRoute     = \'%s\','):format(route()))
    print(('    flareWeapon    = \'%s\','):format(tostring(A.flareWeapon)))
    print(('    flareModel     = \'%s\','):format(tostring(A.flareModel)))
    print(('    flarePtfxAsset = \'%s\','):format(tostring(A.flarePtfxAsset)))
    print(('    flarePtfxName  = \'%s\','):format(tostring(A.flarePtfxName)))
end, false)

-- An un-deleted local object outlives the resource that made it -- and the
-- cached model and weapon go with it, because a restart is a new session and
-- the config may have been edited across it.
AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    clearBench()
    dropLanded()
    BR.Flare.forget()
    BR.Flare.fired, BR.Flare.failed = 0, 0
end)
