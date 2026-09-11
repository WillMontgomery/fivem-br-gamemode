-- The in-match Ammu-Nation weapon shop (#274): where the counters are, what is
-- sold over them, and what it costs.
--
-- ═══════════════════════════════════════════════════════════════════════════
-- THE GOVERNING RULE. IF YOU READ ONE PARAGRAPH, READ THIS
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Owner, 2026-09-08:
--
--   "config/shop.lua's header is for the pregame shop, where this is still
--    true. an in-game shop is different. also we're not planning to (as of now)
--    sell items which could not otherwise be found in the wild - just a
--    convenience with a fee."
--
--   "in-match wallet should not exist, agreed. the player has one Volts bank."
--
-- So the rule this feature lives or dies by is one sentence:
--
--     NOTHING IS SOLD HERE THAT CANNOT BE FOUND IN THE WILD.
--
-- The shop is a CONVENIENCE WITH A FEE. A player standing at this counter is
-- paying to skip the search, not to buy something the map would never have
-- given them. That is the whole of what stops a saved Volts balance turning
-- into an advantage, and it is the same argument config/shop.lua's header makes
-- about the warmup showroom -- except that showroom is a PREGAME shop, where the
-- worst case is transport, and this one opens in the middle of a fight.
--
-- ═══ AND NOTHING IN CODE ENFORCES IT, WHICH IS WHY IT IS WRITTEN HERE ═══
--
-- There is no line of Lua anywhere in this repository that can look at a
-- catalogue row and tell you whether the thing it names is findable on the map.
-- The rarity buckets, the airdrop shelf, the melee list and the crate tables are
-- four separate structures and "findable" is a property of the relationship
-- between them, not of any one row.
--
-- SO THE CATALOGUE IS DERIVED RATHER THAN AUTHORED, and that is the closest
-- thing to enforcement available. This file writes down NO list of weapons.
-- `BR.GunshopSolve.catalogue` walks BR.Config.Weapons -- the array the world
-- loot roll itself is built from -- and keeps the rows at BR.Rarity.RARE and
-- above. A weapon is on sale here BECAUSE it is in the table the map rolls
-- against, and the day the owner moves a rarity, adds a gun or removes one, the
-- shop moves with him and nobody has to remember that it exists.
--
-- A HAND-COPIED SECOND LIST IS THIS PROJECT'S SIGNATURE DEFECT. Two
-- representations of one fact, drifting apart quietly -- see the same paragraph
-- in shared/shop_solve.lua's header, which was written after it had already
-- happened. A copied weapon list here would go stale the first time a rarity
-- changed, and the symptom would be a shop selling a gun the map no longer
-- has, which is exactly the thing the owner's sentence forbids.
--
-- ═══ WHAT IS DELIBERATELY *NOT* SOLD ═══
--
--   BR.Config.AirdropWeapons -- RPG, grenade launcher, railgun, minigun. The
--   owner ruled on 2026-08-21 that these are AIRDROP-ONLY: "We just spawn normal
--   (ultra rare) loot and they can pick it up if they want to." They are in no
--   rarity bucket, so no world roll can ever produce them, so THE ONLY WAY TO
--   HOLD ONE IS TO REACH A SUPPLY DROP. Selling one over a counter would be
--   selling exactly the thing that cannot otherwise be found -- a breach of the
--   rule at the top of this file, not a balance question -- and it would also
--   undo the reason the airdrop is worth crossing the map for.
--
--   Deriving from BR.Config.Weapons excludes them for free, because that is the
--   array they are deliberately absent from (see the long note above
--   BR.Config.AirdropWeapons). `BR.GunshopSolve.catalogue` ALSO takes the
--   airdrop table and rejects by id anyway, so the exclusion survives somebody
--   later passing the merged BR.Config.WeaponById in by mistake.
--
--   BR.Config.Melee -- brass knuckles through battle axe. A SEPARATE TABLE from
--   BR.Config.Weapons, so deriving from Weapons excludes the whole list without
--   a single line of filtering. THAT IS DELIBERATE AND NOT AN ACCIDENT OF THE
--   FILTER: melee is a crate prize (user call, 2026-08-07), it has no magazine
--   and no ammo pool, and an Ammu-Nation counter selling a machete is not a
--   thing anybody asked for. If the owner ever wants them, it is a second
--   source table passed to the solver, not an edit to this note.
--
--   BR.Config.Throwables -- grenades, molotovs, sticky bombs, smoke. Also a
--   separate table and also excluded for free. Not ruled on either way; they are
--   findable in the wild, so the rule at the top does not forbid them. If they
--   are wanted, they are a third source table. Flagged rather than assumed.
--
--   Everything below BR.Rarity.RARE. Common and uncommon guns are what a player
--   trips over in the first ninety seconds of a match; paying Volts for a Micro
--   SMG is not a convenience anybody would use. The floor is named once, by
--   `BR.GunshopSolve.minRarity`, rather than spelled as a literal inside a
--   filter, so moving it is one line.
--
-- ═══ ONE VOLTS BANK, AND NO SECOND PURSE ═══
--
-- "in-match wallet should not exist, agreed. the player has one Volts bank."
--
-- So this feature adds NO currency, NO match-local balance and NO pickup that
-- means money. A purchase is debited from the saved balance the market already
-- owns (BR.Config.Market.currency is the one place the word "Volts" is spelled),
-- exactly as the warmup showroom's purchases are. There is nothing here to keep
-- in step with anything, because there is only one pot.
--
-- ═══════════════════════════════════════════════════════════════════════════

BR = BR or {}
BR.Config = BR.Config or {}

BR.Config.Gunshop = {
    -- WITH NO STORES OR NO CATALOGUE THE FEATURE IS INERT RATHER THAN BROKEN.
    -- BR.Config.Rescue.points' rule, applied a third time (config/shop.lua was
    -- the second). See BR.GunshopSolve.enabled.
    enabled = true,

    -- ------------------------------------------------------------------
    -- THE ELEVEN COUNTERS
    -- ------------------------------------------------------------------
    --
    -- Anchors read out of GTA's own `shop_controller` script data and
    -- cross-checked against two independent third-party transcriptions of the
    -- same set (ox_inventory's shop locations and qb-shops' `ammunation`
    -- config). The owner has confirmed these look right.
    --
    -- `heading` IS THE COUNTER'S FACING, not a clerk's and not a player's. What
    -- stands where relative to it is the client's decision and is deliberately
    -- not made here.
    --
    -- ═══════════════════════════════════════════════════════════════════════
    -- THE `z` IS THE TABULATED ANCHOR AND IT IS NOT A CLERK HEIGHT. DO NOT
    -- AUTHOR ONE.
    -- ═══════════════════════════════════════════════════════════════════════
    --
    -- THE SOURCES DISAGREE WITH EACH OTHER BY UP TO ABOUT 1.1 METRES on these z
    -- values, and the disagreement is not noise -- it is that they do not all
    -- mean the same thing by "the shop's z". Some tables carry the FLOOR of the
    -- interior at the counter. Others carry the coordinate a standing ped was
    -- recorded at, which is that floor plus roughly the distance from a ped's
    -- feet to its center. A metre is the difference between a clerk standing on
    -- the floor, a clerk buried to the waist in it, and a clerk floating.
    --
    -- THERE IS NO WAY TO TELL WHICH ONE ANY GIVEN ROW IS FROM THE NUMBER ALONE,
    -- and picking wrong is a fault that only a playtest can see -- eleven
    -- interiors, one of which will look fine while the other ten do not. The
    -- warmup showroom already paid for this lesson from the other end: `veto`
    -- shipped at an authored z that probed a metre out, and it cost three
    -- playtest rounds and a whole investigation before anybody looked at the
    -- ground instead of at the table (see the note on that row in
    -- config/shop.lua).
    --
    -- SO NOTHING HERE AUTHORS A CLERK z. THE CLIENT GROUND-PROBES. The engine
    -- knows where the floor of an interior is and no surveyed figure can be more
    -- accurate than asking it. This table carries the ANCHOR -- which is
    -- correct as an x/y position and as a rough height for starting a probe --
    -- and the override slots below, and nothing else.
    --
    -- `zOverride` IS THE ESCAPE HATCH AND IT SHOULD STAY EMPTY. An absolute
    -- world z that skips the probe entirely, for the one interior where the
    -- probe is eventually found to be wrong (a mezzanine, a prop the ray
    -- catches, an interior that has not streamed). Authoring one is a decision
    -- to trust a typed number over the engine, so it wants a reason beside it.
    --
    -- `probeFromM` IS THE OTHER SLOT: how far ABOVE the anchor the client starts
    -- its downward probe, when this store's anchor turns out to be the standing
    -- figure rather than the floor and the default start is already below the
    -- ceiling of something. Also nil everywhere, also per-store.
    --
    -- `range = true` marks the two SHOOTING-RANGE interiors. Those two buildings
    -- have a second room behind the shop floor, so anything that reasons about
    -- what is inside the store (a probe ceiling, a spawn area, an interior id)
    -- has a case here it does not have at the other nine.
    --
    -- `clerk = 'country'` marks the two that want the country clerk model rather
    -- than the city one. See `clerkModels` below.
    --
    -- NO `label`. The store ids are the districts they stand in and are enough
    -- to name a row in a console line; a display name is COPY, the owner has not
    -- written any for this feature, and inventing player-facing text is a
    -- standing rule against, not a gap to fill. Whoever builds the UI should ask
    -- him for the words rather than reading a guess out of this file.
    stores = {
        { id = 'pillbox',  x =    23.6862, y = -1106.4610, z =  29.9159, heading = 160.0000, range = true },
        { id = 'sandy',    x =  1693.5720, y =  3761.6010, z =  34.8242, heading = 227.3919, clerk = 'country' },
        { id = 'hawick',   x =   252.8583, y =   -51.6284, z =  70.0600, heading =  69.9999 },
        { id = 'lamesa',   x =   841.0564, y = -1034.7620, z =  28.3137, heading =   0.0000 },
        { id = 'paleto',   x =  -330.2908, y =  6085.5480, z =  31.5737, heading = 224.9999, clerk = 'country' },
        { id = 'seoul',    x =  -660.9294, y =  -934.1031, z =  21.9481, heading = 180.0000 },
        { id = 'morning',  x = -1304.9760, y =  -395.8181, z =  36.8147, heading =  75.7783 },
        { id = 'route68',  x = -1117.6120, y =  2700.2640, z =  18.6730, heading = 221.8271 },
        { id = 'chumash',  x = -3172.5110, y =  1089.4120, z =  20.9576, heading = 246.5813 },
        { id = 'palomino', x =  2566.5920, y =   293.1332, z = 108.8538, heading =   0.0000 },
        { id = 'cypress',  x =   808.8609, y = -2158.5080, z =  29.7379, heading =   0.0000, range = true },
    },

    --- THE TWO CLERK MODELS, NAMED HERE BECAUSE THEY ARE DATA.
    ---
    --- Rockstar ships two Ammu-Nation shopkeepers and uses the country one at
    --- the rural stores. Which store gets which is the `clerk` field above; the
    --- model strings are here so the client resolves a key rather than carrying
    --- a model name of its own.
    ---
    --- UNVERIFIED IN GAME AND WORTH ONE GLANCE. These are the model names the
    --- community resources use for these two peds; nothing in this repository
    --- has loaded either of them yet. A model that will not stream is a counter
    --- with nobody behind it, so whoever writes the client should say so on the
    --- console rather than failing silently, and should treat a failed request
    --- as "no clerk" rather than as an error.
    clerkModels = {
        city    = 's_m_y_ammucity_01',
        country = 's_m_m_ammucountry',
    },

    --- HOW CLOSE "AT THE COUNTER" IS, IN METRES, MEASURED IN 2-D.
    ---
    --- Every reach in this project is flat (see BR.ShopSolve.nearest), and here
    --- it matters more than usual: a player is on the shop floor and the anchor's
    --- z is of uncertain meaning by up to a metre, so a 3-D distance would be
    --- measuring against a number this file explicitly refuses to trust.
    ---
    --- 2.5m IS A FIRST CUT AND IS THE OWNER'S TO MOVE. The eleven counters are
    --- not near each other -- the closest pair is districts apart -- so unlike
    --- the warmup showroom there is no ambiguity for the radius to resolve and
    --- nothing here has to be tight. It only has to mean "standing at the
    --- counter and not walking past the door".
    reachM = 2.5,

    --- ...AND HOW FAR THE SERVER LETS THAT REACH, WHICH IS FURTHER ON PURPOSE.
    ---
    --- ═══ THE SERVER IS NOT MEASURING THE SAME THING THE CLIENT IS ═══
    ---
    --- `reachM` above answers "should this player be offered a counter", asked on
    --- their own machine against their own ped, this frame. The server answers
    --- "was this player at a counter when they pressed", and it has no ped to ask:
    --- it has BR.Roster's SAMPLED position, taken by server/roster.lua at
    --- BR.Config.Match.posSampleHz -- 4 Hz -- so the newest reading it can hold is
    --- up to 250ms old.
    ---
    --- 250ms OF A SPRINT IS ABOUT 1.8 METRES. Measuring a 2.5m reach against a
    --- position that stale would refuse a player who is standing at the counter
    --- and whose last sample was taken as they walked up to it -- a purchase that
    --- fails for a reason nobody can see, which is the worst refusal there is.
    ---
    --- BEING GENEROUS COSTS NOTHING HERE, AND THAT IS WHY IT IS THE ANSWER. The
    --- security property this check exists for is "a client cannot shop from the
    --- top of Mount Chiliad", not "a client cannot shop from four metres away";
    --- the nearest two counters are districts apart (tools/test_gunshop.lua
    --- asserts it), so a radius four times the client's still names exactly one
    --- store and still puts the player inside the building.
    serverReachM = 6.0,

    -- ------------------------------------------------------------------
    -- THE CLERK
    -- ------------------------------------------------------------------
    --
    -- NONE OF THESE WERE IN THE FIRST CUT OF THIS FILE, and the header above the
    -- store table says why: "what stands where relative to [the heading] is the
    -- client's decision and is deliberately not made here". Building the client
    -- turned that from a decision not yet made into a decision made, and a number
    -- the client invented would be a number the owner cannot move without opening
    -- a client file. So they are here, together, with the same "first cut, his to
    -- move" standing that `reachM` has.
    --
    -- EVERY ONE OF THESE IS UNSEEN IN GAME. Nothing in this repository has ever
    -- put a ped in an Ammu-Nation. They are starting values chosen to be safe
    -- rather than measured values, and the dev command `/brgunshop` exists to
    -- turn one playtest round into eleven real numbers.

    --- HOW CLOSE A PLAYER COMES BEFORE A CLERK IS BUILT, AND HOW FAR THEY GO
    --- BEFORE HE IS TAKEN DOWN. Metres, flat, same as every other reach here.
    ---
    --- ═══ TWO NUMBERS RATHER THAN ONE, BECAUSE ONE IS A FLICKER ═══
    ---
    --- A single radius means a player standing on it builds and destroys a ped
    --- once a second for as long as they stand there -- a model request, a
    --- ground probe and a delete, every second, from a reconciler that thinks it
    --- is idle. The gap between these two is the hysteresis that makes that
    --- unreachable.
    ---
    --- 60m IS INSIDE THE BUILDING AND 90m IS OUTSIDE IT. An Ammu-Nation shop
    --- floor is a few metres across, so 60m means "on this block, probably
    --- through the door" -- close enough that the interior has streamed and the
    --- ground probe has something to hit, far enough that the clerk is standing
    --- there before the player is looking at him.
    ---
    --- WHY THIS FEATURE HAS A DISTANCE TERM AND THE WARMUP SHOWROOM DOES NOT.
    --- The showroom is ONE pad, built at the flip to warmup and torn down at
    --- wheels-up, and every player in the match is going to walk through it.
    --- These are ELEVEN buildings scattered over 51 km^2, ten of which any given
    --- player will never enter, and a framerate investigation on 2026-09-07
    --- found that invisible-but-simulated peds and per-frame entity work are
    --- what actually cost frames on this server. Eleven permanent peds would be
    --- ten of them simulated for nobody.
    clerkBuildM = 60.0,
    clerkKeepM  = 90.0,

    --- WHERE HE STANDS RELATIVE TO THE ANCHOR, AND WHICH WAY HE FACES.
    ---
    --- ═══ THESE WERE ZERO AND ZERO, AND THE PLAYTEST SAID WHY THAT WAS WRONG
    ---     ═══
    ---
    --- They shipped at zero because the anchors were cross-checked against
    --- ox_inventory's shop locations and qb-shops' `ammunation` config (see the
    --- store table above), and in BOTH of those resources the row is where the
    --- SHOP PED is created. Zero was those two resources' own answer, adopted
    --- rather than invented. The note here said what would change it: "the owner
    --- looking at a clerk standing in the customer's spot".
    ---
    --- Owner, 2026-09-09, having done exactly that at five of the eleven:
    ---
    ---   "The ped position is consistently on top of the register (as I have
    ---    validated at many shops) - let us move their position back behind the
    ---    counter and to the left (the ped-s right) about 1m"
    ---
    --- SO THE ANCHOR IS THE REGISTER, NOT THE CLERK'S SPOT. Consistently, at
    --- every store he checked, which is the useful half of that sentence: one
    --- correction moves all eleven and no store needs a number of its own.
    ---
    --- ─────────────────────────────────────────────────────────────────────
    ---  NEEDS HIS PLAYTEST: HOW FAR BACK IS "BEHIND THE COUNTER".
    --- ─────────────────────────────────────────────────────────────────────
    ---
    --- HE GAVE ONE NUMBER AND THERE ARE TWO HOLES. "About 1m" is read as the
    --- LATERAL move, which is the half of his sentence it sits next to, and
    --- `clerkRightM` is that metre. The step BACK has no number in his message
    --- at all, so -0.7 is this file's guess at a shop counter's depth -- far
    --- enough to clear a register, not so far that he is against the back wall.
    --- It is the first number to move if the clerk is still not where he wants
    --- him, and moving it is one edit here.
    ---
    --- WHAT EACH ONE DOES. `clerkOffsetM` slides him along the counter's own
    --- heading -- positive is forward, the way the counter faces, so NEGATIVE IS
    --- BACK. `clerkRightM` slides him along the counter's right, positive to the
    --- ped's right, which with `clerkFaceDeg` at zero is the direction his
    --- sentence names. `clerkFaceDeg` turns him on the spot and does not move
    --- him, so a facing fix cannot silently undo a position fix. Three numbers,
    --- one playtest round.
    clerkOffsetM = -0.7,
    clerkRightM  = 1.0,
    clerkFaceDeg = 0.0,

    --- HOW LONG THE CLERK HOLDS THE WEAPON OUT, in milliseconds.
    ---
    --- ═══ ONE NUMBER, READ BY BOTH HALVES, BECAUSE IT IS ONE MOMENT ═══
    ---
    --- Owner, 2026-09-09, P2 step 4: "the entity is deleted, the ped tasks
    --- cleared, and I am now armed with that weapon ALL AT ONCE."
    ---
    --- Three things end together and they end on two different machines. The
    --- CLIENT deletes the prop and clears the clerk's tasks when this elapses;
    --- the SERVER delivers the weapon into the inventory when this elapses. A
    --- number typed into either file alone would be that moment splitting in
    --- half the day somebody tuned one of them -- the gun appearing before the
    --- clerk has finished offering it, or the clerk's hand emptying into
    --- nothing. It is spelled here so there is nothing to keep in step.
    ---
    --- AMMO NEVER WAITS. P2 step 5 skips the whole presentation for ammo, so an
    --- ammo purchase is delivered the instant the charge lands and this number
    --- is not consulted.
    ---
    --- IT IS A REAL COST AND IT IS STATED. The server's post-charge gate
    --- forfeits a purchase whose buyer stopped being alive in a live match, and
    --- this widens that window by exactly this many milliseconds. Against a
    --- DynamoDB write of up to six seconds, which is what the gate was written
    --- for, 1.4 seconds is a small addition -- but it is an addition, and the
    --- day this is raised to something theatrical it is the thing to weigh.
    handoverMs = 1400,

    --- HOW LONG A CLERK MODEL MAY TAKE TO STREAM BEFORE THE COUNTER GIVES UP.
    ---
    --- client/rescue.lua's paramedic uses 5000 for the same question and the same
    --- kind of ped. A request that has not landed in five seconds is a request
    --- that is not going to; the console says which model and which store, and
    --- the store stands down rather than erroring -- which is what the note above
    --- `clerkModels` asks for in as many words.
    modelWaitMs = 5000,

    --- HOW FAR ABOVE THE ANCHOR THE GROUND PROBE STARTS, WHEN A STORE HAS NO
    --- `probeFromM` OF ITS OWN.
    ---
    --- ═══ THE NUMBER IS SQUEEZED BETWEEN TWO FAILURES AND BOTH ARE SILENT ═══
    ---
    --- GET_GROUND_Z_FOR_3D_COORD answers with the highest ground BELOW the point
    --- it is handed -- client/loot.lua carries the write-up and the playtest that
    --- produced it ("hillside loot just spawned below the map instead"). So:
    ---
    ---   TOO LOW and the probe starts UNDER the shop floor, where the highest
    ---   ground below it is the storey beneath or nothing at all. The header
    ---   above the store table says the tabulated z may be the floor OR a
    ---   standing ped's center, up to about 1.1m apart, so starting AT the
    ---   anchor is starting under the floor at every store where it is the
    ---   floor and float noise goes the wrong way.
    ---
    ---   TOO HIGH and the probe starts above the CEILING, and the highest ground
    ---   below it is the roof of the building. A clerk on the roof of Ammu-Nation
    ---   is the same class of bug as loot under the map and reads as a wrong
    ---   number rather than as a wrong native.
    ---
    --- 1.5 CLEARS THE WORST CASE OF THE FIRST BY 0.4m AND SITS WELL UNDER THE
    --- SECOND: these are shop interiors with something like a three-metre ceiling
    --- over a counter, so a probe from a metre and a half over the anchor is
    --- inside the room whichever of the two meanings the anchor has.
    ---
    --- PER-STORE `probeFromM` OVERRIDES IT and is nil everywhere, exactly as
    --- shipped. The two shooting-range stores (`range = true`) are the ones to
    --- suspect first if a clerk comes out somewhere strange.
    probeLiftM = 1.5,

    --- HOW LONG THE PROBE MAY KEEP ASKING BEFORE THE ANCHOR z IS USED AS IT IS.
    ---
    --- The native is documented as answering false when the coordinates are
    --- outside the client's render distance (citizenfx/natives,
    --- MISC/GetGroundZFor_3dCoord.md), and a clerk is built at `clerkBuildM` --
    --- sixty metres out, through a wall, quite possibly before the interior has
    --- streamed. So the first probe legitimately answers nothing, and the answer
    --- is to ask again rather than to place on a refusal.
    ---
    --- THE SAME BUDGET AS THE SHOWROOM'S COLLISION WAIT (BR.Config.Shop
    --- .collisionWaitMs, 1500) and the same shape: request, poll, give up, carry
    --- on with today's behavior. A clerk placed at the raw anchor is a clerk who
    --- may be a metre out; a clerk who never appears because one streaming
    --- request never completed is a counter that does not work at all.
    probeWaitMs = 1500,

    --- THE PLATE ABOVE THE COUNTER: how far in front of the clerk it stands, how
    --- far above his feet, and how wide it is. Metres.
    ---
    --- A PED'S ORIGIN IS AT HIS FEET, which is the difference from
    --- BR.Config.Shop's sign numbers -- those are offsets from a vehicle's
    --- origin, which is somewhere around its axle line, and BR.ShopSolve
    --- .signHeight derives them from the model's own bounding box. A ped's box is
    --- about 0.35m deep and "bumper fraction" means nothing on it, so these are
    --- authored: 1.05m up is chest height on a standing ped, 0.55m forward puts
    --- the plate over the counter rather than inside the clerk.
    ---
    --- "FORWARD" IS THE CLERK'S OWN FACING, so `clerkFaceDeg` above turns the
    --- clerk and his sign together and one number fixes both. If a playtest finds
    --- the plate behind him, that is the number to move rather than this one --
    --- and it will not have vanished in the meantime: BR.Dui's quad is drawn
    --- from whichever side the camera is on, so a sign facing away reads
    --- backwards rather than not at all.
    signForwardM = 0.55,
    signUpM      = 1.05,
    signWidthM   = 0.55,

    --- THE CUE KEY THE PURCHASE PLAYS. A KEY, NOT A SOUND.
    ---
    --- `shop.buy` is already in BR.Config.Audio.cues -- the owner picked it on
    --- 2026-09-08 for "Shop purchase complete" -- so this is the existing cue
    --- named by the existing key, and br_core/client/sfx.lua stays the only file
    --- in the project that knows what set and name it resolves to.
    ---
    --- THE REFUSAL CUE IS NOT HERE and that is not an omission: `shop.denied`
    --- rides on BR.Market.tellShortfall's toast, at the one funnel every shortfall
    --- in the game reaches, so this feature inherits it without naming it.
    cue = 'shop.buy',

    --- THE REFUSAL CUE, WHICH IS HERE NOW AND WAS NOT BEFORE.
    ---
    --- ═══ IT HAD TO BE NAMED THE DAY THE COUNTER STOPPED BORROWING THE
    ---     MARKET'S SENTENCE ═══
    ---
    --- The note above is still true about HOW it works -- `shop.denied` rides ON
    --- the toast payload rather than beside it, so it REPLACES the general warn
    --- sound instead of playing on top of it -- and no longer true that this
    --- feature inherits it for free. The owner rewrote this counter's shortfall
    --- sentence on 2026-09-09 (`poorToast` below), so server/gunshop.lua now
    --- speaks its own toast and BR.Market.tellShortfall is off the path.
    ---
    --- A KEY, NOT A SOUND, exactly as `cue` above is: br_core/client/sfx.lua
    --- stays the only file in the project that knows what set and name this
    --- resolves to, and /brsfx can still audition it.
    denyCue = 'shop.denied',

    -- ------------------------------------------------------------------
    -- WHAT IS ON THE SHELF, AND HOW MUCH OF IT
    -- ------------------------------------------------------------------
    --
    -- Owner, 2026-09-09:
    --
    --   "Each shop should start the match with a random number of weapons in
    --    stock, distributed across all categories they sell. Let us say this
    --    number is between 3 and 8 total. They will have no limited stock on
    --    ammo."
    --   "The amount of each item they have in stock should differ between
    --    shops"
    --
    -- HIS TWO NUMBERS, AND NOTHING ELSE IS AUTHORED HERE. How the total is
    -- spent -- one unit into every rarity band first, then the remainder at
    -- random across the shelf -- is BR.GunshopSolve.rollStock's rule, where a
    -- test can run it. This file holds the band, because the band is the thing
    -- he is likely to move after a round.
    --
    -- THE FLOOR AND THE NUMBER OF BANDS ARE THE SAME NUMBER, WHICH IS WHAT MAKES
    -- "DISTRIBUTED ACROSS ALL CATEGORIES" AFFORDABLE. The catalogue has three
    -- rarity bands -- rare, epic, legendary -- and his floor is 3, so the
    -- smallest legal shop is exactly one of each and every shop above it has
    -- spare units to scatter. Lowering `stockMin` below 3 is legal and quietly
    -- gives the guarantee up: rollStock spends what it has, in band order, and
    -- stops.
    --
    -- EVERY SHOP THEREFORE HOLDS AT LEAST ONE LEGENDARY, which is the reading of
    -- his sentence rather than a decision this file made. If eleven guaranteed
    -- legendaries across the map is more than he wants, the rule to change is
    -- rollStock's band pass, not these two integers.
    --
    -- AMMO IS NOT COUNTED AT ALL. "They will have no limited stock on ammo", so
    -- there is no ammo term here and none in the roll: an ammo row never appears
    -- in a stock table, and that absence is what every reader takes to mean
    -- unlimited.
    stockMin = 3,
    stockMax = 8,

    -- ═══════════════════════════════════════════════════════════════════════
    --  EVERY WORD A PLAYER READS AT THIS COUNTER, AND ALL OF THEM ARE HIS
    -- ═══════════════════════════════════════════════════════════════════════
    --
    -- This block used to hold one placeholder and a note asking the owner to
    -- replace it. He played the counter on 2026-09-09 and wrote the lot. What
    -- follows is his wording, character for character, and the ONLY marks added
    -- to it are the tildes -- which are not letters. ui-src's KeyText paints
    -- anything between a pair of them with `--color-volts`, which is this
    -- project's one mechanism for the signature color, and he asked for it by
    -- name: "remember the Volts text and quantity must be our signature color".
    --
    -- NOTHING BELOW MAY BE TIDIED. The colon-space in "Your balance is: ", the
    -- full stops, the capital letters in "Out of Stock" -- all his. A rewrite
    -- that reads better is a rewrite that is wrong.

    --- WHAT THE COUNTER IS CALLED ON SCREEN. Two surfaces, one word.
    ---
    --- Owner, 2026-09-09: "The menu title should say Weapon Shop", and, of the
    --- world plate, "the DUI should follow our standard formatting and content -
    --- a title Weapon Shop and a line underneath PRESS TO OPEN".
    ---
    --- ONE VALUE FOR BOTH, WHICH IS WHY THE PLACEHOLDER WAS ONE VALUE FOR BOTH.
    --- br_core/client/gunshop.lua reads this twice -- once for the plate's label
    --- and once for the ScaleformUI banner -- so his two sentences are one edit
    --- and the two surfaces cannot drift apart. Whoever builds the plate must
    --- read this rather than typing the words a second time.
    menuTitle = 'Weapon Shop',

    --- WHAT A ROW WITH NOTHING BEHIND IT SAYS WHERE ITS PRICE WOULD BE.
    ---
    --- Owner, 2026-09-09: "If an item is out of stock, the row should be locked
    --- and a price should not be shown - instead show Out of Stock".
    ---
    --- IT REPLACES THE PRICE RATHER THAN JOINING IT. "a price should not be
    --- shown" is the load-bearing half of that sentence: a sold-out row must not
    --- read as a thing with a cost.
    outOfStockLabel = 'Out of Stock',

    --- WHAT A PLAYER WHO CANNOT AFFORD A ROW IS TOLD. TWO SENTENCES.
    ---
    --- Owner, 2026-09-09: "if they select an item they cannot afford, give them
    --- a toast that says You do not have enough Volts for that item. Your
    --- balance is: {balance} Volts."
    ---
    --- ═══ THIS REPLACES THE MARKET'S SENTENCE AT THIS COUNTER, AND HE ASKED
    ---     FOR THAT TOO ═══
    ---
    --- Owner, same message: "You need 378 more to buy that is not good copy -
    --- how about You need more Volts to buy that item. again, volts text should
    --- be our color."
    ---
    --- ─────────────────────────────────────────────────────────────────────
    ---  NEEDS HIS DECISION: HE WROTE TWO SENTENCES FOR ONE REFUSAL.
    --- ─────────────────────────────────────────────────────────────────────
    ---
    --- "You need more Volts to buy that item." and "You do not have enough Volts
    --- for that item. Your balance is: {balance} Volts." are both his, both
    --- written in the same message, and both about the press that produced "You
    --- need 378 more to buy that". THE LONGER ONE IS USED HERE, because it is
    --- strictly the shorter one plus the balance he asked to see, and because it
    --- is the one he wrote as a specification rather than as a "how about". If
    --- he wants the short one, it is this string and nothing else moves.
    ---
    --- AND THE OLD SENTENCE IS STILL LIVE SOMEWHERE ELSE. "You need %d more to
    --- buy that." is BR.Market.tellShortfall's, and three other callers speak
    --- it: the pregame vehicle showroom, and both arms of BR.Market.charge,
    --- which is the revive-key purchase's path. Retiring it there is a change to
    --- server/market.lua and a decision about a screen he has not commented on,
    --- so it is NOT made here.
    ---
    --- `%s` IS THE BALANCE, ALREADY MARKED AND ALREADY WORDED. It arrives as
    --- "~1234 Volts~" from BR.ShopSolve.priceLine, so the currency word is
    --- BR.Config.Market.currency's and this file never spells it -- the same
    --- division config/shop.lua's `balanceToast` makes for the same reason.
    poorToast    = 'You do not have enough ~Volts~ for that item.',
    balanceToast = 'Your balance is: %s.',

    --- WHAT A PLAYER WHO JUST BOUGHT AMMO IS TOLD.
    ---
    --- Owner, 2026-09-09: "when ammo is purchased show a success toast: You
    --- purchased {item} for {cost}. otherwise they have no way to know anything
    --- went through."
    ---
    --- TWO HOLES, IN HIS ORDER. `%s` one is the item, which is
    --- BR.GunshopSolve.menuLabel -- his own label out of config/weapons.lua or
    --- config/loot.lua, plus the quantity mark an ammo row already carries. `%s`
    --- two is the cost, marked for the signature color like every other figure
    --- in a toast in this game.
    ---
    --- AMMO ONLY, WHICH IS HIS SCOPING. A weapon purchase gets the clerk's
    --- handover animation instead, so a toast there would be the second thing
    --- saying the same thing.
    boughtToast = 'You purchased %s for %s.',

    -- ------------------------------------------------------------------
    -- WHAT IT COSTS
    -- ------------------------------------------------------------------
    --
    -- Owner, 2026-09-08:
    --
    --   "ammo should be cheap (20-50 Volts), and prices should be a range per
    --    weapon class - rare is 100-150 Volts, epic is 200-275 Volts, and
    --    legendary is 400-500 Volts."
    --
    -- HIS BANDS ARE RANGES, SO THE WEAPONS INSIDE A BAND ARE SPREAD ACROSS IT
    -- rather than all sharing one number. Every price below is a LITERAL and not
    -- a formula, deliberately: a formula would mean he could not move one gun
    -- without moving its neighbours, and moving one gun by hand is the entire
    -- reason a price table exists.
    --
    -- ═══ THE AXIS IS PER-SHOT `damage`, ASCENDING ═══
    --
    -- Within each band the guns are sorted by the `damage` field in
    -- config/weapons.lua and priced from the bottom of the band to the top. The
    -- damage figure is quoted on every line, so the ordering is checkable
    -- against the source table without opening it.
    --
    -- WHY THAT AXIS AND NOT SUSTAINED DPS. `damage / minInterval` is the more
    -- sophisticated number and both fields are right there, and it was rejected
    -- for two reasons. It reorders the band in ways that read as wrong to the
    -- person paying -- the Heavy Revolver, a 97-damage hand cannon, prices
    -- BELOW the SMG Mk II on a DPS axis -- and, more importantly, `damage` is
    -- the number the server's own damage model and anti-cheat already run on
    -- (BR.Config.ExpectedDamage), so pricing on it means the shop's order and
    -- the game's order cannot disagree.
    --
    -- WHERE THE AXIS READS ODDLY, SAID OUT LOUD. Per-shot damage is not
    -- comparable ACROSS weapon classes in a fight: a shotgun's 72 is one slow
    -- shell and a rifle's 33 is ten rounds a second. So the Assault Shotgun and
    -- the Heavy Revolver land at the expensive end of RARE, and the Sniper Rifle
    -- and Revolver Mk II at the expensive end of EPIC, on a number that
    -- overstates them. That is the axis being consistent rather than being
    -- right, and those four are the first rows the owner is likely to want to
    -- move. Moving one is one integer.
    --
    -- TIES BREAK ON THE AUTHORED ORDER of BR.Config.Weapons, which is the class
    -- grouping he already reads that file in.
    --
    -- ═══ A WEAPON WITH NO PRICE IS DROPPED, NOT SOLD FOR NOTHING ═══
    --
    -- The catalogue is derived and this table is authored, so the two can come
    -- apart in one direction: he adds a gun at RARE and does not price it.
    -- BR.GunshopSolve.catalogue REJECTS that row and BR.Config.Gunshop.build
    -- prints it, the way server/shop.lua's resolve() reports its rejects. A
    -- half-priced catalogue is a HALF-STOCKED SHOP rather than a crash, and the
    -- console says which gun and why.
    prices = {
        -- RARE -- his band is 100-150. Eleven weapons, five Volts apart.
        smgmk2         = 100,  -- damage 26
        assaultsmg     = 105,  -- damage 27
        combatpdw      = 110,  -- damage 28
        carbinerifle   = 115,  -- damage 32
        gusenberg      = 120,  -- damage 32
        assaultrifle   = 125,  -- damage 33
        advancedrifle  = 130,  -- damage 34
        mg             = 135,  -- damage 34
        heavypistol    = 140,  -- damage 40
        assaultshotgun = 145,  -- damage 72, one slow shell -- see the note above
        revolver       = 150,  -- damage 97, one slow shot -- see the note above

        -- EPIC -- his band is 200-275. Ten weapons, spread across it.
        carbinemk2     = 200,  -- damage 36
        assaultmk2     = 210,  -- damage 37
        specialcarbine = 215,  -- damage 38
        combatmg       = 225,  -- damage 38
        marksmanrifle  = 235,  -- damage 65
        combatshotgun  = 240,  -- damage 80
        heavyshotgun   = 250,  -- damage 88
        pumpshotgunmk2 = 260,  -- damage 92
        revolvermk2    = 265,  -- damage 99, one slow shot -- see the note above
        sniperrifle    = 275,  -- damage 101, one slow shot -- see the note above

        -- LEGENDARY -- his band is 400-500. Four weapons.
        combatmgmk2    = 400,  -- damage 40
        militaryrifle  = 435,  -- damage 42
        marksmanmk2    = 465,  -- damage 70
        heavysniper    = 500,  -- damage 216
    },

    -- ------------------------------------------------------------------
    -- PER-WEAPON ROW ICONS, OUT OF THE BASE GAME (#274 M4)
    -- ------------------------------------------------------------------
    --
    -- Owner, 2026-09-11: "As for the menu icons - how does the ScaleformUI demo
    -- menu draw them? Those gfx are built into the base game. We should use
    -- those."
    --
    -- HE WAS RIGHT AND THE PREVIOUS ANSWER WAS WRONG. That round shipped one
    -- generic badge per KIND and reported that per-weapon art would have to be
    -- drawn. The art has been in the game since launch.
    --
    -- ═══════════════════════════════════════════════════════════════════════
    -- WHAT IS ACTUALLY THERE, AND WHAT IS NOT
    -- ═══════════════════════════════════════════════════════════════════════
    --
    -- ⚠ THERE IS NO TEXTURE DICTIONARY NAMED AFTER A WEAPON. The shape everybody
    -- reaches for first -- RequestStreamedTextureDict('WEAPON_PISTOL') and a
    -- texture of the same name -- does not exist in any capitalization, and the
    -- pairs that turn up on the Cfx forum under that shape are RedM. `w_pi_pistol`
    -- IS a real name, but it is also a weapon MODEL name, which is how the
    -- confusion starts.
    --
    -- WHAT EXISTS IS THREE SHARED DICTIONARIES of small weapon icons, which are
    -- what Rockstar's own mp_weapons script loads to draw exactly this kind of
    -- list. Every txn below was read out of a texture dump of the shipped .ytd
    -- files rather than inferred from a pattern, and anything that was only
    -- attested by a decompiled script and could not be found in a dump was left
    -- out. That distinction is the whole point of this block: A WRONG TEXTURE
    -- NAME DRAWS NOTHING AND REPORTS NO ERROR, which is this project's worst
    -- failure shape, and a plausible name is indistinguishable from a real one
    -- until somebody is standing at a counter looking at a blank row.
    --
    -- ⚠ AND THE COVERAGE STOPS AT 2013. These dictionaries are the launch
    -- lineup. Rockstar's own hash-to-texture lookup returns an empty string for
    -- every weapon added after it, which is the game itself saying there is no
    -- icon -- so the thirteen guns listed in the `withNoArt` note below are not
    -- an oversight here, they are art that was never made.
    --
    -- ═══ THE MK2s WEAR THEIR BASE GUN'S ART, AND THAT IS A DECISION ═══
    --
    -- The texture is evidenced; the PAIRING is ours. An Assault Rifle MK2 is an
    -- Assault Rifle with furniture on it and reads as one at badge size, so four
    -- rows that would otherwise fall back to the generic badge get the right
    -- silhouette instead. It is the one place in this table where a line is a
    -- judgment rather than a lookup, and it is marked on each of them.
    weaponIcons = {
        -- ⚠ ONE SWITCH, BECAUSE NOBODY HAS SEEN THIS ON A SCREEN YET.
        --
        -- The names are evidenced. What is NOT evidenced, and cannot be without
        -- running the game, is how the menu movie's badge slot treats them: the
        -- slot is square-ish and this art is 2:1, so it may letterbox, crop or
        -- squash, and the item badge path has never been fed a base-game
        -- dictionary before. If it looks wrong, this is the line that turns all
        -- of it back into the badges that shipped last round, with no other edit
        -- and no restart of anything else.
        enabled = true,

        -- ═══ KEYED BY THE SHOP ROW'S id, WHICH IS config/weapons.lua's id ═══
        --
        -- Not by WEAPON_* and not by hash. A key that is not a real weapon id is
        -- as invisible as a wrong texture name -- the row simply falls back to
        -- the generic badge and says nothing -- so tools/test_gunshop.lua checks
        -- every key here against the catalogue the shop actually builds.
        art = {
            -- EXACT: the weapon's own icon, name read straight out of the dump.
            assaultsmg      = { txd = 'mpweaponscommon_small', txn = 'w_sb_assaultsmg' },
            assaultshotgun  = { txd = 'mpweaponscommon_small', txn = 'w_sg_assaultshotgun' },
            carbinerifle    = { txd = 'mpweaponsgang0_small',  txn = 'w_ar_carbinerifle' },
            combatmg        = { txd = 'mpweaponsgang0_small',  txn = 'w_mg_combatmg' },
            sniperrifle     = { txd = 'mpweaponsgang0_small',  txn = 'w_sr_sniperrifle' },
            heavysniper     = { txd = 'mpweaponsgang0_small',  txn = 'w_sr_heavysniper' },
            assaultrifle    = { txd = 'mpweaponsgang1_small',  txn = 'w_ar_assaultrifle' },
            mg              = { txd = 'mpweaponsgang1_small',  txn = 'w_mg_mg' },

            -- THE FOUR MK2s, WEARING THE BASE GUN'S ART. See the note above:
            -- the texture is evidenced, the pairing is our call.
            pumpshotgunmk2  = { txd = 'mpweaponscommon_small', txn = 'w_sg_pumpshotgun' },
            carbinemk2      = { txd = 'mpweaponsgang0_small',  txn = 'w_ar_carbinerifle' },
            combatmgmk2     = { txd = 'mpweaponsgang0_small',  txn = 'w_mg_combatmg' },
            assaultmk2      = { txd = 'mpweaponsgang1_small',  txn = 'w_ar_assaultrifle' },
        },

        -- ═══ THE THIRTEEN THAT KEEP THE GENERIC BADGE, AND WHY EACH ONE DOES
        --     ═══
        --
        -- ⚠ WRITTEN DOWN RATHER THAN LEFT AS AN ABSENCE, so the next person does
        -- not spend an afternoon re-deriving that the art is missing. This list
        -- is not read by anything; it is the working.
        --
        --   NO ART EXISTS ANYWHERE IN THE GAME. Post-2013 weapons. Rockstar's
        --   own lookup answers the empty string for every one of them, so there
        --   is nothing to point at and no amount of searching will find it:
        --     combatpdw, gusenberg, heavypistol, revolver, revolvermk2,
        --     specialcarbine, marksmanrifle, marksmanmk2, combatshotgun,
        --     heavyshotgun, militaryrifle
        --
        --   ART EXISTS BUT NOT AT THIS SIZE. `w_sb_smg` is in the full
        --   `mpweaponsgang0` and is absent from `mpweaponsgang0_small`. Reaching
        --   it means holding a dictionary of roughly eighty textures -- every
        --   attachment and every silhouette -- for one row:
        --     smgmk2
        --
        --   ⚠ A NAME THAT IS REAL AND MAY STILL DRAW NOTHING. The only
        --   `mpweaponsgang0_small` entry for it is `w_ar_addvancedrifle`, with
        --   the typo, and a secondary source reports that entry is a blank stub
        --   rather than the icon. A blank badge and a wrong name look identical
        --   from a chair, so it is not shipped on a report nobody could confirm:
        --     advancedrifle
    },

    -- ------------------------------------------------------------------
    -- AMMO: ALL FIVE POOLS
    -- ------------------------------------------------------------------
    --
    -- "ammo should be cheap (20-50 Volts)". All five of BR.Config.AmmoOrder are
    -- sold, because all five are found in the wild -- the floor loot table is
    -- 74% ammo by weight (config/loot.lua) and every pool is in it.
    --
    -- ═══ THE PRICE ORDER IS SCARCITY, AND THE TWO SCARCITY NUMBERS AGREE ═══
    --
    -- There are two independent measures of how freely a pool is meant to flow,
    -- and they were both authored years apart by different decisions:
    --
    --   the GROUND PICKUP    BR.Config.AmmoPickups[pool].amount -- how many
    --                        rounds one piece of ammo on the floor is worth.
    --   the INVENTORY CAP    BR.Config.AmmoCaps[pool] -- how much of it a player
    --                        may hold at once.
    --
    -- They put the five pools in EXACTLY THE SAME ORDER: smg, medium, light,
    -- shells, heavy, from most freely available to least. Two numbers that were
    -- not written to agree, agreeing, is a better axis than either one alone,
    -- so that is the order the prices run in.
    --
    -- THE GAPS ARE UNEVEN BECAUSE THE SCARCITY IS. Light, SMG and medium sit at
    -- caps of 300-400 and pickups of 36-60; shells and heavy sit at caps of 120
    -- and 60 and pickups of 16 and 12. That is a cliff, not a slope, and the
    -- price steps at the same place rather than pretending the five pools are
    -- evenly spaced.
    --
    -- ═══ THE BUNDLE SIZE IS THE OWNER'S CALL AND HE HAS NOT MADE IT ═══
    --
    -- ─────────────────────────────────────────────────────────────────────
    --  NEEDS HIS CONFIRMATION: HOW MUCH AMMO ONE PURCHASE BUYS.
    -- ─────────────────────────────────────────────────────────────────────
    --
    -- THE DEFAULT IS ONE GROUND PICKUP'S WORTH, and it is authored as a RULE
    -- rather than as five copied integers: `bundle` is nil on every row below,
    -- and BR.GunshopSolve reads BR.Config.AmmoPickups[pool].amount when it is.
    -- Writing the five numbers out here would be a second copy of a table that
    -- already exists, which is the defect the header of this file is about.
    --
    -- WHY THAT DEFAULT. It is the rule at the top of this file made literal: a
    -- purchase hands over EXACTLY the stack the player would have picked up off
    -- the floor, so the counter is a convenience and demonstrably nothing more.
    -- Any other number is a judgement about pacing that only the owner can make.
    --
    -- WHAT HE SHOULD JUDGE IT AGAINST -- both numbers are quoted per row below:
    -- the pickup amount is how much a single find is worth, and the cap is how
    -- many of these bundles it takes to fill the pool from empty. Heavy is the
    -- one to look at first: at 12 a bundle and a cap of 60, filling a Heavy
    -- Sniper from empty is five purchases and 250 Volts, which may well be more
    -- transactions than he wants at a counter in the middle of a match.
    --
    -- `bundle` IS THE PER-POOL OVERRIDE. An integer on any row below pins that
    -- pool and leaves the other four deriving. That is where his answer goes.
    --
    -- KEYED BY BR.AmmoType, NOT BY THE STRING, exactly as BR.Config.AmmoPickups
    -- and BR.Config.AmmoCaps are keyed. Five bare 'light'/'smg' literals here
    -- would be the pool vocabulary written down a second time, in a file that
    -- has no reason to know how it is spelled.
    ammo = {
        --  pool                       price      pickup   cap   bundles to fill
        [BR.AmmoType.SMG]    = { price = 20 },  --   60     400   6.7
        [BR.AmmoType.MEDIUM] = { price = 25 },  --   45     350   7.8
        [BR.AmmoType.LIGHT]  = { price = 30 },  --   36     300   8.3
        [BR.AmmoType.SHELLS] = { price = 40 },  --   16     120   7.5
        [BR.AmmoType.HEAVY]  = { price = 50 },  --   12      60   5.0
    },
}

