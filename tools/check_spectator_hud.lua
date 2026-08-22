-- Static gate: a spectator's HUD describes the player on screen.
--
-- ═══ THE BUG ═══
--
-- "the health/shield/inventory don't show properly. They should be fully
-- populated" -- the owner, from the playtest. They WERE populated. They were
-- populated with the dead viewer's own numbers -- zero health, zero shield, an
-- inventory that dying had cleared -- because the camera changed subject and
-- the HUD did not.
--
-- ═══ WHY A TEXT GATE, AND WHAT IS TESTED PROPERLY ELSEWHERE ═══
--
-- The INVENTORY half has a real behaviour test: tools/test_client.lua loads
-- client/inventory.lua, fires the feed event and reads the envelope that comes
-- out. That is the better instrument and it is used where it reaches.
--
-- The other two halves it cannot reach:
--
--   client/state.lua  is loaded by one suite (tools/test_roster.lua) and not by
--                     the one that owns the inventory, so the vitals
--                     substitution has no home to be driven from.
--
--   server/spectate.lua's feed is not a value at all. What matters about it is
--                     WHERE the inventory goes -- one recipient, chosen by a
--                     policy already applied -- and "it was not broadcast" is
--                     not something a suite can observe.
--
-- So this reads them as text, and it is aimed at the two mistakes that would
-- not look like mistakes: a second copy of health on the wire, and an
-- inventory that leaves the server to anybody but the one watcher.
--
-- Run standalone:  lua tools/check_spectator_hud.lua

local ROOT = 'resources/[fivem-royale]/'

local failures = 0

local function fail(msg, why)
    failures = failures + 1
    io.write('FAIL  ', msg, '\n')
    if why then io.write('      ', why, '\n') end
end

--- Source with comments stripped. Every file this reads explains itself at
--- length and names the very calls being looked for -- including this gate's
--- own reasoning quoted back into them -- so a check satisfied by prose would
--- pass on a file that had deleted the code and kept the essay.
local function codeOf(src)
    src = src:gsub('%-%-%[%[.-%]%]', ' ')
    src = src:gsub('%-%-[^\n]*', '')
    return src
end

local function read(rel)
    local fh = io.open(ROOT .. rel, 'r')
    if not fh then
        fail(rel .. ' is missing')
        return nil
    end
    local s = fh:read('a')
    fh:close()
    return s
end

-- ------------------------------------------------- health and shield, client ---

local state = read('br_core/client/state.lua')
if state then
    local code = codeOf(state)

    -- THE HUD ASKS WHO IS BEING WATCHED. Without this the bars are the dead
    -- viewer's, which is the reported bug exactly.
    --
    -- THE WHOLE EXPRESSION IS PINNED, NOT THE NAME. `BR.Spectate.targetSrc`
    -- appearing somewhere is not the claim -- `local watching = nil and
    -- BR.Spectate.targetSrc` contains it, never calls it, and puts the bug
    -- straight back while every mention of the function is still in the file.
    -- That mutation escaped this gate's first draft.
    if not code:find('local watching = BR%.Spectate and BR%.Spectate%.targetSrc')
        or not code:find('BR%.Spectate%.targetSrc%(%)') then
        fail('client/state.lua does not CALL BR.Spectate.targetSrc() for the HUD',
             'the HUD would go back to drawing the dead viewer\'s own vitals')
    end

    -- IT READS THE ROSTER MIRROR, NOT A SECOND WIRE. `hp` and `armour` are
    -- already in roster.lua's PUBLIC_FIELDS and already arrive for every player
    -- in the match, so asking the server to send them again down the spectate
    -- feed would be two representations of one fact -- and the second one would
    -- be the one that goes stale.
    if not code:find('S%.roster%[watching%]') then
        fail('the spectated vitals do not come from the roster mirror',
             'a second copy of a public fact is this project\'s signature bug')
    end

    -- WHO THE BARS ARE ABOUT IS PART OF THE DEDUPE. BR.PushHud only sends when
    -- a value changed; two squadmates on the same health are the same numbers,
    -- so without this a cycle to the next target sends nothing and the HUD
    -- keeps describing the previous one.
    if not code:find('watching == lastPush%.watching') then
        fail('the HUD dedupe does not include WHO is being watched',
             'stepping to a target on identical health would not repaint')
    end
