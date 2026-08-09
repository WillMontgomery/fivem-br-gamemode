-- Key bindings.
--
-- Everything goes through REGISTER_KEY_MAPPING (verified: ns CFX, apiset client)
-- rather than polling control IDs. That single decision buys three things:
--
--   * bindings appear in the GTA pause menu under Settings > Key Bindings,
--     grouped under this resource, so players can rebind them with no UI of ours;
--   * rebinds persist across sessions, handled by the client;
--   * we stop fighting GTA's own control scheme, which is what happens when a
--     resource hardcodes IsControlJustPressed on a key the player has remapped.
--
-- Hold-style actions use the +command / -command convention: FiveM calls
-- "+revive" on press and "-revive" on release automatically.
--
-- Registration must happen at load time, not inside a loop -- the pause menu is
-- populated when the resource starts.

BR = BR or {}
BR.Keys = {
    -- action name -> whether it is currently held (for +/- pairs)
    held = {},
    -- action name -> array of listener functions
    listeners = {},
}

--- Subscribe to a key action.
--- @param action string   e.g. 'inventory', 'revive'
--- @param fn function      receives (pressed: boolean)
function BR.Keys.on(action, fn)
    local l = BR.Keys.listeners[action]
    if not l then
        l = {}
        BR.Keys.listeners[action] = l
    end
    l[#l + 1] = fn
end

--- @param action string
--- @return boolean
function BR.Keys.isHeld(action)
    return BR.Keys.held[action] == true
end

local function fire(action, pressed)
    BR.Keys.held[action] = pressed
    local l = BR.Keys.listeners[action]
    if not l then return end
    for i = 1, #l do
        -- A listener throwing must not stop the others, and must not leave the
        -- held state wrong -- a stuck "held" flag would mean a revive that never
        -- stops or a chat box that never closes.
        local ok, err = pcall(l[i], pressed)
        if not ok then
            print(('[br_core] key listener for "%s" errored: %s'):format(action, tostring(err)))
        end
    end
end

-- THE BINDING TABLE, BUILT BY THE REGISTRARS THEMSELVES.
--
-- It exists so the settings screen can list what is bindable without anybody
-- hand-typing it a second time. The first attempt at a rebinder did hand-type
-- it, in another resource, and got two entries wrong -- the marker command is
-- `brping` not `brmarker`, and INTERACT is a hold action whose real commands
-- are `+brinteract` / `-brinteract`. Binds were being written against
-- commands that do not exist, which is a large part of why none of them
-- appeared to do anything (user, 2026-08-09).
--
-- One list, produced by the code that registers them. It cannot drift.
BR.Keys.bindings = {}

--- Which action a group is filed under on the settings screen.
local group = 'Combat'

--- Register a tap action: fires once on press.
--- @param action string      internal name
--- @param command string     console command / binding id
--- @param description string shown in the pause menu
--- @param key string         default key, e.g. 'TAB'
local function tap(action, command, description, key)
    RegisterCommand(command, function()
        -- The RAW LAYER WINS WHEN IT IS RUNNING. The command stays registered
        -- so GTA's own list still shows it, but firing from both paths would
        -- double-tap every action for a player whose chosen key happens to
        -- match the engine's stored one.
        if BR.Keys.rawActive then return end
        fire(action, true)
        fire(action, false)
    end, false)
    RegisterKeyMapping(command, description, 'keyboard', key)
    BR.Keys.bindings[#BR.Keys.bindings + 1] = {
        action = action, command = command, label = description,
        default = key, hold = false, group = group,
    }
end

--- Register a hold action: fires true on press, false on release.
local function hold(action, command, description, key)
    RegisterCommand('+' .. command, function()
        if BR.Keys.rawActive then return end
        fire(action, true)
    end, false)
    RegisterCommand('-' .. command, function()
        if BR.Keys.rawActive then return end
        fire(action, false)
    end, false)
    RegisterKeyMapping('+' .. command, description, 'keyboard', key)
    BR.Keys.bindings[#BR.Keys.bindings + 1] = {
        action = action, command = command, label = description,
        default = key, hold = true, group = group,
    }
end

-- Descriptions are prefixed so they group together and read sensibly in the
-- pause menu, where they sit alongside every other resource's bindings.

group = 'Movement'
-- Drop. ONE key for the whole descent: aboard the bus it jumps, in freefall
-- it deploys the glider. Two bindings for consecutive actions on the same
-- second of gameplay was one binding too many.
tap ('deploy',      'brdeploy',    'Royale: Jump / deploy glider',       'SPACE')

group = 'Combat'
-- Inventory and interaction
tap ('inventory',   'brinventory', 'Royale: Inventory',                  'TAB')
hold('interact',    'brinteract',  'Royale: Interact / pick up / revive','E')
tap ('drop',        'brdrop',      'Royale: Drop selected item',         'G')
-- R by default because RELOAD is exactly what a player reaches for when they
-- want the thing in their hands to do something, and reloading a shield potion
-- means nothing -- so the two never want the key at the same moment. Rebind it
-- in Settings > Key Bindings like everything else here.
tap ('use',         'bruse',       'Royale: Use selected item',          'R')

group = 'Slots'
-- Slots. Direct slot keys beat scroll-wheel cycling under pressure.
tap ('slot1',       'brslot1',     'Royale: Slot 1',                     '1')
tap ('slot2',       'brslot2',     'Royale: Slot 2',                     '2')
tap ('slot3',       'brslot3',     'Royale: Slot 3',                     '3')
tap ('slot4',       'brslot4',     'Royale: Slot 4',                     '4')
tap ('slot5',       'brslot5',     'Royale: Slot 5',                     '5')

group = 'Comms'
-- Comms
tap ('chatGlobal',  'brchat',      'Royale: Chat (global)',              'T')
tap ('chatSquad',   'brchatsquad', 'Royale: Chat (squad)',               'Y')
tap ('ping',        'brping',      'Royale: Place a marker',             'Z')

group = 'Map'
-- Map and spectating
tap ('map',         'brmap',       'Royale: Map',                        'M')
-- CLEARING A WAYPOINT. GTA's own way to remove one is to open the pause map,
-- find the flag and click it again -- which in a battle royale means opening a
-- full-screen menu mid-fight to undo a misclick (user, 2026-08-06: "there is
-- no way to remove a user-made waypoint"). BACKSPACE by default, rebindable
-- like everything else here.
tap ('clearWaypoint', 'brclearwp', 'Royale: Clear map waypoint',          'BACK')
tap ('specNext',    'brspecnext',  'Royale: Spectate next player',       'RIGHT')
tap ('specPrev',    'brspecprev',  'Royale: Spectate previous player',   'LEFT')

group = 'Interface'
-- OUR SCREENS ARE KEYS TOO, and they live here rather than in br_ui because
-- this is the table the rebinder reads. The pause menu was registered over
-- there with an EMPTY default and was in no table at all, so nothing could
-- open it -- there was no key, and no row in the settings screen to give it
-- one (user, 2026-08-09: "how can I test the pause menu?").
--
-- F1 for the pause menu, because Escape belongs to GTA's own and taking it
-- would leave a player with no way out if our NUI ever breaks. Settings is
-- deliberately unbound: it is reachable from the lobby and from the pause
-- menu, and a mispressed key that throws a full-screen opaque menu over a
-- firefight is worse than no shortcut.
tap ('pause',       'brpausemenu', 'Royale: Pause menu',                 'F1')
tap ('settingsMenu', 'brsettingsmenu', 'Royale: Settings',               '')

-- br_ui owns the pages; this owns the keys. TriggerEvent crosses resources,
-- which is the same hop br_core already uses to reach the interface.
BR.Keys.on('pause', function(pressed)
    if pressed then TriggerEvent('br:ui:pauseToggle') end
end)
BR.Keys.on('settingsMenu', function(pressed)
    if pressed then TriggerEvent('br:ui:settingsToggle') end
end)

--- Names of every registered action, for the debug overlay.
BR.Keys.actions = {
    'deploy', 'inventory', 'interact', 'drop', 'use',
    'slot1', 'slot2', 'slot3', 'slot4', 'slot5',
    'chatGlobal', 'chatSquad', 'ping', 'map', 'specNext', 'specPrev',
    'clearWaypoint',
}

-- ---------------------------------------------------------------------------
-- REBINDING FROM OUR OWN SETTINGS SCREEN
--
-- The first attempt drove FiveM's `bind` console command. It did not work, and
-- rather than guess a fourth time: `bind` is real and documented, but it binds
-- a CONSOLE COMMAND, and half the table above does not have the command name
-- somebody hand-typed into another resource -- interact is `+brinteract`, the
-- marker is `brping`. Even with the names right it was writing bindings whose
-- interaction with the RegisterKeyMapping entry already in the player's
-- fivem.cfg is not something the docs settle.
--
-- So this stops asking the engine to route the key and reads the key itself.
-- IS_RAW_KEY_JUST_PRESSED / _RELEASED take a Windows virtual-key code, are
-- purely local, and answer the one question we actually have: is this exact
-- key down right now. From there we call `fire()` DIRECTLY -- the same
-- function the console commands call -- so a rebound key is indistinguishable
-- from a default one to everything downstream.
--
-- IT IS ALL-OR-NOTHING, ON PURPOSE. `rawActive` gates the RegisterKeyMapping
-- handlers above: when the raw layer is running they do nothing, so an action
-- can never fire twice for one press. And the flag is only set if the native
-- actually answers, so a build without it falls back to exactly the behaviour
-- this project has always had, with nothing lost.
--
-- The GTA pause-menu entries still exist and still list the defaults. They are
-- inert while the raw layer runs; the settings screen is the live one.
-- ---------------------------------------------------------------------------

local KVP = 'br:keys'

--- command -> virtual-key code. Nothing in here means "use the default".
local vk = nil

--- The virtual-key codes for the DEFAULT keys above, so the raw layer can
--- reproduce them for a player who has never rebound anything.
---
--- Hand-mapped because there is no native that converts a RegisterKeyMapping
--- key name to a VK code -- and deliberately kept to exactly the keys this
--- project actually uses as defaults, rather than a general table that would
--- be mostly untested.
local DEFAULT_VK = {
    SPACE = 0x20, TAB = 0x09, E = 0x45, G = 0x47, R = 0x52,
    ['1'] = 0x31, ['2'] = 0x32, ['3'] = 0x33, ['4'] = 0x34, ['5'] = 0x35,
    T = 0x54, Y = 0x59, Z = 0x5A, M = 0x4D, BACK = 0x08,
    LEFT = 0x25, RIGHT = 0x27, UP = 0x26, DOWN = 0x28,
    F1 = 0x70, F2 = 0x71, F3 = 0x72, F4 = 0x73, F5 = 0x74,
}

local function load()
    if vk then return vk end
    vk = {}
    local raw = GetResourceKvpString(KVP)
    if raw and #raw > 0 then
        local ok, res = pcall(json.decode, raw)
        if ok and type(res) == 'table' then
            for _, b in ipairs(BR.Keys.bindings) do
                local v = tonumber(res[b.command])
                if v then vk[b.command] = v end
            end
        end
    end
    for _, b in ipairs(BR.Keys.bindings) do
        if vk[b.command] == nil then vk[b.command] = DEFAULT_VK[b.default] end
    end
    return vk
end

--- Push the whole table to the interface.
function BR.Keys.push()
    local out = {}
    for _, b in ipairs(BR.Keys.bindings) do
        local code = load()[b.command]
        out[#out + 1] = {
            group   = b.group,
            command = b.command,
            label   = (b.label:gsub('^Royale:%s*', '')),
            vk      = code,
            key     = code and (BR.Keys.vkName(code) or ('#' .. code)) or '',
            default = b.default,
        }
    end
    TriggerEvent('br:ui:sendLocal', BR.Nui.KEYBINDS,
        { actions = out, raw = BR.Keys.rawActive == true })
end

--- A readable name for a virtual-key code.
---
--- Only the ones a player is plausibly going to bind. Anything else falls back
--- to its number, which is ugly and honest -- better than a wrong name.
local VK_NAME = {
    [0x08] = 'Backspace', [0x09] = 'Tab', [0x0D] = 'Enter', [0x10] = 'Shift',
    [0x11] = 'Ctrl', [0x12] = 'Alt', [0x14] = 'Caps', [0x20] = 'Space',
    [0x21] = 'Page Up', [0x22] = 'Page Down', [0x23] = 'End', [0x24] = 'Home',
    [0x25] = 'Left', [0x26] = 'Up', [0x27] = 'Right', [0x28] = 'Down',
    [0x2D] = 'Insert', [0x2E] = 'Delete',
    [0xBA] = ';', [0xBB] = '=', [0xBC] = ',', [0xBD] = '-', [0xBE] = '.',
    [0xBF] = '/', [0xC0] = '`', [0xDB] = '[', [0xDC] = '\\', [0xDD] = ']',
    [0xDE] = "'",
}
function BR.Keys.vkName(code)
    if VK_NAME[code] then return VK_NAME[code] end
    if code >= 0x30 and code <= 0x5A then return string.char(code) end   -- 0-9 A-Z
    if code >= 0x70 and code <= 0x7B then return 'F' .. (code - 0x6F) end -- F1-F12
    if code >= 0x60 and code <= 0x69 then return 'Num ' .. (code - 0x60) end
    return nil
end

--- The readable key a command is ACTUALLY on, or nil.
---
--- THE AUTHORITY WHEN THE RAW LAYER IS RUNNING, and the reason anything else
--- has to ask: the engine still believes its own RegisterKeyMapping default,
--- because nothing can change that from script. So GetControlInstructionalButton
--- kept answering "E" after interact was rebound to R, and every DUI prompt in
--- the world went on saying E (user, 2026-08-09).
--- @param command string
--- @return string|nil
function BR.Keys.labelFor(command)
    if not BR.Keys.rawActive then return nil end
    local code = load()[command]
    if not code then return nil end
    return BR.Keys.vkName(code) or ('#' .. code)
end

--- Bind one command to one virtual-key code, or to nothing.
--- @param command string
--- @param code integer|nil  nil or 0 unbinds
function BR.Keys.set(command, code)
    local known = false
    for _, b in ipairs(BR.Keys.bindings) do
        if b.command == command then known = true break end
    end
    if not known then return false end

    load()
    code = tonumber(code)
    if code == 0 then code = nil end

    -- CONFLICTS RESOLVE IN FAVOUR OF THE NEW BINDING, which is what every game
    -- does: whatever held that key is left unbound, and the screen shows which
    -- one lost it. Refusing instead would send the player hunting.
    if code then
        for c, v in pairs(vk) do
            if c ~= command and v == code then vk[c] = nil end
        end
    end
    vk[command] = code

    local store = {}
    for c, v in pairs(vk) do store[c] = v end
    SetResourceKvp(KVP, json.encode(store))

    BR.Keys.push()
    -- ANYTHING THAT DRAWS A KEY HAS TO REDRAW IT. The world prompts cache
    -- their payload per entry, so without this the crate you are standing in
    -- front of keeps naming the old key until you walk away and back.
    TriggerEvent('br:keys:changed')
    return true
end

-- The reader. One FRAME callback over a table of at most eighteen entries,
-- which is two native calls each in the worst case and none at all when the
-- raw layer is off.
--
-- HOLD ACTIONS GET BOTH EDGES, which is the thing the console-command route
-- could not have given us without the +/- names being exactly right: press
-- fires true, release fires false, and `interact` keeps working as a hold.
local rawDown = {}

BR.Loop.register(BR.Loop.FRAME, 'keybinds.raw', function()
    if not BR.Keys.rawActive then return end

    local map = load()
    for _, b in ipairs(BR.Keys.bindings) do
        local code = map[b.command]
        if code then
            -- EDGES ARE DERIVED, NOT ASKED FOR.
            --
            -- The first cut called IS_RAW_KEY_JUST_PRESSED, which DOES NOT
            -- EXIST -- only IS_RAW_KEY_PRESSED is declared in
            -- fivem/ext/native-decls. So the probe threw, the layer refused
            -- to start, and the settings screen honestly reported that
            -- rebinding was unavailable (user, 2026-08-09: "not sure why I
            -- got 'Rebinding is unavailable'"). It was right; the native was
            -- imaginary.
            --
            -- One native and a remembered bit gives both edges, which is all
            -- the missing one would have done anyway.
            local down = IsRawKeyPressed(code)
            local was = rawDown[b.command] == true
            if down ~= was then
                rawDown[b.command] = down or nil
                if down then
                    fire(b.action, true)
                    if not b.hold then fire(b.action, false) end
                elseif b.hold then
                    fire(b.action, false)
                end
            end
        end
    end
end)

-- UI actions arrive through br_ui's forwarder, the same road the locker and
-- the inventory take: br_ui owns the page and the callbacks, br_core owns
-- what they mean.
AddEventHandler('br:ui:action', function(name, data)
    if name ~= BR.NuiCb.KEYBIND_SET then return end
    BR.Keys.set(tostring(data and data.command or ''), data and data.vk)
end)

AddEventHandler('br:ui:ready', function()
    BR.Keys.push()
end)

AddEventHandler('onClientResourceStart', function(res)
    if res ~= GetCurrentResourceName() then return end

    -- PROBED, NOT ASSUMED, and the fallback is the status quo. If this build
    -- has no raw-key natives the flag stays false, the RegisterKeyMapping
    -- handlers keep working exactly as they always have, and the settings
    -- screen says so rather than offering a rebinder that cannot bind.
    -- IS_RAW_KEY_PRESSED, and only that one: it is the single raw-key native
    -- actually declared (CFX, client, takes a Windows virtual-key code). The
    -- "just pressed" and "just released" variants that would have been
    -- convenient do not exist, which is what the first version probed for and
    -- correctly failed to find.
    local ok = pcall(function() return IsRawKeyPressed(0x77) end)
    BR.Keys.rawActive = ok
    print(('[br_core] raw key layer %s'):format(ok and 'active' or 'UNAVAILABLE'))
    load()
    BR.Keys.push()
end)

RegisterCommand('brkeys', function(_, args)
    if args[1] == 'reset' then
        vk = nil
        DeleteResourceKvp(KVP)
        load()
        BR.Keys.push()
        print('[br_core] keybinds reset to defaults')
        return
    end
    print('=== keybinds ===')
    print(('  raw layer: %s'):format(tostring(BR.Keys.rawActive)))
    for _, b in ipairs(BR.Keys.bindings) do
        local code = load()[b.command]
        print(('  %-9s %-28s %s'):format(b.group, b.label,
            code and (BR.Keys.vkName(code) or ('#' .. code)) or '(unbound)'))
    end
    print('  usage: brkeys [reset]')
end, false)
