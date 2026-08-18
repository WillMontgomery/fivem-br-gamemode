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
    -- The Volts payout answers the same questions as the XP curve from the
    -- same row, and the two have to agree about what a win is -- so they are
    -- tested together rather than one here and one in a suite that has to boot
    -- the whole roster to reach it.
    'br_lib/config/market.lua',
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

    -- PLACEMENT 1 AND A DEATH IS NOT A WIN. The last squad standing can still
    -- be taken by the storm: eliminate() records placement 1, because nobody
    -- outlasted them, and they died. The client has always drawn that as a
    -- death; the stats and payout path used to bank it as a win.
    local diedLast = BR.Xp.forMatch({ kills = 3, downs = 0, revives = 0, damage = 400,
                                      survivedMs = 900000, placement = 1, total = 48,
                                      died = true })
    ok(diedLast < won, 'placing first but dying does not earn the win bonus',
        ('won=%d diedLast=%d'):format(won, diedLast))
    ok(diedLast > second, 'but it still out-earns second place -- they did finish top',
        ('diedLast=%d second=%d'):format(diedLast, second))

    -- Absent `died` must read as false, or every row built before the field
    -- existed silently loses its win bonus.
    ok(BR.Xp.forMatch({ kills = 3, downs = 0, revives = 0, damage = 400,
                        survivedMs = 900000, placement = 1, total = 48 }) == won,
        'a row with no died field is still a win')

    -- The same rule, on the Volts side. They keep the placement scale (they
    -- did finish top) and lose only the win bonus.
    local paidWin  = BR.Config.marketPayout({ placement = 1, total = 48, kills = 3 })
    local paidDied = BR.Config.marketPayout({ placement = 1, total = 48, kills = 3,
                                              died = true })
    ok(paidDied < paidWin, 'the win payout needs them to have survived it',
        ('win=%d died=%d'):format(paidWin, paidDied))
    ok(paidDied > BR.Config.marketPayout({ placement = 2, total = 48, kills = 3 }),
        'but placing first while dying still beats placing second')

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

-- THE SUMMARY USED TO BE HERE, WHICH DISARMED EVERYTHING BELOW IT.
--
-- It printed the totals and called `os.exit(1)` on failure -- and the curve
-- contract, the section this file exists to enforce, runs AFTER it. So a
-- contract failure printed a red FAIL line and then the script ran off the end
-- of the file and exited 0. tools/verify.sh reads the exit code, so the one
-- thing pinning the game's curve to Ringmaster's could not fail the build; it
-- could only leave a message in a passing log.
--
-- That is the same shape as the rest of this bug: a check that exists, looks
-- right, and is wired to nothing. The summary now runs once, at the bottom.

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

-- THE FIRST TEN, not the first five. These are the numbers the curve was
-- explained to the owner with, so they are the ones that have to stay true: a
-- tuning that moves level 7 moves who is level 7, and it should fail here
-- rather than on somebody's profile.
for _, c in ipairs({
    { level = 1,  threshold = 0 },
    { level = 2,  threshold = 800 },
    { level = 3,  threshold = 2350 },
    { level = 4,  threshold = 4400 },
    { level = 5,  threshold = 6850 },
    { level = 6,  threshold = 9700 },
    { level = 7,  threshold = 12850 },
    { level = 8,  threshold = 16350 },
    { level = 9,  threshold = 20100 },
    { level = 10, threshold = 24100 },
}) do
    ok(BR.Xp.thresholdFor(c.level) == c.threshold,
        ('thresholdFor(%d) == %d'):format(c.level, c.threshold))
    ok(BR.Xp.thresholdFor(c.level) % 50 == 0,
        ('thresholdFor(%d) is a multiple of 50'):format(c.level))
end

