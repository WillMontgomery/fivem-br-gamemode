-- The bodyguard ownership probe (#401), client half. A DEV TEST, NOT THE
-- FEATURE: server/guardprobe.lua says what `brguardprobe` is for.
--
-- ═══ WHAT THIS HALF DOES ═══
--
-- A networked ped's tasks, flags and relationship group are written on the
-- machine that OWNS it, and ownership moves (the research on #401: to whoever
-- shoots it, even with migration disabled, resetting its tasks on the way).
-- So every client in the guard's bucket watches it, and the one that owns it:
--
--   * ON GAINING IT, first reports what SURVIVED the move -- the follow task's
--     status, whether the guard is still in the probe's group, its carbine, its
--     seat, its health -- and then applies everything again: the group,
--     friendly to the caller's relationship group and hostile to every other,
--     the combat attributes and the follow task. On losing it, says so.
--   * WHILE IT OWNS IT, once a second: a follow task that has ended (and no
--     fight, and no seat) is given again, and reported.
--   * ON `brguardprobe drive`, puts it in the first free passenger seat of the
--     caller's vehicle.
--
-- ═══ FRIENDLY TO THE CALLER'S GROUP ═══
--
-- The guard is put in a group of its own, BR_GUARDPROBE, and only the owning
-- client writes its rows -- companion with the caller's group as
-- BR.Native.groupFor names it from the roster, hate with every other BR group
-- and the stock PLAYER group. It never writes a row between two players' groups,
-- so nobody's own shots change. A caller with no squadmate is in BR_SOLO, which
-- every unsquadded player shares: the guard is then friendly to all of them,
-- and the report says which group it took.
--
-- ═══ NO COST UNTIL IT IS TYPED ═══
--
-- One TICK callback that returns at once while there is no guard: no native,
-- nothing allocated. The scope gate's three natives are not used: the caller's
-- ped is found by the network id the server sends.

BR = BR or {}

local isTrue = BR.NativeTruthy

local GROUP = 'BR_GUARDPROBE'
local MAX_TEAM = 63   -- client/natives.lua's teamFor range: BR_SQ1..BR_SQ63
local FOLLOW = 'SCRIPT_TASK_FOLLOW_TO_OFFSET_OF_ENTITY'
local CARBINE = 'WEAPON_CARBINERIFLE'
local RETASK_MS = 1000

--- What the server said: { net, caller, callerPedNet }, or nil.
local probe = nil
--- Whether this client owned the guard on the last pass, and when it last
--- checked the follow task.
local owned = false
local checkedAt = 0

--- The guard's handle here, or nil when it is not in this client's world.
local function guardHere()
    if not probe then return nil end
    if not isTrue(NetworkDoesNetworkIdExist(probe.net)) then return nil end
    local e = NetworkGetEntityFromNetworkId(probe.net)
    if not e or e == 0 or not isTrue(DoesEntityExist(e)) then return nil end
    return e
end

--- The caller's ped here, or 0.
local function callerPed()
    if not probe then return 0 end
    if GetPlayerServerId(PlayerId()) == probe.caller then return PlayerPedId() end
    local n = probe.callerPedNet
    if not n or not isTrue(NetworkDoesNetworkIdExist(n)) then return 0 end
    return NetworkGetEntityFromNetworkId(n) or 0
end

--- The caller's relationship group, as BR.Native.groupFor names it.
local function callerGroup()
    local S = BR.State or {}
    local row = S.roster and S.roster[probe.caller] or nil
    local me = { src = probe.caller, squadId = row and row.squadId or nil }
    local g = BR.Native and BR.Native.groupFor and BR.Native.groupFor(me, S.roster) or nil
    return g or GetHashKey('BR_SOLO')
end

--- The probe's own rows: companion with `friend`, hate with every other.
local function relate(friend)
    AddRelationshipGroup(GROUP)
    local g = GetHashKey(GROUP)
    local function set(rel, other)
        SetRelationshipBetweenGroups(rel, g, other)
        SetRelationshipBetweenGroups(rel, other, g)
    end
    set(5, GetHashKey('PLAYER'))
    set(5, GetHashKey('BR_SOLO'))
    for n = 1, MAX_TEAM do set(5, GetHashKey(('BR_SQ%d'):format(n))) end
    set(0, friend)
    return g
end

--- What the guard is right now, for a report.
local function looks(guard, what, note)
    local veh = GetVehiclePedIsIn(guard, false)
    return {
        net = probe.net, what = what, note = note,
        task = GetScriptTaskStatus(guard, GetHashKey(FOLLOW)),
        groupOk = GetPedRelationshipGroupHash(guard) == GetHashKey(GROUP),
        armed = GetSelectedPedWeapon(guard) == GetHashKey(CARBINE),
        inVeh = veh ~= nil and veh ~= 0,
        combat = isTrue(IsPedInCombat(guard, 0)),
        health = GetEntityHealth(guard),
    }
end

local function report(d)
    print(('[br_core] guardprobe: %s -- follow task %s, group %s, carbine %s, in vehicle %s')
        :format(d.what, tostring(d.task), d.groupOk and 'kept' or 'LOST',
            d.armed and 'yes' or 'no', d.inVeh and 'yes' or 'no'))
    TriggerServerEvent('br:guardprobe:report', d)
end

--- Give the follow task, unless the guard is seated.
local function follow(guard)
    local veh = GetVehiclePedIsIn(guard, false)
    if veh ~= nil and veh ~= 0 then return false end
    local target = callerPed()
    if not target or target == 0 then return false end
    TaskFollowToOffsetOfEntity(guard, target, 0.0, -2.0, 0.0, 3.0, -1, 1.5, true)
    return true
end

--- Everything the owner applies: the group, the fight, the weapon, the task.
local function apply(guard)
    local friend = callerGroup()
    SetPedRelationshipGroupHash(guard, relate(friend))
    SetPedCombatAttributes(guard, 46, true)   -- always fight
    SetPedFleeAttributes(guard, 0, false)
    SetPedKeepTask(guard, true)
    local carbine = GetHashKey(CARBINE)
    if not isTrue(HasPedGotWeapon(guard, carbine, false)) then
        GiveWeaponToPed(guard, carbine, 250, false, true)
    end
    follow(guard)
    return friend
end

BR.Loop.register(BR.Loop.TICK, 'guardprobe', function()
    if not probe then return end
    local guard = guardHere()
    local mine = guard ~= nil and isTrue(NetworkHasControlOfEntity(guard))
    if mine and not owned then
        owned = true
        local d = looks(guard, 'gained ownership')
        local friend = apply(guard)
        d.note = ('re-applied; friendly to group %d'):format(friend)
        report(d)
        checkedAt = GetGameTimer()
    elseif owned and not mine then
        owned = false
        TriggerServerEvent('br:guardprobe:report', { net = probe.net, what = 'lost ownership' })
    elseif mine then
        local now = GetGameTimer()
        if now - checkedAt >= RETASK_MS then
            checkedAt = now
            -- 7: the script task is not running (GET_SCRIPT_TASK_STATUS).
            if GetScriptTaskStatus(guard, GetHashKey(FOLLOW)) == 7
               and not isTrue(IsPedInCombat(guard, 0)) and follow(guard) then
                report(looks(guard, 'follow task re-given'))
            end
        end
    end
end)

RegisterNetEvent('br:guardprobe:state')
AddEventHandler('br:guardprobe:state', function(d)
    if type(d) ~= 'table' or type(d.net) ~= 'number' then
        probe, owned = nil, false
        return
    end
    local same = probe ~= nil and probe.net == d.net
    probe = { net = d.net, caller = tonumber(d.caller), callerPedNet = tonumber(d.callerPedNet) }
    if not same then owned = false end
end)

-- `brguardprobe drive`: the owner seats it, in the first free passenger seat.
RegisterNetEvent('br:guardprobe:drive')
AddEventHandler('br:guardprobe:drive', function(d)
    if not probe or type(d) ~= 'table' or d.net ~= probe.net then return end
    local guard = guardHere()
    if not guard or not isTrue(NetworkHasControlOfEntity(guard)) then return end
    local veh = isTrue(NetworkDoesNetworkIdExist(d.veh)) and NetworkGetEntityFromNetworkId(d.veh) or 0
    if not veh or veh == 0 then
        report(looks(guard, 'drive', 'the vehicle is not in this client\'s world'))
        return
    end
    local seats = GetVehicleMaxNumberOfPassengers(veh)
    for seat = 0, seats - 1 do
        if isTrue(IsVehicleSeatFree(veh, seat)) then
            ClearPedTasksImmediately(guard)
            SetPedIntoVehicle(guard, veh, seat)
            -- Stays in the seat it was given, not the wheel (the research's
            -- config flag 184).
            SetPedConfigFlag(guard, 184, true)
            report(looks(guard, 'drive', ('seated in seat %d'):format(seat)))
            return
        end
    end
    report(looks(guard, 'drive', 'no free passenger seat'))
end)
