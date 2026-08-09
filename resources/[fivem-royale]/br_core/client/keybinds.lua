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
--- @param raw integer|nil    raw-layer default, when it must DIFFER from the
---                           engine's. Only the pause menu needs this: its key
---                           is Escape, and Escape is not something
---                           RegisterKeyMapping can be given.
local function tap(action, command, description, key, raw)
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
        default = key, hold = false, group = group, raw = raw,
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
-- ESCAPE, because we are replacing GTA's pause menu rather than sitting
-- beside it (user call, 2026-08-09). DISABLE_FRONTEND_THIS_FRAME
-- (0x6D3465A73092F0E6) is the documented way to take the engine's menu away --
-- it stops the frontend being TOGGLED, from the keyboard and from a
-- controller's Start alike, which is why this can be done at all now and could
-- not be by disabling control 199/200.
--
-- Two guards, because a pause menu you cannot open is a soft lock:
--   * the suppression follows the binding (BR.Keys.ownsEscape) -- rebind our
--     menu off Escape and GTA's comes straight back;
--   * and it needs the raw layer, so a client without it keeps the engine's
--     menu and reaches ours on F1.
-- F1 stays as the ENGINE-side default for exactly that fallback; the raw
-- layer's own default is Escape, which RegisterKeyMapping cannot be given.
--
-- Settings is deliberately unbound: it is reachable from the lobby and from
-- the pause menu, and a mispressed key that throws a full-screen opaque menu
-- over a firefight is worse than no shortcut.
tap ('pause',       'brpausemenu', 'Royale: Pause menu',                 'F1', 0x1B)
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

--- command -> virtual-key code, or FALSE for "deliberately on no key".
---
--- `false` and `nil` are different answers and the difference is load-bearing.
--- nil means nobody has said anything, so the default applies; false means the
--- player cleared it, or it lost a conflict to another action -- and that has
--- to SURVIVE A RESTART. It did not: the table was rebuilt from the KVP and
--- then every missing entry was filled in from DEFAULT_VK, so a command that
--- had been unbound came back on its default key the next session -- straight
--- back onto the key that took it from it. Rebind interact to R once and both
--- interact and USE end up on R after a reload, quietly, with the settings
--- screen showing exactly that and no way to read it as a bug.
local vk = nil

--- Commands the player has an OPINION about -- rebound or cleared.
---
--- Separate from `vk` because "we own this binding" is a different question
--- from "what key is it": the world prompts need to know whether to trust our
--- answer or the engine's, and a command sitting on its default is one we have
--- no more claim to than the engine does.
local chosen = {}

--- The SECOND key each command may have, same shape as `vk`.
---
--- Every game with a keyboard settings screen has two slots per action, and
--- for the same reason: a player who wants Q *and* the side mouse button, or
--- who is learning a new layout without giving up the old one, should not have
--- to choose (user, 2026-08-09). Ours is a plain second table -- the reader
--- checks both, everything else treats them identically, and a command with
--- nothing in this table behaves exactly as it did before.
local alt = nil

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

--- One stored slot, as three distinct answers.
---
--- A number is a key. `false` (or a legacy 0) is "deliberately on no key". And
--- nil is silence, which is the only one that takes a default.
--- @return integer|false|nil
local function readSlot(stored)
    if stored == false or stored == 0 then return false end
    return tonumber(stored)
end

