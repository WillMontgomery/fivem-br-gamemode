-- Unit tests for WHICH keys the raw key layer reads, and when (#393).
--
--   "for the primary loops in br_core - we need to seriously scrutinize how
--    we're handling our compute expenses, which translates to framerate for our
--    players."                                            -- owner, 2026-10-07
--
-- keybinds.raw used to read every bound key on every frame: 25 IsRawKeyDown a
-- frame in every phase of a session, three of them for shift alone. It now
-- reads a key only while a press on it could do something -- every listener of
-- the action gets a say through BR.Keys.on's `live` -- and reads nothing while
-- one of our screens holds the keyboard. The rule the round was given is the
-- rule these tests hold it to: THE PLAYER MUST NOT BE ABLE TO TELL. So the
-- heart of this file is a differential: thousands of random frames of keys,
-- states and screens, played through the real client/keybinds.lua and through
-- a model of the loop as it shipped before #393, and every press, release and
-- held state a listener could act on compared between the two.
--
-- THE ONE DIFFERENCE THERE IS, AND IT IS ASSERTED RATHER THAN HIDDEN. A key
-- read again after a frame unread has no last frame to compare with, so its
-- state is adopted: a key already down then is no press (exactly what the old
-- loop made of it), and a press whose edge lands on that very frame is not seen.
-- The differential allows that case and nothing else, and counts it.
--
-- WHAT THIS DOES NOT COVER: which states each listener's `live` names. Those
-- are each listener's own question, and every one is pressed through the real
-- key layer against its real listener elsewhere -- R, G, 1-5, M, B and Space in
-- tools/test_client.lua, the spectate arrows and the emote wheel in
-- tools/test_keylive.lua, which also holds every suite's own counting listeners
-- to answering no.

local ROOT = 'resources/[fivem-royale]/'
local realPrint = print

-- ------------------------------------------------------------ native stubs ---
--
-- Globals, reset by boot() so each test can stand up a fresh client.

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
    Citizen = { CreateThread = function() end, Wait = function() end }
    json = { encode = function() return '{}' end, decode = function() return {} end }
    function AddEventHandler(n, fn)
        handlers[n] = handlers[n] or {}
        table.insert(handlers[n], fn)
    end
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

--- Whether the emote row's own gate (BR.Season.has('emotes')) is open.
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

local function frames(n) for _ = 1, n do frame() end end

local function totalReads()
    local n = 0
    for _, c in pairs(reads) do n = n + c end
    return n
end

--- A screen of ours coming up or going, as br_ui announces it.
local function focus(screen) TriggerEvent('br:ui:focusChanged', screen) end

-- Default codes (client/keybinds.lua's DEFAULT_VK).
local VK = { RIGHT = 0x27, B = 0x42, ONE = 0x31, G = 0x47, E = 0x45, ALT = 0x12 }

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

-- ======================================================================== --
-- THE RULE, CASE BY CASE
-- ======================================================================== --

describe('a key nobody could act on is not read')
do
    boot()
    local live, presses = false, 0
    BR.Keys.on('specNext', function(p) if p and live then presses = presses + 1 end end,
        function() return live end)

    frame()
    local before = totalReads()
    ok((reads[VK.RIGHT] or 0) == 0,
       'while its one listener says no, the key is not read at all',
       ('%d reads of RIGHT'):format(reads[VK.RIGHT] or 0))
    ok(reads[VK.E] == 1, 'and a key whose listeners never said is read as always',
       ('%s reads of E'):format(tostring(reads[VK.E])))

    live = true
    frame()
    ok(reads[VK.RIGHT] == 1, 'the frame it says yes, the key is read again')
    ok(totalReads() == before + 1, 'and that one key is the whole difference',
       ('%d then %d'):format(before, totalReads()))

    keys[VK.RIGHT] = true
    frame()
    keys[VK.RIGHT] = nil
    frame()
    ok(presses == 1, 'and a press while it is live is a press, once', ('%d'):format(presses))
end

describe('a key held across the switch is never a press')
do
    boot()
    local live, calls = false, {}
    BR.Keys.on('specNext', function(p) calls[#calls + 1] = p end,
        function() return live end)

    -- Pressed and held while nothing listens -- a living player leaning on the
    -- arrow key, say -- and then the listener comes on with it still down.
    frame()
    keys[VK.RIGHT] = true
    frames(3)
    live = true
    frames(3)
    ok(#calls == 0, 'the key is adopted as held, not announced -- the loop as it '
       .. 'shipped would have fired its press while nothing listened, and nothing since',
       ('%d calls'):format(#calls))

    keys[VK.RIGHT] = nil
    frame()
    keys[VK.RIGHT] = true
    frame()
    ok(#calls == 2 and calls[1] == true and calls[2] == false,
       'let go and pressed again, it is an ordinary tap',
       ('%d calls'):format(#calls))

    -- A key that went UP while unread is not a release either: the tap's
    -- release was delivered with its press, long ago.
    calls = {}
    live = false
    frame()
    keys[VK.RIGHT] = nil
    frames(2)
    live = true
    frame()
    ok(#calls == 0, 'and a key let go while unread is no event at all')
end

describe('every listener has a say')
do
    boot()
    local live = false
    BR.Keys.on('drop', function() end, function() return live end)
    frame()
    ok((reads[VK.G] or 0) == 0, 'one listener, saying no: unread')

    BR.Keys.on('drop', function() end)
    frame()
    ok(reads[VK.G] == 1, 'a second listener that never said keeps the key read, '
       .. 'which is how every action behaved before #393')

    boot()
    local a, b = false, false
    BR.Keys.on('trail', function() end, function() return a end)
    BR.Keys.on('trail', function() end, function() return b end)
    frame()
    ok((reads[VK.B] or 0) == 0, 'two listeners, both saying no: unread')
    b = true
    frame()
    ok(reads[VK.B] == 1, 'either one saying yes is enough')
end

describe('a borrowed press keeps its key read')
do
    boot()
    local claimed = 0
    BR.Keys.on('specNext', function() end, function() return false end)
    BR.Keys.claim('specNext', function() claimed = claimed + 1 end, 1000)
    frame()
    ok(reads[VK.RIGHT] == 1, 'a claim is a listener that can act, so the key is read')
    keys[VK.RIGHT] = true
    frame()
    ok(claimed == 1, 'and the press reaches the claim')
    keys[VK.RIGHT] = nil
    frame()
    ok((reads[VK.RIGHT] or 0) == 0, 'spent, the key goes back to unread')
end

describe('a live check that throws reads as live')
do
    boot()
    BR.Keys.on('specPrev', function() end, function() error('boom', 0) end)
    frames(3)
    ok(reads[0x25] == 1, 'the key is read -- a throw must never cost a player a key')
    local said = 0
    for _, p in ipairs(printed) do
        if p:find('specPrev', 1, true) and p:find('boom', 1, true) then said = said + 1 end
    end
    ok(said == 1, 'and it is said once, not every frame', ('%d lines'):format(said))
    ok(BR.Loop.stats()[1] ~= nil, 'and the loop is still running')
    local suspended = false
    for _, s in ipairs(BR.Loop.stats()) do
        if s.name == 'keybinds.raw' and s.suspended then suspended = true end
    end
    ok(not suspended, 'keybinds.raw is not suspended by it')
end

describe('a hold row: its state is adopted, its release still arrives')
do
    boot()
    local live, calls = false, {}
    BR.Keys.on('emoteWheel', function(p) calls[#calls + 1] = p end,
        function() return live end)
    frame()
    ok((reads[VK.ALT] or 0) == 0 and (reads[0xA4] or 0) == 0,
       'the wheel key, both of its codes, unread while nothing could open a wheel')
    keys[VK.ALT] = true
    frame()
    live = true
    frame()
    ok(#calls == 0 and BR.Keys.isHeld('emoteWheel') == true,
       'switched on with Alt already down: held, and no press',
       ('%d calls, held %s'):format(#calls, tostring(BR.Keys.isHeld('emoteWheel'))))
    keys[VK.ALT] = nil
    frame()
    ok(#calls == 1 and calls[1] == false, 'and letting go is a release, as it always was')

    -- AN UNREAD HOLD READS NOT-HELD. Pressed while live, then the listener says
    -- no, then let go unread: nothing is left claiming the key is down for
    -- endHolds() to release into a listener that has nothing running.
    calls = {}
    keys[VK.ALT] = true
    frame()
    ok(#calls == 1 and calls[1] == true, 'pressed while live: a press')
    live = false
    frame()
    ok(BR.Keys.isHeld('emoteWheel') == false, 'unread, the hold reads not-held')
    keys[VK.ALT] = nil
    frame()
    focus('settings')
    frame()
    ok(#calls == 1, 'and a screen taking the keyboard releases nothing into it',
       ('%d calls'):format(#calls))
    focus('none')
    frame()
end

-- ======================================================================== --
-- A SCREEN THAT HOLDS THE KEYBOARD
-- ======================================================================== --

describe('nothing is read while one of our screens holds the keyboard')
do
    boot()
    local interact = {}
    BR.Keys.on('interact', function(p) interact[#interact + 1] = p end)
    frame()
    local open = totalReads()
    ok(open > 10, 'with no screen up every bound key is read', ('%d reads'):format(open))

    focus('settings')
    frames(3)
    ok(totalReads() == 0, 'under Settings, not one key is read',
       ('%d reads'):format(totalReads()))

    -- E pressed while typing, and still down when the screen goes.
    keys[VK.E] = true
    frames(2)
    focus('none')
    frame()
    ok(totalReads() == open, 'the first frame back reads every key again')
    ok(#interact == 0, 'and a key held through the screen is no press -- exactly '
       .. 'what reading under the screen made of it', ('%d calls'):format(#interact))
    ok(BR.Keys.isHeld('interact') == true,
       'but a hold reads held at once, from the key, as it always has')
    keys[VK.E] = nil
    frame()
    ok(#interact == 1 and interact[1] == false, 'and its release is delivered')

    focus('inventory')
    frame()
    ok(totalReads() == open,
       'the inventory keeps the keyboard, so under it every key is read as before')
end

describe('the resync window reads every key')
do
    boot()
    BR.Keys.on('specNext', function() end, function() return false end)
    frame()
    ok((reads[VK.RIGHT] or 0) == 0, 'an idle key, unread')
    focus('inventory')
    frame()
    ok(reads[VK.RIGHT] == 1, 'a focus change opens the window, and the idle key is '
       .. 'read with the rest: the window closes on the first quiet frame of EVERY key')
    frames(3)
    ok((reads[VK.RIGHT] or 0) == 0, 'and once it closes, idle again')
end

describe('a hold whose state anybody reads is never left unread')
do
    -- An unread hold reads not-held. That is harmless only while nothing asks
    -- isHeld for it: dbno.lua starts a revive from isHeld('interact') alone,
    -- and a gated interact key would be a revive that cannot start. So across
    -- the tree: no action read through isHeld may have a listener that hands
    -- BR.Keys.on a live check (a column-0 listener whose closing line is
    -- `end, <check>)`). Only debug readouts and keybinds.lua itself are exempt.
    local files = {}
    local p = io.popen('find "' .. ROOT .. '" -name "*.lua" -path "*/client/*"')
    for f in p:lines() do files[#files + 1] = f end
    p:close()
    ok(#files > 50, 'the client files are found', #files)

    local gated, readers = {}, {}
    for _, f in ipairs(files) do
        local lines = {}
        for l in io.lines(f) do lines[#lines + 1] = l end
        for i, l in ipairs(lines) do
            local action = l:match("^BR%.Keys%.on%(%s*'([%w_]+)'")
            if action then
                for j = i + 1, #lines do
                    if lines[j]:match('^end') then
                        if lines[j]:match('^end%s*,') then gated[action] = f .. ':' .. i end
                        break
                    end
                end
            end
            if not f:find('keybinds.lua', 1, true) and not f:find('debug.lua', 1, true) then
                for a in l:gmatch("isHeld%(%s*'([%w_]+)'%s*%)") do
                    readers[#readers + 1] = { action = a, at = f .. ':' .. i }
                end
            end
        end
    end
    ok(gated.emoteWheel ~= nil and gated.specNext ~= nil,
       'the scan sees the live checks it exists for', tostring(gated.emoteWheel))
    local bad = {}
    for _, r in ipairs(readers) do
        if gated[r.action] then
            bad[#bad + 1] = ('%s is read at %s and gated at %s'):format(r.action, r.at, gated[r.action])
        end
    end
    ok(#readers > 3 and #bad == 0, 'no held state anybody reads belongs to a gated key',
       table.concat(bad, '; '))
end

-- ======================================================================== --
-- THE DIFFERENTIAL
-- ======================================================================== --
--
-- The loop as it shipped before #393, modeled line for line: every row read on
-- every frame; holds fire both edges unless a screen owns the keyboard; taps fire
-- on a rising edge unless a screen owns it or the resync window is open; the
-- window opens on every focus change and closes on its first frame after the
-- first in which nothing moved; endHolds releases every held hold on the way in.

local ROWS = {
    { action = 'specNext',   codes = { VK.RIGHT },     hold = false, flag = 'a' },
    { action = 'trail',      codes = { VK.B },         hold = false, flag = 'b' },
    { action = 'slot1',      codes = { VK.ONE },       hold = false, flag = 'a' },
    { action = 'emoteWheel', codes = { VK.ALT, 0xA4 }, hold = true,  flag = 'c' },
    { action = 'interact',   codes = { VK.E },         hold = true,  flag = nil },
}

local function model()
    local m = { rawDown = {}, held = {}, resyncing = false, frames = 0, ui = false }
    function m.focus(owns, fireFn)
        m.resyncing, m.frames = true, 0
        if owns ~= m.ui then
            m.ui = owns
            if owns then
                for _, r in ipairs(ROWS) do
                    if r.hold and m.held[r.action] == true then
                        m.held[r.action] = false
                        fireFn(r.action, false)
                    end
                end
            end
        end
    end
    function m.frame(fireFn)
        local moved = false
        for _, r in ipairs(ROWS) do
            local down = false
            for _, c in ipairs(r.codes) do if keys[c] then down = true end end
            local was = m.rawDown[r.action] == true
            if r.hold then m.held[r.action] = down and not m.ui end
            if down ~= was then
                moved = true
                m.rawDown[r.action] = down or nil
                if m.ui then
                    -- adopted
                elseif r.hold then
                    m.held[r.action] = down
                    fireFn(r.action, down)
                elseif down and not m.resyncing then
                    fireFn(r.action, true)
                    fireFn(r.action, false)
                end
            end
        end
        if m.resyncing then
            if m.frames > 0 and not moved then m.resyncing = false end
            m.frames = m.frames + 1
        end
    end
    return m
end

describe('the differential: random frames, the shipped loop against the new one')
do
    local seed = 393
    local function rnd()
        seed = (seed * 1103515245 + 12345) % 2147483648
        return seed / 2147483648
    end

    local flags = { a = false, b = false, c = false }
    local function liveOf(flag) return flag == nil or flags[flag] end

    -- The script: what happens before each frame, generated once and played
    -- twice.
    local N = 6000
    local script = {}
    local codes = { VK.RIGHT, VK.B, VK.ONE, VK.ALT, VK.E }
    for f = 1, N do
        local s = { keys = {}, flags = {}, focus = nil }
        for _, c in ipairs(codes) do
            if rnd() < 0.07 then s.keys[#s.keys + 1] = c end
        end
        for _, k in ipairs({ 'a', 'b', 'c' }) do
            if rnd() < 0.03 then s.flags[#s.flags + 1] = k end
        end
        local r = rnd()
        if r < 0.004 then s.focus = 'settings'
        elseif r < 0.008 then s.focus = 'inventory'
        elseif r < 0.014 then s.focus = 'none' end
        script[f] = s
    end

    local function apply(s)
        for _, c in ipairs(s.keys) do keys[c] = not keys[c] or nil end
        for _, k in ipairs(s.flags) do flags[k] = not flags[k] end
    end

    -- Each call is tagged with WHEN it came: `F` from inside a frame, `X` from a
    -- focus change between two -- endHolds() releasing a hold on the way into a
    -- screen. A frame call carries the number of the frame it came from, a
    -- focus call the number of the last frame before it.
    local phase = 'F'

    -- PLAY ONE: the real file.
    boot()
    local real, realHeld, unread = {}, {}, {}
    for _, r in ipairs(ROWS) do
        BR.Keys.on(r.action, function(p)
            if liveOf(r.flag) then
                real[#real + 1] = ('%s%d %s %s'):format(phase, frameNo, r.action, tostring(p))
            end
        end, r.flag and function() return flags[r.flag] end or nil)
    end
    flags.a, flags.b, flags.c = false, false, false

    --- Which rows the frame just stepped left unread, as script frame `f`.
    local function noteUnread(f)
        for _, r in ipairs(ROWS) do
            local n = 0
            for _, c in ipairs(r.codes) do n = n + (reads[c] or 0) end
            unread[f .. ' ' .. r.action] = (n == 0)
        end
    end
    frame()
    noteUnread(0)
    local readsReal, readsAll = 0, 0
    for f = 1, N do
        apply(script[f])
        if script[f].focus then
            phase = 'X'
            focus(script[f].focus)
        end
        phase = 'F'
        frame()
        readsReal = readsReal + totalReads()
        realHeld[f] = BR.Keys.isHeld('interact')
        noteUnread(f)
    end

    -- PLAY TWO: the shipped loop, on the same keyboard from the same start.
    for k in pairs(keys) do keys[k] = nil end
    flags.a, flags.b, flags.c = false, false, false
    local m = model()
    local ref, refHeld = {}, {}
    local tag = ''
    local function modelFire(action, p)
        for _, r in ipairs(ROWS) do
            if r.action == action and liveOf(r.flag) then
                ref[#ref + 1] = ('%s %s %s'):format(tag, action, tostring(p))
            end
        end
    end
    for f = 1, N do
        apply(script[f])
        if script[f].focus then
            tag = 'X' .. f
            m.focus(script[f].focus == 'settings', modelFire)
        end
        tag = 'F' .. (f + 1)
        m.frame(modelFire)
        refHeld[f] = m.held.interact == true
        -- What the shipped loop read: every bound row, every frame -- 22 rows,
        -- shift three codes while up and Alt two.
        readsAll = readsAll + 25
    end

    -- THE COMPARISON. Every call the new loop made, the old one made too.
    local refSet = {}
    for _, e in ipairs(ref) do refSet[e] = (refSet[e] or 0) + 1 end
    local extra = {}
    for _, e in ipairs(real) do
        if (refSet[e] or 0) > 0 then refSet[e] = refSet[e] - 1
        else extra[#extra + 1] = e end
    end
    ok(#extra == 0, 'the new loop never acts where the shipped one did not',
       table.concat(extra, '; ', 1, math.min(#extra, 6)))

    -- Every call the shipped loop made that the new one did not must be the one
    -- case: on the first frame its key was read after a frame unread (or, for
    -- a focus call, right after such a frame).
    local allowed, bad = 0, {}
    for e, n in pairs(refSet) do
        for _ = 1, n do
            local kind, fr, action = e:match('^(%u)(%d+) (%S+)')
            fr = tonumber(fr)
            local prev = (kind == 'F') and (fr - 2) or (fr - 1)
            if unread[prev .. ' ' .. action] then
                allowed = allowed + 1
            else
                bad[#bad + 1] = e
            end
        end
    end
    ok(#bad == 0, 'and every call it skipped is a press on the first frame its key '
       .. 'was read again -- the one case, and no other',
       table.concat(bad, '; ', 1, math.min(#bad, 6)))
    ok(#ref > 1000, 'the script exercises the keys', ('%d calls'):format(#ref))
    ok(allowed > 0 and allowed * 20 < #ref,
       'and that case does occur, rarely', ('%d of %d'):format(allowed, #ref))

    local heldDiff = 0
    for f = 1, N do if realHeld[f] ~= refHeld[f] then heldDiff = heldDiff + 1 end end
    ok(heldDiff == 0, 'the interact key reads held on exactly the same frames, every one',
       ('%d frames differ'):format(heldDiff))

    ok(readsReal < readsAll, 'and the new loop read fewer keys',
       ('%d reads against %d'):format(readsReal, readsAll))
    realPrint(('     differential: %d frames, %d listener calls, %d skipped on a '
        .. 'first-read frame, %d of %d raw-key reads'):format(N, #ref, allowed,
        readsReal, readsAll))
end

realPrint(('%s%d passed, %d failed\27[0m')
    :format(fail == 0 and '\27[32m' or '\27[31m', pass, fail))
os.exit(fail == 0 and 0 or 1)
