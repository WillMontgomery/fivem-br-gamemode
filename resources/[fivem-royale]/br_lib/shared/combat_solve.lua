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
    NO_AMMO     = 'shooter has no rounds for it',
    TOO_FAR     = 'beyond the weapon\'s range',
    TOO_FAST    = 'faster than the weapon can cycle',
    SELF        = 'shooter and victim are the same player',
    SAME_SQUAD  = 'friendly fire',
    NOT_LIVE    = 'one of them is not alive in this match',
    OTHER_MATCH = 'different matches',
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

    if ctx.sameSrc then return false, BR.ShotRefusal.SELF end
    if not ctx.sameMatch then return false, BR.ShotRefusal.OTHER_MATCH end
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

    -- The server knows what it put in their hands.
    if ctx.heldItem and ctx.heldItem ~= w.id then
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
    local base = BR.Config.ExpectedDamage(weapon, rarity, dist)
    -- Distance goes in twice, and means different things each time: the
    -- weapon's own falloff above, and the headshot's close-range payoff here.
    local mult = BR.Config.BodyMultFor(component, dist)
    return base * mult, mult
end
