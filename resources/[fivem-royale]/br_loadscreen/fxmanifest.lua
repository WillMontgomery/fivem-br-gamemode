fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'br_loadscreen'
author 'FiveM Royale'
description 'Branded loading screen. Held open by br_core until the lobby can stand in for it.'
version '0.1.0'

-- MANUAL SHUTDOWN is the whole point: the game does not decide when this
-- screen goes away, br_core does (client/loading.lua), and it choreographs
-- the exit -- this screen holds until the world is genuinely ready, fades
-- everything above its glow on cue (the glow stays), hands its song to the
-- lobby, and the shutdown lands on the lobby's identical backdrop, which then
-- fades to the world as the menu fades in. The loadscreen NUI is one-way (it
-- cannot fetch callbacks), so nothing on it is clickable -- and it is
-- deliberately not a fake menu either: UI that looks clickable and is not is
-- worse than none. Its one key, M, mutes its own track.
loadscreen 'index.html'
loadscreen_manual_shutdown 'yes'

files {
    'index.html',
    -- THE TRACK AND THE STILLS (#423). Everything listed here downloads
    -- before the screen can show, so the stills are sized to a budget by
    -- tools/loadscreen_shots.py, which also writes the page's list of them.
    'audio/loadingscreen.ogg',
    'shots/*.webp',
}
