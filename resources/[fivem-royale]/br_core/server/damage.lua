-- M6: server-side damage validation and kill attribution.
--
-- THE ONE THING THAT MAKES THIS POSSIBLE: FiveM raises `weaponDamageEvent` on
-- the SERVER before damage is applied network-wide, and CancelEvent() in that
-- handler stops it reaching anyone. That is a genuine authority hook, not a
-- report-after-the-fact -- which is why M6 can replace the placeholder ammo
-- model rather than merely audit it.
--
-- MEASUREMENT BEFORE ENFORCEMENT, and that is a deliberate sequencing choice.
-- The payload's field names are not documented anywhere authoritative: the
-- game-events reference lists the event and states the list is "largely
-- undocumented", and the production anticheats that use it read only the one
-- or two fields they need (`weaponType`, `hitGlobalId`). Writing a validator
-- against guessed field names and shipping it switched on is the exact shape
-- of the mistake that cost this project six playtest rounds on the ammo
-- counter. So:
--
--   1. /brdamagelog records real payloads and prints every key in them.
--   2. BR.Config.Combat.enforce goes true once those names are known.
--
-- Until step 2, this file validates, logs its verdict, and cancels NOTHING.
-- A wrong assumption is a console line rather than a match where nobody can
-- shoot anybody.

BR = BR or {}
BR.Damage = BR.Damage or {}

local cfg = BR.Config.Combat or {}

-- Last shot time per shooter, for the rate-of-fire check. Keyed by src.
local lastShot = {}

-- Explosives in flight, per shooter: thrown[src][item] = timestamp of the last
-- one spent. See BR.Damage.noteThrow for why a timestamp and not a count.
local thrown = {}

-- Last applied melee hit, keyed shooter:victim:weapon -> timestamp.
--
-- ONE SWING MUST COST ONE HIT. A melee attack in GTA is an animation with
-- several contact points, and the engine is under no obligation to raise
-- exactly one weaponDamageEvent for it -- the punch that arrived as damageType
-- 1 was a hint that melee reports through more than one path. Now that
-- ownership is decided by the WEAPON rather than the type, every one of those
-- paths lands here, and two events for one swing would apply our damage twice.
--
-- Only melee is deduplicated. A rifle firing at 85ms intervals is genuinely
-- several hits and must never be collapsed; a machete cannot swing twice in
-- 200ms and anything claiming otherwise is one swing counted twice.
local meleeHit = {}

-- Recording state for /brdamagelog.
local recording = 0

-- Ped handle -> player src, rebuilt on a cadence.
--
-- Resolving this per BULLET matters: an automatic weapon raises one of these
-- events per round, and a linear scan over the roster per round is work that
-- scales with both fire rate and player count at once. The map is rebuilt
-- lazily instead, and a miss falls through to a scan -- so a ped that
-- streamed in since the last rebuild still resolves, just once.
local pedMap, pedMapAt = {}, 0

local function rebuildPedMap()
    pedMap = {}
    BR.Roster.each(
        function(e) return e.state ~= BR.PlayerState.LEFT end,
        function(src)
            local ped = GetPlayerPed(src)
            if ped and ped ~= 0 then pedMap[ped] = src end
        end)
    pedMapAt = GetGameTimer()
end

--- Resolve a network id to a player src, or nil if it is not a player.
---
--- This is the whole reason hitGlobalIds is worth reading: a shot into an
--- ambient ped is not our business, and one into a player is the only kind
--- this file has an opinion about.
--- @param netId integer
--- @return integer|nil
local function playerFromNetId(netId)
    if not netId then return nil end
    local ent = NetworkGetEntityFromNetworkId(netId)
    if not ent or ent == 0 then return nil end

    local src = pedMap[ent]
    if src then return src end

    -- Miss: either the map is stale or the ped is an NPC. Rebuilding is cheap
    -- and bounded, but only worth doing once a second -- otherwise every shot
    -- into scenery would rebuild it.
    if GetGameTimer() - pedMapAt > 1000 then
        rebuildPedMap()
        return pedMap[ent]
    end
    return nil
end

--- Record that a player spent one of a throwable, so the explosion it causes
--- can be recognised as theirs.
---
--- A TIMESTAMP RATHER THAN A COUNT, and the difference matters. A count would
--- have to be decremented when the thing goes off, and the server cannot know
--- that: a grenade thrown into the sea never produces a damage event, so its
--- count would never come back and the player would accumulate phantom credit
--- forever. A window expires on its own.
---
--- The window is generous on purpose (BR.Config.Combat.explosiveGraceMs). It
--- is not the security boundary -- the inventory is. A player can only be here
--- at all if the server issued them that explosive and watched them spend one;
--- the window merely stops that credit lasting the whole match.
--- @param src integer
--- @param item string
function BR.Damage.noteThrow(src, item)
    if not item then return end
    local t = thrown[src]
    if not t then t = {}; thrown[src] = t end
    t[item] = GetGameTimer()
end

-- Self-inflicted hits, per player: { since, count }.
local selfHits = {}

--- Count a self-inflicted hit and say whether it has become a pattern.
---
--- Called BEFORE validation, because the answer is an input to it. One
--- self-hit is ordinary -- you stood in your own grenade -- so it is allowed
--- and lands like anybody else's. Several in a few seconds is not bad play,
--- it is somebody exercising a path, and the shot is refused and counted.
--- @param src integer
--- @return boolean  true when this hit is one too many
function BR.Damage.noteSelfHit(src)
    local now = GetGameTimer()
    local window = cfg.selfWindowMs or 5000
    local r = selfHits[src]
    if not r or now - r.since > window then
        r = { since = now, count = 0 }
        selfHits[src] = r
    end
    r.count = r.count + 1
    return r.count > (cfg.selfLimit or 2)
end

