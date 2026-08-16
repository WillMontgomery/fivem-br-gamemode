-- The drop: freefall -> glider -> ground.
--
-- Driven entirely by GET_PED_PARACHUTE_STATE, because the engine's own state
-- is the only honest answer to "is the chute out yet" -- inferring it from
-- velocity or height re-derives what the ped already knows.
--
-- THE CHUTE IS A WEAPON AND IT MUST BE GIVEN. TASK_PARACHUTE's second
-- parameter looks like "give parachute" and is verified UNUSED (a removed
-- legacy jetpack flag) -- task a ped without GADGET_PARACHUTE in their
-- inventory and they fall to their death with the animation of someone
-- reaching for a ripcord that is not there.

BR = BR or {}

local CHUTE = GetHashKey('GADGET_PARACHUTE')   -- 0xFBAB5776, verified

local dropping = false

--- Tell the server we are down, and KEEP TELLING IT UNTIL IT AGREES.
---
--- THE REPORT USED TO BE FIRE-AND-FORGET, and it is the single most
--- historically unreliable message in this project -- the server-side
--- stuck-lander promotion exists precisely because it goes missing. When it
--- does, nothing retried: the player stayed FREEFALL until that net noticed
--- five seconds of stillness, and since the net needs two fresh 2Hz position
--- samples either side of those five seconds, the real wait was closer to ten.
--- A solo player landed and then stood in an empty world with no HUD and no
--- inventory for over ten seconds (user, 2026-08-08).
---
--- Every consequence of landing hangs off the ALIVE state -- the HUD, the
--- inventory bar, loot visibility, being shootable -- so one dropped packet
--- costs all of it.
---
--- The fix is the same shape as the chute REMOVAL directly below, and for the
--- same reason: a message that must arrive is re-sent until the world reflects
--- it, rather than sent once and hoped for. The server is still the only
--- authority -- it validates the state transition exactly as before and
--- ignores a duplicate -- so the worst case is a handful of tiny events.
local function reportLanded()
    TriggerServerEvent(BR.Net.DROP_LANDED)

    Citizen.CreateThread(function()
        for attempt = 1, 12 do
            Citizen.Wait(400)

            -- The server has agreed: our own mirror says we are on the
            -- ground. Nothing to re-send.
            local st = BR.State.me.state
            if st ~= BR.PlayerState.FREEFALL
               and st ~= BR.PlayerState.GLIDE
               and st ~= BR.PlayerState.BUS then
                if attempt > 1 then
                    print(('[br_core] landing confirmed after %d re-sends')
                        :format(attempt - 1))
                end
                return
            end

            -- Airborne again is not a lost packet. A player who was promoted
            -- and then walked off a cliff must not be re-reporting a landing.
            if dropping then return end

            TriggerServerEvent(BR.Net.DROP_LANDED)
        end
        print('[br_core] landing report never took -- server still thinks we '
            .. 'are airborne after 12 attempts')
    end)
end

-- THE LANDING LATCH. The landing test is "chute away, feet on something" --
-- which is also true in the instant AFTER THE JUMP, before the exit
-- velocity and parachute task have taken hold: the ped still reads as
-- on-foot, so the landing branch fired seconds into the fall. That sent a
-- false DROP_LANDED (the server marked the player ALIVE mid-air -- the
-- premature storm clock), and re-fired every re-arm: the stack of four
-- "Loot up!" toasts. Landing only counts after the drop has actually been
-- AIRBORNE at least once.
local airborneSeen = false

