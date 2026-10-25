# The data center's main gate

Season 2's campus front gate (#415) opens from its readers (#420). Three
lanes, each a crash arm, an outer bi-fold gate, a trap and an inner bi-fold
gate, with a red reader at the curb outside the outer gate and inside the
inner one. Each lane is a sally port: a press at a reader opens the gate
nearest it, that gate shuts behind whoever came into the trap, and only then
does the other one open. This page is the contract: the registry and its
zones, the press, the sequence, the fold and the engine questions still open.

[← Back to the main README](../README.md)

---

Five pieces, a file each.

| Piece | Where | Its job |
|---|---|---|
| **The registry** | `br_lib/config/dcgate_parts.lua` (generated) | The three lanes: four leads, four followers and an arm each, the lane's box, and the six lane readers. Read by both sides. |
| **The numbers** | `br_lib/config/dcgate.lua` | The fold, the sequence's times, the reader's reach, the server's door, the zones' margins, the client's radii and drives. |
| **The shared rules** | `br_lib/shared/dcgate_solve.lua` (`BR.DcGateSolve`) | The reader a player is at, "is this point in the lane", the pose and its ease, the bi-fold's counter-rotation, each lane's zones, who is in them, the sally port's sequence, the wire's lane code, the door's name. Pure. |
| **The server** | `br_core/server/dcgate.lua` (`BR.DcGate`) | This match's lanes, the door a press comes through, the pass that moves each cycle on, who is told, the snapshot's view, `brgatesv`. |
| **The client** | `br_core/client/dcgate.lua` | The 27 doors registered and locked, the prompt, the press, each gate's fold, the read-back. Decides nothing. |

**The server decides every lane.** A client only says "open the gate of the
reader I stand at"; the server checks that the player is in a match under
way (the bus still flying, or playing), standing, at that reader by its own
position sample and not in a trap, and that the lane's cycle is not already
running, then tells the whole match. Every gate after that opens and shuts by
who the server sees where. Clients animate.

**Season 2 and later**: one row, `dcgate = { from = 2 }` in
`br_lib/config/seasons.lua`, asked only as `BR.Season.has('dcgate')`. Off, no
prompt shows and nothing opens. The gate stays shut and locked in every
season, as the map pack kept it.

## The owner's decisions

2026-10-19:

- Standing at a lane's reader shows the prompt **"Press E to open the gate"**.
- Server-authoritative per match (its routing bucket); clients animate.
- The fold: the lead leaf turns 0-90 degrees about its post hinge, and the
  follower rides on the lead's free edge and counter-rotates (the gate kit's
  `kit_gate_doors.json`).
- The gamemode registers, locks and opens the main gate's 24 leaves and 3
  arms; br_datacenter stops locking them in the same publish. B3's
  construction gate is unlocked in the pack (no gamemode work).
- Season 2 only. The readers work in a match only (the issue's default).
  **No reader in the trap.**

2026-10-24, after round 1b in game (the fold works):

- **A sally port, not both gates at once.** A press at the outside reader
  opens only the outer gate and raises the arm; a press at the inside reader
  opens only the inner gate.
- **Proximity, not a 20 s timer.** The first gate closes about 2 s after its
  swing area and approach are clear once someone is in the trap; a first gate
  nobody has come into the trap through within 10 s closes, and the cycle
  ends. The first gate fully shut with someone in the trap, the second gate
  opens; it closes about 2 s after the trap and its swing area are clear.
- **A gate never closes on a player or a vehicle in its swing area.** A press
  while the lane's cycle runs is not taken. A player in the trap with no
  cycle running gets nothing.
- **The arm is turned by hand and stays frozen in every pose** (the bug: an
  arm driven into before the press stayed down when the lane opened; and with
  the hand drive, running into a shut arm knocked it off). Every part is read
  back and posed again when it is off.

## The registry

`BR.Config.DcGate.parts`, written by `tools/dcgate_parts.py` from two files of
the map's:

- **where each part stands**: the site works' door table,
  `doors/brdc_site_doors.json` in the br_datacenter pack (every placed door
  object's id, model, origin and heading, and every reader);
- **how each part moves**: the gate kit's `kit_gate_doors.json` (the leads'
  open sense, the followers' attach offset and counter-rotation, the arm's
  raise axis, the leaf's mid-height and the arm's pivot height).

```
py tools/dcgate_parts.py <brdc_site_doors.json> <kit_gate_doors.json>                write it
py tools/dcgate_parts.py <brdc_site_doors.json> <kit_gate_doors.json> --check        is it current?
py tools/dcgate_parts.py ... --locks <br_datacenter client.lua>    and how many the pack still locks
```

The file's header names both sources and their sha256. The generator refuses
the whole table, and writes nothing, for a lane that is not lanes 1-3 with an
outer and an inner gate of `lead_l`, `lead_r`, `follow_l`, `follow_r`, an outer
arm and two readers; a model that is not the kit's for its role; a coordinate
that is not a finite number; a follower not attached to its own lead, not at
the kit's offset, not at its lead's heading or not standing where its lead's
knuckle puts it (2 cm); a pair whose counter-rotation is not -2 times its
lead's turn; a gate that does not fold away from the trap; and, with
`--locks`, a part the pack's `DOOR_LOCKS` lists with another model or more
than 1 cm away.

**The lane's box** is computed, not drawn: along the lane from the crash arm's
beam (0.25 m past its pivot line) to the inner gate's fold (the knuckle,
1.065 m past the inner posts), across it post to post, and from the lowest
grade under its parts to the highest. Both readers stand outside it.

