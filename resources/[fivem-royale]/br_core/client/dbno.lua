-- Downed but not out: the client half.
--
-- EVERYTHING HERE IS PRESENTATION AND INPUT. The bleed timer, the revive
-- distance and the moment a downed player is finally eliminated all live on
-- the server (server/combat.lua) -- a client that strips this file out entirely
-- bleeds out at exactly the same second, holding a rifle and standing upright
-- while everybody else watches a body on the floor. That is why the DBNO_SET
-- handler lives here rather than in the mirror: unlike STORM_DAMAGE and
-- HIT_DAMAGE, nothing on this side is load-bearing for the outcome.
--
-- Two jobs:
--
--   1. BEING DOWN. Take the weapon away, put the player on the floor, keep
--      them there, and let them crawl -- which is the whole reason the state
--      looks different from death at a distance (owner, 2026-08-09): an enemy
--      across the street has to be able to tell "finish them" from "they are
--      already gone", and a body that moves is the only signal that carries
--      that far.
--
--   2. PICKING SOMEBODY UP. A hold on the interact key, reusing the crate
--      machinery rather than a second implementation of it.

BR = BR or {}
BR.Dbno = {}

local M = BR.Config.Match

-- What the server last told us about our OWN downed state. Held whole, because
-- the UI envelope is sent whole -- REVIVE_PROGRESS merges into this and the
-- merged copy goes across the bridge, so there is one shape and one writer.
local mine = { downed = false, bleedEndsAt = 0, reviverName = nil,
               revivePct = 0.0 }

-- The revive we are performing on somebody else, or nil.
local holding = nil   -- { target = src, from = ms }

-- Whether we have told the server we are holding. The key can be released and
-- re-pressed faster than the round trip, so the request is edge-driven.
local sentStart = false

-- --------------------------------------------------------------------------
-- Being down
-- --------------------------------------------------------------------------

--- Push the whole downed payload at the interface.
local function pushMine()
    TriggerEvent('br:ui:sendLocal', BR.Nui.DBNO, {
        downed      = mine.downed and true or false,
        bleedEndsAt = mine.bleedEndsAt or 0,
        reviverName = mine.reviverName,
        revivePct   = mine.revivePct or 0.0,
    })
end

-- The crawl animation, resolved once at first use.
--
-- PROBED, NOT ASSUMED. `SetPedMovementClipset` with a crawl clipset is the
-- clean answer if the clipset exists on this build, and the fallback is the
-- injured-ground animation played as a loop. Neither is documented anywhere
-- authoritative for a networked FiveM client, and a wrong dictionary name is
-- invisible to luac and to the unit tests -- it throws at runtime, and five
-- throws suspend the whole frame callback. So the dictionary is requested and
-- CHECKED, and a build that has neither degrades to lying still rather than to
-- a dead subsystem.
local CRAWL = {
    clipset = 'move_crawl',
    dict    = 'move_injured_ground',
    anim    = 'front_loop',
    picked  = nil,   -- 'clipset' | 'anim' | 'none'
}

--- Work out which crawl this build can actually do. Returns the choice.
--- @return string
local function resolveCrawl()
    if CRAWL.picked then return CRAWL.picked end

    -- The clipset route first: it keeps GTA's own locomotion, so the player
    -- steers with the stick and the engine handles turning and slopes.
    RequestClipSet(CRAWL.clipset)
    local deadline = GetGameTimer() + 500
    while not HasClipSetLoaded(CRAWL.clipset) and GetGameTimer() < deadline do
        Citizen.Wait(0)
    end
    if HasClipSetLoaded(CRAWL.clipset) then
        CRAWL.picked = 'clipset'
        return CRAWL.picked
    end

    RequestAnimDict(CRAWL.dict)
    deadline = GetGameTimer() + 500
    while not HasAnimDictLoaded(CRAWL.dict) and GetGameTimer() < deadline do
        Citizen.Wait(0)
    end
    CRAWL.picked = HasAnimDictLoaded(CRAWL.dict) and 'anim' or 'none'

    if CRAWL.picked == 'none' then
        print(('[br_core] dbno: no crawl available (clipset "%s" and dict "%s" both absent) -- downed players will lie still')
            :format(CRAWL.clipset, CRAWL.dict))
    end
    return CRAWL.picked
