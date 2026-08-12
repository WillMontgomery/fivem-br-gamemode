# XP and Volts — what actually drives them

Two currencies, one write. Both are computed at the end of a match by
`br_stats/server/persist.lua` and applied in a single atomic DynamoDB `ADD`.

**Everything below is tuning, not architecture.** The numbers live in two config
tables and changing them is a config edit, not a code change:

| what | where |
|---|---|
| XP curve and match XP | `br_lib/shared/xp.lua` |
| Volts payout, level bonus, prices | `br_lib/config/market.lua` |

---

## The rule that makes any of this defensible

**Currency is earned, never bought.** There is exactly one writer that can
increase a balance — the end-of-match stats write. There is no purchase path, no
top-up, no admin grant, and no code anywhere else that touches `balance`.

That is what turns "nothing in the market changes how a fight goes" from a
promise in a comment into a property you can check. If a second writer ever
appears, the claim stops being true and the whole no-pay-to-win argument has to
be re-argued from scratch.

---

## Volts

### Per match

| source | amount |
|---|---|
| finishing the match | 60 |
| winning | +240 |
| placement | up to +150, scaled linearly by how far up you finished |
| each elimination | +20 |
| each revive | +15 |

Placement scales as `150 × (1 − (placement − 1) / (total − 1))` — so second place
in a full lobby is worth nearly the full bonus and last place is worth nothing
extra. A win takes the flat 240 instead.

**Every match pays something.** A player who drops, loses immediately and
finishes last still earns 60. Zero-payout matches teach people that playing was
a waste of time, which is the opposite of what a progression system is for.

Roughly: a middling match pays ~150, a strong one ~400.

### Per level

`100 + (level − 1) × 25` Volts, paid **per level crossed** rather than per
level-up event — a match big enough to cross two levels pays for both. Paying
once would quietly punish the best match somebody ever had.

Later levels pay more because the XP between them grows. A flat bonus would make
the twentieth level-up feel worse than the second despite taking four times as
long.

### Not paid, on purpose

- **Damage dealt.** Rewards chip-shooting from range and disengaging, which is
  not behaviour worth encouraging.
- **Time survived.** Rewards hiding.
- **Airdrops.** No airdrop system exists yet. When it does, the payout should be
  counted at match end rather than on pickup — paying on pickup rewards
  *reaching* a contested crate and then dying, and it breaks the one-writer rule
  above.

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
| Ringmaster profile | level, total XP, balance | `br-players` directly |

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

Current intent: an uncommon canopy is a handful of matches, a legendary is a
season's habit.
