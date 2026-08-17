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

-- THE DOWNED POSE.
--
-- WHAT WENT WRONG THE FIRST TIME, because it is the whole reason this is now
-- written the careful way. The first cut called
-- `SetPedMovementClipset(ped, 'move_crawl')`. `move_crawl` is an ANIMATION
-- DICTIONARY, not a locomotion clipset -- and handing a movement clipset
-- something that is not one does not fail, it puts the ped in BIND POSE. A
-- downed player stood there in a perfect T-pose (owner, in game). The clipset
-- request even reported success, which is how it got past the guard that was
-- supposed to catch exactly this.
--
-- So: no movement clipset unless somebody has watched one work. These are
-- animation dictionaries played as a loop, tried in order, and a build with
-- none of them lies still rather than T-posing. `/brcrawl` is the probe that
-- turns this list from a guess into a fact -- run it in game and the answer
-- decides what ships.
-- CHOSEN IN GAME, 2026-08-09: move_injured_ground / front_loop is the one that
-- looks like a downed player (owner, watching all four through /brcrawl). It is
-- first because first is what ships; the rest stay as the fallback chain and as
-- the record of what was actually compared.
local CRAWL_CANDIDATES = {
    { dict = 'move_injured_ground',       anim = 'front_loop'  },
    { dict = 'move_crawl',                anim = 'onfront_fwd' },
    { dict = 'combat@damage@writhe',      anim = 'writhe_loop' },
    { dict = 'random@dealgonewrong',      anim = 'idle_a'      },
}

-- The one that loaded, or false once every candidate has been tried and failed.
local crawl = nil

--- Request a dictionary and wait a beat for it. Returns whether it landed.
--- @param dict string
--- @return boolean
local function loadDict(dict)
    if HasAnimDictLoaded(dict) then return true end
    -- DoesAnimDictExist first: requesting a name the game has never heard of
    -- is a streaming request that can never complete, so without this the
    -- 400ms wait below would be paid for every bad guess in the list.
    if DoesAnimDictExist and not DoesAnimDictExist(dict) then return false end

    RequestAnimDict(dict)
    local deadline = GetGameTimer() + 400
    while not HasAnimDictLoaded(dict) and GetGameTimer() < deadline do
        Citizen.Wait(0)
    end
    return HasAnimDictLoaded(dict)
end

--- The first candidate this build can actually play, or nil.
--- @return table|nil
local function resolveCrawl()
    if crawl ~= nil then return crawl or nil end

    for _, c in ipairs(CRAWL_CANDIDATES) do
        if loadDict(c.dict) then
            crawl = c
            print(('[br_core] dbno: downed pose is %s / %s'):format(c.dict, c.anim))
            return crawl
        end
    end

    crawl = false
    print('[br_core] dbno: no downed animation on this build -- downed players will lie still. Run /brcrawl.')
    return nil
end

--- Start (or restart) the downed loop on our own ped.
--- @param force boolean|nil  play even if something is already running
local function playCrawl(force)
    local c = resolveCrawl()
    if not c then return end

    local ped = PlayerPedId()
    if not force and IsEntityPlayingAnim(ped, c.dict, c.anim, 3) then return end
    -- Flag 1 is the looping one, and the clip plays IN PLACE -- the movement
    -- below is ours, because none of these assets is a locomotion clipset.
    TaskPlayAnim(ped, c.dict, c.anim, 8.0, -8.0, -1, 1, 0.0, false, false, false)
end

