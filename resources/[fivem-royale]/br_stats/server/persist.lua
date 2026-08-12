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

    local r = {
        kills      = p.kills or 0,
        downs      = p.downs or 0,
        revives    = p.revives or 0,
        damage     = p.damage or 0.0,
        placement  = placement,
        total      = ctx.total or 0,
        squadId    = p.squadId,
        survivedMs = math.max(0, (ctx.endedAt or 0) - (ctx.startedAt or 0)),
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
        playtimeSec  = math.floor(r.survivedMs / 1000),
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

    local written, skipped = 0, 0

    for _, p in ipairs(res.players or {}) do
        local license = licenseOf(p.src)
        if not license then
            skipped = skipped + 1
        else
            local deltas, xpEarned = deltasFor(p, res)

            -- The level is derived HERE, from the total the store will hold
            -- after this write, using the same curve the summary screen uses.
            -- br_ddb stores what we compute rather than computing its own, so
            -- there is one implementation of the curve rather than two that
            -- can disagree.
            local before = BR.Stats.cachedXp and BR.Stats.cachedXp[license] or 0
            local after = before + xpEarned
            deltas.level = BR.Xp and BR.Xp.levelFor(after) or 1
            deltas.name = p.name
            deltas.at = os.time() * 1000

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
        end
    end

    print(('[br_stats] match %s: %d recorded, %d skipped (no license)')
        :format(tostring(res.matchId), written, skipped))
end)
