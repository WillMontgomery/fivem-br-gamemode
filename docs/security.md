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
| Claim loot across the map | Claims are range-checked against the roster's own sampled position, rate-limited, arbitrated first-come, and refused for any entry the server never streamed to that player. |
| Duplicate an item | Entries are single-use ids on the server; the second claim finds nothing. |
| Give yourself ammo | Ammo reports are **decrease-only**: a report that raises a number is refused outright. The worst a liar can do is disarm themselves. |
| Read where all the loot is | The layout seed never leaves the server, and a player may only subscribe to the cell they are standing in and its neighbours — checked against their own sampled position. |
| Probe which loot is left | A claim for an entry outside your view answers **identically** to a claim for one that no longer exists. Ids are sequential, so distinguishable refusals would have been an existence oracle over the whole layout. |
| Carry an item the mode does not issue | Weapons are matched against an allowlist keyed by hash; anything else is not a weapon this gamemode knows about. |

The general shape: **a client can ask for things, and every answer is computed
from state it does not hold.**

**Two rows in that table were aspirational until 2026-08-14, and it is worth
recording rather than quietly fixing.** `LOOT_CELL` validated the payload's shape,
the player's state and their zone — and then subscribed them to whatever cell they
named, anywhere in the integer plane, unlimited. So the seed staying server-side
constrained only honest clients: a loop over the grid was streamed the entire
layout. `LOOT_CLAIM` separately never checked whether an entry had been streamed to
the claimant, which left three distinguishable refusals over a dense sequential id
space. Both are now closed, and the rule lives in `BR.LootCellReachable`
(`br_lib/shared/loot_gen.lua`) with its arithmetic pinned in `tools/test_shared.lua`
and the handler behaviour in `test_roster.lua`'s `loot.enumeration` block. A
security claim in a document is worth exactly the test behind it.

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

Slack is deliberate and documented: roster positions sample at 4 Hz, so both
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
| `SELF` | hurting yourself *repeatedly* — 3+ times in 5s | **recorded, bars nothing** — see below |

The split is the difference between *rules* and *means*. An honest client
produces the top group constantly — and since fists are a real weapon, every
player has the means to at any moment, so counting them would trip an
anticheat built for trainers on the first warmup scrap. There is no honest
input that produces the bottom group.

**"Counted" in that column means "worth writing down", which is a different
question from "opens a case".** They are two tables in `combat_solve.lua` on
purpose: `BR.ShotSuspicious` gates the per-shot console line and the event, and
`BR.ShotTier` decides what files a case and how loudly. Every row marked **yes**
is in both. `SELF` is in the first and deliberately not the second — see the tier
table further down, which is where the bar actually lives.

**Self-damage is allowed.** You can stand in your own grenade and it hurts
you, like anyone else's would. What is refused and recorded is *repetition* —
three self-inflicted hits inside five seconds is somebody exercising a path
rather than playing badly. It grades nothing.

**`OTHER_MATCH` is not counted, and the reason is worth stating.** Matches run
in parallel in separate routing buckets, so two players in different matches
cannot normally see or shoot each other at all — which makes this refusal
almost exclusively a *boundary race*. A player finishing an automatic burst at
the instant their match ends, or at the instant the other player is moved to
the lobby, generates one of these per round still in flight. That is a dozen
refusals from a single honest trigger pull, which would fire the response on
its own. Producing it deliberately would first require defeating bucket
isolation, which is a much louder failure with its own detection.

**The exact trigger.** The bar is per reason and per match:

> **1** high-severity refusal, or **2** normal ones, from the same player **in one
> match** files one incident. `NO_WEAPON` is the exception and wants 2. The count
> does not lapse; it resets when the match does. Configured at
> `BR.Config.Combat.refusalBar`, with the tiers in `BR.ShotTier` and the per-reason
> exception in `BR.ShotBarOverride`.

**This replaced 8-inside-a-rolling-10-seconds (owner call, 2026-08-14), and the
reason is worth stating: the old rule described one kind of cheater.** Eight of
anything inside ten seconds is somebody spraying with a trainer. Somebody patient —
one impossible hit every eleven seconds, all match, every match — never reached it,
filed nothing, and left no trace anywhere. Since the countable stream has no honest
explanation at all, there was never a reason to demand eight of it.

