-- Aerial supply drops (#88).
--
-- MUST LOAD AFTER config/loot.lua AND config/weapons.lua. It reads their rarity
-- buckets and their id lookups to build its own pools.
--
-- ------------------------------------------------------------------------
-- THERE IS NO AIRDROP NATIVE. Researched before a line was written, because
-- the alternative was writing code that fights the engine (owner, 2026-08-21:
-- "the game should have natives for airdrops already, which spawn falling
-- from a parachute").
--
-- It does not. The `OBJECT` native namespace has nothing matching parachute,
-- cargo, crate, drop, supply or paradrop; the only parachute natives are ped
-- TASK natives. GTA Online's own crate drop (`am_crate_drop`) and ammo drop
-- (`am_ammo_drop`) are hand-rolled script: create the crate object, create a
-- SEPARATE chute prop, ATTACH_ENTITY_TO_ENTITY at (0, 0, 0.1), play the chute
-- deploy anim, ACTIVATE_PHYSICS, SET_ENTITY_VELOCITY (0, 0, -0.2) and
-- SET_DAMPING for the terminal-velocity feel.
--
-- WHAT WE TAKE FROM ROCKSTAR: the chute PROP and its anim. `p_cargo_chute_s`
-- is the purpose-built cargo canopy with its own dict/anim pair. It is NOT
-- BR.Config.Drop.parachuteModel (`p_parachute1_mp_s`) -- that is the player's
-- back-worn canopy, a different asset in a different category.
--
-- WHAT WE DELIBERATELY DO NOT TAKE: the physics. Every public FiveM airdrop
-- either networks the crate (which `sv_entityLockdown relaxed` refuses, and
-- which the Cfx.re issue tracker records as sporadically failing to sync at
-- all) or lets each client run its own physics simulation and then disagree
-- about where the crate landed. Our descent is a PURE FUNCTION of a record
-- the server published once plus the synced clock -- the same bet the storm
-- and the bus route already make. Nothing per-frame crosses the wire, every
-- client's crate is at the same place at the same millisecond because there
-- is no property for two machines to disagree about, and the object stays
-- `isNetwork = false` like everything else this gamemode creates.
-- ------------------------------------------------------------------------

BR = BR or {}
BR.Config = BR.Config or {}

local R = BR.Rarity

-- ---------------------------------------------------------------------------
-- EXCLUSIVE MEANS EXCLUSIVE
-- ---------------------------------------------------------------------------
--
-- Owner, 2026-08-21: "The air drops should have exclusive loot which is not
-- found anywhere else, and a LOT of it (up to 12 items)", and then, on what
-- that loot should be: "Things like explosives, RPGs, miniguns, etc are
-- exciting."
--
-- THE MECHANISM IS THE FISTS PATTERN (config/weapons.lua). A weapon is
-- resolvable everywhere -- the allowlist, the validator, the inventory, the
-- ground prop, the label -- through BR.Config.WeaponById, while being absent
-- from every rarity BUCKET, which is the only thing BR.RollLootStack ever rolls
-- against. Registered but never rolled. That is what "found nowhere else" means
-- mechanically, and it costs the world layout nothing: the buckets are built
-- from BR.Config.Weapons alone, so a fixed seed still produces a byte-identical
-- map. tools/test_airdrop.lua pins that by generating a whole layout and
-- looking, rather than by trusting this paragraph.
--
-- THE HEAVY SHIELD USED TO BE HERE AND IS GONE (owner, 2026-08-21: "We don't
-- need heavy shield to exist. That's not exciting."). Removed outright -- the
-- item, its registration and the test that pinned it -- rather than left
-- disabled, because a consumable that exists and is in no pool is indisting-
-- uishable from a bug for whoever reads this next.
--
-- `cprkit` IS STILL NAMED, IN THE HEALING POOL, AND IS STILL #191's SEAM. The
-- resolver below drops ids that do not resolve, so naming it costs nothing
-- today and costs no edit to this file on the day it exists.

BR.Config.Airdrop = {
    enabled = true,

    -- EXACTLY ONE PER MATCH, NO MORE AND NO LESS (owner, 2026-08-21), and both
    -- halves of that sentence are a number here rather than a hardcoded truth.
    --
    -- `perMatch` is how many are SCHEDULED. `chance` is rolled once per
    -- scheduled drop, so a value below 1.0 is a probability that the match gets
    -- one at all -- which the owner asked for explicitly. At 1.0 the roll
    -- always passes and the match always gets exactly `perMatch`, subject to
    -- the siting rule below.
    --
    -- ═══ IT CAPS THE AUTOMATIC PATH ONLY (owner, 2026-08-23) ═══
    --
    -- "`brairdrop now` should be allowed multiple times per match as it's a
    -- manual command and should override our match limit."
    --
    -- This number is read in exactly one place -- BR.Airdrop.begin, which fills
    -- `pending` with it -- and the scheduler sites out of `pending` and nowhere
    -- else, so the automatic cap is structural. The console verbs (`now` and
    -- `<poiId>`) manufacture their own entries and are deliberately not counted
    -- against it. DO NOT RAISE THIS NUMBER TO GET MORE MANUAL DROPS: every one
    -- added here is one more drop every match gets on its own.
    perMatch = 1,
    chance   = 1.0,

    -- WHEN. Measured from the moment the match goes PLAYING, drawn uniformly.
    -- Early enough that the fight over it is a mid-game event rather than an
    -- endgame coin flip, late enough that everyone has landed and armed up.
    minDelayMs = 210000,   -- 3m30
    maxDelayMs = 420000,   -- 7m00

    -- HOW OFTEN THE SITING RULE IS RE-ASKED once the drop is due. See
    -- BR.AirdropSite: a circle mid-shrink is a different question five seconds
    -- later, so a re-check is progress rather than a spin.
    retryEveryMs = 5000,

    -- THE DESCENT. Linear, because a canopy descends at terminal velocity, and
    -- half a minute long because that is how long the map gets to converge on
    -- the blip.
    --
    -- `altitude` is metres ABOVE THE GROUND, never an absolute z, and that
    -- distinction is the same one BR.Loot's `flift` makes: only a client can
    -- ground-probe, so an absolute z from the server is a guess. Each client
    -- resolves the ground under (x, y) itself and falls to it.
    --
    -- ═══ 260 CAME DOWN TO 170, AND WHAT THAT COSTS IS THE DESCENT RATE ═══
    --
    -- Owner, 2026-08-22: "The cargobob seemed to be too high off the ground when
    -- it came in. I could barely hear it."
    --
    -- THE AIRCRAFT'S HEIGHT IS THIS NUMBER PLUS `planeAltAbove`, and almost all
    -- of it is this one -- the crate leaves the Cargobob, so the Cargobob is
    -- wherever the crate starts. It was flying at 300m (260 + 40) and it is
    -- flying at 195m (170 + 25) now, a third lower.
    --
    -- ─── THE FALL TIME IS UNCHANGED, WHICH IS THE HALF THAT WAS CONFIRMED ───
    --
    -- BR.AirdropHeightAt is `alt * (1 - progress)` and progress is measured
    -- against `descentMs`, so the descent takes thirty seconds at ANY altitude.
    -- The owner confirmed the arrival was right ("the airdrop arrived
    -- perfectly") and thirty seconds is what they were confirming; it is
    -- deliberately untouched.
    --
    -- WHAT MOVED IS THE RATE: 260m/30s was 8.7 m/s and 170m/30s is 5.7 m/s. A
    -- real cargo canopy comes down at roughly 5-7 m/s, so this is if anything
    -- the more honest number -- but it IS a change, the crate will read as
    -- floating a little more than it did, and that is the trade being made. If
    -- the owner wants the old rate back at the new height, `descentMs` goes to
    -- 20000 and the map loses ten seconds of converging on the blip; those two
    -- cannot both be held.
    --
    -- ─── AND LOWER IS NOT FREE OVER TERRAIN ───
    --
    -- `planeAltAbove` is measured from the ground at the DROP POINT, not from
    -- the ground under the aircraft, and the run-in is planeSpeed * planeLeadMs
    -- = about 540m long since the 2026-08-23 halving (it was 1080m). A ridge
    -- more than ~195m above the drop point within that half-kilometre is
    -- something the Cargobob flies through rather than over. It has collision
    -- off (client/airdrop.lua), so that is a cosmetic clip and never a crash --
    -- but it was not reachable at 300m and it is now. The shorter run-in halves
    -- the stretch of map this can happen over; see `planeSpeed`.
    descentMs = 30000,
    altitude  = 170.0,

    -- ------------------------------------------------------------------
    -- ...AND A CRATE THAT HIGH HAS TO BE ASKED TO DRAW AT ALL
    -- ------------------------------------------------------------------
    --
    -- Owner, 2026-08-23: "we need to fix the delay between when the cargobob
    -- flies over and when the cargo drops. It seems that the loose flares drop
    -- before the cargo - they should all be at once. The flares start dropping
    -- at the perfect time for the cargo to drop."
    --
    -- ═══ THERE IS NO DELAY IN THE ARITHMETIC, AND THE FLARES ARE THE PROOF ═══
    --
    -- The crate and the flares are not two timings that could drift apart. They
    -- are ONE function: client/airdrop.lua's place() writes the crate's
    -- coordinates and then hands client/flares.lua the two positions beside it,
    -- and place() is only ever called on a frame where the crate object already
    -- exists. A flare at the right moment therefore PROVES a crate at the right
    -- moment -- there is no path that lights one without the other.
    --
    -- SO WHAT THE OWNER SAW WAS NOT A LATE CRATE. It was a crate that existed,
    -- in the right place, on the right frame, and was not being DRAWN. It comes
    -- into being 170m up; every part of a drop that IS visible from there is
    -- visible for a reason of its own -- a projectile flare carries the engine's
    -- own light and corona, and a Cargobob is a vehicle. A wooden box is a small
    -- prop with a small authored LOD distance, and it pops in when it has fallen
    -- far enough to be worth drawing, which is most of the way down.
    --
    -- AND `planeSpeed` IS NOT THE CAUSE, which was worth ruling out before
    -- anything moved: the run-in lasts `planeLeadMs` at ANY speed (the aircraft
    -- is switched on at tArm and the release is planeLeadMs later), and
    -- BR.AirdropPlaneAt puts it exactly over the drop point at tRelease. Halving
    -- it on 2026-08-23 moved where the approach starts, never when it ends.
    --
    -- ═══ SET_ENTITY_LOD_DIST IS THE ONE LEVER, AND IT IS A uint16 ═══
    --
    -- (0x5927F96A78577363.) citizenfx/natives records the range as "0 to 0xFFFF
    -- (higher values will result in 0xFFFF) as it is actually stored as a 16-bit
    -- value". 1000 is well inside that and comfortably past the 195m the highest
    -- part of a drop is ever seen from -- generous rather than tuned, because
    -- there is exactly one crate and one canopy per match and for thirty
    -- seconds.
    --
    -- IT IS APPLIED TO THE PLANE TOO, at the same value and for the same
    -- sentence: the run-in begins 540m out and the aircraft the owner is meant
    -- to look up at is the whole point of having one.
    --
    -- WHAT NOBODY CAN TELL YOU FROM HERE is whether the box was invisible for
    -- this reason or for another one -- nothing outside a running client can
    -- read a prop's LOD distance back. What can be said is that this is the only
    -- native that governs it, that the call is free, and that /brairdrop now
    -- prints the value each part was built with.
    propLodDist = 1000,

    -- ------------------------------------------------------------------
    -- THE PLANE
    -- ------------------------------------------------------------------
    --
    -- The owner said no plane, then changed their mind (2026-08-21). It is
    -- hand-rolled, because there is no native for any of this -- and the thing
    -- it is modelled on is already in this repo: client/bus.lua's ghost flights
    -- (795-853) fly a LOCAL, non-networked Titan along a server-published timed
    -- route by direct coordinate writes against the synced clock, for warmup
    -- bystanders. That is an airdrop flyover with a different model and route.
    --
    -- NOTHING WAS TAKEN FROM kq_airdrop, the paid resource in the owner's
    -- project folder. Its plane and drop logic is Cfx.re escrow-ENCRYPTED (FXAP
    -- header), so there is no source to read; it is a commercial product with no
    -- licence permitting reuse; and its one readable spawn call is
    -- `CreateObject(model, coords, 1, 0, 0)` -- isNetwork = true, which
    -- `sv_entityLockdown relaxed` refuses outright. There was nothing to take
    -- and it would not have worked.
    --
    -- ═══ THE RELEASE IS NOT THE ANNOUNCEMENT, AND THAT IS WHAT THE PLANE
    --     BOUGHT ═══
    --
    -- Before the plane, the crate began falling at `tStart` -- the moment the
    -- server committed the drop and sent the record. Clients receive that record
    -- AFTER tStart, so there is no window in which a plane could be seen flying
    -- IN: by the time anyone knew, it would already be leaving.
    --
    -- So the record now carries a third timestamp. `tStart` is when the drop is
    -- announced and the blip goes up; `tRelease` is `planeLeadMs` later, when
    -- the plane is overhead and the crate leaves it; `tLand` is `descentMs`
    -- after that. Everyone gets the notification, looks up, and watches it
    -- arrive -- which is the entire point of having a plane rather than a crate
    -- that appears in the sky.
    --
    -- IT COSTS THE MATCH `planeLeadMs` OF EXTRA WARNING and nothing else. The
    -- siting rule is solved against the circle at tLand, so the margin is still
    -- honoured at the moment the crate actually arrives.
    planeLeadMs = 12000,

    -- The flyover is on the same bet as everything else here: a pure function of
    -- the record and the clock, so every client's plane is in the same place at
    -- the same millisecond with nothing on the wire. It flies a STRAIGHT LINE
    -- along `rec.heading` -- the same heading the crate rests at, which makes
    -- the box land pointing the way the plane was going -- and is over the drop
    -- point exactly at tRelease.
    --
    -- ═══ A CARGOBOB, BECAUSE THE OWNER WANTED TO HEAR A HELICOPTER ═══
    --
    -- "instead of a faked prop that moves (our bus/plane) we should spawn the
    -- cargobob in motion, give it a pilot, then have the pilot fly it across the
    -- finish line. This will give players the actual sound of a helicopter
    -- running rather than a prop that slides across the sky" -- 2026-08-22.
    --
    -- THE MODEL IS THE HALF OF THAT REQUEST WORTH TAKING, AND IT IS THIS LINE.
    -- The Titan is a fixed-wing turboprop: there is no helicopter sound in it at
    -- any audio setting, under any flight method, so the sound they asked for
    -- was never reachable by changing how it flies. A Cargobob is also ~34%
    -- slower (99.5 vs 133.3 mph), which serves a drop meant to be watched.
    --
    -- THE OTHER HALF -- AN AI PILOT FLYING IT -- WAS DECLINED, and the reasoning
    -- is worth keeping because it will be proposed again. TaskHeliMission is
    -- widely reported not to arrive reliably, and both open-source airdrop
    -- resources re-issue it in a loop rather than trust it, which is itself the
    -- evidence. It would trade the one property this whole design rests on --
    -- every client solving the same descent from the record and the synced
    -- clock -- for an audio improvement nobody could confirm exists.
    --
    -- AND THE PREMISE IS STILL UNVERIFIED. Two research sweeps found NO report
    -- that teleporting a vehicle degrades its engine audio. If it does sound
    -- wrong, the documented cause is audio LOD -- SET_AUDIO_VEHICLE_PRIORITY's
    -- own text says the game drops a vehicle by distance, view frustum "and what
    -- it is currently doing" -- and a cheap experiment settles it: park it with
    -- the engine on, not teleporting, and stand under it. Sounding right
    -- stationary means the complaint is kinematic (no banking, no doppler) and
    -- no audio native fixes that.
    planeModel = 'cargobob',
    planePilot = 's_m_m_pilot_01',

    -- ═══ HALVED, 2026-08-23, AND IT IS THE HONEST NUMBER RATHER THAN A TASTE
    --     SETTING ═══
    --
    -- Owner, after the playtest: cut the Cargobob's speed by 50%.
    --
    -- 90 m/s is 201 mph. The note above records that a Cargobob does 99.5 mph,
    -- which is the reason the model was chosen over the Titan -- so the aircraft
    -- was flying at TWICE its own top speed and reading as a jet with rotors.
    -- 45 m/s is 100.7 mph: the Cargobob's actual maximum, and the first value
    -- here that the airframe could really hold.
    --
    -- ─── WHAT THIS DOES NOT CHANGE: THE LENGTH OF THE APPROACH ───
    --
    -- The run-in lasts `planeLeadMs` -- twelve seconds -- WHATEVER THIS NUMBER
    -- IS. BR.AirdropPlaneVisible turns the aircraft on at tArm and the release
    -- is planeLeadMs later; speed decides where it starts, not when. So
    -- `planeLeadMs` is deliberately NOT compensated: doubling it to hold the old
    -- run-in distance would add twelve seconds between the arm and the release,
    -- delaying a crate whose arrival the owner has already confirmed as right
    -- ("the airdrop arrived perfectly"), and buying nothing anybody can see.
    --
    -- ─── WHAT IT DOES CHANGE: WHERE THE RUN-IN BEGINS ───
    --
    -- planeSpeed * planeLeadMs was 1080m and is 540m. That is FURTHER INSIDE
    -- normal vehicle draw distance rather than outside it, so if anything the
    -- aircraft is visible for more of its approach than it was; and the terrain
    -- clip the `altitude` note warns about now has half the corridor to go
    -- wrong in. Both moves are in the right direction, which is why nothing else
    -- here is adjusted to compensate.
    --
    -- Metres a second.
    planeSpeed = 45.0,
    -- Metres ABOVE THE CRATE's release altitude, never an absolute z. Same rule
    -- as `altitude` above and for the same reason: only a client can ground-probe.
    --
    -- 40 CAME DOWN TO 25 (owner, 2026-08-22: "too high off the ground when it
    -- came in"). This is the CHEAP half of that fix and it costs nothing at all
    -- -- the crate's release height, the fall time and the fall rate are all
    -- `altitude`'s business, and this number only decides how far above the box
    -- the aircraft that dropped it is flying. It is also the SMALL half: 15m of
    -- the 105m the aircraft came down. See `altitude` for the other 90 and for
    -- what that one traded.
    planeAltAbove = 25.0,
    -- How long it stays in the world after the release. Long enough to watch it
    -- go, short enough that it is gone before the fight over the crate starts.
    planeTrailMs = 15000,

    -- ------------------------------------------------------------------
    -- AND IT HAS TO CLEAR WHAT IS BETWEEN IT AND THE DROP
    -- ------------------------------------------------------------------
    --
    -- Owner, 2026-08-23: "We also need a way to make sure the cargobob avoids
    -- terrain, because drops at chili[ad]".
    --
    -- ═══ THE `altitude` NOTE ABOVE PREDICTED THIS AND DID NOTHING ABOUT IT ═══
    --
    -- "A ridge more than ~195m above the drop point within that half-kilometre
    -- is something the Cargobob flies through rather than over." It is worse
    -- than a ridge: `chiliad_e` is authored at z 160 and the `chiliad` summit
    -- POI at 780, so a run-in laid across the massif puts the aircraft six
    -- hundred metres inside it.
    --
    -- WHAT CHANGES IS THE HEIGHT AND NOTHING ELSE. The route is still a straight
    -- line at constant speed passing over the drop point at tRelease -- the
    -- property the whole file rests on. The aircraft now flies at whichever is
    -- higher: its nominal altitude, or `planeTerrainClearance` above the highest
    -- ground still AHEAD of it. See BR.AirdropApproach and BR.AirdropPlaneZ.
    --
    -- AND IT COSTS THE RELEASE NOTHING, which is the half worth checking rather
    -- than trusting: the corridor is measured forward from the aircraft and
    -- clipped at tRelease, so it collapses onto the drop point as the release
    -- arrives and the floor drops back under the nominal height. The crate still
    -- leaves exactly `planeAltAbove` beneath the aircraft.
    --
    -- 60m OVER THE HIGHEST GROUND AHEAD. A Cargobob is about 20m long and the
    -- probe answers bare ground, not the pylon, mast or pine standing on it, so
    -- this is three airframes of margin and not a tight fit. It is deliberately
    -- WELL under `altitude` + `planeAltAbove` (195m): a clearance above that
    -- would raise the aircraft over flat ground too, and the drop point's own
    -- ground is always in the corridor.
    planeTerrainClearance = 60.0,
    -- How far ahead the corridor looks, in MILLISECONDS OF FLIGHT rather than
    -- metres -- so it is a fixed slice of the run-in whatever `planeSpeed` is,
    -- exactly as `planeLeadMs` is. 6s of the 12s run-in, which is 270m at the
    -- current speed.
    --
    -- LONGER IS NOT BETTER. GetGroundZFor_3dCoord is documented to fail beyond
    -- render distance and the far end of the corridor is already the far end of
    -- what a client near the drop can answer for; samples that fail are skipped,
    -- so a longer horizon buys mostly nothing and costs probes.
    planeLookAheadMs      = 6000,
    -- Points along it, ends included. Eight over 270m is a sample every ~39m --
    -- finer than the aircraft's own length, which is the resolution that
    -- matters, since anything narrower than the airframe it can fly through
    -- without touching.
    planeProbeSamples     = 8,
    -- How often the corridor is re-probed. The ground probe is slow enough that
    -- config/storm.lua caches it at 1Hz for the wall; 4Hz over 8 points for at
    -- most 27 seconds once a match is the cheapest version of this that still
    -- reads as flying rather than stepping.
    planeProbeMs          = 250,
    -- ...and how long a corridor that stops answering keeps its last verdict.
    -- FAIL-OPEN, BUT NOT INSTANTLY: a probe that blinks out for one pass must
    -- not drop the aircraft into the ridge it just measured, and a probe that
    -- has been silent for two seconds is not describing anything any more.
    planeProbeHoldMs      = 2000,
    -- WHERE THE PROBE STARTS ITS SEARCH DOWNWARD, as an ABSOLUTE z, and it is
    -- the one number here that cannot be derived from the drop.
    -- GetGroundZFor_3dCoord returns the highest ground BELOW the point it is
    -- given, so probing from the aircraft's own altitude would find nothing at
    -- all over a summit that stands above it -- the exact case this feature
    -- exists for. 1200 clears Mount Chiliad (~1100m), which is the highest
    -- ground on this map.
    planeProbeFromZ       = 1200.0,

    -- ------------------------------------------------------------------
    -- AND THE OTHER CURE FOR "I COULD BARELY HEAR IT"
    -- ------------------------------------------------------------------
    --
    -- AUDIO LOD IS THE DOCUMENTED REASON A DISTANT AIRCRAFT IS QUIET, and the
    -- note above already said so without acting on it.
    -- SET_AUDIO_VEHICLE_PRIORITY (0xE5564483E407F914) is a hint to the audio
    -- system about what LOD a vehicle should use; its own documentation says
    -- HIGH "will bump up the activation range significantly" and stops the LOD
    -- dropping when the vehicle is outside the view frustum, and that MAX
    -- "attempts to maintain full audio detail regardless of how far it is from
    -- the listener".
    --
    -- ═══ MAX IS 2 AND HIGH IS 3. THE ENUM IS NOT IN ASCENDING ORDER. ═══
    --
    --   AUDIO_VEHICLE_PRIORITY_NORMAL = 0
    --   AUDIO_VEHICLE_PRIORITY_MEDIUM = 1
    --   AUDIO_VEHICLE_PRIORITY_MAX    = 2   <-- "regardless of distance"
    --   AUDIO_VEHICLE_PRIORITY_HIGH   = 3
    --
    -- Read off citizenfx/natives (AUDIO/SetAudioVehiclePriority.md), the file
    -- docs.fivem.net renders, and checked twice BECAUSE it is backwards: a 3
    -- shipped in the belief it was the maximum is a HIGH, which is weaker and
    -- would look exactly like the native doing nothing.
    --
    -- ─── WHAT IT COSTS, WHICH IS NOT NOTHING ───
    --
    -- The same documentation records a hard limit of FIVE simultaneous granular
    -- vehicles including the player's, and says that spending them on max
    -- priority leaves fewer engines for ordinary traffic. We spend exactly one,
    -- for at most `planeTrailMs` past the release, once per match. That is the
    -- cheapest possible version of this bet.
    --
    -- ─── AND ESSENTIALLY NOBODY USES IT, WHICH CUTS BOTH WAYS ───
    --
    -- The Cfx.re forum has no thread mentioning this native under either name --
    -- no working examples and no bug reports. So there is no evidence it fails,
    -- and none that it works, and NOTHING documents whether it is sticky or
    -- needs re-asserting. client/airdrop.lua sets it once on the handle it just
    -- created, which is the only moment it certainly has one.
    --
    -- Set to nil to stop asking for it at all.
    planeAudioPriority = 2,

    -- ------------------------------------------------------------------
    -- THE DROP WAITS UNTIL SOMEBODY CAN SEE IT
    -- ------------------------------------------------------------------
    --
    -- Owner, 2026-08-22: "The plane radius should instead be measured by the
    -- distance between the drop (at ground level) and the closest player.
    -- Ideally the drop should never happen until a player is within 200m of the
    -- drop location. That way they get to see the drop happen".
    --
    -- ═══ THIS REPLACED A CLIENT-SIDE PRESENTATION RADIUS, AND IT IS NOT ONE ═══
    --
    -- The first answer to "the plane flies to an empty sky" was a 1000m radius
    -- each CLIENT applied to itself: the drop happened on the server's clock
    -- whether anybody watched, and a distant client simply did not build a Titan
    -- it could not see. That is gone, and so is the sentence that justified it.
    -- This is a gate on the DROP, decided once, on the server, from the roster's
    -- own sampled positions -- so a drop nobody is near does not happen at all
    -- rather than happening unseen.
    --
    -- MEASURED GROUND-LEVEL TO GROUND-LEVEL. From the landing point's (x, y) to
    -- the player's (x, y), never from the plane and never from the release
    -- altitude -- a crate 260m up is 260m away from somebody standing directly
    -- underneath it, and gating on that would be gating on the altitude rather
    -- than on the walk.
    --
    -- ═══ AND THE ANNOUNCEMENT NOW COMES FIRST, WHICH IS THE WHOLE OF WHY THIS
    --     WORKS ═══
    --
    -- A gate on "is somebody near the drop" is circular unless they have been
    -- told where the drop is: nobody would ever be within 200m except by
    -- accident, and the match would essentially never get an airdrop. So the
    -- drop is SITED and ANNOUNCED at schedule time -- the blip goes up and the
    -- notification goes out, naming a place -- and only the DESCENT waits. See
    -- br_core/server/airdrop.lua, which is two phases now rather than one.
    --
    -- ═══ AND IF NOBODY COMES, THE MATCH GETS NO AIRDROP ═══
    --
    -- Owner, 2026-08-22: "Correct - if nobody goes to the area where the drop is
    -- ready to happen within the allotted time, then no drop should happen."
    --
    -- "The allotted time" is the blip's own ceiling (`blipMaxMs` below), and the
    -- two share ONE clock deliberately: BR.AirdropExpired is the single
    -- question, so the blip going out and the drop being abandoned are the same
    -- instant rather than two timers that can disagree. The drop is counted as
    -- SPENT rather than retried -- the match has already been told one is
    -- coming, and a second announcement naming a second place would read as two
    -- airdrops when the owner asked for exactly one.
    --
    -- ═══ THE 250m MARGIN IS RE-CHECKED WHEN THE WAIT ENDS, AND THIS BLOCK USED
    --     TO ARGUE THAT IT SHOULD NOT BE ═══
    --
    -- What stood here, until 2026-08-23: the margin is solved once at siting
    -- against the earliest landing; a wait of minutes lets the circle shrink
    -- under it; re-checking would abandon a drop for a player who did exactly
    -- what this feature asked of them; and anyway it is SELF-CORRECTING, because
    -- a point outside the circle is a point nobody is near, so the gate never
    -- opens.
    --
    -- THE LAST CLAUSE IS THE ONE THAT WAS WRONG, and the owner found it:
    -- "aidrops aren't spawning within the circle at all times." The drop is
    -- ANNOUNCED at siting -- that is this whole feature's first half -- so a
    -- blip is standing over the point telling the match to run at it. They do.
    -- They arm it. The crate lands where the storm no longer is. The gate does
    -- not fail to open on a bad point; it is the thing that delivers somebody to
    -- one.
    --
    -- SO BOTH ENDS MOVED. Siting now solves the margin against every circle the
    -- drop could land under, out to this gate's own deadline (`blipMaxMs`), and
    -- against the circle the storm is shrinking toward -- which is the owner's
    -- own suggestion, "they should only spawn within the next circle", made
    -- exact. And the arm re-asks it against the landing time that has just
    -- become known. See BR.AirdropLandingCircles.
    --
    -- WHAT THAT COSTS IS THE CASE THE OLD TEXT WAS PROTECTING: a storm that
    -- turns over a whole phase while somebody walks can still leave the point
    -- outside, and that drop is now abandoned rather than delivered. It is the
    -- rarer of the two evils and it is the one this file already chose
    -- everywhere else -- "the drop has to be a fight, not a sprint into the
    -- wall". A crate that lands outside the circle is not a consolation prize
    -- for the player who ran to it; it is a death sentence for whoever contests
    -- it, which is the sentence `insideBy` exists to write.
    --
    -- 200m IS THE OWNER'S NUMBER. /brairdrop prints the CLOSEST APPROACH any
    -- player actually made, which is how this gets retuned from a playtest
    -- rather than from a guess.
    armWithin = 200.0,

    -- ------------------------------------------------------------------
    -- WHERE IT LANDS, AND THE TWO RULES THAT CAN CONTRADICT EACH OTHER
    -- ------------------------------------------------------------------
    --
    -- Owner, 2026-08-21: "Airdrops should use standard POIs as coords" and "it
    -- should only happen at a point which is going to be within the circle by a
    -- minimum of 250m".
    --
    -- Those two can have no answer at the same time, and often will: POIs are
    -- fixed and there are 107 of them, while a late circle is small and moves.
    -- Phase 4's target radius is 520m, so a 250m margin leaves a disc of radius
    -- 270m for a POI to sit in -- at this map's POI density that is empty more
    -- often than not.
    --
    -- THE DECISION: NEITHER RULE BENDS, AND A MATCH MAY GET NO AIRDROP.
    --
    -- The margin is a SAFETY property -- the drop has to be a fight, not a
    -- sprint into the wall -- and the POI rule is a PLACEMENT property. Picking
    -- "the nearest POI" would put the most valuable loot on the map outside the
    -- circle, or on its rim, which is worse than no drop at all: it converts
    -- the highest-value objective in the match into a death sentence for
    -- whoever contests it. Silently relaxing 250m to whatever happens to fit
    -- would be the same failure wearing a smaller number.
    --
    -- So when nothing qualifies the drop WAITS (retryEveryMs) and re-asks,
    -- because the circle is usually mid-shrink and the answer changes. If the
    -- phase cap below passes with nothing ever qualifying, this match gets no
    -- airdrop and the server log says exactly why. That is a deliberate
    -- zero, not a silent failure.
    --
    -- In practice the default delay lands during phase 1 or 2, where the radius
    -- is 2600m or more and dozens of POIs qualify, so the zero should be rare.
    --
    -- ═══ AND IT IS MEASURED AGAINST MORE THAN ONE CIRCLE NOW (2026-08-23) ═══
    --
    -- The number did not move; what it is asked OF did. A landing point has to
    -- clear this margin against every circle the drop could land under -- see
    -- `armWithin` above and BR.AirdropLandingCircles. Raising or lowering this
    -- one number still tunes all of them together, which is why it is still one
    -- number.
    insideBy = 250.0,

    -- NO AIRDROPS PAST STORM STAGE 4 (owner). Read against the published
    -- record's phase at the moment the drop is committed.
    --
    -- ═══ "SPAWN BEFORE THE BEGINNING OF PHASE 3?" -- ASKED, AND ANSWERED NO
    --     (owner, 2026-08-23) ═══
    --
    -- It was the second half of their proposal for drops landing outside the
    -- circle, and it treats the symptom rather than the cause. The cause was
    -- that the margin was solved once and never re-asked while the drop waited
    -- (see `armWithin`); a phase cap does not touch that -- a drop sited in
    -- phase 2 can still sit for four minutes and land in phase 4.
    --
    -- AND IT WOULD COST MOST MATCHES THEIR AIRDROP. The schedule draws
    -- uniformly from 3m30 to 7m00 after PLAYING, and phase 3 begins somewhere
    -- around 280-660 seconds in (config/storm.lua: phase 1 holds 120-180s and
    -- sweeps 40-240s, phase 2 holds 120s and sweeps up to 120s). A cap at "before
    -- phase 3" would refuse a large slice of that window outright.
    --
    -- LATE PHASES ARE ALREADY SELF-LIMITING, which is the reason none of that is
    -- needed. Phase 4's target radius is 520m and the margin is 250m, so a
    -- qualifying POI has to sit in a 270m disc; at this map's density that is
    -- usually empty, the drop waits, and the match gets its deliberate zero. The
    -- cap stays at the owner's own earlier number.
    maxPhase = 4,

    -- ------------------------------------------------------------------
    -- WHAT IS IN IT
    -- ------------------------------------------------------------------
    --
    -- TEN TO FOURTEEN, DRAWN PER DROP (owner, 2026-08-22: "instead of 'up to
    -- 12' items, let's make it 10-14 items in these airdrops. That should be
    -- enough for an entire squad."). It was a fixed twelve before.
    --
    -- ═══ THE ARRAY IS A PRIORITY ORDER NOW, NOT A MANIFEST ═══
    --
    -- `payout` lists FOURTEEN slots and a drop deals the first `n` of them,
    -- where n is drawn uniformly from [minItems, maxItems] out of the AIRDROP's
    -- own rng (docs/match-math.md section 1: every subsystem has a prime of its
    -- own so its draws cannot shift another's -- taking this one from the loot
    -- stream would move every downstream loot draw on the map).
    --
    -- SO THE ORDER IS LOAD-BEARING AND IT IS NOT DECORATIVE. Slots 1-10 are
    -- what EVERY drop is guaranteed to contain, so the floor has to be a
    -- complete kit on its own: both exclusives, the Volts, two legendaries, an
    -- epic, a throwable, a heal and BOTH ammo slots. Ammo is deliberately
    -- inside the guaranteed ten rather than at the tail -- a minimum roll that
    -- paid an RPG and no heavy rounds would be the worst drop in the game
    -- wearing the best loot table.
    --
    -- SLOTS 11-14 ARE THE TAIL, and the first two of them restore the third
    -- legendary and the second epic -- so an n of 12 deals EXACTLY the twelve
    -- items this shipped with on 2026-08-21. The change adds a spread around
    -- what the owner already playtested rather than a different drop.
    --
    -- `maxItems` may not exceed #payout; tools/test_airdrop.lua pins that,
    -- because a payout array shorter than the range is a drop that silently
    -- pays fewer items than the number above it says.
    minItems = 10,
    maxItems = 14,
    payout = {
        -- --- the guaranteed ten ---------------------------------------
        'exclusive', 'exclusive',
        'volts',
        'legendary', 'legendary',
        'epic',
        'throwable',
        'healing',
        'ammo', 'ammo',
        -- --- the tail, dealt as the draw allows ------------------------
        'legendary',   -- 11: back to three legendaries
        'epic',        -- 12: ...and two epics, which is the 2026-08-21 drop
        'ammo',        -- 13
        'legendary',   -- 14
    },

    -- The pools the payout draws from.
    --
    -- `bucket` reads a rarity bucket straight out of config/weapons.lua, so the
    -- drop tracks the weapon table automatically -- add a legendary rifle there
    -- and it is in the airdrop, with nothing to remember here.
    --
    -- `ids` names items explicitly, for the pools that are not a whole tier.
    pools = {
        -- THE AIRDROP SHELF: the four weapons that exist only here
        -- (BR.Config.AirdropWeapons). Named by id rather than by bucket, on
        -- purpose -- they are in no bucket, which is the whole of "not found
        -- anywhere else", and a bucket reference would silently pay out
        -- nothing the day someone re-tiered them.
        exclusive = { kind = 'weapon', ids = {
            'rpg', 'minigun', 'railgun', 'grenadelauncher',
        } },

        -- Volts. Not an inventory item at all -- see voltsAmount below.
        volts     = { kind = 'volts' },

        legendary = { kind = 'weapon', bucket = R.LEGENDARY },
        epic      = { kind = 'weapon', bucket = R.EPIC },

        -- A full stack, not one: an airdrop grenade is a plan, a single
        -- grenade is a coin flip (the same argument RollLootStack makes for
        -- pairs on the world tables).
        throwable = { kind = 'throwable', ids = { 'sticky', 'grenade' } },
        -- `cprkit` IS THE SEAM FOR #191 and nothing more: the id is named here,
        -- the resolver below skips ids that do not resolve, and the day #191
        -- registers a `cprkit` consumable it appears in this pool with no change
        -- to this file. It is deliberately NOT defined here -- building it would
        -- be building #191.
        healing   = { kind = 'consumable', ids = { 'medkit', 'cprkit' } },
        ammo      = { kind = 'ammo', ids = {
            BR.AmmoType.HEAVY, BR.AmmoType.MEDIUM, BR.AmmoType.SHELLS,
            BR.AmmoType.SMG, BR.AmmoType.LIGHT,
        } },
    },

    -- ------------------------------------------------------------------
    -- VOLTS, AND WHY THE PICKUP IS NOT A WRITE
    -- ------------------------------------------------------------------
    --
    -- Owner, 2026-08-21: "Yes Volts should be a loot item in the air drops, and
    -- they should be 100 Volts. This should be an item that does not go into
    -- inventory - they simply pick it up and it's gone. Simple notification that
    -- they collected 100 Volts, and that's it."
    --
    -- WHAT IT IS ON THE GROUND: an ordinary loot registry entry of kind
    -- 'volts'. It inherits the whole hardened claim path -- range-checked
    -- against the roster's own sampled position, rate-limited, first-come
    -- arbitrated, refused identically for an entry that was never streamed to
    -- you and for one that no longer exists (docs/security.md). It is the
    -- highest-value single entry on the map, so re-earning that for a bespoke
    -- pickup would have been the wrong trade.
    --
    -- WHAT IT IS NOT: a second writer of a balance. The claim handler credits
    -- the roster entry and nothing else; the number rides the match results
    -- envelope into BR.Config.marketPayout and lands in the SAME atomic ADD as
    -- the match payout and the level-up bonus. config/market.lua's "exactly one
    -- writer that can increase a balance" stays literally true, and #88 asked
    -- for that explicitly ("it keeps the one-writer property intact").
    --
    -- The player is told at the moment they pick it up either way, which is the
    -- half the owner described. A player who leaves the match before it ends
    -- forfeits it along with their XP, their kills and their placement -- the
    -- rule roster.lua already applies to everything else a match earned.
    voltsAmount = 100,
    -- The prop the pile is drawn as. A vanilla money bundle: this is currency
    -- on the floor and it should read as currency on the floor.
    voltsProp   = 'prop_anim_cash_pile_01',
    -- FIVE TIMES THE AUTHORED SIZE (owner, 2026-08-22: "The volts prop is
    -- perfect but should be 5x the size."). See the PROP SIZE block below for
    -- how a size is applied at all, and for what may stop it.
    voltsScale  = 5.0,

    -- How far out the contents land, per item, when it bursts open. Same
    -- construction as a crate's scatter ring, one radius wider because a dozen
    -- items in a crate's ring would stack inside each other.
    scatterSpread = 0.8,

    -- ------------------------------------------------------------------
    -- PROPS
    -- ------------------------------------------------------------------
    --
    -- THE EXISTING PAIR, and they work (owner: "see if we can continue using
    -- our existing ones"). Nothing about prop_box_wood05a stops it being
    -- airdropped, because the descent is a coordinate write on a local object
    -- rather than a physics fall -- there is no model that cannot be moved that
    -- way. So the "if we can't airdrop ours, we shouldn't use the same husk
    -- either" branch never opens: the open/closed pair stays a matched pair.
    --
    -- If a playtest says an airdrop crate has to LOOK different from the 1300
    -- ordinary ones, both lines move together and nothing else changes.
    crateProp = 'prop_box_wood05a',
    huskProp  = 'prop_box_wood05b',

    -- ------------------------------------------------------------------
    -- PROP SIZE -- AND WHY THE BOX IS BACK AT 1.0 AND THE CANOPY IS NOT
    -- ------------------------------------------------------------------
    --
    -- Owner, 2026-08-22: "The parachute and crate props (including husk) should
    -- be 2x larger and the parachute should be 2.5x larger please." and "The
    -- volts prop is perfect but should be 5x the size."
    --
    -- Owner, 2026-08-23, having played it: "we need to tweak how the prop
    -- scaling works for the crate as it currently clips. We may need to drop
    -- scaling altogether." And, in the same breath: "the parachute scaling works
    -- great - let's keep that."
    --
    -- THERE IS NO SetEntityScale IN GTA V. #166 established that and settled on
    -- the transform matrix instead -- an entity's three axis vectors are unit
    -- length, so renormalising them to k draws the model at k (see
    -- BR.Native.propScale in br_core/client/natives.lua). That is the only
    -- lever, it scales the RENDER and never a collision box, and config/loot.lua
    -- has been carrying the same warning since the small shield went to 0.5:
    --
    --   ═══ NOBODY HAS CONFIRMED THE MATRIX SCALE RENDERS ON THIS BUILD ═══
    --
    -- ...except that the owner has now confirmed it, from the other end: a crate
    -- that CLIPS is a crate that grew. The matrix route renders. That is the one
    -- genuinely good piece of news in this block, and it retires a warning three
    -- config files have been carrying since #166.
    --
    -- ═══ WHY THE CANOPY IS FINE AND THE BOX IS NOT, WHICH IS GEOMETRY AND NOT
    --     A NUMBER ═══
    --
    -- A matrix scale grows the model about its ORIGIN. The canopy is frozen, has
    -- collision switched off, is positioned by arithmetic and hangs in open air
    -- with nothing beneath it to intersect -- so growing it about its origin
    -- costs nothing and it reads exactly as asked. Every part of "the parachute
    -- scaling works great" is a consequence of it never touching anything.
    --
    -- THE LANDED CRATE IS THE OPPOSITE OF ALL FOUR. It is a DYNAMIC physics
    -- object (client/loot.lua: SetEntityDynamic, SetEntityHasGravity,
    -- ActivatePhysics, unfrozen -- "drive into one and it moves", user
    -- 2026-08-05), it keeps its collision, and its height comes from resting on
    -- the ground. So at k the render reaches k times as far BELOW the origin
    -- while the collider that decides where the origin rests is still 1x: the
    -- bottom half of the box is drawn underneath the surface it is standing on.
    -- That is the clip, and it is not a tuning error -- 1.5 buries half as much
    -- of a bigger box and 1.1 buries a tenth of one.
    --
    -- ═══ AND IT CANNOT BE OFFSET AWAY, WHICH IS WHY "TWEAK IT" HAS NO ANSWER
    --     ═══
    --
    -- The obvious repair is to lift the prop by the extra half-height, and it
    -- works for a FROZEN prop. It cannot work here: gravity puts a dynamic
    -- object back on its 1x collider on the next simulation step, so the lift is
    -- undone before anybody sees it. Freezing the crate to keep the lift would
    -- take back the physics the owner asked for by name. There is no third
    -- option on this engine.
    --
    -- ═══ SO THE BOX GOES BACK TO AUTHORED SIZE, AND THE PRICE IS NAMED ═══
    --
    -- At 1.0 the airdrop crate is the same model at the same size as the ~1300
    -- ordinary ones (crateProp below is BR.Config.Loot.chestProp). What still
    -- tells it apart: two map blips of its own, the LEGENDARY glow, the flare
    -- column burnt down its descent path, and a 2.5x cargo canopy overhead the
    -- whole way down. What is LOST is the one cue that worked at a glance across
    -- a car park with the crate already on the ground.
    --
    -- IF THAT LOSS IS TOO MUCH, THE LEVER IS A MODEL AND NOT A NUMBER -- change
    -- crateProp/huskProp together, above. A genuinely larger crate model brings
    -- its own collision box with it and clips nothing, which is precisely what a
    -- matrix scale can never do.
    --
    -- A FALLING PART AND A LANDED ONE ARE SCALED IN TWO DIFFERENT FILES, because
    -- they are two different objects: the crate under the canopy is a local prop
    -- br_core/client/airdrop.lua builds, and the crate on the ground is an
    -- ordinary loot registry entry br_core/client/loot.lua builds. Both read
    -- these numbers, so the box does not change size when it touches down --
    -- which is also why both had to move, and why moving only the landed one
    -- would have produced a crate that shrank on impact.
    --
    -- /brpropscale IS STILL THE RULER, and it is how the owner checks this
    -- without a deploy: `brpropscale airdrop 2` puts the clip back on a live
    -- crate and `brpropscale airdrop 1` takes it away again, rebuilding the prop
    -- each time. The husk answers to `brpropscale airdrophusk`.
    crateScale = 1.0,
    huskScale  = 1.0,
    -- KEPT EXACTLY AS IT IS (owner, 2026-08-23: "the parachute scaling works
    -- great - let's keep that"). It is also the only one of the three that CAN
    -- stay: see the geometry above.
    chuteScale = 2.5,

    -- THE CARGO CANOPY, which is a different asset from the player's.
    -- `p_parachute1_mp_s` (BR.Config.Drop.parachuteModel) is the back-worn
    -- one; `p_cargo_chute_s` is the one Rockstar's own crate drop hangs over
    -- a crate, and it ships its own deploy anim. Base-game and streamed, so it
    -- needs nothing but RequestModel.
    chuteModel   = 'p_cargo_chute_s',
    chuteAnimDict = 'P_cargo_chute_S',
    chuteAnim     = 'P_cargo_chute_S_deploy',
    -- Rockstar's own offset, in the crate's LOCAL frame: right/forward/up in
    -- metres from the crate's centre. Their script reaches it with
    -- ATTACH_ENTITY_TO_ENTITY; we reach it by writing the canopy's coordinates
    -- from the same solver the crate's come from. See the note on rigid parts
    -- in br_core/client/airdrop.lua for why.
    chuteOffset  = { x = 0.0, y = 0.0, z = 0.1 },

    -- ------------------------------------------------------------------
    -- THE FLARES
    -- ------------------------------------------------------------------
    --
    -- Owner, 2026-08-21: "we need to attach flares to the left and right side of
    -- the crate when it's spawned so the flares leave smoke trails as it falls."
    --
    -- Owner, 2026-08-22: "there's still no flares on the crate, and there should
    -- be flares on the husk too fwiw", then "After using brflare it's clear to me
    -- why the flares aren't working - you used the wrong flare", and then, with a
    -- reference: "None of those models are the ones we need in order to draw the
    -- proper particles."
    --
    -- ═══════════════════════════════════════════════════════════════════
    -- THIRD ATTEMPT, AND THE OWNER IS RIGHT: NO MODEL WAS EVER GOING TO
    -- WORK. THE FIRST TWO ATTEMPTS WERE THE SAME MISTAKE TWICE.
    -- ═══════════════════════════════════════════════════════════════════
    --
    --   1. `prop_flare_01a` -- a name that is not a model at all. The whole
    --      flare block sat behind `if loadModel(...)`, so props and particles
    --      vanished together and nothing said a word.
    --
    --   2. A candidate list that took the first name which loaded. Something
    --      loaded. The owner still saw nothing.
    --
    -- BOTH ATTEMPTS WERE LOOKING FOR A MODEL THAT GLOWS. There is no such
    -- model. `AMMO_FLARE` is a CAmmoThrownInfo block and every visual the flare
    -- has is in it -- FuseFx `proj_flare_fuse`, TrailFx `proj_flare_trail`,
    -- LightColour (1.0, 0.168, 0.168), LightIntensity 8, LightRange 0.5,
    -- LightFlickers, CoronaSize, CoronaIntensity, and a LightBone of
    -- `gun_vfx_projtrail` -- and all of it is applied by the PROJECTILE
    -- controller. `<Model>w_am_flare</Model>` is only the drawable the
    -- projectile wears. A CreateObject of it makes a CObject with no ammo info
    -- and no controller, so none of that code runs and you get a grey tube.
    -- That is `w_am_flare`, `prop_flare_01` and `prop_flare_01b` alike, and it
    -- is why choosing between them could never have worked.
    --
    -- ═══ SO WE FIRE A REAL FLARE. THE OWNER'S REFERENCE IS THE TECHNIQUE. ═══
    --
    -- DevTestingPizza/Flares-and-Bombs (cflares.lua) fires `weapon_flaregun`
    -- through ShootSingleBulletBetweenCoordsWithExtraParams after
    -- RequestWeaponAsset and contains ZERO particle code -- the trail and the
    -- light come free because it is a real projectile.
    --
    -- AND ONE RESOURCE ALREADY DOES IT ON A CRATE DROP, which is our exact
    -- case. Vechro/cratedrop fires `weapon_flare` at the parachute's
    -- coordinates, and its two quirks ARE the technique:
    --
    --   * THE START AND END COORDS DIFFER BY 1e-4. That is what makes a
    --     BALLISTIC thing stand still: with effectively no separation there is
    --     no direction to travel in, so the flare stays where it was put. It is
    --     also load-bearing in the other direction -- that resource's own
    --     comment says a flare fired with IDENTICAL coords "remains static and
    --     won't remove itself later".
    --   * SPEED IS NEGATIVE (-1.0), which is idiomatic across every resource
    --     that does this.
    --
    -- That answers the objection this file has refused the projectile over
    -- twice: a projectile is ballistic, and this one is not going anywhere.
    --
    -- ═══ AND THE OTHER OBJECTION HAS A SERVER-SIDE ANSWER, VERIFIED IN
    --     FiveM'S OWN SOURCE RATHER THAN INFERRED ═══
    --
    -- A projectile REPLICATES. It is not a networked entity -- `sv_entityLock-
    -- down` would not refuse it -- which makes it worse rather than better:
    -- every client would draw forty-seven remote copies on top of the pair it
    -- built itself. One research pass claimed the technique is "local to the
    -- calling client". IT IS NOT, and the proof is that FiveM's server contains
    -- a full wire parser for it: `CStartProjectileEvent`
    -- (citizen-server-impl/src/state/ServerGameState.cpp), surfaced to scripts
    -- as `startProjectileEvent`, carrying ownerId, projectileHash and
    -- weaponHash. A purely local action does not get a net game event.
    --
    -- WHAT MAKES IT USABLE IS THAT CANCELLING THAT EVENT SUPPRESSES THE RELAY,
    -- and that is not a guess either. Both of the server's packet paths gate the
    -- relay on the handler's return value, verbatim:
    --
    --     if (eventHandler())            // false when a script cancelled
    --     {
    --         RouteEvent(...);           // the only thing that sends it on
    --     }
    --
    -- (NetGameEventPacketHandler.cpp:134 for the V2 packet, and
    -- ServerGameState.cpp:8003 for the legacy msgNetGameEvent path.)
    --
    -- So br_core/server/airdrop.lua cancels `startProjectileEvent` for the FLARE
    -- weapon hash and nothing else. Every client fires its own pair locally and
    -- receives nobody else's. The property this whole file rests on -- nothing
    -- about a drop crosses the wire per frame -- is intact, and it is intact for
    -- a checked reason rather than a hopeful one.
    --
    -- ═══ WHAT NOBODY CAN TELL YOU FROM HERE ═══
    --
    -- Whether any of it RENDERS. That has been the honest answer twice and it is
    -- the honest answer now. Nothing outside a running client can say whether a
    -- fired flare appears, how bright it reads at 170m, or whether the cancel
    -- leaves the local copy alone. /brflare is the instrument; it fires one in
    -- front of the player and reports every fact a native will answer.
    --
    -- ─── THE TWO ROUTES, AND WHY THE SECOND ONE SURVIVES ───
    --
    --   'projectile'  THE DEFAULT. A real `weapon_flare` fired in place, with
    --                 the engine's own light, corona, flicker and trail. No
    --                 particle code, because the projectile is the particle.
    --   'object'      The old prop + looped ptfx. Kept because it is the ONLY
    --                 route with an observable: a looped ptfx handle can be
    --                 asked whether it is alive, and a projectile cannot be
    --                 asked anything at all. If the projectile route shows
    --                 nothing, this is what distinguishes "the client is not
    --                 drawing flares" from "the client is drawing flares that
    --                 do not glow".
    --
    -- CreateWeaponObject WAS CONSIDERED AND IS NOT IMPLEMENTED, so that attempt
    -- four does not re-litigate it: a GitHub code search for CreateWeaponObject
    -- with a flare returns only native stub files -- no released resource does
    -- it -- and the one resource that uses the native at all ships a MODIFIED
    -- weapons.meta, which suggests vanilla alone was not enough. It creates a
    -- weapon object rather than a projectile, so there is still no path for the
    -- ammo light code to run. It is the same mistake as the models, wearing a
    -- different native.
    flareRoute = 'projectile',

    -- ------------------------------------------------------------------
    -- THE PROJECTILE ROUTE
    -- ------------------------------------------------------------------
    --
    -- `weapon_flare`, NOT `weapon_flaregun`. Both appear in the wild by this
    -- route; the crate-drop resource -- our exact case -- uses `weapon_flare`,
    -- which is the thrown flare whose AMMO_FLARE block carries the light.
    -- `weapon_flaregun` is the pistol that fires it, and the owner's reference
    -- uses it because it is firing from an aircraft with real velocity.
    flareWeapon = 'weapon_flare',
    -- RequestWeaponAsset's two extra arguments, as two of the three resources
    -- pass them. THE WAIT LOOP MUST CONTAIN A Citizen.Wait OR THE CLIENT HANGS,
    -- which is why loadWeapon in client/flares.lua is bounded like every other
    -- streaming wait in this project rather than a bare `while not ... do end`.
    flareAssetP1 = 31,
    flareAssetP2 = 26,
    -- The separation between the shot's start and end coordinates, in metres.
    -- SMALL ENOUGH THAT THE FLARE DOES NOT TRAVEL AND NON-ZERO ON PURPOSE: the
    -- reference resource's comment records that identical coords leave a flare
    -- that "remains static and won't remove itself later".
    flareEpsilon = 0.0001,
    -- Negative, as every resource that does this passes it.
    flareSpeed   = -1.0,

    -- ═══ HOW OFTEN A FLARE IS RE-FIRED. ONE NUMBER, AND ONLY DURING THE FALL ═══
    --
    -- A FIRED FLARE BURNS OUT. AMMO_FLARE's LifeTime is 62.5s and its
    -- LifeTimeAfterExplosion is 60s, so a flare lit at the release is gone about
    -- a minute later whatever we do -- which is fine for a 30s descent.
    --
    -- A flare fired in place STAYS in place while the crate falls away from it,
    -- so the only way a falling crate has flares beside it is to light a new one
    -- as it goes. What that leaves behind is a burning column down the descent
    -- path -- the "smoke trails as it falls" the owner asked for on 2026-08-21,
    -- drawn by the engine instead of by us. At 3000ms a 30s descent lights ten a
    -- side; they expire on their own about a minute later and WE NEVER DELETE
    -- THEM -- see below.
    --
    -- ─── AND THE OWNER NAMED THAT COLUMN THE BEST PART (2026-08-23) ───
    --
    -- "there are also free-falling flares which I did not expect but I LOVE it!"
    -- The flares hanging in the air behind the crate are not a bug and are not
    -- a placeholder: they are what this cadence IS. Do not "fix" them into a
    -- pair that tracks the box down.
    --
    -- THERE WAS A SECOND NUMBER HERE, `flareRefireMs`, for the landed crate and
    -- its husk. It is gone with the pass that read it -- same message, same day:
    -- "Seems the husk keeps getting more and more flares indefinitely though...
    -- If we drop the husk flares and keep the free-falling ones I'd be happy
    -- with that." See client/flares.lua.
    --
    -- ═══ WE DO NOT CLEAN THESE UP, AND THAT IS DELIBERATE ═══
    --
    -- A fired flare settles into a real `w_am_flare` world object that we did
    -- not create and hold no handle to. The reference resources find theirs
    -- again with GetClosestObjectOfType and a radius -- a spatial search that
    -- would, on this map, just as happily delete a flare somebody else lit. The
    -- engine already expires them on AMMO_FLARE's own clock, so the honest
    -- answer is to let it: nothing here creates an object it cannot delete,
    -- because nothing here creates one at all.
    flareFallRefireMs = 3000,

    -- ------------------------------------------------------------------
    -- THE OBJECT ROUTE (the fallback, and the only observable one)
    -- ------------------------------------------------------------------
    --
    -- Only read when `flareRoute` is 'object'. The model is a config value with
    -- its alternatives beside it so all three can be tried from the console
    -- without a code change -- but understand what is being tried: none of them
    -- glows, and the visible part of this route is the PARTICLE.
    flareModel        = 'w_am_flare',
    flareAlternatives = { 'w_am_flare', 'prop_flare_01', 'prop_flare_01b' },
    -- FOUR TIMES AUTHORED SIZE, AND STILL A GUESS. /brpropscale's warning
    -- applies in full: if the matrix scale does not render on this build then
    -- neither does this.
    flareScale        = 4.0,
    -- `core` / `exp_grd_flare` IS THE FLARE'S OWN EFFECT and it replaced
    -- `weap_smoke_grenade` here. The chain is traceable: AMMO_FLARE's
    -- <Explosion> is FLARE, eExplosionTag FLARE is 22, and explosionfx.dat's
    -- EXP_VFXTAG_FLARE row names `exp_grd_flare`. It is verified present in
    -- `core` and there is a shipped reference using it at a world coordinate
    -- (Coffeelot/cw-racingapp). Other verified pairs, all reachable with
    -- `/brflare ptfx <asset> <name> [scale]` and none needing an edit here:
    --   core                     proj_flare_trail, proj_flare_fuse,
    --                            weap_heist_flare_trail, weap_smoke_grenade
    --   wpn_flare                proj_heist_flare_trail
    --   scr_oddjobtraffickingair scr_crate_drop_flare, scr_crate_drop_beacon
    --   scr_apartment_mp         scr_finders_package_flare
    flarePtfx         = true,
    flarePtfxAsset    = 'core',
    flarePtfxName     = 'exp_grd_flare',
    -- Bigger than the 1.0 that showed nothing, and a plume rather than a wisp.
    flarePtfxScale    = 2.0,

    -- ------------------------------------------------------------------
    -- WHERE THEY GO, ON EITHER ROUTE
    -- ------------------------------------------------------------------
    --
    -- In the crate's LOCAL frame, so they stay on the crate's left and right
    -- faces while it yaws. One per side, and the sign is the only difference.
    -- Wider than they were, because the crate is drawn at 2x now and the old
    -- 0.55 would put both flares inside it.
    flareOffset = { x = 1.1, y = 0.0, z = 0.0 },

    -- ------------------------------------------------------------------
    -- ...AND THEY STOP AT TOUCHDOWN. THERE IS NO `flareOnLanded`.
    -- ------------------------------------------------------------------
    --
    -- ═══ THE OWNER ASKED FOR LANDED FLARES, SAW THEM, AND ASKED FOR THEM BACK
    --     OUT. BOTH SENTENCES ARE HERE ON PURPOSE. ═══
    --
    -- 2026-08-22: "there should be flares on the husk too fwiw."
    -- 2026-08-23: "Seems the husk keeps getting more and more flares
    --   indefinitely though. The way you have it coded there are also
    --   free-falling flares which I did not expect but I LOVE it! If we drop the
    --   husk flares and keep the free-falling ones I'd be happy with that."
    --
    -- WHY IT LOOKED LIKE THAT, because the reason is the whole argument against
    -- putting it back. A projectile flare is lit AT A COORDINATE and burns where
    -- it was lit; we hold no handle and never delete one. Against a FALLING
    -- crate the cadence therefore paints a column down the descent path and each
    -- flare expires ~60s later -- self-limiting, and the part the owner loves.
    -- Against a box that has stopped moving, the same cadence stacks a new pair
    -- on the same spot every 45s until the match ends. Same code, same numbers;
    -- the only difference is whether the target moves.
    --
    -- A "fix" that capped the count, or deleted the old pair, would mean this
    -- file creating flares it then has to find again -- and the only way to find
    -- one is GetClosestObjectOfType with a radius, which on this map would just
    -- as happily delete a flare somebody else lit. The owner's answer is
    -- cheaper and better: there are no landed flares.
    --
    -- SO DO NOT RE-ADD `flareOnLanded`, `flareRefireMs`, a landed pass in
    -- client/flares.lua, or BR.Loot.airdropBox(). All four went together and all
    -- four would have to come back.

    -- HOW FAR THE CRATE TURNS OVER THE WHOLE DESCENT, in degrees. A crate under
    -- a canopy that never turns reads as a prop sliding down an invisible rail.
    -- A number rather than a literal in the client because the flares' world
    -- positions are derived from it, so the two cannot disagree.
    spinDegrees = 30.0,

    -- ------------------------------------------------------------------
    -- THE BLIP
    -- ------------------------------------------------------------------
    --
    -- 161 IS THE POINT, NOT A COMPROMISE. It was first written down here as the
    -- owner's choice over GTA's crate-drop glyph (306, `radar_cratedrop`), as
    -- though a crate glyph were the thing we could not have. It is the other way
    -- round -- owner, 2026-08-21: "bliptype 161 is what I want - it will give
    -- them a radius, not an exact point. That's why we want 161."
    --
    -- 161 is `radar_mp_noise`, the animated radiating-ripple icon, and a ripple
    -- is an AREA. That is the design: everyone in the match learns roughly where
    -- the drop is coming down and has to find it, rather than being handed a
    -- pixel to run at. A crate glyph would answer the question the search is
    -- supposed to be. Do not "fix" this to 306.
    --
    -- IT IS AN ORDINARY SPRITE ON AN ORDINARY COORD BLIP, checked against the
    -- Cfx blip reference after the 2026-08-22 playtest reported no marker. The
    -- RADIUS blips are 9 and 10 (`radar_radius_blip`,
    -- `radar_radius_outline_blip`) and are made with AddBlipForRadius, which
    -- takes no sprite at all -- so "gives them a radius" is what 161 LOOKS like
    -- and does not mean this wants a radius blip.
    blipSprite = 161,
    blipColour = 5,      -- the same yellow the loot blips use
    -- TWICE THE SIZE (owner, 2026-08-22: "The blip needs to be 2x larger
    -- please."). 1.2 was the value they saw; this is that, doubled.
    --
    -- THIS IS THE BIG MAP'S SIZE AND ONLY THE BIG MAP'S (owner, 2026-08-23:
    -- "The big map blip is perfect size"). Do not retune it to fix the minimap
    -- -- that is `blipMinimapScale` below.
    blipScale  = 2.4,
    -- Named, or GTA names the sprite after whatever mission it was drawn for
    -- and the pause-menu legend reads as something from a heist -- the lesson
    -- client/loot.lua's courtesy blips already paid for.
    blipName   = 'Airdrop',

    -- ------------------------------------------------------------------
    -- ...AND IT IS TWO BLIPS, ONE PER SURFACE
    -- ------------------------------------------------------------------
    --
    -- Owner, 2026-08-23: "specifically the blip on the MINIMAP should show much
    -- smaller. I believe there's a bliptype we can use that only shows on the
    -- big map and one that only shows on the minimap. The big map blip is
    -- perfect size"
    --
    -- ═══ THEY ARE RIGHT, AND SET_BLIP_SCALE IS THE REASON IT TAKES TWO ═══
    --
    -- There is no per-surface scale. SET_BLIP_SCALE sets ONE size and both
    -- surfaces draw at it, so a single blip cannot be 2.4 on the pause map and
    -- small on the minimap however it is configured. What CAN be restricted per
    -- surface is DISPLAY -- SET_BLIP_DISPLAY (0x9029B2F3DA924928) -- so the
    -- drop puts up two blips at the same coordinate, each shown on one surface
    -- only and each carrying its own scale. client/airdrop.lua builds,
    -- re-asserts and tears down both together.
    --
    -- ═══ THE ENUM, CHECKED RATHER THAN REMEMBERED ═══
    --
    -- Read off citizenfx/natives HUD/SetBlipDisplay.md -- the file
    -- docs.fivem.net renders -- because the blog-level sources disagree with it
    -- and with each other (one widely-copied post has 8 as "minimap only"; it is
    -- not, it is BOTH surfaces, not selectable). The documented table:
    --
    --   0, 1, 7  nowhere at all
    --   2, 6     both surfaces, selectable on the map
    --   3, 4     MAIN MAP ONLY, selectable
    --   5, 9     MINIMAP ONLY
    --   8, 10+   both surfaces, not selectable
    --
    -- 3 AND 5 ARE ALSO THE TWO ROCKSTAR ACTUALLY SHIPS. That same file records
    -- that the decompiled scripts only ever use 0, 2, 3, 4, 5 and 8 -- so of the
    -- pairs that would work (3/4 and 5/9) these are the halves with vanilla
    -- mileage behind them, which is the difference between a documented value
    -- and an exercised one.
    --
    -- AND THEY ARE CONFIG VALUES, NOT LITERALS, for exactly that reason: this
    -- repo has been bitten by a documented enum being wrong before (the audio
    -- priority above, where MAX is 2 and HIGH is 3). If the split comes out
    -- backwards in-game, these two numbers swap and nothing else moves.
    blipDisplay        = 3,     -- big map only
    blipMinimapDisplay = 5,     -- minimap only
    -- "MUCH smaller" against a big map blip staying at 2.4. A third of it, and
    -- below GTA's own default of 1.0 -- the minimap is a corner of the screen
    -- and the drop is one point on it, where the pause map is the whole screen
    -- and the ripple is meant to read as an area. This is the number to turn if
    -- it is still wrong; `blipScale` is not.
    blipMinimapScale   = 0.8,

    -- ------------------------------------------------------------------
    -- HOW LONG THE BLIP LIVES, WHICH IS NOW A DIFFERENT QUESTION
    -- ------------------------------------------------------------------
    --
    -- It used to be "one minute after the drop hits the ground" (owner,
    -- 2026-08-21) and that was measured from tLand. The 2026-08-22 playtest
    -- found the hole in it:
    --
    --   "if nobody arrives fast enough, the blip goes away and they have no
    --    idea where the drop is. My proposal is we keep the blip on until 1
    --    minute after the crate is opened, or no longer than 4 minutes if
    --    unopened, which would also be the case if nobody got to the location
    --    in time. But 5 minutes should be plenty of time to get there."
    --
    -- SO THE CLOCK NOW RUNS FROM THE OPEN, NOT FROM THE LANDING, and there is a
    -- ceiling under it for the case where nobody ever opens it.
    --
    --   opened at tOpen  ->  the blip goes at tOpen + blipAfterOpenMs
    --   never opened     ->  the blip goes at tStart + blipMaxMs
    --
    -- Opening it SHORTENS the window in the ordinary case, and that is the
    -- intent: the blip's job is to get somebody there, and once somebody is
    -- there it has one minute of work left. The ceiling is what makes the
    -- unopened case safe -- and it is load-bearing now in a way it was not
    -- yesterday, because the same playtest removed the auto-open (see
    -- br_core/server/airdrop.lua), so "opened" is a thing that may simply never
    -- happen. Without the ceiling an uncontested drop would mark the map for
    -- the rest of the match.
    --
    -- ═══ CONFIRMED BY THE OWNER, 2026-08-22 ═══
    --
    -- This was flagged here as an ambiguity -- their "5 minutes should be
    -- plenty" one sentence after naming 4 -- and it was read as justifying the
    -- 4-minute ceiling rather than naming a second number. That reading was
    -- right and they have said so:
    --
    --   "The blip should be 4 minutes. If nobody opens it. If someone opens it,
    --    the blip should remain for 1 minute after opening. That's what I meant,
    --    which I guess could total to 5."
    --
    -- So the two numbers below ARE the rule, and the "could total to 5" is the
    -- 4-minute ceiling plus the minute an open buys. Do not collapse them into
    -- one number.
    --
    -- WHAT THE CEILING IS MEASURED FROM MOVED ON THE SAME DAY, and that is the
    -- one thing here that is not the owner's sentence: see `armWithin` above.
    -- A drop now WAITS for somebody to come near before it falls, so the clock
    -- restarts when it stops waiting. `tArm`, not `tStart`.
    blipAfterOpenMs = 60000,    -- 1m00 after the crate is opened
    blipMaxMs       = 240000,   -- 4m00 from the announcement, then from the arm

    -- Verbatim, and it must stay verbatim (owner, 2026-08-21). Written here
    -- rather than inline so there is one copy to be wrong.
    notifyText = 'An airdrop is arriving! It brings ultra-rare loot - first come, first served.',
}

-- ---------------------------------------------------------------------------
-- POOL RESOLUTION
-- ---------------------------------------------------------------------------

--- Turn one pool definition into an array of stack TEMPLATES.
---
--- Resolved once, at load, for two reasons. It keeps BR.AirdropPayout pure --
--- it shuffles and copies, and looks nothing up -- and it means an id that does
--- not resolve (the `cprkit` seam, until #191 lands) is dropped ONCE here
--- rather than changing the number of RNG draws a payout burns.
--- @param p table
--- @return table[]
local function resolvePool(p)
    local out = {}

    if p.kind == 'weapon' then
        local bucket = p.bucket and BR.Config.WeaponsByRarity[p.bucket] or nil
        local src = bucket or {}
        if p.ids then
            src = {}
            for _, id in ipairs(p.ids) do
                local w = BR.Config.WeaponById[id]
                if w then src[#src + 1] = w end
            end
        end
        for _, w in ipairs(src) do
            out[#out + 1] = {
                item = w.id, kind = BR.ItemKind.WEAPON,
                rarity = w.rarity, count = 1, clip = w.clip,
            }
        end

    elseif p.kind == 'throwable' then
        for _, id in ipairs(p.ids or {}) do
            local t = BR.Config.WeaponById[id]
            if t then
                out[#out + 1] = {
                    item = t.id, kind = BR.ItemKind.THROWABLE,
                    rarity = t.rarity, count = t.maxStack or 1,
                }
            end
        end

    elseif p.kind == 'consumable' then
        for _, id in ipairs(p.ids or {}) do
            local c = BR.Config.ConsumableById[id]
            if c then
                out[#out + 1] = {
                    item = c.id, kind = BR.ItemKind.CONSUMABLE,
                    rarity = c.rarity, count = 1,
                }
            end
        end

    elseif p.kind == 'ammo' then
        for _, id in ipairs(p.ids or {}) do
            local a = BR.Config.AmmoPickups[id]
            if a then
                out[#out + 1] = {
                    item = id, kind = BR.ItemKind.AMMO,
                    rarity = BR.Rarity.COMMON, count = a.amount,
                }
            end
        end

    elseif p.kind == 'volts' then
        -- ONE TEMPLATE, NO ids LIST. There is exactly one thing this pool can
        -- pay and the amount is the config's, so the deck is a single card and
        -- every slot pointing at this pool deals the same 100 Volts. `count`
        -- carries the amount because that is the field wireEntry already sends;
        -- nothing new travels for this.
        --
        -- 'volts' IS A BARE STRING BECAUSE THE OTHER NON-INVENTORY KINDS ARE.
        -- BR.ItemKind names what a SLOT can hold, and this is the one loot kind
        -- that never reaches a slot -- so it sits beside 'chest', 'husk' and
        -- 'deathbox', which are literals in server/loot.lua and client/loot.lua
        -- for the same reason.
        out[#out + 1] = {
            item = 'volts', kind = 'volts',
            rarity = BR.Rarity.LEGENDARY,
            count = BR.Config.Airdrop.voltsAmount or 100,
            prop = BR.Config.Airdrop.voltsProp,
        }
    end

    return out
end

--- [poolName] = array of stack templates, in a FIXED order.
---
--- Built from arrays throughout -- BR.Config.WeaponsByRarity, the authored id
--- lists -- and never from a pairs() walk, for the reason loot_gen.lua states
--- at the top of its file: a payout must replay identically from a seed.
BR.Config.Airdrop.resolvedPools = {}
for _, name in ipairs({ 'exclusive', 'volts', 'legendary', 'epic', 'throwable',
                        'healing', 'ammo' }) do
    local p = BR.Config.Airdrop.pools[name]
    if p then
        BR.Config.Airdrop.resolvedPools[name] = resolvePool(p)
    end
end
