-- Static gate: a local function called before it is declared.
--
-- WHY THIS EXISTS. In Lua, `local function f` only binds `f` from that line
-- onward. Code ABOVE it that says `f(...)` compiles fine -- it resolves as a
-- GLOBAL lookup, which is nil at runtime. There is no syntax error, luac -p is
-- happy, and the unit tests never see it because they exercise the server and
-- these are client files full of stubbed natives.
--
-- What it looks like in the game: the call throws, the loop registry suspends
-- that callback after five consecutive errors, and an entire subsystem goes
-- quiet with one line in the console. It has now cost two playtest rounds --
-- BR.Loot's ground probe (solidGround) took every crate on the map with it.
--
-- The fix in code is either to move the declaration up or to forward-declare
-- (`local f` ... `f = function() end`), and the second form is deliberately
-- NOT flagged here: `local f` at the top IS the declaration, so the binding
-- exists by the time anything calls it.
--
-- Run standalone:  lua tools/check_forward_locals.lua <file>...

local failures = 0
local scanned  = 0

--- Strip strings and comments so their contents cannot look like code.
--- Crude on purpose: replacing them with same-length blanks keeps every line
--- number and column intact, which is what the report needs.
local function blank(line)
    line = line:gsub('%-%-.*$', '')          -- line comments
    line = line:gsub('"[^"]*"', function(s) return string.rep(' ', #s) end)
    line = line:gsub("'[^']*'", function(s) return string.rep(' ', #s) end)
    return line
end

--- @param path string
local function check(path)
    local fh = io.open(path, 'r')
    if not fh then return end
    scanned = scanned + 1

    local lines = {}
    for line in fh:lines() do lines[#lines + 1] = line end
    fh:close()

    -- Where each `local function NAME` is declared.
    local declaredAt = {}
    local order = {}
    for i, raw in ipairs(lines) do
        local name = blank(raw):match('^%s*local%s+function%s+([%w_]+)%s*%(')
        if name and not declaredAt[name] then
            declaredAt[name] = i
            order[#order + 1] = name
        end
    end

    -- Long strings ([[ ]]) would need a real lexer; there are none in this
    -- project's Lua and a false positive here is cheap to spot, so this
    -- deliberately stays a line scanner.
    for _, name in ipairs(order) do
        local declLine = declaredAt[name]
        for i = 1, declLine - 1 do
            local code = blank(lines[i])
            -- A CALL, not a mention: `name(`. Skips comments, table keys and
            -- the string forms above.
            local before = code:match('()' .. name .. '%s*%(')
            if before then
                -- `foo.name(` and `foo:name(` are a different function.
                local prefix = code:sub(math.max(1, before - 1), before - 1)
                if prefix ~= '.' and prefix ~= ':' then
                    failures = failures + 1
                    io.write(('\27[31mFAIL\27[0m %s:%d: calls "%s" before its'
                        .. ' `local function` on line %d\n')
                        :format(path, i, name, declLine))
                end
            end
        end
    end
end

local args = { ... }
if #args == 0 then
    io.write('usage: lua tools/check_forward_locals.lua <file>...\n')
    os.exit(2)
end
for _, path in ipairs(args) do check(path) end

if failures > 0 then
    io.write(('\27[31m%d forward-local call(s)\27[0m in %d file(s)\n')
        :format(failures, scanned))
    os.exit(1)
end
io.write(('\27[32mok\27[0m   %d files, no local called before its declaration\n')
    :format(scanned))
