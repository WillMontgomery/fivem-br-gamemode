-- The inventory mirror, and the only place a weapon is ever put in a hand.
--
-- READ-ONLY, LIKE THE ROSTER. What the server sends in INV_SET is the truth;
-- this file renders it onto the ped and into the UI, and sends REQUESTS back.
-- Nothing here decides that a pickup succeeded.
--
-- ACTIVE SLOT ONLY. The ped carries exactly what is in the selected slot and
-- nothing else -- every switch is RemoveAllPedWeapons + GiveWeaponToPed. That
-- is heavier than swapping the equipped weapon, and it is the point: the ped's
-- weapon wheel is not a second inventory that can drift out of agreement with
-- the real one.
--
-- AND IT IS SUSPENDED IN THE AIR. RemoveAllPedWeapons takes the PARACHUTE with
-- it. A weapon applied mid-drop would delete the chute of a player at 400
-- metres, which is not a HUD bug, it is a death. Nothing in here touches the
-- ped until the server says ALIVE.

BR = BR or {}
BR.Inv = BR.Inv or {}

local L        = BR.Config.Loot
local SLOTS    = L.slots or 5
local UNARMED  = BR.Config.Gadgets.UNARMED

-- SLOT ZERO IS FISTS, and nothing can ever be put in it (user call,
-- 2026-08-05). It sits left of slot 1 on the bar and cycles with the rest.
-- Having a deliberate empty hand matters: you cannot open a crate or vault
-- convincingly with a rifle up, and "put the gun away" should not mean
-- dropping it.
local MELEE_SLOT = BR.Config.Loot.meleeSlot or 0

-- The mirror. Empty slots are `false`, exactly as they are on the wire and on
-- the server -- one representation, no boundary conversion to get wrong.
local inv = { slots = {}, ammo = {}, active = 1, using = nil }
for i = 1, SLOTS do inv.slots[i] = false end

-- What is actually in the ped's hands right now, and whose hands they were.
-- The ped handle matters: a respawn hands out a new one with no weapons on it.
local applied, appliedPed = nil, 0

--- When this player last gained anything. Zero means "has found nothing all
--- match", which is what the mercy blips in client/loot.lua key on.
BR.Inv.lastGainAt = 0

--- Set by /brprobe raw. While true, this file writes NOTHING to the ped's
--- ammo and reports nothing to the server.
---
--- It exists because the first ammo measurement was contaminated by our own
--- writes: the numbers being watched were partly ones we had just set, which
--- makes "what does this native do" unanswerable. A probe has to be able to
--- take our hands off the wheel.
BR.Inv.suspendAmmo = false

-- Last magazine count we reported. The reserve is NOT tracked here any more:
-- the server derives it from how this number moves (see server/inventory.lua).
local lastReport = { clip = -1, at = 0 }

-- GTA'S OWN WEAPON UI HAS TO GO. The inventory replaces it wholesale, and
-- leaving the engine's version bound to the same keys means every one of our
-- inputs fires two things at once: TAB opened our panel AND the weapon wheel,
-- and 1-5 selected our slots AND the wheel's weapon groups (user, 2026-08-05).
--
-- These are DISABLED, not rebound. The player's own GTA control settings still
-- decide which physical key each of these is -- we are suppressing the
-- engine's reaction to them, not claiming a key.
local SUPPRESS = {
    37,   -- INPUT_SELECT_WEAPON        (the weapon wheel; TAB by default)
    157, 158, 159, 160, 161,  -- INPUT_SELECT_WEAPON_UNARMED..SHOTGUN (1-5)
    162, 163, 164,            -- ..and the rest of the group row
    99, 100,                  -- INPUT_SELECT_NEXT/PREV_WEAPON
    14, 15,                   -- INPUT_WEAPON_WHEEL_NEXT/PREV (mouse wheel)
}

-- SCROLL UP CYCLES BACKWARDS, SCROLL DOWN DOES NOTHING (user call,
-- 2026-08-05: "if 1 is selected, 5 is next"). One direction through a wrapping
-- ring reaches every slot and needs no thought about which way you are going;
-- two directions on a six-item ring is a decision nobody wants mid-fight.
-- Control 15 is the wheel's "previous", which is what a scroll UP reports --
-- 14 (down) stays disabled and inert.
local WHEEL_UP = 15

