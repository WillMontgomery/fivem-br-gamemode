-- Static gate: the squad panel shows voice STATE, and claims nothing it is not
-- told.
--
-- ═══ THE REQUEST ═══
--
-- Owner, 2026-08-22: "'Squad voice: nobody else on your squad radio yet' - how
-- about instead of showing this text, we show something in the top squad panel
-- next to each player which shows if they are muted, not listening, or talking.
-- I'm picturing icons like discord's mute/deafen/etc".
--
-- Two halves: the sentence goes, and the panel grows a mark. The Lua half of
-- the first is asserted behaviourally in tools/test_client.lua, which drives
-- BR.Voice.statusFor and reads the envelope that comes out. This file is for
-- the properties no suite can reach.
--
-- ═══ WHAT IS AIMED AT, AND WHY EACH ONE WOULD NOT LOOK LIKE A MISTAKE ═══
--
--   THE PANEL BECOMING AN ORACLE. The mark is built from two things already on
--   the voice envelope -- the talking list, and this client's own verdict. The
--   obvious "improvement" is to publish each player's voice mode so a mate can
--   be drawn as muted. That widens what a client is told about players it
--   cannot see, for a glyph, and it would be WRONG anyway: a squadmate on
--   'nearby' is not on your radio and is still audible standing next to you.
--   A change that added it would look like a feature and read like one in
--   review. So the squad payload's shape is pinned here.
--
--   THE MARK GOING BACK ON EVERY ROW. "You cannot hear anyone" is a fact about
--   THIS client. Painting it on a squadmate's row says something about them
--   that nobody knows. The gate pins the `you` test.
--
--   THE SLOT GOING CONDITIONAL AGAIN. The mark it replaces was rendered only
--   while somebody spoke, which moved the name sideways every sentence and
--   blinked whenever MumbleIsPlayerTalking dropped between words. Both are
--   fixed by the slot always existing and the glyphs cross-fading; both come
--   straight back if a later round "simplifies" it to `{talking && ...}`.
--
--   THE LAYOUT PAIR COMING APART. The mark opts out of baseline alignment and
--   the row it sits in opts in. Neither half is obviously load-bearing on its
--   own, and deleting either makes every downed and dead plate change height
--   with the player's text-size preference.
--
-- Run standalone:  lua tools/check_squad_voice.lua

local ROOT = 'resources/[fivem-royale]/'
local UI   = 'ui-src/src/'

local failures = 0

local function fail(msg, why)
    failures = failures + 1
    io.write('FAIL  ', msg, '\n')
    if why then io.write('      ', why, '\n') end
end

--- Lua source with its comments removed.
---
--- NOT OPTIONAL. Every file this reads quotes the owner's sentence back into
--- its own prose to explain why the sentence went -- so a gate that searched
--- raw source for that sentence would fail on the file that correctly deleted
--- it. tools/check_spectator_hud.lua learned the same lesson from the other
--- direction and carries the same pair of strippers.
local function codeOf(src)
    src = src:gsub('%-%-%[%[.-%]%]', ' ')
    src = src:gsub('%-%-[^\n]*', '')
    return src
end

--- TypeScript/TSX with its comments removed. Same argument, and it bites
--- harder here: VoiceMark.tsx's header names `tscale`, `{talking &&` and the
--- deleted sentence, all of which are searched for below.
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

-- ------------------------------------------------------- the sentence is gone ---

