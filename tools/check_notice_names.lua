-- Static gate: a toast that names a player draws that name in bold, and no
-- player's name can ever carry formatting.
--
-- ═══ THE REQUEST ═══
--
-- Owner, 2026-08-31:
--
--   "Any time we mention a player by name in a toast their name should be
--    bold."
--
-- EVERY toast, not only the ones he wrote that day. That is a rule about a
-- CLASS of sentence rather than a list of them, so the thing that has to hold
-- is a property of the pipeline: a name reaches the page as its own piece, and
-- a call site that puts one inside the string is a regression that still reads
-- perfectly on screen.
--
-- The pipeline's own behaviour is asserted where it can be executed --
-- tools/test_shared.lua drives BR.Notice through every shape, including a
-- player called `**bold**`, `{b:x}` and `{key:brptt}`. This file is for the
-- properties no suite in this repo can run: the CALL SITES across four
-- resources, the TSX that draws the result, and the built bundle.
--
-- ═══ WHAT IS AIMED AT, AND WHY EACH WOULD NOT LOOK LIKE A MISTAKE ═══
--
--   A NAME FORMATTED INTO THE SENTENCE. `('%s is down!'):format(entry.name)` is
--   what every one of these call sites looked like until 2026-08-31, it is what
--   the next one will be written as, and the result is a perfectly correct
--   notice with no bold in it. Nothing breaks. The owner would have to notice
--   one row out of a dozen not matching the others.
--
--   BOLD BECOMING MARKUP. The obvious way to add emphasis to a string is `**`
--   or a `{b:...}` token, and both are forgeable BY THE PLAYER, because the
--   name is the one part of the sentence a player writes. `{key:brptt}` is safe
--   for the opposite reason -- its payload is a command name over a fixed
--   alphabet, from our source. A `{b:}` token would look like its sibling and
--   be nothing like it.
--
--   THE NAME GOING THROUGH KeyText. The prose halves must (several of our
--   sentences carry a `{key:}` hole); the name must not, or a player called
--   `{key:brptt}` draws a key cap in the middle of a sentence about them. The
--   two branches are three lines apart and the wrong one is a one-word edit.
--
--   THE SPLIT NOT SURVIVING THE WIRE. `parts` is the first non-scalar field on
--   the NOTIFY payload. br_core/client/state.lua forwards that payload field by
--   field on purpose, and a new field is exactly what gets left off.
--
--   THE BUNDLE GOING STALE. Every assertion below passes on a repository whose
--   ui-src was edited and never rebuilt, and the game would draw no bold at all
--   with a green verify. No other gate in this repo covers Notices.tsx.
--
-- Run standalone:  lua tools/check_notice_names.lua

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
--- raw-source search matches the explanation rather than the code. This one
--- needs it more than most -- br_lib/shared/notice.lua's header quotes
--- `**%s**`, `{b:...}` and `:format(` while explaining why none of them is used.
local function codeOf(src)
    src = src:gsub('%-%-%[%[.-%]%]', ' ')
    src = src:gsub('%-%-[^\n]*', '')
    return src
end

--- TypeScript/TSX with its comments removed.
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

-- ------------------------------------------------------------ the module ---

local notice = read(ROOT .. 'br_lib/shared/notice.lua', codeOf)
if notice then
    for _, fn in ipairs({ 'who', 'line', 'wire', 'clean' }) do
        if not notice:find('function BR%.Notice%.' .. fn .. '%(') then
            fail('br_lib/shared/notice.lua no longer defines BR.Notice.' .. fn,
                 'the four together are the pipeline: mark a name, split the '
                 .. 'sentence, unpack it for the wire, rebuild it on arrival')
        end
    end

    -- THE SPLIT IS ON THE FORMAT STRING AND NOTHING ELSE. The value is copied
    -- whole into a part; the moment anything runs a pattern over it -- gsub,
    -- find, match, gmatch -- there is a grammar for a name to break out of, and
    -- that is the entire thing this module exists to prevent.
    local body = notice:match('function BR%.Notice%.line.-\nend')
    if not body then
        fail('BR.Notice.line is no longer a recognisable function',
             'this gate reads the scanner out of it')
    else
        for _, verb in ipairs({ 'gsub', 'gmatch', 'match', 'find' }) do
            if body:find('%f[%w]' .. verb .. '%s*%(') then
                fail('BR.Notice.line runs `' .. verb .. '` over its input',
                     'the sentence is walked character by character on OUR '
                     .. 'format string and the values are never scanned. A '
                     .. 'pattern applied to an argument is a grammar a player '
                     .. 'name can be written to break')
            end
        end
        if not body:find('isWho%(') then
            fail('BR.Notice.line no longer asks whether a value is a name',
                 'the marker is a TABLE, which is what a player cannot supply. '
                 .. 'Inferring "every %s is a person" would bold the reason in '
                 .. '"%s\'s invite expired -- %s."')
        end
    end
