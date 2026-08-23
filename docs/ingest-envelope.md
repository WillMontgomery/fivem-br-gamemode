# The ingest envelope

*What `br_ringmaster` sends to Ringmaster, and what Ringmaster promises back.*

[← Back to the main README](../README.md)

This is the only contract between the two repos. It is written down, versioned,
and pinned by committed fixtures in `tools/fixtures/` that **both** sides test
against — so the game half and the console half can each be built and verified
with the other one absent. That decoupling is the point: neither side is
deployed yet, and neither should have to be.

The fixtures are mirrored byte-identical into
`fivem-ringmaster/src/lib/__fixtures__/`. If you change one, change both, or
the two halves start disagreeing about a shape neither of them is testing.

---

## Direction

**Outbound only. FXServer never listens.** The game host opens a connection to
Ringmaster's ingest endpoint over the VPC peering link and pushes. There is no
inbound HTTP surface on the game box at all — commands arrive over SSH instead,
through `tools/dispatch.sh`'s pinned verb set (see
[branch-switch.md](branch-switch.md)).

```
br_ringmaster  ──HTTP POST──▶  https://ringmaster/api/ingest
```

## Transport

`POST`, `Content-Type: application/json`, one envelope per request.

| Header | Value |
|---|---|
| `X-Ringmaster-Secret` | the shared secret, compared in constant time |

**The endpoint must answer fast.** `PerformHttpRequest` has a **hardcoded 5
second no-response timeout** and it is not configurable — so the endpoint
validates, acknowledges, and processes asynchronously. Nothing slow happens
before the response. A 5-second stall on the console side becomes a stalled
outbox on the game side.

| Response | Meaning to the sender |
|---|---|
| `2xx` | delivered — `ack` |
| anything else, or no response | not delivered — `nack` |

Failure is **non-fatal and never retried into a stall**. Same rule as
everything else that leaves the match loop: Ringmaster being down is not an
outage of the game.

---

## Two channels, and why they are not one

`br_ringmaster` sends two kinds of envelope, and the distinction is
load-bearing rather than organisational.

| | `snapshot` | `events` |
|---|---|---|
| What it is | current state | things that happened |
| Semantics | **latest wins** | **every one matters** |
| On failure | dropped; the next one is better anyway | retried with backoff |
| Ordering | irrelevant — newest is truth | preserved |
| Backing | a single slot, overwritten in place | `BR.Outbox` |

Running snapshots through `BR.Outbox` would be a category error. The outbox is
an ordered FIFO with retry: a failed snapshot batch would be re-sent *ahead of*
the current one, putting a four-second-old player list on the wire in front of
a fresh one. And its drop-oldest overflow policy is right for a player list and
exactly wrong for an anticheat firing — the one dropped because the queue
filled is the one you needed.

---

## Common shape

Every envelope carries the same `server` block.

```json
{
  "v": 1,
  "kind": "snapshot",
  "server": {
    "bootEpoch": "1754784000-4281003-55f0a1b2c3d4",
    "resource": "br_ringmaster",
    "wallMs": 1754784000000,
    "gameMs": 4281003
  }
}
```

**`v`** — envelope version. The receiver rejects an unknown version rather than
guessing at it.

**`bootEpoch`** — unique per *resource start*. This is not decoration:
`BR.Outbox` restarts its `seq` counter at 0 in `new()`, and `tools/deploy.sh`
tells you to restart resources after every deploy. A receiver deduping on `seq`
alone would silently discard the first N events after every single deploy, as
duplicates of events from the previous run. **Dedupe on `(bootEpoch, seq)`.**

**`wallMs` and `gameMs`** — the clock pair, sampled together, and the reason
anything here is datable at all. Every timestamp this project produces is
`GetGameTimer()`: milliseconds since *server start*. Inside the game that is
correct and deliberate. Off the box it is meaningless — an audit row stamped
`4281003` is not a timestamp. So the envelope carries one wall-clock reading
alongside the game-clock reading taken at the same instant, and the receiver
converts every per-event time:

```
realMs = server.wallMs + (event.at - server.gameMs)
```

Sampling them together is the contract. Two separate calls later would drift.

---

## `kind: "snapshot"`

Sent on a timer (`br_ringmaster_push_ms`, default 2000). Latest wins; if one
fails to deliver it is dropped, because the next one is two seconds away and
strictly better.

See [`tools/fixtures/ingest-snapshot.json`](../tools/fixtures/ingest-snapshot.json).

