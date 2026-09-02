-- Does the client's ped agree with the server's health ledger?
--
-- WHAT THIS IS FOR, AND WHY IT IS ONLY A DETECTOR.
--
-- server/roster.lua samples every player's ped health four times a second and
-- writes the result into `entry.hp` -- the same field BR.Damage.applyHit does
-- its arithmetic on. Under FiveM's ownership model the ped's health is a value
-- the OWNING CLIENT controls, so that write hands the authority on "how much
-- health does this player have" back to the player. A client that pins its own
-- ped at full health has its ledger restored 250ms after every hit, and the
-- independent backstop that should notice (the server-observed death check in
-- server/combat.lua) reads the SAME client-owned number, so it never fires
-- either.
--
-- Closing that is a gameplay change and it is not this file. This file answers
-- the cheaper question first: IS ANYBODY DOING IT. The server already holds
-- both numbers -- its own ledger and the client's claim -- so the disagreement
-- between them is observable without inventing any new data, without changing
-- what happens to any player, and without a redeploy being able to break a
-- gunfight. See docs/security.md: the damage validator shipped in log-only mode
-- for a full playtest before it was allowed to enforce, on the rule that every
-- refusal printed during honest play is a false positive. Same rule, same
-- order.
--
-- THE SIGNAL IS THE *UNEXPLAINED UPWARD* MOVE, AND EVERY WORD OF THAT IS DOING
-- WORK.
--
--   * UPWARD only. A sample BELOW the ledger is the world hurting somebody --
--     a fall, a fire, drowning, a car -- and those are damage paths the engine
--     still owns and the server does not model at all. Counting them would
--     mean counting ordinary play. They are also not the exploit: a player who
--     lowers their own health has cheated themselves.
--
--   * UNEXPLAINED. There are exactly four honest ways a ped can read HIGHER
--     than the ledger, and each one is excused by name below rather than being
--     absorbed into a fudge factor -- because a tolerance wide enough to hide
--     a revive is wide enough to hide a cheat, and the reason a sample was
--     excused is the first thing anyone debugging a false positive wants.
--
-- A DETECTOR THAT FIRES ON HONEST PLAY IS WORSE THAN NO DETECTOR, because it
-- gets switched off, and the day it gets switched off is the day it was needed.
-- So the arithmetic here is deliberately conservative in one direction only:
-- every ambiguous sample is excused. Missing the first two seconds of a cheat
-- costs nothing -- the counter is cumulative and the exploit is not a single
-- sample, it is the same lie four times a second for a whole match.

BR = BR or {}

--- Why a sample that read high was NOT counted.
---
--- A STRING RATHER THAN A BOOLEAN, and it is worth the extra field. The first
--- question asked of any anticheat number is "what if it is wrong", and the
--- only useful answer is a breakdown of what it threw away and why. `/brhealth`
--- prints these counts beside the totals for exactly that reason.
BR.HealthExcuse = {
    COUNTED  = 'counted',    -- nothing explains it; this is the signal
    NONE     = 'none',       -- the ped is at or below the ledger: ordinary
    TOLERANCE= 'tolerance',  -- within rounding of the ledger
    HURT     = 'hurt',       -- the server hurt them and the client has not applied it yet
    HEALING  = 'healing',    -- a med kit or shield the server itself issued
    SETTLING = 'settling',   -- a revive/respawn the server wrote; the ped is catching up
    NOT_LIVE = 'not-live',   -- not an ALIVE player in a live match
    RESCUE   = 'rescue',     -- #191: riding an ambulance, health restored on arrival
}

