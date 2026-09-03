-- Static gate: a xN on a notice means "again, while you were still looking at
-- it" -- on screen and in the pause menu alike.
--
-- ═══ THE REPORT ═══
--
-- Owner, 2026-09-02:
--
--   "the 'x2' and 'x3' and 'x4' toast flags should only appear if the same
--    notification arrives before the last one disappears - currently in the
--    pause menu when I look at previous notifications, if I have the same
--    content toast show up 20 minutes apart it shows 'x2' which is unintended
--    behavior."
--
-- The LIVE stack could never have had this bug and still cannot: it coalesces
-- against `notices`, which holds only the rows whose removal timer has not
-- fired, so a repeat that arrives after the row has gone is a new row by
-- construction. THE HISTORY had it, because it coalesced against `noticeLog` --
-- sixty entries reaching back to the start of the match -- on the SENTENCE
-- ALONE. Two unrelated events twenty minutes apart read as one event that
-- happened twice, which is a record that looks trustworthy and is not.
--
-- So the log's match is (sentence, still on screen), and the second half of it
-- is `goneAt`: the instant that line's toast left, written from the SAME
-- lifetime the stack armed its removal timer with.
--
-- ═══ WHAT IS AIMED AT, AND WHY EACH WOULD NOT LOOK LIKE A MISTAKE ═══
--
--   THE WINDOW GOING BACK TO "EVER". `log.findIndex(e => e.text === t.text)` is
--   what this was, it is the obvious way to write it, and it produces a history
--   that is right about every burst and wrong about every repeat -- which is to
--   say right on the screen where anybody is looking and wrong on the screen
--   nobody checks until twenty minutes later. There is no error, no warning,
--   and the wrong version renders identically for the first four seconds.
--
--   A SECOND LIFETIME. The window has to be the notice's OWN duration, and
--   there are three of them: a payload `ms`, a countdown's deadline, and a
--   sticky's ceiling. A `4000` written next to the log -- the default, the
--   number in the comments, the one that is right for most notices -- agrees
--   with the stack for every notice that took the default and disagrees for
--   every one that did not. Measured: with the window hardcoded to TOAST_MS an
--   8-second notice repeating at 5 seconds reads x2 on screen and TWO SEPARATE
--   LINES in the history, from one event. So lifetimeOf is one function with
--   two callers, and this gate counts the constants to keep it that way.
--
--   THE IDENTITY WIDENING. The sentence is what a repeat is matched on, and it
--   has to stay that: since notices carry names as structured parts the flat
--   `text` already separates "Jim is down!" from "Bob is down!" (da0ec36), and
--   a match on tone, or on nothing, would fold those back together.
--
--   THE HISTORY LOSING THE OLD LINE. Two events are two rows WITH TWO TIMES --
--   that is the whole of the report, and the pause menu is where it was seen.
--   A create path that spliced the older row out, or a row that stopped
--   carrying its own `at`, would leave one line again by another route.
--
--   THE BUNDLE GOING STALE. Every assertion above passes on a repository whose
--   ui-src was edited and never rebuilt, and the game would keep counting up
--   forever. `goneAt` is a payload field name, which is the one thing in a TS
--   file that survives minification unchanged.
--
-- The behaviour itself is not assertable here -- the store is TypeScript and no
-- harness in this repo loads it. It was driven through the real store in the
-- browser dev harness on 2026-09-02, both ways round, and both mutations above
-- were measured red.
--
-- Run standalone:  lua tools/check_notice_repeat.lua

local ROOT = 'resources/[fivem-royale]/'
local UI   = 'ui-src/src/'

local failures = 0

local function fail(msg, why)
    failures = failures + 1
    io.write('FAIL  ', msg, '\n')
    if why then io.write('      ', why, '\n') end
end

--- TypeScript with its comments removed. Same reason as every sibling gate:
--- the file argues in prose about the thing being searched for -- the header of
--- logNotice quotes the owner's report and names every symbol below -- so a
--- raw-source search matches the explanation rather than the code.
local function codeOfTs(src)
    src = src:gsub('/%*.-%*/', ' ')
    src = src:gsub('//[^\n]*', '')
    return src
