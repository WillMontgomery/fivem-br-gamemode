-- World loot: the layout, the streaming grid, and claim arbitration.
--
-- ONE MATCH, ONE LAYOUT, LIVING ON THE INSTANCE. Exactly the shape storm.lua
-- settled on: state hangs off `m`, one globally-named scheduler job walks
-- BR.Server.eachMatch. Per-match jobs are not merely unnecessary, they are
-- impossible -- BR.Sched.every hard-errors on a duplicate name -- and teardown
-- is data (m.loot = nil), not cancellation.
--
-- THE CLIENT IS TOLD, NEVER SHOWN THE SEED. The layout is generated here from
-- a seed and streamed cell by cell as players walk into range. Handing the
-- client the seed instead would be one line shorter and would ship a wallhack:
-- every item on the map, derivable at leisure, forever.
--
-- CLAIMS ARE ARBITRATED, NOT ANNOUNCED. Two players reaching the same rifle in
-- the same tick is the normal case at a hot drop, not an edge case; exactly one
-- of them gets it here, and the loser is TOLD (refusals are audible, the rule
-- the bus jump handler earned the hard way).

BR = BR or {}
BR.Loot = BR.Loot or {}

local L = BR.Config.Loot

-- Forward declaration. zoneFor() needs the warmup zone, which is built further
-- down, but the spawn helpers above it need zoneFor -- and a local referenced
-- before its `local` statement resolves as a GLOBAL, which is nil at runtime
-- and silent at load.
local zoneFor

-- THE SAME TABLES THE CLIENT READS (br_lib/config/loot.lua). Written out twice
-- they drifted, and the symptom was no loot anywhere with nothing in any log:
-- the client simply never asked. WARMUP sees the SHARED island layout rather
-- than any match's -- see zoneFor().
--
-- This side is still the security boundary; it just no longer has its own
-- opinion about what the rule is.
local CAN_SEE  = BR.Config.LootVisibleStates
local CAN_TAKE = BR.Config.LootTakeStates

-- --------------------------------------------------------------------------
-- Wire shapes
-- --------------------------------------------------------------------------

--- The client's view of a ground entry. Container CONTENTS never travel: what
--- is in a chest is the reason to open it, and a client that knew would only
--- open the good ones.
--- @param e table
--- @param born boolean|nil  true only on the message that ANNOUNCES A BIRTH.
--- @return table
local function wireEntry(e, born)
    return {
        id      = e.id,
        kind    = e.kind,
        item    = e.item,
        rarity  = e.rarity,
        count   = e.count,
        x       = e.x,
        y       = e.y,
        z       = e.z,
        prop    = e.prop,
        heading = e.heading,
        -- WHERE THIS THING CAME FROM, when it came from somewhere.
        --
        -- Three floats, present only on entries that were born mid-match --
        -- a crate bursting open, a player dropping something -- and absent on
        -- the generated layout, which was always just there. The client uses
        -- it to arc the prop from its origin to its resting place instead of
        -- popping it into existence.
        --
        -- SENT WITH THE THING IT DESCRIBES, deliberately, rather than
        -- prefetched during the open-hold. Prefetching a container's contents
        -- before the claim is confirmed would hand the client a list of what
        -- is inside crates it has not opened, which is a wallhack for three
        -- floats' worth of latency we do not actually need: the origin
        -- travels in the same message as the item.
        --
        -- AND ONLY IN THAT MESSAGE. An origin is a BIRTH EVENT, not a property
        -- of the entry, and this is the distinction that makes the arc safe to
        -- run at all. These fields used to be on every wire copy -- the cell
        -- subscription, the reconnect snapshot, the repair re-announce -- so a
        -- player who walked into the cell five minutes after a crate was opened
        -- was handed the same three floats as the player who opened it. The
        -- client stamps the arrival clock when the message arrives, because it
        -- has no other clock to stamp it from, so that player's loot would have
        -- flown out of a box somebody emptied while they were elsewhere.
        fx      = born and e.fx or nil,
        fy      = born and e.fy or nil,
        -- HEIGHT ABOVE THE GROUND, NOT AN ABSOLUTE Z, and that distinction is
        -- a bug fix. The server's z for any entry is a first-pass hint -- only
        -- the client has a ground probe, which is why groundZ() exists there
        -- at all. Sending the container's authored z as the arc's start meant
        -- items burst UPWARD OUT OF THE FLOOR when that hint sat below the
        -- real ground (user, 2026-08-08).
        --
        -- A lift is unambiguous: the client adds it to the ground height it
        -- resolved itself, so the arc starts at the crate's mouth or the
        -- player's hands wherever the terrain actually is.
        fl      = born and e.flift or nil,
        -- ═══ THE ONE HEIGHT ON THIS WIRE THAT IS A MEASUREMENT ═══
        --
        -- Owner, 2026-09-03: "any time an inventory item is dropped and the ped
        -- is under a bridge or other structure, the item goes on the ground on
        -- the upper structure and not on the ground around the ped".
        --
        -- The client resolves every entry's height itself, by probing DOWN from
        -- 1200m -- see PROBE_FROM_Z in client/loot.lua, and the hillside
        -- regression written up above it that put that number there. Under an
        -- overpass the highest ground below 1200 in that column is the DECK, so
        -- the probe succeeds, plausibly, and answers with the freeway over your
        -- head. Nothing downstream can tell that answer from a right one.
        --
        -- `z` cannot break the tie, because `z` means different things for
        -- different entries: for the 1300 generated ones it is a hint authored
        -- from map knowledge (0.0 for roadside filler, and config/map.lua's own
        -- header says so), and for a dropped item it is a live ped's root that
        -- the server sampled. The client has no way to know which it holds.
        --
        -- `pz` IS THAT BIT, AND IT IS ONLY EVER SET WHERE A PED WAS ACTUALLY
        -- STANDING ON THE GROUND IN QUESTION. Present on a drop and a death
        -- scatter, absent on all generated loot, all crate contents, the
        -- airdrop and the landing crates. Where it is present the client starts
        -- its probe just above it instead of in the sky, so the surface it
        -- finds is the one under the bridge rather than the one over it.
        --
        -- NOT GATED ON `born`, UNLIKE fx/fy/fl ABOVE, AND THE DIFFERENCE IS THE
        -- WHOLE POINT. An origin is a birth EVENT -- replaying it to a player
        -- who arrives later would fly the item out of a hand that is not there
        -- any more. This is a PROPERTY of the entry: the ground under a dropped
        -- gun is still that ground when a stranger walks up ten minutes later,
        -- and if the cell subscription omitted it that stranger would see the
        -- gun on the freeway while the dropper sees it at their feet. It must
        -- also survive the crate-to-husk re-announce for the same reason.
        --
        -- THIS DOES NOT WIDEN WHAT THE CLIENT MAY CLAIM. It travels the other
        -- way: the server is TELLING the client that this one height was
        -- measured rather than guessed. Nothing here reads a `pz` off the wire,
        -- and the repair round-trip below clears it (see the LOOT_FIX handler).
        pz      = e.pz,
    }
end

-- --------------------------------------------------------------------------
-- The registry
-- --------------------------------------------------------------------------

--- Index one entry into its cell.
--- @param loot table
--- @param e table
local function index(loot, e)
    local key = BR.LootCellKeyAt(e.x, e.y)
    e.cell = key
    local cell = loot.cells[key]
    if not cell then
        cell = {}
        loot.cells[key] = cell
    end
    cell[e.id] = true
    loot.items[e.id] = e
end

