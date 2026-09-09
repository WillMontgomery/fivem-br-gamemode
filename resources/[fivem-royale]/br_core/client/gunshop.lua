-- The in-match Ammu-Nation counter, client side (#274): the clerk, the plate on
-- the counter, the keypress, and the menu that opens behind it.
--
-- ═══════════════════════════════════════════════════════════════════════════
-- "We need to spawn NPCs at each shop ... We should have a DUI at the counter
--  and pressing the interact key will open the menu to purchase items using
--  volts." -- owner, 2026-09-07
-- ═══════════════════════════════════════════════════════════════════════════
--
-- This is client/shop.lua's shape with three differences, and each of them is
-- forced by the difference between one showroom in a warmup and eleven counters
-- in a live match.
--
-- ═══ 1. THE CLERK IS A LOCAL PED, AND THAT IS NOT A PREFERENCE ═══
--
-- client/rescue.lua's paramedic carries the full argument and it applies here
-- word for word. There is no ped server setter -- citizenfx/fivem's
-- ext/native-decls/server/ holds exactly one creation native,
-- CreateVehicleServerSetter, and #2787 ("Implement Server Setters; RPC are
-- broken") is still open. The two routes that remain are both closed:
-- client-side NETWORKED CreatePed is POPTYPE_MISSION, which `sv_entityLockdown
-- relaxed` refuses outright; and server-side CreatePed is an RPC native, which
-- citizenfx/fivem #1407 is closed with the rule that RPC creation is inherently
-- incompatible with routing buckets -- and THIS GAMEMODE RUNS EVERY MATCH IN
-- ONE, so the ped would land in the bucket of whichever client the engine picked
-- to build it.
--
-- A LOCAL PED SIDESTEPS ALL THREE AND NEEDS NO BUCKET HANDLING AT ALL. What it
-- costs is exactly one thing and it is cosmetic: every player sees their own
-- clerk rather than the same one. Nothing about this feature depends on two
-- players agreeing about a ped -- the purchase is arbitrated on the server from
-- a sampled position and a catalogue both sides hold.
--
-- ═══ 2. IT IS BUILT AND TORN DOWN ON DISTANCE, WHICH THE SHOWROOM NEVER DOES
--     ═══
--
-- The showroom is one pad every player in the match walks through, so it is
-- built off the state flip and 1.36km is a streaming hazard to wait out rather
-- than a reason not to build. These are eleven buildings over 51 km^2 and any
-- given player will never enter ten of them. The framerate investigation on
-- 2026-09-07 found that invisible-but-simulated peds and per-frame entity work
-- are what actually cost frames on this server, so eleven permanent clerks would
-- be ten of them simulated for nobody, for the whole match, on every machine.
--
-- SO THE RECONCILER HAS A DISTANCE TERM (BR.GunshopSolve.wantsClerk, two radii
-- so a player standing on the boundary does not build and delete a ped once a
-- second), and NOTHING IS DRAWN OR ASKED FOR when no counter is near: the FRAME
-- pass returns on its first line unless a plate is up, and the plate is only up
-- inside `reachM` of a counter.
--
-- ═══ 3. THE CLERK'S HEIGHT IS PROBED, NEVER AUTHORED ═══
--
-- config/gunshop.lua refuses to author one and says why at length: the sources
-- these anchors came from disagree by up to about 1.1m on whether the tabulated
-- z is the interior floor or a standing ped's center, and there is no way to
-- tell which any given row is from the number alone. The warmup showroom already
-- paid for that lesson from the other end -- `veto` shipped at an authored z
-- that probed a metre out and cost three playtest rounds.
--
-- So the engine is asked. GET_GROUND_Z_FOR_3D_COORD answers with the highest
-- ground BELOW the point it is handed (client/loot.lua's PROBE_FROM_Z carries
-- the playtest that established it), so the probe starts a little ABOVE the
-- anchor and not at it -- and only a little, because a probe started over the
-- roof answers with the roof.
--
-- AND EVERY PROBE IS WRITTEN DOWN. `placed` below is a ledger of what was asked
-- and what came back at each of the eleven, and /brgunshop prints it. One
-- playtest round turns eleven guesses into eleven numbers the owner can paste
-- back into config/gunshop.lua's `zOverride` slots.

BR = BR or {}
BR.Gunshop = BR.Gunshop or {}

local G = BR.Config.Gunshop

--- 0 IS TRUTHY IN LUA AND A FIVEM BOOL NATIVE MAY ANSWER 1 OR 0. Nine shipped
--- instances on this project; every client file carries this line.
local function isTrue(v) return v == true or v == 1 end

--- Call a native only if this build has it, and never let it throw.
---
--- The clerk's protections are a run of eight writes and a single missing native
--- in the middle of them would leave a ped that is invincible but can still
--- ragdoll, or frozen but still flees. Guarding each one means a build without
--- some ped flag loses that one property rather than the whole clerk.
--- @param f any
local function nat(f, ...)
    if type(f) ~= 'function' then return end
    pcall(f, ...)
end

--- The usable catalogue on this client. Same rows the server resolved, from the
--- same config and the same derivation -- config/ is a shared_script, so this is
--- the same computation run twice rather than a copy sent over the wire.
local rows = {}

--- The usable counters.
local stores = {}

--- The clerks standing on THIS machine right now: [storeId] = ped handle.
local clerks = {}

--- [storeId] = true while a build thread for it is in flight.
---
--- SEPARATE FROM `clerks`, because a model request yields for up to five seconds
--- and the reconciler runs once a second. Without this, one approach to a store
--- starts five build threads and four of them leak a ped.
local building = {}

--- WHAT THE GROUND PROBE SAID AT EACH COUNTER, AND WHAT WAS DONE WITH IT.
---
--- A LEDGER, NOT A PLAN. Nothing here reads it to decide where anything goes;
--- /brgunshop prints it and that is its whole purpose. It exists because the
--- clerk's height is the one number nobody has -- config/gunshop.lua explicitly
--- refuses to guess it -- and the answer exists for one frame unless it is kept.
---
---   [id] = { model    = string,   -- which clerk model was asked for
---            anchorZ  = number,   -- the tabulated z, untouched
---            fromZ    = number,   -- where the downward probe started
---            hit      = boolean,  -- did the native answer at all
---            gz       = number|nil, -- what it answered
---            z        = number,   -- where the ped was actually created
---            source   = string,   -- 'override' | 'probe' | 'anchor'
---            delta    = number,   -- z - anchorZ: how wrong the table was
---            waitedMs = number,   -- how long the probe was retried for
---            restZ    = number|nil, -- where the ped read back at
---            at       = number }  -- GetGameTimer at the build
---
--- ═══ AND IT IS *NOT* CLEARED WHEN A CLERK IS TORN DOWN, WHICH IS THE ONE
---     PLACE THIS DIVERGES FROM client/shop.lua ═══
---
--- The showroom drops its ledger row with the car, because the pad is one scene
--- and a reading left standing over a torn-down pad describes a previous match.
--- Here the reading describes a BUILDING, which is the same building next match
--- and the match after that -- and the whole point of the ledger is that the
--- owner walks to a few counters over a round and reads all of them at the end.
--- Clearing on walk-away would erase the very reading he went to collect.
---
--- `at` IS WHAT KEEPS THAT HONEST. Every row says when it was taken, so a
--- reading from twenty minutes ago is visibly one from twenty minutes ago rather
--- than being mistaken for the clerk standing in front of you.
local placed = {}

--- Building yields, so a state flap can start a second build while the first is
--- still streaming a model. Same generation token client/shop.lua and
--- client/bus.lua use, and for the same reason: one flight produced two planes.
local gen = 0

--- What the plate was last told, so it is sent on CHANGE rather than per frame.
---
--- ═══ NO PAIR GUARD HERE, AND THAT IS A REAL DIFFERENCE FROM THE SHOWROOM ═══
---
--- client/shop.lua guards on (shown, shown-for-which-row) because its plate
--- quotes a car's name and a car's price and the cars are 3.25m apart, so
--- walking the line changes the WORDS without ever dropping the plate. This
--- plate's words do not depend on which counter it is at -- it is a title and a
--- key cap -- and no two counters are within four reaches of each other
--- (tools/test_gunshop.lua asserts it), so there is no second store to walk to
--- without the plate going down in between. A guard on `show` alone is correct
--- here for reasons that are stated rather than assumed.
local plateShown = false

--- The counter the TICK pass decided the player is at, held for the FRAME pass
--- to draw against -- and the ONE counter a keypress may open.
---
--- #128's LESSON. In client/loot.lua the prompt and the claim used to resolve
--- independently, and with two crates in reach a player pressed while looking at
--- one and took the other. The press acts on what was drawn, never on a fresh
--- search.
local candidate = nil

--- The one menu. Built once, on the first press, and reused at all eleven
--- counters for the life of the resource.
---
--- ONE OBJECT RATHER THAN ONE PER OPEN, because a UIMenu registers itself with
--- the library's MenuHandler and its BreadcrumbsHandler when it is shown, and a
--- fresh object per press would be thirty UIMenuItems and a scaleform rebuild
--- for a catalogue that has not changed. The prices are config and config does
--- not move inside a session.
local menu = nil

--- Is the menu up, and which counter opened it.
---
--- `menuStore` IS WHAT CLOSES IT ON WALK-AWAY. The menu belongs to the counter
--- it was opened at; when the TICK pass stops finding that counter in reach, the
--- menu goes down. A shop screen that stays up while the player runs down the
--- street is a shop screen they can buy from in the street.
local menuOpen  = false
local menuStore = nil

-- ---------------------------------------------------------------------------
-- The plate
-- ---------------------------------------------------------------------------

--- THE SHARED WORLD-PROMPT PAGE, WHICH IS THE SEVENTH CONSUMER OF IT.
---
--- The crate, the pump, the revive, the heal station, the showroom and the
--- revive key all draw on this one browser, and client/ambheal.lua states the
--- standing rule: "One browser for every world prompt in the game." A DUI is a
--- whole CEF instance.
---
--- ═══ AND THIS IS THE CONSUMER THE HAZARD IN THAT RULE WAS NEVER TESTED
---     AGAINST ═══
---
--- ambheal.lua names the unfixed cost in as many words: two consumers in range
--- at once means "two writers on one page and two handlers on one keypress", and
--- the honest outcome is that such a press does both. Every existing consumer is
--- somewhere that rarely happens -- an airfield in warmup, a petrol station, a
--- corpse. AN AMMU-NATION COUNTER IS OPEN MID-MATCH IN A BUILDING WHERE FLOOR
--- LOOT CAN BE LYING TWO METRES AWAY, which is the first time this rule meets
--- the case it was written to tolerate rather than to solve.
---
--- WHAT IS DONE ABOUT IT HERE, AND WHAT IS NOT. BR.Gunshop.busy() below answers
--- the project's existing question for this -- client/ambheal.lua and
--- client/revivekey.lua both expose a `prompting()` for exactly this purpose --
--- but the ONE call site that spends those answers is in client/dbno.lua, which
--- is deliberately the only file that calls BR.Loot.suppress (that function is a
--- plain boolean with no refcount, so a second writer would clear the first's
--- yield). Adding this file's clause to that one OR is a one-line edit to a file
--- another agent is holding this round. IT IS NOT DONE, IT IS REPORTED, and
--- until it lands a press at a counter with a crate underfoot claims the crate
--- as well.
local function promptPage()
    return BR.Dui.page('lootprompt', 'nui://br_ui/dui/prompt.html', 512, 256)
end

--- Show or hide the counter plate.
---
--- ═══ THE COPY IS ONE WORD AND IT IS NOT HIS ═══
---
--- The owner has written no player-facing text for this feature. A world prompt
--- structurally needs a subject over its key cap, so the plate borrows the same
--- single word the menu banner uses -- `BR.Config.Gunshop.menuTitle`, which
--- carries a marked block asking him to replace it. One word, used twice, in one
--- place, rather than two guesses in two files.
---
--- NO `hint`. The showroom's second line is a price and there is no single price
--- at a counter; prompt.html renders an absent hint as an empty line. NO `ring`:
--- this is a tap, not a hold.
---
--- THE KEY CAP IS THE PLAYER'S OWN BINDING, asked for by COMMAND rather than by
--- control -- client/loot.lua's fix, without which every prompt in the game said
--- E after a rebind.
---
--- ═══ AND THE HUD'S VOLTS READOUT COMES UP WITH IT ═══
---
--- `br:ui:sendLocal 'shopplate'` is the mechanism client/shop.lua uses for the
--- owner's 2026-08-29 request ("when a DUI is shown at the shop, please show
--- their current volts balance with NUI where the bullet rounds show"). He has
--- not asked for it HERE, and it is done anyway -- flagged in the handover
--- rather than quietly -- because a shop you cannot see your balance in is a
--- shop where every refusal is a surprise, and because this adds no copy, no
--- payload and no mechanism: it is a boolean on an event that already exists,
--- and br_ui already holds the figure. One line to remove if he disagrees.
--- @param show boolean
local function setPlate(show)
    show = (show == true)
    if show == plateShown then return end
    plateShown = show

    TriggerEvent('br:ui:sendLocal', 'shopplate', { show = show })

    local page = promptPage()
    if not show then
        BR.Dui.send(page, { t = 'prompt', show = false })
        return
    end

    BR.Dui.send(page, {
        t     = 'prompt',
        show  = true,
        label = tostring(G.menuTitle or ''),
        key   = BR.Native.keyLabelForCommand('brinteract', 51),
        ring  = false,
    })
end

-- ---------------------------------------------------------------------------
-- The clerk
-- ---------------------------------------------------------------------------

--- ONE GROUND PROBE, OR AN HONEST ACCOUNT OF WHY THERE IS NO ANSWER.
---
--- THE FIRST RETURN IS A BOOL AND IT GOES THROUGH isTrue. Cfx documents the
--- native as answering false when the coordinates are outside the client's
--- render distance (citizenfx/natives, MISC/GetGroundZFor_3dCoord.md), which is
--- the exact condition a clerk built from sixty metres away runs into. Reading
--- its 0 as truth would put a ped at whatever the second return happened to hold
--- -- which is 0.0, sea level on this map, so it would read as a plausible
--- height rather than as a refusal.
---
--- includeWater FALSE: we want the shop floor, not the sea over it.
--- @param x number
--- @param y number
--- @param fromZ number
--- @return boolean hit
--- @return number|nil z
local function probeGround(x, y, fromZ)
    if type(GetGroundZFor_3dCoord) ~= 'function' then return false, nil end
    local ok, hit, gz = pcall(GetGroundZFor_3dCoord, x, y, fromZ, false)
    if not ok or not isTrue(hit) then return false, nil end
    return true, tonumber(gz)
end

--- Take one clerk down.
---
--- THE LEDGER ROW STAYS. See the note on `placed`: the reading describes a
--- building, not a scene, and the owner collects them over a round.
--- @param id string
local function dropClerk(id)
    local ped = clerks[id]
    if ped and ped ~= 0 and isTrue(DoesEntityExist(ped)) then
        DeleteEntity(ped)
    end
    clerks[id] = nil
end

--- Take every clerk down, and abandon anything still streaming.
local function teardownAll()
    gen = gen + 1
    for id in pairs(clerks) do dropClerk(id) end
    building = {}
end

--- Put one clerk behind one counter.
---
--- ONE THREAD PER STORE rather than one for all eleven, which is the opposite of
--- client/shop.lua's choice and for the opposite reason: the showroom builds
--- thirteen models at one place at one moment, so serialising them is what stops
--- a burst of RequestModel stuttering the scene. Here a player is inside ONE
--- building; the other ten stores are kilometres away and their threads will
--- never run at the same time. A shared thread would only mean the clerk waits
--- behind a store nobody is at.
---
--- ═══ WHAT A SHOP PED MUST NOT DO ═══
---
--- It must not be shot (invincible, undamageable, untargetable, and it does not
--- die when injured), must not RAGDOLL, must not react to gunfire or FLEE or
--- WANDER (SetBlockingOfNonTemporaryEvents is the one that covers all three --
--- it makes the ped ignore every non-permanent event the world hands it), must
--- not BLOCK A DOORWAY (the player passes through it), and must not be SIMULATED
--- WHEN NOBODY IS NEAR -- which is not a flag but the whole reconciler above.
--- @param store table
local function buildClerk(store)
    if clerks[store.id] or building[store.id] then return end
    building[store.id] = true

    local mine = gen
    Citizen.CreateThread(function()
        -- CLEARED ON EVERY EXIT. A build flag left set is a counter that never
        -- gets a second attempt for the rest of the match.
        local function giveUp()
            building[store.id] = nil
        end

        local name = BR.GunshopSolve.clerkModel(G, store)
        if not name then
            print(('^3[br_core] gunshop: "%s" has no clerk model -- no clerk^7')
                :format(tostring(store.id)))
            return giveUp()
        end

        local model = GetHashKey(name)
        if not (isTrue(IsModelValid(model)) and isTrue(IsModelAPed(model))) then
            print(('^3[br_core] gunshop: "%s" is not a ped model on this build '
                   .. '-- "%s" has no clerk^7')
                :format(tostring(name), tostring(store.id)))
            return giveUp()
        end

        RequestModel(model)
        local waited = 0
        local budget = tonumber(G.modelWaitMs) or 5000
        while not isTrue(HasModelLoaded(model)) and waited < budget do
            Citizen.Wait(50)
            waited = waited + 50
            if mine ~= gen then
                -- THE REQUEST IS RELEASED ON EVERY EXIT, INCLUDING THIS ONE. An
                -- abandoned build that kept its RequestModel holds a ped model
                -- resident for the rest of the session, which is exactly the
                -- kind of cost the distance teardown exists to avoid.
                SetModelAsNoLongerNeeded(model)
                return giveUp()
            end
        end
        if not isTrue(HasModelLoaded(model)) then
            -- SAID OUT LOUD, WHICH IS WHAT config/gunshop.lua ASKS FOR. Neither
            -- clerk model has ever been loaded by this project, so "it does not
            -- stream" is a live possibility and a silent failure would look
            -- exactly like a counter nobody had wired up.
            print(('^3[br_core] gunshop: model "%s" never loaded in %dms -- '
                   .. '"%s" has no clerk^7')
                :format(tostring(name), budget, tostring(store.id)))
            SetModelAsNoLongerNeeded(model)
            return giveUp()
        end

        -- ═══ THE PROBE, RETRIED ON A BUDGET ═══
        --
        -- Same freeze-request-poll-give-up shape as client/shop.lua's
        -- awaitCollision, and for the same reason in a different archetype: the
        -- clerk is built at `clerkBuildM`, through a wall, quite possibly before
        -- the interior has streamed -- and the probe is documented as answering
        -- false outside the render distance. The first `false` is information
        -- about the world, not about the floor.
        local fromZ = BR.GunshopSolve.probeStart(G, store)
            or ((tonumber(store.z) or 0.0) + 0.0)
        local pWait  = 0
        local pBudget = tonumber(G.probeWaitMs) or 1500
        local hit, gz = probeGround(store.x + 0.0, store.y + 0.0, fromZ)
        while not hit and pWait < pBudget do
            nat(RequestCollisionAtCoord, store.x + 0.0, store.y + 0.0, fromZ)
            Citizen.Wait(50)
            pWait = pWait + 50
            if mine ~= gen then
                SetModelAsNoLongerNeeded(model)
                return giveUp()
            end
            hit, gz = probeGround(store.x + 0.0, store.y + 0.0, fromZ)
        end

        -- THE ARITHMETIC IS br_lib's, NOT THIS FILE'S. "The probe wins over the
        -- table" is the whole of what config/gunshop.lua's header asks for, and
        -- a rule that lives in a client file is a rule no suite can execute.
        local z, source = BR.GunshopSolve.clerkZ(G, store, hit, gz)
        local cx, cy, cz, ch = BR.GunshopSolve.clerkAt(G, store, z)
        if not cx or not cz then
            SetModelAsNoLongerNeeded(model)
            return giveUp()
        end

        -- 4 IS PED_TYPE_MISSION. The last two flags are isNetwork and
        -- bScriptHostPed, and both are false: see the header, and
        -- client/rescue.lua for the same two falses in the same positions on the
        -- same native.
        local ped = CreatePed(4, model, cx, cy, cz, ch, false, false)
        SetModelAsNoLongerNeeded(model)

        -- A HANDLE, AND 0 IS TRUTHY. CreateVehicle answering 0 was this
        -- project's eighth 0-is-truthy defect and cost a full playtest round;
        -- CreatePed answers the same way for the same reasons.
        if not (ped and ped ~= 0 and isTrue(DoesEntityExist(ped))) then
            print(('^3[br_core] gunshop: could not create a clerk at "%s"^7')
                :format(tostring(store.id)))
            return giveUp()
        end

        if mine ~= gen then
            -- Abandoned mid-stream. This ped is in nobody's `clerks` table, so
            -- teardownAll cannot reach it and this is the only place it can be
            -- cleaned up.
            DeleteEntity(ped)
            return giveUp()
        end

        nat(SetEntityHeading, ped, ch)
        nat(SetEntityInvincible, ped, true)
        nat(SetEntityCanBeDamaged, ped, false)
        nat(SetPedCanBeTargetted, ped, false)
        nat(SetPedDiesWhenInjured, ped, false)
        nat(SetPedCanRagdoll, ped, false)
        -- THE ONE THAT COVERS REACTING, FLEEING AND WANDERING AT ONCE. A ped
        -- blocked from non-temporary events ignores gunfire, explosions, other
        -- peds and the player entirely, so it never plays a flee task and never
        -- starts an ambient wander. client/rescue.lua's medic uses the same
        -- native for the same purpose.
        nat(SetBlockingOfNonTemporaryEvents, ped, true)
        nat(SetPedFleeAttributes, ped, 0, false)
        nat(FreezeEntityPosition, ped, true)
        -- NOT A DOORWAY. An Ammu-Nation counter is in a small room and a solid
        -- ped standing in it is something to walk around; this lets the player
        -- through.
        --
        -- THE THIRD ARGUMENT IS `thisFrameOnly` AND IT MUST BE FALSE. Passing
        -- true is the shape that reads as "yes, disable it" and means "for one
        -- frame" -- so the clerk would be solid again on the next tick and the
        -- fault would present as a ped that is intermittently walkable, which
        -- nobody would connect to this line.
        --
        -- SET AGAINST THE PLAYER'S PED HANDLE AS IT IS NOW, which is enough: a
        -- new handle means the player died or respawned, and either takes them
        -- out of ALIVE and tears every clerk down.
        nat(SetEntityNoCollisionEntity, ped, PlayerPedId(), false)

        local restZ
        local okP, p = pcall(GetEntityCoords, ped)
        if okP and p then restZ = p.z end

        placed[store.id] = {
            model    = name,
            anchorZ  = tonumber(store.z) or 0.0,
            fromZ    = fromZ,
            hit      = hit and true or false,
            gz       = gz,
            z        = cz,
            source   = source,
            delta    = cz - (tonumber(store.z) or 0.0),
            waitedMs = pWait,
            restZ    = restZ,
            at       = GetGameTimer(),
        }

        -- EVERYTHING FROM THE GENERATION CHECK ABOVE TO THIS LINE RUNS WITHOUT
        -- YIELDING, and that is what makes the check sufficient rather than
        -- merely likely. Lua threads here are cooperative: nothing else can run
        -- between them, so teardownAll cannot bump `gen` in the gap and leave a
        -- ped that no table points at. A Citizen.Wait added anywhere in that
        -- stretch would need a second check after it.
        clerks[store.id] = ped
        building[store.id] = nil
    end)
end

-- ---------------------------------------------------------------------------
-- The scene
-- ---------------------------------------------------------------------------

--- Should there be clerks anywhere at all right now?
---
--- PLAYING AND ALIVE, on both clocks -- the match's and this player's -- which is
--- the same pair BR.GunshopSolve.canBuy rules on, so a counter is never offered
--- in a state the server would refuse. That pair is flagged in the solver's
--- header as needing the owner's confirmation (a DBNO player, and whether the
--- shops are also open in warmup); this file reads it rather than repeating it,
--- so his answer is one edit there.
--- @return boolean
local function wantScene()
    if not BR.GunshopSolve.enabled(G) then return false end
    if BR.State.match.state ~= BR.MatchState.PLAYING then return false end
    if BR.State.me.state ~= BR.PlayerState.ALIVE then return false end
    return true
