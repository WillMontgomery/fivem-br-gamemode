# The data center's main gate

Season 2's campus front gate (#415) opens from its readers (#420). Three
lanes, each a crash arm, an outer bi-fold gate, a trap and an inner bi-fold
gate, with a red reader at the curb outside the outer gate and inside the
inner one. A player at a reader presses interact and that whole lane folds
open. This page is the contract: the registry, the press, the clock, the fold
and the engine questions still open.

[← Back to the main README](../README.md)

---

Five pieces, a file each.

| Piece | Where | Its job |
|---|---|---|
| **The registry** | `br_lib/config/dcgate_parts.lua` (generated) | The three lanes: four leads, four followers and an arm each, the lane's box, and the six lane readers. Read by both sides. |
| **The numbers** | `br_lib/config/dcgate.lua` | The open time, the fold, the reader's reach, the server's door, the lane's box margins, the client's radii and drives. |
| **The shared rules** | `br_lib/shared/dcgate_solve.lua` (`BR.DcGateSolve`) | The reader a player is at, "is this point in the lane", the pose and its ease, the bi-fold's counter-rotation, the door's name. |
| **The server** | `br_core/server/dcgate.lua` (`BR.DcGate`) | This match's lanes, the door a press comes through, the clock, who is told, the snapshot's view, `brgatesv`. |
| **The client** | `br_core/client/dcgate.lua` | The 27 doors registered and locked, the prompt, the press, the fold. Decides nothing. |

**The server decides every lane.** A client only says "open the lane of the
reader I stand at"; the server checks that the player is in a match under
way (the bus still flying, or playing), standing, and at that reader by its
own position sample, then tells the whole match. Clients animate.

**Season 2 and later**: one row, `dcgate = { from = 2 }` in
`br_lib/config/seasons.lua`, asked only as `BR.Season.has('dcgate')`. Off, no
prompt shows and nothing opens. The gate stays shut and locked in every
season, as the map pack kept it.

## The owner's decisions (2026-10-19)

- Standing at a lane's reader shows the prompt **"Press E to open the gate"**.
  Pressing it opens that whole lane: both bi-fold gates fold open and its crash
  arm rises.
- The lane stays open **20 seconds**, then folds shut, but **waits while any
  player or vehicle is still in the lane**.
- Server-authoritative per match (its routing bucket); clients animate.
- The fold: the lead leaf turns 0-90 degrees about its post hinge, and the
  follower rides on the lead's free edge and counter-rotates (the gate kit's
  `kit_gate_doors.json`).
- The gamemode registers, locks and opens the main gate's 24 leaves and 3
  arms; br_datacenter stops locking them in the same publish. B3's
  construction gate is unlocked in the pack (no gamemode work).
- Season 2 only. The readers work in a match only (the issue's default).

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
lead's turn; and, with `--locks`, a part the pack's `DOOR_LOCKS` lists with
another model or more than 1 cm away.

**The lane's box** is computed, not drawn: along the lane from the crash arm's
beam (0.25 m past its pivot line) to the inner gate's fold (the knuckle,
1.065 m past the inner posts), across it post to post, and from the lowest
grade under its parts to the highest. Both readers stand outside it.

## A press

### The prompt

`client/dcgate.lua`, a TICK callback registered only within `client.promptM`
of the gate. While this player stands within `readerM` (3 m, flat) and
`readerZM` of a lane reader, in a match under way, ALIVE, on Season 2, with
none of our screens up, and that lane is not open, the notice stack shows,
sticky and silent:

> Press **[E]** to open the gate

The owner's words. The E is a `BR.KeyToken('brinteract')` hole the page draws
as a key cap of the player's own interact binding, as `client/skydive.lua`'s
"Press {key} to pull your chute!" and the big map's notice are
(`tools/check_key_glyphs.lua` holds this file to it). GTA's `~INPUT_CONTEXT~`
glyph is not used: it draws GTA's context key, which is not the key the press
is read from. The prompt is sent once as it comes up and taken down the moment
any of those stops being true.

A lane folding shut is not open, so the prompt shows again, and a press opens
it again.

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
   client).
7. **open**: the lane is not open already.

Then the lane opens: `m.dcgate.lanes[n] = { open = true, at, holdUntil =
at + openMs }`, `DCGATE_STATE` to the whole match, and one console line:
`[br_core] dcgate: lane 2 open by NightOwl (12) at gate.lane2.reader_in in
match 4`.

## The clock

`BR.DcGate.pass`, every `lane.checkMs` (500 ms), over the matches under way
(BUS or PLAYING):

- **An open lane past its 20 seconds folds shut**, unless somebody is in it.
- **A lane still folding shut** (`foldMs` after it started) **opens again** if
  somebody is in it, and folds shut the moment it is clear: its 20 seconds were
  had.
- A lane open inside its time, or shut and still, is not looked at. Nothing
  runs while every lane of every match is shut.

### Who is in the lane: the server's own positions

