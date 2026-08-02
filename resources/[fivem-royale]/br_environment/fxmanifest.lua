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
description 'FiveM Royale -- world state: IPLs, the Cayo Perico lobby island, streamed assets'

shared_scripts {
    '@br_lib/shared/enums.lua',
    '@br_lib/shared/protocol.lua',
}

client_scripts {
    'client/ipl.lua',
}
