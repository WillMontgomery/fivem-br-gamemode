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

--- Has this player's match not actually started yet? (#144)
---
--- WARMUP and BUS only. WAITING has no players in it, and by ENDED or CLEANUP
--- the results are published or about to be -- holding a death open there would
--- be holding it open past the moment it is written down.
---
--- The window is real and it is not small: a player becomes ALIVE the instant
--- they LAND (DROP_LANDED), while the match stays in BUS until the LAST player
--- is down, which server/match.lua extends in ten-second steps for anyone still
--- under canopy. So the first person to touch the ground is mortal, on foot, in
--- a POI, for as long as the slowest glider takes -- "what may be a minute or
--- more", in the issue's words. They are also the only players who can die here:
--- WARMUP, BUS, FREEFALL and GLIDE are all invincible client-side
--- (client/natives.lua), which is why this is the landed-early case and not a
--- theoretical one.
--- @param m table|nil
--- @return boolean
local function beforeTheMatch(m)
    if not m then return false end
    return m.state == BR.MatchState.WARMUP
        or m.state == BR.MatchState.BUS
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
    BR.Roster.setState(src, BR.PlayerState.DEAD)

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

    BR.Roster.update(src, { hp = 100.0, armour = 0.0 })
    BR.Roster.setState(src, BR.PlayerState.ALIVE)
    TriggerClientEvent(BR.Net.HEALTH_SYNC, src, { hp = 100, armour = 0 })

    BR.Server.notifyClear(src, 'revive.pending')
    BR.Server.notify(src, 'The match has started. You are back in.',
        'success', { ms = 5000 })

    print(('[br_core] revived %s (%d) -- died before the match started')
        :format(entry.name, src))
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
    if cause ~= 'left' and beforeTheMatch(m) then
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

    BR.Roster.setState(src, BR.PlayerState.DEAD)
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
    end

    local killer = killerSrc and BR.Roster.get(killerSrc)
    if killer and killerSrc ~= src then
        killer.kills = (killer.kills or 0) + 1
        BR.Broadcast.delta({ op = 'update', src = killerSrc, e = { kills = killer.kills } })
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

    -- SQUADS ONLY, AND THE GATE IS THE MODE'S OWN FLAG (owner, 2026-08-09).
    --
    -- Solo has nobody who could revive you, so a knock today would only be a
    -- slower death and a worse one. Solo DBNO is wanted LATER and is
    -- deliberately not this milestone: it only becomes a real state once there
    -- is something that can pick a lone player up, and that is M8d's hearse
    -- rescue. When it arrives the switch here is `BR.Mode.SOLO.dbno = true`
    -- plus a second answer to the question below -- which is why the two
    -- conditions are separate rather than one "is this a squad match".
    if not BR.ResolveMode(m.mode).dbno then return false end

    return hasStandingMate(entry)
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
    -- assistWindowMs (10s) and a bleed runs 15-45s, so a player who is knocked
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

    BR.Combat.pushDbno(src)

    -- THE SQUAD IS TOLD IN WORDS, not only in pixels. The panel stripe and the
    -- [DOWN] gamer tag both already say this, and both require the mate to be
    -- looking at the right thing -- which in a firefight is exactly what they
    -- are not doing.
    if entry.squadId then
        BR.Roster.each(
            function(e) return e.squadId == entry.squadId and e.src ~= src end,
            function(mate)
                BR.Server.notify(mate, ('%s is down.'):format(entry.name),
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

    if e.dbnoUntil <= now then
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
--- @param reviver table|nil
--- @param target table|nil
--- @return boolean
local function reviveAllowed(reviver, target)
    if not reviver or not target then return false end
    if reviver.state ~= BR.PlayerState.ALIVE then return false end
    if target.state ~= BR.PlayerState.DBNO then return false end
    if not reviver.matchId or reviver.matchId ~= target.matchId then return false end
    if not reviver.squadId or reviver.squadId ~= target.squadId then return false end

    -- MEASURED FROM THE SERVER'S OWN POSITION SAMPLES, never from anything a
    -- client said -- the rule the loot claim already follows, with the same
    -- slack for the same 250ms sampling skew.
    local a, b = reviver.pos, target.pos
    if not a or not b then return false end

    local reach = (M.dbnoReviveDist or 1.5) + (M.dbnoReviveSlack or 1.0)
    return BR.Dist3(a.x, a.y, a.z, b.x, b.y, b.z) <= reach
end

--- Stop whatever revive is running on this player. Harmless if none is.
--- @param src integer
--- @param entry table
--- @param reason string|nil
local function stopRevive(src, entry, reason)
    local reviverSrc = entry.reviverSrc
    if not reviverSrc then return end

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
--- @param src integer
--- @param reviverSrc integer|nil  credited with the revive; nil for an admin
function BR.Combat.revive(src, reviverSrc)
    local entry = BR.Roster.get(src)
    if not entry or entry.state ~= BR.PlayerState.DBNO then return end

    reviverSrc = reviverSrc or entry.reviverSrc
    local reviver = reviverSrc and BR.Roster.get(reviverSrc) or nil

    entry.reviverSrc, entry.reviveFrom = nil, nil
    entry.reviveBeat, entry.reviveTickAt = nil, nil
    -- The knock is UNDONE, not merely paused: whoever put them down no longer
    -- owns a finish that is not going to happen.
    entry.dbnoUntil, entry.downedBy = nil, nil

    BR.Roster.update(src, { hp = (M.dbnoReviveHp or 30) + 0.0, armour = 0.0 })
    BR.Roster.setState(src, BR.PlayerState.ALIVE)

    if reviver then
        reviver.revives = (reviver.revives or 0) + 1
    end

    -- The server cannot write a ped, so it says what the number IS and the
    -- client applies it -- the same contract the storm and the validated shot
    -- already use, in absolute form rather than as a delta.
    TriggerClientEvent(BR.Net.HEALTH_SYNC, src,
        { hp = M.dbnoReviveHp or 30, armour = 0 })
    BR.Combat.pushDbno(src)

    if reviverSrc then
        TriggerClientEvent(BR.Net.REVIVE_PROGRESS, reviverSrc,
            { pct = 100.0, target = src, done = true })
        BR.Server.notify(reviverSrc, ('You picked %s up.'):format(entry.name),
            'success', { ms = 4000 })
    end
    BR.Server.notify(src,
        reviver and ('%s picked you up.'):format(reviver.name)
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

        if not reviveAllowed(reviver, entry) then
            stopRevive(src, entry, 'interrupted')

        elseif now - (entry.reviveBeat or 0) > (M.dbnoReviveBeatMs or 750) then
            -- THE HOLDER WENT QUIET. A revive is only alive while the client
            -- keeps saying so; a lost REVIVE_STOP used to hand out a completed
            -- eight-second hold for a tap (owner, in game). Requiring evidence
            -- rather than trusting one message makes the failure cost a
            -- fraction of a second instead of the whole interaction.
            stopRevive(src, entry, 'released')

        elseif math.max(reviver.lastHitAt or 0, reviver.lastStormAt or 0)
               > (entry.reviveFrom or 0) then
            -- CANCELLED BY THE REVIVER'S DAMAGE, not the downed player's.
            -- Picking somebody up is the thing you cannot do while being shot,
            -- which is the entire reason it takes eight seconds in the open.
            stopRevive(src, entry, 'hurt')

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

            local payload = { pct = pct * 100.0, target = src,
                              reviverName = reviver.name }
            TriggerClientEvent(BR.Net.REVIVE_PROGRESS, reviverSrc, payload)
            TriggerClientEvent(BR.Net.REVIVE_PROGRESS, src, payload)
        end
    else
        entry.reviveTickAt = nil
    end

    if now >= (entry.dbnoUntil or 0) then
        BR.Combat.eliminate(src, 'bledout', entry.downedBy)
    end
end

BR.Sched.every(250, 'combat.dbno', function()
    local now = GetGameTimer()
    BR.Roster.each(
        function(e) return e.state == BR.PlayerState.DBNO end,
        function(src, entry) stepDowned(src, entry, now) end)
end)

RegisterNetEvent(BR.Net.REVIVE_START)
AddEventHandler(BR.Net.REVIVE_START, function(data)
    local src = source
    local targetSrc = math.tointeger(tonumber(data and data.target))
    if not targetSrc then return end

    local reviver = BR.Roster.get(src)
    local target  = BR.Roster.get(targetSrc)
    if not reviveAllowed(reviver, target) then return end

    -- ALREADY OURS: this is the heartbeat, not a new hold. The client
    -- re-asserts every 250ms and the clock below is what expires a revive
    -- whose holder went quiet, so this path must NOT restart the progress.
    if target.reviverSrc == src then
        target.reviveBeat = GetGameTimer()
        return
    end

    -- FIRST HAND ON WINS. Two mates holding the same body is not twice as fast
    -- and it must not restart the clock for whoever pressed second.
    if target.reviverSrc then return end

    target.reviverSrc = src
    target.reviveFrom = GetGameTimer()
    target.reviveBeat = target.reviveFrom
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

    -- A recent storm tick outranks whatever the engine blames: the finishing
    -- blow of a storm death often reads as generic damage.
    local cause = describeCause(data and data.cause)
    if entry.lastStormAt and (GetGameTimer() - entry.lastStormAt) < 3000 then
        cause = 'storm'
    end

    BR.Combat.defeat(src, cause, BR.Combat.attributedKiller(entry))
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
            BR.Combat.defeat(src, cause, BR.Combat.attributedKiller(entry))
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
--- `brdown <id>` refuses when the rules say it should -- solo, no standing
--- squadmate, already down -- and SAYS WHICH, because "nothing happened" is
--- indistinguishable from a bug and this is the command that will be used to
--- decide whether DBNO is working at all.
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
        end)
    if n == 0 then print('  nobody is down') end
    print(('  bleed %ds/%d/%ds, %.2fs per damage point, revive %.1fs within %.1fm')
        :format(M.dbnoBleedBase, M.dbnoBleedStep, M.dbnoBleedMin,
                M.dbnoBleedPerDamage, M.dbnoReviveTime, M.dbnoReviveDist))
end, true)
