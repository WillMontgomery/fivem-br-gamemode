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

    -- ═══ THE PICKUP DEADLINE, WHICH IS A DRAINING LINE AND NOT A NUMBER ═══
    --
    -- Owner, 2026-09-02: "what if we put a red line at the bottom of the
    -- player's card to represent the timer? The bar will become less filled
    -- (akin to the bleed out timer card) as the time runs out"
    --
    -- It replaced a `142s` in the corner, which he had reported the same day:
    -- "the timer is not clear either. It should be more obvious what that timer
    -- means." So the field must still reach the panel, and what it drives must
    -- still be a length rather than digits.
    if not panel:find('m%.reviveKeyEndsAt') then
        fail('the squad panel no longer draws the pickup deadline',
             'owner, 2026-08-31: "If there is a timer to pickup their key, '
             .. 'display it in the squad panel", drawn since 2026-09-02 as the '
             .. 'red line along the bottom of the card')
    end
    do
        local clocks = select(2, panel:gsub('function%s+RowClock%s*%(', ''))
            + select(2, panel:gsub('function%s+BleedClock%s*%(', ''))
        if clocks ~= 1 then
            fail(('the panel defines %d countdown components, not 1'):format(clocks),
                 'there is one number on this row -- the bleed deadline. A '
                 .. 'second countdown component is how the pickup grows a '
                 .. 'numeral again beside the bar that replaced it, and two '
                 .. 'readings of one deadline is what the owner was looking at '
                 .. 'when he asked for the bar')
        end
    end

    -- ═══ AND IT IS THE BLEED CARD'S BAR, WHICH IS THE HALF HE NAMED ═══
    --
    --   THE TREATMENT. "(akin to the bleed out timer card)" is an instruction to
    --   reuse, not to resemble. DbnoOverlay's bar is a `bg-black/60` track with
    --   a `.bar-fill` child driven by `transform: scaleX()`; a hand-rolled
    --   width animation here would look right on the day it was written and
    --   drift the first time that card is touched.
    --
    --   THE COLOUR. "Red" is `--color-danger`, which is one of the four tokens
    --   index.css remaps for colourblind modes -- the revive timer's own "blue"
    --   is `--color-shield` and is not a blue hex. A literal red here is a bar
    --   that silently stops matching the card it was asked to match, for the
    --   players who need the remap most. DbnoOverlay's note reaches for
    --   `--color-hp` "rather than a literal green" for the same reason.
    --
    --   WHERE IT SITS. "the bottom of the player's card" -- absolutely
    --   positioned on the plate. Inside the `min-w-0` column it would stop at
    --   the text's edge rather than crossing the card, which looks like a bar
    --   that is nearly finished draining on a key that has just been minted.
    local drain = panel:match('function KeyDrain.-\n}')
    if not drain then
        fail('the panel no longer draws the pickup as a draining line',
             'owner, 2026-09-02: "put a red line at the bottom of the player\'s '
             .. 'card to represent the timer"')
    else
        if not drain:find('bar%-fill') then
            fail('the pickup bar is not the bleed card\'s `.bar-fill`',
                 'he named that card as the reference. That class carries a '
                 .. '300ms linear transition written to blend stepped writes '
                 .. 'into continuous motion; a second bar implementation is a '
                 .. 'second answer to what a draining bar looks like')
        end
        if not drain:find('scaleX', 1, true) then
            fail('the pickup bar is no longer scaled by transform',
                 '`.bar-fill` is `transform-origin: left center` and animates '
                 .. 'transform only -- a width animation gets no transition at '
                 .. 'all and steps once every 250ms')
        end
        if not drain:find('var%(%-%-color%-danger%)') then
            fail('the pickup bar\'s red is not --color-danger',
                 'that token is remapped by the colourblind modes and a hex is '
                 .. 'not. It is also the exact colour of the bleed card he '
                 .. 'asked this to look like, so the two can only stay matched '
                 .. 'by naming the same token')
        end
        if drain:find('#%x%x%x') then
            fail('the pickup bar carries a literal colour',
                 'see above -- every colour on this panel is a token')
        end
        if not drain:find('absolute') or not drain:find('bottom%-0') then
            fail('the pickup bar is not pinned to the bottom of the card',
                 '"a red line at the bottom of the player\'s card" is the whole '
                 .. 'of the design, and being out of flow is also what keeps it '
                 .. 'from changing any row\'s height')
        end

        -- ═══ AND THE RED BREATHES ═══
        --
        -- Owner, 2026-09-02: "For the red line on the squad bar - please make
        -- the red pulse fade so it looks urgent."
        --
        -- ON THE FILL AND NOT THE TRACK, because he asked for the RED to pulse:
        -- fading the black groove blinks the empty part of the line too, which
        -- reads as the card's edge flickering. The two classes are asserted
        -- TOGETHER on one element for that reason.
        local fill = drain:match('className="([^"]*bar%-fill[^"]*)"')
        if not fill then
            fail('cannot find the pickup bar\'s fill element')
        elseif not fill:find('mate%-pulse') then
            fail('the pickup bar\'s red no longer pulses',
                 'owner, 2026-09-02: "please make the red pulse fade so it '
                 .. 'looks urgent". `.mate-pulse` is this panel\'s own beat -- '
                 .. 'the one a downed mate\'s colour tag already wears -- so a '
                 .. 'key on the ground and a mate bleeding out breathe in step')
        end
    end

    -- ═══ AND WHATEVER PULSES IT MUST NOT TOUCH `transform` ═══
    --
    -- THIS IS THE ONE THAT WOULD NOT LOOK LIKE A BUG. The drain is an inline
    -- `transform: scaleX()` written by a tick; a keyframe that animates
    -- transform BEATS an inline style in the cascade, so the bar would pulse
    -- exactly as asked and quietly stop draining -- and the nearest pulse to
    -- hand, `.mate-talk`/`talkPulse` on this very row, does animate scale().
    --
    -- ui-src/scripts/check-ui.mjs R7 does NOT cover this. It refuses keyframes
    -- that animate width, height, top, left, margin, padding or box-shadow;
    -- #257 records that the list is those seven and no more, so transform --
    -- which is exactly what it is supposed to encourage everywhere else -- is
    -- invisible to it. Hence a gate here, against the keyframe by name.
    do
        local css = read(UI .. 'index.css', codeOfTs)
        if css then
            local pulse = css:match('@keyframes%s+matePulse%s*%b{}')
            if not pulse then
                fail('index.css no longer defines matePulse',
                     'the pickup bar and every downed mate\'s colour tag are '
                     .. 'animated by it')
            else
                if pulse:find('transform') then
                    fail('matePulse animates transform',
                         'the pickup bar\'s drain IS an inline transform, and a '
                         .. 'keyframe beats an inline style -- so this change '
                         .. 'would freeze the bar at full while it went on '
                         .. 'pulsing, which looks like a working feature')
                end
                if not pulse:find('opacity') then
                    fail('matePulse no longer fades',
                         '"make the red pulse fade" is the request; opacity is '
                         .. 'the only channel that does it without touching the '
                         .. 'transform the drain owns or the layout thread')
                end
            end
        end
    end
    do
        -- ...AND IT IS RENDERED ON THE PLATE, NOT INSIDE THE COLUMN. Asserted by
        -- position, the way the key mark is above: the bar must come AFTER the
        -- `flex-1 min-w-0` div opens and it must not be swallowed by it, which
        -- is only checkable here as "it is the last thing in the plate".
        local posCol = panel:find('flex%-1 min%-w%-0')
        local posBar = panel:find('<KeyDrain')
        local posBars = panel:find('<VitalBar')
        if posCol and posBar and posBars and not (posBars < posBar) then
            fail('the pickup bar is drawn above the row\'s own bars',
                 'it belongs on the plate itself, after the column everything '
                 .. 'else lays out in -- inside that column it stops at the '
                 .. 'text\'s edge instead of crossing the card')
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
-- listed six lines on 2026-08-30, rewrote the collection half into nine on
-- 2026-08-31, and wrote the tenth himself on 2026-09-01 ("the line under (in the
-- smaller lighter font) should say 'PRESS AND HOLD'"). A HUD caption added "for
-- clarity" is the likeliest eleventh, and it would arrive here rather than in
-- the panel -- which is the point of the table and the reason to count it from
-- this side.
--
-- THE COUNT MOVED BY ONE AND THE SENTENCE THAT MOVED IT ADDED TWO STRINGS, which
-- is worth writing down because it looks like an off-by-one: the same message
-- rewrote `revive` from 'Revive teammate' to 'Revive your squad' AND added
-- `reviveHold` under it. One new key, one rewritten value.

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
            if n ~= 10 then
                fail(('the revive key copy table holds %d lines, not 10'):format(n),
                     'the owner listed six on 2026-08-30, asked for the feature '
                     .. 'to ship rather than wait on him polishing them, '
                     .. 'polished them himself on 2026-08-31 into nine, and '
                     .. 'wrote the tenth on 2026-09-01. An eleventh is a '
                     .. 'question for him, not a commit -- and the squad '
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

        -- ...AND THE DRAIN BAR'S OWN CLASSES, WHICH IS THE MARKER FOR THIS
        -- ROUND. `reviveKeyEndsAt` has been on this payload since 2026-08-31, so
        -- it is satisfied by a bundle built before the owner replaced the
        -- numeral with a line (2026-09-02). A class string is the other thing
        -- that survives minification verbatim, and this one is read out of the
        -- SOURCE rather than spelled here for the reason the glyph is: a literal
        -- pins what somebody once wrote, not what ships.
        --
        -- BOTH OF THE BAR'S CLASS STRINGS, TRACK AND FILL. The fill's is what
        -- carries `mate-pulse`, so pinning only the track would have gone green
        -- on a bundle built before the owner asked for the red to breathe --
        -- exactly the hole the `reviveKeyEndsAt` marker had before the bar.
        -- Every future edit to either string invalidates a stale bundle on its
        -- own, which is the property rather than these two particular classes.
        do
            local cls = {
                panel and panel:match('className="(absolute inset%-x%-0[^"]*)"'),
                panel and panel:match('className="([^"]*bar%-fill[^"]*)"'),
            }
            if not (cls[1] and cls[2]) then
                fail('cannot read the pickup bar\'s classes out of SquadPanel.tsx',
                     'this gate compares them with the built bundle. If the bar '
                     .. 'was restructured, re-point this -- do not replace it '
                     .. 'with a literal')
            else
                for _, c in ipairs(cls) do
                    if not js:find(c, 1, true) then
                        fail('the built bundle does not contain the pickup '
                             .. 'drain bar as it is written now',
                             'the bundle is stale. Run: cd ui-src && npm run build')
                        break
                    end
                end
            end
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
    .. '     rides the same beacon and drains the bleed card\'s own bar along\n'
    .. '     the foot of that card -- in the token red, breathing on the same\n'
    .. '     pulse a downed mate\'s tag wears, on a channel the drain does not\n'
    .. '     own -- while something is still on the ground\n')
