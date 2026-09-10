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

    -- ═══ HANDLE-AWARE FROM THE START, BECAUSE PART D SHARES THIS WORLD ═══
    --
    -- ENT is the tilted fixture drawBoard is measured against. Part D lets
    -- client/board.lua BUILD its own prop and stand a ped near it, and both have
    -- to be readable through the same natives -- a stub that answered one fixed
    -- position for every handle would let a lifecycle bug (drawing on a handle
    -- that was deleted, say) pass by reading the fixture instead.
    dui.PED = 1
    dui.ped = { x = 0.0, y = 0.0, z = 0.0, h = 0.0 }
    dui.objects = {}
    dui.nextObj = 100

    function PlayerPedId() return dui.PED end

    function GetEntityCoords(e)
        if e == ENT then return { x = PROP.x, y = PROP.y, z = PROP.z } end
        if e == dui.PED then
            return { x = dui.ped.x, y = dui.ped.y, z = dui.ped.z }
        end
        local o = dui.objects[e]
        if o then return { x = o.x, y = o.y, z = o.z } end
        return { x = 0.0, y = 0.0, z = 0.0 }
    end

    function GetEntityForwardVector(e)
        if e == ENT then
            local _, fwd = axes()
            return { x = fwd[1], y = fwd[2], z = fwd[3] }
        end
        local o = dui.objects[e]
        local h = math.rad((o and o.heading) or 0.0)
        return { x = -math.sin(h), y = math.cos(h), z = 0.0 }
    end

    function GetEntityHeading(e)
        if e == dui.PED then return dui.ped.h end
        local o = dui.objects[e]
        return (o and o.heading) or 0.0
    end
    function SetEntityHeading(e, v)
        local o = dui.objects[e]
        if o then o.heading = v end
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
    function DoesEntityExist(e)
        if e == ENT then return 1 end
        return dui.objects[e] and 1 or 0
    end
    function IsDuiAvailable() return 1 end

    -- ═══ OBJECTS ARE MADE AND DESTROYED FOR REAL, AND BOTH ARE COUNTED ═══
    --
    -- A board that leaks a prop per warmup and a board that keeps one are the
    -- same picture. Counting is the only way to tell them apart from outside.
    dui.made, dui.deleted = 0, 0
    dui.modelLoaded = true
    dui.requests = {}

    -- FORGIVING ON PURPOSE. A nil model has to be refused by `sited()` long
    -- before it reaches here, and that refusal is an assertion below. If this
    -- stub threw on nil the way a length operator does, deleting that gate would
    -- blow the suite up with a stack trace instead of failing the assertion that
    -- names the rule, and a crash is a much worse diagnosis than a FAIL line.
    function GetHashKey(s)
        if type(s) ~= 'string' then return 0 end
        local h = 5381
        for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
        return h
    end
    function HasModelLoaded() return dui.modelLoaded and 1 or 0 end
    function RequestModel(m) dui.requests[#dui.requests + 1] = m end
    function SetModelAsNoLongerNeeded() end
    function CreateObjectNoOffset(model, x, y, z)
        dui.nextObj = dui.nextObj + 1
        dui.objects[dui.nextObj] = { model = model, x = x, y = y, z = z,
                                     heading = 0.0 }
        dui.made = dui.made + 1
        return dui.nextObj
    end
    function DeleteEntity(e)
        if dui.objects[e] then dui.deleted = dui.deleted + 1 end
        dui.objects[e] = nil
    end
    function FreezeEntityPosition() end
    function SetEntityAsMissionEntity() end
    function GetCurrentResourceName() return 'br_core' end

    local cam = { x = 120.0, y = 190.0, z = 31.0 }
    function GetGameplayCamCoord() return cam end

    -- BR.Dui.ready pushes the interface-size preference the first frame a
    -- browser answers, and that push encodes. Nothing here reads the result;
    -- the stub exists so the file under test can take its ordinary path.
    json = { encode = function() return '{}' end }

    -- ═══ EVERY BROWSER IS COUNTED AND EVERY NAVIGATION IS RECORDED ═══
    --
    -- The issue's rule is one browser, refreshed with SetDuiUrl and never
    -- recreated to change what is on it. A fixture that did not count could not
    -- tell a swap from a leak: both put the right picture on the prop, and only
    -- one of them costs a Chromium instance per match.
    dui.created = {}
    dui.destroyed = 0
    dui.navigations = {}

    function CreateDui(url)
        dui.created[#dui.created + 1] = url
        return 900 + #dui.created
    end
    function GetDuiHandle() return 2 end
    function CreateRuntimeTxd() return 3 end
    function CreateRuntimeTextureFromDuiHandle() end
    function SendDuiMessage() end
    function DestroyDui() dui.destroyed = dui.destroyed + 1 end
    function SetDuiUrl(_, url) dui.navigations[#dui.navigations + 1] = url end

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

-- =========================================================================
-- PART D -- the lifecycle
-- =========================================================================
--
-- ═══ THE THINGS THAT LOOK IDENTICAL FROM INSIDE THE GAME ═══
--
-- A board that leaks a browser per match and a board that keeps one show the
-- same picture. A board that recreates its DUI to change the page and a board
-- that navigates it show the same picture. A board that quietly spawned a prop
-- nobody asked for and a board waiting for a model to stream look the same for
-- the first hundred milliseconds and then do not, in a way nobody is watching
-- for. Every one of those is a count, and counting is what this part does.

local loops = {}
local cmds  = {}

BR.Loop = {
    FRAME = 'frame', TICK = 'tick', SLOW = 'slow',
    register = function(_, name, fn) loops[name] = fn end,
}
BR.State = { me = { state = BR.PlayerState.LOBBY } }

function RegisterCommand(name, fn) cmds[name] = fn end

-- THE COUNTERS START AT ZERO HERE, not at load. Part C opened a probe page of
-- its own through the same BR.Dui, and a browser count that carried it in would
-- make every "exactly one browser" assertion below off by one -- which is a
-- fixture bug that reads as a leak.
dui.created = {}
dui.navigations = {}
dui.destroyed = 0
dui.made, dui.deleted = 0, 0

loadAll({ 'br_core/client/board.lua' })

local LIC = 'b6f5a1273092df7eb6a8c2a981418f275f2ae3fb'
local BOARD_URL = 'https://ringmaster.blitz-royale.com/scoreboard?id=' .. LIC
local STATIC_URL = 'nui://br_ui/dui/static.html'

local function tick() loops['board.track']() end
local function frame()
    dui.polys = {}
    loops['board.draw']()
    return dui.polys
end

--- How many times the browser has been sent to this address.
local function navs(url)
    local n = 0
    for _, u in ipairs(dui.navigations) do
        if u == url then n = n + 1 end
    end
    return n
end

--- Run /brboard and hand back every line it printed.
local function brboard(...)
    local lines = {}
    local realp = print
    print = function(s) lines[#lines + 1] = tostring(s) end
    cmds['brboard'](nil, { ... })
    print = realp
    return lines
end

--- Does any printed line match this Lua pattern?
local function printed(lines, pat)
    for _, l in ipairs(lines) do
        if l:match(pat) then return true end
    end
    return false
end

describe('a checkout with no prop named builds nothing whatever')
do
    -- ⚠ THE ASSERTION THAT PROTECTS THE WARMUP PAD FROM US. The owner has a prop
    -- in mind and has not said which, so the shipped config names none -- and a
    -- feature that spawned a placeholder anyway would put an object nobody asked
    -- for in front of every player in the lobby.
    BR.State.me.state = BR.PlayerState.WARMUP
    tick()
    tick()
    eq(dui.made, 0, 'no object is created')
    eq(#dui.created, 0, 'no browser is started')
    eq(#frame(), 0, 'and nothing is drawn')

    -- ═══ AND THE TWO HALVES ARE CHECKED SEPARATELY, WHICH THEY HAVE TO BE ═══
    --
    -- The shipped config is missing BOTH the model and the coordinates, so an
    -- assertion driven only from that state passes whether the gate asks about
    -- the model, the coordinates, or nothing at all. A first attempt at this
    -- suite did exactly that: deleting the model check from `sited()` broke
    -- nothing, because the coordinates were nil too and stopped it further down.
    B.prop.x, B.prop.y, B.prop.z = 500.0, 600.0, 30.0
    tick()
    tick()
    eq(dui.made, 0, 'coordinates with no model name build nothing')
    eq(#dui.created, 0, 'and start no browser')

    B.prop.x, B.prop.y, B.prop.z = nil, nil, nil
    B.prop.model = 'prop_board_probe'
    tick()
    tick()
    eq(dui.made, 0, 'and a model with nowhere to stand builds nothing either')
    eq(#dui.created, 0, 'and starts no browser')

    -- ALL THREE COORDINATES, AND THE THIRD IS CHECKED ON ITS OWN. Setting x and
    -- y together and leaving z out is the shape a half-finished config edit
    -- takes, and CREATE_OBJECT_NO_OFFSET with a nil z is an engine error rather
    -- than a board that is slightly wrong.
    B.prop.x, B.prop.y = 500.0, 600.0
    tick()
    tick()
    eq(dui.made, 0, 'x and y with no z build nothing')
    B.prop.x, B.prop.y = nil, nil

    -- OFF THE PAD IS THE THIRD GATE, and it is not the same as the other two.
    B.prop.x, B.prop.y, B.prop.z = 500.0, 600.0, 30.0
    BR.State.me.state = BR.PlayerState.LOBBY
    tick()
    tick()
    eq(dui.made, 0, 'a fully sited board is still nothing from the lobby menu')
    eq(#dui.created, 0, 'and no browser is started there')

    -- ...AND SO IS THE CONFIG SWITCH.
    BR.State.me.state = BR.PlayerState.WARMUP
    B.enabled = false
    tick()
    tick()
    eq(dui.made, 0, 'enabled = false turns the whole feature off')
    B.enabled = true

    -- Put the model back where the next block expects it.
    B.prop.model = nil
end

describe('the prop waits for its model rather than yielding for it')
do
    B.prop.model = 'prop_board_probe'
    B.prop.x, B.prop.y, B.prop.z = 500.0, 600.0, 30.0
    B.prop.heading = 90.0
    dui.ped.x, dui.ped.y, dui.ped.z = 500.0, 605.0, 30.0

    -- ═══ MODEL LOADING IS ASYNCHRONOUS AND THIS PASS CANNOT WAIT ═══
    --
    -- client/loot.lua's spawn worker says a RequestModel-then-wait loop "cannot
    -- live in a loop callback", and it is right. The cure here is a state
    -- machine rather than a thread: ask, return, and build on whichever later
    -- pass the model has actually arrived on. The failure this catches is a
    -- board that asks once, finds the model missing, and never comes back.
    dui.modelLoaded = false
    tick()
    eq(dui.made, 0, 'a model that has not streamed yields no object')
    ok(#dui.requests > 0, 'but it has been asked for')
    eq(#dui.created, 0, 'and no browser is built around a prop that is not there')

    dui.modelLoaded = true
    tick()
    eq(dui.made, 1, 'the next pass builds it, with no thread and no wait')
    eq(#dui.created, 1, 'and exactly one browser goes with it')
end

describe('with no license there is nothing true to paint, so it paints static')
do
    -- FiveM does not always report a license and server/board.lua then sends
    -- nothing. A board that built its URL anyway would ask for `?id=` and sit on
    -- an HTTP 400 page; a board that refused to exist would leave a black
    -- rectangle that reads as a bug. Static is the honest third answer, and it
    -- is the SAME answer as a Ringmaster outage because it is the same fact.
    eq(dui.created[1], STATIC_URL,
        'the first browser opens on the local static page')
    eq(#frame(), 2, 'and the quad is drawn, so the screen is visibly on')
end

describe('the license arrives and the browser is NAVIGATED, not replaced')
do
    handlers[BR.Net.BOARD_ID](LIC)
    tick()
    eq(navs(BOARD_URL), 1, 'it is sent to the board')
    eq(#dui.created, 1, 'and no second browser was started to do it')
    eq(dui.destroyed, 0, 'nor was the first one destroyed')

    -- ═══ AND THE 10Hz PASS DOES NOT RELOAD IT TEN TIMES A SECOND ═══
    --
    -- The address is re-decided every pass. Without the comparison inside
    -- BR.Dui.url this is a page load per tick, per client, from every machine in
    -- the lobby, against a route that reads DynamoDB. It would work perfectly
    -- and be invisible from in front of the prop.
    for _ = 1, 20 do tick() end
    eq(navs(BOARD_URL), 1, 'twenty more passes navigate nowhere')
end

describe('the draw is gated on range and lives on the frame band')
do
    local polys = frame()
    eq(#polys, 2, 'in range, two triangles')

    dui.ped.x, dui.ped.y = 500.0 + 400.0, 600.0
    eq(#frame(), 2,
        'moving does not change the draw until the 10Hz pass re-decides')
    tick()
    eq(#frame(), 0, 'and then the far-away board stops being drawn')

    dui.ped.x = 500.0
    tick()
    eq(#frame(), 2, 'walking back turns it on again')
end

describe('static is a SetDuiUrl away and never a new browser')
do
    local before = #dui.created
    brboard('static')
    tick()
    eq(navs(STATIC_URL), 1, 'the board goes to the static page')
    eq(#dui.created, before, 'with no browser created')
    eq(dui.destroyed, 0, 'and none destroyed')

    for _ = 1, 20 do tick() end
    eq(navs(STATIC_URL), 1, 'and it does not keep reloading it')

    -- STILL DRAWN. "Show static instead" is a different picture on the same
    -- surface, not the surface going away -- a board that stopped drawing here
    -- would be the blank quad the owner asked us not to ship.
    eq(#frame(), 2, 'the quad is still there, showing noise')

    brboard('live')
    tick()
    eq(navs(BOARD_URL), 2, 'and going live navigates back')
    eq(#dui.created, before, 'still on the same browser')
end

describe('leaving warmup takes the browser and the prop with it')
do
    -- ═══ THE ISSUE IS EXPLICIT: A DUI IS A REAL BROWSER AND LEAKING ONE PER
    --     MATCH IS NOT ACCEPTABLE ═══
    --
    -- MATCH START IS THIS EDGE AND NOT A SECOND MECHANISM. A match starting is
    -- this player's state leaving WARMUP, so the one teardown covers "left the
    -- area" and "the match began" and the two cannot come to disagree.
    local madeBefore, createdBefore = dui.made, #dui.created
    BR.State.me.state = BR.PlayerState.BUS
    tick()
    eq(dui.destroyed, 1, 'the browser is destroyed')
    eq(dui.deleted, 1, 'and the prop is deleted')
    eq(#frame(), 0, 'nothing is drawn from the bus')

    for _ = 1, 10 do tick() end
    eq(dui.destroyed, 1, 'and the teardown is not repeated every pass')

    BR.State.me.state = BR.PlayerState.WARMUP
    tick()
    eq(#dui.created, createdBefore + 1, 'coming back builds a browser')
    eq(dui.made, madeBefore + 1, 'and a prop')
    eq(dui.destroyed, 1, 'and the old one really was destroyed, not orphaned')
end

describe('/brboard moves the board and prints what it moved it to')
do
    -- ═══ HE ASKED FOR A TOOL, AND A TOOL WHOSE OUTPUT IS NOT PASTEABLE IS A
    --     SECOND ROUND OF GUESSING ═══
    --
    -- Owner, 2026-09-09: "I can help align it if you give me the tools."
    local lines = brboard('w', '4.0')
    ok(printed(lines, '^%s*widthM%s*= 4%.00,$'),
        'a new width prints as the config line it belongs on')

    local wide = frame()
    local tl, tr = nil, nil
    for _, p in ipairs(wide) do
        for i = 1, 3 do
            if p.uv[i][1] == 0.0 and p.uv[i][2] == 0.0 then tl = p.v[i] end
            if p.uv[i][1] == 1.0 and p.uv[i][2] == 0.0 then tr = p.v[i] end
        end
    end
    ok(tl and tr and near(dist3(tl, tr), 4.0, 0.001),
        'and the quad on the prop is actually four meters across now',
        tl and tr and ('%.3f'):format(dist3(tl, tr)) or 'not drawn')

    -- A DELTA, WHICH IS THE HALF THAT MAKES IT A NUDGER. `4.0` sets, `+0.5`
    -- moves; the leading sign is the entire difference and it is read off the
    -- raw string, because tonumber('+0.5') and tonumber('0.5') are equal.
    lines = brboard('w', '+0.5')
    ok(printed(lines, '^%s*widthM%s*= 4%.50,$'), 'and +0.5 nudges from there')

    lines = brboard('yaw', '-90')
    ok(printed(lines, '^%s*yawDeg%s*= %-90%.00,$'),
        'a negative delta on an untouched field reads from the config value')

    -- THE WHOLE BLOCK IS THERE, not just the field that changed. Pasting back a
    -- partial block is how a field somebody never touched gets quietly zeroed.
    lines = brboard()
    for _, key in ipairs({ 'forwardM', 'sideM', 'upM', 'widthM', 'yawDeg' }) do
        ok(printed(lines, '^%s*' .. key .. '%s*= '), key .. ' is in the block')
    end
    ok(printed(lines, "^%s*prop = { model = 'prop_board_probe', x = 500%.00"),
        'and so is the prop, in the shape config/board.lua writes it')

    -- IT SAYS WHAT THE BOARD IS DOING, which is the other half of the request:
    -- seven different faults all look like "the board is not there".
    ok(printed(lines, '^  health '), 'the health state is printed')
    ok(printed(lines, 'texture 1280x720'), 'so is the resolution')
    ok(printed(lines, '^  url    ' .. BOARD_URL:gsub('%p', '%%%0')),
        'and the address actually in force')
    ok(printed(lines, '^  warmup true'), 'and whether we are on the pad')
end

describe('/brboard prop and here place it without a config edit')
do
    local madeBefore, deletedBefore = dui.made, dui.deleted

    brboard('prop', 'prop_board_other')
    eq(dui.deleted, deletedBefore + 1, 'auditioning a model drops the old prop')
    tick()
    eq(dui.made, madeBefore + 1, 'and stands the new one up')

    dui.ped.x, dui.ped.y, dui.ped.z = 511.0, 622.0, 33.0
    dui.ped.h = 250.0
    local lines = brboard('here')
    ok(printed(lines, "model = 'prop_board_other', x = 511%.00, y = 622%.00, "
        .. 'z = 33%.00, heading = 250%.0'),
        'and `here` surveys the spot he is standing on, heading included')

    -- AND THE OBJECT REALLY MOVES THERE, rather than the numbers moving and the
    -- prop staying put -- which would be a readout that agrees with itself and
    -- with nothing on screen.
    tick()
    local moved = nil
    for h, o in pairs(dui.objects) do
        if near(o.x, 511.0, 0.01) and near(o.y, 622.0, 0.01) then moved = h end
    end
    ok(moved ~= nil, 'the prop is standing where he stood')

    -- RESET PUTS EVERYTHING BACK, INCLUDING THE PROP. A reset that restored the
    -- numbers and left an object standing at the overridden site would make the
    -- readout lie about where the board is.
    deletedBefore = dui.deleted
    lines = brboard('reset')
    eq(dui.deleted, deletedBefore + 1, 'reset drops the prop it was auditioning')
    ok(printed(lines, "model = 'prop_board_probe'"),
        'and the model goes back to the config')
    ok(printed(lines, '^%s*widthM%s*= 2%.40,$'),
        'and so do the five numbers')
end

describe('the resource stopping does not leave a browser behind')
do
    local before = dui.destroyed
    handlers['onResourceStop']('br_core')
    eq(dui.destroyed, before + 1, 'the browser is destroyed on the way out')
    eq(#frame(), 0, 'and nothing is drawn after it')
end

-- ---------------------------------------------------------------- report ---

realPrint(('\n%s  board: %d passed, %d failed')
    :format(fail == 0 and '\27[32mPASS\27[0m' or '\27[31mFAIL\27[0m', pass, fail))
realExit(fail == 0 and 0 or 1)
