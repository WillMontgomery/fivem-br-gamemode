fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'br_ddb'
author 'Blitz Royale'
-- Read-only on the console's tables, with two deliberate exceptions: incidents
-- are append-only from here, and since 2026-08-20 the screenshots attached to
-- one are written straight to S3 -- PutObject, one bucket, one prefix, no read
-- and no list. See the header of js-src/br_ddb/src/index.js for why both writes
-- live on this side rather than on the console's.
description 'AWS access for the game server: ban checks, grants, profiles, filing incidents, and uploading incident artifacts.'
version '0.1.0'

-- NODE 22, NOT THE DEFAULT. FXServer ships an old Node for server scripts; the
-- AWS SDK's bundle needs a modern one. This convar opts this resource into the
-- current runtime and is the difference between "works" and a parse error on
-- boot with no useful message.
node_version '22'

-- THE BUNDLE, NOT THE SOURCE. dist/server.js is generated -- edit js-src/br_ddb
-- and run `npm run build`. tools/pre-commit refuses a source-only commit, and
-- verify.sh compares the source against the fingerprint recorded in
-- dist/fingerprint.json, which server/fingerprint.lua republishes at boot.
--
-- THERE IS DELIBERATELY NO package.json IN THIS RESOURCE. FXServer's own build
-- toolchain (Node 16, yarn) tries to build any resource that has one, which
-- fails on a modern SDK and takes the resource down with it. Shipping one
-- pre-bundled file sidesteps the whole toolchain.
server_scripts {
    'dist/server.js',
    'server/debug.lua',
    'server/fingerprint.lua',
}

-- No dependency on br_core or br_ringmaster in either direction. This resource
-- answers questions and knows nothing about matches, players or moderation --
-- which is what lets the ban gate restart without disturbing it, and what keeps
-- its surface small enough to audit at a glance.
