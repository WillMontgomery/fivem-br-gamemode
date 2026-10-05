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
        -- ── in the world ──────────────────────────────────────────────────────
        --
        -- TWO TOKENS, and only in the two lobby notices: {playername} is the
        -- player who did it (drawn bold, like every name in a toast -- it
        -- travels as BR.Notice.who, never formatted into the string), and
        -- {description} is the function's `<id>_description` line. The owner's
        -- own wording for the notices (#396, 2026-10-04) uses exactly these.

        -- A toast to the player picking up a Yubikey for the first time ever:
        -- what it does and how to use it. Once per player, ever (the profile
        -- row's yubikeySeen).
        first_pickup = '[COPY: first pickup -- what a Yubikey does and how to use it]',
        -- To a player at a terminal without a key: what they need to get in.
        -- The hint on the terminal's world plate, and the app's reason when a
        -- function cannot run for that cause.
        no_key = '[COPY: terminal without a key -- what is needed to get access]',
        -- To a player at a terminal that is outside the storm: the plate's
        -- hint, a toast if they use it anyway, and the app's reason.
        offline = '[COPY: terminal offline -- it is outside the storm]',
        -- A toast to a holder trying to pick up a second Yubikey.
        already_holding = '[COPY: pickup refused -- you already hold a Yubikey]',
        -- To a holder whose squad has already used its one key this match:
        -- the plate's hint and the app's reason.
        squad_used = '[COPY: refused -- your squad already used a key this match]',
        -- A toast to the lobby (everyone in the match, the dead and spectators
        -- included) when someone gains access to a terminal with a key.
        notice_access = '[COPY: lobby notice -- {playername} gained access to a terminal]',
        -- A toast to the lobby when that player picks a function and it runs.
        notice_action = '[COPY: lobby notice -- {playername} activated: {description}]',
        -- The Yubikey's name on the world plate over a key lying on the ground,
        -- read by anyone who walks up to it.
        key_label = '[COPY: Yubikey -- its name on the ground pickup]',
        -- The title on a terminal's world plate, read by anyone near it.
        terminal_label = '[COPY: terminal plate -- title]',
        -- The plate's hint under that title when this player can use it now
        -- (holding a key, the squad's use unspent, inside the storm). The key
        -- cap and the hold ring are drawn beside it.
        terminal_use = '[COPY: terminal plate -- hold to use]',

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

        -- ── the functions ─────────────────────────────────────────────────────
        --
        -- Every listed id has three lines: <id>_name in the app's list,
        -- <id>_done at the terminal once it ran, and <id>_description, the
        -- {description} in notice_action. tools/test_terminal.lua fails an id
        -- missing one.

        storm_reveal_name = '[COPY: function name -- Storm reveal]',
        -- At the terminal, once the server has run it. The squad is not sent a
        -- line of its own: the lobby's notice_action already reaches them, and
        -- the final zone appears on their maps (art.reveal below).
        storm_reveal_done = '[COPY: Storm reveal confirmation]',
        storm_reveal_description = '[COPY: Storm reveal -- its {description} in the lobby notice]',
        -- The revealed final zone's name in the pause map's legend, read by
        -- the squad that ran it.
        storm_reveal_blip = '[COPY: map legend -- where the storm ends]',
    },

    -- ═══ THE ART: EVERY PLACEHOLDER IN ONE SPOT ═══
    --
    -- The owner's Yubikey prop (`blitz_seckey`, in the Season 2 props resource)
    -- and HUD icon replace the first two; until then they are a stock GTA prop
    -- and a plain glyph. The blips are the owner's own numbers (#396,
    -- 2026-10-04: "type 521, color 51 (draws as a laptop)").
    art = {
        -- The Yubikey lying on the ground: any loose key, from a crate, an
        -- airdrop, a death or a leave. Drawn by client/loot.lua like any loot,
        -- at keyScale times its authored size (a USB stick is a few
        -- centimetres long).
        keyProp = 'prop_cs_usb_drive',
        keyScale = 4.0,
        -- The equipped icon on the HUD, and the mark beside a holder's name in
        -- the squad panel. A string drawn as text.
        hudGlyph = '⚿',
        -- A terminal in the world: a local, non-networked prop per site.
        terminalProp = 'prop_laptop_01a',
        -- A terminal's blip, drawn only while this player holds a key and only
        -- for a terminal inside the storm.
        blipSprite = 521,
        blipColour = 51,
        blipScale = 0.9,
        -- Storm reveal: where the storm ends, on the squad's pause map and
        -- minimap from activation to the end of the match. A radius blip around
        -- the final point plus a sprite at it.
        reveal = { sprite = 161, colour = 1, scale = 1.0, radiusM = 60.0, alpha = 120 },
    },

    -- ═══ WHERE A YUBIKEY COMES FROM (owner, 2026-10-04) ═══
    --
    -- Both are EXTRA items: rolled on their own stream when the container
    -- opens, after its contents were decided, so today's loot odds do not
    -- move. "for now let's only make it a 50/50 chance in airdrops instead of
    -- every single one", and "a small chance in legendary crates".
    sources = {
        airdropChance = 0.5,
        legendaryCrateChance = 0.05,
    },

    -- ═══ LEAVING A MATCH ALIVE ═══
    --
    -- UNDECIDED (#396): the owner has not ruled. True -- the default, as
    -- proposed on the issue -- drops a held key where the leaver stood, like
    -- a death, so quitting is not a way to keep a key you were about to lose.
    -- False lets a leaver keep it. Covers both walking out (Leave Match) and
    -- disconnecting mid-match.
    leaveDrops = true,

    -- ═══ THE TERMINALS ═══
    --
    -- One row per terminal in the world, placed in game with the dev tool
    -- (`brterminal place` prints the row to paste here):
    --
    --   { id = 'airport_tower', x = 0.0, y = 0.0, z = 0.0, h = 0.0 },
    --
    -- `id` is lower case letters, digits and underscores, at most 32
    -- characters, and unique; x/y/z is where the prop stands and h its heading.
    -- EMPTY UNTIL THE OWNER PLACES THEM ("Terminal sites: placed in game with
    -- a dev placement tool rather than guessed").
    sites = {
    },

    -- How close a player must stand to a terminal to see its plate and to use
    -- it, in metres. The server allows `useSlackM` more, for a position sample
    -- up to a quarter second old (the loot claim's REACH_SLACK, for the same
    -- reason).
    useDistanceM = 2.5,
    useSlackM = 2.0,
    -- How long interact is held to open the computer.
    holdMs = 800,
    -- How often a client re-asks which terminals are inside the storm and
    -- redraws their blips. The wall moves metres per second; a second is
    -- plenty, and it is one zone build per pass however many terminals.
    clientPassMs = 1000,
    -- How often the server checks every open computer is still at a live
    -- terminal with a living player beside it, and closes it if not.
    sessionCheckMs = 500,

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