```json
{
  "v": 1,
  "kind": "snapshot",
  "server": { "...": "as above" },
  "snapshot": {
    "takenGameMs": 4281003,
    "counts": { "connected": 3, "inMatch": 2 },
    "truncated": false,
    "matches": [
      {
        "id": 41,
        "state": "STORM",
        "mode": "squads",
        "bucket": 141,
        "endsAt": 4400000,
        "alive": 2,
        "squadsAlive": 1
      }
    ],
    "players": [
      {
        "src": 3,
        "name": "Tester",
        "license": "license:110000112345678",
        "matchId": 41,
        "squadId": 7,
        "state": "ALIVE",
        "hp": 87,
        "armour": 0,
        "kills": 2,
        "downs": 0,
        "revives": 0,
        "damage": 314,
        "placement": null,
        "pos": { "x": 1234.5, "y": -567.8, "z": 78.9 },
        "posAt": 4280500,
        "bucket": 141,
        "connectedAt": 4100000
      }
    ]
  }
}
```

**`connectedAt`** — when they connected, as a **game-clock reading**, mapping to
the roster's existing `joinedAt`. Deliberately not a duration: a duration is
stale the instant it arrives and ticks *backwards* whenever a push is late,
where an origin lets the console compute "connected for 41m" continuously
against its own clock. Convert with the same formula as every other timestamp.
This field exists because the console's player table wanted a "time connected"
column — the first instance of the UI driving the wire contract, which is the
direction the fixtures were built to make cheap.

**`takenGameMs`** lets the receiver drop an out-of-order snapshot. Under retry
this could not happen, but snapshots are not retried and the network is still
the network.

**`players` carries fields the game deliberately never broadcasts to clients** —
`license`, `pos`, `matchId`. `br_core`'s roster has a `PUBLIC_FIELDS` allowlist
that withholds exactly these, because broadcasting live positions to every
client hands a wallhack to anyone reading the event stream. Ringmaster is a
legitimate exception: this is server-to-server, over a private link, to a box
that already holds the ban list. It gets its **own second allowlist**,
`RINGMASTER_FIELDS`, sitting directly beneath `PUBLIC_FIELDS` in `roster.lua` so
that adding a roster field forces a decision about both audiences at once.

**`truncated`** — the honest flag. The snapshot is a **full player list with no
delta encoding**, which is fine at the current `sv_maxclients 48` and will not
be at the 2048 M9 exists to enable: 2048 rows with a position and a license
each, twice a second, cross-region, is megabytes per second. When the list is
capped, this says so rather than quietly showing a short list that looks
complete. The delta story is a later problem; pretending it is not a problem is
not.

**`placement`** is `null` until the player is out. `nil` does not survive
serialisation in either direction, so absent-versus-null is not a distinction
this wire can carry — the field is always present.

### `snapshot.ddb` — can this box reach DynamoDB?

**Optional, and absent is the normal case.** It is not in
`tools/fixtures/ingest-snapshot.json` for that reason: the fixture pins the
required shape, and this field's absence is a state the receiver must handle
anyway.

```json
"ddb": {
  "ok": true,
  "at": 4281003,
  "error": null,
  "region": "us-east-1",
  "prefix": "ringmaster-",
  "ms": 42
}
```

**Why it rides the push.** `br:ddb:selftest` is a real `GetItem` issued by the
running `br_ddb` with its own region, prefix and credentials — the probe `brddb`
prints. **Only something inside FXServer can ask it.** A shell probe from
`tools/dispatch.sh` would answer whether the *machine* has a route, which is one
of the three ways this breaks and reports healthy for the other two: no IAM
grant, and a wrong region. So the verdict travels on the channel the game
already owns, and the console's SSH verb set is untouched.

**`at` is the probe's clock, not the push's,** and that is the whole reason it
is on the wire. `br_ringmaster` does **not** round-trip to DynamoDB on every
push — that would be a network call every two seconds to answer a question that
changes when somebody edits an IAM policy. It probes on its own cadence and
resends the cached verdict, so the receiver dates the **probe**. Convert it like
every other timestamp; the console expires a reading at five minutes and reads
anything older as *unknown*.

**The cadence is a minute, with a faster retry while there is nothing at all to
report** (`server/ddb.lua`). Four beats inside that five-minute ceiling, so one
skipped probe never flaps the reading to unknown.

**Absent is never a failure.** `br_ddb` not started, no probe answered yet, a
probe that was never replied to — all of them leave the key off the snapshot
entirely, and the receiver must read that as *not told*. Nothing on the game
side invents a verdict in either direction: a false green hides a ban gate
failing open, and a false red fires on every routine `restart br_ddb`, which
`tools/deploy.sh` tells you to run after every deploy.

