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
inbound HTTP surface on the game box at all — commands, when they exist, arrive
over SSH instead (see PLAN.md, M9).

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
        "action": "log"
      }
    }
  ]
}
```

`seq` is monotonic **within a `bootEpoch`** and starts at 1. `at` is
`GetGameTimer()` — convert it with the formula above.

### Event kinds in Slice 1

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
Fires once per window at `refusalLimit` (8) countable refusals inside
`refusalWindowMs` (10000). `action` still means what it always meant — what the
server actually did — and what it does now is file an incident, so the value is
the constant `incident`.

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

---

## Versioning

Bump `v` when a field is removed or its meaning changes. Adding an optional
field does not need a bump — the receiver ignores what it does not know, and
must not fail on it.

The receiver rejects an envelope whose `v` it does not recognise, with a
non-2xx, which the sender treats as a `nack`. That is the correct outcome: a
console that cannot understand the server should say so loudly rather than
display a confidently wrong player list.
