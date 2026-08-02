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
        BR.Roster.each(nil, function(src)
            BR.Roster.setState(src, BR.PlayerState.WARMUP)
        end)
        -- Squads are formed once, here, from the parties that exist at the
        -- moment the match starts. Forming them earlier would go stale as
        -- people join and leave parties in the lobby.
        BR.Party.formSquads(S.mode)

    elseif state == BR.MatchState.BUS then
        BR.Server.matchId = BR.Server.matchId + 1
        BR.Roster.each(
            function(e) return e.state == BR.PlayerState.WARMUP end,
            function(src) BR.Roster.setState(src, BR.PlayerState.BUS) end)

    elseif state == BR.MatchState.PLAYING then
        -- Everyone not already out becomes ALIVE -- not just those on the bus.
        --
        -- Matching only BUS meant `brforce playing`, which skips the bus
        -- entirely, promoted nobody: every player stayed in lobby/warmup, which
        -- do not count as alive, so squadsAlive() was 0 and the win condition
        -- fired on the very next tick. The match ended the instant it started.
        --
        -- M3 replaces this: players become ALIVE when they LAND, not when the
        -- match starts.
        BR.Roster.each(
            function(e)
                return e.state ~= BR.PlayerState.DEAD
                   and e.state ~= BR.PlayerState.LEFT
                   and e.state ~= BR.PlayerState.SPECTATING
            end,
            function(src) BR.Roster.setState(src, BR.PlayerState.ALIVE) end)

        -- Nothing can win in the first moments of a match. Without this, any
        -- path that reaches PLAYING with states still settling ends instantly,
        -- and the log reads as though a match was played and won in one tick.
        S.startedAt = GetGameTimer()

    elseif state == BR.MatchState.ENDED then
        BR.Match.awardPlacements()

    elseif state == BR.MatchState.CLEANUP then
        BR.Match.reset()

    elseif state == BR.MatchState.WAITING and from == BR.MatchState.CLEANUP then
        BR.Broadcast.snapshot()   -- re-seed everyone for the next match
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
            return e.state == BR.PlayerState.ALIVE or e.state == BR.PlayerState.DBNO
        end,
        function(src, e) living[#living + 1] = { src = src, e = e } end)

    for _, p in ipairs(living) do
        p.e.placement = 1
        BR.Broadcast.delta({ op = 'update', src = p.src, e = { placement = 1 } })
    end

    if #living > 0 then
        local names = {}
        for _, p in ipairs(living) do names[#names + 1] = p.e.name end
        local who = table.concat(names, ', ')
        print(('[br_core] match %d won by %s'):format(BR.Server.matchId, who))
        BR.Server.systemMessage(('Victory Royale: %s'):format(who))
    else
        print(('[br_core] match %d ended with no survivors'):format(BR.Server.matchId))
        BR.Server.systemMessage('Match over -- no survivors.')
    end
end

--- Clear per-match state, ready for the next one.
function BR.Match.reset()
    BR.Server.storm = nil
    BR.Roster.each(nil, function(src, e)
        e.kills, e.downs, e.revives, e.damage = 0, 0, 0, 0.0
        e.placement, e.lastDamageBy, e.lastDamageAt = nil, nil, 0
        e.hp, e.armour = 100.0, 0.0
        BR.Roster.setState(src, BR.PlayerState.LOBBY)
    end)
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
        if BR.Lobby.count() >= BR.Lobby.needed() then
            -- Consume the queue BEFORE transitioning. If anything in the
            -- transition throws, the queue must still be spent -- otherwise the
            -- next tick sees a full queue and tries to start the match again,
            -- every tick, forever.
            S.mode = BR.Lobby.dominantMode()
            BR.Lobby.clear()
            BR.Match.transition(BR.MatchState.WARMUP)
        end
        return
    end

    if winConditionMet() then
        BR.Match.transition(BR.MatchState.ENDED)
        return
    end

    -- A timed state whose time is up moves to whatever comes next.
    if S.endsAt > 0 and now >= S.endsAt then
        if S.state == BR.MatchState.WARMUP then
            -- Connected count here, not queued: the queue was cleared when
            -- warmup began, and what matters now is whether enough people are
            -- still actually present to make a match of it.
            if BR.Server.count() < M.MinPlayers(BR.Server.devMode) then
                print('[br_core] match: not enough players, returning to WAITING')
                BR.Match.transition(BR.MatchState.WAITING)
            else
                BR.Match.transition(BR.MatchState.BUS, 30)
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
