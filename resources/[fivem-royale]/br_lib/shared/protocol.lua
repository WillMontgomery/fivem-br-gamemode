-- Network event names and the NUI envelope contract.
--
-- Every event name in the project lives here. Magic strings scattered across
-- files are how client and server quietly stop agreeing with each other.

BR = BR or {}

--- Server -> client, and client -> server, net event names.
--- Prefixed so they never collide with another resource's events.
BR.Net = {
    -- Handshake / bulk sync
    READY           = 'br:ready',            -- C->S  client finished loading, request snapshot
    SNAPSHOT        = 'br:snapshot',         -- S->C  full roster + match + inventory state

    -- Match lifecycle
    STATE           = 'br:state',            -- S->C  { state, endsAt, meta }
    ROSTER_DELTA    = 'br:roster:delta',     -- S->C  array of roster changes (coalesced)
    DIGEST          = 'br:digest',           -- S->C  { alive, squadsAlive, phase, endsAt }

    -- Lobby / squads
    QUEUE_JOIN      = 'br:queue:join',       -- C->S  { mode }
    QUEUE_LEAVE     = 'br:queue:leave',      -- C->S
    -- C->S { mode }. The player picked a mode tile. Sent at the MOMENT OF
    -- CHOICE rather than only at ready-up, because picking Solo has a
    -- consequence -- it leaves your party -- and a consequence the server
    -- only applies later is one the client has to remember to ask for. It
    -- used to: Lobby.tsx fired a SQUAD_LEAVE off a locally-derived "am I in a
    -- party" boolean, and when that stopped leaving the party there was no
    -- server-side rule to fall back on (user, 2026-08-09).
    MODE_SET        = 'br:mode:set',
    -- Parties are persistent; squads are formed from them per match. The events
    -- are named "squad" for continuity with the UI, but they operate on parties.
    SQUAD_INVITE    = 'br:squad:invite',     -- C->S  { target }
    SQUAD_RESPOND   = 'br:squad:respond',    -- C->S  { accept }
    SQUAD_JOINREQ   = 'br:squad:joinreq',    -- C->S  { leader } -- ask to join their party
    SQUAD_JOINRESP  = 'br:squad:joinresp',   -- C->S  { requester, accept } -- leader's answer
    SQUAD_JOINASK   = 'br:squad:joinask',    -- S->C  { from, name, size, max } -- to the leader
    SQUAD_LEAVE     = 'br:squad:leave',      -- C->S
    SQUAD_KICK      = 'br:squad:kick',       -- C->S  { target }
    SQUAD_UPDATE    = 'br:squad:update',     -- S->C  { id, leader, members }
    SQUAD_INVITED   = 'br:squad:invited',    -- S->C  { partyId, from, name, size, max }
    LOBBY_STATUS    = 'br:lobby:status',     -- S->C  { queued, needed, connected, mode, ids, players, wait }
    SQUAD_RESULT    = 'br:squad:result',     -- S->C  { ok, reason } -- feedback for an invite/kick
    -- S->C one notice for the on-screen stack.
    --   { text, tone, key?, ms?, endsAt?, sticky?, clear? }
    -- `key` makes a notice ADDRESSABLE: a second one with the same key
    -- replaces the first in place rather than stacking or counting. `endsAt`
    -- renders a live countdown inside the row -- one notice with a moving
    -- number, never a message per second. `sticky` outlives its own event and
    -- is removed only by `clear`. See BR.Server.notify.
    NOTIFY          = 'br:notify',
    SQUAD_POS       = 'br:squad:pos',        -- S->C  squadmate positions, SQUAD MEMBERS ONLY (1Hz)
    MATCH_LEAVE     = 'br:match:leave',      -- C->S  abandon the current match, back to the lobby
    TO_LOBBY        = 'br:lobby:return',     -- S->C  respawn at the lobby pad NOW (leave-match flow)
    -- C->S "my screen is genuinely black, you may take my world away now".
    --
    -- THE ONE THING THE SERVER CANNOT SEE. At ENDED the roster sweep to LOBBY
    -- is what freezes the ped, moves the routing bucket (so the car they were
    -- driving stops existing) and stops the storm drawing -- and it used to
    -- fire the instant the match was decided, which is while the verdict slam
    -- is still playing over a live world. The player watched the world be
    -- dismantled and THEN watched it fade out (#124).
    --
    -- The order the sweep needs is: screen black first, teardown second, and
    -- only the CLIENT knows when its own page has finished going black. So it
    -- says so, and the server sweeps that player then. A client that never
    -- says it is swept on a deadline anyway -- see BR.Config.Match.coverWaitMs
    -- -- because a player stuck in a match that will not let go is far worse
    -- than a visible cut.
    MATCH_COVERED   = 'br:match:covered',    -- C->S  (no payload)

    -- Bus / drop
    BUS_ROUTE       = 'br:bus:route',        -- S->C  { sx, sy, ex, ey, alt, tStart, tEnd }
    BUS_SPECTATE    = 'br:bus:spectate',     -- S->C  { matchId, route } -- another match's departing flight, for warmup bystanders
    BUS_JUMP        = 'br:bus:jump',         -- C->S  request to jump
    BUS_JUMP_OK     = 'br:bus:jumpOk',       -- S->C  { x, y, z, heading }
    DROP_LANDED     = 'br:drop:landed',      -- C->S  reached the ground

    -- Storm
    STORM_SYNC      = 'br:storm:sync',       -- S->C  full storm record (also mirrored to GlobalState)
    STORM_DAMAGE    = 'br:storm:damage',     -- S->C  { amount, targetHp }

    -- Player-placed map markers (one per player; squad-visible in squads)
    MARKER_SET      = 'br:marker:set',       -- C->S  { x, y }
    MARKER_CLEAR    = 'br:marker:clear',     -- C->S  remove my marker
    MARKER_SYNC     = 'br:marker:sync',      -- S->C  { op, owner, x, y, colour }

    -- Voice channels. The client cannot work these out for itself: a channel
    -- is derived from the match, and matchId is deliberately NEVER public
    -- (see PUBLIC_FIELDS in server/roster.lua). So the server hands each
    -- player the two numbers and nothing else.
    VOICE_SET       = 'br:voice:set',        -- S->C  { prox, mates, nearbyRange, squadRange }

    -- Loot / inventory
    LOOT_CELL       = 'br:loot:cell',        -- C->S  { cx, cy } subscribe to a grid cell
    LOOT_ADD        = 'br:loot:add',         -- S->C  array of loot entries entering scope
    LOOT_GONE       = 'br:loot:gone',        -- S->C  array of loot ids removed
    LOOT_CLAIM      = 'br:loot:claim',       -- C->S  { id }
    -- The repair round-trip. Only a CLIENT can ground-probe or read water
    -- height, so a client that finds an entry floating in the sea or buried
    -- under the map sends back the corrected position it computed. The server
    -- bounds how far it may move (see server/loot.lua) -- this is a
    -- suggestion, not an instruction.
    LOOT_FIX        = 'br:loot:fix',         -- C->S  { id, x, y, z }
    -- C->S { item, x, y, z }. An NPC the reporter killed dropped a weapon.
    -- Client-observed by necessity: ambient peds are client-side and the
    -- server has never heard of them. Rate-limited and range-checked at the
    -- far end -- see the handler for why that is enough.
    NPC_DROP        = 'br:loot:npcdrop',
    -- DEV ONLY, refused unless the server is in dev mode. Exists so a crate
    -- can be spawned from the F8 console standing in front of you, rather
    -- than from the server console where you cannot see it land.
    LOOT_DEV        = 'br:loot:dev',         -- C->S  { item?, x, y, z }
    INV_SET         = 'br:inv:set',          -- S->C  authoritative inventory mirror
    INV_SWAP        = 'br:inv:swap',         -- C->S  { from, to }
    INV_DROP        = 'br:inv:drop',         -- C->S  { slot }
    INV_USE         = 'br:inv:use',          -- C->S  { slot }
    INV_SELECT      = 'br:inv:select',       -- C->S  { slot }
    -- The server owns the inventory but cannot write a ped: it decides the
    -- consumable landed and TELLS the client to apply it, exactly as the storm
    -- tells a client to hurt itself. Health/armour arrive in DISPLAY units.
    INV_EFFECT      = 'br:inv:effect',       -- S->C  { health, healthCap, armour, armourCap }
    -- Ammo is the one number only the client can observe before M6's shot
    -- validation exists. Reports are accepted ONLY when they LOWER the stored
    -- value, so the worst a liar can do is disarm themselves.
    INV_AMMO        = 'br:inv:ammo',         -- C->S  { pool = { light = n, ... }, clip, slot }

    -- Combat / DBNO
    -- S->C { hp, armour } in DISPLAY units, an authoritative correction.
    --
    -- DISPLAY rather than engine, unlike HIT_DAMAGE and STORM_DAMAGE, and the
    -- difference is deliberate: those two carry a DELTA to apply, this carries
    -- an ABSOLUTE value to become. BR.ToEngineHp is the converter and
    -- BR.Native.setDisplayHealth is the one call that should ever perform it.
    HEALTH_SYNC     = 'br:health:sync',
    DAMAGE_FEED     = 'br:damage:feed',      -- S->C  { amount, dir, headshot } for hitmarkers
    -- S->C { amount, armourFirst }. The server telling a victim to apply a
    -- validated gunshot to their own ped. Same shape and same reasoning as
    -- STORM_DAMAGE: the server cannot write a ped, so it keeps the ledger and
    -- instructs the client to show it.
    HIT_DAMAGE      = 'br:hit:damage',
    -- S->C { netId, hp }. A shot was REFUSED, so the shooter's local copy of
    -- the victim is wrong -- GTA applied the damage on their machine before
    -- the server ever saw the event, and CancelEvent stops replication, not
    -- that. This tells them to put the ped back.
    HIT_RESYNC      = 'br:hit:resync',
    KILL_FEED       = 'br:kill:feed',        -- S->C  { killer, victim, weapon, headshot }
    -- S->C { downed, bleedEndsAt, byName, reviverName, revivePct }.
    --
    -- The WHOLE downed state, every time, rather than a patch. There are five
    -- fields, they change on events a human causes, and a merge protocol for
    -- that would be more code than the feature -- the same call SETTINGS made.
    --
    -- `bleedEndsAt` is a SERVER timestamp: the interface must compare it
    -- against `Date.now() + clockOffset`, never against Date.now(). The server
    -- clock and the browser clock share no origin.
    DBNO_SET        = 'br:dbno:set',
    REVIVE_START    = 'br:revive:start',     -- C->S  { target }
    REVIVE_STOP     = 'br:revive:stop',      -- C->S
    -- S->C { pct, target, reviverName }. Sent to BOTH parties while a revive
    -- runs: the reviver needs it for their hold ring, and the downed player
    -- needs to know somebody is actually coming for them -- which is the one
    -- piece of information that decides whether they hang on or give up.
    REVIVE_PROGRESS = 'br:revive:progress',
    -- S->C (no payload) "get up, the match is starting" (#144).
    --
    -- A DEAD PED IS THE ONE THING THE SERVER CANNOT PUT RIGHT ON ITS OWN. Every
    -- other correction in this block is a NUMBER -- health, armour, a bleed
    -- clock -- and the roster is where numbers live. Resurrection is not: it is
    -- NetworkResurrectLocalPlayer on the machine that owns the ped, and without
    -- spawnmanager nothing else performs it (client/spawn.lua's own note). So
    -- the roster flip to ALIVE and this event are two halves of one revive, and
    -- the event goes FIRST -- a client left holding a corpse while the server
    -- calls it alive is the state the server-observed death check exists to
    -- eliminate, and it would eliminate them.
    --
    -- No payload: the client already knows where its own body is, and the
    -- server's position sample is a quarter of a second stale.
    REVIVED         = 'br:revive:atstart',

    -- Spectate / end
    SPECTATE_SET    = 'br:spectate:set',     -- S->C  { targetSrc, x, y, z }
    SPECTATE_CYCLE  = 'br:spectate:cycle',   -- C->S  { dir }
    SUMMARY         = 'br:summary',          -- S->C  end-of-match payload

    -- Death. The client reports; the server decides. See server/combat.lua.
    PLAYER_DIED     = 'br:player:died',      -- C->S  { cause, killer? }

    -- The market.
    --
    -- THE CLIENT ASKS; THE SERVER DECIDES; THE SERVER ANSWERS WITH THE WHOLE
    -- STATE. There is no optimistic update anywhere in this path, because the
    -- one thing a storefront must never do is show an item as owned when the
    -- database disagreed. MARKET_STATE is the only thing that ever changes what
    -- the page believes, and it always carries the full picture -- balance,
    -- owned ids, equipped ids -- so a dropped message costs a render, not a
    -- divergence.
    -- What one match actually paid, sent to that player alone once the write
    -- has been computed. SEPARATE FROM SUMMARY because summary is br_core's and
    -- fires at the end of the match, while this comes from br_stats after the
    -- result has been turned into deltas -- and it is the only place the real
    -- numbers exist. The verdict screen used to invent both.
    --
    -- IT CARRIES BOTH ENDS OF THE BAR, not just the award. It used to send the
    -- earned amount and the level landed on, which left the page to work out
    -- where the bar should stop -- and the page got it wrong in three separate
    -- ways at once (#91, #130): it added the award to a total that already
    -- included it, it subtracted the wrong level's span on a level-up and
    -- clamped the result at zero, and it kept the old level's span as the
    -- denominator so the bar could sit past its own end forever. Sending
    -- `into`/`needed` alongside `fromXp`/`fromNeeded` removes the arithmetic
    -- from the client entirely; there is nowhere left for it to be wrong.
    MATCH_EARNED    = 'br:match:earned',     -- S->C  { xp, volts, level, into, needed,
                                             --         fromLevel, fromXp, fromNeeded, levelUp }
    -- The in-game player list and reporting.
    --
    -- THE SERVER FILTERS THE BUCKET; THE CLIENT NEVER LEARNS WHICH ONE. `matchId`
    -- is marked NEVER PUBLIC in roster.lua's PUBLIC_FIELDS, so the list is
    -- resolved server-side and the answer sent -- rather than sending an id and
    -- asking the client to filter on it, which would leak the very field the
    -- projection exists to withhold.
    PLAYERS_ASK     = 'br:players:ask',      -- C->S  (no payload; the server knows who asked)
    PLAYERS_LIST    = 'br:players:list',     -- S->C  { players = { { src, name, state, squadId, left } } }
    -- C->S { targets = { { src, category } }, note? }. NEVER a license: the
    -- client names a server id and the server resolves it, the same rule the
    -- market follows for item ids.
    REPORT_SUBMIT   = 'br:report:submit',
    -- S->C { ok, filed, refused? }. Sent when the incident has actually LANDED,
    -- not when the request was received -- the promise to the player is that an
    -- admin will see it, and that promise is only true once a row exists.
    REPORT_RESULT   = 'br:report:result',

    MARKET_STATE    = 'br:market:state',     -- S->C  { balance, owned, equipped }
    MARKET_BUY      = 'br:market:buy',       -- C->S  { id }
    MARKET_EQUIP    = 'br:market:equip',     -- C->S  { id }

    -- Chat
    CHAT_SEND       = 'br:chat:send',        -- C->S  { channel, text }
    CHAT_MSG        = 'br:chat:msg',         -- S->C  { channel, from, name, text, at }

    -- Clock synchronisation. The storm and bus are interpolated locally from a
    -- record published once, which only works if clients agree on the time.
    CLOCK_PING      = 'br:clock:ping',       -- C->S  { sentAt }
    CLOCK_PONG      = 'br:clock:pong',       -- S->C  { sentAt, serverAt }

    -- Client -> server position report (2 Hz), used for validation and spectate
    POS_REPORT      = 'br:pos',              -- C->S  { x, y, z }

    -- C->S { name }. A display name the player chose, stored in THEIR kvp and
    -- proposed here. Settings are otherwise entirely client-side -- this is
    -- the one preference other people can see, so it is the one the server
    -- gets a say in. Accepted in the lobby only.
    SETTINGS_NAME   = 'br:settings:name',

    -- C->S. Leave the server from our own pause menu.
    --
    -- THE CLIENT CANNOT DO THIS ITSELF: `disconnect` is a restricted console
    -- command and ExecuteCommand gets "Access denied" (user, 2026-08-09). The
    -- server can, with DropPlayer, which is also the more honest place for it
    -- -- leaving is something the server should know about rather than
    -- discover.
    LEAVE_SERVER    = 'br:leave:server',
}

--- Chat channels. `squad` is routed server-side to squad members only -- the
--- client never filters, because a client-side filter is not a privacy boundary.
BR.ChatChannel = {
    GLOBAL = 'global',
    SQUAD  = 'squad',
    SYSTEM = 'system',  -- server-generated: storm warnings, eliminations
}

BR.ChatLimits = {
    maxLength     = 200,
    rateWindowMs  = 10000,
    rateMax       = 8,     -- messages per window before the server starts dropping
    historyKept   = 60,    -- messages the client keeps for the scrollback
}

--- NUI envelope kinds. Lua -> NUI always sends exactly one shape:
---   { t = 'br', v = 1, k = <kind>, d = <payload>, s = <seq> }
--- `s` is monotonic so React can drop stale or out-of-order messages.
BR.Nui = {
    SNAPSHOT  = 'snapshot',  -- full state, sent on load and after a br_ui restart
    STATE     = 'state',     -- match state transition
    HUD       = 'hud',       -- vitals, alive count, kills (10 Hz, deltas)
    SQUAD     = 'squad',
    -- THE PARTY, ALWAYS, alongside whatever the squad channel is carrying.
    -- In a match those are different groups: the squad is who you are
    -- fighting with and is fixed for the round; the party is who you will
    -- still be with next round. One channel could only ever describe one of
    -- them, and mid-match it describes the squad -- which is why party
    -- management had nothing to read.
    PARTY     = 'party',
    -- Who is speaking right now: { talking = {src...}, names = {name...} },
    -- the two arrays in the same order. The squad panel marks the ids; the
    -- bottom-centre indicator prints the names, and it has to name people who
    -- are NOT squadmates -- anyone in proximity can be heard -- so the names
    -- travel with the ids rather than being looked up in the squad payload.
    VOICE     = 'voice',
    INV       = 'inv',
    PROMPT    = 'prompt',    -- world-anchored interaction prompt + progress ring
    FEED      = 'feed',      -- kill feed + damage numbers
    HIT       = 'hit',       -- YOU connected: {amount, headshot, killed, name}
    STORM     = 'storm',     -- phase, radius, endsAt (4 Hz)
    DBNO      = 'dbno',
    SPECTATE  = 'spectate',
    SUMMARY   = 'summary',
    FOCUS     = 'focus',     -- tell the UI which screen owns focus
    TOAST     = 'toast',
    CHAT      = 'chat',      -- one appended message
    SCREEN    = 'screen',    -- resolution + safe zone, so the HUD can lay out
    LOBBY     = 'lobby',     -- queue progress, so waiting has a visible reason
    INVITE    = 'invite',    -- an incoming party invite
    LEAVING   = 'leaving',   -- the voluntary-leave interstitial (black + text)
    -- THE ENGINE'S FRONTEND OWNS THE SCREEN, so our page must not draw.
    --
    -- A scaleform cannot be covered by NUI and NUI cannot be covered by it, so
    -- for as long as GTA's own menu is up, anything we paint is simply sitting
    -- ON TOP of the menu the player was sent to use (owner, 2026-08-16:
    -- "results in the lobby UI overlaying on top of the GTA V settings
    -- screen").
    --
    -- THIS IS A SEPARATE QUESTION FROM FOCUS AND HAS TO BE. Focus decides who
    -- owns the CURSOR; this decides who owns the SCREEN. The lobby is drawn
    -- from match state, not from the focus stack -- deliberately, so a queue
    -- screen is visible before it is clickable -- which means emptying the
    -- focus stack releases the mouse and leaves the lobby painted exactly
    -- where it was. That is the whole bug, and one more focus call could
    -- never have fixed it.
    --
    -- LUA OWNS IT, and the page only mirrors it. The previous attempt had the
    -- PAGE raise a flag before asking Lua to hand over, and the focus
    -- envelopes Lua emits while tearing its own stack down cleared that flag
    -- again a frame later.
    FRONTEND  = 'frontend',  -- { up } -- GTA's menu is on screen; draw nothing
    -- The player's own preferences, read back out of KVP on boot. Sent as a
    -- whole object rather than as deltas: there are a dozen of them, they
    -- change when a human drags a slider, and a merge protocol for that would
    -- be more code than the feature.
    SETTINGS  = 'settings',
    -- The character roster and which one is on. Pushed on ready and after
    -- every successful swap -- the page never assumes an apply worked, since
    -- a model that fails to stream leaves you wearing the old one.
    LOCKER    = 'locker',
    -- LEVEL AND XP. WHERE THE BAR IS, and the only envelope allowed to say so.
    -- Every value on it is evaluated by BR.Xp on the server -- from MARKET_STATE
    -- on connect and after a credit, and from MATCH_EARNED at the end of a
    -- match. The interface renders it and derives nothing from it; the day it
    -- derived a level and a span for itself is #91 and #130.
    PROGRESS  = 'progress',
    -- WHERE THE BAR WAS, so the fill has a start. Separate from PROGRESS
    -- because most progress pushes are not awards -- a reconnect should
    -- restore the bar, not replay a celebration.
    --
    -- IN PRODUCTION THE VERDICT SCREEN RAISES THIS ITSELF, off EARNED, because
    -- it is the only thing that can see whether it is on screen. The one Lua
    -- sender left is the `brxp` preview command. That is deliberate, not
    -- neglect: an award pushed from Lua is an award timed against a screen Lua
    -- cannot observe, which is how it went unseen twice.
    XP        = 'xp',
    MARKET    = 'market',
    -- The player list. Carries the roster projection AND the report state --
    -- how many reports are left this match, and the categories -- because the
    -- panel cannot render its own rules and must not invent them.
    PLAYERS   = 'players',
    -- The answer to a submitted report, so the panel can say what happened
    -- rather than closing hopefully.
    REPORT    = 'report',
    -- What the match just paid. Separate from XP because it carries Volts too,
    -- and because the verdict screen owns WHEN it is shown -- Lua cannot see
    -- that screen and timing an award against it from here has failed twice.
    EARNED    = 'earned',
    -- Every RegisterKeyMapping command we own, with the key currently bound
    -- to it, so the settings screen can list and rebind them without sending
    -- the player into GTA's own menus to find them.
    KEYBINDS  = 'keybinds',
}

--- NUI -> Lua callback names, namespaced. Every one of these MUST resolve on
--- every path including errors; a missing resolve hangs the CEF promise forever.
BR.NuiCb = {
    QUEUE        = 'br/lobby/queue',
    QUEUE_LEAVE  = 'br/lobby/leave',
    MODE_SET     = 'br/lobby/mode',
    SQUAD_INVITE = 'br/squad/invite',
    SQUAD_RESPOND = 'br/squad/respond',
    SQUAD_JOINREQ = 'br/squad/joinreq',
    SQUAD_JOINRESP = 'br/squad/joinresp',
    SQUAD_KICK   = 'br/squad/kick',
    SQUAD_LEAVE  = 'br/squad/leave',
    INV_SWAP     = 'br/inv/swap',
    INV_DROP     = 'br/inv/drop',
    INV_USE      = 'br/inv/use',
    INV_SELECT   = 'br/inv/select',
    CLOSE        = 'br/close',
    CHAT_SEND    = 'br/chat/send',
    CHAT_FOCUS   = 'br/chat/focus',  -- UI tells Lua the input opened/closed
    PAUSE        = 'br/pause',       -- ESC in the lobby: open GTA's pause menu
    -- Menu audio. React knows a button was pressed; Lua owns the cue table and
    -- the throttle, so the UI names a CUE ('ui.select') and never a sound set.
    -- Native rather than an <audio> tag because engine audio ducks against
    -- gunfire and a browser tag does not.
    SFX          = 'br/sfx',
    ERROR        = 'br/err',  -- CEF exception sink; without this a crash is a blank screen
    ENV          = 'br/ui/env',  -- CEF capability report, printed at startup
    -- Settings. SAVE carries the whole object; Lua writes it to KVP and echoes
    -- it back, so the page never has to believe its own optimistic copy.
    -- FOCUS is separate because the settings screen can be opened from a
    -- keybind mid-match, where nothing else is holding the cursor.
    SETTINGS_SAVE  = 'br/settings/save',
    SETTINGS_FOCUS = 'br/settings/focus',
    -- Open GTA's own pause menu on the key bindings page. FiveM keybinds are
    -- RegisterKeyMapping bindings and they are rebound THERE -- a rebinder in
    -- CEF would be a second, disagreeing source of truth.
    KEYBINDS     = 'br/settings/keybinds',
    -- The locker. PICK swaps the model; SPIN turns the ped in place while the
    -- camera holds still. Both forwarded to br_core, which owns the ped.
    LOCKER_PICK  = 'br/locker/pick',
    LOCKER_SPIN  = 'br/locker/spin',
    LOCKER_FOCUS = 'br/locker/focus',
    MARKET_FOCUS = 'br/market/focus',
    MARKET_BUY   = 'br/market/buy',
    -- EQUIP IS A SEPARATE VERB FROM BUY, and not a flag on it. Buying is a
    -- debit and can be refused for reasons equipping never has; equipping is
    -- free, idempotent, and happens far more often. Folding them into one
    -- callback would mean every equip carried a price the server has to ignore.
    MARKET_EQUIP = 'br/market/equip',
    -- The player list. FOCUS follows the same push/pop discipline every other
    -- overlay uses; SUBMIT carries the selected targets and their categories.
    PLAYERS_FOCUS = 'br/players/focus',
    REPORT_SUBMIT = 'br/report/submit',
    -- The pause menu. FOCUS opens and closes it; ACTION carries the one verb
    -- the player picked ('lobby' | 'squad' | 'server' | 'quit').
    PAUSE_FOCUS  = 'br/pause/focus',
    -- The manual, which is a page on the lobby AND a tab in the pause menu.
    HELP_FOCUS   = 'br/help/focus',
    -- Opens GTA's own pause menu so the player can reach the settings no
    -- script can write: microphone, push-to-talk, output device.
    VOICE_SETTINGS = 'br/voice/settings',
    -- The same handover, asked for by somebody who wants GRAPHICS rather than
    -- a microphone: resolution, quality, FOV. Identical mechanically, and a
    -- separate name because the only route to the engine's settings used to be
    -- a button reading "Microphone & push-to-talk" -- which is not a place any
    -- player looks for their resolution (owner, 2026-08-16: "no clear way to
    -- reach GTA's own graphics/display settings").
    GAME_SETTINGS  = 'br/game/settings',
    -- The interface saying "an animation is playing, do not take the screen
    -- away yet". The post-match XP award is the only thing that raises it.
    XP_BUSY      = 'br/xp/busy',
    -- THE OTHER HALF OF EVERY TRANSITION: the page saying "I am now fully
    -- black" (or "I am not any more").
    --
    -- Lua raises a cover -- the curtain for a trip, the verdict backdrop at
    -- the end of a match -- and then has to change the world underneath it.
    -- Until now it fired the message and moved on, so the change and the
    -- cover were two independent timers and the change routinely won: the
    -- lobby vanished and the HUD cut in BEFORE the fade that exists to hide
    -- exactly that (#124). Tuning the timers has been tried and does not
    -- hold, because they are measuring different clocks -- one is a Lua
    -- Wait(), the other is a CSS transition in another process on another
    -- frame budget.
    --
    -- So the page reports it. { kind = 'curtain'|'verdict', covered = bool },
    -- and per this project's rule (see client/players.lua and pause.lua) it
    -- reports the STATE it is in rather than a toggle -- a dropped message
    -- then costs one stale reading instead of permanent disagreement.
    --
    -- FAIL SAFE, ALWAYS. Every Lua waiter is bounded: a crashed CEF, a
    -- dropped POST or a transition the browser optimised away must cost a
    -- visible cut, never a player parked behind a black screen forever.
    COVERED      = 'br/cover',
    PAUSE_ACTION = 'br/pause/action',
    -- Rebind one command. { command, key } -- an empty key unbinds it.
    KEYBIND_SET  = 'br/settings/keybind',
}

BR.NUI_ENVELOPE_VERSION = 1

--- Screens that leave the GAME's input alive underneath them.
---
--- AN ALLOWLIST, NOT A DENY LIST. This started as "everything except lobby and
--- chat", so every screen added afterwards defaulted to KEEPING INPUT -- the
--- dangerous answer -- until somebody remembered to exclude it. A menu nobody
--- listed is now a menu you cannot run around inside, which is the safe way to
--- be wrong.
---
--- ONLY THE INVENTORY, AND IT PAYS A PRICE FOR IT THAT IS NOT WRITTEN HERE.
---
--- Keeping game input does not stop the page RECEIVING a click. It stops the
--- player AIMING one, because the mouse is still the camera and the mouse
--- buttons are still the trigger: reaching for a control turns your view away
--- from it, and pressing it fires your gun. The inventory is usable in spite of
--- that only because br_core/client/inventory.lua disables LOOK_LR, LOOK_UD,
--- ATTACK and AIM every frame while its panel is up -- "the camera spins as you
--- reach for a slot" (user, 2026-08-05). That per-frame suppressor is the real
--- cost of an entry in this table, it is written per screen, and nothing here
--- can grant it.
---
--- THE PLAYER LIST WAS ADDED HERE ON 2026-08-16 AND TAKEN BACK OUT THE DAY
--- AFTER (#135). It never got a suppressor, so it inherited the whole cost and
--- none of the remedy: "The player list doesn't capture mouse input today. It
--- should" (owner, 2026-08-16). It also asks for far more pointing than five
--- slot cards do -- a checkbox per row, a dropdown per ticked row, a note field
--- -- and it is a latching panel opened deliberately rather than a thing
--- glanced at mid-burst. So it trades "readable while running" for "clickable
--- at all", which is the trade the owner asked for.
---
--- AND THAT TRADE IS WHAT COLLAPSED THE PANEL BACK TO ONE FOCUS SCREEN. There
--- was a second, `playersReport`, whose entire reason for existing was to be
--- ABSENT from this table: a report has a text field, and with input kept every
--- keystroke in it is also a movement key, so typing a note walked you off a
--- roof. With view mode out of the table too, both modes want the same focus
--- and the second screen was machinery doing nothing. See br_ui/client/players.lua.
BR.FocusKeepsInput = { inventory = true }

--- What the engine and the page should be told, for a given focus stack.
---
--- PURE, AND IN br_lib, SO IT CAN BE TESTED. Focus is the single worst
--- non-crash bug this interface can produce -- a leak means the player cannot
--- move, cannot shoot, and cannot fix it without reconnecting -- and it has now
--- been got wrong twice in ways that were only findable by playing:
---
---   1. The stack was a boolean, so two screens closing out of order left
---      focus half-held.
---   2. The bridge only ACTED when "is anything focused" changed, so pushing a
---      screen onto an already-focused stack changed nothing the page could
---      see. Settings and the locker opened from the lobby did nothing at all
---      -- while still leaving an entry on the stack that nothing would pop,
---      so readying up carried the cursor into the match (user, 2026-08-09).
---
--- Both are the same mistake: deriving behaviour from a summary of the stack
--- instead of from the stack. This returns the whole answer, every time, and
--- the caller diffs it against what it last applied.
--- @param stack string[]
--- @return table  { held, screen, keepInput }
function BR.FocusResolve(stack)
    local n = stack and #stack or 0
    local screen = (n > 0) and stack[n] or 'none'
    return {
        held      = n > 0,
        screen    = screen,
        keepInput = (n > 0) and (BR.FocusKeepsInput[screen] == true) or false,
    }
end

--- Lua 5.4 distinguishes integer 5 from float 5.0 and they serialise differently
--- through SendNUIMessage. Normalise every numeric payload field once, here, at
--- the boundary -- not in twelve places downstream.
---@param v any
---@return any
function BR.NuiNumber(v)
    if type(v) == 'number' then
        return v + 0.0
    end
    return v
end

--- Recursively coerce all numbers in a payload to floats. Call this on the
--- envelope's `d` field before SendNUIMessage.
---@param tbl any
---@return any
function BR.NuiNormalise(tbl)
    if type(tbl) ~= 'table' then
        return BR.NuiNumber(tbl)
    end
    local out = {}
    for k, v in pairs(tbl) do
        out[k] = BR.NuiNormalise(v)
    end
    return out
end
