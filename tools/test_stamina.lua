-- Sprint is unlimited, and GTA's own stamina never runs out (#389).
--
--   "eliminates the concept of the stamina/sprint bar, and instead allows
--    infinite stamina."                              -- owner, 2026-10-04
--
-- ═══ WHY A SUITE FOR ONE NATIVE CALL ═══
--
-- What is left of br_core/client/stamina.lua is one call on the tick band, and
-- the failure it prevents cannot be seen until it happens: GTA drains HEALTH
-- from a player who runs its own stamina dry. Our old meter stopped every
-- sprint after about eight seconds, so the engine's never got near empty and a
-- weak pin would have gone unnoticed. Sprint is unlimited now, so a pin that
-- misses a state, skips ticks, or restores too little is a player losing
-- health for running -- which from inside a match reads as damage from nowhere.
--
-- So this loads the real file on the real loop registry and steps it, with a
-- player who holds sprint for a full minute. Nothing here is a text search.
--
-- Run:  lua tools/test_stamina.lua        (or via tools/verify.sh)

-- ------------------------------------------------------------ native stubs ---

local realPrint = print
local logged = {}
function print(s) logged[#logged + 1] = tostring(s) end

local fakeTime = 0
function GetGameTimer() return fakeTime end
function GetCurrentResourceName() return 'br_core' end
function GetPlayerServerId() return 1 end

--- NOT 0. Every other suite answers 0 here, and a pin that hard-coded player 0
--- would agree with them by accident. This client is player 7.
local ME = 7
function PlayerId() return ME end
function PlayerPedId() return 1 end

Citizen = { CreateThread = function() end, Wait = function() end,
            SetTimeout = function() end }

local handlers = {}
function AddEventHandler(n, fn)
    handlers[n] = handlers[n] or {}
    table.insert(handlers[n], fn)
end
function RegisterNetEvent() end

local commands = {}
function RegisterCommand(n, fn) commands[n] = fn end

--- Every RestorePlayerStamina, in order.
local restores = {}
function RestorePlayerStamina(player, amount)
    restores[#restores + 1] = { player = player, amount = amount }
end

--- What the last FRAME step disabled. A disable lasts one frame, so the record
--- starts empty on every frame.
local disabled = {}
function DisableControlAction(_pad, control) disabled[control] = true end

--- A PLAYER WHO IS SPRINTING, BY EVERY READING THE OLD METER TOOK. On foot,
--- the engine says sprinting, the sprint key is down and the ped is moving at a
--- run. Nothing in the shipped file reads these; they are here so that anything
--- which starts reading them again sees a sprint that never ends.
local SPRINT = 21
function IsPedOnFoot() return true end
function IsPedSprinting() return true end
function IsControlPressed(_pad, c) return c == SPRINT end
function GetEntitySpeed() return 7.0 end

-- ---------------------------------------------------------------- modules ---

local ROOT = 'resources/[fivem-royale]/'

local function loadMod(f)
    local chunk, err = loadfile(ROOT .. f)
    if not chunk then
        realPrint('\27[31mload error\27[0m ' .. f .. ': ' .. tostring(err))
        os.exit(1)
    end
    chunk()
end

for _, f in ipairs({
    'br_lib/shared/enums.lua', 'br_lib/shared/protocol.lua',
    'br_lib/shared/rng.lua', 'br_lib/shared/geo.lua', 'br_lib/shared/clock.lua',
    -- For the config check at the bottom: the meter's tuning lived here.
    'br_lib/config/match.lua',
    'br_core/client/main.lua',
}) do loadMod(f) end

local before = {}
for _, n in ipairs(BR.Loop.names()) do before[n.name] = true end

loadMod('br_core/client/stamina.lua')

--- What stamina.lua put on the loop, found rather than named, so a rename is
--- not a failure and a second callback is not hidden.
local added = {}
for _, n in ipairs(BR.Loop.names()) do
    if not before[n.name] then added[#added + 1] = n end
end

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

--- One tick: 100ms of frames, then the tick band, and the slow band on every
--- tenth -- all three bands at the rates the real loop runs them, so a pin on
--- any band is judged by what it actually covers.
local ticks = 0
local function tick()
    for _ = 1, 6 do
        fakeTime = fakeTime + 16
        disabled = {}
        BR.Loop.step(BR.Loop.FRAME)
    end
    fakeTime = fakeTime + 4
    BR.Loop.step(BR.Loop.TICK)
    ticks = ticks + 1
    if ticks % 10 == 0 then BR.Loop.step(BR.Loop.SLOW) end
end

--- RESTORE_PLAYER_STAMINA ADDS a share of the maximum, documented as 0.0 to
--- 1.0. Anything at 1.0 or over fills an empty meter in one call, so no sprint
--- can get ahead of it between two ticks.
local FULL = 1.0

--- Did this tick top up THIS player's engine meter to full?
--- @return boolean ok, string why
local function pinned()
    if #restores == 0 then return false, 'no RestorePlayerStamina at all' end
    for _, r in ipairs(restores) do
        if r.player == ME and type(r.amount) == 'number' and r.amount >= FULL then
            return true, 'ok'
        end
    end
    local r = restores[#restores]
    return false, ('player %s, amount %s'):format(tostring(r.player), tostring(r.amount))
end

-- ------------------------------------------------------- the pin is a loop ---

describe('the pin')
do
    -- Which band is not asserted: every check below steps all three, so what
    -- is judged is whether every tick ends with the meter full.
    ok(#added >= 1, 'stamina.lua puts the pin on the loop')
end

-- ------------------------------------------------------ every player state ---

describe('every state')
do
    -- Sorted so a failure names the same state on every run.
    local states = {}
    for _, v in pairs(BR.PlayerState) do states[#states + 1] = v end
    table.sort(states)
    ok(#states >= 9, 'the enum is the one this file was written against',
       #states .. ' states')

    for _, st in ipairs(states) do
        BR.State.me.state = st
        restores = {}
        tick()
        local good, why = pinned()
        ok(good, ('the engine\'s stamina is filled while %s'):format(st), why)
    end

    -- A STATE NOBODY HAS WRITTEN YET, AND NO STATE AT ALL. The pin is not a
    -- list of states, so a new one cannot be missing from it; and the client
    -- runs ticks before its first roster snapshot says who it is.
    BR.State.me.state = 'a-state-added-next-year'
    restores = {}
    tick()
    ok((pinned()), 'and in a state that does not exist yet', select(2, pinned()))

    local me = BR.State.me
    BR.State.me = nil
    restores = {}
    tick()
    ok((pinned()), 'and before this client knows who it is', select(2, pinned()))
    BR.State.me = me
end

-- --------------------------------------------- a minute of sprinting, flat out ---

describe('a minute of sprint')
do
    BR.State.me.state = BR.PlayerState.ALIVE
    local missed, blockedAt = 0, nil
    for i = 1, 600 do
        restores = {}
        tick()
        if not pinned() then missed = missed + 1 end
        if disabled[SPRINT] and not blockedAt then blockedAt = i end
    end
    ok(missed == 0, 'every one of 600 ticks fills the engine\'s stamina',
       missed .. ' ticks went without')
    ok(blockedAt == nil, 'and sprint is never taken away, however long it is held',
       blockedAt and ('blocked after %.1f s'):format(blockedAt / 10))

    -- The same minute in warmup, where the old meter also ran.
    BR.State.me.state = BR.PlayerState.WARMUP
    missed, blockedAt = 0, nil
    for i = 1, 600 do
        restores = {}
        tick()
        if not pinned() then missed = missed + 1 end
        if disabled[SPRINT] and not blockedAt then blockedAt = i end
    end
    ok(missed == 0 and blockedAt == nil, 'and the same in warmup',
       ('%d missed, blocked at %s'):format(missed, tostring(blockedAt)))
end

-- --------------------------------------------------------- the pin stays up ---

describe('health of the callback')
do
    -- BR.Loop suspends a callback after five errors in a row and says so once.
    -- A pin that threw would stop pinning for the rest of the session.
    for _, s in ipairs(BR.Loop.stats()) do
        if not before[s.name] then
            ok(s.errors == 0 and not s.suspended and s.enabled,
               ('%s has run %d times without an error'):format(s.name, s.calls),
               ('%d errors, suspended %s'):format(s.errors, tostring(s.suspended)))
        end
    end
end

-- ------------------------------------------------------ and no meter is left ---

describe('no meter')
do
    ok(BR.Config.Stamina == nil, 'there is no sprint meter tuning to read')
    ok(BR.State.stamina == nil, 'nothing publishes a stamina reading for a HUD bar',
       tostring(BR.State.stamina))
    ok(commands.brstam == nil, 'and no command reads out a meter that is gone')

    -- AND THE BAR CANNOT COME BACK THROUGH THE NUI CONTRACT. Read as text, so a
    -- `stamina` field returning to the HUD envelope or to HudPayload fails here
    -- even though nothing in this file loads state.lua or the page.
    local function slurp(path)
        local f = io.open(path, 'rb')
        if not f then return nil end
        local t = f:read('a'); f:close(); return t
    end
    local stateLua = slurp('resources/[fivem-royale]/br_core/client/state.lua')
    local types = slurp('ui-src/src/bridge/types.ts')
    ok(stateLua ~= nil and not stateLua:find('stamina%s*='),
       'the HUD envelope carries no stamina field')
    ok(types ~= nil and not types:find('stamina%??%s*:'),
       "and the page's HudPayload declares none")
end

-- ---------------------------------------------------------------- result ---

realPrint(('\n\27[32m%d passed\27[0m'):format(pass))
if fail > 0 then
    realPrint(('\27[31m%d failed\27[0m'):format(fail))
    os.exit(1)
end
