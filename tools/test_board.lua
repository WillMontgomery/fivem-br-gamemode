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

describe('the shipped heading is the owner\'s quaternion, converted')
do
    -- ═══════════════════════════════════════════════════════════════════════
    -- FOUR NUMBERS BECAME ONE, AND THIS IS THE ARITHMETIC THAT DID IT
    -- ═══════════════════════════════════════════════════════════════════════
    --
    -- Owner, 2026-09-11: "Rotation is: 0, 0, -0.9238796, -0.3826834"
    --
    -- THE CONFIG FIELD IS A HEADING AND HE GAVE A QUATERNION. Any one of the
    -- four pasted straight in would have been a number in a number-shaped hole,
    -- and the board would have faced somewhere arbitrary with nothing anywhere
    -- saying why.
    --
    -- ⚠ SO THIS DOES THE CONVERSION HERE, FROM HIS RAW FOUR, AND COMPARES. An
    -- assertion that only read `B.prop.heading == 135.0` would agree with any
    -- edit to the config -- it would prove a field exists and nothing else. This
    -- one fails if the shipped number stops being the correct conversion of the
    -- quaternion he actually sent, which is the claim worth pinning.
    local QX, QY, QZ, QW = 0.0, 0.0, -0.9238796, -0.3826834

    -- IT IS A UNIT QUATERNION, which is how we know all four components are
    -- present and none of them is a scale factor or a stray field.
    ok(near(math.sqrt(QX * QX + QY * QY + QZ * QZ + QW * QW), 1.0, 0.0001),
        'the four components are a unit quaternion',
        ('%.7f'):format(math.sqrt(QX * QX + QY * QY + QZ * QZ + QW * QW)))

    --- Yaw, pitch and roll in degrees, from a quaternion read as (x, y, z, w).
    local function euler(x, y, z, w)
        local yaw = math.atan(2 * (w * z + x * y), 1 - 2 * (y * y + z * z))
        local sp = 2 * (w * y - z * x)
        if sp > 1.0 then sp = 1.0 elseif sp < -1.0 then sp = -1.0 end
        local deg = 180.0 / math.pi
        return yaw * deg, math.asin(sp) * deg,
               math.atan(2 * (w * x + y * z), 1 - 2 * (x * x + y * y)) * deg
    end

    -- ═══ THE COMPONENT ORDER IS (x, y, z, w), AND THE NUMBERS PROVE IT ═══
    --
    -- Read that way the rotation is a PURE YAW: pitch and roll are exactly zero,
    -- which is what a display standing upright on flat ground is.
    local yaw, pitch, roll = euler(QX, QY, QZ, QW)
    ok(near(pitch, 0.0, 0.0001), 'read as (x,y,z,w) there is no pitch',
        ('%.6f'):format(pitch))
    ok(near(roll, 0.0, 0.0001), 'and no roll -- it is a rotation about the '
        .. 'world\'s up and nothing else', ('%.6f'):format(roll))

    -- ...AND THE OTHER READING IS ABSURD, which is the half that makes the
    -- sentence above a deduction rather than a preference. The same four numbers
    -- taken as (w, x, y, z) describe a screen lying over on its corner.
    local _, _, wrongRoll = euler(QY, QZ, QW, QX)
    ok(math.abs(wrongRoll) > 1.0,
        'while (w,x,y,z) would put a 135 degree ROLL on it, which is a screen '
            .. 'on its side and not what he placed', ('%.6f'):format(wrongRoll))

    -- ═══ AND THE ANSWER IS THE ONE IN THE CONFIG ═══
    --
    -- Normalized into [0, 360) because the formula answers in (-180, 180] and
    -- the config carries the positive spelling.
    local want = yaw % 360.0
    ok(near(want, 135.0, 0.001), 'the conversion lands on 135 degrees',
        ('%.6f'):format(want))
    ok(near(B.prop.heading % 360.0, want, 0.001),
        'and that is what br_lib/config/board.lua ships',
        ('config %s, converted %.6f'):format(tostring(B.prop.heading), want))

    -- IT IS AN EXACT MULTIPLE OF 22.5, which is the tell that the component
    -- order is right: 0.9238796 is cos(22.5) and 0.3826834 is sin(22.5), so a
    -- ragged answer would have meant reading the four in the wrong order.
    ok(near(want % 22.5, 0.0, 0.001),
        'and it is an exact multiple of 22.5, as those two cosines promise',
        ('%.6f'):format(want % 22.5))

    -- ═══ THE INVERSE READING IS NAMED, NOT SILENTLY EXCLUDED ═══
    --
    -- ymaps frequently store the conjugate of an entity's rotation. The config
    -- says why the direct reading was chosen anyway -- the prop is FOUND, so its
    -- real orientation comes from the ymap through the entity and this number
    -- steers no geometry -- and this pins the alternative so that "225" turning
    -- up in the config later is a deliberate edit rather than a typo.
    local inv = euler(-QX, -QY, -QZ, QW) % 360.0
    ok(near(inv, 225.0, 0.001),
        'the ymap-inverse reading would have been 225, and is not what ships',
        ('%.6f'):format(inv))
end

