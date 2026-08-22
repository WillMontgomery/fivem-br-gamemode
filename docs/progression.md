# XP and Volts — what actually drives them

Two currencies. Both are computed at the end of a match by
`br_stats/server/persist.lua` and applied in a single atomic DynamoDB `ADD`.
Volts have one other source — the report reward — which is paid on its own
schedule and is documented below.

**Almost everything below is tuning, not architecture.** The numbers live in
three places and changing them is an edit to one line:

| what | where |
|---|---|
| XP curve and match XP | `br_lib/shared/xp.lua` |
| Volts payout, level bonus, prices | `br_lib/config/market.lua` |
| The report reward | `br_stats/server/awards.lua` → `AWARD_VOLTS` |

---

## The rule that makes any of this defensible

**Currency is earned, never bought.** There is no purchase path, no top-up and
no admin grant. Nothing anywhere converts money, or an admin's goodwill, into a
balance.

That is what turns "nothing in the market changes how a fight goes" from a
promise in a comment into a property you can check.

**There are now two writers that can increase a balance, and this document used
to say there was one.** That sentence was true until `e4f211d` (#168) and is not
any more, so it is corrected here rather than left to be discovered:

| verb | when | how much |
|---|---|---|
| `br:ddb:statsApply` | end of match, from `br_stats/server/persist.lua` | whatever the match earned |
| `br:ddb:awardPay` | an incident the player reported resolves with an action taken | a flat 125 |

Both are **earned by what you did in a match** — playing it, or reporting
somebody in it who turned out to be worth reporting. That is the property that
actually matters and it survives intact; the count of writers was only ever a
proxy for it. The one debit is `br:ddb:purchase`, which is how a cosmetic is
bought.

The check that replaces "count the writers": **every path that moves `balance`
lives in `js-src/br_ddb/src/index.js` and nowhere else**, and each is a single
`UpdateItem` on the profile row — `statsApply` unconditional and atomic,
`awardPay` and `purchase` conditional so neither can half-apply or run twice.
Adding a third means adding a verb to that file, which is deliberately meant to
feel like a decision — see [the ban contract](ban-contract.md).

---

## Volts

### Per match

| source | amount |
|---|---|
| finishing the match | 8 |
| winning | +60 |
| placement | up to +35, scaled linearly by how far up you finished |
| each elimination | +5 |
| each revive | +4 |

Placement scales as `35 × (1 − (placement − 1) / (total − 1))` — so second place
in a full lobby is worth nearly the full bonus and last place is worth nothing
extra. A win takes the flat 60 **instead of** the placement scale, not on top
of it. Placement 1 with `died` set — the last squad standing taken by the storm
— places first and still died, so it falls through to the placement scale (the
full 35) and does not get the win.

**Every match pays something.** A player who drops, loses immediately and
finishes last still earns 8. Zero-payout matches teach people that playing was
a waste of time, which is the opposite of what a progression system is for.

Roughly: a middling match pays ~36, a strong one ~68.

### Retuned 2026-08-16 (#89)

The first calibration paid a single match up to 470, and in one real match the
player who placed **second** with a kill took 470 while the **winner** took 60.
A payout where placement is the headline term cannot invert like that, so
placement was not the headline term — the **level-up bonus** was, at
`100 + 25/level` it could exceed the win bonus outright. The whole table came
down by roughly a third and the level bonus came down to a quarter of a win.

Worked examples on a 16-player field, at the weights that retune produced:

```
won it, no kills                 15 + 120                    = 135
2nd, 1 kill, levelled to 3       15 +  65 + 10 + 35          = 125
2nd, 4 kills                     15 +  65 + 40               = 120
8th, 2 kills                     15 +  37 + 20               =  72
last, nothing                    15                          =  15
```

**The 60 in that report was not a tuning artefact.** 60 was the *old*
`completion` value and nothing else on top of it, which needs placement ≠ 1,
zero kills *and* zero revives on the same row — the shape of a row published by a **second** ENDED transition, after
`BR.Match.resetPlayers` has zeroed the per-match counters while leaving
`matchId` intact. That is a defect upstream of the payout table, and retuning a
formula whose inputs are blank only changes which wrong number comes out.

### Halved 2026-08-20

Owner, after a playtest: *"Please cut all Volts earnings by 50%"*. Every weight
in the table above is now exactly half what #89 left it at, and so are the level
bonus and the report reward — the level bonus because exempting it would have
made it the largest single term again, which is the failure #89 existed to fix,
and the report reward because "all" was taken at its word.

`completion` rounds **up**, to 8: 15 does not halve evenly, and this is the term
that carries "every match pays something".

The same worked examples afterwards:

```
won it, no kills                  8 +  60                    =  68
2nd, 1 kill, levelled to 3        8 +  32 +  5 + 17          =  62
2nd, 4 kills                      8 +  32 + 20               =  60
8th, 2 kills                      8 +  18 + 10               =  36
last, nothing                     8                          =   8
```

**Prices did not move with it**, other than the trail range, which was re-priced
the same day under its own instruction (ceiling 1500). So at ~36 for a middling
match an uncommon canopy at 1200 is around 33 matches and a legendary at 6000 is
about 165. That is stated here rather than absorbed quietly, because it is the
second retune in a row to widen the gap.

The shape is unchanged, and `tools/test_stats.lua` is what says so: it compares
the terms against each other rather than pinning any of them, so a *partial*
rescale — the plausible mistake — fails there while a uniform one passes.

### Per level

`⌊(25 + (level − 1) × 5) ÷ 2⌋` Volts, paid **per level crossed** rather than per
level-up event — a match big enough to cross two levels pays for both. Paying
once would quietly punish the best match somebody ever had.

The 25 + 5/level curve is kept and the *result* is halved rather than the two
constants being halved in place: 5 ÷ 2 is 2.5, and a constant of 2 would flatten
the growth, so the bonus would fall further behind a win the longer somebody
played. Halving at the end holds the ratio at every level and costs one floor,
which is why alternate levels land on 12, 15, 17, 20, 22.

Later levels pay more because the XP between them grows. A flat bonus would make
the twentieth level-up feel worse than the second despite taking four times as
long.

**Deliberately modest against the match payout.** This is a punctuation mark on
top of earning, not the earning itself — roughly a quarter of a win, and it
stays there. At the old `100 + 25/level` it competed with winning outright
(level 3 paid 150 against a 240 win bonus, and from level 7 it never lost
again), which meant the largest single term in a session went to whoever
happened to cross a boundary regardless of how they placed.

### Airdrop Volts (#88)

**100 Volts, lying on the ground inside the supply drop.** The owner named the
number: *"they should be 100 Volts. This should be an item that does not go into
inventory - they simply pick it up and it's gone."*

**Paid at match end, not on pickup**, which is the whole reason it is listed
here rather than as a second earning path. Claiming the pile increments
`voltsPickedUp` on the roster entry and says one sentence; the number rides the
match results envelope into `BR.Config.marketPayout` and lands in the **same
atomic ADD** as everything else the match paid. So the invariant at the top of
this page — *exactly one writer can increase a balance* — survives an airdrop,
and there is no per-pickup write on a personally-funded database.

It is added **whole**, and it is the one term the 2026-08-20 halving does not
touch: every other weight is a curve the owner tuned, and this is a figure the
owner named and the player was already shown in a toast. Halving it would make
that toast a lie.

**A player who leaves before the match ends forfeits it**, along with their XP,
their kills and their placement. That is not special handling — it is the rule
`resetPlayer` already applies to every per-match counter, and the counter is
cleared with the rest of them so one airdrop cannot be banked twice.

### Not paid, on purpose

- **Damage dealt.** Rewards chip-shooting from range and disengaging, which is
  not behaviour worth encouraging.
- **Time survived.** Rewards hiding.

---

## Report rewards (#168, `e4f211d`)

**125 Volts to the reporter, and to every corroborator, when an incident they
filed resolves and an action was taken.** The number lives in
`br_stats/server/awards.lua` as `AWARD_VOLTS` rather than in `market.lua`,
deliberately: `market.lua` holds what a *match* pays next to what things cost so
the two stay calibrated, and this is neither — it is a fixed bounty on a
moderation outcome, outside the earn-per-hour curve.

Nothing is paid for filing. The reward tracks the **verdict**, so a report that
turns out to be nothing costs the reporter nothing and earns them nothing.

### The loop, end to end

```
report accepted   br_core/server/players.lua  →  br:incident:filed
                  the case is already a row in ringmaster-incidents

debt recorded     br_stats/server/awards.lua  →  br:ddb:awardClaim
                  one DynamoDB item on the GAME's own table

...hours or days, and several deploys...

sweep             every 10 min  →  br:ddb:awardQueue, then one
                  br:ddb:incidentVerdict per pending case

paid              br:ddb:awardPay, once per payee, forever
settled           br:ddb:awardSettle takes the case off the queue
```

**The debt is durable because the verdict is not fast.** An admin decides in a
web console in another region, minutes to days later, and the game server will
have restarted several times in between — so "remember who to pay" cannot be a
Lua table. It is one item on `br-players` (`{pk: 'br:reportaward', sk: 'queue'}`)
holding the pending ids, the licenses owed for each, and when each was first
claimed. A deploy between the report and the decision loses nothing.

**It polls rather than being told.** There *is* a console→game channel — the SSH
dispatcher that carries a kick — and it is deliberately not used here. A dropped
message on that path is an unpaid reward with nothing recording it was owed; a
missed poll is a reward paid on the next sweep.

**A reward cannot be paid twice, and no code remembers not to pay it.** The
credit and the receipt are the *same* conditional `UpdateItem`: `ADD balance,
reportRewards` with `ConditionExpression: attribute_not_exists(#paid) OR NOT
contains(#paid, :id)`. `reportRewards` is a string set on the same item as the
balance, so there is no window between deciding to pay and recording it. A second
attempt is refused **by DynamoDB**, and the refusal is reported to the caller as
success — which is the opposite call from `purchase`, where a refusal means the
player asked for something and did not get it. Here nobody asked; the condition
failing means the money already landed.

**Being paid does not depend on being online.** The credit is on the account. If
the player happens to be connected they also get a line saying so, and
`br:market:credited` keeps `br_core`'s session-cached balance honest so the lobby
does not go on showing the old total.

### What "an action was taken" means, exactly

Resolved in `js-src/br_ddb/src/verdict.js` against the console's own
`IncidentVerdict` contract, and read `action` first:

| row | `settled` | `payable` |
|---|---|---|
| absent, or the read failed | no | no |
| `state` anything but `resolved` | no | no |
| resolved, `verdict.action` = `ban` or `kick` | yes | **yes** |
| resolved, `verdict.action` = `none` | yes | no |
| resolved, no `verdict` at all | yes | no |

**Absent is not `none`.** A resolved row carrying no verdict is either one
resolved before the field existed or one the system auto-resolved, where no human
decided anything — reading that as "no action was taken" is a claim about a
decision nobody made. Both settle paying nobody, and both are logged, but they
are logged as different facts.

`expiresAt` is present **if and only if** `action` is `ban`, and `null` on a
permanent one. A reader that reaches for it without narrowing on `action` gets
`undefined` where a permanent ban gives `null` — two falsy values meaning
entirely different things. Nothing here decides on it: a temporary ban and a
permanent one are the same 125 Volts.

### The edges that are written down rather than discovered

- **Fails closed.** An unreadable verdict answers "not settled", the claim stays
  on the queue, and the next sweep asks again. Paying on a failed read would
  credit against a verdict nobody has seen. (The ban check fails *open*, for the
  opposite reason: an unreachable database must not become a server nobody can
  join.)
- **Thirty days, then dropped unpaid.** A case still undecided after a month is
  read on every sweep for the rest of the server's life otherwise. No verdict is
  not a verdict.
- **Ten minutes between sweeps**, ten cases per sweep. The reward is a pleasant
  surprise hours later, not a transaction anybody is watching.
- **A machine-filed incident pays nobody.** An anticheat filing has no reporter,
  so no debt is registered. A human who later corroborates it is claimed against
  that same id and is paid normally.
- **A payee whose write genuinely failed leaves the case on the queue**, so the
  next sweep retries; the payees already paid are refused a second time and cost
  nothing.
- **A stats failure must never stop a match**, the rule `br_stats` has always run
  on. Nothing here is on a hot path, nothing blocks, and every failure is a log
  line.

`brawards` in the server console prints the counters (claimed, swept, paid,
already paid, settled, expired) and forces a sweep.

---

## XP

XP drives levels only. It has no purchasing power, which is deliberate: levels
say how long you have played, Volts say what you have done recently, and
collapsing them into one number loses both meanings.

The curve is in `br_lib/shared/xp.lua`. It lives in `br_lib` rather than in
`br_stats` so that **one implementation** is shared by everything that needs it:

- `br_stats` derives the level to store at match end
- `br_core` evaluates it to send the lobby a real level and bar

A client that computed its own would eventually disagree with the server about
what level somebody is, and the player believes the number in front of them. So
the client never derives a level — it renders what the server sends.

---

## Where the numbers surface

| screen | shows | source |
|---|---|---|
| Lobby | level, bar, balance | `MARKET_STATE`, from the profile row |
| Verdict | XP gained, level-up, Volts earned | `MATCH_EARNED`, from br_stats |
| Market | balance | `MARKET_STATE` |
| A toast, whenever a sweep pays | "gifted 125 Volts… who has now been banned" | `br_stats/server/awards.lua`, keyed `report.reward` |
| Ringmaster profile | level, total XP, balance | `br-players` directly |

The reward toast names the **action** and nothing else. The admin's written
resolution is not in it and must not be: it is prose one moderator wrote for
another, and forwarding it hands a stranger's internal note to the person who
reported them.

**The verdict screen owns its own timing.** Lua only delivers the numbers; the
screen stages the animation, because it is the only thing that can observe
whether it is on screen. A delay timed from Lua against a screen it cannot see
has missed that window twice.

**If the stats write fails, nothing is claimed.** No award animation, no Volts
line. A match whose result was not recorded must not tell the player it paid.

---

## Keeping the two calibrated

Payout and prices live in the same file on purpose. They only mean anything
relative to each other — a 1200 canopy is cheap or extortionate depending
entirely on what a match returns — so changing one should force you to look at
the other.

**Payout has moved twice and prices have moved once**, which is stated here
rather than quietly absorbed, because the gap is no longer small. At **~36** for a
middling match an uncommon canopy at 1200 is around **33 matches** and a legendary
at 6000 is about **165**. The owner asked for a third of the payout in #89 and for
half of what was left on 2026-08-20, and said nothing about the canopy or finish
prices either time, so those are untouched. If prices are the half that should
move, it is the table at the top of `market.lua`.

> **This section used to read "At ~70 for a middling match an uncommon canopy at
> 1200 is around 17 matches … and a legendary at 6000 is 60–80."** Those were the
> post-#89 figures and the halving on 2026-08-20 left them describing a payout
> that no longer exists — in a document that gets the arithmetic right two
> sections earlier. Both halves of the file now quote the same numbers.

The one price instruction that did land is the **trail** range, re-scaled the same
day under its own instruction to a ceiling of **1500**: 400 for Ember and Ice, 700
for Toxic and Rose, 1000 for Void, 1500 for Patriot. The squad-colour trail is
gone entirely, and **"None" is no longer shown as a product** — it stays in the
index as a hidden default so an equipped slot has somewhere to go back to, but it
is not a card in the storefront and it never was a thing anybody bought.

The older intent that "an uncommon is a handful of matches" has not been true for
two retunes. Saying so is the point of this section.
