fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'br_stats'
author 'FiveM Royale'
description 'Persistent stats, XP and leaderboards. Degrades gracefully without a database.'
version '0.1.0'

-- Only what the stats layer actually needs. It has no gameplay dependencies, so
-- a change to storm or loot tuning cannot affect persistence.
shared_scripts {
    '@br_lib/shared/enums.lua',
}

server_scripts {
    '@br_lib/shared/identity.lua',  -- BR.Identity; profiles.lua keys on it
    'server/db.lua',        -- must load first; everything else uses BR.Db
    'server/xp.lua',
    'server/persist.lua',  -- match results -> DynamoDB via br_ddb
    'server/profiles.lua',
    'server/leaderboard.lua',
}

files {
    'sql/schema.sql',
}

dependency 'br_lib'

-- NOTE: oxmysql is intentionally NOT declared as a dependency.
--
-- Declaring it would make br_stats refuse to start without it, which is exactly
-- backwards: the whole design here is that a missing or broken database costs
-- you stats, not the gamemode. db.lua checks for oxmysql at runtime and disables
-- itself cleanly if it is absent.