--- BUILD THE CATALOGUE, AND SAY WHAT WAS THROWN OUT OF IT.
---
--- ═══ A FUNCTION, NOT A LOOP AT THE BOTTOM OF THIS FILE, AND THE REASON IS
---     LOAD ORDER ═══
---
--- br_lib's fxmanifest loads `config/*.lua` as a GLOB, and the order a glob is
--- expanded in is the platform's business rather than anything this file can
--- see. `gunshop` sorts BEFORE `weapons` alphabetically, so at this file's own
--- load BR.Config.Weapons may not exist yet -- and a catalogue derived from a
--- table that is not there is an EMPTY SHOP with no error anywhere.
---
--- config/shop.lua's `register` is a function for the mirror-image version of
--- the same hazard (it writes into a table config/loot.lua later reassigns).
--- Same shape, same reason: br_core's own gunshop files call this once at their
--- own resource start, by which time every br_lib script is up whatever order
--- they ran in.
---
--- IDEMPOTENT, so two callers cost one build and ONE set of console lines. The
--- client and the server both need the catalogue and neither should have to
--- know whether the other went first.
---
--- @return table rows     the usable catalogue, in BR.Config.Weapons order,
---                        ammo last
--- @return table rejects  { { id, why } } -- rows that are not for sale
function BR.Config.Gunshop.build()
    local G = BR.Config.Gunshop
    if G.rows then return G.rows, G.rejects end

    local rows, rejects = BR.GunshopSolve.catalogue(G, {
        weapons     = BR.Config.Weapons,
        -- THE EXCLUSION, PASSED AS THE REAL TABLE. Deriving from
        -- BR.Config.Weapons already excludes the airdrop shelf, because that is
        -- the array it is deliberately absent from -- this is the belt to that
        -- braces, and it costs nothing because it is the SAME table the airdrop
        -- reads rather than a list of four names retyped here.
        airdropOnly = BR.Config.AirdropWeapons,
        ammoOrder   = BR.Config.AmmoOrder,
        ammoPickups = BR.Config.AmmoPickups,
    })

    -- SAID OUT LOUD, ALWAYS. server/shop.lua's resolve() sets the precedent and
    -- the argument is the same: a row that was silently dropped is a gun the
    -- owner priced, cannot see on the shelf, and has no way to ask about.
    for i = 1, #rejects do
        print(('^3[br_lib] gunshop: "%s" is not for sale -- %s^7')
            :format(tostring(rejects[i].id), tostring(rejects[i].why)))
    end

    if #rows == 0 then
        print('[br_lib] gunshop: no catalogue -- the gun shops are inert')
    end

    G.rows, G.rejects = rows, rejects
    return rows, rejects
end
