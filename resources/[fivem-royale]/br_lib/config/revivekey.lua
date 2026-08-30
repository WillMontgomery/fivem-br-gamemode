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
-- WHAT IS NOT HERE, AND MUST NOT BE ADDED UNTIL HE ASKS
-- ═══════════════════════════════════════════════════════════════════════════
--
-- NO STRINGS. Not a prompt, not a toast, not a marker label. #219 Q20 asks him
-- what his squad is told and when, and it is UNANSWERED -- so there is no
-- player-facing copy in this feature at all, and the owner's standing rule is
-- that unrequested copy reads as slop. config/rescue.lua holds the same line
-- ("Nothing in this feature ever tells a player anything").
--
-- NO RESURRECTION NUMBERS. No hold time, no drop height, no parachute, no
-- landing health. That is #219 step 5 and it is gated on Q10, Q11, Q18 and Q21,
-- none of which he has answered. A number written here ahead of them would be a
-- guess wearing the authority of config.

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
