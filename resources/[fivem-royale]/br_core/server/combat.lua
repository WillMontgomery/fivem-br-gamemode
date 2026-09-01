-- Elimination, and the downed state that now sits in front of it.
--
-- AUTHORITY. The client reports its own death, because it is the only party that
-- can observe it immediately. The server decides what that means, and
-- independently confirms it by reading the player's health server-side. A client
-- that never reports still dies; a client that reports falsely is ignored.
--
-- M7 PUT A DECISION IN THE MIDDLE. Running out of health used to mean one
-- thing, so four separate paths called eliminate() directly: the validated
-- damage path, the storm's ledger, the client's own death report and the
-- server-observed health check. Now it can mean two things, and the difference
-- is not a property of the path -- being shot, burned or caught by the wall all
-- knock a squad player down and all kill a solo. So every one of those callers
-- goes through BR.Combat.defeat instead, which is the only place the question
-- is asked. Building it any other way is how a player ends up downable by a
-- rifle and instantly killable by a fall.

BR = BR or {}
BR.Combat = {}

local M = BR.Config.Match

--- Can this player be eliminated? Dying in the lobby is not a thing.
---
--- Takes an ENTRY, not a state string, so it matches the predicate contract of
--- BR.Roster.each and BR.Server.count -- both of which pass the whole entry.
--- An earlier version took the state string, which made
--- `BR.Roster.each(canDie, ...)` compare a table against a string: always false,
--- so the server-observed death check silently never ran for anybody. No error,
--- no log line, just a check that quietly did nothing.
--- @param entry table
--- @return boolean
local function canDie(entry)
    local s = entry and entry.state
    return s == BR.PlayerState.ALIVE
        or s == BR.PlayerState.DBNO
        or s == BR.PlayerState.BUS
        or s == BR.PlayerState.FREEFALL
        or s == BR.PlayerState.GLIDE
end

