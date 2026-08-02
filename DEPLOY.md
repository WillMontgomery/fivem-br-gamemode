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

> **Run under tmux, not directly under systemd.** Recent Linux artifacts have a
> known segfault when launched directly by systemd. Either use `tmux`, or write a
> unit that launches through a shell wrapper.

```bash
tmux new -s royale
cd ~/fxserver && ./run.sh +exec server.cfg
# detach with ctrl-b then d
```

---

## 2. Database

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

Then set `mysql_connection_string` in `server.cfg` to match the password you chose.

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
on the server**. Node is only needed if you intend to change the interface:

```bash
cd resources/[fivem-royale]/br_ui
npm install
npm run build      # typechecks, then writes ui/
npm run dev        # browser dev harness, no game required
```

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

Three gates: Lua 5.4 syntax on every file, unit tests for the pure logic
(geometry, storm solver, seeded RNG, loop registry, XP curve), and a scope gate
that fails the build if a scope-limited native appears in client code without an
explicit `-- scope-ok:` marker.

Requires Lua 5.4 (`winget install --id DEVCOM.Lua -e`, or your distro's package).
The script finds `luac` on its own.
