-- The market and the progression readout.
--
-- BOTH SYSTEMS ARE REAL NOW. Balance, ownership, equipped slots and the XP
-- curve all come from the server, which reads them from DynamoDB. This file
-- renders what it is sent and forwards what the player pressed; it decides
-- nothing.
--
-- IT SENDS AN ID AND NOTHING ELSE. No price, no ownership claim, no balance --
-- every one of those is resolved server-side against BR.Config and the row, so
-- a modified client can ask for anything and receive exactly what it is owed.
-- Editing anything in this file achieves nothing except lying to yourself.
--
-- WHAT IS STILL SYNTHETIC is named as such below: the character, banner and
-- verdict kinds have no definitions yet, and they are kept only so the
-- storefront's shape stays honest while the defined kinds fill in.

local RES = GetCurrentResourceName()

BR = BR or {}
BR.Market = {}

-- REAL NOW, and seeded at level 1 rather than at the flattering synthetic
-- level 14 it used to hold. The server sends the true progression with the
-- market state; this is only what the bar shows in the moments before the
-- first one arrives, and a fake level 14 in that window is a number the player
-- would watch drop.
local PROFILE = { level = 1, xp = 0, needed = 1 }

--- The catalogue, from the shared season config.
---
--- MOVED OUT OF THIS FILE, because the list is the part that changes every
--- season and the code around it is not. `br_lib/config/market.lua` holds the
--- definitions organised by season, so adding a set is appending a block and
--- ending one is flipping `active` -- rather than editing the middle of a
--- table inline in the file that renders it.
---
--- The synthetic items below are the ones that have no definition yet: they
--- keep the screen honest about what the finished storefront looks like while
--- only the parachutes are real. They go the moment their kinds are defined.
local SYNTHETIC = {
    { id = 'ped_juggalo', name = 'Juggalo',   sub = 'Character',  kind = 'character', price = 1500, rarity = 2 },
    { id = 'ped_clown',   name = 'Clown',     sub = 'Character',  kind = 'character', price = 2500, rarity = 3 },
    { id = 'ped_trooper', name = 'Trooper',   sub = 'Character',  kind = 'character', price = 4000, rarity = 4, owned = true },
    { id = 'ped_yeti',    name = 'Yeti',      sub = 'Character',  kind = 'character', price = 9000, rarity = 5 },
    -- The trails that used to be here are real now, defined in the season
    -- config alongside the canopies and the weapon finishes. Leaving the
    -- synthetic pair behind would have put two "Ember"s in one grid, one of
    -- which could be bought and one of which could not.
    { id = 'ban_storm',   name = 'Stormchaser', sub = 'Banner',   kind = 'banner',    price = 1200, rarity = 3 },
    { id = 'ban_first',   name = 'Day One',   sub = 'Banner',     kind = 'banner',    price = 0,    rarity = 5, owned = true },
    { id = 'vd_royale',   name = 'Victory Royale', sub = 'Verdict', kind = 'verdict', price = 0,    rarity = 1, owned = true },
}

--- What the server says we own. Replaced wholesale on every MARKET_STATE.
---
--- NEVER WRITTEN OPTIMISTICALLY. A purchase does not mark itself owned here and
--- hope; it asks the server, the server writes conditionally, and the answer
--- comes back as a new state. The page can lag by one round trip -- it cannot
--- claim you own something the database refused.
local STATE = { balance = 0, owned = {}, equipped = {} }

