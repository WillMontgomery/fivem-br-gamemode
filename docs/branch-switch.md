# Branch switching from the console

Deploying a branch other than `main` to the live game host, from Ringmaster's
maintenance page, without a human on the box.

This document describes **what was built**. It replaces an earlier design that
the owner cut down before implementation; the parts that were cut are listed in
§7 so that "why is there no X" has an answer other than "somebody forgot".

---

## 1. The rule everything else hangs off

`deploy.sh` does this, and has always done this:

```sh
git -C "$SRC_DIR" reset --quiet --hard "origin/$BRANCH"
git -C "$SRC_DIR" clean --quiet -fd
```

`$SRC_DIR` is `/opt/fivem-server-classic/.gamemode-src` — the served clone.
`authorized_keys` pins Ringmaster's SSH key to a forced command:

```
command="/opt/fivem-server-classic/.gamemode-src/tools/dispatch.sh",no-pty ...
```

Those two facts sit badly together, and the reason is one line in
`tools/dispatch.sh`'s own header: **the dispatcher is a tracked file inside the
directory the deploy hard-resets.** It was moved there deliberately and moving
it there was right — it meant the dispatcher shipped with the game code instead
of needing a second manual `git pull` that nothing prompted you to do. The cost
of that decision was invisible while `main` was the only thing ever checked out.

Branch switching makes it visible. "Switch to branch X" and "replace the
console's only channel to the box with whatever X says that channel should be"
are, mechanically, the same operation.

**So: a ref is only deployable if `<sha>:tools/dispatch.sh` exists, is mode
100755, and its blob id is exactly equal to `origin/main:tools/dispatch.sh`'s
blob id.**

Blob ids, not diffs, not a checksum of our own — git already content-addresses
every file, so the whole rule is two `ls-tree` calls and a string compare.

It is enforced **twice**:

| Where | Function | When |
| --- | --- | --- |
| `tools/dispatch.sh` | `ref_blocked_by` | before `switchref` writes the pin |
| `tools/deploy.sh` | `assert_dispatch_invariant` | before anything touches the working tree |