local voice = read(ROOT .. 'br_core/client/voice.lua', codeOf)
if voice then
    -- THE STRING ITSELF, IN CODE. This is the whole of the owner's first half.
    if voice:find('nobody else on your squad radio', 1, true) then
        fail('client/voice.lua still sends the sentence the owner asked to be '
             .. 'rid of',
             '"Squad voice: nobody else on your squad radio yet" -- it is '
             .. 'replaced by the squad panel\'s mark, not by a shorter line')
    end

    -- THE ROW SURVIVES, WHICH IS NOT THE SAME THING. `code` is what the
    -- envelope's dedup key is built from (see the TICK band in that file), so
    -- collapsing 'alone' into 'radio' would stop a squad FORMING from pushing
    -- anything at all -- a panel that never learns it has a squad, which is a
    -- much worse bug than the line this change removed.
    if not voice:find("code = 'alone'", 1, true) then
        fail("the 'alone' verdict no longer exists",
             'the row has to keep its own code even with no headline: the '
             .. 'voice envelope dedups on it, so merging it into the working '
             .. 'row means no push when a squadmate finally joins')
    end

    -- AND IT IS STILL NOT SILENT. A radio with one person on it carries the
    -- moment a second joins; nothing is refusing anybody. The squad panel's
    -- mark reads `silent`, so a `true` here would put the no-voice glyph on
    -- the viewer's row for every solo-squad match -- furniture, permanently,
    -- in the one place this change was supposed to make quieter.
    local aloneRow = voice:match("code = 'alone'.-\n%s*}")
    if aloneRow and aloneRow:find('silent = true', 1, true) then
        fail("the 'alone' row now reports itself silent",
             'nothing is refusing anybody on a working radio -- this would '
             .. 'draw the no-voice mark on a squad whose voice is fine')
    end
    if aloneRow and aloneRow:find('headline', 1, true) then
        fail("the 'alone' row carries a headline again",
             'whatever it says, it is a line painted across the bottom of the '
             .. 'screen about something the squad panel already shows')
    end

    -- THE ONE ROW THAT KEEPS ITS LINE. Squad mode with no squad is a silence
    -- nobody asked for and cannot fix from the panel -- there is nothing to
    -- mark, because there is no squad to mark it on.
    if not voice:find("code = 'nosquad'.-headline") then
        fail("the 'nosquad' row lost its headline too",
             'that one is not a caption for the squad panel: there is no '
             .. 'squad on it. It is the last row that still says anything')
    end
end

-- ------------------------------------------------ nothing new is published ---

-- THE ONE VOICE FACT A SQUADMATE'S ROW MAY CARRY. Named once, here, because
-- three checks below spell it and a gate whose permitted value drifts between
-- its own assertions permits whatever the loosest one does.
--
-- ═══ WHY THIS GATE NARROWED INSTEAD OF BEING DELETED ═══
--
-- It used to fail on ANY voice field crossing this boundary, and the refusal it
-- enforced is quoted in the block at the top of this file. The owner overruled
-- it on 2026-08-29, having watched the panel fail to show him the one thing he
-- wanted from it: "the squad panel works, but doesn't accurately show when
-- others in the squad have 'off' selected" -- then, told the fact was on no
-- wire at all, "Why can't we build another client -> server -> squad hop? It
-- should only be processed at the start of a squad in warmup and whenever
-- changes occur."
--
-- A DELETED GATE WOULD HAVE BEEN A DECISION NOBODY COULD FIND. Two of the three
-- arguments it was built on still stand and are still about the thing that is
-- still forbidden -- the MODE. 'nearby' and 'squad' differ only in the presence
-- of a distance, so drawing which one a mate is on means comparing positions,
-- which is a proximity oracle for players the client cannot see. `off` is the
-- one mode with no distance in it: absolute, both directions, everybody. So the
-- gate now permits exactly that boolean, by name, and fails on everything else
-- exactly as it did -- which means widening it again is a line somebody has to
-- write IN THIS FILE, next to the reasons, rather than a field they add
-- somewhere else and nobody notices.
local VOICE_BIT = 'voiceOff'

