-- Unit tests for br_ui's half of the emote system (#215, "Scope v2").
--
-- Emotes are a Season 2 feature (#388; owner, 2026-10-04), gated by
-- BR.Season.has('emotes'). And of the Market (owner, 2026-10-02): "The market
-- manages them: equip, unequip, and swap one for another when more than 8 are
-- owned."
--
-- ═══ WHAT THIS LOADS FOR REAL ═══
--
-- br_lib's enums, protocol, devgate, config/market, config/emotes, the season
-- module and its list, then the REAL br_ui/client/market.lua, with RegisterNUICallback, TriggerServerEvent
-- and TriggerEvent captured. So every assertion below is about what the page
-- is actually sent and what the server is actually asked, not about a stub.
--
-- ═══ THE SEASON DISCIPLINE ═══
--
-- br_ui is a client resource: it reads br_seasonServed, the season br_core's
-- server booted with and replicated, at call time. This file sets it the way
-- the server would have -- BR_SEASON resolved by the module's own rule, the
-- latest when unset -- and tools/verify.sh runs it with no BR_SEASON, then at
-- the season before the emotes row's `from` (off) and at `from` (on). A
-- gate-closed case calls gateClosed() (the season before `from`), a gate-open
-- case gateOpen() (`from`), and restore() puts the run's season back, so no
-- assertion depends on the run. Dev mode stays OFF throughout. Group 0 asserts
-- whatever the run's own season means.
--
-- ═══ WHAT IT DELIBERATELY DOES NOT TEST ═══
--
-- The page (ui-src: scripts/test-music.mjs and check-ui rule R24), the server
-- (tools/test_emotes.lua) and the wheel and playback (tools/test_emotes_client.lua).

local RES = 'resources/[fivem-royale]/'
--- The season this run's server booted with: verify.sh's BR_SEASON, or nil.
local RUN_SEASON = os.getenv('BR_SEASON')

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

-- DEV MODE IS A CONVAR, read at call time by BR.Dev.on(); it stays off. THE
-- SEASON IS ONE TOO: br_seasonServed, read at call time by BR.Season.current().
local devOn = false
local convars = {}
function GetConvar(name, dflt)
    if name == 'sv_devMode' or name == 'br_devMode' then return devOn and 'true' or 'false' end
    if convars[name] ~= nil then return convars[name] end
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

-- br_ui's own manifest order: devgate first, then enums and protocol, then the
-- client scripts with config/market.lua, config/emotes.lua and the season
-- module and its list at their head.
loadAt('br_lib/shared/devgate.lua')
loadAt('br_lib/shared/enums.lua')
loadAt('br_lib/shared/protocol.lua')
loadAt('br_lib/config/market.lua')
loadAt('br_lib/config/emotes.lua')
loadAt('br_lib/shared/season.lua')
loadAt('br_lib/config/seasons.lua')
loadAt('br_ui/client/market.lua')

-- A TYPO'D ID FAILS THIS SUITE rather than quietly closing a door.
BR.Season.strict = true

local ROW = BR.Config.Seasons.features.emotes
local FROM = ROW.from
local OFF = FROM - 1
if OFF < 1 then
    realPrint('\27[31mFAIL\27[0m emotes are on from Season 1, so there is no season to close them in')
    os.exit(1)
end
local RUN_SERVED = tostring((BR.Season.resolve(RUN_SEASON)))
convars.br_seasonServed = RUN_SERVED

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

local function gateClosed() convars.br_seasonServed = tostring(OFF) end
local function gateOpen() convars.br_seasonServed = tostring(FROM) end
local function restore() convars.br_seasonServed = RUN_SERVED; devOn = false end
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
-- BEFORE THE SEASON ARRIVES (#388). br_seasonServed is replicated and may land
-- after br_ui starts; until it does the season is unknown and the page must
-- not show a tab or a slider the server's season may not have.
-- ---------------------------------------------------------------------------

describe('before the season arrives')
do
    convars.br_seasonServed = nil
    reset()
    ok(BR.Season.current() == nil and BR.Season.has('emotes') == false,
        'no season yet: br_ui does not guess one, and the gate reads shut')
    fire('onClientResourceStart', 'br_ui')
    local e = lastLocal(BR.Nui.EMOTES)
    ok(e ~= nil and e.on == false,
        "br_ui's own start sends EMOTES {on=false}: no Emotes tab, no Music slider",
        e and tostring(e.on))
    ok(lastLocal(BR.Nui.MARKET) ~= nil and #emoteItems(lastLocal(BR.Nui.MARKET)) == 0,
        'and a grid with no emote tile')

    reset()
    local a1, ok1 = callCb(BR.NuiCb.MARKET_BUY, { id = 'emote_shuffle' })
    local a2, ok2 = callCb(BR.NuiCb.MARKET_EQUIP, { id = 'emote_shuffle' })
    local a3, ok3 = callCb(BR.NuiCb.MARKET_UNEQUIP, { id = 'emote_shuffle' })
    ok(ok1 and ok2 and ok3 and #toServer == 0,
        'the three Market callbacks forward nothing for an emote', #toServer)
    ok(a1 and a1.ok and a2 and a2.ok and a3 and a3.ok, 'and all three still answer')

    -- A STATE FROM THE SERVER CAN BEAT THE CONVAR HERE; it still opens nothing.
    reset()
    fire(BR.Net.MARKET_STATE, { balance = 0, owned = { 'emote_shuffle' }, equipped = {},
        emotes = { 'emote_shuffle', '', '', '', '', '', '', '' } })
    e = lastLocal(BR.Nui.EMOTES)
    ok(e ~= nil and e.on == false and #emoteItems(lastLocal(BR.Nui.MARKET)) == 0,
        'a market state arriving first still sends no tab and no tile')

    -- THE SEASON ARRIVES AT THE ONE BEFORE `from`: still shut.
    gateClosed()
    reset()
    fire(BR.Net.MARKET_STATE, { balance = 0, owned = {}, equipped = {} })
    e = lastLocal(BR.Nui.EMOTES)
    ok(e ~= nil and e.on == false and #emoteItems(lastLocal(BR.Nui.MARKET)) == 0,
        ('Season %d arrives: still no tab and no tile'):format(OFF))

    -- A SEASON WITH EMOTES LANDS INSTEAD: br_core's gate pass sees the flip and
    -- raises br:emotes:gate, and br_ui re-sends from its own read at once --
    -- before, and without, any answer from the server.
    convars.br_seasonServed = nil
    reset()
    fire('onClientResourceStart', 'br_ui')
    gateOpen()
    reset()
    fire('br:emotes:gate')
    e = lastLocal(BR.Nui.EMOTES)
    ok(e ~= nil and e.on == true, ('Season %d arrives: EMOTES {on=true} is re-sent'):format(FROM),
        e and tostring(e.on))
    ok(#emoteItems(lastLocal(BR.Nui.MARKET)) == #BR.Config.Emotes.order,
        'with the dances on the grid', #emoteItems(lastLocal(BR.Nui.MARKET)))
    ok(#toServer == 0, 'and no server round trip in between', #toServer)
    restore()
end

-- ---------------------------------------------------------------------------
-- `restart br_core` ONTO AN EARLIER SEASON (#388, dev boxes). Nothing changes
-- on br_ui's side, and br_core's restarted client has no flip to see -- its
-- first gate pass reads the gate shut with nothing before it. That first pass
-- raises br:emotes:gate anyway, so the page's Emotes tab still closes.
-- ---------------------------------------------------------------------------

describe('br_core restarted onto an earlier season')
do
    gateOpen()
    reset()
    fire(BR.Net.MARKET_STATE, { balance = 0, owned = { 'emote_shuffle' }, equipped = {},
        emotes = { 'emote_shuffle', '', '', '', '', '', '', '' } })
    ok(lastLocal(BR.Nui.EMOTES).on == true, ('Season %d: the page has the tab'):format(FROM))

    gateClosed()
    reset()
    fire('br:emotes:gate')
    local e = lastLocal(BR.Nui.EMOTES)
    ok(e ~= nil and e.on == false,
        ("br_core's first pass at Season %d: EMOTES {on=false} is re-sent"):format(OFF),
        e and tostring(e.on))
    ok(#emoteItems(lastLocal(BR.Nui.MARKET)) == 0, 'and the dances leave the grid')
    ok(#toServer == 0, 'with nothing asked of the server', #toServer)
    restore()
end

-- ---------------------------------------------------------------------------
-- 0. THIS RUN'S SEASON, with dev mode OFF and nothing forced
-- ---------------------------------------------------------------------------

describe("0. this run's season")
do
    devOn = false
    restore()
    reset()
    local season = BR.Season.current()
    local want = season >= FROM and (ROW.untilSeason == nil or season < ROW.untilSeason)
    ok(tostring(season) == RUN_SERVED, 'the page follows the season the server replicated', season)
    ok(BR.Season.has('emotes') == want,
        ('Season %d: emotes are %s, with dev mode off'):format(season, want and 'on' or 'off'))
    fire(BR.Net.MARKET_STATE, { balance = 0, owned = {}, equipped = {}, emotes = eightEmpty() })
    local e = lastLocal(BR.Nui.EMOTES)
    ok(e ~= nil and e.on == want, 'EMOTES {on=' .. tostring(want) .. '} is sent', e and tostring(e.on))
    ok(#emoteItems(lastLocal(BR.Nui.MARKET)) == (want and #BR.Config.Emotes.order or 0),
        'the emote rows are on the grid exactly when the season has them',
        #emoteItems(lastLocal(BR.Nui.MARKET)))
    reset()
    local answered = callCb(BR.NuiCb.MARKET_UNEQUIP, { id = 'emote_shuffle' })
    ok(#serverSent(BR.Net.MARKET_UNEQUIP) == (want and 1 or 0) and answered and answered.ok == true,
        'MARKET_UNEQUIP forwards exactly when the season has emotes, and always answers')
    restore()
end

-- ---------------------------------------------------------------------------
-- 1. Gate closed
-- ---------------------------------------------------------------------------

describe('1. gate closed')
do
    gateClosed()
    ok(BR.Season.has('emotes') == false, ('has(emotes) is false at Season %d'):format(OFF))
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
    ok(BR.Season.has('emotes') == true, ('has(emotes) is true at Season %d, dev mode off'):format(FROM))
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
-- 4. Robustness: a BR.Season stub with no config (the test_client case)
-- ---------------------------------------------------------------------------

describe('4. robustness')
do
    local savedSeason, savedConfig = BR.Season, BR.Config.Emotes
    BR.Season = { has = function() return true end }
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
    BR.Season = nil
    BR.Config.Emotes = savedConfig
    reset()
    okPush = pcall(BR.Market.push)
    ok(okPush and lastLocal(BR.Nui.EMOTES).on == false, 'BR.Season nil: push works, gate off')
    BR.Season, BR.Config.Emotes = savedSeason, savedConfig
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
realPrint(('\27[32m%d passed\27[0m (Season %s)'):format(pass, RUN_SEASON or 'unset'))
