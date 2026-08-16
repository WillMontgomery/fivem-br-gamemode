-- Match configuration.
--
-- Player counts live here rather than being hardcoded so raising the cap later is
-- a one-line change. Note the hard ceiling below: OneSync is free up to 48 slots,
-- and setting sv_maxclients above that without a Cfx.re Element Club tier makes
-- the server fail its heartbeat check and drop off the public list entirely.

BR = BR or {}

BR.Config = BR.Config or {}

BR.Config.Match = {
    -- Slots. 48 is the free OneSync ceiling; the code paths are written to scale
    -- past it, but do not raise this without the matching Element Club tier.
    maxPlayers      = 48,
    -- 1 so a lone dev client can walk the whole flow. The win condition knows
    -- a dev match that STARTED with one squad has nothing to win (see
    -- winConditionMet) -- otherwise PLAYING would end three seconds in.
    minToStart      = 1,
    minToStartProd  = 16,

    -- Lobby / warmup timings, in seconds.
    warmupSeconds   = 45,
    warmupShortened = 15,     -- once the lobby is full, cut the wait
    endedSeconds    = 20,     -- summary screen duration before returning to lobby
    cleanupSeconds  = 5,

    -- THE COVER HANDSHAKE'S DEADLINES, and every one of them exists to be
    -- WRONG SAFELY rather than to be right (#124).
    --
    -- A screen transition is: cover the screen, change the world, uncover.
    -- The cover lives in CEF and the change lives in Lua, so the only honest
    -- way to order them is for the page to say "I am black now"
    -- (BR.NuiCb.COVERED). These are the caps on waiting for it -- a page that
    -- never answers has crashed, and a player left staring at black because
    -- of it is a far worse bug than the visible cut the cover was hiding.
    --
    -- coverWaitMs   the curtain's own fade is 600ms; four times that is
    --               "something is wrong", not "the machine is slow".
    -- verdictWaitMs the verdict backdrop starts 1.4s after the summary lands
    --               and takes 2s to reach solid black -- so ~3.9s from the
    --               ENDED transition. Six seconds is that plus room.
    -- coverSweepMs  the SERVER's own deadline for sweeping a player home
    --               without ever hearing from them. Longer than the client's
    --               own wait (which is what normally triggers the report) and
    --               comfortably inside endedSeconds, so CLEANUP is never the
    --               thing that has to rescue it.
    coverWaitMs     = 2500,
    verdictWaitMs   = 6000,
    coverSweepMs    = 8000,

    -- Default mode when a player queues without choosing.
    defaultMode     = 'solo',

    -- Squads
    autofill        = true,   -- fill partial squads with solo queuers
    maxSquadSize    = 4,

    -- A squad match needs somebody to fight. One squad means the win condition
    -- is already satisfied at the starting gun, which reads as "the match ended
    -- the instant it began". Dev mode drops to 1 so a two-client test can force
    -- a match through; set autofill = false to test as two one-player squads.
    minSquads       = 2,
    minSquadsDev    = 1,

    -- How long the queue waits for an incomplete party before starting the
    -- match without its stragglers (who can still late-join during warmup).
    -- Zero patience started matches on the first Ready; infinite patience
    -- hands one AFK partymate the whole lobby.
    partyGraceSeconds = 45,

    -- THE LOBBY IS A CHARACTER SHOT NOW, not a landscape.
    --
    -- It used to be an empty vista with the player invisible in it: a menu
    -- with a view. Standing YOUR ped in frame is what makes the locker and
    -- the ped picker possible at all, and it is what every battle royale does
    -- with this screen -- the thing you are about to play as, looking back at
    -- you (user, 2026-08-08).
    --
    -- Everyone stands on this exact spot, in the SAME routing bucket, and
    -- each client hides every OTHER lobby ped locally (client/squadmates.lua)
    -- -- so nobody's character walks through your shot while the bucket stays
    -- shared. A per-player bucket would have done the same job and cost the
    -- one thing the shared bucket buys: players in the lobby can still be
    -- reached by anything that addresses the lobby as a place.
    lobbyPos        = { x = 5039.27, y = -5721.95, z = 17.08, heading = 208.31 },

    -- THE LOBBY CAMERA. Locked, because a lobby camera the player can swing
    -- is a lobby camera pointed at the sky within ten seconds.
    --
    -- `dist` is the user's six feet, in metres, measured along the ped's OWN
    -- forward vector -- so the camera is always looking the ped in the face
    -- whatever heading the spawn is authored at.
    --
    -- `offset` is the part that is a design decision rather than a
    -- measurement: it slides the AIM point sideways so the ped lands in the
    -- right third of the screen instead of dead centre, because the left
    -- third is the menu (see screens/Lobby.tsx, which reserves exactly that
    -- gap). Aiming off-centre rather than moving the camera keeps the ped
    -- face-on; moving the camera would put them in three-quarter profile.
    --
    -- `fov` is a normal-ish lens. Anything wider at six feet gives the ped a
    -- caricature nose; anything narrower crops them at the chest, which the
    -- locker cannot use.
    -- The heights came down a foot after the first playtest (user,
    -- 2026-08-09): mid-torso put the lens above the character's centre of
    -- mass and the shot read as looking DOWN at them, which is the least
    -- flattering angle a character select can have. The aim drops slightly
    -- less than the camera, so the lens now tilts a touch UP -- the standard
    -- hero framing, and it puts more of the outfit in shot for the locker.
    lobbyCam        = {
        dist   = 1.83,   -- 6 ft in front of the ped
        height = 0.65,   -- camera height above the ped's root
        aim    = 0.68,   -- what it looks at; above `height` => tilted up
        offset = 0.58,   -- aim shifted left => ped sits right of centre
        fov    = 50.0,
    },

    -- Warmup pad: the Cayo Perico airstrip apron. The island is enabled by
    -- br_environment whenever a match is not PLAYING -- if players spawn into
    -- ocean here, that resource is not running (it must be ensured in
    -- server.cfg) or its island switch failed; check the F8 console for
    -- '[br_environment]'.
    --
    -- M3: the Battle Bus departs from this airstrip; its runway runs
    -- (4517.7, -4558.3) -> (4372.2, -4413.2), heading ~315.
    warmupPos       = { x = 4449.0, y = -4482.0, z = 4.3, heading = 315.0 },
    -- Tighter than the old LSIA pad: the airstrip apron is generous but the
    -- island tip is not, and a wide scatter puts players in the surf.
    warmupRadius    = 60.0,

    -- Routing buckets. Lobby and warmup are fixed SHARED buckets; matches
    -- allocate upward from matchBase. The warmup pad is communal (user call,
    -- 2026-08-04): everyone waiting for any flight stands there together and
    -- watches departures -- riders only hop to their match's own bucket a
    -- few seconds after wheels-up (bus.lua schedules it), jumpers the moment
    -- they leave the plane.
    lobbyBucket     = 1,
    warmupBucket    = 2,
    matchBucketBase = 100,

    -- VOICE. FiveM ships its own Mumble server and client, so there is no
    -- third-party voice resource here and none is wanted.
    --
    -- WHAT THE ENGINE DOES NOT DO FOR US: proximity voice is computed from
    -- player POSITIONS, and two matches occupy the same coordinates. Routing
    -- buckets stop players seeing each other; they are not documented to stop
    -- players HEARING each other, and betting a whole match's comms on an
    -- undocumented side effect is how you find out in front of 48 people.
    --
    -- So every match gets its own Mumble channel explicitly. ONE channel per
    -- player -- the match's proximity room -- and squadmates are reached by
    -- NAME instead of by room. See BR.Config.Match.voice.range below and
    -- br_core/client/voice.lua for why the squad room was removed (#157).
    --
    -- Channel numbers are opaque integers to the client. They are derived
    -- from matchId, which is NEVER public (roster.lua PUBLIC_FIELDS), so the
    -- server hands each player their number over VOICE_SET.
    voice = {
        enabled          = true,

        -- ==================================================================
        -- HOW FAR A VOICE CARRIES. TWO NUMBERS, BECAUSE THERE ARE TWO JOBS.
        --
        -- #157: "even when set to nearby (while in squads or solos), the
        -- channel is global." Everybody in the match heard everybody, at any
        -- range, because NOTHING EVER TOLD MUMBLE A DISTANCE. FiveM's Mumble
        -- gates proximity on a distance value the game has to supply
        -- (MUMBLE_SET_AUDIO_INPUT_DISTANCE / _OUTPUT_DISTANCE); with none
        -- supplied there is nothing to gate on and the channel is a party
        -- line. NetworkSetTalkerProximity, which this file used to configure,
        -- belongs to the GAME's own voice chat and Mumble never reads it.
        --
        -- THE ENGINE'S CUTOFF IS BINARY, NOT A CURVE. On the stock convar path
        -- a speaker is either in range at full volume or out of range at
        -- nothing -- there is no fade. `setr voice_useNativeAudio true` in
        -- server.cfg swaps that for the game's own attenuation curves; see the
        -- note in server.cfg.example before turning it on.
        --
        -- WHY THE TWO NUMBERS CANNOT BE ONE. Mumble's distance is a property
        -- of a SPEAKER and a LISTENER, not of a channel: every stream you
        -- receive is gated by the same number whichever room it arrived
        -- through. So "25 m for strangers, the whole map for my squad" is not
        -- expressible as a distance at all. Squadmates get there by a
        -- different door -- a per-player volume override, which the native's
        -- own documentation says "will also bypass 3D audio and distance
        -- calculations" -- and `squad` below is the range at which the client
        -- stops opening that door. Radio, in other words, on top of proximity.
        range = {
            -- Ordinary speech, in metres. Deliberately short: being heard is
            -- a positional tell, and a wide radius turns every rooftop into a
            -- public address system.
            nearby = 25.0,

            -- Squadmates, in metres. THE DEFAULT IS PAST THE MAP DIAGONAL
            -- (8 km x 11.5 km, so ~14 km corner to corner), which means squad
            -- comms never cut out anywhere a player can stand. That is the
            -- point of squad comms and 25 m would not be squad comms.
            --
            -- It is a real cutoff, not a synonym for infinity, so it is worth
            -- knowing what the alternatives buy:
            --   16000  never cuts out. The default.
            --    3500  the opening storm circle (Config.Storm.radius0) --
            --          squad comms cover the play area and no further, so a
            --          squadmate who has not left the bus zone stays reachable
            --          but one who has run to the far coast does not.
            --     100  a "shout" band: squads keep contact through a fight
            --          without a map-wide radio. Harsher, and legitimate.
            squad  = 16000.0,
        },

        -- Channel id bases. Kept far apart and far from 0, which is the
        -- default channel every client starts in.
        lobbyChannel     = 1000,
        warmupChannel    = 1001,
        matchBase        = 2000,   -- + matchId

        -- Whether a squad hears each other beyond `range.nearby` at all. Off
        -- means squads are proximity-only, which is a legitimate (harsher)
        -- design and one edit away: no squad routing is stated and no volume
        -- override is opened, so a squadmate is exactly as audible as any
        -- other player standing where they stand.
        squadIsGlobal    = true,
    },

    -- HEALTH UNITS -- read this before touching any health number anywhere.
    --
    -- There are two scales in play and mixing them is the most likely source of
    -- a subtle balance bug in this project:
    --
    --   ENGINE health  100..200, where 100 means dead for a player ped. This is
    --                  what GetEntityHealth and SetEntityHealth speak.
    --   DISPLAY health 0..100, what the player sees and what every gameplay
    --                  number in config uses (consumables, DBNO revive HP).
    --
    -- Everything in config/*.lua is DISPLAY units. Convert at the engine
    -- boundary with BR.ToEngineHp / BR.ToDisplayHp -- never inline the arithmetic.
    --
    -- THE FLOOR IS 100, the convention after all. A 2026-08-02 note here
    -- claimed an in-game verification of floor 0 -- that verification misread
    -- a corpse: GetEntityHealth returns 0 AFTER death, so a dead body "proves"
    -- 0 while the living range never actually dips below 100. The live
    -- measurement that settled it (2026-08-04): a player died with the health
    -- bar at exactly 50%, which under a 0..200 display mapping is precisely
    -- the engine-100 death threshold announcing itself.
    maxHealth       = 200,    -- engine units
    healthFloor     = 100,    -- engine units; at or below this a player ped is dead
    maxArmour       = 100,    -- armour is already 0..100 natively, no conversion

    -- DBNO (squads only -- solo has nobody who could revive you).
    dbnoBleedBase   = 45,     -- seconds on the first knock
    dbnoBleedStep   = -8,     -- each subsequent knock in the same match is shorter
    dbnoBleedMin    = 15,
    dbnoReviveTime  = 8.0,    -- seconds of held interact
    dbnoReviveDist  = 1.5,
    dbnoReviveHp    = 30,     -- displayed HP after a successful revive

    -- WHAT SHOOTING A DOWNED PLAYER DOES (owner's call, 2026-08-09): it takes
    -- time off the bleed rather than health off a second health bar. There is
    -- no knocked-HP pool, because the bleed timer already IS the downed
    -- player's health -- denominated in seconds, visible to them as a
    -- countdown, and visible to everyone else as a body still crawling.
    --
    -- THE NUMBER IS A GUESS AND IS WRITTEN DOWN AS ONE, like the molotov's 42.
    -- At 0.35 a 30-damage rifle round takes 10.5s off a fresh 45s knock -- four
    -- rounds finish it -- and a shotgun blast (~90) takes 31s. That feels right
    -- on paper and has never been played. Tune it before defending it.
    dbnoBleedPerDamage = 0.35,

    -- The display health the LEDGER holds a downed player at. It has to be
    -- greater than zero for two separate reasons and both are load-bearing:
    -- BR.Damage.applyHit only sends the shooter their `netId`/`hp` correction
    -- while the victim's hp is above zero (that correction is what stops a
    -- downed player reading as a permanent corpse on the shooter's screen),
    -- and the roster's own health sampling would otherwise see a zero and hand
    -- the server-observed death check a body to eliminate.
    dbnoHp          = 5,

    -- Slack on the SERVER's revive distance check, in metres. Positions are
    -- sampled at 250ms, so the server's idea of where two players are standing
    -- is always slightly behind the client's -- the same skew the loot claim
    -- check allows for, for the same reason.
    dbnoReviveSlack = 1.0,

    -- How long the server keeps a revive alive without hearing from the client
    -- holding it. The client re-asserts every 250ms; three misses drops it.
    -- This exists because a single lost REVIVE_STOP once handed out a completed
    -- eight-second hold for a brief tap -- progress has to require continuous
    -- evidence rather than trusting one message to arrive.
    dbnoReviveBeatMs = 750,

    -- The crawl. Metres per second and degrees per second: none of the downed
    -- animations this build has is a locomotion clipset, so client/dbno.lua
    -- drives the ped by hand and these are real units rather than a multiplier
    -- on a walk that is not happening.
    dbnoCrawlSpeed  = 0.55,
    dbnoTurnRate    = 90.0,

    -- How high above the body the revive prompt floats. Low, because the body
    -- is lying down -- at the standing 0.9 it hovered well clear of the player
    -- it belonged to (owner, in game).
    dbnoPromptLift  = 0.35,

    -- Server-side sampling and broadcast rates. These are the knobs to turn if
    -- the server tick starts running long at full player count.
    posSampleHz     = 2,
    deltaFlushHz    = 4,
    digestHz        = 2,

    -- Kill attribution: how long after taking damage a player still counts as
    -- having been killed by the attacker, so storm or fall damage finishing a
    -- wounded player still credits the shooter.
    assistWindowMs  = 10000,
}

-- Ambient world life inside matches, as fractions of GTA's defaults. The
-- routing-bucket population flag is the on/off switch (roster.applyBucket);
-- these throttle the amount, per-frame in gamerules. Parked cars run full
-- -- they are scenery and, eventually, loot context.
BR.Config.Ambient = {
    peds         = 0.3,
    scenarioPeds = 0.3,
    -- Raised from 0.19 (user, 2026-08-05: more vehicles, on and off road).
    -- A battle royale needs rotation: a circle two kilometres away with no
    -- car in sight is a walk, not a decision. Still well under vanilla, which
    -- fills the freeway bumper to bumper.
    vehicles     = 0.45,
    -- Parked cars are where OFF-ROAD vehicles actually come from -- GTA's
    -- density natives cannot filter by class, and the roaming traffic model
    -- is overwhelmingly city cars on city roads. Full density means every
    -- farm, quarry and trailhead has its own truck standing in it.
    parked       = 1.0,
    -- Ambient drivers drive BADLY: zero ability, maximum aggression --
    -- the apocalypse does not produce calm commuters.
    erratic      = true,

    -- HOW BADLY. The first pass used style 786468 at 30 m/s and still read as
    -- calm, and the reason is in the flags: 786468 is
    -- avoid-vehicles + avoid-objects + shortest-path + stay-on-road, so a
    -- "rushed" driver still politely drove round everything in its way.
    --
    -- 262656 is shortest-path (262144) + allow-wrong-way (512) and NOTHING
    -- else. What is missing is the point: no stopping at lights, no avoiding
    -- vehicles, no avoiding peds, no avoiding objects. They take the quickest
    -- line to wherever they are going and drive through whatever is on it.
    --
    -- Paired with ability 0.0 (worst possible driver) and aggression 1.0,
    -- which together decide how much they oversteer and how willingly they
    -- ram. Deliberately NOT panic: peds fleeing gunfire is a different system
    -- and not what is wanted here (user, 2026-08-07) -- these are commuters
    -- who drive like maniacs, not civilians running for their lives.
    erraticStyle      = 262656,
    erraticSpeed      = 45.0,    -- m/s cruise target (was 30)
    erraticAbility    = 0.0,     -- 0 = worst driver in Los Santos
    erraticAggression = 1.0,
    erraticRange      = 250.0,
    -- Re-tasked this often rather than once ever: the engine replaces a ped's
    -- task on collisions and arrivals, and a driver that reverts stays calm
    -- for the rest of its life.
    erraticRetaskMs   = 8000,
}

-- Sprint stamina, Fortnite-shaped: a meter that drains while sprinting and
-- recharges after a beat off the key. OUR meter is the only limiter -- GTA's
-- own stamina stat is kept topped up (running it dry drains HEALTH, which
-- has no place here). Client-side and cosmetic-plus-controls only; nothing
-- about it crosses the wire.
BR.Config.Stamina = {
    max          = 100.0,
    -- 12.5 was ~8 seconds of sprint, which a second playtester called too
    -- short (2026-08-07). 6.5 gives about 15 -- long enough to cross a street
    -- and break line of sight, which is what the meter is for, without making
    -- it free.
    -- 100 / 7.8: cut 35% off the twelve-second version (user, 2026-08-07).
    -- The meter is for breaking line of sight, not for crossing a district.
    drainPerSec  = 12.82,
    regenPerSec  = 25.0,   -- ~4 seconds to refill
    regenDelayMs = 900,    -- breath caught before the refill starts
    minToSprint  = 15.0,   -- an emptied meter must climb back here to sprint
}

--- Resolve the minimum players to start, honouring dev mode.
--- @param devMode boolean
--- @return integer
function BR.Config.Match.MinPlayers(devMode)
    if devMode then
        return BR.Config.Match.minToStart
    end
    return BR.Config.Match.minToStartProd
end

--- Resolve the minimum number of squads a squad match needs, honouring dev mode.
--- @param devMode boolean
--- @return integer
function BR.Config.Match.MinSquads(devMode)
    if devMode then
        return BR.Config.Match.minSquadsDev
    end
    return BR.Config.Match.minSquads
end

-- Health conversion. The only two places that know about the engine's offset.

--- Display health (0..100) -> engine health.
--- @param display number
--- @return integer
function BR.ToEngineHp(display)
    local M = BR.Config.Match
    local span = M.maxHealth - M.healthFloor
    local v = M.healthFloor + BR.Clamp(display, 0.0, 100.0) * (span / 100.0)
    return math.floor(v + 0.5)
end

--- A display-unit DELTA (damage or heal amount) -> engine units. Deltas scale
--- by the span only -- no floor offset, that is for absolute values.
--- @param display number
--- @return number  engine delta, NOT rounded (callers decide how to carry fractions)
function BR.ToEngineHpDelta(display)
    local M = BR.Config.Match
    return display * (M.maxHealth - M.healthFloor) / 100.0
end

--- Engine health -> display health (0..100).
--- @param engine number
--- @return number
function BR.ToDisplayHp(engine)
    local M = BR.Config.Match
    local span = M.maxHealth - M.healthFloor
    if span <= 0 then return 0.0 end
    return BR.Clamp((engine - M.healthFloor) * (100.0 / span), 0.0, 100.0)
end

--- Is this engine health value a dead player ped?
--- @param engine number
--- @return boolean
function BR.IsDeadHp(engine)
    return engine <= BR.Config.Match.healthFloor
end

--- M6 combat validation.
---
--- THE SEQUENCING THAT GOT US HERE, kept because it is the reusable part.
--- FiveM's weaponDamageEvent payload is not documented anywhere authoritative,
--- so nothing was enforced until real payloads had been recorded with
--- /brdamagelog and the field names were facts rather than guesses. Then the
--- validator ran in log-only mode for a full playtest, on the rule that every
--- refusal printed during honest play is a FALSE POSITIVE. That log came back
--- empty (2026-08-07), which is what unlocked both flags below.
---
--- Guessing the field names and shipping enforcement on top of them is exactly
--- the pattern that cost this project six rounds on the ammo counter.
--- WHAT A MATCH REMEMBERS ABOUT A PLAYER, so an incident can carry evidence
--- rather than only an accusation.
---
--- Held in memory and discarded when the match leaves the registry. Nothing is
--- written to a database unless an incident is filed (owner call, 2026-08-14),
--- so a clean match -- nearly all of them -- costs one table and no DynamoDB
--- traffic.
---
--- Bounded because 100 players times an unbounded chat log is a memory leak with
--- a nice name. The caps are the last N, not the first N: the recent lines are
--- the ones that explain an incident, the early ones are the bus ride.
BR.Config.Evidence = {
    chatMax = 50,
    killMax = 30,
}

BR.Config.Combat = {
    -- Both ON as of 2026-08-07: a full playtest produced no "shot refused"
    -- lines, which is the false-positive gate this was waiting for.
    -- `/brdamage off` backs BOTH out live, without a redeploy -- flipping the
    -- takeover changes every gunfight at once and the failure mode is the kind
    -- you want to leave in one command rather than one deploy.
    enforce       = true,
    applyOwnDamage = true,
    logHits       = false,

    -- THE SERVER COUNTS THE ROUNDS NOW. Every shot arrives as a validated
    -- server event, so it can simply be counted -- which retires the M5
    -- placeholder where the client reported its own magazine and the server
    -- believed any decrease. With this on, INV_AMMO is refused outright and
    -- the reload is the server's too.
    --
    -- Backed out by `/brdamage off` along with the rest of the takeover: if
    -- the server stops applying damage it also stops seeing shots, and a gun
    -- whose magazine nothing decrements is better than one nothing refills.
    serverAmmo    = true,

    -- WHAT A REFUSAL DOES, beyond being cancelled.
    --
    -- A stream of refusals is a real signal rather than noise: the validator
    -- ran in log-only mode for a full playtest on the rule that every refusal
    -- during honest play is a FALSE POSITIVE, and that log came back empty. So
    -- somebody generating a dozen in half a minute is doing something the
    -- server did not issue them the means to do.
    --
    -- TIGHTENED TO 8 IN 10s (user call, 2026-08-08), from 12 in 30s.
    --
    -- The looser window was chosen when nothing had been measured. Since then
    -- a full playtest has produced no false positives at all, and separating
    -- rules refusals from means refusals took the ordinary-play noise out
    -- entirely -- so the countable stream is now only things with no honest
    -- explanation, and eight of those inside ten seconds is a decision rather
    -- than a bad minute.
    --
    -- THERE IS NO `refusalAction` ANY MORE (owner call, 2026-08-14). It read
    -- "log" | "notify" | "kick" and decided what the SERVER would do to the
    -- player on its own. Crossing the threshold now files an incident with the
    -- match's evidence attached and stops there; Ringmaster reads the case and
    -- decides, because it is the side that holds the ban list, the audit log
    -- and a human. A convar that still named an enforcement action would be
    -- describing a decision this file no longer makes.
    --
    -- PER MATCH, NOT PER WINDOW, AND GRADED (owner call, 2026-08-14).
    --
    -- `refusalLimit = 8` inside a rolling ten seconds is gone. The owner's verdict
    -- on it was blunt and correct: "we don't want a system that virtually never
    -- creates incidents". Eight of anything inside ten seconds describes somebody
    -- spraying with a trainer and misses somebody careful, and since the countable
    -- stream has no honest explanation at all there was never a reason to demand
    -- eight of it.
    --
    -- So the count is per MATCH -- it no longer lapses after ten seconds -- and the
    -- bar depends on how bad the reason is:
    --
    --   high    1   the server never issued the means. One is enough.
    --   normal  2   a number the weapon does not have. Real, but position
    --               sampling and a bad tick can manufacture one, so not one.
    --
    -- Which reason sits in which tier lives in BR.ShotTier (combat_solve.lua),
    -- beside the refusal enum it keys on, because keying it here would mean
    -- reading BR.ShotRefusal before combat_solve.lua has defined it -- this file
    -- loads first. `NO_WEAPON` carries a per-reason override there and the
    -- reasoning is with it.
    --
    -- SELF IS NO LONGER COUNTED AT ALL. It used to count toward the eight without
    -- earning severity, so that mixing self-harm with real refusals could not keep
    -- somebody under the bar. At a bar of one or two that argument inverts: one
    -- self-hit plus one marginal out-of-range shot would open a case, and a player
    -- could manufacture one against themselves. It is still refused and still
    -- logged; it simply no longer contributes.
    refusalBar = { high = 1, normal = 2 },

    -- KEPT, BUT NO LONGER A THRESHOLD INPUT. The summary line on an incident reads
    -- "N shots refused in Ms", and this is the M. Nothing decides anything on it.
    refusalWindowMs = 10000,

    -- HURTING YOURSELF IS ALLOWED; DOING IT REPEATEDLY IS NOT.
    --
    -- You can stand in your own grenade, and refusing that outright made
    -- explosives free to spam at your own feet. But a player taking damage
    -- from themselves three times in five seconds is exercising a path rather
    -- than playing, so the third one is refused and counted.
    selfLimit    = 2,
    selfWindowMs = 5000,

    -- ONE SWING, ONE HIT. A melee attack is an animation with several contact
    -- points and the engine may raise more than one event for it -- which is
    -- how a punch came to apply our damage twice. Duplicates inside this
    -- fraction of the weapon's own swing cycle are cancelled without being
    -- applied. Melee only: a rifle at 85ms is genuinely several hits.
    meleeDedupe  = 0.5,

    -- `damageType` IS NOT A DISCRIMINATOR, AND THIS IS THE EVIDENCE.
    --
    -- The plan was to gate the takeover on damageType. Measured with
    -- /brdamagelog:
    --
    --   bullet     WEAPON_CARBINERIFLE  damageType 3   (2026-08-06)
    --   melee      WEAPON_UNARMED       damageType 3   (2026-08-08)
    --   explosion  WEAPON_GRENADE       damageType 3   (2026-08-08)
    --   melee      WEAPON_UNARMED       damageType 1   (2026-08-08, later)
    --
    -- Three different things share 3, and one of them ALSO reports 1. The
    -- field says nothing reliable about what happened -- and gating on it meant
    -- a punch fell through to the engine, which applied GTA's own melee damage
    -- ON TOP of ours and killed a full-health player in two hits.
    --
    -- The gate is gone. `weaponType` decides, against three tables:
    -- WeaponByHash (ours -> validate and apply), Environmental (the world's ->
    -- always the engine's, so a car fire or a fall is never a refusal), and
    -- neither (a weapon nobody was issued -> the only thing worth refusing).
    -- Chasing damageType with a longer list of numbers would have left every
    -- gap in that list as a damage path handed silently back to the client.
    --
    -- Kept as a record of what was measured. Nothing reads it.
    damageTypesSeen = { 1, 3 },

    -- FIRE IS THE ENGINE'S, AND WE CANNOT HAVE IT.
    --
    -- Measured 2026-08-08: /brdamagelog armed for 15 payloads, a molotov
    -- thrown at a player, the player DIED, and not one payload printed.
    -- Burning damage does not raise weaponDamageEvent at all -- it is applied
    -- on the victim's own machine through a path the server never sees.
    --
    -- Which means our molotov `damage` number can never apply, and worse: a
    -- molotov kill was credited to NOBODY, because attribution reads the
    -- ledger and nothing ever wrote to it.
    --
    -- So explosions are attributed from a different event entirely.
    -- `explosionEvent` DOES fire server-side, carries the thrower and the
    -- position, and fires for grenades, sticky bombs and molotovs alike. We
    -- cannot take the damage over; we can absolutely say whose it was.
    --
    -- Types are GTA's own explosion enum. Only the three this gamemode issues
    -- are claimed: a petrol pump going up is not somebody's kill.
    explosionTypes = {
        [0]  = 'grenade',
        [2]  = 'sticky',
        [3]  = 'molotov',
    },
    -- How long a fire keeps crediting the person who lit it. Molotov flames
    -- burn for a good while and a player who runs through them ten seconds
    -- later was still killed by whoever threw it. Attribution only lands on
    -- players who are ACTUALLY LOSING HEALTH inside the radius, so a generous
    -- window costs nothing.
    fireLifeMs     = 20000,
    fireRadius     = 6.0,
    -- Blast attribution is instant and short: the bang either caught you or
    -- it did not.
    blastAttributeMs = 1200,

    -- HOW LONG A THROWN EXPLOSIVE STAYS YOURS.
    --
    -- A grenade goes off a second or more after it leaves the hand, and
    -- throwing the last one empties the slot -- so the validator cannot ask
    -- "are you holding a grenade" when the blast lands. It asks whether the
    -- server watched you spend one recently instead.
    --
    -- This is not the security boundary; the inventory is. Nobody reaches this
    -- check without the server having issued them the explosive and seen the
    -- count fall. The window only stops that credit lasting the whole match.
    --
    -- Generous because the alternative is refusing honest kills: 30s covers a
    -- grenade cook, a bounce, and a sticky bomb stuck to a car that the thrower
    -- waits to detonate. A sticky left longer than this is refused, which is
    -- the one known limitation and is bounded by how rare stickies are.
    explosiveGraceMs = 30000,

    -- Slack, and it is load-bearing. Roster positions are sampled at 2Hz, so
    -- at the instant of a shot both players can be half a second stale --
    -- about 4.5m each at a sprint. Refusing an honest shot is a broken game;
    -- accepting a marginal one is a rounding error no aimbot can exploit.
    rangeSlack    = 1.35,   -- multiplier on the weapon's authored maxRange
    rangeSlackM   = 12.0,   -- ...plus this, for the sampling lag itself
    intervalSlack = 0.6,    -- a shot may arrive this fraction early

    headshotMult  = 2.0,

    -- How many payloads /brdamagelog captures before it stops on its own. It
    -- prints every key it sees, so this is the tool that replaces guessing.
    logSamples    = 15,
}

--[[
    PLAYER REPORTS.

    The second source of incidents, after the anticheat. The anticheat sees what
    it can measure; a player sees teaming, griefing and abuse, none of which
    leave a trace in a damage ledger.

    THE CATEGORIES ARE DELIBERATELY SHORT, and "name" is not one of them (owner,
    2026-08-12): we do not control names, so a category we cannot act on would
    only teach players that reporting does nothing. Every option here is
    something an admin can actually do something about.

    THIS EXACT LIST IS THE OWNER'S, given verbatim in #143 (2026-08-16) and in
    this order. It is shorter than the one it replaces by one entry and the
    swap is not cosmetic:

      * `teaming` and `griefing` are GONE and `power_gaming` stands where both
        of them stood. The pair were two names for the same complaint -- an
        admin opening either had to read the case to find out which had been
        meant -- and the split bought nothing, because the action on both is
        the same conversation with the same player.
      * `power_gaming` is the term the server's own community already uses for
        it, so the word on the report is the word an admin will use in the
        reply.

    THE IDS ARE WHAT REACHES THE DATABASE, not the labels, and they are what a
    console query filters on. Renaming one silently orphans every row filed
    under the old spelling -- rows already written keep `teaming`, and nothing
    here rewrites them, which is correct: a record of what somebody actually
    reported must not be edited by a config change.

    A DEFAULT IS PRE-SELECTED, because a report filed with no category is still
    worth having and a required field is how you get "asdf". `cheating` is the
    default because it is both the most common and the one most worth a human
    looking at.

    RATE LIMITS ARE NOT OPTIONAL. This feature is, by construction, a way for
    any player to make the server write to DynamoDB on demand. The limits are
    per match and enforced server-side.

    THE PANEL NO LONGER ADVERTISES THEM (owner, #142: "We don't need to tell a
    player how many people they can report, or how many reports are left").
    They are enforced exactly as hard as they were; the difference is that a
    player discovers a limit by being told the reason it refused, rather than
    by reading a running total they never asked for.

    REPORT SPAM IS ITSELF A SIGNAL and is kept rather than discarded -- the
    console's "reports they filed against others" section exists precisely so
    somebody who reports everybody is visible. A refused-for-rate report is
    still counted, because the attempt is the signal.

    THERE IS NO `maxNote`, AND NO NOTE. It was deleted with #142 ("We don't
    need a custom text field for reports. Just the dropdown"), and it turns out
    it had never done anything: br_ddb has written `note: null` unconditionally
    since 2026-08-14 ("NO FREE-TEXT NOTE, EVER, FROM THE GAME") -- so a cap on
    a string that reached a page, a callback, a net event, an incident payload
    and then a hard null was three layers of plumbing around a value the
    database was already throwing away.
]]
BR.Config.Report = {
    categories = {
        { id = 'cheating',     label = 'Cheating',     default = true },
        { id = 'abusive_chat', label = 'Abusive chat' },
        { id = 'exploiting',   label = 'Exploiting' },
        { id = 'power_gaming', label = 'Power gaming' },
        -- LAST, whatever else moves. "Something else" is the option a player
        -- picks after failing to find theirs, so it has to be the one they
        -- arrive at rather than the one they meet on the way.
        { id = 'other',        label = 'Something else' },
    },

    --- Players nameable in one submission.
    maxTargets = 5,

    --- Submissions per player per match.
    ---
    --- NOT THE SAME LIMIT AS "one report per target per match" (#143), and both
    --- are live. This one bounds how many times a player can make the server
    --- write to a database; the other bounds how many times one accusation can
    --- be made to count twice. Neither implies the other: three submissions of
    --- five distinct targets is fifteen reports and is fine, and two
    --- submissions naming the same person is one report and is refused.
    maxPerMatch = 3,
}

--- The category to pre-select, resolved from the table above rather than
--- repeated as a string that could drift out of the list.
--- @return string
function BR.Config.defaultReportCategory()
    for _, c in ipairs(BR.Config.Report.categories) do
        if c.default then return c.id end
    end
    return BR.Config.Report.categories[1].id
end

--- Is this a category the server will accept?
--- @param id string
--- @return boolean
function BR.Config.isReportCategory(id)
    for _, c in ipairs(BR.Config.Report.categories) do
        if c.id == id then return true end
    end
    return false
end

--- weaponDamageEvent's `hitComponent`, decoded.
---
--- CONFIRMED IN GAME, 2026-08-07. The community mapping was suspect until a
--- deliberate headshot came back as component 20 -- exactly where the table
--- says HEAD is -- alongside a one-shot kill. Earlier samples at 0, 14 and 17
--- (pelvis, left wrist, right elbow) are consistent with spraying at a moving
--- target, so the table is taken as correct.
---
--- This is what makes damage-by-bone possible: the payload tells us WHERE the
--- round landed, so a leg hit and a headshot need not be worth the same thing.
BR.Config.HitComponent = {
    PELVIS       = 0,
    LEFT_HIP     = 1,  LEFT_LEG      = 2,  LEFT_FOOT    = 3,
    RIGHT_HIP    = 4,  RIGHT_LEG     = 5,  RIGHT_FOOT   = 6,
    LOWER_TORSO  = 7,  UPPER_TORSO   = 8,  CHEST        = 9,
    UNDER_NECK   = 10,
    LEFT_SHOULDER = 11, LEFT_UPPER_ARM = 12, LEFT_ELBOW = 13, LEFT_WRIST = 14,
    RIGHT_SHOULDER = 15, RIGHT_UPPER_ARM = 16, RIGHT_ELBOW = 17, RIGHT_WRIST = 18,
    NECK         = 19,
    HEAD         = 20,
}

--- Is this hit component a headshot?
--- @param c integer|nil
--- @return boolean
function BR.Config.IsHeadshot(c)
    local H = BR.Config.HitComponent
    return c == H.HEAD or c == H.NECK or c == H.UNDER_NECK
end

--- Damage multiplier by body part.
---
--- THIS IS A BALANCE DECISION, AND IT IS A DEPARTURE FROM GTA. The captured
--- headshot is the evidence: a Mini SMG whose base damage we call 23 reported
--- `weaponDamage 234` and killed outright. GTA's own headshot multiplier is
--- effectively lethal for any weapon -- one round anywhere near the head ends
--- a fight regardless of what the gun is.
---
--- A battle royale generally does not want that. Fortnite headshots are a
--- large multiplier, not an instant kill, because a mode built on looting has
--- to let a player who found armour and a good gun survive one unlucky round.
--- So headshots hurt a great deal and still leave a fight to win.
---
--- Sniper rifles get there anyway through raw damage: a Heavy Sniper at 216
--- base times 2.0 is far past any health pool, which is the right place for a
--- one-shot to live.
---
--- Keyed by hitComponent; anything unlisted is 1.0.
--- TWO HEADSHOTS TO KILL (user call, 2026-08-07), and 2.5 is the arithmetic
--- of that rather than a taste. Health is 100 display units, so "two shots"
--- means a headshot must land in (50, 100]:
---
---     Mini SMG   23 x 2.5 =  58   -> 2 headshots
---     Pistol     26 x 2.5 =  65   -> 2
---     Carbine    32 x 2.5 =  80   -> 2
---     Revolver   97 x 2.5 = 243   -> 1, and a hand cannon should
---     Heavy Sniper 216 x 2.5      -> 1, which is where one-shots belong
---
--- So the rule holds for every automatic weapon and sidearm, and the two
--- weapons that break it are the two that are supposed to.
BR.Config.BodyMult = {
    [BR.Config.HitComponent.HEAD]        = 2.3,
    [BR.Config.HitComponent.NECK]        = 1.8,
    [BR.Config.HitComponent.UNDER_NECK]  = 1.8,

    -- Centre mass is the honest target: full damage, and the biggest area on
    -- the model. Everything below it is a consolation prize.
    [BR.Config.HitComponent.CHEST]       = 1.0,
    [BR.Config.HitComponent.UPPER_TORSO] = 1.0,
    [BR.Config.HitComponent.LOWER_TORSO] = 0.95,
    [BR.Config.HitComponent.PELVIS]      = 0.95,

    -- LIMBS HURT LESS, and noticeably so (user call, 2026-08-07). Spraying at
    -- a running target and clipping an arm should not trade evenly with
    -- someone who put their rounds in the chest.
    [BR.Config.HitComponent.LEFT_SHOULDER]   = 0.75,
    [BR.Config.HitComponent.RIGHT_SHOULDER]  = 0.75,
    [BR.Config.HitComponent.LEFT_UPPER_ARM]  = 0.65,
    [BR.Config.HitComponent.RIGHT_UPPER_ARM] = 0.65,
    [BR.Config.HitComponent.LEFT_ELBOW]      = 0.55,
    [BR.Config.HitComponent.RIGHT_ELBOW]     = 0.55,
    [BR.Config.HitComponent.LEFT_WRIST]      = 0.50,
    [BR.Config.HitComponent.RIGHT_WRIST]     = 0.50,

    [BR.Config.HitComponent.LEFT_HIP]    = 0.80,
    [BR.Config.HitComponent.RIGHT_HIP]   = 0.80,
    [BR.Config.HitComponent.LEFT_LEG]    = 0.65,
    [BR.Config.HitComponent.RIGHT_LEG]   = 0.65,
    [BR.Config.HitComponent.LEFT_FOOT]   = 0.50,
    [BR.Config.HitComponent.RIGHT_FOOT]  = 0.50,
}

--- A HEADSHOT IS A CLOSE-RANGE PAYOFF (user call, 2026-08-07).
---
--- Landing one across a car park should reward aim; landing one across the
--- map should not simply delete somebody. So the head multiplier is at full
--- strength inside `full` metres and decays to `far` by `fade`, which makes
--- close-quarters aim the thing it rewards rather than range.
---
--- Snipers are untouched by this in the way that matters: a Heavy Sniper hits
--- for 216 to the CHEST, so it remains a one-shot at any distance through raw
--- damage. What this removes is the SMG headshot from 200 metres.
BR.Config.HeadshotRange = {
    full = 30.0,    -- full multiplier at or inside this
    fade = 120.0,   -- decayed to `far` at or beyond this
    far  = 1.25,    -- what a very long headshot is worth
}

--- The multiplier for a hit component. Unknown parts are worth full damage --
--- an unrecognised bone should never silently zero a hit.
--- @param c integer|nil
--- @param dist number|nil  metres; only the head group cares
--- @return number
function BR.Config.BodyMultFor(c, dist)
    if c == nil then return 1.0 end
    local mult = BR.Config.BodyMult[c] or 1.0

    if dist and BR.Config.IsHeadshot(c) then
        local r = BR.Config.HeadshotRange
        local span = (r.fade or 120.0) - (r.full or 30.0)
        if span > 0.0 then
            local t = BR.Clamp((dist - (r.full or 30.0)) / span, 0.0, 1.0)
            -- Never BELOW the far value, and never above the close one: a
            -- head hit is always at least as good as a chest hit.
            mult = BR.Lerp(mult, math.max(r.far or 1.25, 1.0), t)
        end
    end

    return mult
end

--- Descent classification, shared by the BUS ceiling and the stuck-lander net.
---
--- 0.7 m/s sits between the two things that must be told apart: a parachute
--- descends around 2 m/s and clears it comfortably, while a hung client at a
--- frozen altitude reads 0. Freefall is ~50 m/s and was never in doubt -- it
--- was the CANOPY the old per-tick test could not see.
BR.Config.Match.descendRate  = 0.7      -- m/s; below this is not descending
BR.Config.Match.stuckLanderMs = 5000    -- held at one altitude this long -> ALIVE