**A player** standing or downed in the match whose sample (no older than
`lane.sampleMaxAgeMs`, 3 s) is in the box grown by `lane.pedMarginM` (0.5 m);
**a vehicle** of the match's routing bucket whose center is in the box grown by
`lane.vehicleMarginM` (2.5 m, a car's half-length, so a bumper under a leaf
counts) past its ends and `lane.vehicleSideM` (1 m, a car's half-width) past
its sides: the leaves fold inside the posts, so a car parked beside the lane,
on the island between two, holds neither. Both from `lane.belowM` under the
grade to `lane.aboveM` over it, so a helicopter over the gate holds nothing.

A car waiting at the reader inside the inner gate, centered in the lane with
its driver's window at the pedestal, has its nose about 0.7 m into the inner
gate's fold (the reader is 1.43 m past it, and the inner gate folds into the
campus): it holds the lane, as it should.

**Why the server and not client reports.** A closing gate has to know about
everybody: a player nowhere near a client that could report them, a car nobody
sits in. A client's report is a claim about itself, and a modified client
could hold a lane open from across the map or never report the car it parked.
The server already has both answers: every player's 4 Hz position sample
(`server/roster.lua`) and, under OneSync, every vehicle's position and routing
bucket (`GetAllVehicles`, the pool `server/terminalfx/airstrike.lua` reads).
The pool is read once a pass, only when a lane is due, and only the vehicles of
a due match's bucket have their position read.

**Every vehicle counts**, driven or not: a car left parked in a lane, or a
wreck, holds it open for as long as it is there.

**The state is the match's**: `m.dcgate = { lanes, rate, refused }`, made on
first use and gone with the match. Off Season 2, the pass forgets it (every
client shut its lanes itself).

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

### Posed as it streams in

What a part shows is a function of its lane's pose (0 shut, 1 open) and
nothing else. Within `client.nearM` of the gate the SLOW pass reads each
door's physics (`DoorSystemGetIsPhysicsLoaded`) and poses every door whose
physics streamed in: a lane open since before this client came near arrives
open, its followers found and attached. A pass that finds every part already
posed calls nothing but the reads.

### The fold

When a lane near this client changes, its parts are found
(`GetClosestObjectOfType` at their placed origins, once) and a FRAME callback
folds it: the pose moves a whole fold per `foldMs` (4 s) and every angle is
read through an ease, so the fold starts and stops gently and a fold turned
back runs back from where it is.

- **A lead** turns `sense * foldDeg * ease(pose)` about its hinge (its
  origin), `sense` +1 for `lead_l` and -1 for `lead_r` (the kit).
- **A follower** is attached to its lead at the knuckle
  (`AttachEntityToEntity`, bone 0, the kit's offset, with collision) and turned
  **-2 times its lead's turn as the lead stands now** (its heading against its
  placed heading), so it mirrors its lead about the gate line at every frame
  and lies flat against it at 90. It is unlocked while it rides, and let go,
  put back at its placed origin and heading, and locked again once its lead is
  shut.
- **The settle.** Once a lane's pose stops, its followers are ridden on until
  no lead has turned for 5 frames running (at most 300 frames), so a lead the
  door system eases to its ratio over many frames is tracked all the way, and
  a shut lane's followers are not let go while their leads still turn. As a
  backstop, the SLOW pass rides a lane's followers again when one is more than
  1 degree off -2 times its lead's turn as the lead stands (a lead that moved
  after the settle).
- **The arm** rises `armRaiseDeg * ease(pose)` (85 degrees).

How a lead and an arm are moved is `client.drive`:

| Drive | How |
|---|---|
| `ratio` (shipped) | The door system's own open ratio, held locked: `DoorSystemSetOpenRatio(sign * deg / ratioDeg)` then state 1. The engine's way of holding a door ajar. |
| `rotate` | The handle frozen and turned by `SetEntityRotation` (order 2), the door unlocked while it is moved; the arm about its local +y by -raise. |

### Away from the gate, and stopping

Away from it nothing is driven: a lane's pose is simply its target, and the
parts are posed again on the way back. `client.nearM` is the leaves' own
draw distance (lodDist 300 m), so no client sees a leaf it is not keeping
posed. br_core stopping lets every follower go (back at its placed origin and
heading) and locks every part shut where it was placed, and leaves them
registered: a gate left locked is the map's resting state.

### What it costs

Nothing per frame, anywhere, unless a lane near this client is folding. In the
lobby the SLOW pass calls nothing; without the pack, one model check every ten
seconds; away from the gate, one position a second. Within `client.nearM`: 27
physics reads and 3 registration reads a second, and for each open lane its
four leads' headings. Within `client.promptM`: a
TICK reading this player's position. While a lane folds (4 s): about 26
natives a frame.

## The wire

| Event | Way | Payload | Rule |
|---|---|---|---|
| `BR.Net.DCGATE_USE` | C→S | `{ reader }` | "Open the lane of the reader I stand at." Taken only through the door above; silent otherwise. Never answered: the lane, if it opens, arrives as `DCGATE_STATE`. |
| `BR.Net.DCGATE_STATE` | S→C | `{ matchId, open = { [lane] = boolean } }` | Every lane of the match, whenever one changes; to the whole match. |
| `BR.Net.SNAPSHOT` | S→C | gains `dcgate = { matchId, open }` | `BR.DcGate.viewFor`: a late joiner and a restarted client see an open lane open. Nil outside a match or off Season 2. |
| `BR.Net.DCGATE_DEV` | S→C | `'<text>'` | A `brgatesv` answer, printed on F8. |

