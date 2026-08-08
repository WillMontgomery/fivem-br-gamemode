-- Combat validation, as pure functions.
--
-- M6's job is to stop trusting the client about damage. The mechanism is
-- FiveM's server-side `weaponDamageEvent`, which fires before the damage is
-- applied network-wide and can be refused outright with CancelEvent() -- so
-- the server is genuinely authoritative here, not merely opinionated.
--
-- WHY THIS FILE EXISTS SEPARATELY: the handler itself is unavoidably tangled
-- up in engine payloads and network ids, and none of that can be exercised
-- outside the game. The DECISIONS -- is this shot possible, is this damage
-- plausible, is this cadence physically achievable -- are arithmetic, and
-- arithmetic belongs somewhere it can be tested. Same split as storm_solve.
--
-- Load order: requires enums.lua, geo.lua and config/weapons.lua.

BR = BR or {}

--- Why a shot was refused. Strings rather than numbers so a log line reads.
BR.ShotRefusal = {
    OK          = nil,
    NO_WEAPON   = 'weapon is not one this gamemode issues',
    NOT_HELD    = 'shooter does not hold that weapon',
    NOT_THROWN  = 'shooter did not throw that explosive',
    WARMUP      = 'warmup deals no damage',
    SELF_BLAST  = 'caught in their own blast',
    NO_AMMO     = 'shooter has no rounds for it',
    TOO_FAR     = 'beyond the weapon\'s range',
    TOO_FAST    = 'faster than the weapon can cycle',
    SELF        = 'shooter and victim are the same player',
    SAME_SQUAD  = 'friendly fire',
    NOT_LIVE    = 'one of them is not alive in this match',
    OTHER_MATCH = 'different matches',
}

--- WHICH REFUSALS ARE ACTUALLY A CHEAT SIGNAL.
---
--- Not all of them are, and treating them alike makes the anticheat threshold
--- meaningless. Two categories:
---
---   RULES.  Friendly fire, shooting yourself, shooting during warmup, a shot
---           that raced a match boundary. These are things an HONEST client
---           does constantly -- the game simply declines them. Fists made this
---           urgent: everyone has them at all times, so a warmup scrap now
---           produces a dozen NOT_LIVE refusals in seconds and would trip a
---           threshold built for people using trainers.
---   MEANS.  A weapon the server never issued, a magazine it never filled, a
---           range or a cadence the weapon does not have. There is no honest
---           way to produce these, only a race -- which is why the threshold
---           is a dozen in thirty seconds rather than one.
---
--- Only the second kind counts toward the threshold.
---
--- SELF IS IN THE SECOND LIST, deliberately. A player cannot shoot their own
--- ped in this game -- there is no honest input that produces it -- so a
--- bullet naming the shooter as its own victim is somebody's tooling, not
--- somebody's mistake (user call, 2026-08-08). The one honest way to hurt
--- yourself is your OWN GRENADE, and that arrives as SELF_BLAST instead, which
--- is refused for damage and counted as nothing.
BR.ShotSuspicious = {
    [BR.ShotRefusal.NO_WEAPON]  = true,
    [BR.ShotRefusal.NOT_HELD]   = true,
    [BR.ShotRefusal.NO_AMMO]    = true,
    [BR.ShotRefusal.TOO_FAR]    = true,
    [BR.ShotRefusal.TOO_FAST]   = true,
    [BR.ShotRefusal.NOT_THROWN] = true,
    [BR.ShotRefusal.SELF]       = true,
}

