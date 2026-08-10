-- The match state machine -- PER INSTANCE.
--
--   (queue clears the gate) ──► WARMUP ──(timer)──► BUS ──(route done)──► PLAYING
--                                                                            │
--                    (destroyed) ◄──(timer)── CLEANUP ◄──(timer)── ENDED ◄───┘
--
-- PARALLEL MATCHES (user call, 2026-08-04). There is no global "the match":
-- BR.Server.matches holds any number of concurrent instances, each with its
-- own routing bucket, storm, bus route and win condition. WAITING is not an
-- instance state -- it is what a lobby player sees when they belong to no
-- match. The lifecycle:
--
--   * While an instance is in OPEN WARMUP (not full), ready-ups late-join it
--     directly -- the queue stays empty, so no second match can form. This
--     IS the formation gate the user specified: a new match starts with the
--     first players who ready up after every existing match is BUS-or-later
--     (or a full warmup).
--   * Once the queue clears the start conditions, BR.Match.create() mints an
--     instance straight into WARMUP. Its players enter its own routing
--     bucket right there -- the warmup pad is already the match's private
--     world, which is what makes the instance handoff seamless: there is no
--     later mid-flight bucket hop to hide.
--   * ENDED sweeps its players home to the lobby (they keep matchId --
--     and with it the match's event traffic -- through the summary);
--     CLEANUP wipes per-player match state; then the instance is destroyed.
--
-- One authority, one AUDIENCE-SCOPED broadcast per transition. Clients never
-- infer the state -- they are told, and only ever about their own match.

BR = BR or {}
BR.Match = {}

local M = BR.Config.Match

--- Seconds each state lasts. nil means "until something else ends it" --
--- BUS until the route ends, PLAYING until one team is left.
local DURATION = {
    [BR.MatchState.WARMUP]  = M.warmupSeconds,
    [BR.MatchState.BUS]     = nil,   -- set from the bus route
    [BR.MatchState.PLAYING] = nil,
    [BR.MatchState.ENDED]   = M.endedSeconds,
    [BR.MatchState.CLEANUP] = M.cleanupSeconds,
}

--- Mint a new match instance and start its warmup.
---
--- The participants are ATTACHED FIRST, then flipped to WARMUP: the state
--- change is what applies the routing bucket, and the bucket needs the
--- matchId to already be there.
---
--- @param mode string
--- @param participants integer[]
--- @return table the instance
function BR.Match.create(mode, participants)
    BR.Server.matchId = BR.Server.matchId + 1
    local m = {
        id        = BR.Server.matchId,
        bucket    = M.matchBucketBase + BR.Server.matchId,
        state     = BR.MatchState.WAITING,   -- transition() below moves it out
        mode      = mode or BR.Mode.SOLO.key,
        endsAt    = 0,
        shortened = false,
    }
    BR.Server.matches[m.id] = m

    for _, src in ipairs(participants or {}) do
        if BR.Roster.get(src) then
            BR.Roster.setMatch(src, m.id)
        end
    end

    print(('[br_core] match %d formed -- %s, %d player(s), bucket %d')
        :format(m.id, m.mode, #(participants or {}), m.bucket))

    BR.Match.transition(m, BR.MatchState.WARMUP)
    return m
end

--- Tear an instance down completely. The only way a match leaves the
--- registry. Any player still attached (a crash mid-teardown, a straggler)
--- is swept home first.
--- @param m table
function BR.Match.destroy(m)
    BR.Roster.each(
        function(e) return e.matchId == m.id end,
        function(src, e)
            if e.state ~= BR.PlayerState.LOBBY
               and e.state ~= BR.PlayerState.LEFT then
                BR.Roster.setState(src, BR.PlayerState.LOBBY)
            end
            BR.Roster.setMatch(src, nil)
            -- The SQUAD channel spent the whole match showing the in-match
            -- squad; back in the lobby it must show the PARTY again (which
            -- deliberately survives matches). A client whose party display
            -- went stale here filtered its owner out of every invite list
            -- with nothing on screen explaining why (live report,
            -- 2026-08-04: "can't see each other in the menu" until a solo
            -- queue dissolved the party).
            -- AND ANY INVITE THEY SENT DIES WITH THE MATCH (owner's call,
            -- 2026-08-09). An invite raised mid-match is answered from the
            -- pause menu, and the moment the match ends both players are
            -- somewhere else with a lobby in front of them -- a card still
            -- offering to join a party from two screens ago is answering a
            -- question nobody is still asking. The TTL sweep would get there
            -- eventually; the match ending is the honest moment.
            BR.Party.withdrawInvitesFrom(src, 'the match ended')
            BR.Party.resync(src)
        end)
    BR.Server.matches[m.id] = nil
    print(('[br_core] match %d destroyed'):format(m.id))

    -- Re-seed everyone (the old CLEANUP->WAITING snapshot, kept): the
    -- destroyed match's players just changed view, and any client that
    -- missed a delta converges here rather than at its next digest.
    BR.Broadcast.snapshot()
end

--- Move an instance to a new state.
---
--- The only way a match state ever changes. Everything else calls this, so
--- there is one place to log from and one place that broadcasts -- to the
--- match's audience, never to the world.
---
--- @param m table
--- @param state string
--- @param durationSec number|nil  overrides the table above
function BR.Match.transition(m, state, durationSec)
    local from = m.state
    if from == state then return end

    local secs = durationSec or DURATION[state]
    m.state  = state
    m.endsAt = secs and (GetGameTimer() + secs * 1000) or 0
    m.shortened = false

    print(('[br_core] match %d: %s -> %s%s'):format(
        m.id, from, state, secs and (' (%ds)'):format(secs) or ''))

    -- Broadcast BEFORE onEnter -- the ordering is a CONTRACT. At ENDED the
    -- client must hear the match ended BEFORE the roster sweep flips its
    -- own state to LOBBY: processing the flip first reads as a voluntary
    -- leave (roundParticipant drops) and the verdict screen never shows --
    -- the "died and went straight to the lobby card" regression
    -- (2026-08-04, caused by briefly reversing this order). BUS is the one
    -- exception: the flight computes the real endsAt inside onEnter, so
    -- onEnter(BUS) sends the single 'bus' event itself -- broadcasting
    -- here too was the doubled "state bus" client log.
    if state ~= BR.MatchState.BUS then
        BR.Broadcast.state(m, state, m.endsAt, { from = from })
    end
    BR.Match.onEnter(m, state, from)
end

--- Side effects of entering a state. Kept separate from transition() so the
--- transition itself stays trivially readable.
--- @param m table
--- @param state string
--- @param from string
function BR.Match.onEnter(m, state, from)
    if state == BR.MatchState.WARMUP then
        -- Membership was attached by create() (or brforce's fallback); only
        -- the members enter warmup. The queue gated the start; it also
        -- defined who is in -- never the whole roster, which would conscript
        -- players who did not ready up.
        BR.Roster.each(
            function(e) return e.matchId == m.id end,
            function(src) BR.Roster.setState(src, BR.PlayerState.WARMUP) end)

        -- Squads are formed once, here, from the parties that exist at the
        -- moment the match starts. Forming them earlier would go stale as
        -- people join and leave parties in the lobby.
        BR.Party.formSquads(m)

        -- ...and squads are what voice channels are cut from, so the push
        -- happens IMMEDIATELY after rather than waiting for the 1Hz sweep.
        -- A second in the wrong room at the start of warmup is a second of
        -- somebody's plan going to the wrong people.
        if BR.Voice then BR.Voice.pushMatch(m) end

        -- The flight is drawn NOW, not at departure: warmup is when players
        -- study the route on the map and pick their drop.
        BR.Bus.plan(m)

        -- The world is stocked NOW too, for the same reason in reverse:
        -- players land during BUS, not at PLAYING, so loot generated at the
        -- state flip would appear under the feet of whoever got down first.
        BR.Loot.begin(m)

    elseif state == BR.MatchState.BUS then
        m.descent = nil     -- fresh per flight: the descent-grace bookkeeping
        m.landCheck = nil   -- and the stuck-lander bookkeeping runs here too
        -- One "waiting on the others" notice per player per flight.
        BR.Roster.each(
            function(e) return e.matchId == m.id end,
            function(_, e) e.landNotice = nil end)

        -- The flight decides how long BUS lasts, so the deadline is set HERE
        -- -- transition() broadcasts it right after onEnter returns, as the
        -- one and only 'bus' state event. The geometry was planned at
        -- WARMUP; departure only stamps the clock onto it. `brforce bus`
        -- from nothing skips warmup, so plan on demand if nothing is drawn.
        if not BR.Bus.active(m) then BR.Bus.plan(m) end
        local dur = BR.Bus.depart(m)
        m.endsAt = GetGameTimer() + math.floor(dur * 1000)
        -- The single 'bus' state event, with the flight's real deadline --
        -- see the ordering note in transition(), which skips its own
        -- broadcast for BUS.
        BR.Broadcast.state(m, state, m.endsAt, { from = from, reason = 'busRoute' })

        BR.Roster.each(
            function(e) return e.matchId == m.id
                and e.state == BR.PlayerState.WARMUP end,
            function(src) BR.Roster.setState(src, BR.PlayerState.BUS) end)

        -- THE PAD'S LOOT DOES NOT FLY. Everything found during warmup is
        -- wiped at wheels-up: the island exists to be practised on, and
        -- arriving early must not be a head start over a late joiner who
        -- boards with nothing (user call, 2026-08-05 -- Fortnite's pre-game
        -- island rule).
        BR.Inv.clearFor(m)

        -- The starting team count is taken HERE, before anyone can possibly
        -- be dead (warmup is invincible; the doors are still shut). Counting
        -- it at PLAYING was the bug where a player who died during the bus
        -- ride made a two-player match register as "started with one squad"
        -- -- engaging the dev-mode never-auto-end hold and hanging the match.
        m.startSquads = BR.Server.squadsAlive(m)

    elseif state == BR.MatchState.PLAYING then
        -- Anyone somehow still aboard goes out the door first -- brforce can
        -- reach PLAYING mid-flight, and a player left in the BUS state would
        -- be invisible and frozen with the match running around them.
        BR.Bus.ejectAll(m)

        -- WARMUP only. Players who rode the bus are FREEFALL or GLIDE right
        -- now, and they become ALIVE when they LAND (DROP_LANDED in bus.lua),
        -- not when the state machine happens to tick over -- snapping a
        -- mid-air player to ALIVE would say they can fight before they can
        -- steer. The WARMUP case keeps `brforce playing` working: forcing
        -- past the bus entirely still promotes the people standing on the
        -- pad. LOBBY bystanders are never touched.
        BR.Roster.each(
            function(e) return e.matchId == m.id
                and e.state == BR.PlayerState.WARMUP end,
            function(src) BR.Roster.setState(src, BR.PlayerState.ALIVE) end)

        -- Nothing can win in the first moments of a match. Without this, any
        -- path that reaches PLAYING with states still settling ends instantly,
        -- and the log reads as though a match was played and won in one tick.
        m.startedAt = GetGameTimer()

        m.landCheck = nil   -- fresh stuck-lander bookkeeping per match

        -- The flight is over, so nobody is waiting for it. The "waiting for
        -- the last players to land" notice is STICKY, and a sticky notice is
        -- only as good as the code that withdraws it -- landingNotices runs
        -- during BUS only, so it cannot be the caller for the moment BUS ends.
        BR.Bus.clearLandingNotices(m)

        -- Normally counted at BUS entry (before anyone can be dead); this
        -- fallback covers `brforce playing` straight from warmup, where the
        -- bus never ran. Never overwrite a count the bus already took.
        m.startSquads = m.startSquads or BR.Server.squadsAlive(m)

        -- The storm clock starts NOW -- the last landing, not the bus timer
        -- -- and the first circle goes on every map immediately so rotation
        -- decisions start with the looting (user call, 2026-08-02).
        BR.Storm.begin(m)

    elseif state == BR.MatchState.ENDED then
        BR.Match.awardPlacements(m)

        -- Everyone goes HOME at ENDED, not at cleanup. Placements are
        -- already awarded (the line above; the CLEANUP wipe keeps them until
        -- then), and flipping the roster to LOBBY is what drives the whole
        -- trip client-side: the fade, the teleport to the vista, the
        -- invisibility, the shared lobby bucket. They KEEP their matchId --
        -- the summary screen still needs this match's ENDED/CLEANUP traffic.
        BR.Roster.each(
            function(e) return e.matchId == m.id
                and e.state ~= BR.PlayerState.LEFT end,
            function(src) BR.Roster.setState(src, BR.PlayerState.LOBBY) end)

    elseif state == BR.MatchState.CLEANUP then
        BR.Bus.clear(m)
        BR.Loot.clear(m)
        -- A DEBUG FREEZE DOES NOT OUTLIVE ITS MATCH. brstormfreeze holds ONE
        -- match still while something else is tested in it; carrying it into
        -- the next round means that round silently has no storm, and a battle
        -- royale with no storm never ends.
        if BR.Storm.thawOnMatchEnd then BR.Storm.thawOnMatchEnd() end
        BR.Match.resetPlayers(m)
    end
end

--- Assign final placements.
---
--- Placement is by squad, not by player: a four-stack that wipes together all
--- share a placement, which is what players expect and what the summary screen
--- needs to show.
--- @param m table
function BR.Match.awardPlacements(m)
    local living = {}
    BR.Roster.each(
        function(e)
            -- isInMatch, not just ALIVE/DBNO: since landing became what makes
            -- a player alive, a winner can be mid-glide when the last enemy
            -- dies -- still falling is still standing.
            return e.matchId == m.id and BR.Server.isInMatch(e.state)
        end,
        function(src, e) living[#living + 1] = { src = src, e = e } end)

    for _, p in ipairs(living) do
        p.e.placement = 1
        BR.Broadcast.delta({ op = 'update', src = p.src, e = { placement = 1 } })
    end

    -- Console only. The chat is for PLAYERS TALKING (user rule, 2026-08-03):
    -- the victory is announced by the end screen, which every participant is
    -- already looking at.
    if #living > 0 then
        local names = {}
        for _, p in ipairs(living) do names[#names + 1] = p.e.name end
        print(('[br_core] match %d won by %s'):format(m.id,
            table.concat(names, ', ')))
    else
        print(('[br_core] match %d ended with no survivors'):format(m.id))
    end
end

--- Clear per-player match state for one instance's players, at CLEANUP.
--- @param m table
function BR.Match.resetPlayers(m)
    m.storm = nil
    m.startSquads = nil
    BR.Inv.clearFor(m)
    BR.Roster.each(
        function(e) return e.matchId == m.id end,
        function(src, e)
            e.kills, e.downs, e.revives, e.damage = 0, 0, 0, 0.0
            e.lastDamageBy, e.lastDamageAt = nil, 0
            e.stormHp, e.lastStormAt = nil, nil
            e.hp, e.armour = 100.0, 0.0

            -- THE KNOCK COUNT IS PER MATCH, which is the only thing that makes
            -- the shortening bleed fair: a player who was picked up three times
            -- last round starts the next one on a full 45 seconds.
            e.dbnoUntil, e.dbnoCount = nil, 0
            e.downedBy, e.reviverSrc, e.reviveFrom = nil, nil, nil
            e.reviveBeat, e.reviveTickAt = nil, nil

            -- Explicitly cleared, so clients drop them too. squadId is
            -- per-match; partyId deliberately survives.
            BR.Roster.clearFields(src, { 'placement', 'squadId', 'colour' })
            if e.state ~= BR.PlayerState.LOBBY
               and e.state ~= BR.PlayerState.LEFT then
                BR.Roster.setState(src, BR.PlayerState.LOBBY)
            end
        end)
end

--- Cut a match's warmup short once it is full.
---
--- Warmup exists to give stragglers time to arrive. Once nobody else can join
--- THIS match, it is dead time -- and a full warmup staring at a 45 second
--- timer with every slot taken is the most obvious possible way to waste a
--- player's patience. (It also reopens the formation gate sooner: a full
--- warmup no longer blocks the next match from forming.)
---
--- Rebroadcasts rather than mutating quietly: clients derive their countdown
--- from endsAt, so an endsAt that changed without being announced would leave
--- every HUD counting down to the wrong moment.
--- @param m table
function BR.Match.shortenWarmupIfFull(m)
    if m.shortened then return end
    if BR.Server.countIn(m) < M.maxPlayers then return end

    local cap = GetGameTimer() + M.warmupShortened * 1000
    if cap >= m.endsAt then
        m.shortened = true    -- already sooner than the cap; nothing to do
        return
    end

    m.endsAt = cap
    m.shortened = true
    print(('[br_core] match %d full -- warmup cut to %ds'):format(m.id, M.warmupShortened))
    BR.Broadcast.state(m, m.state, m.endsAt, { reason = 'lobbyFull' })
end

--- Why the next match OF A MODE cannot form yet, or nil if it can.
---
--- THE GATE AND THE EXPLANATION ARE THE SAME FUNCTION, deliberately.
---
--- The formation tick decides whether to start; the lobby broadcast tells
--- players what it is waiting for. Written separately those two drift, and the
--- failure is nasty: the interface confidently explains a condition that is
--- not the one actually holding the match, so the player does the thing it
--- asked for and nothing happens. One function, two callers, no disagreement.
---
--- Note there is no "a warmup is open" reason here: while one of this mode
--- is open, ready-ups late-join it instead of queueing, so the queue this
--- function reads only ever holds players waiting for a NEW match.
---
--- @param mode string|nil  the mode whose queue is being judged; defaults to
---        the dominant mode (the lobby status display's approximation)
--- @return table|nil  { reason = 'players'|'squads'|'party', have, need }
function BR.Match.startBlocker(mode)
    mode = mode or BR.Lobby.dominantMode()
    local queued = #BR.Lobby.ids(mode)
    local need   = BR.Lobby.needed()
    if queued < need then
        return { reason = 'players', have = queued, need = need }
    end

    -- Enough PLAYERS is not the same as enough TEAMS. Four players who all
    -- queued as one party form a single squad, and a single squad has already
    -- met the win condition before the match starts.
    if mode ~= BR.Mode.SOLO.key then
        local squads    = BR.Party.prospectiveSquads(BR.Lobby.ids(mode), mode)
        local minSquads = BR.Config.Match.MinSquads(BR.Server.devMode)
        if squads < minSquads then
            return { reason = 'squads', have = squads, need = minSquads }
        end

        -- PARTIES ENTER TOGETHER -- with a patience limit. One member
        -- readying up must not launch the match while the rest of their
        -- party is still picking a mode (the first two-client squad test
        -- started the instant the first Ready landed) -- but one AFK
        -- partymate must not brick the queue for everyone either. So the
        -- hold lasts partyGraceSeconds; after that the match forms without
        -- the stragglers, and the warmup door they can still walk through
        -- is the late-join path that already exists. The party panel marks
        -- who the room is waiting on (check / ellipsis) the whole time.
        local queuedSet = {}
        for _, src in ipairs(BR.Lobby.ids(mode)) do queuedSet[src] = true end
        local incomplete = nil
        for src in pairs(queuedSet) do
            local party = BR.Party.of(src)
            if party then
                local ready = 0
                for _, mem in ipairs(party.members) do
                    if queuedSet[mem] then ready = ready + 1 end
                end
                if ready < #party.members then
                    incomplete = { reason = 'party', have = ready, need = #party.members }
                    break
                end
            end
        end
        if incomplete then
            BR.Server.partyHoldSince = BR.Server.partyHoldSince or GetGameTimer()
            if GetGameTimer() - BR.Server.partyHoldSince
               < (BR.Config.Match.partyGraceSeconds * 1000) then
                return incomplete
            end
            -- Patience spent: start without them.
        else
            BR.Server.partyHoldSince = nil
        end
    end

    return nil
end

--- Say out loud why a full queue is not starting.
---
--- The tick runs at 4Hz, so this is throttled and only speaks when the answer
--- changes. Without it the lobby sits at "enough players" forever with no
--- indication of what it is waiting for, which is indistinguishable from the
--- queue being broken -- a failure mode this project has already shipped once.
--- @param blocker table
local lastWarn = { key = '', at = 0 }

function BR.Match.announceBlocker(blocker)
    -- An empty queue explains itself. Announcing it anyway printed
    -- "holding: 0 queued, need 1" every 15 seconds into an empty server's
    -- console, forever. Speak only when somebody is actually waiting.
    if blocker.have == 0 then return end

    local now = GetGameTimer()
    local key = ('%s:%d/%d'):format(blocker.reason, blocker.have, blocker.need)
    if key == lastWarn.key and (now - lastWarn.at) < 15000 then return end
    lastWarn.key, lastWarn.at = key, now

    -- Console only; the lobby screen already tells the waiting players what
    -- the queue is short of, phrased from this same blocker.
    if blocker.reason == 'squads' then
        print(('[br_core] holding: %d squad(s), need %d -- waiting for another team')
            :format(blocker.have, blocker.need))
    elseif blocker.reason == 'party' then
        print(('[br_core] holding: a party has %d/%d readied up')
            :format(blocker.have, blocker.need))
    else
        print(('[br_core] holding: %d queued, need %d')
            :format(blocker.have, blocker.need))
    end
end

--- How long after PLAYING begins before a win can be declared.
--- Purely a guard against states that have not settled; a real match cannot be
--- decided this fast anyway.
local WIN_GRACE_MS = 3000

--- Is there anyone left to fight over, in THIS match?
--- @param m table
--- @return boolean
local function winConditionMet(m)
    -- Only meaningful once the match is live; two players in a lobby are not a
    -- finished match.
    if m.state ~= BR.MatchState.PLAYING then return false end
    if m.startedAt and (GetGameTimer() - m.startedAt) < WIN_GRACE_MS then
        return false
    end

    -- An empty match has not "been won" -- it has nobody in it. The
    -- abandoned-match sweep in the tick is what ends those.
    if BR.Server.countIn(m) == 0 then return false end

    -- DEV ONLY: a match that STARTED with exactly one squad has nothing to
    -- win, so as long as that squad is still standing it never auto-ends --
    -- a lone developer can sit in PLAYING and poke at the world.
    -- brforce/brskip/brleave are the ways out, and everyone dying still ends
    -- it. Production cannot reach this: the minSquads gate refuses to start
    -- a one-squad match at all. (== 1, not <= 1: a zero here means states
    -- had not settled when the count was taken, which is the grace period's
    -- problem, not this rule's.)
    if BR.Server.devMode and m.startSquads == 1
       and BR.Server.squadsAlive(m) >= 1 then
        return false
    end

    return BR.Server.squadsAlive(m) <= 1
end

--- One instance's share of the tick.
--- @param m table
local function matchTick(m, now)
    -- A MATCH NOBODY BELONGS TO CANNOT END ITSELF: the win condition
    -- refuses empty matches by design, so an instance whose last member
    -- left (everyone brleaving mid-PLAYING) sat leaked forever with its
    -- storm still ticking (repro'd 2026-08-04). Memberless means dissolve,
    -- whatever the state.
    if BR.Server.countIn(m) == 0
       and m.state ~= BR.MatchState.ENDED
       and m.state ~= BR.MatchState.CLEANUP then
        print(('[br_core] match %d: memberless -- dissolving'):format(m.id))
        BR.Match.destroy(m)
        return
    end

    if m.state == BR.MatchState.WARMUP then
        BR.Match.shortenWarmupIfFull(m)
    end

    -- Whoever is already on the ground learns the match is waiting on the
    -- rest. Polled rather than hooked to the landing report, which has a long
    -- history of not arriving -- see BR.Bus.landingNotices.
    if m.state == BR.MatchState.BUS then
        BR.Bus.landingNotices(m)
    end

    -- AN ABANDONED MATCH DIES -- but DYING IS NOT LEAVING. Everyone
    -- brleaving during warmup or the flight leaves nothing to run (nothing
    -- happened, nothing to show): the instance is destroyed on the spot.
    -- If anyone actually DIED, this was a match, however short, and it takes
    -- the REAL exit: ENDED runs placements, the verdict, the roster sweep
    -- and the trip home.
    if (m.state == BR.MatchState.WARMUP or m.state == BR.MatchState.BUS)
       and BR.Server.aliveCount(m) == 0 then
        local anyDead = BR.Server.countIn(m, function(p)
            return p.state == BR.PlayerState.DEAD
        end) > 0
        if anyDead then
            print(('[br_core] match %d: everyone is down -- ending'):format(m.id))
            BR.Match.transition(m, BR.MatchState.ENDED)
        else
            print(('[br_core] match %d: everyone left -- dissolving'):format(m.id))
            BR.Match.destroy(m)
        end
        return
    end

    if m.state == BR.MatchState.BUS then
        -- The drop ends when the LAST player is down -- not when the route
        -- timer says so. Everyone jumped early and landed? The match goes
        -- live now instead of waiting out an empty flight. The endsAt timer
        -- below stays as the CEILING: a client that crashes mid-fall never
        -- reports a landing, and one ghost must not hold 47 players in the
        -- pre-match state forever.
        local airborne = BR.Server.countIn(m, function(p)
            return p.state == BR.PlayerState.BUS
                or p.state == BR.PlayerState.FREEFALL
                or p.state == BR.PlayerState.GLIDE
        end)
        if airborne == 0 and BR.Server.aliveCount(m) > 0 then
            print(('[br_core] match %d: last player down -- going live'):format(m.id))
            BR.Match.transition(m, BR.MatchState.PLAYING)
            return
        end

        -- THE CEILING YIELDS TO A LIVE DESCENDER. A real glider off a 500m
        -- exit outlasts the route timer, and forcing PLAYING under them
        -- started the storm clock before the last player had landed.
        --
        -- Altitude is tracked EVERY tick, so that at the moment the ceiling
        -- hits, "is anyone genuinely falling" is already answered -- deciding
        -- it only at expiry would either grant every ghost one free
        -- extension (first sample has no baseline) or grant a real glider
        -- none (no second sample before the transition). A frozen altitude
        -- stops paying within one round, so a hung client cannot hold the
        -- room; the extensions cap at two minutes regardless.
        m.descent = m.descent or { extended = 0, z = {}, falling = {} }
        BR.Roster.each(
            function(e)
                return e.matchId == m.id
                   and (e.state == BR.PlayerState.BUS
                     or e.state == BR.PlayerState.FREEFALL
                     or e.state == BR.PlayerState.GLIDE)
            end,
            function(src, e)
                if e.pos and (now - (e.posAt or 0)) < 3000 then
                    -- A RATE, not a per-tick delta. A canopy descends about
                    -- 2 m/s, which is half a metre per 250ms tick -- under
                    -- the old 1.0m test it read as NOT descending, so the
                    -- ceiling refused to wait for the one thing it exists to
                    -- wait for. Judged per second, freefall and canopy both
                    -- clear the bar and a hung client still does not.
                    local prev = m.descent.z[src]
                    local verdict = BR.ClassifyDescent(
                        prev and prev.z, prev and prev.at,
                        e.pos.z, e.posAt or now,
                        BR.Config.Match.descendRate)
                    if verdict then
                        m.descent.falling[src] = (verdict == 'falling') or nil
                    end
                    -- Only record a sample when it is genuinely new: the tick
                    -- is 4Hz and positions arrive at 2Hz, so half of all ticks
                    -- would otherwise overwrite the baseline with the same
                    -- reading and make every rate zero.
                    if not prev or prev.at ~= (e.posAt or now) then
                        m.descent.z[src] = { z = e.pos.z, at = e.posAt or now }
                    end
                else
                    m.descent.falling[src] = nil
                end
            end)

        if m.endsAt > 0 and now >= m.endsAt and airborne > 0
           and m.descent.extended < 120000 then
            local descending = false
            for _, v in pairs(m.descent.falling) do
                if v then descending = true break end
            end
            if descending then
                m.descent.extended = m.descent.extended + 10000
                m.endsAt = m.endsAt + 10000
                BR.Broadcast.state(m, m.state, m.endsAt, { reason = 'descent' })
                print(('[br_core] match %d: someone is still descending -- holding BUS 10s more')
                    :format(m.id))
            end
        end
    end

    -- STUCK LANDERS BECOME ALIVE. A player whose landing report was lost
    -- (or refused) stays FREEFALL/GLIDE forever -- and those states are
    -- invincible on their own client, so they walk the match untouchable
    -- ("players seem invincible", live report). Standing at a constant
    -- altitude for five seconds is not falling by any definition: promote
    -- them server-side, which drops their invincibility and re-arms every
    -- system keyed on ALIVE.
    --
    -- This MUST run during BUS as well as PLAYING, and the first version
    -- (PLAYING only) was circular: a stuck lander still counts as airborne,
    -- airborne > 0 is exactly what holds the match in BUS -- so the net that
    -- would fix them was waiting on the state THEY were blocking, and the
    -- player walked Los Santos untouchable until the route timer ran out
    -- ("invincible until the flight is over", live repro). No false
    -- positives from the ride itself: riders are in the BUS state, which
    -- this filter never touches, and a jumper awaiting exit coords hits the
    -- self-place fallback (and a changing z) within a second.
    if m.state == BR.MatchState.PLAYING or m.state == BR.MatchState.BUS then
        m.landCheck = m.landCheck or { z = {}, still = {} }
        BR.Roster.each(
            function(e)
                return e.matchId == m.id
                   and (e.state == BR.PlayerState.FREEFALL
                     or e.state == BR.PlayerState.GLIDE)
            end,
            function(src, e)
                if e.pos and (now - (e.posAt or 0)) < 3000 then
                    -- THE SAME RATE TEST, and this is the half that actually
                    -- hurt players. Under the old per-tick delta a parachutist
                    -- looked stationary, so this net PROMOTED THEM TO ALIVE
                    -- WHILE THEY WERE STILL IN THE AIR -- which sent them the
                    -- "match starts once everyone has landed" toast before
                    -- they had landed, dropped the airborne count to zero, and
                    -- took the match live under a player still on canopy
                    -- (user, 2026-08-06). It was meant to catch a client whose
                    -- landing report was lost, and it caught ordinary flying.
                    --
                    -- Stillness is now counted in WALL TIME, so the threshold
                    -- means five seconds whatever the tick rate happens to be.
                    local prev = m.landCheck.z[src]
                    local verdict = BR.ClassifyDescent(
                        prev and prev.z, prev and prev.at,
                        e.pos.z, e.posAt or now,
                        BR.Config.Match.descendRate)

                    if verdict == 'still' then
                        local since = m.landCheck.still[src] or (e.posAt or now)
                        m.landCheck.still[src] = since
                        local heldMs = (e.posAt or now) - since
                        if heldMs >= (BR.Config.Match.stuckLanderMs or 5000) then
                            print(('[br_core] %s (%d) has held one altitude %.1fs -- promoting to ALIVE')
                                :format(e.name, src, heldMs / 1000.0))
                            BR.Roster.setState(src, BR.PlayerState.ALIVE)
                            m.landCheck.still[src] = nil
                        end
                    elseif verdict == 'falling' then
                        m.landCheck.still[src] = nil
                    end

                    if not prev or prev.at ~= (e.posAt or now) then
                        m.landCheck.z[src] = { z = e.pos.z, at = e.posAt or now }
                    end
                end
            end)
    end

    if winConditionMet(m) then
        BR.Match.transition(m, BR.MatchState.ENDED)
        return
    end

    -- A timed state whose time is up moves to whatever comes next.
    if m.endsAt > 0 and now >= m.endsAt then
        if m.state == BR.MatchState.WARMUP then
            -- Participants still standing on the pad: a lobby idler who
            -- never readied up must not pad the number that decides whether
            -- this match is worth flying.
            if BR.Server.aliveCount(m) < M.MinPlayers(BR.Server.devMode) then
                print(('[br_core] match %d: not enough players, dissolving'):format(m.id))
                BR.Match.destroy(m)
            else
                -- No duration passed: onEnter(BUS) plans the route and sets
                -- the deadline from it.
                BR.Match.transition(m, BR.MatchState.BUS)
            end
        elseif m.state == BR.MatchState.BUS then
            BR.Match.transition(m, BR.MatchState.PLAYING)
        elseif m.state == BR.MatchState.ENDED then
            BR.Match.transition(m, BR.MatchState.CLEANUP)
        elseif m.state == BR.MatchState.CLEANUP then
            BR.Match.destroy(m)
        end
    end
end

--- The tick: every instance advances, then the queue may form a new one.
--- Deliberately dumb per instance -- check whether the current state should
--- end, and if so move on. All the interesting logic lives in onEnter.
local function tick()
    local now = GetGameTimer()

    BR.Server.eachMatch(function(m) matchTick(m, now) end)

    -- FORMATION, PER MODE. Matches are homogeneous (user call, 2026-08-04),
    -- so each mode's queue forms its own match, and a solo warmup being open
    -- never blocks a squad match from forming beside it -- both warmups
    -- share the communal pad; the flights are separate. A mode's queue only
    -- ever accumulates while no warmup of that mode is open (ready-ups
    -- late-join an open one instead of queueing), which is the formation
    -- gate: the next match of a mode forms from the first players to ready
    -- up after every match of that mode is BUS-or-later or a full warmup.
    for _, modeDef in pairs(BR.Mode) do
        local mode = modeDef.key
        if not BR.Server.formingMatch(mode) then
            local parts = BR.Lobby.ids(mode)
            if #parts > 0 then
                -- Every reason to hold is checked BEFORE the queue is
                -- consumed. The queue is spent on the way into WARMUP, so
                -- refusing later would leave the players out of the queue
                -- with no match to be in.
                local blocker = BR.Match.startBlocker(mode)
                if blocker then
                    BR.Match.announceBlocker(blocker)
                else
                    BR.Lobby.consume(parts)
                    BR.Match.create(mode, parts)
                end
            end
        end
    end
end

BR.Sched.every(250, 'match.tick', tick)

--- Leave the current match, on the player's own initiative.
---
--- The match must not notice beyond the elimination: leaving while alive IS an
--- elimination -- placement recorded, squadmates play on, the alive count drops
--- through the same path a death would use. Anything gentler would create a
--- second, parallel way to exit a match, and every later system (placements,
--- stats, spectate) would have to know about both.
---
--- The party deliberately survives. Leaving the MATCH and leaving the PARTY
--- are different intents with different buttons.
--- @param src integer
function BR.Match.leaveMatch(src)
    local entry = BR.Roster.get(src)
    if not entry then return end

    if entry.state == BR.PlayerState.LOBBY then
        -- Already home. If they still carry a matchId (the ENDED summary),
        -- leaving just detaches them from the last of its traffic -- no
        -- second trip for a player already standing in the lobby.
        BR.Roster.setMatch(src, nil)
        return
    end

    if entry.state == BR.PlayerState.WARMUP then
        -- The match has not started; there is no placement to record. They
        -- simply step out, and the warmup-end headcount treats them exactly
        -- like someone who never readied up.
        BR.Roster.clearFields(src, { 'squadId', 'colour' })
    elseif BR.Server.isInMatch(entry.state)
        or entry.state == BR.PlayerState.DBNO then
        BR.Combat.eliminate(src, 'left', nil)
    end
    -- DEAD and SPECTATING players fall through: already out of the fight, they
    -- only need the trip back to the lobby.

    BR.Roster.setState(src, BR.PlayerState.LOBBY)
    -- Leaving really leaves: unlike the ENDED sweep (which keeps matchId for
    -- the summary), a voluntary exit detaches immediately -- no more of this
    -- match's traffic, free to queue for the next one.
    BR.Roster.setMatch(src, nil)
    TriggerClientEvent(BR.Net.TO_LOBBY, src)
    BR.Server.notify(src, 'You left the match.', 'info')

    -- AND THEIR PARTY DISPLAY IS RE-ASSERTED, the same way it is when a match
    -- is destroyed. The SQUAD channel spends the whole match carrying the
    -- in-match squad, so a party change during one -- including leaving it on
    -- the way out through the pause menu -- may never have reached this
    -- client. Walking back into the lobby with a party the server does not
    -- have is how "neither player can leave the party" starts (user,
    -- 2026-08-09): the button asks to leave something already gone.
    --
    -- The match-destroy path does this per player; a voluntary exit skips
    -- that path entirely, which is exactly why it needs its own call.
    BR.Party.resync(src)

    print(('[br_core] %s (%d) left the match'):format(entry.name, src))
end

RegisterNetEvent(BR.Net.MATCH_LEAVE)
AddEventHandler(BR.Net.MATCH_LEAVE, function()
    BR.Match.leaveMatch(source)
end)

-- --------------------------------------------------------------------------
-- Admin
-- --------------------------------------------------------------------------

--- The instance admin commands operate on: the newest one, or -- for brforce
--- from nothing -- a fresh instance formed from whoever is queued (falling
--- back to nobody, which is the honest outcome of forcing a match no one
--- asked for).
--- @return table
local function debugTarget()
    local m = BR.Server.latestMatch()
    if m then return m end
    local mode  = BR.Lobby.dominantMode()
    local parts = BR.Lobby.ids()
    BR.Lobby.clear()
    return BR.Match.create(mode, parts)
end

RegisterCommand('brforce', function(_, args)
    local target = args[1]
    if not target then
        local m = BR.Server.latestMatch()
        print(('  usage: brforce <state>   current: %s')
            :format(m and m.state or BR.MatchState.WAITING))
        print('  states: waiting warmup bus playing ended cleanup')
        return
    end

    if target == BR.MatchState.WAITING then
        -- WAITING is no longer an instance state: forcing it dissolves the
        -- newest match outright, which is what the command was for.
        local m = BR.Server.latestMatch()
        if m then
            print(('[br_core] admin dissolved match %d (was %s)'):format(m.id, m.state))
            BR.Match.destroy(m)
        else
            print('  no match to dissolve')
        end
        return
    end

    for _, v in pairs(BR.MatchState) do
        if v == target then
            local m = debugTarget()
            print(('[br_core] admin forced match %d: %s -> %s'):format(m.id, m.state, v))
            BR.Match.transition(m, v)
            return
        end
    end
    print(('  unknown state: %s'):format(target))
end, true)

RegisterCommand('brskip', function()
    -- Ends the newest match's current timed state immediately.
    local m = BR.Server.latestMatch()
    if not m then
        print('  no match running')
        return
    end
    if m.endsAt > 0 then
        m.endsAt = GetGameTimer()
        print(('[br_core] admin skipped to the end of match %d\'s %s'):format(m.id, m.state))
    else
        print(('  %s has no timer to skip'):format(m.state))
    end
end, true)