### The zones

`BR.DcGateSolve.laneZones`, from the registry at run time: every zone is a
strip of the lane's box, post to post at its grade, and none is a typed
coordinate.

| Zone | From | To | Derived from |
|---|---|---|---|
| **the trap** | the outer gate's line | the inner gate's line | each gate's two lead hinges |
| **the outer swing** | the outer gate's line | past the arm's beam to the box's end (2.26 m out) | the leaf's length (the followers' knuckle offset) to the side the leads fold to, the arm, the box |
| **the outer way** | the outer gate's line | the outside reader (5.0 m out) | the swing, and the reader's position |
| **the inner swing** | the inner gate's line | the leaf's length into the campus (1.07 m) | the leaf's length, the fold side |
| **the inner way** | the inner gate's line | the inside reader (2.5 m in) | the swing, and the reader's position |

A gate folds away from the trap, so the trap and the swings meet at the gate
lines and never overlap. The arm comes down with the outer gate, so its beam
is in the outer swing. Each reader opens first the gate it stands beyond (the
outside one the outer gate, the inside one the inner gate), and neither is in
a trap.

**Who is in a zone**: a player standing or downed in the match whose sample
(no older than `lane.sampleMaxAgeMs`, 3 s) is in it grown by
`lane.pedMarginM` (0.5 m); a vehicle of the match's routing bucket whose
center is in it grown by `lane.vehicleMarginM` (2.5 m, a car's half-length, so
a bumper under a leaf counts) along the lane and `lane.vehicleSideM` (1 m, a
car's half-width) across it: the leaves fold inside the posts, so a car parked
beside the lane, on the island between two, is in none. Both from
`lane.belowM` under the grade to `lane.aboveM` over it, so a helicopter over
the gate is in nothing. **Every vehicle counts in a swing or a way**, driven
or not: a car left parked in a swing holds that gate open for as long as it is
there. **The trap holds players only** (the owner's "the trap holds
someone"): a driver counts by their own sample, and an empty or wrecked car
left in a trap holds nothing, so it cannot keep that lane's second gate open
and its readers refusing for the rest of the match.

## A press

### The prompt

`client/dcgate.lua`, a TICK callback registered only within `client.promptM`
of the gate. While this player stands within `readerM` (3 m, flat) and
`readerZM` of a lane reader, in a match under way, ALIVE, on Season 2, with
none of our screens up, not in a trap, and that lane's cycle is not running,
the notice stack shows, sticky and silent:

> Press **[E]** to open the gate

The owner's words. The E is a `BR.KeyToken('brinteract')` hole the page draws
as a key cap of the player's own interact binding, as `client/skydive.lua`'s
"Press {key} to pull your chute!" and the big map's notice are
(`tools/check_key_glyphs.lua` holds this file to it). GTA's `~INPUT_CONTEXT~`
glyph is not used: it draws GTA's context key, which is not the key the press
is read from. The prompt is sent once as it comes up and taken down the moment
any of those stops being true.

**No reader in the trap**: a spot in the trap just inside the inner gate is
within `readerM` of the inside reader, so a player in a trap is at no reader,
on the client and on the server.

### The server's door

`RegisterNetEvent(BR.Net.DCGATE_USE)`, `{ reader }`. Every refusal is a silent
drop, counted per reason on the match (for `brgate list`), in this order:

1. **season**: the gate on in the season in force.
2. **shape**: `reader` a whole number naming one of the six lane readers.
3. **rate**: no sooner than `use.minIntervalMs` (0.5 s) after this player's
   last press, and `use.perMatch` (120) a match at most. The client asks at
   most once per `client.askMs` (1 s), twice the server's interval, so network
   jitter never drops a retry.
4. **match**: the player is in a match, and it is under way: BUS or PLAYING.
   A player who jumps early is on the ground, ALIVE, before the match goes
   live.
5. **player**: ALIVE, by the roster.
6. **reach**: by the server's own sample, no older than `use.sampleMaxAgeMs`
   (1 s), within `readerM` flat and `readerZM` of **that** reader, each plus
   `use.reachSlackM` (3 m: the 4 Hz sample of a car rolling up trails the
   client), and in no lane's trap.
7. **busy**: the lane's cycle is not running.

Then the cycle starts: the gate the reader stands beyond opens,
`DCGATE_STATE` goes to the whole match, and one console line:
`[br_core] dcgate: lane 2 outer gate open by NightOwl (12) at
gate.lane2.reader_in in match 4`.

## The sally port

`BR.DcGateSolve.advance`, a pure state machine, one lane at a time; the
server's pass (`BR.DcGate.pass`, every `lane.checkMs`, 500 ms) feeds it who is
in the lane's zones for every lane whose cycle runs, in every match under
way.

| Phase | The gates | Moves on when |
|---|---|---|
| **idle** | both shut | a press at a reader: its gate opens first -> **first** |
| **first** | the first gate open (inbound: the outer gate and its arm; outbound: the inner gate) | once it is fully open (`foldMs`): someone in the trap and its swing and approach (its way) clear for `cycle.closeDelayMs` (2 s) -> **firstShut**; or nobody in the trap `cycle.abandonMs` (10 s) after it opened and its swing clear for 2 s -> **firstShut** (the cycle will end) |
| **firstShut** | the first gate folding shut | anybody in its swing -> **first** (open again); fully shut (`foldMs`) with someone in the trap -> **second**; with nobody -> **idle** |
| **second** | the second gate open | once it is fully open: the trap and its swing clear for 2 s -> **secondShut** |
| **secondShut** | the second gate folding shut | anybody in its swing or the trap -> **second** (open again, so nobody is shut in); fully shut -> **idle** |

- **A gate never closes on anybody in its swing.** A first gate stays open
  for as long as a car is parked under its leaves or its arm, and a gate
  folding shut opens again for anybody who steps or drives into its swing.
- **A clear spell is counted from no earlier than the gate standing fully
  open**, so every gate stands open for at least 2 s, and a player who pressed
  on foot has the fold and 2 s to walk in even if somebody was already in the
  trap.
- **The approach holds only a first gate with someone in the trap**: a car
  waiting at the outside reader keeps the outer gate open for it while the
  car ahead is in the trap, but a presser who walks away does not hold an
  empty cycle past its 10 s.
- **A press during a cycle is not taken**, at any phase, until its last gate
  is fully shut.
- **A player dropped in the trap** (no cycle running) gets nothing: no reader
  is in reach from it. Somebody else's cycle lets them out (a first gate that
  shuts with them in the trap opens the second).
- **A match that ends mid-cycle** is left as it is: its cycles are not moved
  on and it is told nothing more; the clients shut every gate in the lobby,
  and the next match starts with every lane idle.

Each change is one console line, e.g. `[br_core] dcgate: lane 2 in match 4:
outer gate shutting behind a player in the trap`.

**Why the server and not client reports.** A closing gate has to know about
everybody: a player nowhere near a client that could report them, a car nobody
sits in. A client's report is a claim about itself, and a modified client
could hold a gate open from across the map or never report the car it parked.
The server already has both answers: every player's 4 Hz position sample
(`server/roster.lua`) and, under OneSync, every vehicle's position and routing
bucket (`GetAllVehicles`, the pool `server/terminalfx/airstrike.lua` reads).
The pool is read once a pass, only while a cycle runs somewhere, and only the
vehicles of a running match's bucket have their position read.

**The state is the match's**: `m.dcgate = { lanes, rate, refused }`, each
lane `BR.DcGateSolve.newLane()` (its phase, its first and second gate, and
each gate `{ open, at, from }`), made on first use and gone with the match.
Off Season 2, the pass forgets it (every client shut its gates itself).

## The doors and the fold

### Registered and locked, the pack's way

At load, if the pack's models are in the build (asked again every ten seconds
while they are not), every one of the 27 parts is registered with the door
system **under the pack's own names** (`brdc_door_<id>`, the pack's
`DOOR_LOCKS`), locally (no door events are sent), and locked shut the pack's
way: the open ratio to 0, state 4 (forced shut this frame), then 1 (held).
Using the pack's names means a pack that still registers a part and this file
hold one door between them, not two. A registration a stopped pack took is
registered again on the next pass near the gate.

