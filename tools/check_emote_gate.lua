-- Static gate: every emote entry point asks the ONE gate.
--
-- ═══ WHY THIS EXISTS ═══
--
-- Emotes (#215) were dev-mode only behind one config line. Since #388 (owner,
-- 2026-10-04) they are the first Season 2 feature: the gate is the `emotes` row
-- in br_lib/config/seasons.lua, asked as BR.Season.has('emotes'). That promise
-- is made of two halves, and either can rot without a sound:
--
--   * A DOOR THAT DOES NOT ASK. A new net handler, key, loop or console command
--     that forgets the gate is LIVE on a Season 1 box -- the feature leaks
--     into a season that was never meant to have it.
--   * A SECOND GATE. A door that asks dev mode (BR.Dev.on(), the convars,
--     BR.Server.devMode), keeps an accessor of its own, or compares the season
--     number itself is still SHUT -- or still open -- whatever the row says.
--     The one row is then two, and the second is wherever somebody hid it.
--
-- tools/verify.sh also runs every emote suite at the season before the row's
-- `from` (off) and at `from` (on), which proves both states WORK. This file
-- proves there is no door the suites do not know about. Neither is enough alone.
--
-- ═══ THE RULES ═══
--
--   G1 THE ONE ROW         exactly one `emotes = { from = <n> ... }` row in
--                          br_lib/config/seasons.lua, and the old dev-mode line
--                          (requireDevMode) named nowhere
--   G2 NO ACCESSOR         BR.Emotes.enabled is gone: neither defined nor asked
--   G3 NO SECOND GATE      no dev-mode read and no season-number comparison or
--                          pick() in an emote file or a gated body, and nobody
--                          replaces the BR.Emotes table
--   G4 EVERY DOOR ASKS     each discovered entry point calls
--                          BR.Season.has('emotes') or that file's pinned
--                          nil-safe wrapper
--   G5 NOT VACUOUS         every door the contract names is actually found
--   G6 THE PAGE            the Music volume slider and the Emotes tab render
--                          only behind `emotesOn`, in the agreed places
--   G7 NO HIDDEN DOOR      an emote door registered where G4 cannot see it --
--                          indented, or not at column 0 in an emote file --
--                          fails rather than being skipped
--
-- READS TEXT, NOT A PARSE TREE, like tools/check_net_gates.lua -- and with the
-- same blanking so prose that QUOTES a pattern is never read as code. Unlike
-- that file it blanks with a small lexer rather than per line, because the emote
-- files open with --[[ ]] headers that name every one of these patterns.
--
-- Run standalone:  lua tools/check_emote_gate.lua <file>...   (.lua and .tsx)
--                  lua tools/check_emote_gate.lua --selftest

local SEASONS = 'br_lib/config/seasons.lua'

-- ---------------------------------------------------------------------------
-- Reading Lua without parsing Lua
-- ---------------------------------------------------------------------------