local state = read(ROOT .. 'br_core/client/state.lua', codeOf)
if state then
    -- THE SQUAD PAYLOAD'S SHAPE. pushSquadOrParty assembles one member table
    -- and that table is the entire contract with the panel.
    local push = state:match('function pushSquadOrParty.-\nend')
    if not push then
        fail('client/state.lua no longer defines pushSquadOrParty',
             'this gate reads the squad payload out of it')
    else
        -- THE PERMITTED FIELD IS REMOVED AND THEN THE OLD TEST IS RUN
        -- UNCHANGED. Subtracting the one exception rather than listing what is
        -- allowed keeps the check's failure mode the same as it always was:
        -- anything it does not recognise fails, including a field nobody has
        -- thought of yet.
        local rest = push:gsub(VOICE_BIT, '')
        if rest:lower():find('voice', 1, true) then
            fail('the squad payload has grown a voice field beyond `'
                 .. VOICE_BIT .. '`',
                 'exactly one voice fact about another player may cross this '
                 .. 'boundary, and it is the boolean the owner asked for on '
                 .. '2026-08-29. A per-player voice MODE is still refused: it '
                 .. 'would be wrong half the time -- a mate on nearby is not '
                 .. 'on your radio and is still audible standing next to you '
                 .. '-- and the only honest version of it compares positions. '
                 .. 'See ui-src/src/hud/VoiceMark.tsx')
        end

        -- AND THE BIT MUST STAY A BIT. A mode string reaching the payload under
        -- any name at all is the thing being refused; this catches the spelling
        -- that gets there without the word `voice` in it.
        if push:find("'nearby'", 1, true) or push:find("'off'", 1, true) then
            fail('the squad payload spells a voice mode out',
                 'the wire carries a boolean, not a mode. See BR.Net.'
                 .. 'VOICE_STATE in br_lib/shared/protocol.lua')
        end

        -- THE POSITIVE HALF, which the old gate did not need and this one does.
        -- A check that only forbids is satisfied by a payload that carries
        -- nothing -- which is exactly the state the owner reported as broken.
        if not push:find(VOICE_BIT, 1, true) then
            fail('the squad payload no longer carries `' .. VOICE_BIT .. '`',
                 'without it a squadmate who has turned their voice off is '
                 .. 'indistinguishable from one who is simply not speaking, '
                 .. 'which is the playtest report this hop was built for')
        end
    end
end

-- THIS ONE DID NOT NARROW, AND THAT IS THE POINT OF THE NARROWING ABOVE.
--
-- The owner approved a squad-only hop. PUBLIC_FIELDS is broadcast to EVERY
-- client in the match, so the exception granted above buys nothing here: "that
-- player cannot hear anything" is worth having about a teammate and worth
-- exploiting about an enemy -- it is the difference between flanking somebody
-- who can be warned and somebody who cannot. The bit rides the squad beacon
-- instead, which is the same boundary `dbnoUntil` and the squad level already
-- sit on for the same reason.
local roster = read(ROOT .. 'br_core/server/roster.lua', codeOf)
if roster then
    local public = roster:match('local PUBLIC_FIELDS = {.-}')
    if not public then
        fail('server/roster.lua no longer defines PUBLIC_FIELDS')
    elseif public:lower():find('voice', 1, true) then
        fail('PUBLIC_FIELDS has grown a voice field',
             'that list goes to every client in the match, not just a squad. '
             .. 'The one published voice bit is squad-only and rides the beacon '
             .. 'in server/party.lua; see the block above `VOICE_BIT`')
    end
end

-- ------------------------------------------------- and it comes off the beacon ---
--
-- WHERE THE BIT IS ALLOWED TO ENTER THE SERVER'S PAYLOADS, asserted from the
-- other end. The client half above pins what may LEAVE the squad payload; this
-- pins that the value it reads has a squad-only origin rather than having been
-- quietly moved onto a broadcast on the way.

local party = read(ROOT .. 'br_core/server/party.lua', codeOf)
if party then
    local beacon = party:match("BR%.Sched%.every%(250, 'party%.squadpos'.-\nend%)")
    if not beacon then
        fail('server/party.lua no longer defines the party.squadpos beacon',
             'this gate reads the squad-only push out of it')
    elseif not beacon:find(VOICE_BIT, 1, true) then
        fail('the squad beacon no longer carries `' .. VOICE_BIT .. '`',
             'it is the only channel this fact may travel on -- squad-only by '
             .. 'construction, already carrying the bleed deadline and the '
             .. 'level for the same reason')
    end