--- Is this shot physically possible, given what the SERVER believes?
---
--- Everything here is checked against the server's own model -- the roster's
--- sampled positions, the inventory it maintains -- never against anything the
--- shooter reported. A client that lies about its weapon, its range or its
--- rate of fire fails against numbers it does not control.
---
--- SLACK IS DELIBERATE AND LOAD-BEARING. Roster positions are sampled at 2Hz,
--- so at the moment of a shot both players may be up to half a second stale --
--- which at a sprint is ~4.5m each. Rejecting an honest shot is far worse than
--- accepting a marginal one: the first is an unplayable game, the second is a
--- rounding error an aimbot cannot exploit. The storm solves the identical
--- problem the same way.
---
--- @param shot table  { weapon = <hash>, dist = <number>, sinceLastMs = <number> }
--- @param ctx table   { heldItem, clip, sameSquad, shooterLive, victimLive,
---                      sameMatch, sameSrc }
--- @param cfg table   BR.Config.Combat
--- @return boolean ok, string|nil why
function BR.ValidateShot(shot, ctx, cfg)
    cfg = cfg or {}

    -- SHOOTING YOURSELF IS NOT A THING YOU CAN DO, except with your own
    -- grenade. Splitting the two matters because one of them is a cheat
    -- signal and the other is Tuesday: there is no input in this game that
    -- makes your own bullet name your own ped, but standing too close to a
    -- blast you threw is ordinary play. Resolved before anything else so the
    -- weapon lookup below can decide which it was.
    if ctx.sameSrc then
        local sw = BR.Config.WeaponByHash[BR.NormHash(shot.weapon or 0)]
        if sw and sw.explosive then
            return false, BR.ShotRefusal.SELF_BLAST
        end
        return false, BR.ShotRefusal.SELF
    end
    if not ctx.sameMatch then return false, BR.ShotRefusal.OTHER_MATCH end

    -- WARMUP IS A PRACTICE PAD, NOT A SAFE ZONE. Nothing stops a player
    -- swinging at somebody on it -- the punch plays, the impact reads -- and
    -- nothing comes off anybody's health (user call, 2026-08-08). Refusing the
    -- damage rather than blocking the input is what makes that true for
    -- everyone: the engine's own hit is cancelled, so a client that thinks it
    -- landed a killing blow is simply wrong, and the ped is resynced.
    --
    -- Checked BEFORE liveness, because WARMUP is not ALIVE and would otherwise
    -- come back as NOT_LIVE -- which reads in a log as a desync rather than as
    -- a rule.
    if ctx.warmup then return false, BR.ShotRefusal.WARMUP end

    if not ctx.shooterLive or not ctx.victimLive then
        return false, BR.ShotRefusal.NOT_LIVE
    end
    if ctx.sameSquad then return false, BR.ShotRefusal.SAME_SQUAD end

    -- Normalised, because weaponDamageEvent reports the hash SIGNED -- the
    -- same trap that gave twenty weapons unlimited ammo. Unnormalised, every
    -- top-bit-set weapon would validate as "not one this gamemode issues",
    -- i.e. half the arsenal would read as a cheat.
    local w = BR.Config.WeaponByHash[BR.NormHash(shot.weapon)]
    if not w then return false, BR.ShotRefusal.NO_WEAPON end

    -- AN EXPLOSION IS NOT A SHOT, and three of the checks below quietly assume
    -- it is. All three would refuse an honest grenade:
    --
    --   HELD.  A grenade detonates a second or more after it leaves the hand,
    --          and throwing your last one empties the slot -- so by the time
    --          the damage event arrives the thrower is holding FISTS. What is
    --          checked instead is that the server issued them that explosive
    --          and saw them spend one, recently. That is a real bound: the
    --          server decides what is in the inventory, so a client cannot
    --          conjure a grenade it was never given.
    --   RANGE. The bound is the throw PLUS the blast. The victim may be a
    --          whole blast radius further from the thrower than the grenade
    --          ever travelled, and the weapon's "range" describes neither.
    --   RATE.  There is no action to cycle. A cluster of stickies detonates
    --          together, and every one of those is a legitimate event in the
    --          same millisecond -- TOO_FAST would refuse all but the first.
    if w.explosive then
        if ctx.heldItem ~= w.id and not ctx.threwRecently then
            return false, BR.ShotRefusal.NOT_THROWN
        end
        local reach = (w.maxRange or 0.0) * (cfg.rangeSlack or 1.35)
                    + (w.blastRadius or 0.0)
                    + (cfg.rangeSlackM or 12.0)
        if (shot.dist or 0.0) > reach then
            return false, BR.ShotRefusal.TOO_FAR
        end
        return true, nil
    end

    -- THE SERVER KNOWS WHAT IT PUT IN THEIR HANDS, AND AN EMPTY SLOT IS AN
    -- ANSWER.
    --
    -- This used to read `if ctx.heldItem and ctx.heldItem ~= w.id`, which
    -- skipped the whole check when the slot was empty -- and that is exactly
    -- the state a weapon from outside the inventory leaves you in. A carbine
    -- conjured by a trainer, fired with no inventory weapon at all, passed
    -- validation and dealt full damage, because nil never disagrees with
    -- anything. It also spent no ammo, since there was no slot to spend from.
    --
    -- Requiring a match in BOTH directions closes it: if the server did not
    -- issue you a weapon, you cannot shoot anyone with one.
    if ctx.heldItem ~= w.id then
        return false, BR.ShotRefusal.NOT_HELD
    end

    -- ...and how many rounds it had. A shot from an empty magazine is either
    -- a desync or a cheat, and either way it is not damage.
    if ctx.clip ~= nil and ctx.clip <= 0 then
        return false, BR.ShotRefusal.NO_AMMO
    end

    -- Range, with slack for stale positions at both ends.
    if w.maxRange then
        local limit = w.maxRange * (cfg.rangeSlack or 1.35)
                    + (cfg.rangeSlackM or 12.0)
        if (shot.dist or 0.0) > limit then
            return false, BR.ShotRefusal.TOO_FAR
        end
    end

    -- Rate of fire. A weapon cannot cycle faster than its own action, and a
    -- macro or a modified weapons.meta is exactly what this catches.
    if w.minInterval and shot.sinceLastMs then
        local floor = w.minInterval * (cfg.intervalSlack or 0.6)
        if shot.sinceLastMs < floor then
            return false, BR.ShotRefusal.TOO_FAST
        end
    end

    return true, nil
