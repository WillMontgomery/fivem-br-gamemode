-- Season 2 terminals (#396), wave C: EMP, the server half.
--
-- THE PAGE (br_lib/config/terminals.lua, `emp_*`): "Every vehicle within the
-- radius you choose stalls and won't start. Vehicles that drive in after it
-- goes off aren't affected. They start again when it ends." Options `radius`
-- (300 or 600 meters around this terminal) and `duration` (30 or 60 seconds),
-- the row's choices, read as numbers.
--
--   WHICH VEHICLES   picked HERE, once, at the moment it goes off
--                    (BR.Terminal.empPick): every vehicle in this match's
--                    routing bucket (`m.bucket`) within the radius of this
--                    terminal on the ground -- BR.Terminal.anchorOf, so the dev
--                    terminal is the player -- that a player may use in this
--                    gamemode. A vehicle that drives in afterwards was never
--                    picked, so it is never stalled.
--   NOT PICKED       anything BR.Config.VehicleRefusalFor refuses -- what
--                    flies and the tanks (#193), aircraft above all: nobody
--                    may fly one here (client/vehrefuse.lua ejects them,
--                    server/vehicles.lua files a case), and a stalled
--                    helicopter in the air falls on whoever is under it, which
--                    the page does not say; a trailer or a train (no engine to
--                    stall); and the CPR ride's ambulance while it carries a
--                    downed player (BR.Rescue.vehicleBusy) -- the game's own
--                    machinery, not a player's car. An ARMED model-table row
--                    is no refusal since #322 (its weapons are switched off
--                    and it is an ordinary car), so it IS picked and stalls
--                    like any car; so are the station ambulances, ordinary
--                    cars players may take.
--   MARKED           with an entity state bag, `fx.empBag`, holding the
--                    milliseconds it has left as it is set -- replicated to
--                    every client the vehicle is relevant to, and to a client
--                    it becomes relevant to later. A vehicle a second EMP
--                    picks keeps whichever end is later.
--   STALLED          by client/terminalfx/emp.lua, on whichever client owns the
--                    vehicle (the driver, once they are in): its engine off and
--                    undriveable, on the bag's change, on entering it, and on
--                    the one SLOW pass when ownership has moved -- never per
--                    frame.
--   IT ENDS          on its own clock (the job below clears each bag), with
--                    the match (the job, and `br:match:destroyed` for a match
--                    torn down between two passes), off Season 2, and with
--                    br_core stopping -- the bags are CLEARED there, not just
--                    forgotten: they live on entities, not on the match, and a
--                    bag left on a car after a restart would stall whoever got
--                    in next.
--
-- NOT REFUSED FOR FINDING NO VEHICLE. A refusal spends nothing, so "no car
-- near this terminal" would be free intel (Pulse's rule); an EMP over an empty
-- car park is an EMP. Refused, spending nothing, only outside a match (and on
-- a build with no server vehicle natives). Nothing here creates, deletes or
-- moves a vehicle: server/vehicles.lua's creation rule, the fuel ledger
-- (server/fuel.lua tracks a vehicle by its driver, and a stalled one drives
-- nowhere) and sv_entityLockdown are untouched, and the only write is the
-- server's own state bag.

BR = BR or {}
BR.Terminal = BR.Terminal or {}

local T = BR.Terminal

local function fx() return BR.Config.Terminals.fx or {} end

local function on()
    return BR.Season ~= nil and BR.Season.has ~= nil and BR.Season.has('terminals') == true
end

--- The state bag key a stalled vehicle carries; client/terminalfx/emp.lua
--- reads the same config line.
--- @return string
local function bagKey()
    return fx().empBag or 'brEmp'
end

--- Vehicle types with no engine to stall (GetVehicleType's words).
local NO_ENGINE = { trailer = true, train = true }

--- A BOOL native's answer, believed correctly: `0` is truthy in Lua.
local function didHit(v)
    return v == true or v == 1
end

--- The marks of every match that has some, by match id: the same table as
--- that match's `terminalFx.emp`. Only so `br:match:destroyed` -- raised after
--- the match has left BR.Server.matches -- can still reach the bags to clear.
local byMatch = {}

--- Can this server stall anything at all? GetAllVehicles and Entity(...).state
--- are OneSync's; a build without them can pick nothing.
--- @return boolean
local function capable()
    return type(GetAllVehicles) == 'function' and type(Entity) == 'function'
end

--- Set (ms) or clear (nil) one vehicle's bag. pcall'd: a handle that went
--- stale between the pick and here throws rather than answering.
local function setBag(veh, ms)
    pcall(function()
        Entity(veh).state:set(bagKey(), ms and math.max(1, math.floor(ms)) or nil, true)
    end)
end

--- Does the EMP take this vehicle? It has an engine, it is not one this
--- gamemode refuses (aircraft and tanks; an armed row is allowed since #322,
--- so it is taken), and it is not the CPR ride.
--- @param veh integer
--- @return boolean
local function takes(veh)
    local okT, vtype = pcall(GetVehicleType, veh)
    vtype = okT and vtype or nil
    if NO_ENGINE[vtype] then return false end
    if BR.Config.VehicleRefusalFor then
        local okM, model = pcall(GetEntityModel, veh)
        local why = BR.Config.VehicleRefusalFor(okM and model or nil,
            { typeOf = function() return vtype end })
        if why ~= nil then return false end
    end
    if BR.Rescue and BR.Rescue.vehicleBusy and BR.Rescue.vehicleBusy(veh) then return false end
    return true
end

--- EVERY VEHICLE AN EMP AT (x, y) TAKES, in this match, now: in its routing
--- bucket, within `radius` meters on the ground, and one `takes` allows.
--- Sorted, so a log line and a suite read the same list.
--- @param m table
--- @param x number
--- @param y number
--- @param radius number
--- @return integer[] handles
function T.empPick(m, x, y, radius)
    local out = {}
    if not capable() then return out end
    local okAll, all = pcall(GetAllVehicles)
    if not okAll or type(all) ~= 'table' then return out end
    local r2 = radius * radius
    for _, veh in ipairs(all) do
        local okE, exists = pcall(DoesEntityExist, veh)
        local okB, bucket = pcall(GetEntityRoutingBucket, veh)
        if okE and didHit(exists) and okB and bucket == m.bucket then
            local okC, c = pcall(GetEntityCoords, veh)
            if okC and c then
                local dx, dy = c.x - x, c.y - y
                if dx * dx + dy * dy <= r2 and takes(veh) then out[#out + 1] = veh end
            end
        end
    end
    table.sort(out)
    return out
end

--- Is this vehicle stalled by an EMP in this match right now? For the suites
--- and the console.
--- @param m table
--- @param veh integer
--- @param now number
--- @return boolean
function T.empStalled(m, veh, now)
    local marks = m and m.terminalFx and m.terminalFx.emp or nil
    local untilAt = marks and marks[veh] or nil
    return untilAt ~= nil and now < untilAt and on() and m.state == BR.MatchState.PLAYING
end

--- Clear every bag a match's EMPs set, or (with `now`) the ones whose time is
--- up. Public so the suites can step it.
--- @param m table
--- @param now number
function T.expireEmp(m, now)
    local st = m.terminalFx
    local marks = st and st.emp
    if not marks then return end
    -- THE MATCH IS OVER, OR THE SEASON SWITCHED: every bag goes now. They are
    -- on entities, so forgetting them would leave stalled cars behind.
    local all = (not on()) or m.state ~= BR.MatchState.PLAYING
    local cleared = 0
    for veh, untilAt in pairs(marks) do
        if all or now >= untilAt then
            marks[veh] = nil
            setBag(veh, nil)
            cleared = cleared + 1
        end
    end
    if next(marks) == nil then
        st.emp = nil
        byMatch[m.id] = nil
    end
    if cleared > 0 then
        print(('[br_core] terminals: EMP over for %d vehicle(s) in match %s')
            :format(cleared, tostring(m.id)))
    end
end

T.FUNCTIONS.emp = {
    -- Outside a match there is nothing to stall; a dev session (typed facts,
    -- for walking the app) is never refused for it.
    refuse = function(src, session)
        local m = T.whereIs(src)
        if not m then return (not session.dev) and 'unavailable' or nil end
        if not capable() then return 'unavailable' end
        return nil
    end,
    run = function(src, session, opts)
        local m = T.whereIs(src)
        if not m then
            if session.dev then
                print(('[br_core] brterminal (client %d): EMP ran on the dev terminal '
                    .. 'with no match to stall'):format(src))
                return { ok = true, code = 'done' }
            end
            return { ok = false, code = 'unavailable' }
        end
        if not capable() then return { ok = false, code = 'unavailable' } end
        local x, y = T.anchorOf(src, session)
        if not x then return { ok = false, code = 'unavailable' } end
        local radius = tonumber(opts and opts.radius) or 300
        local seconds = tonumber(opts and opts.duration) or 30
        local now = GetGameTimer()
        local untilAt = now + seconds * 1000
        local taken = T.empPick(m, x, y, radius)
        local st = T.fxOf(m)
        st.emp = st.emp or {}
        for _, veh in ipairs(taken) do
            -- A SECOND EMP NEVER SHORTENS A FIRST over the same vehicle.
            local was = st.emp[veh]
            if was == nil or was < untilAt then st.emp[veh] = untilAt end
            setBag(veh, st.emp[veh] - now)
        end
        if next(st.emp) == nil then
            st.emp = nil
        else
            byMatch[m.id] = st.emp
        end
        print(('[br_core] terminals: EMP (%d m, %d s) in match %s stalled %d vehicle(s)')
            :format(radius, seconds, tostring(m.id), #taken))
        return { ok = true, code = 'done' }
    end,
}

-- ONCE A SECOND: the bags whose time is up, and every bag of a match no
-- longer being played (or off Season 2), cleared.
if BR.Sched and BR.Sched.every then
    BR.Sched.every(fx().endCheckMs or 1000, 'terminal.emp', function()
        local now = GetGameTimer()
        BR.Server.eachMatch(function(m)
            if m.terminalFx and m.terminalFx.emp then T.expireEmp(m, now) end
        end)
    end)
end

--- Every bag one match's EMPs set, cleared, from the index.
--- @param id any  the match id
local function clearMatch(id)
    local marks = id ~= nil and byMatch[id] or nil
    if not marks then return end
    byMatch[id] = nil
    for veh in pairs(marks) do
        marks[veh] = nil
        setBag(veh, nil)
    end
end

-- A MATCH TORN DOWN BETWEEN TWO PASSES (an abandoned one never reaches ENDED)
-- is no longer in BR.Server.matches, so the job above cannot see it: its bags
-- are cleared here, from the index.
AddEventHandler('br:match:destroyed', function(d)
    clearMatch(type(d) == 'table' and d.matchId or nil)
end)

-- BR_CORE STOPPING (a restart mid-EMP): the bags outlive the resource on the
-- entities, so every one is cleared on the way out.
AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    local ids = {}
    for id in pairs(byMatch) do ids[#ids + 1] = id end
    for _, id in ipairs(ids) do clearMatch(id) end
end)