--- Put the player on the floor and start whatever crawl this build supports.
local function enterDowned()
    -- BEING DOWNED MEANS BEING ALIVE, AND THE WORLD DOES NOT KNOW THAT.
    --
    -- THE BUG (owner, 2026-08-16): a player who fell from a height went straight
    -- to OUT. Their screen read 0 health, they could not crawl, their body stayed
    -- in the world and a squadmate standing over them got no revive prompt at
    -- all. The squad panel said "out" the moment they landed.
    --
    -- Every knock the server hands out through a validated GUNSHOT arrives at a
    -- ped that is still alive: BR.Damage.applyHit clamps the damage it instructs
    -- us to apply so the ped survives at the downed floor, on purpose. Nothing
    -- clamps a fall. Falls, fire, drowning and cars are damage paths M6
    -- deliberately left to the engine (server/damage.lua reads them off
    -- weaponDamageEvent as environmental and returns), so the ped is genuinely
    -- DEAD by the time DBNO_SET arrives -- and a dead ped takes no animation,
    -- holds no health, and reads as a corpse to the server's own health sampler,
    -- which then eliminates the player it just knocked down.
    --
    -- The server cannot fix this from its side: NetworkResurrectLocalPlayer runs
    -- on the machine that owns the ped or nowhere (see the REVIVED note in
    -- shared/protocol.lua, which says exactly this about the #144 path). So the
    -- knock and the resurrection are two halves of one event, and this is the
    -- half that lives here.
    --
    -- IN PLACE, AND WITHOUT BR.Spawn.respawn. This body is already lying on the
    -- ground it fell to; respawn() is the verb for arriving somewhere NEW and
    -- carries luggage that is wrong here (it strips the inventory's weapons and
    -- ground-probes from fifty metres up, which indoors finds the roof). Same
    -- reasoning, and the same three calls, as spawn.lua's REVIVED handler.
    --
    -- The health that follows is the SERVER's: knock() sends HEALTH_SYNC with
    -- the downed floor immediately after DBNO_SET, because a resurrection
    -- restores GTA's defaults rather than ours.
    if IsEntityDead(PlayerPedId()) then
        local ped = PlayerPedId()
        local p = GetEntityCoords(ped)
        NetworkResurrectLocalPlayer(p.x, p.y, p.z, GetEntityHeading(ped),
                                    true, false)
        -- The dying animation outlives the resurrection otherwise: the ped
        -- stands up and then finishes collapsing over the top of the crawl.
        ClearPedTasksImmediately(PlayerPedId())
        print('[br_core] dbno: the world had already killed this ped -- resurrected onto the downed floor')
    end

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

        if not mine.downed then return end
        playCrawl(true)

        -- AND NOTHING KNOCKS THEM OUT OF IT AGAIN. The knockdown above is the
        -- only ragdoll a downed player gets; leaving it enabled meant a passing
        -- car stood them back up mid-bleed, because the collision ragdolls them
        -- and the getup task that follows outranks a looping animation (owner,
        -- in game). The watchdog below covers everything else that can cancel a
        -- clip -- but not being ragdolled in the first place is the cheaper
        -- half, and it is the half that stops them standing.
        SetPedCanRagdoll(PlayerPedId(), false)
    end)
end

--- Stand back up: undo everything enterDowned did.
local function leaveDowned()
    local ped = PlayerPedId()
    -- Reset the movement clipset even though nothing sets one any more. It is
    -- two native calls, and the alternative -- a player who was downed by an
    -- OLDER client build walking into the lobby at crawling pace -- is the
    -- undeleted-object bug in a different costume.
    ResetPedMovementClipset(ped, 0.0)
    SetPedMoveRateOverride(ped, 1.0)
    ClearPedTasks(ped)
    -- Handed back, or a revived player is permanently immune to being knocked
    -- over by anything for the rest of the match.
    SetPedCanRagdoll(ped, true)
    -- The inventory re-arms itself on the next pass, now that canArm() is true
    -- again; asking it here would race the state delta that made it true.
end

--- The server says the bleed ran out. Our ped has not noticed.
---
--- A downed ped is alive and invincible, so nothing about being eliminated
--- reaches it on its own -- the server sends HEALTH_SYNC 0 alongside this and
--- that is what should land the kill. This is the belt to that pair of braces:
--- invincibility is re-decided every frame from the mirror's state, so there is
--- a window of a frame or two where a health write can be ignored, and a player
--- left alive after the match has finished with them is the worst possible
--- outcome to leave to a race.
local function dieNow()
    Citizen.CreateThread(function()
        for _ = 1, 12 do
            local ped = PlayerPedId()
            if IsEntityDead(ped) or IsPedFatallyInjured(ped) then return end
            SetEntityHealth(ped, 0)
            Citizen.Wait(100)
        end
        print('[br_core] dbno: the ped would not die after a bleed-out -- tell somebody')
    end)
end

