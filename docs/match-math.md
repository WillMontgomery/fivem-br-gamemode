# The arithmetic of a match

Every number a match is built from, where it comes from, and why it is that
number. This is the page to read before changing any of them.

[← Back to the main README](../README.md)

---

> **Two matches on the same server are never identical. Not unlikely — impossible.**
> Across separate server runs the odds are roughly **1 in 4.3 billion** (2³²).
> The proof is one line of algebra and it is in §1.

Nothing here is decided by a client. Every value below is computed on the
server, from a seed the server keeps, and published as a record that clients
*interpolate* rather than recompute. That distinction is load-bearing and it
comes up in every section.

---

## 0. Why any of this is generated at all

An authored map is the obvious alternative: pick the good drop spots, place the
loot by hand, script the circles. Plenty of games do it. For **this** game it
would be worse, for four reasons that compound.

**A battle royale is a game about incomplete information, and an authored map
deletes it.** The whole tension of a drop is *not knowing* what is down there
before you commit. On a fixed map that is true exactly once per player. By the
tenth match everyone knows which building holds the good crate, and the drop
stops being a decision — it becomes a race to a known coordinate, won by
whoever alt-tabbed least. Every match here lays out ~3,200 items freshly, so
"is this POI worth it" is a real question on match one thousand.

**Randomness is what makes the storm a director rather than a timer.** The
anchor is chosen from the flight path, so the circle usually contains ground
people actually dropped on — but which ground changes every time. Combined with
the breakout rule, that means the map has no permanent centre. There is no
Tilted Towers to memorise, no one building that wins the endgame, and a squad
that always plays the same rotation is punished by the map rather than
rewarded by it.

**It makes the game cheap to change.** Rebalancing an authored map means moving
hundreds of hand-placed objects. Here it means editing one number and running
`tools/verify.sh`. Loose loot was halved twice in a week and healing was moved
into crates entirely — both are a config line, both are covered by tests that
fail if the resulting distribution is wrong.

**And it is what makes the layout unknowable to a cheat.** The seed never
leaves the server. A client cannot derive where anything is because it does not
have the input; all it ever receives is the 3×3 cell of items it is standing
in. On an authored map the layout is in the resource files — every player has a
copy, and a wallhack is a text editor.

The cost is that the generator has to be *correct*, because a bad draw is a
broken match rather than a bad screenshot. That is why every formula below is a
pure function tested outside the game, and why there are gates for the things
that are data rather than logic (see [Testing](testing.md)).

---

## 1. Seeds, and why the same match never repeats

Four independent seeds per match, each folded with a **different prime**:

```
lootSeed    = now + matchSeq × 15485863
stormSeed   = now + matchSeq ×     7919
busSeed     = now + matchSeq ×   104729
airdropSeed = now + matchSeq ×   1299709
```

where `now` is `GetGameTimer()` — milliseconds since the resource started, and
`matchSeq` is the match's **sequence number**: an increment from 1, internal,
never displayed. It is not the match **id**, which since #291 is a random 28-bit
draw shown as seven hex characters. All this number has to do is tell two matches
apart inside one millisecond, and an increment does that exactly as well as a
random draw — while keeping every layout, storm path and tour reproducible from
a boot, which a random draw would not.
Each seed is expanded through SplitMix32 into the four 32-bit state words of an
xoshiro-style generator (`br_lib/shared/rng.lua`), because Lua's built-in RNG
is neither portable nor reproducible across runtimes.

### The exact odds of two identical matches

A match is fully determined by its three seeds, so two matches are identical if
and only if all three collide. Write that out for matches `(t₁, n₁)` and
`(t₂, n₂)`, where `n` is the sequence number:

```
t₁ + n₁ × 15485863  =  t₂ + n₂ × 15485863
t₁ + n₁ ×     7919  =  t₂ + n₂ ×     7919
```

Subtract the second from the first:

```
(n₁ − n₂) × (15485863 − 7919) = 0     ⟹    n₁ = n₂     ⟹    t₁ = t₂
```

**So two matches are identical only if they have the same sequence number at
the same millisecond.** Sequence numbers are allocated by increment and never
reused, so within a single server run the probability is *exactly zero* — not
small, structurally impossible. That is a stronger guarantee than one seed would
give, and it is what the four different primes buy.