`NO_WEAPON` sits at 2 despite being `high`, and it is the only entry that looks
inconsistent. The other three high reasons are checked against state the server
definitely owns: its own inventory, its own ammunition count, a throw it watched.
`NO_WEAPON` is the catch-all — the hash is in neither our weapon table nor the
world's — so its false-positive rate tracks how complete two lookup tables are, and
a hash added by a future game build or carried by an ambient NPC lands there.
Nobody running a conjured weapon fires exactly once.

**Repeat signals corroborate; they do not file again.** `damage.lua` reports at the
bar and then only when the count *doubles* — about ten reports for a thousand
refusals, which keeps a cheater holding the trigger from putting twenty events a
second onto a queue that drops its oldest entries. The first report opens the case;
every later one appends to it, carrying a `seq` so a receiver can tell 1, 2, 4 with
a gap in it from a match where nothing more happened. One case per player per match,
so DynamoDB write volume is flat and no single player can bury a queue that is meant
to be a shrinking worklist.

The console does that append, not the game. Corroboration is an `UpdateItem` on
`events` — the console's own half of the row — and nothing the game holds can reach
it. So corroboration rides the event channel and is allowed to be lost, precisely
because the case it attaches to is already durable.

> **This paragraph used to say the game's grant on `ringmaster-incidents` is
> "append-only", and that stopped being true when the match timeline shipped.** The
> game now holds an `UpdateItem` of its own on that table. It is not a widening of
> what the game can *decide* — see the grant list below — but "append-only" was the
> sentence somebody would have quoted to argue the game cannot write to an existing
> row, and it can.

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
no player reads. Nothing else in the game escalates on repetition — and no strike
count survives a match, which is a real limit rather than an oversight: a player
who stays under the bar every match forever files nothing, and the console's own
Blind spots tab says so.

**Severity is a triage hint, not a verdict.** `BR.ShotTier` grades a match by its
*worst* reason, using the tally the firing carries. It is the same table the bar is
read from, so the decision to file and the severity written on the row cannot
disagree — they were two tables until 2026-08-14, and two tables is two chances to
edit one of them:

| Tier | Bar | Reasons | Why |
|---|---|---|---|
| `high` | **1** | `NOT_HELD`, `NO_AMMO`, `NOT_THROWN` | The server never issued the means, and it is certain of that — its own inventory, its own ammunition count, a throw it watched happen. |
| `high` | **2** | `NO_WEAPON` | Same severity, higher bar: this is the catch-all bucket, so it is as much a gap in a lookup table as a dishonest shooter. |
| `normal` | **2** | `TOO_FAR`, `TOO_FAST` | A number the weapon does not have — real, but manufacturable by position sampling and a bad tick, which is why the validator already carries slack. |
| — | — | `SELF` | **Recorded, and counted toward nothing.** |

`SELF` is the one worth explaining, and it changed on 2026-08-14. It used to count
toward the threshold without earning severity, because otherwise somebody mixing
self-hits with real means would fall below eight and never trip. **At a bar of one
or two that argument inverts**: one self-hit beside one marginal out-of-range shot
would open a case, and a player could manufacture one against themselves by standing
in their own grenades. So it now contributes to nothing.

It is still refused, still printed, and still appears in the tally on the case,
because an admin reading it wants to see the self-harm — it simply must not grade
anything. The arithmetic that made it ambiguous in the first place: `selfLimit` is 2
over 5 seconds, so the third self-damage tick already reads as repetition, and one
grenade at your own feet lands several ticks well inside that. A pure-self cluster
of eight is two grenades, not somebody exercising something.

**The game files the row itself, and that is a deliberate widening of `br_ddb`.**
`ringmaster-incidents` is the one console-owned table the game may write, and it
may write it three ways and no others:

| verb | on | scope |
|---|---|---|
| `PutItem` | `ringmaster-incidents` | conditional on the id being **absent**, so a repeat can only be refused |
| `UpdateItem` | `ringmaster-incidents` | an **attribute allowlist** — `incidentId`, `matchEndedAt`, `matchTimeline`, `matchTimelineComplete`, `matchKillsSeen` — with `ReturnValues: NONE` |
| `GetItem` | `ringmaster-*` | broad in the policy; four tables in the code (below) |