-- A DOWNED PLAYER STEERS AND NOTHING ELSE (owner, 2026-08-09).
--
-- They keep control of whether they are moving and in which direction; they
-- lose the weapon, the inventory, the vehicle and every other verb. Crawling
-- away from a firefight is the one decision the state is supposed to leave you,
-- and taking it away as well would make being downed a loading screen.
--
-- THE MOVEMENT IS OURS. None of the assets that survived the probe is a
-- locomotion clipset -- they are animation dictionaries that play in place --
-- so the engine's own walk is disabled and the ped is driven by hand at
-- dbnoCrawlSpeed. Disabled-then-read is the standard shape for that: the
-- control still reports its value through GetDisabledControlNormal, so the
-- input is ours without the ped also trying to walk on it.
local DOWNED_BLOCKED = {
    21, 22, 23, 24, 25,          -- sprint, jump, enter vehicle, attack, aim
    30, 31, 32, 33, 34, 35,      -- movement axes and WASD (read back below)
    44, 75,                      -- cover, exit vehicle
    140, 141, 142, 143,          -- melee attacks and block
}

BR.Loop.register(BR.Loop.FRAME, 'dbno.controls', function()
    if not mine.downed then return end

    for i = 1, #DOWNED_BLOCKED do
        DisableControlAction(0, DOWNED_BLOCKED[i], true)
    end

    -- The loop is the pose; if anything cancelled it -- a car, a blast, a
    -- scripted task -- put it straight back. Cheap: one IsEntityPlayingAnim
    -- when nothing is wrong.
    playCrawl(false)

    local ped = PlayerPedId()
    if IsPedRagdoll(ped) or IsEntityInAir(ped) then return end

    -- Turn on the horizontal axis, inch forward on the vertical one. Both are
    -- read from the DISABLED control, which is the whole point of disabling it.
    local lr = GetDisabledControlNormal(0, 30)
    local ud = GetDisabledControlNormal(0, 31)

    if math.abs(lr) > 0.1 then
        SetEntityHeading(ped,
            (GetEntityHeading(ped) - lr * (M.dbnoTurnRate or 90.0)
             * GetFrameTime()) % 360.0)
    end

    -- Forward only. A crawl has no reverse gear, and -ud would let a downed
    -- player back out of a doorway faster than they went in.
    if ud >= -0.1 then return end

    local step = (M.dbnoCrawlSpeed or 0.55) * GetFrameTime()
    local h    = math.rad(GetEntityHeading(ped))
    local dx, dy = -math.sin(h) * step, math.cos(h) * step
    local c = GetEntityCoords(ped)

    -- A RAY BEFORE EVERY STEP, because moving a ped by hand does not resolve
    -- collision -- SetEntityCoords would happily post them through a wall, and
    -- "crawl into the geometry" is a better exploit than most. Cast from chest
    -- height a little further than the step is long; anything solid means stay
    -- put. One ray per frame, and only while actually crawling.
    local reach = step + 0.45
    local ray = StartShapeTestRay(c.x, c.y, c.z + 0.25,
                                  c.x + dx * (reach / step),
                                  c.y + dy * (reach / step),
                                  c.z + 0.25, 1 | 16, ped, 4)
    local _, hit = GetShapeTestResult(ray)
    if hit == 1 then return end

    SetEntityCoordsNoOffset(ped, c.x + dx, c.y + dy, c.z, false, false, false)
end)

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
        -- Picked up, or finished. The two look identical from here except for
        -- this flag, and only one of them ends with a body.
        if d.died then dieNow() end
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

            -- THE HOLD IS RE-ASSERTED, NOT ANNOUNCED ONCE.
            --
            -- A brief tap completed a whole revive in playtest (owner,
            -- 2026-08-09). The key layer is not the problem -- it derives both
            -- edges correctly -- so the STOP was raised and did not land, and
            -- the design was one message away from an eight-second hold
            -- happening for free. Progress now requires CONTINUOUS evidence:
            -- the server expires a revive it has not heard about recently, so
            -- silence stops it and a lost STOP costs a fraction of a second
            -- instead of the whole interaction. Same reasoning as the bus's
            -- landing notices being polled rather than hooked.
            local now = GetGameTimer()
            if now - (holding.beat or 0) >= 250 then
                holding.beat = now
                TriggerServerEvent(BR.Net.REVIVE_START, { target = holding.target })
            end
        end
    else
        setPrompt(target, nil)
    end

    if not target then return end

    -- Drawn natively at the mate's own position, every frame, so the label is
    -- welded to the body however fast the camera moves.
    local ped = BR.Squadmates.pedOf(holding and holding.target or target)
    if ped ~= 0 then
        -- Low over the body. The loot prompt's lift is written for something
        -- standing on the ground; this one is written for something lying on
        -- it, and at the standing height it floated clear of the player it was
        -- pointing at (owner, in game).
        local c = GetEntityCoords(ped)
        BR.Dui.drawWorld(promptPage(), c.x, c.y,
                         c.z + (M.dbnoPromptLift or 0.35),
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

--- WHICH DOWNED POSE THIS BUILD ACTUALLY HAS.
---
---   brcrawl        what exists, and what loads
---   brcrawl <n>    play candidate n on your own ped for six seconds
---
--- This command exists because the first version of the downed state guessed
--- an asset name, guessed the wrong KIND of asset, and put every downed player
--- in a T-pose. `move_crawl` is an animation dictionary; it was handed to
--- SetPedMovementClipset, which does not fail on a bad clipset -- it renders
--- bind pose. Read the `clipset?` column with that in mind: it reported TRUE
--- for the asset that caused the bug, so it is a hint and not an answer.
--- Watching `brcrawl <n>` is the answer.
RegisterCommand('brcrawl', function(_, args)
    local n = tonumber(args[1])

    if n and CRAWL_CANDIDATES[n] then
        local c = CRAWL_CANDIDATES[n]
        if not loadDict(c.dict) then
            print(('  %s did not load -- nothing to show'):format(c.dict))
            return
        end
        print(('[br_core] playing %s / %s for 6s'):format(c.dict, c.anim))
        Citizen.CreateThread(function()
            local ped = PlayerPedId()
            TaskPlayAnim(ped, c.dict, c.anim, 8.0, -8.0, -1, 1, 0.0,
                         false, false, false)
            Citizen.Wait(6000)
            ClearPedTasks(PlayerPedId())
            print('[br_core] done')
        end)
        return
    end

    print('=== downed pose candidates ===')
    print('  #  dict / anim                              exists  loads  clipset?')
    for i, c in ipairs(CRAWL_CANDIDATES) do
        local exists = (not DoesAnimDictExist) or DoesAnimDictExist(c.dict)
        local loads  = exists and loadDict(c.dict) or false
        -- REPORTED, NEVER APPLIED. Applying an unverified movement clipset is
        -- precisely what T-posed a downed player, and a probe that reproduces
        -- the bug it is investigating is not a probe.
        RequestClipSet(c.dict)
        local asClip = HasClipSetLoaded(c.dict)
        print(('  %d  %-40s %-7s %-6s %s'):format(
            i, c.dict .. ' / ' .. c.anim,
            tostring(exists), tostring(loads), tostring(asClip)))
    end
    print(('  in use: %s'):format(
        crawl and (crawl.dict .. ' / ' .. crawl.anim)
              or (crawl == false and 'none -- lying still' or 'not resolved yet')))
    print('  "brcrawl <n>" plays one on your own ped for six seconds.')
    print('  clipset? TRUE is NOT proof -- it read true for the asset that')
    print('  T-posed everybody. Watch it before believing it.')
end, false)

RegisterCommand('brdbno', function()
    print('=== dbno (client) ===')
    print(('  me         : %s'):format(tostring(BR.State.me.state)))
    print(('  downed     : %s  bleedEndsAt %s  (%.1fs left)')
        :format(tostring(mine.downed), tostring(mine.bleedEndsAt),
                (mine.bleedEndsAt - BR.Clock.now()) / 1000.0))
    print(('  reviver    : %s  %.0f%%')
        :format(tostring(mine.reviverName), mine.revivePct or 0.0))
    print(('  pose       : %s   (brcrawl for the candidate list)'):format(
        crawl and (crawl.dict .. ' / ' .. crawl.anim)
              or (crawl == false and 'none -- lying still' or 'not resolved yet')))
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
