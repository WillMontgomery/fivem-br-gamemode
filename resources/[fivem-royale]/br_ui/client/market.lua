-- The market and the progression readout.
--
-- NEITHER SYSTEM EXISTS YET, AND THIS FILE SAYS SO RATHER THAN PRETENDING.
--
-- There is no persistence in this project (M7b is the milestone that decides
-- where it lives), so there is nowhere to keep a balance, an inventory of
-- owned cosmetics, or an XP total that survives a reconnect. Building the
-- ledger before that decision is made would mean building it twice.
--
-- What DOES exist is the interface, and the interface is the part worth
-- arguing about first: what is for sale, what it costs relative to what a
-- match pays, whether the XP bar reads as a reward. So this serves a synthetic
-- profile and catalogue from a table, the screens render it exactly as they
-- will render the real one, and the day there is a server the only change is
-- where these two functions get their numbers.
--
-- IT IS ALL LOCAL. The values below never reach the server and nothing here
-- can be spent, so a player editing them achieves nothing except lying to
-- themselves about a mock.

local RES = GetCurrentResourceName()

BR = BR or {}
BR.Market = {}

-- SYNTHETIC. Delete this table and read a real profile: that is the whole
-- migration. The numbers are chosen to make the screens honest -- a level
-- mid-way through its bar, a balance that affords some things and not others,
-- and a couple of items already owned so both card states are visible.
local PROFILE = { level = 14, xp = 2380, needed = 4000 }

local CATALOGUE = {
    { id = 'ped_juggalo', name = 'Juggalo',   sub = 'Character',  kind = 'character', price = 1500, rarity = 2 },
    { id = 'ped_clown',   name = 'Clown',     sub = 'Character',  kind = 'character', price = 2500, rarity = 3 },
    { id = 'ped_trooper', name = 'Trooper',   sub = 'Character',  kind = 'character', price = 4000, rarity = 4, owned = true },
    { id = 'ped_yeti',    name = 'Yeti',      sub = 'Character',  kind = 'character', price = 9000, rarity = 5 },
    { id = 'ped_diver',   name = 'Diver',     sub = 'Character',  kind = 'character', price = 1500, rarity = 2 },
    { id = 'ped_agent',   name = 'Agent',     sub = 'Character',  kind = 'character', price = 3000, rarity = 3 },
    { id = 'trail_ember', name = 'Ember',     sub = 'Chute trail', kind = 'trail',    price = 800,  rarity = 2 },
    { id = 'trail_void',  name = 'Void',      sub = 'Chute trail', kind = 'trail',    price = 2000, rarity = 4 },
    { id = 'trail_gold',  name = 'Bullion',   sub = 'Chute trail', kind = 'trail',    price = 6000, rarity = 5 },
    { id = 'ban_storm',   name = 'Stormchaser', sub = 'Banner',   kind = 'banner',    price = 1200, rarity = 3 },
    { id = 'ban_first',   name = 'Day One',   sub = 'Banner',     kind = 'banner',    price = 0,    rarity = 5, owned = true },
    { id = 'vd_royale',   name = 'Victory Royale', sub = 'Verdict', kind = 'verdict', price = 0,    rarity = 1, owned = true },
    { id = 'vd_lastone',  name = 'Last One Standing', sub = 'Verdict', kind = 'verdict', price = 3500, rarity = 4 },
}

local BALANCE = 7450

function BR.Market.push()
    TriggerEvent('br:ui:sendLocal', BR.Nui.MARKET,
        { balance = BALANCE, items = CATALOGUE })
end

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

RegisterNUICallback(BR.NuiCb.MARKET_BUY, function(data, cb)
    -- REFUSED, AUDIBLY, rather than silently pretending. There is no economy
    -- to debit and no store to record ownership in; a purchase that appeared
    -- to work and then vanished on reconnect would be worse than one that
    -- says it is not ready. "Refusals are audible" is a standing rule in this
    -- project for exactly this reason.
    local id = tostring(data and data.id or '?')
    print(('[br_ui] market: purchase of %s refused -- no economy yet'):format(id))
    -- The envelope directly rather than BR.Notify: that helper lives in
    -- br_core's Lua state and this is br_ui's. Same wire, one hop shorter.
    TriggerEvent('br:ui:sendLocal', BR.Nui.TOAST, {
        text = 'The store is not open yet.', tone = 'warn', key = 'market.closed',
    })
    cb({ ok = false, reason = 'no economy' })
end)

AddEventHandler('br:ui:ready', function()
    BR.Market.push()
    BR.Market.pushProgress()
end)

RegisterCommand('brxp', function(_, args)
    -- Drives the award animation with a made-up number, so the post-match
    -- moment can be watched without playing a match. `brxp 900` fills the
    -- bar; a number big enough to cross `needed` runs the level-up.
    local amount = tonumber(args[1]) or 650
    local fromLevel, fromXp, fromNeeded = PROFILE.level, PROFILE.xp, PROFILE.needed

    PROFILE.xp = PROFILE.xp + amount
    while PROFILE.xp >= PROFILE.needed do
        PROFILE.xp = PROFILE.xp - PROFILE.needed
        PROFILE.level = PROFILE.level + 1
        PROFILE.needed = math.floor(PROFILE.needed * 1.15)
    end

    BR.Market.pushProgress()
    TriggerEvent('br:ui:sendLocal', BR.Nui.PROGRESS, PROFILE)
    TriggerEvent('br:ui:sendLocal', BR.Nui.XP, {
        xp = amount, fromLevel = fromLevel, fromXp = fromXp, fromNeeded = fromNeeded,
    })
    print(('[br_ui] xp +%d -> level %d, %d/%d')
        :format(amount, PROFILE.level, PROFILE.xp, PROFILE.needed))
end, false)

AddEventHandler('onClientResourceStart', function(res)
    if res ~= RES then return end
    BR.Market.push()
    BR.Market.pushProgress()
end)
