-- Unit tests for br_ui's half of the emote system (#215, "Scope v2").
--
-- Owner, 2026-10-02: "Everything is devMode-required behind one config line,
-- so removing that line makes it production-ready in the same PR." And of the
-- Market: "The market manages them: equip, unequip, and swap one for another
-- when more than 8 are owned."
--
-- ═══ WHAT THIS LOADS FOR REAL ═══
--
-- br_lib's enums, protocol, devgate, config/market and config/emotes, then the
-- REAL br_ui/client/market.lua, with RegisterNUICallback, TriggerServerEvent
-- and TriggerEvent captured. So every assertion below is about what the page
-- is actually sent and what the server is actually asked, not about a stub.
--
-- ═══ THE ONE-LINE DISCIPLINE ═══
--
-- config/emotes.lua is loaded through `loadEmotesConfig`, which -- when
-- BR_EMOTES_LINE_DELETED=1 -- removes the exact line `    requireDevMode =
-- true,` first. tools/verify.sh runs this suite both ways. A gate-closed case
-- calls gateClosed(), which forces the line back on AND turns dev mode off; a
-- gate-open case calls gateOpen(), which turns dev mode on. Each group puts
-- requireDevMode back to whatever the file loaded with, so no assertion
-- depends on the line being in the file -- deleting it is a change this suite
-- has already run. Group 0 runs only with the line deleted and proves the
-- open behaviour with dev mode OFF and nothing forced.
--
-- ═══ WHAT IT DELIBERATELY DOES NOT TEST ═══
--
-- The page (ui-src: scripts/test-music.mjs and check-ui rule R24), the server
-- (tools/test_emotes.lua) and the wheel and playback (tools/test_emotes_client.lua).

local RES = 'resources/[fivem-royale]/'
local LINE_DELETED = os.getenv('BR_EMOTES_LINE_DELETED') == '1'

