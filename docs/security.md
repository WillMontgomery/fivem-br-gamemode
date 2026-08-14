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

**3. Damage is validated at the source (M6).** FiveM raises
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
validator ran in log-only mode for a full playtest first, on the rule that
every refusal printed during honest play is a false positive; that log came
back empty, which is what unlocked enforcement.

**Not every refusal is a cheat signal, and conflating them makes the threshold
useless.** Every refused shot resolves to exactly one reason, and each reason
is classed once:

| Refusal | What produced it | Counted? |
|---|---|---|
| `WARMUP` | a hit on or from the practice pad | no — warmup deals no damage by design |
| `SAME_SQUAD` | friendly fire | no |
| `NOT_LIVE` | one of the two is not alive in this match | no |
| `OTHER_MATCH` | a shot that raced a match boundary | no |
| `NO_WEAPON` | a weapon this gamemode does not issue at all | **yes** |
| `NOT_HELD` | a weapon the server did not put in *your* hands | **yes** |
| `NO_AMMO` | a magazine the server never filled | **yes** |
| `TOO_FAR` | beyond the weapon's range, plus slack | **yes** |
| `TOO_FAST` | faster than the weapon can cycle, plus slack | **yes** |
| `NOT_THROWN` | an explosion from something you never threw | **yes** |
| `SELF` | hurting yourself *repeatedly* — 3+ times in 5s | **yes** |

The split is the difference between *rules* and *means*. An honest client
produces the top group constantly — and since fists are a real weapon, every
player has the means to at any moment, so counting them would trip an
anticheat built for trainers on the first warmup scrap. There is no honest
input that produces the bottom group.

**Self-damage is allowed.** You can stand in your own grenade and it hurts
you, like anyone else's would. What is refused and counted is *repetition* —
three self-inflicted hits inside five seconds is somebody exercising a path
rather than playing badly.

**`OTHER_MATCH` is not counted, and the reason is worth stating.** Matches run
in parallel in separate routing buckets, so two players in different matches
cannot normally see or shoot each other at all — which makes this refusal
almost exclusively a *boundary race*. A player finishing an automatic burst at
the instant their match ends, or at the instant the other player is moved to
the lobby, generates one of these per round still in flight. That is a dozen
refusals from a single honest trigger pull, which would fire the response on
its own. Producing it deliberately would first require defeating bucket
isolation, which is a much louder failure with its own detection.

**The exact trigger.** There is one escalating rule and these are its numbers:

> **8** countable refusals from the same player inside a **10-second** rolling
> window **files one incident**, once only, for that window. The window restarts
> empty on the next refusal after it lapses. Configured at
> `BR.Config.Combat.refusalLimit` and `refusalWindowMs`.

These numbers were tightened from 12-in-30s once rules refusals were separated
out: what is left in the countable stream has no honest explanation, so eight
of them inside ten seconds is a decision rather than a bad minute.

**The game no longer decides what happens to the player** (owner call,
2026-08-14). `refusalAction` — which read `log` | `notify` | `kick` — is gone,
along with the in-game warning and the `DropPlayer` that sat behind it. Two
things were wrong with deciding here:

- **The player was told.** A notice reading "your shots are not landing" is
  free tuning feedback for whoever is testing a trainer. Nothing is now shown
  to an offender at any point, and the eventual kick reason is deliberately
  generic.
- **The evidence was gathered after the fact, if at all.** Dropping the player
  first ended the session the evidence had to come from.

So the order is inverted. Crossing the threshold collects what the match knows
about that player and files an **incident**; Ringmaster reads the case, decides,
and sends any enforcement back over the command channel it already owns. It is
the side with the ban list, the audit log and a human. This side has a counter.

`BR.Damage.noteRefusal` still prints one line to the **server console**, which
no player reads. Nothing else in the game escalates on repetition — no strike
count survives a window, a match, or a session.

**Severity is a triage hint, not a verdict.** `BR.IncidentBuild.SEVERITY_OF`
grades a window by its *worst* reason, using the tally the firing now carries:

| Tier | Reasons | Why |
|---|---|---|
| `high` | `NO_WEAPON`, `NOT_HELD`, `NO_AMMO`, `NOT_THROWN` | The server never issued the means. There is no honest path to a weapon the gamemode does not have or a magazine it did not fill. |
| `normal` | `TOO_FAR`, `TOO_FAST` | A number the weapon does not have — real, but manufacturable by 2Hz position sampling and a bad tick, which is why the validator already carries slack. |
| — | `SELF` | **Counts toward the threshold, files nothing on its own.** |

`SELF` is the one worth explaining. It has to keep counting, or somebody mixing
self-hits with real means would fall below eight and never trip at all. But
`selfLimit` is 2 over 5 seconds, so the third self-damage tick already reads as
repetition — and one grenade at your own feet lands several ticks well inside
that. A pure-self cluster of eight is two grenades, not somebody exercising
something. Mixed with one real refusal, the case files at the real refusal's
severity; the self-hits do not soften it.

**The game files the row itself, and that is a deliberate widening of `br_ddb`.**
`ringmaster-incidents` is the one console-owned table the game may write, and it
is **append-only**: file a case, never read one back, no access at all to grants,
bans or audit. The write is conditional on the id being absent, so a repeat can
only be refused — it cannot overwrite a case, or erase a verdict and the admin who
made it.

The alternative was posting the case over the event channel and letting the
console write it. That is worse: the channel drops batches silently after four
attempts and nothing on either envelope says so, and an incident lost that way is
unrecoverable because the evidence buffer behind it is discarded at match end. So
the row is written by the game and the event carries only an id. What a
compromised game box gains from this grant is the ability to file noise.

**One event, three answers, and `weaponType` gives all of them.**
`weaponDamageEvent` fires for everything that hurts a player — gunfire, melee,
explosions, but also falls, fire, drowning and being run over. `damageType`
looks like it should sort those out and does not: bullets, melee *and*
grenades all report 3, and melee sometimes reports 1. So the weapon hash
decides, against three tables:

- **ours** — a weapon this gamemode issues → validate and apply;
- **the world's** — `WEAPON_FALL`, `WEAPON_FIRE`, `WEAPON_EXPLOSION` and the
  rest → always the engine's, never a refusal. An ambient car explosion or a
  fall off a roof never reaches the validator at all;
- **neither** — a weapon nobody was issued → the only thing worth refusing.

Explosions are
validated differently on purpose, because a grenade breaks three assumptions a
bullet satisfies: the thrower is holding *fists* by the time it goes off (so
possession is checked against a recent throw the server watched them spend, not
against what is in their hand); the bound on distance is the throw *plus* the
blast; and a cluster of stickies detonating in the same millisecond is not a
weapon cycling impossibly fast. Blast damage is flat — the only distance the
server knows is thrower-to-victim, and the victim standing *on* the grenade is
the far one, so falloff would make a direct hit the weakest hit in the game.

**What this is not.** There is no signature scanning, no injected-DLL
detection, no behavioural heuristics — nothing that tries to identify a cheat
*program*. The design goal is narrower and more durable: make the client's
opinion structurally irrelevant to the outcome. A cheat that can make your own
screen lie is uninteresting; one that can make the server award you a kill is
the only kind that matters, and those are the paths that are closed.

---

