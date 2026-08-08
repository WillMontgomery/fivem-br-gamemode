# Cheat resistance

Why the client is never the authority on anything that decides a match.

[← Back to the main README](../README.md)

---

FiveM's default trust model was built for co-op sandboxes: **the shooter's
client decides what happened.** Your machine computes the hit, computes the
damage, and tells the server. A captured `weaponDamageEvent` from this project
shows it plainly —

```
overrideDefaultDamage   true
weaponDamage            234        <- the client's own number
willKill                true       <- ...and its own verdict
```

That is fine for a sandbox where everyone is a guest and nothing is at stake.
It is not fine for a mode where one player wins.

**The gamemode is built so the client is never the authority on anything that
decides a match.** Not as a bolt-on anti-cheat, but because every subsystem was
written server-first from M1 onward. Three layers:

**1. The roster is the only truth.** Who is alive, what state they are in, what
squad they are on, their health and placement — all of it lives in
`br_core/server/roster.lua` and reaches clients as explicit broadcasts. A
client cannot make itself alive, resurrect a squadmate, or see a player the
server has not told it about. `tools/verify.sh` fails the build if a
scope-limited native appears in client gameplay code, because deriving state
from what happens to be nearby is how authority leaks back to the client by
accident.

**2. The inventory is server-owned, and that is inherently harder to cheat than
a client-side one.** Every slot, every stack and every round of ammunition
lives on the server. The client sends *requests* — "select slot 3", "drop
this", "claim entry 412" — and renders whatever comes back. Consequences:

| Attack | Why it fails |
|---|---|
| Spawn an item into your inventory | There is no code path that adds a stack from a client message. Items enter only by claiming a world entry the server generated. |
| Claim loot across the map | Claims are range-checked against the roster's own sampled position, rate-limited, and arbitrated first-come — a second claimant gets a refusal. |
| Duplicate an item | Entries are single-use ids on the server; the second claim finds nothing. |
| Give yourself ammo | Ammo reports are **decrease-only**: a report that raises a number is refused outright. The worst a liar can do is disarm themselves. |
| Read where all the loot is | The layout seed never leaves the server. Clients are streamed only the cell they are standing in and its neighbours. |
| Carry an item the mode does not issue | Weapons are matched against an allowlist keyed by hash; anything else is not a weapon this gamemode knows about. |

The general shape: **a client can ask for things, and every answer is computed
from state it does not hold.**

**3. Damage is validated at the source (M6, in progress).** FiveM raises
`weaponDamageEvent` on the *server* before damage is applied network-wide, and
`CancelEvent()` there stops it reaching anyone — a genuine veto rather than a
report after the fact. Every shot is checked against the server's own model:

- is that weapon one we actually issued to this player? *(we own the inventory)*
- did it have rounds in it? *(we own the ammo)*
- were they close enough for that weapon's range? *(we own positions)*
- could that weapon physically cycle that fast? *(`minInterval`)*
- is the target on their own squad?

None of that reads anything the shooter sent. The damage figure is then
recomputed from our own tables — weapon, rarity, distance falloff and the body
part that was hit — so a modified `weaponDamage` is *evidence*, never input.

Slack is deliberate and documented: roster positions sample at 2 Hz, so both
players can be ~4.5 m stale at a sprint. Refusing an honest shot is a broken
game; accepting a marginal one is a rounding error no aimbot can exploit. The
validator runs in log-only mode first, and every refusal printed during honest
play is a false positive to be fixed before enforcement is switched on.

**What this is not.** There is no signature scanning, no injected-DLL
detection, no behavioural heuristics — nothing that tries to identify a cheat
*program*. The design goal is narrower and more durable: make the client's
opinion structurally irrelevant to the outcome. A cheat that can make your own
screen lie is uninteresting; one that can make the server award you a kill is
the only kind that matters, and those are the paths that are closed.

---