The `UpdateItem` is the match-timeline close, and it is the one verb here that
touches a case that already exists. What makes it safe is the allowlist rather than
the code: `events` is the console's timeline, where an admin's notes,
corroborations and resolution live, and `state`, `verdict`, `resolvedAt`,
`resolvedBy*`, `resolution` and `closedByBan` are the decision itself. **None of
those is in the five attributes the policy permits**, so a compromised game box
cannot express an opinion about a moderation outcome even by writing the field
directly. `ReturnValues: NONE` is the other half and is not decoration — an
attribute allowlist restricts what an update may *write*, and `ReturnValues` is how
the same request could still read the rest of the row back.

> **This section used to say the game "holds no access at all to
> `ringmaster-audit`, and read-only single-key access to `ringmaster-bans` and
> `ringmaster-grants`."** That was the policy until 2026-08-17, when the owner
> widened the read to `dynamodb:GetItem` on the whole `ringmaster-*` prefix, with
> the words *"this is deliberately broad, I know"*. That prefix covers `audit`,
> `bans`, `grants`, `incidents`, `sessions`, `telemetry` and `to-gameserver`. The
> sentence is corrected rather than deleted because a security document that
> understates a grant is the one nobody re-reads.

**So the grant is broad and the code is not**, and the difference is worth stating
as the gap it is. `js-src/br_ddb/src/index.js` names four tables and names each
once:

| table | verb | what for |
|---|---|---|
| `ringmaster-bans` | `GetItem` | the connect gate |
| `ringmaster-grants` | `GetItem` | in-game admin scopes |
| `ringmaster-maintenance` | `GetItem` | the drain gate |
| `ringmaster-incidents` | `GetItem` | the verdict read, plus the two writes above |

Nothing in that file reads `audit`, and nothing should. When somebody comes to
narrow the policy back to a list of ARNs, that table is the answer.

**The incidents read is narrower than the grant in three further ways, all of them
enforced in code rather than promised.** It is a `GetItem` keyed on `incidentId` —
there is no `Query` and no `Scan` anywhere in `br_ddb`, which is the property that
stops a compromised box enumerating cases at all. Every id it is ever called with
came back from this box's own `PutItem`, so "read back cases whose ids it knows"
means "read back its own". And it is a `ProjectionExpression`, not the row: four
attributes — `incidentId`, `state`, `verdict`, `resolvedAt`. The evidence, the
chat log, the kill log, the reporter, the subject and the moderator's written
resolution are all on that item and **none** of them crosses into the game server.

What #168 cost, stated plainly because the owner paid it knowingly: the property
"there is no read of any kind on this table" is gone. A compromised game box can
now learn whether a case it filed was decided and whether an action followed. It
still cannot alter a verdict. See [the ban contract](ban-contract.md).

The alternative was posting the case over the event channel and letting the
console write it. That is worse: the channel drops batches silently after four
attempts and nothing on either envelope says so, and an incident lost that way is
unrecoverable because the evidence buffer behind it is discarded at match end. So
the row is written by the game and the event carries only an id. What a
compromised game box gains from this grant is the ability to file noise.

## The second source: a weapon in a hand the gamemode never filled

Everything above is the **damage** path — refused shots, counted server-side inside
`weaponDamageEvent`. There is a second thing that opens a case, and it is a
different shape in every way that matters, so it is documented apart rather than
folded into the table above.

`br_core/client/inventory.lua` has always taken any weapon that is not the active
inventory slot out of the ped's hand. **That strip is a gameplay fix and not an
anticheat one.** The engine applies damage locally before the server sees it, so a
foreign weapon lets a client kill somebody on their own screen while the server
refuses the shot — the victim reads as dead and is alive. That was a live report on
2026-08-08.

**What was wrong with it was the silence.** A player granting themselves a rifle in
a menu tripped nothing: the weapon vanished, they granted another, and the match
ended with an empty record. The strip now reports, and
`br_core/server/strip.lua` turns those reports into the same kind of case the
refusal path files.

