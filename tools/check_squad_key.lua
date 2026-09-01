-- Static gate: the squad panel says whether a mate's revive key is held, and
-- says it without a word.
--
-- ═══ THE REQUEST ═══
--
-- Owner, 2026-08-30, after the fifth playtest of the revive key:
--
--   "I also saw nothing in the squad panel indicating that a revive key had
--    been retrieved."
--
--   "I'm unable to interact with their revive key now and I have no way to know
--    I still have their key."
--
-- Those are one report. A key is an ENTITLEMENT HELD BY A SQUAD rather than an
-- object anybody carries (br_lib/config/revivekey.lua: "NO SLOT. NO CARRIER."),
-- so there is no inventory row to look at; and once the three-minute pickup
-- expires there is nothing in the world either. The squad panel is the only
-- surface that lists the people a key is ABOUT, so it is where the fact has to
-- live -- and it was drawing an eliminated mate the squad could bring back
-- identically to one nobody could reach.
--
-- The wire underneath is asserted behaviourally where it is built:
-- tools/test_revivekey.lua drives the real ledger and the real beacon. This
-- file is for the properties no suite in this repo can execute -- client
-- state.lua is loaded by no harness, and TSX by none at all.
--
-- ═══ WHAT IS AIMED AT, AND WHY EACH ONE WOULD NOT LOOK LIKE A MISTAKE ═══
--
--   THE FACT GOING PUBLIC. The obvious home for a new per-player fact is
--   roster.lua's PUBLIC_FIELDS, and it is the wrong one: that list is broadcast
--   to every client in the match. "That squad can still get him back" is the
--   single most useful thing to hand the squad that just killed him -- it is
--   the difference between pushing a body and leaving it -- and nothing would
--   break, so nobody would notice. The beacon in server/party.lua is already
--   squad-only.
--
--   THE THIRD READING COLLAPSING INTO THE SECOND. The field is a TRI-STATE:
--   absent (no key), false (a key exists and is not ours), true (held). Written
--   as `b and b.key and (b.key.held == true) or nil`, Lua folds false into nil
--   and the panel goes blind again for the mate whose key is lying on the
--   ground -- which is half of the report above. It reads as idiomatic Lua and
--   this project has shipped that trap ten times.
--
--   ...AND THE SAME COLLAPSE IN JAVASCRIPT. `{m.reviveKey && ...}` draws
--   nothing for `false`, which is a real state here and not an absence.
--
--   THE MARK GROWING A CAPTION. "Never add unsolicited UI text" is a standing
--   instruction, and this feature's copy is fixed at the six lines the owner
--   listed on 2026-08-30 -- all of them prompts and notices, none of them a
--   panel label. A seventh added for a HUD glyph is exactly the drift the
--   single copy table exists to prevent.
--
--   THE MARK LEARNING TO SCALE. The squad plate is a fixed-size plate, which
--   index.css names as the one place the text-size preference must not reach.
--   The voice mark next door scales and needed `align-self: center` plus an
--   `items-baseline` row to stop it dragging every plate's height with it; this
--   mark sits in the OTHER flex group on the same row and walks into the same
--   bug, at 0.6px per plate -- invisible in review.
--
--   THE FADE COMING BACK. A dead plate is drawn at 0.34 because "dead is
--   finished and still". A mate whose key the squad holds is not finished, and
--   a mark painted at a third of its ink on the row that matters most is a
--   slower way of showing the owner nothing. The lift is the assertion most
--   likely to be "tidied" back to a constant.
--
--   THE BUNDLE GOING STALE. Every assertion above passes on a repository whose
--   ui-src was edited and never rebuilt, and the game would show the old panel.
--   No other gate in this repo catches that for this file.
--
-- Run standalone:  lua tools/check_squad_key.lua

local ROOT = 'resources/[fivem-royale]/'
local UI   = 'ui-src/src/'

local failures = 0

local function fail(msg, why)
    failures = failures + 1
    io.write('FAIL  ', msg, '\n')
    if why then io.write('      ', why, '\n') end
end

--- Lua source with its comments removed. Same reason as the sibling gates:
--- every file below argues in prose about the thing being searched for, so a
--- raw-source search matches the explanation rather than the code.
local function codeOf(src)
    src = src:gsub('%-%-%[%[.-%]%]', ' ')
    src = src:gsub('%-%-[^\n]*', '')
    return src
