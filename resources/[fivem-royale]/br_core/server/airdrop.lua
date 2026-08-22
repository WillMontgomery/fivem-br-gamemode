-- Aerial supply drops, server half: the authority -- ONE PER MATCH INSTANCE.
--
-- Same shape as storm.lua and loot.lua: state hangs off `m` (m.airdrop), one
-- globally-named scheduler job walks BR.Server.eachMatch, and teardown is data
-- (m.airdrop = nil) rather than cancellation.
--
-- WHAT CROSSES THE WIRE, AND WHAT DOES NOT.
--
-- The record (BR.BuildAirdropRecord) goes out ONCE, when the drop is
-- committed. Everything the clients draw -- where the crate is this frame, how
-- long the blip has left -- is solved locally from it against the synced clock,
-- so there is no per-frame traffic and no property two machines can disagree
-- about. The CONTENTS never travel: they are rolled here and only become
-- visible as ordinary loot entries at the moment the crate bursts open, which
-- is the same rule BR.Loot's wireEntry already enforces for crates.
--
-- WHY THE CRATE IS A LOOT REGISTRY ENTRY RATHER THAN A NEW OBJECT.
--
-- An airdrop is by construction the highest-value thing on the map, which makes
-- it the highest-value target for exactly the attacks docs/security.md lists:
-- claiming out of range, claiming what was never streamed to you, racing a
-- claim, probing ids to learn what is left. BR.Loot's claim path already
-- refuses all of those -- range-checked against the roster's OWN sampled
-- position, rate-limited, first-come arbitrated, and an out-of-view claim
-- answering identically to a claim for something that no longer exists. So the
-- twelve items land as ordinary entries through BR.Loot.spawnStack and inherit
-- the whole of it. Re-earning that for a bespoke pickup would be a mistake.
--
-- ITS OWN RNG STREAM, folded with a prime of its own (1299709) exactly as the
-- loot (15485863), storm (7919) and bus (104729) do -- see docs/match-math.md
-- section 1. Drawing an airdrop's timing or position from the loot stream would
-- shift every downstream loot draw and change every existing layout, silently.

BR = BR or {}
BR.Airdrop = {}

local A = BR.Config.Airdrop

-- ---------------------------------------------------------------------------
-- Landing
-- ---------------------------------------------------------------------------

--- Burst one arrived drop open.
---
--- AUTO-OPENS, and there is no claim on the crate itself (owner, 2026-08-21:
--- "once it lands it should auto-open"). What is left behind is the husk --
--- scenery, unclaimable, refused silently by the claim handler -- and twelve
--- ordinary ground entries arranged in a ring around it.
---
--- The ring, the `from` origin and the mouth height are the same ones a crate
--- open already uses, so the arrival reads identically: everything arcs OUT of
--- the box rather than popping into existence beside it.
--- @param m table
--- @param d table   { rec, items }
local function land(m, d)
    if not m or not m.loot then return end

    local L   = BR.Config.Loot
    local rec = d.rec

    -- The opened crate. `gz` is the POI's nominal height and therefore a first
    -- pass, exactly like every generated entry's z -- the client's ground probe
    -- and the LOOT_FIX round-trip correct it, which is machinery that already
    -- exists rather than new work.
    BR.Loot.spawnStack(m, {
        item    = 'husk',
        kind    = 'husk',
        rarity  = BR.Rarity.COMMON,
        count   = 1,
        prop    = A.huskProp or L.chestOpenProp,
        heading = rec.heading,
    }, rec.x, rec.y, rec.gz)

    local items = d.items or {}
    local n = #items
    if n > 0 then
        local spread = A.scatterSpread or L.deathBoxSpread or 0.8
        local radius = math.max(spread, 0.55 * n * spread)
        local from   = {
            x = rec.x, y = rec.y,
            lift = L.crateMouthHeight or 0.6,
        }
        for i, stack in ipairs(items) do
            local a = (i / n) * math.pi * 2.0
            BR.Loot.spawnStack(m, stack,
                rec.x + math.cos(a) * radius,
                rec.y + math.sin(a) * radius,
                rec.gz, from)
        end
    end

    print(('[br_core] airdrop: match %d drop %d landed at %s (%.0f, %.0f) -- %d items')
        :format(m.id, rec.n, tostring(rec.poi), rec.x, rec.y, n))
end

-- ---------------------------------------------------------------------------
-- Committing
-- ---------------------------------------------------------------------------

