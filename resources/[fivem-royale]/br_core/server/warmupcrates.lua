-- The four permanent crates on the warmup island: the authority half.
--
-- ═══════════════════════════════════════════════════════════════════════════
-- THE CYCLE, WHICH IS THE WHOLE FILE
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Owner, 2026-09-04: "We need 4 crates in warmup that are persistent entities
-- and can be cycled through open/closed states infinitely... The player can open
-- it like any other crate, loot comes out, and they can pick it up. After they
-- walk away any loot from the crate will animate back into the crate and the
-- husk entity will revert to a full crate entity."
--
--   SEALED   an ordinary registry entry of kind 'chest', sitting in the shared
--            warmup zone with everything else on the island.
--   OPENED   by br_core/server/loot.lua's claim handler, through the code path
--            every other crate in the game uses -- scatter() spills the
--            contents, toHusk() turns the entry into its husk in place.
--   CLEARED  when no warmup player has been within `leaveRadius` for
--            `settleMs`. Whatever is left of the spill is retired, and the
--            clients are told to fly it home first.
--   RESEALED one `returnMs` later: fresh contents at the SAME authored rarity,
--            the husk becomes a chest again, one re-announce, same entry id.
--
-- ...and then it is SEALED, which is the same state it started in with the same
-- id and the same position. That is what "infinitely" rests on: the cycle has no
-- accumulating state at all. Nothing is created per pass (the entry is mutated,
-- never replaced), nothing is appended to, and the only counter is a diagnostic.
-- The thousandth cycle runs the identical four table writes the first one did.
--
-- ═══ WHY THESE ARE ORDINARY LOOT ENTRIES ═══
--
-- The alternative -- a private registry with its own prompt, hold, claim and
-- arbitration -- is a second implementation of the most-tested interaction in
-- this project, and it would be wrong in a different way from the first one.
-- Everything that makes a crate a crate is already written: the reach test, the
-- rate limit, the first-claim-wins arbitration, the existence oracle the claim
-- handler is careful not to leak, the husk swap that answers a claim with no
-- reply message. These four get all of it by being ordinary entries in the
-- warmup zone, and this file only decides when one goes back.
--
-- IT REACHES THAT REGISTRY THROUGH THREE EXPORTS on BR.Loot -- warmupZone,
-- remove and reannounce -- added to br_core/server/loot.lua for this file. The
-- note above them there says why each one is an export rather than a copy.
--
-- ═══ WHAT THIS FILE DELIBERATELY DOES NOT SET ═══
--
-- `warmup = true` on the entry. That flag means "when this is opened, queue a
-- replacement SOMEWHERE ELSE on the island" (the claim handler, and the
-- loot.warmupRespawn job it feeds). It is right for the 220 generated crates and
-- would be a bug here: these four come back where they are, so a flagged one
-- would ALSO breed a fifth crate at a random point every time anybody opened it,
-- forever, until the island was carpeted.
--
-- ═══ AND WHAT IT CANNOT DO FROM HERE ═══
--
-- FREEZE ANYTHING. A crate's prop is a client-side, non-networked object that
-- only the client that built it can see or move (sv_entityLockdown relaxed --
-- and this file creates no entities at all, which is why that is not a problem
-- to solve here). The freeze lives in br_core/client/warmupcrates.lua, which
-- pins each prop onto the surveyed coordinates in config/warmupcrates.lua.

BR = BR or {}
BR.WarmupCrates = BR.WarmupCrates or {}

local W = BR.Config.WarmupCrates
local L = BR.Config.Loot

--- Per-anchor state. Built once, mutated forever, never reallocated.
---
---   entry      the live registry table BR.Loot.spawnStack handed back. Held by
---              REFERENCE rather than by id, so the husk swap -- which mutates
---              that same table in place -- is visible here without a lookup.
---   clearSince when the last warmup player left `leaveRadius`, or nil while one
---              is standing there.
---   returnAt   when the fly-home animation ends and the crate reseals, or nil
---              when no reset is in flight.
---   cycles     diagnostics only; /brwarmupcrates reads it.
local crates = {}

--- The island's own RNG, seeded once.
---
--- Its own instance rather than the warmup zone's: BR.Loot.warmupZone()'s `rng`
--- is what the respawn job draws replacement crates from, and sharing it would
--- mean a reset here silently moved every future random crate on the island.
--- Seeded off the clock with a prime of its own, the same shape BR.Loot.begin
--- and the storm use, so two servers started in the same millisecond do not
--- stock these four identically.
local rng = nil

--- Has the placement pass run? Placement is idempotent and self-healing (see
--- the tick), so this only stops the first pass doing it four times.
local placed = false

