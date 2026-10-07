-- Season 2 terminals (#396), round 5: VEHICLE DROP, the server half.
--
-- THE OWNER, 2026-10-06: "Kuruma is good!", and "let's not have them pick a
-- location for the vehicle drop, but instead have it drop within 40m of them,
-- with a blip until they get into the vehicle, OR when in squads they can pick
-- from a dropdown of alive teammates to drop it next to."
--
--   THE CAR     an armored Kuruma (fx.dropModel, `kuruma2`), never an armed
--               vehicle, built by BR.Vehicles.spawnOwned -- the one creation
--               path, beside the allowlist: the vehicle rules' own ruling
--               admits it, it goes into the match's routing bucket, and the
--               fuel ledger takes it the moment somebody in the match sits
--               in it (server/fuel.lua admits on the seat, not the spawn).
--   NEXT TO     option `to`: 'self' (the runner), or 'mate' (option `mate`,
--               a standing teammate the state listed, BR.Terminal.mates) --
--               the second in a squad match alone, `bad_option` outside one.
--   WHERE       within fx.dropRadiusM (40 m) of that player, on a road or
--               flat open ground under open sky -- never on a player, in the
--               water or inside a building. ONLY A CLIENT CAN SEE ROADS AND
--               ROOFS, so the client of the player it is for looks while the
--               run loads (`prepare`, TERMINAL_DROP_FIND; client/terminalfx/
--               vehicle_drop.lua) and sends the best spot it has every
--               second; the server keeps the last one that passes its OWN
--               checks (BR.TerminalSolve.dropCheck: near its 4 Hz sample of
--               them, at their height, clear of every player, inside the play
--               area) and checks it again when the load is over. No spot is
--               `drop_ground` (`drop_ground_mate`), and everything comes back.
--   THE DESCENT the real car is built AT ONCE, where it will land, frozen and
--               locked -- so a car the engine will not make is a refund, not
--               a promise -- and every client within fx.dropDrawM draws a copy
--               of it coming down from fx.dropAltM under the airdrop's own
--               cargo chute, on the airdrop's own fall curve, hiding the real
--               one until the copy touches down (TERMINAL_DROP). At
--               fx.dropFallMs it is unfrozen and unlocked.
--   THE BLIP    on the squad's maps (`blip` in TERMINAL_DROP), moved if the
--               car is, until somebody in that squad gets in (the seat walk,
--               BR.Vehicles.ridingIn), the car is destroyed or gone, the
--               match stops being played, or Season 2 ends; again to a
--               squadmate on br:ready.
--
-- REFUSED, SPENDING NOTHING (the Volts included), as the run is asked, as it
-- is accepted and as the load ends: `drop_target` (the runner is not
-- standing), `drop_no_mate` (the teammate is not a standing teammate now),
-- `drop_ground(_mate)` (nowhere to land), `unavailable` (no match, or a car
-- the vehicle rules or the engine will not build). The lobby hears
-- notice_action (`vehicle_drop_description`); the teammate it lands next to is
-- told who sent it (`vehicle_drop_received`). Nothing timed is done to anybody
-- else, so it has no persistent notice.

BR = BR or {}
BR.Terminal = BR.Terminal or {}

local T = BR.Terminal
local TS = BR.TerminalSolve

local function fx() return BR.Config.Terminals.fx or {} end
local function copy() return BR.Config.Terminals.copy end

local function on()
    return BR.Season ~= nil and BR.Season.has ~= nil and BR.Season.has('terminals') == true
end

--- A FiveM BOOL native may answer 1/0, and 0 is truthy in Lua.
local function didHit(v)
    return v == true or v == 1
end

--- How high over the ground the car is held, in meters: about a ped's
--- height, the shop's spawn height (server/shop.lua builds at the player's
--- z), so on unfreezing it settles onto its wheels rather than out of the
--- ground. The copy comes down to the same height.
local LIFT_M = 1.0

--- An engine at or below this is a wreck: GTA's destroyed vehicle.
local WRECKED_ENGINE = -3999.0

--- How far the car must move before its blip is moved, in meters.
local BLIP_MOVE_M = 2.0

--- The most spot answers one search is read for: one a second for the
--- longest load, with room. Past it a client is not a person.
local ANSWERS_MAX = 20

--- The searches in flight, by runner: [src] = { target, nonce, matchId,
--- answers, spot? }. One per runner, as one run is.
local asks = {}
local nonceSeq = 0

