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

BR = BR or {}
BR.DevMenu = BR.DevMenu or {}

local D = BR.DevMenu

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

    menu = m
    return true
end

--- Is the dev menu on screen? A live read of the library's own answer, never a
--- flag of ours -- BR.Menu.up's reason: every close the library or another
--- menu makes is then seen without being told.
--- @return boolean
function D.up()
    if not menu then return false end
    local ok, vis = pcall(menu.Visible, menu)
    return ok and vis == true
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
        pcall(menu.Visible, menu, false)
        return
    end
    if matchState() ~= followed then followMatch() end
end

--- Open the menu, or put it away. F10 and /brdev both come here.
function D.toggle()
    if D.up() then
        pcall(menu.Visible, menu, false)
        return
    end
    -- Not under one of our panels: the follow pass would only put it away.
    if BR.Keys and BR.Keys.uiScreen ~= nil then return end
    if not build() then return end
    -- EVERY OTHER MENU GOES DOWN FIRST, through its own close, so the gun
    -- shop's flags come down with its menu -- the emote wheel's rule.
    BR.Menu.closeAll(menu)
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
    if D.up() then pcall(menu.Visible, menu, false) end
end)
