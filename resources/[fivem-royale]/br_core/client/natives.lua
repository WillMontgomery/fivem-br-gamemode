-- Wrappers for natives whose behaviour we do not fully trust yet.
--
-- Every native in here is one of three kinds:
--   (a) verified but easy to misuse, so the correct usage is encoded once;
--   (b) known-broken in some configuration, with the working path chosen here;
--   (c) uncertain on this build, with a documented fallback behind a config flag.
--
-- The point is that when a native turns out to behave differently than expected,
-- exactly one file changes. /brnativecheck exercises these in the lobby and
-- reports what actually works, so the assumptions get tested rather than trusted.

BR = BR or {}
BR.Native = {}

-- The local relationship group holding me + my squadmates. A relationship
-- group hash IS the joaat of its name, so this is constant and safe to read
-- before applyWorldSetup registers the group.
BR.Native.ALLY_GROUP = GetHashKey('BR_ALLY')

-- Implementation switches. Flipped by /brnativecheck findings or by config.
BR.Native.use = {
    spectatorNative = false,  -- false = free-cam + SetFocusEntity (the safer default)
    stormPostFx     = false,  -- off until an effect name is confirmed in-game
}

-- ---------------------------------------------------------------- parachute ---

-- GET_PED_PARACHUTE_STATE return values (verified against citizenfx/natives).
BR.Native.ChuteState = {
    NONE     = -1,  -- no parachute
    ON_BACK  =  0,  -- equipped, not deployed
    OPENING  =  1,
    OPEN     =  2,
    FREEFALL =  3,  -- "falling to doom"
}

-- THE DROP SEQUENCE LIVES IN client/skydive.lua, AND NOWHERE ELSE.
--
-- There used to be a BR.Native.beginSkydive()/endSkydive() pair here, an M3
-- draft that nothing ever called once skydive.lua grew the real (verified,
-- retried) sequence. It was deleted rather than left as a convenience, because
-- of the line it carried: SetPlayerHasReserveParachute(PlayerId()), whose
-- comment promised a disable that was never written. A second give path for
-- the chute is the exact shape of every reserve-parachute bug this project has
-- had, and one that hands out a reserve deliberately would have been the last
-- one anybody looked for. If a helper is wanted again, it calls into
-- skydive.lua -- it does not re-implement it.
--
-- TASK_PARACHUTE's second parameter is VERIFIED UNUSED -- a vestigial jetpack
-- flag that does NOT give the player a chute. Skipping the explicit
-- GiveWeaponToPed is still the single easiest way to break the drop.

-- ------------------------------------------------------------------- aiming ---

--- What is the player standing in front of?
---
--- Built for loot ("which crate am I facing"), but deliberately generic:
--- doors, revives, vehicles and interactables all want the same question
--- answered, and answering it twice in two places is how two systems end up
--- disagreeing about what the player is pointing at.
---
--- FROM THE PED, NOT THE CAMERA (user call, 2026-08-05). The camera version
--- lets you loot something by glancing at it while walking past; the ped's
--- own facing means you have to turn towards the thing, which is what "stand
--- in front of it" means and what the interaction distance is measured from.
--- The ray starts at chest height so it clears the crate's own footprint and
--- angles down slightly, since everything interactable is on the floor.
---
--- The probe is the SYNCHRONOUS variant: it costs more than the asynchronous
--- one, but the asynchronous one answers on a later frame, and a prompt that
--- appears a frame after you turn to something is a prompt that flickers.
---
--- @param maxDist number   metres ahead of the ped
--- @param flags integer|nil shapetest flags; default 16 = objects only
--- @return boolean hit
--- @return table|nil coords  { x, y, z } where it hit
--- @return integer entity    the entity hit, or 0
function BR.Native.aim(maxDist, flags)
    local ped = PlayerPedId()
    local p   = GetEntityCoords(ped)
    local fwd = GetEntityForwardVector(ped)
    local d   = maxDist or 4.0

    -- Chest height forward, ankle height at the far end: a flat ray at chest
    -- height sails over a crate on the floor, and a flat one at ankle height
    -- catches every kerb between here and there.
    local sx, sy, sz = p.x, p.y, p.z + 0.55
    local ex, ey, ez = p.x + fwd.x * d, p.y + fwd.y * d, p.z - 0.35

    local handle = StartExpensiveSynchronousShapeTestLosProbe(
        sx, sy, sz, ex, ey, ez,
        flags or 16,   -- 16 = objects
        ped,           -- ignore ourselves
        4)
    local _, hit, endCoords, _, entity = GetShapeTestResult(handle)

    if hit == 1 or hit == true then
        return true, endCoords, entity or 0
    end
    return false, nil, 0
end

--- The key currently bound to a GTA control, as a letter we can print.
---
--- GET_CONTROL_INSTRUCTIONAL_BUTTON returns a glyph token ("t_E", "b_32")
--- rather than a name, so the readable half is what comes after the prefix.
--- This is how the interaction prompt shows a real key without hardcoding one:
--- rebind INPUT_CONTEXT in GTA's settings and the prompt follows.
---
--- Returns nil when the token is not a plain key (a controller button, say),
--- and the caller falls back to words.
--- @param control integer
--- @return string|nil
function BR.Native.keyLabel(control)
    local ok, raw = pcall(GetControlInstructionalButton, 2, control, true)
    if not ok or type(raw) ~= 'string' then return nil end
    local letter = raw:match('^t_(.+)$')
    if letter and #letter <= 5 then return letter end
    return nil
end

--- What key is bound to one of OUR commands, as a printable label.
---
--- THE PROMPT WAS LYING ABOUT THE KEY. It read GetControlInstructionalButton
--- for control 51 (INPUT_CONTEXT), which is GTA's own context key -- not the
--- `brinteract` binding the player can change in the pause menu. Rebinding
--- interact to anything else left every prompt in the game still saying E
--- (user, 2026-08-08). The INPUT was always right; only the LABEL was wrong,
--- so the key worked and the sign above it did not.
---
--- FiveM encodes a RegisterKeyMapping command as a synthetic control id --
--- `GetHashKey(command) | 0x80000000` -- which is the same number
--- inputForCommand() formats into a `~INPUT_...~` token. Feeding that id back
--- to GetControlInstructionalButton is the natural way to ask "what is this
--- bound to now", and it is the ONE thing here that has not been confirmed on
--- this build: PLAN records that the `~INPUT_<hash>~` TOKEN renders as a hole
--- in native help text, which may or may not say anything about this call.
---
--- So it is written to degrade rather than to be right: try the command's own
--- binding, fall back to the vanilla control's label, and print both side by
--- side in /brpromptcheck so one look in game settles it. A prompt showing the
--- wrong key is bad; a prompt showing no key at all is worse.
--- @param command string   the RegisterKeyMapping command name, no slash
--- @param fallbackControl integer  vanilla control to label if that fails
--- @return string|nil
--- @param command string   the RegisterKeyMapping command name, no slash
--- @param fallbackControl integer|nil
--- @return string|nil label, string|nil which form answered
function BR.Native.keyLabelForCommand(command, fallbackControl)
    -- BOTH FORMS, AND THE PLUS ONE FIRST.
    --
    -- keybinds.lua registers TAP actions as `brdrop` and HOLD actions as
    -- `+brinteract` -- and the keymapping is registered under the name with
    -- the plus, so that is the name whose hash the engine knows. Asking for
    -- `brinteract` asks about a control nobody registered.
    --
    -- Which is exactly what the first version did, and the output said so
    -- without my reading it: `brdrop bound G` (a tap -- correct), while
    -- `brinteract bound E` with the key rebound to R (a hold -- the lookup
    -- missed and the vanilla fallback answered, and the fallback happens to
    -- be E, so the two were indistinguishable). Two columns that agree by
    -- coincidence hid the bug for a round.
    -- OUR OWN BINDING FIRST, when we are the one routing the key.
    --
    -- Everything below asks the ENGINE what a RegisterKeyMapping command is
    -- bound to -- and the engine only knows its own stored mapping, which
    -- nothing can change from script. Once the raw-key layer owns the
    -- routing, the engine's answer is a stale default: interact rebound to R
    -- still reported E, so every world prompt went on saying E (user,
    -- 2026-08-09). BR.Keys is the authority whenever it is running, and
    -- returns nil when it is not, so the engine lookup stays the answer for
    -- exactly the builds that still rely on it.
    local mine, owned
    if BR.Keys and BR.Keys.labelFor then mine, owned = BR.Keys.labelFor(command) end
    if mine then return mine, 'raw' end
    -- OWNED AND EMPTY IS AN ANSWER. If the player has deliberately cleared
    -- this action, it is on no key -- and falling through to the engine would
    -- print the default they just removed, which is the exact failure this
    -- lookup exists to avoid, only quieter.
    if owned then return nil, 'unbound' end

    for _, name in ipairs({ '+' .. command, command }) do
        local id = (GetHashKey(name) | 0x80000000) & 0xFFFFFFFF
        local ok, raw = pcall(GetControlInstructionalButton, 2, id, true)
        if ok and type(raw) == 'string' and raw ~= '' then
            -- Most keys come back as `t_E`. Some -- TAB, arrows -- use a
            -- different prefix or none at all, so a raw short string is
            -- accepted rather than discarded (brinventory read as "(none)"
            -- on TAB purely because of the old strict match).
            local letter = raw:match('^t_(.+)$') or raw
            if #letter > 0 and #letter <= 6 then
                return letter, name
            end
        end
    end
    local fb = fallbackControl and BR.Native.keyLabel(fallbackControl) or nil
    return fb, fb and 'vanilla' or nil
end

--- THE BIG MAP, and it lives here because the RADAR lives here.
---
--- SET_BIGMAP_ACTIVE is not a menu -- it expands the minimap into the
--- full-screen map GTA Online uses, drawn over live gameplay with no frontend
--- and no pause. Which means it is subject to DisplayRadar, and the per-frame
--- rule above turns the radar OFF in the lobby: the map button was calling a
--- native that worked perfectly on a minimap that was not being drawn (user,
--- 2026-08-09: "the map button still does nothing at all"). Owning both in one
--- place is what stops that happening again.
---
--- br_ui asks via `br:map:big`; it owns the page and the key, this owns what
--- the screen actually does.
--- @param on boolean
function BR.Native.setBigmap(on)
    on = on == true
    if BR.Native.bigmap == on then return end
    BR.Native.bigmap = on

    -- The radar has to be up BEFORE the expansion, or there is nothing to
    -- expand -- so grant it here rather than waiting for the frame loop.
    if on then DisplayRadar(true) end
    SetBigmapActive(on, on)

    if on then
        -- A full-screen map with no cursor and no menu needs to say how to
        -- leave, and it has to name the player's OWN key -- the whole point
        -- of the rebinder is that F1 is a default, not a fact.
        --
        -- DRAWN AS A KEY, AND THIS IS THE NOTICE THAT MOST NEEDED IT (#209).
        -- It is STICKY: it stays up for as long as the map is open, which is
        -- exactly the window in which a player might go and rebind the pause
        -- key. A substituted label would sit there naming the old one. The
        -- token names the command and the page redraws the plate on the rebind
        -- push -- see BR.KeyToken in br_lib/shared/protocol.lua.
        local key = (BR.Keys and BR.Keys.labelFor and BR.Keys.labelFor('brpausemenu'))
        BR.Notify(key and ('Press %s to close the map'):format(BR.KeyToken('brpausemenu'))
                       or 'Press the pause key to close the map',
                  'info', { key = 'map.big', sticky = true })
    else
        BR.NotifyClear('map.big')
    end
end

AddEventHandler('br:map:big', function(on) BR.Native.setBigmap(on == true) end)

-- br_ui raises this while it is deliberately holding GTA's own frontend open
-- for the map. The per-frame loop stops suppressing the frontend for exactly
-- as long as it is up -- see the note beside DisableFrontendThisFrame.
AddEventHandler('br:map:frontend', function(on)
    BR.Native.frontendMap = on == true
end)

--- Is this BOOL native true?
---
--- In Lua `0` IS TRUTHY and a FiveM native declared BOOL may answer `1`/`0`
--- rather than `true`/`false`, so a bare `if X() then` is true for a `0` and a
--- bare `not X()` is false for one. This repository has shipped that mistake
--- ten times; client/spawn.lua, client/inventory.lua and br_ui/client/pause.lua
--- all keep a local of exactly this shape and this is br_core/client/natives
--- .lua's.
---
--- IT IS NOT WHAT THE ROCKSTAR EDITOR REPORT WAS, AND THAT IS WORTH
--- RECORDING RATHER THAN IMPLYING.
--- IsPauseMenuActive demonstrably does NOT answer `0` for "no" on this build:
--- the retake below reads it, and a `0` there would have fired
--- SetFrontendActive + a pause-menu toggle on every frame of every session
--- since the day it landed. The game is playable, so the native is answering
--- something falsy. Normalised anyway, because "it answers booleans today" is a
--- fact about this build and not a property of the API -- which is the sentence
--- br_ui/client/pause.lua already carries over its own copy of this.
--- @param v any
--- @return boolean
local function isTrue(v) return v == true or v == 1 end

--- TAKING BACK A FRONTEND WE DID NOT RAISE, AND KNOWING WHEN TO STOP.
--- (owner, 2026-08-29 -- the Rockstar Editor.)
---
--- `asked`  we called SetFrontendActive(false) and are owed a menu going down.
--- `since`  when this frontend first appeared, so the attempt can be bounded.
--- `gaveUp` it outlived the attempt, so it is not ours and we let go of it.
---
--- See the retake itself, inside applyGameRules beside DisableFrontendThisFrame,
--- for what each of the three is for.
local retake = { asked = false, since = 0, gaveUp = false }

--- How long a frontend may resist SetFrontendActive(false) before we accept it
--- is not ours to close.
---
--- FIVE HUNDRED MILLISECONDS BECAUSE THAT IS ALREADY THIS PROJECT'S ANSWER to
--- "how long do you insist a frontend goes down" -- br_ui/client/pause.lua's
--- MAP_SETTLE_MS is the same number for the same question, and the map route
--- reaches it after a single press. A leaked Escape is answered in one frame;
--- anything still up thirty frames later is a different kind of thing.
local RETAKE_MS = 500

-- BR.Native.worldToScreen was deleted with the NUI loot prompt.
--
-- It existed to tell the UI where a crate was on screen, which is the thing
-- DUI removes the need for entirely: the prompt is now a texture drawn at a
-- world position by SetDrawOrigin, so nothing has to project anything. Left
-- as a note because "how do I put a UI element over a world object" is a
-- question that will come up again, and the answer is now client/dui.lua
-- rather than a screen-space round trip.

--- @return integer one of BR.Native.ChuteState
function BR.Native.chuteState()
    return GetPedParachuteState(PlayerPedId())
end

--- Metres above ground, used to decide when to force the glider open.
--- @return number
function BR.Native.heightAboveGround()
    return GetEntityHeightAboveGround(PlayerPedId())
end

function BR.Native.forceOpenChute()
    ForcePedToOpenParachute(PlayerPedId())
end

-- ------------------------------------------------------------------ ragdoll ---

--- Knock the player down for the DBNO transition.
---
--- Ragdoll type 1 (CTaskNMScriptControl) is DOCUMENTED AS NON-FUNCTIONAL in
--- networked environments, so it is never used here. Type 0 (CTaskNMRelax) is the
--- only viable option, and only for the knockdown instant -- sustained ragdoll is
--- too unstable to hold a player in, so the crawl is animation-driven.
--- @param minMs integer
--- @param maxMs integer
function BR.Native.knockdown(minMs, maxMs)
    local ped = PlayerPedId()
    SetPedCanRagdoll(ped, true)
    SetPedToRagdoll(ped, minMs or 1500, maxMs or 2000, 0, false, false, false)
end

-- ------------------------------------------------------------------- health ---

--- Read the local player's health in DISPLAY units (0..100).
--- Engine health runs 100..200 for a living player ped -- the floor IS the
--- conventional 100 (settled by a live death at exactly half bar under the
--- old 0..200 mapping); see BR.ToDisplayHp and the config note.
--- @return number
function BR.Native.displayHealth()
    return BR.ToDisplayHp(GetEntityHealth(PlayerPedId()))
end

--- Apply a server-authoritative health correction, in display units.
--- @param display number
function BR.Native.setDisplayHealth(display)
    SetEntityHealth(PlayerPedId(), BR.ToEngineHp(display))
end

--- Damage or heal. APPLY_DAMAGE_TO_PED heals on negative values, so this single
--- native covers storm damage, medkits and shield potions.
--- @param amount number   positive damages, negative heals
--- @param armourFirst boolean
function BR.Native.applyDamage(amount, armourFirst)
    ApplyDamageToPed(PlayerPedId(), math.floor(amount + 0.5), armourFirst and true or false)
end

--- Normalise the player's health model at match start.
function BR.Native.initHealthModel()
    local ped = PlayerPedId()
    SetEntityMaxHealth(ped, BR.Config.Match.maxHealth)
    SetEntityHealth(ped, BR.Config.Match.maxHealth)
    SetPedArmour(ped, 0)
    SetPlayerMaxArmour(PlayerId(), BR.Config.Match.maxArmour)
    -- Passive regeneration would quietly undo the whole damage model.
    SetPlayerHealthRechargeMultiplier(PlayerId(), 0.0)
end

--- Take the knock off the body: blood, damage decals and dirt.
---
--- ═══ THE REQUEST ═══
---
--- Owner, 2026-08-28: "any time revive is processed, please clean the ped."
---
--- He noticed it stepping out of an ambulance, because #191's delivery hands
--- back FULL health (server/rescue.lua passes `deliverHp`) -- so the one revive
--- in the game that restores a player completely was also the one that left
--- them wearing every hit that put them down. But the request is "any revive"
--- and so is this: it is called from client/dbno.lua's DBNO_SET handler, which
--- is where EVERY BR.Combat.revive lands -- a squad pick-up, /brrevive and the
--- CPR delivery alike -- and from client/spawn.lua's REVIVED handler, which is
--- the other one (BR.Combat.reviveHeld, the death undone at match start).
---
--- ═══ THREE NATIVES, AND THE FOURTH IS DELIBERATELY NOT HERE ═══
---
---   ClearPedBloodDamage    the blood itself: the decals a hit sprays on.
---   ResetPedVisibleDamage  the damage LAYER those decals live in -- bruising,
---                          scarring, the marks a fall leaves. Blood is one
---                          kind of visible damage and not all of it, so
---                          clearing only the first leaves a beaten-looking
---                          player who is no longer bleeding.
---   ClearPedEnvDirt        the road. A downed player CRAWLS (client/dbno.lua),
---                          face down, for up to a minute; the dirt that puts
---                          on them is part of what "clean the ped" means and
---                          nothing else ever takes it off.
---
--- NOT ClearPedWetness. Wetness is a fact about the WORLD, not about the knock:
--- a player revived in the rain or pulled out of the sea is wet for the same
--- reason everyone standing next to them is, and drying them for a second until
--- the weather puts it back would be the one visibly WRONG thing in a function
--- whose whole job is to remove things that should not be there.
---
--- ═══ WHY EACH CALL IS GUARDED ═══
---
--- Not superstition about the native list -- all three are long-standing CFX
--- natives. It is about the CALLER: the DBNO_SET handler runs `pushMine()`
--- AFTER this, and pushMine is what tells the interface the player is back up.
--- A throw here would take that push with it, so a missing native on some
--- future build would cost a revived player their HUD rather than a wash. The
--- guard is three words and it cannot be the thing that fails.
--- @param ped integer|nil  defaults to the local player's ped
function BR.Native.cleanPed(ped)
    ped = ped or PlayerPedId()
    if ClearPedBloodDamage   then ClearPedBloodDamage(ped)   end
    if ResetPedVisibleDamage then ResetPedVisibleDamage(ped) end
    if ClearPedEnvDirt       then ClearPedEnvDirt(ped)       end
end

-- -------------------------------------------------------------------- blips ---

--- Radius blips CANNOT be resized in place -- the blip must be removed and
--- re-added. Callers pass the previous handle back in and get a new one.
--- @param existing integer|nil
--- @param x number
--- @param y number
--- Give a blip a name, which is what the PAUSE MENU legend reads.
---
--- EVERY BLIP WE MAKE NEEDS ONE. A blip with no name inherits whatever GTA
--- calls that sprite by default -- so the courtesy loot markers announced
--- themselves in the pause menu as whatever heist the briefcase sprite was
--- drawn for, and the storm's direction arrow had no entry at all (user,
--- 2026-08-09). Neither is visible on the minimap, which is why both survived
--- this long: the legend is the one place a blip has to explain itself, and it
--- is the one place nobody looks while playing.
---
--- The three calls are a set and the order is fixed; 'STRING' is the text
--- entry that means "the literal I am about to hand you".
--- @param blip integer
--- @param name string
function BR.Native.blipName(blip, name)
    if not blip or not DoesBlipExist(blip) then return end
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentString(name)
    EndTextCommandSetBlipName(blip)
