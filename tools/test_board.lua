-- Unit tests for the warmup-area stat board (#247).
--
-- ═══════════════════════════════════════════════════════════════════════════
-- WHAT CAN BE TESTED HERE, AND WHAT CANNOT
-- ═══════════════════════════════════════════════════════════════════════════
--
-- There is no FiveM in this file and there is certainly no Chromium. Whether
-- CreateDui actually opens a browser, whether Ringmaster answers, whether a
-- 1280x720 page is legible from six meters, and what a DrawSpritePoly looks like
-- on a prop nobody has named yet are all questions only a playtest answers.
--
-- What IS answerable is every decision the Lua makes on the way there, and this
-- feature is mostly decisions:
--
--   PART A  br_lib/config/board.lua. One pure function builds the one string
--           this feature depends on, and a wrong URL is a browser sitting on an
--           error page with nothing anywhere saying why. The owner wrote the URL
--           out in full; it is pinned here as a LITERAL, because a test that
--           rebuilt it from the config would agree with any edit to the config.
--
--   PART B  br_core/server/board.lua. One push, and three ways to get it wrong
--           that all look like it working: sending the qualified `license:...`
--           form (which would answer HTTP 400 and show an error page),
--           broadcasting an identifier to the lobby instead of to its owner, and
--           sending something when FiveM reported no license at all.
--
--   PART C  br_core/client/dui.lua's new quad. drawBoard is drawFace with a
--           lateral and a yaw, and both are exactly the kind of arithmetic that
--           looks right and comes out mirrored. Stood on a prop with a real
--           pose, the way tools/test_shop.lua stands the same file on a car.
--
--   PART D  br_core/client/board.lua. The lifecycle the issue is explicit about
--           -- one browser, created on entry to warmup, destroyed on the way
--           out, never recreated to change what is on it -- plus the health
--           state, the draw gate and the tuning command.
--
-- Run via tools/verify.sh, or directly:  lua tools/test_board.lua

local realPrint = print
local realExit  = os.exit

local ROOT = 'resources/[fivem-royale]/'
local function loadAll(files)
    for _, f in ipairs(files) do
        local chunk, err = loadfile(ROOT .. f)
        if not chunk then
            realPrint('\27[31mload error\27[0m ' .. f .. ': ' .. tostring(err))
            realExit(1)
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
        and math.abs(a - b) <= (tol or 0.0005)
end

-- =========================================================================
-- PART A -- the URL
-- =========================================================================

loadAll({
    'br_lib/shared/enums.lua',
    'br_lib/shared/protocol.lua',
    'br_lib/shared/identity.lua',
    'br_lib/config/board.lua',
})

local B = BR.Config.Board

describe('the URL is the one the owner wrote out')
do
    -- ═══ HIS OWN EXAMPLE, PINNED AS A LITERAL ═══
    --
    -- Owner, 2026-09-09: "if their license is
    -- b6f5a1273092df7eb6a8c2a981418f275f2ae3fb, the URL would be like
    -- https://ringmaster.blitz-royale.com/scoreboard?id=b6f5a127..."
    --
    -- Written out whole rather than assembled from B.host and B.path. Assembling
    -- it would make this assertion agree with a typo in either field, which is
    -- the one thing it is here to catch.
    local LIC = 'b6f5a1273092df7eb6a8c2a981418f275f2ae3fb'
    eq(BR.BoardUrl(LIC),
        'https://ringmaster.blitz-royale.com/scoreboard'
            .. '?id=b6f5a1273092df7eb6a8c2a981418f275f2ae3fb',
        'the shipped config builds exactly his URL')

    -- THE HOST IS A VALUE, WHICH IS THE POINT OF SPLITTING IT OUT. A staging
    -- deployment is one config edit and no Lua change.
    eq(BR.BoardUrl(LIC, { host = 'https://staging.example', path = '/scoreboard' }),
        'https://staging.example/scoreboard?id=' .. LIC,
        'and a different host moves the whole URL with it')

    -- NO SEPARATOR IS INVENTED OR REMOVED. `host` carries no trailing slash and
    -- `path` carries its own leading one; a builder that "helpfully" normalised
    -- either would make the two fields disagree about who owns the slash.
    eq(BR.BoardUrl(LIC, { host = 'https://h', path = '/a/b' }),
        'https://h/a/b?id=' .. LIC,
        'the join is host .. path and nothing else')
end

describe('a license that is not hex builds no URL at all')
do
    -- ═══ THIS IS ABOUT WHAT A STRAY VALUE WOULD DO, NOT ABOUT TRUST ═══
    --
    -- The license comes off our own server's FiveM connection, so nobody is
    -- forging it. But the result is handed to CreateDui: a value carrying '#',
    -- '&', '?' or a space silently addresses something other than the board, and
    -- a browser pointed somewhere unknown is the failure with no symptom.
    --
    -- EACH OF THESE IS A DIFFERENT WAY TO CHANGE THE ADDRESS, and every one of
    -- them would have been accepted by a bare `if license ~= '' then`.
    ok(BR.BoardUrl('abc#frag') == nil, 'a fragment cannot be smuggled in')
    ok(BR.BoardUrl('abc&x=1') == nil, 'nor a second query parameter')
    ok(BR.BoardUrl('abc/../other') == nil, 'nor a path segment')
    ok(BR.BoardUrl('abc def') == nil, 'nor whitespace')
    ok(BR.BoardUrl('license:b6f5a127') == nil,
        'and the QUALIFIED form is refused, because a colon in a query string '
            .. 'is a 400 rather than a board')

    ok(BR.BoardUrl('') == nil, 'an empty license builds nothing')
    ok(BR.BoardUrl(nil) == nil, 'and so does nil, which is a real answer FiveM '
        .. 'gives and not an error')
    ok(BR.BoardUrl(12345) == nil, 'and a number is not a license')

    -- BOTH CASES OF HEX. FiveM writes lowercase, but a value that had been
    -- through an uppercasing round trip somewhere is still the same key and
    -- still safe in a URL.
    ok(BR.BoardUrl('B6F5A127') ~= nil, 'uppercase hex is still hex')

    -- AND NO LENGTH PIN. Forty characters is what this build produces; pinning
    -- it would present a future FiveM change as "the board stopped working".
    ok(BR.BoardUrl('ab') ~= nil, 'a short hex license is not rejected for length')
end

describe('the config is inert until the owner names a prop')
do
    -- ⚠ THE ONE ASSERTION IN THIS FILE THAT IS MEANT TO BE DELETED. He has a
    -- prop in mind and has not said which. Until he does, the shipped config
    -- must not conjure one -- and the whole feature is gated on this field, so a
    -- placeholder model here would put an unasked-for object on the warmup pad.
    eq(B.prop.model, nil, 'no model ships')
    eq(B.prop.x, nil, 'and no coordinates ship with it')

    -- THE TEXTURE MATCHES THE PAGE. Ringmaster's src/lib/scoreboard.ts pins
    -- BOARD_WIDTH/BOARD_HEIGHT at 1280x720 and writes a fixed-pixel document
    -- with overflow hidden; a texture of another size crops the page or leaves a
    -- band of background, and neither says a word anywhere.
    eq(B.width, 1280, 'the texture is 1280 wide, matching BOARD_WIDTH')
    eq(B.height, 720, 'and 720 tall, matching BOARD_HEIGHT')
end

-- =========================================================================
-- PART B -- the license reaches the client
-- =========================================================================
--
-- ═══ THREE FAILURES THAT ALL LOOK LIKE IT WORKING ═══
--
-- A push that fires, carries a string, and reaches a client passes any check
-- that only asks whether something was sent. What separates a working board from
-- a browser on a 400 page is WHICH string and WHICH client.

local sends = {}
local handlers = {}

function RegisterNetEvent() end
function AddEventHandler(name, fn) handlers[name] = fn end
function TriggerClientEvent(name, target, payload)
    sends[#sends + 1] = { name = name, target = target, payload = payload }
end

--- The identifiers FiveM is pretending to report, per source.
---
--- THE REAL TWO NATIVES, AND NOT A SHORTCUT PAST BR.Identity. BR.Identity.rawOf
--- walks GET_NUM_PLAYER_IDENTIFIERS and GET_PLAYER_IDENTIFIER by index, and
--- parse() then allowlists and strips the prefix -- which is the step that turns
--- `license:b6f5...` into the bare hex the URL needs. Stubbing licenseOf itself
--- would skip exactly the transformation under test, and an `ip:` row is fed in
--- below so the allowlist is doing real work rather than being trusted.
local identifiers = {}
function GetNumPlayerIdentifiers(src)
    return #(identifiers[tonumber(src)] or {})
end
function GetPlayerIdentifier(src, i)
    return (identifiers[tonumber(src)] or {})[i + 1]
end

loadAll({ 'br_core/server/board.lua' })

--- Fire READY as one client.
local function ready(src)
    sends = {}
    -- `source` IS A GLOBAL IN FXSERVER and the handler reads it. Setting it here
    -- is what makes "read it once into a local" a claim this file can check.
    _G.source = src
    handlers[BR.Net.READY]()
    _G.source = nil
    return sends
end

describe('the server hands one client its own license')
do
    identifiers[7] = {
        'license:b6f5a1273092df7eb6a8c2a981418f275f2ae3fb',
        'discord:1234',
        'ip:203.0.113.9',
    }

    local out = ready(7)
    eq(#out, 1, 'READY pushes exactly one message')
    eq(out[1].name, BR.Net.BOARD_ID, 'on BR.Net.BOARD_ID')

    -- ═══ TO THAT SOURCE, NEVER TO -1 ═══
    --
    -- An identifier broadcast to the lobby is a different feature with a
    -- different argument behind it. -1 is the value that would do it and it is
    -- one character away from `src`.
    eq(out[1].target, 7, 'addressed to the player it describes and nobody else')

    -- ═══ BARE, NOT QUALIFIED ═══
    --
    -- BR.Identity.qualified puts `license:` back for the paths that STORE a
    -- license -- br_stats keys rows on it. A query string is not one of those
    -- paths: Ringmaster's route normalises `id` and answers 400 to a colon, so
    -- the qualified form is a board that is permanently an error page.
    eq(out[1].payload, 'b6f5a1273092df7eb6a8c2a981418f275f2ae3fb',
        'and carries the BARE hex, which is what the URL takes')

    -- AND IT IS A URL THE MOMENT IT ARRIVES, which is the only thing the client
    -- does with it. Composing the two halves here is what proves the wire format
    -- and the builder agree; either alone would pass while they disagreed.
    eq(BR.BoardUrl(out[1].payload),
        'https://ringmaster.blitz-royale.com/scoreboard'
            .. '?id=b6f5a1273092df7eb6a8c2a981418f275f2ae3fb',
        'the pushed value builds the owner\'s URL with no further work')
end

describe('no license means no push')
do
    -- FiveM does not always report one, and BR.Identity.licenseOf answers nil
    -- rather than inventing a key. A push of nil, or of the empty string, would
    -- reach the client and make it build `?id=` -- a 400, forever, with the
    -- client believing it had been told.
    identifiers[8] = { 'discord:999', 'steam:110000100000000' }
    eq(#ready(8), 0, 'a player with no license is sent nothing')

    identifiers[9] = {}
    eq(#ready(9), 0, 'and neither is one with no identifiers at all')
end

-- =========================================================================
-- PART C -- the quad on the prop
-- =========================================================================
--
-- ═══ WHY THIS IS NOT drawFace's TEST AGAIN ═══
--
-- tools/test_shop.lua already stands client/dui.lua on a car with a real pose
-- and proves the yard sign is leveled, unmirrored, wound toward the camera and
-- measured in meters. drawBoard is that function with two terms drawFace does
-- not have, and BOTH are the kind of arithmetic that looks right and comes out
-- backwards:
--
--   THE LATERAL, which must move the board the way it looks like it should move
--   FROM WHERE THE READER IS STANDING. Positive is the reader's right. Get the
--   sign wrong and every alignment session pushes the board the wrong way.
--
--   THE YAW, which turns the board off the prop's own facing. It exists because
--   a prop's forward vector is the modeller's choice: plenty of GTA props face
--   along their local -Y. Get the sense wrong and 90 degrees puts the board
--   edge-on and looks like it vanished.

local dui = {}
do
    -- A PROP WITH A REAL POSE, tilted, so "leveled" is a claim with something to
    -- level. The same construction tools/test_shop.lua uses for the car, for the
    -- same reason: a fixture whose forward vector could disagree with its
    -- position would let a wrong quad pass by reading a different prop.
    local PROP = { h = 40.0, pitch = 7.0, roll = 11.0,
                   x = 120.0, y = 200.0, z = 30.0 }
    local ENT = 42

    local function axes()
        local ch, sh = math.cos(math.rad(PROP.h)), math.sin(math.rad(PROP.h))
        local cp, sp = math.cos(math.rad(PROP.pitch)), math.sin(math.rad(PROP.pitch))
        local cr, sr = math.cos(math.rad(PROP.roll)), math.sin(math.rad(PROP.roll))
        local function body(vx, vy, vz)
            vx, vz = vx * cr + vz * sr, vz * cr - vx * sr
            vy, vz = vy * cp - vz * sp, vy * sp + vz * cp
            vx, vy = vx * ch - vy * sh, vx * sh + vy * ch
            return { vx, vy, vz }
        end
        return body(1.0, 0.0, 0.0), body(0.0, 1.0, 0.0), body(0.0, 0.0, 1.0)
    end

    function GetEntityCoords() return { x = PROP.x, y = PROP.y, z = PROP.z } end
    function GetEntityForwardVector()
        local _, fwd = axes()
        return { x = fwd[1], y = fwd[2], z = fwd[3] }
    end
    function GetOffsetFromEntityInWorldCoords(_, lx, ly, lz)
        local rt, fwd, up = axes()
        return {
            x = PROP.x + rt[1] * lx + fwd[1] * ly + up[1] * lz,
            y = PROP.y + rt[2] * lx + fwd[2] * ly + up[2] * lz,
            z = PROP.z + rt[3] * lx + fwd[3] * ly + up[3] * lz,
        }
    end
    function GetEntityModel() return 1 end
    function GetModelDimensions()
        return { x = -1.0, y = -0.2, z = 0.0 }, { x = 1.0, y = 0.2, z = 2.0 }
    end

    -- DoesEntityExist ANSWERS 1 AND 0, NOT true AND false, which is what the
    -- runtime does and what the ratchet in tools/verify.sh exists for. A stub
    -- answering Lua booleans would let a bare `if DoesEntityExist(e)` pass.
    function DoesEntityExist() return 1 end
    function IsDuiAvailable() return 1 end

    local cam = { x = 120.0, y = 190.0, z = 31.0 }
    function GetGameplayCamCoord() return cam end

    -- BR.Dui.ready pushes the interface-size preference the first frame a
    -- browser answers, and that push encodes. Nothing here reads the result;
    -- the stub exists so the file under test can take its ordinary path.
    json = { encode = function() return '{}' end }

    function CreateDui() return 1 end
    function GetDuiHandle() return 2 end
    function CreateRuntimeTxd() return 3 end
    function CreateRuntimeTextureFromDuiHandle() end
    function SendDuiMessage() end
    function DestroyDui() end
    function SetDuiUrl() end

    -- THE BILLBOARD NATIVES ARE DEFINED AND MUST NEVER FIRE. If drawBoard ever
    -- reaches for SetDrawOrigin it is a screen-space sprite again, whatever else
    -- it does, and a board pinned to a prop is exactly what it must not be.
    dui.originDraws = 0
    function SetDrawOrigin() dui.originDraws = dui.originDraws + 1 end
    function DrawSprite() dui.originDraws = dui.originDraws + 1 end
    function ClearDrawOrigin() end
    function GetAspectRatio() return 1.7778 end
    function GetActiveScreenResolution() return 1920, 1080 end

    dui.polys = {}
    function DrawSpritePoly(x1, y1, z1, x2, y2, z2, x3, y3, z3,
                            _r, _g, _b, _a, _txd, _tex,
                            u1, v1, _w1, u2, v2, _w2, u3, v3, _w3)
        dui.polys[#dui.polys + 1] = {
            v  = { { x1, y1, z1 }, { x2, y2, z2 }, { x3, y3, z3 } },
            uv = { { u1, v1 }, { u2, v2 }, { u3, v3 } },
        }
    end

    function BR.Clamp(v, lo, hi)
        if v < lo then return lo end
        if v > hi then return hi end
        return v
    end

    loadAll({ 'br_lib/shared/geo.lua', 'br_core/client/dui.lua' })

    dui.page = BR.Dui.page('boardprobe', 'about:blank', 1280, 720)
    dui.ENT = ENT
    dui.PROP = PROP

    dui.draw = function(fwd, side, up, w, yaw)
        dui.polys = {}
        BR.Dui.drawBoard(dui.page, ENT, fwd, side, up, w, yaw)
        return dui.polys
    end

    --- The vertex carrying a given UV, from whichever triangle holds it.
    dui.at = function(u, v)
        for _, p in ipairs(dui.polys) do
            for i = 1, 3 do
                if p.uv[i][1] == u and p.uv[i][2] == v then return p.v[i] end
            end
        end
        return nil
    end
end

local function dist3(p, q)
    local dx, dy, dz = p[1] - q[1], p[2] - q[2], p[3] - q[3]
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

describe('drawBoard is a quad in the world, not a sprite on the screen')
do
    local W = 2.4
    dui.draw(0.06, 0.0, 1.2, W, 0.0)
    eq(#dui.polys, 2, 'two triangles of world geometry')
    eq(dui.originDraws, 0,
        'and not one SetDrawOrigin or DrawSprite -- the screen-space path is '
            .. 'not reached at all')

    local tl, tr = dui.at(0.0, 0.0), dui.at(1.0, 0.0)
    local bl = dui.at(0.0, 1.0)
    ok(tl and tr and bl and dui.at(1.0, 1.0), 'all four texture corners placed')

    -- MEASURED IN METERS, AND THE HEIGHT FOLLOWS THE TEXTURE. 1280x720 is 9:16
    -- of its width tall, so widthM is one number and the picture can never be
    -- stretched by a second one drifting from it.
    ok(near(dist3(tl, tr), W, 0.001), 'exactly widthM across',
        ('%.4f'):format(dist3(tl, tr)))
    ok(near(dist3(tl, bl), W * (720 / 1280), 0.001),
        'and the page\'s own aspect tall', ('%.4f'):format(dist3(tl, bl)))

    -- LEVEL, THOUGH THE PROP IS PITCHED 7 DEGREES AND ROLLED 11. The top edge
    -- is horizontal and the side edge is vertical; a quad built out of the
    -- prop's whole matrix would wear both angles.
    ok(near(tl[3], tr[3], 0.0005), 'the top edge is level in the world',
        ('%.4f vs %.4f'):format(tl[3], tr[3]))
    ok(near(tl[1], bl[1], 0.0005) and near(tl[2], bl[2], 0.0005),
        'and the side edge is straight up it')
end

describe('the lateral moves the board to the READER\'S right')
do
    -- ═══ THE FAILURE THIS CATCHES IS A BOARD THAT SLIDES THE WRONG WAY ═══
    --
    -- Both halves are asserted together on purpose. Positive `side` must move
    -- the board toward the corner the texture's RIGHT edge is at -- so the
    -- offset and the writing agree, and an alignment session that nudges right
    -- sees it go right from the only side anybody stands on.
    dui.draw(0.06, 0.0, 1.2, 2.4, 0.0)
    local tl0, tr0 = dui.at(0.0, 0.0), dui.at(1.0, 0.0)

    dui.draw(0.06, 0.5, 1.2, 2.4, 0.0)
    local tl1, tr1 = dui.at(0.0, 0.0), dui.at(1.0, 0.0)

    -- It moved half a meter.
    ok(near(dist3(tl0, tl1), 0.5, 0.001), 'a side of 0.5 moves it half a meter',
        ('%.4f'):format(dist3(tl0, tl1)))

    -- ...and it moved TOWARD the right-hand edge rather than away from it. The
    -- displacement projected onto (right edge minus left edge) must be positive.
    local ex, ey = tr0[1] - tl0[1], tr0[2] - tl0[2]
    local dx, dy = tl1[1] - tl0[1], tl1[2] - tl0[2]
    ok(ex * dx + ey * dy > 0.0,
        'and toward the texture\'s right edge, so the nudge and the writing '
            .. 'agree about which way is right')

    -- AND IT STAYED ON THE SAME PANEL. Sliding sideways must not change how far
    -- off the prop the board stands, or a tuned stand-off would have to be
    -- retuned every time the board moved along.
    ok(near(dist3(tl1, tr1), 2.4, 0.001), 'the board is unchanged in size')
    ok(near(tl0[3], tl1[3], 0.0005), 'and unchanged in height')
end

describe('the yaw turns the board off the prop\'s own facing')
do
    -- ═══ WHY THIS TERM EXISTS ═══
    --
    -- A prop's forward vector is the modeller's choice, not ours. Without a yaw,
    -- aligning the board would mean rotating the PROP away from the direction
    -- the owner wants the prop to face.
    dui.draw(1.0, 0.0, 1.2, 2.4, 0.0)
    local a0, b0 = dui.at(0.0, 0.0), dui.at(1.0, 0.0)
    local n0x, n0y = b0[1] - a0[1], b0[2] - a0[2]

    dui.draw(1.0, 0.0, 1.2, 2.4, 90.0)
    local a1, b1 = dui.at(0.0, 0.0), dui.at(1.0, 0.0)
    local n1x, n1y = b1[1] - a1[1], b1[2] - a1[2]

    -- NINETY DEGREES IS A RIGHT ANGLE, which is the whole claim. The top edge's
    -- direction turns by exactly that much, so the dot product of the two goes
    -- to zero -- and it is checked as a dot rather than by comparing angles,
    -- because an angle comparison would pass for 90 and for 270 alike.
    local l0 = math.sqrt(n0x * n0x + n0y * n0y)
    local l1 = math.sqrt(n1x * n1x + n1y * n1y)
    ok(near((n0x * n1x + n0y * n1y) / (l0 * l1), 0.0, 0.001),
        'a yaw of 90 turns the board through a right angle',
        ('%.4f'):format((n0x * n1x + n0y * n1y) / (l0 * l1)))

    -- ...COUNTER-CLOCKWISE SEEN FROM ABOVE, which is the sense the config
    -- documents. The 2D cross product of before and after is positive for a
    -- counter-clockwise turn, and this is the assertion that tells 90 from -90.
    ok(n0x * n1y - n0y * n1x > 0.0,
        'and counter-clockwise seen from above, as the config says')

    -- A FULL TURN IS THE IDENTITY, which catches a yaw applied in the wrong
    -- unit: 360 radians is not 360 degrees, and only one of them comes back to
    -- where it started.
    dui.draw(1.0, 0.0, 1.2, 2.4, 360.0)
    local a2 = dui.at(0.0, 0.0)
    ok(near(a2[1], a0[1], 0.002) and near(a2[2], a0[2], 0.002),
        'and 360 degrees is the identity, so the term is in degrees')

    -- ZERO IS drawFace's OWN ANSWER. The whole reason drawBoard reuses that
    -- file's basis and quad rather than deriving its own is that the two must
    -- not come to disagree; at yaw 0 and side 0 they are the same geometry.
    dui.polys = {}
    BR.Dui.drawFace(dui.page, dui.ENT, 1.0, 1.2, 2.4)
    local f = dui.at(0.0, 0.0)
    ok(near(f[1], a0[1], 0.0005) and near(f[2], a0[2], 0.0005)
        and near(f[3], a0[3], 0.0005),
        'and at yaw 0 with no lateral it is drawFace exactly')
end

-- ---------------------------------------------------------------- report ---

realPrint(('\n%s  board: %d passed, %d failed')
    :format(fail == 0 and '\27[32mPASS\27[0m' or '\27[31mFAIL\27[0m', pass, fail))
realExit(fail == 0 and 0 or 1)