end

--- Is this store's clerk actually standing on THIS client?
---
--- Handed to BR.GunshopSolve.nearest as its `present` filter so the SELECTION
--- skips a counter with nobody behind it, rather than being checked after the
--- fact. config/gunshop.lua asks for exactly this: "a model that will not stream
--- is a counter with nobody behind it [...] treat a failed request as 'no clerk'
--- rather than as an error".
--- @param store table
--- @return boolean
local function standing(store)
    local ped = clerks[store.id]
    return (ped ~= nil and ped ~= 0 and isTrue(DoesEntityExist(ped)))
end

-- ---------------------------------------------------------------------------
-- The menu
-- ---------------------------------------------------------------------------

--- Put the menu away.
--- @param why string  console only, and only when something unusual closed it
local function closeMenu(why)
    if not menuOpen then return end
    menuOpen  = false
    menuStore = nil
    if menu then pcall(menu.Visible, menu, false) end
    if why then print(('[br_core] gunshop: menu closed -- %s'):format(why)) end
end

--- Build the one menu, once.
---
--- ═══ THE COLORS ARE OURS AND THEY ARE APPLIED IN ONE PLACE ═══
---
--- BR.Menu (client/menu.lua) holds the palette and the two constructors; this
--- file names no hex and no HUD index. ScaleformUI takes color per menu at
--- construction, so without that helper every menu we ever write repeats the
--- same four decisions -- see its header for why it exists and why it is tiny.
---
--- ═══ WHAT EACH ROW SAYS, AND WHERE EVERY WORD CAME FROM ═══
---
---   the LABEL is BR.GunshopSolve.menuLabel -- config/weapons.lua's own display
---   name for a gun, config/loot.lua's own for an ammo pool, plus the bundle
---   size on ammo because a price for an unstated quantity cannot be judged;
---   the RIGHT LABEL is BR.ShopSolve.priceLine, which is the only "N Volts"
---   formatter in the tree. CALLING IT ACROSS THE NAMESPACE IS DELIBERATE:
---   br_core/fxmanifest.lua says BR.GunshopSolve shares no symbol with
---   BR.ShopSolve, and a second price formatter here would be two
---   representations of one format -- the defect both of those files' headers
---   are about. The currency's name arrives from BR.Config.Market.currency,
---   which is the one place the word "Volts" is spelled;
---   the PANEL COLOR is the row's own rarity through BR.RarityInfo, which is
---   what the loot glow and the inventory borders already read;
---   the DESCRIPTION is empty. There is nothing true to put in it that the row
---   does not already say, and inventing a sentence per gun is thirty pieces of
---   unrequested copy.
---
--- ITEMS ARE ADDED IN CATALOGUE ORDER, which is BR.Config.Weapons' authored
--- class grouping followed by BR.Config.AmmoOrder -- never pairs(). The
--- catalogue guarantees it and this loop does not re-sort.
--- @return boolean built
local function buildMenu()
    if menu then return true end
    -- NIL-GUARDED ON THE MODULE, NOT JUST ON ITS ANSWER, which is the shape
    -- every cross-file call in this project takes. A build without
    -- client/menu.lua is one where the honest outcome is a counter that does
    -- not open, said on the console -- not a nil index inside a keypress.
    if not (BR.Menu and BR.Menu.available and BR.Menu.available()) then
        print('^3[br_core] gunshop: ScaleformUI is not in this Lua state -- '
              .. 'the counters cannot open. Is ScaleformUI_Lua deployed?^7')
        return false
    end
    if #rows == 0 then return false end

    -- THE SUBTITLE IS EMPTY, ON PURPOSE. The strip under the banner still draws
    -- the item counter -- "3/30", in our gold -- and a counter is a number
    -- rather than copy. A word there would be a second invented string for a
    -- surface that reads fine without one.
    local built = BR.Menu.new(G.menuTitle, '')
    if not built then return false end

    local currency = BR.Config.Market and BR.Config.Market.currency
    for _, row in ipairs(rows) do
        local item = BR.Menu.item(
            BR.GunshopSolve.menuLabel(row),
            BR.ShopSolve.priceLine(row.price, currency),
            BR.Menu.rarityColor(row.rarity))
        if item then
            -- ═══ THE PRESS NAMES A ROW AND SAYS NOTHING ELSE ═══
            --
            -- No price, no balance, no claim about where it is standing --
            -- every one of those is resolved in server/gunshop.lua. The menu
            -- STAYS OPEN: there is no purchase limit at this counter, so a
            -- player buying a rifle and then two boxes of ammo is the ordinary
            -- case and closing the screen under them would be an invented rule.
            item.Activated = function()
                TriggerServerEvent(BR.Net.GUNSHOP_BUY, { id = row.id })
            end
            pcall(built.AddItem, built, item)
        end
    end

    -- AN EMPTY MENU IS NOT SHOWN, AND THAT IS A GUARD RATHER THAN TIDINESS.
    -- UIMenu:Visible(true) on a menu with no items calls
    -- MenuHandler:CloseAndClearHistory() and then ASSERTS -- an uncaught error
    -- raised out of a keypress handler. Reachable if every UIMenuItem.New above
    -- failed, which is the shape a version bump would take.
    if #built.Items == 0 then
        print('^3[br_core] gunshop: the menu built with no items -- not '
              .. 'opening it^7')
        return false
    end

    menu = built
    return true