end

--- What a hit should take off, in DISPLAY units.
---
--- The server recomputes this from its own tables rather than believing the
--- number in the event -- `weaponDamage` in the payload is whatever the
--- shooter's game said, which is precisely the field a damage multiplier
--- edits.
---
--- DAMAGE VARIES BY BONE, which is the whole reason hitComponent is read.
--- The payload says exactly where the round landed, so a wrist and a head are
--- not worth the same thing -- see BR.Config.BodyMult for the numbers and why
--- they deliberately differ from GTA's own.
---
--- @param weapon integer   weapon hash (signed or unsigned)
--- @param rarity integer|nil
--- @param dist number|nil
--- @param component integer|nil  weaponDamageEvent's hitComponent
--- @param cfg table        BR.Config.Combat
--- @return number damage, number multiplier
function BR.ShotDamage(weapon, rarity, dist, component, cfg)
    cfg = cfg or {}

    -- EXPLOSIONS HAVE NO BONE AND NO FALLOFF. hitComponent came back 0 on the
    -- captured grenade -- a blast does not land on a wrist -- and the distance
    -- the server has is thrower-to-victim, which for a thrown weapon runs the
    -- wrong way (see ExpectedDamage). Flat damage is the honest model until
    -- the server can see where the thing actually landed.
    local w = BR.Config.WeaponByHash[BR.NormHash(weapon)]
    if w and w.explosive then
        return BR.Config.ExpectedDamage(weapon, rarity, nil), 1.0
    end

    local base = BR.Config.ExpectedDamage(weapon, rarity, dist)
    -- Distance goes in twice, and means different things each time: the
    -- weapon's own falloff above, and the headshot's close-range payoff here.
    local mult = BR.Config.BodyMultFor(component, dist)
    return base * mult, mult
end
