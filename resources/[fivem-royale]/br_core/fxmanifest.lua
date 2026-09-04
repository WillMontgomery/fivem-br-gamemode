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
    -- FIRST, AND THE ORDER IS THE WHOLE MECHANISM. devgate.lua wraps
    -- RegisterCommand with the dev-mode gate every command in this project now
    -- carries (owner, 2026-08-31); a file that registers a command BEFORE this
    -- one loads is silently ungated. Shared rather than client+server because
    -- both states register commands and both need the same wrap.
    -- tools/verify.sh checks this line's position.
    '@br_lib/shared/devgate.lua',
    '@br_lib/shared/enums.lua',
    '@br_lib/shared/protocol.lua',
    '@br_lib/shared/names.lua',   -- display-name rules; client and server share them
    -- A toast that names a player, split so the name can be drawn bold and can
    -- never be anything but text. SHARED because both halves of every such
    -- notice are here: server/combat.lua and server/party.lua compose them,
    -- client/state.lua composes one and forwards them all. NO LOAD-ORDER
    -- REQUIREMENT -- it reads nothing at load and calls no native -- and it
    -- sits beside names.lua because the two are about the same word.
    '@br_lib/shared/notice.lua',
    '@br_lib/shared/rng.lua',
    '@br_lib/shared/geo.lua',
    -- Point-in-polygon for the surveyed playable boundary. BEFORE
    -- config/map.lua, which wraps it as BR.Config.Map.InBounds -- the wrapper
    -- resolves at call time so the order is not load-bearing today, and putting
    -- the definition above its only caller keeps it from becoming so.
    '@br_lib/shared/polygon.lua',
    '@br_lib/shared/clock.lua',
    -- The world override -- what time it is and what the sky is doing when the
    -- console has said so. SHARED because it is the same record on both sides:
    -- server/world.lua holds the authority and every client mirrors it, and a
    -- second copy of "what does an unoverridden clock read" is the drift this
    -- placement prevents. NO LOAD-ORDER REQUIREMENT: it reads nothing at load,
    -- calls no native, and is above its readers only so it reads that way.
    '@br_lib/shared/world.lua',
    '@br_lib/config/match.lua',
    '@br_lib/config/storm.lua',
    '@br_lib/config/map.lua',
    '@br_lib/config/weapons.lua',
    -- Which vehicles the gamemode refuses, and why. AFTER geo.lua (above), not
    -- merely near it: the file calls BR.NormHash at LOAD time to build its
    -- hash-keyed lookup, so loading it any earlier would key every row on nil
    -- and refuse nothing -- silently, since an empty refusal table reads exactly
    -- like a clean one. It reads BR.Config.Bus.model nowhere, so config/map.lua
    -- may sit either side of it.
    '@br_lib/config/vehicles.lua',
    '@br_lib/config/loot.lua',
    -- AFTER config/loot.lua AND config/weapons.lua, and not merely near them.
    -- It resolves its payout pools at LOAD time out of their rarity buckets and
    -- their id lookups -- including BR.Config.AirdropWeapons, the four explosives
    -- weapons.lua registers into the id lookup and into no bucket. Load this
    -- earlier and every pool resolves empty, which is an airdrop that lands
    -- carrying nothing and says so nowhere.
    '@br_lib/config/airdrop.lua',
    -- The fuel budget and the petrol stations. AFTER config/storm.lua, not
    -- merely near it: the tank size is DERIVED from BR.Config.Storm.mapAABB at
    -- load time -- the map diagonal is what "two fuel stops per crossing" is
    -- measured against -- so loading it earlier would divide by a nil AABB and
    -- take the resource down at load.
    '@br_lib/config/fuel.lua',
    -- The boost solver, and then the boost numbers. THIS PAIR IS ORDERED AND THE
    -- ORDER IS BACKWARDS FROM EVERY OTHER SOLVER HERE, which is why it is
    -- declared up among the configs rather than down with its siblings:
    -- config/boost.lua derives `addMps` from BR.BoostSolve.MPH AT LOAD TIME, so
    -- the solver has to exist first. Putting the mph-to-m/s constant in both
    -- files instead is the drift this project is most scarred by; one definition
    -- and one ordered pair is the cheaper price.
    '@br_lib/shared/boost_solve.lua',
    '@br_lib/config/boost.lua',
    '@br_lib/config/audio.lua',
    -- The CPR kit's ambulance (#191). AFTER config/map.lua for a reader rather
    -- than for the loader: BR.Config.Rescue.Points() prefers the authored
    -- pickup/drop-off list in BR.Config.Map when there is one, and reads it at
    -- CALL time -- so the order here is about where somebody looks for the
    -- points, not about whether they resolve.
    '@br_lib/config/rescue.lua',
    -- Healing in the back of an ambulance (owner, 2026-08-28). AFTER
    -- config/rescue.lua, and this one IS a load order rather than a reader's
    -- convenience in one direction and a reader's in the other:
    --
    --   AT LOAD it needs nothing -- every reader in it (stretcher(), models(),
    --   label()) resolves BR.Config.Rescue at CALL time, deliberately, so the
    --   owner can re-survey the stretcher with /brattach and both features move
    --   together.
    --   ON THE PAGE it must follow, because the whole file is written against
    --   config/rescue.lua's decisions and the first thing a reader needs is the
    --   table it borrows from.
    '@br_lib/config/ambheal.lua',
    -- The squad's revive key (#219 step 4). AFTER config/rescue.lua, for the
    -- same reason config/ambheal.lua is: `models()` resolves BR.Config.Rescue at
    -- CALL time, so this is a reader's order and not the loader's. It is the
    -- third file to ask that one list what an ambulance is, and it is declared
    -- beside the other two so the three read as a set.
    '@br_lib/config/revivekey.lua',
    -- The 23 station ambulances (#219 step 3). AFTER config/rescue.lua and
    -- config/map.lua, and for the same reason the three above it are: its
    -- `Points()` and `Model()` resolve BR.Config.Rescue at CALL time -- so the
    -- surveyed rows have exactly one reader and the two features cannot disagree
    -- about where a station is. Declared with the other ambulance configs
    -- because the four are one feature family on the map.
    '@br_lib/config/ambulances.lua',
    '@br_lib/config/peds.lua',      -- the locker roster; reads BR.Config
    -- The warmup vehicle shop's catalogue (#224). SHIPS EMPTY, on purpose --
    -- the owner authors the models, coordinates and headings in game, and with
    -- no rows the feature is inert rather than broken (BR.Config.Rescue.points'
    -- rule, applied a second time).
    --
    -- SHARED, AND THAT IS THE WHOLE OF "EXACTLY AS SHOWN". The server arbitrates
    -- the purchase from this table and the CLIENT rebuilds the car from it --
    -- both the showroom copy and the one that comes out of the item -- so no
    -- appearance ever has to cross the wire and there is nothing in flight that
    -- could describe the car differently from the way it was described in
    -- warmup.
    --
    -- IT HAS NO LOAD-ORDER REQUIREMENT AND THAT IS DELIBERATE. It registers its
    -- rows into BR.Config.ConsumableById through a FUNCTION that br_core's own
    -- shop files call at resource start, rather than at its own load -- because
    -- config/loot.lua builds that table with a plain assignment and anything
    -- registered before that line would be destroyed by it. Declared here, after
    -- the other feature configs, for a reader.
    '@br_lib/config/shop.lua',
    -- The catalogue. SHARED rather than server-only: the server decides what
    -- you own, and the client has to resolve an equipped id into the natives
    -- that actually put it on you. Both sides need the same definitions.
    '@br_lib/config/market.lua',
    -- Where the admin console lives. One key, no useful default, and it MUST
    -- precede overrides.lua: that file refuses to boot if a convar names a
    -- BR.Config key that does not exist yet, which is the anti-drift check
    -- doing exactly its job on a load-order mistake.
    '@br_lib/config/admin.lua',
    -- Where our Discord is. Same shape as admin.lua -- one key, no useful
    -- committed default -- and the same load-order requirement: it must precede
    -- overrides.lua, whose anti-drift check refuses to boot on a convar naming a
    -- BR.Config key that does not exist yet.
    '@br_lib/config/community.lua',
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
    -- BR.HealthUnexplainedGain: does the client's ped agree with the server's
    -- health ledger. Pure, and cfg is a parameter, so it has no load-order
    -- requirement of its own -- it sits here because it is read by
    -- server/roster.lua's sampler and belongs beside the other anticheat solver.
    '@br_lib/shared/health_solve.lua',
    -- BR.RescueDestination and the drive estimate (#191). AFTER
    -- shared/storm_solve.lua, and that IS a load order rather than a reader's
    -- convenience: choosing a drop-off means asking BR.StormAt where the circle
    -- will be when the ambulance ARRIVES, which is the whole rule -- a point
    -- inside the wall at dispatch is routinely outside it on arrival.
    '@br_lib/shared/rescue_solve.lua',
    -- BR.AmbHealSolve: the reach test, the rear arc, the door rule and the heal
    -- ramp. PURE, with every threshold a parameter, so it has no load-order
    -- requirement of its own beyond shared/geo.lua (BR.Clamp and BR.Dist, both
    -- already loaded). SHARED because both halves call it and a solver only one
    -- side can load is a solver only one side can be tested against -- and
    -- because the geometry the client draws a prompt from and the geometry the
    -- server grants a claim from must be the same arithmetic, not two copies of
    -- it. It sits here beside rescue_solve.lua because they are the two
    -- ambulance solvers.
    '@br_lib/shared/ambheal_solve.lua',
    -- BR.FuelSolve. SHARED because both halves of the fuel model call it: the
    -- server drains and refills through it, the client converts metres to a
    -- tank level through it, and a solver only one side can load is a solver
    -- only one side can be tested against.
    '@br_lib/shared/fuel_solve.lua',
    '@br_lib/shared/loot_gen.lua',  -- reads the loot/weapon/map config at call time
    -- The airdrop solver: siting, payout and the descent curve. AFTER
    -- config/airdrop.lua, whose resolved pools BR.AirdropPayout deals from.
    '@br_lib/shared/airdrop_solve.lua',
    -- Who a spectator may look at. Pure, so the squad rule is testable without
    -- a server; read by server/spectate.lua only, but SHARED because a solver
    -- that only the server can load is a solver only the server can test.
    '@br_lib/shared/spectate_solve.lua',
    -- BR.ShopSolve (#224): the catalogue, the purchase condition, and the
    -- canonical form of a car's appearance.
    --
    -- SHARED FOR A HARDER REASON THAN THE OTHER SOLVERS. The usual argument --
    -- a solver only one side can load is a solver only one side can test --
    -- applies, but the load-bearing one is BR.ShopSolve.appearance: the
    -- showroom car and the car a player unpacks are dressed by ONE client
    -- function over the output of that ONE solver, so they are not kept in sync,
    -- they are the same computation run twice. A server-only copy would put the
    -- car's description on the wire, which is precisely the second
    -- representation this design exists to not have.
    --
    -- ...AND THE SAME ARGUMENT NOW COVERS THE COLOUR ROLL (2026-08-31).
    -- BR.ShopSolve.paint turns one server-issued seed into a paint index, and it
    -- has to answer identically on the server's clients and on each other's --
    -- so it is BR.Rng (loaded near the top of this list) over a config table
    -- every machine holds, rather than a colour the server resolves and sends.
    --
    -- LAST, because it reads nothing at load and everything at call time --
    -- which is also why BR.Rng being 180 lines above it is a readability
    -- choice rather than a dependency.
    '@br_lib/shared/shop_solve.lua',
}

-- main.lua must load first on both sides: it defines the loop registry (client)
-- and BR.Server (server) that every other file reaches into.
client_scripts {
    'client/main.lua',      -- defines the loop registry; must be first
    'client/natives.lua',
    -- The world override this client is holding, and THE ONLY PLACE THIS CLIENT
    -- WRITES WEATHER. AFTER natives.lua for a reader rather than for the loader
    -- -- natives.lua's clock pin asks BR.World.clockHM() at call time and
    -- nil-guards it -- but BEFORE client/storm.lua, which is a real order in
    -- the sense that matters: storm.lua's weather branches are now claims made
    -- through BR.World.want, and a claim made into a nil table would take the
    -- storm tick down with it. It answers BR.Net.WORLD_SET and the island's
    -- 'br:world:island' from br_environment; it registers no command and joins
    -- no loop.
    'client/world.lua',
    'client/loading.lua',   -- owns BR.State.worldReady; screen.lua reads it
    'client/screen.lua',
    'client/spawn.lua',
    'client/lobbycam.lua',  -- reads BR.Spawn.traveling; must follow spawn.lua
    'client/locker.lua',    -- the ped in that shot; needs BR.Native (natives.lua)
    -- Whether that ped is a LOBBY ped -- hidden from every other lobby client
    -- -- and the walk-in that puts it in frame. AFTER lobbycam.lua and
    -- locker.lua, and that is a READER'S order in one direction and the
    -- loader's in the other: it drives BR.LobbyCam's flight and calls
    -- BR.Locker.push at CALL time (both nil-guarded), but client/squadmates.lua
    -- BELOW reads BR.LobbyPed.isLobbyPed() on a FRAME loop to decide whose ped
    -- to hide, and a frame answered by a missing table is a frame where every
    -- other lobby ped is visible. It needs client/main.lua for the loop
    -- registry and BR.Dist (@br_lib/shared/geo.lua), both already above.
    'client/lobbyped.lua',
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
    -- The one-a-session "switch to slot N" notice for a passenger (#206). Reads
    -- BR.Inv.local_() at call time, so it only has to be BELOW main.lua for the
    -- loop registry; it is here because the mirror is what it reads.
    'client/driveby.lua',
    'client/loot.lua',      -- world props + pickup; needs BR.Inv (inventory.lua)
    -- The airdrop's flares: how one is lit, and where they go WHILE THE CRATE
    -- FALLS. It needs client/main.lua for the loop registry and BR.Native
    -- (natives.lua) for the prop scale on the object route, and that is now the
    -- whole of what it needs -- it used to be placed after client/loot.lua as
    -- well, because a second pass in it asked BR.Loot.airdropBox() where the
    -- landed box was. The owner asked for that pass to go (2026-08-23); nothing
    -- here reads br_core/client/loot.lua any more, and this line stays where it
    -- is only because these two files are a pair.
    --
    -- BEFORE client/airdrop.lua for the same reason in the other direction:
    -- that file hands this one two world positions per frame and holds a
    -- BR.Flare site rather than flare props of its own.
    'client/flares.lua',
    -- The falling crate, its canopy and the blip. Reads BR.Native (natives.lua)
    -- for the blip name, BR.Clock (shared) for the descent and BR.Flare
    -- (flares.lua) for the flares; it creates no loot of its own -- what lands
    -- is server registry entries arriving through client/loot.lua like anything
    -- else.
    'client/airdrop.lua',
    'client/dbno.lua',      -- downed + revive; yields the interact key from loot.lua
    -- The CPR kit's ambulance ride (#191). AFTER dbno.lua, and this one is a
    -- real ordering rather than a reader's: both listen on BR.Keys 'interact'
    -- while the player is DOWNED, and they must never both act on one press.
    -- They cannot -- dbno.lua's handler is about reviving SOMEBODY ELSE and
    -- returns early on `not me.squadId`, while this one only fires for a solo
    -- holding a kit -- but the two conditions are mutually exclusive by
    -- argument rather than by construction, so the file that yields is declared
    -- after the file it yields to.
    'client/rescue.lua',
    -- Healing in the back of any ambulance (owner, 2026-08-28). AFTER
    -- client/rescue.lua, and that is a READER'S order rather than the loader's:
    -- it borrows that file's stretcher, its pose and its two camera numbers
    -- through the config, and every one of those is reached at call time. It
    -- needs client/main.lua for the loop registry, client/keybinds.lua for
    -- BR.Keys.on('interact'), client/dui.lua for the shared prompt page and
    -- client/natives.lua for BR.Native.keyLabelForCommand -- all of which are
    -- above.
    --
    -- IT IS BELOW client/loot.lua AND THAT IS FINE. loot.lua's canTake() asks
    -- BR.AmbHeal.healing() so a player on the stretcher is not offered a crate,
    -- and it asks it NIL-GUARDED AT CALL TIME -- the same shape in which
    -- markers.lua, dbno.lua, bus.lua and survey.lua all ask BR.Rescue.riding()
    -- from above the file that answers. A load order would only matter if the
    -- table were read while loot.lua itself was loading, and it is not.
    'client/ambheal.lua',
    -- The warmup vehicle shop (#224): the showroom, the plate on the bonnet,
    -- and the car that comes out of the item.
    --
    -- A REAL LOAD ORDER IN ONE RESPECT AND A READER'S IN THE REST. It needs
    -- client/main.lua for the loop registry, client/keybinds.lua for
    -- BR.Keys.on('interact'), client/dui.lua for the shared prompt page and
    -- client/natives.lua for BR.Native.keyLabelForCommand -- the same four
    -- client/ambheal.lua names, all of which are above.
    --
    -- IT IS THE FIFTH CONSUMER OF THE ONE PROMPT BROWSER and is declared beside
    -- the fourth for that reason: crate, pump, revive, heal station, showroom.
    'client/shop.lua',
    -- The revive key on screen (#219 step 5): the plate over a dead mate's key,
    -- the plate at an ambulance, and the hold that brings them back.
    --
    -- THE SIXTH CONSUMER OF THE ONE PROMPT BROWSER, declared beside the fifth
    -- for the reason the line above gives: crate, pump, revive, heal station,
    -- showroom, revive key.
    --
    -- AFTER client/dbno.lua AND client/ambheal.lua, AND BOTH ARE REAL ORDERINGS
    -- RATHER THAN A READER'S -- this is the file that YIELDS, twice, and the
    -- convention in this block is that the yielder is declared after what it
    -- yields to:
    --
    --   * dbno.lua drives BR.ReviveKey.yield() and BR.ReviveKey.prompting()
    --     from its own frame pass, which is how the one BR.Loot.suppress() call
    --     site covers this file's plates as well as its own. Those two names are
    --     reached at CALL time and nil-guarded on both sides, so the loader does
    --     not actually care -- but a reader looking for who yields to whom
    --     should find them in this order.
    --   * ambheal.lua answers BR.AmbHeal.prompting(), which is what stops one
    --     press behind an ambulance both starting a heal and spending 500 Volts.
    --
    -- It needs client/main.lua for the loop registry, client/keybinds.lua for
    -- BR.Keys, client/dui.lua for the shared prompt page and client/natives.lua
    -- for BR.Native.keyLabelForCommand -- the same four names client/ambheal.lua
    -- and client/shop.lua list, all of which are above.
    --
    -- IT IS A SECOND HANDLER ON SQUAD_POS, alongside client/squadmates.lua, and
    -- that needs no order at all: FiveM fans an event to every handler, and
    -- neither file reads the other's cache.
    'client/revivekey.lua',
    -- The fuel gauge, the pump prompt and the station blips. AFTER dui.lua
    -- (it borrows the crate's prompt page) and AFTER keybinds.lua (it reads
    -- BR.Keys.isHeld('interact')); it reads BR.Native.blipName at call time, so
    -- natives.lua only has to be somewhere above, which it is.
    -- The boost: the meter, the forward impulse and the tailpipe flames. AFTER
    -- keybinds.lua, which is a real load order rather than a reader's -- it
    -- reads BR.Keys.isHeld('boost') every frame and BR.Keys.labelFor in
    -- /brboostinfo -- and BEFORE client/fuel.lua for a READER: fuel.lua's
    -- pushBars asks BR.Boost.meter() for the third bar in the vehicle envelope,
    -- so the file that answers is declared above the file that asks. It reaches
    -- it at call time and nil-guards, so the loader does not care.
    'client/boost.lua',
    'client/fuel.lua',
    -- How breakable a car is: the four handling multipliers, written on this
    -- machine, to the car this player is in. NEEDS NOTHING ABOVE IT EXCEPT
    -- client/main.lua for the loop registry -- it reads BR.Config.VehicleDamage
    -- (a shared config, already loaded) and BR.NormHash (geo.lua, likewise), and
    -- it talks to no other subsystem in either direction. It is declared HERE,
    -- after client/fuel.lua, for a reader: fuel.lua is the file that draws the
    -- condition bar this one makes move, and the file that puts the health back.
    'client/vehdamage.lua',
    -- Refusing an aircraft, a tank or an armed vehicle at the door (#215): eject,
    -- one sentence, lock it behind them. NEEDS client/main.lua for the loop
    -- registry and NOTHING ELSE AT LOAD TIME -- BR.Notify (client/state.lua) and
    -- BR.State are both reached at call time, and the ruling comes from
    -- BR.Config.VehicleRefusalFor, a shared config already loaded above.
    --
    -- Declared HERE, immediately after client/vehdamage.lua, for a reader: these
    -- two are the pair that act on the vehicle a player is climbing into, they
    -- ride the same `GetVehiclePedIsEntering` window, and they are the only two
    -- files that do. It is ADVISORY -- see its header; the enforcement is
    -- server/vehicles.lua and always was.
    'client/vehrefuse.lua',
    -- The spectator camera. Needs BR.Keys (keybinds.lua) for the arrows and
    -- BR.Native (natives.lua) for the scoped ped lookup; client/lobbycam.lua
    -- reads BR.Spectate.active() at call time, so load order between the two
    -- does not matter.
    'client/spectate.lua',
    'client/chat.lua',
    'client/voice.lua',   -- Mumble channels; server/voice.lua decides them
    'client/probe.lua',    -- /brprobe: what the natives ACTUALLY do on this build
    -- /brattach: attach the ped to a vehicle and nudge the offset until it looks
    -- right (#191's stretcher). Beside probe.lua because it is the same kind of
    -- thing -- a command that MEASURES what has to be written down, rather than
    -- a subsystem -- and nothing in the gamemode calls it.
    --
    -- NEEDS client/main.lua FOR THE LOOP REGISTRY AND NOTHING ELSE AT LOAD TIME.
    -- BR.PlayerState comes from shared/enums.lua, already the first line above.
    -- BR.State, BR.Config.Rescue and BR.NormHash are all reached at CALL time
    -- and nil-guarded -- BR.Config.Rescue deliberately, because #191's config is
    -- landing alongside this and the tool has to work with or without it.
    'client/attachtune.lua',
    -- /brsurvey: pick the playable boundary off the pause map, one waypoint per
    -- corner, and print it as a config table. Beside probe.lua and
    -- attachtune.lua because it is the same kind of thing -- a command that
    -- MEASURES what has to be written down -- and nothing in the gamemode calls
    -- it.
    --
    -- AFTER client/markers.lua, and that is a READER'S order rather than the
    -- loader's. The two want the same gesture: markers.place consumes any fresh
    -- waypoint and turns it into a squad ping, so it stands down while
    -- BR.Survey.active(). It reads that nil-guarded at call time -- exactly as
    -- it reads BR.Rescue.riding() one line above -- so the file that yields is
    -- declared above the file it yields to, and the loader does not care.
    --
    -- It needs client/main.lua for the loop registry and client/natives.lua for
    -- BR.Native.radiusBlip and BR.Native.blipName; BR.Dist comes from
    -- @br_lib/shared/geo.lua, already loaded above.
    'client/survey.lua',
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
    -- THE ONLY config/*.lua THIS RESOURCE LOADS SERVER-SIDE, and the exception
    -- is deliberate: every other config file is in shared_scripts above and goes
    -- to clients with them. This one is the domain and shortener lists, and a
    -- player holding those knows exactly which host still gets through. Read
    -- lazily by chat_screen.lua, so this ordering is belt to that braces.
    '@br_lib/config/chat.lua',
    -- BEFORE incident_build.lua, which calls BR.ChatScreen.clamp when it builds
    -- a refused-chat timeline entry, and before server/chat.lua, whose sanitise
    -- calls it on every message. SERVER-ONLY like the two beside it: what the
    -- server will not carry is a moderation rule, and shipping the domain list
    -- to clients would hand every player the exact shape of the filter.
    '@br_lib/shared/chat_screen.lua',
    '@br_lib/shared/incident_build.lua',
    -- SERVER-ONLY for the same reason as the two above: how many screenshots a
    -- case gets, and when, is a moderation rule. server/artifacts.lua calls
    -- BR.ArtifactPlan.new() at load time, so this must precede it.
    '@br_lib/shared/artifact_plan.lua',
    'server/main.lua',      -- defines BR.Server and starts the scheduler
    'server/clock.lua',
    -- brtime and brweather: the console's clock and sky. AFTER server/main.lua,
    -- and that IS a real order rather than a reader's -- both verbs read
    -- BR.Server.devMode, which main.lua resolves from the convars. It is
    -- declared beside server/clock.lua because a reader looking for "the time"
    -- will land on one of the two, and they are opposite halves of the subject:
    -- clock.lua is the network clock every countdown is derived from, this is
    -- the world clock the sun hangs on.
    'server/world.lua',
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
    -- The CPR kit's rescue (#191). AFTER combat.lua and inventory.lua, and both
    -- matter at CALL time rather than at load: it eliminates and revives through
    -- BR.Combat, and it reads and spends a kit through BR.Inv. The dependency
    -- also runs the other way -- BR.Combat.canBeDowned asks BR.Rescue.holdsKit
    -- whether a solo's death is a knock -- and that call is guarded on
    -- `BR.Rescue ~= nil`, because a lethal hit can land before this file has
    -- loaded and the honest answer during that window is "no kit".
    'server/rescue.lua',
    -- The claim on an ambulance somebody is healing in (owner, 2026-08-28).
    -- AFTER server/rescue.lua, AND THAT IS A REAL ORDER RATHER THAN A READER'S
    -- -- but only just, and it is worth being precise about which:
    --
    --   AT LOAD it needs BR.Sched (already above, in shared) and nothing else.
    --   AT CALL it asks BR.Rescue three questions -- isAmbulance, vehicleBusy
    --   and noteVehicle -- and all three are nil-guarded, because a build
    --   without the rescue half should heal nobody rather than throw. So the
    --   order is what makes the guards never fire in a shipped server, and the
    --   guards are what make the order not load-bearing.
    --
    -- IT IS DECLARED HERE, immediately after the file it borrows from, so the
    -- two ambulance features read as a pair on this page the way they do in
    -- br_lib/config.
    'server/ambheal.lua',
    -- The squad's revive key (#219 step 4). AFTER server/rescue.lua and for the
    -- same reason server/ambheal.lua is -- it asks BR.Rescue.isAmbulance what an
    -- ambulance is, nil-guarded, so the order is what keeps the guard from ever
    -- firing rather than a load requirement.
    --
    -- ITS OWN CALLER IS ABOVE IT, WHICH IS THE ORDER THAT DOES NOT MATTER.
    -- server/combat.lua calls BR.ReviveKey.onEliminated at elimination, guarded
    -- on `BR.ReviveKey ~= nil` -- the same arrangement it has with BR.Loot and
    -- with BR.Rescue, and for the same reason: a lethal hit can land before this
    -- file has loaded, and the honest behaviour in that window is a death with
    -- no key rather than a throw inside the elimination path.
    'server/revivekey.lua',
    -- The 23 station ambulances (#219 step 3). AFTER server/rescue.lua, and this
    -- is a READER'S order in one direction and a real one in NEITHER:
    --
    --   AT LOAD it needs BR.Sched, BR.Config.Ambulances and BR.Config.Match --
    --   all of them above, all of them br_lib except the scheduler.
    --   AT CALL it builds vehicles through BR.Vehicles.spawnOwned, which is
    --   declared BELOW this line (with the allowlist tools/verify.sh requires it
    --   to sit beside) and is resolved when the bus doors open rather than at
    --   load -- exactly the arrangement server/rescue.lua already has with the
    --   same function.
    --
    -- THE DEPENDENCY ALSO RUNS BACKWARDS, and that is the one worth naming:
    -- server/rescue.lua asks BR.Ambulances.displace, from ABOVE this line and
    -- nil-guarded, so that its ride is not created inside a parked station
    -- ambulance. A build without this file spawns on the surveyed point exactly
    -- as it did before, which is correct when there is nothing parked there.
    'server/ambulances.lua',
    'server/loot.lua',      -- world loot: layout, streaming, claim arbitration
    -- Aerial supply drops. AFTER storm.lua and loot.lua for a reader rather
    -- than for the loader: it asks BR.StormAt where the circle will be when the
    -- crate arrives, and hands the contents to BR.Loot.spawnStack so they
    -- inherit the hardened claim path. Both are call-time.
    'server/airdrop.lua',
    'server/damage.lua',    -- M6: weaponDamageEvent validation and attribution
    'server/markers.lua',   -- player map markers: relay + squad scoping
    -- The fuel ledger: a metre budget per VEHICLE, spent by driving and bought
    -- back at a petrol station. AFTER roster.lua, and that one is a real load
    -- order rather than a reader's: it calls BR.Roster.sampleIntervalMs() at
    -- load time to register its consumption pass on the same clock the position
    -- sampler runs on, which is the whole reason a distance budget is free.
    -- The boost relay, and the answer to "was this vehicle boosting". BEFORE
    -- server/fuel.lua for a READER rather than for the loader: fuel.lua's sample
    -- pass calls BR.Boost.fuelMultiplier at call time and nil-guards it, so the
    -- order on the page is the order of the question. It needs BR.Sched (already
    -- above, in shared) for its sweep and BR.Roster for the driver check, which
    -- it reads at call time.
    'server/boost.lua',
    'server/fuel.lua',
    'server/chat.lua',
    'server/voice.lua',    -- voice channel authority: one room per match, one per squad
    'server/debug.lua',
    'server/market.lua',    -- inventory, purchases and equipped slots
    -- The warmup vehicle shop (#224). AFTER market.lua, and that is a REAL
    -- order rather than a reader's in one direction and a reader's in the
    -- other:
    --
    --   AT CALL it charges through BR.Market.charge and reads
    --   BR.Market.balanceOf -- the market owns the ledger and this file owns no
    --   copy of it -- and it builds the car through BR.Vehicles.spawnOwned,
    --   which tools/verify.sh requires to be the only server-side creation
    --   path. Both are call-time, so the declaration order is the order of the
    --   question.
    --   AT LOAD it needs nothing but BR.Config, which is br_lib and is above
    --   everything here.
    --
    -- server/match.lua CALLS INTO IT from onEnter(BUS) -- from ABOVE this line,
    -- and nil-guarded, exactly as the rescue's own back-references are: a
    -- server without a shop must start a bus flight rather than throw.
    'server/shop.lua',
    -- Admin scopes, read from the same DynamoDB grants table the console
    -- authorises against, through br_ddb -- never from br_ringmaster, which the
    -- game must not depend on. players.lua and incident.lua both read it, and
    -- both nil-guard it, so the order is for a reader rather than for the
    -- loader: the thing that answers the question is declared above the two
    -- files that ask it.
    'server/grants.lua',
    -- The Admin tab in the pause menu. AFTER grants.lua for a reader rather
    -- than for the loader: it asks BR.Grants.holds the question grants.lua
    -- answers, and it is declared below the file that answers it.
    'server/admin.lua',
    -- Whether a player is already in our Discord: one authenticated GET to
    -- Discord per connection, cached for that connection. AFTER
    -- @br_lib/shared/identity.lua, and that IS a real order rather than a
    -- reader's -- it resolves the `discord:` identifier through BR.Identity, and
    -- identity.lua is the second line of this list.
    --
    -- BEFORE community.lua for a reader rather than for the loader: the file
    -- that answers the question is declared above the file that asks it, exactly
    -- as grants.lua sits above admin.lua.
    'server/guild.lua',
    -- The Discord card in the pause menu. ITS ONLY LOAD-ORDER REQUIREMENT IS
    -- br_lib: it reads BR.Config.Community at call time rather than at load, and
    -- it nil-guards BR.Guild above -- so a checkout with guild.lua removed still
    -- sends the invite and simply shows the card to everybody, which is this
    -- feature's own default. It is declared beside admin.lua because it is the
    -- second file to answer br:ready with a small envelope for the pause menu,
    -- and a reader looking for one will find the other.
    'server/community.lua',
    -- Spectate sessions and the squad rule. AFTER combat.lua and party.lua for
    -- a reader rather than for the loader: it asks the roster who is still in
    -- the fight, and both of those are what make that answer true.
    'server/spectate.lua',
    'server/players.lua',   -- the in-game player list and player reports
    'server/ringmaster.lua', -- the admin-console snapshot feed; emits, never listens
    'server/incident.lua',  -- builds incident payloads from evidence; emits, never enforces
    -- The second anticheat detector, beside server/damage.lua's: a weapon the
    -- inventory never issued, taken out of a ped's hand by client/inventory.lua
    -- and reported here. AFTER incident.lua for a reader rather than for the
    -- loader -- it raises `br:core:stripped`, which that file answers, and the
    -- order on the page is the order of the pipeline. It reads BR.Grants,
    -- BR.Evidence and BR.Inv at call time only, so nothing above it is needed at
    -- load.
    'server/strip.lua',
    -- The third anticheat detector: a networked vehicle the gamemode refuses,
    -- caught in the server-side `entityCreating` before the entity exists.
    -- AFTER incident.lua for a reader rather than for the loader -- it raises
    -- `br:core:vehicle`, which that file answers, and the order on the page is
    -- the order of the pipeline. Beside strip.lua because the two are the same
    -- shape: count, hold a bar, hand over, never enforce.
    'server/vehicles.lua',
    -- Screenshots of the offender, taken on their own client and uploaded to S3
    -- through br_ddb. AFTER incident.lua and players.lua for a reader rather
    -- than for the loader: it listens to `br:incident:filed` and
    -- `br:ringmaster:corroborate`, which those two raise, and it is declared
    -- below both so the order on the page is the order of the pipeline.
    'server/artifacts.lua',
}

dependency 'br_lib'
