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
    '@br_lib/shared/names.lua',   -- display-name rules; client and server share them
}

client_scripts {
    -- The catalogue, organised by season. Shared so the definitions have one
    -- home rather than living inline in the file that renders them.
    '@br_lib/config/market.lua',

    'client/nui.lua',
    -- Preferences live HERE rather than in br_core: they are about this
    -- machine's screen and speakers, they are stored in this resource's kvp,
    -- and every one of them is consumed by the page. br_core owns the game;
    -- br_ui owns how it is presented.
    'client/settings.lua',
    'client/pause.lua',     -- our pause menu, in place of GTA's
    'client/market.lua',    -- the storefront; synthetic until a server exists
}

files {
    'ui/index.html',
    'ui/assets/*.js',
    'ui/assets/*.css',
    -- THE FONTS, and the reason this line is easy to forget: a missing font
    -- does not error. CEF falls back to Segoe UI, the layout still looks
    -- plausible, and the whole game silently renders in the operating
    -- system's UI font while the browser preview looks perfect. Globbed
    -- rather than named because Vite content-hashes the filenames.
    --
    -- Both extensions: Fontsource's @font-face lists woff2 first and woff as
    -- the fallback. CEF takes the woff2, so the woff is never fetched -- but
    -- it ships in the build output either way, and half a font pair is
    -- exactly the sort of thing that only surfaces on some other engine build.
    'ui/assets/*.woff2',
    'ui/assets/*.woff',
    -- Item artwork, copied verbatim out of ui-src/public by Vite. Without
    -- this line CEF cannot fetch them and every slot silently falls back to
    -- its drawn icon -- which looks like the artwork "not working" rather
    -- than like a missing manifest entry.
    'ui/items/*.png',
    -- Market artwork, same story, same failure mode. Separate directory
    -- because the ids come from a different config and the two sets are
    -- filled in independently.
    'ui/market/*.png',
    -- The DUI page. Deliberately NOT under ui/ -- that directory is Vite's
    -- output and gets emptied on every build. This one is hand-written and
    -- loaded by URL (nui://br_ui/dui/prompt.html) rather than as the ui_page,
    -- so it needs no build step at all.
    'dui/prompt.html',
}

dependency 'br_lib'
