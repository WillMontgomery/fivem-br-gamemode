-- The revive key: minted at elimination, collected off the ground, bought at an
-- ambulance, and spent by a squadmate holding a key over the spot where it lies.
-- #219 steps 4 and 5.
--
-- ═══════════════════════════════════════════════════════════════════════════
-- WHERE THE REVIVE HAPPENS, AND WHY IT IS NOT AT AN AMBULANCE
-- ═══════════════════════════════════════════════════════════════════════════
--
-- A LIVE SQUADMATE HOLDS `interact` AT THE KEY'S OWN RECORDED POINT. Not at the
-- corpse, not at an ambulance, not anywhere a player has to be PUT.
--
-- NOT AT THE CORPSE, AND THAT IS THE LOAD-BEARING HALF. The record already
-- carries x/y/z, copied off the body at mint time specifically so the key does
-- not follow it. Ruling against those two numbers re-uses the exact circle that
-- already decides collection and costs no new geometry. Ruling against the ped
-- instead would inherit two shipped defects at once: #163's clone, which
-- "CRAWLS AWAY" on the reviver's machine while the real body is pinned on its
-- own, and 33ca88c's finding that a corpse's position is a DEATH RAGDOLL --
-- "the one thing this file already knows do not replicate reliably"
-- (citizenfx/fivem#2436, open). A hold measured to a body that drifts dies at
-- two seconds with a full ring on screen and nothing to say why.
--
-- NOT AT AN AMBULANCE, EITHER, and the reason is placement. Buying keys at a van
-- is a number leaving a balance and touches no vehicle state; STANDING A LIVING
-- PED UP at one is a placement, and client/spawn.lua states what that costs --
-- the ground probe "is actively wrong indoors: it searches downward from fifty
-- metres up, which for a death inside a building finds the roof". The 23
-- persistent ambulances of #219 step 3 do not exist either, so an
-- ambulance-only revive would make a squad's whole path back depend on finding
-- an ambient van.
--
-- SO THEY COME BACK WHERE THEY FELL, WITH NO PLACEMENT AT ALL.
-- BR.Net.REVIVED is the existing OUT->ALIVE resurrection (#144's held death) and
-- it resurrects at `GetEntityCoords(ped)` on the machine that owns the ped --
-- the body's own position, exactly, with no probe and no server sample in the
-- loop. It also carries ClearPedTasksImmediately, initHealthModel and cleanPed
-- ("any time revive is processed, please clean the ped" -- owner, 2026-08-28)
-- for no new client code.
--
-- ═══════════════════════════════════════════════════════════════════════════
-- WHAT THEY COME BACK WITH: NOTHING, AND IT IS FREE
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Owner, 2026-08-30: "if their key was used to revive them, they lost their
-- inventory."
--
-- NOT ONE LINE IMPLEMENTS THAT. BR.Loot.deathBox ran one line above the mint and
-- called BR.Inv.dropAll, which sets every slot to false and zeroes every ammo
-- pool ON THE LIVE INVENTORY, then pushed the emptied inventory to the client.
-- The eliminated player's server-side kit was already gone at the moment the key
-- was minted. A revive that restores nothing produces his ruling by
-- construction -- and anything that tried to hand kit back would be DUPLICATING
-- loot that is already scattered on the ground in the 4.6m ring around them.
--
-- HEALTH IS BR.Config.Match.dbnoReviveHp -- the same 30 a squadmate's pick-up
-- hands back, read at call time so the two can never drift. See
-- config/revivekey.lua on why there is no `reviveHp` of its own.
--
-- ═══════════════════════════════════════════════════════════════════════════
-- THE KEY IS MINTED ON THE EDGE THAT SPILLS THE INVENTORY. THE SAME ONE
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Owner, 2026-08-30:
--
--   "During the bleed out, if they are revived in-person there, they can keep
--    their inventory... The moment that bleed out timer ends and they go to
--    spectate - their key is created and their inventory is spilled on the
--    ground"
--
-- ONE EVENT, NOT TWO -- so the two must not be able to disagree, and the only
-- way to guarantee that is to give them ONE CALL SITE rather than two rules that
-- happen to agree today. `BR.ReviveKey.onEliminated` is called from
-- server/combat.lua on the line below `BR.Loot.deathBox`, inside the same `if m`
-- guard, above the state change, from the same two values (`m`, `src`) and
-- against the same `entry.pos`.
--
-- WHAT THAT BUYS, PRECISELY -- and the precision matters, because the obvious
-- statement of it is false:
--
--   IT IS NOT "a key exists exactly when items were spilled". `BR.Loot.deathBox`
--   returns early when the player was carrying nothing (`#contents == 0`), and a
--   player eliminated with an empty inventory must still be recoverable. The
--   invariant is about the EDGE, not the outcome.
--
--   IT IS: the key is minted on exactly the code path that forfeits an
--   inventory, and on no other. Which makes the owner's table true by
--   construction rather than by two rules being kept in step:
--
--     picked up in person during bleed-out -> never reaches eliminate() at all,
--       so no deathBox and no key. Their kit is still on them.
--     bleed-out expires -> eliminate() -> deathBox AND a key, together.
--
-- AND THE #144 HELD DEATH IS THE PROOF THAT THE PLACEMENT IS LOAD-BEARING. A
-- player who dies before the match starts is routed through `holdForStart`,
-- which returns BEFORE the death box -- so they keep their inventory and, now,
-- get no key, with no branch written here to say so. Putting the mint anywhere
-- else in eliminate() (above the `beforeTheMatch` guard, or after the state
-- change) would have handed a key to somebody who is about to be revived for
-- free and never lost anything. tools/test_revivekey.lua drives that case.
--
-- ═══════════════════════════════════════════════════════════════════════════
-- WHERE THE RECORD LIVES, AND WHY IT IS NOT A SQUAD TABLE
-- ═══════════════════════════════════════════════════════════════════════════
--
-- The key is OWNED BY THE SQUAD but IDENTIFIED BY THE PLAYER IT BRINGS BACK, and
-- those are different facts. It is stored on the eliminated player's roster
-- entry as `entry.reviveKey`, and the squad half is derived -- "this squad's
-- outstanding keys" is a walk of the roster filtered on `squadId`, which
-- server/party.lua and server/combat.lua both already do for other reasons.
--
-- A SQUAD-INDEXED TABLE WOULD HAVE BEEN THE OBVIOUS SHAPE AND IT IS THE WRONG
-- ONE, for a reason this codebase has already paid for once (#161): a second
-- table is a second thing that has to be torn down, and every teardown path has
-- to remember it. On the roster entry it inherits all of them for free:
--
--   * MATCH CLEANUP and WALKING OUT both clear it, because both go through
--     `BR.Match.resetPlayer` -- the single function #161 exists to have created.
--   * A DISCONNECT takes it with the entry: `BR.Roster.remove` pulls the entry
--     out of the roster, so a leaver's key stops being found by any walk on the
--     same tick their body stops being findable. #219's note that "a
--     disconnected player is not resurrectable in the same way" is therefore
--     satisfied by construction, with no test on LEFT anywhere in this file.
--   * IT IS IN NEITHER ROSTER ALLOWLIST, the question server/roster.lua asks of
--     every new field. Not PUBLIC_FIELDS: that goes to every client in the
--     match, and whether a squad can afford to come back is exactly what the
--     squad that killed them would like to know. Not RINGMASTER_FIELDS: the
--     admin console cannot act on it.
--
-- ═══════════════════════════════════════════════════════════════════════════
-- COLLECTION IS A SERVER PROXIMITY TEST, NOT A CLIENT MESSAGE
-- ═══════════════════════════════════════════════════════════════════════════
--
-- There is no `REVIVEKEY_TAKE` and there must not be one. The server already
-- samples every player's position four times a second, server-side, with
-- GetEntityCoords -- server/roster.lua's note on why it is not asked of the
-- client applies here word for word -- and the key lies at a position this file
-- wrote down itself. So "did a squadmate walk over it" is answerable HERE, from
-- two numbers neither of which a client has ever touched.
--
-- WHAT THAT DELETES: a net event, a client file, a trust boundary, and a string
-- the owner has not written. See config/revivekey.lua's `collectM` for the full
-- argument against a prompt.
--
-- THE LATENCY IS THE SAMPLER'S, up to 250ms. That is imperceptible for walking
-- over something and it is the same freshness the storm damages people on.
--
-- ═══════════════════════════════════════════════════════════════════════════
-- BUYING IS THE FIRST TIME A SAVED BALANCE IS SPENT INSIDE A MATCH
-- ═══════════════════════════════════════════════════════════════════════════
--
-- config/shop.lua carries the ruling (owner, 2026-08-29, answering #224, #219
-- and #222 together): the SAVED balance, "because at warmup a player's
-- match-Volts are zero and the saved balance is the only pot that exists".
--
-- THAT ARGUMENT DOES NOT APPLY HERE AND THE ANSWER STILL DOES. This purchase
-- happens mid-match, where `voltsPickedUp` is not zero and a second pot really
-- does exist -- so the reason he gave for the shop is absent, and the ruling he
-- gave is not. It is flagged in the report rather than re-litigated in code:
-- one currency for both purchases is worth more than a second rule, and picking
-- the other pot here would be this file deciding a thing he has decided.
--
-- SO IT GOES THROUGH BR.Market.charge, exactly as the shop does -- the same
-- DynamoDB conditional write, the same reservation against the session cache,
-- the same shortfall sentence, and no new wording. See `buy`.
--
-- ═══════════════════════════════════════════════════════════════════════════
-- EVERY WORD THIS FILE SPEAKS COMES OUT OF BR.Config.ReviveKey.copy
-- ═══════════════════════════════════════════════════════════════════════════
--
-- The owner listed six lines on 2026-08-30 and asked for the feature to ship
-- rather than wait on him polishing them, so all six live in ONE table in
-- config/revivekey.lua and this module holds no string of its own. `say()` below
-- is the only path to a player, it takes its text as an argument, and it returns
-- silently when the table has nothing for it -- so deleting a line from the
-- config makes the game quieter rather than making it print a fallback somebody
-- else wrote.
--
-- THREE OF THE SIX REACH PLAYERS FROM HERE (collected, bought, expired). The
-- other three are world prompts and belong to client/revivekey.lua.
--
-- AND A COMPLETED REVIVE SAYS NOTHING AT ALL. BR.Combat.revive ends with "%s
-- picked you up." / "You picked %s up."; this path deliberately does not borrow
-- them. There is no seventh line, the subject watches their own body stand up,
-- and the reviver's ring closes -- see the report.

BR = BR or {}
BR.ReviveKey = {}

local K = BR.Config.ReviveKey

--- The owner's wording, or nothing.
---
--- READ THROUGH A FUNCTION rather than captured into a local at load, because
--- config/revivekey.lua is a shared file an operator may reload and because a
--- captured copy is one more thing that can be stale while looking correct.
--- @return table
local function copy()
    return (K and K.copy) or {}
end

--- Tell somebody one of the owner's six lines.
---
--- THE ONLY PATH FROM THIS MODULE TO A PLAYER'S SCREEN, and it is deliberately
--- the only one: tools/test_revivekey.lua asserts there is exactly one
--- BR.Server.notify call site in this file and that every string that leaves it
--- is a member of BR.Config.ReviveKey.copy. A second call site with a literal in
--- it is how invented copy ships wearing the owner's authority.
---
--- SILENT ON A MISSING LINE. No default, no `or 'something'`.
--- @param who integer|integer[]
--- @param line string|nil
--- @param tone string|nil
local function say(who, line, tone)
    if type(line) ~= 'string' or line == '' then return end
    if not (BR.Server and BR.Server.notify) then return end
    BR.Server.notify(who, line, tone or 'info', { ms = 4000 })
end

--- Did a native declared BOOL say yes?
---
--- The `isTrue` idiom, and this project has shipped the bug it prevents ten
--- times. A FiveM native declared BOOL hands Lua a number on some builds and a
--- boolean on others, and IN LUA `0` IS TRUTHY -- so `if DoesEntityExist(e)` is
--- true for an entity that does not exist. Here that would mean selling a revive
--- key at an ambulance that has been blown up.
--- @param v any
--- @return boolean
local function isTrue(v)
    return v == true or v == 1
end

--- Purchases waiting on DynamoDB. [squadId] = true.
---
--- ═══ WHY A SECOND GUARD ON TOP OF THE MARKET'S OWN ═══
---
--- BR.Market.charge already reserves the amount against the session cache before
--- it asks the row, so the VOLTS cannot be spent twice by a second press
--- arriving during the round trip. That protects the money and not the goods.
---
--- The goods here are a set of keys shared by a squad, and two presses from two
--- DIFFERENT squadmates are two different sources with two different
--- reservations -- so the market would happily take 25 Volts from each of them
--- for the same set of keys, and the second purchase would mark keys that were
--- already held. One charge, one grant; a squad that is mid-purchase is refused.
---
--- KEYED ON THE SQUAD because that is what is being bought for, and squad ids
--- are match-namespaced (server/party.lua), so this cannot collide across
--- parallel matches. Cleared in the callback, which BR.Market.charge guarantees
--- always runs.
local buying = {}

--- Is the feature switched on and configured?
--- @return boolean
local function enabled()
    return K ~= nil and K.enabled == true
        and (tonumber(K.expiryMs) or 0) > 0
end

--- Server natives this file leans on, checked ONCE rather than guessed at.
---
--- server/ambheal.lua's pattern and its reason: almost nothing about a vehicle
--- is answerable on the server, so the handful that are get checked at load and
--- consulted per call rather than assumed. Without
--- NetworkGetEntityFromNetworkId there is no way to turn the net id a client
--- names into a vehicle, and the honest behaviour is to refuse every purchase
--- rather than to sell keys at an unchecked ambulance.
local can = {
    entityFromNet = type(NetworkGetEntityFromNetworkId) == 'function',
}

if enabled() and not can.entityFromNet then
    print('^3[br_core] revivekey: NetworkGetEntityFromNetworkId is missing on '
        .. 'this build -- keys can be collected but never bought^7')
end

local stat = {
    minted = 0, collected = 0, expired = 0, bought = 0, refused = 0,
    -- The hold's own counters. `stops` is the number that reads a playtest: a
    -- string of stops with the same reason is a hold being killed and re-armed,
    -- which is what a player experiences as "the ring fills and nothing happens"
    -- -- the exact symptom client/dbno.lua spent four rounds on.
    holds = 0, stops = 0, revived = 0,
}

--- Every member of a squad in a match, as server ids.
---
--- THE WHOLE SQUAD INCLUDING THE ONE WHO IS OUT. A key's owner is spectating
--- their own body and "your squad can bring you back" is the single most useful
--- thing they could be told, so they are on the list rather than filtered off
--- it. The audience is the same squad-only one server/party.lua's beacon already
--- serves; nothing here reaches a player outside it.
--- @param squadId any
--- @param matchId any
--- @return integer[]
local function squadSrcs(squadId, matchId)
    local out = {}
    if not squadId or not matchId then return out end
    BR.Roster.each(
        function(e) return e.squadId == squadId and e.matchId == matchId end,
        function(src) out[#out + 1] = src end)
    return out
end

-- ---------------------------------------------------------------------------
-- Minting
-- ---------------------------------------------------------------------------

--- A player has just stopped being in the match. Leave their squad a key.
---
--- CALLED FROM server/combat.lua, BESIDE BR.Loot.deathBox, AND FROM NOWHERE
--- ELSE. See this file's header for why that placement is the whole design.
---
--- ═══ SOLOS GET NO KEY, AND THE GATE IS `squadId` RATHER THAN THE MODE ═══
---
--- "owned by the squad" is not a thing a solo player has. Gating on the mode
--- would be a second reader of a fact `entry.squadId` already carries -- and
--- server/combat.lua's `tellSquad` gates the identical way one screen above this
--- call, so the two agree by using the same field rather than by both being
--- right about the mode.
---
--- THE LAST MEMBER OF A SQUAD STILL GETS ONE. There is nobody left to collect
--- it, so it will lie there and expire -- which costs nothing and is better than
--- a special case that would also have to decide what "last" means while a
--- purchase is in flight.
---
--- @param m table|nil    the match, as combat.lua has it
--- @param src integer
--- @return table|nil     the record, for the caller's log and for tests
function BR.ReviveKey.onEliminated(m, src)
    if not enabled() then return nil end
    if not m then return nil end

    local e = BR.Roster.get(src)
    if not e or not e.squadId then return nil end

    -- WHERE THE BODY IS, READ THE WAY THE DEATH BOX READS IT. `entry.pos` is the
    -- server's own sample and combat.lua's note applies to both of us: "what
    -- they were carrying and where they were standing are both still true at
    -- exactly this moment". One line later the roster sweep has opinions.
    local pos = e.pos
    if not pos then return nil end

    -- ALREADY HAS ONE. Not reachable through eliminate() -- `canDie` refuses a
    -- player who is already OUT -- but this function is public and the cost of
    -- being wrong is a pickup that jumps to a new position, so the second mint
    -- is refused rather than allowed to overwrite the first.
    if e.reviveKey then return e.reviveKey end

    local now = GetGameTimer()
    e.reviveKey = {
        -- WHERE THE PICKUP LIES. Copied rather than referenced: `entry.pos` is
        -- overwritten in place by the sampler, and a key that followed the
        -- corpse would follow it through every physics nudge a body takes.
        x = pos.x, y = pos.y, z = pos.z,
        mintedAt  = now,
        -- WHEN THE THING ON THE GROUND GOES AWAY -- not when the key does. See
        -- config/revivekey.lua: "They can still purchase" is the other half of
        -- the same sentence that set this timer.
        expiresAt = now + (tonumber(K.expiryMs) or 180000),
        -- FALSE UNTIL COLLECTED OR BOUGHT. The one field step 5 will clear.
        held = false,
        -- HOW THE SQUAD CAME BY IT. For the console line only -- a bought key is
        -- identical to a fetched one (owner, 2026-08-30, answering Q16) and
        -- nothing may branch on this.
        via = nil,
    }
    stat.minted = stat.minted + 1

    print(('[br_core] revivekey: minted for %s (%d), squad %s, pickup at '
        .. '(%.1f, %.1f) for %.0fs')
        :format(tostring(e.name), src, tostring(e.squadId),
                pos.x, pos.y, (tonumber(K.expiryMs) or 180000) / 1000))

    return e.reviveKey
end

-- ---------------------------------------------------------------------------
-- Reading the squad's keys
-- ---------------------------------------------------------------------------

--- Is there still something on the ground for this key?
--- @param rec table|nil
--- @param now integer
--- @return boolean
local function pickupLive(rec, now)
    return rec ~= nil and rec.held ~= true and now < (rec.expiresAt or 0)
end

--- Every key this squad could still be given, held or not.
---
--- ONE WALK, ONE PREDICATE, USED BY THE PURCHASE AND BY /brkey -- so what the
--- diagnostic reports and what the purchase acts on cannot be two different
--- answers. server/loot.lua's `mayFix` carries the same argument for the same
--- reason: "a second copy would be a reader that agrees with the rule until the
--- day the rule changes, which is the day you are reading it."
---
--- MATCH-FILTERED AS WELL AS SQUAD-FILTERED. Squad ids are match-namespaced so
--- this is belt and braces, and it is the same pair server/combat.lua's
--- `tellSquad` uses.
---
--- @param squadId any
--- @param matchId any
--- @return table[]  { src, entry, rec }, unheld first is NOT guaranteed
function BR.ReviveKey.forSquad(squadId, matchId)
    local out = {}
    if not squadId or not matchId then return out end
    BR.Roster.each(
        function(e)
            return e.squadId == squadId and e.matchId == matchId
               and e.reviveKey ~= nil
        end,
        function(src, e)
            out[#out + 1] = { src = src, entry = e, rec = e.reviveKey }
        end)
    return out
end

--- How many of this squad's keys are still unheld -- i.e. what 25 Volts buys.
--- @param squadId any
--- @param matchId any
--- @return integer
function BR.ReviveKey.outstanding(squadId, matchId)
    local n = 0
    for _, k in ipairs(BR.ReviveKey.forSquad(squadId, matchId)) do
        if k.rec.held ~= true then n = n + 1 end
    end
    return n
end

--- Does this squad hold a key for this player? The question step 5 will ask.
---
--- PUBLISHED NOW, WITH NO CALLER, AND THAT IS DELIBERATE -- it is the one thing
--- step 5 needs from this file, and writing it here means the resurrection work
--- reads the record through a function rather than reaching into
--- `entry.reviveKey.held` from another file and freezing this shape.
--- @param src integer
--- @return boolean
function BR.ReviveKey.heldFor(src)
    local e = BR.Roster.get(src)
    return e ~= nil and e.reviveKey ~= nil and e.reviveKey.held == true
end

-- ---------------------------------------------------------------------------
-- The sweep: collection and expiry
-- ---------------------------------------------------------------------------

--- Mark a key held, however it was come by, and tell the squad which.
---
--- ONE FUNCTION FOR BOTH DOORS, so a bought key and a fetched one cannot come to
--- differ in anything but the word this says -- which is the owner's ruling
--- ("Identical -- just a shortcut", 2026-08-30) held by construction rather than
--- by two code paths agreeing.
--- @param e table
--- @param via string
--- @param line string|nil  the owner's word for this door, from `copy`
local function grant(e, via, line)
    e.reviveKey.held = true
    e.reviveKey.via = via
    say(squadSrcs(e.squadId, e.matchId), line, 'success')
end

--- Walk over a key to collect it; run out the clock to lose the pickup.
---
--- ═══ ONE JOB PER RECORD PER TICK, AND COLLECTION IS TESTED FIRST ═══
---
--- A squadmate standing on the body on the tick the timer runs out has
--- collected it. That ordering is the forgiving one, it is the one a player
--- would expect, and it is the only one that does not turn a race into a
--- silent loss of the thing they walked across the map for.
BR.Sched.every(K and K.tickMs or 1000, 'revivekey.sweep', function()
    if not enabled() then return end

    local now = GetGameTimer()

    -- COLLECTORS FIRST, GATHERED ONCE. The alternative is a roster walk per key,
    -- which in a squad match with four bodies down is four walks a second for
    -- the same answer.
    --
    -- ALIVE AND NOTHING ELSE. Narrower than server/party.lua's visible states
    -- and narrower on purpose:
    --
    --   OUT is excluded because THE SUBJECT'S OWN CORPSE IS AT THE KEY. An OUT
    --   player's `pos` is the body they are spectating from, which is the exact
    --   position this file wrote the key down at -- so admitting OUT would have
    --   every key collect ITSELF on the first tick after it was minted, and the
    --   feature would look like it worked.
    --
    --   DBNO is excluded because a downed player crawls at 0.55 m/s and is
    --   bleeding out; if they are on top of a body it is because they were shot
    --   there, not because they went to fetch anything.
    --
    --   BUS, FREEFALL and GLIDE are excluded because nobody is eliminated before
    --   the doors open, so a body under a flight path is not a thing that
    --   happens -- and if step 5 ever drops a resurrected player back in, they
    --   must not hoover up keys on the way down.
    local movers = {}
    BR.Roster.each(
        function(e) return e.state == BR.PlayerState.ALIVE and e.squadId and e.pos end,
        function(src, e)
            movers[#movers + 1] = { src = src, e = e }
        end)

    BR.Roster.each(
        function(e) return e.reviveKey ~= nil and e.reviveKey.held ~= true end,
        function(src, e)
            local rec = e.reviveKey

            -- ═══ THERE HAS TO BE SOMETHING THERE TO WALK OVER ═══
            --
            -- `pickupLive` and not a bare distance test, and this is the whole
            -- of what the expiry BUYS. Without it the three minutes are
            -- decorative: the record stays unheld for ever (deliberately, so it
            -- can still be bought), so a squadmate wandering past the body at
            -- minute ten would collect a pickup that stopped existing at minute
            -- three -- and the free option the owner put a clock on would never
            -- actually close.
            --
            -- THE BOUNDARY IS EXCLUSIVE AND THE TWO TESTS ARE COMPLEMENTS:
            -- `pickupLive` is `now < expiresAt`, the expiry below is
            -- `now >= expiresAt`. So no tick can both collect and expire the
            -- same key, and there is no ordering between them that could lose
            -- one -- which is the property worth having, rather than a
            -- tie-break rule that would have to be remembered.
            if pickupLive(rec, now) then
                for _, mv in ipairs(movers) do
                    if mv.e.squadId == e.squadId and mv.e.matchId == e.matchId
                       and mv.src ~= src
                       and BR.Dist(mv.e.pos.x, mv.e.pos.y, rec.x, rec.y)
                           <= (tonumber(K.collectM) or 2.5) then
                        grant(e, 'fetched', copy().collected)
                        stat.collected = stat.collected + 1
                        print(('[br_core] revivekey: %d collected the key for %s (%d)')
                            :format(mv.src, tostring(e.name), src))
                        return
                    end
                end
            end

            -- THE PICKUP GOES, THE KEY STAYS. `reviveKey` is not cleared here
            -- and clearing it would delete the purchase path -- "They can still
            -- purchase the revive keys" is the second half of the sentence that
            -- set this deadline.
            if now >= (rec.expiresAt or 0) and not rec.lapsed then
                rec.lapsed = true
                stat.expired = stat.expired + 1
                -- THE SQUAD IS TOLD THE FREE OPTION CLOSED, and the owner's
                -- word for it is "Revive key lost" -- which is about the thing
                -- on the ground and not about the entitlement. `lapsed` is what
                -- makes this fire exactly once per key; the sweep keeps walking
                -- this record for the rest of the match, because it is still
                -- buyable.
                say(squadSrcs(e.squadId, e.matchId), copy().expired, 'warn')
                print(('[br_core] revivekey: the pickup for %s (%d) expired -- '
                    .. 'still buyable')
                    :format(tostring(e.name), src))
            end
        end)
end)

-- ---------------------------------------------------------------------------
-- Buying
-- ---------------------------------------------------------------------------

--- May this player buy their squad's keys at this vehicle, right now?
---
--- EVERY CLAIM IN "I was standing at an ambulance and I bought a key" IS
--- RE-DERIVED HERE. server/ambheal.lua's header states the shape and this is the
--- same one minus the rear arc: the model, the distance, being in a live match,
--- having a squad, and there being anything to buy are all read off this
--- server's own samples and its own clock. Nothing the client sent is trusted
--- except WHICH vehicle it means, which is a net id that is then interrogated.
---
--- @param src integer
--- @param entry table|nil
--- @param netId any
--- @return boolean
--- @return string|nil why   for /brkey and the console, never for a player
--- @return integer|nil veh
function BR.ReviveKey.canBuy(src, entry, netId)
    if not enabled() then return false, 'disabled' end
    if not entry then return false, 'no entry' end
    if not can.entityFromNet then return false, 'no net id resolver on this build' end

    netId = tonumber(netId)
    if not netId then return false, 'no net id' end

    -- ═══ THE BUYER MUST BE IN THE MATCH, AND `OUT` IS THE INTERESTING HALF ═══
    --
    -- An eliminated player buying their own way back would be a second life
    -- bought with no squadmate involved, which is not the feature -- "any
    -- squadmate can (instead of going to the revive key to pick it up) purchase"
    -- (#219 s6). They also have no body at an ambulance to be standing beside;
    -- their corpse is wherever they fell.
    --
    -- DBNO IS EXCLUDED TOO, and that leaves #219 Q17 open rather than answering
    -- it -- see the report. A downed player crawling at 0.55 m/s is not standing
    -- at an ambulance in any sense, so the geometry refuses them anyway; this
    -- makes the refusal say why instead of blaming the distance.
    if entry.state ~= BR.PlayerState.ALIVE then
        return false, 'only a player who is up and in the match may buy'
    end

    local m = entry.matchId and BR.Server.matches[entry.matchId]
    if not m or m.state ~= BR.MatchState.PLAYING then
        return false, 'not in a playing match'
    end

    if not entry.squadId then return false, 'no squad' end
    if buying[entry.squadId] then return false, 'a purchase is already in flight' end

    -- ═══ IS THERE ANYTHING TO BUY ═══
    --
    -- Refused rather than charged-for-nothing. 25 Volts is not refundable
    -- (config/shop.lua: "Purchases cannot be refunded") and a squad with every
    -- key already held would be paying for a no-op.
    local n = BR.ReviveKey.outstanding(entry.squadId, entry.matchId)
    if n <= 0 then return false, 'that squad has no outstanding keys' end

    -- ═══ THE VEHICLE, RESOLVED AND INTERROGATED RATHER THAN TRUSTED ═══
    local okVeh, veh = pcall(NetworkGetEntityFromNetworkId, netId)
    if not okVeh or not veh or veh == 0 then
        return false, 'that net id resolves to nothing'
    end

    local okEx, exists = pcall(DoesEntityExist, veh)
    if not okEx or not isTrue(exists) then return false, 'that vehicle does not exist' end

    -- IS IT AN AMBULANCE. Asked of server/rescue.lua so all three features mean
    -- the same thing by the word -- see BR.Rescue.isAmbulance. Nil-guarded
    -- because this file must keep loading if the rescue half is ever pulled, and
    -- the honest answer during that window is "nothing is an ambulance", which
    -- makes buying inert rather than wrong.
    local okModel, model = pcall(GetEntityModel, veh)
    if not okModel then return false, 'could not read the model' end
    if not (BR.Rescue and BR.Rescue.isAmbulance and BR.Rescue.isAmbulance(model)) then
        return false, 'that is not an ambulance'
    end

    -- ═══ ARE THEY ACTUALLY AT IT ═══
    --
    -- Both positions are the SERVER's: `entry.pos` is its own four-times-a-second
    -- sample of the player's ped, and the vehicle's is read on this line.
    -- Neither is anything the client sent.
    local okPos, c = pcall(GetEntityCoords, veh)
    if not okPos or c == nil then return false, 'could not read where it is' end

    local p = entry.pos
    if p == nil then return false, 'no position sample for that player yet' end

    local reach = (tonumber(K.reachM) or 6.0) + (tonumber(K.reachSlackM) or 2.0)
    local d = BR.Dist(c.x, c.y, p.x, p.y)
    if d > reach then
        return false, ('not at an ambulance (%.1fm)'):format(d)
    end

    return true, nil, veh
end

--- Buy every outstanding key this squad has, for one price.
---
--- ═══ THE GOODS MUST NOT EXIST BEFORE THE DEBIT DOES ═══
---
--- BR.Market.charge is a DynamoDB round trip and answers through a callback for
--- exactly this reason; server/shop.lua's note spells it out. So the keys are
--- granted INSIDE `done`, and the squad is marked as buying for the whole of the
--- flight so a second press cannot buy the same set twice.
---
--- ═══ AND THE SET IS RE-READ AFTER THE ANSWER, NOT CAPTURED BEFORE IT ═══
---
--- A DynamoDB round trip is long enough for a fifth squadmate to be eliminated
--- in. Granting against a list captured before the charge would leave that
--- player's key unheld while the squad had just paid the price that covers
--- "all revive keys for the squad" -- so the walk happens after the money has
--- landed, and the purchase covers everything outstanding at the moment it
--- completes. That is the reading most generous to the payer, and the owner's
--- sentence is the generous one.
---
--- @param src integer
--- @param netId any
--- @param done fun(ok:boolean, why:string|nil, n:integer|nil)|nil
function BR.ReviveKey.buy(src, netId, done)
    done = done or function() end

    local entry = BR.Roster.get(src)
    local ok, why = BR.ReviveKey.canBuy(src, entry, netId)
    if not ok then
        stat.refused = stat.refused + 1
        -- LOGGED AND NOT SENT. Nothing in this feature tells a player anything
        -- -- there is no wording for it (#219 Q20 is unanswered) and
        -- server/rescue.lua holds the same line. The one exception is the
        -- market's OWN shortfall sentence, which BR.Market.charge speaks below
        -- and which already exists for this exact fact.
        print(('[br_core] revivekey: refused %d -- %s'):format(src, tostring(why)))
        done(false, why)
        return
    end

    local squadId, matchId = entry.squadId, entry.matchId
    local price = math.floor(tonumber(K.price) or 25)

    if not (BR.Market and BR.Market.charge) then
        print('^3[br_core] revivekey: no market on this build -- nothing charged^7')
        done(false, 'no market')
        return
    end

    buying[squadId] = true
    BR.Market.charge(src, price, 'revivekey', function(paid, why2, left)
        buying[squadId] = nil

        if not paid then
            stat.refused = stat.refused + 1
            print(('[br_core] revivekey: %d was not charged -- %s')
                :format(src, tostring(why2)))
            done(false, why2)
            return
        end

        local n = 0
        for _, k in ipairs(BR.ReviveKey.forSquad(squadId, matchId)) do
            if k.rec.held ~= true then
                -- THE WORD IS SAID ONCE PER PURCHASE, NOT ONCE PER KEY. "one
                -- purchase buys all revive keys for the squad" is one event to
                -- the player, so `grant` is handed the line only for the first
                -- of them and the rest are silent -- otherwise a squad with
                -- three mates down would get three identical toasts for one
                -- press.
                grant(k.entry, 'bought', n == 0 and copy().bought or nil)
                n = n + 1
            end
        end
        stat.bought = stat.bought + 1

        print(('[br_core] revivekey: %d bought %d key(s) for squad %s at %d '
            .. 'Volts -- %s left')
            :format(src, n, tostring(squadId), price, tostring(left)))
        done(true, nil, n)
    end)
end

--- C->S. "I am at an ambulance and I want my squad's keys."
---
--- ═══ THIS HANDLER HAS NO CLIENT SENDER YET, AND THAT IS REPORTED ═══
---
--- The press needs an on-screen affordance, an affordance needs a word, and the
--- owner has not given one (#219 Q20). Rather than invent copy, the whole
--- player-facing half is left out and this handler is driven by `/brkey buy`
--- below -- the same way /brrescue drives BR.Rescue.begin. When he gives the
--- wording, the client half is a prompt and one TriggerServerEvent into here;
--- nothing on this side changes.
RegisterNetEvent(BR.Net.REVIVEKEY_BUY)
AddEventHandler(BR.Net.REVIVEKEY_BUY, function(d)
    local src = source
    if type(d) ~= 'table' then return end
    BR.ReviveKey.buy(src, d.n)
end)

-- ---------------------------------------------------------------------------
-- Spending one: the hold, and the way back
-- ---------------------------------------------------------------------------
--
-- ═══ THE CLAIM LIVES ON THE KEY RECORD, NOT ON `entry.reviverSrc` ═══
--
-- The obvious home is the field server/combat.lua already uses for a DBNO
-- revive, and it is the wrong one -- not for tidiness, for two LIVE WALKERS.
-- REVIVE_STOP's handler and BR.Combat.forget both do `e.reviverSrc == src ->
-- stopRevive`, and stopRevive ends in BR.Combat.pushDbno(src): a
-- DBNO_SET { downed = false } sent to a player who is OUT and spectating. Two
-- files would be arbitrating one field for two different features.
--
-- ON THE RECORD IT ALSO INHERITS EVERY TEARDOWN THE KEY ALREADY HAS, which is
-- the argument the whole feature was built on: BR.Match.resetPlayer clears
-- `e.reviveKey` in one line and BR.Roster.remove takes it with the entry on a
-- disconnect, so a claim cannot outlive the match, the round or the player.
--
-- ═══ ON SUCCESS THE KEY IS NILLED, NOT UN-HELD ═══
--
-- `forSquad` filters on `reviveKey ~= nil`, so nil is "spent". Setting
-- `held = false` instead would put the key back on the market and let a squad
-- buy the same person back twice.

--- How far the SERVER lets a hold be from the key. See config/revivekey.lua.
--- @return number
local function reviveReach()
    return (tonumber(K and K.reviveReachM) or 3.0)
         + (tonumber(K and K.reviveSlackM) or 1.0)
end

--- @return integer
local function holdMs()
    return math.floor(tonumber(K and K.reviveHoldMs) or 6000)
end

--- Everything that has to be true for a key revive to still be running.
---
--- RE-CHECKED EVERY TICK rather than only when the hold starts, which is
--- server/combat.lua's shape and what makes the cancellation rules free: walking
--- away, being knocked yourself, the key being spent by somebody else and the
--- match ending are all just this returning false.
---
--- MEASURED IN TWO DIMENSIONS, DELIBERATELY, and not in three. This is the same
--- circle `collectM` is measured with one screen above -- the key is a flat spot
--- on the ground and the reviver is standing on that ground -- and the vertical
--- difference between a standing player and a body lying at their feet is noise
--- a 3D form would charge them for. server/combat.lua's DBNO revive uses Dist3
--- because both of ITS positions are peds.
---
--- @param reviverSrc integer
--- @param src integer          the player the key belongs to
--- @param e table              their roster entry
--- @return boolean allowed, string|nil why not
local function reviveAllowed(reviverSrc, src, e)
    if not enabled() then return false, 'disabled' end
    if not e then return false, 'no such player' end

    local rec = e.reviveKey
    if not rec then return false, 'no key for that player' end
    -- ═══ THE SQUAD HAS TO OWN IT ═══
    --
    -- A key lying unclaimed on the ground is not a revive. It is fetched by
    -- walking to it (the sweep, above) or bought at an ambulance, and only then
    -- is there anything to spend.
    if rec.held ~= true then return false, 'that key is not held yet' end

    if e.state ~= BR.PlayerState.OUT then
        return false, 'the target is ' .. tostring(e.state) .. ', not out'
    end

    local r = BR.Roster.get(reviverSrc)
    if not r then return false, 'no such reviver' end
    if r.state ~= BR.PlayerState.ALIVE then
        return false, 'the reviver is ' .. tostring(r.state)
    end
    if not r.squadId or r.squadId ~= e.squadId then return false, 'different squads' end
    if not r.matchId or r.matchId ~= e.matchId then return false, 'different matches' end

    -- ═══ AND THE MATCH HAS TO BE LIVE ═══
    --
    -- THE SAME GATE combat.dbno USES, AND IT IS NOT DECORATIVE. That file
    -- carries a full write-up of the shipped bug where a clock belonging to a
    -- finished match eliminated the winner and stamped a death over VICTORY
    -- ROYALE. A hold that completed after the last enemy squad fell would stand
    -- somebody up in a match whose results were already published.
    --
    -- IT IS ALSO THE WHOLE OF THE LATE-GAME ANSWER (#219 Q18). The elimination
    -- that mints the last key of the second-to-last squad is the elimination
    -- that ends the match, ~250ms later -- so "revive the last enemy squad back
    -- into a match that was already won" is unreachable without a player-count
    -- rule the owner has not given.
    local m = e.matchId and BR.Server.matches[e.matchId]
    if not m or m.state ~= BR.MatchState.PLAYING then
        return false, 'not in a playing match'
    end

    local p = r.pos
    if not p then return false, 'no position sampled for the reviver' end

    local reach = reviveReach()
    local d = BR.Dist(p.x, p.y, rec.x, rec.y)
    if d > reach then
        return false, ('%.2fm from the key, server reach is %.2fm'):format(d, reach)
    end
    return true
end

--- Tell one client its hold is over. Harmless when the hold was never theirs.
--- @param reviverSrc integer
--- @param src integer
--- @param reason string|nil
local function cancelTo(reviverSrc, src, reason)
    TriggerClientEvent(BR.Net.REVIVEKEY_PROGRESS, reviverSrc,
        { pct = 0.0, target = src, cancelled = true, reason = reason })
end

--- Drop whatever hold is running on this key. Safe on a record with none.
--- @param src integer
--- @param e table
--- @param reason string|nil
local function stopHold(src, e, reason)
    local rec = e.reviveKey
    if not rec or not rec.byS then return end

    local byS = rec.byS
    -- KEPT FOR /brkey, the way server/combat.lua keeps `reviveLastPct`: a string
    -- of stops at the same percentage is the signature of a client re-arming
    -- rather than of a player who cannot hold a key, and it is the number that
    -- was missing the last three times this had to be guessed at.
    rec.lastPct  = math.min(1.0, (GetGameTimer() - (rec.from or 0)) / holdMs()) * 100.0
    rec.stopWhy  = reason
    rec.stopAt   = GetGameTimer()
    rec.byS, rec.from, rec.beat = nil, nil, nil
    stat.stops = stat.stops + 1

    cancelTo(byS, src, reason)
end

--- Put a player who is OUT back in the match, where they fell.
---
--- ═══ SHAPED ON BR.Combat.reviveHeld, NOT ON BR.Combat.revive ═══
---
--- `revive` refuses a non-DBNO entry on its first line, and the undo it performs
--- (dbnoUntil, downedBy, reviverSrc) was already done inside eliminate(). The
--- function that matches THIS transition is `reviveHeld` -- the only other
--- OUT->ALIVE path in the codebase -- and it does the four things `revive` does
--- not and this genuinely needs: it clears `placement` and `diedAt`, it clears
--- `engineHp` (or the 1Hz server-observed death check reads a stale corpse
--- sample and eliminates them again a second into their new life), it stamps
--- `healthSettleUntil` so the health audit does not log the crossover, and it
--- sends REVIVED BEFORE the state flip.
---
--- IT IS NOT REUSED, ONLY COPIED IN SHAPE. `reviveHeld` hardcodes 100 health and
--- speaks "The match has started. You are back in.", both of which are wrong
--- here.
---
--- ═══ AND THE STORM LEDGER IS CLEARED, WHICH IS A REAL BUG AND NOT HYGIENE ═══
---
--- server/storm.lua seeds its `display` from `e.stormHp` and only ever clamps it
--- DOWN. Nothing clears that field on death -- only BR.Match.resetPlayer and
--- stepping back inside the circle do. So a player the storm killed, revived at
--- their corpse and therefore still outside the wall, would carry a `stormHp` at
--- or below zero and be eliminated again on the very next storm tick REGARDLESS
--- of the health they were just handed. `lastStormAt` goes with it so the first
--- tick after the revive measures from now rather than from before they died.
---
--- Being outside the wall is still a bad place to be picked up, and that is the
--- rule -- storm.lua says so in as many words. This only makes the damage start
--- from the health they were given.
---
--- @param src integer
--- @param e table
--- @param reviverSrc integer|nil  credited; nil for the console path
local function bringBack(src, e, reviverSrc)
    local M = BR.Config.Match or {}
    local hp = tonumber(M.dbnoReviveHp) or 30

    -- THE KEY IS SPENT. Nilled and not un-held: `forSquad` filters on the record
    -- existing, so nil is the only representation of "gone" that cannot be
    -- bought a second time.
    e.reviveKey = nil

    e.revivePending = nil
    e.placement, e.diedAt = nil, nil
    e.engineHp = nil
    e.stormHp, e.lastStormAt = nil, nil
    -- THE CAMERA'S MEMORY OF WHO KILLED THEM. Written by eliminate() for the
    -- spectate default and deliberately a licence rather than an id, so it
    -- outlives the moment on purpose. Cleared here because they are not
    -- spectating anybody any more, and because a LATER death with no killer --
    -- the storm, a fall -- would otherwise inherit this one and point their
    -- camera at somebody who did not kill them.
    e.killedByLicense = nil
    -- Nothing above wrote these, and they are cleared anyway for the reason
    -- reviveHeld gives: this is not undoing our own work, it is refusing to
    -- trust that no other path reached this entry while the body was lying there.
    e.dbnoUntil, e.downedBy = nil, nil
    e.reviverSrc, e.reviveFrom = nil, nil
    e.reviveBeat, e.reviveTickAt = nil, nil

    -- THE PED FIRST, THE LEDGER SECOND, for the reason protocol.lua's REVIVED
    -- note gives: a client left holding a corpse while the server calls it ALIVE
    -- is exactly the state the server-observed death check exists to eliminate.
    TriggerClientEvent(BR.Net.REVIVED, src)

    e.healthSettleUntil = GetGameTimer()
        + (((BR.Config.Combat or {}).healthAudit or {}).settleMs or 2000)

    BR.Roster.update(src, { hp = hp + 0.0, armour = 0.0 })
    BR.Roster.setState(src, BR.PlayerState.ALIVE)
    TriggerClientEvent(BR.Net.HEALTH_SYNC, src, { hp = hp, armour = 0 })

    -- SPECTATING ENDS BY ITSELF AND NEEDS NO TEARDOWN CALL HERE.
    -- server/spectate.lua's `mayWatch` refuses anyone BR.Server.isInMatch, and
    -- its resolve pass stops the session with 'in-the-fight' on the next feed --
    -- 250ms. Its own comment names this as the line #144's revive already runs
    -- into.

    local r = reviverSrc and BR.Roster.get(reviverSrc) or nil
    if r then
        r.revives = (r.revives or 0) + 1
        TriggerClientEvent(BR.Net.REVIVEKEY_PROGRESS, reviverSrc,
            { pct = 100.0, target = src, done = true })
    end

    stat.revived = stat.revived + 1
    print(('[br_core] revivekey: %s (%d) is back in on %d hp%s')
        :format(tostring(e.name), src, hp,
                r and (' -- brought back by ' .. tostring(r.name)) or ''))
end

--- Complete a revive by hand, from the console. The same path, not a shortcut.
---
--- `/brkey revive` runs THIS, which is `bringBack` with the identical ruling in
--- front of it -- server/rescue.lua's rule for /brrescue and the same one: an
--- admin verb that took a different route would be testing itself.
--- @param src integer
--- @param reviverSrc integer|nil
--- @return boolean ok, string|nil why
function BR.ReviveKey.revive(src, reviverSrc)
    local e = BR.Roster.get(src)
    if not e then return false, 'no roster entry' end
    -- The reviver defaults to the holder of the running hold, so the console
    -- verb finishes the hold a player is actually performing rather than
    -- stealing the credit for it.
    reviverSrc = reviverSrc or (e.reviveKey and e.reviveKey.byS) or nil

    if reviverSrc then
        local ok, why = reviveAllowed(reviverSrc, src, e)
        if not ok then return false, why end
    else
        -- NO REVIVER NAMED AND NONE HOLDING. The geometry has nobody to measure,
        -- so the rest of the ruling is applied without it -- a key that is held,
        -- a player who is OUT, a match that is playing.
        local rec = e.reviveKey
        if not rec then return false, 'no key for that player' end
        if rec.held ~= true then return false, 'that key is not held yet' end
        if e.state ~= BR.PlayerState.OUT then
            return false, 'the target is ' .. tostring(e.state) .. ', not out'
        end
        local m = e.matchId and BR.Server.matches[e.matchId]
        if not m or m.state ~= BR.MatchState.PLAYING then
            return false, 'not in a playing match'
        end
    end

    bringBack(src, e, reviverSrc)
    return true
end

--- One key's share of the 250ms job.
---
--- 250ms MATCHES THE CLIENT'S RE-ASSERTION AND THE ROSTER'S POSITION SAMPLER,
--- which is what makes the reach re-check mean something: stepping faster would
--- re-measure the same coordinates.
BR.Sched.every(250, 'revivekey.hold', function()
    if not enabled() then return end

    local now  = GetGameTimer()
    local ms   = holdMs()
    local beat = tonumber(K and K.reviveBeatMs) or 1000

    BR.Roster.each(
        function(e) return e.reviveKey ~= nil and e.reviveKey.byS ~= nil end,
        function(src, e)
            local rec = e.reviveKey
            local byS = rec.byS

            local ok, why = reviveAllowed(byS, src, e)
            if not ok then
                stopHold(src, e, why or 'notallowed')
                return
            end

            -- ═══ SILENCE IS A RELEASE ═══
            --
            -- The client re-asserts every 250ms and this is what expires a hold
            -- whose holder went quiet -- a crash, a dropped STOP, a player who
            -- alt-tabbed with the key down. Without it a lost STOP would leave a
            -- hold running to completion with nobody's finger on anything, which
            -- is the bug client/dbno.lua shipped as "a brief tap completed a
            -- whole revive".
            if now - (rec.beat or 0) > beat then
                stopHold(src, e, 'went quiet')
                return
            end

            local pct = (now - (rec.from or now)) / ms
            if pct >= 1.0 then
                bringBack(src, e, byS)
                return
            end

            TriggerClientEvent(BR.Net.REVIVEKEY_PROGRESS, byS,
                { pct = pct * 100.0, target = src })
        end)
end)

--- C->S. "I am on that key and I am holding the button."
---
--- RE-ASSERTED, NOT ANNOUNCED ONCE -- see protocol.lua. The heartbeat branch is
--- first because it is the common case: at 250ms over a six-second hold it runs
--- twenty-three times for every one time the arm branch does.
RegisterNetEvent(BR.Net.REVIVEKEY_START)
AddEventHandler(BR.Net.REVIVEKEY_START, function(d)
    local src = source
    local targetSrc = math.tointeger(tonumber(type(d) == 'table' and d.target))
    -- The one refusal that stays silent: with no target there is no ring on the
    -- far side to take down. server/combat.lua's REVIVE_START says the same.
    if not targetSrc then return end

    local e = BR.Roster.get(targetSrc)
    local ok, why = reviveAllowed(src, targetSrc, e)
    if not ok then
        stat.refused = stat.refused + 1
        cancelTo(src, targetSrc, why or 'notallowed')
        return
    end

    local rec = e.reviveKey

    -- ALREADY OURS: this is the heartbeat, not a new hold. It must NOT restart
    -- the progress, or a player leaning on the key would reset their own clock
    -- four times a second and the ring would never finish.
    if rec.byS == src then
        rec.beat = GetGameTimer()
        return
    end

    -- FIRST HAND ON WINS, AND THE SECOND PRESSER IS REFUSED. server/combat.lua's
    -- rule verbatim: "Two mates holding the same body is not twice as fast and
    -- it must not restart the clock for whoever pressed second." It is also the
    -- only rule the existing hold protocol can enforce without inventing a
    -- second notion of progress -- and #219 Q11 (helper scaling) is a number the
    -- owner has not given.
    if rec.byS then
        stat.refused = stat.refused + 1
        cancelTo(src, targetSrc,
            ('taken: %d already has this key'):format(rec.byS))
        return
    end

    rec.byS  = src
    rec.from = GetGameTimer()
    rec.beat = rec.from
    stat.holds = stat.holds + 1
end)

--- C->S. "The key came up."
---
--- NO PAYLOAD AND A ROSTER WALK, which is REVIVE_STOP's shape: the server holds
--- at most one claim per reviver, so it can find it, and a client that names the
--- wrong target cannot cancel somebody else's hold.
RegisterNetEvent(BR.Net.REVIVEKEY_STOP)
AddEventHandler(BR.Net.REVIVEKEY_STOP, function()
    local src = source
    BR.Roster.each(
        function(e) return e.reviveKey ~= nil and e.reviveKey.byS == src end,
        function(tsrc, e) stopHold(tsrc, e, 'released') end)
end)

-- ---------------------------------------------------------------------------
-- Admin
-- ---------------------------------------------------------------------------

--- What does this player's squad hold, and why can they not buy?
---
--- THE REFUSAL REASONS EXIST FOR THIS COMMAND AND NOWHERE ELSE, which is
--- server/rescue.lua's rule for /brrescue and the same one: a refusal toast
--- would be player-facing copy nobody asked for.
RegisterCommand('brkey', function(src, args)
    local verb   = args and args[1]
    local target = tonumber(args and args[2])
        or (tonumber(src) ~= 0 and tonumber(src) or nil)

    if not target then
        print('usage: brkey <status|buy|revive> <serverId> [netId]')
        return
    end

    local entry = BR.Roster.get(target)
    if not entry then
        print(('[br_core] revivekey: %d has no roster entry'):format(target))
        return
    end

    local keys = BR.ReviveKey.forSquad(entry.squadId, entry.matchId)
    local now  = GetGameTimer()

    print(('[br_core] revivekey %d: squad=%s  keys=%d  outstanding=%d  '
        .. 'hold=%dms reach=%.1fm hp=%d')
        :format(target, tostring(entry.squadId), #keys,
                BR.ReviveKey.outstanding(entry.squadId, entry.matchId),
                holdMs(), reviveReach(),
                tonumber((BR.Config.Match or {}).dbnoReviveHp) or 30))

    for _, k in ipairs(keys) do
        print(('    %s (%d)  held=%s%s  pickup=%s  at (%.1f, %.1f)')
            :format(tostring(k.entry.name), k.src, tostring(k.rec.held == true),
                    k.rec.via and (' via ' .. k.rec.via) or '',
                    pickupLive(k.rec, now)
                        and ('%.0fs left'):format((k.rec.expiresAt - now) / 1000)
                        or 'gone',
                    k.rec.x, k.rec.y))

        -- ═══ THE HOLD, WHICH IS THE HALF A PLAYTEST CANNOT SEE ═══
        --
        -- Everything above is visible in game. This is not: whether a hold is
        -- registered at all, how far through it is, and -- when it is NOT
        -- running -- why the last one stopped and how far it had got. A string
        -- of stops at the same percentage is a client re-arming, which is what
        -- "the ring fills and nothing happens" actually is; a single stop at 40%
        -- with a distance in the reason is a player who walked off. Those two
        -- look identical on screen and cost four playtest rounds last time.
        if k.rec.byS then
            print(('        held by %d for %.0f%% (last beat %dms ago)')
                :format(k.rec.byS,
                        math.min(1.0, (now - (k.rec.from or now)) / holdMs()) * 100.0,
                        now - (k.rec.beat or now)))
        elseif k.rec.stopAt then
            print(('        no hold -- last stopped %.0fs ago at %.0f%% (%s)')
                :format((now - k.rec.stopAt) / 1000, k.rec.lastPct or 0.0,
                        tostring(k.rec.stopWhy)))
        else
            print('        no hold, and none has been attempted')
        end

        -- WHY A HOLD WOULD BE REFUSED RIGHT NOW, asked of the real ruling. Only
        -- meaningful with somebody to measure, which is `target` -- so this line
        -- answers "could the player I named revive this mate from where they are
        -- standing", which is the question a two-client test round asks.
        local okRev, whyRev = reviveAllowed(target, k.src, k.entry)
        print(('        %d may revive them: %s%s'):format(target, tostring(okRev),
            okRev and '' or (' (' .. tostring(whyRev) .. ')')))
    end

    if verb == 'buy' then
        local netId = tonumber(args and args[3])
        local okBuy, whyBuy = BR.ReviveKey.canBuy(target, entry, netId)
        print(('    canBuy=%s%s'):format(tostring(okBuy),
            okBuy and '' or (' (' .. tostring(whyBuy) .. ')')))
        if okBuy then BR.ReviveKey.buy(target, netId) end

    elseif verb == 'revive' then
        -- `brkey revive <serverId>` FINISHES THE NAMED PLAYER'S OWN REVIVE --
        -- the id is the person coming BACK, matching `status` and `buy`, which
        -- both take the subject rather than the actor.
        local okRev, whyRev = BR.ReviveKey.revive(target, tonumber(args and args[3]))
        print(('    revive=%s%s'):format(tostring(okRev),
            okRev and '' or (' (' .. tostring(whyRev) .. ')')))
    end

    print(('    minted=%d collected=%d expired=%d bought=%d refused=%d '
        .. 'holds=%d stops=%d revived=%d')
        :format(stat.minted, stat.collected, stat.expired, stat.bought,
                stat.refused, stat.holds, stat.stops, stat.revived))
end, true)
