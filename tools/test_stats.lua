-- Unit tests for br_stats' XP curve.
--
-- xp.lua is pure arithmetic with no database and no natives, so it is testable
-- outside the game. The level inversion is the part worth testing hard: it uses
-- a closed-form root rather than a loop, and floating-point pow is exactly where
-- an off-by-one at a level boundary would hide.

function GetGameTimer() return 0 end

local ROOT = 'resources/[fivem-royale]/'
for _, f in ipairs({
    'br_lib/shared/enums.lua',
    'br_lib/shared/xp.lua',
}) do
    local chunk, err = loadfile(ROOT .. f)
    if not chunk then
        io.write('\27[31mload error\27[0m ', f, ': ', tostring(err), '\n')
        os.exit(1)
    end
    chunk()
end

local pass, fail = 0, 0
local group = ''
local function describe(n) group = n end
local function ok(cond, name, detail)
    if cond then pass = pass + 1 else
        fail = fail + 1
        io.write('\27[31mFAIL\27[0m ', group, ' > ', name,
            detail and ('\n       ' .. tostring(detail)) or '', '\n')
    end
end

describe('xp.thresholds')
do
    ok(BR.Xp.thresholdFor(1) == 0, 'level 1 starts at zero xp')
    ok(BR.Xp.thresholdFor(0) == 0, 'level 0 degrades to zero')

    local monotonic, prev = true, -1
    for lvl = 1, BR.Xp.Config.maxLevel do
        local t = BR.Xp.thresholdFor(lvl)
        if t <= prev and lvl > 1 then monotonic = false end
        prev = t
    end
    ok(monotonic, 'thresholds strictly increase with level')

    -- Each level should cost more than the one before it, or the curve is not
    -- actually a curve.
    local accelerating = true
    for lvl = 2, BR.Xp.Config.maxLevel - 1 do
        local a = BR.Xp.thresholdFor(lvl) - BR.Xp.thresholdFor(lvl - 1)
        local b = BR.Xp.thresholdFor(lvl + 1) - BR.Xp.thresholdFor(lvl)
        if b < a then accelerating = false end
    end
    ok(accelerating, 'each level costs at least as much as the previous one')
end

