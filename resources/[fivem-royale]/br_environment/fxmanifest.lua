-- br_environment: the world, not the game.
--
-- Everything that changes WHAT EXISTS in the map lives here -- IPL loading,
-- the Cayo Perico lobby island, and eventually streamed assets (peds, weapons,
-- vehicles, map edits, placeable props, textures, sounds). br_core decides who
-- is alive; this resource decides what the world looks like while they are.
--
-- Kept separate from br_core so asset streaming (which will eventually make
-- this resource large) never sits in the same download or restart unit as the
-- gameplay hot path.

fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'br_environment'
description 'FiveM Royale -- world state: IPLs, the Cayo Perico lobby island, vehicle seat weapon data, streamed assets'

shared_scripts {
    '@br_lib/shared/enums.lua',
    '@br_lib/shared/protocol.lua',
}

client_scripts {
    'client/ipl.lua',
}

-- THE FIRST GAME DATA FILE THIS PROJECT HAS EVER SHIPPED (#197).
--
-- `data_file` hands a file to the GAME's own loader rather than to Lua, and
-- VEHICLE_LAYOUTS_FILE is the one that decides which weapons a vehicle seat
-- accepts. Our copy redefines two weapon groups and nothing else -- read the
-- header of the file itself, which is where the whole argument lives.
--
-- IT IS DECLARED IN BOTH BLOCKS ON PURPOSE. `files` is what makes the file
-- reach the client at all and what makes LoadResourceFile able to read it
-- back (which is how /brdriveby reports whether the override even shipped);
-- `data_file` is what mounts it into the game. Either one alone is a resource
-- that looks correct and does nothing.
--
-- THE BLAST RADIUS IS EVERY VEHICLE AND EVERY PLAYER. Backing it out is
-- deleting these two blocks -- there is no config flag, because a tunable that
-- can only be read at resource start is a switch that lies about being live.
files {
    'data/vehiclelayouts.meta',
}

data_file 'VEHICLE_LAYOUTS_FILE' 'data/vehiclelayouts.meta'
