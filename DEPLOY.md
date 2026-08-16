# Deploying FiveM Royale

Target: **Legacy FiveM** (standard FXServer Linux artifacts) on Ubuntu.

---

## 1. Server prerequisites

```bash
sudo apt update
sudo apt install -y curl xz-utils tmux mariadb-server
```

### FXServer artifacts

Download the **Linux** build from the Cfx.re artifacts page. Use the
**recommended** channel for anything you care about; `latest` is for testing.

```bash
mkdir -p ~/fxserver && cd ~/fxserver
curl -sSLo fx.tar.xz "<recommended-linux-artifact-url>"
tar xf fx.tar.xz && rm fx.tar.xz
```

> **Ubuntu 26.04 note.** Cfx.re builds against an older glibc and current guidance
> still recommends 22.04/24.04. It will most likely run fine, but if the server
> refuses to start, the cause is almost always a missing or mismatched `libssl` /
> `libicu`. Install the compat package the error names rather than assuming the
> artifact is broken. **Test this before writing any gameplay code** — it is a
> cheap check that becomes expensive to discover later.

### Running the server

**Under systemd, inside tmux, using the three units in `tools/`.** systemd owns
the lifecycle (boot, reboot, crash recovery); tmux owns the terminal, because
**this artifact does not run without one** — see the note below, which exists so
nobody relearns it.

```bash
sudo apt install -y tmux
sudo cp tools/royale.service tools/royale-watchdog.service tools/royale-watchdog.timer /etc/systemd/system/
sudo nano /etc/systemd/system/royale.service           # set User= and the paths
sudo nano /etc/systemd/system/royale-watchdog.service  # same user in runuser -u
sudo systemctl daemon-reload
sudo systemctl enable --now royale royale-watchdog.timer
```

Day to day:

```bash
systemctl status royale                          # is it up
tmux attach -t royale                            # the REAL console: brstate, brprofile, brperf all work
tail -f /opt/fivem-server-classic/console.log    # console output without attaching
sudo systemctl restart royale                    # bounce it
```

**Detach from tmux with `ctrl-b` then `d`. Never `ctrl-c`** — that is the
console, and Ctrl-C shuts the server down.

