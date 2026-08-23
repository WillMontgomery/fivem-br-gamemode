-- Static gate: the squad panel shows a teammate's LEVEL, beside their name,
-- and says nothing else.
--
-- ═══ THE REQUEST ═══
--
-- Owner, 2026-08-22: "We need some way in the squad panel to see the levels of
-- our teammates near their name."
--
-- The behavioural half -- where the number comes from, who is told, and what a
-- player with no profile yet gets -- is asserted in tools/test_shared.lua
-- ('squad.level'), which drives the real beacon. This file is for the
-- properties no suite can execute.
--
-- ═══ WHAT IS AIMED AT, AND WHY EACH ONE WOULD NOT LOOK LIKE A MISTAKE ═══
--
--   THE NUMBER GOING PUBLIC. The obvious home for a new per-player fact is
--   roster.lua's PUBLIC_FIELDS, and it is the wrong one: that list is
--   broadcast to every client in the match. A level gives away nothing
--   tactical, so nothing would break and nobody would notice -- which is
--   exactly why it needs a gate rather than a comment. The owner asked to see
--   his TEAMMATES' levels; the squad beacon is the channel already limited to
--   them.
--
--   A CAPTION GROWING BESIDE IT. "Never add unsolicited UI text" is a standing
--   instruction, and a bare figure beside a name is what was asked for. "Lv",
--   "LVL" or "Level" is the natural thing for a later round to add "for
--   clarity", in the tightest row on the HUD.
--
--   THE FIGURE LEARNING TO SCALE. The squad plate is a fixed-size plate, which
--   index.css names as the one place the text-size preference must not reach.
--   The voice mark next door scales, and needed `align-self: center` plus an
--   `items-baseline` row to stop it dragging every plate's height with it. A
--   `tscale` or `.ts` added here walks straight back into that bug, and the
--   symptom is 0.6px per plate -- invisible in review, and a panel that
--   changes height with a setting nobody connects to it.
--
--   THE GUARD BECOMING A TRUTHINESS TEST. `{m.level && ...}` renders a literal
--   0 in React, and `!= null` lets a NaN through to be painted. Levels are
--   1..100; a range test is the only spelling that draws nothing for "not
--   known yet" without inventing a number.
--
--   THE FIGURE LOSING `shrink-0`. Without it a long gamertag squeezes the
--   level out of its own row instead of truncating itself -- so the feature
--   silently disappears for exactly the players most likely to have a high
--   one.
--
-- Run standalone:  lua tools/check_squad_level.lua

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
--- SquadPanel.tsx's own note contains the words "Level", "tscale" and
--- "m.level &&", all of which are searched for below.
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
    elseif public:find('level', 1, true) or public:find('xp', 1, true) then
        fail('PUBLIC_FIELDS has grown a level (or the xp behind it)',
             'that list goes to every client in the match. The owner asked to '
             .. 'see his TEAMMATES\' levels -- the squad beacon in '
             .. 'server/party.lua is the channel already limited to them')
    end
end

-- ------------------------------------------------- derived, never read ---

local party = read(ROOT .. 'br_core/server/party.lua', codeOf)
if party then
    if not party:find('BR%.Xp%.levelFor') then
        fail('server/party.lua no longer derives the level from xp',
             'BR.Xp.levelFor is the same authority server/market.lua sends the '
             .. 'lobby and br_stats writes the profile row from. A second '
             .. 'implementation, or a stored `level` column read directly, is '
             .. 'how the panel ends up disagreeing with the lobby chip')
    end
    -- THE STORED COLUMN IS THE TRAP. A profile row really does carry `level`,
    -- written at match end, and it lags the xp beside it for the whole of the
    -- next match. Reading it would look correct in every review.
    if party:find('e%.level') or party:find('entry%.level') then
        fail('the beacon reads a stored `level` field',
             'that column is written at match end and goes stale -- derive it '
             .. 'from xp, which accumulates atomically and cannot')
    end
    if not party:find('level = levelOf%(src%)') then
        fail('the squad beacon no longer carries the level',
             'this is the only channel it travels on; without it the panel has '
             .. 'nothing to draw')
    end
end

-- ------------------------------------------------------- the client fold ---

local state = read(ROOT .. 'br_core/client/state.lua', codeOf)
if state then
    local push = state:match('function pushSquadOrParty.-\nend')
    if not push then
        fail('client/state.lua no longer defines pushSquadOrParty',
             'this gate reads the squad payload out of it')
    elseif not push:find('level = b and b%.level') then
        fail('the squad payload no longer folds the beacon\'s level in',
             'it must come off the BEACON (squad-only), not from the roster '
             .. 'mirror -- and it must not be computed here: a client that '
             .. 'derived its own would eventually disagree with the lobby')
    end
end

-- --------------------------------------------------------------- the panel ---

