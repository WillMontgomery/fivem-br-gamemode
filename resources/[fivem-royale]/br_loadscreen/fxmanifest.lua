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
-- its text on cue (the glow stays), and the shutdown lands on the lobby's
-- identical purple backdrop, which then fades to the world as the menu
-- fades in. The loadscreen NUI is one-way (it cannot fetch callbacks), so
-- it is deliberately NOT interactive -- and deliberately not a fake menu
-- either: UI that looks clickable and is not is worse than none.
loadscreen 'index.html'
loadscreen_manual_shutdown 'yes'

files {
    'index.html',
}
