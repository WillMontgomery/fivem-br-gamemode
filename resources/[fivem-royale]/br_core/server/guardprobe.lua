-- The bodyguard ownership probe (#401), server half. A DEV TEST COMMAND, NOT
-- THE FEATURE.
--
-- ═══ WHAT IT IS FOR ═══
--
-- The research on #401 (2026-10-07) found the one thing the bodyguard cannot
-- be built without knowing: who OWNS a networked ped, and what survives when
-- that changes. citizenfx/fivem#2986 (open): a networked ped migrates to
-- whoever shoots it, even with migration disabled, and its tasks and flags
-- reset on the way. Two questions were left for "a ~20 min two-client test,
-- using a dev command, before the build":
--
--   * Shoot the guard: log its owner every 100 ms, and whether it fires back.
--   * A teammate drives with the guard aboard: does ownership move to the
--     driver?
--
-- This is that command, and nothing else:
--
--   brguardprobe spawn   one networked armed soldier (s_m_y_marine_03, a
--                        carbine, 50 armor) 2 m in front of the caller, in
--                        their routing bucket, orphan mode 2 (kept when its
--                        owner leaves), friendly to the caller's relationship
--                        group and following them -- the group and the task
--                        applied by whichever client owns it (client/
--                        guardprobe.lua). A second spawn replaces the first.
--   brguardprobe drive   the guard into the first free passenger seat of the
--                        caller's vehicle, by its owning client.
--   brguardprobe log     every 100 ms, the guard's owner (NetworkGetEntityOwner),
--                        health and whether it is in a vehicle, printed and
--                        kept -- with every owner change, and each owning
--                        client's report of what survived -- in
--                        br_core/guardprobe.log, rewritten once a second, to
--                        paste. `brguardprobe log off` stops it.
--   brguardprobe clear   deletes the guard and stops the log.
--
-- ═══ WHAT KEEPS IT OUT OF EVERY MATCH ═══
--
-- DEV MODE ONLY: br_lib/shared/devgate.lua's RegisterCommand wrap, like
-- `brboxsv` -- typed in F8, it arrives as that player. REGISTERED UNRESTRICTED
-- on purpose for the same reason: restricted would ask for an ACE the dev gate
-- already stands in for. SEASON 2, like the bodyguard it measures (a terminal
-- function): BR.Season.has('terminals'). NOTHING RUNS UNTIL IT IS TYPED: no
-- thread, no scheduled job, no event sent; the client half's one TICK callback
-- returns at once while there is no guard. And the guard is deleted when
-- br_core stops, since orphan mode 2 would otherwise keep it in the world.

BR = BR or {}

local MODEL = 's_m_y_marine_03'
local WEAPON = 'WEAPON_CARBINERIFLE'
local ARMOR = 50
local AHEAD_M = 2.0
local LOG_MS = 100
local FLUSH_MS = 1000
local LOG_FILE = 'guardprobe.log'
--- Lines kept for the file: half an hour at ten a second, and a margin.
local KEEP_LINES = 20000

--- The guard, or nil: { ent, net, caller, bucket, callerPedNet, at }.
local probe = nil
--- What the log has kept, oldest first, and whether it is running.
local lines = {}
local logging = false
--- Bumped by every spawn and clear, so a spawn still waiting for its ped
--- from before stands down.
local spawnGen = 0
--- Bumped by every `log`, `log off` and clear, so a sampler from before stops.
local logGen = 0

--- NativeTruthy where it is loaded; the plain comparison where it is not.
local function truthy(v)
    if BR.NativeTruthy then return BR.NativeTruthy(v) end
    return v == true or v == 1
end

--- A player's name, or their id.
local function nameOf(src)
    if not src or src < 0 then return 'nobody' end
    return ('%s (%d)'):format(GetPlayerName(src) or '?', src)
end

--- Write everything kept to the file. SaveResourceFile answers a BOOL,
--- compared rather than believed (server/props.lua's note).
local function flush()
    local body = table.concat(lines, '\n') .. '\n'
    local wrote = SaveResourceFile(GetCurrentResourceName(), LOG_FILE, body, -1)
    if wrote ~= true and wrote ~= 1 then
        print(('[br_core] guardprobe: could not write %s/%s'):format(GetCurrentResourceName(), LOG_FILE))
    end
end

--- One line: printed, and kept for the file.
local function out(line)
    local stamped = ('%s %s'):format(os.date('%H:%M:%S'), line)
    print('[br_core] guardprobe: ' .. line)
    lines[#lines + 1] = stamped
    if #lines > KEEP_LINES then table.remove(lines, 1) end
end

--- Tell the caller (and the console) what happened.
local function tell(src, text)
    print('[br_core] guardprobe: ' .. text)
    if src and src > 0 and BR.Server and BR.Server.notify then
        BR.Server.notify(src, 'brguardprobe: ' .. text, 'info')
    end
end

--- The players in the guard's routing bucket: the only clients that can own
--- it, and so the only ones told about it.
local function audience(bucket)
    local out_ = {}
    for _, id in ipairs(GetPlayers()) do
        local s = tonumber(id)
        if s and GetPlayerRoutingBucket(s) == bucket then out_[#out_ + 1] = s end
    end
    return out_
end

--- Send every client in the guard's bucket the probe as it stands (nil: gone).
local function broadcast(p, bucket)
    local payload = p and { net = p.net, caller = p.caller, callerPedNet = p.callerPedNet } or false
    for _, s in ipairs(audience(bucket)) do
        TriggerClientEvent('br:guardprobe:state', s, payload)
    end
end

--- Delete the guard, if there is one, and say nothing to anyone else.
local function remove(why)
    spawnGen = spawnGen + 1
    logGen = logGen + 1
    local p = probe
    probe = nil
    if not p then return false end
    if truthy(DoesEntityExist(p.ent)) then DeleteEntity(p.ent) end
    broadcast(nil, p.bucket)
    if logging then
        out(('guard %d deleted (%s)'):format(p.net, why))
        logging = false
        flush()
    end
    return true
end

--- The 100 ms sampler, while `log` is on and there is a guard.
local function startLog()
    logGen = logGen + 1
    local mine = logGen
    logging = true
    local p = probe
    out(('log on: guard %d, called by %s, bucket %d'):format(p.net, nameOf(p.caller), p.bucket))
    Citizen.CreateThread(function()
        local lastOwner, lastFlush, t0 = nil, GetGameTimer(), GetGameTimer()
        while logging and logGen == mine and probe == p do
            local now = GetGameTimer()
            if not truthy(DoesEntityExist(p.ent)) then
                out(('%6d ms  the guard no longer exists'):format(now - t0))
                break
            end
            local owner = NetworkGetEntityOwner(p.ent)
            local veh = GetVehiclePedIsIn(p.ent, false)
            local inVeh = veh ~= nil and veh ~= 0
            if owner ~= lastOwner then
                out(('%6d ms  OWNER CHANGED %s -> %s'):format(now - t0,
                    lastOwner == nil and 'none' or nameOf(lastOwner), nameOf(owner)))
                lastOwner = owner
            end
            out(('%6d ms  owner %s  health %d  armor %d  in vehicle %s'):format(now - t0,
                nameOf(owner), GetEntityHealth(p.ent), GetPedArmour(p.ent),
                inVeh and ('yes (%d)'):format(NetworkGetNetworkIdFromEntity(veh)) or 'no'))
            if now - lastFlush >= FLUSH_MS then
                lastFlush = now
                flush()
            end
            Citizen.Wait(LOG_MS)
        end
        if logGen == mine then logging = false end
        flush()
    end)
end

--- Spawn the guard in front of `src`.
local function spawn(src)
    remove('replaced')
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then
        tell(src, 'no ped for the caller')
        return
    end
    local c = GetEntityCoords(ped)
    local h = GetEntityHeading(ped)
    local r = math.rad(h)
    -- GTA's heading: 0 faces +y, and it turns counterclockwise.
    local x, y = c.x - math.sin(r) * AHEAD_M, c.y + math.cos(r) * AHEAD_M
    local bucket = GetPlayerRoutingBucket(src)
    local ent = CreatePed(4, GetHashKey(MODEL), x, y, c.z, (h + 180.0) % 360.0, true, true)
    if not ent or ent == 0 then
        tell(src, 'CreatePed returned no entity')
        return
    end
    spawnGen = spawnGen + 1
    local mine = spawnGen
    Citizen.CreateThread(function()
        -- AN RPC: a client builds it, so it exists a moment later, or never.
        local waited = 0
        while not truthy(DoesEntityExist(ent)) and waited < 5000 do
            Citizen.Wait(50)
            waited = waited + 50
        end
        if spawnGen ~= mine then
            if truthy(DoesEntityExist(ent)) then DeleteEntity(ent) end
            return
        end
        if not truthy(DoesEntityExist(ent)) then
            tell(src, ('the guard did not appear in %d ms -- nothing spawned'):format(waited))
            DeleteEntity(ent)
            return
        end
        SetEntityRoutingBucket(ent, bucket)
        SetEntityOrphanMode(ent, 2)
        GiveWeaponToPed(ent, GetHashKey(WEAPON), 250, false, true)
        SetPedArmour(ent, ARMOR)
        probe = {
            ent = ent, net = NetworkGetNetworkIdFromEntity(ent), caller = src,
            bucket = bucket, callerPedNet = NetworkGetNetworkIdFromEntity(ped),
            at = GetGameTimer(),
        }
        broadcast(probe, bucket)
        tell(src, ('guard %d spawned in %d ms, bucket %d, first owner %s'):format(
            probe.net, waited, bucket, nameOf(NetworkGetEntityOwner(ent))))
        -- THE CALLER'S PED CAN CHANGE (a respawn): the owning client follows a
        -- network id, so a new one is sent. Once a second, while this guard is.
        local p = probe
        while probe == p do
            Citizen.Wait(1000)
            if probe ~= p then break end
            local now = GetPlayerPed(p.caller)
            local net = now and now ~= 0 and NetworkGetNetworkIdFromEntity(now) or nil
            if net and net ~= p.callerPedNet then
                p.callerPedNet = net
                broadcast(p, p.bucket)
            end
        end
    end)
end

--- Put the guard in the caller's vehicle: the owning client picks the seat.
local function drive(src)
    if not probe then tell(src, 'no guard -- `brguardprobe spawn` first') return end
    local veh = GetVehiclePedIsIn(GetPlayerPed(src), false)
    if not veh or veh == 0 then tell(src, 'you are not in a vehicle') return end
    local vnet = NetworkGetNetworkIdFromEntity(veh)
    for _, s in ipairs(audience(probe.bucket)) do
        TriggerClientEvent('br:guardprobe:drive', s, { net = probe.net, veh = vnet })
    end
    local line = ('drive: guard %d into vehicle %d, asked of its owner %s'):format(
        probe.net, vnet, nameOf(NetworkGetEntityOwner(probe.ent)))
    if logging then out(line) else tell(src, line) end
end

RegisterCommand('brguardprobe', function(source, args)
    local src = tonumber(source) or 0
    local verb = tostring((args or {})[1] or ''):lower()
    if src <= 0 then
        print('  brguardprobe is typed by a player in game (F8): it spawns in front of them')
        return
    end
    if not (BR.Season and BR.Season.has('terminals')) then
        tell(src, 'Season 2 only, like the bodyguard it measures')
        return
    end
    if verb == 'spawn' then
        spawn(src)
    elseif verb == 'drive' then
        drive(src)
    elseif verb == 'log' then
        if tostring((args or {})[2] or ''):lower() == 'off' then
            logGen = logGen + 1
            logging = false
            flush()
            tell(src, ('log off -- %d line(s) in br_core/%s'):format(#lines, LOG_FILE))
        elseif not probe then
            tell(src, 'no guard -- `brguardprobe spawn` first')
        elseif logging then
            tell(src, 'already logging')
        else
            lines = {}
            startLog()
            tell(src, ('logging every %d ms to br_core/%s'):format(LOG_MS, LOG_FILE))
        end
    elseif verb == 'clear' then
        tell(src, remove('cleared') and 'guard deleted' or 'no guard')
    else
        tell(src, 'usage: brguardprobe spawn | drive | log [off] | clear')
    end
end)

-- WHAT EACH OWNING CLIENT SAW WHEN IT GAINED OR LOST THE GUARD
-- (client/guardprobe.lua): whether the task and the group survived the move.
-- Logged and nothing else -- this answers no request and refuses nothing but
-- a report about a guard that is not this one, or a flood.
local lastReport = {}
RegisterNetEvent('br:guardprobe:report')
AddEventHandler('br:guardprobe:report', function(d)
    local src = tonumber(source)
    if not src or not probe or type(d) ~= 'table' or d.net ~= probe.net then return end
    local now = GetGameTimer()
    if lastReport[src] and now - lastReport[src] < 100 then return end
    lastReport[src] = now
    local line = ('client %s %s: follow task %s, group %s, carbine %s, in vehicle %s, in combat %s, health %s')
        :format(nameOf(src), tostring(d.what), tostring(d.task), d.groupOk and 'kept' or 'LOST',
            d.armed and 'yes' or 'no', d.inVeh and 'yes' or 'no', d.combat and 'yes' or 'no',
            tostring(d.health))
    if d.note then line = line .. ' -- ' .. tostring(d.note) end
    out(line)
end)

AddEventHandler('playerDropped', function()
    local src = tonumber(source)
    if src then lastReport[src] = nil end
end)

AddEventHandler('onResourceStop', function(name)
    if name ~= GetCurrentResourceName() then return end
    remove('br_core stopped')
end)
