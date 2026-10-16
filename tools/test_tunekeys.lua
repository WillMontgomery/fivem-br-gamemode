-- Unit tests for the dev tuning tools' shared keys (#404):
-- br_core/client/tunekeys.lua, over the REAL loop registry (client/main.lua)
-- and modeled controls, the clock and the text natives.
--
-- "Any manual adjustment commands must allow keyboard input." (owner,
-- 2026-10-11.) /brlabel, /brshine, /brpropscale, /brgunplate and /brlobbycam
-- all ride this file, so what is pinned here is what every one of them does
-- with a key: a tap is one step, a hold is twenty a second at 30, 60 or 144
-- fps alike and a hitch is not paid back in a burst, SHIFT is the bigger step, a pick and DELETE are once a press, the numbers are
-- on screen every frame, only the keys it reads are claimed and only while it
-- is on, and putting it away prints what to paste. Each tool's own suite pins
-- what its keys move: tools/test_crates_client.lua (the three loot ones),
-- tools/test_gunshop.lua (/brgunplate), tools/test_lobbyseq.lua (/brlobbycam).
--
-- Run via tools/verify.sh, or directly:  lua tools/test_tunekeys.lua

local realPrint = print

-- ------------------------------------------------------------- the engine ---

local now = 1000
function GetGameTimer() return now end
function GetCurrentResourceName() return 'br_core' end
function GetPlayerServerId() return 1 end
function PlayerId() return 0 end
function PlayerPedId() return 7 end
function GetEntityCoords() return { x = 0.0, y = 0.0, z = 0.0 } end
function GetVehiclePedIsIn() return 0 end

