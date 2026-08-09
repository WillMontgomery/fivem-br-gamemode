-- Player settings: storage, defaults and the focus for the settings screen.
--
-- LUA OWNS THE VALUES, THE PAGE OWNS THE PRESENTATION. The page never writes
-- to storage and never trusts its own optimistic copy: it sends the whole
-- object, this file clamps it, persists it, and echoes back what was actually
-- stored. A slider that snaps back to 1.30 is telling the truth about the
-- clamp; a slider that keeps a value the game did not accept is lying.
--
-- KVP, NOT A SERVER TABLE. These are preferences about one person's screen and
-- ears -- scale, colour, volume -- and they should survive a server wipe, work
-- offline, and never cost a round trip. SetResourceKvp is per-resource and
-- per-machine, which is exactly the right lifetime. The one exception is the
-- gamertag, which other players can see and which the SERVER therefore has to
-- agree to; it is stored here and proposed there.
--
-- CLAMPED HERE, NOT IN THE PAGE. The page is the thing most likely to be
-- wrong -- an old build, a hot reload mid-drag, a hand-crafted fetch -- and a
-- --ui-scale of 40 is an interface nobody can reach the settings screen to
-- undo.

local RES = GetCurrentResourceName()
local KVP = 'br:settings'

BR = BR or {}
BR.Settings = {}

--- The shipped defaults, and the schema.
---
--- Every key here is also the whitelist: anything the page sends that is not
--- in this table is dropped rather than stored, so a stale build cannot
--- accumulate junk in a player's KVP forever.
local DEFAULTS = {
    -- Interface scale. The MULTIPLIER, applied inside the root font-size
    -- clamp -- so the 11px floor and 28px ceiling still hold and no setting
    -- can produce an interface that is unreadable or that does not fit.
    uiScale     = 1.00,
    -- Text size, applied only to the things that can grow without breaking a
    -- layout: notices, chat, the kill feed, lobby prose. Deliberately NOT the
    -- HUD readouts, which live in fixed plates.
    textScale   = 1.00,
    -- 'off' | 'deuter' | 'protan' | 'tritan'. Repaints rarity, health and
    -- shield, and turns on rarity PIPS -- a count, not a hue, because a
    -- palette that only ever swaps colours still asks a colourblind player to
    -- tell two colours apart.
    colourblind = 'off',
    -- Interface audio, 0..1. The browser cue palette is the only tier a
    -- slider can reach: PlaySoundFrontend has no per-cue volume.
    volUi       = 0.70,
    volMusic    = 0.50,
    -- Draw the safe-area box the HUD lays out inside. Diagnostic, and the
    -- only honest way to answer "is my HUD cut off or is that the design".
    safeArea    = false,
    -- Proposed to the server on join. Empty means "use my platform name".
    gamertag    = '',
}

local RANGE = {
    uiScale   = { 0.80, 1.30 },
    textScale = { 0.90, 1.15 },
    volUi     = { 0.00, 1.00 },
    volMusic  = { 0.00, 1.00 },
}

local COLOURBLIND = {
    off = true, deuter = true, protan = true, tritan = true,
}

local current = nil

--- Coerce one payload into something storable. Never throws, never returns
--- nil, and never returns a field the schema does not name.
--- @param raw table|nil
--- @return table
local function sanitise(raw)
    raw = type(raw) == 'table' and raw or {}
    local out = {}

    for key, fallback in pairs(DEFAULTS) do
        local v = raw[key]
        if type(fallback) == 'number' then
            v = tonumber(v)
            local r = RANGE[key]
            if not v or v ~= v then          -- nil, or NaN, which compares false to itself
                v = fallback
            elseif r then
                v = math.max(r[1], math.min(r[2], v))
            end
        elseif type(fallback) == 'boolean' then
            v = (v == true)
        else
            v = tostring(v or fallback)
        end
        out[key] = v
    end

    if not COLOURBLIND[out.colourblind] then out.colourblind = 'off' end

    -- A gamertag is shown to other players, so the rules are the server's
    -- eventually -- but there is no reason to send it something obviously
    -- wrong. Trimmed, length-capped, and stripped of the characters that
    -- would let a name impersonate the interface around it.
    out.gamertag = out.gamertag
        :gsub('^%s+', ''):gsub('%s+$', '')
        :gsub('[%c<>~^]', '')
        :sub(1, 20)

    return out
end