end

local function readRaw(path)
    local fh = io.open(path, 'r')
    if not fh then
        fail(path .. ' is missing')
        return nil
    end
    local s = fh:read('a')
    fh:close()
    return s
end

local function read(path, strip)
    local s = readRaw(path)
    return s and strip(s) or nil
end

--- How many times `needle` appears in `hay`, as a plain substring.
local function countOf(hay, needle)
    local n, at = 0, 1
    while true do
        local a, b = hay:find(needle, at, true)
        if not a then return n end
        n, at = n + 1, b + 1
    end
end

-- ------------------------------------------------------------- the store ---

local store = read(UI .. 'store/index.ts', codeOfTs)
if store then
    -- ONE LIFETIME, TWO CALLERS. Everything else here rests on this: if the
    -- stack and the log measure "still on screen" with two different sums, one
    -- of them is wrong for every notice that did not take the default.
    if not store:find('const lifetimeOf%s*=') then
        fail('the store no longer derives a notice lifetime in one place',
             'lifetimeOf is what the stack arms its removal timer with AND '
             .. 'what the history measures its coalescing window with. Two '
             .. 'copies of that arithmetic is how a xN starts meaning one '
             .. 'thing on screen and another in the pause menu')
    end

    -- THE CONSTANT COUNT IS THE REAL ASSERTION, and it is what a written-out
    -- window fails. Each of these may appear exactly twice in code: its own
    -- declaration, and its single use inside lifetimeOf. A third occurrence is
    -- somebody computing a duration somewhere else.
    for _, k in ipairs({ 'STICKY_MAX_MS', 'COUNTDOWN_TAIL_MS', 'TOAST_MS' }) do
        local n = countOf(store, k)
        if n ~= 2 then
            fail(('%s is used %d time(s) in the store, not 2'):format(k, n),
                 'a notice\'s lifetime is declared once and computed once, in '
                 .. 'lifetimeOf. A second sum built out of these constants is '
                 .. 'a window that agrees with the row on screen only for the '
                 .. 'notices that took the default')
        end
    end

    local logFn = store:match('const logNotice =.-\n  }')
    if not logFn then
        fail('logNotice is no longer a recognisable function',
             'this gate reads the coalescing rule out of it')
    else
        if not logFn:find('lifetimeOf%(') then
            fail('the notice history does not measure the toast\'s own lifetime',
                 'the window a repeat has to arrive inside is the previous '
                 .. 'row\'s ACTUAL time on screen -- a payload ms, a '
                 .. 'countdown\'s deadline or a sticky\'s ceiling -- and not a '
                 .. 'number written beside it')
        end

        -- BOTH BRANCHES STAMP A FRESH WINDOW. There are two ways a line gets
        -- written -- folded into an existing one, or created -- and each has
        -- to say when the toast it now stands for will leave. A create path
        -- that forgot would leave the field undefined, `now < undefined` is
        -- false, and that line could never be counted up again: the flag would
        -- stop working rather than overcount, which is the quieter half of the
        -- same bug.
        if countOf(logFn, 'goneAt:') ~= 2 then
            fail('logNotice does not stamp both of its branches with a window',
                 'a repeat folds into a line and a new event starts one, and '
                 .. 'either way the row now stands for a toast that is on '
                 .. 'screen until some particular instant')
        end

        -- ...AND ONE OF THEM IS READ. A `goneAt` that is only ever WRITTEN
        -- satisfies the count above while every repeat still coalesces -- the
        -- field would be dead weight and the reported bug would be back
        -- untouched. So the entry being folded INTO has to be tested.
        if not logFn:find('%.goneAt') then
            fail('the notice history folds a repeat into a line without asking '
                 .. 'whether that line is still on screen',
                 'a xN means "again, while you were still looking at it" '
                 .. '(owner, 2026-09-02). If nothing compares against the '
                 .. 'previous line\'s goneAt, the history is matching on the '
                 .. 'sentence alone and two events twenty minutes apart read '
                 .. 'as one event that happened twice')
        end

        -- THE IDENTITY IS STILL THE SENTENCE. `text` is the flattened notice,
        -- so it already separates two players' names; time is what separates
        -- two of the same event.
        if not logFn:find('e%.text === t%.text') then
            fail('the history no longer matches a keyless repeat on its sentence',
                 'the flat `text` is what tells "Jim is down!" from "Bob is '
                 .. 'down!" (da0ec36). A wider match folds two players into '
                 .. 'one line; a narrower one stops coalescing bursts at all')
        end

        -- TWO EVENTS ARE TWO ROWS. The merge branch splices the old line out
        -- and re-heads it; the create branch must not, or the older event
        -- loses its place and its time and the history is back to one line.
        if countOf(logFn, 'splice(') ~= 1 then
            fail('logNotice no longer has exactly one splice',
                 'the merge branch lifts the line it is updating and puts it '
                 .. 'back on top. A second splice is the create path removing '
                 .. 'the older event -- which is the same lost line by another '
                 .. 'route')
        end
    end

    local showFn = store:match('const showNotice =.-\n  }')
    if not showFn then
        fail('showNotice is no longer a recognisable function',
             'this gate reads its lifetime out of it')
    elseif not showFn:find('lifetimeOf%(') then
        fail('the live stack does not arm its removal timer from lifetimeOf',
             'the log measures its window with that function. A stack that '
             .. 'computes its own is the two surfaces disagreeing about when a '
             .. 'notice disappeared, which is the only fact either of them '
             .. 'coalesces on')
    end

    -- THE ROW CARRIES IT. Written out field by field, so this is where it gets
    -- dropped.
    if not store:find('goneAt: number') then
        fail('the notice history row does not declare goneAt',
             'the log row is built field by field and typed by hand; a window '
             .. 'the row cannot store is a window nothing can check')
    end
