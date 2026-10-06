--[[
    The market's server half: what you own, what you have equipped, what you
    can afford.

    THE CLIENT NEVER DECIDES ANYTHING HERE. It names an item id and nothing
    else -- no price, no ownership claim, no balance. Every one of those is
    resolved on this side against BR.Config and the database, because a
    storefront that trusts the client for a price is a storefront that sells
    everything for zero the first time somebody looks at it.

    ONE READ PER PLAYER PER SESSION. The inventory arrives once, on join, and
    is held in memory for the rest of the session. Every mutation after that
    goes through a conditional write whose result updates the cache, so the
    cache cannot drift from the row without the write having failed -- and a
    failed write refuses out loud. This project is personally funded and
    DynamoDB is billed per read; polling an inventory that only this server can
    change would be spending money to learn what we already know.

    THE CACHE IS PER-SESSION AND DIES WITH THE PLAYER. No invalidation, no TTL,
    nothing clever: dropping the entry on disconnect is the whole lifecycle.

    FAILS TO DEFAULTS, NEVER TO A LOCKED DOOR. An unreadable inventory means a
    player who owns exactly the defaults for this session -- which is every
    slot filled and a perfectly playable match -- rather than a player who
    cannot drop. Same rule as the ban gate and the maintenance poll.
]]

BR = BR or {}
BR.Market = BR.Market or {}