### Posed as it streams in, and read back

What a part shows is a function of its gate's pose (0 shut, 1 open) and
nothing else. Within `client.nearM` of the gate the SLOW pass reads each
door's physics (`DoorSystemGetIsPhysicsLoaded`) and poses every door whose
physics streamed in: a gate open since before this client came near arrives
open, its followers found and attached.

**The read-back.** Every lead and arm of a gate at rest is read back by its
drive's own read, each pass: a `ratio` part by `DoorSystemGetOpenRatio`
(more than 0.02 off its pose), a `rotate` part by `GetEntityRotation` (more
than 2 degrees off, either Euler spelling of the same turn accepted, or not
frozen). One that is off is posed again (its whole gate, followers ridden); one
still off on the next pass has its door registered again first, once. This is
what caught the owner's bug: an arm driven into before the press read ratio
0.000 at pose 1.00, and nothing read it back. A pass that finds every part
where it should be calls nothing but the reads.

**What the read-back cannot promise for a `ratio` part.** The old fold sent
the arm's open ratio every frame for its whole 4 s, and the arm still read
0.000: a part a car has hit may not hear its ratio at all, so posing it again
does not help, and only the registration on the second pass might (not yet
seen in game). If it does not, that part is posed again every pass for as long
as it is off, which costs a few calls a second and does nothing. The leads are
`ratio` and locked shut as the arm was when it broke; if a lead driven into
before the press stays shut, `brgate drive lead rotate` is the fallback (it
also folds the leaves flat at 90).

