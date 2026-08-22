-- A spectator's ped does nothing, and gets everything back.
--
-- "Admin spectating works great, however I had a gun in hand and accidentally
-- shot it while in spectate. My preference would be we disable all ped actions
-- while in spectate -- this would allow them to continue riding passenger seat
-- in a vehicle for example, but would prevent accidental gun fires or walking
-- around." -- the owner, 2026-08-22.
--
-- ═══ WHY THIS IS A SUITE OF ITS OWN ═══
--
-- br_core/client/spectate.lua is in no other suite's load list, and
-- tools/test_client.lua says so in a comment where it STUBS BR.Spectate: "it is
-- a camera, and standing one up here would mean stubbing RenderScriptCams and
-- the shape tests for no assertion's benefit". That was true while the only
-- thing anybody read from the file was `active()`. It stopped being true the
-- moment the file grew a rule about the player's own ped, because that rule has
-- two properties neither a text gate nor a stub can see:
--
--   WHICH controls are held -- a list is exactly the kind of thing a text gate
--   passes on while an id is quietly missing from it, and the missing id in the
--   shipped version was the one the report is about;
--
--   and WHEN they are let go, which is a question about frames. The whole
--   safety argument for this feature is that DisableControlAction expires on
--   its own, so the test that matters is "step the frame with no session and
--   observe that nothing was disabled" -- and that is a step, not a string.
--
-- So the camera natives ARE stubbed here, and it is worth it once.
--
-- ═══ THE FAILURE THIS IS AIMED AT ═══
--
-- Not the gunshot. The gunshot is an accident with a bruise attached. The
-- failure worth a suite is a player who stops spectating and CANNOT MOVE, with
-- nothing on screen to say why -- br_ui/client/nui.lua has shipped that shape
-- twice (a focus stack that returned early and left a screen nobody could
-- raise), and this file's own header cites it. Every restoration path below is
-- there because of that, not because of the trigger.
--
-- Run:  lua tools/test_spectate.lua        (or via tools/verify.sh)

-- ------------------------------------------------------------ native stubs ---