end

-- ------------------------------------------------------- the target's ped ---

local spec = read('br_core/client/spectate.lua')
if spec then
    local code = codeOf(spec)

    if not code:find('function BR%.Spectate%.targetSrc') then
        fail('client/spectate.lua does not expose the target',
             'client/state.lua reads it behind a nil-guard, so a rename here '
             .. 'fails OPEN: the HUD silently goes back to the viewer\'s vitals')
    end

    -- A CHANGE OF SUBJECT FORCES A REPAINT. Same argument as the dedupe above,
    -- from the other end.
    if not code:find('BR%.PushHud%(true%)') then
        fail('a change of spectate target does not force a HUD push')
    end

    -- THE TARGET'S NAME REACHES THE INTERFACE. It is the X in the owner's
    -- "SPECTATING X", and this envelope is the only thing that carries it --
    -- the hint has no other source for who is on screen, so dropping this field
    -- leaves the line reading "SPECTATING " with nothing after it.
    if not code:find('name%s*=%s*session and session%.name') then
        fail('the spectate envelope no longer carries the target\'s name',
             'the on-screen hint would read "SPECTATING" with nothing after it')
    end

    -- AND THE INVENTORY IS FORWARDED RATHER THAN DECODED HERE. This file owns a
    -- camera; the bar is somebody else's business.
    --
    -- BOTH EDGES, COUNTED. The event name appears TWICE for two different
    -- reasons -- the forward on a push that carries one, and the explicit clear
    -- when a session stops -- so "the string is in the file" is satisfied by
    -- either one alone. Deleting the forward and keeping the clear leaves a bar
    -- that never fills; deleting the clear and keeping the forward leaves a
    -- player staring at the last loadout they watched. Both escaped a version
    -- of this gate that only looked for the name.
    if not code:find("TriggerEvent%('br:spectate:inv', d%.inv%)") then
        fail('the target\'s inventory is not forwarded to the inventory module',
             'the bar would never be given anything to draw')
    end
    if not code:find("TriggerEvent%('br:spectate:inv', nil%)") then
        fail('a session ending does not clear the spectated inventory',
             'the viewer would keep the last watched player\'s bar')
    end
end

-- --------------------------------------------------------- the server feed ---

local server = read('br_core/server/spectate.lua')
if server then
    local code = codeOf(server)

    if not code:find('BR%.Inv%.publicFor') then
        fail('the spectate feed never reads the target\'s inventory',
             'the bar has nothing to draw and goes back to the empty one')
    end

    -- ═══ THE ASSERTION THIS FILE EXISTS FOR ═══
    --
    -- An inventory is NOT in roster.lua's PUBLIC_FIELDS and must never become
    -- public: what somebody is holding is exactly what a wallhack wants. It may
    -- leave the server only on the spectate event, addressed to the ONE watcher
    -- whose right to look at this player the server has already decided.
    --
    -- A BROADCAST IS THE FAILURE. TriggerClientEvent(..., -1, ...) in this file
    -- would hand every client in the server the loadout of everybody being
    -- watched, and it would look completely correct in game -- the bar would
    -- fill in, the playtest would pass, and the leak would be invisible.
    if code:find('TriggerClientEvent%s*%(%s*[^,]+,%s*%-1') then
        fail('server/spectate.lua broadcasts to every client',
             'an inventory is not public; it goes to the one watcher the '
             .. 'server chose and to nobody else')
    end

    -- THE FEED DEDUPES. Late in a match most of the lobby is dead and watching
    -- somebody; sending five slots per session per tick anyway is the whole
    -- roster's inventory crossing the wire 4 Hz for the rest of the round.
    -- THE SIGNATURE IS COMPUTED FROM THE INVENTORY AND COMPARED TO THE STORED
    -- ONE. Both halves are pinned: `invSig` merely APPEARING is satisfied by
    -- the function's own definition, so a body that computed something else --
    -- a timestamp, a counter, a random -- would keep the name, keep the field,
    -- and send the whole payload on every tick anyway. That escaped this gate's
    -- first draft.
    if not code:find('local sig = invSig%(inv%)')
        or not code:find('sig ~= s%.invSig') then
        fail('the inventory is sent on every feed tick with no working dedupe',
             'client/state.lua makes the same argument about the HUD -- "600 '
             .. 'pointless messages a minute"')
    end

    -- A NEW TARGET RESENDS UNCONDITIONALLY. The signature is derived from
    -- CONTENTS, so two squadmates holding the same rifle produce the same one --
    -- and the push after a cycle would then send nothing, leaving the bar
    -- showing the player just stepped off.
    if not code:find('s%.invSig = nil') then
        fail('cycling to a new target does not force the inventory to resend',
             'two targets with identical loadouts would leave the bar stale')
    end
