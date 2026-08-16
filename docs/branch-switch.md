# Branch switching from the console

Deploying a branch other than `main` to the live game host, from Ringmaster's
maintenance page, without a human on the box.

This document supersedes an earlier plan. That plan was built on two measured
claims about this repository, and **both of them were false** — in opposite
directions, which is why the corrected version reads so differently. The
measurements are redone in §2 and the commands are included so they can be
re-run rather than believed.

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

Those two facts sit badly together and the reason is one line in
`tools/dispatch.sh`'s own header comment: **the dispatcher is a tracked file
inside the directory the deploy hard-resets.** It was moved there deliberately,
and moving it there was right — it meant the dispatcher shipped with the game
code instead of needing a second manual `git pull` that nothing prompted you to
do. The cost of that decision was invisible while `main` was the only thing
ever checked out.

Adding branch switching makes it visible. "Switch to branch X" and "replace the
console's only channel to the box with whatever X says that channel should be"
are, mechanically, the same operation.

**So: a ref is only deployable if `<sha>:tools/dispatch.sh` exists, is mode
100755, and its blob id is exactly equal to `origin/main:tools/dispatch.sh`'s
blob id.**

Blob ids, not diffs, not a checksum we compute — git already content-addresses
every file, so this is one `rev-parse` per side and a string compare. It is
enforced **twice**: in `dispatch.sh` before it writes the branch pin, and again
in `deploy.sh` before it touches the working tree. Twice because the two run at
different times — a switch is staged now and deployed when the match ends, up
to 72 hours later, and the ref can move in between.

What this buys: the feature stops being "run arbitrary code, including the
control channel" and becomes "swap the resource payload; the boundary is
invariant." The Lua under `resources/` is still arbitrary code from an
unreviewed branch — that is the entire point of the feature and is not in
scope to prevent. The channel that can *turn the feature off* is what is being
protected.

**The accepted cost: you cannot use this feature to test a change to `tools/`.**
Changes to `tools/` go through `main` and PR review, which is where
`verify.sh`'s boundary gate already runs. That is the correct place for them and
this restriction is a feature, not a limitation to work around later.

---

## 2. What is actually true of this repository today

The earlier plan asserted that *"37 of 39 real remote branches score 0, and the
two that pass are 1-ahead/96-behind and both delete `tools/dispatch.sh`."*
None of that is true. There is no 39, there is no branch that deletes the
dispatcher, and no branch passes.

Re-run it yourself:

```bash
git fetch --prune origin && MAIN=$(git rev-parse origin/main:tools/dispatch.sh) && git for-each-ref --format='%(refname:short)' refs/remotes/origin/ | grep -v 'HEAD$' | while read -r r; do blob=$(git rev-parse -q --verify "$r:tools/dispatch.sh" 2>/dev/null); [ "$blob" = "$MAIN" ] && s=SAME || s="${blob:+DIFFERS}"; printf '%-42s %-8s %s\n' "${r#origin/}" "${s:-MISSING}" "$(git rev-list --left-right --count "origin/main...$r" | awk '{print $2" ahead / "$1" behind"}')"; done
```

As measured on 2026-08-16, across **15** remote branches:

| Measurement | Result |
| --- | --- |
| Branches whose `tools/dispatch.sh` is byte-identical to main's | **15 of 15** |
| Branches missing or altering `tools/dispatch.sh` | **0** |
| Branches at least 1 commit ahead of `main` | **0 of 15** |

Two conclusions follow, and they point in opposite directions.

**The invariant rule is free.** It excludes nothing that exists. It is a
tripwire for a future branch that touches `tools/`, not a filter that costs us
anything now. The earlier plan's framing — that the feature's first action
would delete the channel — was alarming and wrong.

**The proposed "≥1 commit ahead" filter is not just wrong in principle, it
produces an empty dropdown.** Every branch on this remote is fully merged into
`main`: zero ahead, between 1 and 30 behind. Ship that filter and the feature
has no visible effect on any branch that exists, which reads as "the dropdown
is broken."

There is also a remote branch literally named `origin`, at main's tip. That is
a mispush and should be deleted; it will otherwise render as `origin/origin` in
every branch list this feature produces.