--- Try to turn a pending schedule entry into a real drop.
---
--- THREE OUTCOMES, and the middle one is the whole of #88's hard part:
---
---   'sent'   -- sited, published, announced.
---   'wait'   -- nothing qualifies YET. The caller leaves it pending and asks
---               again in retryEveryMs. A circle mid-shrink is a genuinely
---               different question a few seconds later, so this terminates on
---               its own rather than spinning: either a POI comes inside the
---               margin, or the phase cap below closes the window.
---   'phase'  -- past storm stage 4. This match gets no drop, and the log says
---               so. See config/airdrop.lua for why neither rule is bent.
---
--- NO RNG IS BURNED ON A 'wait'. BR.AirdropPickSite draws nothing when there
--- are no candidates, so the payout a match eventually gets does not depend on
--- how many times this was asked.
--- @param m table
--- @param p table   the pending entry { n, dueAt, checkedAt }
--- @param now number
--- @return string outcome
local function tryCommit(m, p, now)
    if not BR.AirdropStormOk(m.storm, A.maxPhase) then
        print(('[br_core] airdrop: match %d gets none -- storm is past stage %d')
            :format(m.id, A.maxPhase or 4))
        return 'phase'
    end

    -- THE CIRCLE AT ARRIVAL, not the one showing now. BR.StormAt is a pure
    -- function of the published record, so "will this point be inside the
    -- circle when the crate lands" is arithmetic rather than a guess.
    --
    -- ARRIVAL IS THE PLANE'S RUN-IN PLUS THE FALL. `planeLeadMs` is the window
    -- between the announcement and the crate leaving the aircraft, and it counts
    -- here for the same reason `descentMs` does: the 250m margin is a promise
    -- about where the crate will be when it TOUCHES DOWN, and solving it against
    -- a time twelve seconds early would quietly shave the margin on every shrink.
    local tRelease = now + (A.planeLeadMs or 0)
    local tLand    = tRelease + (A.descentMs or 30000)
    local cx, cy, r = BR.StormAt(m.storm, tLand)

    local poi, seen = BR.AirdropPickSite(m.airdrop.rng, BR.Config.Map.POIs,
        cx, cy, r, A.insideBy or 250.0, BR.LootPlaceable)
    if not poi then
        local _ = seen
        return 'wait'
    end

    local rec = BR.BuildAirdropRecord(p.n, poi, A.altitude or 260.0,
        now, tLand, m.airdrop.rng:float() * 360.0, tRelease)
    local items = BR.AirdropPayout(m.airdrop.rng, A)

    m.airdrop.live[#m.airdrop.live + 1] = { rec = rec, items = items }
    m.airdrop.sent = (m.airdrop.sent or 0) + 1

    BR.Broadcast.toMatch(m, BR.Net.AIRDROP_SYNC, rec)

    -- VERBATIM, and the literal lives in the config so there is one copy of it
    -- (owner, 2026-08-21). Sent to the match's own audience rather than to -1:
    -- a second concurrent match, and the lobby, have nothing to do with this
    -- one's drop.
    BR.Server.notify(BR.Server.audience(m), A.notifyText, 'info')

    print(('[br_core] airdrop: match %d drop %d -> %s (%.0f, %.0f), released in %.0fs and lands in %.0fs, %d POI(s) qualified (circle r %.0f, margin %.0f)')
        :format(m.id, rec.n, tostring(poi.id), poi.x, poi.y,
                (A.planeLeadMs or 0) / 1000,
                (tLand - now) / 1000, seen, r, A.insideBy or 250.0))
    return 'sent'
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

--- Schedule a match's airdrops. Called when it goes PLAYING.
---
--- EVERY DRAW HAPPENS WHETHER OR NOT IT IS USED. The chance roll and the delay
--- are both taken unconditionally, so a match where the probability roll fails
--- burns exactly the same RNG as one where it passes -- the same discipline
--- BR.NextStormCentre applies to its breakout roll, and for the same reason: a
--- conditional draw makes the sequence depend on the outcome.
--- @param m table
function BR.Airdrop.begin(m)
    m.airdrop = nil
    if not A or A.enabled == false then return end

    local count = math.tointeger(A.perMatch or 1) or 1
    if count <= 0 then return end

    local now = GetGameTimer()
    local st = {
        rng     = BR.Rng(now + m.id * 1299709),
        pending = {},
        live    = {},
        sent    = 0,
    }

    local lo = A.minDelayMs or 210000
    local hi = math.max(lo, A.maxDelayMs or lo)

    for i = 1, count do
        local roll  = st.rng:float()
        local delay = st.rng:int(lo, hi)
        if roll < (A.chance or 1.0) then
            st.pending[#st.pending + 1] = {
                n = i, dueAt = now + delay, checkedAt = 0,
            }
        end
    end

    m.airdrop = st

    if #st.pending == 0 then
        print(('[br_core] airdrop: match %d rolled no drop (chance %.2f)')
            :format(m.id, A.chance or 1.0))
    else
        local due = {}
        for _, p in ipairs(st.pending) do
            due[#due + 1] = ('%.0fs'):format((p.dueAt - now) / 1000)
        end
        print(('[br_core] airdrop: match %d scheduled %d drop(s), due %s')
            :format(m.id, #st.pending, table.concat(due, ', ')))
    end
end

--- Forget a match's airdrops. The clients tear their own props down off the
--- state transition, so there is nothing to un-send here.
--- @param m table
function BR.Airdrop.clear(m)
    if m then m.airdrop = nil end
end

-- ---------------------------------------------------------------------------
-- The tick
-- ---------------------------------------------------------------------------
--
-- 1 Hz. The descent is half a minute long and the schedule is measured in
-- minutes, so nothing here needs to be finer -- and the SOLVER is what answers
-- "where is the crate now", on every client, for free.

BR.Sched.every(1000, 'airdrop.tick', function()
    local now = GetGameTimer()

    BR.Server.eachMatch(function(m)
        local st = m.airdrop
        if not st then return end
        if m.state ~= BR.MatchState.PLAYING then return end

        -- Arrivals first, so a drop committed and landed inside one tick (only
        -- reachable with a zero descentMs, which the dev command allows) still
        -- happens in the right order.
        for i = #st.live, 1, -1 do
            local d = st.live[i]
            if BR.AirdropLanded(d.rec, now) then
                table.remove(st.live, i)
                land(m, d)
            end
        end

        for i = #st.pending, 1, -1 do
            local p = st.pending[i]
            if now >= p.dueAt
               and (now - p.checkedAt) >= (A.retryEveryMs or 5000) then
                p.checkedAt = now
                if tryCommit(m, p, now) ~= 'wait' then
                    table.remove(st.pending, i)
                end
            end
        end
    end)
end)

-- ---------------------------------------------------------------- admin ---

--- Inspect or force a drop.
---
---   brairdrop              what this match's schedule is doing
---   brairdrop now          commit the next pending drop immediately, under
---                          the real siting rules (so "no POI qualifies" is
---                          reproducible rather than theoretical)
---   brairdrop <poiId>      drop on a named POI, bypassing the storm phase cap
---                          and the 250m margin -- the only way to see one land
---                          somewhere specific without waiting for the circle
---                          to cooperate
RegisterCommand('brairdrop', function(_, args)
    local m = BR.Server.latestMatch()
    if not m then
        print('  no match')
        return
    end
    if m.state ~= BR.MatchState.PLAYING then
        print(('  airdrops only run during PLAYING (match %d is %s)')
            :format(m.id, tostring(m.state)))
        return
    end
    if not m.airdrop then
        print('  this match has no airdrop schedule (BR.Config.Airdrop.enabled?)')
        return
    end

    local st  = m.airdrop
    local now = GetGameTimer()
    local arg = args[1] and tostring(args[1]) or nil

    if not arg then
        print(('=== airdrop: match %d ==='):format(m.id))
        print(('  sent %d, in flight %d, pending %d')
            :format(st.sent or 0, #st.live, #st.pending))
        for _, p in ipairs(st.pending) do
            print(('    drop %d due in %.0fs'):format(p.n, (p.dueAt - now) / 1000))
        end
        for _, d in ipairs(st.live) do
            print(('    drop %d at %s lands in %.0fs')
                :format(d.rec.n, tostring(d.rec.poi), (d.rec.tLand - now) / 1000))
        end
        print('  usage: brairdrop [now|<poiId>]')
        return
    end

    if arg == 'now' then
        local p = st.pending[1]
        if not p then
            print('  nothing pending')
            return
        end
        p.checkedAt = 0
        p.dueAt = now
        local outcome = tryCommit(m, p, now)
        if outcome ~= 'wait' then table.remove(st.pending, 1) end
        print(('  %s'):format(outcome))
        return
    end

    local poi = BR.Config.Map.GetPOI(arg)
    if not poi then
        print(('  no such POI: %s'):format(arg))
        return
    end

    local n = (st.sent or 0) + 1
    local tRelease = now + (A.planeLeadMs or 0)
    local rec = BR.BuildAirdropRecord(n, poi, A.altitude or 260.0,
        now, tRelease + (A.descentMs or 30000), st.rng:float() * 360.0,
        tRelease)
    st.live[#st.live + 1] = { rec = rec, items = BR.AirdropPayout(st.rng, A) }
    st.sent = n
    BR.Broadcast.toMatch(m, BR.Net.AIRDROP_SYNC, rec)
    BR.Server.notify(BR.Server.audience(m), A.notifyText, 'info')
    print(('  forced drop %d on %s (%.0f, %.0f)'):format(n, poi.id, poi.x, poi.y))
end, true)