--- Flatten the seasons into the list the NUI renders.
---
--- Defaults are marked owned rather than hidden: the free item is the thing you
--- go back to, so it has to be visible and selectable in the same grid as the
--- ones you paid for.
local function catalogue()
    local out = {}

    for _, season in ipairs(BR.Config.Market.seasons) do
        for _, item in ipairs(season.items) do
            local owned = item.default == true or STATE.owned[item.id] == true
            out[#out + 1] = {
                id       = item.id,
                name     = item.name,
                sub      = item.sub,
                kind     = item.kind,
                price    = item.price,
                rarity   = item.rarity,
                season   = item.seasonName,
                owned    = owned,
                equipped = STATE.equipped[item.kind] == item.id,
                -- Inactive seasons render for the people who own their items
                -- but cannot be bought from.
                locked   = not item.purchasable and not item.default,
            }
        end
    end

    for _, item in ipairs(SYNTHETIC) do out[#out + 1] = item end

    return out
end

function BR.Market.push()
    TriggerEvent('br:ui:sendLocal', BR.Nui.MARKET, {
        balance  = STATE.balance,
        -- Sent rather than hardcoded in the page, so renaming the currency is
        -- one line in the config instead of a search across two languages.
        currency = BR.Config.Market.currency,
        items    = catalogue(),
    })
end

--- The server's answer, and the only thing that changes what the page believes.
RegisterNetEvent(BR.Net.MARKET_STATE)
AddEventHandler(BR.Net.MARKET_STATE, function(state)
    if type(state) ~= 'table' then return end

    STATE.balance = tonumber(state.balance) or 0

    STATE.owned = {}
    for _, id in ipairs(state.owned or {}) do STATE.owned[id] = true end

    STATE.equipped = {}
    for kind, id in pairs(state.equipped or {}) do STATE.equipped[kind] = id end

    -- THE SERVER OWNS THE CURVE. It evaluates BR.Xp and sends the result, so
    -- this side never derives a level -- a client that computed its own would
    -- eventually disagree with the server about what level somebody is, and
    -- the player would believe the one in front of them.
    local pr = state.progress
    if type(pr) == 'table' then
        PROFILE.level  = tonumber(pr.level) or PROFILE.level
        PROFILE.xp     = tonumber(pr.xp) or PROFILE.xp
        PROFILE.needed = math.max(1, tonumber(pr.needed) or PROFILE.needed)
        BR.Market.pushProgress()
    end

    BR.Market.push()
end)

function BR.Market.pushProgress()
    TriggerEvent('br:ui:sendLocal', BR.Nui.PROGRESS, PROFILE)
end

RegisterNUICallback(BR.NuiCb.MARKET_FOCUS, function(data, cb)
    if data and data.open then
        TriggerEvent('br:ui:pushFocus', 'market')
    else
        TriggerEvent('br:ui:popFocus', 'market')
    end
    cb({ ok = true })
end)

-- BOTH VERBS JUST FORWARD, AND THAT IS THE POINT. This side sends an id and
-- nothing else -- no price, no ownership claim. Everything that could be lied
-- about is resolved server-side against BR.Config and the database, so a
-- modified client can ask for anything and get exactly what it is owed.
--
-- The callback resolves immediately rather than waiting for the outcome: CEF
-- promises must always resolve, and the real answer arrives as its own
-- MARKET_STATE. A page that awaited the round trip would hang on any dropped
-- message, which is the one failure this protocol is shaped to survive.
RegisterNUICallback(BR.NuiCb.MARKET_BUY, function(data, cb)
    TriggerServerEvent(BR.Net.MARKET_BUY, { id = tostring(data and data.id or '') })
    cb({ ok = true })
end)

RegisterNUICallback(BR.NuiCb.MARKET_EQUIP, function(data, cb)
    TriggerServerEvent(BR.Net.MARKET_EQUIP, { id = tostring(data and data.id or '') })
    cb({ ok = true })
end)

--- Award XP, push the new profile and the award that animates to it.
--- @param amount integer
function BR.Market.award(amount)
    amount = math.max(0, math.floor(tonumber(amount) or 0))
    if amount <= 0 then return end

    local fromLevel, fromXp, fromNeeded = PROFILE.level, PROFILE.xp, PROFILE.needed
    PROFILE.xp = PROFILE.xp + amount
    while PROFILE.xp >= PROFILE.needed do
        PROFILE.xp = PROFILE.xp - PROFILE.needed
        PROFILE.level = PROFILE.level + 1
        -- 15% steeper per level. Invented, like everything else here, but
        -- invented in ONE place so the curve is a number to argue about
        -- rather than a shape buried in an animation.
        PROFILE.needed = math.floor(PROFILE.needed * 1.15)
    end

    -- The new profile FIRST, then the award: the bar animates FROM where the
    -- award says it was, TO where the profile says it is now. Reversed, it
    -- would animate to a value it already held.
    TriggerEvent('br:ui:sendLocal', BR.Nui.PROGRESS, PROFILE)
    TriggerEvent('br:ui:sendLocal', BR.Nui.XP, {
        xp = amount, fromLevel = fromLevel, fromXp = fromXp, fromNeeded = fromNeeded,
    })
end

-- EVERY MATCH PAYS, AND IT PAYS ON THE VERDICT SCREEN.
--
-- The award has to land where the match ended -- while the player is still
-- looking at won-or-lost, over the teardown they are already waiting through
-- (user, 2026-08-09). On the lobby card it would arrive after a fade, a
-- teleport and a menu: three screens away from the thing that earned it.
--
-- The FORMULA IS SYNTHETIC, and it is the shape of the real one rather than a
-- placeholder number: a flat completion payment so a bad match still pays
-- something, a placement bonus that is steep at the top, and per-elimination
-- on top. Swapping in a server-issued `xpEarned` is a one-line change -- the
-- field is already on this payload and has always been zero.
--
-- br_ui registers the summary event itself rather than routing through
-- br_core: several resources may handle one net event, and progression is
-- presentation until there is a ledger behind it.
-- WHAT THE MATCH ACTUALLY PAID, straight through to the page.
--
-- The verdict screen owns the TIMING (it is the only thing that can see itself
-- on screen -- a delay timed from Lua has missed that window twice), so this
-- only delivers the numbers and lets EndScreen stage them.
RegisterNetEvent(BR.Net.MATCH_EARNED)
AddEventHandler(BR.Net.MATCH_EARNED, function(e)
    if type(e) ~= 'table' then return end
    TriggerEvent('br:ui:sendLocal', BR.Nui.EARNED, {
        xp      = tonumber(e.xp) or 0,
        volts   = tonumber(e.volts) or 0,
        level   = tonumber(e.level) or PROFILE.level,
        levelUp = e.levelUp == true,
    })
end)

RegisterNetEvent(BR.Net.SUMMARY)
AddEventHandler(BR.Net.SUMMARY, function(s)
    if not s then return end

    local placement = tonumber(s.placement) or 0
    local total     = tonumber(s.total) or 1
    local kills     = tonumber(s.kills) or 0

    local earned = 120                                   -- you turned up
    if s.won then
        earned = earned + 500                            -- and you won
    elseif placement > 0 and total > 1 then
        -- Linear in how far up you finished, which is enough shape to feel
        -- like placement matters without pretending to be tuned.
        earned = earned + math.floor(380 * (1.0 - (placement - 1) / (total - 1)))
    end
    earned = earned + kills * 60

    -- A beat after the verdict lands, so the slam owns the first moment and
    -- the bar is not already moving when the player looks at it. .end-late
    -- flies the supporting lines in at 3.6s; this arrives just behind them.
    -- THE AWARD IS THE INTERFACE'S NOW, and this is deliberately not doing
    -- it any more. It used to push one a couple of seconds after the summary
    -- arrived, timed against a verdict screen it cannot observe -- and the
    -- animation was reported as never appearing, twice, because a delay tuned
    -- against the teardown window misses it whenever teardown is quick.
    --
    -- screens/EndScreen.tsx fires the staged award from its own mount, which
    -- cannot miss a screen that has to exist for the timer to run at all.
    -- This handler keeps the FORMULA -- the shape of the real one -- so that
    -- swapping in a server-issued xpEarned is still a one-line change.
    print(('[br_ui] match XP would be +%d (placement %d/%d, %d kills)')
        :format(earned, placement, total, kills))
end)

AddEventHandler('br:ui:ready', function()
    -- ASK, THEN RENDER WHAT WE HAVE. The request goes to the server and the
    -- answer arrives as MARKET_STATE; pushing the current (possibly empty)
    -- state first means the page has a grid to draw rather than a blank screen
    -- for the length of a round trip.
    TriggerServerEvent(BR.Net.MARKET_STATE)
    BR.Market.push()
    BR.Market.pushProgress()
end)

RegisterCommand('brxp', function(_, args)
    -- Drives the award animation with a made-up number, so the post-match
    -- moment can be watched without playing a match. `brxp 900` fills the
    -- bar; a number big enough to cross `needed` runs the level-up.
    --
    -- IT NARRATES, because it reported doing nothing once and the interface
    -- half was provably fine (user, 2026-08-09). The two lines below split
    -- the failure cleanly: no output at all means this file never loaded and
    -- there is no level chip either; output with no movement means the
    -- envelope is arriving somewhere the interface is not listening.
    local amount = tonumber(args[1]) or 650
    local fromLevel, fromXp, fromNeeded = PROFILE.level, PROFILE.xp, PROFILE.needed

    PROFILE.xp = PROFILE.xp + amount
    while PROFILE.xp >= PROFILE.needed do
        PROFILE.xp = PROFILE.xp - PROFILE.needed
        PROFILE.level = PROFILE.level + 1
        PROFILE.needed = math.floor(PROFILE.needed * 1.15)
    end

    -- The new profile FIRST, then the award: the bar animates from where the
    -- award says it was, to where the profile says it is now. Reversed, it
    -- would animate to a value it already held.
    TriggerEvent('br:ui:sendLocal', BR.Nui.PROGRESS, PROFILE)
    TriggerEvent('br:ui:sendLocal', BR.Nui.XP, {
        xp = amount, fromLevel = fromLevel, fromXp = fromXp, fromNeeded = fromNeeded,
    })

    print(('[br_ui] brxp: sent "%s" %d/%d lvl %d, and "%s" +%d from lvl %d %d/%d')
        :format(tostring(BR.Nui.PROGRESS), PROFILE.xp, PROFILE.needed, PROFILE.level,
                tostring(BR.Nui.XP), amount, fromLevel, fromXp, fromNeeded))
    print('[br_ui] brxp: the bar only exists on the LOBBY screen -- if you are'
        .. ' in a match there is nothing on screen to move.')
end, false)

AddEventHandler('onClientResourceStart', function(res)
    if res ~= RES then return end
    BR.Market.push()
    BR.Market.pushProgress()
end)

-- THE TEARDOWN WAITS FOR THE AWARD.
--
-- The result sequence holds a black screen for a fixed time and then
-- teleports home, and that duration was a guess against an animation in
-- another process. Guesses lose: the level-up flip -- the one beat the whole
-- system is building to -- kept being cut off (owner, 2026-08-09).
--
-- The interface says when it is busy instead. br_core holds while this is
-- true, with its own hard cap so a page that never says "done" cannot strand
-- a player on a black screen.
RegisterNUICallback(BR.NuiCb.XP_BUSY, function(data, cb)
    TriggerEvent('br:xp:busy', data and data.busy == true)
    cb({ ok = true })
end)
