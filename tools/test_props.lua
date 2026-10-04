-- Unit tests for /brprop, the dev props (#384).
--
-- Owner, 2026-10-03: "I want a way to spawn them in ... something akin to our
-- pickups where it hovers/bobs/rotates when close, and I need a way to interact
-- with it manually like moving in every direction, and rotating. Be sure the
-- server spawns it since clients can't."
--
-- ═══ WHAT A PLAYTEST CANNOT TELL APART, AND THIS CAN ═══
--
-- Almost every failure of this feature looks like "the prop did not do what I
-- pressed". A step that went the wrong way at one camera angle, a coarse step
-- that is secretly the fine one, a rate limit that drops the confirm, a cancel
-- that puts the prop back on this screen and nowhere else, a refusal nobody
-- prints, a model held resident forever -- from a chair they are one symptom.
-- Each is a few lines here.
--
--   PART A  br_lib/shared/props_solve.lua -- the rules and the arithmetic, with
--           no natives: names, angles, the world box, the placement rule, every
--           edit axis at both step sizes and several camera angles, the key
--           repeat, the send throttle, and the pickup look off the LOOT's own
--           numbers.
--   PART B  br_core/server/props.lua behind the REAL br_lib/shared/devgate.lua
--           -- the `brpropsv` command refused with dev mode off and run with it
--           on for a player holding no grant; the refusals, ids, the broadcast
--           and the late joiner's full list, the move rate limit, save ->
--           restart -> load; and the edit session, the only door the edit
--           stream has, opened by the command and closed on every way out.
--   PART C  br_core/client/props.lua over the REAL client/keybinds.lua -- the
--           copy lifecycle (spawn, replace, delete, display), model refusal and
--           release, the hover as drawn, every request run as `brpropsv`, the
--           edit starting only on the server's answer, the edit keys read
--           through the raw layer at both step sizes, throttled sends, confirm
--           and cancel, and cleanup on resource stop.
--   PART D  the exact lines PART C's client ran, typed into PART B's server.
--
-- Run via tools/verify.sh, or directly:  lua tools/test_props.lua

local realPrint = print
local ROOT = 'resources/[fivem-royale]/'

local function loadAll(files)
    for _, f in ipairs(files) do
        local chunk, err = loadfile(ROOT .. f)
        if not chunk then
            realPrint('\27[31mload error\27[0m ' .. f .. ': ' .. tostring(err))
            os.exit(1)
        end
        chunk()
    end
end

-- ---------------------------------------------------------------- harness ---

local pass, fail = 0, 0
local group = ''

local function describe(name) group = name end

local function ok(cond, name, detail)
    if cond then
        pass = pass + 1
    else
        fail = fail + 1
        realPrint(('\27[31mFAIL\27[0m %s > %s%s'):format(group, name,
            detail and ('\n       ' .. tostring(detail)) or ''))
    end
end

local function eq(got, want, name)
    ok(got == want, name, ('got %s, want %s'):format(tostring(got), tostring(want)))
end

local function near(a, b, tol)
    return type(a) == 'number' and type(b) == 'number'
        and math.abs(a - b) <= (tol or 1e-6)
end

local function close(got, want, name, tol)
    ok(near(got, want, tol), name, ('got %s, want %s'):format(tostring(got), tostring(want)))
end

-- A REAL JSON, small. The save file is a string on disk, and a round trip
-- through a fake that hands the table straight back would prove nothing about
-- whether a float or an id survives being written down.
local function jsonEncode(v)
    local t = type(v)
    if t == 'nil' then return 'null' end
    if t == 'boolean' then return tostring(v) end
    if t == 'number' then
        if v ~= v or v == math.huge or v == -math.huge then error('non-finite number') end
        if math.type(v) == 'integer' then return tostring(v) end
        return ('%.17g'):format(v)
    end
    if t == 'string' then
        return '"' .. (v:gsub('[%c"\\]', function(c)
            return ('\\u%04x'):format(c:byte())
        end)) .. '"'
    end
    if t == 'table' then
        if #v > 0 or next(v) == nil then
            local parts = {}
            for i = 1, #v do parts[i] = jsonEncode(v[i]) end
            return '[' .. table.concat(parts, ',') .. ']'
        end
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        local parts = {}
        for _, k in ipairs(keys) do
            parts[#parts + 1] = jsonEncode(tostring(k)) .. ':' .. jsonEncode(v[k])
        end
        return '{' .. table.concat(parts, ',') .. '}'
    end
    error('cannot encode ' .. t)
end

local function jsonDecode(s)
    local i = 1
    local function ws() i = s:find('[^ \t\r\n]', i) or (#s + 1) end
    local value
    local function str()
        i = i + 1
        local out = {}
        while true do
            local c = s:sub(i, i)
            if c == '' then error('unterminated string') end
            if c == '"' then i = i + 1; break end
            if c == '\\' then
                local n = s:sub(i + 1, i + 1)
                if n == 'u' then
                    out[#out + 1] = string.char(tonumber(s:sub(i + 2, i + 5), 16))
                    i = i + 6
                else
                    out[#out + 1] = ({ n = '\n', t = '\t', r = '\r' })[n] or n
                    i = i + 2
                end
            else
                out[#out + 1] = c
                i = i + 1
            end
        end
        return table.concat(out)
    end
    function value()
        ws()
        local c = s:sub(i, i)
        if c == '{' then
            i = i + 1
            local o = {}
            ws()
            if s:sub(i, i) == '}' then i = i + 1; return o end
            while true do
                ws()
                if s:sub(i, i) ~= '"' then error('bad key at ' .. i) end
                local k = str()
                ws()
                if s:sub(i, i) ~= ':' then error('missing colon at ' .. i) end
                i = i + 1
                o[k] = value()
                ws()
                local d = s:sub(i, i)
                i = i + 1
                if d == '}' then return o end
                if d ~= ',' then error('bad object at ' .. i) end
            end
        elseif c == '[' then
            i = i + 1
            local a = {}
            ws()
            if s:sub(i, i) == ']' then i = i + 1; return a end
            while true do
                a[#a + 1] = value()
                ws()
                local d = s:sub(i, i)
                i = i + 1
                if d == ']' then return a end
                if d ~= ',' then error('bad array at ' .. i) end
            end
        elseif c == '"' then
            return str()
        elseif s:sub(i, i + 3) == 'true' then
            i = i + 4; return true
        elseif s:sub(i, i + 4) == 'false' then
            i = i + 5; return false
        elseif s:sub(i, i + 3) == 'null' then
            i = i + 4; return nil
        else
            local num = s:match('^-?%d+%.?%d*[eE]?[-+]?%d*', i)
            if not num or num == '' then error('unexpected ' .. c .. ' at ' .. i) end
            i = i + #num
            return tonumber(num)
        end
    end
    local v = value()
    ws()
    if i <= #s then error('trailing data at ' .. i) end
    return v
end

json = { encode = jsonEncode, decode = jsonDecode }

-- =========================================================================
-- PART A -- the rules and the arithmetic
-- =========================================================================

BR = nil
loadAll({
    'br_lib/shared/enums.lua',
    'br_lib/shared/protocol.lua',
    'br_lib/shared/polygon.lua',
    'br_lib/config/map.lua',
    'br_lib/config/loot.lua',
    'br_lib/config/props.lua',
    'br_lib/shared/props_solve.lua',
})

local S = BR.PropSolve
local P = BR.Config.Props
local LOOT = BR.Config.Loot

-- Two fixed places, checked against the REAL surveyed boundary rather than
-- assumed: one on the island, one out at sea.
local INSIDE  = { x = 200.0, y = -900.0, z = 30.0 }
local OUTSIDE = { x = -3500.0, y = -3500.0, z = 2.0 }

describe('the fixtures stand where they claim to')
do
    ok(BR.Config.Map.InBounds(INSIDE.x, INSIDE.y) == true, 'INSIDE is inside the boundary')
    ok(BR.Config.Map.InBounds(OUTSIDE.x, OUTSIDE.y) == false, 'OUTSIDE is outside it')
end

describe('a model name is an archetype name and nothing else')
do
    eq(S.modelName('prop_box_wood05a', P), 'prop_box_wood05a', 'a stock prop name passes')
    eq(S.modelName('BR_Crate-v2', P), 'br_crate-v2', 'letters, digits, _ and - pass, lower-cased')
    eq(S.modelName(string.rep('a', P.nameMaxLen), P), string.rep('a', P.nameMaxLen),
        'exactly the length cap passes')
    ok(S.modelName(string.rep('a', P.nameMaxLen + 1), P) == nil, 'one over the cap is refused')
    for _, bad in ipairs({ '', 'two words', 'a/b', '../x', 'a.b', "x'y", 'x"y', 'a;b',
                           'tab\there', 'nl\nhere', 'é' }) do
        ok(S.modelName(bad, P) == nil, ('%q is refused'):format(bad))
    end
    ok(S.modelName(nil, P) == nil, 'nil is refused')
    ok(S.modelName(12345, P) == nil, 'a number is refused')
    local _, why = S.modelName('a b', P)
    ok(type(why) == 'string' and why ~= '', 'and a refusal says why')
    eq(P.nameMaxLen, 64, 'the cap is 64 characters')
end

describe('display is pickup or static, pickup by default')
do
    eq(S.display(nil), 'pickup', 'nothing given is pickup')
    eq(S.display('pickup'), 'pickup', 'pickup')
    eq(S.display('STATIC'), 'static', 'static, any case')
    ok(S.display('floating') == nil, 'anything else is refused')
    ok(S.display(5) == nil, 'a number is refused')
end

describe('every stored angle is folded into (-180, 180]')
do
    eq(S.angle(370), 10.0, '370 is 10')
    eq(S.angle(-190), 170.0, '-190 is 170')
    eq(S.angle(180), 180.0, '180 stays 180')
    eq(S.angle(-180), 180.0, '-180 is 180')
    eq(S.angle(540), 180.0, '540 is 180')
    eq(S.angle(359), -1.0, '359 is -1')
    eq(S.angle(0), 0.0, '0 is 0')
end

describe('a transform is six real numbers inside the world')
do
    local t = S.transform({ x = 1.5, y = -2.5, z = 30.0, yaw = 450.0 }, P)
    ok(t ~= nil, 'a plain position passes')
    eq(t and t.yaw, 90.0, 'the yaw is folded')
    eq(t and t.pitch, 0.0, 'a missing pitch is zero')
    eq(t and t.roll, 0.0, 'a missing roll is zero')

    local nan, inf = 0 / 0, math.huge
    local bads = {
        { 'no x', { y = 0, z = 0 } },
        { 'a NaN x', { x = nan, y = 0, z = 0 } },
        { 'an infinite y', { x = 0, y = inf, z = 0 } },
        { 'a string z', { x = 0, y = 0, z = '30' } },
        { 'a NaN yaw', { x = 0, y = 0, z = 0, yaw = nan } },
        { 'an infinite pitch', { x = 0, y = 0, z = 0, pitch = -inf } },
        -- +inf AS WELL AS -inf, and on an ANGLE: a position is caught again by
        -- the world box, a rotation by nothing else -- inf % 360 is NaN, and a
        -- NaN yaw would be stored, broadcast and saved.
        { 'an infinite yaw', { x = 0, y = 0, z = 0, yaw = inf } },
        { 'a string roll', { x = 0, y = 0, z = 0, roll = '1' } },
        { 'x past the world', { x = P.world.xy + 1, y = 0, z = 0 } },
        { 'x past the world, westward', { x = -P.world.xy - 1, y = 0, z = 0 } },
        { 'y past the world', { x = 0, y = -P.world.xy - 1, z = 0 } },
        { 'y past the world, northward', { x = 0, y = P.world.xy + 1, z = 0 } },
        { 'z below it', { x = 0, y = 0, z = P.world.zMin - 1 } },
        { 'z above it', { x = 0, y = 0, z = P.world.zMax + 1 } },
    }
    for _, b in ipairs(bads) do
        ok(S.transform(b[2], P) == nil, b[1] .. ' is refused')
    end
    ok(S.transform({ x = P.world.xy, y = -P.world.xy, z = P.world.zMax }, P) ~= nil,
        'the world edge itself passes')
    ok(S.transform(nil, P) == nil, 'no table is refused')
end

describe('a prop goes inside the boundary, or near whoever asked')
do
    local IB = BR.Config.Map.InBounds
    ok(S.placeOk(INSIDE, nil, IB, P), 'inside the boundary passes with nobody near')
    ok(S.placeOk(INSIDE, OUTSIDE, IB, P), 'inside passes wherever the requester is')
    local justIn = { x = OUTSIDE.x + P.nearM - 0.01, y = OUTSIDE.y, z = OUTSIDE.z }
    local justOut = { x = OUTSIDE.x + P.nearM + 0.01, y = OUTSIDE.y, z = OUTSIDE.z }
    ok(S.placeOk(justIn, OUTSIDE, IB, P), 'outside the boundary, just inside nearM, passes')
    ok(not S.placeOk(justOut, OUTSIDE, IB, P), 'and just past nearM is refused')
    local up = { x = OUTSIDE.x, y = OUTSIDE.y, z = OUTSIDE.z + P.nearM + 1 }
    ok(not S.placeOk(up, OUTSIDE, IB, P), 'nearM is a 3-D distance: straight up counts')
    ok(not S.placeOk(OUTSIDE, nil, IB, P), 'outside with no known requester is refused')

    -- A REAL POSITION IS A vector3, and type() of one is 'vector3' in CfxLua.
    -- Stood in for here by answering 'vector3' for one table: a table-only
    -- guard refused every real position, so every edit off the island failed.
    do
        local VEC = { x = OUTSIDE.x, y = OUTSIDE.y, z = OUTSIDE.z }
        local realType = type
        type = function(v) if v == VEC then return 'vector3' end return realType(v) end
        local okVec = S.placeOk(justIn, VEC, IB, P)
        type = realType
        ok(okVec, 'a requester position that is a vector3 counts, not only a table')
    end
    ok(not S.placeOk(OUTSIDE, { x = 0 / 0, y = 0, z = 0 }, IB, P),
        'a NaN requester position is no position')
    ok(not S.placeOk(OUTSIDE, nil, function() return 1 end, P),
        'a boundary test answering 1 is not a yes')
    local _, why = S.placeOk(OUTSIDE, nil, IB, P)
    ok(type(why) == 'string' and why:find('150') ~= nil, 'the refusal names the distance', why)
end

describe('every edit axis, at both step sizes, from several camera angles')
do
    local base = { x = 10.0, y = 20.0, z = 30.0, pitch = 5.0, roll = -5.0, yaw = 45.0 }
    for _, coarse in ipairs({ false, true }) do
        local m = coarse and P.step.coarse.m or P.step.fine.m
        local deg = coarse and P.step.coarse.deg or P.step.fine.deg
        local size = coarse and 'coarse' or 'fine'
        for _, cam in ipairs({ 0.0, 90.0, 180.0, -90.0, 37.0 }) do
            local h = math.rad(cam)
            local fx, fy = -math.sin(h), math.cos(h)
            local rx, ry = math.cos(h), math.sin(h)
            local want = {
                fwd   = { fx * m, fy * m, 0 },
                back  = { -fx * m, -fy * m, 0 },
                right = { rx * m, ry * m, 0 },
                left  = { -rx * m, -ry * m, 0 },
                up    = { 0, 0, m },
                down  = { 0, 0, -m },
            }
            for action, d in pairs(want) do
                local n = S.move(base, action, cam, coarse, P)
                local tag = ('%s %s at camera %g'):format(size, action, cam)
                ok(near(n.x - base.x, d[1], 1e-9) and near(n.y - base.y, d[2], 1e-9)
                   and near(n.z - base.z, d[3], 1e-9), tag .. ' moves by the step',
                   ('dx %.4f dy %.4f dz %.4f'):format(n.x - base.x, n.y - base.y, n.z - base.z))
                ok(n.pitch == base.pitch and n.roll == base.roll and n.yaw == base.yaw,
                    tag .. ' turns nothing')
            end
        end
        local rot = {
            yawLeft = { 'yaw', deg }, yawRight = { 'yaw', -deg },
            pitchUp = { 'pitch', deg }, pitchDown = { 'pitch', -deg },
            rollRight = { 'roll', deg }, rollLeft = { 'roll', -deg },
        }
        for action, d in pairs(rot) do
            local n = S.move(base, action, 123.0, coarse, P)
            close(n[d[1]] - base[d[1]], d[2], ('%s %s turns %s by %g'):format(size, action, d[1], d[2]))
            ok(n.x == base.x and n.y == base.y and n.z == base.z, ('%s %s moves nothing'):format(size, action))
            for _, other in ipairs({ 'pitch', 'roll', 'yaw' }) do
                if other ~= d[1] then
                    eq(n[other], base[other], ('%s %s leaves %s alone'):format(size, action, other))
                end
            end
        end
    end

    -- The two named examples, so the convention is readable as well as pinned.
    local n = S.move({ x = 0, y = 0, z = 0, pitch = 0, roll = 0, yaw = 0 }, 'fwd', 0.0, false, P)
    close(n.y, 0.01, 'camera north (0): W pushes north (+y)')
    n = S.move({ x = 0, y = 0, z = 0, pitch = 0, roll = 0, yaw = 0 }, 'fwd', 90.0, false, P)
    close(n.x, -0.01, 'camera west (90): W pushes west (-x)')
    n = S.move({ x = 0, y = 0, z = 0, pitch = 0, roll = 0, yaw = 0 }, 'right', 90.0, false, P)
    close(n.y, 0.01, 'camera west (90): D pushes north (+y)')

    eq(P.step.fine.m, 0.01, 'fine is 1 cm')
    eq(P.step.fine.deg, 1.0, 'and 1 degree')
    eq(P.step.coarse.m, 0.10, 'coarse is 10 cm')
    eq(P.step.coarse.deg, 15.0, 'and 15 degrees')

    local w = S.move({ x = 0, y = 0, z = 0, pitch = 0, roll = 0, yaw = 175.0 }, 'yawLeft', 0, true, P)
    eq(w.yaw, -170.0, 'a turn past 180 folds')
    local src = { x = 1, y = 2, z = 3, pitch = 4, roll = 5, yaw = 6 }
    S.move(src, 'fwd', 0, true, P)
    ok(src.x == 1 and src.y == 2 and src.z == 3, 'the input transform is never changed')

    local r = S.resetRotation({ x = 1, y = 2, z = 3, pitch = 4, roll = 5, yaw = 6 })
    ok(r.x == 1 and r.y == 2 and r.z == 3 and r.pitch == 0 and r.roll == 0 and r.yaw == 0,
        'reset rotation zeroes all three and keeps the position')
end

describe('a tap is one step, a hold repeats at a rate, a hitch does not burst')
do
    local st = {}
    ok(S.repeatFire(st, true, 1000, P), 'the press steps at once')
    ok(not S.repeatFire(st, true, 1100, P), 'and not again before the delay')
    ok(not S.repeatFire(st, false, 1120, P), 'release steps nothing')
    ok(S.repeatFire(st, true, 1130, P), 'and the next press steps at once')

    st = {}
    local steps = 0
    for t = 0, 1000, 10 do
        if S.repeatFire(st, true, t, P) then steps = steps + 1 end
    end
    eq(steps, 17, 'a one-second hold: 1 + one per 50 ms from 250 ms to 1000 ms')

    st = {}
    S.repeatFire(st, true, 0, P)
    S.repeatFire(st, true, 260, P)
    local burst = 0
    if S.repeatFire(st, true, 5000, P) then burst = burst + 1 end
    if S.repeatFire(st, true, 5001, P) then burst = burst + 1 end
    eq(burst, 1, 'a five-second frame is one step, not ninety')
    eq(P.repeatDelayMs, 250, 'the repeat waits 250 ms')
    eq(P.repeatMs, 50, 'then steps every 50 ms')
end

describe('edit updates are sent at most 10 a second')
do
    ok(S.sendDue(nil, 0, P.sendHz), 'the first goes at once')
    ok(not S.sendDue(1000, 1099, P.sendHz), '99 ms later is too soon')
    ok(S.sendDue(1000, 1100, P.sendHz), '100 ms later is due')
    eq(P.sendHz, 10, 'and the rate is 10 Hz')
end

describe('the pickup look reads the loot pickup\'s own numbers')
do
    -- THE NAMES THE PROP READS ARE THE LOOT'S REAL FIELDS. A renamed loot key
    -- would otherwise leave the prop on its fallback numbers, looking nearly
    -- right and drifting from the loot forever.
    local KEYS = { 'promptDistance', 'hoverHeight', 'hoverRiseMs', 'hoverFallMs',
                   'bobAmplitude', 'bobPeriodMs', 'spinDegPerSec', 'hoverPitch' }
    for _, k in ipairs(KEYS) do
        ok(type(LOOT[k]) == 'number', ('BR.Config.Loot.%s exists'):format(k))
    end

    -- A full rise, near, at a moment the bob is at zero.
    local st = {}
    local t = 0
    local rise = LOOT.hoverRiseMs
    local z, pitch, off, k
    for _ = 1, 100 do
        t = t + rise / 50
        z, pitch, off, k = S.hover(st, 90.0, 0.0, rise / 50, t, LOOT)
    end
    eq(k, 1.0, 'near for longer than hoverRiseMs: fully lifted')
    local bob = math.sin(t / LOOT.bobPeriodMs * math.pi * 2.0) * LOOT.bobAmplitude
    close(z, LOOT.hoverHeight + bob, 'the height is hoverHeight plus the bob', 1e-9)
    close(pitch, 90.0 + LOOT.hoverPitch,
        "the pitch tilts by hoverPitch from the prop's own, not toward it", 1e-9)

    -- Each number, changed on its own, changes what is drawn.
    local function sample(L)
        local s = {}
        local out = {}
        local tt = 0
        for i = 1, 12 do
            tt = tt + 40
            local a, b, c, d = S.hover(s, 30.0, (i < 9) and 1.0 or 100.0, 40, tt + 333, L)
            out[#out + 1] = ('%.6f/%.6f/%.6f/%.6f'):format(a, b, c, d)
        end
        return table.concat(out, ' ')
    end
    local base = sample(LOOT)
    for _, key in ipairs(KEYS) do
        local L2 = {}
        for kk, vv in pairs(LOOT) do L2[kk] = vv end
        L2[key] = (key == 'promptDistance') and 0.5 or (LOOT[key] * 1.7 + 3)
        ok(sample(L2) ~= base, ('changing BR.Config.Loot.%s changes the hover'):format(key))
    end

    -- Half the rise time, from rest, is half the lift: the rise is hoverRiseMs.
    local L3 = { promptDistance = 10, hoverHeight = 2.0, hoverRiseMs = 1000,
                 hoverFallMs = 400, bobAmplitude = 0.0, bobPeriodMs = 1000,
                 spinDegPerSec = 90.0, hoverPitch = 0.0 }
    st = {}
    local z1, k1
    for i = 1, 5 do z1, _, _, k1 = S.hover(st, 0.0, 1.0, 100, 1000 + i * 100, L3) end
    close(st.lift, 0.5, 'half of hoverRiseMs is half the lift')
    close(k1, S.ease(0.5), 'and the height follows the eased lift')
    close(z1, 2.0 * S.ease(0.5), 'scaled by hoverHeight')
    for i = 6, 10 do S.hover(st, 0.0, 1.0, 100, 1000 + i * 100, L3) end
    local _, _, off0 = S.hover(st, 0.0, 1.0, 0, 2000, L3)
    local offFull
    for i = 1, 10 do _, _, offFull = S.hover(st, 0.0, 1.0, 100, 2000 + i * 100, L3) end
    close(S.angle(offFull - off0), 90.0,
        'fully lifted, the spin is spinDegPerSec: a second turns it 90 degrees', 1e-6)

    -- A HITCH IS CLAMPED to 100 ms, as loot.render clamps it.
    st = {}
    S.hover(st, 0.0, 1.0, 5000, 9000, L3)
    close(st.lift, 0.1, 'a five-second frame lifts by 100 ms, not to the top')

    -- Outside prompt range nothing moves at all.
    st = {}
    local zf, pf, of, kf = S.hover(st, 12.0, 11.0 * 11.0, 100, 777, L3)
    ok(zf == 0 and pf == 12.0 and of == 0 and kf == 0, 'out of range: at rest, exactly')

    -- THE SPIN UNWINDS AS IT SETTLES, so rest is the record's own yaw.
    st = {}
    for _ = 1, 30 do S.hover(st, 0.0, 1.0, 100, 0, L3) end
    local spun = math.abs(st.off)
    ok(spun > 10, 'spinning near it', spun)
    local worst = 0
    local inStep = true
    for _ = 1, 8 do
        local _, _, o, kk = S.hover(st, 0.0, 999.0, 50, 0, L3)
        if math.abs(o) > worst then worst = math.abs(o) end
        -- IN STEP WITH THE FALL: the offset left is the lift left, so it
        -- glides home with the height rather than holding and then snapping.
        if not near(math.abs(o), spun * kk, 1e-9) then inStep = false end
    end
    ok(inStep, 'the offset shrinks in step with the lift, frame by frame')
    local _, _, oEnd, kEnd = S.hover(st, 0.0, 999.0, 50, 0, L3)
    eq(kEnd, 0.0, 'after hoverFallMs the lift is gone')
    eq(oEnd, 0.0, 'and the yaw is back on the record exactly')
    ok(worst <= spun + 1e-9, 'never turning further away on the way down')
    ok(spun <= 180.0, 'and never more than half a turn to undo')
end

describe('a save row is checked like a request, against the world only')
do
    local r = S.fromRow({ model = 'PROP_X', display = 'static', x = OUTSIDE.x, y = OUTSIDE.y,
                          z = OUTSIDE.z, pitch = 1, roll = 2, yaw = 370 }, P)
    ok(r ~= nil and r.model == 'prop_x' and r.display == 'static' and r.yaw == 10,
        'a good row passes, far from anybody')
    ok(S.fromRow({ model = 'a b', x = 0, y = 0, z = 0 }, P) == nil, 'a bad name is refused')
    ok(S.fromRow({ model = 'a', display = 'x', x = 0, y = 0, z = 0 }, P) == nil, 'a bad display')
    ok(S.fromRow({ model = 'a', x = 0, y = 0 }, P) == nil, 'a missing z')
    ok(S.fromRow({ model = 'a', x = 1e9, y = 0, z = 0 }, P) == nil, 'outside the world')
    ok(S.fromRow('row', P) == nil, 'not a table')
end

describe('the where line is Lua that pastes back to the same prop')
do
    local rec = { id = 7, model = 'prop_x', display = 'pickup', x = 123.4564, y = -5.5,
                  z = 30.25, pitch = 10, roll = -20.0, yaw = 90 }
    local line = S.whereLine(rec)
    eq(line, "{ model = 'prop_x', display = 'pickup', x = 123.456, y = -5.500, z = 30.250, "
        .. 'pitch = 10.0, roll = -20.0, yaw = 90.0 },', 'the exact line')
    local chunk = load('return ' .. line:sub(1, -2))
    local back = chunk and chunk()
    ok(back ~= nil and back.model == 'prop_x' and near(back.x, 123.456)
       and back.yaw == 90.0 and back.display == 'pickup', 'and it parses back')
    ok(line:find('id') == nil, 'no session id in it')
end

-- =========================================================================
-- PART B -- the server
-- =========================================================================

local handlers, toClient, consoleLines, files, roster, svCommands, svConvars, jobs, adminAsked
local clock = 100000

local function bootServer(opts)
    opts = opts or {}
    BR = nil
    handlers, toClient, consoleLines, svCommands, jobs = {}, {}, {}, {}, {}
    files = opts.files or {}
    svConvars = { sv_devMode = (opts.devMode == false) and 'false' or 'true' }
    adminAsked = 0
    roster = {
        [1] = { pos = { x = INSIDE.x, y = INSIDE.y, z = INSIDE.z } },
        [2] = { pos = { x = OUTSIDE.x, y = OUTSIDE.y, z = OUTSIDE.z } },
        [3] = { pos = { x = INSIDE.x, y = INSIDE.y, z = INSIDE.z } },
    }

    function GetGameTimer() return clock end
    function GetCurrentResourceName() return 'br_core' end
    function IsDuplicityVersion() return true end
    function GetConvar(n, d)
        local v = svConvars[n]
        if v == nil then return d end
        return v
    end
    -- The native, as devgate.lua finds it: what it registers, and whether
    -- restricted, so the test reads what the server would really be handed.
    function RegisterCommand(name, fn, restricted)
        svCommands[name] = { fn = fn, restricted = restricted }
    end
    function RegisterNetEvent() end
    function AddEventHandler(name, fn)
        handlers[name] = handlers[name] or {}
        table.insert(handlers[name], fn)
    end
    function TriggerClientEvent(name, target, data)
        toClient[#toClient + 1] = { name = name, target = target, data = data }
    end
    function SaveResourceFile(res, name, body)
        if opts.saveFails then return false end
        files[res .. '/' .. name] = body
        return true
    end
    function LoadResourceFile(res, name) return files[res .. '/' .. name] end
    print = function(s) consoleLines[#consoleLines + 1] = tostring(s) end

    -- THE REAL DEV GATE FIRST, as br_core's manifest loads it: the command is
    -- registered through its wrap, so dev mode off is tested, not assumed.
    loadAll({
        'br_lib/shared/devgate.lua',
        'br_lib/shared/enums.lua',
        'br_lib/shared/protocol.lua',
        'br_lib/shared/polygon.lua',
        'br_lib/config/map.lua',
        'br_lib/config/loot.lua',
        'br_lib/config/props.lua',
        'br_lib/shared/props_solve.lua',
    })
    if opts.maxProps then BR.Config.Props.maxProps = opts.maxProps end
    -- A GRANT MODULE THAT REFUSES EVERYBODY AND COUNTS WHO ASKS. Nobody in
    -- these tests holds a grant, and /brprop must work anyway without ever
    -- asking -- the scopes it wanted stopped existing on 2026-08-29.
    BR.Admin = {
        devTrusted = function()
            adminAsked = adminAsked + 1
            return false, 'not-admin'
        end,
    }
    BR.Roster = { get = function(src) return roster[src] end }
    BR.Sched = { every = function(ms, name, fn) jobs[name] = { ms = ms, fn = fn } end }
    loadAll({ 'br_core/server/props.lua' })
end

local function fireAs(src, name, ...)
    local prev = source
    source = src
    for _, fn in ipairs(handlers[name] or {}) do fn(...) end
    source = prev
end

--- Type one `brpropsv` line as player `src` (0 is the server console), split
--- on whitespace the way the console splits it.
local function sv(src, line)
    local args = {}
    for w in line:gmatch('%S+') do args[#args + 1] = w end
    local c = svCommands.brpropsv
    if c then c.fn(src, args, 'brpropsv ' .. line) end
end

local function sentTo(target, name)
    local out = {}
    for _, e in ipairs(toClient) do
        if (target == nil or e.target == target) and (name == nil or e.name == name) then
            out[#out + 1] = e
        end
    end
    return out
end

local function lastResult(src)
    local r = sentTo(src, BR.Net.PROP_RESULT)
    return r[#r] and r[#r].data or nil
end

local function spawnReq(over)
    local d = { model = 'prop_box_wood05a', display = 'pickup',
                x = INSIDE.x + 2, y = INSIDE.y, z = INSIDE.z - 1, pitch = 0, roll = 0, yaw = 0 }
    for k, v in pairs(over or {}) do d[k] = v end
    return d
end

--- The line client/props.lua sends for a spawn.
local function spawnLine(over)
    local d = spawnReq(over)
    return ('spawn %s %s %s %s %s %s'):format(d.model, d.display,
        S.num(d.x), S.num(d.y), S.num(d.z), S.num(d.yaw))
end

--- The line client/props.lua sends for a confirm.
local function confirmLine(id, t)
    return ('edit confirm %d %s %s %s %s %s %s'):format(id, S.num(t.x), S.num(t.y),
        S.num(t.z), S.num(t.pitch or 0), S.num(t.roll or 0), S.num(t.yaw or 0))
end

local function mv(over)
    local d = { id = 1, x = INSIDE.x + 3, y = INSIDE.y, z = INSIDE.z, pitch = 10, roll = 20, yaw = 400 }
    for k, v in pairs(over or {}) do d[k] = v end
    return d
end

describe('server: every request is the dev command brpropsv, and dev mode is its whole gate')
do
    bootServer()
    local c = svCommands.brpropsv
    ok(c ~= nil, 'brpropsv is registered')
    eq(c and c.restricted, false,
        'unrestricted: restricted would ask the player for the command.brpropsv ACE')
    ok(svCommands.brprop == nil, 'and the server has no brprop -- that is the client\'s, which runs this')

    -- DEV MODE OFF: every verb refused at the wrap, by name, and nothing moves.
    bootServer({ devMode = false })
    BR.Props.create(1, spawnReq())
    toClient = {}
    local lines = {
        spawnLine(), 'delete 1', 'delete all', 'display 1 static', 'save', 'load',
        'edit begin 1', confirmLine(1, INSIDE), 'edit cancel 1', 'frobnicate',
    }
    for _, line in ipairs(lines) do
        consoleLines = {}
        sv(1, line)
        eq(#toClient, 0, line .. ': dev mode off, nothing sent to anybody')
        ok(table.concat(consoleLines, '\n'):find('brpropsv is dev%-mode only') ~= nil,
            line .. ': and this console says which gate closed', table.concat(consoleLines, '\n'))
    end
    eq(BR.Props.count(), 1, 'the prop is still there')
    local r = BR.Props.get(1)
    ok(r and r.x == INSIDE.x + 2 and r.display == 'pickup', 'and unchanged')
    eq(files['br_core/devprops.json'], nil, 'nothing was saved')
    eq(BR.Props.editing(1), nil, 'and no edit session opened')

    -- DEV MODE ON, A PLAYER WITH NO GRANT: every verb runs.
    bootServer()
    sv(1, spawnLine())
    sv(1, spawnLine({ model = 'second' }))
    eq(BR.Props.count(), 2, 'spawn')
    sv(1, 'display 1 static')
    eq(BR.Props.get(1).display, 'static', 'display')
    sv(1, 'save')
    ok(files['br_core/devprops.json'] ~= nil, 'save')
    sv(1, 'delete 2')
    eq(BR.Props.count(), 1, 'delete')
    sv(1, 'load')
    eq(BR.Props.count(), 2, 'load')
    sv(1, 'edit begin 1')
    eq(BR.Props.editing(1), 1, 'edit begin')
    sv(1, confirmLine(1, { x = INSIDE.x + 4, y = INSIDE.y, z = INSIDE.z }))
    eq(BR.Props.get(1).x, INSIDE.x + 4, 'edit confirm')
    sv(1, 'edit begin 1')
    sv(1, 'edit cancel 1')
    eq(BR.Props.editing(1), nil, 'edit cancel')
    sv(1, 'delete all')
    eq(BR.Props.count(), 0, 'delete all')
    eq(adminAsked, 0, 'and not one of them asked BR.Admin.devTrusted')

    -- EITHER CONVAR OPENS IT, as BR.Dev.on() reads them.
    bootServer({ devMode = false })
    svConvars.br_devMode = 'true'
    sv(1, spawnLine())
    eq(BR.Props.count(), 1, 'br_devMode alone opens it too')

    -- AND THERE IS NO GRANT MODULE TO NEED: with none loaded it still works.
    bootServer()
    BR.Admin = nil
    sv(1, spawnLine())
    eq(BR.Props.count(), 1, 'no admin module at all: still a prop')
end

describe('server: nothing in server/props.lua asks for a grant')
do
    local fh = io.open(ROOT .. 'br_core/server/props.lua', 'r')
    local src = fh and fh:read('a') or ''
    if fh then fh:close() end
    local code = {}
    for line in (src .. '\n'):gmatch('([^\n]*)\n') do code[#code + 1] = (line:gsub('%-%-.*$', '')) end
    local text = table.concat(code, '\n')
    ok(#src > 0, 'the file is there')
    ok(text:find('BR%.Admin') == nil, 'no BR.Admin in its code')
    ok(text:find('BR%.Grants') == nil, 'no BR.Grants either')
    ok(text:find("RegisterCommand%('brpropsv'") ~= nil, 'it registers brpropsv through RegisterCommand')
    ok(text:find('rawCommand') == nil, 'and never through the ungated door')
end

describe('server: a spawn makes a record, numbers it, and tells everybody')
do
    bootServer()
    sv(1, spawnLine({ model = 'PROP_Box_Wood05a' }))
    eq(BR.Props.count(), 1, 'one prop')
    local r = BR.Props.get(1)
    ok(r ~= nil and r.model == 'prop_box_wood05a', 'id 1, model lower-cased')
    local all = sentTo(-1, BR.Net.PROP_SYNC)
    eq(#all, 1, 'one broadcast, to everybody')
    local set = all[1] and all[1].data.set
    ok(set and set[1] and set[1].id == 1 and set[1].model == 'prop_box_wood05a'
       and set[1].display == 'pickup', 'carrying the record')
    if set and set[1] then set[1].x = -1 end
    ok(BR.Props.get(1).x ~= -1, 'as a copy: changing the payload changes no record')
    ok((lastResult(1) or ''):find('spawned #1') ~= nil, 'and the asker is told', lastResult(1))
    ok(table.concat(consoleLines, '\n'):find('client 1') ~= nil, 'and this console records who')

    sv(1, spawnLine({ display = 'static' }))
    eq(BR.Props.get(2) and BR.Props.get(2).display, 'static', 'the next is #2, static as asked')
    BR.Props.remove(2)
    sv(1, spawnLine())
    ok(BR.Props.get(3) ~= nil and BR.Props.get(2) == nil, 'an id is never reused')

    -- THROUGH A COMMAND LINE AND BACK, BIT FOR BIT.
    sv(1, spawnLine({ x = INSIDE.x + 0.123456789, y = INSIDE.y - 1 / 3, yaw = 33.3 }))
    local r4 = BR.Props.get(4)
    ok(r4 and r4.x == INSIDE.x + 0.123456789 and r4.y == INSIDE.y - 1 / 3,
        'the position survives the command line exactly', r4 and ('%.17g'):format(r4.x))
    close(r4 and r4.yaw, 33.3, 'and the yaw comes through', 1e-9)
    sv(1, ('spawn prop_x pickup %s %s %s'):format(S.num(INSIDE.x), S.num(INSIDE.y), S.num(INSIDE.z)))
    local r5 = BR.Props.get(5)
    ok(r5 and r5.yaw == 0 and r5.pitch == 0 and r5.roll == 0, 'no yaw given is upright, facing north')
end

describe('server: a spawn that breaks a rule is refused, and the asker hears why')
do
    bootServer()
    local cases = {
        { 'a bad name', spawnLine({ model = 'a/b' }), 'letters' },
        { 'no name', 'spawn', 'no model' },
        { 'a bad display', spawnLine({ display = 'hover' }), 'pickup or static' },
        { 'a NaN position', spawnLine({ x = 0 / 0 }), 'real numbers' },
        { 'a word for a number', 'spawn prop_x pickup 200 north 30', 'real numbers' },
        { 'no position', 'spawn prop_x pickup', 'real numbers' },
        { 'a word for the yaw', ('spawn prop_x pickup %s %s %s east')
            :format(S.num(INSIDE.x), S.num(INSIDE.y), S.num(INSIDE.z)), 'rotation' },
        { 'outside the world', spawnLine({ x = 1e7 }), 'outside the world' },
        { 'outside the boundary and far away',
          spawnLine({ x = OUTSIDE.x, y = OUTSIDE.y, z = OUTSIDE.z }), 'more than 150 m' },
    }
    for _, c in ipairs(cases) do
        toClient = {}
        sv(1, c[2])
        eq(BR.Props.count(), 0, c[1] .. ': no prop')
        eq(#sentTo(-1, BR.Net.PROP_SYNC), 0, c[1] .. ': nothing broadcast')
        local said = lastResult(1) or ''
        ok(said:find('refused') ~= nil and said:find(c[3], 1, true) ~= nil,
            c[1] .. ': the reason reaches the asker', said)
    end

    -- Outside the boundary is fine NEAR the asker -- the warmup pad case.
    sv(2, spawnLine({ x = OUTSIDE.x + 3, y = OUTSIDE.y, z = OUTSIDE.z }))
    eq(BR.Props.count(), 1, 'outside the boundary but beside the asker: allowed')
    -- And the position is the SERVER's sample of the asker, not anything sent.
    roster[2] = nil
    sv(2, spawnLine({ x = OUTSIDE.x + 3, y = OUTSIDE.y, z = OUTSIDE.z }))
    eq(BR.Props.count(), 1, 'an asker the server has not sampled cannot place outside')
    sv(2, spawnLine())
    eq(BR.Props.count(), 2, 'but can place inside the boundary')
    -- The server console has no position at all.
    sv(0, spawnLine({ x = OUTSIDE.x + 3, y = OUTSIDE.y, z = OUTSIDE.z }))
    eq(BR.Props.count(), 2, 'nor can the server console')
    ok(table.concat(consoleLines, '\n'):find('client 0%): spawn refused') ~= nil,
        'and the console answer is on the console')
end

describe('server: the cap on live props')
do
    bootServer({ maxProps = 3 })
    for _ = 1, 3 do sv(1, spawnLine()) end
    eq(BR.Props.count(), 3, 'three of three')
    toClient = {}
    sv(1, spawnLine())
    eq(BR.Props.count(), 3, 'the fourth is refused')
    eq(#sentTo(-1, BR.Net.PROP_SYNC), 0, 'and not broadcast')
    ok((lastResult(1) or ''):find('already 3') ~= nil, 'the refusal names the cap', lastResult(1))
    bootServer()
    eq(BR.Config.Props.maxProps, 64, 'and the shipped cap is 64')
end

describe('server: the edit stream moves a prop only inside its session, checked and rate-limited')
do
    bootServer()
    BR.Props.create(1, spawnReq())
    BR.Props.create(1, spawnReq({ x = INSIDE.x + 10 }))
    toClient, consoleLines = {}, {}

    -- NO SESSION: the stream is nobody's door.
    fireAs(1, BR.Net.PROP_MOVE, mv())
    eq(BR.Props.get(1).x, INSIDE.x + 2, 'no session: the stream moves nothing')
    eq(#toClient, 0, 'and nothing is sent to anybody')
    eq(#consoleLines, 0, 'or said on this console -- any client can send it')

    -- A SESSION, OPENED BY THE COMMAND.
    sv(1, 'edit begin 1')
    eq(BR.Props.editing(1), 1, 'edit begin opens a session on #1')
    local open = sentTo(1, BR.Net.PROP_EDIT)
    ok(#open == 1 and open[1].data.id == 1 and open[1].data.open == true,
        'and tells that player, alone, that it is open')
    toClient = {}
    fireAs(1, BR.Net.PROP_MOVE, mv())
    local r = BR.Props.get(1)
    ok(r.x == INSIDE.x + 3 and r.pitch == 10 and r.roll == 20 and r.yaw == 40,
        'inside it: moved and turned, yaw folded')
    eq(#sentTo(-1, BR.Net.PROP_SYNC), 1, 'rebroadcast to everybody')
    eq(#sentTo(1, BR.Net.PROP_RESULT), 0, 'an ordinary update is not answered')

    -- THE WRONG PROP, AND THE WRONG PLAYER.
    clock = clock + 100
    toClient = {}
    fireAs(1, BR.Net.PROP_MOVE, mv({ id = 2, x = INSIDE.x + 9 }))
    eq(BR.Props.get(2).x, INSIDE.x + 10, 'the session is on #1: an update for #2 moves nothing')
    eq(#toClient, 0, 'silently')
    fireAs(3, BR.Net.PROP_MOVE, mv({ x = INSIDE.x + 9 }))
    eq(BR.Props.get(1).x, INSIDE.x + 3, 'and nobody else streams into this player\'s session')
    fireAs(1, BR.Net.PROP_MOVE, 'not a table')
    eq(BR.Props.get(1).x, INSIDE.x + 3, 'a payload that is not a table moves nothing')

    -- THE FLOOR.
    clock = clock + 100
    fireAs(1, BR.Net.PROP_MOVE, mv({ x = INSIDE.x + 5 }))
    clock = clock + 20
    toClient = {}
    fireAs(1, BR.Net.PROP_MOVE, mv({ x = INSIDE.x + 4 }))
    eq(BR.Props.get(1).x, INSIDE.x + 5, '20 ms later: dropped')
    eq(#toClient, 0, 'silently')
    fireAs(1, BR.Net.PROP_MOVE, mv({ x = INSIDE.x + 4, final = true }))
    eq(BR.Props.get(1).x, INSIDE.x + 5, '`final` on the stream does not skip the floor')
    clock = clock + BR.Config.Props.moveMinMs
    fireAs(1, BR.Net.PROP_MOVE, mv({ x = INSIDE.x + 6 }))
    eq(BR.Props.get(1).x, INSIDE.x + 6, 'moveMinMs later: taken')

    -- A REFUSAL INSIDE THE SESSION IS THE EDITOR'S OWN BUSINESS.
    clock = clock + 100
    toClient = {}
    fireAs(1, BR.Net.PROP_MOVE, mv({ x = OUTSIDE.x, y = OUTSIDE.y, z = OUTSIDE.z }))
    eq(BR.Props.get(1).x, INSIDE.x + 6, 'a move out to sea is refused')
    ok((lastResult(1) or ''):find('move refused') ~= nil, 'the editor hears why', lastResult(1))
    local back = sentTo(1, BR.Net.PROP_SYNC)
    ok(#back == 1 and back[1].data.set[1].x == INSIDE.x + 6,
        'and is sent the record as it stands, to put his preview back')
    eq(#sentTo(-1, BR.Net.PROP_SYNC), 0, 'nobody else is bothered')
    clock = clock + 100
    fireAs(1, BR.Net.PROP_MOVE, mv({ yaw = 0 / 0 }))
    eq(BR.Props.get(1).yaw, 40, 'a NaN rotation is refused')

    -- AND ONCE IT CLOSES, NOTHING.
    sv(1, confirmLine(1, { x = INSIDE.x + 7, y = INSIDE.y, z = INSIDE.z }))
    eq(BR.Props.editing(1), nil, 'the confirm closes the session')
    clock = clock + 100
    toClient = {}
    fireAs(1, BR.Net.PROP_MOVE, mv({ x = INSIDE.x + 8 }))
    eq(BR.Props.get(1).x, INSIDE.x + 7, 'after the session closed, the stream moves nothing')
    eq(#toClient, 0, 'and says nothing')

    -- A player who leaves takes his rate window with him.
    sv(1, 'edit begin 1')
    fireAs(1, BR.Net.PROP_MOVE, mv({ x = INSIDE.x + 8 }))
    fireAs(1, 'playerDropped')
    sv(1, 'edit begin 1')
    fireAs(1, BR.Net.PROP_MOVE, mv({ x = INSIDE.x + 9 }))
    eq(BR.Props.get(1).x, INSIDE.x + 9, 'after playerDropped the next update is not "too soon"')
end

describe('server: confirm lands at once; cancel puts back the server\'s own copy')
do
    bootServer()
    BR.Props.create(1, spawnReq({ yaw = 30 }))
    sv(1, 'edit begin 1')
    fireAs(1, BR.Net.PROP_MOVE, mv())
    clock = clock + 10
    local want = { x = INSIDE.x + 0.123456789, y = INSIDE.y - 1 / 3, z = INSIDE.z + 1.75,
                   pitch = 1.5, roll = -2.25, yaw = -179.5 }
    sv(1, confirmLine(1, want))
    local r = BR.Props.get(1)
    ok(r.x == want.x and r.y == want.y and r.z == want.z and r.pitch == want.pitch
       and r.roll == want.roll and r.yaw == want.yaw,
        'a confirm 10 ms after an update lands, every field exact')
    ok((lastResult(1) or ''):find('#1 placed') ~= nil, 'and is answered', lastResult(1))
    eq(BR.Props.editing(1), nil, 'and closes the session')
    sv(1, confirmLine(1, want))
    ok((lastResult(1) or ''):find('confirm refused: you have no open edit') ~= nil,
        'a second confirm finds no session', lastResult(1))

    -- CANCEL: the record from `edit begin`, even with the player far away now.
    BR.Props.create(2, spawnReq({ x = OUTSIDE.x + 3, y = OUTSIDE.y, z = OUTSIDE.z, yaw = 15 }))
    sv(2, 'edit begin 2')
    fireAs(2, BR.Net.PROP_MOVE, { id = 2, x = OUTSIDE.x + 6, y = OUTSIDE.y, z = OUTSIDE.z, yaw = 90 })
    eq(BR.Props.get(2).x, OUTSIDE.x + 6, 'streamed off its start')
    roster[2] = { pos = { x = OUTSIDE.x + 400, y = OUTSIDE.y, z = OUTSIDE.z } }
    toClient = {}
    sv(2, 'edit cancel 2')
    local c = BR.Props.get(2)
    ok(c.x == OUTSIDE.x + 3 and c.yaw == 15,
        'cancel puts it back, though the player is now 400 m away off the island')
    local s = sentTo(-1, BR.Net.PROP_SYNC)
    ok(#s == 1 and s[1].data.set[1].x == OUTSIDE.x + 3, 'for everybody')
    eq(BR.Props.editing(2), nil, 'and closes the session')

    -- A REFUSED CONFIRM STILL CLOSES, and puts the preview back.
    sv(1, 'edit begin 1')
    toClient = {}
    sv(1, confirmLine(1, OUTSIDE))
    eq(BR.Props.get(1).x, want.x, 'a confirm out to sea is refused')
    ok((lastResult(1) or ''):find('confirm refused') ~= nil, 'with the reason', lastResult(1))
    local b = sentTo(1, BR.Net.PROP_SYNC)
    ok(#b == 1 and b[1].data.set[1].x == want.x, 'and the record as it stands')
    eq(BR.Props.editing(1), nil, 'and the session is closed all the same')

    -- AN END FOR ANOTHER PROP is refused and leaves the session alone.
    BR.Props.create(1, spawnReq())
    sv(1, 'edit begin 1')
    sv(1, 'edit cancel 3')
    ok((lastResult(1) or ''):find('your open edit is #1') ~= nil, 'an end for #3 is refused', lastResult(1))
    eq(BR.Props.editing(1), 1, 'and #1 is still open')
    sv(1, 'edit')
    ok((lastResult(1) or ''):find('usage: brpropsv') ~= nil, 'a bare edit prints the usage')
end

describe('server: edit begin is refused for the console, an unknown prop, and a prop being edited')
do
    bootServer()
    BR.Props.create(1, spawnReq())
    sv(0, 'edit begin 1')
    ok(table.concat(consoleLines, '\n'):find('edit refused: edit needs a player') ~= nil,
        'the server console cannot hold a session')
    eq(BR.Props.editing(0), nil, 'and does not')

    toClient = {}
    sv(1, 'edit begin 9')
    ok((lastResult(1) or ''):find('no prop #9') ~= nil, 'an unknown id is refused', lastResult(1))
    local e = sentTo(1, BR.Net.PROP_EDIT)
    ok(#e == 1 and e[1].data.id == 9 and e[1].data.open == false,
        'and the client is told the session is not open, so it stops waiting')

    sv(1, 'edit begin 1')
    sv(3, 'edit begin 1')
    ok((lastResult(3) or ''):find('client 1 is editing #1') ~= nil,
        'a prop another player is editing is refused', lastResult(3))
    eq(BR.Props.editing(3), nil, 'no second session')
    clock = clock + 100
    fireAs(3, BR.Net.PROP_MOVE, mv({ x = INSIDE.x + 9 }))
    eq(BR.Props.get(1).x, INSIDE.x + 2, 'and the second player\'s stream moves nothing')
    sv(1, 'edit cancel 1')
    sv(3, 'edit begin 1')
    eq(BR.Props.editing(3), 1, 'once the first closes, the next player may')
end

describe('server: a session closes on every way out')
do
    --- One stream update from `src` on `id`, a second after the last; did it
    --- move the prop?
    local function streams(src, id)
        clock = clock + 1000
        local before = BR.Props.get(id)
        fireAs(src, BR.Net.PROP_MOVE, { id = id, x = INSIDE.x + 1, y = INSIDE.y,
            z = (before and before.z or 0) + 0.5, pitch = 0, roll = 0, yaw = 0 })
        local after = BR.Props.get(id)
        return before ~= nil and after ~= nil and after.z ~= before.z
    end

    bootServer()
    for _ = 1, 4 do BR.Props.create(1, spawnReq()) end
    sv(1, 'edit begin 1')
    ok(streams(1, 1), 'the probe moves a prop inside a session')

    sv(1, confirmLine(1, { x = INSIDE.x, y = INSIDE.y, z = INSIDE.z }))
    ok(not streams(1, 1), 'confirm closes it')
    sv(1, 'edit begin 1')
    sv(1, 'edit cancel 1')
    ok(not streams(1, 1), 'cancel closes it')

    sv(1, 'edit begin 1')
    fireAs(1, 'playerDropped')
    eq(BR.Props.editing(1), nil, 'a disconnect closes it')
    ok(not streams(1, 1), 'and the stream is shut')

    sv(1, 'edit begin 2')
    toClient = {}
    sv(3, 'delete 2')
    eq(BR.Props.editing(1), nil, 'deleting the prop, by anybody, closes it')
    eq(#sentTo(1, BR.Net.PROP_EDIT), 0, 'without a second word -- the client ends on the gone')
    sv(1, 'edit begin 3')
    sv(3, 'delete 4')
    eq(BR.Props.editing(1), 3, 'deleting another prop does not')

    sv(1, 'save')
    toClient = {}
    sv(3, 'load')
    eq(BR.Props.editing(1), nil, 'a load closes it')
    local e = sentTo(1, BR.Net.PROP_EDIT)
    ok(#e == 1 and e[1].data.id == 3 and e[1].data.open == false
       and tostring(e[1].data.why):find('reloaded') ~= nil, 'and tells the editor why')
    ok(not streams(1, 3), 'and the stream is shut')

    sv(1, 'edit begin 1')
    sv(1, 'edit begin 3')
    eq(BR.Props.editing(1), 3, 'another edit begin moves the session')
    ok(not streams(1, 1), 'off the first prop')
    ok(streams(1, 3), 'and onto the second')

    sv(3, 'delete all')
    eq(BR.Props.editing(1), nil, 'delete all closes it')

    -- IDLE.
    BR.Props.create(1, spawnReq())
    local id = BR.Props.list()[1].id
    local idle = BR.Config.Props.editIdleMs
    sv(1, 'edit begin ' .. id)
    clock = clock + idle - 1
    BR.Props.expireSessions(clock)
    eq(BR.Props.editing(1), id, 'one ms short of editIdleMs: still open')
    ok(streams(1, id), 'and an update keeps it alive')
    clock = clock + idle - 1
    BR.Props.expireSessions(clock)
    eq(BR.Props.editing(1), id, 'counted from the last update, not the begin')
    clock = clock + 2000
    toClient = {}
    local job = jobs['props.sessions']
    ok(job ~= nil and job.ms <= 10000, 'a scheduled job checks every few seconds')
    if job then job.fn() end
    eq(BR.Props.editing(1), nil, 'past editIdleMs the job closes it')
    local t = sentTo(1, BR.Net.PROP_EDIT)
    ok(#t == 1 and t[1].data.open == false and tostring(t[1].data.why):find('idle') ~= nil,
        'and tells the editor why')
    ok(not streams(1, id), 'and the stream is shut')
    eq(idle, 600000, 'ten minutes')
end

describe('server: delete one, delete all, change the display')
do
    bootServer()
    for _ = 1, 3 do BR.Props.create(1, spawnReq()) end
    toClient = {}
    sv(1, 'delete 2')
    eq(BR.Props.count(), 2, 'one deleted')
    local g = sentTo(-1, BR.Net.PROP_SYNC)
    ok(#g == 1 and g[1].data.gone and g[1].data.gone[1] == 2 and #g[1].data.gone == 1,
        'the id goes to everybody as gone')
    sv(1, 'delete 2')
    ok((lastResult(1) or ''):find('no prop #2') ~= nil, 'deleting it twice is refused')
    sv(1, 'delete')
    ok((lastResult(1) or ''):find('delete refused') ~= nil, 'and so is no id at all')

    sv(1, 'display 1 static')
    eq(BR.Props.get(1).display, 'static', 'display changed')
    local s = sentTo(-1, BR.Net.PROP_SYNC)
    eq(s[#s].data.set[1].display, 'static', 'and broadcast')
    sv(1, 'display 1 spin')
    eq(BR.Props.get(1).display, 'static', 'a bad mode is refused')
    sv(1, 'display 1')
    eq(BR.Props.get(1).display, 'static', 'and so is no mode at all (not read as pickup)')
    ok((lastResult(1) or ''):find('display refused') ~= nil, 'with a reason')

    toClient = {}
    sv(1, 'delete ALL')
    eq(BR.Props.count(), 0, 'all deleted')
    local ga = sentTo(-1, BR.Net.PROP_SYNC)
    ok(#ga == 1 and #ga[1].data.gone == 2 and ga[1].data.gone[1] == 1 and ga[1].data.gone[2] == 3,
        'every id in one message, in order')
    ok((lastResult(1) or ''):find('deleted every prop %(2%)') ~= nil, 'and counted', lastResult(1))

    sv(1, '')
    ok((lastResult(1) or ''):find('usage: brpropsv') ~= nil, 'bare prints the usage')
    sv(1, 'frobnicate')
    ok((lastResult(1) or ''):find('usage: brpropsv') ~= nil, 'and so does a verb it does not know')
end

describe('server: a late joiner, and a restarted br_core, get the whole list')
do
    bootServer()
    BR.Props.create(1, spawnReq({ model = 'b' }))
    BR.Props.create(1, spawnReq({ model = 'a', display = 'static' }))
    toClient = {}
    fireAs(9, BR.Net.READY)
    eq(#toClient, 1, 'one message')
    local m = toClient[1]
    ok(m and m.target == 9 and m.name == BR.Net.PROP_SYNC, 'to the joiner alone')
    ok(m and m.data.full == true and #m.data.props == 2, 'the full list')
    ok(m and m.data.props[1].id == 1 and m.data.props[2].id == 2 and m.data.props[2].display == 'static',
        'in id order, every field')
    m.data.props[1].x = -1
    ok(BR.Props.get(1).x ~= -1, 'the payload is a copy')

    -- READY carries no gate, dev mode included: every player draws the props.
    bootServer({ devMode = false })
    BR.Props.create(1, spawnReq())
    toClient = {}
    fireAs(9, BR.Net.READY)
    eq(#toClient, 1, 'with dev mode off a joiner is still sent the list to draw')
end

describe('server: save, restart, load -- the placements come back exactly')
do
    bootServer()
    BR.Props.create(1, spawnReq({ model = 'one', yaw = 33.3 }))
    BR.Props.create(1, spawnReq({ model = 'two', display = 'static', pitch = -12.5, roll = 7.25 }))
    BR.Props.create(1, spawnReq({ model = 'three' }))
    BR.Props.remove(1)
    BR.Props.move(1, { id = 3, x = INSIDE.x + 0.123456789, y = INSIDE.y - 0.5, z = INSIDE.z + 1.75,
                       pitch = 1, roll = 2, yaw = -179.5, final = true })
    local before = BR.Props.list()
    sv(1, 'save')
    local body = files['br_core/devprops.json']
    ok(type(body) == 'string' and body:find('"three"') ~= nil, 'written to br_core/devprops.json')
    ok((lastResult(1) or ''):find('saved 2 prop') ~= nil, 'and counted', lastResult(1))

    -- A RESTART: a fresh server state over the same disk.
    bootServer({ files = files })
    eq(BR.Props.count(), 0, 'a restarted server starts empty')
    toClient = {}
    sv(1, 'load')
    local after = BR.Props.list()
    eq(#after, #before, 'the same number come back')
    local same = true
    for i = 1, #before do
        for _, k in ipairs({ 'id', 'model', 'display', 'x', 'y', 'z', 'pitch', 'roll', 'yaw' }) do
            if after[i] == nil or before[i][k] == nil or before[i][k] ~= after[i][k] then
                same = false
            end
        end
    end
    ok(same, 'every field, ids included, bit for bit')
    local full = sentTo(-1, BR.Net.PROP_SYNC)
    ok(#full == 1 and full[1].data.full == true and #full[1].data.props == 2,
        'everybody is sent the full list')
    ok((lastResult(1) or ''):find('loaded 2 prop') ~= nil, 'and the asker is told', lastResult(1))
    BR.Props.create(1, spawnReq())
    ok(BR.Props.get(4) ~= nil, 'and the next id follows the highest loaded one')
end

describe('server: a load that cannot read the file changes nothing')
do
    bootServer()
    BR.Props.create(1, spawnReq())
    sv(1, 'load')
    eq(BR.Props.count(), 1, 'no file: the prop stays')
    ok((lastResult(1) or ''):find('load failed') ~= nil, 'and the asker is told', lastResult(1))

    files['br_core/devprops.json'] = 'this is not { json'
    sv(1, 'load')
    eq(BR.Props.count(), 1, 'garbage: the prop stays')
    files['br_core/devprops.json'] = '{"v":1}'
    sv(1, 'load')
    eq(BR.Props.count(), 1, 'no props array: the prop stays')

    -- AND AN EDIT IN PROGRESS SURVIVES A LOAD THAT CHANGED NOTHING.
    sv(1, 'edit begin 1')
    sv(3, 'load')
    eq(BR.Props.editing(1), 1, 'a failed load closes no session')
end

describe('server: a load skips bad rows, keeps good ones, and never collides')
do
    bootServer({ maxProps = 4 })
    files['br_core/devprops.json'] = json.encode({ v = 1, props = {
        { id = 5, model = 'good', display = 'pickup', x = 1, y = 2, z = 3, pitch = 0, roll = 0, yaw = 0 },
        { id = 5, model = 'dupe', display = 'static', x = 1, y = 2, z = 3, pitch = 0, roll = 0, yaw = 0 },
        { id = 6, model = 'bad name', x = 1, y = 2, z = 3 },
        { id = 7, model = 'nowhere', x = 1e9, y = 2, z = 3 },
        { model = 'noid', x = OUTSIDE.x, y = OUTSIDE.y, z = OUTSIDE.z },
        { id = 9, model = 'fourth', x = 1, y = 2, z = 3 },
        { id = 10, model = 'fifth', x = 1, y = 2, z = 3 },
    } })
    sv(1, 'load')
    eq(BR.Props.count(), 4, 'four good rows kept, to the cap')
    eq(BR.Props.get(5) and BR.Props.get(5).model, 'good', 'an id is kept')
    eq(BR.Props.get(9) and BR.Props.get(9).model, 'fourth', 'and another')
    local models = {}
    for _, r in ipairs(BR.Props.list()) do models[r.model] = r.id end
    ok(models.dupe ~= nil and models.dupe ~= 5, 'a duplicate id gets a fresh one', models.dupe)
    ok(models.noid ~= nil, 'a missing id gets one, far from anybody (the file is the server\'s own)')
    ok(models.fifth == nil, 'past the cap is skipped')
    ok((lastResult(1) or ''):find('skipped 3 bad row') ~= nil, 'and the skips are counted', lastResult(1))
end

describe('server: a save that cannot write says so')
do
    bootServer({ saveFails = true })
    BR.Props.create(1, spawnReq())
    sv(1, 'save')
    ok((lastResult(1) or ''):find('save failed') ~= nil, 'a refused write is a failure', lastResult(1))
end

describe('the save survives a deploy, and never reaches the repo')
do
    local fh = io.open('tools/deploy.sh', 'r')
    local deploy = fh and fh:read('a') or ''
    if fh then fh:close() end
    local name = BR.Config.Props.saveFile
    ok(deploy:find("--exclude 'br_core/" .. name .. "'", 1, true) ~= nil,
        'tools/deploy.sh excludes br_core/' .. name .. ' from the rsync --delete')
    fh = io.open('.gitignore', 'r')
    local ignore = fh and fh:read('a') or ''
    if fh then fh:close() end
    ok(ignore:find('/resources/*/br_core/' .. name, 1, true) ~= nil, '.gitignore ignores it')
end

print = realPrint

-- =========================================================================
-- PART C -- the client, over the real key layer
-- =========================================================================

local now = 50000
local logged = {}
local cHandlers, commands, toServer, executed = {}, {}, {}, {}
local convars = { br_devMode = 'true' }

--- Lines the client handed the server, kept for PART D to type into a real
--- server: { spawn, confirm }.
local handed = {}

-- The world.
local hashOf, nameOfHash = {}, {}
local inImage, loadAfter, requestedAt, released = {}, {}, {}, {}
local objects, nextObj = {}, 7000
local ped = { x = INSIDE.x, y = INSIDE.y, z = INSIDE.z, heading = 0.0 }
local camYaw = 0.0
local GROUND = INSIDE.z - 1.0
local disabled = {}
local drawn = {}

-- The keyboard: held VK codes, answered in the 1/0 shape, because 0 is truthy
-- in Lua and a reader that forgot would see every key held forever.
local keys = {}

local function vec(x, y, z) return { x = x, y = y, z = z } end

local function rotate(o, pitch, roll, yaw, v)
    -- Rz(yaw) * Rx(pitch) * Ry(roll), applied to v. Only this stub's own
    -- convention: the code under test asks the engine and never assumes one.
    local cp, sp = math.cos(math.rad(pitch)), math.sin(math.rad(pitch))
    local cr, sr = math.cos(math.rad(roll)), math.sin(math.rad(roll))
    local cy, sy = math.cos(math.rad(yaw)), math.sin(math.rad(yaw))
    local x1, y1, z1 = cr * v.x + sr * v.z, v.y, -sr * v.x + cr * v.z
    local x2, y2, z2 = x1, cp * y1 - sp * z1, sp * y1 + cp * z1
    return vec(o.x + cy * x2 - sy * y2, o.y + sy * x2 + cy * y2, o.z + z2)
end

local function bootClient()
    BR = nil
    logged, cHandlers, commands, toServer, executed = {}, {}, {}, {}, {}
    objects, released, requestedAt = {}, {}, {}
    disabled, drawn, keys = {}, {}, {}

    print = function(s) logged[#logged + 1] = tostring(s) end
    function GetGameTimer() return now end
    function GetCurrentResourceName() return 'br_core' end
    function GetConvar(n, d) local v = convars[n]; if v == nil then return d end; return v end
    Citizen = { CreateThread = function() end, Wait = function() end, SetTimeout = function() end }
    function AddEventHandler(n, fn)
        cHandlers[n] = cHandlers[n] or {}
        table.insert(cHandlers[n], fn)
    end
    function RegisterNetEvent() end
    function TriggerEvent(n, ...)
        for _, fn in ipairs(cHandlers[n] or {}) do fn(...) end
    end
    function TriggerServerEvent(n, data) toServer[#toServer + 1] = { name = n, data = data, at = now } end
    -- A command this client does not have goes to the server (see the header
    -- of server/props.lua); here it is written down instead.
    function ExecuteCommand(line) executed[#executed + 1] = line end
    function RegisterCommand(n, fn) commands[n] = fn end
    function RegisterKeyMapping() end
    local kvp = {}
    function SetResourceKvp(k, v) kvp[k] = v end
    function GetResourceKvpString(k) return kvp[k] end
    function DeleteResourceKvp(k) kvp[k] = nil end
    function IsPauseMenuActive() return 0 end
    function IsPauseMenuRestarting() return 0 end
    function GetPlayerServerId() return 1 end
    function PlayerId() return 0 end
    function PlayerPedId() return 1 end

    function IsRawKeyDown(vk) return keys[vk] and 1 or 0 end
    function IsRawKeyPressed(vk) return keys[vk] and 1 or 0 end

    function GetHashKey(name)
        local k = name:lower()
        if not hashOf[k] then
            local h = 0
            for i = 1, #k do h = (h * 31 + k:byte(i)) % 2147483647 end
            hashOf[k], nameOfHash[h] = h, k
        end
        return hashOf[k]
    end
    function IsModelInCdimage(h) return inImage[nameOfHash[h]] and 1 or 0 end
    function RequestModel(h)
        if requestedAt[h] == nil then requestedAt[h] = now end
        released[h] = nil
    end
    function HasModelLoaded(h)
        local after = loadAfter[nameOfHash[h]]
        if requestedAt[h] == nil or after == nil then return 0 end
        return (now - requestedAt[h] >= after) and 1 or 0
    end
    function SetModelAsNoLongerNeeded(h)
        released[h] = true
        requestedAt[h] = nil
    end
    function CreateObjectNoOffset(h, x, y, z, isNetwork, netMission, dynamic)
        if nameOfHash[h] == 'a_car' then return 0 end
        nextObj = nextObj + 1
        objects[nextObj] = { model = nameOfHash[h], hash = h, x = x, y = y, z = z,
                             pitch = 0, roll = 0, yaw = 0,
                             isNetwork = isNetwork, netMission = netMission, dynamic = dynamic }
        return nextObj
    end
    function DoesEntityExist(o) return objects[o] and 1 or 0 end
    function DeleteEntity(o) objects[o] = nil end
    function FreezeEntityPosition(o, f) if objects[o] then objects[o].frozen = f end end
    function SetEntityCollision(o, a) if objects[o] then objects[o].collision = a end end
    function SetEntityCoordsNoOffset(o, x, y, z)
        local e = objects[o]
        if e then e.x, e.y, e.z = x, y, z end
    end
    function SetEntityRotation(o, p, r, y, order)
        local e = objects[o]
        if e then e.pitch, e.roll, e.yaw, e.order = p, r, y, order end
    end
    function GetEntityModel(o) return objects[o] and objects[o].hash or 0 end
    function GetEntityCoords(e)
        if e == 1 then return vec(ped.x, ped.y, ped.z) end
        local o = objects[e]
        return o and vec(o.x, o.y, o.z) or vec(0, 0, 0)
    end
    function GetEntityHeading() return ped.heading end
    function GetModelDimensions() return vec(-0.5, -0.5, -0.25), vec(0.5, 0.5, 0.75) end
    function GetOffsetFromEntityInWorldCoords(o, x, y, z)
        local e = objects[o]
        return rotate(e, e.pitch, e.roll, e.yaw, vec(x, y, z))
    end
    function GetGroundZFor_3dCoord(_, _, z)
        if z > GROUND then return 1, GROUND end
        return 0, 0.0
    end
    function GetGameplayCamRot() return vec(0, 0, camYaw) end
    function DisableControlAction(_, c) disabled[c] = true end
    for _, n in ipairs({ 'SetTextFont', 'SetTextScale', 'SetTextColour', 'SetTextDropshadow',
                         'SetTextEdge', 'SetTextDropShadow', 'SetTextOutline',
                         'BeginTextCommandDisplayText', 'EndTextCommandDisplayText' }) do
        _G[n] = function() end
    end
    function AddTextComponentSubstringPlayerName(s) drawn[#drawn + 1] = s end

    loadAll({
        'br_lib/shared/devgate.lua',
        'br_lib/shared/enums.lua',
        'br_lib/shared/protocol.lua',
        'br_lib/shared/geo.lua',
        'br_lib/shared/polygon.lua',
        'br_lib/config/map.lua',
        'br_lib/config/loot.lua',
        'br_lib/config/props.lua',
        'br_lib/shared/props_solve.lua',
        'br_core/client/main.lua',
        'br_core/client/keybinds.lua',
        'br_core/client/props.lua',
    })
    TriggerEvent('onClientResourceStart', 'br_core')
end

--- One frame of the FRAME band.
local function frame(ms)
    now = now + (ms or 16)
    disabled, drawn = {}, {}
    BR.Loop.step(BR.Loop.FRAME)
end

local function frames(n, ms) for _ = 1, n do frame(ms) end end

local function cmd(line)
    local args = {}
    for w in line:gmatch('%S+') do args[#args + 1] = w end
    commands.brprop(0, args, 'brprop ' .. line)
end

local function sync(msg) TriggerEvent(BR.Net.PROP_SYNC, msg) end

--- The server's answer to `edit begin`: the session is open.
local function serverOpens(id) TriggerEvent(BR.Net.PROP_EDIT, { id = id, open = true }) end

--- Every `brpropsv` line this client ran, as word lists, whose first words
--- match `prefix` ('spawn', 'edit confirm', ...).
local function ran(prefix)
    local out = {}
    for _, line in ipairs(executed) do
        local rest = line:match('^brpropsv (.*)$')
        if rest and rest:sub(1, #prefix) == prefix then
            local w = {}
            for x in rest:gmatch('%S+') do w[#w + 1] = x end
            out[#out + 1] = w
        end
    end
    return out
end

--- The last line this client ran, or nil.
local function lastRan() return executed[#executed] end

local function rec(id, over)
    local r = { id = id, model = 'prop_test', display = 'pickup',
                x = INSIDE.x + 20, y = INSIDE.y, z = GROUND + 0.25, pitch = 0.0, roll = 0.0, yaw = 0.0 }
    for k, v in pairs(over or {}) do r[k] = v end
    return r
end

local function objOf(model)
    for h, o in pairs(objects) do
        if o.model == model then return o, h end
    end
    return nil
end

local function countObjects()
    local n = 0
    for _ in pairs(objects) do n = n + 1 end
    return n
end

local function saidLike(pat)
    for i = #logged, 1, -1 do
        if logged[i]:find(pat) then return logged[i] end
    end
    return nil
end

local function sentOf(name)
    local out = {}
    for _, e in ipairs(toServer) do if e.name == name then out[#out + 1] = e end end
    return out
end

local function errorsOf(name)
    for _, s in ipairs(BR.Loop.stats()) do
        if s.name == name then return s.errors end
    end
    return -1
end

local function tap(vk)
    keys[vk] = true
    frame(16)
    keys[vk] = nil
    frame(16)
end

inImage = { prop_test = true, prop_other = true, prop_slow = true, prop_never = true, a_car = true }
loadAfter = { prop_test = 100, prop_other = 100, prop_slow = 4000, a_car = 50 }

describe('client: the command is behind the dev gate')
do
    convars.br_devMode = 'false'
    bootClient()
    cmd('save')
    eq(#toServer + #executed, 0, 'dev mode off: /brprop sends nothing')
    ok(saidLike('brprop is dev%-mode only') ~= nil, 'and says which gate closed')
    convars.br_devMode = 'true'
    bootClient()
    cmd('save')
    eq(lastRan(), 'brpropsv save', 'dev mode on: it runs the server dev command')
    eq(#toServer, 0, 'and sends no net event')
end

describe('client: a record becomes a local, frozen, non-networked object, and its model is let go')
do
    bootClient()
    sync({ set = { rec(1) } })
    local h = GetHashKey('prop_test')
    ok(requestedAt[h] ~= nil, 'the model is requested')
    frame(16)
    eq(countObjects(), 0, 'nothing built before it streams')
    frames(8, 16)
    local o = objOf('prop_test')
    ok(o ~= nil, 'built once it has streamed')
    ok(o and o.isNetwork == false and o.netMission == false, 'local and non-networked')
    ok(o and o.dynamic == false and o.frozen == true, 'frozen, never dynamic')
    ok(o and o.collision == false, 'a pickup has no collision, like loose loot')
    ok(o and o.x == INSIDE.x + 20 and o.z == GROUND + 0.25, 'at the record')
    ok(released[h] == true and requestedAt[h] == nil, 'and the model is released once built')
    eq(errorsOf('props.frame'), 0, 'no frame errors')
end

describe('client: static has collision and sits exactly as placed, however close')
do
    bootClient()
    sync({ set = { rec(1, { display = 'static', x = ped.x + 0.5, pitch = 12, roll = -7, yaw = 33 }) } })
    frames(30, 16)
    local o = objOf('prop_test')
    ok(o and o.collision == true, 'static is solid')
    ok(o and o.x == ped.x + 0.5 and o.z == GROUND + 0.25 and o.pitch == 12 and o.roll == -7
       and o.yaw == 33, 'and exactly where and how it was placed, though the player is on it')
end

describe('client: display, replace and delete follow the server')
do
    bootClient()
    sync({ set = { rec(1) } })
    frames(10, 16)
    local o, handle = objOf('prop_test')
    sync({ set = { rec(1, { display = 'static' }) } })
    frame(16)
    ok(objects[handle] and objects[handle].collision == true, 'display -> static: same object, now solid')
    sync({ set = { rec(1, { model = 'prop_other' }) } })
    ok(objects[handle] == nil, 'a new model for the same id deletes the old copy at once')
    frames(10, 16)
    ok(objOf('prop_other') ~= nil and countObjects() == 1, 'and draws the new one')
    sync({ gone = { 1 } })
    eq(countObjects(), 0, 'gone deletes it')

    -- A full list replaces everything: missing ids go, new ones come.
    sync({ set = { rec(1), rec(2, { model = 'prop_other' }) } })
    frames(10, 16)
    eq(countObjects(), 2, 'two drawn')
    sync({ full = true, props = { rec(2, { model = 'prop_other' }), rec(3) } })
    frames(10, 16)
    local models = {}
    for _, ob in pairs(objects) do models[#models + 1] = ob.model end
    table.sort(models)
    eq(table.concat(models, ','), 'prop_other,prop_test', 'the full list is what is drawn')
    sync({ full = true, props = {} })
    eq(countObjects(), 0, 'and an empty full list clears the lot')
    eq(errorsOf('props.frame'), 0, 'no frame errors')
end

describe('client: a model the game does not have is refused by name')
do
    bootClient()
    sync({ set = { rec(4, { model = 'nope_model' }) } })
    ok(requestedAt[GetHashKey('nope_model')] == nil, 'not requested at all')
    ok(saidLike("#4 'nope_model' is not in this game's CD image") ~= nil, 'and F8 names it')
    frames(5, 16)
    eq(countObjects(), 0, 'nothing drawn')

    sync({ set = { rec(5, { model = 'prop_never' }) } })
    local hn = GetHashKey('prop_never')
    frames(10, 100)
    eq(countObjects(), 0, 'a model that never streams: nothing yet')
    frames(45, 100)
    ok(saidLike("#5 'prop_never' did not load within 5000 ms") ~= nil, 'after the wait, F8 names it')
    ok(released[hn] == true, 'and the request is let go')

    sync({ set = { rec(6, { model = 'a_car' }) } })
    frames(10, 16)
    ok(saidLike('refused to build it as an object') ~= nil, 'a handle of 0 is a refusal, said out loud')
    eq(countObjects(), 0, 'not an object')

    -- A record deleted while its model streams leaves nothing held.
    sync({ set = { rec(7, { model = 'prop_slow' }) } })
    local hs = GetHashKey('prop_slow')
    frame(16)
    sync({ gone = { 7 } })
    ok(released[hs] == true, 'deleted mid-stream: the model is let go')
    frames(300, 16)
    eq(countObjects(), 0, 'and it is never built')
end

describe('client: /brprop spawn streams the model, then asks -- in front, on the ground')
do
    bootClient()
    ped.heading = 0.0
    cmd('spawn PROP_Test')
    eq(#ran('spawn'), 0, 'nothing asked before the model streams')
    frames(10, 16)
    local s = ran('spawn')
    eq(#s, 1, 'asked once')
    local w = s[1] or {}
    eq(#w, 7, 'spawn <model> <display> <x> <y> <z> <yaw>')
    eq(w[2], 'prop_test', 'by its lower-cased name')
    eq(w[3], 'pickup', 'as a pickup by default')
    close(tonumber(w[4]), ped.x, 'straight ahead at heading 0: same x')
    close(tonumber(w[5]), ped.y + P.spawnAheadM + 0.5, 'spawnAheadM plus half its footprint north')
    close(tonumber(w[6]), GROUND + 0.25, 'its bottom on the ground, not its origin')
    eq(tonumber(w[7]), 0, 'facing the way he faces')
    ok(released[GetHashKey('prop_test')] == true, 'and the model is let go')
    eq(#ran('spawn'), 1, 'it is not asked twice')
    eq(#toServer, 0, 'and no net event carries it')
    handed.spawn = lastRan()

    ped.heading = 90.0
    cmd('spawn prop_test static')
    frames(10, 16)
    s = ran('spawn')
    local w2 = s[2] or {}
    close(tonumber(w2[4]), ped.x - (P.spawnAheadM + 0.5), 'heading 90 (west): in front is -x')
    eq(w2[3], 'static', 'static when asked')
    eq(tonumber(w2[7]), 90, 'facing west')
    ped.heading = 0.0

    toServer, executed = {}, {}
    cmd('spawn nope_model')
    ok(saidLike("'nope_model' is not in the game's CD image") ~= nil, 'a missing model: F8 names it')
    cmd('spawn bad/name')
    ok(saidLike('spawn refused: a model name is letters') ~= nil, 'a bad name: refused before anything')
    cmd('spawn prop_test hover')
    ok(saidLike('spawn refused: display is pickup or static') ~= nil, 'a bad display too')
    cmd('spawn prop_never')
    frames(60, 100)
    ok(saidLike("'prop_never' did not load within 5000 ms") ~= nil, 'a model that never streams is refused')
    ok(released[GetHashKey('prop_never')] == true, 'and let go')
    eq(#toServer + #executed, 0, 'and none of them asked the server anything')
end

describe('client: the pickup look, as drawn, off the loot numbers')
do
    bootClient()
    local r = rec(1, { x = ped.x + 1.0, y = ped.y, yaw = 20.0, pitch = 0 })
    sync({ set = { r } })
    frames(10, 16)
    local o = objOf('prop_test')
    -- Near: rise for longer than hoverRiseMs and look.
    local top = -math.huge
    local yaws = {}
    for _ = 1, 120 do
        frame(16)
        if o.z > top then top = o.z end
        yaws[o.yaw] = true
    end
    local lift = top - r.z
    ok(lift >= LOOT.hoverHeight - LOOT.bobAmplitude - 1e-6
       and lift <= LOOT.hoverHeight + LOOT.bobAmplitude + 1e-6,
        'near it rises by hoverHeight, give or take the bob', lift)
    local n = 0
    for _ in pairs(yaws) do n = n + 1 end
    ok(n > 50, 'and spins', n)
    ok(o.x == r.x and o.y == r.y, 'straight up, never sideways')

    -- Walk away: after hoverFallMs it is exactly the record again.
    ped.x = ped.x - 50
    frames(60, 16)
    ok(o.z == r.z and o.yaw == r.yaw and o.pitch == r.pitch and o.roll == r.roll,
        'away from it, it rests on its record exactly',
        ('z %.4f yaw %.4f'):format(o.z, o.yaw))
    ped.x = INSIDE.x

    -- THE DRAWN PROP FOLLOWS THE LOOT TABLE, read live: retune the loot and the
    -- prop moves with it. A client that drew off its own copy of the numbers
    -- (or off props_solve's fallbacks, which equal today's loot) would pass
    -- every assertion above and drift the day anybody touched the loot.
    BR.Config.Loot.hoverHeight = 1.5
    BR.Config.Loot.bobAmplitude = 0.0
    frames(120, 16)
    close(o.z - r.z, 1.5, 'with hoverHeight retuned to 1.5, it rises 1.5', 1e-9)
    BR.Config.Loot.promptDistance = 0.5
    frames(60, 16)
    eq(o.z, r.z, 'and with promptDistance cut to 0.5, 1 m away it rests')
    eq(errorsOf('props.frame'), 0, 'no frame errors')
end

-- ----------------------------------------------------------------- edit ---

local VK = { W = 0x57, S = 0x53, A = 0x41, D = 0x44, Q = 0x51, Z = 0x5A,
             J = 0x4A, L = 0x4C, I = 0x49, K = 0x4B, U = 0x55, O = 0x4F,
             F = 0x46, C = 0x43, ENTER = 0x0D, X = 0x58,
             LCTRL = 0xA2, CTRL = 0x11 }

local function bootEditing(over)
    bootClient()
    ped.x, ped.y, ped.z, ped.heading = INSIDE.x, INSIDE.y, INSIDE.z, 0.0
    camYaw = 0.0
    sync({ set = { rec(1, over) } })
    frames(10, 16)
    cmd('edit')
    serverOpens(1)
    frame(16)
    return objOf('prop_test')
end

local function lastMove()
    local m = sentOf(BR.Net.PROP_MOVE)
    return m[#m] and m[#m].data or nil
end

describe('client: edit asks the server for the session, and starts only on its answer')
do
    bootClient()
    ped.x, ped.y, ped.z = INSIDE.x, INSIDE.y, INSIDE.z
    sync({ set = { rec(1) } })
    frames(10, 16)
    local o = objOf('prop_test')
    local y = o.y
    cmd('edit')
    eq(lastRan(), 'brpropsv edit begin 1', 'edit runs `edit begin` for the nearest prop')
    frame(16)
    ok(not table.concat(drawn, '\n'):find('#1  prop_test'), 'no readout before the server answers')
    tap(VK.W)
    eq(o.y, y, 'and W moves nothing yet')
    eq(#sentOf(BR.Net.PROP_MOVE), 0, 'nor streams anything')
    cmd('edit')
    ok(saidLike('still waiting for the server to open #1') ~= nil, 'asking twice is refused')
    eq(#ran('edit begin'), 1, 'and asks once')
    serverOpens(1)
    frame(16)
    ok(table.concat(drawn, '\n'):find('#1  prop_test') ~= nil, 'the answer starts the edit')
    tap(VK.W)
    ok(o.y > y, 'and W moves it')

    -- A REFUSAL: the reason comes as a result line, then the session's close.
    bootClient()
    sync({ set = { rec(1) } })
    frames(10, 16)
    cmd('edit 1')
    TriggerEvent(BR.Net.PROP_RESULT, 'edit refused: client 3 is editing #1')
    TriggerEvent(BR.Net.PROP_EDIT, { id = 1, open = false })
    ok(saidLike('edit refused: client 3 is editing #1') ~= nil, 'the reason is on F8')
    executed = {}
    cmd('edit 1')
    eq(lastRan(), 'brpropsv edit begin 1', 'and the next edit asks again at once')

    -- AN ANSWER NOBODY ASKED FOR is handed straight back.
    bootClient()
    sync({ set = { rec(5) } })
    frames(10, 16)
    serverOpens(5)
    eq(lastRan(), 'brpropsv edit cancel 5', 'an unasked session is canceled')
    frame(16)
    ok(not table.concat(drawn, '\n'):find('#5'), 'and no edit starts')

    -- AND ONE FOR A PROP THAT WENT IN THE MEANTIME.
    bootClient()
    sync({ set = { rec(1) } })
    frames(10, 16)
    cmd('edit 1')
    sync({ gone = { 1 } })
    serverOpens(1)
    eq(lastRan(), 'brpropsv edit cancel 1', 'a session for a prop now gone is canceled')
    ok(saidLike('there is no prop #1') ~= nil, 'and F8 says why')
end

describe('client: the server can end an edit, and the edit stops at once')
do
    local o = bootEditing()
    tap(VK.W)
    frames(10, 16)
    local y = o.y
    ok(y > INSIDE.y, 'nudged first')
    -- The server's echo of the update it took: the record the stream kept current.
    sync({ set = { rec(1, { y = y }) } })
    executed = {}
    TriggerEvent(BR.Net.PROP_EDIT, { id = 1, open = false, why = 'idle for 600 s' })
    ok(saidLike('#1 edit ended by the server: idle for 600 s') ~= nil, 'F8 says so, and why')
    frame(16)
    ok(next(disabled) == nil, 'the controls are back')
    tap(VK.ENTER)
    eq(#executed, 0, 'Enter confirms nothing: there is no edit to confirm')
    tap(VK.W)
    eq(o.y, y, 'and W walks rather than nudging; the prop stays on its record')
    logged = {}
    TriggerEvent(BR.Net.PROP_EDIT, { id = 1, open = false, why = 'again' })
    ok(saidLike('ended by the server') == nil, 'a close for an edit already over says nothing')
end

describe('client: edit takes the nearest prop and shows the readout')
do
    local o = bootEditing()
    ok(saidLike('editing #1 prop_test') ~= nil, 'F8 says which')
    local all = table.concat(drawn, '\n')
    ok(all:find('#1  prop_test  %(pickup%)') ~= nil, 'the readout names id, model and display', all)
    ok(all:find('x 220%.00') ~= nil and all:find('yaw 0%.0') ~= nil, 'position and rotation')
    ok(all:find('step fine 0%.01 m / 1 deg') ~= nil, 'the step in force')
    ok(all:find('W A S D move') ~= nil and all:find('Enter confirm') ~= nil, 'and the keys')
    ok(o ~= nil, 'the copy is there')
end

describe('client: every edit key, both step sizes, through the raw key layer')
do
    local actions = {
        { 'fwd', VK.W }, { 'back', VK.S }, { 'left', VK.A }, { 'right', VK.D },
        { 'up', VK.Q }, { 'down', VK.Z },
        { 'yawLeft', VK.J }, { 'yawRight', VK.L }, { 'pitchUp', VK.I },
        { 'pitchDown', VK.K }, { 'rollLeft', VK.U }, { 'rollRight', VK.O },
    }
    for _, coarse in ipairs({ false, true }) do
        for _, cam in ipairs({ 0.0, 90.0, 215.0 }) do
            local o = bootEditing()
            camYaw = cam
            for _, a in ipairs(actions) do
                local start = { x = o.x, y = o.y, z = o.z, pitch = o.pitch, roll = o.roll, yaw = o.yaw }
                -- Ctrl as the SIDE-SPECIFIC code: the generic slot is not what
                -- the owner's build fills (client/keybinds.lua, VK_ALSO).
                if coarse then keys[VK.LCTRL] = true end
                tap(a[2])
                keys[VK.LCTRL] = nil
                local want = S.move(start, a[1], cam, coarse, P)
                local tag = ('%s %s, camera %g'):format(coarse and 'coarse' or 'fine', a[1], cam)
                ok(near(o.x, want.x, 1e-9) and near(o.y, want.y, 1e-9) and near(o.z, want.z, 1e-9)
                   and near(o.pitch, want.pitch, 1e-9) and near(o.roll, want.roll, 1e-9)
                   and near(o.yaw, want.yaw, 1e-9), tag .. ': one tap is exactly one step',
                   ('x %.3f y %.3f z %.3f p %.1f r %.1f y %.1f'):format(o.x, o.y, o.z, o.pitch, o.roll, o.yaw))
            end
        end
    end
end

describe('client: the GTA controls on the edit keys are off while editing, and only then')
do
    local o = bootEditing()
    for _, c in ipairs({ 32, 33, 34, 35, 44, 20, 23, 26, 73, 191, 201, 36, 326 }) do
        ok(disabled[c] == true, ('control %d disabled while editing'):format(c))
    end
    ok(not disabled[1] and not disabled[2], 'the mouse look is left alone')
    ok(not disabled[200] and not disabled[199], 'and so is the pause menu')
    tap(VK.ENTER)
    frame(16)
    ok(next(disabled) == nil, 'after the edit ends nothing is disabled')
    ok(o ~= nil, 'copy present')
end

describe('client: edit updates go to the server at most 10 a second, and the confirm once more')
do
    bootEditing()
    toServer = {}
    keys[VK.W] = true
    frames(125, 16)   -- two seconds
    keys[VK.W] = nil
    frames(10, 16)
    local moves = sentOf(BR.Net.PROP_MOVE)
    ok(#moves >= 15 and #moves <= 21, 'two seconds held: about twenty updates', #moves)
    local gapOk = true
    for i = 2, #moves do
        if moves[i].at - moves[i - 1].at < 100 then gapOk = false end
    end
    ok(gapOk, 'never two within 100 ms')
    local anyFinal = false
    for _, m in ipairs(moves) do if m.data.final ~= nil then anyFinal = true end end
    ok(not anyFinal, 'the stream never says final')
    ok(moves[1] and moves[1].data.id == 1, 'and names the prop')
    local before = #moves
    frames(20, 16)
    eq(#sentOf(BR.Net.PROP_MOVE), before, 'nothing sent while nothing changes')

    local o = objOf('prop_test')
    tap(VK.ENTER)
    eq(#sentOf(BR.Net.PROP_MOVE), before, 'Enter is not another stream update')
    local fin = ran('edit confirm')
    local w = fin[#fin] or {}
    ok(#fin == 1 and w[3] == '1' and #w == 9, 'Enter runs `edit confirm 1 <x y z pitch roll yaw>`', lastRan())
    ok(tonumber(w[4]) == o.x and tonumber(w[5]) == o.y and tonumber(w[6]) == o.z
       and tonumber(w[7]) == o.pitch and tonumber(w[8]) == o.roll and tonumber(w[9]) == o.yaw,
        'carrying the preview exactly', lastRan())
    ok(saidLike('#1 confirmed') ~= nil, 'and says so')
    handed.confirm = lastRan()
    frame(16)
    local y = o.y
    tap(VK.W)
    eq(o.y, y, 'after confirming, W is walking again')
    ok(o.y > INSIDE.y, 'and the prop stays where it was confirmed', o.y)
end

describe('client: cancel puts the record back, here and on the server')
do
    local o = bootEditing({ yaw = 30.0 })
    local start = { x = o.x, y = o.y, z = o.z, yaw = o.yaw }
    keys[VK.LCTRL] = true
    for _ = 1, 5 do tap(VK.D) end
    tap(VK.Q)
    tap(VK.J)
    keys[VK.LCTRL] = nil
    frames(10, 16)
    ok(o.x ~= start.x and o.z ~= start.z and o.yaw ~= start.yaw, 'moved and turned first')
    ok(#sentOf(BR.Net.PROP_MOVE) > 0, 'and the server heard about it')
    local streamed = #sentOf(BR.Net.PROP_MOVE)
    tap(VK.X)
    eq(lastRan(), 'brpropsv edit cancel 1', 'X runs `edit cancel 1`; the server keeps the original')
    eq(#sentOf(BR.Net.PROP_MOVE), streamed, 'and streams nothing more')
    frames(3, 16)
    ok(o.x == start.x and o.z == start.z and o.yaw == start.yaw, 'and the copy is back at once')
    ok(saidLike('edit canceled') ~= nil, 'F8 says so')
end

describe('client: a key held when the edit began does nothing until let go')
do
    bootClient()
    sync({ set = { rec(1) } })
    frames(10, 16)
    keys[VK.ENTER] = true
    cmd('edit 1')
    serverOpens(1)
    frames(5, 16)
    eq(#ran('edit confirm'), 0, 'the Enter that submitted the command does not confirm')
    keys[VK.ENTER] = nil
    frame(16)
    tap(VK.ENTER)
    eq(#ran('edit confirm'), 1, 'a fresh press does')

    -- AND A MOVE KEY THE SAME: W still down from walking up to the prop must
    -- not shove it the moment the edit opens.
    bootClient()
    sync({ set = { rec(1) } })
    frames(10, 16)
    local o = objOf('prop_test')
    local y = o.y
    keys[VK.W] = true
    cmd('edit 1')
    serverOpens(1)
    frames(30, 16)
    eq(o.y, y, 'W held through the start of the edit moves nothing')
    keys[VK.W] = nil
    frame(16)
    tap(VK.W)
    ok(o.y > y, 'a fresh W does')
end

describe('client: F puts the bottom on the ground, C clears the rotation')
do
    local o = bootEditing({ z = GROUND + 6.0, pitch = 30.0, roll = 10.0, yaw = 45.0 })
    tap(VK.F)
    -- The stub's own matrix finds the lowest corner; the code asked it.
    local low = math.huge
    for _, cx in ipairs({ -0.5, 0.5 }) do
        for _, cy in ipairs({ -0.5, 0.5 }) do
            for _, cz in ipairs({ -0.25, 0.75 }) do
                local w = rotate(o, o.pitch, o.roll, o.yaw, vec(cx, cy, cz))
                if w.z < low then low = w.z end
            end
        end
    end
    close(low, GROUND, 'the lowest corner sits on the ground, rotated as it is', 1e-6)
    eq(o.collision, false, 'and the collision is back as it was for a pickup')
    tap(VK.C)
    ok(o.pitch == 0 and o.roll == 0 and o.yaw == 0, 'C: no rotation at all')
end

describe('client: the preview stops where the server would refuse')
do
    -- Out at sea, outside the boundary: only nearM around the player counts.
    bootClient()
    ped.x, ped.y, ped.z = OUTSIDE.x, OUTSIDE.y, OUTSIDE.z
    camYaw = 0.0
    sync({ set = { rec(1, { x = OUTSIDE.x, y = OUTSIDE.y + P.nearM - 10, z = OUTSIDE.z }) } })
    frames(10, 16)
    cmd('edit 1')
    serverOpens(1)
    frame(16)   -- one frame with nothing held, or the hold is never armed
    keys[VK.LCTRL], keys[VK.W] = true, true
    frames(450, 16)
    keys[VK.LCTRL], keys[VK.W] = nil, nil
    frame(16)
    local o = objOf('prop_test')
    local d = math.sqrt((o.x - ped.x) ^ 2 + (o.y - ped.y) ^ 2 + (o.z - ped.z) ^ 2)
    ok(d <= P.nearM and d > P.nearM - 1, 'held forward it stops at nearM', d)
    ok(saidLike('#1 stops here') ~= nil, 'and says why, once')
    local stops = 0
    for _, l in ipairs(logged) do if l:find('stops here') then stops = stops + 1 end end
    eq(stops, 1, 'only once')
    ped.x, ped.y, ped.z = INSIDE.x, INSIDE.y, INSIDE.z
end

describe('client: a key the player has bound is his, not the edit\'s')
do
    bootClient()
    sync({ set = { rec(1) } })
    frames(10, 16)
    BR.Keys.set('brslot1', VK.J)
    local fired = 0
    BR.Keys.on('slot1', function(pressed) if pressed then fired = fired + 1 end end)
    cmd('edit 1')
    serverOpens(1)
    ok(saidLike("J is your key for 'Royale: Slot 1'") ~= nil, 'F8 says J is taken, and by what')
    local o = objOf('prop_test')
    local yaw = o.yaw
    tap(VK.J)
    eq(o.yaw, yaw, 'J does not turn the prop')
    eq(fired, 1, 'J is still slot 1')
    local all = table.concat(drawn, '\n')
    ok(all:find('%- L yaw') ~= nil, 'and the readout shows J as off', all)
    tap(VK.L)
    ok(o.yaw ~= yaw, 'L still turns it')
end

describe('client: edit refuses when it cannot work, and ends when its prop goes')
do
    bootClient()
    cmd('edit')
    ok(saidLike('no prop within 50 m') ~= nil, 'nothing near: said so')
    sync({ set = { rec(2, { model = 'nope_model' }) } })
    cmd('edit 2')
    ok(saidLike('#2 is not drawn on this client') ~= nil, 'a prop this client cannot draw: said so')
    cmd('edit 9')
    ok(saidLike('there is no prop #9') ~= nil, 'an unknown id: said so')
    eq(#executed, 0, 'and none of them asked the server')

    bootClient()
    sync({ set = { rec(1) } })
    frames(10, 16)
    BR.Keys.rawActive = false
    cmd('edit 1')
    ok(saidLike('edit needs the raw key layer') ~= nil, 'no raw key layer: refused, with where to look')

    bootEditing()
    cmd('edit 1')
    ok(saidLike('already editing #1') ~= nil, 'a second edit is refused')
    sync({ gone = { 1 } })
    ok(saidLike('#1 was deleted while you were editing it') ~= nil, 'deleted mid-edit: said so')
    frame(16)
    ok(next(disabled) == nil, 'and the controls are back')

    -- One of our screens holding the keyboard: keys are not nudges.
    local o = bootEditing()
    BR.Keys.uiOwnsKeyboard = true
    local y = o.y
    tap(VK.W)
    eq(o.y, y, 'a key typed into a screen does not move the prop')
    BR.Keys.uiOwnsKeyboard = false
end

describe('client: the server\'s echo does not fight the preview')
do
    local o = bootEditing()
    tap(VK.W)
    local y = o.y
    sync({ set = { rec(1) } })   -- an older position arriving mid-edit
    frame(16)
    eq(o.y, y, 'the preview holds')
    sync({ set = { rec(1, { display = 'static' }) } })
    frame(16)
    eq(o.y, y, 'through a display change too')
    ok(table.concat(drawn, ' | '):find('%(static%)') ~= nil, 'which the readout does take')
    eq(o.collision, true, 'and the copy is solid now')
end

describe('client: the other verbs ask the server for exactly what was typed')
do
    bootClient()
    sync({ set = { rec(3, { yaw = 90, x = 1.5, y = 2.25, z = 3.125 }) } })
    toServer, executed = {}, {}
    cmd('delete 3')
    cmd('delete ALL')
    cmd('display 3 STATIC')
    cmd('save')
    cmd('load')
    eq(table.concat(executed, ' | '),
        'brpropsv delete 3 | brpropsv delete all | brpropsv display 3 static | brpropsv save | brpropsv load',
        'each runs brpropsv with exactly what was typed')
    eq(#toServer, 0, 'and no net event')

    executed = {}
    cmd('delete')
    cmd('display 3')
    cmd('display x static')
    eq(#executed, 0, 'a malformed verb asks nothing')

    logged = {}
    cmd('where 3')
    ok(saidLike("{ model = 'prop_test', display = 'pickup', x = 1.500, y = 2.250, z = 3.125") ~= nil,
        'where prints the paste line')
    cmd('list')
    ok(saidLike('#3 +prop_test') ~= nil, 'list lists it')
    eq(#executed + #toServer, 0, 'where and list read this client\'s records and ask nothing')
    logged = {}
    cmd('')
    ok(saidLike('usage: brprop spawn <model>') ~= nil, 'bare prints the usage')
    TriggerEvent(BR.Net.PROP_RESULT, 'spawned #4 x')
    ok(saidLike('brprop: spawned #4 x') ~= nil, 'the server\'s answer is printed on F8')
end

describe('client: resource stop deletes every local copy and lets every model go')
do
    bootClient()
    sync({ set = { rec(1), rec(2, { model = 'prop_other' }) } })
    frames(10, 16)
    sync({ set = { rec(3, { model = 'prop_slow' }) } })
    -- A DIFFERENT model for the pending spawn, so its release is its own and
    -- not the streaming copy's.
    cmd('spawn prop_never')
    frame(16)
    cmd('edit 1')
    serverOpens(1)
    eq(countObjects(), 2, 'two drawn, one streaming, a spawn pending, an edit open')
    TriggerEvent('onResourceStop', 'some_other_resource')
    eq(countObjects(), 2, 'another resource stopping changes nothing')
    ok(released[GetHashKey('prop_never')] == nil, 'nor lets anything go')
    TriggerEvent('onResourceStop', 'br_core')
    eq(countObjects(), 0, 'br_core stopping deletes every copy')
    ok(released[GetHashKey('prop_slow')] == true, 'and lets the streaming model go')
    ok(released[GetHashKey('prop_never')] == true, 'and the pending spawn\'s')
    frame(16)
    ok(next(disabled) == nil, 'and the edit is over')
    eq(errorsOf('props.frame'), 0, 'no frame errors anywhere in the client suite')
end

-- =========================================================================
-- PART D -- the client's own lines, typed into the server
-- =========================================================================
--
-- PARTS B AND C EACH PIN ONE SIDE OF THE COMMAND LINE. This is the seam: the
-- exact strings client/props.lua handed ExecuteCommand above, split the way
-- the console splits them, run through the real server/props.lua behind the
-- real dev gate. A field renamed or reordered on one side only fails here.

describe('the lines the client runs are the lines the server reads')
do
    ok(handed.spawn ~= nil and handed.confirm ~= nil, 'PART C handed over a spawn and a confirm',
        tostring(handed.spawn) .. ' / ' .. tostring(handed.confirm))
    bootServer()
    local function words(line)
        local w = {}
        for x in (line or ''):gmatch('%S+') do w[#w + 1] = x end
        return w
    end
    local function typed(line)
        local rest = (line or ''):gsub('^brpropsv ', '', 1)
        sv(1, rest)
    end

    typed(handed.spawn)
    local sw = words(handed.spawn)
    local r = BR.Props.get(1)
    ok(r ~= nil and r.model == sw[3] and r.display == sw[4], 'the spawn line makes that prop', handed.spawn)
    ok(r ~= nil and r.x == tonumber(sw[5]) and r.y == tonumber(sw[6]) and r.z == tonumber(sw[7])
       and r.yaw == S.angle(tonumber(sw[8]) or 0 / 0), 'where the client put it, to the bit')

    typed('brpropsv edit begin 1')
    eq(BR.Props.editing(1), 1, 'edit begin opens the session the confirm needs')
    typed(handed.confirm)
    local cw = words(handed.confirm)
    local c = BR.Props.get(1)
    ok(c ~= nil and c.x == tonumber(cw[5]) and c.y == tonumber(cw[6]) and c.z == tonumber(cw[7])
       and c.pitch == tonumber(cw[8]) and c.roll == tonumber(cw[9]) and c.yaw == tonumber(cw[10]),
        'the confirm line puts it exactly where the preview was', handed.confirm)
    eq(BR.Props.editing(1), nil, 'and closes the session')
    ok((lastResult(1) or ''):find('#1 placed') ~= nil, 'and is answered', lastResult(1))
end

print = realPrint
realPrint(('\n%d passed, %d failed'):format(pass, fail))
if fail > 0 then os.exit(1) end