> The **second** countable strip in a match opens one incident. The first is recorded
> and announced to nobody — one weapon in one hand for one tick is the shape our own
> two inventory mirrors disagreeing has, and a second one a second later is not. Every
> strip after the second announces, **each one**, and appends a `weapon_strip` entry to
> **that** incident's `matchTimeline` — never a second case. Announcements no longer
> follow `damage.lua`'s doubling rule: the owner's call on 2026-08-20 was that "'4 or 5
> more times' is too many", so `count` on the wire now climbs 2, 3, 4, 5 and a gap in it
> means a **lost** announcement rather than quiet strips in between. What bounds the
> channel is `MIN_INTERVAL_MS` (one countable strip per 900 ms per player) and the
> artifact planner's per-case frame cap; the timeline still receives all of them,
> because it is RAM until the case's own writes carry it.

**Cost is unchanged by volume.** The strips known at filing time ride the `PutItem`
that was already happening; the rest ride the match-end `UpdateItem` that was
already happening. That close write touches only the attributes the game's grant
on `ringmaster-incidents` allows, and strips add none — which is also why there is
no `matchStripsSeen` counter beside `matchKillsSeen`. A truncated strip list is
reported by `matchTimelineComplete` going false, and that is the whole of it.

**A strip during WARMUP is the earliest signal there is, and it used to be the
least recorded.** `startedAt` is stamped on entering PLAYING, so a case opened on
the warmup pad was filed with no match start, no deadline and an empty timeline —
and, because the game keyed its match-end write on that same start, it never
received an end either. The console reads that shape as "filed outside a match",
which is false about a row carrying a `matchId`. Three things changed:

- the row carries **`matchCreatedAt`**, when the match was *formed*, written by
  the `PutItem` at filing. It is a separate field from `matchStartedAt` rather
  than an early value for it, because one field holding two facts is unreadable;
- the timeline is anchored on a **`match_created`** entry when there is no start
  to anchor it on, so the strips that opened the case are on the record at all;
- the case is queued for the match-end write like any other, and that write now
  carries **`matchStartedAt`** and **`matchEndsBy`** so the real values arrive
  when the match actually starts and ends.

> The close's attribute list **is** the game's IAM grant, and it grew from five to
> seven. **Widen the policy before deploying the code, never after.** DynamoDB
> evaluates `dynamodb:Attributes` against the whole request, so an un-widened
> policy does not drop the two new fields — it refuses the entire `UpdateItem`,
> taking the end timestamp and the post-filing timeline with it, on every case.
> `brring` prints the failed-close count for exactly this reason.

**Two guards stop this accusing innocent players, and they exist because the strip
is deliberately broader than the report.** The strip compares against the *active*
slot, so a weapon from another of the player's own slots — held for the tick between
a slot change and the grant landing — is stripped too. Stripping it is harmless.
Filing it would not be. So the client declines to report a hash that is in any of
its own slots, and the server declines again against **its own** inventory, which is
the copy a compromised client does not control. `brstrips` prints how often that
second guard fired; on a healthy server it is zero.

**Nobody is exempt.** An admin exemption shipped here for one commit, testing the
console grant so that weapons granted through vMenu while testing would not open
cases about the person who reads the queue. The owner removed it the same day: *"I
don't want admins to be exempt from any incidents please."*

They were right, and the reasoning is worth keeping rather than the exemption. The
noise it avoided is a queue the owner can close; the hole it opened was shaped
exactly like the accounts with the most power, and nobody would have seen it. The
grant is no longer consulted at all — an admin, a player known not to be staff, and
a player whose grant row was never read all file identically, so a slow or failed
DynamoDB read cannot decide whether an accusation gets made. Restoring the
exemption fails six tests by name.

The premise was wrong as well as the policy: **vMenu is a development tool and is
not going to production**, so there is no benign route to a weapon this gamemode
never issued. In production every strip is a cheat signal, and one during warmup is
the earliest one available — it happens before the offender has touched a real
player.

**This catches one tier and it is not the serious one.** The report is sent by our
own resource running on the offender's machine. A cheat that stops `br_core` — or
deletes one `TriggerServerEvent` — silences it completely, and no server-side native
can read what is in a ped's hand to check. What it catches is the vMenu tier, with
our resource still running underneath. The unforgeable half is the damage validation
above, which does not need the client's cooperation and cannot be turned off from
one.

## The third source: a vehicle the gamemode refuses

M8's Option A means **this gamemode spawns no vehicles at all** — the supply is
GTA's own ambient traffic and its parked-car network. Nothing in the resource
tree creates a networked vehicle. So any networked vehicle a client creates is,
by construction, something we did not make, and `br_core/server/vehicles.lua`
catches it in the server-side `entityCreating` event.