**Bounded at the sender.** `error` ≤ 512, `region` ≤ 64, `prefix` ≤ 128, because
those are the receiver's caps and an over-long AWS error message would fail the
whole envelope — taking the player list down to report a database.

### The other half of the same question lives on `status`, not here

Reachability is one of **two** `br_ddb` facts, and the second one is not on this
wire at all. *Is the box running a `dist/server.js` that is the file its own
`dist/fingerprint.json` describes?* is answered off the filesystem, so it rides
`tools/dispatch.sh`'s existing `status` verb as an optional `bundle` object:

```json
"bundle": {
  "manifest": { "scheme": "…", "source": "…", "bundle": "…", "bundleBytes": 713416, "files": 8 },
  "onDisk": "<sha256 of the deployed dist/server.js>"
}
```

Both halves are independently nullable and **absence is never a mismatch** — a
missing manifest, a missing bundle and a box with no `sha256sum` are three
different absences. The dispatcher compares nothing; it reports two readings.

**What a match means, and the three things it does not.** The box has the bundle
and the manifest and **no source tree**, so the only comparison available there
is the file against the hash recorded beside it. It catches an rsync that did
not finish or a hand-patched bundle. It does **not** prove the bundle was
rebuilt from current source — that is the manifest's `source` half, it needs
`js-src/br_ddb`, and `tools/verify.sh` checks it before a commit ever lands. It
does not prove the bundle is *correct*; nothing reads a line of it. And it is
**not tamper detection**: the manifest sits in the same directory as the bundle,
writable by whoever can write the bundle. It is a mistake detector, the realistic
mistake is a deploy that did not finish, and it must not be described as a
security property anywhere.

**No ninth verb.** This widens a read-only verb's *response*, not the verb set —
which is the console's actual capability boundary and is pinned by name in
`tools/verify.sh`.

---

## `kind: "events"`

A batch from `BR.Outbox`. Ordered, retried with backoff, and every entry
matters.

See [`tools/fixtures/ingest-events.json`](../tools/fixtures/ingest-events.json).

```json
{
  "v": 1,
  "kind": "events",
  "server": { "...": "as above" },
  "events": [
    {
      "seq": 41,
      "kind": "player_seen",
      "at": 4275000,
      "data": {
        "license": "license:110000112345678",
        "name": "Tester",
        "identifiers": {
          "discord": "998877665544332211",
          "steam": "110000100000000"
        }
      }
    },
    {
      "seq": 42,
      "kind": "refusal",
      "at": 4280003,
      "data": {
        "license": "license:110000112345678",
        "src": 3,
        "name": "Tester",
        "matchId": 41,
        "count": 8,
        "windowMs": 10000,
        "reason": "TOO_FAR",
        "action": "incident"
      }
    }
  ]
}
```

`seq` is monotonic **within a `bootEpoch`** and starts at 1. `at` is
`GetGameTimer()` — convert it with the formula above.

### Event kinds

**Seven kinds cross this wire and no others**: `player_seen`, `player_left`,
`refusal`, `incident_filed`, `incident_corroborated`, `outcome` and
`admin_spectate`. Nothing the incident, artifact or weapon-strip work added is a
new kind — artifacts never touch this channel at all (frames go straight to S3,
and the case row is written by `br_ddb`), and strips reuse `incident_filed` and
`incident_corroborated`.

> **This paragraph said "four kinds" until 2026-08-21 and had been wrong for two
> slices.** `player_left` shipped with session playtime and `outcome` shipped
> with the kick, both of them real kinds on this channel with no line here — so
> the one sentence a console author would read to learn what to expect named
> less than half of it. `admin_spectate` is the first addition made with this
> list, and correcting the count was part of adding it.

**`player_seen`** — emitted once per connect, carrying the allowlisted
identifiers. This is how a Discord id ever becomes associated with a license,
and therefore how anybody logs into Ringmaster at all.

**There is no `ip` here and there never will be.** `br_lib/shared/identity.lua`
keeps an explicit allowlist — `license`, `license2`, `discord`, `steam`,
`fivem`, `xbl`, `live` — rather than a denylist, so an identifier type FiveM
adds next year is excluded by construction rather than collected by default.
The cost is real and worth stating: evasion matching is weaker without an IP,
because every remaining identifier is one a determined evader can change. What
survives still catches the common case, and we never hold network-location data
on players.

**`refusal`** — the anticheat firing, mirrored from `BR.Damage.noteRefusal`.

**The trigger changed on 2026-08-14 and the event's cadence changed with it.** It
used to fire once per rolling 10s window at `refusalLimit` (8). It now fires when a
single reason crosses its own per-match bar — **1** for high-severity reasons, **2**
for normal ones and for `NO_WEAPON` — and then again only when the count *doubles*.
So a receiver should expect one event at the crossing and roughly `log2(n)` after it,
not one per refused shot: `count` climbing 1, 2, 4, 8, 16 across a match is the
normal shape for a persistent offender.