end

-- ------------------------------------------------------------- the glyphs ---

local mark = read(UI .. 'hud/VoiceMark.tsx', codeOfTs)
if mark then
    -- DRAWN HERE, NOT INSTALLED. This project pays for nothing and ships
    -- nothing unlicensed; there is no icon package in ui-src/package.json and
    -- there must not be one for this. Inline SVG also takes `currentColor`,
    -- which is what lets the mark follow the colourblind remaps.
    if not mark:find('<svg', 1, true) then
        fail('VoiceMark draws no inline SVG',
             'the glyphs are ours, written in that file. An icon package or an '
             .. 'image asset is a licence to check and a file to forget in '
             .. 'fxmanifest')
    end
    if not mark:find('currentColor', 1, true) then
        fail('the glyphs do not use currentColor',
             'a hardcoded fill cannot follow --color-danger, the accent, or '
             .. 'the colourblind remaps')
    end
    if mark:find('<img', 1, true) or mark:find('url(', 1, true) then
        fail('VoiceMark references an image',
             'the glyphs are inline SVG paths; an asset here is a file that '
             .. 'has to reach the client and a licence that has to be recorded')
    end

    -- TWO STATES, AND THEY ARE THE SAME OBJECT. Waves mean sound is flowing;
    -- a cross means nothing is. Losing either branch leaves one glyph doing
    -- both jobs, which is a mark that cannot be read.
    if not mark:find('M11%.1 5%.6a') then
        fail('the speaking glyph has lost its waves')
    end
    if not mark:find('M10%.7 6%.3 14%.1 9%.7') then
        fail('the no-voice glyph has lost its cross')
    end

    -- IT SCALES WITH THE PLAYER'S TEXT-SIZE PREFERENCE, AND VIA `.ts` (#159).
    -- Bare `tscale` multiplies 1em -- the PARENT's size -- so on an element
    -- that declares its own --fs it silently throws that value away.
    if not mark:find("%['%-%-fs' as string%]") then
        fail('VoiceMark declares no --fs, so it cannot scale with the text-size '
             .. 'preference (#159)')
    end
    if mark:find('tscale', 1, true) then
        fail('VoiceMark uses bare `tscale` alongside a declared size (#159)',
             '`tscale` multiplies the PARENT font size and discards --fs')
    end

    -- IT CANNOT FLICKER. The glyphs are both mounted and only opacity moves,
    -- over longer than the 100ms band Lua pushes on -- so a dropout between
    -- two words dips the mark instead of clearing it. A version that mounted
    -- and unmounted would blink, and would move the name with it.
    -- BOTH LAYERS, COUNTED. There are two glyphs and each fades on its own;
    -- a check for "a transition somewhere in the file" is satisfied by either
    -- one alone, and half a cross-fade is a mark that pops on the way in and
    -- glides on the way out.
    local fades = select(2, mark:gsub("transition: 'opacity", ''))
    if fades < 2 then
        fail(('the mark no longer cross-fades on both layers (%d of 2)')
             :format(fades),
             'MumbleIsPlayerTalking goes false between words; a mark that '
             .. 'mounts and unmounts with it blinks several times a sentence')
    end

    -- THE HALF OF THE LAYOUT PAIR THAT LIVES HERE. See SquadPanel below.
    if not mark:find("alignSelf: 'center'", 1, true) then
        fail('the mark participates in baseline alignment again',
             'a flex row with no baseline-aligned item takes its baseline from '
             .. 'the bottom edge of its FIRST item -- this mark. Growing it '
             .. 'with the text-size preference then moves the whole row: '
             .. 'measured, every downed and dead plate 0.6px taller at 1.15')
    end
end

-- --------------------------------------------------------- the squad panel ---