--- Everyone currently on the island.
---
--- WARMUP AND NOTHING ELSE, which is the same test BR.Config.LootTakeStates and
--- zoneFor() make: the warmup zone is a communal bucket shared by every
--- concurrent match's waiting players, and a player in any other state is
--- looking at a different registry entirely and cannot be standing here.
---
--- Owner, 2026-09-04: "ANYONE can use these crates in warmup, not just the
--- tutorial folks." So there is no tutorial test anywhere in this file --
--- BR.Roster.inTutorial is never asked, and the audience below is every warmup
--- player without qualification.
--- @param fn function  receives (src, entry)
local function eachOnIsland(fn)
    BR.Roster.each(function(e) return e.state == BR.PlayerState.WARMUP end, fn)
end

--- Is anybody close enough to this crate to still be using it?
---
--- A player whose position has never been sampled counts as ABSENT rather than
--- present, deliberately. `pos` is nil only in the moments between connecting
--- and the first roster sample, which is a player who is nowhere near the
--- island yet -- and treating an unknown as "somebody is standing there" is how
--- a reset that must happen eventually becomes one that never does.
--- @param a table  an anchor row
--- @return boolean
local function occupied(a)
    local near = false
    eachOnIsland(function(_, e)
        if near or not e.pos then return end
        if BR.Dist(e.pos.x, e.pos.y, a.x, a.y) <= (W.leaveRadius or 22.0) then
            near = true
        end
    end)
    return near
end

