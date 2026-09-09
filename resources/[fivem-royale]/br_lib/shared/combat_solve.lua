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

--- The furthest a hit from this weapon can be and still be honest.
---
--- ONE DEFINITION, TWO READERS, AND THAT IS THE WHOLE REASON IT IS A FUNCTION.
--- BR.ValidateShot refuses on this number and `/brshots` prints it beside the
--- distance that was measured. A second copy of the arithmetic in the readout
--- would let the printed limit drift away from the enforced one -- and a
--- readout that lies about the bound is worse than no readout, because it
--- turns a wrong limit into a limit that looks right.
---
--- EXPLOSIVES GET A DIFFERENT BOUND, not a bigger slack. The victim may be a
--- whole blast radius further from the thrower than the thing ever travelled,
--- so the sum is throw PLUS blast -- see the note in BR.ValidateShot.
--- @param w table|nil  a BR.Config.Weapon* row
--- @param cfg table|nil BR.Config.Combat
--- @return number|nil  nil when the weapon has no range to exceed
function BR.ShotRangeLimit(w, cfg)
    if not w then return nil end
    cfg = cfg or {}
    if w.explosive then
        return (w.maxRange or 0.0) * (cfg.rangeSlack or 1.35)
             + (w.blastRadius or 0.0)
             + (cfg.rangeSlackM or 12.0)
    end
    if not w.maxRange then return nil end
    return w.maxRange * (cfg.rangeSlack or 1.35) + (cfg.rangeSlackM or 12.0)
end

--- The shortest gap between two shots this weapon can honestly produce.
---
--- NIL FOR AN EXPLOSIVE, deliberately, and it is the same fact the validator
--- states by returning before the rate check: a detonation is not a trigger
--- pull, and a cluster of stickies going off together is several legitimate
--- events in one millisecond.
--- @param w table|nil
--- @param cfg table|nil
--- @return number|nil  nil when nothing about cadence can be refused
function BR.ShotIntervalFloor(w, cfg)
    if not w or w.explosive or not w.minInterval then return nil end
    return w.minInterval * ((cfg or {}).intervalSlack or 0.6)
end

--- The shortest gap between two LAUNCHES of this explosive.
---
--- THE OPPOSITE HALF OF THE FUNCTION ABOVE, AND THE REASON THAT ONE RETURNS
--- NIL. "A detonation is not a trigger pull" is true and it was read as "an
--- explosive has no cadence at all", which is a different claim and a false
--- one. A grenade launcher has an action; it cycles in 600ms; nothing honest
--- fires two rounds from it in the same millisecond. What the impact cadence
--- could not be applied to is the BLAST -- one rocket catching four people is
--- four legitimate events with no gap between them -- and applying the rule to
--- the launch instead costs that nothing (audit finding 3, 2026-09-08).
---
--- NIL FOR A THROWABLE, because none of them authors a minInterval and the
--- bound on throwing is not time: it is that the server watched a grenade leave
--- your hand and has one credit to spend for it. An arm has no action to cycle.
--- @param w table|nil
--- @param cfg table|nil
--- @return number|nil  nil when nothing about launch cadence can be refused
function BR.ShotLaunchFloor(w, cfg)
    if not w or not w.explosive or not w.minInterval then return nil end
    return w.minInterval * ((cfg or {}).intervalSlack or 0.6)
end

--- How long ONE projectile's impacts may go on arriving.
---
--- The window a launch authorization stays open for. Everything inside it is
--- the same blast catching more people and is free; the first impact outside it
--- is a new projectile and has to pay for itself again.
---
--- CAPPED BY THE LAUNCH CADENCE WHERE THERE IS ONE, and that is not a detail. A
--- grenade launcher cycles in 600ms, so a flat 1200ms window would let the
--- SECOND honest round of a pair be absorbed into the first one's authorization
--- -- no round spent, no cadence measured. The window has to close before the
--- weapon can fire again or it swallows the shot it was meant to charge for.
--- @param w table|nil
--- @param cfg table|nil
--- @return number
function BR.ShotBlastWindow(w, cfg)
    cfg = cfg or {}
    -- Defaults to the attribution window, which is the same physical fact
    -- measured for a different purpose: "the bang either caught you or it did
    -- not" (BR.Config.Combat.blastAttributeMs).
    local win = cfg.blastWindowMs or cfg.blastAttributeMs or 1200
    local floor = BR.ShotLaunchFloor(w, cfg)
    if floor and floor < win then return floor end
    return win