--- The drops still showing a blip, by id: { id, matchId, squad, by, target,
--- veh, netId, x, y, z, h, tRelease, tLand, alt, landed, bx, by2 }.
local drops = {}
local dropSeq = 0

--- @param src integer
--- @return boolean standing, table|nil entry
local function standing(src)
    local e = BR.Roster.get(src)
    return e ~= nil and e.state == BR.PlayerState.ALIVE, e
end

--- Who this run drops the car next to, or nil and why.
--- @param src integer  the runner
--- @param opts table|nil
--- @return integer|nil target, string|nil why
local function targetOf(src, opts)
    local to = opts and opts.to or 'self'
    if to == 'self' then
        if not standing(src) then return nil, 'drop_target' end
        return src, nil
    end
    if to ~= 'mate' or not T.squadMatch(src) then return nil, 'bad_option' end
    local want = tonumber(opts.mate)
    for _, row in ipairs(T.mates(src)) do
        if tonumber(row.id) == want then return want, nil end
    end
    return nil, 'drop_no_mate'
end
T.dropTargetOf = targetOf

--- Can this server build the car at all? The creation path is there, and the
--- vehicle rules' own ruling (BR.Config.VehicleRefusalFor, which
--- spawnOwned asks again) does not refuse the model.
--- @return boolean
local function buildable()
    if not (BR.Vehicles and BR.Vehicles.spawnOwned) then return false end
    local model = fx().dropModel or 'kuruma2'
    if BR.Config.VehicleRefusalFor and GetHashKey
        and BR.Config.VehicleRefusalFor(GetHashKey(model)) ~= nil then
        return false
    end
    return true
end

