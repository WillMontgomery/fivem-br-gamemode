-- The locker: which character you play as.
--
-- CLIENT-ONLY, AND THAT IS A DECISION. The model is cosmetic, it replicates by
-- itself (every other client sees your ped, because it IS your ped), and it
-- has no effect on hitboxes the server validates -- damage is decided from
-- server-sampled positions and bone components, not from the model. So there
-- is nothing here the server needs to arbitrate, and adding a round trip would
-- buy a slower locker and one more thing to desync.
--
-- THE APPLY IS THE PREVIEW. There is no separate "trying on" state: clicking a
-- character changes the ped standing in front of the lobby camera, instantly.
-- A locker that needs a confirm step is a locker where you cannot see what you
-- are confirming.
--
-- SetPlayerModel IS DESTRUCTIVE and the order below is not negotiable: it
-- gives you a NEW ped handle, wipes weapons, and resets the health model to
-- GTA's defaults rather than ours. Everything that has to be re-asserted after
-- a model swap is re-asserted here, in one place, because the alternative is
-- discovering it in a match -- a player who changed character in the lobby
-- arriving at the warmup pad with 200 max health and no parachute.

BR = BR or {}
BR.Locker = {}

local KVP = 'br:locker:ped'

-- Spin is the player dragging the ped around. Held here rather than read off
-- the entity every frame: the ped is FROZEN in the lobby, and a frozen entity
-- is exactly the case where "read it back to find out where it is" quietly
-- stops agreeing with what you asked for.
local spin = 0.0
local applying = false

