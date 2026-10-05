fx_version "cerulean"
game "gta5"
lua54 "yes"
use_experimental_fxv2_oal "yes"

version "1.1.1"
name "cuchi_computer"
description "Usable computer"
author "Cu-chi"
repository "https://github.com/Cu-chi/cuchi_computer"

-- BR-PATCH 1 (fivem-royale, #396): STANDALONE. NO FRAMEWORK, NO DATABASE.
--
-- Upstream's shared, client and server scripts were ESX/QBCore and oxmysql
-- plus the roleplay apps (the laptop item, data heists, mail, market, the
-- addresses and their darkchat, the fake IP system). All of them are gone, and
-- so is every server script: this resource has no server half at all.
-- client/shell.lua is the whole Lua side -- it shows the desktop, holds NUI
-- focus while it is up and forwards what the page asks -- and br_core is what
-- drives it, through the exports and events that file documents. The page
-- keeps upstream's desktop and window manager (nui/), with one English locale.
client_script "client/shell.lua"

ui_page "nui/index.html"

files {
    "locales/main.js",
    "locales/ui/en.js",
    "nui/**/*"
}
-- BR-PATCH 1 end
