-- Player identifiers, filtered to what this project is willing to hold.
--
-- FiveM hands out a list of identifiers per connection -- license, discord,
-- steam, and others -- and they are the only durable handle on a person. A name
-- changes, a server id is recycled within the minute, but a license survives
-- both. Moderation, bans and admin grants all key on these.
--
-- ALLOWLIST, NOT DENYLIST, and that is the load-bearing decision. **IP is not
-- collected** (user, 2026-08-08): it is the one identifier a player cannot
-- change, which makes it the most useful for catching ban evasion and also the
-- most sensitive thing we could hold -- and under GDPR it is personal data.
-- Writing that rule as "skip ip:" would leave whatever identifier type FiveM
-- adds next silently collected by default. Naming what we keep means anything
-- unanticipated is excluded by construction. Same reflex as the roster's
-- PUBLIC_FIELDS.
--
-- The cost is real and worth knowing: every identifier below is one a
-- determined evader can change. What survives still catches the common case --
-- the same Discord or Steam account reappearing under a new license.
--
-- Pure on purpose: parse() takes an array of strings and returns tables, so the
-- interesting part is testable outside the game. ofPlayer() is the thin native
-- wrapper over it.

BR = BR or {}

BR.Identity = {}

--- Identifier types we keep, in a FIXED ORDER.
---
--- The order is not decoration. This project's determinism rule is "never
--- iterate a hash" -- a Lua table's pairs() order is not stable, and anything
--- built by iterating one differs run to run. Consumers that need to walk
--- identifiers walk `ordered` from parse(), which follows this array.
---
--- `license2` is a genuinely different FiveM identifier from `license`, not a
--- variant of it, which is exactly why matching is exact rather than by prefix
--- (see parse). Both are kept.
BR.Identity.ALLOWED = {
    'license',
    'license2',
    'discord',
    'steam',
    'fivem',
    'xbl',
    'live',
}

-- Set form, built once from the array above. Membership only -- never iterated.
local ALLOWED_SET = {}
for _, k in ipairs(BR.Identity.ALLOWED) do
    ALLOWED_SET[k] = true
end

--- Split one raw identifier into its type and value.
---
--- Exact match on the segment before the FIRST colon. A prefix comparison would
--- quietly accept `license2:` as a `license`, which is not a cosmetic bug: it
--- would file two different identifiers under one key and make a ban lookup
--- match the wrong person.
---
--- @param raw string
--- @return string|nil kind
--- @return string|nil value
local function split(raw)
    if type(raw) ~= 'string' then return nil, nil end

    local colon = raw:find(':', 1, true)
    if not colon then return nil, nil end

    local kind  = raw:sub(1, colon - 1)
    local value = raw:sub(colon + 1)

    if kind == '' or value == '' then return nil, nil end

    return kind:lower(), value
end

--- Filter a raw identifier list down to the allowlist.
---
--- @param list table  array of raw identifier strings, e.g. { 'license:ab12', 'ip:1.2.3.4' }
--- @return table byKind   map of kind -> value, allowlisted types only
--- @return table ordered  array of { kind, value }, in ALLOWED order
--- @return number dropped how many entries were refused (unknown type, ip, malformed)
function BR.Identity.parse(list)
    local byKind, dropped = {}, 0

    for i = 1, #(list or {}) do
        local kind, value = split(list[i])

        if kind and ALLOWED_SET[kind] then
            -- First wins. A duplicate of the same kind is either a platform
            -- quirk or something being spoofed; either way the later one has
            -- no better claim than the earlier.
            if byKind[kind] == nil then
                byKind[kind] = value
            else
                dropped = dropped + 1
            end
        else
            dropped = dropped + 1
        end
    end

    local ordered = {}
    for _, k in ipairs(BR.Identity.ALLOWED) do
        if byKind[k] then
            ordered[#ordered + 1] = { kind = k, value = byKind[k] }
        end
    end

    return byKind, ordered, dropped
end

--- Every identifier FiveM reports for a connected player, unfiltered.
---
--- Server-side only -- these natives do not exist on the client. Separated from
--- parse() so the filtering logic stays testable without a game.
---
--- @param src number|string player server id
--- @return table array of raw identifier strings
function BR.Identity.rawOf(src)
    local out = {}
    local n = GetNumPlayerIdentifiers(src) or 0

    for i = 0, n - 1 do
        local id = GetPlayerIdentifier(src, i)
        if id then out[#out + 1] = id end
    end

    return out
end

--- Allowlisted identifiers for a connected player.
--- @param src number|string player server id
--- @return table byKind
--- @return table ordered
--- @return number dropped
function BR.Identity.ofPlayer(src)
    return BR.Identity.parse(BR.Identity.rawOf(src))
end

--- Put the type prefix back on a value from parse().
---
--- parse() strips it, because a map keyed `byKind.license` should not repeat
--- the word in the value. But FiveM's own wire format, and anything already
--- persisted against it, is the qualified `license:abc...` string -- br_stats'
--- primary key is exactly that. So the prefix has to be reattachable rather
--- than merely discarded, or adopting this module means rewriting every stored
--- row. Nil in, nil out, so callers can pass a lookup through without a guard.
---
--- @param kind string
--- @param value string|nil
--- @return string|nil
function BR.Identity.qualified(kind, value)
    if value == nil then return nil end
    return kind .. ':' .. value
end

--- The one identifier everything else keys on.
---
--- Returns nil when FiveM did not report a license, which does happen -- callers
--- decide whether that is fatal for them. Nothing should invent a fallback key:
--- a profile filed under a guessed identifier is worse than no profile.
---
--- @param src number|string
--- @return string|nil
function BR.Identity.licenseOf(src)
    local byKind = BR.Identity.ofPlayer(src)
    return byKind.license
end