end

--- Open the menu at one counter.
--- @param store table
local function openMenu(store)
    if menuOpen then return end
    if not buildMenu() then return end

    menuOpen  = true
    menuStore = store
    -- THE PLATE GOES DOWN WITH THE MENU UP. They say the same word, and one of
    -- them is a full-screen panel; leaving the world plate lit behind it is the
    -- same prompt twice.
    setPlate(false)
    pcall(menu.Visible, menu, true)
end

--- IS THIS FILE HOLDING THE INTERACT KEY OR THE SCREEN?
---
--- ═══ BUILT AHEAD OF ITS ONE CALLER, AND THE CALLER IS NAMED ═══
---
--- client/ambheal.lua's `prompting()` and client/revivekey.lua's `prompting()`
--- are the project's shape for this question, and the ONE place they are spent
--- is client/dbno.lua's single BR.Loot.suppress() call site -- one caller, one
--- OR, no possible disagreement, because BR.Loot.suppress is a plain boolean
--- with no refcount and a second writer would clear the first's yield.
---
--- THIS HAS NO CALLER YET. Adding it is one clause in that OR:
---
---     BR.Loot.suppress(busy
---         or (BR.ReviveKey ~= nil and BR.ReviveKey.prompting ~= nil
---             and BR.ReviveKey.prompting())
---         or (BR.Gunshop ~= nil and BR.Gunshop.busy ~= nil
---             and BR.Gunshop.busy()))
---
--- and it is not written here because client/dbno.lua is held by another agent
--- this round. Until it lands, a press at a counter with a crate underfoot
--- claims the crate as well -- which is the shared-prompt cost client/ambheal.lua
--- already documents, met for the first time in a place where it is likely
--- rather than rare.
--- @return boolean
function BR.Gunshop.busy()
    return menuOpen or plateShown
