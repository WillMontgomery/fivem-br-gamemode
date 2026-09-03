-- The revive key: minted at elimination, taken off the ground with a press,
-- bought at an ambulance, and spent by a squadmate holding a key AT an
-- ambulance. #219 steps 4 and 5.
--
-- ═══════════════════════════════════════════════════════════════════════════
-- WHERE THE REVIVE HAPPENS: AT AN AMBULANCE, AND NOWHERE ELSE
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Owner, 2026-08-30, after the round that shipped the other answer:
--
--   "I should be able to walk up to an ambulance and see a DUI to press
--    something to revive them. Then once that is complete, their screen should
--    fade to black, set focus to the area where the ambulance I just used is,
--    process the revive, give them a parachute, put them 150m above the
--    ambulance, then fade in. And now they're back in the match."
--
--   "the press e to revive DUI when standing at the ped should not show once
--    they've bled out. The only option at that point is the ambulance."
--
-- THIS FILE USED TO ARGUE THE OPPOSITE AT LENGTH and the argument is deleted
-- rather than answered, because it was never ours to make. What is worth
-- keeping from it is the one technical finding it was built on: a hold must not
-- be measured to a CORPSE. #163's clone "CRAWLS AWAY" on the reviver's machine
-- while the real body is pinned on its own, and 33ca88c found that a corpse's
-- position is a death ragdoll -- "the one thing this file already knows do not
-- replicate reliably" (citizenfx/fivem#2436, open). That finding survives
-- intact here: the hold is measured to an AMBULANCE, which is a networked
-- vehicle the server can read directly, and to nothing that ever died.
--
-- SO THE HOLD IS RULED WITH `reachM`, THE PURCHASE'S OWN RADIUS. Same van, same
-- player, same question -- see config/revivekey.lua on why there is not a second
-- number for it. The two reach values that measured a hold at the key's point
-- (`reviveReachM`, `reviveSlackM`) are gone; nothing is measured to a key's
-- recorded coordinates any more except the PICKUP, which is still on the ground
-- where it fell.
--
-- ═══════════════════════════════════════════════════════════════════════════
-- AND THE ARRIVAL IS A DROP, IN THE ORDER HE GAVE IT
-- ═══════════════════════════════════════════════════════════════════════════
--
--   1. the subject's screen fades to black
--   2. the streaming focus moves to the ambulance that was used
--   3. the revive is processed
--   4. they are given a parachute
--   5. they are placed 150m above that ambulance
--   6. fade in
--
-- STEPS 1 AND 2 ARE A MESSAGE, AND 3-6 ARE THE ONE AFTER IT. This file owns
-- WHEN, because it owns the ledger; client/revivekey.lua owns the screen, the
-- ped and the chute. The hold completing sends BR.Net.REVIVEKEY_ARRIVE (go
-- black, focus there) and then waits `fadeMs + focusMs` before doing ANY of its
-- own work -- so the resurrection, the roster flip and the health all still
-- happen in the order they always did, one after another, with the player's
-- screen already black by the time the first of them runs.
--
-- WHY THE WAIT IS ON THIS SIDE RATHER THAN THE CLIENT'S. If the server flipped
-- the roster to ALIVE and the client deferred the resurrection behind its own
-- fade, there would be up to a second of a player the server calls ALIVE whose
-- ped is a corpse -- which is precisely the state the 1Hz server-observed death
-- check in server/combat.lua exists to eliminate, and it would eliminate them,
-- intermittently, for a revive that had just been paid for. Holding the whole
-- sequence here means that window never opens.
--
-- STEPS 3 AND 5 ARE ONE NATIVE, AND THAT IS NOT A STEP BEING DROPPED.
-- NetworkResurrectLocalPlayer takes the coordinates it stands you up at, so
-- "process the revive" and "put them 150m above the ambulance" cannot be two
-- calls without resurrecting somebody twice. See client/revivekey.lua's
-- REVIVEKEY_PLACE handler, which performs all four of the remaining steps in
-- his order.
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
-- HEALTH IS BR.Config.ReviveKey.reviveHp -- FULL, and it is the owner's own
-- sentence of 2026-08-31: "when a revive is processed using the key, the player
-- should come back with full health". It used to be the 30 an in-person pick-up
-- hands back; that number has not moved and still governs the in-person revive.
-- See config/revivekey.lua's `reviveHp` for the argument his sentence retired.
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
--   inventory AND leaves somebody in the match to be brought back to. Which
--   makes the owner's table true by construction rather than by two rules being
--   kept in step:
--
--     picked up in person during bleed-out -> never reaches eliminate() at all,
--       so no deathBox and no key. Their kit is still on them.
--     bleed-out expires -> eliminate() -> deathBox AND a key, together.
--     walked out -> eliminate('left') -> deathBox, and NO key. See below.
--
-- ═══ AND 'left' IS THE ONE PLACE THE TWO LINES PART COMPANY (2026-09-02) ═══
--
-- Owner, playtest: "in squads, a player leaves the match and the others get 'x
-- has bled out' toasts."
--
-- `BR.Match.leaveMatch` routes a walk-out through eliminate() on purpose --
-- "leaving while alive IS an elimination" -- so it arrived here too, minted a
-- key and spoke `copy.bledOut` at the squad. THE SECOND CLAUSE ABOVE IS WHAT IT
-- FAILED: a leaver is detached from the match microseconds later and there is
-- nobody left to revive. `BR.Match.resetPlayer` nils `reviveKey` in the same
-- tick, and `forSquad` and `reviveAllowed` both filter on the `matchId` that
-- call clears -- so the key could not be bought, found or spent, and the toast
-- sent the squad running for something that had already ceased to exist.
--
-- THE GUARD IS IN server/combat.lua AND NOT IN THIS FILE, because `cause` is
-- that function's own value and it already branches on `cause ~= 'left'` for the
-- #144 hold. This module's contract is unchanged: it is still handed only the
-- eliminations that are supposed to mint, and it still speaks for every one of
-- them.
--
-- THE DEATH BOX IS DELIBERATELY NOT GATED WITH IT. A leaver still spills their
-- kit -- walking out is not a way to take it home.
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
-- COLLECTION IS A PRESS. IT USED TO BE A PROXIMITY TEST, AND THAT WAS THE BUG
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Owner, 2026-08-30: "I somehow picked up the dead player's key by walking up
-- to them without seeing a DUI or pressing anything."
--
-- This file used to say "there is no REVIVEKEY_TAKE and there must not be one",
-- on the grounds that the server samples every position four times a second and
-- can therefore answer "did a squadmate walk over it" from two numbers no client
-- has touched. All of that is still TRUE and none of it was the question. A
-- thing that leaves the ground without a press is a thing the player cannot know
-- they have -- and a squad that cannot tell whether it holds a key cannot decide
-- whether to walk to an ambulance.
--
-- SO THERE IS A PRESS, AND THE SERVER STILL DECIDES EVERYTHING ELSE. The client
-- sends "I pressed, and I meant that mate" (BR.Net.REVIVEKEY_TAKE) and nothing
-- more; `canTake` re-derives the distance, the squad, the match, the state and
-- whether there is still a pickup there from this server's own samples. The
-- trust boundary that the old sweep avoided by never listening is the same
-- boundary `canBuy` has always stood on, and it is stood on the same way.
--
-- WHAT THE SWEEP STILL DOES: the expiry, and only the expiry. It is a deadline
-- check with nobody to ask.
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
-- SIX OF THE NINE REACH PLAYERS FROM HERE (bledOut, collect, collectedBy,
-- bought, expired, revived). The other three are world prompts and belong to
-- client/revivekey.lua.
--
-- AND A COMPLETED REVIVE SPEAKS NOW, WHICH IT DID NOT UNTIL 2026-08-31. This
-- file used to argue that it should not -- "the subject watches their own body
-- stand up, and the reviver's ring closes" -- and the owner has since written
-- the sentence himself: `copy.revived`. It still does not borrow BR.Combat's
-- "%s picked you up.", which is the other act.
--
-- FOUR OF THE SIX NAME A PLAYER, AND `say` PASSES THE NAMES SEPARATELY. The
-- line stays a string out of `copy` and the names travel as BR.Notice.who
-- markers, so the rule this file is built on -- every word comes from the
-- config table -- is unchanged, and the name is never inside the string. See
-- br_lib/shared/notice.lua for why that separation is what makes bold safe.

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
---
--- ═══ THE NAMES ARE ARGUMENTS, NOT PART OF THE LINE ═══
---
--- Owner, 2026-08-31: "Any time we mention a player by name in a toast their
--- name should be bold." Four of his lines have `%s` holes in them, and the
--- values for those holes arrive here as varargs rather than pre-formatted into
--- the string -- so `line` is still, character for character, a member of
--- BR.Config.ReviveKey.copy, and the name is still a value that no parser ever
--- looks at. BR.Notice.line does the splitting, on OUR string.
--- @param who integer|integer[]
--- @param line string|nil
--- @param tone string|nil
--- @param ... any  values for the line's `%s` holes; names wrapped in
---                 BR.Notice.who so the page draws them bold
local function say(who, line, tone, ...)
    if type(line) ~= 'string' or line == '' then return end
    if not (BR.Server and BR.Server.notify) then return end
    BR.Server.notify(who, BR.Notice.line(line, ...), tone or 'info', { ms = 4000 })
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

