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

-- Colours live in BR.SquadColours (br_lib/shared/enums.lua), keyed on the
-- member index the server assigns -- stable because it sorts by server id, so
-- every client colours the squad identically. The local table this replaced
-- disagreed with the one markers.lua used, which is why a teammate's dot and
-- their destination marker were different colours (and included purple, which
-- belongs to the storm).

local blips    = {}   -- [src] = blip handle
local tags     = {}   -- [src] = { tag = gamerTagId, ped = pedHandle }
local mates    = {}   -- [src] = latest server record for that squadmate
local lastPush = 0

local PLAYER_GROUP = GetHashKey('PLAYER')

-- Every ped we have ever moved into BR_ALLY, so leaving the squad (or the
-- squad dissolving) can hand ALL of them back -- the group is no longer
-- tied to tag lifetime (see the loop below).
local allied = {}

local function dropTag(src)
    local t = tags[src]
    if t then
        RemoveMpGamerTag(t.tag)
        tags[src] = nil
    end
end

--- Hand every allied ped back to the default group. Called when the squad
--- stops being a squad -- an EX-squadmate must not stay unshootable.
local function disbandAllies()
    for ped in pairs(allied) do
        if DoesEntityExist(ped) then
            SetPedRelationshipGroupHash(ped, PLAYER_GROUP)
        end
    end
    allied = {}
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
    disbandAllies()
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
                SetBlipColour(b, BR.SquadColour(m.i).blip)
                SetBlipAsShortRange(b, false)   -- squadmates matter at any range
                BeginTextCommandSetBlipName('STRING')
                AddTextComponentSubstringPlayerName(m.name)
                EndTextCommandSetBlipName(b)
                blips[m.src] = b
            else
                SetBlipCoords(b, m.x + 0.0, m.y + 0.0, 0.0)
            end

            -- A dead mate's blip STAYS, dimmed. Where they went down is the
            -- whole reason to keep it; a full-brightness dot would read as a
            -- live teammate to rotate to. Set unconditionally rather than on
            -- the state edge -- four native calls a second is nothing, and an
            -- edge test cannot cover the blip that was born dead (a mate who
            -- died while this client was out of the squad push).
            local dead = m.state == BR.PlayerState.DEAD
                or m.state == BR.PlayerState.SPECTATING
            SetBlipAlpha(blips[m.src], dead and 120 or 255)
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
        local player = GetPlayerFromServerId(src) -- scope-ok: overhead name + local relationship group need the local ped; absence just means neither applies yet
        local ped = (player ~= -1) and GetPlayerPed(player) or 0 -- scope-ok: same presentation-only use

        -- SQUAD-LEVEL PEACE IS NOT PRESENTATION -- and it is re-asserted
        -- EVERY tick, for every streamed-in mate, in every state. The old
        -- version set the group once, inside the tag path, only after the
        -- mate had jumped -- so a handle change (or any engine-side group
        -- reset) silently made a teammate shootable again ("in squads I
        -- can kill my own teammates", live report). Ten hash-writes a
        -- second is free; a teamkill is not.
        if ped ~= 0 then
            SetPedRelationshipGroupHash(ped, BR.Native.ALLY_GROUP)
            allied[ped] = true
        end

        -- NO NAME UNTIL THEY HAVE JUMPED: everyone shares the plane during
        -- the flight, and a tag on an invisible rider rendered as a name
        -- floating over the fuselage. Pre-drop there is nothing to label.
        --
        -- DEAD AND DOWNED MATES ARE STILL LABELLED. Nothing hides faster in a
        -- firefight than the question "where did my teammate go down", and the
        -- corpse is the answer. The state is written into the tag so it reads
        -- at a glance rather than being a name that mysteriously stopped
        -- moving (user report, 2026-08-05: could not see dead squadmates).
        local e = BR.State.roster[src]
        local st = e and e.state
        local jumped = st == BR.PlayerState.FREEFALL
            or st == BR.PlayerState.GLIDE
            or st == BR.PlayerState.ALIVE
            or st == BR.PlayerState.DBNO
            or st == BR.PlayerState.DEAD
            or st == BR.PlayerState.SPECTATING

        local mark = ''
        if st == BR.PlayerState.DBNO then mark = ' [DOWN]'
        elseif st == BR.PlayerState.DEAD or st == BR.PlayerState.SPECTATING then
            mark = ' [DEAD]'
        end

        if ped ~= 0 and jumped then
            local t = tags[src]
            -- Re-tag when the ped handle changes (respawn or re-entering
            -- scope hands the mate a new ped, and the old tag dies with the
            -- old handle) OR when the mark changes -- a gamer tag's text is
            -- fixed at creation, so "Alice" becoming "Alice [DEAD]" is a new
            -- tag or it is nothing.
            if not t or t.ped ~= ped or t.mark ~= mark then
                dropTag(src)
                local tag = CreateFakeMpGamerTag(ped, m.name .. mark,
                    false, false, '', 0)
                SetMpGamerTagVisibility(tag, 0, true)   -- component 0: the name
                tags[src] = { tag = tag, ped = ped, mark = mark }
            end
        else
            dropTag(src)
        end
    end
end)

