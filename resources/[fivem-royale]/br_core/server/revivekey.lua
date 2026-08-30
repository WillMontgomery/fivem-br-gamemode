-- The revive key: minted at elimination, collected off the ground, bought at an
-- ambulance. #219 step 4, and step 4 only.
--
-- ═══════════════════════════════════════════════════════════════════════════
-- WHAT THIS FILE DOES NOT DO, SAID FIRST SO NOBODY LOOKS FOR IT
-- ═══════════════════════════════════════════════════════════════════════════
--
-- IT RESURRECTS NOBODY. There is no hold, no ambulance ride, no parachute and no
-- landing. That is #219 step 5, and it is gated on four questions the owner has
-- not answered (Q10 storm, Q11 helper scaling, Q18 late game, Q21 what they come
-- back with). A key that is held is a key that is READY, and nothing consumes it
-- yet. `held` is the field step 5 will clear.
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

BR = BR or {}
BR.ReviveKey = {}

local K = BR.Config.ReviveKey

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

local stat = { minted = 0, collected = 0, expired = 0, bought = 0, refused = 0 }

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

--- Mark a key held, however it was come by.
--- @param e table
--- @param via string
local function grant(e, via)
    e.reviveKey.held = true
    e.reviveKey.via = via
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
                        grant(e, 'fetched')
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
                grant(k.entry, 'bought')
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
        print('usage: brkey <status|buy> <serverId> [netId]')
        return
    end

    local entry = BR.Roster.get(target)
    if not entry then
        print(('[br_core] revivekey: %d has no roster entry'):format(target))
        return
    end

    local keys = BR.ReviveKey.forSquad(entry.squadId, entry.matchId)
    local now  = GetGameTimer()

    print(('[br_core] revivekey %d: squad=%s  keys=%d  outstanding=%d')
        :format(target, tostring(entry.squadId), #keys,
                BR.ReviveKey.outstanding(entry.squadId, entry.matchId)))

    for _, k in ipairs(keys) do
        print(('    %s (%d)  held=%s%s  pickup=%s  at (%.1f, %.1f)')
            :format(tostring(k.entry.name), k.src, tostring(k.rec.held == true),
                    k.rec.via and (' via ' .. k.rec.via) or '',
                    pickupLive(k.rec, now)
                        and ('%.0fs left'):format((k.rec.expiresAt - now) / 1000)
                        or 'gone',
                    k.rec.x, k.rec.y))
    end

    if verb == 'buy' then
        local netId = tonumber(args and args[3])
        local okBuy, whyBuy = BR.ReviveKey.canBuy(target, entry, netId)
        print(('    canBuy=%s%s'):format(tostring(okBuy),
            okBuy and '' or (' (' .. tostring(whyBuy) .. ')')))
        if okBuy then BR.ReviveKey.buy(target, netId) end
    end

    print(('    minted=%d collected=%d expired=%d bought=%d refused=%d')
        :format(stat.minted, stat.collected, stat.expired, stat.bought,
                stat.refused))
end, true)
