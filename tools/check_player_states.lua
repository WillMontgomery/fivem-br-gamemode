-- Static gate: a reference to a BR.PlayerState member that does not exist.
--
-- WHY THIS EXISTS. `BR.PlayerState` is a plain table, so `BR.PlayerState.DEAD`
-- after DEAD has been renamed is not an error -- it is `nil`, and nil is a
-- perfectly good Lua value. What it does next depends on where it landed, and
-- all three outcomes are bad in different ways:
--
--   * IN A COMPARISON it is silently always-false. `st == BR.PlayerState.DEAD`
--     stops matching anybody, the rule never fires, and nothing says so.
--   * IN A TABLE CONSTRUCTOR as a key it throws "table index is nil" at load
--     time -- the loud case, and the only one that announces itself.
--   * IN AN ipairs LIST it TRUNCATES THE LIST. `ipairs` stops at the first nil
--     rather than skipping it, so `{ ALIVE, LOBBY, SPECTATING, DEAD }` with two
--     stale names becomes a two-element loop that still passes every assertion
--     it does run. A suite that tested four states now tests two and stays
--     green. That is a measured behaviour, not a hypothetical: it is exactly
--     what tools/test_shop.lua did during #233.
--
-- The first and third are the dangerous ones, because a half-finished rename
-- leaves a suite passing while it quietly stops asserting. #233 renamed DEAD to
-- OUT and deleted SPECTATING across ~30 files; the full suite passed with a
-- site still on the old name, which is what this gate is for.
--
-- IT IS DELIBERATELY A NAME CHECK AND NOT A BEHAVIOUR TEST. One behavioural
-- test guards one site. This guards every site in the tree, including the ones
-- nobody has written a test for and the ones added next year.
--
-- ═══ SCOPE: resources/ TODAY, AND tools/ IS ONE WORD AWAY ═══
--
-- verify.sh runs this over `resources` only, which is the same scope
-- check_forward_locals.lua uses. It is NOT because the suites do not need it --
-- they need it most, since the ipairs truncation above happened in one -- but
-- because pointing it at tools/ today fails on a defect this change did not
-- introduce and may not fix: tools/test_lobbyseq.lua sets
-- `BR.State.me.state = BR.PlayerState.PLAYING` in five places, and PLAYING is a
-- MATCH state, not a player state. Those five lines assign nil and have never
-- tested the thing they read as testing.
--
-- That file belonged to another agent when this landed, so it was reported
-- rather than edited. WHEN IT IS FIXED, ADD `tools` TO THE find IN verify.sh --
-- this checker already handles the suites' local-alias form, and passing them
-- is the only thing standing between here and full coverage.
--
-- Run standalone:  lua tools/check_player_states.lua <file>...

local ROOT = (arg and arg[0] or ''):gsub('tools[/\\]check_player_states%.lua$', '')
if ROOT == '' then ROOT = './' end

local ENUM = ROOT .. 'resources/[fivem-royale]/br_lib/shared/enums.lua'

