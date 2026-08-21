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
--- what the key does when it is pressed:
---
---   armed   a trail is EQUIPPED AND PAINTED -- there is something to turn on.
---   on      whether it is currently visible, so the toggle knows which way to
---           go and a fresh drop starts from a known state rather than from
---           whatever the last one left behind.
---
--- `on` STARTS FALSE ON EVERY DROP, WHATEVER IS EQUIPPED (owner, 2026-08-17:
--- "smoke trails should always default to off, which requires the player to
--- press the button, which will then dismiss our DUI").
---
--- It used to start TRUE in all three painting branches, so a player who owned a
--- trail flew it from the moment the canopy opened and the prompt was offering
--- them a way to switch something OFF. The prompt's sentence is "toggle smoke
--- trails" and the owner's design is that pressing it is what starts them; a
--- default of on made the key a mute button and made the box a notice rather
--- than an instruction.
---
--- ARMED IS UNCHANGED AND THAT SEPARATION IS NOW LOAD-BEARING. `armed` still
--- means a trail was painted, so it is still the test that decides whether there
--- is anything honest to prompt for; `on` is the player's answer. Skydive's
--- emitter holds INPUT_PARACHUTE_SMOKE only while BOTH are true, so nothing
--- comes out of the canopy until the key is pressed -- and `/brdropdbg` reading
--- `armed true  on false  emit frames 0` mid-glide is the CORRECT readout now,
--- not the symptom it was during #131.
---
--- ARMED IS SET BY THE BRANCH THAT PAINTS, NEVER BY THE EQUIPPED SLOT, and that
--- distinction is the whole of #131's fourth requirement. `worn['trail']` is
--- always present: the catalogue's default item is 'None', whose apply table is
--- literally `{}`, so it resolves to a present-but-EMPTY table and a slot test
--- would answer "yes" for a player who owns nothing. They would then be offered
--- a key for a trail that does not exist -- "a prompt for a thing they do not
--- have", which is the failure the issue names. Only the branches that actually
--- call SetPlayerParachuteSmokeTrailColor set this, so it cannot drift from what
--- is in the sky.
---
--- TWO FLAGS HAVE NOW GONE FROM HERE, AND BOTH WENT WITH A BRANCH.
---
--- `trailSquad` (#131, 2026-08-16) said "the colour up there is the squad's,
--- not the purchase", and everything that read it was a consequence of the squad
--- OVERRIDE the owner reversed.
---
--- `trailSource` ('purchase' | 'squad' | nil) outlived it and has gone with the
--- squad FALLBACK (owner, 2026-08-20: "'Squad color' trails should not be a
--- thing"). It was a receipt for one question -- "did my bought trail fly, or
--- did the squad colour take it" -- and there is no longer a squad colour to
--- take anything. With one possible non-nil value it was `armed and 'purchase'`
--- spelled out at three call sites and printed as a fourth fact in
--- `/brdropdbg`, which is a field its only writer could no longer fill.
BR.Cosmetics.trailArmed = false
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

--- Paint the trail this drop will fly. A purchase, or nothing.
---
--- THE SQUAD BRANCH IS GONE (owner, 2026-08-20: "'Squad color' trails should not
--- be a thing"), AND THIS FUNCTION HAS NOW ARGUED IT BOTH WAYS BEFORE LOSING IT.
--- First the squad colour OVERRODE a purchase, because finding your team in the
--- air is a gameplay read; #131 reversed that and left it as the fallback for
--- anyone who had not bought a trail. It is now neither, and this file takes no
--- squad argument at all.
---
--- REMOVING THE ITEM WITHOUT REMOVING THIS BRANCH WOULD HAVE BEEN THE WRONG HALF
--- OF THE INSTRUCTION. `trail_squad` was what an unspent player wore; delete it
--- and leave the fallback and every unspent player flies their squad's colour
--- with nothing in the storefront to un-equip -- strictly more squad-coloured
--- smoke than before, and no way out. The free default is `trail_none` and it
--- paints nothing, so the two halves agree.
---
--- WHAT THE TEAM LOSES IS ONE OPT-IN READ. Trails start OFF on every drop
--- (owner, 2026-08-17), so the squad colour only ever reached the sky when a
--- squadmate pressed the key for it. Markers, nameplates and the squad list are
--- untouched.
function BR.Cosmetics.applyTrail()
    local pid = PlayerId()
    local apply = BR.Cosmetics.get('trail')

    BR.Cosmetics.trailArmed = false
    BR.Cosmetics.trailOn = false
    liveRgb = nil

    -- THE PERMISSION STARTS OFF IN EVERY BRANCH BELOW, and it is the permission
    -- rather than only our own flag for a reason: with it granted, the player's
    -- own vanilla X still produces smoke, so a trail that is "off" would come
    -- out for anyone who happened to press it. `showTrail` grants it on the
    -- first press, and re-asserts the colour at the same time, which is what
    -- liveRgb above exists for. The COLOUR is still written here -- it costs one
    -- native and means the first press has nothing left to get wrong.
    if apply.trailCycle then
        SetPlayerCanLeaveParachuteSmokeTrail(pid, false)
        BR.Cosmetics.trailArmed = true
        BR.Cosmetics.trailOn = false
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
        SetPlayerCanLeaveParachuteSmokeTrail(pid, false)
        SetPlayerParachuteSmokeTrailColor(pid,
            apply.trailRgb[1], apply.trailRgb[2], apply.trailRgb[3])
        liveRgb = apply.trailRgb
        BR.Cosmetics.trailArmed = true
        BR.Cosmetics.trailOn = false
        return
    end

    -- NOTHING BOUGHT, SO NOTHING FLIES. This is what the free default item,
    -- 'None', means, and reaching it means the player is still wearing it,
    -- because every paid trail returns above.
    --
    -- THE PERMISSION IS STILL WITHDRAWN RATHER THAN LEFT ALONE. It is not our
    -- flag that emits smoke -- the player's own vanilla X does, if the engine is
    -- still permitting it from a previous drop -- so the one native here is what
    -- makes "no trail equipped" mean no trail on screen. `trailArmed` stays
    -- false, so the descent offers no prompt and the key does nothing.
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

--- GTA'S OWN SMOKE INPUT. Verified against docs.fivem.net's control table and
--- the alt:V control reference, 2026-08-16: index 154, INPUT_PARACHUTE_SMOKE,
--- default X on keyboard / A on Xbox. 145 is DETACH and 152/153 are the brakes.
local INPUT_PARACHUTE_SMOKE = 154

--- Actually leave smoke this frame. THIS IS THE LINE #131 WAS MISSING.
---
--- SET_PLAYER_CAN_LEAVE_PARACHUTE_SMOKE_TRAIL IS A PERMISSION, NOT AN EMITTER,
--- and that single misreading is the whole of this bug. Everything above sets
--- the permission and the colour and then stops, on the assumption that the
--- engine would start trailing on its own. It does not. In base GTA the
--- parachute smoke trail is a HELD CONTROL -- the player holds X under the
--- canopy and smoke comes out for exactly as long as they hold it. The two
--- natives decide whether that key is allowed to do anything and what colour it
--- produces; neither of them presses it.
---
--- So the owner's readout was true in every particular and still had no smoke in
--- it: `armed true`, `on true`, both natives called with a colour, permission
--- granted -- and nobody ever holding the key the permission was granted for.
--- That is why it has never rendered in either state, for anyone, since the
--- feature was written.
---
--- WE HOLD IT FOR THEM, because the owner's design is a TOGGLE on our own
--- rebindable key ("press [key] to toggle smoke trails"), not a hold on GTA's.
--- SetControlNormal writes the control's value for one frame only, so this has
--- to run every frame the trail is meant to be visible -- which is what makes it
--- a per-frame call in skydive.lua's descent loop rather than one more one-shot
--- beside the natives above.
---
--- The player's own X is left alone and still works: this ADDS a press, it does
--- not block one. With the trail toggled off the permission is false, so their X
--- produces nothing either -- the toggle stays authoritative, which is what the
--- prompt promises.
--- @return boolean  whether smoke was actually asked for this frame
function BR.Cosmetics.emitTrailThisFrame()
    if not BR.Cosmetics.trailArmed or not BR.Cosmetics.trailOn then
        return false
    end
    SetControlNormal(0, INPUT_PARACHUTE_SMOKE, 1.0)
    return true
end

--- What colour the ENGINE thinks it is holding, for /brdropdbg and nothing else.
---
--- AN ENGINE READBACK, WHICH IS THE ONE THING THE OLD READOUT DID NOT HAVE.
--- `armed`/`on`/`source` are all our own variables agreeing with themselves --
--- the owner's three prints showed them all healthy while nothing rendered, so
--- as evidence they are worth nothing. GET_PLAYER_PARACHUTE_SMOKE_TRAIL_COLOR
--- asks the game what it actually stored, so a write that never landed shows up
--- as a colour that is not the one we sent.
---
--- pcall'd because an absent native throws, and this runs inside a debug command
--- whose whole job is to still print the other twenty facts if one of them is
--- unavailable on this build.
--- @return string
function BR.Cosmetics.engineTrailColour()
    local ok, r, g, b = pcall(GetPlayerParachuteSmokeTrailColor, PlayerId())
    if not ok or type(r) ~= 'number' then return '(unreadable)' end
    return ('%d,%d,%d'):format(r, g, b)
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
