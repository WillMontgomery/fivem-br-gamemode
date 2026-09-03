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
-- THE STRINGS ARE HERE NOW, AND EVERY ONE OF THEM IS HIS
-- ═══════════════════════════════════════════════════════════════════════════
--
-- This file used to say "NO STRINGS", and the reason it gave was that #219 Q20
-- was unanswered. It is answered: the owner listed six lines on 2026-08-30 and
-- then said to stop waiting on him and ship it, and he rewrote the collection
-- half of them himself on 2026-08-31.
--
-- SO ALL TEN LIVE IN ONE TABLE, `copy` BELOW, AND NOWHERE ELSE. That is the
-- whole point of the table: he can rewrite every word this feature speaks by
-- editing one screen of one file, without opening the server module, the client
-- module or the prompt page. No string in this feature may be written anywhere
-- but there -- not a default in a `or`, not a fallback in the client, not a
-- second copy in a comment that somebody later pastes.
--
-- AND THERE ARE EXACTLY TEN -- nine of them his of 2026-08-31 and the tenth
-- his of 2026-09-01. If the design ever needs an eleventh, the answer is to ask
-- him, not to write one. See the note over `copy`.
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
-- AND THE HEALTH IS `reviveHp`, WHICH IS THE OWNER'S OWN NUMBER NOW.
--
-- "when a revive is processed using the key, the player should come back with
--  full health"                                          -- owner, 2026-08-31
--
-- THIS FILE USED TO ARGUE THE OPPOSITE AT LENGTH, and the argument is worth
-- keeping as a record of what his sentence overturned: a key revive handed back
-- BR.Config.Match.dbnoReviveHp, the same 30 a squadmate's pick-up hands back,
-- "because it is the same act". It is not the same act, and he has said so. A
-- squad revive costs a mate a few exposed seconds beside a body; a key costs a
-- death, an inventory spilled on the ground, a fetch across the map or 25
-- Volts, and a six-second hold at a van. config/rescue.lua's `deliverHp = 100`
-- already made exactly this trade for exactly this reason.
--
-- IT IS A NUMBER OF THIS FEATURE'S OWN, AND THAT IS NOW THE POINT rather than
-- the objection. The old note called a second number "free to drift" from
-- dbnoReviveHp; the two are SUPPOSED to differ, so sharing one would have been
-- the drift. `reviveHp` is below, and BR.Config.Match.dbnoReviveHp is untouched
-- -- an in-person DBNO revive still hands back 30.

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

    -- The health a player is put back into the match on, when their squad spent
    -- a key on them.
    --
    -- ═══ HIS SENTENCE, 2026-08-31, AND IT IS THE WHOLE OF THIS NUMBER ═══
    --
    --   "when a revive is processed using the key, the player should come back
    --    with full health"
    --
    -- 100 IS FULL, and it is written as 100 rather than derived from anything
    -- because that is what every other absolute health in this project is:
    -- config/rescue.lua's `deliverHp`, BR.Config.Match.dbnoReviveHp, the values
    -- HEALTH_SYNC carries. The engine's own 200-based scale is converted at the
    -- edge, not here.
    --
    -- IT MOVES THE KEY REVIVE AND NOTHING ELSE. BR.Config.Match.dbnoReviveHp is
    -- still 30 and an in-person DBNO pick-up still hands back 30 -- the owner
    -- named one of the two and the other is untouched. See the header for what
    -- this file used to argue and why his sentence retires it.
    reviveHp = 100,

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
    -- ═══ AND IT IS FOUR SETS NOW, ONE PER PANEL, BECAUSE HE MEASURED FOUR ═══
    --
    -- Owner, 2026-09-02, after walking round an ambulance with /brplate:
    --
    --   face left:   out = -0.090,  side =  1.620,  frac = 0.620,
    --                lift = -0.340, width = 1.250
    --   face nose:   out = -0.250,  side = -0.030,  frac = 0.620,
    --                lift = -0.260, width = 1.250
    --   face right:  out = -0.090,  side = -2.220,  frac = 0.620,
    --                lift = -0.350, width = 1.250
    --   face tail:   out = -0.290,  side = -0.000,  frac = 0.620,
    --                lift = -0.110, width = 1.250
    --
    -- ⚠ THESE ARE HIS, TO THE THIRD DECIMAL, AND THEY ARE NOT TO BE TIDIED.
    -- `left` and `right` are not mirror images -- 1.620 against -2.220 -- and
    -- `tail` is spelled `-0.000`. Both look like something to fix and neither
    -- is: an ambulance's model origin is not on its centreline, so the same
    -- place on the bodywork IS a different `side` from either flank, and the
    -- readout he pasted from prints a signed zero because that is what the
    -- number in the table was. Averaging the pair, or rounding a sign away,
    -- silently moves plates he has already approved.
    --
    -- ═══ WHY ONE SET COULD NOT COVER FOUR PANELS ═══
    --
    -- `side` is metres along the panel from the MODEL'S OWN ORIGIN, and the
    -- distance from that origin to the middle of a flank is nothing like the
    -- distance to the middle of the tail. `out` and `lift` differ for the same
    -- kind of reason -- a van's back doors, its bonnet and its flanks are not
    -- one surface at one height. One set of five was one panel's numbers
    -- applied to four, which is what he was correcting.
    --
    -- ═══ WHICH SET IS BR.NearestBoxFace'S ANSWER, NOT A GUESS HERE ═══
    --
    -- The keys are the four words /brplate already prints in its readout
    -- ("face tail"), which are BR.Dui.nearFace's (ux, uy) said out loud: +Y is
    -- the nose, -Y the tail, +X the right flank, -X the left. client's
    -- `plateNumbers(face)` looks the set up by that word, so the plate a player
    -- walks up to and the numbers it is drawn with come off ONE face pick.
    --
    -- ═══ WHAT NO LONGER READS THIS TABLE AT ALL ═══
    --
    -- THE PLATE OVER A KEY ON THE GROUND. It used to take `frac` and `lift` from
    -- here, on 2026-09-01's instruction that it be level with the ambulance
    -- plate. He reported it too high a FOURTH time on 2026-09-02 and said where
    -- it goes instead: "It should be inside the 3dmarker". So it is anchored to
    -- `marker` below and to nothing here -- which also means these four sets are
    -- free to move per panel without dragging a plate in a field with them.
    --
    -- SO THE TWO PLATES AT A VAN SHARE THIS AND THE THIRD DOES NOT. The revive
    -- and the purchase are one plate at one van drawn a moment apart and must
    -- agree; the take is somewhere else entirely and must not.
    --
    -- TWO OF THE FIVE ARE MEASURED AGAINST THE MODEL RATHER THAN AGAINST
    -- NOTHING, which is what makes them survive a van this code has never seen.
    -- `out` starts at the model's own panel (BR.NearestBoxFace hands back the
    -- reach to it) and `frac` is a position in the model's own height
    -- (BR.ShopSolve.signHeight, the shop's derivation, borrowed rather than
    -- re-written) -- so a longer or taller ambulance moves its own plate and
    -- nothing here changes. config/shop.lua's `signBumperFrac` block is the full
    -- argument for why that beats a constant.
    --
    -- THE FIVE, IN EVERY SET:
    --
    --   out    metres off the panel the player is nearest to. NEGATIVE IS
    --          INSIDE THE BODYWORK and all four of his are -- a quad standing
    --          proud of an ambulance's slab sides read as floating beside it,
    --          and he brought every one of them back in.
    --   side   metres ALONG that panel, positive to the reader's right. Its
    --          direction is the FACE'S, not the van's: BR.NearestBoxFace says
    --          which panel, and this is spent along the perpendicular of that
    --          same answer, so "right" means the reader's right at the driver's
    --          door AND at the back doors. See BR.Dui.drawNearFace and the note
    --          in drawPlane beside the line that decides the same left for the
    --          writing on it. (Owner, 2026-09-01: "I need to be able to move it
    --          left/right as well.")
    --   frac   where up the model's own height the plate's centre sits: 0 the
    --          ground the tyres stand on, 1 the roof.
    --   lift   metres added after that derivation, so a nudge moves the plate
    --          without touching the shape. config/shop.lua's `signLift`.
    --   width  metres across; the height follows the 512x256 page's own aspect
    --          rather than being a second number to keep in step. The
    --          interface-size preference still multiplies it.
    plate = {
        left  = { out = -0.090, side =  1.620, frac = 0.620,
                  lift = -0.340, width = 1.250 },
        nose  = { out = -0.250, side = -0.030, frac = 0.620,
                  lift = -0.260, width = 1.250 },
        right = { out = -0.090, side = -2.220, frac = 0.620,
                  lift = -0.350, width = 1.250 },
        tail  = { out = -0.290, side = -0.000, frac = 0.620,
                  lift = -0.110, width = 1.250 },
    },

    -- ------------------------------------------------------------------
    -- THE MARKER THAT STANDS WHERE THE BODY USED TO
    -- ------------------------------------------------------------------
    --
    -- Owner, 2026-08-31: "After a player has bled out, their ped should become
    -- invisible. Only the 3dmarker (type 24) and DUI should be shown at their
    -- position. I like the blip though - let's keep that."
    --
    -- ═══ WHY THERE HAS TO BE ONE AT ALL ═══
    --
    -- The corpse was doing a job nobody had written down: it was the only thing
    -- in the WORLD that said "the key is here". The blip is a dot on a minimap
    -- and the DUI plate does not appear until `collectM` -- 2.5 metres -- so with
    -- the body gone and nothing in its place a squadmate would have to walk onto
    -- an unmarked patch of ground to discover the prompt. The marker is what
    -- makes the plate findable, which is why the owner named the two together.
    --
    -- ═══ THE AUDIENCE IS THE SQUAD, AND IT IS NOT A CHOICE MADE HERE ═══
    --
    -- client/revivekey.lua draws this from its `keys` table, which is built from
    -- the squad beacon and nothing else -- so the marker reaches exactly the
    -- people who already have the blip and could already have the plate. Making
    -- it visible to enemies would be a new fact about where somebody died
    -- travelling to players who were never told it, which is the boundary
    -- client/squadmates.lua states as "you see your squad, and nobody else".
    --
    -- ⚠ NONE OF THESE IS THE OWNER'S NUMBER. He specified the marker TYPE and
    -- nothing else; the rest are a starting point chosen to be readable, in the
    -- same spirit as `plate` above. The colour is the one part that is not
    -- arbitrary -- see `colour`.
    marker = {
        -- HIS NUMBER, AND THE ONLY ONE HERE THAT IS. Type 24 is the flat
        -- upright chevron GTA uses for a thing on the ground worth walking to.
        -- Named explicitly rather than left as a literal in the draw pass so
        -- that "the 3dmarker (type 24)" is greppable from his own words.
        kind = 24,

        -- ═══ WHICH OF THESE IS "TALLER", AND IT IS NOT THE OBVIOUS ONE ═══
        --
        -- Owner, 2026-09-02: "...inside the 3dmarker, which should also be made
        -- about 25% taller btw."
        --
        -- DrawMarker's scale is (scaleX, scaleY, scaleZ) and this marker is
        -- drawn `size, size, height` -- so `size` is METRES ACROSS, spent on BOTH
        -- horizontal axes at once, and `height` is the vertical one on its own.
        -- Making a marker taller by raising `size` makes it a quarter wider
        -- instead, on a marker that is already the widest thing on that patch of
        -- ground, and nothing about it would look taller.
        --
        -- THE NOTE THAT USED TO SIT HERE SAID THE OPPOSITE -- that type 24 draws
        -- in the ground plane so "the third dimension is thickness rather than
        -- height". It was wrong about the marker and it was contradicted by the
        -- owner's own report, which asks for a plate to be drawn INSIDE this
        -- thing: a marker with no vertical extent has no inside. `height` is the
        -- axis, and it is the only one that moved.
        --
        -- 0.4 -> 0.5 IS HIS 25%, ARITHMETIC RATHER THAN ROUNDED, and `size` is
        -- deliberately untouched: he asked for taller, not bigger.
        size = 0.8,
        height = 0.5,

        -- Metres above the key's recorded z. The key's z is the ground the body
        -- was lying on, and a marker drawn exactly on it z-fights the terrain.
        --
        -- ⚠ THE PLATE OVER THE KEY IS NOW HUNG OFF THIS AND OFF `height`. See
        -- `markerBand` in client/revivekey.lua: the plate is drawn at the middle
        -- of the band those two describe, so nudging either one moves the plate
        -- with the marker and there is no second number to keep in step. That is
        -- the whole of the owner's fourth report on that plate.
        lift = 0.06,

        -- THE PLATE'S OWN DANGER RED, NOT A NEW COLOUR. `#F87171` is what
        -- client/revivekey.lua sends the prompt page, and client/dbno.lua's
        -- revive plate carries it too -- "the world prompts that are about a
        -- PERSON rather than an object". Written out as the channels DrawMarker
        -- actually takes, because a hex string here would be a second spelling
        -- of one colour and the marker is the only consumer in this game that
        -- cannot use the first. Alpha is the one free number: low enough to read
        -- as a marking on the ground rather than a solid object standing on it.
        colour = { r = 248, g = 113, b = 113, a = 140 },

        -- How far away it is drawn, in metres.
        --
        -- WIDER THAN `collectM` BY A LOT, WHICH IS THE ENTIRE POINT -- it exists
        -- to be seen from where you are, not from where the prompt already is.
        -- Short of the blip's range on purpose: the minimap is how a squad
        -- crosses the map to a body and this is how they find it once they are
        -- in the area, and a chevron visible from 300m would be a second
        -- long-range marker competing with the one the owner asked to keep.
        drawM = 120.0,

        -- Does it spin? GTA rotates a marker for you when asked, and a chevron
        -- that turns is the engine's own idiom for "come here" -- the same thing
        -- the loot markers do.
        rotate = true,
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

--- EVERY WORD THIS FEATURE SPEAKS, IN ONE PLACE, AND ALL OF IT HIS.
---
--- He listed six lines on 2026-08-30 and asked for the feature to ship rather
--- than wait on him polishing them. On 2026-08-31 he polished them: he renamed
--- the pickup plate and wrote the four sentences the collection and the revive
--- now say. Every prompt, every confirmation and every notice in
--- server/revivekey.lua and client/revivekey.lua reads out of this table and
--- holds no string of its own. Rewrite a value here and the game says the new
--- thing everywhere, immediately.
---
--- ═══ TEN, AND AN ELEVENTH IS A QUESTION RATHER THAN A COMMIT ═══
---
--- The standing rule on this project is that copy nobody asked for reads as
--- slop, and this is the feature that has come closest to breaking it. There is
--- deliberately NO refusal string, NO hint, NO empty state and NO progress
--- label: a press the server declines says nothing at all, exactly as the CPR
--- rescue and the ambulance heal say nothing (server/rescue.lua: "Nothing in
--- this feature ever tells a player anything"). If an eleventh line ever seems
--- necessary, ask him for it.
---
--- THE TENTH IS `reviveHold`, AND HE WROTE IT (2026-09-01). It arrived with a
--- rewrite of `revive` in the same sentence, which is why the count moved by one
--- and not by two -- see both, below.
---
--- ═══ `%s` IS WHERE HE WROTE `[player]` ═══
---
--- Four of the ten name somebody. He wrote the hole as `[player]`; it is `%s`
--- here because that is the hole every sentence in this project uses and
--- because BR.Notice.line is what fills it -- splitting on THIS string, which
--- is ours, and never on the name, which is the player's. See
--- br_lib/shared/notice.lua: that split is the whole reason a name can be drawn
--- bold without a name being able to carry formatting.
---
--- ═══ DOUBLE QUOTES WHERE HIS WORDING HAS AN APOSTROPHE ═══
---
--- `"You've collected %s's revive key..."` rather than the same line in single
--- quotes with two backslashes in it. Both are the same Lua string; only one of
--- them can be read against his message without mentally unescaping it, and
--- being readable against his message is the entire job of this table.
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
    --
    -- IT SAID "Take revive key" UNTIL 2026-08-31, and the owner renamed it
    -- himself: "to be consistent with the terminology of the toast which reads
    -- 'Revive key collected'". `collect` below is the toast he means, in the
    -- words he has since given it -- the plate and the sentence it produces now
    -- use one verb.
    take      = 'Collect revive key',

    -- The world prompt at an ambulance, when this squad has something to buy.
    buy       = 'Buy revive keys — 25 Volts',

    -- The world prompt AT AN AMBULANCE for a key the squad already owns: the
    -- hold that brings its owner back. It used to be drawn over the body; the
    -- owner moved it to the van, and once a mate has bled out the van is the
    -- only place it appears at all.
    --
    -- ═══ IT IS THE PLATE'S BIG LINE NOW, AND IT NO LONGER NAMES ANYBODY ═══
    --
    -- Owner, 2026-09-01: "The ambulance DUI should say 'Revive your squad' and
    -- the line under (in the smaller lighter font) should say 'PRESS AND HOLD'
    -- instead of including the player's name."
    --
    -- TWO CHANGES IN ONE SENTENCE AND THE SECOND IS THE STRUCTURAL ONE. This
    -- string moves from the plate's SMALL line to its BIG one -- and the big one
    -- was the downed mate's NAME, which is what "instead of including the
    -- player's name" deletes. So the ambulance plate is the one prompt in this
    -- game that names nobody: `reviveHold` below took the small line, and the
    -- roster lookup that fed the name is gone from all three call sites in
    -- client/revivekey.lua rather than left feeding a field nothing reads.
    --
    -- IT IS STILL THE VERB AND STILL HIS. "Revive your squad" is quoted exactly
    -- as typed -- his capital R, his lower-case squad, no full stop.
    revive    = 'Revive your squad',

    -- The line under it, in prompt.html's smaller lighter face.
    --
    -- HIS CAPITALS, KEPT EVEN THOUGH THE PAGE WOULD SHOUT IT ANYWAY.
    -- dui/prompt.html sets `text-transform: uppercase` on `#hint`, so
    -- 'Press and hold' would REACH THE SCREEN LOOKING IDENTICAL -- and that is
    -- exactly why the capitals stay: he typed them, this table is the place his
    -- wording is read back against his message, and a value that renders the
    -- same is still not the value he wrote. The day that CSS rule changes, the
    -- line he asked for is the line that draws.
    reviveHold = 'PRESS AND HOLD',

    -- ------------------------------------------------------------------
    -- THE FOUR THAT NAME SOMEBODY (owner, 2026-08-31)
    -- ------------------------------------------------------------------
    --
    -- `%s` is his `[player]`; see the note above. Where a line has two holes,
    -- the comment says which person each one is, because he said so and getting
    -- them the wrong way round is the one mistake here that still reads as a
    -- sentence.

    -- To the squad, THE SUBJECT EXCLUDED, the moment somebody stops being in the
    -- match and their key is minted.
    --
    -- ═══ IT SAYS HOW LONG THE FETCH IS OPEN FOR, SINCE 2026-09-02 ═══
    --
    -- Owner: "Perhaps the 'grab their key!' toast should also mention that the
    -- key expires and after how long."
    --
    -- THE SMALLEST EDIT THAT CARRIES THE FACT. His sentence is otherwise
    -- untouched -- same two doors, same order, same exclamation marks -- and the
    -- deadline is inserted where it belongs rather than appended as a second
    -- sentence. ⚠ HE HAS NOT SEEN THIS WORDING. `within %s` is this file's
    -- guess at his instruction and it is one string in one place for him to
    -- overwrite.
    --
    -- IT ATTACHES TO THE FETCH AND NOT TO THE PURCHASE, which is the fact rather
    -- than a nicety: `expiryMs` retires the WORLD PICKUP and nothing else (see
    -- the block on it above), so the ambulance is still open afterwards and a
    -- sentence that put the clock on the whole line would be wrong about half of
    -- it.
    --
    -- ⚠ THE SECOND `%s` IS A DURATION, NOT A NAME. server/revivekey.lua fills it
    -- from BR.Config.ReviveKey.expiryMs through BR.Clock.words, so the three
    -- minutes are stated in exactly one place and re-tuning `expiryMs` cannot
    -- leave this line lying. BR.Notice.line writes a non-`who()` value in as
    -- prose, so it draws unbolded beside the bolded name.
    bledOut   = '%s has bled out! Get their revive key within %s or purchase it '
                .. 'at an ambulance!',

    -- To the player who pressed, and to nobody else.
    --
    -- IT REPLACES `collected = 'Revive key collected'`, which is the line he
    -- quoted on 2026-08-31 when he renamed the plate above -- so the terminology
    -- his rename was for is the terminology this says. The old line went to the
    -- whole squad; these two split that audience, because he wrote one sentence
    -- for the collector and a different one for everybody else.
    collect   = "You've collected %s's revive key. Get to an ambulance to "
                .. "revive them!",

    -- To the rest of the squad -- everyone but the collector, the person the key
    -- belongs to included, since they are watching their own body.
    --
    -- FIRST HOLE IS THE COLLECTOR, SECOND IS THE OWNER OF THE KEY. His words:
    -- "(first name is the collector, second is the owner of the key)".
    collectedBy = "%s picked up %s's revive key! Get to an ambulance to revive "
                .. "them.",

    -- To the whole squad when a revive completes at an ambulance.
    --
    -- FIRST HOLE IS THE REVIVER, SECOND IS THE ONE BROUGHT BACK. His words:
    -- "(first is the reviver, second is the revived)". The hyphen is his, not an
    -- em dash -- `buy` above shows he types one when he wants one.
    revived   = '%s revived %s - they are back in!',

    -- ------------------------------------------------------------------

    -- Sent to the squad the moment a purchase lands.
    bought    = 'Revive keys bought',

    -- Sent to the squad the moment the thing on the ground goes away. NOT the
    -- key: the key survives its pickup and is still buyable at an ambulance for
    -- the rest of the match. This line is about the free option closing.
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
