-- The storm, server half: the authority -- ONE PER MATCH INSTANCE.
--
-- The server publishes ONE record per phase (BR.BuildStormRecord) and both
-- sides solve the circle locally from it against the synced clock -- the same
-- pattern as the bus. Nothing per-frame ever crosses the wire. The record,
-- the rng and the damage-carry bookkeeping all live on the match instance
-- (m.storm / m.stormRng / m.stormCarry): two concurrent matches run two
-- independent storms, each published only to its own audience.
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

local cfg = BR.Config.Storm

-- Dev tuning: every subsequently built phase gets its wait/shrink multiplied
-- by this. 0.1 turns the 20-minute cycle into 2 for testing. Records already
-- published keep their stamped times -- brphase re-enters if you want it now.
-- Deliberately global across matches: it is a dev knob, not match state.
local timeScale = 1.0

local function publish(m)
    BR.Broadcast.toMatch(m, BR.Net.STORM_SYNC, m.storm)
end

-- ═══ THE SOUND THE WALL MAKES WHEN IT STARTS MOVING ═══
--
--   "We also need a sound for when the storm starts moving"
--                                          -- owner, 2026-08-22
--
-- WHICH MOMENT THAT IS. A phase has two halves. `enterPhase` is when the next
-- circle is DRAWN and the wall STOPS -- the hold. The wall starts moving at the
-- other end of that hold, when BR.StormAt stops answering HOLDING and starts
-- answering SHRINKING. That edge is what this cues, and it is cued eight times
-- a match rather than once.
--
-- ═══ WHY THE SERVER OWNS THE EDGE AND NOT THE CLIENT ═══
--
-- Every client already solves the wall for itself -- that is the whole design,
-- and it means every client COULD notice this boundary on its own. It must not:
-- that is eight latches in eight frame loops, each drifting by a frame, each
-- needing its own "have I already played this" state, and each getting it wrong
-- for a player who joined or respawned mid-phase. The server runs one 1 Hz job
-- that is already looking at exactly this record, so the edge is detected once,
-- in one place, and ADDRESSED to the match. "Everyone hears it once" then
-- follows from the fan-out rather than from eight clients agreeing.
--
-- UP TO ONE SECOND LATE, AND THAT IS FINE. The job ticks at 1 Hz, so the cue
-- can trail the true boundary by up to a second. A shrink runs 40 to 360
-- seconds and the wall is a kilometre wide; nobody can perceive the offset, and
-- paying for exactness would mean putting this in a frame loop.
local MOVE_CUE = 'storm.move'

