# The ban contract

Two codebases decide whether somebody is banned, and they must never disagree.

- **Ringmaster** (`fivem-ringmaster`, `src/lib/bans.ts`) writes the row and shows
  the admin what it means.
- **The game server** (`js-src/br_ddb/src/ban.js`) reads the row at connect and
  decides whether the player gets in.

They are separate implementations in different languages, in different repos, on
different machines. That is not an accident to be cleaned up later: the game box
cannot install dependencies, so a shared package is not available to it, and
routing the check through Ringmaster would make every player's connection depend
on the admin console being awake. Duplicating a dozen lines is the cheaper
mistake.

**This file is the contract.** If the rule changes, all three change together:
this document, `lib/bans.ts`, and `ban.js` — each of the two implementations has
tests over the same case table.

## The row

Stored in DynamoDB table `ringmaster-bans`, partition key `license` (String),
no sort key.

| Field | Type | Meaning |
|---|---|---|
| `license` | String | The qualified license, e.g. `license:abc123…`. The only identifier bans key on. |
| `at` | Number | When the ban was issued (epoch ms). |
| `by` / `byName` | String / String | The admin's license and display name at the time. |
| `reason` | String | Why. **Shown to the player at connect**, so it is written for them. |
| `expiresAt` | Number \| null | Absolute expiry (epoch ms), or `null` for permanent. |
| `playerName` | String \| null | Their name when banned, for the console's list. |
| `liftedAt` | Number \| null | Set when lifted. **Its presence is the lifted state.** |
| `liftedBy` / `liftedByName` / `liftReason` | | Who lifted it and why. |

### Why an absolute expiry rather than a duration

A duration would have to be re-evaluated against a moving "now" by every reader,
and the game host and the console do not share a clock. One number, one meaning,
no arithmetic at the edges.

### Why lifting keeps the row

The question asked six months later is *"has this person been banned before, and
who let them back in"*. A table that deletes on lift cannot answer it at all. It
also means an accidental lift is visible and recoverable rather than silent.

## The rule

```
isActive(ban, now):
    no row              -> not banned
    liftedAt set        -> not banned      (lifted beats everything)
    expiresAt <= now    -> not banned      (served)
    otherwise           -> BANNED
```

Case table — both implementations test exactly these:

| Case | Active? |
|---|---|
| No row at all | no |
| Permanent (`expiresAt: null`), never lifted | **yes** |
| `expiresAt` absent entirely (not null) | **yes** |
| Temporary, expiry in the future | **yes** |
| Temporary, expiry in the past | no |
| Expiry exactly equal to `now` | no (served) |
| Lifted, expiry still in the future | no |
| Lifted, permanent | no |
| `liftedAt` absent rather than null | **yes** |

The last two rows are the ones that bite. **Absent is not null**, and a field
DynamoDB omits arrives as `undefined` — the same class of bug that produced the
ingest schema's 400s, where Lua omitted nil keys and a `.nullable()` schema
rejected `undefined`.

## Failure is open, on purpose

If the game server cannot reach DynamoDB — no credentials, no route, a throttle,
a timeout, a malformed row — the ban check answers **not banned** and logs the
error loudly.

A database that cannot be reached must not become a server nobody can join. The
failure mode of *"a banned player gets in until the link recovers"* is strictly
better than *"nobody gets in at all"*, and the second is the one that ends a
game night. The connect gate carries its own timeout for the same reason: a
deferral that never resolves strands the player on a connecting screen forever,
which is worse than any ban decision either way.

## What the game server may do with this table

`GetItem` on `ringmaster-bans`, and nothing else — no `Query`, no `Scan`, no
writes. The only question it ever asks is about one specific license, at connect.
`br_ddb` deliberately has no general-purpose query primitive: a generic DynamoDB
bridge inside the game server is one careless commit away from a write path into
the tables that decide who is banned and who is an admin. Adding a verb is meant
to feel like a decision.

**There is no `Query` and no `Scan` anywhere in `br_ddb`** — not in one verb, not
in a helper, not on the game's own tables. Every read in the file is a `GetItem`
on a key the game already holds. That is the property the paragraph above is
really about, and it is worth stating as a property because it is greppable:
nothing here can ever *enumerate*. The reward queue is even shaped around it —
one item holding the whole queue, rather than one item per incident, precisely so
that finding them again is a `GetItem` rather than a `Query`.

**The split that matters is not read-versus-write, it is whose table.** `br_ddb`
now exposes nineteen verbs, and several of them write:

| table family | verbs | access |
|---|---|---|
| `ringmaster-bans`, `ringmaster-grants`, `ringmaster-maintenance` | `banCheck`, `grantsFetch`, `maintenance` | **read-only**, one key at a time |
| `ringmaster-incidents` | `putIncident`, `incidentClose`, `incidentVerdict` | file a case, close its match timeline, read four attributes back |
| `ringmaster-audit` | — | no code path (but see the grant note below) |
| `br-players` — profiles, inventory, history rows and the reward queue all live on it | `profileFetch`, `statsApply`, `historyPut`, `inventoryFetch`, `purchase`, `equip`, `awardClaim`, `awardQueue`, `awardPay`, `awardSettle` | read and write freely |
| `royale-incidents-bucket` (S3, not DynamoDB) | `artifactBegin`, `artifactPut` | `PutObject` under `incidents/` and nothing else |
| — | `selftest` | reads a license that will never exist |

