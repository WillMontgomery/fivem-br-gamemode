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

    return {
        sameSrc     = shooter == victim,
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
--- The action still defaults to logging rather than kicking. A validator that
--- has never wrongly refused an honest player TODAY may still do so the first
--- time a pickup races a shot, and banning your own players is a worse failure
--- than tolerating a cheater who is already unable to hurt anyone. Turn it up
--- deliberately: `BR.Config.Combat.refusalAction`.
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
    local window = cfg.refusalWindowMs or 30000

    local r = refusalOf[src]
    if not r or now - r.since > window then
        r = { since = now, count = 0 }
        refusalOf[src] = r
    end
    r.count = r.count + 1

    local limit = cfg.refusalLimit or 12
    if r.count ~= limit then return end   -- fire once per window, not per shot

    local e = BR.Roster.get(src)
    local name = e and e.name or ('src ' .. src)
    print(('[br_core] ANTICHEAT: %s (%d) had %d shots refused in %ds -- last: %s')
        :format(name, src, r.count, window / 1000, tostring(why)))

    local action = cfg.refusalAction or 'log'
    if action == 'notify' or action == 'kick' then
        BR.Server.notify(src,
            'Your weapon is not one this match issued you. Shots are not landing.',
            'warn')
    end
    if action == 'kick' then
        DropPlayer(src, 'Weapon validation failed repeatedly.')
    end
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
--- @param shooter integer
--- @param victim integer
function BR.Damage.resync(shooter, victim)
    local e = BR.Roster.get(victim)
    if not e then return end

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

--- @param shooter integer
--- @param victim integer
--- @param amount number   display units, already multiplied by body part
--- @param meta table      { weapon, headshot, component, dist }
function BR.Damage.applyHit(shooter, victim, amount, meta)
    if amount <= 0.0 then return end

    local e = BR.Roster.get(victim)
    if not e then return end

    local armour = e.armour or 0.0
    local hp     = e.hp or 100.0

    -- Armour soaks first, and only what it has.
    local toArmour = math.min(armour, amount)
    local toHealth = amount - toArmour

    e.armour = armour - toArmour
    e.hp     = math.max(0.0, hp - toHealth)

    -- ...and the victim is told to look like it. Engine units on the wire, to
    -- match STORM_DAMAGE's contract.
    TriggerClientEvent(BR.Net.HIT_DAMAGE, victim, {
        amount      = math.floor(BR.ToEngineHpDelta(toHealth) + 0.5),
        armour      = math.floor(toArmour + 0.5),
        armourFirst = true,
    })

    -- The shooter gets a hitmarker. This is the one piece of feedback that
    -- cancelling the engine's damage would otherwise take away.
    TriggerClientEvent(BR.Net.DAMAGE_FEED, shooter, {
        amount   = math.floor(amount + 0.5),
        headshot = meta and meta.headshot or false,
        killed   = e.hp <= 0.0,
    })

    -- Attribution, for the kill feed and for anything that finishes them
    -- later: the assist window means storm or fall damage on a wounded player
    -- still credits whoever shot them.
    e.lastHitBy = shooter
    e.lastHitAt = GetGameTimer()
    e.lastHitWeapon = meta and meta.weapon or nil

    if e.hp <= 0.0 then
        local how = 'gunshot'
        if meta and meta.explosive then
            how = 'explosion'
        elseif meta and meta.headshot then
            how = 'headshot'
        end
        BR.Combat.eliminate(victim, how, shooter)
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

    -- ONLY THE DAMAGE TYPES WE HAVE MEASURED -- WHICH TURNS OUT TO BE ALL OF
    -- THEM THAT MATTER.
    --
    -- The expectation was that gunfire, melee and explosions would each carry
    -- their own `damageType` and that this gate would sort them. They do not.
    -- Measured 2026-08-08 with /brdamagelog:
    --
    --   bullet     (WEAPON_CARBINERIFLE etc)  damageType 3
    --   melee      (WEAPON_UNARMED, 0xA2719263)  damageType 3
    --   explosion  (WEAPON_GRENADE, 0x93E220BD)  damageType 3
    --
    -- So damageType is NOT the discriminator; `weaponType` is, and the three
    -- paths are told apart by the weapon table instead (w.melee, w.explosive).
    -- The three payloads differ in ways that corroborate this: the punch
    -- carried hasActionResult=true with a melee actionResultName, the grenade
    -- carried hasActionResult=false, hitComponent 0 and weaponDamage 500.
    --
    -- The gate stays anyway, and is worth its keep for the types NOBODY has
    -- produced yet: fire, falls, drowning, vehicle impacts. Taking one of
    -- those over on a guess would apply the weapon table to a fall. Passing it
    -- through leaves the engine in charge of exactly the paths M5 left it in
    -- charge of, and counting it means an unmeasured type announces itself
    -- once instead of being invisible until somebody notices.
    local dtype = math.tointeger(data.damageType or -1) or -1
    if not (cfg.takeOver or {})[dtype] then
        BR.Damage.seenTypes = BR.Damage.seenTypes or {}
        if not BR.Damage.seenTypes[dtype] then
            BR.Damage.seenTypes[dtype] = true
            print(('[br_core] damageType %d is not one we validate -- left to '
                .. 'the engine. Capture it with /brdamagelog and add it to '
                .. 'BR.Config.Combat.takeOver once its meaning is known.')
                :format(dtype))
        end
        return
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
    local fired = BR.Config.WeaponByHash[BR.NormHash(data.weaponType or 0)]
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

                local ok, why = BR.ValidateShot(
                    { weapon = data.weaponType, dist = dist, sinceLastMs = since },
                    ctx, cfg)

                if not ok then
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
