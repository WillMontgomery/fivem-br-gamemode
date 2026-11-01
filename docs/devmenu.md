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
| **The server** | `br_core/server/devmenu.lua` (`BR.DevMenu`) | The door, `brdevsv`: the gate, the checks, the rate, and the console verb each row runs. |
| **The spawn** | `br_core/server/vehicles.lua` (`BR.Vehicles.spawnInFront`) | `brcar`'s own server-side spawn, which the vehicle spawner runs too. |

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
| Vehicle spawner | a menu: Spawn by name, then a row per vehicle class | `brcar`'s spawn (`BR.Vehicles.spawnInFront`), any model | **the asker**: in front of them, in their bucket; not from the lobby. See [The vehicle spawner](#the-vehicle-spawner) |

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
the game has none, sorted by name without regard to case. Each submenu wears
the dev menu's bar with its own name in the strip under it, and the library's
own Back walks back one menu at a time.

**The lists are the game's.** `GetAllVehicleModels` is every vehicle archetype
the game registered -- the base game, every DLC, and any vehicle a resource
streams -- and the class and the name are read off each model's model info, so
nothing is loaded to list it. Read once, the first time the spawner opens;
each class's menu is built the first time it opens; all of it is kept.
**Trains get no row** (class 21): the server setter cannot build a train
(Cfx, [forum.cfx.re/t/5217679](https://forum.cfx.re/t/createvehicleserversetter-serverside-spawned-vehicles-despawning/5217679),
2025-08-25: "Its not possible to spawn trains using
CREATE_VEHICLE_SERVER_SETTER").

**"Armed"** is a right-hand label in GTA's red (`~HC_6~`, HUD_COLOUR_RED --
an index into the engine's palette, never the project's cyan or gold), on the
models `BR.Config.IsArmedVehicle` names: every ARMED row of the refused-vehicle
table (which includes every model `IsDisarmedVehicle` names), every TANK row,
and every FLIES row marked `armed = true` -- the aircraft and fliers whose
model the game's vehicle data gives a weapon. A model the table does not name
is not marked, whatever it is.

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
`brcar`'s spawn for the asker: `CreateVehicleServerSetter`, five meters in
front of them, a quarter turn across, in their routing bucket. **Any model**:
`brcar`'s allowlist pre-check is `brcar`'s and stays in `brcar`, which still
refuses what it always refused. A success is a line on F8 (`adder (0xB779A091)
as automobile, netId …, bucket …`); a refusal is `brcar`'s own sentence as a
toast -- `no ped for <id> yet …`, `the engine refused to create <model>`,
`the platform refused to create <model> as a <type>` -- or `<model> was
created and is already gone, or its handle never resolved`.

**Where it works.** Everywhere `brcar` does -- the warmup pad, the plane and
the drop, the match, downed or out -- but **not from the lobby**, which answers
`no match running`: every lobby player stands on the one lobby mark in one
shared bucket, so a car there would sit in every lobby player's shot. In warmup
and in a match the match's vehicle rules still hold: `client/vehrefuse.lua`
puts a player out of a refused vehicle, and the occupancy detector in
`server/vehicles.lua` counts a driver in one and files on the second. A dev
menu vehicle is not excused from either; that is an open question on #426.

**What a server-side vehicle does that a trainer's does not.** It is
`POPTYPE_MISSION` and nobody owns it until a client in range takes it; it is
left on the platform's default orphan mode, so it is collected once no player
has it in scope, and it may vanish on its own (citizenfx/fivem#2623, open).
It is not seated: it lands in front of you, as `brcar`'s does.

## What the server checks

Every word, against the lists the rows are built from: an hour 0-23 or
`reset`; a weather of `BR.World.WEATHERS` or `reset`; a state of
`BR.Config.DevMenu.states`; an amount of `BR.Config.DevMenu.volts`; a player
id and token; `on` or `off`; a model name (`BR.Config.DevMenu.modelWord`) and
a sync tree of `BR.Config.DevMenu.vehicleTypes` -- `train` is not one. Anything
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
natives -- the server setter's arguments, the position, the routing bucket,
any model while `brcar` still refuses, every refusal and the lobby -- and the
client over a modeled `GetAllVehicleModels`: the class rows, names, fallback,
sort and Armed marks, the tree every kind of model is asked as, the keyboard
and the keys that close it, and the library's trail back through the
submenus. The verbs' bodies are covered where their commands are:
`test_roster` (force and skip on a given match, the one-match warmup pause,
and `brcar` itself), `test_storm` (the one-match storm pause), `test_airdrop`
(`dropNow` on a given match), `test_stats` (`grantVolts`'s answers and the
production-tables refusal), `test_yubikey` (`devKey`, and the same refusal),
`test_shared`. `tools/check_vehicles.lua` holds the `armed` marks to their
rule, row by row.