--- Has this player left the bus into a match that has not started yet? (#144)
---
--- THE WINDOW IS THE DESCENT AND WHAT FOLLOWS IT, NOT THE WARMUP PAD. Rescoped
--- on the owner's correction, 2026-08-16:
---
---   "this was not supposed to cover dying during warmup, since that's not
---    possible. instead, the issue is dying between jumping from the bus and
---    game state changing to playing"
---
--- So it takes TWO facts, and neither alone is the window:
---
---   THE MATCH IS IN BUS. Which is not a small slice: BUS covers the whole
---   descent AND the whole wait afterwards, because server/match.lua holds the
---   state until the LAST player is down and extends it in ten-second steps for
---   anyone still under canopy. WARMUP is deliberately excluded -- the owner
---   says death is not possible there, and a hold that covered it would be
---   holding open something that never happens. WAITING has no players in it,
---   and by ENDED or CLEANUP the results are published or about to be, so
---   holding a death there would be holding it open past the moment it is
---   written down.
---
---   AND THIS PLAYER IS OUT OF THE DOOR. Somebody still ABOARD has not entered
---   the window yet -- "between jumping from the bus and..." is where it starts,
---   and starting it earlier would put the aircraft back inside a scope the
---   owner has just taken it out of.
---
--- What is left is exactly the descent and the moments after it: FREEFALL and
--- GLIDE in the air, ALIVE once their feet are down, DBNO if a squadmate's
--- killer got there first. The last of those is the case that actually happens
--- and the reason the window matters at all -- a player becomes ALIVE the
--- instant they LAND, so the first person to touch the ground is mortal, on
--- foot, in a POI, for as long as the slowest glider takes ("what may be a
--- minute or more", in the issue's words). The airborne states are invincible
--- client-side (client/natives.lua) and are covered anyway, because a client
--- that loses that invincibility is not a reason to bank a death nobody could
--- have earned.
--- @param m table|nil
--- @param entry table|nil
--- @return boolean
local function beforeTheMatch(m, entry)
    if not m or not entry then return false end
    if m.state ~= BR.MatchState.BUS then return false end
    local s = entry.state
    return s == BR.PlayerState.FREEFALL
        or s == BR.PlayerState.GLIDE
        or s == BR.PlayerState.ALIVE
        or s == BR.PlayerState.DBNO
end

--- A death that is going to be undone, recorded NOWHERE (#144).
---
--- The owner: "If a player dies before game state changes to playing, we should
--- notify them they will be revived automatically when the match starts, and
--- then do so."
---
--- THE DANGEROUS HALF IS THE BOOKKEEPING, NOT THE REVIVE, AND THIS PROJECT HAS
--- THE SCARS TO PROVE IT. A placement-1 death was banked as a WIN because the
--- stats path and the client disagreed about what a death meant, and a second
--- results publish invented a full set of rows -- both landed in DynamoDB as an
--- atomic ADD, which has no compensating write. There is no undo. So a death
--- that will be reversed must never be WRITTEN, rather than written and then
--- carefully unwritten: every field the results row is built from is simply
--- never touched here.
---
--- What eliminate() does that this deliberately does not:
---   * `entry.placement` -- a placement is a finishing position, and this player
---     has not finished. Left nil, so awardPlacements and the results row see
---     someone who was never eliminated.
---   * `entry.diedAt` -- the single field `died` is derived from, which decides
---     `wins`, `deaths`, the win XP bonus and the top-10 bonus, AND doubles as
---     the survival clock's end stamp. Writing it would pay this player for
---     surviving until the moment they were revived.
---   * the killer's `kills` -- an undone death is not a kill. The shooter is
---     told nothing, which is the honest outcome: there is no such kill to tell
---     them about.
---   * `BR.Loot.deathBox` -- their inventory stays on their person rather than
---     being scattered for someone else to take. Undoing THAT is impossible
---     once another player has walked over it.
---   * `BR.Evidence.noteKill` and the kill feed -- the feed is how the whole
---     match learns somebody is out, and this player is not out.
---
--- The roster DOES go to DEAD, and that is not a contradiction. Their ped is
--- genuinely dead on their own machine; a roster that disagreed would leave the
--- server-observed health check firing `defeat` at them once a second forever.
--- DEAD is what the client draws off and what stops them shooting; it is the
--- three fields above, not the state string, that a results row is made of.
--- @param src integer
--- @param entry table
--- @param m table
local function holdForStart(src, entry, m)
    -- The knock, if there was one, is over -- same clearing eliminate does, and
    -- for the same reason: a downed player whose bleed clock keeps running would
    -- be eliminated for real thirty seconds into the hold.
    local wasDowned = entry.state == BR.PlayerState.DBNO
    entry.dbnoUntil, entry.downedBy = nil, nil
    entry.reviverSrc, entry.reviveFrom = nil, nil
    entry.reviveBeat, entry.reviveTickAt = nil, nil

    entry.revivePending = true
    BR.Roster.setState(src, BR.PlayerState.OUT)

    if wasDowned then
        TriggerClientEvent(BR.Net.DBNO_SET, src, { downed = false, died = true })
        TriggerClientEvent(BR.Net.HEALTH_SYNC, src, { hp = 0, armour = 0 })
    end

    -- STICKY, BECAUSE THE WAIT IS THE PROBLEM. The reason the issue asks for a
    -- notice at all is that a dead screen with nothing on it reads as "you are
    -- out" -- and this player may be looking at it for the rest of the flight.
    -- A notice that fades after four seconds would leave them in exactly the
    -- silence it was written to break. Keyed and sticky, withdrawn by name when
    -- the revive lands.
    BR.Server.notify(src,
        'You are down, but not out. The match has not started yet -- '
        .. 'you will be revived automatically when it does.',
        'info', { key = 'revive.pending', sticky = true })

    print(('[br_core] %s (%d) died before match %d started -- held for revive, '
        .. 'nothing recorded'):format(entry.name, src, m.id))
end

--- Get a held player back up, on the transition into PLAYING (#144).
---
--- Called from match.lua's onEnter(PLAYING). Public because that is the only
--- caller and it lives in another file -- and because `/brrevive` should never
--- become the second way to do this.
---
--- ORDER IS LOAD-BEARING IN BOTH DIRECTIONS. The client is told to resurrect
--- BEFORE the roster says ALIVE, because the server-observed death check reads
--- `engineHp` from the position sampler and would see a corpse in a state that
--- can die -- and eliminate them again, for real this time, one second into the
--- match they were just given back. `engineHp` is cleared here as well: the
--- sample is up to a second old and clearing it is the difference between "no
--- opinion until the next sample" and "an opinion from before the revive".
--- @param src integer
--- @param entry table
function BR.Combat.reviveHeld(src, entry)
    entry.revivePending = nil

    -- NEITHER OF THESE SHOULD BE SET AND BOTH ARE CLEARED ANYWAY. holdForStart
    -- never writes them, so this is not undoing its work -- it is refusing to
    -- trust that no other path reached this entry while it was held. The cost is
    -- two assignments; the cost of being wrong is a fabricated placement and a
    -- death in DynamoDB that nothing can take back (the fingerprint of both
    -- earlier stats bugs).
    entry.placement, entry.diedAt = nil, nil
    entry.engineHp = nil

    TriggerClientEvent(BR.Net.REVIVED, src)

    -- THE LEDGER LEADS AND THE PED FOLLOWS, which is the reverse of the usual
    -- direction and is why the health audit needs telling. For one round trip
    -- this player's entry says 100 and their ped is still a corpse; the moment
    -- the client applies HEALTH_SYNC the ped crosses back over. The audit in
    -- server/roster.lua reads this stamp so the crossover is not counted as a
    -- client inventing health for itself.
    entry.healthSettleUntil = GetGameTimer()
        + ((BR.Config.Combat.healthAudit or {}).settleMs or 2000)

    BR.Roster.update(src, { hp = 100.0, armour = 0.0 })
    BR.Roster.setState(src, BR.PlayerState.ALIVE)
    TriggerClientEvent(BR.Net.HEALTH_SYNC, src, { hp = 100, armour = 0 })

    BR.Server.notifyClear(src, 'revive.pending')
    BR.Server.notify(src, 'The match has started. You are back in.',
        'success', { ms = 5000 })

    print(('[br_core] revived %s (%d) -- died before the match started')
        :format(entry.name, src))
end

--- Tell a squad that one of them just changed phase -- and never tell the
--- subject.
---
--- "When a squad player goes from alive to DBNO and DBNO to out, a sound effect
--- should be played that all squadmates can hear, except the one which is down.
--- They have their own sounds for this phase." (owner, playtest.)
---
--- THE AUDIENCE IS THE FEATURE, AND IT IS DECIDED HERE. Every client already
--- learns that a mate went down -- the roster delta carries `state`, the squad
--- beacon carries the row, the panel stripe turns red. Any of those could be
--- watched for an edge and turned into a sound, and every one of those clients
--- would then be deciding for itself who is allowed to hear it. Two of them
--- would disagree the first time a delta was coalesced, and the one client that
--- must NOT play it -- the subject, who has their own cue for this and is busy
--- hearing it -- is the client least able to tell the difference. The server
--- knows the squad and the server knows the subject, so the server addresses the
--- envelope and no client ever holds an opinion about it.
---
--- IT RIDES DBNO_SET, which is already the downed channel and already has
--- exactly one handler in the whole client (client/dbno.lua). The `mate` key is
--- what distinguishes the two shapes: an envelope with `mate` is ABOUT SOMEBODY
--- ELSE and says nothing about the receiver's own state, so the handler answers
--- it and returns before it can touch `mine`.
---
--- @param subject integer  who it happened to
--- @param entry table      their roster entry
--- @param phase string     'down' | 'out' | 'up'
local function tellSquad(subject, entry, phase)
    if not entry.squadId then return end
    BR.Roster.each(
        function(e)
            return e.squadId == entry.squadId
               and e.src ~= subject
               and e.matchId == entry.matchId
        end,
        function(mate)
            TriggerClientEvent(BR.Net.DBNO_SET, mate,
                { mate = { src = subject, name = entry.name, phase = phase } })
        end)
end

--- Eliminate a player.
---
--- Placement is assigned as the number of teams still standing INCLUDING this
--- one, computed before the state change. Last of eight teams finishes 8th.
---
--- @param src integer
--- @param cause string
--- @param killerSrc integer|nil
function BR.Combat.eliminate(src, cause, killerSrc)
    local entry = BR.Roster.get(src)
    if not entry or not canDie(entry) then return end

    -- Placement counts THIS match's teams; the kill feed goes to THIS
    -- match's audience. A death in one match is silence in every other.
    local m = BR.Server.matchOf(src)

    -- BEFORE ANYTHING IS WRITTEN DOWN (#144). This has to be the first branch in
    -- the function -- ahead of the placement read, ahead of the death box --
    -- because everything below it is a consequence that cannot be taken back.
    --
    -- 'left' IS EXCLUDED AND THAT IS NOT AN OVERSIGHT. Leaving mid-match is
    -- routed through here on purpose ("leaving while alive IS an elimination",
    -- match.lua) so that quitting cannot be a cheaper exit than dying. A player
    -- who has disconnected or walked out cannot be revived into a match they are
    -- no longer in, and holding their exit open would mean a leaver during the
    -- bus finishes with no placement and no results row at all -- a way out with
    -- no cost, which is the exact thing that funnel exists to prevent.
    --
    -- Everything else IS held, `brkill` included: an admin killing somebody
    -- during the flight is testing this path, and a test tool that took a
    -- different route would be testing itself.
    if cause ~= 'left' and beforeTheMatch(m, entry) then
        holdForStart(src, entry, m)
        return
    end

    local placement = BR.Server.squadsAlive(m)

    -- THE BOX IS BUILT BEFORE THE STATE CHANGES. What they were carrying and
    -- where they were standing are both still true at exactly this moment;
    -- one line later the roster sweep and the CLEANUP reset have opinions
    -- about both. Whoever killed them gets to walk over and take it.
    if m and BR.Loot and BR.Loot.deathBox then
        BR.Loot.deathBox(m, src)
    end

    -- ═══ AND THE KEY IS MINTED ON THE SAME EDGE, WHICH IS THE WHOLE RULE ═══
    --
    -- Owner, 2026-08-30: "The moment that bleed out timer ends and they go to
    -- spectate - their key is created and their inventory is spilled on the
    -- ground" -- and, of the other branch, "if they are revived in-person there,
    -- they can keep their inventory, which is no different from today."
    --
    -- ONE EVENT, NOT TWO. The two halves are stated as one moment, so they get
    -- ONE CALL SITE rather than two rules that happen to agree today: same `if
    -- m` guard, same `src`, same `entry.pos`, one line apart and above the state
    -- change. A squadmate who reaches them during the bleed-out never arrives
    -- here at all, so they keep their kit AND leave no key, with no branch
    -- written anywhere to say so.
    --
    -- IT IS BELOW THE #144 HOLD AND THAT IS LOAD-BEARING. `holdForStart` returns
    -- long before this line, so a player who died before the match started gets
    -- no key -- which is right, because they lost no inventory and are about to
    -- be revived for free. Moving this above that guard would hand their squad a
    -- 25-Volt entitlement for a death that is never recorded.
    --
    -- NOT GUARDED ON WHAT THE DEATH BOX RETURNED. It returns nil for a player
    -- who was carrying nothing, and an empty-handed player must still be
    -- recoverable -- the invariant is the EDGE, not the spill.
    if m and BR.ReviveKey and BR.ReviveKey.onEliminated then
        BR.ReviveKey.onEliminated(m, src)
    end

    -- A BLEED-OUT IS A DEATH THE PED HAS NOT HEARD ABOUT.
    --
    -- Every other route into this function arrives because something already
    -- died: the client watched its own ped go down, or the server read a dead
    -- body. A downed player is the opposite -- their ped is alive, invincible
    -- by design (see the DBNO note in client/natives.lua), and the only thing
    -- that has changed is a number in this file. So flipping the roster to DEAD
    -- and stopping there left the placard on screen, the crawl running and the
    -- player conscious with the match already over for them (owner, in game).
    --
    -- Two instructions, because the client half is two separate facts: stop
    -- being downed, and die. HEALTH_SYNC is the existing verb for the second --
    -- the server saying what a number IS rather than how much to move it.
    local wasDowned = entry.state == BR.PlayerState.DBNO
    entry.dbnoUntil, entry.downedBy = nil, nil
    entry.reviverSrc, entry.reviveFrom = nil, nil
    entry.reviveBeat, entry.reviveTickAt = nil, nil
    -- dbnoCount deliberately survives: it is per MATCH and resets at CLEANUP,
    -- so being finished does not hand the next knock a fresh 45 seconds.

    BR.Roster.setState(src, BR.PlayerState.OUT)
    entry.placement = placement
    -- WHEN THEIR MATCH STOPPED, for the survival term in the XP curve. Written
    -- here because this is the only place a player stops surviving, and read
    -- against m.startedAt -- the same GetGameTimer() clock, deliberately, so
    -- the subtraction means something. Survival XP used to be computed from the
    -- MATCH's duration, which paid the player who died first exactly what it
    -- paid the winner (#99).
    entry.diedAt = GetGameTimer()
    BR.Broadcast.delta({ op = 'update', src = src, e = { placement = placement } })

    if wasDowned then
        TriggerClientEvent(BR.Net.DBNO_SET, src, { downed = false, died = true })
        TriggerClientEvent(BR.Net.HEALTH_SYNC, src, { hp = 0, armour = 0 })
        -- DBNO -> OUT, the second of the owner's two moments. Only from a knock:
        -- a squadmate who was shot dead outright never took a knee, and the kill
        -- feed is what carries that. Sent to the squad and not to them -- they
        -- are watching a verdict screen and have their own sound for it.
        tellSquad(src, entry, 'out')
    end

    local killer = killerSrc and BR.Roster.get(killerSrc)
    if killer and killerSrc ~= src then
        killer.kills = (killer.kills or 0) + 1
        BR.Broadcast.delta({ op = 'update', src = killerSrc, e = { kills = killer.kills } })

        -- WHO TO POINT THE VICTIM'S CAMERA AT, IN SOLOS. "If in solos, the
        -- default spectate target should be the killer (if there was one)" --
        -- the owner, 2026-08-22. server/spectate.lua reads this; nothing else
        -- does, and nothing on the client is ever told it.
        --
        -- A LICENCE, NOT `killerSrc`. FiveM recycles server ids within the
        -- minute and this outlives the moment it is written by design -- the
        -- victim watches this person for the rest of their round. Storing the id
        -- would eventually point a dead player's camera at whoever inherited it,
        -- which is the exact bug server/spectate.lua's own feed re-checks a
        -- licence every 250ms to avoid. It is resolved back to a live id at the
        -- moment of use and never before.
        --
        -- WRITTEN INSIDE THE `killer and killerSrc ~= src` GUARD, so it inherits
        -- both of that guard's facts for free: there is a real roster entry, and
        -- nobody is ever recorded as their own killer. `attributedKiller` has
        -- already refused a stale hit and a killer who has left; a death with no
        -- killer reaches this line with `killerSrc` nil and simply does not run
        -- it -- the storm, a fall, a car with nobody in it (#194) -- so "no
        -- killer" stays nil here, the same representation the kill feed uses.
        entry.killedByLicense = BR.Roster.licenseOf(killerSrc)
    end

    local feed = {
        killer    = killer and killer.name or nil,
        killerSrc = killer and killerSrc or nil,
        victim    = entry.name,
        -- The src matters to exactly one consumer: the victim's own client,
        -- which needs to know HOW it died to pick the right verdict slam --
        -- a storm death is not an "elimination" and should not read as one.
        victimSrc = src,
        cause     = cause,
        placement = placement,
        -- WHAT KILLED THEM, not just that they died. The server has already
        -- established this on the validated damage path; the feed simply
        -- never carried it, so every line in the corner read the same and the
        -- one question a kill feed exists to answer -- what am I up against
        -- -- had no answer on screen. Only meaningful WITH a killer: a fall
        -- has no weapon and inventing one would be a lie with an icon.
        weapon    = killer and entry.lastHitWeapon or nil,
        headshot  = (cause == 'headshot') or nil,
    }
    -- Keep it, in case an incident needs it later. The kill feed is a client
    -- broadcast that nothing persists, so this is the only record that a
    -- particular player killed a particular other one -- which is most of what
    -- a teaming or griefing report turns on. Recorded against BOTH sides; see
    -- BR.Evidence.noteKill for why a player's own deaths are evidence too.
    if BR.Evidence then BR.Evidence.noteKill(feed) end

    if m then
        BR.Broadcast.toMatch(m, BR.Net.KILL_FEED, feed)
    else
        -- No instance resolvable (a brkill on an odd state); the victim at
        -- least must hear about their own death.
        TriggerClientEvent(BR.Net.KILL_FEED, src, feed)
    end

    print(('[br_core] eliminated %s (%d) -- placement %d%s')
        :format(entry.name, src, placement,
                killer and (' by ' .. killer.name) or (' (' .. tostring(cause) .. ')')))

    -- No system chat: the kill feed already carries this to every client,
    -- and the chat is for players talking (user rule, 2026-08-03).
end

--- What GET_PED_CAUSE_OF_DEATH's weapon hash means in words.
---
--- The client reports the raw hash; translating it HERE keeps the wire format
--- dumb and the mapping in one place. Built lazily because GetHashKey is what
--- computes the keys (a raw hash literal in source broke luac once already),
--- and normalised to unsigned because hash sign conventions differ between
--- the native's return and Lua's arithmetic.
local causeByHash = nil

local function describeCause(raw)
    if type(raw) ~= 'number' then
        return (type(raw) == 'string') and raw or 'unknown'
    end
    if not causeByHash then
        causeByHash = {}
        local function put(weapon, key)
            causeByHash[GetHashKey(weapon) & 0xFFFFFFFF] = key
        end
        put('WEAPON_FALL',                 'fall')
        put('WEAPON_DROWNING',             'drowned')
        put('WEAPON_DROWNING_IN_VEHICLE',  'drowned')
        put('WEAPON_FIRE',                 'burned')
        put('WEAPON_EXPLOSION',            'explosion')
        put('WEAPON_RAMMED_BY_CAR',        'roadkill')
        put('WEAPON_RUN_OVER_BY_CAR',      'roadkill')
    end
    return causeByHash[raw & 0xFFFFFFFF] or 'unknown'
end

--- Who killed this player, according to the SERVER's own record of who has
--- been shooting them.
---
--- THE CLIENT IS NEVER ASKED, and it no longer could answer usefully anyway.
--- M6 cancels the engine's damage and applies its own, so GTA's idea of who
--- shot whom is gone by the time the ped dies -- the killing blow is our
--- SetEntityHealth, and the client honestly reports no killer. That is why
--- every elimination read "0 eliminations" on the summary (user, 2026-08-08):
--- the attribution was waiting for M6 and M6 had removed the thing it was
--- waiting on.
---
--- `lastHitBy` is written by the validated damage path, so it is a fact the
--- server established, not a claim it received. The window is what makes storm
--- and fall damage credit the shooter: finish someone who was already bleeding
--- from your rifle and it is still your kill.
--- @param entry table  the victim's roster entry
--- @return integer|nil killer src
function BR.Combat.attributedKiller(entry)
    if not entry or not entry.lastHitBy then return nil end

    local window = BR.Config.Match.assistWindowMs or 10000
    if GetGameTimer() - (entry.lastHitAt or 0) > window then return nil end

    -- Never credit somebody for their own death, and never credit a player who
    -- has since left.
    if entry.lastHitBy == entry.src then return nil end
    if not BR.Roster.get(entry.lastHitBy) then return nil end

    return entry.lastHitBy
end

--- Who gets this death, including the one attributor that runs too late.
---
--- BR.Vehicles' roadkill ledger writes `lastHitBy` from the roster's own 4 Hz
--- sample, which covers every vehicular death that took more than a quarter of a
--- second to arrive -- a glancing hit, a knock that bleeds out, a player finished
--- by the storm afterwards. It does NOT cover the ordinary case, which is a car
--- at speed turning a full-health player into a corpse between two samples: the
--- victim's client reports the death immediately and this function runs before
--- the sampler next fires.
---
--- So an unattributed death gets one look, HERE, at the freshest state the server
--- holds. It costs nothing on the common path -- a death with a killer never
--- reaches the second branch, and a death without one is rare -- and it reads
--- exactly the same tables the sampler does. Nothing from the wire is consulted:
--- `data.killer` and `data.cause` are the client's GET_PED_SOURCE_OF_DEATH and
--- are ignored here as they have been since M6.
--- @param src integer
--- @param entry table
--- @return integer|nil killer src
local function killerOf(src, entry)
    local killer = BR.Combat.attributedKiller(entry)
    if killer then return killer end

    if BR.Vehicles and BR.Vehicles.creditRoadkill
       and BR.Vehicles.creditRoadkill(src) then
        return BR.Combat.attributedKiller(entry)
    end
    return nil
end

-- --------------------------------------------------------------------------
-- DBNO: down, bleed, revive
-- --------------------------------------------------------------------------
--
-- THE BLEED TIMER IS THE DOWNED PLAYER'S HEALTH (owner's call, 2026-08-09).
-- There is no second health bar and no knocked-HP pool: enemy fire takes
-- SECONDS off the clock, the storm takes seconds off the clock, and the clock
-- reaching zero is the death. That choice is what makes the state readable from
-- the outside -- a body still crawling has time left on it, a body that has
-- stopped does not -- and it is why the downed player's own overlay is a
-- countdown rather than a bar.
--
-- Everything below is the server's. The client is told what its state is and
-- shows it; a client that ignores DBNO_SET entirely still bleeds out at exactly
-- the same moment, because the ledger is here.

--- How long this knock lasts, in ms.
---
--- Each knock in the same match is shorter (dbnoBleedStep is negative), floored
--- at dbnoBleedMin -- so a squad cannot farm revives out of one long fight. The
--- counter is per MATCH and is wiped with everything else at CLEANUP.
--- @param entry table
--- @return integer
local function bleedMsFor(entry)
    local n = entry.dbnoCount or 1
    local secs = M.dbnoBleedBase + M.dbnoBleedStep * (n - 1)
    if secs < M.dbnoBleedMin then secs = M.dbnoBleedMin end
    return math.floor(secs * 1000)
end

--- Is there anybody who could actually come and pick this player up?
---
--- ALIVE, or still on canopy -- a mate mid-glide can land and revive, so they
--- count. A DBNO mate does NOT: a squad that is entirely down has nobody left
--- who can crawl over and hold a key, so the last knock of a wipe is a death
--- rather than four bodies waiting out four timers with nothing to wait for.
--- @param entry table
--- @return boolean
local function hasStandingMate(entry)
    if not entry.squadId then return false end

    local found = false
    BR.Roster.each(
        function(e)
            return e.squadId == entry.squadId
               and e.src ~= entry.src
               and e.matchId == entry.matchId
               and (e.state == BR.PlayerState.ALIVE
                 or e.state == BR.PlayerState.FREEFALL
                 or e.state == BR.PlayerState.GLIDE)
        end,
        function() found = true end)
    return found
end

--- Would running out of health knock this player down rather than kill them?
---
--- Public because BR.Damage.applyHit has to ask BEFORE it writes any health:
--- the answer changes how much damage the victim is instructed to apply to
--- their own ped, and a knock has to leave that ped alive.
--- @param entry table
--- @return boolean
function BR.Combat.canBeDowned(entry)
    if not entry or entry.state ~= BR.PlayerState.ALIVE then return false end

    local m = entry.matchId and BR.Server.matches[entry.matchId]
    if not m then return false end

    -- ═══ SQUADS BY MODE, SOLOS BY INVENTORY (#191) ═══
    --
    -- This used to be one gate -- the mode's `dbno` flag -- with a note saying
    -- solo DBNO would arrive when there was finally something that could pick a
    -- lone player up. That is the CPR kit, and it arrived, but NOT in the shape
    -- the note predicted: the note expected `BR.Mode.SOLO.dbno = true`, and that
    -- is emphatically not the change.
    --
    -- `BR.Mode.SOLO.dbno` STAYS FALSE, and the reason is the whole design. The
    -- mode's flag is a statement about the MODE -- "in this mode, running out of
    -- health means being knocked down" -- and in solos that is still false for
    -- almost every player almost all of the time. Flipping it would knock down
    -- every solo player in every match and leave them on the floor with no kit,
    -- no mate and no ambulance, which is the "slower death and a worse one" the
    -- old note was written to avoid. What the kit changes is not the mode; it is
    -- one player's own death, and only while they are carrying the item.
    --
    -- SO THE TWO ARMS ARE GENUINELY DIFFERENT QUESTIONS and are written as such:
    --
    --   SQUAD: the mode says yes, and then -- is anybody left who could actually
    --   come and pick them up? A squad that is entirely down has nobody, so the
    --   last knock of a wipe is a death.
    --
    --   SOLO: the mode says no, and then -- are they carrying a CPR kit? Nobody
    --   can ever revive them (see below), so the kit is not "somebody could pick
    --   them up", it is "they can call an ambulance", and the answer is in their
    --   inventory rather than on the roster.
    --
    -- ═══ AND NO SOLO KNOCKED THIS WAY IS REVIVABLE. IT ALREADY COSTS NOTHING ═══
    --
    -- #191: "No revive is possible -- the only exits are the item or the
    -- bleed-out timer." That is enforced by three things this change did not
    -- have to touch, and it is worth naming them so nobody later "fixes" one:
    --
    --   * reviveAllowed() below requires `reviver.squadId == target.squadId`,
    --     and a solo player has no squadId at all -- so `nil ~= nil` is false and
    --     every revive request is refused server-side.
    --   * client/dbno.lua's revive scan returns early on `not me.squadId`, so a
    --     solo client never even looks for a body to hold a key on.
    --   * hasStandingMate() is not consulted on this arm, so nothing here
    --     implies a rescuer exists.
    --
    -- The kit therefore makes solo death conditional WITHOUT making solo revive
    -- possible, which is exactly the pair #191 asked for.
    --
    -- ═══ SOLOS ONLY. THE SQUAD LOCKOUT WAS WITHDRAWN ═══
    --
    -- Owner, 2026-08-23: "CPR kit only in solos". Earlier the same day he
    -- described the kit working in SQUADS instead, with a revive lockout as its
    -- cost -- "when used in squads, immediately prevents that player from being
    -- revived by any other players for that one use". The later message wins and
    -- the lockout IS NOT BUILT. A squad player holding a kit falls through the
    -- squad arm below and gets exactly what they have always got. Recorded here
    -- because the issue thread still contains both quotes.
    if BR.ResolveMode(m.mode).dbno then
        return hasStandingMate(entry)
    end

    -- ASKED OF THE INVENTORY, and asked LAST, so the ordinary solo death -- the
    -- overwhelmingly common case -- costs one table lookup on the mode and stops.
    -- BR.Damage.applyHit calls this before it writes any health, on every lethal
    -- hit in every match, so the cheap answer has to be on the cheap path.
    return BR.Rescue ~= nil and BR.Rescue.holdsKit(entry)
end

--- 0..1 through the revive currently being held on this player.
--- @param entry table
--- @return number
local function revivePctOf(entry)
    if not entry.reviveFrom then return 0.0 end
    local total = (M.dbnoReviveTime or 8.0) * 1000.0
    if total <= 0 then return 1.0 end
    return BR.Clamp((GetGameTimer() - entry.reviveFrom) / total, 0.0, 1.0)
end

--- Tell a player what their own downed state is.
---
--- THE WHOLE PAYLOAD, EVERY TIME. Five fields that change on events a human
--- causes; a merge protocol for that would be more code than the feature.
--- @param src integer
function BR.Combat.pushDbno(src)
    local e = BR.Roster.get(src)
    if not e then return end

    if e.state ~= BR.PlayerState.DBNO then
        TriggerClientEvent(BR.Net.DBNO_SET, src, { downed = false })
        return
    end

    local by = e.downedBy and BR.Roster.get(e.downedBy) or nil
    local r  = e.reviverSrc and BR.Roster.get(e.reviverSrc) or nil

    TriggerClientEvent(BR.Net.DBNO_SET, src, {
        downed      = true,
        bleedEndsAt = e.dbnoUntil or 0,
        byName      = by and by.name or nil,
        reviverName = r and r.name or nil,
        revivePct   = revivePctOf(e) * 100.0,
    })
end

--- Put a player down.
--- @param src integer
--- @param killerSrc integer|nil
function BR.Combat.knock(src, killerSrc)
    local entry = BR.Roster.get(src)
    if not entry then return end

    entry.dbnoCount  = (entry.dbnoCount or 0) + 1
    entry.dbnoUntil  = GetGameTimer() + bleedMsFor(entry)
    entry.reviverSrc, entry.reviveFrom = nil, nil
    entry.reviveBeat, entry.reviveTickAt = nil, nil

    -- WHO OWNS THE FINISH IF NOBODY EVER TOUCHES THEM AGAIN, and this is the
    -- trap the whole field exists for. BR.Combat.attributedKiller expires at
    -- assistWindowMs (10s) and a bleed runs 40-120s, so a player who is knocked
    -- and simply left alone would be credited to nobody -- the same shape as
    -- the "0 eliminations" summary M6 had to fix. downedBy does not expire: it
    -- is cleared by a revive or by the match ending, and by nothing else.
    if killerSrc and killerSrc ~= src then
        entry.downedBy = killerSrc
        local killer = BR.Roster.get(killerSrc)
        if killer then
            -- A KNOCK IS ITS OWN STATISTIC. It is not a kill -- the revive may
            -- undo it -- and the summary has carried a `downs` column since M1
            -- with nothing ever writing to it.
            killer.downs = (killer.downs or 0) + 1
        end
    end

    -- The ledger holds them just above zero. See dbnoHp in config/match.lua for
    -- the two separate things that break when it is zero.
    BR.Roster.update(src, { hp = (M.dbnoHp or 5) + 0.0, armour = 0.0 })
    BR.Roster.setState(src, BR.PlayerState.DBNO)

    -- THE SAMPLE FROM BEFORE THE KNOCK MUST NOT OUTLIVE IT.
    --
    -- `engineHp` is up to 250ms old and, on every damage path the engine still
    -- owns, it is a reading of a CORPSE: a fall, a fire, drowning or a car kills
    -- the ped outright, and the knock that follows is the server deciding that
    -- death means "down" instead. Left in place, the server-observed death check
    -- reads that stale zero and finishes a player it knocked a fraction of a
    -- second ago. Cleared for exactly the reason reviveHeld clears it -- no
    -- opinion until the next sample beats an opinion from before the event.
    entry.engineHp = nil

    BR.Combat.pushDbno(src)

    -- ...AND THE PED IS PUT ON THE DOWNED FLOOR, WHATEVER PUT THEM THERE.
    --
    -- Sent AFTER pushDbno, and the order is load-bearing: DBNO_SET is what makes
    -- the client resurrect a ped the world killed (client/dbno.lua), and a
    -- resurrection restores GTA's default health -- so a health write that
    -- arrived first would simply be overwritten by it.
    --
    -- This used to be implicit and only true down one path. BR.Damage.applyHit
    -- clamps a knocking shot so the victim's ped survives at this floor, so a
    -- GUNSHOT knock landed on the right number by construction. Nothing clamps a
    -- fall, so a player who dropped from a height was handed the downed STATE
    -- with a dead ped reading zero -- no crawl, no health, and no way back
    -- (owner, 2026-08-16). The server cannot write a ped; it can say what the
    -- number is, which is the contract HEALTH_SYNC already exists for.
    TriggerClientEvent(BR.Net.HEALTH_SYNC, src, { hp = M.dbnoHp or 5, armour = 0 })

    -- ...AND IN SOUND, which is the half that does not need them to be looking
    -- anywhere at all. ALIVE -> DBNO, the first of the owner's two moments.
    tellSquad(src, entry, 'down')

    -- THE SQUAD IS TOLD IN WORDS, not only in pixels. The panel stripe and the
    -- [DOWN] gamer tag both already say this, and both require the mate to be
    -- looking at the right thing -- which in a firefight is exactly what they
    -- are not doing.
    if entry.squadId then
        BR.Roster.each(
            function(e) return e.squadId == entry.squadId and e.src ~= src end,
            function(mate)
                -- HIS EXCLAMATION MARK, 2026-08-31, and his rule about the
                -- name: "Any time we mention a player by name in a toast their
                -- name should be bold." BR.Notice.line is what carries that
                -- without ever putting formatting inside the name -- see
                -- br_lib/shared/notice.lua.
                BR.Server.notify(mate,
                    BR.Notice.line('%s is down!', BR.Notice.who(entry.name)),
                    'warn', { key = 'dbno.' .. src, ms = 6000 })
            end)
    end

    print(('[br_core] %s (%d) is DOWN -- %.0fs to bleed out%s')
        :format(entry.name, src, bleedMsFor(entry) / 1000.0,
                killerSrc and (' (by %d)'):format(killerSrc) or ''))
end

--- This player has run out of health. THE one verb for it.
---
--- Every caller that used to reach eliminate() directly comes here instead, so
--- "down or dead" is answered once rather than four times in four files.
--- @param src integer
--- @param cause string
--- @param killerSrc integer|nil
function BR.Combat.defeat(src, cause, killerSrc)
    local entry = BR.Roster.get(src)
    if not entry or not canDie(entry) then return end

    if BR.Combat.canBeDowned(entry) then
        BR.Combat.knock(src, killerSrc)
        return
    end

    BR.Combat.eliminate(src, cause, killerSrc)
end

--- Take time off a downed player's clock.
---
--- The conversion is the whole model: `amount` is DISPLAY damage, exactly what
--- would have come off a standing player's health, and dbnoBleedPerDamage turns
--- it into seconds. Storm damage comes through here too, with no shooter -- a
--- player knocked inside the wall bleeds out fast, which is the honest outcome
--- and saves inventing a second rule for it.
--- @param src integer
--- @param amount number      display-unit damage
--- @param shooterSrc integer|nil
--- @param meta table|nil     { weapon }
function BR.Combat.bleed(src, amount, shooterSrc, meta)
    local e = BR.Roster.get(src)
    if not e or e.state ~= BR.PlayerState.DBNO then return end
    if not amount or amount <= 0.0 then return end

    local now = GetGameTimer()
    e.dbnoUntil = (e.dbnoUntil or now)
                - math.floor(amount * (M.dbnoBleedPerDamage or 0.35) * 1000)

    if shooterSrc and shooterSrc ~= src then
        e.lastHitBy     = shooterSrc
        e.lastHitAt     = now
        e.lastHitWeapon = (meta and meta.weapon) or e.lastHitWeapon
        -- The last person to shoot them owns the finish, whether the clock runs
        -- out under their fire or a few seconds after they walked away.
        e.downedBy = shooterSrc
    end

    -- Same rule as the tick below: a player being carried is not finishable by
    -- a clock. Damage still shortens the deadline they return to if the rescue
    -- fails, which is why this subtracts before it checks rather than instead.
    if not e.rescue and e.dbnoUntil <= now then
        BR.Combat.eliminate(src, 'finished', e.downedBy)
        return
    end

    BR.Combat.pushDbno(src)
end

-- ----------------------------------------------------------------- revive ---

--- Everything that has to be true for a revive to still be running.
---
--- Re-checked EVERY tick rather than only when the hold starts, which is what
--- makes the cancellation rules free: walking away, being knocked yourself,
--- the target dying and the match ending are all just this returning false.
---
--- IT ANSWERS WHY, AND THAT IS THE SERVER HALF OF #163's INSTRUMENT. Six
--- separate facts used to collapse into one word, `notallowed`, which is what a
--- reviver was told four times a second while nobody could say which of the six
--- it was. The reason is carried into refuseRevive and stopRevive, printed by
--- /brdbno, and -- for the one that is a number -- carries the number.
--- @param reviver table|nil
--- @param target table|nil
--- @return boolean allowed, string|nil why not
local function reviveAllowed(reviver, target)
    if not reviver or not target then return false, 'no such player' end
    if reviver.state ~= BR.PlayerState.ALIVE then
        return false, 'the reviver is ' .. tostring(reviver.state)
    end
    if target.state ~= BR.PlayerState.DBNO then
        return false, 'the target is ' .. tostring(target.state) .. ', not down'
    end
    if not reviver.matchId or reviver.matchId ~= target.matchId then
        return false, 'different matches'
    end
    if not reviver.squadId or reviver.squadId ~= target.squadId then
        return false, 'different squads'
    end

    -- MEASURED FROM THE SERVER'S OWN POSITION SAMPLES, never from anything a
    -- client said -- the rule the loot claim already follows, with the same
    -- slack for the same 250ms sampling skew.
    local a, b = reviver.pos, target.pos
    -- NAMED SEPARATELY, because "the server has never sampled this player"
    -- looks nothing like "they walked away" and used to read as the same
    -- refusal. It means OneSync or the position job, not the player.
    if not a then return false, 'no position sampled for the reviver' end
    if not b then return false, 'no position sampled for the target' end

    local reach = (M.dbnoReviveDist or 1.5) + (M.dbnoReviveSlack or 1.0)
    local d = BR.Dist3(a.x, a.y, a.z, b.x, b.y, b.z)
    if d > reach then
        return false, ('%.2fm apart, server reach is %.2fm'):format(d, reach)
    end
    return true
end

--- Stop whatever revive is running on this player. Harmless if none is.
--- @param src integer
--- @param entry table
--- @param reason string|nil
local function stopRevive(src, entry, reason)
    local reviverSrc = entry.reviverSrc
    if not reviverSrc then return end

    -- HOW FAR IT HAD GOT WHEN IT DIED, kept for /brdbno. A hold that is being
    -- killed and restarted reads as a string of identical percentages here,
    -- which is the signature of the client re-arming rather than of a player
    -- who cannot hold a key -- and it is the number that was missing when the
    -- last three rounds had to guess between the two.
    entry.reviveLastPct = revivePctOf(entry) * 100.0
    entry.reviveStopWhy = reason
    entry.reviveStopAt  = GetGameTimer()
    entry.reviveStops   = (entry.reviveStops or 0) + 1

    entry.reviverSrc, entry.reviveFrom = nil, nil
    entry.reviveBeat, entry.reviveTickAt = nil, nil

    TriggerClientEvent(BR.Net.REVIVE_PROGRESS, reviverSrc,
        { pct = 0.0, target = src, cancelled = true, reason = reason })
    BR.Combat.pushDbno(src)
end

--- The hold landed -- or an admin said it did.
---
--- Public so `/brrevive` runs the SAME path a player's eight seconds run,
--- rather than a shortcut that could keep working while the feature does not.
--- `hp` IS THE THIRD CALLER'S DOING (#191) AND DEFAULTS TO THE OLD BEHAVIOUR.
--- A squad revive and an admin revive both hand back `dbnoReviveHp`; the CPR
--- kit's ambulance hands back full health, because it is an ultra-rare item
--- spent in full on a ride the player could not shoot back during. The
--- alternative was for server/rescue.lua to call this and then correct the
--- health afterwards, which is two health writes and a visible flicker between
--- them -- and the undo below (the bleed deadline, the owed kill, the client's
--- downed mirror) is what nobody may skip, so routing every revive through here
--- matters more than keeping the signature short.
---
--- @param src integer
--- @param reviverSrc integer|nil  credited with the revive; nil for an admin
--- @param hp number|nil  display health to come back on; default dbnoReviveHp
function BR.Combat.revive(src, reviverSrc, hp)
    local entry = BR.Roster.get(src)
    if not entry or entry.state ~= BR.PlayerState.DBNO then return end

    hp = hp or (M.dbnoReviveHp or 30)

    reviverSrc = reviverSrc or entry.reviverSrc
    local reviver = reviverSrc and BR.Roster.get(reviverSrc) or nil

    entry.reviverSrc, entry.reviveFrom = nil, nil
    entry.reviveBeat, entry.reviveTickAt = nil, nil
    -- The knock is UNDONE, not merely paused: whoever put them down no longer
    -- owns a finish that is not going to happen.
    entry.dbnoUntil, entry.downedBy = nil, nil

    -- The same crossover reviveHeld describes, and this is the path #191's
    -- ambulance delivery arrives on as well: the ledger is written here and the
    -- ped only reaches this number when the client applies the HEALTH_SYNC
    -- below. Stamped before the write so no sample can land in between.
    entry.healthSettleUntil = GetGameTimer()
        + ((BR.Config.Combat.healthAudit or {}).settleMs or 2000)

    BR.Roster.update(src, { hp = hp + 0.0, armour = 0.0 })
    BR.Roster.setState(src, BR.PlayerState.ALIVE)

    if reviver then
        reviver.revives = (reviver.revives or 0) + 1
    end

    -- The server cannot write a ped, so it says what the number IS and the
    -- client applies it -- the same contract the storm and the validated shot
    -- already use, in absolute form rather than as a delta.
    TriggerClientEvent(BR.Net.HEALTH_SYNC, src,
        { hp = hp, armour = 0 })
    BR.Combat.pushDbno(src)

    -- ...AND THE SQUAD HEARS IT, which is the third of the three phases this
    -- channel carries (owner, 2026-08-18: "when a player is revived all squad
    -- mates should hear a success sound").
    --
    -- SENT FROM HERE AND NOT FROM THE HOLD THAT CAUSED IT, because this is the
    -- one function every revive goes through: a completed eight seconds,
    -- `/brrevive`, and anything later that decides to put somebody back on
    -- their feet all land here. A cue raised at the end of the hold instead
    -- would be silent for the admin path and would fire for a hold that was
    -- refused on the last tick.
    --
    -- The subject is excluded by tellSquad and that is deliberate and
    -- unchanged: they are being told in words ("X picked you up") on the line
    -- below, and the whole reason the server owns the audience is that the
    -- subject is the one client that must not hear the squad's version.
    tellSquad(src, entry, 'up')

    if reviverSrc then
        TriggerClientEvent(BR.Net.REVIVE_PROGRESS, reviverSrc,
            { pct = 100.0, target = src, done = true })
        BR.Server.notify(reviverSrc,
            BR.Notice.line('You picked %s up.', BR.Notice.who(entry.name)),
            'success', { ms = 4000 })
    end
    BR.Server.notify(src,
        reviver and BR.Notice.line('%s picked you up.',
                                   BR.Notice.who(reviver.name))
                 or 'You were revived.',
        'success', { ms = 4000 })

    print(('[br_core] %s (%d) was revived%s')
        :format(entry.name, src, reviver and (' by ' .. reviver.name) or ''))
end

--- One downed player's share of the 250ms job.
--- @param src integer
--- @param entry table
--- @param now number
local function stepDowned(src, entry, now)
    local reviverSrc = entry.reviverSrc
    if reviverSrc then
        -- THE REVIVE IS STEPPED FIRST, and the ordering is deliberate: a hold
        -- that completes on the same tick the clock expires should save them.
        -- They earned it, and the alternative is a player dying underneath a
        -- full progress ring.
        local reviver = BR.Roster.get(reviverSrc)

        local allowed, why = reviveAllowed(reviver, entry)
        if not allowed then
            stopRevive(src, entry, 'interrupted: ' .. tostring(why))

        elseif now - (entry.reviveBeat or 0) > (M.dbnoReviveBeatMs or 750) then
            -- THE HOLDER WENT QUIET. A revive is only alive while the client
            -- keeps saying so; a lost REVIVE_STOP used to hand out a completed
            -- eight-second hold for a tap (owner, in game). Requiring evidence
            -- rather than trusting one message makes the failure cost a
            -- fraction of a second instead of the whole interaction.
            stopRevive(src, entry, ('released: nothing heard for %dms')
                :format(now - (entry.reviveBeat or 0)))

        elseif math.max(reviver.lastHitAt or 0, reviver.lastStormAt or 0)
               > (entry.reviveFrom or 0) then
            -- CANCELLED BY THE REVIVER'S DAMAGE, not the downed player's.
            -- Picking somebody up is the thing you cannot do while being shot,
            -- which is the entire reason it takes eight seconds in the open.
            --
            -- WHICH of the two, because they are different bugs if this turns
            -- out to be firing when it should not: a storm tick lands on
            -- everybody standing in the wall, a hit lands on one person.
            stopRevive(src, entry,
                ((reviver.lastStormAt or 0) > (reviver.lastHitAt or 0))
                    and 'hurt: the reviver is taking storm damage'
                    or  'hurt: the reviver was shot mid-hold')

        else
            local pct = revivePctOf(entry)
            if pct >= 1.0 then
                BR.Combat.revive(src, reviverSrc)
                return
            end
            -- THE CLOCK STOPS WHILE SOMEBODY IS ON THEM (owner, 2026-08-09).
            --
            -- A revive begun with three seconds left still ended in a death,
            -- which reads as the game ignoring the thing you did rather than
            -- as a race you lost -- and the eight-second hold is already the
            -- risk. So the deadline is pushed along with the tick while the
            -- hold is genuinely progressing, which pauses the bleed without
            -- needing a second notion of "paused" that everything else would
            -- have to know about.
            --
            -- It is the ONLY thing that moves the deadline forward. Damage
            -- moves it back, and stopping the hold simply stops this.
            entry.dbnoUntil = (entry.dbnoUntil or now) + (now - (entry.reviveTickAt or now))
            entry.reviveTickAt = now

            -- ...AND THE MOVED DEADLINE GOES BACK TO THE PLAYER IT BELONGS TO.
            --
            -- THE PAUSE ABOVE HAS ALWAYS WORKED AND HAS NEVER BEEN VISIBLE, and
            -- that is the whole of "while actively reviving, the DBNO timer does
            -- not stop" (owner, 2026-08-18). The number the downed player WATCHES
            -- is not this one: DBNO_SET carries `bleedEndsAt` to their client,
            -- their client hands it to the interface, and ui-src's DbnoOverlay
            -- counts down from it on requestAnimationFrame -- continuously, on
            -- the browser's own clock, against whatever deadline it was last
            -- given. DBNO_SET is sent on EDGES. The last edge before a hold is
            -- the hold registering, so the browser spent the entire revive
            -- counting down from a deadline this line had already moved four
            -- times a second and never mentioned.
            --
            -- Carried on the tick that already exists rather than by pushing a
            -- second envelope beside it: this payload is the only thing sent
            -- while a hold runs, and both ends of the clock now travel together.
            -- It reaches the reviver too, who is a squadmate and already sees
            -- this exact number on the squad beacon (server/party.lua).
            local payload = { pct = pct * 100.0, target = src,
                              reviverName = reviver.name,
                              bleedEndsAt = entry.dbnoUntil }
            TriggerClientEvent(BR.Net.REVIVE_PROGRESS, reviverSrc, payload)
            TriggerClientEvent(BR.Net.REVIVE_PROGRESS, src, payload)
        end
    else
        entry.reviveTickAt = nil
    end

    -- ═══ A PLAYER ON THE AMBULANCE DOES NOT BLEED OUT ═══
    --
    -- Owner, 2026-08-28, first ride that reached the server: "My ped stayed in
    -- place while the timer continued for some reason... Then the timer expired
    -- and I died."
    --
    -- BR.Rescue.begin sets `rescue` and hands the ride to the client, and that
    -- was the whole of it -- nothing ever stopped the clock that was already
    -- running. The countdown that made the kit worth using went on counting and
    -- finished the player mid-rescue.
    --
    -- THE GUARD IS ON THE FLAG, NOT ON A CLEARED TIMER. Clearing dbnoUntil
    -- would work until a rescue fails: RESCUE_LOST puts the player back in
    -- DBNO, and a cleared clock would leave them downed forever with nothing to
    -- finish them. Suspending it keeps the deadline intact for exactly that
    -- return, and `rescue` is already the flag storm.lua reads for the same
    -- reason -- a player in the back of an ambulance is not available to be
    -- killed by anything the match is doing outside it.
    if not entry.rescue and now >= (entry.dbnoUntil or 0) then
        BR.Combat.eliminate(src, 'bledout', entry.downedBy)
    end
end

-- ═══ A BLEED CLOCK BELONGS TO A LIVE MATCH, AND STOPS WITH IT ═══
--
-- Owner, 2026-08-29: "When one player is in the ambulance and the only other
-- remaining player(s) die, the verdict shown is 'VICTORY ROYALE' along with
-- ALSO the cause of DBNO on top of it."
--
-- THE SECOND VERDICT WAS A REAL ELIMINATION, PUBLISHED AFTER THE MATCH ENDED,
-- and the chain is worth writing down because every link in it is correct on
-- its own:
--
--   1. A player on the ambulance is DBNO for the whole ride -- deliberately;
--      server/rescue.lua and the DBNO section above both turn on it -- and
--      BR.Server.isInMatch counts DBNO. So they are a squad still standing, the
--      last other player dying ends the match, and awardPlacements hands them
--      placement 1. They win, and publishResults banks it, at ENDED.
--   2. server/rescue.lua's tick sees a match that is no longer PLAYING and
--      clears `rec`/`entry.rescue`. Correct: that ride is over and it is not
--      that file's business to eliminate anybody.
--   3. ...which un-suspends the clock below. The suspension is deliberately a
--      GUARD on the flag rather than a cleared deadline (see the note in
--      stepDowned), so `dbnoUntil` is still the timestamp it had when the
--      ambulance picked them up -- long past. The very next 250ms tick
--      eliminated the winner for 'bledout'.
--   4. The client had already dismissed its match surfaces on the ENDED
--      transition. The DEAD delta arrived after that, BR.NoteDeath put the word
--      back up, and nothing was left to take it down -- so the death word sat
--      over VICTORY ROYALE for the ~3.4s until the verdict screen's backdrop
--      reached black and the roster swept the player home.
--
-- THE FIX IS AT (3) BECAUSE (3) IS THE ONLY WRONG LINK. Nothing should be
-- finished by a clock belonging to a match that is over: the results are
-- published, the placements are awarded, and an elimination after that point
-- can only ever contradict something already written down.
--
-- THE SAME GATE combat.deathcheck ALREADY USES, in the same shape and for the
-- same reason -- per player against THEIR match, because matches advance
-- independently, and BUS is live because #144's held death runs through here
-- (a player who bleeds out before PLAYING must still reach holdForStart, or
-- they are never revived into the round).
--
-- IT STOPS THE REVIVE HALF TOO, and that is right rather than incidental: a
-- hold that completed after the winner was decided would stand somebody up in
-- a finished match.
BR.Sched.every(250, 'combat.dbno', function()
    local now = GetGameTimer()
    BR.Roster.each(
        function(e)
            if e.state ~= BR.PlayerState.DBNO then return false end
            local m = e.matchId and BR.Server.matches[e.matchId]
            return m ~= nil and (m.state == BR.MatchState.PLAYING
                              or m.state == BR.MatchState.BUS)
        end,
        function(src, entry) stepDowned(src, entry, now) end)
end)

-- ==========================================================================
-- #246: A BODY STREAMED IN LATE IS DRAWN WHERE THE KNOCK HAPPENED.
-- ==========================================================================
--
-- "After a player dies and their ped is placed on the ground OR MOVES in the
-- crawling position, then another player from outside the cell comes into the
-- cell and arrives at the scene - the dead ped's position on the alive player's
-- screen is in the same position where the death happened." (owner, 2026-08-30.)
--
-- THIS IS THE REPORT client/dbno.lua PREDICTED, AND IT NAMED THE ARM. The #164
-- block in that file ends with the sentence this exists to answer:
--
--   "a client that streams the body in LATER, with no re-task in between,
--    builds its clone from the task as it stands and is not covered by a step
--    that has already been performed. ... it should arm off the scope change
--    rather than off a clock."
--
-- SO THE ARM IS `playerEnteredScope`, AND THE PAYLOAD IS NOT WHAT IT LOOKS
-- LIKE. Read off ServerGameState.cpp rather than off a forum post, because the
-- two fields are one word apart in the docs and swapping them would nudge the
-- wrong machine forever:
--
--     evMan->QueueEvent2("playerEnteredScope", {},
--         { { "player", entityClient->GetNetId() },
--           { "for",    client->GetNetId() } });
--
-- and the block it sits in is `if (!syncData.hasCreated) { if (IsBigMode()) {
-- if (entity->type == NetObjEntityType::Player) {`. So:
--
--   * `data.player` is the OWNER OF THE PLAYER PED BEING CREATED -- the body.
--   * `data.for` is the CLIENT THE CLONE IS BEING BUILT FOR -- the newcomer.
--   * it fires on the tick the clone is created, once per pair, and its twin
--     `playerLeftScope` fires when that clone is destroyed.
--
-- BOTH ARE INSIDE `IsBigMode()`, WHICH IS NOT "ONESYNC" -- IT IS ONESYNC
-- INFINITY. On onesync legacy the events never fire at all and this whole file
-- section is dead code. server.cfg.example sets `onesync on`, which is the
-- bigmode value (ServerGameState.cpp reports "on" vs "legacy" off the same
-- predicate), so it is live on this deployment -- but a box switched to legacy
-- loses the fix silently, which is what the `entered` counter in /brdbno is for.
--
-- WHY THE SERVER ASKS THE OWNER INSTEAD OF DOING IT ITSELF. There is no
-- server-side SET_ENTITY_COORDS. ServerGameState_Scripting.cpp registers
-- exactly four entity SETTERS -- distance culling radius, orphan mode, routing
-- bucket, and the ignore-request-control filter -- plus the lockdown modes.
-- Player peds are client-authoritative and the server cannot write one, so the
-- cheapest wire path is one empty event to one client.
--
-- AND WIDENING CULLING IS NOT THE FIX, which is worth stating because it is the
-- first idea everyone has. server/rescue.lua carries the long note: the
-- relevancy radius is 424m by default, an override makes an entity relevant to
-- EVERY client on the tick it is set, and rescue.lua takes that trade for one
-- ambulance for one ride and hands it straight back. Doing it for every downed
-- body would send the whole match to everybody for the whole match.

--- The floor between two nudges to the SAME body, ms.
---
--- THIRTY SPECTATORS ARRIVING AT ONCE MUST NOT BUY THIRTY TASKS, and the answer
--- is coalescing rather than dropping: one step corrects EVERY machine watching,
--- so thirty arrivals genuinely need one step between them. What they must not
--- do is queue thirty.
---
--- IT IS A RATE LIMITER AND NOT A CLOCK, and the distinction is the whole of
--- #164's argument. The 500ms beat that was removed fired for the WHOLE BLEED
--- whether or not anything had happened -- 80 to 240 per knock, every one of
--- them a chance for the network to sample the body mid-step. This fires only
--- when a clone was actually built, so a quiet body in an empty field costs
--- nothing at all, and a body in a firefight costs at most one per second.
local RESYNC_FLOOR_MS = 1000

--- How often the pending set is drained, ms.
---
--- NOT THE FLOOR, AND SHORTER THAN IT ON PURPOSE. This is the LATENCY a
--- newcomer pays before the correction leaves; the floor is what stops the
--- second one arriving too soon. A stale clone crawls at roughly 0.35 m/s
--- (`move_injured_ground` is a locomotion dictionary), so a quarter second of
--- waiting is under a tenth of a metre of error, against the ~0.5m the issue
--- asks for.
local RESYNC_DRAIN_MS = 250

--- Bodies that somebody has just cloned. src -> true.
local resyncPending = {}
--- When each body was last nudged. src -> ms.
local resyncSentAt = {}

--- For /brdbno. Every one of these is a number the owner can read against the
--- client's own `scope` line to say which half of the round trip is missing.
local resyncStats = { entered = 0, sent = 0, coalesced = 0, floored = 0 }
BR.Combat.resyncStats = resyncStats

AddEventHandler('playerEnteredScope', function(data)
    if type(data) ~= 'table' then return end
    -- STRINGS ON THE WIRE. fmt::sprintf("%d", ...) on both fields, so these
    -- arrive as "12" and a raw table lookup would find nothing.
    local owner = tonumber(data.player)
    if not owner then return end

    local entry = BR.Roster.get(owner)
    if not entry then return end
    -- ONLY A BODY. An alive player is being driven by their own machine every
    -- frame and their clone is built from a position that is at most one
    -- snapshot old; there is nothing stale to correct and no reason to spend a
    -- message on it. DBNO and OUT are the two states where the ped stops
    -- generating updates of its own.
    if entry.state ~= BR.PlayerState.DBNO
       and entry.state ~= BR.PlayerState.OUT then return end

    resyncStats.entered = resyncStats.entered + 1
    if resyncPending[owner] then
        resyncStats.coalesced = resyncStats.coalesced + 1
    end
    resyncPending[owner] = true
end)

BR.Sched.every(RESYNC_DRAIN_MS, 'combat.scoperesync', function()
    -- `next` rather than a length: this table is empty on almost every pass and
    -- the empty case must cost one comparison.
    if next(resyncPending) == nil then return end

    local now = GetGameTimer()
    for owner in pairs(resyncPending) do
        local entry = BR.Roster.get(owner)
        if not entry or (entry.state ~= BR.PlayerState.DBNO
                         and entry.state ~= BR.PlayerState.OUT) then
            -- Revived, disconnected, or swept home between the arm and the
            -- drain. The pending flag goes with them; so does the stamp, or a
            -- player knocked again inside the floor would have their FIRST
            -- nudge of the new knock swallowed by the last one of the old.
            resyncPending[owner] = nil
            resyncSentAt[owner]  = nil
        elseif now - (resyncSentAt[owner] or -RESYNC_FLOOR_MS) < RESYNC_FLOOR_MS then
            -- INSIDE THE FLOOR, SO IT STAYS PENDING rather than being dropped.
            -- A newcomer who cloned the body one frame AFTER the last step is
            -- exactly the case this issue is about, and dropping them here
            -- would reproduce it with extra steps.
            resyncStats.floored = resyncStats.floored + 1
        else
            resyncPending[owner] = nil
            resyncSentAt[owner]  = now
            resyncStats.sent     = resyncStats.sent + 1
            TriggerClientEvent(BR.Net.DBNO_RESYNC, owner)
        end
    end
end)

--- Tell a would-be reviver their hold is not happening.
---
--- A REFUSAL THAT SAYS NOTHING LOOKS EXACTLY LIKE A HOLD THAT IS WORKING, and
--- on this interaction that is not a nuance -- it is the entire failure mode.
--- br_ui/dui/prompt.html fills its ring from a ONE-SHOT CSS animation started by
--- a single "a hold began, it lasts N ms" message, so the ring closes on
--- schedule whether or not this file ever agreed to anything. Three of the
--- returns below used to be silent, which meant the player watched a full ring
--- and then watched nothing happen, with no evidence anywhere pointing at the
--- server (owner, playtest; and the same false signal cost four rounds on #129).
---
--- The reply is the same envelope stopRevive already sends, so the client needs
--- no new branch: a cancelled REVIVE_PROGRESS drops the hold and the next
--- setPrompt takes the ring back down. `reason` is for the log and for whatever
--- the interface decides to say later; nothing depends on its value today.
---
--- CHEAP BY CONSTRUCTION. The client asks at most four times a second per hold,
--- so a refusal costs the same traffic as the progress ticks an ACCEPTED hold
--- already generates -- and only while somebody is actually leaning on a key.
--- @param src integer
--- @param targetSrc integer
--- @param reason string
local function refuseRevive(src, targetSrc, reason)
    -- RECORDED ON THE TARGET, because that is the row /brdbno prints and the
    -- refusal is about this body. Kept as the LAST one plus a count: a refusal
    -- that happens once is a race and the same refusal a hundred times is the
    -- answer, and the pair fits on one line.
    local t = BR.Roster.get(targetSrc)
    if t then
        t.reviveRefuseWhy = reason
        t.reviveRefuseAt  = GetGameTimer()
        t.reviveRefuseBy  = src
        t.reviveRefusals  = (t.reviveRefusals or 0) + 1
    end
    TriggerClientEvent(BR.Net.REVIVE_PROGRESS, src,
        { pct = 0.0, target = targetSrc, cancelled = true, reason = reason })
end

RegisterNetEvent(BR.Net.REVIVE_START)
AddEventHandler(BR.Net.REVIVE_START, function(data)
    local src = source
    local targetSrc = math.tointeger(tonumber(data and data.target))
    -- The one refusal that stays silent, because there is nobody to answer
    -- about: without a target id there is no ring on the far side to take down.
    if not targetSrc then return end

    local reviver = BR.Roster.get(src)
    local target  = BR.Roster.get(targetSrc)
    local allowed, why = reviveAllowed(reviver, target)
    if not allowed then
        refuseRevive(src, targetSrc, why or 'notallowed')
        return
    end

    -- ALREADY OURS: this is the heartbeat, not a new hold. The client
    -- re-asserts every 250ms and the clock below is what expires a revive
    -- whose holder went quiet, so this path must NOT restart the progress.
    if target.reviverSrc == src then
        target.reviveBeat = GetGameTimer()
        return
    end

    -- FIRST HAND ON WINS. Two mates holding the same body is not twice as fast
    -- and it must not restart the clock for whoever pressed second.
    if target.reviverSrc then
        refuseRevive(src, targetSrc,
            ('taken: %d already has this body'):format(target.reviverSrc))
        return
    end

    target.reviverSrc = src
    target.reviveFrom = GetGameTimer()
    target.reviveBeat = target.reviveFrom
    -- THE PAUSE STARTS HERE, NOT ON THE FIRST TICK. stepDowned advances the
    -- deadline by `now - reviveTickAt`, and with nothing stamped that first
    -- pass measured zero -- so the quarter second between the hold registering
    -- and the scheduler's next look ran off the clock every single time. It is
    -- a fifth of a knock over a full 2.8s hold, and it is free to close.
    target.reviveTickAt = target.reviveFrom
    BR.Combat.pushDbno(targetSrc)
end)

RegisterNetEvent(BR.Net.REVIVE_STOP)
AddEventHandler(BR.Net.REVIVE_STOP, function()
    local src = source
    BR.Roster.each(
        function(e) return e.reviverSrc == src end,
        function(tsrc, entry) stopRevive(tsrc, entry, 'released') end)
end)

--- Forget a player's DBNO bookkeeping. Called on disconnect and at match
--- teardown: server ids are recycled, and inheriting somebody else's knock
--- count would hand the next holder of that slot a 15-second first bleed.
--- @param src integer
function BR.Combat.forget(src)
    local entry = BR.Roster.get(src)
    if entry then
        entry.dbnoUntil, entry.dbnoCount = nil, nil
        entry.downedBy, entry.reviverSrc, entry.reviveFrom = nil, nil, nil
        entry.reviveBeat, entry.reviveTickAt = nil, nil
        -- ...AND THE DIAGNOSTIC RECORD WITH THEM. /brdbno prints these as ages,
        -- and an age is a lie if the row belongs to somebody else: server ids
        -- are recycled within the minute, which is the whole reason this
        -- function exists.
        entry.reviveRefuseWhy, entry.reviveRefuseAt = nil, nil
        entry.reviveRefuseBy, entry.reviveRefusals  = nil, nil
        entry.reviveStopWhy, entry.reviveStopAt     = nil, nil
        entry.reviveStops, entry.reviveLastPct      = nil, nil
    end
    -- ...and anything they were in the middle of picking up.
    BR.Roster.each(
        function(e) return e.reviverSrc == src end,
        function(tsrc, e) stopRevive(tsrc, e, 'gone') end)
end

--- Client-reported death. A hint, not an instruction.
RegisterNetEvent(BR.Net.PLAYER_DIED)
AddEventHandler(BR.Net.PLAYER_DIED, function(data)
    local src = source
    local entry = BR.Roster.get(src)
    if not entry then return end

    if not canDie(entry) then
        -- Not necessarily malicious: a report can arrive just after the server
        -- already eliminated them from its own health check.
        if BR.Server.devMode then
            print(('[br_core] ignored death report from %d in state %s')
                :format(src, entry.state))
        end
        return
    end

    -- ...AND A DOWNED PLAYER IS NOT FINISHED BY THEIR OWN CLIENT EITHER
    -- (owner, 2026-08-17: "I tried triggering DBNO by falling from a height but
    -- it went straight to dead").
    --
    -- THE ASYMMETRY THIS CLOSES. There are exactly two doors from "this ped
    -- reads dead" to defeat(), and defeat() on a DBNO entry can only ever
    -- eliminate -- canBeDowned requires ALIVE, so the knock branch is
    -- unreachable and the fall-through is the whole of it. ef501ef locked one
    -- door (the server's own sampler, in combat.deathcheck below) and left this
    -- one standing open, which is why the same symptom came back the moment
    -- client/dbno.lua's timing changed underneath it.
    --
    -- The reason given there applies here word for word: for everybody else the
    -- ped is the evidence, and for a downed player it is evidence of nothing.
    -- Their health IS the bleed clock, their ped is invincible by design
    -- (client/natives.lua), and the engine still kills it down the paths we
    -- never took over -- a fall, a fire, drowning, a car. A fall is the ordinary
    -- case: the report BELOW is the one that produced the knock in the first
    -- place, and the engine then finishes the same death a beat later. The
    -- client is not lying and is not duplicating; gamerules.death re-arms the
    -- instant the ped stops reading dead, which is exactly what being
    -- resurrected onto the downed floor does to it.
    --
    -- Nothing is lost by declining. The bleed clock owns this ending and still
    -- delivers it, at dbnoBleedBase and faster under fire, and a downed player
    -- can still be finished with a gun through BR.Combat.bleed. What goes is
    -- only the ability to end yourself twice over one fall.
    if entry.state == BR.PlayerState.DBNO then
        if BR.Server.devMode then
            print(('[br_core] ignored death report from %d: already down, the '
                   .. 'bleed clock owns that ending'):format(src))
        end
        return
    end

    -- A recent storm tick outranks whatever the engine blames: the finishing
    -- blow of a storm death often reads as generic damage.
    local cause = describeCause(data and data.cause)
    if entry.lastStormAt and (GetGameTimer() - entry.lastStormAt) < 3000 then
        cause = 'storm'
    end

    -- Resolved BEFORE the roadkill cause is read, because resolving is what
    -- writes `lastRoadkillAt` on the death this handler is processing.
    local killer = killerOf(src, entry)

    -- ...AND A ROADKILL THE SERVER ITSELF ATTRIBUTED OUTRANKS THE HASH THE
    -- CLIENT SENT, in the direction that matters. `describeCause` already turns
    -- WEAPON_RUN_OVER_BY_CAR into 'roadkill', so an honest client usually says it
    -- first -- but the cause on the wire is the victim's own machine talking, and
    -- the one thing a victim can do with it is deny their killer the right label.
    -- Below the storm, which is documented as outranking everything.
    if cause ~= 'storm' and BR.Vehicles and BR.Vehicles.roadkillRecent
       and BR.Vehicles.roadkillRecent(entry) then
        cause = 'roadkill'
    end

    BR.Combat.defeat(src, cause, killer)
end)

--- Independent confirmation from server-side health.
---
--- This is the half a cheating client cannot avoid. It requires OneSync, which
--- is also what makes position sampling work -- if the roster shows no peds,
--- this silently does nothing and the boot warning explains why.
BR.Sched.every(1000, 'combat.deathcheck', function()
    -- BUS counts as live: early droppers are on the ground and mortal while
    -- stragglers are still flying, and a death in that window must be
    -- observed like any other. PLAYING-only meant a landed player could not
    -- be server-confirmed dead until the LAST player was down. Checked per
    -- player against THEIR match's state -- matches advance independently.
    BR.Roster.each(function(e)
        if not canDie(e) then return false end

        -- A DOWNED PLAYER IS NEVER FINISHED BY THIS CHECK, AND THAT IS THE
        -- WHOLE POINT OF THE STATE (#115 sibling, owner 2026-08-16).
        --
        -- For everybody else the ped IS the evidence -- it is the half a
        -- cheating client cannot avoid. For a downed player it is not evidence
        -- of anything: the bleed clock is their health (see the DBNO section
        -- above), their ped is invincible by design (client/natives.lua), and a
        -- ped reading dead here means only that the ENGINE killed it down a path
        -- we never took over -- a fall, a fire, drowning, a car -- a beat before
        -- the knock landed. Reading that corpse turned every fall in a squad
        -- match into an instant elimination one second after the squad panel
        -- said DOWN, with the body still lying there and no revive prompt for
        -- anyone (owner, 2026-08-16).
        --
        -- Nothing is lost by declining: defeat() on a DBNO entry can only ever
        -- eliminate anyway -- canBeDowned requires ALIVE -- so this branch was
        -- never deciding "down or out", it was racing the bleed clock that
        -- already owns the answer and already terminates, at dbnoBleedBase and
        -- faster under fire.
        if e.state == BR.PlayerState.DBNO then return false end

        local m = e.matchId and BR.Server.matches[e.matchId]
        return m ~= nil and (m.state == BR.MatchState.PLAYING
                          or m.state == BR.MatchState.BUS)
    end, function(src, entry)
        if not entry.ped or entry.ped == 0 then return end

        -- engineHp is sampled by roster.positions alongside coordinates.
        if entry.engineHp and BR.IsDeadHp(entry.engineHp) then
            -- A death within moments of a storm tick is a storm death: the
            -- kill feed should say so rather than the generic fallback.
            local cause = 'server-observed'
            if entry.lastStormAt
               and (GetGameTimer() - entry.lastStormAt) < 3000 then
                cause = 'storm'
            end
            print(('[br_core] server observed %s (%d) dead (hp %d) -- eliminating')
                :format(entry.name, src, entry.engineHp))
            -- Attributed the same way as a client-reported death: the server's
            -- own record of who has been shooting them. A player who bleeds
            -- out from a rifle wound still credits the rifle.
            local killer = killerOf(src, entry)
            -- ...AND THIS PATH IS THE ONE THAT NEEDS THE ROADKILL LABEL MOST.
            -- It is reached when the client said nothing at all, so there is no
            -- cause hash to translate and 'server-observed' is a statement about
            -- how we found out rather than about what happened.
            if cause ~= 'storm' and BR.Vehicles and BR.Vehicles.roadkillRecent
               and BR.Vehicles.roadkillRecent(entry) then
                cause = 'roadkill'
            end
            BR.Combat.defeat(src, cause, killer)
        end
    end)
end)

RegisterCommand('brkill', function(_, args)
    local src = tonumber(args[1])
    if not src then
        print('  usage: brkill <serverId>   -- eliminate a player, for testing')
        return
    end
    if not BR.Roster.get(src) then
        print(('  no such player: %d'):format(src))
        return
    end
    BR.Combat.eliminate(src, 'admin', tonumber(args[2]))
end, true)

--- Knock a player down without shooting them.
---
--- `brdown <id>` refuses when the rules say it should -- no standing squadmate
--- in a squad, no CPR kit in a solo, already down -- and SAYS WHICH, because
--- "nothing happened" is indistinguishable from a bug and this is the command
--- that will be used to decide whether DBNO is working at all.
RegisterCommand('brdown', function(_, args)
    local src = tonumber(args[1])
    if not src then
        print('  usage: brdown <serverId> [killerId]   -- knock a player down')
        return
    end

    local entry = BR.Roster.get(src)
    if not entry then
        print(('  no such player: %d'):format(src))
        return
    end
    if entry.state == BR.PlayerState.DBNO then
        print(('  %s (%d) is already down'):format(entry.name, src))
        return
    end
    if not BR.Combat.canBeDowned(entry) then
        local m = entry.matchId and BR.Server.matches[entry.matchId]
        print(('  %s (%d) cannot be downed: state %s, mode %s, standing mate %s')
            :format(entry.name, src, entry.state,
                    m and m.mode or 'no match',
                    tostring(entry.squadId ~= nil)))
        print('  (squads only, and only while a squadmate is still standing)')
        return
    end

    BR.Combat.knock(src, tonumber(args[2]))
end, true)

--- Finish a revive on a downed player instantly, from nobody in particular.
RegisterCommand('brrevive', function(_, args)
    local src = tonumber(args[1])
    local entry = src and BR.Roster.get(src)
    if not entry then
        print('  usage: brrevive <serverId>   -- pick a downed player back up')
        return
    end
    if entry.state ~= BR.PlayerState.DBNO then
        print(('  %s (%d) is not down (state %s)'):format(entry.name, src, entry.state))
        return
    end

    BR.Combat.revive(src, tonumber(args[2]))
end, true)

--- Shoot a downed player without a second squad to shoot them with.
---
--- THIS EXISTS BECAUSE THE TEST WAS IMPOSSIBLE. Damage-to-seconds needs an
--- ENEMY hitting a downed player: friendly fire is refused by design, and a
--- two-squad match needs more clients than a two-machine playtest has (owner,
--- 2026-08-09). Rather than leave the headline mechanic of this milestone
--- unmeasurable until there are six people in a room, the damage can be
--- injected here -- through BR.Combat.bleed, the same function a real bullet
--- reaches, so what is measured is the real path and not a rehearsal of it.
---
---   brbleed <id> [damage] [byId]
RegisterCommand('brbleed', function(_, args)
    local src = tonumber(args[1])
    local entry = src and BR.Roster.get(src)
    if not entry then
        print('  usage: brbleed <serverId> [damage=30] [byId]')
        print('  takes damage off a downed player\'s clock, as an enemy shot would')
        return
    end
    if entry.state ~= BR.PlayerState.DBNO then
        print(('  %s (%d) is not down (state %s)'):format(entry.name, src, entry.state))
        return
    end

    local amount = tonumber(args[2]) or 30.0
    local before = entry.dbnoUntil or 0
    BR.Combat.bleed(src, amount, tonumber(args[3]), nil)

    print(('[br_core] %s (%d): %.0f damage -> %.1fs off the clock (%.1fs left)')
        :format(entry.name, src, amount, (before - (entry.dbnoUntil or 0)) / 1000.0,
                ((entry.dbnoUntil or GetGameTimer()) - GetGameTimer()) / 1000.0))
end, true)

--- Hurt a REVIVER, so the cancel-on-damage rule can be tested at all.
---
--- Same problem as brbleed and the same answer: the rule reads lastHitAt, so
--- this writes lastHitAt. It applies no actual damage -- the point is the
--- interruption, and a command that also killed the reviver would be testing
--- two things at once.
---
---   brhurt <id>
RegisterCommand('brhurt', function(_, args)
    local src = tonumber(args[1])
    local entry = src and BR.Roster.get(src)
    if not entry then
        print('  usage: brhurt <serverId>')
        print('  marks a player as just-hit, which is what cancels a revive')
        return
    end
    entry.lastHitAt = GetGameTimer()
    print(('[br_core] %s (%d) marked as hit just now'):format(entry.name, src))
end, true)

--- Every downed player: how long they have, who put them there, who is on them.
RegisterCommand('brdbno', function()
    local now = GetGameTimer()
    local n = 0

    --- "12.3s ago", or "never".
    local function since(t)
        if not t or t == 0 then return 'never' end
        return ('%.1fs ago'):format((now - t) / 1000.0)
    end

    print('=== downed ===')
    BR.Roster.each(
        function(e) return e.state == BR.PlayerState.DBNO end,
        function(src, e)
            n = n + 1
            local r = e.reviverSrc and BR.Roster.get(e.reviverSrc) or nil
            print(('  %-4d %-18s match %-3s knock #%d  %.1fs left  by %s  reviver %s %s')
                :format(src, e.name, tostring(e.matchId), e.dbnoCount or 0,
                        ((e.dbnoUntil or now) - now) / 1000.0,
                        tostring(e.downedBy), r and r.name or '-',
                        e.reviveFrom and ('%.0f%%'):format(
                            BR.Clamp((now - e.reviveFrom)
                                     / ((M.dbnoReviveTime or 8.0) * 1000.0),
                                     0.0, 1.0) * 100.0) or ''))

            -- WHAT THIS SERVER LAST TOLD SOMEBODY WHO TRIED (#163).
            --
            -- The client's own /brdbno can say "the server refused"; only this
            -- side knows WHICH refusal and with what numbers behind it. The
            -- pair is the whole instrument: a filled ring plus these two lines
            -- is an answerable report, and a filled ring on its own is not.
            print(('       refused  : %s x%d, last %s (asked by %s)')
                :format(tostring(e.reviveRefuseWhy or '-'),
                        e.reviveRefusals or 0, since(e.reviveRefuseAt),
                        tostring(e.reviveRefuseBy)))
            print(('       stopped  : %s x%d, last %s at %.0f%%')
                :format(tostring(e.reviveStopWhy or '-'), e.reviveStops or 0,
                        since(e.reviveStopAt), e.reviveLastPct or 0.0))
            print(('       position : self %s   reviver %s')
                :format(e.pos and 'sampled' or 'NEVER SAMPLED -- no OneSync?',
                        r and (r.pos and 'sampled'
                                     or 'NEVER SAMPLED -- no OneSync?') or '-'))
            -- #246. READ THIS AGAINST THE CLIENT'S OWN `scope` LINE, which is
            -- the other end of the same round trip: a body with nudges sent
            -- here and none received there is a client that is not listening,
            -- and one with `pending` stuck true is a floor that never clears.
            print(('       scope    : last nudge %s, %s')
                :format(since(resyncSentAt[src]),
                        resyncPending[src] and 'ONE PENDING'
                                           or 'nothing waiting'))
        end)
    if n == 0 then print('  nobody is down') end

    -- ...AND THE TOTALS, WHICH COVER THE CORPSES TOO. The per-body lines above
    -- are DBNO only; an OUT player is armed by exactly the same event and has
    -- no row of its own to print, so `entered` is the only place a dead body
    -- being streamed in shows up at all.
    --
    -- `entered` AT ZERO IS THE ONE READING THAT MEANS SOMETHING ON ITS OWN: it
    -- is what a box running onesync LEGACY looks like. playerEnteredScope is
    -- fired inside ServerGameState's `IsBigMode()` guard, so on legacy this
    -- number never leaves 0 however many people walk over a body, and the whole
    -- of #246 is inert.
    print(('  scope      : %d entries on a body, %d nudges sent, %d coalesced, '
           .. '%d held by the %dms floor')
        :format(resyncStats.entered, resyncStats.sent,
                resyncStats.coalesced, resyncStats.floored, RESYNC_FLOOR_MS))
    if resyncStats.entered == 0 then
        print('               entered 0 -- either nobody has walked up to a body '
              .. 'yet, or this box is on onesync LEGACY, where the event does '
              .. 'not exist')
    end
    print(('  bleed %ds/%d/%ds, %.2fs per damage point, revive %.1fs within %.1fm')
        :format(M.dbnoBleedBase, M.dbnoBleedStep, M.dbnoBleedMin,
                M.dbnoBleedPerDamage, M.dbnoReviveTime, M.dbnoReviveDist))
end, true)
