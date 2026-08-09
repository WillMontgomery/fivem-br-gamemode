-- Display-name validation.
--
-- PURE, AND IN br_lib, so it can be unit tested and so the client and the
-- server run the SAME rule. The client runs it to refuse instantly -- a player
-- should learn their name is unavailable while they are still looking at the
-- field, not after a round trip. The server runs it because the client's copy
-- is a courtesy and the server's is the boundary; a modified client that skips
-- the check gets refused anyway.
--
-- WHAT IT IS FOR: a name is drawn over other people's screens, in their kill
-- feed and beside their chat. This is not censorship of what a player may say
-- to their friends -- it is the rule for a label everyone else is forced to
-- read.
--
-- HOW IT RESISTS THE OBVIOUS DODGES. Matching a literal wordlist catches
-- nobody: the first thing anyone tries is `f_u_c_k`, `fuuuck`, `phuck`, `fvck`,
-- `5hit`. So the candidate is NORMALISED first -- case folded, leetspeak
-- mapped back to letters, separators dropped, runs of a repeated letter
-- collapsed -- and the wordlist is matched against THAT. One normalisation
-- beats a hundred spellings.
--
-- IT WILL NEVER BE COMPLETE, AND THAT IS FINE. This is a speed bump against
-- casual offensiveness, not an adversarial filter; a determined person will
-- always get something through, and the answer to that is a report button and
-- a moderator (M9), not a longer list. What it MUST NOT do is reject ordinary
-- names, which is why the list is short, specific, and free of fragments that
-- appear inside innocent words.

BR = BR or {}

--- Leetspeak and lookalikes, mapped back to the letter they stand in for.
local FOLD = {
    ['0'] = 'o', ['1'] = 'i', ['3'] = 'e', ['4'] = 'a', ['5'] = 's',
    ['6'] = 'g', ['7'] = 't', ['8'] = 'b', ['9'] = 'g',
    ['@'] = 'a', ['$'] = 's', ['!'] = 'i', ['|'] = 'i', ['+'] = 't',
}

--- Reduce a name to the form the wordlist is written against.
---
--- Deliberately aggressive: it exists only to be matched, never to be shown.
---
--- `collapse` squashes runs of a repeated letter. It is OPTIONAL, and both
--- answers are needed -- see BR.ValidateName, which checks the blocklist
--- against the collapsed AND the uncollapsed form. Collapsing catches
--- `fuuuuck`; NOT collapsing is what keeps `poop` recognisable, since
--- collapsing it would leave `pop` and block `popular`.
--- @param s string
--- @param collapse boolean|nil
--- @return string
function BR.FoldName(s, collapse)
    s = tostring(s or ''):lower()

    -- Leetspeak first, so `5h1t` becomes `shit` before anything else runs.
    s = s:gsub('.', function(c) return FOLD[c] or c end)

    -- Everything that is not a letter is a separator, and separators are how
    -- `f.u.c.k` and `f u c k` hide. Drop them entirely.
    s = s:gsub('[^a-z]', '')

    -- Collapse runs: `fuuuuck` -> `fuck`. Applied AFTER the drop so that
    -- `f-u-u-c-k` also lands.
    --
    -- REPEATED `(.)%1`, NOT `(.)%1+`. Lua patterns do not accept a quantifier
    -- on a back-reference -- `%1+` is not "the captured character, one or
    -- more times", and the first version of this silently collapsed nothing
    -- at all (caught by the test for `fuuuuck`, which sailed through). Two at
    -- a time until it stops changing is the same result with a pattern Lua
    -- actually has.
    if collapse then
        local prev
        repeat
            prev = s
            s = s:gsub('(.)%1', '%1')
        until s == prev
    end

    return s
end

--- Ordinary words that happen to contain a blocked one.
---
--- THE SCUNTHORPE PROBLEM, and it is not hypothetical -- the test suite
--- caught this filter rejecting a real English town and a mushroom on its
--- first run. These are REMOVED from the folded name before it is scanned,
--- rather than being an exact-match allowlist, so `xXScunthorpeXx` passes too
--- while `fuckscunthorpe` still does not.
---
--- Short and English-centric on purpose. It will need adding to; that is the
--- expected maintenance for a filter of this kind, and it is cheap.
local INNOCENT = {
    'scunthorpe', 'shitake', 'penistone', 'clitheroe', 'lightwater',
    'assassin', 'assassins', 'assess', 'assessment', 'assemble', 'asset',
    'bass', 'bassline', 'class', 'classic', 'glass', 'grass', 'brass',
    'cocktail', 'cockpit', 'cockney', 'peacock', 'shuttlecock',
    'analyst', 'analysis', 'analogue', 'canal',
    'cumbria', 'cumberland', 'circumstance', 'document', 'accumulate',
    'titan', 'titanium', 'constitution', 'competition',
    'administrator', 'admiral',
}

