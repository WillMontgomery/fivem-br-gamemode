--[[
    Match results -> DynamoDB, through br_ddb.

    REPLACES THE ORACLE THAT NEVER RAN. br_stats has had an `applyMatch` since
    it was written and nothing ever called it, because br_core emitted no
    match-end event -- so no stat has ever been recorded on this server. That
    is now fixed at both ends: br_core publishes `br:match:results`, and this
    listens.

    THE GOVERNING RULE IS UNCHANGED: A STATS FAILURE MUST NEVER STOP A MATCH.
    Everything here is fire-and-forget, every failure is a log line, and nothing
    blocks the match ending or the summary screen. The old oxmysql layer earned
    that rule with a circuit breaker; DynamoDB through br_ddb gets it for free,
    because br_ddb already answers rather than throws.

    WHY THE GAME WRITES THIS DIRECTLY rather than sending it to Ringmaster:
    the console is a companion to the server, never something the server can be
    made to need. Ringmaster being down should cost you the admin panel and
    nothing else -- certainly not a player's progression.
]]

BR = BR or {}
BR.Stats = BR.Stats or {}

--- license -> lifetime XP, as last published by br_core.
---
--- THE TABLE THAT WAS READ AND NEVER WRITTEN. `deltasFor` has consulted this
--- since the stats writer landed, and nothing populated it -- so every level
--- this file computed was derived from a single match's XP rather than the
--- player's total. It stored the wrong level, told the verdict screen the wrong
--- level, and paid the level-up bonus against the wrong boundary.
---
--- br_core owns the real number: it reads the profile row on connect and
--- applies every credit as it lands. It publishes on load and after each
--- credit, so this is right on the first match of a session and stays right.
BR.Stats.cachedXp = BR.Stats.cachedXp or {}

AddEventHandler('br:stats:knownXp', function(license, xp)
    if type(license) ~= 'string' or license == '' then return end
    BR.Stats.cachedXp[license] = tonumber(xp) or 0
end)

local nextReq = 0
local pending = {}

AddEventHandler('br:ddb:statsResult', function(req, ok, info)
    local cb = pending[req]
    if not cb then return end
    pending[req] = nil
    cb(ok, info or {})
end)

--- Resolve a player's license at the moment the match ends.
---
--- READ HERE RATHER THAN TRUSTED FROM THE ROSTER. The roster's `license` field
--- is documented as "filled by br_stats if it is running", which means it is
--- often nil -- and a stats row written under a guessed key is worse than one
--- not written at all.
--- @param src number|string
--- @return string|nil
local function licenseOf(src)
    if not BR.Identity then return nil end
    local byKind = BR.Identity.ofPlayer(src)
    return BR.Identity.qualified('license', byKind and byKind.license)
end

