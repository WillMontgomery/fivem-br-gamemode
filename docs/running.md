# Running and developing

Server setup, the UI build, the verification gate and the in-game diagnostics.

[← Back to the main README](../README.md)

---

See **[DEPLOY.md](DEPLOY.md)** for the full walkthrough. In short:

```bash
git clone https://github.com/WillMontgomery/fivem-br-gamemode.git
cp server.cfg.example server.cfg     # then fill in sv_licenseKey
```

Copy `resources/[fivem-royale]/` into your server's resources directory, or use
[`tools/deploy.sh`](tools/deploy.sh) to pull and sync automatically.

**OneSync is required** (`set onesync on`). Without it the server cannot see
player entities at all — no positions, no storm damage, no validation — and the
failure is completely silent. The server warns loudly at boot if it is off.

A database is **optional**. Without one, `br_stats` disables itself and matches
run normally; you just get no persistent stats.

---

## Development

```bash
./tools/verify.sh          # syntax + tests + scope gate + manifest coverage
cd ui-src && npm run dev   # the UI in a browser, no game required
cd ui-src && npm run build # typecheck, build, and CSS compatibility check
```

`verify.sh` runs four gates: Lua 5.4 syntax on every file, ~770 unit tests over
the pure logic (geometry, storm solver and anchor picker, seeded RNG, loot
layout generation, loop registry, roster, match flow, bus routes, storm engine,
loot streaming and claims, the inventory model, parties, XP curve), the scope
gate, and a check that every `.lua` is declared in its `fxmanifest` — because a
file that is never loaded produces no error.

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
| `brblack` | client | Every state that can cause a black screen, at once |
| `brfocus` | client | The NUI focus stack — why you do or don't have a cursor |
| `brbus`, `brdrop` | client | Bus ride and skydive state, live |
| `brloot` | client | What this client can see: entries, live props, nearest item |
| `brpromptcheck` | client | Which prompt glyph actually renders for a custom keybind |
| `/brleave` | client | Leave the current match (counts as an elimination) |
| `brperf` | both | Per-subsystem frame and tick cost |
| `brwhy <id>` | server | Why a given player is in the state they're in |
| `brscatter` | server | Spread everyone 3 km apart to test OneSync scoping |
| `brforce <state>`, `brskip`, `brkill <id>` | server | Drive the match by hand |
| `brloot [matchId]` | server | World loot: counts by kind and rarity, cells, who is subscribed |
| `brinv <id>`, `brgive <id> <item> [n]` | server | Read or fill a player's inventory |
| `brphase <n>` | server | Jump the storm to phase n, seamlessly from the live circle |
| `brstormscale <0.05–1>` | server | Compress storm pacing for testing (0.1 ≈ a 2-minute cycle) |
| `brstate`, `brroster`, `brstorm`, `brqueue`, `brparty` | server | State dumps |

---