**A new subsystem takes a new prime, and the reason is not tidiness.** The
airdrop (#88) draws its schedule, its landing POI and its contents from
`airdropSeed`. Had it drawn them from `lootSeed` instead — the obvious
shortcut, since both are about loot — every draw it took would have shifted the
entire downstream loot sequence, and every existing layout would have changed
the day the airdrop shipped. Independent streams are what make a subsystem
addable without moving anything already on the map.

That is not a one-off argument, and it was collected on again on 2026-08-22.
The airdrop's item count went from a fixed twelve to a draw of 10–14, which
*added an rng call*. Taken from `airdropSeed` it moves nothing; taken from
`lootSeed` it would have shifted all ~3,200 items on every map in the game —
silently, because a different-but-valid layout is indistinguishable from a
correct one. `tools/test_airdrop.lua` generates a whole layout, burns an airdrop
payout, and generates it again, rather than trusting this paragraph.

Across separate server runs, sequence numbers restart from the same base, so
identity needs the same one to be minted at the same millisecond offset.
Treating that offset as uniform over a 32-bit range gives **≈ 1 in 4.3 × 10⁹**, and in practice far less
— matches start when players queue, not on a schedule.

For scale, the space the seeds *address* is much larger than the seeds
themselves. One layout alone draws roughly:

| Draws | From |
|---|---|
| ~3,200 items × (position, kind, rarity, item) | the loot layout |
| ~24 | storm centres and breakout rolls |
| ~10 | route chord, tour choice, anchor |
| ~20 | airdrop: the probability roll, the delay, the POI, the heading, **how many items this drop holds**, and one shuffle per pool it deals from |

The binding constraint is therefore the seed, not the outcome space — which is
exactly the right way round. Widening the seed widens everything downstream.

**The seed never leaves the server.** A client that could derive the loot
layout would know where every item on the map is; a client that could derive
the storm sequence would know every circle in advance. `brlootseed <n>` pins a
layout for debugging, server-side only.

---

## 2. The flight route

The bus flies an authored tour, not a straight line. Route selection is a
seeded pick over the tours in `br_lib/config/map.lua`, then a chord across the
map for the approach.

### The chord

```
theta   = rng() * 2π                        -- a random bearing
offset  = (rng() * 2 - 1) × radius × maxOffset
half    = √(radius² - offset²)              -- half-chord at that offset
start   = centre + perpendicular(offset) - direction × half
end     = centre + perpendicular(offset) + direction × half
```

The perpendicular offset is what stops every match flying through the middle of
the map. `maxOffset` defaults to 0.5, so the chord can sit anywhere from a
diameter to a shallow edge pass.

### Timing the route

Waypoints are solved into a timed path with a smoothing pass, so the plane
accelerates and decelerates rather than stepping between speeds:

```
-- forward pass, then backward pass, over every adjacent pair
cap      = √(v_next² + 2 × a_max × distance)
v_i      = min(v_i, cap)

-- then time each segment at its average speed
t += distance / ((v_prev + v_next) / 2)
```

The backward pass is the one that matters: without it a plane can be *told* to
be slow at a waypoint it is arriving at too fast to reach.

### Takeoff

| Quantity | Value | Why |
|---|---|---|
| Roll distance | ~382 m | Spawn to `rotatePoint`, surveyed in game |
| `rollSpeed` | 88 m/s | Wheels-up speed. Roll time is `2 × distance / rollSpeed` |
| `climbDist` | 1800 m | Past rotation, to reach cruise altitude |
| `climbSpeed` | 270 m/s | Through the climb and the first turn |
| `turnRadius` | 1000 m | Fillet: start turning this far from a waypoint |

### The doors

The jumpable window is the **union** of an authored window and every door-zone
crossing:

```
open  = min(authoredOpen,  first zone entry)
close = max(authoredClose, last zone exit)
open  = max(open, rotateAt)          -- never before wheels-up
```

Door zones (`BR.Config.Map.DoorZones`) cover LSIA and the ports. The union is
widening-only: a zone can never make the jumpable stretch shorter than the
authored one. The radii are deliberately tight — an early draft at 1200/1400 m
reached out over the ocean, and the departure path from Cayo clipped it,
opening the doors over open water seconds after takeoff.

---

## 3. The storm

### The anchor

The whole sequence homes on one point, chosen at warmup:

1. Pick a random **waypoint of this match's own flight tour**.
2. Pick a random **POI** between `band.min` and `band.max` of it (500–1500 m).
3. If nothing is in band, widen by `widenStep` up to `widenMax`, then take the
   nearest POI outright.

Route-coupled, so the opening circle almost always contains a stretch of the
path players actually dropped along. POI-anchored, so the centre is always a
nameable place on land.

### The opening zone

```
radius0 = max(configRadius0, distance from anchor to the furthest AABB corner) + openMargin
```

It covers the **whole playable map** by construction, and it is an exact **disc**
of that radius — zone 0 is the one zone that is not drawn (#344). Nobody can land
outside it, so "I spawned already dying" is structurally impossible, and its wall
during phase 1's hold is a clean ring just past the farthest map corner.

### The phases

| # | Radius | Wait | Shrink (ceiling) | DPS |
|---|---|---|---|---|
| 1 | 2600 | 120 s | 240 s | 0.5 |
| 2 | 1600 | 120 s | 120 s | 1.25 |
| 3 | 950 | 90 s | 90 s | 1.7 |
| 4 | 520 | 75 s | 75 s | 2.2 |
| 5 | 260 | 60 s | 60 s | 2.9 |
| 6 | 110 | 45 s | 50 s | 4.0 |
| 7 | 40 | 40 s | 40 s | 5.0 |
| 8 | 0 | 30 s | 60 s | 6.7 |

A phase's radius is now the size of its zone's **area** — every zone holds 0.90
of that circle's area, whatever its shape — rather than a bound on where its
edge may be. See "The shape of the wall" below.

DPS is in **display units per second** against a 100-point bar, so phase 1
takes 200 s of standing still to kill and phase 8 takes 15.

Phase 1 is deliberately the forgiving one: a far-end jumper has a legitimate
multi-minute run to the first circle, so being caught by it should cost health
rather than the match.

### How long a shrink actually takes

The authored `shrink` is a **ceiling**, not the duration. The real figure is
priced off the furthest player's run to the wall the sweep ends on, against the
wall that will chase them:

```
lo(t)     = how far along a straight line from the player the safe zone begins
            at sweep fraction t
run       = min over two lines of ( max over the sweep of lo(t) / t )    -- 0 inside it
furthest  = max over in-match players of run
shrinkSec = clamp(furthest / 9.0, 40, ceiling)
```

9 m/s is the assumed cross-map travel speed. Everyone already inside means the
sweep takes the 40-second floor and the game moves on; a genuine straggler buys
time up to the ceiling. The wall is the destination's **real boundary** (#344,
as #364 did for the hold): it used to be `distance to next centre − nextRadius`,
which on a stretched zone charges a player off its long side a run to a circle
nothing draws and lets one off its end ride free. Phase 8's destination is a
point, and the run is to the point.

**Priced on the moving wall, not on the distance** (#344). While the wall was the
blend `(1 − t)·Z0 + t·D`, a player running straight at the destination's nearest
point at `d / T` stood inside it at every instant, so the distance was the run to
the metre. The corner-to-corner morph moves each corner to its own partner, so
parts of the wall reach a player sooner than their distance says, and a sweep
priced at `d / 9` knocked the runner it was priced for (139 HP at phase 5, in the
round's review). So the run reads the wall itself — `lo(t) / t` is the pace that
keeps the line's entry into the safe zone behind the runner — along the two lines
a player runs at a destination: straight at its nearest point, and straight at its
centre as far as its edge. A player outside the zone the phase starts in is in the
storm already and is priced on the distance. `BR.StormSweepRun` reads the wall at
62 instants and refines the maxima of the players who could set the price; its
measured error and cost are in storm_solve.lua.

**What #344 cost the pacing, measured rather than argued.** The zones keep their
phase's area, but a 3:1 zone is longer than its circle was, so the furthest run
from the zone a phase starts in to its destination is longer too, and more sweeps
now reach the authored ceiling — which is exactly where the price stops protecting
the furthest player. 600 simulated matches, the same seeds on 52a7caa and now, 24
players spread over land inside the zone each phase starts in:

| Phase | Mean sweep (s) | Sweeps at the ceiling | Mean furthest run (m) |
|---|---|---|---|
| 2 | 130.9 → 133.4 | 65.2% → 70.5% | 2000 → 2277 |
| 3 | 107.4 → 112.6 | 54.2% → 68.3% | 1438 → 1635 |
| 4 | 92.8 → 98.3 | 25.5% → 36.7% | 1048 → 1193 |
| 5 | 66.3 → 71.2 | 0.0% → 8.2% | 675 → 761 |
| 6 | 45.3 → 46.6 | 0.0% → 0.3% | 371 → 411 |

A match runs 1402 s on average against 1422 now (+19 s, 1.4%; the 90th percentile
1531 → 1547). Pricing on the moving wall is 1.3 s of that; the rest is the shapes.
The ceilings are the owner's to move.

### Where the next zone goes

**By its real shape, wholly inside the zone before it** (#344): "the circles
still overlap when they are different shapes." The centres the next zone `D` can
take and still fit inside the current zone `Z` are

```
F       = { c : D + c ⊂ Z }                         -- Z eroded by D: convex
L(θ)    = the furthest s with c0 + s·(cos θ, sin θ) in F   -- bisected, 48 steps
offset  = √u × edgeBias × L(θ)                      -- θ = 2πU, u = U
```

`F` holds the current zone's own centre with room to spare, because each zone
is drawn to fit inside its predecessor concentric at the ratio of their radii
(below). `√u` is what `pointInDisc` applied: uniform over `F` when `F` is a disc,
so the zone path does not cluster toward the centre. The draws are the same two
values `pointInDisc` took, in the same order, so the stream stays aligned.

Because a zone is fitted by its real outline rather than its circle, it has less
room to move than a circle of the same radius had — measured over 1000 matches,
the mean offset of a nested phase is 0.13–0.27 of the current radius at phases
2–7, against 0.25–0.40 in the circle era.

**Breakout.** With a probability that ramps by phase, the next zone may leave the
current one entirely, with the gap between the two SHAPES capped:

```
chance(phase) = lerp(0%, 85%, (phase − 1) / (phases − 1))
F_b           = { c : gap(Z, D + c) ≤ gapMax × curRadius }   -- when it fires
gap(Z, D + c) = signed distance from c to Z ⊕ (−D)            -- a corner list
```

`gapMax` is 0.5, so the two zones may separate by up to half the predecessor's
radius. `F_b` contains `F`, so a breakout roll still lands nested 6–11% of the
time at phases 2–7. This is safe only because the wall **sweeps**: damage comes
from where the wall is, and a phase that rolled a breakout gets its shrink ceiling
multiplied by `shrinkFactor` (2.5) so the run is one people can make.

Two earlier formulations were wrong in instructive ways — scaling the budget by
the *next* radius made the final phase (radius 0) unable to move at all, and
scaling by the *current* radius could never separate the early circles. Stating
the geometry we wanted removed both accidents.

**The last phases hug the edge**: the offset is at least `L(θ) − edgeHugM`.
**The map bounds** clamp the centre so the next zone's exact bounding box stays
inside `mapAABB` (an axis it is wider than is centred), and if that moved it out
of the phase's region it is walked back toward the current centre to the last
point inside — the phase's budget beats bounds, because the sweep was priced off
where the solver put it.

### And never into the sea

A drawn centre that lands in authored water is walked back along its own
bearing toward the previous centre, which is dry by induction from the anchor.
Without this, 210 of 600 sampled draws off a coastal centre landed in open
water. The region a centre is drawn in is convex and holds the previous centre,
so every step back is still a zone wholly inside its predecessor.

### The shape of the wall

Since #344 the wall is **not a circle**, and since 2026-09-23 every zone draws
its own shape **by area**: "the storm is still too circular. let's draw it by
area now instead of any consideration for a radius." A zone is the convex hull
of its corner **discs**: a rounded vertex is one disc, a beveled vertex is its
chamfer's two points, a sharp vertex is one point, and a circle zone is one disc.

```
circle      one zone in ten, one disc holding the area
corners     3 to 12, drawn per zone: 3–6 at weight 2, 7–12 at weight 1
finish      each vertex rounded, beveled or cornered, a third each
turn        the whole ring rotated by U(0, 360°)
angles      each vertex slid by up to ±9° within its slot
radii       1 + 0.13 × U(−1, 1)                  -- symmetric, then:
stretch     target S = 1 + 2u, u = U(0, 1): the ring stretched along a drawn axis
            by the area-preserving map that gets closest to S without passing it,
            S measured exactly as longest length / narrowest width, capped at 3:1
cut         a rounded or beveled vertex takes 0.5 of the shorter half-edge
area        the hull scaled to exactly 0.90 of the circle's
```

Every zone covers the same ground — 0.90 of its phase circle — so pacing does not
move with its shape. **Triangles and squares are back** ("triangles and squares
are okay with me"): the rule that removed them, no corner past 1.15 `r`, was
radius reasoning, and a zone is placed by its real outline now. Each zone is also
**chained**: zone `z` must fit inside zone `z−1` concentric at the ratio of their
radii with `fitClear` (0.04 r) to spare, and a draw that does not is turned in
15° steps, then tamed down a stretch ladder, and last of all becomes a copy of
its predecessor's shape. Zone 1 is unconstrained — every zone 1 fits inside the
map disc. Measured over 21 000 zones (3000 matches × zones 1–7):

| stretch | < 1.5 | 1.5–2 | 2–2.5 | ≥ 2.5 | median | max |
|---|---|---|---|---|---|---|
| share | 30.4% | 25.7% | 23.3% | 20.6% | 1.88 | 3.000 |

| zone | circles | stretch tamed | turned to fit | parent's shape |
|---|---|---|---|---|
| 2 | 6.5% | 17.0% | 54.7% | 3.2% |
| 3 | 8.3% | 10.4% | 54.2% | 1.3% |
| 4 | 9.4% | 4.6% | 42.8% | 0.1% |
| 5 | 8.3% | 1.2% | 32.3% | 0.03% |

Corners: 3, 4, 5 and 6 at 12.8–13.2% each, 7 to 12 at 6.3–6.8% each, circles
9.0%; finishes 33.2 / 33.4 / 33.3%. Area 0.900 exactly; the centre is at least
0.41 r deep in every zone; the furthest any corner reaches is 1.40 r on average
and 2.64 r at worst.

**Long zones are longer than the old diameters.** At phase 5 (r 260) the longest
length is 700 m at the median and 1028 m at worst, where the circle was 520 m
across; at phase 6 (r 110) 294 m median and 448 m worst, 0.4% of zones past the
424 m FiveM draws players to; at phase 7 (r 40) 107 m median, 164 m worst.

Convexity is not guaranteed by the draw and is **enforced**: a concave ring is
redrawn from values the same stream already handed out, with both jitters
lowered, and the last attempt uses no jitter at all. A hull of discs is convex
whatever the discs are. The exact signed distance and the exact erosion the
renderer depends on are only exact for a convex shape, and so is the stitch that
joins an overlapping pair. Every zone reads exactly 317 values off its stream,
whatever it decides, so a retry never shifts what comes after it.

**Each zone keeps one shape, and the wall morphs corner to corner.** Zone k is
the zone phase k closes on; it is phase k's target and then phase k+1's starting
zone, in the same shape throughout. "I don't want the destinations shape or
corners to change at all. I want the moving wall's corners and lines to move and
change to match the destination's." So every vertex of the zone the wall leaves
is paired with a vertex of the zone it closes on — by the direction each faces,
round the circle — and every disc travels in a straight line to its partner's:

```
disc(t)     (1 − t) × (source disc, placed)  +  t × (destination disc, placed)
wall(t)     hull of every disc(t)  ∪  the destination's own discs   -- nested phases
```

max(n, m) links, never n + m: a surplus destination corner opens out of one that
was already there, a surplus source corner closes onto its neighbour's partner,
and each corner's finish becomes its partner's. The destination never moves or
changes. On a nested phase the wall **holds the destination at every instant**
and **never moves outward** — a moving disc's later position is a blend of its
earlier one and a disc of the destination, both inside the earlier hull. Where the
bare corner paths would have cut into the destination, the wall rests on it
instead: measured in 34–52% of nested sweeps at phases 2–7 (the bare cut would
have been up to 374 m deep at phase 2). While it rests it wears the destination's
corners it rests on beside its own moving ones, so it can show more corners than
`max(n, m)`: one more on 17.4% of mid-sweep frames, two on 2.8%, three or four on
0.4% (10,260 frames, 150 matches) — the price of holding the destination with
straight corner paths. Arriving early instead of resting was measured at 4.2% of
frames, with corners up to ten times as fast; the owner decides. It is convex at
every `t` (a hull), and
its signed distance and erosion are the same corner list's, exact. A breakout
morphs the same way without the destination in the hull, and the safe zone is
the wall united with the destination.

**The map shows the morph without redrawing anything.** Every disc travels in a
straight line, so the moving wall is the solver's own circle times one unit shape:

```
disc(t)  =  c(t) + r(t) × [ (1 − m) a + m b ],      m = t · r1 / r(t)
wall(t)  =  c(t) + r(t) × V(m),      V(m) = hull of every (1 − m) a + m b
```

where `a` and `b` are a link's two unit discs and `c(t), r(t)` the circle
`BR.StormAt` reports. The map may not rebuild its polygons while the storm moves —
that was #350's hitch — but it can move, scale and fade one it already has. So the
one rebuild a phase makes, when its record arrives, draws `V(0)` and `V(1)` about
their own origin (and the destination in place), and every tick of the sweep
places both and crossfades them by `m`: exact at the two ends, a blend in between.
Each is placed where it is true — the largest copy of itself the wall holds, with
`V(1)` grown about the destination's centre so it always holds the destination —
so the fill is never past the wall by more than half a metre, and a keyframe the
destination pokes out of hands most of its alpha to the next one up that holds it,
so the keyframe shown most holds the destination to 23 m at worst. The cost is
fill that stops short of the wall mid-sweep: 310 m on average at phase 2 at one
pair, 44 m at eight. `overlay.keyframes` adds more `V(k/K)` during the hold, never
while the storm moves or a conjoined zone grows (config/storm.lua has the table).
The sweep's end needs no rebuild, because `V(1)` on the destination's circle is the
destination.

### A conjoined zone grows into its destination

"If they're conjoined, today the border pops suddenly to cover the whole area.
Instead it should grow over a period of 20s." On a breakout whose destination `D`
overlaps the zone `Z` the wall stands in, the safe zone across the hold's first
`grow.seconds` is

```
S     = max over D's discs of ( sd_Z(centre) + radius )     -- how far D reaches outside Z
g     = clamp( elapsed / min(grow.seconds, hold), 0, 1 )     -- BR.StormAt's eighth answer
G(g)  = Z  ∪  ( D ∩ Z grown by g·S )
```

Growing a convex corner list adds to every corner's radius; the intersection of
two convex shapes is the corner list of their boundaries' runs inside each other;
and the union is the stitch every breakout already uses — so the damage tick, the
HUD and the wall bill, read and draw `G` exactly, off one clock. It starts as `Z`
and ends on `Z ∪ D`, and only ever grows. A destination wholly apart from the zone
still appears at once. The map shows `Z` under the destination's own fill for
those twenty seconds: drawing the front would be a rebuild on a motion cadence.
Once the zone stands still it shows the union `Z ∪ D` as the zone's fill, with the
destination over it, as a static breakout hold always was — drawn at the phase's
one rebuild and shown by alpha, so the old zone's edge does not run across the
destination for the rest of the phase.

**What airdrop siting stands on changed with it.** The wall's support function
used to be affine in `t`, which made "clears both ends of the window, clears every
instant in it" a theorem. A hull of moving discs is not affine in `t`; on a nested
phase the stronger statement holds instead — anything inside the destination is
inside the wall at every instant — and on a breakout the destination entry keeps a
crate inside what the damage tick bills at every instant.

**The shape is derived, not sent.** The record carries the match's storm seed
and the phase index; the client's wall and the server's damage tick both build
both zones' shapes — circle, corner count, stretch and every vertex's finish
included — from those numbers through one shared function. Nothing about the
geometry crosses the wire (but for a frozen or re-entered record's own outline,
`mo`, on the dev commands), and a wall drawn from a different derivation than the
one being billed would be a lie with no bound on its size.

This section used to list two costs of the shapes. Both were paid off and
validated in game on 2026-09-23, and are kept here as history so nobody
re-derives the dead ends:

* **the map used to draw a circle.** No GTA native fills an arbitrary outline,
  so the rings were radius blips at `r`, over-reporting by about a sixth of `r`
  where the shape dents in. The vendored `MINIMAP_LOADER.gfx` turned out to
  carry `ADD_AREA_OVERLAY`, which fills a real concave polygon on both the radar
  and the pause map (#347, #350). A moving zone is never rebuilt: its keyframes
  are moved, resized and faded in place (above), a breakout's included, since the
  moving union is shown as the moving zone under the destination's own fill rather
  than as one polygon; the union itself is shown only while it stands still. The nominal-radius map blips carry the map for the rest of a
  sweep whose placement or fade the engine refuses, and for a client whose
  overlay never becomes ready.
* **an overlapping breakout used to draw both boundaries**, showing curtain
  inside the safe zone. Two convex shapes that overlap have a union whose
  boundary is one loop, alternating between runs of each outside the other;
  `blobUnion` finds every crossing by intersecting the two boundaries' runs and
  arcs outright and joins the outside runs into that loop (#356). Two copies of
  one shape cross exactly twice, and two different zones' shapes can cross four
  or six times — 1.2% of reachable overlaps do — which is why it finds every
  crossing rather than two. The damage was always exact — a signed distance to a
  union is the minimum of the two — so this was only ever a drawing defect.

---

## 4. Loot

### How much, and where

For each of the **120** POIs — 75 tier 1, 28 tier 2, 13 tier 3, 4 tier 4 — by tier:

```
crates(tier)      = 20 | 20 | 24 | 35
floor items(tier) =  5 |  8 | 14 | 14
```

Tier 4 is the four **golden** POIs (#227): Humane Labs, Kortz Center, Great
Chaparral and Raton Canyon. Floor loot is flat against tier 3 on purpose — the
premium is paid in crates and in the rarity mix, because crates carry the loot
and floor items garnish it. 35 against tier 1's 20 is 1.75×, which puts these
four back near the 2.4× spread the tier-3 sites had before the 2026-08-05
flattening; that is the point of them, and there are four rather than fourteen.

Plus 420 roadside filler items along the authored corridors, offset 8–22 m
perpendicular to the centreline, on one side or the other, never on it.

Crates sample uniformly **by area** in `radius × 0.95`, floor items in
`radius × 0.97`. The crate figure used to be 0.75, which is only 56% of the
area — and that is what read as "clustered in the middle".

A rejected point retries by **shrinking toward the centre**:

```
radius(attempt) = radius × spread × lerp(1.0, 0.15, (attempt − 1) / 11)
```

Re-rolling the same disc just draws the sea again for a coastal POI. Walking
inward always terminates, because a POI centre is on land by definition.

### What is in it

Crates and the floor roll on **different tables**:

```
crate kind ~ weighted(weapon 55, ammo 18, consumable 21, throwable 6)
floor kind ~ weighted(ammo 74, weapon 16, consumable  6, throwable 4)
```

Bandages and med kits are `chestOnly` and cannot spawn loose at all. A crate
holds **2–4 items weighted 1:2:1**, so three is typical and it is never empty.
Crate weapon rolls have a **12%** chance of producing melee instead of a firearm
(`meleeChance`), and melee is crate-only — a machete on the roadside is a
consolation prize.

> **Both of the crate numbers above were the pre-#127 ones: `weapon 34 … 8` and
> an 18% melee chance.** They are one change, not two, and that is why they were
> wrong together. `meleeChance` is a fraction of the *weapon* rolls, so it is
> coupled to the kind weights: leaving it at 0.18 while weapon went 34 → 55 would
> have taken melee from 6.1% of crate items to 9.9% — a 62% increase in machetes
> arriving inside a change whose entire purpose was "more guns". 0.12 of the new
> weight lands it back at 6.6%.

### Rarity

```
rarity ~ weighted(RarityWeights[tier])
item   ~ uniform(bucket[rarity]), walking DOWN if that bucket is empty
```

| Tier | Common | Uncommon | Rare | Epic | Legendary | Rare+ |
|---|---|---|---|---|---|---|
| 1 | 55 | 28 | 13 | 3 | 1 | 17 |
| 2 | 40 | 30 | 20 | 8 | 2 | 30 |
| 3 | 25 | 28 | 27 | 15 | 5 | 47 |
| 4 | 14 | 23 | 30 | 23 | 10 | 63 |

Crate contents roll at `min(tier + 1, 3)` — one tier hotter than the ground
around them, which is what makes crossing open ground for one worth the
exposure. **Tier 4 is the exception: it reads row 4 directly and is not
bumped.** The clamp is why. It stops at 3, so `tier + 1` at a tier-4 POI lands
back on row 3 and a golden crate rolls what a tier-2 crate already rolls;
raising the clamp to 4 instead would hand row 4 to every tier-3 POI as well.

The row 4 numbers are the owner's, 2026-09-08, and the ladder is the point of
them: rare-or-better runs 17 → 30 → 47 → 63 and legendary 1 → 2 → 5 → 10.
**Legendary doubling from tier 3 is deliberate, not a typo.**

Measured through the generator, 300k crates per tier — well under the raw
weights, because ammo is always common, melee stops at uncommon, consumables
have no rare band and throwables have no legendary one:

| Tier | Item rare+ | Item legendary | Crate glows rare+ | Crate holds a legendary |
|---|---|---|---|---|
| 1 | 18.4% | 1.39% | 45.1% | 4.1% |
| 2 | 29.8% | 3.48% | 64.2% | 10.1% |
| 3 | 29.8% | 3.48% | 64.2% | 10.1% |
| 4 | 41.2% | 6.95% | 78.1% | 19.3% |

Tiers 2 and 3 are identical because both clamp to row 3: what separates them is
the crate count, not the mix. Map-wide the change costs 2456 → 2512 crates and
813 → 837 floor items.

---

## 5. Damage

Every figure here is recomputed **server-side** from our own tables. The
client's reported damage is evidence of intent, never an input.

```
damage = weaponDamage
       × rarityMultiplier
       × rangeFalloff
       × bodyPartMultiplier
```

### Range falloff

Linear over the back half of the weapon's range, floored at 55%:

```
if distance > maxRange / 2:
    falloff = lerp(1.0, 0.55, (distance − maxRange/2) / (maxRange/2))
```

### Body parts

| Part | Multiplier |
|---|---|
| Head | 2.3 |
| Neck | 1.8 |
| Chest / upper torso | 1.0 |
| Lower torso / pelvis | 0.95 |
| Hips | 0.80 |
| Shoulders | 0.75 |
| Upper arms / legs | 0.65 |
| Elbows | 0.55 |
| Wrists / feet | 0.50 |

2.3 is arithmetic, not taste. Health is 100, so "two headshots to kill" means a
headshot must land in (50, 100]:

```
Mini SMG   23 × 2.3 = 53      Carbine        32 × 2.3 = 74
Pistol     26 × 2.3 = 60      Military Rifle 42 × 2.3 = 97
```

The weapons that break the rule are the ones that should: revolvers, shotguns
and snipers, all of which hit for 60+ to the chest before any multiplier.

**Headshots also fall off with range**, so a cross-map SMG headshot is not a
delete:

```
headMult(d) = lerp(2.3, 1.25, clamp((d − 30) / (120 − 30), 0, 1))
```

Snipers are unaffected in the way that matters — they one-shot centre mass
through raw damage at any range.

### Going down

Squads only, and only while a squadmate is ALIVE, FREEFALL or GLIDE — a mate on
canopy can land and pick you up, a mate already down cannot, so the last knock of
a wipe is a death rather than four bodies waiting out four timers.

```
bleed(n) = max(dbnoBleedMin, dbnoBleedBase + dbnoBleedStep × (n − 1))
         = max(40, 120 − 21 × (n − 1))          seconds

  knock   1     2     3     4     5     6
          120   99    78    57    40    40   (floor)
```

`n` is per **match** and is wiped at CLEANUP.

| Quantity | Value | Notes |
|---|---|---|
| First knock | 120 s | Was 45 s. "The DBNO bleed out timer seems awfully short… 2 minutes minimum" |
| Step per later knock | −21 s | |
| Floor | 40 s | |
| Revive hold | 2.8 s | Was 8.0 s, cut 65% on the owner's call. **The only place this number exists** — the server measures against it, the client sends it to the prompt as `holdMs`, and the ring's CSS `animation-duration` comes from that message and nothing else |
| Revive range | 1.5 m | +1.0 m slack on the server's own check, for the same 4 Hz sampling skew the loot claim allows |
| Revive heartbeat | 750 ms | The client re-asserts every 250 ms; three misses drops the hold. One lost stop message once handed out a completed hold for a brief tap |
| Health on getting up | 30 | Display units, no shield |
| Ledger health while down | 5 | Must be above zero, or the shooter never gets the correction that stops a downed player reading as a permanent corpse, and the roster's own sampling eliminates the body |
| Seconds off the clock per damage | 0.93 | |
| Crawl | 0.55 m/s, 90 °/s | Real units, because no downed animation in this build is a locomotion clipset — the ped is driven by hand |

**The three bleed numbers are one shape, not three values.** When the base went
45 → 120, the step went −8 → −21 and the floor 15 → 40, so the curve is identical
in proportion and only the units changed. Raising only the base would have
flattened it: at −8 a second knock cost 18% of a 45-second bleed and would have
cost 7% of a 120-second one — the same table describing a different rule.

**`dbnoBleedPerDamage` is tuned against a round count, not against seconds.** The
property it holds is "about four rifle rounds finish a fresh knock, a shotgun
blast takes roughly a third of it". It had to move 0.35 → 0.93 with the base, or
the same four rounds would have taken 42 s off a two-minute clock and finishing
somebody would have needed eleven of them — at which point nobody shoots a downed
player at all. Tune it against the round count.

**The clock stops while a revive is genuinely progressing**, and that is the only
thing that moves the deadline forward. Damage moves it back; letting go simply
stops it.

### Getting up after the clock has run out

Running the bleed clock out is no longer the end of a squad player's match
(#219). The moment they go to spectate, their inventory spills as an ordinary
death box and a **revive key** is minted at the same point — one edge, one call
site, so a squadmate who reaches them during the bleed-out leaves no key and
they keep their kit, with no branch written anywhere to say so.

The key is an entitlement **held by the squad** and recorded on the *eliminated*
player's roster entry. It is not an inventory item, so none of these numbers is
a slot cost.

| Quantity | Value | Notes |
|---|---|---|
| Collect range | 2.5 m | +1.0 m slack on the server's own check, the same allowance the revive range takes |
| Pickup lifetime | 180 s | Retires the **world pickup only**. The entitlement it stood for stays purchasable for the rest of the match, which is what makes revives unlimited if a squad can pay |
| Price | 25 Volts | The owner's number of 2026-08-30, superseding the 150 in #219's body. One purchase covers **every** key the squad has outstanding, and the set is re-read *after* the charge lands, so a mate eliminated during the DynamoDB round trip is covered by the price already paid |
| Revive hold | 6.0 s | At an ambulance, not at the body — more than twice the 2.8 s a pick-up off the floor costs |
| Reach | 6.0 m | +2.0 m slack. **One radius for both gestures**: buying and reviving ask "am I at this van" of the same player at the same vehicle, and a second value would be a second answer free to drift |
| Health on arrival | 100 | Full, against 30 for a revive at the body. The owner's call: a key costs a death, a spilled inventory and a drive, so it does not also cost you the fight you land in |
| Arrival height | 150 m | Above the van. They come back **falling**, not standing up beside it |

**The two ways back are priced against each other, not independently.** A pick-up
off the floor is free, quick, and keeps the player's inventory; the key costs a
death, a spilled inventory, a fetch across the map or 25 Volts, and a hold more
than twice as long. That is the asymmetry the design rests on — the cheap path
is the one that rewards a squad for reaching a mate in time — and the health is
the one row deliberately pointing the other way: the owner overturned an earlier
30 with "the player should come back with full health" precisely because a key
revive is *not* the same act as a pick-up and should not also cost the fight
you land in.

**The two ranges are the exception and are more generous, not less.** Both are
wider than the DBNO revive's 1.5 m, and neither is part of the cost. The 6.0 m
is measured **to the ambulance** — a van is a bigger thing to stand next to than
a ped, and it is one radius answering "am I at this vehicle" for the purchase and
the revive alike, because a second value would be a second answer to one question
and free to drift. The 2.5 m is to the pickup lying on the ground, which is an
easier thing to stand over than a body somebody is still shooting at.

**The 23 station ambulances are what make the reach number usable.** They stand
at surveyed points from the moment the bus doors open, and every one of them is
put on the squad's map the instant a mate reaches OUT — the trigger is that state
alone, deliberately, because blips during a bleed-out point at something nobody
can act on.

### When a refused shot becomes a case

A refused shot is arithmetic too, and the numbers are small enough that getting
them wrong in a document is worse than omitting them. The bar is **per reason and
per match**, and the count does not lapse — it resets when the match does:

| Tier | Bar | Reasons |
|---|---|---|
| `high` | **1** | `NOT_HELD`, `NO_AMMO`, `NOT_THROWN` |
| `high` | **2** | `NO_WEAPON` — same severity, higher bar, via `BR.ShotBarOverride` |
| `normal` | **2** | `TOO_FAR`, `TOO_FAST` |
| — | — | `SELF` — refused, logged, and counted toward nothing |

```lua
BR.Config.Combat.refusalBar      = { high = 1, normal = 2 }
BR.Config.Combat.refusalWindowMs = 10000
```

**`refusalWindowMs` is not a threshold input and decides nothing.** The summary
line on an incident reads "N shots refused in Ms" and this is the M. It is the
only thing left of the rolling window the bar used to live in.

> **Several places still describe this as "a dozen refusals in thirty seconds",
> and every one of them is wrong.** That was the first calibration, chosen before
> anything had been measured. It became 8-in-10s on 2026-08-08 and then stopped
> being a window at all on 2026-08-14, when the owner's verdict was that "we don't
> want a system that virtually never creates incidents" — eight of anything inside
> ten seconds describes somebody spraying with a trainer and misses somebody
> patient. The stalest copy is the comment above `BR.ShotSuspicious` in
> `br_lib/shared/combat_solve.lua`, which is a *code* comment sitting directly on
> top of the table the live rule is keyed against.

`selfLimit` is **2** over `selfWindowMs` **5000**, so the third self-inflicted hit
inside five seconds is refused. It is graded by nothing: at a bar of one or two,
counting it would let one self-hit beside one marginal out-of-range shot open a
case, and a player could manufacture that against themselves.

The reasoning behind all of this — which refusals are *rules* and which are
*means*, and why only the second kind counts — is in
[Cheat resistance](security.md). This section is only the numbers.

### Health units

Two scales, and mixing them is the likeliest source of a subtle balance bug:

- **Engine** 100–200, where **100 means dead**. What `GetEntityHealth` speaks.
- **Display** 0–100, what players see and what every config number uses.

Convert only at the boundary, with `BR.ToEngineHp` / `BR.ToDisplayHp`.

---

## 6. Everything else, in one table

| Quantity | Value | Notes |
|---|---|---|
| Max players | 48 | The free OneSync ceiling |
| Squad size | 4 | `minSquads` 2, so a match needs somebody to fight |
| Warmup | 45 s | 15 s once the lobby is full |
| Sprint | 7.8 s | Drain 12.82/s, regen 25/s after a 900 ms pause |
| Position sampling | 4 Hz | Which is why every range check carries slack |
| Roster delta flush | 4 Hz | |
| Digest | 2 Hz | The self-healing heartbeat |
| Client loops | 60 / 10 / 1 Hz | frame, tick, slow |
| Loot cell | 256 m | 3×3 subscription = 768 m |
| Loot props | 90 m | Subscription is cheap; objects are not |
| Assist window | 10 s | Storm damage still credits whoever shot you |

---

## Where these live

| Numbers | File |
|---|---|
| Players, timings, health, ambient, combat, body parts | `br_lib/config/match.lua` |
| Storm phases, anchor band, breakout, pacing | `br_lib/config/storm.lua` |
| Weapons, rarity, ammo caps, melee | `br_lib/config/weapons.lua` |
| Loot budgets, crates, consumables, drag, labels | `br_lib/config/loot.lua` |
| POIs, roads, water, door zones, bus routes | `br_lib/config/map.lua` |

The solvers that consume them are pure and tested outside the game:
`br_lib/shared/storm_solve.lua`, `loot_gen.lua`, `combat_solve.lua`, `geo.lua`.