--- Did this player throw one of these recently enough to own the blast?
--- @param src integer
--- @param item string
--- @return boolean
function BR.Damage.threwRecently(src, item)
    local t = thrown[src]
    local at = t and t[item]
    if not at then return false end
    return (GetGameTimer() - at) <= (cfg.explosiveGraceMs or 30000)
end

--- Everything the validator needs about a shooter/victim pair, from the
--- SERVER's own model. Nothing here comes off the wire.
--- @param shooter integer
--- @param victim integer
--- @param weapon integer|nil  weapon hash from the event, for the throw check
--- @return table|nil
local function contextFor(shooter, victim, weapon)
    local a = BR.Roster.get(shooter)
    local b = BR.Roster.get(victim)
    if not a or not b then return nil end

    local inv  = BR.Inv and BR.Inv.of(shooter) or nil
    local held = inv and inv.slots[inv.active] or nil

    -- Only to answer "did they throw this", never to decide whether the
    -- weapon is legitimate -- that is BR.ValidateShot's job and it does it
    -- against the same table.
    local w = weapon and BR.Config.WeaponByHash[BR.NormHash(weapon)] or nil

    local sameSrc = shooter == victim

    return {
        sameSrc     = sameSrc,
        -- Counted here rather than in the validator, because it is a fact
        -- about history and the validator is a pure function of one shot.
        selfRepeat  = sameSrc and BR.Damage.noteSelfHit(shooter) or false,
        sameMatch   = a.matchId ~= nil and a.matchId == b.matchId,
        shooterLive = a.state == BR.PlayerState.ALIVE,
        victimLive  = b.state == BR.PlayerState.ALIVE
                   or b.state == BR.PlayerState.DBNO,
        sameSquad   = a.squadId ~= nil and a.squadId == b.squadId,

        -- EITHER of them being on the practice pad makes it a warmup hit.
        -- Requiring both would let somebody standing off the pad hurt a player
        -- on it, which is the one thing the pad promises not to happen.
        warmup      = a.state == BR.PlayerState.WARMUP
                   or b.state == BR.PlayerState.WARMUP,

        -- AN EMPTY ACTIVE SLOT IS FISTS, not "unknown". Slot 0 holds nothing
        -- by design, so a player throwing a punch has no stack here at all --
        -- and reporting nil made the validator refuse every punch in the game
        -- as NO_WEAPON (user's log, 2026-08-08).
        --
        -- This does NOT reopen the trainer hole that `ctx.heldItem ~= w.id`
        -- was written to close. The hole was that nil never disagrees with
        -- anything; 'fists' disagrees with everything except fists. A carbine
        -- conjured over an empty slot still fails, and now it fails saying so.
        heldItem    = held and held.item or 'fists',
        clip        = held and held.clip or nil,
        rarity      = held and held.rarity or nil,
        threwRecently = (w ~= nil) and BR.Damage.threwRecently(shooter, w.id)
                        or false,
        posA        = a.pos,
        posB        = b.pos,
    }
end

--- Record one payload, printing every key it carries.
---
--- This is the whole point of the current milestone slice: it turns "what
--- fields does weaponDamageEvent have" from a guess into a fact, once.
--- @param sender any
--- @param data table
local function record(sender, data)
    recording = recording - 1
    print(('[br_core] --- weaponDamageEvent sample (%d left) ---'):format(recording))
    print(('  sender: %s'):format(tostring(sender)))
    if type(data) ~= 'table' then
        print(('  data is %s, not a table'):format(type(data)))
        return
    end
    -- Sorted, so two samples can be diffed by eye.
    local keys = {}
    for k in pairs(data) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    for _, k in ipairs(keys) do
        local v = data[k]
        if type(v) == 'table' then
            local parts = {}
            for i, item in ipairs(v) do parts[i] = tostring(item) end
            print(('    %-28s { %s }'):format(k, table.concat(parts, ', ')))
        else
            print(('    %-28s %s   [%s]'):format(k, tostring(v), type(v)))
        end
    end
    if recording <= 0 then
        print('[br_core] damage log finished. Paste this to fix the field names.')
    end
end

-- --------------------------------------------------------------------------
-- Applying it
-- --------------------------------------------------------------------------

--- Apply a validated hit, server-authoritatively.
---
--- ARMOUR FIRST, then health, both in DISPLAY units -- the same order the
--- storm uses and the same order the shield item implies. The server's roster
--- entry is the ledger; the victim's client is told to show it, and the 2Hz
--- health sample confirms it afterwards.
---
--- ELIMINATION COMES FROM THE LEDGER, not from the ped. That is the property
--- that makes this worth doing: a client that drops the HIT_DAMAGE event keeps
--- its health bar and still dies here, at the same moment an honest one would.
---
-- Refusals per shooter, with the window they fell in.
local refusalOf = {}

--- Count a refused shot against its shooter, and act if there are enough.
---
--- THE THRESHOLD IS ONLY DEFENSIBLE BECAUSE IT WAS MEASURED. The validator ran
--- in log-only mode for a full playtest on the rule that every refusal during
--- honest play is a false positive, and that log came back EMPTY -- so a stream
--- of them is not noise, it is somebody doing something the server did not
--- issue them the means to do.
---
--- THIS FUNCTION NO LONGER TOUCHES THE PLAYER, and that is the point.
---
--- It used to notify them and, at `refusalAction = kick`, drop them -- deciding
--- and enforcing in the same breath, before anybody had recorded why. Two things
--- were wrong with that. The player learned exactly which of their tools had
--- been noticed, which is free tuning feedback for whoever is testing a trainer.
--- And the evidence was gathered, if at all, from a session that had already
--- ended.
---
--- So the order is inverted (owner call, 2026-08-14): file an incident with the
--- evidence attached, and let Ringmaster decide. It holds the ban list, the
--- audit log and an admin; this function holds a counter. Enforcement comes back
--- over the command channel that already exists for it.
---
--- NOTHING IS EVER SHOWN TO THE OFFENDER. Not a notice, not a hint, and the
--- eventual kick reason is deliberately generic. The one line printed below goes
--- to the server console, which no player reads.
--- @param src integer
--- @param why string|nil
function BR.Damage.noteRefusal(src, why)
    -- RULES ARE NOT CHEATING. Friendly fire, a punch thrown in warmup and a
    -- shot that raced a match boundary are all things an honest client does --
    -- and since fists became a real weapon EVERY player has the means to
    -- generate them constantly. Counting those would mean the first warmup
    -- scrap of every match trips a threshold built for trainers.
    if not BR.ShotSuspicious[why] then return end

    local now = GetGameTimer()
    local e = BR.Roster.get(src)
    local matchId = e and e.matchId or nil

    -- PER MATCH, NOT PER TEN SECONDS (owner call, 2026-08-14).
    --
    -- The record used to lapse after `refusalWindowMs`, so a player producing one
    -- impossible hit every eleven seconds -- all match, every match -- never
    -- reached the threshold and left no trace anywhere. The count now runs for the
    -- match and resets when the match does. `forgetRefusals(src)` still clears it
    -- on disconnect, so a recycled server id cannot inherit one.
    local r = refusalOf[src]
    if not r or r.matchId ~= matchId then
        r = { since = now, matchId = matchId, count = 0, filedAt = 0, byReason = {} }
        refusalOf[src] = r
    end

    -- A TALLY, NOT JUST A TOTAL. A match is a mix, and this function reports a
    -- handful of times at most -- so without this the case is classified by
    -- whichever refusal happened to land last. Seven conjured-weapon shots
    -- followed by one out-of-range would be filed as the mildest thing present and
    -- sorted to the bottom of somebody's queue. Bounded by construction: the key
    -- space is the seven values in BR.ShotSuspicious.
    r.byReason[why] = (r.byReason[why] or 0) + 1

    -- SELF IS RECORDED AND NOT COUNTED. It is in BR.ShotSuspicious, so it reaches
    -- here and shows up in the tally an admin reads; it is absent from
    -- BR.ShotTier, so it contributes to nothing. While the bar was eight it had to
    -- count, or mixing self-harm with real refusals kept somebody under it. At a
    -- bar of one or two the same reasoning says the opposite.
    if BR.ShotTier[why] then r.count = r.count + 1 end

    local crossed, severity, worst = BR.ShotTallyVerdict(r.byReason, cfg.refusalBar)
    if not crossed then return end

    -- ONE REPORT PER DOUBLING, WHICH IS WHAT KEEPS THIS OFF THE QUEUE'S THROAT.
    --
    -- The old rule was `r.count ~= limit`: exactly one report ever, because the
    -- count could equal the limit only once. Now that a bar can be one, "what
    -- about the next fifty" needs an answer, and reporting each of them would put
    -- ~20 events a second onto a 512-deep drop-oldest queue during active abuse --
    -- destroying the player_seen stream behind it in order to say the same thing
    -- twenty times.
    --
    -- So: report at the crossing, then only when the count DOUBLES. About ten
    -- reports for a thousand refusals, no timer needed, and each one means
    -- something an admin would want to know: it doubled. Turning the second and
    -- later reports into corroboration on the existing case rather than a new case
    -- is server/incident.lua's job -- it is the file that already knows what has
    -- been filed for this match.
    if r.count < (r.filedAt == 0 and 1 or r.filedAt * 2) then return end
    r.filedAt = r.count
    r.reports = (r.reports or 0) + 1

    local name = e and e.name or ('src ' .. src)
    local window = cfg.refusalWindowMs or 10000
    print(('[br_core] ANTICHEAT: %s (%d) -- %d refused this match, worst %s (%s), last: %s')
        :format(name, src, r.count, tostring(severity), tostring(worst), tostring(why)))

    -- Hand the firing to br_ringmaster, which files the incident and attaches
    -- the evidence. Fire-and-forget on purpose: if br_ringmaster is absent
    -- nothing listens and nothing is owed -- the shots were already refused,
    -- which is the part that protects the match.
    --
    -- `action` still means what it has always meant: what the server actually
    -- did. What it did is file a case, so that is what it says. The value is
    -- constant now rather than configurable, and it stays on the wire because
    -- the receiver's job is to record what happened, not to infer it.
    -- IDENTITY IS RESOLVED HERE, NOT LEFT TO THE SNAPSHOT.
    --
    -- This used to send `e.license`, which is nil until the ringmaster
    -- projection happens to fill it -- so whether a case could be keyed to a
    -- player depended on whether a snapshot had run for them yet. That was
    -- survivable while this was a log line. It is not survivable now that the
    -- event opens an incident: server ids recycle within the minute, so a case
    -- with no license is a case about whoever holds that slot next.
    local license = BR.Roster.licenseOf(src)

    TriggerEvent('br:ringmaster:refusal', {
        src      = src,
        name     = name,
        license  = license,   -- nil only for a genuinely licenseless connection
        matchId  = matchId,
        count    = r.count,
        windowMs = window,
        reason   = tostring(why),
        -- Every reason this match and how many of each. An ADDED field, so
        -- nothing downstream has to change to keep working -- but it is what
        -- lets the case be classified by the worst thing that happened rather
        -- than the last.
        reasons  = r.byReason,
        -- THE SAME VERDICT THE BAR WAS TESTED WITH, carried rather than recomputed
        -- downstream. Two traversals of the same tally in two files is two chances
        -- to disagree about which reason graded the case.
        severity = severity,
        -- WHICH REPORT THIS IS FOR THIS PLAYER, THIS MATCH: 1 is the crossing and
        -- opens the case, 2+ are doublings and corroborate it. It rides the wire so
        -- a receiver can tell a lost corroboration (1, 2, 4 with 3 missing) from a
        -- quiet one -- the event channel drops silently and never says so.
        seq      = r.reports,
        action   = 'incident',
        at       = now,
    })
end

--- Forget a player's refusal history. Called on disconnect.
--- @param src integer
function BR.Damage.forgetRefusals(src)
    refusalOf[src] = nil
end

--- Tell a shooter that the victim they think they killed is fine.
---
--- The server's ledger is the truth about the victim's health; this hands that
--- truth to the one client whose local copy disagrees. Sent only to the
--- shooter, because nobody else's view was ever wrong.
---
--- ...AND ONLY WHILE THEY ACTUALLY ARE FINE. The success path has always said
--- this -- applyHit withholds the netId once the ledger reads zero, because "the
--- corpse on the shooter's screen is correct and resurrecting it would be the
--- bug". The refusal path never did, and a refusal is exactly where it bites:
--- friendly fire is refused, so every shot into a dead squadmate's body came
--- back here and told the shooter to stand it up.
---
--- THE STATE, NOT THE NUMBER, and that is not a stylistic preference. Copying
--- applyHit's `e.hp > 0` test would not work here: an eliminated player's ledger
--- health is never zeroed -- a bleed-out leaves it parked on the DBNO floor --
--- so `e.hp` reads 5 for a player who has been out of the match for a minute,
--- and BR.ToEngineHp(5) is a perfectly live-looking 105 on the wire. The roster
--- state is the fact; the health is a leftover.
--- @param shooter integer
--- @param victim integer
function BR.Damage.resync(shooter, victim)
    local e = BR.Roster.get(victim)
    if not e then return end
    if e.state ~= BR.PlayerState.ALIVE and e.state ~= BR.PlayerState.DBNO then
        return
    end

    local ped = GetPlayerPed(victim)
    if not ped or ped == 0 then return end

    local netId = NetworkGetNetworkIdFromEntity(ped)
    if not netId or netId == 0 then return end

    TriggerClientEvent(BR.Net.HIT_RESYNC, shooter, {
        netId = netId,
        -- Engine units, because the client writes this straight onto a ped.
        hp    = math.floor(BR.ToEngineHp(e.hp or 100.0) + 0.5),
    })
end

--- Spend one round from the shooter's magazine, server-side.
---
--- THIS IS WHAT M6 WAS FOR. The ammo model until now was the M5 placeholder:
--- the client reported its own magazine and the server believed any decrease,
--- on the reasoning that the worst a liar could do was disarm themselves. That
--- was a holding position, and it is no longer needed -- every shot now arrives
--- as a server event the server has already validated, so the server can
--- simply count them.
---
--- Called on EVERY validated shot, hit or miss. A miss still costs a round,
--- which is the entire difference between counting shots and counting hits.
--- @param src integer
--- @param weapon integer  weapon hash from the event
function BR.Damage.spendRound(src, weapon)
    local inv = BR.Inv and BR.Inv.of(src)
    if not inv then return end

    local slot = inv.slots[inv.active]
    if not slot or slot.kind ~= BR.ItemKind.WEAPON then return end

    local w = BR.Config.WeaponById[slot.item]
    if not w then return end
    -- Only the weapon actually being fired. A shot from something else means
    -- the slot and the ped disagree, and guessing which is right is how the
    -- ammo model went wrong the first time.
    if BR.NormHash(w.hash) ~= BR.NormHash(weapon) then return end
    -- Melee has no magazine to spend.
    if w.melee or not w.clip then return end

    local clip = slot.clip or 0
    if clip <= 0 then
        -- An empty magazine that is still firing. The validator already
        -- refuses this (NO_AMMO), so reaching here means enforcement is off --
        -- worth counting rather than silently allowing.
        BR.Damage.dryShots = (BR.Damage.dryShots or 0) + 1
        return
    end

    slot.clip = clip - 1

    -- RELOAD IS THE SERVER'S TOO, now that it can see the magazine empty.
    -- Without this the gun would simply stop at zero and never refill, because
    -- the client report that used to carry reloads is gone.
    if slot.clip <= 0 and w.ammo then
        local pool = inv.ammo[w.ammo] or 0
        if pool > 0 then
            local moved = math.min(w.clip, pool)
            inv.ammo[w.ammo] = pool - moved
            slot.clip = moved
        end
    end

    BR.Inv.push(src)
end

--- Credit a shooter with damage that actually landed.
---
--- THE PRODUCER THAT NEVER EXISTED. `entry.damage` has been initialised on the
--- roster, reset at CLEANUP, projected to the console, forwarded in the match
--- results and multiplied by the XP curve's `perDamage` since all of that was
--- written -- and nothing anywhere added to it, so `damageDealt` in DynamoDB
--- was 0 for every player who ever played (#98). Every read path was present
--- and plausible, which is exactly why it survived review.
---
--- WHAT LANDED, NOT WHAT WAS SWUNG. The caller's `amount` is the ledger's
--- number before armour and before the downed-floor clamp; crediting that would
--- pay for overkill, so a player emptying a magazine into a corpse-to-be would
--- out-earn one who stopped when the job was done.
---
--- Storm and fire damage are credited to nobody, and cannot be: the storm has
--- no dealer, and burning damage is applied on the victim's own machine through
--- a path the server never sees (see the fire ledger below). Their KILLS are
--- attributed; their damage is not, and there is no server-side number to fix
--- that with.
--- @param shooter integer|nil
--- @param victim integer
--- @param landed number  display units that actually came off armour or health
local function creditDamage(shooter, victim, landed)
    if not shooter or shooter == victim or landed <= 0.0 then return end
    local dealer = BR.Roster.get(shooter)
    if not dealer then return end
    dealer.damage = (dealer.damage or 0.0) + landed
end

--- @param shooter integer
--- @param victim integer
--- @param amount number   display units, already multiplied by body part
--- @param meta table      { weapon, headshot, component, dist }
function BR.Damage.applyHit(shooter, victim, amount, meta)
    if amount <= 0.0 then return end

    local e = BR.Roster.get(victim)
    if not e then return end

    -- A HIT ON SOMEBODY ALREADY DOWN BUYS TIME, NOT HEALTH.
    --
    -- The bleed timer IS a downed player's health (see the DBNO section of
    -- server/combat.lua), so this whole function's armour-then-health
    -- arithmetic has nothing to work on. The shooter still gets their
    -- hitmarker -- they connected, and telling them otherwise would read as
    -- the shot not landing.
    if e.state == BR.PlayerState.DBNO then
        BR.Combat.bleed(victim, amount, shooter, meta)
        -- Credited in full: against a downed player the bleed clock IS their
        -- health, so the whole amount did work. There is no armour to soak it
        -- and no floor to clamp it to.
        creditDamage(shooter, victim, amount)
        -- Read AFTER the bleed: `e` is the live entry, so a hit that ran the
        -- clock out has already flipped it to DEAD by this line and the
        -- marker gets to punctuate.
        TriggerClientEvent(BR.Net.DAMAGE_FEED, shooter, {
            amount   = math.floor(amount + 0.5),
            headshot = meta and meta.headshot or false,
            killed   = e.state ~= BR.PlayerState.DBNO,
        })
        return
    end

    local armour = e.armour or 0.0
    local hp     = e.hp or 100.0

    -- Armour soaks first, and only what it has.
    local toArmour = math.min(armour, amount)
    local toHealth = amount - toArmour

    -- A KNOCK IS DECIDED BEFORE THE HEALTH IS WRITTEN, because it changes how
    -- much damage the victim is told to apply to their own ped: the ped has to
    -- survive a knock, and instructing the full amount would kill it on the
    -- victim's own machine a beat before the server said anything about being
    -- downed. So the instruction is clamped to the ledger's downed floor and
    -- the overflow is simply dropped -- there is nothing left for it to hurt.
    local downing = (hp - toHealth <= 0.0) and BR.Combat.canBeDowned(e)
    if downing then
        toHealth = math.max(0.0, hp - (BR.Config.Match.dbnoHp or 5))
    end

    e.armour = armour - toArmour
    e.hp     = math.max(0.0, hp - toHealth)

    -- Read AFTER the clamp, so a knocking shot credits the damage that reached
    -- the downed floor rather than the overflow that was dropped.
    creditDamage(shooter, victim, toArmour + toHealth)

    -- ...and the victim is told to look like it. Engine units on the wire, to
    -- match STORM_DAMAGE's contract.
    TriggerClientEvent(BR.Net.HIT_DAMAGE, victim, {
        amount      = math.floor(BR.ToEngineHpDelta(toHealth) + 0.5),
        armour      = math.floor(toArmour + 0.5),
        armourFirst = true,
    })

    -- The shooter gets a hitmarker. This is the one piece of feedback that
    -- cancelling the engine's damage would otherwise take away.
    -- ...AND THE SHOOTER'S COPY OF THEM IS CORRECTED WITH IT.
    --
    -- THE BUG THIS FIXES: a player shot down to 7hp died on the SHOOTER'S
    -- screen and stayed a corpse there forever, while walking around alive on
    -- their own (user, 2026-08-09).
    --
    -- CancelEvent stops the damage REPLICATING; it does not undo the copy GTA
    -- already applied locally on the shooter's machine before the server ever
    -- saw the event. So every validated shot leaves the shooter's local ped
    -- carrying GTA's damage number while the ledger carries OURS -- and ours
    -- is a different number, because it is recomputed from our own tables with
    -- rarity and falloff and body part. The two drift apart by the difference,
    -- every single shot, and eventually the local copy reaches zero while the
    -- real player is on 7.
    --
    -- The refusal path has corrected this since 2026-08-08 (BR.Damage.resync).
    -- The SUCCESS path never did, which is the whole bug: refused shots looked
    -- right and landed shots did not.
    --
    -- Carried on DAMAGE_FEED rather than as a second event because this
    -- already goes to exactly the right player at exactly the right rate --
    -- one per hit, to the one machine whose copy is wrong.
    --
    -- Only while they are ALIVE. Once the ledger says dead, the corpse on the
    -- shooter's screen is correct and resurrecting it would be the bug.
    local netId, engineHp = nil, nil
    if e.hp > 0.0 then
        local vped = GetPlayerPed(victim)
        if vped and vped ~= 0 then
            local nid = NetworkGetNetworkIdFromEntity(vped)
            if nid and nid ~= 0 then
                netId    = nid
                engineHp = math.floor(BR.ToEngineHp(e.hp) + 0.5)
            end
        end
    end

    TriggerClientEvent(BR.Net.DAMAGE_FEED, shooter, {
        amount   = math.floor(amount + 0.5),
        headshot = meta and meta.headshot or false,
        killed   = e.hp <= 0.0,
        netId    = netId,
        hp       = engineHp,
    })

    -- Attribution, for the kill feed and for anything that finishes them
    -- later: the assist window means storm or fall damage on a wounded player
    -- still credits whoever shot them.
    e.lastHitBy = shooter
    e.lastHitAt = GetGameTimer()
    e.lastHitWeapon = meta and meta.weapon or nil

    if downing or e.hp <= 0.0 then
        local how = 'gunshot'
        if meta and meta.explosive then
            how = 'explosion'
        elseif meta and meta.headshot then
            how = 'headshot'
        end
        -- NOT eliminate() any more. defeat() is the one place that decides
        -- whether running out of health means down or out, so a knock is
        -- possible from every damage path or from none of them.
        BR.Combat.defeat(victim, how, shooter)
    end
end

-- --------------------------------------------------------------------------
-- The handler
-- --------------------------------------------------------------------------

AddEventHandler('weaponDamageEvent', function(sender, data)
    if recording > 0 then record(sender, data) end
    if type(data) ~= 'table' then return end

    local shooter = tonumber(sender)
    if not shooter then return end

    -- THE WEAPON DECIDES WHOSE HIT THIS IS. NOT `damageType`.
    --
    -- This used to gate on damageType and it was wrong twice over. First the
    -- 2026-08-08 capture showed bullets, melee AND grenades all reporting
    -- damageType 3, so it discriminated nothing. Then a punch arrived as
    -- damageType 1 -- so melee has more than one type -- and fell through to
    -- the engine, which applied GTA's own melee damage ON TOP of ours. Two
    -- punches killed a full-health player (user, 2026-08-08).
    --
    -- Chasing that with a longer list of numbers is the same mistake with more
    -- steps: the list is unbounded and every gap in it is a damage path
    -- silently handed back to the client. `weaponType` is the field that
    -- actually says what happened, and there are exactly three answers:
    --
    --   OURS         a weapon this gamemode issues -> validate and apply.
    --   THE WORLD'S  a fall, a fire, drowning, a car -> the engine's, always.
    --   NEITHER      a weapon nobody was given -> the only thing left to
    --                refuse, and the only thing worth refusing.
    --
    -- damageType is kept in the logs because it is useful evidence, and it is
    -- no longer a decision.
    local fired = BR.Config.WeaponByHash[BR.NormHash(data.weaponType or 0)]
    if not fired then
        local env = BR.Config.EnvironmentalFor(data.weaponType)
        if env then
            -- The world hurt somebody. Not our business, and never a refusal:
            -- storm, falls and fire have always been the engine's, and an
            -- exploding car is the same kind of thing (user question,
            -- 2026-08-08: would NOT_THROWN block ambient explosions? It
            -- cannot -- those never reach the validator at all).
            BR.Damage.envHits = (BR.Damage.envHits or 0) + 1
            return
        end
        -- Falls through to the loop below, where it is refused as NO_WEAPON
        -- against a real victim. Deliberately NOT returned here: a trainer
        -- weapon is exactly the case this whole file exists for.
    end

    -- ONE ROUND, ONCE PER EVENT, AND BEFORE ANY OF THE HIT LOGIC.
    --
    -- Deliberately not inside the per-victim loop below: a shotgun pellet
    -- spread or a round that clips two players raises one event listing
    -- several hits, and charging a magazine per victim would empty a gun in
    -- three shots. It is also outside the "did we hit a player" test, because
    -- a MISS costs a round too -- that is the whole difference between
    -- counting shots and counting hits.
    if cfg.serverAmmo then
        BR.Damage.spendRound(shooter, data.weaponType)
    end

    -- hitGlobalIds is the documented-by-usage field; hitGlobalId is the
    -- singular form some builds send. Read both rather than betting on one.
    local ids = data.hitGlobalIds
    if type(ids) ~= 'table' then
        ids = data.hitGlobalId and { data.hitGlobalId } or nil
    end
    if not ids then return end

    -- CADENCE IS PER EVENT, NOT PER VICTIM, and this used to be inside the
    -- loop below. A shotgun blast that catches two players -- or a grenade
    -- that catches four -- arrives as ONE event listing several hits, so the
    -- second victim was measured against a "last shot" stamped microseconds
    -- earlier by the first, and refused as TOO_FAST. The shooter was
    -- competing with themselves. Same reasoning that already put spendRound
    -- outside the loop.
    local now = GetGameTimer()
    local since = now - (lastShot[shooter] or 0)

    -- Explosives do not stamp it. A detonation is not a trigger pull, and
    -- letting one set the clock means the next honest rifle round is measured
    -- from the moment your own grenade went off.
    if not (fired and fired.explosive) then lastShot[shooter] = now end

    for _, netId in ipairs(ids) do
        local victim = playerFromNetId(netId)
        if victim then
            local ctx = contextFor(shooter, victim, data.weaponType)
            if ctx then
                local dist = 0.0
                if ctx.posA and ctx.posB then
                    dist = BR.Dist3(ctx.posA.x, ctx.posA.y, ctx.posA.z,
                                    ctx.posB.x, ctx.posB.y, ctx.posB.z)
                end

                -- ONE SWING, ONE HIT -- AND RESOLVED BEFORE VALIDATION, not
                -- after. A duplicate arrives microseconds behind the original,
                -- so the rate check would refuse it as TOO_FAST -- which is a
                -- COUNTABLE refusal. Validating duplicates would have had the
                -- engine's own double-reporting file anticheat strikes against
                -- players for punching. It is not a refusal; it is the same
                -- swing arriving twice, and the second copy is simply dropped.
                local dupe = false
                if fired and fired.melee then
                    local key = shooter .. ':' .. victim .. ':'
                                .. tostring(BR.NormHash(data.weaponType or 0))
                    local last = meleeHit[key]
                    local window = (fired.minInterval or 400)
                                 * (cfg.meleeDedupe or 0.5)
                    if last and (now - last) < window then
                        dupe = true
                        BR.Damage.meleeDupes = (BR.Damage.meleeDupes or 0) + 1
                    else
                        meleeHit[key] = now
                    end
                end

                local ok, why
                if dupe then
                    -- Cancelled all the same: the engine's copy of a duplicate
                    -- is just as unwelcome as our own would be.
                    if cfg.applyOwnDamage then CancelEvent() end
                else
                    ok, why = BR.ValidateShot(
                        { weapon = data.weaponType, dist = dist,
                          sinceLastMs = since }, ctx, cfg)
                end

                if dupe then           -- nothing further; already handled
                elseif not ok then
                    -- REFUSALS ARE LOUD WHILE ENFORCEMENT IS OFF. The whole
                    -- purpose of this phase is to find out how often the
                    -- validator would have been WRONG about an honest shot,
                    -- and a silent refusal teaches nothing. Every line printed
                    -- here during normal play is a FALSE POSITIVE -- a shot
                    -- that would have been wrongly cancelled -- so an empty
                    -- log over a full match is the signal that enforcement is
                    -- safe to switch on.
                    BR.Damage.refusals = (BR.Damage.refusals or 0) + 1
                    -- ...but a rules refusal is not printed unless asked for.
                    -- Warmup fistfights would otherwise fill the console with
                    -- lines that mean "the game said no", drowning the ones
                    -- that mean "somebody has a weapon we did not issue".
                    if BR.ShotSuspicious[why] or cfg.logHits then
                        print(('[br_core] shot refused: %d -> %d, %s (%.0fm, %dms)')
                            :format(shooter, victim, tostring(why), dist, since))
                    end
                    BR.Damage.noteRefusal(shooter, why)
                    if cfg.enforce then
                        CancelEvent()

                        -- PUT THE VICTIM BACK ON THE SHOOTER'S SCREEN.
                        --
                        -- CancelEvent stops the damage REPLICATING; it does not
                        -- undo it. GTA already applied it locally on the
                        -- shooter's machine before the server saw the event, so
                        -- a refused burst leaves them looking at a corpse that
                        -- is alive and playing on every other screen (user's
                        -- own test with a trainer, 2026-08-08).
                        --
                        -- Nothing is at stake -- the victim was never hurt and
                        -- no kill was credited -- but it is worth correcting
                        -- anyway, because the same desync would hit an HONEST
                        -- player whose shot was refused by a race, and there it
                        -- would read as the game being broken rather than as
                        -- cheating not working.
                        BR.Damage.resync(shooter, victim)
                    end
                else
                    -- WHAT THE SERVER THINKS THE HIT WAS WORTH.
                    --
                    -- Recomputed from our own tables and NEVER read off the
                    -- event: `weaponDamage` in the payload is the shooter's
                    -- own number (27 and 33 in the captured samples), and
                    -- `overrideDefaultDamage` arrives TRUE -- which is to say
                    -- the client is already telling the server what the hit
                    -- should cost. That field is precisely what a damage
                    -- multiplier edits, so it is evidence of intent and never
                    -- an input.
                    local head = BR.Config.IsHeadshot(data.hitComponent)
                    local dmg, mult = BR.ShotDamage(data.weaponType, ctx.rarity,
                                                    dist, data.hitComponent, cfg)
                    BR.Damage.lastHit = {
                        shooter = shooter, victim = victim,
                        ours = dmg, theirs = data.weaponDamage,
                        head = head, component = data.hitComponent, mult = mult,
                        willKill = data.willKill, at = now,
                    }
                    if cfg.logHits then
                        print(('[br_core] hit %d -> %d: ours %.1f (x%.2f, part %s), client said %s%s')
                            :format(shooter, victim, dmg, mult,
                                    tostring(data.hitComponent),
                                    tostring(data.weaponDamage),
                                    head and '  HEADSHOT' or ''))
                    end

                    -- THE TAKEOVER. Cancel GTA's damage and apply ours.
                    --
                    -- It has to be both halves or neither: leaving the engine's
                    -- damage in place and "correcting" health afterwards means
                    -- the client's number lands first, which is the exact
                    -- window a multiplier cheat needs. Cancelling without
                    -- applying means nobody can hurt anybody.
                    --
                    -- The ledger pattern is the storm's, and for the same
                    -- reason: the server cannot write a ped, so it keeps the
                    -- authoritative number and TELLS the victim to show it. A
                    -- client that ignores the instruction keeps its health bar
                    -- and dies at exactly the same moment as an honest one.
                    if cfg.applyOwnDamage then
                        CancelEvent()
                        BR.Damage.applyHit(shooter, victim, dmg, {
                            weapon    = data.weaponType,
                            headshot  = head,
                            explosive = fired and fired.explosive or false,
                            component = data.hitComponent,
                            dist      = dist,
                        })
                    end
                end
            end
        end
    end
end)

-- --------------------------------------------------------------------------
-- Explosions and fire: attribution without ownership
-- --------------------------------------------------------------------------
--
-- WE CANNOT TAKE FIRE DAMAGE OVER, AND WE CAN STILL SAY WHOSE IT WAS.
--
-- Measured 2026-08-08: /brdamagelog armed, a molotov thrown at a player, the
-- player died, and NOT ONE PAYLOAD PRINTED. Burning damage never raises
-- weaponDamageEvent -- it is applied on the victim's own machine through a
-- path the server does not see. No amount of validator work reaches it.
--
-- The cost was not the damage number. It was the KILL: attribution reads
-- e.lastHitBy, nothing ever wrote to it, and a molotov kill was credited to
-- nobody at all.
--
-- `explosionEvent` does fire on the server, carries the thrower and the
-- position, and fires for grenades, sticky bombs and molotovs alike. So the
-- damage stays the engine's and the LEDGER becomes ours: whoever lit the fire
-- owns every point of health lost inside it.
--
-- ONLY PLAYERS ACTUALLY LOSING HEALTH ARE ATTRIBUTED. Standing in somebody's
-- fire unharmed credits them nothing, which is what keeps a generous radius
-- and a twenty-second window from handing out kills the storm did.

-- Live fires: { owner, x, y, z, item, until_ }.
local fires = {}

--- Note an explosion, and remember it if it was one of ours.
--- @param owner integer
--- @param ev table
local function noteExplosion(owner, ev)
    local item = (cfg.explosionTypes or {})[math.tointeger(ev.explosionType) or -1]
    if not item then return end   -- a car, a petrol pump: nobody's kill

    local e = BR.Roster.get(owner)
    if not e or not e.matchId then return end

    local now = GetGameTimer()
    -- A blast is instantaneous; a molotov keeps burning. Both are the same
    -- record with a different lifetime.
    local life = (item == 'molotov') and (cfg.fireLifeMs or 20000)
                                      or (cfg.blastAttributeMs or 1200)

    fires[#fires + 1] = {
        owner = owner, matchId = e.matchId, item = item,
        x = ev.posX or 0.0, y = ev.posY or 0.0, z = ev.posZ or 0.0,
        until_ = now + life,
    }
    BR.Damage.explosions = (BR.Damage.explosions or 0) + 1
end

AddEventHandler('explosionEvent', function(sender, ev)
    if type(ev) ~= 'table' then return end
    local owner = tonumber(sender)
    if owner then noteExplosion(owner, ev) end
end)

--- Credit health lost inside somebody's fire to whoever lit it.
---
--- Runs off the roster's own 2Hz health sampling, so it sees the same numbers
--- the storm does and needs no client cooperation. A player whose health did
--- not move is not burning, whatever they are standing in.
BR.Sched.every(500, 'damage.fires', function()
    if #fires == 0 then return end

    local now = GetGameTimer()
    local live = {}
    for _, f in ipairs(fires) do
        if now < f.until_ then live[#live + 1] = f end
    end
    fires = live
    if #fires == 0 then return end

    local r = cfg.fireRadius or 6.0
    local r2 = r * r

    BR.Roster.each(
        function(e) return e.state == BR.PlayerState.ALIVE
                        or e.state == BR.PlayerState.DBNO end,
        function(src, e)
            if not e.pos then return end

            local hp = (e.hp or 100.0) + (e.armour or 0.0)
            local was = e.burnHp
            e.burnHp = hp
            -- Not hurt since the last sample: nothing to attribute. This is
            -- the whole guard -- without it, standing near a burnt-out patch
            -- would credit its owner for a storm death.
            if not was or hp >= was then return end

            for _, f in ipairs(fires) do
                if f.matchId == e.matchId then
                    local dx, dy = e.pos.x - f.x, e.pos.y - f.y
                    local dz = e.pos.z - f.z
                    if dx * dx + dy * dy <= r2 and math.abs(dz) < 8.0 then
                        e.lastHitBy = f.owner
                        e.lastHitAt = now
                        e.lastHitWeapon = f.item

                        -- SELF-HARM IS COUNTED HERE, because there is nowhere
                        -- else left to count it.
                        --
                        -- The repeat guard used to live in the validator, on
                        -- weaponDamageEvent. It could never fire: dropping
                        -- three grenades at your own feet raises NO
                        -- weaponDamageEvent at all (user capture,
                        -- 2026-08-08 -- the log stayed empty and the player
                        -- died), exactly like the molotov. Explosions are the
                        -- only realistic way to hurt yourself, so the one path
                        -- that could see it was the one path that never ran.
                        --
                        -- The damage still cannot be refused -- it is the
                        -- engine's, applied on the victim's own machine -- but
                        -- the PATTERN is now visible, which is what the rule
                        -- was ever about. Blowing yourself up once is a
                        -- mistake; doing it three times in five seconds is
                        -- somebody exercising something.
                        if f.owner == src and BR.Damage.noteSelfHit(src) then
                            BR.Damage.noteRefusal(src, BR.ShotRefusal.SELF)
                        end
                        return
                    end
                end
            end
        end)
end)

--- Forget a player's fires. Called on disconnect and at match teardown, so a
--- reconnect cannot inherit credit for a fire lit by whoever held the id
--- before them.
--- @param src integer
function BR.Damage.forgetFires(src)
    local keep = {}
    for _, f in ipairs(fires) do
        if f.owner ~= src then keep[#keep + 1] = f end
    end
    fires = keep
end

-- --------------------------------------------------------------------------
-- Tooling
-- --------------------------------------------------------------------------

--- Capture the next few weaponDamageEvent payloads and print every field.
---
---   brdamagelog          capture BR.Config.Combat.logSamples payloads
---   brdamagelog 40       capture that many
---   brdamagelog off
---
--- Shoot another player (or be shot) while this is running. What it prints is
--- the ground truth this milestone needs before enforcement can be trusted.
RegisterCommand('brdamagelog', function(_, args)
    if args[1] == 'off' then
        recording = 0
        print('[br_core] damage log off')
        return
    end
    recording = math.tointeger(tonumber(args[1])) or cfg.logSamples or 15
    print(('[br_core] recording the next %d weaponDamageEvent payloads.')
        :format(recording))
    print('  Shoot a player. Every field of every payload will be printed.')
end, true)

--- Forget a player's rate-of-fire history. Called on disconnect and at match
--- teardown, so a reconnect cannot inherit a stale "last shot" timestamp and
--- have their first shot refused as too fast.
--- @param src integer
function BR.Damage.forget(src)
    lastShot[src] = nil
    thrown[src]   = nil
    selfHits[src] = nil
    if BR.Damage.forgetFires then BR.Damage.forgetFires(src) end
    for k in pairs(meleeHit) do
        if k:find('^' .. src .. ':') or k:find(':' .. src .. ':') then
            meleeHit[k] = nil
        end
    end
end

--- Turn the damage takeover on and off WITHOUT A REDEPLOY.
---
---   brdamage            what it is doing now
---   brdamage off        stop cancelling and applying; GTA's numbers again
---   brdamage on
---   brdamage strict     also cancel refused shots
---
--- This exists because flipping the takeover changes every gunfight in the
--- match at once, and the failure mode -- nobody can hurt anybody -- is the
--- kind you want to back out of in one command rather than one deploy.
RegisterCommand('brdamage', function(_, args)
    local a = args[1]
    if a == 'off' then
        cfg.applyOwnDamage, cfg.enforce = false, false
        print('[br_core] damage takeover OFF -- GTA applies its own numbers again')
    elseif a == 'on' then
        cfg.applyOwnDamage = true
        print('[br_core] damage takeover ON')
    elseif a == 'strict' then
        cfg.applyOwnDamage, cfg.enforce = true, true
        print('[br_core] damage takeover ON, refused shots cancelled')
    end
    print(('  applyOwnDamage=%s  enforce=%s  logHits=%s  refusals so far=%d')
        :format(tostring(cfg.applyOwnDamage), tostring(cfg.enforce),
                tostring(cfg.logHits), BR.Damage.refusals or 0))
end, true)
