-- XP and levelling.
--
-- Pure functions over numbers -- no database, no natives -- so this is unit
-- testable outside the game (tools/test_stats.lua).
--
-- The curve is quadratic rather than exponential. Exponential curves look
-- generous early and become a wall; a quadratic keeps later levels meaningful
-- without the gap between level 40 and 41 being measured in weeks.

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

--- Progress through the current level, 0..1.
--- @param xp integer
--- @return number pct
--- @return integer intoLevel
--- @return integer levelSpan
function BR.Xp.progress(xp)
    local level = BR.Xp.levelFor(xp)
    if level >= BR.Xp.Config.maxLevel then
        return 1.0, 0, 0
    end
    local lo = BR.Xp.thresholdFor(level)
    local hi = BR.Xp.thresholdFor(level + 1)
    local span = hi - lo
    if span <= 0 then return 0.0, 0, 0 end
    return (xp - lo) / span, xp - lo, span
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

    local win = (place == 1) and c.winBonus or 0
    local top10 = (place > 1 and place <= 10) and c.top10Bonus or 0

    local breakdown = {
        kills = kills, downs = downs, revives = revives, damage = damage,
        survival = survival, placement = placement, win = win, top10 = top10,
    }

    local sum = 0
    for _, v in pairs(breakdown) do sum = sum + v end
    return sum, breakdown
end