**The allowlist is authored in `br_lib/config/vehicles.lua`, and its polarity is
the opposite of the weapon table's.** There, a weapon must be written down to be
permitted. Here, a vehicle must be written down to be *refused* — because the
owner's rule is "every vehicle except anything that flies or has built-in
weapons", and GTA ships several hundred of them.

> That makes it a deny-list, and a deny-list rots: an aircraft nobody wrote down
> is permitted silently and forever. **The flight half of the rule does not rot,
> because it is asked of the engine rather than of a list.** `GetVehicleType` is
> answerable server-side and returns one of eight strings; `heli` and `plane`
> between them are "anything that flies", including models added to the game
> after the table was written. It is read out of the client's own clone packet
> and is therefore assertable, which is why it is the *second* signal: the model
> table catches what it names whatever the client claims, and the class catches
> what the table never heard of. Defeating both means spawning an unlisted
> aircraft *and* lying about its class.

**Nothing is cancelled.** The owner's call on 2026-08-21 was *"For offenders,
don't stop them, simply file an incident"* — the same shape as the weapon strip:
prevent at the boundary, and where the boundary is bypassed, record rather than
block. The **second** refused vehicle in a match opens one case; every one after
it corroborates that case, never a second one. The first is silent, and for a
reason specific to this detector rather than the strip's: attribution rests on
`NetworkGetEntityOwner`, and ownership follows proximity and migrates, so one
refused vehicle is a claim resting on one ownership read.

**No new timeline kind was added, and that is a decision.** A strip earns
`weapon_strip` entries because the owner asked for recursive strips to land on
the timeline; paying for that meant a kind the console had to learn and a share
of the truncation budget. "Simply file an incident" asks for what `priorFor`
already does for every producer, so this costs the console nothing new and the
case the same two writes.

**What it can see depends on `sv_entityLockdown`, and the two are partly
substitutes rather than complements.** The platform validates a client's
clone-create *before* raising `entityCreating` — a rejected entity is deleted and
the event never fires. Under `inactive` (the default, and what this project has
always run) the validator is not called at all and every client-created vehicle
reaches the detector. Under `relaxed` the honest cheat is stopped by the platform
and never reaches it; what still arrives is a refused model claiming to be engine
population, because that field is four bits out of the client's own packet.

> **A refused model claiming to be population is counted and not filed**, and
> `brvehicles` prints the models. It is either GTA placing ambient aircraft or a
> client lying to walk one past `relaxed` — indistinguishable from the server,
> and blaming the nearest player for the first would be the worst false positive
> this feature can produce. One playtest reads the list and settles it.

**The mode itself is unresolved and is the owner's call.** `strict` is
incompatible with Option A: the platform's entity validator gates its
engine-population carve-out on the mode not being strict, so strict rejects
`RANDOM_AMBIENT`, `RANDOM_PARKED`, `RANDOM_PATROL`, `RANDOM_PERMANENT` and
`RANDOM_SCENARIO` — which is the entire vehicle supply, plus ambient peds.
Enabling it *is* changing ambient traffic. `server.cfg.example` carries the full
consequence list beside the single line that sets it, and ships the platform
default explicitly so no deploy turns it on by assumption.

## Artifacts: screenshots of the offender, and why they may not exist

A filed case captures the **offending player's own screen** three times —
immediately, at **+5s** and at **+10s** — plus one frame per corroboration
arriving after that first ten seconds, to a maximum of **nine per case**. At the
cap the capture stops; nothing already taken is ever discarded to make room.

The capture runs on the **subject's own machine**, through the third-party Cfx
resource `screenshot-basic`, and uploads to `royale-incidents-bucket` under
`incidents/<incidentId>/NN.webp`. The game box holds `s3:PutObject` on that
prefix and nothing else — it cannot read a frame back, list the bucket, or delete
one. The console holds `GetObject` and serves frames to a browser through
short-lived presigned GETs; the bucket is not public and objects expire after 180
days.

**EMPTY IS NORMAL AND IS NOT EVIDENCE OF ANYTHING.** This is the property that
matters most and the easiest one to lose. The subject can disconnect, crash,
alt-tab, sit on a loading screen, or be running a client where `screenshot-basic`
was never installed — and every frame fails independently of the others. A case
with two frames, or none, is a normal case and says nothing whatsoever about
whether anything was happening. Nothing in the game logs a missing frame as an
error, and nothing anywhere should present one as meaningful.

