fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'br_loadscreen'
author 'FiveM Royale'
description 'Branded loading screen. Held open by br_core until the lobby can stand in for it.'
version '0.1.0'

-- MANUAL SHUTDOWN is the whole point: the game does not decide when this
-- screen goes away, br_core does (client/loading.lua) -- the moment the real
-- lobby menu has data and can take over. The loadscreen NUI is one-way (it
-- cannot fetch callbacks), so it is deliberately NOT interactive: the
-- interactive part of joining -- queueing, parties, ready up -- happens in
-- the actual lobby the instant this drops, while the world still streams
-- behind an opaque backdrop in the same visual language.
loadscreen 'index.html'
loadscreen_manual_shutdown 'yes'

files {
    'index.html',
}
