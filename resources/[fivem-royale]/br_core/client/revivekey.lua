-- The revive key, on screen: the plate over a loose key, the two plates at an
-- ambulance, and the arrival that puts a mate back in the sky above one. #219
-- step 5's client half.
--
-- ═══════════════════════════════════════════════════════════════════════════
-- THIS FILE DECIDES NOTHING. IT DRAWS, IT REPORTS A PRESS, AND IT ARRIVES
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Every rule lives in server/revivekey.lua: whether a key exists, whether the
-- squad owns it, whether this player is close enough, whether that vehicle is an
-- ambulance, whether the match is still running, and whether six seconds have
-- actually elapsed. Nothing here is a boundary. What this side owns is the three
-- things the server cannot do -- draw, notice a finger on a key, and move this
-- machine's own ped -- and it owns them the way client/dbno.lua does, because
-- that file has already paid for the alternatives.
--
-- ═══════════════════════════════════════════════════════════════════════════
-- WHERE THE COORDINATES COME FROM, AND WHY NOT FROM A PED
-- ═══════════════════════════════════════════════════════════════════════════
--
-- THE PICKUP comes FROM THE SQUAD BEACON (server/party.lua), as
-- `m.key = { x, y, z, held, live, mintedAt }` on the OUT mate's row. Those are the
-- SERVER'S OWN NUMBERS -- the ones its ruling is measured against -- so the take
-- plate and the take ruling cannot disagree about where the key is.
--
-- THE REVIVE comes from an AMBULANCE, found with GetClosestVehicle exactly as
-- the buy plate has always found one, and named to the server as a net id it
-- then interrogates for itself. The owner moved the revive there on 2026-08-30:
-- "the press e to revive DUI when standing at the ped should not show once
-- they've bled out. The only option at that point is the ambulance."
--
-- AND NEITHER IS A DEAD PED, WHICH IS POISON. client/dbno.lua's #163 block: our
-- machine's copy of a downed mate "CRAWLS AWAY", and commit 33ca88c adds that a
-- corpse's position is a death ragdoll -- "the one thing this file already knows
-- do not replicate reliably" (citizenfx/fivem#2436, open). A prompt anchored to
-- that walks off the body it belongs to, on this screen only, while the server
-- still rules against the fixed point. There is no ped in this file at all.
--
-- ═══════════════════════════════════════════════════════════════════════════
-- ONE PROMPT BROWSER, SIX CONSUMERS, ONE KEY. HOW THIS ONE YIELDS
-- ═══════════════════════════════════════════════════════════════════════════
--
-- The crate, the pump, the revive, the heal station and the showroom already
-- share `nui://br_ui/dui/prompt.html` and all listen on 'interact', which
-- BR.Keys fans to EVERY listener with no consume. This file is the sixth, and it
-- does not add an arbiter -- client/ambheal.lua and client/loot.lua both record
-- why that is a restructure of the hottest pass in the client rather than a
-- feature. It yields, in three explicit directions:
--
--   * TO client/dbno.lua, which calls BR.ReviveKey.yield() from its own frame
--     pass while a DOWNED mate is in reach or being held. A knock beside a
--     corpse is the one place the take plate genuinely overlaps, and picking up
--     a mate who is still bleeding beats walking to a van for one who is not.
--   * TO client/ambheal.lua, by standing BOTH AMBULANCE PLATES down while
--     BR.AmbHeal.prompting() -- otherwise one press behind an ambulance would
--     start a heal AND spend 25 Volts, or start a heal AND a six-second revive.
--     It used to be only the buy plate that yielded, because the revive used to
--     happen at a corpse; the revive moved to the van, so it inherits the same
--     stand-down and for the same reason.
--   * TO client/loot.lua, by way of dbno.lua's single BR.Loot.suppress() call
--     site, which now reads BR.ReviveKey.prompting(). A corpse is ringed with
--     scattered loot BY CONSTRUCTION (BR.Loot.deathBox), so this is not an edge
--     case -- it is every single revive. The suppression is driven from the ONE
--     existing caller rather than added as a second bare one, because
--     BR.Loot.suppress is a plain boolean and a second writer saying `false`
--     would clear the first writer's yield on the frame they disagree.
--
-- ═══════════════════════════════════════════════════════════════════════════
-- WHERE THE THREE PLATES ARE DRAWN, AND WHY TWO OF THEM ARE NOT BILLBOARDS
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Owner, 2026-08-31: "I don't like the positioning of the 'press E to revive'
-- DUI... What I want is a DUI that shows on the nearest face of the vehicle."
--
-- THE TWO PLATES AT A VAN ARE SIGNS ON ITS BODYWORK. Both of them -- the revive
-- and the purchase -- go through `drawOnVan` to BR.Dui.drawNearFace, which
-- stands a quad in the world, in metres, level with the horizon, off whichever
-- panel of the model's own box the PLAYER is nearest to. They used to be
-- screen-space sprites hanging a fixed 1.1m over the vehicle's origin, which is
-- roughly its roof, and that is the positioning he is objecting to.
--
-- THEY CANNOT OVERLAP, BECAUSE THEY ARE NEVER BOTH OFFERED. `choose` returns
-- exactly one candidate and the revive beats the buy (see its header), so the
-- two never reach the browser in the same frame. That is also why they share one
-- set of numbers: they are one plate at one van, and giving them two positions
-- would only mean the plate jumped the instant a squad paid its 25 Volts.
--
-- THE PLATE OVER A LOOSE KEY IS STILL A BILLBOARD, and that is not an
-- inconsistency: there is no bodywork under it. It hangs over a point on the
-- ground where a body fell, so it stays BR.Dui.drawWorld at GROUND_LIFT.
--
-- AND THE RING IS THE RESTING STATE NOW. "I want it by default to draw the empty
-- circle around the E instead of a glyph that changes to the circle when
-- pressed" -- the same message. The revive plate carries `ring` with no
-- duration, which dui/prompt.html already draws as an empty circle round the key
-- cap; the hold adds `holdMs` and the circle fills. The other two plates are
-- single presses and carry no ring, because a ring with nothing behind it is an
-- interface promising a hold that does not exist.
--
-- ═══════════════════════════════════════════════════════════════════════════
-- NO STRINGS LIVE HERE
-- ═══════════════════════════════════════════════════════════════════════════
--
-- All three plates read BR.Config.ReviveKey.copy. There is no `or 'Revive'`
-- anywhere in this file: a missing line draws NO PLATE rather than a fallback
-- somebody else wrote, because the owner's standing rule is that copy he did not
-- ask for reads as slop, and a default in an `or` is exactly how one ships.
--
-- THE ARRIVAL SPEAKS NOTHING AT ALL. It is a fade, a placement and a parachute;
-- the player watches the world come back and works out where they are from the
-- world. There is no seventh line and none may be invented.

BR = BR or {}
BR.ReviveKey = {}

local K = BR.Config.ReviveKey

--- Did a native declared BOOL say yes?
---
--- `0` IS TRUTHY IN LUA and a FiveM native declared BOOL hands this state a
--- number on some builds. Ten shipped instances of that in this project. Here it
--- would mean offering to sell keys at an ambulance that does not exist.
--- @param v any
--- @return boolean
local function isTrue(v)
    return v == true or v == 1
end

--- The owner's wording, or an empty table. See config/revivekey.lua.
--- @return table
local function copy()
    return (K and K.copy) or {}
end

-- ---------------------------------------------------------------------------
-- What the squad beacon said
-- ---------------------------------------------------------------------------

--- [serverId] = { x, y, z, held, live } for squadmates who left a key.
---
--- REBUILT WHOLE ON EVERY PUSH, which is what makes it self-clearing: a key that
--- was spent, expired or wiped stops arriving and stops being drawn, with no
--- teardown written anywhere. The push IS the membership list -- the same
--- property client/squadmates.lua's `mates` relies on.
local keys = {}

--- When the last beacon landed.
---
--- THE SERVER GOES QUIET RATHER THAN SENDING AN EMPTY LIST when a squad stops
--- being a squad -- the last mate died, the match ended between two pushes -- so
--- silence longer than a few pushes means "nothing". client/squadmates.lua
--- carries the same clock for the same reason: without it, the last key of a
--- finished match would hang in the world indefinitely.
local lastPush = 0
local STALE_MS = 3500

--- A SECOND HANDLER ON SQUAD_POS, AND THAT IS DELIBERATE.
---
--- client/squadmates.lua has the first, and it owns blips, overhead names and
--- ally grouping. FiveM fans an event to every handler, so this file reads the
--- same push without that file having to grow an accessor, without a load-order
--- dependency between them, and without either being able to break the other by
--- changing what it keeps. The alternative -- exporting `mates` -- would make
--- one file's private cache another file's interface.
RegisterNetEvent(BR.Net.SQUAD_POS)
AddEventHandler(BR.Net.SQUAD_POS, function(list)
    lastPush = GetGameTimer()
    local seen = {}
    for _, m in ipairs(list or {}) do
        -- NEVER OUR OWN ROW. A key belongs to the person it brings back, and
        -- this player is standing up looking at the screen -- so their own key,
        -- if the beacon ever carried one, is not a thing they can act on.
        if m.src ~= BR.State.me.src and type(m.key) == 'table' then
            seen[m.src] = true
            keys[m.src] = m.key
        end
    end
    for src in pairs(keys) do
        if not seen[src] then keys[src] = nil end
    end
end)