`action` still means what it always meant — what the server actually did — and what
it does now is file an incident, so the value is the constant `incident`.

Two added fields, so **no `v` bump**:

- **`severity`** — `low` / `normal` / `high`, the grade the game applied. Carried
  rather than left to be recomputed: two traversals of the same tally in two repos
  is two chances to disagree about which reason graded the case.
- **`seq`** — which report this is for this player in this match, from 1. `seq` 1
  opened a case; everything after it corroborates that case rather than filing
  another.

It stays on the wire while constant because the receiver's job is to record what
happened rather than infer it from a build number. **This is an added enum value,
not a removed field or a changed meaning, so it needs no `v` bump** — but the
receiver rejects values it does not know, so the console must be updated before
a game server that sends it. Deploy order is console first, game second; the
console keeps accepting `log` / `notify` / `kick` so an older game build still
reports cleanly.

Identity is on the **event**, not inferred from `src`. Server ids are recycled
within the minute; a moderation record keyed on one is a record about whoever
happens to be holding that slot later. `license` is resolved by
`BR.Damage.noteRefusal` at the moment it fires rather than left for the snapshot
path to fill, because a case that cannot be keyed to a player cannot be
reviewed — it is `null` only for a genuinely licenseless connection.

**`refusal` also now carries `reasons`** — a `{ [reason]: count }` tally of every
countable refusal in the window, not just the last one. An added optional field,
so no `v` bump. It exists because the firing reports once and a window is usually
a mix: without the tally, seven conjured-weapon shots followed by one self-hit
were classified by the self-hit and sorted to the bottom of the queue.

### `incident_filed` — the doorbell

Emitted by `br_ringmaster` **after** the incident row is durably in DynamoDB.

```json
{
  "seq": 43,
  "kind": "incident_filed",
  "at": 4281120,
  "data": {
    "incidentId": "0f9c…",
    "kind": "anticheat",
    "severity": "high",
    "subjectLicense": "license:abc…",
    "state": "pending_review"
  }
}
```

**`data.kind` is `anticheat` or `report`, and there is no third value** — but
there are **three producers**. Refused shots and **weapon strips** both file
`anticheat` with no reporter; the panel files `report`. The strip path
deliberately reuses the anticheat record shape rather than adding a kind, because
a receiver triages it identically and the console has two record types that
should not become three. The one visible difference on the row is that a
strip-filed case carries **no `refusal` block**: that block holds `count` and
`windowMs` from the shot validator, a strip has neither number, and inventing
them would dress up the finding. Its evidence is the match timeline instead.

**THE WRITE IS THE SOURCE OF TRUTH; THIS EVENT IS ONLY A DOORBELL.** That is the
load-bearing property of the whole incident pipeline and the reason the game
writes to DynamoDB itself rather than posting the case here.

This channel drops silently. `outbox.lua` gives a batch four attempts and then
discards it, the drop counters reach only the local `brring` command, and neither
envelope carries them — so the console genuinely cannot tell "thirty-two
refusals were dropped because the link was down" from "no refusals happened". An
incident lost that way would be unrecoverable, because the evidence buffer behind
it is discarded at match end.

So the payload here is deliberately minimal: an id, and enough to decide whether
to look now. **A receiver must never treat the absence of this event as the
absence of an incident.** The console's reconciliation sweep — a bounded query for
untriaged incidents, run on boot and on evidence of loss, never on a timer — is
what makes a lost doorbell cost a delay rather than a case.

`severity` is a triage hint (`low` / `normal` / `high`), not an instruction. The
game forms no opinion about what should happen to the player.

**Unknown kinds are safe.** `gameEvent.kind` is a bounded string and `data` is a
loose record, so a console that predates this event parses the envelope, applies
what it understands, and buffers the rest. Deploy order does not matter for this
one — unlike `refusal`'s `action`, which is an enum the schema validates.

### `incident_corroborated` — it is still happening

Emitted when a player who **already has a case this match** trips a bar again.

```json
{
  "seq": 44,
  "kind": "incident_corroborated",
  "at": 4283400,
  "data": {
    "incidentId": "0f9c…",
    "subjectLicense": "license:abc…",
    "seq": 2,
    "count": 4,
    "reason": "shooter does not hold that weapon",
    "severity": "high"
  }
}
```

