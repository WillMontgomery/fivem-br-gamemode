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
    defaultMode     = 'squad',

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

    -- Routing buckets. Lobby is fixed; matches allocate upward from matchBase so
    -- the next lobby can form while the current match finishes.
    lobbyBucket     = 1,
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
