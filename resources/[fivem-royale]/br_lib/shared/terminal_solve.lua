-- Season 2 terminals (#396): the rules the server and every client both read.
--
-- ONE SPELLING OF EACH, because two would have to agree forever. A client
-- draws a terminal's plate and blip off these answers and the server rules a
-- use or a run off the same ones, so "online" means one thing on both sides:
--
--   zoneAt / inside   is this point inside the storm's CURRENT safe zone --
--                     the wall as it stands now, by its real shape
--   squadKey          which squad a player's one use belongs to (a solo
--                     player is a squad of one)
--   sites             the terminal rows in a config, checked
--   line              a copy line with its {playername} / {description}
--                     tokens filled, as a BR.Notice line
--   extraRoll         the Yubikey's extra-item roll for one container
--
-- Nothing here reads a native or sends anything.

BR = BR or {}
BR.TerminalSolve = BR.TerminalSolve or {}

local T = BR.TerminalSolve

--- A terminal id's shape: lower case letters, digits and underscores,
--- starting with a letter, at most 32 characters.
T.ID = '^[a-z][a-z0-9_]*$'
T.ID_MAX = 32

--- @param id any
--- @return boolean
function T.validId(id)
    return type(id) == 'string' and #id <= T.ID_MAX and id:match(T.ID) ~= nil
end

--- @param v any
--- @return boolean
local function finite(v)
    return type(v) == 'number' and v == v and v > -math.huge and v < math.huge
end
T.finite = finite

-- ------------------------------------------------------------------ storm ---

--- The storm's current safe zone as a shape, or nil when there is no storm
--- record yet -- warmup, the bus and a server that has not published one --
--- in which case everything is inside it.
---
--- THE WALL AS IT STANDS, NOT THE TARGET. "Every computer works unless it's
--- outside the storm" (owner, 2026-10-04): a terminal the moving wall has
--- passed is outside it now, whatever circle the wall is heading for. And the
--- REAL SHAPE (BR.StormZone), never a radius test -- a zone has been a shape
--- since #344, and a circle test is wrong both ways near the edge.
---
--- NOT THE DAMAGE CUSHION. server/storm.lua bills a margin outside this edge
--- so a player at the curtain is never hurt; a terminal has no such clock skew
--- to forgive, so it reads the boundary itself.
--- @param rec table|nil  a published storm record
--- @param now number     server time (GetGameTimer on the server, BR.Clock.now() on a client)
--- @return table|nil shape
function T.zoneAt(rec, now)
    if type(rec) ~= 'table' then return nil end
    local cx, cy, r, _, _, _, t, g = BR.StormAt(rec, now)
    return BR.StormZone(rec, cx, cy, r, t, g)
end

--- Is (x, y) inside `zone`? No zone is no storm, which is inside.
--- @param zone table|nil
--- @param x number
--- @param y number
--- @return boolean
function T.inside(zone, x, y)
    if zone == nil then return true end
    return BR.StormShape.distance(zone, x, y) <= 0.0
end

-- ------------------------------------------------------------------ squad ---

--- The key a squad's one use is recorded under, this match.
---
--- A SOLO PLAYER IS A SQUAD OF ONE: no squadId, so the key is the player.
--- tostring() on both, because squadId carries the match tag in front of an
--- index (server/party.lua) and a number and a string must never be two
--- different squads.
--- @param entry table|nil  a roster entry
--- @param src integer
--- @return string
function T.squadKey(entry, src)
    if entry and entry.squadId ~= nil then
        return 'squad:' .. tostring(entry.squadId)
    end
    return 'solo:' .. tostring(src)
end

-- ------------------------------------------------------------------ sites ---

--- The usable terminal rows of a sites list, in order, each a fresh table.
---
--- A ROW THAT IS NOT A TERMINAL IS SKIPPED AND NAMED, never half-used: a bad id,
--- a missing or non-finite coordinate, or an id already taken. `why` collects
--- one line per skipped row for whoever loaded it to print.
--- @param rows table|nil
--- @return table[] sites, string[] why
function T.sites(rows)
    local out, why, seen = {}, {}, {}
    for i, r in ipairs(type(rows) == 'table' and rows or {}) do
        if type(r) ~= 'table' then
            why[#why + 1] = ('row %d is not a table'):format(i)
        elseif not T.validId(r.id) then
            why[#why + 1] = ('row %d: id %s is not lower_case_letters (at most %d)')
                :format(i, tostring(r.id), T.ID_MAX)
        elseif seen[r.id] then
            why[#why + 1] = ('row %d: id %s is used twice'):format(i, r.id)
        elseif not (finite(r.x) and finite(r.y) and finite(r.z)) then
            why[#why + 1] = ('row %d (%s): x, y and z must be numbers'):format(i, r.id)
        else
            seen[r.id] = true
            out[#out + 1] = { id = r.id, x = r.x + 0.0, y = r.y + 0.0, z = r.z + 0.0,
                              h = finite(r.h) and (r.h + 0.0) or 0.0 }
        end
    end
    return out, why
end

--- The config line for one site, for pasting into br_lib/config/terminals.lua.
--- @param s table { id, x, y, z, h }
--- @return string
function T.siteLine(s)
    return ("{ id = '%s', x = %.2f, y = %.2f, z = %.2f, h = %.1f },")
        :format(s.id, s.x, s.y, s.z, s.h or 0.0)
end

-- ------------------------------------------------------------------- copy ---

--- A copy line with its tokens filled, as BR.Notice.line returns it.
---
--- {playername} becomes BR.Notice.who(name) -- the name travels as its own
--- piece and is drawn bold, never formatted into the sentence, which is what
--- tools/check_notice_names.lua holds every toast that names a player to.
--- {description} becomes plain text. Any other {word} is left as written, and
--- a '%' in the copy is a percent sign.
--- @param text string
--- @param name string|nil
--- @param description string|nil
--- @return string|table
function T.line(text, name, description)
    local args = {}
    local fmt = tostring(text or ''):gsub('%%', '%%%%')
    fmt = fmt:gsub('{(%a+)}', function(tok)
        if tok == 'playername' then
            args[#args + 1] = BR.Notice.who(name)
            return '%s'
        elseif tok == 'description' then
            args[#args + 1] = tostring(description or '')
            return '%s'
        end
        return nil
    end)
    return BR.Notice.line(fmt, table.unpack(args))
end

-- ---------------------------------------------------------------- sources ---

--- Does this container hold an extra Yubikey?
---
--- ITS OWN STREAM, NOT THE LAYOUT'S. The roll is BR.Rng seeded from the match's
--- loot seed and the container's id, folded with a prime and #396's number, so
--- it takes nothing off any stream the loot generator, the scatter or the
--- airdrop's payout draws from: every other item in every crate is exactly
--- what it would have been, and the same pinned seed (/brlootseed) replays the
--- same keys.
--- @param layoutSeed integer|nil
--- @param containerId integer|nil
--- @param chance number  0..1
--- @return boolean
function T.extraRoll(layoutSeed, containerId, chance)
    chance = tonumber(chance) or 0
    if chance <= 0 then return false end
    if chance >= 1 then return true end
    local seed = ((math.tointeger(layoutSeed) or 0) * 31
        + (math.tointeger(containerId) or 0) * 2246822519 + 396) % 2147483647
    return BR.Rng(seed):float() < chance
end
