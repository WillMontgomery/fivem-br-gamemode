-- Every `live` check a client file hands BR.Keys.on, pressed through the real
-- key layer -- and no suite's own listener allowed to stand in for one (#393).
--
-- keybinds.raw reads a key only while some listener of its action says a press
-- could act. A check that says no where it should say yes is a key that stops
-- responding, which is the failure #393's review asked to be impossible to land.
-- So each check is put to a press through client/keybinds.lua, against the real
-- file that registers it, and to what the press does in the game; and outside the
-- states it names, to its key not being read at all.
--
-- WHERE EACH ONE IS PRESSED:
--
--   * R, G, 1-5, M, B and Space -- inventory.lua, keybinds.lua, skydive.lua and
--     bus.lua -- in tools/test_client.lua, which loads those files.
--   * the spectate arrows and the emote wheel, HERE: their files are ones
--     tools/test_client.lua does not load, and their own suites
--     (test_spectate, test_emotes_client) model BR.Keys rather than run it.
--
-- AND `observers.listen`, LAST. #393's review found the hole these blocks close:
-- tools/test_client.lua's own counting listeners on `use` and `drop` gave no
-- `live`, which keybinds.raw reads as "always", so R and G were read in every
-- state whatever inventory.lua's check said -- and a check that switched either
-- key off for good passed every suite. That block reads every test file and
-- fails on a listener that could do it again.
--
-- This suite registers no listener of its own: it loads keybinds.lua and one
-- client file per block, on a fresh client, and presses keys.

local ROOT = 'resources/[fivem-royale]/'
local realPrint = print

-- ------------------------------------------------------------ native stubs ---

local fakeTime, frameNo = 0, 0
--- Physically held keys, by virtual-key code.
local keys = {}
--- IsRawKeyDown calls this frame, by code.
local reads = {}
local handlers, printed = {}, {}

