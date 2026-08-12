--[[
    What the player is wearing, and the natives that put it there.

    THE SERVER SENDS IDS; THIS FILE RESOLVES THEM. BR.Config.MarketIndex is
    shared, so the client can turn `chute_hornet` into `{ chuteTint = 7 }`
    without the server having to serialise a table of natives across the wire.
    The server remains the only thing that decides WHICH id -- this side only
    knows how to wear one.

    NOTHING IN HERE MAY CHANGE HOW A FIGHT GOES. Every apply below is a texture
    or a colour: the parachute model, hitbox and descent rate are untouched, the
    weapon's geometry and damage are untouched. If a future item needs anything
    other than an appearance, it does not belong in this file and probably does
    not belong in the market.

    IT FAILS TO THE DEFAULTS AND NEVER TO AN ERROR. A player whose market state
    never arrived gets index 0 and the squad trail -- which is exactly what
    every player had before any of this existed.
]]

BR = BR or {}
BR.Cosmetics = BR.Cosmetics or {}

--- kind -> apply table, as resolved from the last MARKET_STATE.
local worn = {}

--- The cycling-trail thread's generation counter. Incremented on every equip
--- change so an old cycle cannot keep writing colours after a new item is on.
local trailGen = 0

--- The apply table for one slot, or an empty table.
--- @param kind string
--- @return table
function BR.Cosmetics.get(kind)
    return worn[kind] or {}
end

RegisterNetEvent(BR.Net.MARKET_STATE)
AddEventHandler(BR.Net.MARKET_STATE, function(state)
    if type(state) ~= 'table' then return end

    local next_ = {}
    for kind, id in pairs(state.equipped or {}) do
        local item = BR.Config.MarketIndex[id]
        if item and item.apply then next_[kind] = item.apply end
    end
    worn = next_
    trailGen = trailGen + 1

    -- The market page lives in br_ui, in another Lua state. It gets the same
    -- event; this handler is only about wearing things.
end)

-- ----------------------------------------------------------------- canopy ---

--- The canopy index to use for this drop.
---
--- CALLED BY skydive.lua INSIDE ITS EXISTING WINDOW -- after the model override
--- and before TaskParachute. The order is not stylistic: the tint is read when
--- the canopy opens, so setting it afterwards leaves the previous design up
--- and looks exactly like the item not working.
function BR.Cosmetics.applyChute()
    local tint = BR.Cosmetics.get('chute').chuteTint
    if type(tint) ~= 'number' then return end

    local pid = PlayerId()
    SetPlayerParachuteTintIndex(pid, tint)
    -- The pack is a separate native and a separate texture. A black pack under
    -- a red canopy reads as a bug rather than as a cosmetic.
    SetPlayerParachutePackTintIndex(pid, tint)
end

-- ------------------------------------------------------------------ trail ---

--- Squad colour wins over a bought trail, and that is a gameplay decision.
---
--- The trail is how you find your team in the air. A player who bought Void
--- and then could not tell which smoke was their squadmate's would have paid
--- to make the game harder to read -- so the purchase applies when you are
--- dropping alone, and the squad colour overrides it when you are not.
--- @param squadColour string|nil  the squad's hex colour, if in a squad
--- @param hexToRgb function
function BR.Cosmetics.applyTrail(squadColour, hexToRgb)
    local pid = PlayerId()
    local apply = BR.Cosmetics.get('trail')

    if squadColour then
        SetPlayerCanLeaveParachuteSmokeTrail(pid, true)
        SetPlayerParachuteSmokeTrailColor(pid, hexToRgb(squadColour))
        return
    end

    if apply.trailCycle then
        SetPlayerCanLeaveParachuteSmokeTrail(pid, true)
        local gen = trailGen
        local colours = apply.trailCycle
        local ms = math.max(100, tonumber(apply.trailCycleMs) or 350)
        Citizen.CreateThread(function()
            local i = 1
            -- Stops the moment the canopy is gone or a different item is
            -- equipped. A cycle left running would keep calling a native every
            -- 350ms for the rest of the session.
            while gen == trailGen do
                local c = colours[i]
                SetPlayerParachuteSmokeTrailColor(pid, c[1], c[2], c[3])
                i = i % #colours + 1
                Citizen.Wait(ms)
                if GetPedParachuteState(PlayerPedId()) == BR.Native.ChuteState.NONE then
                    return
                end
            end
        end)
        return
    end

    if apply.trailRgb then
        SetPlayerCanLeaveParachuteSmokeTrail(pid, true)
        SetPlayerParachuteSmokeTrailColor(pid,
            apply.trailRgb[1], apply.trailRgb[2], apply.trailRgb[3])
        return
    end

    -- No squad, no bought trail: leave it off rather than picking something.
    SetPlayerCanLeaveParachuteSmokeTrail(pid, false)
end

-- ----------------------------------------------------------- weapon finish ---

--- Weapons are tinted as they come to hand.
---
--- POLLED RATHER THAN HOOKED, and cheaply. There is no "weapon changed" event
--- in this codebase, and the alternatives are worse: tinting inside the
--- inventory code would put a cosmetic concern in the middle of the thing that
--- decides what you are holding, and tinting once on give would miss every
--- weapon picked up from the ground -- which in a battle royale is all of them.
---
--- Half a second is imperceptible for something that only matters when you look
--- at your own hands, and the native is a no-op when the tint already matches.
Citizen.CreateThread(function()
    local last = nil
    while true do
        Citizen.Wait(500)

        local tint = BR.Cosmetics.get('weapon').weaponTint
        if type(tint) == 'number' then
            local ped = PlayerPedId()
            local ok, cur = pcall(GetSelectedPedWeapon, ped)
            if ok and cur and cur ~= 0 and (cur ~= last or tint ~= 0) then
                last = cur
                SetPedWeaponTintIndex(ped, cur, tint)
            end
        end
    end
end)