local panel = read(UI .. 'hud/SquadPanel.tsx', codeOfTs)
if panel then
    if not panel:find("from './VoiceMark'", 1, true) then
        fail('the squad panel no longer draws the voice mark')
    end

    -- THE SLOT IS UNCONDITIONAL. `{talking && <...>}` is the shape that was
    -- there before and it is the shape a later round reaches for.
    if panel:find('{talking &&', 1, true) then
        fail('the voice mark is rendered conditionally again',
             'the slot has to exist on every row or the name shifts sideways '
             .. 'every time somebody starts speaking, and the glyphs have '
             .. 'nothing to fade in and out of')
    end
    if panel:find('rounded%-full mate%-talk') then
        fail('the old accent dot is back in the squad panel',
             'there is one voice vocabulary and it is VoiceMark -- a second '
             .. 'marker for the same fact reads as a second fact')
    end

    -- THE SILENCE MARK IS THE VIEWER'S OWN AND NOBODY ELSE'S. `you` is how the
    -- row is found; without the comparison the glyph lands on every row and
    -- claims something about four people that is known about one.
    if not panel:find('squad%.you') then
        fail('the panel no longer reads `you`',
             'it is the only way to know which row is the viewer\'s, and the '
             .. '"no voice" mark belongs on that row alone')
    end
    if not panel:find('m%.src === mine') then
        fail('the viewer\'s own row is no longer identified',
             'the `fault` colour and the voice envelope\'s verdict belong to '
             .. 'that row alone; without the comparison they land on four '
             .. 'people')
    end

    -- A SQUADMATE'S ROW READS THE ONE PUBLISHED BIT AND NOTHING ELSE.
    if not panel:find(VOICE_BIT, 1, true) then
        fail('the panel no longer reads `' .. VOICE_BIT .. '`',
             'a squadmate who has turned their voice off then looks exactly '
             .. 'like one who is not speaking, which is the report of '
             .. '2026-08-29 that the hop was built for')
    end

    -- AND IT READS IT AS A BOOLEAN. `m.voiceOff &&` would also swallow the
    -- distinction this file cares about least and JavaScript gets wrong most:
    -- absent is a real state on this field -- a mate the beacon has not covered
    -- yet, an older server -- and it must render as nothing for that reason
    -- rather than by falling through a truthiness test.
    if not panel:find(VOICE_BIT .. ' === true', 1, true) then
        fail('`' .. VOICE_BIT .. '` is not read as an explicit boolean',
             'absent and false are different claims that happen to draw the '
             .. 'same thing; a truthiness test collapses them by accident')
    end

    -- 'fault' IS THE VIEWER'S ALONE. It is --color-danger and it means "this is
    -- wrong and you can fix it" -- true only of the player who can open the
    -- settings screen. A mate's voice being off is reported, not alarmed about,
    -- and painting it red teaches the player that the colour means nothing.
    --
    -- THE BRANCH, NOT THE FUNCTION AROUND IT. `silentFor` is annotated
    -- `'chosen' | 'fault' | null`, so a search over the whole function finds
    -- the word in its own type and reports the correct file -- which is how
    -- this check failed on its first run. What is asked is narrower and is the
    -- actual question: what does the line that reads the mate's bit RETURN.
    local mateBranch = panel:match('return m%.' .. VOICE_BIT .. '[^\n]*')
    if not mateBranch then
        fail('the panel no longer resolves a squadmate\'s mark from `'
             .. VOICE_BIT .. '` in one expression',
             'this gate reads the mate branch off that return')
    elseif mateBranch:find("'fault'", 1, true) then
        fail("a squadmate's row can be painted as a voice FAULT",
             'nothing published says a mate\'s silence is unwanted -- '
             .. VOICE_BIT .. ' is a state they chose. Red is for the one '
             .. 'player who can act on it')
    end

    -- THE OTHER HALF OF THE LAYOUT PAIR.
    -- `min-w-0` IS PART OF THE PATTERN, not decoration. The DOWN/OUT stamp
    -- beside the name is ALSO `flex items-baseline gap-1`, so a pattern without
    -- the trailing class matches that one and passes happily over a name row
    -- that has gone back to `items-center`. That mutation survived this gate's
    -- first draft.
    if not panel:find('flex items%-baseline gap%-1 min%-w%-0') then
        fail('the name row is no longer baseline-aligned',
             'with `items-center` there is no baseline-aligned item in the '
             .. 'row, so its baseline is synthesised from the voice mark -- '
             .. 'and the plate then changes height with the text-size setting')
    end
