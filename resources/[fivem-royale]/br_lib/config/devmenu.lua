-- The dev menu (#422): its words, its key and the server's limits.
--
-- Owner, 2026-10-24: "What I need now is a dev-only menu using the same UI as
-- our gun store. It should control things like time, weather, match state,
-- give volts, give Yubikeys, Storm pause, warmup pause, spawn airdrops"
--
-- SHARED BECAUSE BOTH HALVES READ IT. The client builds its rows out of the
-- labels and the two lists below; the server takes a request only when its
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
    },

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

    --- The server drops a request that arrives sooner than this after the last
    --- one it read from the same player, good or bad. Nothing in the menu
    --- sends faster than a person can press Enter; this is the floor under a
    --- client that does.
    minIntervalMs = 250,
}