-- THE CUMULATIVE PAIR IS PINNED TOO, and that is what this revision adds.
--
-- These cases used to assert `into`/`span` alone -- the offset inside the
-- current level and what that level costs -- which is the pair every surface
-- renders, and is not the pair a player is asking about. 18,196 lifetime XP
-- displayed as "1,846 / 3,750", and the owner read it as a level 8 player
-- holding less XP than level 3 costs. The curve was right; the pair on screen
-- was the wrong one. Pinning one representation and not the other is how a
-- display drifts from the curve underneath it with every test still green.
for _, c in ipairs({
    { xp = 0,    level = 1, into = 0,    span = 800,  next = 800 },
    { xp = 1,    level = 1, into = 1,    span = 800,  next = 800 },
    { xp = 799,  level = 1, into = 799,  span = 800,  next = 800 },
    { xp = 800,  level = 2, into = 0,    span = 1550, next = 2350 },
    { xp = 801,  level = 2, into = 1,    span = 1550, next = 2350 },
    { xp = 2349, level = 2, into = 1549, span = 1550, next = 2350 },
    { xp = 2350, level = 3, into = 0,    span = 2050, next = 4400 },
    { xp = 2498, level = 3, into = 148,  span = 2050, next = 4400 },
    { xp = 4399, level = 3, into = 2049, span = 2050, next = 4400 },
    { xp = 4400, level = 4, into = 0,    span = 2450, next = 6850 },

    -- THE OWNER'S OWN PROFILE (2026-08-17), by the exact numbers reported.
    -- Level 8 begins at 16,350 and costs 3,750: 16,350 + 1,846 = 18,196, and
    -- the next level begins at 20,100.
    { xp = 18196, level = 8, into = 1846, span = 3750, next = 20100 },

    -- Both sides of the top of the curve. `next` is 0 at max level rather than
    -- a threshold that does not exist, and every display has to branch on it.
    { xp = 991549, level = 99,  into = 15449, span = 15450, next = 991550 },
    { xp = 991550, level = 100, into = 0,     span = 0,     next = 0 },

    -- A negative total cannot reach the store, which only applies non-negative
    -- ADDs -- but levelFor clamps and progress has to clamp with it, or one
    -- half answers level 1 while the other answers into = -500.
    { xp = -500, level = 1, into = 0, span = 800, next = 800 },
}) do
    ok(BR.Xp.levelFor(c.xp) == c.level,
        ('levelFor(%d) == %d'):format(c.xp, c.level))

    local _, into, span, total, nxt = BR.Xp.progress(c.xp)
    ok(into == c.into and span == c.span,
        ('progress(%d) into/span == %d/%d'):format(c.xp, c.into, c.span),
        ('got %s/%s'):format(tostring(into), tostring(span)))

    -- The pair the player reads.
    ok(nxt == c.next,
        ('progress(%d) next == %d'):format(c.xp, c.next),
        ('got %s'):format(tostring(nxt)))
    ok(BR.Xp.nextThresholdFor(c.xp) == c.next,
        ('nextThresholdFor(%d) == %d'):format(c.xp, c.next),
        ('got %s'):format(tostring(BR.Xp.nextThresholdFor(c.xp))))
    ok(total == math.max(0, c.xp),
        ('progress(%d) total == %d'):format(c.xp, math.max(0, c.xp)),
        ('got %s'):format(tostring(total)))
end

-- THE TWO REPRESENTATIONS ARE ONE FACT, across the whole curve rather than at
-- the handful of totals above.
--
-- This is the check the feature never had. The cumulative pair and the bar's
-- per-level pair describe the same position and nothing said so, so a screen
-- could render one while the level came from the other and everything passed.
-- The identical sweep runs in the console's scripts/check-xp-curve.mjs.
do
    -- MAX LEVEL IS A DIFFERENT CONTRACT AND IS STATED AS ONE.
    --
    -- The first version of this sweep asserted `into == total - floor`
    -- everywhere and failed at 992,136 -- in BOTH repos, at the identical
    -- total, which is the fixture doing exactly its job. Past 991,550 a player
    -- keeps earning XP and `into` stays 0, because there is no level to be
    -- part-way through. That is deliberate: into/span is bar geometry and
    -- there is no bar up there. The cumulative pair is what stays meaningful.
    local bad = {}
    local maxLevel = BR.Xp.Config.maxLevel
    for xp = 0, 1100000, 617 do
        local pct, into, span, total, nxt = BR.Xp.progress(xp)
        local level = BR.Xp.levelFor(xp)
        local floor = BR.Xp.thresholdFor(level)

        if nxt == 0 then
            if level ~= maxLevel or into ~= 0 or span ~= 0 or pct ~= 1.0 then
                bad[#bad + 1] = ('at %d: max level should be %d/0/0/1, got %d/%d/%d/%s')
                    :format(xp, maxLevel, level, into, span, tostring(pct))
            elseif total < BR.Xp.thresholdFor(maxLevel) then
                bad[#bad + 1] = ('at %d: no next level below the level-%d threshold')
                    :format(xp, maxLevel)
            end
        elseif into ~= total - floor then
            bad[#bad + 1] = ('at %d: into %d ~= total %d - floor %d')
                :format(xp, into, total, floor)
        elseif nxt ~= floor + span then
            bad[#bad + 1] = ('at %d: next %d ~= floor %d + span %d')
                :format(xp, nxt, floor, span)
        elseif not (total >= floor and total < nxt) then
            bad[#bad + 1] = ('at %d: total %d outside [%d, %d)')
                :format(xp, total, floor, nxt)
        elseif BR.Xp.levelFor(nxt) ~= level + 1 then
            bad[#bad + 1] = ('at %d: next %d is level %d, expected %d')
                :format(xp, nxt, BR.Xp.levelFor(nxt), level + 1)
        end
        if #bad > 0 then break end
    end
    ok(#bad == 0, 'the cumulative pair and the bar agree at every total',
        table.concat(bad, '; '))
end

io.write(('\n\27[32m%d passed\27[0m'):format(pass))
if fail > 0 then
    io.write(('  \27[31m%d failed\27[0m\n'):format(fail))
    os.exit(1)
end
io.write('\n')
