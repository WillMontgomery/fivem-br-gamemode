-- The inventory mirror, and the only place a weapon is ever put in a hand.
--
-- READ-ONLY, LIKE THE ROSTER. What the server sends in INV_SET is the truth;
-- this file renders it onto the ped and into the UI, and sends REQUESTS back.
-- Nothing here decides that a pickup succeeded.
--
-- ACTIVE SLOT ONLY. The ped carries exactly what is in the selected slot and
-- nothing else -- every switch is RemoveAllPedWeapons + GiveWeaponToPed. That
-- is heavier than swapping the equipped weapon, and it is the point: the ped's
-- weapon wheel is not a second inventory that can drift out of agreement with
-- the real one.
--
-- AND IT IS SUSPENDED IN THE AIR. RemoveAllPedWeapons takes the PARACHUTE with
-- it. A weapon applied mid-drop would delete the chute of a player at 400
-- metres, which is not a HUD bug, it is a death. Nothing in here touches the
-- ped until the server says ALIVE.

BR = BR or {}
BR.Inv = BR.Inv or {}

local L        = BR.Config.Loot
local SLOTS    = L.slots or 5
local UNARMED  = BR.Config.Gadgets.UNARMED

-- SLOT ZERO IS FISTS, and nothing can ever be put in it (user call,
-- 2026-08-05). It sits left of slot 1 on the bar and cycles with the rest.
-- Having a deliberate empty hand matters: you cannot open a crate or vault
-- convincingly with a rifle up, and "put the gun away" should not mean
-- dropping it.
local MELEE_SLOT = BR.Config.Loot.meleeSlot or 0

