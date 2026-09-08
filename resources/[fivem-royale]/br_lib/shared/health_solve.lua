-- Does the client's ped agree with the server's health ledger -- and which of
-- the two wins when it does not?
--
-- WHAT THIS IS FOR.
--
-- server/roster.lua samples every player's ped health four times a second.
-- Under FiveM's ownership model the ped's health is a value the OWNING CLIENT
-- controls, so what comes back is a CLAIM, not a reading. This file holds the
-- two questions the server asks about that claim, and they are deliberately
-- separate functions:
--
--   BR.HealthUnexplainedGain  -- IS ANYBODY LYING?  (the detector; counts)
--   BR.HealthCommit           -- WHAT DOES THE LEDGER SAY NOW?  (the rule; acts)
--
-- The detector shipped first, alone, on the project's standing order: measure,
-- prove the log is empty during honest play, then act (docs/security.md, and
-- the way the damage validator shipped). The rule is the "then act" half.
--
-- ═══ WHY THE LEDGER USED TO LOSE, AND WHAT THAT COST ═══
--
-- The sampler used to write the sample straight into `entry.hp` -- the same
-- field BR.Damage.applyHit subtracts from. That handed the authority on "how
-- much health does this player have" back to the player: the server subtracted
-- 25, told the client to apply it, the client ignored the instruction, and 250ms
-- later the sampler copied the client's untouched 100 back over the server's 75.
-- A security audit reproduced exactly that (2026-09-08, finding 1: 100 -> 75 ->
-- restored to 100 in 300ms, with zero unexplained recovery counted, because the
-- ledger was overwritten before the next sample had anything left to measure).
--
-- ═══ THE SHAPE: MONOTONIC DOWNWARD, EXCEPT WHERE THE SERVER SAID OTHERWISE ═══
--
-- The obvious fix -- stop reading the ped -- is wrong, and it is worth writing
-- down why, because it is what the next person will reach for. The sampler
-- exists BECAUSE the engine owns damage the server never took over: falls,
-- fire, drowning, cars, the world. Nothing on the server models any of them. A
-- ledger that refused the engine outright would mean a player could step off a
-- skyscraper and the server would never notice.
--
-- So the sampler is ASYMMETRIC, and every clause of that is load-bearing:
--
--   * A DECREASE IS BELIEVED, always. That is the fall, the fire, the car. It
--     is also not the exploit -- a player who lowers their own health has
--     cheated themselves.
--
--   * AN INCREASE IS REFUSED unless the SERVER authorized it. There is no
--     tolerance band that leaks upward and no grace period that commits: a
--     window wide enough to hide a revive is wide enough to hide a cheat, and
--     a +2 amnesty repeated four times a second is eight points of free health
--     per second, which is a ratchet rather than a rounding error.
--
--   * AN AUTHORIZED INCREASE IS CAPPED AT WHAT WAS AUTHORIZED. A bandage buys
--     the bandage's target and not a point more. The alternative -- "any rise
--     inside the heal window" -- was rejected outright: every consumable in the
--     game would then be a two-second amnesty a modified client could pin its
--     health inside, and the re-press loop (#271) makes that window rollable.
--
-- ═══ THE HONEST CLIENT IS THE CASE THAT DECIDES THE DESIGN ═══
--
-- A real player's acknowledgement is DELAYED by their ping. Between the server
-- subtracting 25 and the client applying it, that player's ped legitimately
-- reads 25 HIGHER than the ledger -- which is the cheat's exact shape. A rule
-- that punished it would accuse everybody on a bad connection, and the day this
-- gets switched off is the day it was needed.
--
-- It does not have to be punished, because it does not have to be resolved:
-- REFUSING the rise is already the right answer for both of them. The honest
-- client's ped is about to come down to the ledger on its own, so holding the
-- ledger costs that player nothing at all -- their number was already correct.
-- The difference between the two is not what the ledger does, it is what
-- happens next: the honest ped converges within the round trip and is never
-- counted, resynchronised or reported, while the modified one goes on
-- disagreeing forever and the detector below adds up every point of it.
--
-- That is why `hurtGraceMs` still exists and why its meaning has narrowed. It
-- no longer decides whether the increase COMMITS -- nothing commits an
-- unverified increase any more. It decides whether the disagreement is worth
-- naming: inside the window it is a round trip, outside it is a claim.

BR = BR or {}

--- Is a server-written stamp still inside its window?
---
--- HOISTED TO FILE SCOPE so the detector and the rule cannot drift apart. Both
--- ask the same question -- "did the server do something recently enough that
--- the ped and the ledger are ALLOWED to disagree" -- and the day those two
--- answer differently is the day a player is counted for a rise that was also
--- committed, or excused for one that was refused.
---
--- DECLARED ABOVE BOTH CALLERS, and that is not style: a Lua `local function`
--- is invisible above its own declaration, where the name resolves as a nil
--- global instead. Every stamp it reads is one the SERVER wrote; nothing a
--- client sends ever reaches here.
--- @param now number
--- @param stamp number|nil  a GetGameTimer() reading, or nil for "never"
--- @param ms number|nil     window length; a non-positive window never opens
--- @return boolean
local function within(now, stamp, ms)
    stamp = tonumber(stamp)
    if stamp == nil then return false end
    local w = tonumber(ms) or 0.0
    if w <= 0.0 then return false end
    return (now - stamp) < w
end

--- Is a deadline the server set still in the future?
---
--- `healUntil` and `healthSettleUntil` are DEADLINES rather than events, because
--- both cover a stretch the server already knows the length of: a consumable has
--- an `endsAt` and a revive has a round trip. Comparing `now` against a deadline
--- the writer chose keeps the duration next to the thing that knows it, rather
--- than forcing every writer to agree on one window in here.
--- @param now number
--- @param deadline number|nil
--- @return boolean
local function before(now, deadline)
    deadline = tonumber(deadline)
    return deadline ~= nil and now < deadline
end

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
---    the ledger. It is the one legitimate upward path the ledger does not
---    already own, which is why BR.HealthCommit needs a CEILING here and an
---    excuse is not enough on its own: this window is the only one a player can
---    open on demand, and a window that committed whatever it found inside it
---    would be a two-second amnesty per bandage.
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

    -- The three windows, all read through the file-scope helpers above so that
    -- BR.HealthCommit below is asking exactly the same questions of exactly the
    -- same stamps. Each is "did this happen recently enough that the ped and the
    -- ledger are ALLOWED to disagree", and each compares against a stamp the
    -- SERVER wrote -- never against anything a client sent.
    if within(now, ctx.lastHitAt, cfg.hurtGraceMs or 1500) then
        return 0.0, BR.HealthExcuse.HURT
    end

    if before(now, ctx.healUntil) then
        return 0.0, BR.HealthExcuse.HEALING
    end

    if before(now, ctx.settleUntil) then
        return 0.0, BR.HealthExcuse.SETTLING
    end

    return gain, BR.HealthExcuse.COUNTED
end

--- What the sampler did with one claim, and why.
---
--- A STRING FOR THE SAME REASON BR.HealthExcuse IS ONE: the first question
--- anybody asks of a rule that can refuse a player something is "when does it
--- refuse", and the only useful answer is a name per outcome rather than a
--- boolean nobody can debug. Every one of these is greppable in a test, and the
--- test suite names them rather than asserting on numbers alone.
---
--- THE ONE DISTINCTION THAT DOES REAL WORK IS `HOLD` vs `REFUSED`, and it is
--- the honest-client rule in a single field. Both refuse the increase and
--- neither commits anything; only REFUSED means "nothing explains this", and
--- only REFUSED lets the caller resynchronise the ped. A high-ping player whose
--- acknowledgement is still in flight scores HOLD, so nothing is ever yanked out
--- from under them for having a bad connection.
BR.HealthVerdict = {
    OPEN    = 'open',     -- outside the boundary; the claim is simply believed
    SAMPLE  = 'sample',   -- believed, and it went DOWN: the world hurt them
    FROZEN  = 'frozen',   -- neither direction; the server has just written this
    GRANT   = 'grant',    -- a rise the server authorized, in full
    CAPPED  = 'capped',   -- a rise the server authorized, clamped to what it issued
    HOLD    = 'hold',     -- a rise refused, with an honest explanation for it
    REFUSED = 'refused',  -- a rise refused with nothing whatever to explain it
}

--- What the ledger holds after this sample.
---
--- PURE, AND cfg IS A PARAMETER, for BR.HealthUnexplainedGain's reason: it makes
--- every threshold reachable from a test with values no shipped config would
--- hold, which is the only way a rule gets shown to still refuse.
---
--- USED FOR BOTH HEALTH AND ARMOUR, one call each. `entry.armour` is what
--- BR.Damage.applyHit soaks a hit with BEFORE health is touched and it is
--- sampled off GetPedArmour on the same line, so a client pinning its armour at
--- 100 regenerates the soak four times a second -- the same exploit, costing the
--- shooter more. The two are separate calls rather than one because they have
--- separate ceilings and separate tolerances, not because the rule differs.
---
--- ═══ THE ORDER OF THE CLAUSES IS THE DESIGN. READ IT DOWNWARD ═══
---
--- 1. NOT A NUMBER. An unreadable sample is not evidence of anything, so the
---    ledger stands. A missing LEDGER is the opposite: there is no opinion to
---    contradict yet, so the sample is adopted. `nan ~= nan` is checked rather
---    than assumed, because every comparison against a NaN is false -- so one
---    sliding through would silently read as "no rise" and disable the rule for
---    that player, which is the one failure mode an anticheat must not have.
---
--- 2. `enforce == false`. COMPARED, NOT TESTED FOR TRUTHINESS, like every other
---    flag in this codebase: a convar override can leave a string here, and
---    `if cfg.enforce then` is true for the string "false".
---
--- 3. NOT ALIVE IN A MATCH -> the claim is believed, exactly as it was before
---    this rule existed. Deliberately the SAME boundary the detector uses, and
---    for the same argument: only an ALIVE player can be shot, so only an ALIVE
---    player's ledger is worth defending. Everything outside it would be a fight
---    with the game rather than with a cheat -- a DEAD player's ped is
---    resurrected for the spectator camera, a LOBBY ped is whatever the lobby
---    left it on, the locker hands out a fresh ped on full health, and a
---    returning player's respawn is a rise nobody authorized in any ledger.
---    DBNO never reaches here at all: the sampler skips it, because a downed
---    player's health is a bleed countdown rather than a ped reading.
---
--- 4. A SETTLE WINDOW IS OPEN -> NEITHER DIRECTION COMMITS.
---
---    This is a revive, a respawn or a match reset, where the LEDGER LEADS and
---    the ped follows -- the reverse of every other case here. For one round
---    trip the entry says 100 and the ped is still a corpse, so believing the
---    DOWNWARD sample would drag a just-revived player straight back to the
---    number they were revived from, which is the fix undoing the feature.
---
---    Freezing both directions was chosen over the alternative -- "raise the
---    ledger back to whatever the server wrote" -- because the server does not
---    record what it wrote anywhere, and adding somewhere would mean a new
---    writer in four files (server/combat.lua twice, revivekey.lua, match.lua)
---    to express a fact that is already true: during the window the ledger is
---    correct by construction and the sample is stale. The cost is that world
---    damage in the first `settleMs` after a revive lands on the NEXT sample
---    instead of this one. Nothing is lost -- the ped is still burning, and the
---    sample after the window reads the lower number and commits it.
---
--- 5. THE SAMPLE IS AT OR BELOW THE LEDGER -> BELIEVED. The fall, the fire, the
---    drowning, the car. This clause is why the sampler still exists.
---
--- 6. RESCUE (#191) -> refused, and explained. A downed player rides an
---    ambulance and BR.Combat.revive hands their health back ON ARRIVAL, through
---    the ledger, with a settle window. Nothing about the ride itself authorizes
---    a rise, so the ledger holds -- but it holds as HOLD rather than REFUSED,
---    because yanking a player's ped mid-rescue over a state the server wrote
---    itself would be the detector's cried-wolf failure with teeth on it.
---
--- 7. A HEAL THE SERVER ISSUED -> committed, UP TO THE CEILING IT ISSUED.
---
---    The one legitimate upward path the ledger does not already own. A med kit,
---    a bandage, a shield plate or the ambulance heal (#241) sends INV_EFFECT
---    carrying a TARGET and the CLIENT walks its own ped up to it, so the rise
---    genuinely happens on the client and the sampler reads it on the way past.
---
---    `ctx.grantTo` IS THAT TARGET, echoed onto the entry by whoever issued the
---    effect. Without it the window alone would be an amnesty: two seconds per
---    issue in which any claim at all is committed, re-stamped every 250ms for
---    the length of a channel, and openable on demand by the re-press loop in
---    #271. With it, a bandage buys the bandage.
---
---    A MISSING CEILING FAILS CLOSED, and softly. The rise is refused, but as
---    HOLD -- so the ledger sits low, no incident is raised and no ped is
---    resynchronised. A future heal path that forgets to stamp its ceiling
---    therefore under-heals the ledger until the next authorized write, which is
---    a bug in the player's disfavour; the fail-OPEN alternative is the audit
---    finding back again.
---
--- 8. DAMAGE STILL IN FLIGHT -> refused, and explained. See the header: this is
---    the honest high-ping player, and refusing their rise costs them nothing
---    because their ped is on its way down to this exact number. The window no
---    longer decides whether anything commits; it decides whether the
---    disagreement gets a name.
---
--- 9. WITHIN TOLERANCE -> refused, and explained. Two float pipelines, both
---    floored, so a point of disagreement is arithmetic rather than evidence --
---    but it is still not COMMITTED, because a +2 accepted four times a second
---    is eight free points per second and the ledger would ratchet to full
---    between fights. Held, not counted, not resynchronised.
---
--- 10. EVERYTHING ELSE -> refused, and named. This is the audit's case: a ped
---    that reads higher than the ledger with no server action of any kind behind
---    it. The ledger stands, the detector counts it, and the caller pushes the
---    real number back at the client.
---
--- @param ledger number|nil  the server's display value BEFORE this sample
--- @param sampled number     the display value read off the ped this sample
--- @param ctx table  { now, state, rescue, lastHitAt, healUntil, settleUntil, grantTo }
--- @param cfg table|nil      BR.Config.Combat.healthAudit
--- @return number|nil committed  what the ledger holds after this sample
--- @return string verdict        BR.HealthVerdict.*
function BR.HealthCommit(ledger, sampled, ctx, cfg)
    cfg = cfg or {}
    ctx = ctx or {}

    local s = tonumber(sampled)
    local l = tonumber(ledger)

    if s == nil or s ~= s then return l, BR.HealthVerdict.HOLD end
    if l == nil or l ~= l then return s, BR.HealthVerdict.OPEN end

    if cfg.enforce == false then return s, BR.HealthVerdict.OPEN end

    if ctx.state ~= BR.PlayerState.ALIVE then return s, BR.HealthVerdict.OPEN end

    local now = tonumber(ctx.now) or 0.0

    if before(now, ctx.settleUntil) then return l, BR.HealthVerdict.FROZEN end

    if s <= l then return s, BR.HealthVerdict.SAMPLE end

    -- 0 IS TRUTHY IN LUA, so `rescue` is compared against nil rather than
    -- tested -- the day somebody stores a rescue id of 0 in it is the day a
    -- truthiness test would silently invert this clause.
    if ctx.rescue ~= nil then return l, BR.HealthVerdict.HOLD end

    if before(now, ctx.healUntil) then
        local ceiling = tonumber(ctx.grantTo)
        if ceiling == nil or ceiling ~= ceiling then
            return l, BR.HealthVerdict.HOLD
        end
        -- A ceiling at or below the ledger authorizes nothing. It is an
        -- authority to RAISE and never a license to lower: the downward path is
        -- clause 5's and belongs to the world, not to a consumable.
        if ceiling <= l then return l, BR.HealthVerdict.HOLD end
        if s <= ceiling then return s, BR.HealthVerdict.GRANT end
        return ceiling, BR.HealthVerdict.CAPPED
    end

    if within(now, ctx.lastHitAt, cfg.hurtGraceMs or 1500) then
        return l, BR.HealthVerdict.HOLD
    end

    if (s - l) <= (tonumber(cfg.toleranceHp) or 2.0) then
        return l, BR.HealthVerdict.HOLD
    end

    return l, BR.HealthVerdict.REFUSED
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