--- Can this player's ped be given anything at all?
---
--- WARMUP counts. There is loot on the warmup island and the point of it is
--- early PVP, so the bar, the panel and the weapon grants all have to work
--- there -- a bar showing five slots you cannot open was the worst of both
--- (user, 2026-08-05).
--- @return boolean
local function canArm()
    local st = BR.State.me.state
    return st == BR.PlayerState.ALIVE
        or st == BR.PlayerState.DBNO
        or st == BR.PlayerState.WARMUP
end

--- The weapon hash a slot represents, or nil for anything not held.
--- @param slot table|false
--- @return integer|nil
local function hashOf(slot)
    if not slot then return nil end
    if slot.kind ~= BR.ItemKind.WEAPON and slot.kind ~= BR.ItemKind.THROWABLE then
        return nil
    end
    local w = BR.Config.WeaponById[slot.id]
    return w and w.hash or nil
end

--- Reserve ammo available for a slot.
--- @param slot table
--- @return integer
local function reserveFor(slot)
    if slot.kind == BR.ItemKind.THROWABLE then return slot.count or 1 end
    local w = BR.Config.WeaponById[slot.id]
    if not w or not w.ammo then return 0 end
    return math.floor(inv.ammo[w.ammo] or 0)
end

-- --------------------------------------------------------------------------
-- Putting it in the hand
-- --------------------------------------------------------------------------

--- Make the ped hold whatever the active slot says, and nothing else.
--- @param force boolean|nil  re-apply even if the mirror thinks it is current
local function applyActive(force)
    if not canArm() or BR.Inv.suspendAmmo then return end

    local ped = PlayerPedId()
    local slot = inv.slots[inv.active]
    local want = hashOf(slot)

    -- A new ped handle is a new, empty ped: re-apply whatever we thought was
    -- already there.
    if ped ~= appliedPed then
        applied, appliedPed = nil, ped
        force = true
    end
    -- SAME WEAPON: DO NOTHING.
    --
    -- This used to re-assert the ammo here on the grounds that SetPedAmmo is
    -- idempotent. It is not idempotent against the ENGINE: the player fires,
    -- the engine decrements, and 100ms later this wrote the mirror's number
    -- straight back over it. The gun never emptied and the counter never
    -- moved -- which is exactly the "bullet counts do not update" report, and
    -- it survived two rounds of looking at the display code because the
    -- display was right and the ammo genuinely was not going down.
    --
    -- Ammo is now written to the ped in exactly one place: a fresh grant
    -- below, or reapplyAmmo() when the SERVER's number goes UP (a pickup).
    if not force and want == applied then return end

    RemoveAllPedWeapons(ped, true)

    if want and slot then
        local clip    = math.floor(slot.clip or 0)
        local reserve = reserveFor(slot)
        -- The engine's ammo number is TOTAL, clip included; giving the reserve
        -- alone leaves a gun that is one magazine short of what the HUD says.
        GiveWeaponToPed(ped, want, clip + reserve, false, true)
        SetPedAmmo(ped, want, clip + reserve)
        SetAmmoInClip(ped, want, clip)
        SetCurrentPedWeapon(ped, want, true)
    else
        SetCurrentPedWeapon(ped, UNARMED, true)
    end

    applied = want
end

--- Push the server's ammo numbers onto the ped, when they went UP.
---
--- The only legitimate reason for the server to know about more ammo than the
--- engine has is a PICKUP. Pushing on any other change would fight the engine
--- as the player fires -- see the note in applyActive.
local function reapplyAmmo(serverClip)
    if not canArm() or BR.Inv.suspendAmmo then return end
    local slot = inv.slots[inv.active]
    local hash = hashOf(slot)
    if not hash or applied ~= hash then return end

    -- ONLY WHEN THE SERVER'S NUMBERS WENT UP, and never by comparing against
    -- the engine. Comparing against GetAmmoInPedWeapon is what produced
    -- unlimited ammo: that native does not move when firing on this build, so
    -- a mirror that had drifted upward looked like a gun that needed topping
    -- up, forever (user, 2026-08-06).
    local ped  = PlayerPedId()
    local clip = math.floor(slot.clip or 0)

    SetPedAmmo(ped, hash, reserveFor(slot) + clip)
    SetAmmoInClip(ped, hash, clip)
    lastReport.clip = serverClip or clip
end

--- Forget everything. Called at match teardown and on death.
local function clearLocal()
    for i = 1, SLOTS do inv.slots[i] = false end
    inv.ammo, inv.active, inv.using = {}, 1, nil
    applied, appliedPed = nil, 0
    lastReport.clip = -1
    BR.Inv.lastGainAt = 0