-- ---------------------------------------------------------------------------
-- Finding the ambulance
-- ---------------------------------------------------------------------------

--- Model hashes that count, resolved once on first use.
---
--- LAZILY, and through BR.Config.ReviveKey.models() -- which returns
--- BR.Config.Rescue.models -- so the rescue, the heal and this cannot come to
--- mean different things by "ambulance". client/ambheal.lua resolves its copy
--- the same way for the same reason: GetHashKey is not available in every state
--- that loads the shared config.
local modelSet = nil
local function isAmbulance(model)
    if modelSet == nil then
        modelSet = {}
        for _, name in ipairs(K.models()) do
            local h = BR.NormHash(GetHashKey(name))
            if h then modelSet[h] = true end
        end
    end
    return modelSet[BR.NormHash(model)] == true
end

--- The nearest ambulance, or nil.
---
--- GetClosestVehicle, ONE NATIVE PER TICK, which is client/ambheal.lua's choice
--- and its argument: a van is four metres long and you walk up to it, so a ray
--- would add a "you were not quite looking at it" failure to a gesture that has
--- none, and a pool walk is every streamed vehicle ten times a second to answer
--- a question about the one within reach.
---
--- MODEL 0 AND OUR OWN FILTER: passing a hash would make the native answer for
--- only the FIRST model in the list, and the list is allowed to grow.
--- @param x number
--- @param y number
--- @param z number
--- @return integer|nil
local function nearestAmbulance(x, y, z)
    if GetClosestVehicle == nil then return nil end
    local ok, veh = pcall(GetClosestVehicle, x, y, z,
                          (tonumber(K.reachM) or 6.0) + 2.0, 0, 70)
    if not ok or not veh or veh == 0 then return nil end
    if not isTrue(DoesEntityExist(veh)) then return nil end
    if not isAmbulance(GetEntityModel(veh)) then return nil end
    return veh
end

--- The name the server can resolve this vehicle by, or nil.
---
--- ═══ ONE RESOLVER FOR THE PURCHASE AND FOR THE REVIVE ═══
---
--- Both gestures now name the same van to the server, so both ask this. It
--- refuses a vehicle that exists ONLY ON THIS MACHINE: an unnetworked entity is
--- not a shared world object and the server has nothing to look it up by, which
--- client/ambheal.lua refuses the same way for the same reason.
---
--- isTrue ON BOTH READS. DoesEntityExist and NetworkGetEntityIsNetworked are
--- declared BOOL and `0` IS TRUTHY IN LUA -- ten shipped instances of that in
--- this project. Here a bare read would hand the server a net id for a wreck and
--- start a six-second hold at nothing.
--- @param veh integer|nil
--- @return integer|nil
local function netIdOf(veh)
    if not veh or veh == 0 then return nil end
    if not isTrue(DoesEntityExist(veh)) then return nil end
    if NetworkGetEntityIsNetworked ~= nil
       and not isTrue(NetworkGetEntityIsNetworked(veh)) then
        return nil
    end
    local ok, netId = pcall(NetworkGetNetworkIdFromEntity, veh)
    if not ok or not netId then return nil end
    return netId
end

-- ---------------------------------------------------------------------------
-- The plate
-- ---------------------------------------------------------------------------

--- The prompt page.
---
--- SHARED WITH THE CRATE, THE PUMP, THE REVIVE, THE STRETCHER AND THE SHOWROOM.
--- client/fuel.lua's rule: "One browser for every world prompt in the game". A
--- DUI is a whole CEF instance and a sixth one would be a browser per
--- interaction.
local function promptPage()
    return BR.Dui.page('lootprompt', 'nui://br_ui/dui/prompt.html', 512, 256)
end

-- How big the plate over a LOOSE KEY draws.
--
-- client/ambheal.lua's number, matched rather than re-derived, so the sixth
-- consumer of one browser does not draw at a different size to the fifth. It is
-- not a tuning knob and is deliberately not in the config: a plate that looks
-- like the other five is the whole requirement.
--
-- IT IS A SCREEN FRACTION AND IT BELONGS TO drawWorld ALONE. The plate over a
-- key on the ground is still a billboard pinned to a point -- there is nothing
-- there to bolt a sign to -- so it is still sized as a share of the display. The
-- two plates AT A VAN are quads measured in metres now and are sized by
-- BR.Config.ReviveKey.plate.width instead; see the draw pass.
--
-- THE VEHICLE LIFT THAT USED TO SIT BESIDE THIS IS GONE. It was 1.1m above the
-- vehicle ORIGIN, which put the plate at about the roof of an ambulance and is
-- exactly the positioning the owner objected to on 2026-08-31. The height of a
-- plate on a van is derived from that van's own box now (`plateHeight` below),
-- so there is no constant left to keep.
local PROMPT_SCALE = 1.6

-- ═══ AND THE KEY ON THE GROUND IS NOT A VEHICLE ═══
--
-- Owner, in game: "the 'take revive key' DUI over a corpse is way too high off
-- the ground."
--
-- The vehicle lift was being used for all three plates, and the third one hangs
-- off the key's RECORDED z rather than off a van. That z is the corpse's own
-- position at the moment of elimination (server/revivekey.lua copies
-- `entry.pos`), and a ped's root is at its FEET -- config/loot.lua says so where
-- it measures `waistHeight = 0.75` up from it. So the key's z is the ground the
-- body is lying on, and 1.1 above the ground is chest height on a standing man,
-- floating clear of a body lying flat.
--
-- THIS IS THE SECOND TIME THIS EXACT MISTAKE HAS BEEN MADE and the first fix is
-- the number to match. client/dbno.lua's revive plate had it over a downed mate
-- ("at the standing 0.9 it hovered well clear of the player it belonged to",
-- config/match.lua) and was brought to `dbnoPromptLift = 0.35` measured from the
-- HEAD BONE -- which on a body on the floor is, in client/squadmates.lua's
-- words, "a few centimetres of ground clearance". 0.6 off the ground is where
-- that approved plate ends up over the same body, reached from the anchor this
-- file actually has.
--
-- AND IT STAYS UNDER THE CRATE'S. config/loot.lua's `promptLift = 0.75` is
-- written for an item that RISES half a metre when it is offered; a plate over
-- a corpse has nothing to rise with and belongs lower than one that does.
local GROUND_LIFT  = 0.6

-- ---------------------------------------------------------------------------
-- WHERE THE PLATE SITS ON THE VAN
-- ---------------------------------------------------------------------------
--
-- Owner, 2026-08-31: "I don't like the positioning of the 'press E to revive'
-- DUI... What I want is a DUI that shows on the nearest face of the vehicle."
--
-- WHICH FACE IS BR.Dui.drawNearFace's ANSWER AND NOT THIS FILE'S. It is handed
-- the player's position and the van, and works the face out from the model's own
-- box; everything this file owns is the four numbers below. Both halves are read
-- off the model rather than authored against the ambulance, so the day
-- BR.Config.Rescue.models grows a longer van the plate is still on its panel.

--- Model bounding boxes, cached by model hash.
---
--- client/shop.lua's `signOffsets` keeps its own for the same reason and this is
--- deliberately not shared with it: GetModelDimensions is a model-table lookup
--- on a path that runs every frame a plate is up, and the answer is a constant
--- per model. Only the Z span is kept -- the face pick needs the X and Y of the
--- box and asks BR.Dui for it, which has its own cache and is the file that
--- draws the corners.
local DIMS = {}

--- The four numbers that put a plate on a van, with this file's own fallbacks.
---
--- FALLBACKS ON NUMBERS, WHICH IS NOT THE RULE ABOUT WORDS. A missing line of
--- copy draws no plate at all (see the header); a missing distance draws the
--- plate somewhere sensible, because a number nobody has tuned yet is a starting
--- point rather than an invention. `tonumber` on each so a string in the config
--- cannot reach the draw as a string.
--- @return number out, number frac, number lift, number width
local function plateNumbers()
    local p = (K and type(K.plate) == 'table') and K.plate or nil
    return (p and tonumber(p.out)   or 0.35),
           (p and tonumber(p.frac)  or 0.62),
           (p and tonumber(p.lift)  or 0.0),
           (p and tonumber(p.width) or 0.75)
end

