-- Unit tests for the warmup vehicle shop (#224).
--
-- ═══ THE FIXTURE IS THE POINT, AND THE SHIPPED CATALOGUE IS EMPTY ═══
--
-- BR.Config.Shop.items ships as `{}` on purpose -- the owner authors the models,
-- coordinates and headings in game and has not written them yet, and until he
-- does the feature must be INERT rather than broken (BR.Config.Rescue.points'
-- rule, applied a second time). So EVERY behavioural test below runs against a
-- FIXTURE catalogue built in this file. Testing against the shipped table would
-- assert nothing at all, and would start passing for the wrong reason the moment
-- he pastes his rows in.
--
-- Exactly one test reads the shipped table, and it asserts that it is empty.
--
-- ═══ WHAT THIS SUITE IS FOR ═══
--
-- Three of this feature's rules are effectively unobservable in a running game
-- and expensive to get wrong:
--
--   "EXACTLY AS SHOWN WHEN THEY PURCHASED IT". The wrong implementation looks
--   identical to the right one for as long as nobody happens to notice that the
--   car that came out of the item is a different colour from the one in the
--   showroom -- and by then the display entity has been gone for forty minutes
--   and there is nothing left to compare against. The property that makes it
--   true is structural (one function, one row, nothing on the wire) and this
--   file asserts the structure.
--
--   THE DELIVERY ORDERING. The item is handed out one line after
--   BR.Inv.clearFor(m) in match.onEnter(BUS). One line EARLIER and the wipe
--   deletes the thing the player paid for -- and the symptom is a purchase that
--   silently never arrives, which is indistinguishable from the purchase having
--   failed.
--
--   NO REFUND, EVER. Owner, answer 3: a purchase is not refunded, including when
--   the engine loses the car. The failure mode of getting that wrong is a
--   SECOND CAR FOR ONE PAYMENT, and it only shows up under an engine fault
--   nobody can reproduce on demand (citizenfx/fivem#2623).

local RES  = 'resources/[fivem-royale]/'
local ROOT = RES .. 'br_lib/'

local fakeTime = 0
function GetGameTimer() return fakeTime end

-- ---------------------------------------------------------------------------
-- Natives and engine stubs
-- ---------------------------------------------------------------------------

--- ONE MODEL IS BANNED AND ITS HASH IS THE REAL ONE. `lazer` is row 17 of
--- BR.Config.RefusedVehicles with hash 0xB39B0AE6, so the refusal below is the
--- shipped table refusing a shipped model rather than a stub agreeing with
--- itself. Everything else hashes to something that is in no row.
local HASHES = { lazer = 0xB39B0AE6 }
local nextHash = 0x10000000
function GetHashKey(s)
    s = tostring(s or '')
    if not HASHES[s] then
        nextHash = nextHash + 1
        HASHES[s] = nextHash
    end
    return HASHES[s]
end

local handlers = {}
function AddEventHandler(name, fn) handlers[name] = fn end
function RegisterNetEvent() end
function GetCurrentResourceName() return 'br_core' end

--- Everything the server told a client, in order.
local sent = {}
function TriggerClientEvent(name, src, payload)
    sent[#sent + 1] = { name = name, src = src, payload = payload }
end

--- Server-side ped reads. One player, standing at the origin facing north.
local peds = {}
function GetPlayerPed(src) return peds[src] and peds[src].ped or 0 end
function GetEntityCoords(ped)
    for _, p in pairs(peds) do
        if p.ped == ped then return { x = p.x, y = p.y, z = p.z } end
    end
    return { x = 0.0, y = 0.0, z = 0.0 }
end
function GetEntityHeading(ped)
    for _, p in pairs(peds) do
        if p.ped == ped then return p.heading end
    end
    return 0.0
end

local function loadAt(root, f)
    local chunk, err = loadfile(root .. f)
    if not chunk then
        print('\27[31mload error\27[0m ' .. f .. ': ' .. tostring(err))
        os.exit(1)
    end
    chunk()
end
local function load(f) loadAt(ROOT, f) end
local function loadCore(f) loadAt(RES, f) end

for _, f in ipairs({
    'shared/enums.lua',
    'shared/geo.lua',        -- BR.Dist and BR.NormHash
    'config/overrides.lua',
    'config/match.lua',
    'config/loot.lua',       -- BR.Config.ConsumableById and the pickup cue
    'config/audio.lua',      -- BR.Config.Audio.cues, which the shop cue lands in
    'config/vehicles.lua',   -- the refused list the catalogue is checked against
    'shared/shop_solve.lua',
    'config/shop.lua',
}) do load(f) end

local pass, fail = 0, 0
local group = ''
local function describe(n) group = n end
local function ok(cond, name, detail)
    if cond then pass = pass + 1 else
        fail = fail + 1
        print('\27[31mFAIL\27[0m ' .. group .. ' > ' .. name ..
            (detail and ('\n       ' .. tostring(detail)) or ''))
    end
end

local function readFile(p)
    local fh = io.open(p)
    if not fh then return '' end
    local s = fh:read('a')
    fh:close()
    return s
end

-- ---------------------------------------------------------------------------
describe('the shipped catalogue')
-- ---------------------------------------------------------------------------
do
    -- THE ONE TEST THAT READS THE REAL TABLE. Everything after this uses a
    -- fixture.
    ok(type(BR.Config.Shop.items) == 'table' and #BR.Config.Shop.items == 0,
        'ships EMPTY -- the owner has not authored his models yet',
        #BR.Config.Shop.items)

    ok(BR.ShopSolve.enabled(BR.Config.Shop) == false,
        'so the shop does not exist, rather than existing and being broken')

    local rows, rejects = BR.ShopSolve.catalogue(BR.Config.Shop,
                                                 BR.Config.Shop.refusedReason)
    ok(#rows == 0 and #rejects == 0,
        'and resolving an empty catalogue is not an error -- no rows, no '
            .. 'complaints')

    -- INERT MEANS INERT ON BOTH ENDS. `enabled` is what the purchase handler
    -- and the client scene both ask first, so a false here is the whole of "no
    -- showroom, no plate, no purchase".
    local can, why = BR.ShopSolve.canBuy({
        on = BR.ShopSolve.enabled(BR.Config.Shop),
        matchState = BR.MatchState.WARMUP,
        playerState = BR.PlayerState.WARMUP,
        row = { id = 'x', price = 1 }, bought = 0, limit = 1,
        balance = 999999, price = 1,
    })
    ok(can == false and why == BR.ShopSolve.Refusal.OFF,
        'and nothing can be bought from it whatever else is true')
end

-- ---------------------------------------------------------------------------
-- THE FIXTURE. Three sellable cars and one that must be thrown out.
-- ---------------------------------------------------------------------------

local FIXTURE = {
    enabled = true,
    limit   = 1,
    reachM  = 4.0,
    minSpacingM = 6.0,
    useMs   = 3000,
    tokenScale  = 0.1,
    tokenMarker = 34,
    spawnAheadM = 5.0,
    signLabel   = BR.Config.Shop.signLabel,
    boughtToast = BR.Config.Shop.boughtToast,
    cue         = BR.Config.Shop.cue,
    lockedState = 2,
    items = {
        {
            id = 'runner', model = 'sultan', label = 'Sultan',
            price = 750, vtype = 'automobile',
            x = 100.0, y = 200.0, z = 30.0, heading = 90.0,
            appearance = {
                primary = 27, secondary = 12, pearl = 3, wheelColour = 0,
                windowTint = 1, wheelType = 0, dirt = 0.0,
                plate = 'BR SHOP', plateIndex = 0,
                mods = { [11] = 2, [23] = 4, [12] = 1 },
                toggles = { [18] = true },
                extras = { [1] = true, [2] = false },
            },
        },
        {
            -- A SECOND PRICE, because answer 2 is "per-model price, in config".
            id = 'hauler', model = 'bison', price = 400,
            x = 140.0, y = 200.0, z = 30.0, heading = 90.0,
        },
        {
            -- NO APPEARANCE BLOCK AT ALL. A half-filled row has to be safe.
            id = 'plain', model = 'blista', price = 100,
            x = 180.0, y = 200.0, z = 30.0, heading = 0.0,
        },
        {
            -- BANNED. `lazer` is in BR.Config.RefusedVehicles because it flies.
            id = 'cheat', model = 'lazer', price = 10,
            x = 220.0, y = 200.0, z = 30.0, heading = 0.0,
        },
    },
}

local FROWS, FREJECTS = BR.ShopSolve.catalogue(FIXTURE,
                                               BR.Config.Shop.refusedReason)
local function frow(id) return BR.ShopSolve.rowById(FROWS, id) end

-- ---------------------------------------------------------------------------
describe('the catalogue is the safety mechanism')
-- ---------------------------------------------------------------------------
do
    ok(#FROWS == 3, 'three of the four fixture rows are sellable', #FROWS)

    ok(frow('cheat') == nil,
        'and a BANNED model is not one of them -- an aircraft cannot be sold')

    local found = nil
    for _, r in ipairs(FREJECTS) do if r.id == 'cheat' then found = r end end
    ok(found ~= nil and found.why:find('refused', 1, true) ~= nil,
        'the refusal is REPORTED rather than silent, and it says why',
        found and found.why)

    -- ═══ THE REFUSAL IS THE SHIPPED TABLE'S, NOT THIS FILE'S ═══
    --
    -- The point of hashing `lazer` to its real 0xB39B0AE6 is that this asserts
    -- config/vehicles.lua actually refusing a model it actually lists. A stub
    -- that answered "banned" would pass this test with the whole ban list
    -- deleted.
    local allowed = BR.Config.IsAllowedVehicle(GetHashKey('lazer'))
    ok(allowed == false,
        'because BR.Config.IsAllowedVehicle refuses it -- the same one function '
            .. 'BR.Vehicles.spawnOwned asks')

    -- A row for a car that IS allowed must survive, or the check is just a
    -- switch that turns the shop off.
    ok(BR.Config.IsAllowedVehicle(GetHashKey('sultan')) == true
           and frow('runner') ~= nil,
        'and an ordinary car is not caught by it')

    -- DUPLICATES, which would otherwise produce two rows selling one item id
    -- and a delivery that could come from either.
    local dup = { enabled = true, items = {
        { id = 'a', model = 'sultan', price = 1, x = 0.0, y = 0.0, z = 0.0 },
        { id = 'a', model = 'blista', price = 2, x = 0.0, y = 0.0, z = 0.0 },
    } }
    local drows, drej = BR.ShopSolve.catalogue(dup, BR.Config.Shop.refusedReason)
    ok(#drows == 1 and #drej == 1 and drej[1].why == 'duplicate id',
        'two rows with one id: the second is thrown out and named')

    -- MALFORMED ROWS. Each of these would otherwise reach the world as a car
    -- with no price, no position, or a price nobody could pay.
    local bad = { enabled = true, items = {
        { model = 'sultan', price = 1, x = 0.0, y = 0.0, z = 0.0 },          -- no id
        { id = 'b', price = 1, x = 0.0, y = 0.0, z = 0.0 },                  -- no model
        { id = 'c', model = 'sultan', x = 0.0, y = 0.0, z = 0.0 },           -- no price
        { id = 'd', model = 'sultan', price = 0, x = 0.0, y = 0.0, z = 0.0 },-- free
        { id = 'e', model = 'sultan', price = -5, x = 0.0, y = 0.0, z = 0.0 },
        { id = 'f', model = 'sultan', price = 7.5, x = 0.0, y = 0.0, z = 0.0 },
        { id = 'g', model = 'sultan', price = 1 },                           -- nowhere
    } }
    local brows = BR.ShopSolve.catalogue(bad, BR.Config.Shop.refusedReason)
    ok(#brows == 0, 'and seven differently-broken rows all fail to reach the pad',
        #brows)
end

-- ---------------------------------------------------------------------------
describe('exactly as shown')
-- ---------------------------------------------------------------------------
do
    local row = frow('runner')

    -- ═══ THE APPEARANCE IS TOTAL ═══
    --
    -- Every field is present in the answer even when the row omits it, because
    -- a dresser that skips absent fields leaves a freshly created vehicle
    -- wearing the RANDOM COLOUR the engine gives it -- and a random colour is
    -- different on the showroom car and on the bought car by definition.
    local plain = BR.ShopSolve.appearance(frow('plain'))
    for _, k in ipairs({ 'primary', 'secondary', 'pearl', 'wheelColour',
                         'interior', 'dashboard', 'livery', 'roofLivery',
                         'windowTint', 'wheelType', 'plateIndex',
                         'xenonColour' }) do
        ok(plain[k] == -1,
            ('a row with no appearance block still answers %s, as an explicit '
             .. '"the model\'s own default"'):format(k), plain[k])
    end
    ok(type(plain.mods) == 'table' and next(plain.mods) == nil
           and type(plain.toggles) == 'table' and type(plain.extras) == 'table',
        'and the three collections are empty tables rather than nil')

    -- ═══ TWO CALLS AGREE, WHICH IS THE WHOLE PROMISE ═══
    --
    -- The showroom car is dressed at warmup and the bought car forty minutes
    -- later, both from this function over this row. If two calls could differ,
    -- nothing else in the feature could save it.
    local a1 = BR.ShopSolve.appearance(row)
    local a2 = BR.ShopSolve.appearance(row)
    local same = true
    for k, v in pairs(a1) do
        if type(v) ~= 'table' and a2[k] ~= v then same = false end
    end
    for slot, idx in pairs(a1.mods) do
        if a2.mods[slot] ~= idx then same = false end
    end
    ok(same, 'the same row dressed twice is the same car, field for field')

    ok(a1.primary == 27 and a1.secondary == 12 and a1.plate == 'BR SHOP'
           and a1.mods[11] == 2 and a1.mods[23] == 4
           and a1.toggles[18] == true,
        'and it is the AUTHORED car rather than a defaulted one')

    -- ═══ EXTRAS READ THE WAY A PERSON WOULD EXPECT ═══
    --
    -- SET_VEHICLE_EXTRA takes `true` to mean DISABLED. The inversion happens in
    -- exactly one place (BR.Shop.dress) and the config is written the human way,
    -- so this asserts the config's polarity survives normalisation.
    ok(a1.extras[1] == true and a1.extras[2] == false,
        'an extra the owner turned ON arrives here as true')

    -- ═══ THE CALLER CANNOT WRITE BACK INTO THE CONFIG ═══
    --
    -- A defaulted field written back into the shared row would be a second
    -- representation of the appearance arriving by the back door -- one client
    -- would have persisted its own defaults into the table every other reader
    -- uses.
    a1.mods[99] = 7
    a1.primary = 0
    local a3 = BR.ShopSolve.appearance(row)
    ok(a3.mods[99] == nil and a3.primary == 27,
        'and mutating the answer cannot reach the authored row')

    -- ═══ STRUCTURE: ONE DRESSER, TWO CALLERS ═══
    --
    -- The behavioural half above proves the FUNCTION is deterministic. This
    -- half proves that both cars actually go through it -- which is the claim a
    -- refactor could quietly break while every test above kept passing.
    local cli = readFile(RES .. 'br_core/client/shop.lua')
    local calls = 0
    for _ in cli:gmatch('BR%.Shop%.dress%(') do calls = calls + 1 end
    ok(calls == 3,
        'client/shop.lua declares BR.Shop.dress once and calls it exactly '
            .. 'twice -- the showroom car and the bought car', calls)

    -- ═══ AND NOTHING ABOUT AN APPEARANCE IS ON THE WIRE ═══
    --
    -- The delivery message carries a net id and a catalogue id. If it ever
    -- carried a colour, a mod list or a plate, there would be a second
    -- description of the car in flight -- which is the drift this whole design
    -- exists to make impossible.
    local srv = readFile(RES .. 'br_core/server/shop.lua')
    for _, forbidden in ipairs({ 'primary', 'secondary', 'livery', 'mods',
                                 'plate', 'appearance', 'windowTint' }) do
        ok(srv:find("TriggerClientEvent%('br:shop:dress'[^\n]*" .. forbidden) == nil,
            ('the delivery message does not carry "%s"'):format(forbidden))
    end
    ok(srv:find('BR.ShopSolve.appearance', 1, true) == nil
           and srv:find('SetVehicleMod', 1, true) == nil
           and srv:find('SetVehicleColours', 1, true) == nil,
        'and the server never touches an appearance at all')
end

-- ---------------------------------------------------------------------------
describe('the item')
-- ---------------------------------------------------------------------------
do
    -- Registration is what turns a catalogue row into something the inventory,
    -- the ground, the label and the drop all already know how to handle.
    local before = {}
    for id in pairs(BR.Config.ConsumableById) do before[id] = true end

    local saved = BR.Config.Shop
    BR.Config.Shop = FIXTURE
    FIXTURE.register = saved.register
    FIXTURE.refusedReason = saved.refusedReason
    local rrows = FIXTURE.register(saved.refusedReason)
    BR.Config.Shop = saved

    ok(#rrows == 3, 'registering the fixture registers its three sellable rows')

    local item = BR.Config.ConsumableById['car_runner']
    ok(item ~= nil, 'the Sultan is an ordinary consumable, by item id')
    ok(BR.ShopSolve.itemIdFor(frow('runner')) == 'car_runner',
        'and its item id is derived from the row rather than authored twice')
    ok(('car_runner'):find(':', 1, true) == nil,
        'with no colon in it -- item ids become artwork filenames')

    ok(item.maxStack == 1 and item.carryMax == 1,
        'CARRY ONE, STACK ONE: one purchase is one car')
    ok(type(item.useMs) == 'number' and item.useMs > 0,
        'it declares useMs, which is what makes a consumable usable by hand at '
            .. 'all (server/inventory.lua refuses one that does not)')
    ok(item.shopCar == 'runner',
        'and it names the row that built it, which is how the delivered car is '
            .. 'dressed from the same table the showroom car was')
    ok(item.label == 'Sultan',
        'the label is the owner\'s, not the model string, when he wrote one')

    ok(item.health == nil and item.armour == nil,
        'it heals nothing -- a car is not a potion')

    -- ═══ IN NO RARITY BUCKET, WHICH IS THE CPR KIT'S PATTERN ═══
    --
    -- BR.Config.ConsumablesByRarity is what BR.RollLootStack rolls against.
    -- A car in it would be a car in every crate on the map that rolls its tier.
    local rollable = false
    for _, bucket in pairs(BR.Config.ConsumablesByRarity or {}) do
        for _, c in ipairs(bucket) do
            if c.id == 'car_runner' then rollable = true end
        end
    end
    ok(rollable == false,
        'and it is in NO rarity bucket, so no crate on the map can ever roll a '
            .. 'car')

    -- THE GROUND TOKEN.
    ok(item.prop == 'sultan',
        'dropped, its prop is the CAR -- the owner asked for the vehicle itself')
    ok(item.propScale == 0.1,
        'at a tenth of its authored size, which is what makes it pickup-sized',
        item.propScale)
    ok(item.fallbackMarker == 34,
        'and it carries the owner\'s stated fallback for the case where the '
            .. 'engine will not build a vehicle as an object')

    -- PER-ROW OVERRIDE, because a Sanchez and a Bison are not the same size to
    -- begin with and the scale is a multiple rather than a measurement.
    ok(BR.ShopSolve.tokenScale({ tokenScale = 0.25 }, FIXTURE) == 0.25,
        'a row may override the token scale')
    ok(BR.ShopSolve.tokenScale({}, { tokenScale = 0.2 }) == 0.2,
        'and the catalogue default applies when it does not')

    -- The registration must not have disturbed anything already there.
    ok(BR.Config.ConsumableById['cprkit'] ~= nil
           and BR.Config.ConsumableById['medkit'] ~= nil,
        'registering cars leaves the existing consumables alone')
    ok(before['car_runner'] == nil,
        'and nothing named a car before the fixture was registered')
end

-- ---------------------------------------------------------------------------
describe('the purchase condition')
-- ---------------------------------------------------------------------------
do
    local row = frow('runner')
    local function st(over)
        local s = {
            on = true,
            matchState = BR.MatchState.WARMUP,
            playerState = BR.PlayerState.WARMUP,
            row = row, bought = 0, limit = 1,
            balance = 1000, price = row.price,
        }
        for k, v in pairs(over or {}) do s[k] = v end
        return s
    end

    ok(select(1, BR.ShopSolve.canBuy(st())) == true,
        'a warmup player with the money buys the car')

    -- ═══ WARMUP ON BOTH CLOCKS ═══
    for _, s in ipairs({ BR.MatchState.PLAYING, BR.MatchState.BUS,
                         BR.MatchState.ENDED, BR.MatchState.WAITING }) do
        local can, why = BR.ShopSolve.canBuy(st({ matchState = s }))
        ok(can == false and why == BR.ShopSolve.Refusal.STATE,
            ('the shop is shut once the match is %s'):format(s))
    end
    for _, s in ipairs({ BR.PlayerState.ALIVE, BR.PlayerState.LOBBY,
                         BR.PlayerState.SPECTATING, BR.PlayerState.DEAD }) do
        local can, why = BR.ShopSolve.canBuy(st({ playerState = s }))
        ok(can == false and why == BR.ShopSolve.Refusal.STATE,
            ('and shut to a player who is %s during one'):format(s))
    end

    -- ═══ ONE VEHICLE PER PLAYER PER MATCH ═══
    local can, why = BR.ShopSolve.canBuy(st({ bought = 1 }))
    ok(can == false and why == BR.ShopSolve.Refusal.BOUGHT,
        'a second car is refused -- "no more than 1 vehicle during warmup"')
    ok(select(1, BR.ShopSolve.canBuy(st({ bought = 1, limit = 2 }))) == true,
        'and the limit is a NUMBER in config, so two is one edit away')

    -- ═══ THE PRICE ═══
    can, why = BR.ShopSolve.canBuy(st({ balance = 749 }))
    ok(can == false and why == BR.ShopSolve.Refusal.AFFORD,
        'one Volt short is a refusal')
    ok(select(1, BR.ShopSolve.canBuy(st({ balance = 750 }))) == true,
        'and spending your last Volt is a purchase, not an overdraft')
    ok(BR.ShopSolve.shortfall(749, 750) == 1,
        'the shortfall is what the market\'s existing sentence needs')

    -- PER-MODEL PRICING (answer 2). The Bison is cheaper and it is the ROW that
    -- says so.
    ok(frow('hauler').price == 400 and frow('runner').price == 750,
        'two cars, two prices, both authored')
    ok(select(1, BR.ShopSolve.canBuy(st({ row = frow('hauler'),
                                          price = frow('hauler').price,
                                          balance = 400 }))) == true,
        'and 400 Volts buys the 400-Volt car')
    can, why = BR.ShopSolve.canBuy(st({ row = frow('hauler'),
                                        price = frow('hauler').price,
                                        balance = 399 }))
    ok(can == false and why == BR.ShopSolve.Refusal.AFFORD,
        'but not the 750 one')

    -- A CAR THAT IS NOT FOR SALE.
    --
    -- Built by hand rather than through `st`, because `{ row = nil }` is an
    -- EMPTY TABLE in Lua and the override loop would never see the key -- which
    -- is a test that passes by not testing anything.
    local absent = st()
    absent.row = nil
    can, why = BR.ShopSolve.canBuy(absent)
    ok(can == false and why == BR.ShopSolve.Refusal.NOROW,
        'and naming a car that is not in the catalogue buys nothing')
end

-- ---------------------------------------------------------------------------
-- The server half, driven for real.
-- ---------------------------------------------------------------------------

local roster = {}
local matches = {}
local inv = {}
local dropped = {}
local notices = {}
local charged = {}
local spawned = {}
local spawnFails = false

BR.Server = {
    matchOf = function(src) return roster[src] and matches[roster[src].matchId] end,
    notify = function(src, text, tone)
        notices[#notices + 1] = { src = src, text = text, tone = tone }
    end,
}
BR.Roster = {
    get = function(src) return roster[src] end,
    each = function(pred, fn)
        local ids = {}
        for src in pairs(roster) do ids[#ids + 1] = src end
        table.sort(ids)
        for _, src in ipairs(ids) do
            if pred(roster[src]) then fn(src, roster[src]) end
        end
    end,
}
BR.Market = {
    balances = {},
    balanceOf = function(src) return BR.Market.balances[src] or 0 end,
    tellShortfall = function(src, price)
        notices[#notices + 1] = { src = src, text = 'shortfall', tone = 'warn' }
    end,
    charge = function(src, amount, reason)
        if (BR.Market.balances[src] or 0) < amount then return false, 'poor' end
        BR.Market.balances[src] = BR.Market.balances[src] - amount
        charged[#charged + 1] = { src = src, amount = amount, reason = reason }
        return true, nil
    end,
}
BR.Vehicles = {
    spawnOwned = function(model, vtype, x, y, z, heading, forSrc)
        if spawnFails then return nil, nil, 'the engine refused it (handle 0)' end
        spawned[#spawned + 1] = {
            model = model, vtype = vtype, x = x, y = y, z = z,
            heading = heading, forSrc = forSrc,
        }
        return 500 + #spawned, 9000 + #spawned, nil
    end,
}
BR.Inv = {
    give = function(src, stack)
        inv[src] = inv[src] or {}
        if #inv[src] >= 5 then return false, nil, 'carrymax' end
        inv[src][#inv[src] + 1] = stack
        return true, nil, nil
    end,
}
BR.Loot = {
    dropForPlayer = function(src, stack)
        dropped[#dropped + 1] = { src = src, stack = stack }
    end,
}

-- THE FIXTURE IS INSTALLED AS THE CONFIG BEFORE server/shop.lua RESOLVES IT.
-- Everything below therefore exercises the real handler against three cars that
-- exist rather than against a shipped table that is empty on purpose.
local shipped = BR.Config.Shop
FIXTURE.register       = shipped.register
FIXTURE.refusedReason  = shipped.refusedReason
BR.Config.Shop = FIXTURE

loadCore('br_core/server/shop.lua')
handlers['onResourceStart']('br_core')

local function reset()
    sent, notices, charged, spawned, dropped = {}, {}, {}, {}, {}
    inv, roster, matches, peds = {}, {}, {}, {}
    BR.Market.balances = {}
    spawnFails = false
end

local function player(src, opts)
    opts = opts or {}
    matches[1] = matches[1] or { id = 1, state = BR.MatchState.WARMUP }
    roster[src] = {
        matchId = 1,
        state = opts.state or BR.PlayerState.WARMUP,
        pos = { x = 0.0, y = 0.0, z = 30.0 },
    }
    peds[src] = { ped = 900 + src, x = 0.0, y = 0.0, z = 30.0, heading = 0.0 }
    BR.Market.balances[src] = opts.balance or 1000
end

local function buy(src, id)
    _G.source = src
    handlers['br:shop:buy']({ id = id })
end

-- ---------------------------------------------------------------------------
describe('buying, for real')
-- ---------------------------------------------------------------------------
do
    reset()
    player(10)
    buy(10, 'runner')

    ok(#charged == 1 and charged[1].amount == 750,
        'the purchase charges the price off the ROW, not off anything the '
            .. 'client sent', charged[1] and charged[1].amount)
    ok(roster[10].shopBuy ~= nil and roster[10].shopBuy.row == 'runner'
           and roster[10].shopBuy.matchId == 1,
        'and the purchase is recorded against this match')

    -- ═══ THE OWNER'S SENTENCE, VERBATIM ═══
    ok(#notices == 1 and notices[1].text ==
        'Thanks for your purchase. It will be available in your inventory '
        .. 'once the match starts.',
        'the toast is the owner\'s wording, exactly',
        notices[1] and notices[1].text)

    ok(#sent == 1 and sent[1].name == 'br:shop:bought',
        'and the client is told, so it can play the existing pickup cue')

    -- A SECOND CAR IS REFUSED AND COSTS NOTHING.
    buy(10, 'hauler')
    ok(#charged == 1, 'a second purchase charges nothing at all', #charged)
    ok(roster[10].shopBuy.row == 'runner',
        'and does not overwrite the first')

    -- A CLIENT NAMING A CAR THAT IS NOT FOR SALE.
    reset()
    player(11)
    buy(11, 'cheat')          -- the banned row
    ok(#charged == 0 and roster[11].shopBuy == nil,
        'the banned model cannot be bought even by naming it directly')
    buy(11, 'nonesuch')
    ok(#charged == 0, 'nor can a car that was never in the catalogue')

    -- MONEY.
    reset()
    player(12, { balance = 749 })
    buy(12, 'runner')
    ok(#charged == 0 and roster[12].shopBuy == nil,
        'a player one Volt short buys nothing')
    ok(#notices == 1 and notices[1].text == 'shortfall',
        'and is told in the market\'s own words rather than in invented ones')

    -- STATE.
    reset()
    player(13)
    matches[1].state = BR.MatchState.PLAYING
    buy(13, 'runner')
    ok(#charged == 0, 'and the shop is shut once the bus has gone')
end

-- ---------------------------------------------------------------------------
describe('delivery')
-- ---------------------------------------------------------------------------
do
    reset()
    player(20)
    player(21)
    buy(20, 'runner')

    BR.Shop.deliver(matches[1])

    ok(inv[20] ~= nil and #inv[20] == 1
           and inv[20][1].item == 'car_runner'
           and inv[20][1].kind == BR.ItemKind.CONSUMABLE
           and inv[20][1].count == 1,
        'the buyer gets exactly one car item when the match starts')
    ok(inv[21] == nil, 'and the player who bought nothing gets nothing')

    -- ONCE. A delivery that ran twice would be two cars for one payment.
    BR.Shop.deliver(matches[1])
    ok(#inv[20] == 1, 'delivering twice delivers once', #inv[20])

    -- ═══ AND IT IS DROPPED AT THEIR FEET IF THE BAG IS FULL (answer 4) ═══
    reset()
    player(22)
    buy(22, 'runner')
    inv[22] = { 1, 2, 3, 4, 5 }        -- five slots, all taken
    BR.Shop.deliver(matches[1])
    ok(#dropped == 1 and dropped[1].src == 22
           and dropped[1].stack.item == 'car_runner',
        'a full inventory puts the car on the ground rather than losing it')

    -- ═══ THE ORDERING IN match.onEnter(BUS) ═══
    --
    -- Unobservable in game: one line the wrong way round and the purchase
    -- silently never arrives, which looks exactly like the purchase failing.
    local mtc = readFile(RES .. 'br_core/server/match.lua')
    local wipe = mtc:find('BR%.Inv%.clearFor%(m%)')
    local hand = mtc:find('BR%.Shop%.deliver%(m%)')
    ok(wipe ~= nil and hand ~= nil and hand > wipe,
        'the car is handed out AFTER the warmup inventory wipe, or the wipe '
            .. 'deletes the thing the player paid for')

    local busAt = mtc:find('elseif state == BR%.MatchState%.BUS then')
    local playAt = mtc:find('elseif state == BR%.MatchState%.PLAYING then')
    ok(busAt ~= nil and playAt ~= nil and hand > busAt and hand < playAt,
        'and it happens on the BUS transition -- "once the match starts"')
end

-- ---------------------------------------------------------------------------
describe('unpacking, and the absence of a refund')
-- ---------------------------------------------------------------------------
do
    reset()
    player(30)
    peds[30].heading = 0.0

    ok(BR.Shop.unpack(30, 'runner') == true, 'using the item builds the car')
    ok(#spawned == 1 and spawned[1].model == 'sultan'
           and spawned[1].vtype == 'automobile' and spawned[1].forSrc == 30,
        'through BR.Vehicles.spawnOwned, in the buyer\'s routing bucket')
    ok(math.abs(spawned[1].y - 5.0) < 0.001 and math.abs(spawned[1].x) < 0.001,
        'five metres in front of them rather than on top of them',
        spawned[1].x .. ' / ' .. spawned[1].y)
    ok(math.abs(spawned[1].heading - peds[30].heading) < 0.001,
        'facing the way they are facing, because they are about to be sitting '
            .. 'in it')

    local dress = nil
    for _, s in ipairs(sent) do if s.name == 'br:shop:dress' then dress = s end end
    ok(dress ~= nil and dress.src == 30 and dress.payload.row == 'runner'
           and dress.payload.n == 9001,
        'and the client is handed a net id and a CATALOGUE ID')

    -- THE WIRE CARRIES NOTHING ELSE. Two keys: the id and the row.
    local keys = 0
    for _ in pairs(dress.payload) do keys = keys + 1 end
    ok(keys == 2, 'those two things and nothing else', keys)

    -- ═══ A VANISHED CAR GETS NOTHING (answer 3) ═══
    reset()
    player(31)
    spawnFails = true
    ok(BR.Shop.unpack(31, 'runner') == false,
        'a spawn the engine refuses answers false')
    ok(#dropped == 0 and (inv[31] == nil or #inv[31] == 0),
        'and NOTHING is given back -- no refund, no replacement item')
    ok(#charged == 0, 'and no Volts are returned either')

    local none = nil
    for _, s in ipairs(sent) do if s.name == 'br:shop:dress' then none = s end end
    ok(none == nil, 'and no client is told to dress a car that does not exist')

    -- AN ITEM FOR A ROW THAT NO LONGER EXISTS.
    reset()
    player(32)
    ok(BR.Shop.unpack(32, 'nonesuch') == false and #spawned == 0,
        'and an item naming a row that is gone builds nothing')

    -- ═══ THE ITEM IS SPENT BEFORE THE SPAWN IS ATTEMPTED ═══
    --
    -- server/inventory.lua consumes the stack and THEN asks the shop, which is
    -- the opposite of the ambulance's ordering and is deliberate: a use that put
    -- the item back on a failed spawn is a use a player repeats until the engine
    -- cooperates, which is a second car for one payment.
    local invsrc = readFile(RES .. 'br_core/server/inventory.lua')
    local consume = invsrc:find('s%.count = s%.count %- 1')
    local ask = invsrc:find('BR%.Shop%.unpack')
    ok(consume ~= nil and ask ~= nil and ask > consume,
        'the slot is emptied before BR.Shop.unpack is called')
end

-- ---------------------------------------------------------------------------
describe('the dropped token')
-- ---------------------------------------------------------------------------
do
    -- The marker fallback is a client render decision and cannot be driven from
    -- here, so this asserts the two halves that make it reachable: that a
    -- failed prop is LATCHED, and that the latch is what the renderer reads.
    local lootsrc = readFile(RES .. 'br_core/client/loot.lua')

    ok(lootsrc:find('local function fallbackMarkerOf', 1, true) ~= nil,
        'client/loot.lua knows how to look a fallback marker up')
    ok(lootsrc:find('noProp%(e, .the engine refused to build it as an object.')
           ~= nil,
        'and marks an entry whose prop the engine would not build')
    ok(lootsrc:find('not isTrue%(IsModelValid%(model%)%)') ~= nil,
        'and one whose model this build does not have -- through isTrue, '
            .. 'because 0 IS TRUTHY and a raw read would never fire')
    ok(lootsrc:find('e%.noProp and fallbackMarkerOf%(e%)') ~= nil,
        'and the renderer draws that marker in place of the rarity disc')

    -- THE NUMBER IS THE OWNER'S, PASSED THROUGH. Nothing in this tree claims to
    -- know what marker 34 draws.
    ok(BR.Config.Shop.tokenMarker == 34,
        'and the number is 34, which is the one he named')
end

-- ---------------------------------------------------------------------------
describe('the sound and the words')
-- ---------------------------------------------------------------------------
do
    -- ═══ NO NEW AUDIO CUE ═══
    --
    -- config/audio.lua's rule: two actions that sound identical are worse than
    -- one that sounds wrong. A purchase IS something landing in an inventory,
    -- so it is the pickup cue and there is nothing new to audition.
    local cli = readFile(RES .. 'br_core/client/shop.lua')

    -- ═══ THE SAME TABLE, NOT A SECOND PAIR ═══
    --
    -- The cue is installed by BR.Config.Shop.register as a REFERENCE to
    -- BR.Config.Loot.pickupSound. `==` on tables is identity in Lua, so this
    -- fails the day somebody "tidies" it into a copy -- which is the edit that
    -- would let the two drift the next time the owner re-points the pickup
    -- sound.
    ok(shipped.cue == 'shop.buy',
        'the shipped config names one cue key')
    ok(BR.Config.Audio.cues['shop.buy'] == BR.Config.Loot.pickupSound,
        'and the shop cue IS BR.Config.Loot.pickupSound -- the same table, not '
            .. 'a copy of its two strings')
    ok(BR.Config.Loot.pickupSound.name == 'PICK_UP'
           and BR.Config.Loot.pickupSound.set == 'HUD_FRONTEND_DEFAULT_SOUNDSET',
        'which is PICK_UP / HUD_FRONTEND_DEFAULT_SOUNDSET')

    -- ═══ REACHED BY KEY, SO /brsfx CAN AUDITION IT ═══
    --
    -- tools/verify.sh refuses a set/name pair written at a call site outside
    -- three files; this is the positive form of that rule.
    ok(cli:find('BR%.Sfx%.play%(S%.cue%)') ~= nil,
        'and the client plays it by cue KEY rather than by naming the pair')
    ok(cli:find('PlaySoundFrontend') == nil
           and cli:find('PlaySoundFromEntity') == nil,
        'client/shop.lua names no audio native at all')

    -- ═══ THREE STRINGS, AND THE OWNER WROTE ALL OF THEM ═══
    --
    -- His standing rule is that unrequested copy reads as slop. The toast and
    -- the plate are quoted verbatim; the price is a bare number.
    ok(BR.Config.Shop.boughtToast ==
        'Thanks for your purchase. It will be available in your inventory '
        .. 'once the match starts.',
        'the toast, verbatim')
    ok(BR.Config.Shop.signLabel == '%s for sale',
        'and the plate says "[model name] for sale"')
    ok(BR.Config.Shop.signLabel:format('Sultan') == 'Sultan for sale',
        'which with a name in it reads the way he wrote it')

    -- THE PRICE IS A BARE NUMBER on the second line -- no unit, no verb, no
    -- "press E to buy" of our own invention.
    ok(cli:find('hint%s*=%s*tostring%(math%.floor') ~= nil,
        'the price is rendered as a bare number and nothing else')

    -- NOTHING ELSE IS SPOKEN. Every notify/refuse this feature can reach is
    -- either the toast or the market's own existing sentence.
    local srv = readFile(RES .. 'br_core/server/shop.lua')
    local speaks = 0
    for _ in srv:gmatch('BR%.Server%.notify%(') do speaks = speaks + 1 end
    ok(speaks == 1,
        'server/shop.lua says exactly one thing to a player, and it is his '
            .. 'sentence', speaks)
end

-- ---------------------------------------------------------------------------
describe('the showroom')
-- ---------------------------------------------------------------------------
do
    local cli = readFile(RES .. 'br_core/client/shop.lua')

    -- ═══ THE OWNER'S THREE WORDS ═══
    ok(cli:find('SetVehicleDoorsLocked', 1, true) ~= nil,
        'the display cars have their doors locked')
    ok(cli:find('SetEntityInvincible', 1, true) ~= nil,
        'are invincible')
    ok(cli:find('FreezeEntityPosition', 1, true) ~= nil,
        'and have their position frozen')
    ok(BR.Config.Shop.lockedState == 2,
        'lock state 2 (LOCKED), not 4 (LOCKED_PLAYER_INSIDE) -- 4 waits for an '
            .. 'entry that never happens and client/rescue.lua shipped it once')

    -- ═══ LOCAL, NEVER NETWORKED ═══
    --
    -- Two `false`s in the last two positions. A networked client-created vehicle
    -- is refused by sv_entityLockdown before any of our code runs, and the
    -- refusal is SILENT.
    ok(cli:find('false, false%)') ~= nil,
        'and they are created local and non-networked, like the Battle Bus')

    -- ...WHICH IS ALSO WHY THE VERIFY GATE IS NOT TRIPPED. Server-side vehicle
    -- creation is refused outside br_core/server/vehicles.lua; the showroom
    -- never asks for one.
    local srv = readFile(RES .. 'br_core/server/shop.lua')
    -- THE CALL, NOT THE WORD. tools/verify.sh matches
    -- `CreateVehicle(ServerSetter)?\s*\(` in any server file outside
    -- vehicles.lua, so the thing to assert absent is the CALL -- prose about
    -- why the call is not here is exactly what this file should contain.
    ok(srv:find('CreateVehicle%s*%(') == nil
           and srv:find('CreateVehicleServerSetter%s*%(') == nil,
        'server/shop.lua creates no vehicle itself -- it asks '
            .. 'BR.Vehicles.spawnOwned, which is where the allowlist lives')
    ok(srv:find('BR%.Vehicles%.spawnOwned') ~= nil,
        'and that is the only creation path it has')

    -- ONE BROWSER. A DUI is a whole CEF instance and this is the fifth consumer
    -- of the one prompt page, not a sixth browser.
    local pages = 0
    for _ in cli:gmatch('BR%.Dui%.page%(') do pages = pages + 1 end
    ok(pages == 1 and cli:find("'lootprompt'", 1, true) ~= nil,
        'and the plate borrows the one shared prompt page', pages)
end

print(('\n\27[32m%d passed\27[0m'):format(pass))
if fail > 0 then
    print(('\27[31m%d failed\27[0m'):format(fail))
    os.exit(1)
end
