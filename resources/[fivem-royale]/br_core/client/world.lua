-- The world override on a client, and the ONE place this client's sky is set.
--
-- Owner, 2026-08-31: "can you make me a brtime command on the server which will
-- set the time in-game? Recall we have the game locked at noon right now. Also I
-- want one for brweather too."
--
-- ═══ THE CLOCK IS NOT HERE, AND THAT IS THE DESIGN ═══
--
-- client/natives.lua pins the clock with NetworkOverrideClockTime on the FRAME
-- band, and anything this file did to the clock would be overwritten inside one
-- frame. So nothing here touches it. The pin reads BR.World.clockHM() instead of
-- the literal `12, 0` it used to carry, and the override is a value that
-- function answers -- one writer, unchanged, told a different number.
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

-- ---------------------------------------------------------------------- sky ---

--- What each source currently wants. Absent means "no claim".
local claims = { override = nil, storm = nil, island = nil }

--- The weather name the engine was last handed by this file, or nil if the last
--- thing it was handed was ClearWeatherTypePersist.
---
--- COMPARED BEFORE EVERY WRITE, because the claims are pushed from a 10Hz storm
--- tick and from an override envelope, and re-asserting the same weather blend
--- restarts it -- a sky that never finishes arriving.
local wrote = nil

--- Write whatever wins, if it is not what the engine already has.
--- @param force boolean|nil  write even if the winner is unchanged
local function push(force)
    local name, blend = BR.World.resolveSky(claims)

    if name == nil then
        -- NOBODY WANTS THE SKY. Hand it back to the engine rather than picking
        -- a default: this is the state a match ends in and GTA's own weather is
        -- the right thing to be standing under between rounds.
        if wrote ~= nil then
            wrote = nil
            ClearWeatherTypePersist()
        end
        return
    end

    if name == wrote and not force then return end
    wrote = name

    if blend and blend > 0.0 then
        SetWeatherTypeOvertimePersist(name, blend + 0.0)
    else
        SetWeatherTypeNowPersist(name)
    end
end

--- Claim the sky, or release a claim by passing nil.
---
--- THE SOURCE IS CHECKED AGAINST THE PRIORITY LIST rather than trusted. A typo
--- would otherwise store an unranked key that resolveSky walks straight past --
--- a claim that never wins, never errors and never gets noticed.
--- @param source string  a member of BR.World.SKY_SOURCES
--- @param name string|nil  a weather name, or nil to release
--- @param blend number|nil seconds to blend over; 0 or nil snaps
--- @param force boolean|nil  write even if the resolved winner is unchanged
function BR.World.want(source, name, blend, force)
    if not BR.World.SKY_SOURCE[source] then
        print(('[br_core] world: %s is not a sky source'):format(tostring(source)))
        return
    end
    claims[source] = name and { name = name, blend = blend } or nil

    -- A FORCED WRITE IS ONLY THE WINNER'S TO ASK FOR. storm.lua's drying snap
    -- forces because re-writing the same weather is what hard-resets the
    -- engine's rain memory -- but that is a claim about the sky the storm is
    -- showing, and while a console override is on screen the storm is not
    -- showing one. Honouring the flag regardless would have a yielding source
    -- re-assert somebody else's sky for a reason that has nothing to do with it,
    -- which is a small thing that makes "the storm writes nothing while an
    -- override holds" untrue.
    local _, winner = BR.World.sky()
    push(force == true and winner == source)
end

--- What the sky resolves to right now, and which claim is showing it.
---
--- Read by BR.World.want above (to decide whether a forced write is the
--- forcer's to ask for) and by tools/test_shared.lua. No console verb reads it:
--- if one ever should, it belongs beside the others in server/debug.lua rather
--- than as a second command here.
--- @return string|nil name, string|nil source
function BR.World.sky()
    local name = BR.World.resolveSky(claims)
    if name == nil then return nil, nil end
    for _, src in ipairs(BR.World.SKY_SOURCES) do
        if claims[src] and claims[src].name == name then return name, src end
    end
    return name, nil
end

-- ----------------------------------------------------------------- override ---

--- Fold the override into the claim table and apply it.
local function applyOverride()
    local wx = BR.World.weatherName()
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

    push()
end

-- THE WHOLE OVERRIDE ARRIVES EVERY TIME, and a field that is not in it is the
-- reset -- see BR.World.payload. Sent to everyone when it changes, and to one
-- client on br:ready, which is what a late joiner gets.
RegisterNetEvent(BR.Net.WORLD_SET)
AddEventHandler(BR.Net.WORLD_SET, function(p)
    BR.World.applyPayload(p)
    applyOverride()
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