--- How high up the van the plate's centre hangs, in metres from its origin.
---
--- BR.ShopSolve.signHeight IS THE DERIVATION, BORROWED RATHER THAN WRITTEN. It
--- is the project's one answer to "how far up a vehicle does a plate hang",
--- argued at length in br_lib/shared/shop_solve.lua against exactly the mistake
--- this round is fixing: one authored height is a saloon's number applied to a
--- monster truck. A second copy of the same lerp here would be a second answer
--- free to drift, and it is a pure function a suite can already execute.
--- @param veh integer
--- @param frac number
--- @param lift number
--- @return number|nil  nil when the model has not answered with a box
local function plateHeight(veh, frac, lift)
    local model = GetEntityModel(veh)
    local d = DIMS[model]
    if not d then
        local a, b = GetModelDimensions(model)
        if not a or not b then return nil end
        d = { bottom = a.z, top = b.z }
        DIMS[model] = d
    end
    return BR.ShopSolve.signHeight(d.bottom, d.top, frac, lift)
end

-- ---------------------------------------------------------------------------
-- THE RULER'S STATE  (/brplate, at the bottom of this file)
-- ---------------------------------------------------------------------------
--
-- ═══ HE OFFERED TO MEASURE IT, SO THE MEASURING HAS TO BE POSSIBLE ═══
--
-- Owner, 2026-08-31: "If you want to make me the tools to manipulate the DUI
-- position then fetch it I can give you the coords."
--
-- THE HARD PART IS NOT THE NUMBERS, IT IS STANDING IN FRONT OF THE PLATE. The
-- revive plate appears only when this player's squad holds a key for a mate who
-- has bled out, which is not a thing anybody can arrange on demand while tuning
-- a distance. So the ruler DRAWS THE PLATE ITSELF at the nearest ambulance, and
-- everything downstream of that -- the face pick, the height derivation, the
-- width, the interface-size preference -- is the shipped path rather than a
-- preview of it. A tool that measured something other than what ships would be
-- worse than no tool.
--
-- DECLARED HERE, ABOVE EVERY PASS THAT READS THEM. A `local` read from a closure
-- built earlier in the file resolves as a GLOBAL -- which is nil, which does not
-- error, which silences a whole loop band after five throws.
-- tools/check_forward_locals.lua exists because that has cost two playtest
-- rounds.

--- Is the ruler drawing its own plate right now? Set by /brplate on|off.
local tuning = false

--- The van it has picked, refreshed on the tick band; nil when none is in reach.
local tuneVeh = nil

--- Which face the last plate at a van went on, in that van's own axes, exactly
--- as BR.Dui.drawNearFace reported it. NOTHING BUT THE READOUT READS THIS -- it
--- is an instrument's output, not a decision anything is taken on.
local faceX, faceY = nil, nil

--- Is the plate on screen the ruler's preview rather than a real offer?
---
--- READ BY BR.ReviveKey.prompting BELOW, which client/dbno.lua uses to suppress
--- crate prompts. Without this a dev command left running would quietly turn the
--- loot prompts off around every ambulance, and the report would be about loot.
local previewing = false

-- Sent on change only, exactly like the crate's and the stretcher's: a re-send
-- restarts the ring animation from zero, so a hold already running is left
-- alone. See client/dbno.lua's #129 note -- a full ring is evidence that
-- setPrompt was called and evidence of nothing else at all.
local shownKey = nil

--- Draw or clear the plate.
--- @param what table|nil  { mode, label, hint, ring, holdMs, id }
local function setPrompt(what)
    -- ═══ THE NO-OP CASES RETURN BEFORE THE PAGE IS ASKED FOR ═══
    --
    -- BR.Dui.page CREATES the browser. This function is called from a pass that
    -- runs every frame for every player in the match, and the answer on almost
    -- all of them is "nothing, same as last time" -- so asking for the page first
    -- would build a CEF instance for every player in the game whether or not
    -- they ever stand over a body.
    local k = what and table.concat(
        { what.mode, tostring(what.id), tostring(what.holdMs) }, ':') or nil
    if k == shownKey then return end
    shownKey = k

    local page = promptPage()

    if not what then
        BR.Dui.send(page, { t = 'prompt', show = false })
        return
    end

    BR.Dui.send(page, {
        t     = 'prompt',
        show  = true,
        label = what.label,
        hint  = what.hint,
        -- ═══ THE KEY GLYPH IS OFFERED ONLY WHERE THERE IS A PRESS ═══
        --
        -- The revive is a hold and the purchase is a press, so both name the
        -- player's own binding -- asked for by COMMAND rather than by control,
        -- which is client/loot.lua's fix for every prompt saying E after a
        -- rebind. The loose key is NEITHER: collection is a proximity test the
        -- server runs on its own samples, so that plate carries no glyph and
        -- prompt.html hides the badge when `key` is absent. A key cap on a plate
        -- with nothing to press is a lie the player would act on.
        key    = what.press and BR.Native.keyLabelForCommand(
                     'brinteract', BR.Config.Loot.promptControl or 51) or nil,
        -- The danger colour, matching client/dbno.lua's revive plate and for its
        -- reason: these are the world prompts that are about a PERSON rather
        -- than an object.
        colour = '#F87171',
        ring   = what.ring or false,
        holdMs = what.holdMs,
    })
end

-- ---------------------------------------------------------------------------
-- Deciding what is on offer
-- ---------------------------------------------------------------------------

--- Set by client/dbno.lua while it owns the interact key.
local yielded = false

--- Yield the prompt and the key to the downed-mate revive.
---
--- CALLED FROM client/dbno.lua's ONE frame pass, nil-guarded at the call site --
--- the same shape in which four files ask BR.Rescue.riding() from above the file
--- that answers, so the load order between the two does not matter.
---
--- WHY THAT DIRECTION. A mate who is DOWNED can still be saved outright, keeps
--- their inventory and costs the squad nothing; a mate who is OUT costs a key
--- and comes back empty. If a body and a knock are within reach of the same
--- player, the knock is the better act, so this file stands down rather than
--- teaching that one about keys.
--- @param on boolean
function BR.ReviveKey.yield(on)
    yielded = (on == true)
end

--- Is one of this file's plates on screen right now?
---
--- READ BY client/dbno.lua, which owns the single BR.Loot.suppress() call site.
--- A corpse is ringed with scattered loot by construction, so without this every
--- revive plate would be fighting a crate plate for the same browser and the
--- same key.
---
--- THE RULER'S PREVIEW IS NOT AN OFFER, and this is the one place that matters:
--- a plate drawn by /brplate is a picture of a plate, there is no press behind
--- it, and it must not take the crate prompts down around every ambulance for as
--- long as somebody leaves the tool on.
--- @return boolean
function BR.ReviveKey.prompting()
    return shownKey ~= nil and not previewing
end

--- What this player could act on right now, decided once per tick.
--- { mode = 'revive'|'take'|'buy', id, x, y, z, veh }
local cand = nil

--- { target = serverId, from = ms } while this player is holding for a revive.
---
--- DECLARED HERE, ABOVE THE TICK PASS THAT CLEARS IT AND ABOVE THE FRAME PASS
--- THAT SETS IT. A `local` read from a closure built earlier in the file
--- resolves as a GLOBAL -- which is nil, which does not error, which silences a
--- whole loop band after five throws. tools/check_forward_locals.lua exists
--- because that has cost two playtest rounds.
local holding = nil

--- Throttle on the re-assertion of a running hold.
local ASK_EVERY_MS = 250
local lastAsk = 0

--- Throttle on the purchase, so a mashed key cannot queue three round trips.
local lastBuy = 0

--- The cheap half of the decision: can this player act on anything at all?
---
--- SPLIT OUT SO THE AMBULANCE SCAN IS NEVER PAID FOR BY SOMEBODY WHO COULD NOT
--- USE ONE -- client/ambheal.lua's argument, and it is stronger here because the
--- overwhelmingly common answer is "this player's squad has nobody down".
--- @return boolean
local function eligible()
    if not K or K.enabled ~= true then return false end
    if yielded then return false end
    if BR.State.match.state ~= BR.MatchState.PLAYING then return false end
    if BR.State.me.state ~= BR.PlayerState.ALIVE then return false end
    if not BR.State.me.squadId then return false end
    -- NOTHING TO DO. `next` rather than a count: this is the answer on almost
    -- every pass and it must cost one comparison.
    if next(keys) == nil then return false end
    if GetGameTimer() - lastPush > STALE_MS then return false end
    -- ON A STRETCHER OR IN THE BACK OF A RESCUE, THIS PLAYER IS NOT WALKING
    -- ANYWHERE. Both asked nil-guarded at call time, so neither file has to be
    -- above this one for the loader.
    if BR.AmbHeal and BR.AmbHeal.healing and BR.AmbHeal.healing() then return false end
    if BR.Rescue and BR.Rescue.riding and BR.Rescue.riding() then return false end
    -- NOT FROM A CAR. You walk to a body; you do not drive over one and press a
    -- button. client/loot.lua and client/ambheal.lua both make the same call.
    return not isTrue(IsPedInAnyVehicle(PlayerPedId(), false))
end