local function load()
    if vk then return vk end
    vk, alt = {}, {}
    local raw = GetResourceKvpString(KVP)
    if raw and #raw > 0 then
        local ok, res = pcall(json.decode, raw)
        if ok and type(res) == 'table' then
            -- MIGRATION, AND IT COSTS ONE LINE. The first shape was a flat
            -- command -> code table; the second has named slots. A save from
            -- before this change has no `primary` field, so the table ITSELF
            -- is the primary map -- and nobody loses their bindings to a
            -- refactor they did not ask for.
            local first  = type(res.primary) == 'table' and res.primary or res
            local second = type(res.alt) == 'table' and res.alt or {}
            for _, b in ipairs(BR.Keys.bindings) do
                local p, a = readSlot(first[b.command]), readSlot(second[b.command])
                if p ~= nil then vk[b.command], chosen[b.command] = p, true end
                if a ~= nil then alt[b.command], chosen[b.command] = a, true end
            end
        end
    end
    for _, b in ipairs(BR.Keys.bindings) do
        -- `b.raw` is a raw-layer default that DIFFERS from the one registered
        -- with the engine -- the pause menu is Escape here and F1 there,
        -- because the engine cannot be given Escape and we can.
        if vk[b.command] == nil then vk[b.command] = b.raw or DEFAULT_VK[b.default] end
    end
    return vk
end

--- Persist both slots.
local function save()
    local p, a = {}, {}
    for c, v in pairs(vk) do p[c] = v end
    for c, v in pairs(alt) do a[c] = v end
    SetResourceKvp(KVP, json.encode({ primary = p, alt = a }))
end