end

--- How many DISTINCT players one event may hurt, given what fired it.
---
--- ONE EVENT IS ONE SHOT, AND A SHOT REACHES A BOUNDED NUMBER OF PEOPLE.
--- `hitGlobalIds` is a list the CLIENT composes, so its length is a claim and
--- not a measurement -- and the handler used to apply damage once per entry
--- with no ceiling at all. Three copies of one victim in a pistol event were
--- three hits for one round (audit, 2026-09-08).
---
--- Deduplication alone would not close it: a hundred DISTINCT victims in one
--- event is the same fabrication wearing a different hat, and against a full
--- lobby it is a wipe. So the count is bounded as well, by what the weapon can
--- physically reach.
---
--- THE NUMBERS ARE DELIBERATELY GENEROUS, because the failure direction is not
--- symmetric. Dropping a legitimate victim from a real grenade is a hit that
--- silently did nothing -- the shooter sees a blast and no marker -- and that
--- reads as the game being broken. Accepting one impossible extra victim is a
--- rounding error nobody can build an exploit on. Same reasoning as the range
--- and cadence slack above.
---
---   melee      A swing is one contact. Two is a body that walked into the arc
---              of a machete already travelling; three is not a swing.
---   explosive  A grenade in a squad fight genuinely catches everybody stood
---              together, and the blast radii here run to 12m.
---   firearm    A shotgun raises ONE event for a whole pellet spread, and a
---              round can pass through a body into the one behind it.
--- @param w table|nil  a BR.Config.Weapon* row, nil for a hash we do not issue
--- @param cfg table|nil BR.Config.Combat
--- @return integer
function BR.ShotMaxTargets(w, cfg)
    cfg = cfg or {}
    if w and w.explosive then return cfg.maxBlastTargets or 12 end
    if w and w.melee     then return cfg.maxMeleeTargets or 2  end
    return cfg.maxShotTargets or 6
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
    --
    -- WHAT THAT ARGUMENT LEFT UNGUARDED, AND FOR TWENTY-ONE DAYS NOBODY SAW IT:
    -- all three of those exemptions are about the IMPACT, and skipping them left
    -- nothing at all checking the LAUNCH. Holding an empty grenade launcher --
    -- empty magazine, empty reserve -- authorized damage, repeatedly, at any
    -- rate, for as long as you kept hold of it. The audit's harness hit a victim
    -- twice on the same millisecond with one and neither attempt was refused
    -- (finding 3, 2026-09-08).
    --
    -- So the projectile is authorized rather than the impact, and the two
    -- questions are asked separately:
    --
    --   ctx.blastShared   this impact belongs to a launch the server already
    --                     authorized and is still counting victims for. Four
    --                     people caught by one rocket share one authorization,
    --                     which is exactly the property the three exemptions
    --                     above exist to protect.
    --   otherwise         a NEW projectile, which has to pay for itself: it
    --                     came out of a magazine the server filled, or it was a
    --                     throw the server watched happen and has a credit for.
    if w.explosive then
        if not ctx.blastShared then
            if w.clip then
                -- A LAUNCHER IS IN YOUR HANDS WHEN IT FIRES, unlike a grenade,
                -- so the ordinary held check is the right one and always was.
                if ctx.heldItem ~= w.id then
                    return false, BR.ShotRefusal.NOT_THROWN
                end
            elseif not ctx.threwRecently then
                -- A THROWABLE IS NOT AUTHORIZED BY BEING HELD, and it used to
                -- be: `heldItem == w.id or threwRecently`. Holding grenades
                -- therefore authorized unlimited blasts, because the held half
                -- of that test is true for as long as any remain in the slot and
                -- says nothing whatever about a particular one having been
                -- thrown. The credit does say that, and there is one of them per
                -- grenade the server watched leave the hand.
                return false, BR.ShotRefusal.NOT_THROWN
            end
        end

        if (shot.dist or 0.0) > BR.ShotRangeLimit(w, cfg) then
            return false, BR.ShotRefusal.TOO_FAR
        end

        -- Another victim of a projectile already paid for. Nothing further is
        -- owed: charging again here is precisely the mistake that would refuse
        -- the second, third and fourth person a grenade caught.
        if ctx.blastShared then return true, nil end

        -- A MAGAZINE THE SERVER NEVER FILLED. Read as the magazine stood BEFORE
        -- this event spent from it -- the last rocket in the tube is a rocket,
        -- and the check that fired on the post-spend number would refuse it.
        -- Explicitly `== false` so an unset field means "not applicable" rather
        -- than "empty": a thrown grenade has no magazine to be empty of.
        if ctx.launchAmmo == false then
            return false, BR.ShotRefusal.NO_AMMO
        end

        -- ...and the action still cannot cycle faster than it cycles. Measured
        -- between LAUNCHES, which is why BR.ShotIntervalFloor still says nil for
        -- an explosive and BR.ShotLaunchFloor is a different function.
        local launchFloor = BR.ShotLaunchFloor(w, cfg)
        if launchFloor and ctx.sinceLaunchMs
           and ctx.sinceLaunchMs < launchFloor then
            return false, BR.ShotRefusal.TOO_FAST
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

    -- Range, with slack for stale positions at both ends. Nil limit means the
    -- weapon has no authored range, which is not the same as a range of zero.
    local limit = BR.ShotRangeLimit(w, cfg)
    if limit and (shot.dist or 0.0) > limit then
        return false, BR.ShotRefusal.TOO_FAR
    end

    -- Rate of fire. A weapon cannot cycle faster than its own action, and a
    -- macro or a modified weapons.meta is exactly what this catches.
    local floor = BR.ShotIntervalFloor(w, cfg)
    if floor and shot.sinceLastMs and shot.sinceLastMs < floor then
        return false, BR.ShotRefusal.TOO_FAST
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