--- Pick what to offer.
---
--- ═══ THE ORDER IS THE WHOLE OF THE ARBITRATION ═══
---
---   1. REVIVE beats everything. A key the squad already owns, and an ambulance
---      within reach, is the act this feature exists for.
---   2. TAKE next. Something on the ground worth pressing for.
---   3. BUY last, and only when neither of the above is on offer -- if a squad
---      can bring somebody back right now, that is the thing to be told about,
---      not the price of the key they have not fetched.
---
--- ═══ AND THERE IS NO REVIVE PLATE AT A BODY. THAT IS THE POINT OF THE ROUND ═══
---
--- "the press e to revive DUI when standing at the ped should not show once
--- they've bled out. The only option at that point is the ambulance." -- the
--- owner, 2026-08-30. It is true here by CONSTRUCTION rather than by a guard:
--- the revive branch cannot produce a candidate without a vehicle handle, and
--- the only thing that produces one is `nearestAmbulance`. There is no
--- combination of positions that draws a revive plate over a corpse.
---
--- ═══ MORE THAN ONE MATE DOWN: THE ONE WHO HAS BEEN OUT LONGEST ═══
---
--- The keys are all at one van now, so "nearest" has stopped meaning anything
--- and the plate has to name somebody. FIRST MINTED WINS -- `rec.mintedAt`, which the
--- squad beacon carries for this. It is the only tie-break of the three that a
--- player can predict from what they can see: the mate who died first comes back
--- first, and the squad works down the list. (Ties, which are two eliminations
--- inside one server frame, fall to the lower server id so the answer is stable
--- rather than pairs()-order.)
---
--- ONE ANSWER, HELD, AND THE PRESS ACTS ON IT. client/loot.lua's #128 lesson
--- applied before it costs anything: the prompt and the claim used to resolve
--- independently there, and with two crates in reach a player pressed while
--- looking at one and took the other.
--- @param px number
--- @param py number
--- @return table|nil
local function choose(px, py)
    -- THE TIGHT NUMBERS, NOT THE SERVER'S. config/revivekey.lua adds its slack
    -- on the ruling side only, so there is no position at which a plate is
    -- absent and the server would have allowed the press -- the divergence only
    -- ever runs the forgiving way. client/fuel.lua's header records what the
    -- other direction costs.
    local takeReach = tonumber(K.collectM) or 2.5

    -- ONE WALK OF THE SQUAD'S KEYS, ANSWERING ALL THREE QUESTIONS. What is
    -- owned and oldest, whether anything is still owed, and whether a loose one
    -- is under our feet.
    local heldSrc, heldAt = nil, nil
    local takeSrc, takeD, takeRec = nil, nil, nil
    local owed = false

    for src, rec in pairs(keys) do
        if rec.held == true then
            local mintedAt = tonumber(rec.mintedAt) or 0
            if heldSrc == nil or mintedAt < heldAt
               or (mintedAt == heldAt and src < heldSrc) then
                heldSrc, heldAt = src, mintedAt
            end
        else
            owed = true
            if rec.live == true then
                local d = BR.Dist(px, py, rec.x, rec.y)
                if d <= takeReach and (takeD == nil or d < takeD) then
                    takeSrc, takeD, takeRec = src, d, rec
                end
            end
        end
    end

    -- ═══ THE AMBULANCE, PAID FOR ONCE AND ONLY WHEN IT COULD MATTER ═══
    --
    -- GetClosestVehicle is the one native this pass spends, and it is skipped
    -- entirely for a squad that has nothing held and nothing owed -- which,
    -- `eligible()` having already refused everybody with no keys at all, is a
    -- squad whose only key is the one under this player's feet.
    local veh, vc = nil, nil
    if heldSrc or owed then
        -- YIELD TO THE STRETCHER. Both plates would be drawn at the same van and
        -- both handlers would act on one press, so a hurt player behind an
        -- ambulance with a mate down would heal AND spend 25 Volts, or heal AND
        -- start a revive. The heal is the one that was there first and the one
        -- with a rear-arc test behind it, so this stands down. The residual cost
        -- is that neither ambulance plate is offered at the TAILGATE while hurt;
        -- walking round to the wing offers both, because the heal has an arc and
        -- this does not.
        if not (BR.AmbHeal and BR.AmbHeal.prompting and BR.AmbHeal.prompting()) then
            local c = GetEntityCoords(PlayerPedId())
            veh = nearestAmbulance(c.x, c.y, c.z)
            if veh then
                vc = GetEntityCoords(veh)
                if BR.Dist(c.x, c.y, vc.x, vc.y) > (tonumber(K.reachM) or 6.0) then
                    veh, vc = nil, nil
                end
            end
        end
    end

    if heldSrc and veh then
        return { mode = 'revive', id = heldSrc, veh = veh,
                 x = vc.x, y = vc.y, z = vc.z }
    end

    if takeSrc then
        return { mode = 'take', id = takeSrc,
                 x = takeRec.x, y = takeRec.y, z = takeRec.z }
    end

    -- ═══ THE PURCHASE ═══
    --
    -- Offered when this squad has ANY key it does not yet own -- including one
    -- whose pickup has expired, which is the whole point of the 25 Volts: "The
    -- pickup expires on a timer... They can still purchase the revive keys at an
    -- ambulance" is one sentence, and the second half is what this plate is.
    if owed and veh then
        return { mode = 'buy', id = veh, veh = veh, x = vc.x, y = vc.y, z = vc.z }
    end

    return nil
end

BR.Loop.register(BR.Loop.TICK, 'revivekey.scan', function()
    if not eligible() then
        -- ═══ THE TEARDOWN IS A LEVEL TEST, NOT AN EDGE HANDLER ═══
        --
        -- client/shop.lua's argument, and it applies to every one of the ways
        -- this can stop being live: the match ending, the player dying, being
        -- knocked, getting into a car, the squad's last key being spent,
        -- client/dbno.lua taking the key. Comparing want against have costs one
        -- comparison a tick and has no cases; hanging the cleanup off a
        -- particular transition leaves every case that is not that transition to
        -- a handler that did not run.
        --
        -- THE STOP IS SENT RATHER THAN ASSUMED. The server expires a quiet hold
        -- inside reviveBeatMs anyway, so this is not load-bearing for
        -- correctness -- it is what makes the reviver's ring come down at once
        -- instead of up to a second later.
        if holding then
            TriggerServerEvent(BR.Net.REVIVEKEY_STOP)
            holding = nil
        end
        cand = nil
        -- THE RULER OUTLIVES ELIGIBILITY, AND IT HAS TO. Almost nobody tuning
        -- this is eligible -- it needs a squadmate who has bled out -- so the
        -- preview is drawn from the frame pass below in exactly the state this
        -- branch is written for. Clearing the plate here as well would leave the
        -- two passes sending `show:false` and `show:true` at each other ten
        -- times a second.
        if not tuning then setPrompt(nil) end
        return
    end
    local c = GetEntityCoords(PlayerPedId())
    cand = choose(c.x, c.y)
end)

-- ---------------------------------------------------------------------------
-- The hold
-- ---------------------------------------------------------------------------

--- The reviver's own ring, and the two words that end a hold.
---
--- THE RING IS NOT DRIVEN BY THIS. br_ui/dui/prompt.html runs a one-shot CSS
--- animation from a single "a hold began, it lasts N ms" message, so it fills on
--- schedule whatever the server thinks. What this handler is for is the ENDING:
--- `cancelled` and `done` are the only way this side learns that a hold it is
--- still asking for has stopped meaning anything.
RegisterNetEvent(BR.Net.REVIVEKEY_PROGRESS)
AddEventHandler(BR.Net.REVIVEKEY_PROGRESS, function(d)
    if type(d) ~= 'table' then return end
    if not holding or d.target ~= holding.target then return end
    if d.cancelled or d.done then
        holding = nil
        -- NOT `lastAsk = 0`. A cancel is the server saying no; re-arming is the
        -- frame loop's job and it must stay on the 250ms leash, or a refusal the
        -- player is holding through becomes a per-frame conversation.
        -- client/dbno.lua's note, and the same failure.
    end
end)

