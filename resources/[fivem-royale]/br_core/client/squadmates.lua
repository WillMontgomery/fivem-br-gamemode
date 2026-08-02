-- Squadmate presence: minimap blips and overhead names, SQUAD ONLY.
--
-- Fortnite's rule, enforced end to end: you see your squad, and nobody else.
-- Solos see no one. Other squads see nothing of yours. The privacy boundary is
-- the SERVER's -- br:squad:pos is only ever addressed to squad members, so a
-- modified client cannot widen it; everything in this file is presentation.
--
-- Blips are drawn from SERVER coordinates (AddBlipForCoord), not from entities,
-- so a squadmate 3km away still has a blip -- the 424m scope ceiling does not
-- apply to data the server sends. Overhead names DO need the ped, so they
-- exist only while the mate is in scope: exactly the range where you can see
-- the ped to hang a name over.

BR = BR or {}

-- Member index -> blip colour. Stable because the server sorts members by
-- server id before numbering them, so every client colours the squad the same.
local BLIP_COLOURS = { 3, 2, 5, 1, 8, 27, 15, 12 }

local blips    = {}   -- [src] = blip handle
local tags     = {}   -- [src] = { tag = gamerTagId, ped = pedHandle }
local mates    = {}   -- [src] = latest server record for that squadmate
local lastPush = 0

local PLAYER_GROUP = GetHashKey('PLAYER')

local function dropTag(src)
    local t = tags[src]
    if t then
        RemoveMpGamerTag(t.tag)
        -- Hand the ped back to the default group, or an EX-squadmate would
        -- stay unshootable until their ped handle happened to change.
        if DoesEntityExist(t.ped) then
            SetPedRelationshipGroupHash(t.ped, PLAYER_GROUP)
        end
        tags[src] = nil
    end
end

local function dropMate(src)
    local b = blips[src]
    if b then
        if DoesBlipExist(b) then RemoveBlip(b) end
        blips[src] = nil
    end
    dropTag(src)
    mates[src] = nil
end

local function clearAll()
    for src in pairs(mates) do dropMate(src) end
end

RegisterNetEvent(BR.Net.SQUAD_POS)
AddEventHandler(BR.Net.SQUAD_POS, function(list)
    lastPush = GetGameTimer()

    local seen = {}
    for _, m in ipairs(list or {}) do
        if m.src ~= BR.State.me.src then
            seen[m.src] = true
            mates[m.src] = m

            local b = blips[m.src]
            if not b or not DoesBlipExist(b) then
                b = AddBlipForCoord(m.x + 0.0, m.y + 0.0, 0.0)
                SetBlipSprite(b, 1)
                SetBlipScale(b, 0.85)
                SetBlipColour(b, BLIP_COLOURS[((m.i - 1) % #BLIP_COLOURS) + 1])
                SetBlipAsShortRange(b, false)   -- squadmates matter at any range
                BeginTextCommandSetBlipName('STRING')
                AddTextComponentSubstringPlayerName(m.name)
                EndTextCommandSetBlipName(b)
                blips[m.src] = b
            else
                SetBlipCoords(b, m.x + 0.0, m.y + 0.0, 0.0)
            end
        end
    end

    -- Anyone the server stopped sending is out -- died, left, next match's
    -- squads reshuffled. The push IS the membership list.
    for src in pairs(mates) do
        if not seen[src] then dropMate(src) end
    end
end)

-- Overhead names, ally grouping, and staleness.
--
-- The server goes quiet instead of sending an empty list when a squad stops
-- being a squad (last mate died, match ended while the job was between
-- pushes), so silence longer than a few pushes means "no squad" -- without
-- the staleness check the last blip of a dead squadmate would outlive them
-- indefinitely.
--
-- TICK, not SLOW: this loop is also what moves a freshly streamed-in
-- squadmate into the BR_ALLY group, and until that happens they are
-- shootable -- at 10Hz that window is a bullet or two, at 1Hz a burst.
BR.Loop.register(BR.Loop.TICK, 'squadmates.tags', function()
    if next(mates) and (GetGameTimer() - lastPush) > 3500 then
        clearAll()
        return
    end

    for src, m in pairs(mates) do
        -- Presentation-only use of scope: a name can only hang over a ped
        -- that is streamed in, and no game state is derived from whether it
        -- is. Out of scope, the coord blip above still shows where they are.
        local player = GetPlayerFromServerId(src) -- scope-ok: overhead name needs the local ped; absence just means no tag
        if player ~= -1 then
            local ped = GetPlayerPed(player) -- scope-ok: same presentation-only use
            local t = tags[src]
            -- Re-tag when the ped handle changes: respawn or re-entering
            -- scope hands the mate a new ped, and the old tag dies with the
            -- old handle.
            if ped ~= 0 and (not t or t.ped ~= ped) then
                dropTag(src)
                local tag = CreateFakeMpGamerTag(ped, m.name, false, false, '', 0)
                SetMpGamerTagVisibility(tag, 0, true)   -- component 0: the name
                -- Squad-level peace: same group as my own ped, and my
                -- canAttackFriendly=false (gamerules) refuses the damage.
                SetPedRelationshipGroupHash(ped, BR.Native.ALLY_GROUP)
                tags[src] = { tag = tag, ped = ped }
            end
        else
            dropTag(src)
        end
    end
end)

-- Match over: the squad no longer exists, so neither does its presence.
RegisterNetEvent(BR.Net.STATE)
AddEventHandler(BR.Net.STATE, function(d)
    if d.state == BR.MatchState.ENDED
       or d.state == BR.MatchState.CLEANUP
       or d.state == BR.MatchState.WAITING then
        clearAll()
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    clearAll()
end)
