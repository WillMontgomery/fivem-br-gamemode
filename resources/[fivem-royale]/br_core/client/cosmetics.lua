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

--- THE TRAIL'S STATE FOR THIS DROP, because a toggle needs something to toggle.
---
--- Read by skydive.lua to decide whether to draw the descent prompt at all and
--- what the key does when it is pressed. Three separate facts, and collapsing
--- any two of them loses a case:
---
---   armed  a trail is actually flying -- there is something to turn off.
---   squad  and it is the SQUAD's colour rather than the purchase, which is a
---          different thing to a different audience (see the override note
---          below). The prompt is suppressed on this, not on `armed`.
---   on     whether it is currently visible, so the toggle knows which way to
---          go and a fresh drop starts from a known state rather than from
---          whatever the last one left behind.
---
--- ARMED IS SET BY THE BRANCH THAT PAINTS, NEVER BY THE EQUIPPED SLOT, and that
--- distinction is the whole of #131's fourth requirement. `worn['trail']` is
--- always present: the catalogue's default item is 'Squad Colour', whose apply
--- table is literally `{ trailRgb = nil }`, so it resolves to a
--- present-but-EMPTY table and a slot test would answer "yes" for a player who
--- owns nothing. They would then be offered a key for a trail that does not
--- exist -- "a prompt for a thing they do not have", which is the failure the
--- issue names. Only the two branches that actually call
--- SetPlayerParachuteSmokeTrailColor set this, so it cannot drift from what is
--- in the sky.
BR.Cosmetics.trailArmed = false
BR.Cosmetics.trailSquad = false
BR.Cosmetics.trailOn = false

--- The colour currently painted, so turning the trail back ON can re-assert it.
---
--- SET_PLAYER_CAN_LEAVE_PARACHUTE_SMOKE_TRAIL is a permission and
--- SET_PLAYER_PARACHUTE_SMOKE_TRAIL_COLOR is a colour, and the pair has already
--- bitten this project once at the other end: the canopy tint is read when the
--- canopy opens, so setting it a moment late "looks exactly like the item the
--- player bought not working" (skydive.lua's own note, verbatim). A toggle that
--- only flipped the permission would be trusting the engine to have kept a
--- colour across a period where it was told nobody could see it. Re-asserting
--- costs one native call per press and removes the entire question.
---
--- nil for the cycling item, and deliberately: its thread rewrites the colour
--- every 350ms regardless, so there is nothing here worth remembering.
local liveRgb = nil

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

    BR.Cosmetics.trailArmed = false
    BR.Cosmetics.trailSquad = false
    BR.Cosmetics.trailOn = false
    liveRgb = nil

    if squadColour then
        SetPlayerCanLeaveParachuteSmokeTrail(pid, true)
        local r, g, b = hexToRgb(squadColour)
        SetPlayerParachuteSmokeTrailColor(pid, r, g, b)
        liveRgb = { r, g, b }
        BR.Cosmetics.trailArmed = true
        BR.Cosmetics.trailSquad = true
        BR.Cosmetics.trailOn = true
        return
    end

    if apply.trailCycle then
        SetPlayerCanLeaveParachuteSmokeTrail(pid, true)
        BR.Cosmetics.trailArmed = true
        BR.Cosmetics.trailOn = true
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
        liveRgb = apply.trailRgb
        BR.Cosmetics.trailArmed = true
        BR.Cosmetics.trailOn = true
        return
    end

    -- No squad, no bought trail: leave it off rather than picking something.
    SetPlayerCanLeaveParachuteSmokeTrail(pid, false)
end

--- Turn the trail this drop already chose off, or back on. Never re-decides it.
---
--- The colour is re-asserted on the way ON rather than trusted, for the reason
--- given beside liveRgb. On the way OFF the colour is left alone: it is
--- invisible either way, and writing it would only be there to look symmetric.
--- @param on boolean
--- @return boolean acted  false when there is no trail flying to act on
function BR.Cosmetics.showTrail(on)
    if not BR.Cosmetics.trailArmed then return false end
    on = on == true

    local pid = PlayerId()
    if on and liveRgb then
        SetPlayerParachuteSmokeTrailColor(pid, liveRgb[1], liveRgb[2], liveRgb[3])
    end
    SetPlayerCanLeaveParachuteSmokeTrail(pid, on)
    BR.Cosmetics.trailOn = on
    return true
end

--- The drop is over: no trail, and no state left claiming otherwise.
---
--- ONE PLACE TURNS IT OFF, and that is the point of the function existing for
--- what used to be a single native call. skydive.lua stands the trail down from
--- two different endings -- a landing and a vehicle seat -- and a third that
--- forgot to clear the flags would leave `trailArmed` true into the next drop,
--- where a player with nothing equipped would be offered a prompt for the trail
--- the PREVIOUS round happened to fly. That is the exact class of bug #131 is
--- about: an interface confidently naming a thing the player does not have.
function BR.Cosmetics.clearTrail()
    SetPlayerCanLeaveParachuteSmokeTrail(PlayerId(), false)
    BR.Cosmetics.trailArmed = false
    BR.Cosmetics.trailSquad = false
    BR.Cosmetics.trailOn = false
    liveRgb = nil
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
