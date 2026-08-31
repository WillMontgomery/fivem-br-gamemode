-- The revive key: what a squad gets when one of them stops being in the match.
--
-- ═══ THE OWNER'S TWO MESSAGES, IN FULL, BECAUSE EVERY CLAUSE IS A RULE ═══
--
--   "The key is picked up by the player, then owned by the squad. It's not an
--    inventory item. One player can pick up the key while another processes the
--    revive"                                            -- owner, 2026-08-30
--
--   "The pickup expires on a timer, let's say 3 minutes. They can still purchase
--    the revive keys at an ambulance for 25 volts (one purchase buys all revive
--    keys for the squad, multiple instances of this are allowed per match)"
--                                                       -- owner, 2026-08-30
--
--   "if their key was used to revive them, they lost their inventory. During the
--    bleed out, if they are revived in-person there, they can keep their
--    inventory, which is no different from today. The moment that bleed out
--    timer ends and they go to spectate - their key is created and their
--    inventory is spilled on the ground"                -- owner, 2026-08-30
--
-- ═══════════════════════════════════════════════════════════════════════════
-- IT IS NOT AN INVENTORY ITEM, AND THAT IS THE DESIGN RATHER THAN A DETAIL
-- ═══════════════════════════════════════════════════════════════════════════
--
-- A key is an ENTITLEMENT HELD BY A SQUAD, not an object anybody carries. The
-- consequences are all deletions, and they are worth naming because each one is
-- a question #219 asked at length and the owner's sentence removes:
--
--   * NO SLOT. It never competes with a weapon or a med kit for one of the five
--     (BR.Config.Loot.slots), so a squad is never choosing between a rescue and
--     an armour plate.
--   * NO CARRIER. There is nobody to kill for it (#219 Q4), nobody to
--     disconnect with it (Q6), and nothing to loot off a body.
--   * NO SECOND JOURNEY. "One player can pick up the key while another processes
--     the revive" is free once the squad owns it, rather than a hand-off that
--     would have to be built.
--
-- SO THE RECORD LIVES ON THE ELIMINATED PLAYER'S ROSTER ENTRY, keyed by the
-- person it brings back rather than by the person who fetched it. See
-- server/revivekey.lua for why that placement is what makes the squad rule fall
-- out for free instead of needing a squad-indexed table to maintain.
--
-- ═══════════════════════════════════════════════════════════════════════════
-- THE PICKUP EXPIRES. THE ENTITLEMENT DOES NOT
-- ═══════════════════════════════════════════════════════════════════════════
--
-- These are two different clocks and reading them as one would delete the
-- purchase path. "The pickup expires on a timer" and "They can STILL purchase
-- the revive keys" are the same message: after three minutes the thing on the
-- ground is gone, and the 25 Volts still buys the key it was.
--
-- So `expiryMs` retires the WORLD PICKUP and nothing else. A key that was never
-- collected stays purchasable for the rest of the match, which is also what
-- makes "unlimited -- if they can pay" (owner, 2026-08-30, #219 Q19) true.
--
-- ═══════════════════════════════════════════════════════════════════════════
-- THE STRINGS ARE HERE NOW, AND EVERY ONE OF THEM IS A PLACEHOLDER
-- ═══════════════════════════════════════════════════════════════════════════
--
-- This file used to say "NO STRINGS", and the reason it gave was that #219 Q20
-- was unanswered. It is answered: the owner listed six lines on 2026-08-30 and
-- then said to stop waiting on him and ship it.
--
-- SO ALL SIX LIVE IN ONE TABLE, `copy` BELOW, AND NOWHERE ELSE. That is the
-- whole point of the table: he can rewrite every word this feature speaks by
-- editing one screen of one file, without opening the server module, the client
-- module or the prompt page. No string in this feature may be written anywhere
-- but there -- not a default in a `or`, not a fallback in the client, not a
-- second copy in a comment that somebody later pastes.
--
-- AND THERE ARE EXACTLY SIX. If the design ever needs a seventh, the answer is
-- to ask him, not to write one. See the note over `copy`.
--
-- ═══════════════════════════════════════════════════════════════════════════
-- THE RESURRECTION NUMBERS ARE HERE NOW TOO. TWO OF THEM, AND NOT THE OTHERS
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Step 5 is built (server/revivekey.lua's hold, client/revivekey.lua's prompt),
-- so the numbers it actually spends are named here: `reviveHoldMs` and the two
-- reach values. What is STILL not here is everything the shape of the feature
-- deleted rather than deferred -- there is no drop height, no parachute and no
-- landing spot, because a key revive stands a player up where they fell and
-- performs no placement at all. See server/revivekey.lua's `bringBack`.
--
-- AND THERE IS NO `reviveHp`, DELIBERATELY. A key revive hands back
-- BR.Config.Match.dbnoReviveHp -- the same 30 a squadmate's pick-up hands back
-- -- because it is the same act: a mate standing over a body in the open for a
-- few seconds. The 100 in config/rescue.lua is the argued exception (an
-- ultra-rare item spent in full on a ride the player could not shoot back
-- during), not the rule. A number of its own here would be a second answer to a
-- question that already has one, free to drift.

BR = BR or {}
BR.Config = BR.Config or {}

BR.Config.ReviveKey = {
    enabled = true,

    -- ------------------------------------------------------------------
    -- THE DROPPED PICKUP
    -- ------------------------------------------------------------------

    -- "The pickup expires on a timer, let's say 3 minutes."
    --
    -- HIS NUMBER, AND HIS HEDGE. "let's say" is an invitation to tune it, which
    -- is why it is a named key rather than 180000 written into the sweep.
    --
    -- IT RETIRES THE PICKUP, NOT THE KEY. See the block above: after this the
    -- squad can no longer walk to the body, and can still buy what was lying
    -- there.
    expiryMs = 180000,

    -- How close a squadmate has to be to the body to have collected it.
    --
    -- ═══ WHY THERE IS NO PROMPT AND NO PRESS ═══
    --
    -- Collection is a PROXIMITY TEST THE SERVER RUNS ON ITS OWN SAMPLES, not a
    -- key press. Three reasons, in order of weight:
    --
    --   1. IT NEEDS NO WORDING. A prompt is a string the owner has not given
    --      (Q20), and inventing one is the thing he has asked us not to do.
    --   2. THERE IS NO CHOICE TO REFUSE. A prompt exists to let a player decline
    --      -- to leave a crate for a squadmate, to not spend a med kit. Nobody
    --      declines their own mate's revive key, and a prompt whose only answer
    --      is yes is a keypress tax.
    --   3. THE PROMPT BUDGET IS ALREADY SPENT. client/dbno.lua: "One browser for
    --      every world prompt in the game", and BR.Loot.suppress() exists
    --      because the crate prompt and the revive prompt already collide over
    --      it. A body has scattered loot around it by construction
    --      (BR.Loot.deathBox rings the corpse at deathScatterRadius), so a key
    --      prompt would be a fourth contender in the one place the third already
    --      fights.
    --
    -- 2.5m IS "STANDING ON THE BODY" and is deliberately tighter than the 4.6m
    -- ring their kit is scattered in, so running the loot does not sweep up the
    -- key from the far side of it without ever reaching them.
    collectM = 2.5,

    -- ------------------------------------------------------------------
    -- BUYING ONE
    -- ------------------------------------------------------------------

    -- "purchase the revive keys at an ambulance for 25 volts".
    --
    -- 25, NOT THE 150 IN #219's BODY. The issue was written on 2026-08-23 and
    -- the owner priced it on 2026-08-30; the later number is the decision.
    price = 25,

    -- "one purchase buys all revive keys for the squad".
    --
    -- NOT A KNOB, A STATEMENT -- and it is here so the reading is on the record
    -- rather than inferred from a loop. The owner asked for one reading to be
    -- confirmed and this is it: 25 Volts makes every currently-eliminated
    -- squadmate REVIVABLE. It does not resurrect anybody. Each one still needs
    -- its own hold at an ambulance, which is step 5 and does not exist yet.
    buysAll = true,

    -- How close to an ambulance "at an ambulance" is.
    --
    -- ═══ BESIDE IT, NOT BEHIND IT -- AND THAT IS A DIFFERENCE FROM ambheal ═══
    --
    -- config/ambheal.lua tests a REAR ARC as well as a distance, because the
    -- owner asked for the back of the ambulance specifically and because the
    -- heal puts a body on the stretcher through those doors. Buying a key is not
    -- that: he said "at an ambulance", the transaction is a number leaving a
    -- balance, and there is nothing about it that happens at the tailgate.
    --
    -- So this is a plain radius, and it is wider than ambheal's 3.5 for the
    -- reason the arc is absent -- a sphere with no arc at 3.5m would refuse
    -- somebody standing at the front wing, which nobody would be able to
    -- explain.
    reachM = 6.0,

    -- Slack added to `reachM` for the SERVER's own ruling only.
    --
    -- server/ambheal.lua's argument, and it applies unchanged: the server's
    -- position sample is up to one sampler interval old and the vehicle may have
    -- rolled, so a ruling run at exactly `reachM` refuses presses that were
    -- legitimate when they were made. The slack is added on the ruling side so
    -- that whatever draws the prompt later keeps the tight number, and the only
    -- direction this can be wrong in is forgiving.
    reachSlackM = 2.0,

    -- ------------------------------------------------------------------
    -- HOUSEKEEPING
    -- ------------------------------------------------------------------

    -- How often the expiry sweep runs. The same cadence server/rescue.lua and
    -- server/ambheal.lua use, and for the same reason: this is a deadline check,
    -- not an animation, and a second of imprecision on a three-minute timer is
    -- not observable.
    tickMs = 1000,

    -- ------------------------------------------------------------------
    -- SPENDING ONE
    -- ------------------------------------------------------------------

    -- How long a squadmate holds the interact key over the key's own point to
    -- bring the owner of it back.
    --
    -- ⚠ NOT THE OWNER'S NUMBER. He has not given one. This is roughly double
    -- BR.Config.Match.dbnoReviveTime (2.8s), and the doubling is the only
    -- argument behind it: putting somebody back in the match is a larger act
    -- than picking up a mate who is still bleeding, and the whole read of the
    -- gesture -- standing still in the open, visible, doing nothing else -- is
    -- what the duration buys. Change it here and nothing else moves; the client
    -- ring is animated from this number and the server rules against it.
    reviveHoldMs = 6000,

    -- How close to the KEY'S OWN POINT the reviver has to stand.
    --
    -- ═══ TO THE RECORDED POINT, NEVER TO THE CORPSE ═══
    --
    -- server/revivekey.lua copies x/y/z off the body at mint time precisely so
    -- the key does NOT follow it, and this is the reach that circle is measured
    -- with. Measuring to the dead player's ped instead would inherit #163's
    -- drifting clone and commit 33ca88c's death-ragdoll problem in one line --
    -- the body a reviver is standing over walks out of any circle you draw
    -- around it, on their machine only, and the hold dies with nothing on screen
    -- to say why.
    --
    -- WIDER THAN `collectM` (2.5) BY HALF A METRE, on purpose. Collection is
    -- "standing on the body"; the revive is a hold you should not lose by
    -- shifting your feet, and it is the same relationship
    -- dbnoReviveDist/dbnoReviveSlack has.
    reviveReachM = 3.0,

    -- Slack added to `reviveReachM` for the SERVER's ruling only.
    --
    -- Identical in kind to `reachSlackM` above and to
    -- BR.Config.Match.dbnoReviveSlack: the server's position sample is up to one
    -- sampler interval old, so a ruling run at exactly `reviveReachM` cancels
    -- holds that were legitimate when they were made. The prompt keeps the tight
    -- number, the ruling keeps the loose one, and the only direction this can be
    -- wrong in is forgiving.
    reviveSlackM = 1.0,

    -- How long the server waits to hear from a hold before it drops it.
    --
    -- THE CLIENT RE-ASSERTS AND SILENCE IS A RELEASE, which is the protocol
    -- client/dbno.lua already runs and the reason a brief tap cannot complete a
    -- revive: the hold needs CONTINUOUS evidence, so a STOP that never lands
    -- costs a fraction of a second rather than the whole interaction. The client
    -- re-asks every 250ms; this is four of those.
    reviveBeatMs = 1000,
}

--- EVERY WORD THIS FEATURE SPEAKS, IN ONE PLACE, ALL OF IT PROVISIONAL.
---
--- ⚠ PLACEHOLDER WORDING PENDING THE OWNER'S. He listed these six lines on
--- 2026-08-30 and asked for the feature to ship rather than wait on him
--- polishing them, so they are here to be CORRECTED IN ONE EDIT: every prompt,
--- every confirmation and every notice in server/revivekey.lua and
--- client/revivekey.lua reads out of this table and holds no string of its own.
--- Rewrite a value here and the game says the new thing everywhere, immediately.
---
--- ═══ SIX, AND A SEVENTH IS A QUESTION RATHER THAN A COMMIT ═══
---
--- The standing rule on this project is that copy nobody asked for reads as
--- slop, and this is the feature that has come closest to breaking it. There is
--- deliberately NO refusal string, NO hint, NO empty state and NO progress
--- label: a press the server declines says nothing at all, exactly as the CPR
--- rescue and the ambulance heal say nothing (server/rescue.lua: "Nothing in
--- this feature ever tells a player anything"). If a seventh line ever seems
--- necessary, ask him for it.
---
--- ═══ `buy` CARRIES THE PRICE AS TEXT, AND THAT IS HIS SENTENCE ═══
---
--- "Buy revive keys — 25 Volts" is quoted verbatim, which means the 25 in the
--- string and the 25 in `price` above are two copies of one number. Left as
--- written rather than interpolated, because the words are his and the moment
--- this file starts assembling them out of parts is the moment his wording
--- stops being reproducible. If the price moves, both move -- and the console
--- line in /brkey prints `price` rather than this string, so the two can always
--- be compared.
BR.Config.ReviveKey.copy = {
    -- The world prompt over a key lying on the ground, for the squadmate who
    -- can walk to it. See the note on `collectM`: walking in is what takes it,
    -- so this plate carries NO key glyph -- it names the thing, it does not
    -- offer a press.
    take      = 'Take revive key',

    -- The world prompt at an ambulance, when this squad has something to buy.
    buy       = 'Buy revive keys — 25 Volts',

    -- The world prompt over a key the squad already owns: the hold that
    -- actually brings the owner of it back.
    revive    = 'Revive teammate',

    -- Sent to the squad the moment a key is collected off the ground...
    collected = 'Revive key collected',
    -- ...and the moment a purchase lands.
    bought    = 'Revive keys bought',
    -- ...and the moment the thing on the ground goes away. NOT the key: the key
    -- survives its pickup and is still buyable at an ambulance for the rest of
    -- the match. This line is about the free option closing.
    expired   = 'Revive key lost',
}

--- Which models count as an ambulance.
---
--- ═══ ONE LIST, AND IT IS server/rescue.lua's ═══
---
--- config/rescue.lua argues for a single list "so the vehicle the rescue BUILDS
--- and the vehicles it RECOGNISES can never mean different things", and
--- config/ambheal.lua already reads it rather than copying it. This is the third
--- feature to ask the word what it means and it asks the same place.
---
--- IT ASKS BR.Rescue.isAmbulance AT THE CALL SITE rather than resolving hashes
--- here, which is the resolution config/ambheal.lua's header reached: one list
--- with two resolvers is the same fault one step later.
--- @return string[]
function BR.Config.ReviveKey.models()
    local R = BR.Config.Rescue
    return (R and R.models) or { 'ambulance' }
end