local panel = read(UI .. 'hud/SquadPanel.tsx', codeOfTs)
if panel then
    if not panel:find('LevelMark', 1, true) then
        fail('the squad panel no longer draws a level')
    end

    -- BESIDE THE NAME, WHICH IS THE WHOLE SPEC. Asserted by POSITION rather
    -- than by carving the group out with a pattern: the group contains nested
    -- spans, so any non-greedy match for its closing tag stops at the name's
    -- and reports a level that is sitting right where it belongs as missing.
    -- (It did, on this gate's first run.) The level has to fall after the
    -- group opens, after the name inside it, and before the DOWN/OUT stamp
    -- that closes the row.
    local posGroup = panel:find('flex items%-baseline gap%-1 min%-w%-0')
    local posName  = panel:find('{m%.name}')
    local posLevel = panel:find('<LevelMark')
    local posStamp = panel:find('%(dead %|%| downed%) &&')
    if not (posGroup and posName and posStamp) then
        fail('the name row is no longer recognisable',
             'this gate locates the level relative to the name and the stamp')
    elseif not posLevel then
        fail('the panel no longer renders <LevelMark/>')
    elseif not (posGroup < posLevel and posName < posLevel
                and posLevel < posStamp) then
        fail('the level is not beside the name any more',
             ('group@%s name@%s level@%s stamp@%s -- the owner asked for it '
              .. 'NEAR THE NAME; elsewhere on the plate it is a different '
              .. 'feature'):format(tostring(posGroup), tostring(posName),
                                   tostring(posLevel), tostring(posStamp)))
    end

    local markBody = panel:match('function LevelMark.-\n}')
    if not markBody then
        fail('LevelMark is no longer a recognisable component')
    else
        -- NO CAPTION, asserted as "this element renders the number and NOTHING
        -- ELSE". Searching for the words instead does not work -- the
        -- component is CALLED LevelMark, so a search for 'Level' matches its
        -- own name and fails on the correct file (it did, first run). Pinning
        -- the whole text content is stronger anyway: it refuses a prefix, a
        -- suffix and a unit as well as the three words anybody would reach for.
        if not markBody:find('>%s*{level}%s*</span>') then
            fail('LevelMark renders something other than the bare figure',
                 'the owner asked for the LEVELS near the name, not a label. '
                 .. '"Never add unsolicited UI text" -- so this element\'s '
                 .. 'entire content is {level}')
        end
        -- IT MUST NOT SCALE. See the header.
        if markBody:find('tscale', 1, true) or markBody:find('"ts ', 1, true)
           or markBody:find(' ts ', 1, true) then
            fail('the level scales with the text-size preference',
                 'the squad plate is a fixed-size plate. The voice mark next '
                 .. 'door needed align-self:center to stop exactly this from '
                 .. 'changing every plate\'s height with the setting')
        end
        if not markBody:find('shrink%-0') then
            fail('the level lost `shrink-0`',
                 'a long gamertag then squeezes the figure out of its own row '
                 .. 'instead of truncating itself')
        end
        if not markBody:find('tabular%-nums') then
            fail('the level is no longer in tabular figures',
                 '1 and 100 must put their digits on the same rhythm or the '
                 .. 'column jitters as levels tick over')
        end
    end

    -- THE GUARD IS A RANGE, NOT A TRUTHINESS TEST.
    if panel:find('{m%.level &&') then
        fail('the level guard is a truthiness test again',
             'React renders a literal 0 for `{0 && ...}`, and 0 is not a level. '
             .. 'Levels are 1..100 -- ask for that')
    end
    if not panel:find("typeof m%.level === 'number'") or not panel:find('m%.level >= 1') then
        fail('the level guard no longer tests for a real level',
             'absent means "the server has not said yet" and must draw '
             .. 'NOTHING -- not a 0, not a placeholder 1, and not a NaN')
    end
end

-- ------------------------------------------------------------- the bundle ---
--
-- ui-src is a SOURCE tree; br_ui/ui/assets/index.js is what the game loads and
-- it is committed. Every assertion above passes on a repository whose bundle
-- was never rebuilt, and the game would show the old panel.

do
    local fh = io.open(ROOT .. 'br_ui/ui/assets/index.js', 'r')
    if not fh then
        fail('the built UI bundle is missing')
    else
        local js = fh:read('a')
        fh:close()
        -- THE CLASS STRING IS READ OUT OF THE SOURCE rather than spelled out
        -- here, which is the difference between "a level was built once" and
        -- "THIS level is the one that ships". The sibling gate learned this:
        -- a literal is satisfied by a bundle built before the last edit.
        local cls = panel and panel:match('function LevelMark.-className="([^"]+)"')
        if not cls then
            fail('cannot read LevelMark\'s class string out of SquadPanel.tsx',
                 'this gate resolves it and compares with the built bundle. If '
                 .. 'the component was restructured, re-point this -- do not '
                 .. 'replace it with a literal')
        else
            -- JSX collapses the source's newlines and indentation into single
            -- spaces in the emitted string, so compare on a normalised form.
            local norm = cls:gsub('%s+', ' ')
            if not js:find(norm, 1, true) then
                fail('the built bundle does not contain the CURRENT level mark',
                     'the bundle is stale. Run: cd ui-src && npm run build')
            end
        end
    end
end

if failures > 0 then
    io.write(('\ncheck_squad_level: %d problem(s)\n'):format(failures))
    os.exit(1)
end

io.write('ok   a teammate\'s level is derived from xp, travels only to their own\n'
    .. '     squad, sits beside the name with no caption, and draws nothing at\n'
    .. '     all until the server knows it\n')