end

-- ---------------------------------------------------------------------------
-- The loops
-- ---------------------------------------------------------------------------

--- The clerks, reconciled once a second.
---
--- A RECONCILER RATHER THAN EDGE HANDLERS, which is client/shop.lua's argument
--- and it survives the move to a distance term unchanged: building on an edge
--- leaves every case that is not an edge -- joining mid-match, a br_core
--- restart, a state that flapped while a model was streaming -- to a handler
--- that did not run. Comparing want against have has no such cases.
---
--- SLOW BAND. The question is "has the player crossed sixty metres", and at a
--- sprint that is eight seconds; once a second is already finer than it needs.
--- Walking eleven stores at 1 Hz is eleven flat distances a second, which is
--- less arithmetic than one pass of the showroom's proximity scan.
BR.Loop.register(BR.Loop.SLOW, 'gunshop.clerks', function()
    if not wantScene() then
        if next(clerks) ~= nil or next(building) ~= nil then teardownAll() end
        return
    end

    local c = GetEntityCoords(PlayerPedId())
    for i = 1, #stores do
        local s = stores[i]
        -- "HAS" INCLUDES A BUILD IN FLIGHT, so the KEEP radius applies to a
        -- clerk who is still streaming. Without it a player hovering on the
        -- build radius would start a thread, fall outside it, and start another
        -- one a second later while the first was still waiting on a model.
        local has = standing(s) or building[s.id] == true
        if BR.GunshopSolve.wantsClerk(s, c.x, c.y,
                                      G.clerkBuildM, G.clerkKeepM, has) then
            if not has then buildClerk(s) end
        elseif standing(s) then
            dropClerk(s.id)
        end
        -- A BUILD THAT IS NO LONGER WANTED IS NOT CHASED DOWN, and that is a
        -- decision rather than an omission. It finishes, files its ledger row --
        -- which is the reading the owner is collecting anyway -- and the NEXT
        -- pass of this loop, one second later, drops the clerk it made. Adding a
        -- per-store abandon token would be a second generation counter to keep
        -- right, to save one ped for one second.
    end
end)

