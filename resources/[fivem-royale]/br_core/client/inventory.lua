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

-- What we last told the server, and when.
--
-- `total` is the number that matters: GetAmmoInPedWeapon, the ped's WHOLE
-- holding for this weapon, magazine included. `clip` rides along so the server
-- can keep the split for the HUD, but it is never the thing decisions are made
-- on. A total of -1 means "no baseline yet" -- the next read establishes one
-- without reporting, so a weapon switch never looks like a burst of fire.
local lastReport = { total = -1, clip = -1, at = 0 }

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

        -- GIVE THE WEAPON WITH ZERO AMMO, THEN SET THE AMMO. This is
        -- ox_inventory's order, and the reason for it is that
        -- GIVE_WEAPON_TO_PED *ADDS* rounds to a weapon the ped already holds
        -- rather than setting them. Passing `clip + reserve` here, as this
        -- used to, means every re-grant of the same weapon topped the player
        -- up by a full holding -- invisible while switching between two guns,
        -- and compounding whenever anything re-applied the same one.
        GiveWeaponToPed(ped, want, 0, false, true)
        SetPedAmmo(ped, want, clip + reserve)
        SetAmmoInClip(ped, want, clip)
        SetCurrentPedWeapon(ped, want, true)

        -- AND THE ENGINE MAY NOT PICK THE WEAPON. Without this the engine
        -- swaps to "something better" on pickup and on empty, which fights the
        -- active-slot model for control of the hand.
        SetWeaponsNoAutoswap(true)

        -- PASSENGERS SHOOT. GTA gates drive-bys per player, and with it off a
        -- passenger simply cannot fire at all -- which in a battle royale
        -- makes a car a rolling coffin for everyone who is not driving (user,
        -- 2026-08-06: "any seat which is not the driver should be able to do
        -- this"). The engine still applies its own rule about which weapons
        -- are usable from a seat; this only stops us being the reason.
        SetPlayerCanDoDriveBy(PlayerId(), true)
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

--- Re-anchor the report baseline on what the SERVER just said.
---
--- Called after every INV_SET. The alternative -- clearing the baseline and
--- letting the next engine read establish one -- silently throws away every
--- other sample, because our own report is what produced the INV_SET in the
--- first place. Anchoring on the server's numbers instead means the baseline is
--- always the authority's view, which is exactly what the next decrease should
--- be measured against.
local function rebaseline()
    local s = inv.slots[inv.active]
    if s and s.kind == BR.ItemKind.WEAPON then
        lastReport.clip  = math.floor(s.clip or 0)
        lastReport.total = lastReport.clip + reserveFor(s)
    else
        lastReport.clip, lastReport.total = -1, -1
    end
end

--- Forget everything. Called at match teardown and on death.
local function clearLocal()
    for i = 1, SLOTS do inv.slots[i] = false end
    inv.ammo, inv.active, inv.using = {}, 1, nil
    applied, appliedPed = nil, 0
    lastReport.clip, lastReport.total = -1, -1
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

--- How much of each thing an inventory holds, ignoring WHERE it is.
---
--- Keyed by item id for the slots and by '@pool' for the ammo pools, so the
--- two cannot collide. Used to answer "did anything arrive" without a
--- reordering counting as an arrival.
--- @param slots table
--- @param ammo table|nil
--- @return table
local function tally(slots, ammo)
    local t = {}
    for i = 1, SLOTS do
        local s = slots[i]
        if type(s) == 'table' and s.id then
            t[s.id] = (t[s.id] or 0) + (s.count or 1)
        end
    end
    if type(ammo) == 'table' then
        for pool, n in pairs(ammo) do
            if type(n) == 'number' then
                t['@' .. tostring(pool)] = n
            end
        end
    end
    return t
end

--- Adopt a server payload.
--- @param d table
local function adopt(d)
    if type(d) ~= 'table' or type(d.slots) ~= 'table' then return end

    -- Did anything actually ARRIVE? A pickup that was refused (too far, gone,
    -- rate-limited) still produces an INV_SET, so "the server sent an
    -- inventory" is not the same as "you picked something up" -- and the
    -- sound is the feedback that tells those apart.
    --
    -- COMPARED AS TOTALS, NOT SLOT BY SLOT. The per-slot version asked "does
    -- slot i hold something different from before", which is true of BOTH
    -- halves of a swap -- so shuffling items left and right in the panel
    -- played the pickup sound every time (user, 2026-08-06). Nothing was
    -- picked up; the same things were in different places. Counting each item
    -- across the whole inventory makes reordering invisible, which is what it
    -- should be.
    local gained = false
    do
        local before, after = tally(inv.slots, inv.ammo), tally(d.slots, d.ammo)
        for key, n in pairs(after) do
            if n > (before[key] or 0) then gained = true break end
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
    -- The server has just spoken; that is what the next decrease is measured
    -- against, whether or not anything was reapplied to the ped.
    rebaseline()
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

    -- NOT WHILE THE PAUSE MENU IS UP, and not while aiming down a scope.
    --
    -- Disabling a control does not stop IsDisabledControlJustPressed from
    -- seeing it -- that is the entire point of the disabled variants -- so the
    -- wheel kept cycling slots while the player was scrolling the pause map,
    -- and kept stealing the scroll that a sniper scope uses to zoom (user,
    -- 2026-08-07). In both cases the wheel belongs to something else.
    -- ONE NATIVE, AND IT IS A PROBED ONE.
    --
    -- The first version of this line also called GetFollowPedCamViewMode and
    -- IsAimCamThirdPersonViewActive, neither of which this project had ever
    -- probed -- and an unknown binding throws. Five consecutive throws suspend
    -- the callback, and THIS callback is the one that suppresses GTA's weapon
    -- wheel and disables ATTACK while a consumable is in hand. So the whole
    -- file went quiet at once: the wheel came back and using a shield made the
    -- ped throw a punch (user, 2026-08-07, both reported together).
    --
    -- The standing rule exists for exactly this and I broke it: a probe for
    -- every native a subsystem leans on, BEFORE the in-game test. Aiming is
    -- all this actually needs to know.
    local scoped = IsPlayerFreeAiming(PlayerId())

    -- MOUSE WHEEL UP CYCLES DOWNWARD THROUGH THE RING, wrapping past the fist
    -- slot at the bottom to slot 5 at the top.
    if not IsPauseMenuActive() and not scoped
       and IsDisabledControlJustPressed(0, WHEEL_UP) then
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

    local slot = inv.slots[inv.active]
    local hash = hashOf(slot)
    if not hash then return end
    -- Only report the weapon the ped is CONFIRMED to be holding. In the frames
    -- between an INV_SET and the grant landing, the engine has the old weapon
    -- (or none) -- and since the server accepts any decrease, reporting there
    -- would empty the new magazine before it was ever fired.
    if applied ~= hash then return end

    local ped = PlayerPedId()

    -- INFINITE AMMO OFF, EVERY TICK -- NOT ONCE PER WEAPON SWITCH.
    --
    -- Asserting it only at grant time was not enough: /brprobe raw, with every
    -- one of our own writes suspended, still showed the magazine frozen and
    -- the totals climbing by one per shot (user, 2026-08-06). A frozen
    -- magazine is what infinite-ammo-clip does, so something is re-setting the
    -- flag after we clear it. Two natives a tick is cheap enough that we can
    -- simply keep clearing it rather than find out what.
    SetPedInfiniteAmmo(ped, false, hash)
    SetPedInfiniteAmmoClip(ped, false)

    -- ONLY WHEN THE ENGINE AGREES THE PED IS HOLDING IT.
    --
    -- `applied` is our own bookkeeping -- what we last GAVE the ped -- and it
    -- keeps saying "carbine" through every frame in which the engine has
    -- quietly stowed the thing: getting into a car, the get-in animation, a
    -- cutscene, a ragdoll. In all of those GetAmmoInPedWeapon reads 0 for a
    -- weapon the ped is not currently holding, and 0 is a DECREASE, so the
    -- report emptied the player's gun and the reserve with it -- permanently,
    -- because decrease-only never gives it back (user, 2026-08-06: "the HUD is
    -- showing 0 bullets while in a vehicle").
    --
    -- Asking the engine what is in the hand costs one native and closes the
    -- whole class: the vehicle case, the animation window that the old
    -- IsPedInAnyVehicle guard raced against, and any future stow we have not
    -- thought of.
    -- NORMALISED ON BOTH SIDES. The engine returns this hash SIGNED and the
    -- config authors it positive, so twenty of the forty weapons in the game
    -- could never satisfy a raw comparison -- and every one of them therefore
    -- had unlimited ammo, silently, because this guard fired on every tick
    -- (user's /brprobe ammo, 2026-08-06: config hash and "ENGINE holds"
    -- printed identically and still compared unequal).
    -- MELEE HAS NO AMMO TO REPORT. A machete has no magazine and no pool, so
    -- everything below it -- the clamp, the decrease-only total, the report --
    -- is arithmetic about a number that does not exist.
    do
        local w = BR.Config.WeaponById[slot.id]
        if w and w.melee then return end
    end

    -- THROWING THE LAST ONE TAKES THE WEAPON WITH IT.
    --
    -- A throwable is not a gun that runs empty -- the engine REMOVES it from
    -- the ped when the last one leaves the hand. So the guard below, which
    -- exists to stop us reporting for a weapon the ped is not holding, fired
    -- on exactly the moment we most needed to report: the slot never reached
    -- zero, so it kept its grenade, and cycling slots handed out another one
    -- (user, 2026-08-07). Same shape as the ammo bug -- a guard that is right
    -- in general and wrong at the one boundary that matters.
    --
    -- Checked BEFORE the held-weapon guard, because by now it is gone.
    if slot.kind == BR.ItemKind.THROWABLE
       and not HasPedGotWeapon(ped, hash, false) then
        if (slot.count or 0) > 0 then
            TriggerServerEvent(BR.Net.INV_AMMO,
                { slot = inv.active, total = 0, clip = 0 })
        end
        return
    end

    local heldOk, held = GetCurrentPedWeapon(ped, true)
    if not heldOk or BR.NormHash(held) ~= BR.NormHash(hash) then return end

    -- Nor while a reload is playing: the magazine is mid-swap and reads as
    -- whatever the animation has reached, which is not a number to build a
    -- reserve calculation on.
    if IsPedReloading(ped) then return end

    -- THE TOTAL IS THE NUMBER THAT MATTERS. The clip is only the split.
    --
    -- Four rounds of this bug were spent watching the wrong number. The model
    -- before this one reported GetAmmoInClip and let the server infer firing
    -- from the direction it moved -- but /brprobe raw showed the magazine
    -- pinned at 5 while GetAmmoInPedWeapon climbed by one per shot, so the one
    -- number we trusted was the one that never moved (user, 2026-08-06).
    --
    -- ox_inventory -- the inventory most FiveM servers actually run -- watches
    -- GetAmmoInPedWeapon and guards it with `if currentAmmo < weaponAmmo`: it
    -- refuses increases outright rather than explaining them. That guard is the
    -- whole answer. The total is what firing consumes, a reload only moves
    -- rounds between the two halves of it, and any RISE is by definition not
    -- something the player did.
    --
    -- So: decrease-only on the total, and the clip rides along purely so the
    -- server can keep the HUD's split honest.
    local granted = math.floor((slot.clip or 0) + reserveFor(slot))
    local total   = GetAmmoInPedWeapon(ped, hash) or 0

    -- THE CLAMP, and the reason this is now immune to whatever is doing it.
    -- The server said we hold `granted` rounds. The engine holding MORE than
    -- that is impossible under honest play, so it is written back down instead
    -- of being explained -- which fixes the runaway at the ped as well as in
    -- the counter. Never upward: writing ammo up is what produced the
    -- unlimited-ammo round.
    if total > granted then
        SetPedAmmo(ped, hash, granted)
        total = granted
    end

    -- GET_AMMO_IN_CLIP is a BOOL with an out-param, so Lua gets two returns.
    local _, clip = GetAmmoInClip(ped, hash)
    clip = math.max(0, math.min(clip or 0, total))

    -- THE DISPLAY DOES NOT WAIT FOR THE ROUND TRIP, OR FOR THE REPORT GATE.
    --
    -- The magazine is read straight off the gun in the player's hands, so
    -- there is nothing to check with the server before showing it. It used to
    -- move only when a report went out, once every 500ms, which at any real
    -- rate of fire meant the counter lagged several rounds behind the shots
    -- (user, 2026-08-06: "make it update like 3 or 4x"). This is every tick --
    -- 10Hz -- and costs one NUI message on the frames where it changed.
    --
    -- The RESERVE stays the server's and still arrives with the next INV_SET.
    if clip ~= slot.clip then
        slot.clip = clip
        pushUi()
    end

    local now = GetGameTimer()
    if now - lastReport.at < (L.ammoReportMs or 150) then return end
    lastReport.at = now

    -- No baseline yet (weapon just switched): take one and say nothing.
    if lastReport.total < 0 then
        lastReport.total, lastReport.clip = total, clip
        return
    end

    -- Nothing moved, or the total went UP. Either way there is nothing to tell
    -- the server -- and a rise must not be forwarded even as a split change,
    -- or it arrives as a reload the reserve did not pay for.
    if total > lastReport.total then return end
    if total == lastReport.total and clip == lastReport.clip then return end

    lastReport.total, lastReport.clip = total, clip
    TriggerServerEvent(BR.Net.INV_AMMO, {
        slot = inv.active, total = total, clip = clip,
    })
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

--- WHY IS THE AMMO REPORT NOT GOING OUT?
---
--- The report loop bails on six separate conditions, and every one of them
--- presents identically from the outside: the gun never runs dry. The Advanced
--- Rifle did exactly that while every other weapon behaved (user, 2026-08-06),
--- and no amount of reading the loop can say WHICH guard fired on a live ped.
---
--- So it reports itself. /brprobe ammo prints this, and the answer is a single
--- line rather than another round of hypotheses.
--- @return table
function BR.Inv.reportState()
    local ped   = PlayerPedId()
    local slot  = inv.slots[inv.active]
    local hash  = hashOf(slot)
    local heldOk, held = GetCurrentPedWeapon(ped, true)

    local why = nil
    if not canArm() then                    why = 'state is not ALIVE/DBNO/WARMUP'
    elseif BR.Inv.suspendAmmo then          why = 'suspended by /brprobe raw'
    elseif not slot then                    why = 'active slot is empty'
    elseif not hash then                    why = 'slot holds nothing weapon-shaped'
    elseif applied ~= hash then             why = 'our own grant has not landed yet'
    elseif not heldOk or BR.NormHash(held) ~= BR.NormHash(hash) then
                                            why = 'the ENGINE says the ped holds a different weapon'
    elseif IsPedInAnyVehicle(ped, false) then why = 'in a vehicle'
    elseif IsPedReloading(ped) then         why = 'mid-reload'
    end

    return {
        slotIndex = inv.active,
        item      = slot and slot.id or nil,
        wantHash  = hash,
        appliedHash = applied,
        engineHash  = heldOk and held or nil,
        engineTotal = hash and GetAmmoInPedWeapon(ped, hash) or nil,
        serverClip  = slot and slot.clip or nil,
        serverPool  = slot and reserveFor(slot) or nil,
        lastTotal   = lastReport.total,
        blockedBy   = why,
    }
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