--- The key to write this row under.
---
--- A ROW THAT CARRIES ITS OWN LICENSE HAS ALREADY ANSWERED THIS. That is the
--- sealed-on-disconnect case: `licenseOf` resolves through the live player
--- list, so for somebody who left ten minutes ago it returns nothing and the
--- row would be dropped as unkeyable -- which is the bug it is here to fix
--- (#100). br_core captures the license at disconnect for exactly this.
--- @param p table  one row from br:match:results
--- @return string|nil
local function keyFor(p)
    return p.license or licenseOf(p.src)
end

--- Turn one player's match into the deltas the store adds up.
---
--- PLACEMENT DRIVES THE COUNTERS, and the two special cases are the ones worth
--- naming: placement 1 is a win, and ANY placement means they finished the
--- match rather than won it -- so `deaths` counts every non-winning finish,
--- which is what "deaths" has always meant for a battle royale profile.
local function deltasFor(p, ctx)
    local placement = p.placement or 0
    local won = placement == 1
    local squad = (p.squadId ~= nil)

    -- SURVIVAL IS PER PLAYER, AND IT USED NOT TO BE. This read
    -- `(ctx.endedAt - ctx.startedAt)` -- the MATCH's duration, off the envelope
    -- rather than the row -- so all 48 players were credited the same survival
    -- time and the one eliminated ninety seconds in was paid what the winner
    -- was (#99). br_core now stamps the moment each player stopped surviving
    -- and sends the difference.
    local r = {
        kills      = p.kills or 0,
        downs      = p.downs or 0,
        revives    = p.revives or 0,
        damage     = p.damage or 0.0,
        placement  = placement,
        total      = ctx.total or 0,
        squadId    = p.squadId,
        survivedMs = p.survivedMs or 0,
    }

    local xpEarned = BR.Xp and BR.Xp.forMatch(r) or 0

    return {
        xp           = xpEarned,
        -- CURRENCY RIDES ALONG WITH THE STATS, in the same atomic ADD. It has
        -- to: a separate write could credit XP and not the balance, and a
        -- player who levelled up without being paid has no way to tell that
        -- from being paid nothing.
        balance      = BR.Config.marketPayout and BR.Config.marketPayout(r) or 0,
        matches      = 1,
        wins         = won and 1 or 0,
        top10s       = (placement > 0 and placement <= 10) and 1 or 0,
        kills        = r.kills,
        deaths       = won and 0 or 1,
        downs        = r.downs,
        revives      = r.revives,
        damageDealt  = math.floor(r.damage),
        -- PRESENCE, NOT SURVIVAL. Playtime is how long they were in the match,
        -- which for anyone who stayed to spectate is longer than they lived --
        -- and for anyone who quit is shorter than the match ran. The two look
        -- interchangeable and are not, which is how survival XP came to be
        -- measured with the wrong one.
        playtimeSec  = math.floor((p.presentMs or r.survivedMs) / 1000),
        soloMatches  = squad and 0 or 1,
        squadMatches = squad and 1 or 0,
    }, xpEarned
end

AddEventHandler('br:match:results', function(res)
    if GetResourceState('br_ddb') ~= 'started' then
        -- Said once per match rather than silently skipped: a server whose
        -- stats are not being recorded looks identical to one where nobody has
        -- played, which is exactly how this went unnoticed for so long.
        print('^3[br_stats] br_ddb is not started -- match results not recorded^7')
        return
    end

    local written, skipped, left = 0, 0, 0

    for _, p in ipairs(res.players or {}) do
        local license = keyFor(p)
        if not license then
            skipped = skipped + 1
        else
            local deltas, xpEarned = deltasFor(p, res)

            -- The level is derived HERE, from the total the store will hold
            -- after this write, using the same curve the summary screen uses.
            -- br_ddb stores what we compute rather than computing its own, so
            -- there is one implementation of the curve rather than two that
            -- can disagree.
            -- POPULATED AT LAST. This read `BR.Stats.cachedXp` since the day it
            -- was written and nothing ever wrote to that table, so `before` was
            -- always 0 -- and every level below was derived from ONE match's XP
            -- instead of a career of it. br_core publishes the real total now
            -- (see `br:stats:knownXp` below); the fallback stays because a
            -- server running br_stats without br_core has nobody to tell it,
            -- and a wrong level is better than a crash.
            local before = BR.Stats.cachedXp[license] or 0
            local after = before + xpEarned
            local levelBefore = BR.Xp and BR.Xp.levelFor(before) or 1
            deltas.level = BR.Xp and BR.Xp.levelFor(after) or 1
            deltas.name = p.name
            deltas.at = os.time() * 1000

            -- LEVELLING UP PAYS, and it pays per level crossed rather than per
            -- level-up event: a single enormous match that crosses two levels
            -- should pay for both, and paying once would quietly punish the
            -- best match somebody ever had.
            --
            -- It rides in the same ADD as the match payout because it is the
            -- same write. A separate one could credit the match and not the
            -- level, and a player who saw "LEVEL 12" and no matching balance
            -- change has no way to tell that from the bonus not existing.
            if deltas.level > levelBefore and BR.Config.levelBonus then
                for lvl = levelBefore + 1, deltas.level do
                    deltas.balance = deltas.balance + BR.Config.levelBonus(lvl)
                end
            end

            -- TELL THE PLAYER WHAT THEY EARNED, from the same numbers being
            -- written. The verdict screen used to invent an XP figure client
            -- side with a formula that was never the real one -- so the bar
            -- animated to a number nothing had persisted, and Volts were not
            -- mentioned at all.
            --
            -- Sent before the write rather than after: the player is looking at
            -- the verdict screen now, and a DynamoDB round trip is exactly the
            -- window in which they stop looking. A failed write is reported in
            -- the server log; the far worse outcome is a correct write nobody
            -- saw the reward for.
            --
            -- NOT SENT TO SOMEBODY WHO LEFT. Their src is gone and, worse, may
            -- already belong to whoever connected into that slot -- who would
            -- get a verdict screen for a match they were not in. The write
            -- still happens; only the telling is skipped.
            if p.src and not p.left then
                TriggerClientEvent(BR.Net.MATCH_EARNED, p.src, {
                    xp      = xpEarned,
                    volts   = deltas.balance,
                    level   = deltas.level,
                    levelUp = deltas.level > levelBefore,
                })
            end

            -- KEEP br_core's INVENTORY CACHE HONEST. It read the row once on
            -- connect and holds it for the session; without this the lobby
            -- would show the balance and level the player had when they joined
            -- until they reconnected -- so a match would appear to pay nothing.
            --
            -- An event rather than a call: br_stats does not depend on br_core
            -- and must keep working on a server with no gamemode loaded.
            TriggerEvent('br:market:credited', license, xpEarned, deltas.balance)

            nextReq = nextReq + 1
            local req = nextReq
            pending[req] = function(ok, info)
                if not ok then
                    print(('^3[br_stats] could not record %s: %s^7')
                        :format(license, tostring(info.error)))
                end
            end
            SetTimeout(8000, function() pending[req] = nil end)

            TriggerEvent('br:ddb:statsApply', req, license, deltas)
            written = written + 1
            if p.left then left = left + 1 end
        end
    end

    -- The departed count is called out rather than folded in: it is the number
    -- that used to be silently zero, so it is the one worth being able to read
    -- off the console when checking this works.
    print(('[br_stats] match %s: %d recorded (%d had left), %d skipped (no license)')
        :format(tostring(res.matchId), written, left, skipped))
end)
