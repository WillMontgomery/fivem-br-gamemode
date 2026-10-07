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
--   [COPY: ...] still a placeholder. None is left since round 5
--              (2026-10-06): first_pickup is the owner's, key_label and
--              already_holding WRITTEN.
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

        -- VERBATIM (the owner's, for "the tutorial-style card which tells them
        -- how to use it and requires manual dismissal using the return key";
        -- built round 5, 2026-10-06). THE FIRST-PICKUP CARD: the player who
        -- gets a Yubikey for the first time ever (a pickup, or `bryubikey
        -- give`) reads it on br_ui's tutorial card until they press Enter. Not
        -- a toast.
        --
        -- ROUND 6 (owner, 2026-10-07): 'make "You found a Yubikey!" H1 please,
        -- and "Please read this entire message." H3', and 'Where it has the
        -- Enter gylph, please append "to dismiss" next to that.' (spelling-ok:
        -- his words) So his text is four lines now, word for word as he wrote
        -- them: the card's H1 (_title), its H3 (_subtitle, which was the
        -- **bold** sentence), the rest of it as the body (first_pickup), and the
        -- words after the Enter cap (_dismiss).
        first_pickup_title = 'You found a Yubikey!',
        first_pickup_subtitle = 'Please read this entire message.',
        first_pickup = "This is a very powerful item and can do a variety of things - that choice is yours. The Yubikey stays with you between matches, and you can only have one at a time. After one use - it's gone. To find out what it can do, find a computer marked on your map.",
        first_pickup_dismiss = 'to dismiss',
        -- VERBATIM (owner, 2026-10-04, "No key"). Two readers: the app's login
        -- screen, and the reason a function cannot run for that cause. Not
        -- the world plate since round 6: the plate is one plate whatever the
        -- player's status (client/yubikey.lua's plateFor).
        no_key = 'You need a Yubikey to access this system. Search far and wide, and you just might find one.',
        -- WRITTEN. A terminal outside the storm: a toast if the server hears
        -- a press there anyway (a client a step behind the storm), and the
        -- app's reason (the dev tool's `brterminal offline`, or the moment
        -- before the storm's close). NOT the world plate since round 4: a
        -- terminal outside the storm has no plate at all (owner, 2026-10-06:
        -- "no blip and no DUI - hence it's unusable").
        offline = 'This terminal is outside the storm and offline.',
        -- WRITTEN (round 5, 2026-10-06; was a placeholder). A toast to a holder
        -- trying to pick up a second Yubikey: the key stays on the ground.
        already_holding = 'You already have a Yubikey.',
        -- WRITTEN. A holder whose squad has already used its one key this
        -- match: the app's reason, and the toast for a run refused for it.
        -- Not the world plate since round 7 (owner, 2026-10-07: 'The DUI
        -- reading "you already used your terminal this match" should be the
        -- same DUI text as the rest, not unique to that status.').
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
        -- WRITTEN (round 5, 2026-10-06; was a placeholder). The Yubikey's name
        -- on the world plate over a key on the ground, to anyone near it.
        key_label = 'Yubikey',
        -- VERBATIM (owner, 2026-10-06: 'When approaching one of these, a DUI
        -- should be shown: "Computer system" "press to open" with the
        -- interact key on it'). The title on every terminal's world plate,
        -- whatever its hint -- and its blip's name on the map.
        terminal_label = 'Computer system',
        -- VERBATIM (the same words). The plate's hint, beside the interact
        -- key's cap: THE ONE PLATE, whatever the player's status -- a key or
        -- none (round 6), the squad's use spent or not (round 7). A terminal
        -- outside the storm has no plate.
        terminal_use = 'press to open',

        -- ── the persistent notices, on the HUD. WRITTEN (2026-10-06, round 4)
        --
        -- The owner: "Anything that a player is being impacted by, which
        -- happened as a result of another player's actions at a terminal,
        -- should show a persistent notification with a timer explaining what
        -- the impact is and when it will be over." Read by THE PLAYER IT IS
        -- HAPPENING TO, in a stack of rows beside the minimap, each with a
        -- countdown to its end (m:ss) -- or, for one that lasts the rest of the
        -- match, impact_until_end in its place. Each row is up only while it is
        -- true (server/terminalfx.lua's impact sources say who gets which).
        -- They name the function first, so the lobby's notice and the row read
        -- as the same thing.

        -- In place of a countdown, for a row that lasts the rest of the match.
        impact_until_end = 'Until the match ends',
        -- EMP: every player whose driving it stalls (everyone outside the
        -- runner's squad).
        impact_emp = 'EMP: any vehicle you drive stalls.',
        -- Power outage: every player standing in its area (not the runner).
        impact_outage = 'Power outage: the lights are out where you are.',
        -- Comms blackout: every player in a squad it blacked out. Squad-only,
        -- like the function, so it has no `_solo` sibling.
        impact_blackout = 'Comms blackout: your teammates are off your map.',
        -- A bounty (Scan's, on the player who ran it, or a Contract's, on its
        -- target): the player who carries it.
        impact_bounty = 'Bounty: every player can see where you are.',
        -- Scan: every opponent of a scanning squad, for the rest of the match
        -- (not while their own squad is under Ghost).
        impact_scan = 'Scan: another squad can see where you are.',
        impact_scan_solo = 'Scan: another player can see where you are.',
        -- Time & weather, for the rest of the match: everyone but the runner,
        -- one row for a time run and one for a weather run.
        impact_time = 'Time & weather: the time of day was changed.',
        impact_weather = 'Time & weather: the weather inside the circle was changed.',
        -- Storm control, for the rest of the match: everyone but the runner's
        -- squad, which has the mark on its maps instead (2026-10-07: "Everyone
        -- else only gets the usual notice"). WRITTEN (2026-10-06, round 5; was
        -- "...the storm will end where another player chose.").
        impact_storm = 'Storm control: the storm is closing toward a spot another player picked.',
        -- WRITTEN (2026-10-06, round 5). Airstrike, from its warning to its last
        -- rocket: every player in the fight inside its reach (the circle and the
        -- blast's reach past it), the runner's squad included, but never the
        -- runner. The countdown is to the last rocket.
        impact_airstrike = 'Airstrike: rockets are coming down where you are.',

        -- ── the desktop (cuchi_computer) -- at the terminal. WRITTEN ─────────

        -- Under the boot spinner, for the 7 to 10 seconds the desktop takes
        -- to start (bootMinMs .. bootMaxMs below, a new pick every boot).
        shell_boot = 'Starting up...',
        -- WRITTEN (2026-10-06, round 4). THE STORM'S CLOSE: the blue screen
        -- the whole computer shows for about 1.5 s when the storm takes the
        -- terminal while it is in use, before it powers off (owner: "the
        -- computer should show a BSOD quickly followed by a CRT-style visual
        -- power off"). A parody of Windows 10's: its sad face, its one
        -- sentence, and a stop code that names the storm, top to bottom.
        bsod_face = ':(',
        bsod_text = 'Your terminal ran into a problem and needs to shut down.',
        bsod_code = 'Stop code: STORM_REACHED_TERMINAL',
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
        -- page's path segment. A tool's own segment is its id. The host
        -- kept its name when the app became Control Tower (round 2): a
        -- question for the owner, not a change made for him.
        address_host = 'https://controltower.blitz',
        -- VERBATIM (owner, 2026-10-06: "the functions page should be called
        -- Home in the URL, sidebar, and breadcrumbs"), lower case as a path
        -- is: the cards page. A tool's page is under path_tools.
        path_home = 'home',
        -- WRITTEN (2026-10-06, round 5: 'Rename the "Functions" to "Tools"';
        -- was path_functions, 'functions'). A tool's page: /tools/<id>.
        path_tools = 'tools',
        path_howto = 'how-to',
        -- WRITTEN (2026-10-06). The Privacy page.
        path_privacy = 'privacy',
        path_login = 'login',
        -- Hover labels on the browser's buttons and the window's close.
        aria_back = 'Back',
        aria_forward = 'Forward',
        aria_reload = 'Reload',
        aria_address = 'Address',
        -- The close button on the confirmation box and on a run's answer.
        aria_close = 'Close',
        -- The search box in the top bar, its "use what I typed" row and the
        -- row it shows when nothing matches. WRITTEN (2026-10-06, round 5:
        -- 'Rename the "Functions" to "Tools"'; were 'Search functions' and
        -- 'No matching functions').
        search_placeholder = 'Search tools',
        search_use = 'Search for "{value}"',
        search_empty = 'No matching tools',
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

        -- VERBATIM (owner, 2026-10-06, as path_home): the cards page's link
        -- and its first breadcrumb, which every tool's trail starts with.
        -- The page's heading is tools_heading.
        nav_home = 'Home',
        nav_howto = 'How to',
        -- WRITTEN (2026-10-06). The Privacy page's link, after How to, and
        -- its breadcrumb.
        nav_privacy = 'Privacy',
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

        -- WRITTEN (2026-10-06, round 5: 'Rename the "Functions" to "Tools"';
        -- were functions_heading 'Functions' and 'No functions match.'). The
        -- cards' heading, and the line when the filters leave none.
        tools_heading = 'Tools',
        filter_empty = 'No tools match.',
        filter_clear = 'Clear filter',
        card_category = 'Category',
        card_risk = 'Risk',
        card_status = 'Status',
        -- WRITTEN (2026-10-06, round 4: "The cards should show cost in volts
        -- and bounty"). A card's cost and bounty sections, their names in
        -- the preferences' "Card content", and the labels of the filters of
        -- the same names on Home (with card_category, card_risk and
        -- card_status). A cost in Volts is its figure and the word, in the
        -- Volts style; a function that costs no Volts is cost_free.
        card_cost = 'Cost',
        card_bounty = 'Bounty',
        cost_free = 'Free',
        -- WRITTEN (round 4). The Cost filter's choice for every function that
        -- costs Volts.
        cost_paid = 'Paid',
        -- WRITTEN (2026-10-06, round 5). A card's cost when it depends on the
        -- options chosen and the cheapest choice is free (Gear Up: free for
        -- you or a teammate, Volts for the whole squad -- the registry row's
        -- `costBy`). {volts} is the most it can cost, in the Volts style. The
        -- Cost filter lists such a card under both Free and Paid.
        cost_free_or = 'Free, or {volts}',
        -- WRITTEN (round 4). A card's bounty, from its registry row's
        -- `bounty`: none, the runner gets one (Scan), another player gets
        -- one (Contract). The Bounty filter's choices too.
        bounty_none = 'None',
        bounty_runner = 'You get one',
        bounty_target = 'Another player gets one',
        -- WRITTEN (round 4: "the "Functions" search should have filters
        -- available for category, risk, Volts cost (free/paid), bounty, and
        -- availability status"). Each filter's choice that filters nothing,
        -- after its label (card_category, card_risk, card_cost, card_bounty,
        -- card_status). The other choices are the cards' own words:
        -- category_*, risk_*, cost_free / cost_paid, bounty_*, status_*.
        filter_any = 'Any',
        -- VERBATIM (owner, 2026-10-06: "Any tool that can impact the whole
        -- squad should have a tooltip next to the card title (the blue
        -- text, see attached) which should read "Squads!" upon clicking it,
        -- the new box should read "This function will apply to your entire
        -- squad.""). The blue link beside the title of a card and of a page
        -- whose row is `squadWide`, and the box it opens. IN A SQUAD MATCH
        -- ONLY: the empty `_solo` lines hide both outside one.
        squads_link = 'Squads!',
        squads_link_solo = '',
        squads_popover = 'This function will apply to your entire squad.',
        squads_popover_solo = '',
        pref_title = 'Preferences',
        pref_confirm = 'Confirm',
        pref_cancel = 'Cancel',
        pref_page_size = 'Cards per page',
        -- WRITTEN (round 5; was '{count} functions').
        pref_page_option = '{count} tools',
        pref_visible = 'Card content',
        pref_visible_group = 'Show on each card',
        -- What a card says about a function right now.
        status_available = 'Available',
        status_used = 'Used',
        -- VERBATIM (owner, 2026-10-05, round 2: 'the term "offline" is
        -- confusing when we use "Available" to indicate the opposite. Let's
        -- instead say "Not available"'). A function not built yet, or a
        -- terminal outside the storm.
        status_offline = 'Not available',
        -- ROUND 6 (owner, 2026-10-07: "Let's make all the terminals have all
        -- the same tools available please", and on the tools' own rules "Yes
        -- please say the real reason"). Every terminal lists every tool, so
        -- round 2's "Not available at this terminal" (status_not_here) is
        -- gone: a tool stopped by a rule of the match says the rule, in a few
        -- words, as status_<the server's reason> (the full line is beneath it
        -- on the tool's page), and the Status filter groups them all as
        -- status_not_now -- which is also what a reason with no short line of
        -- its own says ('unavailable': a run already under way, say).
        -- WRITTEN (round 6, proposal for the owner)
        status_not_now = 'Not available now',
        -- WRITTEN (round 6, proposal for the owner)
        status_no_key = 'Needs a Yubikey',
        -- WRITTEN (round 6, proposal for the owner)
        status_no_storm = "Storm hasn't started",
        -- WRITTEN (round 6, proposal for the owner)
        status_storm_aimed = 'Storm spot already picked',
        -- WRITTEN (round 6, proposal for the owner)
        status_no_circle = 'Final circle reached',
        -- WRITTEN (round 6, proposal for the owner)
        status_no_target = 'No opponent with an elimination',
        -- WRITTEN (round 6, proposal for the owner)
        status_no_weapons = 'No armed opponents',
        -- WRITTEN (round 6, proposal for the owner)
        status_health_full = 'Nobody to heal or drain',
        -- WRITTEN (round 6, proposal for the owner)
        status_reboot_none = 'Nobody to bring back',
        -- WRITTEN (round 6, proposal for the owner)
        status_no_night = 'Only at night',
        -- Max ammo with every gun in the squad full. Worked out over the
        -- whole squad, so in a squad match it says the squad's: a runner with
        -- no gun whose teammates' guns were full read "Ammo already full" as
        -- their own (round 7 review; owner, 2026-10-07: '"ammo already full"
        -- shows when I've got no weapons in-hand, so that's a bit confusing').
        -- WRITTEN (round 7, proposal for the owner)
        status_ammo_full = "Squad's ammo already full",
        -- WRITTEN (round 6, proposal for the owner). The same, outside a
        -- squad match (round 6's line).
        status_ammo_full_solo = 'Ammo already full',
        -- WRITTEN (round 7, proposal for the owner). Max ammo when nobody it
        -- fills carries a gun (owner, 2026-10-07: '"ammo already full" shows
        -- when I've got no weapons in-hand, so that's a bit confusing').
        status_no_guns = 'No guns to refill',
        -- WRITTEN (round 6, proposal for the owner)
        status_drop_busy = 'Airdrop already on its way',
        -- WRITTEN (round 6, proposal for the owner)
        status_no_site = 'No airdrop spot in the circle',
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
        -- VERBATIM (owner, 2026-10-06, round 4: 'This could be a multi-step
        -- flow on the popup box like where the confirm button is greyed out (spelling-ok: his words)
        -- until they select a "set location" button'). The confirm box's
        -- first step for a function run at a spot (`spot` on its registry row:
        -- Storm control, Supply drop): it hides the computer and opens the big
        -- map, where the player sets a waypoint and closes the map. Run stays
        -- disabled until a spot is set; pressed again, it picks again. The
        -- place picked is then shown beside it by the game's own name for it
        -- (its street and area), which is no line of ours.
        confirm_location = 'Set location',

        -- ── why a function cannot run. WRITTEN, beside no_key, offline and
        --    squad_used above ──────────────────────────────────────────────────

        -- WRITTEN (2026-10-05, round 2; was 'This function is offline.'; round
        -- 5 said tool for function). A tool whose effect is not built yet:
        -- listed, described, never run. Beside the "Not available" badge, so
        -- it does not say offline.
        fn_offline = 'This tool is not available.',
        -- WRITTEN (2026-10-05, round 2). A run whose cost the player's Volts
        -- cannot cover: refused by the server after every other reason, with
        -- nothing spent. {cost} and {balance} are the figure and the word.
        no_volts = "You don't have enough Volts. This costs {cost}, and your balance is {balance}.",
        -- A reason with no line of its own. WRITTEN (round 5; was "This
        -- function can't run right now.").
        unavailable = "This tool can't run right now.",
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
        -- WRITTEN (round 7, proposal for the owner). Max ammo: nobody in the
        -- squad still in the fight carries a gun -- refused, spending nothing.
        no_guns = 'Nobody in your squad is carrying a gun.',
        -- WRITTEN (round 7, proposal for the owner). The same, outside a
        -- squad match.
        no_guns_solo = "You're not carrying a gun.",
        -- Supply drop: another airdrop is waiting for a player or falling.
        drop_busy = 'Another airdrop is already on its way.',
        -- WRITTEN (2026-10-06, round 4; was 'Everyone in your squad who is
        -- standing is already at full health and armor.'). Field medic, with
        -- nothing at all to change: everyone in the squad who is standing is
        -- already full (or nobody is standing), and no other player standing
        -- has 50 health or more to lose -- refused, spending nothing.
        health_full = 'Everyone in your squad who is standing is already at full health and armor, and no other player has 50 health or more.',
        health_full_solo = "You're already at full health and armor, and no other player has 50 health or more.",
        -- WRITTEN (2026-10-06, round 4; was 'Nobody in the match is carrying
        -- a weapon.'). Disarm: nobody still in the match outside the squad
        -- carries a weapon -- refused, spending nothing (the Volts included).
        no_weapons = 'Nobody outside your squad is carrying a weapon.',
        no_weapons_solo = 'Nobody else in the match is carrying a weapon.',
        -- WRITTEN (2026-10-06, wave A). Contract: nobody outside the squad
        -- has an elimination yet -- refused, spending nothing.
        no_target = 'Nobody outside your squad has an elimination yet.',
        no_target_solo = 'Nobody else has an elimination yet.',
        -- WRITTEN (2026-10-06, round 4). Power outage, when the match is not
        -- on a night a Time & weather run set (owner: "only work if someone
        -- else has set it to night time first") -- refused, spending nothing
        -- (at the terminal: why not).
        no_night = "This only works while it's night because someone ran Time & weather.",

        -- ── the how-to page. WRITTEN. The one page allowed to talk strategy,
        --    in general terms; a function's own page never says how it helps ──

        howto_title = 'How to use the terminal',
        howto_key_title = 'Getting a Yubikey',
        -- WRITTEN (2026-10-06, round 5; the first line was "Airdrops have a
        -- 50/50 chance of carrying a Yubikey, and legendary crates have a
        -- small chance."): every crate can hold one now, at a rare item's
        -- chance (sources.crateChance below).
        howto_key_body = "Airdrops have a 50/50 chance of carrying a Yubikey. Any crate can hold one too, about as often as any one rare item.\nYou can hold one Yubikey at a time. It doesn't take an inventory slot, and its icon shows on your HUD.\nIf you're eliminated, your Yubikey drops where you fell, and anyone can pick it up.\nA Yubikey you don't use stays with you into your next match.",
        howto_terminal_title = 'Using a terminal',
        -- WRITTEN (2026-10-06, round 3: "hold interact" became "press
        -- interact", as the plate's press opens the computer now; round 5:
        -- "Pick a function" became "Pick a tool").
        -- WRITTEN (round 6, proposal for the owner; the last line was "Pick a
        -- tool, read its page, choose its options and press Run."): the
        -- options are asked in the box Run opens now, not on the page.
        howto_terminal_body = "While you hold a Yubikey, terminals inside the storm show on your map as laptops.\nWalk up to one and press interact to open it.\nA terminal outside the storm is offline and won't open.\nPick a tool, read its page and press Run. The box that opens asks for any choices the tool needs. Press Run there to run it.",
        howto_rules_title = 'One use per squad',
        -- WRITTEN (round 5 said tool for function in the rules, the notices
        -- and the tips, each way).
        howto_rules_body = "Each squad gets one terminal use per match. A solo player is a squad of one.\nRunning a tool uses your Yubikey and your squad's use. A Yubikey is gone after one use.\nIf a squadmate already ran a tool this match, your Yubikey stays with you for a later match.\nA tool that can't run uses nothing.",
        -- WRITTEN (2026-10-05, round 2). The same section outside a squad
        -- match.
        howto_rules_title_solo = 'One use per match',
        howto_rules_body_solo = "You get one terminal use per match.\nRunning a tool uses your Yubikey and your terminal use. A Yubikey is gone after one use.\nA tool that can't run uses nothing.",
        howto_notices_title = 'What everyone is told',
        -- WRITTEN (2026-10-06, round 4: the second line gained "unless its
        -- page says otherwise", for Field medic, which tells nobody).
        howto_notices_body = "When you open a terminal with a Yubikey, everyone in the match is told your name.\nWhen you run a tool, everyone is told your name and what you ran, unless its page says otherwise.\nSome tools tell more. Each tool's page lists who is told.",
        howto_tips_title = 'Tips',
        howto_tips_body = "Read a tool's risks before you run it.\nOpening a terminal announces you to the whole match. Clear the area first.\nA terminal near the storm's edge can go offline while you read. Pick one well inside the circle.\nTalk to your squad before you run anything. You only get one use between you.\nIntel shows the most while many squads are left. Supply matters most when your squad is low on gear.\nStorm tools change where the last fight happens. Think about where your squad will be.\nA bounty puts you on every map for 10 minutes. Have a plan to survive it first.",
        -- WRITTEN (2026-10-05, round 2). The tips outside a squad match.
        howto_tips_body_solo = "Read a tool's risks before you run it.\nOpening a terminal announces you to the whole match. Clear the area first.\nA terminal near the storm's edge can go offline while you read. Pick one well inside the circle.\nIntel shows the most while many players are left. Supply matters most when you're low on gear.\nStorm tools change where the last fight happens. Think about where you will be.\nA bounty puts you on every map for 10 minutes. Have a plan to survive it first.",

        -- ── the privacy page (owner, 2026-10-06: "a Privacy page in the
        --    sidebar", a made-up policy sponsored by Lifeinvader) ─────────────
        --
        -- VERBATIM: the owner approved this copy word for word ("Perfect",
        -- 2026-10-06). Not to be edited or re-punctuated without him. At the
        -- terminal: the page's title, then its body, two paragraphs (the '\n'
        -- between them). It says no "squad", so it has no _solo sibling.
        privacy_title = 'Privacy Policy',
        privacy_body = "Control Tower is proudly sponsored by Lifeinvader, the social network that already knows what you had for breakfast. By opening, touching, standing near, or thinking warmly about this terminal, you agree that everything you do here may be collected, stored, analyzed, monetized, re-monetized, printed out, laminated, and left on the dashboard of a stolen sedan in Vespucci. This includes, but is not limited to, your name, your location, your Volts balance, your loadout, your teammates' names (we will be using these), how long you hovered over Run before losing your nerve, and the exact noise you made when the storm caught you. Your data is stored securely on a server somewhere inside the storm and backed up nightly to a USB stick we found on the ground.\nWe take your privacy extremely seriously, which is why we guarantee complete privacy to every person who has never used, opened, approached, or heard of Control Tower. If you are reading this, that guarantee no longer applies to you, and we thank you for your contribution. Your information may be shared with Lifeinvader, its affiliates, its affiliates' cousins, the Los Santos Police Department, Merryweather Security, every other player in this match (you may have noticed), and anyone who asks nicely or loudly. You may request a copy of your data at any time by writing to an address we have not disclosed, and we will respond within 90 business years. You may opt out by uninstalling the planet. This policy may change at any time without notice, and probably already has since you started reading. If you made it this far, you have read more of this policy than anyone at Lifeinvader, and you are legally entitled to nothing.",

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
        scan_what = "Every opponent still in the match appears on the maps of everyone in your squad.\nThe marks update every 2 seconds until the match ends.\nA squad running Ghost is hidden from the marks while it lasts.\nThe player who runs it gets a bounty for 10 minutes.",
        scan_what_solo = "Every opponent still in the match appears on your map.\nThe marks update every 2 seconds until the match ends.\nA player running Ghost is hidden from the marks while it lasts.\nThe player who runs it gets a bounty for 10 minutes.",
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

        -- Storm control (owner's; LIVE since wave B, 2026-10-06; ROUND 4, the
        -- same day: "we should let them actually pick exactly where they want
        -- it", on the big map -- `spot` on the registry row, and its zone
        -- option and three possible circles gone)
        storm_control_name = 'Storm control',
        -- WRITTEN (storm control redesign, proposal for the owner; was 'Picks a
        -- spot on the map for the storm to close toward.'). Owner, 2026-10-07:
        -- "I select a marker of where I want the storm to FINISH that match."
        storm_control_summary = 'Picks the spot on the map where the storm finishes.',
        -- WRITTEN (storm control redesign, proposal for the owner; was round 5's
        -- "...closes toward it ... The last circle ends on that spot if the
        -- storm can reach it, or as close to it as the storm can get.\nEvery
        -- circle still has to fit inside the one before it..."). The owner,
        -- 2026-10-07, confirmed: the final circle is centered on the spot (the
        -- nearest land, for one in the water); the spot is marked for the
        -- runner and their squad for the rest of the match; each new circle
        -- moves an equal share of the remaining way toward it, so circles may
        -- break out past the one before (server/storm.lua's STORM CONTROL
        -- block); a circle already on the map never moves (round 6). ONE SPOT A
        -- MATCH (round 4's review): once the storm is aimed, every later run is
        -- refused (storm_aimed).
        storm_control_what = "You pick a spot on the map, and the storm finishes there. A spot in the water or off the map counts as the nearest land to it.\nEach new circle moves part of the way toward the spot, so a circle can land outside the one before it.\nThe final circle is marked on your squad's maps until the match ends.\nCircles already on the map don't move. The change starts with the next circle the storm draws.\nOnly one spot can be picked each match. Once it is, Storm control can't be run again.",
        -- WRITTEN (storm control redesign, proposal for the owner).
        storm_control_what_solo = "You pick a spot on the map, and the storm finishes there. A spot in the water or off the map counts as the nearest land to it.\nEach new circle moves part of the way toward the spot, so a circle can land outside the one before it.\nThe final circle is marked on your map until the match ends.\nCircles already on the map don't move. The change starts with the next circle the storm draws.\nOnly one spot can be picked each match. Once it is, Storm control can't be run again.",
        storm_control_duration = 'Rest of the match',
        storm_control_affects = 'Everyone in the match',
        storm_control_notified = 'Everyone in the match',
        -- WRITTEN (storm control redesign, proposal for the owner; was 'The
        -- storm may end short of your spot. ...'): the storm no longer ends
        -- short, and a far spot's circles break out.
        storm_control_risks = 'A far spot makes the circles jump far. Your squad still has to reach the last circle.',
        storm_control_risks_solo = 'A far spot makes the circles jump far. You still have to reach the last circle.',
        -- WRITTEN (storm control redesign, proposal for the owner; was 'The
        -- storm will end on your spot, or as close to it as it can.').
        storm_control_done = 'The storm will finish on your spot.',
        -- WRITTEN (storm control redesign, proposal for the owner; was 'Storm
        -- control. They picked a spot for the storm to close toward.').
        storm_control_description = 'Storm control. They picked where the storm finishes.',
        -- WRITTEN (2026-10-06, wave B). Storm control's own reason: the final
        -- circle is already drawn, so no circle is left to change -- refused,
        -- spending nothing (at the terminal: why not).
        no_circle = 'The final circle is already on the map.',
        -- WRITTEN (2026-10-06, round 4's review; round 5, was 'Someone has
        -- already picked where the storm ends this match.'). Storm control once
        -- the storm is already aimed this match: one spot a match, so a second
        -- squad's run never replaces the first's -- refused, spending nothing
        -- (at the terminal: why not). Round 4's three refusals of the spot
        -- itself (over water, outside the next circle, too near its edge) are
        -- gone with the limits they stated.
        storm_aimed = 'Someone has already picked a spot for the storm this match.',

        -- Comms blackout (owner's; LIVE since wave C, 2026-10-06)
        comms_blackout_name = 'Comms blackout',
        comms_blackout_summary = "Hides teammates' map markers from every other squad for a while.",
        -- WRITTEN (2026-10-06, wave C; was "...\nTheir squad panel stops
        -- showing where their teammates are.\n..."): the squad panel never
        -- showed where a teammate is -- client/state.lua folds no position
        -- into its rows -- so there is nothing there to stop showing, and the
        -- line went.
        -- WRITTEN (round 6, proposal for the owner; the last line is new):
        -- the options are asked in the box Run opens (round 6), so the page
        -- names them -- "We should explain what options exist in the
        -- description". The same for every tool with options below.
        comms_blackout_what = "Players in every other squad stop seeing their teammates on the map and the minimap.\nYour squad isn't affected. Voice chat isn't affected.\nWhen you press Run, you choose how long it lasts: 1 minute, 2 minutes or 3 minutes.",
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

        -- Time & weather (owner's; LIVE since wave B, 2026-10-06; ROUND 4, the
        -- same day: "either time or weather to be set. Not both. Weather should
        -- be any weather the game engine allows, except rain and thunder since
        -- those are reserved for the storm only. The duration should be the
        -- remainder of the match")
        time_weather_name = 'Time & weather',
        -- WRITTEN (2026-10-06, round 4; was "Changes the match's time of day,
        -- and the weather inside the circle, for a while."). One or the other,
        -- for the rest of the match, or until another run changes it (round
        -- 4's review: another squad's run may, so no line promises more).
        time_weather_summary = "Changes the match's time of day, or the weather inside the circle, until the match ends or another run changes it.",
        -- WRITTEN (2026-10-06, round 4; was "Sets the time of day for everyone
        -- in the match, and the weather inside the circle.\nOutside the circle,
        -- the storm's own weather stays.\nWhen it ends, the match's own time
        -- and weather come back."). The owner's round-2 rule still holds: the
        -- weather chosen here holds only inside the circle, and the storm's
        -- own weather wins outside it. The clock runs on from the time chosen
        -- at the match's own rate (#394), so the second line says it runs.
        -- WRITTEN (round 6, proposal for the owner; the first three lines were
        -- "Pick the time of day or the weather. ...", "The time of day
        -- changes for everyone..." and "The weather changes only inside the
        -- circle. ..."): the page names every choice the box offers.
        time_weather_what = "When you press Run, you choose to change the time of day or the weather. One run changes one of them, not both.\nThe time of day can be day, dusk or night. It changes for everyone in the match, and the clock runs on from there.\nThe weather can be extra sunny, clear, cloudy, smog, overcast, fog, Christmas, light snow, snow or blizzard. It changes only inside the circle. Outside it, the storm's own weather stays.\nIt lasts until the match ends, or until another run changes it.",
        -- WRITTEN (2026-10-06, round 4). The first option: which of the two
        -- this run changes. Only the chosen one's own option is shown under it.
        time_weather_opt_change = 'What to change',
        time_weather_opt_change_time = 'Time of day',
        time_weather_opt_change_weather = 'Weather',
        time_weather_opt_time = 'Time of day',
        time_weather_opt_time_day = 'Day',
        time_weather_opt_time_dusk = 'Dusk',
        time_weather_opt_time_night = 'Night',
        time_weather_opt_weather = 'Weather',
        -- WRITTEN (2026-10-06, round 4; was Clear, Rain and Fog). One per
        -- engine weather offered (fx.skyWeather), clearest first. "Clear" is
        -- the engine's CLEAR now, not the match's own clear sky.
        time_weather_opt_weather_sunny = 'Extra sunny',
        time_weather_opt_weather_clear = 'Clear',
        time_weather_opt_weather_clouds = 'Cloudy',
        time_weather_opt_weather_smog = 'Smog',
        time_weather_opt_weather_overcast = 'Overcast',
        time_weather_opt_weather_fog = 'Fog',
        time_weather_opt_weather_xmas = 'Christmas',
        time_weather_opt_weather_snowlight = 'Light snow',
        time_weather_opt_weather_snow = 'Snow',
        time_weather_opt_weather_blizzard = 'Blizzard',
        -- WRITTEN (2026-10-06, round 4; was '3 or 5 minutes, as chosen').
        time_weather_duration = 'Rest of the match, or until another run changes it',
        time_weather_affects = 'Everyone in the match',
        time_weather_notified = 'Everyone in the match',
        time_weather_risks = 'It changes what your squad can see too.',
        time_weather_risks_solo = 'It changes what you can see too.',
        -- WRITTEN (2026-10-06, round 4; was 'The time of day has changed, and
        -- so has the weather inside the circle.'). One line for either choice.
        time_weather_done = 'Your change is made. It lasts until the match ends, or until another run changes it.',
        time_weather_description = 'Time & weather. The sky has changed.',

        -- Power outage (owner's; LIVE since wave B, 2026-10-06; ROUND 4, the
        -- same day: "The power outage tool should only work if someone else
        -- has set it to night time first")
        power_outage_name = 'Power outage',
        -- WRITTEN (2026-10-06, round 4; was 'Turns the lights off for every
        -- player in an area for a while.'). The lights go off for the players
        -- in the area, not for the area itself (power_outage_what says why),
        -- so the card, the done line and the lobby's notice say whose lights
        -- go out -- and, since round 4, that it is a night's.
        power_outage_summary = 'Turns the lights off at night for every player in an area for a while.',
        -- WRITTEN (2026-10-06, round 4: the last line is new; wave B's was
        -- "Street lights, building lights and signs go dark in the area you
        -- choose. / ..."). The game's blackout is one switch per player for
        -- the whole map, not per district: a player in the area sees every
        -- light go dark, and a player outside it keeps every light, the area's
        -- included. The line says so.
        -- WRITTEN (round 6, proposal for the owner; the second line is new):
        -- the areas and the durations the box offers, which the page named
        -- only as radio buttons before round 6.
        power_outage_what = "Street lights, building lights and signs go dark for every player inside the area you choose.\nWhen you press Run, you choose the area: 1 km around a spot you pick on the map, the whole city of Los Santos, or everything outside the city in Blaine County. You also choose how long it lasts: 2 minutes or 4 minutes.\nPlayers outside the area keep their lights.\nVehicle headlights still work.\nThe lights come back when it ends.\nIt only works while it's night because someone ran Time & weather.",
        power_outage_opt_area = 'Area',
        -- WRITTEN (round 6, proposal for the owner; was 'Around this
        -- terminal' / 'Everything within 1 km of this terminal.'): "Any use
        -- of 'near this terminal' is like, not useful for this gamemode" --
        -- the area is 1 km around a spot picked on the map in the confirm box.
        power_outage_opt_area_spot = 'Around a spot you pick',
        power_outage_opt_area_spot_desc = 'Everything within 1 km of the spot you pick on the map.',
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
        -- WRITTEN (2026-10-06, wave B review; was 'The power is out.').
        power_outage_done = 'The lights are out for every player in the area.',
        -- WRITTEN (2026-10-06, wave B review; was 'Power outage. The lights are
        -- out.').
        power_outage_description = 'Power outage. The lights are out for every player in an area.',

        -- Disarm (owner's; LIVE since wave A, 2026-10-06; ROUND 4, the same
        -- day: "The disarm tool should not apply to the user or their squad")
        disarm_name = 'Disarm',
        -- WRITTEN (2026-10-06, round 4; was "Takes away every player's most
        -- powerful weapon.").
        disarm_summary = 'Takes away the most powerful weapon of every player outside your squad.',
        disarm_summary_solo = "Takes away every other player's most powerful weapon.",
        -- WRITTEN (2026-10-06, round 4; was "Every player still in the match
        -- loses the most powerful weapon they carry, your squad included.
        -- ...").
        disarm_what = "Every player still in the match outside your squad loses the most powerful weapon they carry.\nYour squad keeps all of its weapons.\nMost powerful means the highest rarity, then the most damage.\nThe weapons are gone. They aren't dropped.",
        disarm_what_solo = "Every other player still in the match loses the most powerful weapon they carry.\nYou keep all of yours.\nMost powerful means the highest rarity, then the most damage.\nThe weapons are gone. They aren't dropped.",
        disarm_duration = 'Instant',
        -- WRITTEN (2026-10-06, round 4; was 'Every player still in the match,
        -- your squad included').
        disarm_affects = 'Every player still in the match outside your squad',
        disarm_affects_solo = 'Every other player still in the match',
        disarm_notified = 'Everyone in the match',
        -- No `disarm_risks` since round 4: the squad no longer loses anything,
        -- so the two lines saying it did ("Your squad loses its most powerful
        -- weapons too.") went, and risk_notice is the page's only risk.
        -- WRITTEN (2026-10-06, round 4; was "Every player's most powerful
        -- weapon is gone.").
        disarm_done = 'The most powerful weapon of every player outside your squad is gone.',
        disarm_done_solo = "Every other player's most powerful weapon is gone.",
        -- WRITTEN (2026-10-06, round 4; was "Disarm. Every player's most
        -- powerful weapon is gone.").
        disarm_description = 'Disarm. Every player outside their squad lost their most powerful weapon.',
        disarm_description_solo = 'Disarm. Every other player lost their most powerful weapon.',

        -- Airstrike (owner's, approved 2026-10-06: "yes please put Airstrike in
        -- the same build"). ALL WRITTEN (2026-10-06, round 5) for his review.
        -- The 10 seconds, the 10 rockets, the 40 meters and the 4 seconds are
        -- fx.strikeWarnMs, strikeRockets, strikeRadiusM and strikeSpreadMs, and
        -- tools/test_terminalstrike.lua holds the page to them.
        airstrike_name = 'Airstrike',
        airstrike_summary = 'Calls 10 rockets down on a spot you pick on the map.',
        -- What the server does (server/terminalfx/airstrike.lua): rough
        -- circles while the spot is picked, then a warning everyone can see,
        -- then rockets on random points (homing in on them since round 7),
        -- whose damage the server works out. The
        -- runner's squad is hit too (the coordinator's proposal: it is their
        -- call where to aim). A player taken out by one counts as the
        -- runner's elimination, but never a teammate. The rough circles ask
        -- Ghost like every mark on another squad's map (BR.Terminal.hidden),
        -- so the page says Ghost hides a squad from them, as Scan's and
        -- Contract's do (round 5's review; tools/test_terminal.lua derives the
        -- rows whose marks ask Ghost from the code and holds each one's page).
        -- WRITTEN (round 7, proposal for the owner): the third line, "10
        -- rockets home in on random points" (was "10 rockets fall on random
        -- points ... They aren't guided."), since they fly in as homing
        -- missiles (owner, 2026-10-07: "Any chance we could use homing
        -- missiles targeted at the random coords we already have?").
        airstrike_what = "You pick a spot on the map. While you pick, opponents show as rough circles somewhere near where they are, unless your squad already sees them with Scan. A squad running Ghost is hidden from the circles while it lasts.\nEveryone in the match sees a circle on their map, and a red flare marks the spot. Players inside it are warned.\n10 seconds later, 10 rockets home in on random points within 40 meters of the spot over about 4 seconds.\nEach rocket hurts every player near where it lands, your squad and you included, and damages vehicles.\nAn opponent taken out by a rocket counts as your elimination.",
        airstrike_what_solo = "You pick a spot on the map. While you pick, opponents show as rough circles somewhere near where they are, unless you already see them with Scan. A player running Ghost is hidden from the circles while it lasts.\nEveryone in the match sees a circle on their map, and a red flare marks the spot. Players inside it are warned.\n10 seconds later, 10 rockets home in on random points within 40 meters of the spot over about 4 seconds.\nEach rocket hurts every player near where it lands, you included, and damages vehicles.\nAn opponent taken out by a rocket counts as your elimination.",
        airstrike_duration = 'About 15 seconds: a 10-second warning, then the rockets',
        airstrike_affects = 'Everyone near the spot, your squad included',
        airstrike_affects_solo = 'Everyone near the spot, you included',
        airstrike_notified = 'Everyone in the match, with a circle on their map',
        airstrike_risks = "Everyone sees where it will land, and has 10 seconds to get away.\nYour squad is hit too if it's near the spot.",
        airstrike_risks_solo = "Everyone sees where it will land, and has 10 seconds to get away.\nYou're hit too if you're near the spot.",
        airstrike_done = 'The airstrike is on its way.',
        airstrike_description = 'Airstrike. Rockets will hit the circle on the map in 10 seconds.',
        -- The circle on every player's map, and the rough circles while a
        -- spot is picked: their names in the pause map's legend.
        airstrike_blip = 'Airstrike',
        airstrike_fuzz_blip = 'Opponent nearby',
        -- Why it cannot run, at the terminal -- refused, spending nothing, the
        -- 200 Volts included: a spot off the play area.
        strike_spot = 'That spot is off the map. Pick a spot inside the play area.',

        -- Supply drop (owner's; LIVE)
        supply_drop_name = 'Supply drop',
        supply_drop_summary = 'Calls in an extra airdrop.',
        -- WRITTEN (2026-10-06, round 4; was "An extra airdrop is placed at
        -- the spot you choose and ..."): the spot is picked on the big map, and
        -- the drop goes to the airdrop spot nearest it, as any airdrop lands
        -- only at one.
        supply_drop_what = "You pick a place on the map. An extra airdrop is placed at the airdrop spot nearest it and marked on every player's map.\nLike any airdrop, the aircraft comes once a player is within 200 meters, and the drop is called off if nobody comes in time.\nIt lands only inside the next circle, like any airdrop.",
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

        -- Gear Up (owner's, round 5, 2026-10-06; he named it). Its name is his
        -- word, VERBATIM; every other line is WRITTEN for his review. "give
        -- something to themselves - anything of their choice - any inventory
        -- item or weapon which is not a heavy sniper or machine gun ... the
        -- item they choose can also be given to a teammate, or for a charge of
        -- 200 volts the whole team can get them. If they choose a consumable,
        -- they are given the maxCarry quantity of that item."
        gear_up_name = 'Gear Up',
        gear_up_summary = 'Gives you, a teammate or your whole squad an item or weapon you choose.',
        gear_up_summary_solo = 'Gives you an item or weapon you choose.',
        -- The 'mg' class and the Heavy Sniper are left out (gearUp, below); a
        -- consumable or throwable comes at a full stack clamped to what the
        -- player may carry (its carryMax), a weapon as one found in a crate
        -- does (a full magazine and one spare); nobody standing, or nobody
        -- with room, is refused before anything is spent.
        -- WRITTEN (round 6, proposal for the owner; the first line was "Pick
        -- an item or weapon from the list. ...", and the third "It goes to
        -- you or one teammate for free, ..."): the list is in the box Run
        -- opens, not on the page.
        gear_up_what = "When you press Run, you pick an item or weapon from a list. The Heavy Sniper and machine guns aren't on it.\nA consumable or a throwable comes as a full stack, up to what you can carry. A weapon comes loaded, with one spare magazine.\nYou also pick who gets it: you or one teammate for free, or everyone in your squad for Volts.\nOnly a player who is standing, with room in their inventory, can get it.",
        gear_up_what_solo = "When you press Run, you pick an item or weapon from a list. The Heavy Sniper and machine guns aren't on it.\nA consumable or a throwable comes as a full stack, up to what you can carry. A weapon comes loaded, with one spare magazine.\nYou need room for it in your inventory.",
        -- The dropdown of items. Each item's own line, gear_up_opt_item_<id>,
        -- is the game's name for it (its `label` in the weapons and loot
        -- configs), written in below as the list is built: no words of ours.
        gear_up_opt_item = 'Item',
        -- Who gets it. Outside a squad match the whole choice is not shown
        -- (the empty `_solo` lines): it is always you.
        gear_up_opt_who = 'Who gets it',
        gear_up_opt_who_solo = '',
        gear_up_opt_who_self = 'You',
        gear_up_opt_who_mate = 'One teammate',
        gear_up_opt_who_mate_solo = '',
        gear_up_opt_who_squad = 'Everyone in your squad',
        gear_up_opt_who_squad_solo = '',
        -- The dropdown of standing teammates, shown when "One teammate" is
        -- picked. Each choice is the teammate's name, as the squad panel and
        -- the match panel write it: no words of ours.
        gear_up_opt_mate = 'Teammate',
        gear_up_duration = 'Instant',
        gear_up_affects = 'You, one teammate or your whole squad, as chosen',
        gear_up_affects_solo = 'You',
        gear_up_notified = 'Everyone in the match, and any teammate who gets it',
        gear_up_notified_solo = 'Everyone in the match',
        -- One line for every choice: the runner's own inventory, a teammate's
        -- or the squad's.
        gear_up_done = 'The gear is handed out.',
        gear_up_description = 'Gear Up. They handed out gear of their choice.',
        -- A toast to each teammate who got it from someone else's run (never
        -- the runner), after the lobby's notice: {playername} is the runner,
        -- {description} what they got ("Assault Rifle", "3 Med Kits"). Only
        -- in a squad match, where a teammate can be picked; it says no squad.
        gear_up_received = '{playername} used Gear Up to give you: {description}.',
        -- Why it cannot run, at the terminal -- refused, spending nothing, the
        -- Volts included. The player it would go to is not standing (downed,
        -- in the air, out, or gone)...
        gear_standing = 'Only a player who is standing can get it.',
        -- ...the teammate picked is not one who can (no longer standing, or
        -- no longer a teammate)...
        gear_no_mate = "That teammate can't get it. Pick a teammate who is standing.",
        -- ...already carrying as many as they may (its carryMax)...
        gear_full = "You're already carrying as many of those as you can.",
        gear_full_mate = 'Your teammate is already carrying as many of those as they can.',
        gear_full_squad = 'Everyone in your squad who is standing is already carrying as many of those as they can.',
        gear_full_squad_solo = '',
        -- ...or with no free slot for it (and no stack of it to top up).
        gear_no_room = "You don't have room in your inventory for it.",
        gear_no_room_mate = "Your teammate doesn't have room in their inventory for it.",
        gear_no_room_squad = "Someone in your squad doesn't have room in their inventory for it.",
        gear_no_room_squad_solo = '',

        -- Vehicle drop (owner's, approved 2026-10-06: "Kuruma is good!", and
        -- "let's not have them pick a location for the vehicle drop, but
        -- instead have it drop within 40m of them, with a blip until they get
        -- into the vehicle, OR when in squads they can pick from a dropdown of
        -- alive teammates to drop it next to."). ALL WRITTEN (2026-10-06,
        -- round 5) for his review. The 40 is fx.dropRadiusM, and
        -- tools/test_terminalstrike.lua holds the page to it.
        vehicle_drop_name = 'Vehicle drop',
        vehicle_drop_summary = 'Drops an armored Kuruma by parachute next to you or a teammate.',
        vehicle_drop_summary_solo = 'Drops an armored Kuruma by parachute next to you.',
        -- What the server does (server/terminalfx/vehicle_drop.lua): the
        -- player it is for finds a road or open ground within 40 meters, the
        -- car comes down there, and the squad's blip goes when one of them
        -- gets in (or it is destroyed, or the match ends).
        -- WRITTEN (round 6, proposal for the owner; was "...or of the
        -- teammate you pick."): the teammate is picked in the box Run opens.
        vehicle_drop_what = "An armored Kuruma comes down by parachute on a road or open ground within 40 meters of you, or of a teammate you pick when you press Run.\nIt has no weapons.\nA blip marks it on your squad's maps until one of you gets in.\nPlayers nearby can see it come down, and anyone can take it.",
        vehicle_drop_what_solo = "An armored Kuruma comes down by parachute on a road or open ground within 40 meters of you.\nIt has no weapons.\nA blip marks it on your map until you get in.\nPlayers nearby can see it come down, and anyone can take it.",
        -- Next to whom. Outside a squad match the whole choice is not shown
        -- (the empty `_solo` lines): it is always you.
        vehicle_drop_opt_to = 'Drop it next to',
        vehicle_drop_opt_to_solo = '',
        vehicle_drop_opt_to_self = 'You',
        vehicle_drop_opt_to_mate = 'A teammate',
        vehicle_drop_opt_to_mate_solo = '',
        -- The dropdown of standing teammates, shown when "A teammate" is
        -- picked. Each choice is the teammate's name: no words of ours.
        vehicle_drop_opt_mate = 'Teammate',
        vehicle_drop_duration = 'It lands in about 10 seconds and stays. The blip lasts until one of your squad gets in.',
        vehicle_drop_duration_solo = 'It lands in about 10 seconds and stays. The blip lasts until you get in.',
        vehicle_drop_affects = 'Your squad',
        vehicle_drop_affects_solo = 'You',
        vehicle_drop_notified = 'Everyone in the match, and the teammate it lands next to',
        vehicle_drop_notified_solo = 'Everyone in the match',
        vehicle_drop_risks = "Players nearby can see it come down.\nAnyone can take it, and it can be destroyed like any vehicle.",
        vehicle_drop_done = 'Your vehicle is on its way down.',
        vehicle_drop_description = 'Vehicle drop. An armored car is coming down by parachute.',
        -- A toast to the teammate it lands next to (never the runner), after
        -- the lobby's notice: {playername} is the runner. Only in a squad
        -- match, where a teammate can be picked; it says no squad.
        vehicle_drop_received = '{playername} used Vehicle drop. An armored car is coming down next to you.',
        -- Its blip's name in the pause map's legend, on the squad's maps.
        vehicle_drop_blip = 'Vehicle drop',
        -- Why it cannot run, at the terminal -- refused, spending nothing, the
        -- Volts included. The teammate picked is not one who can get it (no
        -- longer standing, or no longer a teammate)...
        drop_no_mate = "That teammate isn't standing. Pick a teammate who is.",
        -- ...the player it is for is not standing now (it is asked again as
        -- the load ends)...
        drop_target = 'The player it was for has to be standing when it drops.',
        -- ...or no road or open ground was found within 40 meters of them:
        -- water, a building or a crowd all around, or a client that did not
        -- answer.
        drop_ground = "There's no road or open ground within 40 meters for the vehicle. Try again somewhere more open.",
        drop_ground_mate = "There's no road or open ground within 40 meters of your teammate for the vehicle.",

        -- Reboot (suggested; LIVE since wave C, 2026-10-06)
        reboot_name = 'Reboot',
        -- WRITTEN (round 6, proposal for the owner; was "...by parachute over
        -- this terminal."): over the runner or a teammate, never the terminal.
        reboot_summary = 'Brings eliminated squadmates back by parachute over you or a teammate.',
        -- WRITTEN (round 6, proposal for the owner; was "...by parachute over
        -- this terminal.\n..."). A rebooted player comes back the way a
        -- revive key brings one back over an ambulance (server/revivekey.lua):
        -- dropped 150 meters over the player picked, with a parachute.
        -- And round 6's review ("...over you or the teammate you pick."):
        -- the teammate is picked in the box Run opens.
        reboot_what = "Every eliminated player in your squad comes back with full health, by parachute over you or a teammate you pick when you press Run.\nThey come back with an empty inventory.\nPlayers who left the match don't come back.",
        -- Over whom (round 6), Vehicle drop's two options. Squad-only, so no
        -- `_solo` lines. WRITTEN (round 6, proposal for the owner).
        reboot_opt_to = 'Bring them back over',
        reboot_opt_to_self = 'You',
        reboot_opt_to_mate = 'A teammate',
        -- The dropdown of standing teammates, shown when "A teammate" is
        -- picked. Each choice is the teammate's name: no words of ours.
        -- WRITTEN (round 6, proposal for the owner).
        reboot_opt_mate = 'Teammate',
        reboot_duration = 'Instant',
        reboot_affects = 'Your squad',
        reboot_notified = 'Everyone in the match',
        -- WRITTEN (round 6, proposal for the owner; the second line was "They
        -- come back here, where the notice was just sent from."). A revive key
        -- for a rebooted player is spent with the reboot -- they are back --
        -- even one the squad paid for at an ambulance.
        reboot_risks = "Rebooted players start with nothing.\nPlayers nearby can see them come down.\nA revive key for any of them is used up, even one your squad bought.",
        reboot_done = 'Your squad is back.',
        reboot_description = 'Reboot. Their squad is back.',
        -- WRITTEN (2026-10-06, wave C). Reboot's own reason: nobody in the
        -- squad is eliminated and still in the match (a player who left
        -- cannot come back) -- refused, spending nothing, the Volts included
        -- (at the terminal: why not). Squad-only, like every Reboot line.
        reboot_none = "There's nobody in your squad to bring back.",
        -- WRITTEN (round 6, proposal for the owner). Reboot's reason when it
        -- comes back over the runner and the runner is not standing as it runs
        -- (downed, out or in the air) -- refused, everything given back. A
        -- teammate picked who is no longer standing is Vehicle drop's
        -- drop_no_mate, the same line.
        reboot_target = 'You have to be standing when your squad comes back over you.',

        -- Ghost (suggested; LIVE since wave A, 2026-10-06). WRITTEN (2026-10-06,
        -- round 5): the summary and the page's first line no longer name a
        -- function the owner cut in round 5, so they say what Ghost hides now:
        -- the squad, from Scan and the bounty markers.
        ghost_name = 'Ghost',
        -- WRITTEN (2026-10-06, round 5, the Airstrike build): an Airstrike's
        -- rough circles, shown while its spot is picked, ask Ghost too (the one
        -- predicate every mark on another squad's map asks), so the lines say
        -- so -- were "...from Scan and bounty markers..." and "...other squads'
        -- Scan markers.".
        ghost_summary = 'Hides your squad from Scan, Airstrike and bounty markers for a while.',
        ghost_summary_solo = 'Hides you from Scan, Airstrike and bounty markers for a while.',
        -- WRITTEN (round 6, proposal for the owner; the last line is new):
        -- the duration the box offers.
        ghost_what = "Your squad doesn't show up on other squads' Scan or Airstrike markers.\nIf one of you has a bounty, the bounty marker is hidden too.\nIt doesn't hide you from anyone who can see you.\nWhen you press Run, you choose how long it lasts: 2 minutes or 4 minutes.",
        ghost_what_solo = "You don't show up on other players' Scan or Airstrike markers.\nIf you have a bounty, the bounty marker is hidden too.\nIt doesn't hide you from anyone who can see you.\nWhen you press Run, you choose how long it lasts: 2 minutes or 4 minutes.",
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

        -- EMP (suggested; LIVE since wave C, 2026-10-06; ROUND 4, the same day:
        -- "The EMP tool should kill all cars in the entire match, except the
        -- ones that the user or their squad get into. This should last for 3
        -- minutes." -- so its radius and duration options are gone)
        emp_name = 'EMP',
        -- WRITTEN (2026-10-06, round 4; was 'Stalls every vehicle in an area
        -- for a short time.').
        emp_summary = 'Stalls every vehicle in the match for 3 minutes, except the ones your squad drives.',
        emp_summary_solo = 'Stalls every vehicle in the match for 3 minutes, except the ones you drive.',
        -- WRITTEN (2026-10-06, round 4; was "Every vehicle within the radius
        -- you choose stalls and won't start.\nVehicles that drive in after it
        -- goes off aren't affected.\nThey start again when it ends."). It is
        -- the DRIVER that decides (server/terminalfx/emp.lua): a car stalls
        -- while anybody but the squad drives it, wherever it is. WRITTEN
        -- (round 7, proposal for the owner): the second line, "NPC traffic
        -- stops too." (owner, 2026-10-07: "The EMP doesn't work for NPC
        -- vehicles. We should probably use speed zones for this and set it
        -- to 0." -- client/terminalfx/emp.lua).
        emp_what = "For 3 minutes, every vehicle in the match stalls and won't start while a player outside your squad is driving it.\nNPC traffic stops too.\nVehicles your squad drives keep working, unless another squad's EMP is going off too. If someone outside your squad takes the wheel, it stalls.\nVehicles start again when it ends, unless another EMP is still going off.",
        emp_what_solo = "For 3 minutes, every vehicle in the match stalls and won't start while another player is driving it.\nNPC traffic stops too.\nVehicles you drive keep working, unless another player's EMP is going off too. If another player takes the wheel, it stalls.\nVehicles start again when it ends, unless another EMP is still going off.",
        -- WRITTEN (2026-10-06, round 4; was '30 seconds or 1 minute, as
        -- chosen').
        emp_duration = '3 minutes',
        -- WRITTEN (2026-10-06, round 4; was 'Every vehicle in the radius,
        -- yours included'). WRITTEN (round 7, proposal for the owner): ", and
        -- NPC traffic" -- the What line's "NPC traffic stops too." said what
        -- this line left out.
        emp_affects = 'Every vehicle in the match driven by a player outside your squad, and NPC traffic',
        emp_affects_solo = 'Every vehicle in the match driven by another player, and NPC traffic',
        emp_notified = 'Everyone in the match',
        -- No `emp_risks` since round 4: the squad's own vehicles no longer
        -- stall, so the lines saying they did ("Your squad's vehicles in the
        -- radius stall too.") went, and risk_notice is the page's only risk.
        emp_done = 'The EMP went off.',
        -- WRITTEN (2026-10-06, round 4; was 'EMP. Vehicles near their
        -- terminal have stalled.').
        emp_description = 'EMP. Every vehicle stalls for 3 minutes, except the ones their squad drives.',
        emp_description_solo = 'EMP. Every vehicle stalls for 3 minutes, except the ones they drive.',

        -- Contract (new; LIVE since wave A, 2026-10-06; ROUND 4, the same day:
        -- "The contract bounty should last 10 minutes, and cannot land on a
        -- player in the same squad as the user"). Its bounty is Scan's word
        -- for word since: the owner's bounty_new and bounty_protect (whose "for
        -- the next 10 minutes" is now true of both) -- so wave A's
        -- contract_protect (the five-minute line to the target's squad) and
        -- contract_target (a toast to the target) are gone. The target reads
        -- their own name in bounty_new, and their HUD's persistent notice
        -- (impact_bounty) says the bounty and its time left.
        contract_name = 'Contract',
        -- WRITTEN (2026-10-06, round 4; was 'Puts a bounty on the player with
        -- the most eliminations.'): never the runner's squad, so the card
        -- says so.
        contract_summary = 'Puts a bounty on the player outside your squad with the most eliminations.',
        contract_summary_solo = 'Puts a bounty on the player with the most eliminations, other than you.',
        -- WRITTEN (2026-10-06, round 4; "for 5 minutes" became 10).
        contract_what = "The player outside your squad with the most eliminations gets a bounty for 10 minutes.\nTheir position shows on every player's map while it lasts. If their squad runs Ghost, it's hidden while Ghost lasts.\nA tie goes to the player who got there first.",
        contract_what_solo = "The player with the most eliminations, other than you, gets a bounty for 10 minutes.\nTheir position shows on every player's map while it lasts. If they run Ghost, it's hidden while Ghost lasts.\nA tie goes to the player who got there first.",
        -- WRITTEN (2026-10-06, round 4; was '5 minutes').
        contract_duration = '10 minutes',
        contract_affects = 'One player outside your squad',
        contract_affects_solo = 'One player other than you',
        -- WRITTEN (2026-10-06, round 4; was 'Everyone in the match, the target
        -- included'): the target's squad is told to protect them.
        contract_notified = "Everyone in the match, and the target's squad",
        contract_notified_solo = 'Everyone in the match',
        -- WRITTEN (2026-10-06, round 4; was 'The target is told a contract is
        -- on them.').
        contract_risks = 'The target is told they have a bounty, and for how long.',
        contract_done = 'The contract is out.',
        contract_description = 'Contract. The top player has a bounty.',

        -- Field medic (new; LIVE since wave A, 2026-10-06; ROUND 4, the same
        -- day: "Field medic should heal everyone on the squad to full, and
        -- their shield, and remove 20 health from everyone else in the match
        -- who has at least 50 health", and "Field medic should not notify
        -- everyone" -- `quiet` on its row, so it has no `_description` and its
        -- page no risk_notice)
        field_medic_name = 'Field medic',
        -- WRITTEN (2026-10-06, round 4; was 'Restores full health and armor
        -- to everyone in your squad.' / 'Restores your full health and armor.').
        field_medic_summary = 'Restores full health and armor to everyone in your squad, and takes 20 health from other players.',
        field_medic_summary_solo = 'Restores your full health and armor, and takes 20 health from other players.',
        -- WRITTEN (2026-10-06, round 4: the last line is new). The 20 and the
        -- 50 are fx.medicDrainHp and fx.medicDrainFromHp; the suite holds the
        -- page to them.
        field_medic_what = "Every player in your squad who is still standing gets full health and full armor.\nDowned players aren't revived.\nEvery other player in the match who is standing with at least 50 health loses 20 health. Their armor isn't touched.",
        field_medic_what_solo = "You get full health and full armor.\nEvery other player in the match who is standing with at least 50 health loses 20 health. Their armor isn't touched.",
        field_medic_duration = 'Instant',
        -- WRITTEN (2026-10-06, round 4; was 'Your squad' / 'You').
        field_medic_affects = 'Your squad, and every other player with at least 50 health',
        field_medic_affects_solo = 'You, and every other player with at least 50 health',
        -- WRITTEN (2026-10-06, round 4; was 'Everyone in the match'): the run
        -- tells the lobby nothing (opening the terminal with a key still did).
        field_medic_notified = 'Nobody',
        field_medic_risks = "Only players standing when it runs are healed.",
        field_medic_done = 'Your squad is patched up.',
        field_medic_done_solo = "You're patched up.",
    },

    -- ═══ THE ART: EVERY PLACEHOLDER IN ONE SPOT ═══
    --
    -- The owner's Yubikey prop (`blitz_seckey`, in the Season 2 props resource)
    -- is the key on the ground since round 6, and his HUD icon since round 5;
    -- the glyphs are still plain text. The blips are the owner's own numbers
    -- (#396, 2026-10-04: "type 521, color 51 (draws as a laptop)", and the
    -- bounty's "blip 58, color 3" for everyone and "blip 58, color 69" for
    -- teammates).
    art = {
        -- The Yubikey lying on the ground: any loose key, from a crate, an
        -- airdrop, a death or a leave. Drawn by client/loot.lua like any loot.
        --
        -- THE OWNER'S PROP (round 6, 2026-10-07: "the pickup works but it
        -- doesn't show the prop"). `blitz_seckey`, streamed by br_stream_s2
        -- with blitz_seckey.ytyp -- a Season 2 resource, as the key is. Its
        -- drawable's bounds, read from the .ydr's header: 24 x 9.6 x 3.1 cm,
        -- origin at its base. A pistol's length, the size of the small loot
        -- around it, so it is drawn as authored (1.0 costs no matrix write).
        keyProp = 'blitz_seckey',
        keyScale = 1.0,
        -- THE STOCK STAND-IN, for a client that cannot draw his: a Season 2
        -- box without the pack, or a stream that never arrives. client/loot.lua
        -- asks the CD image for keyProp and draws this instead when it is not
        -- there (and from then on, once it fails to stream or build). A heist
        -- USB stick a few centimeters long, at 4x -- about his prop's length.
        --
        -- IT IS A MODEL THIS GAME HAS, which the old stand-in was not: the
        -- key was drawn as `prop_cs_usb_drive` until round 6, a name that is
        -- in no object list for any build, so IsModelValid said no, the prop
        -- was never built and a key on the ground showed its glow and
        -- nothing else.
        keyFallbackProp = 'hei_prop_hst_usb_drive',
        keyFallbackScale = 4.0,
        -- The mark beside a holder's name in the squad panel, a string drawn as
        -- text; and on the HUD, whether the holder's own icon is drawn -- the
        -- icon itself is the owner's image since round 5 (br_ui's
        -- public/items/yubikey.png, hud/YubikeyIcon.tsx), not this glyph.
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
        -- 2 meters: every row stands at its laptop in the ymap he published
        -- (br_stream_s2 5ec1f721) since paleto_pd and calafia_way were moved
        -- the 1.7 m onto theirs (2026-10-06), so this is slack, not reach.
        hideRadiusM = 2.0,
        -- THE PLATE AT THE LAPTOP (round 6, owner 2026-10-07: "please lower
        -- the DUIs to the elevation of the laptops"): how far over a row's z
        -- -- the laptop's own origin, where it sits on its desk, at every site
        -- -- the plate is centered, in meters. About the middle of an open
        -- laptop's screen. It was 0.9 m: about head height over a laptop
        -- on a desk. client/yubikey.lua reads it for every site.
        plateLiftM = 0.15,
        -- A terminal's blip, drawn only while this player holds a key, from
        -- warmup on, and only for a terminal inside the storm once there is
        -- one (round 5). One short-range blip per terminal, a fuel station's
        -- kind (client/yubikey.lua terminalBlip): the type is these three, the
        -- display the game's default.
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
        -- Vehicle drop (round 5): its blip on the squad's maps until one of
        -- them gets in (sprite 225 is the game's car; color 2 green -- a
        -- placeholder like Scan's), and the canopy the car hangs from on the
        -- way down: the airdrop's own cargo chute (BR.Config.Airdrop's
        -- chuteModel and its deploy anim), `chuteScale` times its authored
        -- size, `chuteRiseM` over the car's origin.
        drop = { sprite = 225, colour = 2, scale = 1.0, chuteScale = 3.0, chuteRiseM = 1.2 },
        -- Airstrike (round 5): the circle on every player's map from its
        -- warning to its last rocket (a radius blip, red), and the rough
        -- circles of its map pick (a fainter red). Placeholders like Scan's.
        strike = { colour = 1, alpha = 110 },
        fuzz = { colour = 1, alpha = 60 },
        -- What each client draws of it, and nothing more: the rocket's model
        -- with the rocket trail from `core`, flying in as a homing missile
        -- (round 7, below); where it lands, a fireball from `core`
        -- ('exp_grd_vehicle', the ground explosion GTA draws for a car), the
        -- game's cheap explosion sound and a camera shake for a player within
        -- shakeM. NOT AddExplosion: a scripted explosion is networked, does its
        -- own damage and would be judged by server/damage.lua's explosion
        -- checks. The look is the owner's to tune in game; nothing here
        -- decides who is hurt.
        --
        -- ROUND 6 (owner, 2026-10-07: "missile props never actually spawn, and
        -- the explosions from them should be 3x as big, at least"):
        --   models    tried in order, the first that streams in within loadMs
        --             drawn: since round 7 the Homing Launcher's rocket, then
        --             the RPG's and a vehicle missile as stand-ins if it will
        --             not come
        --   lodDist   how far off each rocket is still drawn -- a weapon's own
        --             is a few meters, so the rockets were culled for their
        --             whole fall (client/terminalfx/airstrike.lua's header).
        --             1,500 m since round 7: past the farthest client that
        --             draws one, fx.strikeDrawM beyond its point plus launchM
        --             out and launchUpM up (about 1,130 m)
        --   blastBaseM  how far the fireball reaches at scale 1, in meters. The
        --             fireball is drawn at fx.strikeReachM / blastBaseM -- 3x
        --             (15 m over 5), was 1x -- so it covers exactly the ground
        --             the server's damage reaches. AN ESTIMATE of the effect's
        --             own size: if the fireball looks smaller or bigger than the
        --             blast that hurts, this is the one number to change.
        --
        -- ROUND 7 (owner, 2026-10-07: "Any chance we could use homing missiles
        -- targeted at the random coords we already have?"): each rocket flies
        -- in like one, onto the server's own point at the server's own time
        -- (client/terminalfx/airstrike.lua's header) -- the trail is the one
        -- the Homing Launcher's ammo draws (weaponhominglauncher.meta's
        -- TrailFx). A look the owner tunes in game:
        --   flightMs  how long each is in the air, launch to impact
        --   launchM, launchUpM  where it is launched from: this far off to the
        --             side of its point, and this high over it
        --   diveUpM   the height over its point it dives from, the last leg
        --   fanDeg    the arc a strike's launches spread over, one bearing
        --             a rocket in the order the server lands them
        --   weaveM    how far each veers off the straight line on the way in,
        --             one side then the other
        rocket = { models = { 'w_lr_homing_rocket', 'w_lr_rpg_rocket', 'w_ex_vehiclemissile_3' },
                   loadMs = 5000, lodDist = 1500,
                   trailAsset = 'core', trail = 'proj_rpg_trail',
                   flightMs = 3000, launchM = 320.0, launchUpM = 160.0, diveUpM = 90.0,
                   fanDeg = 50.0, weaveM = 40.0,
                   blastAsset = 'core', blast = 'exp_grd_vehicle', blastBaseM = 5.0,
                   sound = 'MAIN_EXPLOSION_CHEAP', shake = 'LARGE_EXPLOSION_SHAKE', shakeM = 60.0 },
    },

    -- ═══ WHERE A YUBIKEY COMES FROM (owner, 2026-10-04; crates 2026-10-06) ═══
    --
    -- Both are EXTRA items: rolled on their own stream when the container
    -- opens, after its contents were decided, so today's loot odds do not
    -- move -- and neither does the crate's displayed rarity, which was
    -- decided from those contents (server/yubikey.lua's Y.extraFor). "for now
    -- let's only make it a 50/50 chance in airdrops instead of every single
    -- one".
    --
    -- THE CRATES, ROUND 5: "We should have the same chance of yubikeys in
    -- crates as something rare", and "let's make the Yubikey rare then, not
    -- legendary." So EVERY crate, every tier (never the warmup pad), rolls a
    -- key at the chance the average RARE item is in a crate: each item a crate
    -- can roll at rare (twelve on 2026-10-06: eleven guns and the grenade),
    -- its share of crates holding it, weighted by how many crates of each tier
    -- a match lays out, averaged. 3.08% then. tools/test_yubikey.lua measures
    -- it with the real loot generator over the real map, every run, and fails
    -- when this number is more than a tenth away from it -- so a loot change
    -- that moves the rare items moves this test, not the owner's intent. It
    -- was a small chance in legendary crates alone (legendaryCrateChance,
    -- 0.05) until then.
    sources = {
        airdropChance = 0.5,
        crateChance = 0.031,
    },

    -- ═══ LEAVING A MATCH ALIVE ═══
    --
    -- A LEAVER KEEPS THE KEY since round 6 (owner, 2026-10-07: "Seems the
    -- ownership of an unused Yubikey doesn't actually persist between
    -- matches as it should"). It was true from #396, as proposed on the
    -- issue while the owner had not ruled: a held key dropped where the
    -- leaver stood, like a death. But walking out is how a match is left on
    -- a dev box (Leave Match, `brleave`), and it is not a use -- so his
    -- unused key stayed behind in a match he had left. Only a use and a
    -- death take a key now. True puts the drop back, for both walking out
    -- and disconnecting mid-match; quitting is then not a way to keep a key
    -- you were about to lose.
    --
    -- A DOWNED LEAVER DROPS IT EITHER WAY (round 6's review): Leave Match, a
    -- disconnect, a crash or a kick while DBNO is the fight already lost, so
    -- the key drops where they lay, as their death would drop it. This
    -- switch is for a holder standing or in the air.
    leaveDrops = false,

    -- ═══ THE TERMINALS (owner, 2026-10-06) ═══
    --
    -- "we don't need a script to place the props - I've just done so with a
    -- ymap". THE LAPTOPS ARE THE OWNER'S YMAP'S: prop_laptop_01a in
    -- LaptopTerminals.ymap in the Season 2 drop on S3, streamed with
    -- br_stream_s2 (assets.lock), so nothing in this repository makes one.
    -- These rows are WHERE THOSE PROPS STAND: his numbers, and two moved the
    -- 1.7 m onto their laptops (below). Each terminal's plate, blip, reach and
    -- session check is read from its row (client/yubikey.lua,
    -- server/terminal.lua) and from nothing in the world, so a row moved
    -- without its laptop is a plate beside empty air, and the other way round.
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
        -- paleto PD. ON ITS LAPTOP, as his ymap stands it (2026-10-06, read
        -- from LaptopTerminals.ymap): his row was -429.23584, 5963.753,
        -- 30.50765, 1.7 m from the prop.
        { id = 'paleto_pd',        x = -428.793182, y = 5963.445801, z = 32.129494,  h = 0.0 },
        -- calafia way. ON ITS LAPTOP, the same way: his row was 361.000427,
        -- 4434.68652, 61.91766, 1.7 m from the prop.
        { id = 'calafia_way',      x = 361.20929,   y = 4434.358887, z = 63.535072,  h = 0.0 },
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
    --                { id, choices = { ... }, default, when? }. A choice is a
    --                string; the server takes only a listed one, for a listed
    --                option, and fills a missing one with its default.
    --                `when = { <option> = <choice> }` offers an option only
    --                while another has that choice (round 4: Time & weather's
    --                time OR weather): the app shows it only then, and the
    --                server drops it otherwise and refuses a choice made for
    --                it (BR.Terminal.options).
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
    --   bounty       who a run puts a bounty on, as the card and the filters
    --                say (round 4, owner 2026-10-06: "The cards should show
    --                cost in volts and bounty"): 'runner' (the player who
    --                runs it gets one: Scan), 'target' (it puts one on
    --                another player: Contract), absent for none. The app's
    --                words, never the server's rule: each effect gives its
    --                own bounty.
    --   squadWide    true for a function whose effect reaches the runner's
    --                whole squad (its `_affects` starts "Your squad", or its
    --                marks show on the squad's maps): the app shows "Squads!"
    --                beside its title IN A SQUAD MATCH, whose popover says it
    --                applies to the whole squad (round 4). Presentation only.
    --   spot         true for a function run at a place the player picks on
    --                the big map (round 4, owner 2026-10-06: Storm control and
    --                Supply drop, "pick exactly where"): the confirm box's
    --                "Set location" step (confirm_location), and the run
    --                carries the spot as `at = { x, y }` (BR.Terminal.spot;
    --                the function reads it as `opts.at`).
    --                OR, ROUND 6 (owner, 2026-10-07: 'Any use of "near this
    --                terminal" is like, not useful for this gamemode'),
    --                `{ when = { <option> = <choice>, ... } }`: run at a spot
    --                ONLY while the run's options carry every listed choice
    --                (Power outage: `{ when = { area = 'spot' } }`). The
    --                choices read are the ones the run carries -- defaults
    --                filled in, an option whose own `when` does not hold left
    --                out (BR.Terminal.options) -- and the rule is ONE function
    --                both sides read, BR.TerminalSolve.spotWanted (the app's
    --                model.ts `needsSpot` asks the same of the same choices).
    --                The box shows "Set location" and Run waits for a spot only
    --                then; the run carries `at` only then, and the door refuses
    --                one sent with any other choice (bad_option) as it refuses
    --                one sent to a row that never takes a spot. Each `when`
    --                names an option of the row and one of its choices
    --                (tools/test_terminal.lua); a `spot` of any other shape is
    --                no spot at all (BR.TerminalSolve.spotRule).
    --   fuzz         true for a function run at a spot whose map pick shows
    --                the player's opponents as rough circles near where they
    --                are (round 5, Airstrike): the client says when the pick
    --                starts and ends (TERMINAL_PICK) and the server sends them
    --                (TERMINAL_FUZZ). Never centered on anybody.
    --   quiet        true for a function whose run the lobby is NOT told of
    --                (round 4, owner 2026-10-06: "Field medic should not
    --                notify everyone"): no notice_action, so no
    --                `<id>_description`, and its page leaves out risk_notice.
    --                Opening a terminal with a key still tells the lobby
    --                (notice_access), whatever is run after.
    --   costBy       a price that depends on the options (round 5, Gear Up:
    --                "for a charge of 200 volts the whole team can get them"):
    --                { option = <option id>, choices = { [<choice>] = Volts } }.
    --                A run whose option has a listed choice costs that, any
    --                other `cost` (BR.Terminal.costOf). The figures are held
    --                to 0..200 like `cost`; the app shows the run's own price
    --                on the page and in the confirm box, and the card says
    --                cost_free_or.
    --
    -- AN OPTION MAY ALSO HAVE (round 5):
    --
    --   source       its choices are listed by the server at the moment, not
    --                here: 'mates', this player's standing teammates in a squad
    --                match (the state's `mates`, each a server id as a string
    --                and a name). The door takes any well-formed id for it and
    --                the function says whether it is still one (Gear Up's
    --                gear_no_mate). No `choices`, no default.
    --   dropdown     true to draw it as a dropdown, not radio buttons: a long
    --                list (Gear Up's items) or a list of names.
    --
    -- The server half of a built function is BR.Terminal.FUNCTIONS[id] in
    -- br_core/server/terminal.lua: an optional `refuse` and a `run`.
    --
    -- WHERE EACH CAME FROM: the owner's list (2026-10-04) is the first nine;
    -- Reboot, Ghost and EMP were suggested on #396 and approved for
    -- consideration; Contract and Field medic are the app round's proposals,
    -- for the owner to keep or cut. He cut four on 2026-10-06: Lockdown ("The
    -- player gains nothing from using that"), Storm delay ("We have to keep
    -- the pace of the match"), and two more in round 5. Round 5 added Gear Up,
    -- Vehicle drop and Airstrike.
    functions = {
        { id = 'scan',           category = 'intel',      risk = 'high',   implemented = true, cost = 200,
          bounty = 'runner', squadWide = true },
        { id = 'storm_reveal',   category = 'intel',      risk = 'low',    implemented = true, squadWide = true },
        -- ROUND 4 (owner, 2026-10-06): run at a spot picked on the big map.
        -- SQUAD-WIDE (2026-10-07): the spot is marked on the squad's maps.
        { id = 'storm_control',  category = 'storm',      risk = 'medium', implemented = true, cost = 150,
          spot = true, squadWide = true },
        -- SQUAD-ONLY (round 2): it hides teammates' markers from every other
        -- squad, and outside a squad match nobody has a teammate to hide.
        -- LIVE SINCE WAVE C (2026-10-06): server/terminalfx/comms_blackout.lua,
        -- the one predicate the squad beacon asks before it sends positions.
        { id = 'comms_blackout', category = 'disruption', risk = 'medium', implemented = true,
          squadOnly = true,
          options = { { id = 'duration', choices = { '60', '120', '180' }, default = '60' } } },  -- seconds
        -- THE OWNER'S RULE FOR WHOEVER BUILDS IT (2026-10-05, round 2):
        -- "thunderstorm cannot be a pickable weather. Make sure the storm will
        -- still storm when outside the circle too - whatever weather they set
        -- is only set while inside the storm." So there is no 'thunder'
        -- choice, and the chosen weather applies ONLY to players inside the
        -- circle: outside it the storm's own weather (br_core/client/storm.lua,
        -- BR.World.want('storm', ...)) always wins, whatever was picked here.
        --
        -- AND ROUND 4 (owner, 2026-10-06): "either time or weather to be set.
        -- Not both", "any weather the game engine allows, except rain and
        -- thunder", for "the remainder of the match". So `change` picks which,
        -- and only that one's own option applies (`when`); no duration.
        { id = 'time_weather',   category = 'disruption', risk = 'low',    implemented = true,
          options = {
              { id = 'change', choices = { 'time', 'weather' }, default = 'time' },
              { id = 'time', when = { change = 'time' },
                choices = { 'day', 'dusk', 'night' }, default = 'night' },
              { id = 'weather', when = { change = 'weather' },
                choices = { 'sunny', 'clear', 'clouds', 'smog', 'overcast', 'fog',
                            'xmas', 'snowlight', 'snow', 'blizzard' }, default = 'clear' },
          } },
        -- ROUND 6 (owner, 2026-10-07): no "around this terminal" -- the area's
        -- first choice is 1 km around a spot the player picks on the big map
        -- in the confirm box, so the row is run at a spot only while that is
        -- the area chosen (`spot.when`). server/terminalfx/power_outage.lua
        -- reads it as opts.at.
        { id = 'power_outage',   category = 'disruption', risk = 'low',    implemented = true,
          spot = { when = { area = 'spot' } },
          options = {
              { id = 'area', choices = { 'spot', 'city', 'county' }, default = 'spot' },
              { id = 'duration', choices = { '120', '240' }, default = '120' },
          } },
        { id = 'disarm',         category = 'disruption', risk = 'high',   implemented = true, cost = 200 },
        -- ROUND 5 (owner, 2026-10-06: "yes please put Airstrike in the same
        -- build"): about 10 rockets (homing since round 7, on the same points)
        -- on random points within 40 m of a
        -- spot picked on the big map, after a 10 s warning everyone can see;
        -- the server works out the damage. `fuzz`: while the spot is picked,
        -- opponents show as rough circles (server/terminalfx/airstrike.lua).
        -- 200 Volts: PROPOSED, with the rest of the costs under the owner's
        -- review.
        { id = 'airstrike',      category = 'disruption', risk = 'medium', implemented = true, cost = 200,
          spot = true, fuzz = true },
        { id = 'supply_drop',    category = 'supply',     risk = 'medium', implemented = true,
          spot = true },
        { id = 'max_ammo',       category = 'supply',     risk = 'low',    implemented = true, squadWide = true },
        -- ROUND 5 (owner, 2026-10-06, his name for it): any item or weapon
        -- but a heavy sniper or a machine gun, from a dropdown, to the runner,
        -- one standing teammate, or -- for 200 Volts -- the whole squad. The
        -- item's choices are filled in below from the weapons and loot
        -- configs (`gearUp`); the teammate's are listed by the server
        -- (`source`). A consumable or throwable comes at a full stack up to
        -- its carryMax. server/terminalfx/gear_up.lua.
        { id = 'gear_up',        category = 'supply',     risk = 'low',    implemented = true,
          costBy = { option = 'who', choices = { squad = 200 } },
          options = {
              { id = 'item', choices = {}, default = 'pistol', dropdown = true },
              { id = 'who', choices = { 'self', 'mate', 'squad' }, default = 'self' },
              { id = 'mate', when = { who = 'mate' }, source = 'mates', dropdown = true },
          } },
        -- ROUND 5 (owner, 2026-10-06: "Kuruma is good!"): an armored Kuruma,
        -- never an armed vehicle, by parachute within 40 m of the runner -- or,
        -- in a squad match, of a standing teammate picked from a dropdown --
        -- with a blip for the squad until one of them gets in. No map pick.
        -- 100 Volts: PROPOSED, with the rest of the costs under the owner's
        -- review. server/terminalfx/vehicle_drop.lua.
        { id = 'vehicle_drop',   category = 'supply',     risk = 'medium', implemented = true, cost = 100,
          squadWide = true,
          options = {
              { id = 'to', choices = { 'self', 'mate' }, default = 'self' },
              { id = 'mate', when = { to = 'mate' }, source = 'mates', dropdown = true },
          } },
        -- SQUAD-ONLY (round 2): it brings back squadmates. LIVE SINCE WAVE C
        -- (2026-10-06): server/terminalfx/reboot.lua, through the revive key's
        -- own return (BR.ReviveKey.bringBackAt).
        -- ROUND 6 (owner, 2026-10-07: "Any use of 'near this terminal' is like,
        -- not useful for this gamemode"): they come back by parachute over the
        -- runner, or over a standing teammate picked from a dropdown -- Vehicle
        -- drop's two options, to the letter. It was over this terminal.
        { id = 'reboot',         category = 'squad',      risk = 'medium', implemented = true, cost = 150,
          squadOnly = true, squadWide = true,
          options = {
              { id = 'to', choices = { 'self', 'mate' }, default = 'self' },
              { id = 'mate', when = { to = 'mate' }, source = 'mates', dropdown = true },
          } },
        -- DISRUPTION ON ITS OWN (round 2): alone, it still hides the player
        -- from other players' Scan and bounty markers -- what Comms
        -- blackout, filed under disruption, does to every other squad's
        -- teammate markers.
        { id = 'ghost',          category = 'squad',      risk = 'low',    implemented = true,
          soloCategory = 'disruption', squadWide = true,
          options = { { id = 'duration', choices = { '120', '240' }, default = '120' } } },  -- seconds
        -- LIVE SINCE WAVE C (2026-10-06); ROUND 4 (the same day): every
        -- vehicle in the match, for 3 minutes, except while the runner's squad
        -- drives it -- no options. server/terminalfx/emp.lua keeps the fact,
        -- and each client/terminalfx/emp.lua holds the car its player drives.
        { id = 'emp',            category = 'disruption', risk = 'medium', implemented = true },
        { id = 'contract',       category = 'disruption', risk = 'medium', implemented = true, bounty = 'target' },
        -- ROUND 4 (owner, 2026-10-06): heals the squad, drains everyone else
        -- at 50 health or more by 20, and tells the lobby nothing (`quiet`).
        { id = 'field_medic',    category = 'supply',     risk = 'low',    implemented = true, squadWide = true,
          quiet = true },
    },

    -- The categories, in the order the side navigation lists them.
    categories = { 'intel', 'storm', 'disruption', 'supply', 'squad' },

    -- ═══ THE BUILT EFFECTS' NUMBERS ═══
    fx = {
        -- ── wave B (2026-10-06): Storm control, Time & weather, Power
        --    outage. An option's choices are the registry row's own numbers
        --    (the durations), read as numbers where they are used;
        --    everything else is here. ──

        -- How often the server checks whether a wave B effect has run out, or
        -- its match has ended or left Season 2, and ends it (Time & weather,
        -- Power outage): one pass a second.
        worldCheckMs = 1000,

        -- Time & weather: the time of day each choice sets, as hour and
        -- minute. The clock then RUNS from there at the match's own rate
        -- (#394's slow clock: an hour of game time every five minutes) for
        -- the rest of the match, whose own running clock comes back for the
        -- end screen.
        skyTime = {
            day   = { 12, 0 },
            dusk  = { 19, 30 },
            night = { 0, 0 },
        },
        -- The engine weather each choice names (round 4, owner, 2026-10-06:
        -- "any weather the game engine allows, except rain and thunder since
        -- those are reserved for the storm only"). Of the fifteen the engine
        -- has (br_lib/shared/world.lua's WEATHERS), FIVE ARE NOT OFFERED, each
        -- because it rains:
        --   RAIN, THUNDER  the owner's two, the storm's
        --   CLEARING       light rain: the engine's weather 8, which alt:V's
        --                  weather reference and the menus that set weather by
        --                  index name "Light rain" (rageOS's admin commands:
        --                  "Light rain (Clearing)")
        --   NEUTRAL        weather 9, "Smoggy light rain" in the same places
        --                  ("Smoggy light rain (Neutral)")
        --   HALLOWEEN      rains: the Cfx.re thread on keeping it on ("Permanent
        --                  Halloween") asks how to stop its rain
        -- A choice is the engine's own weather by its own name, the festive
        -- months included: "clear" is CLEAR, not the match's `base` sky.
        -- server/terminalfx/time_weather.lua refuses any name here that is not
        -- an engine weather, or is RAIN or THUNDER, whatever this table says.
        skyWeather = {
            sunny     = 'EXTRASUNNY',
            clear     = 'CLEAR',
            clouds    = 'CLOUDS',
            smog      = 'SMOG',
            overcast  = 'OVERCAST',
            fog       = 'FOGGY',
            xmas      = 'XMAS',
            snowlight = 'SNOWLIGHT',
            snow      = 'SNOW',
            blizzard  = 'BLIZZARD',
        },
        -- Seconds a client blends into the chosen weather as its view crosses
        -- into the circle -- the storm's own sky blend (config/storm.lua's
        -- weather.blendSec), so walking in looks like a storm exit does.
        skyBlendSec = 5.0,

        -- Power outage: how far "Around a spot you pick" reaches from the
        -- spot, in meters (round 6; it was around this terminal). The page
        -- says it (power_outage_opt_area_spot_desc, "within 1 km"), and
        -- tools/test_terminalworld.lua holds the two together. "Los Santos" and
        -- "Blaine County" are the storm's own city line (#381).
        outageRadiusM = 1000.0,

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
        --    own numbers (Ghost's seconds), read as numbers where they are
        --    used; everything else is here. ──

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
        -- How often the server checks whether a timed effect has run out
        -- (Ghost) and ends it, and pushes the persistent notices: one pass a
        -- second.
        endCheckMs = 1000,
        -- (Contract's bounty is bountyMs, the owner's ten, since round 4: "The
        -- contract bounty should last 10 minutes".)
        -- Field medic's drain (round 4, owner 2026-10-06: "remove 20 health
        -- from everyone else in the match who has at least 50 health"): how
        -- much it takes, and the least a standing player outside the squad
        -- must have to lose it. Display units (the bar's 0..100); the page
        -- says both (field_medic_what), and tools/test_terminalfx.lua holds
        -- them together.
        medicDrainHp = 20,
        medicDrainFromHp = 50,

        -- ── wave C (2026-10-06), and round 4 the same day ──

        -- EMP (round 4, owner: "This should last for 3 minutes"): how long
        -- every driver outside the runner's squad stalls whatever they drive.
        -- The page says it (emp_what, emp_duration), and
        -- tools/test_terminalfx.lua holds the two together.
        empMs = 3 * 60 * 1000,
        -- AND NPC TRAFFIC STOPS (round 7, owner: "We should probably use speed
        -- zones for this and set it to 0."): while any EMP lasts, every
        -- client in the match lays road speed zones at 0 over the play area
        -- (client/terminalfx/emp.lua's header has the research). A grid over
        -- the surveyed boundary's box widened by marginM, in cells of at most
        -- cellM, one zone of radiusM per cell, centered at height z: the
        -- farthest point of a cell is half its diagonal away (1,768 m at
        -- 2,500), and a road 500 m above or below z still sits inside 2,000 m
        -- -- so every road is covered whether the game measures the zone as a
        -- sphere or a circle. 20 zones on the 2026-10 boundary.
        -- tools/test_terminalfx.lua holds the cover to every point.
        empTraffic = { cellM = 2500.0, radiusM = 2000.0, z = 300.0, marginM = 500.0 },

        -- ── round 5 (2026-10-06): Vehicle drop ──
        --
        -- The car: an armored Kuruma ("Kuruma is good!"), built by
        -- BR.Vehicles.spawnOwned, so the vehicle rules' own ruling admits it
        -- (config/vehicles.lua refuses every armed model) and the fuel ledger
        -- takes it the moment somebody in the match sits in it.
        dropModel = 'kuruma2',
        -- "within 40m of them": the page says it (vehicle_drop_what), and
        -- tools/test_terminalstrike.lua holds the two together. The client of
        -- the player it is for looks for a road node, then flat open ground,
        -- inside this -- never nearer than dropMinM to them -- and the server
        -- takes its answer only within dropRadiusM + dropSlackM of its own
        -- 4 Hz sample of them (the sample may be a step behind), within
        -- dropRiseM of their height, at least dropClearM from every player in
        -- the match, and inside the play area.
        dropRadiusM = 40.0,
        dropMinM = 6.0,
        dropSlackM = 6.0,
        dropRiseM = 25.0,
        dropClearM = 4.0,
        -- How often that client sends the best spot it has while the run
        -- loads (the server keeps the last good one), and for how long at
        -- most.
        dropAskMs = 1000,
        dropAskForMs = 8000,
        -- The descent: from dropAltM over the spot to the ground in
        -- dropFallMs, on the airdrop's own fall curve (BR.AirdropFallen,
        -- with BR.Config.Airdrop's flare at the bottom), drawn by every
        -- client within dropDrawM of it.
        dropAltM = 120.0,
        dropFallMs = 9000,
        dropDrawM = 600.0,

        -- ── round 5 (2026-10-06): Airstrike ──
        --
        -- The strike (the owner's "~10 s warning", "about 10 unguided
        -- rockets ... onto random points within ~40 m over a few seconds"): the
        -- warning from the run's end to the first rocket, the rockets, their
        -- spread on the ground and in time. The page says each one
        -- (airstrike_what), and tools/test_terminalstrike.lua holds them
        -- together.
        strikeWarnMs = 10000,
        strikeRockets = 10,
        strikeRadiusM = 40.0,
        strikeSpreadMs = 4000,
        -- THE DAMAGE, THE SERVER'S (PROPOSED): each rocket deals strikeDamage
        -- (display units, armor first) to every player within strikeFullM of
        -- where it lands, falling off in a straight line to nothing at
        -- strikeReachM -- a lethal core and the RPG's own 12 m blast, a bit
        -- wider. Measured on the ground (x, y): the server cannot see roofs, so
        -- a rocket hurts whoever is within reach on the map, indoors or up a
        -- tower. Vehicles: within strikeWreckM, wrecked; out to strikeReachM,
        -- strikeVehicleDamage engine and body points falling off the same way.
        --
        -- ROUND 6 (owner, 2026-10-07: the explosions "should be 3x as big, at
        -- least"): THE BLAST A PLAYER SEES IS THE BLAST THAT HURTS. The
        -- fireball is drawn 3x its old size, out to strikeReachM (15 m; the
        -- client sizes it off this number, art.rocket.blastBaseM), and the
        -- damage reaches exactly that far -- so nobody outside the fireball is
        -- hurt and nobody inside it is spared. It was a 1x fireball (about
        -- 5 m) over a 14 m reach. The lethal core is the old fireball's own
        -- 5 m (was 4), and so is the wreck radius.
        strikeDamage = 150.0,
        strikeFullM = 5.0,
        strikeReachM = 15.0,
        strikeWreckM = 5.0,
        strikeVehicleDamage = 1000.0,
        -- How long the circle stays on the map after the last rocket, and how
        -- far off a client draws the rockets and the flare.
        strikeLingerMs = 2000,
        strikeDrawM = 800.0,
        -- THE ROUGH CIRCLES of its map pick: each opponent inside a circle of
        -- fuzzRadiusM whose center sits fuzzMinM..fuzzMaxM from them (spread
        -- evenly over that ring's area), fixed for the match per runner and
        -- opponent so picking again tells nothing more, and moved with them
        -- every fuzzPingMs while the pick lasts -- fuzzMaxMs at most.
        fuzzRadiusM = 100.0,
        fuzzMinM = 25.0,
        fuzzMaxM = 85.0,
        fuzzPingMs = 2000,
        fuzzMaxMs = 120000,
    },

    -- ═══ GEAR UP'S LIST (round 5, owner 2026-10-06) ═══
    --
    -- "any inventory item or weapon which is not a heavy sniper or machine
    -- gun." THE LIST IS EVERY ITEM THE WEAPONS AND LOOT CONFIGS DEFINE, built
    -- below as this file loads (after config/weapons.lua and config/loot.lua,
    -- as br_core's manifest has it), in their order: the guns
    -- (BR.Config.Weapons), the airdrop shelf (AirdropWeapons), melee,
    -- throwables, then the consumables and the CPR kit. LEFT OUT:
    --
    --   excludeClasses  every gun of these `class`es (config/weapons.lua):
    --                   'mg', the machine guns -- the MG, the Gusenberg
    --                   Sweeper, the Combat MG and its Mk II -- and the
    --                   minigun, which is filed and fed with them
    --   excludeWeapons  these ids: the Heavy Sniper, by its own name. The
    --                   other three scoped rifles (Marksman Rifle, Sniper
    --                   Rifle, Marksman Mk II) are on the list
    --
    -- AND NEVER ON IT, BY CONSTRUCTION (nothing below reads them): ammo (a
    -- pool, not a slot -- a weapon brings its spare magazine, and Max ammo is
    -- its own tool), the Yubikey and the revive key (owned, never carried),
    -- fists, and the shop's car tokens (config/shop.lua's, not the loot's).
    gearUp = {
        excludeClasses = { 'mg' },
        excludeWeapons = { 'heavysniper' },
    },

    -- The server drops a second run request from one player sooner than this
    -- after the last. A run is one click and the button disables itself while
    -- it waits, so anything faster is not a person.
    runMinIntervalMs = 500,
}

-- ═══ GEAR UP'S ITEMS, RESOLVED AS THIS FILE LOADS ═══
--
-- The `item` option's choices and each one's line, gear_up_opt_item_<id> --
-- the item's own `label`, the name the inventory and the ground already show
-- -- from the configs `gearUp` names. A config that is not loaded adds
-- nothing (a harness that loads this file alone has an empty list, and the
-- door refuses every item). The default stays the row's when it is listed,
-- or becomes the first item.
do
    local C = BR.Config.Terminals
    local G = C.gearUp or {}
    local skipClass, skipId = {}, {}
    for _, c in ipairs(G.excludeClasses or {}) do skipClass[c] = true end
    for _, id in ipairs(G.excludeWeapons or {}) do skipId[id] = true end
    local row = nil
    for _, r in ipairs(C.functions) do
        if r.id == 'gear_up' then row = r end
    end
    local itemOpt = nil
    for _, o in ipairs(row and row.options or {}) do
        if o.id == 'item' then itemOpt = o end
    end
    if itemOpt then
        local items, seen, tiers = {}, {}, {}
        local function add(def)
            if type(def) ~= 'table' or type(def.id) ~= 'string' or seen[def.id] then return end
            if skipId[def.id] or (def.class ~= nil and skipClass[def.class]) then return end
            if type(def.label) ~= 'string' or def.label == '' then return end
            seen[def.id] = true
            items[#items + 1] = def.id
            C.copy['gear_up_opt_item_' .. def.id] = def.label
            -- ROUND 6 (owner, 2026-10-07: "add it's rarity with the colored
            -- font. Sorted by most rare at the top"): the item's own rarity,
            -- the one the stack Gear Up hands over carries (T.gearStack).
            if BR.RarityInfo and BR.RarityInfo[def.rarity] then tiers[def.id] = def.rarity end
        end
        local K = BR.Config
        for _, list in ipairs({ K.Weapons, K.AirdropWeapons, K.Melee, K.Throwables, K.Consumables }) do
            for _, def in ipairs(list or {}) do add(def) end
        end
        add(K.CprKit)
        itemOpt.choices = items
        itemOpt.rarity = tiers
        local listed = false
        for _, id in ipairs(items) do
            if id == itemOpt.default then listed = true end
        end
        if not listed then itemOpt.default = items[1] end
    end

    -- THE RARITIES' NAMES (round 6, Gear Up's item list): rarity_<key>, the
    -- names BR.RarityInfo gives them -- the inventory's and the market's own
    -- words for them -- so the app says them through its speaker like every
    -- other line. Their colors ride in the catalog (br_core/client/terminal.lua).
    for _, info in pairs(BR.RarityInfo or {}) do
        if type(info) == 'table' and type(info.key) == 'string' and type(info.label) == 'string' then
            C.copy['rarity_' .. info.key] = info.label
        end
    end
end
