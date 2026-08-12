fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'br_ddb'
author 'Blitz Royale'
description 'Read-only DynamoDB access for the game server: ban checks and grants.'
version '0.1.0'

-- NODE 22, NOT THE DEFAULT. FXServer ships an old Node for server scripts; the
-- AWS SDK's bundle needs a modern one. This convar opts this resource into the
-- current runtime and is the difference between "works" and a parse error on
-- boot with no useful message.
node_version '22'

-- THE BUNDLE, NOT THE SOURCE. dist/server.js is generated -- edit js-src/br_ddb
-- and run `npm run build`, which tools/pre-commit and verify.sh both enforce.
--
-- THERE IS DELIBERATELY NO package.json IN THIS RESOURCE. FXServer's own build
-- toolchain (Node 16, yarn) tries to build any resource that has one, which
-- fails on a modern SDK and takes the resource down with it. Shipping one
-- pre-bundled file sidesteps the whole toolchain.
server_scripts {
    'dist/server.js',
    'server/debug.lua',
}

-- No dependency on br_core or br_ringmaster in either direction. This resource
-- answers questions and knows nothing about matches, players or moderation --
-- which is what lets the ban gate restart without disturbing it, and what keeps
-- its surface small enough to audit at a glance.