--- The same squad, minus one person.
---
--- TWO OF THE OWNER'S 2026-08-31 LINES ARE ADDRESSED TO "the rest of the squad"
--- and one is addressed to a single player, so the audience is now part of what
--- each sentence means rather than a constant. He wrote a different sentence for
--- the collector than for everybody else; sending both to everybody would say
--- "You've collected..." to four people, only one of whom did.
---
--- BUILT ON squadSrcs RATHER THAN BESIDE IT, so "who is in this squad" stays one
--- walk with one predicate and this is only the filter.
--- @param squadId any
--- @param matchId any
--- @param exceptSrc integer|nil
--- @return integer[]
local function squadSrcsExcept(squadId, matchId, exceptSrc)
    local out = {}
    for _, src in ipairs(squadSrcs(squadId, matchId)) do
        if src ~= exceptSrc then out[#out + 1] = src end
    end
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
--- AND NOT FOR EVERY ELIMINATION THAT REACHES IT: that call site refuses
--- `cause == 'left'`, because a player who walked out is detached from the match
--- in the same tick and has nobody to be revived to. The refusal lives there and
--- not here -- see the header -- so this function has no opinion about WHY
--- somebody stopped being in the match, only that they did.
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

    -- ═══ THE SQUAD IS TOLD THERE IS SOMETHING TO GO AND GET ═══
    --
    -- Owner, 2026-08-31: "When a squadmate bleeds out, to the rest of the squad:
    -- '[player] has bled out! Get their revive key or purchase it at an
    -- ambulance!'"
    --
    -- HERE AND NOT IN combat.lua's eliminate(), because the sentence is about
    -- the KEY -- it names both doors this file owns -- and because this is the
    -- one place that knows a key was actually minted. A squad whose mate died in
    -- a mode with no keys, or before this feature was enabled, must not be told
    -- to go and fetch one; every early return above is a reason this line would
    -- have been a lie.
    --
    -- THE REST OF THE SQUAD, WHICH IS HIS AUDIENCE AND NOT squadSrcs'. The
    -- subject is excluded: "you have bled out" is not news to the person
    -- watching their own body, and combat.lua's tellSquad excludes them from the
    -- cue for the same reason one screen above this call.
    --
    -- ═══ AND HOW LONG THEY HAVE, WHICH IS THE SECOND HOLE ═══
    --
    -- Owner, 2026-09-02: "Perhaps the 'grab their key!' toast should also
    -- mention that the key expires and after how long."
    --
    -- THE NUMBER COMES OFF `expiryMs` AND IS NOT WRITTEN IN THE SENTENCE. The
    -- console line four lines below already derives its seconds from the same
    -- key, and a "3 minutes" typed into config/revivekey.lua's copy table would
    -- be the third copy of one number and the one nobody would think to change.
    -- BR.Clock.words turns it into the unit a player reads.
    --
    -- IT TRAVELS AS A VALUE, NOT AS A FORMATTED STRING, which is this file's one
    -- rule: `line` stays character for character a member of
    -- BR.Config.ReviveKey.copy and BR.Notice.line does the splitting. A duration
    -- is not a BR.Notice.who, so it lands as prose and draws unbolded beside the
    -- name that does not.
    say(squadSrcsExcept(e.squadId, e.matchId, src), copy().bledOut, 'warn',
        BR.Notice.who(e.name), BR.Clock.words(tonumber(K.expiryMs) or 180000))

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
--- differ in anything but what is SAID about it -- which is the owner's ruling
--- ("Identical -- just a shortcut", 2026-08-30) held by construction rather than
--- by two code paths agreeing.
---
--- AND THE SPEAKING LEFT IT ON 2026-08-31. It used to take the line and address
--- the whole squad, which was right while both doors said one sentence to one
--- audience. The owner then wrote TWO sentences for the fetch -- one to the
--- collector, one to everybody else -- and left the purchase saying its single
--- line, so the doors now differ in audience as well as in wording and a shared
--- speaker would have to be told both. The STATE CHANGE is still one function,
--- which is the half that had to be identical.
--- @param e table
--- @param via string
local function grant(e, via)
    e.reviveKey.held = true
    e.reviveKey.via = via
end

--- Run out the clock to lose the pickup. That is the whole of this job now.
---
--- ═══ COLLECTION LEFT THIS SWEEP AND BECAME A PRESS ═══
---
--- The tick used to gather every ALIVE squadded player and test each of them
--- against each loose key, so that walking within `collectM` of a body silently
--- took the key off it. The owner asked for a prompt and a press instead (see
--- the header), so that half lives in `BR.ReviveKey.take` and this is a deadline
--- check with nobody to ask.
---
--- WHAT WENT WITH IT: the collector walk, and with it the rule that an OUT
--- player must not be a collector. That rule was the single most load-bearing
--- line in this file -- an eliminated player's `pos` IS the key's position, so a
--- sweep that admitted them collected every key for free on the tick after it
--- was minted. It is not gone, it has MOVED: `canTake` refuses a presser who is
--- not ALIVE and refuses a presser who is the subject, and tools/test_revivekey
--- .lua asserts both against the press rather than against the sweep.
BR.Sched.every(K and K.tickMs or 1000, 'revivekey.sweep', function()
    if not enabled() then return end

    local now = GetGameTimer()

    BR.Roster.each(
        function(e) return e.reviveKey ~= nil and e.reviveKey.held ~= true end,
        function(src, e)
            local rec = e.reviveKey

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
-- Taking one off the ground
-- ---------------------------------------------------------------------------

--- May this player take that mate's key off the ground, right now?
---
--- EVERY CLAUSE OF "I WAS STANDING ON IT AND I PRESSED" IS RE-DERIVED HERE, the
--- way `canBuy` re-derives every clause of "I was at an ambulance". The client
--- carries the INTENT -- which mate -- and nothing else, because the intent is
--- the only part of it the server cannot see.
---
--- THE TWO REFUSALS THAT MATTER MOST ARE THE FIRST TWO, and they are the rule
--- the old sweep enforced with its collector filter:
---
---   THE SUBJECT MAY NOT TAKE THEIR OWN KEY. An eliminated player's `pos` IS the
---   position this file wrote the key down at -- they are spectating from the
---   body it was minted on -- so the distance is zero, for ever. Without this
---   line a dead player pressing interact would hold their own key, every squad
---   would own every key for free, and it would look like the feature working.
---
---   AND THE PRESSER HAS TO BE ALIVE. A DBNO mate crawls at 0.55 m/s and is
---   bleeding out; if they are on top of a body it is because they were shot
---   there, not because they went to fetch anything.
---
--- @param src integer
--- @param entry table|nil
--- @param targetSrc any
--- @return boolean
--- @return string|nil why   for /brkey and the console, never for a player
--- @return table|nil target the roster entry of the mate whose key it is
function BR.ReviveKey.canTake(src, entry, targetSrc)
    if not enabled() then return false, 'disabled' end
    if not entry then return false, 'no entry' end

    targetSrc = math.tointeger(tonumber(targetSrc))
    if not targetSrc then return false, 'no target' end
    if targetSrc == src then
        return false, 'a player cannot take their own key -- their body is on it'
    end

    if entry.state ~= BR.PlayerState.ALIVE then
        return false, 'only a player who is up and in the match may take a key'
    end

    local m = entry.matchId and BR.Server.matches[entry.matchId]
    if not m or m.state ~= BR.MatchState.PLAYING then
        return false, 'not in a playing match'
    end
    if not entry.squadId then return false, 'no squad' end

    local e = BR.Roster.get(targetSrc)
    if not e then return false, 'no such player' end
    if e.squadId ~= entry.squadId then return false, 'different squads' end
    if e.matchId ~= entry.matchId then return false, 'different matches' end

    local rec = e.reviveKey
    if not rec then return false, 'no key for that player' end
    if rec.held == true then return false, 'that key is already held' end

    -- ═══ THERE HAS TO BE SOMETHING THERE TO PICK UP ═══
    --
    -- `pickupLive` and not a bare distance test, and this is the whole of what
    -- the expiry BUYS. The record stays unheld for ever on purpose so it can
    -- still be bought, so without this a squadmate pressing over the body at
    -- minute ten would take a pickup that stopped existing at minute three --
    -- and the free option the owner put a clock on would never actually close.
    if not pickupLive(rec, GetGameTimer()) then
        return false, 'that pickup has expired -- it is buyable, not takeable'
    end

    local p = entry.pos
    if p == nil then return false, 'no position sample for that player yet' end

    local reach = (tonumber(K.collectM) or 2.5) + (tonumber(K.collectSlackM) or 1.0)
    local d = BR.Dist(p.x, p.y, rec.x, rec.y)
    if d > reach then
        return false, ('%.2fm from the key, server reach is %.2fm'):format(d, reach)
    end

    return true, nil, e
end

--- Take it.
--- @param src integer
--- @param targetSrc any
--- @return boolean ok, string|nil why
function BR.ReviveKey.take(src, targetSrc)
    local entry = BR.Roster.get(src)
    local ok, why, e = BR.ReviveKey.canTake(src, entry, targetSrc)
    if not ok then
        stat.refused = stat.refused + 1
        -- LOGGED AND NOT SENT, which is this whole feature's rule: a press the
        -- server declines says nothing at all. The refusal reasons exist for
        -- /brkey and the console log.
        print(('[br_core] revivekey: %d may not take %s\'s key -- %s')
            :format(src, tostring(targetSrc), tostring(why)))
        return false, why
    end

    grant(e, 'fetched')

    -- ═══ TWO SENTENCES, TWO AUDIENCES, BOTH HIS (2026-08-31) ═══
    --
    -- "On collecting a key, to the collector" and "When someone collects a key,
    -- to the rest of the squad" are his own headings for these two lines, and
    -- they replace the single `Revive key collected` that used to go to
    -- everybody. `entry` is the presser and `e` is the mate whose key it is;
    -- `collectedBy` names them in that order because he said so -- "first name
    -- is the collector, second is the owner of the key".
    --
    -- THE REST OF THE SQUAD INCLUDES THE ONE WHO IS OUT. They are watching their
    -- own body and a mate has just picked up the thing that brings them back,
    -- which makes them the person on that list who most wants the sentence.
    say(src, copy().collect, 'success', BR.Notice.who(e.name))
    say(squadSrcsExcept(e.squadId, e.matchId, src), copy().collectedBy,
        'success', BR.Notice.who(entry.name), BR.Notice.who(e.name))

    stat.collected = stat.collected + 1
    print(('[br_core] revivekey: %d took the key for %s (%s)')
        :format(src, tostring(e.name), tostring(targetSrc)))
    return true
end

--- C->S. "I am standing on that mate's key and I am taking it."
RegisterNetEvent(BR.Net.REVIVEKEY_TAKE)
AddEventHandler(BR.Net.REVIVEKEY_TAKE, function(d)
    local src = source
    if type(d) ~= 'table' then return end
    BR.ReviveKey.take(src, d.target)
end)

-- ---------------------------------------------------------------------------
-- Buying
-- ---------------------------------------------------------------------------

--- Resolve a net id to an ambulance this player is actually standing at.
---
--- ═══ ONE RESOLVER FOR THE PURCHASE AND FOR THE REVIVE ═══
---
--- Both gestures happen at the same van and both are sent as a net id, so "is
--- that an ambulance and am I at it" is asked twice per press by two features
--- that must never come to disagree. server/ambheal.lua's header states the
--- shape and this is the same one minus the rear arc: the model, the distance
--- and the vehicle's existence are all read off this server's own samples.
--- Nothing the client sent is trusted except WHICH vehicle it means.
---
--- IT ASKS BR.Rescue.isAmbulance, which is the one answer server/rescue.lua,
--- server/ambheal.lua and this file all use, so all three mean the same thing by
--- the word. Nil-guarded because this file must keep loading if the rescue half
--- is ever pulled, and the honest answer during that window is "nothing is an
--- ambulance", which makes both gestures inert rather than wrong.
---
--- @param entry table|nil   the acting player's roster entry
--- @param netId any
--- @return integer|nil veh
--- @return string|nil why
--- @return table|nil at   { x, y, z } -- where the van is, for the arrival
local function ambulanceFor(entry, netId)
    if not can.entityFromNet then return nil, 'no net id resolver on this build' end

    netId = tonumber(netId)
    if not netId then return nil, 'no net id' end

    local okVeh, veh = pcall(NetworkGetEntityFromNetworkId, netId)
    if not okVeh or not veh or veh == 0 then
        return nil, 'that net id resolves to nothing'
    end

    local okEx, exists = pcall(DoesEntityExist, veh)
    if not okEx or not isTrue(exists) then return nil, 'that vehicle does not exist' end

    local okModel, model = pcall(GetEntityModel, veh)
    if not okModel then return nil, 'could not read the model' end
    if not (BR.Rescue and BR.Rescue.isAmbulance and BR.Rescue.isAmbulance(model)) then
        return nil, 'that is not an ambulance'
    end

    -- ═══ ARE THEY ACTUALLY AT IT ═══
    --
    -- Both positions are the SERVER's: `entry.pos` is its own four-times-a-second
    -- sample of the player's ped, and the vehicle's is read on this line.
    -- Neither is anything the client sent.
    local okPos, c = pcall(GetEntityCoords, veh)
    if not okPos or c == nil then return nil, 'could not read where it is' end

    local p = entry and entry.pos
    if p == nil then return nil, 'no position sample for that player yet' end

    local reach = (tonumber(K.reachM) or 6.0) + (tonumber(K.reachSlackM) or 2.0)
    local d = BR.Dist(c.x, c.y, p.x, p.y)
    if d > reach then
        return nil, ('not at an ambulance (%.1fm)'):format(d)
    end

    return veh, nil, { x = c.x, y = c.y, z = c.z }
end

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
    if tonumber(netId) == nil then return false, 'no net id' end

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
    --
    -- Through the ONE resolver the revive hold also uses -- see `ambulanceFor`.
    local veh, whyVeh = ambulanceFor(entry, netId)
    if not veh then return false, whyVeh end

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

        -- THE WORD IS SAID ONCE PER PURCHASE, NOT ONCE PER KEY. "one purchase
        -- buys all revive keys for the squad" is one event to the player, so it
        -- is said here rather than inside the loop -- otherwise a squad with
        -- three mates down would get three identical toasts for one press.
        --
        -- IT MOVED OUT OF `grant` WITH EVERY OTHER SENTENCE (see grant), and the
        -- guard moved with it unchanged: `n == 0` inside the loop and `n > 0`
        -- after it are the same condition, which is that at least one key was
        -- actually granted.
        if n > 0 then
            say(squadSrcs(squadId, matchId), copy().bought, 'success')
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
--- ITS SENDER IS client/revivekey.lua's buy plate, and `/brkey buy` drives the
--- identical path -- the same rule server/rescue.lua states for /brrescue: an
--- admin verb that took a different route would be testing itself.
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

--- How far the SERVER lets a hold be from the ambulance. See the header: this
--- is `reachM` -- the PURCHASE's radius -- because it is the same van.
--- @return number
local function reviveReach()
    return (tonumber(K and K.reachM) or 6.0)
         + (tonumber(K and K.reachSlackM) or 2.0)
end

--- @return integer
local function holdMs()
    return math.floor(tonumber(K and K.reviveHoldMs) or 6000)
end

--- How long the subject's screen is black before this file touches anything.
---
--- fadeMs + focusMs: the fade, and then the streaming focus sitting on the
--- ambulance while the world comes in under it. See the header for why the whole
--- of that wait is on THIS side.
--- @return integer
local function arriveMs()
    return math.floor(tonumber(K and K.fadeMs) or 400)
         + math.floor(tonumber(K and K.focusMs) or 1000)
end

--- Everything that has to be true for a key revive to still be running.
---
--- RE-CHECKED EVERY TICK rather than only when the hold starts, which is
--- server/combat.lua's shape and what makes the cancellation rules free: walking
--- away from the van, being knocked yourself, the ambulance being blown up, the
--- key being spent by somebody else and the match ending are all just this
--- returning false.
---
--- MEASURED IN TWO DIMENSIONS, DELIBERATELY, and not in three. A van is four
--- metres long and you walk up to it; the vertical difference between a standing
--- player and a vehicle's origin is noise a 3D form would charge them for, and
--- `canBuy` has always measured the same circle at the same vehicle.
---
--- @param reviverSrc integer
--- @param src integer          the player the key belongs to
--- @param e table              their roster entry
--- @param netId any            the ambulance the reviver says they are at
--- @return boolean allowed, string|nil why not, table|nil at  { x, y, z }
local function reviveAllowed(reviverSrc, src, e, netId)
    if not enabled() then return false, 'disabled' end
    if not e then return false, 'no such player' end

    local rec = e.reviveKey
    if not rec then return false, 'no key for that player' end
    -- ═══ THE SQUAD HAS TO OWN IT ═══
    --
    -- A key lying unclaimed on the ground is not a revive. It is taken with a
    -- press at the body (`canTake`) or bought at an ambulance, and only then is
    -- there anything to spend.
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

    -- ═══ AND THEY HAVE TO BE AT AN AMBULANCE ═══
    --
    -- THE WHOLE OF WHAT THE OWNER'S 2026-08-30 MESSAGE CHANGED, and it is one
    -- call: the same resolver the purchase uses, on the same net id the client
    -- names, measured with the same radius. `at` is what comes back with it --
    -- the van's own coordinates, which the arrival is placed 150m above -- so
    -- the vehicle that ruled the hold and the vehicle they fall onto are the
    -- same vehicle by construction rather than by two lookups agreeing.
    local veh, whyVeh, at = ambulanceFor(r, netId)
    if not veh then return false, whyVeh end

    return true, nil, at
end

--- Tell one client its hold is over. Harmless when the hold was never theirs.
--- @param reviverSrc integer
--- @param src integer
--- @param reason string|nil
local function cancelTo(reviverSrc, src, reason)
    TriggerClientEvent(BR.Net.REVIVEKEY_PROGRESS, reviverSrc,
        { pct = 0.0, target = src, cancelled = true, reason = reason })
end

--- Withdraw the promise made to the subject when the hold completed.
---
--- The black screen and the streaming focus are the client's, taken on our
--- word, and this is the word being taken back. Rare by construction -- see
--- `stillPossible` for the two things that can go wrong in the second and a half
--- between the promise and the arrival -- but a subject left staring at a black
--- screen because a match ended underneath them would have no way out at all,
--- and client/revivekey.lua's own deadline is the second net rather than the
--- first.
--- @param src integer
local function unpromise(src)
    TriggerClientEvent(BR.Net.REVIVEKEY_ARRIVE, src, { cancelled = true })
end

--- Drop whatever hold is running on this key. Safe on a record with none.
---
--- ═══ IT REFUSES TO TOUCH A COMMITTED REVIVE ═══
---
--- Once the six seconds are up the revive is PAID FOR, and the second and a half
--- the arrival spends fading is not a window in which the reviver can change
--- their mind. Without this line, letting go of the key during the fade -- or the
--- 250ms silence of a dropped heartbeat -- would take a completed revive back
--- and leave the subject to time out on a black screen. `arriveAt` is what says
--- the hold is over; see the stepper.
--- @param src integer
--- @param e table
--- @param reason string|nil
local function stopHold(src, e, reason)
    local rec = e.reviveKey
    if not rec or not rec.byS then return end
    if rec.arriveAt then return end

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

--- Is a promised arrival still deliverable?
---
--- THE ONLY THINGS RE-CHECKED IN THE SECOND AND A HALF THE BLACK SCREEN LASTS,
--- and the list is short on purpose. Once the hold has completed, the revive is
--- paid for: the reviver's distance, their heartbeat, and whether the ambulance
--- is still in one piece have all stopped mattering -- they mattered while the
--- ring was filling. What is left is the two facts that would make standing this
--- player up nonsense rather than unfair.
--- @param e table
--- @return boolean, string|nil
local function stillPossible(e)
    if e.state ~= BR.PlayerState.OUT then
        return false, 'the target is ' .. tostring(e.state) .. ', not out'
    end
    local m = e.matchId and BR.Server.matches[e.matchId]
    if not m or m.state ~= BR.MatchState.PLAYING then
        return false, 'not in a playing match'
    end
    return true
end

--- Put a player who is OUT back in the match, 150m above the ambulance used.
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
--- sends the resurrection BEFORE the state flip.
---
--- IT IS NOT REUSED, ONLY COPIED IN SHAPE. `reviveHeld` hardcodes 100 health and
--- speaks "The match has started. You are back in.", both of which are wrong
--- here -- and it resurrects a player where they fell, which is now wrong twice.
---
--- ═══ AND THE PED EVENT IS REVIVEKEY_PLACE, NOT REVIVED ═══
---
--- REVIVED stands a body up at `GetEntityCoords(ped)` -- exactly where it is
--- lying, no placement at all -- which is what #144's held death needs and the
--- opposite of what the owner asked for here. This path names the AMBULANCE and
--- the client does the whole of his sequence off it. `at` is the vehicle's own
--- coordinates as the ruling read them, so the van that allowed the hold and the
--- van they fall onto cannot be two different vans.
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
--- @param at table                { x, y, z } of the ambulance they arrive over
local function bringBack(src, e, reviverSrc, at)
    -- FULL HEALTH, WHICH IS THE OWNER'S SENTENCE OF 2026-08-31: "when a revive
    -- is processed using the key, the player should come back with full health".
    -- It was BR.Config.Match.dbnoReviveHp -- the 30 an in-person pick-up hands
    -- back, which still does. See config/revivekey.lua's `reviveHp` for the
    -- argument this replaced.
    local hp = tonumber(K and K.reviveHp) or 100

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
    --
    -- AND THE SCREEN IS ALREADY BLACK BY HERE. This whole function runs
    -- `arriveMs()` after the promise went out, so the client resurrects the
    -- instant this lands rather than deferring behind its own fade -- which is
    -- what keeps the window above from opening at all. See the header.
    TriggerClientEvent(BR.Net.REVIVEKEY_PLACE, src,
        { x = at.x, y = at.y, z = at.z })

    e.healthSettleUntil = GetGameTimer()
        + (((BR.Config.Combat or {}).healthAudit or {}).settleMs or 2000)

    BR.Roster.update(src, { hp = hp + 0.0, armour = 0.0 })
    BR.Roster.setState(src, BR.PlayerState.ALIVE)
    TriggerClientEvent(BR.Net.HEALTH_SYNC, src, { hp = hp, armour = 0 })

    -- SPECTATING IS ALREADY OVER BY HERE. It was ended a whole fade ago, at the
    -- moment the promise went out, so that the camera cut happened while there
    -- was nothing on screen -- see the stepper. server/spectate.lua's resolve
    -- pass would also have caught it within 250ms of the state flip below; that
    -- is now the net rather than the plan.

    local r = reviverSrc and BR.Roster.get(reviverSrc) or nil
    if r then
        r.revives = (r.revives or 0) + 1
        TriggerClientEvent(BR.Net.REVIVEKEY_PROGRESS, reviverSrc,
            { pct = 100.0, target = src, done = true })

        -- ═══ AND THE SQUAD IS TOLD, WHICH IS NEW ON 2026-08-31 ═══
        --
        -- Owner: "When a revive completes, to the squad: '[player] revived
        -- [player] - they are back in!' (first is the reviver, second is the
        -- revived)". The order is his and it is the whole of why `r` comes
        -- before `e` here.
        --
        -- THE WHOLE SQUAD, BOTH PARTIES INCLUDED. He said "to the squad" with no
        -- exclusion, and unlike the collection there is no second sentence for
        -- anybody to be reading instead.
        --
        -- ONLY WITH A REVIVER, AND THAT IS A GAP RATHER THAN A RULE. His line
        -- names two people, and `/brkey revive <id>` with no hold running and no
        -- reviver named has only one. The feature's standing answer to a case he
        -- has not worded is silence (see the header), so the console path with
        -- nobody to credit says nothing -- rather than this file inventing a
        -- one-name version of his sentence.
        say(squadSrcs(e.squadId, e.matchId), copy().revived, 'success',
            BR.Notice.who(r.name), BR.Notice.who(e.name))
    end

    stat.revived = stat.revived + 1
    print(('[br_core] revivekey: %s (%d) is back in on %d hp, %.0fm over '
        .. '(%.1f, %.1f)%s')
        :format(tostring(e.name), src, hp,
                tonumber(K and K.dropM) or 150.0, at.x, at.y,
                r and (' -- brought back by ' .. tostring(r.name)) or ''))
end

--- Complete a revive by hand, from the console. The same path, not a shortcut.
---
--- `/brkey revive` runs THIS, which is `bringBack` with the identical ruling in
--- front of it -- server/rescue.lua's rule for /brrescue and the same one: an
--- admin verb that took a different route would be testing itself.
---
--- ═══ IT NEEDS AN AMBULANCE NOW, BECAUSE THE ARRIVAL IS SOMEWHERE ═══
---
--- The verb used to be able to stand somebody up with no reviver at all, because
--- a key revive placed nobody anywhere -- there was nothing left to name. There
--- is now: they arrive 150m over a specific van, so the console has to say WHICH,
--- and there are exactly two honest ways to know.
---
---   A HOLD THAT IS ALREADY RUNNING knows. `rec.spot` is the ambulance the last
---   ruling measured, refreshed every 250ms by the stepper, so `/brkey revive
---   <id>` finishes the revive a player is actually performing -- which is what
---   the verb is for in a two-client test.
---
---   OR THE CALLER NAMES BOTH. `/brkey revive <id> <reviverSrc> <netId>` runs
---   the full ruling against that pair, exactly as a press would.
---
--- AND NOTHING ELSE. With no hold and no named van there is no arrival point,
--- and inventing one -- their corpse, the map centre -- would be this verb
--- testing a path the game does not have.
--- @param src integer
--- @param reviverSrc integer|nil
--- @param netId any
--- @return boolean ok, string|nil why
function BR.ReviveKey.revive(src, reviverSrc, netId)
    local e = BR.Roster.get(src)
    if not e then return false, 'no roster entry' end
    local rec = e.reviveKey

    -- The reviver defaults to the holder of the running hold, so the console
    -- verb finishes the hold a player is actually performing rather than
    -- stealing the credit for it.
    reviverSrc = reviverSrc or (rec and rec.byS) or nil

    local at = nil
    if netId ~= nil then
        if not reviverSrc then return false, 'name a reviver with the net id' end
        local okRule, why
        okRule, why, at = reviveAllowed(reviverSrc, src, e, netId)
        if not okRule then return false, why end
    else
        -- NO VAN NAMED, SO THE RUNNING HOLD'S ONE IS THE ONLY ANSWER. The rest
        -- of the ruling is still applied -- a key that is held, a player who is
        -- OUT, a match that is playing -- so this is a shortcut through the
        -- GEOMETRY and through nothing else.
        if not rec then return false, 'no key for that player' end
        if rec.held ~= true then return false, 'that key is not held yet' end
        local okPossible, whyPossible = stillPossible(e)
        if not okPossible then return false, whyPossible end
        at = rec.spot
        if not at then
            return false, 'no ambulance -- nobody is holding at one, so name '
                .. 'a reviver and a net id'
        end
    end

    bringBack(src, e, reviverSrc, at)
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

            -- ═══ COMMITTED: THE HOLD IS OVER AND THE SCREEN IS GOING BLACK ═══
            --
            -- Everything below this branch is about a hold that is still being
            -- performed, and none of it applies once the six seconds are up. A
            -- reviver who lets go, walks away or drops a heartbeat during the
            -- fade has already paid; re-ruling them here would take a completed
            -- revive back and strand the subject on a black screen.
            if rec.arriveAt then
                if now < rec.arriveAt then return end

                local okStill, whyStill = stillPossible(e)
                if not okStill then
                    -- THE PROMISE IS WITHDRAWN, not silently dropped. The
                    -- subject's client is holding a black screen and the
                    -- streaming focus on our word.
                    unpromise(src)
                    rec.arriveAt = nil
                    stopHold(src, e, whyStill or 'notallowed')
                    print(('[br_core] revivekey: the arrival for %s (%d) fell '
                        .. 'through -- %s'):format(tostring(e.name), src,
                                                   tostring(whyStill)))
                    return
                end

                bringBack(src, e, byS, rec.spot)
                return
            end

            local ok, why, at = reviveAllowed(byS, src, e, rec.veh)
            if not ok then
                stopHold(src, e, why or 'notallowed')
                return
            end
            -- WHERE THE VAN IS, REFRESHED EVERY TICK. An ambulance is a vehicle
            -- and a vehicle can be pushed; the arrival is placed over wherever
            -- it was when the hold finished, not over where it was when the hold
            -- started.
            rec.spot = at

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
                -- ═══ STEP 1 AND STEP 2, AND THEN A WAIT ═══
                --
                -- "their screen should fade to black, set focus to the area
                -- where the ambulance I just used is" -- and only THEN is the
                -- revive processed. So the hold completing sends the promise and
                -- does nothing else; `arriveAt` is when the branch at the top of
                -- this callback picks it up, one whole fade later.
                rec.arriveAt = now + arriveMs()
                TriggerClientEvent(BR.Net.REVIVEKEY_ARRIVE, src,
                    { x = at.x, y = at.y, z = at.z })

                -- ═══ AND THE SPECTATE CAMERA COMES DOWN UNDER THE BLACK ═══
                --
                -- It would come down on its own -- server/spectate.lua's
                -- resolve pass stops anyone BR.Server.isInMatch with
                -- 'in-the-fight' -- but that runs at 250ms and it runs off the
                -- STATE, which does not flip until the far end of the fade. So
                -- left alone, the camera would still be sitting behind a
                -- squadmate's shoulder for a quarter of a second AFTER the
                -- screen has begun coming back, and the player would watch
                -- somebody else for a beat before cutting to their own descent.
                -- Ending it here spends that quarter second inside the black.
                --
                -- BR.Spectate.stop IS THE ONE TEARDOWN and it is documented as
                -- safe for a player with no session, so this needs no test for
                -- whether they were watching anybody. Nil-guarded because this
                -- file must keep loading if the spectate half is ever pulled.
                if BR.Spectate and BR.Spectate.stop then
                    BR.Spectate.stop(src, 'in-the-fight')
                end
                print(('[br_core] revivekey: %s (%d) is coming back at '
                    .. '(%.1f, %.1f) in %dms')
                    :format(tostring(e.name), src, at.x, at.y, arriveMs()))
                return
            end

            TriggerClientEvent(BR.Net.REVIVEKEY_PROGRESS, byS,
                { pct = pct * 100.0, target = src })
        end)
end)