describe('xp.levelFor')
do
    ok(BR.Xp.levelFor(0) == 1, 'zero xp is level 1')
    ok(BR.Xp.levelFor(-500) == 1, 'negative xp degrades to level 1')

    -- THE important test: levelFor must exactly invert thresholdFor at every
    -- boundary, including one xp either side of it.
    local bad = {}
    for lvl = 2, BR.Xp.Config.maxLevel do
        local t = BR.Xp.thresholdFor(lvl)
        if BR.Xp.levelFor(t) ~= lvl then
            bad[#bad + 1] = ('at threshold %d: expected %d got %d')
                :format(t, lvl, BR.Xp.levelFor(t))
        end
        if BR.Xp.levelFor(t - 1) ~= lvl - 1 then
            bad[#bad + 1] = ('just below %d: expected %d got %d')
                :format(t, lvl - 1, BR.Xp.levelFor(t - 1))
        end
    end
    ok(#bad == 0, 'levelFor exactly inverts thresholdFor at every boundary',
        table.concat(bad, '; '):sub(1, 300))

    local capped = BR.Xp.levelFor(BR.Xp.thresholdFor(BR.Xp.Config.maxLevel) * 100)
    ok(capped == BR.Xp.Config.maxLevel, 'level is capped at maxLevel',
        ('got %d'):format(capped))

    local monotonic = true
    local last = 1
    for xp = 0, 500000, 997 do
        local l = BR.Xp.levelFor(xp)
        if l < last then monotonic = false end
        last = l
    end
    ok(monotonic, 'level never decreases as xp increases')
end

describe('xp.progress')
do
    local inRange = true
    for xp = 0, 300000, 613 do
        local pct = BR.Xp.progress(xp)
        if pct < 0.0 or pct > 1.0 then inRange = false end
    end
    ok(inRange, 'progress stays within 0..1')

    local atStart = BR.Xp.progress(BR.Xp.thresholdFor(5))
    ok(atStart < 0.01, 'progress resets at a level boundary',
        ('got %.4f'):format(atStart))

    local justBelow = BR.Xp.progress(BR.Xp.thresholdFor(6) - 1)
    ok(justBelow > 0.9, 'progress approaches 1 just before the next level',
        ('got %.4f'):format(justBelow))

    local maxed = BR.Xp.progress(BR.Xp.thresholdFor(BR.Xp.Config.maxLevel))
    ok(maxed == 1.0, 'max level reports full progress')
end

describe('xp.forMatch')
do
    local base = { kills = 0, downs = 0, revives = 0, damage = 0,
                   survivedMs = 0, placement = 48, total = 48 }

    local none = BR.Xp.forMatch(base)
    ok(none >= 0, 'a last-place empty match is never negative', ('got %d'):format(none))

    local killer = BR.Xp.forMatch({ kills = 5, downs = 0, revives = 0, damage = 500,
                                    survivedMs = 300000, placement = 10, total = 48 })
    local passive = BR.Xp.forMatch({ kills = 0, downs = 0, revives = 0, damage = 0,
                                     survivedMs = 300000, placement = 10, total = 48 })
    ok(killer > passive, 'kills and damage are rewarded')

    local won = BR.Xp.forMatch({ kills = 3, downs = 0, revives = 0, damage = 400,
                                 survivedMs = 900000, placement = 1, total = 48 })
    local second = BR.Xp.forMatch({ kills = 3, downs = 0, revives = 0, damage = 400,
                                    survivedMs = 900000, placement = 2, total = 48 })
    ok(won > second, 'winning beats second place')

    -- Second of 48 should land close to a win, not fall off a bracket edge.
    -- A flat "top N" bonus would make 10th and 11th wildly different for no
    -- reason the player can perceive.
    ok(second > won * 0.75, 'second place is close to a win, not a cliff',
        ('won=%d second=%d ratio=%.2f'):format(won, second, second / won))

    local mid = BR.Xp.forMatch({ kills = 3, downs = 0, revives = 0, damage = 400,
                                 survivedMs = 900000, placement = 24, total = 48 })
    local last = BR.Xp.forMatch({ kills = 3, downs = 0, revives = 0, damage = 400,
                                  survivedMs = 900000, placement = 48, total = 48 })
    ok(mid > last, 'placement scales continuously rather than in brackets')

    -- Placement should be roughly linear between first and last.
    local span = won - last
    local halfway = mid - last
    ok(math.abs((halfway / span) - 0.5) < 0.25,
        'placement reward is roughly linear',
        ('halfway is %.2f of the span'):format(halfway / span))

    local _, breakdown = BR.Xp.forMatch({ kills = 2, downs = 1, revives = 1, damage = 250,
                                          survivedMs = 600000, placement = 1, total = 48 })
    ok(breakdown.win > 0 and breakdown.kills > 0 and breakdown.revives > 0,
        'breakdown itemises each source for the summary screen')

    -- A solo match (total = 1) must not divide by zero.
    local solo = BR.Xp.forMatch({ kills = 0, downs = 0, revives = 0, damage = 0,
                                  survivedMs = 1000, placement = 1, total = 1 })
    ok(solo >= 0 and solo == solo, 'a one-player match does not divide by zero',
        ('got %s'):format(tostring(solo)))

    local missing = BR.Xp.forMatch({})
    ok(missing >= 0 and missing == missing, 'an empty result table is handled',
        ('got %s'):format(tostring(missing)))
end

io.write(('\n\27[32m%d passed\27[0m'):format(pass))
if fail > 0 then
    io.write(('  \27[31m%d failed\27[0m\n'):format(fail))
    os.exit(1)
end
io.write('\n')

-- ---------------------------------------------------------------------------
-- THE CURVE CONTRACT, shared with Ringmaster.
--
-- The console cannot run Lua, so it carries its own port of this curve in
-- src/lib/xp.ts. Two implementations of one rule are only safe when something
-- fails loudly the moment they disagree -- the same arrangement the ban rule
-- already has, for the same reason.
--
-- THESE CASES ARE THE CONTRACT. The identical list lives in the console's
-- scripts/check-xp-curve.mjs and both sides must satisfy it. If you change the
-- curve here, change it there, and these will tell you if you got it wrong.
--
-- THE BOUNDARY CASES ARE THE POINT. A port that rounds differently agrees on
-- most values and diverges near a threshold -- correct almost always, wrong
-- exactly when somebody is about to level up. 2498 is in the list because it
-- is the real value that exposed Ringmaster showing level 2 for a player the
-- game showed as level 3.
-- ---------------------------------------------------------------------------
describe('xp.curve contract (mirrored in fivem-ringmaster)')

for _, c in ipairs({
    { level = 1, threshold = 0 },
    { level = 2, threshold = 800 },
    { level = 3, threshold = 2350 },
    { level = 4, threshold = 4400 },
    { level = 5, threshold = 6850 },
}) do
    ok(BR.Xp.thresholdFor(c.level) == c.threshold,
        ('thresholdFor(%d) == %d'):format(c.level, c.threshold))
    ok(BR.Xp.thresholdFor(c.level) % 50 == 0,
        ('thresholdFor(%d) is a multiple of 50'):format(c.level))
end

for _, c in ipairs({
    { xp = 0,    level = 1, into = 0,    span = 800 },
    { xp = 1,    level = 1, into = 1,    span = 800 },
    { xp = 799,  level = 1, into = 799,  span = 800 },
    { xp = 800,  level = 2, into = 0,    span = 1550 },
    { xp = 801,  level = 2, into = 1,    span = 1550 },
    { xp = 2349, level = 2, into = 1549, span = 1550 },
    { xp = 2350, level = 3, into = 0,    span = 2050 },
    { xp = 2498, level = 3, into = 148,  span = 2050 },
    { xp = 4399, level = 3, into = 2049, span = 2050 },
    { xp = 4400, level = 4, into = 0,    span = 2450 },
}) do
    ok(BR.Xp.levelFor(c.xp) == c.level,
        ('levelFor(%d) == %d'):format(c.xp, c.level))

    local _, into, span = BR.Xp.progress(c.xp)
    ok(into == c.into and span == c.span,
        ('progress(%d) == %d/%d'):format(c.xp, c.into, c.span))
end