---

## 3. The three rules that change

### 3.1 "Only offer branches ≥1 commit ahead of the current branch" → replaced

Beyond producing nothing today, the rule measures against a point that moves
every time you switch, hides how far back a rollback would take you, and
removes `main` from its own dropdown.

**Replaced with three non-directional filters, computed on the game box:**

1. **Name allowlist.** `main`, or `^(feature|release|hotfix|fix|dev|test|ci)/[A-Za-z0-9._/-]{1,80}$`. Overridable only by `BR_REF_ALLOW` on the box.
2. **Recency.** Tip committer date within `BR_BRANCH_MAX_AGE_DAYS` (default 30). `main` is exempt and always present.
3. **Cap.** The 10 most recent by committer date, plus `main`.

Every survivor is then run through the §1 gate and returned with
`eligible: true|false` and a `blockedBy` reason. **Ineligible branches are shown
disabled with the reason, never omitted.** Silent absence reads as a bug;
"this branch changes tools/dispatch.sh" is exactly what an operator needs to
see, and given §2 it is the only reason that will ever appear.

Each entry carries `name`, `sha`, `ahead`/`behind` **relative to the deployed
sha**, `behindMain`, `tipAt`, `tipAuthor`, `subject`. Sorted by date, never by
commit count. `main` appears disabled, labelled `main — use Revert to main`.

### 3.2 "Confirm when switching away from main" → gate on the target instead

Gating on the source means `feature/a → feature/b` — a switch between two
unreviewed trees on an already-degraded box — passes without a word. Gate on
the target: **confirm whenever the target is not `main`.** Switching *to* main
never confirms, because recovery has to be cheaper than the mistake.

Confirm at both ends. The staged switch does not deploy until the match ends,
possibly three days later and possibly pressed by a different admin, and the
force-deploy dialog currently says "pull main". It must name the target ref.

### 3.3 "Revert to main is the only way back" → it cannot be, and here is why

The revert travels over the channel the switch is allowed to replace. After a
branch deploy, the `dispatch.sh` answering the revert *came from that branch*.
A recovery path implemented inside the thing being recovered from is not a
recovery path.

The §1 invariant makes that scenario very unlikely — but "unlikely" is the
wrong standard for the one control that undoes everything else.

**Revert moves off the served clone entirely.** A second SSH key with its own
forced command at `/opt/ringmaster/recover.sh`: root-owned, mode 0755, outside
both clones, never written by any deploy, takes no arguments, does one thing —
pin `main`, run the deploy unit. The console holds it as
`GAME_SSH_RECOVERY_KEY`. `revert` is **not** a verb in `dispatch.sh`.

The button stays exactly as described: appears whenever the box is off `main`,
one click, schedules the window.

---

## 4. Everything else the switch has to get right

**Pin the sha, not the name.** Up to 72 hours pass between the audit row and
`deploy.sh` resolving the ref, and anyone with push access can force-push in
between. The console resolves the selection to a 40-hex sha at listing time,
stores it on the maintenance row, sends it over SSH, shows it in both
confirmations, and both box-side hops refuse if `origin/<branch>` no longer
equals it. **A moved branch is a refusal, never a silent deploy of a new tip.**

**Automation gate is derived, never stored.** `onMain = deployedRef === 'main'`,
recomputed from the host on every tick, written in the positive so `undefined`
does not read as main. It must not live on the maintenance `current` row —
`schedule()` is a full `put` and any schedule/cancel cycle would wipe it, after
which the driver would auto-deploy `main` over a parked branch as `system`.

**Attribution is stored, on a different item.** `id = 'driver-state'` in the
same table, holding `parkedRef`, `parkedSha`, `switchedAt/By/ByName`. Different
partition key, so `schedule()` cannot reach it. Read only to render "off main
since X, switched by Y" — never to decide whether to automate.

**A bare `deploy` refreshes the checked-out ref, not `main`.** Off main,
defaulting to `main` would turn every ordinary deploy — the 72-hour automation,
a force, a human on the box — into a silent unannounced revert with players
online. `deploy.sh`'s default becomes `symbolic-ref --short -q HEAD`, falling
back to `main`. On every box that exists today the served clone is on `main`,
so this is byte-identical until the moment the feature ships.