### The fold

Each gate folds by itself. When a gate near this client changes, its parts are
found (`GetClosestObjectOfType` at their placed origins, once) and a FRAME
callback folds it: the pose moves a whole fold per `foldMs` (4 s) and every
angle is read through an ease, so the fold starts and stops gently and a fold
turned back runs back from where it is.

- **A lead** turns `sense * foldDeg * ease(pose)` about its hinge (its
  origin), `sense` +1 for `lead_l` and -1 for `lead_r` (the kit).
- **A follower** is attached to its lead at the knuckle
  (`AttachEntityToEntity`, bone 0, the kit's offset, with collision) and turned
  **-2 times its lead's turn as the lead stands now** (its heading against its
  placed heading), so it mirrors its lead about the gate line at every frame.
  It is unlocked while it rides, and let go, put back at its placed origin and
  heading, **frozen there** and locked again once its lead is shut (it is
  unfrozen again as it is attached for the next fold).
- **The settle.** Once a gate's pose stops, its followers are ridden on until
  no lead has turned for 5 frames running (at most 300 frames), so a lead the
  door system eases to its ratio over many frames is tracked all the way, and
  a shut gate's followers are not let go while their leads still turn. As a
  backstop, the SLOW pass rides a gate's followers again when one is more than
  1 degree off -2 times its lead's turn as the lead stands.
- **The arm** is the outer gate's: it rises `armRaiseDeg * ease(pose)` (85
  degrees) with it.

How a lead and the arm are moved is `client.drive`:

| Drive | How |
|---|---|
| `ratio` (the leads) | The door system's own open ratio, held locked: `DoorSystemSetOpenRatio(sign * deg / ratioDeg)` then state 1. The engine's way of holding a door ajar. |
| `rotate` (the arm) | The handle frozen the moment it is found and turned by `SetEntityRotation` (order 2; the arm about its local +y by -raise), **frozen in every pose, shut included**, never unfrozen while this client drives it. Its door is locked shut while the part is shut and let go (state 0) while it is turned, and it is frozen again on every drive, after that change of state: the freeze is the engine's, and this file's flag cannot see it cleared. |

