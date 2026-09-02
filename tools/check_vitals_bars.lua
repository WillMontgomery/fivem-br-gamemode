-- Static gate: the health and shield bars say what they are, and still hide a
-- zero.
--
-- ═══ THE REQUEST ═══
--
-- Owner, 2026-08-22 (#210), on the three vehicle bars:
--
--   "All 3 bars look good. I wish we had the same type text within the
--    health/shield bars to be honest."
--
-- The vehicle strip gained a caption and a numeral inside each pill after the
-- earlier round of that playtest. The player's own vitals did not, and the
-- header comment in Vitals.tsx argued at length that they should not. The owner
-- has now asked for the opposite, so the captions are on and that argument is
-- gone from the file.
--
-- ═══ WHY A TEXT GATE ═══
--
-- ui-src has no JavaScript test runner -- the whole interface is verified by
-- static gates plus the Lua suites behind whatever feeds it -- so a rendering
-- rule inside a .tsx file has no other instrument in this repo. Two things
-- follow and are worth saying rather than leaving to be discovered:
--
--   * THIS CANNOT TELL YOU IT LOOKS RIGHT. Legibility of a 6.8px caption over
--     a saturated fill is a thing only an eye in game can settle. What it can
--     tell you is that a rule got quietly inverted, which is the findable half.
--   * THE GEOMETRY WAS MEASURED, NOT ASSERTED HERE. At 1280x720 the row is
--     11.55px tall with its top edge at y=694.77, identical before and after
--     the captions and identical at text scales 0.90 / 1.00 / 1.15; the shield
--     caption uses 35.06px of the 68px it has at the largest setting. Numbers
--     off a running harness, recorded in the components. A gate that restated
--     them would be asserting arithmetic it cannot perform.
--
-- Run standalone:  lua tools/check_vitals_bars.lua

local UI = 'ui-src/src/'

local failures = 0

local function fail(msg, why)
    failures = failures + 1
    io.write('FAIL  ', msg, '\n')
    if why then io.write('      ', why, '\n') end
end

--- TypeScript with its comments stripped.
---
--- LOAD-BEARING HERE MORE THAN ANYWHERE. Vitals.tsx's header quotes the owner,
--- quotes the RULE, and spells out the exact expression this gate is looking
--- for -- including the retired one. Read raw, the check for the retired
--- heuristic below fires on the paragraph explaining why it was retired.
local function codeOfTs(src)
    src = src:gsub('/%*.-%*/', ' ')
    src = src:gsub('//[^\n]*', '')
    return src
end

local function readUi(rel)
    local fh = io.open(UI .. rel, 'r')
    if not fh then
        fail(UI .. rel .. ' is missing')
        return nil
    end
    local s = fh:read('a')
    fh:close()
    return codeOfTs(s)
end

local vitals = readUi('hud/Vitals.tsx')
local vehicle = readUi('hud/VehicleBars.tsx')

-- ══════════════════════════════════ the two bars say what they are ════════

if vitals then
    -- THE CAPTIONS THEMSELVES. The words are the `title` attributes the row has
    -- carried since it was written, which is the same move VehicleBars made
    -- with Condition and Fuel -- nothing new was named, and the standing rule
    -- is that interface text is the owner's.
    if not vitals:find('label="Health"', 1, true) then
        fail('the health bar carries no caption',
             'the owner asked for "the same type text within the health/shield '
             .. 'bars" that the vehicle strip has')
    end
    if not vitals:find('label="Shield"', 1, true) then
        fail('the shield bar carries no caption', 'same request, same round')
    end

    -- ═══ THE ZERO RULE, WHICH IS WHAT THIS CHANGE COULD HAVE BROKEN ═══
    --
    -- The shield hides its numeral at 0, and that is deliberate: 0 means no
    -- shield, the empty bar says so by itself, and a lone "0" floating in an
    -- empty pill reads as debris. An empty TANK is the opposite -- it is the
    -- one reading a driver most needs.
    --
    -- THE OLD CONDITION ASKED THE WRONG QUESTION AND GOT THE RIGHT ANSWER BY
    -- LUCK. It was `value > 0 || label !== undefined`: the caption stood in for
    -- "this is a bar whose zero is a reading", which was true only while the
    -- vehicle bars were the only captioned ones in the game. Giving health and
    -- shield captions makes that proxy false, and the shield would have started
    -- printing a 0 as a SIDE EFFECT of a change about captions -- silently, and
    -- in the one place the rule exists to protect.
    -- READ OFF THE showNum EXPRESSION, NOT THE FILE. `label !== undefined` is
    -- still in Vitals.tsx and is still correct there -- it is what decides
    -- whether to render the caption ELEMENT at all. Searching the whole file
    -- for it fails on that line, which is this gate's own first draft.
    local showNum = vitals:match('const showNum%s*=([^\n]*)')
    if not showNum then
        fail('cannot find the showNum rule in Vitals.tsx',
             'reshape this gate with the component rather than deleting it')
    else
        if showNum:find('label') then
            fail('the numeral-at-zero rule still keys off the presence of a '
                 .. 'caption',
                 'health and shield have captions now, so that heuristic '
                 .. 'prints a 0 in an empty shield pill -- the exact thing it '
                 .. 'forbids: ' .. showNum)
        end
        if not showNum:find('zeroNum') then
            fail('the numeral-at-zero rule does not ask about zeroNum',
                 'the rule is real and split; it has to be asked directly '
                 .. 'rather than inferred from another prop: ' .. showNum)
        end
        -- AND IT IS STILL GATED ON `num` AT ALL. A rule that dropped that
        -- would print a numeral on the stamina bar, which passes neither.
        if not showNum:find('num') then
            fail('the numeral rule no longer asks whether a numeral was wanted',
                 'stamina passes no `num` and must stay a bare bar: ' .. showNum)
        end
    end
    if not vitals:find('zeroNum === true') then
        fail('Fill has no explicit control over drawing a zero',
             'the rule is real and split; it has to be asked directly rather '
             .. 'than inferred from another prop')
    end

    -- AND THE VITALS DO NOT OPT IN. Asserted on the two `<Fill>` calls rather
    -- than on the file, because `zeroNum` appears in the file legitimately --
    -- it is a declared prop. A health or shield bar that passed it would print
    -- the 0 this rule exists to hide.
    for _, bar in ipairs({ 'Health', 'Shield' }) do
        local call = vitals:match('<Fill[^>]-label="' .. bar .. '"[^>]->')
            or vitals:match('<Fill[^>]-' .. bar:lower() .. '[^>]->')
        if not call then
            fail(('cannot find the %s bar\'s <Fill> call to check it'):format(bar),
                 'reshape this gate with the component rather than deleting it')
        elseif call:find('zeroNum') then
            fail(('the %s bar opts in to drawing its zero'):format(bar),
                 'a dead player\'s 0 and an empty shield\'s 0 are states the '
                 .. 'empty bar already says; the numeral is debris')
        end
    end

    -- ═══ THE CAPTION SCALES AND THE NUMERAL DOES NOT ═══
    --
    -- That split is the HUD's existing rule rather than a preference: the
    -- player's text multiplier goes on prose and captions, which can grow
    -- without pushing anything off screen, and stays off fixed-size plates,
    -- where the extra line height simply clips.
    --
    -- `.micro-label` WITH `.ts` AND AN EXPLICIT --fs IS THE ONLY SPELLING THAT
    -- WORKS (#159). `.micro-label` declares its own font-size and is declared
    -- LATER in index.css than Tailwind's utilities, and bare `.tscale`
    -- multiplies 1em -- the PARENT's size -- so `micro-label tscale` ignores
    -- the slider entirely. index.css records that exact pair biting.
    if not vitals:find('micro%-label ts') then
        fail('the caption is not `micro-label ts`',
             'micro-label declares its own size, so bare tscale beside it '
             .. 'discards that size and the caption stops scaling (#159)')
    end
    if vitals:find('micro%-label tscale') or vitals:find('tscale micro%-label') then
        fail('the caption pairs micro-label with bare tscale (#159)',
             '`.ts` with an explicit --fs is the pairing that survives it')
    end
end

-- ═══════════════════════════════ the vehicle strip keeps its zero ═════════

if vehicle then
    -- THE OTHER HALF OF THE SPLIT, AND IT HAD TO BE MADE EXPLICIT IN THE SAME
    -- CHANGE. It used to come free from having a caption. It does not any more,
    -- so if this is dropped an empty tank silently stops reading -- which is
    -- the failure the rule was written for in the first place.
    if not vehicle:find('zeroNum') then
        fail('the vehicle bars no longer ask for their zero to be drawn',
             'an empty tank is the one number a driver most needs, and a blank '
             .. 'beside a caption reads as the number having failed')
    end
end

-- ══════════════════════════════════════════════ the bundle is the game ═══

do
    -- Same check and same reason as check_spectator_hud.lua's: ui-src is a
    -- source tree and br_ui/ui/assets/index.js is what FiveM serves.
    local fh = io.open('resources/[fivem-royale]/br_ui/ui/assets/index.js', 'r')
    if not fh then
        fail('the built UI bundle is missing')
    else
        local js = fh:read('a')
        fh:close()
        -- The caption strings are literals in the source and survive
        -- minification, so their absence means the bundle predates the change.
        if not js:find('label:"Shield"', 1, true)
            and not js:find('label: "Shield"', 1, true) then
            fail('the built bundle has no captioned shield bar',
                 'the bundle is stale. Run: cd ui-src && npm run build')
        end
    end
end

if failures > 0 then
    io.write(('\ncheck_vitals_bars: %d problem(s)\n'):format(failures))
    os.exit(1)
end

io.write('ok   health and shield name themselves inside the pill, the caption '
    .. 'scales\n     with the text slider, and a zero shield still draws no '
    .. 'numeral\n')
