-- Unit tests for the CLIENT half of the emote system (#215): the wheel, this
-- player's own playback and its cancels, the music each record is owed, the
-- gate watcher, `bremote` and the /brnativecheck rows.
--
-- Owner, 2026-10-02 (#215, "Scope v2"): "HOLD LEFT ALT to open the wheel,
-- release to pick." "Anywhere except the lobby, on foot only." A dance ends
-- when its time is up or the player moves, aims, gets in a vehicle, goes down
-- or dies -- and "damage does not cancel". Emotes are a Season 2 feature
-- (#388; owner, 2026-10-04), gated by BR.Season.has('emotes').
--
-- THE REAL FILES, A MODELLED WORLD. client/menu.lua, client/emotes.lua and
-- client/emotewheel.lua are loaded as they ship, over the real config, the
-- real loop registry and the real clock. What is modelled is what a Lua
-- process cannot be: the ped's natives (every BOOL one answers 1/0, because 0
-- is truthy in Lua and a bare read of it is this repository's most-shipped
-- defect), the keyboard layer (BR.Keys), the inventory, and ScaleformUI's
-- RadialMenu -- eight segments, Visible() firing OnMenuClose, the
-- currentSelection the library hands its movie, and a MenuHandler.
--
-- ═══ THE SEASON DISCIPLINE ═══
--
-- A client never reads br_season: it reads br_seasonServed, the season the
-- server booted with and replicated (br_lib/shared/season.lua), as it lands.
-- So this file sets that convar the way the server would have -- to BR_SEASON
-- resolved by the module's own rule, the latest when it is unset -- and
-- verify.sh runs it with no BR_SEASON, then at the season before the emotes
-- row's `from` (off) and at `from` (on). No assertion may depend on which: a
-- gate-closed case calls gateClosed() (the season before `from`), a gate-open
-- case gateOpen() (`from`), and restoreSeason() puts the run's season back.
-- Dev mode stays OFF throughout. Group 0 asserts whatever the run's season
-- means.

local ROOT = 'resources/[fivem-royale]/'
--- The season this run's server booted with: verify.sh's BR_SEASON, or nil.
local RUN_SEASON = os.getenv('BR_SEASON')

-- ------------------------------------------------------------ native stubs ---

local fakeTime = 100000
function GetGameTimer() return fakeTime end
function GetCurrentResourceName() return 'br_core' end
function GetPlayerServerId() return 7 end
function PlayerId() return 0 end
function vector3(x, y, z) return { x = x, y = y, z = z } end

--- Replicated convars as this client sees them. br_seasonServed is the one that
--- matters: the season module holds it, and re-reads it when the runtime's
--- convar listener says it moved -- so every write below is a `setr`, and the
--- listeners (AddConvarChangeListener, apiset shared) hear it. br_devMode is
--- never set, so dev mode is off for the whole file.
local convarListeners = {}
function AddConvarChangeListener(filter, fn)
    convarListeners[#convarListeners + 1] = { filter = filter, fn = fn }
    return #convarListeners
end
local convarStore = {}
local convars = setmetatable({}, {
    __index = convarStore,
    __newindex = function(_, k, v)
        convarStore[k] = v
        for _, l in ipairs(convarListeners) do
            if l.filter == nil or l.filter == k then l.fn(k, '') end
        end
    end,
})
function GetConvar(name, default)
    local v = convars[name]
    if v == nil then return default end
    return tostring(v)
end

local realPrint = print
local logged = {}
function print(...)
    local parts = {}
    for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    logged[#logged + 1] = table.concat(parts, ' ')
end

Citizen = { CreateThread = function() end, Wait = function() end,
            SetTimeout = function() end }

local handlers = {}
function AddEventHandler(n, fn)
    handlers[n] = handlers[n] or {}
    table.insert(handlers[n], fn)
end
function RegisterNetEvent() end

--- Every local event, in order. `trail` is the open's dismissal order.
local events, trail = {}, {}
function TriggerEvent(n, ...)
    events[#events + 1] = { name = n, args = { ... } }
    if n == 'br:ui:clearFocus' then trail[#trail + 1] = 'clearFocus' end
    for _, fn in ipairs(handlers[n] or {}) do fn(...) end
end
local sent = {}
function TriggerServerEvent(n, ...) sent[#sent + 1] = { name = n, args = { ... } } end

--- The commands as the GAME would hold them -- devgate's wrapper in front.
local wrappedCmds = {}
function RegisterCommand(n, fn) wrappedCmds[n] = fn end

--- A BOOL native's answer, as 1/0. `0` is truthy in Lua.
local function B(v) return v and 1 or 0 end

-- The ped.
local PED = 1
function PlayerPedId() return PED end
local pedPos = { x = 0.0, y = 0.0, z = 0.0 }
function GetEntityCoords() return pedPos end
local world, input = {}, {}
local function resetWorld()
    world = { dead = false, fatally = false, swimming = false, underwater = false,
              falling = false, freefall = false, climbing = false, vaulting = false,
              ragdoll = false, aiming = false, shooting = false, melee = false,
              speed = 0.0, entering = 0, offFoot = false, health = 200 }
    input = { x = 0.0, y = 0.0, jump = false, aimBtn = false }
end
resetWorld()
function IsEntityDead() return B(world.dead) end
function IsPedFatallyInjured() return B(world.fatally) end
function IsPedSwimming() return B(world.swimming) end
function IsPedSwimmingUnderWater() return B(world.underwater) end
function IsPedFalling() return B(world.falling) end
function IsPedInParachuteFreeFall() return B(world.freefall) end
function IsPedClimbing() return B(world.climbing) end
function IsPedVaulting() return B(world.vaulting) end
function IsPedRagdoll() return B(world.ragdoll) end
function IsPlayerFreeAiming() return B(world.aiming) end
function IsPedShooting() return B(world.shooting) end
function IsPedInMeleeCombat() return B(world.melee) end
function GetEntitySpeed() return world.speed end
function GetVehiclePedIsTryingToEnter() return world.entering end
function GetEntityHealth() return world.health end
function GetDisabledControlNormal(_, c)
    if c == 30 then return input.x end
    if c == 31 then return input.y end
    return 0.0
end
function IsDisabledControlPressed(_, c)
    if c == 22 then return B(input.jump) end
    if c == 25 then return B(input.aimBtn) end
    return 0
end
local disabled = {}
function DisableControlAction(_, c) disabled[c] = true end

-- The frontend.
local fe = { active = false, restarting = false }
function IsPauseMenuActive() return B(fe.active) end
function IsPauseMenuRestarting() return B(fe.restarting) end

-- The animation natives.
local missingDict, missingClip, slowDict = {}, {}, {}
local loaded, playing = {}, nil
local tasks, stops, clears, removes = {}, {}, 0, 0
function DoesAnimDictExist(d) return B(not missingDict[d]) end
function RequestAnimDict(d) if not slowDict[d] then loaded[d] = true end end
function HasAnimDictLoaded(d) return B(loaded[d] == true) end
function RemoveAnimDict(d) removes = removes + 1; loaded[d] = nil end
function TaskPlayAnim(ped, dict, clip, bin, bout, dur, flag)
    tasks[#tasks + 1] = { ped = ped, dict = dict, clip = clip, bin = bin,
                          bout = bout, dur = dur, flag = flag }
    playing = { dict = dict, clip = clip }
end
function IsEntityPlayingAnim(_, d, c)
    return B(playing ~= nil and playing.dict == d and playing.clip == c)
end
function StopAnimTask(ped, d, c, speed)
    stops[#stops + 1] = { ped = ped, dict = d, clip = c, speed = speed }
    playing = nil
end
function ClearPedTasks() clears = clears + 1 end
function GetAnimDuration(_, c) return missingClip[c] and 0.0 or 4.5 end
local files = {}
function LoadResourceFile(_, path) return files[path] end

-- --------------------------------------------------------- ScaleformUI model ---

--- MenuHandler: the current menu and the draw flag, as the library keeps them.
MenuHandler = { _currentMenu = nil, ableToDraw = false, cleared = 0 }
function MenuHandler:CloseAndClearHistory()
    if self._currentMenu ~= nil and self._currentMenu:Visible() then
        self._currentMenu:Visible(false)
    end
    self.cleared = self.cleared + 1
end

--- The library's movies, as far as the wheel's own close reaches them: the
--- radial's CLEAR_ALL is recorded so a hand-hidden wheel can be seen to clear.
local radialCalls = {}
ScaleformUI = { Scaleforms = {
    _radialMenu = { CallFunction = function(_, fn) radialCalls[#radialCalls + 1] = fn end },
} }

SColor = { FromHudColor = function(n) return { hud = n } end }
UIMenuItem = {}

--- A UIMenu, as BR.Menu.new builds the gun shop's. Visible(false) clears the
--- library's current menu and draw flag (SUI:13805, 13835), which is the
--- reason the wheel closes them BEFORE it shows.
UIMenu = {}
UIMenu.__index = UIMenu
function UIMenu.New(title) return setmetatable({ _visible = false, title = title }, UIMenu) end
function UIMenu:Visible(b)
    if b == nil then return self._visible end
    self._visible = b
    if b then
        MenuHandler._currentMenu, MenuHandler.ableToDraw = self, true
    else
        trail[#trail + 1] = 'menu closed'
        MenuHandler._currentMenu, MenuHandler.ableToDraw = nil, false
    end
end
for _, m in ipairs({ 'CounterColor', 'SubtitleColor', 'MouseControlsEnabled',
                     'MouseEdgeEnabled' }) do UIMenu[m] = function() end end

--- The RadialMenu: eight segments, a currentSelection the library hands to
--- LOAD_MENU when it builds (recorded as `builtWith`), and Visible(false)
--- firing OnMenuClose.
local radials = {}
RadialSegment = {}
RadialSegment.__index = RadialSegment
function RadialSegment:AddItem(item)
    -- The library's setters on a VISIBLE wheel index the wrong field; the
    -- wheel must only ever be filled while it is down.
    assert(not self.Parent._visible, 'AddItem on a visible wheel')
    item.Parent = self
    self.Items[#self.Items + 1] = item
end
RadialMenu = {}
RadialMenu.__index = RadialMenu
function RadialMenu.New()
    local m = setmetatable({
        _visible = false, currentSelection = 1, oldAngle = 0, changed = false,
        Segments = {}, InstructionalButtons = { 'accept', 'back' },
        OnMenuOpen = function() end, OnMenuClose = function() end,
        OnSegmentHighlight = function() end, OnSegmentSelect = function() end,
    }, RadialMenu)
    for i = 1, 8 do
        m.Segments[i] = setmetatable({ Index = i, Items = {}, currentSelection = 1,
                                       Parent = m }, RadialSegment)
    end
    radials[#radials + 1] = m
    return m
end
function RadialMenu:Visible(b)
    if b == nil then return self._visible end
    self._visible = b
    if b then
        self.builtWith = self.currentSelection
        MenuHandler._currentMenu, MenuHandler.ableToDraw = self, true
        trail[#trail + 1] = 'wheel shown'
    else
        self.OnMenuClose(self)
        MenuHandler.ableToDraw = false
    end
end
function RadialMenu:CurrentSelection(i)
    if i ~= nil then self.currentSelection = i return end
    return self.currentSelection or 1
end
SegmentItem = {}
SegmentItem.__index = SegmentItem
function SegmentItem.New(label) return setmetatable({ label = label }, SegmentItem) end

-- ------------------------------------------------------------------ loading ---

local function loadFile(f)
    local chunk, err = loadfile(ROOT .. f)
    if not chunk then
        realPrint('\27[31mload error\27[0m ' .. f .. ': ' .. tostring(err))
        os.exit(1)
    end
    chunk()
end

local function readFile(path)
    local fh = io.open(path, 'rb')
    if not fh then return '' end
    local s = fh:read('a')
    fh:close()
    return s
end

for _, f in ipairs({ 'br_lib/shared/enums.lua', 'br_lib/shared/protocol.lua',
                     'br_lib/shared/devgate.lua' }) do loadFile(f) end

-- THE RAW HANDLER IS CAPTURED, so its own gate branch is exercised: devgate's
-- wrapper would refuse first with dev off and the test would be vacuous. The
-- wrapped copy is kept beside it, as the game would hold it.
local devWrap = RegisterCommand
local rawCmds = {}
RegisterCommand = function(n, fn, restricted)
    rawCmds[n] = fn
    return devWrap(n, fn, restricted)
end

for _, f in ipairs({ 'br_lib/shared/geo.lua', 'br_lib/shared/clock.lua',
                     'br_lib/config/market.lua', 'br_lib/shared/season.lua',
                     'br_lib/config/seasons.lua', 'br_lib/config/emotes.lua' }) do loadFile(f) end
loadFile('br_core/client/main.lua')

local C = BR.Config.Emotes

-- A TYPO'D ID FAILS THIS SUITE rather than quietly closing a door.
BR.Season.strict = true

--- The emotes row, the two seasons either side of its edge, and what the
--- server would have replicated for this run.
local ROW = BR.Config.Seasons.features.emotes
local FROM = ROW.from
local OFF = FROM - 1
assert(OFF >= 1, 'emotes are on from Season 1, so there is no season to close them in')
local RUN_SERVED = tostring((BR.Season.resolve(RUN_SEASON)))
convars.br_seasonServed = RUN_SERVED

-- The collaborators, modelled.
local keyListeners, keyPushes, mapGatedCalls, heldKeys = {}, 0, 0, {}
BR.Keys = {
    on = function(a, fn)
        keyListeners[a] = keyListeners[a] or {}
        table.insert(keyListeners[a], fn)
    end,
    isHeld = function(a) return heldKeys[a] == true end,
    uiOwnsKeyboard = false,
    uiScreen = nil,
    push = function() keyPushes = keyPushes + 1 end,
    mapGated = function() mapGatedCalls = mapGatedCalls + 1 end,
}
local invMirror = { using = nil }
BR.Inv = {
    closePanel = function() trail[#trail + 1] = 'closePanel' end,
    offFoot = function() return world.offFoot end,
    local_ = function() return invMirror end,
}
BR.Native = { bigmap = false, frontendMap = false, fullscreenMap = false }
local watch = nil
BR.Spectate = { watchPoint = function() return watch end }
BR.State.me.src = 7
BR.State.me.state = BR.PlayerState.ALIVE

loadFile('br_core/client/menu.lua')
loadFile('br_core/client/emotes.lua')
loadFile('br_core/client/emotewheel.lua')
-- brseason's client half (#388): it raises br:season:changed when this
-- client's season moves, and prints the switch in F8. Group 9 drives it.
loadFile('br_core/client/season.lua')

-- ------------------------------------------------------------------ harness ---

local pass, fail = 0, 0
local group = ''
local function describe(n) group = n end
local function ok(cond, name, detail)
    if cond then
        pass = pass + 1
    else
        fail = fail + 1
        realPrint('\27[31mFAIL\27[0m ' .. group .. ' > ' .. name ..
            (detail ~= nil and ('\n       ' .. tostring(detail)) or ''))
    end
end

local function fire(name, ...)
    for _, fn in ipairs(handlers[name] or {}) do fn(...) end
end

local function gateClosed() convars.br_seasonServed = tostring(OFF) end
local function gateOpen() convars.br_seasonServed = tostring(FROM) end
local function restoreSeason() convars.br_seasonServed = RUN_SERVED end

local function tick(ms) fakeTime = fakeTime + (ms or 100); BR.Loop.step(BR.Loop.TICK) end
local function frame(ms)
    fakeTime = fakeTime + (ms or 16)
    disabled = {}
    BR.Loop.step(BR.Loop.FRAME)
end
local function slow() fakeTime = fakeTime + 1000; BR.Loop.step(BR.Loop.SLOW) end

local function key(pressed)
    for _, fn in ipairs(keyListeners.emoteWheel or {}) do fn(pressed) end
end

local function count(name)
    local n = 0
    for _, s in ipairs(sent) do if s.name == name then n = n + 1 end end
    return n
end
local function plays()
    local out = {}
    for _, s in ipairs(sent) do
        if s.name == BR.Net.EMOTE_PLAY then out[#out + 1] = s.args[1] and s.args[1].id end
    end
    return out
end

local function setWheel(ids)
    local e = {}
    for k = 1, 8 do e[k] = ids[k] or '' end
    fire(BR.Net.MARKET_STATE, { balance = 0, owned = {}, equipped = {}, emotes = e })
end

local ORDER = C.order
local A, Bid, Cid = ORDER[1], ORDER[2], ORDER[3]
local FULL = { ORDER[1], ORDER[2], ORDER[3], ORDER[4], ORDER[5], ORDER[6], ORDER[7], ORDER[8] }

local function wheelObj() return radials[#radials] end

--- Close the wheel if it is up and put everything back to a player standing
--- still on the warmup pad, alive, with the gate open.
local function calm()
    if BR.EmoteWheel.isOpen() then key(false) end
    resetWorld()
    invMirror.using = nil
    heldKeys = {}
    BR.Keys.uiOwnsKeyboard, BR.Keys.uiScreen = false, nil
    BR.Native.bigmap, BR.Native.frontendMap, BR.Native.fullscreenMap = false, false, false
    fe.active, fe.restarting = false, false
    BR.State.me.state = BR.PlayerState.ALIVE
    watch = nil
    pedPos.x, pedPos.y, pedPos.z = 0.0, 0.0, 0.0
    gateOpen()
    trail = {}
    sent = {}
end

--- Every record over: time moves past the longest dance, and the passes run.
local function idle()
    fakeTime = fakeTime + 700000
    tick(); tick()
end

local function record(t)
    t = t or {}
    local r = {
        src = t.src or 7, id = t.id or A, tStart = t.tStart or fakeTime,
        durationMs = t.durationMs or 12000,
        x = t.x or 0.0, y = t.y or 0.0, z = t.z or 0.0,
        tSent = t.tSent, tEnd = t.tEnd,
    }
    if r.tSent == nil and not t.noSent then r.tSent = r.tStart end
    fire(BR.Net.EMOTE_RECORD, r)
    return r
end

--- The last EMOTE_AUDIO payload, or nil.
local function lastAudio()
    for i = #events, 1, -1 do
        local e = events[i]
        if e.name == 'br:ui:sendLocal' and e.args[1] == BR.Nui.EMOTE_AUDIO then
            return e.args[2]
        end
    end
    return nil
end
local function audioCount()
    local n = 0
    for _, e in ipairs(events) do
        if e.name == 'br:ui:sendLocal' and e.args[1] == BR.Nui.EMOTE_AUDIO then n = n + 1 end
    end
    return n
end
local function near(a, b) return math.abs(a - b) < 1e-6 end

-- ════════════════════════════════════════════════════════════════════════════
-- 5. THE GATE WATCHER. Run first, because its first pass is a one-time event.
-- ════════════════════════════════════════════════════════════════════════════

--- How many times br_ui has been told to re-send the page its grid and the
--- EMOTES flag (br:emotes:gate, #388).
local function uiTold()
    local n = 0
    for _, e in ipairs(events) do if e.name == 'br:emotes:gate' then n = n + 1 end end
    return n
end

-- BEFORE THE SEASON ARRIVES (#388). br_seasonServed is a replicated convar and
-- may land after these files load; until it does the season is unknown and
-- every door must read shut -- on a Season 1 box, a door opened in that
-- window would be a Season 2 feature on a Season 1 client, and the wheel's
-- key mapping can never be taken back. Every door this file has is asked.
describe('5. gate: before the season arrives, every door is shut')
do
    convars.br_seasonServed = nil
    sent = {}
    ok(BR.Season.current() == nil and BR.Season.has('emotes') == false,
        'no season yet: the client does not guess one, and the gate reads shut',
        tostring(BR.Season.current()))
    setWheel({ A })
    key(true)
    ok(not BR.EmoteWheel.isOpen(), 'the wheel does not open')
    key(false)
    local tasksBefore, audioBefore = #tasks, audioCount()
    record({ src = 51, id = A, x = 1.0 })
    record({ id = A })
    ok(next(BR.Emotes.records()) == nil, 'records are ignored')
    tick(); tick()
    ok(#tasks == tasksBefore and audioCount() == audioBefore, 'nothing plays and no audio is sent')
    ok(BR.Emotes.request(A) == false and #plays() == 0, 'request() sends nothing')
    ok(BR.Emotes.blocked() == 'gate', "blocked() says 'gate'", BR.Emotes.blocked())

    local lines = #logged
    local okCmd, err = pcall(rawCmds.bremote, 0, {})
    ok(okCmd and logged[lines + 1] ~= nil
            and logged[lines + 1]:find("bremote: emotes are off (the server's season has not arrived yet", 1, true) ~= nil,
        'the raw bremote handler says the season has not arrived, and does not throw',
        okCmd and logged[lines + 1] or err)
    local okRows, rows = pcall(BR.Emotes.nativeCheck)
    ok(okRows and #rows == 1 and rows[1].ok == true
            and rows[1].detail:find('has not arrived', 1, true) ~= nil,
        'nativeCheck is one ok row saying so, and does not throw',
        okRows and rows[1] and rows[1].detail or rows)

    -- br_core's FIRST pass is its start (or a `restart br_core`): br_ui is told
    -- to re-send the page the gate as it reads now, shut or not.
    ok(uiTold() == 0, 'nothing has told br_ui anything before the first gate pass')
    slow()
    ok(uiTold() == 1, "br_core's first gate pass tells br_ui to re-send, with the gate shut", uiTold())
    slow()
    ok(uiTold() == 1, 'and a second pass with nothing moved tells it nothing more', uiTold())
    ok(count(BR.Net.MARKET_STATE) == 0 and keyPushes == 0 and mapGatedCalls == 0,
        'the gate pass maps nothing, pushes no keys and asks the server for nothing',
        ('%d/%d/%d'):format(count(BR.Net.MARKET_STATE), keyPushes, mapGatedCalls))
    ok(#sent == 0, 'and nothing at all reaches the server', #sent)
end

describe('5. gate: the watcher')
do
    -- THE SEASON ARRIVES AT THE ONE BEFORE `from`: still shut, and no flip.
    gateClosed()
    sent = {}
    slow()
    ok(count(BR.Net.MARKET_STATE) == 0,
        ('Season %d arriving asks the server for nothing'):format(OFF))
    ok(keyPushes == 0 and mapGatedCalls == 0,
        'and neither re-pushes the keys nor maps the gated row', keyPushes)
    ok(uiTold() == 1, 'nor tells br_ui again: the page already has it shut', uiTold())
    key(true)
    ok(not BR.EmoteWheel.isOpen(), 'and the wheel still does not open')
    key(false)

    -- AND AT `from`: the flip, once.
    gateOpen()
    slow()
    ok(count(BR.Net.MARKET_STATE) == 1,
        'opening it sends exactly one MARKET_STATE request', count(BR.Net.MARKET_STATE))
    ok(keyPushes == 1, 'and re-pushes the keybind table once', keyPushes)
    ok(mapGatedCalls == 1, 'and asks BR.Keys.mapGated while open', mapGatedCalls)
    ok(uiTold() == 2, 'and tells br_ui to re-send at once, without the round trip', uiTold())

    slow()
    ok(count(BR.Net.MARKET_STATE) == 1 and keyPushes == 1 and uiTold() == 2,
        'a pass with no flip sends nothing more')
    ok(mapGatedCalls == 2, 'but mapGated is asked on every open pass', mapGatedCalls)

    gateClosed()
    slow()
    ok(count(BR.Net.MARKET_STATE) == 2 and keyPushes == 2 and uiTold() == 3,
        'closing it is a flip: one more request, one more push, and br_ui told')
    gateOpen()
    slow()
    ok(count(BR.Net.MARKET_STATE) == 3 and keyPushes == 3 and uiTold() == 4,
        'and so is opening it again')
    local blank = true
    for _, s in ipairs(sent) do
        if s.name == BR.Net.MARKET_STATE and #s.args > 0 then blank = false end
    end
    ok(blank, 'every request carries no payload ("tell me my state")')

    -- Closed mid-dance: records, audition and the clip all go.
    setWheel({ A })
    record({ x = 1.0 })
    tick(); tick()
    ok(#tasks > 0, 'a dance is playing before the gate closes')
    local stopsBefore = #stops
    gateClosed()
    slow()
    ok(#stops == stopsBefore + 1, 'the gate closing takes the clip off the ped')
    ok(next(BR.Emotes.records()) == nil, 'and drops every record')

    -- Left CLOSED, so in a run whose season has emotes, group 0's first pass
    -- is a flip.
end

-- ════════════════════════════════════════════════════════════════════════════
-- 0. THE ONE LINE DELETED: emotes are on with dev mode off and nothing forced.
-- ════════════════════════════════════════════════════════════════════════════

describe("0. this run's season, with dev mode off")
do
    restoreSeason()
    local season = BR.Season.current()
    local want = season >= FROM and (ROW.untilSeason == nil or season < ROW.untilSeason)
    ok(tostring(season) == RUN_SERVED, 'the client runs the season the server replicated', season)
    ok(BR.Dev.on() == false and BR.Season.has('emotes') == want,
        ('Season %d: emotes are %s, with dev mode off'):format(season, want and 'on' or 'off'))
    local pushes = keyPushes
    sent = {}
    slow()
    if want then
        ok(keyPushes == pushes + 1 and count(BR.Net.MARKET_STATE) == 1,
            'the watcher sees the gate open: the keybind row is pushed and the '
                .. 'market state asked for')
        setWheel({ A })
        key(true)
        ok(BR.EmoteWheel.isOpen(), 'the wheel opens')
        fakeTime = fakeTime + 300
        key(false)
        record({ id = A })
        tick(); tick()
        ok(#tasks > 0 and tasks[#tasks].dict == BR.Emotes.row(A).dict,
            'and an own record plays its clip')
        idle()
    else
        ok(keyPushes == pushes and count(BR.Net.MARKET_STATE) == 0,
            'the watcher sees no flip: the gate stays shut and nothing is asked')
        setWheel({ A })
        key(true)
        ok(not BR.EmoteWheel.isOpen(), 'the wheel does not open')
        ok(BR.Emotes.request(A) == false and #plays() == 0, 'and request() sends nothing')
    end
end

-- ════════════════════════════════════════════════════════════════════════════
-- 1. OPENING
-- ════════════════════════════════════════════════════════════════════════════

describe('1. the wheel opens only where a dance could start')
do
    calm()
    setWheel({ A })
    key(true)
    ok(BR.EmoteWheel.isOpen(), 'gate open, ALIVE, on foot, nothing up: it opens')
    ok(wheelObj() ~= nil and wheelObj()._visible == true, 'and the radial is visible')
    ok(wheelObj() and #wheelObj().InstructionalButtons == 0,
        'with its instructional buttons emptied, as every BR.Menu menu')
    ok(BR.Menu.holdsEscape() == true, 'and Escape belongs to it while it is open (#371)')
    calm()
    ok(not BR.EmoteWheel.isOpen(), 'a release closes it')

    BR.State.me.state = BR.PlayerState.WARMUP
    key(true)
    ok(BR.EmoteWheel.isOpen(), 'it opens on the warmup pad too')
    calm()

    local refused = {
        { 'the gate is closed', function() gateClosed() end },
        { 'in the lobby', function() BR.State.me.state = BR.PlayerState.LOBBY end },
        { 'downed', function() BR.State.me.state = BR.PlayerState.DBNO end },
        { 'dead', function() world.dead = true end },
        { 'in a vehicle', function() world.offFoot = true end },
        { 'getting into a vehicle', function() world.entering = 4242 end },
        { 'swimming', function() world.swimming = true end },
        { 'falling', function() world.falling = true end },
        { 'in freefall', function() world.freefall = true end },
        { 'climbing', function() world.climbing = true end },
        { 'vaulting', function() world.vaulting = true end },
        { 'channeling an item', function() invMirror.using = { slot = 1 } end },
        { 'holding Interact', function() heldKeys.interact = true end },
        { 'GTA\'s pause menu is up', function() fe.active = true end },
        { 'the pause menu is restarting', function() fe.restarting = true end },
        { 'the big map is up', function() BR.Native.bigmap = true end },
        { 'the frontend map is up', function() BR.Native.frontendMap = true end },
        { 'the fullscreen map is up', function() BR.Native.fullscreenMap = true end },
        { 'our pause menu is up', function() BR.Keys.uiScreen = 'pause' end },
        { 'the market is up', function() BR.Keys.uiScreen = 'market' end },
        { 'a screen owns the keyboard', function() BR.Keys.uiOwnsKeyboard = true end },
    }
    for _, r in ipairs(refused) do
        calm()
        r[2]()
        trail = {}
        key(true)
        ok(not BR.EmoteWheel.isOpen() and #trail == 0,
            'it does NOT open, and dismisses nothing, while ' .. r[1],
            table.concat(trail, ','))
    end

    calm()
    input.x = 1.0
    world.speed = 3.0
    key(true)
    ok(BR.EmoteWheel.isOpen(), 'it DOES open while walking (moving is refused at the pick)')
    calm()
    world.aiming = true
    key(true)
    ok(BR.EmoteWheel.isOpen(), 'and while aiming')
    calm()
    BR.Keys.uiScreen = 'inventory'
    key(true)
    ok(BR.EmoteWheel.isOpen(), 'and over the inventory panel, which it closes')
    calm()
end

describe('1. the open dismisses, in order, before it shows')
do
    calm()
    local shop = BR.Menu.new('Ammu-Nation')
    ok(shop ~= nil, 'a BR.Menu.new menu can be built in this model')
    shop:Visible(true)
    trail = {}
    key(true)
    ok(table.concat(trail, ',') == 'closePanel,clearFocus,menu closed,wheel shown',
        'inventory panel, then the focus stack, then the open menu, then the wheel',
        table.concat(trail, ','))
    ok(shop._visible == false, 'the gun shop menu is down')
    ok(MenuHandler._currentMenu == wheelObj() and MenuHandler.ableToDraw == true,
        "and the wheel is the library's current, drawing menu -- the shop's close "
            .. 'came first, so it did not take the wheel down with it')
    calm()
    ok(MenuHandler._currentMenu ~= wheelObj() or not wheelObj()._visible,
        'releasing takes the wheel down through the library')
end

describe('1. a menu shown over the wheel keeps drawing when the wheel goes')
do
    -- #215: Interact at a gun shop counter while Alt is held. The shop's
    -- Visible(true) makes it the library's current menu; the wheel's close
    -- must then hide only the wheel, not clear the shop's draw flag.
    calm()
    key(true)
    ok(BR.EmoteWheel.isOpen() and MenuHandler._currentMenu == wheelObj(), 'the wheel is up and current')
    local shop = BR.Menu.new('Ammu-Nation')
    shop:Visible(true)
    radialCalls = {}
    key(false)
    ok(not BR.EmoteWheel.isOpen() and wheelObj()._visible == false, 'the release takes the wheel down')
    ok(MenuHandler._currentMenu == shop and MenuHandler.ableToDraw == true,
        'and the shop stays the current, DRAWING menu')
    ok(shop._visible == true, 'and stays open')
    ok(radialCalls[1] == 'CLEAR_ALL', "the wheel's movie is cleared by hand", radialCalls[1])
    shop:Visible(false)
    calm()
end

describe('1. the segments mirror the wheel, and the highlight tells the truth')
do
    calm()
    setWheel({ A, '', Cid })
    key(true)
    local w = wheelObj()
    ok(#w.Segments[1].Items == 1 and w.Segments[1].Items[1].label == BR.Emotes.row(A).name,
        'segment 1 carries the dance in slot 1, by name')
    ok(#w.Segments[2].Items == 0, 'segment 2 is empty, like slot 2')
    ok(#w.Segments[3].Items == 1 and w.Segments[3].Items[1].label == BR.Emotes.row(Cid).name,
        'segment 3 carries slot 3')
    ok(w.builtWith == 2, 'the highlight starts on the FIRST EMPTY segment (2)', w.builtWith)
    calm()

    setWheel({ '', A })
    key(true)
    ok(wheelObj().builtWith == 1, 'an empty slot 1 is highlighted first', wheelObj().builtWith)
    calm()

    setWheel(FULL)
    key(true)
    ok(wheelObj().builtWith == 1, 'a full wheel starts on segment 1', wheelObj().builtWith)
    local filled = 0
    for k = 1, 8 do filled = filled + #wheelObj().Segments[k].Items end
    ok(filled == 8, 'with all eight segments drawn', filled)
    calm()

    -- REBUILT EVERY OPEN: a slot emptied since the last open is empty now.
    setWheel({ A })
    key(true)
    filled = 0
    for k = 1, 8 do filled = filled + #wheelObj().Segments[k].Items end
    ok(filled == 1, 'the next open is rebuilt from the new mirror, not added to', filled)
    calm()
    ok(#radials == 1, 'one radial, built once and kept', #radials)
end

-- ════════════════════════════════════════════════════════════════════════════
-- 2. RELEASING
-- ════════════════════════════════════════════════════════════════════════════

describe('2. the release is the pick')
do
    local function openFor(ids, ms, sel)
        calm()
        setWheel(ids)
        key(true)
        if sel then wheelObj().currentSelection = sel end
        fakeTime = fakeTime + (ms or 300)
    end

    openFor({ A, Bid }, 100)
    key(false)
    ok(#plays() == 0 and not BR.EmoteWheel.isOpen(), 'a release inside tapMs is a tap: it cancels')

    openFor({ A, Bid }, 300)
    key(false)
    ok(#plays() == 0, 'an unmoved release with an empty slot cancels -- the highlight is on it')

    openFor(FULL, 300)
    key(false)
    ok(#plays() == 1 and plays()[1] == FULL[1],
        'an unmoved release on a FULL wheel plays segment 1, which is what is lit',
        table.concat(plays(), ','))

    openFor({ A, Bid, Cid }, 300, 3)
    key(false)
    ok(#plays() == 1 and plays()[1] == Cid,
        'a release with the highlight moved onto a filled segment sends EMOTE_PLAY { id }',
        table.concat(plays(), ','))

    openFor({ A, '', Cid }, 300, 2)
    key(false)
    ok(#plays() == 0, 'a release on an empty segment cancels')

    openFor({ A, Bid }, 300, 1)
    BR.Keys.uiOwnsKeyboard = true
    key(false)
    ok(#plays() == 0, 'a release while a screen owns the keyboard cancels')

    openFor({ A, Bid }, 300, 1)
    fire('br:ui:focusChanged', 'none')
    ok(BR.EmoteWheel.isOpen(), "focusChanged('none') does not close it")
    fire('br:ui:focusChanged', 'inventory')
    ok(not BR.EmoteWheel.isOpen(), "focusChanged('inventory') -- TAB -- closes it")
    key(false)
    ok(#plays() == 0, 'and the release after that sends nothing')

    openFor({ A, Bid }, 300, 1)
    wheelObj():Visible(false)
    ok(not BR.EmoteWheel.isOpen(), "the library's own Back (Visible(false)) closes it")
    key(false)
    ok(#plays() == 0, 'and the release after that sends nothing')

    openFor({ A, Bid }, 300, 1)
    wheelObj()._visible = false
    frame()
    ok(not BR.EmoteWheel.isOpen(), 'a wheel the library hid without a callback is noticed by the frame pass')

    openFor({ A, Bid }, 300, 1)
    frame()
    ok(BR.EmoteWheel.isOpen() and disabled[19] and disabled[24] and disabled[25] and disabled[37],
        'while open the frame pass disables Alt\'s own control, attack, aim and the weapon wheel')
    ok(not disabled[30] and not disabled[31], 'and leaves movement alone')
    world.offFoot = true
    frame()
    ok(not BR.EmoteWheel.isOpen(), 'getting into a vehicle closes it')

    for _, c in ipairs({ { 'the pause menu', function() fe.active = true end },
                         { 'a screen taking the keyboard', function() BR.Keys.uiOwnsKeyboard = true end },
                         { 'going down', function() BR.State.me.state = BR.PlayerState.DBNO end },
                         { 'the gate closing', function() gateClosed() end } }) do
        openFor({ A, Bid }, 300, 1)
        c[2]()
        frame()
        ok(not BR.EmoteWheel.isOpen(), c[1] .. ' closes an open wheel')
    end

    openFor({ A, Bid }, 300, 1)
    input.x = 1.0
    key(false)
    ok(#plays() == 0, 'a pick while moving sends nothing')

    openFor({ A, Bid }, 300, 1)
    world.aiming = true
    key(false)
    ok(#plays() == 0, 'a pick while aiming sends nothing')

    openFor({ A, Bid }, 300, 1)
    world.speed = 4.0
    key(false)
    ok(#plays() == 0, 'a pick while still carrying speed sends nothing')

    -- RAGDOLL REFUSES A START and never cancels one (group 3 has the other half).
    openFor({ A, Bid }, 300, 1)
    world.ragdoll = true
    key(false)
    ok(#plays() == 0, 'a pick while ragdolled sends nothing')

    -- request() itself: only an id on the wheel is ever sent.
    calm()
    setWheel({ A })
    local sentOk, why = BR.Emotes.request(Bid)
    ok(sentOk == false and why == 'not on the wheel' and #plays() == 0,
        'request() refuses an id that is not on the wheel, and sends nothing', why)
    calm()
end

-- ════════════════════════════════════════════════════════════════════════════
-- 3. PLAYBACK
-- ════════════════════════════════════════════════════════════════════════════

describe('3. playback: an own record plays, its end stops it')
do
    calm()
    idle()
    local before = #tasks
    local r = record({ id = A })
    tick()
    tick()
    local t = tasks[#tasks]
    local row = BR.Emotes.row(A)
    ok(#tasks == before + 1 and t.dict == row.dict and t.clip == row.clip,
        'the own record tasks its clip once the dictionary has loaded', #tasks - before)
    ok(t and t.bin == 8.0 and t.bout == -8.0 and t.dur == -1 and t.flag == 1,
        'TaskPlayAnim(..., 8.0, -8.0, -1, 1, ...)',
        t and ('%s %s %s %s'):format(t.bin, t.bout, t.dur, t.flag))
    ok(BR.Emotes.mine() ~= nil and BR.Emotes.mine().tStart == r.tStart, 'mine() is the record')
    tick(); tick()
    ok(#tasks == before + 1, 'a clip still playing is not re-tasked')

    local stopsBefore = #stops
    fakeTime = r.tStart + r.durationMs + 1
    tick()
    ok(#stops == stopsBefore + 1, 'the natural end takes the clip off')
    ok(count(BR.Net.EMOTE_STOP) == 0, 'and sends no EMOTE_STOP -- the end is computed, never messaged')
    ok(clears == 0, 'ClearPedTasks is never called')

    -- Somebody else's record is never played on this ped.
    before = #tasks
    record({ src = 99, id = Bid, x = 3.0 })
    tick(); tick()
    ok(#tasks == before, "another player's record plays nothing on this ped")
    idle()
end

describe('3. playback: every cancel stops it and sends exactly one EMOTE_STOP')
do
    local cancels = {
        { 'movement input', function() input.x = 1.0 end },
        { 'jump', function() input.jump = true end },
        { 'aiming', function() world.aiming = true end },
        { 'the aim button', function() input.aimBtn = true end },
        { 'firing (IsPedShooting)', function() world.shooting = true end },
        { 'melee', function() world.melee = true end },
        { 'a vehicle', function() world.offFoot = true end },
        { 'swimming', function() world.swimming = true end },
        { 'falling', function() world.falling = true end },
        { 'going down (DBNO)', function() BR.State.me.state = BR.PlayerState.DBNO end },
        { 'dying', function() world.dead = true end },
        { 'an item channel (inv.using)', function() invMirror.using = { slot = 2 } end },
        { 'holding Interact', function() heldKeys.interact = true end },
    }
    for _, c in ipairs(cancels) do
        calm()
        idle()
        record({ id = A })
        tick(); tick()
        local stopsBefore, tasked = #stops, playing ~= nil
        c[2]()
        tick()
        tick()
        ok(tasked and #stops == stopsBefore + 1 and count(BR.Net.EMOTE_STOP) == 1,
            c[1] .. ' stops the dance and sends exactly one EMOTE_STOP',
            ('tasked=%s stops+%d EMOTE_STOP x%d'):format(tostring(tasked),
                #stops - stopsBefore, count(BR.Net.EMOTE_STOP)))
        ok(BR.Emotes.mine() == nil, c[1] .. ': the record is over for this client at once')
    end
    calm()
    idle()
end

describe('3. playback: damage and ragdoll do not cancel')
do
    calm()
    idle()
    record({ id = A })
    tick(); tick()
    local stopsBefore, tasksBefore = #stops, #tasks
    world.health = 120
    tick(); tick()
    ok(#stops == stopsBefore and count(BR.Net.EMOTE_STOP) == 0,
        'a health drop does NOT stop it -- "damage does not cancel"')

    -- A hit ragdolls the ped and knocks the clip off.
    world.ragdoll = true
    playing = nil
    tick(1500); tick(1500)
    ok(#stops == stopsBefore and count(BR.Net.EMOTE_STOP) == 0,
        'ragdolling does NOT stop it')
    ok(#tasks == tasksBefore, 'and nothing is re-tasked onto a ragdoll', #tasks - tasksBefore)
    world.ragdoll = false
    -- Two passes: the dictionary was released when the clip was first tasked,
    -- so the first asks for it again and the second tasks.
    tick(); tick()
    ok(#tasks == tasksBefore + 1, 'once the ped is up, the dance is put back')

    -- A dropped clip without a ragdoll is put back on the re-task clock.
    playing = nil
    tasksBefore = #tasks
    tick(400)
    ok(#tasks == tasksBefore, 'a dropped clip is not re-tasked inside RETASK_MS')
    tick(700); tick()
    ok(#tasks == tasksBefore + 1, 'and is re-tasked once 1000 ms have passed')
    idle()
end

describe('3. playback: a dictionary the build lacks')
do
    calm()
    idle()
    local row = BR.Emotes.row(Bid)
    missingDict[row.dict] = true
    local lines = #logged
    local before = #tasks
    record({ id = Bid })
    tick(); tick(); tick()
    local said = 0
    for i = lines + 1, #logged do
        if logged[i]:find('this dance plays without it', 1, true) then said = said + 1 end
    end
    ok(said == 1, 'says so on the console exactly once', said)
    ok(count(BR.Net.EMOTE_STOP) == 1, 'and stops the record (one EMOTE_STOP)', count(BR.Net.EMOTE_STOP))
    ok(#tasks == before, 'and tasks nothing')
    missingDict[row.dict] = nil

    -- A dictionary that never streams is given up on after LOAD_MS.
    idle()
    sent = {}
    slowDict[row.dict] = true
    lines = #logged
    record({ id = Bid })
    tick(500); tick(500); tick(500); tick(500); tick(500)
    said = 0
    for i = lines + 1, #logged do
        if logged[i]:find('did not stream', 1, true) then said = said + 1 end
    end
    ok(said == 1 and count(BR.Net.EMOTE_STOP) == 1,
        'a dictionary that never loads is spent after 2000 ms, once', said)
    slowDict[row.dict] = nil
    ok(clears == 0, 'ClearPedTasks is never called, by anything above')
    idle()
end

describe('3. playback: a new record replaces the old one')
do
    calm()
    idle()
    record({ id = A })
    tick(); tick()
    local stopsBefore, tasksBefore = #stops, #tasks
    record({ id = Bid })
    tick()
    ok(#stops == stopsBefore + 1, 'the old clip comes off first')
    tick(); tick()
    ok(#tasks == tasksBefore + 1 and tasks[#tasks].clip == BR.Emotes.row(Bid).clip,
        'and the new one is tasked on a later pass')
    -- A tEnd copy ends it early, with nothing sent.
    local mine = BR.Emotes.mine()
    stopsBefore = #stops
    record({ id = Bid, tStart = mine.tStart, tSent = fakeTime, tEnd = fakeTime })
    tick()
    ok(#stops == stopsBefore + 1 and count(BR.Net.EMOTE_STOP) == 0,
        'a tEnd copy of the record stops it, and sends nothing back')
    idle()
end

describe('3. bremote: an over-wide flag is refused')
do
    calm()
    idle()
    local lines = #logged
    local before = #tasks
    rawCmds.bremote(0, { 'anim@x', 'clip_y', '1024' })
    tick(); tick()
    local refused = false
    for i = lines + 1, #logged do
        if logged[i]:find('refused', 1, true) then refused = true end
    end
    ok(refused and #tasks == before, '`bremote <dict> <clip> 1024` refuses and plays nothing')
    rawCmds.bremote(0, { 'anim@x', 'clip_y', '16' })
    rawCmds.bremote(0, { 'anim@x', 'clip_y', '32' })
    tick(); tick()
    ok(#tasks == before, 'and so do 16 and 32, which free the legs')
end

-- ════════════════════════════════════════════════════════════════════════════
-- 4. AUDIO
-- ════════════════════════════════════════════════════════════════════════════

describe('4. audio: distance, tracks and the final empty list')
do
    calm()
    idle()
    local base = audioCount()
    record({ src = 21, id = A, x = 5.0 })
    record({ src = 22, id = Bid, x = 25.0 })
    tick()
    local a = lastAudio()
    ok(audioCount() == base + 1 and a and #a.tracks == 1,
        'one record in earshot, one out: one track', a and #a.tracks)
    local t = a and a.tracks[1]
    ok(t and t.src == 21 and t.track == BR.Emotes.row(A).track,
        "the track is the row's file", t and t.track)
    ok(t and near(t.g, 0.75), 'a record 5 m away has g = 0.75', t and t.g)

    -- A row with no track is silent while the dance still plays.
    local row = BR.Emotes.row(Cid)
    local savedTrack = row.track
    row.track = nil
    record({ src = 23, id = Cid, x = 1.0 })
    tick()
    a = lastAudio()
    local has23 = false
    for _, tr in ipairs(a.tracks) do if tr.src == 23 then has23 = true end end
    ok(not has23 and BR.Emotes.records()[23] ~= nil,
        'a row with track = nil sends no track, and its record is still held')
    row.track = savedTrack

    -- Everything ends: exactly one empty list.
    fakeTime = fakeTime + 13000
    base = audioCount()
    tick(); tick(); tick()
    a = lastAudio()
    ok(audioCount() == base + 1 and #a.tracks == 0,
        'after the last dance ends, exactly one empty list is sent',
        audioCount() - base)
    tick()
    ok(audioCount() == base + 1, 'and nothing after it')
    idle()
end

describe('4. audio: where the music is in the track')
do
    calm()
    idle()
    BR.Clock.synced, BR.Clock.offset = true, 500.0
    local now = BR.Clock.now()
    record({ src = 31, id = A, x = 1.0, tStart = now - 1000, tSent = now - 1000 })
    tick(0)
    local a = lastAudio()
    ok(a and #a.tracks == 1 and near(a.tracks[1].pos, BR.Clock.now() - (now - 1000)),
        'synced: pos is BR.Clock.now() - tStart', a and a.tracks[1] and a.tracks[1].pos)

    BR.Clock.synced, BR.Clock.offset = false, 0.0
    idle()
    record({ src = 32, id = A, x = 1.0, tStart = 50000, tSent = 53000 })
    fakeTime = fakeTime + 400
    BR.Loop.step(BR.Loop.TICK)
    a = lastAudio()
    ok(a and #a.tracks == 1 and near(a.tracks[1].pos, 3400),
        'unsynced: pos is tSent - tStart plus the time since it arrived',
        a and a.tracks[1] and a.tracks[1].pos)
    idle()
end

describe('4. audio: the own stopped record is silent at once')
do
    calm()
    idle()
    setWheel({ A })
    record({ id = A, x = 5.0 })
    tick(); tick()
    local a = lastAudio()
    ok(a and #a.tracks == 1 and a.tracks[1].src == 7, 'the own dance is heard')
    input.x = 1.0
    tick()
    a = lastAudio()
    ok(count(BR.Net.EMOTE_STOP) == 1 and a and #a.tracks == 0,
        'moving stops it, and the same pass sends no track for it -- before any tEnd returns')
    idle()
end

describe('4. audio: a spectator hears what they watch')
do
    calm()
    idle()
    watch = vector3(505.0, 0.0, 0.0)
    record({ src = 41, id = A, x = 500.0 })
    tick()
    local a = lastAudio()
    ok(a and #a.tracks == 1 and near(a.tracks[1].g, 0.75),
        'watchPoint 5 m from the dancer, ped 500 m away: g = 0.75',
        a and a.tracks[1] and a.tracks[1].g)
    watch = nil
    tick()
    a = lastAudio()
    ok(a and #a.tracks == 0, 'and without a session the ped is the listener again')
    idle()
end

-- ════════════════════════════════════════════════════════════════════════════
-- 5. THE GATE, CLOSED
-- ════════════════════════════════════════════════════════════════════════════

describe('5. gate: closed means none of it')
do
    calm()
    idle()
    gateClosed()
    setWheel({ A })
    key(true)
    ok(not BR.EmoteWheel.isOpen(), 'no wheel')
    local base = audioCount()
    record({ src = 51, id = A, x = 1.0 })
    record({ id = A })
    ok(next(BR.Emotes.records()) == nil, 'records are ignored')
    tick(); tick()
    ok(audioCount() == base, 'no audio is sent')
    ok(BR.Emotes.request(A) == false and #plays() == 0, 'request() sends nothing')
    ok(BR.Emotes.blocked() == 'gate', "blocked() says 'gate'", BR.Emotes.blocked())
    local lines = #logged
    rawCmds.bremote(0, {})
    ok(logged[lines + 1] and logged[lines + 1]:find('bremote: emotes are off', 1, true) ~= nil,
        'the raw bremote handler prints the off line', logged[lines + 1])
    local rows = BR.Emotes.nativeCheck()
    ok(#rows == 1 and rows[1].name == 'dances' and rows[1].ok == true,
        'nativeCheck is one ok row saying emotes are off')

    -- THE DEV GATE IS STILL IN FRONT OF bremote: it is not exempt (owner: the
    -- audition tool plays any clip on a ped others can see).
    lines = #logged
    wrappedCmds.bremote(0, {})
    ok(logged[lines + 1] and logged[lines + 1]:find('dev-mode only', 1, true) ~= nil,
        'with dev mode off the devgate-wrapped bremote refuses before the handler',
        logged[lines + 1])
    local dg = readFile(ROOT .. 'br_lib/shared/devgate.lua')
    local exempt = dg:match('\nlocal EXEMPT = (%b{})') or ''
    ok(exempt ~= '' and not exempt:find('bremote%s*='),
        'and devgate.lua does not exempt bremote', exempt)
    calm()
end

-- ════════════════════════════════════════════════════════════════════════════
-- 6. bremote
-- ════════════════════════════════════════════════════════════════════════════

describe('6. bremote: an audition is local only')
do
    calm()
    idle()
    local before = #tasks
    rawCmds.bremote(0, { 'anim@audition', 'loop_a' })
    tick(); tick()
    ok(#tasks == before + 1 and tasks[#tasks].dict == 'anim@audition'
            and tasks[#tasks].clip == 'loop_a' and tasks[#tasks].flag == 1,
        'an audition tasks the clip with flag 1')
    ok(#sent == 0, 'and sends no server event at all', #sent)
    local stopsBefore = #stops
    rawCmds.bremote(0, { 'stop' })
    tick()
    ok(#stops == stopsBefore + 1, '`bremote stop` ends it')
    ok(#sent == 0, 'still without a server event')

    rawCmds.bremote(0, { 'anim@audition', 'loop_a', '2' })
    tick(); tick()
    ok(tasks[#tasks].flag == 2, 'a flag may be given')
    stopsBefore = #stops
    input.x = 1.0
    tick()
    ok(#stops == stopsBefore + 1 and #sent == 0, 'the same cancels end an audition, and nothing is sent')
    calm()
    world.aiming = true
    before = #tasks
    rawCmds.bremote(0, { 'anim@audition', 'loop_a' })
    tick(); tick()
    ok(#tasks == before, 'an audition is refused where a dance could not start')
    calm()
    local lines = #logged
    rawCmds.bremote(0, {})
    local listed = 0
    for i = lines + 1, #logged do
        if logged[i]:find('emote_', 1, true) and logged[i]:find('ms', 1, true) then listed = listed + 1 end
    end
    ok(listed == #ORDER, 'bare `bremote` lists every row', listed)
    idle()
end

-- ════════════════════════════════════════════════════════════════════════════
-- 7. nativeCheck
-- ════════════════════════════════════════════════════════════════════════════

describe('7. nativeCheck: one row per dance')
do
    calm()
    local rows = BR.Emotes.nativeCheck()
    ok(#rows == #ORDER and #rows == 16, 'sixteen rows', #rows)
    local named, allOk = true, true
    for i, r in ipairs(rows) do
        if r.name ~= 'dance: ' .. ORDER[i] then named = false end
        if r.ok ~= true then allOk = false end
    end
    ok(named, "named 'dance: <id>' in catalogue order")
    ok(allOk, 'every clip found is ok')
    ok(rows[1].detail:find('track MISSING (plays silent)', 1, true) ~= nil and rows[1].ok == true,
        'a missing track file is reported and is still ok -- the dance plays silent',
        rows[1].detail)
    ok(rows[1].detail:find('4.50s clip, plays 12s', 1, true) ~= nil,
        'the detail carries the clip length and the play time', rows[1].detail)

    files['ui/' .. BR.Emotes.row(ORDER[2]).track] = 'OggS'
    missingClip[BR.Emotes.row(ORDER[3]).clip] = true
    local saved = BR.Emotes.row(ORDER[4]).track
    BR.Emotes.row(ORDER[4]).track = nil
    rows = BR.Emotes.nativeCheck()
    BR.Emotes.row(ORDER[4]).track = saved
    missingClip[BR.Emotes.row(ORDER[3]).clip] = nil
    files = {}
    ok(rows[2].ok and rows[2].detail:find('track present', 1, true) ~= nil,
        'a track in the bundle reads present', rows[2].detail)
    ok(rows[3].ok == false, 'a clip the dictionary lacks is a FAILED row', rows[3].detail)
    ok(rows[4].ok and rows[4].detail:find('no track (plays silent)', 1, true) ~= nil,
        'a row with no track says so', rows[4].detail)

    local natives = readFile(ROOT .. 'br_core/client/natives.lua')
    local body = natives:match('\nfunction BR%.Native%.check%(%)(.-)\nend\n') or ''
    ok(body:find('BR.Emotes.nativeCheck()', 1, true) ~= nil,
        'BR.Native.check calls BR.Emotes.nativeCheck()')
    ok(natives:find("\nAddEventHandler('br:map:fullscreen'", 1, true) ~= nil,
        "natives.lua handles 'br:map:fullscreen'")
    -- EVERY PED NATIVE NEW TO THE TREE HAS A PRESENCE ROW, so a build missing
    -- one says so on /brnativecheck instead of throwing inside canStart.
    local missing = {}
    for _, n in ipairs({ 'IsPedSwimming', 'IsPedSwimmingUnderWater', 'IsPedFalling',
                         'IsPedClimbing', 'IsPedVaulting', 'IsPedRagdoll',
                         'IsPedInParachuteFreeFall', 'IsPedShooting', 'IsPedInMeleeCombat',
                         'GetEntitySpeed', 'GetVehiclePedIsTryingToEnter' }) do
        if not body:find("'" .. n .. "'", 1, true) then missing[#missing + 1] = n end
    end
    ok(#missing == 0, 'BR.Native.check probes every ped native the emotes added',
        table.concat(missing, ','))
end

-- ════════════════════════════════════════════════════════════════════════════
-- 9. brseason (#388): A SWITCH MID-SESSION, ON THIS CLIENT
-- ════════════════════════════════════════════════════════════════════════════

-- The dev-mode `brseason` moves the season the server replicates while this
-- client is running, and tells it so (BR.Net.SEASON_SWITCHED). Nothing here
-- may take the season off that message: every door answers the replicated
-- value, and br_core's client/season.lua raises `br:season:changed` only once
-- that value has landed. Both orders are walked -- the message first, then the
-- value first -- each way across the emotes row's edge.
describe('9. brseason: every client door follows a switch')
do
    local function changes()
        local n = 0
        for _, e in ipairs(events) do if e.name == 'br:season:changed' then n = n + 1 end end
        return n
    end
    local function told(season)
        return ('[br_core] brseason: Will (#3) switched this server to Season %d'):format(season)
    end
    local function logs(line)
        for i = #logged, 1, -1 do if logged[i] == line then return true end end
        return false
    end

    calm()
    idle()
    slow()
    setWheel({ A })
    key(true)
    ok(BR.EmoteWheel.isOpen(), ('Season %d: the wheel opens'):format(FROM))
    fakeTime = fakeTime + 300
    key(false)
    record({ id = A })
    tick(); tick()
    ok(playing ~= nil, 'and an own record is playing')
    local base, ui, pushes, asks, stopsBefore = changes(), uiTold(), keyPushes, count(BR.Net.MARKET_STATE), #stops

    -- THE MESSAGE BEFORE THE VALUE: printed, and nothing moves.
    fire(BR.Net.SEASON_SWITCHED, { season = OFF, from = FROM, by = 'Will (#3)' })
    ok(logs(told(OFF)), 'the F8 says who switched', logged[#logged])
    ok(changes() == base and BR.Season.has('emotes') == true and playing ~= nil,
        'and until the value lands, nothing is re-read and the dance plays on')

    -- THE VALUE LANDS.
    gateClosed()
    tick()
    ok(playing == nil and #stops == stopsBefore + 1, 'the next TICK takes the clip off the ped')
    slow()
    ok(changes() == base + 1, 'the next SLOW pass raises br:season:changed, once', changes() - base)
    ok(uiTold() == ui + 1 and keyPushes == pushes + 1 and count(BR.Net.MARKET_STATE) == asks + 1,
        'and the gate pass sees the flip: br_ui told, the keys re-pushed, the market asked once')
    ok(next(BR.Emotes.records()) == nil, 'every record is dropped')
    key(true)
    ok(not BR.EmoteWheel.isOpen(), ('Season %d: the wheel does not open'):format(OFF))
    key(false)
    ok(BR.Emotes.request(A) == false and BR.Emotes.blocked() == 'gate', 'request() and blocked() answer the gate')
    record({ id = A })
    ok(next(BR.Emotes.records()) == nil, 'and a record that arrives now is ignored')
    slow()
    ok(changes() == base + 1, 'a later pass raises nothing more')

    -- THE VALUE BEFORE THE MESSAGE: raised as the message arrives.
    gateOpen()
    fire(BR.Net.SEASON_SWITCHED, { season = FROM, from = OFF, by = 'Will (#3)' })
    ok(logs(told(FROM)) and changes() == base + 2,
        'with the value already landed, the message itself raises br:season:changed')
    local maps = mapGatedCalls
    slow()
    ok(changes() == base + 2, 'and the pass after does not raise it twice')
    ok(mapGatedCalls == maps + 1 and keyPushes == pushes + 2, 'the gate pass maps the row and re-pushes the keys')
    setWheel({ A })
    key(true)
    ok(BR.EmoteWheel.isOpen(), ('Season %d again: the wheel opens'):format(FROM))
    fakeTime = fakeTime + 300
    key(false)
    calm()
end

-- ════════════════════════════════════════════════════════════════════════════
-- 8. SCOPE
-- ════════════════════════════════════════════════════════════════════════════

describe('8. scope: the emote files read no player out of scope')
do
    for _, f in ipairs({ 'br_core/client/emotes.lua', 'br_core/client/emotewheel.lua' }) do
        local src = readFile(ROOT .. f)
        ok(src ~= '', f .. ' is readable')
        for _, banned in ipairs({ 'GetActivePlayers', 'GetPlayerFromServerId', 'GetPlayerPed(' }) do
            ok(src:find(banned, 1, true) == nil, f .. ' never names ' .. banned)
        end
        local code = src:gsub('%-%-[^\n]*', '')
        ok(code:find('ClearPedTasks', 1, true) == nil, f .. ' never calls ClearPedTasks')
    end
end

-- Nothing above may have left a loop callback throwing.
local threw = {}
for _, l in ipairs(logged) do
    if l:find('loop callback "emotes', 1, true) then threw[#threw + 1] = l end
end
describe('loops')
ok(#threw == 0, 'no emotes loop callback threw', threw[1])

restoreSeason()
realPrint(('%s%d passed, %d failed (Season %s)%s'):format(fail == 0 and '\27[32m' or '\27[31m',
    pass, fail, RUN_SEASON or 'unset', '\27[0m'))
os.exit(fail == 0 and 0 or 1)