end

-- --------------------------------------------------------------------------
-- The UI channel
-- --------------------------------------------------------------------------

local function pushUi()
    -- Sent whole rather than as deltas: five slots is a tiny payload, and the
    -- storm's "never send a nil clear" rule means a partial update would need
    -- a vocabulary for "this slot is now empty" that `false` already is.
    TriggerEvent('br:ui:sendLocal', BR.Nui.INV, {
        slots  = inv.slots,
        ammo   = inv.ammo,
        active = inv.active,
        using  = inv.using,
    })
end

--- Adopt a server payload.
--- @param d table
local function adopt(d)
    if type(d) ~= 'table' or type(d.slots) ~= 'table' then return end

    -- Did anything actually ARRIVE? A pickup that was refused (too far, gone,
    -- rate-limited) still produces an INV_SET, so "the server sent an
    -- inventory" is not the same as "you picked something up" -- and the
    -- sound is the feedback that tells those apart.
    local gained = false
    for i = 1, SLOTS do
        local was, now = inv.slots[i], d.slots[i]
        if type(now) == 'table' then
            if not was or was.id ~= now.id or (now.count or 1) > (was.count or 1) then
                gained = true
            end
        end
    end

    -- Did the SERVER's ammo for the weapon in hand go up? A pickup, or a
    -- reload it just paid for -- either way the ped needs the rounds putting
    -- into it. Measured against the last thing the server said, never against
    -- the engine.
    local gainedAmmo = false
    do
        local nowSlot = d.slots[d.active or 0]
        local wasSlot = inv.slots[inv.active]
        if type(nowSlot) == 'table' then
            local w = BR.Config.WeaponById[nowSlot.id]
            if w and w.ammo then
                local nowPool = (d.ammo and d.ammo[w.ammo]) or 0
                local wasPool = inv.ammo[w.ammo] or 0
                local nowClip = nowSlot.clip or 0
                local wasClip = (wasSlot and wasSlot.id == nowSlot.id)
                    and (wasSlot.clip or 0) or -1
                if nowPool > wasPool or nowClip > wasClip then
                    gainedAmmo = true
                end
            end
        end
    end

    for i = 1, SLOTS do
        local s = d.slots[i]
        inv.slots[i] = (type(s) == 'table') and s or false
    end
    local wasActive = inv.active
    inv.ammo   = d.ammo or {}
    inv.active = d.active or MELEE_SLOT
    inv.using  = d.using

    -- The switch click. Only on an actual change, and only on OUR screen --
    -- PlaySoundFrontend is local by definition.
    if inv.active ~= wasActive and L.switchSound then
        PlaySoundFrontend(-1, L.switchSound.name, L.switchSound.set, true)
    end

    applyActive(false)

    -- Push the server's ammo onto the ped when it went UP -- a pickup, or a
    -- reload the server just paid for. `gainedAmmo` is measured against what
    -- we last saw the server say, never against the engine.
    if gainedAmmo then
        local s = inv.slots[inv.active]
        reapplyAmmo(s and s.clip)
    end
    pushUi()

    if gained then
        -- Read by loot.lua's mercy blips: "has this player ever found
        -- anything" is the difference between helping and nagging.
        BR.Inv.lastGainAt = GetGameTimer()
        if L.pickupSound then
            PlaySoundFrontend(-1, L.pickupSound.name, L.pickupSound.set, true)
        end
    end
end

RegisterNetEvent(BR.Net.INV_SET)
AddEventHandler(BR.Net.INV_SET, adopt)

-- The snapshot carries the same payload, which is what makes a mid-match
-- br_ui restart (or a reconnect) come back holding the right rifle.
RegisterNetEvent(BR.Net.SNAPSHOT)
AddEventHandler(BR.Net.SNAPSHOT, function(payload)
    if payload and payload.inv then adopt(payload.inv) end
end)

-- --------------------------------------------------------------------------
-- Effects
-- --------------------------------------------------------------------------