--- How much health this player recovered that the server never issued them.
---
--- PURE, AND cfg IS A PARAMETER RATHER THAN A GLOBAL READ. Same shape as
--- BR.ValidateShot: it makes every threshold in here reachable from
--- tools/test_shared.lua with values no shipped config would hold, which is the
--- only way the excuses get shown to still excuse.
---
--- THE FOUR EXCUSES, IN THE ORDER THEY ARE CHECKED AND WHY EACH EXISTS:
---
--- 1. NOT_LIVE -- only an ALIVE player in a match can be shot, so only an ALIVE
---    player's ledger is worth defending. A DEAD player's ped gets resurrected
---    for the spectator camera and a LOBBY player's ped is whatever the lobby
---    left them on; both would read high forever and neither means anything.
---    DBNO never reaches here at all (the sampler already skips it, because a
---    downed player's health is a bleed countdown rather than a ped reading).
---
--- 2. RESCUE -- #191 puts a downed player inside an ambulance and BR.Combat.revive
---    hands their health back on arrival. The server writes the ledger and the
---    client's ped follows one round trip later, which is the SETTLING shape
---    below; this is named separately anyway because the rescue state is written
---    by the server and nothing else, so it is a free and certain excuse, and
---    because a detector that cried wolf on the feature landing the same week
---    would have been switched off in its first playtest.
---
--- 3. HURT -- the server applied damage to the ledger and told the client to
---    hurt its own ped. Between those two events the ped is legitimately higher
---    than the ledger, by exactly the damage in flight, for one round trip. This
---    is the single largest source of honest divergence and the grace window is
---    the main false-positive control: it must comfortably exceed one sample
---    interval plus a bad ping, because a player on a poor connection is not a
---    cheat.
---
--- 4. HEALING -- a med kit or shield potion. The server decides these land and
---    sends INV_EFFECT with a TARGET (server/inventory.lua); the client raises
---    its own ped and the sampler reads the rise on the way up. So during a use,
---    and for a settle window after it, the ped is SUPPOSED to be climbing past
---    the ledger. This is the excuse that matters most for the eventual fix: it
---    is the one legitimate upward path that the ledger does not already own.
---
--- 5. SETTLING -- a revive, a respawn or a match reset. Here the LEDGER leads and
---    the ped follows, so the usual direction is reversed and the sample reads
---    LOW rather than high -- but a client that applies HEALTH_SYNC slightly
---    early, or a resurrection that restores GTA's default health before our
---    number lands, produces a brief spike the other way.
---
--- @param ledger number|nil    the server's display hp (0..100) BEFORE this sample
--- @param sampled number       display hp read off the ped this sample
--- @param ctx table            { now, state, rescue, lastHitAt, healUntil, settleUntil }
--- @param cfg table|nil        BR.Config.Combat.healthAudit
--- @return number gain         display points recovered with no explanation (0 if none)
--- @return string excuse       BR.HealthExcuse.*
function BR.HealthUnexplainedGain(ledger, sampled, ctx, cfg)
    cfg = cfg or {}
    ctx = ctx or {}

    ledger  = tonumber(ledger)
    sampled = tonumber(sampled)
    -- No ledger yet means no opinion to contradict. NaN likewise -- and it is
    -- checked rather than assumed, because `nan > x` is false for every x, so a
    -- NaN would silently read as "no gain" and disable the detector for that
    -- player rather than erroring where somebody would see it.
    if ledger == nil or sampled == nil then return 0.0, BR.HealthExcuse.NONE end
    if ledger ~= ledger or sampled ~= sampled then return 0.0, BR.HealthExcuse.NONE end

    -- ONLY A LIVE PLAYER IN A MATCH. `state` is compared against the enum rather
    -- than tested for truthiness: every roster state is a non-empty string and
    -- so every one of them is truthy, which would make `if ctx.state then` mean
    -- "always".
    if ctx.state ~= BR.PlayerState.ALIVE then
        return 0.0, BR.HealthExcuse.NOT_LIVE
    end

    -- 0 IS TRUTHY IN LUA. `rescue` is a server-written marker whose absence is
    -- nil, so this is safe as a truthiness test today -- but it is written as an
    -- explicit nil comparison anyway, because the day somebody stores a rescue
    -- id of 0 in it is the day this exemption silently inverts.
    if ctx.rescue ~= nil then
        return 0.0, BR.HealthExcuse.RESCUE
    end

    local gain = sampled - ledger

    -- Not higher than the ledger: the ordinary case, every sample of every
    -- honest player. Checked before the windows below so the common path costs
    -- one comparison.
    if gain <= 0.0 then return 0.0, BR.HealthExcuse.NONE end

    -- Rounding. Both numbers are floored to integers from different float
    -- pipelines (ours through BR.ToDisplayHp, theirs through the engine), so a
    -- point of disagreement is arithmetic rather than evidence.
    local tol = tonumber(cfg.toleranceHp) or 2.0
    if gain <= tol then return 0.0, BR.HealthExcuse.TOLERANCE end

    local now = tonumber(ctx.now) or 0.0

    -- The three windows. Each is "did this happen recently enough that the ped
    -- and the ledger are ALLOWED to disagree", and each compares against a
    -- stamp the SERVER wrote -- never against anything a client sent.
    local function within(stamp, ms)
        stamp = tonumber(stamp)
        if stamp == nil then return false end
        local w = tonumber(ms) or 0.0
        if w <= 0.0 then return false end
        return (now - stamp) < w
    end

    if within(ctx.lastHitAt, cfg.hurtGraceMs or 1500) then
        return 0.0, BR.HealthExcuse.HURT
    end

    -- `healUntil` and `settleUntil` are DEADLINES rather than events, because
    -- both cover a stretch the server already knows the length of: a consumable
    -- has an `endsAt` and a revive has a round trip. Comparing `now` against a
    -- deadline the writer chose keeps the duration next to the thing that knows
    -- it, rather than forcing every writer to agree on one window here.
    local healUntil = tonumber(ctx.healUntil)
    if healUntil ~= nil and now < healUntil then
        return 0.0, BR.HealthExcuse.HEALING
    end

    local settleUntil = tonumber(ctx.settleUntil)
    if settleUntil ~= nil and now < settleUntil then
        return 0.0, BR.HealthExcuse.SETTLING
    end

    return gain, BR.HealthExcuse.COUNTED
end

--- Fold one sample's verdict into a player's running tally.
---
--- SEPARATE FROM THE ARITHMETIC ABOVE so the accumulation is testable without a
--- roster, and so the caller in server/roster.lua stays three lines -- the
--- sampler is a hot loop over every player four times a second and it should
--- read as "sample, judge, record".
---
--- CUMULATIVE PER MATCH, NOT A RATE, and that is the whole reason this is a good
--- signal. Honest play produces a tally that sits at zero: the excuses above
--- absorb every legitimate upward move, and what is left over is bounded jitter
--- that the tolerance eats. The exploit produces a tally that climbs without
--- limit, because the lie has to be repeated four times a second to keep
--- working. Nothing honest looks like that, so the threshold does not have to be
--- clever -- it only has to be higher than zero by a comfortable margin. It is
--- reset with the rest of the per-match record in BR.Match.resetPlayer, beside
--- the storm ledger, for the reason #161 spells out.
---
--- @param tally table|nil   the previous tally, or nil to start one
--- @param gain number       from BR.HealthUnexplainedGain
--- @param excuse string     from BR.HealthUnexplainedGain
--- @return table tally      { hp, samples, peak, excused = { [excuse] = n } }
function BR.HealthTally(tally, gain, excuse)
    tally = tally or { hp = 0.0, samples = 0, peak = 0.0, excused = {} }
    tally.excused = tally.excused or {}

    if excuse ~= BR.HealthExcuse.COUNTED then
        -- NONE is every ordinary sample of every honest player -- 48 players at
        -- 4Hz is two hundred a second -- so it is deliberately NOT tallied. The
        -- others are rare and their counts are the false-positive audit.
        if excuse ~= BR.HealthExcuse.NONE then
            tally.excused[excuse] = (tally.excused[excuse] or 0) + 1
        end
        return tally
    end

    gain = tonumber(gain) or 0.0
    if gain ~= gain or gain <= 0.0 then return tally end

    tally.hp      = (tally.hp or 0.0) + gain
    tally.samples = (tally.samples or 0) + 1
    if gain > (tally.peak or 0.0) then tally.peak = gain end
    return tally
end

--- Has this player's tally earned an operator line yet?
---
--- ONCE PER MATCH PER PLAYER, AND THE `reportedAt` STAMP IS WHY. A cheat that
--- works produces a crossing on every sample after the first, and a console
--- that prints four lines a second about one player is a console nobody reads --
--- which is the same failure as no detector at all, arrived at from the other
--- side.
---
--- IT RETURNS A DECISION AND WRITES NOTHING. The caller stamps the tally, so a
--- test can ask this question repeatedly without the answer changing under it.
--- @param tally table|nil
--- @param cfg table|nil
--- @return boolean
function BR.HealthShouldReport(tally, cfg)
    if tally == nil then return false end
    if tally.reportedAt ~= nil then return false end
    cfg = cfg or {}
    local bar = tonumber(cfg.reportHp) or 100.0
    return (tonumber(tally.hp) or 0.0) >= bar
end