--- Why the spot a search holds may not take the car NOW, by where everybody
--- is now (BR.TerminalSolve.dropCheck), or nil.
--- @param a table  the search
--- @param spot table
--- @return string|nil
local function spotWhy(a, spot)
    local e = BR.Roster.get(a.target)
    local m = BR.Server.matchOf(a.target)
    if not e or not e.pos or not m or m.id ~= a.matchId then return 'far' end
    local others = {}
    BR.Roster.each(function(o) return o.matchId == m.id end, function(_, o)
        if o.pos then others[#others + 1] = { x = o.pos.x, y = o.pos.y } end
    end)
    local inBounds = BR.Config.Map and BR.Config.Map.InBounds or nil
    return TS.dropCheck(spot, e.pos, others, fx(), inBounds)
end

--- Stop a search, on the client doing it.
local function stopAsk(src)
    local a = asks[src]
    if not a then return end
    asks[src] = nil
    TriggerClientEvent(BR.Net.TERMINAL_DROP_FIND, a.target, { nonce = a.nonce, stop = true })
end

--- The squad a drop's blip is for, as the match has it now.
local function squadOfDrop(d)
    local m = BR.Server.matchById and BR.Server.matchById(d.matchId) or nil
    if not m then return {} end
    return T.squadOf(m, d.squad)
end

--- What TERMINAL_DROP tells `to` about a drop: the descent, and the blip if
--- `to` is in its squad.
local function dropPayload(d, to)
    local e = BR.Roster.get(to)
    local mine = e ~= nil and TS.squadKey(e, to) == d.squad
    return { matchId = d.matchId, id = d.id, netId = d.netId,
             x = d.x, y = d.y, z = d.z, h = d.h,
             tRelease = d.tRelease, tLand = d.tLand, alt = d.alt,
             blip = (mine and not d.blipOff) or nil }
end

--- Take a drop's blip off its squad's maps, and forget it.
local function blipOff(d, why)
    drops[d.id] = nil
    d.blipOff = true
    for _, s in ipairs(squadOfDrop(d)) do
        TriggerClientEvent(BR.Net.TERMINAL_DROP, s, { matchId = d.matchId, id = d.id, off = true })
    end
    print(('[br_core] terminals: vehicle drop %d\'s blip is off (%s)'):format(d.id, why))
end

--- The car has landed: let it go.
local function land(d)
    if d.landed then return end
    d.landed = true
    pcall(FreezeEntityPosition, d.veh, false)
    pcall(SetVehicleDoorsLocked, d.veh, 1)
end

--- The drops whose car has landed, a squadmate is in it, it is wrecked or
--- gone, or whose match is over: their blips off. The rest moved if their
--- car was. Public so the suites can step it; on the 1 s pass.
--- @param now number
function T.stepDrops(now)
    for _, d in pairs(drops) do
        local m = BR.Server.matchById and BR.Server.matchById(d.matchId) or nil
        local why = nil
        if not on() then
            why = 'season'
        elseif not m or m.state ~= BR.MatchState.PLAYING then
            why = 'match'
        else
            if not d.landed and now >= d.tLand then land(d) end
            local okE, exists = pcall(DoesEntityExist, d.veh)
            if not (okE and didHit(exists)) then
                why = 'gone'
            else
                local okH, engine = pcall(GetVehicleEngineHealth, d.veh)
                if okH and tonumber(engine) and tonumber(engine) <= WRECKED_ENGINE then
                    why = 'wrecked'
                elseif d.landed and BR.Vehicles and BR.Vehicles.ridingIn then
                    for _, s in ipairs(T.squadOf(m, d.squad)) do
                        local e = BR.Roster.get(s)
                        if e and e.ped and BR.Vehicles.ridingIn(e.ped) == d.veh then
                            why = 'boarded'
                            break
                        end
                    end
                end
            end
        end
        if why then
            blipOff(d, why)
        else
            local okC, c = pcall(GetEntityCoords, d.veh)
            if okC and c and TS.finite(c.x) and TS.finite(c.y) then
                local dx, dy = c.x - d.bx, c.y - d.by2
                if dx * dx + dy * dy > BLIP_MOVE_M * BLIP_MOVE_M then
                    d.bx, d.by2 = c.x + 0.0, c.y + 0.0
                    for _, s in ipairs(T.squadOf(m, d.squad)) do
                        TriggerClientEvent(BR.Net.TERMINAL_DROP, s,
                            { matchId = d.matchId, id = d.id, x = d.bx, y = d.by2 })
                    end
                end
            end
        end
    end
end

--- The drops whose blip is still up, for the suites.
--- @return table[]
function T.dropsLive()
    local out = {}
    for _, d in pairs(drops) do out[#out + 1] = d end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

--- The search a runner has in flight, for the suites.
--- @param src integer
--- @return table|nil
function T.dropAsk(src)
    return asks[src]
end

T.FUNCTIONS.vehicle_drop = {
    -- Outside a match there is nowhere to drop it; a dev session (typed facts,
    -- for walking the app) is never refused for it. A car this server cannot
    -- build is refused on the card. Listed, it is otherwise available: who it
    -- is for is a choice the card has not made yet.
    refuse = function(src, session, opts)
        local m = T.whereIs(src)
        if not m then return (not session.dev) and 'unavailable' or nil end
        if not buildable() then return 'unavailable' end
        if opts == nil then return nil end
        local _, why = targetOf(src, opts)
        return why
    end,
    -- AS THE RUN IS ACCEPTED: the player it is for starts looking for
    -- somewhere to land it, and sends what they find while it loads.
    prepare = function(src, session, opts)
        local target = targetOf(src, opts)
        if not target then return end
        stopAsk(src)
        nonceSeq = nonceSeq + 1
        local m = BR.Server.matchOf(target)
        local F = fx()
        asks[src] = { target = target, nonce = nonceSeq, matchId = m and m.id or nil, answers = 0 }
        TriggerClientEvent(BR.Net.TERMINAL_DROP_FIND, target, {
            nonce = nonceSeq, r = F.dropRadiusM or 40.0, minM = F.dropMinM or 6.0,
            everyMs = F.dropAskMs or 1000, forMs = F.dropAskForMs or 8000,
        })
    end,
    abandon = function(src)
        stopAsk(src)
    end,
    run = function(src, session, opts)
        local m, _, key = T.whereIs(src)
        if not m then
            stopAsk(src)
            if session.dev then
                print(('[br_core] brterminal (client %d): Vehicle drop ran on the dev terminal '
                    .. 'with no match to drop into'):format(src))
                return { ok = true, code = 'done' }
            end
            return { ok = false, code = 'unavailable' }
        end
        local a = asks[src]
        stopAsk(src)
        local target, why = targetOf(src, opts or {})
        if not target then return { ok = false, code = why } end
        local noGround = (target == src) and 'drop_ground' or 'drop_ground_mate'
        -- THE LAST GOOD SPOT, CHECKED AGAIN AGAINST WHERE EVERYBODY IS NOW.
        if not a or a.target ~= target or not a.spot or spotWhy(a, a.spot) ~= nil then
            return { ok = false, code = noGround }
        end
        if not buildable() then return { ok = false, code = 'unavailable' } end
        local s, F = a.spot, fx()
        local model = F.dropModel or 'kuruma2'
        local veh, netId, whyVeh = BR.Vehicles.spawnOwned(model, 'automobile',
            s.x, s.y, s.z + LIFT_M, s.h, nil, m.bucket)
        if not veh then
            print(('^1[br_core] terminals: vehicle drop for %d: the engine would not build %s (%s) '
                .. '-- everything given back^7'):format(src, model, tostring(whyVeh)))
            return { ok = false, code = 'unavailable' }
        end
        -- HELD WHERE IT WILL LAND until it has: frozen, and locked, so nobody
        -- climbs into a car every client is hiding while its copy comes down.
        pcall(FreezeEntityPosition, veh, true)
        pcall(SetVehicleDoorsLocked, veh, 2)
        local now = GetGameTimer()
        dropSeq = dropSeq + 1
        local d = {
            id = dropSeq, matchId = m.id, squad = key, by = src, target = target,
            veh = veh, netId = netId, x = s.x + 0.0, y = s.y + 0.0, z = s.z + LIFT_M, h = s.h + 0.0,
            tRelease = now, tLand = now + math.floor(tonumber(F.dropFallMs) or 9000),
            alt = tonumber(F.dropAltM) or 120.0, landed = false,
            bx = s.x + 0.0, by2 = s.y + 0.0,
        }
        drops[d.id] = d
        SetTimeout(d.tLand - now, function()
            if drops[d.id] == d then land(d) end
        end)
        local runner = BR.Roster.get(src)
        print(('[br_core] terminals: Vehicle drop by %s (%d): %s at (%.1f, %.1f, %.1f) next to %d, netId %s')
            :format(runner and runner.name or '?', src, model, d.x, d.y, d.z, target, tostring(netId)))
        -- THE DESCENT, TO THE WHOLE MATCH, after "has redeemed their special
        -- power: Vehicle drop..."; the blip with it, to the squad; and the
        -- teammate it lands next to, who chose nothing, told who sent it.
        return { ok = true, code = 'done', after = function()
            for _, to in ipairs(T.lobbyOf(m)) do
                TriggerClientEvent(BR.Net.TERMINAL_DROP, to, dropPayload(d, to))
            end
            if target ~= src then
                BR.Server.notify(target, TS.line(TS.pick(copy(), 'vehicle_drop_received',
                    T.squadMatch(target) == true), runner and runner.name or GetPlayerName(src)),
                    'success', { ms = 8000 })
            end
        end }
    end,
}

-- THE SPOT, FROM THE PLAYER IT IS FOR: kept only from them, for the search
-- they were asked, and only when it passes the server's own checks -- the last
-- good one stands until a better one comes, and `none` changes nothing.
RegisterNetEvent(BR.Net.TERMINAL_DROP_SPOT)
AddEventHandler(BR.Net.TERMINAL_DROP_SPOT, function(d)
    local from = tonumber(source)
    if not from or not on() or type(d) ~= 'table' then return end
    for _, a in pairs(asks) do
        if a.target == from and a.nonce == d.nonce then
            a.answers = a.answers + 1
            if a.answers > ANSWERS_MAX or d.none == true then return end
            local spot = { x = d.x, y = d.y, z = d.z, h = d.h }
            if spotWhy(a, spot) == nil then
                a.spot = { x = d.x + 0.0, y = d.y + 0.0, z = d.z + 0.0, h = d.h + 0.0 }
            end
            return
        end
    end
end)

-- ONCE A SECOND: the blips, and a car that landed while no timer ran.
if BR.Sched and BR.Sched.every then
    BR.Sched.every(fx().endCheckMs or 1000, 'terminal.drops', function()
        if next(drops) == nil then return end
        T.stepDrops(GetGameTimer())
    end)
end

-- A squadmate whose client restarts is shown the blip again.
AddEventHandler(BR.Net.READY, function()
    local src = tonumber(source)
    if not src or not on() or next(drops) == nil then return end
    local m, e = BR.Server.matchOf(src), BR.Roster.get(src)
    if not m or not e then return end
    local key = TS.squadKey(e, src)
    for _, d in pairs(drops) do
        if d.matchId == m.id and d.squad == key then
            TriggerClientEvent(BR.Net.TERMINAL_DROP, src, dropPayload(d, src))
        end
    end
end)

AddEventHandler('playerDropped', function()
    local src = tonumber(source)
    if src and asks[src] then asks[src] = nil end
end)