end

-- -------------------------------------------------------------- the client bar ---

local inv = read('br_core/client/inventory.lua')
if inv then
    local code = codeOf(inv)

    if not code:find('spectated or inv') then
        fail('the inventory bar does not substitute the spectated inventory',
             'this is the one place the swap may happen -- the interface has no '
             .. 'notion of spectating and must not grow one')
    end
end

-- --------------------------------------------------- the on-screen hint (#4) ---
--
-- "There's no pointers to tell me what buttons to press for next/last spectate
-- target. That should be shown at the bottom center (not overlapping with our
-- 'Currently talking' text and scaling properly with our player's preferences)
-- and look like a button but not have a mouse required. Also some text that
-- says 'SPECTATING X' would be helpful above those buttons." -- the owner.
--
-- The POSITION was verified by measuring the rendered boxes in the dev harness;
-- what is pinned here are the properties a later edit could quietly undo.

local UI = 'ui-src/src/'

--- TypeScript/CSS source with its comments removed.
---
--- NOT OPTIONAL, AND THE REASON IS THIS FILE'S OWN FIRST DRAFT. The components
--- being checked explain themselves at length and QUOTE THE VERY TOKENS being
--- searched for -- SpectateHint's header says "never bare `.tscale`" and "what
--- it is NOT is a real button element". Read raw, the `tscale` assertion below
--- failed on a file that does not use tscale, because the prose saying so
--- contains the word.
---
--- The same trap is live in ui-src/scripts/check-ui.mjs, which matches
--- `<button` against raw source: a comment mentioning the tag trips its R3 rule
--- and a commented-out button would satisfy it. Worth fixing there; out of
--- scope here, and noted so the next reader does not rediscover it.
local function codeOfTs(src)
    src = src:gsub('/%*.-%*/', ' ')        -- block and JSDoc comments
    src = src:gsub('//[^\n]*', '')          -- line comments
    return src
end

--- CSS with its comments removed -- BLOCK COMMENTS ONLY.
---
--- CSS has no `//` comment, and running the TypeScript stripper over a
--- stylesheet would eat everything after the `//` in any `url(https://...)`.
--- Two languages, two strippers, rather than one that is subtly wrong on one of
--- them.
local function codeOfCss(src)
    return (src:gsub('/%*.-%*/', ' '))
end

local function readUi(rel)
    local fh = io.open(UI .. rel, 'r')
    if not fh then
        fail(UI .. rel .. ' is missing')
        return nil
    end
    local s = fh:read('a')
    fh:close()
    return rel:sub(-4) == '.css' and codeOfCss(s) or codeOfTs(s)
end

do
    local code = readUi('hud/SpectateHint.tsx')
    if code then
        -- THE OWNER'S STRING, VERBATIM. Not "Spectating" and not "Watching".
        if not code:find('SPECTATING {', 1, true) then
            fail('the hint no longer says SPECTATING X in the owner\'s words')
        end

        -- THE KEYS ARE READ FROM THE REAL BINDINGS, BY COMMAND NAME.
        --
        -- The arrows are rebindable, and keybinds.lua resolves a conflict in
        -- favour of the NEW binding -- so a player who puts something else on
        -- the right arrow leaves `brspecnext` unbound. A hint with the glyph
        -- baked in would name a key that does nothing, which is worse than no
        -- hint at all.
        if not code:find("command: 'brspecnext'", 1, true)
            or not code:find("command: 'brspecprev'", 1, true) then
            fail('the hint does not name the spectate commands',
                 'it must look its glyphs up rather than hardcode arrows')
        end
        if not code:find('keybinds%.find') then
            fail('the hint does not resolve its keys from the keybinds list',
                 'a hardcoded arrow is wrong the moment somebody rebinds it')
        end

        -- IT LOOKS LIKE A BUTTON AND IS NOT ONE. No button element, no click
        -- handler, and the whole block is pointer-events:none -- a spectating
        -- player has no cursor, because spectating deliberately never joins the
        -- focus stack (client/spectate.lua argues why).
        if code:find('onClick') or code:find('<butt' .. 'on') then
            fail('the spectate hint has become clickable',
                 'the owner asked for something that looks like a button and '
                 .. 'needs no mouse; a spectator has no cursor to give it')
        end
        if not code:find('pointer%-events%-none') then
            fail('the spectate hint does not set pointer-events-none')
        end

        -- IT SCALES WITH THE PLAYER'S TEXT-SIZE PREFERENCE, AND VIA `.ts`.
        --
        -- #159 is the open issue about elements that ignore the preference.
        -- Bare `tscale` multiplies 1em -- the PARENT's size -- so on an element
        -- that declares its own --fs it silently throws that value away. Every
        -- sized element here uses `.ts` with an explicit --fs, which is the
        -- documented pairing.
        if not code:find("%['%-%-fs' as string%]") then
            fail('the hint declares no --fs, so it cannot scale with the '
                 .. 'player\'s text-size preference (#159)')
        end
        if code:find('tscale') then
            fail('the hint uses bare `tscale` alongside a declared size (#159)',
                 '`tscale` multiplies the PARENT font size and discards --fs; '
                 .. '`.ts` is the pairing that works')
        end
    end
end

do
    -- THE CLEARANCE IS ONE FACT, NOT TWO. The hint stacks above the talking
    -- line, so it has to know how tall that line is -- and TalkingBar has to be
    -- reading the same number, or the two drift into an overlap that only
    -- appears while somebody is speaking.
    local css = readUi('index.css')
    if css and not css:find('%-%-talkline%-h') then
        fail('index.css no longer derives --talkline-h',
             'the hint\'s clearance over the talking line would become a '
             .. 'hand-copied literal')
    end
    -- BOUNDED TO THE DECLARATION with [^;], not `.-`. Lua's lazy match spans
    -- newlines, so `--talkline-h:.-var(--text-scale)` was satisfied by the
    -- property being present and `var(--text-scale)` appearing ANYWHERE later
    -- in a 1,500-line stylesheet -- it passed happily against a hardcoded
    -- `--talkline-h: 1.5rem`. That mutation escaped this gate's first draft.
    if css and not css:find('%-%-talkline%-h:[^;]-var%(%-%-text%-scale%)') then
        fail('--talkline-h does not scale with --text-scale',
             'the talking line grows with the preference and the clearance '
             .. 'over it has to grow too, or it overlaps at the large setting')
    end
    local talk = readUi('hud/TalkingBar.tsx')
    if talk and not talk:find('var%(%-%-talkline%-fs%)') then
        fail('TalkingBar no longer reads --talkline-fs',
             'it would be sizing itself from a literal while the hint clears a '
             .. 'variable -- two spellings of one number')
    end
end

do
    -- THE BUNDLE IS THE THING THE GAME LOADS.
    --
    -- ui-src is a SOURCE tree; br_ui/ui/assets/index.js is what ships, and it
    -- is committed. Editing a component without rebuilding leaves a repository
    -- where every source assertion above passes and the game shows the old
    -- interface -- which is precisely why verify.sh already greps this bundle
    -- for the voice defaults. Same check, same reason.
    local fh = io.open(ROOT .. 'br_ui/ui/assets/index.js', 'r')
    if not fh then
        fail('the built UI bundle is missing')
    else
        local js = fh:read('a')
        fh:close()
        if not js:find('SPECTATING', 1, true) then
            fail('the built bundle does not contain the spectate hint',
                 'the bundle is stale. Run: cd ui-src && npm run build')
        end
    end
end

if failures > 0 then
    io.write(('\ncheck_spectator_hud: %d problem(s)\n'):format(failures))
    os.exit(1)
end

io.write('ok   a spectator\'s HUD reads the watched player -- vitals off the '
    .. 'public roster,\n     inventory off the session feed, sent to one '
    .. 'watcher and deduped\n')