-- ---------------------------------------------------------------------------
-- The world's own damage, which is not ours and is still not unconditional
-- ---------------------------------------------------------------------------
--
-- A HASH IS A CLAIM ABOUT THE CAUSE, NOT PROOF THAT THE CAUSE HAPPENED, and
-- until 2026-09-08 the handler read it as proof. `weaponType` landing in
-- BR.Config.Environmental returned before every check in this file -- inventory,
-- state, squad, range, rate, damage value -- and did not cancel the event, so a
-- client-composed payload labelled WEAPON_EXPLOSION with a large damage figure
-- and somebody else's ped in `hitGlobalIds` reached the exit unopposed (audit
-- finding 4).
--
-- WHAT MAKES THIS THE DANGEROUS ONE TO FIX. Falls, fire, drowning and cars are
-- damage this project DELIBERATELY leaves to the engine: it kills the ped
-- outright on the victim's own machine and the server finds out by sampling
-- health (server/combat.lua's server-observed death check, and the note in
-- BR.Combat.defeat about a knock arriving after a corpse). Making environmental
-- damage strict does not make those safe -- it makes a player who falls off a
-- building not die, which is a worse bug than the one being fixed.
--
-- SO THE SHAPE IS A BOUND, NOT A DENIAL, and it rests on what Cfx documents
-- about the event: weaponDamageEvent fires when a client wants to damage a
-- REMOTELY-OWNED entity. Your own fall, your own drowning, your own burning are
-- applied to a ped you own; they are not this event, and where a build raises
-- them anyway they arrive with the sender as their own victim. That case is
-- never refused here, on any hash, for any reason.
--
-- What is left is the genuinely remote kind -- somebody's car exploding next to
-- you, somebody running you over, somebody's fire -- and every one of those
-- requires the two of them to be in the same match and near each other. That is
-- a fact the server holds from its own 2Hz sampling and the client does not
-- control, which is what makes it a boundary rather than a second claim.

