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
| **Unit tests** | 5 suites, ~900 assertions, over the pure shared modules and the server model. |
| **Scope gate** | Bans OneSync scope-limited natives from client gameplay code. |
| **Weapon table** | Re-derives every weapon hash from its name. |
| **POI siting** | Spacing, water, no-loot zones, distance to roads. |
| **Forward locals** | Catches a `local function` called above its own declaration. |
| **Manifest coverage** | Every `.lua` is declared in an fxmanifest. |

### The suites

| Suite | Covers |
|---|---|
| `test_shared.lua` | The pure modules: RNG determinism, geometry, storm solving, loot generation, combat validation, descent classification, bus doors. No FiveM dependency at all. |
| `test_roster.lua` | The server model end to end — roster, parties, squads, match state machine, bus, storm, loot streaming, inventory. The big one. |
| `test_loop.lua` | The client loop registry: bands, suspension after repeated errors, enable/disable. |
| `test_sched.lua` | The server scheduler: intervals, duplicate-name refusal, stepping. |
| `test_stats.lua` | XP and placement arithmetic. |

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
| `brloot` | What this client can see, plus crate drag counters. |
| `brdamagelog` | Records real `weaponDamageEvent` payloads and prints every field. |
| `brdamage off` | Backs the damage takeover out live, without a redeploy. |

---

## Adding a test

New coverage goes into the **existing** suites — no new suite file, so no
`verify.sh` edit. Open a bare `do … end` block after a `describe(...)`, call
`reset()` first, and remember the load-bearing rule: revert the fix, watch it
fail, restore.