end

--- Put the player on the floor and start whatever crawl this build supports.
local function enterDowned()
    local ped = PlayerPedId()

    -- THE WEAPON GOES FIRST, before anything can be fired from the floor. The
    -- inventory's own weapon application is already suspended by canArm(); this
    -- is the half that clears what is currently in their hands.
    RemoveAllPedWeapons(ped, true)
    SetCurrentPedWeapon(ped, GetHashKey('WEAPON_UNARMED'), true)

    -- The knockdown instant. Ragdoll type 0 (CTaskNMRelax) and only for the
    -- moment of falling -- sustained ragdoll is too unstable to hold a player
    -- in, which is why the crawl is animation-driven from here on.
    BR.Native.knockdown(1200, 1600)

    Citizen.CreateThread(function()
        -- Let the ragdoll land before asking for an animation on top of it, or
        -- the clip is cancelled by a physics state that has not settled.
        Citizen.Wait(1200)
        if not mine.downed then return end

        local choice = resolveCrawl()
        local p = PlayerPedId()
        if choice == 'clipset' then
            SetPedMovementClipset(p, CRAWL.clipset, 1.0)
            SetPedMoveRateOverride(p, M.dbnoCrawlSpeed or 0.55)
        elseif choice == 'anim' then
            TaskPlayAnim(p, CRAWL.dict, CRAWL.anim, 8.0, -8.0, -1,
                         1, 0.0, false, false, false)
        end
    end)
end

--- Stand back up: undo everything enterDowned did.
local function leaveDowned()
    local ped = PlayerPedId()
    ResetPedMovementClipset(ped, 0.0)
    SetPedMoveRateOverride(ped, 1.0)
    ClearPedTasks(ped)
    -- The inventory re-arms itself on the next pass, now that canArm() is true
    -- again; asking it here would race the state delta that made it true.
end

RegisterNetEvent(BR.Net.DBNO_SET)
AddEventHandler(BR.Net.DBNO_SET, function(d)
    if type(d) ~= 'table' then return end

    local was = mine.downed
    mine.downed      = d.downed == true
    mine.bleedEndsAt = d.bleedEndsAt or 0
    mine.reviverName = d.reviverName
    mine.revivePct   = d.revivePct or 0.0

    if mine.downed and not was then
        enterDowned()
        BR.Sfx.play('hit.crit')
    elseif was and not mine.downed then
        leaveDowned()
    end

    pushMine()
end)

-- THE SERVER SAYS WHAT THE NUMBER IS; WE APPLY IT.
--
-- The same contract as STORM_DAMAGE and HIT_DAMAGE, in absolute form rather
-- than as a delta -- which is what a revive needs, since the point is to land
-- on a specific health rather than to move by an amount. Handled here because
-- a revive is the only thing that sends it.
RegisterNetEvent(BR.Net.HEALTH_SYNC)
AddEventHandler(BR.Net.HEALTH_SYNC, function(d)
    if type(d) ~= 'table' then return end
    if d.hp then BR.Native.setDisplayHealth(tonumber(d.hp) or 0) end
    if d.armour then SetPedArmour(PlayerPedId(), math.floor(tonumber(d.armour) or 0)) end
end)

