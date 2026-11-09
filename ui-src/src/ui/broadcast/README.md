# The Broadcast kit (#431)

The owner picked Broadcast for the squad panel (#429) and asked for two more
things: an effect for every piece of UI as it appears and goes ("right now it
just pops in and out"), and something that scales -- "let's make something that
will be scalable and a cohesive UX", across the HUD and on to the Market. This
is that: a small kit of our own, no third-party component library, in three
parts.

- **TOKENS** (`tokens.css`): every color, length, type size, curve and duration
  the kit draws with, under `--bc-`. Colors point at `src/index.css`'s tokens,
  so the colorblind modes reach them.
- **PRIMITIVES**: Plate, ScoreCell, Numeral (and Clock), Bar, Stamp, Tag (and
  Badge), LightSweep; the HUD's slanted Vitals; for later screens Button (and
  CardAction), Tab (TabStrip), Card (CardGrid), ListRow and DialogFrame.
- **MOTION** (`motion/`, `motion.css`): presence -- one anchor on its way in
  and out -- with a stagger, a quick hide for layers, and named presets. A
  screen picks its motion in one place.

It is for UI v2's screens (#436), each behind its piece: with every piece
off nothing on screen uses it, and its tokens sit on no element (the root,
below).

## The owner's picks (2026-11-03)

They bind every build.

- **His health and shield bars are slanted**, like Broadcast, not today's
  pills: `Vitals`, the HUD board's "vitals · slant" in the kit (two straps,
  the ramp feed, the numeral after the bar). The HUD stage draws it in the
  vitals strip.
- **Numbers tick in when the HUD comes on**: each place ticks into place
  already showing its true digit. `reveal="tick"` is Numeral's default (and
  Bar's `numReveal`); not count up, not just appear. Leave it unset.
- **Volts are the soft gold**, `--bc-volts` (`--color-volts`, #d9ae35),
  everywhere a Volts amount shows: the Market's prices and balance included.
  `--bc-victory` is victory's.

## Files

| file | what |
|---|---|
| `tokens.css` | every token, on the kit's root class `.bc-kit`; `@property --bc-u` |
| `kit.css` | the primitives, a section each, then their keyframes and `.layer-off` lines |
| `motion.css` | the presence channels and the built-in presets (broadcast, quickHide, none) |
| `motion/drop.css`, `fade.css`, `slide.css` | the plug-in presets |
| `motion/tokens.ts` | the motion numbers, once: curves (literals), durations, the stagger, the presets' timings |
| `motion/machine.ts` | the presence machine: pure, no DOM, no React, node-testable |
| `motion/usePresence.ts` | its React and DOM half |
| `motion/label.ts` | which side of the number rule a numeral is on (alone, or in a label), and its way out and back (`wayOf`): pure, node-testable on stand-ins |
| `motion/Presence.tsx`, `PresenceScope.tsx`, `QuickHide.tsx` | the components; `PresenceClock` is in `PresenceScope.tsx` |
| `motion/presets.ts`, `context.ts` | the preset registry; the contexts |
| `Plate.tsx` ... `DialogFrame.tsx` | the primitives (`Vitals.tsx`: the slanted vitals) |
| `deps.ts` | the ONE file that imports from the rest of `src/` |
| `util.ts` | `u()`, `vars()`, `rgba()`, `ab()`, `useBeat()`, `slantInsets()`, `toneColor()` |
| `index.ts` | one import for a screen: every export, and the stylesheets in cascade order |
| `scripts/test-broadcast.mjs` | the checks (below), in `npm run build` |

(`motion/machine.ts` is the system map's `presence.ts`: on Windows a
`presence.ts` beside `Presence.tsx` is one module to the resolver.)

## The checks

`scripts/test-broadcast.mjs` runs in `npm run build` (alone, `npm run
test:broadcast`). It pins every curve and duration the TS and the CSS both hold
(and `--bc-ease-out`/`--bc-ease-snap` through to `src/index.css`), checks every
preset has its CSS rule and its timings, drives the presence machine through
every change of moment, and holds the CSS to its rules (every endless animation
paused under `.layer-off`, every class `bc-`, keyframes on transform and
opacity only), and runs the scope's way out as one (a leave the scope drove
parks until the last one ends). It also pins the number rule, over every sheet
a number can meet -- the kit's and every other one under `src/` -- by
specificity, then order: only motion.css sets a number's own opacity or timing
(a page may only land one whole at once: opacity 1, transitions off), an
animation on a number moves its transform only, and no page hands a Numeral or
Clock a class or style of its own. The cascade is resolved for every preset
there is (the kit's, its plug-ins, and every one a page names in its CSS or
registers in its code) and every phase: a number alone goes the moment its
content starts to leave and stays hidden (a preset may keep it only as a quick
hide: its root's opacity alone, on the quick hide's timing); one in a label
keeps its opacity through the leave and lands as one alone does; a page's own
exit (`data-bc-exit`) hides one alone at once and outranks a page's live
landing. `motion/label.ts` is run on stand-ins for the previews' cases (Send 2
reports, 7,450 VOLTS, 8/8, a struck price, a clock glyph, a box that says it is
a label, a price that is its button's label, a score on its plate line, a bar's
numeral, a level beside a name), and its way out and back through every moment
(a leave from shown, a leave before landing, after landing, live, a turn-round
showing or hidden, held, a quick hide, a change mid-leave). Numeral's and
Clock's wiring to both is checked in their source (the ref on the span they
draw, `useInLabel` after every render, `useWay`, what they draw), and every
check fails on a mutant of the code it guards.