end

--- TypeScript/TSX with its comments removed. It bites hardest here:
--- SquadPanel.tsx's own notes quote `{m.reviveKey &&`, `0.34` and `tscale`,
--- all of which are searched for below.
local function codeOfTs(src)
    src = src:gsub('/%*.-%*/', ' ')
    src = src:gsub('//[^\n]*', '')
    return src
end

local function read(path, strip)
    local fh = io.open(path, 'r')
    if not fh then
        fail(path .. ' is missing')
        return nil
    end
    local s = fh:read('a')
    fh:close()
    return strip(s)
end

-- ------------------------------------------- it is squad-only, not public ---

local roster = read(ROOT .. 'br_core/server/roster.lua', codeOf)
if roster then
    local public = roster:match('local PUBLIC_FIELDS = {.-}')
    if not public then
        fail('server/roster.lua no longer defines PUBLIC_FIELDS')
    elseif public:lower():find('revivekey', 1, true) then
        fail('PUBLIC_FIELDS has grown the revive key',
             'that list goes to every client in the match, and whether a squad '
             .. 'can still get somebody back is what the squad that killed '
             .. 'them would use. The beacon in server/party.lua is the channel '
             .. 'already limited to their own squad')
    end
end

-- ------------------------------------------------------- it is on the beacon ---

local party = read(ROOT .. 'br_core/server/party.lua', codeOf)
if party then
    if not party:find('key = keyRow%(') then
        fail('the squad beacon no longer carries the key row',
             'this is the only channel it travels on; without it the panel and '
             .. 'the world plates both have nothing to draw')
    end
    -- THE ONE BIT THE PANEL FOLDS IN. `held` is what separates "go and get it"
    -- from "we have it", and it is the whole of what crosses to the interface.
    if not party:find('held = k%.held == true') then
        fail('the beacon no longer publishes `held` as an explicit boolean',
             'the panel draws two different marks off this one bit, and 0 is '
             .. 'truthy in Lua -- a truth test here is how they become one')
    end
    -- AND THE PICKUP'S DEADLINE. Owner, 2026-08-31: "If there is a timer to
    -- pickup their key, display it in the squad panel." The panel cannot derive
    -- it -- `mintedAt` is on the beacon but BR.Config.ReviveKey.expiryMs is not,
    -- and shipping the duration so the page could add the two would put the
    -- three minutes in a second place.
    if not party:find('expiresAt = k%.expiresAt') then
        fail('the beacon no longer carries the pickup deadline',
             'the squad panel counts it down, and the only other way to get it '
             .. 'there is to send the interface a duration to add to a mint '
             .. 'time -- which is the same number in two places')
    end
end

-- ------------------------------------------------------- the client fold ---