**A frame is the game's 3D render and nothing else.** `screenshot-basic` captures
off the game's own render target; NUI and the HUD are composited afterwards, so
**they never appear in a frame**. What an admin gets is the world, the ped, the
weapon in its hands and where it is pointing — not the inventory, not the map, not
a menu, and not whatever the cheat's own overlay is drawing. Reading a case as
though the picture were the subject's monitor is the misreading this pipeline
invites, and the frames cannot support it.

**The timestamp is the server's.** This is an anti-cheat surface: the premise is
that the subject may be running modified software, so their clock is not
evidence. Each frame is stamped with `os.time()` on the game box at the moment
the server decided to ask for it, and that value travels as S3 object metadata
(`x-amz-meta-captured-at`, unix milliseconds) rather than in the key or on the
DynamoDB row.

Both of those exclusions are decisions rather than accidents. **Not the row**,
because the game's `UpdateItem` on `ringmaster-incidents` is scoped to an
attribute allowlist that holds the match timeline and its counters and nothing
else — there is no per-frame attribute it is permitted to write, so a case it has
already filed cannot grow a capture list. (One existed: `captureKeys` was written
`[]` at filing time, could never be added to by its only writer, and was deleted
outright.) **Not the key**, because a key carrying a timestamp is a key that
cannot be guessed, and the console holds `GetObject` with no `ListBucket` — a key
it cannot derive is a frame it cannot find. Metadata is what is left, and it costs
nothing: `s3:GetObject` covers `HEAD` as well as `GET`, so the capture time
arrives on the same request that fetches the image.

**The subject is told nothing, at any point.** Same rule as the rest of the
pipeline: no notice, no hint, no sound. A player who learns they are under
suspicion changes behaviour, which costs the case the evidence it was made of.

### `screenshot-basic` is not vendored, unlike pma-voice

pma-voice lives in this repository at `resources/[voice]/pma-voice` because three
player-facing faults were unfixable from outside it, and a third-party resource
we cannot patch is a resource we cannot fix. The same argument was weighed here
and comes out the other way, for reasons that are about this particular resource
rather than about the principle:

* **It cannot be vendored the way pma-voice was.** pma-voice ships runnable Lua,
  so `VENDOR.json` can assert that every byte outside a marked patch is
  byte-identical to an upstream tag. `screenshot-basic` ships TypeScript with a
  `package.json` and `webpack_config` lines, and **has no built output in the
  repository at all** — FXServer builds it on the box with its own Node 16 and
  yarn toolchain. Vendoring it would mean either shipping that toolchain
  dependency (which `DEPLOY.md` documents as the thing that already took a
  resource down once) or committing a build we produced ourselves, which
  destroys the provenance property the vendoring gate exists to assert.
* **Nothing in it needs patching for us.** The faults that justified vendoring
  pma-voice were player-facing and unavoidable. This resource is called once per
  frame from server code, is never touched by a player, and its one real defect —
  it holds an upload token open forever, so a callback for a client that never
  answers is never fired — is worked around cleanly from our side with a timeout
  and a swept spool directory.

So it is **installed, not vendored**, and the standing rule applies with full
force: *do not assume it is installed*. `br_core/server/artifacts.lua` checks
`GetResourceState` before every capture, opens no case state when it is absent,
and produces no log line at all — a server without it files incidents exactly as
before, carrying no frames.

## A case has two states, and a verdict is final

`pending_review` and `resolved`. There is no third state, **a resolved case
cannot be re-opened, and a verdict cannot be changed after the fact.** The
console writes the state and the verdict in one conditional update that refuses
to run twice, so there is no window in which a resolved row is still waiting for
its decision to arrive.

That is what lets the game read a case with a single question and no polling
subtlety: `state === 'resolved'` means finished, whatever else is or is not on
the row. It is also why a resolved row carrying **no verdict at all** has to be
its own answer rather than being folded into "no action taken" — a row that
predates the field, or one the system auto-resolved, records that nobody decided
anything, and reporting it as a decision would be a claim about a human who never
looked.

