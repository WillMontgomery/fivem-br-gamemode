-- The revive key, on screen: the plate over a loose key, the plate at an
-- ambulance, and the hold that brings a squadmate back. #219 step 5's client
-- half.
--
-- ═══════════════════════════════════════════════════════════════════════════
-- THIS FILE DECIDES NOTHING. IT DRAWS, AND IT REPORTS A KEY BEING HELD
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Every rule lives in server/revivekey.lua: whether a key exists, whether the
-- squad owns it, whether this player is close enough, whether the match is still
-- running, and whether six seconds have actually elapsed. Nothing here is a
-- boundary. What this side owns is the two things the server cannot see -- what
-- is on screen, and whether a finger is on a key -- and it owns them the way
-- client/dbno.lua does, because that file has already paid for the alternatives.
--
-- ═══════════════════════════════════════════════════════════════════════════
-- WHERE THE COORDINATES COME FROM, AND WHY NOT FROM A PED
-- ═══════════════════════════════════════════════════════════════════════════
--
-- FROM THE SQUAD BEACON (server/party.lua), as `m.key = { x, y, z, held, live }`
-- on the OUT mate's row. Those are the SERVER'S OWN NUMBERS -- the ones its
-- ruling is measured against -- so the plate and the ruling cannot disagree
-- about where the key is.
--
-- THE OBVIOUS ALTERNATIVE IS A DEAD PED AND IT IS POISON. client/dbno.lua's
-- #163 block: our machine's copy of a downed mate "CRAWLS AWAY", and commit
-- 33ca88c adds that a corpse's position is a death ragdoll -- "the one thing
-- this file already knows do not replicate reliably" (citizenfx/fivem#2436,
-- open). A prompt anchored to that walks off the body it belongs to, on this
-- screen only, while the server still rules against the fixed point. There is no
-- ped in this file at all.
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
--     corpse is the one place the two prompts genuinely overlap, and picking up
--     a mate who is still bleeding beats spending a key on one who is not.
--   * TO client/ambheal.lua, by standing the buy plate down while
--     BR.AmbHeal.prompting() -- otherwise one press behind an ambulance would
--     start a heal AND spend 25 Volts.
--   * TO client/loot.lua, by way of dbno.lua's single BR.Loot.suppress() call
--     site, which now reads BR.ReviveKey.prompting(). A corpse is ringed with
--     scattered loot BY CONSTRUCTION (BR.Loot.deathBox), so this is not an edge
--     case -- it is every single revive. The suppression is driven from the ONE
--     existing caller rather than added as a second bare one, because
--     BR.Loot.suppress is a plain boolean and a second writer saying `false`
--     would clear the first writer's yield on the frame they disagree.
--
-- ═══════════════════════════════════════════════════════════════════════════
-- NO STRINGS LIVE HERE
-- ═══════════════════════════════════════════════════════════════════════════
--
-- All three plates read BR.Config.ReviveKey.copy. There is no `or 'Revive'`
-- anywhere in this file: a missing line draws NO PLATE rather than a fallback
-- somebody else wrote, because the owner's standing rule is that copy he did not
-- ask for reads as slop, and a default in an `or` is exactly how one ships.

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