local state = read(ROOT .. 'br_core/client/state.lua', codeOf)
if state then
    local push = state:match('function pushSquadOrParty.-\nend')
    if not push then
        fail('client/state.lua no longer defines pushSquadOrParty',
             'this gate reads the squad payload out of it')
    else
        if not push:find('reviveKey = ') then
            fail('the squad payload no longer carries the revive key',
                 'the beacon has it and the panel reads it; this fold is the '
                 .. 'only thing between them')
        end
        -- THE TRI-STATE MUST SURVIVE THE FOLD. An `and`/`or` chain returns nil
        -- for the false case, so the mate whose key is still on the ground
        -- goes back to being drawn as unrecoverable -- half the report.
        if push:find('reviveKey = [^,\n]*%f[%w]and%f[%W]')
           or push:find('reviveKey = [^,\n]*%f[%w]or%f[%W]') then
            fail('the revive key is folded in with an and/or chain',
                 '`x and y or nil` collapses FALSE into nil, and false is a '
                 .. 'real reading here: a key exists and the squad has not '
                 .. 'fetched it. Compute it with an `if` above the table')
        end
        if not push:find('b%.key%.held == true') then
            fail('the fold no longer reads the beacon\'s `held` explicitly',
                 'absent, false and true are three different renderings; a '
                 .. 'truthiness test turns them into two')
        end
        -- NO COORDINATES. The beacon's key row also carries x/y/z and a mint
        -- time, and those belong to client/revivekey.lua's world plates. On
        -- this payload they would be a position the interface could draw.
        -- THE DEADLINE FOLDS IN TOO, AND ONLY WHILE THERE IS A PICKUP.
        --
        -- Owner, 2026-08-31: "If there is a timer to pickup their key, display
        -- it in the squad panel."
        --
        -- GATED ON THE BEACON'S `live`, not on the number being present. The
        -- key row keeps travelling after the three minutes are up -- that is
        -- how the client knows the purchase is the only door left -- so a
        -- deadline forwarded unconditionally leaves every expired key showing a
        -- countdown pinned at 0s for the rest of the match. It is the same
        -- class of mistake as collapsing the tri-state above, and it looks like
        -- simplification.
        if not push:find('reviveKeyEndsAt = ') then
            fail('the squad payload no longer carries the pickup deadline',
                 'the beacon has it and the panel counts it down; this fold is '
                 .. 'the only thing between them')
        end
        if not push:find('b%.key%.live == true') then
            fail('the pickup deadline is folded in without asking `live`',
                 'the key row outlives its pickup on purpose -- the key is '
                 .. 'still buyable -- so an ungated deadline draws a timer '
                 .. 'stuck at zero on every expired key for the rest of the '
                 .. 'match')
        end
        if push:find('key%.x') or push:find('key%.y') or push:find('key%.z') then
            fail('the squad payload has grown the key\'s world position',
                 'the panel needs one bit. A coordinate here is a coordinate '
                 .. 'the interface can draw, which is a wider feature than the '
                 .. 'one that was asked for -- and the squad beacon\'s '
                 .. 'positions are its single deliberate privacy exception')
        end
    end
end

-- --------------------------------------------------------------- the panel ---

