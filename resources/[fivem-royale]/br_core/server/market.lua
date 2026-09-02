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
AddEventHandler('br:ddb:spendResult',     function(req, ok, extra) reply(req, ok, extra or {}) end)

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
        -- SPENDABLE, NOT THE ROW (#224). A player who has just bought a car in
        -- warmup has committed those Volts; a screen still showing them is a
        -- screen inviting them to be spent again. See BR.Market.balanceOf.
        balance  = BR.Market.spendable(entry),
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
        -- `push` republishes the lifetime XP to br_stats, so this branch --
        -- a reconnect racing a drop, where the license is still cached -- is
        -- covered without a second call here.
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
    -- `spent = 0` IS THE SAME KIND OF NOT-DECORATION (#224): Volts reserved
    -- against a charge that is in flight to DynamoDB. It is only ever moved by
    -- BR.Market.charge, which refuses while `loaded` is false -- so no spend can
    -- exist before the fetch below replaces this table.
    inv[lic] = withDefaults({ balance = 0, spent = 0, xp = 0, owned = {}, equipped = {}, loaded = false })

    ask('br:ddb:inventoryFetch', function(i, extra)
        local entry = { balance = 0, spent = 0, xp = 0, owned = {}, equipped = {}, loaded = true }

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
    -- SPENDABLE RATHER THAN THE ROW (#224). Volts already committed to a warmup
    -- car are gone even though DynamoDB has not been told yet, and this is the
    -- one condition on this side that could let them be spent twice. The
    -- DynamoDB condition below still guards the row itself -- it just cannot
    -- know about a debit that has not been written.
    local have = BR.Market.spendable(entry)
    if have < item.price then
        refuse(src, ('You need %d more to buy that.'):format(item.price - have))
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

--- Say the market's existing "you cannot afford this" sentence.
---
--- THE MARKET'S WORDING, NOT A SECOND ONE. #224 shipped exactly three
--- player-facing strings and none of them is a refusal; the owner's standing
--- rule is that unrequested copy reads as slop. This is the sentence the
--- storefront has always used for the same fact.
--- @param src integer
--- @param price number
function BR.Market.tellShortfall(src, price)
    local need = math.floor((tonumber(price) or 0) - BR.Market.balanceOf(src))
    if need <= 0 then return end
    refuse(src, ('You need %d more to buy that.'):format(need))
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