--- Tell a whole match the wall has begun to move -- at most once per phase.
---
--- THE LATCH IS ON THE MATCH, NOT ON THE PHASE NUMBER, and that difference is
--- real: `brphase` and `brstormfreeze off` both RE-ENTER a phase from wherever
--- the wall is standing, which gives it a fresh hold and a fresh sweep. Keyed on
--- the number, a thaw would hold its peace while the wall visibly set off again.
--- `enterPhase` clears it, so every entry -- first, forced or thawed -- arms it.
---
--- FINISHED COUNTS AS MOVED. The state to watch is SHRINKING, but a scheduler
--- stall long enough to skip every tick of a sweep would step straight from
--- HOLDING to FINISHED and the cue would be lost with nothing to say so. A wall
--- that has finished moving has moved, so the latch trips either way.
--- @param m table
local function cueMovementOnce(m, st)
    if m.stormMoveCued then return end
    if st ~= BR.StormPhase.SHRINKING and st ~= BR.StormPhase.FINISHED then return end
    m.stormMoveCued = true
    -- A CUE KEY, NEVER A SOUND NAME. The wire carries `storm.move` and the
    -- client resolves it against its own BR.Config.Audio.cues, which is what
    -- lets the owner re-point it with /brsfx bind without a line of this file
    -- changing. See br_lib/shared/protocol.lua's SFX_CUE.
    BR.Broadcast.toMatch(m, BR.Net.SFX_CUE, { c = MOVE_CUE })
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
--- @param m table         the match instance
--- @param phase integer   1-based index into cfg.phases
--- @param cx0 number      circle being held / shrunk from
--- @param cy0 number
--- @param r0 number
--- @param now number
--- @param waitSec number|nil  override the authored wait (the dynamic hold)
local function enterPhase(m, phase, cx0, cy0, r0, now, waitSec)
    local p = cfg.phases[phase]

    -- The FINAL phases hug the rim: the next centre sits within edgeHugM of
    -- the current circle's circumference, so endgames resolve as a run to a
    -- place rather than a shuffle in the middle. Earlier phases roam the
    -- whole containment slack (edgeBiasMax 1.0).
    local minDist = 0.0
    if phase > #cfg.phases - (cfg.edgeHugPhases or 0) then
        minDist = math.max(0.0, (r0 - p.radius) - (cfg.edgeHugM or 0.0))
    end
    -- The breakout budget rides along: it lets this phase's circle leave the
    -- current one, and the sweep pricing immediately below is what keeps that
    -- fair -- the furthest player's run to the TARGET's edge sets the wall's
    -- travel time, so a circle that moved further simply takes longer to close.
    local cx1, cy1, brokeOut = BR.NextStormCentre(m.stormRng, cx0, cy0, r0,
        p.radius, cfg.edgeBiasMax, cfg.mapAABB, minDist,
        BR.StormBreakoutFor(cfg, phase))

    -- Price the sweep for the furthest player's run to the target's edge --
    -- THIS match's players only.
    local furthest = 0.0
    BR.Roster.each(
        function(e) return e.matchId == m.id and BR.Server.isInMatch(e.state) end,
        function(_, e)
            if e.pos then
                local d = BR.Dist(e.pos.x, e.pos.y, cx1, cy1) - p.radius
                if d > furthest then furthest = d end
            end
        end)
    -- A BREAKOUT BUYS A LONGER SWEEP.
    --
    -- The authored per-phase `shrink` is the ceiling on travel time, and it was
    -- written for NESTED circles -- where the furthest anyone can be from the
    -- next circle's edge is about one radius. A circle that has separated from
    -- its predecessor can be three times that away, and at 9 m/s the wall
    -- would simply outrun everyone: the rotation the breakout is meant to
    -- force becomes a cull instead. So the ceiling is lifted for exactly the
    -- phases that broke out, and the pricing below still decides how much of
    -- it is actually used -- if everybody happens to be near the new circle,
    -- the sweep is short regardless.
    local ceiling = p.shrink
    if brokeOut then
        ceiling = p.shrink * ((cfg.breakout and cfg.breakout.shrinkFactor) or 1.0)
    end
    local shrinkSec = BR.Clamp(furthest / cfg.shrinkPace.metersPerSec,
        cfg.shrinkPace.minSeconds, ceiling)

    m.storm = BR.BuildStormRecord(phase, cx0, cy0, r0, cx1, cy1, p.radius,
        now, (waitSec or p.wait) * 1000 * timeScale,
        shrinkSec * 1000 * timeScale, p.dps)

    -- ARMED FOR THIS PHASE'S SWEEP. Every route into a phase comes through
    -- here -- the first one, the next one, `brphase`, and the thaw -- so this
    -- one line is what makes "once per hold-to-shrink transition" true for all
    -- four of them rather than for the ordinary one only.
    m.stormMoveCued = false

    print(('[br_core] storm: match %d phase %d -- r %.0f -> %.0f, holds %.0fs, shrinks %.0fs (furthest %.0fm), %.1f dps')
        :format(m.id, phase, r0, p.radius,
                m.storm.tWait / 1000, m.storm.tShrink / 1000, furthest, p.dps))
    publish(m)
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