--- Why an environmental claim was refused. Deliberately NOT members of
--- BR.ShotRefusal.
---
--- THE INCIDENT SURFACE IS PINNED BY A GATE AND BY AN EXHAUSTIVE TEST, and both
--- of them are right to be: a reason quietly added to BR.ShotSuspicious starts
--- opening cases somebody has to review. These are a different question -- was
--- this event the world's -- reached by a different path, and they cancel
--- without accusing anybody. Wiring them into the anticheat feed is a decision
--- worth taking on its own evidence rather than as a side effect of closing a
--- hole; until then a refused environmental claim is counted and printed to the
--- server console, which no player reads.
BR.EnvRefusal = {
    NO_SENDER   = 'the sender is not in a match',
    OTHER_MATCH = 'the world does not reach into another match',
    NOT_LIVE    = 'the victim is not alive in this match',
    TOO_FAR     = 'too far apart for the world to have done it',
    TOO_BIG     = 'more damage than the world deals',
    TOO_OFTEN   = 'more of these than the world produces',
    BAD_POS     = 'an explosion nowhere',
    NOT_OURS    = 'an explosive the server never issued',
}

--- How far a cause of each kind can honestly reach across two SAMPLED
--- positions.
---
---   own      A fall, drowning, exhaustion, bleeding. These are computed on the
---            ped they happen to, so a REMOTE one is already odd -- the honest
---            residue is a passenger drowning in somebody else's car, which is
---            a distance of nearly zero. Bounded tightly rather than refused,
---            because "already odd" is not the same as impossible and this file
---            has been wrong about that before.
---   contact  A car, an animal, rotors, a fence. The two entities have to have
---            touched.
---   area     An explosion, a fire, a flare. The blast has a radius and neither
---            end of it is a position the server can see, so this one is
---            generous on purpose.
---
--- ANYTHING NOT LISTED IS `contact`, which is the strictest of the three that
--- can still happen between two players. A hash added by a future game build
--- lands there and is bounded rather than exempt -- the opposite of the default
--- that produced this finding.
BR.EnvClass = {
    fall       = 'own',
    drown      = 'own',
    drownveh   = 'own',
    exhaustion = 'own',
    bleeding   = 'own',
    explosion  = 'area',
    fire       = 'area',
    flare      = 'area',
}

--- @param env table|nil  a BR.Config.Environmental row
--- @param cfg table|nil  BR.Config.Combat
--- @return number
function BR.EnvReach(env, cfg)
    cfg = cfg or {}
    local class = env and BR.EnvClass[env.id] or 'contact'
    if class == 'area' then return cfg.envAreaM or 60.0 end
    if class == 'own'  then return cfg.envOwnM  or 12.0 end
    return cfg.envContactM or 25.0
end

--- May this remote environmental claim stand?
---
--- ORDERED SO THE ANSWER NAMES THE STRONGEST THING WRONG WITH IT. A claim
--- against somebody in another match is a fabrication whatever its distance, and
--- reporting it as TOO_FAR would file the mildest true statement about it.
---
--- @param env table|nil  the BR.Config.Environmental row the hash resolved to
--- @param ctx table  { sameSrc, onRoster, sameMatch, victimLive, dist, amount,
---                     burst }
--- @param cfg table|nil BR.Config.Combat
--- @return boolean ok, string|nil why
function BR.EnvDamageAllowed(env, ctx, cfg)
    cfg = cfg or {}

    -- THE WORLD HURTING YOU IS NEVER REFUSED, AND THIS IS THE WHOLE SAFETY
    -- ARGUMENT. Every path the owner cares about -- the fall off a building, the
    -- fire, the drowning, the storm -- ends on the victim's own ped. Refusing
    -- one of those to close a hole about OTHER people's peds would trade a
    -- theoretical exploit for a player who steps off a roof and walks away.
    if ctx.sameSrc then return true, nil end

    -- A sender the roster has never heard of, or one outside a match: there is
    -- no world here for anything to happen in.
    if not ctx.onRoster then return false, BR.EnvRefusal.NO_SENDER end
    if not ctx.sameMatch then return false, BR.EnvRefusal.OTHER_MATCH end
    if not ctx.victimLive then return false, BR.EnvRefusal.NOT_LIVE end

    -- Nil distance means the server has not sampled one of them yet, which is a
    -- gap in OUR knowledge and never evidence against the player. Fail open.
    if ctx.dist and ctx.dist > BR.EnvReach(env, cfg) then
        return false, BR.EnvRefusal.TOO_FAR
    end

    -- THE ONE NUMBER WE CANNOT REWRITE, ONLY REFUSE. Environmental damage stays
    -- the engine's -- there is no ledger of ours behind it -- so the figure in
    -- the payload is the client's and it is applied. The cap is therefore set
    -- well above anything lethal rather than anywhere near a plausible value: a
    -- long fall or a car at speed is allowed to kill outright, and only a number
    -- with no physical meaning is cut.
    if (ctx.amount or 0) > (cfg.envMaxDamage or 400) then
        return false, BR.EnvRefusal.TOO_BIG
    end

    if ctx.burst then return false, BR.EnvRefusal.TOO_OFTEN end

    return true, nil
