-- Key bindings, rebindable from OUR settings screen.
--
-- WHY THIS EXISTS AT ALL. Every key in this game goes through
-- RegisterKeyMapping, which puts it in GTA's pause menu under Settings -> Key
-- Bindings -> FiveM. That is the correct platform citizenship and it is a
-- terrible player experience: the list is four levels deep in a menu most
-- players never open, sorted by resource, and nothing in our interface hints
-- that it exists (user, 2026-08-09: "which are very obscure for these settings
-- btw - they're buried").
--
-- HOW IT WORKS, and the honest limitation.
--
-- FiveM has runtime console commands `bind <mapper> <input> <command>` and
-- `unbind <mapper> <input>`, reachable from script through ExecuteCommand.
-- That is a genuine, documented API and it is what this file drives.
--
-- What it does NOT do is edit the RegisterKeyMapping DEFAULT, which lives in
-- the player's fivem.cfg and is written by GTA's menu. There is no script-side
-- API for that. So a command registered with a default key would end up
-- answering to two keys: its default and the one bound here.
--
-- The answer is that OUR key-mapped commands have NO DEFAULTS. Every mapping
-- the player has comes from this file, applied at boot from kvp, so there is
-- exactly one source of truth and rebinding is unbind-then-bind. The defaults
-- below are ours, not the engine's.
--
-- The cost is real and worth naming: a player whose kvp is empty has no keys
-- until this runs. It runs on resource start, before they can reach a match,
-- and `/brkeys reset` is the escape hatch if it ever does not.

local RES = GetCurrentResourceName()
local KVP = 'br:keybinds'

BR = BR or {}
BR.Keybinds = {}

--- Everything a player can bind, in the order the settings screen lists them.
---
--- `command` is the RegisterCommand name, which is what `bind` targets.
--- Grouped so the screen can show them as sections rather than as one wall of
--- twenty rows.
local ACTIONS = {
    { group = 'Combat',    command = 'brinventory',    label = 'Inventory',        default = 'TAB' },
    { group = 'Combat',    command = 'brslot1',        label = 'Slot 1',           default = '1' },
    { group = 'Combat',    command = 'brslot2',        label = 'Slot 2',           default = '2' },
    { group = 'Combat',    command = 'brslot3',        label = 'Slot 3',           default = '3' },
    { group = 'Combat',    command = 'brslot4',        label = 'Slot 4',           default = '4' },
    { group = 'Combat',    command = 'brslot5',        label = 'Slot 5',           default = '5' },
    { group = 'World',     command = 'brinteract',     label = 'Interact / loot',  default = 'E' },
    { group = 'World',     command = 'brmarker',       label = 'Place map marker', default = 'B' },
    { group = 'Social',    command = 'brchat',         label = 'Chat',             default = 'T' },
    { group = 'Social',    command = 'brchatsquad',    label = 'Squad chat',       default = 'Y' },
    { group = 'Interface', command = 'brsettings_open', label = 'Settings',        default = '' },
    { group = 'Interface', command = 'brpausemenu',    label = 'Pause menu',       default = 'F1' },
    { group = 'Interface', command = 'brleave',        label = 'Leave the match',  default = '' },
}

BR.Keybinds.actions = ACTIONS

--- Which command each action is currently bound to. Loaded from kvp.
local bound = nil

local function load()
    if bound then return bound end
    bound = {}

    local raw = GetResourceKvpString(KVP)
    if raw and #raw > 0 then
        local ok, res = pcall(json.decode, raw)
        if ok and type(res) == 'table' then
            for _, a in ipairs(ACTIONS) do
                local k = res[a.command]
                if type(k) == 'string' then bound[a.command] = k end
            end
        end
    end

    -- Anything the stored map does not mention takes OUR default. A player who
    -- has never opened the settings screen therefore has a full set of keys,
    -- which is the whole reason the defaults live here rather than in
    -- RegisterKeyMapping.
    for _, a in ipairs(ACTIONS) do
        if bound[a.command] == nil then bound[a.command] = a.default end
    end
    return bound
end

local function save()
    SetResourceKvp(KVP, json.encode(bound or {}))
end

--- Push every binding to the engine.
---
--- IDEMPOTENT AND SAFE TO REPEAT: `bind` on a key that is already bound to the
--- same command is a no-op, so running this on every resource start costs
--- nothing and covers a fivem.cfg that was edited or lost between sessions.
local function applyAll()
    for _, a in ipairs(ACTIONS) do
        local key = load()[a.command]
        if key and #key > 0 then
            ExecuteCommand(('bind keyboard %s "%s"'):format(key, a.command))
        end
    end
end

--- Send the list and the current keys to the interface.
function BR.Keybinds.push()
    local list = {}
    for _, a in ipairs(ACTIONS) do
        list[#list + 1] = {
            group   = a.group,
            command = a.command,
            label   = a.label,
            key     = load()[a.command] or '',
            default = a.default,
        }
    end
    TriggerEvent('br:ui:sendLocal', BR.Nui.KEYBINDS, { actions = list })
end

--- Bind one action to one key, or to nothing.
---
--- CONFLICTS ARE RESOLVED BY TAKING THE KEY, which is what every game does and
--- what players expect: the new binding wins and whatever held that key is
--- left unbound. The alternative -- refusing the bind -- makes the player go
--- and find the conflict themselves, and the screen shows them which action
--- lost it.
--- @param command string
--- @param key string  '' unbinds
--- @return boolean
function BR.Keybinds.set(command, key)
    local known = false
    for _, a in ipairs(ACTIONS) do
        if a.command == command then known = true break end
    end
    if not known then return false end

    key = tostring(key or ''):upper()
    load()

    -- Take the key off whoever else had it, in the engine and in our map.
    if #key > 0 then
        for _, a in ipairs(ACTIONS) do
            if a.command ~= command and bound[a.command] == key then
                bound[a.command] = ''
            end
        end
        ExecuteCommand(('unbind keyboard %s'):format(key))
    end

    -- And off the key this action used to hold, or the old one keeps working.
    local was = bound[command]
    if was and #was > 0 and was ~= key then
        ExecuteCommand(('unbind keyboard %s'):format(was))
    end

    bound[command] = key
    if #key > 0 then
        ExecuteCommand(('bind keyboard %s "%s"'):format(key, command))
    end

    save()
    BR.Keybinds.push()
    return true
end

-- ------------------------------------------------------------- callbacks ---

RegisterNUICallback(BR.NuiCb.KEYBIND_SET, function(data, cb)
    local ok = BR.Keybinds.set(
        tostring(data and data.command or ''),
        tostring(data and data.key or ''))
    cb({ ok = ok })
end)

AddEventHandler('br:ui:ready', function()
    BR.Keybinds.push()
end)

-- ---------------------------------------------------------------- console ---

RegisterCommand('brkeys', function(_, args)
    if args[1] == 'reset' then
        bound = nil
        DeleteResourceKvp(KVP)
        applyAll()
        BR.Keybinds.push()
        print('[br_ui] keybinds reset to defaults')
        return
    end

    print('=== keybinds ===')
    for _, a in ipairs(ACTIONS) do
        local k = load()[a.command]
        print(('  %-10s %-18s %s'):format(
            a.group, a.label, (k and #k > 0) and k or '(unbound)'))
    end
    print('  usage: brkeys [reset]')
end, false)

AddEventHandler('onClientResourceStart', function(res)
    if res ~= RES then return end
    -- Applied at boot, which is the only thing standing between a fresh
    -- install and a player with no keys at all.
    applyAll()
end)
