-- The match state machine.
--
--   WAITING ──(enough players)──► WARMUP ──(timer)──► BUS ──(route done)──► PLAYING
--                                                                              │
--                        CLEANUP ◄──(timer)── ENDED ◄──(one team left)─────────┘
--                           │
--                           └──► WAITING
--
-- One authority, one broadcast per transition. Clients never infer the state --
-- they are told, and they derive every countdown from the endsAt they are given
-- rather than running their own timers.
--
-- Milestone 1 implements the skeleton: transitions, timing, and the win
-- condition. BUS and PLAYING currently just hold for their duration -- the drop
-- and the storm arrive in M3 and M4 and hook in here.

BR = BR or {}
BR.Match = {}

local M = BR.Config.Match
local S = BR.Server.match

--- Seconds each state lasts. nil means "until something else ends it" -- WAITING
--- ends when enough players queue, PLAYING when one team is left.
local DURATION = {
    [BR.MatchState.WAITING] = nil,
    [BR.MatchState.WARMUP]  = M.warmupSeconds,
    [BR.MatchState.BUS]     = nil,   -- set from the bus route in M3
    [BR.MatchState.PLAYING] = nil,
    [BR.MatchState.ENDED]   = M.endedSeconds,
    [BR.MatchState.CLEANUP] = M.cleanupSeconds,
}

--- Move to a new state.
---
--- The only way the match state ever changes. Everything else calls this, so
--- there is one place to log from and one place that broadcasts.
---
--- @param state string
--- @param durationSec number|nil  overrides the table above
function BR.Match.transition(state, durationSec)
    local from = S.state
    if from == state then return end

    local secs = durationSec or DURATION[state]
    S.state  = state
    S.endsAt = secs and (GetGameTimer() + secs * 1000) or 0
    S.shortened = false

    print(('[br_core] match: %s -> %s%s'):format(
        from, state, secs and (' (%ds)'):format(secs) or ''))

    BR.Broadcast.state(state, S.endsAt, { from = from })
    BR.Match.onEnter(state, from)
end