describe('the prop is sited, and sited on the owner\'s own numbers')
do
    -- ⚠ THE ASSERTION THAT USED TO SAY THE OPPOSITE. It read `eq(B.prop.model,
    -- nil)` and its comment called itself "the one assertion in this file that
    -- is meant to be deleted", because the owner had a prop in mind and had not
    -- named it. He has now named it, so the rule it protected -- do not guess a
    -- model -- is satisfied by his own words rather than by emptiness.
    eq(B.prop.model, 'prop_huge_display_02', 'his model ships')

    -- HIS COORDINATES, UNROUNDED. This project does not lower, ground-probe or
    -- tidy a surveyed number, and a `%.2f` somewhere in the pipeline that
    -- quietly trimmed one would pass any assertion written to two places.
    ok(near(B.prop.x, 4539.29443, 1e-5), 'x is his, to the digit',
        tostring(B.prop.x))
    ok(near(B.prop.y, -4498.826, 1e-5), 'y is his, to the digit',
        tostring(B.prop.y))
    ok(near(B.prop.z, 7.20210361, 1e-5), 'z is his, to the digit',
        tostring(B.prop.z))

    -- THE SEARCH RADIUS IS A REAL NUMBER, because a nil one would make every
    -- search in client/board.lua fall back to a default nobody chose.
    ok(type(B.prop.radiusM) == 'number' and B.prop.radiusM > 0.0,
        'and there is a radius to look within', tostring(B.prop.radiusM))

    -- ═══ THREE OF THE FIVE ARE nil ON PURPOSE ═══
    --
    -- forwardM, upM and widthM are measured off the prop. The previous draft's
    -- 0.06 / 1.20 / 2.40 were invented against no prop at all and are known
    -- wrong against a stage display; a number here again would silently beat the
    -- measurement, which is exactly what the resolver is built to let it do.
    eq(B.forwardM, nil, 'forwardM is left to the prop to answer')
    eq(B.upM, nil, 'and so is upM')
    eq(B.widthM, nil, 'and so is widthM')

    -- ...WHILE THE OTHER TWO ARE NOT, and 0.0 is a real instruction rather than
    -- an absent one. A bounding box has no opinion about either.
    eq(B.sideM, 0.0, 'sideM is centred, which is a decision and not a nil')
    eq(B.yawDeg, 0.0, 'and yawDeg is the prop\'s own facing')

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

    --- Per-model boxes, so the board's fitted numbers are a MEASUREMENT of a
    --- specific model rather than whatever one box every model shares.
    ---
    --- The default is drawFace's old fixture, kept byte for byte so Part C and
    --- tools/test_shop.lua keep reading the shape they were written against.
    dui.boxes = {}
    function GetModelDimensions(model)
        local b = dui.boxes[model]
        if b then
            return { x = b[1], y = b[2], z = b[3] },
                   { x = b[4], y = b[5], z = b[6] }
        end
        return { x = -1.0, y = -0.2, z = 0.0 }, { x = 1.0, y = 0.2, z = 2.0 }
    end

    -- ═══ A CLOCK, BECAUSE THE SEARCH IS THROTTLED AND A THROTTLE IS A CLAIM
    --     ABOUT TIME ═══
    --
    -- GET_CLOSEST_OBJECT_OF_TYPE costs 2-4ms and client/fuel.lua's post-mortem is
    -- that an uncached MISS is what turns that into a collapse. Asserting the
    -- board does not repeat it every pass needs a tick that does not advance
    -- unless the test advances it.
    dui.now = 100000
    function GetGameTimer() return dui.now end

    -- ═══════════════════════════════════════════════════════════════════════
    -- THE WORLD ALREADY HAS A DISPLAY IN IT
    -- ═══════════════════════════════════════════════════════════════════════
    --
    -- Owner, 2026-09-11: "The prop is prop_huge_display_02, already in a ymap and
    -- streamed and verified working in-game."
    --
    -- `place` is a ymap. It puts an object into the same table CreateObjectNoOffset
    -- writes to -- so it is readable through every native above and is
    -- indistinguishable from a spawned one from inside the code under test -- but
    -- it deliberately does NOT touch `dui.made`. That separation is the whole
    -- fixture: `made` now counts only objects br_core conjured, so "we found the
    -- one that was there" and "we built a second one on top of it" stop being the
    -- same picture and become two different numbers.
    dui.place = function(model, x, y, z, heading)
        dui.nextObj = dui.nextObj + 1
        dui.objects[dui.nextObj] = { model = model, x = x, y = y, z = z,
                                     heading = heading or 0.0 }
        return dui.nextObj
    end

    --- Every GetClosestObjectOfType call, with the arguments it was made with.
    dui.searches = {}

    --- ═══ THE FIRST SPELLING OF `isMission` ANSWERS NOTHING ═══
    ---
    --- citizenfx/natives documents the flag as "if true doesn't return mission
    --- objects", which is backwards from how the name reads, and p6/p7 are
    --- undocumented everywhere. client/warmupcrates.lua asks both spellings for
    --- that reason and client/board.lua now does too.
    ---
    --- SO THIS STUB MAKES THAT LOAD-BEARING RATHER THAN DECORATIVE. It answers
    --- only for `isMission == true`, so a search that asked one spelling and
    --- guessed finds nothing at all -- and every downstream assertion in Part D
    --- fails rather than passing on a coin flip that happened to land right.
    ---
    --- ═══ AND `sloppyRadius` IS A NATIVE THAT DOES NOT KEEP ITS PROMISE ═══
    ---
    --- client/board.lua re-checks the distance of a hit AFTER passing the native
    --- a radius, which reads as belt and braces right up until you ask what would
    --- catch it if the braces were cut. A fixture that always honours the radius
    --- argument cannot: the re-check would be dead code that every test agreed
    --- with. This flag makes the stub answer with the nearest match at ANY
    --- distance, which is the behaviour the re-check exists for, and is not an
    --- invented worry -- this project has been wrong about what a native promises
    --- before, which is why client/probe.lua exists.
    dui.sloppyRadius = false

    function GetClosestObjectOfType(x, y, z, radius, hash, mission, p6, p7)
        dui.searches[#dui.searches + 1] = {
            x = x, y = y, z = z, radius = radius, hash = hash,
            mission = mission, p6 = p6, p7 = p7,
        }
        if mission ~= true then return 0 end

        local best, bestD = 0, math.huge
        for h, o in pairs(dui.objects) do
            if o.model == hash then
                local dx, dy, dz = o.x - x, o.y - y, o.z - z
                local d = math.sqrt(dx * dx + dy * dy + dz * dz)
                if (dui.sloppyRadius or d <= radius) and d < bestD then
                    best, bestD = h, d
                end
            end
        end
        return best
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