**Why frozen in every pose.** A door entity turned by `SetEntityRotation`
loses its hinge (owner, 2026-10-24: with the old hand drive, which unfroze the
arm and handed it to the door lock once it was shut, running into the bars
knocked them off). Frozen, a part is solid: cars stop against it and it cannot
fall. The same holds for a `rotate` lead (`brgate drive lead rotate`) and for
a follower put back where it was placed. A part only goes back to the door
system -- put at its placed rotation, unfrozen, locked shut -- when br_core
stops or `brgate drive` switches its kind back to `ratio` (a dev switch: an
arm handed back after it was turned can be knocked loose again, as before). A
copy that streams out and back is the map's own, hinged, and is found and
frozen on the next pass.

**81 degrees, not 90** (round 1b, `brgate near`: the leads at ratio 1.000,
turned 81). That is not this file's numbers: `foldDeg` 90 over `ratioDeg.lead`
90 asks the door system for ratio 1.0 at full open, the most it can be asked,
so 81 is the door's own limit at 1.0. The followers are read from where the
lead really is, so they mirror it at 81 too, but the pair is then an 18 degree
V rather than flat: each follower's free end stands about 0.33 m in from its
post on the gate line, a clear width of about 3.5 m in a 4.2 m lane.
`ratioDeg.lead = 81` would make the angles on the way true (it cannot get past
81); `brgate drive lead rotate` turns the leads the full 90 by hand.

### Away from the gate, and stopping

Away from it nothing is driven: a gate's pose is simply its target, and the
parts are posed again on the way back. `client.nearM` is the leaves' own
draw distance (lodDist 300 m), so no client sees a leaf it is not keeping
posed. br_core stopping hands every part back to the door system: every
follower let go (back at its placed origin and heading), anything frozen put
at its placed rotation and unfrozen, every part shut and locked where it was
placed, and left registered: a gate left locked is the map's resting state.

### What it costs

Nothing per frame, anywhere, unless a gate near this client is folding. In the
lobby the SLOW pass calls nothing; without the pack, one model check every ten
seconds; away from the gate, one position a second. Within `client.nearM`: 27
physics reads, 3 registration reads, 12 open-ratio reads (the leads) and 3
rotation reads (the arms) a second, and for each open gate its two leads'
headings. Within `client.promptM`: a TICK reading this player's position. While
a gate folds (4 s): about 14 natives a frame.

## The wire

| Event | Way | Payload | Rule |
|---|---|---|---|
| `BR.Net.DCGATE_USE` | C→S | `{ reader }` | "Open the gate of the reader I stand at." Taken only through the door above; silent otherwise. Never answered: the gate, if it opens, arrives as `DCGATE_STATE`. |
| `BR.Net.DCGATE_STATE` | S→C | `{ matchId, lanes = { [lane] = code } }` | Every lane of the match, once a pass when any changes; to the whole match. A code is 1 (the outer gate open) + 2 (the inner gate open) + 4 (its cycle running): 0 idle, 5 an inbound cycle's outer gate open, 4 a gate folding shut mid-cycle. |
| `BR.Net.SNAPSHOT` | S→C | gains `dcgate = { matchId, lanes, poses }` | `BR.DcGate.viewFor`: each lane's code, and each gate's pose now (`poses[lane] = { outer, inner }`, 0-1 to the hundredth), so a late joiner or a restarted client sees each gate where it is. A client near the gate takes a pose more than 0.1 off its own and folds on from there; a client folding in step keeps its own. Nil outside a match or off Season 2. |
| `BR.Net.DCGATE_DEV` | S→C | `'<text>'` | A `brgatesv` answer, printed on F8. |

All names in `br_lib/shared/protocol.lua`.

## The numbers

`br_lib/config/dcgate.lua`, each with who decided it:

| Key | Value | Why |
|---|---|---|
| `foldMs` | 4 s | A fold each way |
| `cycle.closeDelayMs` | 2 s | Owner, 2026-10-24: "about 2 s" after a gate's zone is clear |
| `cycle.abandonMs` | 10 s | Owner, 2026-10-24: a first gate nobody comes through |
| `foldDeg` | 90 | The kit: theta 0-90, hard stop at 90 |
| `armRaiseDeg` | 85 | The kit: 85-90 is fully raised; its previews stand it at 85 |
| `readerM` / `readerZM` | 3 m / 2.5 m | A driver at the pedestal and a player on foot beside it |
| `use.minIntervalMs` / `perMatch` | 0.5 s / 120 | The door's rate: half `client.askMs` |
| `use.sampleMaxAgeMs` / `reachSlackM` | 1 s / 3 m | The presser's sample, and the reach past the client's |
| `lane.pedMarginM` / `vehicleMarginM` / `vehicleSideM` | 0.5 m / 2.5 m / 1 m | A zone grown for a player, and for a car's center along it and across it |
| `lane.belowM` / `aboveM` | 1 m / 4.5 m | Under the grade, over it |
| `lane.checkMs` / `sampleMaxAgeMs` | 500 ms / 3 s | The pass, and the samples it counts |
| `client.nearM` / `promptM` | 300 m / 15 m | Past the gate's radius: the doors kept posed (the leaves' lodDist), the prompt's TICK |
| `client.askMs` | 1 s | A press asks the server no more often |
| `client.findRadiusM` / `findsPerPass` | 0.6 m / 9 | The finds |
| `client.drive` | lead `ratio`, arm `rotate` | Owner, 2026-10-24: the arm turned by hand rises every time |
| `client.ratioDeg`, `ratioSign` | 90, 1 | A `ratio` part's angle at ratio 1.0 (the leads stand 81 there in game) |

