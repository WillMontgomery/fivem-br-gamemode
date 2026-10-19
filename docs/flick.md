# Flick cameras

Season 2's pole cameras (#419): a few hundred cameras along the roads and at
the junctions that feed the terminal's Scan. Players knock them out, and Scan
loses sight of that area for the rest of the match. This page is the contract:
the registry, how a camera goes down, who is told, the reward, what Scan sees,
and the coverage the Scan squad gets on its big map.

[← Back to the main README](../README.md)

---

Six pieces, a file each. Each knows only its neighbors.

| Piece | Where | Its job |
|---|---|---|
| **The registry** | `br_lib/config/flick_cameras.lua` (generated) | Every camera: `{ id, x, y, z, h, region }`. Read by both sides. |
| **The numbers** | `br_lib/config/flick.lua` | The ranges, the Volts, the takedown toast's copy, the door's rules, the client's watch, the art. |
| **The shared rules** | `br_lib/shared/flick_solve.lua` (`BR.FlickSolve`) | The grid, "is this point covered", the down rule, the reach rule, the takedown toast's line. One spelling for both sides and the suites. |
| **The server** | `br_core/server/flick.lua` (`BR.Flick`) | This match's cameras, the report door, the decision, the credit and its toast, who is told of a down, the snapshot's view, `BR.Flick.seen` for Scan, the dev verbs. |
| **The client** | `br_core/client/flick.lua` | Watches the cameras near this player and reports one that went down; shows every down camera broken; the Season 1 hides; the Scan squad's coverage on the big map. Decides nothing. |
| **Scan** | `br_core/server/terminalfx.lua` | Sends only the opponents a live camera sees ([terminals.md](terminals.md#scan-and-the-bounty)). |

**The server decides every down.** A map object is each client's own, so only
a client can see one break, and a client only ever says "I did it" or "it
fell". It never names anybody else, and nobody else's ped is resolved on the
client (none of the [scope gate](terminology.md)'s natives is needed). Credit
goes only to the player whose own report says `me`, standing in a PLAYING
match, within reach of the camera by the server's own 4 Hz sample of them.

**Season 2 and later**: one row, `flick = { from = 2 }` in
`br_lib/config/seasons.lua`, asked only as `BR.Season.has('flick')`: by the
door, Scan's filter, the sends, the snapshot's view, and every client pass
(through a `refreshSeason` on the SLOW pass, as `client/terminalfx.lua` does).
Off, nothing reports, nothing pays, and Scan is exactly what it was. It is its
own row and not `terminals` because the cameras are their own content.

## The owner's decisions (2026-10-18)

- Named Flick; the logo is a hand giving the middle finger.
- About 300 cameras along roads and near junctions inside the play area, never
  blocking a driveway or a lane. The prop is a pole with a camera and a solar
  panel, with an LOD.
- Knocked out by gunfire or knocked over by a vehicle: **one hit on the camera
  or on its solar panel** takes it down. Down for the rest of the match; the
  server decides; every client shows it broken; all of it resets each match.
- **Explosions and AI traffic** take a camera down too, and **pay nobody**.
- Scan sees an opponent within **75 m** of a working camera on foot and within
  **150 m in any seat of a vehicle** (the cameras read plates).
- The coverage is drawn **on the big map only, for the Scan squad only**.
  Nobody sees the cameras on any map otherwise.
- **2 Volts** a camera taken down, **30 at most a match**.
- **The takedown toast**: the player credited is told, as if by the "SA
  Sovereign Citizens Community", "Thank you for your service." with the Volts
  just earned -- only when Volts are actually credited ([The takedown
  toast](#the-takedown-toast)).
- Scan's new copy: "Scan's new text looks good" (the lines are in
  [The copy](#the-copy-and-the-art)).

## The registry

`BR.Config.Flick.cameras`, one row per camera the placement ymap stands, in a
file of its own because it is generated:

```lua
BR.Config.Flick.cameras = {
    { id =    1, x =   121.741, y =    -2.741, z =   66.730, h = 324.4, region = 'alta' },  -- alta_1
    ...
}
```

- **`id` is a whole number, 1..9999, unique and never reused** -- never the
  array index -- so a match in flight and the dev tools agree on what "camera
  117" is, and `FLICK_DOWN`'s ids stay small. The placement work keeps every id
  it ever gave (`flick/place/flick_ids.tsv`): a camera within 3 m of an earlier
  one keeps its id, and a dropped one's is retired.
- `x, y, z` is the foot of the pole on the ground; `h` the GTA heading the ymap
  stands it at; `region` the nearest POI. The comment is the placement's
  display name, which renumbers when the set changes.
- **One source for both files.** The placement work writes the ymap and
  `flick_cameras.json` from the same list, so the rows are where the props
  stand. Nothing in this repo can read the ymap (it is in the Season 2 asset
  drop), so the generator is where the two agree.
- **The positions are public, and that is fine.** The table ships to every
  client, and the props stand in the world for anyone to see. What is withheld
  is who stands near them (Scan stays on the server) and which cameras were
  knocked out out of view.

**The generator**, `tools/flick_cameras.py`, writes the file from the
placement list and refuses a list it cannot trust (an id that is not a whole
number in 1..9999 or repeats, a coordinate or heading that is not a finite
number, a region that is not lower-case letters, digits and underscores):

```
py tools/flick_cameras.py <path to flick_cameras.json>            write it
py tools/flick_cameras.py <path to flick_cameras.json> --check    is it current?
```

The file's header names the source and its sha256. A new list then needs
`lua tools/perf_client.lua --rebaseline` in the same commit: the Season 1 hides
and the coverage circles scale with the count (see [Testing](testing.md#the-frame-profiler-and-its-budget)).

**`tools/check_boundary.lua` check 6** (verify.sh's `map boundary`): every
camera inside the surveyed ring, as the terminal sites are; ids whole, 1..9999
and unique; the count between 250 and 1,500; and no two cameras closer than
`minSpacingM` (10 m), so one camera's model hide (1.5 m) can never catch a
neighbor. It prints the count, the tightest margin and the closest pair.

**The grid.** `BR.FlickSolve.grid(rows, cellM)`, built once a resource start on
each side: cells of `gridM` (150 m, the widest range) holding row indices, so
"any live camera within r" walks the 3x3 cells around a point -- a handful of
rows in the city, none in the hills.

## The world

### What the prop does

The prop is ours (`blitz_flick_cam`), built on the game's camera-pole fragment
(`prop_cctv_pole_04`'s break numbers): a base that never moves, a pole a car
snaps at its base plate, and a camera head and a solar panel that one bullet
breaks off. Its LOD is inside the model, so hiding it hides every distance.
It draws to 150 m from the ymap. The flick workspace's `design/PROP.md` has the
rest.

**`HasObjectBeenBroken` is the signal for both causes.** The ymap entity stays
at the base when a car snaps the pole -- the falling pole is a new object -- so
"tilted" and "moved" will not fire on the handle the client holds. They stay in
the down rule as harmless extras.

### Season 1 hides the cameras

The ymap rides the Season 2 drop, so a live `brseason 1` on a box started at
Season 2 still streams it. A client where `BR.Season.has('flick')` is false
hides `art.model` at every row with `CreateModelHideExcludingScriptObjects(x, y,
z, art.hideRadiusM, hash, true)` -- map objects only, surviving a map reload --
and `RemoveModelHide(..., false)` brings them back when the season turns Flick
on. On start and on `BR.Season.onChange` only (the SLOW pass catches a move it
did not announce), never per pass, and **spread over frames**:
`client.hidesPerFrame` (25) a frame, twelve frames for 300. A client that does
not know its season yet hides nothing: it would only show them all again a
second later.

### A down camera, on every client

A map object is this client's alone, so "broken for everyone" is drawn by each
client from the server's list:

1. **The intact model hidden at the row**, the same model hide at
   `art.hideRadiusM` (1.5 m), so a camera that streams in later arrives hidden.
   A batch a frame, as the Season 1 hides are.
2. **A stand-in wreck** near the view: a local, non-networked script object
   (`CreateObjectNoOffset(..., false, false, false)`) at the row and its
   heading, of the model the server's recorded cause names -- `art.wreck.weapon`
   (`blitz_flick_cam_shot`, the pole standing, the camera hanging; unfrozen, so
   a car can still knock it over) or `art.wreck.vehicle` (`blitz_flick_cam_down`,
   the stump; frozen). Only within `client.wreckM` (300 m) of the view (a
   spectator's is their target's), nearest first, at most `client.wreckMax`
   (24), made and dropped on the SLOW pass. A script object is never caught by
   the hide. A build without the wreck models: hidden only.
3. **A real wreck is left alone.** While this client's own copy of the camera
   that it saw go down still exists, no stand-in is drawn over it.

**Reset each match.** On a new match's first list, in the lobby, off Season 2
and when br_core stops: every down's hide lifted, every wreck deleted, the
reported set cleared. A camera a client physically broke is not repairable by
script; it comes back when its map section streams out, which the trip to the
lobby does.

## A camera going down

### The client watches the cameras near it

`client/flick.lua`, one SLOW pass (`flick.watch`). It returns before any native
unless Flick is on, the mirror says the match is PLAYING, and this player is
ALIVE or DBNO. Then:

1. **The near set**: the live, unreported cameras within `client.nearM`
   (120 m), off the grid. Pure Lua.
2. **The handle**, cached per camera: `GetClosestObjectOfType(row,
   client.findRadiusM, model, false, false, false)` only as a camera comes into
   reach or its cached copy stops existing (it streamed out), at most
   `client.findsPerPass` (4) a pass. A row with nothing there (no pack, or not
   streamed yet) is asked again only `client.findRetryMs` (5 s) on.
3. **The probe**: `DoesEntityExist`, `GetEntityHealth` (against the health first
   read), `HasObjectBeenBroken`, `GetEntityUprightValue`; `GetEntityCoords` only
   when the health or the upright value moved. Every BOOL through
   `BR.NativeTruthy`.
4. **The rule**, `BR.FlickSolve.downed(probe, row)`: down when broken, tilted
   past `tiltDownDeg` (30 deg), moved more than `movedDownM` (0.75 m), or (when
   `healthLossDown` is set, once the prop is measured) that much health gone.
5. **Up: the damage record cleared** (`ClearEntityLastDamageEntity`), every
   pass, so a "me" is the damage of the last second -- never a shot at the pole
   long ago that a passing car then gets the credit for.
6. **Down: who did it, as this client saw it.** `by = 'me'` when
   `HasEntityBeenDamagedByEntity(handle, PlayerPedId(), true)`, or when this
   player drives (seat -1 of `GetVehiclePedIsIn`) a vehicle that damaged it;
   else `by = 'other'`. `cause` is `vehicle` when
   `HasEntityBeenDamagedByAnyVehicle`, else `weapon`.
7. **Report once**: `FLICK_REPORT { id, by, cause }`, and the camera is marked
   reported for the rest of the match whether the server agrees or not.

Cost while nothing happens: five natives a camera a second. Ten cameras in
reach is fifty a second, under one a frame.

**Why bystanders report too.** A camera can fall with nobody's "me" on it:
traffic, a car with no driver, a remote player's shot simulated here. The
server takes an `other` report as a down with no reward, so a camera broken
where players can see it is broken for Scan too. It gives a modified client no
more than a gun: it can only down cameras within reach of where the server's
own sample says it stands.

### The server's door

`RegisterNetEvent(BR.Net.FLICK_REPORT)` in `server/flick.lua`. Every refusal is
a silent drop, counted per reason on the match (for `brflick list`), in this
order:

1. **season**: Flick on in the season in force.
2. **shape**: `id` a whole number naming a row; `by` `me` or `other`; `cause`
   `weapon`, `vehicle` or absent.
3. **rate**: no sooner than `report.minIntervalMs` (300 ms) after this player's
   last report, and `report.perMatch` (60) a match at most.
4. **match**: the reporter is in a match, and it is PLAYING. Warmup, the bus,
   the end screen and the lobby down nothing.
5. **player**: ALIVE or DBNO, by the roster.
6. **reach**: by the server's own sample, no older than
   `report.sampleMaxAgeMs` (1 s), 3D to the row (`BR.FlickSolve.reach`): a `me`
   ram within `reach.vehicle` (25 m), a `me` shot within `reach.weapon`
   (400 m), any `other` within `reach.other` (400 m).
7. **duplicate**: the camera is still up -- or went down less than
   `report.creditWindowMs` (3 s) ago with nobody credited, and this is a `me`
   report from a standing player. Anything else changes nothing.

`FLICK_REPORT` creates no item, so it is not one of
`tools/check_net_gates.lua`'s spawn doors, and its handler reads no dev mode.

### The decision

- **A camera up goes down**: `m.flick.down[id] = { at, cause, by?, blast? }`,
  then the credit (below), then the send, then one console line:
  `[br_core] flick: camera 117 down (vehicle) by NightOwl (12), +2 Volts (6/30)
  in match 4`.
- **A camera already down** inside the credit window, nobody credited, and a
  `me` report from a standing player: the credit only. So a bystander's `other`
  landing 200 ms before the shooter's `me` costs the shooter nothing. Two `me`
  reports: the first one the door took is paid.
- **Explosions pay nobody.** The server hears every networked explosion
  (`explosionEvent`: its sender and where) and keeps the last few of each
  PLAYING match. A down within `report.blastM` (15 m) of one, up to
  `report.blastWindowMs` (3 s) after it, is nobody's: down, no Volts.
- **The state is the match's**: `m.flick = { down, order, paid, sent, rate,
  refused, blasts }`, made on first use and gone with the match, so every match
  starts with every camera up and two matches at once each have their own.

### Who is told

`BR.Net.FLICK_DOWN { matchId, ids, causes }`, additive -- a camera never comes
back up inside a match, so a client's list only grows. It goes:

- **To the players near it**: within `showM` (500 m, past the farthest any
  camera draws) by their view -- their own sample, or for a spectator the
  sample of the player they watch, as `EMOTE_RECORD` is routed. A down is a
  fresh position of a player ("somebody was just here"), which is why it is
  not sent to the whole match.
- **To every member of a squad running Scan, all of it**: their coverage is the
  registry less every down. When a squad starts Scan,
  `BR.Flick.joinScan(m, key)` sends it every down so far, at once.
- **And later to whoever comes near**: the `flick.send` job every `sendPassMs`
  (1 s) sends each match player the downs within `showM` of their view they
  have not been sent.

**The snapshot carries it.** `BR.Broadcast.snapshot` adds `flick =
BR.Flick.viewFor(target)`, `{ matchId, ids, causes }`: the downs this player
should hold, which becomes exactly what they have been sent -- so a late joiner
and a restarted client (`br:ready` raises the snapshot) are re-seeded by the
same function. `client/flick.lua` replaces its list for that match with it; a
snapshot with none (no match, Season 1) leaves it none. `playerDropped`
forgets a player's sent set.

## The reward

**2 Volts a camera to the player credited, 30 at most a match, through the
Volts path the airdrop pile uses.**

- **Paid at match end, in the one atomic ADD.** The credit adds to the roster
  entry's `voltsPickedUp` ("Volts found in the match": an airdrop's pile, a
  Flick camera), which the results row carries (a leaver's sealed row too),
  `br_stats/server/persist.lua` passes to `BR.Config.marketPayout`, and that
  adds whole, after the weights, into `deltas.balance`. No new writer of a
  balance, no per-camera database write, and `BR.Match.resetPlayer` already
  zeroes it ([progression.md](progression.md#airdrop-volts-88)).
- **The cap is by account, on the match**: `m.flick.paid[license]`, so walking
  out and back, a reconnect or a client restart never resets it. Each credit
  pays `min(voltsEach, voltsMatchMax - paid)`: the 16th camera still goes down,
  credited, and pays 0.
- **What stops a farm**: each camera pays once a match and never comes back up
  in it; only a `me` report from a player ALIVE in the PLAYING match, within
  reach, inside the credit window; an `other` report downs and pays nothing; a
  downed (DBNO) reporter downs it and is paid nothing; an explosion pays
  nobody; the reporter's rate and per-match limit; the dev verbs pay nothing;
  Season 1 pays nothing.
- **What the player is told**: the takedown toast, at once, to them alone,
  and only when Volts are actually credited. Then the Volts appear in the
  verdict's "Volts earned", which is `marketPayout`'s answer.

### The takedown toast

On screen, in the notice stack, in the success tone:

> SA Sovereign Citizens Community: Thank you for your service. **+2 Volts**

with "+2 Volts" in the Volts color. The owner's words (2026-10-18), verbatim,
in `BR.Config.Flick.copy`: `sender` "SA Sovereign Citizens Community" and
`thanks` "Thank you for your service." -- no other word. **A toast has no
title field** (`ToastPayload` is a sentence, a tone and a lifetime), so the
sender leads the line before a colon: the closest pattern there is, the HUD
notices that name what speaks ("Scan: another squad can see you near Flick
cameras.") and the chat's "name: text". `BR.FlickSolve.toast(copy, n,
currency)` joins it: the figure is `BR.ShopSolve.priceLine` with
`BR.Config.Market.currency`, `+` before it, all inside the tilde pair
ui-src's KeyText paints in the Volts color (the purchase and balance toasts'
mark). It is what was credited: 2, or what is left under the 30.

**It is sent from `credit`, on the same `n > 0` that adds to
`voltsPickedUp`**, so it fires exactly when Volts are credited: a `me` shot or
ram from a standing player, and the shooter's `me` inside the credit window
after a bystander's `other`. **Silent** at the cap (the 16th camera, or the
rest of an account's 30 after a rejoin), and for every down that pays nobody:
an explosion, traffic or a bystander's `other`, another player's camera (a
duplicate), a downed reporter, a `me` past the credit window, the dev down,
and Season 1. Keyless, as the airdrop pile's "You collected" toast is, so two
in a row coalesce into one row with x2.

## Scan, seen through the cameras

`server/terminalfx.lua`. With Flick on, Scan's push sends only the opponents a
live camera sees:

- **The rule**, `BR.FlickSolve.covers(grid, down, x, y, inVehicle)`: a live
  camera within `rangeM` (75 m) of the player, or within `vehicleRangeM`
  (150 m) while they ride a vehicle. **Flat (2D)**, so what Scan sends is
  exactly what the circles on the big map show, and a player on a roof, in the
  air or in a basement is judged where the map puts them.
- **In a vehicle** is the server's own answer, `BR.Vehicles.ridingIn(e.ped)`,
  any seat, so a car's passengers show with its driver. It is asked only for a
  player inside 150 m of a live camera and outside 75 m of every one: on foot
  answers first and for nothing.
- **Once a ping, not once a squad**: `T.pushScans` asks `BR.Flick.seen(m, now)`
  once, the set of players a live camera sees, and each scanning squad's list
  is that set less its own squad and any squad under Ghost.
- **Clients never get a position they should not**: the filter is on the
  server, before the payload is built. `TERMINAL_SCAN` gains `flick = true`, so
  the client knows to draw the coverage; the list keeps its shape. The season
  is asked in terminalfx itself, so a camera file that failed to load makes Scan
  see nobody, never everybody.
- **A camera knocked out** is out of the next ping: `BR.Flick.seen` reads
  `m.flick.down` live.

**Unchanged**: the bounty (still on everyone's map for ten minutes, cameras or
not: it is the runner's risk, not Scan's reach), Ghost, Airstrike's rough
circles ("nothing while the runner's squad has Scan running" still holds),
Comms blackout, the price and the one use. Power outage does not touch a
camera (it has a solar panel), and neither does EMP.

**The notice stays static.** `impact_scan` is not switched on and off as a
player walks in and out of coverage: that would tell every opponent where the
coverage ends, which only the Scan squad may see. Its line says "near Flick
cameras".

## The coverage on the big map

**Who**: only a client receiving `TERMINAL_SCAN` with `flick = true` -- the
scanning squad, dead and spectating members included -- in a match, on Season
2. Nobody else draws anything: no camera blip and no legend entry, for anyone.

**What**: one radius blip per live camera, `rangeM`, in `art.coverage`'s color
and alpha (placeholders: never the storm's purple, Scan's red or the bounty's
blue; "the circles should be barely visible", owner, 2026-10-18, so alpha
starts at 25 and `brflicktune` is how he picks the look). No name and off the legend (`BR.Native.blipHiddenOnLegend`): a legend
with hundreds of entries flickers and rebuilds. Overlaps at a junction read
darker, "seen from two poles". The vehicle range is not drawn.

**When**: **only while the big map is up** (`BR.Native.frontendMap`, raised by
br_ui around the frontend map, which the terminal's map pick waits on). A TICK
callback, registered only while the pushes say `flick`, sees it rise and queues
a circle for every live camera; `client.coverageBatch` (100) are made a frame,
three frames for 300. They come down when the map falls, in the lobby, when the
pushes stop (three of their periods, the marks' rule), off Season 2 and on
resource stop. A camera that goes down while the map is up loses its circle at
once.

**Why this way**: the radar never holds the circles, so playing costs nothing
and the map costs one burst as it opens; and it is not the minimap overlay
(`client/mapoverlay.lua`), which is the storm's, draws on both maps, and whose
area push is the expensive call #350's hitch was traced to. If the owner wants
the minimap too, the same set becomes short-range blips near the player: a
change of lifetime, not of design.

## The wire

| Event | Way | Payload | Rule |
|---|---|---|---|
| `BR.Net.FLICK_REPORT` | C→S | `{ id, by, cause? }` | "This camera near me went down." Taken only through the door above; silent otherwise. Never answered: the down, if any, arrives as `FLICK_DOWN`. |
| `BR.Net.FLICK_DOWN` | S→C | `{ matchId, ids, causes }` / `{ matchId, reset = true }` | Cameras down in this match, additive, each with the cause the server recorded. To the players within `showM` of each by their view, to every member of a Scan squad all of them, and on a 1 s pass to whoever comes near. `reset` only from `brflick reset`. |
| `BR.Net.SNAPSHOT` | S→C | gains `flick = { matchId, ids, causes }` | The downs this player should hold (`BR.Flick.viewFor`). |
| `BR.Net.TERMINAL_SCAN` | S→C | gains `flick = true` | Coverage applies; the list is the opponents a live camera sees. |
| `BR.Net.FLICK_DEV` | S→C | `'<text>'` | A `brflicksv` answer, printed on F8. |

All names in `br_lib/shared/protocol.lua`.

## The numbers

`br_lib/config/flick.lua`, each with who decided it:

| Key | Value | Why |
|---|---|---|
| `rangeM` | 75 m | Owner, 2026-10-18 |
| `vehicleRangeM` | 150 m | Owner, 2026-10-18 (the cameras read plates) |
| `voltsEach` / `voltsMatchMax` | 2 / 30 | Owner, 2026-10-18 |
| `gridM` | 150 m | The grid's cell: the widest range |
| `minSpacingM` | 10 m | `check_boundary.lua`: no two cameras closer |
| `report.minIntervalMs` / `perMatch` | 300 ms / 60 | The door's rate |
| `report.sampleMaxAgeMs` | 1 s | The reporter's sample, no older |
| `report.creditWindowMs` | 3 s | A `me` after an `other` is still credited |
| `report.reach` | weapon 400 m, vehicle 25 m, other 400 m | The reporter's distance, 3D |
| `report.blastM` / `blastWindowMs` | 15 m / 3 s | An explosion's down pays nobody |
| `showM` / `sendPassMs` | 500 m / 1 s | Who is sent a down, and the pass |
| `client.nearM` | 120 m | The watch's reach |
| `client.findRadiusM` / `findsPerPass` / `findRetryMs` | 2 m / 4 / 5 s | The finds |
| `client.tiltDownDeg` / `movedDownM` / `healthLossDown` | 30 deg / 0.75 m / off | The down rule |
| `client.wreckM` / `wreckMax` | 300 m / 24 | The stand-ins |
| `client.hidesPerFrame` / `coverageBatch` | 25 / 100 | The batches a frame |
| `art.model`, `art.wreck`, `art.wreckFrozen`, `art.hideRadiusM`, `art.coverage` | | The prop's names, 1.5 m, the coverage's look (placeholders) |

`tools/config_report.lua` shows `rangeM`, `vehicleRangeM`, `voltsEach`,
`voltsMatchMax` and the camera count on the console's Live config page.

## Dev

Dev mode only (`br_lib/shared/devgate.lua` wraps every command), Season 2 only,
run on the server as `brflicksv`:

| Command | Does |
|---|---|
| `brflick` / `brflick list` | Cameras, down this match by cause, refused reports by reason, your Flick Volts this match against the cap |
| `brflick near` | The nearest camera: id, distance, up or down here, and what this client reads off its copy (handle, health, broken, upright, moved, damaged by you, by a vehicle). The tool for the engine questions below |
| `brflick down <id>` / `brflick down near` | Down it through the decision: nobody credited, nothing paid |
| `brflick reset` | Every camera in your match up again on the server, and every client's hides lifted (`FLICK_DOWN reset`). A camera a client physically broke stays broken until it streams out; the answer says so |
| `brflick coverage [off]` | Your big map's coverage without running Scan |
| `brflick hides` | The model hides this client holds, the downs, wrecks and circles |
| `brflicktune` | The coverage's look on the keys (#404's shape, `client/tunekeys.lua`), on or off. While on, the big map shows a circle for every working camera with no Scan run; LEFT/RIGHT the blip color (once a press, round GTA's palette 0-85), UP/DOWN the alpha (1 a step), SHIFT 10, DELETE the shipped look, the numbers on screen, every circle restyled at once. Again (or `off`) puts it away and prints the `coverage = { ... }` line to paste into `br_lib/config/flick.lua` |

From the server console a verb about a player takes the player id last:
`brflicksv list 12`, `brflicksv down 117 12`.

## Engine behavior to settle on the dev box

Searched (Cfx.re forum, FiveM docs) for the design on 2026-10-18; none of these
is answered anywhere, and none was tried in game. Each has its fallback, and
`brflick near` prints every read the first three need, so one walk-up answers
them.

| Question | If yes | If no |
|---|---|---|
| `GetClosestObjectOfType` returns a ymap-placed instance of our model | the watch as written | probe with `GetGamePool('CObject')` filtered by model near the row, on the SLOW pass only |
| A vehicle or a shot on our prop shows as broken (`HasObjectBeenBroken`) | the down rule as written | the prop changes (the fragment's break numbers) |
| `HasEntityBeenDamagedByEntity` is set by the player's shot and car, and cleared by `ClearEntityLastDamageEntity` | `me` as written | `gameEventTriggered` `CEventNetworkEntityDamage` (victim, attacker) if it fires for map objects; else credit only a `vehicle` report with the reporter's own vehicle within reach |
| A remote player's ram or shot breaks the local copy on a bystander's client | bystanders report `other`, as designed | nothing breaks there: only the hide shows it, which is already the design |
| `CreateModelSwap` works on ymap objects | one call per down instead of hide plus wreck | hide plus wreck, as built |
| `SetBlipDisplay` keeps a radius blip off the radar | coverage could stay up between map opens | built only while the map is up, as built |
| A script-made `_shot` fragment stands until it is hit | unfrozen, as configured | `art.wreckFrozen.weapon = true` |
| `brflicktune`'s keys and readout reach it while the big map is up | tune with the map open | tune with it closed and open it to look: every circle is made in the look of the moment |

`CreateModelHideExcludingScriptObjects` and `RemoveModelHide` are the ones the
laptops' Season 1 hides already rely on (read against the Cfx docs on
2026-10-06, [terminals.md](terminals.md#terminals-in-the-world)).

## The copy and the art

**The copy** is Scan's, in `br_lib/config/terminals.lua`, APPROVED by the owner
on 2026-10-18 ("Scan's new text looks good") and held word for word by
`tools/test_terminal.lua`, which also holds the 75 and the 150 in it to
`BR.Config.Flick` and fails the day the `flick` and `terminals` rows start in
different seasons (the lines are replaced, not forked):

| Key | Who reads it | Line |
|---|---|---|
| `scan_summary` / `_solo` | At the terminal: Scan's card | "Shows opponents near working Flick cameras on your squad's maps for the rest of the match." / "... on your map ..." |
| `scan_what` / `_solo` | At the terminal: Scan's page | "Opponents within 75 m of a working Flick camera appear on the maps of everyone in your squad, and opponents in a vehicle within 150 m." then "Your big map shows where the cameras can see.", "A camera that's knocked out stays out for the rest of the match." and Scan's three lines as they were (solo: "your map", "A player running Ghost") |
| `scan_description` / `_solo` | The lobby's `notice_action` | "Scan. Their squad sees opponents near Flick cameras for the rest of the match." / "Scan. They see ..." |
| `impact_scan` / `_solo` | The HUD, every opponent of a Scan squad | "Scan: another squad can see you near Flick cameras." / "... another player ..." |

And the takedown toast's two lines, the owner's (2026-10-18), in
`br_lib/config/flick.lua`'s `copy` and held word for word by
`tools/test_flick.lua` ([The takedown toast](#the-takedown-toast)):

| Key | Who reads it | Line |
|---|---|---|
| `copy.sender` | The player credited with a camera: the toast's sender, before a colon | "SA Sovereign Citizens Community" |
| `copy.thanks` | The same toast, before the Volts earned | "Thank you for your service." |

No other line: no camera plate, no blip name.

**The art**: `art.model` and `art.wreck` are the prop's names (`blitz_flick_cam`,
`blitz_flick_cam_shot`, `blitz_flick_cam_down`, in the Season 2 drop's
`br_flick`); `art.coverage` (color 5, alpha 25) is a placeholder for the owner,
who picks it with `brflicktune`.