**`deploy.sh`'s copy is the load-bearing one.** `dispatch.sh` lives in the
served clone — the tree a branch switch overwrites — so a hostile branch could
in principle ship a `dispatch.sh` with the check removed. `deploy.sh` lives in
the ops clone at `/opt/misc/fivem-br-gamemode`, which a branch switch never
touches (see `royale-deploy.service`'s `ExecStart`). Nothing a deployed branch
contains can edit, weaken or skip it. `dispatch.sh`'s copy exists to refuse
early and explain why, not to be the boundary.

What this buys: the feature stops being "run arbitrary code, including the
control channel" and becomes "swap the resource payload; the boundary is
invariant". The Lua under `resources/` is still arbitrary code from an
unreviewed branch — that is the entire point of the feature and is not in scope
to prevent. The channel that can *turn the feature off* is what is protected.

**The accepted cost: this feature cannot be used to test a change to `tools/`.**
Such a branch is listed, shown disabled with the reason, and refused at both
hops. Changes to `tools/` go through `main` and PR review, which is where
`verify.sh`'s gates run. That is the correct place for them, and the restriction
is a feature rather than a limitation to work around later.

**`feat/branch-switch` — the branch that introduced this — is itself ineligible
by its own rule**, because it changes `tools/dispatch.sh`. That is the intended
behaviour demonstrating itself.

### The gate that keeps this document true

`tools/verify.sh` has a `branch-switch invariant` check that reads the text of
both scripts and fails the build if:

- `deploy.sh` does not define `assert_dispatch_invariant`, or the function does
  not compare `tools/dispatch.sh` against `origin/main`;
- any non-comment `reset --hard` in `deploy.sh` appears with no
  `assert_dispatch_invariant` call on an earlier line;
- `dispatch.sh` does not define `ref_blocked_by`, or `do_switchref` reaches the
  line that renames the pin into place without calling it first.

It is structural rather than behavioural on purpose: exercising the real thing
needs two clones, a remote and a box, while asserting that the call is present
and *above* the reset needs none of that and catches the failure that actually
happens — the check being deleted or moved in a refactor, not the check being
wrong.

Both halves were verified to fail when the corresponding call is removed.

---

## 2. What is actually true of this repository

Re-run it yourself:

```bash
git fetch --prune origin && MAIN=$(git rev-parse origin/main:tools/dispatch.sh) && git for-each-ref --format='%(refname)' refs/remotes/origin/ | grep -v '/HEAD$' | while read -r r; do n=${r#refs/remotes/origin/}; blob=$(git rev-parse -q --verify "$r:tools/dispatch.sh" 2>/dev/null); [ "$blob" = "$MAIN" ] && s=SAME || s="${blob:+DIFFERS}"; printf '%-42s %-8s %s\n' "$n" "${s:-MISSING}" "$(git rev-list --left-right --count "origin/main...$r" | awk '{print $2" ahead / "$1" behind"}')"; done
```

Two corrections to the earlier draft of this document, both of which mattered:

**There is no remote branch called `origin`.** The earlier draft recorded one,
"at main's tip", and recommended deleting it. It does not exist and never did:
`git ls-remote --heads origin` has never listed it. What exists is
`refs/remotes/origin/HEAD`, a purely local symref pointing at
`refs/remotes/origin/main` that every clone creates — and `git`'s
`%(refname:short)` shortens it to the bare word `origin`, which is what the
earlier measurement saw. `do_branches` therefore iterates `%(refname)` and
strips the prefix itself, and skips both `HEAD` and anything carrying a
`%(symref)`. **Do not delete anything on the remote on account of this.**

**Branch counts move.** The earlier draft asserted "15 remote branches" as of
2026-08-16; at the time of writing this one the remote carries two,
`main` and `dev`. Nothing in the implementation depends on the number, which is
the point of the change described in §3.1 — but a measurement is only true on
the day it is taken, so the command above is included rather than its output.

---

## 3. The three rules that changed

### 3.1 "Only offer branches ≥1 commit ahead" → dropped entirely

That rule measures against a point that moves every time you switch, hides how
far back a rollback would take you, and removes `main` from its own list. It has
also, at least once in this repository's history, produced an empty list because
every branch was fully merged.

**Replaced with: every remote branch, most recent commit first, capped at 20.**
No name allowlist, no age filter. Which branches are worth deploying is a
judgement for the person clicking, and a regex encoding it only teaches people
to name branches to get past it. The cap is a display cap and nothing more.

Each entry carries `name`, `sha` (40 hex), `ahead`/`behind` **relative to the
deployed sha**, `tipAt`, `tipAuthor`, `subject`, `eligible` and `blockedBy`.

**Ineligible branches are returned and shown disabled with the reason, never
omitted.** Silent absence reads as a bug in the list: the operator knows the
branch exists, cannot see it, and has no way to tell "we refuse this" from "the
dropdown is broken". `blockedBy` is a sentence, not a code, because it is
rendered verbatim next to the disabled entry.

### 3.2 "Confirm when switching away from main" → gate on the target instead

Gating on the source means `feature/a → feature/b` — a switch between two
unreviewed trees on an already-degraded box — passes without a word.

**Confirm whenever the target is not `main`.** Switching *to* main never
confirms, because recovery has to be cheaper than the mistake.

The force-deploy dialog used to say it would "pull main" unconditionally. It now
names the target ref and its short sha.

### 3.3 "Revert to main is the only way back" → it is, and it travels the normal channel

The earlier design moved revert onto a second SSH key with its own forced
command at `/opt/ringmaster/recover.sh`, on the grounds that a revert travelling
over the channel the switch is allowed to replace is not a recovery path.

**That was cut, and the reasoning that replaces it is §1.** The revert is safe
over the ordinary channel *precisely because* the invariant guarantees
`tools/dispatch.sh` is byte-identical on every ref that can ever be deployed. A
branch that could change the dispatcher could never have been deployed in the
first place, so there is no state this box can reach in which the dispatcher
answering the revert is not the reviewed one.

The residual risk is honestly stated in §8. The button behaves as described:
visible whenever the box is off `main`, one click, schedules the window.

---

## 4. How a switch actually flows

```
  console                       dispatch.sh              deploy.sh
  (Ringmaster)                  (served clone)           (ops clone)
      │
      │  ssh branches
      ├─────────────────────────────►│
      │                              │ fetch --prune (bounded 4s)
      │                              │ ref_blocked_by per branch
      │◄─────────────────────────────┤ [{name, sha, eligible, blockedBy…}]
      │
      │  admin picks feature/x @ 3f2a…, confirms (target ≠ main)
      │  window row stores targetRef + targetSha
      │
      │  … drain … server empties, possibly hours later …
      │
      │  ssh switchref feature/x 3f2a… <base64 name>
      ├─────────────────────────────►│ validate name as a raw string
      │                              │ origin/feature/x still == 3f2a…?
      │                              │ ref_blocked_by 3f2a…
      │                              │ write .branch-pin atomically
      │◄─────────────────────────────┤ {"ok":true}
      │
      │  ssh deploy   (only if switchref succeeded)
      ├─────────────────────────────►│ sudo systemctl start royale-deploy
      │                                         │
      │                                         ▼
      │                              read .branch-pin, re-validate the name
      │                              fetch feature/x AND main
      │                              origin/feature/x still == 3f2a…?
      │                              assert_dispatch_invariant
      │                              symbolic-ref HEAD → refs/heads/feature/x
      │                              reset --hard, clean, consume the sha
      │                              rsync, restart FXServer
```

**`switchref` runs at deploy time, not at scheduling time.** A window can be
cancelled, and a cancelled window must not leave a pin behind that the next
routine deploy would silently act on. If `switchref` fails, the deploy does not
run and the window is recorded as failed with the refusal as its reason.

---

## 5. The pin file

`$SERVER_ROOT/.branch-pin`, owned by the `ubuntu` user. One line:

```
feature/x 3f2a9c1e...        # staged: ref plus the sha it was chosen at
feature/x                    # after a successful deploy: sha consumed
```

**Why a file at all.** `do_deploy` shells out through a sudoers rule that
matches `/usr/bin/systemctl start royale-deploy` **exactly**, and sudo matches
command lines exactly — appending a branch would silently stop matching the rule
already deployed on the box. (The same trap kept `--no-block` out of
`do_deploy`.) There is no argument to pass, so the ref has to be somewhere the
unit can find it.

**Why not a systemd `EnvironmentFile`, which is the obvious answer and is
wrong.** That file is read by systemd *as root* while being writable by the
deploy user, so anything able to write it chooses environment variables for a
root unit — `PATH`, `LD_PRELOAD`, anything. It converts "can pin a branch" into
"can run code as root", which is strictly larger than the capability this
feature is asking for. A plain ref-name file that an unprivileged `deploy.sh`
reads and re-validates cannot do that: the worst a corrupted one can say is the
name of a branch, which is exactly the decision it is allowed to make.

**The contents are never trusted.** `deploy.sh` re-validates the name from
scratch with the same shape check `dispatch.sh` applies. A pin that does not
validate is ignored with a loud warning rather than being fatal — a corrupt pin
must not be able to stop the server being deployed at all.

**The sha is consumed by the first successful deploy.** It exists to make *one*
staged switch exact: hours pass between an admin choosing a branch and the last
match ending, and a force-push in that gap must be a refusal rather than a
silent deploy of a tip nobody looked at. Once the switch has landed, later
routine deploys legitimately track the branch's tip, and keeping the sha forever
would instead make every one of them fail. The invariant check still runs on
every deploy, against whatever the tip is then.

A second file, `$SERVER_ROOT/.branch-pin.by`, holds `<epoch-ms> <display name>`
for the console's banner. It is **purely cosmetic**, is a separate file so that
`deploy.sh` never parses a human's display name, and nothing reads it to make a
decision.

---

## 6. Everything else the switch has to get right

**`BRANCH` no longer defaults to `main`.** In order: `$BR_BRANCH`, the pin file
if the name validates, `git -C "$SRC_DIR" symbolic-ref --short -q HEAD`, then
`main`. The third step is the one that matters. An unconditional `main` would
turn every routine deploy — the console's 72-hour automation, a force, a human
typing `systemctl start royale-deploy` — into a silent unannounced revert with
players online and nothing in any log saying a branch had been swapped out from
under them.

**`symbolic-ref` before `reset --hard`, using plumbing.** `git reset --hard
origin/feature/x` while `HEAD` still points at `refs/heads/main` does exactly
what it says: it moves the *local main branch* to the feature branch's commit.
The tree would be right and every question about it would be answered wrong —
`symbolic-ref` would report `main`, so the fallback above would resolve to
`main`, the off-main banner would never appear, and `status` would report the
box as running `main` while it ran something else. `symbolic-ref` writes
`.git/HEAD` and touches no file in the working tree, so unlike `checkout` it
cannot fail because somebody edited a resource in place — which is the exact
failure `reset --hard` is there to be immune to.

**A first clone always clones `main`,** whatever the pin says. A fresh clone has
no `origin/main` on disk to measure the invariant against, so cloning the
requested branch directly would install an unreviewed `tools/dispatch.sh` before
any check could run. It clones the reviewed ref and then falls through into the
ordinary fetch → check → reset path, which is the only code that ever puts a
branch on this box.

**`deploy.sh` always fetches `main` as well as the target,** because the
invariant is measured against `origin/main` and a stale one would measure
against a rule that has since changed.

**Automatic updates run only on `main`.** `onMain = deployedRef === 'main'`,
derived from the host on every driver tick and **never persisted**. It must not
live on the maintenance `current` row: `schedule()` is a full `put`, so any
schedule/cancel cycle would wipe it, after which the driver would auto-deploy
`main` over a parked branch attributed to `system`. It is written in the
positive so `undefined` does not read as `main`. Off main, the driver also
reports "no update available" rather than the raw distance from `main`, so the
console and the in-game nudge stop offering to deploy a comparison the box is
not tracking.

**`status` gained four fields:** `sha` (the full deployed commit, because
`commit` is abbreviated and cannot be compared to a 40-hex pin), `deployedRef`,
`pinnedRef`, `pinnedBy`, `pinnedAt`. `deployedRef` is read off the *clone*, not
off the pin — a switch staged and then cancelled leaves a pin naming a branch
this box has never run, and the banner is about what is **running**. It is empty
when `HEAD` is detached, and that reads as "not main", which is the safe
direction: being wrong that way costs a banner, being wrong the other way costs
an unannounced automatic deploy over a parked branch.

**Ref names are validated as raw strings before git sees them,** in both
scripts. This is a shape check, not a naming policy — there is deliberately no
`feature/`-style prefix allowlist. What it refuses is the handful of strings
that stop being a branch name once something else reads them: a leading `-` (an
*option* to every git command, and `--upload-pack=` on a fetch is arbitrary code
execution on this box), `..`, `//`, a trailing `/`, and anything outside
`[A-Za-z0-9._/-]`. `git check-ref-format` runs last, because it is itself a git
command taking the string as an argument and so cannot be the thing that decides
the string is safe to pass to a git command.

**JSON output is escaped.** `branches` prints commit subjects and author names
straight off a branch anybody can push. A single `"` in one of them would turn
the dispatcher's output into what the console reports as
`dispatch returned non-JSON` — an apostrophe in a commit message breaking the
branch list and looking like the SSH channel was down. `json_str` escapes
backslash then quote and drops control characters.

**Fields are separated by `0x1F`, not a tab.** Tab is an IFS *whitespace*
character, so bash collapses runs of them and drops empty fields; the first
version of `do_branches` used tabs, and because `%(symref)` is empty for an
ordinary branch every field after it shifted left by one. The symptom was an
entirely empty branch list from a command that was working perfectly.

**Both remote calls are time-bounded.** The console allows a whole SSH round
trip six seconds, so an unbounded `fetch` against GitHub over a cold link would
turn "show me the branches" into "the game server is unreachable". `branches`
answers from the refs on disk if the fetch does not finish in four seconds and
sets `stale: true`, which the console says out loud.

---

## 7. Cut from the original design, on purpose

None of these were built. They are listed so their absence is legible.

| Cut | Why the reduced shape is still safe |
| --- | --- |
| A second SSH key and `/opt/ringmaster/recover.sh` | §3.3 — the invariant makes the ordinary channel byte-identical on every deployable ref. |
| A `deploy-ref` grant/scope | `process` gates it, as it gates every other action that restarts the server. |
| A 24-hour park lease with auto-revert | Nothing drags the box back to `main` on its own; the banner and the one-click revert are the whole recovery story. See §8. |
| A separate `driver-state` DynamoDB item | Attribution lives on the box in `.branch-pin.by` and is derived from `status`, so no console-side row can be wiped by a `put`. |
| A branch-name allowlist regex | §3.1 — replaced by a shape check that refuses only what is unsafe to pass to git. |

---

## 8. Risks accepted

- **Lua from an unreviewed branch runs on the live host.** That is the feature.
- **A branch can still ship a broken game.** The gate protects the control
  channel, not playability. Revert is the answer.
- **Nothing brings the box back to `main` on its own.** The park lease was cut,
  so a box left on a branch stays there until somebody presses the button. The
  banner is deliberately loud and unmissable on every page for exactly this
  reason, and automatic updates are off the whole time it is showing — which
  means an update sitting behind a parked branch also waits indefinitely.
- **Revert travels the same channel as the switch.** Safe by §1's invariant, not
  by isolation. If the invariant is ever weakened, this becomes the first thing
  that breaks, and `verify.sh`'s gate is what stands in the way.
- **A moved branch is a hard refusal, not a re-prompt.** An admin who staged a
  switch and then pushed to that branch gets a failed window and has to pick it
  again. That is the intended trade: never deploying a tip nobody looked at is
  worth more than never having to click twice.

---

## 9. What to test on a live box

1. Every branch appears; nothing is silently absent.
2. A branch whose `tools/dispatch.sh` differs appears **disabled with the
   reason**, and `switchref` against it refuses even if the console is patched
   to send it. *(`feat/branch-switch` itself is such a branch.)*
3. Force-push the target between staging and deploy: the deploy refuses and says
   the ref moved.
4. Park on a branch, then cancel and re-schedule a window: the box must still be
   parked, and the driver must not auto-deploy `main` as `system`.
5. Off main, press ordinary deploy: it refreshes the parked branch, does not
   revert.
6. Revert to main from the banner: one click, drains, deploys `main`, banner
   clears.
7. An admin without `process` sees the controls disabled, and the API refuses a
   hand-crafted request.