--- Two views of a Lua source, line for line and column for column:
---   code   comments AND strings blanked -- what executes, minus literals
---   names  comments blanked, strings kept -- for the doors whose NAME is a
---          string ('emoteWheel', 'bremote', 'emotes.play'), so a commented-out
---          registration is not a door and a quoted one still is
--- @param src string
--- @return table code, table names
local function views(src)
    local code, names = {}, {}
    local n = #src
    local i = 1
    local function put(ch, keepName)
        if ch == '\n' then
            code[#code + 1] = '\n'; names[#names + 1] = '\n'
        else
            code[#code + 1] = keepName == 'code' and ch or ' '
            names[#names + 1] = (keepName == 'code' or keepName == 'str') and ch or ' '
        end
    end
    while i <= n do
        local c = src:sub(i, i)
        if c == '-' and src:sub(i + 1, i + 1) == '-' then
            local eq = src:match('^%[(=*)%[', i + 2)
            local stop
            if eq then
                local _, e = src:find(']' .. eq .. ']', i + 2, true)
                stop = e or n
            else
                local e = src:find('\n', i, true)
                stop = e and (e - 1) or n
            end
            for j = i, stop do put(src:sub(j, j), 'comment') end
            i = stop + 1
        elseif c == '[' and src:match('^%[=*%[', i) then
            local eq = src:match('^%[(=*)%[', i)
            local _, e = src:find(']' .. eq .. ']', i + 2 + #eq, true)
            local stop = e or n
            for j = i, stop do put(src:sub(j, j), 'str') end
            i = stop + 1
        elseif c == '"' or c == "'" then
            local j = i + 1
            while j <= n do
                local d = src:sub(j, j)
                if d == '\\' then j = j + 2
                elseif d == c or d == '\n' then break
                else j = j + 1 end
            end
            local stop = math.min(j, n)
            for k = i, stop do put(src:sub(k, k), 'str') end
            i = stop + 1
        else
            put(c, 'code')
            i = i + 1
        end
    end
    local function split(buf)
        local out = {}
        for line in (table.concat(buf) .. '\n'):gmatch('([^\n]*)\n') do out[#out + 1] = line end
        return out
    end
    return split(code), split(names)
end

--- @param path string @param suffix string
local function endsWith(path, suffix)
    return #path >= #suffix and path:sub(-#suffix) == suffix
end

-- ---------------------------------------------------------------------------
-- The doors
-- ---------------------------------------------------------------------------

--- Openers whose body runs to the first `end)` at column 0 -- or `end,`, where a
--- key listener hands BR.Keys.on its `live` check (#393). `view` says which
--- text the opener is matched against.
local OPEN_PAREN = {
    { pat = '^AddEventHandler%(%s*BR%.Net%.(EMOTE_%u[%u_]*)%s*,%s*function', view = 'code', kind = 'net' },
    { pat = '^AddEventHandler%(%s*BR%.Net%.(MARKET_UNEQUIP)%s*,%s*function', view = 'code', kind = 'net' },
    { pat = '^RegisterNetEvent%s*%(%s*BR%.Net%.(EMOTE_%u[%u_]*)%s*,%s*function', view = 'code', kind = 'net' },
    { pat = '^RegisterNetEvent%s*%(%s*BR%.Net%.(MARKET_UNEQUIP)%s*,%s*function', view = 'code', kind = 'net' },
    { pat = "^BR%.Keys%.on%(%s*'(emoteWheel)'", view = 'names', kind = 'key' },
    { pat = "^BR%.Loop%.register%(%s*BR%.Loop%.%u+%s*,%s*'(emotes%.[%w_]+)'", view = 'names', kind = 'loop' },
    { pat = "^BR%.Sched%.%a+%(.-'(emotes%.[%w_]+)'", view = 'names', kind = 'loop' },
}

--- br_ui's three Market callbacks. Only in that file.
local NUI_FILE = 'br_ui/client/market.lua'
local NUI_CBS = { 'MARKET_UNEQUIP', 'MARKET_BUY', 'MARKET_EQUIP' }

--- Named bodies, each to the first `end` at column 0, by file.
local NAMED = {
    ['br_core/server/market.lua'] = {
        '^function BR%.Market%.push%(', '^function BR%.Market%.equip%(',
        '^function BR%.Market%.unequip%(', '^function BR%.Market%.addOwned%(',
        '^AddEventHandler%(%s*BR%.Net%.MARKET_BUY',
    },
    ['br_core/client/emotes.lua'] = {
        '^function BR%.Emotes%.blocked%(', '^function BR%.Emotes%.canStart%(',
        '^function BR%.Emotes%.request%(', '^function BR%.Emotes%.nativeCheck%(',
    },
    ['br_ui/client/market.lua'] = {
        '^local function catalogue%(', '^function BR%.Market%.pushEmotes%(',
    },
}

--- Registrations G7(b) looks for in an emote file (on the code view).
local REGISTRATIONS = {
    'RegisterNetEvent%(.-,%s*function', 'AddEventHandler%(', 'RegisterNUICallback%(',
    'RegisterCommand%(', 'BR%.Keys%.on%(', 'BR%.Loop%.register%(', 'BR%.Sched%.%a+%(',
    'exports%(', 'CreateThread%(', 'SetTimeout%(',
}

--- Registrations an emote file may make that are not doors: mirrors, cleanup
--- and the wheel's close-only focus listener.
local ALLOWED = {
    '^AddEventHandler%(%s*BR%.Net%.MARKET_STATE',
    "^AddEventHandler%(%s*'onClientResourceStop'",
    "^AddEventHandler%(%s*'playerDropped'",
    "^AddEventHandler%(%s*'br:ui:focusChanged'",
}

--- An emote door registered indented, anywhere -- G4 reads column 0 only.
local INDENTED = {
    '^%s+AddEventHandler%(%s*BR%.Net%.EMOTE_', '^%s+AddEventHandler%(%s*BR%.Net%.MARKET_UNEQUIP',
    '^%s+RegisterNetEvent%(%s*BR%.Net%.EMOTE_[%w_]*%s*,',
    '^%s+RegisterNetEvent%(%s*BR%.Net%.MARKET_UNEQUIP[%w_]*%s*,',
    '^%s+RegisterNUICallback%(%s*BR%.NuiCb%.MARKET_UNEQUIP',
    "^%s+BR%.Keys%.on%(%s*'emoteWheel'", "^%s+RegisterCommand%(%s*'bremote",
    "^%s+BR%.Loop%.register%(.-'emotes%.",
}

local GATE = "BR%.Season%.has%(%s*'emotes'%s*%)"

-- ---------------------------------------------------------------------------
-- The check
-- ---------------------------------------------------------------------------

--- @param files table  { { path = string, src = string } }
--- @return table findings  { { path, line, rule, why } }, integer doors
local function run(files)
    local out = {}
    local function fail(path, line, rule, why)
        out[#out + 1] = { path = path, line = line or 0, rule = rule, why = why }
    end

    local found = {}           -- G5: what was seen
    local function saw(key) found[key] = true end
    local doors = 0
    local rows, sawSeasons = 0, false

    for _, f in ipairs(files) do
        local path = f.path
        if endsWith(path, '.lua') then
            local code, names = views(f.src)
            local lower = path:lower()
            local isEmote = lower:find('emote', 1, true) ~= nil
            local isServer = path:find('/server/', 1, true) ~= nil
            local isClient = path:find('/client/', 1, true) ~= nil

            --- The first line at or after `from` matching `pat` on the code view.
            local function stopAt(from, pat)
                for j = from, #code do
                    if code[j]:match(pat) then return j end
                end
                return #code
            end
            --- A body on the NAMES view: the gate's id is a string, and the code
            --- view blanks strings, so `has('emotes')` and `has('dances')` would
            --- read the same there.
            local function namesOf(a, b)
                return table.concat(names, '\n', a, b)
            end

            -- The pinned wrappers this file defines, and whether each asks.
            local wrappers = {}
            for i, l in ipairs(code) do
                local w = l:match('^local function (emotesOn)%(') or l:match('^local function (emoteHidden)%(')
                if w then
                    local stop = l:match('%f[%w]end%s*$') and i or stopAt(i + 1, '^end')
                    wrappers[w] = { line = i, asks = namesOf(i, stop):find(GATE) ~= nil }
                end
            end

            -- ── G1: the one row, and the old line nowhere ───────────────────
            if endsWith(path, SEASONS) then
                sawSeasons = true
                for i, l in ipairs(code) do
                    if l:match('^%s*emotes%s*=') then
                        rows = rows + 1
                        if rows > 1 then
                            fail(path, i, 'G1', 'a second `emotes` row -- there is ONE')
                        elseif not l:match('^%s*emotes%s*=%s*{%s*from%s*=%s*%d+%s*[,}]') then
                            fail(path, i, 'G1', 'the row must read `emotes = { from = <n> ... }` on one line -- verify.sh reads `from` off it')
                        end
                    end
                end
            end
            for i, l in ipairs(code) do
                if l:find('%f[%w_]requireDevMode%f[^%w_]') then
                    fail(path, i, 'G1', 'names requireDevMode -- that line is gone (#388); emotes are gated by their row in ' .. SEASONS)
                end
            end

            -- ── G2: no accessor of its own ──────────────────────────────────
            for i, l in ipairs(code) do
                if l:find('BR%.Emotes%.enabled%f[^%w_]') then
                    fail(path, i, 'G2', "BR.Emotes.enabled is gone (#388) -- a second door beside BR.Season.has('emotes')")
                end
            end

            -- ── G3 (a): no second gate in an emote file ─────────────────────
            local function devRead(i)
                return code[i]:find('BR%.Dev%.on') or code[i]:find('BR%.Server%.devMode')
                    or names[i]:find('GetConvar%s*%(%s*[\'"][bs][rv]_devMode')
            end
            --- The season NUMBER deciding something, rather than the row:
            --- current() beside a comparison, or a pick().
            local function seasonRead(i)
                local l = code[i]
                return l:find('BR%.Season%.current%(%)%s*[<>=~]') or l:find('[<>=]%s*BR%.Season%.current%(%)')
                    or l:find('BR%.Season%.pick%f[^%w_]')
            end
            if isEmote then
                for i = 1, #code do
                    if devRead(i) then
                        fail(path, i, 'G3', "an emote file reads dev mode itself -- ask BR.Season.has('emotes'), the one gate")
                    end
                    if seasonRead(i) then
                        fail(path, i, 'G3', "an emote file decides by the season number -- ask BR.Season.has('emotes'), so the row in "
                            .. SEASONS .. ' stays the one place')
                    end
                end
            end
            for i, l in ipairs(code) do
                if l:find('BR%.Emotes%s*=%s*{') then
                    fail(path, i, 'G3', 'replaces the BR.Emotes table -- write BR.Emotes = BR.Emotes or {}')
                end
            end

            -- ── G4: discover the doors, and each must ask ───────────────────
            local starts = {}
            local function door(i, stop, label)
                doors = doors + 1
                starts[i] = true
                local text = namesOf(i, stop)
                local asks = text:find(GATE) ~= nil
                for w, def in pairs(wrappers) do
                    if not asks and text:find('%f[%w_]' .. w .. '%(') and def.asks then asks = true end
                end
                if not asks then
                    fail(path, i, 'G4', label .. " does not ask BR.Season.has('emotes') (or a pinned wrapper that does)")
                end
                for j = i, stop do
                    if devRead(j) then
                        fail(path, j, 'G3', label .. ' reads dev mode -- a second gate the season row cannot open')
                    end
                    if seasonRead(j) then
                        fail(path, j, 'G3', label .. ' decides by the season number -- a second gate beside the row')
                    end
                end
            end

            for i = 1, #code do
                for _, o in ipairs(OPEN_PAREN) do
                    local name = (o.view == 'code' and code[i] or names[i]):match(o.pat)
                    if name then
                        door(i, stopAt(i + 1, '^end%s*[%),]'), name)
                        if o.kind == 'net' then
                            saw((isServer and 'server:' or isClient and 'client:' or '?:') .. name)
                        else
                            saw(o.kind .. ':' .. name)
                        end
                    end
                end
                local cmd = names[i]:match("^RegisterCommand%(%s*'(bremote[%w_]*)'")
                if cmd then
                    door(i, stopAt(i + 1, '^end%s*,'), 'command ' .. cmd)
                    saw('cmd:' .. cmd)
                end
                if endsWith(path, NUI_FILE) then
                    for _, cb in ipairs(NUI_CBS) do
                        if code[i]:match('^RegisterNUICallback%(%s*BR%.NuiCb%.' .. cb .. '%f[^%w_]') then
                            door(i, stopAt(i + 1, '^end%s*%)'), 'NUI ' .. cb)
                            saw('nui:' .. cb)
                        end
                    end
                end
            end
            for suffix, pats in pairs(NAMED) do
                if endsWith(path, suffix) then
                    for _, pat in ipairs(pats) do
                        for i = 1, #code do
                            if code[i]:match(pat) then
                                door(i, stopAt(i + 1, '^end'), (code[i]:match('^[^%(]+') or pat))
                                saw('named:' .. suffix .. ':' .. pat)
                                break
                            end
                        end
                    end
                end
            end

            -- keybinds.lua: the hold row carries the wrapper, declared above it.
            if endsWith(path, 'br_core/client/keybinds.lua') then
                for i = 1, #code do
                    if names[i]:match("^hold%(%s*'emoteWheel'") then
                        if not names[i]:match(',%s*emotesOn%s*%)%s*$') then
                            fail(path, i, 'G4', "the emoteWheel hold row must end `, emotesOn)` -- its 5th argument is the row gate")
                        end
                        local def = wrappers.emotesOn
                        if not def then
                            fail(path, i, 'G4', 'keybinds.lua has no `local function emotesOn(`')
                        else
                            if def.line >= i then
                                fail(path, def.line, 'G4', 'emotesOn is declared BELOW the hold row that names it -- a value reference the forward-locals gate cannot see, nil at load')
                            end
                            if not def.asks then
                                fail(path, def.line, 'G4', "emotesOn does not ask BR.Season.has('emotes')")
                            end
                        end
                    end
                end
            end

            -- ── G7: no door G4 cannot see ───────────────────────────────────
            for i = 1, #names do
                for _, p in ipairs(INDENTED) do
                    if names[i]:match(p) then
                        fail(path, i, 'G7', 'an emote door registered indented -- G4 reads doors that start at column 0')
                        break
                    end
                end
            end
            if isEmote then
                for i = 1, #code do
                    local hit = false
                    for _, p in ipairs(REGISTRATIONS) do
                        if code[i]:find(p) then hit = true break end
                    end
                    if hit and not starts[i] then
                        local ok = false
                        if code[i]:match('^%S') then
                            for _, p in ipairs(ALLOWED) do
                                if names[i]:match(p) then ok = true break end
                            end
                        end
                        if not ok then
                            fail(path, i, 'G7', 'a registration in an emote file that is neither a gated door nor on the allow-list')
                        end
                    end
                end
            end
        end
    end

    -- ── G1: the row exists ───────────────────────────────────────────────────
    if not sawSeasons then
        fail(SEASONS, 0, 'G1', 'not passed to the gate')
    elseif rows == 0 then
        fail(SEASONS, 0, 'G1', "no `emotes` row -- every BR.Season.has('emotes') is off in every season")
    end

    -- ── G6: the page ─────────────────────────────────────────────────────────
    local settings, market
    for _, f in ipairs(files) do
        if endsWith(f.path, 'screens/Settings.tsx') then settings = f end
        if endsWith(f.path, 'screens/Market.tsx') then market = f end
    end
    if not settings then
        fail('ui-src/src/screens/Settings.tsx', 0, 'G6', 'not passed to the gate')
    else
        local t = settings.src
        local _, labels = t:gsub('label="Music volume"', '')
        local at = t:find('{emotesOn && %(%s*<Slider%s+label="Music volume"')
        if labels ~= 1 or not at then
            fail(settings.path, 0, 'G6', 'the Music volume slider must appear once, as {emotesOn && (<Slider label="Music volume" ...')
        else
            local tut = t:find('data-tut="settings-volui"', 1, true)
            local _, divEnd = t:find('</div>', tut or #t + 1, true)
            if not tut or not divEnd or divEnd > at then
                fail(settings.path, 0, 'G6', 'the Music volume slider must sit after the settings-volui wrapper')
            else
                local between = t:sub(divEnd + 1, at - 1):gsub('{/%*.-%*/}', '')
                if not between:match('^%s*$') then
                    fail(settings.path, 0, 'G6', 'the Music volume slider is not DIRECTLY below "Interface sounds" (owner, 2026-10-02)')
                end
            end
        end
    end
    if not market then
        fail('ui-src/src/screens/Market.tsx', 0, 'G6', 'not passed to the gate')
    else
        local t = market.src
        if not t:find('const EMOTE_TAB', 1, true) or not t:find('emotesOn %? %[%.%.%.TABS, EMOTE_TAB%] : TABS') then
            fail(market.path, 0, 'G6', 'the Emotes tab must be `emotesOn ? [...TABS, EMOTE_TAB] : TABS`')
        end
        local lines = {}
        for l in (t .. '\n'):gmatch('([^\n]*)\n') do lines[#lines + 1] = l end
        for i, l in ipairs(lines) do
            if l:match('^const TABS') then
                for j = i, #lines do
                    if lines[j]:find("'emote'", 1, true) then
                        fail(market.path, j, 'G6', "TABS names 'emote' -- the tab exists only behind emotesOn, as EMOTE_TAB")
                    end
                    if j > i and lines[j]:match('^%]') then break end
                end
                break
            end
        end
    end

    -- ── G5: the doors the contract names were all found ──────────────────────
    local want = {
        'server:EMOTE_PLAY', 'server:EMOTE_STOP', 'server:MARKET_UNEQUIP', 'client:EMOTE_RECORD',
        'nui:MARKET_UNEQUIP', 'nui:MARKET_BUY', 'nui:MARKET_EQUIP', 'key:emoteWheel',
        'cmd:bremote', 'cmd:bremotegrant',
        'loop:emotes.play', 'loop:emotes.audio', 'loop:emotes.gate', 'loop:emotes.wheel',
        'loop:emotes.sweep',
    }
    for suffix, pats in pairs(NAMED) do
        for _, pat in ipairs(pats) do want[#want + 1] = 'named:' .. suffix .. ':' .. pat end
    end
    table.sort(want)
    for _, k in ipairs(want) do
        if not found[k] then
            fail('(tree)', 0, 'G5', ('%s was not found -- a gate that finds nothing passes everything'):format(k))
        end
    end

    return out, doors
end

-- ---------------------------------------------------------------------------
-- Self-test
-- ---------------------------------------------------------------------------

local R = 'resources/[fivem-royale]/'

--- A minimal tree that satisfies every rule. Each fixture below breaks it one
--- way and names the rule that must fire.
local function goodTree()
    return {
        [R .. 'br_lib/config/emotes.lua'] = table.concat({
            "-- requireDevMode and BR.Season.has('emotes') in a comment are prose",
            'BR.Emotes = BR.Emotes or {}',
            'BR.Config.Emotes = {',
            '    slots = 8,',
            '}',
        }, '\n'),
        [R .. 'br_lib/config/seasons.lua'] = table.concat({
            '-- <id> = { from = <n> } in a comment is prose; so is emotes = 9',
            'BR.Config.Seasons = {',
            '    latest = 2,',
            '    features = {',
            '        emotes = { from = 2 },',
            '    },',
            '}',
        }, '\n'),
        [R .. 'br_core/server/emotes.lua'] = table.concat({
            '--[[ AddEventHandler(BR.Net.EMOTE_PLAY, function() BR.Dev.on() end) ]]',
            'BR.Emotes = BR.Emotes or {}',
            'RegisterNetEvent(BR.Net.EMOTE_PLAY)',
            'AddEventHandler(BR.Net.EMOTE_PLAY, function(d)',
            '    local src = source',
            "    if not BR.Season.has('emotes') then return end",
            'end)',
            'RegisterNetEvent(BR.Net.EMOTE_STOP)',
            'AddEventHandler(BR.Net.EMOTE_STOP, function()',
            "    if not BR.Season.has('emotes') then return end",
            'end)',
            "BR.Sched.every(250, 'emotes.sweep', function()",
            "    local open = BR.Season.has('emotes')",
            'end)',
            "AddEventHandler('playerDropped', function() end)",
            "RegisterCommand('bremotegrant', function(src, args)",
            "    if not BR.Season.has('emotes') then return end",
            'end, true)',
        }, '\n'),
        [R .. 'br_core/server/market.lua'] = table.concat({
            "local function emoteHidden(item) return item.kind == 'emote' and not BR.Season.has('emotes') end",
            'function BR.Market.push(src)',
            "    local on = BR.Season.has('emotes')",
            'end',
            'AddEventHandler(BR.Net.MARKET_BUY, function(data)',
            '    if emoteHidden(item) then return end',
            'end)',
            'function BR.Market.equip(src, id)',
            '    if emoteHidden(item) then return end',
            'end',
            'function BR.Market.unequip(src, id)',
            '    if emoteHidden(item) then return end',
            'end',
            'RegisterNetEvent(BR.Net.MARKET_UNEQUIP)',
            'AddEventHandler(BR.Net.MARKET_UNEQUIP, function(data)',
            "    if not (BR.Season and BR.Season.has and BR.Season.has('emotes')) then return end",
            'end)',
            'function BR.Market.addOwned(src, id)',
            '    if emoteHidden(item) then return end',
            'end',
        }, '\n'),
        [R .. 'br_core/client/emotes.lua'] = table.concat({
            'BR.Emotes = BR.Emotes or {}',
            'AddEventHandler(BR.Net.MARKET_STATE, function(state) end)',
            'RegisterNetEvent(BR.Net.EMOTE_RECORD)',
            'AddEventHandler(BR.Net.EMOTE_RECORD, function(rec)',
            "    if not BR.Season.has('emotes') then return end",
            'end)',
            'function BR.Emotes.blocked()',
            "    if not BR.Season.has('emotes') then return 'gate' end",
            'end',
            'function BR.Emotes.canStart()',
            "    if not BR.Season.has('emotes') then return false end",
            'end',
            'function BR.Emotes.request(id)',
            "    if not BR.Season.has('emotes') then return false end",
            'end',
            'function BR.Emotes.nativeCheck()',
            "    if not BR.Season.has('emotes') then return {} end",
            'end',
            "BR.Loop.register(BR.Loop.TICK, 'emotes.play', function()",
            "    if not BR.Season.has('emotes') then return end",
            'end)',
            "BR.Loop.register(BR.Loop.TICK, 'emotes.audio', function()",
            "    if not BR.Season.has('emotes') then return end",
            'end)',
            "BR.Loop.register(BR.Loop.SLOW, 'emotes.gate', function()",
            "    local on = BR.Season.has('emotes')",
            'end)',
            "AddEventHandler('onClientResourceStop', function() end)",
            "RegisterCommand('bremote', function(_, args)",
            "    if not BR.Season.has('emotes') then return end",
            'end, false)',
        }, '\n'),
        [R .. 'br_core/client/emotewheel.lua'] = table.concat({
            "BR.Keys.on('emoteWheel', function(pressed)",
            "    if not BR.Season.has('emotes') then return end",
            'end)',
            "BR.Loop.register(BR.Loop.FRAME, 'emotes.wheel', function()",
            "    if BR.Emotes.blocked() ~= nil and BR.Season.has('emotes') then return end",
            'end)',
            "AddEventHandler('br:ui:focusChanged', function(screen) end)",
        }, '\n'),
        [R .. 'br_core/client/keybinds.lua'] = table.concat({
            "local function emotesOn() return BR.Season ~= nil and BR.Season.has ~= nil and BR.Season.has('emotes') == true end",
            "hold('emoteWheel',  'bremotewheel', 'Royale: Emote wheel',                'LMENU', emotesOn)",
        }, '\n'),
        [R .. 'br_ui/client/market.lua'] = table.concat({
            "local function emotesOn() return BR.Config.Emotes ~= nil and BR.Season ~= nil and BR.Season.has ~= nil and BR.Season.has('emotes') == true end",
            'local function catalogue()',
            '    if emotesOn() then end',
            'end',
            'function BR.Market.pushEmotes()',
            "    TriggerEvent('br:ui:sendLocal', BR.Nui.EMOTES, { on = emotesOn() })",
            'end',
            'RegisterNUICallback(BR.NuiCb.MARKET_BUY, function(data, cb)',
            '    if not (item and item.kind == \'emote\' and not emotesOn()) then end',
            'end)',
            'RegisterNUICallback(BR.NuiCb.MARKET_EQUIP, function(data, cb)',
            '    if not (item and item.kind == \'emote\' and not emotesOn()) then end',
            'end)',
            'RegisterNUICallback(BR.NuiCb.MARKET_UNEQUIP, function(data, cb)',
            '    if emotesOn() then end',
            'end)',
        }, '\n'),
        ['ui-src/src/screens/Settings.tsx'] = table.concat({
            '<div data-tut="settings-volui">',
            '  <Slider label="Interface sounds" />',
            '</div>',
            '{/* Owner, 2026-10-02: directly below Interface sounds */}',
            '{emotesOn && (',
            '  <Slider',
            '    label="Music volume" value={draft.volMusic}',
            '  />',
            ')}',
        }, '\n'),
        ['ui-src/src/screens/Market.tsx'] = table.concat({
            "const TABS: { id: MarketItem['kind']; label: string }[] = [",
            "  { id: 'chute', label: 'Canopies' },",
            ']',
            "const EMOTE_TAB = { id: 'emote' as const, label: 'Emotes' }",
            'const tabs = emotesOn ? [...TABS, EMOTE_TAB] : TABS',
        }, '\n'),
    }
end

--- Replace exactly one occurrence of `old` in one fixture file.
local function edit(tree, file, old, new)
    local src = tree[file]
    local a, b = src:find(old, 1, true)
    assert(a, 'selftest edit found nothing: ' .. old)
    tree[file] = src:sub(1, a - 1) .. new .. src:sub(b + 1)
    return tree
end

local CFG, SRV, MKT, CLI = R .. 'br_lib/config/emotes.lua', R .. 'br_core/server/emotes.lua',
    R .. 'br_core/server/market.lua', R .. 'br_core/client/emotes.lua'
local SEA = R .. 'br_lib/config/seasons.lua'
local WHL, KEY, UIM = R .. 'br_core/client/emotewheel.lua', R .. 'br_core/client/keybinds.lua',
    R .. 'br_ui/client/market.lua'
local SET, MTX = 'ui-src/src/screens/Settings.tsx', 'ui-src/src/screens/Market.tsx'

local FIXTURES = {
    { name = 'the good tree passes', want = nil },
    { name = 'emotes moved to Season 1 is still green', want = nil,
      mut = function(t) return edit(t, SEA, 'emotes = { from = 2 },', 'emotes = { from = 1 },') end },
    { name = 'emotes removed again from Season 3 is still green', want = nil,
      mut = function(t) return edit(t, SEA, 'emotes = { from = 2 },', 'emotes = { from = 2, untilSeason = 3 },') end },
    { name = 'the row removed', want = 'G1',
      mut = function(t) return edit(t, SEA, '        emotes = { from = 2 },\n', '') end },
    { name = 'a second row', want = 'G1',
      mut = function(t) return edit(t, SEA, '        emotes = { from = 2 },', '        emotes = { from = 2 },\n        emotes = { from = 3 },') end },
    { name = 'a row verify.sh cannot read from', want = 'G1',
      mut = function(t) return edit(t, SEA, 'emotes = { from = 2 },', 'emotes = { untilSeason = 4, from = 2 },') end },
    { name = 'the seasons file not passed', want = 'G1',
      mut = function(t) t[SEA] = nil return t end },
    { name = 'the old line back in the config', want = 'G1',
      mut = function(t) return edit(t, CFG, '    slots = 8,', '    slots = 8,\n    requireDevMode = true,') end },
    { name = 'the old line read in another file', want = 'G1',
      mut = function(t) return edit(t, CLI, 'function BR.Emotes.blocked()', 'function BR.Emotes.blocked()\n    local x = BR.Config.Emotes.requireDevMode') end },
    { name = 'the accessor defined again', want = 'G2',
      mut = function(t) return edit(t, CFG, '    slots = 8,\n}', '    slots = 8,\n}\nfunction BR.Emotes.enabled() return BR.Season.has(\'emotes\') end') end },
    { name = 'a door asking the old accessor', want = 'G2',
      mut = function(t) return edit(t, WHL, "    if not BR.Season.has('emotes') then return end\nend)\nBR.Loop.register", "    if not BR.Emotes.enabled() then return end\nend)\nBR.Loop.register") end },
    { name = 'a door comparing the season number', want = 'G3',
      mut = function(t) return edit(t, SRV, "    local open = BR.Season.has('emotes')", '    local open = BR.Season.current() >= 2') end },
    { name = 'a season pick() in an emote file', want = 'G3',
      mut = function(t) return edit(t, WHL, "AddEventHandler('br:ui:focusChanged'", "local n = BR.Season.pick({ [1] = 0, [2] = 8 })\nAddEventHandler('br:ui:focusChanged'") end },
    { name = 'a door asking another feature', want = 'G4',
      mut = function(t) return edit(t, SRV, "AddEventHandler(BR.Net.EMOTE_STOP, function()\n    if not BR.Season.has('emotes') then return end",
          "AddEventHandler(BR.Net.EMOTE_STOP, function()\n    if not BR.Season.has('dances') then return end") end },
    { name = 'BR.Dev.on() inside br_ui\'s MARKET_BUY callback', want = 'G3',
      mut = function(t) return edit(t, UIM, "    if not (item and item.kind == 'emote' and not emotesOn()) then end\nend)\nRegisterNUICallback(BR.NuiCb.MARKET_EQUIP",
          "    if not BR.Dev.on() then return end\n    if not (item and item.kind == 'emote' and not emotesOn()) then end\nend)\nRegisterNUICallback(BR.NuiCb.MARKET_EQUIP") end },
    { name = 'a dev convar read in an emote file', want = 'G3',
      mut = function(t) return edit(t, WHL, "AddEventHandler('br:ui:focusChanged'", "local dev = GetConvar('br_devMode', 'false')\nAddEventHandler('br:ui:focusChanged'") end },
    { name = 'BR.Server.devMode in the server emote file', want = 'G3',
      mut = function(t) return edit(t, SRV, "    local open = BR.Season.has('emotes')", "    local open = BR.Season.has('emotes') and BR.Server.devMode") end },
    { name = 'the BR.Emotes table replaced', want = 'G3',
      mut = function(t) return edit(t, CLI, 'BR.Emotes = BR.Emotes or {}', 'BR.Emotes = {}') end },
    { name = 'a handler that does not ask', want = 'G4',
      mut = function(t) return edit(t, SRV, "AddEventHandler(BR.Net.EMOTE_STOP, function()\n    if not BR.Season.has('emotes') then return end",
          'AddEventHandler(BR.Net.EMOTE_STOP, function()\n    local x = 1') end },
    { name = 'a named body that does not ask', want = 'G4',
      mut = function(t) return edit(t, MKT, 'function BR.Market.unequip(src, id)\n    if emoteHidden(item) then return end',
          'function BR.Market.unequip(src, id)\n    local x = 1') end },
    { name = 'a wrapper that does not ask', want = 'G4',
      mut = function(t) return edit(t, UIM, "BR.Season.has ~= nil and BR.Season.has('emotes') == true end", 'true end') end },
    { name = 'the hold row without its gate', want = 'G4',
      mut = function(t) return edit(t, KEY, "'LMENU', emotesOn)", "'LMENU')") end },
    { name = 'an emotesOn defined below the hold row', want = 'G4',
      mut = function(t)
          local src = t[KEY]
          local def, row = src:match('^([^\n]*)\n([^\n]*)$')
          t[KEY] = row .. '\n' .. def
          return t
      end },
    { name = 'a missing command', want = 'G5',
      mut = function(t) return edit(t, SRV, "RegisterCommand('bremotegrant'", "RegisterCommand('brother'") end },
    { name = 'a slider placed after another Slider', want = 'G6',
      mut = function(t) return edit(t, SET, '</div>\n', '</div>\n<Slider label="Something else" />\n') end },
    { name = 'the slider not gated', want = 'G6',
      mut = function(t) return edit(t, SET, '{emotesOn && (', '{true && (') end },
    { name = 'a TABS fixture with \'emote\' inside the rows', want = 'G6',
      mut = function(t) return edit(t, MTX, "  { id: 'chute', label: 'Canopies' },", "  { id: 'chute', label: 'Canopies' },\n  { id: 'emote', label: 'Emotes' },") end },
    { name = 'the tabs expression not gated', want = 'G6',
      mut = function(t) return edit(t, MTX, 'emotesOn ? [...TABS, EMOTE_TAB] : TABS', '[...TABS, EMOTE_TAB]') end },
    { name = 'an indented handler', want = 'G7',
      mut = function(t) return edit(t, R .. 'br_core/server/market.lua', 'function BR.Market.push(src)\n',
          'function BR.Market.push(src)\n    AddEventHandler(BR.Net.EMOTE_PLAY, function() end)\n') end },
    { name = 'a two-argument RegisterNetEvent, indented', want = 'G7',
      mut = function(t) return edit(t, UIM, 'local function catalogue()\n', 'local function catalogue()\n    RegisterNetEvent(BR.Net.EMOTE_RECORD, function() end)\n') end },
    { name = 'a two-argument RegisterNetEvent in an emote file', want = 'G7',
      mut = function(t) return edit(t, CLI, "AddEventHandler('onClientResourceStop'", "RegisterNetEvent('br:emote:other', function() end)\nAddEventHandler('onClientResourceStop'") end },
    { name = 'a thread in an emote file', want = 'G7',
      mut = function(t) return edit(t, WHL, "AddEventHandler('br:ui:focusChanged'", "CreateThread(function() end)\nAddEventHandler('br:ui:focusChanged'") end },
    { name = 'an unlisted event in an emote file', want = 'G7',
      mut = function(t) return edit(t, CLI, "AddEventHandler('onClientResourceStop'", "AddEventHandler('br:emote:secret', function() end)\nAddEventHandler('onClientResourceStop'") end },
}

local function asFiles(tree)
    local files = {}
    for path, src in pairs(tree) do files[#files + 1] = { path = path, src = src } end
    table.sort(files, function(a, b) return a.path < b.path end)
    return files
end

local function selftest()
    local bad = 0
    for _, fx in ipairs(FIXTURES) do
        local tree = goodTree()
        if fx.mut then tree = fx.mut(tree) end
        local findings = run(asFiles(tree))
        local okFx
        if fx.want == nil then
            okFx = #findings == 0
        else
            okFx = false
            for _, f in ipairs(findings) do
                if f.rule == fx.want then okFx = true end
            end
        end
        if not okFx then
            bad = bad + 1
            io.write(('\27[31mFAIL\27[0m selftest: %s -- wanted %s, got %d finding(s)%s\n'):format(
                fx.name, fx.want or 'none', #findings,
                findings[1] and (': ' .. findings[1].rule .. ' ' .. findings[1].why) or ''))
        end
    end
    if bad == 0 then
        io.write(('ok   %d selftest fixtures: G1-G7 each fire on a broken tree, and a good one -- '
            .. 'whatever season its row names -- passes\n'):format(#FIXTURES))
    end
    return bad
end

-- ---------------------------------------------------------------------------
-- Entry
-- ---------------------------------------------------------------------------

local args = { ... }
if #args == 0 then
    io.write('usage: lua tools/check_emote_gate.lua <file.lua|file.tsx>...\n')
    io.write('       lua tools/check_emote_gate.lua --selftest\n')
    os.exit(2)
end
if args[1] == '--selftest' then os.exit(selftest() > 0 and 1 or 0) end

local files = {}
for _, path in ipairs(args) do
    local fh = io.open(path, 'r')
    if fh then
        files[#files + 1] = { path = path, src = fh:read('a') }
        fh:close()
    end
end
local findings, doors = run(files)
if #findings > 0 then
    for _, f in ipairs(findings) do
        io.write(('FAIL %s:%d: %s %s\n'):format(f.path, f.line, f.rule, f.why))
    end
    os.exit(1)
end
io.write(("ok   every emote entry point asks BR.Season.has('emotes') (%d entry points; the one row is in %s)\n")
    :format(doors, SEASONS))