--- Which counter is the player at?
---
--- ON THE TICK BAND, NOT THE FRAME BAND. Walking speed is about two metres a
--- second and the reach is 2.5m, so ten passes a second is already finer than
--- the question can change -- client/shop.lua's argument, and this pass does
--- less work than that one because the eleven stores are a flat sweep with no
--- entity reads until something is in reach.
---
--- ═══ AND IT IS WHAT PUTS THE MENU AWAY ═══
---
--- Three ways the menu closes and all of them are here: the player leaves the
--- counter it was opened at, the match or the player leaves PLAYING/ALIVE, or
--- one of our NUI screens takes the keyboard. The fourth is the library's own
--- Back button, which needs nothing from this file.
BR.Loop.register(BR.Loop.TICK, 'gunshop.prompt', function()
    if not wantScene() then
        setPlate(false)
        candidate = nil
        closeMenu(nil)
        return
    end

    -- ═══ A NUI SCREEN OWNING THE KEYBOARD CLOSES THE MENU ═══
    --
    -- br_ui's focus stack and ScaleformUI's control disabling are two different
    -- mechanisms that do not know about each other: the menu holds input with
    -- DisableAllControlActions and the inventory holds it with SetNuiFocus, and
    -- with both up the player is reading one screen while the other one is still
    -- taking their arrow keys. `uiScreen` is br_ui's own answer to "is one of our
    -- panels up" (client/keybinds.lua), and it is the right one rather than
    -- `uiOwnsKeyboard`, which is deliberately false for the inventory.
    if BR.Keys.uiScreen ~= nil then
        setPlate(false)
        candidate = nil
        closeMenu(nil)
        return
    end

    local c = GetEntityCoords(PlayerPedId())
    local best = BR.GunshopSolve.nearest(stores, c.x, c.y,
                                         tonumber(G.reachM) or 2.5, standing)
    candidate = best

    if menuOpen then
        -- THE MENU BELONGS TO THE COUNTER IT WAS OPENED AT. Comparing the store
        -- rather than testing for any store in reach is what stops a menu opened
        -- at one counter surviving a walk to another -- which cannot happen at
        -- these anchors and is the correct shape regardless.
        if best ~= menuStore then closeMenu(nil) end
        -- The plate stays down for as long as the menu is up.
        setPlate(false)
        return
    end

    setPlate(best ~= nil)
end)

