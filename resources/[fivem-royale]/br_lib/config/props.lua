-- Dev props (#384): the numbers behind /brprop.
--
-- Owner, 2026-10-03: "I'm testing some custom props - first ever, made by
-- Claude, and I want a way to spawn them in. I would like something akin to our
-- pickups where it hovers/bobs/rotates when close, and I need a way to interact
-- with it manually like moving in every direction, and rotating. Be sure the
-- server spawns it since clients can't. Give me tools to spawn objects by name
-- and I'll stream them"
--
-- A DEV TOOL, AND EVERYTHING HERE IS A LIMIT OR A FEEL. The pickup look is not
-- in this file at all: a prop shown as a pickup reads BR.Config.Loot's own
-- hover numbers at call time (see br_lib/shared/props_solve.lua), so retuning
-- the loot retunes these with it and the two can never drift apart.
--
-- Nothing here is a server tunable. The props exist only on a dev box -- every
-- door is behind BR.Admin.devTrusted -- so there is no public number to override.

BR = BR or {}
BR.Config = BR.Config or {}

BR.Config.Props = {
    -- THE SERVER'S LIMITS. Every one is enforced in br_core/server/props.lua
    -- against what a client sent; the client checks the same rules first only
    -- so a refusal can be printed before anything goes over the wire.

    --- How many props may exist at once. Each is one local object on every
    --- client, and a record in every full sync a late joiner is sent.
    maxProps    = 64,

    --- A model name is letters, digits, `_` and `-`, at most this long. GTA's
    --- own archetype names are well under it; the cap is about a payload, not
    --- about any real model.
    nameMaxLen  = 64,

    --- A prop outside the surveyed playable boundary is still allowed within
    --- this many metres of the player asking -- the warmup pad and the lobby
    --- are outside the island's outline, and a dev standing there must be able
    --- to place something in front of himself.
    nearM       = 150.0,

    --- The world box. Anything outside it is a broken number rather than a
    --- placement, wherever the requester is standing. Generous on purpose:
    --- the real map fits well inside it.
    world       = { xy = 10000.0, zMin = -500.0, zMax = 3000.0 },

    --- The server drops an edit update that arrives sooner than this after the
    --- last one from the same player. The client sends at sendHz below (100ms
    --- apart); this is the floor under a client that does not. The confirm is
    --- never dropped.
    moveMinMs   = 50,

    --- Where `/brprop save` writes, inside br_core, with SaveResourceFile.
    --- tools/deploy.sh excludes it from the rsync's --delete and .gitignore
    --- ignores it, so a dev deploy does not wipe the saved placements and a
    --- local save is never committed.
    saveFile    = 'devprops.json',

    -- THE CLIENT'S FEEL.

    --- How long a model may take to stream before the spawn is refused, and
    --- before a client gives up drawing someone else's prop.
    loadWaitMs  = 5000,

    --- `/brprop spawn` puts the prop this far in front of the player, plus
    --- half its own footprint so a big model does not land on his feet.
    spawnAheadM = 1.5,

    --- `/brprop edit` with no id takes the nearest prop within this range.
    pickRangeM  = 50.0,

    --- Edit-mode step sizes. Ctrl held is coarse. Attachtune's numbers
    --- (client/attachtune.lua), so the two hand tools move the same way:
    --- 1cm and 1 degree for the last nudge, 10cm and 15 degrees to get there.
    step = {
        fine   = { m = 0.01, deg = 1.0 },
        coarse = { m = 0.10, deg = 15.0 },
    },

    --- A tap is exactly one step. Held, the key repeats after repeatDelayMs and
    --- then every repeatMs -- 20 steps a second whatever the frame rate.
    repeatDelayMs = 250,
    repeatMs      = 50,

    --- How often the edit preview is sent to the server while it changes.
    --- The issue says at most 10 Hz; the confirm is sent once more on top.
    sendHz      = 10,
}