end

-- IT IS LOADED WHEREVER IT IS SPOKEN. A resource that composes a notice
-- without pulling the module in indexes nil at the moment the sentence is
-- sent -- which is a hard error in the one code path that was trying to tell
-- the player something.
for _, res in ipairs({ 'br_core', 'br_ui' }) do
    local man = read(ROOT .. res .. '/fxmanifest.lua', codeOf)
    if man and not man:find('br_lib/shared/notice%.lua') then
        fail(res .. ' does not load br_lib/shared/notice.lua',
             'it composes or forwards a notice that names a player, and '
             .. 'BR.Notice is nil in a state that has not pulled the file in')
    end
end

-- ------------------------------------------------------- the four senders ---
--
-- Every path from Lua to the notice stack has to carry `parts`, or a sentence
-- that was split arrives flat and draws no bold. There are exactly four.

local broadcast = read(ROOT .. 'br_core/server/broadcast.lua', codeOf)
if broadcast then
    for _, fn in ipairs({ 'notify', 'notifyAll' }) do
        local body = broadcast:match('function BR%.Server%.' .. fn .. '.-\nend')
        if not body then
            fail('server/broadcast.lua no longer defines BR.Server.' .. fn)
        else
            if not body:find('BR%.Notice%.wire%(') then
                fail('BR.Server.' .. fn .. ' does not unpack a built notice',
                     'its `text` argument may be a string OR the table '
                     .. 'BR.Notice.line returns, and wire() is the one place '
                     .. 'that knows the difference')
            end
            -- THE UNPACK LINE IS REMOVED BEFORE LOOKING FOR THE FIELD.
            -- `local flat, parts = BR.Notice.wire(text)` contains the
            -- characters `parts =`, so a naive search for the payload key is
            -- satisfied by the line that merely PRODUCES it -- and passes a
            -- function that unpacks the notice and then drops half of it on the
            -- floor. Measured: that mutation went through green.
            local fields = body:gsub('local%s+flat,%s*parts%s*=[^\n]*', '')
            if not fields:find('parts%s*=') then
                fail('BR.Server.' .. fn .. ' does not put `parts` on the wire',
                     'the split sentence would arrive flat and the name would '
                     .. 'draw in the prose weight -- with nothing broken')
            end
        end
    end
end