--- ...and drawing the plate, which has to be per frame: BR.Dui.drawFace is a
--- pair of DrawSpritePoly calls and a poly lasts exactly one frame. The TICK
--- pass decides WHETHER; this decides WHERE.
---
--- ═══ IT HANGS OFF THE CLERK, AND THAT IS ONLY SAFE BECAUSE HE IS FROZEN ═══
---
--- BR.Dui.drawFace takes an ENTITY and lays the sign along that entity's
--- flattened forward vector, so a ped that turned to look at the player would
--- swing the sign with him. The clerk cannot: he is created at a fixed heading,
--- frozen, and blocked from every non-temporary event, so he has no task that
--- could turn him. THAT IS A PRECONDITION OF DRAWING THIS WAY rather than a
--- happy accident -- the day a clerk is given an idle animation that turns him,
--- this needs a world-anchored draw instead (drawPlane in client/dui.lua is
--- file-local; exposing a `drawFaceAt` over it is the shape that would take).
---
--- A PED'S ORIGIN IS AT HIS FEET, unlike a vehicle's, which is why the two
--- offsets are authored in config rather than derived from a model box the way
--- BR.ShopSolve.signHeight derives a bumper.
BR.Loop.register(BR.Loop.FRAME, 'gunshop.draw', function()
    if not plateShown or not candidate then return end
    local ped = clerks[candidate.id]
    -- RE-CHECKED, because reading the coordinates of a dead handle throws -- and
    -- in a frame callback five of those cost the whole band.
    if not ped or ped == 0 or not isTrue(DoesEntityExist(ped)) then return end

    BR.Dui.drawFace(promptPage(), ped,
                    tonumber(G.signForwardM) or 0.55,
                    tonumber(G.signUpM) or 1.05,
                    tonumber(G.signWidthM) or 0.55)
end)