--- @return table  never nil
function BR.Settings.get()
    if current then return current end

    local raw = GetResourceKvpString(KVP)
    local decoded = nil
    if raw and #raw > 0 then
        -- A corrupt or half-written value must not stop the interface
        -- loading. Falling back to defaults costs a player their preferences
        -- once; throwing here costs them the game.
        local ok, res = pcall(json.decode, raw)
        if ok and type(res) == 'table' then decoded = res end
    end

    current = sanitise(decoded)
    return current
end

--- Persist and echo. The echo is what the page renders from.
--- @param raw table|nil
--- @return table  what was actually stored
function BR.Settings.save(raw)
    current = sanitise(raw)
    SetResourceKvp(KVP, json.encode(current))
    return current
end

--- Push the stored settings to the page.
---
--- Called on every br:ui:ready, not only the first: br_ui restarting mid-match
--- gives CEF a fresh page with default scale, and nothing else would ever tell
--- it otherwise -- the interface would silently revert to 1.00 for the rest of
--- the session.
function BR.Settings.push()
    TriggerEvent('br:ui:sendLocal', BR.Nui.SETTINGS, BR.Settings.get())
end

AddEventHandler('br:ui:ready', function()
    BR.Settings.push()
end)

-- ------------------------------------------------------------- callbacks ---

RegisterNUICallback(BR.NuiCb.SETTINGS_SAVE, function(data, cb)
    local ok, stored = pcall(BR.Settings.save, data)
    if not ok then
        print(('[br_ui] settings save failed: %s'):format(tostring(stored)))
        cb({ ok = false })
        return
    end

    -- The gamertag is the one setting somebody else can see, so the server
    -- gets a say. Proposed, not asserted: the page shows whatever comes back
    -- on the roster.
    TriggerServerEvent(BR.Net.SETTINGS_NAME, { name = stored.gamertag })

    cb({ ok = true, settings = stored })
end)

RegisterNUICallback(BR.NuiCb.SETTINGS_FOCUS, function(data, cb)
    if data and data.open then
        TriggerEvent('br:ui:pushFocus', 'settings')
    else
        TriggerEvent('br:ui:popFocus', 'settings')
    end
    cb({ ok = true })
end)

RegisterNUICallback(BR.NuiCb.KEYBINDS, function(_, cb)
    -- FIVEM KEYBINDS LIVE IN GTA'S PAUSE MENU, and there is no native that
    -- rebinds a RegisterKeyMapping command from script. Building a rebinder
    -- in CEF would produce a second source of truth that disagrees with the
    -- one the game actually reads -- so the button opens the real thing
    -- instead of pretending.
    --
    -- Reuses the ESC-in-the-lobby path rather than raising the frontend here:
    -- the pause menu cannot open while NUI holds the cursor, and that path
    -- already drops focus, waits for the fade, and -- the part worth having
    -- -- hands focus BACK when the menu closes (br_core/client/state.lua).
    TriggerEvent('br:ui:clearFocus')
    TriggerEvent('br:ui:pauseRequest')
    cb({ ok = true })
end)

-- ---------------------------------------------------------------- keybind ---

-- SETTINGS IS REACHABLE FROM ANYWHERE, not only from the lobby card. A player
-- who finds the interface too small discovers that mid-match, in the middle of
-- a fight, and telling them to die first is not an answer.
--
-- Through RegisterKeyMapping like every other bind in this project, so it is
-- rebindable in the pause menu -- and UNBOUND by default: a mispressed key
-- that opens an opaque full-screen menu over a firefight is worse than no
-- shortcut at all. The lobby button is the discoverable route.
--
-- The screen follows FOCUS, exactly as the inventory panel does, so there is
-- one source of truth about whether it is open and it is the same one that
-- owns the cursor.
-- The KEY is br_core's, like every other key in the project -- registered
-- there as `brsettingsmenu` and rebindable in this very screen. This end only
-- has to answer it.
AddEventHandler('br:ui:settingsToggle', function()
    TriggerEvent('br:ui:pushFocus', 'settings')
end)

-- ---------------------------------------------------------------- console ---

RegisterCommand('brsettings', function(_, args)
    if args[1] == 'reset' then
        current = nil
        DeleteResourceKvp(KVP)
        BR.Settings.push()
        print('[br_ui] settings reset to defaults')
        return
    end

    local s = BR.Settings.get()
    print('=== settings ===')
    for _, k in ipairs({ 'uiScale', 'textScale', 'colourblind',
                         'volUi', 'volMusic', 'safeArea', 'gamertag' }) do
        print(('  %-12s %s'):format(k, tostring(s[k])))
    end
    print('  usage: brsettings [reset]')
end, false)

AddEventHandler('onClientResourceStart', function(res)
    if res ~= RES then return end
    BR.Settings.get()   -- warm the cache, so a corrupt value is reported at boot
end)