local logs = {}
function print(s) logs[#logs + 1] = tostring(s) end

Citizen = { CreateThread = function() end, Wait = function() end }
function AddEventHandler() end

--- What is held, what was claimed this frame, and what was drawn where.
local down, claims, drawn = {}, {}, {}
function IsDisabledControlPressed(_, id) return down[id] and 1 or 0 end
function DisableControlAction(_, id) claims[id] = (claims[id] or 0) + 1 end
for _, n in ipairs({ 'SetTextFont', 'SetTextScale', 'SetTextColour', 'SetTextDropshadow',
                     'SetTextEdge', 'SetTextDropShadow', 'SetTextOutline',
                     'BeginTextCommandDisplayText' }) do
    _G[n] = function() end
end
local pending = nil
function AddTextComponentSubstringPlayerName(s) pending = s end
function EndTextCommandDisplayText(x, y) drawn[#drawn + 1] = { x = x, y = y, s = pending } end

local ROOT = 'resources/[fivem-royale]/'
for _, f in ipairs({
    'br_lib/shared/enums.lua',
    'br_lib/shared/protocol.lua',
    'br_lib/shared/rng.lua',
    'br_lib/shared/geo.lua',
    'br_lib/shared/clock.lua',
    'br_lib/config/match.lua',
    'br_lib/config/storm.lua',
    'br_lib/config/map.lua',
    'br_lib/config/weapons.lua',
    'br_lib/config/loot.lua',
    'br_lib/shared/storm_solve.lua',
    'br_core/client/main.lua',
    'br_core/client/tunekeys.lua',
}) do
    local chunk, err = loadfile(ROOT .. f)
    if not chunk then
        realPrint('\27[31mload error\27[0m ' .. f .. ': ' .. tostring(err))
        os.exit(1)
    end
    chunk()
end

-- ---------------------------------------------------------------- harness ---

local pass, fail = 0, 0
local group = ''
local function describe(n) group = n end
local function ok(cond, name, detail)
    if cond then pass = pass + 1 else
        fail = fail + 1
        realPrint(('\27[31mFAIL\27[0m %s > %s%s'):format(group, name,
            detail and ('\n       ' .. tostring(detail)) or ''))
    end
end
local function eq(got, want, name)
    ok(got == want, name, ('got %s, want %s'):format(tostring(got), tostring(want)))
end

local T = BR.TuneKeys
local K = T.KEY

--- One frame `ms` after the last.
local function frame(ms)
    now = now + (ms or 16)
    claims, drawn = {}, {}
    BR.Loop.step(BR.Loop.FRAME)
end
--- `keys` held for `ms` (frames `step` ms apart), then a frame with none.
local function hold(keys, ms, step)
    down = {}
    for _, k in ipairs(keys) do down[k] = true end
    local t = 0
    repeat
        frame(step or 50)
        t = t + (step or 50)
    until t >= (ms or 1)
    down = {}
    frame(50)
end

local function registered(name)
    for _, e in ipairs(BR.Loop.names()) do
        if e.name == name and e.band == BR.Loop.FRAME then return true end
    end
    return false
end

local function errored()
    for _, l in ipairs(logs) do
        if l:find('errored', 1, true) or l:find('stack traceback', 1, true) then return l end
    end
    return nil
end

--- A tool that records what the keys asked of it.
local function tool(extra)
    local t = { nudges = {}, picks = {}, resets = 0, settles = 0, offs = 0, n = 0 }
    t.spec = {
        lines = function(k)
            t.lastK = k
            return { '~b~test~w~', ('n %d'):format(t.n) }
        end,
        nudge = function(k)
            t.nudges[#t.nudges + 1] = { v = k.v, h = k.h, s = k.s, depth = k.depth,
                                        turn = k.turn, coarse = k.coarse }
            t.n = t.n + k.v + k.h + k.s
            return true
        end,
        settle = function() t.settles = t.settles + 1 end,
        reset = function() t.resets = t.resets + 1 end,
        off = function() t.offs = t.offs + 1; print('[br_core] test: paste me') end,
    }
    for key, v in pairs(extra or {}) do t.spec[key] = v end
    return t
end

-- =========================================================================

describe('the same keys and numbers /brrocket already uses')
do
    -- ONE SHAPE FOR EVERY TOOL. /brrocket's keys are where the owner's hands
    -- already are; a second tool whose PAGE UP is a different control, or whose
    -- hold runs at a different rate, is a tool whose numbers cannot be compared.
    local fh = io.open(ROOT .. 'br_core/client/terminalfx/airstrike.lua', 'rb')
    local src = fh and fh:read('a') or ''
    if fh then fh:close() end
    local list = src:match('local ROCKET_BLOCKED = {([^}]*)}')
    ok(list ~= nil, 'brrocket\'s claimed list is readable')
    local theirs = {}
    for n in (list or ''):gmatch('%d+') do theirs[#theirs + 1] = tonumber(n) end
    eq(table.concat(T.BLOCKED, ','), table.concat(theirs, ','), 'the same keys claimed, in the same order')
    local keys = src:match('local ROCKET_KEY = {(.-)\n}') or ''
    for _, name in ipairs({ 'UP', 'DOWN', 'LEFT', 'RIGHT', 'BIGGER', 'SMALLER', 'RESET',
                            'DEPTH', 'TURN', 'COARSE' }) do
        local id = keys:match('%f[%w]' .. name .. ' = (%d+)')
        eq(K[name], tonumber(id), name .. ' is the same control')
    end
    eq(T.REPEAT_MS, tonumber(src:match('ROCKET_REPEAT_MS = (%d+)')), 'and a hold steps as often')
    eq(T.REPEAT_MS, 50, 'twenty a second')
end

describe('the tools that count their own repeat step on the same beat')
do
    -- /brplate, /brrocket and /brattach predate this file and keep their own
    -- deadline. Counted from the frame that took the step, theirs rounded up
    -- to whole frames exactly as this file's did (its header, ON THE BEAT), so
    -- the two lines that carry it are pinned here in each. /brrocket's is run
    -- at 60 and 30 fps too, in tools/test_terminalstrike.lua.
    for _, c in ipairs({
        { 'br_core/client/revivekey.lua', 'nudgeAt', 'REPEAT_MS' },
        { 'br_core/client/terminalfx/airstrike.lua', 'nudgeAt', 'ROCKET_REPEAT_MS' },
        { 'br_core/client/attachtune.lua', 'S.nextAt', 'REPEAT_MS' },
    }) do
        local fh = io.open(ROOT .. c[1], 'rb')
        local src = fh and fh:read('a') or ''
        if fh then fh:close() end
        src = src:gsub('%-%-[^\n]*', '')
        local at, every = c[2]:gsub('%.', '%%.'), c[3]
        ok(src:find('if now < ' .. at .. ' then return end%s*'
                .. at .. ' = ' .. at .. ' %+ ' .. every .. '%s*'
                .. 'if ' .. at .. ' <= now then ' .. at .. ' = now %+ ' .. every .. ' end') ~= nil,
            c[1]:match('[^/]+$') .. ': the next step is due ' .. every .. ' after this one was, '
                .. 'or from now when that is past')
    end
end

describe('nudged: a step of a number\'s own size, rounded and kept in range')
do
    local row = { fine = 0.01, coarse = 0.10, places = 2, lo = -1.0, hi = 1.0 }
    local v = 0.0
    for _ = 1, 20 do v = T.nudged(v, 1, false, row) end
    eq(v, 0.2, 'twenty steps of 0.01 land on 0.20, not 0.19999')
    eq(T.nudged(0.2, -1, true, row), 0.1, 'SHIFT: a coarse step')
    eq(T.nudged(0.95, 1, true, row), 1.0, 'never past hi')
    eq(T.nudged(-0.95, -1, true, row), -1.0, 'never past lo')
    local n = T.nudged(60, 1, false, { fine = 1, coarse = 10, places = 0, lo = 0, hi = 255 })
    eq(math.type(n), 'integer', 'a whole-number row stays a whole number (it pastes as 61, not 61.0)')
    eq(T.nudged(nil, 1, false, row), 0.01, 'a number that was never set starts from 0')
end

describe('on: one FRAME callback, the keys claimed, the numbers drawn')
do
    local t = tool({ x = 0.7, y = 0.1 })
    ok(not T.on('one'), 'off to start with')
    ok(T.start('one', t.spec), 'start turns it on')
    ok(T.on('one') and registered('tunekeys.one'), 'one FRAME callback, named for the tool')
    frame()
    local all = true
    for _, id in ipairs({ 27, 172, 173, 174, 175, 10, 11, 178 }) do all = all and (claims[id] or 0) > 0 end
    ok(all, 'the arrows, the phone, the page keys and DELETE are claimed while it is on')
    ok(not claims[K.DEPTH] and not claims[K.TURN] and not claims[K.COARSE]
        and not claims[30] and not claims[31] and not claims[32] and not claims[1] and not claims[2],
        'CTRL, ALT, SHIFT, walking and the mouse are not')
    eq(#drawn, 2, 'the readout, every frame')
    ok(drawn[1] and drawn[1].x == 0.7 and drawn[1].y == 0.1 and drawn[1].s == '~b~test~w~',
        'where the tool asked for it')
    ok(drawn[2] and math.abs(drawn[2].y - 0.126) < 1e-9, 'a line apart (/brplate\'s spacing)')
    frame()
    eq(#drawn, 2, 'and the next frame too')
    ok(not T.start('one', t.spec), 'start again while on: nothing more')
    eq(errored(), nil, 'and no second callback under the same name')

    -- A TAP IS ONE STEP.
    hold({ K.UP }, 1)
    eq(#t.nudges, 1, 'UP tapped: one step')
    ok(t.nudges[1].v == 1 and t.nudges[1].h == 0 and t.nudges[1].s == 0, 'up, and nothing else')
    hold({ K.DOWN }, 1)
    eq(t.nudges[2] and t.nudges[2].v, -1, 'DOWN: down')
    hold({ K.RIGHT }, 1)
    hold({ K.LEFT }, 1)
    ok(t.nudges[3].h == 1 and t.nudges[4].h == -1, 'RIGHT and LEFT: across')
    hold({ K.BIGGER }, 1)
    hold({ K.SMALLER }, 1)
    ok(t.nudges[5].s == 1 and t.nudges[6].s == -1, 'PAGE UP and PAGE DOWN: the size')

    -- A HOLD IS TWENTY A SECOND, WHATEVER THE FRAME RATE. 40 and 100 fps
    -- divide 50 ms evenly and pass either way; 60, 30 and 144 are the ones a
    -- deadline counted from the frame gets wrong (16, 16 and 18).
    for _, r in ipairs({ { 25, '40 fps' }, { 10, '100 fps' }, { 16, '60 fps (16 ms frames)' },
                         { 17, '60 fps (17 ms frames)' }, { 33, '30 fps' }, { 7, '144 fps' },
                         { 20, '50 fps' }, { 40, '25 fps' } }) do
        t.nudges = {}
        hold({ K.UP }, 1000, r[1])
        eq(#t.nudges, 20, ('UP held a second at %s: 20 steps'):format(r[2]))
    end
    t.nudges = {}
    hold({ K.UP }, 1000, 60)
    eq(#t.nudges, 17, 'and below 20 fps, one a frame: never two in one')

    -- A HITCH IS NOT PAID BACK IN A BURST: a deadline already behind the clock
    -- starts again from now.
    t.nudges = {}
    down = { [K.UP] = true }
    for _ = 1, 10 do frame(16) end
    local before = #t.nudges
    frame(1000)
    eq(#t.nudges - before, 1, 'a second-long frame mid-hold: one step')
    local after = #t.nudges
    for _ = 1, 6 do frame(16) end
    eq(#t.nudges - after, 1, 'and in the 96 ms after it, one more on the beat, not one a frame')
    down = {}
    frame(50)

    -- LET GO AND PRESS AGAIN SOONER THAN A REPEAT: STILL A STEP, because
    -- letting go clears the wait.
    t.nudges = {}
    down = { [K.UP] = true }; frame(16)
    down = {}; frame(16)
    down = { [K.UP] = true }; frame(16)
    down = {}; frame(16)
    eq(#t.nudges, 2, 'two taps 32 ms apart: two steps')

    -- THE MODIFIERS GO WITH THE STEP.
    t.nudges = {}
    hold({ K.COARSE, K.UP }, 1)
    hold({ K.DEPTH, K.UP }, 1)
    hold({ K.TURN, K.UP }, 1)
    ok(t.nudges[1].coarse and not t.nudges[1].depth, 'SHIFT: the bigger step')
    ok(t.nudges[2].depth and not t.nudges[2].coarse, 'CTRL: depth')
    ok(t.nudges[3].turn and not t.nudges[3].depth, 'ALT: turn')
    ok(t.lastK and t.lastK.v == 0, 'and the readout is told what is held too')

    -- SETTLED ONCE THE KEYS COME UP.
    t.settles = 0
    down = { [K.UP] = true }
    frame(50); frame(50); frame(50)
    eq(t.settles, 0, 'not while a key is held')
    down = {}
    frame(50)
    eq(t.settles, 1, 'once when it comes up')
    frame(50)
    eq(t.settles, 1, 'and only once')

    -- DELETE, ONCE A PRESS.
    hold({ K.RESET }, 500)
    eq(t.resets, 1, 'DELETE held: one reset')
    eq(t.settles, 2, 'settled once it is let go')
    hold({ K.RESET }, 1)
    eq(t.resets, 2, 'and another press, another')

    -- PUT AWAY.
    logs = {}
    ok(T.stop('one'), 'stop puts it away')
    eq(t.offs, 1, 'its off ran once')
    ok((logs[#logs] or ''):find('paste me', 1, true) ~= nil, 'and printed what to paste')
    ok(not T.on('one'), 'off')
    down = { [K.RIGHT] = true, [K.UP] = true }
    frame()
    down = {}
    ok(next(claims) == nil, 'and the arrows are the player\'s again on the next frame')
    eq(#drawn, 0, 'nothing drawn')
    frame()
    ok(not registered('tunekeys.one'), 'nothing per frame')
    ok(not T.stop('one'), 'stop again: it was not on')
    eq(t.offs, 1, 'and nothing printed twice')

    -- AND ON AGAIN, UNDER THE SAME NAME.
    ok(T.start('one', t.spec) and registered('tunekeys.one'), 'on again')
    T.stop('one')
    frame()
    eq(errored(), nil, 'no callback errored')
end

describe('a tool with a list picks with LEFT / RIGHT, once a press')
do
    local t = tool()
    t.spec.pick = function(d) t.picks[#t.picks + 1] = d end
    T.start('list', t.spec)
    hold({ K.RIGHT }, 1000, 25)
    eq(#t.picks, 1, 'RIGHT held a second: one pick')
    eq(t.picks[1], 1, 'the next')
    hold({ K.LEFT }, 1)
    eq(t.picks[2], -1, 'LEFT: the one before')
    eq(#t.nudges, 0, 'and neither nudged anything')
    hold({ K.UP }, 1)
    ok(#t.nudges == 1 and t.nudges[1].h == 0, 'UP still nudges')
    t.settles = 0
    hold({ K.RIGHT }, 1)
    eq(t.settles, 0, 'and a pick alone has nothing to settle')
    T.stop('list')
end

describe('a nudge that moved nothing has nothing to settle')
do
    local t = tool()
    t.spec.nudge = function() return false end
    T.start('idle', t.spec)
    hold({ K.LEFT }, 1)
    eq(t.settles, 0, 'not settled')
    T.stop('idle')
    eq(t.settles, 0, 'not even when put away')
end

describe('a key still held when it is put away: settled, then put away')
do
    local t = tool()
    T.start('cut', t.spec)
    down = { [K.BIGGER] = true }
    frame(50)
    T.stop('cut')
    down = {}
    eq(t.settles, 1, 'the change is settled')
    eq(t.offs, 1, 'and the paste line printed')
end

describe('one at a time')
do
    local a, b = tool(), tool()
    T.start('a', a.spec)
    logs = {}
    T.start('b', b.spec)
    ok(not T.on('a') and T.on('b'), 'turning one on puts the other away')
    eq(a.offs, 1, 'with its paste line, as if it had been turned off')
    frame()
    hold({ K.UP }, 1)
    ok(#a.nudges == 0 and #b.nudges == 1, 'and only the one that is on moves')
    T.stop('b')
    frame()
    ok(not registered('tunekeys.a') and not registered('tunekeys.b'), 'and nothing is left per frame')
    eq(errored(), nil, 'no callback errored')
end

-- ----------------------------------------------------------------- result ---

print = realPrint
io.write(('%s%d passed%s'):format('\27[32m', pass, '\27[0m'))
if fail > 0 then
    io.write(('  %s%d failed%s\n'):format('\27[31m', fail, '\27[0m'))
    os.exit(1)
end
io.write('\n')