-- ---------------------------------------------------------------------------
-- Buying
-- ---------------------------------------------------------------------------

--- THE PRESS ACTS ON WHAT WAS DRAWN, never on a fresh search. #128 again.
---
--- ═══ IT DOES NOTHING WHILE THE MENU IS OPEN, AND THE GUARD IS NOT BELT AND
---     BRACES ═══
---
--- ScaleformUI holds input with Controls:ToggleAll(false) --
--- DisableAllControlActions plus a re-enabled whitelist -- and this project's
--- interact key does not go through control actions at all when the raw layer is
--- running: client/keybinds.lua reads the keyboard itself under `rawActive` and
--- fires listeners from its own frame pass, which no amount of control disabling
--- can reach. The menu's own Select is INPUT_FRONTEND_ACCEPT (Enter), a
--- different key entirely, so E at an open menu is a press with nothing to do.
--- Without this line it would fall through to whatever else wants the key.
BR.Keys.on('interact', function(pressed)
    if not pressed then return end
    if menuOpen then return end
    if not plateShown then return end
    local store = candidate
    if not store then return end
    openMenu(store)
end)

--- The purchase landed.
---
--- BY KEY, THROUGH BR.Sfx, AND NOT AS A SET/NAME PAIR WRITTEN HERE.
--- tools/verify.sh refuses an inlined pair outside three files, and the reason is
--- good: a pair nothing knows the key of cannot be auditioned with /brsfx,
--- cannot be re-pointed with `brsfx bind`, and fails silently when the set is
--- wrong. The key is config/gunshop.lua's `cue`, which resolves to the owner's
--- own pick for "Shop purchase complete".
---
--- THE MENU STAYS OPEN AND NOTHING IS SAID. There is no toast on this path --
--- the owner has written none for this feature -- and the feedback is the cue,
--- the item appearing in the bag, and the Volts readout on the HUD dropping,
--- all of which are mechanisms that already existed.
RegisterNetEvent(BR.Net.GUNSHOP_BOUGHT)
AddEventHandler(BR.Net.GUNSHOP_BOUGHT, function(d)
    if type(d) ~= 'table' then return end
    if BR.Sfx and G.cue then BR.Sfx.play(G.cue) end
end)

-- ---------------------------------------------------------------------------
-- The dev command
-- ---------------------------------------------------------------------------
--
-- ═══ ELEVEN GUESSES INTO ELEVEN NUMBERS ═══
--
-- config/gunshop.lua authors no clerk height and says why: the sources disagree
-- by up to about 1.1m on what the tabulated z means and no survey can settle it
-- from outside the game. This command is how it gets settled -- walk into a
-- store, let the clerk build, and the `delta` column is exactly how far the
-- table was out at that counter. Where the probe and the anchor agree, the row
-- was a floor; where they differ by about a metre, it was a standing figure.
--
-- ITS OUTPUT IS PASTEABLE. Any row that needs pinning becomes a `zOverride` in
-- config/gunshop.lua, which is the slot that shipped empty for exactly this.
--
-- CONSOLE ONLY. Nothing here draws, notifies, or speaks to a player, and the
-- dev gate is BY CONSTRUCTION: br_lib/shared/devgate.lua replaces the global
-- RegisterCommand with a gated wrapper before any br_core file loads.

--- A metre reading, or a dash where there is nothing to read.
---
--- "-0.00" IS NOT A READING. Every delta here is a difference of two floats that
--- may be equal, so a probe that agreed exactly with the table answers with a
--- value a hair under zero about half the time -- and "-0.00" in a column headed
--- `delta` reads as "the clerk sank a little", which is the opposite of what it
--- means. client/shop.lua's /brshop carries the same helper for the same reason.
--- @param v number|nil
--- @return string
local function m(v)
    if type(v) ~= 'number' then return '-' end
    local s = ('%.2f'):format(v)
    if s == '-0.00' then return '0.00' end
    return s
