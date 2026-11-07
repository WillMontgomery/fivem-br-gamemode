-- Static gate: UI v2's list, its one door and its kill switch (#436).
--
-- ═══ WHY THIS EXISTS ═══
--
-- Owner, 2026-11-07: "One toggle for everything (market, locker v2, HUD,
-- inventory, player list, etc), and also a separate toggle for each
-- component", switched live from the server console, on prod too, as a kill
-- switch. The whole mechanism is one list, br_lib/config/uiv2.lua, one door,
-- BR.UIv2.has(id), one module that reads the switches, and one console
-- command. Each half fails QUIETLY when it rots, the way the season's did
-- (tools/check_seasons.lua), so the same rules hold it by construction:
--
--   * A TYPO'D ID is off forever: has() fails closed on an id with no row.
--   * A ROW NOTHING ASKS is a switch that switches nothing.
--   * A ROW WITH A KEY says something has() never reads; an id with `_` or a
--     capital is a switch name that is not exactly one convar (convar names
--     ignore case, and br_uiv2_<id> must not be read two ways).
--   * A SECOND READER of a switch decides on its own copy -- unresolved, and
--     on a client, live mid-match, which is the one thing the owner ruled out.
--   * A SECOND WRITER: boot and the re-read belong to br_core's start, the
--     flip to `bruiv2`, the held answer to br_core's client.
--   * A KILL SWITCH ANY PLAYER CAN THROW. `bruiv2` is exempt from the dev gate
--     so it works on prod; its own body is the gate, and restricted alone
--     would admit an in-game group.admin.
--   * A WAY IN THAT NO RULE CAN READ: an alias, a bracket, a method call.
--
-- ═══ THE RULES ═══
--
--   U1 KNOWN IDS     every BR.UIv2.has(...) takes its id as a string literal,
--                    and the id is a row
--   U2 NO DEAD ROWS  every row is asked about somewhere in resources/
--   U3 SANE ROWS     the registry loads in bare Lua (no GetConvar: it is pure
--                    data) and builds BR.Config.UIv2.pieces; every id is
--                    lowercase letters and digits from a letter; every row is
--                    an empty table
--   U4 ONE READER    no file but br_lib/shared/uiv2.lua names br_uiv2 --
--                    br_uiv2_<piece> and br_uiv2Served have it in their names
--                    -- in code or a string, matched without case, or
--                    reaches one as BR.UIv2.CONVAR, PREFIX or SERVED
--   U5 ONE DOOR      BR.UIv2.has is only ever CALLED (or nil-checked, or
--                    tested for truth), and defined only by the module
--   U6 ONE WRITER    BR.UIv2.boot and BR.UIv2.recheck are named only by
--      EACH          br_core/server/main.lua, BR.UIv2.flip only by
--                    br_core/server/uiv2.lua, BR.UIv2.hold and BR.UIv2.adopt
--                    only by br_core/client/uiv2.lua (the module defines them)
--   U7 CONSOLE ONLY  `bruiv2` is registered exactly once, in
--                    br_core/server/uiv2.lua, restricted (`end, true)`), its
--                    handler's first statement `if tonumber(src) ~= 0 then
--                    ... return end`; and no ExecuteCommand line names it
--   U8 PLAIN NAMES   outside the module BR.UIv2 is written `BR.UIv2.<name>`,
--                    with no space or line break in it, or compared with nil,
--                    or tested for truth -- never bracket-indexed (BR['UIv2']
--                    included), called with `:`, or assigned, passed or
--                    returned bare -- so U1 and U4 to U6 read every way in
--
-- READS TEXT, NOT A PARSE TREE, with check_seasons.lua's lexer, so prose that
-- quotes a pattern is never read as code. The registry is LOADED, in a
-- sandbox with nothing but the BR table, so U3 judges what the game will see
-- and fails the day it grows a convar read. A name built at run time, or
-- reached through an alias of BR itself, never appears as text; that is
-- review's to see.
--
-- Run standalone:  lua tools/check_uiv2.lua <file.lua>...
--                  lua tools/check_uiv2.lua --selftest

local REGISTRY = 'br_lib/config/uiv2.lua'
local MODULE = 'br_lib/shared/uiv2.lua'
local BOOTER = 'br_core/server/main.lua'
local COMMAND = 'br_core/server/uiv2.lua'
local HOLDER = 'br_core/client/uiv2.lua'

-- ---------------------------------------------------------------------------
-- Reading Lua without parsing Lua (tools/check_seasons.lua's lexer)
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

--- BR.Config.UIv2 as the file builds it, or nil and why. The sandbox holds
--- the BR table and nothing else, so a convar read raises.
--- @param src string
--- @return table|nil, string|nil
local function loadRegistry(src)
    local env = { BR = { Config = {} } }
    local chunk, err = load(src, '@' .. REGISTRY, 't', env)
    if not chunk then return nil, 'does not load: ' .. tostring(err) end
    local okRun, runErr = pcall(chunk)
    if not okRun then return nil, 'raises while loading in bare Lua (it is pure data: no convar, no native): ' .. tostring(runErr) end
    local cfg = env.BR.Config and env.BR.Config.UIv2
    if type(cfg) ~= 'table' then return nil, 'builds no BR.Config.UIv2 table' end
    return cfg
end

-- ---------------------------------------------------------------------------
-- The check
-- ---------------------------------------------------------------------------

--- @param files table  { { path = string, src = string } }
--- @return table findings  { { path, line, rule, why } }
--- @return table summary  { rows = n, asks = n }
local function run(files)
    local out = {}
    local function fail(path, line, rule, why)
        out[#out + 1] = { path = path, line = line or 0, rule = rule, why = why }
    end

    -- ── U3: the registry ────────────────────────────────────────────────────
    local reg
    for _, f in ipairs(files) do
        if endsWith(f.path, REGISTRY) then reg = f end
    end
    local rows, nRows = {}, 0
    if not reg then
        fail(REGISTRY, 0, 'U3', 'not passed to the gate')
    else
        local cfg, why = loadRegistry(reg.src)
        if not cfg then
            fail(reg.path, 0, 'U3', why)
        elseif type(cfg.pieces) ~= 'table' then
            fail(reg.path, 0, 'U3', 'builds no BR.Config.UIv2.pieces table')
        else
            for id, row in pairs(cfg.pieces) do
                nRows = nRows + 1
                rows[id] = true
                local name = tostring(id)
                if type(id) ~= 'string' or not id:match('^[a-z][a-z0-9]*$') then
                    fail(reg.path, 0, 'U3', ('row %s: an id is lowercase letters and digits, from a letter -- br_uiv2_<id> must name exactly one convar, and convar names ignore case'):format(name))
                end
                if type(row) ~= 'table' then
                    fail(reg.path, 0, 'U3', ('row %s is not a table'):format(name))
                else
                    for k in pairs(row) do
                        fail(reg.path, 0, 'U3', ('row %s: key %s -- a row is an empty table, and has() would ignore it')
                            :format(name, tostring(k)))
                    end
                end
            end
        end
    end

    -- ── U1 / U4 / U5 / U6 / U7: every file ──────────────────────────────────
    local asked = {}
    local nAsks = 0
    local registrations = {}
    for _, f in ipairs(files) do
        if endsWith(f.path, '.lua') then
            local isModule = endsWith(f.path, MODULE)
            local code, names = views(f.src)
            for i = 1, #names do
                local l = names[i]

                -- U4: nobody else names a switch, in code or in a string, in
                -- any case.
                if not isModule and l:lower():find('br_uiv2', 1, true) then
                    fail(f.path, i, 'U4', 'names br_uiv2 -- only ' .. MODULE .. ' reads the UI v2 switches; ask BR.UIv2.has()')
                end
                if not isModule and (code[i]:find('BR%.UIv2%.CONVAR%f[^%w_]') or code[i]:find('BR%.UIv2%.PREFIX%f[^%w_]')
                                     or code[i]:find('BR%.UIv2%.SERVED%f[^%w_]')) then
                    fail(f.path, i, 'U4', "reads a UI v2 convar through BR.UIv2's name for it -- ask BR.UIv2.has()")
                end

                if not isModule then
                    -- U1 / U5: every mention of the door. Found in `code`, so a
                    -- has() written inside a string is prose and asks nothing
                    -- (U2 cannot be satisfied by a print), and read in `names`
                    -- at the same column, where the id's literal is kept.
                    local from = 1
                    while true do
                        local s, e = code[i]:find('BR%.UIv2%.has%f[^%w_]', from)
                        if not s then break end
                        local rest = l:sub(e + 1)
                        local _, id = rest:match('^%s*%(%s*([\'"])([^\'"]*)%1%s*%)')
                        if id then
                            nAsks = nAsks + 1
                            asked[id] = true
                            if reg and not rows[id] then
                                fail(f.path, i, 'U1', ("BR.UIv2.has('%s'): no such row in %s -- off for good"):format(id, REGISTRY))
                            end
                        elseif rest:match('^%s*%(') then
                            fail(f.path, i, 'U1', 'BR.UIv2.has takes its id as a string literal, so this gate can see it')
                        elseif not (rest:match('^%s*[~=]=%s*nil%f[^%w_]') or rest:match('^%s+and%f[^%w_]')
                                    or rest:match('^%s+then%f[^%w_]')) then
                            fail(f.path, i, 'U5', 'BR.UIv2.has used as a value -- call it with a literal id where the answer is needed')
                        end
                        from = e + 1
                    end
                    if code[i]:find('function%s+BR%.UIv2%.has%f[^%w_]') or code[i]:find('BR%.UIv2%.has%s*=[^=]') then
                        fail(f.path, i, 'U5', 'a second BR.UIv2.has -- the door is ' .. MODULE .. "'s")
                    end

                    -- U6: one writer each.
                    for _, w in ipairs({ { 'boot', BOOTER }, { 'recheck', BOOTER }, { 'flip', COMMAND },
                                         { 'hold', HOLDER }, { 'adopt', HOLDER } }) do
                        if not endsWith(f.path, w[2]) and code[i]:find('BR%.UIv2%.' .. w[1] .. '%f[^%w_]') then
                            fail(f.path, i, 'U6', ('names BR.UIv2.%s -- only %s may'):format(w[1], w[2]))
                        end
                    end
                end

                -- U7: every registration of `bruiv2`, spelled in any case, so
                -- no second spelling of the kill switch slips past (devgate's
                -- exemption reads the name exactly), and nothing that types it.
                if l:find('RegisterCommand%s*%(%s*([\'"])[bB][rR][uU][iI][vV]2%1')
                   or l:find('rawCommand%s*%(%s*([\'"])[bB][rR][uU][iI][vV]2%1') then
                    registrations[#registrations + 1] = { path = f.path, line = i, code = code, names = names }
                end
                if l:find('ExecuteCommand', 1, true) and l:lower():find('bruiv2', 1, true) then
                    fail(f.path, i, 'U7', 'ExecuteCommand names bruiv2 -- the kill switch is typed on the server console, by a person')
                end
            end

            -- U8: every way in is spelled so the rules above can read it. The
            -- whole file at once, because a name can be split over lines.
            if not isModule then
                local text = table.concat(code, '\n')
                local function lineOf(pos)
                    local _, n = text:sub(1, pos):gsub('\n', '')
                    return n + 1
                end
                local pos = 1
                while true do
                    local s, e = text:find('%f[%w_]BR%s*%.%s*UIv2%f[^%w_]', pos)
                    if not s then break end
                    pos = e + 1
                    local why = nil
                    if text:sub(s, e) ~= 'BR.UIv2' then
                        why = 'BR.UIv2 spelled with a space or a line break in it -- write BR.UIv2, so every rule here can read it'
                    elseif text:find('^%.[%a_]', e + 1) then
                        why = nil
                    elseif text:find('^%s*%.', e + 1) or text:find('^%.%s', e + 1) then
                        why = 'BR.UIv2 . <name> with a space or a line break -- write BR.UIv2.<name>, so every rule here can read it'
                    elseif text:find('^%s*%[', e + 1) then
                        why = 'BR.UIv2 bracket-indexed -- a name in a string or a variable is one no rule here can read'
                    elseif text:find('^%s*:', e + 1) then
                        why = 'BR.UIv2 called with `:` -- write BR.UIv2.<name>(...), so every rule here can read it'
                    elseif text:find('^%s*[~=]=%s*nil%f[^%w_]', e + 1) or text:find('^%s*and%f[^%w_]', e + 1)
                           or text:find('^%s*then%f[^%w_]', e + 1)
                           or text:sub(math.max(1, s - 16), s - 1):find('%f[%w_]not%s*$') then
                        why = nil
                    else
                        why = 'BR.UIv2 used bare -- assigned, passed or returned, it reaches every door and write under a name no rule here can read'
                    end
                    if why then fail(f.path, lineOf(s), 'U8', why) end
                end
                local named = table.concat(names, '\n')
                pos = 1
                while true do
                    local s, e = text:find('%f[%w_]BR%s*%[', pos)
                    if not s then break end
                    pos = e + 1
                    if named:find('^BR%s*%[%s*([\'"])UIv2%1%s*%]', s) then
                        fail(f.path, lineOf(s), 'U8', "BR['UIv2'] -- write BR.UIv2.<name>, so every rule here can read it")
                    end
                end
            end
        end
    end

    -- ── U7: exactly one registration, the console's ─────────────────────────
    if #registrations == 0 then
        fail(COMMAND, 0, 'U7', 'bruiv2 is registered nowhere -- the kill switch is ' .. COMMAND .. "'s")
    end
    if #registrations > 1 then
        for _, r in ipairs(registrations) do
            fail(r.path, r.line, 'U7', ('bruiv2 registered %d times -- once, in %s'):format(#registrations, COMMAND))
        end
    end
    for _, r in ipairs(registrations) do
        if not endsWith(r.path, COMMAND) then
            fail(r.path, r.line, 'U7', 'bruiv2 registered outside ' .. COMMAND)
        else
            local code = r.code
            local head = code[r.line]
            if not head:match('^RegisterCommand%s*%(') or not r.names[r.line]:find('function%s*%(%s*src%s*[,%)]') then
                fail(r.path, r.line, 'U7', 'bruiv2 is registered at the top of the file, its handler written in place as function(src, ...)')
            else
                -- The handler's first statement is the refusal.
                local j = r.line + 1
                while j <= #code and code[j]:match('^%s*$') do j = j + 1 end
                if not (code[j] or ''):match('^%s*if%s+tonumber%s*%(%s*src%s*%)%s*~=%s*0%s+then%s.-%f[%w]return%s+end%s*$') then
                    fail(r.path, j, 'U7', "bruiv2's handler must begin `if tonumber(src) ~= 0 then ... return end` -- the console only (0 is truthy in Lua)")
                end
                -- Its end: the first line at the top level that closes it.
                local k = r.line + 1
                while k <= #code and not code[k]:match('^end%f[^%w_]') do k = k + 1 end
                if not (code[k] or ''):match('^end%s*,%s*true%s*%)%s*$') then
                    fail(r.path, k, 'U7', 'bruiv2 must be registered restricted: its RegisterCommand ends `end, true)`')
                end
            end
        end
    end

    -- ── U2: every row is asked about ───────────────────────────────────────
    local ids = {}
    for id in pairs(rows) do ids[#ids + 1] = tostring(id) end
    table.sort(ids)
    for _, id in ipairs(ids) do
        if not asked[id] then
            fail(reg and reg.path or REGISTRY, 0, 'U2', ("row %s: nothing asks BR.UIv2.has('%s') -- a switch that switches nothing"):format(id, id))
        end
    end

    return out, { rows = nRows, asks = nAsks }
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
            '-- market = { from = 9 } in a comment is prose',
            'BR = BR or {}',
            'BR.Config = BR.Config or {}',
            'BR.Config.UIv2 = {',
            '    pieces = {',
            '        market = {},',
            '        locker = {},',
            '        hud2 = {},',
            '    },',
            '}',
        }, '\n'),
        [R .. MODULE] = table.concat({
            'BR.UIv2 = BR.UIv2 or {}',
            "BR.UIv2.CONVAR = 'br_uiv2'",
            "BR.UIv2.SERVED = 'br_uiv2Served'",
            "local raw = GetConvar('BR_UIV2_MARKET', '')",
            'function BR.UIv2.has(id) return false end',
            'function BR.UIv2.boot() local U = BR.UIv2 return U end',
        }, '\n'),
        [R .. BOOTER] = table.concat({
            'local uiv2Lines = BR.UIv2.boot()',
            'local moved = BR.UIv2.recheck()',
        }, '\n'),
        [R .. COMMAND] = table.concat({
            "-- RegisterCommand('bruiv2', fn, false) in a comment is prose",
            "RegisterCommand('bruiv2', function(src, args)",
            "    if tonumber(src) ~= 0 then print('  bruiv2 is server-console only') return end",
            "    local lines = BR.UIv2.flip(nil, 'on')",
            '    if lines then',
            '        for _, l in ipairs(lines) do print(l) end',
            '    end',
            'end, true)',
        }, '\n'),
        [R .. HOLDER] = table.concat({
            'BR.UIv2.hold(function() return true end)',
            'BR.UIv2.adopt(false)',
        }, '\n'),
        [R .. 'br_ui/client/market.lua'] = table.concat({
            "-- GetConvar('br_uiv2') and BR.UIv2.has(x) in a comment are prose",
            "-- and so are BR.UIv2.flip('market', 'off'), BR.UIv2.boot(), local U = BR.UIv2",
            "if not BR.UIv2.has('market') then return end",
            "local on = BR.UIv2 ~= nil and BR.UIv2.has ~= nil and BR.UIv2.has(\"locker\") == true",
            'if BR.UIv2 and BR.UIv2.onChange then BR.UIv2.onChange(push) end',
            "if not (BR.UIv2 and BR.UIv2.has and BR.UIv2.has( 'hud2' )) then return end",
            'if not BR.UIv2 or not BR.UIv2.known() then return end',
            "print('[br_ui] bruiv2 market on, on the server console')",
            "print('BR.UIv2[1] and BR[\"UIv2\"] in a string are prose')",
            "print('BR.UIv2.has(id) and BR.UIv2.has(\"nope\") in a string are prose too')",
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

local REG, CMD, DOOR = R .. REGISTRY, R .. COMMAND, R .. 'br_ui/client/market.lua'
local ASK = "if not BR.UIv2.has('market') then return end"

--- One line added ahead of the door's first ask.
local function before(line)
    return function(t) return edit(t, DOOR, ASK, line .. '\n' .. ASK) end
end

local FIXTURES = {
    { name = 'the good tree passes', want = nil },
    { name = "a typo'd id", want = 'U1',
      mut = function(t) return edit(t, DOOR, "has('market') then", "has('markt') then") end },
    { name = 'an id passed as a variable', want = 'U1',
      mut = function(t) return edit(t, DOOR, "has('market') then", 'has(id) then') end },
    { name = 'a row nothing asks', want = 'U2',
      mut = function(t) return edit(t, REG, '    },\n}', '        unused = {},\n    },\n}') end },
    { name = 'a row asked only inside a string', want = 'U2',
      mut = function(t)
          edit(t, REG, '    },\n}', '        unused = {},\n    },\n}')
          return before("print(\"ask BR.UIv2.has('unused') to see\")")(t)
      end },
    { name = 'an id with an underscore', want = 'U3',
      mut = function(t) return edit(t, REG, 'hud2 = {},', "hud2 = {},\n        ['hud_two'] = {},") end },
    { name = 'an id with a capital', want = 'U3',
      mut = function(t) return edit(t, REG, 'hud2 = {},', 'hud2 = {},\n        Hud = {},') end },
    { name = 'a row with a key', want = 'U3',
      mut = function(t) return edit(t, REG, 'market = {},', 'market = { from = 2 },') end },
    { name = 'a row that is not a table', want = 'U3',
      mut = function(t) return edit(t, REG, 'market = {},', 'market = true,') end },
    { name = 'a registry calling GetConvar', want = 'U3',
      mut = function(t) return edit(t, REG, 'BR.Config.UIv2 = {', "local on = GetConvar('x', '')\nBR.Config.UIv2 = {") end },
    { name = 'a registry with no pieces table', want = 'U3',
      mut = function(t) return edit(t, REG, '    pieces = {', '    rows = {') end },
    { name = 'the registry not passed', want = 'U3',
      mut = function(t) t[REG] = nil return t end },
    { name = 'a second reader of a piece switch', want = 'U4', mut = before("local raw = GetConvar('br_uiv2_market', '')") },
    { name = 'the same in capitals', want = 'U4', mut = before("local raw = GetConvar('BR_UIV2_MARKET', '')") },
    { name = 'a reader of the whole switch', want = 'U4', mut = before("local raw = GetConvar('br_uiv2', '')") },
    { name = 'a reader of the served name', want = 'U4', mut = before("local raw = GetConvar('br_uiv2Served', '')") },
    { name = 'a reader through BR.UIv2.SERVED', want = 'U4', mut = before("local raw = GetConvar(BR.UIv2.SERVED, '')") },
    { name = 'a reader through BR.UIv2.PREFIX', want = 'U4', mut = before("local raw = GetConvar(BR.UIv2.PREFIX .. 'market', '')") },
    { name = 'the door aliased', want = 'U5', mut = before('local has = BR.UIv2.has') },
    { name = 'the door passed along', want = 'U5', mut = before('follow(BR.UIv2.has)') },
    { name = 'a second door defined', want = 'U5', mut = before('function BR.UIv2.has() return true end') },
    { name = 'a boot outside main.lua', want = 'U6', mut = before('BR.UIv2.boot()') },
    { name = 'a recheck outside main.lua', want = 'U6', mut = before('BR.UIv2.recheck()') },
    { name = 'a flip outside the command file', want = 'U6', mut = before("BR.UIv2.flip('market', 'off')") },
    { name = 'the flip aliased outside the command file', want = 'U6', mut = before('local f = BR.UIv2.flip') },
    { name = 'a hold outside client/uiv2.lua', want = 'U6', mut = before('BR.UIv2.hold(function() return true end)') },
    { name = 'an adopt outside client/uiv2.lua', want = 'U6', mut = before('BR.UIv2.adopt(true)') },
    { name = 'bruiv2 registered unrestricted', want = 'U7',
      mut = function(t) return edit(t, CMD, 'end, true)', 'end, false)') end },
    { name = 'bruiv2 registered with no restricted flag', want = 'U7',
      mut = function(t) return edit(t, CMD, 'end, true)', 'end)') end },
    { name = 'bruiv2 without the refusal', want = 'U7',
      mut = function(t) return edit(t, CMD, "    if tonumber(src) ~= 0 then print('  bruiv2 is server-console only') return end\n", '') end },
    { name = 'the refusal not the first statement', want = 'U7',
      mut = function(t) return edit(t, CMD, "    if tonumber(src) ~= 0 then", "    local n = 1\n    if tonumber(src) ~= 0 then") end },
    { name = 'the refusal as a truth test', want = 'U7',
      mut = function(t) return edit(t, CMD, 'if tonumber(src) ~= 0 then', 'if src then') end },
    { name = 'bruiv2 registered in a second file', want = 'U7',
      mut = before("RegisterCommand('bruiv2', function(src) if tonumber(src) ~= 0 then return end end, true)") },
    { name = 'bruiv2 registered again, spelled in another case', want = 'U7',
      mut = before("RegisterCommand('BrUiV2', function(src, args) end, false)") },
    { name = 'bruiv2 registered through the raw door', want = 'U7',
      mut = before("BR.Dev.rawCommand('bruiv2', function(src) end, true)") },
    { name = 'bruiv2 registered nowhere', want = 'U7',
      mut = function(t) return edit(t, CMD, "RegisterCommand('bruiv2', function(src, args)",
          "RegisterCommand('bruiv3', function(src, args)") end },
    { name = 'bruiv2 reached by ExecuteCommand', want = 'U7', mut = before("ExecuteCommand('bruiv2 off')") },
}

-- U8: every spelling of a way in that U1 and U4 to U6 cannot read, each one
-- line added to an otherwise good file.
for _, fx in ipairs({
    { 'BR.UIv2 aliased', "local U = BR.UIv2; U.flip('market', 'off')" },
    { 'the door bracket-indexed', "BR.UIv2['has']('market')" },
    { 'the flip bracket-indexed, spaced', "BR.UIv2 [ \"flip\" ]('market', 'off')" },
    { 'a convar name bracket-indexed', "GetConvar(BR.UIv2['SERVED'],'')" },
    { 'a name built by concatenation, in a bracket', "BR.UIv2['fl' .. 'ip']('market', 'off')" },
    { 'a bracket after not', "local _ = not BR.UIv2['has']('market')" },
    { 'a method call', "BR.UIv2:flip('market', 'off')" },
    { 'a method call after not', "local _ = not BR.UIv2:has('market')" },
    { 'the name split over lines', "BR.UIv2\n    .flip('market', 'off')" },
    { 'a space in the spelling', "BR . UIv2.flip('market', 'off')" },
    { 'a space before the name', "BR.UIv2. flip('market', 'off')" },
    { 'a space before the dot, after not', "local _ = not BR.UIv2 .has('market')" },
    { 'BR bracket-indexed', "BR['UIv2'].flip('market', 'off')" },
    { 'passed bare', 'follow(BR.UIv2)' },
    { 'returned bare', 'return BR.UIv2' },
    { 'kept with or', 'local U = BR.UIv2 or {}' },
    { 'kept in a table', 'local t = { ui = BR.UIv2 }' },
}) do
    FIXTURES[#FIXTURES + 1] = { name = fx[1], want = 'U8', mut = before(fx[2]) }
end

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
        io.write(('ok   %d selftest fixtures: U1-U8 each fire on a broken tree, and a good one passes\n')
            :format(#FIXTURES))
    end
    return bad
end

-- ---------------------------------------------------------------------------
-- Entry
-- ---------------------------------------------------------------------------

local args = { ... }
if #args == 0 then
    io.write('usage: lua tools/check_uiv2.lua <file.lua>...\n')
    io.write('       lua tools/check_uiv2.lua --selftest\n')
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
io.write(('ok   %d UI v2 piece(s), %d BR.UIv2.has call(s), each a listed id; only %s reads the switches, only %s boots it, only %s flips it (bruiv2, server-console only), only %s holds it, and every BR.UIv2 is spelled plainly\n')
    :format(sum.rows, sum.asks, MODULE, BOOTER, COMMAND, HOLDER))
