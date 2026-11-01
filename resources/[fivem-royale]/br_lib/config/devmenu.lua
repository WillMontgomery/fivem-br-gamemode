-- The dev menu (#422): its words, its key and the server's limits -- and its
-- vehicle spawner's (#426).
--
-- Owner, 2026-10-24: "What I need now is a dev-only menu using the same UI as
-- our gun store. It should control things like time, weather, match state,
-- give volts, give Yubikeys, Storm pause, warmup pause, spawn airdrops"
--
-- SHARED BECAUSE BOTH HALVES READ IT. The client builds its rows out of the
-- labels and the lists below; the server takes a request only when its
-- value is one of those same lists, so a row can never offer something the
-- server refuses and a hand-typed request can never ask for something no row
-- offers. One copy of each list, read by both, is what keeps that true.
--
-- NOTHING HERE IS A SERVER TUNABLE. The menu exists only on a dev box -- every
-- request is the dev-mode command `brdevsv` -- so there is no public number to
-- override. See docs/devmenu.md.

BR = BR or {}
BR.Config = BR.Config or {}

BR.Config.DevMenu = {
    -- THE OWNER'S WORDS, each row as he named it on 2026-10-24, and nothing
    -- else. No descriptions, no hints, no empty-state lines: a row says what it
    -- is and the value beside it says what it will do.
    --
    -- `title` and `player` and `reset` are the three the menu needs that he did
    -- not say. `title` is the bar the library draws with no banner art under
    -- it; `player` is the row the two gives read their player from; `reset`
    -- is the value that hands the clock and the sky back, the console verbs'
    -- own word for it.
    --
    -- THE VEHICLE SPAWNER'S THREE (#426). Owner, 2026-11-01: "can you also add
    -- to our dev menu a vehicle spawner menu? ... include spawn by name ... put
    -- a note on their row in red that says "Armed"". `armed` is his word
    -- exactly; `vehicles` and `byName` name the two rows he asked for, and are
    -- his to replace. The class rows are named by the game, not here.
    labels = {
        title   = 'Dev menu',
        time    = 'Time',
        weather = 'Weather',
        match   = 'Match state',
        player  = 'Player',
        volts   = 'Give volts',
        yubikey = 'Give Yubikeys',
        storm   = 'Storm pause',
        warmup  = 'Warmup pause',
        airdrop = 'Spawn airdrops',
        reset   = 'Reset',
        vehicles = 'Vehicle spawner',
        byName   = 'Spawn by name',
        armed    = 'Armed',
    },

    --- The one sentence the vehicle spawner's CLIENT says itself (#426), as a
    --- warning toast and on F8: a vehicle row or a typed name it will not ask
    --- the server for -- a name that is not a vehicle this game has, or a
    --- train. `%s` is the name, as typed. Every other refusal is the server's,
    --- in brcar's own words.
    cannotSpawn = '%s cannot be spawned',

    --- The key that opens it, as RegisterKeyMapping takes it. A DEFAULT: the
    --- player moves it in FiveM's own key bindings (Settings > Key Bindings >
    --- FiveM), and the mapping is not registered at all until this client
    --- reads dev mode on, so the public box's binding list never shows it.
    key = 'F10',

    --- The amounts the Give volts row offers, smallest first. THE SERVER TAKES
    --- ONLY THESE: an amount that is not in this list is dropped as a request
    --- no row could have sent, which is also the bound on what one press can
    --- mint. `brvolts` on the server console still takes any amount, negative
    --- ones included, for testing the spend path.
    volts = { 100, 500, 1000, 5000, 10000 },

    --- The values the Match state row offers, in `brforce`'s own usage order,
    --- and `skip`, which is `brskip`. THE SERVER TAKES ONLY THESE.
    states = { 'waiting', 'warmup', 'bus', 'playing', 'ended', 'cleanup', 'skip' },

    --- The sync trees a vehicle request may name (#426), as
    --- CreateVehicleServerSetter spells them. THE SERVER TAKES ONLY THESE.
    ---
    --- THE PLATFORM BUILDS AN EIGHTH, `train`, AND IT IS LEFT OUT ON PURPOSE.
    --- The server setter fills a train's creation and position and none of the
    --- nodes a train runs on -- "Its not possible to spawn trains using
    --- CREATE_VEHICLE_SERVER_SETTER" (Cfx, forum.cfx.re/t/5217679, 2025-08-25)
    --- -- so a request naming one is a request no row sends.
    vehicleTypes = { 'automobile', 'bike', 'boat', 'heli', 'plane', 'submarine', 'trailer' },

    --- The vehicle classes the spawner lists no row for, by the game's class
    --- number. 21 is Trains: every model in it is a train, and a train cannot
    --- be built this way (above).
    vehicleClassesLeftOut = { 21 },

    --- The longest model name the keyboard takes and the server reads -- the
    --- dev props' bound (BR.Config.Props.nameMaxLen), for the dev props'
    --- reason: the name travels into a console line.
    modelMaxLen = 64,

    --- The server drops a request that arrives sooner than this after the last
    --- one it read from the same player, good or bad. Nothing in the menu
    --- sends faster than a person can press Enter; this is the floor under a
    --- client that does.
    minIntervalMs = 250,
}

--- A vehicle request's model name, lower-cased, or nil (#426).
---
--- ONE RULE FOR BOTH HALVES, which is why it is here. The client sends only a
--- name this answers for, and the server takes only a name this answers for --
--- so a row can never send a name the server drops, and a hand-typed request
--- can never get a stranger string past the server than a row could.
---
--- LETTERS, DIGITS, `_` AND `-`, at most modelMaxLen of them: what an archetype
--- name is, and the dev props' rule (br_lib/shared/props_solve.lua's
--- modelName). Lower-cased because GTA hashes a name lower-cased, so `Lazer` --
--- the game registers it that way -- and `lazer` are one model.
--- @param s any
--- @return string|nil
function BR.Config.DevMenu.modelWord(s)
    if type(s) ~= 'string' or s == '' then return nil end
    if #s > (BR.Config.DevMenu.modelMaxLen or 64) then return nil end
    if not s:match('^[A-Za-z0-9_%-]+$') then return nil end
    return s:lower()
end