end

--- @param radius number
--- @param colour integer
--- @param alpha integer
--- @param name string|nil  legend entry; these are rebuilt constantly, so it
---                         has to be re-applied on every rebuild
--- @return integer blip
function BR.Native.radiusBlip(existing, x, y, radius, colour, alpha, name)
    if existing and DoesBlipExist(existing) then
        RemoveBlip(existing)
    end
    local blip = AddBlipForRadius(x, y, 0.0, radius)
    SetBlipColour(blip, colour)
    SetBlipAlpha(blip, alpha)
    SetBlipHighDetail(blip, true)
    if name then BR.Native.blipName(blip, name) end
    return blip
end

-- -------------------------------------------------------------- prop scale ---

--- One axis vector of a transform matrix, renormalised to length k.
---
--- Hoisted rather than nested: BR.Native.propScale runs after every rotation
--- write in client/loot.lua's hover, which is per frame per item in range, and
--- a closure built three times a frame per shield is a closure built for
--- nothing.
--- @param v table  a vector3 from GetEntityMatrix
--- @param k number
--- @return number x
--- @return number y
--- @return number z
local function axisAt(v, k)
    local len = math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
    if len < 0.000001 then return 0.0, 0.0, 0.0 end
    local s = k / len
    return v.x * s, v.y * s, v.z * s
end