--- Side effects of entering a state. Kept separate from transition() so the
--- transition itself stays trivially readable.
--- @param state string
--- @param from string
function BR.Match.onEnter(state, from)
    if state == BR.MatchState.WARMUP then
        -- Only the players who READIED UP enter the match. This used to sweep
        -- the whole roster, which conscripted everyone connected -- a player
        -- idling in the lobby, or one who had just left the previous match,
        -- was dragged into warmup they never asked for. The queue gates the
        -- start; it must also define who is in.
        --
        -- The fallback covers `brforce warmup`, which jumps here without the
        -- tick having snapshotted the queue. It still respects the rule: the
        -- QUEUE is consumed, not the roster -- forcing a match with nobody
        -- queued produces an empty match, which is the honest outcome.
        local parts = S.participants
        if not parts or #parts == 0 then
            parts = BR.Lobby.ids()
            BR.Lobby.clear()
        end
        S.participants = nil   -- consumed; must never leak into the next match
        S.partyHoldSince = nil -- the party-gate patience is per queue attempt

        -- The match's identity is minted when it FORMS, not at the bus:
        -- routing buckets are matchBucketBase + matchId, and participants
        -- enter their match's bucket right here as their states flip to
        -- WARMUP. Minting at BUS (as before) would have re-bucketed
        -- everybody mid-flow.
        BR.Server.matchId = BR.Server.matchId + 1

        for _, src in ipairs(parts) do
            if BR.Roster.get(src) then
                BR.Roster.setState(src, BR.PlayerState.WARMUP)
            end
        end
        -- Squads are formed once, here, from the parties that exist at the
        -- moment the match starts. Forming them earlier would go stale as
        -- people join and leave parties in the lobby.
        BR.Party.formSquads(S.mode)

        -- The flight is drawn NOW, not at departure: warmup is when players
        -- study the route on the map and pick their drop.
        BR.Bus.plan()

    elseif state == BR.MatchState.BUS then
        S.descent = nil     -- fresh per flight: the descent-grace bookkeeping
        S.landCheck = nil   -- and the stuck-lander bookkeeping runs here too

        -- The flight decides how long BUS lasts, so the deadline is set HERE
        -- and rebroadcast. The geometry was planned at WARMUP; departure only
        -- stamps the clock onto it. `brforce bus` from WAITING skips warmup,
        -- so plan on demand if nothing is drawn yet.
        if not BR.Bus.active() then BR.Bus.plan() end
        local dur = BR.Bus.depart()
        S.endsAt = GetGameTimer() + math.floor(dur * 1000)
        BR.Broadcast.state(S.state, S.endsAt, { reason = 'busRoute' })

        BR.Roster.each(
            function(e) return e.state == BR.PlayerState.WARMUP end,
            function(src) BR.Roster.setState(src, BR.PlayerState.BUS) end)

        -- The starting team count is taken HERE, before anyone can possibly
        -- be dead (warmup is invincible; the doors are still shut). Counting
        -- it at PLAYING was the bug where a player who died during the bus
        -- ride made a two-player match register as "started with one squad"
        -- -- engaging the dev-mode never-auto-end hold and hanging the match.
        S.startSquads = BR.Server.squadsAlive()

    elseif state == BR.MatchState.PLAYING then
        -- Everyone not already out becomes ALIVE -- not just those on the bus.
        --
        -- Matching only BUS meant `brforce playing`, which skips the bus
        -- entirely, promoted nobody: every player stayed in lobby/warmup, which
        -- do not count as alive, so squadsAlive() was 0 and the win condition
        -- fired on the very next tick. The match ended the instant it started.
        --
        -- Anyone somehow still aboard goes out the door first -- brforce can
        -- reach PLAYING mid-flight, and a player left in the BUS state would
        -- be invisible and frozen with the match running around them.
        BR.Bus.ejectAll()

        -- WARMUP only. Players who rode the bus are FREEFALL or GLIDE right
        -- now, and they become ALIVE when they LAND (DROP_LANDED in bus.lua),
        -- not when the state machine happens to tick over -- snapping a
        -- mid-air player to ALIVE would say they can fight before they can
        -- steer. The WARMUP case keeps `brforce playing` working: forcing
        -- past the bus entirely still promotes the people standing on the
        -- pad. LOBBY bystanders are never touched.
        BR.Roster.each(
            function(e) return e.state == BR.PlayerState.WARMUP end,
            function(src) BR.Roster.setState(src, BR.PlayerState.ALIVE) end)

        -- Nothing can win in the first moments of a match. Without this, any
        -- path that reaches PLAYING with states still settling ends instantly,
        -- and the log reads as though a match was played and won in one tick.
        S.startedAt = GetGameTimer()
        S.landCheck = nil   -- fresh stuck-lander bookkeeping per match

        -- Normally counted at BUS entry (before anyone can be dead); this
        -- fallback covers `brforce playing` straight from warmup, where the
        -- bus never ran. Never overwrite a count the bus already took.
        S.startSquads = S.startSquads or BR.Server.squadsAlive()

        -- The storm clock starts NOW -- the last landing, not the bus timer
        -- -- and the first circle goes on every map immediately so rotation
        -- decisions start with the looting (user call, 2026-08-02).
        BR.Storm.begin()

    elseif state == BR.MatchState.ENDED then
        BR.Match.awardPlacements()

        -- Everyone goes HOME at ENDED, not at cleanup. Placements are
        -- already awarded (the line above; reset() keeps them until
        -- CLEANUP), and flipping the roster to LOBBY is what drives the
        -- whole trip client-side: the fade, the teleport to the vista, the
        -- invisibility, the private bucket. Waiting out the summary period
        -- standing over a corpse in Los Santos served nobody -- M7's
        -- victory screen will render over the lobby instead.
        BR.Roster.each(
            function(e) return e.state ~= BR.PlayerState.LEFT end,
            function(src) BR.Roster.setState(src, BR.PlayerState.LOBBY) end)

    elseif state == BR.MatchState.CLEANUP then
        BR.Bus.clear()
        BR.Match.reset()

    elseif state == BR.MatchState.WAITING then
        BR.Bus.clear()   -- covers brforce waiting from mid-flight too

        -- NO MATCH STATE OUTLIVES THE MATCH. The normal road home runs
        -- through ENDED's sweep, but aborts and brforce arrive here
        -- directly -- and a player still DEAD (or BUS, or FREEFALL) at
        -- WAITING is stranded: no teleport fires, no resurrection, the
        -- lobby menu draws over a corpse. Whatever the road, WAITING
        -- means everyone is a lobby player now.
        BR.Roster.each(
            function(e) return e.state ~= BR.PlayerState.LOBBY
                and e.state ~= BR.PlayerState.LEFT end,
            function(src) BR.Roster.setState(src, BR.PlayerState.LOBBY) end)

        if from == BR.MatchState.CLEANUP then
            BR.Broadcast.snapshot()   -- re-seed everyone for the next match
        end
    end
end

