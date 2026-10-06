# Testing

What the suites and gates do, when to run them, and the bugs they have caught.

[← Back to the main README](../README.md)

---

## The one command

```bash
bash tools/verify.sh          # skips each suite whose inputs have not changed since it passed
bash tools/verify.sh --full   # runs everything, and refreshes the pass cache
```

Runs everything below in increasing order of strictness and exits non-zero on
any failure. It is wired as a **pre-commit hook**, and CI runs it after the UI
and br_ddb package-owned checks have proved both committed bundles match source.
Pull requests and `main` are covered remotely; `dev` is guarded locally before
commit. Locally, a suite that passed and whose inputs are byte-for-byte what they
were is skipped — see [the pass cache](#the-pass-cache). CI has no cache and
always runs everything.

Lua 5.4 is required. `verify.sh` finds the ordinary `lua`/`luac` pair,
Homebrew's keg-only `lua@5.4`, and the standard Windows install path; when
absent it prints the matching Homebrew, apt, or winget command.

Python 3 runs the licensed-asset gate and its suite, and the deploy handover
suite (`python3`, or `py` on Windows, each tried before it is used so the
Microsoft Store stand-in is never taken for Python); without it all three print
`skip`, and the pass cache is off.

---

## The pass cache

Owner, 2026-10-04: *"The full check skips suites whose files didn't change."*
On the Windows PC verify.sh had grown to well over six minutes, almost all of it
a handful of suites that had nothing to do with the change being checked.

**What is skipped, and when.** A *unit* is one suite or one of the slower gates.
When it passes, the cache stores the hash of everything it read. The next run
skips it only if

- every one of those inputs hashes the same **in the working tree now** —
  uncommitted edits count, a file that was absent must still be absent, and a
  directory it listed must list the same names;
- `tools/verify.sh`, `tools/vcache.py` and both tracers are unchanged (editing
  any of them runs everything);
- the interpreter is the same binary (the Lua executable and its DLL, or the
  Python build), and for a gate with declared inputs, the same bash.

Anything that cannot be evaluated counts as changed. A skipped unit prints one
line, `skipped -- unchanged since it passed at <time> (<n> inputs)`, and the
last line says how many ran and how many were skipped: `PASS  23 ran, 61 skipped`.

**How a unit's inputs are recorded.**

| Kind | How | What counts as read |
|---|---|---|
| Lua suites and gates | `tools/vcache_trace.lua` runs the script in place of `lua script` (same `arg`, `...` and exit code) with the I/O functions wrapped | every path given to `io.open`, `io.lines`, `io.input`, `dofile`, `loadfile`; for `require`, every `package.path` candidate up to the one that loaded (so a file that would now shadow it is a change); `io.popen`'s command, exit code and output (re-run at check time); every `os.getenv` and its value. A path the run wrote first is its own output, not an input. `os.execute` or a popen for writing makes the unit uncacheable. |
| Python suites | `tools/vcache_trace.py`, the same way | `open`/`os.open`, every directory listing (`os.listdir`/`os.scandir`, so `os.walk`, `glob` and `pathlib`), `os.stat` and `os.path`'s existence and size queries, every imported module outside the standard library, the whole environment (children inherit it), and for each child process its program's binary and every argument that names a file or directory. Paths under a directory the run created are its own. `os.system`, `exec*`, `spawn*` make it uncacheable. |
| Bash gates | declared in `verify.sh`: `vc_begin NAME file:… tree:DIR[:SUFFIX] list:DIR[:SUFFIX] exe:…` | exactly what is declared, plus the whole environment and bash's own binary |

**What is cached, and what always runs.** Measured on the owner's PC before the
cache (2026-10-05, one full run, 403 s); the stages that cost are units.

| Stage | Before | Cached as |
|---|---|---|
| `test_assets.py` | 123 s | traced Python unit |
| `test_shared`, `test_roster`, `test_storm` | 83, 48, 46 s | traced Lua units |
| the other 45 Lua suites | 15 s together | one traced unit each |
| forward locals, bool natives | 16, 15 s | traced units; their file lists are now built in bash alone (they ran `dirname` once per directory level per file, about 1,500 processes, which was nearly all of their time) |
| `test_configreport.sh` | 12 s | declared: itself and `tools/dispatch.sh` (it points the dispatcher at temp boxes) |
| dev gate on console commands | 9 s | declared: `tree:resources/[fivem-royale]:.lua` |
| syntax | 7 s | **per file**: each `.lua` with `luac`'s binary, so one edited file is one `luac` |
| br_ddb bundle over the wire | 5 s | declared: `dispatch.sh`, the manifest, the bundle, `node` |
| duplicate console commands | 4 s | declared: `tree:resources/[fivem-royale]:.lua` |
| frame budget | 3 s | traced Lua unit |
| emote gate, season gates, player states, notice names, cue call sites, net events | 0.2–2.6 s | traced units; the `find` that builds their arguments is declared as `list:` |
| secrets | 3 s | **always runs**, on purpose (below) |
| console capability boundary (around `test_configreport`) | about 2.5 s | **always runs**: some forty greps over `dispatch.sh` and everything under `resources/` in six languages, some setting the result directly, with `test_configreport` — a unit — in the middle; it would have to be a unit inside a unit |
| manifest coverage, shared coverage, vendored third-party, tunable overrides, br_ddb bundle | about 1 s each | **always run**: bash over most of `resources/` (or all of `js-src/br_ddb`), so the declared input would be nearly the whole tree — re-run by almost any change anyway, and one wrong declaration from hiding one |
| the other thirty-odd gates | under 0.5 s each | **always run**: mostly one `grep` or one Lua process, where checking a cache entry costs about what the gate does |

`secrets` always runs on purpose: it asks git about the whole repository, so
its input is everything, and it is the gate a stale answer would hurt most.
The UI bundle's byte comparison is CI's (`npm run build:check`), untouched.

**When it is written.** `vcache.py check` runs once at the start and
`vcache.py commit` once at the very end, after every gate. Commit stores only
units that exited 0 — and deletes the entry of any unit that failed — so a
failure is never stored, and a run stopped part way (Ctrl-C, a closed terminal)
reaches no commit and stores nothing. It also refuses a unit whose inputs
moved while it ran: a file whose existence or size differs from what the tracer
saw, a hash that differs from the one the Python tracer took when it read, or
any input modified after the unit started, or so close before it that the
timestamp cannot tell (0.1 s on a filesystem that keeps fractions of a second,
covering a Windows clock tick; 2 s on one that keeps whole seconds). A file
saved and verified straight away is before the start, so it is stored.
Refusals print one line, `not stored: <unit> (<why>)`, and simply run next
time; if `verify.sh` or a cache file itself changed during the run, nothing is
stored.

**Where it lives.** `.verify-cache/` in the checkout (gitignored):
`entries/` holds one JSON file per unit, `runs/` the traces of a run in
progress. Deleting the directory is always safe; the next run is a full one.

**`--full`** ignores the cache, runs every unit, and rewrites the cache from
that run alone (an entry for anything that did not pass in it is dropped).
Use it after changing something the cache cannot see (below).

**CI always runs everything.** GitHub Actions checks out fresh, so there is no
`.verify-cache/`; and `verify.sh` turns the cache off outright when `CI` or
`GITHUB_ACTIONS` is set, so the suites run under the plain interpreter exactly
as before. It is also off without Python 3 or on a bash older than 5.

**What it cannot see, honestly.**

- **What a child process reads.** A Python suite's subprocess is recorded by
  its binary and the files named in its arguments, not by what it opens.
  `test_assets.py` runs `tools/deploy.sh` and `tools/assets.py` against temp
  trees it builds (both are arguments, so editing either re-runs it), git, bash
  and `cmd.exe` (binaries recorded). The bash gates' children are covered by
  what each one declares.
- **The machine outside the checkout**: git's global config, a different `grep`
  that is not Git for Windows' own. Bash's binary is recorded for every gate
  with declared inputs, which covers a Git for Windows upgrade.
- **The pre-commit hook's environment** differs from a terminal's (git sets
  `GIT_INDEX_FILE` and friends), so the Python suites and bash gates — which
  record the whole environment — run again under the hook. The Lua suites read
  only the variables they ask for and stay skipped.

When in doubt, `--full`.

`tools/test_vcache.py` (the `pass cache` gate) is the cache's own suite: a
scratch checkout with stand-in suites, driven through the real helper and commit
blocks of `verify.sh` — an edited input, a file read on only one branch, a new
file in a listed directory, an absent file appearing, an environment variable,
a `loadfile`d module, a popen's output, a Python import and a script it runs, a
declared input, an edit to `verify.sh` or any cache file, `--full`, a failing
suite or gate, an interrupted run, an input edited while its suite ran (Lua, at
the same size; and Python), the cache's own files changing mid-run, an
`os.execute`. Each asserts the suite **ran** the next time. Twenty-five
mutations of `vcache.py`, both tracers and the bash helpers — each one a
guarantee removed — all fail it.

---

## What runs, and what each part is for

| Stage | What it proves |
|---|---|
| **Syntax** | `luac -p` on every `.lua`. FiveM runs Lua 5.4 and so does this, so a pass means the resource will at least load. The floor, not the ceiling. |
| **Unit tests** | 49 suites, over 10,000 assertions, covering the pure shared modules, server model, client interaction layer, AWS-facing subsystems, and individual files where a rule lives. The run order stays explicit, but `verify.sh` compares it with every `tools/test_*.lua` file and fails if either side has an extra entry — a new suite cannot exist without running in CI. |
| **Frame budget** | br_core's native calls, draw calls and kilobytes allocated per frame, phase by phase through a simulated session from the lobby to a match and the things a player does in one, stay within `tools/perf_budget.lua`. See [the frame profiler](#the-frame-profiler-and-its-budget). |
| **Scope gate** | Bans OneSync scope-limited natives from client gameplay code. |
| **Weapon table** | Re-derives every weapon hash from its name, and requires every weapon and throwable to say explicitly whether a car seat accepts it — a missing `driveby` field reads as "no" and would silently drop a gun out of the drive-by hint. See [Vehicle data overrides](vehicle-data.md). |
| **Vehicle table** | Re-derives every refused-vehicle hash from its name, signed and unsigned. The refusal list is what keeps aircraft and weaponised vehicles out, including out of the showroom catalogue, so a hash that stopped matching its name would silently stop refusing anything. |
| **POI siting** | Spacing, water, no-loot zones, distance to roads — and since the station ambulances landed, the 23 surveyed ambulance spawns held to the same rules. |
| **Map boundary** | The surveyed ring is simple and closed, its perimeter and area still recompute to what the survey printed, and every POI, ambulance spawn and terminal site (#396's laptops) is inside it. What makes the table hard to edit by accident: the numbers are pinned to a survey rather than to whatever is in the file. |
| **HUD, squad panel and spectating** | Nine gates covering the surfaces a unit test cannot see rendered: `spectator microphone`, `spectator HUD`, `squad voice marks`, `squad levels`, `squad revive keys`, `notice names`, `key glyphs`, `vitals bars` and `death verdict`. Each pins a boundary rather than a layout — what crosses to the client and what does not. **`notice names` is the one with teeth**: a player's name is the only part of a toast a player writes, so it checks every sender for a name formatted into a sentence, which would be a formatting injection with a sign-up form in front of it. |
| **Forward locals** | Catches a `local function` called above its own declaration. |
| **Player states** | Every `PlayerState` reference across the tree names one of the nine that exist. A typo'd member is `nil`, and a comparison against `nil` is not an error — it is a branch that never runs. |
| **Bool natives** | A `BOOL` native read as a bare Lua truth value, against a recorded baseline of the known set. `0` is truthy in Lua and several natives answer `1`/`0`, so `if IsThing() then` is true forever. The gate also refuses new private `isTrue` implementations: call sites alias the tested `BR.NativeBool` or `BR.NativeTruthy` policy instead. `test_bool_natives.lua` proves the detector still detects. |
| **Config report** | The convar allowlist may not name a credential. Since `configreport` began reading `server-identity.cfg` as well as `server.cfg`, `tools/test_configreport.sh` also runs the verb over six temporary box shapes and reads the JSON back: migrated, unmigrated and half-migrated boxes all report their `sv_hostname`, and none of them reports `sv_licenseKey` or its value. The allowlist gate reads the *text* of `dispatch.sh`, so it stayed green through a reporter that answered `not set` about a hostname that was set; this one asks the verb. |
| **Voice defaults** | Voice modes are mutually exclusive, and the default agrees in Lua, in TypeScript and in the built bundle — three copies of one constant, compared as text. |
| **Tunable overrides** | Overridable keys are server-only, and every consumer loads them in order. |
| **Manifest coverage** | Every `.lua` is declared in an fxmanifest. |
| **Shared coverage** | Anything dropped into `br_lib` is actually loaded. |
| **Deploy payload** | The deploy's own payload check still works. |
| **Vendored third-party** | For every vendored resource: the license is kept, the upstream version is recorded, the patch log and the source agree **in both directions**, and `deploy.sh` still syncs it. |
| **Console capability boundary** | `dispatch.sh`'s SSH verb set, exactly — matched on the *shape* of a case arm, so a verb with a new name cannot be invisible to it. Also pins the three files allowed to call the sound natives directly, and that `/brsfx` keeps its silence probe and reads that `BOOL` through the `1`-or-`true` idiom. A set/name pair written at a call site cannot be auditioned and fails *silently* when it is wrong, which is the shape that has cost this project three rounds. |
| **Dev gate on console commands** | Every console command goes through the one wrap in `br_lib/shared/devgate.lua`, exempting only `brkick`, `brspectate`, `brring` and `bremotegrant` (whose gate is the season instead — see below). It checks the four things construction rests on — the exempt set parsed as a set, the raw-door allowlist, every command-registering resource loading `devgate.lua`, and loading it **first** — rather than a list of today's command names, which would stay green forever while the next command arrived ungated beside it. That is the same denylist-inside-the-gate failure `configreport)` not matching `config)` already cost this repo. |
| **Season gates** | Seasons (#388): one list, `br_lib/config/seasons.lua`, and one door, `BR.Season.has(id)`. `tools/check_seasons.lua` fails an id passed to `has()` with no row (it would be off in every season), a row nothing asks about, a `from` past `latest` or an `untilSeason` not after its `from`, a row with any other key, any file but `br_lib/shared/season.lua` that names `br_season`, `has()` aliased where its id cannot be seen, and any file but `br_core/server/season.lua` (the dev-mode `brseason`) that names `BR.Season.switch` (rules S1–S6, each with a `--selftest` fixture). |
| **Emote gate** | Emotes are the first Season 2 feature (#388); they were dev-mode only behind one config line until then. `tools/check_emote_gate.lua` proves every emote entry point — net handlers, the wheel key, the loops, the sweep, `bremote` and `bremotegrant`, br_ui's Market callbacks, the page's tab and slider — asks `BR.Season.has('emotes')`, that nothing asks dev mode, an accessor of its own or the season number a second way, and that no door is registered where it cannot see one (rules G1–G7, each with a `--selftest` fixture). Then every emote suite runs at the season before the row's `from` and at `from` — Season 1 (off) and Season 2 (on) — read off the row, so moving emotes moves the runs. |
| **Branch-switch invariant** | No path to a hard reset that skips the dispatch blob check. |
| **Incident surface** | Only `BR.ShotSuspicious` can reach the Ringmaster. |
| **Incident notice surface** | Exactly one sender of the "See something suspicious?" notice, one emitter of the `br:incident:filed` acknowledgement every creation path converges on, one asker of `br:ddb:putIncident`, and no acknowledgement from the corroboration handler. It pins the choke points rather than counting the creation paths, so a new detector is covered on the day it lands (#214). A second announcer would not fail a test nobody wrote — it would quietly tell the offender, which is #93; and a path writing its own row would file cases nobody is ever told about, with every other gate green. |
| **Timeline entry kinds** | Every match-timeline `kind` the Lua side writes is one `close.js` stores. The two live in different languages in different directories, and a kind added on one side alone is a timeline entry that silently never arrives. |
| **Secrets** | The only gate that scans the whole repo rather than `resources/`. |
| **Asset files** | No bought game asset in the repo (#391). `tools/check_asset_files.sh` asks git for every tracked file and every untracked one a `git add -A` would sweep up, and fails on a GTA/FiveM asset type (`.ytd`, `.ydr`, `.yft`, `.ymap`, `.ytyp`, `.ybn`, `.ycd`, `.awc`, `.rpf`, `.fxap` and the rest), the data files a pack ships beside them (`.meta`, `.dat`, `.dat54`), a pack archive (`.zip`, `.rar`, `.7z`, `.tar`, `.gz`, `.xz`, `.bz2`, `.zst`, `.lz4` and their combinations), or a copy of any of them (`legion.ytd.bak`, `x.ydr~`), outside an exact allowlist of our own: br_audio's Cargobob bank and the vendored ScaleformUI movies. A stale allowlist row fails too. The same gate, with `check_secrets.sh`, is the **pre-push hook** (`tools/pre-push`), which runs the copies `install-hooks.sh` put beside it in `<hooks>/pre-push-gates/`, never the pushing worktree's `tools/`, so every worktree sharing the hooks gets the same gates. It reads only git objects: every commit the push sends that the remote pushed to does not have, as `git ls-remote` reports it (not this clone's tracking refs, which can be stale or another remote's), so a pack or a key added and removed again inside one push is still refused. It fails closed: a missing gate, a gate that exits 2, or a grep that cannot run refuses the push. `resources/[licensed]/` and `.assets-cache/` are gitignored, so a checkout with pulled packs passes. |
| **Licensed assets** | `tools/assets.py check` on `assets.lock` — the schema, sha256 format, season ranges, no resource twice, and nothing but names, checksums, sizes, file lists and season pins — without touching the bucket; then `tools/test_assets.py`. |
| **Deploy handover** | `tools/test_deploy.py`: the ops clone's `deploy.sh` hands the deploy to the deployed commit's own when they differ, once, pinned to the commit it checked. |
| **br_ddb bundle** | Locally, the committed bundle is pinned to the current `js-src/br_ddb` source fingerprint so the gate runs without npm. In CI, Node 22 installs the locked dependencies and `npm run check` rebuilds in memory for an exact byte comparison; the fingerprint can no longer bless a stale or unrelated bundle by itself. The ban-rule cases run on both paths when Node is present. |
| **br_ddb bundle over the wire** | The same question asked of a **box**: `status` reports the bundle actually deployed there, and every absence as `null` rather than as a blank that reads like an answer. The gate above compares two things in this repository; this one compares this repository against what is running. |
| **Duplicate console commands** | One name, one registration — three collided at once in #137. |
| **American spelling** | `tools/check_spelling.sh` (#399's review): the lines a branch adds since it left `origin/dev` — committed, staged, unstaged and untracked, outside vendored code — hold no British form (`colour`, `licence`, `tyre`, `metres`, `-ise`, a doubled `-ll-`). Names the code must keep are not words to it: a `.field`, a native, a one-word string, a `key =`, anything in backticks. A name the line declares (`local`, `const`, `let`, `var`, `function`) is ours and is read, a lower-case one split at its capitals (`fullArmor`), and so are the branch's commit messages (#396 wave A's review: `local armour` and three commit messages had slipped past). The older lines already in the tree are not read. A line that has to keep a British form carries `spelling-ok`. With no `origin/dev` it says so and passes. `--self-test` runs first: a scratch repo with a bad commit whose exact finds (two declared names, a bare `function`, a message line) must come back beside every shape that must pass (a field, a key, a native kept as a local, backticks, a quoted word, `spelling-ok`), and an American commit that must pass. |
| **Pass cache** | `tools/test_vcache.py`: skipping an unchanged suite never hides a change. See [the pass cache](#the-pass-cache). |

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
| `test_shared.lua` | 2,891 | The pure modules: RNG determinism, geometry, storm solving, loot generation, combat validation, descent classification, bus doors, the DBNO rig, and the dev gate's own wrap. And #399's sky and timecycle: the storm grade in the shared timecycle slot (a dev's modifier saved, the red, the modifier put back; one set or cleared while the red is up; teardown and a freeze; nothing at all at rest), the slot's writers held to `brtc` and the brnativecheck probe (which puts the slot back and proves -1 after a clear), the drying snap's rain under a console sky, the festive sky as one fact in the world payload from the real `server/world.lua`, and a whole session walked through the real `world.lua`, `storm.lua` and `ipl.lua` -- not festive, write for write what origin/dev wrote before #399; festive, XMAS everywhere with the bus's overcast cover, THUNDER in the storm and XMAS after it, `brfestive` as a blend, flipped at every step -- with the ground snow pass on a resolved snow sky only and on change only: never under the bus's cover or the storm's thunder, and two thousand random claims and festive flips over every weather and role, where the ground is white exactly when the resolved sky is a snow weather. |
| `test_loop.lua` | 97 | The client loop registry: bands, suspension after repeated errors, enable/disable, and opt-in stall attribution without normal-path timer bracketing. |
| `test_sched.lua` | 41 | The server scheduler: intervals, duplicate-name refusal, stepping. |
| `test_roster.lua` | 3,041 | The server model end to end — roster, parties, squads, match state machine, bus, storm, loot streaming, inventory. The big one, and the only one that can reach an admin console command: its `RegisterCommand` shim was `function() end`, so every one of them loaded into nothing and could never be run. It is also where the revive key's central rule lives, against the real `eliminate()`. #396 wave A: `BR.Inv.grantEffect` through the real sampler (the ledger follows a granted climb to full and keeps it; an ungranted one is refused; a running channel ends, its item unspent); `BR.Inv.revoke` and its excuse through the real damage handler (that weapon, that player, the grace only; a pistol's NOT_HELD, each launcher's NOT_THROWN -- the RPG, the grenade launcher and the railgun, half a second after Disarm and 6.5 s after, still in the air -- and a NO_AMMO nobody listed, each with its control past the grace; the shipped grace pinned above the longest flight in the arsenal plus a round trip); `killsAt` stamped with a credited kill and cleared with it. |
| `test_stats.lua` | 186 | XP and placement arithmetic. It compares payout terms **against each other** and pins none of them, which is what let the 50% Volts cut land green while a *partial* rescale — the plausible mistake — would have failed. |
| `test_ringmaster.lua` | 705 | The Ringmaster surface: the incident envelope, the gate, kick and maintenance. #396 wave A: a strip of the gun Disarm just took opens nothing, during the grace and for that weapon only. |
| `test_artifacts.lua` | 119 | Incident screenshots: three timed frames, the ten-second rule on corroborations, the cap of nine and the clean no-op past it, a subject who disconnects mid-schedule, `screenshot-basic` absent, a failed upload, and a client that never answers. Loads `br_core/server/artifacts.lua` itself. |
| `test_airdrop.lua` | 823 | Aerial supply drops (#88), in two halves that both load the real files: the pure solver, plus `server/airdrop.lua` itself for the schedule, the siting decision, the phase cap and the auto-open. Its best assertion is the invisible one — that an airdrop-only item appears in no world roll, proved by generating a whole layout and looking. |
| `test_audio.lua` | 200 | The airdrop Cargobob's native audio bank (#382), read back from the **committed** binaries by a reader written here and not shared with `tools/build_audio.mjs`: one mono stream looping from sample 0 at 32 kHz in whole ADPCM blocks, peak data that matches the decoded audio, a loop with no seam, every variant's distance and loudness, and the one name that has to agree across both files — the stream id against every SimpleSound's FileName — because a mismatch there plays silence with no error anywhere. |
| `test_client.lua` | 2,024 | The client interaction layer — keybinds, holds, prompts, loot pickup and same-frame target/ray behavior — with the FiveM natives stubbed and the frame band stepped by hand, the same shape `test_roster.lua` uses for the server. It also carries the engine friendly-fire rule (#115), written out once from the external record so that a fix which merely agrees with itself still has to agree with that. And `brtc` bare (#399): both timecycle slots and whether the storm's grade owns the primary one, with no write. |
| `test_spectate.lua` | 71 | `client/spectate.lua`, which no other suite loads. The property is not which controls are in the list — a text gate could do that — but that the list is **let go on every path out of a session**, which is a step of the loop rather than a string in a file. A spectator who cannot move after a match is worse than the accidental gunshot that prompted the work. |
| `test_matchexit.lua` | 95 | That every way out of a match takes the match's surfaces with it (#204), plus exact relationship-cache invalidation from roster snapshots and deltas. It loads the whole mirror, `client/state.lua`, because both properties are event sequences invisible to a static check. |
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
| `test_emotes.lua` | 232 | The emote system's server half (#215): the catalogue rows and `rowProblem`, the season gate (and that dev mode is not one), the wheel's eight slots through load, equip, unequip and buy — including both duplicate-safe rollbacks, the per-slot busy guard and the slot-write cap — the play record's audience (same bucket and within range, spectators of a dancer in range, never a teammate 500 m away or a lobby-bucket player), the early stop to everybody the start reached, the sweep's late deliveries, `bremotegrant` called as its **raw** handler, and a `brseason` switch that every one of those doors answers at once — or, with a match running, only at its teardown. |
| `test_emotes_client.lua` | — | The dancer's client: when the wheel opens and what it dismisses, the release that picks, playback and every cancel (and that damage and ragdoll are not cancels), the distance-faded music list, and the client gate watcher — every door shut before the season arrives, and br_ui told to re-send on br_core's first pass and on every flip — and a `brseason` switch mid-session, with the message and the replicated value landing in either order. |
| `test_emotes_ui.lua` | — | br_ui's Market glue for emotes: the catalogue rows and wheel slots only behind the gate, the `EMOTES` flag (off until the season arrives, and re-sent when br_core's gate pass says so — which is what closes the tab after `restart br_core` onto an earlier season), and the three Market callbacks forwarding nothing for an emote while it is closed. A `brseason` switch re-sends both on `br:season:changed`, even when the server's push landed first. |
| `test_season.lua` | 484 | Seasons (#388): `br_season`'s parse and its fallback to the latest season with a boxed warning, `has()` at every edge including a feature a season takes away, the unknown id (off and said once in game, raised in a suite), `pick()`, the change after boot that is seen and ignored, and the season crossing from a server Lua state to a client one — including that an operator's replicated `br_season` moves no client, and that a client the season has not reached yet knows none and shuts every gate. It also pins the wiring: who boots, which manifests load it, and the dev-mode lobby label `S2 · 1a2b3c4`. And the dev-mode `brseason`: `BR.Season.switch` and its bounds, the command over `devgate.lua`'s **real** wrap (refused with dev mode off), a switch at once with no match, one staged in every match state and applied only at the teardown, a second replacing a staged one, `reset`, and the client that re-reads the replicated value whichever of it and the message lands first. The client's copy of the season: read once as the module loads and again only when the runtime's convar listener (or `br:season:changed`, or a SEASON_SWITCHED) says it moved -- three thousand questions after load read the convar no more -- `onChange` hearing every move including the first arrival, and a runtime without the listener re-reading on a bounded thread. `test_roster.lua`'s `season.brseason` stages one in a real match and watches it land at the real teardown, with the lobby label following. Since #391 it also holds `brseason`'s licensed-asset warning: silent with no install record or when the sets agree, naming every pack that differs (and how) on a switch, staged or not, and on a bare `brseason`, a resource the record calls `unknown` (after a swap whose undo failed) said in words rather than printed as a version, and the record's names and line shapes pinned against `tools/assets.py`. |
| `test_props.lua` | 744 | `/brprop`'s dev props (#384), in four parts that all load the real files: the pure rules and edit arithmetic (every axis at both step sizes from several camera angles, and the pickup look proved to read each of the loot's own hover numbers); `server/props.lua`'s `brpropsv` command registered through the **real** `devgate.lua` — refused with dev mode off, run with it on for a player holding no grant — with its refusals, ids, rate limit, late-join list, a save → restart → load round trip through a real JSON string, and the edit session that is the edit stream's only door, closed on every way out; `client/props.lua` over the **real** `client/keybinds.lua`, so every edit key is pressed through the raw layer in the 1/0 shape; and the exact lines the client ran, typed into the server. |
| `test_stamina.lua` | 20 | Unlimited sprint (#389). `client/stamina.lua` is one call now — GTA's own stamina refilled every tick, because running it dry drains **health** and no meter of ours ends a sprint any more. The suite steps every player state, a state that does not exist yet, a client that does not know who it is, and a full minute of held sprint in a match and in warmup, with all three loop bands at their real rates: every tick must end with the engine's meter full and sprint never disabled. |
| `test_rarity.lua` | 57 | One rarity palette (#392). The page used to show two: the bag and the world painted `BR.RarityInfo`'s set while `index.css` held Tailwind's defaults, and the colorblind modes reached only the latter. It pins the owner's five against `BR.RarityInfo` (hex, rgb, key, label), `index.css`'s base `:root` block, `types.ts` RARITY (which must hold **no** color) and `tailwind.config.ts`; refuses rarity declarations under any selector but a colorblind mode; and compares the **built** stylesheet with the source rule for rule, so a source edit that was never rebuilt fails here. Its CSS reader is fed broken fixtures too, because a parser that finds nothing passes everything. |
| `test_crates.lua` | 391 | Season 2 crates (#395), the config and the server, on the real files. The look module: every tier, festive or plain, sealed and open, and the four gift boxes; that the shipped placeholder block is inert (no model, no timed open); that a clip is timed only when the whole row is real **and** the props' resource runs on the box; the festive window at November 30, December 1, January 31 and February 1, and `brfestive` -- the festive calendar (`BR.Festive`, #399) the crates now ask rather than own, and `brfestive` sending the festive sky to every client once per change through the real `server/world.lua`, never on Season 1. Then `server/loot.lua` and `server/warmupcrates.lua`: Season 1 byte-for-byte unchanged on the wire and opened on the spot; every crate stamped once with its tier and its match's festive answer (decided once, at layout); the open -- OPENING, LOOT_OPENING to the cell with `mine` on the opener's copy only, a second hold answered like a husk, the burst at exactly `clipMs` with today's contents-then-husk order; a client streaming the crate in during the clip (`op`) and after it; the opener going down, out or disconnecting mid-clip; the match ending or the entry leaving mid-clip; the airdrop's blip starting at the burst; the warmup pad's respawn at the burst and the four crates' cycle twice; `brbox` and its refusals. And the real `brseason` (`server/season.lua`) under crates already standing: 2 to 1 with the pad stocked leaves no `bt`/`bf`/`bg`/`op` on any crate or husk, in the registry, on the wire or in a fresh stream-in, tells each player looking once in one message, bursts a crate caught mid-clip at once (its stale timer bursting nothing), opens every crate on the spot and reseals the four as wood; 1 to 2 gives every crate its tier, every husk the tier it was sealed at and a `brbox` gift its color back; a staged switch restyles only at the teardown; the next match's layout follows; a switch between two seasons that both have crates moves nothing. |
| `test_crates_client.lua` | 182 | Season 2 crates on screen (#395): `client/loot.lua`, `dui.lua` and `warmupcrates.lua` over a modeled engine -- entities with model, pose, freeze, collision and animation; models present or absent, streaming or never; clipsets on time, late or never; threads on a frame clock. The box per tier, festive and gift, and the wooden crate for a missing model, a placeholder row, a model that never streams and one the engine refuses; the clip (once, held, frozen, part-way when late, not at all past its end, after a late clipset); the open prop built at the sealed box's pose **before** the sealed one is deleted; a crate streamed in mid-clip drawn open and kept at the burst; the reveal only for the opener; a lingering box swept; the prompt at the config row's offset and rotation, moved live by `brboxprompt`; natives per frame for a box no more than for the wooden crate; the pad's markers on boxes; `brbox` and `brboxcheck`. And a season switch: a stamped crate on a Season 1 client is wood (no clip, no box streamed); 2 to 1 rebuilds every box as today's wooden crate, placed from its entry rather than at the box's pose (even where the box went through the map), wood built before the box goes, no box body left and every box model handed back; 1 to 2 the reverse; the server's restyle and the client's season landing in any of the four orders, one body built; a switch while a box is still streaming in never adopts it; a switch mid-clip; the pad's markers following; and the gate asked once per switch, never per frame. |
| `test_terminal.lua` | 3,375 | The Season 2 terminals' contract (#396, [docs/terminals.md](terminals.md)), in all three of its Lua files. The registry and the copy agree row by row (every function's card and page lines, every option's label and choices, a default among its choices, the owner's verbatim lines, and a word check that no function line says it helps); every row is listed and an unbuilt one is `fn_offline` and spends nothing; options are taken only as the registry allows (anything else `bad_option`, nothing spent); TERMINAL_INFO reaches each open computer's player alone, and nobody off Season 2. `server/terminal.lua`'s `brterminalsv` over the **real** `devgate.lua` and season module (refused with dev mode off and at Season 1), the payload and every refusal in order, a run taken only inside the session the server opened (no session, another terminal, another player, a malformed id, too soon: no answer), the key and the squad's use spent once, a season switched under an open session closing it, and the registry agreeing with the copy block; `client/terminal.lua` over a modeled computer (what it opens with, every relay, the key layer told, a computer that cannot open handing the session back); `cuchi_computer/client/shell.lua`'s NUI focus vote taken and given back on every way in and out, nothing opened before its page is ready, and the page's run sent on with the terminal br_core opened, never the page's; and one round trip through all three. Round 2 (2026-10-05): the owner's verbatim words and no thunderstorm (refused `bad_option`); the boot's and the run's ranges, and a fresh run length every run; every cost 0..200 and the four priced rows; a dev session's typed Volts refused short with nothing spent, spent exactly as it is accepted, the new balance said, every other reason first; an effect that cannot happen giving back the Volts, the key and the use; a computer closed mid-load answered by a toast; every copy line that says squad with a squad-free `_solo` sibling (or squad-only), the one Lua picker, and every Lua reader of the copy through it; squad-only functions hidden and refused; the shell's boot range, game time and `Clock`; br_core's client sending the game clock only while open and only on a new minute. Mutation-checked (round 2's report). The review of round 2: every last word the server sends carries `toast`, its own toast line for it through the picker (each refusal, `no_volts` with the figures written in, a paid done with the new balance; none on `running`); br_core's client toasts it when the computer has closed but the server has not heard, when another terminal is up, with no computer, or when the shell says nothing is up; the shell answers whether it showed a result and passes on a `missed` toast only if it relayed that text, once; and end to end, a close still on its way up toasts the answer once on the client, the other order once from the server, and an answer the page held is toasted once as it closes. Mutation-checked. Round 3 (2026-10-06): the plate's two lines are the owner's verbatim, with no solo twins; no `holdMs`, and no copy line says "hold interact"; the no-key, squad-used and offline plates keep their lines; the client's press asks the server, which keeps its interval; the page-load range, 1-3 s, handed to the app in the catalog. Mutation-checked. (The desktop's own half, `br.js`, is `ui-src/scripts/test-terminal-desktop.mjs`, and the app's page loads `ui-src/scripts/test-terminal-model.mjs`, both run by `npm run build:terminal`.) `test_client.lua`'s focus gate holds the key layer's half: nothing fires under the computer, and the Escape that closes it does not open the pause menu. |
| `test_yubikey.lua` | 344 | The Gameplay half of #396 ([docs/terminals.md](terminals.md)) on the real files. Server: `server/yubikey.lua`, `server/terminal.lua` and the **real** `server/loot.lua` claim and open over a stubbed roster and br_ddb -- the key read from the profile and carried into the next match, the cap of one (a holder's claim leaves the key on the ground), first_pickup once ever, the death drop at the holder's feet, the leave drop (walking out and a disconnect) and its `leaveDrops` switch, every profile write and a failed one said aloud; the sources at their odds over 4,000 containers (airdrop about 0.5, legendary crate about `legendaryCrateChance`, nothing else, never the warmup pad) and as an EXTRA item (the same crate spills the same items in the same order plus the key); a terminal online only inside the storm's current zone; a use only from a living player in reach at a live terminal in a PLAYING match; access and the run telling the lobby twice (another match hears nothing), the key and the squad's ONE use spent, the squad's other holders refused `squad_used` and keeping their keys, a solo player a squad of one, a new match a new use; Storm reveal to the squad (the dead mate included) and nobody else, again on `br:ready`; the session closed on going down, walking off and the storm; every dev verb. Client: `client/yubikey.lua` over modeled natives -- blips only with a key, only inside the storm, only from the bus on; the plate's four readings and the press; the reveal until the lobby; no native on a frame without a plate. Season 1: none of it, server or client. And the hooks in `market.lua`, `combat.lua`, `roster.lua`, `loot.lua`, `party.lua`, `state.lua` and `dbno.lua`, pinned by text. Round 2: a run's loading before the lobby is told; a key given back by the account (a gone player included, the cap of one kept); the push's `squadMatch` and the plate's solo line. Round 3 (2026-10-06): the owner's fifteen sites, his order and numbers, every one a terminal, inside the surveyed boundary and out of the water; no script makes a laptop (no object near a player, no terminal file making one or naming its model); Season 1 hiding the laptop at every row -- the map-objects-only hide, its model, radius and survive-reload flag, nothing per pass, a live switch both ways and an unannounced one, the dev tool's changes and the resource stop, the radius reaching his ymap's two offset laptops; the plate's "Computer system" / "press to open" with the key cap; a press asking at once and once (not inside the interval, not under a screen, not as the computer comes up, not on a held key); and a press carried to the real server door, which opens, drops a repeat, and refuses out of reach, downed and at Season 1. Mutation-checked (37 mutations with the app's and the desktop's). The storm's own half -- `BR.Storm.finalCentre` exact at every phase and never moving the stream -- is `test_storm.lua`'s `server.final`. Wave A: a Lockdown leaves only the terminal it kept on a holder's map and turns the others' plates to `locked` with nothing to press, forcing included. |
| `test_terminalfx.lua` | 568 | What the BUILT terminal functions do once #396's door says yes ([docs/terminals.md](terminals.md)), on the real `server/terminal.lua`, `server/terminalfx.lua` and `client/terminalfx.lua`. Scan: the whole squad (a dead member included) is sent every opponent, alive, downed or in the air, every 2 s for the rest of the match, and nobody else is. The bounty to the owner's spec: "has redeemed" before "A new bounty is among us", the protect toast to the squad but not the bounty, ten minutes, everyone outside the squad sent where it is every second (the squad reads the beacon), one empty push to clear, ended by elimination and by the match ending, a solo player a squad of one. The match panel's fields. Supply drop: the terminal's or the next circle's point handed to `BR.Airdrop.call`, and `bad_option`, `no_site`, `no_storm`, `drop_busy` each spending nothing. Max ammo: every squadmate still in the fight filled, `ammo_full` listed and refused. The client: two blips per mark, moved not rebuilt, dropped, cleared in the lobby and when pushes stop, nothing at Season 1. And the beacon bit, the panel glyph and the teammates' blip 58 color 69, pinned by text. Round 2, at a real terminal over a modeled market: a run the balance cannot cover refused with nothing spent and the market never asked; spent exactly as it is accepted, the effect and the lobby only when the load is over, the new balance said; the match ending mid-load refunding the Volts, the key and the use; a free run's refusal at the end; two presses and two squadmates never spending twice; a write that fails, a row that refuses and no market, each spending nothing; the door asked again after the round trip; closing, going down or dying mid-load (the run completes, a toast says it, no bounty for a runner who is out); leaving the server (everything back); the squad and solo notices and toasts; bounty_protect never to a player with no squadmates. Mutation-checked (#396's app report and round 2's). Wave A (2026-10-06), on the function files the manifest lists (`server/terminalfx/<id>.lua`, `client/terminalfx/<id>.lua`): Field medic (the standing only, to full, `health_full`); Disarm (the one ranking -- rarity, damage, slot; a launcher taken first; throwables never; everyone in the fight; `no_weapons`, the Volts given back at the end); Key finder (both targets, static marks for 2 minutes ended by the server, the holders warned, `no_keys*`); Pulse (found once inside the radius, followed 30 s, told, never refused for finding nobody); Ghost (the one predicate, asked by Scan, the bounty and Pulse; its clock, the match's end, Season 1); Contract (the tie rule, its own five minutes and words -- never the owner's ten-minute line -- a longer bounty kept, `no_target`); Lockdown (the one online rule both ways, open computers closed, the press and the list say locked, the storm still takes the kept terminal, `lockdown_none`); each one's refusal spending nothing, its end-of-load refund, its dev command, its solo lines; and the client marks of Key finder and Pulse and Lockdown's fact. Mutation-checked: 45 mutants over the predicates, all killed (wave A's report). The wave A review: a launcher outranks a legendary rifle; two Lockdowns loading at once, in either order (the second to land refused `locked`, everything given back, the first holding, the lobby told once); the dev command's own `locked` and `lockdown_none`; `T.facts` at a locked terminal; Key finder on the ground warning no holder. Seven more mutants, all killed. |
| `test_assets.py` | 125 tests | The licensed-asset tool (#391), in Python because the tool is, against a fake `aws` first on PATH that serves a temp dir as the bucket, under paths with spaces and brackets. Packing the same folder twice gives the same sha256; push (of one folder, several, or a `[category]`) uploads once, never overwrites, and checks the lock before uploading; `retire` writes a null pin. The lock: its validation, its one written form, and its one form of pins (no null that removes nothing, no pin repeating the one in force). Season selection, null pins included, and `br_season` as br_core sees it: FXServer's early exec carrying a value past `ensure br_core`, `sets` stopping that, a bare `br_season N` once the convar exists, exec order, `;`, a comment that ends its command and not the line, `ensure` of a `[category]` br_core sits in, one argument or nothing runs, a BOM. Pull: downloads only what the cache lacks, a sha256 mismatch refuses before any archive is opened, one bad pack installs none, removal confined to `resources/[licensed]/`; `--stage` changes nothing installed, `--swap` refuses a missing or stale stage, a failure at every rename restores the old set exactly, a failed undo deletes nothing and leaves a truthful record, a kill at every point is undone by the next pull, everything staged is fsynced first, the cache prune. `publish` from its own clone of a bare remote, beside a shared checkout it must never touch: add, change, retire and re-add through the y/N gate (n leaves no ref, object or lock anywhere); the empty-folder rule (removed from a season on, nothing to remove); a half-copied or unreadable folder, at any depth, refusing before any upload or prompt, and on a retry too; a pack still landing with its `fxmanifest.lua` in, a copy's new creation time under an old mtime, and a Season folder written to lately, each refused until a minute has passed; the folders read again after the `y`, refusing a copy that finished, started or was deleted during the prompt or before a retry; a link, or an entry that cannot be stat'ed, refusing rather than skipped; a same-size, same-mtime edit of an already-published pack; the index sparing packing but never reading; a branch switched mid-prompt; dev moving mid-prompt with the same plan (pushed without asking) and another (asked again); dev rewound mid-prompt staying rewound (the lease); only a fast-forward of the planned dev ever pushed; success read back from the remote; the last check before the push; every refusal; and the real `Publish.cmd` through `cmd.exe` on Windows, bootstrapping its clone. It also runs the real `deploy.sh` with the pull stubbed (stage before the syncs, swap after them and before the stamp, a failed swap, a pre-#391 ref), the real `check_asset_files.sh` in a scratch repo, and the real `pre-push` hook pushing to bare remotes, from an old-base worktree too, with text `.gitattributes` marks binary or gives a textconv scanned as committed. |
| `test_deploy.py` | 9 tests | `deploy.sh` handing the deploy to the deployed commit's own `deploy.sh`, with the **real** script in both roles: this checkout's runs, and the newer version it fetches is the same file plus a vendored resource and a few lines recording who ran with what. A newer version takes over once and its list is synced; the same version runs alone; the handed-over run keeps the branch and the sha the first run checked while the branch moves, another fetch lands in the served clone and the pin names another branch, and gets the arguments and the `BR_*` environment unchanged; `--dry-run` hands over and stays dry; `--status` only says it would; no `deploy.sh` in the tree, a copy that cannot be made or would sit inside the served clone, and a version that does not take the handover all leave this one deploying (with the red box when it is the older one); a version that never agrees with itself is handed to once, not forever. The private copy is outside the served clone and gone afterwards. |
| `test_vcache.py` | 32 tests | The pass cache ([above](#the-pass-cache)), through the real helper and commit blocks of `verify.sh` in a scratch checkout: every way an input can change re-runs its suite, and a failure, an interrupted run, an input edited mid-run (Lua or Python), the cache's own files changing mid-run and an `os.execute` are never stored; a declared `list:` is names only and a `tree:` its listings and matching contents. Also the tracers themselves: the script's own `arg`, `...` and exit code, every read path, `require`'s candidates, and the Lua binary's DLL as part of its identity. |

**The three emote suites run three times.** Once as a box with no `br_season`
(the latest season), and twice from the emote gate section with `BR_SEASON` set
to the season before the emotes row's `from` and to `from` — Season 1 and
Season 2. So no assertion may depend on the run: a closed-gate case boots (or,
on a client, replicates) the season before `from`, an open one `from`, and
group 0 asserts whatever the run's own season means, with dev mode **off**
throughout.

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

## The frame profiler and its budget

`tools/perf_client.lua` measures what br_core costs per frame without starting
the game (#393). It loads every br_core client file in fxmanifest order, plus
the vendored ScaleformUI that runs inside br_core, against a modelled engine: a
60 fps clock, threads as coroutines, the three `BR.Loop` bands on their real
threads, events, entities, blips, keys, aiming, cars and a camera. A stub server
answers what the client asks for — loot cells, from `BR.BuildLootLayout` and
`BR.BuildWarmupLayout`, the way `server/loot.lua` does — one frame later, and
br_environment answers the island release. One squad player is walked through
nineteen phases, with payloads built by the server's own shared builders:

| phase | what it is |
|---|---|
| lobby, warmup | the lobby; the warmup pad with its loot and eight players |
| plane boarding | parked and rolling, all 24 players aboard |
| plane cruise | three seconds past the coast where the doors open: 500 m up, 185 m/s over the city, the island released, every rider aboard, the loot below asked for |
| freefall, chute | the jump and the glide, the other 23 spread around in the air |
| match | a phase-1 hold at the densest loot spot, a carbine in hand, a squadmate down nearby |
| match aim, pings, drive, revive, ptt, loot | the same, with one thing done: a sniper scope at FOV 8, all four markers down, driving with boost held, interact held at the downed squadmate, push-to-talk held, a chest held open |
| match sweep | phase 1's sweep, the wall moving |
| match late, outside, emote, downed, spectate | a phase-3 hold; then 250 m outside the zone, Season 2's emote wheel open, knocked, and spectating a squadmate |

```bash
lua tools/perf_client.lua                  # the table, every phase
lua tools/perf_client.lua --top 15 --by 8  # more rows, more natives named per row
lua tools/perf_client.lua --phase match    # stop after one phase
lua tools/perf_client.lua --digest --root <other checkout>/  # same draws as another tree?
lua tools/perf_client.lua --check          # the verify.sh gate
lua tools/perf_client.lua --rebaseline     # rewrite tools/perf_budget.lua
```

Each row is one loop callback (`frame storm.wall`), raw thread
(`thread ScaleformUI.lua:18774`) or event handler (`net br:squad:pos`), with
three counts per frame and the natives it called most:

- **natives** — every native call.
- **draws** — the natives named `Draw*` (`DrawSpritePoly`, `DrawPoly`,
  `DrawMarker`, `DrawSprite`, `DrawRect`...), counted again on their own: in the
  game each is render-thread work as well as a call.
- **KB** — kilobytes allocated, with the collector stopped. Only the code's
  own: the harness's bookkeeping and the vector3 tables the native stubs hand
  back (values in CfxLua, not allocations) are left out.

**All three are exact.** The clock is the model's, `math.random` is seeded and
the stub server answers in a fixed order, so a run gives the same numbers as the
last. The one wobble is up to 0.1 natives a frame in the plane phases:
`client/main.lua` starts its band threads in `pairs()` order, which Lua seeds
afresh every run, so a SLOW pass and the loot prop thread can swap places within
a frame. Lua time is printed per phase only, over the whole window, beside the
tick of the clock it was read from (`os.clock` ticks a whole millisecond here);
it is this machine's PUC Lua with the stubs, for a before/after on one box and
nothing more. **What it cannot see** is the engine's side of a call: a
`DrawSpritePoly` counts one here and is a textured triangle on the render thread
in the game, and real native costs differ by orders of magnitude. resmon,
`brbench <name>` and `brab <name>` are the in-game measure.

**The gate.** `verify.sh`'s `frame budget` stage runs `--check`. It fails a
phase that goes over what `tools/perf_budget.lua` recorded for it by more than
**2.5 natives, 0.9 draws or 0.9 KB a frame** — so one more 3-call loop, one
more draw every frame or one more kilobyte a frame fails, in any phase — and it
fails if any callback errored under the model (a callback that throws stops
being counted). The slack is a constant in `tools/perf_client.lua`; the budget
file holds only measurements, so rebaselining cannot loosen it. A failure names
the count that went over and its five biggest contributors.

**When it fails**, run the table for that phase and find the new row. If the
cost is a mistake — a per-frame loop with no gate, a native read per frame
whose answer cannot change, a draw that came back, a table built every frame —
fix it. If it is a feature that is *meant* to cost more, run `--rebaseline`,
commit `tools/perf_budget.lua` with the change, and say why in the commit
message. Rebaseline after a change that costs *less*, too, or the room it made
stays open. Never edit the budget by hand.

**When the model is wrong** — a new client file that errors on load, a native
whose stubbed answer sends the code down a path the game never takes, a scene
that no longer reaches the callback it is for — extend `IMPL`, the stub server
or the scene in `tools/perf_client.lua`, then rebaseline in its own commit so
the number that moved is the model's and not a feature's.

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
| `brperf reset` / `brperf` / `brperf stop` / `brloop` | Clear and arm per-callback stall attribution, read the window, then return to the timer-free normal path; `brloop` disables one callback for a bisect. Calls, errors, suspension and the frame histogram remain always-on. |
| `brstormhitch` / `brstormbisect` | Correlate #350's long frames with storm/network/map markers (`storm.map.alpha`, `storm.map.rebuild`, `storm.map.fallback`, `storm.unit.build`), then run clean local-render A/B windows: map fill absent, resident-but-frozen, shaped wall absent, and normal restoration. |
| `brdriveby [s]` | Why a passenger cannot fire (#197). Samples across frames — a disabled control lasts one, and a stow is indistinguishable from the climb-in animation until you count them — then names the cause: our own panel, a control something holds down, a permission never asserted, or the seat's own weapon rule. Also the only check there is on the `driveby` field: it prints our claim next to what the engine did, and says `stowed-unexpected` when they disagree. |
| `brboostwhy [s]` | Why the boost does nothing (#203). A full meter is the symptom of every cause at once — the meter only falls on a frame the loop decides to spend — so the chain is counted instead, rung by rung, and the rung that fails is named: the three virtual-key codes shift can arrive as against the one the binding watches, GTA's own controls on the same key, the seat and class gates, the tank and the ignition, the meter, and whether `APPLY_FORCE_TO_ENTITY` was accepted and the car actually gained the +30 mph. `[key-engine-only]` means the reader is wrong; `[force-inert]` means the physics is; `[key-wrong-code]` names one table entry in `keybinds.lua`. `[fuel-low]` and `[engine-off]` are the two gates the owner added on 2026-09-21 — boost only works with the engine running and the tank at or above `BR.Config.Boost.minFuelPct` — and the tank is asked first because a dry tank stalls the car, so an empty one would otherwise report itself as the stall. Two rows answer "what ELSE does this key do": a sweep of all 360 control ids on the frames the key is held (the four named rows are a hardcoded list from a table last updated in 2020), and the car's peak lateral speed while boosting. Note that a control row reading `PRESSED` says the key is down and nothing more — no native reports what the engine did with a control. |
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
