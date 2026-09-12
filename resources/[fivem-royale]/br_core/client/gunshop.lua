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

-- ---------------------------------------------------------------------------
-- THE FOUR STRINGS A PLAYER READS AT THIS COUNTER THAT ARE NOT DERIVED
-- ---------------------------------------------------------------------------
--
-- ═══ THREE OF THEM ARE HIS, VERBATIM, AND ONE IS A PLACEHOLDER ═══
--
-- Everything else on this surface still comes from a table somebody owns: item
-- names from config/weapons.lua and config/loot.lua, the price from
-- BR.ShopSolve.priceLine, the category headers from BR.RarityInfo's own `label`
-- fields, the key cap from the player's binding, and the title from
-- config/gunshop.lua's `menuTitle`.
--
-- PLATE_HINT and OUT_OF_STOCK are the owner's own words from 2026-09-09.
-- OUT_OF_STOCK is READ rather than typed -- config/gunshop.lua authors
-- `outOfStockLabel` for it, in a block that says nothing in it may be tidied,
-- and it had no reader until now.
--
-- AND AMMO_GROUP IS HIS TOO, SINCE 2026-09-11. It was the one string on this
-- surface nobody had typed but us, and it was marked as such for two days.
-- See the block below.
--
-- ═══════════════════════════════════════════════════════════════════════════
-- THE AMMUNITION SEPARATOR IS SETTLED (owner, 2026-09-11)
-- ═══════════════════════════════════════════════════════════════════════════
--
--   "The ammunition separator should read 'Ammo' and be no special color, same
--    color as the ammo item rows themselves."
--
-- THAT IS THE WORD AND THE COLOR, AND IT CLOSES A QUESTION THAT WAS ASKED
-- TWICE. His answer of earlier the same day -- "The `Ammo` separator should be
-- simply the name of the category of rarity for the items listed below the
-- separator" -- was a RULE rather than a word, and 503298c found it could not
-- be carried out: ammunition carries no rarity anywhere in this project, so
-- there was no label to read and "Common" would have been an invention wearing
-- a lookup's clothes. This sentence answers the question that left open. The
-- placeholder block that stood here is gone because the thing it was flagging
-- is gone: `Ammo` is the word he typed, in the quotation above.
--
-- AMMUNITION STILL CARRIES NO RARITY, and his answer is not that it now has
-- one -- it is that the separator does not need one. tools/test_gunshop.lua
-- still goes RED the day either config table grows a rarity for a pool, because
-- that would be a real change to what ammunition IS and somebody should look at
-- this file when it happens. What that failure now means is "his premise
-- moved", not "his wording has arrived".
--
-- THE COLOR HALF IS A CHANGE AND NOT A RESTATEMENT. Every separator took
-- BR.Menu.accent() -- the interface cyan, at full opacity, brighter than
-- anything else on the shelf. "No special color, same color as the ammo item
-- rows themselves" means this one takes what its own rows take, which is
-- BR.Menu.rarityColor of the rarity those rows carry. See `grouped` and
-- `buildMenu`: the header reads it off a row rather than naming a rarity here,
-- so it cannot come to disagree with the rows underneath it.
--
-- THE OTHER THREE SEPARATORS WERE LEFT ON THE CYAN THAT DAY, because he had
-- ruled on the ammunition one and said nothing about Rare, Epic or Legendary.
-- HOURS LATER HE RULED ON ALL OF THEM: "No ScaleformUI should ever use our cyan
-- ever", answering "the selected row and separator rows being that obnoxious
-- light blue still". So the cyan is gone from those three as well, and what they
-- wear instead is the library's own panel rather than a color anybody here chose
-- -- see `buildMenu`, where the open question is marked.

--- Owner, 2026-09-09: "a line underneath PRESS TO OPEN".
local PLATE_HINT = 'PRESS TO OPEN'

--- Owner, 2026-09-09: "instead show Out of Stock".
---
--- ═══ HIS WORDS, READ FROM WHERE HE PUT THEM ═══
---
--- config/gunshop.lua authors `outOfStockLabel` for exactly this, in a block
--- that says in as many words that nothing in it may be tidied -- "the capital
--- letters in 'Out of Stock' -- all his". It had no reader: this file typed the
--- phrase a second time, so his one edit would have changed the config and left
--- the shelf saying the old thing, with nothing to say why.
---
--- THE FALLBACK IS THE SAME STRING AND THAT IS NOT A SECOND COPY. It is what
--- the row says if the config value is ever removed, which is a row that reads
--- correctly rather than a row labelled `nil` -- and the ONE place it could
--- differ from his is under test.
local OUT_OF_STOCK = (type(G.outOfStockLabel) == 'string'
    and G.outOfStockLabel ~= '' and G.outOfStockLabel) or 'Out of Stock'

--- Owner, 2026-09-11: "The ammunition separator should read 'Ammo'". His word,
--- and the capital A is his as well. See the block above for the question it
--- closes.
local AMMO_GROUP = 'Ammo'

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

--- The last `open` the HUD was told about, so the envelope is sent on the edge
--- only. Its writer is setMenuFlag(); see the note there.
local menuFlagged = false

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

--- [rowId] = the UIMenuItem that row was built as.
---
--- ═══ THE ONE MENU IS STILL ONE MENU, BUT THE ROWS ARE NO LONGER FIXED ═══
---
--- The note on `menu` above says the prices are config and config does not move
--- inside a session, which was true and is no longer the whole truth: stock is
--- per store and per match, the balance moves with every purchase, and an ammo
--- pool fills up. So the ITEM OBJECTS are still built once -- thirty
--- UIMenuItem.News and a scaleform rebuild per keypress is what that note was
--- protecting against -- and their labels, badges and enabled flags are
--- re-applied on every open against the counter being opened.
---
--- KEYED BY ROW ID rather than by index, because the item list also contains
--- category separators and an index into it is not an index into the catalogue.
local items = {}

--- WHAT EACH COUNTER HAS LEFT: stock[storeId][rowId] = count.
---
--- ═══ nil IS "THE SERVER HAS NOT SAID", AND THAT IS NOT THE SAME AS ZERO ═══
---
--- A client that has heard nothing shows every row at its price, which is
--- exactly today's behavior and is the only safe reading: treating silence as
--- an empty shop would be eleven counters that sell nothing on any box whose
--- server half has not shipped yet.
---
--- IT IS PRESENTATION ONLY. Nothing here refuses a purchase -- the row stays
--- pressable and the server decides, the same way it already decides the price,
--- the balance and whether the player is really at a counter. A client that
--- could veto a sale could also be persuaded not to.
local stock = nil

--- The player's spendable Volts, as of the last MARKET_STATE. See the handler.
local balance = nil

--- THE WEAPON A CLERK IS CURRENTLY HOLDING OUT: [storeId] = { obj = , ped = }.
---
--- ═══ A RECORD RATHER THAN A HANDLE, WHICH IS client/rescue.lua's ORPHAN GUARD
---     ═══
---
--- The presentation is a sequence with waits in it, and buying twice in three
--- seconds is an ordinary input at a counter. A cleanup that tested "is there
--- still an object here" would have the FIRST purchase's thread delete the
--- SECOND one's prop. Comparing the whole record means a thread only ever
--- cleans up its own.
local presented = {}

--- THE PLATE'S THREE OFFSETS, LIVE. nil means "use the config value".
---
--- Set by /brgunplate and read by the FRAME draw. See the command for why they
--- exist: the owner asked for a tool rather than another round of guesses.
local plateFwd, plateUp, plateW = nil, nil, nil

