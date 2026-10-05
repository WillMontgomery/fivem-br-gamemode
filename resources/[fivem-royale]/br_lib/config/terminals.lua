-- Season 2 terminals (#396): the computer a Yubikey unlocks, and the functions
-- it can run.
--
-- ═══ THE OWNER'S DECISIONS, 2026-10-04 (#396) ═══
--
--   * Every terminal works unless it is OUTSIDE the storm.
--   * A Yubikey is an owned item, one per player, shown as an icon, no slot;
--     it carries into the next match if unused and drops when its holder dies.
--   * ONE use per squad per match; the squad's other holders are refused.
--   * The lobby hears when someone gains access, and again when an action is
--     selected and activated, "so they don't think the server's been hacked".
--   * Storm reveal shows where the storm will end this match, to the squad.
--
-- ═══ THIS FILE IS THREE THINGS ═══
--
--   copy       every player-facing line the feature shows, in ONE block
--   functions  the function registry: what a terminal lists, in order
--   the numbers the server's door uses
--
-- ═══════════════════════════════════════════════════════════════════════════
-- THE COPY: EVERY LINE IS A PLACEHOLDER UNTIL THE OWNER WRITES IT
-- ═══════════════════════════════════════════════════════════════════════════
--
-- The owner writes or approves every player-facing line (#396), so every value
-- below is an obvious placeholder in brackets, and nothing anywhere else in the
-- feature is allowed a word of its own: the desktop (cuchi_computer's br.js)
-- and the terminal app (ui-src/terminal) render only keys out of this table,
-- and a key with no line renders as nothing. Replacing a placeholder is an
-- edit here and a restart; no UI rebuild.
--
-- WHO READS EACH LINE is in its comment. "At the terminal" is the one player
-- using the computer; "the lobby" is everyone in that match.
--
-- The desktop and the app receive the whole table with the state
-- (br_core/client/terminal.lua), so a line used by both -- `no_key`,
-- `squad_used`, `offline` are both a prompt in the world and the reason a
-- function cannot run -- is written once.

BR = BR or {}
BR.Config = BR.Config or {}

BR.Config.Terminals = {
    copy = {
        -- ── in the world (the Gameplay half of #396 shows these) ──────────────

        -- To the player picking up a Yubikey for the first time ever: what it
        -- does and how to use it.
        first_pickup = '[COPY: first pickup -- what a Yubikey does and how to use it]',
        -- To a player at a terminal without a key: what they need to get in.
        -- Also the app's reason when a function cannot run for that cause.
        no_key = '[COPY: terminal without a key -- what is needed to get access]',
        -- To a player at a terminal that is outside the storm. Also the app's
        -- reason for that cause.
        offline = '[COPY: terminal offline -- it is outside the storm]',
        -- To a holder walking over a second Yubikey.
        already_holding = '[COPY: pickup refused -- you already hold a Yubikey]',
        -- To a holder whose squad has already used its one key this match.
        -- Also the app's reason for that cause.
        squad_used = '[COPY: refused -- your squad already used a key this match]',
        -- To the lobby, when someone gains access to a terminal.
        notice_access = '[COPY: lobby notice -- someone gained access to a terminal]',
        -- To the lobby, when an action is selected and activated.
        notice_action = '[COPY: lobby notice -- an action was selected and activated]',

        -- ── the desktop (cuchi_computer) -- at the terminal ───────────────────

        -- Under the boot spinner, for the quarter second the desktop starts.
        shell_boot = '[COPY: computer starting up]',
        -- Under the terminal app's desktop icon.
        desktop_icon = '[COPY: desktop icon -- the terminal app]',
        -- The terminal app's window title bar.
        window_title = '[COPY: terminal app window title]',

        -- ── the terminal app (ui-src/terminal) -- at the terminal ────────────

        -- The heading over the function list.
        app_heading = '[COPY: terminal app -- heading over the function list]',
        -- The status of a function that can run now.
        available = '[COPY: function status -- available]',
        -- The status of a function that cannot, for a reason with no line of
        -- its own.
        unavailable = '[COPY: function status -- unavailable]',
        -- The button that runs a function.
        run = '[COPY: button -- run this function]',

        -- ── the functions: <id>_name in the list, <id>_done once it ran ──────

        storm_reveal_name = '[COPY: function name -- Storm reveal]',
        -- At the terminal, once the server has run it. (Whether the squad
        -- also hears it is the Gameplay half's to decide.)
        storm_reveal_done = '[COPY: Storm reveal confirmation]',
    },

    -- ═══ THE FUNCTION REGISTRY ═══
    --
    -- What a terminal lists, in this order. An id is lower case, letters,
    -- digits and underscores, at most 32 characters (the page and the server
    -- both check that shape), and every id has `<id>_name` and `<id>_done`
    -- lines above. The server half is a table of the same ids in
    -- br_core/server/terminal.lua (BR.Terminal.FUNCTIONS): whether one can run
    -- for this player at this terminal, and what running it does. A function
    -- the owner has not decided yet (Scan and its bounty, the rest of #396's
    -- list) gets a row here and an entry there when he has.
    functions = {
        { id = 'storm_reveal' },
    },

    -- The server drops a second run request from one player sooner than this
    -- after the last. A run is one click and the button disables itself while
    -- it waits, so anything faster is not a person.
    runMinIntervalMs = 500,
}
