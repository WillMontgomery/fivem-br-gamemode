-- XP and levelling.
--
-- Pure functions over numbers -- no database, no natives -- so this is unit
-- testable outside the game (tools/test_stats.lua).
--
-- The curve is quadratic rather than exponential. Exponential curves look
-- generous early and become a wall; a quadratic keeps later levels meaningful
-- without the gap between level 40 and 41 being measured in weeks.
--
-- THE MODEL IS CUMULATIVE LIFETIME XP AGAINST RISING THRESHOLDS, and always
-- has been -- `thresholdFor` is a running total and `levelFor` is its inverse,
-- so nothing is ever reset or spent. What resets is `into`, the offset used to
-- draw a bar, and rendering that offset as though it were the player's XP is
-- what made level 8 look like it held 1,846 XP. See `nextThresholdFor`.

BR = BR or {}
BR.Xp = {}

BR.Xp.Config = {
    -- XP awarded per event.
    perKill        = 60,
    perDown        = 25,   -- squads: knocking someone down, before the finish
    perRevive      = 40,
    perDamage      = 0.35, -- per point of damage dealt
    perMinute      = 12,   -- survival time
    perPlacement   = 500,  -- scaled by how close to first you finished
    winBonus       = 400,
    top10Bonus     = 120,

    -- Level curve: xpForLevel(n) = base * (n-1)^exponent
    base           = 800,
    exponent       = 1.55,
    maxLevel       = 100,
}

--- Total XP required to have REACHED a given level.
--- @param level integer
--- @return integer
--- ROUNDED TO THE NEAREST 50, because a player reads this number.
---
--- The raw curve produces thresholds like 2342 and spans like 1542, and "1,542
--- XP to the next level" reads as a number that fell out of a spreadsheet
--- rather than one somebody chose (owner, 2026-08-15). Rounding the THRESHOLD
--- rather than the span is what keeps both tidy: a span is the difference of
--- two thresholds, so multiples of 50 subtract to multiples of 50.
---
--- It cannot round to zero for level 2 and it cannot go backwards, because
--- `base` is 800 and the curve is monotonic well above the rounding step.
local ROUND_TO = 50

function BR.Xp.thresholdFor(level)
    if level <= 1 then return 0 end
    local c = BR.Xp.Config
    local raw = c.base * ((level - 1) ^ c.exponent)
    return math.floor(raw / ROUND_TO + 0.5) * ROUND_TO
end

--- The LIFETIME total at which this player reaches their next level.
---
--- THE CURVE HAS ALWAYS BEEN CUMULATIVE AND THE SCREEN HAS ALWAYS HIDDEN IT.
--- `progress` below returns `into`/`span` -- where you are inside the current
--- level, counted from zero again every time you level up -- and that is the
--- pair every surface renders. So a player holding 18,196 lifetime XP reads
--- "1,846 / 3,750" beside a level 8 chip, and asked the obvious question: how
--- can I be level 8 with less XP than level 3 costs? (owner, 2026-08-17)
---
--- They could not, and they never were: 16,350 + 1,846 = 18,196, and 3,750 is
--- exactly what level 8 costs. Both numbers were true and neither was the one
--- being asked for. This is the pair that answers it -- 18,196 / 20,100 -- the
--- same two numbers `levelFor` already derives the level from.
---
--- 0 MEANS THERE IS NO NEXT LEVEL rather than "the next level is free". nil
--- would make every arithmetic caller guard, and 0 fails the `> 0` test that
--- the max-level branch needs anyway.
--- @param xp integer
--- @return integer
function BR.Xp.nextThresholdFor(xp)
    local level = BR.Xp.levelFor(xp)
    if level >= BR.Xp.Config.maxLevel then return 0 end
    return BR.Xp.thresholdFor(level + 1)
end

--- Level implied by a total XP value.
--- @param xp integer
--- @return integer
function BR.Xp.levelFor(xp)
    local c = BR.Xp.Config
    if xp <= 0 then return 1 end

    -- Invert the curve directly rather than looping from level 1. At level 100
    -- a loop is trivial, but this is called for every player at match end and
    -- the closed form is exact.
    local level = math.floor((xp / c.base) ^ (1.0 / c.exponent)) + 1
    if level > c.maxLevel then level = c.maxLevel end
    if level < 1 then level = 1 end

    -- Guard against floating point landing a hair under the threshold.
    while level < c.maxLevel and xp >= BR.Xp.thresholdFor(level + 1) do
        level = level + 1
    end
    while level > 1 and xp < BR.Xp.thresholdFor(level) do
        level = level - 1
    end
    return level
end

