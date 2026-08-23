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

--- Put one arrived drop on the ground, SEALED.
---
--- ═══ THE AUTO-OPEN IS GONE (owner, 2026-08-22: "Also we don't need to
---     auto-open the crate. I changed my mind on that.") ═══
---
--- It used to spawn the husk and all twelve items the instant the crate touched
--- down. Three things were happening in that one call and only one of them was
--- "opening":
---
---   1. the crate was RETIRED from the flight list -- still has to happen, and
---      still does, in the tick above;
---   2. a HUSK appeared, as the thing left behind;
---   3. the CONTENTS were scattered in a ring around it.
---
--- 2 and 3 are what a player open does, and BR.Loot has done exactly that for
--- every crate on the map since long before airdrops existed: `scatter` then
--- `toHusk`, off the LOOT_CLAIM handler. So the auto-open is not replaced with
--- anything -- it is DELETED, and what lands instead is one ordinary sealed
--- container entry carrying the payout as its `contents`.
---
--- WHICH MEANS THE AIRDROP INHERITS THE WHOLE CONTAINER PATH rather than
--- imitating it: the hold-to-open prompt, the glow, the first-come arbitration,
--- the range check against the roster's own sampled position, the rate limit,
--- the "an entry you were never streamed answers exactly like one that is gone"
--- refusal, the open sound, the sealed-to-husk model swap, and the LOOT_FIX
--- repair round-trip that moves an entry the client can prove is unreachable.
--- Every one of those is hardening this file would otherwise have had to
--- re-earn on the single highest-value target in the match.
---
--- `huskProp` AND `huskItem` TRAVEL WITH IT because the airdrop's husk is drawn
--- at a different SIZE from the 1300 ordinary ones (owner, 2026-08-22: "The
--- parachute and crate props (including husk) should be 2x larger"), and the
--- client resolves a scale from the item id. BR.Loot.toHusk reads them; an
--- entry without them becomes the ordinary husk exactly as before.
--- @param m table
--- @param d table   { rec, items }
local function land(m, d)
    if not m or not m.loot then return end

    local rec   = d.rec
    local items = d.items or {}

    -- `gz` is the POI's nominal height and therefore a first pass, exactly like
    -- every generated entry's z -- the client's ground probe and the LOOT_FIX
    -- round-trip correct it, which is machinery that already exists rather than
    -- new work. That round-trip is also the rooftop answer: see
    -- BR.Loot.groundOk in br_core/client/loot.lua.
    local crate = BR.Loot.spawnStack(m, {
        item     = 'airdrop',
        kind     = 'chest',
        rarity   = BR.Rarity.LEGENDARY,
        count    = 1,
        prop     = A.crateProp or BR.Config.Loot.chestProp,
        heading  = rec.heading,
        contents = items,
        -- What it becomes when somebody opens it.
        huskItem = 'airdrophusk',
        huskProp = A.huskProp or BR.Config.Loot.chestOpenProp,
        -- WHICH DROP THIS IS, so the open can be reported back to this file and
        -- turned into the blip's `tOpen`. An id rather than a reference: the
        -- entry is announced over the wire and a table with a record hanging
        -- off it would put the whole flight plan in a LOOT_ADD payload.
        airdrop  = rec.n,
    }, rec.x, rec.y, rec.gz)

    -- THE RECORD OUTLIVES THE FLIGHT NOW. It used to be dropped on landing
    -- because nothing could happen to a drop after it burst open; a sealed
    -- crate can still be opened, and the open has to find the record to stamp
    -- `tOpen` on it and re-publish. Keyed by drop number, cleared with the
    -- match.
    m.airdrop.landed = m.airdrop.landed or {}
    m.airdrop.landed[rec.n] = rec

    print(('[br_core] airdrop: match %d drop %d landed SEALED at %s (%.0f, %.0f) -- %d items inside, entry %s')
        :format(m.id, rec.n, tostring(rec.poi), rec.x, rec.y, #items,
                tostring(crate and crate.id)))
end

--- A player just opened this match's airdrop crate.
---
--- Called from BR.Loot's claim handler, which is where the open actually
--- happens -- this file does not own the container path and deliberately does
--- not duplicate any of it. All it does is stamp the moment onto the published
--- record and send the record again.
---
--- THE RE-SEND IS THE WHOLE MECHANISM AND THERE IS NO NEW MESSAGE. The client's
--- AIRDROP_SYNC handler has always treated a record arriving with an `n` it
--- already holds as a REPLACEMENT ("a re-send replaces"), so one extra
--- broadcast per match is the entire cost of the owner's new blip rule. By the
--- time this fires the crate, canopy and flares have long since been torn down
--- at touchdown, so the replacement rebuilds nothing but the blip.
---
--- ONCE. A second open cannot happen -- the crate becomes a husk and a husk is
--- refused -- but `tOpen` is written only if it is unset anyway, so a re-entrant
--- call cannot push the blip's expiry further out.
--- @param m table
--- @param n integer   which drop of this match
function BR.Airdrop.opened(m, n)
    if not m or not m.airdrop then return end
    local rec = (m.airdrop.landed or {})[n]
    if not rec or rec.tOpen then return end

    rec.tOpen = GetGameTimer()
    BR.Broadcast.toMatch(m, BR.Net.AIRDROP_SYNC, rec)

    print(('[br_core] airdrop: match %d drop %d opened -- blip goes in %.0fs')
        :format(m.id, n,
                (BR.AirdropBlipEndsAt(rec, A) - rec.tOpen) / 1000))
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