--- @return string
function BR.Locker.chosen()
    local id = GetResourceKvpString(KVP)
    return (id and #id > 0) and id or BR.Config.Peds[1].id
end

--- Put the chosen model on the player.
---
--- Serialised on `applying`: RequestModel is asynchronous, and two overlapping
--- applies would each wait for their own model and then race to be the one
--- that finished last -- with the loser's re-assertions landing on the
--- winner's ped.
--- @param id string|nil  nil re-applies whatever is stored
--- @param cb function|nil
function BR.Locker.apply(id, cb)
    if applying then return end
    applying = true

    local entry = BR.PedById(id or BR.Locker.chosen())
    local hash = GetHashKey(entry.model)

    Citizen.CreateThread(function()
        RequestModel(hash)

        -- ~5 seconds. A model that has not streamed by then is not going to,
        -- and the honest outcome is "you keep the ped you had" rather than a
        -- thread that waits forever holding the applying latch.
        local deadline = GetGameTimer() + 5000
        while not HasModelLoaded(hash) and GetGameTimer() < deadline do
            Citizen.Wait(50)
        end

        if not HasModelLoaded(hash) then
            print(('[br_core] locker: %s (%s) never streamed'):format(entry.id, entry.model))
            applying = false
            if cb then cb(false) end
            return
        end

        -- Where we were, so the swap does not also move us. SetPlayerModel
        -- keeps the position, but it does NOT keep the heading reliably, and
        -- the lobby is a framed shot where a ped facing the wrong way is the
        -- whole picture being wrong.
        local before = PlayerPedId()
        local pos = GetEntityCoords(before)
        local heading = GetEntityHeading(before)

        SetPlayerModel(PlayerId(), hash)
        SetModelAsNoLongerNeeded(hash)

        local ped = PlayerPedId()
        SetEntityCoordsNoOffset(ped, pos.x, pos.y, pos.z, false, false, false)
        SetEntityHeading(ped, heading)

        -- EVERYTHING SetPlayerModel JUST THREW AWAY.
        --
        -- The health model is ours (BR.ToEngineHp and every damage number in
        -- the game depend on maxHealth being what config says); a fresh ped
        -- comes back with GTA's. The default component variation is what
        -- stops some models spawning in their underwear. The relationship
        -- group matters because squadmates.lua allies peds by group and a new
        -- handle is not in anyone's ally set yet.
        BR.Native.initHealthModel()
        SetPedDefaultComponentVariation(ped)
        SetPedCanRagdoll(ped, false)

        -- The lobby's per-frame rules (natives.lua) re-freeze and re-show it
        -- on the next tick, so nothing here has to fight them -- but the
        -- frame between the swap and that tick is a frame where an unfrozen
        -- ped can start falling, and the lobby mark is not always on the
        -- ground.
        FreezeEntityPosition(ped, true)

        SetResourceKvp(KVP, entry.id)
        applying = false

        print(('[br_core] locker: %s (%s)'):format(entry.id, entry.model))
        if cb then cb(true) end
    end)
end

--- Turn the character in place.
---
--- The CAMERA never moves -- it is aimed at a coordinate, not at the entity,
--- which is what lets the ped rotate inside a fixed frame instead of the world
--- swinging around them.
--- @param delta number  degrees
function BR.Locker.spinBy(delta)
    if BR.State.me.state ~= BR.PlayerState.LOBBY then return end
    spin = (spin + (tonumber(delta) or 0.0)) % 360.0
    SetEntityHeading(PlayerPedId(),
        ((BR.Config.Match.lobbyPos.heading + spin) % 360.0))
end

--- Which id is mid-swap, so the screen can say so. Nil when nothing is.
local loadingId = nil

--- Send the roster and the current choice to the interface.
function BR.Locker.push()
    local list = {}
    for _, p in ipairs(BR.Config.Peds) do
        list[#list + 1] = { id = p.id, name = p.name }
    end
    TriggerEvent('br:ui:sendLocal', BR.Nui.LOCKER,
        -- `loading` is the id being STREAMED IN right now. A model that is not
        -- already in memory takes a moment to arrive, and until it does the
        -- button looked like it had not registered the click -- so players
        -- clicked again (user, 2026-08-09: "a delay ... they don't know
        -- why"). Naming which one is loading lets the screen mark that one
        -- button rather than blocking the whole page.
        { peds = list, chosen = BR.Locker.chosen(), loading = loadingId })
end

AddEventHandler('br:ui:ready', function()
    BR.Locker.push()
end)

-- The stored choice is applied ONCE, when the player first stands in the
-- lobby -- not on a transition, because there is no transition into the very
-- first lobby. Watching my own state covers the first spawn, a reconnect and
-- a br_core restart with one rule.
--
-- It does NOT re-apply on every return to the lobby: the model survives a
-- match, and swapping it again between rounds would be a visible hitch (and a
-- weapon wipe) for no change at all.
local appliedOnce = false
BR.Loop.register(BR.Loop.TICK, 'locker.initial', function()
    if appliedOnce then return end
    if BR.State.me.state ~= BR.PlayerState.LOBBY then return end
    appliedOnce = true

    -- Only if it is not already what we want. A fresh session hands you a
    -- default GTA ped, so this normally does swap -- but a br_core restart
    -- mid-session should be free.
    local want = GetHashKey(BR.PedById(BR.Locker.chosen()).model)
    if GetEntityModel(PlayerPedId()) ~= want then
        BR.Locker.apply(nil)
    end
end)

-- UI actions arrive through br_ui's forwarder, which is where every gameplay
-- callback lands: br_ui owns the page and the callbacks, br_core owns what
-- they mean.
AddEventHandler('br:ui:action', function(name, data)
    if name == BR.NuiCb.LOCKER_PICK then
        local id = data and data.id

        -- THE LAST PRESS WINS, and a press during a swap is not dropped.
        --
        -- Clicking quickly did nothing at all (user, 2026-08-09). Each pick
        -- starts a model request that takes as long as it takes, and a second
        -- pick arriving mid-flight raced the first: two apply() calls, two
        -- callbacks, and the loser could land AFTER the winner and put the
        -- earlier model back -- or the in-flight request could simply swallow
        -- the newer choice.
        --
        -- So a pick during a swap is REMEMBERED rather than run, and applied
        -- when the current one finishes. Remembered, not queued: pressing
        -- four buttons quickly should end on the fourth, not play all four
        -- back in sequence.
        if loadingId then
            BR.Locker.queued = id
            return
        end

        loadingId = id
        BR.Locker.push()   -- the button can show it is working

        BR.Locker.apply(id, function(ok)
            loadingId = nil
            local nextId = BR.Locker.queued
            BR.Locker.queued = nil
            BR.Locker.push()
            if nextId and nextId ~= id then
                TriggerEvent('br:ui:action', BR.NuiCb.LOCKER_PICK, { id = nextId })
            end
            if not ok then
                BR.Notify('That character could not be loaded.', 'warn')
            end
        end)
    elseif name == BR.NuiCb.LOCKER_SPIN then
        BR.Locker.spinBy(data and data.delta)
    end
end)

-- EVERY MODEL NAME IN THE ROSTER IS HAND-TYPED, which makes a typo the most
-- likely thing wrong with this file -- and the failure mode is silent: the
-- request never resolves, the five-second deadline expires, and the player
-- clicks a character that simply does nothing. Checked once at startup so a
-- bad entry is a line in the console rather than a bug report.
--
-- IsModelInCdimage answers "does the game have this at all", which is the
-- question; IsModelAPed rules out the other half, where a valid name turns out
-- to be a vehicle or a prop and SetPlayerModel quietly does nothing useful.
AddEventHandler('onClientResourceStart', function(res)
    if res ~= GetCurrentResourceName() then return end
    local bad = 0
    for _, p in ipairs(BR.Config.Peds) do
        local hash = GetHashKey(p.model)
        if not IsModelInCdimage(hash) or not IsModelAPed(hash) then
            bad = bad + 1
            print(('[br_core] locker: %s -> "%s" is not a ped model on this build')
                :format(p.id, p.model))
        end
    end
    if bad > 0 then
        print(('[br_core] locker: %d of %d characters are unusable')
            :format(bad, #BR.Config.Peds))
    end
end)

RegisterCommand('brlocker', function(_, args)
    if args[1] then
        BR.Locker.apply(args[1])
        return
    end
    print('=== locker ===')
    print(('  chosen  %s'):format(BR.Locker.chosen()))
    for _, p in ipairs(BR.Config.Peds) do
        print(('  %-11s %-24s %s'):format(p.id, p.model,
            p.id == BR.Locker.chosen() and '<-' or ''))
    end
    print('  usage: brlocker [id]')
end, false)