--- C->S. "I am at that ambulance and I am holding the button."
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
    local netId = type(d) == 'table' and d.n or nil
    local ok, why, at = reviveAllowed(src, targetSrc, e, netId)
    if not ok then
        stat.refused = stat.refused + 1
        cancelTo(src, targetSrc, why or 'notallowed')
        return
    end

    local rec = e.reviveKey

    -- ALREADY OURS: this is the heartbeat, not a new hold. It must NOT restart
    -- the progress, or a player leaning on the key would reset their own clock
    -- four times a second and the ring would never finish.
    --
    -- IT DOES REFRESH THE VAN, because a re-assertion is the client saying which
    -- ambulance it is still standing at -- and a player who walked from one to
    -- another mid-hold has been ruled against the new one on the line above.
    if rec.byS == src then
        rec.beat = GetGameTimer()
        rec.veh, rec.spot = netId, at
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
    -- THE VAN, RECORDED WITH THE CLAIM. The stepper re-rules against it every
    -- 250ms and the arrival is placed above it, so it is stored beside the hold
    -- rather than re-derived from a second lookup that could find a different
    -- ambulance parked half a metre closer.
    rec.veh, rec.spot = netId, at
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

--- What does this player's squad hold, where does the revive happen, and why
--- can they not do it?
---
--- THE REFUSAL REASONS EXIST FOR THIS COMMAND AND NOWHERE ELSE, which is
--- server/rescue.lua's rule for /brrescue and the same one: a refusal toast
--- would be player-facing copy nobody asked for.
---
--- ═══ THE NET ID IS THE THIRD ARGUMENT FOR ALL THREE VERBS ═══
---
--- The revive happens at an ambulance now, so "could this player revive that
--- mate" is not answerable without one -- exactly as "could they buy" never was.
--- One position for one argument across the three verbs, rather than the third
--- slot meaning a vehicle for `buy` and a person for `revive`.
---
--- WITH NO NET ID GIVEN, a key that has a HOLD running is ruled against the van
--- that hold is at, so a bare `/brkey <id>` during a two-client test still
--- answers the question the test is asking.
RegisterCommand('brkey', function(src, args)
    local verb   = args and args[1]
    local target = tonumber(args and args[2])
        or (tonumber(src) ~= 0 and tonumber(src) or nil)
    local netId  = tonumber(args and args[3])

    if not target then
        print('usage: brkey <status|buy|revive> <serverId> [netId] [reviverSrc]')
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
        .. 'hold=%dms reach=%.1fm (at an ambulance) take=%.1fm hp=%d '
        .. 'drop=%.0fm after %dms of black')
        :format(target, tostring(entry.squadId), #keys,
                BR.ReviveKey.outstanding(entry.squadId, entry.matchId),
                holdMs(), reviveReach(),
                (tonumber(K.collectM) or 2.5) + (tonumber(K.collectSlackM) or 1.0),
                tonumber(K.reviveHp) or 100,
                tonumber(K.dropM) or 150.0, arriveMs()))

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
        if k.rec.arriveAt then
            -- ═══ THE HALF SECOND NOBODY CAN SEE FROM A CHAIR ═══
            --
            -- Between the ring closing and the player falling out of the sky
            -- there is a black screen on somebody else's machine, and "the
            -- revive did nothing" and "the revive is mid-arrival" look
            -- identical from the reviver's side. This line is the difference.
            print(('        COMMITTED -- arriving in %dms over (%.1f, %.1f)')
                :format(math.max(0, k.rec.arriveAt - now),
                        (k.rec.spot or {}).x or 0.0, (k.rec.spot or {}).y or 0.0))
        elseif k.rec.byS then
            print(('        held by %d for %.0f%% at van %s (last beat %dms ago)')
                :format(k.rec.byS,
                        math.min(1.0, (now - (k.rec.from or now)) / holdMs()) * 100.0,
                        tostring(k.rec.veh),
                        now - (k.rec.beat or now)))
        elseif k.rec.stopAt then
            print(('        no hold -- last stopped %.0fs ago at %.0f%% (%s)')
                :format((now - k.rec.stopAt) / 1000, k.rec.lastPct or 0.0,
                        tostring(k.rec.stopWhy)))
        else
            print('        no hold, and none has been attempted')
        end

        -- WHY A PICKUP WOULD BE REFUSED RIGHT NOW. The press is new and its
        -- refusals are the ones a playtest cannot read: "I stood on the body and
        -- pressed and nothing happened" is a distance, an expiry or a state, and
        -- the three are indistinguishable on screen because none of them says
        -- anything.
        local okTake, whyTake = BR.ReviveKey.canTake(target, entry, k.src)
        print(('        %d may take their key: %s%s'):format(target,
            tostring(okTake), okTake and '' or (' (' .. tostring(whyTake) .. ')')))

        -- WHY A HOLD WOULD BE REFUSED RIGHT NOW, asked of the real ruling. Only
        -- meaningful with somebody to measure (`target`) AND a van to measure to
        -- -- so this line answers "could the player I named revive this mate at
        -- that ambulance", which is the question a two-client test round asks.
        local okRev, whyRev = reviveAllowed(target, k.src, k.entry,
                                            netId or k.rec.veh)
        print(('        %d may revive them at van %s: %s%s')
            :format(target, tostring(netId or k.rec.veh), tostring(okRev),
                    okRev and '' or (' (' .. tostring(whyRev) .. ')')))
    end

    if verb == 'buy' then
        local okBuy, whyBuy = BR.ReviveKey.canBuy(target, entry, netId)
        print(('    canBuy=%s%s'):format(tostring(okBuy),
            okBuy and '' or (' (' .. tostring(whyBuy) .. ')')))
        if okBuy then BR.ReviveKey.buy(target, netId) end

    elseif verb == 'revive' then
        -- `brkey revive <serverId>` FINISHES THE NAMED PLAYER'S OWN REVIVE --
        -- the id is the person coming BACK, matching `status` and `buy`, which
        -- both take the subject rather than the actor.
        --
        -- IT DRIVES THE WHOLE ARRIVAL, not a shortcut past it: the same
        -- bringBack, the same REVIVEKEY_PLACE at the same van. What it skips is
        -- only the fade, because there was no hold to promise one.
        local okRev, whyRev = BR.ReviveKey.revive(target,
                                                  tonumber(args and args[4]),
                                                  netId)
        print(('    revive=%s%s'):format(tostring(okRev),
            okRev and '' or (' (' .. tostring(whyRev) .. ')')))
    end

    print(('    minted=%d collected=%d expired=%d bought=%d refused=%d '
        .. 'holds=%d stops=%d revived=%d')
        :format(stat.minted, stat.collected, stat.expired, stat.bought,
                stat.refused, stat.holds, stat.stops, stat.revived))
end, true)