end

-- ------------------------------------------------------- one vocabulary ---

local bar = read(UI .. 'hud/TalkingBar.tsx', codeOfTs)
if bar then
    -- THE BOTTOM-CENTRE LINE AND THE PANEL DRAW THE SAME MARK, from the same
    -- component. That rule predates this change -- TalkingBar's own note has
    -- always said "a second, different marker for the same fact would read as
    -- a second fact" -- and it is why the dot moved when the panel's did.
    if not bar:find("from './VoiceMark'", 1, true) then
        fail('the talking line and the squad panel no longer draw the same mark',
             'one fact, one marker. They moved together on purpose')
    end
    if bar:find('rounded%-full mate%-talk') then
        fail('the talking line has kept its own accent dot')
    end
end

-- ------------------------------------------------------------- the bundle ---
--
-- ui-src is a SOURCE tree; br_ui/ui/assets/index.js is what the game loads and
-- it is committed. Every assertion above passes on a repository whose bundle
-- was never rebuilt, and the game would show the old panel. Same check, same
-- reason, as the voice-defaults gate in verify.sh.

do
    local fh = io.open(ROOT .. 'br_ui/ui/assets/index.js', 'r')
    if not fh then
        fail('the built UI bundle is missing')
    else
        local js = fh:read('a')
        fh:close()

        -- THE PATH IS READ OUT OF THE SOURCE, NOT SPELLED OUT HERE, and that
        -- is the difference between "a voice mark was built once" and "THIS
        -- voice mark is the one that ships". A literal in this file is
        -- satisfied by a bundle built before the glyph was last edited --
        -- which is exactly the stale-bundle case the check exists for, and it
        -- survived this gate's first draft: redrawing the cone and not
        -- rebuilding passed, because the OLD cone was still in the bundle.
        local cone = mark and mark:match("CONE = '([^']+)'")
        if not cone then
            fail('cannot read the glyph path out of VoiceMark.tsx',
                 'this gate resolves `const CONE = \'...\'` and compares it '
                 .. 'with the built bundle. If that constant was renamed, '
                 .. 're-point this -- do not replace it with a literal')
        elseif not js:find(cone, 1, true) then
            fail('the built bundle does not contain the CURRENT voice mark',
                 'the bundle is stale. Run: cd ui-src && npm run build')
        end
        if js:find('nobody else on your squad radio', 1, true) then
            fail('the built bundle still carries the deleted sentence',
                 'nothing in ui-src should ever have held it -- the words are '
                 .. "Lua's -- so this means a copy was made")
        end

        -- AND THE BIT REACHES THE PLAYER. `voiceOff` is a PROPERTY NAME read
        -- off a payload, so the minifier cannot rename it -- unlike a local,
        -- which is why this is checkable at all. Its absence means the source
        -- grew the field and the bundle did not, which looks correct in every
        -- diff and shows the owner exactly the panel he reported.
        if not js:find(VOICE_BIT, 1, true) then
            fail('the built bundle does not read `' .. VOICE_BIT .. '`',
                 'the bundle is stale. Run: cd ui-src && npm run build')
        end
    end
end

if failures > 0 then
    io.write(('\ncheck_squad_voice: %d problem(s)\n'):format(failures))
    os.exit(1)
end

io.write('ok   the squad panel marks voice state from what the client is told --\n'
    .. '     talking on any row, "no voice" on the viewer\'s own and on a mate\n'
    .. '     the beacon says is off, and nothing at all otherwise. One bit\n'
    .. '     crosses the boundary; the mode still crosses nothing\n')
