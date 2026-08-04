-- The storm, server half: the authority.
--
-- The server publishes ONE record per phase (BR.BuildStormRecord) and both
-- sides solve the circle locally from it against the synced clock -- the same
-- pattern as the bus. Nothing per-frame ever crosses the wire.
--
-- AUTHORITY, stated plainly. The server cannot write a ped's health, so the
-- visible hurt is applied client-side on instruction (STORM_DAMAGE). But the
-- server keeps its own ledger of what the storm SHOULD have done to each
-- player and eliminates from the LEDGER -- so a client that ignores the
-- instruction keeps its health bar and dies at exactly the same moment as an
-- honest one. That is what makes the M4 authority drill pass: disable every
-- client storm callback and the elimination still lands on time.
--
-- Storm damage is deliberately NOT routed through combat validation: it has no
-- attacker, no weapon and no hit position. It is the server hurting a player,
-- not a player claiming to have hurt one.

BR = BR or {}
BR.Storm = {}

local S   = BR.Server
local cfg = BR.Config.Storm

local rng   = nil     -- per-match; seeded at begin()
local carry = {}      -- [src] = fractional ENGINE damage not yet whole enough to send

-- Dev tuning: every subsequently built phase gets its wait/shrink multiplied
-- by this. 0.1 turns the 20-minute cycle into 2 for testing. Records already
-- published keep their stamped times -- brphase re-enters if you want it now.
local timeScale = 1.0

local function publish()
    TriggerClientEvent(BR.Net.STORM_SYNC, -1, S.storm)
end

--- Build and publish the record that shrinks toward phases[phase], starting
--- from the given circle. The next centre is drawn HERE, at phase entry, so
--- players see where to rotate for the whole hold.
---
--- THE WALL'S TRAVEL TIME IS PRICED HERE TOO, every phase (user call,
--- 2026-08-04): the furthest in-match player's run to the TARGET circle's
--- edge, at shrinkPace speed, floored at minSeconds and ceilinged by the
--- authored value. Everyone already inside the target? The sweep is quick
--- and the game moves on. A straggler two kilometres out? They get their
--- run. This replaced phase 1's hold-payback scheme -- pricing the shrink
--- directly is the same fairness without the bookkeeping.
--- @param phase integer  1-based index into cfg.phases
--- @param cx0 number     circle being held / shrunk from
--- @param cy0 number
--- @param r0 number
--- @param now number
--- @param waitSec number|nil  override the authored wait (the dynamic hold)
local function enterPhase(phase, cx0, cy0, r0, now, waitSec)
    local p = cfg.phases[phase]

    -- The FINAL phases hug the rim: the next centre sits within edgeHugM of
    -- the current circle's circumference, so endgames resolve as a run to a
    -- place rather than a shuffle in the middle. Earlier phases roam the
    -- whole containment slack (edgeBiasMax 1.0).
    local minDist = 0.0
    if phase > #cfg.phases - (cfg.edgeHugPhases or 0) then
        minDist = math.max(0.0, (r0 - p.radius) - (cfg.edgeHugM or 0.0))
    end
    local cx1, cy1 = BR.NextStormCentre(rng, cx0, cy0, r0, p.radius,
        cfg.edgeBiasMax, cfg.mapAABB, minDist)

    -- Price the sweep for the furthest player's run to the target's edge.
    local furthest = 0.0
    BR.Roster.each(
        function(e) return BR.Server.isInMatch(e.state) end,
        function(_, e)
            if e.pos then
                local d = BR.Dist(e.pos.x, e.pos.y, cx1, cy1) - p.radius
                if d > furthest then furthest = d end
            end
        end)
    local shrinkSec = BR.Clamp(furthest / cfg.shrinkPace.metersPerSec,
        cfg.shrinkPace.minSeconds, p.shrink)

    S.storm = BR.BuildStormRecord(phase, cx0, cy0, r0, cx1, cy1, p.radius,
        now, (waitSec or p.wait) * 1000 * timeScale,
        shrinkSec * 1000 * timeScale, p.dps)

    print(('[br_core] storm: phase %d -- r %.0f -> %.0f, holds %.0fs, shrinks %.0fs (furthest %.0fm), %.1f dps')
        :format(phase, r0, p.radius,
                S.storm.tWait / 1000, S.storm.tShrink / 1000, furthest, p.dps))
    publish()
end

--- The opening circle covers the WHOLE playable map: distance from the anchor
--- to the farthest bounds corner, floored at radius0. Nobody can land outside
--- circle 1, so "I spawned already dying" is structurally impossible -- the
--- first shrink is what brings the map in toward the anchor.
--- @param ax number
--- @param ay number
--- @return number
local function openingRadius(ax, ay)
    local A = cfg.mapAABB
    local r = cfg.radius0
    r = math.max(r, BR.Dist(ax, ay, A.min.x, A.min.y))
    r = math.max(r, BR.Dist(ax, ay, A.min.x, A.max.y))
    r = math.max(r, BR.Dist(ax, ay, A.max.x, A.min.y))
    r = math.max(r, BR.Dist(ax, ay, A.max.x, A.max.y))
    return r + (cfg.openMargin or 200.0)
