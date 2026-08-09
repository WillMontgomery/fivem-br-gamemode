# Deploying FiveM Royale

Target: **Legacy FiveM** (standard FXServer Linux artifacts) on Ubuntu.

---

## 1. Server prerequisites

```bash
sudo apt update
sudo apt install -y curl xz-utils rsync mariadb-server
```

`tmux` is deliberately not in that list any more — the server runs under
systemd (see below), and tmux is only needed for the fallback unit.

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

**Run it under systemd, using the unit in `tools/`.** Not from an interactive
SSH session: a server started by hand in a terminal dies when that terminal
does, and does not come back after a reboot. That was how this server actually
ran until 2026-08-09, and it is the reason the unit exists.

```bash
sudo cp tools/royale.service /etc/systemd/system/royale.service
sudo nano /etc/systemd/system/royale.service   # set User= and the paths
sudo systemctl daemon-reload
sudo systemctl enable --now royale
```

Then:

```bash
systemctl status royale        # is it up
journalctl -u royale -f        # the console output, live
sudo systemctl restart royale  # bounce it
```

> **The segfault caveat.** Recent Linux artifacts are widely reported to crash
> when systemd launches them **directly**. `tools/royale.service` goes through
> `bash -c` for exactly that reason — the shell wrapper is the documented
> workaround. If it still segfaults on your host, swap in
> `tools/royale-tmux.service`, which runs the same thing inside a `tmux`
> session (`sudo apt install -y tmux` first). That variant supervises the
> process less well and puts nothing in the journal, so it is the fallback
> rather than the default — but it also makes `tmux send-keys` available, which
> is a cheap version of the admin command channel M9 needs.

**Deploying is a separate step from running**, and keeping them separate is
deliberate: a `systemctl restart` should relaunch what is already on disk, not
silently pull new code. Sync with `tools/deploy.sh`, then restart:

```bash
./tools/deploy.sh && sudo systemctl restart royale
```

> **If you are still using a hand-written `pull-and-start.sh`**, `tools/deploy.sh`
> replaces it and fixes three things. `sudo git pull` has no `set -e` and no
> non-interactive handling, so a diverged clone hangs or half-completes and the
> copy afterwards runs anyway. `cp -r` never deletes a file that was removed
> upstream, unlike `rsync --delete`. And an unquoted `[fivem-royale]` is a bash
> **glob** — a character class matching one character from `f,i,v,e,m-r,y,a,l`
> — which works today only because `resources/` happens to contain no
> single-character entry for it to match.

---

## 2. Database — optional, and skippable on first boot

**You do not need this to run a match.** `br_stats` checks at runtime whether
oxmysql is available and disables itself cleanly if not, printing why. Gameplay
is unaffected; you simply get no persistent stats, XP or leaderboards.

If you are booting for the first time and want a clean log, comment these two
lines out of `server.cfg` and come back to this section later:

```cfg
# ensure oxmysql
# ensure br_stats
```

`ensure` on a resource that is not installed logs a "could not find resource"
error. It is harmless, but it is noise in exactly the log you want to be reading
carefully on a first boot.

### 2a. Install oxmysql

oxmysql is a third-party resource, not something npm or apt provides. Download
the latest release and drop it in `resources/[standalone]/`:

```bash
mkdir -p ~/fxserver/resources/\[standalone\] && cd ~/fxserver/resources/\[standalone\]
curl -sSLo oxmysql.zip \
  https://github.com/CommunityOx/oxmysql/releases/latest/download/oxmysql.zip
unzip -q oxmysql.zip && rm oxmysql.zip
```

You should end up with `resources/[standalone]/oxmysql/fxmanifest.lua`. If the
folder is nested one level deeper after extraction, move it up — FXServer will
not find it otherwise.

### 2b. MariaDB

```bash
sudo systemctl enable --now mariadb
sudo mariadb-secure-installation
```

Create the database and a dedicated user:

```bash
sudo mariadb -u root -p <<'SQL'
CREATE DATABASE fivem_royale CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'royale'@'localhost' IDENTIFIED BY 'CHANGE_ME_STRONG_PASSWORD';
GRANT ALL PRIVILEGES ON fivem_royale.* TO 'royale'@'localhost';
FLUSH PRIVILEGES;
SQL
```

Apply the schema (safe to re-run):

```bash
sudo mariadb -u root -p fivem_royale \
  < resources/[fivem-royale]/br_stats/sql/schema.sql
```

Then set `mysql_connection_string` in `server.cfg` to match the password you chose,
and uncomment `ensure oxmysql` and `ensure br_stats`.

Order matters: `set mysql_connection_string` must appear **before** `ensure oxmysql`,
and `ensure oxmysql` before `ensure br_stats`. The supplied `server.cfg.example`
already has them in the right order.

Verify with `brdb` on the server console:

```
oxmysql       started
ready         true
healthy       true
```

`ready true / healthy false` means oxmysql connected but the schema is missing —
run the `schema.sql` step above. That distinction is deliberate: "no database"
and "database with no tables" have different fixes, and guessing between them
wastes time.

**Security:** MariaDB binds to `localhost` by default. Leave it that way and do
**not** open port 3306 in the EC2 security group — the game server and the
database are on the same host and never need to talk over the network.

**If the database is unavailable**, `br_stats` disables itself and says why.
Matches still run; only persistence is lost. Check with `brdb` on the console.

---

## 3. Resources

Copy `resources/[fivem-royale]/` into the server's `resources/` directory, and
install `oxmysql` into `resources/[standalone]/`.

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
| `mysql_connection_string` | Must match the password set above. |
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
comfortable for 48 slots plus MariaDB.

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
| shared coverage | a `br_lib/shared/*.lua` appears in no consuming resource's `shared_scripts` — the gap that let two finished modules sit dead |
| secrets | anything credential-shaped is about to be committed, anywhere in the repo |
| slice-1 boundary | `tools/dispatch.sh` grows a verb beyond `status`/`telemetry`, or `br_ringmaster` gains a write path (see PLAN.md, M9 Slice 1) |

Requires Lua 5.4 (`winget install --id DEVCOM.Lua -e`, or your distro's package).
The script finds `luac` on its own.
