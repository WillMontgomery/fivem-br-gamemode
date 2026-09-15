---
--- @authors Manups4e, PhilippRendell, Lacol9
---

fx_version 'cerulean'

games { 'gta5' }

-- BR-PATCH 3: THIS RESOURCE EXPOSES THE BUNDLE; br_core EXECUTES IT.
--
-- FiveM resources have separate Lua states. Starting this resource first does
-- not make UIMenu/SColor visible inside br_core, so br_core must keep loading
-- `@ScaleformUI_Lua/ScaleformUI.lua`. Executing the same file here as a
-- client_script as well would create a second state and a second copy of every
-- always-on ScaleformUI thread. Listing it as a file keeps the cross-resource
-- include available while this resource itself runs no library code.
files {
    'ScaleformUI.lua'
}

-- BR-PATCH 1: example.lua is upstream's SHOWCASE DEMO and it is not inert.
-- Loaded, it starts a thread that draws a green world marker at the player's
-- spawn, adds two timer bars, and types "this is a test" onto the minimap four
-- seconds in, then runs a forever loop watching for demo hotkeys. It remains on
-- disk for reference but is intentionally absent from client_scripts.
--
-- To evaluate it again, restore a client_scripts block containing example.lua
-- on a dev branch; never load the library itself here while br_core includes it.