end

-- --------------------------------------------------------- the pause menu ---
--
-- WHERE HE SAW IT. Two events have to read as two lines with two times, so the
-- row keeps drawing its own `at` and keeps drawing the count only above 1.

local log = read(UI .. 'screens/NoticeLog.tsx', codeOfTs)
if log then
    if not log:find('n%.at') then
        fail('the pause menu\'s history no longer stamps each line with its '
             .. 'own time',
             '"20 minutes apart" is the whole of the report. Two rows that '
             .. 'cannot say when they happened are no better than one row '
             .. 'reading x2')
    end
    if not log:find('n%.count > 1') then
        fail('the pause menu\'s history no longer draws the multiplier from a '
             .. 'count above one',
             'a x1 on every line is the same misreading in the other '
             .. 'direction -- and the live row and this one have to agree')
    end
end

-- ------------------------------------------------------------- the bundle ---
--
-- ui-src is a SOURCE tree; br_ui/ui/assets/index.js is what the game loads and
-- it is committed. Every assertion above passes on a repository whose bundle
-- was never rebuilt, and the shipped page would keep counting up forever.
--
-- A PAYLOAD FIELD NAME survives minification unchanged, which is what makes it
-- usable as the freshness marker. `goneAt` is new with this rule, so it cannot
-- be satisfied by a bundle built before it.

do
    local js = readRaw(ROOT .. 'br_ui/ui/assets/index.js')
    if js and not js:find('goneAt', 1, true) then
        fail('the built bundle does not know when a notice leaves the screen',
             'the bundle is stale. Run: cd ui-src && npm run build')
    end
end

if failures > 0 then
    io.write(('\ncheck_notice_repeat: %d problem(s)\n'):format(failures))
    os.exit(1)
end

io.write('ok   a repeated notice counts up only while the one before it is\n'
    .. '     still on screen -- measured against that notice\'s own lifetime,\n'
    .. '     by the live stack and the pause menu\'s history alike -- and a\n'
    .. '     repeat that arrives after it has gone takes a line of its own,\n'
    .. '     with its own time\n')