--- Everything this crate spilled that is still lying on the ground.
---
--- ═══ IDENTIFIED BY ORIGIN, NOT BY PROXIMITY ═══
---
--- Every entry born from a container carries the container's own x/y in `fx`/`fy`
--- -- BR.Loot.spawnStack copies them straight off the `from` table that
--- scatter() builds out of `container.x, container.y`. Those are the same two
--- floats, copied, so the comparison is exact and cannot mistake one crate's
--- spill for another's: no two of these four anchors share a coordinate, and no
--- generated crate is at one.
---
--- The distance test is a SECOND condition rather than the first, and it exists
--- only to bound what a wrong answer could ever reach -- see `returnRadius` in
--- config/warmupcrates.lua. An item a player has since carried off is not
--- reachable at all: picking it up retires it, and a retired entry is not in
--- this table to find.
--- @param m table
--- @param a table
--- @return table[] entries
local function spillOf(m, a)
    local out = {}
    local r = W.returnRadius or 12.0
    for _, e in pairs(m.loot.items) do
        if e.fx == a.x and e.fy == a.y and BR.Dist(e.x, e.y, a.x, a.y) <= r then
            out[#out + 1] = e
        end
    end
    -- Sorted by id so the message is stable run to run: two servers replaying
    -- the same sequence send the same list in the same order, which is the only
    -- way a report about this animation can be compared with another one.
    table.sort(out, function(p, q) return p.id < q.id end)
    return out
end

--- Put one anchor's crate into the world, sealed.
--- @param i integer
local function place(i)
    local a = W.anchors[i]
    local m = BR.Loot.warmupZone()

    -- THE SURVEYED z GOES IN AS-IS AND NOTHING VOUCHES FOR IT.
    --
    -- The two optional arguments are both omitted on purpose. `from` would give
    -- the crate a birth arc, and these were always there. `standZ` would set
    -- `pz`, which means "the SERVER measured a ped standing on this ground" --
    -- these heights are the owner's, read off his own screen, and putting them
    -- behind a field whose whole contract is server provenance would make that
    -- sentence false for the one field the client's ground probe trusts.
    --
    -- The client probes for this prop like it probes for every other one, and
    -- br_core/client/warmupcrates.lua then pins the result back onto the number
    -- above. That is where the surveyed height is honoured, and it is the only
    -- place it can be: the server has no ground probe and no map.
    local e = BR.Loot.spawnStack(m, BR.WarmupCrateStack(rng, a), a.x, a.y, a.z)
    if not e then
        print(('^3[br_core] warmupcrates: anchor %d could not be placed^7'):format(i))
        return
    end

    local rec = crates[i]
    if rec then
        rec.entry, rec.clearSince, rec.returnAt = e, nil, nil
    else
        crates[i] = { anchor = a, entry = e, clearSince = nil,
                      returnAt = nil, cycles = 0 }
    end
end

--- Start a reset: send the spill home and retire it.
---
--- THE MESSAGE GOES OUT BEFORE THE RETIREMENT, IN THAT ORDER, AND THAT IS THE
--- WHOLE OF THE ANIMATION'S CORRECTNESS. The client cannot animate a prop that
--- br_core/client/loot.lua has already deleted, and LOOT_GONE is what deletes
--- it. Both messages leave in this same server tick, so a client handles them in
--- the same frame: the return handler copies each prop where it stands, then
--- LOOT_GONE takes the original away. Reverse them and the copy finds nothing.
---
--- AND IF THEY EVER DID ARRIVE THE OTHER WAY ROUND the cost is one missing
--- animation, not a fault: the client's handler skips an item it cannot find
--- and the crate reseals on schedule regardless.
--- @param rec table
--- @param m table
--- @param now integer
local function beginReset(rec, m, now)
    local a = rec.anchor
    local spill = spillOf(m, a)

    if #spill > 0 then
        local items = {}
        for i, e in ipairs(spill) do
            -- TWO FLOATS PER ITEM, AND NOTHING ELSE ON THIS WIRE.
            --
            -- Not the item, not its kind, and NOT ITS PROP -- which is the one
            -- that looks like an omission and is not. `prop` is nil on almost
            -- everything a crate spills: BR.RollLootStack returns an id, a kind
            -- and a count, and the MODEL is resolved on the client by
            -- modelOf(), which asks GET_WEAPONTYPE_MODEL for a weapon and three
            -- different config tables for everything else. Sending a name this
            -- side does not have would send nil; sending enough for the client
            -- to redo that resolution would be a second copy of modelOf living
            -- in a different file from the first.
            --
            -- So the client is told WHERE and works out WHAT by looking: a loose
            -- prop stands at its entry's x/y exactly, so the object already in
            -- the world answers both the model question and the height question
            -- at once, and answers them with what is actually on screen rather
            -- than with what this side believes.
            items[i] = { x = e.x, y = e.y }
        end
        local payload = {
            x = a.x, y = a.y, z = a.z,
            lift  = W.mouthLift or L.crateMouthHeight or 0.6,
            ms    = W.returnMs or 520,
            items = items,
        }
        -- EVERY WARMUP PLAYER, not the crate's cell subscribers. This is a rare
        -- event on a communal island a handful of people are standing on, and
        -- the alternative is a second copy of loot.lua's cell arithmetic to save
        -- a message nobody will ever measure. A client too far away to have
        -- built the props finds none and does nothing.
        eachOnIsland(function(src)
            TriggerClientEvent(BR.Net.WARMUP_CRATE_RETURN, src, payload)
        end)
    end

    for _, e in ipairs(spill) do
        BR.Loot.remove(m, e)
    end

    rec.returnAt = now + (W.returnMs or 520)
end

--- Finish a reset: the husk becomes a sealed crate again.
---
--- THE MIRROR OF toHusk IN br_core/server/loot.lua, field for field, and it is
--- written as a mirror on purpose -- if that function grows a field this one has
--- to give it back. Same id, same position, one re-announce: the client mutates
--- the entry it already holds and swaps one model for the other, which is the
--- 2026-08-05 fix ("visibly slow") running in the other direction.
---
--- THE POSITION IS RE-ASSERTED RATHER THAN ASSUMED. A container is the one kind
--- of entry br_core/server/loot.lua will let a client move more than once
--- (fixOk: "those get to keep moving"), so a crate that somehow attracted a
--- repair would otherwise reseal wherever the repair left it and stay there for
--- every cycle after. It cannot currently happen -- the client pin means the
--- prop never leaves the surveyed point, so nothing ever reports one -- and that
--- is exactly the kind of "cannot happen" worth costing three assignments.
---
--- AND IT IS SAFE TO WRITE THEM WITHOUT RE-INDEXING, which is the question that
--- assignment raises. `e.cell` is set when the entry is indexed and every
--- announce goes to that cell's subscribers, so a position restored into a
--- DIFFERENT cell would be a crate announced to the wrong people. It cannot be:
--- a repair is bounded to 30m (FIX_RADIUS), cells are 256m, and the nearest cell
--- boundary to any of the four anchors is over a hundred metres away.
--- @param rec table
--- @param m table
local function reseal(rec, m)
    local a = rec.anchor
    local e = rec.entry

    e.contents = BR.WarmupCrateContents(rng, a.rarity)
    e.kind     = 'chest'
    e.item     = 'chest'
    e.prop     = L.chestProp
    e.rarity   = BR.LootContentsRarity(e.contents)
    e.heading  = a.heading
    e.x, e.y, e.z = a.x, a.y, a.z

    BR.Loot.reannounce(m, e)

    rec.returnAt   = nil
    rec.clearSince = nil
    rec.cycles     = rec.cycles + 1
end

-- ═══ THE ONE JOB, AT 4 Hz ═══
--
-- Four crates, one distance test each against however many people are on the
-- island. That is cheaper than the roster's own position sampler and it runs on
-- the same scheduler, so /brperf accounts for it beside everything else.
--
-- 250ms rather than 1000: `settleMs` is the number that decides when a crate
-- comes back, and a job that only looks once a second turns a 5-second settle
-- into somewhere between 5 and 6. The animation hand-off (`returnAt`) wants the
-- finer clock too -- at 1Hz the reseal would land up to a second after the loot
-- had finished flying home, which is a second of an empty husk with nothing on
-- the way to it.
BR.Sched.every(250, 'warmupcrates.tick', function()
    if W.enabled == false then return end

    -- GUARDED, LIKE EVERY OTHER CROSS-FILE CALL ON THIS PROJECT. br_core's
    -- manifest declares server/loot.lua above this file, so on any real
    -- deployment these three exports are there -- and a build that dropped that
    -- file has lost the whole loot system, not four crates. Indexing nil here
    -- would take this scheduler job down after five errors and put THAT in the
    -- log instead of the actual fault.
    if not BR.Loot or not BR.Loot.warmupZone then return end

    local now = GetGameTimer()
    local m = BR.Loot.warmupZone()
    if not m or not m.loot then return end

    if not placed then
        placed = true
        rng = BR.Rng(GetGameTimer() + 8867)
        for i = 1, #W.anchors do place(i) end
        print(('[br_core] warmupcrates: %d permanent crates placed on the island')
            :format(#W.anchors))
        return
    end

    for i = 1, #W.anchors do
        local rec = crates[i]

        -- SELF-HEAL. Nothing in this project retires a husk, so an anchor whose
        -- entry has left the registry is a fault somewhere else -- and the
        -- honest response to it is a crate back on the island rather than an
        -- empty patch of beach nobody can explain. Loud, because a silent
        -- re-place would hide whatever ate the first one.
        if not rec or m.loot.items[rec.entry.id] ~= rec.entry then
            print(('^3[br_core] warmupcrates: anchor %d had lost its entry -- replacing^7')
                :format(i))
            place(i)
        elseif rec.returnAt then
            if now >= rec.returnAt then reseal(rec, m) end
        elseif rec.entry.kind == 'husk' then
            if occupied(rec.anchor) then
                rec.clearSince = nil
            else
                rec.clearSince = rec.clearSince or now
                if now - rec.clearSince >= (W.settleMs or 5000) then
                    beginReset(rec, m, now)
                end
            end
        else
            -- Sealed. Any half-counted departure belongs to the cycle that has
            -- just ended, not to the next one.
            rec.clearSince = nil
        end
    end
end)

--- What the four crates are doing right now.
---
--- READ-ONLY AND COPIED. The caller gets numbers, not the live records: this
--- table is the cycle's entire state and a reader holding a reference to it
--- could stop one mid-reset without meaning to.
--- @return table[]
function BR.WarmupCrates.state()
    local now = GetGameTimer()
    local out = {}
    for i = 1, #W.anchors do
        local a = W.anchors[i]
        local rec = crates[i]
        out[i] = {
            index   = i,
            x = a.x, y = a.y, z = a.z, heading = a.heading,
            rarity  = a.rarity,
            id      = rec and rec.entry.id or nil,
            kind    = rec and rec.entry.kind or nil,
            cycles  = rec and rec.cycles or 0,
            clearMs = (rec and rec.clearSince) and (now - rec.clearSince) or nil,
            resealIn = (rec and rec.returnAt) and (rec.returnAt - now) or nil,
        }
    end
    return out
end

-- The state dump. DEV-GATED FOR FREE and it must stay that way:
-- br_lib/shared/devgate.lua wraps RegisterCommand for every file that loads
-- after it, so there is no third argument here -- passing `true` would make this
-- ace-restricted instead, which is a different gate that FiveM's own console
-- refuses in production mode.
--
-- IT ANSWERS THE THREE QUESTIONS A REPORT ABOUT THESE CRATES CAN RAISE, because
-- from a chair "the crate never came back", "it came back empty" and "it came
-- back in the wrong place" all look the same: whether the entry still exists,
-- what kind it currently is, and how far through the settle it is. `cycles` is
-- the one that proves the loop is a loop -- a number that goes up is a crate
-- that has genuinely reset rather than one that was never opened.
RegisterCommand('brwarmupcrates', function()
    print(('[br_core] warmup crates: %d anchors, %s')
        :format(#W.anchors, W.enabled == false and 'DISABLED' or 'enabled'))
    for _, s in ipairs(BR.WarmupCrates.state()) do
        local info = BR.RarityInfo[s.rarity]
        print(('  %d  %-9s  (%.2f, %.2f, %.2f) h%.1f  id=%s kind=%s cycles=%d%s%s')
            :format(s.index, info and info.label or '?',
                    s.x, s.y, s.z, s.heading,
                    tostring(s.id), tostring(s.kind), s.cycles,
                    s.clearMs and (('  clear for %dms'):format(s.clearMs)) or '',
                    s.resealIn and (('  reseals in %dms'):format(s.resealIn)) or ''))
    end
end)
