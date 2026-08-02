fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'br_core'
author 'FiveM Royale'
description 'Battle royale gameplay: match state, roster, storm, drop, loot, combat.'
version '0.1.0'

-- br_lib is a file container, not a runtime dependency. These are pulled straight
-- into this resource's Lua state, so calling them costs nothing at runtime.
--
-- ORDER MATTERS and is not alphabetical:
--   enums     defines BR and the enumerations everything else references
--   geo       defines BR.Clamp / BR.Lerp, which config/match.lua uses at call time
--   config    reads enums at load time to build its lookup tables
--   storm_solve reads BR.Lerp and BR.StormPhase
shared_scripts {
    '@br_lib/shared/enums.lua',
    '@br_lib/shared/protocol.lua',
    '@br_lib/shared/rng.lua',
    '@br_lib/shared/geo.lua',
    '@br_lib/shared/clock.lua',
    '@br_lib/config/match.lua',
    '@br_lib/config/storm.lua',
    '@br_lib/config/map.lua',
    '@br_lib/config/weapons.lua',
    '@br_lib/config/loot.lua',
    '@br_lib/shared/storm_solve.lua',
}

-- main.lua must load first on both sides: it defines the loop registry and the
-- scheduler that every other file registers into.
client_scripts {
    'client/main.lua',
    'client/natives.lua',
    'client/keybinds.lua',
    'client/chat.lua',
    'client/debug.lua',
}

server_scripts {
    'server/main.lua',
    'server/chat.lua',
    'server/debug.lua',
}

dependency 'br_lib'
