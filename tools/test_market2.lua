-- Unit tests for br_ui's half of the Season 2 Market (#411).
--
-- Owner, 2026-10-13: "nothing we re-do in the shop should ever show on season
-- 1." The gate is the `market2` row in br_lib/config/seasons.lua, asked as
-- BR.Season.has('market2') by br_ui/client/market.lua. On, the MARKET envelope
-- carries `v2` (the page draws screens/MarketV2.tsx), the grid drops the
-- placeholder kinds the server cannot sell (Characters, Banners -- "only real
-- items"), and nothing is marked New (owner, 2026-10-14: "let's not just put
-- the "new" tag on everything - have some meaning to it. or get rid of it.").
-- Off, the envelope and the grid are exactly what they were before #411.
--
-- AND WHAT ONLY THE SEASON 2 MARKET ANSWERS (#411, 2026-10-14): MARKET_PREVIEW
-- -- a dance on the lobby character, refused unless owned or affordable,
-- handed to br_core as `br:ui:marketPreview` (its half is the last block of
-- tools/test_lobbyseq.lua) -- and `brmarkettabs`, the tab designs' switch.
--
-- ═══ WHAT THIS LOADS FOR REAL ═══
--
-- br_lib's devgate, enums, protocol, config/market, config/emotes, the season
-- module and its list, then the REAL br_ui/client/market.lua, with
-- RegisterNUICallback, TriggerServerEvent and TriggerEvent captured -- the
-- same harness as tools/test_emotes_ui.lua. Every assertion is about what the
-- page is actually sent and what the server is actually asked.
--
-- ═══ THE SEASON DISCIPLINE ═══
--
-- br_seasonServed is set the way br_core's server replicates it, and each block
-- puts the season it is about in force itself (season1(), season2()), so no
-- assertion depends on BR_SEASON. The page half (the screen, the confirm, the
-- tabs, Season 1's screen byte-for-byte) is ui-src/scripts/test-marketv2.mjs.

local RES = 'resources/[fivem-royale]/'

local realPrint = print
function print() end

-- ---------------------------------------------------------------------------
-- Natives and engine stubs (test_emotes_ui.lua's)
-- ---------------------------------------------------------------------------

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
-- Off, as on the public box, but for the `brmarkettabs` block, which is a dev
-- command (br_lib/shared/devgate.lua wraps every RegisterCommand).
local devMode = false
function GetConvar(name, dflt)
    if name == 'sv_devMode' or name == 'br_devMode' then return devMode and 'true' or 'false' end
    if convars[name] ~= nil then return convars[name] end
    return dflt
end
function GetCurrentResourceName() return 'br_ui' end
function GetGameTimer() return 0 end

local handlers, nuiCbs, toServer, toLocal = {}, {}, {}, {}
function AddEventHandler(name, fn)
    handlers[name] = handlers[name] or {}
    handlers[name][#handlers[name] + 1] = fn
end
function RegisterNetEvent() end
function RegisterNUICallback(name, fn) nuiCbs[name] = fn end
function TriggerServerEvent(name, ...) toServer[#toServer + 1] = { name = name, args = { ... } } end
function TriggerEvent(name, ...) toLocal[#toLocal + 1] = { name = name, args = { ... } } end
local commands = {}
function RegisterCommand(name, fn) commands[name] = fn end

local function fire(name, ...)
    for _, fn in ipairs(handlers[name] or {}) do fn(...) end
end

local function loadAt(f)
    local chunk, err = loadfile(RES .. f)
    if not chunk then
        realPrint('\27[31mload error\27[0m ' .. f .. ': ' .. tostring(err))
        os.exit(1)
    end
    chunk()
end

-- br_ui's own manifest order.
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

local ROW = BR.Config.Seasons.features.market2

-- ---------------------------------------------------------------------------
-- Harness
-- ---------------------------------------------------------------------------

local pass, failn, group = 0, 0, ''
local function describe(n) group = n end
local function ok(cond, name, detail)
    if cond then pass = pass + 1 else
        failn = failn + 1
        realPrint('\27[31mFAIL\27[0m ' .. group .. ' > ' .. name ..
            (detail ~= nil and ('\n       ' .. tostring(detail)) or ''))
    end
end

local function season1() convars.br_seasonServed = '1' end
local function season2() convars.br_seasonServed = '2' end
local function reset() toServer, toLocal = {}, {} end

--- The most recent payload sent to the page under `kind`, or nil.
local function lastLocal(kind)
    for i = #toLocal, 1, -1 do
        local e = toLocal[i]
        if e.name == 'br:ui:sendLocal' and e.args[1] == kind then return e.args[2] end
    end
    return nil
end

local function keysOf(t)
    local out = {}
    for k in pairs(t or {}) do out[#out + 1] = tostring(k) end
    table.sort(out)
    return table.concat(out, ',')
end

local function itemById(grid, id)
    for _, it in ipairs(grid and grid.items or {}) do if it.id == id then return it end end
    return nil
end

local function kindsOf(grid)
    local seen, out = {}, {}
    for _, it in ipairs(grid and grid.items or {}) do
        if not seen[it.kind] then seen[it.kind] = true; out[#out + 1] = it.kind end
    end
    table.sort(out)
    return table.concat(out, ',')
end

local function serverSent(name)
    local out = {}
    for _, e in ipairs(toServer) do if e.name == name then out[#out + 1] = e.args[1] end end
    return out
end

local function callCb(name, data)
    local answered = nil
    local okCall = pcall(nuiCbs[name], data, function(r) answered = r end)
    return answered, okCall
end

--- One grid from a fresh state, in force at the season set.
local function grid(state)
    reset()
    fire(BR.Net.MARKET_STATE, state or { balance = 1000, owned = {}, equipped = {} })
    return lastLocal(BR.Nui.MARKET)
end

--- The fields a tile carried before #411 -- no others may reach Season 1.
local S1_FIELDS = {
    id = true, name = true, sub = true, kind = true, price = true, rarity = true, season = true,
    owned = true, equipped = true, slot = true, locked = true,
}
--- The placeholders, in their order: Season 1's and only Season 1's.
local PLACEHOLDERS = { 'ped_juggalo', 'ped_clown', 'ped_trooper', 'ped_yeti', 'ban_storm', 'ban_first' }

--- Every tile of the config's own seasons that the shelf shows, in order.
local function shelf()
    local out = {}
    for _, s in ipairs(BR.Config.Market.seasons) do
        for _, it in ipairs(s.items) do
            if it.hidden ~= true then out[#out + 1] = it.id end
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- THE ROW
-- ---------------------------------------------------------------------------

describe('the row')
do
    ok(type(ROW) == 'table' and ROW.from == 2 and ROW.untilSeason == nil,
        'market2 = { from = 2 }: the Season 2 Market from Season 2, and never off again')
    season1()
    ok(BR.Season.has('market2') == false, 'off on Season 1')
    season2()
    ok(BR.Season.has('market2') == true, 'on on Season 2')
end

-- ---------------------------------------------------------------------------
-- SEASON 1: THE ENVELOPE AND THE GRID ARE THE ONES THEY ALWAYS WERE
-- ---------------------------------------------------------------------------

describe('Season 1 is untouched')
do
    season1()
    local g = grid()
    ok(g ~= nil, 'a grid is pushed')
    ok(keysOf(g) == 'balance,currency,items', 'the envelope is { balance, currency, items } -- no v2', keysOf(g))

    local extra = {}
    for _, it in ipairs(g.items) do
        for k in pairs(it) do
            if not S1_FIELDS[k] then extra[#extra + 1] = it.id .. '.' .. tostring(k) end
        end
    end
    ok(#extra == 0, 'no tile carries a field Season 1 never had (isNew among them)', table.concat(extra, ','))

    local want = shelf()
    for _, id in ipairs(PLACEHOLDERS) do want[#want + 1] = id end
    local got = {}
    for _, it in ipairs(g.items) do got[#got + 1] = it.id end
    ok(table.concat(got, ',') == table.concat(want, ','),
        "the config's shelf, then the six placeholders, in that order", table.concat(got, ','))
    ok(kindsOf(g) == 'banner,character,chute,trail,weapon',
        'Characters and Banners still have their tiles', kindsOf(g))
    local troop = itemById(g, 'ped_trooper')
    ok(troop ~= nil and troop.owned == true and troop.price == 4000 and troop.rarity == 4,
        'a placeholder is drawn as it always was', troop and keysOf(troop))
end

-- ---------------------------------------------------------------------------
-- SEASON 2: ONLY REAL ITEMS, AND NEW ON THE SEASON'S OWN
-- ---------------------------------------------------------------------------

describe('Season 2')
do
    season2()
    local g = grid({ balance = 7000, owned = { 'chute_azure', 'emote_shuffle' }, equipped = { chute = 'chute_azure' },
        emotes = { 'emote_shuffle', '', '', '', '', '', '', '' } })
    ok(g ~= nil and g.v2 == true, 'the envelope says v2 = true')
    ok(keysOf(g) == 'balance,currency,items,v2', 'and nothing else new', keysOf(g))

    ok(kindsOf(g) == 'chute,emote,trail,weapon', 'the kinds on the grid are the real ones', kindsOf(g))
    local fake = {}
    for _, it in ipairs(g.items) do
        if BR.Config.MarketIndex[it.id] == nil then fake[#fake + 1] = it.id end
    end
    ok(#fake == 0, 'every tile is a catalog item the server can resolve', table.concat(fake, ','))
    for _, id in ipairs(PLACEHOLDERS) do
        ok(itemById(g, id) == nil, ('no %s tile'):format(id))
    end

    local dances, extra = 0, {}
    for _, it in ipairs(g.items) do
        if it.kind == 'emote' then dances = dances + 1 end
        for k in pairs(it) do
            if not S1_FIELDS[k] then extra[#extra + 1] = it.id .. '.' .. tostring(k) end
        end
    end
    ok(dances == #BR.Config.Emotes.order and dances > 0, 'the dances are on the grid', dances)
    ok(#extra == 0, 'and no tile carries New -- or any field a Season 1 tile does not', table.concat(extra, ','))

    -- THE REST OF THE GRID IS SEASON 1'S, TILE FOR TILE.
    season1()
    local g1 = grid({ balance = 7000, owned = { 'chute_azure' }, equipped = { chute = 'chute_azure' } })
    local same, diff = 0, {}
    local i2 = 0
    for _, a in ipairs(g1.items) do
        if a.kind ~= 'character' and a.kind ~= 'banner' then
            i2 = i2 + 1
            local b = g.items[i2]
            local match = b ~= nil and keysOf(a) == keysOf(b)
            if match then
                for k, v in pairs(a) do if b[k] ~= v then match = false end end
            end
            if match then same = same + 1 else diff[#diff + 1] = a.id end
        end
    end
    ok(#diff == 0 and same == #shelf(),
        "Season 2's real tiles are Season 1's, in the same order with the same fields", table.concat(diff, ','))
    local sel = itemById(g, 'chute_azure')
    ok(sel ~= nil and sel.owned == true and sel.equipped == true, 'ownership and the equipped slot come through')
    local wheel = itemById(g, 'emote_shuffle')
    ok(wheel ~= nil and wheel.slot == 1 and wheel.equipped == true, 'and the wheel')
end

-- ---------------------------------------------------------------------------
-- BEFORE THE SEASON ARRIVES: the gate is shut, so it is Season 1's Market.
-- ---------------------------------------------------------------------------

describe('before the season arrives')
do
    convars.br_seasonServed = nil
    reset()
    fire('onClientResourceStart', 'br_ui')
    local g = lastLocal(BR.Nui.MARKET)
    ok(BR.Season.current() == nil, 'no season yet')
    ok(g ~= nil and g.v2 == nil and itemById(g, 'ped_juggalo') ~= nil,
        "br_ui's own start sends Season 1's envelope and grid, never a guess at Season 2")
end

-- ---------------------------------------------------------------------------
-- ITS OWN ROW: the Market follows `market2`, never `emotes` (#411's review).
-- Both rows say `from = 2` today, so only moving one away from the other shows
-- which of them the envelope and the grid follow.
-- ---------------------------------------------------------------------------

describe('market2 is its own row')
do
    local rows = BR.Config.Seasons.features
    local m2From, emFrom = rows.market2.from, rows.emotes.from
    season2()

    rows.emotes.from = 3 -- the Season 2 Market, and no dances yet
    local g = grid()
    ok(g ~= nil and g.v2 == true, 'market2 on, emotes off: the envelope still says v2', g and keysOf(g))
    ok(kindsOf(g) == 'chute,trail,weapon', 'the real items only, and no dances while their row is off', kindsOf(g))

    rows.emotes.from, rows.market2.from = 2, 3 -- the dances, on Season 1's Market
    g = grid({ balance = 1000, owned = {}, equipped = {}, emotes = { '', '', '', '', '', '', '', '' } })
    ok(g ~= nil and g.v2 == nil, "emotes on, market2 off: no v2 -- Season 1's Market", g and keysOf(g))
    ok(itemById(g, 'ban_storm') ~= nil and itemById(g, 'emote_shuffle') ~= nil,
        'its placeholders, and the dances the emotes row brings')
    local marked = {}
    for _, it in ipairs(g.items) do if it.isNew ~= nil then marked[#marked + 1] = it.id end end
    ok(#marked == 0, 'with New on nothing, the dances included', table.concat(marked, ','))

    rows.market2.from, rows.emotes.from = m2From, emFrom
end

-- ---------------------------------------------------------------------------
-- brseason: THE PAGE FOLLOWS A SWITCH, BOTH WAYS, WITH NO SERVER ROUND TRIP
-- ---------------------------------------------------------------------------

describe('brseason')
do
    season2()
    grid()
    season1()
    reset()
    fire('br:season:changed', 1, 2)
    local g = lastLocal(BR.Nui.MARKET)
    ok(g ~= nil and g.v2 == nil and itemById(g, 'ban_storm') ~= nil,
        'switched to Season 1: v2 goes, and the placeholders come back')
    ok(#toServer == 0, 'with nothing asked of the server', #toServer)
    season2()
    reset()
    fire('br:season:changed', 2, 1)
    g = lastLocal(BR.Nui.MARKET)
    ok(g ~= nil and g.v2 == true and itemById(g, 'ban_storm') == nil,
        'switched back to Season 2: v2, and the placeholders gone')
end

-- ---------------------------------------------------------------------------
-- A PURCHASE IS STILL THE SERVER'S: an id and nothing else, and no tile moves
-- until MARKET_STATE says so.
-- ---------------------------------------------------------------------------

describe('purchases stay server-authoritative')
do
    season2()
    grid({ balance = 5000, owned = {}, equipped = {} })
    reset()
    local answered, okCall = callCb(BR.NuiCb.MARKET_BUY, { id = 'chute_crimson', price = 0, owned = true })
    local buys = serverSent(BR.Net.MARKET_BUY)
    ok(okCall and answered and answered.ok == true, 'MARKET_BUY answers at once')
    ok(#buys == 1 and keysOf(buys[1]) == 'id' and buys[1].id == 'chute_crimson',
        'and forwards the id alone -- never a price or an ownership claim', buys[1] and keysOf(buys[1]))
    BR.Market.push()
    local tile = itemById(lastLocal(BR.Nui.MARKET), 'chute_crimson')
    ok(tile ~= nil and tile.owned == false, 'a re-push before the answer still shows it unowned')
    fire(BR.Net.MARKET_STATE, { balance = 3500, owned = { 'chute_crimson' }, equipped = { chute = 'chute_crimson' } })
    local g = lastLocal(BR.Nui.MARKET)
    tile = itemById(g, 'chute_crimson')
    ok(tile ~= nil and tile.owned == true and tile.equipped == true and g.balance == 3500,
        "the server's answer is what moves it")
end

-- ---------------------------------------------------------------------------
-- THE PREVIEW (#411): "let's have a way for them to preview the emote while in
-- market, but shouldn't work if they can't afford it" (owner, 2026-10-14).
-- ---------------------------------------------------------------------------

--- Every `br:ui:marketPreview` raised since the last reset, as its id or 'nil'.
local function previews()
    local out = {}
    for _, e in ipairs(toLocal) do
        if e.name == 'br:ui:marketPreview' then out[#out + 1] = tostring(e.args[1]) end
    end
    return table.concat(out, ',')
end

describe('the preview')
do
    local dance, other = 'emote_shuffle', 'emote_jumper'
    local price = BR.Config.MarketIndex[dance].price
    season2()
    grid({ balance = price, owned = { other }, equipped = {} })

    reset()
    local answered, okCall = callCb(BR.NuiCb.MARKET_PREVIEW, { id = dance })
    ok(okCall and answered and answered.ok == true, 'MARKET_PREVIEW answers at once')
    ok(previews() == dance, 'an affordable dance goes to the lobby ped', previews())
    ok(#toServer == 0, 'and nothing reaches the server: no record, no music', #toServer)

    reset()
    callCb(BR.NuiCb.MARKET_PREVIEW, { id = other })
    callCb(BR.NuiCb.MARKET_PREVIEW, {})
    callCb(BR.NuiCb.MARKET_PREVIEW, { id = '' })
    ok(previews() == other .. ',nil,nil', 'an owned one goes too, and no id is the stop', previews())

    grid({ balance = price - 1, owned = { other }, equipped = {} })
    reset()
    answered = callCb(BR.NuiCb.MARKET_PREVIEW, { id = dance })
    ok(previews() == '' and answered and answered.ok == true,
        'one the player neither owns nor can afford is refused -- and still answered', previews())
    callCb(BR.NuiCb.MARKET_PREVIEW, { id = other })
    ok(previews() == other, 'while one they own still plays, at any balance', previews())

    reset()
    callCb(BR.NuiCb.MARKET_PREVIEW, { id = 'chute_crimson' })
    callCb(BR.NuiCb.MARKET_PREVIEW, { id = 'emote_nope' })
    ok(previews() == '', 'anything but a dance in the catalog is refused', previews())

    -- A CLOSED SEASON'S DANCE: on sale nowhere, so never previewed unowned.
    local item = BR.Config.MarketIndex[dance]
    local was = item.purchasable
    item.purchasable = false
    grid({ balance = 999999, owned = {}, equipped = {} })
    reset()
    callCb(BR.NuiCb.MARKET_PREVIEW, { id = dance })
    ok(previews() == '', 'a dance no longer on sale is refused to a player who does not own it', previews())
    item.purchasable = was

    -- SEASON 1 NEVER: the callback answers and does nothing at all.
    season1()
    grid({ balance = 999999, owned = { other }, equipped = {} })
    reset()
    answered = callCb(BR.NuiCb.MARKET_PREVIEW, { id = other })
    callCb(BR.NuiCb.MARKET_PREVIEW, {})
    ok(previews() == '' and #toServer == 0 and answered and answered.ok == true,
        'on Season 1 nothing is sent anywhere, the stop included', previews())

    -- ITS OWN ROWS BOTH WAYS: the Season 2 Market with emotes off plays
    -- nothing, and neither do the dances on Season 1's Market.
    local rows = BR.Config.Seasons.features
    season2()
    rows.emotes.from = 3
    grid({ balance = 999999, owned = { other }, equipped = {} })
    reset()
    callCb(BR.NuiCb.MARKET_PREVIEW, { id = other })
    ok(previews() == '', 'with the emotes row off, nothing plays even on the Season 2 Market', previews())
    rows.emotes.from, rows.market2.from = 2, 3
    grid({ balance = 999999, owned = { other }, equipped = {} })
    reset()
    callCb(BR.NuiCb.MARKET_PREVIEW, { id = other })
    callCb(BR.NuiCb.MARKET_PREVIEW, {})
    ok(previews() == '', "with the market2 row off, the emotes row's dances preview nothing", previews())
    rows.market2.from = 2
end

-- ---------------------------------------------------------------------------
-- THE TAB DESIGNS (#411): `brmarkettabs`, the dev box's comparison switch.
-- ---------------------------------------------------------------------------

describe('brmarkettabs')
do
    local cmd = commands.brmarkettabs
    ok(type(cmd) == 'function', 'the command is registered')
    season2()
    reset()
    cmd(0, { 'rail' })
    ok(lastLocal(BR.Nui.MARKET_TABS) == nil, 'off a dev box it is refused by the dev gate and sends nothing')
    devMode = true
    for _, c in ipairs({ { '1', 'bar' }, { 'rail', 'rail' }, { '3', 'folder' }, { 'BAR', 'bar' } }) do
        reset()
        cmd(0, { c[1] })
        local d = lastLocal(BR.Nui.MARKET_TABS)
        ok(d ~= nil and d.design == c[2] and keysOf(d) == 'design',
            ('brmarkettabs %s sends { design = %s }'):format(c[1], c[2]), d and keysOf(d))
    end
    reset()
    cmd(0, { 'plates' })
    cmd(0, {})
    ok(lastLocal(BR.Nui.MARKET_TABS) == nil, 'a design it does not know, or none, sends nothing')

    reset()
    cmd(0, { '2' })
    reset()
    fire('br:ui:ready')
    local d = lastLocal(BR.Nui.MARKET_TABS)
    ok(d ~= nil and d.design == 'rail', 'a reloaded page is told the design again', d and d.design)

    season1()
    reset()
    cmd(0, { 'folder' })
    fire('br:ui:ready')
    ok(lastLocal(BR.Nui.MARKET_TABS) == nil, 'on Season 1 it sends nothing, then or on a reload')
    season2()
    reset()
    fire('br:ui:ready')
    d = lastLocal(BR.Nui.MARKET_TABS)
    ok(d ~= nil and d.design == 'rail', 'and what it was asked on Season 1 is not kept for later', d and d.design)
    devMode = false
end

-- ---------------------------------------------------------------------------
-- THE WIRING
-- ---------------------------------------------------------------------------

describe('wiring')
do
    local fh = assert(io.open(RES .. 'br_ui/client/market.lua', 'rb'))
    local src = fh:read('a')
    fh:close()
    local _, asks = src:gsub("BR%.Season%.has%('market2'%)", '')
    ok(asks == 1, "br_ui's market asks BR.Season.has('market2') in one place, its market2On()", asks)
    ok(src:find('local function market2On() return BR.Season ~= nil and BR.Season.has ~= nil and '
        .. "BR.Season.has('market2') == true end", 1, true) ~= nil, 'nil-safe, like emotesOn')
end

if failn > 0 then
    realPrint(('\27[31m%d failed\27[0m, %d passed'):format(failn, pass))
    os.exit(1)
end
realPrint(('\27[32m%d passed\27[0m'):format(pass))