--- Everyone currently subscribed to a cell.
--- @param m table
--- @param key string
--- @return integer[]
local function subscribersOf(m, key)
    local out = {}
    for src, keys in pairs(m.loot.subs) do
        if keys[key] then out[#out + 1] = src end
    end
    table.sort(out)
    return out
end

--- Announce a new entry to everyone already looking at its cell.
---
--- `born` is what separates "this thing has just come into existence" from the
--- two RE-announces that ride the same message: a container becoming its husk,
--- and an entry whose position the repair round-trip corrected. Only the first
--- is allowed to carry an origin -- see wireEntry.
--- @param m table
--- @param e table
--- @param born boolean|nil
local function announce(m, e, born)
    local payload = { wireEntry(e, born) }
    for _, src in ipairs(subscribersOf(m, e.cell)) do
        TriggerClientEvent(BR.Net.LOOT_ADD, src, payload)
    end
end

--- Remove an entry and tell everyone looking at it.
--- @param m table
--- @param e table
local function retire(m, e)
    local cell = m.loot.cells[e.cell]
    if cell then cell[e.id] = nil end
    m.loot.items[e.id] = nil

    local payload = { e.id }
    for _, src in ipairs(subscribersOf(m, e.cell)) do
        TriggerClientEvent(BR.Net.LOOT_GONE, src, payload)
    end
end

--- Put a stack into the world.
--- @param m table    a match, or the shared warmup zone
--- @param stack table
--- @param x number
--- @param y number
--- @param z number
--- @return table|nil entry
--- @param from table|nil  { x, y, lift } the item visibly travels FROM.
--- `lift` is metres ABOVE THE GROUND, never an absolute z -- only the client
--- can resolve ground height, so an absolute z from here is a guess.
--- @param standZ number|nil  THE ONE EXCEPTION TO THAT LAST SENTENCE, and it is
--- narrow on purpose. Pass the z of ground A PED WAS MEASURED STANDING ON at
--- this same x/y, and nothing else. It is the difference between a height the
--- server guessed and one it observed, and the client uses it to probe from
--- under a bridge instead of from above it (see `pz` in wireEntry).
---
--- DO NOT PASS A HEIGHT FROM A DIFFERENT PLACE THAN x/y. The temptation is
--- landingCrates, which has a real ped z to hand -- but it scatters its crates
--- 55-130m away (config/loot.lua `landing`), and a player who lands in a valley
--- would vouch for a crate on the hillside above them. A probe started below
--- the surface is the 2026-08-23 "loot spawned below the map" bug exactly, and
--- PROBE_FROM_Z exists because of it.
function BR.Loot.spawnStack(m, stack, x, y, z, from, standZ)
    if not m or not m.loot or not stack then return nil end

    m.loot.nextId = m.loot.nextId + 1
    local e = {
        fx = from and from.x or nil,
        fy = from and from.y or nil,
        flift = from and from.lift or nil,
        id     = m.loot.nextId,
        item   = stack.item,
        kind   = stack.kind,
        rarity = stack.rarity,
        count  = stack.count or 1,
        clip   = stack.clip,
        -- HAS THIS BEEN IN SOMEBODY'S HANDS? Set by BR.Inv's `released` on every
        -- stack that leaves an inventory -- a drop, a death, a displaced swap --
        -- and read by BR.Inv.give, which mints a clip's worth of reserve for a
        -- FOUND gun and must not mint one for a gun coming back. It has to
        -- survive the round trip through the world or the fact is lost exactly
        -- where it is needed (owner, 2026-08-23: "when I drop it and pick it
        -- back up it has 1 round in it now"). Nil on all 1300 generated entries,
        -- on every crate's contents and on the airdrop shelf, which is what
        -- keeps found loot arriving loaded.
        --
        -- SERVER-SIDE ONLY, like the three husk fields below: wireEntry does not
        -- carry it, because it is an input to an arbitration the server makes
        -- alone and a client has no use for it and no right to it.
        carried = stack.carried,
        x = x, y = y, z = z,
        -- GROUND A PED WAS MEASURED ON, or nil. Unlike `dropped` below -- which
        -- is on every entry born mid-match and means nothing about height --
        -- this is set by four callers and read by the client's ground probe.
        -- See wireEntry, which is the only thing that sends it.
        pz     = standZ,
        prop   = stack.prop,
        heading = stack.heading,
        contents = stack.contents,
        warmup = stack.warmup,
        dropped = true,
        -- WHAT THIS CONTAINER BECOMES WHEN IT IS OPENED, and how widely its
        -- contents scatter. Both nil for every crate the generator makes --
        -- toHusk and scatter fall back to the config exactly as they always
        -- have -- and set only by the airdrop, whose husk is drawn at a
        -- different size and whose ring holds more items than a crate's.
        --
        -- SERVER-SIDE ONLY. None of these three reach wireEntry: `huskProp` and
        -- `huskItem` become the entry's own `prop` and `item` the moment it is
        -- opened, which is a re-announce the client already handles, and
        -- `spread` has done its work before any of it travels.
        huskItem = stack.huskItem,
        huskProp = stack.huskProp,
        spread   = stack.spread,
        -- WHICH AIRDROP THIS IS, if it is one. Read once, by the claim handler,
        -- to tell br_core/server/airdrop.lua that its crate was opened -- which
        -- is what starts the blip's last minute. A number rather than a
        -- reference so nothing here holds a flight plan.
        airdrop = stack.airdrop,
    }
    index(m.loot, e)
    announce(m, e, true)
    return e
end

--- Turn a sealed crate INTO its opened husk, in place.
---
--- Same id, same position: the client mutates the entry it already holds and
--- swaps one model for another. Retiring the crate and announcing a separate
--- husk entry meant a delete, a network round-trip and a fresh model stream
--- before the open crate appeared -- visibly slow (user, 2026-08-05). One
--- message, one model swap.
---
--- A husk is not loot: it cannot be claimed and it carries no rarity. It is
--- there so a room you have already swept reads as swept from the doorway.
---
--- THE HUSK'S IDENTITY CAN BE THE CRATE'S CHOICE, and for exactly one crate it
--- is. An airdrop's box is drawn at twice the authored size on both sides of the
--- open (owner, 2026-08-22), and the client resolves a prop's scale from its
--- ITEM ID -- so an airdrop husk that called itself 'husk' like the other 1300
--- would shrink back to normal on the frame it was opened. `huskItem` and
--- `huskProp` are unset on every generated crate and the fallbacks below are
--- what those have always used.
--- @param m table
--- @param crate table
local function toHusk(m, crate)
    crate.kind     = 'husk'
    crate.item     = crate.huskItem or 'husk'
    crate.prop     = crate.huskProp or L.chestOpenProp
    crate.rarity   = BR.Rarity.COMMON
    crate.contents = nil
    announce(m, crate)
end

--- Drop a stack at a player's feet. The inventory calls this.
--- @param src integer
--- @param stack table
--- @return table|nil entry
function BR.Loot.dropForPlayer(src, stack)
    local e = BR.Roster.get(src)
    if not e or not e.pos then return nil end
    local m = zoneFor(src)
    if not m then return nil end
    -- FROM THE HAND, not from the floor. The dropped item arcs out of the
    -- player's grip and lands, which is the same movement the crate burst
    -- uses in reverse. e.pos is the ped's ROOT, so waist is an offset up.
    --
    -- AND THE ROOT IS ALSO THE VOUCH (owner, 2026-09-03: an item dropped under
    -- a bridge "goes on the ground on the upper structure and not on the ground
    -- around the ped"). This is the tightest case there is: same x, same y, and
    -- a ped is standing on that exact spot at this exact moment. The last
    -- argument is what stops the client probing the deck overhead -- see `pz`
    -- in wireEntry.
    return BR.Loot.spawnStack(m, stack, e.pos.x, e.pos.y, e.pos.z,
        { x = e.pos.x, y = e.pos.y, lift = L.waistHeight or 0.75 },
        e.pos.z)
end

-- --------------------------------------------------------------------------
-- Lifecycle
-- --------------------------------------------------------------------------

--- Pinned layout seed, for testing. nil = a fresh layout per match.
---
--- Layouts are NOT the same every match by design: the seed folds in the game
--- timer, so two matches never share a map. That is right for play and
--- miserable for debugging, hence /brlootseed.
local pinnedSeed = nil

--- Generate a match's loot.
---
--- Called at WARMUP, not at PLAYING: players land during BUS, and an item that
--- appears the moment the state machine ticks over is an item that was not
--- there when the first player ran past it.
---
--- @param m table
--- @param seed integer|nil
function BR.Loot.begin(m, seed)
    -- Folded with a prime of its own, exactly as the storm (7919) and the bus
    -- (104729) do, so two matches minted in the same server millisecond do not
    -- lay out the same map.
    --
    -- THE FOLD IS `seq`, NOT `id` (#291). All this number has to do is tell two
    -- matches apart inside one millisecond, which `seq` does exactly as well --
    -- and being an increment it keeps this seed the value it has always had.
    -- The random id would have made every layout on the box unreproducible from
    -- one boot to the next, including in the unit tests, where a layout that
    -- differs per run is a suite that fails one time in twenty for no reason.
    seed = seed or pinnedSeed or (GetGameTimer() + m.seq * 15485863)

    m.loot = {
        seed    = seed,
        nextId  = 0,
        items   = {},
        cells   = {},
        subs    = {},
        at      = {},
        respawn = {},
        fixed   = 0,
    }

    local entries, stats = BR.BuildLootLayout(seed)
    for _, e in ipairs(entries) do
        m.loot.nextId = math.max(m.loot.nextId, e.id)
        index(m.loot, e)
    end

    print(('[br_core] loot: match %d seeded %d -- %d items, %d chests, %d filler across %d cells')
        :format(m.id, seed, stats.poi, stats.chest, stats.filler,
                (function()
                    local n = 0
                    for _ in pairs(m.loot.cells) do n = n + 1 end
                    return n
                end)()))
end

--- Forget a match's loot. The clients tear their own props down off the state
--- transition, so there is nothing to un-send here.
--- @param m table
function BR.Loot.clear(m)
    if m then m.loot = nil end
end

--- Scatter a few crates around where a player just landed.
---
--- Generation cannot do this -- it runs at warmup and nobody has picked a drop
--- yet. Dropping into empty countryside and finding nothing is how a player
--- concludes the mode has no loot in it, so the loot comes to them (user call,
--- 2026-08-05).
---
--- Deliberately NOT within sight of the landing point: the inner radius puts
--- them past what the eye takes in on touchdown, so it reads as a lucky drop
--- zone rather than as crates raining down around you.
---
--- Once per player per match.
--- @param src integer
function BR.Loot.landingCrates(src)
    local e = BR.Roster.get(src)
    if not e or not e.pos or e.landingLoot then return end

    local m = BR.Server.matchOf(src)
    if not m or not m.loot then return end

    e.landingLoot = true

    local cfg = L.landing
    if not cfg or (cfg.crates or 0) <= 0 then return end

    -- The MATCH's rng, so a replayed seed replays these too.
    m.loot.rng = m.loot.rng or BR.Rng(m.loot.seed + 7717)
    local rng = m.loot.rng

    for _ = 1, cfg.crates do
        local placed = false
        for _ = 1, 6 do
            local a = rng:float() * math.pi * 2.0
            local r = cfg.minRadius
                + rng:float() * math.max(1.0, cfg.maxRadius - cfg.minRadius)
            local x = e.pos.x + math.cos(a) * r
            local y = e.pos.y + math.sin(a) * r
            if BR.LootPlaceable(x, y) then
                local crate = BR.MakeCrate(rng, cfg.tier or 2, x, y, e.pos.z)
                BR.Loot.spawnStack(m, crate, x, y, e.pos.z)
                placed = true
                break
            end
        end
        local _ = placed
    end
end

-- --------------------------------------------------------------------------
-- The shared warmup zone
-- --------------------------------------------------------------------------

-- ONE LAYOUT FOR EVERYBODY WAITING. The warmup pad is a COMMUNAL routing
-- bucket -- every concurrent match's warmup players stand on it together --
-- so a per-match layout would put two players side by side looking at
-- different crates in the same spot.
--
-- It is a pseudo-match: same `loot` shape, so every function above operates on
-- it unchanged. Id 0, which no real match can have -- BR.Match.mintIds never
-- issues it (#291), and this line is the reason it never will -- so a stray
-- lookup cannot collide.
local warmupZone = nil

--- [src] = the loot registry this player is currently subscribed to (a match
--- id, or 0 for the shared warmup pad). Crossing between them invalidates
--- every id the client is holding.
local zoneOf = {}

--- The shared warmup zone, built on first use.
--- @return table
local function warmup()
    if warmupZone then return warmupZone end

    local W = BR.Config.Loot.warmup
    warmupZone = {
        id     = 0,
        warmup = true,
        state  = BR.MatchState.WARMUP,
        loot   = {
            seed = GetGameTimer(), nextId = 0, items = {}, cells = {},
            subs = {}, at = {}, respawn = {}, fixed = 0,
        },
    }
    warmupZone.rng = BR.Rng(warmupZone.loot.seed + 5779)

    for _, e in ipairs(BR.BuildWarmupLayout(warmupZone.loot.seed)) do
        warmupZone.loot.nextId = math.max(warmupZone.loot.nextId, e.id)
        index(warmupZone.loot, e)
    end

    print(('[br_core] loot: warmup pad stocked with %d crates (shared)')
        :format(W.crates or 0))
    return warmupZone
end

--- Which loot registry this player is looking at.
---
--- A WARMUP player sees the shared island; everyone else sees their own
--- match. This is the single place that decision is made -- every handler
--- below goes through it, so there is no path where a warmup player can reach
--- a match's items or the reverse.
--- @param src integer
--- @return table|nil zone
zoneFor = function(src)
    local e = BR.Roster.get(src)
    if not e then return nil end
    if e.state == BR.PlayerState.WARMUP then return warmup() end
    local m = BR.Server.matchOf(src)
    if m and m.loot then return m end
    return nil
end

-- ═══ THE THREE DOORS INTO THIS REGISTRY, AND WHO USES THEM ═══
--
-- br_core/server/warmupcrates.lua owns four containers on the island that reset
-- themselves forever (owner, 2026-09-04). It is a separate file because none of
-- its behaviour belongs to world loot -- but it has to put its crates in the
-- SAME registry every other warmup crate lives in, or they could not be opened:
-- the claim handler resolves a player's zone through zoneFor() above, and an
-- entry outside that zone is an entry it will never find.
--
-- So these three are exports of things this file already does, and each one is
-- here rather than reimplemented over there for a reason worth naming:
--
--   * warmupZone   The zone is a LOCAL built on first use. A second copy of the
--                  "is this player on the pad" decision is the drift that
--                  BR.Config.LootVisibleStates was created to end.
--   * remove       Retiring an entry is three table writes and a message to
--                  everyone subscribed to its cell. Two of those are private
--                  bookkeeping (`cells`, `items`) and the third has to reach the
--                  same set of players `announce` reaches.
--   * reannounce   Re-sending a MUTATED entry -- which is what a husk becoming
--                  a sealed crate again is -- has to go out in the wire shape
--                  wireEntry() defines. That shape has grown three fields this
--                  month (`fx`/`fy`/`fl`, then `pz`), and a second writer of it
--                  would have been wrong twice already.
--
-- NOTHING NEW HAPPENS HERE. These add no capability the loot system did not
-- have; they name three existing ones so exactly one implementation of each
-- survives. `born` is deliberately not exposed: an origin is a birth event
-- (see wireEntry), and a reset is the opposite of a birth.

--- The shared warmup zone, built on first use.
---
--- CALLING THIS BUILDS THE ISLAND LAYOUT if nobody has yet. That is a change of
--- TIMING and not of behaviour -- the 220 crates were always going to be built
--- the moment the first player subscribed to a pad cell -- and it is why the
--- warmup crates place themselves off a scheduler tick rather than at load: the
--- tick runs after every server file has finished loading, so BR.Config and
--- BR.Rng are certainly there when the layout is generated.
--- @return table zone
function BR.Loot.warmupZone()
    return warmup()
end

--- Retire one entry from a zone and tell everyone looking at it.
--- @param m table
--- @param e table
function BR.Loot.remove(m, e)
    if not m or not m.loot or not e then return end
    retire(m, e)
end

--- Re-send an entry whose fields have just changed in place.
---
--- The mutation is the caller's; this is only the wire. Same id, same position:
--- the client mutates the entry it already holds -- see the note on toHusk, and
--- the `reskinned` branch of addEntries in br_core/client/loot.lua, which is
--- what makes the model swap instant in either direction.
--- @param m table
--- @param e table
function BR.Loot.reannounce(m, e)
    if not m or not m.loot or not e then return end
    announce(m, e)
end

-- --------------------------------------------------------------------------
-- Streaming
-- --------------------------------------------------------------------------

--- The entries a player should be holding right now, for the snapshot.
--- @param src integer
--- @return table|nil
function BR.Loot.viewFor(src)
    local e = BR.Roster.get(src)
    if not e or not CAN_SEE[e.state] then return nil end
    local m = zoneFor(src)
    if not m then return nil end

    local keys = m.loot.subs[src]
    if not keys then return nil end

    local out = {}
    for key in pairs(keys) do
        for id in pairs(m.loot.cells[key] or {}) do
            local entry = m.loot.items[id]
            if entry then out[#out + 1] = wireEntry(entry) end
        end
    end
    -- Sorted: a snapshot is compared against by tests, and an unordered one
    -- would be a different payload every run.
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

--- How often one player may ask for a full re-seed of their 3x3 block.
---
--- TWO SECONDS. A genuine recovery needs one; the client only asks when it is
--- holding nothing at all, and the first answer fixes that. Anything faster is
--- somebody hammering a rebuild-and-send, which is the only cost this path has.
local RESYNC_MS = 2000

RegisterNetEvent(BR.Net.LOOT_CELL)
AddEventHandler(BR.Net.LOOT_CELL, function(d)
    local src = source
    if type(d) ~= 'table' then return end

    local cx = math.tointeger(d.cx)
    local cy = math.tointeger(d.cy)
    if not cx or not cy then return end

    local e = BR.Roster.get(src)
    if not e or not CAN_SEE[e.state] then return end
    local m = zoneFor(src)
    if not m then return end

    -- CROSSING BETWEEN THE PAD AND A MATCH is not a cell move, it is a new
    -- world. Ids mean different things in the two registries, so the old
    -- subscription is dropped whole (the client is told to forget those ids)
    -- rather than diffed against the new one.
    if zoneOf[src] ~= m.id then
        local prev = zoneOf[src] == 0 and warmupZone or BR.Server.matchById(zoneOf[src])
        if prev and prev.loot then
            local stale = {}
            for key in pairs(prev.loot.subs[src] or {}) do
                for id in pairs(prev.loot.cells[key] or {}) do
                    stale[#stale + 1] = id
                end
            end
            prev.loot.subs[src] = nil
            prev.loot.at[src] = nil
            if #stale > 0 then TriggerClientEvent(BR.Net.LOOT_GONE, src, stale) end
        end
        zoneOf[src] = m.id
    end

    -- YOU MAY SUBSCRIBE TO THE CELL YOU ARE STANDING IN, AND ITS NEIGHBOURS.
    --
    -- The rule and the reasoning live in BR.LootCellReachable, because the
    -- arithmetic is worth testing and this handler is not. In short: without it a
    -- client could name any cell in the plane and be streamed it, which hands out
    -- the whole layout and makes withholding the seed pointless.
    --
    -- REFUSED SILENTLY, and after the zone-crossing block above rather than
    -- before it. The crossing is a correction to state that has already happened
    -- -- the player really is somewhere else -- so it must run even when the cell
    -- they asked for is wrong. Dropping the request here leaves them with no
    -- subscription in the new zone until their next call, which their own client
    -- makes on the next move, and the 5s loot.sweep cleans up regardless.
    --
    -- No notify: an honest client cannot produce this, and a dishonest one is
    -- being told which of its requests were noticed.
    if not e.pos then return end

    -- ═══ JUDGED AGAINST WHERE THEY ARE, NOT WHERE WE LAST LOOKED ═══
    --
    -- `e.pos` is the roster's own sample, taken at posSampleHz (4/s) off the
    -- replicated ped, so it lags a teleport by up to 250ms -- and a ready-up is
    -- exactly a teleport. The client subscribes from the LOBBY first (that
    -- request succeeds), the ped is moved to the pad, the client asks again from
    -- the pad within 100ms, and this test still saw the lobby. Lobby to pad is
    -- two cells and the drift tolerance is one, so the second request was
    -- refused -- silently, permanently, because the client latches `myCell`
    -- before it sends and only ever asks again on a cell EDGE.
    --
    -- That was the whole of the owner's report (2026-09-07): "the crates don't
    -- spawn until I go outside their near proximity and back in", with /brloot
    -- showing `cell 17,-18  entries 0` while standing on the pad. Walking out of
    -- the cell and back is a new edge, by which time the sample had caught up.
    --
    -- THE LIVE READ IS STRICTER, NOT LOOSER. It is the same rule -- you may
    -- subscribe only near where you are -- asked of the truth rather than of a
    -- quarter-second-old copy. The cached sample stays the fallback for the
    -- moments a ped is not resolvable.
    -- EITHER READING MAY SATISFY IT, AND THAT IS DELIBERATELY A SUPERSET OF THE
    -- OLD RULE. Narrowing on the live position would refuse requests the sample
    -- accepts today -- a player who asked while moving away -- and this is a
    -- bug fix, not a tightening. An attacker still has to be within one cell by
    -- one of two readings of their OWN position, which is the property
    -- BR.LootCellReachable exists to enforce.
    local ok = BR.LootCellReachable(cx, cy, e.pos.x, e.pos.y)

    if not ok then
        local ped = GetPlayerPed(src)
        -- `ped ~= 0` IS THE EXISTENCE TEST. DoesEntityExist answers 1/0 and 0 is
        -- TRUTHY in Lua, so `if DoesEntityExist(ped) then` is true for a ped
        -- that is not there -- the trap tools/verify.sh keeps a ratchet for.
        if ped and ped ~= 0 then
            local live = GetEntityCoords(ped)
            if live and live.x then
                ok = BR.LootCellReachable(cx, cy, live.x, live.y)
            end
        end
    end

    if not ok then return end

    -- ═══ AND A CLIENT THAT HAS LOST EVERYTHING MAY SAY SO ═══
    --
    -- The dedupe below is doing a real job at 10Hz and stays. What it could not
    -- tell apart was a duplicate request from a client that still holds the cell
    -- and one from a client whose registry was dropped underneath it --
    -- `forgetAll` runs whenever the player leaves a loot-visible state, which a
    -- match dissolving under them does, and the server keeps the subscription it
    -- already recorded. `resync` is the client saying "I have nothing".
    --
    -- RATE-LIMITED, because it is a request to rebuild and send a 3x3 block. Once
    -- every RESYNC_MS per player is far more than a genuine recovery needs and
    -- far less than a spammer would want.
    local centre = BR.LootCellKey(cx, cy)

    if d.resync == true then
        local now = GetGameTimer()
        local last = m.loot.resyncAt and m.loot.resyncAt[src] or 0
        if now - last >= RESYNC_MS then
            m.loot.resyncAt = m.loot.resyncAt or {}
            m.loot.resyncAt[src] = now
            -- Forget what we think they have, so the "entering scope" walk below
            -- treats every cell as new and sends the lot.
            m.loot.subs[src] = nil
            m.loot.at[src] = nil
            print(('[br_core] loot: %s (%d) asked to re-seed %s')
                :format(e.name, src, centre))
        end
    end

    if m.loot.at[src] == centre then return end   -- nothing moved
    m.loot.at[src] = centre

    local want = {}
    for _, key in ipairs(BR.LootCellsAround(cx, cy)) do want[key] = true end

    local had = m.loot.subs[src] or {}

    -- Entering scope.
    local adds = {}
    for key in pairs(want) do
        if not had[key] then
            for id in pairs(m.loot.cells[key] or {}) do
                local entry = m.loot.items[id]
                if entry then adds[#adds + 1] = wireEntry(entry) end
            end
        end
    end

    -- Leaving it.
    local gone = {}
    for key in pairs(had) do
        if not want[key] then
            for id in pairs(m.loot.cells[key] or {}) do
                gone[#gone + 1] = id
            end
        end
    end

    m.loot.subs[src] = want

    if #adds > 0 then TriggerClientEvent(BR.Net.LOOT_ADD, src, adds) end
    if #gone > 0 then TriggerClientEvent(BR.Net.LOOT_GONE, src, gone) end
end)

-- --------------------------------------------------------------------------
-- Claims
-- --------------------------------------------------------------------------

--- The two numbers inReach refuses on, named rather than inline because
--- BR.Loot.inspect PRINTS them. A diagnostic carrying its own copy of the
--- bound it is reporting on is a diagnostic that lies at exactly the moment it
--- matters -- when the rule has moved and the reader has not.
local REACH_SLACK = 4.0
local REACH_Z     = 12.0

--- Is this player close enough to that entry to have taken it?
---
--- The position being compared is the roster's own 4Hz sample, so it can be
--- half a second stale -- a sprinting player covers ~3.5m in that time, which
--- is the entire pickup radius. Without a slack term the honest claims of
--- anyone moving get refused, which is the same class of skew the storm's edge
--- cushion exists for, and the same fix.
--- @param e table roster entry
--- @param item table
--- @return boolean
local function inReach(e, item)
    if not e.pos then return false end
    local d = BR.Dist(e.pos.x, e.pos.y, item.x, item.y)
    if d > (L.pickupDistance + REACH_SLACK) then return false end

    -- THE HEIGHT CHECK ONLY APPLIES TO A HEIGHT WE ACTUALLY KNOW.
    --
    -- An entry's z is the POI's NOMINAL height until a client ground-probes
    -- it, and those are authored from map knowledge -- tens of metres out on
    -- any slope, and a flat 0.0 for roadside filler. Comparing a real player
    -- z against that refused most legitimate pickups: the first crate you
    -- reached happened to be near its nominal height, and every one after
    -- that answered "Too far away" (user, 2026-08-05).
    --
    -- Once repaired, the z IS the ground under it, so the check is worth
    -- having again: it stops someone on the floor above claiming the rifle
    -- downstairs.
    if item.repaired then
        return math.abs((e.pos.z or 0.0) - (item.z or 0.0)) < REACH_Z
    end
    return true
end

--- Token-bucket rate limit on claims.
--- @param e table roster entry
--- @return boolean allowed
local function rateOk(e)
    local now = GetGameTimer()
    if not e.lootWindow or now - e.lootWindow >= 1000 then
        e.lootWindow, e.lootClaims = now, 0
    end
    e.lootClaims = e.lootClaims + 1
    return e.lootClaims <= (L.pickupRateLimit or 4)
end

--- Where a container's contents land, relative to it.
---
--- SPILLED, NOT ARRANGED (owner, 2026-08-23: "the loot doesn't need to be
--- spread equidistant from the crate"). What was here was `(i / n) * 2pi` at
--- one fixed radius: every item on an even ring at an identical distance, which
--- reads as an inventory laid out for inspection rather than as a box that
--- burst.
---
--- THE OLD CONSTRAINTS SURVIVE INTACT, because they are the reason the ring was
--- a ring in the first place:
---
---   VISIBLE AND REACHABLE. Nothing is ever thrown FURTHER than the ring it
---     replaces -- the radius factors are all <= 1.0 -- and nothing lands
---     closer to the box than `scatterClearance`, which is what stops an item
---     ending up inside the container prop where it can be neither seen nor
---     targeted.
---
---     AND THAT BOUND IS WHY THIS CANNOT DISTURB THE GROUND PLACEMENT (owner,
---     2026-08-23: "We have loot properly landing on the ground today. Nothing
---     should change there"). Every position this produces is strictly INSIDE
---     the disc the old ring's items already sat on -- the ring sat exactly on
---     its rim -- so no item is offered a patch of terrain the old layout was
---     not already willing to put one on. Nothing here touches z at all: the
---     caller still passes the container's own, and only the CLIENT resolves a
---     real ground height (groundZ, then PlaceObjectOnGroundProperly), with the
---     LOOT_FIX round-trip unchanged behind it. A container on a roof spills
---     onto that roof, which is the answer the ring gave too.
---
---   EVERYONE SEES THE SAME ARRANGEMENT. Not by luck: the offsets come out of
---     BR.Rng seeded from the match's own layout seed and the CONTAINER'S ID,
---     both fixed for the life of the entry. math.random would have been just
---     as identical across clients (this runs on the server, once, and the
---     positions are what travel) and still wrong -- the layout has to replay
---     from a seed for /brlootseed to mean anything, and an unseeded roll would
---     make the same pinned seed lay out differently on the second run.
---
--- NOTHING STACKS INSIDE ANYTHING ELSE, which was the ring's other quiet job
--- and the whole reason the airdrop had to name a wider spread. Each item keeps
--- its own angular wedge and wanders only inside it, and the radius alternates
--- between an inner and an outer band by index, so two neighbours are never
--- both pushed in. Swept over 50,000 seeds at every size a container can hold,
--- the closest any pair lands is 1.07m (a 3-item crate) and 1.44m at the
--- airdrop's fourteen -- an ammo box is about a third of a metre across.
---
--- The numbers below were measured rather than guessed, and the ANGULAR one is
--- the sensitive one: at +/- 0.28 of a wedge that worst pair fell to 0.90m,
--- because a wide swing is a small chord once an item is also on the inner
--- band. Widen it again and re-measure before believing otherwise.
--- @param seed integer
--- @param n integer
--- @param radius number   the old ring's radius: the OUTER bound, not a target
--- @return table[]        n entries of { dx, dy }
local function spill(seed, n, radius)
    local rng = BR.Rng(seed)
    local clearance = L.scatterClearance or 0.7
    local wedge = (math.pi * 2.0) / n
    local out = {}
    for i = 1, n do
        -- The wedge this item owns, and how far inside it it may wander:
        -- +/- 0.22 of a wedge, which leaves 56% of the gap between any two
        -- neighbours untouched.
        local a = (i - 0.5) * wedge + (rng:float() - 0.5) * (wedge * 0.44)
        -- Two bands by index, so adjacent items are never on the same one.
        -- Floored rather than rescaled, because the alternative -- mapping both
        -- bands into the annulus above the clearance -- lets an item sit
        -- exactly ON the clearance, and two of those at a shallow angle are the
        -- closest pair the whole scheme can produce.
        local lo, hi = 0.82, 1.0
        if i % 2 == 0 then lo, hi = 0.52, 0.70 end
        local r = math.max(clearance, radius * (lo + (hi - lo) * rng:float()))
        out[i] = { dx = math.cos(a) * r, dy = math.sin(a) * r }
    end
    return out
end

--- Scatter a container's contents on the ground around it.
--- @param m table
--- @param container table
local function scatter(m, container)
    local contents = container.contents or {}
    local n = #contents
    if n == 0 then return end

    -- THE CONTAINER MAY NAME ITS OWN SPREAD, and only the airdrop does: fourteen
    -- items on a crate's ring stack inside each other, which is what
    -- BR.Config.Airdrop.scatterSpread exists to widen. Unset everywhere else, so
    -- every ordinary crate and death box uses the number it always has -- and
    -- the spill above still treats whatever comes out as its OUTER bound, so a
    -- wider airdrop stays exactly as wide as it was.
    local spread = container.spread or L.deathBoxSpread or 0.8
    local radius = math.max(spread, 0.55 * n * spread)
    -- Everything comes OUT OF THE BOX, a little above its base, so the client
    -- can arc it rather than popping it into existence at the scatter point.
    local from = {
        x = container.x, y = container.y,
        lift = L.crateMouthHeight or 0.6,
    }
    -- The match layout's seed folded with the container's id and a prime of its
    -- own -- the same shape BR.Loot.begin uses -- so two containers opened in
    -- one match do not spill identically.
    local seed = (m.loot.seed or 0) + (container.id or 0) * 2654435761
    for i, o in ipairs(spill(seed, n, radius)) do
        BR.Loot.spawnStack(m, contents[i],
            container.x + o.dx,
            container.y + o.dy,
            container.z, from)
    end
end

-- --------------------------------------------------------------------------
-- WHY A REFUSED CLAIM TALKS (#171)
--
-- Owner, 2026-08-17: "If I'm already holding the max amount of something and
-- try to pickup another, show me a toast that says 'you cannot carry more
-- shields' for example."
--
-- The refusal existed and the message did not reach him, in two different ways.
--
--   * `carrymax` DID notify -- and built its sentence from
--     BR.Config.ConsumableById alone. A THROWABLE lives in
--     BR.Config.WeaponById, so a player holding three grenades got
--     "You can only carry 0 of thoses." Both halves wrong: the cap and the
--     name.
--   * everything else in the chain either had no branch (`noinv`) or had a
--     branch for a reason BR.Inv.give has never returned (`full`). A reason
--     with no branch is SILENT, and a silent refusal is indistinguishable
--     from a broken key -- the rule the bus jump handler earned and #129 then
--     spent seven rounds relearning.
--
-- So the chain is gone. There is a table with a DEFAULT under it, which is the
-- only shape in which a reason added later cannot arrive silent.
--
-- AND THEN A SECOND ROUND, BECAUSE SPEAKING IS NOT THE SAME AS BEING TRUE
-- (owner, 2026-08-18, after playtest). Once every refusal had a sentence, the
-- one that had been silent turned out to be saying the wrong thing: `sameitem`
-- announced a MAXIMUM, and it was neither a maximum nor global.
--
-- ONE SENTENCE PER QUESTION, and there are two questions:
--
--   HAVE I REACHED MY LIMIT?  -- `carrymax`, and only `carrymax`. Asked of the
--     WHOLE inventory (BR.Inv.give counts every slot) and asked only of items
--     that have a limit at all (BR.Inv.carryMax returns nil, not zero, for the
--     ones that do not). It is the one sentence entitled to quote a number.
--
--   CAN THIS GO WHERE I AM STANDING?  -- `sameitem`. One slot, no ceiling
--     involved, and an item the player is perfectly entitled to more of. It
--     offers the remedy instead of a verdict.
--
-- Merging those two is what reopened this issue. Anything added below that
-- reads like a limit should be checked against BR.Inv.carryMax before it is
-- allowed to say so.
-- --------------------------------------------------------------------------

--- "No, and the reason is not worth a sentence of its own."
---
--- ONE LITERAL, THREE READERS (owner, 2026-08-18: "These inventory messages are
--- just wrong"). This sentence was written out three times -- the `noinv` entry
--- below, the fallback at the end of refusalText, and the state check in the
--- claim handler -- and three copies of one sentence is a wording change that
--- half-lands: two of them move and the third keeps saying the old thing to
--- whichever player happens to hit that branch.
local REFUSED = 'You cannot pickup that item right now.'

--- What a refused claim says, by reason.
---
--- TWO REASONS ARE DELIBERATELY ABSENT. `carrymax` and `sameitem` both have to
--- NAME THE ITEM -- and `carrymax` its cap as well -- so they are built in
--- refusalText, where the config lookup lives. Everything that can be said
--- without knowing what was picked up is said here.
local REFUSAL = {
    ammofull = 'Already carrying the maximum.',
    -- BR.Inv.of could not find a roster entry. Not reachable from this handler
    -- today -- it checks the roster several lines earlier -- and listed anyway,
    -- because "unreachable" is a fact about the caller and this table is about
    -- the reason. It cost nothing and it was silent.
    noinv    = REFUSED,
}

--- What to call this item, one of it.
---
--- Three tables and a fallback, in the same order pluralOf walks them, because
--- an item id can be a consumable, a weapon or throwable, or an ammo pool and
--- the sentence has no way to know which. The last line is the one that
--- matters: a refusal that renders `nil` into its own text is worse than the
--- refusal it replaced.
--- @param stack table|nil
--- @return string
local function labelOf(stack)
    local id = stack and stack.item
    local c = id and BR.Config.ConsumableById[id]
    if c then return c.label or 'item' end
    local w = id and BR.Config.WeaponById[id]
    if w then return w.label or 'item' end
    local a = id and BR.Config.AmmoPickups[id]
    if a then return a.label or 'item' end
    return 'item'
end

--- What to call this item when there is more than one of it.
---
--- THE CONFIG'S OWN NAME (see `plural` in br_lib/config/loot.lua), so the
--- sentence is authored where the item is rather than assembled here. The
--- fallback forms a regular plural, which is right for every name in the game
--- today -- including every throwable, whose config is the weapon table.
--- @param stack table|nil
--- @return string
local function pluralOf(stack)
    local id = stack and stack.item
    local c = id and BR.Config.ConsumableById[id]
    if c then return c.plural or ((c.label or 'item') .. 's') end
    local w = id and BR.Config.WeaponById[id]
    if w then return w.plural or ((w.label or 'item') .. 's') end
    local a = id and BR.Config.AmmoPickups[id]
    if a then return a.label or 'of those' end
    return 'of those'
end

--- The sentence a refused claim produces. Never empty, for any reason.
---
--- PUBLIC SO IT CAN BE TESTED WITHOUT A CLAIM. The property worth pinning is
--- not "carrymax says the right thing" -- it is "NO reason produces silence",
--- and that one is only provable by handing it a reason nobody has written a
--- branch for.
--- @param reason string|nil
--- @param stack table|nil  the entry that was refused, for the name and the cap
--- @return string
function BR.Loot.refusalText(reason, stack)
    if reason == 'carrymax' then
        -- THE CAP COMES FROM THE INVENTORY, not from a config field guessed at
        -- here. BR.Inv.carryMax is the same function BR.Inv.give tested
        -- against to refuse this in the first place, so the number in the
        -- message cannot disagree with the number that produced it.
        local cap = BR.Inv.carryMax(stack)
        -- NO CAP, NO NUMBER. An item with no ceiling cannot produce this
        -- reason today, so this branch is defensive -- but "You cannot carry
        -- more than 0 Small Shields" is exactly the kind of sentence the old
        -- "0 of thoses" was, and printing a zero because a lookup came back
        -- empty is how that one got shipped in the first place.
        if not cap or cap <= 0 then
            return ('You cannot carry more %s.'):format(pluralOf(stack))
        end
        return ('You cannot carry more than %d %s.'):format(cap, pluralOf(stack))
    end

    -- THE LIKE-FOR-LIKE REFUSAL, WHICH IS NOT A LIMIT AND NO LONGER TALKS LIKE
    -- ONE (#171, reopened -- owner, 2026-08-18: "the 'you cannot pickup any
    -- more X' notification should really only appear if I'm actively holding an
    -- item id that has a maximum, and I've reached my maximum already").
    --
    -- IT SAID "You cannot pickup any more %s." AND THAT SENTENCE WAS TWO LIES
    -- AT ONCE. It announced a maximum for an SNS Pistol, which has never had
    -- one -- weapons have no carryMax and BR.Inv.carryMax returns nil for every
    -- one of them. And it announced that maximum off the ACTIVE SLOT, so the
    -- player who took it at face value learned the ceiling was three shields,
    -- switched to slot 4, and picked up three more. A per-slot rule wearing a
    -- global sentence teaches the player a limit that does not exist.
    --
    -- WHAT IS ACTUALLY TRUE HERE is that the inventory is full and the one slot
    -- a swap may spend holds this same item -- so spending it would trade a
    -- stack of three for a pickup of one, or a loaded magazine for a floor
    -- copy's. The player may still have more of this item; they just cannot
    -- have it HERE. So the sentence is the way out rather than a verdict, and
    -- it is the way out the owner found for himself: change slots.
    --
    -- SINGULAR, AND "another". `pluralOf` belongs to the carrymax sentence,
    -- which counts; this one names a single item and dodges the a/an problem
    -- that "a SNS Pistol" would otherwise walk into. labelOf falls back three
    -- times for the same reason pluralOf does -- "You can only carry 0 of
    -- thoses." was born of a lookup that came back empty.
    if reason == 'sameitem' then
        return ('Switch slots to pick up another %s.'):format(labelOf(stack))
    end

    return REFUSAL[reason] or REFUSED
end

RegisterNetEvent(BR.Net.LOOT_CLAIM)
AddEventHandler(BR.Net.LOOT_CLAIM, function(d)
    local src = source
    if type(d) ~= 'table' then return end

    local id = math.tointeger(d.id)
    if not id then return end

    local e = BR.Roster.get(src)
    if not e then return end
    local m = zoneFor(src)
    if not m then return end

    if not CAN_TAKE[e.state] then
        -- The same literal the reason table falls back to. This one is not a
        -- BR.Inv.give reason -- it never gets that far -- but the player is
        -- being told the same thing, so it is told with the same words.
        BR.Server.notify(src, REFUSED, 'warn')
        return
    end

    if not rateOk(e) then
        -- Not announced to the player: at four claims a second this is either
        -- a stuck key or a script, and neither deserves a toast per frame.
        print(('[br_core] loot: %s (%d) is claiming faster than %d/s -- refused')
            :format(e.name, src, L.pickupRateLimit or 4))
        return
    end

    -- FIRST CLAIM WINS, and the loser hears about it. This is the whole
    -- arbitration: the entry is gone from the table before anything else
    -- happens, so a second claim in the same tick finds nothing.
    local item = m.loot.items[id]

    -- AN ENTRY YOU WERE NEVER STREAMED ANSWERS EXACTLY LIKE ONE THAT IS GONE,
    -- and the identical answer is the whole point of this block.
    --
    -- LOOT_FIX has always checked the subscription before trusting a repair. This
    -- handler never did, and the cost was not that unseen entries could be taken
    -- -- inReach's 7.5m already stopped that -- but that the three replies below
    -- were DISTINGUISHABLE. A dead id said "someone beat you to it", a live one
    -- out of reach said "too far away", and a looted crate said nothing at all.
    -- Over a dense sequential id space at four claims a second, that is a working
    -- existence-and-kind oracle over the layout: probe the range, learn how much
    -- loot is left and which crates have been opened, without going near any of
    -- it.
    --
    -- Folding "not yours to see" into "already gone" collapses the oracle, and it
    -- is also the honest answer: from any legitimate client's point of view an
    -- entry outside its view and an entry that no longer exists are the same
    -- thing. Cells are 256m and the subscription is the 3x3 block around the
    -- player, so anything within pickup range is certainly inside it -- this
    -- cannot refuse a claim an honest client would make.
    --
    -- ⚠ THAT LAST SENTENCE WAS FALSE FOR AS LONG AS A SUBSCRIPTION COULD BE
    -- LOST WITHOUT THE CLIENT KNOWING. It assumes the client's view and the
    -- server's record of it agree, and until 2026-09-07 they could silently
    -- diverge: the cell request was latched before it was sent, declined without
    -- a reply, and never re-asked until the player crossed a cell boundary. A
    -- player standing on the warmup pad with a sealed crate on screen, holding
    -- E on it, got THIS sentence for a crate nobody had touched -- owner: "what
    -- does 'someone beat you to it' even mean when trying to open these
    -- crates..... wtf lol".
    --
    -- The recovery re-ask in client/loot.lua and the live-position test in the
    -- LOOT_CELL handler are what make the sentence true again. The branch is
    -- left exactly as it was on purpose: the ambiguity is anti-oracle design,
    -- and the fix for an honest client reaching it is to stop it happening
    -- rather than to explain it better.
    local subs = m.loot.subs[src]
    if item and not (subs and subs[item.cell]) then item = nil end

    if not item then
        BR.Server.notify(src, 'Someone beat you to it.', 'warn')
        return
    end

    if not inReach(e, item) then
        -- "TOO FAR AWAY" IS GONE, EVERYWHERE, WITH NO EXCEPTIONS.
        --
        -- This is a straight one-for-one replacement of that sentence and it is
        -- deliberately NOT conditional on kind. An earlier version said this
        -- only for chests and kept the distance answer for everything else, on
        -- the reasoning that for a deathbox or a dropped rifle the distance is
        -- at least TRUE. The owner overruled it (2026-08-21): "Players have no
        -- idea what 'Too far away' means without any context or awareness as to
        -- the expected/actual positions of crates etc. So something that is more
        -- meaningful to them, even if not technically true, is less confusing."
        --
        -- THE MESSAGE BEING LITERALLY TRUE IS NOT THE PROPERTY THAT MATTERS. A
        -- player cannot see the registry position, so "too far away" reads as
        -- nonsense whenever it fires -- and it can only fire when the client's
        -- idea of where the entry is and the server's have diverged, since the
        -- client only offers the prompt within pickupDistance and this accepts
        -- within pickupDistance + REACH_SLACK, which is wider. A sentence that
        -- tells them to stop trying is more use than one that tells them to walk
        -- closer to something they are already touching.
        --
        -- IT DOES NOT FIX THE DIVERGENCE and is not meant to; #198 carries the
        -- mechanism and the designed fix.
        --
        -- AND IT LEAKS NOTHING, which in this handler always deserves the
        -- question -- see the oracle argument above. Being kind-independent, it
        -- is strictly less distinguishing than the version it replaced.
        BR.Server.notify(src,
            'This crate has a lock on it and cannot be opened.', 'warn')
        return
    end

    if item.kind == 'husk' then
        -- AN ALREADY-LOOTED CRATE. Silent, and pinned as silent by
        -- tools/test_ringmaster.lua (loot.chest.husk, loot.chest.race) on the
        -- stated grounds that "the client already refuses to target a husk, so
        -- an honest player never produces this claim".
        --
        -- THAT RATIONALE IS WRONG, AND #171 IS NOT THE PLACE TO ACT ON IT.
        -- The client refuses to TARGET a husk, which is not the same as
        -- refusing to CLAIM one: a container hold, once started, is never
        -- re-tested against the entry's kind. loot.render's hold block ends the
        -- hold for exactly three reasons -- the entry vanished, the player
        -- walked out of reach, the key came up -- and a sealed crate that
        -- becomes a husk mid-hold satisfies none of them, because addEntries
        -- MUTATES THE ENTRY IN PLACE and the id survives. So a player standing
        -- inside 3.5m who loses a race by a tick holds the key for a full
        -- second, watches the ring fill, and gets nothing at all.
        --
        -- Left alone deliberately: the message is half a fix. The other half is
        -- ending the hold on the frame the crate opens, which belongs in
        -- br_core/client/loot.lua, changes what the audit above pins, and wants
        -- an issue of its own rather than a rider on the floor-pickup one.
        return
    end

    if item.kind == 'volts' then
        -- VOLTS ARE NOT AN INVENTORY ITEM (owner, 2026-08-21: "This should be an
        -- item that does not go into inventory - they simply pick it up and it's
        -- gone. Simple notification that they collected 100 Volts, and that's
        -- it."). So the entry is retired and BR.Inv.give is never reached --
        -- there is no slot to find, nothing to displace, and no refusal that
        -- could leave the pile on the floor.
        --
        -- AND THIS IS NOT A WRITE. It increments a counter on the roster entry;
        -- the number rides the match results envelope into
        -- BR.Config.marketPayout and lands in the SAME atomic ADD as the match
        -- payout. config/market.lua's "exactly one writer that can increase a
        -- balance" is the property the whole no-pay-to-win argument rests on,
        -- and #88 asked for it to stay intact by name. Crediting here would have
        -- been a second writer and a per-pickup write on a personally-funded
        -- database, for a number the player is told about either way.
        --
        -- THE AMOUNT COMES OFF THE ENTRY, not off the config. The entry is what
        -- the server generated and holds; reading the config here would let a
        -- retune mid-match pay a different number from the one the pile was
        -- created as.
        local n = math.tointeger(item.count) or 0
        if n > 0 then
            e.voltsPickedUp = (e.voltsPickedUp or 0) + n
        end
        retire(m, item)

        -- ═══ IT SOUNDS LIKE A PICKUP BECAUSE IT IS ONE ═══
        --
        -- Owner, 2026-08-28: "picking up volts doesn't make a sound - it should
        -- make the same sound as picking up an inventory item."
        --
        -- The pickup cue lives on the INVENTORY path (client/inventory.lua
        -- plays L.pickupSound when a slot gains something), and Volts
        -- deliberately never enter the inventory -- owner, 2026-08-21: "they
        -- simply pick it up and it's gone". So the one kind of loot that is
        -- pure reward was the one kind that collected in silence.
        --
        -- SAME CUE, NOT A NEW ONE. He asked for the sound an item makes, so
        -- this reuses BR.Config.Loot.pickupSound rather than introducing a
        -- second Volts-only cue that would drift from it.
        TriggerClientEvent(BR.Net.LOOT_PICKUP_CUE, src)

        BR.Server.notify(src,
            ('You collected %d %s.'):format(n,
                (BR.Config.Market and BR.Config.Market.currency) or 'Volts'),
            'success')
        return
    end

    if item.kind == 'chest' or item.kind == 'deathbox' then
        local contents = item.contents
        if item.kind == 'chest' then
            -- The crate STAYS, opened. Scatter first: toHusk clears the
            -- contents off the entry.
            scatter(m, item)
            toHusk(m, item)

            -- AND IF IT WAS THE AIRDROP, THE BLIP'S LAST MINUTE STARTS HERE.
            --
            -- Owner, 2026-08-22: "we keep the blip on until 1 minute after the
            -- crate is opened". This is the only moment in the codebase that
            -- knows an airdrop crate was opened, because since the same
            -- playtest removed the auto-open the airdrop is an ORDINARY
            -- container and this handler is the whole of the open path.
            --
            -- ONE FIELD AND ONE CALL, not a branch on kind. `item.airdrop` is
            -- nil on all 1300 generated crates, so the ordinary path is
            -- unchanged and unbranched; the guard on the function is there
            -- because br_core/server/airdrop.lua is a separate file and a
            -- deployment that dropped it must not take the loot system with it.
            if item.airdrop and BR.Airdrop and BR.Airdrop.opened then
                BR.Airdrop.opened(m, item.airdrop)
            end
        else
            -- A death box has no husk -- an empty one lying around would
            -- read as a body nobody had looted.
            retire(m, item)
            scatter(m, item)
        end
        local _ = contents
        if item.warmup then
            -- The pad must never end up stripped bare by whoever queued
            -- first: a looted crate comes back somewhere else on the island.
            m.loot.respawn[#m.loot.respawn + 1] = {
                at   = GetGameTimer() + (BR.Config.Loot.warmup.respawnMs or 45000),
                tier = BR.Config.Loot.warmup.tier or 2,
            }
        end
        return
    end

    local ok, displaced, reason = BR.Inv.give(src, item)
    if not ok then
        -- ONE CALL, NO BRANCHES, NO WAY OUT WITHOUT SPEAKING. The chain this
        -- replaces had a branch for `full`, which BR.Inv.give has never
        -- returned, and none for `noinv`, which it can -- see the note above
        -- REFUSAL.
        BR.Server.notify(src, BR.Loot.refusalText(reason, item), 'warn')
        return
    end

    retire(m, item)

    -- A weapon swapped out of a full inventory lands where the player stands.
    if displaced then
        BR.Loot.spawnStack(m, displaced, item.x, item.y, item.z)
    end
end)

-- --------------------------------------------------------------------------
-- Death boxes
-- --------------------------------------------------------------------------

--- Turn what a player was carrying into a box on the ground.
---
--- Called from combat.eliminate BEFORE the inventory is reset, which is the
--- only moment both the contents and the position are still true.
--- @param m table
--- @param src integer
--- @return table|nil entry
function BR.Loot.deathBox(m, src)
    if not m or not m.loot then return nil end

    local e = BR.Roster.get(src)
    if not e or not e.pos then return nil end

    local contents = BR.Inv.dropAll(src)
    BR.Inv.push(src)
    if #contents == 0 then return nil end

    -- SCATTERED, NOT BOXED (user call, 2026-08-05). A death box is one more
    -- thing to walk up to and hold a key on, in the moment right after a
    -- fight when standing still is the last thing you want to do. Their kit
    -- lands around them and you run through it.
    --
    -- A ring rather than a random spray: everything ends up visible and
    -- reachable, and nothing stacks inside anything else.
    local n = #contents
    local radius = L.deathScatterRadius or 4.6   -- ~15 feet
    for i, stack in ipairs(contents) do
        local a = (i / n) * math.pi * 2.0
        -- Two rings once there are more than six items, so a full inventory
        -- does not draw one enormous circle.
        local r = radius * ((i % 2 == 0 and n > 6) and 0.55 or 1.0)
        -- THE RING IS SMALL ENOUGH TO VOUCH FOR. `deathScatterRadius` is 4.6m,
        -- so every stack lands within about fifteen feet of a ped that was
        -- standing on that ground a moment ago -- close enough that its root is
        -- a better starting point for the client's probe than the sky is. A
        -- player killed under an overpass has their kit land under it with
        -- them, instead of on the freeway where nobody can see it fall.
        --
        -- The 4.6m of slack is real and it is why the client treats this as a
        -- hint rather than an answer: on a steep bank the ring's far side can
        -- sit above the corpse, the low probe finds nothing there, and it falls
        -- back to the 1200m probe. Worst case is today's behaviour.
        BR.Loot.spawnStack(m, stack,
            e.pos.x + math.cos(a) * r,
            e.pos.y + math.sin(a) * r,
            e.pos.z, nil, e.pos.z)
    end
    return nil
end

-- --------------------------------------------------------------------------
-- Housekeeping
-- --------------------------------------------------------------------------

-- --------------------------------------------------------------------------
-- The repair round-trip
-- --------------------------------------------------------------------------

--- How far a client may move an entry. Generous enough to walk an item off a
--- rooftop or out of the surf, far too small to relocate loot somewhere
--- useful to the reporter.
local FIX_RADIUS = 30.0

-- ONLY A CLIENT CAN GROUND-PROBE. GetGroundZFor_3dCoord and GetWaterHeight are
-- client natives, and the server has no map at all -- so an entry that
-- generation put in the sea or under a bridge can only be NOTICED out there.
-- The client sends back the corrected position it worked out locally and the
-- server decides whether to accept it.
--
-- The bound is what makes this safe to trust. A hostile client can nudge loot
-- it can already see by up to 30m, once per entry -- which is a worse outcome
-- for them than leaving it where it is, and strictly better than the status
-- quo of items floating in the Pacific.

--- How long a container must wait between accepted repairs. A rolling crate
--- would otherwise send one of these per frame for as long as it rolls.
local FIX_COOLDOWN_MS = 1500

--- The world, vertically. A height outside this pair is not a ground probe.
---
--- ═══ WHY THERE IS A VERTICAL BOUND AT ALL NOW (#232, audit 2026-09-08) ═══
---
--- The audit's observation was that this path "validates horizontal displacement
--- but accepts a client-provided height". It did, and the hole was wider than a
--- missing range check: `tonumber` is happy with a msgpack NaN or infinity, and
--- EVERY COMPARISON AGAINST A NaN IS FALSE -- so `BR.Dist(x, y, ...) > FIX_RADIUS`
--- answered "no, not too far" for a NaN x, and the 30m bound that this whole
--- mechanism rests on was not a bound at all. The finite() test below is the
--- part that closes that; the heights here are the part the audit asked for.
---
--- ABSOLUTE WORLD HEIGHTS, NOT A DELTA, AND THE DELTA IS THE ALTERNATIVE THAT
--- LOST. A bound like "within Nm of where the entry already is" reads better and
--- cannot be written: an entry's z before repair is its POI's NOMINAL height,
--- which the inReach note above calls out as tens of metres out on any slope and
--- a flat 0.0 for roadside filler. A legitimate correction from an authored 0.0
--- to real ground on Mount Chiliad is ~780m, so any delta small enough to be
--- worth having would refuse the exact repairs this feature exists for.
---
--- "Within Nm of the REPORTER" lost for the same reason and a second one: the
--- report is sent from the client's STREAMING worker (br_core/client/loot.lua's
--- drain), not from arm's reach, so the reporter is routinely a whole hillside
--- and several hundred metres away from the entry they are correcting -- and a
--- refused repair is never retried, because the client latches `reported[id]`.
--- Breaking the honest path to tighten a bound the client still owns either way
--- is a bad trade, and the pad has already cost the owner one playtest round to
--- a loot-streaming refusal (2026-09-07).
---
--- SO THIS IS THE HONEST BOUND: nothing a ground probe can legitimately return
--- lies outside it. -300 is below the deepest sea floor on the map; 1000 is
--- above Chiliad's summit, which is the highest ground there is. What it buys is
--- that a client can no longer write 1e9, a NaN or an infinity into an entry's z
--- -- values that poison every other client's ground probe, make inReach's
--- height test on a repaired entry unsatisfiable for everyone, and travel to
--- every subscriber in the announce that follows.
---
--- WHAT IT DOES NOT BUY, STATED PLAINLY: inside the bound the height is still
--- the client's number. A reporter can still put a repaired entry at a legal but
--- wrong height and make it awkward to claim. Fixing THAT means the server
--- learning ground heights for itself, which it cannot do -- the probe natives
--- are client-side, which is the reason this round-trip exists at all.
local FIX_Z_FLOOR   = -300.0
local FIX_Z_CEILING = 1000.0

--- Is this a real, finite number?
---
--- `v ~= v` IS THE NaN TEST AND IT IS THE ONLY ONE LUA HAS -- the same idiom
--- shared/fuel_solve.lua and shared/boost_solve.lua already use, and for the
--- same reason: these numbers arrive off the wire, where a client may send a
--- double the language has no literal for.
--- @param v any
--- @return boolean
local function finite(v)
    return type(v) == 'number' and v == v
        and v > -math.huge and v < math.huge
end

--- May this player move this entry to (x, y, z) right now?
---
--- EVERY RULE THE LOOT_FIX HANDLER ENFORCES, IN ONE PLACE THE DIAGNOSTIC CAN
--- ALSO CALL. BR.Loot.inspect reports whether a repair would be accepted, and
--- the only way that report can be trusted is for it to ask the same function
--- the handler asks. A second copy would be a reader that agrees with the rule
--- until the day the rule changes, which is the day you are reading it.
---
--- The refusal REASON is returned for the diagnostic only; the handler drops
--- it on the floor, because a client is told nothing about a rejected repair
--- (see the oracle note above the claim handler).
--- @param m table zone
--- @param src integer
--- @param e table roster entry -- for the live proximity test
--- @param item table
--- @param x number
--- @param y number
--- @param z number
--- @return boolean ok
--- @return string|nil why
local function fixOk(m, src, e, item, x, y, z)
    -- FINITE FIRST, BEFORE ANY COMPARISON USES THESE. Every test below is an
    -- inequality, and an inequality against a NaN is false -- which is the
    -- direction that ACCEPTS, so a single NaN would walk through the rest of
    -- this function untouched.
    if not finite(x) or not finite(y) or not finite(z) then
        return false, 'not a number'
    end
    if z < FIX_Z_FLOOR or z > FIX_Z_CEILING then return false, 'z off the map' end

    -- ONCE PER ENTRY -- EXCEPT FOR CONTAINERS, which are physical and can be
    -- pushed around by a vehicle for as long as anyone cares to. A crate whose
    -- registry position stopped following its prop is a crate you can see and
    -- cannot open, so those get to keep moving; the per-move bound still
    -- applies to each step, and a cooldown stops a rolling crate flooding the
    -- server (user, 2026-08-06).
    local isContainer = item.kind == 'chest' or item.kind == 'deathbox'
    if item.repaired and not isContainer then return false, 'once-only' end
    if isContainer and GetGameTimer() - (item.fixedAt or 0) < FIX_COOLDOWN_MS then
        return false, 'cooldown'
    end

    -- Must be a place this player is actually looking at, and a small move.
    local subs = m.loot.subs[src]
    if not subs or not subs[item.cell] then return false, 'unsubscribed' end

    -- ═══ AND WHERE THEY ARE NOW, NOT ONLY WHERE THEY SUBSCRIBED FROM ═══
    --
    -- The subscription table above is a RECORD of a decision, and the decision
    -- is only revisited when the player crosses a cell edge -- `m.loot.at[src]`
    -- short-circuits the LOOT_CELL handler otherwise. So a player who subscribes
    -- to a block and is then moved elsewhere by anything that does not go
    -- through a cell edge keeps a stale subscription, and every entry in it
    -- stayed repairable from wherever they now are.
    --
    -- THE SAME QUESTION THE SUBSCRIPTION ITSELF WAS GRANTED ON, asked of the
    -- live sample instead of the table.
    --
    -- THE TOLERANCE IS THE BLOCK PLUS THE DRIFT, AND IT HAS TO BE, or this
    -- refuses honest repairs. A subscription is a `subscribeRadius` block around
    -- the centre cell the client named, and the client is allowed to be
    -- BR.LOOT_CELL_DRIFT cells from that centre -- so the furthest an entry the
    -- server itself sent can legitimately be from the player who is streaming it
    -- is the sum. Anything tighter starts refusing repairs for entries the
    -- server announced, which the client never retries (it latches
    -- `reported[id]`), and the pad has already cost the owner one playtest round
    -- to a loot-streaming refusal (2026-09-07).
    --
    -- WHAT IT CATCHES is the case the table cannot: a subscription is a RECORD of
    -- a decision, revisited only when the client crosses a cell edge and sends
    -- another LOOT_CELL (`m.loot.at[src]` short-circuits it otherwise). A player
    -- moved somewhere else by anything that is not a cell edge keeps the whole
    -- stale block, and every entry in it stayed repairable from wherever they
    -- now are.
    if not e or not e.pos then return false, 'no position' end
    local icx, icy = BR.LootCellOf(item.x, item.y)
    local reach = (L.subscribeRadius or 1) + (BR.LOOT_CELL_DRIFT or 1)
    if not BR.LootCellReachable(icx, icy, e.pos.x, e.pos.y, reach) then
        return false, 'not near that cell'
    end

    if BR.Dist(x, y, item.x, item.y) > FIX_RADIUS then return false, 'too far' end
    return true, nil
end

-- NPC WEAPON DROPS.
--
-- This is a REPORT, and it is treated like every other client report on this
-- project -- believed only within limits that make lying pointless rather than
-- impossible.
--
-- ═══ "THE SERVER HAS NEVER HEARD OF AMBIENT PEDS" WAS WRONG ═══
--
-- That sentence stood here until #232 and it is worth correcting rather than
-- deleting, because the true version is more useful and leads to the same place
-- by a better road. FXServer DOES know about ambient population peds: they are
-- client-cloned entities, `entityCreating`/`entityCreated` fire for them, and
-- GetAllPeds, GetEntityHealth, GetEntityCoords, GetEntityType,
-- GetPedSourceOfDeath and even GetSelectedPedWeapon all exist server-side.
--
-- IT STILL CANNOT AUTHENTICATE ONE, FOR THREE REASONS THAT ARE NOT ABOUT US:
--
--   1. EVERY ONE OF THOSE READS IS THE OWNING CLIENT'S OWN PACKET. ServerGameState
--      parses health, cause of death, population type and current weapon straight
--      out of the clone-sync tree the ped's owner transmits. Spoofing the
--      population type is a known, exploited technique (citizenfx/fivem#2051 --
--      SetPedAsNoLongerNeeded right after CreatePed makes a script ped report as
--      ambient). Reading the ped instead of the event raises the forgery bar from
--      "call TriggerServerEvent" to "emit a well-formed sync tree". It does not
--      make the answer true.
--   2. THERE IS NO SERVER-SIDE PED DEATH EVENT AT ALL. `playerDeathEvent` is
--      players only; `weaponDamageEvent` fires only for damage to a REMOTELY
--      owned entity, and a pedestrian standing next to the player who shoots it
--      is usually owned by that player -- so the common case sends nothing.
--      Server-side detection means polling the ped pool, and GetEntityHealth
--      reads 0 for an entity nobody has in scope, which is indistinguishable
--      from dead (citizenfx/fivem#2794).
--   3. THERE IS NO STABLE IDENTITY TO SPEND. A ped's network id is
--      `handle & 0xFFFF` out of a recycled 16-bit pool, reissued lowest-free-first
--      within seconds on a busy server -- see the note on `paidNear` below.
--
-- So the honest summary is not "the server cannot see them"; it is "everything
-- the server can see about them was written by a client", which lands in exactly
-- the same place: this is a report.
--
-- ═══ WHAT THE AUDIT DID, AND WHY THE LIMITS WERE NOT THE ONES ABOVE ═══
--
-- #232's security audit (2026-09-08, finding 2, HIGH) sent this event from a
-- player who had killed nothing, with `item = 'minigun'` and `clip = 150`, and
-- the server put a LEGENDARY MINIGUN WITH A FULL BELT on the ground. LOOT_CLAIM
-- then moved it into the inventory, where every later possession check saw a
-- weapon the server itself had issued.
--
-- The rate limit and the ceiling were doing their job. The problem was that the
-- thing being limited was worth having. THREE separate failures, and only one of
-- them is "the death is unproven":
--
--   1. THE CLIENT NAMED THE WEAPON, and it was looked up in
--      BR.Config.WeaponById -- which is the resolver for EVERY weapon in the
--      game. config/weapons.lua registers the airdrop shelf into it BY HAND so
--      the damage validator can price an RPG hit, and that made this handler a
--      second, unguarded door onto the ultra-rare shelf. The owner ruled on
--      2026-08-21 that those four are AIRDROP-ONLY; this laundered them into an
--      ordinary inventory, from a pedestrian, twelve times a match.
--   2. THE CLIENT NAMED THE MAGAZINE, clamped only to the weapon's own capacity
--      -- which for a minigun is 150. The comment that used to sit here claimed
--      the drop was "the weapon with an EMPTY magazine". That sentence had never
--      been true; making it true was cheaper than correcting it.
--   3. THE SAME CORPSE COULD PAY REPEATEDLY, because nothing recorded that a
--      corpse had paid. Standing still and re-sending the event every four
--      seconds was the whole of the reproduction.
--
-- ═══ WHAT IS TRUE NOW ═══
--
--   * the reporter must be alive in a match, and the corpse within
--     `npcDrop.range` of the position the SERVER last sampled for them -- so a
--     report still cannot place loot across the map;
--   * every float is finite and the height is on the map (see finite() and
--     FIX_Z_FLOOR above) -- a NaN used to walk straight through the range test,
--     because every comparison against a NaN is false;
--   * THE SERVER CHOOSES THE WEAPON. `d.item` is not read at all. The drop comes
--     from `npcPool` below, which is built from BR.Config.Weapons alone;
--   * THE MAGAZINE IS EMPTY. `d.clip` is not read at all;
--   * ONE CORPSE PAYS ONCE (see `paidNear` below);
--   * and the rate limit and the per-match ceiling are unchanged.
--
-- WHAT A HOSTILE CLIENT CAN STILL DO, STATED PLAINLY BECAUSE IT IS NOT NOTHING:
-- fabricate up to `maxPerMatch` empty common sidearms, one every
-- `minIntervalMs`, at places it has actually walked to and at least
-- NPC_SAME_CORPSE metres apart. That is the reward for killing twelve
-- pedestrians, obtained without killing them -- an honest-looking player's own
-- entitlement, taken early. It is not a rare weapon, it is not loaded, and it is
-- worth less than one crate. The death itself is still unproven, and cannot be
-- proven from here; see the config note in br_lib/config/loot.lua for what
-- proving it would take.
local npcDrops = {}   -- [src] = { at = <ms>, count = <int>, paid = { {x,y}, ... } }

--- How far apart two reported corpses must be to count as two corpses.
---
--- A CORPSE DOES NOT MOVE, so "this position has already paid" is the closest
--- thing to "this death has already paid" that a server with no peds can say.
--- Six metres is about two body-lengths: wide enough that re-sending the same
--- report is refused however the client jitters the floats, narrow enough that
--- two pedestrians genuinely shot on the same pavement usually still pay twice.
---
--- THE HONEST COST, NAMED: two peds killed within six metres of each other pay
--- once, not twice. That is a false refusal and it is the safe direction --
--- the alternative that lost was quantising to a grid, which is cheaper to
--- store and has a boundary two points 10cm apart can fall either side of,
--- i.e. it fails in the direction that PAYS.
---
--- THE OTHER ALTERNATIVE THAT LOST WAS THE OBVIOUS ONE: have the client send the
--- ped's NETWORK ID and keep a set of ids already paid. It reads like the correct
--- answer and it is a bug. A network id on FXServer is `entity->handle & 0xFFFF`
--- -- a bare 16-bit object id out of a recycled pool that FinalizeClone frees on
--- teardown and GetFreeObjectIds re-issues lowest-first. With ambient population
--- churning as players move, ids come back round in SECONDS. A permanent set
--- would start refusing honest kills within minutes of a match starting; an
--- expiring one would start paying twice. The engine does disambiguate
--- generations internally (a random 16-bit `uniqifier`, and a `creationToken`
--- timestamp) and exposes neither to script. A position cannot be recycled.
local NPC_SAME_CORPSE = 6.0

--- The weapons an NPC may be carrying, resolved once at load.
---
--- FROM BR.Config.Weapons AND FROM NOTHING ELSE, which is the same construction
--- -- and the same argument -- as the rarity buckets in config/weapons.lua:
--- "the rarity buckets are built from BR.Config.Weapons and from nothing else.
--- That is not incidental to this working; it is the mechanism. Adding a loop
--- over this table there would put an RPG in every legendary crate on the map."
---
--- THAT IS THE WHOLE OF THE AIRDROP GUARANTEE, AND IT IS STRUCTURAL RATHER THAN
--- A BLOCKLIST. BR.Config.AirdropWeapons is a separate table that
--- config/weapons.lua registers into BR.Config.WeaponById by hand; it is in no
--- rarity bucket and it is not in BR.Config.Weapons. So an id resolved through
--- this list cannot reach the RPG, the grenade launcher, the railgun or the
--- minigun WHATEVER the config says -- including a future config written by
--- somebody who has never read this comment. A blocklist of the four names would
--- have been shorter and would need editing by hand on the day a fifth
--- ultra-rare weapon is added, which is the day nobody remembers this file.
local npcPool = {}
do
    local ordinary = {}
    for _, w in ipairs(BR.Config.Weapons or {}) do ordinary[w.id] = w end
    for _, id in ipairs((L.npcDrop and L.npcDrop.pool) or {}) do
        local w = ordinary[id]
        -- `w.ammo` because a drop has to be a firearm: the pool is authored, but
        -- an authored id that names a melee weapon would put a knife on the
        -- ground with an ammo pool it has no use for.
        if w and w.ammo then npcPool[#npcPool + 1] = w end
    end
    if #npcPool == 0 and (L.npcDrop or {}).enabled ~= false then
        print('^3[br_core] loot: npcDrop.pool resolves to no weapon -- NPC drops '
            .. 'are inert. Pool ids must name rows of BR.Config.Weapons; the '
            .. 'airdrop shelf is deliberately unreachable from here^7')
    end
end

--- Has a corpse at (x, y) already paid this player this match?
---
--- Linear over at most `maxPerMatch` entries -- twelve by default -- so it is
--- cheaper than the table lookup a set would need, and it is a RADIUS test
--- rather than a key, which is the point (see NPC_SAME_CORPSE).
--- @param rec table
--- @param x number
--- @param y number
--- @return boolean
local function paidNear(rec, x, y)
    for _, p in ipairs(rec.paid) do
        if BR.Dist2(x, y, p[1], p[2]) <= NPC_SAME_CORPSE * NPC_SAME_CORPSE then
            return true
        end
    end
    return false
end

RegisterNetEvent(BR.Net.NPC_DROP)
AddEventHandler(BR.Net.NPC_DROP, function(d)
    local src = source
    if type(d) ~= 'table' then return end

    local cfg = BR.Config.Loot.npcDrop or {}
    -- OFF UNLESS SWITCHED ON, WHICH IS A REVERSAL (#232). This used to read
    -- `cfg.enabled == false`, i.e. anything but an explicit false enabled the
    -- feature -- so a deployment with a truncated or older loot config got the
    -- fabrication path by default. The reason for the default itself is in
    -- br_lib/config/loot.lua beside the flag, where the owner will find it.
    if cfg.enabled ~= true then return end
    if #npcPool == 0 then return end

    local e = BR.Roster.get(src)
    if not e or not e.pos then return end
    if e.state ~= BR.PlayerState.ALIVE and e.state ~= BR.PlayerState.WARMUP then
        return
    end

    local m = zoneFor(src)
    if not m then return end

    -- FINITE BEFORE ANY COMPARISON, exactly as fixOk does it and for the same
    -- reason: `tonumber` is happy with a NaN off the wire, every inequality
    -- against a NaN is false, and false is the answer that ACCEPTS here -- so a
    -- NaN x walked straight through the range test below and the corpse could be
    -- nowhere at all.
    local x, y, z = tonumber(d.x), tonumber(d.y), tonumber(d.z)
    if not finite(x) or not finite(y) or not finite(z) then return end
    if z < FIX_Z_FLOOR or z > FIX_Z_CEILING then return end

    -- Range: the same slack the pickup check uses, because roster positions
    -- are sampled at 4Hz and a sprinting player's honest report is stale.
    local range = cfg.range or 60.0
    if BR.Dist(e.pos.x, e.pos.y, x, y) > range then return end

    local now = GetGameTimer()
    local rec = npcDrops[src]
    if not rec then rec = { at = 0, count = 0, paid = {} } npcDrops[src] = rec end
    rec.paid = rec.paid or {}
    if now - rec.at < (cfg.minIntervalMs or 4000) then return end
    if rec.count >= (cfg.maxPerMatch or 12) then return end

    -- ═══ ONE CORPSE, ONE PAYOUT ═══
    --
    -- Checked BEFORE the budget is spent, so a refused duplicate costs the
    -- reporter nothing -- the honest client never sends one (it keeps its own
    -- `looted` set of ped handles), and a hostile one learns nothing from the
    -- silence either way.
    if paidNear(rec, x, y) then return end

    rec.at, rec.count = now, rec.count + 1
    rec.paid[#rec.paid + 1] = { x, y }

    -- ═══ THE SERVER PICKS THE GUN, AND IT PICKS IT EMPTY ═══
    --
    -- `d.item` and `d.clip` are not read anywhere in this handler. That is the
    -- fix for finding 2 and it costs something real, which is worth writing down
    -- rather than discovering later: the drop is NO LONGER THE WEAPON THE PED
    -- WAS ACTUALLY HOLDING. The owner's rule was "I only want them to drop their
    -- inventory the same as a player would" (2026-08-06) and this no longer
    -- honours the letter of it -- because honouring it requires knowing what was
    -- in the ped's hands, the server cannot know that, and a client's word for it
    -- is precisely the exploit. A pistol from an authored pool keeps the SPIRIT
    -- (killing an NPC pays, in our currency, at our rarity) at the price of the
    -- detail.
    --
    -- MATH.RANDOM RATHER THAN THE MATCH RNG, DELIBERATELY. BR.Rng exists so the
    -- loot LAYOUT replays identically from a seed; an NPC drop is not part of
    -- the layout, is not derivable from the seed by anybody, and drawing from
    -- the seeded stream here would make the map's contents depend on how many
    -- pedestrians happened to die -- which is the one property the seeded
    -- generator exists to prevent.
    local w = npcPool[math.random(#npcPool)]

    -- AND NO `standZ`, DELIBERATELY, THOUGH THIS IS THE ONE SITE THAT LOOKS
    -- LIKE IT DESERVES ONE. There really is a ped's root here -- but the server
    -- never saw the ped, never saw it die, and never saw this z: all three
    -- floats arrived in `d` from the reporting client, and everything above
    -- this line is the machinery for believing them only as far as is harmless.
    --
    -- `pz` says "the SERVER measured this height". Setting it from a number a
    -- client sent would make that sentence false and would let a client decide
    -- where every other client's ground probe starts. The bound above is a
    -- world-height sanity check, not a measurement.
    --
    -- The cost is honest and small: an NPC shot under an overpass still drops
    -- its pistol onto the deck, exactly as it did before this change. Fixing
    -- that means the server learning the corpse's height for itself, which it
    -- cannot do.
    BR.Loot.spawnStack(m, {
        item   = w.id,
        kind   = BR.ItemKind.WEAPON,
        rarity = w.rarity or BR.Rarity.COMMON,
        count  = 1,
        -- EMPTY, AND THAT WORD NEEDS A FOOTNOTE. This is the ENTRY's magazine
        -- and it is genuinely zero. What the picker-up then gets is not zero:
        -- BR.Inv.give grants `w.clip * L.weaponReserveClips` of reserve ammo to
        -- EVERY weapon pickup in the game (server/inventory.lua), because "a
        -- found gun has to be usable, or the first weapon on the ground is a
        -- decoration". So an NPC pistol arrives with one reserve clip and an
        -- empty chamber, the same as any pistol found anywhere -- it costs a
        -- reload to bring up, and it is not a free loaded weapon.
        clip   = 0,
    }, x, y, z)
end)

--- Forget a player's NPC-drop budget. Called when they leave a match, so the
--- ceiling is per match rather than per session.
---
--- AND THE PAID-CORPSE LIST WITH IT, which is the same rule: the register exists
--- to stop one corpse paying twice inside one match, and a corpse cannot outlive
--- the match it died in.
--- @param src integer
function BR.Loot.clearNpcDrops(src)
    npcDrops[src] = nil
end

RegisterNetEvent(BR.Net.LOOT_FIX)
AddEventHandler(BR.Net.LOOT_FIX, function(d)
    local src = source
    if type(d) ~= 'table' then return end

    local id = math.tointeger(d.id)
    local x, y, z = tonumber(d.x), tonumber(d.y), tonumber(d.z)
    if not id or not x or not y or not z then return end

    local e = BR.Roster.get(src)
    if not e or not CAN_SEE[e.state] then return end
    local m = zoneFor(src)
    if not m then return end

    local item = m.loot.items[id]
    if not item then return end

    if not fixOk(m, src, e, item, x, y, z) then return end

    item.repaired = true
    item.fixedAt = GetGameTimer()
    m.loot.fixed = (m.loot.fixed or 0) + 1

    -- Re-index: the correction can cross a cell boundary, and an entry filed
    -- under the wrong cell is invisible to everyone who walks up to it.
    local oldCell = m.loot.cells[item.cell]
    if oldCell then oldCell[item.id] = nil end
    item.x, item.y, item.z = x, y, z
    -- AND THE VOUCH DIES WITH THE OLD POSITION. `pz` means "a ped was measured
    -- standing on the ground at THIS x/y"; a repair moves the entry up to 30m,
    -- so whatever ped that was is no longer standing there and the server has
    -- measured nothing about the new spot. Carrying it over would quietly turn
    -- a server measurement into a client's claim -- the entry's new z came
    -- straight off the wire two lines up -- which is the one thing this whole
    -- mechanism must not do. Cleared, the entry probes from 1200m again, which
    -- is what it did before any of this and what the repairing client itself
    -- used to work out the correction it just sent.
    item.pz = nil
    index(m.loot, item)

    -- Everyone looking at either cell hears about it; the id is unchanged, so
    -- clients holding it move the entry rather than duplicating it.
    announce(m, item)
end)

--- What the claim path believes about the entries nearest a player.
---
--- THE READER FOR ONE CRATE, because there was not one. brloot counts by kind
--- and rarity, which answers "is the layout right" and cannot answer "why will
--- THAT box not open" -- and the difference between those two questions is a
--- whole class of bug that is invisible from a chair (#195).
---
--- IT ASKS THE REAL FUNCTIONS. inReach and fixOk are the ones the LOOT_CLAIM
--- and LOOT_FIX handlers ask, called here with the same roster entry, so a row
--- saying `reach no` is the identical computation that produced "Too far
--- away". Reimplementing either would have made this a second opinion, and a
--- second opinion is worth nothing against a bug whose whole nature is that
--- two positions disagree.
---
--- THE POSITION IT TESTS A REPAIR FROM IS THE PLAYER'S. The server has never
--- seen the prop -- crates are client-side objects and only a client knows
--- where one actually is -- so the closest thing to "could this crate be
--- re-anchored to where it visibly is" is "would a repair from where the
--- reporting player stands be accepted". A player standing at the crate makes
--- that the same question.
--- @param src integer
--- @param radius number
--- @return table|nil rows nearest first
--- @return table info what the reader needs to interpret them
function BR.Loot.inspect(src, radius)
    local e = BR.Roster.get(src)
    if not e then return nil, { why = 'no roster entry' } end

    local m = zoneFor(src)
    if not m then
        return nil, { why = ('state %s is in no loot zone'):format(tostring(e.state)) }
    end

    local info = {
        zone      = m.id,
        warmup    = m.warmup and true or false,
        state     = e.state,
        canTake   = CAN_TAKE[e.state] and true or false,
        pos       = e.pos,
        posAgeMs  = e.posAt and (GetGameTimer() - e.posAt) or nil,
        reachMax  = L.pickupDistance + REACH_SLACK,
        reachZ    = REACH_Z,
        fixRadius = FIX_RADIUS,
        fixCool   = FIX_COOLDOWN_MS,
        total     = 0,
    }
    for _ in pairs(m.loot.items) do info.total = info.total + 1 end

    if not e.pos then return nil, info end

    local subs = m.loot.subs[src] or {}
    local now  = GetGameTimer()
    local rows = {}
    for _, item in pairs(m.loot.items) do
        local d = BR.Dist(e.pos.x, e.pos.y, item.x, item.y)
        if d <= radius then
            -- THE PLAYER'S OWN POSITION AS THE PROPOSED ONE, ALL THREE AXES.
            -- The z is now part of what fixOk judges, so a reader that passed
            -- only x and y would be asking a different question from the one the
            -- handler asks -- which is the exact failure the note above this
            -- function exists to prevent.
            local fix, fixWhy = fixOk(m, src, e, item,
                e.pos.x, e.pos.y, e.pos.z or item.z or 0.0)
            rows[#rows + 1] = {
                id       = item.id,
                kind     = item.kind,
                item     = item.item,
                x        = item.x, y = item.y, z = item.z,
                cell     = item.cell,
                subbed   = subs[item.cell] and true or false,
                repaired = item.repaired and true or false,
                fixAgeMs = item.fixedAt and (now - item.fixedAt) or nil,
                d        = d,
                dz       = (e.pos.z or 0.0) - (item.z or 0.0),
                reach    = inReach(e, item),
                fix      = fix,
                fixWhy   = fixWhy,
            }
        end
    end
    -- Nearest first, id as the tiebreak: two entries at the same distance must
    -- not swap places between two runs of a command you are diffing.
    table.sort(rows, function(a, b)
        if a.d ~= b.d then return a.d < b.d end
        return a.id < b.id
    end)
    return rows, info
end

-- --------------------------------------------------------------------------
-- Housekeeping
-- --------------------------------------------------------------------------

--- Every loot registry there is: the live matches plus the shared pad.
--- @param fn function
local function eachZone(fn)
    BR.Server.eachMatch(function(m)
        if m.loot then fn(m) end
    end)
    if warmupZone then fn(warmupZone) end
end

-- Subscriptions belong to players, and players leave. Left behind they would
-- keep a departed src in every announce() loop for the rest of the match.
BR.Sched.every(5000, 'loot.sweep', function()
    eachZone(function(m)
        for src in pairs(m.loot.subs) do
            local ent = BR.Roster.get(src)
            local stillHere = ent and CAN_SEE[ent.state]
                and (m.warmup and ent.state == BR.PlayerState.WARMUP
                     or (not m.warmup and ent.matchId == m.id))
            if not stillHere then
                m.loot.subs[src] = nil
                m.loot.at[src] = nil
                zoneOf[src] = nil
            end
        end
    end)
end)

-- --------------------------------------------------------------------------
-- Dev commands
-- --------------------------------------------------------------------------

--- Pin the layout seed so every match lays out identically.
RegisterCommand('brlootseed', function(_, args)
    local n = tonumber(args[1])
    if args[1] == 'off' or args[1] == 'none' then
        pinnedSeed = nil
        print('[br_core] loot seed unpinned -- every match gets a fresh layout')
        return
    end
    if not n then
        print('  usage: brlootseed <number|off>')
        print(('  currently %s'):format(pinnedSeed and tostring(pinnedSeed) or 'unpinned'))
        return
    end
    pinnedSeed = math.floor(n)
    print(('[br_core] loot seed pinned to %d -- takes effect at the next warmup')
        :format(pinnedSeed))
end, true)

--- Build a stack from an item id, or a full crate when given none.
--- @param item string|nil
--- @param x number
--- @param y number
--- @param z number
--- @return table|nil stack
--- @return string|nil error
local function devStack(item, x, y, z)
    if not item then
        return BR.MakeCrate(BR.Rng(GetGameTimer()), 3, x, y, z)
    end

    local w = BR.Config.WeaponById[item]
    local c = BR.Config.ConsumableById[item]
    if w then
        return { item = item, rarity = w.rarity, count = 1, clip = w.clip,
                 kind = w.clip and BR.ItemKind.WEAPON or BR.ItemKind.THROWABLE }
    elseif c then
        return { item = item, kind = BR.ItemKind.CONSUMABLE,
                 rarity = c.rarity, count = 1 }
    elseif BR.Config.AmmoPickups[item] then
        return { item = item, kind = BR.ItemKind.AMMO,
                 rarity = BR.Rarity.COMMON,
                 count = BR.Config.AmmoPickups[item].amount }
    end
    return nil, ('unknown item: %s'):format(item)
end

--- Spawn a crate (or one item) for a player.
--- @param src integer
--- @param item string|nil
--- @param at table|nil  a position, or nil for the player's sampled one
--- @return string report
local function devSpawn(src, item, at)
    local e = BR.Roster.get(src)
    if not e then return 'no roster entry' end

    local pos = at or e.pos
    if not pos then return 'no position sampled yet' end

    local m = zoneFor(src)
    if not m then
        return ('%s is not anywhere with loot in it (state %s)')
            :format(e.name, tostring(e.state))
    end

    local stack, err = devStack(item, pos.x, pos.y, pos.z)
    if not stack then return err end

    -- AT SOMEBODY'S FEET, EITHER WAY. `at` is the caller's own ped position
    -- reported by the client (an admin on a dev box, see the LOOT_DEV handler);
    -- with no `at` it is the roster's own sample of that ped. Both are a ped
    -- root at this x/y, so both vouch -- and that matters here more than
    -- anywhere, because `/brcrate <id>` is how the bridge case gets playtested
    -- at all.
    local spawned = BR.Loot.spawnStack(m, stack, pos.x, pos.y, pos.z,
        nil, pos.z)
    return ('spawned #%s (%s) at %s')
        :format(tostring(spawned and spawned.id), stack.kind, e.name)
end

--- Drop a crate (or any item) at a player's feet, from the server console.
RegisterCommand('brcrate', function(_, args)
    local src = tonumber(args[1])
    if not src then
        print('  usage: brcrate <serverId> [itemId]')
        print('    no itemId spawns a full crate; otherwise a single item')
        return
    end
    print('[br_core] ' .. devSpawn(src, args[2]))
end, true)

-- The client-side twin, so a crate can be spawned from F8 in front of the ped
-- rather than from the server console where you cannot see it land.
--
-- ═══ THIS WAS "ANY PLAYER SPAWNS ANY WEAPON" AND IT SHIPPED (#232) ═══
--
-- The gate above this line used to be `if not BR.Server.devMode then return
-- end`, which is not an authorization check: dev mode is a fact about how the
-- process was started, and EVERY connected client passes it. `devStack` below
-- resolves an item id through BR.Config.WeaponById, and that table contains
-- BR.Config.AirdropWeapons -- so four keystrokes in a modified client's F8
-- console produced an RPG, a grenade launcher, a railgun or a minigun, and
-- LOOT_CLAIM then legitimized it into the server's own inventory.
--
-- The reasoning behind the replacement, and why it fails CLOSED where the
-- report bounty in server/players.lua deliberately fails open, is at
-- BR.Admin.devTrusted in server/admin.lua. The short version is that the
-- developer this event exists for still has `brcrate <serverId> [itemId]` on
-- the server console, which is the same code path.
--
-- ═══ WHY ONE REFUSAL SPEAKS AND THE OTHER DOES NOT ═══
--
-- 'dev-mode-off' keeps the notify it always had. It leaks nothing: server/
-- main.lua REPLICATES the resolved answer to every client as `br_devMode`, so
-- any client can already read it off a convar without asking us.
--
-- EVERY OTHER REFUSAL IS SILENT ON THE WIRE, and that is the leak rule
-- server/players.lua states for reports: a different answer for an admin is a
-- probe, and whether a license holds a console grant is not otherwise
-- knowable. The reason goes to the SERVER CONSOLE instead, where the person
-- entitled to debug this is already standing -- the same place devgate.lua
-- prints for the same reason. The alternative that lost was a second notify
-- naming the reason, which would have been new player-facing copy nobody asked
-- for as well as a probe.
--
-- The position is still the CLIENT's, which is fine now for the reason it was
-- always claimed to be fine: it is a convenience for somebody who could type
-- the coordinates anyway. That claim just needed a caller it was true of.
RegisterNetEvent(BR.Net.LOOT_DEV)
AddEventHandler(BR.Net.LOOT_DEV, function(d)
    local src = source

    -- NIL-GUARDED, so a br_core loaded without admin.lua refuses instead of
    -- raising. An error here would also stop the spawn, but it would stop it
    -- with a stack trace that reads like a bug in the loot system rather than
    -- like a gate doing its job.
    local ok, why = false, 'no-admin-module'
    if BR.Admin and BR.Admin.devTrusted then
        ok, why = BR.Admin.devTrusted(src)
    end
    if ok ~= true then
        if why == 'dev-mode-off' then
            BR.Server.notify(src, 'Dev mode is off.', 'warn')
        else
            print(('^3[br_core] brcrate (client, %s) refused: %s^7')
                :format(tostring(src), tostring(why)))
        end
        return
    end

    if type(d) ~= 'table' then return end

    local at = nil
    if tonumber(d.x) and tonumber(d.y) and tonumber(d.z) then
        at = { x = tonumber(d.x), y = tonumber(d.y), z = tonumber(d.z) }
    end

    local report = devSpawn(src, d.item, at)
    print(('[br_core] brcrate (client, %d): %s'):format(src, report))
    BR.Server.notify(src, report, 'info')
end)

-- The warmup pad refills itself. Whoever queued first must not be able to
-- strip the island for everyone who arrives after them.
BR.Sched.every(1000, 'loot.warmupRespawn', function()
    if not warmupZone then return end

    local now  = GetGameTimer()
    local W    = BR.Config.Loot.warmup
    local pad  = BR.Config.Match.warmupPos
    local due  = warmupZone.loot.respawn

    for i = #due, 1, -1 do
        if now >= due[i].at then
            local rng = warmupZone.rng
            local inner = W.minRadius or 12.0
            local a = rng:float() * math.pi * 2.0
            -- sqrt: uniform over the AREA, not over the radius -- see the
            -- note in BR.BuildWarmupLayout.
            local span = math.max(1.0, (W.radius or 460.0) - inner)
            local r = inner + math.sqrt(rng:float()) * span
            local crate = BR.MakeCrate(rng, due[i].tier,
                pad.x + math.cos(a) * r, pad.y + math.sin(a) * r, pad.z, nil)
            crate.warmup = true
            BR.Loot.spawnStack(warmupZone, crate, crate.x, crate.y, crate.z)
            table.remove(due, i)
        end
    end
end)