--- license -> { balance, owned = {id=true}, equipped = {kind=id}, loaded,
---              emotes = {k=id}, emoteBusy = {k=true}, slotWrites }
--- `emotes` is the emote wheel (#215): slot k is segment k is equip_emotek,
--- and it is never folded into `equipped`, which is one item per kind.
local inv = {}

--- src -> license, so a disconnect can clear the right entry without asking
--- the identity system about a player who has already gone.
local licenseOf = {}

local nextReq = 0
local pending = {}

local function reply(req, ...)
    local cb = pending[req]
    if not cb then return end
    pending[req] = nil
    cb(...)
end

AddEventHandler('br:ddb:inventoryResult', function(req, i, extra) reply(req, i, extra or {}) end)
AddEventHandler('br:ddb:purchaseResult',  function(req, ok, extra) reply(req, ok, extra or {}) end)
AddEventHandler('br:ddb:equipResult',     function(req, ok, extra) reply(req, ok, extra or {}) end)
AddEventHandler('br:ddb:spendResult',     function(req, ok, extra) reply(req, ok, extra or {}) end)
AddEventHandler('br:ddb:tutorialSetResult', function(req, ok, extra) reply(req, ok, extra or {}) end)
AddEventHandler('br:ddb:unequipResult',   function(req, ok, extra) reply(req, ok, extra or {}) end)
AddEventHandler('br:ddb:ownedAddResult',  function(req, ok, extra) reply(req, ok, extra or {}) end)

--- Issue one br_ddb request with a timeout, so a bridge that never answers
--- cannot leak a pending closure per attempt for the life of the server.
local function ask(event, cb, ...)
    if GetResourceState('br_ddb') ~= 'started' then
        cb(nil, { error = 'br_ddb not started' })
        return
    end
    local req = nextReq + 1
    nextReq = req
    pending[req] = cb
    SetTimeout(6000, function()
        if pending[req] then
            pending[req] = nil
            cb(nil, { error = 'timed out' })
        end
    end)
    TriggerEvent(event, req, ...)
end

--- The license for a connected source, qualified.
--- @param src integer
--- @return string|nil
local function licenseFor(src)
    local byKind = BR.Identity.ofPlayer(src)
    if not byKind or not byKind.license then return nil end
    return BR.Identity.qualified('license', byKind.license)
end

-- ═══ THE EMOTE WHEEL (#215, "Scope v2") ═══
--
-- Owner, 2026-10-02: "Up to 8 equipped", managed from the Market -- "equip,
-- unequip, and swap one for another when more than 8 are owned". Every other
-- kind is one item per slot and lives in `entry.equipped`; dances are eight
-- slots and live in `entry.emotes`, so nothing that walks `equipped` (the
-- cosmetics applied on spawn, the page's one-per-kind rule) ever sees one.
--
-- THIS FILE LOADS WITHOUT br_lib/config/emotes.lua UNDER TEST (test_volts,
-- test_tutorial), so nothing here indexes BR.Config.Emotes: the slot count is
-- pinned and the gate is read through emoteHidden, which is nil-safe.

--- Wheel slots. The config says the same 8; this file may not read it.
local SLOTS = 8

--- A slot write is one DynamoDB UpdateItem, billed. Twenty in ten seconds is
--- more than any hand on a Market page can click and fewer than a script can.
local SLOT_WRITE_WINDOW_MS, SLOT_WRITE_MAX = 10000, 20

--- The wheel slot a br_ddb equip kind names, or nil for every other kind.
--- @param kind any
--- @return integer|nil
local function emoteSlotOf(kind)
    local digit = type(kind) == 'string' and kind:match('^emote(%d)$') or nil
    local k = digit and math.tointeger(tonumber(digit)) or nil
    if k and k >= 1 and k <= SLOTS then return k end
    return nil
end

--- THE GATE, AS THIS FILE ASKS IT. An emote item while BR.Season.has('emotes')
--- is false (this server's season is before the `emotes` row in
--- br_lib/config/seasons.lua) is not for sale, not equippable and not
--- grantable. tools/check_emote_gate.lua pins every door below to this or to
--- the gate itself. NIL-SAFE: test_volts and test_tutorial load this file
--- without the season module, and a market with no season has no emotes.
local function emoteHidden(item) return item ~= nil and item.kind == 'emote' and not (BR.Season ~= nil and BR.Season.has ~= nil and BR.Season.has('emotes')) end

--- Which slot holds `id`, or nil.
--- @param entry table
--- @param id string
--- @return integer|nil
local function slotHolding(entry, id)
    local emotes = entry and entry.emotes
    if not emotes or id == nil then return nil end
    for k = 1, SLOTS do
        if emotes[k] == id then return k end
    end
    return nil
end

--- The lowest empty slot that has no write in flight, or nil when none.
---
--- BUSY SLOTS ARE SKIPPED, and that is what keeps two writes to one
--- equip_emoteK off the wire together: a slot whose REMOVE has not answered
--- reads empty in the cache, and a SET handed it now could land before the
--- REMOVE -- DynamoDB does not order them -- and be erased by it.
--- @param entry table
--- @return integer|nil
local function firstFree(entry)
    for k = 1, SLOTS do
        if entry.emotes[k] == nil and not entry.emoteBusy[k] then return k end
    end
    return nil
end

--- Count one slot write against a fixed window; true once it is over the cap.
--- @param entry table
--- @param now integer
--- @return boolean
local function slotWriteOver(entry, now)
    local w = entry.slotWrites
    if not w or now - w.since > SLOT_WRITE_WINDOW_MS then
        w = { since = now, n = 0 }
        entry.slotWrites = w
    end
    w.n = w.n + 1
    return w.n > SLOT_WRITE_MAX
end

--- Defaults, which every player owns implicitly and which therefore never
--- appear in the `owned` set. Resolved from config rather than hardcoded so a
--- season that changes the default chute does not need this file edited.
local function withDefaults(entry)
    for _, kind in ipairs({ 'character', 'chute', 'trail', 'weapon', 'banner', 'verdict' }) do
        if not entry.equipped[kind] then
            local d = BR.Config.defaultItem(kind)
            if d then entry.equipped[kind] = d.id end
        end
    end
    return entry
end

--- Send one player their whole market state.
---
--- THE WHOLE STATE, EVERY TIME. Sending a delta would be smaller and would
--- introduce the one bug a storefront cannot have: a page that believes it
--- owns something it does not, because it missed a message.
--- @param src integer
function BR.Market.push(src)
    local lic = licenseOf[src]
    local entry = lic and inv[lic]
    if not entry then return end

    -- br_stats HEARS IT EVERY TIME THIS SIDE TELLS A CLIENT ANYTHING.
    --
    -- `br:stats:knownXp` populates BR.Stats.cachedXp, which is what br_stats
    -- uses as the lifetime total a match starts from -- and therefore what
    -- decides the level it writes to the profile row and shows on the verdict
    -- screen. That table lives in br_stats' Lua state, so RESTARTING br_stats
    -- empties it, permanently: it was only published from the inventory fetch
    -- and from a credit, and both of those are behind branches a player who is
    -- already loaded never takes again. The MARKET_STATE handler sends such a
    -- player down `push`, and `load` early-returns for them -- so nothing
    -- republished, and the next match for every connected player was processed
    -- against a lifetime total of zero.
    --
    -- Publishing from here instead makes the rule trivial: br_stats knows what
    -- the client knows. It is a same-process TriggerEvent against a number
    -- already in memory, so doing it on every push costs nothing worth naming,
    -- and re-publishing a value br_stats already holds is a plain assignment.
    BR.Market.publishXp(lic)

    -- THE EMOTE GATE, read once per push (#215). While it is closed the page
    -- hears nothing about dances: no `emotes`, and no emote ids in `owned`.
    local emotesOn = BR.Season ~= nil and BR.Season.has ~= nil and BR.Season.has('emotes')

    local owned = {}
    for id in pairs(entry.owned) do
        local item = BR.Config.MarketIndex[id]
        if emotesOn or not (item and item.kind == 'emote') then owned[#owned + 1] = id end
    end
    table.sort(owned)   -- never send a hash's iteration order over the wire

    -- EIGHT STRINGS, '' FOR AN EMPTY SLOT, because a Lua array with holes does
    -- not survive msgpack as one: index k is wheel segment k, always.
    local emotes = nil
    if emotesOn then
        emotes = {}
        for k = 1, SLOTS do emotes[k] = (entry.emotes and entry.emotes[k]) or '' end
    end

    -- PROGRESSION RIDES WITH THE MARKET STATE, because it came out of the same
    -- read. Splitting it into its own event would mean a second round trip for
    -- data already in memory, and two moments where the lobby could be showing
    -- a level and a balance that disagree about which read they came from.
    --
    -- The curve is evaluated HERE rather than on the client. It moved into
    -- br_lib precisely so this side and br_stats can share one implementation:
    -- a client that computed its own would eventually disagree with the server
    -- about what level somebody is, and the player would believe the client.
    local level, into, needed = 1, 0, 1
    if BR.Xp then
        level = BR.Xp.levelFor(entry.xp)
        -- progress() already returns the span, so it is not recomputed from
        -- two threshold calls that could drift from it.
        local _, i, span = BR.Xp.progress(entry.xp)
        into, needed = i, math.max(1, span)
    end

    TriggerClientEvent(BR.Net.MARKET_STATE, src, {
        -- SPENDABLE, NOT THE ROW (#224). A player who has just bought a car in
        -- warmup has committed those Volts; a screen still showing them is a
        -- screen inviting them to be spent again. See BR.Market.balanceOf.
        balance  = BR.Market.spendable(entry),
        owned    = owned,
        equipped = entry.equipped,
        progress = { level = level, xp = into, needed = needed, total = entry.xp },
        emotes   = emotes,
    })
end

--- Load a player's inventory once, then tell them about it.
--- @param src integer
function BR.Market.load(src)
    local lic = licenseFor(src)
    if not lic then
        print(('^3[br_core] market: no license for %s -- defaults only^7'):format(src))
        return
    end

    licenseOf[src] = lic
    if inv[lic] and inv[lic].loaded then
        -- `push` republishes the lifetime XP to br_stats, so this branch --
        -- a reconnect racing a drop, where the license is still cached -- is
        -- covered without a second call here.
        BR.Market.push(src)
        -- The Yubikey (#396) came out of the same read and is still cached
        -- under the license; this new source is told it is theirs.
        if BR.Yubikey and BR.Yubikey.adopt then BR.Yubikey.adopt(src, lic) end
        return
    end

    -- Seeded before the answer arrives, so a purchase attempted during the
    -- round trip finds an entry to refuse against rather than nil.
    -- `xp = 0` IS NOT DECORATION. The seeded stub was missing it, so during the
    -- round trip `entry.xp` was nil -- and BR.Market.push feeds that straight to
    -- BR.Xp.levelFor. Worse, `br:market:credited` does `(entry.xp or 0) + earned`,
    -- so a match ending inside that window replaced the player's lifetime total
    -- with just what the match paid. The window is short and the symptom is a
    -- level that reads wrong and then silently corrects itself, which is exactly
    -- the kind of thing that gets reported as "it took a while to update".
    -- `spent = 0` IS THE SAME KIND OF NOT-DECORATION (#224): Volts reserved
    -- against a charge that is in flight to DynamoDB. It is only ever moved by
    -- BR.Market.charge, which refuses while `loaded` is false -- so no spend can
    -- exist before the fetch below replaces this table.
    inv[lic] = withDefaults({ balance = 0, spent = 0, xp = 0, owned = {}, equipped = {}, loaded = false,
                              emotes = {}, emoteBusy = {}, slotWrites = nil })

    ask('br:ddb:inventoryFetch', function(i, extra)
        local entry = { balance = 0, spent = 0, xp = 0, owned = {}, equipped = {},
                        tutorial = '', loaded = true,
                        emotes = {}, emoteBusy = {}, slotWrites = nil }

        if i then
            entry.balance = tonumber(i.balance) or 0
            -- WHERE THIS ACCOUNT STANDS WITH THE GUIDED FIRST RUN (#261).
            -- '' is never answered, and it is the state every account is in
            -- until somebody declines or finishes -- which is what makes the
            -- offer reach players who have been here for months.
            entry.tutorial = type(i.tutorial) == 'string' and i.tutorial or ''
            -- LIFETIME XP, not progress into a level. The curve derives both
            -- from this one number, so storing the derived form would mean
            -- storing something that can disagree with its own source.
            entry.xp = tonumber(i.xp) or 0
            for _, id in ipairs(i.owned or {}) do
                -- Ignore ids with no definition. A season pulled from config
                -- leaves owners holding an id nothing can render, and dropping
                -- it here is better than shipping it to a page that will try.
                if BR.Config.MarketIndex[id] then entry.owned[id] = true end
            end
            for kind, id in pairs(i.equipped or {}) do
                -- NOT the wheel slots: cosmetics.lua applies every `equipped`
                -- kind as something worn, and a dance is not worn.
                if emoteSlotOf(kind) == nil and BR.Config.MarketIndex[id] then
                    entry.equipped[kind] = id
                end
            end
            -- THE WHEEL (#215). A slot keeps an id only when it is a dance this
            -- account owns and no lower slot already holds it; anything else
            -- is dropped from the cache and the row is left alone, because
            -- this is a read and must not cost a write.
            local eq = type(i.equipped) == 'table' and i.equipped or {}
            for k = 1, SLOTS do
                local id = eq['emote' .. k]
                local item = id and BR.Config.MarketIndex[id]
                if item and item.kind == 'emote' and entry.owned[id]
                   and slotHolding(entry, id) == nil then
                    entry.emotes[k] = id
                end
            end
        end
        if extra and extra.error then
            print(('^3[br_core] market: inventory read failed for %s (%s) -- defaults only^7')
                :format(src, extra.error))
        end

        inv[lic] = withDefaults(entry)
        BR.Market.publishXp(lic)
        BR.Market.push(src)

        -- THE YUBIKEY (#396, Season 2) rides this same read: two booleans on
        -- the profile row, handed to server/yubikey.lua rather than cached
        -- here, because nothing in the market sells, equips or shows one. A
        -- failed read hands over nil, which is no key. Nil-guarded: test_volts
        -- and test_tutorial load this file without it.
        if BR.Yubikey and BR.Yubikey.loaded then BR.Yubikey.loaded(src, lic, i) end

        -- ═══ AND THE OFFER, NOW THAT WE KNOW WHETHER TO MAKE IT (#261) ═══
        --
        -- Owner, 2026-09-07: "set the default for every single person (not just
        -- new players) to have that tutorial enabled next time they join the
        -- server." Nobody's row carries this field yet, so '' -- never answered
        -- -- is what every account reads back, and every account is offered it
        -- exactly once. There is no separate "new player" test and there does
        -- not need to be.
        --
        -- HERE RATHER THAN ON CONNECT, because this is the line where the answer
        -- exists. A read that failed leaves `entry.tutorial` at '' and the offer
        -- is made -- the permissive direction, which costs a player one toggle
        -- they can untick and costs nobody anything else.
        TriggerClientEvent(BR.Net.TUTORIAL_OFFER, src,
                           { offer = entry.tutorial == '' })
    end, lic)
end

--- Tell br_stats what this player's lifetime XP actually is.
---
--- BECAUSE br_stats CANNOT KNOW IT, AND WAS GUESSING ZERO. It reads
--- `BR.Stats.cachedXp[license]` to work out what level a match ends on, and
--- nothing anywhere populated that table -- so `before` was always 0 and the
--- level was derived from ONE match's XP rather than a career of it. A player
--- with 3558 lifetime XP was stored as level 2, told they were level 2 on the
--- verdict screen, and shown level 2 in the lobby until the next MARKET_STATE
--- corrected it. Same wrong number, three places, one missing writer.
---
--- THIS SIDE IS THE ONE THAT KNOWS. br_core reads the profile row on connect
--- and holds the total for the session, applying every credit as it lands, so
--- `inv[lic].xp` is the authoritative figure. br_stats owns the curve and the
--- payout; it just never had the input.
---
--- An event rather than a call, in the direction br_stats already accepts one:
--- these two resources deliberately do not depend on each other.
--- @param lic string
function BR.Market.publishXp(lic)
    local entry = inv[lic]
    if not entry then return end
    TriggerEvent('br:stats:knownXp', lic, entry.xp or 0)
end

--- One player's lifetime XP, as this side currently holds it.
---
--- EXISTS FOR THE DIAGNOSTIC, and deliberately reads rather than computes. The
--- `brxpsim` console command has to pose a match award against a REAL profile
--- to be worth anything -- a simulation run against a made-up total would
--- confirm only that the arithmetic works on made-up totals, which was never
--- in doubt. This is the same number br_stats is told on `br:stats:knownXp`,
--- so a simulation that looks wrong is evidence about the real path.
--- @param src integer
--- @return integer|nil  nil when this player's inventory has not loaded
function BR.Market.lifetimeXp(src)
    local lic = licenseOf[src]
    local entry = lic and inv[lic]
    if not entry or not entry.loaded then return nil end
    return entry.xp or 0
end

--- What is equipped, resolved to the apply tables the client needs.
---
--- SENT WITH THE STATE rather than looked up client-side, so that the server
--- stays the only thing that decides what a player is wearing.
--- @param src integer
--- @return table  kind -> apply table
function BR.Market.appliedFor(src)
    local lic = licenseOf[src]
    local entry = lic and inv[lic]
    local out = {}
    if not entry then return out end
    for kind, id in pairs(entry.equipped) do
        local item = BR.Config.MarketIndex[id]
        if item and item.apply then out[kind] = item.apply end
    end
    return out
end

--- Does this player own `id`? (#215: bremotegrant skips what is owned.)
--- @param src integer
--- @param id string
--- @return boolean
function BR.Market.owns(src, id)
    local lic = licenseOf[src]
    local entry = lic and inv[lic]
    return entry ~= nil and entry.owned[tostring(id or '')] == true
end

--- Which emote wheel slot holds `id` for this player, or nil (#215).
---
--- THE SERVER'S ANSWER TO "IS IT ON THE WHEEL", which is what EMOTE_PLAY asks
--- before it publishes anything: owning a dance is not enough to play it.
--- @param src integer
--- @param id string
--- @return integer|nil
function BR.Market.slotOf(src, id)
    local lic = licenseOf[src]
    local entry = lic and inv[lic]
    if not entry then return nil end
    return slotHolding(entry, tostring(id or ''))
end

-- A CLIENT ASKING FOR ITS OWN STATE, which is the one direction this event
-- travels other than the answer. Overloaded deliberately rather than adding a
-- constant nobody would read: "tell me my market state" and "here is your
-- market state" are the same message in opposite directions.
RegisterNetEvent(BR.Net.MARKET_STATE)
AddEventHandler(BR.Net.MARKET_STATE, function()
    local src = source
    if licenseOf[src] then BR.Market.push(src) else BR.Market.load(src) end
end)

--- Tell one player why something did not happen.
--- @param src integer
--- @param text string
--- @param cue string|nil  a cue key that REPLACES the general warn sound
local function refuse(src, text, cue)
    TriggerClientEvent(BR.Net.NOTIFY, src,
        { text = text, tone = 'warn', ms = 4000, cue = cue })
end

--- ═══ THE SENTENCE EVERY SHORTFALL IN THE GAME SPEAKS, AND IT IS HIS ═══
---
--- Owner, 2026-09-09: "You need 378 more to buy that is not good copy - how
--- about You need more Volts to buy that item. again, volts text should be our
--- color." And on 2026-09-11, on changing it everywhere rather than only at the
--- gun counter: "Yes please change the 'You need N more to buy that' copy
--- everywhere - great call."
---
--- VERBATIM, INCLUDING THE FULL STOP. The only mark added is the TILDE PAIR,
--- which is not a letter: ui-src's KeyText paints anything between a pair of
--- them with `--color-volts`, and that is this project's one mechanism for the
--- signature color. It is the same pair config/gunshop.lua's `poorToast` wears
--- for the same word, so there is no second way to colour Volts in a toast.
---
--- ═══ THE NUMBER IS GONE, AND THAT IS THE CHANGE ═══
---
--- "You need %d more to buy that." stated a shortfall to the Volt. He read it on
--- a real screen and it is the thing he objected to. Nothing may put the figure
--- back: no appended balance, no second sentence. The gun shop says more than
--- this at its own counter because he WROTE more for that counter
--- (config/gunshop.lua's `poorToast` and `balanceToast`); every other surface
--- says exactly this.
---
--- ═══ DECLARED HERE, ABOVE BOTH READERS ═══
---
--- A Lua local is invisible above its own declaration, and the two places that
--- speak it are the storefront handler immediately below and
--- BR.Market.tellShortfall two hundred lines down. It is ONE constant because it
--- was two literals: the same sentence typed twice in this file, which is how
--- "change it everywhere" came to mean "find every one of them".
local SHORTFALL = 'You need more ~Volts~ to buy that item.'

RegisterNetEvent(BR.Net.MARKET_BUY)
AddEventHandler(BR.Net.MARKET_BUY, function(data)
    local src = source
    local id = tostring(type(data) == 'table' and data.id or data or '')

    local lic = licenseOf[src]
    local entry = lic and inv[lic]
    if not entry or not entry.loaded then
        refuse(src, 'Your profile is still loading -- try again in a moment.')
        return
    end

    -- THE PRICE IS RESOLVED HERE, from config, by id. This is the line that
    -- makes everything else safe: nothing the client sent is used as money.
    local item, why = BR.Config.buyable(id)
    -- A DANCE IS NOT FOR SALE WHILE THE EMOTE GATE IS CLOSED (#215), and it
    -- says so in the words every other unsellable id gets.
    if item and emoteHidden(item) then item, why = nil, 'emotes are off' end
    if not item then
        refuse(src, 'That item is not for sale.')
        print(('^3[br_core] market: %s tried to buy "%s" -- %s^7'):format(src, id, why))
        return
    end

    if entry.owned[id] then
        refuse(src, 'You already own that.')
        return
    end
    -- SPENDABLE RATHER THAN THE ROW (#224). Volts already committed to a warmup
    -- car are gone even though DynamoDB has not been told yet, and this is the
    -- one condition on this side that could let them be spent twice. The
    -- DynamoDB condition below still guards the row itself -- it just cannot
    -- know about a debit that has not been written.
    local have = BR.Market.spendable(entry)
    if have < item.price then
        -- ═══ THE FOURTH SPEAKER OF THIS SENTENCE, AND THE ONE A COUNT OF
        --     tellShortfall's CALLERS MISSES ═══
        --
        -- The Store screen's own refusal. It never went through
        -- BR.Market.tellShortfall -- it typed the same sentence a second time,
        -- in this file, forty lines from the function that owns it -- so "the
        -- copy is in one place" was true of three callers and false of this one.
        -- Both now read SHORTFALL.
        --
        -- THE CUE IS STILL NOT PASSED HERE AND THAT IS DELIBERATE. `shop.denied`
        -- is what the owner picked for "Shop insufficient funds" and it rides on
        -- tellShortfall's payload; adding it to the cosmetics store would be a
        -- sound he has not asked for on a screen he has not commented on. The
        -- copy is what he decided, so the copy is what changed.
        refuse(src, SHORTFALL)
        return
    end

    ask('br:ddb:purchase', function(ok, extra)
        extra = extra or {}
        if ok then
            entry.owned[id] = true
            entry.balance = tonumber(extra.balance) or (entry.balance - item.price)
            -- BOUGHT MEANS WORN. Nobody buys a canopy in order to not use it,
            -- and an extra click between paying and seeing it is the kind of
            -- friction that reads as the purchase not having worked.
            if item.kind == 'emote' then
                -- A DANCE GOES ON THE WHEEL IF THERE IS ROOM (#215). Owning
                -- more than eight is fine; the Market's Replace puts it on
                -- later. The full-wheel sentence is new copy (owner question).
                -- ASKED ONLY WHEN THERE IS ROOM, so a full wheel is this one
                -- sentence rather than equip's refusal toast beside it.
                local slot = firstFree(entry) and BR.Market.equip(src, id, true) or nil
                TriggerClientEvent(BR.Net.NOTIFY, src, {
                    text = slot and ('%s equipped.'):format(item.name)
                        or ('%s bought -- your emote wheel is full.'):format(item.name),
                    tone = 'success', ms = 4000,
                })
            else
                BR.Market.equip(src, id, true)
                TriggerClientEvent(BR.Net.NOTIFY, src, {
                    text = ('%s equipped.'):format(item.name), tone = 'success', ms = 4000,
                })
            end
        else
            refuse(src, extra.refused and ('Purchase refused: ' .. extra.refused)
                or 'The purchase could not be completed. Nothing was charged.')
        end
        BR.Market.push(src)
    end, lic, id, item.price)
end)

--- Put a dance on the wheel (#215). BR.Market.equip's emote arm.
---
--- ═══ OPTIMISTIC, LIKE EVERY OTHER EQUIP, AND THE ROLLBACK IS THE HARD PART ═══
---
--- The cache moves first so the page feels instant, and a refused write puts it
--- back. With one slot per kind "put it back" is one assignment; with eight it
--- can DUPLICATE a dance: replace B in slot 2 with E, equip B into slot 5 while
--- that write is in flight, and a failure that blindly restored slot 2 would
--- leave B on the wheel twice. So the rollback restores the previous id only
--- when nothing else holds it, and only when the slot still holds what this
--- write put there.
---
--- ONE WRITE PER SLOT IN FLIGHT. A busy slot refuses (silently: the page is
--- re-synced by the push), and firstFree never hands one out.
--- @return integer|nil  the slot, or nil when nothing was asked
local function equipEmote(src, lic, entry, item, replace, quiet)
    if not entry.owned[item.id] then
        refuse(src, 'You do not own that.')
        return nil
    end

    -- ALREADY ON THE WHEEL IS ALREADY DONE. No write, and no second copy.
    local held = slotHolding(entry, item.id)
    if held then
        if not quiet then BR.Market.push(src) end
        return held
    end

    -- REPLACE NAMES THE DANCE WHOSE SLOT THIS TAKES; otherwise the lowest free
    -- one. A full wheel without a replace is the Market's "Replace" prompt, so
    -- reaching here is a stale page.
    local k = type(replace) == 'string' and slotHolding(entry, replace) or nil
    k = k or firstFree(entry)
    if not k then
        refuse(src, 'That could not be equipped.')
        BR.Market.push(src)
        return nil
    end
    if entry.emoteBusy[k] then
        BR.Market.push(src)
        return nil
    end
    if slotWriteOver(entry, GetGameTimer()) then
        BR.Market.push(src)
        return nil
    end

    local previous = entry.emotes[k]
    entry.emotes[k] = item.id
    entry.emoteBusy[k] = true

    ask('br:ddb:equip', function(ok, extra)
        entry.emoteBusy[k] = nil
        if not ok then
            if entry.emotes[k] == item.id then
                entry.emotes[k] = (previous ~= nil and slotHolding(entry, previous) == nil)
                    and previous or nil
            end
            refuse(src, 'That could not be equipped.')
            print(('^3[br_core] market: equip %s into emote%d failed for %s (%s)^7')
                :format(item.id, k, src, (extra and (extra.refused or extra.error)) or '?'))
            BR.Market.push(src)
            return
        end
        if not quiet then BR.Market.push(src) end
    end, lic, 'emote' .. k, item.id, false)

    -- `ask` answers at once when br_ddb is not started, and that answer has
    -- already rolled the slot back; only a write still standing is a slot.
    return entry.emotes[k] == item.id and k or nil
end

--- Equip an item into its slot.
--- @param src integer
--- @param id string
--- @param quiet boolean|nil  suppress the state push (the caller will push)
--- @param replace string|nil  EMOTES ONLY: the dance whose wheel slot this takes
--- @return integer|nil  EMOTES ONLY: the wheel slot it went into
function BR.Market.equip(src, id, quiet, replace)
    local lic = licenseOf[src]
    local entry = lic and inv[lic]
    if not entry then return end

    local item = BR.Config.MarketIndex[tostring(id or '')]
    if not item then return end
    if emoteHidden(item) then return nil end
    if item.kind == 'emote' then
        return equipEmote(src, lic, entry, item, replace, quiet)
    end

    -- Defaults are owned by everybody and appear in nobody's owned set, so
    -- they are the one case allowed to skip the ownership condition.
    local isDefault = item.default == true
    if not isDefault and not entry.owned[item.id] then
        refuse(src, 'You do not own that.')
        return
    end

    local previous = entry.equipped[item.kind]
    entry.equipped[item.kind] = item.id

    ask('br:ddb:equip', function(ok, extra)
        if not ok then
            -- PUT IT BACK. The cache was updated optimistically so the page
            -- feels instant, and that is only defensible if a rejected write
            -- undoes it -- otherwise the player spends the session believing
            -- they are wearing something the database never accepted.
            entry.equipped[item.kind] = previous
            refuse(src, 'That could not be equipped.')
            print(('^3[br_core] market: equip %s failed for %s (%s)^7')
                :format(item.id, src, (extra and (extra.refused or extra.error)) or '?'))
            BR.Market.push(src)
            return
        end
        if not quiet then BR.Market.push(src) end
    end, lic, item.kind, item.id, isDefault)
end

RegisterNetEvent(BR.Net.MARKET_EQUIP)
AddEventHandler(BR.Net.MARKET_EQUIP, function(data)
    local src = source
    -- `replace` is the emote wheel's swap (#215): the dance whose slot this
    -- one takes. Every other kind ignores it.
    BR.Market.equip(src, type(data) == 'table' and data.id or data, nil,
        type(data) == 'table' and type(data.replace) == 'string' and data.replace or nil)
end)

--- Take a dance off the wheel (#215). Emote slots only: every other kind has a
--- default to fall back to and no un-equip.
---
--- SAME GUARDS AS equipEmote, and the same duplicate-safe rollback: a failed
--- REMOVE puts the dance back only when the slot is still empty and no other
--- slot has taken it meanwhile.
--- @param src integer
--- @param id string
--- @param quiet boolean|nil
function BR.Market.unequip(src, id, quiet)
    local lic = licenseOf[src]
    local entry = lic and inv[lic]
    if not entry or not entry.emotes then return end

    local item = BR.Config.MarketIndex[tostring(id or '')]
    if not item or emoteHidden(item) or item.kind ~= 'emote' then return end

    local k = slotHolding(entry, item.id)
    if not k then
        BR.Market.push(src)
        return
    end
    if entry.emoteBusy[k] or slotWriteOver(entry, GetGameTimer()) then
        BR.Market.push(src)
        return
    end

    entry.emotes[k] = nil
    entry.emoteBusy[k] = true

    ask('br:ddb:unequip', function(ok, extra)
        entry.emoteBusy[k] = nil
        if not ok then
            if entry.emotes[k] == nil and slotHolding(entry, item.id) == nil then
                entry.emotes[k] = item.id
            end
            refuse(src, 'That could not be unequipped.')
            print(('^3[br_core] market: unequip %s from emote%d failed for %s (%s)^7')
                :format(item.id, k, src, (extra and (extra.refused or extra.error)) or '?'))
            BR.Market.push(src)
            return
        end
        if not quiet then BR.Market.push(src) end
    end, lic, 'emote' .. k)
end

RegisterNetEvent(BR.Net.MARKET_UNEQUIP)
AddEventHandler(BR.Net.MARKET_UNEQUIP, function(data)
    local src = source
    if not (BR.Season and BR.Season.has and BR.Season.has('emotes')) then return end
    BR.Market.unequip(src, type(data) == 'table' and data.id or nil)
end)

--- Hand a player a dance without charging for it: `bremotegrant`'s write (#215).
---
--- ═══ THE LICENSE IS CAPTURED BY THE CALLER AND CHECKED TWICE ═══
---
--- Once here and once when br_ddb answers, because FiveM recycles server ids
--- within the minute and a DynamoDB write is up to six seconds: the player
--- sitting at `src` when the answer lands may not be the one the console named.
--- A mismatch answers 'player changed' and touches no cache.
---
--- `answer`, NOT THE CHARGE PATH'S CALLBACK NAME: tools/test_shop.lua pins
--- that spelling in this file, and this is not that path.
--- @param src integer
--- @param id string
--- @param answer fun(ok:boolean, why:string|nil)
--- @param lic string
function BR.Market.addOwned(src, id, answer, lic)
    if licenseOf[src] ~= lic then answer(false, 'player changed') return end
    local entry = inv[lic]
    if not entry or not entry.loaded then answer(false, 'profile not loaded yet') return end
    local item = BR.Config.MarketIndex[tostring(id or '')]
    if not item or item.kind ~= 'emote' then answer(false, 'not an emote') return end
    if emoteHidden(item) then answer(false, 'emotes are off') return end
    if entry.owned[item.id] then answer(false, 'already owned') return end

    ask('br:ddb:ownedAdd', function(ok, extra)
        extra = extra or {}
        if licenseOf[src] ~= lic then answer(false, 'player changed') return end
        if ok then
            entry.owned[item.id] = true
            -- GRANTED MEANS ON THE WHEEL, when there is room -- the purchase's
            -- rule, so a granted dance and a bought one land the same way,
            -- and a full wheel is not a refusal toast at the player.
            if firstFree(entry) then BR.Market.equip(src, item.id, true) end
            BR.Market.push(src)
            answer(true)
        elseif extra.refused == 'already owned' then
            -- The row knew better than the cache: believe the row.
            entry.owned[item.id] = true
            BR.Market.push(src)
            answer(false, 'already owned')
        else
            answer(false, extra.error or extra.refused or '?')
        end
    end, lic, item.id)
end

-- ---------------------------------------------------------------------------
-- SPENDING VOLTS ON SOMETHING THAT IS NOT A COSMETIC (#224)
-- ---------------------------------------------------------------------------
--
-- The warmup vehicle shop buys a CAR out of the saved balance, and a car is not
-- a cosmetic: it is bought again every match, so it cannot go through
-- MARKET_BUY. `br:ddb:purchase` is one conditional write that debits the balance
-- AND adds the id to the profile's `owned` string set, refusing when the set
-- already contains it -- which is exactly right for a canopy you own forever and
-- exactly wrong for a repeatable spend.
--
-- ═══ IT WAS A SESSION LEDGER, AND IT IS A DYNAMODB WRITE NOW ═══
--
-- THE FIRST SHAPE, KEPT HERE BECAUSE THE COST OF IT IS THE REASON THIS CHANGED:
-- the session cache was decremented at the purchase and the total was folded
-- into `deltas.balance` at match end, so the ONE atomic ADD that writes every
-- match's payout wrote the debit with it. No second writer and no new br_ddb
-- verb -- and the debit was not durable until the match ended, which cost two
-- real things:
--
--   * A PLAYER WHO DISCONNECTED BEFORE THE PAYOUT KEPT THE VOLTS. They also
--     lost the car and the match, so it was not an exploit worth building for,
--     but it was not nothing either.
--   * A SERVER RESTARTED MID-MATCH LOST THE DEBIT for the same reason.
--
-- Both were the same fact: the money moved in memory and something else had to
-- remember to write it down later.
--
-- ═══ SO THE DEBIT IS A CONDITIONAL WRITE, TAKEN AT THE PURCHASE ═══
--
-- `br:ddb:spend` is one UpdateItem -- `ADD #bal :neg` under
-- `ConditionExpression: #bal >= :cost`, and NO `owned` set, which is the clause
-- that makes it a different verb from `br:ddb:purchase` rather than a parameter
-- of it. js-src/br_ddb/src/spend.js carries the whole argument.
--
-- DYNAMODB DECIDES, NOT THIS FILE. The affordability test below still runs and
-- is still worth running -- it refuses instantly, it can say how short somebody
-- is, and it stops an obvious no from costing a round trip -- but it is a
-- CONVENIENCE and never the authority. The cache is one read taken on connect;
-- a report award, a console grant or a second server can move the row
-- underneath it, and a debit that trusted a stale cache would overdraw a real
-- balance. The same rule `br:market:credited` states at the bottom of this
-- file, now enforced on the way out as well as on the way in.
--
-- NOTHING IS DELIVERED BEFORE THE ROW MOVES. `charge` answers through a
-- callback, and every caller does its bookkeeping inside it.

--- ═══ TWO NUMBERS, AND ONLY ONE OF THEM IS MONEY YOU CAN SPEND ═══
---
---   entry.balance  MIRRORS THE ROW. It moves only when the row moves: read on
---                  connect, written by a DynamoDB purchase or spend, added to
---                  by a payout. It is a claim about what DynamoDB holds.
---   entry.spent    IS RESERVED AND IN FLIGHT. It grows the moment a charge is
---                  asked for and shrinks again when the answer arrives --
---                  downward on a refusal, or by moving into `balance` on a
---                  success. It is never larger than the charges currently
---                  waiting on DynamoDB, and it is what stops two presses
---                  inside one round trip spending the same Volts twice.
---
--- SPENDABLE IS THE DIFFERENCE, and every reader of "how much has this player
--- got" goes through here rather than reading `balance`. Getting that wrong is
--- how the same 750 Volts buys a car and a canopy in the same warmup.
--- @param src integer
--- @return integer
function BR.Market.balanceOf(src)
    local lic = licenseOf[src]
    local entry = lic and inv[lic]
    if not entry or not entry.loaded then return 0 end
    return BR.Market.spendable(entry)
end

--- The spendable figure for one cached entry.
--- @param entry table|nil
--- @return integer
function BR.Market.spendable(entry)
    if not entry then return 0 end
    return math.floor((tonumber(entry.balance) or 0)
                      - (tonumber(entry.spent) or 0))
end

--- Say the market's "you cannot afford this" sentence.
---
--- THE MARKET'S WORDING, NOT A SECOND ONE. #224 shipped exactly three
--- player-facing strings and none of them is a refusal; the owner's standing
--- rule is that unrequested copy reads as slop. This is the sentence the
--- storefront has always used for the same fact, and since 2026-09-11 it is HIS
--- sentence rather than ours -- see SHORTFALL at the top of this file.
---
--- ═══ THE PRICE IS STILL A PARAMETER AND IT NO LONGER REACHES THE PLAYER ═══
---
--- The sentence used to quote the shortfall to the Volt; it does not any more.
--- `price` survives because the GUARD below survives, and the guard is not
--- cosmetic: a caller that is not actually short says nothing, and the cue rides
--- on the toast, so a call that says nothing plays nothing. Deleting the
--- parameter would make every refusal speak, including the ones where the row
--- moved underneath a stale cache and the player can in fact afford it.
--- @param src integer
--- @param price number
function BR.Market.tellShortfall(src, price)
    local need = math.floor((tonumber(price) or 0) - BR.Market.balanceOf(src))
    if need <= 0 then return end
    -- ═══ THE FUNNEL EVERY CHARGE-SIDE SHORTFALL REACHES, WHICH IS WHY THE
    --     SOUND IS HERE AND NOT AT THE THREE CALL SITES ═══
    --
    -- Owner, 2026-09-08: "Shop insufficient funds" is what he picked
    -- `shop.denied` for. Three callers reach this function -- the warmup vehicle
    -- showroom (server/shop.lua) and both arms of BR.Market.charge, which is the
    -- revive-key purchase's path -- so one line here is all three, and a fourth
    -- caller added later inherits it without anybody remembering to.
    --
    -- ⚠ IT IS NOT THE ONLY SPEAKER OF THE SENTENCE, AND SAYING IT WAS IS HOW A
    -- WHOLE SURFACE GOT MISSED. The Store screen's MARKET_BUY handler, in this
    -- same file, refuses a purchase it cannot afford WITHOUT coming through
    -- here, so a count of this function's callers is a count of three out of
    -- four. What both share is the SHORTFALL constant at the top of the file;
    -- what they do not share is this cue, deliberately. The gun shop is a fifth
    -- surface and is off this path entirely -- it speaks config/gunshop.lua's
    -- `poorToast`, which the owner wrote for that counter.
    --
    -- CARRIED ON THE TOAST RATHER THAN SENT BESIDE IT. A separate SFX_CUE would
    -- race the sentence and, worse, would play ON TOP of the general warn sound
    -- br_ui/client/nui.lua gives every warn toast -- two sounds for one refusal.
    -- Riding the payload makes it a REPLACEMENT by construction.
    --
    -- AND IT IS BELOW THE `need <= 0` GUARD, so a call that says nothing plays
    -- nothing. The sound and the sentence are the same event or they are neither.
    refuse(src, SHORTFALL, 'shop.denied')
end

--- Take Volts for something that is not a cosmetic, durably.
---
--- ═══ IT ANSWERS THROUGH A CALLBACK, AND THAT IS THE POINT ═══
---
--- This used to return a boolean, synchronously, off the session cache -- so
--- the caller could deliver the goods on the same line it took the money, and
--- the row was only told at match end. It is a DynamoDB write now, and the
--- caller does not learn the answer until DynamoDB gives one. Every caller does
--- its bookkeeping inside `done` for exactly that reason: the goods must not
--- exist before the debit does.
---
--- THREE THINGS HAPPEN IN ORDER, AND THE MIDDLE ONE IS WHY `spent` EXISTS:
---
---   1. the cache is asked whether this is obviously unaffordable, which
---      refuses instantly and speaks the market's existing shortfall sentence;
---   2. the amount is RESERVED against the cache and the lobby is pushed the
---      new figure -- so a second press arriving during the round trip sees the
---      money already gone and cannot spend it again;
---   3. `br:ddb:spend` asks the row, and the row decides.
---
--- A refusal releases the reservation and pushes again, so a player who was
--- refused is looking at the number they actually have.
---
--- ═══ AND IT HANDS BACK WHAT IS LEFT, BECAUSE THE CALLER MUST NOT RE-DERIVE IT
---     ═══
---
--- The third argument to `done` is the balance AFTER the debit, and it exists
--- because #239 wants it in a toast: "Your new balance is: [X] Volts."
---
--- IT IS THE ROW'S ANSWER, NOT ARITHMETIC. `br:ddb:spend` writes with
--- ReturnValues UPDATED_NEW, so `extra.balance` is what the row holds after the
--- conditional write -- and a caller doing `balance - price` for itself would
--- disagree with it the moment another writer (a report award, a console grant,
--- a second server) moved the row between the read and the press. That is the
--- exact case the debit was moved into DynamoDB to fix, and re-deriving the
--- figure here would reintroduce it in the one place a player reads it.
---
--- IT IS ALSO THE NUMBER THE STORE SCREEN SHOWS, by construction: BR.Market.push
--- sends `BR.Market.spendable(entry)` and this is the same call on the same
--- entry one line later. A toast and a screen that disagreed about a balance
--- would be worse than either of them being absent.
---
--- NIL ON A REFUSAL. There is no "new" balance when nothing was charged, and a
--- caller that printed one would be quoting a figure for a purchase that did not
--- happen.
---
--- @param src integer
--- @param amount number
--- @param reason string  for the console line only; never shown to a player
--- @param done fun(ok:boolean, why:string|nil, balance:integer|nil)|nil
function BR.Market.charge(src, amount, reason, done)
    done = done or function() end

    local lic = licenseOf[src]
    local entry = lic and inv[lic]
    if not entry or not entry.loaded then
        done(false, 'profile not loaded')
        return
    end

    local cost = math.floor(tonumber(amount) or 0)
    if cost <= 0 then
        done(false, 'nothing to charge')
        return
    end

    -- THE CONVENIENCE CHECK, NOT THE AUTHORITY. See the block above: this
    -- exists to refuse the obvious case without a round trip and to say how
    -- short they are. The row is still asked below whenever this passes.
    if BR.Market.spendable(entry) < cost then
        BR.Market.tellShortfall(src, cost)
        done(false, 'cannot afford it')
        return
    end

    -- RESERVED, NOT SPENT. `balance` is a claim about what DynamoDB holds and
    -- DynamoDB has not answered yet, so the reservation lives in `spent` and
    -- the two are reconciled when it does.
    entry.spent = (tonumber(entry.spent) or 0) + cost

    -- THE LOBBY SEES THE NEW NUMBER AT ONCE. A balance that only falls when the
    -- write lands is a balance a player would try to spend twice while it is in
    -- flight.
    BR.Market.push(src)

    ask('br:ddb:spend', function(ok, extra)
        extra = extra or {}

        -- The reservation is released either way; on success the same amount
        -- leaves `balance` instead, so `spendable` does not move and the lobby
        -- does not flicker.
        entry.spent = math.max(0, (tonumber(entry.spent) or 0) - cost)

        if ok then
            -- THE ROW'S OWN FIGURE WHERE THERE IS ONE. `UPDATED_NEW` hands back
            -- the balance after the debit, which is better than arithmetic on a
            -- cache that another writer may have moved.
            entry.balance = tonumber(extra.balance) or ((tonumber(entry.balance) or 0) - cost)
            BR.Market.push(src)

            -- ═══ THE MATCH LEDGER'S SPEND COLUMN, AND IT IS ONLY EVER MOVED
            --     HERE (#293) ═══
            --
            -- Volts spent in a match were recorded nowhere in any form. The
            -- debit is a conditional write against the row, so once it settles
            -- the only trace is a smaller balance -- and `entry.spent` a few
            -- lines up is NOT a total of anything: it is an in-flight
            -- reservation, released on this line's own arm and on the refusal
            -- below, so it is zero almost always.
            --
            -- INSIDE THE SUCCESS ARM, WHICH IS THE WHOLE RULE. Counting at the
            -- reservation would bank every refused purchase -- and the case
            -- that reaches the refusal arm is precisely the one the cache
            -- thought was affordable, so it is neither rare nor visible.
            --
            -- ONE PLACE, THREE SPEND PATHS. The warmup showroom
            -- (server/shop.lua), the gun shop (server/gunshop.lua) and the
            -- revive key (server/revivekey.lua) all charge through this
            -- function, so all three are counted without any of them knowing
            -- about the counter, and a fourth added later is counted too.
            --
            -- WHICH MATCH A WARMUP SPEND BELONGS TO: the one the player then
            -- plays, and it needs no arranging. The showroom refuses a buyer
            -- with no matchId, so by the time this line runs the entry is
            -- already attached to that match -- and the only thing that zeroes
            -- the counter, BR.Match.resetPlayer, does not run until that match
            -- reaches CLEANUP or the player walks out of it (#161).
            --
            -- THE ROSTER IS RE-READ AFTER THE ROUND TRIP RATHER THAN CAPTURED
            -- BEFORE IT. A DynamoDB write is up to six seconds; a player can
            -- disconnect inside one and FiveM recycles server ids within the
            -- minute, so the entry sitting at this `src` may belong to somebody
            -- else by now. The license is checked against the one that was
            -- charged, and a mismatch drops the count rather than filing it
            -- against a stranger -- the same rule server/roster.lua applies to
            -- every other per-src cache it forgets on disconnect.
            local e = BR.Roster and BR.Roster.get and BR.Roster.get(src)
            if e and BR.Roster.licenseOf(src) == lic then
                e.voltsSpent = (tonumber(e.voltsSpent) or 0) + cost
            end
            -- ONE READ, THREE USES. The console line, the Store screen (pushed
            -- one line above, out of the same call) and the caller's toast all
            -- quote this, so there is no arrangement in which they disagree.
            local left = BR.Market.spendable(entry)
            print(('[br_core] market: %s charged %d Volts (%s) -- %d left')
                :format(tostring(lic), cost, tostring(reason), left))
            done(true, nil, left)
            return
        end

        -- ═══ REFUSED BY THE ROW, WHICH THE CACHE THOUGHT COULD AFFORD IT ═══
        --
        -- Reachable whenever the cache is stale -- a report award, a console
        -- grant, or this license connected somewhere else. The cache is
        -- corrected from the answer where the answer carries one, so the second
        -- attempt is refused by this side instantly rather than by another
        -- round trip.
        if extra.balance then entry.balance = tonumber(extra.balance) or entry.balance end
        BR.Market.push(src)

        local why = extra.refused or extra.error or 'the write did not land'
        if extra.refused then BR.Market.tellShortfall(src, cost) end
        print(('^3[br_core] market: %s was NOT charged %d Volts (%s) -- %s^7')
            :format(tostring(lic), cost, tostring(reason), tostring(why)))
        done(false, why)
    end, lic, cost)
end

--- The license BR.Market.charge charges this source under, or nil before its
--- profile has loaded.
---
--- FOR A CALLER THAT MAY HAVE TO REFUND AFTER THE PLAYER HAS GONE. The license
--- outlives the source: a Season 2 terminal run (server/terminal.lua) is paid
--- for when it is accepted and carried out seconds later, and a player who
--- disconnects in between is refunded against the row, not the source.
--- @param src integer
--- @return string|nil
function BR.Market.licenseOf(src)
    return licenseOf[src]
end

--- A match paid out (or a refund landed): mirror it into the cache the lobby
--- reads.
---
--- THE WRITE ALREADY HAPPENED ELSEWHERE. br_stats owns the atomic ADD; this
--- only keeps the in-memory copy from going stale, so the numbers do not have
--- to be re-read to be seen. If this event is ever lost the cache is merely old
--- until the next reconnect -- it can never be wrong in a way that lets
--- somebody spend money they do not have, because the purchase condition is
--- evaluated by DynamoDB against the real row and not against this.
---
--- A LOCAL BEFORE IT IS AN EVENT: `br:market:credited` (registered below)
--- is this, and BR.Market.refund calls it directly for its own credit.
--- @param license string
--- @param xpEarned number
--- @param volts number
local function credit(license, xpEarned, volts)
    local entry = inv[license]
    if not entry then return end

    entry.xp = (entry.xp or 0) + (tonumber(xpEarned) or 0)
    entry.balance = (entry.balance or 0) + (tonumber(volts) or 0)

    -- Republished so the NEXT match starts from the right total rather than
    -- from the one read on connect.
    BR.Market.publishXp(license)

    for src, lic in pairs(licenseOf) do
        if lic == license then BR.Market.push(src) end
    end
end

--- Refunds waiting on br_ddb. [req] = callback.
---
--- STRING REQUEST IDS, AND THAT IS WHAT MAKES SHARING THE VERB SAFE.
--- `br:ddb:statsApply` answers on `br:ddb:statsResult`, which br_stats (the
--- match payout) and `brvolts` also listen to, each with numeric ids of its
--- own. A refund's id is 'market-refund:<n>', which no numeric counter can
--- produce, so each listener only ever recognizes its own answers.
local refunds = {}
local refundSeq = 0

AddEventHandler('br:ddb:statsResult', function(req, ok, extra)
    local cb = type(req) == 'string' and refunds[req] or nil
    if not cb then return end
    refunds[req] = nil
    cb(ok == true, extra or {})
end)

--- Give back Volts a charge took, when what was paid for could not happen.
---
--- ═══ THE PAYOUT'S OWN WRITE, NOT A NEW ONE ═══
---
--- `br:ddb:statsApply` with `{ balance = n }` is the unconditional atomic ADD
--- a match payout and `brvolts` already use (js-src/br_ddb/src/stats.js:
--- every other counter is ADDed zero). A refund is the one Volts movement that
--- can only ever make a row whole again, so it needs no condition: it is the
--- exact amount a successful BR.Market.charge took, for a purchase that did
--- not happen, asked for once.
---
--- ═══ ONE CALLER TODAY: A TERMINAL RUN WHOSE EFFECT COULD NOT HAPPEN ═══
---
--- (server/terminal.lua, owner 2026-10-05 round 2: a paid run is charged when
--- it is accepted and carried out three to five seconds later; a match that
--- ended in between, or another airdrop that appeared, refunds it.) Every
--- other spend path in the game delivers inside `charge`'s callback and has
--- nothing to give back.
---
--- THE CACHE AND THE MATCH LEDGER FOLLOW THE ROW, AS THEY DO FOR A CHARGE:
--- `credit` (what `br:market:credited` runs) moves the balance and pushes the
--- lobby, exactly as a payout does, and the `voltsSpent` the charge added to this match's ledger is
--- taken off again. A refund that does not land is said loudly on the console
--- and never retried: the row still holds the debit, and a retry that raced a
--- late answer would pay twice.
--- @param lic string  BR.Market.licenseOf at the time of the charge
--- @param amount number
--- @param reason string  for the console only
--- @param done fun(ok:boolean, why:string|nil, balance:integer|nil)|nil
function BR.Market.refund(lic, amount, reason, done)
    done = done or function() end
    local n = math.floor(tonumber(amount) or 0)
    if type(lic) ~= 'string' or lic == '' or n <= 0 then
        done(false, 'nothing to refund')
        return
    end
    if GetResourceState('br_ddb') ~= 'started' then
        print(('^1[br_core] market: %s was NOT refunded %d Volts (%s) -- br_ddb is not started^7')
            :format(lic, n, tostring(reason)))
        done(false, 'br_ddb not started')
        return
    end
    refundSeq = refundSeq + 1
    local req = ('market-refund:%d'):format(refundSeq)
    refunds[req] = function(ok, extra)
        if not ok then
            print(('^1[br_core] market: %s was NOT refunded %d Volts (%s) -- %s^7')
                :format(lic, n, tostring(reason), tostring(extra.error or 'the write did not land')))
            done(false, extra.error or 'the write did not land')
            return
        end
        credit(lic, 0, n)
        for src, l in pairs(licenseOf) do
            local e = l == lic and BR.Roster and BR.Roster.get and BR.Roster.get(src) or nil
            if e and BR.Roster.licenseOf(src) == lic then
                e.voltsSpent = math.max(0, (tonumber(e.voltsSpent) or 0) - n)
            end
        end
        local left = BR.Market.spendable(inv[lic])
        print(('[br_core] market: %s refunded %d Volts (%s) -- %d now'):format(lic, n, tostring(reason), left))
        done(true, nil, left)
    end
    SetTimeout(8000, function()
        if not refunds[req] then return end
        refunds[req] = nil
        print(('^1[br_core] market: no answer from br_ddb refunding %s %d Volts (%s) -- the write '
            .. 'may or may not have landed^7'):format(lic, n, tostring(reason)))
        done(false, 'timed out')
    end)
    TriggerEvent('br:ddb:statsApply', req, lic, { balance = n })
end

AddEventHandler('br:market:credited', credit)

AddEventHandler('playerDropped', function()
    local src = source
    local lic = licenseOf[src]
    licenseOf[src] = nil
    if not lic then return end
    -- Only drop the cached inventory if nobody else is holding the same
    -- license. Two connections on one license should not be possible, but a
    -- reconnect racing a drop is, and evicting the live session's inventory
    -- would silently empty a playing player's market.
    for _, other in pairs(licenseOf) do
        if other == lic then return end
    end
    inv[lic] = nil
end)

-- ---------------------------------------------------------------------------
-- The guided first run's one persisted fact (#261)
-- ---------------------------------------------------------------------------

--- Has this account answered the tutorial offer, and how?
---
--- '' -- never. 'declined' -- they turned it down. 'done' -- they finished it.
---
--- READ OFF THE PROFILE ROW, which this file already fetches once per connect.
--- It lives beside the balance because it is a fact about the ACCOUNT, and
--- because putting it anywhere else would mean a second read on a path that
--- already has one.
--- @param license string|nil
--- @return string
function BR.Market.tutorialOf(license)
    local e = license and inv[license]
    return (e and type(e.tutorial) == 'string') and e.tutorial or ''
end

--- Write it, once, and remember it locally so the rest of the session agrees.
---
--- ═══ BOTH STATES ARE TERMINAL AND NEITHER OUTRANKS THE OTHER ═══
---
--- 'declined' and 'done' mean the same thing to every reader -- do not offer
--- this again -- and are kept apart only so a human reading the row can tell
--- why. So there is no precedence rule here and none in br_ddb: the last writer
--- wins, and it cannot matter.
---
--- THE CACHE MOVES FIRST AND THE ROW FOLLOWS. A player who declines and then
--- readies up must not be offered it again in the seconds before DynamoDB
--- answers, and the write is idempotent, so a failure costs one re-offer on
--- their next connect rather than a wrong answer now.
--- @param license string|nil
--- @param state string  'declined' or 'done'
function BR.Market.setTutorial(license, state)
    if type(license) ~= 'string' or license == '' then return end
    if state ~= 'declined' and state ~= 'done' then return end

    local e = inv[license]
    if e then e.tutorial = state end

    ask('br:ddb:tutorialSet', function(ok, extra)
        if ok then return end
        print(('^3[br_core] market: tutorial state (%s) not saved for %s: %s^7')
            :format(state, license, tostring((extra or {}).error)))
    end, license, state)
end

--- br_stats finished paying (or refusing) the tutorial reward.
---
--- A CLIENT-LOCAL EVENT BETWEEN TWO RESOURCES' SERVER HALVES, which is the seam
--- `br:market:credited` already uses in the other direction. br_stats owns the
--- payment and this file owns the profile cache; neither reaches into the other.
AddEventHandler('br:market:tutorialDone', function(license)
    BR.Market.setTutorial(license, 'done')
end)

--- The player unticked the box themselves.
---
--- AN ABANDONED RUN IS NOT THIS. Owner, 2026-09-07: "leaving the game tutorial
--- early results in the toggle still being available in the lobby - great, keep
--- it." Only an explicit decline closes the offer, which is why this is its own
--- message rather than a flag on the one that ends a run.
RegisterNetEvent(BR.Net.TUTORIAL_DECLINE)
AddEventHandler(BR.Net.TUTORIAL_DECLINE, function()
    local src = source
    local lic = BR.Roster.licenseOf(src)
    if not lic then return end
    print(('[br_core] market: %d declined the tutorial -- not offering again')
        :format(src))
    BR.Market.setTutorial(lic, 'declined')
end)

-- ---------------------------------------------------------------------------
-- Putting the offer back, for testing (#353)
-- ---------------------------------------------------------------------------

--- Put an account back where it started with the offer, for this session.
---
--- ═══ WHY THERE IS A TOOL FOR THIS AT ALL ═══
---
--- Owner, 2026-09-22: "can you make a server command which clears the tutorial
--- completed status for a given player and shows the toggle in the lobby? I want
--- to test something cause our players told us the tutorial is broken on 4k
--- displays and has steps which display outside the bounds of the screen."
---
--- Both answers are terminal and the row is read once per connect, so every
--- attempt at reproducing that report needed a fresh account. This is the tool
--- that ends that, and nothing in the game reads it.
---
--- ═══ IT CLEARS THE CACHE AND RE-PUSHES. IT DOES NOT WRITE THE ROW ═══
---
--- Not `setTutorial(license, '')`, because there is no way to say '' to the
--- database from here: br_ddb's `br:ddb:tutorialSet` refuses any state but
--- 'declined' and 'done' before it builds an expression, and widening it means
--- editing js-src/br_ddb/src and rebuilding the bundle -- which
--- tools/br_ddb_fingerprint.sh pins and which no box here can currently rebuild
--- (that script's own header says why).
---
--- SO THE LIMIT IS REAL, AND THE COMMAND SAYS IT OUT LOUD. This lasts for the
--- player's current connection: their next connect reads the row, which still
--- says what it said, and the offer is gone again. A tool that needed a
--- reconnect without admitting it would be worse than no tool.
---
--- ═══ THE CACHE IS NOT COSMETIC, WHICH IS THE HALF THAT SURPRISES ═══
---
--- `entry.tutorial` is consulted long after the connect: BR.Roster.setTutorialGame
--- asks BR.Market.tutorialOf before granting the warmup hold, and refuses an
--- account that has already answered. So clearing only the CLIENT's mirror --
--- which is all the client's own /brtutorial does -- puts the cards back and
--- leaves the in-game half's hold refused on any box not in dev mode.
---
--- KEYED OFF THIS FILE'S OWN `licenseOf`, not BR.Roster's. They agree today, and
--- this one is the key `inv` is actually stored under -- so the entry cleared and
--- the entry `push` reads cannot come apart.
--- @param src integer
--- @return string|nil  what the account used to say, or nil with no loaded profile
function BR.Market.clearTutorial(src)
    local lic = licenseOf[src]
    local entry = lic and inv[lic]
    if not entry or not entry.loaded then return nil end

    local was = type(entry.tutorial) == 'string' and entry.tutorial or ''
    entry.tutorial = ''

    -- THE CONNECT'S OWN MESSAGE, RE-SENT. The client's TUTORIAL_OFFER handler
    -- already turns one boolean into both the account's standing and the lobby
    -- checkbox, and the page already draws that toggle off them -- so there is
    -- nothing new to send and no new copy to write. A reset-shaped event would
    -- be a second way to say what this one already says.
    TriggerClientEvent(BR.Net.TUTORIAL_OFFER, src, { offer = true })
    return was
end

--- `brtutorialreset <serverId>` -- let one player take the walkthrough again.
---
--- BY SERVER ID, which is what every command here that names a player takes --
--- brgive, brarm, brvolts, brxpsim -- and the roster-entry test is brgive's,
--- answering brgive's question: is this a player, or just a number.
---
--- RESTRICTED RATHER THAN CONSOLE-ONLY. brvolts and brprofile refuse a client
--- because they read and write a stored row; this writes nothing persistent, so
--- it carries the br.admin ACE like brgive and brdown do.
---
--- DEV-GATED BY CONSTRUCTION, like every command in this project --
--- shared/devgate.lua wraps RegisterCommand once. Nothing extra here: a second
--- check would be a second mechanism for a rule that already holds.
RegisterCommand('brtutorialreset', function(_, args)
    local target = tonumber(args and args[1])
    if not target then
        print('  usage: brtutorialreset <serverId>')
        print('    clears that player\'s tutorial answer and puts the lobby')
        print('    toggle back, so the walkthrough can be run again without a')
        print('    fresh account')
        print('    THIS SESSION ONLY -- the stored profile row is not changed, so')
        print('    a reconnect brings their old answer back and this has to be')
        print('    run again')
        return
    end

    local entry = BR.Roster.get(target)
    if not entry then
        print(('  no roster entry for %d'):format(target))
        return
    end

    -- NO PROFILE, NO CLEAR, AND IT SAYS WHICH. The inventory read is one round
    -- trip on join, so this can be typed at a player whose answer has not
    -- arrived yet -- and clearing the seeded stub would be overwritten by the
    -- fetch a moment later. That is the one failure this tool cannot afford to
    -- have quietly.
    local was = BR.Market.clearTutorial(target)
    if not was then
        print(('  brtutorialreset: %s (%d) has no loaded profile yet -- their '
            .. 'inventory read has not come back. brprofile reads it.')
            :format(entry.name or '?', target))
        return
    end

    print(('[br_core] brtutorialreset: %s (%d) answered %s and is offerable '
           .. 'again -- the toggle is above Ready up in their lobby')
        :format(entry.name or '?', target,
                was == '' and 'nothing yet' or ('\'' .. was .. '\'')))
    print('  the stored row is untouched, so a reconnect undoes this')
end, true)