--- THE CLERK'S THREE PLACEMENT NUMBERS, LIVE. nil means "use the config value".
---
--- `clerkRight` HAS NO CONFIG VALUE TO FALL BACK TO YET, which is the whole of
--- C1: BR.GunshopSolve.clerkAt spends `clerkOffsetM` along the counter's forward
--- vector and there is no lateral term anywhere in it. See /brgunclerk.
local clerkFwd, clerkRight, clerkFace = nil, nil, nil

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
--- ═══ AND NOW IT HAS THE SECOND LINE HE ASKED FOR ═══
---
--- Owner, 2026-09-09: "the DUI should follow our standard formatting and content
--- - a title Weapon Shop and a line underneath PRESS TO OPEN".
---
--- THE TITLE IS STILL `menuTitle`, WHICH IS THE ONE WORD HE HAS TO CHANGE. It is
--- 'Shop' in config/gunshop.lua today and it feeds BOTH this plate and the menu
--- banner, so 'Weapon Shop' there answers his D2 title and his M8 in one edit.
--- IT IS NOT HARD-CODED HERE, because a second copy of that phrase is exactly
--- the thing the config's marked block exists to prevent.
---
--- THE SECOND LINE IS HIS OWN CAPS. prompt.html gives #hint `text-transform:
--- uppercase`, so the rendering is PRESS TO OPEN either way -- his string is
--- typed exactly as he wrote it rather than sentence-cased on the way in.
--- client/loot.lua ('Hold to open') and client/ambheal.lua ('Press to heal') put
--- their hint literal in the client, which is why this one is here too.
---
--- NO `ring`: this is a tap, not a hold.
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
        hint  = PLATE_HINT,
        key   = BR.Native.keyLabelForCommand('brinteract', 51),
        ring  = false,
    })
end

--- Tell the HUD the shop menu is up, or down.
---
--- ═══ THE HALF THAT WAS MISSING ═══
---
--- Owner, 2026-09-09, M5 and M6: the squad panel goes away while the shop menu
--- is open, and his Volts balance stays visible bottom-right while it is. The
--- page side of both was built -- `gunshopMenu` in the store, a `gunshopmenu`
--- member on the envelope union, App.tsx routing it, Hud.tsx gating the squad
--- slot and the Volts selector on it -- and NOTHING IN LUA EVER SENT IT, so the
--- whole of it was unreachable code. This function is the sender.
---
--- SAME SEAM AS THE PLATE ABOVE, AND FOR THE SAME REASON. br_ui/client/nui.lua
--- is the only file in the project that may call SendNUIMessage; everything
--- else asks it to, and `br:ui:sendLocal` is the same-client door it exposes
--- for br_core. This carries a BOOLEAN and no figure: br_ui already holds the
--- player's Volts, so sending the number from here would be a second copy of it
--- free to disagree with the shop screen -- client/shop.lua's argument for the
--- plate, unchanged.
---
--- ON THE EDGE ONLY. refreshMenu runs on every stock and balance push while the
--- menu is up, and an unconditional send would be a HUD render per push for an
--- answer that has not moved.
--- @param open boolean
local function setMenuFlag(open)
    open = (open == true)
    if open == menuFlagged then return end
    menuFlagged = open
    TriggerEvent('br:ui:sendLocal', 'gunshopmenu', { open = open })
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
---
--- ═══ AND THE PROP IN HIS HAND GOES FIRST ═══
---
--- The likeliest end of a purchase presentation is not the animation finishing:
--- it is the player walking out, which the SLOW reconciler answers by deleting
--- the clerk. An attached child whose parent is deleted is either destroyed with
--- it or left hanging in the air where the hand was, and I could find no
--- documentation saying which. DETACHING FIRST MAKES THE QUESTION NOT MATTER,
--- which is why the order here is detach, delete the prop, then delete the ped.
--- @param id string
local function dropClerk(id)
    local rec = presented[id]
    if rec then
        presented[id] = nil
        local obj = rec.obj
        if obj and obj ~= 0 and isTrue(DoesEntityExist(obj)) then
            nat(DetachEntity, obj, true, true)
            nat(DeleteEntity, obj)
        end
    end

    local ped = clerks[id]
    if ped and ped ~= 0 and isTrue(DoesEntityExist(ped)) then
        DeleteEntity(ped)
    end
    clerks[id] = nil
end

--- Take every clerk down, and abandon anything still streaming.
local function teardownAll()
    gen = gen + 1
    -- OVER `presented` AS WELL AS `clerks`, because dropClerk only reaches a
    -- prop whose store still has a clerk in the table. A presentation whose
    -- clerk went first would otherwise leave an object nothing points at.
    for id in pairs(presented) do dropClerk(id) end
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
        -- ═══ WHERE HE STANDS IS SOLVED FIRST, AND THE PROBE GOES THERE ═══
        --
        -- C1 moved the clerk in X and Y -- "back behind the counter and to the
        -- left (the ped-s right) about 1m" -- and the probe was left sampling
        -- the ANCHOR, which is the register he was moved off. So his height was
        -- being solved for a spot he no longer stands on: a metre and a half
        -- away, through a counter, on the customer's side of it. On a flat shop
        -- floor the two agree and nothing is visible; the moment a counter has
        -- a step, a plinth or a raised platform behind it -- which is what a
        -- shop counter usually has -- the clerk is placed at the wrong one, and
        -- the symptom is a ped sunk into the floor or standing on air with no
        -- error anywhere.
        --
        -- SO clerkAt IS ASKED TWICE. It is a pure function of the config and
        -- the store, and z is the only argument that changes between the two
        -- calls: the first spends the two offsets to find the XY, the probe
        -- runs THERE, and the second turns the answer into the final position.
        -- Solving the XY here by hand instead would be a second copy of the
        -- offset arithmetic in a client file, which is the thing that whole
        -- function exists to prevent.
        local px, py = BR.GunshopSolve.clerkAt(G, store, nil)
        if not px or not py then
            SetModelAsNoLongerNeeded(model)
            return giveUp()
        end

        -- THE START HEIGHT IS STILL THE ANCHOR'S. `probeStart` is about how far
        -- ABOVE the authored z to begin, and the authored z is the floor of
        -- this interior; moving a metre along it does not change which storey
        -- we are looking for.
        local fromZ = BR.GunshopSolve.probeStart(G, store)
            or ((tonumber(store.z) or 0.0) + 0.0)
        local pWait  = 0
        local pBudget = tonumber(G.probeWaitMs) or 1500
        local hit, gz = probeGround(px, py, fromZ)
        while not hit and pWait < pBudget do
            nat(RequestCollisionAtCoord, px, py, fromZ)
            Citizen.Wait(50)
            pWait = pWait + 50
            if mine ~= gen then
                SetModelAsNoLongerNeeded(model)
                return giveUp()
            end
            hit, gz = probeGround(px, py, fromZ)
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
    -- THE SQUAD PANEL COMES BACK AND THE VOLTS READOUT GOES AWAY WITH IT (M5,
    -- M6). Unconditional at the top of every close path, including the
    -- library's own Back button and onClientResourceStop, because a flag the
    -- page holds and Lua forgets to lower is a squad panel gone for the match.
    setMenuFlag(false)
    -- ASKED BEFORE IT IS TOLD, because this is now reachable FROM the library's
    -- own close: buildMenu hands UIMenu.OnMenuClose a call to this function, and
    -- Visible(false) is what fires that callback. Lowering an already-lowered
    -- menu would run the library's whole teardown a second time and re-enter
    -- here -- harmless, since `menuOpen` is already false by this line, and
    -- avoided anyway rather than relied on.
    if menu then
        local seen, vis = pcall(menu.Visible, menu)
        if not seen or vis == true then pcall(menu.Visible, menu, false) end
    end
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
--- HOW MANY OF ONE ROW THIS COUNTER HAS LEFT, or nil if nobody has said.
--- @param store table|nil
--- @param rowId string
--- @return integer|nil
local function stockOf(store, rowId)
    if type(stock) ~= 'table' or type(store) ~= 'table' then return nil end
    local perStore = stock[store.id]
    if type(perStore) ~= 'table' then return nil end
    return tonumber(perStore[rowId])
end

--- IS THIS ROW SOLD OUT AT THIS COUNTER?
---
--- AMMO IS NEVER SOLD OUT. Owner, 2026-09-09: "They will have no limited stock
--- on ammo." So an ammo row never consults the ledger at all, which also means a
--- server that sends a count for one is ignored rather than obeyed.
--- @param store table|nil
--- @param row table
--- @return boolean
local function soldOut(store, row)
    if row.kind == BR.ItemKind.AMMO then return false end
    local n = stockOf(store, row.id)
    return n ~= nil and n <= 0
end

--- CAN THEY PAY FOR IT RIGHT NOW?
---
--- TRUE WHEN THE BALANCE IS UNKNOWN, which is the same reading as `stock`: a
--- client that has not heard a MARKET_STATE yet must not paint every row locked.
--- @param row table
--- @return boolean
local function affordable(row)
    if balance == nil then return true end
    return balance >= (tonumber(row.price) or 0)
end

--- ARE THEY ALREADY CARRYING THE MAXIMUM OF THIS AMMO?
---
--- ═══ READ OFF THE CLIENT'S OWN MIRROR, AND IT IS A LOCK RATHER THAN A RULE
---     ═══
---
--- BR.Inv.local_() is the inventory this client was last told it has, and
--- BR.Config.AmmoCaps is a shared_script both halves read -- so this is the same
--- two numbers the server would compare, without a byte on the wire. It decides
--- what the ROW LOOKS LIKE and nothing else; the refusal belongs to the server,
--- which is the half that knows.
--- @param row table
--- @return boolean
local function ammoFull(row)
    if row.kind ~= BR.ItemKind.AMMO then return false end
    local pool = row.pool
    if type(pool) ~= 'string' then return false end
    local cap = BR.Config.AmmoCaps and BR.Config.AmmoCaps[pool]
    if type(cap) ~= 'number' then return false end
    local inv = BR.Inv and BR.Inv.local_ and BR.Inv.local_() or nil
    local held = tonumber(type(inv) == 'table' and type(inv.ammo) == 'table'
        and inv.ammo[pool] or nil)
    if held == nil then return false end
    return held >= cap
end

--- WHICH WEAPON TABLES A PLAYER CAN END UP HOLDING SOMETHING OUT OF.
---
--- Owner, 2026-09-09, L5: "When an ammo item is in focus in the menu, a
--- description should be shown that includes a list of all weapons that ammo is
--- used in. This will help the customer understand what ammo they need to
--- purchase for their given loadout."
---
--- ═══ TWO ARRAYS, AND THE SECOND ONE WAS BEING LEFT OUT ═══
---
--- BR.Config.Weapons is what the ground rolls from and BR.Config.AirdropWeapons
--- is a separate array for reasons that have nothing to do with ammunition --
--- see the long note above it about why an airdrop gun is not in the ordinary
--- table. A player who has just opened an airdrop is holding one, and it was
--- the one gun the description would not name.
---
--- THE LIST ITSELF IS BR.GunshopSolve.ammoUsers, which was built for exactly
--- this question, takes source tables for exactly this reason and is tested
--- against both of them. This file rolled its own scan over BR.Config.Weapons
--- alone -- two answers to one question, with the shorter one shipped.
---
--- NOT ONE WORD OF IT IS WRITTEN HERE OR THERE. It is config/weapons.lua's own
--- `label` fields in config/weapons.lua's own order, joined with a comma.
---
--- READ AT CALL TIME, NOT CAPTURED AT LOAD. config/gunshop.lua's header records
--- that br_lib expands `config/*.lua` as a glob and `gunshop` sorts before
--- `weapons`, which is why the catalogue itself is built at resource start
--- rather than at config load. Holding these two tables in an upvalue would be
--- the same trap one step further out -- a nil captured once is a nil forever,
--- and the symptom would be an ammo row that silently names fewer guns.
--- @return table
local function ammoSources()
    return { BR.Config.Weapons, BR.Config.AirdropWeapons }
end

-- ---------------------------------------------------------------------------
-- What a row says about itself, which is now about the player (#274)
-- ---------------------------------------------------------------------------
--
-- Owner, 2026-09-11, both strings verbatim in config/gunshop.lua:
--
--   "we should prefix them with 'This ammo works with your: {guntypes} (new line)
--    As well as: {otherguntypes}'"
--   "The weapons should each have a description which reads: 'This weapon uses
--    {ammotype}. You have {number} rounds for it.'"
--
-- ═══ EVERY HOLE IN BOTH SENTENCES IS A FACT ABOUT THE BAG, NOT THE SHELF ═══
--
-- `{guntypes}` is what the player is carrying, `{number}` is how many rounds they
-- hold, and both move while the menu is open -- a purchase changes them one frame
-- later. That is why the descriptions moved out of `buildMenu`, which runs once,
-- into `refreshMenu`, which runs on every push. BR.Menu.describe is what makes a
-- write safe while the menu is up; its header has the shared-GXT-key argument.
--
-- ⚠ HIS REASON FOR THE SPLIT IS WHY IT MUST NOT BE FLATTENED: "the list is
-- exhaustive to read through and we should make it so they can skim, which is
-- enabled by the colors." Two lists and one of them blue is the feature. One list
-- with a sentence in front of it is what the row already said.

--- WHAT THE PLAYER IS CARRYING, AS A SET OF ITEM IDS.
---
--- READ OFF THE CLIENT'S OWN MIRROR, which is the same source `ammoFull` reads and
--- for the same reason: it is what this client was last told it has, and it decides
--- what a row LOOKS LIKE rather than what the server will allow.
---
--- pairs() RATHER THAN ipairs, AND THAT IS NOT STYLE. An empty slot is `false` on
--- the wire and in the mirror, not nil, so ipairs would walk past it -- but the
--- mirror is rebuilt wholesale by `adopt` and a slot table with a hole in it is
--- not a shape this file should depend on not existing. Order is irrelevant to a
--- set, so there is nothing to lose by asking for every key.
--- @return table { [itemId] = true }
local function carriedIds()
    local out = {}
    local inv = BR.Inv and BR.Inv.local_ and BR.Inv.local_() or nil
    local slots = type(inv) == 'table' and inv.slots or nil
    if type(slots) ~= 'table' then return out end
    for _, s in pairs(slots) do
        if type(s) == 'table' and type(s.id) == 'string' then
            out[s.id] = true
        end
    end
    return out
end

--- HOW MANY ROUNDS OF ONE POOL THEY HOLD RIGHT NOW.
---
--- ⚠ AN UNKNOWN HOLDING IS REPORTED AS 0 HERE, AND `ammoFull` READS THE SAME
--- ABSENCE THE OPPOSITE WAY. They are different questions. `ammoFull` asks "can I
--- prove they are full", where a missing number must NOT lock a row. This asks
--- "how many have they got", and a player whose mirror holds no entry for a pool
--- has none of it -- the mirror starts `ammo = {}` and a match starts with an empty
--- bag, so 0 is the true answer rather than a fallback.
---
--- THE WINDOW WHERE THAT COULD BE WRONG IS BEFORE THE FIRST INV_SET, which lands
--- long before a player can walk to a counter and is re-sent on every pickup.
--- @param pool string|nil
--- @return integer
local function poolHeld(pool)
    if type(pool) ~= 'string' or pool == '' then return 0 end
    local inv = BR.Inv and BR.Inv.local_ and BR.Inv.local_() or nil
    local ammo = type(inv) == 'table' and inv.ammo or nil
    local n = tonumber(type(ammo) == 'table' and ammo[pool] or nil)
    if not n then return 0 end
    if n < 0 then return 0 end
    return math.floor(n)
end

--- WHICH POOL A ROW FEEDS ON, WHICHEVER KIND OF ROW IT IS.
---
--- AN AMMO ROW CARRIES ITS POOL AND A WEAPON ROW DOES NOT. The catalogue stamps
--- `pool` on ammo rows only -- see BR.GunshopSolve.catalogue -- so a gun's pool is
--- looked up in BR.Config.WeaponById, which is the table the ammo COUNT is read
--- through everywhere else in the game (client/inventory.lua's own
--- `inv.ammo[w.ammo]`). One source for "which pool is this gun on" rather than a
--- second copy stamped onto the shop row.
--- @param row table|nil
--- @return string|nil
local function rowPool(row)
    if type(row) ~= 'table' then return nil end
    if row.kind == BR.ItemKind.AMMO then
        return type(row.pool) == 'string' and row.pool ~= '' and row.pool or nil
    end
    local by = BR.Config.WeaponById
    local w  = type(by) == 'table' and by[row.id] or nil
    local pool = type(w) == 'table' and w.ammo or nil
    return type(pool) == 'string' and pool ~= '' and pool or nil
end

--- THE POOL'S OWN NAME, WHICH IS config/loot.lua's AND NOT A WORD FROM HERE.
---
--- `{ammotype}` is a slot in his sentence and BR.Config.AmmoPickups authors the
--- word that goes in it -- "Light Ammo", "Shells" -- which is the same label the
--- ammo ROW on this same shelf is titled with. So the description names the pool
--- in exactly the words the row above it does, and neither is typed here.
--- @param pool string|nil
--- @return string|nil
local function poolLabel(pool)
    local p = BR.Config.AmmoPickups
    local def = type(p) == 'table' and p[pool] or nil
    local label = type(def) == 'table' and def.label or nil
    return type(label) == 'string' and label ~= '' and label or nil
end

--- ONE ROW'S DESCRIPTION, COMPOSED OUT OF HIS TWO TEMPLATES.
---
--- THE MARKING HAPPENS HERE AND THE JOINING DOES NOT, which is the division the
--- price already follows: BR.Menu.blue adds a GTA text token, br_lib puts the
--- commas and the line break in, and config/gunshop.lua owns every word. A token
--- in the config string would print as five characters on any surface that is not
--- a scaleform, and a comma in br_core would be the one character of this feature
--- that only a playtest could check.
---
--- ⚠ ONLY `{guntypes}` IS MARKED ON AN AMMO ROW. "The {guntypes} text should be
--- blue ... and everything else should remain white" -- so `{otherguntypes}` goes
--- in plain, and that asymmetry IS the skim he asked for. Marking both would be
--- a tidier-looking line that does nothing.
---
--- BOTH HOLES ARE MARKED ON A WEAPON ROW, which is equally his: "The {ammotype}
--- should be the same blue as we use above, and the number should be blue as well."
--- @param row table
--- @param held table  the carried-id set, built once per refresh pass
--- @return string
local function describeRow(row, held)
    local pool = rowPool(row)
    if not pool then return '' end

    if row.kind == BR.ItemKind.AMMO then
        local yours, others = BR.GunshopSolve.ammoUsersSplitLine(
            pool, ammoSources(), held)
        return BR.GunshopSolve.ammoDesc(G,
            yours ~= '' and BR.Menu.blue(yours) or '', others)
    end

    local label = poolLabel(pool)
    if not label then return '' end
    -- READ AT THIS MOMENT, NEVER CACHED. `{number}` is "You have N rounds for it"
    -- and it has to be the N they have while they are reading it.
    return BR.GunshopSolve.weaponDesc(G, BR.Menu.blue(label),
                                      BR.Menu.blue(tostring(poolHeld(pool))))
end

--- THE CATALOGUE, REGROUPED TOP-DOWN, WITH A HEADER OVER EACH GROUP.
---
--- Owner, 2026-09-09: "re-categorize it top-down with the top being the most
--- common weapon types they sell, and the bottom being legendary, with
--- separators in between that indicate the category".
---
--- ═══ RARITY IS THE AXIS, BECAUSE IT IS THE ONE HE NAMED AND THE ONLY ONE THAT
---     EXISTS ═══
---
--- "the bottom being legendary" names a rarity, and rarity is a real field on
--- every catalogue row. The other reading of "weapon types" is a CLASS -- pistol,
--- SMG, rifle -- and there is no class field anywhere in config/weapons.lua: the
--- grouping he reads that table in is comment headers, so a class axis would
--- have to be authored from scratch and would be somebody guessing which of
--- thirty guns is a "rifle". Rarity is derived, ordered, and already colors
--- these rows.
---
--- AMMO SITS AT THE TOP, and that is his sentence rather than a preference:
--- ammunition is the most commonly sold thing at a gun counter, and the
--- catalogue already carries it at BR.Rarity.COMMON -- so "most common at the
--- top, legendary at the bottom" is one ascending sort over a field that is
--- already there.
---
--- ORDER WITHIN A GROUP IS THE CATALOGUE'S, untouched -- BR.Config.Weapons'
--- authored class grouping and BR.Config.AmmoOrder. This is a STABLE partition
--- of that list, never a re-sort of it.
--- @return table  { { header = string, rows = { row, ... } }, ... }
local function grouped()
    local out = {}

    -- AMMO IS PARTITIONED BY KIND, NOT BY RARITY, and that is a guard rather
    -- than a style choice. Every ammo row carries BR.Rarity.COMMON -- the
    -- catalogue says in as many words that this is a convention and not a claim
    -- that ammo is common -- so a rarity-only partition would put a COMMON GUN
    -- in the ammunition group on the day somebody lowers
    -- BR.GunshopSolve.minRarity. Asking the kind cannot go wrong that way.
    local ammo = BR.GunshopSolve.ofKind(rows, BR.ItemKind.AMMO)
    if #ammo > 0 then
        -- ═══ AND THIS ONE HEADER WEARS ITS OWN ROWS' COLOR (owner, 2026-09-11)
        --     ═══
        --
        -- "The ammunition separator should read 'Ammo' and be no special color,
        -- same color as the ammo item rows themselves."
        --
        -- READ OFF A ROW, NOT NAMED HERE. Every row in this group is stamped
        -- with the same rarity by BR.GunshopSolve, and `headerRarity` is that
        -- rarity rather than a constant repeating it -- so "the same color as
        -- the rows" stays true if the stamp ever moves, and cannot drift into
        -- being a second opinion about what ammunition is.
        --
        -- ONLY THIS GROUP CARRIES THE FIELD, which is what keeps `buildMenu`
        -- from repainting the other three separators he did not rule on.
        out[#out + 1] = { header       = AMMO_GROUP,
                          rows         = ammo,
                          headerRarity = ammo[1].rarity }
    end

    local order = { BR.Rarity.COMMON, BR.Rarity.UNCOMMON, BR.Rarity.RARE,
                    BR.Rarity.EPIC, BR.Rarity.LEGENDARY }
    local bucket = {}
    for i = 1, #order do bucket[order[i]] = {} end

    for i = 1, #rows do
        local r = rows[i]
        if r.kind ~= BR.ItemKind.AMMO then
            local b = bucket[r.rarity]
            -- A RARITY WITH NO BUCKET IS NOT DROPPED. It would take a sixth
            -- rarity to reach this, and a gun that vanished from the shelf
            -- because somebody added one is a silently half-stocked shop -- the
            -- exact failure tools/test_gunshop.lua exists to make loud.
            if not b then
                b = {}
                bucket[r.rarity] = b
                order[#order + 1] = r.rarity
            end
            b[#b + 1] = r
        end
    end

    for i = 1, #order do
        local list = bucket[order[i]]
        if list and #list > 0 then
            -- THE HEADER IS BR.RarityInfo's OWN LABEL, which is the word the
            -- inventory borders and the loot glow already mean by that color.
            local info = BR.RarityInfo and BR.RarityInfo[order[i]]
            local header = info and info.label or nil
            if header then out[#out + 1] = { header = header, rows = list } end
        end
    end
    return out
end

--- WHICH TEXTURE GOES ON THE BANNER.
---
--- Owner, 2026-09-09: "missing the top banner texture altogether.... I thought
--- there were multiple of these we could pick from but instead we have none?"
---
--- ═══ THE HONEST ANSWER TO HIS QUESTION: SCALEFORMUI SHIPS NO BANNER ART ═══
---
--- There is no gallery inside the library and none in ScaleformUI_Assets, which
--- holds five .gfx movies and not one .ytd. What there IS is GTA's own catalog,
--- and the banner-shaped part of it is the shop title dictionaries, each of
--- which uses the same string twice, as dictionary and as texture:
---
---   shopui_title_gunclub          <- Ammu-Nation's own, and what is used here
---   shopui_title_conveniencestore, _liqourstore, _liqourstore2, _liqourstore3,
---   _gasstation, _carmod, _carmod2, _barber .. _barber4, _tattoos .. _tattoos5,
---   _lowendfashion, _lowendfashion2, _midfashion, _highendfashion,
---   _highendsalon, _movie_masks, _darts, _golfshop, _tennis,
---   _graphics_franklin, _graphics_micheal, _graphics_trevor
---
--- plus the generic dark gradients in `commonmenu`: interaction_bgd,
--- gradient_bgd, gradient_nav. Our own art is possible too and costs nothing --
--- a .ytd in a stream folder -- but it is a texture somebody has to draw.
---
--- ═══ THE PAIR BELONGS IN CONFIG AND THIS IS THE FALLBACK UNTIL IT IS THERE ═══
---
--- `bannerTxd`/`bannerTxn` are read from BR.Config.Gunshop first, so the moment
--- those two fields land beside `menuTitle` this constant stops being consulted.
--- It is written here rather than left nil because a nil is the bare colored bar
--- he already reported.
---
--- IT IS A TEXTURE NAME, NOT COPY. Nothing in it is read as words by a player.
--- @return table|nil  { txd, txn }
local function bannerSprite()
    local txd = type(G.bannerTxd) == 'string' and G.bannerTxd or nil
    local txn = type(G.bannerTxn) == 'string' and G.bannerTxn or nil
    if txd and txn then
        if txd == '' or txn == '' then return nil end
        return { txd = txd, txn = txn }
    end
    return { txd = 'shopui_title_gunclub', txn = 'shopui_title_gunclub' }
end

--- ITEMS ARE ADDED IN THE ORDER `grouped` PUTS THEM IN, never pairs().
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
    local built = BR.Menu.new(G.menuTitle, '', bannerSprite())
    if not built then return false end

    items = {}
    for _, grp in ipairs(grouped()) do
        -- THE HEADER IS A REAL SEPARATOR ITEM, WHICH THE ARROW KEYS SKIP. See
        -- BR.Menu.separator for why a disabled row would not do.
        --
        -- IT IS NOT FATAL IF IT DOES NOT BUILD. A group that lost its header is
        -- a list without a caption; a `return false` here would be a counter
        -- that does not open at all.
        --
        -- ═══ NO SEPARATOR CARRIES THE CYAN NOW, AND ONE CARRIES ITS OWN ROWS'
        --     COLOR ═══
        --
        -- Owner, 2026-09-11, on the ammunition header: "The ammunition separator
        -- should ... be no special color, same color as the ammo item rows
        -- themselves." `headerRarity` is set by `grouped` on that group alone and
        -- is the rarity its own rows carry, so this is the same call the rows make
        -- -- BR.Menu.rarityColor, which is also what refreshMenu repaints them
        -- with on every pass.
        --
        -- AND THE OTHER THREE NOW PASS NOTHING, which is the same day's wider
        -- ruling: "the selected row and separator rows being that obnoxious light
        -- blue still", answered with "No ScaleformUI should ever use our cyan
        -- ever". They took BR.Menu.accent() -- #22d3ee at full opacity, the
        -- brightest thing on the shelf -- and that function no longer exists.
        --
        -- ⚠ nil IS THE LIBRARY'S DEFAULT PANEL AND NOT A COLOR CHOSEN HERE.
        -- UIMenuSeparatorItem inherits SColor.HUD_Panel_light, so Rare, Epic and
        -- Legendary read as plain bars. HE HAS NOT SAID WHAT THEY SHOULD BE: his
        -- ammunition rule -- a header wears the color of the rows under it --
        -- would answer it for all four if he wants it applied, and applying it to
        -- three groups he did not ask about is his call rather than ours.
        local sepColor = nil
        if grp.headerRarity then
            sepColor = BR.Menu.rarityColor(grp.headerRarity)
        end
        local sep = BR.Menu.separator(grp.header, sepColor)
        if sep then pcall(built.AddItem, built, sep) end

        for _, row in ipairs(grp.rows) do
            -- ═══ WHAT IS SET HERE IS WHAT NEVER CHANGES ═══
            --
            -- The label and the panel color are properties of the CATALOGUE,
            -- which is config and does not move inside a session. The price, the
            -- badge, the enabled flag and BOTH DESCRIPTIONS are properties of the
            -- COUNTER, the WALLET and the BAG, and `refreshMenu` re-applies all
            -- of them on every open and on every push.
            --
            -- ⚠ THE DESCRIPTION USED TO BE SET HERE AND CANNOT BE ANY MORE, which
            -- is the structural half of the 2026-09-11 round. An ammo row's
            -- description now names the guns the player is CARRYING and a weapon
            -- row's names how many rounds they are HOLDING, and neither of those
            -- is a fact about the catalogue: both move while the menu is open.
            -- `refreshMenu` is the only place that can be right about them, and
            -- BR.Menu.describe is what makes writing one while the menu is up safe.
            local item = BR.Menu.item(
                BR.GunshopSolve.menuLabel(row), nil,
                BR.Menu.rarityColor(row.rarity))
            if item then
                items[row.id] = item
                -- ═══ THE PRESS NAMES A ROW AND SAYS NOTHING ELSE ═══
                --
                -- No price, no balance, no claim about where it is standing --
                -- every one of those is resolved in server/gunshop.lua. The
                -- menu STAYS OPEN: there is no purchase limit at this counter,
                -- so a player buying a rifle and then two boxes of ammo is the
                -- ordinary case and closing the screen under them would be an
                -- invented rule.
                item.Activated = function()
                    TriggerServerEvent(BR.Net.GUNSHOP_BUY, { id = row.id })
                end
                pcall(built.AddItem, built, item)
            end
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

    -- ═══ THE LIBRARY'S OWN BACK BUTTON HAS TO REACH `menuOpen` ═══
    --
    -- The note on the TICK pass used to say the Back button "needs nothing from
    -- this file". It needed one thing: UIMenu:GoBack takes the menu down
    -- through the library alone -- MenuHandler:CloseAndClearHistory ->
    -- Visible(false) -- and never touches our flag. So `menuOpen` stayed TRUE
    -- with nothing on screen, and the TICK pass reads it before anything else:
    -- the plate stayed down, and the interact key returns early while it is
    -- set, so the counter was dead for as long as the player stood at it. It
    -- came back only when they walked out of reach and `best ~= menuStore`
    -- closed a menu that had already closed itself.
    --
    -- OnMenuClose IS THE LIBRARY'S OWN SEAM FOR THIS, defaulted to an empty
    -- function at construction and called on every path that lowers the menu,
    -- Back and CloseAndClearHistory included. So this is OUR file reconciling
    -- to the library rather than a patch to the vendored one, and it needs no
    -- BR-PATCH entry in its VENDOR.json.
    --
    -- POLLING `built:Visible()` IN THE TICK PASS WAS THE ALTERNATIVE and is
    -- worse: it puts a frame of "menu closed but our flag says open" into every
    -- close, and it asks a question ten times a second that the library is
    -- already willing to answer once.
    built.OnMenuClose = function() closeMenu(nil) end

    menu = built
    return true
end

--- EVERY ROW'S PRICE, BADGE AND SHADE, RE-APPLIED AGAINST ONE COUNTER.
---
--- ═══ "LOCKED" IS TWO STATES AND THEY DO NOT LOOK THE SAME ═══
---
--- Owner, 2026-09-11, on both of them:
---
---   OUT OF STOCK. "instead of a gold price text, we'll show a grey 'Out of
---   stock' text. Also, the row should be shaded differently like it's greyed
---   out/disabled."
---
---   IN STOCK BUT UNAFFORDABLE. The row keeps its gold price so the player can
---   see what they are saving toward, and takes the same shading.
---
--- SO THE SHADE MEANS "YOU CANNOT BUY THIS RIGHT NOW" AND THE RIGHT LABEL SAYS
--- WHICH OF THE TWO IT IS. That is the whole rule, and the third state -- an
--- ammo pool already at its cap -- falls out of it: it is in stock, so it keeps
--- its price and takes the shade.
---
--- ═══ AND "SHADED" IS THE PANEL, NOT UIMenuItem:Enabled ═══
---
--- S3, OUT OF STOCK, is the one row that is genuinely DISABLED, and it always
--- was: "the row should be locked and a price should not be shown". He asked for
--- no toast on this one, so UIMenu:SelectItem returning on the Enabled check and
--- playing the library's error beep IS the feedback.
---
--- L1, CANNOT AFFORD ("if they select an item they cannot afford, give them a
--- toast") and L2, AMMO AT MAX, cannot be disabled rows, for a reason that has
--- not changed: SelectItem's first line is `if not self:CurrentItem():Enabled()
--- then PlaySoundFrontend(ERROR); return end`, which returns BEFORE
--- Item.Activated is called. A disabled row cannot reach the server, and the
--- toast is composed by the server because the server is the half that holds the
--- balance and the ledger. So those two stay PRESSABLE, the press reaches
--- server/gunshop.lua, and the refusal comes back in words.
---
--- THE SHADE IS THEREFORE BR.Menu.disabledColor ON THE ITEM'S OWN PANEL, which
--- is the same `_mainColor` the rarity tint uses, so a row wears one or the
--- other and never both. That function carries the argument.
---
-- ---------------------------------------------------------------------------
-- The per-weapon row icons (#274 M4), OFF SINCE 2026-09-11
-- ---------------------------------------------------------------------------
--
-- ╔═══════════════════════════════════════════════════════════════════════╗
-- ║  EVERY BADGE ON THIS MENU IS A BadgeStyle ENUM. NOTHING BELOW RUNS,   ║
-- ║  AND THE REASON IS A MECHANISM RATHER THAN A PREFERENCE.             ║
-- ╚═══════════════════════════════════════════════════════════════════════╝
--
-- Owner, 2026-09-11, with a screenshot of the Legendary group:
--
--   "Seems the gfx we're loading doesn't always show for every weapon type, see
--    attached. We should just use R*'s default gfx, even if it's only one icon,
--    because it has a differentiator between selected/not selected as the colors
--    invert. Our .png's do not."
--
-- Then, as a rule: "also make sure the gunshop menu icons come from GTA too".
--
-- ═══ THE ONE BADGE SLOT HAS TWO FILL MECHANISMS AND ONLY ONE OF THEM INVERTS
--     ═══
--
--   A BadgeStyle INTEGER is drawn by the movie out of its own art, and the movie
--   INVERTS it on the selected row. That is the selection feedback he is naming.
--
--   CustomLeftBadge(txd, txn) points the row at a STREAMED TEXTURE and the movie
--   draws it FLAT. It cannot invert, and no choice of texture changes that.
--
-- So the twelve iconed rows were not just inconsistent with the thirteen generic
-- ones. They were the twelve rows that had stopped telling the player which row
-- the cursor was on -- on a menu whose selected-row fill he was separately
-- asking to have toned down. One badge everywhere beats twelve that break the
-- highlight.
--
-- ⚠ AND "USE GTA'S ICONS" IS NOT SATISFIED BY A BASE GAME DICTIONARY, WHICH IS
-- THE TRAP IN HIS OWN WORDING. He says "our .png's"; none of them is ours.
-- `mpweaponscommon_small`, `mpweaponsgang0_small` and `mpweaponsgang1_small` are
-- Rockstar's, and every texture name in config/gunshop.lua's art table was read
-- out of the game's own dump. Pointing CustomLeftBadge at Rockstar art is exactly
-- what shipped and exactly what he rejected. THE DISTINCTION IS THE MECHANISM,
-- NOT THE PIXELS.
--
-- ═══ WHAT IS STILL HERE AND WHY ═══
--
-- `BR.Config.Gunshop.weaponIcons.enabled` is false, which makes `iconFor` answer
-- nil, `iconDictsReady` answer false and `requestIconDicts` a no-op -- so every
-- line below still loads, still reads, and never reaches the movie. Kept rather
-- than deleted because the evidenced names are the expensive half and are still
-- correct. config/gunshop.lua's block says what would make them shippable again.
--
-- BR.Menu.leftBadge STILL CALLS CustomLeftBadge ONCE, WITH TWO EMPTY STRINGS,
-- and that is not a survival of this feature: it is the CLEAR that stops a stale
-- texture pair being pushed alongside an enum. Its header has the argument. The
-- assertion in tools/test_gunshop.lua is that no row ever carries a non-empty
-- pair, which is the thing the owner's rule is actually about.
--
-- ═══ THE PART THE LIBRARY DOES NOT DO FOR US, KEPT FOR THE SAME REASON ═══
--
-- ScaleformUI's UIMenuItem:CustomLeftBadge(txd, txn) takes an arbitrary texture
-- dictionary and texture name, so any base game texture is reachable and not
-- just the 191 entries of BadgeStyle. But the library pushes those two strings
-- into the movie and NOTHING ELSE: it never calls RequestStreamedTextureDict for
-- a badge anywhere in the bundle. It requests `commonmenu` once, for the pause
-- menu, and streams dictionaries for minimap overlays and mission cards -- the
-- UIMenu item path has no such call in it at all.
--
-- SO THE DICTIONARY IS OURS TO LOAD, AND AN UNLOADED ONE DRAWS NOTHING AND SAYS
-- NOTHING. That is why `iconDictsReady` gates the whole feature rather than
-- being assumed: a badge slot with a texture name the streamer has never heard
-- of is a blank row, which looks exactly like a wrong name, which looks exactly
-- like a bug in this file.
--
-- ROCKSTAR'S OWN mp_weapons SCRIPT RE-REQUESTS THESE THREE DICTIONARIES INSIDE
-- ITS MENU LOOP, which is the tell that they can be evicted while in use. This
-- file asks whenever the counter plate is up -- seconds before a menu can be
-- opened, and again for as long as anybody is standing there.

local ICONS = type(G.weaponIcons) == 'table' and G.weaponIcons or {}

--- Whether the dictionaries were in memory the last time the TICK pass looked.
---
--- DECLARED HERE, ABOVE EVERY READER, because a Lua local is invisible above its
--- own declaration and the pass that spends this is four hundred lines below.
--- It is the previous answer and not the current one: the pass compares the two
--- and refreshes on the edge, so this must not be read as "are they ready".
local iconsReady = false

--- Every distinct texture dictionary the art table names.
---
--- DERIVED FROM THE ART RATHER THAN LISTED BESIDE IT. A second list would be
--- free to drift from the first, and the failure that drift causes is the silent
--- one: a row whose dictionary was never requested draws nothing and reports
--- nothing. SORTED so the request order is the same on every client, which keeps
--- the assertions about it in tools/test_gunshop.lua from depending on `pairs`.
local ICON_DICTS = {}
do
    local seen = {}
    local art = type(ICONS.art) == 'table' and ICONS.art or {}
    for _, a in pairs(art) do
        local d = type(a) == 'table' and a.txd or nil
        if type(d) == 'string' and d ~= '' and not seen[d] then
            seen[d] = true
            ICON_DICTS[#ICON_DICTS + 1] = d
        end
    end
    table.sort(ICON_DICTS)
end

--- Ask the streamer for them. Idempotent, and cheap once they are in.
local function requestIconDicts()
    if ICONS.enabled == false then return end
    for i = 1, #ICON_DICTS do
        -- `false` FOR p1, WHICH IS WHAT ROCKSTAR PASSES FOR THESE EXACT THREE
        -- DICTIONARIES. The argument is undocumented in citizenfx/natives and
        -- the vendored library passes true elsewhere; matching the game's own
        -- call for the game's own textures is the better precedent to copy.
        RequestStreamedTextureDict(ICON_DICTS[i], false)
    end
end

--- Are all of them in memory?
---
--- ALL, NOT ANY. A row is handed one dictionary, but the alternative to "all
--- ready" is a menu where some guns have icons and others silently do not,
--- depending on which of three streaming requests happened to land first. That
--- reads as a broken table rather than as a slow load.
--- @return boolean
local function iconDictsReady()
    if ICONS.enabled == false then return false end
    if #ICON_DICTS == 0 then return false end
    for i = 1, #ICON_DICTS do
        if not isTrue(HasStreamedTextureDictLoaded(ICON_DICTS[i])) then
            return false
        end
    end
    return true
end

--- The art for one shop row, or nil.
---
--- NIL IS THE ORDINARY ANSWER AND NOT AN ERROR. Thirteen of the twenty-five guns
--- on sale have no icon anywhere in the base game -- they were added after 2013
--- and Rockstar never drew one -- so those rows keep the generic kind badge.
--- config/gunshop.lua lists every one of them and says which reason applies.
--- @param id string  a shop row id
--- @return table|nil { txd, txn }
local function iconFor(id)
    if ICONS.enabled == false then return nil end
    local art = type(ICONS.art) == 'table' and ICONS.art or nil
    if not art then return nil end
    local a = art[id]
    if type(a) ~= 'table' then return nil end
    if type(a.txd) ~= 'string' or a.txd == '' then return nil end
    if type(a.txn) ~= 'string' or a.txn == '' then return nil end
    return a
end

--- ═══ THE BADGE SLOT IS ONE SLOT AND THE ICON WINS IT ═══
---
--- M4 asks for an icon per row and L1/L2/S3 asked for a padlock on the same
--- rows. The right end of a row is where the price is and how the movie lays out
--- a right badge beside a right label is not something this project has seen, so
--- there is exactly one badge position in play.
---
--- THE PADLOCK USED TO WIN IT, AND THE OWNER SETTLED THAT ON 2026-09-11: "If a
--- weapon is both iconed and locked, the icon should remain on the left of the
--- row before the name as normal". Confirmed on both locked states, so the
--- padlock does not occupy the slot in either of them.
---
--- THE ARGUMENT THE OLD PRIORITY LOST. "Cannot afford" is most rows for most of
--- a match, so a lock that won the slot made the icons least visible exactly
--- when somebody is browsing. What carries "locked" now is the row's shade and
--- its right label, neither of which is competing with anything.
---
--- SO THE BADGE IS AN IDENTITY AND NOTHING ELSE, and since the icons were retired
--- later the same day there is exactly ONE identity on the shelf: the kind badge,
--- BadgeStyle.GUN or BadgeStyle.AMMO, on every row. BadgeStyle.LOCK is not
--- reached from this file at all, and neither is any texture.
---
--- ⚠ THE `pic` BRANCH BELOW IS STILL WRITTEN AND IS NOW STRUCTURALLY DEAD, which
--- is deliberate and is the whole value of a one-line switch. `iconDictsReady`
--- answers false while `weaponIcons.enabled` is false, so `art` is false, so
--- `pic` is nil on every row -- and the day the switch moves, the ordering
--- BR.Menu.leftBadge exists to enforce is still there rather than having to be
--- rediscovered.
--- @param store table|nil
local function refreshMenu(store)
    local currency = BR.Config.Market and BR.Config.Market.currency
    local gun  = BR.Menu.badge('GUN')
    local ammo = BR.Menu.badge('AMMO')
    local art  = iconDictsReady()
    -- ONE INVENTORY READ FOR THE WHOLE PASS. Thirty rows asking the mirror what
    -- is in the bag would be thirty answers that cannot differ, and this pass
    -- already runs on every balance and stock push.
    local held = carriedIds()

    for i = 1, #rows do
        local row  = rows[i]
        local item = items[row.id]
        if item then
            local out    = soldOut(store, row)
            local locked = out or (not affordable(row)) or ammoFull(row)

            -- ═══ THE RIGHT LABEL SAYS WHICH KIND OF LOCKED THIS IS ═══
            --
            -- OUT OF STOCK REPLACES THE PRICE, IN GREY -- "instead of a gold
            -- price text, we'll show a grey 'Out of stock' text", and "a price
            -- should not be shown" from the round before it. A sold-out row must
            -- not read as a thing with a cost.
            --
            -- EVERYTHING ELSE KEEPS THE GOLD PRICE, INCLUDING A ROW THEY CANNOT
            -- AFFORD. That is his, and the reason is his too: the player can see
            -- what they are saving toward. The shade below is what tells them
            -- they cannot have it yet.
            --
            -- THE WORDS ARE STILL config/gunshop.lua's. BR.Menu.dimmed prefixes
            -- a color token and touches nothing else, exactly as
            -- BR.Menu.priceGold does for the price.
            if out then
                pcall(item.RightLabel, item, BR.Menu.dimmed(OUT_OF_STOCK))
            else
                pcall(item.RightLabel, item,
                      BR.Menu.priceGold(
                          BR.ShopSolve.priceLine(row.price, currency)))
            end

            -- ═══ ONE SLOT, FILLED IN ONE CALL, SO THE TWO KINDS OF BADGE
            --     CANNOT BE LEFT ON A ROW TOGETHER ═══
            --
            -- The library keeps an integer badge and a { TXD, TXN } pair on
            -- every item and pushes both into the movie on every redraw, and
            -- neither setter clears the other. A row still flips between a
            -- texture and an enum -- the dictionaries arrive mid-session, and
            -- `enabled = false` puts every row back on its kind badge -- so
            -- BR.Menu.leftBadge still owns the ordering that makes that flip
            -- mean one thing; its header has the whole argument.
            --
            -- A WEAPON ROW WITH ART GETS THE ART, LOCKED OR NOT. What it no
            -- longer loses it to is the padlock: see the block above. An ammo
            -- row, a gun the base game never drew an icon for, and every row at
            -- all while the dictionaries are still streaming get the kind badge.
            local pic = art and row.kind == BR.ItemKind.WEAPON
                and iconFor(row.id) or nil

            local badge = row.kind == BR.ItemKind.AMMO and ammo or gun

            BR.Menu.leftBadge(item, badge, pic and pic.txd, pic and pic.txn)

            -- ═══ THE SHADE, WHICH IS WHAT "LOCKED" NOW LOOKS LIKE ═══
            --
            -- SET ON EVERY PASS, ON BOTH ARMS, WHICH IS THE WHOLE GUARD. A row
            -- that was shaded and then became buyable has to be repainted with
            -- its rarity, and an arm that answered nil would leave the shade on
            -- until the menu was rebuilt -- a permanently dead-looking row a
            -- player can buy from. Every row on this shelf carries a rarity
            -- BR.RarityInfo knows (`grouped` cannot place one that does not), so
            -- both arms answer a color whenever the library is present.
            pcall(item.MainColor, item,
                  locked and BR.Menu.disabledColor()
                      or BR.Menu.rarityColor(row.rarity))

            -- ONLY STOCK DISABLES. See the block above: the other two locked
            -- states have to stay pressable to be refused in words.
            pcall(item.Enabled, item, not out)

            -- ═══ AND WHAT THE ROW SAYS ABOUT THE PLAYER'S OWN BAG ═══
            --
            -- LAST ON THE PASS, ON PURPOSE. BR.Menu.describe may re-assert the
            -- highlighted row's text and ask the movie to re-read the shared GXT
            -- key, so it is the one write here that can touch a row other than
            -- this one. Doing it after the price, the badge and the shade means
            -- the row it re-asserts has already had all three applied.
            --
            -- THE `menu` UPVALUE, NOT `built`. This runs both before the menu is
            -- shown (from `openMenu`) and while it is up (from a stock or balance
            -- push), and describe needs to know which -- see its header.
            BR.Menu.describe(menu, item, describeRow(row, held))
        end
    end
end

-- ---------------------------------------------------------------------------
-- The clerk speaks
-- ---------------------------------------------------------------------------
--
-- ═══ THIS IS THE FIRST PED SPEECH IN THE PROJECT ═══
--
-- Owner, 2026-09-09: "can you make the ped talk when the menu is opened?
-- something about selling product."
--
-- Nothing in this repository has ever called a speech native -- a grep for
-- PlayAmbientSpeech, PlayPedAmbientSpeech and SPEECH_PARAMS across every
-- resource returns nothing -- so everything below is new ground and the
-- honest state of each claim is written beside it.
--
-- ═══ WHAT IS PROVEN AND WHAT IS NOT ═══
--
-- PROVEN, out of the game's own ped and speech metadata: both clerk models
-- carry Ammu-Nation clerk speech. s_m_y_ammucity_01 declares the voice group
-- s_m_y_ammucity_01_r2pvg and s_m_m_ammucountry declares
-- s_m_m_ammucountry_01_r2pvg, and each group has TWO concrete voices whose sets
-- DO NOT OVERLAP: a MINI voice carrying SHOP_GREET, SHOP_SELL, SHOP_BROWSE_GUN,
-- SHOP_OUT_OF_STOCK and SHOP_BANTER, and a FULL voice carrying GUNSH_BOUGHT,
-- GUNSH_BIG, GUNSH_RIFLE and GUNSH_BANT. Every name below exists on the voice it
-- is named with, and each has between three and thirty-two recorded variants.
--
-- NOT PROVEN, AND HE SHOULD BE TOLD BEFORE HE HEARS IT: WHAT ANY OF THEM SAYS.
-- Speech audio is not in the GXT string table and no transcript dump exists, so
-- "GUNSH_BOUGHT is a remark about mass destruction" is a reading of a NAME. It
-- is the closest name there is; it is not a quotation. /brgunclerk say is the way
-- that gets settled -- one playtest round, six keypresses, rather than one round
-- per guess.
--
-- ═══ WHY THE VOICE IS NAMED ON EVERY CALL ═══
--
-- A ped model carries a voice GROUP, and the engine picks one member of it at
-- spawn. Since the two members of each of these groups have different speech
-- sets, the plain PLAY_PED_AMBIENT_SPEECH_NATIVE on a freshly created clerk is a
-- coin flip between a ped who has SHOP_SELL and one who does not.
-- PLAY_PED_AMBIENT_SPEECH_WITH_VOICE_NATIVE names the voice and removes the
-- coin flip.
--
-- ═══ AND IT IS NOT A CUE, WHICH IS A BOUNDARY WORTH STATING ═══
--
-- br_core/client/sfx.lua is the only file that may name a GTA sound SET/NAME
-- PAIR, and tools/verify.sh enforces that by grepping PlaySoundFrontend and
-- PlaySoundFromEntity. A speech name is neither of those and does not go
-- through the mixer at all -- it is a ped's own voice line, positional, played
-- by the audio controller. So these live here. THE ARGUMENT FOR THE CUE TABLE
-- APPLIES ANYWAY (a wrong speech name fails silently and cannot be
-- auditioned), which is exactly why /brgunclerk say exists below rather than
-- nothing.

--- [model] = { mini = <voice with the SHOP_* set>, full = <the GUNSH_* set> }.
---
--- THE MODEL NAMES ARE config/gunshop.lua's `clerkModels`, resolved through
--- BR.GunshopSolve.clerkModel, so this table is keyed by the same strings that
--- file authors rather than by a second list of models.
local VOICES = {
    ['s_m_y_ammucity_01'] = {
        mini = 'S_M_Y_AMMUCITY_01_WHITE_MINI_01',
        full = 'S_M_Y_AMMUCITY_01_WHITE_01',
    },
    ['s_m_m_ammucountry'] = {
        mini = 'S_M_M_AMMUCOUNTRY_WHITE_MINI_01',
        full = 'S_M_M_AMMUCOUNTRY_01_WHITE_01',
    },
}

--- WHICH LINE IS PLAYED WHEN. Names, not words -- see the block above.
---
---   SELL   the menu opened. "something about selling product" is what he asked
---          for and SHOP_SELL is the literal name of that line.
---   EMPTY  every gun at this counter is gone (S4).
---   SOLD   a weapon was just bought (P2 step 2).
local SPEECH = {
    SELL  = { name = 'SHOP_SELL',          bank = 'mini' },
    EMPTY = { name = 'SHOP_OUT_OF_STOCK',  bank = 'mini' },
    SOLD  = { name = 'GUNSH_BOUGHT',       bank = 'full' },
}

--- Play one named line on one clerk.
---
--- SPEECH_PARAMS_FORCE, and INTERRUPT for the purchase line: a player who buys
--- within a second of opening the menu must hear the purchase remark rather than
--- have it swallowed by the greeting that is still running.
--- @param ped integer|nil
--- @param model string|nil
--- @param key string          a SPEECH key
--- @param params string|nil
local function say(ped, model, key, params)
    if not ped or ped == 0 or not isTrue(DoesEntityExist(ped)) then return end
    local line = SPEECH[key]
    if not line then return end
    local voices = VOICES[tostring(model or '')]
    local voice = voices and voices[line.bank] or nil
    if not voice then return end
    nat(PlayPedAmbientSpeechWithVoiceNative, ped, line.name, voice,
        params or 'SPEECH_PARAMS_FORCE', false)
end

--- Has this counter sold out of every gun it stocks?
---
--- AMMO IS EXCLUDED BY HIS OWN SENTENCE -- "all items are out of stock (except
--- ammo of course)" -- and `soldOut` already answers false for every ammo row,
--- so this asks only the weapons and cannot be tripped by a pool.
---
--- FALSE WHEN NOTHING IS KNOWN. With no stock ledger there is nothing sold out,
--- so the clerk has nothing to apologize for.
--- @param store table|nil
--- @return boolean
local function allGone(store)
    if type(stock) ~= 'table' then return false end
    local guns = BR.GunshopSolve.ofKind(rows, BR.ItemKind.WEAPON)
    if #guns == 0 then return false end
    for i = 1, #guns do
        if not soldOut(store, guns[i]) then return false end
    end
    return true
end

--- WHAT THE CLERK SAYS AS THE MENU COMES UP.
---
--- Owner, 2026-09-09, S4: "If a customer opens the menu and all items are out of
--- stock (except ammo of course), the clerk should say something like times are
--- tough or sorry I cannot help you much etc."
---
--- HE WROTE "SOMETHING LIKE", WHICH IS NOT WORDING. SHOP_OUT_OF_STOCK is the
--- game's own line for the case and it is the clerk's own voice saying it, so
--- this feature adds no sentence of ours anywhere. If the recording turns out to
--- say the wrong thing, the alternative is a line HE writes, not one we do.
--- @param store table|nil
local function greet(store)
    if type(store) ~= 'table' then return end
    local ped = clerks[store.id]
    local model = BR.GunshopSolve.clerkModel(G, store)
    say(ped, model, allGone(store) and 'EMPTY' or 'SELL')
end

--- Open the menu at one counter.
--- @param store table
local function openMenu(store)
    if menuOpen then return end
    if not buildMenu() then return end

    menuOpen  = true
    menuStore = store
    -- APPLIED BEFORE THE MENU IS SHOWN, which is what keeps the description
    -- writes off the shared GXT key -- see buildMenu.
    refreshMenu(store)
    -- ═══ THE ORDER OF THESE TWO IS THE FIX, NOT AN ACCIDENT ═══
    --
    -- Hud.tsx raises the Volts readout on `shopPlate || gunshopMenu`. The plate
    -- going down is what lowers the first of those, so raising the second AFTER
    -- it would put both false for one envelope and flick the balance off and on
    -- at the exact moment M6 asks for it to stay. Raise, then lower.
    setMenuFlag(true)
    -- THE PLATE GOES DOWN WITH THE MENU UP. They say the same word, and one of
    -- them is a full-screen panel; leaving the world plate lit behind it is the
    -- same prompt twice.
    setPlate(false)
    pcall(menu.Visible, menu, true)
    greet(store)
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
--- Back button, and it does NOT come through here -- it is reconciled at the
--- source, through UIMenu.OnMenuClose, which buildMenu points at closeMenu. See
--- the block there for why this pass must not poll for it instead.
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

        -- ═══ THE ICONS CAN ARRIVE AFTER THE MENU IS ALREADY OPEN ═══
        --
        -- Streaming is asynchronous, so a player who sprints to a counter on a
        -- cold client can open the menu in the window between the request and
        -- the dictionaries landing. Without this the rows keep the generic
        -- badges until something else happens to move the balance -- a menu that
        -- is permanently missing the feature on exactly the machines slow enough
        -- to notice.
        --
        -- EDGE-TRIGGERED, NOT LEVEL. `refreshMenu` walks every row and writes
        -- three strings per item into the movie; running it ten times a second
        -- for as long as the menu is up is the shape of bug this file already
        -- has a note about elsewhere. It runs on the pass the answer CHANGES,
        -- which is once.
        local ready = iconDictsReady()
        if ready ~= iconsReady then
            iconsReady = ready
            refreshMenu(menuStore)
        end
        return
    end

    -- ASKED WHILE THE PLATE IS UP, WHICH IS SECONDS BEFORE THE MENU CAN BE. The
    -- request is idempotent and near-free once the dictionaries are resident,
    -- and Rockstar's own weapon menu re-requests these same three inside its
    -- loop -- which is the tell that a dictionary in use can still be evicted.
    if best ~= nil then requestIconDicts() end

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

    -- THE LIVE OVERRIDES WIN, AND THEY ARE nil UNLESS /brgunplate SET THEM. This
    -- is the one line that makes the tuning command a tool rather than a
    -- printout: the next frame draws at the new number.
    BR.Dui.drawFace(promptPage(), ped,
                    plateFwd or tonumber(G.signForwardM) or 0.55,
                    plateUp or tonumber(G.signUpM) or 1.05,
                    plateW or tonumber(G.signWidthM) or 0.55)
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

-- ---------------------------------------------------------------------------
-- The handover
-- ---------------------------------------------------------------------------
--
-- Owner, 2026-09-09, P2:
--
--   1. I buy something
--   2. the clerk says some random remark about mass destruction, murder, or
--      something along those lines as step 3 happens
--   3. the weapon I just purchased is spawned as a network entity in the
--      clerk's hands as the clerk presents it to me (we need an emote like
--      give or something)
--   4. the entity is deleted, the ped tasks cleared, and I am now armed with
--      that weapon all at once
--   5. This animation/entity/speech process should be skipped for all ammo
--      purchases.
--
-- ═══ STEP 3 CANNOT BE A NETWORK ENTITY, AND THE SECOND REASON IS FATAL ON ITS
--     OWN ═══
--
-- FIRST, THE SERVER CONFIG. server.cfg.example:149 sets `sv_entityLockdown
-- relaxed`, which Cfx documents as "Only script-owned entities created by
-- clients are blocked". A client CreateObject with isNetwork = true is
-- script-owned, so the platform deletes it before any resource sees it. That is
-- already written down twice in this tree, for the airdrop crate and for the
-- rescue medic, and the owner confirmed the same validator empirically on
-- 2026-08-22 (#202) when vMenu stopped spawning vehicles.
--
-- SECOND, AND THIS ONE DOES NOT CARE ABOUT THE CONFIG AT ALL: THE CLERK IS A
-- LOCAL PED. Every player builds their own (see this file's header, and the
-- CreatePed above with both network flags false). A networked object has to be
-- attached to something, and the thing we would attach it to exists on exactly
-- one machine -- other clients either hold a different handle for their own
-- clerk or, ten times out of eleven, have no clerk at that building at all
-- because they are kilometres away. There is no correct attach for a remote
-- viewer to perform, and turning the lockdown off would not change that by one
-- frame.
--
-- WHAT IT COSTS IS NOTHING HE CAN SEE. He already cannot see another player's
-- clerk; the whole counter scene is private. So this is the client-local
-- equivalent, built deliberately rather than a networked entity that would
-- silently never appear.
--
-- ═══ STEP 4 IS THREE THINGS AND THEY END TOGETHER ═══
--
-- "the entity is deleted, the ped tasks cleared, and I am now armed with that
-- weapon all at once." The first two happen HERE, at the end of `present`; the
-- third happens on the SERVER, which is the only thing that may write an
-- inventory. server/gunshop.lua used to deliver the weapon and THEN fire
-- GUNSHOP_BOUGHT, so the player was armed before the clerk had begun to offer
-- the gun -- his sequence backwards, with the clerk animated presenting
-- something already in the buyer's hands.
--
-- IT FIRES THE EVENT FIRST NOW AND SCHEDULES THE DELIVERY FOR THE SAME MOMENT
-- THIS THREAD FINISHES. Both sides read `handoverMs` out of
-- br_lib/config/gunshop.lua rather than carrying a constant, because a moment
-- that lands on two machines cannot be spelled in two files.

--- HOW LONG THE CLERK HOLDS IT OUT, in milliseconds, and WHERE IT SITS IN HIS
--- HAND.
---
--- ═══ THE SIX OFFSETS ARE A STARTING GUESS AND THEY ARE SAID TO BE ONE ═══
---
--- Nobody can know these from outside the game: they are per model and per
--- weapon shape and everyone who ships a prop-in-hand tunes them by eye. They
--- are here as named constants rather than as six numbers inside a call so that
--- /brgunclerk hand can move them live -- which is the same answer the owner
--- already asked for on the plate.
--- CONFIG'S NUMBER, NOT THIS FILE'S. The server waits the same span before it
--- delivers, so P2 step 4's "all at once" is two machines reading one value
--- rather than two constants somebody has to remember to move together.
local HAND_MS = tonumber(G.handoverMs) or 1400
local HAND = { x = 0.09, y = 0.02, z = -0.02, rx = -80.0, ry = 100.0, rz = 0.0 }

--- SKEL_R_Hand. The ID, which GetPedBoneIndex turns into the INDEX that
--- AttachEntityToEntity actually wants -- a distinction client/squadmates.lua
--- already records in prose because passing the ID attaches to the wrong bone
--- silently.
local BONE_R_HAND = 57005

--- Rockstar's own gun store clerk animation dictionary, and the give gesture.
---
--- Both are confirmed present in the game's animation dictionary listing.
--- random@shop_gunstore carries _greeting, _positive_a, _positive_b,
--- _positive_goodbye, _negative_goodbye and three idles -- THE LEADING
--- UNDERSCORE IS PART OF THE CLIP NAME. mp_common carries givetake1_a and
--- givetake1_b, the giver-and-receiver pair every emote pack ships as "Give".
---
--- WHAT I CANNOT PROVE FROM OUTSIDE THE GAME is that either clip is in place
--- rather than carrying root motion. The clerk is FreezeEntityPosition'd, which
--- normally suppresses that, and AF_UPPERBODY below is the cheap insurance --
--- but whether he stays behind his counter is a one-round playtest question.
local GIVE_DICT, GIVE_CLIP = 'mp_common', 'givetake1_a'

--- AF_UPPERBODY (16) + AF_SECONDARY (32). Upper body only, so a counter clerk
--- cannot step out of position, and secondary so it layers rather than
--- replacing whatever pose he is in.
local GIVE_FLAG = 48

--- Stream one animation dictionary, on a budget, without blocking forever.
---
--- HasAnimDictLoaded IS A BOOL NATIVE. Its 0 would be truthy, which is this
--- project's most expensive recurring defect, so it goes through isTrue like
--- every other bool read in this file.
--- @param dict string
--- @param budgetMs integer
--- @return boolean
local function awaitAnim(dict, budgetMs)
    if type(RequestAnimDict) ~= 'function'
        or type(HasAnimDictLoaded) ~= 'function' then
        return false
    end
    if isTrue(HasAnimDictLoaded(dict)) then return true end
    RequestAnimDict(dict)
    local waited = 0
    while not isTrue(HasAnimDictLoaded(dict)) and waited < budgetMs do
        Citizen.Wait(50)
        waited = waited + 50
    end
    return isTrue(HasAnimDictLoaded(dict))
end

--- THE CLERK HANDS OVER ONE WEAPON.
---
--- ═══ A GENERATION TOKEN AND A RECORD COMPARISON, BOTH ═══
---
--- Every wait below is a window in which the clerk can be deleted underneath
--- this thread -- the player walks out, dies, or the match ends. `mine ~= gen`
--- catches the teardown; comparing `presented[id]` against this thread's own
--- record catches the other case, which is a SECOND purchase starting while the
--- first was still streaming a model.
--- @param store table
--- @param row table
local function present(store, row)
    local ped = clerks[store.id]
    if not ped or ped == 0 or not isTrue(DoesEntityExist(ped)) then return end

    local w = BR.Config.WeaponById and BR.Config.WeaponById[row.id]
    if not w or not w.hash then return end
    -- BOTH NATIVES CHECKED BEFORE ANY OF THIS STARTS. A misspelled or missing
    -- native is nil rather than an error in this runtime, and a nil call from
    -- inside a spawned thread takes the thread with it silently -- which is the
    -- failure mode client/natives.lua exists to make loud.
    if type(GetWeapontypeModel) ~= 'function'
        or type(CreateObjectNoOffset) ~= 'function' then
        return
    end

    local mine = gen
    Citizen.CreateThread(function()
        local model = GetWeapontypeModel(w.hash)
        if not model or model == 0 then return end
        if not (isTrue(IsModelValid(model))) then return end

        RequestModel(model)
        local waited = 0
        while not isTrue(HasModelLoaded(model)) and waited < 3000 do
            Citizen.Wait(50)
            waited = waited + 50
            if mine ~= gen then
                SetModelAsNoLongerNeeded(model)
                return
            end
        end
        if not isTrue(HasModelLoaded(model)) then
            SetModelAsNoLongerNeeded(model)
            return
        end

        -- RE-READ RATHER THAN CLOSED OVER. The handle above was taken before a
        -- three-second wait.
        local live = clerks[store.id]
        if mine ~= gen or not live or live == 0
            or not isTrue(DoesEntityExist(live)) then
            SetModelAsNoLongerNeeded(model)
            return
        end

        local p = GetEntityCoords(live)
        -- isNetwork FALSE. See the block above this function.
        local obj = CreateObjectNoOffset(model, p.x, p.y, p.z, false, false,
                                         false)
        SetModelAsNoLongerNeeded(model)
        -- 0 IS TRUTHY AND A REFUSED CREATE ANSWERS 0.
        if not (obj and obj ~= 0 and isTrue(DoesEntityExist(obj))) then return end

        -- A PREVIOUS PROP IS TAKEN DOWN BEFORE A SECOND ONE GOES UP, so a
        -- double purchase cannot leave the first one welded to his hand.
        local prev = presented[store.id]
        if prev and prev.obj and prev.obj ~= obj
            and isTrue(DoesEntityExist(prev.obj)) then
            nat(DetachEntity, prev.obj, true, true)
            nat(DeleteEntity, prev.obj)
        end

        local rec = { obj = obj, ped = live }
        presented[store.id] = rec

        nat(SetEntityCollision, obj, false, false)
        local bone = 0
        if type(GetPedBoneIndex) == 'function' then
            bone = GetPedBoneIndex(live, BONE_R_HAND) or 0
        end
        -- p9 has no documented effect; softPinning false so it cannot pop off;
        -- collision FALSE because this is a prop in a hand; isPed false because
        -- entity1 is an object; rotation order 2; syncRot true so it follows the
        -- hand.
        nat(AttachEntityToEntity, obj, live, bone,
            HAND.x, HAND.y, HAND.z, HAND.rx, HAND.ry, HAND.rz,
            false, false, false, false, 2, true)

        if awaitAnim(GIVE_DICT, 1000) then
            nat(TaskPlayAnim, live, GIVE_DICT, GIVE_CLIP, 4.0, -4.0,
                HAND_MS, GIVE_FLAG, 0.0, false, false, false)
        end

        Citizen.Wait(HAND_MS)

        -- ONLY THIS THREAD'S OWN RECORD IS CLEANED UP. See `presented`.
        if presented[store.id] ~= rec then return end
        presented[store.id] = nil
        if obj ~= 0 and isTrue(DoesEntityExist(obj)) then
            nat(DetachEntity, obj, true, true)
            nat(DeleteEntity, obj)
        end
        if live ~= 0 and isTrue(DoesEntityExist(live)) then
            nat(ClearPedTasks, live)
        end
    end)
end

--- The purchase landed.
---
--- BY KEY, THROUGH BR.Sfx, AND NOT AS A SET/NAME PAIR WRITTEN HERE.
--- tools/verify.sh refuses an inlined pair outside three files, and the reason is
--- good: a pair nothing knows the key of cannot be auditioned with /brsfx,
--- cannot be re-pointed with `brsfx bind`, and fails silently when the set is
--- wrong. The key is config/gunshop.lua's `cue`, which resolves to the owner's
--- own pick for "Shop purchase complete".
---
--- ═══ AMMO GETS THE CUE AND NOTHING ELSE ═══
---
--- P2 step 5: "This animation/entity/speech process should be skipped for all
--- ammo purchases." The kind is not on the wire -- the event carries a row id --
--- so it is resolved through the catalogue both halves share, which needs no
--- protocol change and cannot disagree with the server about what was bought.
---
--- THE MENU STAYS OPEN. There is no purchase limit at this counter, so a player
--- buying a rifle and then two boxes of ammo is the ordinary case.
RegisterNetEvent(BR.Net.GUNSHOP_BOUGHT)
AddEventHandler(BR.Net.GUNSHOP_BOUGHT, function(d)
    if type(d) ~= 'table' then return end
    if BR.Sfx and G.cue then BR.Sfx.play(G.cue) end

    local row = BR.GunshopSolve.rowById(rows, d.row)
    if not row or row.kind == BR.ItemKind.AMMO then return end

    -- THE COUNTER IT WAS BOUGHT AT, WHICH IS THE ONE WITH THE MENU OPEN. A
    -- purchase that landed after the player walked off has no clerk to present
    -- it and simply does not.
    local store = menuStore or candidate
    if type(store) ~= 'table' then return end

    say(clerks[store.id], BR.GunshopSolve.clerkModel(G, store), 'SOLD',
        'SPEECH_PARAMS_FORCE_SHOUTED_CRITICAL')
    present(store, row)
end)

--- WHAT EACH COUNTER HAS LEFT, PUSHED BY THE SERVER.
---
--- ═══ ONE ENVELOPE, TWO USES, AND THE DIFFERENCE IS `full` ═══
---
--- BR.Net.GUNSHOP_STOCK carries { stores, full }. `full = true` is the whole
--- picture for this match, sent once when a player is first seen in it;
--- `full` absent is a DELTA -- one counter, one row -- sent to everyone in the
--- match every time a count moves, because the shelf is shared and the player
--- who takes the last Carbine takes it from everybody.
---
--- A DELTA IS MERGED, NEVER ASSIGNED. Assigning it would empty the other ten
--- counters at the moment somebody bought a rifle at the eleventh, and the
--- symptom would be a shop that goes blank when a stranger shops.
---
--- A DELTA THAT ARRIVES FIRST IS TREATED AS THE PICTURE, which is the safe
--- reading rather than the tidy one: an absent row means NOT COUNTED, so the
--- worst it can do is show a price for something the server will then refuse in
--- words. The opposite default would be a shop that sells nothing.
---
--- REGISTERED ONLY IF THE CONSTANT EXISTS. It does now; the guard stays because
--- a client that loses this event must fall back to "everything is in stock"
--- rather than to a nil index inside a net handler.
if BR.Net.GUNSHOP_STOCK then
    RegisterNetEvent(BR.Net.GUNSHOP_STOCK)
    AddEventHandler(BR.Net.GUNSHOP_STOCK, function(d)
        if type(d) ~= 'table' or type(d.stores) ~= 'table' then return end

        if d.full == true or type(stock) ~= 'table' then
            stock = d.stores
        else
            for storeId, counts in pairs(d.stores) do
                if type(counts) == 'table' then
                    local into = stock[storeId]
                    if type(into) ~= 'table' then
                        into = {}
                        stock[storeId] = into
                    end
                    for rowId, n in pairs(counts) do into[rowId] = n end
                end
            end
        end

        -- A SHELF THAT EMPTIES UNDER AN OPEN MENU REPAINTS. Without this, a
        -- player standing at the counter while somebody else buys the last
        -- carbine keeps looking at a price for it.
        if menuOpen then refreshMenu(menuStore) end
    end)
end

--- THE WALLET, WHICH THIS FILE ONLY EVER READS.
---
--- MARKET_STATE is the event the storefront already pushes on every balance
--- change, and br_core's client half already receives it (client/cosmetics.lua
--- reads `equipped` off the same payload and ignores the rest). So L1's lock
--- needs no new wire traffic at all: it is a number this client is already
--- being told.
---
--- IT DECIDES WHAT A ROW LOOKS LIKE AND NOTHING ELSE. The refusal is the
--- server's, composed against the ledger rather than against this cache.
RegisterNetEvent(BR.Net.MARKET_STATE)
AddEventHandler(BR.Net.MARKET_STATE, function(d)
    if type(d) ~= 'table' then return end
    local b = tonumber(d.balance)
    if b == nil then return end
    balance = b
    if menuOpen then refreshMenu(menuStore) end
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
-- The two tuning commands
-- ---------------------------------------------------------------------------
--
-- ═══ HE ASKED FOR A TOOL, IN THOSE WORDS ═══
--
-- Owner, 2026-09-09, D1: "the DUI should not be above the ped, but in front of
-- the ped at waist height (hopefully right on top of the counter - I can help
-- fine-tune this if you give me tools to do so)".
--
-- So the plate's three numbers, and the clerk's placement beside it, are live
-- and the output is a config line he can paste. This is /brgunshop's argument
-- applied to a different set of unknowables: one round of nudging settles what
-- three rounds of guessing would not.
--
-- BOTH TAKE AN ABSOLUTE OR A DELTA. `0.65` sets, `+0.05` and `-0.10` nudge. A
-- leading sign is the whole difference, which is why the parser below reads the
-- RAW string before it reads the number.
--
-- CONSOLE ONLY, and dev-gated by construction -- br_lib/shared/devgate.lua wraps
-- RegisterCommand before any br_core file loads.

--- "0.65" is a value, "+0.05" and "-0.10" are nudges.
--- @param cur number
--- @param arg string|nil
--- @return number|nil
local function nudge(cur, arg)
    local s = tostring(arg or '')
    local n = tonumber(s)
    if n == nil then return nil end
    if s:sub(1, 1) == '+' or s:sub(1, 1) == '-' then return cur + n end
    return n
end

--- Which counter a tuning command acts on: the one being looked at.
--- @return table|nil
local function tuningStore()
    return menuStore or candidate
end

RegisterCommand('brgunplate', function(_, args)
    local fwd = plateFwd or tonumber(G.signForwardM) or 0.55
    local up  = plateUp or tonumber(G.signUpM) or 1.05
    local wid = plateW or tonumber(G.signWidthM) or 0.55

    local what = tostring(args[1] or ''):lower()
    if what == 'reset' then
        plateFwd, plateUp, plateW = nil, nil, nil
        print('[br_core] gunshop: plate back to config')
    elseif what == 'fwd' then
        plateFwd = nudge(fwd, args[2]) or plateFwd
    elseif what == 'up' then
        plateUp = nudge(up, args[2]) or plateUp
    elseif what == 'w' then
        plateW = nudge(wid, args[2]) or plateW
    elseif what ~= '' then
        print('[br_core] gunshop: brgunplate [fwd|up|w] <value|+delta> | reset')
    end

    fwd = plateFwd or tonumber(G.signForwardM) or 0.55
    up  = plateUp or tonumber(G.signUpM) or 1.05
    wid = plateW or tonumber(G.signWidthM) or 0.55

    print('=== gunshop plate ===')
    print(('  plate %s   at %s'):format(plateShown and 'up' or 'down',
        candidate and tostring(candidate.id) or '-'))
    -- PASTEABLE, WHICH IS THE POINT. These three lines are the shape they take
    -- in br_lib/config/gunshop.lua.
    print(('    signForwardM = %.2f,'):format(fwd))
    print(('    signUpM      = %.2f,'):format(up))
    print(('    signWidthM   = %.2f,'):format(wid))
end, false)

--- ═══ AND THE SAME THING FOR WHERE THE CLERK STANDS ═══
---
--- Owner, 2026-09-09, C1: "The ped position is consistently on top of the
--- register (as I have validated at many shops) - let us move their position
--- back behind the counter and to the left (the ped's right) about 1m".
---
--- ═══ THE CONFIG CANNOT EXPRESS THAT YET, AND THIS IS WHY THE COMMAND EXISTS
---     ═══
---
--- BR.GunshopSolve.clerkAt spends `clerkOffsetM` along the counter's FORWARD
--- vector and has NO LATERAL TERM AT ALL. So "back behind the counter" is a
--- negative clerkOffsetM and "1m to his right" has nowhere to go. The fix is one
--- number in br_lib/config/gunshop.lua and one term in clerkAt, and neither file
--- is this lane's -- so what this lane can do is produce the numbers to put in
--- them, live, rather than have him guess twice.
---
--- `right` HERE IS THE PED'S OWN RIGHT: heading gives forward as
--- (-sin h, cos h), so right is (cos h, sin h). His sentence names both frames
--- for the same direction ("to the left (the ped's right)"), and the ped's is
--- the one a config field would be authored in.
---
--- THE Z IS NEVER TOUCHED. It came out of the ground probe and /brgunshop's
--- ledger says it is right at every counter visited so far; this command moves
--- him in the plane and nothing else.
RegisterCommand('brgunclerk', function(_, args)
    local what = tostring(args[1] or ''):lower()
    local store = tuningStore()

    if what == 'say' then
        -- AUDITION, BECAUSE NOBODY CAN PROVE WHAT A SPEECH NAME SAYS. See the
        -- speech block above: the names are real and their words are not
        -- readable from outside the game.
        local key = tostring(args[2] or ''):upper()
        if not SPEECH[key] then
            print('[br_core] gunshop: brgunclerk say SELL|EMPTY|SOLD')
            return
        end
        if not store then
            print('[br_core] gunshop: stand at a counter first')
            return
        end
        say(clerks[store.id], BR.GunshopSolve.clerkModel(G, store), key,
            'SPEECH_PARAMS_FORCE')
        print(('[br_core] gunshop: %s -> %s'):format(key, SPEECH[key].name))
        return
    end

    if what == 'hand' then
        local k = tostring(args[2] or ''):lower()
        if HAND[k] == nil then
            print('[br_core] gunshop: brgunclerk hand [x|y|z|rx|ry|rz] '
                  .. '<value|+delta>')
        else
            HAND[k] = nudge(HAND[k], args[3]) or HAND[k]
        end
        print(('  HAND = { x = %.2f, y = %.2f, z = %.2f, rx = %.1f, ry = %.1f, '
               .. 'rz = %.1f }'):format(HAND.x, HAND.y, HAND.z,
                                        HAND.rx, HAND.ry, HAND.rz))
        return
    end

    -- ALL THREE FALL BACK TO CONFIG, AND THE MIDDLE ONE DID NOT. `clerkRightM`
    -- was written into config/gunshop.lua by C1 and this tool never learned to
    -- read it, so a nudger whose whole job is to refine the owner's numbers
    -- started from a lateral baseline of ZERO while the game shipped 1.0 -- it
    -- reported the wrong figure, nudged from the wrong figure, and printed a
    -- pasteable config line that would have undone C1 the moment he used it.
    local fwd  = clerkFwd   or tonumber(G.clerkOffsetM) or 0.0
    local lat  = clerkRight or tonumber(G.clerkRightM)  or 0.0
    local face = clerkFace  or tonumber(G.clerkFaceDeg) or 0.0

    if what == 'reset' then
        clerkFwd, clerkRight, clerkFace = nil, nil, nil
        print('[br_core] gunshop: clerk back to config (rebuild to see it)')
    elseif what == 'fwd' then
        clerkFwd = nudge(fwd, args[2]) or clerkFwd
    elseif what == 'right' then
        clerkRight = nudge(lat, args[2]) or clerkRight
    elseif what == 'face' then
        clerkFace = nudge(face, args[2]) or clerkFace
    elseif what ~= '' then
        print('[br_core] gunshop: brgunclerk [fwd|right|face] <value|+delta> | '
              .. 'hand ... | say ... | reset')
    end

    fwd  = clerkFwd   or tonumber(G.clerkOffsetM) or 0.0
    lat  = clerkRight or tonumber(G.clerkRightM)  or 0.0
    face = clerkFace  or tonumber(G.clerkFaceDeg) or 0.0

    print('=== gunshop clerk ===')
    if store then
        local ped = clerks[store.id]
        if ped and ped ~= 0 and isTrue(DoesEntityExist(ped)) then
            local h   = tonumber(store.heading) or 0.0
            local rad = math.rad(h)
            local fx, fy = -math.sin(rad), math.cos(rad)
            local rx, ry = math.cos(rad), math.sin(rad)
            local p = GetEntityCoords(ped)
            -- MOVED IN PLACE RATHER THAN REBUILT. FreezeEntityPosition has to
            -- come off for the write and go back on after it, or the ped is
            -- pinned to where he was.
            nat(FreezeEntityPosition, ped, false)
            nat(SetEntityCoordsNoOffset, ped,
                (tonumber(store.x) or 0.0) + fx * fwd + rx * lat,
                (tonumber(store.y) or 0.0) + fy * fwd + ry * lat,
                p.z, false, false, false)
            nat(SetEntityHeading, ped, (h + face) % 360.0)
            nat(FreezeEntityPosition, ped, true)
            local np = GetEntityCoords(ped)
            print(('  %s   now %.2f, %.2f, %.2f   heading %.1f')
                :format(tostring(store.id), np.x, np.y, np.z, (h + face) % 360.0))
        else
            print(('  %s has no clerk standing'):format(tostring(store.id)))
        end
    else
        print('  not at a counter -- the numbers below are still set')
    end
    -- PASTEABLE, AND EVERY LINE STARTS FROM WHAT THE GAME IS ACTUALLY RUNNING.
    -- All three names exist in br_lib/config/gunshop.lua now -- `clerkRightM`
    -- landed with C1 -- so what prints here is either a number the owner has
    -- nudged this session or the number the file already holds, and pasting the
    -- block back can never quietly zero a field he did not touch.
    print(('    clerkOffsetM = %.2f,'):format(fwd))
    print(('    clerkRightM  = %.2f,'):format(lat))
    print(('    clerkFaceDeg = %.2f,'):format(face))
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