-- Progress on the revive somebody is performing on US. Merged into the state
-- we already hold rather than sent as its own envelope: the interface reads
-- one payload for the whole overlay, so there is one shape and no merge
-- protocol on the far side.
RegisterNetEvent(BR.Net.REVIVE_PROGRESS)
AddEventHandler(BR.Net.REVIVE_PROGRESS, function(d)
    if type(d) ~= 'table' then return end

    -- Addressed at us as the DOWNED player.
    if mine.downed and d.target == BR.State.me.src then
        mine.revivePct   = d.pct or 0.0
        mine.reviverName = d.cancelled and nil or (d.reviverName or mine.reviverName)
        pushMine()
        return
    end

    -- Otherwise we are the one holding, and this is our ring.
    if not holding or d.target ~= holding.target then return end
    if d.cancelled or d.done then
        holding = nil
        sentStart = false
    end
end)

-- --------------------------------------------------------------------------
-- Picking somebody up
-- --------------------------------------------------------------------------

--- The nearest downed squadmate within reach, or nil.
---
--- POSITION COMES FROM THE PED, not from the 1Hz squad broadcast. At a metre
--- and a half the mate is streamed in by definition, and a position that is up
--- to a second old is a metre of error on a check whose whole range is one and
--- a half. The ped handle is resolved through BR.Squadmates.pedOf so this file
--- adds no second scope exception.
--- @return integer|nil src, number|nil dist
local function nearestDowned()
    local me = BR.State.me
    if me.state ~= BR.PlayerState.ALIVE or not me.squadId then return nil end

    local p = GetEntityCoords(PlayerPedId())
    local reach = M.dbnoReviveDist or 1.5
    local bestSrc, bestD = nil, nil

    for src, e in pairs(BR.State.roster) do
        if src ~= me.src and e.squadId == me.squadId
           and e.state == BR.PlayerState.DBNO then
            local ped = BR.Squadmates.pedOf(src)
            if ped ~= 0 then
                local c = GetEntityCoords(ped)
                local d = #(c - p)
                if d <= reach and (not bestD or d < bestD) then
                    bestSrc, bestD = src, d
                end
            end
        end
    end
    return bestSrc, bestD
end

-- The prompt page is the crate's. One browser for every world prompt in the
-- game, created on whichever of the two asks first.
local function promptPage()
    return BR.Dui.page('lootprompt', 'nui://br_ui/dui/prompt.html', 512, 256)
end

-- Sent on change only, exactly like the loot prompt: a re-send restarts the
-- ring animation from zero, so a hold already running is left alone.
local shownFor = nil

--- @param src integer|nil  the downed mate to prompt for, or nil to clear
--- @param holdMs number|nil
local function setPrompt(src, holdMs)
    local page = promptPage()

    if not src then
        if shownFor == nil then return end
        shownFor = nil
        BR.Dui.send(page, { t = 'prompt', show = false })
        return
    end

    local key = tostring(src) .. ':' .. tostring(holdMs)
    if key == shownFor then return end
    shownFor = key

    local e = BR.State.roster[src]
    BR.Dui.send(page, {
        t      = 'prompt',
        show   = true,
        label  = (e and e.name or 'Teammate'),
        hint   = 'Hold to revive',
        key    = BR.Native.keyLabelForCommand('brinteract',
                                              BR.Config.Loot.promptControl or 51),
        -- The danger colour, not a rarity: this is the one world prompt that
        -- is about a person rather than an object.
        colour = '#F87171',
        ring   = true,
        holdMs = holdMs,
    })
end

