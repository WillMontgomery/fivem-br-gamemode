fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'br_stats'
author 'Blitz Royale'
description 'Match results and progression, persisted to DynamoDB via br_ddb.'
version '0.2.0'

-- NO DATABASE DEPENDENCY OF ITS OWN ANY MORE. This used to be an oxmysql
-- client with a connection layer, a circuit breaker and a SQL schema; all of it
-- is gone. Persistence now goes through br_ddb, which the ban gate and the
-- maintenance poller already use, so there is one way this server talks to a
-- datastore rather than two.
--
-- WHAT WAS DELETED AND WHY IT COST NOTHING: db.lua, profiles.lua and
-- leaderboard.lua had ZERO callers between them -- not one function was ever
-- invoked from outside this resource, because br_core emitted no match-end
-- event for them to hang off. So MariaDB held no profiles, no XP and no match
-- history, and removing it lost no data. The intent was real; the wiring was
-- never finished.
--
-- STILL NO `dependency 'br_ddb'`, for the same reason br_ringmaster does not
-- depend on br_core: declaring it would make this refuse to start when br_ddb
-- is absent, and a server without stats should run perfectly well. persist.lua
-- checks the resource state and says so once per match instead.
server_scripts {
    '@br_lib/shared/identity.lua',  -- BR.Identity; persist.lua keys on license
    'server/xp.lua',                -- the curve; must load before persist
    'server/persist.lua',           -- br:match:results -> DynamoDB
}

dependency 'br_lib'
