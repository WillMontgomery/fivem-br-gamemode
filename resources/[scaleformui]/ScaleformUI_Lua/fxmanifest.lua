---
--- @authors Manups4e, PhilippRendell, Lacol9
---

fx_version 'cerulean'

games { 'gta5' }

-- You can comment example.lua if you don't need it!
client_scripts {
    'ScaleformUI.lua',
    -- BR-PATCH 1: example.lua is upstream's SHOWCASE DEMO and it is not inert.
    -- Loaded, it starts a thread that draws a green world marker at the player's
    -- spawn, adds two timer bars, and types "this is a test" onto the minimap
    -- four seconds in, then runs a forever loop watching for demo hotkeys. That
    -- is upstream's intent -- the manifest line directly above says to comment
    -- it out when you do not want it -- but on our server it is a stranger's UI
    -- appearing on every player's screen for no reason anyone could trace.
    --
    -- COMMENTED OUT RATHER THAN DELETED. Deleting the file was the alternative
    -- and it lost twice over: the demo is the thing the owner evaluated and
    -- liked, so it is worth keeping one uncomment away for the next look at it,
    -- and keeping it means this directory stays byte-for-byte the published
    -- 5.8.1 release except for this block, which is the whole provenance claim
    -- VENDOR.json makes. Re-enable by uncommenting the line below.
    -- 'example.lua'
}