local state = read(ROOT .. 'br_core/client/state.lua', codeOf)
if state then
    local notifyFn = state:match('function BR%.Notify.-\nend')
    if not notifyFn then
        fail('client/state.lua no longer defines BR.Notify')
    elseif not (notifyFn:find('BR%.Notice%.wire%(') and notifyFn:find('parts%s*=')) then
        fail('BR.Notify does not carry a built notice',
             'a client-composed notice names players too -- the party invite '
             .. 'is one -- and this is the same envelope the server builds')
    end

    -- THE FORWARDER. It rebuilds the payload field by field on purpose ("the UI
    -- should not be the thing that discovers a sender invented a field"), and
    -- `parts` is the first field on it that is not a scalar -- so it is cleaned
    -- rather than passed through.
    if not state:find('parts%s*=%s*BR%.Notice%.clean%(') then
        fail('the NOTIFY forwarder does not rebuild `parts` through clean()',
             'either it drops the field -- every server notice loses its bold '
             .. '-- or it forwards whatever arrived, which is the one place '
             .. 'this handler deliberately does not do that')
    end
end

-- ---------------------------------------------------- no name in a string ---
--
-- THE REGRESSION GATE. A toast whose text is built with `:format()` over
-- something called `name` is the shape every one of these call sites had before
-- the owner's rule, and it produces a correct-looking notice with the bold
-- silently gone.
--
-- SCANNED AS A WINDOW AFTER THE SEND, not as a whole file: `:format` with a
-- name in it is ordinary and correct in a `print`, and this project logs a name
-- on nearly every line it logs at all.

--- The five ways to reach the stack, and which bracket closes each one's
--- arguments. `(` for the three functions, `{` for the two that hand a payload
--- table to a generic trigger.
local SENDERS = {
    { pat = 'BR%.Server%.notify%(',    open = '(' },
    { pat = 'BR%.Server%.notifyAll%(', open = '(' },
    { pat = 'BR%.Notify%(',            open = '(' },
    { pat = 'BR%.Nui%.TOAST,',         open = '{' },
    { pat = 'BR%.Net%.NOTIFY,',        open = '{' },
}

--- The call's OWN arguments, and not one character more.
---
--- ═══ A FIXED WINDOW IS NOT GOOD ENOUGH, AND IT FAILS THE SAFE WAY ROUND ═══
---
--- The first version of this read a generous 400 characters after each sender
--- and reported six files. Every one was a false alarm: almost every notify in
--- this project is followed within a few lines by a `print` that logs the same
--- event WITH THE PLAYER'S NAME IN IT -- which is correct, is not a toast, and
--- is the single most common shape in the file being scanned. A gate that cries
--- wolf on the correct code gets its rule deleted rather than obeyed.
---
--- So the span is bracket-balanced, and STRING LITERALS ARE SKIPPED while
--- balancing -- `'Party is full (%d).'` is a real toast and an unbalanced-looking
--- one is a plausible future edit.
--- @param code string   comment-stripped source
--- @param from integer  index of the sender's own opening bracket, or just past
---                      the comma before a payload table
--- @param open string   '(' or '{'
--- @return string
local function argSpan(code, from, open)
    local close = (open == '(') and ')' or '}'
    local i, n = from, #code
    -- For the payload forms, walk to the table's own opening brace first.
    if code:sub(i, i) ~= open then
        local at = code:find(open, i, true)
        if not at then return '' end
        i = at
    end
    local start, depth = i, 0
    while i <= n do
        local c = code:sub(i, i)
        if c == '"' or c == "'" then
            -- Skip the literal whole. Lua long strings are not used for copy
            -- anywhere in this project; if one ever is, this stops at its first
            -- quote and the window is short, which reports nothing rather than
            -- reporting nonsense.
            local q = c
            i = i + 1
            while i <= n do
                local d = code:sub(i, i)
                if d == '\\' then i = i + 1
                elseif d == q then break
                elseif d == '\n' then break end
                i = i + 1
            end
        elseif c == open then
            depth = depth + 1
        elseif c == close then
            depth = depth - 1
            if depth == 0 then return code:sub(start, i) end
        end
        i = i + 1
    end
    return code:sub(start, math.min(n, start + 400))
end

--- THE FILE LIST COMES IN ON ARGV, from verify.sh's own `find`.
---
--- This repo's rule, and tools/test_config.lua states the reason: Lua cannot
--- list a directory without io.popen, which spawns cmd.exe on this box -- so a
--- gate's coverage would depend on which shell happened to run it.
--- check_forward_locals.lua and check_bool_natives.lua are both fed the same
--- way. An EMPTY list is a failure below rather than a pass.
local scanned, sites = 0, 0
for _, path in ipairs({ ... }) do
    local src = readRaw(path)
    if src then
        scanned = scanned + 1
        local code = codeOf(src)
        for _, sender in ipairs(SENDERS) do
            local at = 1
            while true do
                local a, b = code:find(sender.pat, at)
                if not a then break end
                sites = sites + 1
                local window = argSpan(code, b, sender.open)

                if window:find(':format%(') then
                    -- `[%w%.]*[Nn]ame` catches name, rName, entry.name,
                    -- target.name, displayName. `gamertag` is the other
                    -- spelling this roster uses for the same thing.
                    local named = window:find('%f[%w][%w%.]*[Nn]ame%f[%W]')
                        or window:find('gamertag')
                    -- item.name is an ITEM and must NOT be bold -- "Carbine
                    -- Rifle equipped." is not a person, and neither is the
                    -- armour plate's `c.label`. Named explicitly rather than
                    -- guessed at from the variable.
                    local isItem = window:find('item%.name')
                        or window:find('c%.label')
                    if named and not isItem then
                        fail(('%s formats a name into a toast'):format(path),
                             'the owner\'s rule is that a player\'s name in a '
                             .. 'toast is bold, and the page can only draw a '
                             .. 'name it was handed as its own piece. Compose '
                             .. 'it with BR.Notice.line and BR.Notice.who -- '
                             .. 'see br_lib/shared/notice.lua')
                    end
                end
                at = b + 1
            end
        end
    end
end

if scanned == 0 then
    fail('the call-site scan found no Lua files at all',
         'the directory walk failed, so this gate proved nothing. It is not a '
         .. 'pass')
end
if sites < 30 then
    fail(('the call-site scan found only %d senders'):format(sites),
         'there are over fifty in this repo. A pattern that stopped matching '
         .. 'would pass this file silently, which is the failure mode a gate '
         .. 'must not have')
end

-- ------------------------------------------------------------- the page ---

local notices = read(UI .. 'hud/Notices.tsx', codeOfTs)
local CLASS = nil
if notices then
    if not notices:find('export function NoticeText') then
        fail('hud/Notices.tsx no longer exports NoticeText',
             'both surfaces that draw a notice -- the live stack and the pause '
             .. 'menu\'s history -- go through it, so the owner\'s rule holds '
             .. 'in one place or in neither')
    end

    -- ANCHORED ON `\n}\n` AND NOT `\n}`. The parameter list is a destructured
    -- object with its own type annotation, so the component's fourth line is
    -- `}) {` -- and a non-greedy match for a closing brace at the start of a
    -- line stops there, handing back a body with none of the rendering in it.
    local body = notices:match('export function NoticeText.-\n}\n')
    if not body then
        fail('NoticeText is no longer a recognisable component')
    else
        CLASS = body:match('<b[^>]-className="([%w%-]+)"')
        if not CLASS then
            fail('NoticeText no longer draws a name in a classed bold element',
                 'the weight lives in index.css as a design-system fact, and '
                 .. 'the class is what proves the shipped bundle was built '
                 .. 'from this file')
        end

        -- THE NAME MUST NOT GO THROUGH KeyText. The prose halves must. Both
        -- branches are in this component and the wrong one is a one-word edit
        -- -- after which a player called `{key:brptt}` draws a key cap.
        --
        -- `<b.-</b>` AND NOT A BRACE-COUNTING PATTERN. This was
        -- `<b[^>]->{[^}]-}</b>`, which cannot match a child that has a brace of
        -- its own -- and `{<KeyText text={p.b} />}` is exactly such a child, so
        -- the pattern returned nil, the guard below was skipped and the
        -- mutation shipped green. Measured. A pattern that stops matching is
        -- indistinguishable from a pass, which is the failure a gate must not
        -- have; hence the `not nameBranch` arm as well.
        local nameBranch = body:match('<b.-</b>')
        if not nameBranch then
            fail('NoticeText no longer draws the name in a <b> element',
                 'this gate reads that element to prove the name is a plain '
                 .. 'text child. Without it there is nothing to check')
        elseif nameBranch:find('KeyText') then
            fail('a player\'s name is rendered through KeyText',
                 'KeyText substitutes `{key:command}` tokens, and a name is '
                 .. 'the one string on this page a PLAYER wrote. It must be a '
                 .. 'plain text child and nothing else')
        end
        if not body:find('KeyText') then
            fail('NoticeText no longer renders the prose through KeyText',
                 'several of our own sentences carry a `{key:}` hole -- the '
                 .. 'voice notice, the sticky one over the big map -- and they '
                 .. 'would start drawing the token as letters')
        end
    end

    -- BOTH SURFACES. The history draws the same sentence a minute later; a name
    -- bold in one and not the other is one rule half-applied.
    if not notices:find('<NoticeText') then
        fail('the live notice stack does not draw through NoticeText')
    end
end

local log = read(UI .. 'screens/NoticeLog.tsx', codeOfTs)
if log and not log:find('<NoticeText') then
    fail('the pause menu\'s notice history does not draw through NoticeText',
         'it is the same sentence read later, and it draws "the same object as '
         .. 'the live notice" by its own comment')
end

-- THE SPLIT SURVIVES THE STORE. `parts` rides ToastPayload, so the live stack
-- gets it by spreading; the LOG's row shape is written out field by field and
-- is where it would be dropped.
local store = read(UI .. 'store/index.ts', codeOfTs)
if store then
    local logFn = store:match('const logNotice =.-\n  }')
    if logFn and not logFn:find('parts') then
        fail('the notice log does not carry `parts`',
             'the log row is built field by field, so a sentence that was '
             .. 'split arrives in the history flat and unbolded')
    end
end

-- ------------------------------------------------------------- the bundle ---
--
-- ui-src is a SOURCE tree; br_ui/ui/assets/index.js is what the game loads and
-- it is committed. Every assertion above passes on a repository whose bundle
-- was never rebuilt, and the game would draw no bold at all.

do
    local js = readRaw(ROOT .. 'br_ui/ui/assets/index.js')
    local css = readRaw(ROOT .. 'br_ui/ui/assets/index.css')

    -- THE CLASS IS READ OUT OF THE SOURCE rather than spelled out here, which
    -- is the difference between "a bold name was built once" and "THIS one is
    -- the one that ships". check_squad_key.lua learned it: a literal is
    -- satisfied by a bundle built before the last edit.
    if CLASS then
        if js and not js:find(CLASS, 1, true) then
            fail('the built bundle does not contain the notice name class',
                 'the bundle is stale. Run: cd ui-src && npm run build')
        end
        if css and not css:find('.' .. CLASS, 1, true) then
            fail('the built stylesheet has no rule for the notice name class',
                 'the class is on the element and nothing makes it bold, which '
                 .. 'is the one failure here that looks exactly like success')
        end
    end
end

if failures > 0 then
    io.write(('\ncheck_notice_names: %d problem(s)\n'):format(failures))
    os.exit(1)
end

io.write(('ok   a toast that names a player carries the name as its own piece all\n'
    .. '     the way to the page, where it draws bold and is never parsed -- %d\n'
    .. '     sender(s) in %d file(s) checked, none formatting a name into a\n'
    .. '     sentence\n'):format(sites, scanned))
