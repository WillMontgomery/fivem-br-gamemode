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
| **Unit tests** | 10 suites, ~3,900 assertions, over the pure shared modules, the server model, the client interaction layer, and the two subsystems that reach AWS. |
| **Scope gate** | Bans OneSync scope-limited natives from client gameplay code. |
| **Weapon table** | Re-derives every weapon hash from its name. |
| **Drive-by data** | The one file here the *game* parses instead of us. Every firearm the gamemode issues is named in `br_environment/data/vehiclelayouts.meta` — its list **replaces** the base game's, so a gun left off silently loses drive-by — and the file still redefines two weapon groups and nothing else. See [Vehicle data overrides](vehicle-data.md). |
| **POI siting** | Spacing, water, no-loot zones, distance to roads. |
| **Forward locals** | Catches a `local function` called above its own declaration. |
| **Config report** | The convar allowlist may not name a credential. |
| **Voice defaults** | Voice modes are mutually exclusive, and the default agrees in Lua, in TypeScript and in the built bundle — three copies of one constant, compared as text. |
| **Tunable overrides** | Overridable keys are server-only, and every consumer loads them in order. |
| **Manifest coverage** | Every `.lua` is declared in an fxmanifest. |
| **Shared coverage** | Anything dropped into `br_lib` is actually loaded. |
| **Deploy payload** | The deploy's own payload check still works. |
| **Vendored third-party** | For every vendored resource: the licence is kept, the upstream version is recorded, the patch log and the source agree **in both directions**, and `deploy.sh` still syncs it. |
| **Console capability boundary** | `dispatch.sh`'s SSH verb set, exactly — matched on the *shape* of a case arm, so a verb with a new name cannot be invisible to it. |
| **Branch-switch invariant** | No path to a hard reset that skips the dispatch blob check. |
| **Incident surface** | Only `BR.ShotSuspicious` can reach the Ringmaster. |
| **Timeline entry kinds** | Every match-timeline `kind` the Lua side writes is one `close.js` stores. The two live in different languages in different directories, and a kind added on one side alone is a timeline entry that silently never arrives. |
| **Secrets** | The only gate that scans the whole repo rather than `resources/`. |
| **br_ddb bundle** | The committed bundle still matches `js-src/br_ddb`, and the ban rule passes its cases. Drift presents as "my change did nothing" with nothing wrong in any log. Skipped, not failed, without Node. |
| **Duplicate console commands** | One name, one registration — three collided at once in #137. |

### The suites

Counts are what `verify.sh` printed on **2026-08-20**, and they are here so a
suite that quietly stops running is visible rather than merely green. They drift
upward constantly and are meant to; what matters is that no row drops or
flatlines. The previous set in this table was a month old and understated the
total by roughly 800 assertions, which is a suite and a half.

| Suite | Assertions | Covers |
|---|---|---|
| `test_shared.lua` | 836 | The pure modules: RNG determinism, geometry, storm solving, loot generation, combat validation, descent classification, bus doors, the DBNO rig. No FiveM dependency at all. |
| `test_roster.lua` | 1,397 | The server model end to end — roster, parties, squads, match state machine, bus, storm, loot streaming, inventory. The big one, and since 2026-08-20 the only one that can reach an admin console command: its `RegisterCommand` shim was `function() end`, so every one of them loaded into nothing and could never be run. |
| `test_loop.lua` | 42 | The client loop registry: bands, suspension after repeated errors, enable/disable. |
| `test_sched.lua` | 41 | The server scheduler: intervals, duplicate-name refusal, stepping. |
| `test_stats.lua` | 164 | XP and placement arithmetic. It compares payout terms **against each other** and pins none of them, which is what let the 50% Volts cut land green while a *partial* rescale — the plausible mistake — would have failed. |
| `test_ringmaster.lua` | 281 | The Ringmaster surface: the incident envelope, the gate, kick and maintenance. |
| `test_artifacts.lua` | 119 | Incident screenshots: three timed frames, the ten-second rule on corroborations, the cap of nine and the clean no-op past it, a subject who disconnects mid-schedule, `screenshot-basic` absent, a failed upload, and a client that never answers. Loads `br_core/server/artifacts.lua` itself. |
| `test_client.lua` | 607 | The client interaction layer — keybinds, holds, prompts, loot pickup — with the FiveM natives stubbed and the frame band stepped by hand, the same shape `test_roster.lua` uses for the server. It also carries the engine friendly-fire rule (#115), written out once from the external record so that a fix which merely agrees with itself still has to agree with that. |
| `test_config.lua` | 286 | The server-tunable overrides: strict convar parsing, ranges refused rather than clamped, a renamed config key as a hard failure, the load-time hook on a server / client / bare state, and the shipped `.cfg` examples run through the real parser. |
| `test_admin.lua` | 128 | The in-game admin console (#23): who is offered the Admin tab and when the answer is settled, the handoff mint and its timeout, and the cost of the common case — an ordinary player with no grant must pay nothing at connect. |

`test_client.lua` is the odd one out and deliberately so: every other suite here
is server-side or pure arithmetic, and all three of the regressions that shipped
on 2026-08-16 landed on a **client** interaction that no gate touched (#140).

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

| Command | What it answers |
|---|---|
| `brnativecheck` | Does every native this project leans on exist and bind? Run **before** an in-game test — a wrong native name is invisible to `luac -p` and to unit tests. |
| `brprobe` | What do the natives actually *do*? Sub-modes for ammo, vehicles, armour, crates. `brprobe raw` suspends our own writes so the engine can be watched alone. |
| `brhitch` | Frame-time *distribution* and the worst frame, with the callbacks that were expensive during it. An average cannot find a hitch. |
| `brbench <name>` | A real per-call cost, by running a callback many times — `brperf` structurally cannot measure sub-millisecond work at 1 ms timer resolution. |
| `brperf` / `brloop` | Per-callback totals, and disabling one to bisect. |
| `brdriveby [s]` | Why a passenger cannot fire (#197). Samples across frames — a disabled control lasts one, and a stow is indistinguishable from the climb-in animation until you count them — then names the cause: our own panel, a control something holds down, a permission never asserted, the seat's weapon rule, or our seat-weapon override having been ignored by the game. |
| `brloot` | What this client can see, plus crate drag counters. |
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
