-- Season 2 terminals (#396): the rules the server and every client both read.
--
-- ONE SPELLING OF EACH, because two would have to agree forever. A client
-- draws a terminal's plate and blip off these answers and the server rules a
-- use or a run off the same ones, so "online" means one thing on both sides:
--
--   zoneAt / inside   is this point inside the storm's CURRENT safe zone --
--                     the wall as it stands now, by its real shape
--   offlineWhy        is this terminal online: the storm, and the dev tool's
--                     forcing
--   squadKey          which squad a player's one use belongs to (a solo
--                     player is a squad of one)
--   sites             the terminal rows in a config, checked
--   pick              a copy line, or its `_solo` sibling outside a squad match
--   line              a copy line with its {playername} / {description}
--                     tokens filled, as a BR.Notice line
--   extraRoll         the Yubikey's extra-item roll for one container
--   outageArea /      Power outage's area for a choice, and whether a point
--     inOutage        is in it
--   dropCheck         whether a Vehicle drop may land on a spot a client found
--   blastDamage /     Airstrike's falloff, and where its rockets land and when
--     strikePlan
--   fuzzOffset        where an Airstrike pick's rough circle sits off an
--                     opponent
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

--- WHY THIS TERMINAL IS OFFLINE, or nil when it is online -- THE ONE RULE,
--- read by the server (every use, every run, every session check, the
--- panel's count) and by every client (the blip, the plate):
---
---   'offline'  outside the storm's current zone ("every computer works
---              unless it's outside the storm", owner 2026-10-04), unless the
---              dev tool forced it online.
--- @param site table  { id, x, y }
--- @param zone table|nil  the storm's current zone (T.zoneAt); nil is no storm
--- @param forced boolean  `brterminal online <id>`: online whatever the storm
--- @return string|nil
function T.offlineWhy(site, zone, forced)
    if forced == true then return nil end
    if T.inside(zone, site.x, site.y) then return nil end
    return 'offline'
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

--- The line `key` as this player may read it.
---
--- "SQUAD" ONLY IN A SQUAD MATCH (owner, 2026-10-05, round 2: "the mention of
--- 'squad' in the terminal should only be mentioned if the player is actively
--- in a squad match"). A line that says squad has a `<key>_solo` sibling that
--- does not, and outside a squad match that sibling is the line -- an empty
--- one included, which means "not shown". THE LUA SIDE'S ONE PICKER: the
--- server's toasts, notices and reasons and the world's plate read every
--- line through here (tools/test_terminal.lua fails a reader that indexes the
--- copy by a computed key, or names a line that has a sibling, any other
--- way). The app has its own, model.ts's `speaker`, over the same fact.
--- @param copy table|nil  BR.Config.Terminals.copy
--- @param key string
--- @param squadMatch boolean  BR.Terminal.squadMatch's answer
--- @return string  '' for a key with no line
function T.pick(copy, key, squadMatch)
    if type(copy) ~= 'table' or type(key) ~= 'string' then return '' end
    if squadMatch ~= true then
        local solo = copy[key .. '_solo']
        if type(solo) == 'string' then return solo end
    end
    local v = copy[key]
    return type(v) == 'string' and v or ''
end

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

-- ------------------------------------------------- the world (wave B) ---

--- Power outage's area for one `area` choice (#396, wave B), as the server
--- sends it and every client tests it: one spelling for both sides.
---
---   here    { kind = 'radius', x, y, r }: within `radius` meters of (x, y),
---           this terminal
---   city    { kind = 'city', line }: below the city line
---   county  { kind = 'county', line }: on it or above it
---
--- THE CITY LINE IS THE STORM'S (#381, BR.StormCityLine): the same line that
--- decides whether a match opens in the city or the county decides which side
--- goes dark. Nil for a choice that is not one of these, or a `here` with no
--- point to center on.
--- @param choice string
--- @param x number|nil @param y number|nil  this terminal
--- @param radius number  meters, for `here`
--- @return table|nil area
function T.outageArea(choice, x, y, radius)
    if choice == 'here' then
        if not (finite(x) and finite(y) and finite(radius) and radius > 0) then return nil end
        return { kind = 'radius', x = x + 0.0, y = y + 0.0, r = radius + 0.0 }
    elseif choice == 'city' or choice == 'county' then
        return { kind = choice, line = BR.StormCityLine() }
    end
    return nil
end

--- Is (x, y) in this outage area? An area that is not one -- off the wire,
--- malformed -- holds nobody.
--- @param area table|nil
--- @param x number @param y number
--- @return boolean
function T.inOutage(area, x, y)
    if type(area) ~= 'table' or not (finite(x) and finite(y)) then return false end
    if area.kind == 'radius' then
        if not (finite(area.x) and finite(area.y) and finite(area.r)) then return false end
        local dx, dy = x - area.x, y - area.y
        return dx * dx + dy * dy <= area.r * area.r
    elseif area.kind == 'city' then
        return finite(area.line) and y < area.line
    elseif area.kind == 'county' then
        return finite(area.line) and y >= area.line
    end
    return false
end

-- ------------------------------------------------ round 5: from the sky ---

--- MAY A VEHICLE DROP LAND HERE? (round 5, owner 2026-10-06: "have it drop
--- within 40m of them".) The spot is what the client of the player it is for
--- found -- a road node or flat open ground under open sky, out of the water
--- (client/terminalfx/vehicle_drop.lua) -- and a client's word, so the server
--- holds it to what it can check itself, and to nothing a client could make
--- true by saying so:
---
---   'shape'   not four finite numbers
---   'far'     more than dropRadiusM + dropSlackM from the server's own 4 Hz
---             sample of the player it is for (the slack is the sample's
---             age), or more than dropRiseM above or below them
---   'crowd'   within dropClearM of any player in the match, by the same
---             samples: never on a player
---   'bounds'  outside the play area (`inBounds`, BR.Config.Map.InBounds)
---
--- Nil when it may. Distances are on the ground (x, y); the height is checked
--- on its own.
--- @param spot table|nil  { x, y, z, h }
--- @param target table  { x, y, z } -- the server's sample of the player it is for
--- @param others table[]  { { x, y } } -- every player in the match, the target included
--- @param cfg table  BR.Config.Terminals.fx
--- @param inBounds function|nil  (x, y) -> boolean
--- @return string|nil why
function T.dropCheck(spot, target, others, cfg, inBounds)
    if type(spot) ~= 'table' or not (finite(spot.x) and finite(spot.y) and finite(spot.z)
                                     and finite(spot.h)) then
        return 'shape'
    end
    if type(target) ~= 'table' or not (finite(target.x) and finite(target.y)) then return 'far' end
    local reach = (tonumber(cfg.dropRadiusM) or 40.0) + (tonumber(cfg.dropSlackM) or 0.0)
    local dx, dy = spot.x - target.x, spot.y - target.y
    if dx * dx + dy * dy > reach * reach then return 'far' end
    if finite(target.z) and math.abs(spot.z - target.z) > (tonumber(cfg.dropRiseM) or 25.0) then
        return 'far'
    end
    local clear = tonumber(cfg.dropClearM) or 4.0
    for _, p in ipairs(others or {}) do
        if finite(p.x) and finite(p.y) then
            local ox, oy = spot.x - p.x, spot.y - p.y
            if ox * ox + oy * oy < clear * clear then return 'crowd' end
        end
    end
    if inBounds and not inBounds(spot.x, spot.y) then return 'bounds' end
    return nil
end

--- AN AIRSTRIKE ROCKET'S DAMAGE to a player `d` meters (on the ground) from
--- where it lands: `full` within `fullM`, falling off in a straight line to
--- nothing at `reachM` (round 5; fx.strikeDamage, strikeFullM, strikeReachM).
--- Display units, before armor -- BR.Damage.applyHit takes it from there.
--- @param d number
--- @param full number @param fullM number @param reachM number
--- @return number
function T.blastDamage(d, full, fullM, reachM)
    full, fullM, reachM = tonumber(full) or 0.0, tonumber(fullM) or 0.0, tonumber(reachM) or 0.0
    if not finite(d) or d < 0.0 or full <= 0.0 or d >= reachM then return 0.0 end
    if d <= fullM then return full + 0.0 end
    return full * (reachM - d) / (reachM - fullM)
end

--- WHERE AND WHEN AN AIRSTRIKE'S ROCKETS LAND (round 5): fx.strikeRockets
--- points spread EVENLY OVER THE AREA within fx.strikeRadiusM of (x, y) --
--- r * sqrt(u), not r * u, which would bunch them at the middle -- each landing
--- at `startAt` plus its own even share of fx.strikeSpreadMs, at a random
--- moment inside that share, so they come down one after another. Unguided:
--- nothing here looks at where anybody is.
--- @param rand fun(): number  0..1 (math.random on the server; a seeded stream in the suites)
--- @param x number @param y number
--- @param cfg table  BR.Config.Terminals.fx
--- @param startAt number  server time of the first share
--- @return table[] { { x, y, at } }, in landing order
function T.strikePlan(rand, x, y, cfg, startAt)
    local n = math.max(1, math.floor(tonumber(cfg.strikeRockets) or 10))
    local r = tonumber(cfg.strikeRadiusM) or 40.0
    local share = math.max(0.0, tonumber(cfg.strikeSpreadMs) or 4000.0) / n
    local out = {}
    for i = 1, n do
        local d = r * math.sqrt(rand())
        local a = 2.0 * math.pi * rand()
        out[i] = { x = x + d * math.cos(a), y = y + d * math.sin(a),
                   at = math.floor(startAt + (i - 1) * share + rand() * share) }
    end
    return out
end

--- WHERE AN AIRSTRIKE PICK'S ROUGH CIRCLE SITS OFF AN OPPONENT (round 5): an
--- offset fx.fuzzMinM..fuzzMaxM long, spread evenly over that ring's area, in
--- any direction. NEVER NONE: the opponent is inside the circle and never at
--- its center.
--- @param rand fun(): number
--- @param minM number @param maxM number
--- @return number dx, number dy
function T.fuzzOffset(rand, minM, maxM)
    minM, maxM = tonumber(minM) or 25.0, tonumber(maxM) or 85.0
    if maxM < minM then maxM = minM end
    local d = math.sqrt(minM * minM + rand() * (maxM * maxM - minM * minM))
    local a = 2.0 * math.pi * rand()
    return d * math.cos(a), d * math.sin(a)
end