--- Strip strings and comments so their contents cannot look like code.
--- Same trick as check_forward_locals.lua: blank them in place so line numbers
--- and columns survive for the report.
local function blank(line)
    line = line:gsub('%-%-.*$', '')
    line = line:gsub('"[^"]*"', function(s) return string.rep(' ', #s) end)
    line = line:gsub("'[^']*'", function(s) return string.rep(' ', #s) end)
    return line
end

-- ═══ THE ENUM ITSELF, READ RATHER THAN RESTATED ═══
--
-- Parsed out of the source instead of being listed here, because a copy in this
-- file would be one more place a rename has to reach -- and the failure mode of
-- forgetting it is this gate going green on a name that no longer exists, which
-- is the exact defect it is meant to catch.
local members, order = {}, {}
do
    local fh = io.open(ENUM, 'r')
    if not fh then
        io.write(('\27[31mcannot open %s\27[0m\n'):format(ENUM))
        os.exit(2)
    end
    local src = fh:read('a')
    fh:close()

    local body = src:match('BR%.PlayerState%s*=%s*{(.-)\n}')
    if not body then
        io.write('\27[31mcould not find the BR.PlayerState table in enums.lua\27[0m\n')
        os.exit(2)
    end
    for line in body:gmatch('[^\n]+') do
        local name = blank(line):match('^%s*([A-Z][A-Z0-9_]*)%s*=')
        if name and not members[name] then
            members[name] = true
            order[#order + 1] = name
        end
    end
end

if #order == 0 then
    io.write('\27[31mparsed the PlayerState table and found no members\27[0m\n')
    os.exit(2)
end

-- ═══ EVERY REFERENCE IN THE TREE ═══
--
-- `PlayerState.NAME` rather than `BR.PlayerState.NAME`, because the test
-- harnesses reach it through half a dozen prefixes -- C.env.BR., W.BR., D.env.BR.,
-- cenv.BR., a bare `B.` -- and the suffix is the part that is always the same.
local bad, scanned, refs = {}, 0, 0

local function check(path)
    local fh = io.open(path, 'r')
    if not fh then return end
    scanned = scanned + 1
    local n = 0
    for raw in fh:lines() do
        n = n + 1
        local line = blank(raw)
        for name in line:gmatch('PlayerState%.([A-Za-z_][A-Za-z0-9_]*)') do
            refs = refs + 1
            if not members[name] then
                bad[#bad + 1] = { path = path, line = n, name = name,
                                  text = raw:gsub('^%s+', '') }
            end
        end
    end
    fh:close()
end

-- ═══ THE LOCAL-ALIAS FORM, WHICH IS HOW #233 NEARLY GOT AWAY WITH IT ═══
--
-- The suites bind `local PS = env.BR.PlayerState` and then write `PS.DEAD`,
-- which the pattern above cannot see. Those aliases are found per file and
-- their members checked the same way. Any single-capital-ish local bound
-- directly to a PlayerState table counts.
local function checkAliases(path)
    local fh = io.open(path, 'r')
    if not fh then return end
    local src = fh:read('a')
    fh:close()

    local aliases = {}
    for a in src:gmatch('local%s+([A-Za-z_][A-Za-z0-9_]*)%s*=%s*[%w_%.]-PlayerState%s*\n?') do
        aliases[a] = true
    end
    if not next(aliases) then return end

    local n = 0
    for raw in src:gmatch('[^\n]*') do
        n = n + 1
        local line = blank(raw)
        for a in pairs(aliases) do
            for name in line:gmatch('%f[%w_]' .. a .. '%.([A-Z][A-Z0-9_]*)') do
                -- Only names that LOOK like enum members, so an alias that also
                -- carries unrelated fields does not produce noise.
                if not members[name] and name:match('^[A-Z][A-Z0-9_]*$') then
                    refs = refs + 1
                    bad[#bad + 1] = { path = path, line = n, name = a .. '.' .. name,
                                      text = raw:gsub('^%s+', '') }
                end
            end
        end
    end
end

local args = { ... }
if #args == 0 then
    io.write('usage: lua tools/check_player_states.lua <file>...\n')
    os.exit(2)
end
for _, path in ipairs(args) do
    check(path)
    checkAliases(path)
end

if #bad > 0 then
    for _, b in ipairs(bad) do
        io.write(('\27[31m%s:%d\27[0m  PlayerState.%s does not exist\n')
            :format(b.path, b.line, b.name))
        io.write(('       %s\n'):format(b.text))
    end
    io.write(('\27[31m%d reference(s) to a PlayerState member that is not in the enum\27[0m\n')
        :format(#bad))
    io.write(('       the enum has: %s\n'):format(table.concat(order, ', ')))
    os.exit(1)
end

io.write(('\27[32mok\27[0m   %d PlayerState reference(s) in %d files, all %d members real\n')
    :format(refs, scanned, #order))