--- One pass of the 10 Hz band, AND A TENTH OF A SECOND OF GAME TIME WITH IT.
---
--- The clock has to move or the throttle on the object search can never expire,
--- and a fixture whose clock stood still would make "it retries" untestable and
--- "it does not retry every pass" trivially true. 100ms is what BR.Loop.TICK
--- actually is.
local function tick()
    dui.now = dui.now + 100
    loops['board.track']()
end

local function frame()
    dui.polys = {}
    loops['board.draw']()
    return dui.polys
end

--- The model hash for a name, through the same stub the code under test uses.
local function hashOf(name) return GetHashKey(name) end

--- Put the owner's display into the world, exactly where the shipped config
--- says it is and facing the way the shipped heading claims.
---
--- ═══ THE SHIPPED NUMBERS, NOT A FIXTURE'S OWN ═══
---
--- Part D used to invent 'prop_board_probe' at (500, 600, 30). Driving it from
--- br_lib/config/board.lua instead means the search radius, the coordinates and
--- the model name are all under test together: a config whose radiusM was too
--- small for its own coordinates, or a model name with a typo in it, now fails
--- here rather than in the warmup area.
local function placeTheDisplay(dx, dy, dz)
    return dui.place(hashOf(B.prop.model),
                     B.prop.x + (dx or 0.0),
                     B.prop.y + (dy or 0.0),
                     B.prop.z + (dz or 0.0),
                     B.prop.heading)
end

--- Stand the player next to the site.
local function standAtSite()
    dui.ped.x, dui.ped.y, dui.ped.z = B.prop.x + 3.0, B.prop.y, B.prop.z
end

--- How many object searches have happened.
local function searchCount() return #dui.searches end

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

-- ═══ THE DISPLAY'S REAL SIZE, PINNED HERE AND NOWHERE ELSE IN THIS FILE ═══
--
-- config/board.lua ships forwardM, upM and widthM as nil because no dimensions
-- for prop_huge_display_02 are published anywhere, and client/board.lua measures
-- them off GET_MODEL_DIMENSIONS instead. So this fixture is the only thing in
-- the suite that knows how big the prop is, and every fitted number asserted
-- below is derived from these six: nine metres across, six tall, standing on the
-- ground, with its front face 0.30 out along its local +Y.
--
-- SET BEFORE THE FIRST TICK, because client/board.lua caches a model's box by
-- hash the first time it is asked and a default measured early would stick.
dui.boxes[hashOf(B.prop.model)] = { -4.5, -0.30, 0.0, 4.5, 0.30, 6.0 }

--- Take the board down the way leaving warmup does, and empty the world of
--- displays, so the next block starts from nothing.
---
--- THE BROWSER COUNTERS ARE NOT RESET AND THAT IS DELIBERATE. `created` and
--- `destroyed` are cumulative for the whole of Part D, so a browser leaked in
--- one block shows up in the next one rather than being tidied away between
--- them. Blocks below take deltas.
local function teardownWorld()
    BR.State.me.state = BR.PlayerState.LOBBY
    tick()
    for h, o in pairs(dui.objects) do
        if o.model == hashOf(B.prop.model)
            or o.model == hashOf('prop_huge_display_01') then
            dui.objects[h] = nil
        end
    end
end

