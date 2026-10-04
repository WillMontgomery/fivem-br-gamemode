-- Static gate: the season list and its one door (#388).
--
-- ═══ WHY THIS EXISTS ═══
--
-- Owner, 2026-10-04: features are gated "by a server convar (set at startup)
-- for which season the server should be running", so one codebase runs Season
-- 3 on dev and Season 2 on prod. The whole mechanism is one list,
-- br_lib/config/seasons.lua, and one door, BR.Season.has(id). Each half fails
-- QUIETLY when it rots:
--
--   * A TYPO'D ID is off in every season. BR.Season.has fails closed on an id
--     with no row, which is the right way for a door to fail and the wrong way
--     for a build to: the feature just never appears, on any box.
--   * A ROW NOTHING ASKS is a season gate that gates nothing; the feature it
--     names is live everywhere while the list says otherwise.
--   * A `from` PAST `latest` is a feature an unset box never runs, though the
--     owner's rule is that an unset box runs everything; an untilSeason at or
--     before its `from` is a feature no season has.
--   * A SECOND READER of br_season decides on its own copy of the answer --
--     at load time, unvalidated, without the fallback or the warning.
--   * A SECOND WRITER of the season in force. BR.Season.switch moves it
--     without a restart, and the owner's rule is that only the dev-mode
--     `brseason` does that (prod is restart-only); a call anywhere else is a
--     season that changes under a running box with no command typed.
--
-- ═══ THE RULES ═══
--
--   S1 KNOWN IDS     every BR.Season.has(...) takes its id as a string literal,
--                    and the id is a row
--   S2 NO DEAD ROWS  every row is asked about somewhere in resources/
--   S3 SANE NUMBERS  `latest` is a whole number from 1; every row is
--                    { from = <n>, untilSeason = <m>? } and nothing else, with
--                    1 <= n <= latest and m > n
--   S4 ONE READER    no file but br_lib/shared/season.lua names br_season (or
--                    br_seasonServed) in code or in a string, or reaches it as
--                    BR.Season.CONVAR or BR.Season.SERVED
--   S5 ONE DOOR      BR.Season.has is only ever CALLED (or nil-checked) -- never
--                    aliased or passed along, where S1 could not see the id
--   S6 ONE SWITCH    BR.Season.switch is named only by br_core/server/season.lua,
--                    the dev-mode `brseason` (and defined by the module)
--
-- READS TEXT, NOT A PARSE TREE, with the same lexer as tools/check_emote_gate.lua
-- so prose that QUOTES a pattern is never read as code. The registry itself is
-- LOADED, in a sandbox, so S3 judges the numbers the game will see.
--
-- Run standalone:  lua tools/check_seasons.lua <file.lua>...
--                  lua tools/check_seasons.lua --selftest

local REGISTRY = 'br_lib/config/seasons.lua'
local MODULE = 'br_lib/shared/season.lua'
local SWITCHER = 'br_core/server/season.lua'

-- ---------------------------------------------------------------------------
-- Reading Lua without parsing Lua (tools/check_emote_gate.lua's lexer)
-- ---------------------------------------------------------------------------

--- Two views of a Lua source, line for line and column for column:
---   code   comments AND strings blanked
---   names  comments blanked, strings kept -- has()'s id is a string
--- @param src string
--- @return table code, table names
local function views(src)
    local code, names = {}, {}
    local n = #src
    local i = 1
    local function put(ch, kind)
        if ch == '\n' then
            code[#code + 1] = '\n'; names[#names + 1] = '\n'
        else
            code[#code + 1] = kind == 'code' and ch or ' '
            names[#names + 1] = (kind == 'code' or kind == 'str') and ch or ' '
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
-- The registry, loaded
-- ---------------------------------------------------------------------------

--- BR.Config.Seasons as the file builds it, or nil and why.
--- @param src string
--- @return table|nil, string|nil
local function loadRegistry(src)
    local env = { BR = { Config = {} } }
    local chunk, err = load(src, '@' .. REGISTRY, 't', env)
    if not chunk then return nil, 'does not load: ' .. tostring(err) end
    local okRun, runErr = pcall(chunk)
    if not okRun then return nil, 'raises while loading: ' .. tostring(runErr) end
    local cfg = env.BR.Config and env.BR.Config.Seasons
    if type(cfg) ~= 'table' then return nil, 'builds no BR.Config.Seasons table' end
    return cfg
end

-- ---------------------------------------------------------------------------
-- The check
-- ---------------------------------------------------------------------------

--- @param files table  { { path = string, src = string } }
--- @return table findings  { { path, line, rule, why } }
--- @return table summary  { rows = n, asks = n, latest = n }
local function run(files)
    local out = {}
    local function fail(path, line, rule, why)
        out[#out + 1] = { path = path, line = line or 0, rule = rule, why = why }
    end

    -- ── S3: the registry ────────────────────────────────────────────────────
    local reg
    for _, f in ipairs(files) do
        if endsWith(f.path, REGISTRY) then reg = f end
    end
    local rows = {}
    local nRows, latest = 0, nil
    if not reg then
        fail(REGISTRY, 0, 'S3', 'not passed to the gate')
    else
        local cfg, why = loadRegistry(reg.src)
        if not cfg then
            fail(reg.path, 0, 'S3', why)
        else
            latest = cfg.latest
            if math.type(latest) ~= 'integer' or latest < 1 then
                fail(reg.path, 0, 'S3', ('latest is %s, not a whole number from 1'):format(tostring(latest)))
                latest = nil
            end
            if type(cfg.features) ~= 'table' then
                fail(reg.path, 0, 'S3', 'features is not a table')
            else
                for id, row in pairs(cfg.features) do
                    nRows = nRows + 1
                    rows[id] = true
                    local name = tostring(id)
                    if type(id) ~= 'string' or not id:match('^[%a_][%w_]*$') then
                        fail(reg.path, 0, 'S3', ('row %s: an id is a plain identifier'):format(name))
                    end
                    if type(row) ~= 'table' then
                        fail(reg.path, 0, 'S3', ('row %s is not a table'):format(name))
                    else
                        for k in pairs(row) do
                            if k ~= 'from' and k ~= 'untilSeason' then
                                fail(reg.path, 0, 'S3', ('row %s: unknown key %s -- a row is from and untilSeason only, and has() would ignore it')
                                    :format(name, tostring(k)))
                            end
                        end
                        local from, till = row.from, row.untilSeason
                        if math.type(from) ~= 'integer' or from < 1 then
                            fail(reg.path, 0, 'S3', ('row %s: from is %s, not a whole number from 1'):format(name, tostring(from)))
                        elseif latest and from > latest then
                            fail(reg.path, 0, 'S3', ('row %s: from = %d is past latest = %d -- an unset box would never run it; raise latest')
                                :format(name, from, latest))
                        end
                        if till ~= nil then
                            if math.type(till) ~= 'integer' then
                                fail(reg.path, 0, 'S3', ('row %s: untilSeason is %s, not a whole number'):format(name, tostring(till)))
                            elseif math.type(from) == 'integer' and till <= from then
                                fail(reg.path, 0, 'S3', ('row %s: untilSeason = %d is not after from = %d -- no season has it')
                                    :format(name, till, from))
                            end
                        end
                    end
                end
            end
        end
    end

    -- ── S1 / S4 / S5: every file ────────────────────────────────────────────
    local asked = {}
    local nAsks = 0
    for _, f in ipairs(files) do
        if endsWith(f.path, '.lua') then
            local isModule = endsWith(f.path, MODULE)
            local code, names = views(f.src)
            for i = 1, #names do
                local l = names[i]

                -- S4: nobody else names the convar, in code or in a string.
                if not isModule and l:find('br_season', 1, true) then
                    fail(f.path, i, 'S4', 'names br_season -- only ' .. MODULE .. ' reads it; ask BR.Season.current() or has()')
                end
                -- ...nor reaches it through the module's own names for it.
                if not isModule and (code[i]:find('BR%.Season%.CONVAR%f[^%w_]')
                                     or code[i]:find('BR%.Season%.SERVED%f[^%w_]')) then
                    fail(f.path, i, 'S4', "reads the season convar through BR.Season's name for it -- ask BR.Season.current() or has()")
                end

                -- S1 / S5: every mention of the door. The module defines it.
                if not isModule then
                    local from = 1
                    while true do
                        local s, e = l:find('BR%.Season%.has%f[^%w_]', from)
                        if not s then break end
                        local rest = l:sub(e + 1)
                        local _, id = rest:match('^%s*%(%s*([\'"])([^\'"]*)%1%s*%)')
                        if id then
                            nAsks = nAsks + 1
                            asked[id] = true
                            -- With no registry S3 has already failed; one
                            -- finding per id would only bury it.
                            if reg and not rows[id] then
                                fail(f.path, i, 'S1', ("BR.Season.has('%s'): no such row in %s -- off in every season"):format(id, REGISTRY))
                            end
                        elseif rest:match('^%s*%(') then
                            fail(f.path, i, 'S1', 'BR.Season.has takes its id as a string literal, so this gate can see it')
                        elseif not (rest:match('^%s*[~=]=%s*nil%f[^%w_]') or rest:match('^%s+and%f[^%w_]')
                                    or rest:match('^%s+then%f[^%w_]')) then
                            fail(f.path, i, 'S5', 'BR.Season.has used as a value -- call it with a literal id where the answer is needed')
                        end
                        from = e + 1
                    end
                    -- A definition anywhere but the module is a second door.
                    if code[i]:find('function%s+BR%.Season%.has%f[^%w_]') or code[i]:find('BR%.Season%.has%s*=[^=]') then
                        fail(f.path, i, 'S5', 'a second BR.Season.has -- the door is ' .. MODULE .. "'s")
                    end
                    -- S6: the season in force moves only through brseason.
                    if not endsWith(f.path, SWITCHER) and code[i]:find('BR%.Season%.switch%f[^%w_]') then
                        fail(f.path, i, 'S6', 'names BR.Season.switch -- only ' .. SWITCHER
                            .. ' (the dev-mode brseason) moves the season in force; prod is restart-only')
                    end
                end
            end
        end
    end

    -- ── S2: every row is asked about ───────────────────────────────────────
    local ids = {}
    for id in pairs(rows) do ids[#ids + 1] = tostring(id) end
    table.sort(ids)
    for _, id in ipairs(ids) do
        if not asked[id] then
            fail(reg and reg.path or REGISTRY, 0, 'S2', ("row %s: nothing asks BR.Season.has('%s') -- a gate that gates nothing"):format(id, id))
        end
    end

    return out, { rows = nRows, asks = nAsks, latest = latest }
end

-- ---------------------------------------------------------------------------
-- Self-test
-- ---------------------------------------------------------------------------

local R = 'resources/[fivem-royale]/'

--- A minimal tree that satisfies every rule. Each fixture below breaks it one
--- way and names the rule that must fire.
local function goodTree()
    return {
        [R .. REGISTRY] = table.concat({
            '-- emotes = { from = 9 } in a comment is prose',
            'BR = BR or {}',
            'BR.Config = BR.Config or {}',
            'BR.Config.Seasons = {',
            '    latest = 3,',
            '    features = {',
            '        emotes = { from = 2 },',
            '        oldmap = { from = 1, untilSeason = 3 },',
            '    },',
            '}',
        }, '\n'),
        [R .. MODULE] = table.concat({
            "BR.Season.CONVAR = 'br_season'",
            'function BR.Season.has(id)',
            "    local raw = GetConvar('br_season', '')",
            'end',
        }, '\n'),
        [R .. 'br_core/server/season.lua'] = table.concat({
            '-- BR.Season.switch(n) in a comment is prose here too',
            'local now = BR.Season.switch(target)',
        }, '\n'),
        [R .. 'br_core/server/emotes.lua'] = table.concat({
            "-- GetConvar('br_season') and BR.Season.has(x) in a comment are prose",
            '-- and so is BR.Season.switch(1)',
            "if not BR.Season.has('emotes') then return end",
            "local on = BR.Season ~= nil and BR.Season.has ~= nil and BR.Season.has(\"emotes\")",
            "if not (BR.Season and BR.Season.has and BR.Season.has( 'oldmap' )) then return end",
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

local REG, MOD, SRV = R .. REGISTRY, R .. MODULE, R .. 'br_core/server/emotes.lua'

local FIXTURES = {
    { name = 'the good tree passes', want = nil },
    { name = 'a typo\'d id', want = 'S1',
      mut = function(t) return edit(t, SRV, "has('emotes') then", "has('emote') then") end },
    { name = 'an id passed as a variable', want = 'S1',
      mut = function(t) return edit(t, SRV, "has('emotes') then", 'has(id) then') end },
    { name = 'a row nothing asks', want = 'S2',
      mut = function(t) return edit(t, REG, '    },\n}', "        unused = { from = 1 },\n    },\n}") end },
    { name = 'from past latest', want = 'S3',
      mut = function(t) return edit(t, REG, 'emotes = { from = 2 }', 'emotes = { from = 4 }') end },
    { name = 'untilSeason at its from', want = 'S3',
      mut = function(t) return edit(t, REG, 'untilSeason = 3', 'untilSeason = 1') end },
    { name = 'a float from', want = 'S3',
      mut = function(t) return edit(t, REG, 'emotes = { from = 2 }', 'emotes = { from = 2.0 }') end },
    { name = 'a misspelled key', want = 'S3',
      mut = function(t) return edit(t, REG, 'untilSeason = 3', 'unitlSeason = 3') end },
    { name = 'latest zero', want = 'S3',
      mut = function(t) return edit(t, REG, 'latest = 3', 'latest = 0') end },
    { name = 'a registry that raises', want = 'S3',
      mut = function(t) return edit(t, REG, 'BR.Config.Seasons = {', 'error("boom")\nBR.Config.Seasons = {') end },
    { name = 'the registry not passed', want = 'S3',
      mut = function(t) t[REG] = nil return t end },
    { name = 'a second reader of br_season', want = 'S4',
      mut = function(t) return edit(t, SRV, "if not BR.Season.has('emotes') then return end",
          "if GetConvar('br_season', '') == '1' then return end\nif not BR.Season.has('emotes') then return end") end },
    { name = 'a reader of the served name', want = 'S4',
      mut = function(t) return edit(t, SRV, "if not BR.Season.has('emotes') then return end",
          "local n = GetConvarInt('br_seasonServed', 1)\nif not BR.Season.has('emotes') then return end") end },
    { name = 'a reader through the module\'s constant', want = 'S4',
      mut = function(t) return edit(t, SRV, "if not BR.Season.has('emotes') then return end",
          "local raw = GetConvar(BR.Season.CONVAR, '')\nif not BR.Season.has('emotes') then return end") end },
    { name = 'the door aliased', want = 'S5',
      mut = function(t) return edit(t, SRV, "if not BR.Season.has('emotes') then return end",
          "local has = BR.Season.has\nif not BR.Season.has('emotes') then return end") end },
    { name = 'a second door defined', want = 'S5',
      mut = function(t) return edit(t, SRV, "if not BR.Season.has('emotes') then return end",
          "function BR.Season.has() return true end\nif not BR.Season.has('emotes') then return end") end },
    { name = 'a switch outside brseason', want = 'S6',
      mut = function(t) return edit(t, SRV, "if not BR.Season.has('emotes') then return end",
          "BR.Season.switch(1)\nif not BR.Season.has('emotes') then return end") end },
    { name = 'the switch aliased outside brseason', want = 'S6',
      mut = function(t) return edit(t, SRV, "if not BR.Season.has('emotes') then return end",
          "local sw = BR.Season.switch\nif not BR.Season.has('emotes') then return end") end },
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
        io.write(('ok   %d selftest fixtures: S1-S6 each fire on a broken tree, and a good one passes\n')
            :format(#FIXTURES))
    end
    return bad
end

-- ---------------------------------------------------------------------------
-- Entry
-- ---------------------------------------------------------------------------

local args = { ... }
if #args == 0 then
    io.write('usage: lua tools/check_seasons.lua <file.lua>...\n')
    io.write('       lua tools/check_seasons.lua --selftest\n')
    os.exit(2)
end
if args[1] == '--selftest' then os.exit(selftest() > 0 and 1 or 0) end

local files = {}
for _, path in ipairs(args) do
    local fh = io.open(path, 'rb')
    if fh then
        files[#files + 1] = { path = path, src = fh:read('a') }
        fh:close()
    end
end
local findings, sum = run(files)
if #findings > 0 then
    for _, f in ipairs(findings) do
        io.write(('FAIL %s:%d: %s %s\n'):format(f.path, f.line, f.rule, f.why))
    end
    os.exit(1)
end
io.write(('ok   %d gated feature(s), latest Season %d, %d BR.Season.has call(s), each a listed id; only %s reads br_season, and only %s switches it\n')
    :format(sum.rows, sum.latest or 0, sum.asks, MODULE, SWITCHER))
