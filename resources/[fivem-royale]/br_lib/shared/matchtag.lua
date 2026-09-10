-- How a match id is written down.
--
-- ONE FUNCTION, ONE HOME, AND THAT IS THE WHOLE REASON THIS FILE EXISTS. There
-- are sixty-eight places in the gamemode that put a match id in front of a
-- person -- fifty-three of them the literal phrase `match %d` -- and the owner
-- asked (2026-09-09) for all of them to read as hex: "Why can't we display it
-- as hex everywhere?" Sixty-eight inline `('%05x'):format(...)` calls would be
-- the same answer written down sixty-eight times, and the next decision about
-- how a match is named would have to find all of them again.
--
-- THE ID IS A NUMBER AND STAYS A NUMBER (#291). It is a random 20-bit draw,
-- 0x00001 to 0xFFFFF, minted in br_core/server/match.lua. Storing it as a hex
-- STRING was considered on the issue and rejected in detail: `tonumber` would
-- collapse two rng seeds to 0, BR.Voice.radioChannel would return nil and
-- silently kill every squad radio, sixty-eight `%d` sites would raise, br_ddb's
-- num() would flatten it to 0 and Ringmaster's `z.number().int()` would refuse
-- it outright -- which is byte for byte the 2026-09-04 ingest outage. Stored as
-- a number, displayed as hex, converted HERE and nowhere else.
--
-- FIVE CHARACTERS, ZERO PADDED, LOWER CASE. Padding matters more than it looks:
-- the ids are a fixed-width space, so `0a3f1` and `a3f1` being the same match
-- written two ways is a difference somebody has to hold in their head while
-- reading a console. Every id this project ever shows is five characters wide.
--
-- `m.seq` IS NOT DISPLAYED AND HAS NO FORMATTER. It is the internal increment
-- that drives the routing bucket and the ordering; putting it on a screen would
-- give one match two numbers, which is the thing this file exists to prevent.

BR = BR or {}

--- The way a match id is written down: five lower-case hex characters.
---
--- NO NIL GUARD, DELIBERATELY. Every call site here replaced a `%d` that would
--- have raised on the same input, and `%05x` raises for the same reasons `%d`
--- does -- nil, a string, a float with no integer representation. A guard would
--- turn a missing id into a plausible-looking `00000`, which is the id
--- server/loot.lua reserves for the communal warmup pad: a bug that reads as a
--- fact. The failure mode is unchanged from before this file existed.
--- @param id integer
--- @return string
function BR.MatchTag(id)
    return ('%05x'):format(id)
end

--- Read a match id back off something a person typed.
---
--- FOR THE CONSOLE, which is the one place a match id travels in the other
--- direction: `/brloot a3f1` is somebody copying what the log just printed.
--- Base 16, because the printed form is the only form there is -- parsing it as
--- decimal would silently answer about a different match for any id made only
--- of digits, and about no match at all for the other fifteen sixteenths.
--- @param s string|number|nil
--- @return integer|nil  nil when it is not a match id
function BR.MatchFromTag(s)
    if s == nil then return nil end
    local n = math.tointeger(tonumber(tostring(s), 16))
    if not n or n < 0 then return nil end
    return n
end