BR.Loop.register(BR.Loop.FRAME, 'revivekey.hold', function()
    local c = cand

    -- ═══ A HOLD IS A LEVEL, NOT AN EDGE ═══
    --
    -- client/dbno.lua's second-revive bug, avoided by construction rather than
    -- inherited: `holding` used to be created only in a key-DOWN listener there,
    -- so anything that ENDED a hold left the player leaning on a key that no
    -- longer meant anything until they let go and pressed again -- and a
    -- completed revive is exactly that. Here the arm is a level test in this
    -- pass, so the frame after a hold ends can start the next one.
    --
    -- A TARGET WE CANNOT SEE THIS FRAME IS NOT A RELEASE, WHICH IS #163. The
    -- reach test is the strictest thing in the interaction; the SERVER re-checks
    -- it every 250ms from its own samples and cancels for real. This side ends a
    -- hold for the two things it is the sole witness to: the key coming up, and
    -- the player deliberately switching to a different mate.
    if holding and not BR.Keys.isHeld('interact') then
        TriggerServerEvent(BR.Net.REVIVEKEY_STOP)
        holding = nil
    elseif holding and c and c.mode == 'revive' and c.id ~= holding.target then
        TriggerServerEvent(BR.Net.REVIVEKEY_STOP)
        holding = nil
    end

    if not holding and c and c.mode == 'revive' and BR.Keys.isHeld('interact') then
        -- THE VAN IS NAMED AT THE ARM AND RE-NAMED ON EVERY BEAT, because the
        -- server rules the distance against it every 250ms and puts the arrival
        -- 150m above it. A hold with no net id is a hold the server cannot rule
        -- at all, so it is not started: `netIdOf` returns nil for an ambulance
        -- that exists only on this machine, which is not a shared world object
        -- and which the server could never resolve.
        local n = netIdOf(c.veh)
        if n then
            holding = { target = c.id, from = GetGameTimer(), veh = c.veh, n = n }
        end
    end

    if holding then
        -- THE HOLD IS RE-ASSERTED, NOT ANNOUNCED ONCE. A brief tap completed a
        -- whole revive in playtest on the DBNO path (owner, 2026-08-09) because
        -- the STOP was raised and did not land. Progress requires CONTINUOUS
        -- evidence: the server expires a hold it has not heard about inside
        -- reviveBeatMs, so silence stops it and a lost STOP costs a fraction of
        -- a second instead of the whole interaction.
        --
        -- Throttled on `lastAsk` rather than on anything inside `holding`, which
        -- is rebuilt whenever a hold re-arms -- a throttle that died with it
        -- would be no throttle at all.
        local now = GetGameTimer()
        if now - lastAsk >= ASK_EVERY_MS then
            lastAsk = now
            -- THE VAN GOES WITH EVERY BEAT, RE-READ RATHER THAN REMEMBERED. A
            -- player who walks from one ambulance to another mid-hold is ruled
            -- against the one they are at now; a vehicle that was destroyed
            -- under them stops resolving and the server cancels for real.
            local n = (c and c.mode == 'revive' and c.id == holding.target
                       and netIdOf(c.veh)) or holding.n
            holding.n = n
            TriggerServerEvent(BR.Net.REVIVEKEY_START,
                { target = holding.target, n = n })
        end
    end

    -- ═══ WHAT IS ON THE PLATE ═══
    local C = copy()
    -- Cleared every frame and set by the one branch that draws a preview, so
    -- "is this a real offer" is a fact about THIS frame rather than a flag
    -- somebody has to remember to take back down.
    previewing = false
    if holding then
        local e = BR.State.roster[holding.target]
        setPrompt(C.revive and {
            mode   = 'revive',
            id     = holding.target,
            -- THE SUBJECT IS THE PERSON AND THE VERB IS THE OWNER'S LINE, which
            -- is client/loot.lua's split followed by dbno.lua, ambheal.lua and
            -- shop.lua. `label` is the mate's name -- exactly what dbno.lua's
            -- revive plate puts there -- and it is not new copy: it is a name
            -- the roster already holds. A mate whose row has not arrived draws
            -- no plate rather than a placeholder word.
            label  = e and e.name or nil,
            hint   = C.revive,
            press  = true,
            ring   = true,
            holdMs = math.floor(tonumber(K.reviveHoldMs) or 6000),
        } or nil)

    elseif c == nil then
        -- ═══ THE RULER'S PREVIEW, AND IT ONLY EVER SPEAKS INTO SILENCE ═══
        --
        -- Offered exactly where this pass would otherwise have cleared the
        -- plate, so there is still ONE writer to the browser and a real offer
        -- always wins. Nothing above this line changed to make room for it.
        --
        -- IT SPEAKS THE OWNER'S OWN LINE AND INVENTS NOTHING. `C.revive` is the
        -- plate being tuned, so the ruler shows the plate that ships; a preview
        -- with wording of its own would be a seventh string. There is no `label`
        -- because a label is a MATE'S NAME and there is no mate -- the same nil
        -- the real plate draws while a roster row is still in flight.
        if tuning and tuneVeh then
            previewing = true
            setPrompt(C.revive and {
                mode = 'tune', id = tuneVeh,
                hint = C.revive, press = true, ring = true,
            } or nil)
        else
            setPrompt(nil)
        end

    elseif c.mode == 'revive' then
        local e = BR.State.roster[c.id]
        setPrompt(C.revive and {
            mode = 'revive', id = c.id,
            label = e and e.name or nil, hint = C.revive, press = true,
            -- ═══ THE RING IS THE RESTING STATE, NOT THE PRESSED ONE ═══
            --
            -- Owner, 2026-08-31: "I want it by default to draw the empty circle
            -- around the E instead of a glyph that changes to the circle when
            -- pressed."
            --
            -- `ring` WITH NO `holdMs` IS ALREADY A STATE THE PAGE HAS, and that
            -- is the whole of the change: dui/prompt.html shows the ring, puts
            -- the key cap inside it and calls stopHold(), which leaves the fill
            -- at its full dash offset -- an empty circle round the E. The hold
            -- branch above sends the same plate WITH a duration, and because
            -- `holdMs` is part of setPrompt's change key that transition is a
            -- real message, so the fill animates from empty on the press and
            -- returns to empty on the release.
            --
            -- IT DOES NOT SPREAD TO THE OTHER TWO. The loose key and the
            -- purchase are single presses with nothing to fill, and a ring on a
            -- plate with no duration behind it would be an interface promising a
            -- hold that does not exist.
            ring   = true,
        } or nil)

    elseif c.mode == 'take' then
        local e = BR.State.roster[c.id]
        -- `press` NOW, SO A KEY CAP. This plate used to carry none, because
        -- collection was a proximity test the server ran on its own samples --
        -- and the owner walked over a key and never knew: "I somehow picked up
        -- the dead player's key by walking up to them without seeing a DUI or
        -- pressing anything" (2026-08-30). A plate with no glyph on a thing that
        -- takes itself is the interface agreeing with the bug.
        setPrompt(C.take and {
            mode = 'take', id = c.id,
            label = e and e.name or nil, hint = C.take, press = true,
        } or nil)

    elseif c.mode == 'buy' then
        setPrompt(C.buy and {
            mode = 'buy', id = c.id,
            -- THE AMBULANCE'S OWN MAP LABEL, which is what
            -- BR.Config.AmbHeal.label() already reads and already draws on the
            -- stretcher plate at this same vehicle. Borrowed rather than
            -- written, so the van is called one thing in both places. Nil-guarded
            -- because this file must keep drawing if the heal half is ever
            -- pulled, and a plate with a verb and no subject is still readable.
            label = BR.Config.AmbHeal and BR.Config.AmbHeal.label
                    and BR.Config.AmbHeal.label() or nil,
            hint  = C.buy,
            press = true,
        } or nil)
    end
end)