describe('the prop is FOUND, and nothing is ever built or unbuilt')
do
    -- ═══════════════════════════════════════════════════════════════════════
    -- ⚠ THE TWO ASSERTIONS THIS WHOLE PART EXISTS FOR
    -- ═══════════════════════════════════════════════════════════════════════
    --
    -- Owner, 2026-09-11: "The prop is prop_huge_display_02, already in a ymap and
    -- streamed and verified working in-game."
    --
    -- A board that spawns its own copy and a board that adopts the one already
    -- standing there SHOW THE SAME PICTURE. From in front of the prop the only
    -- difference is a faint shimmer where two coincident meshes z-fight, which is
    -- exactly the kind of thing somebody decides is a graphics setting.
    --
    -- AND A BOARD THAT DELETES THE PROP ON THE WAY OUT IS WORSE, because it works
    -- perfectly the first time. The symptom arrives one match later as a hole in
    -- the owner's map that lasts until he reconnects, caused by a teardown that
    -- ran when the match started.
    --
    -- Both are counts, and counting is the only way to tell them apart from
    -- outside. `dui.place` deliberately does not touch `made`, so these two
    -- numbers mean exactly "objects br_core conjured" and "objects br_core
    -- destroyed" -- and they must be zero here and everywhere below.
    BR.State.me.state = BR.PlayerState.WARMUP
    standAtSite()
    local display = placeTheDisplay()

    tick()
    eq(dui.made, 0, 'no object is created -- the display was already there')
    eq(dui.deleted, 0, 'and none is destroyed')
    eq(#dui.created, 1, 'a browser is started, because the prop was found')

    -- ═══ AND IT IS THE PRE-PLACED ENTITY, BY HANDLE ═══
    --
    -- "made == 0" alone would also be true of a board that found nothing and
    -- quietly drew on nothing. The quad has to be standing on the ymap's own
    -- object, and its position is the only thing that says so.
    local polys = frame()
    eq(#polys, 2, 'and the quad is drawn')
    local c = GetEntityCoords(display)
    local onIt = false
    for _, p in ipairs(polys) do
        for i = 1, 3 do
            if math.abs(p.v[i][1] - c.x) < 20.0
                and math.abs(p.v[i][2] - c.y) < 20.0 then onIt = true end
        end
    end
    ok(onIt, 'on the entity the ymap placed, not somewhere else')

    -- ═══ THE SEARCH ASKED BOTH SPELLINGS OF `isMission` ═══
    --
    -- citizenfx/natives documents it as "if true doesn't return mission objects",
    -- which is backwards from how the name reads, and p6/p7 are undocumented
    -- everywhere. The fixture answers only for `true`, so a search that asked one
    -- spelling and guessed would have found nothing and failed everything above
    -- -- but this pins the rule directly, so the reason is legible when it does.
    local sawFalse, sawTrue = false, false
    for _, s in ipairs(dui.searches) do
        if s.mission == false then sawFalse = true end
        if s.mission == true then sawTrue = true end
    end
    ok(sawFalse and sawTrue, 'both spellings of isMission were tried')

    -- ...AND IT ASKED AT THE CONFIGURED SITE, WITH THE CONFIGURED RADIUS. A
    -- search centred on the player would find the board from wherever he happened
    -- to be standing and never from where it actually is.
    local s1 = dui.searches[1]
    ok(near(s1.x, B.prop.x, 1e-3) and near(s1.y, B.prop.y, 1e-3)
        and near(s1.z, B.prop.z, 1e-3),
        'the search is centred on the configured site')
    ok(near(s1.radius, B.prop.radiusM, 1e-4),
        'with the configured radius', tostring(s1.radius))
    eq(s1.hash, hashOf(B.prop.model), 'and asks for the configured model')

    -- p6 AND p7 ARE FALSE. Undocumented everywhere, and every working call in
    -- this repository passes false for both; a stray `true` changes what the pool
    -- walk returns with nothing anywhere saying why.
    eq(s1.p6, false, 'p6 is false, as every other call in this repo passes it')
    eq(s1.p7, false, 'and so is p7')
end

describe('a prop outside the radius is a different prop')
do
    -- THE RADIUS IS THE ONLY THING STOPPING THIS ADOPTING A DISPLAY SOMEWHERE
    -- ELSE ON THE ISLAND. GET_CLOSEST_OBJECT_OF_TYPE answers with the nearest
    -- match it can find, and a board drawn on a screen half a kilometre away is
    -- "the board does not work" from the warmup area.
    teardownWorld()
    BR.State.me.state = BR.PlayerState.WARMUP
    standAtSite()

    placeTheDisplay(B.prop.radiusM + 5.0, 0.0, 0.0)
    for _ = 1, 30 do tick() end
    eq(#frame(), 0, 'a display beyond radiusM is not adopted')
    eq(dui.made, 0, 'and nothing is conjured to replace it')

    -- ═══ AND THE DISTANCE IS CHECKED AGAIN AFTER THE NATIVE HAS CHECKED IT ═══
    --
    -- ⚠ THE ASSERTION ABOVE PASSES WITHOUT client/board.lua DOING ANYTHING, and
    -- that was worth finding out: the fixture honours the radius argument, so a
    -- findProp with its own distance test deleted still refuses a far display --
    -- the native had already refused it. The re-check would be dead code every
    -- test agreed with.
    --
    -- SO THIS ASKS THE QUESTION THE RE-CHECK IS ACTUALLY FOR: a native that does
    -- not keep its promise. p6 and p7 are undocumented, `isMission` is documented
    -- backwards, and this project has been wrong about what a native does before
    -- -- which is the whole reason client/probe.lua exists.
    dui.sloppyRadius = true
    for _ = 1, 30 do tick() end
    eq(#frame(), 0,
        'and a native that ignores its own radius does not get the board '
            .. 'drawn on a display sixty metres away')
    dui.sloppyRadius = false

    -- ...WHILE ONE INSIDE IT IS, so the assertions above are about the radius and
    -- not about the search being broken.
    placeTheDisplay(1.0, 0.0, 0.0)
    for _ = 1, 30 do tick() end
    eq(#frame(), 2, 'and one inside it is')
end

describe('a prop that has not streamed in is waited for, not hammered')
do
    -- ═══ client/fuel.lua ALREADY PAID FOR THIS LESSON IN FRAME TIME ═══
    --
    -- "Major client performance hits when at gas stations - what can we do about
    -- that?"  -- owner, 2026-08-23. The post-mortem in fuel.lua's resolvePump is
    -- that the cost of GET_CLOSEST_OBJECT_OF_TYPE (2-4ms, no spatial index, it
    -- walks the object pool) was not the fault. The fault was that A MISS WAS
    -- NEVER CACHED, so the sweep ran again on the very next pass and kept running
    -- for as long as the player stood there.
    --
    -- THIS IS THE SAME SHAPE. The board's site is in the warmup area, the player
    -- stands in the warmup area, and a prop that has not streamed yet is a miss
    -- that lasts seconds. Unthrottled at 10 Hz that is up to 80ms of pool walking
    -- per second, on every machine in the lobby at once.
    teardownWorld()
    BR.State.me.state = BR.PlayerState.WARMUP
    standAtSite()

    local createdBefore = #dui.created
    local before = searchCount()
    tick()
    ok(searchCount() > before, 'with nothing there, it looks')
    eq(#dui.created, createdBefore,
        'and starts no browser around a prop that is not there')
    eq(#frame(), 0, 'and draws nothing')

    -- ...AND THEN IT STOPS LOOKING FOR A WHILE. Ten more passes is a whole second
    -- of game time and must not be ten more pool walks.
    local afterFirst = searchCount()
    for _ = 1, 10 do tick() end
    eq(searchCount(), afterFirst,
        'ten more passes inside the retry window look again zero times')

    -- ...BUT IT DOES COME BACK. A miss cached forever is the opposite bug and
    -- looks identical from a chair: the board simply never appears.
    for _ = 1, 15 do tick() end
    ok(searchCount() > afterFirst, 'and once the window is up it looks again')

    -- AND WHEN THE PROP FINALLY STREAMS IN, IT IS ADOPTED. No thread, no
    -- Citizen.Wait inside a band callback; whichever pass is next finds it.
    placeTheDisplay()
    for _ = 1, 25 do tick() end
    eq(dui.made, 0, 'still nothing was created')
    eq(#dui.created, createdBefore + 1,
        'and exactly one browser goes up once it is there')
    eq(#frame(), 2, 'and the board is finally drawn')
end

describe('with no license there is nothing true to paint, so it paints static')
do
    -- FiveM does not always report a license and server/board.lua then sends
    -- nothing. A board that built its URL anyway would ask for `?id=` and sit on
    -- an HTTP 400 page; a board that refused to exist would leave a black
    -- rectangle that reads as a bug. Static is the honest third answer, and it is
    -- the SAME answer as a Ringmaster outage because it is the same fact.
    eq(dui.created[1], STATIC_URL,
        'the first browser opens on the local static page')
    eq(#frame(), 2, 'and the quad is drawn, so the screen is visibly on')
end

describe('the board is sized and placed by measuring the prop')
do
    -- ═══════════════════════════════════════════════════════════════════════
    -- WE DO NOT KNOW HOW BIG prop_huge_display_02 IS, AND THE ENGINE DOES
    -- ═══════════════════════════════════════════════════════════════════════
    --
    -- The previous draft shipped forwardM 0.06, upM 1.20 and widthM 2.40,
    -- invented against no prop at all. On a stage display a 2.4m board is a
    -- postage stamp somewhere in the middle of a wall. Every number below is
    -- derived from the fixture's box and nothing else.
    local lines = brboard()

    -- THE WIDTH IS THE MODEL'S WIDTH: 4.5 - (-4.5) = 9.00.
    ok(printed(lines, '^%s*widthM%s*= 9%.00,$'),
        'widthM comes off the model box and not out of the air')

    -- THE STAND-OFF IS THE FRONT FACE PLUS CLEARANCE: 0.30 + 0.02 = 0.32. A quad
    -- at the origin's own depth would be inside the mesh, z-fighting with it.
    ok(printed(lines, '^%s*forwardM%s*= 0%.32,$'),
        'forwardM clears the front face of the box')

    -- AND THE HEIGHT IS THE BOX'S CENTRE: (0.0 + 6.0) / 2 = 3.00. A board at the
    -- prop's own origin would be down at its feet.
    ok(printed(lines, '^%s*upM%s*= 3%.00,$'),
        'upM is the vertical centre of the box')

    -- ...AND THE QUAD REALLY IS NINE METRES ACROSS, which is what separates a
    -- readout agreeing with itself from a board that changed size.
    local polys = frame()
    local tl, tr = nil, nil
    for _, p in ipairs(polys) do
        for i = 1, 3 do
            if p.uv[i][1] == 0.0 and p.uv[i][2] == 0.0 then tl = p.v[i] end
            if p.uv[i][1] == 1.0 and p.uv[i][2] == 0.0 then tr = p.v[i] end
        end
    end
    ok(tl and tr and near(dist3(tl, tr), 9.0, 0.001),
        'and the quad on the prop is actually nine meters across',
        tl and tr and ('%.3f'):format(dist3(tl, tr)) or 'not drawn')

    -- ═══ AND A NUMBER IN THE CONFIG STILL BEATS THE TAPE MEASURE ═══
    --
    -- Pasting /brboard's block back into config/board.lua is how a measurement
    -- becomes a decision, and a config that could be silently overruled by a
    -- model change would not be a config.
    B.widthM = 5.0
    ok(printed(brboard(), '^%s*widthM%s*= 5%.00,$'),
        'a configured widthM wins over the measurement')
    B.widthM = nil
    ok(printed(brboard(), '^%s*widthM%s*= 9%.00,$'),
        'and taking it away hands the question back to the prop')

    -- THE SOURCE OF EACH NUMBER IS PRINTED, because `widthM = 9.00` in the paste
    -- block and `widthM = nil` in the file otherwise read as a contradiction.
    ok(printed(brboard(), '^  source fwd measured  up measured  w measured'),
        'and the readout says where the three came from')
end

describe('the license arrives and the browser is NAVIGATED, not replaced')
do
    local createdBefore = #dui.created
    handlers[BR.Net.BOARD_ID](LIC)
    tick()
    eq(navs(BOARD_URL), 1, 'it is sent to the board')
    eq(#dui.created, createdBefore, 'and no second browser was started to do it')
    eq(dui.destroyed, 2, 'and only the two torn down between blocks are gone')

    -- ═══ AND THE 10Hz PASS DOES NOT RELOAD IT TEN TIMES A SECOND ═══
    --
    -- The address is re-decided every pass. Without the comparison inside
    -- BR.Dui.url this is a page load per tick, per client, from every machine in
    -- the lobby, against a route that reads DynamoDB. It would work perfectly and
    -- be invisible from in front of the prop.
    for _ = 1, 20 do tick() end
    eq(navs(BOARD_URL), 1, 'twenty more passes navigate nowhere')
end

describe('the draw is gated on range and lives on the frame band')
do
    local polys = frame()
    eq(#polys, 2, 'in range, two triangles')

    dui.ped.x = B.prop.x + 400.0
    eq(#frame(), 2,
        'moving does not change the draw until the 10Hz pass re-decides')
    tick()
    eq(#frame(), 0, 'and then the far-away board stops being drawn')

    standAtSite()
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

describe('leaving warmup takes the browser, AND LEAVES THE PROP ALONE')
do
    -- ═══ THE ISSUE IS EXPLICIT: A DUI IS A REAL BROWSER AND LEAKING ONE PER
    --     MATCH IS NOT ACCEPTABLE ═══
    --
    -- MATCH START IS THIS EDGE AND NOT A SECOND MECHANISM. A match starting is
    -- this player's state leaving WARMUP, so the one teardown covers "left the
    -- area" and "the match began" and the two cannot come to disagree.
    --
    -- ⚠ AND THIS BLOCK USED TO ASSERT THE EXACT OPPOSITE OF ITS SECOND LINE. It
    -- read `eq(dui.deleted, 1, 'and the prop is deleted')`, which was right for a
    -- prop we had spawned and is now the single most damaging thing this file
    -- could let through: DeleteEntity on a ymap entity takes a piece of the
    -- owner's map away for the rest of that client's session, and this is the
    -- edge that would fire it -- on every match start, for every player.
    local createdBefore, destroyedBefore = #dui.created, dui.destroyed
    BR.State.me.state = BR.PlayerState.BUS
    tick()
    eq(dui.destroyed, destroyedBefore + 1, 'the browser is destroyed')
    eq(dui.deleted, 0, 'and the display is NOT deleted, because it is not ours')
    eq(#frame(), 0, 'nothing is drawn from the bus')

    -- ...AND IT IS STILL STANDING THERE. "deleted == 0" counts calls; this reads
    -- the world, so a teardown that removed the entity by some other route than
    -- DeleteEntity would still be caught.
    local still = nil
    for h, o in pairs(dui.objects) do
        if o.model == hashOf(B.prop.model) then still = h end
    end
    ok(still ~= nil, 'and the display is still standing in the world')

    for _ = 1, 10 do tick() end
    eq(dui.destroyed, destroyedBefore + 1,
        'and the teardown is not repeated every pass')

    BR.State.me.state = BR.PlayerState.WARMUP
    tick()
    eq(#dui.created, createdBefore + 1, 'coming back builds a browser')
    eq(dui.made, 0, 'and still conjures no prop')
    eq(#frame(), 2, 'and finds the same display again')
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
    -- moves; the leading sign is the entire difference and it is read off the raw
    -- string, because tonumber('+0.5') and tonumber('0.5') are equal.
    lines = brboard('w', '+0.5')
    ok(printed(lines, '^%s*widthM%s*= 4%.50,$'), 'and +0.5 nudges from there')

    lines = brboard('yaw', '-90')
    ok(printed(lines, '^%s*yawDeg%s*= %-90%.00,$'),
        'a negative delta on an untouched field reads from the config value')

    -- A DELTA ON A MEASURED FIELD NUDGES FROM THE MEASUREMENT, which is the one
    -- new way this could have gone wrong: `+0.10` on a forwardM the config does
    -- not carry has to start from 0.32 and not from zero.
    lines = brboard('fwd', '+0.10')
    ok(printed(lines, '^%s*forwardM%s*= 0%.42,$'),
        'and a delta on a MEASURED field nudges from the measurement')

    -- THE WHOLE BLOCK IS THERE, not just the field that changed. Pasting back a
    -- partial block is how a field somebody never touched gets quietly zeroed.
    lines = brboard()
    for _, key in ipairs({ 'forwardM', 'sideM', 'upM', 'widthM', 'yawDeg' }) do
        ok(printed(lines, '^%s*' .. key .. '%s*= '), key .. ' is in the block')
    end

    -- ...AND SO IS THE PROP, IN THE SHAPE config/board.lua ACTUALLY WRITES IT --
    -- spread over lines, with five decimals on the coordinates and the search
    -- radius included. Two decimals here would quietly trim the owner's own
    -- surveyed numbers in the one place they get written down.
    ok(printed(lines, "^%s*model%s*= 'prop_huge_display_02',$"),
        'the model is in the block')
    ok(printed(lines, '^%s*x%s*= 4539%.29443,$'),
        'and x, to five decimals rather than rounded to a centimetre')
    ok(printed(lines, '^%s*radiusM%s*= 8%.00,$'), 'and the search radius')
    ok(printed(lines, '^%s*heading%s*= 135%.00,$'), 'and the heading')

    -- IT SAYS WHAT THE BOARD IS DOING, which is the other half of the request:
    -- seven different faults all look like "the board is not there".
    ok(printed(lines, '^  health '), 'the health state is printed')
    ok(printed(lines, 'texture 1280x720'), 'so is the resolution')
    ok(printed(lines, '^  url    ' .. BOARD_URL:gsub('%p', '%%%0')),
        'and the address actually in force')
    ok(printed(lines, '^  warmup true'), 'and whether we are on the pad')

    -- AND IT SAYS THE PROP WAS FOUND RATHER THAN BUILT, plus what it measured --
    -- the two facts that changed when the prop stopped being ours.
    ok(printed(lines, '^  prop   prop_huge_display_02   handle %d+   FOUND at '),
        'the readout says FOUND, with the handle')
    ok(printed(lines, '^  model  9%.00 wide  6%.00 tall  0%.60 deep'),
        'and prints the box it measured, so the fitted numbers can be checked')

    brboard('reset')
end

describe('/brboard fit and adopt turn the unknowns into written-down numbers')
do
    -- Owner, 2026-09-11: "If you can't get the DUI right that's totally fine.
    -- Just give me tools like `brscoreboard` or something to adjust them."

    -- ═══ fit PINS THE MEASUREMENT ═══
    --
    -- It changes nothing on screen -- the three numbers were already measured --
    -- and that is the point: it moves them from "measured" to "nudged" so the
    -- block carries three real numbers to nudge from rather than three nils to
    -- wonder about.
    --
    -- THE PASS FIRST, BECAUSE `fit` NEEDS A PROP IN HAND. The block above ended
    -- on a `reset`, which lets go of the display; the measurement comes off the
    -- entity, so there has to be one.
    tick()
    local lines = brboard('fit')
    ok(printed(lines, '^  source fwd nudged  up nudged  w nudged'),
        'fit pins the measured three')
    ok(printed(lines, '^%s*widthM%s*= 9%.00,$'),
        'and the block still reads nine metres, because fit is not a change')

    -- ═══ adopt READS THE PROP'S REAL POSE ═══
    --
    -- ⚠ THIS IS WHAT SETTLES THE QUATERNION. config/board.lua converted the
    -- owner's four components to 135 degrees and records that ymaps frequently
    -- store the INVERSE of a rotation, which would have made it 225. Both were
    -- defensible from the four numbers alone. This reads the answer off the
    -- entity the ymap actually produced.
    brboard('reset')
    tick()

    -- Move the real entity off the configured pose, so `adopt` has something to
    -- correct and cannot pass by copying a value that already matched.
    local h = nil
    for handle, o in pairs(dui.objects) do
        if o.model == hashOf(B.prop.model) then h = handle end
    end
    -- ⚠ GUARDED, AND THE GUARD IS NOT DECORATION. If a regression ever deletes
    -- the display -- the one fault this whole part is built to catch -- `h` is
    -- nil here, and an unguarded index would blow the suite up with a stack
    -- trace at this line instead of letting the assertions that NAME the rule
    -- report it. Part C's GetHashKey stub carries the same note for the same
    -- reason: a crash is a much worse diagnosis than a FAIL line.
    ok(h ~= nil, 'the display is in the world')
    if h then
        dui.objects[h].x = B.prop.x + 0.37
        dui.objects[h].heading = 225.0
    end

    -- ═══ AND THE READOUT SHOWS THE DISAGREEMENT BEFORE HE ACTS ON IT ═══
    --
    -- 225 against a configured 135 is ninety degrees out, and the whole point of
    -- printing the difference is that it is legible from a chair without
    -- measuring anything. This is the line that would tell the owner the ymap had
    -- stored the inverse after all.
    ok(printed(brboard(), '^  facing 225%.00   config says 135%.00   off by 90%.00$'),
        'the readout prints the real heading, the configured one and the gap')

    brboard('adopt')
    local after = brboard()
    ok(printed(after, '^%s*x%s*= ' .. ('%.5f'):format(B.prop.x + 0.37) .. ',$'),
        'adopt writes the entity\'s true origin into the block')
    ok(printed(after, '^%s*heading%s*= 225%.00,$'),
        'and its true heading, which is how 135 becomes 225 if the ymap inverted it')
    ok(printed(after, '^  facing 225%.00   config says 225%.00   off by 0%.00$'),
        'and the readout then agrees with itself')

    -- Put it back the way the rest of the file expects.
    if h then
        dui.objects[h].x = B.prop.x
        dui.objects[h].heading = B.prop.heading
    end
    brboard('reset')
    tick()
end

describe('/brboard prop auditions a model without touching the map')
do
    -- AUDITION THE SIBLING. prop_huge_display_01 is the other half of the pair and
    -- is the first thing to try if this turns out to be the wrong one.
    local deletedBefore, createdBefore = dui.deleted, #dui.created

    brboard('prop', 'prop_huge_display_01')
    tick()
    eq(dui.deleted, deletedBefore,
        'auditioning a model deletes nothing -- the old prop was never ours')
    eq(dui.made, 0, 'and builds nothing')
    eq(#frame(), 0, 'and with no such model in the world, nothing is drawn')

    -- ═══ AND THE BROWSER SURVIVES A PROP THAT IS NOT THERE ═══
    --
    -- A display that streams out from under a player is the ordinary case, and
    -- destroying a Chromium instance every time one does -- then building another
    -- when it comes back -- is the churn the issue's one-browser rule is about.
    eq(#dui.created, createdBefore, 'and no browser is built or rebuilt for it')

    -- ...AND THE OTHER MODEL IS FOUND WHEN IT EXISTS, so the block above is about
    -- the audition and not about the search being broken.
    dui.place(hashOf('prop_huge_display_01'), B.prop.x, B.prop.y, B.prop.z, 0.0)
    for _ = 1, 30 do tick() end
    eq(#frame(), 2, 'and a world containing the audition model draws on it')

    brboard('reset')
    for _ = 1, 30 do tick() end
    ok(printed(brboard(), "model%s*= 'prop_huge_display_02',"),
        'and reset goes back to the configured model')
end

describe('/brboard here moves where we LOOK, not where the prop stands')
do
    -- ═══ THIS COMMAND CHANGED MEANING WHEN THE PROP STOPPED BEING OURS ═══
    --
    -- It used to survey a spot to build a prop on, and it took the player's own
    -- heading with it. Nothing is built any more and nothing may be rotated, so
    -- what is left is the useful half: stand next to the display and the search
    -- starts from there, which is how a configured coordinate that turns out to
    -- be too far off gets corrected without a restart.
    teardownWorld()
    BR.State.me.state = BR.PlayerState.WARMUP

    -- A display a long way from the configured site: out of radiusM, so the
    -- shipped coordinates cannot reach it.
    local far = dui.place(hashOf(B.prop.model),
                          B.prop.x + 60.0, B.prop.y, B.prop.z, 42.0)
    dui.ped.x, dui.ped.y, dui.ped.z = B.prop.x + 61.0, B.prop.y, B.prop.z

    for _ = 1, 30 do tick() end
    eq(#frame(), 0, 'from the configured site it cannot be reached')

    brboard('here')
    for _ = 1, 30 do tick() end
    eq(#frame(), 2, 'and standing beside it and typing `here` finds it')
    eq(dui.made, 0, 'without building anything')

    -- AND THE SEARCH REALLY MOVED, rather than the numbers moving and the search
    -- staying put -- which would be a readout that agrees with itself and with
    -- nothing on screen.
    local last = dui.searches[#dui.searches]
    ok(near(last.x, B.prop.x + 61.0, 0.01),
        'the search is now centred on the player')

    -- `here` NO LONGER TAKES HIS HEADING. It cannot: the facing belongs to the
    -- ymap. The block still reads the configured heading, and `adopt` is what
    -- replaces it with the real one.
    ok(printed(brboard(), '^%s*heading%s*= 135%.00,$'),
        'and it leaves the heading alone, because it has no business rotating '
            .. 'a piece of the map')

    dui.objects[far] = nil
    brboard('reset')
end

describe('/brscoreboard is the same tool under the name he reached for')
do
    -- Owner, 2026-09-11: "Just give me tools like `brscoreboard` or something to
    -- adjust them."
    --
    -- AN ALIAS AND NOT A SECOND IMPLEMENTATION. Two commands that tune the same
    -- five numbers are two commands that will one day disagree about what they
    -- tune, so this asserts they are the SAME FUNCTION VALUE rather than that
    -- both happen to print something.
    ok(cmds['brscoreboard'] ~= nil, 'the alias is registered')
    ok(cmds['brscoreboard'] == cmds['brboard'],
        'and it is the identical function, not a copy of it')
end

describe('the resource stopping does not leave a browser behind')
do
    teardownWorld()
    BR.State.me.state = BR.PlayerState.WARMUP
    standAtSite()
    placeTheDisplay()
    for _ = 1, 30 do tick() end
    eq(#frame(), 2, 'the board is up')

    local before, deletedBefore = dui.destroyed, dui.deleted
    handlers['onResourceStop']('br_core')
    eq(dui.destroyed, before + 1, 'the browser is destroyed on the way out')
    eq(dui.deleted, deletedBefore,
        'and the map keeps its display, on the one edge that fires for every '
            .. 'player on every `restart br_core`')
    eq(#frame(), 0, 'and nothing is drawn after it')
end

-- ═══ THE TWO NUMBERS THAT MUST STILL BE ZERO ═══
--
-- Asserted per block above and asserted once more here at the end, because these
-- two are the whole difference between adopting the owner's display and building
-- a second one on top of it -- and between leaving his map alone and taking a
-- piece out of it.
describe('across the whole of Part D, nothing was built and nothing deleted')
do
    eq(dui.made, 0, 'not one object was created by br_core')
    eq(dui.deleted, 0, 'and not one was deleted')
    eq(#dui.requests, 0,
        'and no model was ever requested, because none was ever spawned')
end

-- =========================================================================
-- PART E -- what these two files SAY about the page they point a texture at
-- =========================================================================
--
-- ═══ A COMMENT THAT CONTRADICTS THE CODE IS A DEFECT, AND THIS PROJECT HAS
--     BEEN BITTEN BY IT REPEATEDLY ═══
--
-- Neither of these files can see the document. They aim a browser at a URL
-- another repository serves, so everything they say about what that document
-- DOES is a claim about somebody else's codebase, and nothing in this tree can
-- notice it going stale. Two of them already had:
--
--   "Ringmaster's renderer is deliberately built with no transition, no
--    keyframe and no easing anywhere in it." Untrue since Ringmaster's ee66ad2,
--    which added a bounded view transition and a motion setting, and further
--    untrue since 657242e, which added a background that drifts continuously.
--    It now describes SCOREBOARD_MOTION=off alone, and the default is full.
--
--   "A DUI repaints when its content changes and costs approximately nothing
--    when it does not." Untrue of FiveM: NUIRenderCallbacks.cpp calls
--    UpdateFrame() on every registered NUI window unconditionally, and the
--    dirty-flag gate is in the software fallback branch only.
--
-- ⚠ WHAT THIS CAN AND CANNOT DO. It cannot check Ringmaster -- that repository
-- is not on this box at test time and must never be a dependency of this gate.
-- What it CAN do is refuse to let the retired claims come back, and insist the
-- correction names the knob that replaced them, so the next reader is pointed at
-- the file that owns the argument instead of re-deriving it.
describe('neither board file claims the page is still or free any more')
do
    local function readFile(p)
        local fh = io.open(p, 'rb')
        if not fh then return '' end
        local s = fh:read('a')
        fh:close()
        return s
    end

    local cfg = readFile(ROOT .. 'br_lib/config/board.lua')
    local cli = readFile(ROOT .. 'br_core/client/board.lua')
    ok(#cfg > 0 and #cli > 0, 'both board files were actually read',
        ('%d / %d bytes'):format(#cfg, #cli))

    -- THE RETIRED CLAIMS, MATCHED ON THE LOAD-BEARING FRAGMENT. Both are
    -- quotable in a note that says they were withdrawn, so the match is on the
    -- ASSERTION rather than on the words -- "is deliberately built with no"
    -- cannot appear in a sentence retiring itself.
    ok(cfg:find('renderer is deliberately built with no', 1, true) == nil,
        'config/board.lua no longer asserts the page has no transition, '
            .. 'keyframe or easing',
        cfg:find('renderer is deliberately built with no', 1, true))
    ok(cli:find('costs approximately nothing when it does', 1, true) == nil,
        'and client/board.lua no longer reasons from a still DUI being free',
        cli:find('costs approximately nothing when it does', 1, true))

    -- AND THE CORRECTION NAMES WHAT REPLACED THEM, in both files, so neither is
    -- merely a deletion. SCOREBOARD_MOTION is the knob and scoreboardPage.ts is
    -- where the argument lives; a reader who has only one of those has to guess
    -- at the other.
    ok(cfg:find('SCOREBOARD_MOTION', 1, true) ~= nil,
        'config/board.lua names the motion setting that decides it now')
    ok(cli:find('SCOREBOARD_MOTION', 1, true) ~= nil,
        'and so does client/board.lua')
    ok(cfg:find('scoreboardPage.ts', 1, true) ~= nil
        and cli:find('scoreboardPage.ts', 1, true) ~= nil,
        'and both point at the file in the other repository that owns the '
            .. 'argument, rather than re-deriving it here')
    ok(cfg:find('NUIRenderCallbacks', 1, true) ~= nil
        and cli:find('NUIRenderCallbacks', 1, true) ~= nil,
        'and both name the FiveM source the per-frame blit was read out of, so '
            .. 'the correction is checkable rather than asserted')
end

-- ---------------------------------------------------------------- report ---

realPrint(('\n%s  board: %d passed, %d failed')
    :format(fail == 0 and '\27[32mPASS\27[0m' or '\27[31mFAIL\27[0m', pass, fail))
realExit(fail == 0 and 0 or 1)