It holds the kit to the game too: `main.tsx` imports every stylesheet above
`App`, so the built CSS has the kit's rules after index.css's (the other
way round, the kit's captions would lose to `.micro-label` and draw dim); the
index.css keyframes the kit borrows (endSlam, punch, deltaFloat) are still
there, and every keyframe the kit defines is named `bc` and a capital, so none
can replace one of index.css's or a library's; the tokens sit on `.bc-kit`
alone and every kit rule lands on a kit element or inside one (through every
`:is()` and `:where()`); `deps.ts` is the one door, nothing the kit draws
leaves the tree it is mounted in, and every file outside the kit that takes a
value from it sets `bc-kit` or is imported only by files that do; and no kit
source hands Tailwind a utility of its own (QuickHide writes
`hidden === false` for that reason). check-ui reads the kit's sheets as well:
R7 (motion), R27 (every endless loop paused under `.layer-off`) and R2b
(`--bc-warn` is the warn tone, not a rarity). check-css reads the built bundle
for the Chromium rule below: it fails on the individual transform properties,
`linear()`, `color-mix()`, `animation-composition`, nesting and `tan()`, and
warns on the rest; check-cef keeps `zoom` out. test-broadcast holds the kit's
own `.ts` and `.tsx` to that rule too, with the rest of UI v2's code
(`src/hud/v2`, and every file outside the kit that takes a value from it): the
preview gate's code bans, read in inline styles, WAAPI keyframes and their
options, and selector strings, fail the build, and its notes
(requestAnimationFrame, setInterval, backdrop-filter, a transition on layout)
are printed; a deliberate exception carries `cef-ok` in a comment on its line.
And check-layout's UI v2 rows (`hud/v2`, `hud/v2-long-names`) read the page
itself: once the wipe has landed, every element of the kit's (a `bc-` class or
a `data-bc-` attribute) must be drawn under a `.bc-kit` root, which the
per-file rule cannot see for a second root in one file.

## The rules

- **Chromium 103 and 144.** Never the individual transform properties,
  `linear()`, `color-mix()`, `:has()`, container queries,
  `animation-composition`, `text-wrap: balance`, `@starting-style`,
  `transition-behavior`, nesting, `zoom`, `tan()`. `@property` (85), `inert`
  (102), `max()` (79) and CSS variables in keyframes are fine.