--- Where one lifetime XP total sits on the curve.
---
--- TWO REPRESENTATIONS OF ONE POSITION, AND BOTH ARE NEEDED -- which is why
--- they come back from one call rather than from two functions a caller can
--- pick the wrong one of:
---
---   total / next   THE CUMULATIVE PAIR. Lifetime XP, and the lifetime XP at
---                  which the next level starts. The owner's model, and the
---                  only pair that means anything on its own -- "18,196 /
---                  20,100" is legible without knowing what level you are.
---   into / span    THE BAR'S GEOMETRY. A bar cannot be drawn from the
---                  cumulative pair: 18,196 of 20,100 is 90% full at level 8
---                  and 99% full at level 50, so every bar past the early game
---                  would read as nearly finished. A bar's zero is the level's
---                  floor, not the player's first ever match.
---
--- They are the same fact -- `into == total - thresholdFor(level)` and
--- `next == thresholdFor(level) + span` -- and tools/test_stats.lua asserts
--- exactly that, on both sides of the repo boundary. THE FIRST THREE RETURNS
--- ARE UNCHANGED AND IN THE SAME ORDER: br_core/server/market.lua and
--- br_stats/server/persist.lua both destructure `local _, into, span`, and the
--- new values are appended so neither has to move to keep working.
--- @param xp integer
--- @return number pct
--- @return integer intoLevel
--- @return integer levelSpan
--- @return integer total    lifetime xp, clamped at zero
--- @return integer next     lifetime xp the next level begins at; 0 at max
function BR.Xp.progress(xp)
    -- Clamped rather than passed through. A negative total is impossible --
    -- the store only ever applies non-negative ADDs -- but `levelFor` already
    -- answers 1 for it, and reporting level 1 alongside `into = -500` would be
    -- the two halves of one function disagreeing about one input.
    local total = (xp and xp > 0) and xp or 0

    local level = BR.Xp.levelFor(total)
    if level >= BR.Xp.Config.maxLevel then
        return 1.0, 0, 0, total, 0
    end
    local lo = BR.Xp.thresholdFor(level)
    local hi = BR.Xp.thresholdFor(level + 1)
    local span = hi - lo
    if span <= 0 then return 0.0, 0, 0, total, hi end
    return (total - lo) / span, total - lo, span, total, hi
end

--- XP earned from one match result.
---
--- @param r table  { kills, downs, revives, damage, survivedMs, placement, total }
--- @return integer xp
--- @return table breakdown  for the summary screen
function BR.Xp.forMatch(r)
    local c = BR.Xp.Config

    local kills    = math.floor((r.kills   or 0) * c.perKill)
    local downs    = math.floor((r.downs   or 0) * c.perDown)
    local revives  = math.floor((r.revives or 0) * c.perRevive)
    local damage   = math.floor((r.damage  or 0) * c.perDamage)
    local survival = math.floor(((r.survivedMs or 0) / 60000.0) * c.perMinute)

    -- Placement scales linearly from 0 (last) to full value (first). A player
    -- who finished 2nd of 48 should be rewarded close to a winner, which a flat
    -- "top N" bracket would not do.
    local placement = 0
    local total = r.total or 0
    local place = r.placement or 0
    if total > 1 and place >= 1 then
        local frac = (total - place) / (total - 1)
        placement = math.floor(c.perPlacement * frac)
    end

    -- THE WIN BONUS NEEDS THEM TO HAVE SURVIVED IT. Placement 1 says nobody
    -- outlasted them; it does not say they were alive at the end. The last
    -- squad standing taken by the storm places 1st and died, and paying the
    -- win bonus for that was worth more than the whole rest of the match.
    -- `died` is absent on rows built before this existed, which reads as false
    -- and preserves the old behaviour for them.
    local win = (place == 1 and not r.died) and c.winBonus or 0
    -- THE TOP-10 BONUS FILLS THE HOLE THE WIN BONUS LEAVES. It used to read
    -- `place > 1` because placement 1 always collected the larger win bonus
    -- instead -- but a placement-1 death now collects neither, and that made
    -- outlasting everybody and dying pay LESS than finishing second, which is
    -- the same inversion in a smaller coat. Gated on the win bonus not having
    -- been paid rather than on the place, so the two can never both apply and
    -- can never both be skipped.
    local top10 = (win == 0 and place >= 1 and place <= 10) and c.top10Bonus or 0

    local breakdown = {
        kills = kills, downs = downs, revives = revives, damage = damage,
        survival = survival, placement = placement, win = win, top10 = top10,
    }

    local sum = 0
    for _, v in pairs(breakdown) do sum = sum + v end
    return sum, breakdown
end
