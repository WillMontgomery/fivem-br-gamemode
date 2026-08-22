# Running and developing

Server setup, the UI build, the verification gate and the in-game diagnostics.

[← Back to the main README](../README.md)

---

See **[DEPLOY.md](../DEPLOY.md)** for the full walkthrough. In short:

```bash
git clone https://github.com/WillMontgomery/fivem-br-gamemode.git
cp server.cfg.example server.cfg     # then fill in sv_licenseKey
```

Copy `resources/[fivem-royale]/` into your server's resources directory, or use
[`tools/deploy.sh`](../tools/deploy.sh) to pull and sync automatically.

**OneSync is required** (`set onesync on`). Without it the server cannot see
player entities at all — no positions, no storm damage, no validation — and the
failure is completely silent. The server warns loudly at boot if it is off.

A database is **optional**. Without one, `br_stats` disables itself and matches
run normally; you just get no persistent stats.

### Two convars a deployment has to answer for itself

Everything else in `br_lib/config/overrides.lua` overrides a reviewed default.
These two have no default to override — they are addresses that exist only per
deployment — and both are **unset by default, where unset means the feature is
simply absent**:

| convar | kind | unset means |
|---|---|---|
| `br_adminConsoleUrl` | `url` | No Admin tab in the pause menu, no HTTP call, and one line in the boot banner. The game never depends on Ringmaster, so a server with no console configured plays exactly as it did before the feature existed. |
| `br_discordUrl` | `link` | A kicked or banned player is told why and nothing more — **no line at all**, not an empty URL and not a bare "contact an admin". |

**They are parsed differently on purpose, and that is why there are two kinds.**
`br_adminConsoleUrl` is *compared* against a browser's `event.origin`, so it must
be bare and a trailing slash is fatal. `br_discordUrl` is *opened* by a person,
and a Discord invite is nothing without its path — `https://discord.gg/<code>` is
entirely code. Kind `url` would have refused the only value anybody will ever put
in it.

Both get what the overrides mechanism gives everything else: a strict parse, a
hard boot failure on a malformed value, a boot banner line and a `brconfig` line.
A **third** address arriving in that file is the signal to ask whether it is still
the tunables or has quietly become the deployment addresses as well.

### Voice is pma-voice, and it is vendored and pinned

Voice runs on **[pma-voice](https://github.com/AvarianKnight/pma-voice)** (MIT,
© Dillon Skaggs), which owns proximity and the squad radio. `br_core` sets the
convars and the channels; it does not implement voice.

**There is nothing to install.** pma-voice is vendored into this repository at
`resources/[voice]/pma-voice` and `tools/deploy.sh` syncs it to
`resources/[voice]/pma-voice` on the box — the same path a hand-installed clone
used, so a deploy *replaces* that clone rather than adding a second resource
beside it.

> **Upgrading a box that predates the vendoring:** `rm -rf` the old
> `resources/[voice]/pma-voice` **once**, before the first deploy that carries
> the vendored copy. `rsync --delete` does not delete excluded paths, so the old
> clone's `.git` would otherwise survive and misreport the version.

- **The pin is `v7.0.2-rc3`, not `v7.0.0`,** and this is the one place in the
  setup where "the latest tag that is not a release candidate" is the wrong
  instinct. `v7.0.0` carries the proximity bug this server reports; `v7.0.1-rc2`
  onwards fixes it upstream, three ways. `server.cfg.example` argues the whole
  case at the `ensure` line and prints the upgrade command at runtime when it
  detects the old build.
- **The exact upstream commit is recorded** in
  `resources/[voice]/pma-voice/VENDOR.json`, along with a log of every local
  change. There are four such lines, each marked `BR-PATCH`: they remove an
  unconditional debug `print`, silence the mic-click chirp at source, and delete
  the two `RegisterKeyMapping` calls that put "Cycle Proximity" (F11) and "Talk
  over Radio" (Left Alt) in FiveM's key list outside our own key layer. The
  `+radiotalk` **command** is untouched — it is the squad transmit path.
- **`tools/verify.sh` enforces the vendoring**: LICENSE present, version
  recorded, patch log and source in agreement both ways, and `deploy.sh`
  actually syncing the resource.
- **A missing pma-voice announces itself** in the server console at start and on
  the first attempt to use voice, rather than failing silently.
