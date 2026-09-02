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
    -- VOICE, AND THE THREE MODES ARE EXCLUSIVE RATHER THAN LAYERED:
    --   'nearby'  proximity only, out to the gamemode's range, in your own
    --             match. Squadmates get no special treatment at all.
    --   'squad'   the squad radio only, at any distance and with no falloff.
    --             Nobody outside the squad is heard, however close they are --
    --             and a player with NO squad therefore hears nobody, which is
    --             why 'nearby' is the default and not this one.
    --   'off'     neither transmitting nor listening.
    --
    -- THE VALUE IS READ, NOT RESTATED. br_core/client/voice.lua acts on this
    -- setting and used to carry its own default -- 'squad', where this file
    -- said 'nearby' -- so which one a player got depended on whether br_ui's
    -- push on br:ui:ready had landed. One definition, in br_lib/shared/enums
    -- .lua, and both sides read it. See BR.VoiceRouting there for what each
    -- mode routes; br_core owns everything done with it.
    --
    -- TWO SLOTS, ONE PER KIND OF MATCH (owner, from the playtest: "make it so
    -- that a player can save a different preference (nearby/squad/off) for
    -- squads and solos"). Which one is in force is BR.VoiceModeFor's answer,
    -- in br_lib, and br_core re-derives it rather than storing a third value.
    -- BOTH DEFAULT TO 'nearby' -- the argument for that default has not
    -- changed and is written out above BR.VoiceModeDefault.
    --
    -- 'squad' IS NOT A LEGAL VALUE IN THE SOLO SLOT. It is coerced away below
    -- by BR.ToSoloVoiceMode, which is also what makes the migration from the
    -- single old setting safe: a player whose one stored mode was 'squad'
    -- keeps it for squad matches and gets the default for solos, rather than
    -- carrying silence into every solo match they queue.
    voiceModeSolo  = BR.VoiceModeDefault,
    voiceModeSquad = BR.VoiceModeDefault,
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

-- NO LOCAL VOICE-MODE TABLE HERE ANY MORE, deliberately. The valid set and the
-- fallback are br_lib's (BR.ToVoiceMode), for the same reason the default is: a
-- mode this file accepted and br_core did not -- or the reverse -- is a setting
-- that saves and then does nothing.

local current = nil

--- Coerce one payload into something storable. Never throws, never returns
--- nil, and never returns a field the schema does not name.
--- @param raw table|nil
--- @return table
local function sanitise(raw)
    raw = type(raw) == 'table' and raw or {}
    local out = {}

    -- THE MIGRATION, AND IT RUNS BEFORE THE WHITELIST FOR A REASON.
    --
    -- `voiceMode` was one setting and is now two. The loop below drops any key
    -- the schema does not name, so by the time it has run the old value is
    -- gone -- which would silently reset every existing player to the default
    -- on the session this ships. Read here, applied only where the new keys
    -- are ABSENT, so a payload from the current settings screen (which always
    -- sends both) is untouched and this costs nothing after the first save.
    --
    -- The legacy value goes into BOTH slots and the solo one is coerced a few
    -- lines down: somebody who chose 'squad' meant it for the matches that
    -- have squads.
    local legacy = raw.voiceMode
    if legacy ~= nil then
        if raw.voiceModeSolo  == nil then raw.voiceModeSolo  = legacy end
        if raw.voiceModeSquad == nil then raw.voiceModeSquad = legacy end
    end

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
    -- Coerced by br_lib, so the fallback is the same one br_core would apply to
    -- the very same payload a moment later. The solo slot gets the stricter of
    -- the two: 'squad' there is a match with no squads, which is silence, and
    -- br_lib is where that judgement lives so both resources inherit it.
    out.voiceModeSolo  = BR.ToSoloVoiceMode(out.voiceModeSolo)
    out.voiceModeSquad = BR.ToVoiceMode(out.voiceModeSquad)

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
    local s = BR.Settings.get()
    TriggerEvent('br:ui:sendLocal', BR.Nui.SETTINGS, s)
    -- AND TO LUA. Everything above is presentation the PAGE applies; voice is
    -- the first setting whose effect is a native, and br_core owns natives.
    -- One event rather than br_core reaching into this resource's storage.
    TriggerEvent('br:settings:changed', s)
end

AddEventHandler('br:ui:ready', function()
    BR.Settings.push()
end)

--- SOMEBODY ELSE STARTED AND MISSED THE PUSH.
---
--- `br:ui:ready` is the NUI page coming up, and it is the only thing that has
--- ever caused a push. That is enough for the page -- it is the page's own
--- event -- but it is not enough for the other CONSUMERS of these settings,
--- which are now br_core's voice channels and its DUI prompts. Restart br_core
--- on its own and it starts with defaults, having missed a push that already
--- happened and will not happen again until the player opens this screen.
---
--- So the read is available on request as well as on schedule. push() is
--- idempotent -- it re-sends the stored object to the page and re-fires
--- br:settings:changed -- so answering costs one repaint and cannot desync
--- anything: nothing here writes, and the answer is whatever is in KVP.
---
--- The caller is br_core/client/dui.lua on its own onClientResourceStart. If
--- br_ui is the one that restarted, this handler does not exist for a moment
--- and the request is dropped -- which is correct, because br_ui coming up
--- fires `br:ui:ready` and pushes anyway.
AddEventHandler('br:settings:request', function()
    BR.Settings.push()
end)

-- ------------------------------------------------------------- callbacks ---

RegisterNUICallback(BR.NuiCb.SETTINGS_SAVE, function(data, cb)
    -- THE NAME IS CHECKED BEFORE ANYTHING IS STORED, and the answer comes
    -- back with the save so the screen can say so while the player is still
    -- looking at the field. The same BR.ValidateName runs on the server,
    -- which is the actual boundary -- this copy exists to make the refusal
    -- instant rather than to be trusted.
    local nameOk, reason = BR.ValidateName(data and data.gamertag)
    if not nameOk then
        cb({ ok = false, field = 'gamertag', reason = reason })
        return
    end

    local ok, stored = pcall(BR.Settings.save, data)
    if not ok then
        print(('[br_ui] settings save failed: %s'):format(tostring(stored)))
        cb({ ok = false, reason = 'Could not save.' })
        return
    end

    -- The gamertag is the one setting somebody else can see, so the server
    -- gets the final say. Proposed, not asserted: the roster is what the
    -- interface ends up showing.
    TriggerServerEvent(BR.Net.SETTINGS_NAME, { name = stored.gamertag })
    TriggerEvent('br:settings:changed', stored)

    cb({ ok = true, settings = stored })
end)

--- THE PAGE REPORTS ITS RESOLVED PALETTE, FOR THE DOCUMENTS THAT CANNOT READ IT.
---
--- ═══ WHY A COLOUR TRAVELS FROM THE UI TO LUA, WHICH IS THE WRONG DIRECTION
---     FOR EVERYTHING ELSE IN THIS FILE ═══
---
--- The world prompts (br_ui/dui/prompt.html) are a separate document rendered
--- into a runtime texture. They share no stylesheet with the HUD, so they cannot
--- read `--color-hp` -- and the warmup shop's price line has to BE --color-hp
--- (owner, 2026-08-29: the price "needs to be increased in font size and make it
--- green"). That token is one of the four the colourblind modes remap, so a
--- fixed green would be the one thing on screen that ignores the setting.
---
--- THE ALTERNATIVES ALL DUPLICATE index.css. A hex in Lua, or a second copy of
--- the :root[data-cb] blocks inside prompt.html, is a second representation of
--- the accessibility palette -- and the day the green is retuned, one of the two
--- goes stale in silence. This is the repository's signature defect and it is
--- not worth a paint.
---
--- So the page -- which is the only thing that knows what the cascade resolved
--- to -- says what the answer IS, one line after applying the attribute that
--- decides it (ui-src/src/settings/apply.ts). index.css stays the sole place a
--- green is written down.
---
--- A RAW CALLBACK NAME rather than a BR.NuiCb constant, and deliberately: this
--- is not a setting. It is a derived value reported back, it is never stored,
--- never validated against a range, and never round-tripped to the page.
---
--- NOT VALIDATED AS A COLOUR EITHER, because there is nothing to validate
--- against and nothing to protect: the string is handed to a CSS `color`
--- property in a texture-backed document with no DOM anybody can reach. A
--- garbage value paints a prompt wrong until the next settings apply, which is
--- the same failure as no value at all.
--- TWO COLOURS NOW, AND THE SECOND ONE IS NOT AN ACCESSIBILITY TOKEN.
---
--- Owner, 2026-08-30: "the volts text should be orange - the same color we show
--- in the market page." The Store screen paints its balance and its prices with
--- `--color-royale-accent2`, so `volts` carries that token down the same wire
--- the green already travels on. It is reported for the reason above -- one
--- authored place for a colour -- and not because anything remaps it today.
---
--- ONE MESSAGE CARRYING BOTH, rather than a second callback: the page resolves
--- them in the same breath (one getComputedStyle pass, one apply), and a reader
--- that got a green and then a colour later would have a window where the plate
--- was half-repainted.
RegisterNUICallback('br/ui/palette', function(data, cb)
    local d = type(data) == 'table' and data or {}
    local hp = type(d.hp) == 'string' and d.hp ~= '' and d.hp or nil
    local volts = type(d.volts) == 'string' and d.volts ~= '' and d.volts or nil
    if hp or volts then
        TriggerEvent('br:settings:palette', { hp = hp, volts = volts })
    end
    cb({ ok = true })
end)

RegisterNUICallback(BR.NuiCb.SETTINGS_FOCUS, function(data, cb)
    if data and data.open then
        TriggerEvent('br:ui:pushFocus', 'settings')
    else
        TriggerEvent('br:ui:popFocus', 'settings')
    end
    cb({ ok = true })
end)

-- Somebody else needs this screen gone: the Controls tab can hand over to
-- GTA's own key bindings, and the frontend is a scaleform -- nothing we draw
-- can sit over it, so a settings screen left open underneath would keep the
-- cursor with no way to reach it.
AddEventHandler('br:ui:closeSettings', function()
    TriggerEvent('br:ui:popFocus', 'settings')
end)

RegisterNUICallback(BR.NuiCb.KEYBINDS, function(_, cb)
    -- FIVEM KEYBINDS LIVE IN GTA'S PAUSE MENU, and there is no native that
    -- rebinds a RegisterKeyMapping command from script. Building a rebinder
    -- in CEF would produce a second source of truth that disagrees with the
    -- one the game actually reads -- so the button opens the real thing
    -- instead of pretending.
    --
    -- THE SAME DOOR AS THE VOICE AND GRAPHICS BUTTONS, and it was not (#138).
    --
    -- This used to do `clearFocus` then `br:ui:pauseRequest`, which raised the
    -- frontend from br_core and told the PAGE nothing. Clearing the focus stack
    -- is about the cursor; the lobby is drawn from match state rather than from
    -- focus, so it kept painting over the scaleform -- #122's report, on the one
    -- route that was never converted, reachable from the lobby which is the only
    -- place it shows.
    --
    -- handOverToFrontend announces the frontend to the page before raising it
    -- and clears the announcement once it is genuinely down, by whatever route
    -- the player left it. It also restores focus itself, so this must NOT also
    -- fire pauseRequest -- two restore mechanisms racing was the trap here.
    BR.Pause.handOverToFrontend()
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
                         'volUi', 'volMusic',
                         -- Both voice slots, because "which mode am I on" is
                         -- now an answer this file does not have on its own --
                         -- it stores the pair and br_core picks. /brvoice on
                         -- the br_core side prints the one in force.
                         'voiceModeSolo', 'voiceModeSquad', 'gamertag' }) do
        print(('  %-12s %s'):format(k, tostring(s[k])))
    end
    print('  usage: brsettings [reset]')
end, false)

AddEventHandler('onClientResourceStart', function(res)
    if res ~= RES then return end
    BR.Settings.get()   -- warm the cache, so a corrupt value is reported at boot
end)
