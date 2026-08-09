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
