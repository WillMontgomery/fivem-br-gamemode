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
--              that round's report.
--   [COPY: ...] still a placeholder, outside the app's scope.
--
-- A LINE WITH '\n' IN IT IS A LIST: the app draws one paragraph or bullet per
-- piece. `{name}`, `{value}`, `{count}`, `{stage}`, `{stages}` and `{online}`
-- / `{total}` are filled by the app; `{playername}` and `{description}` by the
-- server (BR.TerminalSolve.line), only in the lobby's notices.
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
        -- toast if the player holds interact anyway, and the app's reason.
        offline = 'This terminal is outside the storm and offline.',
        -- [COPY] A toast to a holder trying to pick up a second Yubikey.
        already_holding = '[COPY: pickup refused -- you already hold a Yubikey]',
        -- WRITTEN. A holder whose squad has already used its one key this
        -- match: the world plate's hint and the app's reason.
        squad_used = 'Your squad already used its terminal this match.',
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
        -- [COPY] The title on a terminal's world plate, and its blip's name.
        terminal_label = '[COPY: terminal plate -- title]',
        -- [COPY] The plate's hint when this player can use the terminal now.
        terminal_use = '[COPY: terminal plate -- hold to use]',

        -- ── the desktop (cuchi_computer) -- at the terminal. WRITTEN ─────────

        -- Under the boot spinner, for the quarter second the desktop starts.
        shell_boot = 'Starting up...',
        -- Under the terminal app's desktop icon.
        desktop_icon = 'Blitz Terminal',
        -- The browser's one tab: the app's name, beside its icon.
        window_title = 'Blitz Terminal',

        -- ── the app's frame: the browser and the top bar. WRITTEN ────────────

        -- The app's name: the top bar's title, the side navigation's header,
        -- the first breadcrumb and the login screen's heading.
        app_title = 'Blitz Terminal',
        -- The address bar: the fictional site the pages live on, and each
        -- page's path segment. A function's own segment is its id.
        address_host = 'https://terminal.blitz',
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

        -- ── the side navigation and the breadcrumbs. WRITTEN ─────────────────

        nav_functions = 'Functions',
        nav_howto = 'How to',
        nav_categories = 'Categories',

        -- ── the functions page: the match panel. WRITTEN ─────────────────────
        --
        -- The details panel over the cards, refreshed by the server about once
        -- a second while the computer is open.

        match_heading = 'Match',
        field_match = 'Match ID',
        field_mode = 'Mode',
        field_phase = 'Phase',
        field_time = 'Match time',
        field_storm = 'Storm stage',
        field_sweep = 'Next sweep',
        field_players = 'Players left',
        field_squads = 'Squads left',
        field_squad = 'Your squad',
        field_key = 'Yubikey',
        field_squad_key = "Squad's terminal use",
        field_terminals = 'Terminals online',
        field_bounty = 'Active bounty',
        mode_solo = 'Solo',
        mode_squad = 'Squads',
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
        status_not_here = 'Not here',
        status_offline = 'Offline',
        -- How much a function exposes the player who runs it.
        risk_low = 'Low risk',
        risk_medium = 'Medium risk',
        risk_high = 'High risk',
        category_intel = 'Intel',
        category_storm = 'Storm',
        category_disruption = 'Disruption',
        category_supply = 'Supply',
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
        -- Every function's cost, the same for all.
        cost_line = "Your Yubikey and your squad's one terminal use this match",
        -- The first risk on every function's page: notice_action reaches the
        -- whole match whatever was run.
        risk_notice = 'Everyone in the match is told your name and what you ran.',
        -- The button, and the box that asks before it spends anything.
        run = 'Run',
        confirm_title = 'Run {name}?',
        confirm_body = "This uses your Yubikey and your squad's terminal use for this match. It can't be undone.",
        confirm_yes = 'Run',
        confirm_no = 'Cancel',

        -- ── why a function cannot run. WRITTEN, beside no_key, offline and
        --    squad_used above ──────────────────────────────────────────────────

        -- A function whose effect is not built yet: listed, described, never run.
        fn_offline = 'This function is offline.',
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
        -- Supply drop: another airdrop is waiting for a player or falling.
        drop_busy = 'Another airdrop is already on its way.',

        -- ── the how-to page. WRITTEN. The one page allowed to talk strategy,
        --    in general terms; a function's own page never says how it helps ──

        howto_title = 'How to use the terminal',
        howto_key_title = 'Getting a Yubikey',
        howto_key_body = "Airdrops have a 50/50 chance of carrying a Yubikey, and legendary crates have a small chance.\nYou can hold one Yubikey at a time. It doesn't take an inventory slot, and its icon shows on your HUD.\nIf you're eliminated, your Yubikey drops where you fell, and anyone can pick it up.\nA Yubikey you don't use stays with you into your next match.",
        howto_terminal_title = 'Using a terminal',
        howto_terminal_body = "While you hold a Yubikey, terminals inside the storm show on your map as laptops.\nWalk up to one and hold interact to open it.\nA terminal outside the storm is offline and won't open.\nPick a function, read its page, choose its options and press Run.",
        howto_rules_title = 'One use per squad',
        howto_rules_body = "Each squad gets one terminal use per match. A solo player is a squad of one.\nRunning a function uses your Yubikey and your squad's use. A Yubikey is gone after one use.\nIf a squadmate already ran a function this match, your Yubikey stays with you for a later match.\nA function that can't run uses nothing.",
        howto_notices_title = 'What everyone is told',
        howto_notices_body = "When you open a terminal with a Yubikey, everyone in the match is told your name.\nWhen you run a function, everyone is told your name and what you ran.\nSome functions tell more. Each function's page lists who is told.",
        howto_tips_title = 'Tips',
        howto_tips_body = "Read a function's risks before you run it.\nOpening a terminal announces you to the whole match. Clear the area first.\nA terminal near the storm's edge can go offline while you read. Pick one well inside the circle.\nTalk to your squad before you run anything. You only get one use between you.\nIntel shows the most while many squads are left. Supply matters most when your squad is low on gear.\nStorm functions change where the last fight happens. Think about where your squad will be.\nA bounty puts you on every map for 10 minutes. Have a plan to survive it first.",

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
        -- listed id missing any of them. ALL WRITTEN.

        -- Scan (owner's; LIVE)
        scan_name = 'Scan',
        scan_summary = "Shows every opponent on your squad's maps for the rest of the match.",
        scan_what = "Every opponent still in the match appears on the maps of everyone in your squad.\nThe marks update every 2 seconds until the match ends.\nThe player who runs it gets a bounty for 10 minutes.",
        scan_duration = 'Rest of the match. The bounty lasts 10 minutes.',
        scan_affects = 'Your squad',
        scan_notified = 'Everyone in the match, and your squad',
        scan_risks = "You get a bounty. Everyone in the match is told your name.\nFor 10 minutes your position shows on every player's map.\nThe bounty ends early only if you're eliminated.",
        scan_done = 'Scan is running. You have a bounty for the next 10 minutes.',
        scan_description = 'Scan. Their squad sees every opponent for the rest of the match.',
        -- The opponents' and the bounty's names in the pause map's legend.
        scan_blip = 'Opponent',
        bounty_blip = 'Bounty',

        -- Storm reveal (owner's; LIVE)
        storm_reveal_name = 'Storm reveal',
        storm_reveal_summary = 'Shows your squad where the storm will end this match.',
        storm_reveal_what = "The final circle is marked on the maps of everyone in your squad.\nThe mark stays until the match ends.",
        storm_reveal_duration = 'Rest of the match',
        storm_reveal_affects = 'Your squad',
        storm_reveal_notified = 'Everyone in the match',
        storm_reveal_done = "The final circle is on your squad's maps.",
        storm_reveal_description = 'Storm reveal. Their squad sees where the storm will end.',
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
        time_weather_what = "Sets the time of day and the weather for everyone in the match.\nWhen it ends, the match's own time and weather come back.",
        time_weather_opt_time = 'Time of day',
        time_weather_opt_time_day = 'Day',
        time_weather_opt_time_dusk = 'Dusk',
        time_weather_opt_time_night = 'Night',
        time_weather_opt_weather = 'Weather',
        time_weather_opt_weather_clear = 'Clear',
        time_weather_opt_weather_rain = 'Rain',
        time_weather_opt_weather_fog = 'Fog',
        time_weather_opt_weather_thunder = 'Thunderstorm',
        time_weather_opt_duration = 'Duration',
        time_weather_opt_duration_180 = '3 minutes',
        time_weather_opt_duration_300 = '5 minutes',
        time_weather_duration = '3 or 5 minutes, as chosen',
        time_weather_affects = 'Everyone in the match',
        time_weather_notified = 'Everyone in the match',
        time_weather_risks = 'It changes what your squad can see too.',
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
        power_outage_done = 'The power is out.',
        power_outage_description = 'Power outage. The lights are out.',

        -- Disarm (owner's; offline)
        disarm_name = 'Disarm',
        disarm_summary = "Takes away every player's most powerful weapon.",
        disarm_what = "Every player still in the match loses the most powerful weapon they carry, your squad included.\nMost powerful means the highest rarity, then the most damage.\nThe weapons are gone. They aren't dropped.",
        disarm_duration = 'Instant',
        disarm_affects = 'Every player still in the match, your squad included',
        disarm_notified = 'Everyone in the match',
        disarm_risks = 'Your squad loses its most powerful weapons too.',
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
        max_ammo_what = "Every player in your squad who is still in the fight gets a full reserve for each gun they carry.\nEmpty magazines are loaded too.\nThrowables aren't refilled.",
        max_ammo_duration = 'Instant',
        max_ammo_affects = 'Your squad',
        max_ammo_notified = 'Everyone in the match',
        max_ammo_risks = 'Only guns your squad carries when it runs are filled.',
        max_ammo_done = "Your squad's ammo is full.",
        max_ammo_description = "Max ammo. Their squad's ammo is full.",

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

        -- Ghost (suggested; offline)
        ghost_name = 'Ghost',
        ghost_summary = 'Hides your squad from Scan, Pulse and bounty markers for a while.',
        ghost_what = "Your squad doesn't show up on other squads' Scan or Pulse markers.\nIf one of you has a bounty, the bounty marker is hidden too.\nIt doesn't hide you from anyone who can see you.",
        ghost_opt_duration = 'Duration',
        ghost_opt_duration_120 = '2 minutes',
        ghost_opt_duration_240 = '4 minutes',
        ghost_duration = '2 or 4 minutes, as chosen',
        ghost_affects = 'Your squad',
        ghost_notified = 'Everyone in the match',
        ghost_risks = 'Every squad knows yours went dark, because the notice says so.',
        ghost_done = 'Your squad is hidden.',
        ghost_description = 'Ghost. Their squad is hidden from scans.',

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
        emp_done = 'The EMP went off.',
        emp_description = 'EMP. Vehicles near their terminal have stalled.',

        -- Key finder (suggested; offline)
        key_finder_name = 'Key finder',
        key_finder_summary = 'Shows your squad where other Yubikeys are.',
        key_finder_what = "Marks Yubikeys on your squad's maps.\nThe marks show where the keys were when it ran. They don't follow anyone, and they fade after 2 minutes.",
        key_finder_opt_target = 'Find',
        key_finder_opt_target_ground = 'Keys on the ground',
        key_finder_opt_target_holders = 'Players holding a key',
        key_finder_duration = 'The marks last 2 minutes',
        key_finder_affects = 'Your squad',
        key_finder_notified = 'Everyone in the match',
        key_finder_risks = 'Key holders are warned that keys were located.',
        key_finder_done = "The Yubikeys are on your squad's maps.",
        key_finder_description = 'Key finder. Their squad sees where the Yubikeys are.',

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
        storm_delay_done = 'The storm is delayed.',
        storm_delay_description = 'Storm delay. The storm holds longer before its next sweep.',

        -- Pulse (new; offline)
        pulse_name = 'Pulse',
        pulse_summary = 'Shows every player near this terminal for a short time.',
        pulse_what = "Every player within the radius you choose shows on your squad's maps.\nThe marks follow them for 30 seconds.",
        pulse_opt_radius = 'Radius',
        pulse_opt_radius_250 = '250 meters',
        pulse_opt_radius_500 = '500 meters',
        pulse_duration = '30 seconds',
        pulse_affects = 'Every player in the radius',
        pulse_notified = 'Everyone in the match, and every player it finds',
        pulse_risks = "Every player the pulse finds is told they've been detected.",
        pulse_done = "The pulse is on your squad's maps.",
        pulse_description = 'Pulse. Players near their terminal are on their map.',

        -- Lockdown (new; offline)
        lockdown_name = 'Lockdown',
        lockdown_summary = 'Takes every other terminal offline for a while.',
        lockdown_what = "Every other terminal goes offline for the time you choose.\nNobody can open them.\nThis terminal stays online.",
        lockdown_opt_duration = 'Duration',
        lockdown_opt_duration_180 = '3 minutes',
        lockdown_opt_duration_300 = '5 minutes',
        lockdown_duration = '3 or 5 minutes, as chosen',
        lockdown_affects = 'Every other terminal',
        lockdown_notified = 'Everyone in the match',
        lockdown_risks = "This terminal is the only one left online, and every key holder's map shows it.",
        lockdown_done = 'Every other terminal is offline.',
        lockdown_description = 'Lockdown. Every other terminal is offline.',

        -- Contract (new; offline)
        contract_name = 'Contract',
        contract_summary = 'Puts a bounty on the player with the most eliminations.',
        contract_what = "The player outside your squad with the most eliminations gets a bounty for 5 minutes.\nTheir position shows on every player's map while it lasts.\nA tie goes to the player who got there first.",
        contract_duration = '5 minutes',
        contract_affects = 'One player outside your squad',
        contract_notified = 'Everyone in the match, the target included',
        contract_risks = "The target is told a contract is on them.",
        contract_done = 'The contract is out.',
        contract_description = 'Contract. The top player has a bounty.',

        -- Field medic (new; offline)
        field_medic_name = 'Field medic',
        field_medic_summary = 'Restores full health and armor to everyone in your squad.',
        field_medic_what = "Every player in your squad who is still standing gets full health and full armor.\nDowned players aren't revived.",
        field_medic_duration = 'Instant',
        field_medic_affects = 'Your squad',
        field_medic_notified = 'Everyone in the match',
        field_medic_risks = "Only players standing when it runs are healed.",
        field_medic_done = 'Your squad is patched up.',
        field_medic_description = 'Field medic. Their squad is back to full health.',
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
        -- Scan: each opponent on the scanning squad's maps. Sprite 1 is the
        -- plain dot; colour 1 is red. A placeholder the owner has not picked.
        scan = { sprite = 1, colour = 1, scale = 0.75 },
        -- The bounty, the owner's numbers: blip 58 in colour 3 on everyone's
        -- map, and colour 69 on the bounty's own squad's.
        bounty = { sprite = 58, colour = 3, mateColour = 69, scale = 1.0 },
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
    -- How often the server pushes the open computer its state and the match
    -- panel (TERMINAL_INFO), to that player alone and only while it is open.
    -- The owner asked for "realtime"; the panel's clocks count in seconds.
    infoPushMs = 1000,

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
    --
    -- The server half of a built function is BR.Terminal.FUNCTIONS[id] in
    -- br_core/server/terminal.lua: an optional `refuse` and a `run`.
    --
    -- WHERE EACH CAME FROM: the owner's list (2026-10-04) is the first nine;
    -- Reboot, Ghost, EMP and Key finder were suggested on #396 and approved
    -- for consideration; Storm delay, Pulse, Lockdown, Contract and Field
    -- medic are this round's proposals, for the owner to keep or cut.
    functions = {
        { id = 'scan',           category = 'intel',      risk = 'high',   implemented = true },
        { id = 'storm_reveal',   category = 'intel',      risk = 'low',    implemented = true },
        { id = 'storm_control',  category = 'storm',      risk = 'medium', implemented = false,
          options = { { id = 'zone', choices = { 'near', 'center', 'far' }, default = 'near' } } },
        { id = 'comms_blackout', category = 'disruption', risk = 'medium', implemented = false,
          options = { { id = 'duration', choices = { '60', '120', '180' }, default = '60' } } },
        { id = 'time_weather',   category = 'disruption', risk = 'low',    implemented = false,
          options = {
              { id = 'time', choices = { 'day', 'dusk', 'night' }, default = 'night' },
              { id = 'weather', choices = { 'clear', 'rain', 'fog', 'thunder' }, default = 'clear' },
              { id = 'duration', choices = { '180', '300' }, default = '180' },
          } },
        { id = 'power_outage',   category = 'disruption', risk = 'low',    implemented = false,
          options = {
              { id = 'area', choices = { 'here', 'city', 'county' }, default = 'here' },
              { id = 'duration', choices = { '120', '240' }, default = '120' },
          } },
        { id = 'disarm',         category = 'disruption', risk = 'high',   implemented = false },
        { id = 'supply_drop',    category = 'supply',     risk = 'medium', implemented = true,
          options = { { id = 'site', choices = { 'terminal', 'circle' }, default = 'terminal' } } },
        { id = 'max_ammo',       category = 'supply',     risk = 'low',    implemented = true },
        { id = 'reboot',         category = 'squad',      risk = 'medium', implemented = false },
        { id = 'ghost',          category = 'squad',      risk = 'low',    implemented = false,
          options = { { id = 'duration', choices = { '120', '240' }, default = '120' } } },
        { id = 'emp',            category = 'disruption', risk = 'medium', implemented = false,
          options = {
              { id = 'radius', choices = { '300', '600' }, default = '300' },
              { id = 'duration', choices = { '30', '60' }, default = '30' },
          } },
        { id = 'key_finder',     category = 'intel',      risk = 'low',    implemented = false,
          options = { { id = 'target', choices = { 'ground', 'holders' }, default = 'ground' } } },
        { id = 'storm_delay',    category = 'storm',      risk = 'low',    implemented = false,
          options = { { id = 'delay', choices = { '60', '120' }, default = '60' } } },
        { id = 'pulse',          category = 'intel',      risk = 'medium', implemented = false,
          options = { { id = 'radius', choices = { '250', '500' }, default = '250' } } },
        { id = 'lockdown',       category = 'disruption', risk = 'medium', implemented = false,
          options = { { id = 'duration', choices = { '180', '300' }, default = '180' } } },
        { id = 'contract',       category = 'disruption', risk = 'medium', implemented = false },
        { id = 'field_medic',    category = 'supply',     risk = 'low',    implemented = false },
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
    },

    -- The server drops a second run request from one player sooner than this
    -- after the last. A run is one click and the button disables itself while
    -- it waits, so anything faster is not a person.
    runMinIntervalMs = 500,
}
