-- The dev menu (#422), client half: the rows, and the requests they make.
--
-- Owner, 2026-10-24: "What I need now is a dev-only menu using the same UI as
-- our gun store. It should control things like time, weather, match state,
-- give volts, give Yubikeys, Storm pause, warmup pause, spawn airdrops"
--
-- ═══ THE GUN SHOP'S UI, BUILT THE GUN SHOP'S WAY ═══
--
-- ScaleformUI through BR.Menu (client/menu.lua): GTA's palette, no mouse, no
-- instructional buttons, and Escape the menu's Back rather than our pause
-- menu, all by construction. ONE menu object, built on the first open and
-- kept; a keypress moves the library's own cursor and index, and the server's
-- answer updates rows in place (the player list, the two checkboxes). Nothing
-- is rebuilt per keypress.
--
-- ═══ PRESENTATION AND REQUESTS, NEVER DECISIONS ═══
--
-- Every press is the server's dev command `brdevsv`, run with ExecuteCommand
-- (client/props.lua's route): this client has no command by that name, so
-- FiveM sends the line to the server, which runs it as this player behind dev
-- mode. br_core/server/devmenu.lua checks every word against the same lists
-- these rows are built from and runs the console verb's own body. The answer
-- comes back as BR.Net.DEVMENU_STATE (what the rows show) and DEVMENU_DEV (a
-- line on F8); a refusal is also a toast, sent by the server.
--
-- ═══ F10 AND /brdev, AND NEITHER EXISTS OFF A DEV BOX ═══
--
--   /brdev   registered through devgate.lua's wrap, like every client dev
--            command: with dev mode off it prints which gate closed on F8 and
--            opens nothing.
--   F10      RegisterKeyMapping, so the player can move it in FiveM's own key
--            bindings. A mapping cannot be taken back once it is made, so it is
--            NOT made at load: the SLOW pass below makes it the first time this
--            client reads dev mode on (BR.Dev.on, the replicated br_devMode),
--            once, and stops. On the public box that never happens, and the
--            binding list never shows a dev menu. client/keybinds.lua's
--            BR.Keys.mapGated is the same idea for the emote wheel.
--
--   It is NOT a BR.Keys row. Those are the player's own actions, listed on our
--   Settings screen and read by the raw key layer; a dev tool has no place on
--   that screen.
--
-- ═══ THE WORDS ARE THE OWNER'S ═══
--
-- Every label is BR.Config.DevMenu.labels (br_lib/config/devmenu.lua). The
-- values beside them are data -- hours, the engine's weather names, the match
-- states as the console spells them, players' names, Volts amounts -- and the
-- rows carry no descriptions.
--
-- ═══ THE VEHICLE SPAWNER (#426) ═══
--
-- Owner, 2026-11-01: "can you also add to our dev menu a vehicle spawner
-- menu? remember this needs to be a server-side entity. include spawn by name
-- and have a category selection submenu with a list of all vehicles in each
-- category. For any that you believe to be armed, allow them to be spawned
-- here, but put a note on their row in red that says "Armed""
--
--   Vehicle spawner   the last row, opening a menu of its own:
--     Spawn by name   GTA's on-screen keyboard, titled with the row's label
--     <a class>       one row per vehicle class the game has vehicles in,
--                     named as the game names it, each opening a menu of
--                     every vehicle in that class by its in-game name
--
-- THE LISTS ARE THE GAME'S. GetAllVehicleModels is every vehicle archetype the
-- game registered -- the base game, every DLC, and any vehicle a resource
-- streams -- and GetVehicleClassFromName and GetDisplayNameFromVehicleModel
-- read a model's model info, so nothing is requested or loaded to list one.
-- Read once, the first time the spawner opens; each class's menu is built the
-- first time it opens; all of it is kept. Trains get no row: the server setter
-- cannot build one (config/devmenu.lua's vehicleClassesLeftOut).
--
-- "ARMED" IS config/vehicles.lua's, through BR.Config.IsArmedVehicle, so the
-- menu and the gamemode's own rulings read one list. In GTA's red: a right
-- label is a GTA text command, so its color is a token naming an index into
-- the engine's palette (BR.Menu.red) -- never the project's cyan or gold.
--
-- THE SERVER CANNOT TELL WHAT A MODEL IS, so this side does. A row or a typed
-- name is asked for only when IsModelInCdimage and IsModelAVehicle say this
-- game has it as a vehicle, and the request names the sync tree the
-- IsThisModelA* natives make it (syncTree, below). The spawn is the server's,
-- brcar's own: server/devmenu.lua's `vehicle`.

BR = BR or {}
BR.DevMenu = BR.DevMenu or {}

local D = BR.DevMenu

--- 0 IS TRUTHY IN LUA AND A FIVEM BOOL NATIVE MAY ANSWER 1 OR 0.
local isTrue = BR.NativeBool

--- @return table BR.Config.DevMenu, read at call time
local function cfg() return BR.Config.DevMenu end

--- @param key string @return string  one of the owner's labels
local function label(key)
    local l = cfg().labels or {}
    return tostring(l[key] or '')
end

--- The one menu, built on the first open and kept.
local menu = nil

--- The rows by name, once built.
local rows = {}

--- The players the Player row lists, as the server last sent them:
--- { id, tok, name }. Index i of the row is entry i here. `tok` is the token a
--- give sends back with the id (server/devmenu.lua's header): server ids are
--- recycled, tokens are not.
local players = {}

--- What the list rows send, index for index with what they show.
local hourWords, weatherWords = {}, {}

--- Every menu this file built: the one menu, the Vehicle spawner and the
--- class menus (#426). [menu] = true. D.up and the put-away walk it.
local mine = {}

--- The Vehicle spawner's menu, once built, and the class menus by class
--- number, each once built.
local spawner = nil
local classMenus = {}

--- The vehicles, read once: { classes = { { class, name, vehicles }... } },
--- each class's vehicles { model, hash, class, name, key, armed } sorted by
--- name. nil until the spawner first opens.
local catalog = nil

--- GTA's on-screen keyboard, while Spawn by name has it up and until its keys
--- settle (SPAWN BY NAME, below): { menu, closed, quiet }. Else nil.
local kb = nil
local kbPass = nil

--- Ask the server: one `brdevsv` line, run as this player.
--- @param line string
local function ask(line)
    ExecuteCommand('brdevsv ' .. line)
end

--- A name as a row value. GTA'S TEXT CODES COME OUT: the movie draws a list
--- value as GTA text, and a name is the one string on this menu a player wrote.
--- A `~r~` in it would recolor the row; a `~n~` would break it. Whole codes
--- first, then any `~` left over, so no half of one survives to pair up with
--- the library's own.
--- @param name any
--- @return string
local function shown(name)
    local s = tostring(name or ''):gsub('~[^~]*~', '')
    return (s:gsub('[%c~]', ''))
end

--- This player alone, for the Player row before the server has answered. No
--- token yet, so the two gives send nothing until the answer lands.
--- @return table
local function onlyMe()
    return { { id = GetPlayerServerId(PlayerId()), tok = nil, name = GetPlayerName(PlayerId()) } }
end

--- The Player row's values, out of `players`.
--- @return string[]
local function playerNames()
    local out = {}
    for i, p in ipairs(players) do out[i] = shown(p.name) end
    return out
end

--- The `players` entry the Player row points at, or nil.
--- @return table|nil
local function pickedPlayer()
    local item = rows.player
    if not item then return nil end
    local ok, i = pcall(item.Index, item)
    return ok and players[i] or nil
end

--- The player the Player row points at, as the `<id> <token>` a give sends,
--- or nil.
--- @return string|nil
local function picked()
    local p = pickedPlayer()
    local id = p and math.tointeger(tonumber(p.id)) or nil
    local tok = p and math.tointeger(tonumber(p.tok)) or nil
    if not (id and tok) then return nil end
    return ('%d %d'):format(id, tok)
end

--- The Match state row's index for a state, or 1 (`waiting`) for one it does
--- not list -- the lobby's, or none yet.
--- @param state any
--- @return integer
local function stateIndex(state)
    for i, s in ipairs(cfg().states) do
        if s == state then return i end
    end
    return 1
end

--- The match's state, as this client last heard it (client/state.lua).
--- @return string|nil
local function matchState()
    return BR.State and BR.State.match and BR.State.match.state or nil
end

--- @return string[] values, string[] words
local function hourRows()
    local values, words = {}, {}
    for h = 0, 23 do
        values[#values + 1] = ('%02d:00'):format(h)
        words[#words + 1] = tostring(h)
    end
    values[#values + 1] = label('reset')
    words[#words + 1] = 'reset'
    return values, words
end

--- @return string[] values, string[] words
local function weatherRows()
    local values, words = {}, {}
    for _, name in ipairs(BR.World.WEATHERS) do
        values[#values + 1] = name
        words[#words + 1] = name
    end
    values[#values + 1] = label('reset')
    words[#words + 1] = 'reset'
    return values, words
end

--- @return string[]
local function voltsRows()
    local out = {}
    for i, n in ipairs(cfg().volts) do
        out[i] = BR.ShopSolve.priceLine(n, BR.Config.Market.currency)
    end
    return out
end

--- Add one row, if it built. A row that did not is a row missing, not a menu
--- that will not open -- BR.Menu's own rule.
--- @param m table @param key string @param item table|nil
local function add(m, key, item)
    if not item then return end
    rows[key] = item
    pcall(m.AddItem, m, item)
end

--- Is `v` one of `list`?
--- @param list table @param v any
--- @return boolean
local function oneOf(list, v)
    for _, x in ipairs(list or {}) do
        if x == v then return true end
    end
    return false
end

-- ═══════════════════════════════════════════════════════════════════════════
-- SUBMENUS ARE THE LIBRARY'S, AND SO IS THE TRAIL BACK (#426)
-- ═══════════════════════════════════════════════════════════════════════════
--
-- A row opens its menu through the library's own UIMenu:SwitchTo, and Back
-- in it is the library's own UIMenu:GoBack -- so Escape walks back one menu at
-- a time, as in every Rockstar menu, and nothing here reads a key. The way
-- back is the library's BreadcrumbsHandler: SwitchTo pushes the menu it opens,
-- and GoBack shows the one before it, or closes everything at the first.
--
-- ⚠ THAT TRAIL OUTLIVES A CLOSE, AND A STALE ONE OPENS SOMEBODY ELSE'S MENU.
-- UIMenu:Visible(false) -- the close the toggle, the gun shop and the emote
-- wheel all use (BR.Menu.closeAll) -- leaves the trail where it was, and
-- Visible(true) pushes a menu only onto an EMPTY trail. So:
--
--   * the gun shop closed by walking away leaves [gun shop]; the dev menu
--     opened next would sit on it, and Back from the Vehicle spawner would
--     open the GUN SHOP;
--   * the dev menu put away inside a class menu leaves [dev menu, spawner,
--     class]; Escape at the gun counter or the emote wheel opened next would
--     walk back into the Vehicle spawner.
--
-- Two lines close both. The trail is cleared before the dev menu shows, so it
-- starts there; and every menu of this file clears it when it closes for any
-- reason that is not the library's own switch -- SwitchTo and GoBack set
-- SwitchInProgress around the menu they hide, and every other close leaves it
-- false. A trail one deep was always harmless -- Back at one deep closes
-- whatever is up -- which is why the gun shop's single menu never showed any
-- of this.

--- Is the library half way through showing one menu in place of another?
--- @return boolean
local function switching()
    return type(BreadcrumbsHandler) == 'table'
        and BreadcrumbsHandler.SwitchInProgress == true
end

--- Empty the library's trail. See above.
local function forgetTrail()
    if type(BreadcrumbsHandler) ~= 'table'
        or type(BreadcrumbsHandler.Clear) ~= 'function' then return end
    pcall(BreadcrumbsHandler.Clear, BreadcrumbsHandler)
end

--- Count a menu as this file's, and give it the close that tidies the trail.
--- @param m table
local function adopt(m)
    mine[m] = true
    m.OnMenuClose = function()
        if not switching() then forgetTrail() end
    end
end

--- Show `to` in place of `from`, through the library's own switch.
---
--- ⚠ 1 AND false, AND BOTH ARE LOAD-BEARING. MenuHandler:SwitchTo reads an
--- undefined global (`newer`) whenever the selection it is handed is above 1,
--- so anything else throws -- 1 keeps the menu on the row it was left on. And
--- `inheritOldMenuParams` defaults to true at UIMenu:SwitchTo, where it rebuilds
--- the new menu and copies the old one's settings over it; every menu here
--- came out of BR.Menu.new with the same ones.
---
--- A SWITCH THAT THROWS IS PUT RIGHT. It raises SwitchInProgress first, and
--- the library reads no key from any menu while that is up -- so a throw
--- between the two would leave every ScaleformUI menu in the game deaf.
--- @param from table @param to table
local function switchTo(from, to)
    if type(from) ~= 'table' or type(to) ~= 'table' then return end
    local ok = pcall(from.SwitchTo, from, to, 1, false)
    if not ok and type(BreadcrumbsHandler) == 'table' then
        BreadcrumbsHandler.SwitchInProgress = false
    end
end

--- The menu of this file on screen, or nil. A live read of the library's own
--- answer, never a flag of ours -- see D.up.
--- @return table|nil
local function shownMenu()
    for m in pairs(mine) do
        local ok, vis = pcall(m.Visible, m)
        if ok and vis == true then return m end
    end
    return nil
end

--- Put away whichever of this file's menus is up. Its own close tidies the
--- trail (adopt).
local function putAway()
    local m = shownMenu()
    if m then pcall(m.Visible, m, false) end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- WHAT A MODEL IS, ASKED OF THE GAME (#426)
-- ═══════════════════════════════════════════════════════════════════════════

--- A native that says yes -- asked only if this build has it, never allowed
--- to throw, and normalized (isTrue).
--- @param fn function|nil @param ... any
--- @return boolean
local function says(fn, ...)
    if type(fn) ~= 'function' then return false end
    local ok, v = pcall(fn, ...)
    return ok and isTrue(v)
end

--- A model's vehicle class, 0-22, or nil. Read off the model info, so the
--- model need not be loaded -- vMenu's spawner lists every vehicle the same way.
--- @param hash integer
--- @return integer|nil
local function classOf(hash)
    if type(GetVehicleClassFromName) ~= 'function' then return nil end
    local ok, c = pcall(GetVehicleClassFromName, hash)
    return ok and math.tointeger(tonumber(c)) or nil
end

--- THE SYNC TREE THE SERVER BUILDS A MODEL AS, worked out from the model.
---
--- CreateVehicleServerSetter takes the tree as its second argument and does
--- not check it against the model -- its own documentation: "the same type as
--- the `type` field in vehicles.meta". The trees are the game's network-object
--- classes, and each vehicles.meta type is one of them (the client's
--- GET_VEHICLE_TYPE asks a vehicle for exactly that):
---
---   car, quad, amphibious car or quad, submarine car   automobile
---   motorbike, bicycle                                  bike
---   boat, jetski                                        boat
---   helicopter, blimp                                   heli
---   plane                                               plane
---   submarine                                           submarine
---   trailer                                             trailer
---   train                                               train
---
--- THE NATIVES NAME MOST OF THEM AND NOT ALL. IS_THIS_MODEL_A_CAR is a car and
--- not an amphibious one, and IS_THIS_MODEL_A_QUADBIKE a quad and not an
--- amphibious one, so the two amphibious natives are asked beside them;
--- IS_THIS_MODEL_A_BIKE answers for bicycles too; a jetski is a boat, which
--- IS_THIS_MODEL_A_BOAT answers for -- the jetski native is that answer plus a
--- flag, and its old name, _IS_THIS_MODEL_A_SUBMERSIBLE, is wrong: it does not
--- see a submarine. A blimp, a submarine, a submarine car and a trailer have
--- no native at all. So what none of them claims goes by its class, which in
--- this game build puts each kind in one place:
---
---   14 Boats                   the four submarines         submarine
---   15 Helicopters, 16 Planes  the three blimps            heli
---   11 Utility, 19 Military    every trailer -- 28, and
---                              the Anti-Aircraft Trailer   trailer
---   anything else              the Stromberg and Toreador  automobile
---
--- Every vehicle in the game's own data comes out right this way -- its 921
--- models, types and classes, game build 3717 (DurtyFree's vehicles.json).
--- AN ADD-ON OF AN ODD TYPE IN AN ODD CLASS CAN COME OUT WRONG, and what the
--- game does with a tree that is not the model's is not measured here.
--- @param hash integer
--- @param class integer|nil
--- @return string
local function syncTree(hash, class)
    if says(IsThisModelATrain, hash) then return 'train' end
    if says(IsThisModelAHeli, hash) then return 'heli' end
    if says(IsThisModelAPlane, hash) then return 'plane' end
    if says(IsThisModelABoat, hash) then return 'boat' end
    if says(IsThisModelABicycle, hash) or says(IsThisModelABike, hash) then
        return 'bike'
    end
    if says(IsThisModelACar, hash) or says(IsThisModelAQuadbike, hash)
        or says(IsThisModelAnAmphibiousCar, hash)
        or says(IsThisModelAnAmphibiousQuadbike, hash) then
        return 'automobile'
    end
    if class == 14 then return 'submarine' end
    if class == 15 or class == 16 then return 'heli' end
    if class == 11 or class == 19 then return 'trailer' end
    return 'automobile'
end

--- The client's one refusal (config/devmenu.lua's cannotSpawn), as a warning
--- toast and on F8 -- the server's refusals arrive the same two ways.
--- @param what string  the name, as typed or as the row has it
local function cannot(what)
    local fmt = tostring(cfg().cannotSpawn or '%s')
    local ok, text = pcall(string.format, fmt, shown(what))
    if not ok then text = fmt end
    print('[br_core] brdev: ' .. text)
    if BR.Notify then BR.Notify(text, 'warn') end
end

--- Ask the server for one: `vehicle <model> <tree>`. Only for a vehicle this
--- game has, and only as a tree the server takes -- a train is neither asked
--- for nor listed.
--- @param model string  a model word (config/devmenu.lua's modelWord)
--- @param hash integer
--- @param class integer|nil  the row's class; asked of the game when nil
local function request(model, hash, class)
    if not (says(IsModelInCdimage, hash) and says(IsModelAVehicle, hash)) then
        cannot(model)
        return
    end
    local tree = syncTree(hash, class or classOf(hash))
    if not oneOf(cfg().vehicleTypes, tree) then
        cannot(model)
        return
    end
    ask(('vehicle %s %s'):format(model, tree))
end

--- What the keyboard handed back. Spaces round it are dropped and an empty
--- answer is nothing at all, the same as Escape.
--- @param typed any
local function spawnByName(typed)
    local text = tostring(typed or ''):match('^%s*(.-)%s*$') or ''
    if text == '' then return end
    local model = cfg().modelWord(text)
    if not model then
        cannot(text)
        return
    end
    request(model, GetHashKey(model), nil)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- SPAWN BY NAME: GTA'S KEYBOARD OVER THE OPEN MENU (#426)
-- ═══════════════════════════════════════════════════════════════════════════
--
-- WHILE IT IS UP, THE MENU READS NO KEY. UIMenu:ProcessControl returns before
-- it reads one whenever UpdateOnscreenKeyboard() is 0 -- "still editing" --
-- so typing moves no cursor and presses no row; the menu goes on drawing under
-- the box.
--
-- OUR OWN KEY LAYER IS THE OTHER READER, and the library knows nothing of it.
-- client/keybinds.lua reads the keyboard raw, so typing `titan` would also
-- have been T (chat), I, T, A and N. BR.Keys.setExternalScreen is that layer's
-- door for a screen it cannot see (the terminals' computer is the other): the
-- raw reads stop, Escape is the screen's and not our pause menu's, and the
-- keys are adopted rather than fired when it ends.
--
-- ⚠ AND THE KEY THAT CLOSES THE BOX IS STILL DOWN WHEN IT HAS GONE. The menu
-- reads Select on the PRESS of Enter and Back on the RELEASE of Escape
-- (UIMenu:ProcessControl), and the box swallows only what reaches it while it
-- is up -- so the Enter that confirms can be read as a fresh Select, opening
-- the keyboard again (the library's own example waits 250 ms after one for
-- exactly this), and the Escape that cancels can be read as Back on its way
-- up, closing the Vehicle spawner. So the menu's Select and Back are switched
-- off (its Controls.Select / Controls.Back) from the moment the box opens
-- until both keys have been up for KB_SETTLE_FRAMES frames -- an edge of the
-- keyboard rather than a guess at how long a press lasts.
--
-- ESCAPE ON THE BOX: UpdateOnscreenKeyboard() answers 2, canceled, nothing
-- is asked for, and the spawner is left as it was, on Spawn by name.

--- The text entry the box's title is drawn from: DisplayOnscreenKeyboard takes
--- a text LABEL, not a string, so the row's own label is registered under this
--- key as the box opens.
local KB_TITLE = 'BR_DEVMENU_BYNAME'

--- The keyboard's name to the key layer while it is up (BR.Keys.externalScreen).
local KB_SCREEN = 'devmenu.keyboard'

--- The keys that close the box and also drive the menu: 201 (accept, Enter) is
--- its Select; 177 (cancel) and 199 (pause) are its Back -- Escape is both.
local KB_KEYS = { 201, 177, 199 }

--- How many frames running those keys must read up before the menu has them
--- back. Two, because the library's own loop is a thread of its own and may
--- run before this pass in the frame a key comes up.
local KB_SETTLE_FRAMES = 2

--- Switch a menu's Select and Back off, or back on.
--- @param m table|nil @param off boolean
local function hold(m, off)
    local c = type(m) == 'table' and m.Controls or nil
    if type(c) ~= 'table' then return end
    for _, k in ipairs({ 'Select', 'Back' }) do
        if type(c[k]) == 'table' then c[k].Enabled = not off end
    end
end

--- Is a key that closes the box still down, or coming up this frame?
--- @return boolean
local function keysDown()
    for _, k in ipairs(KB_KEYS) do
        if says(IsDisabledControlPressed, 0, k)
            or says(IsDisabledControlJustReleased, 0, k) then
            return true
        end
    end
    return false
end

--- THE FRAME PASS, WHILE THE BOX IS UP AND UNTIL ITS KEYS SETTLE, and only
--- then: registered by openKeyboard, taken out by itself.
local function keyboardPass()
    local k = kb
    if not k then
        BR.Loop.unregister(kbPass)
        kbPass = nil
        return
    end
    if not k.closed then
        local ok, status = pcall(UpdateOnscreenKeyboard)
        status = ok and math.tointeger(tonumber(status)) or -1
        if status == 0 then return end
        -- 1 is confirmed, 2 canceled, 3 failed, -1 gone without either.
        -- The result is only there on the pass that reads 1.
        k.closed = true
        if BR.Keys and BR.Keys.setExternalScreen then BR.Keys.setExternalScreen(nil) end
        if status == 1 then
            local okR, typed = pcall(GetOnscreenKeyboardResult)
            spawnByName(okR and typed or nil)
        end
    end
    if keysDown() then
        k.quiet = 0
        return
    end
    k.quiet = k.quiet + 1
    if k.quiet < KB_SETTLE_FRAMES then return end
    hold(k.menu, false)
    kb = nil
    BR.Loop.unregister(kbPass)
    kbPass = nil
end

--- Spawn by name: the box, titled with the row's label. One at a time.
--- @param m table  the menu the row was pressed in
local function openKeyboard(m)
    if kb then return end
    pcall(AddTextEntry, KB_TITLE, label('byName'))
    -- 0 IS ONSCREEN_KEYBOARD_ENGLISH, the default: a model name is ASCII.
    local ok = pcall(DisplayOnscreenKeyboard, 0, KB_TITLE, '', '', '', '', '',
                     cfg().modelMaxLen or 64)
    if not ok then return end
    kb = { menu = m, closed = false, quiet = 0 }
    hold(m, true)
    if BR.Keys and BR.Keys.setExternalScreen then BR.Keys.setExternalScreen(KB_SCREEN) end
    if not kbPass then
        kbPass = BR.Loop.register(BR.Loop.FRAME, 'devmenu.keyboard', keyboardPass)
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- THE CLASSES AND THEIR VEHICLES, READ ONCE (#426)
-- ═══════════════════════════════════════════════════════════════════════════

--- A vehicle's in-game name, or its model name when the game has none -- an
--- add-on with no text entry, or the dock and prop trailers the game never
--- named. GTA's text codes come out (`shown`): the row draws it as GTA text.
--- @param hash integer @param model string
--- @return string
local function vehicleName(hash, model)
    local okD, key = pcall(GetDisplayNameFromVehicleModel, hash)
    if okD and type(key) == 'string' and key ~= '' and key ~= 'CARNOTFOUND' then
        local okT, text = pcall(GetLabelText, key)
        if okT and type(text) == 'string' and text ~= 'NULL' then
            local s = shown(text)
            if s ~= '' then return s end
        end
    end
    return model
end

--- A vehicle class as the game names it: GetLabelText('VEH_CLASS_' .. n).
--- The number, when this build has no name for it.
--- @param c integer
--- @return string
local function className(c)
    local ok, text = pcall(GetLabelText, 'VEH_CLASS_' .. c)
    if ok and type(text) == 'string' and text ~= 'NULL' then
        local s = shown(text)
        if s ~= '' then return s end
    end
    return tostring(c)
end

--- Every vehicle the game has, by class. ONCE: the first open of the spawner
--- pays for it -- three reads a model -- and nothing after does.
---
--- A CLASS WITH NO VEHICLES HAS NO ENTRY, so it gets no row; and neither does
--- a class config/devmenu.lua leaves out. A model whose name is not a model
--- word (config/devmenu.lua's modelWord) is left out too: no request could
--- name it.
--- @return table
local function scan()
    if catalog then return catalog end
    local names = {}
    if type(GetAllVehicleModels) == 'function' then
        local ok, list = pcall(GetAllVehicleModels)
        if ok and type(list) == 'table' then names = list end
    end
    local leftOut = {}
    for _, c in ipairs(cfg().vehicleClassesLeftOut or {}) do leftOut[c] = true end
    local armed = BR.Config.IsArmedVehicle
    local byClass = {}
    for _, raw in ipairs(names) do
        local model = cfg().modelWord(raw)
        if model then
            local hash = GetHashKey(model)
            local c = classOf(hash)
            if c and not leftOut[c] then
                local list = byClass[c]
                if not list then
                    list = {}
                    byClass[c] = list
                end
                local name = vehicleName(hash, model)
                list[#list + 1] = {
                    model = model, hash = hash, class = c, name = name,
                    key = name:lower(),
                    armed = armed ~= nil and armed(hash) == true,
                }
            end
        end
    end
    -- BY NAME, then by model so two vehicles the game names alike (four
    -- Avengers) keep one order between sessions.
    local classes = {}
    for c, list in pairs(byClass) do
        table.sort(list, function(a, b)
            if a.key ~= b.key then return a.key < b.key end
            return a.model < b.model
        end)
        classes[#classes + 1] = { class = c, name = className(c), vehicles = list }
    end
    table.sort(classes, function(a, b) return a.class < b.class end)
    catalog = { classes = classes }
    return catalog
end

--- One class's menu: a row per vehicle, by name, the armed ones marked. Built
--- the first time it opens, then kept.
--- @param k table  a scan() class
--- @return table|nil
local function buildClass(k)
    local m = classMenus[k.class]
    if m then return m end
    -- THE BAR IS THE DEV MENU'S AND THE STRIP SAYS WHERE YOU ARE: the class,
    -- in the game's words. No banner art, as on the one menu.
    m = BR.Menu.new(label('title'), k.name, nil)
    if not m then return nil end
    local red = BR.Menu.red(label('armed'))
    for _, v in ipairs(k.vehicles) do
        local item = BR.Menu.item(v.name, v.armed and red or nil)
        if item then
            item.Activated = function() request(v.model, v.hash, v.class) end
            pcall(m.AddItem, m, item)
        end
    end
    -- AN EMPTY MENU IS NOT SHOWN -- build()'s guard, for its reason.
    if #m.Items == 0 then return nil end
    adopt(m)
    classMenus[k.class] = m
    return m
end

--- @param from table  the menu the class row is in
--- @param k table
local function openClass(from, k)
    local m = buildClass(k)
    if m then switchTo(from, m) end
end

--- The Vehicle spawner's menu: Spawn by name, then a row per class. Built --
--- and the vehicles read -- the first time it opens, then kept.
--- @return boolean built
local function buildSpawner()
    if spawner then return true end
    local m = BR.Menu.new(label('title'), label('vehicles'), nil)
    if not m then return false end
    local byName = BR.Menu.item(label('byName'))
    if byName then
        byName.Activated = function(from) openKeyboard(from or m) end
        pcall(m.AddItem, m, byName)
    end
    for _, k in ipairs(scan().classes) do
        local item = BR.Menu.item(k.name)
        if item then
            item.Activated = function(from) openClass(from or m, k) end
            pcall(m.AddItem, m, item)
        end
    end
    if #m.Items == 0 then return false end
    adopt(m)
    spawner = m
    return true
end

--- @param from table  the one menu
local function openSpawner(from)
    if buildSpawner() then switchTo(from, spawner) end
end

--- Build the one menu, once.
--- @return boolean built
local function build()
    if menu then return true end
    if not (BR.Menu and BR.Menu.available and BR.Menu.available()) then
        print('^3[br_core] brdev: ScaleformUI is not in this Lua state -- the dev '
              .. 'menu cannot open. Is ScaleformUI_Lua deployed?^7')
        return false
    end

    -- NO BANNER ART: the library's own bar, with the title on it.
    local m = BR.Menu.new(label('title'), '', nil)
    if not m then return false end
    rows = {}

    local hours
    hours, hourWords = hourRows()
    local restHour = BR.World.restHM()
    add(m, 'time', BR.Menu.list(label('time'), hours, (tonumber(restHour) or 12) + 1))

    local skies
    skies, weatherWords = weatherRows()
    add(m, 'weather', BR.Menu.list(label('weather'), skies, 1))

    -- THE MATCH STATE ROW STANDS ON THE STATE THE MATCH IS IN, and follows it
    -- while the menu is up (the follow pass below). Enter on the state it is
    -- already in changes nothing (BR.Match.transition), so a stray Enter is
    -- harmless -- where a row left on `waiting` would dissolve the match.
    add(m, 'match', BR.Menu.list(label('match'), cfg().states, stateIndex(matchState())))

    if #players == 0 then players = onlyMe() end
    add(m, 'player', BR.Menu.list(label('player'), playerNames(), 1))
    add(m, 'volts', BR.Menu.list(label('volts'), voltsRows(), 1))
    add(m, 'yubikey', BR.Menu.item(label('yubikey')))
    add(m, 'storm', BR.Menu.checkbox(label('storm'), false))
    add(m, 'warmup', BR.Menu.checkbox(label('warmup'), false))
    add(m, 'airdrop', BR.Menu.item(label('airdrop')))
    -- THE VEHICLE SPAWNER (#426), a row that opens a menu of its own. Its
    -- menus are built the first time it opens, not here.
    add(m, 'vehicles', BR.Menu.item(label('vehicles')))

    -- AN EMPTY MENU IS NOT SHOWN: UIMenu:Visible(true) on one asserts. The gun
    -- shop's guard, for its reason.
    if #m.Items == 0 then
        print('^3[br_core] brdev: the menu built with no rows -- not opening it^7')
        return false
    end

    -- ═══ WHAT EACH ROW SENDS ═══
    --
    -- A list row sends on Enter (OnListSelected), never on an arrow: stepping
    -- through the hours is looking, not asking. The checkboxes send the state
    -- the library has just flipped them to; the server's answer puts a box
    -- back if the request did not take.
    if rows.time then
        rows.time.OnListSelected = function(_, _, i) ask('time ' .. tostring(hourWords[i])) end
    end
    if rows.weather then
        rows.weather.OnListSelected = function(_, _, i) ask('weather ' .. tostring(weatherWords[i])) end
    end
    if rows.match then
        rows.match.OnListSelected = function(_, _, i) ask('match ' .. tostring(cfg().states[i])) end
    end
    if rows.volts then
        rows.volts.OnListSelected = function(_, _, i)
            local who, n = picked(), cfg().volts[i]
            if who and n then ask(('volts %s %d'):format(who, n)) end
        end
    end
    if rows.yubikey then
        rows.yubikey.Activated = function()
            local who = picked()
            if who then ask('yubikey ' .. who) end
        end
    end
    if rows.storm then
        rows.storm.OnCheckboxChanged = function(_, _, on) ask('storm ' .. (on and 'on' or 'off')) end
    end
    if rows.warmup then
        rows.warmup.OnCheckboxChanged = function(_, _, on) ask('warmup ' .. (on and 'on' or 'off')) end
    end
    if rows.airdrop then
        rows.airdrop.Activated = function() ask('airdrop') end
    end
    if rows.vehicles then
        rows.vehicles.Activated = function(from) openSpawner(from or m) end
    end

    adopt(m)
    menu = m
    return true
end

--- Is the dev menu on screen -- the one menu, the Vehicle spawner or a class
--- menu? A live read of the library's own answer, never a flag of ours --
--- BR.Menu.up's reason: every close the library or another menu makes is then
--- seen without being told.
--- @return boolean
function D.up()
    return shownMenu() ~= nil
end

--- What the server says the rows are: the players, yourself first, and the two
--- pauses. The Player row keeps pointing at whoever it pointed at -- the same
--- token, not merely the same id -- if they are still listed.
--- @param d table  BR.Net.DEVMENU_STATE's payload
function D.apply(d)
    if type(d) ~= 'table' then return end
    local was = pickedPlayer()
    local wasTok = was and was.tok or nil

    local list = {}
    for _, p in ipairs(type(d.players) == 'table' and d.players or {}) do
        local id = type(p) == 'table' and math.tointeger(tonumber(p.id)) or nil
        local tok = type(p) == 'table' and math.tointeger(tonumber(p.tok)) or nil
        if id and tok then list[#list + 1] = { id = id, tok = tok, name = p.name } end
    end
    players = (#list > 0) and list or onlyMe()

    if rows.player then
        local at = 1
        for i, p in ipairs(players) do
            if wasTok ~= nil and p.tok == wasTok then at = i end
        end
        -- ⚠ ChangeList IS GIVEN THE INDEX AND THEN TOLD IT AGAIN. The library
        -- throws the index away and takes 1 whenever the OLD index is past the
        -- end of the NEW list (UIMenuListItem:ChangeList), so a list that
        -- shrinks would jump the pick to yourself. Index(at) afterwards is the
        -- library's own setter and puts it back.
        pcall(rows.player.ChangeList, rows.player, playerNames(), at)
        pcall(rows.player.Index, rows.player, at)
    end
    if rows.storm then pcall(rows.storm.Checked, rows.storm, d.storm == true) end
    if rows.warmup then pcall(rows.warmup.Checked, rows.warmup, d.warmup == true) end
end

--- The follow pass's handle while the menu is up, else nil.
local followPass = nil

--- The match state the Match state row was last put on.
local followed = nil

--- Put the Match state row on the state the match is in.
local function followMatch()
    local s = matchState()
    followed = s
    if rows.match then pcall(rows.match.Index, rows.match, stateIndex(s)) end
end

--- WHILE THE MENU IS UP, AND ONLY THEN. Registered by D.toggle on the way up
--- and taken out by itself on the first pass that finds the menu down, so a
--- closed menu costs no loop at all.
---
--- ═══ A NUI SCREEN TAKING THE KEYBOARD PUTS THE MENU AWAY ═══
---
--- The gun shop's rule (client/gunshop.lua's prompt pass), for its reason: the
--- menu holds input with DisableAllControlActions and our panels with
--- SetNuiFocus, and with both up the player reads one while the other takes
--- their arrow keys. `uiScreen` is br_ui's answer to "is one of our panels up".
---
--- ═══ THE MATCH STATE ROW FOLLOWS THE MATCH ═══
---
--- When the match moves on -- warmup to the bus, the bus to playing -- the row
--- moves with it, so it never stands on a state the match has left, where one
--- Enter would send the match back.
local function follow()
    if not D.up() then
        BR.Loop.unregister(followPass)
        followPass = nil
        return
    end
    if BR.Keys and BR.Keys.uiScreen ~= nil then
        putAway()
        return
    end
    if matchState() ~= followed then followMatch() end
end

--- Open the menu, or put it away -- whichever of its menus is up. F10 and
--- /brdev both come here.
function D.toggle()
    if D.up() then
        putAway()
        return
    end
    -- Not under one of our panels: the follow pass would only put it away.
    if BR.Keys and BR.Keys.uiScreen ~= nil then return end
    if not build() then return end
    -- EVERY OTHER MENU GOES DOWN FIRST, through its own close, so the gun
    -- shop's flags come down with its menu -- the emote wheel's rule.
    BR.Menu.closeAll(menu)
    -- AND THE LIBRARY'S TRAIL STARTS HERE, so Back from a submenu comes back to
    -- this menu and never to one somebody else left (#426; the note above
    -- `switching`).
    forgetTrail()
    followMatch()
    ask('open')
    pcall(menu.Visible, menu, true)
    if not followPass then
        followPass = BR.Loop.register(BR.Loop.TICK, 'devmenu.follow', follow)
    end
end

RegisterNetEvent(BR.Net.DEVMENU_STATE)
AddEventHandler(BR.Net.DEVMENU_STATE, function(d)
    D.apply(d)
end)

RegisterNetEvent(BR.Net.DEVMENU_DEV)
AddEventHandler(BR.Net.DEVMENU_DEV, function(text)
    print('[br_core] brdev: ' .. tostring(text))
end)

-- Through devgate.lua's wrap: with dev mode off this prints which gate closed,
-- on F8, and opens nothing.
RegisterCommand('brdev', function()
    D.toggle()
end, false)

--- F10, mapped the first time this client reads dev mode on, and never before.
--- See the header. Once mapped, the pass takes itself out of the loop.
local keyPass
keyPass = BR.Loop.register(BR.Loop.SLOW, 'devmenu.key', function()
    if not (BR.Dev and BR.Dev.on and BR.Dev.on()) then return end
    RegisterKeyMapping('brdev', 'Royale: ' .. label('title'), 'keyboard', cfg().key)
    BR.Loop.unregister(keyPass)
end)

AddEventHandler('onClientResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    if D.up() then putAway() end
    -- A BOX LEFT UP WOULD HAVE NOBODY READING IT. FORCE_CLOSE_TEXT_INPUT_BOX,
    -- not CANCEL_ONSCREEN_KEYBOARD, which its own documentation says leaves the
    -- box half torn down.
    if kb and not kb.closed and type(ForceCloseTextInputBox) == 'function' then
        pcall(ForceCloseTextInputBox)
    end
end)