local realPrint = print
local logged = {}
function print(s) logged[#logged + 1] = tostring(s) end

local fakeTime = 0
function GetGameTimer() return fakeTime end
function PlayerId() return 0 end
function GetPlayerServerId() return 1 end
function GetCurrentResourceName() return 'br_core' end

Citizen = { CreateThread = function() end, Wait = function() end,
            SetTimeout = function() end }

local handlers = {}
function AddEventHandler(n, fn)
    handlers[n] = handlers[n] or {}
    table.insert(handlers[n], fn)
end
function RegisterNetEvent() end

local events = {}
function TriggerEvent(n, ...)
    events[#events + 1] = { name = n, args = { ... } }
    for _, fn in ipairs(handlers[n] or {}) do fn(...) end
end

local sent = {}
function TriggerServerEvent(n, ...) sent[#sent + 1] = { name = n, args = { ... } } end

local commands = {}
function RegisterCommand(n, fn) commands[n] = fn end

--- EVERY DisableControlAction OF THE FRAME, AND THE FRAME IS THE UNIT.
---
--- Cleared by `frame()` below rather than by each test, because "what did this
--- ONE step disable" is the only question worth asking of a native whose effect
--- lasts exactly one frame. A recorder that accumulated across steps could not
--- tell a control released on the right frame from one released ten frames
--- late, which is the whole subject of the restoration block.
local held = {}
function DisableControlAction(_pad, control, _disable)
    held[control] = (held[control] or 0) + 1
end

--- THE NATIVES THAT WOULD TAKE A PASSENGER OUT OF THEIR SEAT, COUNTED.
---
--- The owner's sentence has two halves and this is the second one: "this would
--- allow them to continue riding passenger seat in a vehicle for example". A
--- suppression list cannot eject anybody -- DisableControlAction suppresses
--- input and does not task a ped -- but that is an argument, and the way an
--- argument like it stops being true is somebody adding a "tidy up the ped"
--- line later, in a change about something else.
---
--- tools/check_spectator_hud.lua already refuses four of these AS TEXT, for the
--- minimap's sake. This counts them at RUN TIME instead, which reaches the
--- three that gate does not name (the two task calls and SetPedIntoVehicle) and
--- proves the absence over a whole session rather than over a grep.
local moved = {}
for _, n in ipairs({
    'SetEntityCoords', 'SetEntityCoordsNoOffset', 'SetEntityVisible',
    'FreezeEntityPosition', 'NetworkResurrectLocalPlayer',
    'TaskLeaveVehicle', 'ClearPedTasks', 'ClearPedTasksImmediately',
    'SetPedIntoVehicle',
}) do
    _G[n] = function() moved[#moved + 1] = n end
end

-- The camera. `camWorks` is a fixture knob rather than scenery: a session whose
-- camera could not be created is one of the two states the shipped code left
-- the trigger live in, and it is asserted on below.
local camWorks   = true
local camsMade   = 0
local liveCam    = nil
function CreateCamWithParams()
    if not camWorks then return -1 end
    camsMade = camsMade + 1
    liveCam = 400 + camsMade
    return liveCam
end
function DoesCamExist(c) return c ~= nil and c == liveCam end
function DestroyCam() liveCam = nil end
function SetCamActive() end
--- WHERE THE SHOT IS, so "the camera still turns" can be an observation rather
--- than an absence of errors.
local camAt = nil
function SetCamCoord(_c, x, y, z) camAt = { x = x, y = y, z = z } end
function PointCamAtCoord() end
function RenderScriptCams() end

function GetFrameTime() return 0.016 end

--- GET_CONTROL_NORMAL, MODELLED RATHER THAN NOOPED, and this is the fixture
--- that pays for itself.
---
--- The camera orbits on controls 1 and 2 through THIS native -- not the
--- disabled variant -- and the engine answers 0.0 for a control somebody has
--- disabled this frame. So "the look controls were added to the blocked list"
--- and "the camera stopped turning" are the same event, and modelling the
--- native honestly is what lets the suite see it. A stub returning a constant
--- would pass happily with the camera welded straight ahead.
local stickLR, stickUD = 0.0, 0.0
function GetControlNormal(_pad, control)
    if held[control] then return 0.0 end
    if control == 1 then return stickLR end
    if control == 2 then return stickUD end
    return 0.0
end

function GetEntityCoords() return { x = 10.0, y = 20.0, z = 30.0 } end
function StartShapeTestRay() return 7 end
function GetShapeTestResult() return 2, 0, nil end

-- ---------------------------------------------------------------- modules ---

local ROOT = 'resources/[fivem-royale]/'

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

loadAll({
    'br_lib/shared/enums.lua', 'br_lib/shared/protocol.lua',
    'br_lib/shared/rng.lua', 'br_lib/shared/geo.lua', 'br_lib/shared/clock.lua',
    'br_lib/config/match.lua', 'br_lib/config/storm.lua', 'br_lib/config/map.lua',
    'br_lib/config/weapons.lua', 'br_lib/config/loot.lua',
    'br_lib/shared/storm_solve.lua',
    'br_core/client/main.lua',       -- the loop registry; must be first
})

-- The collaborators spectate.lua reaches for, each stubbed at the surface it is
-- actually used through. BR.Native is a wrapper file whose spectate half is
-- three lines of SetFocusEntity; loading it would pull in the blip and help-box
-- machinery for no assertion's benefit.
local focused, minimap = {}, { locked = 0, unlocked = 0 }
BR.Native = {
    spectate      = function(src) focused[#focused + 1] = src return true end,
    stopSpectate  = function() focused[#focused + 1] = 'stop' end,
    spectatePed   = function() return 0 end,   -- out of scope: the common case
    lockMinimap   = function() minimap.locked = minimap.locked + 1 end,
    unlockMinimap = function() minimap.unlocked = minimap.unlocked + 1 end,
}

BR.State = BR.State or {}
BR.State.me = { src = 1, state = BR.PlayerState.DEAD }

-- The key layer, captured rather than driven through keybinds.lua. What matters
-- here is that a subscriber exists and that a press reaches the server; WHICH
-- physical key it is on is keybinds.lua's business and is tested there.
local keySubs = {}
BR.Keys = {
    on = function(action, fn)
        keySubs[action] = keySubs[action] or {}
        table.insert(keySubs[action], fn)
    end,
    labelFor = function() return 'RIGHT' end,
}

local hudPushes = 0
function BR.PushHud() hudPushes = hudPushes + 1 end
function BR.DeathVerdictUp() return false end

loadAll({ 'br_core/client/spectate.lua' })

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

--- One frame. Returns the set of controls that frame disabled.
---
--- THE CLEAR IS BEFORE THE STEP AND NOT AFTER IT, which is the difference
--- between testing this feature and testing a latch. Clearing afterwards would
--- carry the previous frame's suppression into the assertion and every
--- restoration test below would pass against code that never let go.
local function frame()
    held = {}
    BR.Loop.step(BR.Loop.FRAME)
    return held
end

local function fire(name, ...)
    for _, fn in ipairs(handlers[name] or {}) do fn(...) end
end

--- Start (or retarget) a session, the way the server does.
local function start(opts)
    opts = opts or {}
    fire(BR.Net.SPECTATE_SET, {
        targetSrc = opts.targetSrc or 7,
        name      = opts.name or 'Watched',
        admin     = opts.admin == true,
        x = 100.0, y = 200.0, z = 30.0,
    })
end

local function stop(reason)
    fire(BR.Net.SPECTATE_SET, { stop = true, reason = reason or 'stopped' })
end

local function count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

local function sorted(t)
    local out = {}
    for k in pairs(t) do out[#out + 1] = k end
    table.sort(out)
    return table.concat(out, ',')
end

-- ═════════════════════════════════════════════════════════════ what is held ═

describe('the list')

--- The controls a spectating ped must not be able to use, by name.
---
--- SPELLED OUT HERE RATHER THAN READ OUT OF THE FILE UNDER TEST. A test that
--- scrapes `BLOCKED` and compares it to itself asserts nothing at all; this is
--- the second, independent statement of the same list, which is the only shape
--- in which "control 92 went missing" is a failure rather than a diff.
---
--- Names and indices from docs.fivem.net/docs/game-references/controls and the
--- citizenfx/fivem-docs source of that table, cross-read 2026-08-22.
local MUST_BLOCK = {
    [21] = 'SPRINT',    [22] = 'JUMP',      [23] = 'ENTER',
    [24] = 'ATTACK',    [25] = 'AIM',
    [30] = 'MOVE_LR',   [31] = 'MOVE_UD',
    [32] = 'MOVE_UP_ONLY',   [33] = 'MOVE_DOWN_ONLY',
    [34] = 'MOVE_LEFT_ONLY', [35] = 'MOVE_RIGHT_ONLY',
    [44] = 'COVER',     [75] = 'VEH_EXIT',
    [45] = 'RELOAD',    [47] = 'DETONATE',  [58] = 'THROW_GRENADE',
    [68] = 'VEH_AIM',   [69] = 'VEH_ATTACK', [70] = 'VEH_ATTACK2',
    [91] = 'VEH_PASSENGER_AIM', [92] = 'VEH_PASSENGER_ATTACK',
    [114] = 'VEH_FLY_ATTACK',   [331] = 'VEH_FLY_ATTACK2',
    [140] = 'MELEE_ATTACK_LIGHT', [141] = 'MELEE_ATTACK_HEAVY',
    [142] = 'MELEE_ATTACK_ALTERNATE', [143] = 'MELEE_BLOCK',
    [257] = 'ATTACK2',  [263] = 'MELEE_ATTACK1', [264] = 'MELEE_ATTACK2',
    [345] = 'VEH_MELEE_HOLD', [346] = 'VEH_MELEE_LEFT',
    [347] = 'VEH_MELEE_RIGHT',
}

do
    start()
    local h = frame()

    local missing = {}
    for id, name in pairs(MUST_BLOCK) do
        if not h[id] then missing[#missing + 1] = ('%d (%s)'):format(id, name) end
    end
    table.sort(missing)
    ok(#missing == 0, 'every control a ped acts through is held down',
       'not held: ' .. table.concat(missing, ', '))

    -- THE FOUR THAT ARE THE REPORT, NAMED ONE AT A TIME. The sweep above fails
    -- as one line however many ids go missing; these fail as four sentences,
    -- and the sentence is what tells the next reader which accident came back.
    ok(h[24], 'a gun does not fire on foot (ATTACK)')
    ok(h[69] and h[92],
       'and a gun does not fire from a seat -- INPUT_VEH_ATTACK (69) and '
           .. 'INPUT_VEH_PASSENGER_ATTACK (92), which INPUT_ATTACK never covered '
           .. 'and which #206 makes a position this gamemode actively tells '
           .. 'players about')
    ok(h[58] and h[47],
       'a grenade is not thrown and a sticky is not detonated -- both are real '
           .. 'loot here, and every throwable is `driveby = true` in '
           .. 'br_lib/config/weapons.lua because DRIVEBY_THROW reaches every seat')
    ok(h[32] and h[33] and h[34] and h[35],
       'and the ped does not walk')
end

do
    -- THE OVERLAP WITH client/dbno.lua, ASSERTED IN ONE DIRECTION ONLY.
    --
    -- The two lists are deliberately not one array -- spectate.lua's header
    -- argues why -- but "not shared" must not become "drifted". A control added
    -- to DOWNED_BLOCKED is a control somebody decided a player with no weapon
    -- and no vehicle should not be able to use; a spectator, who may be an armed
    -- admin, is the strictly stronger case. So the downed list is required to be
    -- a SUBSET of this one, and never the reverse.
    local fh = io.open(ROOT .. 'br_core/client/dbno.lua', 'r')
    local src = fh and fh:read('a') or ''
    if fh then fh:close() end

    local block = src:match('local DOWNED_BLOCKED = {(.-)}')
    -- Comments first: the entries are annotated in prose, and a year in a note
    -- would read as a control id.
    local ids = {}
    for line in (block or ''):gmatch('[^\n]+') do
        for n in line:gsub('%-%-.*$', ''):gmatch('%d+') do
            ids[#ids + 1] = tonumber(n)
        end
    end

    ok(#ids >= 17,
       'DOWNED_BLOCKED was found and parsed -- a pattern that matched nothing '
           .. 'would make the subset check below vacuously true',
       ('parsed %d id(s)'):format(#ids))

    start()
    local h = frame()
    local gaps = {}
    for _, id in ipairs(ids) do
        if not h[id] then gaps[#gaps + 1] = id end
    end
    ok(#gaps == 0,
       'and every control a DOWNED player is denied, a SPECTATING player is '
           .. 'denied too',
       'in DOWNED_BLOCKED but not held while spectating: ' ..
           table.concat(gaps, ', '))
end

describe('what is deliberately left alone')
do
    start()
    local h = frame()

    -- THE CAMERA'S OWN TWO. GetControlNormal answers 0.0 for a disabled
    -- control, so blocking these does not merely look wrong -- it welds the
    -- shot straight ahead, and the symptom is a camera bug rather than a
    -- control-list bug.
    ok(not h[1] and not h[2],
       'LOOK_LR and LOOK_UD are not blocked -- the camera orbits on them '
           .. 'through GetControlNormal, which answers 0.0 for a disabled control')

    -- ...OBSERVED, NOT INFERRED. The assertion above is about a list; this one
    -- is about the thing the list would break. Turn the stick, step two frames,
    -- and the camera has to be somewhere else -- which is false the moment 1 or
    -- 2 joins BLOCKED, because the orbit reads them through GetControlNormal
    -- and the stub models the 0.0 the engine answers for a disabled control.
    frame()
    local was = camAt and { x = camAt.x, y = camAt.y } or nil
    stickLR = 1.0
    frame()
    frame()
    stickLR = 0.0
    local moved2 = was and camAt
        and (math.abs(camAt.x - was.x) + math.abs(camAt.y - was.y)) > 0.01
    ok(moved2 == true,
       'and the shot actually swings when the stick is turned',
       was and ('%.2f,%.2f -> %.2f,%.2f'):format(was.x, was.y, camAt.x, camAt.y)
           or 'no camera was ever placed')

    ok(not h[199] and not h[200],
       'FRONTEND_PAUSE is not blocked -- the pause menu is how a session is '
           .. 'stopped, and a spectator who cannot open it is a spectator who '
           .. 'cannot get out')

    -- THE DRIVING CONTROLS, DELIBERATELY. A spectating admin in the driver's
    -- seat who cannot brake is a car rolling into the sea with a player in it.
    -- Their weapons are covered above; their steering is not this report.
    local driving = {}
    for _, id in ipairs({ 59, 60, 61, 62, 63, 64, 71, 72, 76 }) do
        if h[id] then driving[#driving + 1] = id end
    end
    ok(#driving == 0,
       'and the driving controls are left alone -- refusing the brake is a '
           .. 'worse accident than the one being fixed',
       'blocked: ' .. table.concat(driving, ', '))

    -- THE ARROWS ARE NOT CONTROLS AT ALL, and the ids they would collide with
    -- if somebody ever polled them are not in the list either.
    ok(not h[174] and not h[175],
       'and the two ids GTA puts on the arrow keys are untouched')
    stop()
    frame()
end

describe('the spectate keys still work')
do
    start()
    frame()
    sent = {}
    ok(keySubs.specNext and keySubs.specPrev,
       'both arrows have a subscriber')
    for _, fn in ipairs(keySubs.specNext or {}) do fn(true) end
    for _, fn in ipairs(keySubs.specPrev or {}) do fn(true) end
    local cycles = 0
    for _, s in ipairs(sent) do
        if s.name == BR.Net.SPECTATE_CYCLE then cycles = cycles + 1 end
    end
    ok(cycles == 2,
       'and a press on each still reaches the server while every ped control '
           .. 'is held down -- the bindings go through RegisterKeyMapping, '
           .. 'which DisableControlAction cannot reach',
       ('%d cycle event(s)'):format(cycles))

    -- AND THE STOP VERB. The pause-menu row is the other way out.
    sent = {}
    fire('br:ui:pauseAction', 'spectate')
    ok(#sent == 1 and sent[1].name == BR.Net.SPECTATE_STOP,
       'and the pause-menu row still asks the server to stop')
    stop()
    frame()
end

-- ══════════════════════════════════════════════════════ what is given back ══

describe('restoration')
do
    -- NEVER STARTED.
    local h = frame()
    ok(count(h) == 0, 'a player who is not spectating has nothing held',
       sorted(h))

    -- THE ORDINARY STOP.
    start()
    ok(count(frame()) > 0, 'a session holds controls')
    stop('stopped')
    ok(count(frame()) == 0,
       'and the stop message gives every one of them back on the very next '
           .. 'frame', sorted(held))

    -- ...AND STAYS GIVEN BACK. A restoration that only holds for one frame is
    -- the same bug wearing a hat.
    frame()
    ok(count(frame()) == 0, 'and on the frames after that', sorted(held))
end

do
    -- EVERY REASON THE SERVER CAN SEND. server/spectate.lua funnels all of them
    -- through BR.Spectate.stop, which sends one message shape -- but the reason
    -- travels with it, and a client that ever branched on the reason would be a
    -- client where one of these leaked. Cheap to assert; expensive to discover.
    for _, reason in ipairs({ 'stopped', 'left', 'target-left', 'no-targets',
                              'no-match', 'gone', 'retargeted', 'shutdown' }) do
        start()
        frame()
        stop(reason)
        ok(count(frame()) == 0,
           ('a session ended with reason %q restores the ped'):format(reason),
           sorted(held))
    end
end

do
    -- THE RESOURCE GOING AWAY, which is the path no message arrives on.
    start()
    ok(count(frame()) > 0, 'a session is running before the restart')
    fire('onResourceStop', 'br_core')
    ok(count(frame()) == 0,
       'br_core stopping restores the ped with no message from the server')

    -- ...AND SOMEBODY ELSE'S RESOURCE MUST NOT. The handler that ends the
    -- session checks the name, and a version that did not would tear a live
    -- session down every time any resource on the box restarted.
    start()
    fire('onResourceStop', 'some-other-resource')
    ok(count(frame()) > 0,
       'and another resource stopping does NOT end the session')
    stop()
    frame()
end

do
    -- THE CAMERA THAT COULD NOT BE CREATED. This is the state the suppression
    -- used to sit below three early returns for: a live session, no picture,
    -- and -- before this round -- a live trigger.
    camWorks = false
    start()
    local h = frame()
    ok(count(h) > 0 and h[24] and h[92],
       'a session whose camera failed still holds the ped -- "this player is '
           .. 'spectating" and "there is a picture" are not the same condition',
       sorted(h))
    stop()
    ok(count(frame()) == 0, 'and it still restores')
    camWorks = true
end

do
    -- THE FEED THAT ARRIVES WITH NO COORDINATES. The camera cannot draw
    -- anything from this, and it is still a session.
    fire(BR.Net.SPECTATE_SET, { targetSrc = 7, name = 'Watched', admin = true })
    local h = frame()
    ok(h[24] and h[92],
       'a push with no position is still a session, and still holds the ped',
       sorted(h))
    stop()
    frame()
end

describe('both kinds of session')
do
    -- A DEAD PLAYER AND AN ADMIN ARE ONE PATH, which is the claim the file's
    -- header opens with. If it ever stops being one path, this is where it
    -- shows: the two sets have to be identical, element for element.
    start({ admin = false })
    local player = sorted(frame())
    stop()
    frame()

    start({ admin = true })
    local admin = sorted(frame())
    stop()
    frame()

    ok(player ~= '' and player == admin,
       'a dead player and an admin hold exactly the same controls',
       'player: ' .. player .. '\n       admin:  ' .. admin)
end

describe('riding as a passenger')
do
    -- NOTHING IN THIS FILE MOVES, HIDES, FREEZES OR RE-TASKS A PED, over a
    -- whole session including a retarget and a stop. A suppression list cannot
    -- eject anybody; this is what keeps that true against the "tidy up the ped"
    -- line somebody adds later in a change about something else.
    moved = {}
    start({ targetSrc = 7 })
    frame()
    frame()
    start({ targetSrc = 9 })        -- cycle to the next player
    frame()
    stop('target-left')
    frame()
    ok(#moved == 0,
       'no ped is moved, hidden, frozen, re-tasked or re-seated at any point '
           .. 'in a session -- so a passenger stays a passenger',
       table.concat(moved, ', '))

    -- AND NOT ONE BLOCKED CONTROL IS A SEAT-RETENTION CONTROL. The question the
    -- owner's sentence actually raises: is anything on this list needed in
    -- order to REMAIN in a seat? Riding is passive -- the ped stays until it is
    -- tasked out -- so the honest form of the check is that the list holds no
    -- control that leaving a vehicle is done WITH, other than the exit key
    -- itself, which is blocked in the helpful direction.
    start()
    local h = frame()
    ok(h[75], 'VEH_EXIT is blocked, which keeps a passenger IN the seat rather '
           .. 'than taking them out of it')
    ok(h[23], 'and so is ENTER, so nothing is climbed into either')
    stop()
    frame()
end

describe('the readout')
do
    -- /brspec is the only thing a playtester can ask, and a readout that throws
    -- is worse than none -- this project has paid for that twice. Both states.
    ok(type(commands.brspec) == 'function', '/brspec is registered')

    local okDown = pcall(commands.brspec, 1, {}, '')
    ok(okDown, '/brspec answers with no session running')

    start()
    frame()
    logged = {}
    local okUp = pcall(commands.brspec, 1, {}, '')
    local text = table.concat(logged, '\n')
    ok(okUp, '/brspec answers with a session running')
    ok(text:find('controls %d+ held'),
       'and it says how many controls the session is holding', text)
    stop()
    frame()
    logged = {}
    pcall(commands.brspec, 1, {}, '')
    ok(table.concat(logged, '\n'):find('controls 0 held'),
       'and reads 0 once the session is over -- the readout cannot drift from '
           .. 'the behaviour, because it is the same condition')
end

-- ---------------------------------------------------------------- result ---

realPrint(('\n\27[32m%d passed\27[0m'):format(pass))
if fail > 0 then
    realPrint(('\27[31m%d failed\27[0m'):format(fail))
    os.exit(1)
end