local function stubs()
    fakeTime, frameNo = 0, 0
    keys, reads, handlers, printed = {}, {}, {}, {}
    function GetGameTimer() return fakeTime end
    function GetFrameCount() return frameNo end
    function GetCurrentResourceName() return 'br_core' end
    function GetPlayerServerId() return 1 end
    function PlayerId() return 0 end
    function print(...)
        local t = {}
        for i = 1, select('#', ...) do t[#t + 1] = tostring((select(i, ...))) end
        printed[#printed + 1] = table.concat(t, ' ')
    end
    Citizen = { CreateThread = function() end, Wait = function() end,
                SetTimeout = function() end }
    json = { encode = function() return '{}' end, decode = function() return {} end }
    function AddEventHandler(n, fn)
        handlers[n] = handlers[n] or {}
        table.insert(handlers[n], fn)
    end
    function RegisterNetEvent() end
    function TriggerEvent(n, ...)
        for _, fn in ipairs(handlers[n] or {}) do fn(...) end
    end
    function TriggerServerEvent() end
    function RegisterCommand() end
    function RegisterKeyMapping() end
    local kvp = {}
    function GetResourceKvpString(k) return kvp[k] end
    function SetResourceKvp(k, v) kvp[k] = v end
    function DeleteResourceKvp(k) kvp[k] = nil end
    function IsPauseMenuActive() return false end
    function IsPauseMenuRestarting() return false end
    function DisableControlAction() end
    function IsRawKeyDown(vk)
        reads[vk] = (reads[vk] or 0) + 1
        return keys[vk] == true
    end
    function IsRawKeyPressed() return false end
end

local function loadAll(list)
    for _, f in ipairs(list) do
        local chunk, err = loadfile(ROOT .. f)
        if not chunk then
            realPrint('\27[31mload error\27[0m ' .. f .. ': ' .. tostring(err))
            os.exit(1)
        end
        chunk()
    end
end

--- Whether BR.Season.has('emotes') says yes.
local seasonEmotes = false

--- A fresh client: br_lib's enums and protocol, the loop registry, and the real
--- client/keybinds.lua, started.
local function boot()
    stubs()
    BR = nil
    loadAll({ 'br_lib/shared/enums.lua', 'br_lib/shared/protocol.lua',
              'br_core/client/main.lua' })
    BR.Season = { has = function(id) return id == 'emotes' and seasonEmotes end }
    BR.State = { me = { src = 1, state = BR.PlayerState.ALIVE } }
    loadAll({ 'br_core/client/keybinds.lua' })
    TriggerEvent('onClientResourceStart', 'br_core')
end

local function frame()
    fakeTime = fakeTime + 16
    frameNo = frameNo + 1
    reads = {}
    BR.Loop.step(BR.Loop.FRAME)
end

-- Default codes (client/keybinds.lua's DEFAULT_VK).
local VK = { RIGHT = 0x27, ALT = 0x12 }

-- ---------------------------------------------------------------- harness ---

local pass, fail = 0, 0
local group = ''
local function describe(n) group = n end
local function ok(cond, name, detail)
    if cond then
        pass = pass + 1
    else
        fail = fail + 1
        realPrint('\27[31mFAIL\27[0m ' .. group .. ' > ' .. name ..
            (detail and ('\n       ' .. tostring(detail)) or ''))
    end
end

local noop = function() end

-- ======================================================================== --
-- THE TWO CHECKS tools/test_client.lua CANNOT PRESS
-- ======================================================================== --

describe('the spectate arrows, read on spectate.lua\'s own check')
do
    boot()
    local wire = {}
    function TriggerServerEvent(n, d) wire[#wire + 1] = { name = n, d = d } end
    BR.Native = { spectate = noop, stopSpectate = noop, lockMinimap = noop,
                  unlockMinimap = noop, spectatePed = function() return 0 end }
    BR.PushHud = noop
    BR.DeathVerdictUp = function() return false end
    loadAll({ 'br_core/client/spectate.lua' })
    local LEFT = 0x25
    local function tap(vk)
        keys[vk] = true
        frame()
        keys[vk] = nil
        frame()
    end
    local function asked()
        local dirs = {}
        for _, w in ipairs(wire) do
            if w.name == BR.Net.SPECTATE_CYCLE then dirs[#dirs + 1] = w.d and w.d.dir end
        end
        return dirs
    end

    BR.State.me.state = BR.PlayerState.OUT
    frame()
    ok(reads[VK.RIGHT] == 1 and reads[LEFT] == 1, 'out of the match, both arrows are read',
       ('RIGHT %s, LEFT %s'):format(tostring(reads[VK.RIGHT]), tostring(reads[LEFT])))
    wire = {}
    tap(VK.RIGHT)
    tap(LEFT)
    local dirs = asked()
    ok(#dirs == 2 and dirs[1] == 1 and dirs[2] == -1,
       'and Right asks the server for the next player, Left for the one before',
       ('%d asks: %s'):format(#dirs, table.concat(dirs, ',')))

    local wrong = {}
    for _, st in ipairs({ 'ALIVE', 'DBNO', 'BUS', 'FREEFALL', 'GLIDE', 'WARMUP' }) do
        BR.State.me.state = BR.PlayerState[st]
        frame()
        if (reads[VK.RIGHT] or 0) + (reads[LEFT] or 0) > 0 then
            wrong[#wrong + 1] = st .. ' read'
        end
        wire = {}
        tap(VK.RIGHT)
        if #asked() > 0 then wrong[#wrong + 1] = st .. ' asked' end
    end
    BR.State.me.state = BR.PlayerState.OUT
    TriggerEvent(BR.Net.SPECTATE_SET, { stop = true, reason = 'match-over', final = true })
    frame()
    if (reads[VK.RIGHT] or 0) + (reads[LEFT] or 0) > 0 then
        wrong[#wrong + 1] = 'OUT, sealed: read'
    end
    ok(#wrong == 0, 'in the fight, on the way down and in a decided match, neither '
       .. 'arrow is read, and a press asks nothing', table.concat(wrong, '; '))
end

describe('the emote wheel key, read on emotewheel.lua\'s own check')
do
    seasonEmotes = false
    boot()
    BR.Config = BR.Config or {}
    BR.Config.Emotes = { tapMs = 150 }
    -- One emote on the wheel, so letting go of Alt over it asks for something.
    local asked = {}
    BR.Emotes = { blocked = function() return nil end,
                  wheel = function() return { 'wave' } end,
                  row = function(id) return id == 'wave' and { name = 'Wave' } or nil end,
                  request = function(id) asked[#asked + 1] = id end }
    SegmentItem = { New = function() return {} end }
    local menu = { Segments = { { AddItem = noop } } }
    function menu.Visible(self, v)
        if v == nil then return self.shown end
        self.shown = v
    end
    function menu.CurrentSelection() return 1 end
    BR.Menu = { radial = function() return menu end, available = function() return true end,
                closeAll = noop }
    BR.Native = {}
    loadAll({ 'br_core/client/emotewheel.lua' })
    local LALT = 0xA4

    frame()
    ok((reads[VK.ALT] or 0) == 0 and (reads[LALT] or 0) == 0,
       'with emotes off and no wheel up, Alt is not read, by either of its codes')
    keys[VK.ALT] = true
    frame()
    keys[VK.ALT] = nil
    frame()
    ok(not BR.EmoteWheel.isOpen(), 'and holding it opens nothing')

    seasonEmotes = true
    frame()
    ok((reads[VK.ALT] or 0) > 0, 'with emotes on, Alt is read')
    keys[VK.ALT] = true
    frame()
    ok(BR.EmoteWheel.isOpen() and menu.shown == true, 'and holding it opens the wheel')
    fakeTime = fakeTime + 500
    keys[VK.ALT] = nil
    frame()
    ok(not BR.EmoteWheel.isOpen() and asked[1] == 'wave',
       'and letting go over an emote asks for it', table.concat(asked, ','))

    -- THE WHEEL'S OWN HALF OF THE CHECK: a wheel that is up keeps the key read,
    -- whatever the season says by then. The season closing on the very frame Alt
    -- is let go still delivers that release -- keybinds.raw runs before the wheel's
    -- own frame callback closes it -- and the release still picks.
    asked = {}
    keys[VK.ALT] = true
    frame()
    ok(BR.EmoteWheel.isOpen(), 'held again: open again')
    fakeTime = fakeTime + 500
    keys[VK.ALT] = nil
    seasonEmotes = false
    frame()
    ok((reads[VK.ALT] or 0) > 0 and asked[1] == 'wave',
       'the season closing under an open wheel still reads Alt, and the release picks',
       ('%s reads, asked %s'):format(tostring(reads[VK.ALT]), table.concat(asked, ',')))
    frame()
    ok(not BR.EmoteWheel.isOpen() and (reads[VK.ALT] or 0) == 0,
       'and with the wheel down and emotes off, Alt is unread again')
    SegmentItem = nil
end

-- ======================================================================== --
-- observers.listen: A SUITE'S OWN COUNTER NEVER DECIDES WHETHER A KEY IS READ
-- ======================================================================== --
--
-- THE FINDING (#393's review). tools/test_client.lua loads the real listeners
-- and adds counting ones of its own, for the rest of the run. Its counters on
-- `use` and `drop` gave BR.Keys.on no `live` -- which keybinds.raw reads as "a
-- press could always act" -- so R and G were read in every state, and mutants
-- that switched off inventory.lua's checks for good passed every suite.
--
-- THE RULE: a test's listener on an action that a loaded client file registers
-- with a `live` passes one that answers no -- `NEVER`, or `function() return
-- false end` -- and a listener on an action named at run time passes a `live` at
-- all. Then the production checks alone decide what is read, and a block that
-- needs a key read has to put the world in the state in which the game reads it.
-- A test file's listener on an action whose production file it does not load is
-- that action's only listener, masks nothing, and is left alone.

describe('observers.listen')
do
    local function slurp(p)
        local fh = io.open(p, 'rb')
        if not fh then return nil end
        local s = fh:read('a')
        fh:close()
        return s
    end

    --- Comments and string contents blanked, lengths and newlines kept, so a
    --- position in the result is the same position in the source.
    local function codeOnly(src)
        local out, i, n = {}, 1, #src
        local function blank(s) return (s:gsub('[^\n]', ' ')) end
        while i <= n do
            local c = src:sub(i, i)
            if c == '-' and src:sub(i, i + 1) == '--' then
                local eq = src:match('^%[(=*)%[', i + 2)
                if eq then
                    local close = ']' .. eq .. ']'
                    local e = src:find(close, i + 4 + #eq, true) or n
                    out[#out + 1] = blank(src:sub(i, e + #close - 1))
                    i = e + #close
                else
                    local e = src:find('\n', i, true) or (n + 1)
                    out[#out + 1] = blank(src:sub(i, e - 1))
                    i = e
                end
            elseif c == '"' or c == "'" then
                local j = i + 1
                while j <= n do
                    local d = src:sub(j, j)
                    if d == '\\' then j = j + 2
                    elseif d == c or d == '\n' then break
                    else j = j + 1 end
                end
                out[#out + 1] = c .. blank(src:sub(i + 1, j - 1)) .. c
                i = j + 1
            elseif c == '[' and src:match('^%[=*%[', i) then
                local eq = src:match('^%[(=*)%[', i)
                local close = ']' .. eq .. ']'
                local e = src:find(close, i + 2 + #eq, true) or n
                out[#out + 1] = blank(src:sub(i, e + #close - 1))
                i = e + #close
            else
                local j = src:find('[%-"\'%[]', i + 1) or (n + 1)
                out[#out + 1] = src:sub(i, j - 1)
                i = j
            end
        end
        return table.concat(out)
    end

    local OPENS = { ['function'] = true, ['if'] = true, ['do'] = true, ['repeat'] = true }
    local CLOSES = { ['end'] = true, ['until'] = true }

    --- The top-level arguments of the call whose `(` is at `open`, as source text.
    local function callArgs(src, code, open)
        local depth, block, start = 0, 0, open + 1
        local args, i, n = {}, open, #code
        local function trim(a, b) return (src:sub(a, b):gsub('^%s+', ''):gsub('%s+$', '')) end
        while i <= n do
            local c = code:sub(i, i)
            if c:match('[%a_]') then
                local w = code:match('^[%w_]+', i)
                if OPENS[w] then block = block + 1 elseif CLOSES[w] then block = block - 1 end
                i = i + #w
            else
                if c == '(' or c == '{' or c == '[' then
                    depth = depth + 1
                elseif c == ')' or c == '}' or c == ']' then
                    depth = depth - 1
                    if depth == 0 then
                        args[#args + 1] = trim(start, i - 1)
                        return args
                    end
                elseif c == ',' and depth == 1 and block == 0 then
                    args[#args + 1] = trim(start, i - 1)
                    start = i + 1
                end
                i = i + 1
            end
        end
        return nil
    end

    --- Every BR.Keys.on call in a file: { line, args }.
    local function keyCalls(src)
        local code = codeOnly(src)
        local out = {}
        for at in code:gmatch('BR%.Keys%.on%s*()%(') do
            local line = select(2, code:sub(1, at):gsub('\n', '')) + 1
            out[#out + 1] = { line = line, args = callArgs(src, code, at) or {} }
        end
        return out
    end

    --- An action argument as a name ('use') or a prefix ('slot' .. i), or nil.
    local function actionOf(arg)
        local lit = arg:match("^'([%w_]+)'$") or arg:match('^"([%w_]+)"$')
        if lit then return lit, false end
        local pre = arg:match("^'([%w_]+)'%s*%.%.") or arg:match('^"([%w_]+)"%s*%.%.')
        if pre then return pre, true end
        return nil
    end

    -- THE PRODUCTION SIDE: every client file of br_core, and the actions each one
    -- registers with a `live`.
    local man = slurp(ROOT .. 'br_core/fxmanifest.lua') or ''
    local body = man:match('client_scripts%s*(%b{})') or ''
    local liveBy = {}          -- [file] = { [action] = true, [prefix .. '*'] = true }
    local seen = {}
    for line in body:gmatch('[^\n]+') do
        local entry = line:match("^%s*'([^'@]+%.lua)'")
        local src = entry and slurp(ROOT .. 'br_core/' .. entry)
        if src then
            for _, c in ipairs(keyCalls(src)) do
                local action, prefix = actionOf(c.args[1] or '')
                if action and #c.args >= 3 then
                    liveBy[entry] = liveBy[entry] or {}
                    liveBy[entry][prefix and (action .. '*') or action] = true
                    seen[#seen + 1] = prefix and (action .. '*') or action
                end
            end
        end
    end
    table.sort(seen)
    local want = { 'deploy', 'deploy', 'drop', 'emoteWheel', 'map', 'slot*', 'specNext',
                   'specPrev', 'trail', 'use' }
    ok(table.concat(seen, ',') == table.concat(want, ','),
       'the reading finds every production `live` there is',
       table.concat(seen, ','))

    local function liveIn(loaded, action)
        for file, acts in pairs(liveBy) do
            if loaded[file] then
                if acts[action] then return true end
                for k in pairs(acts) do
                    if k:sub(-1) == '*' and action:match('^' .. k:sub(1, -2) .. '%d+$') then
                        return true
                    end
                end
            end
        end
        return false
    end

    local function answersNo(arg)
        return arg == 'NEVER'
            or arg:match('^function%s*%(%s*%)%s*return%s+false%s+end$') ~= nil
    end

    --- The rule, over one test file's source. Returns the offending calls.
    local function check(label, src)
        local loaded, any = {}, false
        for file in src:gmatch("['\"]br_core/(client/[%w_/]+%.lua)['\"]") do
            if liveBy[file] then loaded[file] = true any = true end
        end
        local bad = {}
        for _, c in ipairs(keyCalls(src)) do
            local action = actionOf(c.args[1] or '')
            local where = ('%s:%d'):format(label, c.line)
            if action then
                if liveIn(loaded, action) and not answersNo(c.args[3] or '') then
                    bad[#bad + 1] = where .. ' ' .. action
                end
            elseif any and c.args[3] == nil then
                bad[#bad + 1] = where .. ' ' .. tostring(c.args[1])
            end
        end
        return bad
    end

    local lister = io.popen('find tools -maxdepth 1 -name "*.lua"')
    local names = {}
    if lister then
        for name in lister:lines() do names[#names + 1] = name end
        lister:close()
    end
    ok(#names > 20, 'the tools are listed', ('%d files'):format(#names))
    local bad, observed = {}, 0
    for _, name in ipairs(names) do
        local src = slurp(name)
        if src and src:find('BR.Keys.on', 1, true) then
            observed = observed + #keyCalls(src)
            for _, b in ipairs(check(name:match('[^/\\]+$'), src)) do bad[#bad + 1] = b end
        end
    end
    ok(observed > 20, 'and their BR.Keys.on calls are read', ('%d calls'):format(observed))
    ok(#bad == 0, 'no suite\'s own listener keeps a key read that a loaded client '
       .. 'file\'s `live` would leave unread', table.concat(bad, '; '))

    -- AND THE RULE CAN FAIL: the review's two counters, as they were.
    local was = check('t', "loadAll({ 'br_core/client/inventory.lua' })\n"
        .. "BR.Keys.on('use', function(p) if p then n = n + 1 end end)\n"
        .. "BR.Keys.on('drop', function(p)\n    local a, b = 1, 2\nend)\n"
        .. "BR.Keys.on('slot3', function() end, function() return true end)\n"
        .. "for _, a in ipairs(A) do BR.Keys.on(a, function() end) end\n")
    ok(#was == 4, 'the counters #393\'s review found are caught, and a `live` that says '
       .. 'yes, and a name given at run time with none', table.concat(was, '; '))
    local fine = check('t', "loadAll({ 'br_core/client/inventory.lua' })\n"
        .. "BR.Keys.on('use', function() end, NEVER)\n"
        .. "BR.Keys.on('drop', function() end, function() return false end)\n"
        .. "BR.Keys.on('emoteWheel', function() end)\n"
        .. "-- BR.Keys.on('slot1', function() end)\n")
    ok(#fine == 0, 'while one that answers no, one on an action whose file is not '
       .. 'loaded, and one in a comment pass', table.concat(fine, '; '))
end


realPrint(('%s%d passed, %d failed\27[0m')
    :format(fail == 0 and '\27[32m' or '\27[31m', pass, fail))
os.exit(fail == 0 and 0 or 1)
