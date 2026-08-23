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
-- dist/fingerprint.json before a commit lands.
--
-- dist/fingerprint.json IS NOT LOADED BY THIS RESOURCE, and briefly was. A
-- server/fingerprint.lua published the manifest to `GlobalState.brDdbBundle` at
-- boot and nothing ever read it, in either repo -- and it could not have
-- answered the question it was added for anyway: it republished the manifest's
-- CLAIM and never hashed the bundle, and there is no sha256 available to a Lua
-- script in FXServer to hash it with. That check now runs where the hasher is:
-- tools/dispatch.sh reads both files off the deployed resource and reports the
-- manifest and the bundle's real digest together on the `status` verb. The file
-- travels with the bundle either way, because deploys rsync the resource whole.
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
