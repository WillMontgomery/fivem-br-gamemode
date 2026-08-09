-- Player profiles: load on join, write at match end.
--
-- Profiles are cached in memory for the session. Gameplay reads the cache, never
-- the database -- so a database that goes away mid-match changes nothing about
-- what players see until the results fail to save.

BR = BR or {}
BR.Profiles = {}

local cache = {}   -- [license] = profile

--- Rockstar license for a player. Stable across name changes and reconnects,
--- which is why it is the key rather than the name or the (per-session) server id.
---
--- A THIN CONSUMER OF BR.Identity SINCE M9, not a second implementation. There
--- used to be a hand-rolled GetPlayerIdentifiers loop here, and moderation was
--- about to need the same scan for the other identifier types -- at which point
--- the project would have had two readers of the same natives, disagreeing the
--- first time one of them learned something the other did not.
---
--- The qualified form is deliberate and load-bearing: this is `br_players`'
--- primary key, and every row already stored uses `license:abc...`. Returning
--- BR.Identity's bare value would have been a silent re-keying of the whole
--- table dressed up as a refactor.
---
--- @param src integer
--- @return string|nil  e.g. 'license:abc123', or nil if FiveM reported none
local function licenseOf(src)
    return BR.Identity.qualified('license', BR.Identity.licenseOf(src))
end

BR.Profiles.licenseOf = licenseOf

local function blankProfile(license, name)
    return {
        license = license, name = name or 'Unknown',
        xp = 0, level = 1,
        matches = 0, wins = 0, top10s = 0,
        kills = 0, deaths = 0, downs = 0, revives = 0,
        damage_dealt = 0, playtime_sec = 0,
        _fresh = true,
    }
end

--- Load (or create) a profile. Always returns something usable, even with the
--- database down -- an unsaved in-memory profile beats a nil check in every
--- caller.
--- @param src integer
--- @return table
function BR.Profiles.load(src)
    local license = licenseOf(src)
    local name = GetPlayerName(src) or 'Unknown'

    if not license then
        -- No license means we cannot persist anything for them, but they can
        -- still play.
        return blankProfile('anonymous:' .. tostring(src), name)
    end

    if cache[license] then
        cache[license].name = name
        return cache[license]
    end

    local row = BR.Db.single(
        'SELECT * FROM br_players WHERE license = ? LIMIT 1',
        { license }, 'profile load')

    local profile
    if row then
        profile = row
        profile._fresh = false
        profile.name = name
    else
        profile = blankProfile(license, name)
        -- Insert lazily; if this fails the player still plays and we try again
        -- at match end.
        BR.Db.execute(
            'INSERT IGNORE INTO br_players (license, name) VALUES (?, ?)',
            { license, name }, 'profile create')
    end

    profile.level = BR.Xp.levelFor(profile.xp or 0)
    cache[license] = profile
    return profile
end

--- Cached profile without touching the database.
--- @param src integer
--- @return table|nil
function BR.Profiles.get(src)
    local license = licenseOf(src)
    return license and cache[license] or nil
end