--- Draw an entity at a multiple of its authored size (#166).
---
--- THERE IS NO SetEntityScale IN GTA V, and that is not a guess -- client/loot's
--- take animation wanted one, could not find one, and settled for a spin. The
--- only lever is the transform matrix: an entity's three axis vectors are unit
--- length, their LENGTH is its scale, so renormalising them to k draws the model
--- at k.
---
--- NORMALISED FIRST, AND THAT IS THE LOAD-BEARING WORD. GetEntityMatrix reads
--- back whatever is there NOW, so multiplying the vectors as they arrive would
--- compound -- a half, then a quarter, then an eighth, once per frame, until the
--- prop disappeared into its own origin. Renormalising makes this IDEMPOTENT,
--- which it has to be: every caller re-applies it after every matrix write.
---
--- WHICH VECTOR IS WHICH DOES NOT MATTER. GetEntityMatrix is declared
--- forward/right/up/position and is widely reported to hand back right/forward
--- in the other order; a UNIFORM scale is invariant under that disagreement,
--- because all three are multiplied by the same k and handed straight back in
--- the order they arrived. SET_ENTITY_MATRIX takes "the same order as with
--- GET_ENTITY_MATRIX", so the round trip cannot be wrong about it either.
---
--- IT SCALES THE RENDER AND NOT A COLLISION BOX. That is free for loose loot
--- (spawned with collision off, and both reach tests measure from the REGISTRY
--- position rather than from the prop) and free for a falling airdrop crate
--- (collision off, position written by arithmetic). It is NOT free for a landed
--- crate, which is a physics object -- a 2x crate still has a 1x hitbox, so it
--- can be walked through at the corners. That is a cosmetic mismatch and it is
--- the price of there being no scale native; it cannot put anything out of
--- reach, because reach is measured from the entry.
---
--- ═══ AND IT MAY SIMPLY NOT RENDER ON THIS BUILD ═══
---
--- Nothing outside a running client can confirm the matrix route works here.
--- #166 shipped the small shield at 0.5 and no playtest has yet reported a
--- shield that looks half-size, so "the scale did nothing" is live and
--- untested. /brpropscale is the ruler: if props do not change size at ANY
--- value, this is not the lever and the answer is a different MODEL.
---
--- GUARDED, so a build without the natives draws the prop at its authored size
--- instead of erroring sixty times a second in the hottest pass in the client.
--- @param obj integer|nil
--- @param k number|nil   nil or 1.0 costs nothing
function BR.Native.propScale(obj, k)
    if not k or k == 1.0 then return end
    if not obj or not DoesEntityExist(obj) then return end
    if not GetEntityMatrix or not SetEntityMatrix then return end

    local a, b, c, at = GetEntityMatrix(obj)
    if not a or not b or not c or not at then return end

    local ax, ay, az = axisAt(a, k)
    local bx, by, bz = axisAt(b, k)
    local cx, cy, cz = axisAt(c, k)
    SetEntityMatrix(obj, ax, ay, az, bx, by, bz, cx, cy, cz, at.x, at.y, at.z)
end

-- --------------------------------------------------------- ped reachability ---

--- GET_SAFE_COORD_FOR_PED flags. Verified against citizenfx/natives'
--- eSafePositionFlags enum rather than copied off a forum post, because the one
--- widely-pasted table on the web ("0, 14, 12, 16, 20, 21, 28, use 0 or 16")
--- is a list of values Rockstar's scripts pass and says nothing about what they
--- mean.
---
---   1  ONLY_PAVEMENT       only polys marked pavement
---   2  NOT_ISOLATED        no polys marked isolated
---   4  NOT_INTERIOR        no polys created from interiors
---   8  NOT_WATER           no polys marked water
---  16  ONLY_NETWORK_SPAWN  only polys marked as a network spawn candidate
---  32  USE_FLOOD_FILL      flood-fill from the start rather than scan a volume
---
--- ═══ 16 IS WHAT WE ASK FOR, AND IT IS THE FIELD-PROVEN VALUE ═══
---
--- The obvious choice is 4|8 -- not an interior, not water -- and it was the
--- first thing written here. It was changed on the strength of the only Cfx.re
--- thread anyone has found in which a rooftop complaint was actually RESOLVED
--- (forum.cfx.re/t/5248185, ambient animals spawning on roofs): the fix was
--- GetSafeCoordForPed(x, y, z, false, 16), and the reporter's first attempt
--- failed because they passed `true` for the fourth argument, not because of the
--- flags. Both halves of that are copied here deliberately.
---
--- 16 IS ROCKSTAR'S OWN CURATED SET. "Network spawn candidate" polygons are the
--- ones their multiplayer spawn code is allowed to put a player on -- so it is
--- narrower than "a ped could stand here", and narrower in exactly the
--- direction that matters: a warehouse roof is not a place Rockstar will spawn
--- an MP player.
---
--- NARROWER ALSO MEANS FALSE NEGATIVES, and the caller is built for them. Remote
--- Blaine County has plenty of legitimate ground with no network-spawn polygon
--- anywhere near it, so this WILL answer "no" about places that are perfectly
--- fine. That is survivable only because every caller treats a "no" as a reason
--- to look for somewhere better and NEVER as a reason to withhold the thing --
--- see client/loot.lua, where a rejected point still gets its prop built. If
--- that ever stops being true, this constant has to go back to 4|8 on the same
--- day.
---
--- ONE LINE TO RETUNE. /brairdrop on the client prints the verdict and the snap
--- distances for the live drop, which is what settles 16 against 4|8 in a single
--- playtest rather than another round of reasoning.
BR.Native.SAFE_COORD_FLAGS = 16

--- Could a ped plausibly be standing at (x, y, z)?
---
--- ═══ WHY THIS EXISTS: AIRDROPS LAND ON ROOFS ═══
---
--- Owner, 2026-08-22: "Somehow these airdrops can happen on top of buildings
--- where peds otherwise cannot access. Any tips on how to address that?"
---
--- THE CAUSE IS NOT MYSTERIOUS AND IT IS NOT THE SITING RULE. The server picks
--- an authored POI, which is a street-level landmark; the CLIENT then resolves
--- the height with GetGroundZFor_3dCoord probing DOWN from hundreds of metres
--- up. That native is documented to return "the highest ground Z directly
--- beneath" the start point -- so over a building it returns the ROOF, every
--- time, exactly as designed. The drop is not being mis-sited; it is being
--- mis-grounded.
---
--- ═══ WHAT THIS CAN AND CANNOT ANSWER ═══
---
--- GetGroundZFor_3dCoord answers HEIGHT, not REACHABILITY, and no native
--- answers reachability directly. The closest thing is the PATHFINDING NAVMESH,
--- which is the graph peds actually walk: GET_SAFE_COORD_FOR_PED is documented
--- entirely in terms of navmesh polygons, so "is there a ped-walkable polygon
--- here" is a question it really does answer.
---
--- THE SNAP DISTANCE IS THE SIGNAL, NOT THE BOOLEAN. The native searches a
--- volume around the point (its own USE_FLOOD_FILL flag is documented as the
--- alternative to "scanning all polygons within the search volume"), so standing
--- on an un-navmeshed roof it happily finds the STREET thirty metres below and
--- answers true. Reading the boolean alone would pass every rooftop in Los
--- Santos. So this compares what came back against what was asked: a coord
--- displaced further than the tolerances is the navmesh saying "not here, but
--- there".
---
--- ═══ THE THREE THINGS IT MISSES, STATED PLAINLY ═══
---
---   * A ROOF THAT HAS NAVMESH PASSES. Plenty do -- roofs with stairs, fire
---     escapes, car-park decks. That is arguably correct (a ped CAN get up
---     there) but it means "no airdrop on any building" is NOT what this
---     delivers, and the owner should expect the occasional accessible roof.
---   * "A PED CAN STAND HERE" IS NOT "A PED CAN GET HERE". The navmesh is
---     polygons, and this asks about ONE polygon; it does not walk the graph
---     back to the street. A walled compound, a fenced yard or an island of
---     navmesh with no connected route all pass. Answering that properly needs
---     the polygon adjacency graph, which is not exposed to script at all.
---   * IT ONLY ANSWERS NEAR THE PLAYER. The navmesh streams like everything
---     else, and the drop is announced while the whole match is kilometres
---     away. So this is deliberately FAIL-OPEN: when the navmesh is not loaded
---     the answer is "yes", because "I cannot see" must never read as "no" --
---     that would refuse every point on the map to every distant client and
---     take the loot system with it.
---   * IT SAYS "NO" ABOUT PLENTY OF GOOD GROUND. See SAFE_COORD_FLAGS: 16 is a
---     curated set, not a walkability test, and rural POIs will fail it. A
---     caller may use a "no" to look for somewhere better; no caller may use it
---     to withhold a crate.
---
--- ═══ WHAT WAS CONSIDERED AND REJECTED, so it is not re-tried ═══
---
---   * A DOWNWARD RAYCAST FROM ABOVE THE POINT. Several published resources
---     carry one and it is the first thing anybody writes. It answers the
---     INVERSE question -- "is this point underneath something" -- and a rooftop
---     passes it trivially, because there is nothing above a roof.
---   * THE SURFACE NORMAL (GET_GROUND_Z_AND_NORMAL_FOR_3D_COORD). It rejects
---     cliffs, not buildings: a flat commercial roof has the same normal as a
---     flat street.
---   * THE COLLISION MATERIAL under the point. RoofTile and RoofFelt exist in
---     the material list and would catch pitched suburban roofs, but Los
---     Santos' flat commercial roofs are concrete and tarmac -- the same
---     materials as the street below them.
---   * THE ENTITY THE SHAPE TEST HIT. Documented as returning only DYNAMIC
---     entities; static map collision, street and roof alike, is not one.
---
--- @param x number
--- @param y number
--- @param z number     the resolved ground height at (x, y)
--- @param hTol number|nil  metres of horizontal snap allowed (default 5)
--- @param vTol number|nil  metres of vertical snap allowed (default 2.5)
--- @return boolean reachable
--- @return string why       for the diagnostic; never shown to a player
function BR.Native.pedReachable(x, y, z, hTol, vTol)
    -- FAIL OPEN ON A MISSING NATIVE. A build or a test rig without it must get
    -- today's behaviour rather than an empty map.
    if not GetSafeCoordForPed then return true, 'no native' end

    hTol = hTol or 5.0
    vTol = vTol or 2.5

    -- IS THE GRAPH EVEN HERE? A box around the point, tight in z so a roof's
    -- box does not simply swallow the street below it and report "loaded"
    -- about geometry we are not asking about.
    if IsNavmeshLoadedInArea then
        local loaded = IsNavmeshLoadedInArea(x - 20.0, y - 20.0, z - vTol,
                                             x + 20.0, y + 20.0, z + vTol)
        -- 0 IS TRUTHY IN LUA AND A NATIVE DECLARED BOOL MAY ANSWER 1. Five
        -- shipped bugs on this project say so.
        if not (loaded ~= nil and loaded ~= false and loaded ~= 0) then
            return true, 'navmesh not loaded'
        end
    end

    local ok, safe = GetSafeCoordForPed(x, y, z, false,
        BR.Native.SAFE_COORD_FLAGS)
    if not (ok ~= nil and ok ~= false and ok ~= 0) then
        return false, 'no safe coord'
    end
    -- A true with nothing in the out-param is not something to reason from.
    if not safe or not safe.x then return true, 'no coord returned' end

    if math.abs((safe.z or z) - z) > vTol then
        return false, ('snapped %.1fm in z'):format((safe.z or z) - z)
    end
    local dx, dy = (safe.x or x) - x, (safe.y or y) - y
    if math.sqrt(dx * dx + dy * dy) > hTol then
        return false, ('snapped %.1fm sideways')
            :format(math.sqrt(dx * dx + dy * dy))
    end
    return true, 'ok'
end

-- ----------------------------------------------------------------- spectate ---

--- The local ped handle for a spectate target, or 0 when they are not streamed.
---
--- THE ONE PLACE THIS LOOKUP HAPPENS, and the one exception tools/verify.sh's
--- scope gate names by hand: "resolving a ped handle for the spectator camera,
--- after the server has supplied coordinates and the client has moved into
--- range". Concentrating it here is what keeps that exception one reviewable
--- function rather than a habit that spreads.
---
--- 0 IS NOT AN ANSWER ABOUT THE MATCH. Under OneSync big mode a player across
--- the map is simply not in this client's scope; they are alive, they are in the
--- round, and the server knows exactly where they are. Anything that reads a 0
--- here as "gone" is deriving game state from scope, which is the whole reason
--- the gate exists.
--- @param targetSrc integer
--- @return integer ped  0 when out of scope
function BR.Native.spectatePed(targetSrc)
    if not targetSrc then return 0 end
    local plyIdx = GetPlayerFromServerId(targetSrc)  -- scope-ok: spectator camera
    if plyIdx == -1 then return 0 end
    local ped = GetPlayerPed(plyIdx)                 -- scope-ok: spectator camera
    return ped or 0
end

--- Attach the spectator camera to a target.
---
--- NETWORK_SET_IN_SPECTATOR_MODE requires the target ped to EXIST LOCALLY. Under
--- OneSync a target across the map is out of scope, so the ped handle is 0 and
--- the native silently does nothing. The natives that would widen entity culling
--- are deprecated with known unfixable issues, so there is no way to force the
--- target to stream in from range.
---
--- The default path is therefore a free camera plus SET_FOCUS_ENTITY / focus
--- position, which forces the world to stream around a remote point and does not
--- fight the sync layer. The engine spectator mode is kept behind a flag for
--- comparison once it has been tested in-game.
---
--- @param targetSrc integer  server id of the target
--- @param pos table          server-supplied { x, y, z } -- the client cannot
---                           discover this itself for an out-of-scope player
--- @return boolean attached
function BR.Native.spectate(targetSrc, pos)
    local ped = BR.Native.spectatePed(targetSrc)

    if BR.Native.use.spectatorNative and ped ~= 0 then
        NetworkSetInSpectatorMode(true, ped)
        return true
    end

    -- FOCUS FOLLOWS THE TARGET, NOT A POSITION, whenever there is a target to
    -- follow (#192, and the same sentence as the camera's).
    --
    -- THE COMMENT ON BR.Native.use SAID "SetFocusEntity" AND THE CODE HAD NEVER
    -- CALLED IT. What was here was SET_FOCUS_POS_AND_VEL alone -- a fixed point,
    -- re-sent at whatever rate the caller managed, so the streaming volume
    -- lagged the subject by up to one push and a sprinting target repeatedly ran
    -- out of their own loaded world. SET_FOCUS_ENTITY moves with them for free.
    --
    -- IT NEEDS A LOCAL HANDLE, WHICH IS WHY THE POSITION PATH IS NOT REMOVED. A
    -- target across the map has no ped here, so the coordinate is the ONLY thing
    -- that can pull the world in around them -- and the moment it does, the ped
    -- appears and this switches to it on the next call. The two are the same
    -- mechanism at two ranges, not a preference and a fallback.
    if ped ~= 0 and SetFocusEntity then
        SetFocusEntity(ped)
        return true
    end

    if pos then
        SetFocusPosAndVel(pos.x, pos.y, pos.z, 0.0, 0.0, 0.0)
        return true
    end
    return false
end

--- Point the MINIMAP at a world position, leaving every ped where it is.
---
--- ═══ WHY THIS AND NOT THE PED ═══
---
--- "the minimap doesn't show the right location - it shows the dead ped's
--- location" -- the owner, and the proposal attached to it was to move the dead
--- ped to the target and make it invisible.
---
--- THE MINIMAP DOES NOT NEED A PED MOVED. `LockMinimapPosition` is the engine's
--- own answer: it detaches the radar from the local player and pins it to a
--- world x/y until it is unlocked. Nothing is teleported, nothing is hidden,
--- nothing occupies space next to a living player, and -- decisively -- it is
--- the SAME code for a dead player watching a squadmate and for an ADMIN who
--- may be alive and mid-match. Moving a ped is only safe for the first of those
--- two, and a mechanism that is safe in one case and catastrophic in the other
--- is a mechanism waiting for somebody to forget which case they are in.
---
--- SetFocusEntity ABOVE IS A DIFFERENT THING and neither replaces this. That
--- one pulls the STREAMING volume to the target so the world loads around them;
--- it has no effect on what the radar draws. They are two halves of "look over
--- there" and the feature needs both.
---
--- THE ANGLE IS LEFT ALONE, deliberately. `LockMinimapAngle` exists and would
--- turn the map to face the camera, but which way the radar points is a player
--- SETTING in GTA's own options (north-up versus heading-up) and overriding it
--- was not asked for. Only the location was reported wrong.
--- @param x number
--- @param y number
function BR.Native.lockMinimap(x, y)
    if LockMinimapPosition == nil or not x or not y then return false end
    LockMinimapPosition(x + 0.0, y + 0.0)
    return true
end

--- Give the radar back to the local player. Safe to call when nothing is locked.
---
--- CALLED FROM EVERY EXIT PATH, including a resource stop. A minimap left
--- pinned to a coordinate is the same class of bug as a script camera left
--- rendering -- it shows the wrong thing forever, with no error and nothing in
--- any log -- and it survives br_core restarting, because the lock lives in the
--- engine rather than in our Lua state.
function BR.Native.unlockMinimap()
    if UnlockMinimapPosition == nil then return false end
    UnlockMinimapPosition()
    return true
end

function BR.Native.stopSpectate()
    if BR.Native.use.spectatorNative and NetworkIsInSpectatorMode() then
        NetworkSetInSpectatorMode(false, PlayerPedId())
    end
    ClearFocus()
end

-- -------------------------------------------------------------- key prompts ---

--- A native GTA help box (top-left). Used for every prompt that references a
--- key: ~INPUT_*~ placeholders render the player's ACTUAL binding, which no
--- NUI toast can do -- hardcoding "SPACE" into toast text lied to anyone who
--- had rebound it.
--- @param text string  may contain ~INPUT_*~ placeholders
function BR.Native.help(text)
    BeginTextCommandDisplayHelp('STRING')
    AddTextComponentSubstringPlayerName(text)
    EndTextCommandDisplayHelp(0, false, true, -1)
end

--- The per-frame variant: call every frame and the box PERSISTS, vanishing
--- the frame the caller stops. This is how a prompt stays up "until they
--- actually do it" -- the one-shot above fades on the engine's own clock,
--- which is why the doors prompt kept disappearing mid-flight. No beep:
--- sounding it every frame would be a siren.
--- @param text string
function BR.Native.helpThisFrame(text)
    BeginTextCommandDisplayHelp('STRING')
    AddTextComponentSubstringPlayerName(text)
    EndTextCommandDisplayHelp(0, false, false, -1)
end

--- The ~INPUT_~ placeholder for one of OUR keymapped commands (keybinds.lua),
--- resolving to whatever the player bound under Settings > Key Bindings >
--- FiveM. The hash convention (joaat of the command name with the high bit
--- set) is the documented RegisterKeyMapping instructional-button contract.
--- @param command string  the command name as registered, e.g. 'brdeploy'
--- @return string
function BR.Native.inputForCommand(command)
    return ('~INPUT_%08X~'):format((GetHashKey(command) | 0x80000000) & 0xFFFFFFFF)
end

-- ------------------------------------------------------------- storm screen ---

local stormFxActive = false

--- @param inside boolean  true when the player is outside the safe circle
function BR.Native.setStormScreen(inside)
    local fx = BR.Config.Storm.fx
    if inside == stormFxActive then return end
    stormFxActive = inside

    if inside then
        if fx.useTimecycle then
            SetTimecycleModifier(fx.timecycle)
            SetTimecycleModifierStrength(fx.timecycleTarget)
        end
        -- postFX names are the most likely thing to differ between builds, so
        -- this stays off until /brfx confirms one. The timecycle plus the NUI
        -- vignette keep the storm fully readable without it.
        if fx.usePostFx and BR.Native.use.stormPostFx then
            AnimpostfxPlay(fx.postFx, 0, true)
        end
    else
        ClearTimecycleModifier()
        if fx.usePostFx and BR.Native.use.stormPostFx then
            AnimpostfxStop(fx.postFx)
        end
    end
end

-- ------------------------------------------------------------ engine teams ---
--
-- WHY THIS EXISTS AT ALL, AND WHY EVERY EARLIER ATTEMPT COULD NOT HAVE WORKED
-- (#115, ninth round).
--
-- The bug: shoot a squadmate and their ped dies on YOUR screen while they walk
-- around alive on their own. The server refuses the damage with CancelEvent(),
-- which suppresses replication and sends NO negative acknowledgement back
-- (citizenfx/fivem#2343, open since Jan 2024, unimplemented) -- so there has
-- never been a message with which to un-kill the corpse. Health writes cannot
-- do it: a clone that has already run its death is a corpse, and putting the
-- number back does not resurrect it.
--
-- Rounds one to eight all tried to author state ON THE VICTIM'S CLONE, from the
-- shooter's machine:
--
--   * SetPedRelationshipGroupHash(matePed, BR_ALLY)  -- measured not to stop a
--     player's bullets, three separate times (2026-08-05).
--   * SetEntityCanBeDamaged(matePed, false)          -- f1ab8fa. DISPROVEN by
--     playtest 2026-08-19: "their ped fell over, then popped back up", which is
--     the damage landing and the repair net catching it, not damage prevented.
--     The second shot killed outright.
--
-- They fail for ONE reason, and it is the same reason each time: a player's ped
-- is owned by that player's machine, control of it can never be taken, and
-- script writes to a clone you do not own are not honoured. The Cfx forum has
-- the same finding from the other side -- "all players were 'PLAYER'
-- relationship whatever you do with them"
-- (forum.cfx.re/t/friendly-fire-how-to-properly-assign-teams/89739).
--
-- WHAT REPLICATES IS WHAT THE OWNER AUTHORS ABOUT ITSELF. FiveM's own sync tree
-- is explicit about which player facts travel: CPlayerGameStateDataNode carries
-- maxHealth, isInvincible, the bullet/fire/explosion/collision/melee proofs,
-- `playerTeam` as a SIX-BIT field, and `isFriendlyFireAllowed` as a bit
-- (citizenfx/fivem, code/components/citizen-server-impl/include/state/
-- SyncTrees_Five.h -- playerTeam at :2961, isFriendlyFireAllowed at :3194).
-- Every one of those is written by the ped's OWNER and read by everybody else.
-- That is the channel this file uses, and it is why warmup peace
-- (SetPlayerInvincible on your own ped) has always worked while eight rounds of
-- writing to somebody else's ped did not.
--
-- AND THE ENGINE REALLY DOES GATE DAMAGE ON IT. GTA V carries a ped config flag
-- named CPED_CONFIG_FLAG_IgnoreNetSessionFriendlyFireCheckForAllowDamage (442),
-- documented as "will ignore the friendly fire setting that was set by
-- NETWORK_SET_FRIENDLY_FIRE_OPTION when checking if Ped can be damaged"
-- (scripthookvdotnet, PedConfigFlagToggles.cs). A flag that exists to SKIP the
-- friendly-fire check inside the can-be-damaged path is proof that the check is
-- in the can-be-damaged path. It is a damage gate, not an AI-targeting one.
--
-- THE ONE PIECE THAT IS INFERRED, STATED PLAINLY: no source found says in
-- words that the check is "same team AND friendly fire off => refuse". It is
-- the reading every part of the record supports -- SET_PLAYER_TEAM is
-- documented as "set player team on deathmatch and last team standing", the
-- forum recipe names NetworkSetFriendlyFireOption(false) as its prerequisite,
-- and THIS repository measured the prediction from the other end: e1f9f98
-- found that with the flag unset and nobody on a team, "FiveM ships with
-- players unable to damage each other", which is exactly what a team check
-- does when every player shares the default team. Only a playtest closes it.
--
-- WHICH IS WHY THE BLAST RADIUS IS BOUNDED RATHER THAN TRUSTED. See the gate
-- rules on BR.Native.teamFor: a solo never joins anyone's team AND never closes
-- the gate, so if the inference is wrong, solo play -- the default mode -- is
-- untouched and only squad matches misbehave, loudly and immediately.

--- The team a player with NO squad carries.
---
--- RESERVED, and never handed to a squad. Every solo sharing team 0 is safe
--- precisely because a solo also leaves the friendly-fire gate OPEN: a
--- solo-versus-solo pair has the gate open on both sides, so the team they
--- share can never block anything. What a solo must never do is share a team
--- with a SQUAD member, whose gate is closed -- and 0 is kept clear of the
--- squad range for exactly that.
---
--- NOT -1, WHICH IS THE OBVIOUS CHOICE AND IS WRONG. `playerTeam` replicates
--- as an UNSIGNED six-bit field, so -1 goes onto the wire as 63 -- which is a
--- real squad team in the range below, and would put every solo in the game on
--- the same side as squad 63 without a single line of it being visible here.
BR.Native.SOLO_TEAM = 0

--- The widest team id that survives the wire. `playerTeam` is six bits, so
--- 0..63 is what actually replicates; anything larger would be truncated into
--- somebody else's team, which is a silent peace treaty in the middle of a
--- fight. BR.Config.Match.maxPlayers is 48, so a real match never approaches
--- the wrap -- it is a guard against a config change, not a live condition.
local MAX_TEAM = 63

--- Which engine team this client is on, and whether the friendly-fire gate
--- should be CLOSED for it.
---
--- PURE, and deliberately split out of applyGameRules. This function decides
--- who in the entire game can shoot whom, and THE OWNER CANNOT PLAYTEST THE
--- IMPORTANT HALF OF IT: three clients against a squad maximum of four puts all
--- three in one squad, so cross-squad damage cannot be produced in game at all
--- (set BR.Config.Match.maxSquadSize = 2 and it can -- 2 + 1 is two squads).
--- Until then this is decided at the desk, by tools/test_client.lua, which is
--- why it takes its world as arguments instead of reading globals.
---
--- @param me table|nil      BR.State.me -- { src, squadId }
--- @param roster table|nil  BR.State.roster mirror, keyed by server id
--- @return integer team     0..63
--- @return boolean shield   true => NetworkSetFriendlyFireOption(false)
function BR.Native.teamFor(me, roster)
    local squad = me and me.squadId
    if type(squad) ~= 'string' then return BR.Native.SOLO_TEAM, false end

    -- 'm<match>sq<index>'. server/party.lua namespaces squad ids by match so
    -- that two concurrent matches cannot conflate anything keyed on squadId.
    -- Only the INDEX is needed here, and it is unique WITHIN a match -- which
    -- is the only place two players can shoot each other anyway, because
    -- separate matches are separate routing buckets and never in each other's
    -- scope.
    local index = tonumber(squad:match('^m%d+sq(%d+)$'))

    -- FAIL OPEN, ALWAYS. An id in a shape this does not recognise means the
    -- squad system moved and this function did not. The safe answer to that is
    -- the one that leaves every gun in the game working: no team, gate open.
    -- Guessing a team instead risks two strangers sharing one, and a pair of
    -- enemies who cannot hurt each other is a worse bug than the one being
    -- fixed -- it is invisible until somebody loses a fight they should have
    -- won.
    if not index then return BR.Native.SOLO_TEAM, false end

    -- 1..63, never 0, so a squad can never collide with the solo team.
    local team = 1 + ((index - 1) % MAX_TEAM)

    -- THE GATE IS ONLY CLOSED WHEN THERE IS SOMEBODY TO PROTECT, and that is
    -- the containment. A squad of one -- a player whose mates have all left,
    -- or a solo queue that still carried a squad id -- keeps the gate OPEN.
    -- They still get their own team, so nobody shares a side with them, and
    -- they are damageable by every route the engine has.
    --
    -- Read off the roster mirror rather than squadmates.lua's `mates`, because
    -- `mates` is a SQUAD_POS push that the server deliberately stops sending to
    -- a squad of one -- silence there is indistinguishable from a dropped
    -- packet, and this must not close the gate on a guess.
    local mine = false
    local myKey = tostring(me.src)
    for src, e in pairs(roster or {}) do
        if tostring(src) ~= myKey and e and e.squadId == squad then
            mine = true
            break
        end
    end

    return team, mine
end

-- SET_PLAYER_TEAM is memoised, not spammed. Writing the team marks the player
-- sync node dirty, and re-sending it sixty times a second would put a node on
-- the wire every frame for a value that changes about twice a match. The
-- refresh is there because a memo is a belief about the engine's state, and the
-- engine resets a good deal on respawn -- two seconds is cheap insurance
-- against a belief that has gone stale without anything noticing.
local lastTeam, lastTeamAt = nil, 0
local TEAM_REFRESH_MS = 2000

--- @param team integer
local function applyTeam(team)
    local now = GetGameTimer()
    if team == lastTeam and (now - lastTeamAt) < TEAM_REFRESH_MS then return end
    lastTeam, lastTeamAt = team, now
    SetPlayerTeam(PlayerId(), team)
end

--- Forget the memo. Used by the test suite and by anything that knows the
--- engine's idea of the team has been reset underneath us.
function BR.Native.forgetTeam()
    lastTeam, lastTeamAt = nil, 0
end

-- --------------------------------------------------------------- game rules ---

-- ===========================================================================
-- TWO KINDS OF RULE LIVE IN THIS FUNCTION, AND ONLY ONE OF THEM IS PER-FRAME.
-- ===========================================================================
--
-- THE MEASUREMENT THAT FORCED THIS. The owner has been hitching in vehicles,
-- reproducible on the empty Cayo warmup pad, and a FiveM script profiler
-- capture found NOTHING: 150 frames, worst frame 29.7ms, all scripting 5.1% of
-- wall time, worst single scripted call 1.7ms. A bisect with `/brloop off`
-- then named `gamerules.apply` as one of the two biggest wins. The LEADING
-- READING of those two together is that the cost is not in the script but in
-- what the script asks the ENGINE to do -- work performed later in the
-- engine's own update, where a script profiler cannot attribute it. That
-- reading is a HYPOTHESIS. It has not been confirmed, and the per-native
-- evidence hunted for below does not confirm it either.
--
-- WHICH IS WHY THIS CHANGE DOES NOT DEPEND ON IT. Every native moved below is
-- one whose value was IDENTICAL on the previous frame; the writes removed are
-- redundant whatever they cost, and the ones kept are kept because their
-- documented contract is per-frame. If the hitch survives this, the hypothesis
-- was wrong and nothing here has to be argued about again -- the frame path is
-- simply honest now. /brhitch is what settles it.
--
-- So the natives were sorted, and the sort is the whole change:
--
--   PER-FRAME BY CONTRACT -- the `*ThisFrame` family (six HideHudComponent,
--   ThefeedHide, the five density multipliers, DisableFrontend) and
--   DisableControlAction. These are DECLARED to last one frame; the engine
--   re-raises the thing they suppress on every frame it wants to draw it, so
--   a cadence here would be a flicker. NOT ONE OF THEM IS TOUCHED.
--
--   LATCHING -- everything else. A wanted-level cap, a population flag, a
--   relationship group, an invincibility bit: set once and the engine holds
--   them. Re-asserting them sixty times a second buys nothing and costs
--   whatever the engine does on each write.
--
-- WHAT REPLACES "EVERY FRAME" FOR THE LATCHING HALF, because "set it at
-- resource start" is NOT the answer and the old comments say why: the ped
-- handle changes on respawn and takes its relationship group with it, and the
-- engine resets a good deal at a match boundary. So the latch re-asserts on
-- ANY OF:
--
--   * the ped handle changing        -- a respawn, which is the case the old
--                                       per-frame comment was actually about
--   * the player state changing      -- warmup -> bus -> alive -> dbno -> dead
--   * the match state changing       -- a match boundary
--   * a value it writes changing     -- the gate, invincibility, visibility
--   * and a one-second heartbeat     -- because a memo is only a belief about
--                                       the engine's state, and something else
--                                       may have written it since
--
-- That is the same shape as applyTeam's memo above, for the same reason, and
-- it means no rule is ever more than a second stale WITHOUT any of the events
-- that could plausibly clear it having happened. Across every event that
-- could, it is not stale at all.
--
-- WHAT IS DELIBERATELY LEFT PER-FRAME EVEN THOUGH IT LATCHES, so the list is
-- reviewable rather than merely short:
--
--   DisplayRadar   -- client/screen.lua ALSO writes it on a scope change, and
--                     the comment on that call says in as many words that this
--                     line must overwrite it "within a millisecond". A memo
--                     here believes its own last write and would stop
--                     correcting somebody else's. It is a HUD flag; it is not
--                     what is costing frames.
--   FreezeEntityPosition (LOBBY) -- client/spawn.lua holds its own temporary
--                     freezes while collision loads, and this call exists to
--                     re-freeze after anything releases one. A memo would
--                     leave a ped free to walk out of a locked shot for up to
--                     a second. It only runs in the LOBBY, which is not where
--                     the hitch is.
--
-- WHAT THIS COSTS ON A SETTLED FRAME, MEASURED RATHER THAN ESTIMATED. Counted
-- by wrapping every native this function writes and running sixty settled
-- frames through it in tools/test_client.lua's harness:
--
--   before   29 engine writes per frame
--   after    14 engine writes per frame, and all fourteen are the per-frame
--            family -- six HideHudComponentThisFrame, ThefeedHideThisFrame,
--            the five density multipliers, DisplayRadar, DisableControlAction
--
-- ── AND /brbench CANNOT SEE THIS, WHICH IS WORTH KNOWING BEFORE YOU TRY ─────
--
-- BR.Loop.bench runs the callback N times back to back inside one frame. Game
-- time does not advance across that loop, so `due` fires on the first
-- iteration and NEVER AGAIN -- /brbench gamerules.apply will report a number
-- near zero and it will be measuring the settled path only, not the cost this
-- change was about. That is the same blind spot every internally-throttled job
-- has in that command.
--
-- /brhitch is the one that answers. It measures the gap between successive
-- FRAME passes -- our callbacks, every other resource, AND the engine's own
-- update -- so engine work this function provokes lands in its histogram
-- whether or not a script profiler could attribute it.
local LATCH_REFRESH_MS = 1000

--- What the latch believes the engine already has. `at` is when the heartbeat
--- last fired; the rest are the values last written.
local latch = {
    at = 0, ped = nil, state = nil, match = nil,
    shield = nil, invincible = nil, visible = nil,
    clockSec = nil, clockHour = nil, clockMin = nil,
}

--- Forget every belief about the engine's rule state, so the next
--- applyGameRules writes all of it again.
---
--- Used by the test suite, and by anything that knows the engine has been
--- reset underneath us. Same contract as BR.Native.forgetTeam above.
function BR.Native.forgetRules()
    latch.at, latch.ped, latch.state, latch.match = 0, nil, nil, nil
    latch.shield, latch.invincible = nil, nil
    latch.visible, latch.clockSec = nil, nil
    latch.clockHour, latch.clockMin = nil, nil
end

-- ═══════════════════════════════════════════════════════════════════════════
-- EMERGENCY DISPATCH -- "For some reason firetrucks are dispatching when I do
-- things?" (owner, 2026-08-23, during a playtest)
-- ═══════════════════════════════════════════════════════════════════════════
--
-- ENABLE_DISPATCH_SERVICE WAS CALLED NOWHERE IN THIS REPOSITORY. Not once, in
-- any resource, on either side of the wire -- so every dispatch service GTA
-- ships with has been ON in every match this gamemode has ever run. The report
-- is not a bug in something we wrote; it is the absence of a line nobody wrote.
--
-- What that costs a battle royale is not subtle. NPC emergency vehicles drive
-- into firefights, block the roads the rotation depends on, and add engine
-- population nobody asked for. Two smaller consequences worth naming because
-- they are the kind that get blamed on the wrong subsystem later:
--
--   * server/vehicles.lua's `refusedPop` counter exists precisely because "a
--     refused MODEL claiming an engine population type" is ambiguous between
--     GTA's own ambient aircraft and a client lying about the field. Dispatch
--     services 2 and 12 are POLICE AND SWAT HELICOPTERS -- refused models, put
--     in the world by the engine -- so they were one known contributor to that
--     ambiguity. Nothing files on it, so this was never a false case; it was
--     noise in the one diagnostic meant to settle the question.
--   * roadkill attribution is NOT affected, and the check was worth doing
--     rather than assuming: server/debug.lua states in as many words that a
--     roadkill by an ambient driver is credited to nobody by design. A police
--     cruiser running somebody over was already nobody's kill.
--
-- ═══ THE ENUM, AND THE TWO PUBLISHED VERSIONS OF IT THAT ARE WRONG ═════════
--
-- `EnableDispatchService(dispatchService, toggle)` takes GTA's DISPATCH_TYPE
-- ordinal, and the ids below are NOT guessable from the names -- there are
-- three mappings in circulation and only one of them is Rockstar's.
--
-- THE SOURCE USED HERE is alloc8or's extraction of the enum from the
-- `CDispatchResponse` parser definition in the game itself:
-- https://alloc8or.re/gta5/doc/enums/DispatchType.txt
-- Sixteen members, no explicit values, so implicit 0..15 with DT_Invalid at 0.
-- Fetched and read directly rather than taken second-hand.
--
-- WHY THAT SOURCE AND NOT THE OBVIOUS ONE. The obvious one is the FiveM native
-- reference (citizenfx/natives, MISC/EnableDispatchService.md), and its list is
-- WRONG FROM 12 UP: it skips 12 entirely and then gives
-- `DT_SwatHelicopter = 13, DT_PoliceBoat = 14, DT_ArmyVehicle = 15,
--  DT_BikerBackup = 15` -- everything above 11 shifted by one, and 15 issued
-- twice. Checked against the raw markdown, not inferred. A Cfx maintainer
-- pointed at the alloc8or file for exactly this reason when a contributor
-- proposed yet another list (citizenfx/natives PR #473, closed unmerged); the
-- list in that PR is the one from the most-copied cfx.re release thread, which
-- has FIRE_DEPARTMENT at 4 -- so anyone following the popular thread and
-- calling `EnableDispatchService(4, false)` for "fire" is turning off SWAT.
--
-- ═══ AND THIS IS WHY THE LOOP DISABLES A RANGE RATHER THAN A NAME ═══
--
-- The three mappings disagree about which NAME each id carries; all three agree
-- the ids are 1..15. Since every one of them is turned off, the naming dispute
-- cannot cost this gamemode anything -- the table below is DOCUMENTATION, and
-- the contiguous range is what does the work. That is deliberate: it is the
-- arrangement in which being wrong about a name is free, and it is why nothing
-- in the write path looks a service up by name.
BR.Native.DispatchService = {
    POLICE_AUTOMOBILE                  = 1,
    POLICE_HELICOPTER                  = 2,
    FIRE_DEPARTMENT                    = 3,
    SWAT_AUTOMOBILE                    = 4,
    AMBULANCE_DEPARTMENT               = 5,
    POLICE_RIDERS                      = 6,
    POLICE_VEHICLE_REQUEST             = 7,
    POLICE_ROAD_BLOCK                  = 8,
    POLICE_AUTOMOBILE_WAIT_PULLED_OVER = 9,
    POLICE_AUTOMOBILE_WAIT_CRUISING    = 10,
    GANGS                              = 11,
    SWAT_HELICOPTER                    = 12,
    POLICE_BOAT                        = 13,
    ARMY_VEHICLE                       = 14,
    BIKER_BACKUP                       = 15,
}

--- Every dispatch service, and the whole set is turned off.
---
--- THE WHOLE SET RATHER THAN JUST THE FIRE DEPARTMENT, and that is a decision
--- rather than a shrug. The report names fire trucks because fire trucks are
--- what the owner saw; every other entry on that list is the same category of
--- thing -- an AI response to a crime, a fire or a body, in a game mode that is
--- made entirely of crimes, fires and bodies. Disabling three and leaving
--- twelve would guarantee a second report and a second round of this.
---
--- The ONE that deserved a second look before going on the list is 5,
--- AMBULANCE_DEPARTMENT -- see the note on #191 below. It goes on the list.
BR.Native.DISPATCH_OFF = {
    1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
}

-- ═══ #191's CPR AMBULANCE IS NOT AFFECTED BY SERVICE 5, AND HERE IS WHY ═════
--
-- WRITTEN DOWN RATHER THAN LEFT TO BE REDISCOVERED. "We turned off the
-- ambulance dispatch service and then the CPR kit stopped spawning its
-- ambulance" is exactly the shape of thing that surfaces three weeks after the
-- commit that caused it, by which point nobody is looking at this file.
--
-- A DISPATCH SERVICE GOVERNS THE ENGINE'S OWN AI DISPATCH AND NOTHING ELSE. It
-- decides whether the game, unprompted, sends an emergency unit at a crime, a
-- fire or a body. It is not a model ban, not a spawn ban, and not a filter on
-- anything a script asks for by name -- a script that calls CreateVehicle with
-- the `ambulance` model and puts a ped in the driving seat gets an ambulance
-- with a driver, whatever this flag says.
--
-- AND #191'S AMBULANCE IS EXACTLY THAT, CHECKED IN THE TREE RATHER THAN
-- ASSUMED. The feature is not built yet -- `cprkit` is a named seam in
-- config/airdrop.lua's healing pool that currently resolves to nothing -- but
-- the shape it must take is already written into four files that would have to
-- change if it did not:
--
--   server/fuel.lua      "The CPR ambulance is created client-side and
--                        non-networked (the same `isNetwork = false` that keeps
--                        the Battle Bus out of server/vehicles.lua's detector)"
--   server/vehicles.lua  "The CPR ambulance is meant to be local and
--                        non-networked, so it should reach none of this"
--   client/fuel.lua      names it alongside the Battle Bus as a vehicle with no
--                        network id
--   config/vehicles.lua  "#191's ambulance goes in here (or in the model
--                        table); nowhere else" -- i.e. its exemption is from
--                        the REFUSAL ruling, which is a different mechanism
--                        again and is untouched here.
--
-- So it is a gamemode-created entity from end to end. Disabling service 5 stops
-- the engine sending an ambulance to a corpse; it does not stop us from making
-- one. If #191 ever changes its mind and asks the ENGINE for a medic -- a
-- dispatch request rather than a CreateVehicle -- this is the line it has to
-- come back and argue with. There IS such a route, and naming it is the point:
-- CREATE_INCIDENT takes a `dispatchService` argument and is the script-side
-- door INTO this system, so an incident raised that way IS governed by the
-- flags above. A CreateVehicle is not.
--
-- ═══ IS DISPATCH ENOUGH ON ITS OWN? FOR THE REPORT, YES. NOT FOR EVERYTHING ═
--
-- THE WORRY, AND IT IS A REASONABLE ONE: fire trucks answer FIRES and
-- EXPLOSIONS rather than wanted levels, and this gamemode makes explosions
-- constantly -- grenades, RPGs, the railgun, and vehicles that #213 deliberately
-- made break faster with #194 about to credit the kills. If fire response ran on
-- some second system, a wanted-level fix would have looked like it worked and
-- then failed under fire.
--
-- IT DOES NOT. Service 3 IS the fire-response control, and that is a maintainer
-- statement rather than an inference: a Cfx developer describes this native as
-- governing "emergency response AI (e.g. spawning fire trucks for fires,
-- spawning police when there's a wanted level)" -- the two clauses being
-- separate is the whole answer. The FiveM reference makes the same split from
-- the other side, illustrating the native with "a fire in the street (type 3 -
-- DT_FireDepartment)". The entire FIRE namespace was enumerated looking for a
-- second control and there is none: every native in it (StartScriptFire,
-- StopFireInRange, SetFireSpreadRate, GetNumberOfFiresInRange and the rest) is
-- fire PHYSICS. Nothing else decides who comes to put it out.
--
-- THE SECOND LEVER IS REAL BUT IT IS ABOUT A DIFFERENT SYMPTOM, and it is named
-- here so that "we disabled dispatch and there are still fire trucks" has an
-- answer waiting rather than another round of research:
--
--   REMOVE_VEHICLES_FROM_GENERATORS_IN_AREA (0x46A1E1A299EC4BBA, VEHICLE), over
--   a box around each fire station. Station-parked fire trucks are placed by
--   VEHICLE GENERATORS, which are static world population and not dispatch at
--   all -- as a cfx.re thread on precisely this puts it, disabling emergency
--   services "does not stop them from spawning in the station it only stops
--   them from responding". qb-smallresources pairs the two for this reason,
--   calling the generator native over eight hardcoded ±300m boxes.
--
-- AND IT IS DELIBERATELY NOT PULLED, which is a design call and not an
-- oversight. A fire truck standing in a fire station is a PARKED VEHICLE, and
-- parked vehicles are this gamemode's rotation supply: BR.Config.Ambient.parked
-- runs at 1.0 -- full density, alone among the multipliers -- under a comment
-- saying parked cars are where off-road vehicles actually come from. Clearing
-- the stations would delete drivable vehicles from the middle of the map to fix
-- a complaint nobody has made. The owner reported trucks DISPATCHING, which is
-- the half turned off above.
--
-- So: if a later report is "there is a fire truck parked at the station",
-- that is this paragraph and not a regression in the one above. The station
-- coordinates would belong in br_lib/config/map.lua, beside the POIs, and
-- nowhere else.

--- Strip the vanilla systems that make no sense in a battle royale. Called from
--- the frame loop because the `*ThisFrame` half genuinely resets every tick;
--- see the long note above for what the other half does instead.
function BR.Native.applyGameRules()
    local pid = PlayerId()
    local ped = PlayerPedId()
    local st  = BR.State.me.state
    local mst = BR.State.match.state
    local now = GetGameTimer()

    -- The five triggers, read BEFORE anything updates them.
    local due = (ped ~= latch.ped)
             or (st  ~= latch.state)
             or (mst ~= latch.match)
             or ((now - latch.at) >= LATCH_REFRESH_MS)
    if due then
        latch.at, latch.ped, latch.state, latch.match = now, ped, st, mst
    end

    -- ═══════════════════════════════════════════════════════════════════════
    -- THE WANTED LEVEL, WHICH IS THE ONE THIS INVESTIGATION WAS ABOUT
    -- ═══════════════════════════════════════════════════════════════════════
    --
    -- SET_PLAYER_WANTED_LEVEL_NOW is not a setter. Its documentation is one
    -- sentence -- "Forces any pending wanted level to be applied to the
    -- specified player immediately" -- so it is a COMMAND, and this was
    -- issuing it sixty times a second to reach a number the player was
    -- already at.
    --
    -- WHAT IS NOT KNOWN, STATED PLAINLY, BECAUSE THE NEXT PERSON WILL WANT TO
    -- KNOW WHETHER THIS FIXED THE HITCH. It is TEMPTING to write that this
    -- forces a dispatch/police recalculation and that the police system is
    -- vehicle-coupled, which would explain the symptom exactly. There is NO
    -- EVIDENCE FOR THAT. A search of the native docs, the nativedb comments,
    -- decompiled R* scripts and the cfx.re forums turns up no benchmark, no
    -- bug report and no maintainer statement that this native is expensive --
    -- the strongest thing that exists is one forum opinion calling a
    -- wanted-clearing Wait(0) loop "hella inefficient", which is about the
    -- loop and not about the native.
    --
    -- What IS verifiable is that wanted level is OneSync-replicated state:
    -- CPlayerWantedAndLOSDataNode carries wantedLevel, a pendingWantedLevel
    -- bit, isWanted, the wanted position and the pursuit start time. So the
    -- pending-versus-applied distinction is real at the network layer. Whether
    -- a redundant call with the same value dirties that node is UNKNOWN;
    -- engines normally dirty on change.
    --
    -- So this change is justified as REMOVING WORK THAT BUYS NOTHING, which is
    -- true whatever the work costs -- not as a diagnosis. /brhitch is what
    -- settles whether it was the hitch.
    --
    -- THE RULE IS NOT DROPPED, IT IS CLOSED-LOOP INSTEAD OF OPEN-LOOP. The
    -- rule is "the player is never wanted". The old code asserted that by
    -- writing zero every frame without ever asking. This ASKS -- a plain int
    -- read off CWanted -- and writes only when the answer is not already zero.
    --
    -- So the rule now holds MORE tightly than a cadence would: anything that
    -- raises the wanted level is cleared on the very next frame, not at the
    -- next heartbeat. In the steady state the player is at zero and this costs
    -- one comparison.
    --
    -- AND SET_MAX_WANTED_LEVEL(0) IS NOT TRUSTED AS THE ONLY MECHANISM, which
    -- is why the read above is there rather than a bare cap. It caps stars and
    -- is reported not to clear a level already granted; and the community
    -- record on it is CONTRADICTORY -- one cfx.re thread has it permanently
    -- disabling the wanted level, an older one has an author reporting "just
    -- tried it out, it doesn't work". Its own doc body is empty. So it is kept,
    -- because a cap that works costs nothing and stops the problem at source,
    -- and the closed loop above covers the build where it does not.
    --
    -- The heartbeat is ORed into the flush for the same reason pointed the
    -- other way: on a build where the READ is unavailable or lies, the old
    -- unconditional flush still happens, once a second instead of sixty times.
    --
    -- `> 0` and not a BOOL test: GET_PLAYER_WANTED_LEVEL returns the number of
    -- stars, an int. There is nothing here for the 1-versus-true confusion to
    -- bite, and tonumber() keeps it that way if a build ever answers a string.
    if due then
        SetMaxWantedLevel(0)
        SetCreateRandomCops(false)
        SetCreateRandomCopsNotOnScenarios(false)
        SetCreateRandomCopsOnScenarios(false)

        -- EMERGENCY DISPATCH, ON THE SAME LATCH AS THE FOUR ABOVE.
        --
        -- LATCHING, NOT PER-FRAME, and it belongs in exactly this block: it is
        -- an engine setting the game holds, in the same family as the wanted
        -- cap and the cop flags, and 56c0ba7 took that whole family off the
        -- frame path. Fifteen writes a frame is what this would have cost as a
        -- per-frame call -- more than the entire settled frame path costs now.
        --
        -- RE-ASSERTED ON EVERY TRIGGER THE NEIGHBOURS HAVE, which is what makes
        -- the latch safe here rather than merely cheap: a ped handle change
        -- (respawn), a player state change, a match state change and a
        -- one-second heartbeat.
        --
        -- AND THE EVIDENCE SAYS IT WOULD PROBABLY LATCH WITHOUT ANY OF THAT,
        -- which is worth writing down because the published scripts suggest
        -- otherwise. Plenty of them wrap this native in a `while true do
        -- Wait(0)` loop -- and the search for a REASON came back empty: no
        -- documented reset, no cfx.re report of it decaying on respawn, ped
        -- change or session change, and the one bug thread that claimed it
        -- ("Issue with EnableDispatchService native") was answered by a Cfx dev
        -- as a confusion with the police scanner. qb-smallresources, the most
        -- widely deployed codebase that touches it, calls it ONCE under a
        -- comment reading "all these should only need to be called once".
        --
        -- So the cadence here is INSURANCE, not a known requirement, and it is
        -- priced accordingly: fifteen writes at most once a second, versus the
        -- nine hundred a second a `while true` loop would have cost -- which on
        -- a frame path 56c0ba7 just cut from 29 engine writes to 14 would have
        -- been the single most expensive thing in it by two orders of
        -- magnitude. Worst case is a second of staleness on a flag nothing has
        -- ever been observed to clear.
        for i = 1, #BR.Native.DISPATCH_OFF do
            EnableDispatchService(BR.Native.DISPATCH_OFF[i], false)
        end
    end

    if due or (tonumber(GetPlayerWantedLevel(pid)) or 0) > 0 then
        SetPlayerWantedLevel(pid, 0, false)
        SetPlayerWantedLevelNow(pid, false)
    end

    -- PvP, with two carve-outs, both enforced on the SHOOTER's client where
    -- GTA computes bullet damage:
    --
    --   Squadmates: my squad has an engine TEAM, and while I have a live
    --   squadmate the engine's friendly-fire gate is closed. Same team plus a
    --   closed gate is the engine refusing to compute the hit at all; a
    --   different team is damage as normal. See the long note above
    --   BR.Native.teamFor for why this is the only channel that can work and
    --   what part of it is still inferred.
    --
    --   The BR_ALLY relationship group is kept, and is NOT what stops the
    --   bullet -- this comment used to claim it was, and it was measured
    --   otherwise three times over (2026-08-05). It governs AI aggression and
    --   melee, which is worth having, and nothing more.
    --
    --   Warmup: my own ped is simply invincible. Everyone's client does the
    --   same, so nobody can be hurt by anything until the bus.
    --
    -- Per-frame like the rest: the ped handle changes on respawn, and the
    -- group assignment dies with the old handle.
    --
    -- =====================================================================
    -- NetworkSetFriendlyFireOption IS NOT A CONSTANT ANY MORE, AND IT IS
    -- STILL NOT SAFE TO FLIP GLOBALLY. READ BOTH HALVES.
    -- =====================================================================
    --
    -- It was set true by e1f9f98, deliberately, as the fix for a MEASURED
    -- fault: "FiveM ships with players unable to damage each other, which
    -- presented as peace mode on the first real fight". At that point no
    -- player was ever put on a team, so every player was the engine's idea of
    -- friendly to every other and this one flag gated ALL PvP. Twice since,
    -- #115 was diagnosed as "the polarity is backwards"; twice, flipping it on
    -- its own would have turned off every fight in the game.
    --
    -- What changed is the OTHER half. The flag only ever meant "may friendlies
    -- damage each other", and with teams assigned there are finally friendlies
    -- for it to be about. So it closes for exactly the players who have a
    -- squadmate to protect, and stays open for everybody else:
    --
    --   solo                  -> team 0, gate OPEN. Unchanged from e1f9f98 in
    --                            every respect, which is what keeps the
    --                            DEFAULT MODE out of the blast radius if the
    --                            team inference turns out to be wrong.
    --   squad of one          -> own team, gate OPEN. Nobody to protect.
    --   squad of two or more  -> squad team, gate CLOSED.
    --
    -- A pair is only ever blocked when BOTH sides are on the same team, so
    -- cross-squad and squad-versus-solo damage never depend on the gate at
    -- all. BR.Config.Match.engineTeams = false reverts the whole thing to the
    -- e1f9f98 behaviour in one line, without a code change, because this has
    -- had eight rounds and the ninth should be cheap to undo.
    local mcfg = BR.Config and BR.Config.Match
    local team, shield = BR.Native.SOLO_TEAM, false
    if not mcfg or mcfg.engineTeams ~= false then
        team, shield = BR.Native.teamFor(BR.State.me, BR.State.roster)
        applyTeam(team)
    end

    -- `not shield` rather than a number: these are BOOL natives and this
    -- codebase has been bitten four times by 1/0 versus true/false. The value
    -- handed to the engine is a real Lua boolean, and test_client.lua asserts
    -- its TYPE as well as its value.
    --
    -- ON CHANGE, NOT ON A CADENCE. The gate is a latching engine option and
    -- `shield` is a decision about the roster, not about this frame -- it
    -- changes about twice a match, when a squadmate joins or dies. Writing it
    -- the instant it differs is strictly tighter than a heartbeat, and `due`
    -- carries the respawn/boundary/heartbeat cases on top.
    if due or shield ~= latch.shield then
        latch.shield = shield
        NetworkSetFriendlyFireOption(not shield)
    end

    -- THE RELATIONSHIP GROUP DIES WITH THE PED HANDLE, which is precisely why
    -- the old comment said "per-frame like the rest" -- and a respawn is the
    -- only thing that changes the handle. `due` is true on exactly that frame,
    -- so the group is re-applied on the first frame of the new ped rather than
    -- on all sixty of every second the old one was alive.
    if due then
        SetPedRelationshipGroupHash(ped, BR.Native.ALLY_GROUP)
        SetCanAttackFriendly(ped, false, false)
    end

    -- Peace while nobody can meaningfully fight back: the warmup pad, the
    -- bus ride, THE WHOLE DESCENT, and half a second after touchdown. The
    -- descent matters most -- a chute that fails to open must cost the drop,
    -- never the life; the invincibility holds until the landing grace runs
    -- out no matter how hard the ground arrives.
    --
    -- ...AND WHILE DOWNED, WHICH IS A DIFFERENT ARGUMENT ENTIRELY (M7). A
    -- downed player's health is the bleed timer on the server, not the number
    -- on this ped -- so there is nothing here left for the engine to take, and
    -- everything it could still do is wrong. Enemy fire is already stopped
    -- from replicating by the server's CancelEvent, so the only thing this
    -- blocks is THIS client's own engine killing its own ped down a path we
    -- have never taken over: fire, a fall, drowning, a car. Without it,
    -- gamerules.death reports a death the server then has to refuse, and the
    -- player flickers between down and dead.
    --
    -- The honest cost, stated rather than hidden: a downed player cannot burn
    -- to death. They can be finished with a gun, which is the interaction that
    -- matters, and the storm still runs their clock out.
    --
    -- ...AND ONCE THE MATCH IS DECIDED, WHICH IS NEW AND IS NOT COSMETIC.
    --
    -- The roster sweep to LOBBY used to fire the instant a match ended, and
    -- LOBBY is on this list -- so the winner became invincible as a side effect
    -- of being frozen. That sweep now waits for the player's screen to go black
    -- (#124), which is the right order for everything else and leaves a live,
    -- mortal ped standing in a finished match for a few seconds. A winner who
    -- burns to death under their own VICTORY ROYALE would be a spectacular way
    -- to reintroduce the bug from the other end. Nothing may kill you after the
    -- result is in; the placement is already awarded and published.
    -- ═══ KEYED ON THE ANSWER, AND IT HAS TO BE ═══
    --
    -- THE LAST TERM IS A CLOCK. `dropGraceUntil` makes this expression flip
    -- from true to false at a moment when the player state, the match state
    -- and the ped handle have all stayed exactly the same -- so `due` is FALSE
    -- on the frame the grace runs out, and keying the write on `due` alone
    -- would leave a landed player invincible until the next heartbeat.
    --
    -- Comparing the ANSWER catches it on the exact frame, which is the same
    -- frame the old unconditional write caught it on. The expression itself is
    -- pure Lua over values already in hand -- no native -- so evaluating it
    -- every frame and writing only on a change costs a comparison.
    local wantInvincible =
        st == BR.PlayerState.WARMUP
        or st == BR.PlayerState.BUS
        or st == BR.PlayerState.LOBBY
        or st == BR.PlayerState.FREEFALL
        or st == BR.PlayerState.GLIDE
        or st == BR.PlayerState.DBNO
        or mst == BR.MatchState.ENDED
        or mst == BR.MatchState.CLEANUP
        or now < (BR.State.dropGraceUntil or 0)

    if due or wantInvincible ~= latch.invincible then
        latch.invincible = wantInvincible
        SetPlayerInvincible(pid, wantInvincible)
    end

    -- YOUR PED IS THE LOBBY NOW, so it is no longer hidden there.
    --
    -- This used to read `st ~= LOBBY and st ~= BUS`, from when the lobby was
    -- an empty vista and any visible ped was something that had gone wrong.
    -- The shot is a character portrait now (BR.LobbyCam) and the ped IS the
    -- subject -- hiding it would leave the camera pointed at scenery.
    --
    -- Hiding OTHER players from you is NOT done from this side. It was tried
    -- twice -- the owner hiding itself over the network, then the owner
    -- calling _NETWORK_SET_ENTITY_INVISIBLE_TO_NETWORK on itself -- and both
    -- failed, the second because that native is widely reported not to work
    -- under OneSync. It now happens entirely on the OBSERVER's side, every
    -- frame, with SET_ENTITY_LOCALLY_INVISIBLE; see the long note in
    -- client/squadmates.lua for why that is the only one that cannot lose.
    --
    -- ═══════════════════════════════════════════════════════════════════════
    -- ...AND A BLED-OUT PLAYER'S BODY IS THE SECOND THING THIS HIDES
    -- ═══════════════════════════════════════════════════════════════════════
    --
    -- Owner, 2026-08-31: "After a player has bled out, their ped should become
    -- invisible. Only the 3dmarker (type 24) and DUI should be shown at their
    -- position. I like the blip though - let's keep that."
    --
    -- THE NETWORKED PROPERTY IS THE RIGHT TOOL HERE AND THE WRONG ONE IN THE
    -- LOBBY, and the difference is who is supposed to see the ped. The lobby
    -- failure was that SetEntityVisible hides you FROM YOURSELF as well, and the
    -- lobby is a character shot -- so the one machine that had to keep seeing
    -- the ped was the one that could not. An OUT player has no such stake: they
    -- are watching a squadmate through a script camera, their own body is a
    -- corpse behind them, and "invisible to everyone" is the whole request. The
    -- property replicating is exactly what makes it reach the enemy standing
    -- over the body, which no per-frame local hide on THIS machine could do.
    --
    -- SO IT IS ONE WRITE ON ONE CLIENT AND NOT A LOOP ON EVERY CLIENT. The
    -- observer-side alternative would need each machine to enumerate players and
    -- consult a roster mirror for their state, sixty times a second, all match,
    -- to reproduce a fact the owning client already knows. The BUS rider beside
    -- it on this line has been hidden from the whole server this way since M2.
    --
    -- NOTHING CAN LEAVE A PLAYER INVISIBLE. `latch.visible` is compared every
    -- frame and `due` re-asserts on the heartbeat, so the write back to TRUE is
    -- made by the same line the moment the state stops being OUT -- a revive
    -- arrival, the trip home to the lobby, a match reset. The three resurrection
    -- paths (client/spawn.lua, rescue.lua, skydive.lua) each assert it too, so
    -- the exit is covered four ways and none of them is a teardown somebody has
    -- to remember to write.
    --
    -- ═══ IT DOES NOT BREAK client/spectate.lua's "CORPSE WHERE THEY FELL" ═══
    --
    -- That note says a spectator's ped "is a corpse where they fell,
    -- deliberately (see BR.Native.lockMinimap for why it is not moved and must
    -- not be)", and lockMinimap's own header records the rejected proposal it
    -- came from: "to move the dead ped to the target and make it invisible".
    -- Both halves were declined together, but only one of them carries the
    -- danger, and lockMinimap says which -- moving a ped "is only safe for [a
    -- dead player watching a squadmate] and catastrophic in the [ADMIN who may
    -- be alive and mid-match]" case. The hazard is DISPLACEMENT. Concealment was
    -- refused as unnecessary, because the minimap did not need it.
    --
    -- client/dbno.lua's corpse nudge already drew this same distinction for
    -- itself -- "spectate.lua's warning about moving a dead ped ... is about
    -- DISPLACEMENT, and there is none here" -- and there is none here either.
    -- Nothing is teleported and nothing occupies space next to a living player.
    --
    -- AND THE ADMIN IS UNTOUCHED BY CONSTRUCTION, which is the part that
    -- matters. This is keyed on MY OWN PLAYER STATE being OUT, not on whether a
    -- spectate session is running. An admin ghosting a match is ALIVE, so
    -- `wantVisible` stays true for them and this line never fires -- the exact
    -- case the whole warning exists for is the case the test cannot reach.
    --
    -- Written on change, and `due` already covers the two things that could
    -- undo it underneath us: the handle changing (a new ped is visible by
    -- default, and the write that matters is the one hiding a BUS rider) and
    -- the state changing, which is what this value is derived from anyway.
    local wantVisible = st ~= BR.PlayerState.BUS
                        and st ~= BR.PlayerState.OUT
    if due or wantVisible ~= latch.visible then
        latch.visible = wantVisible
        SetEntityVisible(ped, wantVisible, false)
    end

    -- ...UNLESS THE ENTRANCE IS WALKING IT IN (owner, 2026-08-29). The lobby
    -- ped now arrives on foot along an authored path, and this line is the one
    -- thing in the project that can stop it: a per-frame freeze against a ped
    -- task is not a fight the task wins, it is a ped standing still with a walk
    -- animation nobody can see. client/lobbyped.lua owns that window and closes
    -- it the moment the ped reaches the mark -- on every ending, including
    -- abandonment -- so a walk that is dropped halfway is a ped this rule
    -- freezes again on the very next frame.
    if st == BR.PlayerState.LOBBY
       and not (BR.LobbyPed and BR.LobbyPed.walking()) then
        -- The lobby freeze: the ped must not walk, fall or ragdoll out of a
        -- locked shot. It deliberately never RELEASES here -- spawn placement
        -- holds its own temporary freezes while collision loads, and stomping
        -- those drops players through the world.
        FreezeEntityPosition(ped, true)
    end

    -- The bus rider stays hidden, and is NOT frozen: it rides attached inside
    -- the plane, and the old per-frame BUS freeze was still re-freezing for
    -- the ~250ms after a jump while the roster still said BUS -- fighting
    -- TaskParachute in exactly the frames it needed the ped falling. That
    -- race was the dead SPACE key.

    -- The radar follows MY state, owned here like every other per-frame
    -- rule: hidden in the LOBBY (it used to poke out under the menu after a
    -- match), hidden ABOARD THE BUS (the ride is a cutscene; the map lives
    -- on the pause screen -- user call, 2026-08-04), shown for every other
    -- in-match state. This replaces the point calls spawn.lua made at
    -- ENDED/WAITING, which said the right thing for match participants and
    -- the wrong thing for everyone idling in the lobby.
    -- ...and never over a scope. This runs every FRAME, so it is the call that
    -- actually decides: screen.lua sets DisplayRadar when the scope state
    -- changes, and without this line that setting would be overwritten here
    -- within a millisecond and the minimap would sit on the scaleform.
    -- ...and never DURING A TRIP. The player's state flips to WARMUP the
    -- moment the server says so, which is the moment the transition STARTS --
    -- so keying the radar on state alone popped the minimap up at the top of
    -- the fade and left it sitting on a black screen for the whole teleport
    -- (user, 2026-08-09). The trip owns the screen until it says otherwise.
    -- ...and the BIG MAP OVERRIDES ALL OF IT, because SetBigmapActive expands
    -- the MINIMAP -- it is the radar, made full-screen. With DisplayRadar
    -- false, which is exactly the lobby, the map button opened nothing at all
    -- and looked broken (user, 2026-08-09). The radar is decided here, once a
    -- frame, so this is the only place that can grant it.
    -- ...and never WHILE THE CURTAIN IS GOING UP, which is a slightly earlier
    -- moment than "during a trip" and is the gap the owner actually saw. The
    -- curtain is raised the instant the server names us a participant, and the
    -- trip that sets `traveling` starts up to a tick later -- so the minimap
    -- popped up into those milliseconds and was visible through a curtain that
    -- was still fading in (#124). Asked-for is the right test here, not
    -- arrived: a radar hidden slightly early costs nothing.
    DisplayRadar(BR.Native.bigmap
        or (st ~= BR.PlayerState.LOBBY and st ~= BR.PlayerState.BUS
        and not (BR.Spawn and BR.Spawn.traveling)
        and not (BR.Spawn and BR.Spawn.curtainWanted)
        and not (BR.Screen and BR.Screen.scoped)))

    -- GTA'S PAUSE MENU IS OURS NOW.
    --
    -- DISABLE_FRONTEND_THIS_FRAME (0x6D3465A73092F0E6) is the documented way
    -- to stop the frontend being TOGGLED -- the natives db points at it from
    -- the deprecated SET_PAUSE_MENU_ACTIVE for exactly this. It works on the
    -- input, not on a control id, so it covers Escape AND a controller's
    -- Start, which disabling controls 199/200 never reliably did.
    --
    -- THREE THINGS HAVE TO BE TRUE FIRST, and each is a way out of a soft
    -- lock rather than caution for its own sake:
    --   * the raw layer is running, so our menu has a key at all;
    --   * our pause menu is actually ON Escape -- rebind it away and the
    --     engine's menu comes straight back, on the next frame;
    --   * and we are not the ones who opened the frontend. The map route
    --     drives GTA's own menu on purpose and watches 199/200/202 to leave
    --     it; suppressing the frontend underneath that would trap a player
    --     inside the map with no way out.
    if BR.Keys and BR.Keys.ownsEscape and BR.Keys.ownsEscape()
       and not BR.Native.frontendMap then
        -- AND IF IT GETS THROUGH ANYWAY, take it back. The disable is the
        -- documented route and it is not the only path into the frontend --
        -- a controller, another resource, a frame we lost -- and "Escape
        -- still opens GTA's menu" was the report that mattered (user,
        -- 2026-08-09). Closing it and raising ours turns a leak into the
        -- thing the player asked for, one frame late.
        --
        -- The raw layer cannot see Escape while CEF holds the cursor, so this
        -- doubles as the path that works with a menu already open.
        --
        -- ═══ AND SOME FRONTENDS ARE NOT LEAKS ═══════════════════════════════
        --
        -- "when opening rockstar editor our pause menu opens and cannot be
        -- dismissed" (owner, 2026-08-29). Both halves of that are this block,
        -- and they are ONE fault rather than two.
        --
        -- The Rockstar Editor is reached through GTA's pause menu, which on
        -- this gamemode means through br_ui's handOverToFrontend -- and THAT
        -- route's watcher (openFrontendPlain) ends on a single poll of
        -- IsPauseMenuActive() reading false. Entering the Editor is such a
        -- poll: the pause menu goes, so the watcher declares the player back in
        -- the game, lowers `frontendMap`, and hands the suppression here back.
        -- The `not BR.Native.frontendMap` guard above was the ONLY thing
        -- holding this block off, and from that frame it is open for business
        -- while the player is still inside a frontend they never left.
        --
        -- What this block then did, every frame the engine said a frontend was
        -- up: deactivate it, and fire `br:ui:pauseToggle`. That handler
        -- TOGGLES, throttled to one action per 220ms -- so the first fire
        -- opened our menu and every fire after it undid whatever the player had
        -- just done. Dismiss it and it is back a fifth of a second later,
        -- forever, for as long as the engine keeps saying a frontend is up.
        -- Opening and un-dismissable are the same line firing twice.
        --
        -- SO THE TOGGLE IS THE REWARD FOR THE DEACTIVATE HAVING WORKED, not a
        -- companion to attempting it. A leaked Escape closes on the frame we
        -- ask and our menu comes up on the next one -- which is the "one frame
        -- late" the paragraph above already promised. A frontend that outlives
        -- the ask is not a leaked keypress, so nothing is owed and our menu
        -- never opens at all.
        --
        -- AND WE STOP ASKING. Hammering SET_FRONTEND_ACTIVE at somebody else's
        -- screen sixty times a second is its own hazard, and DisableFrontend-
        -- ThisFrame over a frontend that is already up can only take away the
        -- toggle that would have closed it. After RETAKE_MS this block goes
        -- silent -- no disable, no deactivate, no toggle -- until the engine
        -- says the frontend has gone, which is the moment the player is ours
        -- again and everything resumes on that same frame.
        local frontendUp = isTrue(IsPauseMenuActive())

        if not frontendUp then
            -- IT CAME DOWN, AND ONLY A DEACTIVATE WE ASKED FOR EARNS THE MENU.
            -- A frontend the player closed themselves is not a press we are
            -- owed, and answering it with our own menu is the report.
            if retake.asked then
                retake.asked = false
                TriggerEvent('br:ui:pauseToggle')
            end
            retake.since, retake.gaveUp = 0, false
        elseif not retake.gaveUp then
            if retake.since == 0 then retake.since = now end
            if (now - retake.since) >= RETAKE_MS then
                -- `asked` is dropped with it: when this frontend eventually
                -- goes -- the player quitting the Editor -- that is them
                -- leaving, not us succeeding, and it must not open our menu.
                retake.asked, retake.gaveUp = false, true
                print('[br_core] a frontend outlived SetFrontendActive(false) '
                    .. '-- leaving it alone until it closes')
            end
        end

        if not retake.gaveUp then
            DisableFrontendThisFrame()
            if frontendUp then
                SetFrontendActive(false)
                retake.asked = true
            end
        end
    else
        -- NOT OUR QUESTION THIS FRAME -- the map route is deliberately holding
        -- the frontend open, or the player has moved our menu off Escape. Any
        -- attempt in flight is abandoned rather than carried across the gap: it
        -- describes a frontend that is now somebody else's.
        retake.asked, retake.since, retake.gaveUp = false, 0, false
    end

    -- AND THE MAP KEY GETS THE SAME TREATMENT, FOR THE SAME REASON (#199).
    --
    -- WHAT M ACTUALLY IS, checked rather than assumed. The issue calls M "GTA's
    -- own expanded-map key"; the FiveM controls reference says otherwise -- the
    -- only control whose default is M is 244, INPUT_INTERACTION_MENU, GTA
    -- Online's interaction menu. There is no INPUT_MAP and nothing on M expands
    -- anything. (The expanded radar is 20/48, INPUT_MULTIPLAYER_INFO and
    -- INPUT_HUD_SPECIAL, both on Z, and both untouched here.)
    --
    -- SO THIS IS INSURANCE, AND IT IS HONEST ABOUT BEING INSURANCE. GTA
    -- Online's interaction menu is not present on a FiveM server -- the online
    -- scripts that draw it do not run -- so 244 is expected to do nothing on
    -- this build, and "expected to do nothing" is exactly what #134 and #122
    -- both were before somebody pressed the key. One press must not drive two
    -- things; the cost of being wrong in this direction is one comparison and
    -- one native call a frame.
    --
    -- IT FOLLOWS THE BINDING, WHICH IS THE WHOLE POINT OF ASKING. Hardcoding
    -- the suppression would be the same mistake as hardcoding the key: a player
    -- who moves the map off M would lose 244 for nothing, and a player who
    -- moves it ONTO some other engine control would keep the collision. boundTo
    -- answers with the key that actually drives the row -- ours when the raw
    -- layer reads it, the engine's default when the engine does -- so the
    -- suppression is on exactly while the two share a key.
    --
    -- KNOWN CONSEQUENCE, STATED: a resource that reads control 244 for a menu
    -- of its own (vMenu's default is also M) stops seeing it while our map is
    -- on M. That is the collision being resolved, not a side effect of
    -- resolving it, and it resolves in favour of the gamemode.
    if BR.Keys and BR.Keys.boundTo and BR.Keys.boundTo('brmap') == 0x4D then
        DisableControlAction(0, 244, true)   -- INPUT_INTERACTION_MENU
    end

    -- GTA's own feed ("X joined", "Y died", weapon unlocks, whatever any other
    -- resource posts). The gamemode owns its presentation -- eliminations go
    -- through the kill feed, everything personal through the notice stack --
    -- so the engine ticker only ever duplicates or contradicts them.
    -- NOTE: this also silences vMenu's notifications, deliberately.
    ThefeedHideThisFrame()

    -- The cash/bank readout pops top-right at load-in and every time the
    -- pause menu closes. There is no money in a battle royale. The area
    -- and street names ("Grand Senora Desert") go with them -- the map is
    -- the gamemode's to narrate (user call, 2026-08-04).
    HideHudComponentThisFrame(3)   -- HUD_CASH
    HideHudComponentThisFrame(4)   -- HUD_MP_CASH (the bank line)
    HideHudComponentThisFrame(7)   -- HUD_AREA_NAME
    HideHudComponentThisFrame(9)   -- HUD_STREET_NAME

    -- GTA'S OWN WEAPON AND AMMO READOUT (user call, 2026-08-06). The
    -- inventory bar IS the ammo counter -- it shows the magazine, the reserve
    -- and which of five slots is up. The engine's version sits in the same
    -- corner showing a subset of that, from its own idea of what the ped
    -- holds, and the two disagree by design: ours is the server's number.
    HideHudComponentThisFrame(2)   -- HUD_WEAPON_ICON (the ammo counter)

    -- GTA'S OWN VEHICLE NAME, WHICH DRAWS ON TOP OF OURS (#208, owner
    -- 2026-08-22: "there's a GTA V text in the bottom right describing what
    -- vehicle it is (make/model) - but that text overlaps with our UI").
    --
    -- Bottom right is the vehicle bars -- condition, fuel, boost -- and the
    -- inventory. The engine puts its make/model card in the same corner on
    -- every vehicle entry, so the two are simply on top of each other.
    --
    -- 6 IS THE ONE, LOOKED UP RATHER THAN GUESSED. The HUD is a numbered
    -- component set and the table is documented (citizenfx/natives,
    -- HUD/HideHudComponentThisFrame.md): 6 is HUD_VEHICLE_NAME, and that is
    -- the make/model card by itself.
    --
    -- WHAT IS DELIBERATELY NOT HIDDEN, because "hide the vehicle text" has two
    -- plausible answers and only one of them was asked for:
    --
    --   8  HUD_VEHICLE_CLASS -- the CLASS label ("Sports"), a different
    --      element that the engine raises for races. This gamemode has no
    --      races, so it is not expected on entry at all; it is named here so
    --      that if a class label ever does turn up in that corner the next
    --      person has the id rather than the search. Adding it would be one
    --      line and would cost nothing -- it is left out because the report
    --      names the vehicle NAME, and hiding what nobody reported is how a
    --      list like this stops being reviewable.
    --
    --   14 HUD_RETICLE and 21/22, the whole-HUD switches. HideHud/DisplayHud
    --      and friends would take the reticle and the minimap with them, which
    --      is the trade the issue rules out in as many words.
    --
    -- PER FRAME, like everything else in this function, which is what makes it
    -- survive a respawn and a match boundary: the component is re-shown by the
    -- engine every frame it wants to draw, so a one-shot hide at resource start
    -- would last exactly one frame. This runs on BR.Loop.FRAME via
    -- client/gamerules.lua with no state gate above it.
    HideHudComponentThisFrame(6)   -- HUD_VEHICLE_NAME (the make/model card)

    -- The corner busy spinner ("Loading...") -- the engine raises it during
    -- session setup and other resources may leave one on. The convar
    -- sv_showBusySpinnerOnLoadingScreen only covers the phase BEFORE scripts
    -- run; from the first frame we own, nothing of the engine's spins.
    if BusyspinnerIsOn() then BusyspinnerOff() end

    -- AMBIENT LIFE, throttled rather than zeroed (user call, 2026-08-04):
    -- the routing bucket's population flag is the on/off switch (matches
    -- on, lobby off -- roster.applyBucket), and these set HOW MUCH streams
    -- in where it is on. Zeroed during the lobby/warmup states anyway --
    -- the island stays a stage.
    local amb = BR.Config.Ambient
    local inWorld = st ~= BR.PlayerState.LOBBY and st ~= BR.PlayerState.WARMUP
    SetVehicleDensityMultiplierThisFrame(inWorld and amb.vehicles or 0.0)
    SetPedDensityMultiplierThisFrame(inWorld and amb.peds or 0.0)
    SetScenarioPedDensityMultiplierThisFrame(
        inWorld and amb.scenarioPeds or 0.0, inWorld and amb.scenarioPeds or 0.0)
    SetRandomVehicleDensityMultiplierThisFrame(inWorld and amb.vehicles or 0.0)
    SetParkedVehicleDensityMultiplierThisFrame(inWorld and amb.parked or 0.0)

    -- HIGH NOON, FOREVER (for now -- user call, 2026-08-04). Weather is
    -- already gamemode-owned; the clock joins it. The SECONDS still spin
    -- (invisible at sun-angle scale) so any engine system that steps on
    -- clock deltas -- wetness decay is a suspect -- keeps stepping.
    --
    -- ...EXCEPT WHEN THE CONSOLE HAS SAID OTHERWISE (owner, 2026-08-31:
    -- "can you make me a brtime command on the server which will set the time
    -- in-game?"). THE PIN LEARNED THE OVERRIDE RATHER THAN GAINING A RIVAL:
    -- this is still the only NetworkOverrideClockTime call in the tree, still
    -- on the same band, still latched the same way -- it is handed a different
    -- pair of numbers. A second writer somewhere else would have lost the
    -- argument within one frame, every frame, and looked like the verb simply
    -- not working. BR.World.clockHM answers the pinned noon until a
    -- BR.Net.WORLD_SET envelope says otherwise.
    --
    -- NIL-GUARDED because client/world.lua is the file that receives that
    -- envelope and br_lib/shared/world.lua is what defines the accessor; a
    -- build without either should stand at noon rather than throw inside the
    -- per-frame rules, which is where an uncaught error costs the whole loop.
    --
    -- ONCE A SECOND, WHICH IS EVERY TIME THE ARGUMENT CHANGES. The third
    -- argument is whole seconds, so at 60fps this native was being handed the
    -- IDENTICAL (12, 0, s) triple about sixty times per distinct value -- and
    -- overriding the network clock is not a free write. Comparing the second
    -- first makes the call happen exactly when the number it carries is new.
    --
    -- The seconds still spin at exactly the rate they did, which is the whole
    -- of the note above: this drops fifty-nine redundant writes per second and
    -- changes nothing about the sequence of values the engine sees.
    --
    -- THE HOUR AND MINUTE ARE LATCHED BESIDE THE SECOND, and that is not
    -- symmetry for its own sake: comparing the second alone would hold a new
    -- override back until the second happened to tick, so `brtime 21` would
    -- land somewhere in the following second rather than on the keystroke.
    local hour, minute = 12, 0
    if BR.World and BR.World.clockHM then hour, minute = BR.World.clockHM() end

    local clockSec = math.floor(now / 1000) % 60
    if clockSec ~= latch.clockSec
       or hour ~= latch.clockHour or minute ~= latch.clockMin then
        latch.clockSec  = clockSec
        latch.clockHour = hour
        latch.clockMin  = minute
        NetworkOverrideClockTime(hour, minute, clockSec)
    end

    -- Never let the engine's own death/respawn flow run; the gamemode owns it.
    --
    -- LATCHING, AND RE-ARMED ON EVERY STATE CHANGE, which matters most for the
    -- third one. PauseDeathArrestRestart and SetFadeOutAfterDeath are settings
    -- the engine holds; IgnoreNextRestart is a one-shot the engine CONSUMES,
    -- so the thing that must not happen is it being spent and left unarmed.
    -- Dying is a player-state change, so `due` is true on that frame and all
    -- three are re-asserted before the engine's restart path could run -- and
    -- PauseDeathArrestRestart(true) has that path stopped regardless, which is
    -- why this is a second line of defence rather than the only one.
    if due then
        PauseDeathArrestRestart(true)
        SetFadeOutAfterDeath(false)
        IgnoreNextRestart(true)
    end
end

--- One-time world setup at resource start.
function BR.Native.applyWorldSetup()
    SetGarbageTrucks(false)
    SetRandomBoats(false)
    SetRandomTrains(false)
    DistantCopCarSirens(false)
    SetAudioFlag('PoliceScannerDisabled', true)

    -- The squad relationship group. Local to this client, like all
    -- relationship state: MY view groups me and my squadmates together, an
    -- enemy's view groups me with the default PLAYER crowd -- and since each
    -- client's own shots are computed against its own view, both are right.
    AddRelationshipGroup('BR_ALLY')
    local player = GetHashKey('PLAYER')
    -- 5 = hate: BR_ALLY (me + squad) will damage the PLAYER group (everyone
    -- else) and vice versa. Within BR_ALLY, canAttackFriendly = false rules.
    SetRelationshipBetweenGroups(5, BR.Native.ALLY_GROUP, player)
    SetRelationshipBetweenGroups(5, player, BR.Native.ALLY_GROUP)
end

-- ------------------------------------------------------------ native check ---

--- Probe the natives this file depends on and report what is actually available.
---
--- This exists because "the native is documented" and "the native behaves as
--- documented on this build" are different claims, and the second one is the one
--- that matters. Run it in the lobby after any client update.
---
--- @return table array of { name, ok, detail }
function BR.Native.check()
    local results = {}
    local function probe(name, fn)
        local ok, err = pcall(fn)
        results[#results + 1] = { name = name, ok = ok, detail = ok and '' or tostring(err) }
    end

    local ped = PlayerPedId()

    probe('GetPedParachuteState',    function() return GetPedParachuteState(ped) end)
    probe('GetEntityHeightAboveGround', function() return GetEntityHeightAboveGround(ped) end)
    probe('SetPlayerParachuteModelOverride', function()
        SetPlayerParachuteModelOverride(PlayerId(), GetHashKey(BR.Config.Drop.parachuteModel))
    end)
    -- The chute's AMMO, not its presence, is what the engine reads as "has a
    -- parachute available" -- the disarm path checks it and the landing retry
    -- loop exits on it, so a nil here would silently re-arm every player.
    probe('GetAmmoInPedWeapon',      function()
        return GetAmmoInPedWeapon(ped, BR.Config.Gadgets.PARACHUTE)
    end)
    probe('SetPedCanRagdoll',        function() SetPedCanRagdoll(ped, true) end)
    -- THE DOWNED STATE'S NATIVES (M7). Every one of these is called on a ped
    -- that is lying on the floor and cannot fight back, which is the worst
    -- possible place to discover a nil binding: an unknown native throws, five
    -- throws suspend the frame callback, and the callback that would have stood
    -- them back up goes with it. The crawl ASSETS are resolved separately at
    -- first use (client/dbno.lua) because their absence is a degrade rather
    -- than a fault; these are the bindings themselves.
    probe('SetPedMovementClipset',   function()
        -- Requested, not applied: applying one here would leave the caller of
        -- /brnativecheck walking oddly until something reset it.
        return RequestClipSet('move_crawl')
    end)
    probe('HasClipSetLoaded',        function() return HasClipSetLoaded('move_crawl') end)
    probe('ResetPedMovementClipset', function() ResetPedMovementClipset(ped, 0.0) end)
    probe('SetPedMoveRateOverride',  function() SetPedMoveRateOverride(ped, 1.0) end)
    probe('TaskPlayAnim',            function()
        return HasAnimDictLoaded('move_injured_ground')
    end)
    probe('GetEntityHealth',         function() return GetEntityHealth(ped) end)
    probe('SetEntityMaxHealth',      function() SetEntityMaxHealth(ped, BR.Config.Match.maxHealth) end)
    probe('GetPedArmour',            function() return GetPedArmour(ped) end)
    probe('SetPlayerMaxArmour',      function() SetPlayerMaxArmour(PlayerId(), BR.Config.Match.maxArmour) end)
    probe('SetPlayerHealthRechargeMultiplier', function()
        SetPlayerHealthRechargeMultiplier(PlayerId(), 0.0)
    end)
    probe('AddBlipForRadius',        function()
        local b = AddBlipForRadius(0.0, 0.0, 0.0, 100.0)
        RemoveBlip(b)
    end)
    -- Dead squadmates keep a dimmed blip; a nil here would leave every
    -- eliminated mate looking alive on the minimap.
    probe('SetBlipAlpha',            function()
        local b = AddBlipForCoord(0.0, 0.0, 0.0)
        SetBlipAlpha(b, 120)
        RemoveBlip(b)
    end)
    -- The lobby camera's LIFECYCLE, not its creation: brunstuck calls
    -- DestroyAllCams, which leaves BR.LobbyCam holding a handle to a camera
    -- that no longer exists. DoesCamExist is what stops it believing the shot
    -- is still up and never raising it again -- so a nil binding here would
    -- not fail loudly, it would leave a player in the lobby looking through
    -- the gameplay camera at nothing.
    -- THE ONE THAT KEEPS PLAYERS OUT OF EACH OTHER'S LOBBY SHOT.
    --
    -- Purely local and single-frame ("not visible for yourself for the current
    -- frame"), which is exactly why it works where two networked approaches
    -- did not -- see client/squadmates.lua. A nil binding here would be
    -- silent: everyone would simply see everyone, which is a design failure
    -- rather than an error, and it took three attempts to find the native
    -- that holds.
    probe('SetEntityLocallyInvisible', function()
        SetEntityLocallyInvisible(ped)
    end)
    probe('DoesCamExist',            function()
        local c = CreateCamWithParams('DEFAULT_SCRIPTED_CAMERA',
            0.0, 0.0, -200.0, 0.0, 0.0, 0.0, 50.0, false, 0)
        local exists = DoesCamExist(c)
        DestroyCam(c, true)
        return exists
    end)
    probe('DrawMarker',              function()
        DrawMarker(1, 0.0, 0.0, -200.0, 0,0,0, 0,0,0, 1.0,1.0,1.0, 0,0,0, 0, false, false, 2, false, nil, nil, false)
    end)
    probe('SetTimecycleModifier',    function()
        SetTimecycleModifier(BR.Config.Storm.fx.timecycle)
        ClearTimecycleModifier()
    end)
    -- The underscore is real: FiveM keeps it when a native name segment
    -- starts with a digit. The unadorned spelling is nil, and the storm wall
    -- shipped calling it once -- this probe is what makes that a boot-time
    -- finding instead of a per-frame error spam report.
    probe('GetGroundZFor_3dCoord',   function()
        return GetGroundZFor_3dCoord(0.0, 0.0, 500.0, false)
    end)
    probe('SetFocusPosAndVel',       function()
        SetFocusPosAndVel(0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
        ClearFocus()
    end)
    probe('NetworkIsInSpectatorMode', function() return NetworkIsInSpectatorMode() end)
    probe('CreateObjectNoOffset',    function()
        -- isNetwork = false is the whole basis of the loot design; if this ever
        -- starts producing networked entities the server will not survive it.
        local m = GetHashKey('prop_box_ammo04a')
        RequestModel(m)
        local obj = CreateObjectNoOffset(m, 0.0, 0.0, -200.0, false, false, false)
        if obj and obj ~= 0 then DeleteEntity(obj) end
        SetModelAsNoLongerNeeded(m)
    end)
    probe('PauseDeathArrestRestart', function() PauseDeathArrestRestart(true) end)

    -- EMERGENCY DISPATCH. A nil binding here is the silent kind docs/platform.md
    -- is about: nothing throws, nothing logs, and the only symptom is a fire
    -- engine arriving at a firefight three weeks later. Harmless to run in the
    -- lobby -- applyGameRules writes the same thing on the next heartbeat.
    probe('EnableDispatchService',   function()
        EnableDispatchService(BR.Native.DispatchService.FIRE_DEPARTMENT, false)
    end)

    -- M5 loot and inventory. Every one of these is load-bearing on a path the
    -- unit tests cannot reach (they stub natives), and a misspelled native is
    -- nil rather than an error -- which is how GetGroundZFor_3dCoord cost a
    -- day. Probe first, test in-game second.
    probe('GetWeapontypeModel',      function()
        -- Weapons on the ground are drawn as the engine's own model for the
        -- weapon rather than 35 hand-typed prop names.
        return GetWeapontypeModel(BR.Config.WeaponById['pistol'].hash)
    end)
    probe('PlaceObjectOnGroundProperly', function()
        local m = GetHashKey('prop_box_ammo04a')
        RequestModel(m)
        local obj = CreateObjectNoOffset(m, 0.0, 0.0, -200.0, false, false, false)
        if obj and obj ~= 0 then
            PlaceObjectOnGroundProperly(obj)
            DeleteEntity(obj)
        end
        SetModelAsNoLongerNeeded(m)
    end)
    -- The ammo report reads this every 500ms. A nil here reports clip 0 for
    -- every weapon forever, and the server accepts decreases -- so a wrong
    -- name would quietly empty every magazine in the match.
    probe('GetAmmoInClip',           function()
        local _, clip = GetAmmoInClip(ped, BR.Config.WeaponById['pistol'].hash)
        return clip
    end)
    probe('GetAmmoInPedWeapon',      function()
        return GetAmmoInPedWeapon(ped, BR.Config.WeaponById['pistol'].hash)
    end)
    probe('SetAmmoInClip',           function()
        -- Harmless on a ped that does not hold the weapon; the point is only
        -- that the name resolves.
        SetAmmoInClip(ped, BR.Config.WeaponById['pistol'].hash, 0)
    end)
    probe('SetDrawOrigin',           function()
        SetDrawOrigin(0.0, 0.0, -200.0, 0)
        ClearDrawOrigin()
    end)
    -- THE ENGINE TEAM GATE (#115), and the only thing here that reports a
    -- VALUE rather than merely resolving. `detail` normally stays empty on a
    -- pass, which is right for "does this name exist" and useless for the one
    -- question this round of #115 turns on: does a team written by this client
    -- actually stick.
    --
    -- Read it as: the number after `team` is what the engine says my team is,
    -- one line after being told. If it does not match, SET_PLAYER_TEAM is not
    -- taking on this build and BR.Config.Match.engineTeams should go false --
    -- and nothing further about #115 is worth writing in Lua.
    --
    -- Restores whatever teamFor currently wants, so running /brnativecheck mid
    -- match cannot leave a player on a probe's team.
    do
        local want = BR.Native.teamFor(BR.State.me, BR.State.roster)
        local ok, got = pcall(function()
            SetPlayerTeam(PlayerId(), want)
            return GetPlayerTeam(PlayerId())
        end)
        BR.Native.forgetTeam()
        results[#results + 1] = {
            name   = 'SetPlayerTeam/GetPlayerTeam',
            ok     = ok and got == want,
            detail = ('wrote team %s, engine reports %s')
                :format(tostring(want), tostring(got)),
        }
    end
    probe('NetworkSetFriendlyFireOption', function()
        -- Written with the value the frame loop is about to write anyway, so
        -- the probe cannot leave the gate in the wrong position for a frame.
        local _, shield = BR.Native.teamFor(BR.State.me, BR.State.roster)
        NetworkSetFriendlyFireOption(not shield)
    end)

    -- The no-teamkill net reads these every frame that health drops. A nil
    -- here means friendly fire silently works again.
    probe('HasEntityBeenDamagedByEntity', function()
        return HasEntityBeenDamagedByEntity(ped, ped, true)
    end)
    probe('ClearEntityLastDamageEntity', function()
        ClearEntityLastDamageEntity(ped)
    end)
    probe('GetPlayerHasReserveParachute', function()
        return GetPlayerHasReserveParachute(PlayerId())
    end)
    -- The interaction ray. Without it there is no pickup system at all -- the
    -- prompt would never resolve a target.
    probe('StartExpensiveSynchronousShapeTestLosProbe', function()
        local h = StartExpensiveSynchronousShapeTestLosProbe(
            0.0, 0.0, -200.0, 0.0, 0.0, -190.0, 16, PlayerPedId(), 4)
        local _, hit = GetShapeTestResult(h)
        return hit
    end)
    -- The interaction ray's DIRECTION. BR.Native.aim() fires along the ped's
    -- forward vector (user call: you turn towards a thing to interact with
    -- it), so a nil here is a ray that always points at world origin.
    probe('GetEntityForwardVector',  function() return GetEntityForwardVector(ped) end)
    -- LOOT CHOREOGRAPHY. Loose items arc out of crates, hover when you are in
    -- range and fly to your hands when taken -- all of which is these two
    -- natives called per frame on a prop. A nil in either is not a subtle
    -- failure: it throws every frame, and five throws suspend loot.render,
    -- which takes the glow, the labels and the prompt with it.
    --
    -- NoOffset specifically: SetEntityCoords applies a model-height offset
    -- that would sink the item into the ground as it lands.
    probe('SetEntityCoordsNoOffset', function()
        return SetEntityCoordsNoOffset ~= nil
    end)
    probe('SetEntityHeading', function() return GetEntityHeading(ped) end)
    -- PITCH, not just yaw: an item lies flat on the ground and stands up to be
    -- taken, and heading alone cannot express that. Rotation order 2 is the
    -- one every GTA example uses for ZXY euler angles.
    probe('SetEntityRotation', function() return GetEntityRotation(ped, 2) end)

    -- VOICE. FiveM's built-in Mumble, which is what keeps two parallel matches
    -- from sharing a room. A nil here is not a crash -- client/voice.lua
    -- degrades to whatever the engine does by default -- but the default is
    -- "everybody in channel 0", i.e. every match audible to every other, and
    -- the symptom is somebody answering a rotation call from another game.
    -- So it is probed loudly rather than discovered quietly.
    --
    -- Read-only calls only: setting a channel here would move the player out
    -- of whatever room they are legitimately in.
    probe('MumbleIsConnected',   function() return MumbleIsConnected() end)
    -- THE FIRST OF THE THREE, AND THE ONE THAT WAS NEVER CALLED (#150).
    --
    -- A Mumble channel does not exist because a script named it. Nothing can
    -- be joined, listened to or transmitted into until it has been created,
    -- and a nil here is not a degraded voice system -- it is no voice system,
    -- because every channel id this gamemode uses would name a room that is
    -- not there. The engine says so out loud when it happens:
    --   "MUMBLE_ADD_VOICE_CHANNEL_LISTEN: Tried to call native on a channel
    --    that didn't exist"
    probe('MumbleCreateChannel', function()
        return MumbleCreateChannel ~= nil
    end)
    probe('MumbleSetVoiceChannel', function()
        return MumbleSetVoiceChannel ~= nil
    end)
    probe('MumbleClearVoiceChannel', function()
        return MumbleClearVoiceChannel ~= nil
    end)
    -- THE VOICE TARGET IS THE TRANSMIT PATH, and this trio is now load-bearing
    -- rather than optional (#150). Being in a channel decides what a player
    -- HEARS; the target decides where their own audio GOES, and client/voice.lua
    -- builds one for every player in every mode because the version that only
    -- built one for squads left every solo player inaudible. A nil in any of
    -- these is not "no squad voice" any more -- it is no voice at all.
    probe('MumbleSetVoiceTarget', function()
        return MumbleSetVoiceTarget ~= nil
    end)
    probe('MumbleClearVoiceTarget', function()
        return MumbleClearVoiceTarget ~= nil
    end)
    probe('MumbleAddVoiceTargetChannel', function()
        return MumbleAddVoiceTargetChannel ~= nil
    end)
    -- SQUAD VOICE IS TWO NATIVES AND NO ROOM (#157). The first routes our
    -- audio to a squadmate directly; the second is now the load-bearing one for
    -- the WHOLE receive side, not just for squads: it is the only per-listener
    -- volume control the engine has, and the proximity cutoff, the squad radio
    -- and the 'off' switch are all made out of it. A nil in the second one is
    -- not "no squad radio" -- it is a client with no way to decline audio at
    -- all, so every player in the match is audible everywhere.
    probe('MumbleAddVoiceTargetPlayerByServerId', function()
        return MumbleAddVoiceTargetPlayerByServerId ~= nil
    end)
    probe('MumbleSetVolumeOverrideByServerId', function()
        return MumbleSetVolumeOverrideByServerId ~= nil
    end)
    -- THE ENGINE'S OWN DISTANCE CUTOFF, PROBED BUT DELIBERATELY NEVER CALLED.
    --
    -- These were called for one release and they are what made 'nearby' silent
    -- at every distance: stating a distance switches MumbleAudioOutput onto a
    -- position comparison, and a speaker whose position it does not have is
    -- silenced rather than treated as near. They are still probed because their
    -- presence is worth knowing when reading a bug report -- if they are
    -- missing, this build predates the whole mechanism -- but client/voice.lua
    -- applies the cutoff itself and must not call either of these.
    probe('MumbleSetAudioInputDistance', function()
        return MumbleSetAudioInputDistance ~= nil
    end)
    probe('MumbleSetAudioOutputDistance', function()
        return MumbleSetAudioOutputDistance ~= nil
    end)
    -- The GAME's own talker proximity, which is a different native from
    -- MumbleSetTalkerProximity -- that one feeds the engine's SetAudioDistance
    -- and is avoided for the same reason as the two above. This one belongs to
    -- the game's voice path and is the right number on native-audio playback.
    probe('NetworkSetTalkerProximity', function()
        return NetworkSetTalkerProximity ~= nil
    end)
    -- Reads the player's ACTUAL binding for the prompt's key badge. Without
    -- it the prompt shows no key at all.
    probe('GetControlInstructionalButton', function()
        return GetControlInstructionalButton(2, BR.Config.Loot.promptControl or 51, true)
    end)
    -- DUI: the loot prompt is a browser page rendered into a game texture and
    -- drawn as a world sprite. Four natives, all load-bearing -- a nil in any
    -- of them is a prompt that never appears at all.
    probe('CreateRuntimeTxd',        function()
        local txd = CreateRuntimeTxd('br_probe_txd')
        return txd ~= nil
    end)
    probe('CreateDui + DestroyDui',  function()
        local d = CreateDui('nui://br_ui/dui/prompt.html', 8, 8)
        local h = GetDuiHandle(d)
        DestroyDui(d)
        return h
    end)
    -- The ammo report skips a reloading ped: mid-swap the magazine reads as
    -- whatever the animation has reached, which is not a number to build on.
    probe('IsPedReloading',          function() return IsPedReloading(ped) end)
    probe('IsPedShooting',           function() return IsPedShooting(ped) end)
    -- MEASURED: with our own ammo writes suspended, the magazine did not move
    -- while firing and the totals rose by one per shot -- the signature of an
    -- infinite-ammo clip. Nothing here turns it on, which is exactly why it is
    -- asserted OFF on every weapon grant: it is a ped flag with a default we
    -- do not control.
    probe('SetPedInfiniteAmmo',      function()
        SetPedInfiniteAmmo(ped, false, BR.Config.WeaponById['pistol'].hash)
    end)
    probe('SetPedInfiniteAmmoClip',  function() SetPedInfiniteAmmoClip(ped, false) end)
    -- Closing GTA's pause menu out from under our own screens: a player killed
    -- with the map open arrived in the lobby with the frontend still up.
    probe('IsPauseMenuActive',       function() return IsPauseMenuActive() end)
    probe('SetFrontendActive',       function()
        -- Only ever called when the pause menu IS active, so this probe must
        -- not call it blind -- SetFrontendActive(false) on a closed frontend
        -- is harmless but proves nothing about the open case.
        return IsPauseMenuActive() and 'menu open (not touched by probe)'
            or 'menu closed'
    end)
    -- Crate drag. Prop physics has no useful friction, so a shunted crate is
    -- slowed by scaling its own velocity down each tick.
    probe('GetEntityVelocity',       function()
        local v = GetEntityVelocity(ped)
        return ('%.2f,%.2f,%.2f'):format(v.x, v.y, v.z)
    end)
    probe('SetEntityVelocity',       function()
        -- On the PED, and with its own current velocity: this is a no-op that
        -- still proves the native exists and takes three floats.
        local v = GetEntityVelocity(ped)
        SetEntityVelocity(ped, v.x, v.y, v.z)
    end)
    -- Stops the engine choosing the weapon on pickup and on empty, which
    -- otherwise fights the active-slot model for control of the hand.
    -- ox_inventory sets this for the same reason.
    probe('SetWeaponsNoAutoswap',    function() SetWeaponsNoAutoswap(true) end)
    -- Passengers must be able to fire; without this GTA refuses drive-bys
    -- outright and a car is a coffin for everyone who is not driving.
    probe('SetPlayerCanDoDriveBy',   function()
        SetPlayerCanDoDriveBy(PlayerId(), true)
    end)
    -- /brdriveby leans on all six of these, and #197 is precisely a case where
    -- the readout has to be trusted over an argument -- so the readout's own
    -- natives get the same treatment as gameplay's.
    probe('IsPedInAnyVehicle',       function()
        return IsPedInAnyVehicle(ped, false)
    end)
    probe('GetVehiclePedIsIn',       function()
        return GetVehiclePedIsIn(ped, false)
    end)
    probe('GetPedInVehicleSeat',     function()
        local v = GetVehiclePedIsIn(ped, false)
        if not v or v == 0 then return 'not in a vehicle (not called)' end
        return GetPedInVehicleSeat(v, -1) == ped and 'driver' or 'passenger'
    end)
    probe('GetDisplayNameFromVehicleModel', function()
        local v = GetVehiclePedIsIn(ped, false)
        if not v or v == 0 then return 'not in a vehicle (not called)' end
        return GetDisplayNameFromVehicleModel(GetEntityModel(v))
    end)
    -- The one native that answers "is the engine LETTING you do this", as
    -- opposed to the six that answer "did anybody stop you".
    probe('IsPedDoingDriveby',       function() return IsPedDoingDriveby(ped) end)
    -- Declared BOOL, and read for six controls a frame by the drive-by watch.
    -- The TYPE is the interesting half: a build that answers 0 would make every
    -- `not IsControlEnabled(...)` in the game read backwards.
    probe('IsControlEnabled',        function()
        local v = IsControlEnabled(0, 24)
        return ('%s [%s]'):format(tostring(v), type(v))
    end)
    -- Taking a weapon the server never issued back out of the hand, so a
    -- trainer-spawned rifle cannot even produce the local corpse.
    probe('RemoveWeaponFromPed',     function()
        -- A weapon the player will not have: proves the binding without
        -- disarming anybody mid-probe.
        RemoveWeaponFromPed(ped, GetHashKey('WEAPON_RAILGUN'))
    end)
    -- Undoing a refused shot on the SHOOTER's screen. The engine applies
    -- damage locally before the server sees the event, so a cancelled shot
    -- still leaves a corpse there -- and health alone does not revive a ped
    -- that has entered the death state.
    probe('ResurrectPed',            function()
        -- On the player's own ped, which is alive: a no-op that proves the
        -- binding without disturbing anything.
        if not IsEntityDead(ped) then ResurrectPed(ped) end
        return 'not called on a live ped'
    end)
    probe('ClearPedTasksImmediately', function()
        -- NOT called on the player -- it would cancel whatever they are doing.
        return IsEntityDead(ped) and 'ped is dead' or 'ped alive (not called)'
    end)
    probe('NetworkDoesNetworkIdExist', function()
        return NetworkDoesNetworkIdExist(NetworkGetNetworkIdFromEntity(ped))
    end)
    probe('NetworkGetEntityFromNetworkId', function()
        local id = NetworkGetNetworkIdFromEntity(ped)
        return NetworkGetEntityFromNetworkId(id) == ped
            and 'round-trips to the same ped' or 'MISMATCH'
    end)
    -- The mouse wheel belongs to the scope while aiming, not to slot cycling.
    probe('IsPlayerFreeAiming',      function()
        return IsPlayerFreeAiming(PlayerId())
    end)
    -- Ambient drivers who drive like maniacs. Ability and aggression alone did
    -- nothing visible -- the driving TASK and its style flags are what decide
    -- whether a ped stops at a light or drives through the junction.
    probe('SetPedKeepTask',          function() SetPedKeepTask(ped, true) end)
    probe('SetDriveTaskDrivingStyle', function()
        -- On the PLAYER's ped, which has no drive task: a no-op that still
        -- proves the binding exists.
        SetDriveTaskDrivingStyle(ped, 262656)
    end)
    probe('SetDriverRacingModifier', function()
        SetDriverRacingModifier(ped, 1.0)
    end)
    -- Killing an NPC makes the engine drop their weapon as a vanilla pickup,
    -- which has none of our loot's affordances and puts a gun in the ped's
    -- hands the inventory has never heard of.
    probe('SetPedDropsWeaponsWhenDead', function()
        SetPedDropsWeaponsWhenDead(ped, false)
    end)
    -- Reading a corpse for the weapon it was holding, so an NPC kill drops one
    -- of OUR entries instead of a vanilla pickup.
    probe('IsPedDeadOrDying',        function()
        return IsPedDeadOrDying(ped, true)
    end)
    probe('GetGamePool(CPed)',       function()
        return ('%d peds in the world'):format(#GetGamePool('CPed'))
    end)
    probe('GetGamePool(CPickup)',    function()
        return ('%d pickups in the world'):format(#GetGamePool('CPickup'))
    end)
    probe('DoesPickupExist',         function()
        local pool = GetGamePool('CPickup')
        return #pool > 0 and tostring(DoesPickupExist(pool[1])) or 'no pickups'
    end)
    probe('GetPickupCoords',         function()
        local pool = GetGamePool('CPickup')
        if #pool == 0 then return 'no pickups' end
        local c = GetPickupCoords(pool[1])
        return c and ('%.1f,%.1f,%.1f'):format(c.x, c.y, c.z) or 'nil'
    end)
    probe('RemovePickup',            function()
        -- NOT called blind: removing a live pickup would be the probe changing
        -- the world. Existence of the binding is what is being checked.
        return ('%d pickups present'):format(#GetGamePool('CPickup'))
    end)
    -- Clearing the player's own map waypoint from a keybind, because GTA's
    -- only built-in way is to re-click the flag in the pause map.
    probe('IsWaypointActive',        function() return IsWaypointActive() end)
    probe('SetWaypointOff',          function()
        -- Not called blind: turning off a waypoint the player set on purpose
        -- would be the probe changing the game.
        return IsWaypointActive() and 'waypoint set (not cleared by probe)'
            or 'no waypoint'
    end)
    -- Anchoring the crate label to the crate: every corner of the quad is an
    -- offset in the PROP's local space, which is what buys yaw, pitch and roll
    -- without any orientation maths of our own.
    probe('GetOffsetFromEntityInWorldCoords', function()
        local v = GetOffsetFromEntityInWorldCoords(ped, 0.0, 0.0, 1.0)
        return ('%.2f,%.2f,%.2f'):format(v.x, v.y, v.z)
    end)
    probe('GetModelDimensions',      function()
        local mn, mx = GetModelDimensions(GetHashKey(BR.Config.Loot.chestProp))
        return ('%.2f..%.2f z'):format(mn.z, mx.z)
    end)
    probe('GetEntityRotation',       function()
        local r = GetEntityRotation(ped, 2)
        return ('%.1f,%.1f,%.1f'):format(r.x, r.y, r.z)
    end)
    probe('SetEntityRotation',       function()
        local r = GetEntityRotation(ped, 2)
        SetEntityRotation(ped, r.x, r.y, r.z, 2, true)
    end)
    probe('GetGameplayCamCoord',     function()
        local c = GetGameplayCamCoord()
        return ('%.1f,%.1f,%.1f'):format(c.x, c.y, c.z)
    end)
    -- The world-space crate label: a textured quad lying flat on the lid.
    probe('DrawSpritePoly',          function()
        -- Degenerate (all three vertices identical) so the probe draws
        -- nothing visible while still proving the signature binds.
        local c = GetEntityCoords(ped)
        DrawSpritePoly(c.x, c.y, c.z, c.x, c.y, c.z, c.x, c.y, c.z,
            255, 255, 255, 0, 'deadline', 'deadline',
            0.0, 0.0, 1.0, 0.0, 0.0, 1.0, 0.0, 0.0, 1.0)
    end)
    -- Crate mass. Measured: PlaceObjectOnGroundProperly is what welds a crate
    -- down, and the default mass is what made the survivor feel like concrete.
    probe('SetObjectPhysicsParams',  function()
        local m = GetHashKey(BR.Config.Loot.chestProp)
        RequestModel(m)
        local obj = CreateObjectNoOffset(m, 0.0, 0.0, -200.0, false, false, true)
        if obj and obj ~= 0 then
            SetObjectPhysicsParams(obj, 12.0, 0.1, -1.0, -1.0, -1.0, -1.0,
                0.1, 0.1, 0.1, -1.0, -1.0)
            DeleteEntity(obj)
        end
        SetModelAsNoLongerNeeded(m)
    end)
    probe('DrawSprite',              function()
        DrawSprite('commonmenu', 'common_medal', -1.0, -1.0, 0.01, 0.01,
            0.0, 255, 255, 255, 0)
    end)
    probe('GetWaterHeight',          function()
        local _, h = GetWaterHeight(0.0, 0.0, 0.0)
        return h
    end)

    -- The health model assumption that most affects gameplay: does a player ped
    -- really floor at 100 rather than 0?
    local maxH = GetEntityMaxHealth(ped)
    results[#results + 1] = {
        name   = 'health model',
        ok     = true,
        detail = ('engine max=%d, configured max=%d, floor=%d -- verify a dead player reads <= floor')
            :format(maxH, BR.Config.Match.maxHealth, BR.Config.Match.healthFloor),
    }

    return results
end