- **Motion is transform and opacity**, triggered by a state change. Presence is
  transitions (a change of mind retargets); one-shot accents are keyframes,
  restarted by a fresh element (a React key) or an A/B class. **No per-frame
  JavaScript**: clocks wake once per displayed second (`startCountdown`), a
  count-up is at most ten timer writes, nothing uses requestAnimationFrame.
- **No new text.** Words come from data or existing strings (DOWN, OUT, HS, the
  placard caps, the Market's copy). The kit adds none.
- **A number is never hidden at the moment it changes**, and one that counts up
  ends on its true value.
- **A number in a label leaves with its words.** A number standing alone (a
  score, a bar's numeral, a level, a price on its own) goes the moment its
  content starts to leave, so it is never seen moving, under every preset. One
  with words or a glyph beside it in its box, in a box that says it is a label
  (`data-bc-label`: its company is one the DOM cannot show -- a strike or a
  chip's plate drawn in CSS, Showcase's struck total and the Ladder's chip, or
  the struck total in a box beside it, Showcase's gated kit price), or that is
  a button's or a tag's whole label (a price on its buy button), is one of those
  words: it fades and slides out with them. A price on a clickable card that
  has a name of its own still stands alone. Gone on its own, it left "Send 2
  reports" reading "SEND REPORTS" for the frames its words took to fade (the
  player list, after a send). It leaves with them only if it was showing as
  the leave began: one whose entrance had not landed is hidden as a number
  alone is, so it never lands in the middle of the leave.
- **A page's own exit hides its numbers too.** A row that leaves on keyframes
  of its own while its presence stays shown (the squad panel's mate who
  leaves) carries `data-bc-exit`, and every number standing alone in it goes
  as the exit starts.
- **Only the kit sets a number's own opacity and timing** (motion.css). A page
  may land one whole at once (opacity 1, transitions off); to dim one, dim its
  digits (`.bc-col`) or its box, never the number.
- **Tokens only.** Lengths are kit units (`u(3.4)` is `calc(var(--bc-u) *
  3.4)`); a value that recurs is a token. No Tailwind class inside the kit.
- **Classes are `bc-`; phases are data attributes** (`data-bc-phase`), never a
  class like `hidden` or `visible` (Tailwind's `.hidden` is `display: none`,
  which kills a transition outright -- check-ui R8).
- **Every endless animation has its `.layer-off` line** (check-ui R27): the
  on-air meter and the hot slab's pulse, at the end of `kit.css`; the alarm
  pulses on index.css's `.mate-pulse`.
- **`deps.ts` is the one door to the rest of `src/`.**

## The root and the tokens (`tokens.css`)

**A screen built on the kit carries `bc-kit` on its own root element**, and
the tokens are declared there and nowhere else, never on `:root`: some 215
custom properties on the document root would ride every element of every
screen with every UI v2 piece off (Cloudscape's on `<body>` made every lobby
restyle 17% dearer, `screens/lockerv2/sheet.ts`). The kit renders nothing
outside the tree it is mounted in (no portal), so the root's class reaches
everything the kit draws under it; a root inside another root re-declares
the same values and changes nothing.

Palette pointers (`--bc-accent`, `--bc-victory`, `--bc-volts`,
`--bc-hp`, `--bc-shield`, `--bc-danger`, `--bc-storm`, `--bc-rarity-1..5`,
`--bc-ink-*` ...) and promoted literals (`--bc-accent-hi`, `--bc-accent-ink`,
`--bc-focus`, `--bc-warn` -- a tone, never `--rarity-5` -- `--bc-ink-soft`,
`--bc-ink-faint`, `--bc-ink-off`, `--bc-ink-quiet`, `--bc-ink-lit` ...); the
slant (`--bc-slant: -15deg`, `--bc-tan: 0.26795`); surfaces (`--bc-deck`,
`--bc-strap`, `--bc-cell-bg`, `--bc-alarm`, `--bc-out-plate`, the project's
fills by job: `--bc-fill-control`, `--bc-fill-card`, `--bc-fill-selected` ...,
scrims, rules); static shadows; type (`--bc-font-num` Anton, `--bc-font-word`
Barlow, `--bc-fs-*`, `--bc-ls-*`); motion (`--bc-ease-*`, `--bc-t-*`,
`--bc-step`).

**Squad colors are data, not tokens**: a row passes `mate={m.colour}` and the
plate sets `--bc-mate` and `--bc-mate-tint` (`rgba(color, .3)`; no color-mix on
103). Never copy `BR.SquadColours` into CSS.

**The unit.** `--bc-u` is registered as a `<length>`, so it resolves to pixels
where it is declared: `1rem` on `.bc-kit` (the HUD's rem). A subtree with a
unit of its own (a Cloudscape island sizes in em, where a rem would scale
twice) sets `--bc-u` inline and carries `data-bc-u`. Every derived length is
declared on `.bc-kit, [data-bc-u]`, so it re-resolves wherever the unit is
set. (A custom property holding `var()` resolves where it is DECLARED; that is
the trap this is shaped around.)

## Primitives

All take kit units for lengths. Effects are keyed beats: counters that start
at 0 (`useBeat`), so a mount animates nothing, and presence never fires one.

**Plate** -- the slanted surface with its color edge.
`variant`: `deck` (hardware) | `strap` (recedes) | `hot` (demands: a cap strap
in `hot`, its slab breathing). `edge` (the slab color; default the mate, the hot
color, else the accent), `edgeSide`: `lead` | `trail`, `pivot`: `foot` |
`head` (a right-anchored plate: the same parallelogram, the edge drops from the
head). `height` (3.4 deck, 1.6 strap, 4.8 hot), `band` (the name band: a
hairline, the mate wash, a darker rest), `cell`: `lower` | `full`, `cellWidth`,
`cellSide`, `mate`, `hot`, `cap` (existing words), `capHeight`.
`state`: `rest` | `active` (teal, a lit slab) | `alarm` (a red wash, the slab
pulsing) | `dim` | `out` (slab darkened; `fade` sets the settled opacity, .34 by
default; `outDelay` holds the darkening through a dying sequence).
Keyed effects: `flash {n, kind: hit|shield|down|die, power}`, `shake {n, kind:
jolt|knock|punch|rise|thud, amp}` (one channel; A/B restart), `burst` (n),
`recolor {n, prev}` (the old color retracts), `flare` (n), `meter` (the on-air
meter: present when defined, runs while true).
Slots: `fx` (accents in the deck, above the base and under the cell:
LightSweep), `cover` (the band's replacements: `Plate.Swap`), `coverFoot`
(`Plate.Foot`, `Plate.Zip`), `coverFace` (upright content over the cover), and
children (the face).
`Plate.Line {cy, ch, lh, between?, end?, center?}`: an upright line, stepped in
along the slant at its own height (`cy` its center from the plate's top, `ch`
half its content's height, `lh` its box). The squad row: name `0.68/0.44/1.2`,
health `1.84/0.44/0.9`, shield `2.86/0.44/0.9`, a cover line `2.36/0.5/2.08`.
Its rule is `.bc-plate .bc-line`: a line only means something in its plate, and
a sheet with a `.bc-line` of its own (the Broadcast squad prototype's) can
share a page with the kit without either reaching the other.
`Plate.Swap {kind: alarm|out|deck, motion: in|out|none, delay, rider, still,
drain, onLanded}`: a plate that slams over the band on the diagonal with a white
rider; key it by the event; keep the outgoing one mounted with `motion="out"`.
`slantInsets(H, cy, ch)` gives the same insets in JS.

**ScoreCell** `{span: lower|full, side: start|end, width}` -- the near-black
cell in the deck plane, drawn above the fx so a numeral keeps its backing as it
changes. Plate draws one for `cell`.

**Numeral** `{value, places, tone, size: sm|md|lg, fs, beat {n, kind:
pop|slam}, blankZero, reveal: none|tick|count, heavy, format}` -- fixed
columns, plain static text at rest (no strip, no clip). A changed place is a
fresh element with the new digit, opaque from its first frame: it ticks into
place and burns white. A slam is the number's whole move, held to 1.4x. Under
a presence it is `.bc-whole`: it lands whole when its content lands and goes as
its content leaves; one that changes while still entering shows at once
(`data-bc-live`). IN A LABEL (`data-bc-run`, read from the DOM after every
render by `motion/label.ts`: words or a glyph beside it in its box, a box that
says it is a label, or a button's or tag's whole label) it still lands with
its content and ticks in, but leaves with its words, never ahead of them --
if it was showing as the leave began (landed, live, or come back); one whose
entrance had not landed is hidden as one alone is. If its presence turns
round while it is still showing, that entrance neither hides it nor reveals
it again.
`reveal="tick"`, THE DEFAULT (the owner's pick), ticks its
places in as it lands, each already its true digit; `"none"` lands it whole;
`"count"` counts up in at most ten timer writes, ending on the true value (a
change mid-count jumps to it; dropped while hidden). Outside a presence nothing
reveals. `format` writes it (`amount` for the Market's 7,450; a separator is a
column of its own width).
**Clock** `{endsAt, offset, format, beat, size: sm|md|lg, fs, tone}` -- a server
deadline written through a ref (`--` until the first write) on the
drift-corrected countdown; `beat` punches each new second after the first.

**Bar** `{value 0-100, tone, shape: slant|pill, segments, feed: ramp|step,
drive: value|ref, fillRef, axis: x|y, label, num, zeroNum, numPlaces, numBeat,
numTone, numReveal, gain {n, from, to}, glint {n, power}, crack {n, from}, hit
(n), drain, channel}` -- scaleX only, over a black track. `slant` has a white
ghost; `pill` is today's vitals pill (caption inside through Fit, numeral on
the right, notches), kept for the vehicle strip -- the vitals are slanted now.
`ramp` is `.bar-fill`'s 300 ms linear for 4-10 Hz feeds (named in
`--bc-t-ramp` too, so a page's own `.bc-fill` cannot change it); `step` is the
1 Hz squad's fall-then-ghost and ease-out rise -- never on the vitals.
`numReveal` defaults to `tick`. `drive="ref"`: a clock writes the fill's
transform. Real denominators only. Its track box is the surface channel; the
fill keeps its own transform.

**Vitals** `{hp, armor}` (the HUD's `hp` and `armour`) -- the player's health
and shield, slanted (the owner's pick): two straps, health over shield, each
its slab in the bar's color, today's caption (Health, Shield, on the text
slider), a slant Bar on the ramp feed and the numeral after it (ticking in).
Today's rules kept: a zero is not drawn; a drop in health of half a point or
more washes the bar red, at most once a second; four shield notches. It is
`VITALS_H` kit units tall (two `VITAL_H` straps and `--bc-gap`), three times
today's 1.05rem row, so the HUD hangs it by its own height (`--vitals-drop`)
and its own rule (#319, the owner's 2026-08-23 "display them on top of the
minimap instead and bump the chat up") puts it under the radar where it fits
and above it otherwise. Under a presence its plates move on their own
channels: no wrapper channel over it.

**Stamp** `{word, tone, size: tag|band|screen, kind: stamp|drop|slam, beat,
delay}` -- lands once per beat, holds its last frame; still at `beat` 0.

**Tag** `{children, tone, ink: light|dark, variant: word|chip|holder, enter:
wipe|drop|spin|none, beat}` -- a slanted chip, the skew on `::before`. DOWN is a
`word`, HS a `chip` with dark ink, a Yubikey or bounty mark a `holder`.
**Badge** `{kind: delta|count, value, tone, beat, at}` -- +N floating off a
counter, xN on a repeated notice; drawn outside the clipped plate.

**LightSweep** `{kind: sweep|stinger|glint|name, beat, power, color}` -- a
one-shot crossing in a plate's `fx` or a bar's track. Ends invisible.

**Button** -- `ui/Btn`'s contract exactly (`variant: primary|default|ghost|
danger`, `size: sm|md|lg|xl`, `active`, `disabled`, `full`, `cue`, `title`,
`onPress`) on a slanted face with a slab in the variant color. Keeps `btn` (R3),
the cues and a Fit label. **CardAction** `{tone, ...}`: a card's action plate,
its edge and ink in the action's color.
**TabStrip** `{tabs: {id, label}[], value, onPick, design: plates|blade}` and
**Tab** -- the S2 tablist's semantics (roving tabindex, arrows, Home, End).
**Card** `{name, sub, rarity, owned, equipped, art, action, shape:
slant|square}` -- the edge reads equipped, then owned, then rarity (pips in the
colorblind modes); a monogram when there is no art. **CardGrid**: 9.5 units a
column, four at most.
**ListRow** `{label, summary, trailing, state: rest|active|confirm, onPress,
cue}`.
**DialogFrame** `{open, title, onClose, actions, children, scrim}` -- the
broadcast preset in and out, the scrim on `fade`; Escape closes it alone (a
capture listener); its words are held through its leave. It fills the nearest
positioned box, never the viewport.

## Motion: the presence contract

A **presence** is one anchor of a screen on its way in and out.

    phase     hidden | entering | shown | leaving
    channels  root (the wrapper itself), edge, surface, content (+ .bc-whole)

The root carries `data-bc-phase`, `data-bc-preset`, and per channel
`--bc-<ch>-ms`, `--bc-<ch>-delay`, `--bc-<ch>-ease` (computed in TS as plain
strings: calc() on `<time>` is unverified on 103); `--bc-tp: none` while it
lands. While hidden or held it gets `layer-off`, `aria-hidden` and `inert`;
leaving, `inert` (pointer events off).

Primitives opt into a channel by class: `.bc-ch-edge` (scaleY about its pivot),
`.bc-ch-surface` (scaleX from the slab side), `.bc-ch-content` (slides from the
slab side and fades), `.bc-whole` (a number: opacity, stepped, hidden by
`--bc-pre-whole-o`, 0 unless a quick hide names 1; with `data-bc-run`, a
number in a label, which keeps its opacity on the way out: every root
declares `--bc-run-o: 1`, and only the settled hidden takes the preset's
content value). A channel element outside any presence is simply shown.

**API**

    const p = usePresence(want, { preset, order, hold, appear = true, keepMounted, now, step })
    // p.mounted, p.phase, p.held, p.rootProps (spread on the anchor's OWN wrapper), p.info

    <Presence show order preset hold appear keepMounted as className style tut role>...</Presence>
    <PresenceScope want hold preset step>...</PresenceScope>   // a context, no element
    <QuickHide hidden as className style>...</QuickHide>        // a layer root
    <PresenceClock now={fn}>...</PresenceClock>                  // a harness's clock

`Presence` provides `PresencePhaseCtx` (what a Numeral's reveal reads); with the
raw hook, wrap the children in `<PresencePhaseCtx.Provider value={p.info}>`.

**Mechanics**

1. The first frame renders hidden; one forced style read in a layout effect,
   then the entrance begins before the browser paints (no `@starting-style` on
   103).
2. Transitions, so a leave mid-enter or an enter mid-leave turns round from
   where it is and ends on target.
3. An anchor's turn: `order x step` into its scope's reveal; a leave runs the
   stagger backwards at half the step. Eight anchors reveal in 1.2 s.
4. A **late joiner** (the squad slot and the inventory column mount on landed)
   starts at `max(0, scopeStart + order x step - now)`: it never waits and
   never restarts the scope.
5. `hold` keeps it mounted, hidden and layer-off; it enters when released.
6. **Settle** (ui/fade.ts, #252): a phase ends on its last channel's
   transitionend, with the clock as the net at the window plus
   `FADE_SETTLE_MARGIN_MS`, re-checked on every envelope. An entrance the clock
   had to end that is still short of its target lands outright (transitions
   off); a healthy one is not touched. A leave unmounts (or stays, kept). A
   leave its scope drove that ends while others in the scope still leave
   PARKS: hidden, still mounted, holding its box, until the last leave in the
   scope (and every scope inside it) ends; then they all go together, so a
   page never reflows around what is still on screen (a Market page's foot
   unmounting mid-close jumped its cards up to 128 px).
7. The clock is injectable (`now`, or `<PresenceClock>`), so a harness's slow
   motion and seek() hold the settle with the CSS. A harness gives its
   presences its own clock, or a held frame of a leave is cut short by the
   wall clock.

**What a change of moment does**

| moment | result |
|---|---|
| want false while entering | leaves from where it is, at once |
| want true while leaving | enters from where it is, at once |
| want false when shown | leaves on its turn (the stagger backwards) |
| want false in a quick hide | straight to hidden, unseen, no offAir |
| quick hide while entering | the entrance completes underneath; the return is the 150 ms fade |
| land mid-reveal | the late-joiner rule |
| held while entering or shown | hidden at once |
| the scope goes, one leave ends before the rest | parked (hidden, its box held) until the scope's last leave ends |

**Constraints.** Beats never fire on mount, and presence never fires one (a
placard under a presence drops its own `hotDrop`: the `drop` preset is that
motion). The presence element is always its own wrapper: never `.hud-safe`
(R12), never a fixed box or an ancestor of one (R9), never a
`-translate-x-1/2` centering box, never an element with a transform of its own
(the active slot, the hitmarker, the elim banner). Measured boxes (the squad
slot, the chat column, the vitals strip) keep their box; the presence goes
inside them.

**The quick hide** is a LAYER state at a layer root (the ui gate for GTA's map
and menus; the HUD root for pause and the scope): the layer's opacity over
`--bc-t-quick` (150 ms) each way; it never unmounts and never replays the
reveal. Give both layers one edge and chat, notices and the HUD return
together.

### Presets

| name | in | out | for |
|---|---|---|---|
| `broadcast` | **onAir**: edge 360 ms at 0, surface 420 at +80, content 480 at +160 | **offAir**: content 140 at 0, surface 260 at +60, edge 200 at +120 | everything Broadcast |
| `quickHide` | root opacity 150 linear | the same | layer roots only |
| `drop` | today's hotDrop (620, snap) | a 200 ms fade | placards |
| `fade` | opacity 200 linear | the same | today's HUD root |
| `slide` | noticeIn's 220 ms fly | a 200 ms fade | rows |
| `none` | instant | instant | |

**A screen picks its preset in one place**: `<PresenceScope preset="...">`.
Every presence under it that names none takes it, and the name lands on each
root as `data-bc-preset`, so the timings (TS) and the hidden values (CSS) always
agree. A presence can still name its own (`preset="drop"` on a placard).

**To add a preset** (say `iris`):
1. `motion/iris.css`: `[data-bc-preset="iris"] { --bc-pre-root-o: 0; ... }` --
   the hidden values of the channels it moves (`--bc-pre-root-t`,
   `--bc-pre-root-o`, `--bc-pre-edge-s`, `--bc-pre-edge-o`,
   `--bc-pre-surface-s`, `--bc-pre-surface-o`, `--bc-pre-content-x`,
   `--bc-pre-content-o`); anything unnamed stays put. A number standing alone
   is hidden by it whatever it moves (`--bc-pre-whole-o: 0`); only a quick
   hide names 1.
2. `registerPreset({ name: 'iris', enter, leave, step, leaveStep, reverse,
   layer: false })`, with timings from `HALF` or your own `{ms, at, ease}` per
   channel (literal curves: `EASE.*`).
3. Import the CSS after `motion.css` (in `index.ts`), and add it to
   `scripts/test-broadcast.mjs`'s `KIT_SHEETS` (the test fails on a kit sheet
   it does not read).
