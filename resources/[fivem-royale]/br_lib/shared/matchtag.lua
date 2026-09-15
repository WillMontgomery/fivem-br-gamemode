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
-- THE ID IS A NUMBER AND STAYS A NUMBER (#291). It is a random 28-bit draw,
-- 0x0000001 to 0xFFFFFFF, minted in br_core/server/match.lua. Storing it as a
-- hex STRING was considered on the issue and rejected in detail: `tonumber`
-- would collapse two rng seeds to 0, BR.Voice.radioChannel would return nil and
-- silently kill every squad radio, sixty-eight `%d` sites would raise, br_ddb's
-- num() would flatten it to 0 and Ringmaster's `z.number().int()` would refuse
-- it outright -- which is byte for byte the 2026-09-04 ingest outage. Stored as
-- a number, displayed as hex, converted HERE and nowhere else.
--
-- SEVEN CHARACTERS, ZERO PADDED, LOWER CASE. Padding matters more than it
-- looks: the ids are a fixed-width space, so `000a3f1` and `a3f1` being the same
-- match written two ways is a difference somebody has to hold in their head
-- while reading a console. Every id this project SHOWS is seven characters wide.
--
-- ═══ WIDENED FROM FIVE ON 2026-09-12, AND THE REASON IS OUTSIDE THIS PROCESS ═══
--
-- `issuedIds` in match.lua guarantees an id is never reused FOR THE LIFE OF ONE
-- FXSERVER RUN and says so outright. It dies on restart. That was enough while a
-- match id was a thing printed in a console and forgotten -- but Ringmaster now
-- gives every match a PERMANENT URL keyed on this tag, so the question stopped
-- being "can two live matches collide" and became "can two matches the box has
-- EVER played collide", and the birthday bound over that history is the number
-- that matters. At 20 bits it reached even odds at roughly 1,200 matches, which
-- is a season. At 28 bits it reaches them past 19,000.
--
-- STORAGE WAS NEVER THE AMBIGUOUS PART. br-players keys history on
-- `match#<endedAt>#<matchId>` and br-matches keys on this tag, so the row was
-- always addressable; what repeated was the NAME, and the name is what people
-- paste to each other.
--
-- ═══ EVERY TAG PRINTED BEFORE TODAY IS STILL THE SAME MATCH ═══
--
-- THIS RENAMES EVERY MATCH ALREADY RECORDED, and there is no way to widen a
-- fixed-width rendering without doing so: `%07x` on an old id pads it, so the
-- match somebody has bookmarked as `d93aa` renders `00d93aa` from here on. That
-- is deliberate and it is the canonical spelling from now on.
--
-- NOTHING BREAKS, BECAUSE THE PARSER NEVER CARED ABOUT WIDTH. BR.MatchFromTag
-- below is base-16 `tonumber` with no length check, so `d93aa`, `0d93aa` and
-- `00d93aa` are one number -- leading zeroes have never carried meaning in hex.
-- Ringmaster's `matchFromTag` accepts 1..8 hex digits for the same reason, so
-- the live `/matches/d93aa` links keep resolving and there is no migration.
--
-- SO DO NOT "TIGHTEN" THE PARSER TO SEVEN CHARACTERS. It reads like a defence
-- against typos and it is actually a 404 on every link this project has ever
-- handed out. tools/test_roster.lua pins the short spellings for that reason.
--
-- `m.seq` IS NOT DISPLAYED AND HAS NO FORMATTER. It is the internal increment
-- that drives the routing bucket and the ordering; putting it on a screen would
-- give one match two numbers, which is the thing this file exists to prevent.

BR = BR or {}

--- The way a match id is written down: seven lower-case hex characters.
---
--- NO NIL GUARD, DELIBERATELY. Every call site here replaced a `%d` that would
--- have raised on the same input, and `%07x` raises for the same reasons `%d`
--- does -- nil, a string, a float with no integer representation. A guard would
--- turn a missing id into a plausible-looking `0000000`, which is the id
--- server/loot.lua reserves for the communal warmup pad: a bug that reads as a
--- fact. The failure mode is unchanged from before this file existed.
--- @param id integer
--- @return string
function BR.MatchTag(id)
    return ('%07x'):format(id)
end

--- Read a match id back off something a person typed.
---
--- FOR THE CONSOLE, which is the one place a match id travels in the other
--- direction: `/brloot a3f1` is somebody copying what the log just printed.
--- Base 16, because the printed form is the only form there is -- parsing it as
--- decimal would silently answer about a different match for any id made only
--- of digits, and about no match at all for the other fifteen sixteenths.
---
--- WIDTH-AGNOSTIC, AND THAT IS NOW LOAD BEARING RATHER THAN INCIDENTAL. It never
--- checked a length, which is what lets a five-character tag printed before
--- 2026-09-12 -- and every Ringmaster URL built from one -- resolve to exactly
--- the match it always named. See the header: rejecting a short tag would be a
--- 404 on every link this project has handed out, dressed up as validation.
--- @param s string|number|nil
--- @return integer|nil  nil when it is not a match id
function BR.MatchFromTag(s)
    if s == nil then return nil end
    local n = math.tointeger(tonumber(tostring(s), 16))
    if not n or n < 0 then return nil end
    return n
end
