-- The Season 2 jerry can (#217), server half: the press's ruling, the one pour
-- per vehicle, the slices, FUEL_CAN, the freeze and its release, and the
-- crate's extra roll.
--
-- ═══ THE OWNER'S RULINGS ═══
--
--   "Please create an issue scoping a jerry can as a useable loot item, which
--    would only be useable at the gascap of a vehicle and could be used to
--    mobile refuel a vehicle. ... Neither the ped nor the vehicle should be
--    able to move while fueling, and fueling should not be able to start while
--    in motion. maxCarry 1 on the jerry can."   -- owner, 2026-08-22
--   "please remember that jerry can will be a season 2+ feature"
--   "yes, freeze the vehicle while pouring. players can enter and leave the
--    vehicle, and the engine is turned off while fueling."
--   "the jerry can does not repair the vehicle"
--   "partial use of a can should be possible."  -- owner, 2026-11-02
--
-- ═══ WHAT THIS FILE OWNS, AND WHAT IT LEAVES TO OTHERS ═══
--
--   THE RULING. A press arrives as BR.Net.INV_USE { slot, n } -- the only
--     message that names a vehicle, because a pourer is on foot and the server
--     has no "nearest vehicle" read -- and every claim in it is re-derived
--     here from the server's own reads (BR.JerryCan.judge). Every refusal is
--     SILENT: no toast, no channel, nothing spent, a reason counted for
--     `brjerrycan`.
--   THE CLAIM. One pour per vehicle at a time, keyed by network id -- the
--     ambulance heal's shape (server/ambheal.lua). The claim IS the channel's
--     `pour` record: inv.using.pour is the same table.
--   THE SLICES. server/inventory.lua's `inv.use` tick hands each open pour to
--     BR.JerryCan.step every 250 ms. Each slice moves fuel out of the can and
--     into the ledger through BR.Fuel.pour, and writes what is left in the can
--     with BR.JerryCanSolve.fillAfter -- the only writer of a can's fill.
--   THE FREEZE, AND ITS RELEASE.
--   THE CRATE ROLL (BR.JerryCan.extraFor), asked by server/loot.lua as a crate
--     opens.
--
-- The engine hold, the can in the pourer's hand, the cap finder and its marker
-- are client/jerrycan.lua's; the fuel ledger is server/fuel.lua's, and it never
-- learns there is a can.
--
-- ═══ THE FREEZE IS THE SERVER'S RPC, AND THE SERVER NEVER TAKES IT ON TRUST ═══
--
-- A server FreezeEntityPosition is a context RPC: it goes ONCE, to whichever
-- client owns the vehicle at the moment of the call, and it is not re-sent when
-- ownership moves -- with no owner it waits for the next one. So it is sent on
-- the pour's first slice and AGAIN on every pass that finds a different owner
-- (NetworkGetEntityOwner), and the unfreeze goes out the same way at every
-- release. Clients never freeze; they only unfreeze (client/jerrycan.lua).
--
-- WHAT THE SERVER READS OF A FREEZE IS UP TO A SECOND STALE: IsEntityPositionFrozen
-- is the owning client's last-synced bit. So the PROOF that the car stood still
-- is the server's own coordinates and GetEntitySpeed, every pass -- a car that
-- moves past `driftMeters`, or faster than `stillSpeed`, ends the pour where it
-- stands -- and the frozen and engine reads are counted for the readout and
-- never decide anything. A modified owner that refuses the freeze or keeps its
-- engine running buys nothing: the car moves, the pour stops, and the pourer
-- keeps the rest of the can.
--
-- ═══ NOTHING POURS AND NOTHING FREEZES INSIDE THE SETTLE WINDOW ═══
--
-- For `settleMs` after the press (one roster sample) a pour does nothing at all:
-- that sample is the server's second reading of where the pourer and the car
-- stand, its proof neither is moving. The first slice pays for the window, so
-- no fuel is lost to it -- and the freeze starts on that slice, which is what
-- bounds a griefer: every millisecond a car is frozen is a millisecond of
-- fuel the pourer has already poured into it out of their own can, plus one
-- pass. A tank within `minSpace` of full refuses the press outright.
--
-- ═══ EVERY WAY A POUR ENDS RELEASES IT ═══
--
--   the bar completes, or the tank fills first     step -> release('done')
--   a re-check fails (season, the car gone or in   step -> release(<key>)
--     another bucket, the pourer seated, away from
--     the box or moved, the car moving, its ledger
--     row gone)
--   anything else that ends the channel: an        the `jerrycan.reconcile` job,
--     enemy's hit ('Interrupted.'), downed, dead,    on the same pass, after
--     out, the slot guard, Field medic, the death    `inv.use` -> release('reconcile')
--     box, Leave Match, an inventory reset
--   the pourer disconnects                          playerDropped -> 'dropped'
--   the match is torn down                          br:match:destroyed -> 'destroyed'
--   br_core restarts                                onResourceStart -> reset
--
-- AN INTERRUPTION KEEPS WHAT IT POURED AND THE CAN KEEPS THE REST. Nothing is
-- spent on a cancel and nothing needs refunding: the fuel delivered, counted in
-- cans, plus what is left in the can is one can, on every row above.
--
-- ═══ SEASON 1 SEES NONE OF IT ═══
--
-- The press (judge), every slice (step) and the crate roll (extraFor) each ask
-- BR.Season.has('jerrycan') first. Off, no crate rolls a can and no draw is
-- taken; a can given by a dev verb is refused at the press, and a pour running
-- when the season is switched off stops on its next pass.

BR = BR or {}
BR.JerryCan = BR.JerryCan or {}

local JC = BR.JerryCan
local JS = BR.JerryCanSolve

--- BR.Config.Fuel and its jerry can table, read at call time so a suite can
--- move a number between two presses.
local function fuelCfg() return BR.Config.Fuel or {} end
local function canCfg() return (BR.Config.Fuel and BR.Config.Fuel.jerryCan) or {} end

--- Which player states may pour, or hear a pour's cue: server/fuel.lua's
--- pair, which is also the inventory's.
local LIVE = {
    [BR.PlayerState.ALIVE]  = true,
    [BR.PlayerState.WARMUP] = true,
}

--- Did a native declared BOOL say yes? THE `didHit` IDIOM (server/fuel.lua's
--- note): a BOOL native answers 1/0 on some builds, and 0 is truthy in Lua.
--- @param v any
--- @return boolean
local function didHit(v)
    return v == 1 or v == true
end

--- Which server natives this file leans on, checked ONCE, at load. Published
--- for `brjerrycan`. GetEntitySpeed is the one a pour can do without: absent,
--- the speed half of "still" is skipped and the drift tests still hold.
local have = {
    speed         = type(GetEntitySpeed) == 'function',
    heading       = type(GetEntityHeading) == 'function',
    owner         = type(NetworkGetEntityOwner) == 'function',
    frozen        = type(IsEntityPositionFrozen) == 'function',
    engine        = type(GetIsVehicleEngineRunning) == 'function',
    freeze        = type(FreezeEntityPosition) == 'function',
    entityFromNet = type(NetworkGetEntityFromNetworkId) == 'function',
}
JC.natives = have

--- The open pours, by vehicle network id. ONE PER VEHICLE: a second press on a
--- claimed car is refused `claimed`. Each value is the channel's `pour`.
local claims = {}

--- Vehicles released after a hold, watched for `releaseChecks` passes in case
--- the unfreeze did not land: { n, ent, left }. A car released on this pass
--- waits in `pending` until the reconcile job has run, so its first check is
--- on a LATER pass than the unfreeze its release already sent.
local after = {}
local pending = {}

--- The pour's id on the wire: from 1, increasing for as long as br_core runs.
--- NOT reset by BR.JerryCan.reset, so a client never sees an id twice.
local nextId = 0

local stat

local function freshStat()
    return {
        presses = 0, refused = {}, starts = 0, holds = 0, completions = 0,
        emptied = 0, cancels = {}, canceled = 0, reconciled = 0, ownerChanges = 0,
        engineOnPasses = 0, frozenPasses = 0, frozenAfterRelease = 0,
        crateRolls = 0, crateCans = 0,
    }
end
stat = freshStat()

-- ---------------------------------------------------------------------------
-- The world, read guarded
-- ---------------------------------------------------------------------------
--
-- EVERY ENTITY NATIVE IS pcall'd: the platform's entity natives raise on a
-- stale handle rather than answering, and a vehicle can go stale between two
-- passes. A read that throws is no answer, and each caller fails closed on it.

--- Where an entity is, as { x, y, z }, or nil. Field reads, not a type test:
--- a CfxLua vector3 is its own type (server/fuel.lua's coordsOf note).
--- @param ent integer|nil
--- @return table|nil
local function coordsOf(ent)
    if ent == nil or ent == 0 then return nil end
    local ok, c = pcall(GetEntityCoords, ent)
    if not ok or c == nil then return nil end
    local okv, x, y, z = pcall(function() return tonumber(c.x), tonumber(c.y), tonumber(c.z) end)
    if not okv or x == nil or y == nil or z == nil then return nil end
    return { x = x, y = y, z = z }
end

--- A number a native answered, or nil when it is absent, threw or answered
--- something else.
local function numberFrom(fn, ...)
    if type(fn) ~= 'function' then return nil end
    local ok, v = pcall(fn, ...)
    if not ok then return nil end
    return tonumber(v)
end

--- Does this entity exist?
--- @param ent integer|nil
--- @return boolean
local function exists(ent)
    if ent == nil or ent == 0 then return false end
    local ok, v = pcall(DoesEntityExist, ent)
    return ok and didHit(v)
end

--- Who owns a vehicle, as a server id, or -1 for nobody. NOBODY HAS ONE
--- SPELLING: the platform answers -1, 0 or 65535 for "no owner" depending on
--- the path, and a change between two of those is not a change of owner.
--- @param ent integer
--- @return integer
local function ownerOf(ent)
    if not have.owner then return -1 end
    local o = math.tointeger(numberFrom(NetworkGetEntityOwner, ent))
    if o == nil or o <= 0 or o == 65535 then return -1 end
    return o
end

--- The vehicle a network id names, or nil.
--- @param n integer
--- @return integer|nil
local function entityOf(n)
    if not have.entityFromNet then return nil end
    local ent = math.tointeger(numberFrom(NetworkGetEntityFromNetworkId, n))
    if ent == nil or ent == 0 then return nil end
    return ent
end

--- The FreezeEntityPosition RPC, guarded. A send that throws is a send that did
--- not happen, which the drift tests and the post-release checks both cover.
--- @param ent integer
--- @param on boolean
local function freeze(ent, on)
    if not have.freeze then return end
    pcall(FreezeEntityPosition, ent, on == true)
end

--- Send `payload` as FUEL_CAN to every roster entry in this match, in any state
--- -- spectators and the downed see the can in the pourer's hand too -- and to
--- nobody outside it.
--- @param matchId any
--- @param payload table
local function toMatch(matchId, payload)
    if matchId == nil then return end
    BR.Roster.each(function(e) return e.matchId == matchId end, function(src)
        TriggerClientEvent(BR.Net.FUEL_CAN, src, payload)
    end)
end

--- The pump's start cue, once per pour, on its first slice that adds fuel:
--- to the pourer and to every live player in the match the vehicle's own seats
--- answer as sitting in it (BR.Vehicles.ridingIn, the #4006 workaround -- the
--- ledger's `vehicleOf` would count a player who has already got out), each
--- once. The pump's own key (config/audio.lua's 'fuel.start'), so the can and
--- the pump are one sound.
--- @param pour table
--- @param ent integer
local function cue(pour, ent)
    local to = { [pour.src] = true }
    if BR.Vehicles and BR.Vehicles.ridingIn then
        BR.Roster.each(function(e)
            return LIVE[e.state] == true and e.matchId == pour.matchId
        end, function(src, e)
            if BR.Vehicles.ridingIn(e.ped) == ent then to[tonumber(src) or src] = true end
        end)
    end
    local ids = {}
    for s in pairs(to) do ids[#ids + 1] = s end
    table.sort(ids, function(a, b) return (tonumber(a) or 0) < (tonumber(b) or 0) end)
    for _, s in ipairs(ids) do
        TriggerClientEvent(BR.Net.FUEL_SFX, s, { n = pour.n, c = 'fuel.start' })
    end
end

--- @param t table  a counter table keyed by reason
--- @param why string
local function bump(t, why)
    why = tostring(why)
    t[why] = (t[why] or 0) + 1
end

-- ---------------------------------------------------------------------------
-- The press
-- ---------------------------------------------------------------------------

--- The press ruling, with no side effects: may this player pour the can in
--- `slot` into the vehicle `n` names, and how much, for how long?
---
--- INV_USE's own gates have already run (live and in a match, a consumable in
--- the slot, nothing else channeling, a row with a `useMs`); this re-reads the
--- roster entry, the inventory and the match itself, so `brjerrycan`'s dry run
--- can ask it of anybody. In order, the first failure answering its key:
---
---   season      the jerry can is a Season 2 feature
---   live/slot   (the dry run's own: not a live player in a match, or no can in
---               that slot)
---   hand        the can is the slot in hand, so the hand is unarmed
---   nomodule    BR.Fuel.space, BR.Fuel.pour and BR.Vehicles.ridingIn exist
---   nonet       `n` is a whole number and not 0
---   noentity    it names an entity that exists
---   notvehicle  ...which is a vehicle
---   bucket      ...in the routing bucket of the pourer's match: network ids
---               are global across buckets
---   untracked   the ledger has a row for it in the pourer's match. An
---               untracked car reads full: nobody has burned any of its fuel
---   full        it has room for at least `minSpace` of a tank
---   seated      the pourer is on foot -- by the vehicle's own seats
---               (BR.Vehicles.ridingIn), never server GetVehiclePedIsIn, which
---               answers the last car a ped sat in (citizenfx/fivem#4006)
---   away        the pourer stands inside the vehicle's footprint box
---               (BR.JerryCanSolve.atCap), from a fresh read of their ped
---   moving      the vehicle and the pourer are both under `stillSpeed`, where
---               the build has GetEntitySpeed
---   claimed     nobody else is pouring into it
---   empty       the plan pours something: a can with something in it, a tank
---               with room
--- @param src integer
--- @param slot integer|nil  the slot INV_USE named
--- @param n any             INV_USE's `n`, unvalidated
--- @param now integer|nil
--- @return table|nil plan
--- @return string|nil why
function JC.judge(src, slot, n, now)
    if not BR.Season.has('jerrycan') then return nil, 'season' end

    local e = BR.Roster.get(src)
    local m = BR.Server.matchOf(src)
    if not e or not LIVE[e.state] or e.matchId == nil or not m then return nil, 'live' end
    local inv = e.inv
    slot = math.tointeger(tonumber(slot))
    local s = (inv and slot) and inv.slots[slot] or nil
    local c = (s and s.kind == BR.ItemKind.CONSUMABLE) and BR.Config.ConsumableById[s.item] or nil
    if not (c and c.refuel) then return nil, 'slot' end

    if inv.active ~= slot then return nil, 'hand' end

    if not (BR.Fuel and BR.Fuel.space and BR.Fuel.pour
            and BR.Vehicles and BR.Vehicles.ridingIn) then
        return nil, 'nomodule'
    end

    n = math.tointeger(tonumber(n))
    if n == nil or n == 0 then return nil, 'nonet' end

    local ent = entityOf(n)
    if ent == nil or not exists(ent) then return nil, 'noentity' end

    if math.tointeger(numberFrom(GetEntityType, ent)) ~= 2 then return nil, 'notvehicle' end

    local bucket = numberFrom(GetEntityRoutingBucket, ent)
    if bucket == nil or bucket ~= tonumber(m.bucket) then return nil, 'bucket' end

    local F, J = fuelCfg(), canCfg()
    local space = BR.Fuel.space(n, e.matchId)
    if space == nil then return nil, 'untracked' end
    if space < (tonumber(J.minSpace) or 0.0) * (tonumber(F.tankMetres) or 0.0) then
        return nil, 'full'
    end

    if BR.Vehicles.ridingIn(e.ped) ~= nil then return nil, 'seated' end

    local P = coordsOf(e.ped) or e.pos
    local V = coordsOf(ent)
    local row = BR.Vehicles.modelRowOf
        and BR.Vehicles.modelRowOf(numberFrom(GetEntityModel, ent)) or nil
    if P == nil or V == nil
       or not JS.atCap(P.x, P.y, P.z, V.x, V.y, V.z,
                       have.heading and numberFrom(GetEntityHeading, ent) or nil,
                       row, J, F.askRadius) then
        return nil, 'away'
    end

    if have.speed then
        local still = tonumber(J.stillSpeed) or 0.0
        local vs, ps = numberFrom(GetEntitySpeed, ent), numberFrom(GetEntitySpeed, e.ped)
        if vs == nil or ps == nil or not (vs < still) or not (ps < still) then
            return nil, 'moving'
        end
    end

    if claims[n] ~= nil then return nil, 'claimed' end

    local perCan = JS.perCan(row, F.tankMetres, J.canFraction)
    local fill0 = JS.fillOf(s)
    local meters, ms = JS.plan(fill0, space, perCan, c.useMs, J.minPourMs)
    if meters == nil then return nil, 'empty' end

    return {
        n = n, ent = ent, src = src, matchId = e.matchId, bucket = m.bucket,
        perCan = perCan, fill0 = fill0, meters = meters, ms = ms,
        x0 = V.x, y0 = V.y, z0 = V.z,   -- the vehicle at the press
        px = P.x, py = P.y,             -- the pourer at the press (2D)
        row = row, space = space,
    }, nil
end

--- judge, then claim. Counts the press, and a refusal by its reason.
---
--- THE PRESS SPENDS NOTHING AND LEAVES THE CAN'S FILL WHERE IT WAS: the slices
--- move the fuel. The record returned is the claim and the channel's `pour`
--- alike, so the tick's step and the reconcile job agree on which pour is
--- whose.
--- @param src integer
--- @param slot integer
--- @param n any
--- @return table|nil pour
--- @return integer|nil ms  the channel's length
function JC.rule(src, slot, n)
    stat.presses = stat.presses + 1
    local now = GetGameTimer()
    local pour, why = JC.judge(src, slot, n, now)
    if not pour then
        bump(stat.refused, why)
        return nil, nil
    end
    nextId = nextId + 1
    pour.id = nextId
    pour.poured = 0.0
    pour.t0 = now
    pour.hold = false
    pour.owner = -1
    pour.owners = {}
    pour.cued = false
    pour.frozenSeen, pour.engineSeen = 0, 0
    claims[pour.n] = pour
    stat.starts = stat.starts + 1
    return pour, pour.ms
end

--- FUEL_CAN's start, to the pourer's match: every client hangs a can on the
--- pourer's hand from here. Called by INV_USE once the channel is open and the
--- inventory pushed.
--- @param src integer
--- @param pour table
function JC.begin(src, pour)
    if type(pour) ~= 'table' or claims[pour.n] ~= pour then return end
    toMatch(pour.matchId, {
        id = pour.id, n = pour.n, p = pour.src,
        ms = math.tointeger(pour.ms) or math.floor(pour.ms), hold = false,
    })
end

-- ---------------------------------------------------------------------------
-- The release
-- ---------------------------------------------------------------------------

--- Let go of the pour on network id `n`, whatever ended it.
---
---   1. the claim goes;
---   2. FUEL_CAN's end reaches the match, and every client lets go of its can,
---      its engine hold and any frozen copy;
---   3. the unfreeze RPC goes to whoever owns the car, or waits for the next
---      owner -- whether or not this pour had frozen it yet, because nothing
---      else in a match freezes a car a player can pour into. Not to a car that
---      no longer exists: there is nothing left to unfreeze;
---   4. a pour that froze the car is watched for `releaseChecks` passes after
---      this one, and the unfreeze is sent again on each that still reads it
---      frozen;
---   5. the reason is counted.
---
--- IDEMPOTENT, AND A NO-OP FOR AN UNCLAIMED `n`, because it is reached from
--- the slices, the reconcile job, a disconnect and a match's teardown, and two
--- of those can land on one pour.
--- @param n integer
--- @param why string
function JC.release(n, why)
    n = math.tointeger(tonumber(n))
    local pour = n and claims[n] or nil
    if pour == nil then return end
    claims[n] = nil
    toMatch(pour.matchId, { id = pour.id, n = pour.n, p = pour.src, ms = 0 })
    if exists(pour.ent) then freeze(pour.ent, false) end
    if pour.hold then
        pending[#pending + 1] = {
            n = n, ent = pour.ent,
            left = math.tointeger(tonumber(canCfg().releaseChecks)) or 0,
        }
    end
    if why == 'done' then
        stat.completions = stat.completions + 1
    else
        bump(stat.cancels, why)
        stat.canceled = stat.canceled + 1
        if why == 'reconcile' then stat.reconciled = stat.reconciled + 1 end
    end
end

-- ---------------------------------------------------------------------------
-- The slices
-- ---------------------------------------------------------------------------

--- One pass of an open pour, from the `inv.use` tick.
---
--- ═══ THE RE-CHECKS FIRST, EVERY PASS, AND A FAILURE STOPS IT WHERE IT IS ═══
---
---   season     the season still has the jerry can
---   gone       the network id still names the vehicle it named at the press,
---              and that vehicle exists
---   bucket     it is still in the pour's routing bucket
---   seated     the pourer is still on foot (BR.Vehicles.ridingIn)
---   away       the pourer, where the roster last sampled them, is still inside
---              the vehicle's box, where it stands now and facing as it faces
---   moved      the pourer has not moved `pourerDrift` from where they pressed
---   moving     the vehicle has not moved `driftMeters` from where it stood at
---              the press, and is under `stillSpeed` -- the server's own proof
---              the freeze held
---   untracked  the ledger still has the vehicle's row, in this match
---
--- ═══ THEN THE SLICE ═══
---
--- Inside the settle window nothing more happens. After it, the slice is what
--- BR.JerryCanSolve.target says should be in the tank by now less what has
--- already gone in -- the first one pays for the window, the last one is the
--- remainder and never the whole again -- poured through BR.Fuel.pour, which
--- answers what it REALLY added. The can's fill is written from that answer.
---
--- DONE when the bar is up, the plan has all gone in, or the tank took less than
--- it was offered (it filled first -- a pump in the same car). Otherwise, on the
--- first slice, the HOLD: the freeze RPC to the car's owner and FUEL_CAN hold to
--- the match; and on every pass after it, the freeze again for an owner who was
--- not the last one sent it.
---
--- 'done' and 'cancel' HAVE ALREADY RELEASED THE CLAIM; the tick takes the can
--- out of the bag if it is empty, and closes the channel.
--- @param src integer
--- @param e table   the pourer's roster entry
--- @param u table   inv.using
--- @param s table   the can's slot, proved by the tick's slot guard this pass
--- @param now integer
--- @return string verdict  'run' | 'done' | 'cancel'
--- @return string|nil why  for 'cancel'
function JC.step(src, e, u, s, now)
    local pour = u and u.pour
    -- A CHANNEL WHOSE POUR IS NO LONGER THE CLAIM was released by something
    -- else -- a match's teardown -- and has nothing left to release here.
    if type(pour) ~= 'table' or claims[pour.n] ~= pour then return 'cancel', 'released' end

    local function cancel(why)
        JC.release(pour.n, why)
        return 'cancel', why
    end

    local F, J = fuelCfg(), canCfg()

    if not BR.Season.has('jerrycan') then return cancel('season') end

    local ent = entityOf(pour.n)
    if ent == nil or ent ~= pour.ent or not exists(ent) then return cancel('gone') end

    local bucket = numberFrom(GetEntityRoutingBucket, ent)
    if bucket == nil or bucket ~= tonumber(pour.bucket) then return cancel('bucket') end

    if not (BR.Vehicles and BR.Vehicles.ridingIn and BR.Fuel and BR.Fuel.space
            and BR.Fuel.pour) then
        return cancel('nomodule')
    end
    if BR.Vehicles.ridingIn(e.ped) ~= nil then return cancel('seated') end

    local P, V = e.pos, coordsOf(ent)
    if P == nil or V == nil
       or not JS.atCap(P.x, P.y, P.z, V.x, V.y, V.z,
                       have.heading and numberFrom(GetEntityHeading, ent) or nil,
                       pour.row, J, F.askRadius) then
        return cancel('away')
    end

    if JS.drifted(pour.px, pour.py, P.x, P.y, J.pourerDrift) then return cancel('moved') end

    if JS.drifted(pour.x0, pour.y0, V.x, V.y, J.driftMeters) then return cancel('moving') end
    if have.speed then
        local vs = numberFrom(GetEntitySpeed, ent)
        if vs == nil or not (vs < (tonumber(J.stillSpeed) or 0.0)) then
            return cancel('moving')
        end
    end

    if BR.Fuel.space(pour.n, pour.matchId) == nil then return cancel('untracked') end

    -- THE SETTLE WINDOW: no fuel, no freeze.
    local settle = tonumber(J.settleMs) or 0
    local elapsed = now - pour.t0
    if elapsed < settle then return 'run' end

    local want = JS.target(elapsed, pour.ms, pour.meters, settle) - pour.poured
    local added = 0.0
    if want > 0.0 then
        added = BR.Fuel.pour(pour.n, pour.matchId, want)
        pour.poured = pour.poured + added
        s.fill = JS.fillAfter(pour.fill0, pour.poured, pour.perCan)
    end

    if added > 0.0 and not pour.cued then
        pour.cued = true
        cue(pour, ent)
    end

    if now >= u.endsAt or pour.poured >= pour.meters - 1e-6 or added < want - 1e-6 then
        if JS.empty(JS.fillOf(s)) then stat.emptied = stat.emptied + 1 end
        JC.release(pour.n, 'done')
        return 'done', nil
    end

    if not pour.hold then
        freeze(ent, true)
        local owner = ownerOf(ent)
        pour.owner = owner
        pour.owners[owner] = true
        pour.hold = true
        stat.holds = stat.holds + 1
        toMatch(pour.matchId, {
            id = pour.id, n = pour.n, p = pour.src,
            ms = math.tointeger(math.max(0, u.endsAt - now)) or 0, hold = true,
        })
    else
        -- THE RPC REACHED ONE OWNER, AND THIS IS A NEW ONE: a driver got in, or
        -- the car migrated. Sent again, and with nobody owning it, it waits.
        local owner = ownerOf(ent)
        if owner ~= pour.owner then
            freeze(ent, true)
            pour.owner = owner
            pour.owners[owner] = true
            stat.ownerChanges = stat.ownerChanges + 1
        end
    end

    -- DIAGNOSTICS ONLY. Both reads are the owner's last-synced bits, up to a
    -- second stale; the drift and speed tests above are what decide.
    if have.engine then
        local okE, run = pcall(GetIsVehicleEngineRunning, ent)
        if okE and didHit(run) then
            stat.engineOnPasses = stat.engineOnPasses + 1
            pour.engineSeen = pour.engineSeen + 1
        end
    end
    if have.frozen then
        local okF, fz = pcall(IsEntityPositionFrozen, ent)
        if okF and didHit(fz) then
            stat.frozenPasses = stat.frozenPasses + 1
            pour.frozenSeen = pour.frozenSeen + 1
        end
    end

    return 'run', nil
end

-- ---------------------------------------------------------------------------
-- The crate
-- ---------------------------------------------------------------------------

--- A jerry can for this container as it opens, or nil.
---
--- Called by server/loot.lua's openChest after the Yubikey's extra, so the key,
--- when there is one, comes first and nothing already in the box moves. MATCH
--- CRATES ONLY: a container of kind 'chest' that is neither on the warmup pad
--- (`warmup`, on the crate or its zone) nor the airdrop (`airdrop`). A death box
--- never reaches openChest at all, and a landing crate is a chest, so it rolls.
---
--- THE SEASON IS ASKED BEFORE ANY DRAW, and the roll itself is
--- BR.JerryCanSolve.crateRoll -- a stream of its own, salt 217 -- so Season 1's
--- crates spill byte for byte what they always did. The crate still shows the
--- rarity its own contents gave it; the can's blue appears only in the burst.
---
--- A FULL CAN: `fill = 1`, which BR.Loot.spawnStack carries onto the ground.
--- @param m table
--- @param container table
--- @return table|nil stack
function JC.extraFor(m, container)
    if not BR.Season.has('jerrycan') then return nil end
    if not m or not m.loot or not container then return nil end
    if container.kind ~= 'chest' then return nil end
    if container.warmup or m.warmup then return nil end
    if container.airdrop ~= nil then return nil end
    stat.crateRolls = stat.crateRolls + 1
    if not JS.crateRoll(m.loot.seed, container.id, canCfg().crateChance) then return nil end
    stat.crateCans = stat.crateCans + 1
    local row = BR.Config.JerryCan
    print(('[br_core] jerrycan: the crate %s holds a can'):format(tostring(container.id)))
    return {
        item = row.id, kind = BR.ItemKind.CONSUMABLE, rarity = row.rarity,
        count = 1, fill = 1,
    }
end

-- ---------------------------------------------------------------------------
-- Every other ending
-- ---------------------------------------------------------------------------

--- Release every pour this player started. playerDropped's, and a release no
--- other path would reach in time: the roster entry may already be gone.
--- @param src integer|string  `source` in playerDropped is a string
function JC.forget(src)
    src = tonumber(src)
    if src == nil then return end
    local mine = {}
    for n, pour in pairs(claims) do
        if pour.src == src then mine[#mine + 1] = n end
    end
    table.sort(mine)
    for _, n in ipairs(mine) do JC.release(n, 'dropped') end
end

--- The claim on a vehicle -- the channel's `pour` itself -- or nil. For the
--- readout and the suites.
--- @param n integer
--- @return table|nil
function JC.claimOf(n)
    n = math.tointeger(tonumber(n))
    return n and claims[n] or nil
end

--- The counters, copied, with `live` the open pours and `queued` the released
--- cars still being watched.
--- @return table
function JC.stats()
    local live = 0
    for _ in pairs(claims) do live = live + 1 end
    local out = { live = live, queued = #after + #pending, refused = {}, cancels = {} }
    for k, v in pairs(stat) do
        if type(v) == 'number' then out[k] = v end
    end
    for k, v in pairs(stat.refused) do out.refused[k] = v end
    for k, v in pairs(stat.cancels) do out.cancels[k] = v end
    return out
end

--- Drop every claim, the watch list and the counters, sending nothing. For
--- onResourceStart, where nothing is open yet, and for the suites.
function JC.reset()
    claims, after, pending = {}, {}, {}
    stat = freshStat()
end

--- THE RECONCILE JOB, which is what releases every ending the slices never see.
---
--- REGISTERED AFTER `inv.use` (server/inventory.lua is above this file in the
--- manifest, and BR.Sched runs jobs in the order they registered), so a channel
--- the tick closed on this pass -- an enemy's hit, the LIVE guard (downed, dead,
--- out, the bus, no match), the slot guard -- is released on this same pass. So
--- are the endings outside the tick: Field medic (BR.Inv.grantEffect), the
--- death box and Leave Match (dropAll) and an inventory reset. The rule is
--- one test: a claim whose pourer has no roster entry, no channel, or a channel
--- whose `pour` is not this claim, is over.
---
--- AND THE RELEASED CARS. Each watched car that still reads frozen is sent the
--- unfreeze again, on each of the `releaseChecks` passes AFTER the one that
--- released it -- that pass already sent one -- and never once a new pour
--- holds it.
BR.Sched.every(250, 'jerrycan.reconcile', function()
    local keep = {}
    for _, a in ipairs(after) do
        if claims[a.n] == nil then
            if have.frozen and exists(a.ent) then
                local ok, fz = pcall(IsEntityPositionFrozen, a.ent)
                if ok and didHit(fz) then
                    freeze(a.ent, false)
                    stat.frozenAfterRelease = stat.frozenAfterRelease + 1
                end
            end
            a.left = a.left - 1
            if a.left > 0 then keep[#keep + 1] = a end
        end
    end
    after = keep

    local over = {}
    for n, pour in pairs(claims) do
        local e = BR.Roster.get(pour.src)
        local u = e and e.inv and e.inv.using
        if not u or u.pour ~= pour then over[#over + 1] = n end
    end
    table.sort(over)
    for _, n in ipairs(over) do JC.release(n, 'reconcile') end

    -- Released on this pass, by a slice or just above: watched from the next.
    for _, a in ipairs(pending) do after[#after + 1] = a end
    pending = {}
end)

AddEventHandler('playerDropped', function()
    JC.forget(source)
end)

--- A match's world is gone: every pour in it ends with it. Per match, because
--- several run at once and network ids are global (server/fuel.lua's note).
AddEventHandler('br:match:destroyed', function(d)
    local matchId = d and d.matchId or nil
    if matchId == nil then return end
    local mine = {}
    for n, pour in pairs(claims) do
        if pour.matchId == matchId then mine[#mine + 1] = n end
    end
    table.sort(mine)
    for _, n in ipairs(mine) do JC.release(n, 'destroyed') end
end)

AddEventHandler('onResourceStart', function(name)
    if name ~= GetCurrentResourceName() then return end
    JC.reset()
end)

-- ---------------------------------------------------------------------------
-- Admin
-- ---------------------------------------------------------------------------

--- @param t table  reason -> count
--- @return string
local function reasons(t)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys)
    local out = {}
    for _, k in ipairs(keys) do out[#out + 1] = ('%s %d'):format(k, t[k]) end
    return #out > 0 and table.concat(out, ', ') or 'none'
end

--- What is pouring, what has, and why a press would be refused.
---
--- THE REFUSAL REASONS EXIST FOR THIS COMMAND AND NOWHERE ELSE, as
--- /brambheal's do: nothing in this feature ever tells a player anything, so
--- this is the only place anybody finds out which check fired. With
--- `<serverId> <netId>` it dry-runs the press for that player's can into that
--- vehicle -- the server has no "nearest vehicle", so the id is needed.
RegisterCommand('brjerrycan', function(_, args)
    local s = JC.stats()
    local now = GetGameTimer()
    print(('[br_core] jerrycan: %s, %d live pour(s), %d released car(s) watched')
        :format(BR.Season.has('jerrycan') and 'on' or 'OFF this season', s.live, s.queued))
    print(('  natives: speed=%s heading=%s owner=%s frozen=%s engine=%s freeze=%s')
        :format(tostring(have.speed), tostring(have.heading), tostring(have.owner),
                tostring(have.frozen), tostring(have.engine), tostring(have.freeze)))
    local ns = {}
    for n in pairs(claims) do ns[#ns + 1] = n end
    table.sort(ns)
    for _, n in ipairs(ns) do
        local p = claims[n]
        print(('    car %d <- %d, %.1fs in, %.0f of %.0f m, hold %s, owner %d, '
            .. 'frozen seen %d, engine seen %d')
            :format(n, p.src, (now - p.t0) / 1000.0, p.poured, p.meters,
                    tostring(p.hold), p.owner, p.frozenSeen or 0, p.engineSeen or 0))
    end
    print(('  presses %d  starts %d  holds %d  completions %d  emptied %d  canceled %d  '
        .. 'reconciled %d  owner changes %d')
        :format(s.presses, s.starts, s.holds, s.completions, s.emptied, s.canceled,
                s.reconciled, s.ownerChanges))
    print(('  refused: %s'):format(reasons(s.refused)))
    print(('  canceled: %s'):format(reasons(s.cancels)))
    print(('  engine-on passes %d  frozen passes %d  frozen after release %d  '
        .. 'crate rolls %d  cans %d')
        :format(s.engineOnPasses, s.frozenPasses, s.frozenAfterRelease,
                s.crateRolls, s.crateCans))

    local target = tonumber(args and args[1])
    if target == nil then return end
    local netId = tonumber(args and args[2])
    -- THE PLAYER'S CAN, WHEREVER IT IS IN THE BAG: the press names its slot,
    -- and a can that is not in hand is a `hand` refusal worth seeing.
    local e = BR.Roster.get(target)
    local inv = e and e.inv
    local slot = inv and inv.active or nil
    for i, st in ipairs(inv and inv.slots or {}) do
        local c = st and BR.Config.ConsumableById[st.item]
        if c and c.refuel then slot = i break end
    end
    local plan, why = JC.judge(target, slot, netId, now)
    if plan then
        print(('    judge(%d, net %s) = pour %.0f m in %d ms (fill %.3f, %.0f m a can, %.0f m of room)')
            :format(target, tostring(netId), plan.meters, plan.ms, plan.fill0,
                    plan.perCan, plan.space))
    else
        print(('    judge(%d, net %s) = refused -- %s'):format(target, tostring(netId), tostring(why)))
    end
end, true)