-- THE CANOPY IS OUT, SO THE WEAPON IS SPENT.
--
-- GTA does NOT consume GADGET_PARACHUTE when the canopy opens: the ped keeps
-- the weapon with its ammo intact, which is the engine's definition of "has a
-- parachute available". That is why a player who had already pulled was still
-- armed with a second one and why the vanilla deploy prompt came back the
-- moment they were near the ground (live report, 2026-08-05 -- the third
-- distinct reserve-chute symptom, and the first one whose cause was the
-- ENGINE'S ammo model rather than one of our own give paths).
--
-- Zeroing the ammo the instant the canopy appears leaves the open canopy
-- alone (the parachute TASK owns it, not the inventory entry) while making a
-- redeploy impossible. Removing the weapon outright here would be the obvious
-- move and is exactly what we do NOT do: pulling the weapon out from under a
-- live parachute task is how you drop someone out of their own canopy.
local chuteSpent = false

--- Take the parachute away for good, and kill the vanilla prompt with it.
---
--- `hard` is the second attempt: RemoveWeaponFromPed has now failed to shift
--- GADGET_PARACHUTE often enough (it is a gadget, not an ordinary weapon, and
--- the parachute task can hand it straight back as it unwinds) that the
--- fallback is RemoveAllPedWeapons -- which does work, and is safe here
--- because client/inventory.lua re-grants the active slot on its next tick.
--- @param ped integer
--- @param hard boolean|nil
local function disarmChute(ped, hard)
    if hard then
        RemoveAllPedWeapons(ped, true)
        if BR.Inv and BR.Inv.reapply then BR.Inv.reapply() end
    else
        RemoveWeaponFromPed(ped, CHUTE)
    end
    -- The COUNT is ammo and outlives the weapon removal; this is the line the
    -- "reserve chute after landing" reports kept coming back to.
    SetPedAmmo(ped, CHUTE, 0)
    ClearHelp(true)
end

--- Does this ped still have a parachute in any sense the engine cares about?
--- @param ped integer
--- @return boolean
local function hasChute(ped)
    return HasPedGotWeapon(ped, CHUTE, false)
        or GetAmmoInPedWeapon(ped, CHUTE) > 0
end

--- Parse '#RRGGBB' (the squad colour the server assigned) into rgb.
local function hexToRgb(hex)
    if type(hex) ~= 'string' then return 255, 255, 255 end
    local r, g, b = hex:match('^#(%x%x)(%x%x)(%x%x)$')
    if not r then return 255, 255, 255 end
    return tonumber(r, 16), tonumber(g, 16), tonumber(b, 16)
end

AddEventHandler('br:drop:begin', function(d)
    -- One-shot thread: the give-verify-task sequence needs real frames
    -- between steps, and the first flight ended with a player falling
    -- chuteless -- never again on an assumption. dropping is set FIRST so
    -- the SPACE listener in bus.lua stands down immediately.
    dropping = true
    airborneSeen = false
    chuteSpent = false
    -- Out of the door is the one moment that unambiguously un-lands you. See
    -- the note where this is SET, at the bottom of the drop machine.
    BR.State.landed = false

    Citizen.CreateThread(function()
        local ped = PlayerPedId()

        SetEntityVisible(ped, true, false)
        FreezeEntityPosition(ped, false)
        ClearPedTasksImmediately(ped)

        -- Carry the bus's momentum out of the door; a dead-stop exit reads
        -- as teleportation even when the coordinates are right.
        local rad = math.rad(d.heading or 0.0)
        SetEntityVelocity(ped, -math.sin(rad) * 25.0, math.cos(rad) * 25.0, -2.0)

        -- THE CHUTE, VERIFIED -- and NEVER DOUBLED. GiveWeaponToPed is
        -- normally instant, but the one scenario where it quietly fails is
        -- a player mid-teleport -- which is exactly when this runs. Confirm
        -- it stuck, retry across real frames, and say so out loud if the
        -- game refuses. The has-check comes FIRST: giving a second
        -- GADGET_PARACHUTE to a ped that already holds one (the TICK
        -- floor's give can race this thread) stacks as chute ammo, which
        -- the engine treats as a RESERVE parachute -- the "handed another
        -- parachute after pulling the first" report (2026-08-04).
        for attempt = 1, 10 do
            if HasPedGotWeapon(ped, CHUTE, false) then break end
            GiveWeaponToPed(ped, CHUTE, 1, false, false)
            if HasPedGotWeapon(ped, CHUTE, false) then break end
            if attempt == 10 then
                print('[br_core] drop: GADGET_PARACHUTE refused 10 times -- deploy will not work')
            end
            Citizen.Wait(0)
        end
        -- EXACTLY ONE, ALWAYS. Chute count is ammo, and a count above one
        -- is what the engine treats as a RESERVE parachute -- there is no
        -- reserve in this gamemode, whatever race between give paths may
        -- have happened (user rule, 2026-08-04).
        SetPedAmmo(ped, CHUTE, 1)

        SetPlayerParachuteModelOverride(PlayerId(),
            GetHashKey(BR.Config.Drop.parachuteModel))

        -- THE EQUIPPED CANOPY, AND IT HAS TO BE HERE. The tint is read when the
        -- canopy opens, so this must sit after the model override and before
        -- TaskParachute below -- the same window the smoke trail already used.
        -- Set it later and the previous design stays up, which looks exactly
        -- like the item the player bought not working.
        BR.Cosmetics.applyChute()

        -- Squad identity in the air, exactly as cheap as it looks -- and it
        -- still outranks a bought trail, because finding your squadmate's
        -- smoke is a gameplay read and the purchase is decoration.
        if BR.Config.Drop.smokeTrail then
            local me = BR.State.roster[BR.State.me.src]
            -- SQUADDED, not merely coloured. Every roster entry carries a
            -- colour whether or not the player is in a squad, so testing
            -- `me.colour` would hand the squad colour to solo players too and
            -- no bought trail would ever appear. `squadId` is the question
            -- actually being asked, and roster.lua is careful to clear it.
            local squadColour = (me and me.squadId) and me.colour or nil
            BR.Cosmetics.applyTrail(squadColour, hexToRgb)
        end

        -- TASKED, VERIFIED, RETRIED. TaskParachute issued in the same frame
        -- as a long teleport can silently not take -- the ped is mid-warp --
        -- and a ped without the task reports chute state -1 forever, which
        -- made SPACE dead on flight 3. The state saying FREEFALL/OPENING is
        -- the only proof the task exists.
        for attempt = 1, 8 do
            TaskParachute(ped, true, false)   -- second param verified unused
            Citizen.Wait(150)
            local cs = GetPedParachuteState(ped)
            if cs ~= BR.Native.ChuteState.NONE then break end
            if attempt == 8 then
                print('[br_core] drop: TaskParachute never took after 8 attempts')
            end
        end

        -- (The glider prompt is drawn per-frame below, so it persists until
        -- the canopy is actually out.)
    end)
end)

--- The smoke-trail key's readable name, cached for the length of a binding.
---
--- CACHED BECAUSE THE PROMPT IS PER-FRAME, and invalidated because a rebind has
--- to move it. Both halves are copied from the crate prompt, which learned them
--- the expensive way: it rebuilt its payload only when the target changed, so
--- rebinding interact in front of a crate "kept saying the old key until they
--- walked away and back" (user, 2026-08-09). A prompt drawn sixty times a
--- second must not do the lookup sixty times a second, and must not remember
--- the answer past the moment it stops being true.
---
--- `checked` is separate from the label because nil is a real answer: a player
--- who has deliberately cleared this binding has NO key, and re-asking every
--- frame for an answer that will not change is what the cache is avoiding.
local trailKey, trailKeyChecked = nil, false

AddEventHandler('br:keys:changed', function()
    trailKey, trailKeyChecked = nil, false
end)

--- @return string|nil  nil when the action is on no key at all
local function trailKeyName()
    if not trailKeyChecked then
        trailKeyChecked = true
        -- NO VANILLA FALLBACK CONTROL, on purpose. The obvious second argument
        -- is GTA's own parachute-smoke input, and naming it here would quietly
        -- reintroduce the thing the owner ruled out (2026-08-16): "I'd rather
        -- not re-use that since it means leaving our own keybinds authority yet
        -- again." If our binding cannot be named, the honest move is to draw no
        -- prompt rather than to point at a key we do not route.
        trailKey = BR.Native.keyLabelForCommand('brtrail')
    end
    return trailKey
end

-- The glider prompt PERSISTS until the chute is genuinely pulled -- redrawn
-- per frame while falling with the canopy stowed, gone the frame it opens.
-- ~INPUT_PARACHUTE_DEPLOY~ renders the player's real base-game bind (the
-- engine's own deploy input works during the fall, since the ped is in a
-- genuine parachute task; our keybind works alongside).
--
-- AND THE CANOPY HANDS THE BOX OVER RATHER THAN EMPTYING IT (#131). The owner
-- asked for "a pointer text akin to the current 'press [key] to pull
-- parachute'" and then, "after pulling the chute it should say 'press [key] to
-- toggle smoke trails'" -- one help box, two jobs, in sequence. So this is an
-- if/elseif and not two independent prompts: the descent never wants both at
-- once, and two callers of helpThisFrame in one frame is a box that flickers
-- between two sentences rather than a box that changed its mind.
BR.Loop.register(BR.Loop.FRAME, 'skydive.prompt', function()
    if not dropping then return end
    local ped = PlayerPedId()

    -- F IS NOT A RIPCORD-CUTTER. INPUT_PARACHUTE_DETACH (153, default F)
    -- cuts the canopy mid-glide in base GTA -- and F is also the default
    -- enter-vehicle key, so players who reached for a door mid-descent
    -- dropped out of the sky (live report, 2026-08-04). Dead for the
    -- whole drop.
    DisableControlAction(0, 153, true)

    local cs = GetPedParachuteState(ped)
    -- The airborne test must NOT be `not IsPedOnFoot`: a ped in the
    -- parachute task's freefall COUNTS AS ON FOOT, so that gate killed the
    -- prompt for the entire healthy drop (live report, 2026-08-04). What
    -- it was guarding against -- the canopy detaching a beat before the
    -- TICK landing branch disarms, flashing "open the glider" at a player
    -- standing on the ground -- is covered by the freefall/falling pair
    -- below, both false for a ped with feet on anything.
    if (IsPedInParachuteFreeFall(ped) or IsPedFalling(ped))
       and (cs == BR.Native.ChuteState.ON_BACK
            or cs == BR.Native.ChuteState.FREEFALL) then
        BR.Native.helpThisFrame('Press ~INPUT_PARACHUTE_DEPLOY~ to open the glider.')

    elseif cs == BR.Native.ChuteState.OPENING
        or cs == BR.Native.ChuteState.OPEN then
        -- THREE THINGS HAVE TO BE TRUE, and each one is a prompt somebody would
        -- otherwise be shown for nothing.
        --
        -- ARMED: there is a trail flying. Every player has a trail EQUIPPED --
        -- the catalogue default is 'Squad Colour', which paints nothing of its
        -- own -- so the slot is not the question, and only the branches that
        -- actually paint set this flag (cosmetics.lua argues it beside
        -- trailArmed). #131 is explicit that "somebody with nothing equipped
        -- should see no prompt at all rather than a prompt for a thing they do
        -- not have".
        --
        -- NOT THE SQUAD'S: in a squad the colour in the sky is the team's
        -- position marker, not the purchase, and it is deliberately allowed to
        -- override a bought trail (br_lib/config/market.lua and cosmetics.lua
        -- both argue it). Offering to switch that off would be offering to
        -- delete a gameplay read on behalf of three other people who were not
        -- asked -- so the prompt is suppressed and the key declines, with the
        -- explanation moved to the press itself where it answers a question
        -- somebody actually had.
        --
        -- NOT ON FOOT: a canopy still attached after touchdown holds the ped
        -- off "on foot" (the landing branch's own scar), so this alone is not a
        -- complete grounded test -- but it is the cheap half, it is exact for
        -- the ordinary landing where the canopy sheds, and the TICK machine
        -- clears `dropping` within 100ms for the case it misses. A tenth of a
        -- second of a prompt is not worth GetEntityHeightAboveGround on the
        -- frame path, which is the one native this file keeps off it by name.
        if BR.Cosmetics.trailArmed
           and not BR.Cosmetics.trailSquad
           and not IsPedOnFoot(ped) then
            local key = trailKeyName()
            -- A LITERAL LETTER, NOT A GLYPH, AND IT CANNOT BE OTHERWISE. The
            -- line above renders a real button image because
            -- ~INPUT_PARACHUTE_DEPLOY~ is one of the engine's own controls;
            -- "custom keymapping hashes refused to render a glyph in help text"
            -- (bus.lua, verified in game). So the key is resolved to a string
            -- and printed. Same box, same wording, same position -- the letter
            -- is plain where the other is drawn.
            if key then
                BR.Native.helpThisFrame(
                    ('Press %s to toggle smoke trails.'):format(key))
            end
        end
    end
end)

-- THE TOGGLE ITSELF (#131).
--
-- The owner playtested the previous answer to this issue -- which correctly
-- established that trails were automatic and added help text saying so -- and
-- reported "I can't tell anything was even changed". The requirement moved:
-- there is to be a key, it is to be ours, and the descent is to say so. This is
-- that key.
--
-- IT ONLY EVER FLIPS A SWITCH THE DROP ALREADY THREW. showTrail does not
-- re-decide the colour, and this does not call applyTrail -- the whole
-- squad-versus-purchase decision is made once at br:drop:begin, in the window
-- between the parachute model override and TaskParachute where the engine
-- actually reads it. Re-running that decision from a key press would move it
-- outside its window, and a trail set outside its window "looks exactly like
-- the item the player bought not working" -- which is the report this issue
-- opened with.
BR.Keys.on('trail', function(pressed)
    if not pressed or not dropping then return end

    -- SQUADDED IS A REFUSAL WITH AN ANSWER ATTACHED, not a dead key.
    --
    -- The prompt is suppressed in a squad, so nothing invited this press --
    -- but a player who learned the key on a solo drop WILL press it in a
    -- squad, and this project has already written down what a key that does
    -- nothing costs ("a dead key during a fatal fall is the worst possible
    -- failure mode, twice observed", forty lines up). One-shot help rather
    -- than the per-frame box: it is a reply to a press, so it should fade like
    -- one, and BR.Native.help is the variant that does.
    if BR.Cosmetics.trailSquad then
        BR.Native.help('Your squad\'s colour is flying instead, so your team '
            .. 'can find you. It stays on.')
        return
    end

    -- Nothing equipped, or the trail system switched off in config: no prompt
    -- was drawn and there is nothing to flip. Silent, because this is a market
    -- question and not a descent one -- a message here would be an
    -- advertisement fired by a key press mid-fall.
    if not BR.Cosmetics.trailArmed then return end

    BR.Cosmetics.showTrail(not BR.Cosmetics.trailOn)
end)

-- Manual deploy on OUR keymapped binding too (the base game's own deploy
-- input already works natively during the task). If the engine lost the
-- parachute task (state -1 while clearly airborne), this re-tasks instead of
-- doing nothing -- a dead key during a fatal fall is the worst possible
-- failure mode, twice observed.
BR.Keys.on('deploy', function(pressed)
    if not pressed or not dropping then return end
    local ped = PlayerPedId()
    if IsPedInAnyVehicle(ped, true) then return end
    local cs = GetPedParachuteState(ped)
    -- ON_BACK is the state a HEALTHY drop spends its whole freefall in (the
    -- chute was given, so the engine never reports 3/falling-to-doom). The
    -- old check only forced the canopy from FREEFALL, which is why the key
    -- read as dead for every player whose drop was going fine.
    if cs == BR.Native.ChuteState.FREEFALL
       or cs == BR.Native.ChuteState.ON_BACK then
        ForcePedToOpenParachute(ped)
    elseif cs == BR.Native.ChuteState.NONE
       and not IsPedOnFoot(ped) and not IsEntityInWater(ped) then
        -- State NONE means the TASK is lost, not necessarily the weapon --
        -- re-giving one the ped still holds stacks a reserve chute.
        if not HasPedGotWeapon(ped, CHUTE, false) then
            GiveWeaponToPed(ped, CHUTE, 1, false, false)
        end
        SetPedAmmo(ped, CHUTE, 1)   -- exactly one; never a reserve
        TaskParachute(ped, true, false)
    end
end)

-- The drop state machine, at TICK rate -- 10Hz is far finer than any of
-- these transitions and keeps GetEntityHeightAboveGround (slow) off the
-- frame path.
BR.Loop.register(BR.Loop.TICK, 'skydive.state', function()
    -- Armed by the drop handoff OR by the server calling me a faller --
    -- whichever arrives first. Gating on the handoff alone meant that if it
    -- was ever missed, the chute floor below was disarmed for exactly the
    -- player who needed it.
    if not dropping then
        local st = BR.State.me.state
        if st == BR.PlayerState.FREEFALL or st == BR.PlayerState.GLIDE then
            dropping = true
        else
            return
        end
    end

    local ped = PlayerPedId()

    -- A DRIVER'S SEAT IS NOT A DROP. In a vehicle IsPedOnFoot is false, so
    -- the airborne test below reads "falling" -- and the chute floor then
    -- gave the ped a parachute, re-tasked it, and forced the canopy, which
    -- EJECTS from the vehicle (live report: "given a parachute, prompted to
    -- pull, immediately ejected"). If the machine was somehow still armed
    -- when the player got in, entering a vehicle IS proof of being landed:
    -- finish the drop and stand down.
    if IsPedInAnyVehicle(ped, true) then
        if dropping then
            dropping = false
            disarmChute(ped)
            BR.Cosmetics.clearTrail()
            reportLanded()
            print('[br_core] drop: finished from a vehicle seat -- the machine was still armed')
        end
        return
    end

    local cs = GetPedParachuteState(ped)

    -- Spend the chute the moment the canopy appears -- see the note on
    -- chuteSpent at the top. One write, latched, so this is not fighting the
    -- engine every tick of a two-minute glide.
    if not chuteSpent
       and (cs == BR.Native.ChuteState.OPENING
            or cs == BR.Native.ChuteState.OPEN) then
        chuteSpent = true
        SetPedAmmo(ped, CHUTE, 0)
    elseif not chuteSpent then
        -- EXACTLY ONE, EVERY TICK, FOR THE WHOLE FALL.
        --
        -- Setting it once at the give was not enough: a count above one is
        -- what the engine renders as a reserve, and something puts it back
        -- (the parachute task's own setup is the suspect -- MP peds are
        -- expected to carry a spare). Rather than keep guessing which path
        -- does it, this simply refuses to let the count be anything but one
        -- while the canopy is stowed. It is one native write at 10Hz.
        if GetAmmoInPedWeapon(ped, CHUTE) > 1 then
            SetPedAmmo(ped, CHUTE, 1)
        end
    end

    -- THE FLOOR, UNCONDITIONALLY. Below the auto-deploy height with the
    -- canopy not out, this hammers EVERY tick until it is: re-give, re-task,
    -- force -- regardless of which state the chute machinery claims to be in
    -- (-1 task lost, 0 stowed, 3 freefall; ragdolls lie about all three).
    -- Earlier versions gated each recovery step on the state that step
    -- expected, and players fell past a floor made of preconditions. The
    -- descent is invincible as the last net, but the chute is the fix.
    local agl = GetEntityHeightAboveGround(ped)
    local airborne = not IsPedOnFoot(ped) and not IsEntityInWater(ped)
    if airborne and agl > 3.0 then airborneSeen = true end
    -- The floor's band has a BOTTOM as well as a top: below ~3m a chute
    -- can do nothing, and firing there is pure harm -- the vehicle-entry
    -- animation reads as "airborne at ground level" for a beat (not on
    -- foot, chute state NONE once the task drops), and the floor answered
    -- it by handing the player a parachute and forcing it open ("given a
    -- chute the moment I try to enter a vehicle", live report 2026-08-04).
    if airborne
       and cs ~= BR.Native.ChuteState.OPENING
       and cs ~= BR.Native.ChuteState.OPEN
       and agl > 3.0
       and agl < BR.Config.Drop.autoDeployAGL then
        if not HasPedGotWeapon(ped, CHUTE, false) then
            GiveWeaponToPed(ped, CHUTE, 1, false, false)
        end
        -- Ammo is re-asserted here even when the weapon was already held: the
        -- canopy-spent latch above zeroes it, and a chute that reverted to
        -- ON_BACK afterwards would have nothing to deploy. The floor is the
        -- unconditional net -- it must not be able to fire blanks.
        SetPedAmmo(ped, CHUTE, 1)   -- exactly one; never a reserve
        chuteSpent = false
        if cs ~= BR.Native.ChuteState.FREEFALL then
            TaskParachute(ped, true, false)
        end
        ForcePedToOpenParachute(ped)
        return
    end

    -- Landed: on the ground, not falling, canopy not mid-opening -- and
    -- only after the drop has actually BEEN airborne (see the latch note
    -- at the top). Water counts: a sea landing is a bad drop, not a
    -- continuing one.
    --
    -- ANY chute state except OPENING counts as landed. The old test
    -- required NONE/ON_BACK, but the engine sometimes keeps the canopy
    -- ATTACHED after touchdown (state still OPEN, with GTA's own "press F
    -- to release parachute" prompt) -- so the machine stayed armed, the
    -- glider prompt lingered, and the next F press (bound to enter-vehicle)
    -- hit the chute floor from a driver's seat: the parachute-in-a-car
    -- ejection, root-caused at last (user insight, 2026-08-04).
    --
    -- AND on-foot alone is not the whole grounded test: with the canopy
    -- still ATTACHED the parachute task holds the ped off "on foot"
    -- indefinitely -- the machine stayed armed on the ground, which kept
    -- F dead (control 153 stays disabled while dropping) and left the
    -- floor loaded for the vehicle-entry gap (live report, 2026-08-04:
    -- "press F, nothing; enter a vehicle, given a chute"). A ped standing
    -- still at ground level with the canopy out has landed, whatever the
    -- task claims.
    local grounded = IsPedOnFoot(ped) or IsEntityInWater(ped)
    if not grounded and cs == BR.Native.ChuteState.OPEN
       and agl < 2.0 and GetEntitySpeed(ped) < 2.0 then
        grounded = true
    end
    if airborneSeen
       and cs ~= BR.Native.ChuteState.OPENING
       and not IsPedFalling(ped)
       and grounded then
        dropping = false

        if cs == BR.Native.ChuteState.OPEN then
            -- Shed the still-attached canopy along with its vanilla prompt.
            ClearPedTasks(ped)
        end

        -- REMOVAL IS VERIFIED, NOT ASSUMED. The give path has retried across
        -- real frames since flight one, on the grounds that GiveWeaponToPed
        -- can quietly fail around a teleport -- and the removal path, doing
        -- the mirror-image thing at the mirror-image moment, never did. It
        -- also has to outlive ClearPedTasks: the task teardown can hand the
        -- weapon back into the ped's hands a frame later, which no
        -- single-shot RemoveWeaponFromPed can see coming.
        disarmChute(ped)
        Citizen.CreateThread(function()
            for attempt = 1, 15 do
                Citizen.Wait(100)
                local p = PlayerPedId()
                if not hasChute(p) then break end
                -- Escalate after three polite attempts.
                disarmChute(p, attempt >= 3)
            end
        end)

        BR.Cosmetics.clearTrail()

        -- A short grace absorbs the landing-stumble edge cases (gamerules
        -- reads this alongside its warmup/bus invincibility rule).
        BR.State.dropGraceUntil = GetGameTimer() + BR.Config.Drop.landedGraceMs

        -- LANDED, SAID BY THE ONLY MACHINE THAT CAN SEE IT.
        --
        -- Everything a landed player has -- the inventory bar, the squad panel,
        -- a weapon in the hand, a crate they can open -- has until now waited
        -- for the SERVER to agree, which it does when reportLanded() below
        -- finally gets through. That message goes missing often enough to have
        -- its own retry loop and its own server-side rescue net, and while it
        -- is in flight the player stands in a POI with nothing, sometimes until
        -- the match reaches PLAYING and something else promotes them (#126).
        -- It was read as slowness and answered with speed; it is not slowness,
        -- the systems are simply off.
        --
        -- This is the local half of the answer, and it is narrow on purpose: it
        -- decides only what this client DRAWS and what it will let this player
        -- reach for. Every authoritative question -- did the claim succeed, did
        -- the bullet count, what placement was this -- is still the server's
        -- and still keyed on the state it holds. Reading our own ped is the one
        -- observation a client is always entitled to make.
        BR.State.landed = true
        BR.PushHud(true)

        reportLanded()
        TriggerEvent('br:ui:sendLocal', BR.Nui.TOAST, {
            text = 'Loot up before the storm comes!', tone = 'info', ms = 6000,
        })
        print('[br_core] landed')
    end
end)

-- THE STANDING DISARM. Everything above depends on the landing branch firing,
-- and the landing branch has now been wrong in four different ways across four
-- sessions -- attached canopies, vehicle seats, water, the state machine never
-- arming at all. This is the net under all of it: a player the SERVER calls
-- landed (ALIVE/DBNO), standing on the ground, must not be holding a
-- parachute, whatever route they took to get there.
--
-- HasPedGotWeapon first, so the ordinary case is one cheap call at 10Hz and the
-- expensive height probe only runs for a ped that actually still has a chute.
local sweeps = 0
BR.Loop.register(BR.Loop.TICK, 'skydive.disarm', function()
    if dropping then return end

    local st = BR.State.me.state
    if st ~= BR.PlayerState.ALIVE and st ~= BR.PlayerState.DBNO then return end

    local ped = PlayerPedId()
    if not hasChute(ped) then
        sweeps = 0
        return
    end

    -- WATER IS GROUND. GetEntityHeightAboveGround measures to the SEABED, so
    -- a player swimming in 30m of water reads as 30m up and the height gate
    -- skipped them entirely -- which is the worst possible place to leave
    -- someone armed with a parachute, because the engine's next expected
    -- action is a deploy they cannot perform (user, 2026-08-05).
    local inWater = IsEntityInWater(ped)
    if not inWater then
        -- Never yank one out of the air: if this player is somehow genuinely
        -- falling, the floor above is the system that owns them.
        if IsPedFalling(ped) or GetEntityHeightAboveGround(ped) > 5.0 then
            sweeps = 0
            return
        end
    end

    sweeps = sweeps + 1
    disarmChute(ped, sweeps >= 3)
end)

--- Everything about the drop, in one paste.
RegisterCommand('brdrop', function()
    local ped = PlayerPedId()
    print('=== drop (client) ===')
    print(('  dropping  %s   chuteState %d   hasChute %s   chuteAmmo %d   reserve %s'):format(
        tostring(dropping), GetPedParachuteState(ped),
        tostring(HasPedGotWeapon(ped, CHUTE, false)),
        GetAmmoInPedWeapon(ped, CHUTE),
        tostring(GetPlayerHasReserveParachute(PlayerId()))))
    print(('  AGL %.0fm   onFoot %s   inWater %s   falling %s'):format(
        GetEntityHeightAboveGround(ped), tostring(IsPedOnFoot(ped)),
        tostring(IsEntityInWater(ped)), tostring(IsPedFalling(ped))))
    -- THE THREE ANSWERS THE TRAIL PROMPT IS MADE OF, in the order it asks
    -- them, so "why is there no prompt" is one command rather than a guess.
    -- `armed false` means nothing equipped paints; `squad true` means the
    -- override took it and that is correct; `key (none)` means the binding was
    -- cleared. Each is a different fix and they are indistinguishable in the
    -- air, which is exactly how #131 came back a second time.
    print(('  trail: armed %s   squad %s   on %s   key %s'):format(
        tostring(BR.Cosmetics.trailArmed), tostring(BR.Cosmetics.trailSquad),
        tostring(BR.Cosmetics.trailOn),
        tostring(BR.Native.keyLabelForCommand('brtrail') or '(none)')))
end, false)

-- A match ending mid-air (brforce, mass leave) must not leave the latch set.
RegisterNetEvent(BR.Net.STATE)
AddEventHandler(BR.Net.STATE, function(d)
    if d.state == BR.MatchState.WAITING
       or d.state == BR.MatchState.ENDED
       or d.state == BR.MatchState.CLEANUP then
        dropping = false
        -- THE THIRD ENDING, and it is the one that leaves state behind. A
        -- match killed mid-air (brforce, a mass leave) never reaches the
        -- landing branch, so nothing clears the trail flags -- and the drop
        -- machine can arm itself from the SERVER's opinion alone if the
        -- br:drop:begin handoff is ever missed, which is a path where
        -- applyTrail does not run and therefore does not reset them either.
        -- The two together are a descent prompting for a trail left over from
        -- a match that is already over.
        BR.Cosmetics.clearTrail()
    end

    -- THE LANDED LATCH BELONGS TO ONE DROP, and a new round is a new drop.
    -- Carrying it across would tell the next match's interface that a player
    -- still sitting in the plane had already touched down -- the mirror image
    -- of the bug it exists to fix, and the more embarrassing direction to be
    -- wrong in. WARMUP is where it is armed; leaving it set through the lobby
    -- costs nothing, since nothing reads it there.
    if d.state == BR.MatchState.WARMUP or d.state == BR.MatchState.BUS then
        BR.State.landed = false
    end
end)