--- Assign final placements.
---
--- Placement is by squad, not by player: a four-stack that wipes together all
--- share a placement, which is what players expect and what the summary screen
--- needs to show.
function BR.Match.awardPlacements()
    local living = {}
    BR.Roster.each(
        function(e)
            -- isInMatch, not just ALIVE/DBNO: since landing became what makes
            -- a player alive, a winner can be mid-glide when the last enemy
            -- dies -- still falling is still standing.
            return BR.Server.isInMatch(e.state)
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
        print(('[br_core] match %d won by %s'):format(BR.Server.matchId,
            table.concat(names, ', ')))
    else
        print(('[br_core] match %d ended with no survivors'):format(BR.Server.matchId))
    end
end

--- Clear per-match state, ready for the next one.
function BR.Match.reset()
    BR.Server.storm = nil
    S.startSquads = nil   -- the next match takes its own count at BUS entry
    BR.Roster.each(nil, function(src, e)
        e.kills, e.downs, e.revives, e.damage = 0, 0, 0, 0.0
        e.lastDamageBy, e.lastDamageAt = nil, 0
        e.stormHp, e.lastStormAt = nil, nil
        e.hp, e.armour = 100.0, 0.0

        -- Explicitly cleared, so clients drop them too. squadId is per-match;
        -- partyId deliberately survives.
        BR.Roster.clearFields(src, { 'placement', 'squadId', 'colour' })
        BR.Roster.setState(src, BR.PlayerState.LOBBY)
    end)
end

--- Cut the warmup short once the lobby is full.
---
--- Warmup exists to give stragglers time to arrive. Once nobody else can join,
--- it is dead time -- and a full lobby staring at a 45 second timer with every
--- slot taken is the most obvious possible way to waste a player's patience.
---
--- Rebroadcasts rather than mutating quietly: clients derive their countdown
--- from endsAt, so an endsAt that changed without being announced would leave
--- every HUD counting down to the wrong moment.
function BR.Match.shortenWarmupIfFull()
    if S.shortened then return end
    if BR.Server.count() < M.maxPlayers then return end

    local cap = GetGameTimer() + M.warmupShortened * 1000
    if cap >= S.endsAt then
        S.shortened = true    -- already sooner than the cap; nothing to do
        return
    end

    S.endsAt = cap
    S.shortened = true
    print(('[br_core] lobby full -- warmup cut to %ds'):format(M.warmupShortened))
    BR.Broadcast.state(S.state, S.endsAt, { reason = 'lobbyFull' })
end

--- Why the next match cannot start yet, or nil if it can.
---
--- THE GATE AND THE EXPLANATION ARE THE SAME FUNCTION, deliberately.
---
--- The tick below decides whether to start; the lobby broadcast tells players
--- what it is waiting for. Written separately those two drift, and the failure
--- is nasty: the interface confidently explains a condition that is not the one
--- actually holding the match, so the player does the thing it asked for and
--- nothing happens. One function, two callers, no possible disagreement.
---
--- @return table|nil  { reason = 'players'|'squads', have, need }
function BR.Match.startBlocker()
    local queued = BR.Lobby.count()
    local need   = BR.Lobby.needed()
    if queued < need then
        return { reason = 'players', have = queued, need = need }
    end

    -- Enough PLAYERS is not the same as enough TEAMS. Four players who all
    -- queued as one party form a single squad, and a single squad has already
    -- met the win condition before the match starts.
    local mode = BR.Lobby.dominantMode()
    if mode ~= BR.Mode.SOLO.key then
        local squads    = BR.Party.prospectiveSquads(BR.Lobby.ids(), mode)
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
        for _, src in ipairs(BR.Lobby.ids()) do queuedSet[src] = true end
        local incomplete = nil
        for src in pairs(queuedSet) do
            local party = BR.Party.of(src)
            if party then
                local ready = 0
                for _, m in ipairs(party.members) do
                    if queuedSet[m] then ready = ready + 1 end
                end
                if ready < #party.members then
                    incomplete = { reason = 'party', have = ready, need = #party.members }
                    break
                end
            end
        end
        if incomplete then
            S.partyHoldSince = S.partyHoldSince or GetGameTimer()
            if GetGameTimer() - S.partyHoldSince
               < (BR.Config.Match.partyGraceSeconds * 1000) then
                return incomplete
            end
            -- Patience spent: start without them.
        else
            S.partyHoldSince = nil
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

--- Is there anyone left to fight over?
--- @return boolean
--- How long after PLAYING begins before a win can be declared.
--- Purely a guard against states that have not settled; a real match cannot be
--- decided this fast anyway.
local WIN_GRACE_MS = 3000

local function winConditionMet()
    -- Only meaningful once the match is live; two players in a lobby are not a
    -- finished match.
    if S.state ~= BR.MatchState.PLAYING then return false end
    if S.startedAt and (GetGameTimer() - S.startedAt) < WIN_GRACE_MS then
        return false
    end

    -- An empty server has not "been won" -- it has nobody in it. Treating zero
    -- squads as a victory produced a match that ended immediately with no
    -- survivors and a confusing log line.
    if BR.Server.count() == 0 then return false end

    -- DEV ONLY: a match that STARTED with exactly one squad has nothing to
    -- win, so as long as that squad is still standing it never auto-ends --
    -- a lone developer can sit in PLAYING and poke at the world.
    -- brforce/brskip/brleave are the ways out, and everyone dying still ends
    -- it. Production cannot reach this: the minSquads gate refuses to start
    -- a one-squad match at all. (== 1, not <= 1: a zero here means states
    -- had not settled when the count was taken, which is the grace period's
    -- problem, not this rule's.)
    if BR.Server.devMode and S.startSquads == 1
       and BR.Server.squadsAlive() >= 1 then
        return false
    end

    return BR.Server.squadsAlive() <= 1
end

--- The tick. Deliberately dumb: check whether the current state should end, and
--- if so move on. All the interesting logic lives in onEnter.
local function tick()
    local now = GetGameTimer()

    if S.state == BR.MatchState.WAITING then
        -- Start on the QUEUED count, not the connected count. Being connected
        -- and wanting to play are different things: starting on connections
        -- drags anyone idling in the lobby into a match they never asked for,
        -- and made the Play button decorative.
        --
        -- Every reason to hold is checked BEFORE the queue is consumed. The
        -- queue is spent on the way into WARMUP, so refusing later would leave
        -- the players out of the queue with no match to be in.
        local blocker = BR.Match.startBlocker()
        if blocker then
            BR.Match.announceBlocker(blocker)
            return
        end

        -- Consume the queue BEFORE transitioning. If anything in the
        -- transition throws, the queue must still be spent -- otherwise the
        -- next tick sees a full queue and tries to start the match again,
        -- every tick, forever.
        --
        -- The snapshot taken here is the match's roster of participants:
        -- onEnter(WARMUP) runs after the queue is cleared, so it reads this
        -- rather than the queue -- and it must never read the whole roster,
        -- which would conscript players who did not ready up.
        S.mode = BR.Lobby.dominantMode()
        S.participants = BR.Lobby.ids()
        BR.Lobby.clear()
        BR.Match.transition(BR.MatchState.WARMUP)
        return
    end

    if S.state == BR.MatchState.WARMUP then
        BR.Match.shortenWarmupIfFull()
    end

    -- AN ABANDONED MATCH ABORTS -- but DYING IS NOT LEAVING. Everyone
    -- brleaving during warmup or the flight goes straight back to WAITING
    -- (nothing happened, nothing to show). If anyone actually DIED, this
    -- was a match, however short, and it takes the REAL exit: ENDED runs
    -- placements, the verdict, the roster sweep and the trip home. The
    -- first version aborted a solo's mid-bus death to WAITING, skipping
    -- all of that -- lobby menu over a corpse in Los Santos.
    if (S.state == BR.MatchState.WARMUP or S.state == BR.MatchState.BUS)
       and BR.Server.aliveCount() == 0 then
        local anyDead = BR.Server.count(function(p)
            return p.state == BR.PlayerState.DEAD
        end) > 0
        if anyDead then
            print('[br_core] match: everyone is down -- ending')
            BR.Match.transition(BR.MatchState.ENDED)
        else
            print('[br_core] match: everyone left -- aborting back to WAITING')
            BR.Match.transition(BR.MatchState.WAITING)
        end
        return
    end

    if S.state == BR.MatchState.BUS then
        -- The drop ends when the LAST player is down -- not when the route
        -- timer says so. Everyone jumped early and landed? The match goes
        -- live now instead of waiting out an empty flight. The endsAt timer
        -- below stays as the CEILING: a client that crashes mid-fall never
        -- reports a landing, and one ghost must not hold 47 players in the
        -- pre-match state forever.
        local airborne = BR.Server.count(function(p)
            return p.state == BR.PlayerState.BUS
                or p.state == BR.PlayerState.FREEFALL
                or p.state == BR.PlayerState.GLIDE
        end)
        if airborne == 0 and BR.Server.aliveCount() > 0 then
            print('[br_core] match: last player down -- going live')
            BR.Match.transition(BR.MatchState.PLAYING)
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
        S.descent = S.descent or { extended = 0, z = {}, falling = {} }
        BR.Roster.each(
            function(e)
                return e.state == BR.PlayerState.BUS
                    or e.state == BR.PlayerState.FREEFALL
                    or e.state == BR.PlayerState.GLIDE
            end,
            function(src, e)
                if e.pos and (now - (e.posAt or 0)) < 3000 then
                    local last = S.descent.z[src]
                    S.descent.falling[src] =
                        (last ~= nil and e.pos.z < last - 1.0) or nil
                    S.descent.z[src] = e.pos.z
                else
                    S.descent.falling[src] = nil
                end
            end)

        if S.endsAt > 0 and now >= S.endsAt and airborne > 0
           and S.descent.extended < 120000 then
            local descending = false
            for _, v in pairs(S.descent.falling) do
                if v then descending = true break end
            end
            if descending then
                S.descent.extended = S.descent.extended + 10000
                S.endsAt = S.endsAt + 10000
                BR.Broadcast.state(S.state, S.endsAt, { reason = 'descent' })
                print('[br_core] match: someone is still descending -- holding BUS 10s more')
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
    if S.state == BR.MatchState.PLAYING or S.state == BR.MatchState.BUS then
        S.landCheck = S.landCheck or { z = {}, still = {} }
        BR.Roster.each(
            function(e)
                return e.state == BR.PlayerState.FREEFALL
                    or e.state == BR.PlayerState.GLIDE
            end,
            function(src, e)
                if e.pos and (now - (e.posAt or 0)) < 3000 then
                    local last = S.landCheck.z[src]
                    if last and math.abs(e.pos.z - last) < 1.0 then
                        S.landCheck.still[src] = (S.landCheck.still[src] or 0) + 1
                        if S.landCheck.still[src] >= 20 then   -- ~5s at the 250ms tick
                            print(('[br_core] %s (%d) has been at constant altitude 5s -- promoting to ALIVE')
                                :format(e.name, src))
                            BR.Roster.setState(src, BR.PlayerState.ALIVE)
                            S.landCheck.still[src] = nil
                        end
                    else
                        S.landCheck.still[src] = 0
                    end
                    S.landCheck.z[src] = e.pos.z
                end
            end)
    end

    if winConditionMet() then
        BR.Match.transition(BR.MatchState.ENDED)
        return
    end

    -- A timed state whose time is up moves to whatever comes next.
    if S.endsAt > 0 and now >= S.endsAt then
        if S.state == BR.MatchState.WARMUP then
            -- Participants still standing on the pad, not the connected count:
            -- the queue was cleared when warmup began, and a lobby idler who
            -- never readied up must not pad the number that decides whether
            -- this match is worth flying.
            if BR.Server.aliveCount() < M.MinPlayers(BR.Server.devMode) then
                print('[br_core] match: not enough players, returning to WAITING')
                BR.Match.transition(BR.MatchState.WAITING)
            else
                -- No duration passed: onEnter(BUS) plans the route and sets
                -- the deadline from it.
                BR.Match.transition(BR.MatchState.BUS)
            end
        elseif S.state == BR.MatchState.BUS then
            BR.Match.transition(BR.MatchState.PLAYING)
        elseif S.state == BR.MatchState.ENDED then
            BR.Match.transition(BR.MatchState.CLEANUP)
        elseif S.state == BR.MatchState.CLEANUP then
            BR.Match.transition(BR.MatchState.WAITING)
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
        return   -- nothing to leave
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
    TriggerClientEvent(BR.Net.TO_LOBBY, src)
    BR.Server.notify(src, 'You left the match.', 'info')

    print(('[br_core] %s (%d) left the match'):format(entry.name, src))
end

RegisterNetEvent(BR.Net.MATCH_LEAVE)
AddEventHandler(BR.Net.MATCH_LEAVE, function()
    BR.Match.leaveMatch(source)
end)

-- --------------------------------------------------------------------------
-- Admin
-- --------------------------------------------------------------------------

RegisterCommand('brforce', function(_, args)
    local target = args[1]
    if not target then
        print(('  usage: brforce <state>   current: %s'):format(S.state))
        print('  states: waiting warmup bus playing ended cleanup')
        return
    end

    for _, v in pairs(BR.MatchState) do
        if v == target then
            print(('[br_core] admin forced %s -> %s'):format(S.state, v))
            BR.Match.transition(v)
            return
        end
    end
    print(('  unknown state: %s'):format(target))
end, true)

RegisterCommand('brskip', function()
    -- Ends the current timed state immediately, without caring which it is.
    if S.endsAt > 0 then
        S.endsAt = GetGameTimer()
        print('[br_core] admin skipped to the end of the current state')
    else
        print(('  %s has no timer to skip'):format(S.state))
    end
end, true)