local realPrint = print
local printed = {}
function print(...)
    local parts = {}
    for i = 1, select('#', ...) do parts[i] = tostring((select(i, ...))) end
    printed[#printed + 1] = table.concat(parts, '\t')
end

-- ---------------------------------------------------------------------------
-- Natives and engine stubs
-- ---------------------------------------------------------------------------

-- DEV MODE IS A CONVAR, read at call time by BR.Dev.on() -- so this switch is
-- the whole of "is this a dev box" for the suite.
local devOn = false
function GetConvar(name, dflt)
    if name == 'sv_devMode' or name == 'br_devMode' then return devOn and 'true' or 'false' end
    return dflt
end
function GetCurrentResourceName() return 'br_ui' end
function GetGameTimer() return 0 end

local handlers, nuiCbs, toServer, toLocal, commands = {}, {}, {}, {}, {}
function AddEventHandler(name, fn)
    handlers[name] = handlers[name] or {}
    handlers[name][#handlers[name] + 1] = fn
end
function RegisterNetEvent() end
function RegisterNUICallback(name, fn) nuiCbs[name] = fn end
function TriggerServerEvent(name, ...) toServer[#toServer + 1] = { name = name, args = { ... } } end
function TriggerEvent(name, ...) toLocal[#toLocal + 1] = { name = name, args = { ... } } end
-- Installed BEFORE devgate.lua, which captures it as the raw door. This suite
-- tests no command, so a no-op capture is all it needs.
function RegisterCommand(name, fn) commands[name] = fn end

local function fire(name, ...)
    for _, fn in ipairs(handlers[name] or {}) do fn(...) end
end

-- ---------------------------------------------------------------------------
-- Loading
-- ---------------------------------------------------------------------------

local function loadAt(f)
    local chunk, err = loadfile(RES .. f)
    if not chunk then
        realPrint('\27[31mload error\27[0m ' .. f .. ': ' .. tostring(err))
        os.exit(1)
    end
    chunk()
end

--- config/emotes.lua, optionally with the owner's one line deleted.
local function loadEmotesConfig()
    local path = RES .. 'br_lib/config/emotes.lua'
    local fh = assert(io.open(path, 'rb'))
    local src = fh:read('a')
    fh:close()
    if LINE_DELETED then
        local n
        src, n = src:gsub('\n    requireDevMode = true,\n', '\n', 1)
        if n ~= 1 then
            realPrint('\27[31mFAIL\27[0m BR_EMOTES_LINE_DELETED=1 but the one line was not found exactly once')
            os.exit(1)
        end
    end
    local chunk, err = load(src, '@br_lib/config/emotes.lua')
    if not chunk then
        realPrint('\27[31mload error\27[0m config/emotes.lua: ' .. tostring(err))
        os.exit(1)
    end
    chunk()
end

-- br_ui's own manifest order: devgate first, then enums and protocol, then the
-- client scripts with config/market.lua and config/emotes.lua at their head.
loadAt('br_lib/shared/devgate.lua')
loadAt('br_lib/shared/enums.lua')
loadAt('br_lib/shared/protocol.lua')
loadAt('br_lib/config/market.lua')
loadEmotesConfig()
loadAt('br_ui/client/market.lua')

local LOADED_LINE = BR.Config.Emotes.requireDevMode

-- ---------------------------------------------------------------------------
-- Harness
-- ---------------------------------------------------------------------------

local pass, failn, group = 0, 0, ''
local function describe(n) group = n end
local function ok(cond, name, detail)
    if cond then pass = pass + 1 else
        failn = failn + 1
        realPrint('\27[31mFAIL\27[0m ' .. group .. ' > ' .. name ..
            (detail and ('\n       ' .. tostring(detail)) or ''))
    end
end

local function gateClosed() BR.Config.Emotes.requireDevMode = true; devOn = false end
local function gateOpen() devOn = true end
local function restore() BR.Config.Emotes.requireDevMode = LOADED_LINE; devOn = false end
local function reset() toServer, toLocal = {}, {} end

--- The most recent payload sent to the page under `kind`, or nil.
local function lastLocal(kind)
    for i = #toLocal, 1, -1 do
        local e = toLocal[i]
        if e.name == 'br:ui:sendLocal' and e.args[1] == kind then return e.args[2] end
    end
    return nil
end

local function emoteItems(grid)
    local out = {}
    for _, it in ipairs(grid and grid.items or {}) do
        if it.kind == 'emote' then out[#out + 1] = it end
    end
    return out
end

local function itemById(grid, id)
    for _, it in ipairs(grid and grid.items or {}) do if it.id == id then return it end end
    return nil
end

--- Call a NUI callback; returns what it answered (or nil) and whether it threw.
local function callCb(name, data)
    local answered = nil
    local okCall, err = pcall(nuiCbs[name], data, function(r) answered = r end)
    return answered, okCall, err
end

local function serverSent(name)
    local out = {}
    for _, e in ipairs(toServer) do if e.name == name then out[#out + 1] = e.args[1] end end
    return out
end

local function eightEmpty() return { '', '', '', '', '', '', '', '' } end

-- ---------------------------------------------------------------------------
-- 0. THE LINE DELETED: open with dev mode OFF and nothing forced
-- ---------------------------------------------------------------------------

if LINE_DELETED then
    describe('0. the one line deleted')
    devOn = false
    reset()
    ok(BR.Config.Emotes.requireDevMode == nil, 'the loaded config has no requireDevMode')
    ok(BR.Emotes.enabled() == true, 'enabled() is true with dev mode off')
    fire(BR.Net.MARKET_STATE, { balance = 0, owned = {}, equipped = {}, emotes = eightEmpty() })
    local e = lastLocal(BR.Nui.EMOTES)
    ok(e ~= nil and e.on == true, 'EMOTES {on=true} is sent', e and tostring(e.on))
    ok(#emoteItems(lastLocal(BR.Nui.MARKET)) == #BR.Config.Emotes.order,
        'the emote rows are on the grid', #emoteItems(lastLocal(BR.Nui.MARKET)))
    reset()
    local answered = callCb(BR.NuiCb.MARKET_UNEQUIP, { id = 'emote_shuffle' })
    ok(#serverSent(BR.Net.MARKET_UNEQUIP) == 1 and answered and answered.ok == true,
        'MARKET_UNEQUIP forwards')
    restore()
end

-- ---------------------------------------------------------------------------
-- 1. Gate closed
-- ---------------------------------------------------------------------------

describe('1. gate closed')
do
    gateClosed()
    ok(BR.Emotes.enabled() == false, 'enabled() is false (line forced, dev off)')
    reset()
    fire(BR.Net.MARKET_STATE, { balance = 500, owned = { 'chute_azure' }, equipped = {} })
    local grid = lastLocal(BR.Nui.MARKET)
    ok(grid ~= nil, 'a grid is pushed')
    ok(#emoteItems(grid) == 0, 'no emote items', #emoteItems(grid))
    local e = lastLocal(BR.Nui.EMOTES)
    ok(e ~= nil and e.on == false, 'EMOTES {on=false} is sent with the grid')

    -- EMOTES FOLLOWS THE GRID, so a gate flip reaches the page by the grid's road.
    local iMarket, iEmotes = nil, nil
    for i, ev in ipairs(toLocal) do
        if ev.name == 'br:ui:sendLocal' and ev.args[1] == BR.Nui.MARKET then iMarket = i end
        if ev.name == 'br:ui:sendLocal' and ev.args[1] == BR.Nui.EMOTES then iEmotes = i end
    end
    ok(iMarket ~= nil and iEmotes ~= nil and iEmotes > iMarket,
        'EMOTES is sent after the grid (pushEmotes at the end of push)')

    reset()
    local answered, okCall = callCb(BR.NuiCb.MARKET_UNEQUIP, { id = 'emote_shuffle' })
    ok(okCall and #serverSent(BR.Net.MARKET_UNEQUIP) == 0, 'MARKET_UNEQUIP forwards nothing')
    ok(answered ~= nil and answered.ok == true, 'MARKET_UNEQUIP still answers cb({ok=true})')

    reset()
    answered, okCall = callCb(BR.NuiCb.MARKET_BUY, { id = 'emote_shuffle' })
    ok(okCall and #serverSent(BR.Net.MARKET_BUY) == 0, 'MARKET_BUY of an emote forwards nothing')
    ok(answered ~= nil and answered.ok == true, 'MARKET_BUY of an emote still answers')

    reset()
    answered, okCall = callCb(BR.NuiCb.MARKET_EQUIP, { id = 'emote_shuffle' })
    ok(okCall and #serverSent(BR.Net.MARKET_EQUIP) == 0, 'MARKET_EQUIP of an emote forwards nothing')
    ok(answered ~= nil and answered.ok == true, 'MARKET_EQUIP of an emote still answers')

    -- A NON-EMOTE IS UNTOUCHED BY THE GATE.
    reset()
    answered = callCb(BR.NuiCb.MARKET_BUY, { id = 'chute_azure' })
    local buys = serverSent(BR.Net.MARKET_BUY)
    ok(#buys == 1 and buys[1].id == 'chute_azure', 'MARKET_BUY of a chute still forwards')
    ok(answered ~= nil and answered.ok == true, 'and answers')
    reset()
    callCb(BR.NuiCb.MARKET_EQUIP, { id = 'chute_azure' })
    local eqs = serverSent(BR.Net.MARKET_EQUIP)
    ok(#eqs == 1 and eqs[1].id == 'chute_azure' and eqs[1].replace == nil,
        'MARKET_EQUIP of a chute still forwards, with no replace')
    reset()
    callCb(BR.NuiCb.MARKET_BUY, { id = 'no_such_item' })
    ok(#serverSent(BR.Net.MARKET_BUY) == 1, 'an unknown id still forwards (the server refuses it)')
    reset()
    local _, okNil = callCb(BR.NuiCb.MARKET_BUY, nil)
    ok(okNil and #serverSent(BR.Net.MARKET_BUY) == 1, 'a nil payload does not throw')

    -- THE SERVER SENDS `emotes` ONLY WHILE OPEN; one that arrived anyway draws nothing.
    reset()
    fire(BR.Net.MARKET_STATE, { balance = 0, owned = { 'emote_shuffle' }, equipped = {},
        emotes = { 'emote_shuffle', '', '', '', '', '', '', '' } })
    ok(#emoteItems(lastLocal(BR.Nui.MARKET)) == 0, 'a stray emotes field still draws no emote item')
    restore()
end

-- ---------------------------------------------------------------------------
-- 2. Gate open
-- ---------------------------------------------------------------------------

describe('2. gate open')
do
    gateOpen()
    ok(BR.Emotes.enabled() == true, 'enabled() is true (dev on)')
    reset()
    fire(BR.Net.MARKET_STATE, { balance = 1000, owned = { 'emote_shuffle', 'emote_jumper' },
        equipped = {}, emotes = { 'emote_shuffle', '', 7, 'emote_jumper', '', '', '', '' } })
    local grid = lastLocal(BR.Nui.MARKET)
    local emotes = emoteItems(grid)
    ok(#emotes == 16 and #emotes == #BR.Config.Emotes.order, '16 emote items', #emotes)
    local inOrder = true
    for i, id in ipairs(BR.Config.Emotes.order) do
        if not emotes[i] or emotes[i].id ~= id then inOrder = false end
    end
    ok(inOrder, 'in the seam order')

    local sh = itemById(grid, 'emote_shuffle')
    ok(sh ~= nil and sh.slot == 1, 'emote_shuffle is slot 1', sh and tostring(sh.slot))
    ok(sh ~= nil and sh.equipped == true, 'equipped = true')
    ok(sh ~= nil and sh.owned == true, 'owned = true')
    ok(sh ~= nil and sh.kind == 'emote' and sh.sub == 'Dance' and sh.price == 250,
        "kind 'emote', sub 'Dance', 250 Volts")
    ok(sh ~= nil and sh.season == 'Founders' and sh.locked == false,
        'season name, and not locked while the season sells')
    local ju = itemById(grid, 'emote_jumper')
    ok(ju ~= nil and ju.slot == 4 and ju.equipped == true, 'emote_jumper is slot 4 (holes kept)')
    local gr = itemById(grid, 'emote_club_groove')
    ok(gr ~= nil and gr.slot == nil and gr.equipped == false and gr.owned == false,
        'an unowned dance has no slot and is neither equipped nor owned')
    local slotted = 0
    for _, it in ipairs(emotes) do if it.slot ~= nil then slotted = slotted + 1 end end
    ok(slotted == 2, "a non-string entry (7) and '' fill no slot", slotted)

    -- A DUPLICATE THE SERVER SHOULD NEVER SEND still draws one stable slot:
    -- the lowest, every time, not whichever pairs() visits last.
    reset()
    fire(BR.Net.MARKET_STATE, { balance = 1000, owned = { 'emote_shuffle' }, equipped = {},
        emotes = { '', '', '', '', '', '', 'emote_shuffle', '' } })
    local seven = itemById(lastLocal(BR.Nui.MARKET), 'emote_shuffle')
    ok(seven ~= nil and seven.slot == 7, 'a dance in segment 7 is slot 7', seven and tostring(seven.slot))
    reset()
    fire(BR.Net.MARKET_STATE, { balance = 1000, owned = { 'emote_shuffle' }, equipped = {},
        emotes = { '', 'emote_shuffle', '', '', '', 'emote_shuffle', '', 'emote_shuffle' } })
    local dup = itemById(lastLocal(BR.Nui.MARKET), 'emote_shuffle')
    ok(dup ~= nil and dup.slot == 2, 'a duplicated dance draws its lowest segment', dup and tostring(dup.slot))
    -- Put the state the rest of this group asserts against back.
    fire(BR.Net.MARKET_STATE, { balance = 1000, owned = { 'emote_shuffle', 'emote_jumper' },
        equipped = {}, emotes = { 'emote_shuffle', '', 7, 'emote_jumper', '', '', '', '' } })

    local e = lastLocal(BR.Nui.EMOTES)
    ok(e ~= nil and e.on == true, 'EMOTES {on=true}')

    -- SYNTHETIC ROWS STAY AFTER THE DANCES.
    local lastEmote, firstSynth = 0, nil
    for i, it in ipairs(grid.items) do
        if it.kind == 'emote' then lastEmote = i end
        if it.id == 'ped_juggalo' and not firstSynth then firstSynth = i end
    end
    ok(firstSynth ~= nil and firstSynth > lastEmote, 'the emote items come before SYNTHETIC')

    -- REPLACE IS FORWARDED ONLY AS A NON-EMPTY STRING.
    local cases = {
        { { id = 'emote_jumper' }, nil, 'no replace' },
        { { id = 'emote_jumper', replace = 'emote_shuffle' }, 'emote_shuffle', 'a string replace' },
        { { id = 'emote_jumper', replace = '' }, nil, "replace ''" },
        { { id = 'emote_jumper', replace = 5 }, nil, 'replace 5' },
        { { id = 'emote_jumper', replace = { 'x' } }, nil, 'replace a table' },
    }
    for _, c in ipairs(cases) do
        reset()
        local answered = callCb(BR.NuiCb.MARKET_EQUIP, c[1])
        local sent = serverSent(BR.Net.MARKET_EQUIP)
        ok(#sent == 1 and sent[1].id == 'emote_jumper' and sent[1].replace == c[2],
            'MARKET_EQUIP forwards ' .. c[3] .. ' as ' .. tostring(c[2]),
            sent[1] and tostring(sent[1].replace))
        ok(answered ~= nil and answered.ok == true, 'and answers (' .. c[3] .. ')')
    end

    reset()
    local answered = callCb(BR.NuiCb.MARKET_UNEQUIP, { id = 'emote_shuffle' })
    local un = serverSent(BR.Net.MARKET_UNEQUIP)
    ok(#un == 1 and un[1].id == 'emote_shuffle', 'UNEQUIP forwards {id}')
    ok(answered ~= nil and answered.ok == true, 'UNEQUIP answers')
    reset()
    callCb(BR.NuiCb.MARKET_UNEQUIP, nil)
    un = serverSent(BR.Net.MARKET_UNEQUIP)
    ok(#un == 1 and un[1].id == '', "UNEQUIP with no payload forwards id '' (the server refuses it)")

    reset()
    callCb(BR.NuiCb.MARKET_BUY, { id = 'emote_club_groove' })
    local buys = serverSent(BR.Net.MARKET_BUY)
    ok(#buys == 1 and buys[1].id == 'emote_club_groove', 'MARKET_BUY of an emote forwards')
    restore()
end

-- ---------------------------------------------------------------------------
-- 3. Flip
-- ---------------------------------------------------------------------------

describe('3. flip')
do
    gateOpen()
    reset()
    fire(BR.Net.MARKET_STATE, { balance = 0, owned = { 'emote_shuffle' }, equipped = {},
        emotes = { 'emote_shuffle', '', '', '', '', '', '', '' } })
    ok(#emoteItems(lastLocal(BR.Nui.MARKET)) == 16, 'open: the rows are there')
    ok(lastLocal(BR.Nui.EMOTES).on == true, 'open: EMOTES on')

    -- br_core's SLOW 'emotes.gate' asks the server again on a flip; the server
    -- answers without `emotes` and without emote ids in `owned`.
    gateClosed()
    reset()
    fire(BR.Net.MARKET_STATE, { balance = 0, owned = {}, equipped = {} })
    local e = lastLocal(BR.Nui.EMOTES)
    ok(e ~= nil and e.on == false, 'closed: EMOTES {on=false} is re-sent')
    ok(#emoteItems(lastLocal(BR.Nui.MARKET)) == 0, 'closed: the emote rows are dropped')

    -- AND BACK: the wheel mirror was emptied by the closed state, so it comes
    -- back only from the next state the server sends.
    gateOpen()
    reset()
    BR.Market.push()
    local sh = itemById(lastLocal(BR.Nui.MARKET), 'emote_shuffle')
    ok(sh ~= nil and sh.slot == nil, 'reopened before a new state: no stale slot')
    ok(lastLocal(BR.Nui.EMOTES).on == true, 'reopened: EMOTES on')
    restore()
end

-- ---------------------------------------------------------------------------
-- 4. Robustness: a BR.Emotes stub with no config (the test_client case)
-- ---------------------------------------------------------------------------

describe('4. robustness')
do
    local savedEmotes, savedConfig = BR.Emotes, BR.Config.Emotes
    BR.Emotes = { enabled = function() return true end }
    BR.Config.Emotes = nil
    reset()
    local okPush, err = pcall(BR.Market.push)
    ok(okPush, 'catalogue() does not throw with BR.Config.Emotes nil', err)
    local e = lastLocal(BR.Nui.EMOTES)
    ok(e ~= nil and e.on == false, 'and reports the gate off')
    ok(#emoteItems(lastLocal(BR.Nui.MARKET)) == 0, 'and draws no emote item')
    local okState = pcall(fire, BR.Net.MARKET_STATE,
        { balance = 0, owned = {}, equipped = {}, emotes = 'nonsense' })
    ok(okState, 'a MARKET_STATE with a non-table emotes field does not throw')
    reset()
    local answered, okCb = callCb(BR.NuiCb.MARKET_UNEQUIP, { id = 'emote_shuffle' })
    ok(okCb and answered and answered.ok == true and #serverSent(BR.Net.MARKET_UNEQUIP) == 0,
        'MARKET_UNEQUIP with no config forwards nothing and answers')
    BR.Emotes = nil
    reset()
    okPush = pcall(BR.Market.push)
    ok(okPush and lastLocal(BR.Nui.EMOTES).on == false, 'BR.Emotes nil: push works, gate off')
    BR.Emotes, BR.Config.Emotes = savedEmotes, savedConfig
end

-- ---------------------------------------------------------------------------
-- 5. The non-emote grid is unchanged
-- ---------------------------------------------------------------------------

describe('5. the rest of the grid')
do
    for _, open in ipairs({ false, true }) do
        if open then gateOpen() else gateClosed() end
        reset()
        fire(BR.Net.MARKET_STATE, { balance = 0, owned = {}, equipped = { trail = 'trail_none' } })
        local grid = lastLocal(BR.Nui.MARKET)
        local trails, none = 0, false
        for _, it in ipairs(grid.items) do
            if it.kind == 'trail' then trails = trails + 1 end
            if it.id == 'trail_none' then none = true end
        end
        local label = open and 'open' or 'closed'
        ok(trails == 6, label .. ': 6 trails', trails)
        ok(not none, label .. ': no trail_none tile')
        local inSeason = false
        for _, s in ipairs(BR.Config.Market.seasons) do
            for _, it in ipairs(s.items) do if it.kind == 'emote' then inSeason = true end end
        end
        ok(not inSeason, label .. ': no emote in any season.items')
        restore()
    end
end

-- ---------------------------------------------------------------------------
-- 6. The manifest and the fullscreen-map event
-- ---------------------------------------------------------------------------

describe('6. manifest and pause')
do
    local function readAll(p)
        local fh = assert(io.open(p, 'rb'))
        local s = fh:read('a')
        fh:close()
        return s
    end
    local man = readAll(RES .. 'br_ui/fxmanifest.lua')
    local iMarket = man:find("'@br_lib/config/market.lua'", 1, true)
    local iEmotes = man:find("'@br_lib/config/emotes.lua'", 1, true)
    ok(iMarket and iEmotes and iEmotes > iMarket, 'br_ui loads config/emotes.lua after config/market.lua')
    ok(man:find("'ui/emotes/*.ogg'", 1, true) ~= nil, "files{} lists 'ui/emotes/*.ogg'")
    local pause = readAll(RES .. 'br_ui/client/pause.lua')
    local _, nOn = pause:gsub("TriggerEvent%('br:map:fullscreen', true%)", '')
    local _, nOff = pause:gsub("TriggerEvent%('br:map:fullscreen', false%)", '')
    ok(nOn == 1 and nOff == 2, "pause.lua raises 'br:map:fullscreen' once on and twice off",
        nOn .. '/' .. nOff)
    -- Each raise sits on the line after the flag it mirrors.
    local adjacent = 0
    for flag, ev in pause:gmatch("BR%.Pause%.fullscreenMap = (%a+)\n%s*TriggerEvent%('br:map:fullscreen', (%a+)%)") do
        if flag == ev then adjacent = adjacent + 1 end
    end
    ok(adjacent == 3, 'every raise follows its BR.Pause.fullscreenMap write', adjacent)
end

if failn > 0 then
    realPrint(('\27[31m%d failed\27[0m, %d passed'):format(failn, pass))
    os.exit(1)
end
realPrint(('\27[32m%d passed\27[0m'):format(pass))