-- The server decided a consumable landed; this applies it to our own ped. The
-- amounts are TARGETS in display units, already capped by the item -- and they
-- are only ever applied UPWARD. A player who took a hit in the last 500ms
-- (between the server's sample and this event) must not be healed DOWN to a
-- stale number.
RegisterNetEvent(BR.Net.INV_EFFECT)
AddEventHandler(BR.Net.INV_EFFECT, function(d)
    if type(d) ~= 'table' then return end
    local ped = PlayerPedId()

    if d.armour then
        -- RE-ASSERT THE CEILING FIRST. GTA's default max armour is 50, and
        -- SetPlayerMaxArmour is a PLAYER setting that goes back to the default
        -- with a new ped -- which every respawn hands out. initHealthModel set
        -- it once at match start, so by the time anyone drank a shield potion
        -- the cap was 50 again and SetPedArmour silently clamped: "shield
        -- cannot get above 50" (user, 2026-08-06). Cheap, and exactly where it
        -- matters.
        SetPlayerMaxArmour(PlayerId(), BR.Config.Match.maxArmour)
        local target = math.min(d.armour, d.armourCap or BR.Config.Match.maxArmour)
        if target > GetPedArmour(ped) then
            SetPedArmour(ped, math.floor(target))
        end
    end

    if d.health then
        local target = math.min(d.health, d.healthCap or 100.0)
        if target > BR.Native.displayHealth() then
            BR.Native.setDisplayHealth(target)
        end
    end
end)

-- --------------------------------------------------------------------------
-- Input
-- --------------------------------------------------------------------------

-- Every one of these is a REQUEST. The bar does not move until INV_SET comes
-- back, which is why a refused switch looks like nothing happening rather than
-- like a switch that undid itself.
for i = 1, SLOTS do
    BR.Keys.on('slot' .. i, function(pressed)
        if not pressed or not canArm() then return end
        TriggerServerEvent(BR.Net.INV_SELECT, { slot = i })
    end)
end

BR.Keys.on('drop', function(pressed)
    if not pressed or not canArm() then return end
    if not inv.slots[inv.active] then return end
    TriggerServerEvent(BR.Net.INV_DROP, { slot = inv.active })
end)

-- THE USE KEY ALWAYS DOES SOMETHING IF THERE IS ANYTHING TO DO.
--
-- Strictly, you use what is in your hand. But a player who has just picked up
-- their first shield potion into slot 2 while a rifle sits in slot 1 presses
-- the key, nothing happens, and the reasonable conclusion is that the item is
-- broken (user, 2026-08-05: "there's no way to use it"). So: the active slot
-- if it is consumable, otherwise the lowest slot that is.
BR.Keys.on('use', function(pressed)
    if not pressed or not canArm() then return end

    local slot = nil
    local s = inv.slots[inv.active]
    if s and s.kind == BR.ItemKind.CONSUMABLE then
        slot = inv.active
    else
        for i = 1, SLOTS do
            local c = inv.slots[i]
            if c and c.kind == BR.ItemKind.CONSUMABLE then slot = i break end
        end
    end

    if not slot then return end
    -- Bring it up first, so the thing being drunk is the thing in hand.
    if slot ~= inv.active then
        TriggerServerEvent(BR.Net.INV_SELECT, { slot = slot })
    end
    TriggerServerEvent(BR.Net.INV_USE, { slot = slot })
end)

-- The TAB panel. LUA OWNS WHETHER IT IS OPEN, because Lua owns the cursor:
-- br_ui grants keep-input focus to any screen that is not the lobby or chat,
-- so the match keeps running underneath and the page decides nothing.
local panelOpen = false

local function closePanel()
    if not panelOpen then return end
    panelOpen = false
    TriggerEvent('br:ui:popFocus', 'inventory')
end

BR.Keys.on('inventory', function(pressed)
    if not pressed then return end
    if panelOpen then
        closePanel()
        return
    end
    -- Never over the lobby or a corpse: there is nothing to manage and the
    -- cursor would land on top of a menu that already owns focus.
    if not canArm() then return end
    panelOpen = true
    TriggerEvent('br:ui:pushFocus', 'inventory')
end)

-- UI actions. br_ui forwards the callbacks; br_core decides what they mean.
AddEventHandler('br:ui:action', function(name, data)
    if name == BR.NuiCb.CLOSE then closePanel() return end
    if name == BR.NuiCb.INV_SELECT then
        TriggerServerEvent(BR.Net.INV_SELECT, data)
    elseif name == BR.NuiCb.INV_SWAP then
        TriggerServerEvent(BR.Net.INV_SWAP, data)
    elseif name == BR.NuiCb.INV_DROP then
        TriggerServerEvent(BR.Net.INV_DROP, data)
    elseif name == BR.NuiCb.INV_USE then
        TriggerServerEvent(BR.Net.INV_USE, data)
    end
end)

-- --------------------------------------------------------------------------
-- Loops
-- --------------------------------------------------------------------------

BR.Loop.register(BR.Loop.TICK, 'inv.apply', function()
    if not canArm() then
        -- Airborne, in the lobby, or dead: the hand is not ours to fill. The
        -- mirror is left alone so landing re-applies whatever was picked up
        -- on the way down (nothing, today -- but the bus ride is where a
        -- future starting kit would arrive).
        applied = nil
        -- A panel left open over a death or a teardown would keep the cursor
        -- on screen with nothing under it.
        closePanel()
        return
    end

    -- The pause menu is a full-screen map with its own cursor; ours sitting on
    -- top of it is two interfaces fighting for the same mouse (user,
    -- 2026-08-05).
    if panelOpen and IsPauseMenuActive() then closePanel() end

    applyActive(false)
end)

-- Control suppression and slot cycling, per frame.
--
-- FRAME rather than TICK because DisableControlAction only lasts one frame,
-- and a wheel that flickers into existence every other frame is worse than one
-- that never goes away.
BR.Loop.register(BR.Loop.FRAME, 'inv.controls', function()
    if not canArm() then return end

    for i = 1, #SUPPRESS do
        DisableControlAction(0, SUPPRESS[i], true)
    end

    -- MOUSE WHEEL UP CYCLES DOWNWARD THROUGH THE RING, wrapping past the fist
    -- slot at the bottom to slot 5 at the top.
    if IsDisabledControlJustPressed(0, WHEEL_UP) then
        local want = inv.active - 1
        if want < MELEE_SLOT then want = SLOTS end
        TriggerServerEvent(BR.Net.INV_SELECT, { slot = want })
    end

    -- SHOOTING A CONSUMABLE USES IT (user call, 2026-08-05). With a med kit
    -- selected the attack button has nothing else to do, and reaching for the
    -- trigger is what a player does with whatever is in their hands. The
    -- control is the player's own ATTACK binding, whatever they set it to.
    -- NOT WHILE THE PANEL IS OPEN. Disabling a control does not stop
    -- IsDisabledControlJustPressed from seeing it -- that is the entire point
    -- of the disabled variants -- so clicking a slot card in the panel was
    -- also firing this, using a consumable the player was only trying to drag
    -- (user, 2026-08-05).
    local held = inv.slots[inv.active]
    if not panelOpen and held and held.kind == BR.ItemKind.CONSUMABLE
       and not inv.using then
        DisableControlAction(0, 24, true)   -- ATTACK: no punching a potion
        DisableControlAction(0, 25, true)   -- AIM
        if IsDisabledControlJustPressed(0, 24) then
            TriggerServerEvent(BR.Net.INV_USE, { slot = inv.active })
        end
    end

    -- While the panel is up the cursor belongs to the panel. Keep-input focus
    -- means the game still reads the mouse, so without this the camera spins
    -- as you reach for a slot (user, 2026-08-05). Movement is deliberately
    -- left alone: this is a screen you use DURING a fight.
    if panelOpen then
        DisableControlAction(0, 1, true)    -- LOOK_LR
        DisableControlAction(0, 2, true)    -- LOOK_UD
        DisableControlAction(0, 24, true)   -- ATTACK
        DisableControlAction(0, 25, true)   -- AIM
        DisableControlAction(0, 68, true)   -- VEH_ATTACK
        DisableControlAction(0, 69, true)   -- VEH_PASSENGER_ATTACK
        DisableControlAction(0, 70, true)   -- VEH_ATTACK2
        DisableControlAction(0, 106, true)  -- VEH_MOUSE_CONTROL_OVERRIDE
        DisableControlAction(0, 140, true)  -- MELEE_ATTACK_LIGHT
        DisableControlAction(0, 141, true)  -- MELEE_ATTACK_HEAVY
        DisableControlAction(0, 142, true)  -- MELEE_ATTACK_ALTERNATE
        DisableControlAction(0, 257, true)  -- ATTACK2
        DisableControlAction(0, 263, true)  -- MELEE_ATTACK1
        DisableControlAction(0, 264, true)  -- MELEE_ATTACK2

        -- THE PAUSE KEY CLOSES THE PANEL INSTEAD OF PAUSING (user call,
        -- 2026-08-05). Reaching for escape with a menu open means "close the
        -- menu" everywhere else in games, and stacking GTA's pause screen on
        -- top of ours is two interfaces fighting for the same input.
        DisableControlAction(0, 199, true)  -- FRONTEND_PAUSE
        DisableControlAction(0, 200, true)  -- FRONTEND_PAUSE_ALTERNATE
        if IsDisabledControlJustPressed(0, 199)
           or IsDisabledControlJustPressed(0, 200)
           -- Right mouse: the universal "back out of this".
           or IsDisabledControlJustPressed(0, 25) then
            closePanel()
        end
    end
end)

-- The ammo report: 2Hz, decrease-only at the far end, and silent when nothing
-- moved. This is the ONE number the client is the only observer of until M6
-- validates shots server-side; see server/inventory.lua for why that is safe.
BR.Loop.register(BR.Loop.TICK, 'inv.ammo', function()
    if not canArm() or BR.Inv.suspendAmmo then return end

    local now = GetGameTimer()
    if now - lastReport.at < 500 then return end
    lastReport.at = now

    local slot = inv.slots[inv.active]
    local hash = hashOf(slot)
    if not hash then return end
    -- Only report the weapon the ped is CONFIRMED to be holding. In the frames
    -- between an INV_SET and the grant landing, the engine has the old weapon
    -- (or none) -- and since the server accepts any decrease, reporting there
    -- would empty the new magazine before it was ever fired.
    if applied ~= hash then return end

    -- NOT FROM A VEHICLE. In a car the engine stows most weapons, and
    -- GetAmmoInClip for one the ped cannot currently hold reads ZERO -- which
    -- this loop then reported as "the magazine emptied", so the counter fell
    -- to 0/6 the moment the player got in and stayed there (user, 2026-08-06:
    -- "nothing else changed"). A vehicle seat is not evidence about ammo.
    if IsPedInAnyVehicle(PlayerPedId(), false) then return end

    -- Nor while a reload is playing: the magazine is mid-swap and reads as
    -- whatever the animation has reached, which is not a number to build a
    -- reserve calculation on.
    if IsPedReloading(PlayerPedId()) then return end

    -- THE CLIP IS THE ONLY NUMBER READ OFF THE ENGINE, and the reserve is
    -- derived from it SERVER-SIDE.
    --
    -- The previous version computed reserve as `GetAmmoInPedWeapon - clip`,
    -- on the documented assumption that the first is a TOTAL including the
    -- magazine. On this build it does not behave that way: firing does not
    -- move it, so subtracting a shrinking clip made the reserve GROW -- which
    -- is the "12 is increasing per shot" report exactly. Worse, that inflated
    -- number then fed reapplyAmmo, which topped the gun back up: the unlimited
    -- ammo (user, 2026-08-06).
    --
    -- A magazine count is something the engine reports honestly, so that is
    -- all we send. The server watches it: DOWN is firing (the reserve is
    -- untouched), UP is a reload (the reserve pays for it). No assumption
    -- about any other native's semantics survives in this path.
    local ped = PlayerPedId()
    -- GET_AMMO_IN_CLIP is a BOOL with an out-param, so Lua gets two returns.
    local _, clip = GetAmmoInClip(ped, hash)
    clip = math.max(0, clip or 0)

    if clip == lastReport.clip then return end
    lastReport.clip = clip

    TriggerServerEvent(BR.Net.INV_AMMO, { slot = inv.active, clip = clip })

    -- The display follows immediately rather than waiting for the round trip.
    -- The clip is read straight off the gun, so showing it is the HUD agreeing
    -- with what is in the player's hands; the RESERVE stays the server's and
    -- arrives with the next INV_SET.
    slot.clip = clip
    pushUi()
end)

-- --------------------------------------------------------------------------
-- Teardown
-- --------------------------------------------------------------------------

RegisterNetEvent(BR.Net.STATE)
AddEventHandler(BR.Net.STATE, function(d)
    if not d then return end
    if d.state == BR.MatchState.WAITING
       or d.state == BR.MatchState.ENDED
       or d.state == BR.MatchState.CLEANUP then
        closePanel()
        clearLocal()
        pushUi()
    end
end)

--- What the local mirror thinks it is holding. Read by client/loot.lua for
--- the pickup prompt ("swap") and by /brinv.
--- @return table
function BR.Inv.local_()
    return inv
end

--- Force the active slot back onto the ped.
---
--- Called by skydive.lua after its hard disarm (RemoveAllPedWeapons, which
--- takes the real weapon with the parachute). Without this, landing with a gun
--- would leave the mirror thinking it was applied and the ped empty-handed.
function BR.Inv.reapply()
    applied = nil
    applyActive(true)
end