- The convars are set from `server.cfg.example`, which is **documentation and is
  not deployed** — `br_core` re-states what it needs at runtime, so a server
  brought up without them still works.

`brvoice` in the client console reads back mode, channel and who this client can
hear; `brvoice` in the server console says whether pma-voice is even present.

---

## Development

```bash
./tools/verify.sh          # syntax, tests, and 18 further gates
cd ui-src && npm run dev   # the UI in a browser, no game required
cd ui-src && npm run build # typecheck, build, and CSS compatibility check
```

`verify.sh` runs **20 gates**, in increasing order of strictness, exiting
non-zero on any failure:

| | |
|---|---|
| `syntax` | Lua 5.4 on every file |
| `tests` | ~3,900 assertions across 10 suites |
| `scope gate` | OneSync scope-limited natives banned from client gameplay code |
| `weapon table` | every weapon hash re-derived from its name |
| `POI siting` | spacing, water, no-loot zones, distance to roads |
| `forward locals` | a `local function` called above its own declaration |
| `config report` | the convar allowlist stays free of credentials |
| `voice defaults` | voice modes are exclusive and the default agrees in Lua, TS and the bundle |
| `tunable overrides` | overridable keys are server-only; every manifest loads them in order |
| `manifest coverage` | every `.lua` is declared in an fxmanifest |
| `shared coverage` | everything dropped in `br_lib` is actually loaded |
| `deploy payload` | the deploy's own payload check still works |
| `vendored third-party` | licence kept, version recorded, patch log matches the source, `deploy.sh` syncs it |
| `console capability boundary` | `dispatch.sh`'s SSH verb set, exactly |
| `branch-switch invariant` | no path to a hard reset that skips the dispatch blob check |
| `incident surface` | only `BR.ShotSuspicious` can reach the Ringmaster |
| `timeline entry kinds` | every match-timeline kind Lua writes is one `close.js` stores |
| `secrets` | scans the whole repo, not just `resources/` |
| `br_ddb bundle` | the committed bundle matches `js-src/br_ddb` |
| `duplicate console commands` | one name, one registration |

> **This table said 17 gates and "~3,100 assertions across 8 suites".** Neither
> survived the month. Three gates landed after it — `voice defaults`,
> `vendored third-party` and `timeline entry kinds` — and three suites came with
> them: `test_config` (2026-08-19), then `test_artifacts` and `test_admin`
> (2026-08-20). A gate list that quietly runs short is the failure mode this
> table exists to prevent, so the count is stated as well as the rows: if they
> disagree, the table is the stale one.

The unit tests cover the pure logic and the server model: geometry, storm solver
and anchor picker, seeded RNG, loot layout generation, loop registry, roster,
match flow, bus routes, storm engine, loot streaming and claims, the inventory
model, parties, the XP curve, the Ringmaster surface, and the client interaction
layer. See **[testing.md](testing.md)** for what each suite is for.

Every regression test must be **proven load-bearing**: revert the fix, confirm
the test fails, restore it. A test that passes either way is rewritten. Anything
that has to reach clients is asserted **on the wire** (the captured
`TriggerClientEvent` stream), not on the server's own tables — a bug that
passed every server-side assertion and still shipped is what set that rule.

Install the pre-commit hook with `./tools/install-hooks.sh`.

### In-game diagnostics