--- Start a match's storm. Called when it goes PLAYING: the clock starts at
--- the last landing and the first circle is on the map immediately (user
--- call, 2026-08-02) -- the free-loot time is phase 1's 120s wait, not a
--- separate pre-phase.
--- @param m table
function BR.Storm.begin(m)
    local a = m.anchor
    if not a then
        -- brforce playing from nothing skips warmup, so no route -- and no
        -- anchor -- was ever drawn. Any POI beats no storm.
        local poi = BR.Rng(GetGameTimer()):pick(BR.Config.Map.POIs)
        a = { x = poi.x, y = poi.y, name = poi.name, poi = poi.id }
        m.anchor = a
    end

    -- Seeded per match. The id keeps two matches started in the same server
    -- millisecond (tests do this constantly) from replaying each other.
    m.stormRng   = BR.Rng(GetGameTimer() + m.id * 7919)
    m.stormCarry = {}

    -- The free-loot hold is priced for the FURTHEST player's run to the
    -- FIRST TARGET CIRCLE -- distance to its edge, not to the anchor point.
    -- Pricing to the anchor charged a player already standing inside the
    -- phase-1 circle for the full radius they never had to cross ("everyone
    -- is in the circle, why is the timer four minutes?"). Anyone inside the
    -- target pays nothing; only the overshoot beyond its edge buys time.
    -- LOBBY bystanders are not participants and never lengthen the hold.
    local furthest = 0.0
    BR.Roster.each(
        function(e) return e.matchId == m.id and BR.Server.isInMatch(e.state) end,
        function(_, e)
            if e.pos then
                local d = BR.Dist(e.pos.x, e.pos.y, a.x, a.y)
                    - cfg.phases[1].radius
                if d > furthest then furthest = d end
            end
        end)
    -- Floor at hold.minSeconds, NOT phases[1].wait: an all-inside drop
    -- waits one minute, not two (user call, 2026-08-04 -- "why does it
    -- take 3 minutes for the storm to form?"). The authored wait remains
    -- the schedule for LATER phases.
    local holdSec = BR.Clamp(furthest / cfg.hold.metersPerSec,
        cfg.hold.minSeconds or cfg.phases[1].wait, cfg.hold.maxSeconds)

    -- THE WALL MOVES WITHIN THREE MINUTES, whatever the drop spread priced:
    -- the stationary wait caps at startCapSeconds. The old payback (trimmed
    -- hold seconds added to the shrink) is gone -- enterPhase now prices
    -- every phase's shrink for the furthest player's actual run, which is
    -- the same fairness measured directly.
    local waitSec = math.min(holdSec, cfg.hold.startCapSeconds or holdSec)

    local r0 = openingRadius(a.x, a.y)
    print(('[br_core] storm: match %d homing on %s (%.0f, %.0f) -- opening r %.0f, hold %.0fs (furthest %.0fm)')
        :format(m.id, tostring(a.name), a.x, a.y, r0, waitSec, furthest))
    enterPhase(m, 1, a.x, a.y, r0, GetGameTimer(), waitSec)

    -- A MATCH STARTED UNDER A FREEZE INHERITS IT. Without this, freezing the
    -- storm and then starting a fresh match quietly gives you a live one --
    -- which is the failure you would not notice until the wall was on top of
    -- you, an hour into whatever you were actually testing.
    if BR.Storm.isFrozen and BR.Storm.isFrozen() then
        local now = GetGameTimer()
        m.storm = BR.BuildStormRecord(1, a.x, a.y, r0, a.x, a.y, r0,
            now, 24 * 60 * 60 * 1000, 1000, 0.0)
        publish(m)
        print(('[br_core] storm: match %d starts FROZEN (brstormfreeze is on)')
            :format(m.id))
    end
end

--- Which player states the storm can hurt. Airborne players are untouchable
--- -- they cannot steer out of a wall they are falling through, and the drop
--- grace exists for the same reason -- and lobby/warmup are not in the match.
---
--- ═══ A VEHICLE IS NOT ON THIS LIST AND NEVER WILL BE (owner, 2026-08-21, #194
---     question 4) ═══
---
---   "no, vehicles will never grant storm immunity. that's not a thing. the
---    only exception is the ambulance and ONLY while they're in `rescue` state
---    - so if they hop in an ambulance and drive off they are not granted any
---    sort of immunity."
---
--- WHICH IS WHAT THIS FILE ALREADY DOES, and #194 §4 established that before the
--- question was asked: the damage loop below is a position check against the
--- solved circle and a server-side ledger. It holds no ped handle and no vehicle
--- handle, so a player driving through the wall takes exactly what a player
--- walking through it takes. Nothing was added to keep it that way. The test in
--- tools/test_roster.lua's `storm.vehicles` block is what stops it drifting,
--- because "we never wrote the exemption" is not a property anything can check.
---
--- ═══ THE ONE EXCEPTION, NOW THAT #191 HAS LANDED ═══
---
--- This block used to say the exemption could not be written yet, because it was
--- conditioned on a `rescue` state that existed nowhere -- and a flag with no
--- writer is a flag that reads false forever while looking like a working
--- feature. #191 (the CPR kit) built the writer, so the sentence is code now:
--- `and not e.rescue` on the `BR.Roster.each` filter in `storm.damage` below,
--- which is exactly the one-condition change this block specified in advance.
---
--- THE TWO PROHIBITIONS IT WAS WRITTEN WITH ARE BOTH HONOURED, and they are
--- restated rather than deleted because they are what makes the flag safe:
---
---   * NOT A CLIENT-ASSERTED FLAG. Storm damage is the subsystem specifically
---     built so a client cannot influence it (#194 §4); an exemption a client can
---     assert is storm immunity a client can assert. `e.rescue` is written in
---     exactly two places, both in server/rescue.lua -- when the server GRANTS a
---     rescue and when it ENDS one -- and no net event sets it. There is no
---     client->server event in this whole feature that carries a payload at all.
---   * NOT A TEST ON THE VEHICLE. The owner's rule is about the rescue, not about
---     the ambulance -- a player who drives one off has no exemption, so a model
---     check would grant exactly the thing that sentence refuses. Nothing below
---     reads a model, a vehicle handle or a seat; the flag is on the PLAYER, and
---     it is set only for a player the server itself put in an ambulance.
---
--- AND IT IS BOUNDED. server/rescue.lua's deadline is checked unconditionally on
--- every tick and every path out of a rescue clears the flag, so there is no
--- branch on which a player stays exempt -- which matters more here than
--- anywhere else, because the failure would be silent and would look exactly
--- like a player who is simply good at staying inside the circle.
local DAMAGEABLE = {
    [BR.PlayerState.ALIVE] = true,
    [BR.PlayerState.DBNO]  = true,
}

-- Phase advancement. 1 Hz is plenty: a phase is minutes long, and the solver
-- is what answers "where is the wall NOW" -- this job only notices a finished
-- shrink and authors the next record.
BR.Sched.every(1000, 'storm.phase', function()
    BR.Server.eachMatch(function(m)
        if m.state ~= BR.MatchState.PLAYING or not m.storm then return end

        local rec = m.storm
        local _, _, _, st = BR.StormAt(rec, GetGameTimer())

        -- BEFORE the advance, not after. The advance replaces `m.storm` with a
        -- record that is HOLDING again, so a cue evaluated afterwards would be
        -- reading the NEXT phase's hold and would never fire at all.
        cueMovementOnce(m, st)

        if st == BR.StormPhase.FINISHED and rec.phase < #cfg.phases then
            enterPhase(m, rec.phase + 1, rec.cx1, rec.cy1, rec.r1, GetGameTimer())
        end
        -- The final phase just stays FINISHED at radius 0: everyone still
        -- outside (which is everywhere) keeps taking the last phase's dps
        -- until the win condition ends the match.
    end)
end)

-- Damage. Positions come from the roster's own server-side sampling -- never
-- from anything a client reported -- so a position-lying client gains nothing
-- here.
BR.Sched.every(1000, 'storm.damage', function(dt)
    local now = GetGameTimer()

    BR.Server.eachMatch(function(m)
        if m.state ~= BR.MatchState.PLAYING or not m.storm then return end

        local rec = m.storm
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

        -- Capped so a long scheduler stall (or a test jumping the clock)
        -- cannot land one apocalyptic tick.
        local dtSec = math.min((dt and dt > 0) and (dt / 1000.0) or 1.0, 3.0)
        local carry = m.stormCarry or {}
        m.stormCarry = carry

        BR.Roster.each(
            -- `not e.rescue` IS #191'S AMBULANCE EXEMPTION and is the only
            -- exception to "a vehicle never grants storm immunity" that will
            -- ever exist here. See the block above DAMAGEABLE for the two things
            -- it is forbidden from becoming.
            function(e)
                return e.matchId == m.id and DAMAGEABLE[e.state] and not e.rescue
            end,
            function(src, e)
                if not e.pos then return end   -- not sampled yet (OneSync warning covers why)

                if BR.Dist(e.pos.x, e.pos.y, cx, cy) <= r + margin then
                    -- Inside: the ledger re-seeds from sampled reality next
                    -- time they are caught out.
                    e.stormHp  = nil
                    carry[src] = nil
                    return
                end

                -- A DOWNED PLAYER OUT HERE BLEEDS, and that is the whole of
                -- it. The bleed timer is their health (see the DBNO section
                -- of server/combat.lua), so the storm subtracts seconds from
                -- it exactly as a bullet does -- one rule rather than a
                -- second, parallel notion of storm health for downed
                -- players. No STORM_DAMAGE is sent: their ped is held at the
                -- ledger floor and the accelerating countdown on their own
                -- screen is the feedback.
                if e.state == BR.PlayerState.DBNO then
                    e.lastStormAt = now
                    BR.Combat.bleed(src, dps * dtSec, nil, nil)
                    return
                end

                -- THE LEDGER. Seeded from the sampled display hp, then
                -- decremented server-side every tick they spend outside.
                -- min() with the sample keeps it honest when the player is
                -- ALSO being shot: the ledger may never lag above reality,
                -- only refuse to be lied upward. (M6's reconciliation sweep
                -- replaces this with the full model.)
                local display = e.stormHp or e.hp or 100.0
                if e.hp and e.hp < display then display = e.hp end
                display = display - dps * dtSec
                e.stormHp     = display
                e.lastStormAt = now

                -- The visible half: tell the client to hurt its ped. Engine
                -- units, whole numbers, fraction carried forward so 1 dps
                -- rounds to two engine points per second instead of nothing.
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
                -- client's ped dies at the same moment anyway; a deaf one
                -- dies here regardless.
                if display <= 0 then
                    print(('[br_core] storm: ledger kill on %s (%d)')
                        :format(e.name, src))
                    -- defeat(), not eliminate(): the wall knocks a squad
                    -- player down like anything else does. It is a bad place
                    -- to be picked up, which is the point.
                    BR.Combat.defeat(src, 'storm', nil)
                end
            end)
    end)
end)

-- ---------------------------------------------------------------- admin ---

RegisterCommand('brphase', function(_, args)
    local m = BR.Server.latestMatch()
    local n = tonumber(args[1])
    if not n or not cfg.phases[n] then
        print(('  usage: brphase <1-%d>   current: %s'):format(#cfg.phases,
            (m and m.storm) and tostring(m.storm.phase) or 'no storm'))
        return
    end
    if not m or m.state ~= BR.MatchState.PLAYING then
        print('  the storm only runs during PLAYING (brforce playing first)')
        return
    end
    if not m.storm then BR.Storm.begin(m) end

    -- Enter phase n from wherever the wall is RIGHT NOW, so the jump is
    -- seamless on every client.
    local cx, cy, r = BR.StormAt(m.storm, GetGameTimer())
    print(('[br_core] admin: match %d storm jumped to phase %d'):format(m.id, n))
    enterPhase(m, n, cx, cy, r, GetGameTimer())
end, true)

--- FREEZE THE STORM WHERE IT STANDS. Dev mode only.
---
---   brstormfreeze          freeze every live match's wall at its current
---                          radius: no more phases, no more damage
---   brstormfreeze off      thaw -- re-enter the current phase from where the
---                          wall is now, so the resume is seamless
---
--- Exists so a match can be left running indefinitely while something else is
--- being tested, without the storm eventually deciding the session (user,
--- 2026-08-08). The alternative -- `brstormscale 1.0` and racing it -- makes
--- every long test a stopwatch.
---
--- IMPLEMENTED AS A RECORD, NOT A FLAG, and that is the whole trick. Skipping
--- the phase job would not have worked: BR.StormAt solves the wall from the
--- record's own timeline, so the circle would go on shrinking to r1 and sit
--- there at FINISHED with the last phase's dps still burning. Instead the
--- current record is REPLACED with one whose r0 = r1 = wherever the wall is
--- this instant, dps 0, and a hold long enough to outlast any session. Every
--- client solves that to a stationary, harmless circle with no special case at
--- either end, and nothing else in the file needs to know.
local frozen = false

RegisterCommand('brstormfreeze', function(_, args)
    if not BR.Server.devMode then
        print('  brstormfreeze is dev-mode only (br_devMode true)')
        return
    end

    local thaw = (args[1] == 'off' or args[1] == 'thaw')
    local now = GetGameTimer()
    local touched = 0

    BR.Server.eachMatch(function(m)
        if not m.storm then return end
        local cx, cy, r = BR.StormAt(m.storm, now)
        local phase = m.storm.phase

        if thaw then
            -- Re-enter the phase we were in, from where the wall is now.
            enterPhase(m, phase, cx, cy, r, now)
        else
            -- A day of holding. Long enough that no session outlives it, and
            -- still a real number rather than an infinity that would poison
            -- every subtraction the clients do with it.
            m.storm = BR.BuildStormRecord(phase, cx, cy, r, cx, cy, r,
                now, 24 * 60 * 60 * 1000, 1000, 0.0)
            publish(m)
        end
        touched = touched + 1
    end)

    frozen = not thaw
    print(('[br_core] storm %s (%d match%s)'):format(
        thaw and 'THAWED -- phases and damage resume'
             or 'FROZEN -- no phases, no damage, wall stays put',
        touched, touched == 1 and '' or 'es'))
    if not thaw and touched == 0 then
        print('  (no live storm yet -- it will freeze as soon as one starts)')
    end
end, true)

--- Is the storm currently held by brstormfreeze?
--- Read by BR.Storm.begin so a match starting AFTER the freeze inherits it
--- rather than quietly running a live storm under a frozen session.
--- @return boolean
function BR.Storm.isFrozen() return frozen end

--- Drop the freeze at the end of a match.
---
--- A DEBUG SWITCH SHOULD NOT OUTLIVE THE THING IT WAS SET FOR (user call,
--- 2026-08-08). Freezing is something you do to hold ONE match still while
--- testing something else in it; carrying it into the next match means the
--- next round silently has no storm, and a battle royale with no storm never
--- ends -- which is a far more confusing failure than having to type the
--- command again.
---
--- Called from BR.Storm.clear, so it rides the teardown every match already
--- performs rather than needing its own hook.
function BR.Storm.thawOnMatchEnd()
    if not frozen then return end
    frozen = false
    print('[br_core] storm freeze lifted -- the match it was holding has ended')
end

RegisterCommand('brstormscale', function(_, args)
    local s = tonumber(args[1])
    if not s then
        print(('  usage: brstormscale <0.05-1.0>   current: %.2f'):format(timeScale))
        print('  scales wait/shrink of every phase built AFTER this; brphase to apply now')
        return
    end
    timeScale = BR.Clamp(s, 0.05, 1.0)
    print(('[br_core] storm time scale = %.2f (~%.0f min cycle)')
        :format(timeScale, cfg.TotalSeconds() * timeScale / 60.0))
end, true)

-- `brstorm` LIVES IN server/debug.lua, NOT HERE (#137). Both files registered it
-- in the same Lua state and debug.lua loads later, so this version never ran
-- once. Deleted rather than renamed: the surviving one answers the same question
-- and two commands for one question is how the collision happened. Anything this
-- printed that the other does not should move there, not come back here.