BR.Loop.register(BR.Loop.FRAME, 'dbno.revive', function()
    local target, dist = nearestDowned()

    -- THE YIELD, and it is raised from the reach test rather than from the
    -- keypress. Deciding it at the moment the key goes down would mean the
    -- crate prompt was still on screen when the player pressed, so the thing
    -- they were looking at and the thing that happened would disagree.
    BR.Loot.suppress(target ~= nil or holding ~= nil)

    if holding then
        -- The hold is only ours to keep while the reach still holds. The
        -- SERVER makes the same judgement every 250ms off its own position
        -- samples and is the one that counts; this is what keeps the ring
        -- honest in between.
        if target ~= holding.target or not BR.Keys.isHeld('interact') then
            TriggerServerEvent(BR.Net.REVIVE_STOP)
            holding, sentStart = nil, false
            setPrompt(target, nil)
        else
            setPrompt(holding.target, math.floor((M.dbnoReviveTime or 8.0) * 1000))
        end
    else
        setPrompt(target, nil)
    end

    if not target then return end

    -- Drawn natively at the mate's own position, every frame, so the label is
    -- welded to the body however fast the camera moves.
    local ped = BR.Squadmates.pedOf(holding and holding.target or target)
    if ped ~= 0 then
        local c = GetEntityCoords(ped)
        BR.Dui.drawWorld(promptPage(), c.x, c.y, c.z + 0.9,
                         BR.Config.Loot.promptScale or 2.0)
    end
end)

BR.Keys.on('interact', function(pressed)
    if not pressed then
        if holding then
            TriggerServerEvent(BR.Net.REVIVE_STOP)
            holding, sentStart = nil, false
        end
        return
    end

    local target = nearestDowned()
    if not target then return end

    holding = { target = target, from = GetGameTimer() }
    if not sentStart then
        sentStart = true
        TriggerServerEvent(BR.Net.REVIVE_START, { target = target })
    end
end)

-- --------------------------------------------------------------------------
-- Teardown
-- --------------------------------------------------------------------------

--- Forget everything. A match ending mid-revive, or mid-bleed, must not leave
--- a prompt, a movement clipset or a stale overlay behind -- the clipset in
--- particular outlives the state that set it and would follow the player into
--- the lobby at crawling pace.
local function forgetAll()
    if mine.downed then
        mine.downed = false
        leaveDowned()
        pushMine()
    end
    holding, sentStart = nil, false
    setPrompt(nil)
end

RegisterNetEvent(BR.Net.STATE)
AddEventHandler(BR.Net.STATE, function(d)
    if d and (d.state == BR.MatchState.ENDED
              or d.state == BR.MatchState.CLEANUP
              or d.state == BR.MatchState.WAITING) then
        forgetAll()
    end
end)

AddEventHandler('onClientResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    -- A movement clipset survives a resource restart the same way an undeleted
    -- object does; the player would be left crawling with nothing left running
    -- to stand them up.
    local ped = PlayerPedId()
    ResetPedMovementClipset(ped, 0.0)
    SetPedMoveRateOverride(ped, 1.0)
end)

-- --------------------------------------------------------------------------
-- Debug
-- --------------------------------------------------------------------------

RegisterCommand('brdbno', function()
    print('=== dbno (client) ===')
    print(('  me         : %s'):format(tostring(BR.State.me.state)))
    print(('  downed     : %s  bleedEndsAt %s  (%.1fs left)')
        :format(tostring(mine.downed), tostring(mine.bleedEndsAt),
                (mine.bleedEndsAt - BR.Clock.now()) / 1000.0))
    print(('  reviver    : %s  %.0f%%')
        :format(tostring(mine.reviverName), mine.revivePct or 0.0))
    print(('  crawl      : %s'):format(tostring(CRAWL.picked or 'not resolved yet')))
    local target, dist = nearestDowned()
    print(('  in reach   : %s%s'):format(tostring(target),
        dist and (' at %.2fm'):format(dist) or ''))
    print(('  holding    : %s'):format(holding and tostring(holding.target) or '-'))
    print('  downed squadmates the mirror knows about:')
    local n = 0
    for src, e in pairs(BR.State.roster) do
        if e.state == BR.PlayerState.DBNO then
            n = n + 1
            print(('    %-4d %-18s squad %s  ped %d')
                :format(src, tostring(e.name), tostring(e.squadId),
                        BR.Squadmates.pedOf(src)))
        end
    end
    if n == 0 then print('    (none)') end
end, false)
