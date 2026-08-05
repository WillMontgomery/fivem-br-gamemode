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
    '@br_lib/shared/loot_gen.lua',  -- reads the loot/weapon/map config at call time
}

-- main.lua must load first on both sides: it defines the loop registry and the
-- scheduler that every other file registers into.
client_scripts {
    'client/main.lua',      -- defines the loop registry; must be first
    'client/natives.lua',
    'client/loading.lua',   -- owns BR.State.worldReady; screen.lua reads it
    'client/screen.lua',
    'client/spawn.lua',
    'client/gamerules.lua',
    'client/state.lua',
    'client/stamina.lua',   -- needs BR.State (state.lua) and the loops
    'client/squadmates.lua',
    'client/keybinds.lua',
    'client/bus.lua',       -- needs BR.Keys (keybinds) and BR.State (main)
    'client/skydive.lua',
    'client/storm.lua',     -- rendering only; damage lands in state.lua
    'client/markers.lua',   -- pause-map pings: blips + world beams
    'client/inventory.lua', -- the inventory mirror; owns every weapon grant
    'client/loot.lua',      -- world props + pickup; needs BR.Inv (inventory.lua)
    'client/chat.lua',
    'client/debug.lua',
}

server_scripts {
    'server/main.lua',      -- defines the scheduler and BR.Server; must be first
    'server/clock.lua',
    'server/broadcast.lua', -- BR.Broadcast, used by roster
    'server/roster.lua',
    'server/lobby.lua',     -- BR.Lobby, read by the match tick
    'server/party.lua',     -- BR.Party, read by the match tick
    'server/match.lua',
    'server/bus.lua',       -- route authority; match.onEnter(BUS) calls into it
    'server/combat.lua',
    'server/storm.lua',     -- phase authority + the damage ledger
    'server/inventory.lua', -- BR.Inv: the authoritative inventory model
    'server/loot.lua',      -- world loot: layout, streaming, claim arbitration
    'server/markers.lua',   -- player map markers: relay + squad scoping
    'server/chat.lua',
    'server/debug.lua',
}

dependency 'br_lib'
