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
--- SELF IS IN THE SECOND LIST, but it only ever fires on REPETITION. One
--- self-hit is allowed outright and never reaches here -- standing in your own
--- grenade is ordinary play. Several in a few seconds is somebody exercising
--- something, and that is what this counts.
BR.ShotSuspicious = {
    [BR.ShotRefusal.NO_WEAPON]  = true,
    [BR.ShotRefusal.NOT_HELD]   = true,
    [BR.ShotRefusal.NO_AMMO]    = true,
    [BR.ShotRefusal.TOO_FAR]    = true,
    [BR.ShotRefusal.TOO_FAST]   = true,
    [BR.ShotRefusal.NOT_THROWN] = true,
    [BR.ShotRefusal.SELF]       = true,
}

--- HOW BAD A COUNTABLE REFUSAL IS, which is a different question from whether it
--- is worth recording.
---
--- TWO TABLES RATHER THAN ONE, AND THE DISTINCTION IS LOAD-BEARING.
--- `BR.ShotSuspicious` above means "worth writing down": it gates the per-shot
--- console line and it is pinned by an exhaustive test and by a gate in
--- tools/verify.sh. This one means "worth opening a case about, and how loudly".
---
---   high    The server never issued the means -- a weapon this gamemode does not
---           have, a magazine it never filled, a weapon that is not in the
---           shooter's hands, an explosion from something they never threw. There
---           is no honest path to any of these.
---   normal  A number the weapon does not have: out of range, or cycling faster
---           than its action. Real signals, but the ones with a plausible innocent
---           story -- position sampling plus a bad tick can manufacture either,
---           which is why the validator already carries slack.
---
--- SELF IS DELIBERATELY ABSENT, and it used to be present in the equivalent table.
--- While the bar was eight, SELF had to count toward it: otherwise somebody mixing
--- self-harm with real refusals would stay under and never trip. At a bar of one or
--- two that reasoning inverts -- one self-hit beside one marginal out-of-range shot
--- would open a case, and a player could manufacture one against themselves by
--- standing in their own grenades. It is refused and logged either way; it no
--- longer contributes to anything.
---
--- NOTHING ELSE IS EXCLUDED HERE. The rules -- friendly fire, warmup scraps, a
--- shot that raced a match boundary -- are excluded upstream in
--- `BR.ShotSuspicious`. A second filter for them would be a second place for the
--- rule to live and a second place for it to rot.
BR.ShotTier = {
    [BR.ShotRefusal.NO_WEAPON]  = 'high',
    [BR.ShotRefusal.NOT_HELD]   = 'high',
    [BR.ShotRefusal.NO_AMMO]    = 'high',
    [BR.ShotRefusal.NOT_THROWN] = 'high',
    [BR.ShotRefusal.TOO_FAR]    = 'normal',
    [BR.ShotRefusal.TOO_FAST]   = 'normal',
}

--- Per-reason exceptions to the tier's bar.
---
--- `NO_WEAPON` IS HIGH SEVERITY AND STILL WANTS TWO, which looks inconsistent and
--- is not. The other three high reasons are checked against state the server
--- definitely owns: its own inventory, its own ammunition counter, a throw it
--- watched happen. `NO_WEAPON` is the catch-all -- it means the weapon hash is in
--- neither our table nor the world's -- so its false-positive rate is a function
--- of how complete those two tables are, and a hash added by a future game build
--- or carried by an ambient NPC lands here. Nobody running a conjured weapon fires
--- exactly once, so asking for two costs nothing real and stops one gap in a
--- lookup table becoming one case per occurrence.
BR.ShotBarOverride = {
    [BR.ShotRefusal.NO_WEAPON] = 2,
}

--- How many of this reason, in one match, before a case is opened.
--- @param reason string|nil  a BR.ShotRefusal value
--- @param bar table|nil      BR.Config.Combat.refusalBar
--- @return integer|nil count nil when the reason files nothing at all
--- @return string|nil tier
function BR.ShotBarFor(reason, bar)
    local tier = BR.ShotTier[reason]
    if not tier then return nil, nil end
    -- Defaults to 1 rather than 0 so a missing config cannot mean "file on sight".
    return BR.ShotBarOverride[reason] or (bar and bar[tier]) or 1, tier
end

--- Does this match's tally cross any reason's bar, and how bad is the worst thing
--- in it?
---
--- WORST WINS, WHICH THE FIRST VERSION OF THE OLD THRESHOLD GOT WRONG. A match is
--- a mix, and grading it by the reason that happened to arrive last filed seven
--- conjured-weapon refusals as whatever the eighth was.
--- @param tally table|nil  { [reason] = count } accumulated over the match
--- @param bar table|nil    BR.Config.Combat.refusalBar
--- @return boolean crossed
--- @return string|nil severity  the worst tier present, nil if none
--- @return string|nil reason    the reason that earned that severity
function BR.ShotTallyVerdict(tally, bar)
    if type(tally) ~= 'table' then return false, nil, nil end

    local RANK = { normal = 1, high = 2 }
    local crossed = false
    local worst, worstRank, worstReason = nil, 0, nil

    for reason, n in pairs(tally) do
        local need, tier = BR.ShotBarFor(reason, bar)
        -- A tally entry of zero is a reason that was counted and rolled away, not
        -- a reason present.
        if need and (tonumber(n) or 0) >= need then
            crossed = true
            if RANK[tier] > worstRank then
                worst, worstRank, worstReason = tier, RANK[tier], reason
            end
        end
    end

    return crossed, worst, worstReason
end

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

    -- HURTING YOURSELF IS ALLOWED. DOING IT OVER AND OVER IS NOT.
    --
    -- The first version refused self-damage outright, on the reasoning that
    -- you cannot shoot yourself in this game. That was too strong and the user
    -- pushed back on it: you absolutely can stand in your own grenade, and
    -- refusing it makes explosives free to spam at your own feet in a crowd.
    --
    -- So a single self-hit lands like anybody else's. What stays a red flag is
    -- REPETITION -- a player taking damage from themselves several times in a
    -- few seconds is not playing badly, they are exercising something. That
    -- count is the server's (BR.Damage.noteSelfHit) and arrives as
    -- ctx.selfRepeat; the pure function only decides what to do about it.
    if ctx.sameSrc then
        if ctx.selfRepeat then return false, BR.ShotRefusal.SELF end
        return true, nil
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
