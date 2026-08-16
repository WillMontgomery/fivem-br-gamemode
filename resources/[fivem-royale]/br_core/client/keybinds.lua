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
---
--- THE GATE HERE IS `rawHolds`, NOT `rawActive`, AND THE DIFFERENCE IS THE
--- WHOLE OF #129's SECOND ROUND.
---
--- `rawActive` means "the raw layer is reading the keyboard". `rawHolds` means
--- "and the native it resolved can answer the question a HOLD asks" -- is this
--- key down RIGHT NOW, on this frame. Only IsRawKeyDown answers that;
--- IsRawKeyPressed, the fallback for a build that predates it, is a
--- single-frame EDGE (see the long note at the reader below). On a client that
--- fell back, the raw layer can see a press and can never see a hold.
---
--- That used to be survivable and is not any more. The old crate open was a
--- start stamp and a subtraction -- it never needed the key to be down for any
--- of the interval -- so a client on the fallback opened crates anyway, and the
--- startup line calling it "holds degrade to taps" was an accurate description
--- of a cosmetic loss. Since the hold became an ACCUMULATOR that only advances
--- on frames the key reads down (#129, loot.lua), the same client accumulates
--- exactly one frame per press and the threshold is unreachable: the crate
--- cannot be opened at all, which is a core interaction gone rather than a
--- degraded one.
---
--- So the split is per-question rather than all-or-nothing. If the raw layer
--- cannot answer a hold, it does not claim one, and these two commands -- the
--- engine's own +/- pair, which has given both edges reliably since M0 -- drive
--- it instead. Taps are untouched either way.
---
--- THE COST WAS STATED AND THEN UNDERSTATED, AND THAT IS THE THIRD ROUND.
---
--- What was written here was: "on such a client, rebinding a HOLD action from
--- our settings screen does not take effect, because the engine owns the key."
--- True, and it reads like a shrug. It is not one. A rebind that does not take
--- effect is not a preference quietly ignored -- the rebind still lands in the
--- KVP, the settings screen still draws it, and every world prompt still NAMED
--- it, so the crate said "hold R" while the only thing listening was the engine
--- on E. The owner held R at crate after crate: "Welp, now trying to open a
--- crate does nothing at all" (#129). Loose loot went with it, because the
--- claim rides the same press (#139) -- one cause, two reports, and a core
--- interaction dead on a client that had done nothing wrong except use the
--- rebinder this file exists to provide.
---
--- The split itself is still right: a layer that cannot answer what a hold asks
--- must not claim one. What was missing is that the handover has to be VISIBLE.
--- See engineDrives below -- the prompt, the settings screen and the rebinder
--- now all name the engine's key for a binding the engine is driving, and a
--- rebind that cannot take effect is refused rather than stored. The player
--- loses the ability to move one action on an old build, and is told so, which
--- is a different thing entirely from the action silently going away.
local function hold(action, command, description, key)
    RegisterCommand('+' .. command, function()
        if BR.Keys.rawHolds then return end
        fire(action, true)
    end, false)
    RegisterCommand('-' .. command, function()
        if BR.Keys.rawHolds then return end
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
-- THE SMOKE TRAIL IS OURS TO ROUTE, NOT THE ENGINE'S (#131).
--
-- GTA already has a parachute-smoke input, and binding that would have been
-- the shorter road. It was refused on the owner's explicit call (2026-08-16):
-- "I'd rather not re-use that since it means leaving our own keybinds
-- authority yet again." Everything a player can rebind in this game is rebound
-- from one screen, reading one table, and an action routed by the engine
-- instead would sit in that list as a row we cannot move -- the same split
-- authority that had every world prompt saying E long after interact moved to
-- R. One table or none.
--
-- B, and the reason is the canopy. Steering a parachute occupies WASD, Space
-- and the shift/ctrl pair, so a toggle anywhere near them is a toggle that
-- gets hit while flying; B is outside that cluster, is bound to nothing on
-- foot in base GTA, is bound to nothing else here, and is not on the settings
-- screen's reserved list, so anyone who dislikes it can move it.
tap ('trail',       'brtrail',     'Royale: Toggle smoke trail',         'B')

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

-- THE PLAYER LIST IS TAP-TO-LATCH, AND THAT IS LOAD-BEARING RATHER THAN A UX
-- PREFERENCE (#95). `tap()` takes the 5th `raw` argument carrying the VK code
-- the raw layer actually wants; `hold()` does not. A hold-to-show panel on
-- tilde would have registered in the pause menu and then silently never fired,
-- because 0xC0 is not in DEFAULT_VK and hold() has no way to be told about it.
--
-- 0xC0 (VK_OEM_3, tilde) is already in the VK display-name table, so the
-- Settings row renders correctly with no change, and it is absent from the
-- UI's RESERVED map so a player can rebind it off tilde today.
--
-- F2 is the ENGINE-side fallback purely because it is unused and already in
-- DEFAULT_VK. It only matters on a client where IsRawKeyDown is unavailable --
-- the same client the Settings screen already tells that rebinding is off.
tap ('players',     'brplayers',   'Royale: Player list / report',       'F2', 0xC0)

-- br_ui owns the pages; this owns the keys. TriggerEvent crosses resources,
-- which is the same hop br_core already uses to reach the interface.
BR.Keys.on('pause', function(pressed)
    if pressed then TriggerEvent('br:ui:pauseToggle') end
end)
BR.Keys.on('players', function(pressed)
    if pressed then TriggerEvent('br:ui:playersToggle') end
end)

BR.Keys.on('settingsMenu', function(pressed)
    if pressed then TriggerEvent('br:ui:settingsToggle') end
end)

--- Names of every registered action, for the debug overlay.
BR.Keys.actions = {
    'deploy', 'trail', 'inventory', 'interact', 'drop', 'use',
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

-- A SECOND SLOT PER ACTION WAS BUILT AND THEN REMOVED (user, 2026-08-09).
-- Two keyboard keys for one action is a feature nobody asks for; the reason
-- games have two slots is that the second one holds a MOUSE BUTTON or a pad
-- input, and this layer cannot read either. Half a feature that looks like the
-- whole one is worse than not having it -- a player would find the empty
-- alternate slot, try to put mouse 4 in it, and learn what it cannot do.
-- Saves written while it existed still load; their alt entries are ignored.

--- The virtual-key codes for the DEFAULT keys above, so the raw layer can
--- reproduce them for a player who has never rebound anything.
---
--- Hand-mapped because there is no native that converts a RegisterKeyMapping
--- key name to a VK code -- and deliberately kept to exactly the keys this
--- project actually uses as defaults, rather than a general table that would
--- be mostly untested.
---
--- A DEFAULT MISSING FROM HERE IS A KEY THAT NEVER FIRES. The raw layer reads
--- this table and nothing else, so a tap() registered with a key name that is
--- absent gets `vk[command] = nil`, is skipped by the frame loop entirely, and
--- shows as "Unbound" on a settings screen the player never touched. Add the
--- entry in the same commit as the binding.
local DEFAULT_VK = {
    SPACE = 0x20, TAB = 0x09, E = 0x45, G = 0x47, R = 0x52, B = 0x42,
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

--- The saved-shape version, bumped when a stored binding has to MOVE.
---
--- 2 is the one that matters: the pause menu was F1 and is now Escape, and a
--- default only applies to somebody who has never saved anything -- everyone
--- who has played already has F1 written down. Without a migration the change
--- would land for new players only, and the owner asking for it would not get
--- it (2026-08-09). A version means it happens once and never fights a player
--- who then picks something else.
local KVP_VERSION = 2

--- Persist.
local function save()
    local keys = {}
    for c, v in pairs(vk) do keys[c] = v end
    SetResourceKvp(KVP, json.encode({ v = KVP_VERSION, keys = keys }))
end

local function load()
    if vk then return vk end
    vk = {}
    local version = 0
    local raw = GetResourceKvpString(KVP)
    if raw and #raw > 0 then
        local ok, res = pcall(json.decode, raw)
        if ok and type(res) == 'table' then
            -- THREE SHAPES, AND ALL OF THEM STILL LOAD. Flat (the first), a
            -- primary/alt pair (the second slot, since removed), and the
            -- versioned one. Nobody loses their bindings to a refactor they
            -- did not ask for.
            version = tonumber(res.v) or 0
            local keys = (type(res.keys) == 'table' and res.keys)
                      or (type(res.primary) == 'table' and res.primary)
                      or res
            for _, b in ipairs(BR.Keys.bindings) do
                local code = readSlot(keys[b.command])
                if code ~= nil then vk[b.command], chosen[b.command] = code, true end
            end
        end
    end

    -- THE MOVE TO ESCAPE, once. A player who has already bound the pause menu
    -- somewhere deliberate gets it moved too -- there is no way to tell "I
    -- chose F1" from "F1 was the default when I first played", and the owner's
    -- instruction was to put the menu on Escape. It is one line in the
    -- settings screen to move it back.
    if version < KVP_VERSION then
        vk['brpausemenu'] = 0x1B
        chosen['brpausemenu'] = nil
        if raw and #raw > 0 then
            local keys = {}
            for c, v in pairs(vk) do keys[c] = v end
            SetResourceKvp(KVP, json.encode({ v = KVP_VERSION, keys = keys }))
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

--- IS THIS BINDING BEING READ BY THIS LAYER, OR BY THE ENGINE?
---
--- THE QUESTION #129'S THIRD ROUND TURNED ON, AND THE ONE NOTHING WAS ASKING.
---
--- Our rebinder works by reading the keyboard itself: a rebind lands in the KVP
--- below and the frame loop watches the new virtual-key code. The ENGINE's copy
--- of the binding never moves -- nothing can change a RegisterKeyMapping
--- default from script, which is the entire reason this layer exists -- so an
--- action the engine is driving is an action sitting on its ORIGINAL key,
--- whatever the player has since chosen.
---
--- That was survivable while the split was all-or-nothing: either this layer
--- read every binding (and every rebind worked) or it read none (and the
--- settings screen said as much). The per-question split introduced for #129's
--- second round broke that symmetry. On a build without IS_RAW_KEY_DOWN the
--- layer keeps every TAP on the player's own key and quietly hands the HOLDS
--- back to the engine -- so `interact`, rebound to R, was being watched for by
--- nobody: this layer skips hold bindings in that mode, and the engine is
--- listening on E. Pressing R did nothing whatsoever. The crate would not open
--- (#129: "Welp, now trying to open a crate does nothing at all") and the loose
--- item would not be claimed, because the pickup rides the same press (#139).
---
--- One rule, and it is deliberately the exact complement of the test the frame
--- loop applies -- `code and (rawHolds or not b.hold)` under `rawActive`. Two
--- separately-written versions of "who owns this key" is how the prompt came to
--- name a key nothing was listening to; derived from the loop, they cannot
--- drift.
--- @param b table  one row of BR.Keys.bindings
--- @return boolean
local function engineDrives(b)
    if not BR.Keys.rawActive then return true end
    return b.hold and not BR.Keys.rawHolds
end

--- The code the ENGINE's own default for this binding sits on, or nil.
--- @param b table
--- @return integer|nil
local function engineCode(b)
    return b.raw or DEFAULT_VK[b.default]
end

--- Push the whole table to the interface.
function BR.Keys.push()
    local out = {}
    for _, b in ipairs(BR.Keys.bindings) do
        -- `or nil` folds the "deliberately unbound" false into absent: the
        -- screen draws both as "Unbound", and the wire should not carry a
        -- boolean in a field typed as a number.
        local code = load()[b.command] or nil
        -- THE SCREEN SHOWS THE KEY THAT WORKS, not the key we wrote down.
        --
        -- A row the engine is driving is on its default and cannot be moved.
        -- Drawing the player's stored choice for it is the same lie the world
        -- prompts were telling, in the one place they would go to fix it.
        local byEngine = engineDrives(b)
        if byEngine then code = engineCode(b) end
        out[#out + 1] = {
            group   = b.group,
            command = b.command,
            label   = (b.label:gsub('^Royale:%s*', '')),
            vk      = code,
            key     = code and (BR.Keys.vkName(code) or ('#' .. code)) or '',
            default = b.default,
            -- Whether this row is on its default, so the screen can offer a
            -- way back. It is the only way back for a key the capture cannot
            -- take -- Escape cancels a capture, so Escape can never be typed
            -- into one.
            custom  = (not byEngine) and chosen[b.command] == true,
            -- Additive, and the interface is free to ignore it: this row is
            -- the engine's and rebinding it here will not take. Sent so a
            -- screen that wants to say so has the fact rather than having to
            -- infer it from `raw` plus a hold flag it is not given.
            engine  = byEngine or nil,
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
    -- ESCAPE WAS MISSING, and the pause menu's own default is Escape -- so
    -- every place that names the key printed "#27" (user, 2026-08-09).
    [0x1B] = 'Esc', [0x2C] = 'PrtSc', [0x91] = 'ScrLk', [0x13] = 'Pause',
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
    -- THE KEY THAT WORKS, AND ONLY EVER THE KEY THAT WORKS.
    --
    -- A prompt exists to tell the player which key to press. A prompt naming a
    -- key nothing is listening to is worse than no prompt at all, because it
    -- turns "this feature is unavailable" into "this feature is broken" -- and
    -- the player has no way to tell those apart from a chair. That is exactly
    -- what #129's third round was: the crate said R, the engine was listening
    -- on E, and the owner reported that opening a crate "does nothing at all".
    --
    -- So a binding the ENGINE is driving is named by the ENGINE's key. See
    -- engineDrives: this layer's rebind never reaches an action it is not
    -- reading, so our stored code is not an answer to the question being
    -- asked, however deliberately the player chose it.
    --
    -- The previous rule was "ours whenever we have an opinion", written to
    -- close a real gap -- with the raw layer off, the settings screen drew the
    -- rebind and the world prompts drew the engine's default, and the two
    -- openly disagreed (user, 2026-08-09: "the loot and crates still show R").
    -- They agree again here, and now they agree on the truth: BR.Keys.push
    -- draws the engine's key for those same rows.
    for _, b in ipairs(BR.Keys.bindings) do
        if b.command == command and engineDrives(b) then
            local code = engineCode(b)
            if not code then return nil end
            return BR.Keys.vkName(code) or ('#' .. code), true
        end
    end

    -- Anything this layer IS reading is ours to answer for, whether or not the
    -- player has moved it. The engine keeps the last word only for a command
    -- nobody here is watching at all.
    if not (BR.Keys.rawActive or chosen[command]) then return nil end
    local code = load()[command]
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
    return vk['brpausemenu'] == 0x1B
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
    chosen[command] = nil

    save()
    BR.Keys.push()
    TriggerEvent('br:keys:changed')
    return true
end

--- Bind one command to one virtual-key code, or to nothing.
--- @param command string
--- @param code integer|nil  nil or 0 unbinds
function BR.Keys.set(command, code)
    local b = known(command)
    if not b then return false end

    -- A REBIND THAT CANNOT TAKE EFFECT IS REFUSED, NOT STORED.
    --
    -- The row this layer is not reading is the row the engine is driving, and
    -- the engine's key cannot be moved from script. Accepting the rebind wrote
    -- a preference that changed nothing, drew it on the settings screen and on
    -- every world prompt, and left the action on a key the player had every
    -- reason to believe they had abandoned -- which is #129's third round and
    -- #139 in one line. Saying no is a worse feature and a far better answer:
    -- the player learns immediately, and the action keeps working.
    if engineDrives(b) then
        -- The two ways to get here read differently to a player and the message
        -- says which: no raw layer at all is "this client cannot rebind
        -- anything", which the settings screen already announces; a hold on a
        -- build without the level native is one row out of twenty-one, and
        -- without being told, that row looks broken rather than unavailable.
        local why = (not BR.Keys.rawActive)
            and 'this client cannot read the keyboard directly'
            or 'this build has no IS_RAW_KEY_DOWN, so the game engine drives '
               .. 'hold actions'
        TriggerEvent('br:ui:sendLocal', BR.Nui.TOAST, {
            text = ('%s stays on %s -- %s.'):format(
                (b.label:gsub('^Royale:%s*', '')), b.default, why),
            tone = 'warn', ms = 8000,
        })
        BR.Keys.push()
        return false
    end

    load()
    code = tonumber(code)
    if code == 0 then code = nil end

    -- CONFLICTS RESOLVE IN FAVOUR OF THE NEW BINDING, which is what every game
    -- does: whatever held that key is left unbound, and the screen shows which
    -- one lost it. Refusing instead would send the player hunting.
    if code then
        for c, v in pairs(vk) do
            -- FALSE, NOT NIL. Nil is "no opinion", and no opinion means the
            -- default comes back on the next restart -- onto the very key
            -- that just took this one, so the two collide again and the
            -- player has no way to see why.
            if c ~= command and v == code then
                vk[c], chosen[c] = false, true
            end
        end
    end
    vk[command] = code or false
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

--- Whether the raw layer is currently being LIED TO about the keyboard.
---
--- THE STROBE, AND WHY THE FIRST FIX FOR IT WAS THE WRONG SHAPE (#90).
---
--- "holding tilde makes it flicker" (owner, 2026-08-16) -- and it was still
--- flickering after the first attempt, held down and watched. The mechanism, as
--- far as the engine will admit to one: taking or releasing the NUI cursor
--- disturbs the key state the raw natives read, which citizenfx/fivem#3064
--- reports for IS_RAW_KEY_DOWN by name. A key that is still physically held
--- reads UP and then DOWN again with no human involved. The loop below reads
--- that pair as a release and a fresh press, fires the tap, and the tap toggles
--- the very focus that produced it.
---
--- THAT IS A LOOP, NOT A GLITCH, and it is the loop that makes it a strobe
--- rather than one lost keystroke: focus change -> false press -> focus change.
--- The panel opens and shuts for as long as the key is down.
---
--- THE FIRST FIX MEASURED THE WRONG QUANTITY. It required a tap's key to have
--- read UP for 200ms before it could fire again -- a duration, chosen against a
--- guess at how long the disturbance lasts, and the disturbance turned out not
--- to fit inside the guess. A bigger number is not the next move. The number
--- was never the mechanism, and a constant tuned by trial is precisely what let
--- the transition-ordering bug survive for months behind a 450ms guess (#124).
---
--- SO THIS SUPPRESSES ON A STATE WE ACTUALLY KNOW. We know exactly when the
--- reading becomes untrustworthy, because br_ui says so: `br:ui:focusChanged`
--- is emitted by the same function that calls SetNuiFocus (br_ui/client/nui.lua,
--- applyFocus). From that event until the reading settles, a rising edge is
--- ADOPTED rather than fired -- the layer takes the new state as truth and tells
--- nobody. A focus change therefore cannot manufacture the tap that causes the
--- next focus change, which cuts the loop at the only point that closes it.
---
--- AND IT ENDS WHEN THE READING SETTLES, NOT AFTER AN INTERVAL. Any frame in
--- which a bound key changed state extends the window; the first quiet frame
--- after that closes it. When nothing was held as the menu opened -- the
--- ordinary case, every key already up -- that is two frames and costs nothing
--- measurable. When something was held, it lasts exactly as long as the engine
--- keeps changing its mind, which is the quantity the 200ms was trying to guess.
---
--- HOLDS ARE DELIBERATELY NOT SUPPRESSED. A hold's edges are not idempotent:
--- swallow a release and the revive or the crate pickup runs on with nothing
--- left to stop it, which is a scar dbno.lua already carries (owner,
--- 2026-08-09: a brief tap completed an entire eight-second revive). A hold
--- wrongly cancelled costs one more press; a hold never cancelled costs the
--- round. Only taps go quiet -- and only a tap can strobe anyway, because only
--- a tap toggles.
local resyncing = false
local resyncFrames = 0

--- Which native answers "is this key held right now".
---
--- Resolved once at start rather than per frame, and it is deliberately a
--- FUNCTION rather than a flag: IsRawKeyDown is the correct one and
--- IsRawKeyPressed is the fallback for a build that predates it -- on which
--- hold actions degrade to taps, which is a known and survivable loss, unlike
--- having no keys at all.
local rawDownFn = nil

--- ...AND WHETHER THAT FUNCTION ANSWERS A LEVEL OR AN EDGE, RECORDED BY THE
--- BRANCH THAT CHOSE IT.
---
--- This used to be re-derived at the far end as `rawDownFn == IsRawKeyDown`,
--- which asks the runtime a question it does not have to answer the same way
--- twice. FiveM's natives are globals materialised by the Lua runtime, and
--- comparing a stored reference against a fresh read of the global is a test
--- that can come back false while the native is present and working perfectly.
--- If it does, `rawHolds` goes false on a machine that has the level native,
--- every hold binding is handed to the engine for no reason, and the failure
--- that follows (see holdsOnEngine below) is silent.
---
--- The branch above already KNOWS which one it picked. Writing it down there
--- costs a local and cannot be wrong.
local rawLevel = false

BR.Loop.register(BR.Loop.FRAME, 'keybinds.raw', function()
    if not BR.Keys.rawActive then return end

    local map = load()
    -- Did the keyboard move at all this frame? Only used while resyncing, where
    -- it is the whole termination condition: the window lasts until the reading
    -- stops changing, rather than for a length of time somebody picked.
    local moved = false

    for _, b in ipairs(BR.Keys.bindings) do
        local code = map[b.command]
        -- A HOLD BINDING IS ONLY OURS IF WE CAN ANSWER WHAT A HOLD ASKS.
        -- Without IsRawKeyDown this loop can see the press and never the
        -- release, so it would fire a press and then a bogus release on the
        -- very next frame -- and it would ALSO be shadowing the engine's +/-
        -- pair, which can do the job properly. See the note on rawHolds at the
        -- hold() registrar; skipping the binding here is what hands it back.
        if code and (BR.Keys.rawHolds or not b.hold) then
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
            -- IS_RAW_KEY_DOWN, NOT IS_RAW_KEY_PRESSED, and the names are a
            -- trap. In FiveM's implementation (InputNatives.cpp, over GTA's
            -- own ioKeyboard arrays):
            --
            --   KeyDown(k)    = keys[active][k]                -- HELD
            --   KeyPressed(k) = keys[active][k] & changed(k)   -- JUST pressed
            --
            -- So IsRawKeyPressed is an EDGE, true for a single frame. Reading
            -- it as a held state meant every hold action released itself on
            -- the very next frame: opening a crate stopped needing a hold and
            -- became a tap (user, 2026-08-09: "why do I no longer have to
            -- HOLD the pickup button"). The edges below are derived from the
            -- state, so the state is what this has to ask for.
            local down = rawDownFn(code)
            local was = rawDown[b.command] == true

            -- A HELD FLAG THAT IS ONLY EVER WRITTEN ON AN EDGE IS A LATCH, AND
            -- A LATCH CAN BE LEFT ON.
            --
            -- BR.Keys.held is what every hold interaction in the game asks
            -- ("is the player still holding this?") and until now the only
            -- thing that ever wrote it was fire(), on a transition. So the
            -- answer was not the key's state, it was a memory of the last
            -- transition anybody noticed -- and one missed release edge left it
            -- saying "held" for as long as nothing else moved that key. dbno.lua
            -- has the scar: a brief tap completed an entire eight-second revive
            -- in playtest (owner, 2026-08-09), because the stop was raised and
            -- did not land, and nothing afterwards re-checked. The crate hold
            -- has the same shape and #129 is the same complaint about it.
            --
            -- HOLD ACTIONS ONLY, and deliberately. For a hold the raw native
            -- already answers the exact question every frame, so trusting the
            -- sample over the memory costs nothing and a lost edge self-corrects
            -- on the very next one. A tap has no held state worth the name, and
            -- writing one here would fight the resync window below -- which
            -- exists precisely because this key state is NOT trustworthy across
            -- a focus change. That is also the trade being made: a dropped
            -- frame of key state now cancels a hold in progress rather than
            -- being ridden out. For a hold that is the safe side to be wrong on
            -- -- you press again -- and it is the side the owner asked for.
            --
            -- AND IT IS ONLY REACHABLE WHEN THE SAMPLE IS A LEVEL. The branch
            -- above admits a hold binding only under rawHolds, so `down` here
            -- is always IsRawKeyDown's answer -- never the edge fallback's,
            -- which would write "not held" on fifty-nine frames in every sixty
            -- and make a hold arithmetically impossible (#129, second round).
            if b.hold then BR.Keys.held[b.action] = down end

            if down ~= was then
                moved = true
                rawDown[b.command] = down or nil

                if b.hold then
                    -- Both edges, always, resync or not. See the note on
                    -- `resyncing`: a swallowed release leaves a revive or a
                    -- crate pickup running with nothing left to stop it.
                    fire(b.action, down)
                elseif down and not resyncing then
                    fire(b.action, true)
                    fire(b.action, false)
                end
                -- The `elseif` above is the whole of the strobe fix. A rising
                -- edge inside the resync window still updates rawDown -- the
                -- layer ADOPTS the new state, so it is not left disagreeing
                -- with the keyboard -- it simply does not announce it. A focus
                -- change cannot then produce the tap that produces the next
                -- focus change.
            end
        end
    end

    -- THE WINDOW CLOSES WHEN THE KEYBOARD GOES QUIET, and never on a clock.
    --
    -- A frame in which something changed is evidence the engine is still
    -- settling, so it extends the window. The floor of one frame is not a
    -- tuning knob: the disturbance cannot be observed on the same frame the
    -- focus change was announced, so exiting immediately would be exiting
    -- before there was anything to see.
    if resyncing then
        if resyncFrames > 0 and not moved then
            resyncing = false
        end
        resyncFrames = resyncFrames + 1
    end
end)

-- THE ONE EVENT THAT MEANS "STOP TRUSTING THE KEYBOARD".
--
-- br_ui emits this from applyFocus, in the same breath as SetNuiFocus (see
-- br_ui/client/nui.lua), and TriggerEvent crosses resources -- the same hop
-- br_core and br_ui already use in both directions. Every SetNuiFocus call in
-- the project is covered by one: the bridge only changes `held` when the top of
-- the stack changes, and the top of the stack changing is exactly what this
-- announces.
--
-- IT DOES NOT CARE WHICH SCREEN. Any focus change disturbs the reading, and a
-- layer that only distrusted the keyboard for the screens it expected to be
-- opened would be back to reasoning about a list somebody has to remember to
-- update -- which is the mistake BR.FocusKeepsInput's allowlist note is about.
AddEventHandler('br:ui:focusChanged', function()
    resyncing = true
    resyncFrames = 0
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
    BR.Keys.set(command, data and data.vk)
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
    -- IS_RAW_KEY_DOWN FIRST. It is the one that reports a HELD key; the
    -- similarly named IsRawKeyPressed is a single-frame edge, and reading it
    -- as a state is what turned every hold action into a tap.
    local ok = pcall(function() return IsRawKeyDown(0x77) end)
    if ok then
        rawDownFn, rawLevel = IsRawKeyDown, true
    else
        ok = pcall(function() return IsRawKeyPressed(0x77) end)
        if ok then rawDownFn, rawLevel = IsRawKeyPressed, false end
    end
    BR.Keys.rawActive = ok
    -- TWO FLAGS, BECAUSE THERE ARE TWO QUESTIONS. See the note on the hold()
    -- registrar: `rawActive` is "this layer is reading the keyboard",
    -- `rawHolds` is "and it can tell a held key from a pressed one". Only the
    -- level native can, and the whole of #129's second round is a hold that was
    -- being driven by a layer answering the wrong one.
    --
    -- ASKED OF `rawLevel`, NOT OF A POINTER COMPARISON. The previous version
    -- read `rawDownFn == IsRawKeyDown`, which is a question about the runtime's
    -- global table rather than about this build's capabilities -- see the note
    -- on rawLevel. A false answer there silently moves every hold action onto
    -- the engine's key, which on a client that has rebound one is an
    -- interaction that stops responding entirely (#129 third round, #139).
    BR.Keys.rawHolds = ok and rawLevel
    print(('[br_core] raw key layer %s%s'):format(
        ok and 'active' or 'UNAVAILABLE',
        (ok and not BR.Keys.rawHolds)
            and ' (no IsRawKeyDown: hold actions stay on the engine binding)'
            or ''))
    load()
    BR.Keys.push()
end)

RegisterCommand('brkeys', function(_, args)
    if args[1] == 'reset' then
        vk, chosen = nil, {}
        DeleteResourceKvp(KVP)
        load()
        BR.Keys.push()
        print('[br_core] keybinds reset to defaults')
        return
    end
    print('=== keybinds ===')
    -- `holds` IS THE LINE TO READ WHEN A HOLD DOES NOT COMPLETE (#129). false
    -- with the layer active means IsRawKeyDown is missing on this build and the
    -- hold actions are being driven by the engine's +/- pair instead, which is
    -- correct but means our own rebinder does not own them.
    print(('  raw layer: %s   holds: %s   escape is ours: %s'):format(
        tostring(BR.Keys.rawActive), tostring(BR.Keys.rawHolds),
        tostring(BR.Keys.ownsEscape())))
    -- THE ONE READING THAT SAYS WHETHER THE STROBE FIX IS EVEN RUNNING. If a
    -- panel is still flickering and this has never left 0 frames, the focus
    -- event is not arriving from br_ui and the window has never opened -- which
    -- is a different fault from the window opening and being too short, and the
    -- two are indistinguishable from a chair.
    print(('  resync   : %s   frames since the last focus change: %d'):format(
        resyncing and 'OPEN (taps suppressed)' or 'closed', resyncFrames))
    -- WHAT THE KEY ACTUALLY IS, AND WHO IS LISTENING FOR IT. Printing the
    -- stored code alone is what made #129's third round unreadable from a
    -- paste: interact said R, the engine was on E, and this line agreed with
    -- the lie. `via engine` on a row means the stored rebind does not apply and
    -- the key printed is the engine's -- which is now also what the prompt and
    -- the settings screen say.
    for _, b in ipairs(BR.Keys.bindings) do
        local byEngine = engineDrives(b)
        local code = byEngine and engineCode(b) or load()[b.command]
        print(('  %-9s %-28s %-10s %s'):format(b.group, b.label,
            code and (BR.Keys.vkName(code) or ('#' .. code)) or '(unbound)',
            byEngine and 'via engine' or ''))
    end
    print('  usage: brkeys [reset]')
end, false)
