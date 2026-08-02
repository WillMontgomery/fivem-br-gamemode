fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'br_ui'
author 'FiveM Royale'
description 'NUI for FiveM Royale: HUD, lobby, chat. React + HeroUI, built to ui/.'
version '0.1.0'

ui_page 'ui/index.html'

-- Only the protocol constants are needed here, not the whole config. Keeping
-- this list minimal means a change to storm tuning cannot break the UI bridge.
shared_scripts {
    '@br_lib/shared/enums.lua',
    '@br_lib/shared/protocol.lua',
}

client_scripts {
    'client/nui.lua',
}

files {
    'ui/index.html',
    'ui/assets/*.js',
    'ui/assets/*.css',
}

dependency 'br_lib'
