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

### Voice is pma-voice, and it is pinned

Voice runs on **[pma-voice](https://github.com/AvarianKnight/pma-voice)** (MIT,
© Dillon Skaggs), which owns proximity and the squad radio. `br_core` sets the
convars and the channels; it does not implement voice.

```bash
git clone --branch v7.0.2-rc3 --depth 1 \
    https://github.com/AvarianKnight/pma-voice.git '[voice]/pma-voice'
```

- **The pin is `v7.0.2-rc3`, not `v7.0.0`,** and this is the one place in the
  setup where "the latest tag that is not a release candidate" is the wrong
  instinct. `v7.0.0` carries the proximity bug this server reports; `v7.0.1-rc2`
  onwards fixes it upstream, three ways. `server.cfg.example` argues the whole
  case at the `ensure` line and prints the upgrade command at runtime when it
  detects the old build.
- **Install it *outside* `resources/[fivem-royale]/`.** The deploy syncs that
  directory only, so pma-voice at `resources/[voice]/pma-voice` survives every
  deploy untouched.
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
./tools/verify.sh          # syntax, tests, and 15 further gates
cd ui-src && npm run dev   # the UI in a browser, no game required
cd ui-src && npm run build # typecheck, build, and CSS compatibility check
```

`verify.sh` runs **17 gates**, in increasing order of strictness, exiting
non-zero on any failure:

| | |
|---|---|
| `syntax` | Lua 5.4 on every file |
| `tests` | ~3,100 assertions across 8 suites |
| `scope gate` | OneSync scope-limited natives banned from client gameplay code |
| `weapon table` | every weapon hash re-derived from its name |
| `POI siting` | spacing, water, no-loot zones, distance to roads |
| `forward locals` | a `local function` called above its own declaration |
| `config report` | the convar allowlist stays free of credentials |
| `tunable overrides` | overridable keys are server-only; every manifest loads them in order |
| `manifest coverage` | every `.lua` is declared in an fxmanifest |
| `shared coverage` | everything dropped in `br_lib` is actually loaded |
| `deploy payload` | the deploy's own payload check still works |
| `console capability boundary` | `dispatch.sh`'s SSH verb set, exactly |
| `branch-switch invariant` | no path to a hard reset that skips the dispatch blob check |
| `incident surface` | only `BR.ShotSuspicious` can reach the Ringmaster |
| `secrets` | scans the whole repo, not just `resources/` |
| `br_ddb bundle` | the committed bundle matches `js-src/br_ddb` |
| `duplicate console commands` | one name, one registration |

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

