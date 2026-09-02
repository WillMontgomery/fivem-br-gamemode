-- The warmup vehicle shop, as pure functions (#224).
--
-- NO NATIVES, NO STATE, NO SIDE EFFECTS. Everything here is arithmetic over
-- tables, which is what lets tools/test_shop.lua run it -- and it is also what
-- makes the ONE promise this feature rests on checkable:
--
--   ═══ "THE VEHICLE WHICH SPAWNS FROM THEIR INVENTORY MUST BE EXACTLY AS SHOWN
--       WHEN THEY PURCHASED IT" (owner, 2026-08-29) ═══
--
-- There were two ways to keep that promise and only one of them is a property
-- rather than a hope:
--
--   READ IT OFF THE DISPLAY CAR AT PURCHASE TIME and replay it later. The
--   showroom entity becomes the source of truth, its appearance is serialised
--   into the item, and the delivered car is built from that recording. This is
--   the tempting one and it is REJECTED. It creates a SECOND REPRESENTATION of
--   one fact -- the authored row and the recording taken from an entity built
--   out of it -- and this repository's signature defect is exactly that: two
--   representations of one fact drifting apart. It also cannot be tested
--   without a running game, because the recording only exists on a client.
--
--   BUILD BOTH CARS FROM THE SAME ROW. The display vehicle and the purchased
--   vehicle are dressed by ONE function over ONE table, so there is no second
--   representation to drift from. `BR.ShopSolve.appearance` below is that
--   table's canonical form: whatever the owner writes in config/shop.lua, both
--   ends read the output of this function and never the row directly.
--
-- ═══ AND THE COLOURS ARE ROLLED NOW, WHICH DID NOT CHANGE THAT ARGUMENT --
--     IT ADDED ONE NUMBER TO IT (owner, 2026-08-31) ═══
--
-- "can you make the vehicles in the shop spawn with random colors each time
--  they are spawned? except the ambulance. that one has a livery so color won't
--  matter."
--
-- The rejected option came back wearing new clothes the moment that landed:
-- READ THE COLOUR OFF THE DISPLAY CAR AT THE PRESS and carry it on the item. It
-- is rejected for the identical reason, plus a new one -- a colour riding an
-- inventory stack has to survive the bag, the ground, a pickup by somebody else
-- and the NUI mirror, which is four subsystems that would each have to be right
-- about a fact none of them cares about.
--
-- SO THE ROLL IS A FUNCTION, NOT A RECORDING. `BR.ShopSolve.paint` below takes
-- a row and ONE INTEGER SEED and answers a paint index, deterministically. The
-- server owns that seed, holds it on the match, and it does not move for the
-- life of that match -- so the showroom car and the car that comes out of the
-- item are STILL the same computation run twice, and there is still nothing to
-- keep in sync. What a capture would have bought -- "the colour it was wearing
-- when I pressed" -- is bought instead by the seed being immutable: a rebuild
-- mid-warmup cannot re-roll a car somebody is standing in front of, because
-- there is no roll left to make.
--
-- THE APPEARANCE STILL NEVER TRAVELS OVER THE WIRE, and that is the other half.
-- The purchase, the inventory item, the drop and the use carry an ITEM ID; the
-- delivery carries a net id, a catalogue id and the SEED. Not one colour, mod,
-- livery or plate crosses in any direction, and nothing about paint is ever
-- sent client -> server at all. A client that has the config -- every client
-- does; config/ is a shared_script -- reconstructs the whole car from the id and
-- that one number, so the gap between warmup and the moment somebody unpacks the
-- item mid-match carries no state that could be lost, truncated or edited in
-- flight. The display entity is long gone by then and it does not matter,
-- because it was never consulted.

BR = BR or {}
BR.ShopSolve = {}

--- The inventory item id a catalogue row is sold as.
---
--- ONE PREFIX, DERIVED, NEVER AUTHORED. The owner writes `id = 'sultan'` in the
--- catalogue and the item id is computed from it, so a row and its item cannot
--- be given different names by an edit to one of them. The prefix keeps the
--- namespace clear of BR.Config.Consumables, which the shop registers alongside.
---
--- NO COLON, AND THAT IS NOT COSMETIC. Item ids reach br_ui as artwork paths
--- (`ui/items/<id>.png`); a colon is not a legal filename character on every
--- platform this project is developed on, and the failure would be a silently
--- missing icon rather than an error.
--- @param row table
--- @return string|nil
function BR.ShopSolve.itemIdFor(row)
    if type(row) ~= 'table' then return nil end
    local id = row.id
    if type(id) ~= 'string' or id == '' then return nil end
    return 'car_' .. id
end

--- The number of shop rows there are, whatever shape the config is in.
--- @param cfg table|nil
--- @return integer
function BR.ShopSolve.count(cfg)
    local items = cfg and cfg.items
    if type(items) ~= 'table' then return 0 end
    return #items
end

--- Is the shop a thing at all right now?
---
--- WITH NO CATALOGUE THE FEATURE IS INERT RATHER THAN BROKEN. This is
--- BR.Config.Rescue.points' rule applied to a second feature, and for the same
--- reason: the owner authors the data in game and it is not written yet. An
--- empty catalogue must produce a warmup with no shop in it -- no display cars,
--- no prompt, no purchase handler doing anything, and above all no error. Every
--- reader below asks this first.
--- @param cfg table|nil
--- @return boolean
function BR.ShopSolve.enabled(cfg)
    if type(cfg) ~= 'table' then return false end
    if cfg.enabled == false then return false end
    return BR.ShopSolve.count(cfg) > 0
end

--- Is one authored row usable?
---
--- ═══ THE BANNED-MODEL CHECK IS THE SAFETY MECHANISM'S SECOND HALF, NOT ITS
---     FIRST ═══
---
--- config/vehicles.lua lists vehicles that are REFUSED -- anything that flies or
--- carries built-in weapons -- and BR.Vehicles.spawnOwned already refuses one
--- before it creates anything. This check is EARLIER and LOUDER: a refused model
--- in the catalogue would otherwise be a car that stands in the showroom, wears
--- a price, takes a player's Volts and then cannot be delivered. The purchase
--- would succeed and the goods would not exist, and answer 3 says a purchase is
--- never refunded. So a refused row is removed from the catalogue at load, and
--- the console says which row and why.
---
--- IT IS NOT THE WHOLE OF THE FAIRNESS RULE AND MUST NOT BE MISTAKEN FOR IT.
--- See the header of config/shop.lua: the ban list bounds what is legal, the
--- OWNER'S CHOICE OF MODELS bounds what is fair, and only the first of those two
--- is a thing code can check.
---
--- @param row table|nil
--- @param refusedReason fun(model:string):string|nil  nil when the model is fine
--- @return boolean ok
--- @return string|nil why
function BR.ShopSolve.validateRow(row, refusedReason)
    if type(row) ~= 'table' then return false, 'not a table' end
    if not BR.ShopSolve.itemIdFor(row) then return false, 'no id' end
    if type(row.model) ~= 'string' or row.model == '' then
        return false, 'no model'
    end
    local price = tonumber(row.price)
    if not price or price <= 0 or price ~= math.floor(price) then
        return false, 'price must be a positive whole number'
    end
    if type(row.x) ~= 'number' or type(row.y) ~= 'number'
       or type(row.z) ~= 'number' then
        return false, 'no coordinates'
    end
    if refusedReason then
        local why = refusedReason(row.model)
        if why then return false, ('model is refused: %s'):format(why) end
    end
    return true, nil
end

--- The usable catalogue, and everything thrown out of it.
---
--- TWO RETURNS RATHER THAN ONE FILTERED LIST, because a row that was silently
--- dropped is a car the owner authored, cannot see, and has no way to ask about.
--- The caller prints the rejects once at load.
--- @param cfg table|nil
--- @param refusedReason fun(model:string):string|nil
--- @return table rows
--- @return table rejects   { { id, why } }
function BR.ShopSolve.catalogue(cfg, refusedReason)
    local rows, rejects = {}, {}
    if type(cfg) ~= 'table' or type(cfg.items) ~= 'table' then
        return rows, rejects
    end

    local seen = {}
    for i = 1, #cfg.items do
        local row = cfg.items[i]
        local ok, why = BR.ShopSolve.validateRow(row, refusedReason)
        local id = BR.ShopSolve.itemIdFor(row)
        if ok and id and seen[id] then
            ok, why = false, 'duplicate id'
        end
        if ok then
            seen[id] = true
            rows[#rows + 1] = row
        else
            rejects[#rejects + 1] = {
                id = (type(row) == 'table' and tostring(row.id)) or ('#' .. i),
                why = why or 'unusable',
            }
        end
    end
    return rows, rejects
end

--- One row by its ITEM id (not its catalogue id).
--- @param rows table
--- @param itemId string|nil
--- @return table|nil
function BR.ShopSolve.rowByItem(rows, itemId)
    if type(rows) ~= 'table' or type(itemId) ~= 'string' then return nil end
    for i = 1, #rows do
        if BR.ShopSolve.itemIdFor(rows[i]) == itemId then return rows[i] end
    end
    return nil
end

--- One row by its CATALOGUE id, which is what a client names in a purchase.
--- @param rows table
--- @param id any
--- @return table|nil
function BR.ShopSolve.rowById(rows, id)
    if type(rows) ~= 'table' or type(id) ~= 'string' then return nil end
    for i = 1, #rows do
        if type(rows[i]) == 'table' and rows[i].id == id then return rows[i] end
    end
    return nil
end

--- WHICH CAR IS THE PLAYER STANDING AT? THE NEAREST ONE IN REACH, NEVER "ONE OF
--- THE ONES IN REACH".
---
--- ═══ AT THE OWNER'S SPACING NO RADIUS CAN TELL TWO CARS APART, SO DISTANCE
---     ORDER HAS TO ═══
---
--- The surveyed showroom (2026-08-29) puts its tightest pair -- `sanchez` and
--- `outlaw` -- 3.25m apart, and nine other pairs are inside 4.5m. The midpoint
--- between two cars 3.25m apart is 1.63m from each, so a reach small enough to
--- put only ONE of them in range would have to be under 1.63m: inside the
--- bodywork of both, and unusable. THERE IS NO VALUE OF `reachM` THAT MAKES
--- "in reach" MEAN "the one car I am at" on this pad.
---
--- So the radius is not what picks the car. It answers one question -- am I at
--- the showroom at all -- and the ORDERING answers the other. Standing between
--- two cars is then not a coin flip but the obvious answer: the nearer one.
--- #128 is the same defect one system over (two crates in reach, a press that
--- claimed the other), and the fix there was the same fix: resolve once, to the
--- nearest.
---
--- ═══ A FLAT SWEEP, AND NO ASSUMPTION THAT THE SHOWROOM IS ONE CLUSTER ═══
---
--- Every row is measured, every call. There is no spatial index, no "start from
--- the last answer and walk outwards", and no early exit on the first row in
--- range -- all three would be an assumption that the catalogue is contiguous,
--- and it is not: `veto` stands 154m from the other twelve, exactly where the
--- owner put it. At thirteen rows on the tick band a full sweep is free, and it
--- is correct for a catalogue of any shape.
---
--- 2-D, LIKE EVERY OTHER REACH IN THIS PROJECT. The pad is flat (his z values
--- span one metre) and a player on a kerb beside a car is still at that car.
---
--- TIES GO TO THE EARLIER ROW. `<` rather than `<=`, so two cars at the same
--- distance resolve to the one written first in the catalogue -- an arbitrary
--- rule, but a STABLE one, and a stable answer is what stops the plate flipping
--- between two cars while a player stands still.
---
--- @param rows table          the resolved catalogue
--- @param px number           the player, x
--- @param py number           the player, y
--- @param reachM number|nil   how far "at a car" reaches; nil is no reach at all
--- @param present fun(row:table):boolean|nil  optional: is this car actually
---        standing? The client passes its DoesEntityExist check, so a row whose
---        model never streamed cannot be offered for sale.
--- @return table|nil row      the nearest row in reach, or nil
--- @return number|nil dist    how far away it is
function BR.ShopSolve.nearest(rows, px, py, reachM, present)
    if type(rows) ~= 'table' then return nil, nil end
    px, py = tonumber(px), tonumber(py)
    if not px or not py then return nil, nil end
    local reach = tonumber(reachM)
    if not reach or reach <= 0.0 then return nil, nil end

    local best, bestD = nil, nil
    for i = 1, #rows do
        local row = rows[i]
        if type(row) == 'table'
           and type(row.x) == 'number' and type(row.y) == 'number'
           and (present == nil or present(row) == true) then
            local d = BR.Dist(px, py, row.x, row.y)
            if d <= reach and (bestD == nil or d < bestD) then
                best, bestD = row, d
            end
        end
    end
    return best, bestD
end

--- The name this car is sold under.
---
--- `label` IF THE OWNER WROTE ONE, THE MODEL OTHERWISE. The DUI says
--- "[model name] for sale", and GTA's own display names live in a GXT table this
--- server cannot read -- so the honest default is the model string he typed, and
--- `label` is there for when he wants "Sultan RS" rather than `sultanrs`.
--- @param row table|nil
--- @return string
function BR.ShopSolve.nameOf(row)
    if type(row) ~= 'table' then return '' end
    if type(row.label) == 'string' and row.label ~= '' then return row.label end
    return tostring(row.model or '')
end

--- The plate's second line: the price, then what the currency is called.
---
--- ═══ THE WORD COMES FROM CONFIG, NOT FROM HERE ═══
---
--- Owner, 2026-08-29: 'Change the green line to say "x Volts"'. It used to be a
--- bare number, and the note that said so was right at the time -- "adding a
--- word to it would be copy nobody asked for" -- so the word is now asked for
--- and the number is no longer bare.
---
--- `BR.Config.Market.currency` IS THE ONE PLACE THAT STRING LIVES, and its own
--- comment says renaming the currency is that line plus the matching constant in
--- Ringmaster. Writing "Volts" here would make it that line, the Ringmaster
--- constant, AND a client file nobody would think to grep -- so the caller
--- passes it in and this function never spells it.
---
--- NO CURRENCY, NO WORD. A caller that cannot resolve the name gets the bare
--- number back rather than the price followed by nothing or by a placeholder.
--- @param price number|nil
--- @param currency string|nil
--- @return string
function BR.ShopSolve.priceLine(price, currency)
    local n = math.floor(tonumber(price) or 0)
    local word = type(currency) == 'string' and currency or ''
    if word == '' then return tostring(n) end
    return ('%d %s'):format(n, word)
end

--- What the purchase toast says: his sentence, then his balance sentence.
---
--- ═══ "SHOULD ALSO INCLUDE A NOTE ABOUT THEIR NEW BALANCE" (#239) ═══
---
--- Owner, 2026-08-30: "'Thank you for your purchase.' toast should also include
--- a note about their new balance, stated as 'Your new balance is: [X] Volts.'"
---
--- BOTH SENTENCES ARE AUTHORED IN config/shop.lua and neither is written here.
--- This function does the joining and nothing else, and it is in br_lib so the
--- joining is a thing a test can run -- the alternative is a concatenation in
--- server/shop.lua, where the only way to see what a player reads is to buy a
--- car in a running game.
---
--- THE FIGURE GOES THROUGH priceLine, so the number and the currency word are
--- spaced and floored by the same function that spaces and floors the price on
--- the plate. A balance and a price that disagreed about their own formatting
--- would be two representations of one rule.
---
--- A TEMPLATE THAT WILL NOT TAKE A STRING LEAVES THE TOAST ALONE. `balanceToast`
--- is authored, so a `%d` in it is an authoring slip rather than a runtime
--- condition -- but string.format would THROW on it, inside the charge callback,
--- after the money has left the row. The purchase must not be the thing that
--- breaks, so a bad template costs the second sentence and nothing else.
--- @param cfg table|nil       BR.Config.Shop
--- @param balance number|nil  what the row holds AFTER the debit
--- @param currency string|nil
--- @return string
function BR.ShopSolve.boughtToast(cfg, balance, currency)
    local c = type(cfg) == 'table' and cfg or {}
    local bought = type(c.boughtToast) == 'string' and c.boughtToast or ''
    local tmpl   = type(c.balanceToast) == 'string' and c.balanceToast or ''
    if tmpl == '' then return bought end

    local okFmt, line = pcall(string.format, tmpl,
                              BR.ShopSolve.priceLine(balance, currency))
    if not okFmt or type(line) ~= 'string' then return bought end
    if bought == '' then return line end
    return bought .. ' ' .. line
end

--- How high up the car its price plate hangs, in metres from the model origin.
---
--- ═══ "CHANGE THE DUI TO DRAW AT THE ELEVATION OF THE VEHICLE'S BUMPER"
---     (owner, 2026-08-29) ═══
---
--- IT USED TO BE ONE AUTHORED NUMBER, `signLift = 1.15`, measured from the
--- model's own origin -- which is a height that suits a saloon and nothing else.
--- The catalogue runs from a `sanchez` to a `marshall`, and a monster truck's
--- bumper is more than a metre above a dirt bike's: one constant cannot be at
--- both, so at 1.15 the plate floated over the bike and sat inside the truck.
---
--- ═══ SO IT IS READ OFF THE MODEL, AND THE ONLY AUTHORED NUMBER IS A SHAPE ═══
---
--- GetModelDimensions hands back the model's bounding box, and the bumper's
--- height is a FRACTION of that box rather than a distance from anything: the
--- box's floor is where the tyres meet the road, its ceiling is the roof, and
--- every road vehicle wears its bumper low in that span. One fraction is
--- thirteen fewer numbers for the owner to tune, and it scales with the model
--- instead of being contradicted by it.
---
--- `lift` IS THE NUDGE HE KEEPS. It is added after the derivation, in metres, so
--- moving every plate up or down is still one number -- it is just no longer the
--- number that has to know how tall a marshall is.
---
--- NOT CLAMPED INTO THE BOX. A negative `lift` large enough to put the plate
--- underground is a value somebody typed on purpose while tuning, and silently
--- refusing it would look exactly like the setting not working.
---
--- @param minZ number|nil  the model box's floor, from GetModelDimensions
--- @param maxZ number|nil  its ceiling
--- @param frac number|nil  where the bumper sits in that span, 0 = floor
--- @param lift number|nil  metres added afterwards
--- @return number
function BR.ShopSolve.signHeight(minZ, maxZ, frac, lift)
    local lo = tonumber(minZ)
    local hi = tonumber(maxZ)
    local f  = tonumber(frac) or 0.35
    local l  = tonumber(lift) or 0.0

    -- NO BOX, NO DERIVATION. GetModelDimensions answers zeroes for a model that
    -- is not loaded, and a plate at the origin is better than a plate at nan.
    if not lo or not hi then return l end
    -- A box the wrong way up is a model table this code cannot reason about;
    -- the span is taken as a magnitude so the answer stays inside it either way.
    if hi < lo then lo, hi = hi, lo end

    return lo + (hi - lo) * f + l
end

-- ---------------------------------------------------------------------------
-- The roll
-- ---------------------------------------------------------------------------

--- Does this row take a rolled colour, or does it keep the one he authored?
---
--- ═══ AN OPT-OUT, NOT AN OPT-IN, AND THE POLARITY IS THE OWNER'S SENTENCE ═══
---
--- "make the vehicles in the shop spawn with random colors [...] except the
--- ambulance" -- so the rule is the default and the exception is the exception.
--- A row added next month is randomised because nobody had to remember to say
--- so, which is the opposite of what an opt-in flag would have shipped: a
--- fourteenth car standing in preset 1 beside thirteen rolled ones, with nothing
--- to say why.
---
--- `randomColour = false` IS THE ONLY SPELLING THAT TURNS IT OFF. nil is on,
--- true is on, and anything else is on -- an equality rather than a truth test,
--- because the field is authored by hand and a typo must not silently pin a
--- car's colour.
--- @param row table|nil
--- @return boolean
function BR.ShopSolve.randomises(row)
    if type(row) ~= 'table' then return false end
    return row.randomColour ~= false
end

--- One row's own 32-bit seed, folded from the match seed and its id.
---
--- FNV-1a, BY ID RATHER THAN BY POSITION. A per-index derivation would repaint
--- every car below any row the owner inserts or deletes, so a catalogue edit
--- would look like a bug in the roll. The id is the stable thing about a row --
--- it is already what the item, the purchase and the delivery are keyed on.
--- @param seed integer
--- @param id string
--- @return integer
local function fold(seed, id)
    local h = 2166136261
    for i = 1, #id do
        h = (h ~ id:byte(i)) & 0xFFFFFFFF
        h = (h * 16777619) & 0xFFFFFFFF
    end
    return (seed + h) & 0xFFFFFFFF
end

--- The paint index one row wears under one seed, or nil for "use the row".
---
--- ═══ PURE, SO BOTH ENDS CAN RUN IT AND NEITHER HAS TO BE TOLD THE ANSWER ═══
---
--- The server holds the seed and hands it out; the client derives the colour
--- from it. That is BR.Rng's whole reason for existing -- "the server and client
--- must be able to derive the identical loot layout from a single shared seed"
--- -- and it is why the wire carries one integer instead of thirteen colours.
---
--- IT IS ALSO WHY NOTHING ABOUT PAINT TRAVELS CLIENT -> SERVER. A client never
--- names a colour, never names a seed, and is never asked: it receives one and
--- derives. A modified client can of course repaint a vehicle it controls -- it
--- always could, and appearance has never been a boundary here -- but it cannot
--- make the SERVER agree, and the delivered car is dressed from the server's
--- number on every honest machine.
---
--- NIL ON EVERY ABSENCE, RATHER THAN A DEFAULT. No seed, no palette, an empty
--- palette, a row that opted out: all four mean "this car wears what
--- config/shop.lua says", which is the behaviour that shipped before the roll
--- and is a far better failure than a car with no colour at all.
--- @param row table|nil
--- @param seed integer|nil    the match's paint seed
--- @param palette table|nil   BR.Config.Shop.palette
--- @return integer|nil
function BR.ShopSolve.paint(row, seed, palette)
    if not BR.ShopSolve.randomises(row) then return nil end
    if type(palette) ~= 'table' or #palette == 0 then return nil end

    -- A NIL TEST, AND IT READS AS ONE ONLY BECAUSE 0 IS TRUTHY IN LUA. Seed 0
    -- is a seed -- the server masks its roll to 32 bits -- and so is paint index
    -- 0, Metallic Black, which is in the shipped palette. An `s == 0` guard
    -- here, or an `or 0` on either line, silently pins one match in four billion
    -- and one colour in thirty-two to the authored value.
    local s = math.tointeger(tonumber(seed))
    if not s then return nil end

    local id = tostring(row.id or '')
    if id == '' then return nil end

    -- NIL-GUARDED ON THE MODULE. br_lib loads its shared scripts as a glob and
    -- the order is the platform's business; a call before rng.lua has run must
    -- fall back to the authored colour rather than raise inside a dresser.
    if type(BR.Rng) ~= 'function' then return nil end

    local n = tonumber(BR.Rng(fold(s, id)):pick(palette))
    if not n then return nil end
    return math.floor(n)
end

--- ═══ THE DIRT SCALE IS 0..15, AND IT IS NOT A PERCENTAGE ═══
---
--- Owner, 2026-09-01: "can you make vehicles have random dirt levels >20% at
--- the shop? That part should also copy over once they've spawned it."
---
--- SET_VEHICLE_DIRT_LEVEL TAKES A FLOAT FROM 0.0 TO 15.0 -- not 0..100, and
--- guessing 100 would have asked for eleven-hundred-percent dirt and got
--- whatever the engine clamps to, on every car, which is the filthy showroom
--- nobody asked for. The number is checked rather than assumed: the FiveM
--- native reference says values above 15.0 cannot be used and the game refuses
--- to render a car dirtier than the maximum, and this repository had already
--- written the same range down twice from its own testing --
--- br_core/client/fuel.lua ("range 0..15", beside the wash it deliberately does
--- not do) and the authoring comment in config/shop.lua ("0 clean .. 15
--- filthy"). Three sources, one answer.
---
--- SO ">20%" IS A PERCENTAGE OF FIFTEEN, WHICH IS 3.0. That is the floor he
--- named and the only number in this block that is his.
local DIRT_SCALE = 15.0

--- The dirtiest a showroom car may be, and why it is not 15.
---
--- ═══ HE SET A FLOOR AND NOT A CEILING, AND A CEILING STILL HAS TO BE CHOSEN
---     ═══
---
--- ">20%" bounds the roll from below only. Drawing over (20%, 100%] would put
--- caked mud on roughly half the lot, and "dirty" is not "derelict": these cars
--- are being SOLD, they stand on a pad with a price over them, and the request
--- was for cars that are not showroom-fresh rather than for wrecks.
---
--- 60% -- 9.0 -- IS THE CEILING, AND THE REASON IS HEADROOM RATHER THAN TASTE.
--- GTA accumulates dirt on a vehicle as it is driven, so the level a car spawns
--- at is a STARTING point on a scale the game keeps writing to. A car delivered
--- at 15.0 is pinned at the ceiling for the rest of the match and can never
--- look like it has been anywhere; one delivered in this band still visibly
--- weathers on the way to the circle, which is the behaviour a dirt level is
--- for. Leaving the top 40% of the scale to the engine is what buys that.
---
--- ROCKSTAR'S OWN AMBIENT GENERATOR ROLLS `rand() % 15` -- the whole scale --
--- and a showroom is deliberately not ambient traffic: higher floor, lower
--- ceiling, a narrower band than a random car in the street. The difference is
--- the point.
---
--- BOTH NUMBERS ARE TUNING, AND THE FLOOR IS THE ONLY ONE HE GAVE. If the lot
--- reads too clean or too grim in game, these two lines are the whole change.
local DIRT_MIN = DIRT_SCALE * 0.20   -- 3.0, the floor he named
local DIRT_MAX = DIRT_SCALE * 0.60   -- 9.0, the ceiling chosen above

--- Does this row take a rolled dirt level?
---
--- ═══ A SEPARATE FLAG FROM `randomColour`, AND THE AMBULANCE ROLLS ═══
---
--- The obvious move is to read `randomises` here and let the one car that is
--- pinned to its authored colour keep an authored dirt level too. THAT WOULD BE
--- THE WRONG READING OF WHY THAT FLAG EXISTS. `randomColour = false` is on the
--- ambulance for one stated reason -- "that one has a livery so color won't
--- matter" -- and it is a fact about PAINT REPLACING ARTWORK: a rolled colour
--- puts a body colour underneath a livery that was drawn for a white one.
---
--- DIRT DOES NOT REPLACE THE LIVERY, IT WEATHERS IT, exactly as it weathers
--- paint on the other twelve. There is no ambulance anywhere that does not get
--- dirty, and the config already records that the marshall -- which also
--- carries a livery -- was NOT exempted from the colour roll because "he named
--- one car". He named no car at all this time: the dirt request has no
--- exemption in it, and inventing one, justified by a reason that does not
--- apply, is a decision he never made.
---
--- SO ALL THIRTEEN ROLL, AND THE OPT-OUT EXISTS ANYWAY. `randomDirt = false` is
--- the same shape and the same polarity as `randomColour` -- absent means on,
--- only an explicit `false` pins a row, and a misspelling cannot silently pin
--- one because the test is an equality rather than a truth test. No row in the
--- shipped catalogue uses it. It is here so that disagreeing with the paragraph
--- above is a one-word edit rather than a change to this file.
--- @param row table|nil
--- @return boolean
function BR.ShopSolve.dirties(row)
    if type(row) ~= 'table' then return false end
    return row.randomDirt ~= false
end

--- How dirty one row is under one seed, or nil for "use the row".
---
--- ═══ THE SECOND DERIVATION FROM THE FIRST SEED -- NOT A SECOND SEED ═══
---
--- Everything the paint roll's write-up says applies here unchanged: the server
--- owns ONE integer per match (`m.shopSeed`), both ends derive from it, and
--- NOTHING ABOUT DIRT TRAVELS OVER THE WIRE in either direction. The delivery
--- message already carries that seed because the colour needed it; dirt costs
--- it nothing extra, and "the car unpacked from the item wears the same dirt as
--- the one on the pad" is true for the same reason the colour matches -- the two
--- cars are one computation run twice, not two values kept in step.
---
--- ═══ DOMAIN-SEPARATED FROM THE PAINT FOLD, AND THE HONEST REASON IS NOT THE
---     OBVIOUS ONE ═══
---
--- `fold(seed, id)` is what the colour draws from, and both rolls take the FIRST
--- word out of the generator they seed. So sharing the fold would have both of
--- them reading one identical 32-bit word.
---
--- THAT WOULD NOT ACTUALLY CORRELATE THEM TODAY, and the first version of this
--- comment claimed it would. It is worth writing down what is really true
--- instead, because the wrong reason is the more persuasive one: `Rng:pick`
--- reaches the palette through `Rng:int`, which reads the word MODULO 32 -- its
--- bottom five bits -- while `Rng:float` divides the same word by 2^32 and so
--- reads essentially all of its top bits. Low bits and high bits of one xoshiro
--- word are independent enough that a shared fold produces no visible pattern,
--- and a test looking for "every red car is equally dirty" finds nothing.
---
--- THE REASON TO SEPARATE THEM IS THAT THE INDEPENDENCE IS AN ACCIDENT OF
--- Rng:int'S IMPLEMENTATION. `lo + next() % n` is one refactor away from
--- `lo + floor(float() * n)` -- the same function, the spelling most people
--- reach for, and arguably the better one because the modulo is very slightly
--- biased. On the day somebody makes that change, a shared fold makes the paint
--- index a pure function of the dirt level and nothing anywhere says so. The
--- coupling would be introduced by an edit to a DIFFERENT FILE that looks
--- entirely correct on its own.
---
--- So folding `'dirt\0' .. id` buys structural independence rather than a bug
--- fix: the two rolls cannot read the same word whatever Rng does later. The
--- prefix is separated by a NUL so no id can collide with another id's dirt
--- domain by being a prefix of it, and `fold` itself is untouched -- so every
--- colour this function ships beside is bit-for-bit the one it was before.
---
--- ═══ HALF-OPEN AT THE TOP SO THE FLOOR IS STRICT ═══
---
--- `Rng:float()` is uniform on [0, 1), so `lo + f * (hi - lo)` can return
--- EXACTLY `lo` and never returns `hi`. He asked for dirt levels ">20%", so the
--- floor is the bound that has to be strict -- and the subtraction below maps
--- the same draw onto (lo, hi] instead, which is strictly above 20% by
--- construction rather than by rounding. It costs one operator and it makes the
--- owner's own sentence a property a test can assert.
---
--- NIL ON EVERY ABSENCE, exactly as the paint roll does: no seed, no id, a row
--- that opted out, or an RNG that has not loaded yet all mean "this car wears
--- what config/shop.lua says", which is the behaviour that shipped before dirt
--- was rolled at all.
--- @param row table|nil
--- @param seed integer|nil    the match's shop seed -- the SAME one paint uses
--- @return number|nil
function BR.ShopSolve.dirt(row, seed)
    if not BR.ShopSolve.dirties(row) then return nil end

    -- A NIL TEST, AND IT READS AS ONE ONLY BECAUSE 0 IS TRUTHY IN LUA. Seed 0
    -- is a seed -- the server masks its roll to 32 bits -- so an `s == 0` guard
    -- here, or an `or 0` on the line, silently pins one match in four billion
    -- to the authored dirt level. Same sentence as the paint roll's, because it
    -- is the same mistake.
    local s = math.tointeger(tonumber(seed))
    if not s then return nil end

    local id = tostring(row.id or '')
    if id == '' then return nil end

    -- NIL-GUARDED ON THE MODULE, for the reason paint states: br_lib loads its
    -- shared scripts as a glob and the order is the platform's business.
    if type(BR.Rng) ~= 'function' then return nil end

    local f = tonumber(BR.Rng(fold(s, 'dirt\0' .. id)):float())
    if not f then return nil end
    return DIRT_MAX - f * (DIRT_MAX - DIRT_MIN)
end

--- THE APPEARANCE, CANONICALISED. One row in, one fully-populated table out.
---
--- ═══ THIS FUNCTION IS THE "EXACTLY AS SHOWN" GUARANTEE ═══
---
--- Both cars are dressed by BR.Shop.dress (br_core/client/shop.lua) and
--- BR.Shop.dress reads ONLY what this returns. So the showroom car and the car
--- that comes out of the item are not "kept in sync"; they are the same
--- computation run twice, and there is no state anywhere that could be right for
--- one and wrong for the other.
---
--- ═══ THE SEED IS PART OF "THE SAME COMPUTATION", NOT AN OVERRIDE ON TOP OF IT
---     ═══
---
--- The showroom is dressed with the match's seed and the delivered car is
--- dressed with the same match's seed, so the two calls have identical inputs
--- and cannot disagree. A caller that passed a seed to one and not the other
--- would be back to two representations -- which is why the delivery message
--- carries the seed rather than the client remembering the one it built the
--- showroom with, and why a client that has to guess is told to guess NOTHING
--- and use the authored colour instead.
---
--- EVERY FIELD IS PRESENT IN THE ANSWER, including the ones the owner left out.
--- A dresser that skips absent fields would leave the delivered car wearing
--- whatever the engine happened to give it -- and the engine gives a random
--- colour to a freshly created vehicle, which is precisely the drift this
--- feature cannot have. An explicit `-1` (or `false`) means "the model's own
--- default, written deliberately".
---
--- MODS ARE COPIED, NOT REFERENCED. The caller gets a table it may not mutate
--- into the config by accident -- one client writing a defaulted field back into
--- the shared row would be the second representation arriving by the back door.
--- @param row table|nil
--- @param seed integer|nil    the match's shop seed; nil keeps the authored
---                            colour AND the authored dirt level -- one number
---                            feeds both rolls and neither has one of its own
--- @param palette table|nil   BR.Config.Shop.palette
--- @return table
function BR.ShopSolve.appearance(row, seed, palette)
    local a = (type(row) == 'table' and type(row.appearance) == 'table')
        and row.appearance or {}

    local function int(v, fallback)
        local n = tonumber(v)
        if not n then return fallback end
        return math.floor(n)
    end

    local mods = {}
    if type(a.mods) == 'table' then
        for slot, index in pairs(a.mods) do
            local s, i = tonumber(slot), tonumber(index)
            if s and i then mods[math.floor(s)] = math.floor(i) end
        end
    end

    local toggles = {}
    if type(a.toggles) == 'table' then
        for slot, on in pairs(a.toggles) do
            local s = tonumber(slot)
            if s then toggles[math.floor(s)] = (on == true) end
        end
    end

    local extras = {}
    if type(a.extras) == 'table' then
        for id, on in pairs(a.extras) do
            local n = tonumber(id)
            if n then extras[math.floor(n)] = (on == true) end
        end
    end

    -- ═══ THE ROLL WINS, AND IT PAINTS BOTH COATS THE SAME ═══
    --
    -- ONE COLOUR PER CAR, NOT TWO. Every row the owner authored writes
    -- `secondary` equal to `primary`, so a single-coat car is the convention he
    -- already set and the roll keeps it. Two independent draws would put a
    -- random roof and random stripes on a random body -- three colours nobody
    -- chose, on the models where the secondary shows at all -- and "random
    -- colors" is not an invitation to invent a paint job.
    --
    -- WRITTEN AS AN `if`, NOT AS `rolled or int(...)`. 0 is Metallic Black and
    -- 0 is in the palette; it is also TRUTHY in Lua, so the `or` spelling would
    -- happen to work here and would be one edit away from not. This project has
    -- shipped that class of bug nine times and it is not spelling it a tenth.
    local pri, sec = int(a.primary, -1), int(a.secondary, -1)
    local rolled = BR.ShopSolve.paint(row, seed, palette)
    if rolled ~= nil then pri, sec = rolled, rolled end

    -- ═══ AND THE DIRT IS ROLLED THE SAME WAY, OFF THE SAME SEED ═══
    --
    -- Owner, 2026-09-01: "can you make vehicles have random dirt levels >20% at
    -- the shop? That part should also copy over once they've spawned it."
    --
    -- "COPY OVER" IS THE HALF THAT NEEDED NO CODE, and that is the whole payoff
    -- of the shape this file already had. Dirt is derived here, in the one
    -- function BR.Shop.dress reads for BOTH cars, from the seed the delivery
    -- already carries -- so the car that comes out of the item wears the pad
    -- car's dirt for exactly the reason it wears its colour, and there is no
    -- second value to send, store or keep in step.
    --
    -- WRITTEN AS AN `if`, NOT AS `rolled or authored`. 0.0 is a legal dirt level
    -- and 0.0 is TRUTHY in Lua; the `or` spelling would read a clean car as "no
    -- answer" if this function ever returned one. It cannot today -- the band
    -- starts at 3.0 -- which is exactly the kind of "safe by a value that lives
    -- somewhere else" this project has been bitten by.
    local dirt = tonumber(a.dirt) or 0.0
    local rolledDirt = BR.ShopSolve.dirt(row, seed)
    if rolledDirt ~= nil then dirt = rolledDirt end

    return {
        -- -1 IS THE ENGINE'S OWN "LEAVE IT" FOR EVERY COLOUR INDEX HERE, so an
        -- unwritten field and a deliberately-default field produce the same
        -- car -- which is what makes a half-filled row safe to ship.
        primary     = pri,
        secondary   = sec,
        pearl       = int(a.pearl,       -1),
        wheelColour = int(a.wheelColour, -1),
        interior    = int(a.interior,    -1),
        dashboard   = int(a.dashboard,   -1),
        livery      = int(a.livery,      -1),
        roofLivery  = int(a.roofLivery,  -1),
        windowTint  = int(a.windowTint,  -1),
        wheelType   = int(a.wheelType,   -1),
        dirt        = dirt,
        plate       = (type(a.plate) == 'string') and a.plate or nil,
        plateIndex  = int(a.plateIndex,  -1),
        xenon       = (a.xenon == true),
        xenonColour = int(a.xenonColour, -1),
        mods        = mods,
        toggles     = toggles,
        extras      = extras,
    }
end

--- The ground token's render scale.
---
--- Owner, 2026-08-29: "the loot item should be that vehicle but as a prop and
--- super small, like the same size as a weapon prop pickup."
---
--- A NUMBER RATHER THAN A MEASUREMENT, because there is nothing here to measure
--- against: BR.Native.propScale renormalises an entity's matrix axes to k, which
--- is a MULTIPLE OF THE MODEL'S OWN SIZE, and a Sultan and a Sanchez are not the
--- same size to begin with. So a per-row override exists and the default is the
--- one number the owner can retune once for the whole catalogue.
--- @param row table|nil
--- @param cfg table|nil
--- @return number
function BR.ShopSolve.tokenScale(row, cfg)
    local k = tonumber(type(row) == 'table' and row.tokenScale or nil)
    if not k then k = tonumber(cfg and cfg.tokenScale or nil) end
    if not k or k <= 0.0 then return 0.1 end
    return k
end

-- ---------------------------------------------------------------------------
-- May this player buy this car, right now?
-- ---------------------------------------------------------------------------

--- Refusal reasons. Values are what the SERVER logs; only `afford` and
--- `bought` are ever spoken to a player, and both use wording the market
--- already ships (server/market.lua's `refuse`). Nothing here invents copy.
BR.ShopSolve.Refusal = {
    OFF     = 'shopoff',      -- no catalogue: the feature does not exist
    STATE   = 'notwarmup',    -- the shop is open during warmup and never after
    NOROW   = 'nosuchcar',    -- the client named a car that is not for sale
    BOUGHT  = 'alreadyone',   -- one vehicle per player per match
    AFFORD  = 'afford',       -- not enough Volts
}

--- The whole purchase condition, in one place, evaluated by the SERVER.
---
--- THE CLIENT ASKS AND NEVER DECIDES. It sends a catalogue id and nothing else
--- -- no price, no balance, no claim about what state it is in. Every term below
--- is resolved on the server side against config and the roster, which is
--- server/market.lua's rule for the storefront and is the same rule here.
---
--- ONE VEHICLE PER PLAYER PER MATCH, and it is a count rather than a flag so the
--- day the owner wants two the change is a number in config. Owner, 2026-08-29:
--- "players can purchase no more than 1 vehicle during warmup."
---
--- @param st table  { on, matchState, playerState, bought, limit, balance, price }
--- @return boolean ok
--- @return string|nil why   a BR.ShopSolve.Refusal value
function BR.ShopSolve.canBuy(st)
    if type(st) ~= 'table' then return false, BR.ShopSolve.Refusal.OFF end
    if st.on ~= true then return false, BR.ShopSolve.Refusal.OFF end

    -- WARMUP ON BOTH CLOCKS. The MATCH has to be in warmup and the PLAYER has to
    -- be in it -- a spectator or a late joiner sitting in the lobby while a
    -- warmup runs is not somebody standing in the showroom. Checking one and not
    -- the other is the shape of bug that let a downed player use the inventory.
    if st.matchState ~= BR.MatchState.WARMUP then
        return false, BR.ShopSolve.Refusal.STATE
    end
    if st.playerState ~= BR.PlayerState.WARMUP then
        return false, BR.ShopSolve.Refusal.STATE
    end

    if st.row == nil then return false, BR.ShopSolve.Refusal.NOROW end

    local limit = tonumber(st.limit) or 1
    if (tonumber(st.bought) or 0) >= limit then
        return false, BR.ShopSolve.Refusal.BOUGHT
    end

    -- THE PRICE COMES FROM THE ROW AND THE BALANCE FROM THE LEDGER; neither ever
    -- comes from the client. A `>=` rather than a `>`: spending your last Volt
    -- on a car is a purchase, not an overdraft.
    local price   = tonumber(st.price) or 0
    local balance = tonumber(st.balance) or 0
    if balance < price then return false, BR.ShopSolve.Refusal.AFFORD end

    return true, nil
end

--- How many more Volts a player needs, for the market's existing sentence.
--- @param balance number|nil
--- @param price number|nil
--- @return integer
function BR.ShopSolve.shortfall(balance, price)
    local d = (tonumber(price) or 0) - (tonumber(balance) or 0)
    if d < 0 then d = 0 end
    return math.floor(d)
end
