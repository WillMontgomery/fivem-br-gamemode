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

    -- The LOBBY: a vista point above Cayo Perico, used as the backdrop
    -- behind the menu. Players in the LOBBY state sit here invisible and in
    -- a PERSONAL routing bucket -- the lobby is a menu with a view, not a
    -- place, so nobody's ped may wander through the shot.
    lobbyPos        = { x = 4798.33, y = -5031.61, z = 36.59, heading = 44.05 },

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
    -- Still defaults to LOG. A validator that has never wrongly refused an
    -- honest player today may still do so the first time a pickup races a
    -- shot, and banning your own players is a worse failure than tolerating a
    -- cheater who is already unable to hurt anyone. "notify" tells them their
    -- shots are not landing; "kick" drops them.
    refusalAction   = "log",      -- "log" | "notify" | "kick"
    refusalLimit    = 12,
    refusalWindowMs = 30000,

    -- WHICH DAMAGE TYPES WE TAKE OVER.
    --
    -- weaponDamageEvent carries every kind of damage, not just gunfire, and
    -- `damageType` says which. Exactly ONE value has been observed in game:
    -- 3, on every captured bullet payload. Melee, explosions, fire, falls and
    -- vehicle impacts all have their own numbers and NONE of them have been
    -- confirmed here.
    --
    -- So the validator takes over the type it knows and PASSES THE REST
    -- THROUGH untouched. That is deliberate, and it is not the same as
    -- ignoring them: refusing an unknown type would mean grenades doing
    -- nothing the moment a thrown weapon reports as something other than a
    -- bullet, and taking one over on a guessed number would apply our damage
    -- table to a fall. Passing through leaves the engine in charge of paths we
    -- have not measured, which is exactly where M5 left them.
    --
    -- /brdamagelog prints damageType on every sample. One melee hit and one
    -- grenade settle this, and then those numbers move into `takeOver`.
    damageTypes = {
        BULLET = 3,     -- CONFIRMED in game, 2026-08-06
    },
    -- Types the validator owns. Anything else is left to the engine and
    -- counted, so an unknown type shows up as a log line rather than as
    -- silence.
    takeOver = { [3] = true },

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
