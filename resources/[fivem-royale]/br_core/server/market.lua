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

--- license -> { balance, owned = {id=true}, equipped = {kind=id}, loaded }
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

    local owned = {}
    for id in pairs(entry.owned) do owned[#owned + 1] = id end
    table.sort(owned)   -- never send a hash's iteration order over the wire

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
        balance  = entry.balance,
        owned    = owned,
        equipped = entry.equipped,
        progress = { level = level, xp = into, needed = needed, total = entry.xp },
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
        BR.Market.push(src)
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
    inv[lic] = withDefaults({ balance = 0, xp = 0, owned = {}, equipped = {}, loaded = false })

    ask('br:ddb:inventoryFetch', function(i, extra)
        local entry = { balance = 0, xp = 0, owned = {}, equipped = {}, loaded = true }

        if i then
            entry.balance = tonumber(i.balance) or 0
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
                if BR.Config.MarketIndex[id] then entry.equipped[kind] = id end
            end
        end
        if extra and extra.error then
            print(('^3[br_core] market: inventory read failed for %s (%s) -- defaults only^7')
                :format(src, extra.error))
        end

        inv[lic] = withDefaults(entry)
        BR.Market.publishXp(lic)
        BR.Market.push(src)
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
local function refuse(src, text)
    TriggerClientEvent(BR.Net.NOTIFY, src, { text = text, tone = 'warn', ms = 4000 })
end

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
    if not item then
        refuse(src, 'That item is not for sale.')
        print(('^3[br_core] market: %s tried to buy "%s" -- %s^7'):format(src, id, why))
        return
    end

    if entry.owned[id] then
        refuse(src, 'You already own that.')
        return
    end
    if entry.balance < item.price then
        refuse(src, ('You need %d more to buy that.'):format(item.price - entry.balance))
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
            BR.Market.equip(src, id, true)
            TriggerClientEvent(BR.Net.NOTIFY, src, {
                text = ('%s equipped.'):format(item.name), tone = 'success', ms = 4000,
            })
        else
            refuse(src, extra.refused and ('Purchase refused: ' .. extra.refused)
                or 'The purchase could not be completed. Nothing was charged.')
        end
        BR.Market.push(src)
    end, lic, id, item.price)
end)

--- Equip an item into its slot.
--- @param src integer
--- @param id string
--- @param quiet boolean|nil  suppress the state push (the caller will push)
function BR.Market.equip(src, id, quiet)
    local lic = licenseOf[src]
    local entry = lic and inv[lic]
    if not entry then return end

    local item = BR.Config.MarketIndex[tostring(id or '')]
    if not item then return end

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
    BR.Market.equip(src, type(data) == 'table' and data.id or data)
end)

--- A match paid out: mirror it into the cache the lobby reads.
---
--- THE WRITE ALREADY HAPPENED ELSEWHERE. br_stats owns the atomic ADD; this
--- only keeps the in-memory copy from going stale, so the numbers do not have
--- to be re-read to be seen. If this event is ever lost the cache is merely old
--- until the next reconnect -- it can never be wrong in a way that lets
--- somebody spend money they do not have, because the purchase condition is
--- evaluated by DynamoDB against the real row and not against this.
AddEventHandler('br:market:credited', function(license, xpEarned, volts)
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
end)

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