--- The plate ON A VAN, on whichever face the player is nearest to.
---
--- ═══ drawNearFace, NOT drawWorld -- WHICH IS THE ROUND ═══
---
--- Owner, 2026-08-31: "I don't like the positioning of the 'press E to revive'
--- DUI... What I want is a DUI that shows on the nearest face of the vehicle."
---
--- drawWorld is SetDrawOrigin + DrawSprite: a point projected to the screen with
--- the plate then sized in SCREEN fractions, so it was a billboard hanging over
--- the roof that held the same share of the display from any distance. This
--- draws a quad in the world in METRES, squared to the van's own heading and
--- level with the horizon, standing off the panel the player is nearest to.
--- client/shop.lua made the same move for the same complaint (#236) and
--- BR.Dui.drawNearFace is that function's basis and quad with one different
--- direction.
---
--- WHICH FACE IS ABOUT WHERE THE PLAYER IS STANDING, NOT WHERE THE CAMERA IS
--- POINTING. He asked for the face he is closest to; a plate that moved to the
--- other side of the van because the mouse swung round would be a plate that
--- will not hold still while it is read.
--- @param page table
--- @param veh integer
local function drawOnVan(page, veh)
    -- RE-CHECKED, because a vehicle can be destroyed between two frames and
    -- reading a dead handle's coordinates throws -- which in a frame callback
    -- costs the whole band after five of them.
    if not isTrue(DoesEntityExist(veh)) then return end

    local out, frac, lift, width = plateNumbers()
    local oz = plateHeight(veh, frac, lift)
    -- A MODEL THAT HAS NOT ANSWERED DRAWS NOTHING FOR A FRAME. Better than a
    -- plate at a guessed height on the frame the van streams in.
    if not oz then return end

    local p = GetEntityCoords(PlayerPedId())
    faceX, faceY = BR.Dui.drawNearFace(page, veh, p.x, p.y, out, oz, width)
end

--- ...and drawing it, which has to be per frame.
---
--- A DrawSprite and a DrawSpritePoly both last exactly one frame. The pass above
--- decides WHAT; this decides WHERE, sixty times a second, so the plate is
--- welded to the van however fast the camera moves.
BR.Loop.register(BR.Loop.FRAME, 'revivekey.draw', function()
    -- NOTHING IS ASKED FOR BEFORE THERE IS SOMETHING TO DRAW. promptPage() would
    -- CREATE the browser, and a player who never stands over a body should never
    -- pay for a CEF instance this file did not need -- the page is shared, so
    -- whichever consumer asks first builds it and this one has no reason to be
    -- that consumer.
    if shownKey == nil then return end
    local page = promptPage()

    -- A HOLD IS DRAWN AT ITS OWN VAN, not at the key's point on the ground. The
    -- ring belongs to the ambulance the hold is being performed at, and that is
    -- also the only thing still on screen while it runs -- the body may be a
    -- kilometre away.
    if holding then
        drawOnVan(page, holding.veh)
        return
    end

    local c = cand
    if not c then
        -- THE RULER'S PREVIEW. Only reachable when the pass above put a plate up
        -- with no candidate behind it, which is the one thing that does that.
        if tuning and tuneVeh then drawOnVan(page, tuneVeh) end
        return
    end
    if c.veh then
        -- BOTH AMBULANCE PLATES, ON THE SAME FACE, THROUGH THE SAME CALL -- the
        -- revive and the purchase. `choose` returns exactly one candidate and
        -- the revive beats the buy, so the two are never on screen together and
        -- cannot overlap; drawing them in two different places would only mean
        -- the plate jumped from the roof to the bodywork the instant a squad
        -- paid its 25 Volts.
        drawOnVan(page, c.veh)
    else
        -- THE GROUND LIFT, NOT THE VEHICLE ONE. This is the loose key, and
        -- `c.z` is the ground the body it fell from is lying on -- see
        -- GROUND_LIFT above for why the two numbers cannot be the same one.
        BR.Dui.drawWorld(page, c.x, c.y, c.z + GROUND_LIFT, PROMPT_SCALE)
    end
end)

-- ---------------------------------------------------------------------------
-- THE MARKER ON THE GROUND, WHERE THE BODY IS NO LONGER
-- ---------------------------------------------------------------------------
--
-- Owner, 2026-08-31: "After a player has bled out, their ped should become
-- invisible. Only the 3dmarker (type 24) and DUI should be shown at their
-- position. I like the blip though - let's keep that."
--
-- ═══ WHY THE MARKER IS PART OF HIDING THE PED, NOT A DECORATION BESIDE IT ═══
--
-- The corpse was load-bearing and nothing said so. It was the only thing in the
-- WORLD that marked where the key was: the blip is a dot on a minimap and the
-- take plate does not exist until `collectM`, which is 2.5 metres. Hide the body
-- and the plate becomes a thing you find by walking over unmarked ground. So
-- this is the world-space half of what the corpse used to do, and the owner named
-- the two in one sentence for that reason.
--
-- ═══ THE SAME POINT THE PLATE USES, AND FOR THE SAME ARGUMENT ═══
--
-- `rec.x/y/z` off the squad beacon -- the SERVER'S OWN NUMBERS, the ones the take
-- ruling is measured against, which is the whole of this file's header. It is
-- emphatically NOT the ped: that ped is now invisible, and even when it was not,
-- "a corpse's position is a death ragdoll -- the one thing this file already
-- knows do not replicate reliably". A marker anchored to it would sit somewhere
-- different on every screen while the server ruled against a fixed point.
--
-- So the chevron and the plate are drawn from ONE pair of coordinates, and the
-- thing a player walks to is the thing the server will accept.
--
-- ═══ ITS OWN PASS, NOT A BRANCH OF THE PLATE'S ═══
--
-- The plate draws ONE candidate -- the key `choose` picked, at 2.5m, for a player
-- who is ALIVE, on foot and eligible. This draws EVERY key the squad still has
-- outstanding, out to `drawM`, with none of those conditions: a squadmate driving
-- to the body must see where they are going, and `eligible()` refuses anybody in
-- a vehicle. Hanging it off `cand` would have made the marker appear exactly when
-- it had stopped being needed.
--
-- WHAT IT IS GATED ON IS THE SAME THING THE BLIP IS: membership and staleness.
-- `keys` is rebuilt whole on every push and the server goes quiet rather than
-- sending an empty list, so a key that was spent, taken or expired stops arriving
-- and stops being drawn -- with no teardown written anywhere, exactly as the
-- header says. There is nothing here that can leave a marker on the ground.
--
-- A KEY THAT IS HELD OR NO LONGER LIVE DRAWS NOTHING, which is the same pair of
-- fields `choose` reads to decide there is a plate. Once the squad owns the key
-- the place it was dropped means nothing -- the act moved to an ambulance -- and
-- once the pickup has expired there is nothing at the body to walk to at all. The
-- blip stays in both cases, and that is the owner's answer to where a mate went
-- down: he asked to keep it.
local M = (K and type(K.marker) == 'table') and K.marker or nil

BR.Loop.register(BR.Loop.FRAME, 'revivekey.marker', function()
    -- NO BLOCK, NO MARKER. An absent config table is a feature nobody has
    -- configured rather than one to invent numbers for; individual numbers below
    -- do fall back, which is `plateNumbers`' split and the same reasoning.
    if not M then return end
    if not K or K.enabled ~= true then return end

    -- THE CHEAP REFUSALS FIRST, in `eligible()`'s order and for its reason: on
    -- almost every frame of almost every match this squad has no outstanding
    -- key, and that answer must cost one comparison.
    if next(keys) == nil then return end
    if GetGameTimer() - lastPush > STALE_MS then return end

    local kind  = math.tointeger(tonumber(M.kind)) or 24
    local size  = tonumber(M.size) or 0.8
    local tall  = tonumber(M.height) or 0.4
    local lift  = tonumber(M.lift) or 0.06
    local reach = tonumber(M.drawM) or 120.0
    -- `~= false` RATHER THAN `== true`: an unset knob keeps the shipped
    -- behaviour, and only an explicit `false` turns the spin off.
    local spin  = M.rotate ~= false

    local col = (type(M.colour) == 'table') and M.colour or {}
    local cr = math.tointeger(tonumber(col.r)) or 248
    local cg = math.tointeger(tonumber(col.g)) or 113
    local cb = math.tointeger(tonumber(col.b)) or 113
    local ca = math.tointeger(tonumber(col.a)) or 140

    -- MEASURED FROM THE PED AND NOT FROM BR.Spectate.watchPoint(). A spectator
    -- has no key of their own in this table -- the beacon handler drops our own
    -- row -- and the bodies they are watching belong to a squad they are still
    -- in, so drawing round the camera would put chevrons on a screen whose owner
    -- cannot walk to any of them. The player is who this is for.
    local p = GetEntityCoords(PlayerPedId())

    for _, rec in pairs(keys) do
        if rec.live == true and rec.held ~= true then
            local rx, ry = tonumber(rec.x), tonumber(rec.y)
            local rz = tonumber(rec.z)
            if rx and ry and rz and BR.Dist(p.x, p.y, rx, ry) <= reach then
                -- LIFTED OFF THE GROUND BY A FEW CENTIMETRES. `rec.z` is the
                -- ground the body was lying on, and a marker drawn exactly on it
                -- z-fights the terrain -- which reads as the marker flickering
                -- rather than as a number being wrong.
                DrawMarker(kind, rx, ry, rz + lift,
                    0.0, 0.0, 0.0,
                    0.0, 0.0, 0.0,
                    size, size, tall,
                    cr, cg, cb, ca,
                    false, false, 2, spin, nil, nil, false)
            end
        end
    end
end)

-- ---------------------------------------------------------------------------
-- The two presses: taking one off the ground, and buying the lot
-- ---------------------------------------------------------------------------

--- The press that takes a key, and the press that spends 25 Volts.
---
--- ═══ IT ACTS ON WHAT WAS DRAWN, NOT ON A FRESH SEARCH ═══
---
--- `cand` and not a new scan, which is client/ambheal.lua's reading of
--- client/loot.lua's #128: the prompt and the claim used to resolve
--- independently and a player pressed while looking at one crate and took
--- another. Two ambulances parked at a station is the same picture, and so are
--- two bodies in one doorway.
---
--- ═══ AND IT IS INERT UNLESS ONE OF THOSE PLATES IS THE ONE ON SCREEN ═══
---
--- `cand.mode` is the whole guard, and it is what keeps this handler out of the
--- way of the other five listeners on this key: the same press that starts a
--- revive hold, opens a crate or boards a stretcher reaches here too, and finds
--- a mode it does not act on. The REVIVE is not here at all -- it is a HOLD, and
--- a hold is a level test in the frame pass above rather than an edge.
BR.Keys.on('interact', function(pressed)
    if not pressed then return end

    local c = cand
    if not c then return end
    if shownKey == nil then return end

    -- A MASHED KEY MUST NOT QUEUE ROUND TRIPS. The server refuses a second
    -- purchase while one is in flight -- and refuses it silently, by design --
    -- so without this a player leaning on the key would fire a request every
    -- frame the edge repeated and learn nothing from any of them. The take
    -- shares the throttle: it is the same finger and the same silence.
    local now = GetGameTimer()
    if now - lastBuy < 1000 then return end

    if c.mode == 'take' then
        lastBuy = now
        -- THE INTENT AND NOTHING ELSE. Which mate -- the one thing the server
        -- cannot see. Every other clause of "I was standing on it" is re-derived
        -- from the server's own samples in BR.ReviveKey.canTake.
        TriggerServerEvent(BR.Net.REVIVEKEY_TAKE, { target = c.id })

    elseif c.mode == 'buy' then
        local netId = netIdOf(c.veh)
        if not netId then return end
        lastBuy = now
        TriggerServerEvent(BR.Net.REVIVEKEY_BUY, { n = netId })
    end
end)

-- ---------------------------------------------------------------------------
-- Coming back
-- ---------------------------------------------------------------------------
--
-- ═══ THE OWNER'S SEQUENCE, ON THE MACHINE THAT CAN PERFORM IT ═══
--
--   "their screen should fade to black, set focus to the area where the
--    ambulance I just used is, process the revive, give them a parachute, put
--    them 150m above the ambulance, then fade in. And now they're back in the
--    match."  -- 2026-08-30.
--
-- IT ARRIVES AS TWO MESSAGES BECAUSE THE BLACK HAS TO COME FIRST. The server
-- sends REVIVEKEY_ARRIVE the moment the hold completes and then does NOTHING for
-- `fadeMs + focusMs`, so steps 1 and 2 happen here while the ledger is still
-- untouched; REVIVEKEY_PLACE is the rest of it, and everything it does happens
-- behind a screen that is already black.
--
-- NOTHING HERE IS WRITTEN TWICE. The fade in is BR.Spawn.reveal(), the focus is
-- BR.Spawn.focusOn/focusRelease, the resurrection is BR.Spawn.reviveAt and the
-- parachute is skydive.lua's whole drop machine, entered by the same
-- `br:drop:begin` the bus uses. This file supplies coordinates and an order.

--- What we were promised, and when. nil when nothing is arriving.
local arriving = nil

--- Is this client inside the deliberate black of a revive arrival?
---
--- READ BY client/spawn.lua's `spawn.antiblack` WATCHDOG AND BY NOTHING ELSE.
--- That watchdog fades the screen back in after two consecutive SLOW ticks find
--- it dark, and it already stands down for the two other deliberate blacks in
--- this codebase -- `BR.Spawn.traveling` and `BR.Rescue.riding()`. The arrival
--- is a third: ARRIVE fades out, the server then holds REVIVEKEY_PLACE for
--- `fadeMs + focusMs` (1400ms) plus stepper granularity and a round trip, so the
--- dark window runs about 1.45-1.75s against a 1000ms tick. Two ticks land
--- inside a window that long often enough that the owner would have seen his own
--- corpse fade in and then been snapped 150m into the air with the screen
--- already up -- which is the exact sequence the black exists to hide.
---
--- IT STANDS DOWN RATHER THAN THE ARRIVAL GIVING UP ITS FADE, which is the rule
--- the rescue-ride exemption above it is written to: a recovery mechanism must
--- never undo a deliberate fade. Safe because this black is bounded at both ends
--- -- `BR.Spawn.reveal()` on the happy path, and `endArrival`'s own deadline
--- watchdog when the message never comes -- so there is nothing here for the
--- watchdog to rescue that the arrival does not already resolve itself.
--- @return boolean
function BR.ReviveKey.arriving()
    return arriving ~= nil
end

--- How long the black may last before this client lifts it on its own.
---
--- THE DEADLINE IS THE ESCAPE, NOT THE PLAN -- client/spawn.lua's rule for its
--- own 9s placement escape. The server withdraws a promise it cannot keep
--- (REVIVEKEY_ARRIVE with `cancelled`), but a message that never arrives cannot
--- withdraw anything: a match that ends, a resource that restarts, a dropped
--- packet. Without this the subject sits on a black screen with the streaming
--- focus parked on a van, and nothing in the game ever takes either back.
--- @return integer
local function arriveMaxMs()
    return (math.floor(tonumber(K and K.fadeMs) or 400)
          + math.floor(tonumber(K and K.focusMs) or 1000)) + 5000
end

--- Give the screen and the focus back, however the arrival ended.
---
--- ON EVERY ENDING, which is client/spawn.lua's releaseFocus rule arrived at
--- from the same direction: this takes two pieces of borrowed state and every
--- way the trip can end is a way to leave one behind.
local function endArrival()
    arriving = nil
    if BR.Spawn and BR.Spawn.focusRelease then BR.Spawn.focusRelease() end
    -- STEP 6. BR.Spawn.reveal() is the single place in this client that undoes
    -- every way the screen can be dark, and it is a no-op on a screen that is
    -- already lit -- so this is safe on the cancel and the timeout as well as on
    -- the arrival it belongs to.
    if BR.Spawn and BR.Spawn.reveal then BR.Spawn.reveal() end
end

--- S->C. Steps 1 and 2: go black, and pull the world in at that van.
RegisterNetEvent(BR.Net.REVIVEKEY_ARRIVE)
AddEventHandler(BR.Net.REVIVEKEY_ARRIVE, function(d)
    if type(d) ~= 'table' then return end
    if d.cancelled then
        if arriving then
            print('[br_core] revivekey: the arrival was withdrawn -- lifting the black')
            endArrival()
        end
        return
    end

    local x, y, z = tonumber(d.x), tonumber(d.y), tonumber(d.z)
    if not x or not y or not z then return end

    arriving = { at = GetGameTimer(), x = x, y = y, z = z }

    -- 1. THE SCREEN GOES BLACK. The game fade rather than the NUI curtain: the
    --    curtain is the lobby's, it carries words ('leaving' / 'dropping') that
    --    do not describe this, and the subject is spectating -- there is no HUD
    --    of their own under it to cover.
    DoScreenFadeOut(math.floor(tonumber(K and K.fadeMs) or 400))

    -- 2. AND THE STREAMING FOCUS GOES TO THE VAN, held for the whole of the
    --    server's wait so the ground under the ambulance is in by the time
    --    anybody is above it. Borrowed from client/spawn.lua rather than taken
    --    with a second SetFocusPosAndVel -- see BR.Spawn.focusOn.
    if BR.Spawn and BR.Spawn.focusOn then
        BR.Spawn.focusOn(x, y, z, arriveMaxMs())
    end
end)

--- S->C. Steps 3, 4, 5 and 6.
RegisterNetEvent(BR.Net.REVIVEKEY_PLACE)
AddEventHandler(BR.Net.REVIVEKEY_PLACE, function(d)
    if type(d) ~= 'table' then return end
    local x, y, z = tonumber(d.x), tonumber(d.y), tonumber(d.z)
    if not x or not y or not z then return end

    local up = tonumber(K and K.dropM) or 150.0
    local ped = PlayerPedId()
    -- THEIR OWN HEADING, WHICH IS NOT A DECISION. Nothing in the owner's
    -- sentence faces them anywhere, the drop below is given no horizontal
    -- speed, and carrying the heading they already had costs nothing and adds
    -- no number to the config.
    local heading = GetEntityHeading(ped)

    -- 3 AND 5. NetworkResurrectLocalPlayer takes the coordinates it stands you
    --    up at, so "process the revive" and "put them 150m above the ambulance"
    --    are one call and cannot be two without resurrecting somebody twice.
    --    BR.Spawn.reviveAt is the same four calls #144's held death makes.
    BR.Spawn.reviveAt(x, y, z + up, heading)

    -- 4. THE PARACHUTE, which is skydive.lua's entire drop machine and not a
    --    GiveWeaponToPed of our own. That file verifies the give across real
    --    frames, refuses to stack a reserve, applies the player's canopy and
    --    trail, tasks the chute with a retry, holds the auto-deploy floor all
    --    the way down and disarms it on landing. `speed = 0` is the one thing
    --    this arrival wants differently from the bus: nothing threw them out of
    --    anything, and 25 m/s of borrowed momentum would drift them off the van
    --    they were put above.
    TriggerEvent('br:drop:begin',
        { x = x, y = y, z = z + up, heading = heading, speed = 0.0 })

    -- 6. AND THE LIGHT COMES BACK, with the focus.
    endArrival()

    print(('[br_core] revivekey: back in, %.0fm over (%.1f, %.1f)')
        :format(up, x, y))
end)

--- The net under the black. See arriveMaxMs.
BR.Loop.register(BR.Loop.SLOW, 'revivekey.arrivewatch', function()
    if not arriving then return end
    if GetGameTimer() - arriving.at < arriveMaxMs() then return end

    print('[br_core] revivekey: the arrival never landed -- lifting the black '
        .. '(watchdog)')
    endArrival()
end)

-- ---------------------------------------------------------------------------
-- Teardown
-- ---------------------------------------------------------------------------

--- The resource stopping takes the plate with it.
---
--- THE ONLY EDGE HANDLER IN THIS FILE, and it is the one case the level test in
--- `revivekey.scan` cannot cover: the loop bands stop running, so the tick that
--- would have cleared the plate never comes, and a DUI message already sent
--- leaves a prompt hanging in the world with nothing left to take it down. Every
--- other consumer of this browser has the same line.
AddEventHandler('onClientResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    setPrompt(nil)
    -- AND THE BLACK SCREEN, FOR THE SAME REASON. An arrival caught mid-fade by a
    -- resource restart would leave the game faded out with the streaming focus
    -- parked on a van and every loop that could recover it stopped. The
    -- watchdog above is the net under a message that never came; this is the net
    -- under the whole file going away.
    if arriving then endArrival() end
end)

-- ---------------------------------------------------------------------------
-- /brplate -- stand at an ambulance and MEASURE where the plate goes
-- ---------------------------------------------------------------------------
--
-- ═══ THE REQUEST ═══
--
-- Owner, 2026-08-31: "If you want to make me the tools to manipulate the DUI
-- position then fetch it I can give you the coords."
--
-- ═══ IT IS /brlabel's SHAPE, NOT /brattach's, AND THAT IS A DECISION ═══
--
-- This project has two kinds of ruler. /brattach takes the ped, blocks WASD and
-- nudges an offset with the keyboard, because the thing being measured is where
-- a BODY sits and the body must not walk while it is measured. /brlabel,
-- /brshine and /brpropscale are console lines that set a number, print what to
-- paste, and take nothing away from the player.
--
-- THE SECOND SHAPE IS THE RIGHT ONE HERE, FOR ONE REASON: WALKING ROUND THE VAN
-- *IS* THE MEASUREMENT. "Whichever face the player is standing closest to" can
-- only be judged by standing at each face in turn, so a tool that claimed the
-- movement keys to nudge with would have taken away the thing being checked.
-- Nothing here disables a control, holds a ped, or has an exit that can be
-- forgotten -- stopping the resource with it running leaves nothing behind but a
-- plate the teardown above already clears.
--
-- ═══ WHAT IT DRAWS IS WHAT SHIPS ═══
--
-- The preview goes through `drawOnVan` -- the same face pick, the same height
-- derivation off the model's box, the same width, the same interface-size
-- preference, the same words out of BR.Config.ReviveKey.copy. There is no
-- second drawing path to be right while the real one is wrong.

--- One line of the on-screen readout.
---
--- attachtune.lua's `text`, matched call for call, because both are a dev
--- command's instrument panel and there is no reason for two of them to look
--- different. It is a local there and cannot be reached from here.
---
--- IT IS NUMBERS AND NOTHING ELSE. The owner's standing rule against unsolicited
--- copy is about what a PLAYER reads; this is only ever on the screen of
--- somebody who typed the command, and it still says nothing it does not have
--- to. The usage lines are printed to the console once, where they can be read
--- without covering the thing being measured.
local function text(x, y, s, scale)
    SetTextFont(4)
    SetTextScale(0.0, scale or 0.34)
    SetTextColour(255, 255, 255, 235)
    SetTextDropshadow(0, 0, 0, 0, 255)
    SetTextEdge(1, 0, 0, 0, 205)
    SetTextDropShadow()
    SetTextOutline()
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName(s)
    EndTextCommandDisplayText(x, y)
end

--- The face BR.Dui.drawNearFace last reported, as a word.
---
--- THE VAN'S OWN AXES, SAID OUT LOUD: +Y is the nose and +X is the right flank,
--- which is the frame the model's box is written in and the frame
--- BR.NearestBoxFace answers in. Naming them "nose/tail/left/right" rather than
--- printing (0,-1) is the difference between a readout that confirms the tool is
--- picking the face you are standing at and one that has to be decoded.
--- @return string
local function faceName()
    if faceY == 1.0  then return 'nose'  end
    if faceY == -1.0 then return 'tail'  end
    if faceX == 1.0  then return 'right' end
    if faceX == -1.0 then return 'left'  end
    return '-'
end

--- Which van the ruler is drawing at, refreshed while it is on.
---
--- ON THE TICK BAND, LIKE EVERY OTHER AMBULANCE SCAN IN THIS FILE. Walking speed
--- is about two metres a second and GetClosestVehicle is the one native this
--- costs; ten passes a second is already finer than the answer can change.
---
--- THE FEATURE'S OWN RESOLVER, so the ruler cannot end up measuring against a
--- vehicle the revive would refuse. It deliberately does NOT re-apply `reachM`:
--- standing back to look at the plate is part of tuning it, and the search
--- radius `nearestAmbulance` already uses is two metres wider than the reach.
BR.Loop.register(BR.Loop.TICK, 'revivekey.tune', function()
    if not tuning then
        tuneVeh = nil
        return
    end
    local c = GetEntityCoords(PlayerPedId())
    tuneVeh = nearestAmbulance(c.x, c.y, c.z)
end)

--- ═══ THE READOUT IS CONTINUOUS, AND THAT IS NOT A NICETY ═══
---
--- attachtune.lua's argument, unchanged: nudging blind and running a print
--- command to find out what happened is a round trip per step. With the numbers
--- on screen the loop is closed -- type, look, type -- and the face this frame
--- picked is on screen beside them, which is the one thing a printed number
--- cannot tell you.
BR.Loop.register(BR.Loop.FRAME, 'revivekey.tuneread', function()
    if not tuning then return end

    local out, frac, lift, width = plateNumbers()
    local y = 0.34
    text(0.015, y, ('~b~revive plate~w~  %s')
        :format(tuneVeh and ('face ' .. faceName()) or 'no ambulance in reach'))
    y = y + 0.026
    text(0.015, y, ('out %5.3f m   frac %5.3f   lift %6.3f m')
        :format(out, frac, lift))
    y = y + 0.026
    text(0.015, y, ('width %5.3f m'):format(width))
end)

--- WHICH WORDS NAME A NUMBER. A set rather than four branches, for /brshine's
--- reason: the name the owner types and the key that is written are one thing,
--- so a fifth number cannot arrive answering to a name nothing sets.
local PLATE_TUNABLE = { out = true, frac = true, lift = true, width = true }

--- /brplate [on|off] | [out|frac|lift|width <value>]
---
--- CLIENT-LOCAL AND NOT PERSISTED: it is a ruler, not a setting. A restart puts
--- br_lib/config/revivekey.lua's values back, which is what makes it safe to
--- leave a session halfway through a measurement.
RegisterCommand('brplate', function(_, args)
    local name  = tostring((args and args[1]) or '')
    local value = tonumber(args and args[2])

    if name == 'on' or name == 'off' then
        tuning = (name == 'on')
        if not tuning then
            -- The plate comes down on the next frame on its own: the pass that
            -- draws the preview is a level test on `tuning`, so there is no
            -- teardown here to be skipped.
            tuneVeh = nil
        end

    elseif PLATE_TUNABLE[name] then
        -- A KNOWN NAME WITH NO NUMBER IS A TYPO, NOT AN UNKNOWN NAME. Split from
        -- the branch below rather than folded into it: `brplate out` answering
        -- "no such plate value: out" is a tool telling the owner his spelling is
        -- wrong when it is not, and he would go looking for the right word. It
        -- falls through to the printout either way, so the answer to "what is it
        -- now" is on the screen regardless.
        if not value then
            print(('[br_core] brplate: %s takes a number'):format(name))
        elseif type(K.plate) ~= 'table' then
            print('[br_core] brplate: BR.Config.ReviveKey.plate is missing -- '
                .. 'nothing to tune (check br_lib/config/revivekey.lua)')
            return
        else
            K.plate[name] = value
        end

    elseif name ~= '' then
        print(('[br_core] brplate: no such plate value: %s'):format(name))
    end

    local out, frac, lift, width = plateNumbers()
    print('=== revive plate ===')
    print(('  preview   %s%s'):format(tuning and 'on' or 'off',
        tuning and (tuneVeh and ('  (drawing, face ' .. faceName() .. ')')
                             or '  (no ambulance in reach)') or ''))
    print(('  out       %.3f m   off the panel the player is nearest to')
        :format(out))
    print(('  frac      %.3f     up the model box, 0 ground 1 roof'):format(frac))
    print(('  lift      %.3f m   added after that'):format(lift))
    print(('  width     %.3f m   height follows the page'):format(width))
    print('  paste into br_lib/config/revivekey.lua:')
    print('    plate = {')
    print(('        out   = %.3f,'):format(out))
    print(('        frac  = %.3f,'):format(frac))
    print(('        lift  = %.3f,'):format(lift))
    print(('        width = %.3f,'):format(width))
    print('    },')
    print('  usage: brplate on | off   draw a plate at the nearest ambulance')
    print('         brplate out|frac|lift|width <value>')
end, false)