**One case per player per match; everything after it lands here.** A second row
hands an admin the same conclusion twice and lets one persistent offender bury a
queue that is meant to be a strictly shrinking worklist. Appending to the case they
already have says the thing a second row cannot: it is still happening, and nobody
has acted.

**The receiver does the write, and that is the point.** Appending a corroboration is
an `UpdateItem` on `events` — the console's own half of the row, where an admin's
notes and the resolution also live — and `src/lib/incidents.ts`'s `note()` is
already exactly that write. Nothing the game holds can reach `events`.

> **This paragraph used to say the game's grant on that table is "append-only
> (`PutItem` conditional on the id being absent)". That has not been true since
> the match timeline shipped**, and it is corrected rather than quietly edited
> because it is the sentence a reader would quote to conclude the game cannot
> touch a row that already exists. It can: `incidentClose` is an `UpdateItem`
> scoped by an IAM **attribute allowlist** — `incidentId`, `matchEndedAt`,
> `matchTimeline`, `matchTimelineComplete`, `matchKillsSeen` — with
> `ReturnValues: NONE`. `events`, `state`, `verdict` and every `resolved*` field
> are outside it, so the conclusion still holds; the reason changed from "it is
> refused the verb" to "it is refused the attributes", which is a narrower and
> more checkable claim. [security.md](security.md) carries the full grant list.

**Unlike a case, this event is allowed to be lost.** That asymmetry is deliberate: a
corroboration is redundant by definition, and the case it attaches to is already
durable in DynamoDB. Losing one costs a number.

**`data.seq` is per player per match, and it is not the envelope's `seq`.** It starts
at 2, because report 1 opened the case. Its only job is to let a receiver tell 1, 2,
4 *with 3 missing* from a match where nothing more happened — this channel discards a
batch after four attempts and neither envelope says so. Treat a gap as "at least this
many", never as an exact count.

`count` is the running per-match total at the moment of the report, and **how it
climbs depends on which detector sent it**. From the refusal path it roughly doubles
between consecutive corroborations, because `damage.lua` reports at the doublings.
From the unissued-weapon path it climbs **by one** — `strip.lua` announces every
strip from the second onward (owner, 2026-08-20) — so consecutive values there are
2, 3, 4, 5 and a gap means a *lost* corroboration rather than offences that happened
quietly in between. Treat it as "at least this many" in both cases; never as an
exact count.

### `admin_spectate` — who watched whom (#192)

An admin spectate session opening or closing. Two events per session, joined by
`commandId`.

```json
{
  "seq": 91,
  "kind": "admin_spectate",
  "at": 4283400,
  "data": {
    "commandId": "5f2b…",
    "adminLicense": "license:abc…",
    "targetLicense": "license:def…",
    "targetName": "Nemesis",
    "phase": "stop",
    "reason": "target-left",
    "durationMs": 94210
  }
}
```

**`outcome` is not enough on its own, and that is the whole reason this kind
exists.** The console mints a `commandId`, writes an intent row, dispatches
`spectate`, and stamps the `outcome` onto that row — the same two-phase audit the
kick uses. What that covers is *did the button work*. What it cannot cover is the
**end**, because nothing asks for it: an admin stops from the in-game pause menu,
or the target disconnects and the session stops itself. Neither is a command, so
neither has an outcome, and a log with every start and no end is a log that says
every admin is still watching.

**`phase`** is `start` or `stop`. **`durationMs` is present on `stop` only** — a
duration rather than a second timestamp, because every clock the game produces is
`GetGameTimer()` and that is meaningless once it leaves the box (see the clock
pair, above).

**`reason` is present on `stop` only**, and it is a bounded string naming which
of the endings happened:

| `reason` | what happened |
|---|---|
| `stopped` | the admin used the pause-menu exit |
| `target-left` | the target disconnected, **or their server id was recycled** |
| `retargeted` | the admin pressed Spectate on somebody else |
| `gone` / `no-match` / `shutdown` | the session could not continue |

**`target-left` covers the recycled id deliberately.** FiveM reuses server ids
within the minute, so the game re-checks the target's license on every position
push and ends the session if it no longer matches — which is indistinguishable,
from the outside, from the target leaving, and means the same thing: the person
the row was opened about is no longer the person on the other end of the camera.

**A player spectating their own squad produces nothing here.** That is gameplay,
and a row for every death in every match would bury the rows that matter.

---

## Versioning

Bump `v` when a field is removed or its meaning changes. Adding an optional
field does not need a bump — the receiver ignores what it does not know, and
must not fail on it.

The receiver rejects an envelope whose `v` it does not recognise, with a
non-2xx, which the sender treats as a `nack`. That is the correct outcome: a
console that cannot understand the server should say so loudly rather than
display a confidently wrong player list.