**Off main is a lease, not a state.** Disabling the 72-hour backstop removes the
only thing that ever drags the box back toward reviewed code, and `deploy.sh`
never resets on its own. Off-main gets `PARK_MAX_MS` (default 24 h); on expiry
the driver schedules a revert window as `system`, drain-until-empty, with its
own audit action. The header chip goes to warn tone immediately, not at expiry.

**A new scope, so nobody inherits this.** `grants.ts` documents `process` as
"terminate and restart the FXServer process" — everyone holding it was granted
a restart button, not the right to run unreviewed branches. Add `deploy-ref`.
Switching to a non-default ref needs `process` **and** `deploy-ref`; revert
needs `process` alone. There is no grants API route, so nobody holds
`deploy-ref` until it is set by hand in DynamoDB — the feature ships off, and
that is the re-consent.

**"Started" must stop meaning "succeeded".** `do_deploy` returns
`{"ok":true,"started":true}` unconditionally, by design — it detaches so the
six-second SSH budget cannot kill a running deploy. With branches that is no
longer enough: the driver must confirm by comparing `status.deployedSha` to the
window's `targetSha` on later ticks, resolving `ok` on match and `failed` after
a 10-minute timeout.

---

## 5. Where the code goes

**Game box, `tools/dispatch.sh`** — new verbs `branches` and `switchref`, both
read-only-ish and both behind the §1 gate. `switchref` validates the ref name
against the allowlist as a *raw string* before it reaches git, verifies the sha
still matches, runs the gate, and writes the pin to an `EnvironmentFile` the
`royale-deploy` unit reads. It does not run the deploy.

The pin has to be a file because `do_deploy` shells out through a sudoers rule
that matches `/usr/bin/systemctl start royale-deploy` **exactly** — an extra
argument silently stops matching the rule already on the box. The unit reads
`BR_BRANCH` from the environment file; nothing about the sudoers line changes.

**Game box, `tools/deploy.sh`** — re-runs the gate against the pinned sha
before `reset --hard`, and defaults `BRANCH` to the checked-out ref.

**`tools/verify.sh`** — the existing verb-set gate learns the two new verbs, and
gains a check that `deploy.sh` cannot reach `reset --hard` without the gate
call above it. That check is the thing that keeps this document true.

**Console** — `ssh.ts` gains the two calls; `maintenance.ts` carries
`targetRef`/`targetSha` on the window; `maintenanceDriver.ts` gains the
`onMain` gate, the confirmation step and the lease; `grants.ts` gains the scope;
`MaintenancePanel.tsx` gains the dropdown, the off-main notice, and the revert
button. Every string that currently says "main" unconditionally needs rewriting
— there are more of them than you would guess.

---

## 6. What to test

1. Every branch appears; `main` appears disabled; nothing is silently absent.
2. A branch whose `tools/dispatch.sh` differs appears **disabled with the
   reason**, and `switchref` against it refuses even if the console is patched
   to send it. *(No such branch exists today — make one to test this.)*
3. Force-push the target between staging and deploy: the deploy refuses and
   says the ref moved.
4. Park on a branch, then cancel and re-schedule a window: the box must still
   be parked, and the driver must not auto-deploy main as `system`.
5. Off main, press ordinary deploy: it refreshes the parked branch, does not
   revert.
6. Off main, wait out `PARK_MAX_MS`: a revert window schedules itself as
   `system`.
7. Revert with the served clone's `dispatch.sh` deliberately renamed on the
   box: revert must still work. This is the whole reason for the second key.
8. An admin with `process` but not `deploy-ref` sees the dropdown disabled with
   a reason, and the API refuses a hand-crafted request.

---

## 7. Risks accepted

- Lua from an unreviewed branch runs on the live host. That is the feature.
- A branch can still ship a broken game — the gate protects the control
  channel, not playability. Revert is the answer, which is why revert does not
  depend on the branch.
- `recover.sh` is a second forced-command key on the box, maintained by hand
  and outside CI. It is deliberately small enough to read in one sitting, and
  `verify.sh` cannot check it because it is not in this repository.
