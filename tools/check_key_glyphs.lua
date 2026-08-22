-- Static gate: a key is drawn as a key, and the key it draws is the real one.
--
-- ═══ THE REQUEST ═══
--
-- Owner, 2026-08-22 (#209):
--
--   "New request - we should make our own glyphs for keys. For example, this
--    message looks too bland and hard coded: 'Voice chat is set to nearby.
--    Hold N to speak. You can change your preference and keybinds in
--    Settings.'"
--
-- THE COMPLAINT WAS NOT THE WORDING. That sentence is his, it is composed in
-- br_core/client/voice.lua, and every word of it survives. It was that the N
-- sat inside it as a letter of Barlow between two spaces, so a thing you PRESS
-- read as a thing somebody TYPED.
--
-- ═══ WHY A TEXT GATE, AND WHAT IS TESTED PROPERLY ELSEWHERE ═══
--
-- The half that is a value is unit-tested and belongs there: tools/test_client
-- .lua drives BR.Voice.noticeFor through both branches and asserts the owner's
-- wording, the token, and -- the assertion that actually pins the fix -- that
-- passing a resolved label does NOT put that label in the string.
--
-- What no suite in this repo can reach is the other three quarters:
--
--   the two languages agreeing   Lua writes the token, TypeScript parses it,
--                                and nothing executes both. Two spellings of
--                                one wire format in two files is this
--                                project's signature bug and it fails SILENTLY
--                                -- the sentence still renders, with the raw
--                                token sitting in the middle of it.
--   the component's promises     "not a button", "resolved by command name",
--                                "a dash when unbound" are properties of TSX
--                                that no Lua suite can drive.
--   the surfaces still calling   a component can be perfect and uncalled.
--
-- Run standalone:  lua tools/check_key_glyphs.lua

local ROOT = 'resources/[fivem-royale]/'
local UI   = 'ui-src/src/'

local failures = 0

local function fail(msg, why)
    failures = failures + 1
    io.write('FAIL  ', msg, '\n')
    if why then io.write('      ', why, '\n') end
end

--- Lua source with its comments stripped.
---
--- NOT OPTIONAL, AND check_spectator_hud.lua PAID FOR THE LESSON FIRST. Every
--- file this reads explains itself at length and QUOTES THE VERY TOKENS being
--- searched for -- protocol.lua's own note contains the string `{key:brptt}`,
--- and voice.lua's contains "Hold N". Read raw, a check for the bug would find
--- the essay describing the bug and report it.
local function codeOfLua(src)
    src = src:gsub('%-%-%[%[.-%]%]', ' ')
    src = src:gsub('%-%-[^\n]*', '')
    return src
end

--- TypeScript with its comments stripped, for exactly the same reason.
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

local function readLua(rel) return read(ROOT .. rel, codeOfLua) end
local function readUi(rel)  return read(UI .. rel,  codeOfTs)  end

-- ═════════════════════════════════════ the token, and both ends of it ═════

--- The literal Lua writes around the command name, e.g. '{key:' and '}'.
--- Read out of BR.KeyToken rather than restated, so this gate cannot be the
--- place the two spellings drift apart.
local tokenOpen, tokenClose

do
    local proto = readLua('br_lib/shared/protocol.lua')
    if proto then
        if not proto:find('function BR%.KeyToken') then
            fail('br_lib/shared/protocol.lua no longer defines BR.KeyToken',
                 'every sentence that names a key builds its hole with it; '
                 .. 'without one they go back to substituting labels')
        end

        -- THE FORMAT IS EXTRACTED, NOT ASSUMED. Pinning the literal '{key:%s}'
        -- here would make this gate a second declaration of the wire format,
        -- which is the failure it exists to prevent.
        tokenOpen, tokenClose = proto:match("%('([^']*)%%s([^']*)'%):format")
        if not tokenOpen then
            fail('BR.KeyToken does not build its token with a format string',
                 'this gate reads the shape out of it to compare against the '
                 .. 'page\'s parser; reshape them together or neither')
        elseif tokenOpen == '' then
            fail('BR.KeyToken produces a token with no opening literal',
                 'a bare command name in a sentence is indistinguishable from '
                 .. 'a word, and the page would have nothing to find')
        end
    end
end

-- ═══════════════════════════════ the page parses what Lua writes ══════════

do
    local cap = readUi('ui/KeyCap.tsx')
    if cap then
        -- ═══ THE CROSS-LANGUAGE ASSERTION, WHICH IS THE WHOLE POINT ═══
        --
        -- Lua's format and this regex are one wire format written twice, in
        -- two languages, with no test that executes both. When they disagree
        -- nothing errors: the notice renders with `{key:brptt}` sitting in the
        -- middle of the owner's sentence, which is a worse version of the bug
        -- #209 was opened about.
        if tokenOpen and tokenOpen ~= '' then
            -- The regex escapes its braces; compare on the literal characters
            -- rather than the source spelling.
            local rx = cap:match('const KEY_TOKEN%s*=%s*/([^/]+)/')
            if not rx then
                fail('ui/KeyCap.tsx has no KEY_TOKEN pattern',
                     'nothing would parse the holes Lua writes')
            else
                local plain = rx:gsub('\\', '')
                local wantOpen  = tokenOpen
                local wantClose = tokenClose or ''
                if plain:sub(1, #wantOpen) ~= wantOpen then
                    fail(('the page\'s token pattern does not start with %q')
                         :format(wantOpen),
                         'BR.KeyToken writes it and this must read it -- they '
                         .. 'are one format, and a mismatch renders the raw '
                         .. 'token inside the owner\'s sentence')
                end
                if wantClose ~= '' and plain:sub(-#wantClose) ~= wantClose then
                    fail(('the page\'s token pattern does not end with %q')
                         :format(wantClose),
                         'same format, same argument as the opening literal')
                end
            end
        end

        -- ═══ THE KEY COMES FROM THE BINDING, BY COMMAND NAME ═══
        --
        -- THE WHOLE EXPRESSION IS PINNED, NOT THE FIELD NAME, and that is a
        -- lesson check_spectator_hud.lua learned the hard way: `keybinds`
        -- appearing somewhere is satisfied by a component that reads the list
        -- and then draws a constant.
        if not cap:find('s%.keybinds%.find') then
            fail('KeyCap does not resolve its key from the keybinds list',
                 'a hardcoded letter is wrong the moment somebody rebinds, and '
                 .. 'the list is the only thing Lua re-pushes on a rebind')
        end
        if not cap:find('k%.command === command') then
            fail('KeyCap does not match the binding BY COMMAND NAME',
                 'matching by index or by label ties every glyph in the game '
                 .. 'to the order of a table in keybinds.lua')
        end

        -- AN UNBOUND ACTION DRAWS A DASH. Not a blank plate, which reads as the
        -- interface having failed, and never a stale letter.
        if not cap:find("{key || '%-%-'}") then
            fail('KeyCap does not draw a dash for an unbound action',
                 'an empty plate reads as a broken interface; a dash says the '
                 .. 'key is gone, which is true and is fixable from Controls')
        end

        -- IT LOOKS LIKE A BUTTON AND IS NOT ONE. Inherited verbatim from the
        -- spectate hint, whose owner brief said "look like a button but not
        -- have a mouse required" -- and a spectating player has no cursor.
        if cap:find('onClick') or cap:find('<butt' .. 'on') then
            fail('KeyCap has become clickable',
                 'a key glyph is a picture of a key; the thing you click to '
                 .. 'rebind is the Keybinds screen and it already exists')
        end

        -- IT IS THE KEYBINDS SCREEN'S OWN TREATMENT. `.plate` plus the display
        -- face is what makes a glyph in a sentence and the row a player rebinds
        -- read as one object.
        if not cap:find('plate ts font%-display') then
            fail('KeyCap is no longer drawn as a `.plate` in the display face',
                 'that pairing is what the Keybinds screen uses for the same '
                 .. 'object; a glyph that does not match it is a second design')
        end

        -- IT SCALES, AND VIA `.ts` WITH AN EXPLICIT --fs (#159). Bare `tscale`
        -- multiplies 1em -- the PARENT's size -- and silently discards a
        -- declared one.
        if not cap:find("%['%-%-fs' as string%]") then
            fail('KeyCap declares no --fs, so it cannot honour the text slider')
        end
        if cap:find('tscale') then
            fail('KeyCap uses bare `tscale` alongside a declared size (#159)',
                 '`.ts` with --fs is the pairing that survives it')
        end

        -- A WIDE LABEL WIDENS RATHER THAN WRAPPING. `Backspace`, `Page Down`
        -- and `Num 5` all reach here from BR.Keys.vkName; a cap broken over two
        -- lines is not a key.
        if not cap:find("whiteSpace: 'nowrap'") then
            fail('KeyCap may wrap a long key label across two lines',
                 'BR.Keys.vkName returns Backspace and Page Down among others')
        end
        -- AND IT IS BLOCKIFIED, WHICH IS LOAD-BEARING RATHER THAN COSMETIC. On
        -- a bare inline box `min-width` does not apply and vertical padding
        -- does not affect line height, so a one-letter cap dropped into prose
        -- collapses and overlaps the line above. The spectate hint never showed
        -- this because a flex item is blockified for free.
        if not cap:find("display: 'inline%-block'") then
            fail('KeyCap is not inline-block',
                 'inside a sentence its min-width would not apply and its '
                 .. 'padding would overlap the line above')
        end
    end
end

-- ═══════════════════════════ the sentences write holes, not letters ═══════

do
    local voice = readLua('br_core/client/voice.lua')
    if voice then
        -- BOTH SURFACES, COUNTED SEPARATELY. `BR.KeyToken` appearing in the
        -- file is satisfied by either one alone, and they are different
        -- surfaces with different lifetimes: noticeFor is the twelve-second
        -- toast the owner was looking at, statusFor's `detail` is the
        -- paragraph on the settings screen the player rebinds FROM. Losing
        -- either one puts a stale letter back on a surface.
        if not voice:find('BR%.KeyToken%(PTT_COMMAND%)') then
            fail('client/voice.lua no longer builds its key holes with '
                 .. 'BR.KeyToken(PTT_COMMAND)',
                 'the sentence would name a key label again, resolved at the '
                 .. 'moment it was composed and stale from then on')
        end
        local _, n = voice:gsub('BR%.KeyToken%(', '')
        if n < 2 then
            fail(('client/voice.lua builds only %d key hole(s); the notice and '
                  .. 'the settings detail are two'):format(n),
                 'noticeFor is the start-of-match toast, statusFor\'s detail is '
                 .. 'the paragraph on the settings screen -- both name the key')
        end

        -- AND NEITHER SUBSTITUTES THE LABEL. This is the mutation that keeps
        -- every assertion above green and puts the bug straight back:
        -- `('Hold %s'):format(key)` beside a token that nothing reads.
        if voice:find("'Hold %%s'%):format%(key%)")
            or voice:find("'Hold %%s to speak%.'%):format%(key%)") then
            fail('client/voice.lua still formats the resolved key LABEL into a '
                 .. 'sentence',
                 'that is the letter-in-prose #209 was opened about; the label '
                 .. 'may decide WHICH sentence, never appear in one')
        end
    end
end

do
    local natives = readLua('br_core/client/natives.lua')
    if natives then
        -- THE STICKY ONE, AND THE ONE THAT MOST NEEDED THIS. It stays on screen
        -- for as long as the big map is open, which is exactly the window in
        -- which somebody might go and rebind the pause key.
        if not natives:find("BR%.KeyToken%('brpausemenu'%)") then
            fail('the big-map notice does not name its key as a hole',
                 'it is STICKY -- it is up for as long as the map is -- so a '
                 .. 'substituted label sits there naming the old binding')
        end
        if natives:find("to close the map'%):format%(key%)") then
            fail('the big-map notice still substitutes the resolved key label',
                 'the token and the label cannot both be right')
        end
    end
end

-- ═════════════════════════════════ the surfaces still call the component ══

do
    -- A PERFECT COMPONENT THAT NOTHING RENDERS IS THE SILENT FAILURE HERE.
    -- Both of these read a string composed in Lua that may contain a hole; a
    -- surface that dropped back to rendering the raw string would show
    -- `{key:brptt}` to the player and pass every assertion above.
    local notices = readUi('hud/Notices.tsx')
    if notices and not notices:find('<KeyText%s') then
        fail('the notice stack renders its text without KeyText',
             'the once-a-session voice notice and the sticky map notice both '
             .. 'arrive with a hole in them; raw, the player sees the token')
    end

    local settings = readUi('screens/Settings.tsx')
    if settings and not settings:find('<KeyText%s') then
        fail('the settings screen renders voiceDetail without KeyText',
             'that paragraph names the push-to-talk key and sits on the very '
             .. 'screen the player rebinds it from')
    end
end

-- ══════════════════════════════════════════════ the bundle is the game ═══

do
    -- ui-src is a SOURCE tree; br_ui/ui/assets/index.js is what ships and it is
    -- committed. Editing a component without rebuilding leaves a repository
    -- where every assertion above passes and the game draws the old interface.
    -- Same check and same reason as check_spectator_hud.lua's.
    local fh = io.open(ROOT .. 'br_ui/ui/assets/index.js', 'r')
    if not fh then
        fail('the built UI bundle is missing')
    else
        local js = fh:read('a')
        fh:close()
        if tokenOpen and tokenOpen ~= '' and not js:find(tokenOpen, 1, true) then
            fail('the built bundle does not contain the key-token parser',
                 'the bundle is stale. Run: cd ui-src && npm run build')
        end
    end
end

if failures > 0 then
    io.write(('\ncheck_key_glyphs: %d problem(s)\n'):format(failures))
    os.exit(1)
end

io.write('ok   keys draw as keys -- one plate, resolved by command name off the'
    .. '\n     keybinds list, a dash when unbound, and the sentences around '
    .. 'them\n     carry holes rather than letters\n')