local panel = read(UI .. 'hud/SquadPanel.tsx', codeOfTs)
if panel then
    if not panel:find('KeyMark', 1, true) then
        fail('the squad panel no longer draws a revive key mark')
    end

    -- BOTH READINGS, EXPLICITLY. `false` means "a key exists and it is not
    -- ours"; absent means "there is no key". They draw differently and only
    -- an explicit comparison can tell them apart.
    if panel:find('{m%.reviveKey &&') then
        fail('the revive key guard is a truthiness test',
             'false is a real state on this field -- a key lying on the ground '
             .. 'that nobody has fetched -- and `&&` draws nothing for it')
    end
    if not panel:find('m%.reviveKey === true') then
        fail('the panel no longer tests for a HELD key',
             'that is the state the owner reported blind: "no way to know I '
             .. 'still have their key"')
    end
    if not panel:find('m%.reviveKey === false') then
        fail('the panel no longer tests for an UNFETCHED key',
             'the other half of the same report: a key exists to be collected '
             .. 'and nothing on screen said so')
    end

    -- IT SITS WITH THE STAMP, which is the only part of a dead plate still
    -- drawn -- the bars and the bleed clock both go. Asserted by POSITION
    -- rather than by carving the group out with a pattern: the group holds
    -- nested spans, so any non-greedy match for its closing tag stops early
    -- (the sibling gate learned this on its first run).
    local posGroup = panel:find('%(dead %|%| downed%) &&')
    local posMark  = panel:find('<KeyMark')
    local posStamp = panel:find("{dead %? 'OUT' : 'DOWN'}")
    if not (posGroup and posStamp) then
        fail('the stamp row is no longer recognisable',
             'this gate locates the key mark relative to the DOWN/OUT stamp')
    elseif not posMark then
        fail('the panel no longer renders <KeyMark/>')
    elseif not (posGroup < posMark and posMark < posStamp) then
        fail('the key mark is not beside the DOWN/OUT stamp any more',
             ('group@%s mark@%s stamp@%s -- it belongs in the one group a dead '
              .. 'plate still draws, and BEFORE the stamp so DOWN and OUT keep '
              .. 'the right edge every row shares')
             :format(tostring(posGroup), tostring(posMark), tostring(posStamp)))
    end

    -- THE PICKUP CLOCK, BESIDE THE MARK IT BELONGS TO.
    --
    -- IT IS THE SAME COMPONENT THE BLEED DEADLINE USES, which is the assertion
    -- rather than an implementation detail: one clock discipline (an interval,
    -- the server deadline against Date.now() + clockOffset, written straight to
    -- the node) and ONE FORMAT. A second countdown component is how one panel
    -- ends up with `2:14` on one row and `134s` on the next, and the bleed clock
    -- already runs from 120s so neither is obviously the odd one out.
    if not panel:find('m%.reviveKeyEndsAt') then
        fail('the squad panel no longer draws the pickup countdown',
             'owner, 2026-08-31: "If there is a timer to pickup their key, '
             .. 'display it in the squad panel"')
    end
    do
        local clocks = select(2, panel:gsub('function%s+RowClock%s*%(', ''))
            + select(2, panel:gsub('function%s+BleedClock%s*%(', ''))
        if clocks ~= 1 then
            fail(('the panel defines %d countdown components, not 1'):format(clocks),
                 'the bleed deadline and the pickup deadline are two numbers on '
                 .. 'one row. Two components is two answers to "what does a '
                 .. 'countdown look like", and the disagreement shows up only '
                 .. 'once both are on screen at once')
        end
    end

    local markBody = panel:match('function KeyMark.-\n}')
    if not markBody then
        fail('KeyMark is no longer a recognisable component')
    else
        -- A DRAWN GLYPH, NOT A WORD. Asserted as "the mark's content is a
        -- path" rather than by searching for label text -- the component is
        -- CALLED KeyMark, so a search for the word matches its own name and
        -- fails on the correct file.
        if not markBody:find('<path d={KEY_PATH}', 1, true) then
            fail('the key mark no longer draws the key path',
                 'this feature\'s copy is fixed at the six lines in '
                 .. 'br_lib/config/revivekey.lua, none of which is a panel '
                 .. 'label. The mark is a picture')
        end
        if not markBody:find('currentColor', 1, true) then
            fail('the key glyph no longer inherits its colour',
                 '`currentColor` is what lets one path follow both tokens '
                 .. 'through the colourblind remaps -- the same reason '
                 .. 'VoiceMark is inline SVG rather than an image')
        end
        -- TWO COLOURS, ONE OBJECT: VoiceMark's vocabulary. The accent is the
        -- one the squad can act on; the dim shade is the one merely reported.
        if not markBody:find('color%-royale%-accent')
           or not markBody:find('color%-text%-dim') then
            fail('the key mark no longer distinguishes held from unfetched',
                 'the owner hit both states blind. One object in two shades is '
                 .. 'the pair VoiceMark already established on this row')
        end
        -- IT MUST NOT SCALE. See the header.
        if markBody:find('tscale', 1, true) or markBody:find('"ts ', 1, true)
           or markBody:find(' ts ', 1, true) then
            fail('the key mark scales with the text-size preference',
                 'the squad plate is a fixed-size plate. The voice mark next '
                 .. 'door needed align-self:center to stop exactly this from '
                 .. 'changing every plate\'s height with the setting')
        end
        if not markBody:find("alignSelf: 'center'", 1, true) then
            fail('the key mark participates in baseline alignment',
                 'the stamp group is `items-baseline`; an item that joins it '
                 .. 'and is taller than the stamp moves the whole row\'s '
                 .. 'baseline, and the plate\'s height with it')
        end
    end

    -- A MATE WHO CAN COME BACK IS NOT DRAWN AS FINISHED. The dead plate's
    -- 0.34 is right for somebody nobody can reach and wrong for somebody whose
    -- key is held -- it fades the new mark down with everything else, on the
    -- one row it was added for.
    if panel:find('opacity: dead %? 0%.34 : 1') then
        fail('the dead plate is faded to 0.34 whatever the key says',
             'that fade means "finished and still". A mate the squad is '
             .. 'holding a key for is neither, and painting his mark at a '
             .. 'third of its ink is a slower way of showing nothing')
    end
    if not panel:find('opacity: dead %?') then
        fail('the dead plate no longer fades at all',
             'downed and dead must never look alike, and the fade is how this '
             .. 'panel has always said which')
    end
end

-- -------------------------------------------------------- no tenth string ---
--
-- The copy table is the whole of what this feature is allowed to say. The owner
-- listed six lines on 2026-08-30 and rewrote the collection half into nine on
-- 2026-08-31. A HUD caption added "for clarity" is the likeliest tenth, and it
-- would arrive here rather than in the panel -- which is the point of the table
-- and the reason to count it from this side.