-- The mirror. Empty slots are `false`, exactly as they are on the wire and on
-- the server -- one representation, no boundary conversion to get wrong.
--
-- IT STARTS ON FISTS, LIKE THE SERVER DOES (#155). This value is only ever seen
-- in the window before the first INV_SET lands -- on a fresh join and, more
-- often, after a `restart br_core`, where the server keeps the real inventory in
-- the roster and this file is rebuilt from nothing. Leaving it at 1 meant that
-- window drew a bar highlighting slot 1 and, if the ped could be armed, put
-- whatever ends up there into the hand. Short is not the same as never: it is
-- exactly the "selection restore after a resource restart" path #155 names.
local inv = { slots = {}, ammo = {}, active = MELEE_SLOT, using = nil }
for i = 1, SLOTS do inv.slots[i] = false end

-- What is actually in the ped's hands right now, and whose hands they were.
-- The ped handle matters: a respawn hands out a new one with no weapons on it.
local applied, appliedPed = nil, 0

--- When this player last gained anything. Zero means "has found nothing all
--- match", which is what the mercy blips in client/loot.lua key on.
BR.Inv.lastGainAt = 0

--- Set by /brprobe raw. While true, this file writes NOTHING to the ped's
--- ammo and reports nothing to the server.
---
--- It exists because the first ammo measurement was contaminated by our own
--- writes: the numbers being watched were partly ones we had just set, which
--- makes "what does this native do" unanswerable. A probe has to be able to
--- take our hands off the wheel.
BR.Inv.suspendAmmo = false

-- What we last told the server, and when.
--
-- `total` is the number that matters: GetAmmoInPedWeapon, the ped's WHOLE
-- holding for this weapon, magazine included. `clip` rides along so the server
-- can keep the split for the HUD, but it is never the thing decisions are made
-- on. A total of -1 means "no baseline yet" -- the next read establishes one
-- without reporting, so a weapon switch never looks like a burst of fire.
local lastReport = { total = -1, clip = -1, at = 0 }

--- ROUNDS THIS PED HAS ACTUALLY SPENT THAT THE SERVER HAS NOT CHARGED FOR.
---
--- ═══ THE AMMO THAT CAME BACK ═══
---
--- Owner, 2026-08-23, live playtest: "once depleted, switching between slots
--- gave me more ammo". That is a duplication exploit -- cycle the wheel and the
--- gun is full again -- and it does not live in the switch. The switch is right:
--- applyActive grants ZERO and then SetPedAmmo's an explicit number, so it can
--- only ever hand out what it was told to.
---
--- IT LIVES IN WHAT IT WAS TOLD. The number applyActive writes is the SERVER's
--- (`slot.clip` + the pool), and with `Combat.serverAmmo` on the server only
--- debits a round when a validated `weaponDamageEvent` reaches
--- BR.Damage.spendRound. Every round the engine burns that raises no such event
--- -- and an explosive is the clear case, since server/damage.lua's own capture
--- says a blast raises none at all -- is spent on the ped and never spent on the
--- server. The two numbers drift apart, silently, and the next slot switch
--- re-asserts the server's, which is the higher one. That is the refill.
---
--- SO THE DRIFT IS MEASURED RATHER THAN ASSUMED AWAY. Per slot, while its weapon
--- is confirmed in the hand, this holds `what the server says we hold` minus
--- `what the engine says we hold`. It is subtracted from every re-grant, so a
--- weapon that was empty when it was stowed comes back empty -- whatever the
--- server still believes -- and it is REPORTED, so the server stops believing
--- it. Both halves matter: the report is the fix, and this is what makes the
--- ped honest inside the round trip.
---
--- IT CANNOT INVENT AMMO. It is clamped at zero and only ever subtracts, so the
--- worst a wrong reading does is leave a player short -- and a short player is
--- one INV_SET away from the server's number again, while a duplicated magazine
--- is a match somebody else loses.
---
--- KEYED BY SLOT *AND* ITEM. A slot whose weapon changed is a different weapon
--- with a different magazine, and carrying a rifle's deficit onto the pistol
--- that replaced it would take rounds off a gun that never fired one.
---
--- `svClip` IS HERE BECAUSE `slot.clip` IS NOT THE SERVER'S NUMBER ANY MORE BY
--- THE TIME ANYONE READS IT. The report loop writes the ENGINE's magazine into
--- the mirror every tick so the counter follows the gun at 10Hz (see its note),
--- which means the mirror's clip is honest and the mirror's POOL is the only
--- stale half left. Measuring the deficit against the laundered value would
--- therefore find the reserve drift and miss the magazine drift entirely -- and
--- the magazine is the half a re-grant hands straight back. So what the server
--- actually said is kept, once, at the moment it says it.
local shortfall = {}   -- [slot] = { id = <item id>, svClip = <n>, n = <rounds> }

--- The deficit recorded for a slot, or 0 when there is none for THIS weapon.
--- @param at integer
--- @param slot table|false
--- @return integer
local function shortfallFor(at, slot)
    local rec = shortfall[at]
    if not rec or not slot or rec.id ~= slot.id then return 0 end
    return rec.n or 0
end

-- GTA'S OWN WEAPON UI HAS TO GO. The inventory replaces it wholesale, and
-- leaving the engine's version bound to the same keys means every one of our
-- inputs fires two things at once: TAB opened our panel AND the weapon wheel,
-- and 1-5 selected our slots AND the wheel's weapon groups (user, 2026-08-05).
--
-- These are DISABLED, not rebound. The player's own GTA control settings still
-- decide which physical key each of these is -- we are suppressing the
-- engine's reaction to them, not claiming a key.
--
-- NOT ONE OF THESE IS ON A KEY THE RADIO WHEEL WANTS, and that was checked
-- rather than assumed when #200 arrived blaming this list. Against the FiveM
-- controls reference: 37 is TAB, 157-164 are the number row, 99 and 15 are
-- scroll up, 14 is scroll down, 100 is `[`. The radio wheel is control 85,
-- INPUT_VEH_RADIO_WHEEL, default Q -- absent from this table and from every
-- other unconditional disable in this file. The culprit was the MELEE block
-- further down; see its note.
local SUPPRESS = {
    37,   -- INPUT_SELECT_WEAPON        (the weapon wheel; TAB by default)
    157, 158, 159, 160, 161,  -- INPUT_SELECT_WEAPON_UNARMED..SHOTGUN (1-5)
    162, 163, 164,            -- ..and the rest of the group row
    99, 100,                  -- INPUT_SELECT_NEXT/PREV_WEAPON
    14, 15,                   -- INPUT_WEAPON_WHEEL_NEXT/PREV (mouse wheel)
}

--- IS THE PED IN A VEHICLE RIGHT NOW?
---
--- NORMALISED, BECAUSE A FiveM NATIVE DECLARED BOOL DOES NOT HAVE TO HAND LUA A
--- BOOLEAN, and this project has shipped that mistake four times. `1 == true` is
--- false, and -- worse in the other direction -- the number 0 is TRUTHY in Lua,
--- so `not IsPedInAnyVehicle(...)` reads "on foot" as "in a vehicle" on a build
--- that answers 0. Both shapes are covered here so no caller has to know which
--- one this build produces. (The evidence says it is a real boolean today:
--- client/skydive.lua returns early on a raw truthiness test of this same
--- native, and parachutes deploy -- which they could not if a false read 0. That
--- is an observation about one build, not a contract.)
---
--- WHICH WAY IT IS SAFE TO BE WRONG, AND WHICH WAY THIS LEANS. A false "in a
--- vehicle" takes the melee suppression away on foot and brings back the
--- punch-while-drinking bug; a false "on foot" only leaves #200 unfixed. So only
--- the three values that can actually mean "not in a vehicle" -- nil, false and
--- 0 -- read as false here, which puts every silence (a native that declined, a
--- build that has none) on the ON FOOT side, where the cost is the smaller one.
---
--- THE SECOND ARGUMENT IS `false` AND THAT MEANS SEATED, not "reaching for the
--- door" -- so the window where the ped is climbing in still counts as on foot
--- and still suppresses. There is no radio wheel to open until they are in.
--- @return boolean
local function inVehicle()
    local v = IsPedInAnyVehicle(PlayerPedId(), false)
    return not (v == nil or v == false or v == 0)
end

-- SCROLL UP CYCLES BACKWARDS, SCROLL DOWN DOES NOTHING (user call,
-- 2026-08-05: "if 1 is selected, 5 is next"). One direction through a wrapping
-- ring reaches every slot and needs no thought about which way you are going;
-- two directions on a six-item ring is a decision nobody wants mid-fight.
-- Control 15 is the wheel's "previous", which is what a scroll UP reports --
-- 14 (down) stays disabled and inert.
local WHEEL_UP = 15

--- Can this player's ped be given anything at all?
---
--- WARMUP counts. There is loot on the warmup island and the point of it is
--- early PVP, so the bar, the panel and the weapon grants all have to work
--- there -- a bar showing five slots you cannot open was the worst of both
--- (user, 2026-08-05).
--- @return boolean
--- DBNO IS ABSENT, and it used to be here. A downed player keeps their
--- inventory -- it is what the death box is built from, and a revive has to
--- hand it back untouched -- but nothing goes in their hands. The server's own
--- LIVE table (server/inventory.lua) drops DBNO for the same reason, and the
--- two have to agree: when they disagreed over WARMUP the symptom was a
--- keypress that did nothing at all, in silence.
--- ...AND SO DOES "I HAVE LANDED", which is not the same fact as ALIVE.
---
--- ALIVE is the SERVER's word, and it arrives by way of the landing report --
--- the message with a retry loop and a server-side rescue net, because it goes
--- missing. Every one of those milliseconds is a player standing on the ground
--- with empty hands and no bar, and in the bad case it lasted until the match
--- reached PLAYING (#126). The previous round of work read that as slowness and
--- made things render sooner; they were not rendering late, they were disabled.
---
--- Arming on our own touchdown is safe in the one way that matters: the danger
--- this gate exists for is RemoveAllPedWeapons taking the PARACHUTE with it
--- mid-drop, and the same branch in client/skydive.lua that sets this latch has
--- already shed the canopy. There is no chute left to delete.
---
--- THE SERVER HAS NO EQUIVALENT AND DELIBERATELY KEEPS NONE. server/inventory
--- gates every mutation on its own LIVE table (ALIVE, WARMUP) and that is the
--- authority boundary -- a client must not be able to talk itself into a slot
--- switch. The consequence, stated rather than discovered later: inside the
--- window between our own touchdown and the server agreeing, this file will
--- draw the bar and answer the slot keys, and INV_SELECT will be dropped at the
--- far end in silence. That window is short by design and got shorter with
--- #126 -- the landing report's retry loop was dead and now runs -- but it is
--- not zero, and "a keypress that does nothing at all, in silence" is a symptom
--- this project has already paid for once (see the WARMUP note above). If it is
--- ever reported, the fix is the report, not this gate.
local function canArm()
    local st = BR.State.me.state
    return st == BR.PlayerState.ALIVE
        or st == BR.PlayerState.WARMUP
        or BR.State.landed == true
end

--- The weapon hash a slot represents, or nil for anything not held.
--- @param slot table|false
--- @return integer|nil
local function hashOf(slot)
    if not slot then return nil end
    if slot.kind ~= BR.ItemKind.WEAPON and slot.kind ~= BR.ItemKind.THROWABLE then
        return nil
    end
    local w = BR.Config.WeaponById[slot.id]
    return w and w.hash or nil
end

--- Reserve ammo available for a slot.
--- @param slot table
--- @return integer
local function reserveFor(slot)
    if slot.kind == BR.ItemKind.THROWABLE then return slot.count or 1 end
    local w = BR.Config.WeaponById[slot.id]
    if not w or not w.ammo then return 0 end
    return math.floor(inv.ammo[w.ammo] or 0)
end

-- --------------------------------------------------------------------------
-- Putting it in the hand
-- --------------------------------------------------------------------------

--- A FiveM BOOL, read the only way this codebase is allowed to read one.
---
--- FIFTH TIME OF ASKING. `0` IS TRUTHY IN LUA and a native declared BOOL may
--- hand back `1`/`0` rather than `true`/`false`, so both `if v then` and
--- `v == true` are wrong on one build each. dbno.lua carries the long version
--- of this scar under `didHit`; the drive-by facts below come straight off
--- IsPedInAnyVehicle and IsControlEnabled, which are two more of them.
--- @param v any
--- @return boolean
local function yes(v) return v == true or v == 1 end

--- When we last told the engine this player may fire from a seat, and how many
--- times. Read by /brdriveby so "did we ever ask?" is an observation rather
--- than an argument about which branch ran.
local driveBy = { at = 0, count = 0 }

--- PASSENGERS SHOOT, AND WE SAY SO ON A CADENCE RATHER THAN ONCE.
---
--- GTA gates drive-bys per player, and with it off a passenger simply cannot
--- fire at all -- which in a battle royale makes a car a rolling coffin for
--- everyone who is not driving (user, 2026-08-06: "any seat which is not the
--- driver should be able to do this").
---
--- THIS USED TO LIVE INSIDE applyActive, IN THE ARM BRANCH (#197). That put a
--- player-scoped engine flag behind two conditions that have nothing to do with
--- it: the slot had to hold a weapon (the unarmed branch never set it at all),
--- and the slot had to have just CHANGED, because applyActive returns early
--- when the mirror already matches. So the last assertion could be minutes and
--- a respawn behind the moment the player actually sat down in a seat.
---
--- Every other engine flag in this project is already re-asserted for exactly
--- this reason, and each one learned it the hard way: the team memo refreshes
--- every two seconds "because the engine resets a good deal on respawn"
--- (natives.lua), SetPedInfiniteAmmo is cleared EVERY TICK because "something
--- is re-setting the flag after we clear it" (below), and applyGameRules runs
--- per frame because "several of these reset themselves every tick". One
--- native a tick buys this one the same guarantee, and it is the only way the
--- diagnostic can say "we asserted it 0.4s ago" instead of "we asserted it,
--- once, at some point".
---
--- WHAT THIS STILL DOES NOT BUY, AND NOW NEVER WILL. The engine applies its own
--- rule about which weapons are usable from which seat, and that rule is game
--- DATA -- the CDrivebyWeaponGroup named by the seat's drive-by anim info -- not
--- a native we can call. A stock car seat permits unarmed, one-handed and thrown
--- weapons and nothing else, so a rifle is stowed on the way in whatever this
--- flag says.
---
--- We shipped a data file that redefined those two groups by name, and the game
--- IGNORED it (owner, 2026-08-22: "carbine rifle in the passenger seat does
--- nothing but pistols work"). That route is closed and the file is gone; see
--- docs/vehicle-data.md for the finding and client/driveby.lua for what a
--- passenger is told instead. This only stops US being the reason. See
--- /brdriveby.
local function assertDriveBy()
    SetPlayerCanDoDriveBy(PlayerId(), true)
    driveBy.at, driveBy.count = GetGameTimer(), driveBy.count + 1
end

--- Make the ped hold whatever the active slot says, and nothing else.
--- @param force boolean|nil  re-apply even if the mirror thinks it is current
local function applyActive(force)
    if not canArm() or BR.Inv.suspendAmmo then return end

    local ped = PlayerPedId()
    local slot = inv.slots[inv.active]
    local want = hashOf(slot)

    -- A new ped handle is a new, empty ped: re-apply whatever we thought was
    -- already there.
    if ped ~= appliedPed then
        applied, appliedPed = nil, ped
        force = true
    end
    -- SAME WEAPON: DO NOTHING.
    --
    -- This used to re-assert the ammo here on the grounds that SetPedAmmo is
    -- idempotent. It is not idempotent against the ENGINE: the player fires,
    -- the engine decrements, and 100ms later this wrote the mirror's number
    -- straight back over it. The gun never emptied and the counter never
    -- moved -- which is exactly the "bullet counts do not update" report, and
    -- it survived two rounds of looking at the display code because the
    -- display was right and the ammo genuinely was not going down.
    --
    -- Ammo is now written to the ped in exactly one place: a fresh grant
    -- below, or reapplyAmmo() when the SERVER's number goes UP (a pickup).
    if not force and want == applied then return end

    RemoveAllPedWeapons(ped, true)

    if want and slot then
        local clip    = math.floor(slot.clip or 0)
        local reserve = reserveFor(slot)

        -- WHAT THIS PED HAS ALREADY SPENT COMES OFF THE TOP.
        --
        -- The server's numbers are the authority on what this player OWNS; they
        -- are not a measurement of what is left in the gun, and with serverAmmo
        -- on they can sit above it indefinitely (see `shortfall`). Re-asserting
        -- them unmodified is what let a dry weapon come back loaded from a
        -- press of a number key.
        --
        -- Subtracted from the TOTAL and then taken out of the MAGAZINE first,
        -- because that is the order rounds actually leave a gun. A weapon that
        -- ran dry has a deficit equal to everything it was granted, so both
        -- halves land on zero and it comes back empty.
        local short = shortfallFor(inv.active, slot)
        local total = math.max(0, clip + reserve - short)
        clip = math.min(clip, total)

        -- GIVE THE WEAPON WITH ZERO AMMO, THEN SET THE AMMO. This is
        -- ox_inventory's order, and the reason for it is that
        -- GIVE_WEAPON_TO_PED *ADDS* rounds to a weapon the ped already holds
        -- rather than setting them. Passing `clip + reserve` here, as this
        -- used to, means every re-grant of the same weapon topped the player
        -- up by a full holding -- invisible while switching between two guns,
        -- and compounding whenever anything re-applied the same one.
        GiveWeaponToPed(ped, want, 0, false, true)
        SetPedAmmo(ped, want, total)
        SetAmmoInClip(ped, want, clip)
        SetCurrentPedWeapon(ped, want, true)

        -- AND THE ENGINE MAY NOT PICK THE WEAPON. Without this the engine
        -- swaps to "something better" on pickup and on empty, which fights the
        -- active-slot model for control of the hand.
        SetWeaponsNoAutoswap(true)

        -- THE DRIVE-BY PERMISSION IS NOT SET HERE ANY MORE (#197). It is a
        -- player-scoped flag, not a property of this grant, and asserting it
        -- only when the weapon changes is what made "have we asked?" a
        -- question nobody could answer from a seat. See assertDriveBy above,
        -- called from the tick loop.
    else
        SetCurrentPedWeapon(ped, UNARMED, true)
    end

    applied = want
end

--- Push the server's ammo numbers onto the ped, when they went UP.
---
--- The only legitimate reason for the server to know about more ammo than the
--- engine has is a PICKUP. Pushing on any other change would fight the engine
--- as the player fires -- see the note in applyActive.
local function reapplyAmmo(serverClip)
    if not canArm() or BR.Inv.suspendAmmo then return end
    local slot = inv.slots[inv.active]
    local hash = hashOf(slot)
    if not hash or applied ~= hash then return end

    -- ONLY WHEN THE SERVER'S NUMBERS WENT UP, and never by comparing against
    -- the engine. Comparing against GetAmmoInPedWeapon is what produced
    -- unlimited ammo: that native does not move when firing on this build, so
    -- a mirror that had drifted upward looked like a gun that needed topping
    -- up, forever (user, 2026-08-06).
    local ped  = PlayerPedId()
    local clip = math.floor(slot.clip or 0)

    -- ...AND MINUS WHAT WAS ALREADY SPENT, exactly as applyActive does it and
    -- for the same reason. This path is reached on every INV_SET whose ammo
    -- went up -- which includes a pickup of something else entirely, since the
    -- pool is shared -- so without the deduction ANY inventory change refilled a
    -- gun the server had not noticed running dry. The switch is the way the
    -- owner found it; it was never the only way in.
    local short = shortfallFor(inv.active, slot)
    local total = math.max(0, reserveFor(slot) + clip - short)
    clip = math.min(clip, total)

    SetPedAmmo(ped, hash, total)
    SetAmmoInClip(ped, hash, clip)
    lastReport.clip = serverClip or clip
end

--- Re-anchor the report baseline on what the SERVER just said.
---
--- Called after every INV_SET. The alternative -- clearing the baseline and
--- letting the next engine read establish one -- silently throws away every
--- other sample, because our own report is what produced the INV_SET in the
--- first place. Anchoring on the server's numbers instead means the baseline is
--- always the authority's view, which is exactly what the next decrease should
--- be measured against.
local function rebaseline()
    local s = inv.slots[inv.active]
    if s and s.kind == BR.ItemKind.WEAPON then
        lastReport.clip  = math.floor(s.clip or 0)
        lastReport.total = lastReport.clip + reserveFor(s)
    else
        lastReport.clip, lastReport.total = -1, -1
    end
end

--- Forget everything. Called at match teardown and on death.
---
--- BACK TO FISTS, NOT BACK TO SLOT 1 (#155). This is the death and teardown
--- path, so the next thing that happens is a fresh drop -- and it has to leave
--- the mirror agreeing with the server's own newInv() rather than spending the
--- first frames of the next match disagreeing with it about what is in the hand.
local function clearLocal()
    for i = 1, SLOTS do inv.slots[i] = false end
    inv.ammo, inv.active, inv.using = {}, MELEE_SLOT, nil
    applied, appliedPed = nil, 0
    lastReport.clip, lastReport.total = -1, -1
    -- The deficits go with the guns they were measured on. A new match hands
    -- out new weapons and a corpse's rifle is not this player's problem any
    -- more; carrying the numbers over would dock the next magazine.
    shortfall = {}
    BR.Inv.lastGainAt = 0
end

-- --------------------------------------------------------------------------
-- The UI channel
-- --------------------------------------------------------------------------

--- The inventory of the player we are WATCHING, or nil when we are not.
---
--- ═══ WHY THIS IS NOT MERGED INTO `inv` ═══
---
--- `inv` is the mirror of OUR OWN server-held inventory, and everything in this
--- file that acts -- swap, drop, use, select, the ammo report -- reads it. A
--- spectator's view is a picture and nothing more: no key here may act on it,
--- and the cheapest way to guarantee that is for it to live in a different
--- variable that only the draw path knows about. Writing the target's slots
--- into `inv` would put somebody else's rifle one keypress away from a drop
--- request, and the server would refuse it -- but "the server would refuse it"
--- is not a reason to send it.
---
--- IT IS SET BY THE SPECTATE FEED and by nothing else; client/spectate.lua
--- forwards what the server chose to send, and the server only sends it for the
--- one player it has already decided this viewer may watch.
local spectated = nil

local function pushUi()
    -- WHOSE INVENTORY THIS IS, DECIDED IN ONE PLACE. The bar is the same
    -- component either way -- it draws what it is given -- so the substitution
    -- happens here rather than in the interface. That keeps `InventoryBar` with
    -- no notion of spectating at all, which is what stops a second copy of
    -- "am I watching somebody" appearing in TypeScript.
    local src = spectated or inv
    -- Sent whole rather than as deltas: five slots is a tiny payload, and the
    -- storm's "never send a nil clear" rule means a partial update would need
    -- a vocabulary for "this slot is now empty" that `false` already is.
    TriggerEvent('br:ui:sendLocal', BR.Nui.INV, {
        slots  = src.slots,
        ammo   = src.ammo,
        active = src.active,
        using  = src.using,
    })
end

-- REGISTERED BELOW pushUi AND NOT ABOVE IT, deliberately. `local function f`
-- only binds `f` from that line down, so a handler written above this point
-- that calls pushUi() resolves it as a GLOBAL, which is nil at runtime -- no
-- syntax error, luac -p happy, and the whole inventory bar silently stops
-- updating after five caught errors. tools/check_forward_locals.lua exists
-- because BR.Loot's ground probe shipped exactly that and took every crate on
-- the map with it.
AddEventHandler('br:spectate:inv', function(p)
    -- A NIL IS AN EXPLICIT CLEAR, sent when a session ends. It is NOT what a
    -- quiet feed tick looks like -- the server dedupes and omits `inv` when
    -- nothing changed, and spectate.lua does not forward those at all, so the
    -- last picture stands until it genuinely changes or the session stops.
    spectated = (type(p) == 'table') and p or nil
    pushUi()
end)

--- How much of each thing an inventory holds, ignoring WHERE it is.
---
--- Keyed by item id for the slots and by '@pool' for the ammo pools, so the
--- two cannot collide. Used to answer "did anything arrive" without a
--- reordering counting as an arrival.
--- @param slots table
--- @param ammo table|nil
--- @return table
local function tally(slots, ammo)
    local t = {}
    for i = 1, SLOTS do
        local s = slots[i]
        if type(s) == 'table' and s.id then
            t[s.id] = (t[s.id] or 0) + (s.count or 1)
        end
    end
    if type(ammo) == 'table' then
        for pool, n in pairs(ammo) do
            if type(n) == 'number' then
                t['@' .. tostring(pool)] = n
            end
        end
    end
    return t
end

--- Adopt a server payload.
--- @param d table
local function adopt(d)
    if type(d) ~= 'table' or type(d.slots) ~= 'table' then return end

    -- Did anything actually ARRIVE? A pickup that was refused (too far, gone,
    -- rate-limited) still produces an INV_SET, so "the server sent an
    -- inventory" is not the same as "you picked something up" -- and the
    -- sound is the feedback that tells those apart.
    --
    -- COMPARED AS TOTALS, NOT SLOT BY SLOT. The per-slot version asked "does
    -- slot i hold something different from before", which is true of BOTH
    -- halves of a swap -- so shuffling items left and right in the panel
    -- played the pickup sound every time (user, 2026-08-06). Nothing was
    -- picked up; the same things were in different places. Counting each item
    -- across the whole inventory makes reordering invisible, which is what it
    -- should be.
    local gained = false
    do
        local before, after = tally(inv.slots, inv.ammo), tally(d.slots, d.ammo)
        for key, n in pairs(after) do
            if n > (before[key] or 0) then gained = true break end
        end
    end

    -- Did the SERVER's ammo for the weapon in hand go up? A pickup, or a
    -- reload it just paid for -- either way the ped needs the rounds putting
    -- into it. Measured against the last thing the server said, never against
    -- the engine.
    local gainedAmmo = false
    do
        local nowSlot = d.slots[d.active or 0]
        local wasSlot = inv.slots[inv.active]
        if type(nowSlot) == 'table' then
            local w = BR.Config.WeaponById[nowSlot.id]
            if w and w.ammo then
                local nowPool = (d.ammo and d.ammo[w.ammo]) or 0
                local wasPool = inv.ammo[w.ammo] or 0
                local nowClip = nowSlot.clip or 0
                local wasClip = (wasSlot and wasSlot.id == nowSlot.id)
                    and (wasSlot.clip or 0) or -1
                if nowPool > wasPool or nowClip > wasClip then
                    gainedAmmo = true
                end
            end
        end
    end

    for i = 1, SLOTS do
        local s = d.slots[i]
        inv.slots[i] = (type(s) == 'table') and s or false

        -- WHAT THE SERVER SAID THIS MAGAZINE HOLDS, kept before the report loop
        -- overwrites it with what the ENGINE says (see `shortfall`). A slot
        -- whose item changed is a different gun: the deficit measured on the one
        -- that left goes with it, or the replacement arrives already docked.
        local id  = (type(s) == 'table') and s.id or nil
        local rec = shortfall[i]
        if id == nil or (rec and rec.id ~= id) then
            shortfall[i] = nil
            rec = nil
        end
        if id ~= nil then
            if not rec then rec = { id = id, n = 0 } shortfall[i] = rec end
            rec.svClip = math.floor(s.clip or 0)
        end
    end
    local wasActive = inv.active
    inv.ammo   = d.ammo or {}
    inv.active = d.active or MELEE_SLOT
    inv.using  = d.using

    -- The switch click. Only on an actual change, and only on OUR screen --
    -- PlaySoundFrontend is local by definition.
    -- The switch click stays the engine's: it fires mid-fight and wants the
    -- same ducking the pickup does.
    if inv.active ~= wasActive and L.switchSound then
        PlaySoundFrontend(-1, L.switchSound.name, L.switchSound.set, true)
    end

    applyActive(false)

    -- Push the server's ammo onto the ped when it went UP -- a pickup, or a
    -- reload the server just paid for. `gainedAmmo` is measured against what
    -- we last saw the server say, never against the engine.
    if gainedAmmo then
        local s = inv.slots[inv.active]
        reapplyAmmo(s and s.clip)
    end
    -- The server has just spoken; that is what the next decrease is measured
    -- against, whether or not anything was reapplied to the ped.
    rebaseline()
    pushUi()

    if gained then
        -- Read by loot.lua's mercy blips: "has this player ever found
        -- anything" is the difference between helping and nagging.
        BR.Inv.lastGainAt = GetGameTimer()

        -- BACK TO GTA'S OWN PICK_UP (user, 2026-08-08). The rarity-tiered
        -- version replaced a sound that was already right: a pickup is a world
        -- event, it fires while shooting, and the engine cue ducks correctly
        -- against gunfire. Rarity is carried by the slot's colour and its
        -- rarityPop, which is where it belongs.
        if L.pickupSound then
            PlaySoundFrontend(-1, L.pickupSound.name, L.pickupSound.set, true)
        end
    end
end

RegisterNetEvent(BR.Net.INV_SET)
AddEventHandler(BR.Net.INV_SET, adopt)

-- The snapshot carries the same payload, which is what makes a mid-match
-- br_ui restart (or a reconnect) come back holding the right rifle.
RegisterNetEvent(BR.Net.SNAPSHOT)
AddEventHandler(BR.Net.SNAPSHOT, function(payload)
    if payload and payload.inv then adopt(payload.inv) end
end)

-- --------------------------------------------------------------------------
-- Effects
-- --------------------------------------------------------------------------

-- The server decided a consumable landed; this applies it to our own ped. The
-- amounts are TARGETS in display units, already capped by the item -- and they
-- are only ever applied UPWARD. A player who took a hit in the last 500ms
-- (between the server's sample and this event) must not be healed DOWN to a
-- stale number.
RegisterNetEvent(BR.Net.INV_EFFECT)
AddEventHandler(BR.Net.INV_EFFECT, function(d)
    if type(d) ~= 'table' then return end
    local ped = PlayerPedId()

    if d.armour then
        -- RE-ASSERT THE CEILING FIRST. GTA's default max armour is 50, and
        -- SetPlayerMaxArmour is a PLAYER setting that goes back to the default
        -- with a new ped -- which every respawn hands out. initHealthModel set
        -- it once at match start, so by the time anyone drank a shield potion
        -- the cap was 50 again and SetPedArmour silently clamped: "shield
        -- cannot get above 50" (user, 2026-08-06). Cheap, and exactly where it
        -- matters.
        SetPlayerMaxArmour(PlayerId(), BR.Config.Match.maxArmour)
        local target = math.min(d.armour, d.armourCap or BR.Config.Match.maxArmour)
        if target > GetPedArmour(ped) then
            SetPedArmour(ped, math.floor(target))
        end
    end

    if d.health then
        local target = math.min(d.health, d.healthCap or 100.0)
        if target > BR.Native.displayHealth() then
            BR.Native.setDisplayHealth(target)
        end
    end
end)

-- --------------------------------------------------------------------------
-- Input
-- --------------------------------------------------------------------------

-- Every one of these is a REQUEST. The bar does not move until INV_SET comes
-- back, which is why a refused switch looks like nothing happening rather than
-- like a switch that undid itself.
for i = 1, SLOTS do
    BR.Keys.on('slot' .. i, function(pressed)
        if not pressed or not canArm() then return end
        TriggerServerEvent(BR.Net.INV_SELECT, { slot = i })
    end)
end

BR.Keys.on('drop', function(pressed)
    if not pressed or not canArm() then return end
    if not inv.slots[inv.active] then return end
    TriggerServerEvent(BR.Net.INV_DROP, { slot = inv.active })
end)

-- THE USE KEY ALWAYS DOES SOMETHING IF THERE IS ANYTHING TO DO.
--
-- Strictly, you use what is in your hand. But a player who has just picked up
-- their first shield potion into slot 2 while a rifle sits in slot 1 presses
-- the key, nothing happens, and the reasonable conclusion is that the item is
-- broken (user, 2026-08-05: "there's no way to use it"). So: the active slot
-- if it is consumable, otherwise the lowest slot that is.
BR.Keys.on('use', function(pressed)
    if not pressed or not canArm() then return end

    local slot = nil
    local s = inv.slots[inv.active]
    if s and s.kind == BR.ItemKind.CONSUMABLE then
        slot = inv.active
    else
        for i = 1, SLOTS do
            local c = inv.slots[i]
            if c and c.kind == BR.ItemKind.CONSUMABLE then slot = i break end
        end
    end

    if not slot then return end
    -- Bring it up first, so the thing being drunk is the thing in hand.
    if slot ~= inv.active then
        TriggerServerEvent(BR.Net.INV_SELECT, { slot = slot })
    end
    TriggerServerEvent(BR.Net.INV_USE, { slot = slot })
end)

-- The TAB panel. LUA OWNS WHETHER IT IS OPEN, because Lua owns the cursor:
-- br_ui grants keep-input focus to any screen that is not the lobby or chat,
-- so the match keeps running underneath and the page decides nothing.
local panelOpen = false

local function closePanel()
    if not panelOpen then return end
    panelOpen = false
    TriggerEvent('br:ui:popFocus', 'inventory')
end

--- When the panel last changed state, so one press cannot count twice.
local lastToggle = 0

BR.Keys.on('inventory', function(pressed)
    if not pressed then return end

    -- HOLDING THE KEY MADE IT BLINK (user, 2026-08-09: "cannot reliably
    -- open/close it, especially while holding TAB").
    --
    -- The raw layer reads the keyboard directly, and opening the panel hands
    -- CEF the focus -- at which point the game stops seeing the key that is
    -- still physically held. The state goes down -> up -> down as focus
    -- settles, each transition is a real edge, and each edge toggles the
    -- panel. Nothing here is wrong about any single press; the key is simply
    -- being observed through a boundary that moves.
    --
    -- A press inside this window is treated as the one press it was. 250ms is
    -- longer than the focus handover and far shorter than a deliberate
    -- open-then-close.
    local now = GetGameTimer()
    if now - lastToggle < 250 then return end
    lastToggle = now

    if panelOpen then
        closePanel()
        return
    end
    -- Never over the lobby or a corpse: there is nothing to manage and the
    -- cursor would land on top of a menu that already owns focus.
    if not canArm() then return end
    panelOpen = true
    TriggerEvent('br:ui:pushFocus', 'inventory')
end)

-- UI actions. br_ui forwards the callbacks; br_core decides what they mean.
AddEventHandler('br:ui:action', function(name, data)
    if name == BR.NuiCb.CLOSE then closePanel() return end
    if name == BR.NuiCb.INV_SELECT then
        TriggerServerEvent(BR.Net.INV_SELECT, data)
    elseif name == BR.NuiCb.INV_SWAP then
        TriggerServerEvent(BR.Net.INV_SWAP, data)
    elseif name == BR.NuiCb.INV_DROP then
        TriggerServerEvent(BR.Net.INV_DROP, data)
    elseif name == BR.NuiCb.INV_USE then
        TriggerServerEvent(BR.Net.INV_USE, data)
    end
end)

-- --------------------------------------------------------------------------
-- Reporting a strip
-- --------------------------------------------------------------------------

--- The last strip we told the server about.
local lastStripAt = 0

--- How often one client may report a strip, in milliseconds.
---
--- THE TICK BAND IS 10Hz AND A RECURSIVE CHEAT RE-GRANTS ON EVERY ONE OF THEM.
--- The owner's description of the behaviour is the reason this constant exists:
--- "a cheater is likely to do this several times recursively". Unthrottled that
--- is ten net events a second, per offender, for as long as they keep going --
--- and the thing on the far end of them is an evidence buffer and a moderation
--- record, neither of which is improved by the ninth entry in one second.
---
--- ONE A SECOND IS ENOUGH TO SHOW THE PATTERN and cheap enough to be free. It
--- is not a security control and must not be mistaken for one: the far end
--- throttles again, because a modified client can send whatever it likes at
--- whatever rate it likes and this line is inside the resource it has already
--- decided to ignore.
local STRIP_REPORT_MS = 1000

--- Is this hash something the inventory holds SOMEWHERE, just not in hand?
---
--- THE ONE FALSE POSITIVE THIS FEATURE COULD ACTUALLY PRODUCE, and it is worth
--- spelling out because the answer is not obvious from the strip check above.
--- That check compares against the ACTIVE slot only, so any window in which the
--- ped holds a weapon from a DIFFERENT slot of the player's own inventory --
--- a mirror that has adopted a new active slot before `applyActive` has put the
--- new weapon in the hand, a grant that has not landed, `suspendAmmo` holding
--- our writes off the ped during /brprobe raw -- reads as "not the active slot"
--- and is stripped. Stripping it is harmless: `applyActive` puts the right
--- weapon back on the same tick.
---
--- OPENING A CASE ABOUT IT WOULD NOT BE. "You were holding your own shotgun a
--- tenth of a second after switching to your rifle" is a race between two
--- pieces of our own code, and filing it as evidence of a trainer would put an
--- innocent player in a moderation queue. So the strip stays unconditional and
--- the REPORT is withheld for a weapon we did in fact issue them.
---
--- The server checks this again against ITS inventory, which is the
--- authoritative one -- see br_core/server/strip.lua. This half exists so the
--- common race costs no net event at all.
--- @param h integer|nil  a normalised hash
--- @return boolean
local function inAnySlot(h)
    if h == nil then return false end
    for i = 1, SLOTS do
        local want = BR.NormHash(hashOf(inv.slots[i]))
        if want ~= nil and want == h then return true end
    end
    return false
end

--- Is the hash in this ped's hand the MOUNTED GUN OF THE VEHICLE THEY ARE SAT IN?
---
--- ═══ THE BUG THIS EXISTS FOR (owner, 2026-08-22) ═══
---
--- The owner stole an armed helicopter, read the case it produced, and asked:
--- "can you confirm that vehicle-related incidents will not fire as a
--- weapons-related incident? Because that's exactly what happened here. I caused
--- this myself and confirmed no weapons were ever involved."
---
--- They were right. When a ped takes a seat in an armed vehicle the engine makes
--- the vehicle's mounted gun their CURRENT WEAPON, and `GetCurrentPedWeapon`
--- reports that hash. It is not fists, it is not the parachute, and it is in no
--- inventory slot -- so the strip check above refused it, took it out of the
--- hand, and filed a WEAPON case against a player who had never touched a
--- weapon. Once a tick, for as long as they stayed in the seat, because the
--- engine hands it straight back.
---
--- ═══ HOW A MOUNTED WEAPON IS IDENTIFIED, AND WHY NOT THE OTHER WAYS ═══
---
--- `GetCurrentPedVehicleWeapon` -- BOOL GET_CURRENT_PED_VEHICLE_WEAPON(Ped,
--- Hash*) -- is the native built for exactly this question, and it is asked the
--- way this file asks every out-param native: two returns, the BOOL first.
--- The three alternatives were considered and rejected:
---
---   GetWeapontypeGroup. The obvious "is this hash in the vehicle group" test.
---   The published group list is INCOMPLETE -- citizenfx's own native docs mark
---   it `@todo` and name no group constants at all -- so the check would have
---   been written against a number nobody can cite. A guess in an anticheat is
---   worse than no check.
---
---   A hardcoded set of VEHICLE_WEAPON_* hashes. Finite, auditable, and wrong
---   the day anyone adds a vehicle: DLC and add-on vehicles carry weapons whose
---   hashes are not in any list written today, and each missing one is this same
---   bug again for that vehicle only -- the hardest possible shape to find.
---
---   "Seated, and the hash is in no catalogue of ours." THIS IS THE OBVIOUS
---   WRONG ANSWER and it is the one worth naming, because it is one line and it
---   passes every test written from the owner's report. It excuses ANY weapon
---   held in ANY seat, so a player who conjures a rifle and then sits in a car
---   is holding a weapon this gamemode issues nobody, and this file would hand
---   it back to them. See the header at the bottom of this file: the
---   `IsPedInAnyVehicle` guard that used to live in the ammo path was REMOVED
---   because the vehicle was the wrong question, and re-introducing it here as
---   an anticheat exemption would be the same mistake with a worse blast radius.
---
--- ═══ THE TEST IS AN EQUALITY, AND THAT IS WHAT KEEPS THE HOLE SHUT ═══
---
--- The weapon in the hand must BE the mounted weapon the engine names -- not
--- merely "some weapon, in some vehicle". A conjured rifle held in a Buzzard is
--- not the Buzzard's minigun, so it fails this test, is stripped, and is
--- reported exactly as it was before. tools/test_client.lua asserts that case
--- directly, because it is the one a careless fix loses.
---
--- FOUR CONDITIONS, ALL OF THEM CHEAP, ALL OF THEM IN THE SAFE DIRECTION:
---
---   1. the ped is SEATED. On foot there is no mounted weapon to be holding, so
---      a native that answers anyway cannot excuse anything. `inVehicle()` is
---      the normalised read -- see its note, and note that `false` for the
---      second argument means seated rather than climbing in.
---   2. the native EXISTS and did not throw. Absent or angry is no opinion, and
---      no opinion is not an excuse.
---   3. it ANSWERED. A FiveM BOOL may be `true` or `1` and this repo has shipped
---      the wrong reading SIX times, so `yes()` reads both. A build whose BOOL
---      is unreliable here keeps the bug rather than gaining a hole, and that is
---      the direction it is safe to be wrong in.
---   4. the hash is NON-ZERO and EQUAL. A vehicle with no mounted gun answers
---      `0`, and `0` is TRUTHY in Lua -- `BR.NormHash(0)` is `0`, not nil -- so
---      without the explicit test "this vehicle has no gun" would compare equal
---      to "this hand holds nothing" and excuse it. Tested ONCE, on the
---      vehicle's side: a matching guard on the hand would be the same
---      condition written twice and mutation testing would correctly call the
---      second one unkillable, which is the argument client/vehrefuse.lua's
---      `lock` already makes about a guard it deleted for the same reason.
---
--- ═══ WHAT THIS MISSES, STATED RATHER THAN DISCOVERED LATER ═══
---
--- A build on which `GetCurrentPedVehicleWeapon` does not answer for the seat
--- the player is in -- a turret, a passenger gun position, a modded vehicle the
--- native has no opinion about -- falls through to the old behaviour: the strip
--- fires and a weapon case is filed. That is the bug, narrowed, not abolished.
--- If it is ever reported again from a seat, this function is the first place to
--- look and `/brprobe ammo`'s `inVehicle` is the reading that says whether the
--- seat was even seen.
---
--- AND IT IS AS FORGEABLE AS EVERYTHING ELSE ON THIS PATH. A cheat that hooks
--- this native to name the rifle it just conjured buys itself an exemption -- but
--- a cheat that can hook natives can hook `GetCurrentPedWeapon` and never appear
--- here at all, which is cheaper. The trust boundary is unchanged and is stated
--- at length in br_core/server/strip.lua: this whole path is a tripwire in front
--- of server/damage.lua, not the defence.
--- @param h integer|nil  the normalised hash in the hand
--- @return boolean
local function isMountedWeapon(h)
    if not inVehicle() then return false end

    -- pcall AND NO `type(...) == 'function'` GUARD IN FRONT OF IT, deliberately.
    -- `pcall(nil, ...)` returns false rather than raising, so the guard and the
    -- pcall would have had identical behaviour -- and mutation testing said so,
    -- exactly as it did for the guard client/vehrefuse.lua's `lock` deleted for
    -- this reason. A native that is not on this build, and one that dislikes the
    -- handle it was given, both read as "no opinion" here.
    --
    -- Three returns: the pcall's own, then the native's two.
    --
    -- `not pok` IS THE ONE CONDITION HERE MUTATION TESTING CANNOT KILL, and it
    -- is kept rather than deleted like the two above: a failed pcall puts the
    -- ERROR MESSAGE in `answered`, which `yes` rejects for being a string, so
    -- the two halves cannot disagree today. They can the moment anything else
    -- goes in that slot, and dropping it would leave `pok` bound and unread --
    -- which reads as a pcall nobody checked.
    local pok, answered, mounted = pcall(GetCurrentPedVehicleWeapon, PlayerPedId())
    if not pok or not yes(answered) then return false end

    -- NO `h == nil` GUARD AT THE TOP OF THIS FUNCTION, for the same reason and
    -- with the same evidence: `m ~= nil` below already refuses the only shape a
    -- nil hand can reach here in -- an engine that answered and named nothing --
    -- and a second test of the same fact was reported unkillable.
    local m = BR.NormHash(mounted)
    return m ~= nil and m ~= 0 and m == h
end

--- Tell the server a weapon it never issued was taken out of this ped's hand.
---
--- WHAT THIS IS AND IS NOT. It is a report of something that already happened;
--- the weapon is gone by the time this runs and nothing the server says can
--- change that. It catches the vMenu tier -- somebody granting themselves a
--- gun in a menu -- which is exactly the behaviour that produced the
--- corpse-that-is-alive desync, and it catches nothing above that tier: a cheat
--- that stops this resource stops this report along with it. The unforgeable
--- half is still the server-side damage validation in br_core/server/damage.lua,
--- which does not need the client's cooperation and cannot be turned off from a
--- client. Nobody should read this as the defence.
--- @param h integer|nil  the normalised hash that was in the hand
local function reportStrip(h)
    if h == nil or inAnySlot(h) then return end

    local now = GetGameTimer()
    if now - lastStripAt < STRIP_REPORT_MS then return end
    lastStripAt = now

    TriggerServerEvent(BR.Net.INV_STRIPPED, h)
end

-- --------------------------------------------------------------------------
-- Loops
-- --------------------------------------------------------------------------

BR.Loop.register(BR.Loop.TICK, 'inv.apply', function()
    -- ABOVE THE canArm() GATE, ON THE SAME ARGUMENT THE WEAPON-WHEEL BLOCK
    -- MAKES (#134, and now #197). canArm() answers "may this file put a weapon
    -- in this ped's hand", which is false for the lobby, the bus and the whole
    -- descent -- and "may this player fire from a seat" is not that question.
    -- A permission asserted while nobody can fire costs one native and is
    -- already true by the time anybody sits down.
    assertDriveBy()

    if not canArm() then
        -- Airborne, in the lobby, or dead: the hand is not ours to fill. The
        -- mirror is left alone so landing re-applies whatever was picked up
        -- on the way down (nothing, today -- but the bus ride is where a
        -- future starting kit would arrive).
        applied = nil
        -- A panel left open over a death or a teardown would keep the cursor
        -- on screen with nothing under it.
        closePanel()
        return
    end

    -- The pause menu is a full-screen map with its own cursor; ours sitting on
    -- top of it is two interfaces fighting for the same mouse (user,
    -- 2026-08-05).
    if panelOpen and IsPauseMenuActive() then closePanel() end

    -- A WEAPON WE DID NOT ISSUE DOES NOT STAY IN THE HAND.
    --
    -- applyActive only acts when the ACTIVE SLOT changes, so a weapon that
    -- appeared by some other route -- a trainer, anything -- simply sat there
    -- until the next switch. The server already refuses its shots, so nothing
    -- was ever at stake; what it produced was the corpse-that-is-alive desync,
    -- because the engine applies damage locally before the server sees it
    -- (user, 2026-08-08).
    --
    -- Taking it out of the hand is what stops that happening at all, rather
    -- than correcting it a round trip later. This is defence in depth and not
    -- the defence: a cheat that disables this file entirely is still refused
    -- server-side, which is the half that actually matters.
    --
    -- AND IT IS NO LONGER SILENT. The strip is unchanged -- it still happens on
    -- the same tick, for the same reason -- but it now also REPORTS, because a
    -- cheater taking this route used to trip no alarm anywhere at all: the
    -- weapon vanished, they granted themselves another, and nothing was ever
    -- written down. `reportStrip` below is the whole of that addition.
    do
        local ped = PlayerPedId()
        local ok, held = GetCurrentPedWeapon(ped, true)
        if ok then
            local h = BR.NormHash(held)
            local wantHash = BR.NormHash(hashOf(inv.slots[inv.active]))
            -- Fists and the parachute are never ours to strip: the chute is
            -- granted by skydive.lua and removing it at 400 metres is a death.
            --
            -- AND NEITHER IS THE GUN BOLTED TO THE VEHICLE THEY ARE SITTING IN.
            -- A ped in an armed vehicle is HANDED its mounted weapon by the
            -- engine; they did not conjure it and there is nothing to take out
            -- of their hand. See `isMountedWeapon` for how that is established,
            -- why it is an equality rather than "in a vehicle", and what it
            -- misses. The vehicle itself is somebody's problem -- it is refused
            -- by config/vehicles.lua, ejected by client/vehrefuse.lua and
            -- detected by server/vehicles.lua -- but it is a VEHICLE problem,
            -- and answering it here filed it as a weapon one.
            local allowed = h == BR.NormHash(UNARMED)
                or h == BR.NormHash(BR.Config.Gadgets.PARACHUTE)
                or (wantHash ~= nil and h == wantHash)
                or isMountedWeapon(h)
            if not allowed then
                RemoveWeaponFromPed(ped, held)
                applied = nil          -- force the active slot back on
                reportStrip(h)
            end
        end
    end

    applyActive(false)
end)

-- Control suppression and slot cycling, per frame.
--
-- FRAME rather than TICK because DisableControlAction only lasts one frame,
-- and a wheel that flickers into existence every other frame is worse than one
-- that never goes away.
BR.Loop.register(BR.Loop.FRAME, 'inv.controls', function()
    -- THE SUPPRESSION IS UNCONDITIONAL, AND IT SITS ABOVE THE canArm() GATE ON
    -- PURPOSE (#134). Owner, playtesting the drop: "I just found out the GTA V
    -- weapon wheel displays when holding TAB in the plane. That shouldn't
    -- happen."
    --
    -- It used to sit BELOW the gate, so the suppression inherited canArm()'s
    -- answer -- and canArm() answers a completely different question. It asks
    -- "may this file put a weapon in this ped's hand", which is false for the
    -- whole lobby, the whole bus ride and the whole descent because
    -- RemoveAllPedWeapons would take the parachute with it. Whose UI owns TAB
    -- is not that question and never was. Aboard the bus the state is BUS, the
    -- callback returned on its first line, nothing disabled control 37, and
    -- GTA's wheel was free to answer the key.
    --
    -- THE FIX IS NOT TO TAKE THE INVENTORY'S GAME INPUT AWAY. The inventory is
    -- the one screen in this game deliberately marked BR.FocusKeepsInput -- it
    -- is meant to be usable mid-fight, which means the engine keeps reading the
    -- keyboard while it is open, which is what lets the engine see TAB at all.
    -- That behaviour is load-bearing for the screen it belongs to, and trading
    -- it away to stop a wheel appearing during a phase with no combat in it
    -- would be paying for a cosmetic bug with a gameplay one.
    --
    -- WHAT THIS NOW COVERS, phase by phase, all of them phases where there is
    -- nothing to select and the engine's wheel is GTA UI drawn on top of ours:
    --
    --   LOBBY      frozen ped, no weapons, a camera shot the wheel sat over.
    --   BUS        the reported case.
    --   FREEFALL   } the ped is holding GADGET_PARACHUTE for the entire
    --   GLIDE      } descent, so the wheel there was not even empty -- it
    --              } offered the canopy, mid-drop, over the drop UI.
    --   DBNO       client/dbno.lua blocks attack, aim and melee for a downed
    --              player and has never blocked 37, so the wheel opened while
    --              crawling. Left to that file to keep or not; this covers it.
    --   DEAD /     the spectator camera is somebody else's fight; the local
    --   SPECTATING ped's wheel has no business over it.
    --
    -- There is no phase in this gamemode that wants the engine's weapon UI --
    -- see the SUPPRESS table's own note -- so the correct gate is no gate.
    --
    -- DisableControlAction, NOT BLOCK_WEAPON_WHEEL_THIS_FRAME. The blocking
    -- native may well be the tidier call and this project has never probed it,
    -- and an unknown binding throws: five throws suspend this callback, and
    -- THIS callback is the one holding the wheel down. That exact failure has
    -- already happened once here (see the aiming note below) and the way it
    -- presents is the wheel coming back. Control 37 is already proven on this
    -- build by everything that works today in ALIVE and WARMUP.
    --
    -- Cost is twelve native calls a frame in the phases that previously made
    -- none, and it has to be per-frame: a disable lasts exactly one frame.
    for i = 1, #SUPPRESS do
        DisableControlAction(0, SUPPRESS[i], true)
    end

    -- A SPECTATOR'S MOUSE BELONGS TO THE CAMERA, AND THIS FILE IS THE ONE PLACE
    -- WHERE DISABLING A CONTROL IS NOT ENOUGH TO SAY SO.
    --
    -- "I had a gun in hand and accidentally shot it while in spectate. My
    -- preference would be we disable all ped actions while in spectate" -- the
    -- owner, 2026-08-22. client/spectate.lua answers that by holding down every
    -- control a ped acts through, which stops the ENGINE. It does not stop US:
    -- the two readers below are `IsDisabledControlJustPressed`, which sees a
    -- suppressed control on purpose -- the comments beside them say so, twice --
    -- so a suppressed left mouse button still drank a shield potion and a
    -- suppressed scroll wheel still swapped the weapon in the ped's hand. Both
    -- are ped actions, both are the same click the report is about, and neither
    -- goes away by adding another id to a list somewhere else.
    --
    -- IT IS AN ADMIN-ONLY PATH, WHICH IS WHY IT SURVIVED THE FIRST READING. A
    -- dead player never reaches this line -- canArm() below is false for DEAD
    -- and SPECTATING -- but the console's Spectate button requires only that an
    -- admin be in game, so an admin watching a suspect is ALIVE, is holding
    -- their own loadout, and falls straight through.
    --
    -- ABOVE canArm() AND BELOW THE SUPPRESSION, deliberately, and both halves
    -- of that matter. The weapon wheel is suppressed in EVERY phase (#134) and
    -- its own note names DEAD/SPECTATING as one of them, so returning before
    -- that loop would bring GTA's wheel back over the spectate camera. And
    -- closing the panel is the same call the canArm() branch makes below, for
    -- the same reason: a panel left open is a cursor over a shot.
    --
    -- THE NIL-GUARD FAILS OPEN and that is covered elsewhere rather than here:
    -- tools/test_client.lua already pins `function BR.Spectate.active` against
    -- the file that defines it, precisely because voice.lua reaches across the
    -- same way and a rename would silently answer "not spectating" forever.
    if BR.Spectate and BR.Spectate.active() then
        closePanel()
        return
    end

    if not canArm() then return end

    -- NOT WHILE THE PAUSE MENU IS UP, and not while aiming down a scope.
    --
    -- Disabling a control does not stop IsDisabledControlJustPressed from
    -- seeing it -- that is the entire point of the disabled variants -- so the
    -- wheel kept cycling slots while the player was scrolling the pause map,
    -- and kept stealing the scroll that a sniper scope uses to zoom (user,
    -- 2026-08-07). In both cases the wheel belongs to something else.
    -- ONE NATIVE, AND IT IS A PROBED ONE.
    --
    -- The first version of this line also called GetFollowPedCamViewMode and
    -- IsAimCamThirdPersonViewActive, neither of which this project had ever
    -- probed -- and an unknown binding throws. Five consecutive throws suspend
    -- the callback, and THIS callback is the one that suppresses GTA's weapon
    -- wheel and disables ATTACK while a consumable is in hand. So the whole
    -- file went quiet at once: the wheel came back and using a shield made the
    -- ped throw a punch (user, 2026-08-07, both reported together).
    --
    -- The standing rule exists for exactly this and I broke it: a probe for
    -- every native a subsystem leans on, BEFORE the in-game test. Aiming is
    -- all this actually needs to know.
    local scoped = IsPlayerFreeAiming(PlayerId())

    -- MOUSE WHEEL UP CYCLES DOWNWARD THROUGH THE RING, wrapping past the fist
    -- slot at the bottom to slot 5 at the top.
    if not IsPauseMenuActive() and not scoped
       and IsDisabledControlJustPressed(0, WHEEL_UP) then
        local want = inv.active - 1
        if want < MELEE_SLOT then want = SLOTS end
        TriggerServerEvent(BR.Net.INV_SELECT, { slot = want })
    end

    -- SHOOTING A CONSUMABLE USES IT (user call, 2026-08-05). With a med kit
    -- selected the attack button has nothing else to do, and reaching for the
    -- trigger is what a player does with whatever is in their hands. The
    -- control is the player's own ATTACK binding, whatever they set it to.
    -- NOT WHILE THE PANEL IS OPEN. Disabling a control does not stop
    -- IsDisabledControlJustPressed from seeing it -- that is the entire point
    -- of the disabled variants -- so clicking a slot card in the panel was
    -- also firing this, using a consumable the player was only trying to drag
    -- (user, 2026-08-05).
    local held = inv.slots[inv.active]

    -- YOU CAN ONLY SWING WHAT YOU CAN SWING.
    --
    -- The melee controls are live whatever is in your hands, so a player
    -- holding a shield potion or a rifle who taps the light-attack key threw a
    -- punch into the air -- most visibly mid-drink, where the animation fights
    -- the use (user, 2026-08-07). Fists and actual melee weapons swing;
    -- everything else refuses.
    --
    -- ...AND NOT FROM A SEAT, WHICH IS #200 (owner: "while in the driver's seat,
    -- the GTA radio wheel cannot be displayed. I assume it's inadvertently
    -- disabled as part of our weapon wheel hide").
    --
    -- THE HYPOTHESIS WAS RIGHT ABOUT THE BLOCK AND WRONG ABOUT THE LINE. It is
    -- not the weapon-wheel list above -- nothing in that list is on Q, and the
    -- radio wheel is control 85, INPUT_VEH_RADIO_WHEEL, which we have never
    -- disabled anywhere. It is these five. Two of them share the radio wheel's
    -- key, per the FiveM controls reference:
    --
    --    85  INPUT_VEH_RADIO_WHEEL      Q     <- what actually opens it
    --   141  INPUT_MELEE_ATTACK_HEAVY   Q
    --   264  INPUT_MELEE_ATTACK2        Q
    --   140  INPUT_MELEE_ATTACK_LIGHT   R
    --   263  INPUT_MELEE_ATTACK1        R
    --   142  INPUT_MELEE_ATTACK_ALTERNATE  left mouse
    --
    -- GTA reuses Q across contexts precisely because they are exclusive -- you
    -- cannot throw a punch from a car seat -- and this file was disabling the
    -- on-foot half of that pair on EVERY frame of a drive, because `canSwing` is
    -- false for every slot that is not fists or a melee weapon. Which is the
    -- normal state of a player who is driving somewhere with a gun.
    --
    -- SO THE GATE IS THE CONTEXT GTA ALREADY USES, and it costs nothing that was
    -- ever wanted: there is no melee attack to suppress from inside a vehicle.
    -- What it deliberately does NOT touch is the SUPPRESS list above -- #134's
    -- weapon wheel stays disabled in the plane, on the bus, in the lobby and in
    -- a car, exactly as its own note demands, because that is a list about whose
    -- UI owns TAB and this is a list about what the ped's arms can do.
    --
    -- THE PANEL BLOCK BELOW STILL DISABLES ALL FIVE, deliberately. A player with
    -- the inventory open has handed that screen the mouse and the melee keys for
    -- as long as it is up; that is a screen owning a key it is using, not a
    -- suppression leaking into a context that never wanted it.
    --
    -- WHAT IS PROVEN AND WHAT IS NOT, because the difference matters here. What
    -- is proven from the desk: 85 is what opens the radio wheel (it is the one
    -- control every "disable the radio" resource disables), its default key is
    -- Q, 141 and 264 are also on Q, and this file was disabling them on every
    -- frame of a drive. What is NOT proven from the desk is that disabling a
    -- control takes the KEY from a different control sharing it -- the natives
    -- reference does not say either way and this project has no probe for it.
    -- If the wheel still refuses after this lands, that is the answer: the
    -- suspicion moves to control 37, whose suppression is unconditional by
    -- #134's explicit demand, and the fix there is a different shape.
    --
    -- THE ONE-KEYPRESS TEST, since it costs nothing to write down: in a car,
    -- select the FIST slot and try the radio wheel. Fists make `canSwing` true,
    -- which is the one path that never disabled 141 even before this change --
    -- so a wheel that opens on fists and not on a rifle is this bug exactly.
    if not inVehicle() then
        local w = held and BR.Config.WeaponById[held.id] or nil
        local canSwing = (inv.active == MELEE_SLOT) or (w and w.melee) or false
        if not canSwing then
            DisableControlAction(0, 140, true)  -- MELEE_ATTACK_LIGHT
            DisableControlAction(0, 141, true)  -- MELEE_ATTACK_HEAVY
            DisableControlAction(0, 142, true)  -- MELEE_ATTACK_ALTERNATE
            DisableControlAction(0, 263, true)  -- MELEE_ATTACK1
            DisableControlAction(0, 264, true)  -- MELEE_ATTACK2
        end
    end

    if not panelOpen and held and held.kind == BR.ItemKind.CONSUMABLE
       and not inv.using then
        DisableControlAction(0, 24, true)   -- ATTACK: no punching a potion
        DisableControlAction(0, 25, true)   -- AIM
        if IsDisabledControlJustPressed(0, 24) then
            TriggerServerEvent(BR.Net.INV_USE, { slot = inv.active })
        end
    end

    -- While the panel is up the cursor belongs to the panel. Keep-input focus
    -- means the game still reads the mouse, so without this the camera spins
    -- as you reach for a slot (user, 2026-08-05). Movement is deliberately
    -- left alone: this is a screen you use DURING a fight.
    if panelOpen then
        DisableControlAction(0, 1, true)    -- LOOK_LR
        DisableControlAction(0, 2, true)    -- LOOK_UD
        DisableControlAction(0, 24, true)   -- ATTACK
        DisableControlAction(0, 25, true)   -- AIM
        -- EVERY WAY A SEAT FIRES, AND THE NAMES HERE WERE WRONG.
        --
        -- These three lines used to read 68 = VEH_ATTACK, 69 =
        -- VEH_PASSENGER_ATTACK, 70 = VEH_ATTACK2. Checked against the FiveM
        -- controls table (2026-08-22): 68 is VEH_AIM, 69 is VEH_ATTACK, 91 is
        -- VEH_PASSENGER_AIM and 92 is VEH_PASSENGER_ATTACK -- which appeared
        -- NOWHERE in this file.
        --
        -- So the panel suppressed the driver's trigger and the aim, and left
        -- the PASSENGER'S trigger live: a passenger could fire with the
        -- inventory open, which is the one thing this block exists to stop.
        -- The comment being wrong is why nobody noticed -- it named the
        -- control we meant, beside the id of a different one.
        DisableControlAction(0, 68, true)   -- VEH_AIM
        DisableControlAction(0, 69, true)   -- VEH_ATTACK
        DisableControlAction(0, 70, true)   -- VEH_ATTACK2
        DisableControlAction(0, 91, true)   -- VEH_PASSENGER_AIM
        DisableControlAction(0, 92, true)   -- VEH_PASSENGER_ATTACK
        DisableControlAction(0, 106, true)  -- VEH_MOUSE_CONTROL_OVERRIDE
        DisableControlAction(0, 140, true)  -- MELEE_ATTACK_LIGHT
        DisableControlAction(0, 141, true)  -- MELEE_ATTACK_HEAVY
        DisableControlAction(0, 142, true)  -- MELEE_ATTACK_ALTERNATE
        DisableControlAction(0, 257, true)  -- ATTACK2
        DisableControlAction(0, 263, true)  -- MELEE_ATTACK1
        DisableControlAction(0, 264, true)  -- MELEE_ATTACK2

        -- THE PAUSE KEY CLOSES THE PANEL INSTEAD OF PAUSING (user call,
        -- 2026-08-05). Reaching for escape with a menu open means "close the
        -- menu" everywhere else in games, and stacking GTA's pause screen on
        -- top of ours is two interfaces fighting for the same input.
        DisableControlAction(0, 199, true)  -- FRONTEND_PAUSE
        DisableControlAction(0, 200, true)  -- FRONTEND_PAUSE_ALTERNATE
        if IsDisabledControlJustPressed(0, 199)
           or IsDisabledControlJustPressed(0, 200)
           -- Right mouse: the universal "back out of this".
           or IsDisabledControlJustPressed(0, 25) then
            closePanel()
        end
    end
end)

-- The ammo report: 2Hz, decrease-only at the far end, and silent when nothing
-- moved. This is the ONE number the client is the only observer of until M6
-- validates shots server-side; see server/inventory.lua for why that is safe.
BR.Loop.register(BR.Loop.TICK, 'inv.ammo', function()
    if not canArm() or BR.Inv.suspendAmmo then return end

    local slot = inv.slots[inv.active]
    local hash = hashOf(slot)
    if not hash then return end
    -- Only report the weapon the ped is CONFIRMED to be holding. In the frames
    -- between an INV_SET and the grant landing, the engine has the old weapon
    -- (or none) -- and since the server accepts any decrease, reporting there
    -- would empty the new magazine before it was ever fired.
    if applied ~= hash then return end

    local ped = PlayerPedId()

    -- INFINITE AMMO OFF, EVERY TICK -- NOT ONCE PER WEAPON SWITCH.
    --
    -- Asserting it only at grant time was not enough: /brprobe raw, with every
    -- one of our own writes suspended, still showed the magazine frozen and
    -- the totals climbing by one per shot (user, 2026-08-06). A frozen
    -- magazine is what infinite-ammo-clip does, so something is re-setting the
    -- flag after we clear it. Two natives a tick is cheap enough that we can
    -- simply keep clearing it rather than find out what.
    SetPedInfiniteAmmo(ped, false, hash)
    SetPedInfiniteAmmoClip(ped, false)

    -- ONLY WHEN THE ENGINE AGREES THE PED IS HOLDING IT.
    --
    -- `applied` is our own bookkeeping -- what we last GAVE the ped -- and it
    -- keeps saying "carbine" through every frame in which the engine has
    -- quietly stowed the thing: getting into a car, the get-in animation, a
    -- cutscene, a ragdoll. In all of those GetAmmoInPedWeapon reads 0 for a
    -- weapon the ped is not currently holding, and 0 is a DECREASE, so the
    -- report emptied the player's gun and the reserve with it -- permanently,
    -- because decrease-only never gives it back (user, 2026-08-06: "the HUD is
    -- showing 0 bullets while in a vehicle").
    --
    -- Asking the engine what is in the hand costs one native and closes the
    -- whole class: the vehicle case, the animation window that the old
    -- IsPedInAnyVehicle guard raced against, and any future stow we have not
    -- thought of.
    -- NORMALISED ON BOTH SIDES. The engine returns this hash SIGNED and the
    -- config authors it positive, so twenty of the forty weapons in the game
    -- could never satisfy a raw comparison -- and every one of them therefore
    -- had unlimited ammo, silently, because this guard fired on every tick
    -- (user's /brprobe ammo, 2026-08-06: config hash and "ENGINE holds"
    -- printed identically and still compared unequal).
    -- MELEE HAS NO AMMO TO REPORT. A machete has no magazine and no pool, so
    -- everything below it -- the clamp, the decrease-only total, the report --
    -- is arithmetic about a number that does not exist.
    do
        local w = BR.Config.WeaponById[slot.id]
        if w and w.melee then return end
    end

    -- THROWING THE LAST ONE TAKES THE WEAPON WITH IT.
    --
    -- A throwable is not a gun that runs empty -- the engine REMOVES it from
    -- the ped when the last one leaves the hand. So the guard below, which
    -- exists to stop us reporting for a weapon the ped is not holding, fired
    -- on exactly the moment we most needed to report: the slot never reached
    -- zero, so it kept its grenade, and cycling slots handed out another one
    -- (user, 2026-08-07). Same shape as the ammo bug -- a guard that is right
    -- in general and wrong at the one boundary that matters.
    --
    -- Checked BEFORE the held-weapon guard, because by now it is gone.
    if slot.kind == BR.ItemKind.THROWABLE
       and not HasPedGotWeapon(ped, hash, false) then
        if (slot.count or 0) > 0 then
            TriggerServerEvent(BR.Net.INV_AMMO,
                { slot = inv.active, total = 0, clip = 0 })
        end
        return
    end

    local heldOk, held = GetCurrentPedWeapon(ped, true)
    if not heldOk or BR.NormHash(held) ~= BR.NormHash(hash) then return end

    -- Nor while a reload is playing: the magazine is mid-swap and reads as
    -- whatever the animation has reached, which is not a number to build a
    -- reserve calculation on.
    if IsPedReloading(ped) then return end

    -- THE TOTAL IS THE NUMBER THAT MATTERS. The clip is only the split.
    --
    -- Four rounds of this bug were spent watching the wrong number. The model
    -- before this one reported GetAmmoInClip and let the server infer firing
    -- from the direction it moved -- but /brprobe raw showed the magazine
    -- pinned at 5 while GetAmmoInPedWeapon climbed by one per shot, so the one
    -- number we trusted was the one that never moved (user, 2026-08-06).
    --
    -- ox_inventory -- the inventory most FiveM servers actually run -- watches
    -- GetAmmoInPedWeapon and guards it with `if currentAmmo < weaponAmmo`: it
    -- refuses increases outright rather than explaining them. That guard is the
    -- whole answer. The total is what firing consumes, a reload only moves
    -- rounds between the two halves of it, and any RISE is by definition not
    -- something the player did.
    --
    -- So: decrease-only on the total, and the clip rides along purely so the
    -- server can keep the HUD's split honest.
    local granted = math.floor((slot.clip or 0) + reserveFor(slot))
    local total   = GetAmmoInPedWeapon(ped, hash) or 0

    -- THE CLAMP, and the reason this is now immune to whatever is doing it.
    -- The server said we hold `granted` rounds. The engine holding MORE than
    -- that is impossible under honest play, so it is written back down instead
    -- of being explained -- which fixes the runaway at the ped as well as in
    -- the counter. Never upward: writing ammo up is what produced the
    -- unlimited-ammo round.
    if total > granted then
        SetPedAmmo(ped, hash, granted)
        total = granted
    end

    -- ...AND THE OTHER DIRECTION, WHICH USED TO BE THROWN AWAY.
    --
    -- The engine holding FEWER rounds than the server issued is not impossible
    -- and not a cheat: it is the ordinary state of a gun that has been fired
    -- since the last thing the server charged for. Nothing recorded it, so the
    -- next re-grant wrote the server's larger number back onto the ped and the
    -- rounds came back (owner, 2026-08-23). It is recorded here, against the
    -- SERVER's own magazine rather than the laundered mirror -- see `shortfall`
    -- -- and it is subtracted by both write paths.
    --
    -- MEASURED ONLY WHERE THE READ IS TRUSTED. Every guard above this line --
    -- our grant has landed, the ENGINE agrees the ped holds it, no reload is
    -- playing -- exists because those are the states where the ammo natives
    -- answer about a weapon that is not in the hand. A stow reads 0, and 0
    -- recorded here would be a whole holding declared spent.
    do
        local rec = shortfall[inv.active]
        if rec and rec.id == slot.id then
            local said = (rec.svClip or slot.clip or 0) + reserveFor(slot)
            rec.n = math.max(0, math.floor(said) - total)
        end
    end

    -- GET_AMMO_IN_CLIP is a BOOL with an out-param, so Lua gets two returns.
    local _, clip = GetAmmoInClip(ped, hash)
    clip = math.max(0, math.min(clip or 0, total))

    -- THE DISPLAY DOES NOT WAIT FOR THE ROUND TRIP, OR FOR THE REPORT GATE.
    --
    -- The magazine is read straight off the gun in the player's hands, so
    -- there is nothing to check with the server before showing it. It used to
    -- move only when a report went out, once every 500ms, which at any real
    -- rate of fire meant the counter lagged several rounds behind the shots
    -- (user, 2026-08-06: "make it update like 3 or 4x"). This is every tick --
    -- 10Hz -- and costs one NUI message on the frames where it changed.
    --
    -- The RESERVE stays the server's and still arrives with the next INV_SET.
    if clip ~= slot.clip then
        slot.clip = clip
        pushUi()
    end

    -- THROWABLES REPORT REGARDLESS OF serverAmmo, and the server's INV_AMMO
    -- handler has the matching exception for the same reason.
    --
    -- Server ammo counts rounds off validated shot events. A THROW raises no
    -- event: the only thing a grenade produces is its detonation, seconds
    -- later, sometimes never (into water, at nobody). So this report is the
    -- ONLY signal that a grenade left the hand -- and with the blanket return
    -- below sitting above it, the counter sat at 3 while the player threw
    -- them, right up until the "last one taken with it" special case fired
    -- and the whole slot vanished at once (user, 2026-08-08).
    --
    -- Still decrease-only at both ends, so it is as safe as it ever was: the
    -- worst a liar achieves is throwing away their own grenades.
    if slot.kind == BR.ItemKind.THROWABLE then
        local count = total
        if count ~= (slot.count or 0) and count < (slot.count or 0) then
            -- Shown immediately rather than waiting for the round trip, the
            -- same way the magazine is. The server still gets the last word
            -- with the next INV_SET.
            slot.count = count
            pushUi()
            TriggerServerEvent(BR.Net.INV_AMMO,
                { slot = inv.active, total = count, clip = count })
        end
        return
    end

    -- THE REPORT IS NOT RETIRED BY serverAmmo ANY MORE, AND THIS IS THE HALF
    -- THAT ACTUALLY FIXES THE DUPLICATION.
    --
    -- It used to return here. The reasoning was sound and the consequence was
    -- not: M6's server counts rounds off validated shot events, so it has a
    -- better answer THAN THIS ONE FOR THE SHOTS IT SEES -- and it silently keeps
    -- its old answer for every round burnt by a shot it never saw. Nothing else
    -- observes those, so "the server does not want ours" meant nobody had one,
    -- for as long as the match lasted. A blast raises no weaponDamageEvent at
    -- all (server/damage.lua's own 2026-08-08 capture), which puts the whole
    -- airdrop shelf -- the RPG, the grenade launcher and the railgun the owner
    -- reported -- on the never-charged side.
    --
    -- WHAT GOES OUT IS UNCHANGED AND STILL DECREASE-ONLY: the loop below only
    -- speaks when the ENGINE's total has fallen BELOW the last thing the server
    -- said, because rebaseline() anchors that baseline on every INV_SET. It
    -- therefore cannot describe a pickup (a rise, refused at both ends) and it
    -- cannot describe a reload (which moves rounds between the halves and leaves
    -- the total alone). It describes rounds that are gone, which is the one
    -- thing the server cannot see for itself.
    --
    -- The server's matching half refuses to let it move anything but the total
    -- while serverAmmo is on, so the reload the server just paid for is still
    -- the server's -- see the INV_AMMO handler in server/inventory.lua.
    local now = GetGameTimer()
    if now - lastReport.at < (L.ammoReportMs or 150) then return end
    lastReport.at = now

    -- No baseline yet (weapon just switched): take one and say nothing.
    if lastReport.total < 0 then
        lastReport.total, lastReport.clip = total, clip
        return
    end

    -- Nothing moved, or the total went UP. Either way there is nothing to tell
    -- the server -- and a rise must not be forwarded even as a split change,
    -- or it arrives as a reload the reserve did not pay for.
    if total > lastReport.total then return end
    if total == lastReport.total and clip == lastReport.clip then return end

    lastReport.total, lastReport.clip = total, clip
    TriggerServerEvent(BR.Net.INV_AMMO, {
        slot = inv.active, total = total, clip = clip,
    })
end)

-- --------------------------------------------------------------------------
-- Teardown
-- --------------------------------------------------------------------------

RegisterNetEvent(BR.Net.STATE)
AddEventHandler(BR.Net.STATE, function(d)
    if not d then return end
    if d.state == BR.MatchState.WAITING
       or d.state == BR.MatchState.ENDED
       or d.state == BR.MatchState.CLEANUP then
        closePanel()
        clearLocal()
        pushUi()
    end
end)

--- What the local mirror thinks it is holding. Read by client/loot.lua for
--- the pickup prompt ("swap") and by /brinv.
--- @return table
function BR.Inv.local_()
    return inv
end

--- WHY IS THE AMMO REPORT NOT GOING OUT?
---
--- The report loop bails on six separate conditions, and every one of them
--- presents identically from the outside: the gun never runs dry. The Advanced
--- Rifle did exactly that while every other weapon behaved (user, 2026-08-06),
--- and no amount of reading the loop can say WHICH guard fired on a live ped.
---
--- So it reports itself. /brprobe ammo prints this, and the answer is a single
--- line rather than another round of hypotheses.
---
--- "IN A VEHICLE" IS NOT ONE OF THE GUARDS AND HAS NOT BEEN FOR A WHILE (#197).
--- This chain listed it, and the loop does not have it: the old
--- IsPedInAnyVehicle guard was replaced by the GetCurrentPedWeapon check above
--- precisely because the vehicle was the wrong question -- what stops the
--- report is the engine STOWING the weapon, which happens in a seat and in
--- three other places besides. A row naming a guard that does not exist sends
--- the reader to the wrong file, which is the one thing a diagnostic must never
--- do. The vehicle is still reported, as a FACT, under `inVehicle` -- and
--- /brdriveby is the command that knows what to make of it.
--- @return table
function BR.Inv.reportState()
    local ped   = PlayerPedId()
    local slot  = inv.slots[inv.active]
    local hash  = hashOf(slot)
    local heldOk, held = GetCurrentPedWeapon(ped, true)

    local why = nil
    if not canArm() then                    why = 'state is not ALIVE/WARMUP'
    elseif BR.Inv.suspendAmmo then          why = 'suspended by /brprobe raw'
    elseif not slot then                    why = 'active slot is empty'
    elseif not hash then                    why = 'slot holds nothing weapon-shaped'
    elseif applied ~= hash then             why = 'our own grant has not landed yet'
    elseif not heldOk or BR.NormHash(held) ~= BR.NormHash(hash) then
                                            why = 'the ENGINE says the ped holds a different weapon'
    elseif IsPedReloading(ped) then         why = 'mid-reload'
    end

    return {
        slotIndex = inv.active,
        item      = slot and slot.id or nil,
        wantHash  = hash,
        appliedHash = applied,
        engineHash  = heldOk and held or nil,
        engineTotal = hash and GetAmmoInPedWeapon(ped, hash) or nil,
        serverClip  = slot and slot.clip or nil,
        serverPool  = slot and reserveFor(slot) or nil,
        -- Rounds this ped has spent that the server has not charged for. A
        -- non-zero value here IS the 2026-08-23 duplication, caught: it is the
        -- amount a slot switch would have handed back. See `shortfall`.
        shortfall   = slot and shortfallFor(inv.active, slot) or nil,
        lastTotal   = lastReport.total,
        inVehicle   = yes(IsPedInAnyVehicle(ped, false)),
        blockedBy   = why,
    }
end

-- --------------------------------------------------------------------------
-- Why can a passenger not fire? (#197)
-- --------------------------------------------------------------------------

--- Everything THIS FILE knows about the question. The engine half -- the seat,
--- the vehicle, what is actually in the hand, which controls are live -- is
--- gathered by client/debug.lua and merged on top, because those are reads that
--- only mean anything sampled across frames.
--- @return table
function BR.Inv.driveByFacts()
    local slot = inv.slots[inv.active]
    return {
        state        = BR.State.me.state,
        canArm       = canArm(),
        panelOpen    = panelOpen,
        slotIndex    = inv.active,
        item         = slot and slot.id or nil,
        wantHash     = hashOf(slot),
        appliedHash  = applied,
        driveByAt    = driveBy.at,
        driveByCount = driveBy.count,
    }
end

--- THE VERDICT, AND IT IS PURE ON PURPOSE.
---
--- The same argument BR.Native.teamFor makes: this decides which of four
--- indistinguishable causes the owner is looking at, the owner cannot easily
--- stage all four in game, and a wrong answer here sends somebody to the wrong
--- file for a day. So it takes its world as an argument and is settled at the
--- desk by tools/test_client.lua.
---
--- ORDER IS THE DESIGN. Each branch is checked before the ones it would
--- otherwise mask, and the two that are OURS -- a panel we left open, a control
--- something disabled -- come before the two that are the ENGINE's, so we never
--- blame the platform for our own bug.
---
--- `f.permitted` IS OUR CLAIM, NOT THE ENGINE'S ANSWER (#206).
---
--- It is the `driveby` field in br_lib/config/weapons.lua, read through
--- BR.DriveBy.permits: do we say a standard car seat accepts the weapon the
--- active slot names? `true`, `false`, or `nil` when the caller did not work it
--- out (a partial world, which the suite passes deliberately).
---
--- ONLY `== true` IS A CLAIM. Both of the other two mean "we are not saying
--- yes", and the branches below are written that way round on purpose: the
--- verdict that accuses our own table (`stowed-unexpected`) must only fire when
--- we actually made the claim that would have sent a player to that slot.
---
--- The three states ARE told apart one row higher up, in client/debug.lua, where
--- "-" and "we say the seat REFUSES it" are different things to read.
---
--- @param f table  BR.Inv.driveByFacts() plus the engine half
--- @return string code, string sentence
function BR.Inv.driveByVerdict(f)
    f = f or {}
    local want   = BR.NormHash(f.wantHash)
    local grant  = BR.NormHash(f.appliedHash)
    local engine = BR.NormHash(f.engineHash)
    local bare   = BR.NormHash(UNARMED)

    if not yes(f.inVehicle) then
        return 'onfoot',
            'You are not in a vehicle, so there is nothing here to explain. '
            .. 'Get into a seat and run this again.'
    end
    if not f.canArm then
        return 'state',
            'This client will not arm you at all in state "'
            .. tostring(f.state or '?')
            .. '" -- that is the lobby/bus/descent gate, not a drive-by rule.'
    end
    if want == nil then
        return 'unarmed',
            'The active slot holds nothing that can be fired. Select a weapon '
            .. 'slot first.'
    end
    if yes(f.panelOpen) then
        return 'panel',
            'The inventory panel is open, and it deliberately takes ATTACK, '
            .. 'AIM and both vehicle attack controls while it is up. Close it.'
    end
    if f.blocked then
        return 'control',
            'Control ' .. tostring(f.blocked) .. ' was DISABLED on at least one '
            .. 'frame of this sample. Something is holding the trigger down '
            .. 'every frame -- that is a script, ours or another resource, and '
            .. 'it is not the engine.'
    end
    if (f.driveByCount or 0) == 0 then
        return 'never-asked',
            'We have never called SetPlayerCanDoDriveBy on this client. The '
            .. 'inv.apply tick is meant to do that every tick, so it is not '
            .. 'running -- check /brperf for a suspended callback.'
    end
    if grant ~= want then
        return 'ungranted',
            'Our own grant has not landed: the mirror wants this weapon and we '
            .. 'have not put it on the ped yet. Wait a tick and run it again.'
    end
    if engine == nil or engine == bare then
        if f.permitted == true then
            return 'stowed-unexpected',
                'THE ENGINE HAS STOWED A WEAPON WE SAY THIS SEAT ACCEPTS, so OUR '
                .. 'TABLE IS WRONG. `driveby = true` in br_lib/config/weapons.lua '
                .. 'is what client/driveby.lua reads before telling a passenger to '
                .. 'switch to a slot -- and this readout has just proved it would '
                .. 'send them to a weapon that does not fire. Set this weapon\'s '
                .. '`driveby` to false and say which seat this was.'
        end
        return 'stowed',
            'THE ENGINE HAS STOWED THE WEAPON. It is still in your inventory and '
            .. 'it is not in your hands, so there is nothing to fire. This is '
            .. 'GTA\'s own per-seat rule, not ours: a seat permits a list of '
            .. 'weapon groups and a standard car seat lists unarmed, one-handed '
            .. 'and thrown. A rifle, shotgun, sniper or MG is not on that list, '
            .. 'no native lifts it, and redefining the list in a data file was '
            .. 'TRIED AND IGNORED BY THE GAME (2026-08-22, docs/vehicle-data.md). '
            .. 'Switch to a slot holding a pistol, a small SMG or a thrown weapon.'
    end
    if engine ~= want then
        return 'otherweapon',
            'The engine says the ped is holding a weapon that is not the one '
            .. 'the active slot names. That is not a drive-by problem -- read '
            .. '/brprobe ammo, and expect the strip check to take it back.'
    end
    -- THE POSITIVE ANSWER. The engine holding the weapon IN A SEAT is the whole
    -- of "this seat accepts it", and saying "nothing here explains it" to a
    -- player who is holding a pistol in a passenger seat reads as a failure.
    -- It is deliberately keyed on OUR claim agreeing, so that the row above and
    -- this line can never both be believed while they disagree.
    if f.permitted == true then
        return 'armed',
            'The engine is letting you hold this weapon IN THIS SEAT, which is '
            .. 'the whole of the seat rule saying yes. Nothing about the seat is '
            .. 'stopping you firing.'
    end
    return 'unexplained',
        'Nothing here explains it: you are in a seat, the engine agrees you are '
        .. 'holding the weapon the slot names, the permission is asserted and no '
        .. 'attack control was seen disabled. Paste this whole readout -- it '
        .. 'rules out all four of the causes #197 listed.'
end

--- Force the active slot back onto the ped.
---
--- Called by skydive.lua after its hard disarm (RemoveAllPedWeapons, which
--- takes the real weapon with the parachute). Without this, landing with a gun
--- would leave the mirror thinking it was applied and the ped empty-handed.
function BR.Inv.reapply()
    applied = nil
    applyActive(true)
end

-- --------------------------------------------------------------------------
-- Where did the rounds go? (/brammo)
-- --------------------------------------------------------------------------

--- What the last /brammo counted, per pool, so the next one can print the
--- CHANGE. Declared here rather than inside the command because the command is
--- a closure built at load time -- see tools/check_forward_locals.lua.
---
--- nil until the first dump, and that is the honest answer rather than a zeroed
--- table: "nothing has changed since a measurement nobody took" is a sentence a
--- diagnostic must not print.
local lastHeld = nil

--- Everything three parties believe about this player's ammunition, side by
--- side, in the F8 console.
---
--- IT EXISTS BECAUSE THE OWNER HAD NO WAY TO CHECK ANY OF THIS. The 2026-08-23
--- report was "it seemed to have a different amount of ammo than what the HUD
--- showed, then once depleted, switching between slots gave me more ammo" --
--- two sentences describing FOUR numbers that were never printed anywhere: what
--- the server says the magazine holds, what the pool holds, what the ENGINE says
--- is in the gun, and what this file has recorded as spent-but-uncharged. The
--- HUD shows the first two and the gun obeys the third, so a disagreement
--- between them is invisible from inside the game and reads as "the ammo is
--- wrong", which is the least actionable bug report a playtest can produce.
---
--- WHY THIS AND NOT /brprobe ammo. That one watches the ACTIVE weapon across
--- time and answers "is the report loop running" -- it is a stopwatch. This is a
--- still photograph of ALL FIVE SLOTS at one instant, which is the only shape
--- that can answer a question about SWITCHING: the slot you are not holding is
--- exactly the one whose numbers nothing else prints.
---
--- DIFFERENCES ARE MARKED, because a table of five identical-looking rows is
--- how the last one hid. A row whose server total and engine total disagree gets
--- a `!`, and the deficit that disagreement produced is printed next to it.
---
--- Console only, by design: this is a diagnostic for a person reading a log, and
--- nothing here belongs on a player's screen.
---
--- ═══ AND IT NOW PRINTS `held` AND A DELTA, WHICH IS WHAT THE NEXT BUG NEEDED
---     (owner, 2026-08-23, second report) ═══
---
--- The drop/pickup round trip was found with this command and it took two dumps
--- and a careful eye, because what it printed was five DISTRIBUTIONS and the
--- question was about a TOTAL. His two rows read `0 0 0 0 0` and `1 0 1 1 0` --
--- a magazine that went up beside a pool that did not move -- and the round that
--- had actually been created was three of them, minted into the pool and then
--- spent back down by the INV_AMMO floor before he looked. Every column was
--- honest and none of them said "you have more ammunition than you did".
---
--- `held` is the number the invariant is actually about: everything this player
--- has for a pool, magazines included, which is the quantity docs/terminology.md
--- says an empty pool cannot raise. And the delta is against the LAST /brammo,
--- because that is how the command is used -- dump, do the suspicious thing,
--- dump again -- so the diff the owner was doing by eye is done for him. A drop
--- and a pickup with nothing else touched would have printed `+3 since the last
--- /brammo` on the line above his railgun, and there is no reading of that line
--- in which the ammunition was moved rather than made.
RegisterCommand('brammo', function()
    local ped = PlayerPedId()
    local st  = BR.Inv.reportState()

    print('=== ammo ===')
    print(('  state %s   active slot %d   serverAmmo %s')
        :format(tostring(BR.State.me.state), inv.active,
                tostring(((BR.Config.Combat or {}).serverAmmo) == true)))
    if st.blockedBy then
        print(('  the report loop is NOT running: %s'):format(st.blockedBy))
    end

    print('  slot  item             mag  pool  said  engine  spent')
    for i = 1, SLOTS do
        local slot = inv.slots[i]
        if not slot then
            print(('   %s %d  --'):format(inv.active == i and '>' or ' ', i))
        else
            local w    = BR.Config.WeaponById[slot.id]
            local rec  = shortfall[i]
            local sv   = (rec and rec.id == slot.id and rec.svClip)
                or slot.clip or 0
            local pool = reserveFor(slot)
            local said = math.floor(sv) + pool

            -- THE ENGINE IS ONLY ASKED ABOUT THE WEAPON IT IS ACTUALLY HOLDING.
            -- RemoveAllPedWeapons has taken every other one off the ped, so
            -- GetAmmoInPedWeapon would answer 0 for four rows out of five and
            -- the readout would invent four faults. '-' is the honest answer:
            -- not stowed, not empty -- not on this ped at all.
            local hash = hashOf(slot)
            local eng  = nil
            if hash and applied == hash then
                eng = GetAmmoInPedWeapon(ped, hash) or 0
            end

            print(('   %s %d  %-15s %4s %5d %5d %7s %6s%s')
                :format(inv.active == i and '>' or ' ', i,
                        tostring(slot.id),
                        slot.clip and tostring(math.floor(slot.clip)) or '-',
                        pool, said,
                        eng and tostring(eng) or '-',
                        rec and tostring(rec.n or 0) or '-',
                        (eng and eng ~= said) and '  !' or ''))

            if w and w.clip and slot.clip and math.floor(slot.clip) > w.clip then
                print(('        magazine %d is bigger than %s\'s configured %d')
                    :format(math.floor(slot.clip), slot.id, w.clip))
            end
        end
    end

    -- EVERYTHING THIS PLAYER HAS FOR A POOL, MAGAZINES INCLUDED.
    --
    -- The rows above print the SPLIT and the invariant is about the SUM: rounds
    -- move between a magazine and its pool for free, and no route may raise the
    -- two together. Adding them up here is what makes "a round was created"
    -- something the readout says rather than something the reader works out.
    local held = {}
    for _, pool in ipairs(BR.Config.AmmoOrder or {}) do
        held[pool] = math.floor(inv.ammo[pool] or 0)
    end
    for i = 1, SLOTS do
        local slot = inv.slots[i]
        local w    = slot and BR.Config.WeaponById[slot.id]
        -- `held[w.ammo] ~= nil`, not `held[w.ammo]`: a pool sitting at 0 is
        -- exactly the case this whole readout was built for, and 0 IS TRUTHY IN
        -- LUA -- so the bare test happens to work and says the wrong thing. The
        -- question is whether AmmoOrder listed the pool at all.
        if w and w.ammo and held[w.ammo] ~= nil then
            held[w.ammo] = held[w.ammo] + math.floor(slot.clip or 0)
        end
    end

    for _, pool in ipairs(BR.Config.AmmoOrder or {}) do
        local was   = lastHeld and lastHeld[pool]
        local delta = was and (held[pool] - was) or 0
        print(('  pool %-8s %4d   held %4d%s'):format(
            pool, math.floor(inv.ammo[pool] or 0), held[pool],
            delta ~= 0
                and ('   %+d since the last /brammo'):format(delta)
                or ''))
    end
    lastHeld = held

    print('  mag    what the mirror shows -- the ENGINE\'s magazine, written')
    print('         every tick so the counter follows the gun')
    print('  said   what the SERVER last said this weapon holds in total')
    print('  engine what the ENGINE says the ped holds, magazine included')
    print('  spent  rounds burnt that the server has not charged for; this is')
    print('         subtracted from every re-grant, so a `!` row is the bug')
    print('         being contained rather than the bug happening')
    print('  held   pool PLUS every magazine drawing on it. Nothing may raise')
    print('         this but a pickup: a `+` after a drop, a switch or a')
    print('         reload is a round that was made rather than moved')
end, false)
