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
    -- No verdict entry: verdicts are not for sale. Winning is how you get one.
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

-- BR.Market.award IS GONE, AND IT IS WORTH SAYING WHAT IT WAS.
--
-- It took an XP amount, added it to PROFILE, and rolled the level over against
-- a SECOND curve invented right here -- `needed = needed * 1.15` -- which has
-- never been the curve the server uses and never could be. Nothing called it.
-- It was the tenth-something instance of this project's standing failure:
-- finished, reviewed, committed code wired to nothing, which is invisible
-- precisely because it cannot misbehave.
--
-- Deleted rather than fixed, because the correct version of it is `do nothing`.
-- The server evaluates BR.Xp against the lifetime total and sends both ends of
-- the bar on MATCH_EARNED; this file forwards them. A client that computes its
-- own progression is a client that will eventually disagree with the database,
-- and the player believes the screen in front of them.

-- EVERY MATCH PAYS, AND IT PAYS ON THE VERDICT SCREEN.
--
-- The award has to land where the match ended -- while the player is still
-- looking at won-or-lost, over the teardown they are already waiting through
-- (user, 2026-08-09). On the lobby card it would arrive after a fade, a
-- teleport and a menu: three screens away from the thing that earned it.
--
-- WHAT THE MATCH ACTUALLY PAID, straight through to the page.
--
-- The verdict screen owns the TIMING (it is the only thing that can see itself
-- on screen -- a delay timed from Lua has missed that window twice), so this
-- only delivers the numbers and lets EndScreen stage them.
RegisterNetEvent(BR.Net.MATCH_EARNED)
AddEventHandler(BR.Net.MATCH_EARNED, function(e)
    if type(e) ~= 'table' then return end

    -- EVERY NUMBER HERE CAME FROM THE SERVER, INCLUDING WHERE THE BAR STOPS.
    -- The fallbacks are for a br_stats old enough not to send the new fields,
    -- and they fall back to what this client was already showing rather than to
    -- zero -- an unknown end position should leave the bar where it is, not
    -- empty it.
    TriggerEvent('br:ui:sendLocal', BR.Nui.EARNED, {
        xp      = tonumber(e.xp) or 0,
        volts   = tonumber(e.volts) or 0,
        level   = tonumber(e.level) or PROFILE.level,
        into    = tonumber(e.into) or PROFILE.xp,
        needed  = math.max(1, tonumber(e.needed) or PROFILE.needed),
        fromLevel  = tonumber(e.fromLevel) or PROFILE.level,
        fromXp     = tonumber(e.fromXp) or PROFILE.xp,
        fromNeeded = math.max(1, tonumber(e.fromNeeded) or PROFILE.needed),
        levelUp = e.levelUp == true,
    })

    -- AND THE PROFILE MOVES WITH IT. PROFILE is what `br:ui:ready` and a
    -- br_ui restart re-push, so leaving it on the pre-match figure meant a
    -- mid-teardown reload would put the bar back to before the match.
    -- MARKET_STATE carries the same fact a moment later; this makes the two
    -- agree in the window between them rather than racing.
    PROFILE.level  = tonumber(e.level) or PROFILE.level
    PROFILE.xp     = tonumber(e.into) or PROFILE.xp
    PROFILE.needed = math.max(1, tonumber(e.needed) or PROFILE.needed)
end)

-- THE SUMMARY HANDLER THAT PRINTED A THIRD XP FORMULA IS GONE.
--
-- It heard BR.Net.SUMMARY and printed "match XP would be +N" from numbers it
-- made up -- 120 for turning up, 500 for a win, 380 by placement, 60 a kill --
-- none of which have ever been the real values. It awarded nothing; it only
-- narrated. That was defensible while there was no ledger, and actively
-- harmful once there was one: anybody debugging a payout complaint had a
-- confident, wrong number in the F8 console sitting next to the right one.
--
-- The real figures are computed once, in br_stats/server/persist.lua, from the
-- same values written to DynamoDB, and arrive here on MATCH_EARNED.

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
    -- Drives the LOBBY bar's award animation with a made-up number, so the
    -- movement can be watched without playing a match. `brxp 900` fills the
    -- bar; a number big enough to cross `needed` runs the level-up flip.
    --
    -- IT NARRATES, because it reported doing nothing once and the interface
    -- half was provably fine (user, 2026-08-09). The two lines below split
    -- the failure cleanly: no output at all means this file never loaded and
    -- there is no level chip either; output with no movement means the
    -- envelope is arriving somewhere the interface is not listening.
    --
    -- IT NO LONGER TOUCHES PROFILE, and that is a bug fix rather than tidying.
    -- It used to roll PROFILE over against `needed * 1.15` -- a curve that has
    -- never existed on the server -- so running this command left the client's
    -- cached progression permanently wrong until the next MARKET_STATE, and
    -- the wrong values were then re-pushed by every `br:ui:ready`. A diagnostic
    -- that corrupts the thing it is diagnosing is worse than no diagnostic.
    --
    -- So the preview is computed into locals and sent; PROFILE is untouched,
    -- and re-pushed at the end to put the bar back where the server says it is.
    -- The level-up preview reuses the same span for the next level because this
    -- side genuinely does not know the curve and must not guess one -- it is a
    -- preview of the ANIMATION, not of the arithmetic. `brxpsim` on the server
    -- console is the one that uses real numbers.
    local amount = math.max(0, math.floor(tonumber(args[1]) or 650))
    local fromLevel, fromXp, fromNeeded = PROFILE.level, PROFILE.xp, PROFILE.needed

    local toLevel, toXp = fromLevel, fromXp + amount
    if toXp >= fromNeeded then
        toLevel = fromLevel + 1
        toXp = toXp - fromNeeded
    end

    -- The new profile FIRST, then the award: the bar animates from where the
    -- award says it was, to where the profile says it is now. Reversed, it
    -- would animate to a value it already held.
    TriggerEvent('br:ui:sendLocal', BR.Nui.PROGRESS,
        { level = toLevel, xp = toXp, needed = fromNeeded })
    TriggerEvent('br:ui:sendLocal', BR.Nui.XP, {
        xp = amount, fromLevel = fromLevel, fromXp = fromXp, fromNeeded = fromNeeded,
    })

    print(('[br_ui] brxp: PREVIEW ONLY -- sent "%s" %d/%d lvl %d, and "%s" +%d from lvl %d %d/%d')
        :format(tostring(BR.Nui.PROGRESS), toXp, fromNeeded, toLevel,
                tostring(BR.Nui.XP), amount, fromLevel, fromXp, fromNeeded))
    print(('[br_ui] brxp: your real profile is untouched (lvl %d, %d/%d) and the'
        .. ' bar returns to it on the next server push.')
        :format(PROFILE.level, PROFILE.xp, PROFILE.needed))
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