**A ban issued from a case is an ordinary ban.** It is a standard audit action,
recorded in `ringmaster-audit` like any other admin action, and the row it writes
to `ringmaster-bans` is the one in [the ban contract](ban-contract.md) with no
extra field. There is no separate enforcement pathway that skips the audit log —
which matters here, because the whole reason the game does not decide what
happens to a player is that the console is the side with the ban list, the audit
log and a human.

## Players filing cases, and why the panel gives them so little

A report opens or corroborates a case on the same table the anticheat writes to.
The limits are in `BR.Config.Report` and there are three of them at once:

| limit | value | what it bounds |
|---|---|---|
| `maxTargets` | 5 | players nameable in one submission |
| `maxPerMatch` | 3 | submissions per player per match |
| one per target per match | — | how many times one accusation can be made to count twice |

Those are deliberately not the same rule. Three submissions of five distinct
targets is fifteen reports and is fine; two submissions naming the same person is
one report and the second is refused. The first bounds how often a player can
make the server write to a database, the second bounds how often one accusation
can be double-counted.

- **A submission naming somebody already reported is refused whole**, not partly
  filed. A partial file has no honest answer — "3 reports sent" is true and hides
  the refusal — and the panel keeps the selection on a refusal, so an explicit
  "you have already reported X" leaves the player one untick away from sending
  the rest. It does **not** cost them a submission; hitting the rate limit does,
  because hammering the limit is itself a signal worth keeping.
- **There is no free-text box.** The dropdown reason is the whole report. A note
  field existed through a page, a callback, a net event and an incident payload,
  and `br_ddb` had been writing `note: null` unconditionally the whole time.
- **The reporter is never told whether a case already existed.** "Your report was
  added to an existing case" would leak that the person they just named is under
  review, which is precisely what an offender's friend would go looking for.
- **A report with no license is refused.** An unattributable accusation is worth
  less than none: the console's "who reports everybody" signal depends on knowing
  who filed it.

**"Suspect cheating? Press TAB to report &lt;name&gt;" carries no subject on the
wire, and neither does pressing it.** `BR.Net.REPORT_KILLED` and
`BR.Net.REPORT_CORROBORATE` both take **no payload at all**. The server resolves
the asker's own killer from the roster and the damage records it already keeps —
the same attribution the kill feed uses — and answers about that player or
answers nothing. The obvious shape, "is player 14 under suspicion?", is a probe:
a modified client would walk the roster and read back exactly the list this
feature must never produce. Rate-limiting a probe does not stop it, it slows it.
**The guard is the absence of a parameter, not a check on one.**

It requires state DEAD — being knocked down is not being killed — a killer the
server itself attributed, and a case open on that killer. What a player can still
learn is one bit about one player they were already looking at, and only after
being killed by them. The subject learns nothing, here or anywhere.

**Widening the lookup did not widen the question (#177).** The prompt now fires
for a case open against the killer in *any* match rather than only the current
one, which is a larger set of cases and the same single bit about the same single
player. The map it reads (`BR.Incident.openFor`) is license-keyed, lives entirely
server-side, and is reached only by that resolver — there is no verb anywhere
that accepts a license from a client, and br_ddb still has no Query or Scan, so
nothing on the box can enumerate cases at all.

**…but it did widen what the keypress spent, and that had to be split back
apart.** Answering the prompt records itself in `usage.corroborated`, which is
what makes it one action per offender per match. It also spends `usage.named` —
the set the *panel* refuses on — but **only when the case it answered belongs to
this match**. Both writes happened unconditionally until 2026-08-18, so a case
filed in one round and corroborated from the prompt in the next spent the *next*
round's panel allowance: the reporter was told "you have already reported X in
this match" about a match in which they had reported nobody, and that round's own
cheating opened no case. Filing policy is per match on purpose — three rounds of
cheating are three things worth telling an admin about — and a prompt that reads
across matches must not repeal it by the back door.

**Both halves are decided by one function.** `corroborationFor` in
`br_core/server/players.lua` decides whether the prompt is shown *and* whether
the keypress does anything. A client that skips the prompt and sends
`REPORT_CORROBORATE` on its own gets exactly what an honest one would: nothing,
unless it was genuinely owed. The failed paths answer **silently** rather than
explaining themselves — "they have no case" and "you already named them" are
facts about somebody else's standing, and an endpoint that distinguished them
would be the oracle the payload-free design exists to prevent.

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