end

--- Start the storm. Called when the match goes PLAYING: the clock starts at
--- the last landing and the first circle is on the map immediately (user
--- call, 2026-08-02) -- the free-loot time is phase 1's 120s wait, not a
--- separate pre-phase.
function BR.Storm.begin()
    local a = S.matchAnchor
    if not a then
        -- brforce playing from WAITING skips warmup, so no route -- and no
        -- anchor -- was ever drawn. Any POI beats no storm.
        local poi = BR.Rng(GetGameTimer()):pick(BR.Config.Map.POIs)
        a = { x = poi.x, y = poi.y, name = poi.name, poi = poi.id }
        S.matchAnchor = a
    end

    -- Seeded per match. matchId keeps two matches started in the same server
    -- millisecond (tests do this constantly) from replaying each other.
    rng   = BR.Rng(GetGameTimer() + BR.Server.matchId * 7919)
    carry = {}

    -- The free-loot hold is priced for the FURTHEST player's run to the
    -- FIRST TARGET CIRCLE -- distance to its edge, not to the anchor point.
    -- Pricing to the anchor charged a player already standing inside the
    -- phase-1 circle for the full radius they never had to cross ("everyone
    -- is in the circle, why is the timer four minutes?"). Anyone inside the
    -- target pays nothing; only the overshoot beyond its edge buys time.
    -- LOBBY bystanders are not participants and never lengthen the hold.
    local furthest = 0.0
    BR.Roster.each(
        function(e) return BR.Server.isInMatch(e.state) end,
        function(_, e)
            if e.pos then
                local d = BR.Dist(e.pos.x, e.pos.y, a.x, a.y)
                    - cfg.phases[1].radius
                if d > furthest then furthest = d end
            end
        end)
    local holdSec = BR.Clamp(furthest / cfg.hold.metersPerSec,
        cfg.phases[1].wait, cfg.hold.maxSeconds)

    -- THE WALL MOVES WITHIN THREE MINUTES, whatever the drop spread priced:
    -- the stationary wait caps at startCapSeconds. The old payback (trimmed
    -- hold seconds added to the shrink) is gone -- enterPhase now prices
    -- every phase's shrink for the furthest player's actual run, which is
    -- the same fairness measured directly.
    local waitSec = math.min(holdSec, cfg.hold.startCapSeconds or holdSec)

    local r0 = openingRadius(a.x, a.y)
    print(('[br_core] storm: homing on %s (%.0f, %.0f) -- opening r %.0f, hold %.0fs (furthest %.0fm)')
        :format(tostring(a.name), a.x, a.y, r0, waitSec, furthest))
    enterPhase(1, a.x, a.y, r0, GetGameTimer(), waitSec)
end

--- Which player states the storm can hurt. Airborne players are untouchable
--- -- they cannot steer out of a wall they are falling through, and the drop
--- grace exists for the same reason -- and lobby/warmup are not in the match.
local DAMAGEABLE = {
    [BR.PlayerState.ALIVE] = true,
    [BR.PlayerState.DBNO]  = true,
}

-- Phase advancement. 1 Hz is plenty: a phase is minutes long, and the solver
-- is what answers "where is the wall NOW" -- this job only notices a finished
-- shrink and authors the next record.
BR.Sched.every(1000, 'storm.phase', function()
    if S.match.state ~= BR.MatchState.PLAYING or not S.storm then return end

    local rec = S.storm
    local _, _, _, st = BR.StormAt(rec, GetGameTimer())
    if st == BR.StormPhase.FINISHED and rec.phase < #cfg.phases then
        enterPhase(rec.phase + 1, rec.cx1, rec.cy1, rec.r1, GetGameTimer())
    end
    -- The final phase just stays FINISHED at radius 0: everyone still outside
    -- (which is everywhere) keeps taking the last phase's dps until the win
    -- condition ends the match.
end)

-- Damage. Positions come from the roster's own server-side sampling -- never
-- from anything a client reported -- so a position-lying client gains nothing
-- here.
BR.Sched.every(1000, 'storm.damage', function(dt)
    if S.match.state ~= BR.MatchState.PLAYING or not S.storm then return end

    local now = GetGameTimer()
    local rec = S.storm
    local cx, cy, r, st, _, dps = BR.StormAt(rec, now)
    if dps <= 0 then return end

    -- THE EDGE CUSHION. During a shrink the wall moves METRES PER SECOND
    -- (phase 1 sweeps >150 m/s), and three clocks disagree at the knife
    -- edge: this tick, the half-second-old position sample, and the
    -- client's own view of the circle. Damage therefore starts a margin
    -- OUTSIDE the solved radius -- a base allowance plus ~0.7s of wall
    -- travel -- so a player standing at the visible curtain is always
    -- genuinely safe (live reports: hurt while 20-50ft inside the wall).
    local margin = 10.0
    if st == BR.StormPhase.SHRINKING then
        margin = margin
            + ((rec.r0 - rec.r1) / math.max(rec.tShrink / 1000.0, 1.0)) * 0.7
    end

    -- Capped so a long scheduler stall (or a test jumping the clock) cannot
    -- land one apocalyptic tick.
    local dtSec = math.min((dt and dt > 0) and (dt / 1000.0) or 1.0, 3.0)

    BR.Roster.each(
        function(e) return DAMAGEABLE[e.state] end,
        function(src, e)
            if not e.pos then return end   -- not sampled yet (OneSync warning covers why)

            if BR.Dist(e.pos.x, e.pos.y, cx, cy) <= r + margin then
                -- Inside: the ledger re-seeds from sampled reality next time
                -- they are caught out.
                e.stormHp  = nil
                carry[src] = nil
                return
            end

            -- THE LEDGER. Seeded from the sampled display hp, then decremented
            -- server-side every tick they spend outside. min() with the sample
            -- keeps it honest when the player is ALSO being shot: the ledger
            -- may never lag above reality, only refuse to be lied upward.
            -- (M6's reconciliation sweep replaces this with the full model.)
            local display = e.stormHp or e.hp or 100.0
            if e.hp and e.hp < display then display = e.hp end
            display = display - dps * dtSec
            e.stormHp     = display
            e.lastStormAt = now

            -- The visible half: tell the client to hurt its ped. Engine units,
            -- whole numbers, fraction carried forward so 1 dps rounds to two
            -- engine points per second instead of to nothing.
            local engine = BR.ToEngineHpDelta(dps * dtSec) + (carry[src] or 0.0)
            local whole  = math.floor(engine)
            carry[src]   = engine - whole
            if whole > 0 then
                TriggerClientEvent(BR.Net.STORM_DAMAGE, src, {
                    amount      = whole,
                    armourFirst = cfg.damageArmourFirst and true or false,
                })
            end

            -- Elimination comes from the LEDGER, not the ped. An honest
            -- client's ped dies at the same moment anyway; a deaf one dies
            -- here regardless.
            if display <= 0 then
                print(('[br_core] storm: ledger kill on %s (%d)')
                    :format(e.name, src))
                BR.Combat.eliminate(src, 'storm', nil)
            end
        end)
end)

-- ---------------------------------------------------------------- admin ---

RegisterCommand('brphase', function(_, args)
    local n = tonumber(args[1])
    if not n or not cfg.phases[n] then
        print(('  usage: brphase <1-%d>   current: %s'):format(#cfg.phases,
            S.storm and tostring(S.storm.phase) or 'no storm'))
        return
    end
    if S.match.state ~= BR.MatchState.PLAYING then
        print('  the storm only runs during PLAYING (brforce playing first)')
        return
    end
    if not S.storm then BR.Storm.begin() end

    -- Enter phase n from wherever the wall is RIGHT NOW, so the jump is
    -- seamless on every client.
    local cx, cy, r = BR.StormAt(S.storm, GetGameTimer())
    print(('[br_core] admin: storm jumped to phase %d'):format(n))
    enterPhase(n, cx, cy, r, GetGameTimer())
end, true)

RegisterCommand('brstormscale', function(_, args)
    local m = tonumber(args[1])
    if not m then
        print(('  usage: brstormscale <0.05-1.0>   current: %.2f'):format(timeScale))
        print('  scales wait/shrink of every phase built AFTER this; brphase to apply now')
        return
    end
    timeScale = BR.Clamp(m, 0.05, 1.0)
    print(('[br_core] storm time scale = %.2f (~%.0f min cycle)')
        :format(timeScale, cfg.TotalSeconds() * timeScale / 60.0))
end, true)

RegisterCommand('brstorm', function()
    if not S.storm then
        print('  no storm record (storm starts when the match goes PLAYING)')
        return
    end
    local rec = S.storm
    local cx, cy, r, st, msLeft, dps = BR.StormAt(rec, GetGameTimer())
    print(('  phase %d/%d  %s  %.0fs left in sub-phase'):format(
        rec.phase, #cfg.phases, st, msLeft / 1000))
    print(('  circle  %.0f, %.0f  r %.0f'):format(cx, cy, r))
    print(('  next    %.0f, %.0f  r %.0f'):format(rec.cx1, rec.cy1, rec.r1))
    print(('  dps %.1f  timeScale %.2f'):format(dps, timeScale))

    local outside = 0
    BR.Roster.each(
        function(e) return DAMAGEABLE[e.state] end,
        function(_, e)
            if e.pos and BR.Dist(e.pos.x, e.pos.y, cx, cy) > r then
                outside = outside + 1
            end
        end)
    print(('  %d damageable player(s) outside'):format(outside))
end, true)