The two S3 verbs live in `br_ddb` because what reaches AWS is the **EC2 instance
role** the SDK's provider chain finds through IMDS, not the DynamoDB client — a
second resource holding a second copy of the SDK would be a second bundle to keep
current and a second place to audit. They are still two named verbs and not a file
bridge: nothing takes a path, a bucket, a key or a body. The game passes an
incident id, a frame number and an encoding, and every name is derived and
validated on the JS side.

Both prefixes are convars (`br_ddb_table_prefix`, default `ringmaster-`;
`br_ddb_game_prefix`, default `br-`), so the names above are the defaults rather
than constants.

Everything touching `ringmaster-*` is the console's data and the game server only
ever asks it questions about a key it already has. Everything touching `br-*` is
the game's own, so that a match never fails because a web console in another
region is down.

### The deliberate exceptions on `ringmaster-incidents`

**Writing (2026-08-14).** The game may **file** a case. The alternative was
sending incidents to the console over the event channel and letting it write, but
that channel drops batches silently after four attempts and an incident lost that
way is unrecoverable — the evidence buffer behind it is discarded at match end.
So the game writes the row and the event carries only an id. The write is
conditional on the id not already existing, so a repeat can only be refused.

**Updating (`incidentClose`).** The game may also write to a case it has already
filed, which is the exception this document did not have and now needs. When the
match ends, one `UpdateItem` per incident filed in it attaches the match timeline
and its counters. **It is bounded by an IAM attribute allowlist rather than by
being a different verb**, which is the distinction worth carrying:

```
dynamodb:Attributes  incidentId, matchEndedAt, matchTimeline,
                     matchTimelineComplete, matchKillsSeen
dynamodb:ReturnValues NONE
```

`events` — the console's own timeline, where an admin's notes, the corroborations
and the resolution live — is outside it, and so are `state`, `verdict`,
`resolvedAt`, `resolvedBy*`, `resolution` and `closedByBan`. So the game adds
match facts to a case and **cannot express an opinion about one**. `ReturnValues:
NONE` closes the other half: an attribute allowlist restricts what an update may
*write*, and `ReturnValues` is how the same request could still read the rest of
the row back.

An `UpdateItem` was chosen over a second row per closure — which the existing
`PutItem` grant would already have permitted — because the console `scanAll`s this
table and reads every row as an incident, with no discriminator. A phantom entry
in a moderation queue is a worse failure than a narrow, attribute-scoped update.
The write is conditional on `attribute_exists(incidentId)`, so a close for a case
whose `PutItem` was lost fails rather than creating a bare row naming nobody.

**Reading (2026-08-17, #168).** `incidentVerdict` reads a case back. This
document said "cannot read one back" until report rewards shipped, and the
sentence is corrected rather than quietly dropped, because it was load-bearing in
an argument. What the read actually is:

- **`GetItem`, by an id the game minted itself.** Every id this verb is called
  with came back from `putIncident` on this same box, so "read back cases whose
  ids it knows" means "read back its own". It cannot discover an id it did not
  file.
- **A projection, not the row.** `ProjectionExpression` asks for exactly four
  attributes: `incidentId`, `state`, `verdict`, `resolvedAt`. The evidence, the
  chat log, the kill log, the match timeline, the reporter, the subject and the
  admin's written resolution are all on that item and **none** of them crosses
  into the game server.
- **Eventually consistent, and fails closed.** An unreadable case answers "not
  settled" and is asked about again on the next sweep — the opposite of the ban
  check, which fails open. Paying a reward against a verdict nobody has seen is
  worse than paying it ten minutes late.

**What that cost, stated plainly:** the property "there is no read of any kind on
this table" is gone, and so is the claim that a compromised game box "cannot see
a verdict". It still cannot **alter** one.

What a compromised game box can do here: **file noise**, attach match facts to a
case it filed, and learn whether that case was decided and whether anything
happened. What it still cannot do: enumerate anything on any table (no `Query`,
no `Scan`), read a moderator's prose, confirm an identity it did not already
hold, overwrite an existing incident, or alter a verdict.

### The read grant is broader than the code, and this document used to say otherwise

> **This section ended: "The game server has no access at all to
> `ringmaster-audit`… a compromised game host must not be able to read — still
> less rewrite — the account of its own compromise."** The *rewrite* half is
> still true and is the important half. The *read* half is not, and has not been
> since 2026-08-17.

On that date the owner widened the game box's read to `dynamodb:GetItem` on the
whole `ringmaster-*` prefix — *"this is deliberately broad, I know"* — which
covers `audit`, `bans`, `grants`, `incidents`, `sessions`, `telemetry` and
`to-gameserver`. **Nothing in `br_ddb` reads six of those seven**, and the file
names each table it does read exactly once, which is what makes the following
list the answer when somebody comes to narrow the policy back to a list of ARNs:

```
ringmaster-bans         GetItem                            the connect gate
ringmaster-grants       GetItem                            in-game admin scopes
ringmaster-maintenance  GetItem                            the drain gate
ringmaster-incidents    GetItem + PutItem + UpdateItem     cases
```

So "one key at a time, about a license already in front of it" describes the
**code** and no longer describes the **policy**. It is stated as the gap it is,
because a policy nobody can summarise is a policy nobody can narrow — and because
a contract document that understates a grant is the one that gets quoted in an
argument it should have lost. No write grant of any kind exists on `ringmaster-`
`audit`, `bans` or `grants`, and the one write on `incidents` is the
attribute-scoped close above.
