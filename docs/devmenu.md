# The dev menu

A menu in the gun shop's UI, on a dev-mode server only, over the console
commands a playtest leans on (#422), and a vehicle spawner (#426). F10 or
`/brdev` opens it. This page is the contract: who may use it, what each row
runs, and what it writes.

[← Back to the main README](../README.md)

---

Owner, 2026-10-24: *"What I need now is a dev-only menu using the same UI as
our gun store. It should control things like time, weather, match state, give
volts, give Yubikeys, Storm pause, warmup pause, spawn airdrops"*

| Piece | Where | Its job |
|---|---|---|
| **The words and the lists** | `br_lib/config/devmenu.lua` (`BR.Config.DevMenu`) | The labels, the key, the Volts amounts, the match states, and the vehicle spawner's sync trees, left-out class and model-name rule. Read by both sides. |
| **Which vehicles are armed** | `br_lib/config/vehicles.lua` (`BR.Config.IsArmedVehicle`) | The vehicle spawner's "Armed" mark, out of the refused-vehicle table. Rules on nothing. |
| **The client** | `br_core/client/devmenu.lua` | The menu, built once through `BR.Menu` (`client/menu.lua`), the vehicle spawner's menus, built the first time each opens, the key, and one `brdevsv` line per press. Decides nothing. |
| **The server** | `br_core/server/devmenu.lua` (`BR.DevMenu`) | The door, `brdevsv`: the gate, the checks, the rate, the console verb each row runs, and the vehicle spawner's seat. |
| **The spawn** | `br_core/server/vehicles.lua` (`BR.Vehicles.spawnInFront`) | `brcar`'s own server-side spawn, which the vehicle spawner runs too. Dev mode only, and called from those two places only. |
| **The exemption** | `br_core/server/vehicles.lua` (`BR.Vehicles.exemptDevMenuVehicle`), and a state bag for `client/vehrefuse.lua` | The server's in-memory record of what the vehicle spawner built, which the vehicle detectors skip, and the hint that stops the client's ejection and gun hold. A dev box only, on both sides. |
| **The game's own models** | `br_lib/config/vehicle_models.lua` (`BR.Config.VehicleModels`), written by `tools/vehicle_models.py` | Every base-game vehicle model: its hash, the sync tree it has to be built as, how far it reaches across and below its origin, and whether the game's data arms it. The spawn's tree check and placement; `check_vehicles.lua`'s expected Armed set. Server only. |
| **The game's vehicle weapons** | `br_lib/config/vehicle_weapons.lua` (`BR.Config.VehicleWeapons`, `BR.Config.VehicleWeaponByHash`), written by the same tool | Every vehicle weapon the game's data lists on any model, the searchlight, the radar and the water cannon among them. The only weapons a dev menu vehicle's gun is excused for. Shared: the client's strip asks it too. |

## Who

**Anyone on a dev-mode server**, and nobody anywhere else. Every press is the
server command `brdevsv`, run from the client with `ExecuteCommand` (the
`brprop` route), so two gates stand in front of every request:

- `br_lib/shared/devgate.lua`'s wrap: `sv_devMode` or `br_devMode`, read when
  the request arrives;
- `BR.DevMenu.allowed()`: `BR.Server.devMode == true`, what br_core started as.
  Dev mode switched on live, without restarting br_core, is not dev mode here.

On a server without dev mode the request is refused with one line on the
server console and has no other effect. `/brdev` prints the dev-mode line on
F8 and opens nothing, and **F10 is not mapped at all**: a key mapping cannot be
taken back, so the client maps it the first time it reads dev mode on, and the
public box's binding list never shows it. F10 is a default the player can move
in FiveM's key bindings.

## The rows

Each row runs the console command's own body, factored out so the command and
the menu call one piece of code. The two pauses share their command's record
swap and deadline, but hold one match where the command holds every one.

| Row | Value | Runs | Acts on |
|---|---|---|---|
| Time | `00:00`-`23:00`, Reset | `brtime` (`BR.WorldSky.setTime`) | the session's clock override, everyone |
| Weather | the fifteen weathers, Reset | `brweather` (`BR.WorldSky.setWeather`) | the session's sky override, everyone |
| Match state | `waiting` `warmup` `bus` `playing` `ended` `cleanup` `skip`; stands on the match's current state and follows it | `brforce` (`BR.Match.force`), `brskip` (`BR.Match.skip`) | **the asker's match** |
| Player | the connected players, yourself first | -- | who the next two give to, by id and token |
| Give volts | 100, 500, 1,000, 5,000, 10,000 Volts | `brvolts` (`BR.Debug.grantVolts`) | that player's stored profile |
| Give Yubikeys | -- | `brterminalsv key give` (`BR.Terminal.devKey`) | that player's stored profile; one at most, Season 2 |
| Storm pause | on / off | `brstormfreeze`'s record swap (`BR.Storm.setMatchFrozen`) | **the asker's match**; a match with no storm yet starts held |
| Warmup pause | on / off | `brwarmupfreeze`'s deadline (`BR.Match.setMatchWarmupFrozen`) | **the asker's match**; held again if it returns to warmup |
| Spawn airdrops | -- | `brairdrop now` (`BR.Airdrop.dropNow`) | **the asker's match**; PLAYING only |
| Vehicle spawner | a menu: Spawn by name, then a row per vehicle class | `brcar`'s spawn (`BR.Vehicles.spawnInFront`), any model | **the asker**: in front of them, in their bucket, then in its driving seat; exempt from the match's vehicle rules; only in warmup or alive in a match. See [The vehicle spawner](#the-vehicle-spawner) |

**The asker's match, never the newest, never every one.** Matches run side by
side in their own routing buckets, and the console commands aim at
`BR.Server.latestMatch()` -- or, the two freezes, at every match. Match state,
Spawn airdrops and both pauses take `BR.Server.matchOf(asker)`. A pause asked
for the state its match is already in does nothing: a thaw of a storm that was
never held would re-enter its phase, and of a pad would restart its countdown.
`brstormfreeze` and `brwarmupfreeze` on the console still hold or release
every match, and clear the menu's one-match pauses as they do.

From the lobby there is no match. A forced state forms one from the queue, as
`brforce` does, but only for a player who is queued; otherwise, and for
`skip` and both pauses, the answer is `no match running`. `waiting` says
`no match to dissolve`. Time and weather are one override for the whole
session -- the server sends one sky -- so the menu does what the command does.

A refusal is the command's own sentence (`airdrops only run during PLAYING
(match … is warmup)`, `1: already holds one`, `no match running`), sent to the
player who pressed as a warning toast and printed on their F8. A success is a
line on F8 only, and so is an airdrop that `wait`s: it stays queued and is
retried. After every answer the server sends the rows back, so a pause box the
library flipped is put right if the request did not take.

**A give names its player by id and token.** Server ids are recycled within
the minute, so the list the server sends carries a token per player -- a
number never handed out twice -- and a give sends both. A player who has left,
or an id somebody else now holds, is refused with `player <id> has left`, and
the asker is sent the list as it stands.

**The menu closes under our panels.** As at the gun counter, a NUI screen
taking the keyboard (the inventory, say) puts the menu away, and it does not
open under one. E at a gun counter does nothing while any of our menus is up,
and the gun shop's menu closes every other menu before it opens. The scroll
wheel does not switch slots under it.

## The vehicle spawner

Owner, 2026-11-01: *"can you also add to our dev menu a vehicle spawner menu?
remember this needs to be a server-side entity. include spawn by name and have
a category selection submenu with a list of all vehicles in each category. For
any that you believe to be armed, allow them to be spawned here, but put a note
on their row in red that says "Armed""*

**The rows.** Vehicle spawner, the last row, opens a menu of its own: **Spawn
by name**, then one row per vehicle class the game has vehicles in, named as
the game names it (`GetLabelText('VEH_CLASS_' .. n)`), in the game's class
order. A class opens a menu of every vehicle in it, by its in-game name
(`GetLabelText` of `GetDisplayNameFromVehicleModel`), or its model name when
the game has none, sorted by name without regard to case. **Two or more rows in
one class that would show the same name** (case aside) each show the name
followed by the model -- `Avenger (avenger3)`, `Speedo Custom (speedo4)` --
sorted by model; a name alone in its class stays as the game wrote it, and the
"Armed" mark is unaffected. Each submenu wears the dev menu's bar with its own
name in the strip under it, and the library's own Back walks back one menu at
a time.

**The lists are the game's.** `GetAllVehicleModels` is every vehicle archetype
the game registered -- the base game, every DLC, and any vehicle a resource
streams -- and the class and the name are read off each model's model info, so
nothing is loaded to list it. Read once, the first time the spawner opens;
each class's menu is built the first time it opens; all of it is kept.
**Trains get no row** (class 21): the server setter cannot build a train
(Ehbw, answering on the Cfx.re forum,
[forum.cfx.re/t/5217679](https://forum.cfx.re/t/createvehicleserversetter-serverside-spawned-vehicles-despawning/5217679),
2025-08-25: "Its not possible to spawn trains using
CREATE_VEHICLE_SERVER_SETTER").

**"Armed"** is a right-hand label in GTA's red (`~HC_6~`, HUD_COLOUR_RED --
an index into the engine's palette, never the project's cyan or gold), on the
models `BR.Config.IsArmedVehicle` names -- 125 of them: every ARMED row of the
refused-vehicle table (which includes every model `IsDisarmedVehicle` names),
every TANK row, every FLIES row marked `armed = true` -- the aircraft and
fliers whose model the game's vehicle data gives a weapon -- and the 31 armed
models no row names (`BR.Config.ArmedUnruledVehicles`: the Insurgent Pick-Up,
the Nightshark, the Speedo Customs, the Terrorbyte, the Weaponized Conada and
the rest). That last list is data and **rules on nothing**: a match treats
those vehicles exactly as before -- the fliers refused as aircraft by the type
and class nets, the rest driven with their guns live -- until the owner rules
on them in #427. A vehicle in neither the table nor the list is not marked.

**Spawn by name** opens GTA's on-screen keyboard, titled with the row's label.
While it is up the menu reads no key (ScaleformUI's `ProcessControl` stands
down while `UpdateOnscreenKeyboard()` is 0), and our raw key layer is told a
screen it cannot see has the keyboard (`BR.Keys.setExternalScreen`), so typing
is not also T, I, T, A and N. Enter asks for the name typed: trimmed,
lower-cased, and only if `IsModelInCdimage` and `IsModelAVehicle` say this game
has it. **Escape cancels and asks for nothing.** The key that closed the box is
still down when it goes, so the menu's Select and Back stay off until both
keys have been up for two frames -- otherwise that Enter would open the
keyboard again and that Escape would take the menu back.

**The request** is `brdevsv vehicle <model> <type>`, the type being the sync
tree the client works out from the model:

| The model is | `IsThisModelA*` says | The tree |
|---|---|---|
| a car, a quad, an amphibious car or quad | car / quadbike / amphibious car / amphibious quadbike | `automobile` |
| a submarine car (Stromberg, Toreador) | nothing; not one of the classes below | `automobile` |
| a motorbike or a bicycle | bike (bicycle too) | `bike` |
| a boat or a jetski | boat | `boat` |
| a helicopter | heli | `heli` |
| a blimp | nothing; class 15 or 16 | `heli` |
| a plane | plane | `plane` |
| a submarine | nothing; class 14 | `submarine` |
| a trailer | nothing; class 11 or 19 | `trailer` |
| a train | train | refused on the client |

A name that is not a vehicle this game has, or a train, is refused by the
client with `<name> cannot be spawned`, as a warning toast and on F8.

**The server** takes a model name of letters, digits, `_` and `-` (64 at
most, lower-cased) and one of `BR.Config.DevMenu.vehicleTypes`, and runs
`brcar`'s spawn for the asker: `CreateVehicleServerSetter`, in front of them,
a quarter turn across, in their routing bucket. **Any model**: `brcar`'s
allowlist pre-check is `brcar`'s and stays in `brcar`, which still refuses
what it always refused. A success is a line on F8 (`adder (0xB779A091) as
automobile, netId …, bucket …`); a refusal is `brcar`'s own sentence as a
toast -- `no ped for <id> yet …`, `the engine refused to create <model>`,
`the platform refused to create <model> as a <type>` -- or `<model> was
created and is already gone, or its handle never resolved`.

**The tree is held to the model** (#426's review). The server setter does
not check it, but every client does as the vehicle reaches it
(`gta-net-five`'s `netSyncTree.cpp`): a model that is not a vehicle is not
created, a heli, boat, bike, submarine, trailer, plane or train tree holding
a model of another type gets a stand-in (a Buzzard2, a Dinghy2, a Sanchez, a
Submersible, a Tanker, a Cargo Plane, a Freight), and the automobile tree
checks nothing. So `vehicle adder plane` would be a Cargo Plane in a bucket
the whole match shares. Every model of the base game is in
`config/vehicle_models.lua` with the tree the game builds it as, and a
request naming another is dropped like any line no row could have sent --
the rows never send one. Only a model that table does not have, an add-on, is
taken at the client's word.

**Where it lands, by its size.** Turned a quarter across, a vehicle's width
points at the asker, and at five meters nearly every plane and helicopter, the
blimps, the Kosatka and the Tug reached them -- the Cargo Plane's wing reaches
48.9 m from its center. So a model the table has goes out to its reach plus
three meters, never under five, and one whose bottom sits more than a meter
below its origin (the asker's own origin is a meter above the ground) goes in
higher by the difference, so it is not put into the ground: the Cargo Plane
lands 51.9 m out and 5.6 m up, a Hydra 8.7 m out, an Adder at five meters, as
every car did.
An add-on goes five meters out at the asker's height. **Why the table and not
the client's measure:** the server already needs the table for the tree, its
sizes are the game's own figures for every model, and nothing more is taken
from the client; `GetModelDimensions` documents nothing about a model that
is not loaded, and could not be tried here without a game running.

**The table** is written from the game's own vehicle data (DurtyFree's
`vehicles.json`, game build 3717), never by hand:

    py tools/vehicle_models.py <path to vehicles.json>          write it
    py tools/vehicle_models.py <path to vehicles.json> --check  is it current?

921 models: 710 automobile, 67 bike, 22 boat, 35 heli, 43 plane, 4 submarine,
29 trailer, 11 train; 125 armed. A name the game's hash does not come from is
refused, and nothing is written. The manifest loads it into the server alone;
without it the spawn refuses every model and says the table is not loaded.
The same run writes `config/vehicle_weapons.lua`: the 166 vehicle weapons the
data lists on any model, each with its hash, joaat of its name. **Neither is
edited by hand, and a hand edit fails the build** (#426's second review): each
file's header carries an FNV-1a of its body -- every byte from `BR = BR or {}`
on -- and `tools/check_vehicles.lua` recomputes it, so a tree, a size, an
armed flag or a weapon changed by hand is caught without the dump.

**Where it works: in warmup, or alive in a match.** **Not from the lobby**,
which answers `no match running`: every lobby player stands on the one lobby
mark in one shared bucket, so a car there would sit in every lobby player's
shot. And not in the plane or the drop, downed or out, which answer `only in
warmup, or alive in a match` before anything is built: in the plane and the
drop the gamemode is carrying you, and a seat would pull you off the bus
mid-flight; downed or out, nobody drives. These are `client/vehrefuse.lua`'s
own two states, the ones a player takes a vehicle in.

**What it builds is exempt** (owner, 2026-11-01: *"yes exempt dev menu
vehicles, and put me in the driver seat"*). Nobody is put out of it, its gun
is not held off, and nobody is filed against for it, whoever sits in it:

- **The server holds the truth.** Once the spawn has built it, the row
  records the vehicle in `server/vehicles.lua`'s in-memory record
  (`BR.Vehicles.exemptDevMenuVehicle`), keyed on the server's own handle and
  checked against the model it built, since the platform reuses handles. It
  is pruned when the platform removes the entity (`entityRemoved`) and swept
  of dead entries at every write. The occupancy detector skips a vehicle in
  it (no dwell, no count, no case), and `server/damage.lua` and
  `server/strip.lua` leave its own gun alone: a hit or a launch of a vehicle
  weapon (`config/vehicle_weapons.lua`, every model's, so an add-on mounting
  a gun of the base game is covered), or a blast of a type Rockstar's data
  gives only to vehicle guns, from somebody seated in it is neither refused
  nor canceled, and a vehicle weapon in a hand there is no strip case. The
  weapon is asked before the seat. **Its own gun, not any gun** (#426's second
  review): a carbine of ours fired from the same seat is judged as ever, and a
  trainer's weapon -- in no row of ours and no vehicle's -- is refused and
  filed, and stripped and reported, as it is anywhere. In a dev menu
  Technical, a #322 model too, the trainer's hit and launch meet the disarmed
  seat's backstop like anybody's.
- **Only a dev box can hold one.** The writer refuses unless
  `BR.Server.devMode == true`, and so does the spawn before it, behind a
  door that asks the same. `tools/verify.sh` pins the writer to this row.
  `brcar`'s vehicles are never in the record.
- **The client gets a hint, and believes it on a dev box alone.** The writer
  also sets a replicated state bag on the vehicle
  (`BR.Config.DevMenu.vehicleStateKey`, `brDevMenuVehicle`), and on a dev box
  `client/vehrefuse.lua`, which is advisory, neither ejects anybody from a
  vehicle carrying it nor holds its gun off; `client/inventory.lua`'s strip
  leaves a vehicle weapon the engine puts in a hand there. Each reads the
  hint only where it would otherwise act, and only while `BR.Dev.on()` --
  `br_devMode`, which the server replicates and no client sets for another.
  **No server code reads it**: a client can write state on an entity it
  owns. And that is why the clients ask dev mode first (#426's second
  review): `sv_entityLockdown relaxed` lets a client own an ambient Buzzard,
  and a cheat that hung the hint on one made every honest client that got in
  after stay in and keep the gun, while the server -- its record empty --
  filed against them. Off a dev box the hint is not read. On a dev box a
  forged one still fools the clients that read it, and that is all: the
  server files from its own record.

**You are put in the driver's seat.** The server calls the platform's own
`SetPedIntoVehicle`, an RPC your client runs, once a client holds the
vehicle (`NetworkGetEntityOwner`), and again every 250 ms until the
vehicle's own driving seat names you, for five seconds at most. An NPC the
platform put in the driving seat is deleted first; another player in it ends
the try. If the seat cannot be taken -- the vehicle never reaches a client,
it is gone, or somebody else is driving -- the vehicle stays where it landed,
still exempt, and you are told once: `<model> was built, but you could not
be put in it`. If you die, board or leave on the way, the seat is dropped
without a word -- and so it is if you have moved on (#426's second review):
got into anything since the press but the vehicle built for you (the one you
pressed from does not count: asking from a seat is asking to be moved), or
gone more than 10 m from where you pressed, or your position cannot be read.
The warp can land seconds after the press, and must not pull you back to it.
The pass is a scheduler job that cancels itself when nobody is left to seat,
and the next press starts it again under the same name -- which `BR.Sched`
now allows the moment a job is canceled, not one sweep later (a press in that
tick used to throw `duplicate job name`, after the vehicle was built).
Sources: `rpc_spec_natives.lua` declares
`SET_PED_INTO_VEHICLE` a context RPC, which `ServerRPC.cpp` sends to the
ped's owner; `ClientRPC.cpp` resolves a server-setter vehicle at once
without waiting for it, which is why this waits for an owner and checks the
seat; Qbox's `qbx.spawnVehicle` (`qbx_core`, `modules/lib.lua`) seats the
same way. The NPC: forum.cfx.re/t/4936285 and /t/4947251, where Cfx.re's
Linden called it fixed in commit 631484ec (2024).

**What a server-side vehicle does that a trainer's does not.** It is
`POPTYPE_MISSION` and nobody owns it until a client in range takes it; it is
left on the platform's default orphan mode, so it is collected once no player
has it in scope, and it may vanish on its own (citizenfx/fivem#2623, open).
`brcar`'s is not seated: it lands in front of the player it names.

**The spawn is dev mode's alone.** `BR.Vehicles.spawnInFront` builds any
model with no allowlist, so it refuses unless `BR.Server.devMode == true`
whatever its caller checked, and `tools/verify.sh` pins its callers to
`brcar` and this row, line for line: a third, an alias or a wrapper fails the
build, and so does `brcar`'s call outside `brcar`'s handler. It pins the
record the same way -- one writer, one line that puts a vehicle in it -- and
no server code may touch an entity's state but the writer's one `set`.

**`brcar` builds no train** (#426's second review). Its type defaults to the
model's own tree, and a train's is `train`, which the server setter cannot
build a working train in; `brcar` refuses that tree, typed or not, as the
dev menu does.

## What the server checks

Every word, against the lists the rows are built from: an hour 0-23 or
`reset`; a weather of `BR.World.WEATHERS` or `reset`; a state of
`BR.Config.DevMenu.states`; an amount of `BR.Config.DevMenu.volts`; a player
id and token; `on` or `off`; a model name (`BR.Config.DevMenu.modelWord`) and
a sync tree of `BR.Config.DevMenu.vehicleTypes` -- `train` is not one -- that
is, for a model of the base game, the tree the game builds it as. Anything
else is a request no row could have sent, and it is dropped with the usage
line on F8. Every request read spends
the player's slot, good or bad; one inside `minIntervalMs` (250 ms) of the last
is dropped unread, and only a pause's rows are sent back, so a pause box shows
the truth. The server console cannot use `brdevsv`; its commands are the
console verbs themselves.

## The profile store

Give volts and Give Yubikeys write stored profiles through br_ddb. **On a
dev-mode server those are the `dev-` tables**: br_ddb forces every table it
names to `dev-br-*` and `dev-ringmaster-*` whenever `sv_devMode` or
`br_devMode` is on, and ignores the prefix convars while it does
(`js-src/br_ddb/src/prefix.js`; [DEPLOY.md](../DEPLOY.md), "A dev box uses
`dev-` tables"). Those are the convars both gates above read, so the menu
writes `dev-br-players` and never `br-players`. Both rows are on.

**And they ask br_ddb first.** br_ddb resolves its prefix once, at its own
start, so dev mode turned on live with br_ddb left running would leave it on
the production tables while every gate in br_core opens. So the two writes --
`BR.Debug.grantVolts` and `BR.Terminal.devKey`, which `brvolts` and
`brterminalsv key` share -- ask `BR.Debug.productionTables()` first. It reads
`br_ddb/server/tables.lua`'s export, which reads the same two convars the
same way as `prefix.js`, as br_ddb starts. Unless br_ddb named the `dev-`
tables, or is not running at all (nothing is written then), the give is
refused: `br_ddb started outside dev mode, so it writes the production
tables -- restart br_ddb`. A br_ddb that cannot answer counts as production.

One other dev path ends in a profile write without asking: a key put down
with `bryubikey drop` and picked up is a real pickup, and writes through.

## Tests

`tools/test_devmenu.lua`: the server door behind the real `devgate.lua` (off,
started-off, `== true`, console, strangers), every argument, every row's
dispatch with the asker's match, refusals as toasts, the pushed rows and the
rate; the client over the real `client/menu.lua` (the labels in order, no
descriptions, F10 mapped once and only on dev mode, every row's line, the
answer applied in place, names stripped of GTA's text codes); and every line
the rows can type, taken by the server; and `tables.lua` held to `prefix.js`.
The vehicle spawner runs the **real** `server/vehicles.lua` over modeled
natives and the real `config/vehicle_models.lua` -- the server setter's
arguments, the position, the routing bucket, any model while `brcar` still
refuses, every refusal and the lobby; a model of the base game only as its
own tree and an add-on as any; every one of the 921 put down clear by its
size; the spawn's own dev-mode test; a server without the table refusing;
the states a vehicle is had in; the record (written by this row and not by
`brcar`, pruned on removal, forgetting a reused handle, swept at every write,
empty off a dev box) and its replicated hint; and the seat (not before a
client holds the vehicle, the RPC until the seat says so, an NPC deleted, a
player never, five seconds and one sentence, dropped quietly when the asker
dies or leaves, a second vehicle replacing the first) -- and the client over
a modeled `GetAllVehicleModels`: the class rows, names,
fallback, sort, rows that share a name told apart by model, and Armed marks
from the table and the unruled list, the tree every kind of model is asked
as, the keyboard and every key that closes it, and the library's trail back
through the submenus, a switch that throws included. The verbs' bodies are
covered where their commands are: `test_roster` (force and skip on a given
match, the one-match warmup pause, and `brcar` itself, every failure line
under it and its default tree; and the exemption at the detectors: the
occupancy detector skipping a recorded vehicle and filing one that carries
only the hint, and a recorded vehicle's gun canceled and refused nowhere),
`test_ringmaster` (its gun in a hand is no strip case), `test_vehrefuse`
(the client's hint: let in, not emptied, its gun not held, the hint read
only where it changes something), `test_storm` (the one-match storm pause), `test_airdrop`
(`dropNow` on a given match), `test_stats` (`grantVolts`'s answers and the
production-tables refusal), `test_yubikey` (`devKey`, and the same refusal),
`test_shared`. `tools/check_vehicles.lua` holds the `armed` marks to their
rule, row by row, and the unruled list to its names, clear of every row, with
every ruling on its models what it was; re-derives every hash in
`config/vehicle_models.lua`; and holds the marked set to exactly the 125
models the game's data arms, naming any it misses or adds.