-- How high above the point the plate floats, and how big it draws.
--
-- client/ambheal.lua's two numbers, matched rather than re-derived, so the sixth
-- consumer of one browser does not draw at a different size to the fifth. They
-- are not tuning knobs and are deliberately not in the config: a plate that
-- looks like the other five is the whole requirement.
local PROMPT_LIFT  = 1.1
local PROMPT_SCALE = 1.6

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
--- @return boolean
function BR.ReviveKey.prompting()
    return shownKey ~= nil
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
---   1. REVIVE beats everything. A key the squad already owns, within reach, is
---      the act this feature exists for.
---   2. TAKE next. Something on the ground worth walking the last few metres to.
---   3. BUY last, and only when neither of the above is in reach -- a body and an
---      ambulance are rarely in the same place, and when they are, standing over
---      the body is the thing to be told about.
---
--- ONE ANSWER, HELD, AND THE PRESS ACTS ON IT. client/loot.lua's #128 lesson
--- applied before it costs anything: the prompt and the claim used to resolve
--- independently there, and with two crates in reach a player pressed while
--- looking at one and took the other.
--- @param px number
--- @param py number
--- @return table|nil
local function choose(px, py)
    local reach = tonumber(K.reviveReachM) or 3.0
    -- THE TIGHT NUMBER, NOT THE SERVER'S. config/revivekey.lua's `reviveSlackM`
    -- is added on the ruling side only, so there is no position at which this
    -- plate is absent and the server would have allowed the hold -- the
    -- divergence only ever runs the forgiving way. client/fuel.lua's header
    -- records what the other direction costs.
    local bestSrc, bestD, bestRec, bestMode = nil, nil, nil, nil

    for src, rec in pairs(keys) do
        local d = BR.Dist(px, py, rec.x, rec.y)
        if d <= reach then
            local mode = (rec.held == true) and 'revive'
                      or ((rec.live == true) and 'take' or nil)
            -- A HELD KEY OUTRANKS A LOOSE ONE AT ANY DISTANCE, and among equals
            -- the nearer wins. Written as two comparisons rather than a sort:
            -- a squad is four people and three of them can be down.
            if mode and (bestMode == nil
                         or (mode == 'revive' and bestMode ~= 'revive')
                         or (mode == bestMode and d < bestD)) then
                bestSrc, bestD, bestRec, bestMode = src, d, rec, mode
            end
        end
    end

    if bestSrc then
        return { mode = bestMode, id = bestSrc,
                 x = bestRec.x, y = bestRec.y, z = bestRec.z }
    end

    -- ═══ THE PURCHASE ═══
    --
    -- Offered when this squad has ANY key it does not yet own -- including one
    -- whose pickup has expired, which is the whole point of the 25 Volts: "The
    -- pickup expires on a timer... They can still purchase the revive keys at an
    -- ambulance" is one sentence, and the second half is what this plate is.
    local owed = false
    for _, rec in pairs(keys) do
        if rec.held ~= true then owed = true break end
    end
    if not owed then return nil end

    -- YIELD TO THE STRETCHER. Both plates would be drawn at the same van and
    -- both handlers would act on one press, so a hurt player behind an ambulance
    -- with a mate down would heal AND spend 25 Volts on one key. The heal is the
    -- one that was there first and the one with a rear-arc test behind it, so
    -- this stands down. The residual cost is that the purchase is unavailable at
    -- the tailgate of an ambulance while hurt; walking round to the wing offers
    -- it, because the heal has an arc and this does not.
    if BR.AmbHeal and BR.AmbHeal.prompting and BR.AmbHeal.prompting() then
        return nil
    end

    local ped = PlayerPedId()
    local c = GetEntityCoords(ped)
    local veh = nearestAmbulance(c.x, c.y, c.z)
    if not veh then return nil end

    local vc = GetEntityCoords(veh)
    if BR.Dist(c.x, c.y, vc.x, vc.y) > (tonumber(K.reachM) or 6.0) then return nil end

    return { mode = 'buy', id = veh, veh = veh, x = vc.x, y = vc.y, z = vc.z }
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
        setPrompt(nil)
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
        holding = { target = c.id, from = GetGameTimer() }
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
            TriggerServerEvent(BR.Net.REVIVEKEY_START, { target = holding.target })
        end
    end

    -- ═══ WHAT IS ON THE PLATE ═══
    local C = copy()
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
        setPrompt(nil)

    elseif c.mode == 'revive' then
        local e = BR.State.roster[c.id]
        setPrompt(C.revive and {
            mode = 'revive', id = c.id,
            label = e and e.name or nil, hint = C.revive, press = true,
        } or nil)

    elseif c.mode == 'take' then
        local e = BR.State.roster[c.id]
        -- NO `press`, SO NO KEY CAP. Collection is automatic within
        -- BR.Config.ReviveKey.collectM and is decided by the server off its own
        -- position samples -- there is no event a client could send and nothing
        -- for it to lie about. This plate says what is lying there and that
        -- walking to it is the act.
        setPrompt(C.take and {
            mode = 'take', id = c.id,
            label = e and e.name or nil, hint = C.take,
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

--- ...and drawing it, which has to be per frame.
---
--- BR.Dui.drawWorld is a DrawSprite and a sprite lasts exactly one frame. The
--- pass above decides WHAT; this decides WHERE, sixty times a second, so the
--- plate is welded to the point however fast the camera moves.
BR.Loop.register(BR.Loop.FRAME, 'revivekey.draw', function()
    -- NOTHING IS ASKED FOR BEFORE THERE IS SOMETHING TO DRAW. promptPage() would
    -- CREATE the browser, and a player who never stands over a body should never
    -- pay for a CEF instance this file did not need -- the page is shared, so
    -- whichever consumer asks first builds it and this one has no reason to be
    -- that consumer.
    if shownKey == nil then return end
    local page = promptPage()

    if holding then
        local rec = keys[holding.target]
        if rec then
            BR.Dui.drawWorld(page, rec.x, rec.y, rec.z + PROMPT_LIFT, PROMPT_SCALE)
        end
        return
    end

    local c = cand
    if not c then return end
    if c.mode == 'buy' then
        -- RE-READ, because a vehicle can be destroyed between two ticks and
        -- reading a dead handle's coordinates throws -- which in a frame
        -- callback costs the whole band after five of them.
        if not isTrue(DoesEntityExist(c.veh)) then return end
        local vc = GetEntityCoords(c.veh)
        BR.Dui.drawWorld(page, vc.x, vc.y, vc.z + PROMPT_LIFT, PROMPT_SCALE)
    else
        BR.Dui.drawWorld(page, c.x, c.y, c.z + PROMPT_LIFT, PROMPT_SCALE)
    end
end)

-- ---------------------------------------------------------------------------
-- The purchase
-- ---------------------------------------------------------------------------

--- The press that spends 25 Volts.
---
--- ═══ IT ACTS ON WHAT WAS DRAWN, NOT ON A FRESH SEARCH ═══
---
--- `cand` and not a new scan, which is client/ambheal.lua's reading of
--- client/loot.lua's #128: the prompt and the claim used to resolve
--- independently and a player pressed while looking at one crate and took
--- another. Two ambulances parked at a station is the same picture.
---
--- ═══ AND IT IS INERT UNLESS THE BUY PLATE IS THE ONE ON SCREEN ═══
---
--- `cand.mode == 'buy'` is the whole guard, and it is what keeps this handler
--- out of the way of the other five listeners on this key: the same press that
--- starts a revive hold, opens a crate or boards a stretcher reaches here too,
--- and finds a mode that is not 'buy'.
BR.Keys.on('interact', function(pressed)
    if not pressed then return end

    local c = cand
    if not c or c.mode ~= 'buy' then return end
    if shownKey == nil then return end

    -- A MASHED KEY MUST NOT QUEUE ROUND TRIPS. The server refuses a second
    -- purchase while one is in flight -- and refuses it silently, by design --
    -- so without this a player leaning on the key would fire a request every
    -- frame the edge repeated and learn nothing from any of them.
    local now = GetGameTimer()
    if now - lastBuy < 1000 then return end
    lastBuy = now

    local veh = c.veh
    if not veh or not isTrue(DoesEntityExist(veh)) then return end

    -- ...AND IT HAS TO BE NETWORKED, or there is nothing to name to the server.
    -- An ambulance that exists only on this machine is not a shared world object
    -- and the server cannot resolve a net id for it. client/ambheal.lua refuses
    -- the same way for the same reason.
    if NetworkGetEntityIsNetworked ~= nil
       and not isTrue(NetworkGetEntityIsNetworked(veh)) then
        return
    end

    local ok, netId = pcall(NetworkGetNetworkIdFromEntity, veh)
    if not ok or not netId then return end

    TriggerServerEvent(BR.Net.REVIVEKEY_BUY, { n = netId })
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
end)