| Command | Where | What |
|---|---|---|
| `brnativecheck` | client | Verify every native assumption against the running build |
| `brprobe` | client | What the natives actually *do*, not what they are named. Sub-modes for ammo, vehicles, armour, crates; `brprobe raw` suspends our own writes so the engine can be watched alone |
| `brdriveby [seconds]` | client | Why a passenger cannot fire. Samples across frames from the seat: which seat, what the *engine* has in your hands versus what we granted, whether anything disabled a trigger control, and whether we ever asserted the drive-by permission. Exists because those four causes are indistinguishable from inside the car and each wants a different fix |
| `brblack` | client | Every state that can cause a black screen, at once |
| `brfocus` | client | The NUI focus stack — why you do or don't have a cursor |
| `brbus`, `brdropdbg` | client | Bus ride and skydive state, live |
| `brloot` | client | What this client can see: entries, live props, nearest item |
| `brvoice` | both | Proximity voice state — mode, channel, who this client hears. The server's first line says whether pma-voice is even installed |
| `brdbno` | both | The downed/revive interaction, counted as it happens: asks, stops, refusals with their reason, progress ticks, and frames where a live hold found no body. Exists because "I hold the button, the ring fills, nothing happens" describes three different faults that look identical on screen |
| `brcrawl` | client | The crawl: which clip the build actually resolved, and whether this client is emitting anything network-visible while lying still |
| `brpromptcheck` | client | Which prompt glyph actually renders for a custom keybind |
| `/brleave` | client | Leave the current match (counts as an elimination) |
| `brperf` | both | Per-subsystem frame and tick cost |
| `brconfig` | server | The config values that most often explain odd behaviour |
| `brring` | server | Ringmaster link: whether it is configured, and what it would send |
| `brddb` | server | Probe DynamoDB — reachability, credentials, table access |
| `brwhy <id>` | server | Why a given player is in the state they're in |
| `brscatter` | server | Spread everyone 3 km apart to test OneSync scoping |
| `brforce <state>`, `brskip`, `brkill <id>` | server | Drive the match by hand |
| `brloot [matchId]` | server | World loot: counts by kind and rarity, cells, who is subscribed |
| `brinv <id>`, `brgive <id> <item> [n]` | server | Read or fill a player's inventory |
| `brphase <n>` | server | Jump the storm to phase n, seamlessly from the live circle |
| `brstormscale <0.05–1>` | server | Compress storm pacing for testing (0.1 ≈ a 2-minute cycle) |
| `brdown <id>`, `brrevive <id>`, `brbleed <id> [damage]` | server | Knock, pick up, or take damage off a downed player's clock as an enemy shot would. `brdown` refuses and says why when the rules say it should — solo, or no standing squadmate |
| `brartifacts` | server | Incident screenshots: whether `screenshot-basic` is even running, cases open, frames claimed / asked for / stored / lost, and the refusals told apart from the losses — at the cap of nine, inside the first ten seconds, or for a case this process did not file. The only window onto this feature from the box, because nothing about a capture is visible in the game. Restricted |
| `brstrips` | server | The unissued-weapon detector: reports received and counted, throttled, and refused because the weapon turned out to be in the player's own server-side inventory. That last counter is what the command exists for — it is the one false positive this feature can produce, and on a healthy server it is zero. Restricted |
| `bradmin` | server | Why a given player has no Admin tab. The tab is binary and its preconditions are not, so this names which of six reasons applies to each connected player — convar unset, no license, grant row without the scope, no answer from DynamoDB yet, no `discord:` identifier, or an answer this process already settled. Restricted, because it names who holds admin scope |
| `brwarmupfreeze [off]` | server | Hold the warmup pad open indefinitely; the next match inherits the hold. Dev mode plus restricted, modelled on `brstormfreeze` down to `off` as the way back. Implemented as a deadline a day out rather than a flag, because clients count down by subtracting it and an infinity poisons every one of those subtractions. It does **not** lift itself at match end, unlike the storm freeze — a held warmup never reaches the end of a match to hang a release on |
| `brstormfreeze [off]` | server | The same for the storm wall. Dev mode plus restricted; drops at the end of the match it was holding, because a next round with no storm never ends |
| `brawards` | server | The report-reward pipeline: claimed, swept, paid, already paid, settled, expired — then forces a sweep. Restricted, because it names licenses |
| `brxpsim <id> [xp]` | server | Drive a real XP award and level-up at a lobby player without playing a match. Server console only; Volts report as 0 on purpose, because claiming a payout nothing paid is the bug this exists to avoid |
| `brlootsim [crates] [tier] [seed]` | server | Roll the loot tables offline and print the distribution. Reads nothing about any player, changes nothing, spawns nothing |
| `brstate`, `brroster`, `brstorm`, `brqueue`, `brparty` | server | State dumps |

Separately, the console's SSH channel carries a read-only `configreport` verb
that renders a config surface into the admin UI. It reads an explicit allowlist
of convar names rather than the whole of `server.cfg`, because `server.cfg` is
where `sv_licenseKey` lives. That verb set — `status`, `telemetry`,
`configreport`, `kick`, `deploy`, `branches`, `switchref`, and nothing else — is
pinned by the *console capability boundary* gate in `verify.sh`; a new verb is a
new capability from the console to the host, and adding one means updating that
gate on purpose.

---