do
    local cfg = read(ROOT .. 'br_lib/config/revivekey.lua', codeOf)
    if cfg then
        local copy = cfg:match('BR%.Config%.ReviveKey%.copy = {.-\n}')
        if not copy then
            fail('config/revivekey.lua no longer defines a `copy` table',
                 'every word this feature speaks lives there and nowhere else')
        else
            -- COUNT THE ASSIGNMENTS, NOT THE QUOTE MARKS. This counted
            -- `=%s*'`, which was one hit per line only while every line was a
            -- single-quoted one-liner. Four of the nine now run across two
            -- source lines with `..`, and two are DOUBLE quoted -- deliberately,
            -- because his wording has apostrophes in it and the same lines in
            -- single quotes cannot be read against his message without mentally
            -- unescaping two backslashes. Counting keys is what this always
            -- meant.
            local n = 0
            for _ in copy:gmatch('\n%s*[%a_][%w_]*%s*=') do n = n + 1 end
            if n ~= 9 then
                fail(('the revive key copy table holds %d lines, not 9'):format(n),
                     'the owner listed six on 2026-08-30, asked for the feature '
                     .. 'to ship rather than wait on him polishing them, and '
                     .. 'polished them himself on 2026-08-31 into nine. A tenth '
                     .. 'is a question for him, not a commit -- and the squad '
                     .. 'panel\'s mark is a picture precisely so it does not '
                     .. 'need one')
            end
        end
    end
end

-- ------------------------------------------------------------- the bundle ---
--
-- ui-src is a SOURCE tree; br_ui/ui/assets/index.js is what the game loads and
-- it is committed. Every assertion above passes on a repository whose bundle
-- was never rebuilt, and the game would show the old panel with a green verify.

do
    local fh = io.open(ROOT .. 'br_ui/ui/assets/index.js', 'r')
    if not fh then
        fail('the built UI bundle is missing')
    else
        local js = fh:read('a')
        fh:close()
        -- THE GLYPH IS READ OUT OF THE SOURCE rather than spelled out here,
        -- which is the difference between "a key was built once" and "THIS key
        -- is the one that ships". The sibling gate learned it: a literal is
        -- satisfied by a bundle built before the last edit.
        --
        -- SEGMENT BY SEGMENT, because the source concatenates three string
        -- literals and a bundler may or may not fold them. Each piece appears
        -- verbatim either way; the joined form does not.
        local decl = panel and panel:match('const KEY_PATH =.-\n\n')
        local segs = {}
        if decl then
            for s in decl:gmatch("'([^']+)'") do segs[#segs + 1] = s end
        end
        if #segs == 0 then
            fail('cannot read KEY_PATH out of SquadPanel.tsx',
                 'this gate resolves the glyph and compares with the built '
                 .. 'bundle. If the component was restructured, re-point this '
                 .. '-- do not replace it with a literal')
        else
            for _, s in ipairs(segs) do
                if not js:find(s, 1, true) then
                    fail('the built bundle does not contain the CURRENT key glyph',
                         'the bundle is stale. Run: cd ui-src && npm run build')
                    break
                end
            end
        end

        -- AND THE PICKUP CLOCK'S FIELD NAME. The glyph check above is satisfied
        -- by any bundle built since the mark was drawn, so it says nothing
        -- about a LATER edit to this panel. A payload field name is the one
        -- thing in a TSX file that survives minification unchanged, which makes
        -- it the freshness marker for everything added to the row after the
        -- glyph was.
        if not js:find('reviveKeyEndsAt', 1, true) then
            fail('the built bundle does not know about the pickup deadline',
                 'the bundle is stale. Run: cd ui-src && npm run build')
        end
    end
end

if failures > 0 then
    io.write(('\ncheck_squad_key: %d problem(s)\n'):format(failures))
    os.exit(1)
end

io.write('ok   a squadmate\'s revive key travels only to their own squad, folds\n'
    .. '     into the panel as a tri-state that keeps its false, and draws a\n'
    .. '     key beside the OUT stamp -- two shades, no caption, on a plate\n'
    .. '     that stops being faded to nothing. The pickup\'s own deadline\n'
    .. '     rides the same beacon and counts down on the clock the bleed\n'
    .. '     timer already uses, only while something is still on the ground\n')