--- Push the whole table to the interface.
function BR.Keys.push()
    local out = {}
    for _, b in ipairs(BR.Keys.bindings) do
        -- `or nil` folds the "deliberately unbound" false into absent: the
        -- screen draws both as "Unbound", and the wire should not carry a
        -- boolean in a field typed as a number.
        local code = load()[b.command] or nil
        local code2 = alt[b.command] or nil
        out[#out + 1] = {
            group   = b.group,
            command = b.command,
            label   = (b.label:gsub('^Royale:%s*', '')),
            vk      = code,
            key     = code and (BR.Keys.vkName(code) or ('#' .. code)) or '',
            altVk   = code2,
            altKey  = code2 and (BR.Keys.vkName(code2) or ('#' .. code2)) or '',
            default = b.default,
            -- Whether this row is on its default, so the screen can offer a
            -- way back. It is the only way back for a key the capture cannot
            -- take -- Escape cancels a capture, so Escape can never be typed
            -- into one.
            custom  = chosen[b.command] == true,
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
--- @return string|nil label
--- @return boolean owned  true when this answer is ours and there is no
---                        sensible fallback -- an unbound action has NO key,
---                        and naming the engine's stale default for it is a
---                        prompt that lies.
function BR.Keys.labelFor(command)
    -- OURS WHENEVER WE HAVE AN OPINION, not only while the raw layer runs.
    --
    -- The gate used to be `rawActive` alone, which left a gap with teeth: if
    -- the raw layer is off, every rebind still lands in the KVP and is still
    -- what the settings screen draws -- so the screen said one key and the
    -- world prompts said whatever the engine remembered, and the two openly
    -- disagreed (user, 2026-08-09: "the loot and crates still show R"). One
    -- table answers both, or they drift apart again.
    --
    -- The engine keeps the last word for a command nobody has touched, which
    -- is the case where it genuinely knows more than we do: a player who
    -- rebinds in GTA's own list has changed something we never see.
    if not (BR.Keys.rawActive or chosen[command]) then return nil end
    -- The PRIMARY is what a prompt names. A second key is a convenience for
    -- the player who set it; printing both over a crate would be noise.
    local code = load()[command] or alt[command]
    if not code then return nil, chosen[command] == true end
    return BR.Keys.vkName(code) or ('#' .. code), true
end

--- Is our pause menu the thing Escape opens?
---
--- ASKED BEFORE THE ENGINE'S OWN MENU IS SUPPRESSED, and that is the whole
--- point of it being a question rather than a constant. DisableFrontendThisFrame
--- takes GTA's pause menu away; doing that unconditionally would mean a player
--- who rebinds our pause menu to something else has no pause menu at all and
--- no way back. So the suppression follows the binding: hold Escape and the
--- frontend is ours, give Escape up and it is the engine's again.
--- @return boolean
function BR.Keys.ownsEscape()
    if not BR.Keys.rawActive then return false end
    load()
    return vk['brpausemenu'] == 0x1B or alt['brpausemenu'] == 0x1B
end

--- Is this a command we registered?
local function known(command)
    for _, b in ipairs(BR.Keys.bindings) do
        if b.command == command then return b end
    end
    return nil
end

--- Put a command back on its default key, both slots.
---
--- The way back for a key the CAPTURE CANNOT TAKE. Escape cancels a capture --
--- it has to, or a player who opens the row by accident is trapped in it --
--- so Escape can never be typed into one, and the pause menu's own default is
--- Escape. Without this, rebinding pause once would be one-way.
--- @param command string
function BR.Keys.reset(command)
    local b = known(command)
    if not b then return false end

    load()
    vk[command] = b.raw or DEFAULT_VK[b.default]
    alt[command] = nil
    chosen[command] = nil

    save()
    BR.Keys.push()
    TriggerEvent('br:keys:changed')
    return true
end

--- Bind one command to one virtual-key code, or to nothing.
--- @param command string
--- @param code integer|nil  nil or 0 unbinds
--- @param slot integer|nil  1 (default) or 2 for the alternate key
function BR.Keys.set(command, code, slot)
    if not known(command) then return false end

    load()
    slot = (tonumber(slot) == 2) and 2 or 1
    local map = (slot == 2) and alt or vk
    code = tonumber(code)
    if code == 0 then code = nil end

    -- CONFLICTS RESOLVE IN FAVOUR OF THE NEW BINDING, which is what every game
    -- does: whatever held that key is left unbound, and the screen shows which
    -- one lost it. Refusing instead would send the player hunting.
    --
    -- ACROSS BOTH SLOTS, including this command's other one. A key that is a
    -- command's primary AND its alternate is one binding wearing two hats: it
    -- looks like a spare that does not exist, and clearing the primary would
    -- leave the action still firing with nothing on screen to explain it.
    if code then
        for _, pair in ipairs({ { vk, 1 }, { alt, 2 } }) do
            local m, n = pair[1], pair[2]
            for c, v in pairs(m) do
                -- FALSE, NOT NIL. Nil is "no opinion", and no opinion means
                -- the default comes back on the next restart -- onto the very
                -- key that just took this one, so the two collide again and
                -- the player has no way to see why.
                if v == code and not (c == command and n == slot) then
                    m[c], chosen[c] = false, true
                end
            end
        end
    end
    map[command] = code or false
    chosen[command] = true

    save()
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
        local code, code2 = map[b.command], alt[b.command]
        if code or code2 then
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
            -- EITHER KEY. Two slots is one action, so the action is down
            -- while ANY of its keys is -- and holding both and releasing one
            -- must not fire a release, which falling out of an `or` gives for
            -- free.
            local down = (code and IsRawKeyPressed(code))
                      or (code2 and IsRawKeyPressed(code2)) or false
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
    local command = tostring(data and data.command or '')
    if data and data.reset then
        BR.Keys.reset(command)
        return
    end
    BR.Keys.set(command, data and data.vk, data and data.slot)
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
        vk, alt, chosen = nil, nil, {}
        DeleteResourceKvp(KVP)
        load()
        BR.Keys.push()
        print('[br_core] keybinds reset to defaults')
        return
    end
    print('=== keybinds ===')
    print(('  raw layer: %s   escape is ours: %s'):format(
        tostring(BR.Keys.rawActive), tostring(BR.Keys.ownsEscape())))
    for _, b in ipairs(BR.Keys.bindings) do
        local code, code2 = load()[b.command], alt[b.command]
        print(('  %-9s %-28s %-10s %s'):format(b.group, b.label,
            code and (BR.Keys.vkName(code) or ('#' .. code)) or '(unbound)',
            code2 and (BR.Keys.vkName(code2) or ('#' .. code2)) or ''))
    end
    print('  usage: brkeys [reset]')
end, false)