> **The crash history, with the corrected diagnosis** — three failure modes
> chased across 2026-08-09 → 08-11, misattributed twice, recorded here so
> nobody relearns any of them:
>
> 1. A plain unit hands FXServer a stdin already at EOF; it reads that as
>    Ctrl-C and quits cleanly two seconds into every boot. Real; any unit must
>    give it input that never ends (tmux does).
> 2. **SIGABRT shortly after boot** — `Assertion failed: status.ok() ...
>    DatabaseHolder` — is FXServer failing to **open its KVP store**, the `db/`
>    directory next to `server.cfg`. Root cause: `db/` had gone root-owned from
>    running the server with `sudo`, so every server running as the service
>    user aborted at its first KVP access (vMenu's ban store), while hand-run
>    root servers worked. That asymmetry masqueraded first as "clients can't
>    connect" (the server was dead for most of every ten-second restart cycle;
>    `ss` caught it mid-boot) and then as a PTY requirement. It was file
>    ownership the whole time.
>
> **The invariant that prevents the whole class:** everything under
> `/opt/fivem-server-classic` is owned by the unit's `User=`. The server is
> never run with `sudo`, and if it ever aborts at boot again, check ownership
> *first*: `ls -la /opt/fivem-server-classic/db`.
>
> tmux stays on its own merits, not because the PTY theory survived: the
> attach-able console, and `send-keys` as Slice 2's cheap command channel.
> **The costs, each paid:** systemd cannot see a crash inside the session, so
> `royale-watchdog.timer` checks every 30s — a crash costs under a minute,
> unattended. The journal gets nothing, so `pipe-pane` mirrors the console to
> `console.log` (rotation is M9 9e's job).

### Deploying

Install the deploy unit once:

```bash
sudo cp tools/royale-deploy.service /etc/systemd/system/ && sudo systemctl daemon-reload
```

Then deploying is one command, any time:

```bash
sudo systemctl start royale-deploy
```

It syncs from `origin/main` with `tools/deploy.sh` and restarts the game — and
only restarts if the sync succeeded, so a failed pull leaves the server on the
last known-good code instead of bouncing it into a broken tree. Watch it with
`journalctl -u royale-deploy -n 50`.

**Deploying stays separate from running**, deliberately. A `systemctl restart`
relaunches what is already on disk; it does not pull. `Restart=always` means a
crash respawns automatically, and if starting also pulled, a crash at 3am would
silently deploy whatever happened to be on `main` at that moment, so the server
that came back would not be the one that went down.

**Two clones live on the box, with different jobs.**
`/opt/misc/fivem-br-gamemode` is the checkout you `git pull` by hand — it is
where the deploy *script* comes from. `deploy.sh` manages a second clone under
`/opt/fivem-server-classic/.gamemode-src`, which it `reset --hard`s and
`clean -fd`s every run, because what gets served has to be a deployment
artifact rather than somebody's workspace.

---

## 2. Persistence — DynamoDB, no database to install

**There is nothing to install and nothing to run.** Match results, XP and player
identity live in DynamoDB, reached through the `br_ddb` resource, which uses the
box's EC2 instance role — no credentials, no connection string, no local
service.

This replaced MariaDB and oxmysql entirely. If you are looking at an older
checkout that mentions `mysql_connection_string`, that whole section is gone:
`br_stats` no longer has a database layer of its own, and the tables it wrote to
never contained anything (see below).

### What you need

Two tables in **us-east-2**, and the IAM policy in the Ringmaster repo's
`docs/aws-setup.md`:

| Table | Partition key | Sort key | Holds |
|---|---|---|---|
| `br-players` | `pk` (String) | `sk` (String) | `sk = profile` — matches, wins, kills, XP, level.<br>`sk = purchases` — market items, granted back on join.<br>`sk = match#<endedAt>#<matchId>` — one row per match played. |

Purchases are a separate item under the same key deliberately: they are
irreplaceable, they are read on the connect path where latency strands people on
a loading screen, and they must never share a write path with counters that
update at the end of every match.

**Match history is one item per player per match**, filed under the same
partition key as their profile so "this player's recent matches, newest first"
is a `Query` with `ScanIndexForward: false` and a `Limit` — no secondary index
and no scan. They are written in batches of 25, so a 48-player match costs two
calls. **There is no TTL**, by decision: the rows accumulate. Adding one later is
possible but only affects items written *after* it is enabled — existing rows
would need a backfill pass to be given the attribute.

The game box needs `GetItem`, `PutItem`, `UpdateItem`, `BatchWriteItem` and
`Query` on `br-*`. It keeps **read-only** access to `ringmaster-*`, which is the
console's data.

> `BatchWriteItem` is a *separate* IAM action from `PutItem` — a policy granting
> only the latter denies the batch. If match history is the one thing not
> appearing, that is the first place to look; the server log says
> `match history: 0/N rows written` with the AccessDenied message attached.

### If DynamoDB is unreachable

`br_stats` says so once per match and carries on. **A stats failure must never
stop a match** — the rule the old oxmysql layer earned with a circuit breaker,
carried over intact. Check the connection with `brddb` on the console.

### Why there was nothing to migrate

`br_stats` shipped with `applyMatch`, `beginMatch`, `endMatch` and a leaderboard,
and **not one of them was ever called**: `br_core` emitted no match-end event, so
nothing hung off them. The MariaDB schema was created and stayed empty, which is
indistinguishable from a new server — which is why it went unnoticed. The intent
was real; the wiring was never finished. Both ends exist now:
`br_core` publishes `br:match:results`, and `br_stats/server/persist.lua`
consumes it.

---

## 3. Resources

Copy `resources/[fivem-royale]/` into the server's `resources/` directory.

The NUI build output (`br_ui/ui/`) is committed, so **no build step is required
on the server**, and no Node is needed on it either.

### Why the UI project lives in `ui-src/`, outside `resources/`

FXServer automatically builds any resource containing a `package.json`, using its
own bundled yarn and **Node 16**. This toolchain needs Node 20+, so leaving the
project inside the resource made the server try to build an already-built
resource and fail on startup:

```
error tar@7.5.22: The engine "node" is incompatible with this module.
Expected version ">=18". Got "16.9.1"
Building resource br_ui failed.
```

Targeting Node 16 instead is not a real option: Vite 7 requires
`^20.19.0 || >=22.12.0`, Tailwind v4's engine needs Node 20+, and HeroUI v3
requires Tailwind v4. Building on the server would also turn a UI build failure
into a server boot failure, which is the wrong place for it.

So `ui-src/` sits outside `resources/` — the only tree FXServer scans — and
writes its output into `resources/[fivem-royale]/br_ui/ui/`.

```
ui-src/                                   # Vite project, needs Node 20+
  src/                                    # React source
resources/[fivem-royale]/br_ui/
  fxmanifest.lua                          # serves ui/ as static files
  client/nui.lua
  ui/                                     # build output, committed
```

### The CEF constraint — read before touching the UI stack

**FiveM's embedded browser reports Chrome 103** (June 2022). Measured, not
assumed: the client prints a capability probe at startup as
`[br_ui] ---- CEF environment ----`. Re-run it after any FiveM client update.

Not available: `oklch()` `oklab()` `lch()` `color-mix()` `:has()` CSS nesting.

This is why the stack is **HeroUI 2 + Tailwind 3** rather than the current
majors. Tailwind 4's default palette is authored in oklch and HeroUI 3 emits
oklch and color-mix throughout its component styles — neither is patchable from
outside, and on Chrome 103 the result is not a fallback but *no colour at all*.
A correct stylesheet renders as an apparently broken one.

`npm run build` runs `scripts/check-css.mjs`, which fails the build if an
unsupported colour function reaches the bundle. It distinguishes severity
deliberately:

- **value functions are errors** — the declaration is dropped from an otherwise
  valid rule, so the element renders invisible
- **selectors are warnings** — the whole rule is dropped, which degrades
  gracefully (a disabled button not dimming is not worth failing a build)

A dependency bump can reintroduce these with no change on our side, and nothing
in a typecheck or unit test would notice.

To change the interface (on a dev machine, not the server):

```bash
cd ui-src
npm install
npm run build      # typechecks, then writes into the resource
npm run dev        # browser dev harness at :3000, no game required
```

**Always commit the rebuilt `ui/` alongside the source change.** The pre-commit
hook enforces this — install it once with `./tools/install-hooks.sh`. Without it,
committing source without the bundle leaves the server serving the old UI, with
nothing wrong in any log.

---

## 4. Configuration

Edit `server.cfg`:

| Setting | Notes |
|---|---|
| `sv_licenseKey` | From <https://keymaster.fivem.net>. The server will not start without it. |
| `add_principal` | Uncomment and insert your own license identifier to get admin. |
| `sv_devMode` / `br_devMode` | **Set both to `false` for production.** They lower the minimum players to start and enable client dev tools. |
| `sv_maxclients` | 48 is the free OneSync ceiling — see the note in `server.cfg` before raising it. |

---

## 5. First boot checklist

Run these in order. Each one answers a question that is expensive to discover later.

1. **Server console — does the gamemode see the world correctly?**
   ```
   brstate      # match state and player counts
   brconfig     # the tunables that most often explain odd behaviour
   brdb         # database reachable, schema applied
   ```

2. **Client F8 console — do our native assumptions hold on this build?**
   ```
   brnativecheck
   ```
   This is the most important single check on this list. Every assumption the
   gamemode makes about a native is written down in
   `br_core/client/natives.lua`, and this converts them into observations.
   **Re-run it after every FiveM client update.** A failure means that file needs
   its fallback path — not that the calling code should work around it locally.

3. **Client — is the HUD where it should be?**
   ```
   brdebug          # overlay: perf / state / keys
   brperf           # per-subsystem frame cost, budget < 0.35ms for br_core
   ```

4. **The scatter test.** Put two clients ~3 km apart. Both must show the same
   alive count and see each other's join/leave. Scoping bugs work perfectly with
   players stood together and disintegrate when spread across the map — and the
   symptoms look like logic bugs, not architecture bugs. Re-run this whenever the
   roster or broadcast code changes.

---

## 6. Hardware

Currently a **t3a.large** (2 vCPU, 8 GiB).

**The burstable CPU is the real risk.** A game server holds sustained CPU, and
t3a instances earn credits for only a fraction of full utilisation. Once the
credits drain, the instance throttles hard and every player stutters mid-match —
which presents as "the server is lagging" with nothing wrong in the server logs.

Either:
- enable **T3 Unlimited** (small extra hourly cost, no throttling), or
- move to a non-burstable instance — `c6a.large` or `c7a.large` are the natural
  fits, since FXServer's main loop is single-threaded and benefits far more from
  sustained clock speed than from extra cores.

Set a CloudWatch alarm on `CPUCreditBalance` either way. 8 GiB of RAM is
comfortable for 48 slots. There is no database process on this box any more --
persistence is DynamoDB, so the RAM goes to the game.

---

## Verification during development

From the repo root:

```bash
./tools/verify.sh
```

The gates, in the order they run:

| Gate | Fails when |
|---|---|
| syntax | `luac -p` rejects any `.lua` under `resources/` |
| tests | any unit suite fails (pure logic: geometry, storm solver, seeded RNG, loop registry, scheduler, roster, XP curve) |
| scope | a scope-limited native appears in `br_core/client/` without an explicit `-- scope-ok:` marker |
| weapon table | `tools/check_weapons.lua` finds an inconsistency |
| POI siting | `tools/check_pois.lua` finds a badly-placed POI |
| forward locals | a `local function` is called above its own declaration (invisible to `luac -p`, nil at runtime) |
| manifest coverage | a `.lua` exists under a resource but is declared in no fxmanifest — so it silently never loads |
| deploy payload | `deploy.sh`'s own preflight, run against this checkout, so a deploy script that only breaks in production breaks here first |
| secrets | anything credential-shaped is about to be committed, anywhere in the repo |

Requires Lua 5.4 (`winget install --id DEVCOM.Lua -e`, or your distro's package).
The script finds `luac` on its own.
