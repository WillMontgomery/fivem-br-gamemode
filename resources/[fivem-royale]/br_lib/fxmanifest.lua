fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'br_lib'
author 'FiveM Royale'
description 'Shared config, enums, protocol and math for FiveM Royale. Contains no runtime logic.'
version '0.1.0'

-- br_lib is a FILE CONTAINER, not a runtime dependency.
--
-- It deliberately declares no client_scripts or server_scripts of its own. Other
-- resources pull these files directly into their own Lua state with:
--
--     shared_scripts { '@br_lib/shared/enums.lua', ... }
--
-- That loads the file into the consuming resource's state, so calls cost nothing
-- at runtime. Exposing this as exports instead would put a cross-runtime call on
-- every hot path, which is exactly what we are avoiding.
--
-- Load order matters: enums -> protocol -> rng -> geo -> clock -> config -> storm_solve.

files {
    'shared/*.lua',
    'config/*.lua',
}
