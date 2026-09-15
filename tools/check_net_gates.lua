-- Static gate: a NET EVENT that treats dev mode as a permission.
--
-- ═══ WHY THIS EXISTS ═══
--
-- br_lib/shared/devgate.lua gates every console command in the project by
-- wrapping RegisterCommand once, and tools/verify.sh's "dev gate on console
-- commands" section pins the four ways a command can get out from behind that
-- wrap. All of that is about RegisterCommand. NONE of it is about
-- RegisterNetEvent, and a net event is the door a CLIENT can knock on.
--
-- br:loot:dev shipped through that hole (#232, audited 2026-09-08). Its whole
-- authorization was:
--
--     if not BR.Server.devMode then ... return end
--
-- which reads like a permission check and is a fact about how the process was
-- STARTED. Every connected client passed it, and the handler it guards resolves
-- an item id through BR.Config.WeaponById -- which contains
-- BR.Config.AirdropWeapons. So on any box running with dev mode on, any player
-- could ask the server for an RPG, a grenade launcher, a railgun or a minigun
-- and be handed one. server.cfg.example ships with both dev-mode flags set to
-- `true`, so "any box running with dev mode on" is not a hypothetical
-- deployment, it is the documented starting point.
--
-- ═══ WHAT THIS CHECKS, AND WHY IT IS THREE THINGS RATHER THAN ONE ═══
--
--   (1) THE SHAPE. A server net-event handler may READ dev mode to decide
--       whether to print a diagnostic. It may not read dev mode to decide
--       whether to REFUSE. A refusal is an authorization decision, and the one
--       door in this project that is allowed to make it is
--       BR.Admin.devTrusted.
--
--   (2) THE DOOR IS REAL. BR.Admin.devTrusted must actually ask both questions
--       -- dev mode AND a console grant -- and must be able to say no. A
--       helper with the right name and a `return true` body would otherwise
--       satisfy (1) forever.
--
--   (3) THE SPAWNING HANDLERS ARE PINNED BY NAME. Rules (1) and (2) only fire
--       when somebody writes a dev-mode read. A brand new net event that
--       creates items with NO check at all would sail past both. So the set of
--       server net-event handlers that can reach an item-creating call is an
--       allowlist here, and a new one fails the build until a human puts it on
--       the list and says what authorizes it.
--
-- ═══ THE ALTERNATIVE THAT LOST: WRAPPING RegisterNetEvent ═══
--
-- devgate.lua's argument is that a rule copied 130 times fails at the 131st, so
-- the gate goes at the one door they all pass through. The obvious move here is
-- the same one: wrap RegisterNetEvent, refuse unless the handler is on a list.
--
-- IT DOES NOT TRANSFER, and the reason is that the two populations are
-- opposites. Console commands are ALL privileged -- the owner's instruction was
-- "gate all of them" -- so a wrap that refuses by default is right about 140
-- cases out of 140. Net events are the game's ordinary traffic: sixty-odd of
-- them carry a jump, a chat line, a squad invite, an inventory selection, and
-- they must work for every player on the public box. A wrap that refused by
-- default would have to be handed an exemption list holding almost every event
-- in the project, which is a denylist wearing an allowlist's clothes -- and it
-- is exactly the `configreport)` failure tools/verify.sh already records
-- against the dispatch verb check.
--
-- So the runtime keeps no wrap and this file is a STATIC check instead. That
-- costs the one thing a wrap would have given: this reads text, so it cannot
-- see a gate that is correct at runtime through a path it cannot follow, and it
-- cannot see a handler that is fine here and wrong in the function it calls.
-- What it can see is the shape that actually shipped.
--
-- Run standalone:  lua tools/check_net_gates.lua <server-file>...
--                  lua tools/check_net_gates.lua --selftest

local failures = 0
local scanned  = 0

-- ---------------------------------------------------------------------------
-- The pinned doors
-- ---------------------------------------------------------------------------

--- Server net events whose handler can reach a call that CREATES AN ITEM, and
--- what authorizes each one.
---
--- `guard = false` means "player-facing on purpose, authorized by the match
--- rules in the handler rather than by an admin check". `guard = <string>`
--- means the handler body must contain that text.
---
--- WHY AN ALLOWLIST AND NOT A COUNT. A count stays green while one door is
--- swapped for another. A list of names fails the day a new one appears, which
--- is the only day anybody is in a position to think about it -- the same
--- argument tools/verify.sh makes for pinning BR.Dev.rawCommand's consumers by
--- filename rather than by how many there are.
---
--- THE TWO UNGUARDED ENTRIES ARE NOT OVERSIGHTS:
---
---   LOOT_CLAIM  the ordinary pickup. Its spawnStack call is a DISPLACEMENT --
---               a weapon swapped out of a full inventory falls on the ground
---               where the player stands. It creates nothing that did not
---               already exist.
---   NPC_DROP    the NPC kill reward. It was a fabrication route until #232
---               (129de71) moved the choice of weapon, magazine and position
---               onto the server; what is left is a server-decided drop that a
---               client can only ASK for, under a rate limit and a per-match
---               ceiling. It is player-facing by design and an admin check
---               would be wrong.
local SPAWN_DOORS = {
    ['BR.Net.LOOT_CLAIM'] = { guard = false },
    ['BR.Net.NPC_DROP']   = { guard = false },
    ['BR.Net.LOOT_DEV']   = { guard = 'BR.Admin.devTrusted' },
}

--- Calls that bring an item into the world out of nothing.
local SPAWN_CALLS = {
    'devSpawn%s*%(',
    'BR%.Loot%.spawnStack%s*%(',
    'BR%.MakeCrate%s*%(',
}

--- Reads of the dev-mode build flag, on the server.
local DEVMODE_READS = {
    'BR%.Server%.devMode',
    'BR%.Dev%.on%s*%(%s*%)',
}

--- The one helper allowed to turn a dev-mode read into a refusal.
local TRUSTED = 'BR%.Admin%.devTrusted'

--- What a dev-mode read's `if` block may call and still count as a diagnostic
--- rather than a gate. Deliberately tiny: the moment a block calls anything
--- else it is doing something, and doing something on the strength of a build
--- flag is the bug this file exists for.
local LOGGING_ONLY = {
    print = true, format = true, tostring = true,
    ['string.format'] = true,
}

-- ---------------------------------------------------------------------------
-- Reading Lua without parsing Lua
-- ---------------------------------------------------------------------------

--- Strip comments and strings so their contents cannot look like code.
---
--- SAME CRUDE SUBSTITUTION AS tools/check_forward_locals.lua, and the same
--- reason: blanking to equal length keeps every line number and column intact.
--- It matters more here than there, because this project's prose QUOTES the
--- patterns being searched for -- devgate.lua's own header says
--- `BR.Server.devMode` in a sentence, and a gate that read its own explanation
--- as a violation would be deleted within the week.
--- @param line string
--- @return string
local function blank(line)
    line = line:gsub('%-%-.*$', '')
    line = line:gsub('"[^"]*"', function(s) return string.rep(' ', #s) end)
    line = line:gsub("'[^']*'", function(s) return string.rep(' ', #s) end)
    return line
end

--- @param s string
--- @return string
local function trim(s) return (s:gsub('^%s+', ''):gsub('%s+$', '')) end

--- Does any pattern in `pats` appear in `text`?
--- @param text string @param pats table
--- @return boolean
local function anyOf(text, pats)
    for _, p in ipairs(pats) do
        if text:find(p) then return true end
    end
    return false
end

--- The line that closes the `if` opened on line `at`, or nil when `at` is not a
--- single-line `if ... then`.
---
--- A MULTI-LINE CONDITION RETURNS NIL AND THAT IS THE SAFE DIRECTION: nil means
--- "this read is not a plain diagnostic block", which sends it down the failing
--- path rather than the excusing one. A dev-mode read spread over two lines
--- inside a net handler is something a human should look at anyway.
--- @param lines table @param at integer
--- @return integer|nil
local function ifBlockEnd(lines, at)
    local code = blank(lines[at])
    if not code:match('^%s*if%s') then return nil end
    if not code:match('then%s*$') then return nil end

    local indent = #(code:match('^(%s*)'))
    for j = at + 1, #lines do
        local c   = blank(lines[j])
        local ind = #(c:match('^(%s*)'))
        if ind <= indent then
            if c:match('^%s*end%s*$') then return j end
            -- An `else` or `elseif` means the block is a branch rather than a
            -- diagnostic, so it stops counting as one here.
            if c:match('^%s*else') then return j end
        end
    end
    return nil
end

--- Is the dev-mode read on line `at` a diagnostic rather than a gate?
--- @param lines table @param at integer
--- @return boolean
local function isLoggingOnly(lines, at)
    local stop = ifBlockEnd(lines, at)
    if not stop then return false end

    for j = at + 1, stop - 1 do
        local c = blank(lines[j])
        -- A refusal is a return. Nothing that returns is a diagnostic.
        if c:match('^%s*return') or c:match('%sreturn%s') then return false end
        for id in c:gmatch('([%a_][%w_%.]*)%s*%(') do
            if not LOGGING_ONLY[id] then return false end
        end
        -- `('...'):format(x)` survives blanking as `(  ):format(x)`, so the
        -- method call has to be picked up separately from the plain one above.
        for id in c:gmatch(':([%a_][%w_]*)%s*%(') do
            if not LOGGING_ONLY[id] then return false end
        end
    end
    return true
end

-- ---------------------------------------------------------------------------
-- The scan
-- ---------------------------------------------------------------------------

--- @param path string @param msg string
local function fail(path, line, msg)
    failures = failures + 1
    io.write(('\27[31mFAIL\27[0m %s:%d: %s\n'):format(path, line, msg))
end

--- @param path string
--- @param lines table
local function scan(path, lines)
    scanned = scanned + 1

    -- Which names a client can actually reach. A plain AddEventHandler with no
    -- RegisterNetEvent beside it is server-internal: TriggerServerEvent cannot
    -- raise it, so it is not this file's business.
    local net = {}
    for _, raw in ipairs(lines) do
        local n = blank(raw):match('RegisterNetEvent%s*%(%s*([^,%)]+)')
        if n then net[trim(n)] = true end
    end

    local i = 1
    while i <= #lines do
        local code = blank(lines[i])

        -- THE SHAPE THIS GATE CAN READ, ASSERTED RATHER THAN ASSUMED. Every
        -- handler in the project today starts at column 0 and ends at an
        -- `end)` at column 0. An indented one is not necessarily wrong -- it is
        -- unreadable HERE, and a gate that quietly skips what it cannot parse
        -- is a gate with a hole in the shape of the next refactor.
        if code:match('^%s+AddEventHandler%s*%(.-function')
           or code:match('^%s+RegisterNetEvent%s*%(.-,%s*function') then
            fail(path, i, 'event handler is indented; this gate reads handlers '
                .. 'that start at column 0 and end at "end)" at column 0')
        end

        local name = code:match('^AddEventHandler%s*%(%s*([^,]+),%s*function')
                  or code:match('^RegisterNetEvent%s*%(%s*([^,]+),%s*function')
        if name then
            name = trim(name)
            local stop = #lines
            for j = i + 1, #lines do
                if blank(lines[j]):match('^end%s*%)') then
                    stop = j
                    break
                end
            end

            if net[name] then
                local body = {}
                for j = i, stop do body[#body + 1] = blank(lines[j]) end
                local text = table.concat(body, '\n')
                local trusted = text:find(TRUSTED) ~= nil

                -- (1) THE SHAPE.
                for j = i, stop do
                    if anyOf(body[j - i + 1], DEVMODE_READS)
                       and not isLoggingOnly(lines, j) then
                        fail(path, j, ('%s decides something on a dev-mode '
                            .. 'read. Dev mode is a build flag, not an '
                            .. 'authorization check -- every connected client '
                            .. 'passes it on a dev box. Use BR.Admin.devTrusted'
                            .. '(src), which asks that AND for a console grant.')
                            :format(name))
                    end
                end

                -- (3) THE SPAWNING DOORS.
                if anyOf(text, SPAWN_CALLS) then
                    local door = SPAWN_DOORS[name]
                    if door == nil then
                        fail(path, i, ('%s can create an item and is not a '
                            .. 'pinned spawning door. Add it to SPAWN_DOORS in '
                            .. 'tools/check_net_gates.lua and say what '
                            .. 'authorizes it -- a net event that hands out '
                            .. 'items is a decision, not a detail.'):format(name))
                    elseif door.guard and not trusted then
                        fail(path, i, ('%s is pinned as requiring %s and no '
                            .. 'longer calls it.'):format(name, door.guard))
                    end
                end
            end

            i = stop + 1
        else
            i = i + 1
        end
    end
end

--- @param path string
local function check(path)
    local fh = io.open(path, 'r')
    if not fh then return end
    local lines = {}
    for line in fh:lines() do lines[#lines + 1] = line end
    fh:close()
    scan(path, lines)
end

-- ---------------------------------------------------------------------------
-- (2) The door is real
-- ---------------------------------------------------------------------------

--- BR.Admin.devTrusted must ask both questions and must be able to say no.
---
--- MATCHED AS REAL READS, ANCHORED, which is the finding tools/verify.sh
--- records against its own first draft: `grep -q 'BR.Server.devMode'` survived
--- a mutant that renamed every occurrence to `BR.Server.devModeX` -- a read of
--- a field that does not exist, so no gate at all -- because the old name is a
--- prefix of the new one.
--- @param path string
local function checkHelper(path)
    local fh = io.open(path, 'r')
    if not fh then
        failures = failures + 1
        io.write(('\27[31mFAIL\27[0m %s is gone; BR.Admin.devTrusted is the '
            .. 'only thing standing between a net event and an RPG\n'):format(path))
        return
    end
    local src = {}
    for line in fh:lines() do src[#src + 1] = blank(line) end
    fh:close()
    scanned = scanned + 1
    local text = table.concat(src, '\n')

    local at = text:find('function BR%.Admin%.devTrusted%s*%(')
    if not at then
        failures = failures + 1
        io.write(('\27[31mFAIL\27[0m %s no longer defines BR.Admin.devTrusted\n')
            :format(path))
        return
    end

    local body = text:sub(at)
    local stop = body:find('\nend\n')
    if stop then body = body:sub(1, stop) end

    if not anyOf(body, DEVMODE_READS) then
        failures = failures + 1
        io.write('\27[31mFAIL\27[0m BR.Admin.devTrusted no longer reads dev '
            .. 'mode. These tools bend match state and must not exist on the '
            .. 'public box even for an admin.\n')
    end
    if not body:find('BR%.Grants%.holds%s*%(') or not body:find('BR%.Grants%.CONSOLE') then
        failures = failures + 1
        io.write('\27[31mFAIL\27[0m BR.Admin.devTrusted no longer asks '
            .. 'BR.Grants.holds(license, BR.Grants.CONSOLE). Without it the '
            .. 'helper is a dev-mode check with a longer name, which is the '
            .. 'exact bug it was written to remove.\n')
    end
    if not body:find('~=%s*true') and not body:find('==%s*true') then
        failures = failures + 1
        io.write('\27[31mFAIL\27[0m BR.Admin.devTrusted no longer compares the '
            .. 'grant against `true`. holds() answers true, false OR NIL, and '
            .. 'a truthiness test turns "we never read the row" into a pass.\n')
    end
    if not body:find('return%s+false') then
        failures = failures + 1
        io.write('\27[31mFAIL\27[0m BR.Admin.devTrusted has no `return false`; '
            .. 'a helper that cannot refuse is not a gate.\n')
    end
end

-- ---------------------------------------------------------------------------
-- The self-test
-- ---------------------------------------------------------------------------

--- Fixtures, run by tools/verify.sh before the real scan.
---
--- IN THIS FILE RATHER THAN IN tools/test_roster.lua, for one reason that is
--- about people and not about Lua: the suites test the GAME, and somebody
--- reading this checker has to be able to see what it claims to catch without
--- opening a nine-thousand-line file. The cost is honest and worth naming --
--- a fixture living beside the thing it tests can be deleted in the same edit
--- that breaks it, which is why verify.sh runs this as a separate step and
--- fails the build when it does not print its ok line.
local FIXTURES = {
    {
        name = 'a devMode-only net event is caught',
        want = 1,
        src = [[
RegisterNetEvent(BR.Net.LOOT_DEV)
AddEventHandler(BR.Net.LOOT_DEV, function(d)
    local src = source
    if not BR.Server.devMode then
        return
    end
    doSomething(src, d)
end)
]],
    },
    {
        name = 'a properly gated net event passes',
        want = 0,
        src = [[
RegisterNetEvent(BR.Net.LOOT_DEV)
AddEventHandler(BR.Net.LOOT_DEV, function(d)
    local src = source
    local ok = BR.Admin.devTrusted(src)
    if ok ~= true then
        return
    end
    doSomething(src, d)
end)
]],
    },
    {
        name = 'a devMode read that only prints is not a gate',
        want = 0,
        src = [[
RegisterNetEvent(BR.Net.READY)
AddEventHandler(BR.Net.READY, function()
    local src = source
    BR.Broadcast.snapshot(src)
    if BR.Server.devMode then
        print(('snapshot -> %d'):format(src))
    end
end)
]],
    },
    {
        name = 'a server-internal event is not this gate\'s business',
        want = 0,
        src = [[
AddEventHandler('br:core:spectate', function(opts)
    if not BR.Server.devMode then
        return
    end
    BR.Spectate.adminStart(opts)
end)
]],
    },
    {
        name = 'an unpinned spawning net event is caught',
        want = 1,
        src = [[
RegisterNetEvent(BR.Net.FREE_STUFF)
AddEventHandler(BR.Net.FREE_STUFF, function(d)
    local src = source
    BR.Loot.spawnStack(m, d.stack, d.x, d.y, d.z)
end)
]],
    },
    {
        name = 'a pinned spawning door that dropped its guard is caught',
        want = 1,
        src = [[
RegisterNetEvent(BR.Net.LOOT_DEV)
AddEventHandler(BR.Net.LOOT_DEV, function(d)
    local src = source
    devSpawn(src, d.item, nil)
end)
]],
    },
    {
        name = 'an indented handler is refused rather than skipped',
        want = 1,
        src = [[
RegisterNetEvent(BR.Net.LOOT_DEV)
CreateThread(function()
    AddEventHandler(BR.Net.LOOT_DEV, function(d)
        devSpawn(source, d.item, nil)
    end)
end)
]],
    },
    {
        name = 'prose quoting the pattern is not a violation',
        want = 0,
        src = [[
RegisterNetEvent(BR.Net.READY)
-- This handler used to say `if not BR.Server.devMode then return end`.
AddEventHandler(BR.Net.READY, function()
    -- BR.Loot.spawnStack was called here once; it is not any more.
    return
end)
]],
    },
}

--- @return integer failures
local function selftest()
    local bad = 0
    for _, fx in ipairs(FIXTURES) do
        local lines = {}
        for line in (fx.src .. '\n'):gmatch('([^\n]*)\n') do
            lines[#lines + 1] = line
        end

        local before = failures
        -- Findings are counted, not printed, for the cases that are SUPPOSED
        -- to fail -- otherwise a green run prints six red FAIL lines and
        -- nobody reads the seventh.
        local realWrite = io.write
        io.write = function() end
        scan('<fixture: ' .. fx.name .. '>', lines)
        io.write = realWrite
        local got = failures - before
        failures = before

        if got ~= fx.want then
            bad = bad + 1
            io.write(('\27[31mFAIL\27[0m selftest: %s -- wanted %d finding(s), '
                .. 'got %d\n'):format(fx.name, fx.want, got))
        end
    end
    scanned = 0
    if bad == 0 then
        io.write(('\27[32mok\27[0m   %d selftest fixtures: the gate fires on a '
            .. 'devMode-only net event and does not fire on a gated one\n')
            :format(#FIXTURES))
    end
    return bad
end

-- ---------------------------------------------------------------------------
-- Entry
-- ---------------------------------------------------------------------------

local args = { ... }
if #args == 0 then
    io.write('usage: lua tools/check_net_gates.lua <server-file>...\n')
    io.write('       lua tools/check_net_gates.lua --selftest\n')
    os.exit(2)
end

if args[1] == '--selftest' then
    os.exit(selftest() > 0 and 1 or 0)
end

local HELPER = 'resources/[fivem-royale]/br_core/server/admin.lua'
checkHelper(HELPER)
for _, path in ipairs(args) do
    if path ~= HELPER then check(path) end
end

if failures > 0 then
    io.write(('\27[31m%d net-event gate finding(s)\27[0m in %d file(s)\n')
        :format(failures, scanned))
    os.exit(1)
end
io.write(('\27[32mok\27[0m   %d files, no net event decides anything on a '
    .. 'dev-mode read\n'):format(scanned))
