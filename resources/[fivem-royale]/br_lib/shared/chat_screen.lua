-- Screening one chat line: is there a link in it, and is it written in a script
-- this gamemode accepts.
--
-- WHY THIS FILE EXISTS SEPARATELY. The same split as combat_solve/damage and
-- evidence_buf/evidence: the wiring -- which event fires, who receives the
-- message, what the roster knows -- cannot be exercised outside the game, but
-- the DECISION can, and the decision here is the expensive one to get wrong.
--
-- ═══ THE COST OF A FALSE POSITIVE IS NOT SYMMETRICAL WITH A FALSE NEGATIVE ═══
--
-- A message this file refuses is SHADOWED, not bounced: the sender's own client
-- renders it exactly as if it went out and nobody else ever receives it (owner,
-- 2026-08-29, "the experience to the sender should look like it posted just
-- fine"). So a player wrongly caught here is never told, cannot adapt, and
-- spends the rest of the round talking to nobody -- and draws a moderation case
-- while doing it.
--
-- EVERY RULE BELOW IS THEREFORE BIASED TOWARDS LETTING THINGS THROUGH. Where a
-- pattern would catch a real advert and also catch a version number, a decimal,
-- a time, a ratio or a file name, the pattern loses. The strings this must not
-- flag are pinned case by case in tools/test_shared.lua, because "it did not
-- match the obvious URLs" proves nothing about the ones it must not match.

BR = BR or {}

BR.ChatScreen = {}

--- Why a line was refused. These strings reach a moderation record.
---
--- FIVE RATHER THAN TWO, BECAUSE A MODERATOR IS READING THEM. "A link" and "a
--- link to a URL shortener" are not the same finding: the second is somebody
--- hiding where they are sending people, which is advertising almost by
--- definition, while the first is often a player pasting a YouTube clip of their
--- own kill. The reason rides the timeline entry, so the case says which rule
--- fired without a human having to re-derive it from the text.
---
--- WIDENING THIS DID NOT TOUCH close.js, WHICH IS WORTH SAYING BECAUSE IT LOOKS
--- LIKE IT SHOULD HAVE. `reason` is stored there as `str(e?.reason, 32)` -- a
--- bounded free string, not a discriminator -- so only `kind` crosses the
--- two-language contract that tools/verify.sh pins. The Lua side is where a new
--- reason has to be declared, in BR.IncidentBuild.CHAT_REASON, which
--- `fromChat` refuses an unknown value against.
BR.ChatScreen.LINK      = 'link'
BR.ChatScreen.SHORTENER = 'shortener'
BR.ChatScreen.INVITE    = 'invite'
BR.ChatScreen.SOCIAL    = 'social'
BR.ChatScreen.SCRIPT    = 'script'

-- ---------------------------------------------------------------------------
-- Links
-- ---------------------------------------------------------------------------

--- ═══ THE TWO LISTS LIVE IN br_lib/config/chat.lua, NOT HERE ═══
---
--- The RULES are code and belong in this file; the LISTS are a thing somebody
--- has to keep up to date as new shorteners appear, and the owner should not
--- need a developer to add one (coordinator, 2026-08-30). So the domains sit in
--- config beside every other maintained table in this project, and this file
--- reads them.
---
--- BUILT LAZILY AND CACHED ONLY ONCE POPULATED -- the same shape as
--- `knownWeapons` in incident_build.lua, and for the same reason. br_lib's
--- config and shared files load in an order this file must not assume, and an
--- empty result means "the config is not up yet", never "there is nothing to
--- match". Caching an empty table would leave the filter dead for the life of
--- the process, silently, which is the failure mode this whole subsystem keeps
--- being written to avoid.
local lists = nil
local function screenLists()
    if lists then return lists end

    local cfg = BR.Config and BR.Config.ChatScreen
    if cfg == nil then return nil end

    local tld = {}
    for _, t in ipairs(cfg.tlds or {}) do tld[t] = true end

    -- AN ORDERED ARRAY, NOT A MAP, AND THAT IS NOT A STYLE CHOICE. A line may
    -- match two groups at once -- `youtu.be` is a social host and a shortener
    -- by shape -- and `pairs` over a map would pick whichever the hash order
    -- happened to reach first. The stored reason would then differ between two
    -- servers running identical code, and between two runs of the same test.
    -- The config's group order IS the precedence, written down where the owner
    -- can see it.
    local hosts = {}
    for _, group in ipairs(cfg.hosts or {}) do
        for _, h in ipairs(group.domains or {}) do
            hosts[#hosts + 1] = { host = h, reason = group.reason }
        end
    end

    local schemes = {}
    for _, group in ipairs(cfg.schemes or {}) do
        for _, p in ipairs(group.prefixes or {}) do
            schemes[#schemes + 1] = { prefix = p, reason = group.reason }
        end
    end

    if next(tld) == nil and #hosts == 0 then return nil end

    lists = { tld = tld, hosts = hosts, schemes = schemes }
    return lists
end

--- Is there a `label.tld` anywhere in this (already lowercased) string?
---
--- THE TLD MUST BE THE WHOLE RUN AFTER THE DOT, and that single rule is what
--- keeps the false-positive count down. `example.commander` reads `commander`
--- rather than `com`, so it does not match; `example.com/path` reads `com`,
--- because `/` is not a label character, so it does. Nothing here needs a
--- word-boundary escape, which Lua patterns do not have.
---
--- A LABEL CHARACTER MUST SIT IMMEDIATELY BEFORE THE DOT, so "the price is . com"
--- is a sentence rather than a domain.
--- @param s string  lowercased
--- @return boolean
local function hasDomain(s)
    local L = screenLists()
    if not L then return false end

    local i = 1
    while true do
        -- A PLAIN SEARCH FOR A LITERAL DOT, so the third argument is `.` and not
        -- `%.`. Passing an escaped pattern with plain=true looks careful and
        -- searches for a two-character string that never occurs, which is a
        -- rule that matches nothing while reading as though it matches
        -- everything -- this file's first draft did exactly that.
        local d = s:find('.', i, true)
        if not d then return false end

        local before = d > 1 and s:sub(d - 1, d - 1) or ''
        if before:match('%w') then
            local run = s:match('^([%w%-]+)', d + 1)
            if run and L.tld[run] then return true end
        end
        i = d + 1
    end
end

--- Is a NAMED host in this line, and what kind of host is it?
---
--- ═══ A SECOND SIGNAL, NOT A WIDER TLD LIST ═══
---
--- The owner, 2026-08-30: "any common link shorteners and discord invites should
--- trigger the refusal as well as well as social links". The tempting fix is to
--- add the shorteners' TLDs -- `.gd`, `.gl`, `.gy`, `.be`, `.me` -- and it is
--- wrong: those are ordinary country domains carrying ordinary traffic, and
--- `.me` in particular is the exclusion that keeps "call.me" safe. A host list
--- catches `is.gd` without touching `something.gd`, and `t.co` without touching
--- `taco.co`.
---
--- ═══ MATCHED ON HOST BOUNDARIES, WHICH IS THE ENTIRE DIFFICULTY ═══
---
--- A plain substring search would flag `notbit.ly` and `bit.lyrics`. So the
--- character on each side of the match must not be one a hostname label is made
--- of:
---
---   LEFT    anything that is not `[a-z0-9-]`, which deliberately INCLUDES a
---           dot -- `www.bit.ly` and `cdn.youtu.be` are the same host with a
---           subdomain in front, and both should match. `notbit.ly` has a `t`
---           there and does not.
---   RIGHT   anything that is not `[a-z0-9-]`, so `/`, `:`, a space or the end
---           of the line all qualify and `bit.lyrics` does not.
---
--- IT NEVER FIRES ON A BARE WORD, and that falls out of matching the whole host
--- rather than its first label: "meet me on twitch" contains no `twitch.tv` and
--- "check discord" contains no `discord.com`. Nothing here needs a special case
--- for the English word.
---
--- SCHEME AND `www.` NEED NO HANDLING EITHER. `https://bit.ly/x` contains
--- `bit.ly` with `/` on the left and `/` on the right; `www.bit.ly` contains it
--- with `.` on the left. Both are boundaries, so both match without this
--- function knowing what a scheme is.
--- @param s string  lowercased
--- @return string|nil  the group's reason, or nil
local function hostIn(s)
    local L = screenLists()
    if not L then return nil end

    for _, h in ipairs(L.hosts) do
        local from = 1
        while true do
            local a, b = s:find(h.host, from, true)
            if not a then break end

            local before = a > 1 and s:sub(a - 1, a - 1) or ''
            local after  = s:sub(b + 1, b + 1)
            if not before:match('[%w%-]') and not after:match('[%w%-]') then
                return h.reason
            end
            -- KEEP LOOKING FROM THE NEXT CHARACTER. One rejected occurrence does
            -- not mean the line is clean: "bit.lyrics and bit.ly" is one string
            -- whose first match fails the right-hand boundary and whose second
            -- passes it.
            from = a + 1
        end
    end
    return nil
end

--- Is there a link in this line?
---
--- FOUR SIGNALS, IN DESCENDING ORDER OF HOW UNAMBIGUOUS THEY ARE.
---
---   1. an explicit scheme -- `http://` or `https://`. Nothing else spells that.
---   2. a `www.` followed by anything alphanumeric.
---   3. a bare `label.tld` against the curated list above.
---   4. a dotted quad WITH A PORT.
---
--- THE PORT IN (4) IS REQUIRED AND THAT IS THE POINT. A bare `1.2.3.4` is
--- indistinguishable from a four-part version number, which is a thing people
--- type; `1.2.3.4:30120` is a FiveM server address and is not. Advertising an
--- address without its port is a false negative this accepts on purpose.
--- @param text string
--- @return boolean
function BR.ChatScreen.linkIn(text)
    if type(text) ~= 'string' or text == '' then return false end
    return BR.ChatScreen.linkReason(text) ~= nil
end

--- The same question, answered with WHICH rule fired.
---
--- THE NAMED HOST WINS OVER THE GENERIC DOMAIN, and the order is the whole
--- reason this function exists. `discord.gg/x` satisfies both the host list and
--- the `.gg` TLD; recording it as `link` would throw away the more specific and
--- more useful finding. So the host list is asked first, and only a line that no
--- named host explains falls through to the generic signals.
--- @param text string
--- @return string|nil  one of the reason constants, or nil
function BR.ChatScreen.linkReason(text)
    if type(text) ~= 'string' or text == '' then return nil end

    -- LOWERCASED ONCE, FOR ASCII ONLY. Lua's `lower` leaves every byte above
    -- 0x7F alone, which is exactly right here: the domain rules are ASCII and
    -- the accented text this must not disturb is somebody's name.
    local s = text:lower()

    -- A SCHEME FIRST OF ALL. `fivem://connect/<code>` names no host and has no
    -- dot in it, so nothing else in this function can see it.
    local L = screenLists()
    for _, sc in ipairs(L and L.schemes or {}) do
        if s:find(sc.prefix, 1, true) then return sc.reason end
    end

    local named = hostIn(s)
    if named then return named end

    if s:find('https?://') then return BR.ChatScreen.LINK end
    if s:find('www%.%w') then return BR.ChatScreen.LINK end
    if s:find('%d+%.%d+%.%d+%.%d+:%d') then return BR.ChatScreen.LINK end

    if hasDomain(s) then return BR.ChatScreen.LINK end
    return nil
end

-- ---------------------------------------------------------------------------
-- Scripts
-- ---------------------------------------------------------------------------

--- Decode one UTF-8 codepoint.
---
--- HAND-ROLLED RATHER THAN `utf8.codepoint`, for two reasons. The standard
--- function RAISES on a malformed string, and this is fed player input by
--- definition -- an error here would take down the chat handler rather than
--- refuse a message. And the answer this needs for a malformed byte is a
--- decision ("that is not text we accept"), not an exception.
---
--- @param s string
--- @param i integer  1-based byte index
--- @return integer|nil codepoint  nil when the sequence is malformed
--- @return integer next  the byte index to continue from
local function decode(s, i)
    local b1 = s:byte(i)
    if b1 == nil then return nil, i + 1 end
    if b1 < 0x80 then return b1, i + 1 end

    local n, cp
    if b1 >= 0xF0 and b1 <= 0xF4 then
        n, cp = 3, b1 - 0xF0
    elseif b1 >= 0xE0 and b1 <= 0xEF then
        n, cp = 2, b1 - 0xE0
    -- 0xC0 AND 0xC1 ARE EXCLUDED, NOT AN OVERSIGHT. They can only ever begin an
    -- overlong encoding -- a second spelling of a character that already has
    -- one -- which is the oldest way there is to smuggle an ASCII byte past a
    -- filter that decodes and a byte-wise check that does not.
    elseif b1 >= 0xC2 and b1 <= 0xDF then
        n, cp = 1, b1 - 0xC0
    else
        return nil, i + 1
    end

    for k = 1, n do
        local b = s:byte(i + k)
        if b == nil or b < 0x80 or b > 0xBF then return nil, i + k end
        cp = cp * 64 + (b - 0x80)
    end
    return cp, i + n + 1
end

--- The handful of punctuation marks outside Latin-1 that ordinary text carries.
--- Named one by one rather than as a range, because General Punctuation also
--- holds the zero-width and direction-override characters, which are invisible
--- and are only ever in a chat line to hide something.
local PUNCT = {
    [0x2010] = true, [0x2011] = true, [0x2012] = true, [0x2013] = true,
    [0x2014] = true, [0x2015] = true,
    [0x2018] = true, [0x2019] = true, [0x201A] = true,
    [0x201C] = true, [0x201D] = true, [0x201E] = true,
    [0x2026] = true, [0x20AC] = true,
}

--- Is this codepoint one this gamemode's chat accepts?
---
--- ═══ AN ALLOWLIST, BECAUSE THE OWNER ASKED FOR ONE ═══
---
--- "We also need to forbid all non-latin scripts" (2026-08-29). A blocklist of
--- Cyrillic, Greek, Arabic, Hebrew, CJK and Thai would answer the examples and
--- miss everything not on it; deny-by-default answers the sentence.
---
--- LATIN MEANS LATIN WITH ITS ACCENTS, AND THAT WAS THE OWNER'S SECOND ANSWER.
--- `é ñ ü å` and everything like them, because European players must be able to
--- write normally and to type their own names. So the allowance runs to the end
--- of Latin Extended-B (Polish, Czech, Hungarian, Romanian, Turkish, Baltic) and
--- picks up Latin Extended Additional as well (Vietnamese, Welsh), plus the
--- combining marks, because an accent may arrive composed or decomposed and the
--- two are the same word.
---
--- SYMBOLS AND EMOJI ARE ALLOWED, AND THIS IS AN INTERPRETATION RATHER THAN AN
--- INSTRUCTION -- flag it if it is wrong. An emoji is not a script; nobody
--- advertises a rival server in dingbats; and "gg 🔥" is a thing players type
--- constantly. Refusing it would shadow-ban an ordinary message and open a case
--- about it, which is the exact failure the header of this file is about.
--- @param cp integer
--- @return boolean
local function allowed(cp)
    -- Printable ASCII. The control characters never reach here -- chat.lua's
    -- sanitise collapses them -- and are not allowed if they ever do.
    if cp >= 0x20 and cp <= 0x7E then return true end

    -- Latin-1 Supplement, Latin Extended-A, Latin Extended-B.
    if cp >= 0xA0 and cp <= 0x24F then return true end
    -- Combining diacritical marks, for decomposed accents.
    if cp >= 0x300 and cp <= 0x36F then return true end
    -- Latin Extended Additional -- Vietnamese and Welsh.
    if cp >= 0x1E00 and cp <= 0x1EFF then return true end

    if PUNCT[cp] then return true end

    -- Arrows, miscellaneous symbols, dingbats and the emoji planes. See the
    -- note above: symbols are not a script.
    if cp >= 0x2190 and cp <= 0x21FF then return true end
    if cp >= 0x2600 and cp <= 0x27BF then return true end
    if cp >= 0x2B00 and cp <= 0x2BFF then return true end
    -- The joiner and the variation selectors, without which a two-part emoji
    -- arrives as two unrelated pictures.
    if cp == 0x200D or cp == 0xFE0E or cp == 0xFE0F then return true end
    if cp >= 0x1F000 and cp <= 0x1FAFF then return true end

    return false
end

--- Does this line contain a character from a script this gamemode does not take?
---
--- MALFORMED UTF-8 COUNTS AS ONE. A chat line is text or it is not; a broken
--- sequence is either a client sending something other than what it typed or a
--- deliberate attempt to be decoded two different ways by two readers. See
--- `clamp` below for the one way this server used to produce malformed bytes by
--- itself, which it no longer does.
--- @param text string
--- @return boolean
function BR.ChatScreen.nonLatinIn(text)
    if type(text) ~= 'string' then return false end

    local i, n = 1, #text
    while i <= n do
        local cp, nxt = decode(text, i)
        if cp == nil or not allowed(cp) then return true end
        i = nxt
    end
    return false
end

-- ---------------------------------------------------------------------------
-- The two together, and the truncation that must not trip them
-- ---------------------------------------------------------------------------

--- Cut a string to at most `maxBytes`, never through the middle of a character.
---
--- THIS EXISTS BECAUSE THE OBVIOUS `text:sub(1, max)` IS A BUG THE MOMENT THE
--- SCRIPT RULE ABOVE SHIPS. Lua's `sub` counts BYTES. A message at the length
--- limit whose 200th byte is the first half of an `é` was previously truncated
--- mid-character and rendered with a replacement glyph -- untidy, and nothing
--- more. With `nonLatinIn` reading the result, the same truncation produces a
--- malformed sequence, which is refused, which shadow-bans a European player for
--- writing a long sentence and opens a case about them.
---
--- So the server must not be the thing that breaks the encoding. The step-back
--- looks at the byte AFTER the cut: while it is a continuation byte, the cut is
--- inside a character and has to move left.
--- @param s string
--- @param maxBytes integer
--- @return string
function BR.ChatScreen.clamp(s, maxBytes)
    s = tostring(s or '')
    maxBytes = tonumber(maxBytes) or 0
    if maxBytes <= 0 then return '' end
    if #s <= maxBytes then return s end

    local cut = maxBytes
    while cut > 0 do
        local b = s:byte(cut + 1)
        if b == nil or b < 0x80 or b >= 0xC0 then break end
        cut = cut - 1
    end
    return s:sub(1, cut)
end

--- Why this line may not go out, or nil if it may.
---
--- THE LINK IS TESTED FIRST, so a Cyrillic advert with a domain in it reads as
--- a link tier rather than `script`. Both are true of that message and the link
--- is the one a reviewer is looking for. Within the link tiers a NAMED host
--- beats the generic domain rule -- see `linkReason`.
---
--- ═══ WHAT THIS DOES NOT CATCH, STATED SO NOBODY MISTAKES IT FOR COVERAGE ═══
---
--- A HOMOGLYPH BUILT OUT OF LATIN. `paypaI.com` with a capital i, or `rn` where
--- a reader sees `m`, is Latin throughout and passes the script rule; whether it
--- is refused depends entirely on whether the domain is one the list above
--- names. The owner was offered mixed-script detection -- flagging a WORD that
--- draws on two alphabets -- and chose the simpler rule, so a Cyrillic `а`
--- inside a Latin word is caught here only because `nonLatinIn` refuses that
--- character ANYWHERE, not because anything understands the substitution.
--- @param text string
--- @return string|nil  BR.ChatScreen.LINK, BR.ChatScreen.SCRIPT, or nil
function BR.ChatScreen.screen(text)
    if type(text) ~= 'string' or text == '' then return nil end

    local link = BR.ChatScreen.linkReason(text)
    if link then return link end

    if BR.ChatScreen.nonLatinIn(text) then return BR.ChatScreen.SCRIPT end
    return nil
end

--- The refusal reasons, for the tests and for whoever adds a sixth.
---
--- EVERY ONE OF THESE MUST HAVE A SENTENCE IN BR.IncidentBuild.CHAT_REASON, or
--- `fromChat` refuses to file the case it was raised for -- deliberately, so a
--- reason nobody has written English for cannot reach a moderation record.
--- tools/test_shared.lua walks this list against that table.
BR.ChatScreen.REASONS = {
    BR.ChatScreen.LINK,
    BR.ChatScreen.SHORTENER,
    BR.ChatScreen.INVITE,
    BR.ChatScreen.SOCIAL,
    BR.ChatScreen.SCRIPT,
}
