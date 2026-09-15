-- Unit tests for br_stats' XP curve, and for the report-reward pipeline.
--
-- xp.lua is pure arithmetic with no database and no natives, so it is testable
-- outside the game. The level inversion is the part worth testing hard: it uses
-- a closed-form root rather than a loop, and floating-point pow is exactly where
-- an off-by-one at a level boundary would hide.
--
-- server/awards.lua (#168) is here for a different reason: every interesting
-- thing it does happens against a database that is not present, hours after the
-- event that started it, and its whole job is to be safe when repeated. That is
-- untestable in game and trivially testable with a stubbed br_ddb, which is
-- what the second half of this file is.

function GetGameTimer() return 0 end

-- --------------------------------------------------------------- harness ---
--
-- Enough of FiveM for awards.lua to load and be driven. Nothing here fires on
-- its own: the sweep thread is a no-op and the tests call BR.Awards.sweep()
-- when they want one, which is the only way to test "the answer never came".

local handlers = {}
function AddEventHandler(name, fn)
    handlers[name] = handlers[name] or {}
    table.insert(handlers[name], fn)
end

-- A NO-OP, AND THAT IS WHAT IT IS ON THE SERVER TOO. RegisterNetEvent only
-- marks a name as reachable from a client; the handler is still AddEventHandler.
-- So a test that fires the name directly exercises exactly the same function the
-- network would reach, and stubbing this to nothing loses no coverage.
function RegisterNetEvent(_) end

--- Every br_ddb request this file made, in order. The test answers them by
--- firing the matching result event, exactly as the JS half would.
local asked = {}

function TriggerEvent(name, ...)
    asked[#asked + 1] = { name = name, args = { ... } }
    for _, fn in ipairs(handlers[name] or {}) do fn(...) end
end

--- Requests of one kind, oldest first.
local function askedFor(name)
    local out = {}
    for _, a in ipairs(asked) do
        if a.name == name then out[#out + 1] = a end
    end
    return out
end

local sent = {}
function TriggerClientEvent(name, src, payload)
    sent[#sent + 1] = { name = name, src = src, payload = payload }
end

local timers = {}
function SetTimeout(ms, fn) timers[#timers + 1] = { ms = ms, fn = fn } end
local function fireTimers()
    local due = timers
    timers = {}
    for _, t in ipairs(due) do t.fn() end
end

local resourceState = { br_ddb = 'started' }
function GetResourceState(name) return resourceState[name] or 'missing' end

--- Who is connected, and what their identifiers are. Empty by default: the
--- award has to land for somebody who is NOT here, and that is the case most
--- likely to be got wrong.
local online = {}          -- [src] = { 'license:aaa', ... }
function GetPlayers()
    local out = {}
    for src in pairs(online) do out[#out + 1] = tostring(src) end
    table.sort(out)
    return out
end
function GetNumPlayerIdentifiers(src) return #(online[tonumber(src)] or {}) end
function GetPlayerIdentifier(src, i)  return (online[tonumber(src)] or {})[i + 1] end

-- The sweep loop must not run itself; every test drives it explicitly.
Citizen = { CreateThread = function() end, Wait = function() end }

local commands = {}
function RegisterCommand(name, fn, restricted)
    commands[name] = { fn = fn, restricted = restricted }
end

local realPrint = print
local printed = {}
function print(s) printed[#printed + 1] = tostring(s) end

local ROOT = 'resources/[fivem-royale]/'
for _, f in ipairs({
    'br_lib/shared/enums.lua',
    'br_lib/shared/xp.lua',
    -- The Volts payout answers the same questions as the XP curve from the
    -- same row, and the two have to agree about what a win is -- so they are
    -- tested together rather than one here and one in a suite that has to boot
    -- the whole roster to reach it.
    'br_lib/config/market.lua',
    -- BR.Net.NOTIFY, for the sentence the reward sends.
    'br_lib/shared/protocol.lua',
    -- BR.Identity; awards.lua resolves a license back to a connected src.
    'br_lib/shared/identity.lua',
    -- BR.MatchTag and BR.MatchFromTag; br_core/server/debug.lua's brloot names
    -- matches with the first and reads its argument with the second.
    'br_lib/shared/matchtag.lua',
    'br_stats/server/awards.lua',
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

-- ---------------------------------------------------------------------------
-- THE PAYOUT'S SHAPE, WHICH IS THE ONLY THING A RESCALE MAY NOT CHANGE.
--
-- WRITTEN FOR 2026-08-20 AND FOR THE NEXT ONE. The owner asked to "cut all
-- Volts earnings by 50%", and the whole risk in a request like that is that
-- "all" is applied to four of the five places and the fifth is left standing --
-- which does not fail anything above, because every assertion up there compares
-- a payout against another payout from the SAME table and both moved together.
-- BR.Config.levelBonus is the one that lives outside that table, and it is
-- exactly the term #89 had to fix for competing with a win.
--
-- SO NOTHING BELOW PINS AN AMOUNT. Pinning would make the next retune a red
-- build to be edited green, which teaches nobody anything. What is pinned is
-- the ORDER of the terms and the level bonus's position against the win --
-- properties a uniform rescale preserves exactly and a partial one breaks.
-- ---------------------------------------------------------------------------
describe('volts.payout shape')
do
    local p = BR.Config.Market.payout

    ok(p.completion > 0, 'every match pays something -- last with nothing is not zero',
        tostring(p.completion))
    ok(BR.Config.marketPayout({ placement = 16, total = 16 }) == p.completion,
        'and finishing last with nothing pays exactly that and no more',
        tostring(BR.Config.marketPayout({ placement = 16, total = 16 })))

    -- ═══ AND THE WIN DOMINATES, WHICH IS THE 2026-08-29 TABLE'S OWN SHAPE ═══
    --
    -- `win` and `placementTop` never both pay: the surviving winner takes the
    -- first and everybody else takes the second, scaled by where they finished.
    -- So the ratio between them IS the decision, and at 1000 against 200 the win
    -- is the thing worth playing for.
    ok(p.win > p.placementTop,
        'a win is worth more than the best placement scale',
        ('win %d, placementTop %d'):format(p.win, p.placementTop))

    -- ═══ AND THIS ONE CHANGED DIRECTION ON 2026-08-29, WHICH IS WHY IT SAYS
    --     `>=` ═══
    --
    -- It read `p.placementTop > p.perKill * 4` and was called "placement
    -- outweighs a good gunfight -- kills are chased, not farmed", which was true
    -- of the old table (35 against 20) and is not true of the owner's. He set
    -- all five weights himself, and at 200 against 4x50 placing second of sixty
    -- earns about 197 -- ROUGHLY FOUR KILLS, deliberately. Placement is a real
    -- but modest bonus now and the win is the headline term.
    --
    -- WEAKENED RATHER THAN INVERTED. Asserting that placement is worth LESS than
    -- four kills would pin the new table exactly as hard as the old assertion
    -- pinned the old one, and would go red the day he raises placementTop --
    -- which is a retune this file must not punish. `>=` keeps the floor that
    -- matters (a gunfight never outpays finishing well) and lets the value move.
    ok(p.placementTop >= p.perKill * 4,
        'placement is worth at least a good gunfight -- kills are chased, not '
            .. 'farmed',
        ('placementTop %d, four kills %d'):format(p.placementTop, p.perKill * 4))
    ok(p.perKill > p.perRevive,
        'a kill pays more than a revive, and a revive pays',
        ('perKill %d, perRevive %d'):format(p.perKill, p.perRevive))

    -- #89 IN ONE LINE. The level-up used to exceed the win bonus outright, so
    -- the largest term in a session went to whoever crossed a boundary. Both
    -- numbers halved on 2026-08-20, which leaves this ratio untouched -- and
    -- that is the point: halve one and not the other and this fails.
    -- %s, NOT %d, ON EVERY BONUS BELOW. `%d` raises on a float in Lua 5.4, and
    -- the mutation this whole block is aimed at -- halving without flooring --
    -- produces exactly that. The suite would have died inside its own detail
    -- string, exiting non-zero with a stack trace instead of naming the check.
    local lvl3 = BR.Config.levelBonus(3)
    ok(lvl3 * 3 < p.win,
        'a level-up is a punctuation mark on a win, not a substitute for one',
        ('levelBonus(3) %s against a win of %d'):format(tostring(lvl3), p.win))
    ok(BR.Config.levelBonus(4) > lvl3,
        'and later levels still pay more, because the XP between them grows',
        ('%s then %s'):format(tostring(lvl3), tostring(BR.Config.levelBonus(4))))

    -- Whole numbers, at every level. A balance is an integer in DynamoDB and on
    -- the verdict screen, and the halving put a .5 on every other level.
    local fractional = nil
    for lvl = 1, BR.Xp.Config.maxLevel do
        local v = BR.Config.levelBonus(lvl)
        if v ~= math.floor(v) then fractional = ('level %d pays %s'):format(lvl, tostring(v)) end
    end
    ok(fractional == nil, 'and every level bonus is a whole number of Volts', fractional)
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

-- ========================================================================
-- server/awards.lua -- 100 Volts for an accurate report (#168, #256)
-- ========================================================================

local INC = 'incident-abc'
local ALICE = 'license:alice'
local BOB   = 'license:bob'

--- Start each case from a clean bench.
local function reset()
    asked, sent, timers, printed, online = {}, {}, {}, {}, {}
end

--- Request event -> reply event, SPELLED OUT rather than derived by appending
--- 'Result'. br_ddb's naming is "noun + Result" and not "request + Result" --
--- `putIncident` answers on `incidentResult`, `banCheck` on `banResult` -- so a
--- helper that appended would silently answer nothing and every assertion below
--- would fail for the wrong reason. It cost one debugging round to find that
--- out; the table is the fix.
local REPLY = {
    ['br:ddb:awardClaim']      = 'br:ddb:awardClaimResult',
    ['br:ddb:awardQueue']      = 'br:ddb:awardQueueResult',
    ['br:ddb:incidentVerdict'] = 'br:ddb:verdictResult',
    ['br:ddb:awardPay']        = 'br:ddb:awardPayResult',
    ['br:ddb:awardSettle']     = 'br:ddb:awardSettleResult',
}

--- Answer the LAST request of one kind, the way br_ddb would.
--- @return boolean  whether there was one to answer
local function answer(name, ...)
    local list = askedFor(name)
    local last = list[#list]
    if not last then return false end
    -- arg 1 of every br_ddb request is the correlation id.
    TriggerEvent(REPLY[name], last.args[1], ...)
    return true
end

--- Answer EVERY outstanding request of one kind, oldest first. The pay path
--- fans out one request per payee and settles only when all have answered, so
--- a helper that answers one of them would test the wrong thing.
local function answerAll(name, ...)
    for _, a in ipairs(askedFor(name)) do
        TriggerEvent(REPLY[name], a.args[1], ...)
    end
end

--- Put one case on the queue and sweep, with a given verdict projection.
local function sweepWith(projection, licenses, claimedAt)
    BR.Awards.sweep()
    answer('br:ddb:awardQueue', { {
        incidentId = INC,
        licenses   = licenses or { ALICE },
        claimedAt  = claimedAt or (os.time() * 1000),
    } }, {})
    answer('br:ddb:incidentVerdict', true, projection)
end

local BANNED  = { found = true, settled = true, payable = true,  word = 'banned', action = 'ban' }
local KICKED  = { found = true, settled = true, payable = true,  word = 'kicked', action = 'kick' }
local NOACTION= { found = true, settled = true, payable = false, word = nil,      action = 'none' }
local NOVERDICT={ found = true, settled = true, payable = false, word = nil,      action = nil }
local PENDING = { found = true, settled = false, payable = false, word = nil,     action = nil }

describe('awards.claim')
do
    reset()
    TriggerEvent('br:report:claim', { incidentId = INC, license = ALICE, matchId = 7 })
    local c = askedFor('br:ddb:awardClaim')[1]
    ok(c ~= nil, 'a claim reaches br_ddb')
    ok(c and c.args[2] == INC and c.args[3] == ALICE,
        'and carries the incident id and the license, in that order',
        c and (tostring(c.args[2]) .. ' / ' .. tostring(c.args[3])))

    reset()
    TriggerEvent('br:report:claim', { incidentId = '', license = ALICE })
    TriggerEvent('br:report:claim', { incidentId = INC, license = '' })
    TriggerEvent('br:report:claim', 'not a table')
    ok(#askedFor('br:ddb:awardClaim') == 0,
        'a claim with no id or no license is dropped rather than queued')

    -- THE CLAIM IS NOT A CURRENCY WRITE and must never look like one. It only
    -- records who is owed; the pay verb is the one that touches a balance.
    reset()
    TriggerEvent('br:report:claim', { incidentId = INC, license = ALICE })
    ok(#askedFor('br:ddb:awardPay') == 0,
        'filing a report pays nobody -- the verdict has not happened yet')
end

describe('awards.sweep.pending')
do
    reset()
    sweepWith(PENDING)
    ok(#askedFor('br:ddb:awardPay') == 0, 'a case still under review pays nobody')
    ok(#askedFor('br:ddb:awardSettle') == 0,
        'and stays on the queue, so the next sweep asks again')
end

describe('awards.sweep.paid')
do
    -- Alice is here, Bob is not. Both reported; both are owed.
    reset()
    online[3] = { 'license:alice' }
    sweepWith(BANNED, { ALICE, BOB })

    local pays = askedFor('br:ddb:awardPay')
    ok(#pays == 2, 'the reporter AND the corroborator are both paid', tostring(#pays))

    local amounts, ids = {}, {}
    for _, p in ipairs(pays) do
        amounts[#amounts + 1] = p.args[4]
        ids[p.args[2]] = p.args[3]
    end
    -- THE AMOUNT IS PINNED, AND THE SENTENCE IS TIED TO IT RATHER THAN PINNED
    -- SEPARATELY. Both used to be the literal 250, which is two copies of one
    -- constant in one test: a retune of the bounty would have failed both lines
    -- and invited whoever moved it to edit the number in two places and call it
    -- done. It has been retuned twice since -- 125 on 2026-08-20, 100 on
    -- 2026-09-02 (#256) -- and each time this was the single line to change.
    -- The pin is the deliberate one, because a silent retune must still fail
    -- here, and everything downstream reads what was actually paid, so a payment
    -- and a sentence that disagree is its own failure rather than a second pin.
    --
    -- ⚠ AND THE COMMENTS AROUND THE CONSTANT ARE STALE AT 250. #256 did not
    -- sweep them, so grants.lua and awards.lua both still argue about "250
    -- Volts". On 2026-09-06 a tutorial card was written from that stale prose and
    -- the constant was briefly raised to match; the owner corrected it ("100 was
    -- right, put it back and fix the card"). This pin is what catches the next
    -- person who reads a comment instead of the constant.
    local AWARD = amounts[1]
    ok(AWARD == 100 and amounts[2] == AWARD, 'each is worth 100 Volts',
        ('%s / %s'):format(tostring(amounts[1]), tostring(amounts[2])))
    ok(ids[ALICE] == INC and ids[BOB] == INC,
        'and each payment is keyed on the incident, which is what makes it idempotent')

    answerAll('br:ddb:awardPay', true, { paid = true, balance = AWARD })

    local told = {}
    for _, s in ipairs(sent) do
        if s.name == BR.Net.NOTIFY then told[#told + 1] = s end
    end
    ok(#told == 1, 'only the player who is actually in the server is told', tostring(#told))
    ok(told[1] and told[1].src == 3, 'and it goes to their server id')
    ok(told[1] and told[1].payload.text:find(('%d Volts'):format(AWARD), 1, true) ~= nil
        and told[1].payload.text:find('has now been banned', 1, true) ~= nil
        and told[1].payload.text:find('Thanks for your help', 1, true) ~= nil,
        'the sentence names the amount that was actually paid, and the verdict, '
        .. 'in past tense',
        told[1] and told[1].payload.text)

    local credited = 0
    for _, a in ipairs(asked) do
        if a.name == 'br:market:credited' then credited = credited + 1 end
    end
    ok(credited == 2,
        "br_core's balance cache is corrected for BOTH, present or not -- the "
        .. 'award is on the account, not the session', tostring(credited))

    ok(#askedFor('br:ddb:awardSettle') == 1,
        'the case leaves the queue once, after every payee has answered')
end

describe('awards.sweep.kick')
do
    reset()
    online[4] = { 'license:alice' }
    sweepWith(KICKED)
    answerAll('br:ddb:awardPay', true, { paid = true })
    local text
    for _, s in ipairs(sent) do
        if s.name == BR.Net.NOTIFY then text = s.payload.text end
    end
    ok(text and text:find('has now been kicked', 1, true) ~= nil,
        'a kick verdict pays, and the sentence says kicked', tostring(text))
end

describe('awards.sweep.twoClients')
do
    --[[
        THE AWARD WAS PAID AND LOGGED AND THE PLAYER SAW NOTHING.

        Owner, 2026-08-18: the incident was resolved with a kick, the console
        printed `[br_stats] reward: 250 Volts to license:b6f5... (kicked)`, and
        "no payout or notifications to player 1".

        THE ACCOUNT WAS CONNECTED FROM TWO CLIENTS, which is how the owner
        playtests. `srcFor` returned the FIRST src carrying the license and
        stopped, so the sentence went to one of the two -- and which one was
        whatever order GetPlayers answered in. Nothing was lost and nothing was
        logged as missing: the Volts landed on the account, the console said so,
        and the screen that was supposed to explain it belonged to the other
        window.

        THE KEYING IS NOT WHAT CHANGED, and it must not be. One license is one
        person, deliberately -- it is what stops report slots being bought by
        reconnecting -- and the CREDIT is still exactly one credit for the
        account. Only the announcement fans out, which is what br_core's own
        `br:market:credited` has always done with the balance that goes with it.
    ]]
    reset()
    -- One account, two windows. A stranger is online too, so "tell everybody"
    -- would be as wrong as "tell one".
    online[3] = { 'license:alice' }
    online[7] = { 'license:alice' }
    online[8] = { 'license:bob' }
    sweepWith(KICKED)
    answerAll('br:ddb:awardPay', true, { paid = true })

    local told = {}
    for _, s in ipairs(sent) do
        if s.name == BR.Net.NOTIFY then told[#told + 1] = s.src end
    end
    table.sort(told)
    ok(#told == 2 and told[1] == 3 and told[2] == 7,
        'both of an account\'s connected clients are told about its reward',
        table.concat(told, ','))

    -- ...AND NOBODY ELSE. The sentence names a reward for reporting somebody;
    -- posting it to a stranger would tell them a case they have nothing to do
    -- with has just been actioned.
    local strangers = 0
    for _, s in ipairs(sent) do
        if s.name == BR.Net.NOTIFY and s.src == 8 then strangers = strangers + 1 end
    end
    ok(strangers == 0, 'and nobody else in the server hears it')

    -- ONE CREDIT, NOT TWO. The fan-out is the announcement only; a second
    -- awardPay would be the license keying quietly coming undone.
    ok(#askedFor('br:ddb:awardPay') == 1,
        'the account is paid once, however many clients it has open',
        tostring(#askedFor('br:ddb:awardPay')))

    -- AND THE LOG SAYS SO. "Paid and told nobody" and "paid and told" were one
    -- line, which is why the owner could not tell from a console which had
    -- happened.
    local said = table.concat(printed, '\n')
    ok(said:find('told 2 client(s)', 1, true) ~= nil,
        'and the log line says how many screens it reached', said)

    -- THE OFFLINE CASE STILL READS AS OFFLINE rather than as "told 0".
    reset()
    sweepWith(KICKED)
    answerAll('br:ddb:awardPay', true, { paid = true })
    local none = table.concat(printed, '\n')
    ok(none:find('offline, credited anyway', 1, true) ~= nil,
        'a reward for somebody who is not here still says so', none)
end

describe('awards.idempotence')
do
    -- THE CASE THE WHOLE DESIGN IS FOR. DynamoDB refuses the second credit and
    -- reports it as success, so a re-swept case must settle without paying and
    -- without telling anybody a second time.
    reset()
    online[5] = { 'license:alice' }
    sweepWith(BANNED)
    answerAll('br:ddb:awardPay', true, { paid = false, alreadyPaid = true })

    local told = 0
    for _, s in ipairs(sent) do
        if s.name == BR.Net.NOTIFY then told = told + 1 end
    end
    ok(told == 0, 'a payment that was already made tells nobody a second time')

    local credited = 0
    for _, a in ipairs(asked) do
        if a.name == 'br:market:credited' then credited = credited + 1 end
    end
    ok(credited == 0, 'and does not move the balance cache either')
    ok(#askedFor('br:ddb:awardSettle') == 1,
        'but it still counts as answered, so the case is settled rather than retried forever')
end

describe('awards.noaction')
do
    reset()
    sweepWith(NOACTION)
    ok(#askedFor('br:ddb:awardPay') == 0,
        "an admin who decided 'no action' pays nobody")
    ok(#askedFor('br:ddb:awardSettle') == 1,
        'and the case leaves the queue -- the decision is final')

    -- THE DISTINCTION THE VERDICT CONTRACT INSISTS ON. A resolved case with NO
    -- verdict is a legacy row or a system auto-resolution; nobody decided
    -- anything, and it is NOT the same as 'none'. It pays nobody either way,
    -- and the log has to be able to tell them apart.
    reset()
    sweepWith(NOVERDICT)
    ok(#askedFor('br:ddb:awardPay') == 0,
        'a resolved case carrying no verdict at all pays nobody')
    ok(#askedFor('br:ddb:awardSettle') == 1, 'and is also final')

    local said = table.concat(printed, '\n')
    ok(said:find('no verdict recorded', 1, true) ~= nil,
        'and it is logged as an absent verdict, never as "no action taken"', said)
end

describe('awards.failure')
do
    -- FAILS CLOSED. An unreadable verdict is not a decision: paying on it would
    -- credit 250 Volts against something nobody has seen.
    reset()
    BR.Awards.sweep()
    answer('br:ddb:awardQueue', { { incidentId = INC, licenses = { ALICE },
        claimedAt = os.time() * 1000 } }, {})
    answer('br:ddb:incidentVerdict', false, { error = 'timed out' })
    ok(#askedFor('br:ddb:awardPay') == 0, 'an unreadable verdict pays nobody')
    ok(#askedFor('br:ddb:awardSettle') == 0, 'and leaves the case on the queue')

    -- A FAILED PAYMENT KEEPS THE CASE. The next sweep re-pays everybody, and
    -- the ones who already landed are refused by the condition.
    reset()
    sweepWith(BANNED, { ALICE, BOB })
    local pays = askedFor('br:ddb:awardPay')
    TriggerEvent('br:ddb:awardPayResult', pays[1].args[1], true, { paid = true })
    TriggerEvent('br:ddb:awardPayResult', pays[2].args[1], false, { error = 'throttled' })
    ok(#askedFor('br:ddb:awardSettle') == 0,
        'one payee failing leaves the whole case on the queue for the next sweep')

    -- br_ddb ABSENT is not an error worth a stack trace; it is a server with no
    -- persistence, which this resource has always been allowed to be.
    reset()
    resourceState.br_ddb = 'missing'
    BR.Awards.sweep()
    ok(#asked == 0, 'no br_ddb means no sweep, and nothing thrown')
    resourceState.br_ddb = 'started'
end

describe('awards.expiry')
do
    -- A CASE NOBODY EVER TRIAGES must not be read on every sweep forever. It is
    -- dropped unpaid: no verdict is not a verdict.
    reset()
    local old = (os.time() * 1000) - (40 * 24 * 60 * 60 * 1000)
    sweepWith(PENDING, { ALICE }, old)
    ok(#askedFor('br:ddb:awardPay') == 0, 'an expired claim pays nobody')
    ok(#askedFor('br:ddb:awardSettle') == 1, 'and is taken off the queue')

    reset()
    local recent = (os.time() * 1000) - (24 * 60 * 60 * 1000)
    sweepWith(PENDING, { ALICE }, recent)
    ok(#askedFor('br:ddb:awardSettle') == 0,
        'a day-old claim is still waiting, not expired')
end

describe('awards.timeout')
do
    -- A br_ddb THAT NEVER ANSWERS must not leak a pending closure per request,
    -- which on this path would hold a payee list for the life of the server.
    reset()
    BR.Awards.sweep()
    fireTimers()
    ok(#askedFor('br:ddb:awardPay') == 0,
        'a queue read that never answers resolves as empty rather than hanging')
end

describe('awards.command')
do
    ok(commands.brawards ~= nil, 'brawards is registered')
    ok(commands.brawards and commands.brawards.restricted == true,
        'and it is restricted -- it names licenses')
end

-- ---------------------------------------------------------------------------
-- brvolts -- THE ONLY WAY TO PUT VOLTS ON A PROFILE WITHOUT PLAYING A MATCH
--
-- ═══ WHY IT IS TESTED HERE AND NOT WITH THE SHOP ═══
--
-- The thing worth checking about this command is not that it prints something,
-- it is WHICH WRITE IT MAKES. A grant that only moved br_core's session cache
-- would show a balance that cannot be SPENT -- br_ddb evaluates the purchase and
-- spend conditions against the real row -- and the symptom would be a shop that
-- refuses money the lobby says you have. This file already stubs br_ddb and
-- already owns "what a match writes", so it is where that question belongs.
--
-- br_core/server/debug.lua LOADS CLEANLY INTO A HARNESS because every one of its
-- BR.* reads is inside a command body; the file's only top-level statement is a
-- local. So the real command is driven here, not a copy of it.
-- ---------------------------------------------------------------------------

--- Everything br_core/server/debug.lua needs in order to run `brvolts`, and
--- nothing it does not. A stub per system, so a command that started reaching
--- for something new would fail loudly rather than quietly reading nil.
local rosterEntries = {}
BR = BR or {}
BR.Server = BR.Server or {}
BR.Server.devMode = true
BR.Roster = { get = function(src) return rosterEntries[src] end }
function GetPlayerName(src) return 'Player' .. tostring(src) end
function RemoveEventHandler() end

do
    local chunk, err = loadfile(ROOT .. 'br_core/server/debug.lua')
    if not chunk then
        realPrint('\27[31mload error\27[0m br_core/server/debug.lua: ' .. tostring(err))
        os.exit(1)
    end
    chunk()
end

--- Run brvolts as the server console (src 0) and hand back the request it made.
local function brvolts(...)
    local before = #askedFor('br:ddb:statsApply')
    commands.brvolts.fn(0, { ... }, '')
    local all = askedFor('br:ddb:statsApply')
    if #all == before then return nil end
    return all[#all]
end

describe('brvolts.registration')
do
    ok(commands.brvolts ~= nil, 'brvolts is registered')
    ok(commands.brvolts and commands.brvolts.restricted == true,
        'and it is restricted, exactly as brgive is')
    ok(commands.brgive ~= nil and commands.brgive.restricted == true,
        'which is the gate it was asked to copy')
end

describe('brvolts.gates')
do
    online[3] = { 'license:aaaaaaaa' }
    rosterEntries[3] = { state = 'WARMUP' }

    -- ═══ THE SERVER CONSOLE ONLY ═══
    --
    -- brgive's dev gate PLUS brprofile's console check, because this one writes
    -- to a row that outlives the match rather than to a match about to end.
    local n0 = #askedFor('br:ddb:statsApply')
    commands.brvolts.fn(7, { '3', '500' }, '')
    ok(#askedFor('br:ddb:statsApply') == n0,
        'a client cannot run it even holding the ACE')

    -- ═══ AND DEV MODE ═══
    BR.Server.devMode = false
    ok(brvolts('3', '500') == nil, 'and it does nothing on a live box')
    BR.Server.devMode = true

    -- ═══ THE USAGE PRINT AND THE ROSTER CHECK, WHICH ARE brgive's ═══
    ok(brvolts() == nil, 'no arguments writes nothing')
    ok(brvolts('3') == nil, 'and neither does an amount-less call')
    ok(brvolts('nobody', '500') == nil, 'nor a target that is not a number')

    -- ═══ brgive's ROSTER CHECK, AND IT HAS TO BE THE THING THAT REFUSES ═══
    --
    -- 9 is CONNECTED and has a license -- so the license lookup further down
    -- would happily find a row to write to. Testing against a src with no
    -- identifiers either would pass with the roster check deleted, which is a
    -- test that asserts nothing.
    online[9] = { 'license:bbbbbbbb' }
    ok(brvolts('9', '500') == nil,
        'nor a connected player with no roster entry -- brgive\'s check, '
            .. 'verbatim')
    online[9] = nil
    ok(brvolts('3', '0') == nil, 'and 0 is refused rather than written as a no-op')

    resourceState.br_ddb = 'missing'
    ok(brvolts('3', '500') == nil, 'with br_ddb absent there is nothing to write to')
    resourceState.br_ddb = 'started'
end

describe('brvolts.write')
do
    online[3] = { 'license:aaaaaaaa' }
    rosterEntries[3] = { state = 'WARMUP' }

    local req = brvolts('3', '5000')
    ok(req ~= nil, 'a good call reaches br_ddb')

    -- ═══ THE PAYOUT'S OWN VERB, NOT A NEW ONE ═══
    --
    -- `statsApply` is the atomic `ADD #bal :balance` that every match payout
    -- goes through. A grant-only br_ddb verb was the alternative and was
    -- rejected: config/market.lua's promise is that the currency is earned, and
    -- a mint in the shipped bundle would end that whether or not the Lua in
    -- front of it was gated.
    ok(req and req.name == 'br:ddb:statsApply',
        'through the same verb a match payout uses', req and req.name)
    ok(req and req.args[2] == 'license:aaaaaaaa',
        'against that player\'s real license', req and tostring(req.args[2]))

    local deltas = req and req.args[3] or {}
    ok(deltas.balance == 5000, 'carrying the amount as a balance delta',
        tostring(deltas.balance))

    -- ═══ AND NOTHING ELSE, WHICH IS THE HALF THAT COULD CORRUPT A ROW ═══
    --
    -- js-src/br_ddb/src/stats.js SETs `level`, `name` and `lastMatchAt` only
    -- when the caller supplies them -- so a delta carrying nothing but a balance
    -- writes nothing but a balance. A command that filled those in would stamp
    -- a match end that never happened and, before the SET clause became
    -- conditional, would have set the player to level 0 with a blank name.
    local extra = {}
    for k in pairs(deltas) do
        if k ~= 'balance' then extra[#extra + 1] = k end
    end
    table.sort(extra)
    ok(#extra == 0,
        'and NOTHING else -- a grant makes no claim about a match',
        table.concat(extra, ', '))

    -- ═══ NEGATIVE AMOUNTS ARE THE POINT, NOT AN OVERSIGHT ═══
    --
    -- Taking a balance down to just under a car's price is the only way to make
    -- `br:ddb:spend`'s condition refuse on demand. It is an unconditional ADD,
    -- so a big enough negative drives the row below zero -- which is a state
    -- worth being able to test with and one the game cannot otherwise reach.
    local down = brvolts('3', '-500')
    ok(down and down.args[3].balance == -500,
        'a negative amount is sent as a negative delta',
        down and tostring(down.args[3].balance))

    ok(brvolts('3', '250.7') and brvolts('3', '250.7').args[3].balance == 250,
        'and a fractional amount is floored -- a balance is an integer')
end

describe('brvolts.cache')
do
    online[3] = { 'license:aaaaaaaa' }
    rosterEntries[3] = { state = 'WARMUP' }

    local seen = nil
    AddEventHandler('br:market:credited', function(lic, xp, volts)
        seen = { lic = lic, xp = xp, volts = volts }
    end)

    local req = brvolts('3', '5000')
    -- The write answers the way br_ddb's JS half would.
    TriggerEvent('br:ddb:statsResult', req.args[1], true, {})

    -- ═══ THE LOBBY MOVES WITHOUT A RECONNECT ═══
    --
    -- br_core's inventory cache is one read taken on connect. The payout tells
    -- it through this event and so does this, for the same reason and by the
    -- same route -- otherwise the granted Volts are spendable and invisible.
    ok(seen ~= nil, 'a successful write updates br_core\'s session cache')
    ok(seen and seen.lic == 'license:aaaaaaaa' and seen.volts == 5000,
        'with the license and the amount that were written',
        seen and ('%s %s'):format(tostring(seen.lic), tostring(seen.volts)))
    ok(seen and seen.xp == 0,
        'and no XP -- this granted Volts, and inventing XP here would put a '
            .. 'level-up animation on a console command',
        seen and tostring(seen.xp))

    -- ═══ A FAILED WRITE MOVES NOTHING ═══
    --
    -- The cache mirrors the row. Crediting it after a write that did not land
    -- would show a balance that cannot be spent -- the exact failure this
    -- command exists to avoid.
    seen = nil
    local bad = brvolts('3', '5000')
    TriggerEvent('br:ddb:statsResult', bad.args[1], false, { error = 'throttled' })
    ok(seen == nil, 'a refused write leaves the cache alone')
end

-- ---------------------------------------------------------------------------
describe('the tutorial reward (#261)')
-- ---------------------------------------------------------------------------
do
    --- Fire BR.Net.TUTORIAL_DONE as player `src`.
    ---
    --- `source` IS A GLOBAL ON THE REAL SERVER -- FiveM sets it around a net
    --- event handler and the handler reads it in its first line. Setting it here
    --- is what makes this the same call the network makes.
    local function finish(src)
        local before = #asked
        source = src
        TriggerEvent(BR.Net.TUTORIAL_DONE)
        source = nil
        for i = before + 1, #asked do
            if asked[i].name == 'br:ddb:awardPay' then return asked[i] end
        end
        return nil
    end

    online = { [7] = { 'license:cccccccc', 'steam:110000100000007' } }
    sent = {}

    local req = finish(7)

    ok(req ~= nil, 'finishing the walkthrough asks br_ddb to pay')
    ok(req and req.args[2] == 'license:cccccccc',
        'for the license derived on the server, not one the client sent',
        req and tostring(req.args[2]))
    ok(req and req.args[3] == 'tutorial',
        'under a fixed key, which is what makes it once per account forever',
        req and tostring(req.args[3]))
    ok(req and req.args[4] == BR.Config.Market.tutorialReward
            and req.args[4] == 500,
        'for the configured amount, which is 500',
        req and tostring(req.args[4]))

    -- ═══ THE REWARD IS NOT A SECOND CURRENCY ═══
    local seen = nil
    AddEventHandler('br:market:credited', function(lic, xp, volts)
        seen = { lic = lic, xp = xp, volts = volts }
    end)

    TriggerEvent('br:ddb:awardPayResult', req.args[1], true,
                 { paid = true, balance = 1500 })

    ok(seen ~= nil and seen.volts == 500,
        "a paid reward moves br_core's session cache",
        seen and tostring(seen.volts))
    ok(seen ~= nil and seen.xp == 0,
        'and pays no XP -- XP is what matches are for')

    local told = nil
    for _, m in ipairs(sent) do
        if m.name == BR.Net.NOTIFY and m.src == 7 then told = m end
    end
    ok(told ~= nil, 'and the player is told')
    ok(told and told.payload and told.payload.text:find('500', 1, true) ~= nil,
        'with the amount in the sentence',
        told and told.payload and told.payload.text)

    -- THE AMOUNT IS MARKED FOR THE CURRENCY'S COLOUR (owner, 2026-09-07: "the
    -- volts text and quantity are in our signature color"). The page paints
    -- anything between tildes; the marks travelling is what this pins.
    ok(told and told.payload and told.payload.text:find('~500 ', 1, true) ~= nil,
        'and wrapped so the page can colour it',
        told and told.payload and told.payload.text)

    -- AND FINISHING SPENDS THE OFFER, so the lobby stops showing the toggle.
    local closed = false
    for _, a in ipairs(asked) do
        if a.name == 'br:market:tutorialDone' then closed = true end
    end
    ok(closed, 'a paid finish closes the offer on the profile row')

    -- ═══ THE SECOND CLAIM IS REFUSED BY THE DATABASE, AND SAYS NOTHING ═══
    --
    -- The Help page can re-run the walkthrough, so a second claim is an ordinary
    -- event rather than an attack. Paying nothing is right; TELLING them they
    -- were gifted 500 Volts they did not receive is the bug this pins.
    seen, sent = nil, {}
    local again = finish(7)
    ok(again ~= nil, 'a second finish still asks -- the lock is the database')
    TriggerEvent('br:ddb:awardPayResult', again.args[1], true,
                 { paid = false, alreadyPaid = true })
    ok(seen == nil, 'an already-paid claim moves no cache')

    -- ═══ IT SAYS SOMETHING, AND WHAT IT MUST NOT SAY IS THE POINT ═══
    --
    -- Owner, 2026-09-07: "after the in-game tutorial is done for a second time,
    -- I'd like a toast that informs the player that volts were not awarded
    -- because they'd already completed the tutorial before." Silence read as the
    -- reward failing; the hazard in fixing it is a sentence that thanks them for
    -- a payment the database refused.
    local second
    for _, m in ipairs(sent) do
        if m.name == BR.Net.NOTIFY and m.src == 7 then second = m end
    end
    ok(second ~= nil, 'a second finish tells them why nothing arrived')
    ok(second and second.payload
        and second.payload.text:find('completed the tutorial before', 1, true) ~= nil,
        'naming the reason',
        second and second.payload and second.payload.text)
    ok(second and second.payload
        and second.payload.text:find('gifted', 1, true) == nil,
        'and never claiming they were paid')

    -- ═══ A FAILED WRITE PAYS NOBODY AND PROMISES NOBODY ═══
    seen, sent = nil, {}
    local bad = finish(7)
    TriggerEvent('br:ddb:awardPayResult', bad.args[1], false, { error = 'throttled' })
    ok(seen == nil and #sent == 0, 'a failed write credits nothing and says nothing')

    -- ═══ NO LICENSE, NO PAYMENT ═══
    --
    -- Inventing a key here would credit the wrong human later, which is the same
    -- reason BR.Roster.licenseOf leaves a licenseless connection nil.
    online = { [9] = { 'steam:110000100000009' } }
    sent = {}
    ok(finish(9) == nil, 'a connection with no license is not paid')
end

describe('brloot.matchArg')
do
    -- ═══ THE ONE PLACE A MATCH ID TRAVELS THE OTHER WAY (#291) ═══
    --
    -- Every line this project prints names a match in seven hex characters, so
    -- `brloot a3f1` is somebody copying what the log just said. `tonumber` on
    -- that answers nil for the fifteen sixteenths of ids that contain a letter,
    -- and -- worse -- answers about a DIFFERENT match for the ones that do not:
    -- typing the `0000120` it just read would have selected match 120.
    --
    -- SEVEN SINCE 2026-09-12, five before it. The widening is a rendering change
    -- and the PARSE deliberately did not move with it -- see the two assertions
    -- at the end of this block, which pin both spellings landing on one match.
    local seen = {}
    local matches = {
        { id = 0x000a3, state = 'PLAYING' },
        { id = 0x00120, state = 'PLAYING' },   -- decimal 288; reads as 120
    }
    BR.Server.eachMatch = function(fn)
        for _, m in ipairs(matches) do fn(m) end
    end

    local function brloot(arg)
        seen = {}
        local mark = #printed
        commands.brloot.fn(0, { arg }, '')
        for i = mark + 1, #printed do
            local tag = printed[i]:match('match (%x+): no loot')
            if tag then seen[#seen + 1] = tag end
        end
        return table.concat(seen, ',')
    end

    ok(brloot(nil) == '00000a3,0000120',
        'with no argument brloot reports every match, named in hex',
        brloot(nil))

    ok(brloot('00000a3') == '00000a3',
        'and the hex the console printed selects the match it named',
        brloot('00000a3'))

    -- THE TRAP THE OLD `tonumber` WALKED INTO. `0000120` is 288, and 120 is a
    -- different match entirely -- so a decimal parse would answer about neither
    -- the one asked for nor obviously the wrong one.
    ok(brloot('0000120') == '0000120',
        'an id made only of digits still means the hex one, not the decimal '
            .. 'number that shares its spelling', brloot('0000120'))

    ok(brloot('a3') == '00000a3',
        'and a tag typed without its padding still lands')

    -- ═══ AND THE FIVE-CHARACTER SPELLING THE CONSOLE PRINTED FOR MONTHS ═══
    --
    -- THE SAME PROPERTY THE RINGMASTER URLS DEPEND ON, asserted here because
    -- this is the one place the parse is driven through a real command rather
    -- than called directly. Every log line, bookmark and Discord message written
    -- before the widening carries a five-character tag; BR.MatchFromTag has
    -- never checked a length, so `000a3` and `00000a3` are one number and land
    -- on one match. A parser "tightened" to seven would break all of it.
    ok(brloot('000a3') == '00000a3',
        'a tag printed before the widening still selects the match it named, '
            .. 'now spelled seven wide', brloot('000a3'))
    ok(brloot('000a3') == brloot('00000a3'),
        'and the old spelling and the new one are the same match')

    -- UNCHANGED, AND WORTH PINNING RATHER THAN FIXING. An argument that is not
    -- a match id has always fallen through to "every match", because `tonumber`
    -- returned nil for it and nil means "no filter". Hex parsing keeps exactly
    -- that shape; this assertion is here so the day somebody decides a typo
    -- should be refused instead, they do it on purpose.
    ok(brloot('zzz') == '00000a3,0000120',
        'and something that is not a match id falls through to every match, as '
            .. 'it always has', brloot('zzz'))
end

print = realPrint

io.write(('\n\27[32m%d passed\27[0m'):format(pass))
if fail > 0 then
    io.write(('  \27[31m%d failed\27[0m\n'):format(fail))
    os.exit(1)
end
io.write('\n')
