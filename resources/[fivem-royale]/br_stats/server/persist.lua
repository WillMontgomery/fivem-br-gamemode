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

    TWO WRITES PER MATCH, AND THEY ARE NOT EQUALS (#153, added 2026-08-16):

      the AGGREGATE   one atomic ADD per player onto {pk=license, sk='profile'}.
                      The source of truth for every number a player sees.
      the HISTORY     one item per player at {pk=license, sk='match#...'},
                      all of them in one batch. A RECORD, and best-effort.

    They cannot be one operation -- DynamoDB cannot update one item and create
    another in the same call -- so they can diverge. The direction of that
    dependency is fixed and deliberate: the aggregate never waits on the
    history, never checks whether it landed, and never retries because of it. A
    missing history row is a gap in a moderation aid; a missing aggregate is a
    player losing progression, and the two are not worth trading against each
    other.

    BOTH HAPPEN AT ENDED, WHICH IS WHEN br:match:results FIRES. Not at CLEANUP:
    BR.Match.resetPlayers has by then zeroed the per-match counters and cleared
    placement, so anything written at CLEANUP records a match in which nobody
    did anything -- which is exactly the shape of #132.

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

AddEventHandler('br:ddb:historyResult', function(req, ok, info)
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

--- Did this player WIN, as opposed to place first?
---
--- A WIN IS PLACEMENT 1 THAT THEY WERE ALIVE FOR. The last squad standing can
--- still be taken by the storm: eliminate() records placement 1, because nobody
--- outlasted them, and this used to be read as a win -- banking wins +1, deaths
--- 0, the win payout and the win XP bonus for a death. The client has always
--- applied the extra condition (client/state.lua: `placement == 1 and not
--- diedThisMatch`) and showed them a death, so the two halves of the same
--- question disagreed (#133). `died` is carried on the row rather than inferred.
---
--- ONE FUNCTION BECAUSE THERE ARE NOW THREE CONSUMERS -- the aggregate's `wins`
--- counter, the Volts payout, and the match-history row's `won` flag. Three
--- copies of a rule that has already been wrong once is three chances to get it
--- wrong again.
--- @param p table  one row from br:match:results
--- @return boolean
local function wonMatch(p)
    return (p.placement or 0) == 1 and not p.died
end

--- Turn one player's match into the deltas the store adds up.
---
--- PLACEMENT DRIVES THE COUNTERS, and the two special cases are the ones worth
--- naming: placement 1 is a win, and ANY placement means they finished the
--- match rather than won it -- so `deaths` counts every non-winning finish,
--- which is what "deaths" has always meant for a battle royale profile.
local function deltasFor(p, ctx)
    local placement = p.placement or 0
    local won = wonMatch(p)
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
        -- Carried into the XP and payout functions so they can apply the same
        -- rule as `won` above, rather than each re-deriving it from placement.
        died       = p.died == true,
        -- Volts picked up off the ground this match (#88's airdrop pile).
        -- BR.Config.marketPayout adds it to the sum; BR.Xp.forMatch ignores it,
        -- deliberately -- currency found on the floor is not experience earned
        -- by playing, and paying XP for it would make a sprint to the crate the
        -- fastest way to level.
        voltsPickedUp = p.voltsPickedUp or 0,
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

--- The permanent record of one player's match (#153).
---
--- A SECOND ITEM, NOT A SECOND FIELD, and it cannot be otherwise. The deltas
--- above are applied with an atomic ADD to `{pk = license, sk = 'profile'}`;
--- this is a NEW item under the same partition key, and DynamoDB has no
--- operation that updates one item and creates another. So they are two writes
--- and they can diverge -- the aggregate stays the source of truth for the
--- profile numbers, and this is best-effort. See the br:ddb:historyPut handler
--- in js-src/br_ddb/src/index.js.
---
--- THE SORT KEY IS THE ENTIRE READ MODEL. `match#<endedAt>#<matchId>` under
--- `pk = license` turns "this player's recent matches, newest first" into a
--- Query with `ScanIndexForward = false` and a `Limit` -- no secondary index,
--- no scan, one partition per player.
---
--- endedAt IS A WALL CLOCK, DELIBERATELY NOT `ctx.endedAt`. br_core stamps the
--- results envelope with GetGameTimer(), which counts milliseconds since THIS
--- SERVER PROCESS started -- it returns to zero on every restart. As a sort key
--- that would file every match played after a deploy underneath every match
--- played before one, and "newest first" would hand back the oldest. The same
--- wall clock stamps `lastMatchAt` on the aggregate below, so the newest history
--- row and the profile's last-match time agree by construction rather than by
--- luck.
---
--- ZERO-PADDED BECAUSE THE SORT IS LEXICOGRAPHIC, not numeric. Epoch
--- milliseconds are thirteen digits until the year 2286 and would order
--- correctly unpadded -- but a box whose clock has not been set yet produces a
--- short number that would sort ABOVE every real match, permanently. The padding
--- costs nothing and deletes the case.
---
--- @param p table     one row from br:match:results
--- @param ctx table   the results envelope
--- @param license string
--- @param endedAt integer  wall-clock ms, one value for the whole match
--- @param deltas table     the deltas already built for this player
--- @param xpEarned integer
--- @return table
local function historyRowFor(p, ctx, license, endedAt, deltas, xpEarned)
    return {
        -- br_ddb keys on these two and stores neither twice.
        license     = license,
        sk          = ('match#%013d#%s'):format(endedAt, tostring(ctx.matchId or 0)),

        matchId     = ctx.matchId or 0,
        endedAt     = endedAt,
        mode        = tostring(ctx.mode or ''),
        placement   = p.placement or 0,
        -- How many were in it. Third of eight and third of ninety-six are not
        -- the same achievement, and the placement alone cannot tell them apart.
        total       = ctx.total or 0,
        kills       = p.kills or 0,
        downs       = p.downs or 0,
        revives     = p.revives or 0,
        -- Floored to match `damageDealt` on the aggregate. A history row that
        -- says 412.7 while the career total moved by 412 is a discrepancy
        -- somebody would eventually report as a bug.
        damage      = math.floor(p.damage or 0.0),
        survivedMs  = p.survivedMs or 0,
        xpEarned    = xpEarned,
        -- INCLUDES THE LEVEL-UP BONUS, because `deltas.balance` does by the time
        -- this is called -- and because that is the figure the player was shown
        -- on the verdict screen. A record that disagrees with what somebody
        -- watched happen is worse than no record.
        voltsEarned = deltas.balance,
        -- NOT `placement == 1`. See wonMatch, and #133.
        won         = wonMatch(p),
    }
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

    -- ONE TIMESTAMP FOR THE WHOLE MATCH, read once rather than per player.
    --
    -- It was already effectively that -- os.time() inside the loop returns the
    -- same second for all 48 -- except across a second boundary, where half the
    -- field would be stamped a second later than the other half. Harmless for
    -- `lastMatchAt`; not harmless for a SORT KEY, where it would split one match
    -- across two timestamps and file some of it above matches that came later.
    local endedAt = os.time() * 1000

    -- The per-match rows, accumulated and sent as ONE batch after the loop.
    --
    -- NO CACHE IS NEEDED AND NONE EXISTS. The whole match arrives in `res` in a
    -- single handler call, so "batch the writes" is just "build a table and send
    -- it at the end" -- nothing is held between events and nothing survives a
    -- restart to be lost.
    local history = {}

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
            deltas.at = endedAt

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
            -- BOTH ENDS OF THE BAR, EVALUATED HERE, and this is the fix for the
            -- verdict screen showing 0 XP (#91) and the lobby disagreeing with
            -- the stored row (#130). The payload used to carry the earned
            -- amount and the new level and nothing else, so the page had to
            -- work out where the bar should END by adding the award to whatever
            -- it happened to be showing. That is a derivation, on the client,
            -- of a number the server already knows -- and every way it can go
            -- wrong, it did:
            --
            --   * it added the award to a progress value that ALREADY included
            --     it, because br:market:credited pushes the credited total on
            --     MARKET_STATE the same tick this event is sent;
            --   * on a level-up it subtracted the OLD level's span from that
            --     doubled figure and clamped at zero, which is literally how
            --     Epyc gained 1048 XP and was shown 0 (327 + 1048 - 2050 < 0);
            --   * it kept the previous level's span as the denominator, so a
            --     bar could sit past its own end and never reset.
            --
            -- So the server sends where the bar WAS and where it IS, both from
            -- BR.Xp against the lifetime totals either side of this match. The
            -- page renders two numbers it was given and derives nothing. There
            -- is no third place for the curve to be evaluated any more.
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
                -- At maxLevel progress() reports a full bar with a zero span,
                -- which is correct as a fact and useless as a denominator. One
                -- is the smallest value that keeps the bar full rather than
                -- dividing by nothing.
                --
                -- Guarded like every other BR.Xp call in this file: br_stats is
                -- allowed to run on a server with no br_lib, and a verdict
                -- screen with a flat bar beats a match-end handler that throws.
                local intoBefore, spanBefore, intoAfter, spanAfter = 0, 1, 0, 1
                if BR.Xp then
                    local _
                    _, intoBefore, spanBefore = BR.Xp.progress(before)
                    _, intoAfter, spanAfter = BR.Xp.progress(after)
                end

                TriggerClientEvent(BR.Net.MATCH_EARNED, p.src, {
                    xp      = xpEarned,
                    volts   = deltas.balance,
                    -- Where the bar is NOW.
                    level   = deltas.level,
                    into    = intoAfter,
                    needed  = math.max(1, spanAfter),
                    -- Where it has to start from, so the fill is the match
                    -- rather than a jump.
                    fromLevel  = levelBefore,
                    fromXp     = intoBefore,
                    fromNeeded = math.max(1, spanBefore),
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

            -- BUILT AFTER THE LEVEL BONUS, ON PURPOSE. `deltas.balance` grows by
            -- the level-up payout a few lines above, and that same figure is
            -- what the verdict screen just told the player they earned. Building
            -- the row before it would file a record that contradicts what they
            -- watched.
            history[#history + 1] =
                historyRowFor(p, res, license, endedAt, deltas, xpEarned)

            written = written + 1
            if p.left then left = left + 1 end
        end
    end

    -- ONE CALL PER 25 PLAYERS, NOT ONE PER PLAYER. br_ddb splits this into
    -- BatchWriteItem calls; a 48-player match costs two, against the 48 separate
    -- UpdateItems the aggregates above still need (those cannot be batched --
    -- BatchWriteItem has no update form, and an atomic ADD is the entire reason
    -- the aggregate is safe under concurrent match ends).
    --
    -- FIRE AND FORGET, LIKE EVERYTHING ELSE HERE. The failure is a log line. The
    -- aggregate has already been sent and does not depend on this landing, and
    -- nothing retries the match: `m.publishedAt` in br_core guarantees
    -- publishResults runs at most once per match, which is the guard that
    -- matters, and a second one here would only be another thing to get wrong.
    --
    -- WRITTEN AT ENDED, NEVER AT CLEANUP. By CLEANUP, BR.Match.resetPlayers has
    -- zeroed kills, downs, revives and damage, cleared placement and nil'd
    -- diedAt -- so a history row built then would record a match in which
    -- nobody did anything. That is #132's fingerprint exactly, and the reason
    -- this hangs off br:match:results rather than off a later hook.
    if #history > 0 then
        nextReq = nextReq + 1
        local hreq = nextReq
        pending[hreq] = function(ok, info)
            if not ok then
                -- NOT AN ERROR FOR THE MATCH, and the wording says so. The
                -- career totals landed; what is missing is the per-match record
                -- for those rows, which shows up on Ringmaster as a gap.
                print(('^3[br_stats] match history incomplete: %s of %d rows written (%s)^7')
                    :format(tostring(info.written), #history, tostring(info.error)))
            end
        end
        SetTimeout(8000, function() pending[hreq] = nil end)

        TriggerEvent('br:ddb:historyPut', hreq, history)
    end

    -- The departed count is called out rather than folded in: it is the number
    -- that used to be silently zero, so it is the one worth being able to read
    -- off the console when checking this works.
    print(('[br_stats] match %s: %d recorded (%d had left), %d skipped (no license), %d history rows in %d batch(es)')
        :format(tostring(res.matchId), written, left, skipped,
                #history, math.ceil(#history / 25)))
end)
