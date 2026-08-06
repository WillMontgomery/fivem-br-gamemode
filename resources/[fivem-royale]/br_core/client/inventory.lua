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

-- The mirror. Empty slots are `false`, exactly as they are on the wire and on
-- the server -- one representation, no boundary conversion to get wrong.
local inv = { slots = {}, ammo = {}, active = 1, using = nil }
for i = 1, SLOTS do inv.slots[i] = false end

-- What is actually in the ped's hands right now, and whose hands they were.
-- The ped handle matters: a respawn hands out a new one with no weapons on it.
local applied, appliedPed = nil, 0

-- Last ammo report, so the 2Hz push is silent when nothing was fired.
local lastReport = { clip = -1, pool = -1, at = 0 }

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

-- SCROLL UP CYCLES, SCROLL DOWN DOES NOTHING (user call, 2026-08-05). One
-- direction through a wrapping cycle reaches every slot and needs no thought
-- about which way you are going; two directions on a five-item ring is a
-- decision nobody wants mid-fight. Control 15 is the wheel's "previous",
-- which is what a scroll UP reports -- 14 (down) stays disabled and inert.
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
    if not canArm() then return end

    local ped = PlayerPedId()
    local slot = inv.slots[inv.active]
    local want = hashOf(slot)

    -- A new ped handle is a new, empty ped: re-apply whatever we thought was
    -- already there.
    if ped ~= appliedPed then
        applied, appliedPed = nil, ped
        force = true
    end
    if not force and want == applied then
        -- Same weapon, but the ammo behind it may have moved (a pickup, a
        -- report). Cheap enough to re-assert; SetPedAmmo is idempotent.
        if want and slot then
            SetPedAmmo(ped, want, reserveFor(slot) + (slot.clip or 0))
        end
        return
    end

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

--- Forget everything. Called at match teardown and on death.
local function clearLocal()
    for i = 1, SLOTS do inv.slots[i] = false end
    inv.ammo, inv.active, inv.using = {}, 1, nil
    applied, appliedPed = nil, 0
    lastReport.clip, lastReport.pool = -1, -1
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

    for i = 1, SLOTS do
        local s = d.slots[i]
        inv.slots[i] = (type(s) == 'table') and s or false
    end
    inv.ammo   = d.ammo or {}
    inv.active = d.active or 1
    inv.using  = d.using

    applyActive(false)
    pushUi()
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

    -- MOUSE WHEEL UP CYCLES SLOTS, WRAPPING. Past slot 5 is slot 1.
    if IsDisabledControlJustPressed(0, WHEEL_UP) then
        TriggerServerEvent(BR.Net.INV_SELECT, { slot = (inv.active % SLOTS) + 1 })
    end

    -- SHOOTING A CONSUMABLE USES IT (user call, 2026-08-05). With a med kit
    -- selected the attack button has nothing else to do, and reaching for the
    -- trigger is what a player does with whatever is in their hands. The
    -- control is the player's own ATTACK binding, whatever they set it to.
    local held = inv.slots[inv.active]
    if held and held.kind == BR.ItemKind.CONSUMABLE and not inv.using then
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
        DisableControlAction(0, 106, true)  -- VEH_MOUSE_CONTROL_OVERRIDE
    end
end)

-- The ammo report: 2Hz, decrease-only at the far end, and silent when nothing
-- moved. This is the ONE number the client is the only observer of until M6
-- validates shots server-side; see server/inventory.lua for why that is safe.
BR.Loop.register(BR.Loop.TICK, 'inv.ammo', function()
    if not canArm() then return end

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

    local ped   = PlayerPedId()
    local total = GetAmmoInPedWeapon(ped, hash)
    -- GET_AMMO_IN_CLIP is a BOOL with an out-param, so Lua gets two returns.
    local _, clip = GetAmmoInClip(ped, hash)
    clip = math.max(0, clip or 0)
    local pool = math.max(0, total - clip)

    if clip == lastReport.clip and pool == lastReport.pool then return end
    lastReport.clip, lastReport.pool = clip, pool

    local w = BR.Config.WeaponById[slot.id]
    local payload = { slot = inv.active, clip = clip }
    if w and w.ammo and slot.kind == BR.ItemKind.WEAPON then
        payload.pool = { [w.ammo] = pool }
    end
    TriggerServerEvent(BR.Net.INV_AMMO, payload)

    -- AND UPDATE OUR OWN MIRROR, which is what the HUD reads.
    --
    -- The server deliberately does not echo this back -- it would be a packet
    -- per player per half-second to tell them what they just said -- but that
    -- left NOTHING updating the display, so the ammo counter sat at whatever
    -- the weapon was picked up with while the magazine emptied (user,
    -- 2026-08-05). These numbers come from the engine, so writing them here is
    -- not the client deciding anything: it is the display agreeing with the
    -- gun in the player's hands.
    slot.clip = clip
    if w and w.ammo and slot.kind == BR.ItemKind.WEAPON then
        inv.ammo[w.ammo] = pool
    end
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
