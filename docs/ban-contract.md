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
`br_ddb` exposes exactly two read verbs and deliberately has no general-purpose
query primitive: a generic DynamoDB bridge inside the game server is one
careless commit away from a write path into the tables that decide who is banned
and who is an admin.

The game server has **no access at all** to `ringmaster-audit`. The audit log is
the record of what admins did, and a compromised game host must not be able to
read — still less rewrite — the account of its own compromise.
