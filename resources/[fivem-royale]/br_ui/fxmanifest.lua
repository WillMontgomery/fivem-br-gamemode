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
    -- Item artwork, copied verbatim out of ui-src/public by Vite. Without
    -- this line CEF cannot fetch them and every slot silently falls back to
    -- its drawn icon -- which looks like the artwork "not working" rather
    -- than like a missing manifest entry.
    'ui/items/*.png',
    -- The DUI page. Deliberately NOT under ui/ -- that directory is Vite's
    -- output and gets emptied on every build. This one is hand-written and
    -- loaded by URL (nui://br_ui/dui/prompt.html) rather than as the ui_page,
    -- so it needs no build step at all.
    'dui/prompt.html',
}

dependency 'br_lib'
