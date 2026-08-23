-- Aerial supply drops, server half: the authority -- ONE PER MATCH INSTANCE.
--
-- Same shape as storm.lua and loot.lua: state hangs off `m` (m.airdrop), one
-- globally-named scheduler job walks BR.Server.eachMatch, and teardown is data
-- (m.airdrop = nil) rather than cancellation.
--
-- WHAT CROSSES THE WIRE, AND WHAT DOES NOT.
--
-- The record goes out ONCE PER STATE CHANGE and never per frame. Everything the
-- clients draw -- where the crate is this frame, how long the blip has left --
-- is solved locally from it against the synced clock, so there is no per-frame
-- traffic and no property two machines can disagree about. The CONTENTS never
-- travel: they are rolled here and only become visible as ordinary loot entries
-- at the moment a PLAYER opens the crate, which is the same rule BR.Loot's
-- wireEntry already enforces for every crate on the map.
--
-- ═══ A DROP HAPPENS IN TWO PHASES, AND THE ORDER IS THE FEATURE ═══
--
-- Owner, 2026-08-22: "the drop should never happen until a player is within 200m
-- of the drop location. That way they get to see the drop happen."
--
--   SITE   at schedule time. A POI is chosen, the record is published and the
--          match is notified. The blip goes up and NOTHING FLIES.
--   ARM    when the closest living player is within `armWithin` of the landing
--          point. tArm, tRelease and tLand are written onto the SAME record and
--          it is re-broadcast; the descent from there is what it always was.
--
-- THE ANNOUNCEMENT CANNOT MOVE TO THE SECOND PHASE. A gate on "is somebody near
-- the drop" is circular unless they have been told where the drop is -- nobody
-- would ever be within 200m except by accident, and a match would essentially
-- never get an airdrop.
--
-- AND IF NOBODY COMES, THE MATCH GETS NONE (owner, 2026-08-22: "if nobody goes
-- to the area where the drop is ready to happen within the allotted time, then
-- no drop should happen"). "The allotted time" is the blip's own ceiling, and
-- the drop is abandoned at exactly the instant the blip goes out -- one clock,
-- one question (BR.AirdropExpired), so a blip marking a crate that is never
-- coming is not a state this can reach. It counts as SPENT rather than retried.
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

--- Try to SITE a pending schedule entry and announce it.
---
--- ═══ THIS USED TO BE THE WHOLE DROP AND IS NOW HALF OF IT ═══
---
--- It sited the POI, published the record, sent the notification AND started
--- the descent, all in one call. Owner, 2026-08-22: "the drop should never
--- happen until a player is within 200m of the drop location" -- so the descent
--- moved out, into tryArm below.
---
--- THE ORDER IS THE POINT AND IT WAS NOT ALREADY RIGHT. A gate on "is somebody
--- near the drop" is circular unless they have been told where the drop IS:
--- gating this function would mean nobody was ever within 200m except by
--- accident and the match would essentially never get an airdrop. So the
--- announcement stays here, at schedule time, ahead of the gate -- the blip goes
--- up, the notification goes out, and the place is named. Only the aircraft and
--- the crate wait.
---
--- THREE OUTCOMES, and the middle one is the whole of #88's hard part:
---
---   'sited'  -- published and announced. The blip is up; nothing is flying.
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
local function trySite(m, p, now)
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
    --
    -- ═══ AND IT IS THE EARLIEST ARRIVAL NOW, NOT THE ONLY ONE ═══
    --
    -- Since the 200m gate, the crate may not leave for minutes after this. So
    -- this solves the margin against the SOONEST landing the drop could have --
    -- the case where somebody is already standing there -- and the real landing
    -- can be later, under a circle that has shrunk further.
    --
    -- THE MARGIN IS DELIBERATELY NOT RE-CHECKED AT THE ARM, and the reason is
    -- that the gate does the job instead: a point that ends up outside the
    -- circle is a point nobody is near, so nobody opens the gate and the drop
    -- expires on its own. Re-checking would abandon a drop for a player who
    -- walked to it exactly as asked, which is worse than what it would prevent.
    -- See config/airdrop.lua.
    local tRelease = now + (A.planeLeadMs or 0)
    local tLand    = tRelease + (A.descentMs or 30000)
    local cx, cy, r = BR.StormAt(m.storm, tLand)

    local poi, seen = BR.AirdropPickSite(m.airdrop.rng, BR.Config.Map.POIs,
        cx, cy, r, A.insideBy or 250.0, BR.LootPlaceable)
    if not poi then
        local _ = seen
        return 'wait'
    end

    -- NO tRelease AND NO tLand. Nothing is in the air yet -- this record says
    -- "a drop is coming, and it is coming HERE". BR.ArmAirdropRecord fills those
    -- two in when somebody turns up, and the same record is re-broadcast.
    local rec = BR.BuildAirdropSite(p.n, poi, A.altitude or 260.0,
        now, m.airdrop.rng:float() * 360.0)

    -- ROLLED NOW, NOT AT THE ARM. The draw order is unchanged from when this
    -- was one function -- heading, then payout -- so a seed still produces the
    -- payout it always did, and the number of rng calls does not depend on how
    -- long anybody took to walk there. A payout rolled at the arm would make
    -- the contents a function of player movement.
    local items = BR.AirdropPayout(m.airdrop.rng, A)

    -- SPENT AT THE ANNOUNCEMENT, not at the landing. The match has now been told
    -- an airdrop is coming; if nobody comes and it expires, that WAS this
    -- match's airdrop. A retry would announce a second one somewhere else, which
    -- reads as two airdrops in a match the owner asked to have exactly one.
    m.airdrop.waiting[#m.airdrop.waiting + 1] = {
        rec = rec, items = items,
        -- The nearest anybody has actually got, for the diagnostic. This is the
        -- number that retunes `armWithin` from a playtest instead of a guess.
        closest = math.huge,
    }
    m.airdrop.sent = (m.airdrop.sent or 0) + 1

    BR.Broadcast.toMatch(m, BR.Net.AIRDROP_SYNC, rec)

    -- VERBATIM, and the literal lives in the config so there is one copy of it
    -- (owner, 2026-08-21). Sent to the match's own audience rather than to -1:
    -- a second concurrent match, and the lobby, have nothing to do with this
    -- one's drop.
    BR.Server.notify(BR.Server.audience(m), A.notifyText, 'info')

    print(('[br_core] airdrop: match %d drop %d SITED at %s (%.0f, %.0f) -- waiting for a player within %.0fm, %d POI(s) qualified (circle r %.0f, margin %.0f), expires in %.0fs')
        :format(m.id, rec.n, tostring(poi.id), poi.x, poi.y,
                A.armWithin or 200.0, seen, r, A.insideBy or 250.0,
                (BR.AirdropBlipEndsAt(rec, A) - now) / 1000))
    return 'sited'
end

--- Where every living player in this match is, for the gate.
---
--- ═══ THE ROSTER'S OWN SAMPLED POSITIONS, WHICH IS THE ONLY HONEST SOURCE ═══
---
--- The server has no map and cannot see anybody; what it has is the position
--- each client reports, sampled at 4Hz and already the basis for every range
--- check in the loot claim path (docs/security.md). Using it here means the gate
--- is exactly as trustworthy as the pickup range check, and no more -- and a
--- client that lies about being near the drop has bought itself an airdrop
--- arriving where it already was, which is a strictly worse outcome for them
--- than walking there.
---
--- ALIVE OR DOWNED, NOT MERELY CONNECTED. A player watching from the lobby, or
--- one who has left, is not somebody who "gets to see the drop happen". DBNO is
--- included deliberately: they are still in the match, still have a position,
--- and are about to be revived or finished off right next to the crate.
--- @param m table
--- @return table[]  array of { x, y }
local function watchers(m)
    local out = {}
    for _, src in ipairs(BR.Server.audience(m)) do
        local e = BR.Roster.get(src)
        if e and e.pos
           and (e.state == BR.PlayerState.ALIVE or e.state == BR.PlayerState.DBNO)
        then
            out[#out + 1] = { x = e.pos.x, y = e.pos.y }
        end
    end
    return out
end

--- Has somebody come close enough to send the aircraft?
---
--- ═══ A ONE-WAY LATCH, AND THAT ANSWERS "WHAT IF THEY DIE?" ═══
---
--- Once this returns 'armed' the record carries a tRelease and a tLand and the
--- descent is a pure function of the published record and the synced clock --
--- exactly as it always was. Nothing can un-arm it. So a player who opens the
--- gate and is then killed before the crate lands does not cancel the drop: the
--- box has left the aircraft, and their killer is standing where it is coming
--- down, which is the fight this whole feature is for.
---
--- THREE OUTCOMES:
---
---   'armed'   -- somebody is within armWithin. tArm, tRelease and tLand are
---                written onto the record and it is re-broadcast.
---   'waiting' -- nobody yet. Ask again next tick.
---   'expired' -- the blip's own ceiling passed with nobody having come. The
---                match gets no airdrop (owner, 2026-08-22: "if nobody goes to
---                the area where the drop is ready to happen within the allotted
---                time, then no drop should happen").
---
--- THE EXPIRY IS THE BLIP'S, DELIBERATELY. BR.AirdropExpired is the single
--- question, so the moment the blip goes out and the moment the drop is
--- abandoned are the same instant rather than two timers that can disagree --
--- and because the client tears its own blip down off the same record and the
--- same clock, this needs no message at all.
---
--- THE STORM PHASE IS RE-CHECKED, unlike the 250m margin. The margin is
--- self-correcting -- a point that falls outside the circle is a point nobody is
--- near, so the gate simply never opens -- but the phase cap is not: players are
--- inside the circle at stage 5 and would happily open a gate the owner's own
--- rule says is closed.
--- @param m table
--- @param w table   the waiting entry { rec, items, closest }
--- @param now number
--- @return string outcome
local function tryArm(m, w, now)
    local rec = w.rec

    if BR.AirdropExpired(rec, now, A) then
        print(('[br_core] airdrop: match %d drop %d EXPIRED at %s -- nobody came within %.0fm (closest was %s). This match gets no airdrop.')
            :format(m.id, rec.n, tostring(rec.poi), A.armWithin or 200.0,
                    w.closest < math.huge and ('%.0fm'):format(w.closest)
                                           or 'nobody in the match'))
        return 'expired'
    end

    if not BR.AirdropStormOk(m.storm, A.maxPhase) then
        print(('[br_core] airdrop: match %d drop %d abandoned -- storm went past stage %d while it waited (closest was %s)')
            :format(m.id, rec.n, A.maxPhase or 4,
                    w.closest < math.huge and ('%.0fm'):format(w.closest)
                                           or 'nobody in the match'))
        return 'expired'
    end

    local d = BR.AirdropClosest(watchers(m), rec.x, rec.y)
    if d < w.closest then w.closest = d end
    if d > (A.armWithin or 200.0) then return 'waiting' end

    BR.ArmAirdropRecord(rec, now, A)
    BR.Broadcast.toMatch(m, BR.Net.AIRDROP_SYNC, rec)

    print(('[br_core] airdrop: match %d drop %d ARMED -- a player is %.0fm away, released in %.0fs and lands in %.0fs')
        :format(m.id, rec.n, d, (A.planeLeadMs or 0) / 1000,
                (rec.tLand - now) / 1000))
    return 'armed'
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
    -- ═══ FOUR STAGES NOW, BECAUSE THE ANNOUNCEMENT AND THE DESCENT SPLIT ═══
    --
    --   pending  scheduled, not yet sited. No POI, nothing on any screen.
    --   waiting  SITED AND ANNOUNCED. The blip is up and the match has been
    --            told -- but nothing is flying, because the drop is waiting for
    --            somebody to come within `armWithin` of it (owner, 2026-08-22).
    --   live     armed. The aircraft is inbound and the crate is falling on a
    --            published curve, exactly as it always did.
    --   landed   on the ground, sealed, keyed by drop number so an open can find
    --            the record and stamp `tOpen` on it.
    --
    -- `outcome` IS WHY THERE IS NO CRATE, when there is no crate. A match that
    -- showed a blip and produced nothing reads as a bug in a playtest, and
    -- /brairdrop has to be able to say "nobody came within 200m; the closest
    -- anybody got was 340m" rather than shrugging.
    local st = {
        rng     = BR.Rng(now + m.id * 1299709),
        pending = {},
        waiting = {},
        live    = {},
        landed  = {},
        sent    = 0,
        outcome = nil,
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

        -- Arrivals first, so a drop armed and landed inside one tick (only
        -- reachable with a zero descentMs, which the dev command allows) still
        -- happens in the right order.
        for i = #st.live, 1, -1 do
            local d = st.live[i]
            if BR.AirdropLanded(d.rec, now) then
                table.remove(st.live, i)
                land(m, d)
            end
        end

        -- ─── THE GATE ─── every second, for every drop that has been announced
        -- and is waiting for somebody to come and watch it.
        --
        -- AT 1Hz, WHICH IS FINE AND IS THE SAME RATE EVERYTHING ELSE HERE RUNS
        -- AT. The roster's positions are sampled at 4Hz and a sprinting player
        -- covers about seven metres a second, so the worst this costs is a
        -- second of delay on a 200m threshold.
        for i = #st.waiting, 1, -1 do
            local w = st.waiting[i]
            local outcome = tryArm(m, w, now)
            if outcome == 'armed' then
                table.remove(st.waiting, i)
                st.live[#st.live + 1] = w
            elseif outcome == 'expired' then
                -- NO CRATE, EVER, FOR THIS MATCH (owner, 2026-08-22: "if nobody
                -- goes to the area where the drop is ready to happen within the
                -- allotted time, then no drop should happen"). The entry is
                -- dropped and NOT returned to `pending`: `sent` was already
                -- counted at the announcement, so the one-per-match rule reads
                -- this as spent rather than retrying somewhere else.
                --
                -- NOTHING IS SENT TO THE CLIENTS. Their blip expires off the
                -- same record and the same clock at the same instant -- see
                -- BR.AirdropExpired, which is the one question both sides ask.
                table.remove(st.waiting, i)
                st.outcome = {
                    n = w.rec.n, poi = w.rec.poi,
                    why = 'nobody came within range before the blip expired',
                    closest = w.closest,
                }
            end
        end

        for i = #st.pending, 1, -1 do
            local p = st.pending[i]
            if now >= p.dueAt
               and (now - p.checkedAt) >= (A.retryEveryMs or 5000) then
                p.checkedAt = now
                local outcome = trySite(m, p, now)
                if outcome ~= 'wait' then
                    table.remove(st.pending, i)
                    if outcome == 'phase' then
                        st.outcome = {
                            n = p.n,
                            why = 'the storm was past the phase cap before a '
                               .. 'POI ever qualified',
                            closest = math.huge,
                        }
                    end
                end
            end
        end
    end)
end)

-- ---------------------------------------------------------------- admin ---

--- Inspect or force a drop.
---
---   brairdrop              what this match's schedule is doing
---   brairdrop now          site the next pending drop immediately, under the
---                          real siting rules (so "no POI qualifies" is
---                          reproducible rather than theoretical). It still has
---                          to wait for somebody to come within armWithin.
---   brairdrop arm          open the 200m gate by hand, for testing the descent
---                          without walking there
---   brairdrop <poiId>      site a drop on a named POI, bypassing the storm
---                          phase cap and the 250m margin -- the only way to see
---                          one land somewhere specific without waiting for the
---                          circle to cooperate
---
--- ═══ IT HAS TO BE ABLE TO SAY WHY THERE IS NO CRATE ═══
---
--- A match that showed a blip and produced nothing is now a legitimate outcome
--- (owner, 2026-08-22: "if nobody goes to the area where the drop is ready to
--- happen within the allotted time, then no drop should happen") -- and it is
--- indistinguishable from a bug from a chair. So a drop that ended without
--- landing leaves an `outcome` behind, carrying the CLOSEST ANYBODY ACTUALLY
--- GOT. That number is also how `armWithin` gets retuned from a playtest rather
--- than from a guess: if the log says the closest approach was 210m, the
--- threshold is the problem and not the players.
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
        print(('  sent %d, pending %d, waiting for a player %d, in flight %d')
            :format(st.sent or 0, #st.pending, #st.waiting, #st.live))
        for _, p in ipairs(st.pending) do
            print(('    drop %d due in %.0fs'):format(p.n, (p.dueAt - now) / 1000))
        end

        -- THE GATE, WITH BOTH NUMBERS. "Waiting" on its own cannot be told from
        -- "stuck"; the closest approach and the time left are what make it a
        -- readable state.
        local live = watchers(m)
        for _, w in ipairs(st.waiting) do
            local d = BR.AirdropClosest(live, w.rec.x, w.rec.y)
            print(('    drop %d SITED at %s (%.0f, %.0f) -- closest player %s '
                   .. '(need %.0fm), closest ever %s, expires in %.0fs')
                :format(w.rec.n, tostring(w.rec.poi), w.rec.x, w.rec.y,
                        d < math.huge and ('%.0fm'):format(d) or 'nobody alive',
                        A.armWithin or 200.0,
                        w.closest < math.huge and ('%.0fm'):format(w.closest)
                                               or 'never measured',
                        (BR.AirdropBlipEndsAt(w.rec, A) - now) / 1000))
        end

        for _, d in ipairs(st.live) do
            print(('    drop %d at %s lands in %.0fs')
                :format(d.rec.n, tostring(d.rec.poi), (d.rec.tLand - now) / 1000))
        end

        -- WHY THERE IS NO CRATE. The line that stops a deliberate zero reading
        -- as a bug in the next playtest.
        if st.outcome then
            print(('  NO DROP: drop %d %s%s -- closest anybody got: %s')
                :format(st.outcome.n, st.outcome.why,
                        st.outcome.poi and (' at ' .. tostring(st.outcome.poi))
                                        or '',
                        st.outcome.closest < math.huge
                            and ('%.0fm'):format(st.outcome.closest)
                            or 'nobody was ever measured'))
        end
        print('  usage: brairdrop [now|arm|<poiId>]')
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
        local outcome = trySite(m, p, now)
        if outcome ~= 'wait' then table.remove(st.pending, 1) end
        print(('  %s'):format(outcome))
        return
    end

    -- OPEN THE GATE BY HAND. Testing the descent otherwise means physically
    -- walking a character to within 200m of wherever the circle put the POI,
    -- which is several minutes per attempt.
    if arg == 'arm' then
        local w = st.waiting[1]
        if not w then
            print('  nothing is waiting for a player')
            return
        end
        table.remove(st.waiting, 1)
        BR.ArmAirdropRecord(w.rec, now, A)
        BR.Broadcast.toMatch(m, BR.Net.AIRDROP_SYNC, w.rec)
        st.live[#st.live + 1] = w
        print(('  forced drop %d to arm; it lands in %.0fs')
            :format(w.rec.n, (w.rec.tLand - now) / 1000))
        return
    end

    local poi = BR.Config.Map.GetPOI(arg)
    if not poi then
        print(('  no such POI: %s'):format(arg))
        return
    end

    -- SITED, NOT ARMED. It goes through the same gate everything else does --
    -- forcing the POI bypasses the circle, not the owner's rule that somebody
    -- has to be there to watch. `brairdrop arm` is the second half.
    local n = (st.sent or 0) + 1
    local rec = BR.BuildAirdropSite(n, poi, A.altitude or 260.0,
        now, st.rng:float() * 360.0)
    st.waiting[#st.waiting + 1] = {
        rec = rec, items = BR.AirdropPayout(st.rng, A), closest = math.huge,
    }
    st.sent = n
    BR.Broadcast.toMatch(m, BR.Net.AIRDROP_SYNC, rec)
    BR.Server.notify(BR.Server.audience(m), A.notifyText, 'info')
    print(('  sited drop %d on %s (%.0f, %.0f) -- it waits for a player within '
           .. '%.0fm, or /brairdrop arm')
        :format(n, poi.id, poi.x, poi.y, A.armWithin or 200.0))
end, true)

-- ---------------------------------------------------------------------------
-- THE FLARES' REPLICATION, REFUSED
-- ---------------------------------------------------------------------------
--
-- ═══ THIS IS WHAT MAKES A PROJECTILE FLARE LEGAL IN A GAMEMODE WHERE NOTHING
--     ABOUT A DROP CROSSES THE WIRE ═══
--
-- The flares are real `weapon_flare` projectiles now (owner, 2026-08-22, with a
-- reference: "None of those models are the ones we need in order to draw the
-- proper particles"), because no MODEL glows -- every visual a flare has lives
-- in AMMO_FLARE's CAmmoThrownInfo and is applied by the projectile controller.
-- See br_lib/config/airdrop.lua for the whole of that argument.
--
-- A PROJECTILE REPLICATES, and that was the objection this feature's client
-- half refused the projectile route over twice. It is not a networked ENTITY --
-- `sv_entityLockdown` would not refuse it -- which makes it worse rather than
-- better: every client builds its own pair from the record and the clock, and
-- would then receive forty-seven remote copies drawn on top of them.
--
-- ONE RESEARCH PASS CLAIMED THE TECHNIQUE IS "LOCAL TO THE CALLING CLIENT". IT
-- IS NOT, and the proof is that FiveM's server carries a full wire parser for
-- it: `CStartProjectileEvent` in citizen-server-impl/src/state/
-- ServerGameState.cpp, surfaced to scripts as `startProjectileEvent` and
-- carrying ownerId, projectileHash and weaponHash. A purely local action does
-- not get a net game event.
--
-- ═══ AND CANCELLING IT SUPPRESSES THE RELAY, WHICH WAS READ RATHER THAN
--     ASSUMED ═══
--
-- Both of the server's packet paths gate the relay on the handler's return
-- value, and the handler returns TriggerEvent2 -- false when a script has
-- cancelled. Verbatim, from FiveM's own source:
--
--     if (eventHandler())            // false when a script cancelled it
--     {
--         RouteEvent(...);           // the ONLY thing that sends it onward
--     }
--
-- packethandlers/NetGameEventPacketHandler.cpp:134 for the V2 packet, and
-- state/ServerGameState.cpp:8003 for the legacy msgNetGameEvent path. Both were
-- checked, because a fix that only covers one of two paths is a fix that works
-- until a client connects on the other.
--
-- ═══ FILTERED TO THE FLARE, AND NOTHING ELSE, WHICH IS THE WHOLE RISK HERE ═══
--
-- Players throw grenades, stickies and molotovs, and every one of those is a
-- projectile whose replication the match REQUIRES. Cancelling this event
-- broadly would make thrown weapons invisible to everyone but the thrower --
-- a catastrophic bug that would look like a netcode problem rather than like
-- this line. So the match is made on the weapon hash and refuses everything it
-- does not positively recognise.
--
-- HASHES ARE NORMALISED THROUGH BR.NormHash, for the reason config/vehicles.lua
-- states at length: GetHashKey answers a SIGNED 32-bit integer in Lua while the
-- wire carries an unsigned one, so `wire == GetHashKey(name)` is false for the
-- same weapon and the filter would silently never match. That failure is
-- invisible -- it looks exactly like the event not firing.
local flareHashes = nil

--- The set of weapon hashes whose projectiles are ours to suppress.
---
--- BOTH NAMES, because either can be configured and both appear in the wild by
--- this route -- `weapon_flare` is the thrown flare the crate-drop reference
--- uses and is our default; `weapon_flaregun` is the pistol the owner's
--- reference fires. A client switched to the other with `/brflare weapon` must
--- not start leaking flares to the rest of the match.
---
--- Built once, lazily, rather than at load: this is the only reader and the
--- config is settled long before a projectile is ever fired.
--- @return table
local function flareHashSet()
    if flareHashes then return flareHashes end
    flareHashes = {}
    for _, name in ipairs({ A.flareWeapon or 'weapon_flare',
                            'weapon_flare', 'weapon_flaregun' }) do
        local h = BR.NormHash(GetHashKey(name))
        if h then flareHashes[h] = true end
    end
    return flareHashes
end

--- How many flare projectiles this server has refused to relay. Printed by
--- /brairdrop, because a filter that never matches and a filter that matches
--- everything look identical from a chair -- and one of those two is the
--- catastrophic one.
BR.Airdrop.flaresSuppressed = 0

AddEventHandler('startProjectileEvent', function(_, data)
    if type(data) ~= 'table' then return end
    -- TYPE-CHECKED BEFORE BR.NormHash, because NormHash is a bitwise AND and
    -- Lua 5.4 RAISES on a non-integer operand. This handler sees every
    -- projectile every player throws, so a malformed payload must be dropped
    -- rather than allowed to throw on the hottest event surface the server has.
    if type(data.weaponHash) ~= 'number' then return end
    local h = BR.NormHash(data.weaponHash)
    if not h or not flareHashSet()[h] then return end
    BR.Airdrop.flaresSuppressed = (BR.Airdrop.flaresSuppressed or 0) + 1
    -- The firing client's OWN flare is untouched: it was created locally before
    -- this event was ever sent, and this cancels only the relay. Every client
    -- sees exactly one pair -- the one it lit itself.
    CancelEvent()
end)
