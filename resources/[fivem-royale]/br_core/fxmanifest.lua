fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'br_core'
author 'FiveM Royale'
description 'Battle royale gameplay: match state, roster, storm, drop, loot, combat.'
version '0.1.0'

-- br_lib is a file container, not a runtime dependency. These are pulled straight
-- into this resource's Lua state, so calling them costs nothing at runtime.
--
-- ORDER MATTERS and is not alphabetical:
--   enums     defines BR and the enumerations everything else references
--   geo       defines BR.Clamp / BR.Lerp, which config/match.lua uses at call time
--   config    reads enums at load time to build its lookup tables
--   storm_solve reads BR.Lerp and BR.StormPhase
shared_scripts {
    '@br_lib/shared/enums.lua',
    '@br_lib/shared/protocol.lua',
    '@br_lib/shared/names.lua',   -- display-name rules; client and server share them
    '@br_lib/shared/rng.lua',
    '@br_lib/shared/geo.lua',
    '@br_lib/shared/clock.lua',
    '@br_lib/config/match.lua',
    '@br_lib/config/storm.lua',
    '@br_lib/config/map.lua',
    '@br_lib/config/weapons.lua',
    '@br_lib/config/loot.lua',
    '@br_lib/config/audio.lua',
    '@br_lib/config/peds.lua',      -- the locker roster; reads BR.Config
    -- The catalogue. SHARED rather than server-only: the server decides what
    -- you own, and the client has to resolve an equipped id into the natives
    -- that actually put it on you. Both sides need the same definitions.
    '@br_lib/config/market.lua',
    -- THE CONVAR OVERRIDES, AND THIS LINE'S POSITION IS THE FEATURE.
    --
    -- It must come after every config/*.lua above (it edits their tables) and
    -- before every file below and in server_scripts (several of which COPY
    -- those values at load -- server/match.lua's DURATION table is built from
    -- warmupSeconds and endedSeconds the moment it loads, so an override
    -- arriving later would be read by nothing).
    --
    -- On the client and in a bare Lua state this file is inert; it only reads
    -- convars on the server. tools/test_config.lua fails the build if any
    -- manifest loads config/match.lua without this line after it.
    '@br_lib/config/overrides.lua',
    -- BR.Xp. server/market.lua evaluates the curve to send the lobby a real
    -- level -- and without this it is nil, so every player was told they were
    -- level 1 with 0/1 XP regardless of what they had actually earned.
    '@br_lib/shared/xp.lua',
    '@br_lib/shared/storm_solve.lua',
    '@br_lib/shared/combat_solve.lua',
    '@br_lib/shared/loot_gen.lua',  -- reads the loot/weapon/map config at call time
}

-- main.lua must load first on both sides: it defines the loop registry (client)
-- and BR.Server (server) that every other file reaches into.
client_scripts {
    'client/main.lua',      -- defines the loop registry; must be first
    'client/natives.lua',
    'client/loading.lua',   -- owns BR.State.worldReady; screen.lua reads it
    'client/screen.lua',
    'client/spawn.lua',
    'client/lobbycam.lua',  -- reads BR.Spawn.traveling; must follow spawn.lua
    'client/locker.lua',    -- the ped in that shot; needs BR.Native (natives.lua)
    'client/gamerules.lua',
    'client/state.lua',
    'client/stamina.lua',   -- needs BR.State (state.lua) and the loops
    'client/squadmates.lua',
    'client/sfx.lua',      -- one cue table; everything else asks it for a sound
    'client/keybinds.lua',
    'client/bus.lua',       -- needs BR.Keys (keybinds) and BR.State (main)
    -- Must precede skydive.lua, which calls into it inside the one window
    -- where a canopy tint can still be set. Needs BR.Native (natives.lua) for
    -- the chute-state enum.
    'client/cosmetics.lua',
    'client/skydive.lua',
    'client/storm.lua',     -- rendering only; damage lands in state.lua
    'client/markers.lua',   -- pause-map pings: blips + world beams
    'client/dui.lua',       -- browser pages as game textures; loot.lua uses it
    'client/inventory.lua', -- the inventory mirror; owns every weapon grant
    'client/loot.lua',      -- world props + pickup; needs BR.Inv (inventory.lua)
    'client/dbno.lua',      -- downed + revive; yields the interact key from loot.lua
    'client/chat.lua',
    'client/voice.lua',   -- Mumble channels; server/voice.lua decides them
    'client/probe.lua',    -- /brprobe: what the natives ACTUALLY do on this build
    'client/debug.lua',
}

-- sched.lua is server-only rather than shared, because the client has its own
-- loop registry in client/main.lua and would only be carrying a second,
-- never-started scheduler around.
server_scripts {
    '@br_lib/shared/sched.lua',  -- BR.Sched; every file below registers into it
    '@br_lib/shared/identity.lua',  -- BR.Identity; the ringmaster projection resolves licenses
    -- SERVER-ONLY, though both live in shared/. Evidence and severity are
    -- moderation concerns; a client has no use for either and should not be
    -- shipped a table describing what the anticheat considers suspicious.
    --
    -- evidence_buf BEFORE server/evidence.lua, which calls BR.EvidenceBuf.new()
    -- at load time -- and incident_build after combat_solve (in shared_scripts
    -- above), whose enum values it keys its severity table on.
    '@br_lib/shared/evidence_buf.lua',
    '@br_lib/shared/incident_build.lua',
    'server/main.lua',      -- defines BR.Server and starts the scheduler
    'server/clock.lua',
    'server/broadcast.lua', -- BR.Broadcast, used by roster
    'server/roster.lua',
    'server/evidence.lua', -- BR.Evidence: what a match remembers, for incidents
    'server/lobby.lua',     -- BR.Lobby, read by the match tick
    'server/party.lua',     -- BR.Party, read by the match tick
    'server/match.lua',
    'server/bus.lua',       -- route authority; match.onEnter(BUS) calls into it
    'server/combat.lua',
    'server/storm.lua',     -- phase authority + the damage ledger
    'server/inventory.lua', -- BR.Inv: the authoritative inventory model
    'server/loot.lua',      -- world loot: layout, streaming, claim arbitration
    'server/damage.lua',    -- M6: weaponDamageEvent validation and attribution
    'server/markers.lua',   -- player map markers: relay + squad scoping
    'server/chat.lua',
    'server/voice.lua',    -- voice channel authority: one room per match, one per squad
    'server/debug.lua',
    'server/market.lua',    -- inventory, purchases and equipped slots
    -- Admin scopes, read from the same DynamoDB grants table the console
    -- authorises against, through br_ddb -- never from br_ringmaster, which the
    -- game must not depend on. players.lua and incident.lua both read it, and
    -- both nil-guard it, so the order is for a reader rather than for the
    -- loader: the thing that answers the question is declared above the two
    -- files that ask it.
    'server/grants.lua',
    'server/players.lua',   -- the in-game player list and player reports
    'server/ringmaster.lua', -- the admin-console snapshot feed; emits, never listens
    'server/incident.lua',  -- builds incident payloads from evidence; emits, never enforces
}

dependency 'br_lib'