--- Substrings that make a name unavailable, written in FOLDED form.
---
--- Every entry is checked as a SUBSTRING of the folded name, so each one must
--- be specific enough not to appear inside an ordinary word. `cum` is not
--- here for that reason -- it is inside "cucumber", "circumstance" and a
--- hundred others, and a filter that rejects "Cucumber" is a filter players
--- rightly mock. Collapsing runs also means a single letter of a word is
--- enough: `ass` folds to `as`, which is why the entry below is `asshole`
--- rather than `ass`.
local BLOCKED = {
    -- profanity
    'fuck', 'fvck', 'phuck', 'fuk', 'shit', 'bich', 'bitch', 'cunt',
    'asshole', 'bastard', 'wanker',
    'twat', 'prick', 'slut', 'whore', 'dickhed', 'dikhed',
    -- lavatory humour, which the owner named specifically
    'poop', 'turd', 'shiter', 'crap', 'fart', 'diarhea', 'anus', 'rectum',
    -- sexual
    'penis', 'vagina', 'dildo', 'boner', 'blowjob', 'handjob', 'jerkof',
    'masturbat', 'orgasm', 'porn', 'hentai', 'nsfw', 'creampie', 'titfuk',
    'bonerman', 'cock', 'tits', 'nipl', 'nutsak', 'testicl', 'scrotum',
    -- slurs and hate. Kept short on purpose: these are the ones that must
    -- never appear over another player's head, and none of them is a
    -- fragment of an innocent word.
    'nigr', 'niger', 'nigа', 'fagot', 'fagit', 'retard', 'trany', 'kike',
    'spic', 'chink', 'wetback', 'nazi', 'hitler', 'holocaust', 'kkk',
    -- impersonation. A name is drawn beside system text; one that claims to
    -- BE the system is a lie the interface would be telling for them.
    'admin', 'moderator', 'server', 'console', 'system', 'staf',
}

--- Validate a proposed display name.
---
--- @param raw string|nil
--- @return boolean ok
--- @return string|nil reason  player-facing, and specific enough to act on
--- @return string cleaned     what to store when ok
function BR.ValidateName(raw)
    local name = tostring(raw or '')
        :gsub('^%s+', ''):gsub('%s+$', '')
        -- Control characters and the punctuation our own feed wording uses: a
        -- name is drawn beside phrases like "[DEAD]" and the kill feed's own
        -- marks, and one that can forge those is a name that can lie about
        -- the state of the game.
        :gsub('[%c<>~^]', '')

    -- Empty is legal and means "use my platform name".
    if #name == 0 then return true, nil, '' end

    if #name < 3 then
        return false, 'Too short — 3 characters minimum.', name
    end
    if #name > 20 then
        return false, 'Too long — 20 characters maximum.', name
    end

    -- At least some letters, or "..." and "1234" become names.
    if not name:find('%a') then
        return false, 'Needs at least one letter.', name
    end

    -- TWO FORMS, AND THE BLOCKLIST IS NEVER COLLAPSED.
    --
    -- Collapsed catches padding (`fuuuuck` -> `fuck`). Uncollapsed is what
    -- keeps a word whose real spelling has a double letter recognisable:
    -- collapsing `poop` would leave `pop`, which is inside `popular`. Since
    -- the list itself is only ever written one way, a term can match either
    -- form and neither can produce the other's false positives.
    local forms = { BR.FoldName(name, false), BR.FoldName(name, true) }

    for i, folded in ipairs(forms) do
        -- Innocent words come OUT before anything is scanned, so a town or a
        -- mushroom does not have to argue with a wordlist.
        for _, good in ipairs(INNOCENT) do
            folded = folded:gsub(good, '')
        end
        forms[i] = folded
    end

    for _, bad in ipairs(BLOCKED) do
        if forms[1]:find(bad, 1, true) or forms[2]:find(bad, 1, true) then
            return false, 'That name is not available.', name
        end
    end

    return true, nil, name
end