end

--- May this explosion happen at all?
---
--- THE SECOND ROUTE AROUND THE ADJUDICATOR. `explosionEvent` fires server-side,
--- is cancellable, and this file's handler only ever read attribution out of it
--- -- so an explosion nobody was issued, anywhere on the map, at any rate, was
--- never anybody's business. Cfx's own OneSync cookbook is about cancelling
--- exactly this event.
---
--- CANCELLING AN EXPLOSION IS VISIBLE, WHICH IS WHY THE BOUNDS ARE WIDE. Every
--- one of them is a fact the sender does not control -- their own sampled
--- position, their own inventory, how often they have done this -- and the
--- ambient blasts the owner asked to keep working (a car going off a cliff, a
--- petrol pump) pass all of them: they are not one of the three types this
--- gamemode issues, so provenance never applies to them.
---
--- @param ctx table  { onRoster, posOk, dist, scale, burst, item, owns }
--- @param cfg table|nil BR.Config.Combat
--- @return boolean ok, string|nil why
function BR.ExplosionAllowed(ctx, cfg)
    cfg = cfg or {}

    if not ctx.onRoster then return false, BR.EnvRefusal.NO_SENDER end
    if not ctx.posOk then return false, BR.EnvRefusal.BAD_POS end

    -- REACH, NOT PROXIMITY. A rocket travels 300m before it goes off and a
    -- sticky can be driven somewhere and detonated, so this is deliberately the
    -- longest reach in the arsenal plus room -- it is here to refuse an
    -- explosion on the far side of an eight-kilometre map, not to decide
    -- whether somebody could have thrown that far.
    if ctx.dist and ctx.dist > (cfg.blastMaxDistM or 400.0) then
        return false, BR.EnvRefusal.TOO_FAR
    end

    -- `damageScale` is the client's multiplier on the blast and reads 1.0 for
    -- everything the game does by itself.
    if ctx.scale and ctx.scale > (cfg.blastMaxScale or 2.0) then
        return false, BR.EnvRefusal.TOO_BIG
    end

    if ctx.burst then return false, BR.EnvRefusal.TOO_OFTEN end

    -- PROVENANCE, AND ONLY FOR THE THREE WE ISSUE. `item` is non-nil exactly
    -- when the explosion type is one of ours (BR.Config.Combat.explosionTypes),
    -- so a car fire or a gas pump never reaches this line. To have thrown a
    -- grenade you must have been given one, and the server is the only party
    -- that can give you one.
    --
    -- DELIBERATELY NOT THE CONSUMABLE CREDIT the damage path spends. The
    -- explosion and its damage are two events with no guaranteed order, so a
    -- consuming test here could refuse the visible blast of a grenade whose
    -- damage had already been paid for -- and the failure would be an
    -- explosion that never appeared, which is the kind of thing a player
    -- reports as the game being broken.
    if ctx.item and not ctx.owns then
        return false, BR.EnvRefusal.NOT_OURS
    end

    return true, nil
end
