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
--   * Scan shows opponents for the rest of the match to the whole squad, and
--     puts a 10-minute bounty on the player who ran it (the spec is in the
--     `fx` block below).
--
-- ═══ AND 2026-10-05: THE APP ═══
--
-- "The app should look like a web browser", a card per function "so the user
-- can pick between them, navigate between them, understand what they do", a
-- detail page per card with "what options they have ... what it does, what
-- risks it holds for them -- just don't tell them how it can help them", a
-- how-to page, and "please build all of the cards for all the tools I
-- suggested, as well as any other strategic ones you can suggest".
--
-- ═══ AND 2026-10-05, ROUND 2 ═══
--
-- The app is "Control Tower". Thunderstorm is not a weather anyone can pick.
-- "Squad" is only said to a player in a squad match (`<key>_solo` below).
-- The most powerful functions cost Volts, 200 at most (`cost` on the rows).
-- "Offline" became "Not available". The desktop boots for 7 to 10 seconds
-- (bootMinMs / bootMaxMs) and a run loads for 3 to 5 (runMinMs / runMaxMs).
--
-- ═══ THIS FILE IS FOUR THINGS ═══
--
--   copy       every player-facing line the feature shows, in ONE block
--   functions  THE REGISTRY: every function a terminal lists, in order, with
--              its category, risk, options and whether its effect is built.
--              The server rules runs against it (br_core/server/terminal.lua)
--              and the app draws its cards and pages from it (br_core's client
--              hands it to the computer with each opening)
--   fx         the numbers the built effects use (Scan, the bounty, the push)
--   the numbers the server's door uses
--
-- ═══════════════════════════════════════════════════════════════════════════
-- THE COPY
-- ═══════════════════════════════════════════════════════════════════════════
--
-- The owner writes or approves every player-facing line (#396). Nothing
-- anywhere else in the feature is allowed a word of its own: the desktop
-- (cuchi_computer's br.js) and the terminal app (ui-src/terminal) render only
-- keys out of this table, and a key with no line renders as nothing.
-- Replacing a line is an edit here and a restart; no UI rebuild.
--
-- THREE KINDS OF LINE, and the comment over each block says which:
--
--   VERBATIM   the owner's own words (#396, 2026-10-04). Not to be edited
--              without him.
--   WRITTEN    written for the 2026-10-05 app at his request ("descriptions,
--              risks and how-to"), for him to review: every one is listed in
--              that round's report. "WRITTEN (2026-10-05, round 2)" marks a
--              line new or changed in the second round, listed in its report.
--   [COPY: ...] still a placeholder, outside the app's scope.
--
-- A LINE WITH '\n' IN IT IS A LIST: the app draws one paragraph or bullet per
-- piece. `{name}`, `{value}`, `{count}`, `{stage}`, `{stages}`, `{online}`
-- / `{total}`, and `{volts}`, `{cost}` and `{balance}` (each a figure and the
-- currency word, "1,250 Volts") are filled by the app; `{playername}` and
-- `{description}` by the server (BR.TerminalSolve.line), only in the lobby's
-- notices.
--
-- ═══ "SQUAD" ONLY IN A SQUAD MATCH (owner, 2026-10-05, round 2) ═══
--
-- "the mention of 'squad' in the terminal should only be mentioned if the
-- player is actively in a squad match." A line that says squad has a
-- `<key>_solo` sibling that does not, and ONE picker per side chooses between
-- them -- BR.TerminalSolve.pick for the server's toasts, notices and reasons
-- and the world's plate, model.ts's `speaker` for the app -- from the
-- server's `squadMatch` (BR.Terminal.squadMatch: in a match's bus or playing
-- phase, in a mode whose squads are bigger than one). An EMPTY `_solo` line
-- means the row it labels is not shown outside a squad match. The lines of a
-- squad-only function (`squadOnly` on its row) and of a category only those
-- fill are never shown outside one, so they have no sibling.
-- tools/test_terminal.lua fails a line that says squad with neither.
--
-- WHO READS EACH LINE is in its comment. "At the terminal" is the one player
-- using the computer; "the lobby" is everyone in that match.

BR = BR or {}
BR.Config = BR.Config or {}

BR.Config.Terminals = {
    copy = {
        -- ── in the world ──────────────────────────────────────────────────────
        --
        -- TWO TOKENS, and only in the lobby's notices: {playername} is the
        -- player who did it (drawn bold, like every name in a toast -- it
        -- travels as BR.Notice.who, never formatted into the string), and
        -- {description} is the function's `<id>_description` line.

        -- [COPY] A toast to the player picking up a Yubikey for the first time
        -- ever. The owner's verbatim text belongs to an Enter-dismissed card,
        -- which is the follow-up's, not this app's.
        first_pickup = '[COPY: first pickup -- what a Yubikey does and how to use it]',
        -- VERBATIM (owner, 2026-10-04, "No key"). Three readers: the terminal's
        -- world plate without a key, the app's login screen, and the reason a
        -- function cannot run for that cause.
        no_key = 'You need a Yubikey to access this system. Search far and wide, and you just might find one.',
        -- WRITTEN. A terminal outside the storm: the world plate's hint, a
        -- toast if the server hears a press there anyway, and the app's reason.
        offline = 'This terminal is outside the storm and offline.',
        -- WRITTEN (2026-10-06, wave A). A terminal a Lockdown has taken: the
        -- world plate's hint (nothing to hold), a toast if the player presses
        -- anyway, and the app's reason.
        locked = 'A lockdown has taken this terminal offline.',
        -- [COPY] A toast to a holder trying to pick up a second Yubikey.
        already_holding = '[COPY: pickup refused -- you already hold a Yubikey]',
        -- WRITTEN. A holder whose squad has already used its one key this
        -- match: the world plate's hint and the app's reason.
        squad_used = 'Your squad already used its terminal this match.',
        -- WRITTEN (2026-10-05, round 2). The same, outside a squad match.
        squad_used_solo = 'You already used your terminal this match.',
        -- VERBATIM (owner, 2026-10-04, "Lobby notices"). A toast to the lobby
        -- (everyone in the match, the dead and spectators included) when
        -- someone gains access to a terminal with a key.
        notice_access = '{playername} has gained access to a match terminal using their Yubikey. 1 special power has been granted to them.',
        -- VERBATIM. A toast to the lobby when that player picks a function and
        -- it runs.
        notice_action = '{playername} has redeemed their special power: {description}',
        -- VERBATIM (owner, 2026-10-04, "Bounty"). A toast to the lobby when
        -- Scan puts a bounty on the player who ran it...
        bounty_new = 'A new bounty is among us: {playername}.',
        -- VERBATIM. ...and one to that player's squad.
        bounty_protect = "Protect {playername}! They've got a bounty for the next 10 minutes.",
        -- [COPY] The Yubikey's name on the world plate over a key on the ground.
        key_label = '[COPY: Yubikey -- its name on the ground pickup]',
        -- VERBATIM (owner, 2026-10-06: 'When approaching one of these, a DUI
        -- should be shown: "Computer system" "press to open" with the
        -- interact key on it'). The title on every terminal's world plate,
        -- whatever its hint -- and its blip's name on the map.
        terminal_label = 'Computer system',
        -- VERBATIM (the same words). The plate's hint when a press opens the
        -- computer with this player's key, beside the interact key's cap.
        -- The no_key, squad_used and offline plates keep their own lines.
        terminal_use = 'press to open',

        -- ── the desktop (cuchi_computer) -- at the terminal. WRITTEN ─────────

        -- Under the boot spinner, for the 7 to 10 seconds the desktop takes
        -- to start (bootMinMs .. bootMaxMs below, a new pick every boot).
        shell_boot = 'Starting up...',
        -- VERBATIM (owner, 2026-10-05, round 2: 'change the app name to
        -- "Control Tower"'). The app's name, in its three places: under its
        -- desktop icon...
        desktop_icon = 'Control Tower',
        -- ...on the browser's one tab, beside its icon...
        window_title = 'Control Tower',

        -- ── the app's frame: the browser and the top bar. WRITTEN ────────────

        -- ...and the top bar's title -- the only place inside the app it is
        -- written (owner, round 2: "it should only remain in the top bar"; the
        -- side navigation's header, the first breadcrumb and the login
        -- screen's heading no longer say it). VERBATIM, as above.
        app_title = 'Control Tower',
        -- The address bar: the fictional site the pages live on, and each
        -- page's path segment. A function's own segment is its id. The host
        -- kept its name when the app became Control Tower (round 2): a
        -- question for the owner, not a change made for him.
        address_host = 'https://controltower.blitz',
        path_functions = 'functions',
        path_howto = 'how-to',
        path_login = 'login',
        -- Hover labels on the browser's buttons and the window's close.
        aria_back = 'Back',
        aria_forward = 'Forward',
        aria_reload = 'Reload',
        aria_address = 'Address',
        -- The close button on the confirmation box and on a run's answer.
        aria_close = 'Close',
        -- The search box in the top bar, its "use what I typed" row and the
        -- row it shows when nothing matches.
        search_placeholder = 'Search functions',
        search_use = 'Search for "{value}"',
        search_empty = 'No matching functions',
        -- The light/dark switch in the top bar.
        mode_dark = 'Dark mode',
        mode_light = 'Light mode',
        -- The menu under the player's gamertag: open the how-to, or close the
        -- computer.
        menu_howto = 'How to',
        menu_signout = 'Sign out',
        -- WRITTEN (2026-10-05, round 2). The bar under a run while the server
        -- carries it out (runMinMs .. runMaxMs below), over the page the
        -- player is on.
        running = 'Running {name}...',
        -- WRITTEN (2026-10-05, round 2). After a run that cost Volts: in the
        -- app's done line, after `<id>_done`, and in the toast that carries
        -- them both when the computer was closed before the run finished. The
        -- owner's #239 sentence for the vehicle shop ("Your new balance is:
        -- [X] Volts."), reused word for word. The top bar shows the balance
        -- itself, beside the gamertag, with no words of its own: the figure
        -- and the currency word.
        balance_new = 'Your new balance is: {volts}.',

        -- ── the side navigation and the breadcrumbs. WRITTEN ─────────────────

        nav_functions = 'Functions',
        nav_howto = 'How to',
        nav_categories = 'Categories',

        -- ── the functions page: the match panel. WRITTEN ─────────────────────
        --
        -- The details panel over the cards, refreshed by the server about once
        -- a second while the computer is open. A row whose label (or, for the
        -- mode, whose value) is an empty line is not shown.

        -- VERBATIM (owner, 2026-10-05, round 2: 'Can you make the match table
        -- say "Match stats" and be collapsed by default?'). Its header; the
        -- panel starts collapsed every time the app opens.
        match_heading = 'Match stats',
        field_match = 'Match ID',
        field_mode = 'Mode',
        field_phase = 'Phase',
        field_time = 'Match time',
        field_storm = 'Storm stage',
        field_sweep = 'Next sweep',
        field_players = 'Players left',
        field_squads = 'Squads left',
        -- WRITTEN (2026-10-05, round 2): empty -- outside a squad match the
        -- count of squads is the count of players, and the row goes.
        field_squads_solo = '',
        field_squad = 'Your squad',
        -- WRITTEN (2026-10-05, round 2): empty -- a squad of one is the
        -- player, and the row goes.
        field_squad_solo = '',
        field_key = 'Yubikey',
        field_squad_key = "Squad's terminal use",
        -- WRITTEN (2026-10-05, round 2).
        field_squad_key_solo = 'Your terminal use',
        field_terminals = 'Terminals online',
        field_bounty = 'Active bounty',
        mode_solo = 'Solo',
        mode_squad = 'Squads',
        -- WRITTEN (2026-10-05, round 2): empty -- a squad match's warmup is
        -- not a squad match yet, and the mode row goes until the bus.
        mode_squad_solo = '',
        phase_warmup = 'Warmup',
        phase_bus = 'Battle bus',
        phase_playing = 'In progress',
        phase_ended = 'Ended',
        storm_stage = '{stage} of {stages}',
        storm_pre = 'Not started',
        storm_holding = 'Holding',
        storm_shrinking = 'Closing',
        storm_finished = 'Final circle',
        mate_alive = 'Alive',
        mate_downed = 'Downed',
        mate_out = 'Out',
        key_held = 'Held',
        key_none = 'Not held',
        squad_key_unused = 'Unused',
        squad_key_used = 'Used',
        terminals_count = '{online} of {total}',
        none = 'None',
        no_match = 'Not in a match',

        -- ── the functions page: the cards. WRITTEN ───────────────────────────

        functions_heading = 'Functions',
        filter_placeholder = 'Find functions',
        filter_matches = '{count} matches',
        filter_empty = 'No functions match.',
        filter_clear = 'Clear filter',
        card_category = 'Category',
        card_risk = 'Risk',
        card_status = 'Status',
        pref_title = 'Preferences',
        pref_confirm = 'Confirm',
        pref_cancel = 'Cancel',
        pref_page_size = 'Cards per page',
        pref_page_option = '{count} functions',
        pref_visible = 'Card content',
        pref_visible_group = 'Show on each card',
        -- What a card says about a function right now.
        status_available = 'Available',
        status_used = 'Used',
        -- VERBATIM (owner, 2026-10-05, round 2: 'for "Not here" let's
        -- instead say "Not available at this terminal"').
        status_not_here = 'Not available at this terminal',
        -- VERBATIM (owner, 2026-10-05, round 2: 'the term "offline" is
        -- confusing when we use "Available" to indicate the opposite. Let's
        -- instead say "Not available"'). A function not built yet, or a
        -- terminal outside the storm.
        status_offline = 'Not available',
        -- How much a function exposes the player who runs it.
        risk_low = 'Low risk',
        risk_medium = 'Medium risk',
        risk_high = 'High risk',
        category_intel = 'Intel',
        category_storm = 'Storm',
        category_disruption = 'Disruption',
        category_supply = 'Supply',
        -- Shown only in a squad match: outside one, Reboot (squadOnly) is
        -- hidden and Ghost is listed under its soloCategory, so the category
        -- is empty and goes.
        category_squad = 'Squad',

        -- ── a function's page. WRITTEN ───────────────────────────────────────

        details_heading = 'Details',
        what_heading = 'What it does',
        options_heading = 'Options',
        risks_heading = 'Risks',
        field_category = 'Category',
        field_status = 'Status',
        field_duration = 'Duration',
        field_affects = 'Affects',
        field_notified = 'Who is told',
        field_cost = 'Cost',
        -- A function's cost, when it costs no Volts.
        cost_line = "Your Yubikey and your squad's one terminal use this match",
        -- WRITTEN (2026-10-05, round 2). The same, outside a squad match.
        cost_line_solo = 'Your Yubikey and your one terminal use this match',
        -- WRITTEN (2026-10-05, round 2). A function with a `cost` in Volts
        -- (the registry, below): {volts} is that cost.
        cost_line_volts = "{volts}, your Yubikey and your squad's one terminal use this match",
        cost_line_volts_solo = '{volts}, your Yubikey and your one terminal use this match',
        -- The first risk on every function's page: notice_action reaches the
        -- whole match whatever was run.
        risk_notice = 'Everyone in the match is told your name and what you ran.',
        -- The button, and the box that asks before it spends anything.
        run = 'Run',
        confirm_title = 'Run {name}?',
        confirm_body = "This uses your Yubikey and your squad's terminal use for this match. It can't be undone.",
        -- WRITTEN (2026-10-05, round 2). The box outside a squad match, and
        -- the box for a function that costs Volts ({volts}), each way.
        confirm_body_solo = "This uses your Yubikey and your terminal use for this match. It can't be undone.",
        confirm_body_volts = "This uses {volts}, your Yubikey and your squad's terminal use for this match. It can't be undone.",
        confirm_body_volts_solo = "This uses {volts}, your Yubikey and your terminal use for this match. It can't be undone.",
        confirm_yes = 'Run',
        confirm_no = 'Cancel',

        -- ── why a function cannot run. WRITTEN, beside no_key, offline and
        --    squad_used above ──────────────────────────────────────────────────

        -- WRITTEN (2026-10-05, round 2; was 'This function is offline.'). A
        -- function whose effect is not built yet: listed, described, never
        -- run. Beside the "Not available" badge, so it does not say offline.
        fn_offline = 'This function is not available.',
        -- WRITTEN (2026-10-05, round 2). A run whose cost the player's Volts
        -- cannot cover: refused by the server after every other reason, with
        -- nothing spent. {cost} and {balance} are the figure and the word.
        no_volts = "You don't have enough Volts. This costs {cost}, and your balance is {balance}.",
        -- A reason with no line of its own.
        unavailable = "This function can't run right now.",
        -- Options the server would not take (the app only offers valid ones).
        bad_option = "Those options aren't available.",
        -- The storm has not drawn its first circle.
        no_storm = "The storm hasn't started yet.",
        -- Supply drop: no airdrop spot fits inside the next circle.
        no_site = "There's no airdrop spot inside the next circle right now.",
        -- Max ammo: every gun the squad carries is already full.
        ammo_full = "Your squad's ammo is already full.",
        -- WRITTEN (2026-10-05, round 2). The same, outside a squad match.
        ammo_full_solo = 'Your ammo is already full.',
        -- Supply drop: another airdrop is waiting for a player or falling.
        drop_busy = 'Another airdrop is already on its way.',
        -- WRITTEN (2026-10-06, wave A). Field medic: everyone in the squad who
        -- is standing is already at full health and armor (or nobody is
        -- standing) -- refused, spending nothing.
        health_full = 'Everyone in your squad who is standing is already at full health and armor.',
        health_full_solo = "You're already at full health and armor.",
        -- WRITTEN (2026-10-06, wave A). Disarm: nobody still in the match
        -- carries a weapon -- refused, spending nothing (the Volts included).
        no_weapons = 'Nobody in the match is carrying a weapon.',
        -- WRITTEN (2026-10-06, wave A). Key finder, nothing to mark: no
        -- Yubikey anywhere (the card, before a choice is made), none on the
        -- ground, or nobody outside the squad holding one -- refused,
        -- spending nothing.
        no_keys = 'There are no other Yubikeys to find right now.',
        no_keys_ground = 'There are no Yubikeys on the ground right now.',
        no_keys_held = 'Nobody outside your squad is holding a Yubikey right now.',
        no_keys_held_solo = 'Nobody else is holding a Yubikey right now.',
        -- WRITTEN (2026-10-06, wave A). Contract: nobody outside the squad
        -- has an elimination yet -- refused, spending nothing.
        no_target = 'Nobody outside your squad has an elimination yet.',
        no_target_solo = 'Nobody else has an elimination yet.',
        -- WRITTEN (2026-10-06, wave A). Lockdown: no other terminal is online
        -- to take offline -- refused, spending nothing.
        lockdown_none = 'There are no other terminals online to take offline.',

        -- ── the how-to page. WRITTEN. The one page allowed to talk strategy,
        --    in general terms; a function's own page never says how it helps ──

        howto_title = 'How to use the terminal',
        howto_key_title = 'Getting a Yubikey',
        howto_key_body = "Airdrops have a 50/50 chance of carrying a Yubikey, and legendary crates have a small chance.\nYou can hold one Yubikey at a time. It doesn't take an inventory slot, and its icon shows on your HUD.\nIf you're eliminated, your Yubikey drops where you fell, and anyone can pick it up.\nA Yubikey you don't use stays with you into your next match.",
        howto_terminal_title = 'Using a terminal',
        -- WRITTEN (2026-10-06, round 3: "hold interact" became "press
        -- interact", as the plate's press opens the computer now).
        howto_terminal_body = "While you hold a Yubikey, terminals inside the storm show on your map as laptops.\nWalk up to one and press interact to open it.\nA terminal outside the storm is offline and won't open.\nPick a function, read its page, choose its options and press Run.",
        howto_rules_title = 'One use per squad',
        howto_rules_body = "Each squad gets one terminal use per match. A solo player is a squad of one.\nRunning a function uses your Yubikey and your squad's use. A Yubikey is gone after one use.\nIf a squadmate already ran a function this match, your Yubikey stays with you for a later match.\nA function that can't run uses nothing.",
        -- WRITTEN (2026-10-05, round 2). The same section outside a squad
        -- match.
        howto_rules_title_solo = 'One use per match',
        howto_rules_body_solo = "You get one terminal use per match.\nRunning a function uses your Yubikey and your terminal use. A Yubikey is gone after one use.\nA function that can't run uses nothing.",
        howto_notices_title = 'What everyone is told',
        howto_notices_body = "When you open a terminal with a Yubikey, everyone in the match is told your name.\nWhen you run a function, everyone is told your name and what you ran.\nSome functions tell more. Each function's page lists who is told.",
        howto_tips_title = 'Tips',
        howto_tips_body = "Read a function's risks before you run it.\nOpening a terminal announces you to the whole match. Clear the area first.\nA terminal near the storm's edge can go offline while you read. Pick one well inside the circle.\nTalk to your squad before you run anything. You only get one use between you.\nIntel shows the most while many squads are left. Supply matters most when your squad is low on gear.\nStorm functions change where the last fight happens. Think about where your squad will be.\nA bounty puts you on every map for 10 minutes. Have a plan to survive it first.",
        -- WRITTEN (2026-10-05, round 2). The tips outside a squad match.
        howto_tips_body_solo = "Read a function's risks before you run it.\nOpening a terminal announces you to the whole match. Clear the area first.\nA terminal near the storm's edge can go offline while you read. Pick one well inside the circle.\nIntel shows the most while many players are left. Supply matters most when you're low on gear.\nStorm functions change where the last fight happens. Think about where you will be.\nA bounty puts you on every map for 10 minutes. Have a plan to survive it first.",

        -- ── the functions ─────────────────────────────────────────────────────
        --
        -- Every listed id has, at the terminal: `<id>_name`, `<id>_summary`
        -- (its card), `<id>_what` (what it does -- mechanics, never benefit),
        -- `<id>_duration`, `<id>_affects`, `<id>_notified`, `<id>_done` (after
        -- the server ran it), and `<id>_risks` when it has risks beyond
        -- risk_notice, which every page lists first; one line per
        -- option `<id>_opt_<option>`, and per choice `<id>_opt_<option>_<choice>`
        -- with an optional `..._desc`. And for the lobby, `<id>_description`,
        -- the {description} in notice_action. tools/test_terminal.lua fails a
        -- listed id missing any of them. ALL WRITTEN; every `..._solo` line
        -- among them -- the same line for a player outside a squad match --
        -- is WRITTEN (2026-10-05, round 2).

        -- Scan (owner's; LIVE)
        scan_name = 'Scan',
        scan_summary = "Shows every opponent on your squad's maps for the rest of the match.",
        scan_summary_solo = "Shows every opponent on your map for the rest of the match.",
        scan_what = "Every opponent still in the match appears on the maps of everyone in your squad.\nThe marks update every 2 seconds until the match ends.\nThe player who runs it gets a bounty for 10 minutes.",
        scan_what_solo = "Every opponent still in the match appears on your map.\nThe marks update every 2 seconds until the match ends.\nThe player who runs it gets a bounty for 10 minutes.",
        scan_duration = 'Rest of the match. The bounty lasts 10 minutes.',
        scan_affects = 'Your squad',
        scan_affects_solo = 'You',
        scan_notified = 'Everyone in the match, and your squad',
        scan_notified_solo = 'Everyone in the match',
        scan_risks = "You get a bounty. Everyone in the match is told your name.\nFor 10 minutes your position shows on every player's map.\nThe bounty ends early only if you're eliminated.",
        scan_done = 'Scan is running. You have a bounty for the next 10 minutes.',
        scan_description = 'Scan. Their squad sees every opponent for the rest of the match.',
        scan_description_solo = 'Scan. They see every opponent for the rest of the match.',
        -- The opponents' and the bounty's names in the pause map's legend.
        scan_blip = 'Opponent',
        bounty_blip = 'Bounty',

        -- Storm reveal (owner's; LIVE)
        storm_reveal_name = 'Storm reveal',
        storm_reveal_summary = 'Shows your squad where the storm will end this match.',
        storm_reveal_summary_solo = 'Shows you where the storm will end this match.',
        storm_reveal_what = "The final circle is marked on the maps of everyone in your squad.\nThe mark stays until the match ends.",
        storm_reveal_what_solo = "The final circle is marked on your map.\nThe mark stays until the match ends.",
        storm_reveal_duration = 'Rest of the match',
        storm_reveal_affects = 'Your squad',
        storm_reveal_affects_solo = 'You',
        storm_reveal_notified = 'Everyone in the match',
        storm_reveal_done = "The final circle is on your squad's maps.",
        storm_reveal_done_solo = 'The final circle is on your map.',
        storm_reveal_description = 'Storm reveal. Their squad sees where the storm will end.',
        storm_reveal_description_solo = 'Storm reveal. They see where the storm will end.',
        -- The revealed final zone's name in the pause map's legend.
        storm_reveal_blip = 'Final circle',

        -- Storm control (owner's; offline)
        storm_control_name = 'Storm control',
        storm_control_summary = 'Picks where the storm ends, from three possible final circles.',
        storm_control_what = "The server works out three possible final circles.\nYou pick one, and the storm closes toward it for the rest of the match.\nCircles already on the map don't move. The change starts with the next circle the storm draws.",
        storm_control_opt_zone = 'Final circle',
        storm_control_opt_zone_near = 'Closest to this terminal',
        storm_control_opt_zone_center = "Closest to the current circle's center",
        storm_control_opt_zone_far = 'Farthest from this terminal',
        storm_control_duration = 'Rest of the match',
        storm_control_affects = 'Everyone in the match',
        storm_control_notified = 'Everyone in the match',
        storm_control_risks = 'Your squad still has to reach the circle you pick.',
        storm_control_risks_solo = 'You still have to reach the circle you pick.',
        storm_control_done = 'The storm will end where you chose.',
        storm_control_description = 'Storm control. They chose where the storm will end.',

        -- Comms blackout (owner's; offline)
        comms_blackout_name = 'Comms blackout',
        comms_blackout_summary = "Hides teammates' map markers from every other squad for a while.",
        comms_blackout_what = "Players in every other squad stop seeing their teammates on the map and the minimap.\nTheir squad panel stops showing where their teammates are.\nYour squad isn't affected. Voice chat isn't affected.",
        comms_blackout_opt_duration = 'Duration',
        comms_blackout_opt_duration_60 = '1 minute',
        comms_blackout_opt_duration_120 = '2 minutes',
        comms_blackout_opt_duration_180 = '3 minutes',
        comms_blackout_duration = '1 to 3 minutes, as chosen',
        comms_blackout_affects = 'Every other squad',
        comms_blackout_notified = 'Everyone in the match',
        comms_blackout_risks = 'Every other squad knows it started, because the notice says so.',
        comms_blackout_done = 'Comms blackout is running.',
        comms_blackout_description = "Comms blackout. Other squads can't see their teammates on the map.",

        -- Time & weather (owner's; offline)
        time_weather_name = 'Time & weather',
        time_weather_summary = "Changes the match's time of day and weather for a while.",
        -- WRITTEN (2026-10-05, round 2; was "Sets the time of day and the
        -- weather for everyone in the match.\nWhen it ends, ..."). The owner's
        -- round-2 rule (the registry row says it in full): the weather chosen
        -- here holds only inside the circle, and the storm's own weather wins
        -- outside it.
        time_weather_what = "Sets the time of day for everyone in the match, and the weather inside the circle.\nOutside the circle, the storm's own weather stays.\nWhen it ends, the match's own time and weather come back.",
        time_weather_opt_time = 'Time of day',
        time_weather_opt_time_day = 'Day',
        time_weather_opt_time_dusk = 'Dusk',
        time_weather_opt_time_night = 'Night',
        time_weather_opt_weather = 'Weather',
        time_weather_opt_weather_clear = 'Clear',
        time_weather_opt_weather_rain = 'Rain',
        time_weather_opt_weather_fog = 'Fog',
        time_weather_opt_duration = 'Duration',
        time_weather_opt_duration_180 = '3 minutes',
        time_weather_opt_duration_300 = '5 minutes',
        time_weather_duration = '3 or 5 minutes, as chosen',
        time_weather_affects = 'Everyone in the match',
        time_weather_notified = 'Everyone in the match',
        time_weather_risks = 'It changes what your squad can see too.',
        time_weather_risks_solo = 'It changes what you can see too.',
        time_weather_done = 'The time and weather have changed.',
        time_weather_description = 'Time & weather. The sky has changed.',

        -- Power outage (owner's; offline)
        power_outage_name = 'Power outage',
        power_outage_summary = 'Turns the lights off in an area for a while.',
        power_outage_what = "Street lights, building lights and signs go dark in the area you choose.\nVehicle headlights still work.\nThe lights come back when it ends.",
        power_outage_opt_area = 'Area',
        power_outage_opt_area_here = 'Around this terminal',
        power_outage_opt_area_here_desc = 'Everything within 1 km of this terminal.',
        power_outage_opt_area_city = 'Los Santos',
        power_outage_opt_area_city_desc = 'The whole city.',
        power_outage_opt_area_county = 'Blaine County',
        power_outage_opt_area_county_desc = 'Everything outside the city.',
        power_outage_opt_duration = 'Duration',
        power_outage_opt_duration_120 = '2 minutes',
        power_outage_opt_duration_240 = '4 minutes',
        power_outage_duration = '2 or 4 minutes, as chosen',
        power_outage_affects = 'Everyone in the area',
        power_outage_notified = 'Everyone in the match',
        power_outage_risks = "Your squad is in the dark too while it's in the area.",
        power_outage_risks_solo = "You're in the dark too while you're in the area.",
        power_outage_done = 'The power is out.',
        power_outage_description = 'Power outage. The lights are out.',

        -- Disarm (owner's; LIVE since wave A, 2026-10-06)
        disarm_name = 'Disarm',
        disarm_summary = "Takes away every player's most powerful weapon.",
        disarm_what = "Every player still in the match loses the most powerful weapon they carry, your squad included.\nMost powerful means the highest rarity, then the most damage.\nThe weapons are gone. They aren't dropped.",
        disarm_what_solo = "Every player still in the match loses the most powerful weapon they carry, you included.\nMost powerful means the highest rarity, then the most damage.\nThe weapons are gone. They aren't dropped.",
        disarm_duration = 'Instant',
        disarm_affects = 'Every player still in the match, your squad included',
        disarm_affects_solo = 'Every player still in the match, you included',
        disarm_notified = 'Everyone in the match',
        disarm_risks = 'Your squad loses its most powerful weapons too.',
        disarm_risks_solo = 'You lose your most powerful weapon too.',
        disarm_done = "Every player's most powerful weapon is gone.",
        disarm_description = "Disarm. Every player's most powerful weapon is gone.",

        -- Supply drop (owner's; LIVE)
        supply_drop_name = 'Supply drop',
        supply_drop_summary = 'Calls in an extra airdrop.',
        supply_drop_what = "An extra airdrop is placed at the spot you choose and marked on every player's map.\nLike any airdrop, the aircraft comes once a player is within 200 meters, and the drop is called off if nobody comes in time.\nIt lands only inside the next circle, like any airdrop.",
        supply_drop_opt_site = 'Drop spot',
        supply_drop_opt_site_terminal = 'Near this terminal',
        supply_drop_opt_site_terminal_desc = 'The airdrop spot closest to this terminal.',
        supply_drop_opt_site_circle = 'Near the next circle',
        supply_drop_opt_site_circle_desc = "The airdrop spot closest to the next circle's center.",
        supply_drop_duration = "Until it's opened or times out",
        supply_drop_affects = 'Everyone in the match',
        supply_drop_notified = 'Everyone in the match, with the airdrop notice',
        supply_drop_risks = "Every player sees the drop on their map.\nAnyone can open it.",
        supply_drop_done = 'Your supply drop is on the map.',
        supply_drop_description = 'Supply drop. An extra airdrop is on the way.',

        -- Max ammo (owner's; LIVE)
        max_ammo_name = 'Max ammo',
        max_ammo_summary = 'Fills the reserve ammo of everyone in your squad.',
        max_ammo_summary_solo = 'Fills your reserve ammo.',
        max_ammo_what = "Every player in your squad who is still in the fight gets a full reserve for each gun they carry.\nEmpty magazines are loaded too.\nThrowables aren't refilled.",
        max_ammo_what_solo = "You get a full reserve for each gun you carry.\nEmpty magazines are loaded too.\nThrowables aren't refilled.",
        max_ammo_duration = 'Instant',
        max_ammo_affects = 'Your squad',
        max_ammo_affects_solo = 'You',
        max_ammo_notified = 'Everyone in the match',
        max_ammo_risks = 'Only guns your squad carries when it runs are filled.',
        max_ammo_risks_solo = 'Only guns you carry when it runs are filled.',
        max_ammo_done = "Your squad's ammo is full.",
        max_ammo_done_solo = 'Your ammo is full.',
        max_ammo_description = "Max ammo. Their squad's ammo is full.",
        max_ammo_description_solo = 'Max ammo. Their ammo is full.',

        -- Reboot (suggested; offline)
        reboot_name = 'Reboot',
        reboot_summary = 'Brings eliminated squadmates back at this terminal.',
        reboot_what = "Every eliminated player in your squad comes back at this terminal with full health.\nThey come back with an empty inventory.\nPlayers who left the match don't come back.",
        reboot_duration = 'Instant',
        reboot_affects = 'Your squad',
        reboot_notified = 'Everyone in the match',
        reboot_risks = "Rebooted players start with nothing.\nThey come back here, where the notice was just sent from.",
        reboot_done = 'Your squad is back.',
        reboot_description = 'Reboot. Their squad is back.',

        -- Ghost (suggested; LIVE since wave A, 2026-10-06)
        ghost_name = 'Ghost',
        ghost_summary = 'Hides your squad from Scan, Pulse and bounty markers for a while.',
        ghost_summary_solo = 'Hides you from Scan, Pulse and bounty markers for a while.',
        ghost_what = "Your squad doesn't show up on other squads' Scan or Pulse markers.\nIf one of you has a bounty, the bounty marker is hidden too.\nIt doesn't hide you from anyone who can see you.",
        ghost_what_solo = "You don't show up on other players' Scan or Pulse markers.\nIf you have a bounty, the bounty marker is hidden too.\nIt doesn't hide you from anyone who can see you.",
        ghost_opt_duration = 'Duration',
        ghost_opt_duration_120 = '2 minutes',
        ghost_opt_duration_240 = '4 minutes',
        ghost_duration = '2 or 4 minutes, as chosen',
        ghost_affects = 'Your squad',
        ghost_affects_solo = 'You',
        ghost_notified = 'Everyone in the match',
        ghost_risks = 'Every squad knows yours went dark, because the notice says so.',
        ghost_risks_solo = 'Every player knows you went dark, because the notice says so.',
        ghost_done = 'Your squad is hidden.',
        ghost_done_solo = 'You are hidden.',
        ghost_description = 'Ghost. Their squad is hidden from scans.',
        ghost_description_solo = 'Ghost. They are hidden from scans.',

        -- EMP (suggested; offline)
        emp_name = 'EMP',
        emp_summary = 'Stalls every vehicle in an area for a short time.',
        emp_what = "Every vehicle within the radius you choose stalls and won't start.\nVehicles that drive in after it goes off aren't affected.\nThey start again when it ends.",
        emp_opt_radius = 'Radius',
        emp_opt_radius_300 = '300 meters around this terminal',
        emp_opt_radius_600 = '600 meters around this terminal',
        emp_opt_duration = 'Duration',
        emp_opt_duration_30 = '30 seconds',
        emp_opt_duration_60 = '1 minute',
        emp_duration = '30 seconds or 1 minute, as chosen',
        emp_affects = 'Every vehicle in the radius, yours included',
        emp_notified = 'Everyone in the match',
        emp_risks = "Your squad's vehicles in the radius stall too.",
        emp_risks_solo = 'Your own vehicles in the radius stall too.',
        emp_done = 'The EMP went off.',
        emp_description = 'EMP. Vehicles near their terminal have stalled.',

        -- Key finder (suggested; LIVE since wave A, 2026-10-06)
        key_finder_name = 'Key finder',
        key_finder_summary = 'Shows your squad where other Yubikeys are.',
        key_finder_summary_solo = 'Shows you where other Yubikeys are.',
        key_finder_what = "Marks Yubikeys on your squad's maps.\nThe marks show where the keys were when it ran. They don't follow anyone, and they fade after 2 minutes.",
        key_finder_what_solo = "Marks Yubikeys on your map.\nThe marks show where the keys were when it ran. They don't follow anyone, and they fade after 2 minutes.",
        key_finder_opt_target = 'Find',
        key_finder_opt_target_ground = 'Keys on the ground',
        key_finder_opt_target_holders = 'Players holding a key',
        key_finder_duration = 'The marks last 2 minutes',
        key_finder_affects = 'Your squad',
        key_finder_affects_solo = 'You',
        -- WRITTEN (2026-10-06, wave A; was 'Everyone in the match'): the
        -- holders it marks are told too.
        key_finder_notified = 'Everyone in the match, and every key holder it marks',
        -- WRITTEN (2026-10-06, wave A; was 'Key holders are warned that keys
        -- were located.'): only the holders it marks are warned -- Keys on
        -- the ground marks nobody to warn.
        key_finder_risks = "Players holding a key are warned when they're marked.",
        key_finder_done = "The Yubikeys are on your squad's maps.",
        key_finder_done_solo = 'The Yubikeys are on your map.',
        key_finder_description = 'Key finder. Their squad sees where the Yubikeys are.',
        key_finder_description_solo = 'Key finder. They see where the Yubikeys are.',
        -- WRITTEN (2026-10-06, wave A). A toast to each player holding a key
        -- whom Key finder (Players holding a key) marked, after the lobby's
        -- notice.
        key_finder_warned = 'Key finder located your Yubikey. Another squad can see where you were standing for 2 minutes.',
        key_finder_warned_solo = 'Key finder located your Yubikey. Another player can see where you were standing for 2 minutes.',
        -- WRITTEN (2026-10-06, wave A). The marks' name in the pause map's
        -- legend.
        key_finder_blip = 'Yubikey',

        -- Storm delay (new; offline)
        storm_delay_name = 'Storm delay',
        storm_delay_summary = 'Holds the storm in place longer before its next sweep.',
        storm_delay_what = "The storm's current hold gets longer by the time you choose.\nIf the storm is already closing, the delay is added to its next hold.\nThe next circle doesn't change.",
        storm_delay_opt_delay = 'Delay',
        storm_delay_opt_delay_60 = '1 minute',
        storm_delay_opt_delay_120 = '2 minutes',
        storm_delay_duration = '1 or 2 minutes, as chosen',
        storm_delay_affects = 'Everyone in the match',
        storm_delay_notified = 'Everyone in the match',
        storm_delay_risks = 'It delays the storm for every squad, not just yours.',
        storm_delay_risks_solo = 'It delays the storm for every player, not just you.',
        storm_delay_done = 'The storm is delayed.',
        storm_delay_description = 'Storm delay. The storm holds longer before its next sweep.',

        -- Pulse (new; LIVE since wave A, 2026-10-06)
        pulse_name = 'Pulse',
        pulse_summary = 'Shows every player near this terminal for a short time.',
        -- WRITTEN (2026-10-06, wave A; was "Every player within the radius
        -- ..."): the runner's own squad is not marked, and not told it was
        -- detected.
        pulse_what = "Every player outside your squad within the radius you choose shows on your squad's maps.\nThe marks follow them for 30 seconds.",
        pulse_what_solo = "Every other player within the radius you choose shows on your map.\nThe marks follow them for 30 seconds.",
        pulse_opt_radius = 'Radius',
        pulse_opt_radius_250 = '250 meters',
        pulse_opt_radius_500 = '500 meters',
        pulse_duration = '30 seconds',
        -- WRITTEN (2026-10-06, wave A; was 'Every player in the radius').
        pulse_affects = 'Every player outside your squad in the radius',
        pulse_affects_solo = 'Every other player in the radius',
        pulse_notified = 'Everyone in the match, and every player it finds',
        pulse_risks = "Every player the pulse finds is told they've been detected.",
        pulse_done = "The pulse is on your squad's maps.",
        pulse_done_solo = 'The pulse is on your map.',
        pulse_description = 'Pulse. Players near their terminal are on their map.',
        -- WRITTEN (2026-10-06, wave A). A toast to each player a Pulse found,
        -- after the lobby's notice.
        pulse_detected = "A pulse detected you. Another squad can see where you are for 30 seconds.",
        pulse_detected_solo = "A pulse detected you. Another player can see where you are for 30 seconds.",
        -- WRITTEN (2026-10-06, wave A). The marks' name in the pause map's
        -- legend.
        pulse_blip = 'Detected',

        -- Lockdown (new; LIVE since wave A, 2026-10-06)
        lockdown_name = 'Lockdown',
        lockdown_summary = 'Takes every other terminal offline for a while.',
        -- WRITTEN (2026-10-06, wave A; was "...\nThis terminal stays
        -- online."): the storm still takes this terminal like any other --
        -- Lockdown takes the others, it does not hold the wall back.
        lockdown_what = "Every other terminal goes offline for the time you choose.\nNobody can open them.\nThis terminal stays online, unless the storm reaches it.",
        lockdown_opt_duration = 'Duration',
        lockdown_opt_duration_180 = '3 minutes',
        lockdown_opt_duration_300 = '5 minutes',
        lockdown_duration = '3 or 5 minutes, as chosen',
        lockdown_affects = 'Every other terminal',
        lockdown_notified = 'Everyone in the match',
        lockdown_risks = "This terminal is the only one left online, and every key holder's map shows it.",
        lockdown_done = 'Every other terminal is offline.',
        lockdown_description = 'Lockdown. Every other terminal is offline.',

        -- Contract (new; LIVE since wave A, 2026-10-06)
        contract_name = 'Contract',
        contract_summary = 'Puts a bounty on the player with the most eliminations.',
        contract_what = "The player outside your squad with the most eliminations gets a bounty for 5 minutes.\nTheir position shows on every player's map while it lasts.\nA tie goes to the player who got there first.",
        contract_what_solo = "The player with the most eliminations, other than you, gets a bounty for 5 minutes.\nTheir position shows on every player's map while it lasts.\nA tie goes to the player who got there first.",
        contract_duration = '5 minutes',
        contract_affects = 'One player outside your squad',
        contract_affects_solo = 'One player other than you',
        contract_notified = 'Everyone in the match, the target included',
        contract_risks = "The target is told a contract is on them.",
        contract_done = 'The contract is out.',
        contract_description = 'Contract. The top player has a bounty.',
        -- WRITTEN (2026-10-06, wave A). A toast to the target's squadmates
        -- (never the target): the owner's bounty_protect says "the next 10
        -- minutes", Scan's ten, so a Contract's five has its own line.
        contract_protect = "Protect {playername}! There's a contract on them for the next 5 minutes.",
        -- WRITTEN (2026-10-06, wave A). A toast to the target.
        contract_target = "There's a contract on you. Every player can see where you are for the next 5 minutes.",

        -- Field medic (new; LIVE since wave A, 2026-10-06)
        field_medic_name = 'Field medic',
        field_medic_summary = 'Restores full health and armor to everyone in your squad.',
        field_medic_summary_solo = 'Restores your full health and armor.',
        field_medic_what = "Every player in your squad who is still standing gets full health and full armor.\nDowned players aren't revived.",
        field_medic_what_solo = 'You get full health and full armor.',
        field_medic_duration = 'Instant',
        field_medic_affects = 'Your squad',
        field_medic_affects_solo = 'You',
        field_medic_notified = 'Everyone in the match',
        field_medic_risks = "Only players standing when it runs are healed.",
        field_medic_done = 'Your squad is patched up.',
        field_medic_done_solo = "You're patched up.",
        field_medic_description = 'Field medic. Their squad is back to full health.',
        field_medic_description_solo = 'Field medic. They are back to full health.',
    },

    -- ═══ THE ART: EVERY PLACEHOLDER IN ONE SPOT ═══
    --
    -- The owner's Yubikey prop (`blitz_seckey`, in the Season 2 props resource)
    -- and HUD icon replace the first two; until then they are a stock GTA prop
    -- and a plain glyph. The blips are the owner's own numbers (#396,
    -- 2026-10-04: "type 521, color 51 (draws as a laptop)", and the bounty's
    -- "blip 58, color 3" for everyone and "blip 58, color 69" for teammates).
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
        -- The mark beside a squadmate with a bounty in the squad panel. A
        -- string drawn as text; a placeholder like hudGlyph.
        bountyGlyph = '◎',
        -- The laptop the owner's ymap stands at every site (2026-10-06). No
        -- script makes one; this names the model, not a prop to spawn. A
        -- running server cannot swap a streamed asset, so after a live
        -- `brseason 1` on a box started at Season 2 the ymap still streams,
        -- and a client where terminals are off (Season 1) hides this model
        -- within hideRadiusM of every site (client/yubikey.lua), and only map
        -- objects, never a script's.
        terminalProp = 'prop_laptop_01a',
        -- 2 meters, not less: in the ymap he published (br_stream_s2
        -- 5ec1f721), the paleto_pd and calafia_way laptops stand 1.7 m from
        -- their rows (1.6 m higher), and the other thirteen at them.
        hideRadiusM = 2.0,
        -- A terminal's blip, drawn only while this player holds a key and only
        -- for a terminal inside the storm.
        blipSprite = 521,
        blipColour = 51,
        blipScale = 0.9,
        -- Storm reveal: where the storm ends, on the squad's pause map and
        -- minimap from activation to the end of the match. A radius blip around
        -- the final point plus a sprite at it.
        reveal = { sprite = 161, colour = 1, scale = 1.0, radiusM = 60.0, alpha = 120 },
        -- Scan: each opponent on the scanning squad's maps. Sprite 1 is the
        -- plain dot; colour 1 is red. A placeholder the owner has not picked.
        scan = { sprite = 1, colour = 1, scale = 0.75 },
        -- The bounty, the owner's numbers: blip 58 in colour 3 on everyone's
        -- map, and colour 69 on the bounty's own squad's.
        bounty = { sprite = 58, colour = 3, mateColour = 69, scale = 1.0 },
        -- ── wave A (2026-10-06): PLACEHOLDERS the owner has not picked ──
        -- Key finder: where each Yubikey was, on the squad's maps for 2
        -- minutes. Sprite 1 is the plain dot (Scan's); color 5 is yellow.
        keyFinder = { sprite = 1, colour = 5, scale = 0.9 },
        -- Pulse: each player it found, followed for 30 seconds. The plain dot
        -- again; color 17 is orange.
        pulse = { sprite = 1, colour = 17, scale = 0.8 },
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

    -- ═══ THE TERMINALS (owner, 2026-10-06) ═══
    --
    -- "we don't need a script to place the props - I've just done so with a
    -- ymap". THE LAPTOPS ARE THE OWNER'S YMAP'S: prop_laptop_01a in
    -- LaptopTerminals.ymap in the Season 2 drop on S3, streamed with
    -- br_stream_s2 (assets.lock), so nothing in this repository makes one.
    -- These rows are WHERE THOSE PROPS STAND, exactly as he gave them. Each
    -- terminal's plate, blip, reach and session check is read from its row
    -- (client/yubikey.lua, server/terminal.lua) and from nothing in the
    -- world, so a row moved without its laptop is a plate beside empty air,
    -- and the other way round.
    -- br_stream_s2 is installed from Season 2 on, so a box started at Season
    -- 1 has no laptops; a running server cannot swap a streamed asset, so
    -- after a live `brseason 1` they still stream, and a client where
    -- terminals are off hides the laptop at every row (art.terminalProp,
    -- art.hideRadiusM).
    --
    -- `id` is lower case letters, digits and underscores, at most 32
    -- characters, and unique; x/y/z is where the prop stands and h its heading
    -- (0.0: the ymap sets each laptop's heading, and nothing here reads it).
    -- In his order, under his label for each. tools/check_boundary.lua holds every row
    -- inside the surveyed play area, as it holds the POIs and the ambulance
    -- spawns.
    --
    -- `brterminal place` stays only as a DEV AID for a future site: for this
    -- server session it puts a plate and a blip where you look, with no
    -- laptop, and prints the row to paste here -- the laptop goes in the ymap.
    sites = {
        -- mount gordo
        { id = 'mount_gordo',      x = 2825.834,    y = 5969.14648,  z = 351.6426,   h = 0.0 },
        -- top of chilliad
        { id = 'chiliad_top',      x = 472.667969,  y = 5536.955,    z = 785.8789,   h = 0.0 },
        -- fort zancudo
        { id = 'fort_zancudo',     x = -2455.12769, y = 3703.64917,  z = 15.4468756, h = 0.0 },
        -- paleto PD
        { id = 'paleto_pd',        x = -429.23584,  y = 5963.753,    z = 30.50765,   h = 0.0 },
        -- calafia way
        { id = 'calafia_way',      x = 361.000427,  y = 4434.68652,  z = 61.91766,   h = 0.0 },
        -- vineyard
        { id = 'vineyard',         x = -1847.0896,  y = 1929.22607,  z = 150.897141, h = 0.0 },
        -- rebel radio
        { id = 'rebel_radio',      x = 764.2342,    y = 2569.98633,  z = 75.97378,   h = 0.0 },
        -- panorama drive
        { id = 'panorama_drive',   x = 1901.3136,   y = 3201.079,    z = 46.3064651, h = 0.0 },
        -- towers on the hill by vinewood sign
        { id = 'vinewood_towers',  x = 793.333,     y = 1286.544,    z = 360.9136,   h = 0.0 },
        -- vinewood bowl
        { id = 'vinewood_bowl',    x = 998.1884,    y = 408.309143,  z = 93.7109,    h = 0.0 },
        -- hillcrest ridge access road
        { id = 'hillcrest_road',   x = -781.49176,  y = 593.5306,    z = 128.329178, h = 0.0 },
        -- parking lot south of the college
        { id = 'college_lot',      x = -1725.14148, y = 76.23494,    z = 67.39259,   h = 0.0 },
        -- chumash? PD -- his words. The coordinates are La Mesa's police
        -- station, east of the river, so the id says la_mesa.
        { id = 'la_mesa_pd',       x = 852.3667,    y = -1368.79871, z = 26.7313938, h = 0.0 },
        -- factory by the heliport
        { id = 'heliport_factory', x = -630.0207,   y = -1664.05212, z = 26.5907326, h = 0.0 },
        -- vespucci canals
        { id = 'vespucci_canals',  x = -1111.44263, y = -966.7761,   z = 2.909578,   h = 0.0 },
    },

    -- How close a player must stand to a terminal to see its plate and to use
    -- it, in metres. The server allows `useSlackM` more, for a position sample
    -- up to a quarter second old (the loot claim's REACH_SLACK, for the same
    -- reason).
    useDistanceM = 2.5,
    useSlackM = 2.0,
    -- How often a client re-asks which terminals are inside the storm and
    -- redraws their blips. The wall moves metres per second; a second is
    -- plenty, and it is one zone build per pass however many terminals.
    clientPassMs = 1000,
    -- How often the server checks every open computer is still at a live
    -- terminal with a living player beside it, and closes it if not.
    sessionCheckMs = 500,
    -- How often the server pushes the open computer its state and the match
    -- panel (TERMINAL_INFO), to that player alone and only while it is open.
    -- The owner asked for "realtime"; the panel's clocks count in seconds.
    infoPushMs = 1000,

    -- ═══ HOW LONG THINGS TAKE (owner, 2026-10-05, round 2) ═══
    --
    -- "the starting up animation should take longer - random between 7 and 10
    -- seconds": the desktop's boot, under shell_boot, a new uniform pick in
    -- this range every time the computer starts (cuchi_computer's br.js picks
    -- it; br_core's client hands the range over with each opening, like the
    -- copy). A second open while the desktop is up is a refresh, not a boot.
    bootMinMs = 7000,
    bootMaxMs = 10000,
    -- "a loading indicator for 3-5 seconds (random) to show when a function is
    -- being used, before showing them it was successful": the SERVER picks a
    -- run's length in this range when it accepts the run, tells the app, and
    -- carries the effect out -- and tells the lobby -- only when it is up.
    runMinMs = 3000,
    runMaxMs = 5000,
    -- AND 2026-10-06, ROUND 3: "please make an artificial page load time when
    -- navigating in the web browser between pages, except if they use the
    -- forward/back buttons. The time should be random between 1 and 3
    -- seconds, and the tab icon should change to a loading symbol". Every
    -- navigation in the app's browser but back and forward takes a new
    -- uniform pick in this range (ui-src/terminal's model.ts says which are
    -- navigations); br_core's client hands the range to the app in the
    -- catalog with each opening, like the copy.
    pageMinMs = 1000,
    pageMaxMs = 3000,

    -- ═══ THE FUNCTION REGISTRY ═══
    --
    -- What a terminal lists, in this order -- the order of the app's cards.
    -- ONE REGISTRY, READ BY BOTH SIDES: the server rules every run against it
    -- (br_core/server/terminal.lua), and br_core's client hands it to the
    -- computer with each opening, so the app draws its cards, filters and
    -- pages from the same rows. Every word a card or a page says is copy,
    -- keyed by the id (see `<id>_...` above).
    --
    --   id           lower case, letters, digits and underscores, at most 32
    --                characters (the page and the server both check that shape)
    --   category     'intel' | 'storm' | 'disruption' | 'supply' | 'squad'
    --   risk         'low' | 'medium' | 'high': how much it exposes the player
    --                who runs it, drawn as the card's badge
    --   implemented  true when the effect is built. False lists the function,
    --                card and page and all, as `fn_offline`, and the server
    --                refuses its run before anything is spent.
    --   options      what the player chooses before Run, each
    --                { id, choices = { ... }, default }. A choice is a string;
    --                the server takes only a listed one, for a listed option,
    --                and fills a missing one with its default.
    --   cost         Volts the run costs, 0 to 200 (owner, 2026-10-05, round 2:
    --                "For the most powerful items there should be a cost by
    --                Volts, with the max being no more than 200"). Absent is
    --                free. The saved balance, spent through BR.Market.charge
    --                as the revive key is; tools/test_terminal.lua fails a row
    --                outside 0..200. The figures are the coordinator's proposal
    --                for the owner to confirm.
    --   squadOnly    true for a function that means nothing outside a squad
    --                match: not listed there, and its run refused.
    --   soloCategory the category it is listed under outside a squad match,
    --                for a `squad`-category function that still means
    --                something to a player on their own.
    --
    -- The server half of a built function is BR.Terminal.FUNCTIONS[id] in
    -- br_core/server/terminal.lua: an optional `refuse` and a `run`.
    --
    -- WHERE EACH CAME FROM: the owner's list (2026-10-04) is the first nine;
    -- Reboot, Ghost, EMP and Key finder were suggested on #396 and approved
    -- for consideration; Storm delay, Pulse, Lockdown, Contract and Field
    -- medic are this round's proposals, for the owner to keep or cut.
    functions = {
        { id = 'scan',           category = 'intel',      risk = 'high',   implemented = true, cost = 200 },
        { id = 'storm_reveal',   category = 'intel',      risk = 'low',    implemented = true },
        { id = 'storm_control',  category = 'storm',      risk = 'medium', implemented = false, cost = 150,
          options = { { id = 'zone', choices = { 'near', 'center', 'far' }, default = 'near' } } },
        -- SQUAD-ONLY (round 2): it hides teammates' markers from every other
        -- squad, and outside a squad match nobody has a teammate to hide.
        { id = 'comms_blackout', category = 'disruption', risk = 'medium', implemented = false,
          squadOnly = true,
          options = { { id = 'duration', choices = { '60', '120', '180' }, default = '60' } } },
        -- THE OWNER'S RULE FOR WHOEVER BUILDS IT (2026-10-05, round 2):
        -- "thunderstorm cannot be a pickable weather. Make sure the storm will
        -- still storm when outside the circle too - whatever weather they set
        -- is only set while inside the storm." So there is no 'thunder'
        -- choice, and the chosen weather applies ONLY to players inside the
        -- circle: outside it the storm's own weather (br_core/client/storm.lua,
        -- BR.World.want('storm', ...)) always wins, whatever was picked here.
        { id = 'time_weather',   category = 'disruption', risk = 'low',    implemented = false,
          options = {
              { id = 'time', choices = { 'day', 'dusk', 'night' }, default = 'night' },
              { id = 'weather', choices = { 'clear', 'rain', 'fog' }, default = 'clear' },
              { id = 'duration', choices = { '180', '300' }, default = '180' },
          } },
        { id = 'power_outage',   category = 'disruption', risk = 'low',    implemented = false,
          options = {
              { id = 'area', choices = { 'here', 'city', 'county' }, default = 'here' },
              { id = 'duration', choices = { '120', '240' }, default = '120' },
          } },
        { id = 'disarm',         category = 'disruption', risk = 'high',   implemented = true, cost = 200 },
        { id = 'supply_drop',    category = 'supply',     risk = 'medium', implemented = true,
          options = { { id = 'site', choices = { 'terminal', 'circle' }, default = 'terminal' } } },
        { id = 'max_ammo',       category = 'supply',     risk = 'low',    implemented = true },
        -- SQUAD-ONLY (round 2): it brings back squadmates.
        { id = 'reboot',         category = 'squad',      risk = 'medium', implemented = false, cost = 150,
          squadOnly = true },
        -- DISRUPTION ON ITS OWN (round 2): alone, it still hides the player
        -- from other players' Scan, Pulse and bounty markers -- what Comms
        -- blackout, filed under disruption, does to every other squad's
        -- teammate markers.
        { id = 'ghost',          category = 'squad',      risk = 'low',    implemented = true,
          soloCategory = 'disruption',
          options = { { id = 'duration', choices = { '120', '240' }, default = '120' } } },  -- seconds
        { id = 'emp',            category = 'disruption', risk = 'medium', implemented = false,
          options = {
              { id = 'radius', choices = { '300', '600' }, default = '300' },
              { id = 'duration', choices = { '30', '60' }, default = '30' },
          } },
        { id = 'key_finder',     category = 'intel',      risk = 'low',    implemented = true,
          options = { { id = 'target', choices = { 'ground', 'holders' }, default = 'ground' } } },
        { id = 'storm_delay',    category = 'storm',      risk = 'low',    implemented = false,
          options = { { id = 'delay', choices = { '60', '120' }, default = '60' } } },
        { id = 'pulse',          category = 'intel',      risk = 'medium', implemented = true,
          options = { { id = 'radius', choices = { '250', '500' }, default = '250' } } },  -- meters
        { id = 'lockdown',       category = 'disruption', risk = 'medium', implemented = true,
          options = { { id = 'duration', choices = { '180', '300' }, default = '180' } } },  -- seconds
        { id = 'contract',       category = 'disruption', risk = 'medium', implemented = true },
        { id = 'field_medic',    category = 'supply',     risk = 'low',    implemented = true },
    },

    -- The categories, in the order the side navigation lists them.
    categories = { 'intel', 'storm', 'disruption', 'supply', 'squad' },

    -- ═══ THE BUILT EFFECTS' NUMBERS ═══
    fx = {
        -- Scan: how often the scanning squad's opponent marks are refreshed.
        -- Positions are the roster's own 4 Hz samples; two seconds keeps a
        -- whole match's worth of marks to one small event per scanning
        -- squad member every two seconds.
        scanPingMs = 2000,
        -- The bounty (owner, 2026-10-04): "Duration: 10 minutes".
        bountyMs = 10 * 60 * 1000,
        -- How often everyone outside the bounty's squad is sent where the
        -- bounty is. Their squad sees them on the 4 Hz squad beacon already.
        bountyPingMs = 1000,

        -- ── wave A (2026-10-06). An option's choices are the registry row's
        --    own numbers (Ghost's and Lockdown's seconds, Pulse's meters),
        --    read as numbers where they are used; everything else is here. ──

        -- Disarm: how long the server remembers a weapon it took, so a hit
        -- from it -- or the client's strip report of it -- accuses nobody
        -- (BR.Inv.revoke). It has to outlast the round trip before the
        -- inventory update lands AND the longest flight of a round fired just
        -- before it, because that round lands after the weapon is gone. From
        -- the stock weapons.meta: an RPG rocket lives 5 s at most (AMMO_RPG
        -- LifeTime); a grenade launcher's round leaves at 25 m/s and goes off
        -- 1 s after it first lands (AMMO_GRENADELAUNCHER LaunchSpeed,
        -- LifeTimeAfterImpact), so one lobbed straight up is about 6.1 s; the
        -- railgun is INSTANT_HIT. 10 s covers those and a slow round trip,
        -- with room for a lob off a roof. Seconds, never a match.
        disarmGraceMs = 10000,
        -- How often the server checks whether a timed effect has run out (Key
        -- finder's marks; Ghost; Lockdown) and ends it: one pass a second.
        endCheckMs = 1000,
        -- Key finder: "they fade after 2 minutes".
        keyFinderMs = 2 * 60 * 1000,
        -- Pulse: "The marks follow them for 30 seconds", moved this often.
        pulseMs = 30 * 1000,
        pulsePingMs = 1000,
        -- Contract: the bounty it puts out lasts "5 minutes" (Scan's is
        -- bountyMs, the owner's ten).
        contractMs = 5 * 60 * 1000,
    },

    -- The server drops a second run request from one player sooner than this
    -- after the last. A run is one click and the button disables itself while
    -- it waits, so anything faster is not a person.
    runMinIntervalMs = 500,
}