--- Apply one match result to a profile and persist it.
---
--- Returns the XP earned and the new level so the summary screen can show a
--- level-up. The write is best-effort; the returned values are correct
--- regardless of whether it lands.
---
--- @param src integer
--- @param matchId integer|nil
--- @param r table  { kills, downs, revives, damage, survivedMs, placement, total, squadId }
--- @return table result
function BR.Profiles.applyMatch(src, matchId, r)
    local profile = BR.Profiles.load(src)
    local xpEarned, breakdown = BR.Xp.forMatch(r)

    local levelBefore = BR.Xp.levelFor(profile.xp or 0)

    profile.xp           = (profile.xp or 0) + xpEarned
    profile.matches      = (profile.matches or 0) + 1
    profile.kills        = (profile.kills or 0) + (r.kills or 0)
    profile.downs        = (profile.downs or 0) + (r.downs or 0)
    profile.revives      = (profile.revives or 0) + (r.revives or 0)
    profile.damage_dealt = (profile.damage_dealt or 0) + math.floor(r.damage or 0)
    profile.playtime_sec = (profile.playtime_sec or 0) + math.floor((r.survivedMs or 0) / 1000)

    if (r.placement or 0) == 1 then
        profile.wins = (profile.wins or 0) + 1
    else
        profile.deaths = (profile.deaths or 0) + 1
    end
    if (r.placement or 999) <= 10 then
        profile.top10s = (profile.top10s or 0) + 1
    end

    local levelAfter = BR.Xp.levelFor(profile.xp)
    profile.level = levelAfter

    -- One transaction: the aggregate update and the per-match row land together
    -- or not at all. A player credited with a win in one table and missing from
    -- the other is worse than no record.
    local queries = {
        {
            query = [[
                UPDATE br_players SET
                    name = ?, xp = ?, level = ?, matches = ?, wins = ?, top10s = ?,
                    kills = ?, deaths = ?, downs = ?, revives = ?,
                    damage_dealt = ?, playtime_sec = ?
                WHERE license = ?
            ]],
            values = {
                profile.name, profile.xp, profile.level, profile.matches,
                profile.wins, profile.top10s, profile.kills, profile.deaths,
                profile.downs, profile.revives, profile.damage_dealt,
                profile.playtime_sec, profile.license,
            },
        },
    }

    if matchId then
        queries[#queries + 1] = {
            query = [[
                INSERT INTO br_match_players
                    (match_id, license, name, placement, squad_id, kills, downs,
                     revives, damage, survived_ms, xp_earned)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON DUPLICATE KEY UPDATE placement = VALUES(placement)
            ]],
            values = {
                matchId, profile.license, profile.name, r.placement or 0,
                r.squadId, r.kills or 0, r.downs or 0, r.revives or 0,
                math.floor(r.damage or 0), math.floor(r.survivedMs or 0), xpEarned,
            },
        }
    end

    local saved = BR.Db.transaction(queries, 'match result')

    return {
        xpEarned   = xpEarned,
        breakdown  = breakdown,
        xpTotal    = profile.xp,
        level      = levelAfter,
        levelUp    = levelAfter > levelBefore,
        levelsGained = levelAfter - levelBefore,
        saved      = saved,
    }
end

--- Open a match row and return its id, or nil if stats are unavailable.
--- @param mode string
--- @param playerCount integer
--- @return integer|nil
function BR.Profiles.beginMatch(mode, playerCount)
    local res = BR.Db.query(
        'INSERT INTO br_matches (mode, player_count) VALUES (?, ?); SELECT LAST_INSERT_ID() AS id;',
        { mode, playerCount }, 'match begin')

    -- oxmysql returns differently depending on driver and statement shape, so
    -- read defensively rather than assuming one form.
    if type(res) == 'table' then
        if res.insertId then return res.insertId end
        if res[1] and res[1].id then return res[1].id end
    end

    local row = BR.Db.single('SELECT MAX(id) AS id FROM br_matches', {}, 'match id')
    return row and row.id or nil
end

--- Close a match row.
function BR.Profiles.endMatch(matchId, winningSquad, durationSec)
    if not matchId then return end
    BR.Db.execute([[
        UPDATE br_matches
        SET ended_at = CURRENT_TIMESTAMP, winning_squad = ?, duration_sec = ?
        WHERE id = ?
    ]], { winningSquad, math.floor(durationSec or 0), matchId }, 'match end')
end

AddEventHandler('playerDropped', function()
    -- Deliberately keep the cache entry: the same player reconnecting mid-session
    -- should not re-read the database, and a match result may still be written
    -- for them after they disconnect.
end)

RegisterCommand('brprofile', function(_, args)
    local src = tonumber(args[1])
    if not src then
        print('  usage: brprofile <serverId>')
        return
    end
    local p = BR.Profiles.get(src)
    if not p then
        print(('  no cached profile for %d'):format(src))
        return
    end
    local pct, into, span = BR.Xp.progress(p.xp or 0)
    print(('=== %s (%s) ==='):format(p.name, p.license))
    print(('  level %d  (%d / %d xp to next, %.0f%%)'):format(p.level, into, span, pct * 100))
    print(('  matches %d  wins %d  top10 %d'):format(p.matches, p.wins, p.top10s))
    print(('  kills %d  deaths %d  downs %d  revives %d')
        :format(p.kills, p.deaths, p.downs, p.revives))
    print(('  damage %d  playtime %.1f h'):format(p.damage_dealt, (p.playtime_sec or 0) / 3600))
end, true)