end

--- A BOOL THIS FILE RECORDED EARLIER, as a column.
---
--- NOT a live native read. "There is no record" -- a counter never visited --
--- has to stay distinct from "the probe answered no", because collapsing those
--- two would make an unvisited store read as one where the ground probe failed,
--- which is the exact claim this table exists to make.
--- @param v boolean|nil
--- @return string
local function yn(v)
    if v == nil then return '-' end
    return v and 'Y' or 'N'
end

RegisterCommand('brgunshop', function()
    local ped = PlayerPedId()
    local p = GetEntityCoords(ped)

    local nClerks = 0
    for _ in pairs(clerks) do nClerks = nClerks + 1 end

    print('=== gunshop (client) ===')
    print(('  match %s   me %s   scene %s   counters %d   rows %d   clerks %d')
        :format(tostring(BR.State.match.state), tostring(BR.State.me.state),
                wantScene() and 'ON' or 'off', #stores, #rows, nClerks))
    print(('  menu %s   library %s   plate %s   at %s')
        :format(menuOpen and 'OPEN' or 'closed',
                (BR.Menu and BR.Menu.available and BR.Menu.available())
                    and 'present' or 'ABSENT',
                plateShown and 'up' or 'down',
                candidate and tostring(candidate.id) or '-'))
    print(('  you %.2f, %.2f, %.2f   build %.0fm / keep %.0fm   reach %.1fm   '
           .. 'probe lift %.2fm   probe budget %dms')
        :format(p.x, p.y, p.z,
                tonumber(G.clerkBuildM) or 0.0, tonumber(G.clerkKeepM) or 0.0,
                tonumber(G.reachM) or 0.0, tonumber(G.probeLiftM) or 0.0,
                tonumber(G.probeWaitMs) or 0))

    -- ═══ `delta` IS THE COLUMN THIS COMMAND EXISTS FOR ═══
    --
    -- `anchor` is what config/gunshop.lua tabulates, `z` is where the clerk was
    -- actually put, and `delta` is the difference. A store reading 0.00 had a
    -- FLOOR in the table; a store reading about -1.0 had a STANDING FIGURE, and
    -- the whole reason no clerk z is authored is that nobody could tell those
    -- apart from the number alone. `src` says which of the three answers won,
    -- and `probe` says what the engine actually said as opposed to what was
    -- used -- a row with `src anchor` and `probe N` is a counter the world had
    -- not streamed under, which is a different fault from a bad coordinate.
    print(('  %-9s %-18s %7s %7s %7s %7s %7s %-4s %-8s %6s %8s')
        :format('id', 'model', 'anchor', 'from', 'probe', 'z', 'delta',
                'hit', 'src', 'wait', 'age(s)'))

    local now = GetGameTimer()
    local probed, off = 0, 0
    for i = 1, #stores do
        local s   = stores[i]
        local rec = placed[s.id]
        if rec then
            print(('  %-9s %-18s %7s %7s %7s %7s %7s %-4s %-8s %6d %8.1f')
                :format(tostring(s.id), tostring(rec.model),
                        m(rec.anchorZ), m(rec.fromZ), m(rec.gz), m(rec.z),
                        m(rec.delta), yn(rec.hit), tostring(rec.source),
                        tonumber(rec.waitedMs) or 0,
                        (now - (tonumber(rec.at) or now)) / 1000.0))
            if rec.source == 'probe' then probed = probed + 1 end
            if type(rec.delta) == 'number' and math.abs(rec.delta) > 0.10 then
                off = off + 1
            end
        else
            -- NEVER VISITED IS NOT A FAILED PROBE. A counter with no ledger row
            -- has simply never had a player within `clerkBuildM` of it this
            -- session, and printing it as dashes says so rather than leaving it
            -- out and making the table look complete.
            print(('  %-9s %-18s %7s %7s %7s %7s %7s %-4s %-8s %6s %8s')
                :format(tostring(s.id), '-', m(tonumber(s.z)), '-', '-', '-',
                        '-', '-', 'unvisited', '-', '-'))
        end
    end

    -- THE VERDICT LINE IS THREE COUNTS AND NO OPINION. `visited` is how much of
    -- the map has been walked, `probed` is how many of those got a real answer
    -- out of the engine, and `off by >0.10m` is how many anchors the table has
    -- wrong -- which is the number the owner came for.
    local visited = 0
    for _ in pairs(placed) do visited = visited + 1 end
    print(('  visited %d/%d   answered by probe %d   anchors off by >0.10m %d')
        :format(visited, #stores, probed, off))
end, false)

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

--- REGISTERED HERE RATHER THAN AT CONFIG LOAD, and this is one of the two call
--- sites of BR.Config.Gunshop.build() -- the other is server/gunshop.lua.
--- config/gunshop.lua's header explains: br_lib's fxmanifest expands
--- `config/*.lua` as a glob, `gunshop` sorts before `weapons`, and a catalogue
--- derived at that file's own load would be an empty shop with no error
--- anywhere. By the time br_core loads, every br_lib script has run whatever
--- order it ran in.
---
--- BUILD PRINTS ITS OWN REJECTS, so nothing here repeats them.
AddEventHandler('onClientResourceStart', function(res)
    if res ~= GetCurrentResourceName() then return end

    rows = select(1, BR.Config.Gunshop.build())

    local rejects
    stores, rejects = BR.GunshopSolve.stores(G)
    for _, r in ipairs(rejects) do
        print(('^3[br_core] gunshop: counter "%s" is unusable -- %s^7')
            :format(tostring(r.id), tostring(r.why)))
    end
end)

--- A clerk left standing into the next match is a ped nothing owns.
AddEventHandler('onClientResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    closeMenu(nil)
    setPlate(false)
    teardownAll()
end)