-- FRIENDLY FIRE IS UNDONE, BECAUSE IT CANNOT BE PREVENTED HERE.
--
-- The relationship-group scheme (BR_ALLY + SetCanAttackFriendly) governs AI
-- aggression and melee, and it does NOT stop one player's bullets from
-- damaging another's ped -- which is why teamkilling survived being "fixed"
-- twice (user, 2026-08-05, third report). GTA's own answer is the team system,
-- which this gamemode does not use, so the honest fix at this stage is to
-- notice the damage and put the health back.
--
-- This is a CLIENT-SIDE net and it is temporary: M6 moves damage behind
-- server-side validation, where a shot at a squadmate is simply never applied.
-- Until then, restoring is the difference between a squad that works and one
-- that does not.
--
-- FRAME, not TICK: at 10Hz an automatic weapon lands several rounds between
-- samples, and restoring to a health value that was already three bullets old
-- would leak damage. The per-mate scan only runs on a frame where health
-- actually dropped, so the ordinary cost is two native reads.
local lastHp, lastArmour = nil, nil

BR.Loop.register(BR.Loop.FRAME, 'squadmates.noff', function()
    local st = BR.State.me.state
    if st ~= BR.PlayerState.ALIVE and st ~= BR.PlayerState.WARMUP then
        lastHp, lastArmour = nil, nil
        return
    end

    local ped     = PlayerPedId()
    local hp      = GetEntityHealth(ped)
    local armour  = GetPedArmour(ped)
    local prevHp, prevArmour = lastHp, lastArmour
    lastHp, lastArmour = hp, armour

    if not prevHp then return end

    -- HasEntityBeenDamagedByEntity IS A STICKY FLAG, not "was I hit this
    -- frame". It stays true until the damage record is cleared, so a
    -- squadmate who bumped you in a car thirty seconds ago would still read
    -- as your attacker when an ENEMY finally shoots you -- and their damage
    -- would be undone.
    --
    -- So the record is cleared EVERY frame a mate flag is set, not only when
    -- something was restored. That narrows the window to a single frame: for
    -- a false positive an enemy's bullet and a teammate's would have to land
    -- inside the same frame. It is not zero, and it is the honest limit of
    -- doing this client-side -- M6's server-side validation replaces the
    -- whole approach with never applying the shot in the first place.
    local byMate = false
    for src in pairs(mates) do
        local player = GetPlayerFromServerId(src) -- scope-ok: undoing damage needs the attacker's local ped; out of scope they cannot have shot us
        local matePed = (player ~= -1) and GetPlayerPed(player) or 0 -- scope-ok: same
        if matePed ~= 0 and HasEntityBeenDamagedByEntity(ped, matePed, true) then
            byMate = true
        end
    end

    if byMate then ClearEntityLastDamageEntity(ped) end
    if not byMate then return end
    if hp >= prevHp and armour >= prevArmour then return end

    if hp < prevHp then SetEntityHealth(ped, prevHp) end
    if armour < prevArmour then SetPedArmour(ped, math.floor(prevArmour)) end
    lastHp, lastArmour = prevHp, prevArmour
end)

-- Shared-lobby hygiene. The lobby is ONE routing bucket now, so other lobby
-- players' peds can stream in -- every one of them frozen, invisible-on-
-- their-own-client, at the exact vista point the camera occupies. Their own
-- client's invisibility does not reliably replicate, so this client hides
-- them locally, and un-hides anyone who has moved on to a match state.
local hiddenLobbyPeds = {}
BR.Loop.register(BR.Loop.TICK, 'squadmates.lobbyhide', function()
    for _, player in ipairs(GetActivePlayers()) do -- scope-ok: presentation-only hiding of co-located lobby peds
        if player ~= PlayerId() then
            local srv = GetPlayerServerId(player)
            local ped = GetPlayerPed(player) -- scope-ok: same presentation-only use
            if ped and ped ~= 0 then
                local e = BR.State.roster[srv]
                if e and e.state == BR.PlayerState.LOBBY then
                    SetEntityVisible(ped, false, false)
                    hiddenLobbyPeds[ped] = true
                elseif hiddenLobbyPeds[ped] then
                    SetEntityVisible(ped, true, false)
                    hiddenLobbyPeds[ped] = nil
                end
            end
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
