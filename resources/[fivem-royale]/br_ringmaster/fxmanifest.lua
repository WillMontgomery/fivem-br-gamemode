fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'br_ringmaster'
author 'FiveM Royale'
description 'The game-side half of Ringmaster: pushes state out, and (from Slice 2) executes admin verbs.'
version '0.1.0'

-- SERVER ONLY. There is deliberately no client half. Everything an admin does
-- happens through the web console; nothing here should ever put a pixel on a
-- player's screen or ask a client for anything.
--
-- THERE IS ALSO NO `dependency 'br_core'`, and that is deliberate rather than
-- an oversight. Declaring it would make moderation refuse to start when the
-- gamemode is not running, and -- worse -- `restart br_core`, which
-- tools/deploy.sh tells you to run after every single deploy, would take the
-- moderation channel down with it. Same reasoning as br_stats' refusal to
-- declare oxmysql. This resource degrades to "no live state" rather than to
-- "not running": it listens for br_core's snapshot event, and if nothing is
-- broadcasting, it has nothing to say and says so.
server_scripts {
    '@br_lib/shared/enums.lua',     -- BR.PlayerState etc, for reading roster rows
    '@br_lib/shared/protocol.lua',  -- BR.Net.NOTIFY, for maintenance announcements
    '@br_lib/shared/sched.lua',     -- our OWN job registry, separate from br_core's
    '@br_lib/shared/identity.lua',  -- the allowlisted identifier scan
    '@br_lib/shared/outbox.lua',    -- the retrying queue for EVENTS (not snapshots)

    -- THE CONFIG CHAIN, AND IT IS HERE FOR ONE KEY: BR.Config.Community.
    -- discordUrl, which server/appeal.lua puts on the end of a kick or a ban.
    --
    -- ALL FOUR LINES ARE REQUIRED, AND THREE OF THEM LOOK LIKE DEAD WEIGHT.
    -- config/overrides.lua is where a convar becomes a config value, and it runs
    -- once per Lua STATE -- this resource is its own, so without it here the
    -- committed default ('') is all this side would ever see, however carefully
    -- an operator set the convar. And overrides.lua refuses to boot on a set
    -- convar naming a BR.Config table this state has not loaded, which is its
    -- anti-drift check working exactly as designed: a state that reads the
    -- override spec has to carry every group the spec names. On a dev box, where
    -- br_maxSquadSize IS set, omitting match.lua would stop this resource dead.
    --
    -- THIS IS NOT A DEPENDENCY ON br_core. br_lib is a file container -- these
    -- load into this resource's own state and call nothing -- and the deliberate
    -- absence of `dependency 'br_core'` below is untouched: restarting the
    -- gamemode still cannot take the moderation channel with it.
    '@br_lib/config/match.lua',
    '@br_lib/config/admin.lua',
    '@br_lib/config/community.lua',
    '@br_lib/config/overrides.lua',   -- must be last; it edits the three above

    'server/config.lua',    -- must load first; everything else reads BR.Ring.Config
    'server/main.lua',      -- boot banner, boot epoch, identity capture
    'server/ddb.lua',       -- caches br_ddb's last selftest verdict (before
                            -- push.lua, which resends it on the snapshot)
    'server/push.lua',      -- the wire: snapshots latest-wins, events via outbox
    'server/incident.lua',  -- files incidents in DynamoDB, then rings the doorbell
                            -- (after push.lua: reads BR.Ring.outbox)
    'server/maintenance.lua', -- polls the window; drives the drain + notices
    'server/appeal.lua',    -- the appeal sentence, shared by the two files below
                            -- so a kick and a ban cannot word it differently
    'server/kick.lua',      -- brkick: the ONLY DropPlayer in the project
    'server/spectate.lua',  -- brspectate: resolves two licenses and hands them
                            -- to br_core, which owns the session (after
                            -- push.lua: reports outcomes through BR.Ring)
    'server/gate.lua',      -- the connect-time ban gate (fails open, own timeout)
    'server/handoff.lua',   -- #23: mints a signed-in console URL for br_core.
                            -- Answers an event; talks to no client, ever.
    'server/debug.lua',     -- brring: the read-only health dump
}

dependency 'br_lib'