## Dev

Dev mode only (`br_lib/shared/devgate.lua` wraps every command), Season 2 only
for the server's verbs:

| Command | Does |
|---|---|
| `brgate` / `brgate list` | This client's gates, poses, handles, frozen parts and drives, then the server's (`brgatesv list`): each lane idle or its phase, which gate, for how long, inbound or outbound, who is in its zones, and the refused presses by reason |
| `brgate near` | The lane of the nearest reader: its gates, and each part's door state, physics, open ratio, handle, frozen (the engine's own read), rotation and turn against its placed heading, and whether a follower is attached |
| `brgate open <lane\|all> [in\|out]` | Start a cycle as that reader would (the outside one by default), whoever is where (`brgatesv open`) |
| `brgate close <lane\|all>` | End a cycle: its open gate folds shut as the last, opening again on anybody in its swing or the trap |
| `brgate drive <lead\|arm> <ratio\|rotate>` | How this client moves them, until it restarts: each part of that kind handed back to the door system first |

From the server console a verb about a player takes the player id last:
`brgatesv open 2 12`.

## Engine behavior to settle on the dev box

`brgate near` prints every read these need.

| Question | Seen | Then |
|---|---|---|
| A locked door held at an open ratio stands there | Yes for the leads (round 1b: ratio 1.000) | the `ratio` drive for the leads |
| An open ratio of 1.0 turns a lead 90 degrees | No: 81 (round 1b) | the door's own limit; the followers mirror it (see the fold) |
| The arm rises by its open ratio | Not after a hit before the press (ratio 0.000 at pose 1.00) | the arm is `rotate`; the read-back catches a `ratio` part the door system dropped |
| A door entity turned by hand keeps its hinge | No: unfrozen, a hit knocks it off | every part turned by hand stays frozen |
| A frozen part turned by `SetEntityRotation` reads back the rotation it was given | not yet seen | the read-back accepts either Euler spelling of a turn; `brgate near` prints it |
| A change of a door's state, or its registration, clears its object's freeze | not yet seen | every hand-turned part is frozen after either, and `brgate near` prints the engine's own freeze (`IsEntityPositionFrozen`) |
| A follower attached to a frozen lead (`brgate drive lead rotate`) moves with it | not yet seen | the followers ride the lead's heading as it stands |
| A follower frozen where it was let go and unfrozen as it is attached again rides as before | not yet seen | the next round's check |

## The map side

br_datacenter must drop the main gate's 24 leaves and 3 arms from its
`DOOR_LOCKS` in the same publish (`py tools/dcgate_parts.py ... --locks
<client.lua>` says how many it still locks), and this must not ship before it.
The two register the same names, and they fight: the pack's one-second loop
forces shut and re-locks every door whose state is not 1, and a follower
rides unlocked (state 0), so the pack would snap the followers shut under
their leads mid-fold (and the raised arm too); its stop handler also removes
the registrations. The datacenter repo's
`blender/campus_integrate/tools/doorlock.py` already leaves the 27 out
(2026-10-19); the pack has to be built from it and published.

A car waiting at the inside reader, centered in the lane with its driver's
window at the pedestal, has its nose about 0.7 m into the inner gate's fold
(the reader is 1.43 m past the gate line, and the inner gate folds into the
campus): it is in the inner swing, so the inner gate waits for it, but the
leaves fold toward it as they open.

**Not done, for the owner to decide**: the readers stay red while a gate is
open (the kit has a green twin, `brdc_reader_g`, and green signal cabinets for
a model swap), and the guard shack's door, the pedestrian gates and the
substation and generator-yard gates stay the pack's.
