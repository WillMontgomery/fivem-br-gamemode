-- The world override on a client, and the ONE place this client's sky is set.
--
-- Owner, 2026-08-31: "can you make me a brtime command on the server which will
-- set the time in-game? Recall we have the game locked at noon right now. Also I
-- want one for brweather too."
--
-- ═══ THE CLOCK IS NOT HERE, AND THAT IS THE DESIGN ═══
--
-- client/natives.lua owns the clock (BR.Native.applyClock): it holds the lobby
-- and the warmup pad still at noon and runs the match from its anchor (#394),
-- and anything this file did to the clock would undo that or be undone by it.
-- So nothing here touches it. The writer asks BR.World.clockPlan(), which
-- answers the override first -- one writer, told a different time.
--
-- ═══ THE SKY IS HERE, AND IT DID NOT USED TO BE ANYWHERE ═══
--
-- Weather was written from two places before this file existed:
--
--   client/storm.lua                THUNDER when the ring catches you outside,
--                                   EXTRASUNNY when it lets you go, plus a
--                                   drying snap and a release at match end.
--   br_environment/client/ipl.lua   OVERCAST over the lobby island, and a
--                                   ten-second clear to EXTRASUNNY as the bus
--                                   climbs out -- the haze is what hides the
--                                   island/mainland swap mid-flight.
--
-- Neither knows about the other and neither could have been made to yield to a
-- console override on its own: an override that both of them overwrote would
-- last until the next storm tier or the next island flip, and an override that
-- overwrote THEM would leave the sky wherever the console left it once it was
-- released. Both of those are "two writers disagreeing", which is the defect
-- this project keeps paying for.
--
-- SO THE TWO OF THEM STOPPED WRITING AND STARTED CLAIMING. Each says what it
-- WANTS the sky to be; this file resolves the claims by BR.World.SKY_SOURCES
-- priority and writes the winner. That makes the release case fall out for free:
-- lifting the override does not have to guess what the sky should go back to,
-- because the claim underneath it is still sitting in the table.
--
-- THE ISLAND IS IN ANOTHER RESOURCE, SO ITS CLAIM ARRIVES AS AN EVENT. Client
-- events cross resources (br_core/client/bus.lua already triggers
-- 'br:env:releaseIsland' into br_environment), so ipl.lua triggers
-- 'br:world:island' into here. The handshake at the bottom of this file covers
-- the start order in which its first announcement would otherwise be lost.
--
-- ═══ THE FESTIVE SKY (#399) ═══
--
--   "yes snow is meant to reach the players"         -- owner, 2026-10-05
--
-- December and January, on the festive crates' switch, everywhere. The storm's
-- all-clear and the island's skies are ROLES now (`base`, `lobby`, `cover`;
-- br_lib/shared/world.lua's SKY_ROLE), and this file reads each as a weather
-- for the one fact the server sends, BR.World.festive: the clear sky is XMAS
-- instead of EXTRASUNNY, the lobby XMAS instead of OVERCAST, and the bus climb
-- keeps its OVERCAST cover. THUNDER is THUNDER and a console sky is the
-- console's. Not festive, every role is the weather it always was.
--
-- AND IN A MATCH THE CLEAR SKY CYCLES (#399; owner, 2026-10-06: "The match
-- weather can cycle between snow, snowlight, xmas and blizzard during the
-- months of December and January"). The server draws the match's weather and
-- tells this client each one once (BR.World.cycle, the "cycle" section at the
-- bottom); the `base` role reads it, so whatever outranks the clear sky -- the
-- storm's THUNDER, a console sky, Time & weather's weather -- still does, and
-- leaving the storm comes back to the weather the match is on now.

-- ---------------------------------------------------------------------- sky ---

--- What each source currently wants. Absent means "no claim". `terminal` is
--- Control Tower's Time & weather (#396, wave B), claimed by
--- client/terminalfx/time_weather.lua only while this client's view is inside
--- the circle, below the storm and above the island (shared/world.lua's
--- SKY_SOURCES; a role claimed above it yields to the weather it names).
local claims = { override = nil, storm = nil, terminal = nil, island = nil }

--- The weather name the engine was last handed by this file, or nil if the last
--- thing it was handed was ClearWeatherTypePersist.
---
--- COMPARED BEFORE EVERY WRITE, because the claims are pushed from a 10Hz storm
--- tick and from an override envelope, and re-asserting the same weather blend
--- restarts it -- a sky that never finishes arriving.
local wrote = nil

--- When the blend this file last started finishes arriving (GetGameTimer
--- milliseconds), or nil if the last write was a snap or a clear.
---
--- KEPT BECAUSE THE CLEAR SKY CAN MOVE NOW (#399). A forced write snaps, and
--- the only one there is -- client/storm.lua's drying snap -- was timed to land
--- as its own five-second blend ended, when the snap is a visual no-op. A turn
--- of the festive match's cycle (thirty seconds) or a `brfestive` blend (ten)
--- can start in that window, and the snap would jump the rest of the way in one
--- frame. So no forced write is honored while a blend is still arriving
--- (BR.World.want), and the drying schedule asks BR.World.arrivesAt() when the
--- sky will have arrived before it resets the rain.
local arriveAt = nil

-- ═══ THE WHITE GROUND IS WRITTEN HERE TOO, BESIDE THE WEATHER (#399) ═══
--
-- A snow weather changes the sky, the wind and the particles; the snow ON THE
-- GROUND is a separate render pass. So this file turns that pass on while the
-- sky it writes is a snow weather (BR.World.snowGround: XMAS, SNOWLIGHT, SNOW,
-- BLIZZARD -- `brweather XMAS` included), and off under every other sky -- the
-- bus's overcast cover and the storm's THUNDER in the festive months too. The
-- resolved weather decides it and nothing else. Written on change only:
-- nothing here runs per frame or per tick.
--
-- THE RECIPE, FOR GAME BUILD 3889:
--
--   _FORCE_GROUND_SNOW_PASS (0x6E9EF3A33C8899F8, R*'s own since build 3095,
--   by hash: FiveM's Lua has no name for it). NOT Cfx's FORCE_SNOW_PASS, which
--   legacy vMenu's WeatherSync calls: it works by hooking the engine's weather
--   name lookup, it crashed clients on build 3258 until patched, and vMenu
--   Enhanced's author dropped it in 2026 because it breaks weather transitions
--   -- and this file's sky is transitions (the storm's THUNDER and back).
--   SetForceVehicleTrails / SetForcePedFootstepsTracks: tire and footprint
--   tracks in the snow (R*'s USE_SNOW_WHEEL/FOOT_VFX_WHEN_UNSHELTERED).
--   core_snow: the particle asset those tracks' snow puffs come from, requested
--   while the pass is on and released when it goes off, as both vMenus do.
--
-- The flag is the ENGINE's and outlives this resource, so a stop turns it off.
local SNOW_PASS = 0x6E9EF3A33C8899F8
local SNOW_FX   = 'core_snow'
local groundSnow = false

--- @param on boolean
local function setGround(on)
    if on == groundSnow then return end
    groundSnow = on
    Citizen.InvokeNative(SNOW_PASS, on)
    SetForceVehicleTrails(on)
    SetForcePedFootstepsTracks(on)
    if on then
        RequestNamedPtfxAsset(SNOW_FX)
    else
        RemoveNamedPtfxAsset(SNOW_FX)
    end
end

--- Write whatever wins, if it is not what the engine already has.
---
--- A ROLE IS READ HERE, FOR THE FESTIVE SKY (#399). The island and the storm
--- claim the clear sky as `base` and the lobby's as `lobby` (shared/world.lua's
--- SKY_ROLE), and resolveSky reads each as a weather for BR.World.festive, the
--- server's one fact this client holds. Not festive, every role is the weather
--- it always was, so `wrote` sees the same names as before and writes the same.
---
--- THE GROUND FOLLOWS THE SKY: off before a weather without snow is written,
--- on after one with it, decided by the resolved name alone. It is decided
--- whether or not the weather is written, so it can never drift from the name
--- on screen; setGround writes only when it moves.
--- @param force boolean|nil  write even if the winner is unchanged
--- @param blendOver number|nil  blend over this many seconds instead of the claim's
local function push(force, blendOver)
    local name, blend = BR.World.resolveSky(claims, BR.World.isFestive(),
                                            BR.World.cycleNow())

    if name == nil then
        setGround(false)
        -- NOBODY WANTS THE SKY. Hand it back to the engine rather than picking
        -- a default: this is the state a match ends in and GTA's own weather is
        -- the right thing to be standing under between rounds.
        if wrote ~= nil then
            wrote, arriveAt = nil, nil
            ClearWeatherTypePersist()
        end
        return
    end

    local snow = BR.World.snowGround(name)
    if not snow then setGround(false) end

    if name ~= wrote or force then
        wrote = name
        if blendOver then blend = blendOver end

        if blend and blend > 0.0 then
            SetWeatherTypeOvertimePersist(name, blend + 0.0)
            arriveAt = GetGameTimer() + blend * 1000.0
        else
            SetWeatherTypeNowPersist(name)
            arriveAt = nil
        end
    end

    if snow then setGround(true) end
end

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    setGround(false)
end)

--- Claim the sky, or release a claim by passing nil.
---
--- THE SOURCE IS CHECKED AGAINST THE PRIORITY LIST rather than trusted. A typo
--- would otherwise store an unranked key that resolveSky walks straight past --
--- a claim that never wins, never errors and never gets noticed.
--- @param source string  a member of BR.World.SKY_SOURCES
--- @param name string|nil  a weather name, or nil to release
--- @param blend number|nil seconds to blend over; 0 or nil snaps
--- @param force boolean|nil  write even if the resolved winner is unchanged --
---                           once no blend is still arriving
function BR.World.want(source, name, blend, force)
    if not BR.World.SKY_SOURCE[source] then
        print(('[br_core] world: %s is not a sky source'):format(tostring(source)))
        return
    end
    claims[source] = name and { name = name, blend = blend } or nil

    -- THE RAIN KNOB COMES BACK WITH A CHOSEN WEATHER (#396, wave B), as it does
    -- with the console's (applyOverride, below): the storm's drying schedule may
    -- have pinned SetRainLevel(0.0) a moment before Time & weather's RAIN took
    -- the sky, and only the storm's own sky on screen ever hands it back -- so
    -- the RAIN a player chose would fall dry. A role claimed by the terminal (its
    -- clear sky) is the base sky's and leaves the knob alone.
    if source == 'terminal' and name and not BR.World.SKY_ROLE[name] then SetRainLevel(-1.0) end

    -- A FORCED WRITE IS ONLY THE WINNER'S TO ASK FOR. storm.lua's drying snap
    -- forces because re-writing the same weather is what hard-resets the
    -- engine's rain memory -- but that is a claim about the sky the storm is
    -- showing, and while a console override is on screen the storm is not
    -- showing one. Honouring the flag regardless would have a yielding source
    -- re-assert somebody else's sky for a reason that has nothing to do with it,
    -- which is a small thing that makes "the storm writes nothing while an
    -- override holds" untrue.
    --
    -- AND NEVER OVER A SKY STILL ARRIVING (#399). The force snaps, and a snap
    -- of the weather a blend is still carrying the sky to cuts the blend short
    -- -- the rest of a cycle turn's thirty seconds in one frame. While a blend
    -- is running the force is dropped and the claim is recorded as any other;
    -- the drying snap waits for the blend (client/storm.lua).
    local _, winner = BR.World.sky()
    push(force == true and winner == source and BR.World.arrivesAt() == nil)
end

--- When the sky on screen finishes arriving: the GetGameTimer millisecond its
--- blend ends, or nil if it already has (or was snapped). Read by
--- BR.World.want above and by client/storm.lua's drying schedule.
--- @return number|nil
function BR.World.arrivesAt()
    if arriveAt ~= nil and GetGameTimer() < arriveAt then return arriveAt end
    return nil
end

--- What the sky resolves to right now, and which claim is showing it.
---
--- Read by BR.World.want above (to decide whether a forced write is the
--- forcer's to ask for), by client/storm.lua's drying schedule (its rain writes
--- wait for the storm to be on screen, #399) and by tools/test_shared.lua. The
--- name is the weather written: a role claimed is already read for the festive
--- sky and the match's cycle. No console verb reads it:
--- if one ever should, it belongs beside the others in server/debug.lua rather
--- than as a second command here.
--- @return string|nil name, string|nil source
function BR.World.sky()
    local name, _, src = BR.World.resolveSky(claims, BR.World.isFestive(),
                                             BR.World.cycleNow())
    if name == nil then return nil, nil end
    return name, src
end

-- ----------------------------------------------------------------- override ---

--- Fold the override into the claim table and apply it.
---
--- AND THE FESTIVE SKY, WHICH RIDES THE SAME PAYLOAD (#399). When only it moved
--- -- `brfestive`, a `brseason` switch, the first of December -- the sky under
--- every claim changes at once, and it BLENDS (BR.Config.World.festiveBlendSec)
--- rather than snapping: a whole server watching the island turn white. A
--- console sky that changed in the same payload keeps its own snap.
--- @param festiveMoved boolean|nil
local function applyOverride(festiveMoved)
    local wx = BR.World.weatherName()
    local overrideMoved = (claims.override and claims.override.name) ~= wx
    claims.override = wx and { name = wx, blend = 0.0 } or nil

    -- THE RAIN KNOB COMES BACK WITH THE SKY. client/storm.lua's drying schedule
    -- pins SetRainLevel(0.0) for forty-five seconds after a storm clears -- its
    -- documented job, and the fix for a ground that stayed shiny -- and rain
    -- level 0 makes `brweather RAIN` a completely dry rainstorm. Handing the
    -- knob back (-1.0) as the override takes the sky is the smallest thing that
    -- makes the chosen weather look like itself.
    --
    -- IT IS NOT HANDED BACK ON RELEASE, on purpose: the storm's schedule is a
    -- pair of deadlines that will have moved on by then, and re-imposing a
    -- number this file does not own would be exactly the second writer the rest
    -- of this file exists to avoid.
    if wx then SetRainLevel(-1.0) end

    if festiveMoved and not overrideMoved then
        push(false, BR.Config.World.festiveBlendSec + 0.0)
    else
        push()
    end
end

-- THE WHOLE OVERRIDE ARRIVES EVERY TIME, and a field that is not in it is the
-- reset -- see BR.World.payload. Sent to everyone when it changes, and to one
-- client on br:ready, which is what a late joiner gets.
RegisterNetEvent(BR.Net.WORLD_SET)
AddEventHandler(BR.Net.WORLD_SET, function(p)
    local wasFestive = BR.World.isFestive()
    BR.World.applyPayload(p)
    applyOverride(BR.World.isFestive() ~= wasFestive)
end)

-- -------------------------------------------------------------------- cycle ---

-- ═══ THE FESTIVE MATCH SKY'S CYCLE (#399) ═══
--
-- The weather this client's match is on, held in BR.World.cycle and read by the
-- `base` role alone (shared/world.lua's CYCLE_ROLE). The server sends it, once
-- per change, on three roads:
--
--   STATE        `sky` on every state event: the first weather with PLAYING,
--                none with WARMUP and BUS (a new match starts under XMAS).
--   WORLD_CYCLE  each turn after that, and the stop when the festive sky goes
--                off mid-match.
--   SNAPSHOT     `sky` in the match view, for a client that (re)loads mid-match.
--
-- ENDED MOVES NOTHING. The server stops turning when the match leaves PLAYING
-- and its ENDED event carries the same weather; the digest's local replay of
-- ENDED carries none, and must not take the sky off a verdict screen.
--
-- A NEW WEATHER BLENDS IN OVER BR.Config.Festive.cycle.blendSec, and only if it
-- is what the sky resolves to: under the storm's THUNDER, a console sky or
-- Time & weather's weather, the claim above it is still on screen, nothing is
-- written, and the base role comes back to whatever the cycle shows by then.

--- Take the match's cycle weather (nil: none) and turn the sky if it moved.
--- @param name string|nil
local function followCycle(name)
    local was = BR.World.cycleNow()
    BR.World.setCycle(name)
    if BR.World.cycleNow() == was then return end
    push(false, BR.Config.Festive.cycle.blendSec + 0.0)
end

RegisterNetEvent(BR.Net.WORLD_CYCLE)
AddEventHandler(BR.Net.WORLD_CYCLE, function(d)
    followCycle(type(d) == 'table' and d.weather or nil)
end)

RegisterNetEvent(BR.Net.STATE)
AddEventHandler(BR.Net.STATE, function(d)
    if type(d) ~= 'table' or d.state == BR.MatchState.ENDED then return end
    followCycle(d.sky)
end)

RegisterNetEvent(BR.Net.SNAPSHOT)
AddEventHandler(BR.Net.SNAPSHOT, function(p)
    local m = type(p) == 'table' and p.match or nil
    if type(m) ~= 'table' then return end
    followCycle(m.sky)
end)

-- ------------------------------------------------------------- the island ---

-- br_environment's claim. It arrives as a client event because that resource is
-- a different Lua state; the payload is the same (name, blend) pair storm.lua
-- passes to BR.World.want directly.
AddEventHandler('br:world:island', function(name, blend)
    BR.World.want('island', name, blend)
end)

-- THE HANDSHAKE, AND IT IS ABOUT RESOURCE START ORDER.
--
-- ipl.lua announces its claim from applyIsland, and its FIRST announcement is
-- made from a thread that starts as br_environment does. If br_environment
-- starts first, that announcement is triggered into a client where this handler
-- does not exist yet and is simply lost -- and the lobby island would then sit
-- under whatever the engine felt like instead of the overcast haze the bus
-- choreography depends on.
--
-- So this file asks, once, on load. Either order is covered: br_core first and
-- ipl's own announcement lands here; br_environment first and this ask reaches
-- a handler that is already up.
TriggerEvent('br:world:ask')