All names in `br_lib/shared/protocol.lua`.

## The numbers

`br_lib/config/dcgate.lua`, each with who decided it:

| Key | Value | Why |
|---|---|---|
| `openMs` | 20 s | Owner, 2026-10-19 |
| `foldMs` | 4 s | A fold each way |
| `foldDeg` | 90 | The kit: theta 0-90, hard stop at 90 |
| `armRaiseDeg` | 85 | The kit: 85-90 is fully raised; its previews stand it at 85 |
| `readerM` / `readerZM` | 3 m / 2.5 m | A driver at the pedestal and a player on foot beside it |
| `use.minIntervalMs` / `perMatch` | 0.5 s / 120 | The door's rate: half `client.askMs` |
| `use.sampleMaxAgeMs` / `reachSlackM` | 1 s / 3 m | The presser's sample, and the reach past the client's |
| `lane.pedMarginM` / `vehicleMarginM` / `vehicleSideM` | 0.5 m / 2.5 m / 1 m | The box grown for a player, and for a car's center past its ends and its sides |
| `lane.belowM` / `aboveM` | 1 m / 4.5 m | Under the grade, over it |
| `lane.checkMs` / `sampleMaxAgeMs` | 500 ms / 3 s | The pass, and the samples it counts |
| `client.nearM` / `promptM` | 300 m / 15 m | Past the gate's radius: the doors kept posed (the leaves' lodDist), the prompt's TICK |
| `client.askMs` | 1 s | A press asks the server no more often |
| `client.findRadiusM` / `findsPerPass` | 0.6 m / 9 | The finds |
| `client.drive`, `ratioDeg`, `ratioSign` | ratio, 90, 1 | How a lead and an arm are moved (the engine questions) |

## Dev

Dev mode only (`br_lib/shared/devgate.lua` wraps every command), Season 2 only
for the server's verbs:

| Command | Does |
|---|---|
| `brgate` / `brgate list` | This client's lanes, poses, handles and drives, then the server's (`brgatesv list`): each lane open or shut, for how long, what holds an open one, and the refused presses by reason |
| `brgate near` | The lane of the nearest reader: each part's door state, physics, open ratio, handle, rotation and turn against its placed heading, and whether a follower is attached. The tool for the engine questions below |
| `brgate open <lane\|all>` | Open it as a reader would, whoever is where (`brgatesv open`) |
| `brgate close <lane\|all>` | Fold it shut now, as its clock would: it opens again on anybody in it |
| `brgate drive <lead\|arm> <ratio\|rotate>` | How this client moves them, until it restarts: each part of that kind shut the old way first |

From the server console a verb about a player takes the player id last:
`brgatesv open 2 12`.

## Engine behavior to settle on the dev box

None of these was tried in game (the owner was playing on 2026-10-19). Each
has its fallback, and `brgate near` prints every read they need.

| Question | If yes | If no |
|---|---|---|
| A locked door held at an open ratio (`DoorSystemSetOpenRatio`, then state 1) stands there | the `ratio` drive as shipped | `brgate drive lead rotate` |
| The door system snaps a lead to its ratio, or eases it there | either way, the settle rides the followers until the leads stop | |
| An open ratio of 1.0 turns a lead 90 degrees, the kit's way for `lead_l` | as configured | `ratioDeg.lead` to what `brgate near` reads, or `ratioSign.lead = -1` |
| The arm (attribute 9) rises by its open ratio | as shipped | `brgate drive arm rotate` (about local +y by -raise, rotation order 2) |
| A follower attached to a door-system lead moves with it, and is not held shut by its own (unlocked) door entry | as built | make the followers plain props in the pack (the kit's open question for the coordinator) |
| `GetClosestObjectOfType` returns a ymap-placed door object | the finds as written | probe `GetGamePool('CObject')` by model near the origin |

## The map side

br_datacenter must drop the main gate's 24 leaves and 3 arms from its
`DOOR_LOCKS` in the same publish (`py tools/dcgate_parts.py ... --locks
<client.lua>` says how many it still locks), and this must not ship before it.
The two register the same names, and they fight: the pack's one-second loop
forces shut and re-locks every door whose state is not 1, and a follower
rides unlocked (state 0), so the pack would snap the followers shut under
their leads mid-fold (and, with the `rotate` drive, the leads and the arm
too); its stop handler also removes the registrations. The datacenter repo's
`blender/campus_integrate/tools/doorlock.py` already leaves the 27 out
(2026-10-19); the pack has to be built from it and published.

**Not done, for the owner to decide**: the readers stay red when a lane opens
(the kit has a green twin, `brdc_reader_g`, and green signal cabinets for a
model swap), and the guard shack's door, the pedestrian gates and the
substation and generator-yard gates stay the pack's.
