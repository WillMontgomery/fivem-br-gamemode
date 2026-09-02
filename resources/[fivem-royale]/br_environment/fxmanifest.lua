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

-- THIS RESOURCE SHIPS NO GAME DATA FILE, AND THAT IS A TESTED RESULT (#197,
-- closed 2026-08-22 as no plan to fix).
--
-- It briefly shipped `data/vehiclelayouts.meta`, mounted as
-- VEHICLE_LAYOUTS_FILE, redefining DRIVEBY_DEFAULT_ONE_HANDED and
-- DRIVEBY_DEFAULT_REAR_ONE_HANDED so a passenger could fire a long gun. The
-- game IGNORED the redefinition -- an added data file does not get to restate a
-- CDrivebyWeaponGroup the base game already defines -- and the owner confirmed
-- it in a seat on 2026-08-22: "carbine rifle in the passenger seat does nothing
-- but pistols work". Backed out whole.
--
-- Do not re-add it. docs/vehicle-data.md carries the finding, what it cost to
-- get, and the only route that remains open.
