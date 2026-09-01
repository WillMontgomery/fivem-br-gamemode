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
-- THE REVIVE HAPPENS AT AN AMBULANCE, AND THE ARRIVAL IS A DROP
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Owner, 2026-08-30, after the fifth round on this feature:
--
--   "I should be able to walk up to an ambulance and see a DUI to press
--    something to revive them. Then once that is complete, their screen should
--    fade to black, set focus to the area where the ambulance I just used is,
--    process the revive, give them a parachute, put them 150m above the
--    ambulance, then fade in. And now they're back in the match."
--
-- THAT SENTENCE DELETED THE CORPSE REVIVE AND WROTE THREE NUMBERS. The hold now
-- happens at an ambulance, so it is measured with `reachM` -- the SAME radius
-- the purchase already uses, because it is the same gesture at the same van and
-- a second number would be a second answer to "am I at it". The pair that used
-- to measure a hold at the body (`reviveReachM`, `reviveSlackM`) is GONE rather
-- than repurposed: nothing is measured to a key's recorded point any more.
--
-- AND THE ARRIVAL IS ITS OWN SEQUENCE, with `dropM`, `fadeMs` and `focusMs`
-- below. He did not give durations for the black or the focus hold; he gave the
-- ORDER and the height. See each key for which half is his.
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

    -- How close a squadmate has to be to the body to take the key off it.
    --
    -- ═══ THERE IS A PROMPT AND THERE IS A PRESS, AND THE OWNER ASKED FOR IT ═══
    --
    -- "I somehow picked up the dead player's key by walking up to them without
    -- seeing a DUI or pressing anything." -- the owner, 2026-08-30.
    --
    -- This file used to argue at length that collection needed no prompt: that
    -- there is no choice to refuse, that a prompt needs wording he had not
    -- given, and that the plate budget over a corpse was already spent. The
    -- first two are answered -- he HAS given the wording (`copy.take`) and he
    -- wants the press -- and the third was never a reason to make a pickup
    -- silent, only a reason to arbitrate the plates, which client/revivekey.lua
    -- does. A thing that leaves your pocket without you touching a key is
    -- something you cannot know you have.
    --
    -- SO THIS IS NOW A PROMPT RADIUS AS WELL AS A RULING ONE, and 2.5m is still
    -- "standing on the body" -- deliberately tighter than the 4.6m ring their
    -- kit is scattered in, so the key plate does not fight the crate plate from
    -- the far side of the loot without ever reaching them.
    collectM = 2.5,

    -- Slack added to `collectM` for the SERVER's own ruling only.
    --
    -- The same argument `reachSlackM` carries below and `reviveSlackM` used to:
    -- the server's position sample is up to one sampler interval old, so a
    -- ruling run at exactly `collectM` refuses presses that were legitimate when
    -- they were made. The plate keeps the tight number, the ruling keeps the
    -- loose one, and the only direction this can be wrong in is forgiving.
    --
    -- NEW WITH THE PRESS. While collection was a server-side proximity test
    -- there were not two numbers to reconcile -- the server was the only thing
    -- measuring. A press is a claim about where the player was a moment ago, so
    -- it needs the same slack every other press in this project is ruled with.
    collectSlackM = 1.0,

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

    -- How close to an ambulance "at an ambulance" is -- FOR BOTH THE PURCHASE
    -- AND THE REVIVE.
    --
    -- ═══ ONE RADIUS, TWO GESTURES, AND THAT IS DELIBERATE ═══
    --
    -- The revive moved to the van (see the header), so "am I at it" is now
    -- asked twice at the same vehicle by the same player. A second reach value
    -- would be a second answer to one question, free to drift, and the symptom
    -- would be a buy plate that appears half a metre before the revive plate
    -- does at the same van.
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

    -- How long a squadmate holds the interact key AT AN AMBULANCE to bring a
    -- mate whose key their squad holds back into the match.
    --
    -- ⚠ NOT THE OWNER'S NUMBER. He has not given one. This is roughly double
    -- BR.Config.Match.dbnoReviveTime (2.8s), and the doubling is the only
    -- argument behind it: putting somebody back in the match is a larger act
    -- than picking up a mate who is still bleeding, and the whole read of the
    -- gesture -- standing still in the open, visible, doing nothing else -- is
    -- what the duration buys. Change it here and nothing else moves; the client
    -- ring is animated from this number and the server rules against it.
    reviveHoldMs = 6000,

    -- ------------------------------------------------------------------
    -- WHERE THE PLATE HANGS ON THE VAN
    -- ------------------------------------------------------------------
    --
    -- ═══ THE OWNER'S SENTENCE, 2026-08-31 ═══
    --
    --   "I don't like the positioning of the 'press E to revive' DUI... What I
    --    want is a DUI that shows on the nearest face of the vehicle. If you
    --    want to make me the tools to manipulate the DUI position then fetch it
    --    I can give you the coords."
    --
    -- BOTH AMBULANCE PLATES READ THIS TABLE -- the revive and the purchase. They
    -- are one plate at one van drawn a moment apart (client/revivekey.lua's
    -- `choose` returns exactly one candidate, and the revive beats the buy), so
    -- a second set of numbers would be a second answer to "where does the plate
    -- go on an ambulance", free to drift, and the symptom would be the plate
    -- jumping the instant a squad bought a key.
    --
    -- ⚠ NONE OF THE FOUR IS THE OWNER'S NUMBER YET. He offered to measure them
    -- ("then fetch it I can give you the coords") and /brplate is the ruler:
    -- stand at an ambulance, `brplate on`, nudge, and paste the block it prints
    -- back over this table. These four are a starting point chosen to be
    -- obviously readable rather than obviously right.
    --
    -- TWO OF THE FOUR ARE MEASURED AGAINST THE MODEL RATHER THAN AGAINST
    -- NOTHING, which is what makes them survive a van this code has never seen.
    -- `out` starts at the model's own panel (BR.NearestBoxFace hands back the
    -- reach to it) and `frac` is a position in the model's own height
    -- (BR.ShopSolve.signHeight, the shop's derivation, borrowed rather than
    -- re-written) -- so a longer or taller ambulance moves its own plate and
    -- nothing here changes. config/shop.lua's `signBumperFrac` block is the full
    -- argument for why that beats a constant. `lift` and `width` are plain
    -- lengths, and are meant to be: one nudges every plate at once and the other
    -- is the size of a sign, neither of which is a fact about the bodywork.
    plate = {
        -- Metres the plate stands off the panel it is drawn on. Far enough that
        -- it cannot z-fight the bodywork or clip a wing mirror, close enough to
        -- read as painted on the van rather than floating beside it.
        out = 0.35,

        -- Where up the model's own height the plate's centre sits: 0 is the
        -- ground the tyres stand on, 1 the roof. 0.62 is above the shop's 0.35
        -- deliberately -- that one is at the BUMPER, because he asked for it
        -- there; this one is read by somebody standing at the van looking at it,
        -- so it sits about window height on an ambulance.
        frac = 0.62,

        -- Metres added after the derivation, to move every plate at once
        -- without touching the shape. config/shop.lua's `signLift`, same job.
        lift = 0.0,

        -- How wide the plate is, in metres; its height follows the 512x256
        -- page's own aspect rather than being a second number to keep in step.
        -- 0.75 is config/shop.lua's `signWidthM` -- the size the owner approved
        -- for the yard sign ("The overall DUI size is good", 2026-08-30) --
        -- matched rather than re-derived, so the two world signs in this game
        -- are one size. The interface-size preference still multiplies it.
        width = 0.75,
    },

    -- ------------------------------------------------------------------
    -- COMING BACK: THE ARRIVAL SEQUENCE
    -- ------------------------------------------------------------------
    --
    -- "their screen should fade to black, set focus to the area where the
    --  ambulance I just used is, process the revive, give them a parachute, put
    --  them 150m above the ambulance, then fade in."  -- the owner, 2026-08-30.
    --
    -- SIX STEPS IN ONE SENTENCE, AND THE ORDER IS THE SPECIFICATION. The three
    -- numbers under it are here; the sequence itself is split across
    -- server/revivekey.lua (which owns WHEN, because it owns the ledger) and
    -- client/revivekey.lua (which owns the screen, the ped and the chute).

    -- How far above the ambulance they are put down.
    --
    -- HIS NUMBER, EXACTLY, AND THE ONLY ONE OF THE THREE THAT IS. 150m is
    -- roughly two thirds of the bus's own drop and is comfortably above
    -- BR.Config.Drop.autoDeployAGL, so the canopy is a choice rather than a
    -- formality.
    dropM = 150.0,

    -- How long the screen takes to go black, before anything else happens.
    --
    -- ⚠ NOT THE OWNER'S NUMBER. He asked for a fade and did not time it. This is
    -- client/spawn.lua's departure fade rounded up a beat: long enough to read
    -- as a fade rather than a cut, short enough that a squad watching the ring
    -- close does not think it hung. The fade back IN is BR.Spawn.reveal()'s own,
    -- which is the one function in the client that undoes every dark screen.
    fadeMs = 400,

    -- How long the streaming focus sits on the ambulance BEFORE the ped is put
    -- above it.
    --
    -- ⚠ NOT THE OWNER'S NUMBER EITHER -- but it is his number for the same job
    -- somewhere else: "move the focus to the selected warmup spawn area for at
    -- least 1 second before moving the ped, then we fade in once the ped is
    -- there" (2026-08-29, client/spawn.lua's `departure.focusHoldMs`). The
    -- engine spends this second pulling the terrain around the van in while
    -- there is nothing on screen to spoil.
    --
    -- THE SERVER SPENDS fadeMs + focusMs BEFORE IT PROCESSES THE REVIVE, which
    -- is why both live in a SHARED config rather than on the client: the client
    -- draws the black and the server holds the ledger, and the two must be
    -- reading one clock.
    focusMs = 1000,

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
    -- The world prompt over a key lying on the ground, and the press that takes
    -- it. See the note on `collectM`: this plate DOES carry a key glyph now,
    -- because there is a key to press. "I somehow picked up the dead player's
    -- key by walking up to them without seeing a DUI or pressing anything"
    -- (owner, 2026-08-30) is the report that put one there.
    take      = 'Take revive key',

    -- The world prompt at an ambulance, when this squad has something to buy.
    buy       = 'Buy revive keys — 25 Volts',

    -- The world prompt AT AN AMBULANCE for a key the squad already owns: the
    -- hold that brings its owner back. It used to be drawn over the body; the
    -- owner moved it to the van, and once a mate has bled out the van is the
    -- only place it appears at all.
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
