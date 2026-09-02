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

    -- S->C  { c = cue } -- "play this interface cue, in your own head".
    --
    -- ═══ WHY A MATCH-WIDE CUE NEEDS A MESSAGE AT ALL ═══
    --
    -- Every other cue in this gamemode is played by the client that has the
    -- reason to play it -- a hitmarker knows it hit. A cue for something that
    -- happens to the WHOLE MATCH at one instant has no such client: the storm
    -- record is solved locally by everybody, so eight clients crossing the
    -- HOLDING->SHRINKING boundary in their own frame loops would each have to
    -- edge-detect it themselves. That is a per-client latch, per tick, drifting
    -- by a frame each, and a client that rejoined mid-phase would latch at the
    -- wrong moment. The server already runs the phase job; it owns the edge.
    --
    -- WHY NOT REUSE FUEL_SFX. That one carries a NETWORK ID and plays from an
    -- entity -- it exists because the occupants of one car had to hear
    -- something positioned on that car. This is the frontend case: no entity,
    -- no position, the whole match at once. Same cue table, same throttle,
    -- different native at the far end. See br_core/client/sfx.lua.
    --
    -- THE CUE IS A KEY, NOT A SOUND NAME, exactly as FUEL_SFX's is. The wire
    -- never carries a GTA sound-set name, so the set of sounds this event can
    -- possibly produce is the client's own BR.Config.Audio.cues and nothing
    -- else -- an unknown key is ignored with one console line.
    SFX_CUE         = 'br:sfx:cue',

    -- Aerial supply drops. ONE MESSAGE PER DROP, at the moment it is
    -- committed: { n, poi, x, y, gz, alt, heading, tStart, tLand }. Both the
    -- descent and the blip's lifetime are solved from it locally against the
    -- synced clock, so nothing about a falling crate is ever on the wire --
    -- the same bargain STORM_SYNC and BUS_ROUTE already make.
    --
    -- THE CONTENTS ARE NOT IN IT, deliberately, and for the same reason a
    -- chest's are not: what is inside is the reason to run for it, and a
    -- client that knew would only run for the good ones. They arrive as
    -- ordinary LOOT_ADD entries when it bursts open.
    AIRDROP_SYNC    = 'br:airdrop:sync',     -- S->C  one airdrop record

    -- Player-placed map markers (one per player; squad-visible in squads)
    MARKER_SET      = 'br:marker:set',       -- C->S  { x, y }
    MARKER_CLEAR    = 'br:marker:clear',     -- C->S  remove my marker
    MARKER_SYNC     = 'br:marker:sync',      -- S->C  { op, owner, x, y, colour }

    -- Voice channels. The client cannot work these out for itself: a channel
    -- is derived from the match, and matchId is deliberately NEVER public
    -- (see PUBLIC_FIELDS in server/roster.lua). So the server hands each
    -- player the two numbers and nothing else.
    VOICE_SET       = 'br:voice:set',        -- S->C  { prox, mates, nearbyRange, squadRange }

    -- ONE BIT ABOUT THIS PLAYER'S OWN VOICE, TO THEIR OWN SQUAD.
    --
    -- Owner, 2026-08-29, after a playtest: "the squad panel works, but doesn't
    -- accurately show when others in the squad have 'off' selected"; and, when
    -- told the client was never sent it: "Why can't we build another client ->
    -- server -> squad hop? It should only be processed at the start of a squad
    -- in warmup and whenever changes occur."
    --
    -- IT IS A BOOLEAN, NOT THE MODE, AND THAT IS THE WHOLE CONTRACT. `off`
    -- means "my voice carries nothing in either direction" -- the state
    -- BR.VoiceMode.OFF resolves to, whether the player chose it, is spectating
    -- or is sat in the lobby. 'nearby' and 'squad' are indistinguishable on
    -- this wire and must stay that way: which of the two a mate is on is a fact
    -- about people a client cannot see, it changes with the distance between
    -- them, and the honest version of it is a proximity oracle. The refusal is
    -- argued in full in ui-src/src/hud/VoiceMark.tsx and pinned by
    -- tools/check_squad_voice.lua, which now permits this one field and still
    -- fails the build for anything wider.
    --
    -- EDGE-TRIGGERED. The client sends when the answer CHANGES and when its
    -- squad assignment does, never on a band -- see the publish in
    -- br_core/client/voice.lua. The server keeps it on the roster entry and it
    -- reaches squadmates on the beacon that is already leaving (SQUAD_POS),
    -- so nothing periodic was added at either end.
    VOICE_STATE     = 'br:voice:state',      -- C->S  { off = boolean }

    -- Loot / inventory
    LOOT_CELL       = 'br:loot:cell',        -- C->S  { cx, cy } subscribe to a grid cell
    LOOT_ADD        = 'br:loot:add',         -- S->C  array of loot entries entering scope
    LOOT_GONE       = 'br:loot:gone',        -- S->C  array of loot ids removed

    -- Volts never enter the inventory, so they never reach the client path that
    -- plays the pickup cue. This is that cue, on its own, for the one kind of
    -- loot that collects without a slot (owner, 2026-08-28).
    LOOT_PICKUP_CUE = 'br:loot:pickupcue',   -- S->C  play the pickup sound, no payload
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
    -- C->S {}. THE MANUAL RELOAD KEY, AND IT CARRIES NOTHING ON PURPOSE.
    --
    -- The server reloads the slot IT believes is active, from the pool IT holds,
    -- by the same rule spendRound and the INV_AMMO floor run -- so there is no
    -- number for a client to choose and none to lie about. It moves rounds
    -- between a magazine and its pool and cannot raise the two together, which
    -- is what stops a reload key being a fifth way to conjure ammunition.
    INV_RELOAD      = 'br:inv:reload',       -- C->S  {}
    -- C->S <weapon hash>. The client took a weapon out of its own ped's hand
    -- because the inventory never issued it. Client-observed by necessity, in
    -- the same way NPC_DROP above is: the ped's hand is a client-side fact and
    -- the server has no native that can read it.
    --
    -- IT IS EVIDENCE, NOT AN INSTRUCTION. Nothing on the server changes because
    -- of this message -- no inventory is touched, no player is told anything.
    -- It opens a moderation case, so the far end rate-limits it, cross-checks
    -- the hash against the inventory the SERVER holds, and exempts admins. See
    -- br_core/server/strip.lua for all three.
    INV_STRIPPED    = 'br:inv:stripped',     -- C->S  <hash>

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
    -- S->C (no payload) "somebody just streamed your body in; say where it is".
    --
    -- ADDRESSED TO THE BODY'S OWNER AND TO NOBODY ELSE, which is the whole
    -- shape: the server cannot write a player ped (there is no server-side
    -- SET_ENTITY_COORDS -- the server's entity setters are routing, culling,
    -- orphan and lockdown, and nothing else), so the one machine that can say
    -- where a downed or dead body is, is the machine that owns it.
    --
    -- IT CARRIES NOTHING BECAUSE THERE IS NOTHING TO CARRY. Who entered scope
    -- is the server's business, not the owner's; the owner's answer is the same
    -- whoever asked, and a payload naming the newcomer would be a list of who
    -- can see you handed to the player being looked at. #246.
    DBNO_RESYNC     = 'br:dbno:resync',
    REVIVE_START    = 'br:revive:start',     -- C->S  { target }
    REVIVE_STOP     = 'br:revive:stop',      -- C->S
    -- S->C { pct, target, reviverName, bleedEndsAt }. Sent to BOTH parties while
    -- a revive runs: the reviver needs it for their hold ring, and the downed
    -- player needs to know somebody is actually coming for them -- which is the
    -- one piece of information that decides whether they hang on or give up.
    --
    -- `bleedEndsAt` RIDES HERE FOR ONE REASON: the bleed clock is PAUSED while a
    -- hold is progressing, and a pause is not a mode -- it is the server moving
    -- the deadline forward 250ms at a time. DBNO_SET carries that deadline but
    -- is only sent on edges, so between them the interface counts down from a
    -- number that has already moved, and the timer visibly runs while the hold
    -- that stopped it is working. Same units and same origin as DBNO_SET's copy:
    -- a SERVER timestamp, comparable only to the clock-corrected browser time.
    REVIVE_PROGRESS = 'br:revive:progress',
    -- S->C (no payload) "get up, where you are".
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
    -- ⚠ THE NAME IS `atstart` AND THAT IS NOW HISTORY, NOT MEANING. It was
    -- written for #144's held death, which is still one of its two senders. The
    -- other is server/revivekey.lua's key revive, which is not at the start of
    -- anything -- and the wire name is deliberately NOT being changed for it,
    -- because an event id is a compatibility surface and renaming one to improve
    -- a comment is how a deploy goes half-and-half.
    --
    -- IT IS NO LONGER "EXACTLY ONCE PER HELD DEATH". It is once per OUT->ALIVE
    -- transition, from whichever path made it. client/spawn.lua's handler is
    -- already written to be idempotent (a second copy resurrects a living ped at
    -- its own feet, which is a no-op), so the widening cost nothing there.
    --
    -- No payload: the client already knows where its own body is, and the
    -- server's position sample is a quarter of a second stale. That is what
    -- makes "you come back where you fell" free rather than a placement -- see
    -- client/spawn.lua on why the ground probe must not be involved.
    REVIVED         = 'br:revive:atstart',

    -- The CPR kit's rescue (#191).
    --
    -- THE TRAFFIC IS ASYMMETRIC ON PURPOSE, and the asymmetry is the security
    -- model rather than an accident of what was convenient. Four of these six
    -- events run server->client, because every DECISION in a rescue is the
    -- server's: whether it may start, where it goes, when it is stuck, and how
    -- it ends. The two that run client->server carry no parameters at all -- one
    -- asks for a rescue and one says the ambulance is a wreck -- so there is
    -- nothing in either for a modified client to forge. See the top of
    -- server/rescue.lua for how the wreck report can be trusted on sight.
    RESCUE_CALL     = 'br:rescue:call',   -- C->S  (no payload) "call a medic"
    -- S->C  { pickup, dest, endsAt }. Everything the client needs to build the
    -- ride, decided entirely on the server.
    RESCUE_BEGIN    = 'br:rescue:begin',
    -- S->C  { distM }. The server has judged this ambulance stuck -- from its
    -- OWN position samples, never from anything the client said -- and is
    -- ordering a re-place. The client carries it out; it never decides it.
    RESCUE_PLACE    = 'br:rescue:place',
    -- C->S  (no payload) the ambulance has been destroyed. Believed on sight,
    -- because the only thing it can do is eliminate the player who sent it.
    RESCUE_LOST     = 'br:rescue:lost',
    -- C->S  (no payload) the ambulance reached the drop-off. CHECKED, unlike the
    -- wreck report: it is refused unless the server has independently watched
    -- the ambulance travel.
    RESCUE_ARRIVED  = 'br:rescue:arrived',
    -- S->C  { delivered, x, y, z, heading }. The one ending, both ways round:
    -- `delivered = false` means tear the ride down without placing anybody.
    RESCUE_END      = 'br:rescue:end',
    -- S->C  { key, x, y }, or `{ key, gone = true }` to take one down. Owner,
    -- 2026-08-23: "if someone takes it, we need to update it's location on the
    -- map for other players".
    --
    -- KEYED BY AN OPAQUE STRING RATHER THAN BY A PLAYER, because two different
    -- things end up on this channel and only one of them is a person: a rescue
    -- in flight (`r:<src>`) and an ambient ambulance somebody was seen driving
    -- (`v:<entity>`). The client neither parses nor interprets the key -- it is a
    -- table index and nothing else -- which is what lets #219 add a third
    -- category without touching either end.
    --
    -- BROADCAST TO THE MATCH, WHICH IS A DELIBERATE HOLE IN A RULE THIS PROJECT
    -- OTHERWISE KEEPS ABSOLUTELY. server/roster.lua withholds `pos` from
    -- PUBLIC_FIELDS because "broadcasting live positions to every client would
    -- hand a wallhack to anyone reading the event stream", and that reasoning is
    -- untouched -- this is ONE player, for the DURATION OF ONE RESCUE, and
    -- publishing it is the point rather than a side effect. The owner made the
    -- ambulance destructible so other players could end it, kept the siren on so
    -- they could find it, and asked for the map to follow it. A rescue is a
    -- position the game is deliberately announcing.
    --
    -- COORDINATES, NOT AN ENTITY. client/squadmates.lua records why: an
    -- entity-anchored blip dies at the ~424m scope ceiling, and an ambulance
    -- crossing the map is exactly the case that breaks. AddBlipForCoord fed from
    -- the server has no such limit.
    RESCUE_BLIP     = 'br:rescue:blip',

    -- Healing in the back of an ambulance (owner, 2026-08-28). A DIFFERENT
    -- FEATURE FROM THE FOUR ABOVE and deliberately not folded into them: those
    -- carry a DBNO player on a scripted journey, these carry an ALIVE player
    -- standing still. Sharing an event would mean one handler branching on which
    -- kind of ambulance moment it was, which is the shape of thing that ends up
    -- reviving somebody by accident.
    --
    -- ═══ THE HEALTH ITSELF IS NOT ON THIS CHANNEL ═══
    --
    -- It goes out on INV_EFFECT, the med kit's own event, because it is the same
    -- thing: a target the server issued and the client applies upward. That
    -- reuse is worth more than a tidy name -- client/inventory.lua's handler
    -- already caps, floors and refuses a downward write, and server/roster.lua's
    -- health audit already excuses a rise inside `healUntil` as HEALING. A new
    -- event would have needed its own copy of the first and its own excuse in
    -- the second, and the audit crying wolf on the owner's own feature is
    -- exactly the failure config/match.lua's healthAudit block warns about.
    --
    -- C->S  { n = netId } -- "I am standing at the open rear doors of that
    -- ambulance and I pressed interact". EVERY CLAIM IN THAT SENTENCE EXCEPT THE
    -- DOORS IS RE-DERIVED SERVER-SIDE: the model, the distance, the rear arc,
    -- being alive and hurt, and whether anybody else already has that van. The
    -- doors cannot be -- there is no server handler for the door angle -- and
    -- BR.AmbHealSolve.doorsOpen states what a client gains by lying about them.
    AMBHEAL_START   = 'br:ambheal:start',
    -- C->S  (no payload) -- "stop". The interact key while healing, and also
    -- what the client sends when it sees the doors shut, the van gone or its own
    -- ped die. NO PAYLOAD because there is nothing to forge: a player may always
    -- stop their own heal, and the server keeps whatever was granted.
    AMBHEAL_STOP    = 'br:ambheal:stop',
    -- S->C  { n = netId } to begin, `{ done = true }` / `{ done = false }` to
    -- end. ONE EVENT FOR BOTH ENDINGS so a completion cannot be lost behind a
    -- teardown that arrives after it -- the same argument SPECTATE_SET makes.
    --
    -- THE CLIENT BUILDS NOTHING UNTIL THIS ARRIVES. The prompt is local, the
    -- press is a request, and the stretcher, the siren and the camera are all
    -- downstream of the server having granted the claim -- so two players
    -- pressing at one van in the same frame produce one attach, not two.
    AMBHEAL_SET     = 'br:ambheal:set',

    -- Revive keys (#219 steps 4 and 5)
    --
    -- C->S  { n = netId } -- "I am standing at that ambulance and I want my
    -- squad's revive keys". ONE EVENT AND NO REPLY, because there is nothing to
    -- reply with: the only thing a player is ever told about a REFUSED purchase
    -- is nothing at all, and the only thing they are told about a completed one
    -- is BR.Config.ReviveKey.copy.bought, which the server speaks itself.
    --
    -- EVERY CLAIM IN THAT SENTENCE IS RE-DERIVED SERVER-SIDE: the model, the
    -- distance, being alive in a playing match, having a squad, and there being
    -- an outstanding key to buy. See BR.ReviveKey.canBuy.
    --
    -- ITS SENDER IS client/revivekey.lua, which draws the buy plate at an
    -- ambulance when this player's squad has something outstanding. Until the
    -- owner gave the wording there was no sender at all and /brkey buy was the
    -- only way to reach this handler; that console verb still exists and still
    -- runs the identical path.
    --
    REVIVEKEY_BUY   = 'br:revivekey:buy',

    -- ═══ AND THE PICKUP IS A PRESS TOO, WHICH IT WAS NOT ═══
    --
    -- C->S  { target = serverId } -- "I am standing on that mate's key and I am
    -- taking it".
    --
    -- THIS EVENT USED NOT TO EXIST, AND THE NOTE HERE SAID IT MUST NOT. The
    -- argument was that the server already samples every position four times a
    -- second, so nothing needed to be sent and nothing could be lied about. It
    -- was answered by a playtest: "I somehow picked up the dead player's key by
    -- walking up to them without seeing a DUI or pressing anything" (owner,
    -- 2026-08-30). A thing that leaves the ground without a press is a thing the
    -- player cannot know they have.
    --
    -- NOTHING IS TRUSTED BUT THE INTENT. The claim carried here is "I pressed,
    -- and I meant that mate"; the distance, the squad, the match and whether
    -- there is still a pickup there are all re-derived from the server's own
    -- samples in BR.ReviveKey.canTake -- exactly as the purchase re-derives
    -- every clause of "I was standing at an ambulance".
    REVIVEKEY_TAKE  = 'br:revivekey:take',

    -- ═══ THE HOLD THAT ACTUALLY BRINGS SOMEBODY BACK ═══
    --
    -- C->S  { target = serverId, n = netId } -- "I am at that ambulance and I am
    -- holding the key down to bring that player back".
    --
    -- IT NAMES THE AMBULANCE AS WELL AS THE MATE, and that is the difference the
    -- owner's 2026-08-30 message made: the revive used to be ruled against the
    -- key's own recorded point on the ground and is now ruled at a van, so the
    -- server needs to know WHICH van -- both to rule the distance and because
    -- the arrival is placed 150m above that exact vehicle. The net id is a name,
    -- not a fact: server/revivekey.lua resolves it, checks it exists, checks the
    -- model against BR.Rescue.isAmbulance and measures the distance itself.
    --
    -- RE-ASSERTED EVERY 250ms RATHER THAN SENT
    -- ONCE, which is client/dbno.lua's protocol and exists for a bug this
    -- project has already shipped: a brief tap completed a whole revive when the
    -- STOP below was raised and did not land. Progress requires CONTINUOUS
    -- evidence, so silence stops a hold (BR.Config.ReviveKey.reviveBeatMs) and a
    -- lost STOP costs a fraction of a second instead of the whole interaction.
    --
    -- WHY NOT REVIVE_START. That event's ruling, `reviveAllowed` in
    -- server/combat.lua, refuses any target that is not DBNO, and the stepper
    -- behind it (`combat.dbno`) only ever walks DBNO entries. The subject of a
    -- key revive is OUT and spectating; it needs its own ruling and its own
    -- stepper, keyed on the key record rather than on the roster entry's
    -- `reviverSrc` -- see server/revivekey.lua on why sharing that field would
    -- push DBNO_SET at a player who is not down.
    REVIVEKEY_START = 'br:revivekey:start',
    -- C->S  (no payload) "the key came up". The subject is not named because the
    -- server holds exactly one claim per reviver and can find it; the same shape
    -- REVIVE_STOP uses, for the same reason.
    REVIVEKEY_STOP  = 'br:revivekey:stop',
    -- S->C  { pct, target, done?, cancelled? }. The reviver's own ring.
    --
    -- SENT TO THE HOLDER AND TO NOBODY ELSE. It is the same envelope
    -- REVIVE_PROGRESS carries and it is read the same way: `cancelled` and
    -- `done` are what let the client drop a hold it can no longer see the
    -- outcome of, and the ring itself is animated locally from a start message
    -- rather than driven by these -- a dropped one cannot stutter it.
    REVIVEKEY_PROGRESS = 'br:revivekey:progress',

    -- ═══ THE ARRIVAL, IN THE OWNER'S OWN ORDER ═══
    --
    --   "their screen should fade to black, set focus to the area where the
    --    ambulance I just used is, process the revive, give them a parachute,
    --    put them 150m above the ambulance, then fade in."  -- 2026-08-30.
    --
    -- TWO EVENTS, BECAUSE THE BLACK HAS TO COME FIRST AND THE SERVER OWNS THE
    -- LEDGER. The screen is the client's and the resurrection is the server's,
    -- and the whole point of his sentence is that one precedes the other.
    --
    -- S->C  { x, y, z } -- "you are coming back at that van: go black and pull
    -- the world in there". Sent to the SUBJECT the moment the hold completes.
    -- `{ cancelled = true }` is the same event withdrawing the promise, so a
    -- revive that falls apart in the second between the two does not leave
    -- somebody staring at a black screen.
    REVIVEKEY_ARRIVE = 'br:revivekey:arrive',
    -- S->C  { x, y, z } -- "you are back: stand up 150m over that point with a
    -- parachute, and fade in". Sent BEFORE the roster flips to ALIVE, which is
    -- the ordering REVIVED's note below states and the reason it is stated: a
    -- client left holding a corpse while the server calls it ALIVE is exactly
    -- the state the server-observed death check exists to eliminate.
    --
    -- WHY NOT REVIVED. That event resurrects a player WHERE THEY FELL, with no
    -- placement at all -- it is #144's held death, and client/spawn.lua's
    -- handler is written around the body already being on the ground it fell to.
    -- This one is an arrival somewhere else, in the air, with a chute.
    REVIVEKEY_PLACE  = 'br:revivekey:place',

    -- Spectate / end
    --
    -- THE SERVER PICKS THE TARGET AND THE CLIENT DRAWS IT, and the split is a
    -- privacy boundary rather than a preference. Who a dead player may look at
    -- is the whole of #192 (shared/spectate_solve.lua), and a client-side
    -- filter is not a boundary -- the same sentence BR.ChatChannel's `squad`
    -- carries. The client never learns a candidate list; it is told one target
    -- at a time, and told it BY THE SERVER, which is also the only side that can
    -- see the position of a player who is out of scope.
    --
    -- S->C. `{ targetSrc, name, admin, x, y, z }` while a session is running,
    -- re-sent at BR.Config.Spectate.feedMs so the camera has somewhere to be;
    -- `{ stop = true, reason = <string> }` when it ends, for whatever reason.
    -- ONE EVENT FOR BOTH so a stop can never be lost behind a position push
    -- that arrives after it.
    SPECTATE_SET    = 'br:spectate:set',
    -- C->S  { dir } -- +1 next, -1 previous, 0 "start, or re-resolve what I
    -- have". 0 is what a client sends on being eliminated: it asks the server
    -- to open a session under the rules, and the rules may answer "nobody".
    SPECTATE_CYCLE  = 'br:spectate:cycle',
    -- C->S. The pause-menu exit the owner asked for, and the only way a
    -- spectator can end their own session. No payload: the server knows who
    -- asked and a spectator has exactly one session.
    SPECTATE_STOP   = 'br:spectate:stop',
    SUMMARY         = 'br:summary',          -- S->C  end-of-match payload

    -- Fuel. The server owns a metre budget per VEHICLE (server/fuel.lua); the
    -- client owns the gauge, the pump prompt and the station blips.
    --
    -- THE FRACTION IS WHAT TRAVELS, NOT THE LITRES, because
    -- SET_VEHICLE_FUEL_LEVEL is in the vehicle's own tank units and only the
    -- client can read `fPetrolTankVolume` off the handling. The metres ride
    -- along for the pump readout, which is the ledger's own number and must not
    -- be recomputed at the far end from a rounded fraction.
    --
    -- S->C  { n = netId, f = 0..1 of a tank, m = metres remaining }
    FUEL_SET        = 'br:fuel:set',
    -- C->S  { n = netId } -- "what does this car hold?", sent when the player
    -- starts the ENTRY ANIMATION rather than when they are seated, so the
    -- answer is in hand before the ignition would fire. The server answers only
    -- for a vehicle the asker is standing next to; see server/fuel.lua for why
    -- an unrestricted version of this would be a small wallhack.
    FUEL_ASK        = 'br:fuel:ask',
    -- C->S  { n = netId } -- "I am holding the interact key". Repeated for as
    -- long as the hold lasts. EVERY OTHER CLAIM IN THAT SENTENCE IS RE-DERIVED
    -- SERVER-SIDE (in a match, alive, in that vehicle, in the driver's seat, at
    -- a station), and how much fuel it is worth comes from the wall clock
    -- rather than from how many of these arrived -- BR.FuelSolve.grantMs. This
    -- is the only message in the gamemode that can make a resource go UP, which
    -- is why it is the one with the most checks behind it.
    FUEL_PUMP       = 'br:fuel:pump',
    -- S->C  { n = netId, c = cue } -- "play this cue from that car".
    --
    -- ═══ THIS EXISTS BECAUSE THE AUDIO NATIVE IS NOT NETWORKED ═══
    --
    --   "All occupants of a vehicle should hear these sounds."
    --                                          -- owner, 2026-08-22
    --
    -- PLAY_SOUND_FROM_ENTITY plays on the machine that calls it and nowhere
    -- else, so "everyone in the car hears it" has to be a message. The SERVER
    -- decides who gets one -- it is already the thing that knows who is in
    -- which vehicle, from the ledger's own roster walk -- and each recipient
    -- plays its own copy anchored on its own handle for that car.
    --
    -- THE CUE IS A KEY, NOT A SOUND NAME. `c` indexes BR.Config.Audio.cues, so
    -- the wire never carries a GTA sound-set name and a client cannot ask for
    -- an arbitrary one. See br_core/client/sfx.lua's playFrom.
    FUEL_SFX        = 'br:fuel:sfx',

    -- Vehicle boost. The CLIENT owns the meter, the push and its own flames --
    -- a twitch input cannot wait for a round trip -- so these two carry only
    -- what a client cannot do for itself.
    --
    -- C->S  { on = boolean, netId = integer, endsAt? = server ms }
    -- EDGES, NOT DURATIONS, and that is the whole security shape of the fuel
    -- surcharge: the elapsed time is measured on the server's own clock, so
    -- there is no millisecond count in this message for anyone to inflate.
    -- `endsAt` is a HINT about the sender's own meter and is clamped to
    -- BR.Config.Boost.capacityMs at the far end. See server/boost.lua's header
    -- for the owner's decision to accept the client's word here, exactly what it
    -- costs, and the three clamps that bound it.
    BOOST_SET       = 'br:boost:set',
    -- S->C  { netId, on, endsAt? }
    -- The published record, in the same clock-and-record shape the storm and the
    -- bus route use: every client draws its own LOCAL particle effect from it and
    -- puts it out on `endsAt` with no second message needed, so a lost stop
    -- cannot leave a car on fire. Nothing here is an entity; see
    -- br_core/client/boost.lua on why `sv_entityLockdown` has no opinion on a
    -- particle handle.
    BOOST_SYNC      = 'br:boost:sync',

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
    PLAYERS_LIST    = 'br:players:list',     -- S->C  { players = { { id, name, state, squadId, left } } }
    -- C->S { targets = { { id, category } } }.
    --
    -- `id` IS AN OPAQUE PER-MATCH ROW TOKEN, NOT A SERVER ID AND NOT A LICENSE
    -- (#172). It was `src` until players who have left had to stay reportable,
    -- and a server id cannot carry that: it is recycled within the minute, so a
    -- departed row named by its old `src` resolves to whoever holds that slot
    -- now and files the accusation against a stranger.
    --
    -- A LICENSE WITH THE `license:` PREFIX STRIPPED IS NOT THE ANSWER EITHER,
    -- and the reasoning is on BR.Players.listFor rather than repeated here: the
    -- prefix is a constant, so removing it is a rename rather than obfuscation,
    -- and the raw value is the durable key bans and moderation are filed under.
    -- The token is minted server-side, means nothing outside the match that
    -- minted it, and dies with that match -- so the client still names something
    -- the server resolves, which is the rule the market follows for item ids.
    REPORT_SUBMIT   = 'br:report:submit',
    -- S->C { ok, filed, refused? }. Sent when the incident has actually LANDED,
    -- not when the request was received -- the promise to the player is that an
    -- admin will see it, and that promise is only true once a row exists.
    REPORT_RESULT   = 'br:report:result',
    -- S->C { kind = 'exists' } | { kind = 'killer', name = <who> }.
    --
    -- THE SERVER DECIDES WHO GETS IT; THE CLIENT WRITES THE SENTENCE. Both
    -- prompts name the player-list key, and only the client knows which key that
    -- is -- it is rebindable, and a hint naming the wrong key is worse than no
    -- hint (#168, #169). So the envelope carries the OCCASION and never the
    -- text, and br_ui composes it against the keybind table it is already sent.
    --
    -- NO LICENSES, NO IDS, NO LISTS. `name` is a display name the recipient has
    -- already been shown by the kill feed. Nothing here tells a client anything
    -- about a player it was not already looking at.
    REPORT_HINT     = 'br:report:hint',
    -- C->S, NO PAYLOAD AT ALL, and that is the entire anti-enumeration design
    -- (#169). "Was I just killed by somebody who already has a case open?" is a
    -- question only the server may answer, and a client that could NAME the
    -- player it is asking about would be a probe for who is under suspicion.
    -- So the client asks about nobody: the server resolves the asker's own
    -- attributed killer from its own damage records and answers about that
    -- player or says nothing.
    REPORT_KILLED   = 'br:report:killed',
    -- C->S, NO PAYLOAD, FOR THE SAME REASON REPORT_KILLED CARRIES NONE (#177).
    --
    -- "Yes, that one too" -- the one-press answer to the prompt above. The
    -- server resolves the asker's own attributed killer a second time, from the
    -- same records, and corroborates the case it already found there. A client
    -- cannot name the subject, so widening the lookup beyond the current match
    -- (#177 part 1) did not widen what a client can ask ABOUT.
    --
    -- IT IS NOT A SECOND WAY TO REPORT. The subject must already have an open
    -- case, this player must not already have named them this match, and both
    -- of those are decided server-side by the same function that decides
    -- whether the prompt is shown at all.
    REPORT_CORROBORATE = 'br:report:corroborate',

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

    -- The world override: the console's time of day and sky (brtime/brweather).
    --
    -- S->C { hour, minute, weather }. NOT A DELTA AND NEVER ONE: `nil` cannot
    -- travel in a table, so a payload of changes could never say "stop
    -- overriding the hour". This carries the whole override every time and A
    -- MISSING KEY IS THE RESET -- see BR.World.payload.
    --
    -- Sent to everyone the moment it changes, and to ONE client on br:ready.
    -- That second send is the whole of the late-joiner story: a client that
    -- connects after the command was typed would otherwise pin its own clock at
    -- noon while the rest of the session stood at dusk.
    WORLD_SET       = 'br:world:set',

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

    -- C->S. "The console I am framing says nobody is signed in; please get me
    -- a session." Answered with a BR.Nui.ADMIN envelope carrying either a URL
    -- to point the frame at or a machine-readable failure code (#23).
    --
    -- THE CLIENT ASKS AND THE SERVER DECIDES, and the asymmetry is the whole
    -- security design rather than a style choice. Minting is a shared-secret
    -- call to Ringmaster that produces a working admin session for a named
    -- Discord id: a client that could make that call could name somebody
    -- else's. So this event carries NO ARGUMENTS AT ALL -- not a license, not
    -- a Discord id, not a scope. Everything the mint needs is read on the
    -- server from `source`, and br_core/server/admin.lua re-runs the full
    -- eligibility check on every one of these rather than trusting that the
    -- tab was only ever shown to somebody entitled to it.
    ADMIN_MINT      = 'br:admin:mint',

    -- S->C { origin?, mint? }. Whether this player has an Admin tab, where the
    -- console is, and the answer to any mint they asked for.
    --
    -- SENT TO ONE PLAYER, NEVER BROADCAST. `origin` present IS the permission,
    -- so this event is also the only thing that puts the console's address on a
    -- machine -- which is half of why the server-side gate exists at all.
    --
    -- A br_lib EVENT FORWARDED BY br_ui, RATHER THAN A DIRECT `br:ui:send`.
    -- br_ui/client/nui.lua does register `br:ui:send` as a net event and it
    -- would work -- but nothing in this project has ever called it from a
    -- server, and this repo has a documented habit of shipping correct code
    -- with no callers. Every other server-to-page push in the game goes
    -- server -> BR.Net.X -> a br_ui client handler -> br:ui:sendLocal, and that
    -- is the path with production mileage on it.
    ADMIN_STATE     = 'br:admin:state',

    -- S->C { invite? }. Where this deployment's Discord is, or that it has no
    -- Discord to point at.
    --
    -- THE MIRROR IMAGE OF ADMIN_STATE ABOVE, AND WORTH SAYING SO NEXT TO IT.
    -- That event withholds an address because holding it IS the permission;
    -- this one has nothing to withhold. An invite is a public link already
    -- printed to anyone we kick, so it goes to every player on br:ready with no
    -- gate in front of it, and the only question the payload answers is whether
    -- there is one.
    --
    -- `{}` IS A REAL ANSWER AND SILENCE IS NOT. An operator who clears
    -- br_discordUrl and restarts br_core sends the empty table, and a page that
    -- is still up takes the card down on the strength of it -- which saying
    -- nothing could never do. Same argument br_core/server/admin.lua's push()
    -- makes for sending `{}` rather than staying quiet.
    --
    -- THE FIELD IS `invite`, NOT `discordUrl`, AND THE RENAME IS LOAD-BEARING.
    -- br_lib/config/overrides.lua's contract is that an overridable key is read
    -- on the server and nowhere else, and tools/verify.sh enforces it by
    -- grepping every br_*/client/*.lua for the bare key name -- a name that
    -- appears in a client file at all, comment or code, fails the build. The
    -- wire carries the resolved value under a name the client half is allowed
    -- to say, which is the same rename consoleUrl -> `origin` already makes.
    COMMUNITY       = 'br:community',
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
    -- THE CAR YOU ARE IN: { show, health, fuel }, both 0..100.
    --
    -- A CHANNEL OF ITS OWN RATHER THAN TWO MORE FIELDS ON `hud`, and the reason
    -- is the dedupe. client/state.lua's HUD push compares every field it sends
    -- and returns early when none moved, which is what keeps it quiet for a
    -- player standing still. Vehicle health and fuel BOTH move continuously
    -- while driving, so folding them in would make that comparison always true
    -- and turn the whole HUD envelope into an unconditional 10 Hz push -- for a
    -- readout only present while seated in a car.
    --
    -- IT IS ALSO NOT THE SAME LIFETIME. `hud` is on screen for the whole match;
    -- this exists between one door and the next.
    VEHICLE   = 'vehicle',
    PROMPT    = 'prompt',    -- world-anchored interaction prompt + progress ring
    FEED      = 'feed',      -- kill feed + damage numbers
    HIT       = 'hit',       -- YOU connected: {amount, headshot, killed, name}
    STORM     = 'storm',     -- phase, radius, endsAt (4 Hz)
    DBNO      = 'dbno',
    SPECTATE  = 'spectate',
    -- YOUR OWN DEATH, AS A WORD OVER THE WORLD, for the seconds before the
    -- spectator camera takes the screen.
    --
    -- DELIBERATELY NOT `SUMMARY`, and the split is the point. SUMMARY is the
    -- match-end verdict SCREEN -- backdrop, placement, Volts -- and it is
    -- gated on the match being over. This is the death MOMENT: the same word,
    -- alone, on the live world, ~10 seconds, then gone as spectating begins
    -- (the owner). One envelope carrying both would have to be told which of
    -- the two it was, which is a flag standing in for the two surfaces the
    -- owner asked to keep distinct.
    DEATH     = 'death',
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
    -- The admin console (#23): { origin?, mint? }.
    --
    -- `origin` PRESENT IS THE WHOLE OF "SHOW THE ADMIN TAB". It is sent to one
    -- player, only when the server has decided that player may have it, and it
    -- is simply absent otherwise -- so the address of the console is never on
    -- an ordinary player's machine at all. There is no boolean beside it to get
    -- out of step: the tab needs a URL to be worth anything, so the URL IS the
    -- permission.
    ADMIN     = 'admin',
    -- Where our Discord is (owner, 2026-08-30): { invite? }.
    --
    -- `invite` PRESENT IS THE WHOLE OF "DRAW THE CARD", the same one-field shape
    -- ADMIN uses above and for the same reason: a card with no address on it is
    -- worth nothing, so the address IS the condition, and there is no boolean
    -- beside it to fall out of step with it.
    --
    -- THE ENVELOPE ITSELF IS NOT THE SIGNAL, WHICH IS THE ONE TRAP HERE. `{}`
    -- is a table and a table is truthy in both languages, so a reader that asks
    -- whether the payload arrived draws a card with nothing in it. Every reader
    -- has to look inside, at the string.
    COMMUNITY = 'community',
}

--- A HOLE IN A SENTENCE WHERE A KEY BELONGS.
---
--- Owner, 2026-08-22: "we should make our own glyphs for keys. For example,
--- this message looks too bland and hard coded: 'Voice chat is set to nearby.
--- Hold N to speak. You can change your preference and keybinds in Settings.'"
---
--- THE WORDING STAYS HERE AND THE DRAWING GOES THERE, which is the only split
--- that satisfies both of this project's standing rules at once. Interface text
--- is composed in Lua, beside the code that decides which state we are in --
--- one place for the words, and VoiceNotice.tsx, Settings.tsx and this file's
--- own callers all argue why. A key drawn as a key is a plate with a border and
--- a bevel, which Lua cannot express. So Lua writes the sentence with a gap in
--- it and names the COMMAND; ui-src/src/ui/KeyCap.tsx resolves that command
--- against the keybinds list and draws the plate.
---
--- THE COMMAND, NEVER THE LABEL, AND THAT IS THE POINT RATHER THAN A STYLE
--- CHOICE. A substituted key label is a photograph of the binding at the
--- instant the string was built. These strings outlive that instant -- a
--- twelve-second toast, a sticky notice that stays up while the map is open, a
--- settings paragraph that sits on the very screen the player rebinds from --
--- so a label would go stale under the reader, naming a key that no longer does
--- anything. A command name cannot go stale, and the page re-resolves it on
--- every rebind push.
---
--- WHAT IT DOES NOT DO: decide whether a key EXISTS. A caller that has a
--- different sentence for the unbound case still has to ask (see
--- BR.Voice.statusFor, which does exactly that). This only marks the gap.
---
--- @param command string   a RegisterCommand name, e.g. 'brptt'
--- @return string          the token to embed, e.g. '{key:brptt}'
function BR.KeyToken(command)
    return ('{key:%s}'):format(tostring(command))
end

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
    -- The Admin tab is a DOOR, not a tab body (#23). Opening it pushes a focus
    -- screen of its own so the console gets the full-page treatment `/help`
    -- has, rather than the pause menu's tab well -- a board of bans, incidents
    -- and a player table is unusable in a panel. Same shape as HELP_FOCUS.
    ADMIN_FOCUS  = 'br/admin/focus',
    -- "Ringmaster says I am signed out." Forwarded to the server, which is the
    -- only side allowed to ask for a token. See BR.Net.ADMIN_MINT.
    ADMIN_MINT   = 'br/admin/mint',
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
