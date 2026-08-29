# Working agreement

How work gets done here. Written 2026-08-28, after the CPR kit (#191) took six
playtest rounds — most of them avoidable.

Every playtest round costs the owner about twenty minutes and he is the only
person who can run one. **The whole of this document is about spending those
rounds well.**

---

## 1. Ask before building, not after

**A question round costs two minutes. A playtest round costs twenty.** Trade one
for the other every time.

Agents cannot reach the owner directly — they report to the coordinator, who
batches questions and relays answers. So the shape is:

> surface the decisions → coordinator batches them → owner answers once → build

**Ask when:**

- The decision is the owner's taste, not a technical fact — feel, wording,
  numbers arrived at by eye, what a feature *is*.
- Guessing wrong costs a playtest round.
- Two readings of a request lead to materially different work.
- The request contradicts something he said earlier. He reverses decisions
  deliberately and often; say so and let him confirm which one stands.

**Do not ask when:**

- The answer is in the code, the docs, or an issue. Go and read it.
- There is an obvious default and being wrong is cheap to undo.
- It is a mechanical choice with no user-visible consequence.

A brief that asks about everything is worse than one that asks about nothing —
it moves the work back onto the one person who has least time.

**Surface the question early.** A decision raised in the final report has
already cost the build it was needed for.

---

## 2. Instrument before theorising

When something fails and the cause is not visible, **the first move is a
diagnostic that names which condition failed** — not a theory, and not a fix.

This is settled by evidence, not preference:

- `/brcpr` found in one run what three rounds of reading source had missed.
- `/brammo` gave the owner a two-line proof of an ammo dupe that had survived
  five fixes.
- `/brarc`, `/brboostwhy` and `spawnOwned`'s creation print each ended a cycle
  the same way.

The pattern to recognise: **N conditions that all fail identically from the
outside.** No error, no print, no visible difference. Reading cannot distinguish
them and neither can guessing. Make the code say which one it took.

A round spent shipping a diagnostic is not a wasted round. It is the round that
makes the next one conclusive.

---

## 3. Grep before declaring a limit

Before writing "there is no native for this", "the platform cannot do that", or
"this is not possible here" — **search this repository.**

Three times in one day an agent declared something impossible that the codebase
already does:

- "No native draws a line on the pause map." `br_core/client/bus.lua` draws the
  Battle Bus route with `StartGpsCustomRoute` / `AddPointToGpsCustomRoute` /
  `SetGpsCustomRouteRender` — straight segments over open water, no pathfinding.
- A vehicle-spawning helper was written, left unused, and a second agent hit the
  same wall it existed to solve.
- A config table was searched for under a guessed name while the real one sat
  beside it.

If this gamemode ships a feature that does the thing, the answer is in-tree.

---

## 4. A test must fail against the unfixed code

**Demonstrate it.** Revert the fix, watch the test go red, restore it, say so in
the report.

Two bugs shipped through fully green suites because the fixture was written from
the same misreading as the code:

- `slots[1] = { item = 'cprkit' }` — 74 passing cases against code that reads
  `.id`. The stub agreed with the bug.
- An ambulance-points test injected the table name the reader had guessed, so
  the fixture *was* the writer and hid that the real table was called something
  else.

A stub shaped like the bug agrees with the bug. A green suite proves nothing
until one of its cases has been seen to fail.

---

## 5. Platform facts get a source

The widely-copied answer for this engine is wrong often enough to plan around.
In one day:

- Two published versions of the dispatch-service enum disagreed with the game's
  own parser definition; following the popular one disables SWAT and leaves the
  fire brigade running.
- `65534` looked like a sentinel and is the first id a OneSync server allocates.
- `citizenfx/fivem#4006` was recorded as fixed in four separate repo comments.
  It is still open.

So: **cite what you read, name where sources disagree, and write "unverified"
rather than filling a gap.** A confident wrong answer costs a playtest round.

---

## 6. Batch the fixes, not the rounds

Fix everything findable statically. Add a diagnostic for everything that is not.
**Then** hand over one build.

One fix per round is the expensive shape, and it is how six rounds happened: each
fix was real, each revealed the next fault, and each cost a full round to learn
that.

---

## 7. House rules that keep biting

- **`0` is truthy in Lua, and FiveM BOOL natives may answer `1`/`0`.** Nine
  shipped instances. `tools/verify.sh` has a `bool natives` gate with a
  baseline — and it caught the coordinator writing the ninth while committing a
  note about the eighth. Its blind spot is natives whose names are not questions
  (`CreateVehicle`, `GetGroundZFor_3dCoord`), which is where the last two lived.
- **No unsolicited UI text.** No helper copy, no hints, no empty-state prose. If
  the owner gave wording, use it verbatim.
- **Everything lives on `dev`.** `tools/dispatch.sh` is the one exception and
  needs a PR to `main`, enforced by the deploy guard.
- **Commit by explicit pathspec.** Several agents run concurrently; a bare
  `git commit` has taken five files belonging to someone else.
