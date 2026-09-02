# Testing

What the suites and gates do, when to run them, and the bugs they have caught.

[← Back to the main README](../README.md)

---

## The one command

```bash
bash tools/verify.sh
```

Runs everything below in increasing order of strictness and exits non-zero on
any failure. It is wired as a **pre-commit hook**, so nothing lands red.

Lua 5.4 is required and is not on PATH by default on Windows; the script finds
it at `$LOCALAPPDATA/Programs/Lua/bin/`.

---

## What runs, and what each part is for

| Stage | What it proves |
|---|---|
| **Syntax** | `luac -p` on every `.lua`. FiveM runs Lua 5.4 and so does this, so a pass means the resource will at least load. The floor, not the ceiling. |
| **Unit tests** | 28 suites, ~10,300 assertions, over the pure shared modules, the server model, the client interaction layer, the subsystems that reach AWS, and — increasingly — the individual server and client files a rule actually lives in. |
| **Scope gate** | Bans OneSync scope-limited natives from client gameplay code. |
| **Weapon table** | Re-derives every weapon hash from its name, and requires every weapon and throwable to say explicitly whether a car seat accepts it — a missing `driveby` field reads as "no" and would silently drop a gun out of the drive-by hint. See [Vehicle data overrides](vehicle-data.md). |
| **Vehicle table** | Re-derives every refused-vehicle hash from its name, signed and unsigned. The refusal list is what keeps aircraft and weaponised vehicles out, including out of the showroom catalogue, so a hash that stopped matching its name would silently stop refusing anything. |
| **POI siting** | Spacing, water, no-loot zones, distance to roads — and since the station ambulances landed, the 23 surveyed ambulance spawns held to the same rules. |
| **Map boundary** | The surveyed ring is simple and closed, its perimeter and area still recompute to what the survey printed, and every POI and ambulance spawn is inside it. What makes the table hard to edit by accident: the numbers are pinned to a survey rather than to whatever is in the file. |
| **HUD, squad panel and spectating** | Nine gates covering the surfaces a unit test cannot see rendered: `spectator microphone`, `spectator HUD`, `squad voice marks`, `squad levels`, `squad revive keys`, `notice names`, `key glyphs`, `vitals bars` and `death verdict`. Each pins a boundary rather than a layout — what crosses to the client and what does not. **`notice names` is the one with teeth**: a player's name is the only part of a toast a player writes, so it checks every sender for a name formatted into a sentence, which would be a formatting injection with a sign-up form in front of it. |
| **Forward locals** | Catches a `local function` called above its own declaration. |
| **Player states** | Every `PlayerState` reference across the tree names one of the nine that exist. A typo'd member is `nil`, and a comparison against `nil` is not an error — it is a branch that never runs. |
| **Bool natives** | A `BOOL` native read as a bare Lua truth value, against a recorded baseline of the known set. `0` is truthy in Lua and several natives answer `1`/`0`, so `if IsThing() then` is true forever; the gate proves the tree has not got worse, and `test_bool_natives.lua` proves the gate still detects. |
| **Config report** | The convar allowlist may not name a credential. |
| **Voice defaults** | Voice modes are mutually exclusive, and the default agrees in Lua, in TypeScript and in the built bundle — three copies of one constant, compared as text. |
| **Tunable overrides** | Overridable keys are server-only, and every consumer loads them in order. |
| **Manifest coverage** | Every `.lua` is declared in an fxmanifest. |
| **Shared coverage** | Anything dropped into `br_lib` is actually loaded. |
| **Deploy payload** | The deploy's own payload check still works. |
| **Vendored third-party** | For every vendored resource: the licence is kept, the upstream version is recorded, the patch log and the source agree **in both directions**, and `deploy.sh` still syncs it. |
| **Console capability boundary** | `dispatch.sh`'s SSH verb set, exactly — matched on the *shape* of a case arm, so a verb with a new name cannot be invisible to it. Also pins the three files allowed to call the sound natives directly, and that `/brsfx` keeps its silence probe and reads that `BOOL` through the `1`-or-`true` idiom. A set/name pair written at a call site cannot be auditioned and fails *silently* when it is wrong, which is the shape that has cost this project three rounds. |
| **Dev gate on console commands** | Every console command goes through the one wrap in `br_lib/shared/devgate.lua`, exempting only `brkick`, `brspectate` and `brring`. It checks the four things construction rests on — the exempt set parsed as a set, the raw-door allowlist, every command-registering resource loading `devgate.lua`, and loading it **first** — rather than a list of today's command names, which would stay green forever while the next command arrived ungated beside it. That is the same denylist-inside-the-gate failure `configreport)` not matching `config)` already cost this repo. |
| **Branch-switch invariant** | No path to a hard reset that skips the dispatch blob check. |
| **Incident surface** | Only `BR.ShotSuspicious` can reach the Ringmaster. |
| **Incident notice surface** | Exactly one sender of the "See something suspicious?" notice, one emitter of the `br:incident:filed` acknowledgement every creation path converges on, one asker of `br:ddb:putIncident`, and no acknowledgement from the corroboration handler. It pins the choke points rather than counting the creation paths, so a new detector is covered on the day it lands (#214). A second announcer would not fail a test nobody wrote — it would quietly tell the offender, which is #93; and a path writing its own row would file cases nobody is ever told about, with every other gate green. |
| **Timeline entry kinds** | Every match-timeline `kind` the Lua side writes is one `close.js` stores. The two live in different languages in different directories, and a kind added on one side alone is a timeline entry that silently never arrives. |
| **Secrets** | The only gate that scans the whole repo rather than `resources/`. |
| **br_ddb bundle** | The committed bundle is the one recorded against the current `js-src/br_ddb`, and the ban rule passes its cases. A sha256 fingerprint in `dist/fingerprint.json`, **not** a rebuild: it catches a source edit nobody rebuilt — which presents as "my change did nothing" with nothing wrong in any log — and it does not prove the bundle is correct or untampered. Refresh it after a real rebuild with `tools/br_ddb_fingerprint.sh`. The rebuild version of this gate needed `node_modules` and therefore never ran once (#218). |
| **br_ddb bundle over the wire** | The same question asked of a **box**: `status` reports the bundle actually deployed there, and every absence as `null` rather than as a blank that reads like an answer. The gate above compares two things in this repository; this one compares this repository against what is running. |
| **Duplicate console commands** | One name, one registration — three collided at once in #137. |

### The suites

Counts are what these suites printed on **2026-09-01**, in `verify.sh`'s own run
order, and they are here so a suite that quietly stops running is visible rather
than merely green. They drift upward constantly and are meant to; what matters
is that no row drops or flatlines.

> **The previous version of this table had ten rows and understated the total by
> roughly 6,400 assertions** — more than the total it claimed. It listed the
> suites as they stood on 2026-08-20, and eighteen had landed beside it in the
> twelve days since, each one this table's own failure mode: a suite nothing
> lists is a suite nobody notices stopping.

| Suite | Assertions | Covers |
|---|---|---|
| `test_shared.lua` | 2,050 | The pure modules: RNG determinism, geometry, storm solving, loot generation, combat validation, descent classification, bus doors, the DBNO rig, and the dev gate's own wrap. No FiveM dependency at all. |
| `test_loop.lua` | 91 | The client loop registry: bands, suspension after repeated errors, enable/disable. |
| `test_sched.lua` | 41 | The server scheduler: intervals, duplicate-name refusal, stepping. |
| `test_roster.lua` | 1,931 | The server model end to end — roster, parties, squads, match state machine, bus, storm, loot streaming, inventory. The big one, and the only one that can reach an admin console command: its `RegisterCommand` shim was `function() end`, so every one of them loaded into nothing and could never be run. It is also where the revive key's central rule lives, against the real `eliminate()`. |
| `test_stats.lua` | 186 | XP and placement arithmetic. It compares payout terms **against each other** and pins none of them, which is what let the 50% Volts cut land green while a *partial* rescale — the plausible mistake — would have failed. |
| `test_ringmaster.lua` | 444 | The Ringmaster surface: the incident envelope, the gate, kick and maintenance. |
| `test_artifacts.lua` | 119 | Incident screenshots: three timed frames, the ten-second rule on corroborations, the cap of nine and the clean no-op past it, a subject who disconnects mid-schedule, `screenshot-basic` absent, a failed upload, and a client that never answers. Loads `br_core/server/artifacts.lua` itself. |
| `test_airdrop.lua` | 823 | Aerial supply drops (#88), in two halves that both load the real files: the pure solver, plus `server/airdrop.lua` itself for the schedule, the siting decision, the phase cap and the auto-open. Its best assertion is the invisible one — that an airdrop-only item appears in no world roll, proved by generating a whole layout and looking. |
| `test_client.lua` | 1,266 | The client interaction layer — keybinds, holds, prompts, loot pickup — with the FiveM natives stubbed and the frame band stepped by hand, the same shape `test_roster.lua` uses for the server. It also carries the engine friendly-fire rule (#115), written out once from the external record so that a fix which merely agrees with itself still has to agree with that. |
| `test_spectate.lua` | 71 | `client/spectate.lua`, which no other suite loads. The property is not which controls are in the list — a text gate could do that — but that the list is **let go on every path out of a session**, which is a step of the loop rather than a string in a file. A spectator who cannot move after a match is worse than the accidental gunshot that prompted the work. |
| `test_matchexit.lua` | 63 | That every way out of a match takes the match's surfaces with it (#204). It loads the whole mirror, `client/state.lua`, because the property is a **sequence**: a death word that walks into the lobby is invisible to any static check and visible only in roster deltas shaped the way `server/match.lua` really shapes them. |
| `test_lobbyseq.lua` | 289 | The lobby entrance, and the first suite to **model** `Citizen` rather than stub it away. The property is an **order** — the ped is teleported to its warmup spawn and only then becomes networked (owner, 2026-08-29) — one frame wide, on somebody else's screen, and identical in a screenshot either way. Threads are coroutines, the clock is stepped, and the ped actually walks, which is what also lets the entrance be abandoned mid-path leaving no camera and no half-finished task. |
| `test_landtime.lua` | 54 | The landing instrument, and the only suite whose subject is a **measuring instrument** rather than a behaviour. An instrument can agree with the thing it measures by accident: a timer taking "the feet are down" from a clause of the landing test would read zero for exactly the landing #245 is about. So a clause is held false for five seconds and five seconds is what must come out, from a ground truth no ped task owns. |
| `test_config.lua` | 286 | The server-tunable overrides: strict convar parsing, ranges refused rather than clamped, a renamed config key as a hard failure, the load-time hook on a server / client / bare state, and the shipped `.cfg` examples run through the real parser. |
| `test_admin.lua` | 128 | The in-game admin console (#23): who is offered the Admin tab and when the answer is settled, the handoff mint and its timeout, and the cost of the common case — an ordinary player with no grant must pay nothing at connect. |
| `test_community.lua` | 69 | One envelope, and it runs the **real** `config/overrides.lua` rather than assigning `BR.Config.Community` by hand — which makes it a seam test rather than a restatement: it fails the day the convar stops reaching the table the sender reads. What it guards is the `{}`, so an operator clearing the invite takes the Discord card down on a page already on screen. |
| `test_guild.lua` | 101 | The first suite whose subject is an **outside service**. Discord's answers, and the reading of them: a 404 that means "not a member" against a 404 that means "this bot cannot see that guild", the half-configured states, a guild id that is not a snowflake, and the rule that only a confirmed yes hides the card. |
| `test_fuel.lua` | 200 | Its own suite rather than a block in `test_roster` because the property spans three layers: the pure solver, the tank size **derived** from the map AABB, and the registry that makes a tank survive its driver. Split across existing suites, the interesting case — a car staying dry for whoever gets in next — would be testable in neither. |
| `test_boost.lua` | 86 | The vehicle boost, where every number the owner gave is about **time** and every interesting property is a relationship between two of them: a 4-second boost whose first 2 are a ramp, so the ramp completes halfway and stays complete; a partial spend that gets a shorter ramp and is not rescaled; and a 4s-empty/6s-refill meter whose 40% duty cycle the server's claim ceiling has to converge on, or the fuel surcharge stops describing anything. |
| `test_vehdamage.lua` | 225 | #213's handling applier, and the **fixture is the argument**. `GET_VEHICLE_HANDLING_FLOAT` reads the vehicle's own clone of the handling, so it answers our own write — an applier that read and multiplied would multiply by five ten times a second, and a fixture whose getter answered a constant would agree happily. Template and clone are two tables, and the central assertion is that two hundred passes leave the numbers where one pass did. |
| `test_icons.lua` | 385 | A **gate** rather than a shipped module. `check_weapons.lua` can only read the one real `ItemIcon.tsx`, so it proves that file is clean and cannot prove it would notice a dirty one. The rules are pure functions fed deliberately broken sources — the only way a detector is shown to still detect. |
| `test_vehrefuse.lua` | 77 | #215, which rejects a refused vehicle **at the door**, during the entry animation, and falls back to ejecting whoever got in anyway. The two paths are one line apart and indistinguishable in a screenshot — the slow one still ends with the player standing next to the helicopter — so `entering` and `myVeh` are never both set, which is what makes a file that only checks the seat fail rather than pass a second late. |
| `test_rescue.lua` | 226 | The CPR kit's routing arithmetic (#191). "Prefer a point that will be inside the circle **when the ambulance arrives**" only differs from the obvious wrong version during a shrink, on a long route — several minutes into a phase and then dying in the right place — and the failure is invisible when it happens, because the player is simply delivered into the storm and it reads as bad luck. |
| `test_ambheal.lua` | 101 | Healing in the back of an ambulance, where four of the owner's rules are effectively unobservable: a doors-shut refusal looks identical to an unimplemented prompt, "one heal per ambulance" needs two players pressing within a few frames, partial-on-interrupt is indistinguishable from the wrong implementation on any heal that completes, and staging a death on the stretcher costs a round whose bad outcome is a stuck ped. The one rule it deliberately does **not** test — that a healing player is killable — is a property of `client/natives.lua`'s invincibility latch and is asserted there. |
| `test_revivekey.lua` | 294 | Everything about the revive key a playtest cannot reach cheaply: the three-minute expiry, the last 2.5 m of a squadmate's walk, a DynamoDB round trip with another elimination landing inside it, and two squadmates pressing buy in the same second. Deliberately **not** where the central rule is proved — "the key is minted on the same edge that spills the inventory" belongs to `server/combat.lua` and is asserted in `test_roster.lua` against the real `eliminate()`, because a sandbox calling `onEliminated` by hand would only test that the module does as it is told. |
| `test_ambulances.lua` | 107 | The 23 station ambulances (#219 step 3), for four rules that are unobservable and expensive. Chief among them the **routing bucket**: a vehicle created in bucket 0 rather than the match's is indistinguishable in game from one that was never created, and the owner reported "our ambulances aren't spawning still" three times for two different bugs that print the same nothing. |
| `test_shop.lua` | 607 | The warmup showroom, and the suite where the fixture argues hardest: the shipped catalogue was **empty on purpose** until the owner authored his own rows, so every behavioural test builds its own three-car catalogue and exactly one reads the real table. It pins three things a playtest cannot see — that a delivered car is exactly the car shown, that the item is handed out **after** the inventory wipe (one line earlier and the wipe silently deletes what was paid for), and that no refund happens under an engine fault nobody can reproduce on demand. |
| `test_bool_natives.lua` | 31 | The second suite testing a **gate**. `check_bool_natives.lua` reads the real tree against a recorded baseline, so it proves the tree has not got worse and cannot prove it would notice if it had. The rules are pure functions fed broken sources — and, just as importantly, every spelling of the **fix**, because a gate that flags correct code gets an exception and then gets deleted. |

`test_client.lua` was the odd one out and deliberately so: every other suite was
server-side or pure arithmetic, and all three of the regressions that shipped on
2026-08-16 landed on a **client** interaction that no gate touched (#140). It is
no longer alone — `test_spectate`, `test_matchexit`, `test_vehdamage`,
`test_vehrefuse`, `test_lobbyseq` and `test_landtime` each stand up a client
file of their own, and each says in its header why a block inside `test_client`
would not have done.

### How the server suite works without a server

`fakeTime` plus `BR.Sched.step(fakeTime)` — time is a variable the test moves,
not something it waits for. Assertions are made **on the wire** (`sent`,
`eventsOf`) rather than on server tables, because what a client actually
receives is the thing that matters.

> **Always advance `fakeTime` past the job interval before stepping**, or the
> test is vacuous — the job never runs and every assertion passes trivially.

---

## The rules that keep this honest

**1. Every regression test must be proven load-bearing.** Write the test, then
*revert the fix* and confirm it fails, then restore. A test that passes against
the bug it was written for is worse than no test, because it is a claim of
coverage that is not there.

**2. Assert on behaviour, not on constants.** `check_pois.lua` computes the
budget from the live config rather than a literal, so retuning the storm cannot
leave a test asserting a number nothing uses. The two-headshots test filters by
raw damage (`>= 60`) rather than by weapon name, so a future weapon cannot slip
through on a naming accident.

**3. Say so when something is not testable.** The consumable double-count bug
(below) cannot be reproduced in the harness, because the harness's health
sampler stub zeroes armour on every step. That is written into the test file
next to the case rather than papered over with a test that passes for the wrong
reason.

**4. A stub that agrees with the code it tests proves nothing.** This is the
rule that cost the most to learn, and it is the reason #129 survived **six**
rounds of fixes with a green suite.

The stub for the raw key sample was `return keys[vk] == true` — a strict Lua
boolean. `keybinds.lua` then stored that value and compared it with `== true` in
two places. Stub and code encoded the *same assumption*, so they agreed, the
suite passed all 202 of its assertions, and the interaction was dead on the
owner's machine: one press of the trail key counted **545 presses** and toggled
the smoke 545 times, and a crate hold ran **446 frames earning 0 of 1000 ms**
(#129/#131, 2026-08-16). Every one of those six rounds was spent in the loot
code, because the suite was reporting the key layer as proven.

**FiveM natives declared BOOL do not have to hand Lua a boolean**, and this
codebase already carried two scars from exactly that — `natives.lua` compares
`hit == 1 or hit == true` on the shape test, `spawn.lua` compares
`== true or == 1` on the screen fade. Both were written *after* the value
arrived as a number in play. The stub was the one place that assumption was
never re-checked.

So the **shape of the returned value is a dimension of the test matrix now**,
alongside which natives the build has: every raw-layer block runs against
`true/false`, `1/false`, `1/0` and `1/nil`. `1/0` earns its place specifically
because **0 is truthy in Lua** — it is the shape that punishes the obvious
one-line normalisation (`v and true or false`), which would read a released key
as held forever.

The general form: when you write a stub, ask what it would take for the stub to
be *wrong in the same direction* as the code. If the answer is "the same
assumption in both", the test is measuring the harness.

---

## What this has actually saved

Every entry below is a real bug that a test or gate caught, most of them before
anyone had to play a match to find out.

### Caught by the gates

**Twenty weapons with unlimited ammo.** GTA returns weapon hashes as *signed*
32-bit ints, so any hash with the top bit set arrives negative and misses a
table keyed by the positive literal. Half the arsenal could never satisfy the
"is the engine holding what we think" check, so nothing was ever deducted.
`check_weapons.lua` now re-derives every hash from its name — a weapon hash *is*
the joaat of its lowercased name — and asserts each resolves from **both** the
signed and unsigned form. Reverting the fix fails 20 weapons by name.

**Two POIs stacked on existing ones.** `check_pois.lua` was written to enforce a
siting rule and immediately found that the *previous* batch had put Braddock
Pass 112 m from Grapeseed and Catfish View 115 m from the lighthouse — two
POIs each generating a full loot budget onto the same ground.

**Bus doors opening over open water.** The first door-zone radii reached out to
sea, and the departure path from Cayo clipped them. `test_roster`'s bus block
failed on the first run, pointing at the exact coordinate.

**A whole subsystem loading silently as nothing.** `client/screen.lua` was
written, committed and deployed without ever being added to `client_scripts`.
Nothing errored — the HUD just quietly used its CSS fallbacks. The manifest
coverage gate exists because a file that never loads produces no error to grep
for.

**Every crate on the map disappearing.** A `local function` called above its own
declaration resolves as a *global*, which is nil. No syntax error, `luac -p` is
happy, and in game the call throws, the loop registry suspends that callback
after five errors, and a whole subsystem goes silent behind one console line.
`check_forward_locals.lua` is a static gate for exactly that shape, and it has
paid for itself twice.

### Caught by the unit tests

**A squad-formation deadlock, then the fix that broke the original rule.** Two
unpartied players formed one squad while the gate demanded two, so the round
never started. The first fix omitted a term and broke the "a single party of
four still blocks" invariant — and the existing tests caught that immediately,
before it shipped.

**67 loot items floating in the Pacific.** The first water mask swallowed
Chumash, Hookies and Galilee — all coastal towns on dry land — and the
generator's inward-shrinking fallback then dropped everything on their centre
points, in the sea. There is now a test asserting no water rectangle may
contain a POI centre.

**The storm closing on open ocean.** Sampling 600 drifts off a coastal centre,
**210 landed in open water**. The anchor was always a dry POI, but nothing
stopped the per-phase drift walking seaward one circle at a time.

**Headshots one-shotting when they should not.** The body-part table was written
at 2.5× and the test caught that Military Rifle landed at 105 damage — a
one-shot, against a rule that said two. Dropped to 2.3 before it ever ran.

**Storm circles escaping their predecessor.** The nesting invariant has a test
asserting zero violations across 5000 draws. When breakout was deliberately
introduced, that test failed — correctly — and was rewritten to assert the new
contract (a reach budget) rather than being deleted.

### What the tests could *not* catch

Worth being explicit about, because it shapes where the effort goes:

- **Client native semantics.** The ammo saga ran six playtest rounds because no
  test can tell you what `GetAmmoInPedWeapon` does on a live ped. That gap is
  what `/brprobe` exists to fill — a diagnostic that prints what the engine
  actually does, rather than another hypothesis.

  **What `test_client.lua` did and did not close.** It can now prove an
  interaction against every *shape* a native may answer in, and against builds
  that lack the raw layer entirely — that is what rule 4 above bought. It still
  cannot tell you which shape *your* build actually returns. The suite proves
  the code survives all four; only `/brprobe` says which one you are standing
  in.
- **A contaminated environment.** One of those rounds was vMenu's infinite ammo,
  not our code at all. A diagnostic claiming to isolate our code should
  enumerate what else is running before anyone reasons from its numbers.
- **Anything visual.** Crate glow, label placement, bar animation. The UI build
  runs `tsc` and a Chrome-103 CSS gate, but "does it look right" needs eyes.

---

## In-game diagnostics

The tests prove the model; these prove the engine. Run in the F8 console.

**Start the server with `br_devMode true` (or `sv_devMode true`) or none of them
will do anything.** Since 2026-08-31 every console command in the project is
behind that one switch, client commands included — owner: "Yes I want all client
and server commands gated behind devmode" — and this is the practical
consequence for anybody running these tests. A gated command typed on a box that
is not in dev mode **prints which gate closed** rather than failing silently, so
the symptom is legible; before you debug a diagnostic that "does nothing", read
the console line. The client half works only because `server/main.lua` now
replicates the resolved answer under `br_devMode`. Until this change the client
had no dev mode at all — both convar names are read on the server and neither
was replicated, so a client's `GetConvar` saw neither — which means gating the
F8 commands without that replication would have killed every one of them on a
dev box too. See [running.md](running.md) for the gate itself, the three exempt
verbs and the keybinds that deliberately go around it.

| Command | What it answers |
|---|---|
| `brnativecheck` | Does every native this project leans on exist and bind? Run **before** an in-game test — a wrong native name is invisible to `luac -p` and to unit tests. |
| `brprobe` | What do the natives actually *do*? Sub-modes for ammo, vehicles, armour, crates. `brprobe raw` suspends our own writes so the engine can be watched alone. |
| `brhitch` | Frame-time *distribution* and the worst frame, with the callbacks that were expensive during it. An average cannot find a hitch. |
| `brbench <name>` | A real per-call cost, by running a callback many times — `brperf` structurally cannot measure sub-millisecond work at 1 ms timer resolution. |
| `brperf` / `brloop` | Per-callback totals, and disabling one to bisect. |
| `brdriveby [s]` | Why a passenger cannot fire (#197). Samples across frames — a disabled control lasts one, and a stow is indistinguishable from the climb-in animation until you count them — then names the cause: our own panel, a control something holds down, a permission never asserted, or the seat's own weapon rule. Also the only check there is on the `driveby` field: it prints our claim next to what the engine did, and says `stowed-unexpected` when they disagree. |
| `brboostwhy [s]` | Why the boost does nothing (#203). A full meter is the symptom of every cause at once — the meter only falls on a frame the loop decides to spend — so the chain is counted instead, rung by rung, and the rung that fails is named: the three virtual-key codes shift can arrive as against the one the binding watches, GTA's own controls on the same key, the seat and class gates, the meter, and whether `APPLY_FORCE_TO_ENTITY` was accepted and the car actually gained the +30 mph. `[key-engine-only]` means the reader is wrong; `[force-inert]` means the physics is; `[key-wrong-code]` names one table entry in `keybinds.lua`. Two rows answer "what ELSE does this key do": a sweep of all 360 control ids on the frames the key is held (the four named rows are a hardcoded list from a table last updated in 2020), and the car's peak lateral speed while boosting. Note that a control row reading `PRESSED` says the key is down and nothing more — no native reports what the engine did with a control. |
| `brsfx` | Which GTA sound to use, chosen by ear instead of off a list. **The browse path is three steps and each one ends by naming the next**: `brsfx sets` lists the 84 sound sets, `brsfx sounds <SET>` lists every sound in one of them, `brsfx play <SET> <NAME>` plays one. That middle step was missing until 2026-08-23 and the owner said so — `find` demands a search substring you have to already suspect, and `audition` *plays* a set rather than listing it, so there was no way to simply see what was in one. `brsfx sounds` is forgiving about case and about a partial set name, says which set it resolved to, and pages at 60 rows saying how many it withheld. The catalogue behind all of it is 325 base-game sound pairs — the calls GTA's own scripts make, with every DLC bank filtered out because those are silent unless something requests them. `brsfx find <substr> [setSubstr]` searches names across sets, and `brsfx audition <SET>` plays a whole set back to back, printing each name as it goes, because choosing is comparative. `brsfx play <SET> <NAME>` plays anything at all, listed or not. **Every play is probed**: the sound goes through a real `GET_SOUND_ID` and `HAS_SOUND_FINISHED` is polled, so a pair the engine reports as over before it could be heard prints `[silent?]` — that is almost always a sound *set* that is not loaded, and it is the answer that separates "I dislike this" from "this never played". `[unprobed]` means the probe itself could not tell, which is a different claim and is worded as one. `brsfx bind <cue> <SET> <NAME>` re-points a cue for the session so a candidate can be judged where it actually fires; nothing is saved, and the command prints the config line to keep. |
| `brloot` | What this client can see, plus crate drag and arrival-arc counters. |
| `brarc` | Does loot arc out of the container, or pop into existence? Drops one item with a known origin and names the link it stops at. Written because the two look identical from a chair, which is how a dead animation survived every milestone since it was written. |
| `brdamagelog` | Records real `weaponDamageEvent` payloads and prints every field. |
| `brdamage off` | Backs the damage takeover out live, without a redeploy. |

---

## Adding a test

New coverage goes into the **existing** suites — no new suite file, so no
`verify.sh` edit. Open a bare `do … end` block after a `describe(...)`, call
`reset()` first, and remember the load-bearing rule: revert the fix, watch it
fail, restore.

The one reason to break that rule is a suite that needs **its own harness**, and
`test_config.lua` is why the exception is written down. Every other suite loads
`br_lib/config/*.lua` once into the global state and reads it; that one has to
load it repeatedly, into fresh sandboxes, with FiveM natives stubbed differently
each time — because what it tests is the config tables being *rewritten* at load.
Dropping that into `test_shared.lua` would mutate the config out from under 836
assertions that read it. A new suite costs one line in `verify.sh`'s loop and a
row in the table above; skip either and it stops running with nothing to say so.

`test_artifacts.lua` and `test_admin.lua` are the two that have since taken that
exception, and both took it for the same reason `test_config.lua` did: each loads
a server file into a harness shaped for it — `br_core/server/artifacts.lua` with
`screenshot-basic` present and absent, and `br_core` plus `br_ringmaster` in one
Lua state so the request/response seam between them is the thing under test.
